<#
.SYNOPSIS
    Reports Microsoft 365 service usage trends.

.DESCRIPTION
    Aggregates per-service activity from the Microsoft 365 usage reports -
    Exchange, Teams, SharePoint, OneDrive - giving adoption and utilisation
    figures at tenant level.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER Period
    Reporting period.

.PARAMETER Service
    Services to include.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-VivaInsightsUsageReport.ps1 -Period D30 -OutputFormat HTML

    Monthly usage trends as HTML.

.EXAMPLE
    .\Get-VivaInsightsUsageReport.ps1 -Service Teams -Period D7

    Weekly Teams usage only.

.NOTES
    Source use case      : #21 - Viva Insights Usage Report
    Category             : M365
    Technology           : Graph API / Viva
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Usage/productivity trends report"

    Required permissions : Microsoft Graph Reports.Read.All.
    Required modules     : Microsoft.Graph.Authentication, Microsoft.Graph.Reports
    Authentication       : App registration with certificate auth (app-only).

    Tenant usage reports may be pseudonymised: if "Display concealed user
    information" is on in the M365 admin centre, user names are replaced
    with opaque identifiers. That is a privacy setting, not a fault, and
    this script reports the data as returned.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication
#Requires -Modules Microsoft.Graph.Reports

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [ValidateSet('D7','D30','D90','D180')]
    [string]$Period = 'D30',

    [ValidateSet('Exchange','Teams','SharePoint','OneDrive','All')]
    [string[]]$Service = @('All'),

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-VivaInsightsUsageReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #21 (M365)'

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


        Connect-MgGraph -Scopes 'Reports.Read.All' -NoWelcome -ErrorAction Stop
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Microsoft Graph'

        $wanted = if ($Service -contains 'All') { @('Exchange','Teams','SharePoint','OneDrive') } else { $Service }

        $endpoints = @{
            Exchange   = "getEmailActivityUserDetail(period='{0}')"
            Teams      = "getTeamsUserActivityUserDetail(period='{0}')"
            SharePoint = "getSharePointActivityUserDetail(period='{0}')"
            OneDrive   = "getOneDriveActivityUserDetail(period='{0}')"
        }

        foreach ($svc in $wanted) {
            $tmp = [System.IO.Path]::GetTempFileName()
            try {
                $uri = 'https://graph.microsoft.com/v1.0/reports/' + ($endpoints[$svc] -f $Period)
                Invoke-MgGraphRequest -Method GET -Uri $uri -OutputFilePath $tmp -ErrorAction Stop
                $rows = @(Import-Csv -LiteralPath $tmp)
            } catch {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $svc `
                    -Message ('Usage report unavailable: {0}' -f $_.Exception.Message)
                continue
            } finally {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }

            # The "Last Activity Date" column is present across all four reports and is
            # the most reliable signal of whether an account actually uses the service.
            $active = @($rows | Where-Object { $_.'Last Activity Date' })
            $inactive = @($rows | Where-Object { -not $_.'Last Activity Date' })

            $results.Add([PSCustomObject]@{
                Name            = $svc
                Id              = $svc
                Period          = $Period
                TotalAccounts   = $rows.Count
                ActiveAccounts  = $active.Count
                InactiveAccounts= $inactive.Count
                AdoptionPercent = if ($rows.Count -gt 0) { [math]::Round(($active.Count / $rows.Count) * 100, 1) } else { $null }
                Concealed       = [bool]($rows | Where-Object { $_.'User Principal Name' -match '^[A-F0-9]{32,}$' } | Select-Object -First 1)
                ReportDate      = ($rows | Select-Object -First 1).'Report Refresh Date'
            })

            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $svc -Message (
                '{0} of {1} account(s) active over {2}' -f $active.Count, $rows.Count, $Period)
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Viva Insights Usage Report'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
