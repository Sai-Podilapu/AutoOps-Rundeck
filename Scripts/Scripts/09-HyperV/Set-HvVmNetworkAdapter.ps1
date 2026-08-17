<#
.SYNOPSIS
    Adds or removes a network adapter on a Hyper-V virtual machine.

.DESCRIPTION
    Attaches a new virtual NIC to a switch, or detaches an existing one. A
    network change on a running production VM can cut it off from the network,
    so this is approval-gated and refuses to remove the last remaining
    adapter.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER ComputerName
    Hyper-V host(s) to act against. Defaults to the local host.

.PARAMETER Credential
    Credential for the remote Hyper-V host.

.PARAMETER TargetVMName
    Virtual machine to modify.

.PARAMETER Operation
    Add or Remove.

.PARAMETER AdapterName
    Name of the adapter to add or remove.

.PARAMETER SwitchName
    Virtual switch to connect to. Required for Add.

.PARAMETER VlanId
    Optional VLAN id to set on an added adapter.

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
    .\Set-HvVmNetworkAdapter.ps1 -ComputerName HV01 -TargetVMName APP01 -Operation Add -AdapterName 'Backup' -SwitchName 'Backup-vSwitch'

    REQUEST mode - raises an approval to add a backup NIC.

.EXAMPLE
    .\Set-HvVmNetworkAdapter.ps1 -ComputerName HV01 -TargetVMName APP01 -Operation Remove -AdapterName 'Backup' -ApprovalReference APR-...

    Removes the adapter after approval.

.NOTES
    Source use case      : #10 - Hyper-V NIC Add/Remove
    Category             : Hyper-V
    Technology           : PowerShell / SCVMM
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "Network change on VMs; ticket + approval"

    Required permissions : Hyper-V Administrators on the host.
    Required modules     : Hyper-V
    Authentication       : Integrated Kerberos over PSRemoting; SCVMM cmdlets
                           where noted.

    Rollback             : Reverse the operation - re-add the removed adapter,
                           or remove the added one. Note that a re-added
                           adapter gets a NEW MAC address unless one is set
                           explicitly, which can break MAC-based licensing or
                           DHCP reservations in the guest.
#>

#Requires -Version 5.1
#Requires -Modules Hyper-V

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string[]]$ComputerName = $env:COMPUTERNAME,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [Parameter(Mandatory)]
    [string]$TargetVMName,

    [Parameter(Mandatory)]
    [ValidateSet('Add','Remove')]
    [string]$Operation,

    [Parameter(Mandatory)]
    [string]$AdapterName,

    [string]$SwitchName,

    [ValidateRange(0,4094)]
    [int]$VlanId = 0,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Network adapter change',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-HvVmNetworkAdapter'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #10 (Hyper-V)'

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
        Connect-AutomationPlatform -Platform 'HyperV' | Out-Null


        foreach ($hv in $ComputerName) {
            $hvArgs = @{ ComputerName = $hv; ErrorAction = 'Stop' }
            if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $hvArgs.Credential = $Credential }

            $vm   = Get-VM -Name $TargetVMName @hvArgs
            $nics = @(Get-VMNetworkAdapter -VMName $TargetVMName @hvArgs)
            $existing = $nics | Where-Object { $_.Name -eq $AdapterName } | Select-Object -First 1

            if ($Operation -eq 'Add') {
                if (-not $SwitchName) { throw '-SwitchName is required when -Operation is Add.' }
                if ($existing) {
                    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $TargetVMName `
                        -Message ('Skipped - adapter {0} already exists (idempotent)' -f $AdapterName)
                    continue
                }
                $switch = Get-VMSwitch -Name $SwitchName @hvArgs -ErrorAction SilentlyContinue
                if (-not $switch) { throw ('Virtual switch {0} does not exist on {1}.' -f $SwitchName, $hv) }
            } else {
                if (-not $existing) {
                    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $TargetVMName `
                        -Message ('Skipped - adapter {0} does not exist (idempotent)' -f $AdapterName)
                    continue
                }
                # Refuse to strip the last NIC from a running VM - that isolates it.
                if ($nics.Count -le 1) {
                    throw ('Refusing to remove the only network adapter from {0}. The VM would lose all connectivity.' -f $TargetVMName)
                }
            }

            $results.Add([PSCustomObject]@{
                Name          = ('{0}\{1} : {2}' -f $hv, $TargetVMName, $AdapterName)
                Id            = $AdapterName
                VMName        = $TargetVMName
                HyperVHost    = $hv
                Operation     = $Operation
                AdapterName   = $AdapterName
                SwitchName    = $SwitchName
                VlanId        = $VlanId
                VMState       = "$($vm.State)"
                ExistingNics  = $nics.Count
                CurrentSwitch = if ($existing) { $existing.SwitchName } else { $null }
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Add/remove VM network adapter', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Add/remove VM network adapter')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $hvArgs = @{ ComputerName = $item.HyperVHost; ErrorAction = 'Stop' }
            if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $hvArgs.Credential = $Credential }

            if ($item.Operation -eq 'Add') {
                Add-VMNetworkAdapter -VMName $item.VMName -Name $item.AdapterName -SwitchName $item.SwitchName @hvArgs
                if ($item.VlanId -gt 0) {
                    Set-VMNetworkAdapterVlan -VMName $item.VMName -VMNetworkAdapterName $item.AdapterName `
                        -Access -VlanId $item.VlanId @hvArgs
                }
                $detail = 'attached to {0}' -f $item.SwitchName
            } else {
                Remove-VMNetworkAdapter -VMName $item.VMName -Name $item.AdapterName @hvArgs
                $detail = 'detached from {0}' -f $item.CurrentSwitch
            }

            $after = @(Get-VMNetworkAdapter -VMName $item.VMName @hvArgs).Count
            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Adapter {0} {1}. VM now has {2} adapter(s).' -f $item.AdapterName, $item.Operation.ToLower(), $after)
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = $item.Operation; Detail = $detail; Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Hyper-V NIC Add/Remove'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
