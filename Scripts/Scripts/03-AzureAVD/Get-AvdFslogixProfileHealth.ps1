<#
.SYNOPSIS
    Reports FSLogix profile containers that look unhealthy.

.DESCRIPTION
    Inspects the FSLogix profile share for containers that are oversized,
    stale, zero-length or left locked, and reports them. Repair is not
    attempted - the workbook gates it, and a profile container is the only
    copy of somebody's desktop.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER ProfileSharePath
    UNC path to the FSLogix profile share, e.g. \\\\server\\profiles.

.PARAMETER MaxSizeGB
    Report containers larger than this.

.PARAMETER StaleDays
    Report containers not written to in this many days.

.PARAMETER IssuesOnly
    Report only containers with a finding.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-AvdFslogixProfileHealth.ps1 -ProfileSharePath \\\\fs01\\fslogix -MaxSizeGB 30 -IssuesOnly

    Reports oversized, stale or locked containers.

.EXAMPLE
    .\Get-AvdFslogixProfileHealth.ps1 -ProfileSharePath \\\\fs01\\fslogix -StaleDays 180 -OutputFormat CSV -OutputPath .\\profiles.csv

    Full inventory as CSV.

.NOTES
    Source use case      : #5 - AVD FSLogix Profile Health Check
    Category             : Azure AVD
    Technology           : PowerShell / Az Storage
    Difficulty           : Medium
    Agent possible       : Partial
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Detect corrupted/oversized VHDx; report only, repair gated"

    Required permissions : Read access to the FSLogix profile share. No write access is needed or requested.
    Required modules     : none beyond IT-Automation-Common
    Authentication       : Inherits the Az context; managed identity preferred.

    REPORT ONLY, and the limits are worth stating. This inspects container
    FILES - size, timestamps, lock state, matching pairs. It does NOT
    mount a VHDX or check its internal filesystem, because mounting a
    profile container is itself a write operation against the only copy of
    a user's desktop, and doing it on a schedule to look for problems is
    how you cause them. Deep integrity checking belongs in a gated repair
    procedure with the user signed out, which the workbook already says is
    gated. A container held open by a live session is normal, not a fault
    - the report distinguishes the two by age.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory)]
    [string]$ProfileSharePath,

    [ValidateRange(1,2048)]
    [int]$MaxSizeGB = 30,

    [ValidateRange(1,3650)]
    [int]$StaleDays = 90,

    [switch]$IssuesOnly,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-AvdFslogixProfileHealth'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #5 (Azure AVD)'

    try {
        $config = if ($ConfigPath) { Get-AutomationConfig -Path $ConfigPath } else { Get-AutomationConfig }
        # Recorded so an audit can tell which environment a run targeted.
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Configuration loaded for environment: {0}' -f $config.environment)
    } catch {
        # Read-only: config only supplies optional notification endpoints,
        # so its absence must not stop a report from being produced.
        $config = $null
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
            'Config unavailable ({0}); continuing because this script only reads.' -f $_.Exception.Message)
    }

    $results  = [System.Collections.Generic.List[PSCustomObject]]::new()
    $failures = [System.Collections.Generic.List[PSCustomObject]]::new()
}

process {
    try {
        Connect-AutomationPlatform -Platform 'AzureAVD' | Out-Null


        if (-not (Test-Path -LiteralPath $ProfileSharePath)) {
            throw ('Profile share not reachable: {0}' -f $ProfileSharePath)
        }

        $containers = @(Get-ChildItem -LiteralPath $ProfileSharePath -Recurse -File -Include '*.vhdx', '*.vhd' `
            -ErrorAction SilentlyContinue)
        if ($containers.Count -eq 0) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'No profile containers found under {0}. Check the path and that this account can read it - ' +
                'an empty result here is more likely a permissions problem than an empty share.' -f $ProfileSharePath)
        }

        $now = Get-Date
        $maxBytes = $MaxSizeGB * 1GB

        foreach ($container in $containers) {
            $issues = @()
            $sizeGB = [math]::Round($container.Length / 1GB, 2)
            $ageDays = [math]::Round(($now - $container.LastWriteTime).TotalDays, 1)

            if ($container.Length -eq 0) {
                $issues += 'ZERO LENGTH - the container holds nothing'
            } elseif ($container.Length -gt $maxBytes) {
                $issues += ('oversized: {0} GB, over the {1} GB threshold' -f $sizeGB, $MaxSizeGB)
            }
            if ($ageDays -gt $StaleDays) {
                $issues += ('stale: not written in {0} day(s)' -f $ageDays)
            }

            # A container held open by a live session is normal. One held open and not
            # written for weeks is not.
            $isLocked = $false
            try {
                $stream = [System.IO.File]::Open($container.FullName, 'Open', 'Read', 'None')
                $stream.Close()
                $stream.Dispose()
            } catch {
                $isLocked = $true
            }
            if ($isLocked -and $ageDays -gt 1) {
                $issues += ('locked but not written in {0} day(s) - possibly an orphaned session' -f $ageDays)
            }

            # FSLogix writes ODFC containers alongside profile ones; a lone RW.VHDX
            # without its parent is a leftover from a failed operation.
            $isDifferencing = $container.Name -match '(?i)_RW\.vhdx?$'
            if ($isDifferencing) {
                $parentName = $container.Name -replace '(?i)_RW(\.vhdx?)$', '$1'
                $parentPath = Join-Path $container.DirectoryName $parentName
                if (-not (Test-Path -LiteralPath $parentPath)) {
                    $issues += 'differencing disk with no parent container - leftover from a failed operation'
                }
            }

            if ($IssuesOnly -and $issues.Count -eq 0) { continue }

            $results.Add([PSCustomObject]@{
                Name          = $container.Name
                Id            = $container.FullName
                FullPath      = $container.FullName
                Folder        = $container.DirectoryName
                SizeGB        = $sizeGB
                LastWriteTime = $container.LastWriteTime
                AgeDays       = $ageDays
                IsLocked      = $isLocked
                IsDifferencing= $isDifferencing
                Status        = if ($issues.Count) { 'Attention' } else { 'OK' }
                Issues        = ($issues -join '; ')
                RepairNote    = 'REPORT ONLY. Repair is gated per the SOP, and this script does not mount ' +
                                'containers - mounting is a write against the only copy of a user profile.'
            })

            if ($issues.Count) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $container.Name -Message ($issues -join '; ')
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

    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message ('Collected {0} record(s).' -f $candidates.Count)
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AVD FSLogix Profile Health Check'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
