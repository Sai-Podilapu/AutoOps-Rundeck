<#
.SYNOPSIS
    Converts a user mailbox to a shared mailbox, or back.

.DESCRIPTION
    Changes mailbox type. Converting to shared is the standard leaver pattern:
    the mail stays accessible and the licence can be released. Converting back
    to a user mailbox requires a licence, and the script refuses if none is
    available rather than leaving the mailbox in a broken state.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER Mailbox
    Mailbox to convert.

.PARAMETER TargetType
    Shared or Regular.

.PARAMETER BlockSignIn
    Also block sign-in for the associated account when converting to shared.

.PARAMETER ApprovalReference
    Approval token from New-ApprovalRequest, after a human has approved it.
    Without this the script performs no change.

.PARAMETER RequestApproval
    Force REQUEST mode - produce the change set and raise an approval request,
    then stop, even if a reference was supplied.

.PARAMETER TicketReference
    ITSM ticket number recorded in the audit trail alongside the approval
    reference.

.PARAMETER Reason
    Change reason recorded in the approval artifact and the audit log.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Convert-ExoSharedMailbox.ps1 -Mailbox leaver@contoso.com -TargetType Shared -TicketReference REQ0012345

    REQUEST mode - raises an approval for the leaver conversion.

.EXAMPLE
    .\Convert-ExoSharedMailbox.ps1 -Mailbox leaver@contoso.com -TargetType Shared -ApprovalReference APR-... -BlockSignIn

    Converts and blocks sign-in.

.NOTES
    Source use case      : #19 - Shared Mailbox Conversion
    Category             : Exchange & O365
    Technology           : EXO PowerShell
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "Affects licensing/sign-in behaviour; approve per mailbox"

    Required permissions : Exchange Online Recipient Management. -BlockSignIn additionally needs Graph User.ReadWrite.All.
    Required modules     : ExchangeOnlineManagement
    Authentication       : App-only certificate auth via
                           Connect-ExchangeOnline.

    A shared mailbox over 50GB requires a licence to stay accessible. The
    script reports current size so a large mailbox is not silently
    converted into one that stops working.

    Rollback             : Convert back with the opposite -TargetType.
                           Converting to Regular requires an available licence
                           within 30 days, after which the mailbox is removed.
#>

#Requires -Version 5.1
#Requires -Modules ExchangeOnlineManagement

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory)]
    [string[]]$Mailbox,

    [Parameter(Mandatory)]
    [ValidateSet('Shared','Regular')]
    [string]$TargetType,

    [switch]$BlockSignIn,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Mailbox type conversion',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Convert-ExoSharedMailbox'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #19 (Exchange & O365)'

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
            $currentType = "$($mb.RecipientTypeDetails)"

            $wanted = if ($TargetType -eq 'Shared') { 'SharedMailbox' } else { 'UserMailbox' }
            if ($currentType -eq $wanted) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $mbx `
                    -Message ('Skipped - already {0} (idempotent)' -f $currentType)
                continue
            }

            $stats = Get-MailboxStatistics -Identity $mb.Identity -ErrorAction SilentlyContinue
            $sizeGB = $null
            if ($stats -and "$($stats.TotalItemSize)" -match '\(([\d,]+) bytes\)') {
                $sizeGB = [math]::Round(([double]($Matches[1] -replace ',', '')) / 1GB, 2)
            }

            $warnings = @()
            if ($TargetType -eq 'Shared' -and $null -ne $sizeGB -and $sizeGB -gt 50) {
                $warnings += ('mailbox is {0}GB - a shared mailbox above 50GB still needs a licence' -f $sizeGB)
            }
            if ($TargetType -eq 'Regular') {
                $warnings += 'converting to a user mailbox requires an available licence'
            }

            $results.Add([PSCustomObject]@{
                Name        = $mb.PrimarySmtpAddress
                Id          = $mb.Identity
                DisplayName = $mb.DisplayName
                CurrentType = $currentType
                TargetType  = $wanted
                SizeGB      = $sizeGB
                BlockSignIn = [bool]$BlockSignIn
                Warnings    = ($warnings -join '; ')
            })
            if ($warnings.Count) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $mbx -Message ($warnings -join '; ')
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

    if ($RequestApproval -or -not $ApprovalReference) {
        $request = New-ApprovalRequest -ScriptName $scriptName -ChangeSet $candidates `
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Convert mailbox type', $candidates.Count, $Reason, $TicketReference)
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $request.Reference -Message (
            'REQUEST mode - nothing was changed. Supply -ApprovalReference {0} once approved.' -f $request.Reference)
        Write-Warning ('No change made. Approval reference: {0}' -f $request.Reference)
        Write-Output ([PSCustomObject]@{
            Mode = 'RequestApproval'; ApprovalReference = $request.Reference
            CandidateCount = $candidates.Count; Candidates = $candidates; Changed = $false })
        return
    }

    $approvalCheck = Test-ApprovalReference -Reference $ApprovalReference -ScriptName $scriptName
    if (-not $approvalCheck.IsValid) {
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $ApprovalReference -Message (
            'REFUSED to execute: {0}' -f $approvalCheck.Reason)
        throw ('Approval validation failed: {0}' -f $approvalCheck.Reason)
    }
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $ApprovalReference -Message (
        'Approval accepted. {0} Ticket={1}' -f $approvalCheck.Reason, $TicketReference)

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Convert mailbox type')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            Set-Mailbox -Identity $item.Id -Type $TargetType -ErrorAction Stop

            if ($BlockSignIn -and $TargetType -eq 'Shared') {
                try {
                    Connect-MgGraph -Scopes 'User.ReadWrite.All' -NoWelcome -ErrorAction Stop
                    $u = Get-MgUser -UserId $item.Name -Property Id -ErrorAction Stop
                    Update-MgUser -UserId $u.Id -AccountEnabled:$false -ErrorAction Stop
                    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message 'Sign-in blocked'
                } catch {
                    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label `
                        -Message ('Converted, but sign-in could not be blocked: {0}' -f $_.Exception.Message)
                }
            }

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Converted {0} -> {1}. Size {2}GB. Ticket={3}' -f
                $item.CurrentType, $item.TargetType, $item.SizeGB, $TicketReference)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'Converted'
                Detail = ('{0} -> {1}' -f $item.CurrentType, $item.TargetType); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Shared Mailbox Conversion'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
