<#
.SYNOPSIS
    Reports Send As permissions across mailboxes.

.DESCRIPTION
    Lists every Send As grant in scope. Because Send As is
    impersonation-capable and leaves no visible trace in delivered mail, this
    export is the practical way to audit who can send as whom.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER Mailbox
    Mailboxes to inspect. All mailboxes when omitted.

.PARAMETER ResultSize
    Maximum mailboxes to examine when -Mailbox is omitted.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-ExoSendAsPermission.ps1 -OutputFormat CSV

    Tenant-wide Send As audit.

.EXAMPLE
    .\Get-ExoSendAsPermission.ps1 -Mailbox shared@contoso.com

    Send As grants on one mailbox.

.NOTES
    Source use case      : #14 - Check 'Send As' Permissions
    Category             : Exchange & O365
    Technology           : Exchange/EXO PowerShell
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
    [string[]]$Mailbox,

    [int]$ResultSize = 500,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-ExoSendAsPermission'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #14 (Exchange & O365)'

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

        $mailboxes = if ($Mailbox) { $Mailbox | ForEach-Object { Get-Mailbox -Identity $_ -ErrorAction Stop } }
                     else          { Get-Mailbox -ResultSize $ResultSize }

        foreach ($mb in $mailboxes) {
            $perms = Get-RecipientPermission -Identity $mb.Identity -ErrorAction SilentlyContinue |
                     Where-Object { $_.AccessRights -contains 'SendAs' -and "$($_.Trustee)" -ne 'NT AUTHORITY\\SELF' }

            foreach ($p in $perms) {
                $results.Add([PSCustomObject]@{
                    Name        = ('{0} -> {1}' -f $p.Trustee, $mb.PrimarySmtpAddress)
                    Id          = $mb.Identity
                    Mailbox     = $mb.PrimarySmtpAddress
                    MailboxType = "$($mb.RecipientTypeDetails)"
                    Trustee     = "$($p.Trustee)"
                    AccessRights= ($p.AccessRights -join ',')
                    RiskNote    = 'Impersonation-capable - sent mail is indistinguishable from the owner'
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

    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message ('Collected {0} record(s).' -f $candidates.Count)
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Check ''Send As'' Permissions'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
