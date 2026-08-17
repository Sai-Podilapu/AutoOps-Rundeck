<#
.SYNOPSIS
    Adds or removes an email alias on a mailbox.

.DESCRIPTION
    Manages secondary SMTP addresses. Low risk and ticket-driven, so it
    executes directly - but the script refuses to remove the primary address,
    which would break mail flow to the mailbox entirely.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER Mailbox
    Mailbox to modify.

.PARAMETER Alias
    Alias address(es) to add or remove.

.PARAMETER Operation
    Add or Remove.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Set-ExoMailboxAlias.ps1 -Mailbox user@contoso.com -Alias sales@contoso.com -Operation Add

    Adds an alias.

.EXAMPLE
    .\Set-ExoMailboxAlias.ps1 -Mailbox user@contoso.com -Alias old@contoso.com -Operation Remove -WhatIf

    Shows the removal without applying it.

.NOTES
    Source use case      : #22 - Add/Remove Email Alias
    Category             : Exchange & O365
    Technology           : Graph API / Entra ID
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Low-risk, ticket-driven"

    Required permissions : Exchange Online Recipient Management.
    Required modules     : ExchangeOnlineManagement
    Authentication       : App-only certificate auth via
                           Connect-ExchangeOnline.

    Removing an alias that external senders still use causes silent
    non-delivery. Check message trace for recent traffic to the alias
    before removing it.

    Rollback             : Re-run with the opposite -Operation. The full prior
                           address list is recorded first.
#>

#Requires -Version 5.1
#Requires -Modules ExchangeOnlineManagement

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory)]
    [string[]]$Mailbox,

    [Parameter(Mandatory)]
    [string[]]$Alias,

    [Parameter(Mandatory)]
    [ValidateSet('Add','Remove')]
    [string]$Operation,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-ExoMailboxAlias'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #22 (Exchange & O365)'

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

        $acceptedDomains = @((Get-AcceptedDomain -ErrorAction SilentlyContinue).DomainName)

        foreach ($mbx in $Mailbox) {
            $mb = Get-Mailbox -Identity $mbx -ErrorAction Stop
            $current = @($mb.EmailAddresses | ForEach-Object { "$_" })

            foreach ($a in $Alias) {
                $smtpEntry = 'smtp:{0}' -f $a
                $primaryEntry = 'SMTP:{0}' -f $a

                # Never remove the primary - that breaks mail flow to the mailbox.
                if ($Operation -eq 'Remove' -and ($current -ccontains $primaryEntry)) {
                    throw ('Refusing to remove {0} - it is the PRIMARY address of {1}. Change the primary first.' -f
                           $a, $mb.PrimarySmtpAddress)
                }

                $exists = $current | Where-Object { $_ -ieq $smtpEntry -or $_ -ieq $primaryEntry }
                if (($Operation -eq 'Add' -and $exists) -or ($Operation -eq 'Remove' -and -not $exists)) {
                    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0} : {1}' -f $mbx, $a) `
                        -Message 'Skipped - alias already in the requested state (idempotent)'
                    continue
                }

                if ($Operation -eq 'Add') {
                    $domain = ($a -split '@')[-1]
                    if ($acceptedDomains -notcontains $domain) {
                        throw ('Refusing to add {0} - {1} is not an accepted domain in this tenant.' -f $a, $domain)
                    }
                }

                $results.Add([PSCustomObject]@{
                    Name           = ('{0} : {1} {2}' -f $mb.PrimarySmtpAddress, $Operation, $a)
                    Id             = $mb.Identity
                    Mailbox        = $mb.PrimarySmtpAddress
                    Alias          = $a
                    Operation      = $Operation
                    CurrentAddresses = ($current -join '; ')
                    AddressCount   = $current.Count
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Change mailbox alias')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
                'Prior addresses ({0}): {1}' -f $item.AddressCount, $item.CurrentAddresses)

            if ($item.Operation -eq 'Add') {
                Set-Mailbox -Identity $item.Id -EmailAddresses @{ Add = $item.Alias } -ErrorAction Stop
                $detail = 'alias {0} added' -f $item.Alias
            } else {
                Set-Mailbox -Identity $item.Id -EmailAddresses @{ Remove = $item.Alias } -ErrorAction Stop
                $detail = 'alias {0} removed' -f $item.Alias
            }

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message $detail
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = $item.Operation; Detail = $detail; Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Add/Remove Email Alias'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
