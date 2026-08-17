<#
.SYNOPSIS
    Reports Entra ID risky sign-ins and risk detections.

.DESCRIPTION
    Lists sign-ins Identity Protection classified as risky, with the risk
    level, detection type and whether the sign-in ultimately succeeded. A
    risky sign-in that SUCCEEDED is the finding that matters; a blocked one is
    the control working.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER LookbackDays
    Reporting window in days.

.PARAMETER MinimumRiskLevel
    Lowest risk level to include.

.PARAMETER MaxRecords
    Maximum sign-ins to retrieve.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-EntraRiskySignInReport.ps1 -LookbackDays 1 -MinimumRiskLevel medium

    Daily risky sign-in report.

.EXAMPLE
    .\Get-EntraRiskySignInReport.ps1 -LookbackDays 7 -MinimumRiskLevel high -OutputFormat HTML

    Weekly high-risk report.

.NOTES
    Source use case      : #18 - Entra ID Sign-In Risk Report
    Category             : M365
    Technology           : Graph API / Identity Protection
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Daily risky sign-in report"

    Required permissions : Microsoft Graph IdentityRiskEvent.Read.All and AuditLog.Read.All. Requires Entra ID P2 for full risk detail.
    Required modules     : Microsoft.Graph.Authentication, Microsoft.Graph.Identity.SignIns
    Authentication       : App registration with certificate auth (app-only).

    Risk-based reporting requires Entra ID P2. With P1 the risk level
    appears but the detection detail does not, and with neither the
    endpoints return nothing - which the script reports as missing
    licensing rather than as a clean result.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication
#Requires -Modules Microsoft.Graph.Identity.SignIns

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [ValidateRange(1,30)]
    [int]$LookbackDays = 1,

    [ValidateSet('low','medium','high')]
    [string]$MinimumRiskLevel = 'medium',

    [ValidateRange(10,10000)]
    [int]$MaxRecords = 1000,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-EntraRiskySignInReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #18 (M365)'

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


        Connect-MgGraph -Scopes 'AuditLog.Read.All','IdentityRiskEvent.Read.All','Directory.Read.All' -NoWelcome -ErrorAction Stop
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Microsoft Graph'

        $since = (Get-Date).AddDays(-$LookbackDays).ToString('yyyy-MM-ddTHH:mm:ssZ')

        $levels = switch ($MinimumRiskLevel) {
            'low'    { @('low','medium','high') }
            'medium' { @('medium','high') }
            'high'   { @('high') }
        }
        $levelFilter = ($levels | ForEach-Object { "riskLevelDuringSignIn eq '$_'" }) -join ' or '
        $filter = "createdDateTime ge $since and ($levelFilter)"

        $signIns = @()
        try {
            $signIns = @(Get-MgAuditLogSignIn -Filter $filter -Top $MaxRecords -ErrorAction Stop)
        } catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'Risky sign-in data unavailable: {0}. This usually means the tenant lacks Entra ID P2.' -f $_.Exception.Message)
            return
        }

        if ($signIns.Count -eq 0) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
                'No risky sign-ins at level {0} or above in the last {1} day(s).' -f $MinimumRiskLevel, $LookbackDays)
        }

        foreach ($s in $signIns) {
            $succeeded = ($s.Status.ErrorCode -eq 0)

            $results.Add([PSCustomObject]@{
                Name            = $s.UserPrincipalName
                Id              = $s.Id
                UserDisplayName = $s.UserDisplayName
                SignInTime      = $s.CreatedDateTime
                AppDisplayName  = $s.AppDisplayName
                IpAddress       = $s.IPAddress
                City            = $s.Location.City
                Country         = $s.Location.CountryOrRegion
                DeviceOs        = $s.DeviceDetail.OperatingSystem
                DeviceBrowser   = $s.DeviceDetail.Browser
                RiskLevel       = "$($s.RiskLevelDuringSignIn)"
                RiskState       = "$($s.RiskState)"
                RiskDetail      = "$($s.RiskDetail)"
                RiskEventTypes  = ($s.RiskEventTypesV2 -join '; ')
                ConditionalAccessStatus = "$($s.ConditionalAccessStatus)"
                Succeeded       = $succeeded
                ErrorCode       = $s.Status.ErrorCode
                FailureReason   = $s.Status.FailureReason
                Status          = if ($succeeded) { 'RISKY SIGN-IN SUCCEEDED' } else { 'Blocked' }
            })

            if ($succeeded) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $s.UserPrincipalName -Message (
                    'Risky sign-in SUCCEEDED: {0} risk from {1} ({2}) at {3:u}' -f
                    $s.RiskLevelDuringSignIn, $s.IPAddress, $s.Location.CountryOrRegion, $s.CreatedDateTime)
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Entra ID Sign-In Risk Report'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
