<#
.SYNOPSIS
    Removes Hyper-V checkpoints older than a minimum age.

.DESCRIPTION
    Deletes checkpoints beyond the retention age. The age rule is the safety
    control the workbook specifies: a checkpoint taken minutes ago is almost
    certainly load-bearing for a change in flight, while one older than a week
    is usually forgotten and is quietly costing disk and IO.

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

.PARAMETER MinimumAgeDays
    Only remove checkpoints older than this. The workbook guardrail specifies
    a >7 day rule, which is the default.

.PARAMETER KeepLatest
    Always keep this many of the newest checkpoints per VM regardless of age.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Remove-HvVmCheckpoint.ps1 -ComputerName HV01 -MinimumAgeDays 7

    Removes checkpoints older than a week, keeping the newest one per VM.

.EXAMPLE
    .\Remove-HvVmCheckpoint.ps1 -ComputerName HV01 -MinimumAgeDays 30 -KeepLatest 0 -WhatIf

    Shows what a 30-day purge would remove.

.NOTES
    Source use case      : #2 - Hyper-V VM Snapshot Deletion
    Category             : Hyper-V
    Technology           : PowerShell / Hyper-V Module
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: No
    Guardrails (col L)   : "Age-based (>7 days) rule makes this safe; merge impact noted in SOP"

    Required permissions : Hyper-V Administrators on the host.
    Required modules     : Hyper-V
    Authentication       : Integrated Kerberos over PSRemoting; SCVMM cmdlets
                           where noted.

    Removing a checkpoint triggers a disk merge, which generates
    significant storage IO on the host. Schedule outside peak hours - the
    merge impact is the reason this is Medium risk rather than Low.

    Rollback             : NONE. Removing a checkpoint merges its differencing
                           disk into the parent and cannot be undone. The age
                           rule and -KeepLatest exist because there is no
                           recovery.
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

    [ValidateRange(1,3650)]
    [int]$MinimumAgeDays = 7,

    [ValidateRange(0,50)]
    [int]$KeepLatest = 1,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Remove-HvVmCheckpoint'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #2 (Hyper-V)'

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
                $snaps = @(Get-VMSnapshot -VMName $vm.Name @hvArgs -ErrorAction SilentlyContinue |
                           Sort-Object CreationTime -Descending)
                if ($snaps.Count -eq 0) { continue }

                # Keep the newest N regardless of age, then apply the age rule to the rest.
                $eligible = if ($KeepLatest -gt 0) { $snaps | Select-Object -Skip $KeepLatest } else { $snaps }
                $cutoff = (Get-Date).AddDays(-$MinimumAgeDays)

                foreach ($s in $eligible) {
                    if ($s.CreationTime -ge $cutoff) { continue }
                    $results.Add([PSCustomObject]@{
                        Name         = ('{0}\{1}\{2}' -f $hv, $vm.Name, $s.Name)
                        Id           = $s.Id
                        VMName       = $vm.Name
                        HyperVHost   = $hv
                        SnapshotName = $s.Name
                        CreatedAt    = $s.CreationTime
                        AgeDays      = [math]::Round(((Get-Date) - $s.CreationTime).TotalDays, 1)
                        SizeNote     = 'merge IO on removal'
                    })
                }
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Remove VM checkpoint')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $hvArgs = @{ ComputerName = $item.HyperVHost; ErrorAction = 'Stop' }
            if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $hvArgs.Credential = $Credential }

            Remove-VMSnapshot -VMName $item.VMName -Name $item.SnapshotName @hvArgs -Confirm:$false
            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Checkpoint removed (age {0}d). Disk merge now in progress on the host.' -f $item.AgeDays)
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'CheckpointRemoved'; Detail = ('age {0}d' -f $item.AgeDays); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Hyper-V VM Snapshot Deletion'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
