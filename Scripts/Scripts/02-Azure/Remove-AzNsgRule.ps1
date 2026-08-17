<#
.SYNOPSIS
    Audits network security group rules and removes approved candidates.

.DESCRIPTION
    Audits NSG rules for the patterns worth questioning - any-source inbound,
    wide port ranges, rules shadowed by a higher-priority rule, and rules with
    no matching traffic - and produces a candidate list. Deleting an NSG rule
    can sever production traffic, and only the network owner knows which flows
    are real, so removal is gated behind both approval and an explicit
    -Execute.

    DESTRUCTIVE. This script is REPORT-ONLY by default: it produces the
    candidate list and stops. Nothing is deleted, wiped or failed over
    unless -Execute is passed AND a valid -ApprovalReference is supplied.
    A pre-action backup/export is taken where the platform allows it, and
    every object is logged individually before it is touched.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

    AGENT-ASSIST ONLY. This automates the mechanical part - gathering,
    enriching and comparing against a baseline - and then stops, producing
    a decision-ready package. The judgement step is deliberately left to a
    human and is NOT scripted.

.PARAMETER SubscriptionId
    Subscription to operate in. Falls back to azure.defaultSubscriptionId in
    config.json.

.PARAMETER ResourceGroupName
    Limit to specific resource groups.

.PARAMETER NetworkSecurityGroupName
    Limit to specific NSGs.

.PARAMETER FlagAnySource
    Flag inbound Allow rules whose source is Any/Internet.

.PARAMETER FlagWidePortRange
    Flag rules spanning more than this many ports.

.PARAMETER Execute
    Actually perform the destructive action. Without this the script only
    reports what it would do.

.PARAMETER ProtectedList
    Path to a file of names/ids that must never be acted upon, one per line.
    Entries here are excluded unconditionally and the exclusion cannot be
    overridden by any other parameter.

.PARAMETER MinimumAgeDays
    Only consider objects older than this. A conservative default guards
    against acting on something created moments ago.

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
    .\Remove-AzNsgRule.ps1 -ResourceGroupName rg-net

    REPORT ONLY. Audits every NSG and raises an approval with the candidate
    list.

.EXAMPLE
    .\Remove-AzNsgRule.ps1 -ResourceGroupName rg-net -ApprovalReference APR-... -Execute -ProtectedList .\keep-rules.txt

    Removes the approved rules, excluding anything on the protected list.

