<#
.SYNOPSIS
    Reports Exchange Online mailbox health, quota usage and configuration
    risks.

.DESCRIPTION
    Collects mailbox statistics, quota headroom, litigation hold state,
    archive status and forwarding configuration. Quota is reported as headroom
    rather than raw size, because a 90GB mailbox is fine on a 100GB quota and
    a problem on a 50GB one.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER MailboxFilter
    Limit to mailboxes matching this identity filter.

.PARAMETER QuotaWarnPercent
    Flag a mailbox using at least this much of its quota.

.PARAMETER ResultSize
    Maximum mailboxes to examine.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-ExoHealthReport.ps1 -OutputFormat HTML

    Health report across the tenant.

.EXAMPLE
    .\Get-ExoHealthReport.ps1 -MailboxFilter user@contoso.com -OutputFormat JSON

    One mailbox in detail.

.NOTES
    Source use case      : #1 - Exchange Health Checks
    Category             : Exchange & O365
    Technology           : Exchange PowerShell
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Read-only"

    Required permissions : Exchange Online View-Only Recipients role.
    Required modules     : ExchangeOnlineManagement
    Authentication       : App-only certificate auth via
                           Connect-ExchangeOnline.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules ExchangeOnlineManagement

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string[]]$MailboxFilter,

    [ValidateRange(1,100)]
    [int]$QuotaWarnPercent = 85,

    [int]$ResultSize = 1000,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-ExoHealthReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #1 (Exchange & O365)'

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
        Connect-AutomationPlatform -Platform 'ExchangeOnline' | Out-Null


        $exoParams = @{ ShowBanner = $false; ErrorAction = 'Stop' }
        if ($config -and $config.azure) {
            if ($config.azure.applicationId)         { $exoParams.AppId = $config.azure.applicationId }
            if ($config.azure.certificateThumbprint) { $exoParams.CertificateThumbprint = $config.azure.certificateThumbprint }
            if ($config.azure.tenantId)              { $exoParams.Organization = $config.azure.tenantId }
        }
        if (-not $exoParams.AppId) {
            throw 'Exchange Online requires app-only certificate auth. Set azure.applicationId, ' +
                  'azure.certificateThumbprint and azure.tenantId in config.json.'
        }
        Connect-ExchangeOnline @exoParams
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Exchange Online (app-only certificate auth)'

        $mailboxes = if ($MailboxFilter) { $MailboxFilter | ForEach-Object { Get-Mailbox -Identity $_ -ErrorAction Stop } }
                     else                { Get-Mailbox -ResultSize $ResultSize }

        foreach ($mb in $mailboxes) {
            $stats = $null
            try { $stats = Get-MailboxStatistics -Identity $mb.Identity -ErrorAction Stop } catch {
                Write-Verbose ('No statistics for {0}' -f $mb.PrimarySmtpAddress)
            }

            # Quota strings look like "49.5 GB (53,150,220,288 bytes)"; the byte count
            # is the only part worth parsing.
            $quotaBytes = $null
            if ($mb.ProhibitSendReceiveQuota -and "$($mb.ProhibitSendReceiveQuota)" -match '\(([\d,]+) bytes\)') {
                $quotaBytes = [double]($Matches[1] -replace ',', '')
            }
            $usedBytes = $null
            if ($stats -and "$($stats.TotalItemSize)" -match '\(([\d,]+) bytes\)') {
                $usedBytes = [double]($Matches[1] -replace ',', '')
            }
            $pctUsed = if ($quotaBytes -gt 0 -and $null -ne $usedBytes) {
                           [math]::Round(($usedBytes / $quotaBytes) * 100, 1)
                       } else { $null }

            $issues = @()
            if ($null -ne $pctUsed -and $pctUsed -ge $QuotaWarnPercent) { $issues += ('quota {0}% used' -f $pctUsed) }
            if ($mb.ForwardingSmtpAddress)   { $issues += ('external forwarding to {0}' -f $mb.ForwardingSmtpAddress) }
            if ($mb.DeliverToMailboxAndForward -eq $false -and $mb.ForwardingAddress) { $issues += 'forwarding without local delivery' }
            if (-not $mb.LitigationHoldEnabled -and $mb.RecipientTypeDetails -eq 'UserMailbox') { $issues += 'no litigation hold' }

            $results.Add([PSCustomObject]@{
                Name              = $mb.PrimarySmtpAddress
                Id                = $mb.Identity
                DisplayName       = $mb.DisplayName
                MailboxType       = "$($mb.RecipientTypeDetails)"
                UsedGB            = if ($null -ne $usedBytes) { [math]::Round($usedBytes / 1GB, 2) } else { $null }
                QuotaGB           = if ($null -ne $quotaBytes) { [math]::Round($quotaBytes / 1GB, 2) } else { $null }
                QuotaPercentUsed  = $pctUsed
                ItemCount         = if ($stats) { $stats.ItemCount } else { $null }
                LastLogon         = if ($stats) { $stats.LastLogonTime } else { $null }
                ArchiveEnabled    = ($mb.ArchiveStatus -eq 'Active')
                LitigationHold    = $mb.LitigationHoldEnabled
                ForwardingSmtp    = $mb.ForwardingSmtpAddress
                HiddenFromGal     = $mb.HiddenFromAddressListsEnabled
                Status            = if ($issues.Count) { 'Warning' } else { 'OK' }
                Issues            = ($issues -join '; ')
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

    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message ('Collected {0} record(s).' -f $candidates.Count)
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Exchange Health Checks'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
