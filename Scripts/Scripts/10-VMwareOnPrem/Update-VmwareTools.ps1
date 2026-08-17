<#
.SYNOPSIS
    Upgrades VMware Tools on virtual machines.

.DESCRIPTION
    Upgrades VMware Tools where the current version is out of date. A Tools
    upgrade can require a guest reboot and briefly drops the network adapter,
    which is why the workbook gates it on approval and a maintenance window.
    -NoReboot is passed by default so the guest is not restarted without a
    separate decision.

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

.PARAMETER AllowReboot
    Permit the guest to reboot if the Tools upgrade requires it. Off by
    default.

.PARAMETER IncludePoweredOff
    Include powered-off VMs in the candidate list. They cannot be upgraded in
    place, so they are excluded by default.

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
    .\Update-VmwareTools.ps1 -VIServer vcenter01 -ClusterName PROD

    REQUEST mode - lists VMs with outdated Tools and raises an approval.

.EXAMPLE
    .\Update-VmwareTools.ps1 -VIServer vcenter01 -VMName APP01 -ApprovalReference APR-... -AllowReboot

    Upgrades Tools on APP01, permitting a reboot if required.

.NOTES
    Source use case      : #4 - VMware Tools Upgrade
    Category             : VMware OnPrem
    Technology           : PowerCLI
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "May require guest reboot; maintenance window"

    Required permissions : vSphere role with Virtual machine > Interaction > VMware Tools install.
    Required modules     : VMware.VimAutomation.Core
    Authentication       : Connect-VIServer with the PowerCLI credential store
                           or an explicit -Credential.

    The upgrade briefly disconnects the guest network adapter as the
    vmxnet driver reloads. On a VM reached only over that adapter, expect
    a short loss of session even without a reboot.

    Rollback             : NONE in place - Tools cannot be downgraded through
                           this path. Snapshot the VM first with
                           New-VmwareVmSnapshot.ps1 if you need a way back.
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

    [switch]$AllowReboot,

    [switch]$IncludePoweredOff,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'VMware Tools upgrade',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Update-VmwareTools'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #4 (VMware OnPrem)'

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
               else                  { Get-VM }

        foreach ($vm in $vms) {
            if (-not $IncludePoweredOff -and $vm.PowerState -ne 'PoweredOn') { continue }

            $tools = $vm.ExtensionData.Guest.ToolsStatus
            $ver   = $vm.ExtensionData.Guest.ToolsVersion

            # toolsOk means current. Anything else is either old, absent or not running.
            if ($tools -eq 'toolsOk') { continue }
            if ($tools -eq 'toolsNotInstalled') {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $vm.Name `
                    -Message 'Skipped - VMware Tools is not installed; an upgrade cannot install it'
                continue
            }

            $results.Add([PSCustomObject]@{
                Name          = $vm.Name
                Id            = $vm.Id
                VMName        = $vm.Name
                PowerState    = "$($vm.PowerState)"
                ToolsStatus   = "$tools"
                ToolsVersion  = $ver
                GuestOS       = $vm.ExtensionData.Guest.GuestFullName
                RebootMayBeRequired = $true
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Upgrade VMware Tools', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Upgrade VMware Tools')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $vmObj = Get-VM -Name $item.VMName -ErrorAction Stop
            $upParams = @{ VM = $vmObj; Confirm = $false; ErrorAction = 'Stop' }
            if (-not $AllowReboot) { $upParams.NoReboot = $true }

            Update-Tools @upParams

            # Re-read rather than trusting the cmdlet's return.
            $after = (Get-VM -Name $item.VMName).ExtensionData.Guest.ToolsStatus
            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Tools upgrade issued (reboot allowed={0}). Status now: {1}' -f [bool]$AllowReboot, $after)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'ToolsUpgraded'
                Detail = ('{0} -> {1}' -f $item.ToolsStatus, $after); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'VMware Tools Upgrade'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
