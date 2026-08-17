<#
.SYNOPSIS
    Resizes vSphere virtual machine CPU and memory.

.DESCRIPTION
    Changes vCPU count and memory on a VM. Whether this needs downtime depends
    on hot-add: the script reads the hot-add settings and reports up front
    whether the change can be applied live or requires the VM to be powered
    off, rather than failing partway.

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

.PARAMETER TargetVMName
    Virtual machine to resize.

.PARAMETER NewNumCpu
    New vCPU count. Omit to leave unchanged.

.PARAMETER NewMemoryGB
    New memory in GB. Omit to leave unchanged.

.PARAMETER AllowPowerOff
    Permit the script to power the VM off when hot-add is unavailable. Off by
    default.

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
    .\Set-VmwareVmCompute.ps1 -VIServer vcenter01 -TargetVMName APP01 -NewNumCpu 8 -NewMemoryGB 32

    REQUEST mode - reports whether hot-add covers the change and raises an
    approval.

.EXAMPLE
    .\Set-VmwareVmCompute.ps1 -VIServer vcenter01 -TargetVMName APP01 -NewMemoryGB 32 -ApprovalReference APR-... -AllowPowerOff

    Applies the approved change, powering the VM off if required.

.NOTES
    Source use case      : #11 - VM Compute Update (CPU/RAM resize)
    Category             : VMware OnPrem
    Technology           : PowerCLI
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "May require downtime if hot-add disabled; ticket-driven"

    Required permissions : vSphere role with Virtual machine > Configuration > Change CPU count and Change memory.
    Required modules     : VMware.VimAutomation.Core
    Authentication       : Connect-VIServer with the PowerCLI credential store
                           or an explicit -Credential.

    Reducing vCPU or memory ALWAYS requires a power-off; only increases
    can be hot-added, and only when hot-add is enabled on the VM. The
    script reports which case applies before asking for approval.

    Rollback             : Re-run with the previous values, which are recorded
                           in the approval artifact and the audit log before
                           the change is applied.
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

    [Parameter(Mandatory)]
    [string[]]$TargetVMName,

    [ValidateRange(1,128)]
    [int]$NewNumCpu = 0,

    [ValidateRange(1,6144)]
    [int]$NewMemoryGB = 0,

    [switch]$AllowPowerOff,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'VM compute resize',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-VmwareVmCompute'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #11 (VMware OnPrem)'

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

        if ($NewNumCpu -eq 0 -and $NewMemoryGB -eq 0) {
            throw 'Specify -NewNumCpu, -NewMemoryGB or both. Nothing to change.'
        }

        foreach ($vm in (Get-VM -Name $TargetVMName -ErrorAction Stop)) {
            $cpuHotAdd = $vm.ExtensionData.Config.CpuHotAddEnabled
            $memHotAdd = $vm.ExtensionData.Config.MemoryHotAddEnabled

            $cpuChange = ($NewNumCpu   -gt 0 -and $NewNumCpu   -ne $vm.NumCpu)
            $memChange = ($NewMemoryGB -gt 0 -and $NewMemoryGB -ne $vm.MemoryGB)
            if (-not $cpuChange -and -not $memChange) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $vm.Name `
                    -Message 'Skipped - already at the requested size (idempotent)'
                continue
            }

            # A decrease can never be hot-applied, whatever the hot-add settings say.
            $cpuDecrease = ($NewNumCpu   -gt 0 -and $NewNumCpu   -lt $vm.NumCpu)
            $memDecrease = ($NewMemoryGB -gt 0 -and $NewMemoryGB -lt $vm.MemoryGB)

            $needsPowerOff = $false
            $reasons = @()
            if ($vm.PowerState -eq 'PoweredOn') {
                if ($cpuDecrease) { $needsPowerOff = $true; $reasons += 'vCPU decrease' }
                if ($memDecrease) { $needsPowerOff = $true; $reasons += 'memory decrease' }
                if ($cpuChange -and -not $cpuDecrease -and -not $cpuHotAdd) { $needsPowerOff = $true; $reasons += 'CPU hot-add disabled' }
                if ($memChange -and -not $memDecrease -and -not $memHotAdd) { $needsPowerOff = $true; $reasons += 'memory hot-add disabled' }
            }

            $results.Add([PSCustomObject]@{
                Name           = $vm.Name
                Id             = $vm.Id
                VMName         = $vm.Name
                PowerState     = "$($vm.PowerState)"
                CurrentNumCpu  = $vm.NumCpu
                CurrentMemoryGB= $vm.MemoryGB
                NewNumCpu      = if ($NewNumCpu -gt 0) { $NewNumCpu } else { $vm.NumCpu }
                NewMemoryGB    = if ($NewMemoryGB -gt 0) { $NewMemoryGB } else { $vm.MemoryGB }
                CpuHotAdd      = $cpuHotAdd
                MemoryHotAdd   = $memHotAdd
                RequiresPowerOff = $needsPowerOff
                PowerOffReason = ($reasons -join '; ')
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Resize VM compute', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Resize VM compute')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $vmObj = Get-VM -Name $item.VMName -ErrorAction Stop

            if ($item.RequiresPowerOff -and -not $AllowPowerOff) {
                throw ('{0} requires a power-off ({1}) and -AllowPowerOff was not given. VM left untouched.' -f
                       $item.VMName, $item.PowerOffReason)
            }

            $poweredOffByUs = $false
            if ($item.RequiresPowerOff -and $vmObj.PowerState -eq 'PoweredOn') {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
                    'Powering off for the resize: {0}' -f $item.PowerOffReason)
                if ($vmObj.ExtensionData.Guest.ToolsRunningStatus -eq 'guestToolsRunning') {
                    Stop-VMGuest -VM $vmObj -Confirm:$false -ErrorAction Stop | Out-Null
                    $deadline = (Get-Date).AddSeconds(300)
                    do { Start-Sleep -Seconds 5; $st = (Get-VM -Name $item.VMName).PowerState }
                    while ("$st" -ne 'PoweredOff' -and (Get-Date) -lt $deadline)
                }
                if ((Get-VM -Name $item.VMName).PowerState -ne 'PoweredOff') {
                    Stop-VM -VM $vmObj -Confirm:$false -ErrorAction Stop | Out-Null
                }
                $poweredOffByUs = $true
            }

            $setParams = @{ VM = (Get-VM -Name $item.VMName); Confirm = $false; ErrorAction = 'Stop' }
            if ($item.NewNumCpu   -ne $item.CurrentNumCpu)   { $setParams.NumCpu   = $item.NewNumCpu }
            if ($item.NewMemoryGB -ne $item.CurrentMemoryGB) { $setParams.MemoryGB = $item.NewMemoryGB }
            Set-VM @setParams | Out-Null

            if ($poweredOffByUs) {
                Start-VM -VM (Get-VM -Name $item.VMName) -Confirm:$false -ErrorAction Stop | Out-Null
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message 'Powered back on after the resize'
            }

            $after = Get-VM -Name $item.VMName
            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Resized: {0}vCPU/{1}GB -> {2}vCPU/{3}GB' -f
                $item.CurrentNumCpu, $item.CurrentMemoryGB, $after.NumCpu, $after.MemoryGB)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'Resized'
                Detail = ('{0}vCPU/{1}GB -> {2}vCPU/{3}GB' -f $item.CurrentNumCpu, $item.CurrentMemoryGB, $after.NumCpu, $after.MemoryGB)
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'VM Compute Update (CPU/RAM resize)'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
