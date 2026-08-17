<#
.SYNOPSIS
    Triages Sentinel phishing incidents, closing only high-confidence known
    patterns.

.DESCRIPTION
    Classifies open phishing incidents against a file of known high-confidence
    patterns. Those that match are closed with a classification; everything
    else is left open and reported for an analyst. Sender blocking is not
    performed at all - the workbook assigns that decision to an analyst and
    this script does not take it.

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

.PARAMETER SubscriptionId
    Azure subscription to operate in. The current context when omitted.

.PARAMETER ResourceGroupName
    Resource group holding the Sentinel workspace.

.PARAMETER WorkspaceName
    Log Analytics workspace Sentinel runs on.

.PARAMETER KnownPatternFile
    JSON file of high-confidence patterns. An incident matching one of these
    is eligible for automatic closure; nothing else is.

.PARAMETER LookbackHours
    Only consider incidents created within this window.

.PARAMETER IncidentTitleFilter
    Substring identifying phishing incidents.

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
    .\Invoke-SentinelPhishingTriage.ps1 -ResourceGroupName rg-sec -WorkspaceName law-sec -KnownPatternFile .\\patterns.json

    REPORT ONLY. Classifies incidents and raises an approval.

.EXAMPLE
    .\Invoke-SentinelPhishingTriage.ps1 -ResourceGroupName rg-sec -WorkspaceName law-sec -KnownPatternFile .\\patterns.json -ApprovalReference APR-...

    Closes the high-confidence matches.

