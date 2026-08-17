<#
.SYNOPSIS
    Reports Defender for Office 365 email threat detections.

.DESCRIPTION
    Summarises phishing and malware detections over the reporting window by
    threat type and delivery outcome. Messages DELIVERED despite detection are
    separated from those blocked, since a delivered threat needs a response
    and a blocked one is a statistic.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER LookbackDays
    Reporting window in days.

.PARAMETER ThreatType
    Limit to specific threat classifications.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-M365EmailThreatReport.ps1 -LookbackDays 7 -OutputFormat HTML

    Weekly threat report as HTML.

.EXAMPLE
    .\Get-M365EmailThreatReport.ps1 -LookbackDays 1

    Daily summary.

.NOTES
    Source use case      : #19 - M365 Email Threat Report (Defender)
    Category             : M365
    Technology           : Graph API / Defender API
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Phishing/malware detection report"

    Required permissions : Exchange Online Security Reader plus View-Only Audit Logs.
    Required modules     : ExchangeOnlineManagement
    Authentication       : App registration with certificate auth (app-only).

    Defender detail reports cover the last 30 days at most, and the
    current day is always partial. For older data use the Defender portal
    export.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules ExchangeOnlineManagement

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [ValidateRange(1,30)]
    [int]$LookbackDays = 7,

    [string[]]$ThreatType,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-M365EmailThreatReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #19 (M365)'

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

        $detections = @()
        try {
            $detections = @(Get-MailDetailATPReport -StartDate $start -EndDate $end -ErrorAction Stop)
        } catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'Get-MailDetailATPReport unavailable ({0}). Falling back to the mail traffic ATP report.' -f $_.Exception.Message)
            try { $detections = @(Get-MailTrafficATPReport -StartDate $start -EndDate $end -ErrorAction Stop) } catch {
                throw ('No Defender reporting data available: {0}' -f $_.Exception.Message)
            }
        }

        $grouped = $detections | Group-Object { $_.EventType }, { $_.Action }

        foreach ($g in $grouped) {
            $first = $g.Group[0]
            if ($ThreatType -and $ThreatType -notcontains "$($first.EventType)") { continue }

            # "Delivered" outcomes are the ones that need a response.
            $delivered = "$($first.Action)" -match '(?i)deliver|junk|allow'

            $results.Add([PSCustomObject]@{
                Name         = ('{0} / {1}' -f $first.EventType, $first.Action)
                Id           = ('{0}-{1}' -f $first.EventType, $first.Action)
                ThreatType   = "$($first.EventType)"
                Action       = "$($first.Action)"
                MessageCount = $g.Count
                Delivered    = $delivered
                Direction    = "$($first.Direction)"
                TopSenders   = (($g.Group.SenderAddress | Group-Object | Sort-Object Count -Descending |
                                 Select-Object -First 5 | ForEach-Object { '{0}({1})' -f $_.Name, $_.Count }) -join '; ')
                TopRecipients= (($g.Group.RecipientAddress | Group-Object | Sort-Object Count -Descending |
                                 Select-Object -First 5 | ForEach-Object { '{0}({1})' -f $_.Name, $_.Count }) -join '; ')
                FirstSeen    = ($g.Group.Date | Sort-Object | Select-Object -First 1)
                LastSeen     = ($g.Group.Date | Sort-Object | Select-Object -Last 1)
                Status       = if ($delivered) { 'DELIVERED - needs response' } else { 'Blocked' }
            })

            if ($delivered) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $first.EventType -Message (
                    '{0} message(s) classified {1} were {2} - these reached mailboxes' -f
                    $g.Count, $first.EventType, $first.Action)
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'M365 Email Threat Report (Defender)'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
