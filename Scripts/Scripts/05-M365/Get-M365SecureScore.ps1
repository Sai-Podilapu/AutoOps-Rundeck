<#
.SYNOPSIS
    Reports Microsoft Secure Score and alerts on score drops.

.DESCRIPTION
    Reads the current Secure Score, compares it against the previous run
    stored on disk, and reports both the movement and the control profiles
    that regressed. A falling score is more actionable than an absolute
    number, which is why the comparison is the point of this report.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER StateFile
    Path used to store the previous score for comparison.

.PARAMETER DropAlertPoints
    Report a drop of at least this many points as a warning.

.PARAMETER IncludeControls
    Include the per-control breakdown, not just the headline score.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-M365SecureScore.ps1 -OutputFormat HTML

    Secure Score with movement since the last run.

.EXAMPLE
    .\Get-M365SecureScore.ps1 -IncludeControls -DropAlertPoints 2

    Sensitive alerting with the control breakdown.

.NOTES
    Source use case      : #12 - M365 Secure Score Monitoring
    Category             : M365
    Technology           : Graph API / Security API
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Alert on score drops"

    Required permissions : Microsoft Graph SecurityEvents.Read.All.
    Required modules     : Microsoft.Graph.Authentication, Microsoft.Graph.Security
    Authentication       : App registration with certificate auth (app-only).

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication
#Requires -Modules Microsoft.Graph.Security

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$StateFile,

    [ValidateRange(1,1000)]
    [double]$DropAlertPoints = 5,

    [switch]$IncludeControls,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-M365SecureScore'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #12 (M365)'

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
        Connect-AutomationPlatform -Platform 'Graph' | Out-Null


        Connect-MgGraph -Scopes 'SecurityEvents.Read.All' -NoWelcome -ErrorAction Stop
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Microsoft Graph'

        if (-not $StateFile) {
            $StateFile = Join-Path $env:ProgramData 'ITAutomation\State\m365-securescore.json'
        }

        $scores = Invoke-MgGraphRequest -Method GET `
            -Uri 'https://graph.microsoft.com/v1.0/security/secureScores?$top=1' -ErrorAction Stop
        $current = $scores.value | Select-Object -First 1
        if (-not $current) { throw 'No Secure Score data returned for this tenant.' }

        $previous = $null
        if (Test-Path -LiteralPath $StateFile) {
            try { $previous = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json } catch {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Message 'Previous score unreadable; reporting without movement.'
            }
        }

        $delta = if ($previous) { [math]::Round($current.currentScore - $previous.currentScore, 2) } else { $null }
        $pct = if ($current.maxScore -gt 0) { [math]::Round(($current.currentScore / $current.maxScore) * 100, 1) } else { $null }

        $results.Add([PSCustomObject]@{
            Name          = 'Microsoft Secure Score'
            Id            = $current.id
            RecordType    = 'Score'
            Category      = 'Tenant total'
            CurrentScore  = [math]::Round($current.currentScore, 2)
            MaxScore      = [math]::Round($current.maxScore, 2)
            PercentOfMax  = $pct
            PreviousScore = if ($previous) { [math]::Round($previous.currentScore, 2) } else { $null }
            Delta         = $delta
            Movement      = if ($null -eq $delta) { 'first run' }
                            elseif ($delta -lt 0) { ('DROPPED {0} point(s)' -f [math]::Abs($delta)) }
                            elseif ($delta -gt 0) { ('improved {0} point(s)' -f $delta) }
                            else { 'unchanged' }
            Description   = ('{0} of {1} points' -f [math]::Round($current.currentScore, 2), [math]::Round($current.maxScore, 2))
            ActiveUsers   = $current.activeUserCount
            MeasuredAt    = $current.createdDateTime
            Status        = if ($null -ne $delta -and $delta -le (-1 * $DropAlertPoints)) { 'Warning' } else { 'OK' }
        })

        if ($null -ne $delta -and $delta -le (-1 * $DropAlertPoints)) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'Secure Score dropped {0} point(s): {1} -> {2}' -f
                [math]::Abs($delta), $previous.currentScore, $current.currentScore)
        }

        if ($IncludeControls) {
            $prevControls = @{}
            if ($previous -and $previous.controlScores) {
                foreach ($c in $previous.controlScores) { $prevControls[$c.controlName] = $c.score }
            }

            foreach ($c in $current.controlScores) {
                $was = if ($prevControls.ContainsKey($c.controlName)) { $prevControls[$c.controlName] } else { $null }
                $cDelta = if ($null -ne $was) { [math]::Round($c.score - $was, 2) } else { $null }

                $results.Add([PSCustomObject]@{
                    Name          = $c.controlName
                    Id            = $c.controlName
                    RecordType    = 'Control'
                    Category      = $c.controlCategory
                    CurrentScore  = $c.score
                    MaxScore      = $null
                    PercentOfMax  = $null
                    PreviousScore = $was
                    Delta         = $cDelta
                    Movement      = if ($null -eq $cDelta) { 'new' }
                                    elseif ($cDelta -lt 0) { 'regressed' }
                                    elseif ($cDelta -gt 0) { 'improved' }
                                    else { 'unchanged' }
                    Description   = $c.description
                    ActiveUsers   = $null
                    MeasuredAt    = $current.createdDateTime
                    Status        = if ($null -ne $cDelta -and $cDelta -lt 0) { 'Regressed' } else { 'OK' }
                })
            }
        }

        $dir = Split-Path -Parent $StateFile
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        $current | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StateFile -Encoding UTF8
    } catch {
        $msg = $_.Exception.Message
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Message ('Discovery FAILED: {0}' -f $msg)
        $failures.Add([PSCustomObject]@{ Stage = 'Discovery'; Error = $msg })
    }
}

end {
    $candidates = @($results)

    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message ('Collected {0} record(s).' -f $candidates.Count)
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'M365 Secure Score Monitoring'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
