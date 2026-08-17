<#
.SYNOPSIS
    Reports CIS benchmark compliance from cloud-native policy engines.

.DESCRIPTION
    Reads compliance state from Azure Policy and AWS Config for the CIS
    initiatives already assigned there, and reports the pass rate per control.
    It does not implement its own benchmark checks - the cloud providers
    maintain theirs, and a second opinion computed here would just be a worse
    one.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER SubscriptionId
    Azure subscription to operate in. The current context when omitted.

.PARAMETER InitiativeNameFilter
    Substring identifying the CIS initiative assignment in Azure Policy.

.PARAMETER IncludeCloud
    Which clouds to query.

.PARAMETER ConformancePackName
    AWS Config conformance pack carrying the CIS rules.

.PARAMETER AwsRegion
    AWS region for Config.

.PARAMETER NonCompliantOnly
    Report only failing controls.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-CisBenchmarkCompliance.ps1 -IncludeCloud All -NonCompliantOnly -OutputFormat HTML

    Failing CIS controls across Azure and AWS.

.EXAMPLE
    .\Get-CisBenchmarkCompliance.ps1 -IncludeCloud Azure -InitiativeNameFilter 'CIS Microsoft Azure Foundations'

    One specific Azure initiative.

.NOTES
    Source use case      : #9 - CIS Benchmark Compliance Check
    Category             : Security Cloud
    Technology           : Azure Policy / AWS Config / OCI
    Difficulty           : Medium
    Agent possible       : Partial
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Weekly CIS L1/L2 compliance score"

    Required permissions : Reader plus Security Reader in Azure; config:Describe* in AWS.
    Required modules     : Az.Accounts, Az.PolicyInsights
    Authentication       : Vendor REST API via Invoke-RestMethod, or Graph
                           where the tool is Microsoft.

    This reports what the cloud's own policy engine already evaluated. If
    no CIS initiative is assigned in Azure Policy, or no conformance pack
    deployed in AWS Config, the script reports that nothing is being
    evaluated rather than reporting zero failures - which would read as a
    clean bill of health for a benchmark nobody is running.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.PolicyInsights

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [string]$InitiativeNameFilter = 'CIS',

    [ValidateSet('Azure','AWS','All')]
    [string[]]$IncludeCloud = @('All'),

    [string]$ConformancePackName,

    [string]$AwsRegion,

    [switch]$NonCompliantOnly,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-CisBenchmarkCompliance'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #9 (Security Cloud)'

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

        if ($wanted -contains 'Azure') {
            try {
                $azContext = Get-AzContext -ErrorAction Stop
                if ($SubscriptionId -and $azContext.Subscription.Id -ne $SubscriptionId) {
                    $azContext = Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop
                }

                $states = @(Get-AzPolicyState -ErrorAction Stop |
                            Where-Object { "$($_.PolicySetDefinitionName)" -match [regex]::Escape($InitiativeNameFilter) -or
                                           "$($_.PolicyDefinitionReferenceId)" -match [regex]::Escape($InitiativeNameFilter) })

                if ($states.Count -eq 0) {
                    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                        'No Azure Policy states matched "{0}". NOTHING is being evaluated against CIS in this ' +
                        'subscription - that is not the same as passing.' -f $InitiativeNameFilter)
                }

                foreach ($group in ($states | Group-Object PolicyDefinitionName)) {
                    $nonCompliant = @($group.Group | Where-Object { "$($_.ComplianceState)" -eq 'NonCompliant' })
                    if ($NonCompliantOnly -and $nonCompliant.Count -eq 0) { continue }

                    $results.Add([PSCustomObject]@{
                        Name            = $group.Name
                        Id              = $group.Name
                        Cloud           = 'Azure'
                        Control         = $group.Name
                        Evaluated       = $group.Count
                        Compliant       = ($group.Count - $nonCompliant.Count)
                        NonCompliant    = $nonCompliant.Count
                        CompliancePercent = if ($group.Count -gt 0) { [math]::Round((($group.Count - $nonCompliant.Count) / $group.Count) * 100, 1) } else { $null }
                        Status          = if ($nonCompliant.Count -gt 0) { 'NonCompliant' } else { 'Compliant' }
                        FailingResources= (($nonCompliant | Select-Object -First 5 | ForEach-Object { $_.ResourceId }) -join '; ')
                    })
                }
            } catch {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                    'Azure CIS compliance NOT collected: {0}' -f $_.Exception.Message)
            }
        }

        if ($wanted -contains 'AWS') {
            try {
                Import-Module AWS.Tools.ConfigService -ErrorAction Stop
                if (-not $ConformancePackName) {
                    throw 'No -ConformancePackName supplied; AWS Config cannot be queried for CIS without one.'
                }
                $packParams = @{ ConformancePackName = $ConformancePackName; ErrorAction = 'Stop' }
                if ($AwsRegion) { $packParams.Region = $AwsRegion }

                $ruleCompliance = @(Get-CFGConformancePackCompliance @packParams)

                foreach ($rule in $ruleCompliance) {
                    $isCompliant = "$($rule.ComplianceType)" -eq 'COMPLIANT'
                    if ($NonCompliantOnly -and $isCompliant) { continue }

                    $results.Add([PSCustomObject]@{
                        Name            = $rule.ConfigRuleName
                        Id              = $rule.ConfigRuleName
                        Cloud           = 'AWS'
                        Control         = $rule.ConfigRuleName
                        Evaluated       = 1
                        Compliant       = if ($isCompliant) { 1 } else { 0 }
                        NonCompliant    = if ($isCompliant) { 0 } else { 1 }
                        CompliancePercent = if ($isCompliant) { 100 } else { 0 }
                        Status          = "$($rule.ComplianceType)"
                        FailingResources= ''
                    })
                }
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
                    'AWS conformance pack "{0}": {1} rule(s) evaluated.' -f $ConformancePackName, $ruleCompliance.Count)
            } catch {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                    'AWS CIS compliance NOT collected: {0}' -f $_.Exception.Message)
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'CIS Benchmark Compliance Check'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
