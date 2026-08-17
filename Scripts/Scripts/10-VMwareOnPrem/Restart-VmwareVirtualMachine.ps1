<#
.SYNOPSIS
    Restarts a vSphere virtual machine, guest-initiated by default.

.DESCRIPTION
    Restarts selected VMs. A guest restart through VMware Tools is attempted
    first; the hard reset - which is equivalent to pressing the reset button
    and risks filesystem damage - requires an explicit -HardReset. The
    workbook rates this Medium risk for exactly that reason and gates it on
    approval.

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

.PARAMETER HardReset
    Perform a hard reset instead of a guest restart. Risks data loss; never
    the default.

.PARAMETER WaitForToolsSeconds
    How long to wait for VMware Tools to come back after the restart.

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
    .\Restart-VmwareVirtualMachine.ps1 -VIServer vcenter01 -VMName APP01

    REQUEST mode - raises an approval for a guest restart.

.EXAMPLE
    .\Restart-VmwareVirtualMachine.ps1 -VIServer vcenter01 -VMName APP01 -ApprovalReference APR-... -HardReset

    Performs an approved hard reset.

.NOTES
    Source use case      : #9 - Reset VM
    Category             : VMware OnPrem
    Technology           : PowerCLI
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "Hard reset risks data loss; confirm before execution"

    Required permissions : vSphere role with Virtual machine > Interaction > Reset and Restart guest.
    Required modules     : VMware.VimAutomation.Core
    Authentication       : Connect-VIServer with the PowerCLI credential store
                           or an explicit -Credential.

    Rollback             : NONE for a hard reset - an interrupted write is not
                           recoverable. That is why the guest restart is the
                           default and -HardReset must be chosen deliberately.
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

    [switch]$HardReset,

    [ValidateRange(0,3600)]
    [int]$WaitForToolsSeconds = 300,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Planned VM restart',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Restart-VmwareVirtualMachine'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #9 (VMware OnPrem)'

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

        if (-not $VMName) { throw 'Specify -VMName. Restarting every VM in vCenter is not a safe default.' }

        foreach ($vm in (Get-VM -Name $VMName -ErrorAction Stop)) {
            if ($vm.PowerState -ne 'PoweredOn') {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $vm.Name `
                    -Message ('Skipped - VM is {0}, not PoweredOn' -f $vm.PowerState)
                continue
            }
            $toolsRunning = ($vm.ExtensionData.Guest.ToolsRunningStatus -eq 'guestToolsRunning')
            if (-not $toolsRunning -and -not $HardReset) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $vm.Name `
                    -Message 'VMware Tools is not running - a guest restart is not possible. -HardReset would be required.'
            }
            $results.Add([PSCustomObject]@{
                Name         = $vm.Name
                Id           = $vm.Id
                VMName       = $vm.Name
                PowerState   = "$($vm.PowerState)"
                ToolsRunning = $toolsRunning
                VMHost       = $vm.VMHost.Name
                Method       = if ($HardReset) { 'HARD RESET (risks data loss)' }
                               elseif ($toolsRunning) { 'guest restart' }
                               else { 'blocked - no Tools and no -HardReset' }
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Restart VM', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Restart VM')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $vmObj = Get-VM -Name $item.VMName -ErrorAction Stop

            if ($HardReset) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
                    'HARD RESET requested. Approval={0} Ticket={1}' -f $ApprovalReference, $TicketReference)
                Restart-VM -VM $vmObj -Confirm:$false -ErrorAction Stop | Out-Null
            } else {
                if (-not $item.ToolsRunning) {
                    throw 'VMware Tools is not running and -HardReset was not given. Refusing a hard reset by default.'
                }
                Restart-VMGuest -VM $vmObj -Confirm:$false -ErrorAction Stop | Out-Null
            }

            $toolsState = 'not waited for'
            if ($WaitForToolsSeconds -gt 0) {
                Start-Sleep -Seconds 10
                $deadline = (Get-Date).AddSeconds($WaitForToolsSeconds)
                do {
                    Start-Sleep -Seconds 5
                    $toolsState = (Get-VM -Name $item.VMName).ExtensionData.Guest.ToolsRunningStatus
                } while ($toolsState -ne 'guestToolsRunning' -and (Get-Date) -lt $deadline)
            }

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Restart via {0} complete. Tools state: {1}' -f $item.Method, $toolsState)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'Restarted'; Detail = ('{0}; tools {1}' -f $item.Method, $toolsState)
                Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Reset VM'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
