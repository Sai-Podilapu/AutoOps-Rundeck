<#
.SYNOPSIS
    Reports explicit permissions on mailbox folders.

.DESCRIPTION
    Lists folder-level permissions for the specified folders, excluding the
    Default and Anonymous entries unless asked for, since those are almost
    always noise in a review.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER Mailbox
    Mailboxes to inspect.

.PARAMETER FolderPath
    Folders to inspect.

.PARAMETER IncludeDefault
    Include the Default and Anonymous pseudo-users.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-ExoFolderPermission.ps1 -Mailbox user@contoso.com

    Calendar and Inbox permissions for one mailbox.

.EXAMPLE
    .\Get-ExoFolderPermission.ps1 -Mailbox user@contoso.com -FolderPath ':\\Calendar' -IncludeDefault

    Calendar only, including the Default entry.

.NOTES
    Source use case      : #11 - Explicit Folder Permission Check
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
    [Parameter(Mandatory)]
    [string[]]$Mailbox,

    [string[]]$FolderPath = @(':\\Calendar', ':\\Inbox'),

    [switch]$IncludeDefault,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-ExoFolderPermission'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #11 (Exchange & O365)'

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

        foreach ($mbx in $Mailbox) {
            $mb = Get-Mailbox -Identity $mbx -ErrorAction Stop

            foreach ($fp in $FolderPath) {
                $folderId = '{0}{1}' -f $mb.PrimarySmtpAddress, $fp
                $perms = $null
                try { $perms = Get-MailboxFolderPermission -Identity $folderId -ErrorAction Stop }
                catch {
                    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $folderId `
                        -Message ('Folder not found or unreadable: {0}' -f $_.Exception.Message)
                    continue
                }

                foreach ($p in $perms) {
                    $user = "$($p.User)"
                    if (-not $IncludeDefault -and $user -in @('Default','Anonymous')) { continue }

                    $results.Add([PSCustomObject]@{
                        Name         = ('{0} -> {1}{2}' -f $user, $mb.PrimarySmtpAddress, $fp)
                        Id           = $folderId
                        Mailbox      = $mb.PrimarySmtpAddress
                        FolderPath   = $fp
                        Trustee      = $user
                        AccessRights = ($p.AccessRights -join ',')
                        SharingPermissionFlags = "$($p.SharingPermissionFlags)"
                        IsDefault    = ($user -in @('Default','Anonymous'))
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

    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message ('Collected {0} record(s).' -f $candidates.Count)
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Explicit Folder Permission Check'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
