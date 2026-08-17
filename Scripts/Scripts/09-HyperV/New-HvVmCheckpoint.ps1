<#
.SYNOPSIS
    Creates a production checkpoint for virtual machines before a change.

.DESCRIPTION
    Takes a checkpoint of each selected VM, named with the reason and a
    timestamp so the purpose is readable months later. Production checkpoints
    are used where the guest supports them, because they use VSS and leave an
    application-consistent image rather than a saved-state one.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER ComputerName
    Hyper-V host(s) to act against. Defaults to the local host.

.PARAMETER VMName
    Limit to specific virtual machines. Wildcards are accepted for reporting
    scripts only.

.PARAMETER Credential
    Credential for the remote Hyper-V host.

.PARAMETER CheckpointReason
    Short reason recorded in the checkpoint name.

.PARAMETER SkipIfRecentHours
    Skip a VM that already has a checkpoint newer than this. Makes a re-run
    idempotent instead of stacking checkpoints.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\New-HvVmCheckpoint.ps1 -ComputerName HV01 -VMName APP01,APP02 -CheckpointReason 'pre-patch'

    Checkpoints two VMs before patching.

.EXAMPLE
    .\New-HvVmCheckpoint.ps1 -ComputerName HV01 -WhatIf

    Shows which VMs would be checkpointed.

.NOTES
    Source use case      : #1 - Hyper-V VM Snapshot Creation
    Category             : Hyper-V
    Technology           : PowerShell / Hyper-V Module
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Checkpoint before patching; additive"

    Required permissions : Hyper-V Administrators on the host.
    Required modules     : Hyper-V
    Authentication       : Integrated Kerberos over PSRemoting; SCVMM cmdlets
                           where noted.

    Rollback             : A checkpoint is additive and can be removed with
                           Remove-HvVmCheckpoint. It changes nothing about the
                           running VM.
#>

#Requires -Version 5.1
#Requires -Modules Hyper-V

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string[]]$ComputerName = $env:COMPUTERNAME,

    [string[]]$VMName,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [ValidateNotNullOrEmpty()]
    [string]$CheckpointReason = 'pre-change',

    [ValidateRange(0,720)]
    [int]$SkipIfRecentHours = 4,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'New-HvVmCheckpoint'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #1 (Hyper-V)'

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

            $vms = if ($VMName) { Get-VM -Name $VMName @hvArgs } else { Get-VM @hvArgs }
            foreach ($vm in $vms) {
                if ($SkipIfRecentHours -gt 0) {
                    $recent = Get-VMSnapshot -VMName $vm.Name @hvArgs -ErrorAction SilentlyContinue |
                        Where-Object { $_.CreationTime -gt (Get-Date).AddHours(-$SkipIfRecentHours) }
                    if ($recent) {
                        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0}\{1}' -f $hv, $vm.Name) `
                            -Message ('Skipped - checkpoint taken within the last {0}h' -f $SkipIfRecentHours)
                        continue
                    }
                }
                $results.Add([PSCustomObject]@{
                    Name           = ('{0}\{1}' -f $hv, $vm.Name)
                    Id             = $vm.Id
                    VMName         = $vm.Name
                    HyperVHost     = $hv
                    State          = $vm.State
                    CheckpointType = $vm.CheckpointType
                    SnapshotName   = ('{0}-{1}-{2}' -f $vm.Name, $CheckpointReason, (Get-Date -Format 'yyyyMMdd-HHmmss'))
                })
            }
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

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Create VM checkpoint')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $hvArgs = @{ ComputerName = $item.HyperVHost; ErrorAction = 'Stop' }
            if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $hvArgs.Credential = $Credential }

            Checkpoint-VM -Name $item.VMName -SnapshotName $item.SnapshotName @hvArgs
            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Checkpoint created: {0}' -f $item.SnapshotName)
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'CheckpointCreated'; Detail = $item.SnapshotName; Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Hyper-V VM Snapshot Creation'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
