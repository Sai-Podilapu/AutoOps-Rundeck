<#
.SYNOPSIS
    Reports Data Loss Prevention policy matches.

.DESCRIPTION
    Summarises DLP rule matches over the reporting window by policy, rule and
    action, so a rule generating constant false positives is visible as a
    single line rather than a stream of individual incidents.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER LookbackDays
    Reporting window in days.

.PARAMETER MinimumMatches
    Ignore rules with fewer matches than this.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-M365DlpMatchReport.ps1 -LookbackDays 7 -OutputFormat HTML

    Weekly DLP report as HTML.

.EXAMPLE
    .\Get-M365DlpMatchReport.ps1 -LookbackDays 30 -MinimumMatches 10

    Monthly view of the noisiest rules.

.NOTES
    Source use case      : #17 - M365 Data Loss Prevention Policy Report
    Category             : M365
    Technology           : Compliance API / PowerShell
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Weekly DLP rule-match report"

    Required permissions : Exchange Online View-Only Recipients plus Security Reader in the compliance portal.
    Required modules     : ExchangeOnlineManagement
    Authentication       : App registration with certificate auth (app-only).

    The DLP report aggregates by policy and rule rather than listing
    individual incidents. For per-incident detail, use the Purview
    compliance portal - deliberately not exported here, since incident
    bodies frequently contain the sensitive data that triggered the match.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules ExchangeOnlineManagement

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [ValidateRange(1,90)]
    [int]$LookbackDays = 7,

    [ValidateRange(1,100000)]
    [int]$MinimumMatches = 1,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-M365DlpMatchReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #17 (M365)'

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


        $exoParams = @{ ShowBanner = $false; ErrorAction = 'Stop' }
        if ($config -and $config.azure) {
            if ($config.azure.applicationId)         { $exoParams.AppId = $config.azure.applicationId }
            if ($config.azure.certificateThumbprint) { $exoParams.CertificateThumbprint = $config.azure.certificateThumbprint }
            if ($config.azure.tenantId)              { $exoParams.Organization = $config.azure.tenantId }
        }
        if (-not $exoParams.AppId) { throw 'Exchange Online requires app-only certificate auth (see config.json).' }
        Connect-ExchangeOnline @exoParams

        $end = Get-Date
        $start = $end.AddDays(-$LookbackDays)

        $report = @()
        try {
            $report = @(Get-DlpDetailReport -StartDate $start -EndDate $end -ErrorAction Stop)
        } catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'Get-DlpDetailReport unavailable ({0}). Falling back to the aggregate DLP report.' -f $_.Exception.Message)
            try { $report = @(Get-DlpDetectionsReport -StartDate $start -EndDate $end -ErrorAction Stop) } catch {
                throw ('No DLP reporting data available: {0}' -f $_.Exception.Message)
            }
        }

        $grouped = $report | Group-Object { $_.DlpPolicy }, { $_.TransportRule }

        foreach ($g in $grouped) {
            $first = $g.Group[0]
            if ($g.Count -lt $MinimumMatches) { continue }

            $ruleActions = @($g.Group | ForEach-Object { $_.Actions } | Where-Object { $_ } | Select-Object -Unique)
            $workloads = @($g.Group | ForEach-Object { $_.Workload } | Where-Object { $_ } | Select-Object -Unique)

            $results.Add([PSCustomObject]@{
                Name         = ('{0} / {1}' -f $first.DlpPolicy, $first.TransportRule)
                Id           = $first.TransportRule
                PolicyName   = $first.DlpPolicy
                RuleName     = $first.TransportRule
                MatchCount   = $g.Count
                Actions      = ($ruleActions -join '; ')
                Workloads    = ($workloads -join '; ')
                Severity     = $first.Severity
                FirstSeen    = ($g.Group.Date | Sort-Object | Select-Object -First 1)
                LastSeen     = ($g.Group.Date | Sort-Object | Select-Object -Last 1)
                TuningNote   = if ($g.Count -gt 100) { 'High match volume - review for false positives before treating as incidents' }
                               else { '' }
            })
        }

        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'DLP report: {0} rule(s) with matches over {1} day(s). Incident bodies are NOT exported.' -f
            $results.Count, $LookbackDays)
    } catch {
        $msg = $_.Exception.Message
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Message ('Discovery FAILED: {0}' -f $msg)
        $failures.Add([PSCustomObject]@{ Stage = 'Discovery'; Error = $msg })
    }
}

end {
    $candidates = @($results)

    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message ('Collected {0} record(s).' -f $candidates.Count)
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'M365 Data Loss Prevention Policy Report'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
