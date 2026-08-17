<#
.SYNOPSIS
    Updates WAF managed rule sets in detection mode; refuses custom rule
    changes.

.DESCRIPTION
    Updates the managed rule set version on an Azure Front Door WAF policy and
    forces the result into Detection mode. Custom rules are reported and never
    modified, and moving a policy from Detection to Prevention needs a
    separate flag confirming somebody looked at the detection results first.

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
    Resource group holding the WAF policy.

.PARAMETER PolicyName
    WAF policy name(s).

.PARAMETER ManagedRuleSetType
    Managed rule set to apply.

.PARAMETER ManagedRuleSetVersion
    Managed rule set version to move to.

.PARAMETER PromoteToPrevention
    Switch the policy from Detection to Prevention. Requires
    -DetectionResultsValidated.

.PARAMETER DetectionResultsValidated
    Confirms a human reviewed the detection-mode results and accepts that
    Prevention will now block what those results showed.

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
    .\Update-CloudWafRuleSet.ps1 -ResourceGroupName rg-waf -PolicyName wafpolicy01 -ManagedRuleSetVersion 2.1

    REPORT ONLY. Shows the version change and raises an approval.

.EXAMPLE
    .\Update-CloudWafRuleSet.ps1 -ResourceGroupName rg-waf -PolicyName wafpolicy01 -ManagedRuleSetVersion 2.1 -ApprovalReference APR-...

    Applies the update in Detection mode.

.EXAMPLE
    .\Update-CloudWafRuleSet.ps1 -ResourceGroupName rg-waf -PolicyName wafpolicy01 -ManagedRuleSetVersion 2.1 -PromoteToPrevention -DetectionResultsValidated -ApprovalReference APR-...

    Promotes a validated policy to Prevention.

