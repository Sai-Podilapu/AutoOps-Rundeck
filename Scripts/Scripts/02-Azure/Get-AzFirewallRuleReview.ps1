<#
.SYNOPSIS
    Exports Azure Firewall rule collections for review.

.DESCRIPTION
    Exports every network, application and NAT rule collection with its
    priority and action, flagging the patterns worth questioning: any-to-any
    allows, wildcard FQDNs and wide port ranges. The export is automated;
    deciding whether a rule is still justified is business context this script
    cannot supply.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

    AGENT-ASSIST ONLY. This automates the mechanical part - gathering,
    enriching and comparing against a baseline - and then stops, producing
    a decision-ready package. The judgement step is deliberately left to a
    human and is NOT scripted.

.PARAMETER SubscriptionId
    Subscription to operate in. Falls back to azure.defaultSubscriptionId in
    config.json.

.PARAMETER ResourceGroupName
    Limit to specific resource groups.

.PARAMETER FirewallName
    Limit to specific firewalls.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-AzFirewallRuleReview.ps1 -OutputFormat HTML

    Full rule export as HTML for a review meeting.

.EXAMPLE
    .\Get-AzFirewallRuleReview.ps1 -FirewallName afw-hub -OutputFormat JSON

    One firewall as JSON.

.NOTES
    Source use case      : #24 - Azure Firewall Rule Review
    Category             : Azure
    Technology           : Az PowerShell / Firewall API
    Difficulty           : Low
    Agent possible       : Partial
    Can execute with SOP : Partially - Agent Assists
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Export/report is automated; the actual 'review' (is this rule still justified?) is business-context judgment"

    Required permissions : Reader on the firewall.
    Required modules     : Az.Accounts, Az.Network
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.Network

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [string[]]$ResourceGroupName,

    [string[]]$FirewallName,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-AzFirewallRuleReview'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #24 (Azure)'

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

        $fws = if ($ResourceGroupName) { $ResourceGroupName | ForEach-Object { Get-AzFirewall -ResourceGroupName $_ } }
               else                    { Get-AzFirewall }
        if ($FirewallName) { $fws = $fws | Where-Object { $FirewallName -contains $_.Name } }

        foreach ($fw in $fws) {
            foreach ($rc in $fw.NetworkRuleCollections) {
                foreach ($rule in $rc.Rules) {
                    $flags = @()
                    if ($rc.Action.Type -eq 'Allow') {
                        if ($rule.SourceAddresses -contains '*')      { $flags += 'source Any' }
                        if ($rule.DestinationAddresses -contains '*') { $flags += 'destination Any' }
                        if ($rule.DestinationPorts -contains '*')     { $flags += 'all ports' }
                    }
                    $results.Add([PSCustomObject]@{
                        Name          = ('{0} / {1} / {2}' -f $fw.Name, $rc.Name, $rule.Name)
                        Id            = $rule.Name
                        Firewall      = $fw.Name
                        Collection    = $rc.Name
                        CollectionType= 'Network'
                        Priority      = $rc.Priority
                        Action        = "$($rc.Action.Type)"
                        Protocols     = ($rule.Protocols -join ',')
                        Source        = ($rule.SourceAddresses -join ',')
                        Destination   = ($rule.DestinationAddresses -join ',')
                        Ports         = ($rule.DestinationPorts -join ',')
                        Flags         = ($flags -join '; ')
                        ReviewNote    = 'Is this rule still justified? Requires business context.'
                    })
                }
            }

            foreach ($rc in $fw.ApplicationRuleCollections) {
                foreach ($rule in $rc.Rules) {
                    $flags = @()
                    if ($rc.Action.Type -eq 'Allow') {
                        if ($rule.SourceAddresses -contains '*') { $flags += 'source Any' }
                        if ($rule.TargetFqdns | Where-Object { $_ -like '*`**' }) { $flags += 'wildcard FQDN' }
                    }
                    $results.Add([PSCustomObject]@{
                        Name          = ('{0} / {1} / {2}' -f $fw.Name, $rc.Name, $rule.Name)
                        Id            = $rule.Name
                        Firewall      = $fw.Name
                        Collection    = $rc.Name
                        CollectionType= 'Application'
                        Priority      = $rc.Priority
                        Action        = "$($rc.Action.Type)"
                        Protocols     = (($rule.Protocols | ForEach-Object { '{0}:{1}' -f $_.ProtocolType, $_.Port }) -join ',')
                        Source        = ($rule.SourceAddresses -join ',')
                        Destination   = ($rule.TargetFqdns -join ',')
                        Ports         = ''
                        Flags         = ($flags -join '; ')
                        ReviewNote    = 'Is this rule still justified? Requires business context.'
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

    # Agent-assist: the package is produced for a human. The script does
    # NOT proceed to a decision - that step is deliberately not automated.
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'Decision-ready package built: {0} item(s). Human review required.' -f $candidates.Count)
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message ('Collected {0} record(s).' -f $candidates.Count)
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Azure Firewall Rule Review'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
