<#
.SYNOPSIS
    Aggregates Azure Policy compliance across subscriptions.

.DESCRIPTION
    Summarises policy assignment compliance with non-compliant resource counts
    per assignment, so a drifting policy is one line rather than a console
    hunt.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER SubscriptionId
    Subscription to operate in. Falls back to azure.defaultSubscriptionId in
    config.json.

.PARAMETER OnlyNonCompliant
    Report only assignments with non-compliant resources.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-AzPolicyComplianceDashboard.ps1 -OnlyNonCompliant -OutputFormat HTML

    Just the failing assignments, as HTML.

.EXAMPLE
    .\Get-AzPolicyComplianceDashboard.ps1 -OutputFormat CSV

    Full compliance export.

.NOTES
    Source use case      : #27 - Azure Subscription Compliance Dashboard
    Category             : Azure
    Technology           : Az Policy / PowerShell
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Aggregate policy compliance across subscriptions"

    Required permissions : Reader plus Resource Policy Contributor (read) on the subscription.
    Required modules     : Az.Accounts, Az.PolicyInsights, Az.Resources
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.PolicyInsights
#Requires -Modules Az.Resources

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [switch]$OnlyNonCompliant,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-AzPolicyComplianceDashboard'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #27 (Azure)'

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

        $summary = Get-AzPolicyStateSummary -ErrorAction Stop

        foreach ($pa in $summary.PolicyAssignments) {
            $nonCompliant = $pa.Results.NonCompliantResources
            if ($OnlyNonCompliant -and $nonCompliant -eq 0) { continue }

            $assignmentName = ($pa.PolicyAssignmentId -split '/')[-1]
            $definition = $null
            try {
                $assignment = Get-AzPolicyAssignment -Id $pa.PolicyAssignmentId -ErrorAction Stop
                $definition = $assignment.Properties.DisplayName
            } catch {
                Write-Verbose ('Could not resolve assignment {0}' -f $assignmentName)
            }

            $results.Add([PSCustomObject]@{
                Name                  = if ($definition) { $definition } else { $assignmentName }
                Id                    = $pa.PolicyAssignmentId
                AssignmentName        = $assignmentName
                NonCompliantResources = $nonCompliant
                NonCompliantPolicies  = $pa.Results.NonCompliantPolicies
                Status                = if ($nonCompliant -gt 0) { 'NonCompliant' } else { 'Compliant' }
            })
        }

        $results.Add([PSCustomObject]@{
            Name                  = 'SUBSCRIPTION TOTAL'
            Id                    = (Get-AzContext).Subscription.Id
            AssignmentName        = '(all assignments)'
            NonCompliantResources = $summary.Results.NonCompliantResources
            NonCompliantPolicies  = $summary.Results.NonCompliantPolicies
            Status                = if ($summary.Results.NonCompliantResources -gt 0) { 'NonCompliant' } else { 'Compliant' }
        })
    } catch {
        $msg = $_.Exception.Message
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Message ('Discovery FAILED: {0}' -f $msg)
        $failures.Add([PSCustomObject]@{ Stage = 'Discovery'; Error = $msg })
    }
}

end {
    $candidates = @($results)

    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message ('Collected {0} record(s).' -f $candidates.Count)
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Azure Subscription Compliance Dashboard'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
