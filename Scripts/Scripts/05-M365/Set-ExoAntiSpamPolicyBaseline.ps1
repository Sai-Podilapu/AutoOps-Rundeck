<#
.SYNOPSIS
    Compares Exchange Online anti-spam policies against a baseline and applies
    approved changes.

.DESCRIPTION
    Reports each anti-spam policy setting that is weaker than a recommended
    baseline, and stops. How far to tighten a policy is a mail-flow decision
    with business impact, so the script makes no judgement of its own: it
    produces the deviation list, raises an approval artifact, and only applies
    a setting once a messaging admin has approved the reference and named the
    settings to apply.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

    AGENT-ASSIST ONLY. This automates the mechanical part - gathering,
    enriching and comparing against a baseline - and then stops, producing
    a decision-ready package. The judgement step is deliberately left to a
    human and is NOT scripted.

.PARAMETER BaselineFile
    JSON file of baseline settings. The built-in baseline is used when
    omitted.

.PARAMETER PolicyName
    Limit to specific policies.

.PARAMETER ApplySetting
    Restrict the change set to these setting names. All reported deviations
    when omitted.

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
    .\Set-ExoAntiSpamPolicyBaseline.ps1 -OutputFormat HTML

    REPORT ONLY. Compares every policy against the baseline and raises an
    approval.

.EXAMPLE
    .\Set-ExoAntiSpamPolicyBaseline.ps1 -ApprovalReference APR-... -ApplySetting PhishSpamAction,HighConfidencePhishAction

    Applies only the two phishing settings from an approved review.

.NOTES
    Source use case      : #16 - Exchange Online Anti-Spam Policy Review
    Category             : M365
    Technology           : EXO PowerShell
    Difficulty           : Medium
    Agent possible       : Partial
    Can execute with SOP : Partially - Agent Assists
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "Agent reports current policy vs baseline; deciding how far to tighten (mail-flow business impact) is messaging admin judgment"

    Required permissions : Exchange Online Hygiene Management role to apply changes; View-Only Configuration is enough to report.
    Required modules     : ExchangeOnlineManagement
    Authentication       : App registration with certificate auth (app-only).

    Tightening spam policy affects legitimate mail as well as spam.
    Quarantining instead of moving to junk, for instance, means users stop
    seeing false positives at all - which is safer and generates more
    helpdesk contact. That trade-off is the judgement this script refuses
    to make on its own; it is what the approval gate exists to capture.
    -ApplySetting lets an admin approve the review and then apply only
    part of it.

    Rollback             : Each change logs the previous value before it is
                           written. To revert, run
                           Set-HostedContentFilterPolicy -Identity <policy>
                           -<Setting> <previous value> using the CurrentValue
                           recorded in the audit log and the approval artifact.
#>

#Requires -Version 5.1
#Requires -Modules ExchangeOnlineManagement

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$BaselineFile,

    [string[]]$PolicyName,

    [string[]]$ApplySetting,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Anti-spam policy hardening',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-ExoAntiSpamPolicyBaseline'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #16 (M365)'

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
        Connect-AutomationPlatform -Platform 'Graph' | Out-Null


        $exoParams = @{ ShowBanner = $false; ErrorAction = 'Stop' }
        if ($config -and $config.azure) {
            if ($config.azure.applicationId)         { $exoParams.AppId = $config.azure.applicationId }
            if ($config.azure.certificateThumbprint) { $exoParams.CertificateThumbprint = $config.azure.certificateThumbprint }
            if ($config.azure.tenantId)              { $exoParams.Organization = $config.azure.tenantId }
        }
        if (-not $exoParams.AppId) { throw 'Exchange Online requires app-only certificate auth (see config.json).' }
        Connect-ExchangeOnline @exoParams

        # Conservative defaults reflecting common Microsoft guidance. Deliberately a
        # starting point for a conversation, not a target to be applied automatically.
        $baseline = @{
            SpamAction                 = 'Quarantine'
            HighConfidenceSpamAction   = 'Quarantine'
            PhishSpamAction            = 'Quarantine'
            HighConfidencePhishAction  = 'Quarantine'
            BulkSpamAction             = 'MoveToJmf'
            BulkThreshold              = 6
            MarkAsSpamBulkMail         = 'On'
            IncreaseScoreWithNumericIps = 'On'
            IncreaseScoreWithRedirectToOtherPort = 'On'
            EnableLanguageBlockList    = $false
            QuarantineRetentionPeriod  = 30
        }

        if ($BaselineFile) {
            if (-not (Test-Path -LiteralPath $BaselineFile)) { throw ('Baseline file not found: {0}' -f $BaselineFile) }
            $custom = Get-Content -LiteralPath $BaselineFile -Raw | ConvertFrom-Json
            $baseline = @{}
            foreach ($p in $custom.PSObject.Properties) { $baseline[$p.Name] = $p.Value }
        }

        $policies = if ($PolicyName) { $PolicyName | ForEach-Object { Get-HostedContentFilterPolicy -Identity $_ -ErrorAction Stop } }
                    else             { Get-HostedContentFilterPolicy -ErrorAction Stop }

        $reported = 0

        foreach ($pol in $policies) {
            foreach ($key in $baseline.Keys) {
                $actual = $pol.$key
                $expected = $baseline[$key]
                if ($null -eq $actual) { continue }
                if ("$actual" -eq "$expected") { continue }

                $reported++

                # Every deviation is reported. -ApplySetting narrows what may be
                # changed, so an admin can approve the whole review and act on part.
                if ($ApplySetting -and $ApplySetting -notcontains $key) {
                    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0}/{1}' -f $pol.Name, $key) `
                        -Message 'Deviation reported but excluded from the change set by -ApplySetting'
                    continue
                }

                $results.Add([PSCustomObject]@{
                    Name        = ('{0} / {1}' -f $pol.Name, $key)
                    Id          = "$($pol.Identity)"
                    PolicyName  = $pol.Name
                    PolicyId    = "$($pol.Identity)"
                    IsDefault   = $pol.IsDefault
                    Setting     = $key
                    CurrentValue= "$actual"
                    BaselineValue = "$expected"
                    BaselineRaw = $expected
                    Deviation   = ('{0} is "{1}", baseline suggests "{2}"' -f $key, $actual, $expected)
                    AdminDecision = 'Whether to tighten this depends on mail-flow impact - messaging admin judgement'
                })
            }
        }

        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Policy comparison complete. {0} deviation(s) found, {1} in the change set.' -f $reported, $results.Count)
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Apply anti-spam baseline setting', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Apply anti-spam baseline setting')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $setParams = @{ Identity = $item.PolicyId; ErrorAction = 'Stop' }
            $setParams[$item.Setting] = $item.BaselineRaw
            Set-HostedContentFilterPolicy @setParams

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Applied {0}: "{1}" -> "{2}". Previous value recorded here for rollback.' -f
                $item.Setting, $item.CurrentValue, $item.BaselineValue)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'BaselineApplied'
                Detail = ('{0}: {1} -> {2}' -f $item.Setting, $item.CurrentValue, $item.BaselineValue)
                Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Exchange Online Anti-Spam Policy Review'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
