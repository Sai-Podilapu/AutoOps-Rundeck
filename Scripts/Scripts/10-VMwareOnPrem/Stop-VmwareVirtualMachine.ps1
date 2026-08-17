<#
.SYNOPSIS
    Powers off vSphere virtual machines, gracefully by default.

.DESCRIPTION
    Shuts down guests through VMware Tools and only falls back to a hard
    power-off when -Force is given and the graceful attempt has timed out.
    Powering off a production VM needs ticket confirmation, which is why this
    is approval-gated even though the operation itself is routine.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER VIServer
    vCenter server to connect to. Falls back to vmware.vCenterServer in
    config.json.

.PARAMETER Credential
    Credential for vCenter. Omit to use the PowerCLI credential store or SSPI.

.PARAMETER VMName
    Limit to specific virtual machines.

.PARAMETER ClusterName
    Limit to VMs or hosts in specific clusters.

.PARAMETER Force
    Permit a hard power-off if the graceful shutdown does not complete within
    the timeout.

.PARAMETER ShutdownTimeoutSeconds
    How long to wait for the guest to shut down gracefully.

.PARAMETER ApprovalReference
    Approval token from New-ApprovalRequest, after a human has approved it.
    Without this the script performs no change.

.PARAMETER RequestApproval
    Force REQUEST mode - produce the change set and raise an approval request,
    then stop, even if a reference was supplied.

.PARAMETER TicketReference
    ITSM ticket number recorded in the audit trail alongside the approval
    reference.

.PARAMETER Reason
    Change reason recorded in the approval artifact and the audit log.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Stop-VmwareVirtualMachine.ps1 -VIServer vcenter01 -VMName APP01

    REQUEST mode - raises an approval to shut down APP01.

.EXAMPLE
    .\Stop-VmwareVirtualMachine.ps1 -VIServer vcenter01 -VMName APP01 -ApprovalReference APR-... -Force

    Shuts down gracefully, falling back to a hard power-off if the guest does
    not respond.

.NOTES
    Source use case      : #8 - VM Power Off
    Category             : VMware OnPrem
    Technology           : PowerCLI / REST
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "Powering off prod VMs needs ticket confirmation; graceful shutdown per SOP"

    Required permissions : vSphere role with Virtual machine > Interaction > Power off and Shut down guest.
    Required modules     : VMware.VimAutomation.Core
    Authentication       : Connect-VIServer with the PowerCLI credential store
                           or an explicit -Credential.

    Rollback             : Power the VM back on with
                           Start-VmwareVirtualMachine.ps1. A hard power-off may
                           leave the guest filesystem dirty, which is why it is
                           never the first attempt.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Core

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$VIServer,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [string[]]$VMName,

    [string[]]$ClusterName,

    [switch]$Force,

    [ValidateRange(10,3600)]
    [int]$ShutdownTimeoutSeconds = 300,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Planned VM shutdown',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Stop-VmwareVirtualMachine'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #8 (VMware OnPrem)'

    try {
        $config = if ($ConfigPath) { Get-AutomationConfig -Path $ConfigPath } else { Get-AutomationConfig }
        # Recorded so an audit can tell which environment a run targeted.
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Configuration loaded for environment: {0}' -f $config.environment)
    } catch {
        # Fail closed. Safety lists and endpoints live in config; acting
        # without them would bypass the guardrails this use case requires.
        throw ('Cannot read configuration, refusing to proceed: {0}' -f $_.Exception.Message)
    }

    $results  = [System.Collections.Generic.List[PSCustomObject]]::new()
    $failures = [System.Collections.Generic.List[PSCustomObject]]::new()
}

