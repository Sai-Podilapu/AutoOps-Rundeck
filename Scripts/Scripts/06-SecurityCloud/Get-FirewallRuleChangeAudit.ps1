<#
.SYNOPSIS
    Reports firewall and security group rule changes.

.DESCRIPTION
    Reads the control-plane change record for network security rules and
    reports every modification with who made it and when. Read-only: it audits
    changes, it does not reverse them.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER SubscriptionId
    Azure subscription to operate in. The current context when omitted.

.PARAMETER LookbackHours
    Reporting window.

.PARAMETER IncludeCloud
    Which clouds to audit.

.PARAMETER AwsRegion
    AWS region for CloudTrail.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-FirewallRuleChangeAudit.ps1 -LookbackHours 24 -OutputFormat HTML

    Yesterday's rule changes across clouds.

.EXAMPLE
    .\Get-FirewallRuleChangeAudit.ps1 -IncludeCloud Azure -LookbackHours 168

    A week of Azure NSG and firewall changes.

.NOTES
    Source use case      : #8 - Firewall Rule Change Audit
    Category             : Security Cloud
    Technology           : Palo Alto / Azure FW / AWS SG API
    Difficulty           : Medium
    Agent possible       : Partial
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Alert on any rule modification; read-only"

    Required permissions : Reader on the Azure subscription; cloudtrail:LookupEvents in AWS.
    Required modules     : Az.Accounts, Az.Monitor
    Authentication       : Vendor REST API via Invoke-RestMethod, or Graph
                           where the tool is Microsoft.

    The Azure Activity Log retains 90 days and AWS CloudTrail event
    history 90 days by default. A lookback longer than that returns
    nothing for the earlier part of the window and says so, rather than
    presenting a short answer as a complete one. Palo Alto and other
    appliance firewalls are not covered here - their change logs are on
    the appliance and need their own credentials.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.Monitor

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [ValidateRange(1,720)]
    [int]$LookbackHours = 24,

    [ValidateSet('Azure','AWS','All')]
    [string[]]$IncludeCloud = @('All'),

    [string]$AwsRegion,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-FirewallRuleChangeAudit'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #8 (Security Cloud)'

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
        Connect-AutomationPlatform -Platform 'Graph' | Out-Null


        $wanted = if ($IncludeCloud -contains 'All') { @('Azure', 'AWS') } else { $IncludeCloud }
        $since = (Get-Date).AddHours(-$LookbackHours)

        if ($LookbackHours -gt (90 * 24)) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'A {0}h lookback exceeds the 90-day default retention of both sources. Results before that ' +
                'point are missing, not empty.' -f $LookbackHours)
        }

        if ($wanted -contains 'Azure') {
            try {
                $azContext = Get-AzContext -ErrorAction Stop
                if ($SubscriptionId -and $azContext.Subscription.Id -ne $SubscriptionId) {
                    $azContext = Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop
                }

                $events = @(Get-AzLog -StartTime $since -EndTime (Get-Date) -MaxRecord 1000 -WarningAction SilentlyContinue -ErrorAction Stop)
                $ruleEvents = @($events | Where-Object {
                    "$($_.Authorization.Action)" -match '(?i)networkSecurityGroups|azureFirewalls|firewallPolicies|securityRules' -and
                    "$($_.Authorization.Action)" -match '(?i)/write$|/delete$'
                })

                foreach ($e in $ruleEvents) {
                    $results.Add([PSCustomObject]@{
                        Name        = ('{0}: {1}' -f $e.Caller, $e.Authorization.Action)
                        Id          = $e.Id
                        Cloud       = 'Azure'
                        ChangedAt   = $e.EventTimestamp
                        Caller      = $e.Caller
                        Operation   = $e.Authorization.Action
                        ResourceId  = $e.ResourceId
                        ResourceType= $e.ResourceType.Value
                        Status      = "$($e.Status.Value)"
                        SourceIp    = $e.HttpRequest.ClientIpAddress
                        CorrelationId = $e.CorrelationId
                        Detail      = $e.SubStatus.Value
                    })
                }
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
                    'Azure: {0} network security rule change(s) in the window.' -f $ruleEvents.Count)
            } catch {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                    'Azure change audit NOT collected: {0}' -f $_.Exception.Message)
            }
        }

        if ($wanted -contains 'AWS') {
            try {
                Import-Module AWS.Tools.CloudTrail -ErrorAction Stop
                $lookupParams = @{
                    StartTime   = $since
                    EndTime     = (Get-Date)
                    ErrorAction = 'Stop'
                }
                if ($AwsRegion) { $lookupParams.Region = $AwsRegion }

                $sgEventNames = @('AuthorizeSecurityGroupIngress', 'AuthorizeSecurityGroupEgress',
                                  'RevokeSecurityGroupIngress', 'RevokeSecurityGroupEgress',
                                  'CreateSecurityGroup', 'DeleteSecurityGroup',
                                  'CreateNetworkAclEntry', 'DeleteNetworkAclEntry')

                foreach ($eventName in $sgEventNames) {
                    $attr = New-Object Amazon.CloudTrail.Model.LookupAttribute
                    $attr.AttributeKey = 'EventName'
                    $attr.AttributeValue = $eventName
                    $found = @(Find-CTEvent @lookupParams -LookupAttribute $attr)

                    foreach ($e in $found) {
                        $results.Add([PSCustomObject]@{
                            Name        = ('{0}: {1}' -f $e.Username, $e.EventName)
                            Id          = $e.EventId
                            Cloud       = 'AWS'
                            ChangedAt   = $e.EventTime
                            Caller      = $e.Username
                            Operation   = $e.EventName
                            ResourceId  = (($e.Resources | ForEach-Object { $_.ResourceName }) -join '; ')
                            ResourceType= (($e.Resources | ForEach-Object { $_.ResourceType }) -join '; ')
                            Status      = 'Recorded'
                            SourceIp    = ''
                            CorrelationId = $e.EventId
                            Detail      = $e.EventSource
                        })
                    }
                }
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
                    'AWS: {0} security group / NACL change event(s) in the window.' -f
                    @($results | Where-Object { $_.Cloud -eq 'AWS' }).Count)
            } catch {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                    'AWS change audit NOT collected: {0}' -f $_.Exception.Message)
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

    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message ('Collected {0} record(s).' -f $candidates.Count)
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Firewall Rule Change Audit'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
