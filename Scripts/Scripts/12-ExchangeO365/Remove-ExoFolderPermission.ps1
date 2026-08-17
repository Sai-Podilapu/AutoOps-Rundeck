<#
.SYNOPSIS
    Removes an explicit permission from a mailbox folder.

.DESCRIPTION
    Revokes folder-level access for a trustee. Low risk and ticket-driven, so
    it executes directly, recording the prior access right first.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER Mailbox
    Target mailbox (UPN or primary SMTP address).

.PARAMETER Trustee
    User being granted or removed (UPN or primary SMTP address).

.PARAMETER FolderPath
    Folder relative to the mailbox root, e.g. :\\Calendar.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Remove-ExoFolderPermission.ps1 -Mailbox user@contoso.com -Trustee leaver@contoso.com -FolderPath ':\\Calendar'

    Removes calendar access.

.EXAMPLE
    .\Remove-ExoFolderPermission.ps1 -Mailbox user@contoso.com -Trustee leaver@contoso.com -FolderPath ':\\Calendar' -WhatIf

    Shows the removal without applying it.

.NOTES
    Source use case      : #10 - Removal of Explicit Folder Permission
    Category             : Exchange & O365
    Technology           : Exchange/EXO PowerShell
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Ticket-driven"

    Required permissions : Exchange Online Organization Management.
    Required modules     : ExchangeOnlineManagement
    Authentication       : App-only certificate auth via
                           Connect-ExchangeOnline.

    Rollback             : Re-grant with Add-ExoFolderPermission.ps1 using the
                           access right recorded in the audit log.
#>

#Requires -Version 5.1
#Requires -Modules ExchangeOnlineManagement

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory)]
    [string[]]$Mailbox,

    [Parameter(Mandatory)]
    [string[]]$Trustee,

    [Parameter(Mandatory)]
    [string]$FolderPath,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Remove-ExoFolderPermission'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #10 (Exchange & O365)'

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
            $folderId = '{0}{1}' -f $mb.PrimarySmtpAddress, $FolderPath

            foreach ($tr in $Trustee) {
                $existing = Get-MailboxFolderPermission -Identity $folderId -User $tr -ErrorAction SilentlyContinue
                if (-not $existing) {
                    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0} -> {1}' -f $tr, $folderId) `
                        -Message 'Skipped - no explicit permission (idempotent)'
                    continue
                }
                $results.Add([PSCustomObject]@{
                    Name        = ('{0} -> {1}{2}' -f $tr, $mb.PrimarySmtpAddress, $FolderPath)
                    Id          = $folderId
                    Mailbox     = $mb.PrimarySmtpAddress
                    FolderPath  = $FolderPath
                    FolderId    = $folderId
                    Trustee     = $tr
                    AccessRight = ($existing.AccessRights -join ',')
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Remove folder permission')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
                'Prior access right captured: {0}' -f $item.AccessRight)

            Remove-MailboxFolderPermission -Identity $item.FolderId -User $item.Trustee `
                -Confirm:$false -ErrorAction Stop | Out-Null

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message 'Folder permission removed'
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'FolderPermissionRemoved'; Detail = $item.AccessRight; Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Removal of Explicit Folder Permission'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