.NOTES
    Source use case      : #2 - Microsoft Sentinel SOAR Playbook - Phishing
    Category             : Security Cloud
    Technology           : Sentinel / Logic Apps
    Difficulty           : High
    Agent possible       : Partial
    Can execute with SOP : Partially - Agent Assists
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "Playbook auto-handles high-confidence known patterns; ambiguous phishing verdicts and sender-block decisions need an analyst"

    Required permissions : Microsoft Sentinel Responder on the workspace.
    Required modules     : Az.Accounts
    Authentication       : Vendor REST API via Invoke-RestMethod, or Graph
                           where the tool is Microsoft.

    ASSIST-ONLY. Two things are deliberately not automated. Ambiguous
    verdicts stay open and are reported, because a phishing incident
    closed wrongly is a real one nobody looks at again. And sender
    blocking is not performed under any flag - blocking a sender has
    effects well beyond the incident that prompted it, and the workbook
    assigns that call to an analyst. Where the evidence supports one, the
    report says so and leaves it to them.

    Rollback             : Reopen the incident in Sentinel. The classification
                           and comment this script writes are part of the
                           incident record and remain visible after reopening.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$WorkspaceName,

    [Parameter(Mandatory)]
    [string]$KnownPatternFile,

    [ValidateRange(1,720)]
    [int]$LookbackHours = 24,

    [string]$IncidentTitleFilter = 'phish',

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Automated phishing triage of known patterns',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Invoke-SentinelPhishingTriage'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #2 (Security Cloud)'

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


        $azContext = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $azContext) {
            throw 'No Azure context. Run Connect-AzAccount, or use a managed identity, before this script.'
        }
        if ($SubscriptionId -and $azContext.Subscription.Id -ne $SubscriptionId) {
            $azContext = Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop
        }
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Azure context: subscription {0}' -f $azContext.Subscription.Id)

        if (-not (Test-Path -LiteralPath $KnownPatternFile)) {
            throw ('Known-pattern file not found: {0}. Without it nothing is high-confidence and nothing ' +
                   'would be eligible for closure.' -f $KnownPatternFile)
        }
        $patterns = @((Get-Content -LiteralPath $KnownPatternFile -Raw | ConvertFrom-Json).patterns)
        if ($patterns.Count -eq 0) {
            throw ('No patterns defined in {0}.' -f $KnownPatternFile)
        }

        $base = ('/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.OperationalInsights/workspaces/{2}' +
                 '/providers/Microsoft.SecurityInsights') -f $azContext.Subscription.Id, $ResourceGroupName, $WorkspaceName

        $response = Invoke-AzRestMethod -Path ('{0}/incidents?api-version=2023-02-01' -f $base) -Method GET -ErrorAction Stop
        if ($response.StatusCode -ge 400) {
            throw ('Sentinel incidents could not be read (HTTP {0}): {1}' -f $response.StatusCode, $response.Content)
        }
        $incidents = @(($response.Content | ConvertFrom-Json).value)
        $cutoff = (Get-Date).AddHours(-$LookbackHours)

        foreach ($incident in $incidents) {
            $p = $incident.properties
            if ("$($p.status)" -eq 'Closed') { continue }
            if ($IncidentTitleFilter -and "$($p.title)" -notmatch [regex]::Escape($IncidentTitleFilter)) { continue }
            if ($p.createdTimeUtc -and ([datetime]$p.createdTimeUtc) -lt $cutoff) { continue }

            $haystack = '{0} {1}' -f $p.title, $p.description
            $matched = @($patterns | Where-Object { $haystack -match $_.match })
            $isHighConfidence = ($matched.Count -gt 0)

            # A blockable sender is evidence for an analyst, not an instruction. This
            # script never blocks one.
            $senderEvidence = ''
            if ($haystack -match '(?i)from[:\s]+([^\s<>]+@[^\s<>]+)') { $senderEvidence = $Matches[1] }

            if (-not $isHighConfidence) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $p.incidentNumber -Message (
                    'Left OPEN for analyst - no high-confidence pattern matched. Severity {0}.' -f $p.severity)
            }

            $results.Add([PSCustomObject]@{
                Name             = ('#{0} {1}' -f $p.incidentNumber, $p.title)
                Id               = $incident.name
                IncidentName     = $incident.name
                IncidentNumber   = $p.incidentNumber
                Title            = $p.title
                Severity         = $p.severity
                Status           = $p.status
                CreatedUtc       = $p.createdTimeUtc
                Owner            = $p.owner.assignedTo
                HighConfidence   = $isHighConfidence
                MatchedPattern   = (($matched | ForEach-Object { $_.name }) -join '; ')
                Classification   = if ($isHighConfidence) { @($matched)[0].classification } else { '' }
                SenderEvidence   = $senderEvidence
                SenderBlockNote  = if ($senderEvidence) {
                                      ('Sender {0} appears in this incident. Blocking it is an ANALYST decision and is not performed by this script.' -f $senderEvidence)
                                   } else { '' }
                ApiBase          = $base
                Actionable       = $isHighConfidence
            })
        }

        $ambiguous = @($results | Where-Object { -not $_.HighConfidence })
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            '{0} incident(s) matched a high-confidence pattern; {1} left open for analyst review. ' +
            'No sender was blocked.' -f ($results.Count - $ambiguous.Count), $ambiguous.Count)
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Close phishing incident', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Close phishing incident')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            if (-not $item.Actionable) {
                $actions.Add([PSCustomObject]@{
                    Name = $item.Name; Action = 'LeftForAnalyst'
                    Detail = 'No high-confidence pattern matched'; Succeeded = $true })
            } else {
                $body = @{
                    properties = @{
                        title          = $item.Title
                        severity       = $item.Severity
                        status         = 'Closed'
                        classification = if ($item.Classification) { $item.Classification } else { 'TruePositive' }
                        classificationComment = ('Closed automatically by {0}: matched high-confidence pattern "{1}". Approval {2}, ticket {3}.' -f
                            $scriptName, $item.MatchedPattern, $ApprovalReference, $TicketReference)
                    }
                } | ConvertTo-Json -Depth 6

                $update = Invoke-AzRestMethod -Method PUT -Payload $body `
                    -Path ('{0}/incidents/{1}?api-version=2023-02-01' -f $item.ApiBase, $item.IncidentName) -ErrorAction Stop
                if ($update.StatusCode -ge 400) {
                    throw ('Incident update failed (HTTP {0}): {1}' -f $update.StatusCode, $update.Content)
                }

                Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                    'Incident closed as {0} on pattern "{1}"{2}' -f
                    $item.Classification, $item.MatchedPattern,
                    $(if ($item.SenderEvidence) { '. Sender block NOT performed - analyst decision.' } else { '' }))
                $actions.Add([PSCustomObject]@{
                    Name = $item.Name; Action = 'IncidentClosed'; Detail = $item.MatchedPattern; Succeeded = $true })
            }
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Microsoft Sentinel SOAR Playbook - Phishing'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