.NOTES
    Source use case      : #15 - Cloud WAF Rule Update Automation
    Category             : Security Cloud
    Technology           : Azure Front Door / AWS WAF / OCI WAF
    Difficulty           : High
    Agent possible       : Partial
    Can execute with SOP : Partially - Agent Assists
    Automation type      : Change / Write
    Risk level           : High
    Human approval needed: YES
    Guardrails (col L)   : "Managed rule-set updates automatable in staged mode; custom rule changes risk blocking legit traffic - human validates detection-mode results first"

    Required permissions : Contributor on the Front Door WAF policy.
    Required modules     : Az.Accounts, Az.FrontDoor
    Authentication       : Vendor REST API via Invoke-RestMethod, or Graph
                           where the tool is Microsoft.

    ASSIST-ONLY, and the staging is the whole control. A managed rule set
    update in Detection mode is safe: it logs what it would block and
    blocks nothing. The same update in Prevention mode can start refusing
    legitimate traffic the moment it applies, and the first symptom is
    usually a customer complaint rather than an alert. So the update
    always lands in Detection, and promotion is a separate run with a
    separate flag. Custom rules are never touched - their blast radius is
    entirely application-specific and the workbook assigns them to a
    human.

    Rollback             : The previous rule set version and policy mode are
                           captured and logged before the change. Re-apply them
                           to revert. Traffic blocked while Prevention was
                           active is not recoverable - those requests were
                           already refused.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.FrontDoor

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [string[]]$PolicyName,

    [string]$ManagedRuleSetType = 'Microsoft_DefaultRuleSet',

    [Parameter(Mandatory)]
    [string]$ManagedRuleSetVersion,

    [switch]$PromoteToPrevention,

    [switch]$DetectionResultsValidated,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Managed WAF rule set update, staged in detection mode',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Update-CloudWafRuleSet'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #15 (Security Cloud)'

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
    $pre = Test-Prerequisite -RequiredModule 'Az.Accounts','Az.FrontDoor'
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

        if ($PromoteToPrevention -and -not $DetectionResultsValidated) {
            throw 'Refusing -PromoteToPrevention without -DetectionResultsValidated. Prevention mode starts ' +
                  'blocking traffic immediately, and the guardrail on this use case requires a human to ' +
                  'validate the detection-mode results first.'
        }

        $policies = @()
        if ($PolicyName) {
            foreach ($name in $PolicyName) {
                $policies += Get-AzFrontDoorWafPolicy -ResourceGroupName $ResourceGroupName -Name $name -ErrorAction Stop
            }
        } else {
            $policies = @(Get-AzFrontDoorWafPolicy -ResourceGroupName $ResourceGroupName -ErrorAction Stop)
        }

        foreach ($policy in $policies) {
            $managed = @($policy.ManagedRules | Where-Object { $_.RuleSetType -eq $ManagedRuleSetType })
            $currentVersion = if ($managed.Count -gt 0) { @($managed)[0].RuleSetVersion } else { '' }
            $currentMode = "$($policy.Mode)"
            $customRules = @($policy.CustomRules)

            $versionChanging = ($currentVersion -ne $ManagedRuleSetVersion)
            $modeChanging = ($PromoteToPrevention -and $currentMode -ne 'Prevention')

            if (-not $versionChanging -and -not $modeChanging) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $policy.Name -Message (
                    'Skipped - already on {0} {1} in {2} mode (idempotent)' -f
                    $ManagedRuleSetType, $ManagedRuleSetVersion, $currentMode)
                continue
            }

            if ($customRules.Count -gt 0) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $policy.Name -Message (
                    '{0} custom rule(s) present. They are NOT modified by this script - custom rule changes ' +
                    'risk blocking legitimate traffic and are a human decision.' -f $customRules.Count)
            }

            $results.Add([PSCustomObject]@{
                Name            = $policy.Name
                Id              = $policy.Id
                PolicyName      = $policy.Name
                ResourceGroup   = $ResourceGroupName
                CurrentMode     = $currentMode
                TargetMode      = if ($PromoteToPrevention) { 'Prevention' } else { 'Detection' }
                RuleSetType     = $ManagedRuleSetType
                CurrentVersion  = $currentVersion
                TargetVersion   = $ManagedRuleSetVersion
                VersionChanging = $versionChanging
                ModeChanging    = $modeChanging
                CustomRuleCount = $customRules.Count
                CustomRuleNames = (($customRules | ForEach-Object { $_.Name }) -join '; ')
                StagingNote     = if ($PromoteToPrevention) {
                                     'PROMOTION TO PREVENTION - this policy starts BLOCKING traffic on apply'
                                  } else {
                                     'Lands in Detection mode - logs what it would block, blocks nothing'
                                  }
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Update WAF managed rule set', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Update WAF managed rule set')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
                'Previous state (rollback reference): {0} {1}, mode {2}' -f
                $item.RuleSetType, $item.CurrentVersion, $item.CurrentMode)

            $ruleSet = New-AzFrontDoorWafManagedRuleObject -Type $item.RuleSetType -Version $item.TargetVersion

            $updateParams = @{
                ResourceGroupName = $item.ResourceGroup
                Name              = $item.PolicyName
                ManagedRule       = $ruleSet
                Mode              = $item.TargetMode
                ErrorAction       = 'Stop'
            }
            Update-AzFrontDoorWafPolicy @updateParams | Out-Null

            if ($item.TargetMode -eq 'Prevention') {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
                    'Policy is now in PREVENTION mode on {0} {1}. It is blocking traffic from this moment. ' +
                    'Watch the block logs.' -f $item.RuleSetType, $item.TargetVersion)
            } else {
                Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                    '{0} updated {1} -> {2}, staged in DETECTION mode. Review the detection results before promoting.' -f
                    $item.RuleSetType, $item.CurrentVersion, $item.TargetVersion)
            }

            if ($item.CustomRuleCount -gt 0) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
                    '{0} custom rule(s) left untouched: {1}' -f $item.CustomRuleCount, $item.CustomRuleNames)
            }

            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'RuleSetUpdated'
                Detail = ('{0} -> {1}, {2} mode' -f $item.CurrentVersion, $item.TargetVersion, $item.TargetMode)
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Cloud WAF Rule Update Automation'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
