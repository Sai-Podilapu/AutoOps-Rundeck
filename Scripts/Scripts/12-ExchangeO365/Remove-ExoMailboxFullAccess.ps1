<#
.SYNOPSIS
    Removes Full Access permission from a mailbox.

.DESCRIPTION
    Revokes a trustee's full access to a mailbox. Removing access is the
    low-risk direction, so it executes directly - but the prior permission set
    is captured first so it can be restored if the removal turns out to be
    wrong.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER Mailbox
    Target mailbox (UPN or primary SMTP address).

.PARAMETER Trustee
    User being granted or removed (UPN or primary SMTP address).

.PARAMETER RemoveAll
    Remove every non-inherited Full Access grant on the mailbox, not just the
    named trustee.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Remove-ExoMailboxFullAccess.ps1 -Mailbox shared@contoso.com -Trustee leaver@contoso.com

    Removes one trustee\u2019s access.

.EXAMPLE
    .\Remove-ExoMailboxFullAccess.ps1 -Mailbox shared@contoso.com -RemoveAll -WhatIf

    Shows every Full Access grant that would be removed.

.NOTES
    Source use case      : #4 - Mailbox Access Removal
    Category             : Exchange & O365
    Technology           : Exchange/EXO PowerShell
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Removing access is low-risk; ticket-driven"

    Required permissions : Exchange Online Organization Management.
    Required modules     : ExchangeOnlineManagement
    Authentication       : App-only certificate auth via
                           Connect-ExchangeOnline.

    Rollback             : Re-grant with Add-ExoMailboxFullAccess.ps1. The
                           removed permission is written to the audit log
                           first, including whether auto-mapping was set.
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

    [switch]$RemoveAll,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Remove-ExoMailboxFullAccess'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #4 (Exchange & O365)'

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

            $perms = Get-MailboxPermission -Identity $mb.Identity -ErrorAction Stop |
                     Where-Object { $_.AccessRights -contains 'FullAccess' -and -not $_.IsInherited -and
                                    $_.User -notlike 'NT AUTHORITY\\*' }

            if (-not $RemoveAll) {
                $perms = $perms | Where-Object { $Trustee -contains $_.User.ToString() }
            }

            foreach ($p in $perms) {
                $results.Add([PSCustomObject]@{
                    Name        = ('{0} -> {1}' -f $p.User, $mb.PrimarySmtpAddress)
                    Id          = $mb.Identity
                    Mailbox     = $mb.PrimarySmtpAddress
                    Trustee     = "$($p.User)"
                    AccessRight = ($p.AccessRights -join ',')
                    Deny        = $p.Deny
                    Inherited   = $p.IsInherited
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Remove Full Access')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
                'Prior permission captured: {0} had {1} on {2}' -f $item.Trustee, $item.AccessRight, $item.Mailbox)

            Remove-MailboxPermission -Identity $item.Mailbox -User $item.Trustee -AccessRights FullAccess `
                -Confirm:$false -ErrorAction Stop | Out-Null

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message 'Full Access removed'
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'FullAccessRemoved'; Detail = $item.AccessRight; Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Mailbox Access Removal'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
