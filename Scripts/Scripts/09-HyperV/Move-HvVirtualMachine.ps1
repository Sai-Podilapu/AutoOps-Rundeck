<#
.SYNOPSIS
    Live migrates a virtual machine to another Hyper-V host.

.DESCRIPTION
    Performs a live migration of a running VM to a destination host. Live
    migration is zero-downtime in theory, but a failure mid-migration affects
    a production workload, so this script validates the destination has
    capacity and that live migration is enabled on both ends before it starts,
    and verifies the VM is running on the destination afterwards.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER Credential
    Credential for the remote Hyper-V host.

.PARAMETER SourceHost
    Current Hyper-V host.

.PARAMETER DestinationHost
    Target Hyper-V host.

.PARAMETER MigrateVMName
    Virtual machine to migrate.

.PARAMETER IncludeStorage
    Perform a shared-nothing migration that moves the VM storage as well.

.PARAMETER DestinationStoragePath
    Storage path on the destination when -IncludeStorage is used.

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
    .\Move-HvVirtualMachine.ps1 -SourceHost HV01 -DestinationHost HV02 -MigrateVMName APP01

    REQUEST mode - validates and raises an approval, migrating nothing.

.EXAMPLE
    .\Move-HvVirtualMachine.ps1 -SourceHost HV01 -DestinationHost HV02 -MigrateVMName APP01 -ApprovalReference APR-...

    Performs the approved migration.

.NOTES
    Source use case      : #6 - Hyper-V VM Live Migration
    Category             : Hyper-V
    Technology           : PowerShell / SCVMM
    Difficulty           : High
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : High
    Human approval needed: YES
    Guardrails (col L)   : "Zero-downtime in theory, but failures impact prod VMs; approval + maintenance window"

    Required permissions : Hyper-V Administrators on BOTH hosts, with constrained delegation or CredSSP configured for live migration.
    Required modules     : Hyper-V
    Authentication       : Integrated Kerberos over PSRemoting; SCVMM cmdlets
                           where noted.

    Live migration requires Kerberos constrained delegation or CredSSP
    between the hosts. The workbook marks this High risk and
    approval-gated, and the SOP requires a maintenance window even though
    downtime is expected to be zero.

    Rollback             : Migrate back to the source host. A failed live
                           migration normally leaves the VM running on the
                           source, which is why the post-migration verification
                           below reports where the VM actually ended up rather
                           than assuming success.
#>

#Requires -Version 5.1
#Requires -Modules Hyper-V

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [Parameter(Mandatory)]
    [string]$SourceHost,

    [Parameter(Mandatory)]
    [string]$DestinationHost,

    [Parameter(Mandatory)]
    [string[]]$MigrateVMName,

    [switch]$IncludeStorage,

    [string]$DestinationStoragePath,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Planned live migration',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Move-HvVirtualMachine'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #6 (Hyper-V)'

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

    # Risk = High: validate before doing anything at all.
    $pre = Test-Prerequisite -RequiredModule 'Hyper-V'
    if (-not $pre.Passed) {
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Message $pre.Summary
        throw $pre.Summary
    }
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Pre-flight passed.'

    $results  = [System.Collections.Generic.List[PSCustomObject]]::new()
    $failures = [System.Collections.Generic.List[PSCustomObject]]::new()
}

process {
    try {
        Connect-AutomationPlatform -Platform 'HyperV' | Out-Null


        $srcArgs = @{ ComputerName = $SourceHost; ErrorAction = 'Stop' }
        $dstArgs = @{ ComputerName = $DestinationHost; ErrorAction = 'Stop' }
        if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) {
            $srcArgs.Credential = $Credential; $dstArgs.Credential = $Credential
        }

        # Both ends must have live migration enabled, or the migration fails partway.
        $srcHost = Get-VMHost @srcArgs
        $dstHost = Get-VMHost @dstArgs
        if (-not $srcHost.VirtualMachineMigrationEnabled) {
            throw ('Live migration is not enabled on the source host {0}.' -f $SourceHost)
        }
        if (-not $dstHost.VirtualMachineMigrationEnabled) {
            throw ('Live migration is not enabled on the destination host {0}.' -f $DestinationHost)
        }

        foreach ($name in $MigrateVMName) {
            $vm = Get-VM -Name $name @srcArgs
            if ($vm.State -ne 'Running') {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $name `
                    -Message ('VM is {0}, not Running - a live migration does not apply' -f $vm.State)
                continue
            }
            if (Get-VM -Name $name @dstArgs -ErrorAction SilentlyContinue) {
                throw ('A VM named {0} already exists on the destination {1}.' -f $name, $DestinationHost)
            }

            $needGB = [math]::Round($vm.MemoryAssigned / 1GB, 2)
            $cim = @{ ClassName = 'Win32_OperatingSystem'; ErrorAction = 'Stop'; ComputerName = $DestinationHost }
            $dstFreeGB = [math]::Round((Get-CimInstance @cim).FreePhysicalMemory * 1KB / 1GB, 2)
            if ($dstFreeGB -lt $needGB) {
                throw ('Destination {0} has {1}GB free memory, VM needs {2}GB. Refusing.' -f
                       $DestinationHost, $dstFreeGB, $needGB)
            }

            $results.Add([PSCustomObject]@{
                Name            = ('{0} : {1} -> {2}' -f $name, $SourceHost, $DestinationHost)
                Id              = $vm.Id
                VMName          = $name
                SourceHost      = $SourceHost
                DestinationHost = $DestinationHost
                MemoryAssignedGB= $needGB
                DestFreeMemoryGB= $dstFreeGB
                State           = "$($vm.State)"
                IncludeStorage  = [bool]$IncludeStorage
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Live migrate VM', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Live migrate VM')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $srcArgs = @{ ComputerName = $item.SourceHost; ErrorAction = 'Stop' }
            if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $srcArgs.Credential = $Credential }

            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
                'Starting live migration of {0} ({1}GB assigned memory)' -f $item.VMName, $item.MemoryAssignedGB)

            if ($IncludeStorage) {
                if (-not $DestinationStoragePath) {
                    throw '-IncludeStorage requires -DestinationStoragePath.'
                }
                Move-VM -Name $item.VMName -DestinationHost $item.DestinationHost `
                        -IncludeStorage -DestinationStoragePath $DestinationStoragePath @srcArgs
            } else {
                Move-VM -Name $item.VMName -DestinationHost $item.DestinationHost @srcArgs
            }

            # Post-action verification: confirm where the VM actually is, rather than
            # assuming the migration landed.
            $dstCheck = @{ ComputerName = $item.DestinationHost; ErrorAction = 'Stop' }
            if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $dstCheck.Credential = $Credential }
            $moved = Get-VM -Name $item.VMName @dstCheck

            if ($moved -and $moved.State -eq 'Running') {
                Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                    'Migration verified: {0} is Running on {1}' -f $item.VMName, $item.DestinationHost)
                $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'Migrated'; Detail = ('Running on {0}' -f $item.DestinationHost); Succeeded = $true })
            } else {
                $state = if ($moved) { $moved.State } else { 'not present' }
                Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $label -Message (
                    'Migration did not verify - VM is {0} on the destination' -f $state)
                $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'Failed'; Detail = ('destination state: {0}' -f $state); Succeeded = $false })
            }
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Hyper-V VM Live Migration'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