process {
    try {
        Connect-AutomationPlatform -Platform 'VMware' | Out-Null


        if (-not $VIServer -and $config -and $config.vmware) { $VIServer = $config.vmware.vCenterServer }
        if (-not $VIServer) { throw 'No vCenter specified. Pass -VIServer or set vmware.vCenterServer in config.json.' }

        $viParams = @{ Server = $VIServer; ErrorAction = 'Stop' }
        if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $viParams.Credential = $Credential }
        $vc = Connect-VIServer @viParams
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $VIServer -Message (
            'Connected to vCenter {0} (version {1})' -f $vc.Name, $vc.Version)

        $vms = if ($VMName)          { Get-VM -Name $VMName -ErrorAction Stop }
               elseif ($ClusterName) { Get-Cluster -Name $ClusterName | Get-VM }
               else                  { throw 'Specify -VMName or -ClusterName. Powering off every VM in vCenter is not a safe default.' }

        foreach ($vm in $vms) {
            if ($vm.PowerState -eq 'PoweredOff') {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $vm.Name -Message 'Skipped - already powered off'
                continue
            }
            $toolsRunning = ($vm.ExtensionData.Guest.ToolsRunningStatus -eq 'guestToolsRunning')
            if (-not $toolsRunning -and -not $Force) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $vm.Name `
                    -Message 'VMware Tools is not running - a graceful shutdown is not possible. Pass -Force to allow a hard power-off.'
            }
            $results.Add([PSCustomObject]@{
                Name         = $vm.Name
                Id           = $vm.Id
                VMName       = $vm.Name
                PowerState   = "$($vm.PowerState)"
                VMHost       = $vm.VMHost.Name
                ToolsRunning = $toolsRunning
                GuestOS      = $vm.ExtensionData.Guest.GuestFullName
                Method       = if ($toolsRunning) { 'graceful guest shutdown' } elseif ($Force) { 'hard power off' } else { 'blocked - no Tools and no -Force' }
            })
        }
    } catch {
        $msg = $_.Exception.Message
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Message ('Discovery FAILED: {0}' -f $msg)
        $failures.Add([PSCustomObject]@{ Stage = 'Discovery'; Error = $msg })
    }
}

end {
    $candidates = @($results)

    if ($candidates.Count -eq 0) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'No eligible objects. Nothing to do.'
        Write-Output @()
        return
    }

    # Every candidate is logged individually BEFORE any action is taken.
    foreach ($c in $candidates) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0}' -f $c.Name) -Message 'CANDIDATE'
    }

    if ($RequestApproval -or -not $ApprovalReference) {
        $request = New-ApprovalRequest -ScriptName $scriptName -ChangeSet $candidates `
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Power off VM', $candidates.Count, $Reason, $TicketReference)
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $request.Reference -Message (
            'REQUEST mode - nothing was changed. Supply -ApprovalReference {0} once approved.' -f $request.Reference)
        Write-Warning ('No change made. Approval reference: {0}' -f $request.Reference)
        Write-Output ([PSCustomObject]@{
            Mode = 'RequestApproval'; ApprovalReference = $request.Reference
            CandidateCount = $candidates.Count; Candidates = $candidates; Changed = $false })
        return
    }

    $approvalCheck = Test-ApprovalReference -Reference $ApprovalReference -ScriptName $scriptName
    if (-not $approvalCheck.IsValid) {
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $ApprovalReference -Message (
            'REFUSED to execute: {0}' -f $approvalCheck.Reason)
        throw ('Approval validation failed: {0}' -f $approvalCheck.Reason)
    }
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $ApprovalReference -Message (
        'Approval accepted. {0} Ticket={1}' -f $approvalCheck.Reason, $TicketReference)

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Power off VM')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $vmObj = Get-VM -Name $item.VMName -ErrorAction Stop

            if ($item.ToolsRunning) {
                Stop-VMGuest -VM $vmObj -Confirm:$false -ErrorAction Stop | Out-Null

                $deadline = (Get-Date).AddSeconds($ShutdownTimeoutSeconds)
                do {
                    Start-Sleep -Seconds 5
                    $state = (Get-VM -Name $item.VMName).PowerState
                } while ("$state" -ne 'PoweredOff' -and (Get-Date) -lt $deadline)

                if ("$state" -ne 'PoweredOff') {
                    if ($Force) {
                        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
                            'Guest did not shut down within {0}s - falling back to a hard power-off as -Force was given' -f $ShutdownTimeoutSeconds)
                        Stop-VM -VM $vmObj -Confirm:$false -ErrorAction Stop | Out-Null
                    } else {
                        throw ('Guest did not shut down within {0}s and -Force was not given. VM left running.' -f $ShutdownTimeoutSeconds)
                    }
                }
            } else {
                if (-not $Force) {
                    throw 'VMware Tools is not running and -Force was not given. Refusing a hard power-off by default.'
                }
                Stop-VM -VM $vmObj -Confirm:$false -ErrorAction Stop | Out-Null
            }

            $final = (Get-VM -Name $item.VMName).PowerState
            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Power off complete via {0}. State: {1}' -f $item.Method, $final)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'PoweredOff'; Detail = ('{0}; final state {1}' -f $item.Method, $final)
                Succeeded = ("$final" -eq 'PoweredOff') })
        } catch {
            $msg = $_.Exception.Message
            Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $label -Message ('FAILED: {0}' -f $msg)
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'Failed'; Detail = $msg; Succeeded = $false })
        }
    }

    $ok  = @($actions | Where-Object { $_.Succeeded })
    $bad = @($actions | Where-Object { -not $_.Succeeded })
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'END. Succeeded={0} Failed={1}' -f $ok.Count, $bad.Count)

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'VM Power Off'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