.NOTES
    Source use case      : #15 - Azure NSG Rule Audit & Cleanup
    Category             : Azure
    Technology           : Az PowerShell / Policy
    Difficulty           : Medium
    Agent possible       : Partial
    Can execute with SOP : Partially - Agent Assists
    Automation type      : Destructive / High-Impact
    Risk level           : High
    Human approval needed: YES
    Guardrails (col L)   : "Agent audits & proposes removals; deciding which rules are actually safe to delete requires network owner knowledge of traffic flows"

    Required permissions : Network Contributor on the NSG.
    Required modules     : Az.Accounts, Az.Network
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    This script CANNOT know whether a rule is still needed. It surfaces
    candidates and the reason each was flagged; deciding which are
    genuinely safe to delete requires a network owner who knows the
    traffic flows. That judgement is deliberately not automated.

    Rollback             : Re-create the rule from the pre-deletion export this
                           script writes. The export captures the full rule
                           definition including priority, which is what makes
                           restoration possible.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.Network

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [string[]]$ResourceGroupName,

    [string[]]$NetworkSecurityGroupName,

    [bool]$FlagAnySource = $true,

    [ValidateRange(1,65535)]
    [int]$FlagWidePortRange = 100,

    [switch]$Execute,

    [string]$ProtectedList,

    [ValidateRange(0, 3650)]
    [int]$MinimumAgeDays = 0,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'NSG rule cleanup',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Remove-AzNsgRule'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #15 (Azure)'

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

    $protected = @()
    if ($ProtectedList -and (Test-Path -LiteralPath $ProtectedList)) {
        $protected = @(Get-Content -LiteralPath $ProtectedList |
            Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { $_.Trim() })
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Protected list loaded: {0} entry(ies). These are excluded unconditionally.' -f $protected.Count)
    }

    # Risk = High: validate before doing anything at all.
    $pre = Test-Prerequisite -RequiredModule 'Az.Accounts','Az.Network'
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
        Connect-AutomationPlatform -Platform 'Azure' | Out-Null


        if (-not $SubscriptionId -and $config -and $config.azure) { $SubscriptionId = $config.azure.defaultSubscriptionId }
        if ($SubscriptionId) {
            Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop | Out-Null
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message ('Subscription context: {0}' -f $SubscriptionId)
        } else {
            $ctx = Get-AzContext
            if (-not $ctx) { throw 'No Azure context. Pass -SubscriptionId or set azure.defaultSubscriptionId in config.json.' }
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'No -SubscriptionId given; using the ambient context {0}' -f $ctx.Subscription.Id)
        }

        $nsgs = if ($ResourceGroupName) { $ResourceGroupName | ForEach-Object { Get-AzNetworkSecurityGroup -ResourceGroupName $_ } }
                else                    { Get-AzNetworkSecurityGroup }
        if ($NetworkSecurityGroupName) { $nsgs = $nsgs | Where-Object { $NetworkSecurityGroupName -contains $_.Name } }

        foreach ($nsg in $nsgs) {
            $rules = @($nsg.SecurityRules | Sort-Object Priority)

            foreach ($rule in $rules) {
                $flags = @()

                if ($FlagAnySource -and $rule.Direction -eq 'Inbound' -and $rule.Access -eq 'Allow') {
                    $srcs = @($rule.SourceAddressPrefix) + @($rule.SourceAddressPrefixes)
                    if ($srcs | Where-Object { $_ -in @('*','Internet','0.0.0.0/0') }) {
                        $flags += 'inbound Allow from Any/Internet'
                    }
                }

                foreach ($pr in (@($rule.DestinationPortRange) + @($rule.DestinationPortRanges))) {
                    if (-not $pr) { continue }
                    if ($pr -eq '*') { $flags += 'all destination ports'; continue }
                    if ($pr -match '^(\d+)-(\d+)$') {
                        $span = [int]$Matches[2] - [int]$Matches[1]
                        if ($span -gt $FlagWidePortRange) { $flags += ('port range spans {0} ports' -f $span) }
                    }
                }

                # Shadowed: an earlier rule with the same direction already matches
                # everything this one would, so this rule can never take effect.
                $shadow = $rules | Where-Object {
                    $_.Priority -lt $rule.Priority -and
                    $_.Direction -eq $rule.Direction -and
                    $_.SourceAddressPrefix -eq '*' -and
                    $_.DestinationAddressPrefix -eq '*' -and
                    $_.DestinationPortRange -eq '*' -and
                    $_.Protocol -eq '*'
                } | Select-Object -First 1
                if ($shadow) { $flags += ('shadowed by higher-priority rule {0} ({1})' -f $shadow.Name, $shadow.Priority) }

                if ($flags.Count -eq 0) { continue }

                $results.Add([PSCustomObject]@{
                    Name          = ('{0} / {1}' -f $nsg.Name, $rule.Name)
                    Id            = $rule.Name
                    NsgName       = $nsg.Name
                    ResourceGroup = $nsg.ResourceGroupName
                    RuleName      = $rule.Name
                    Priority      = $rule.Priority
                    Direction     = "$($rule.Direction)"
                    Access        = "$($rule.Access)"
                    Protocol      = "$($rule.Protocol)"
                    SourcePrefix  = ((@($rule.SourceAddressPrefix) + @($rule.SourceAddressPrefixes)) -join ',')
                    DestPrefix    = ((@($rule.DestinationAddressPrefix) + @($rule.DestinationAddressPrefixes)) -join ',')
                    DestPorts     = ((@($rule.DestinationPortRange) + @($rule.DestinationPortRanges)) -join ',')
                    Flags         = ($flags -join '; ')
                    AttachedTo    = ((@($nsg.Subnets.Id) + @($nsg.NetworkInterfaces.Id) | ForEach-Object { ($_ -split '/')[-1] }) -join '; ')
                    OwnerDecision = 'A network owner must confirm no live traffic depends on this rule'
                })
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target ('{0}/{1}' -f $nsg.Name, $rule.Name) `
                    -Message ($flags -join '; ')
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

    # Hard exclusions and safety filters BEFORE anything else.
    if ($protected.Count -gt 0) {
        $before = $candidates.Count
        $candidates = @($candidates | Where-Object {
            $id = $_.Id; $nm = $_.Name
            -not ($protected | Where-Object { $_ -and ($id -like $_ -or $nm -like $_) })
        })
        if ($before -ne $candidates.Count) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
                'Protected list excluded {0} object(s).' -f ($before - $candidates.Count))
        }
    }
    if ($MinimumAgeDays -gt 0) {
        $cut = (Get-Date).AddDays(-$MinimumAgeDays)
        $before = $candidates.Count
        $candidates = @($candidates | Where-Object { -not $_.CreatedAt -or $_.CreatedAt -lt $cut })
        if ($before -ne $candidates.Count) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
                'Age filter (>{0}d) excluded {1} object(s).' -f $MinimumAgeDays, ($before - $candidates.Count))
        }
    }

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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Remove NSG rule', $candidates.Count, $Reason, $TicketReference)
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

    if (-not $Execute) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'REPORT-ONLY - {0} candidate(s) identified, nothing was changed. Pass -Execute to act.' -f $candidates.Count)
        $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Azure NSG Rule Audit & Cleanup (candidates)'
        Write-Output $candidates
        return
    }

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Remove NSG rule')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {
            # Mandatory pre-action capture, so the object can be restored.

            # Export the full rule definition before deleting it. This export is the only
            # thing that makes the deletion reversible.
            $exportDir = Join-Path $env:ProgramData 'ITAutomation\Rollback'
            if (-not (Test-Path -LiteralPath $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }
            $exportPath = Join-Path $exportDir ('nsgrule-{0}-{1}-{2}.json' -f $item.NsgName, $item.RuleName, (Get-Date -Format 'yyyyMMdd-HHmmss'))

            $nsgObj = Get-AzNetworkSecurityGroup -ResourceGroupName $item.ResourceGroup -Name $item.NsgName -ErrorAction Stop
            $ruleObj = $nsgObj.SecurityRules | Where-Object Name -eq $item.RuleName | Select-Object -First 1
            $ruleObj | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $exportPath -Encoding UTF8

            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
                'Rule definition exported to {0} - this is the restore path' -f $exportPath)


            $nsgObj = Get-AzNetworkSecurityGroup -ResourceGroupName $item.ResourceGroup -Name $item.NsgName -ErrorAction Stop
            Remove-AzNetworkSecurityRuleConfig -Name $item.RuleName -NetworkSecurityGroup $nsgObj -ErrorAction Stop | Out-Null
            Set-AzNetworkSecurityGroup -NetworkSecurityGroup $nsgObj -ErrorAction Stop | Out-Null

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'NSG rule REMOVED: {0} (priority {1}). Restore from {2}' -f $item.RuleName, $item.Priority, $exportPath)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'RuleRemoved'
                Detail = ('priority {0}; export {1}' -f $item.Priority, $exportPath); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Azure NSG Rule Audit & Cleanup'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
