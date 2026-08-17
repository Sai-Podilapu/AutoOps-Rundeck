<#
.SYNOPSIS
    Configures or removes mailbox forwarding, with external-destination
    checks.

.DESCRIPTION
    Sets or clears mail forwarding. Forwarding to an external address is a
    recognised data exfiltration technique and one of the first things an
    attacker configures after compromising a mailbox, so external destinations
    require approval and are checked against the tenant's outbound anti-spam
    policy before being proposed.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER Mailbox
    Mailbox to configure.

.PARAMETER Operation
    Set or Remove forwarding.

.PARAMETER ForwardingAddress
    Destination address. Required for Set.

.PARAMETER DeliverAndForward
    Keep a copy in the original mailbox. On by default - forwarding without a
    local copy hides the mail from the owner.

.PARAMETER AllowExternal
    Permit forwarding to a domain outside the tenant. Off by default.

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
    .\Set-ExoMailboxForwarding.ps1 -Mailbox user@contoso.com -Operation Set -ForwardingAddress colleague@contoso.com -TicketReference REQ0012345

    REQUEST mode - internal forwarding, raises an approval.

.EXAMPLE
    .\Set-ExoMailboxForwarding.ps1 -Mailbox user@contoso.com -Operation Remove -ApprovalReference APR-...

    Removes forwarding.

.NOTES
    Source use case      : #21 - Email Forwarding
    Category             : Exchange & O365
    Technology           : EXO PowerShell
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : High
    Human approval needed: YES
    Guardrails (col L)   : "Forwarding is a data-exfil vector; approval + external-forwarding policy check"

    Required permissions : Exchange Online Recipient Management.
    Required modules     : ExchangeOnlineManagement
    Authentication       : App-only certificate auth via
                           Connect-ExchangeOnline.

    DeliverAndForward defaults to true. Forwarding WITHOUT a local copy
    means the mailbox owner never sees the mail, which is the
    configuration used to hide activity from the victim during a
    compromise.

    Rollback             : Re-run with -Operation Remove, or restore the
                           previous destination, which is recorded in the audit
                           log before the change.
#>

#Requires -Version 5.1
#Requires -Modules ExchangeOnlineManagement

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory)]
    [string[]]$Mailbox,

    [Parameter(Mandatory)]
    [ValidateSet('Set','Remove')]
    [string]$Operation,

    [string]$ForwardingAddress,

    [bool]$DeliverAndForward = $true,

    [switch]$AllowExternal,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Mailbox forwarding change',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-ExoMailboxForwarding'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #21 (Exchange & O365)'

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

    # Risk = High: validate before doing anything at all.
    $pre = Test-Prerequisite -RequiredModule 'ExchangeOnlineManagement'
    if (-not $pre.Passed) {
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Message $pre.Summary
        throw $pre.Summary
    }
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Pre-flight passed.'

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

        if ($Operation -eq 'Set' -and -not $ForwardingAddress) {
            throw '-ForwardingAddress is required when -Operation is Set.'
        }

        $acceptedDomains = @((Get-AcceptedDomain -ErrorAction SilentlyContinue).DomainName)

        foreach ($mbx in $Mailbox) {
            $mb = Get-Mailbox -Identity $mbx -ErrorAction Stop

            $isExternal = $false
            if ($Operation -eq 'Set') {
                $destDomain = ($ForwardingAddress -split '@')[-1]
                $isExternal = ($acceptedDomains -notcontains $destDomain)

                if ($isExternal) {
                    if (-not $AllowExternal) {
                        throw ('Refusing: {0} is outside the tenant''s accepted domains. Pass -AllowExternal ' +
                               'and obtain approval if external forwarding is genuinely required.' -f $ForwardingAddress)
                    }
                    # Tenant policy may block it anyway - better to say so now than to
                    # set a rule that silently never delivers.
                    $outbound = Get-HostedOutboundSpamFilterPolicy -ErrorAction SilentlyContinue |
                                Select-Object -First 1
                    if ($outbound -and "$($outbound.AutoForwardingMode)" -eq 'Off') {
                        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $mbx -Message (
                            'Tenant outbound policy has AutoForwardingMode=Off. External forwarding will be blocked in transport ' +
                            'even once this mailbox setting is applied.')
                    }
                }
            }

            $results.Add([PSCustomObject]@{
                Name             = $mb.PrimarySmtpAddress
                Id               = $mb.Identity
                Operation        = $Operation
                CurrentForwarding= if ($mb.ForwardingSmtpAddress) { "$($mb.ForwardingSmtpAddress)" }
                                   elseif ($mb.ForwardingAddress) { "$($mb.ForwardingAddress)" } else { $null }
                CurrentDeliverAndForward = $mb.DeliverToMailboxAndForward
                NewForwarding    = if ($Operation -eq 'Set') { $ForwardingAddress } else { $null }
                DeliverAndForward= $DeliverAndForward
                IsExternal       = $isExternal
                RiskNote         = if ($isExternal) { 'EXTERNAL FORWARDING - recognised data exfiltration vector' }
                                   elseif ($Operation -eq 'Set') { 'Internal forwarding' }
                                   else { 'Removing forwarding' }
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Change mailbox forwarding', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Change mailbox forwarding')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
                'Prior forwarding: {0} (deliver and forward: {1})' -f
                $(if ($item.CurrentForwarding) { $item.CurrentForwarding } else { 'none' }), $item.CurrentDeliverAndForward)

            if ($item.Operation -eq 'Set') {
                if ($item.IsExternal) {
                    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
                        'Setting EXTERNAL forwarding to {0}. Approval={1} Ticket={2}' -f
                        $item.NewForwarding, $ApprovalReference, $TicketReference)
                }
                Set-Mailbox -Identity $item.Id -ForwardingSmtpAddress $item.NewForwarding `
                    -DeliverToMailboxAndForward $item.DeliverAndForward -ErrorAction Stop
                $detail = 'forwarding to {0} (local copy: {1})' -f $item.NewForwarding, $item.DeliverAndForward
            } else {
                Set-Mailbox -Identity $item.Id -ForwardingSmtpAddress $null -ForwardingAddress $null `
                    -DeliverToMailboxAndForward $true -ErrorAction Stop
                $detail = 'forwarding removed'
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Email Forwarding'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
