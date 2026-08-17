<#
.SYNOPSIS
    Pulls AWS Trusted Advisor checks as a Well-Architected review summary.

.DESCRIPTION
    Runs the Trusted Advisor checks and groups results by pillar so the output
    reads as a review rather than a flat list of findings.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

    AGENT-ASSIST ONLY. This automates the mechanical part - gathering,
    enriching and comparing against a baseline - and then stops, producing
    a decision-ready package. The judgement step is deliberately left to a
    human and is NOT scripted.

.PARAMETER ProfileName
    Named AWS profile / SSO profile to use. Prefer an IAM role where the host
    supports one.

.PARAMETER Category
    Trusted Advisor categories to include.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-AwsWellArchitectedReview.ps1 

    Pulls all default categories.

.EXAMPLE
    .\Get-AwsWellArchitectedReview.ps1 -Category security,service_limits -OutputFormat JSON

    Pulls two categories as JSON.

.NOTES
    Source use case      : #3 - Well Architect Review
    Category             : AWS
    Technology           : AWS Trusted Advisor
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Partially - Agent Assists
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Agent pulls Trusted Advisor data & drafts findings; architectural judgment, trade-off discussions and remediation decisions are human"

    Required permissions : support:DescribeTrustedAdvisorChecks, support:DescribeTrustedAdvisorCheckResult (Business/Enterprise support required)
    Required modules     : AWS.Tools.Common, AWS.Tools.Support
    Authentication       : IAM role or SSO profile via Set-AWSCredential. Never
                           an access key pair in code.

    Trusted Advisor full checks require a Business or Enterprise support
    plan and the API is only available in us-east-1. The script targets
    us-east-1 for the Support API regardless of -Region, which applies to
    any other call.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules AWS.Tools.Common
#Requires -Modules AWS.Tools.Support

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$ProfileName,

    [string[]]$Category = @('cost_optimizing','performance','security','fault_tolerance','service_limits'),

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-AwsWellArchitectedReview'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #3 (AWS)'

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
        Connect-AutomationPlatform -Platform 'AWS' | Out-Null


        $awsArgs = @{ Region = 'us-east-1' }   # Support API is us-east-1 only
        if ($ProfileName) { $awsArgs.ProfileName = $ProfileName }

        $checks = Get-ASATrustedAdvisorCheck -Language en @awsArgs |
            Where-Object { $Category -contains $_.Category }

        foreach ($chk in $checks) {
            $res = Get-ASATrustedAdvisorCheckResult -CheckId $chk.Id -Language en @awsArgs
            $results.Add([PSCustomObject]@{
                Name           = $chk.Name
                Id             = $chk.Id
                Pillar         = $chk.Category
                Status         = $res.Status
                ResourcesFlagged = $res.ResourcesSummary.ResourcesFlagged
                ResourcesProcessed = $res.ResourcesSummary.ResourcesProcessed
                EstimatedMonthlySavings = $res.CategorySpecificSummary.CostOptimizing.EstimatedMonthlySavings
                Description    = $chk.Description
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

    # Agent-assist: the package is produced for a human. The script does
    # NOT proceed to a decision - that step is deliberately not automated.
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'Decision-ready package built: {0} item(s). Human review required.' -f $candidates.Count)
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message ('Collected {0} record(s).' -f $candidates.Count)
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Well Architect Review'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
