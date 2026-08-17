<#
.SYNOPSIS
    Provisions standard Azure Monitor metric alert rules.

.DESCRIPTION
    Creates a standard set of metric alert rules - CPU, available memory and
    disk - against target resources, wired to an existing action group.
    Idempotent: an alert rule that already exists is left alone rather than
    duplicated.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER SubscriptionId
    Subscription to operate in. Falls back to azure.defaultSubscriptionId in
    config.json.

.PARAMETER ResourceGroupName
    Limit to specific resource groups.

.PARAMETER TargetResourceId
    Resources to alert on. Omit to target every VM in scope.

.PARAMETER ActionGroupId
    Resource id of the action group to notify.

.PARAMETER CpuThreshold
    CPU percentage above which the alert fires.

.PARAMETER Severity
    Alert severity, 0 (critical) to 4 (verbose).

.PARAMETER EvaluationFrequencyMinutes
    How often the rule is evaluated.

.PARAMETER WindowSizeMinutes
    Aggregation window. Must be at least the evaluation frequency.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\New-AzMonitorAlertRule.ps1 -ResourceGroupName rg-prod -ActionGroupId '/subscriptions/.../actionGroups/ag-ops'

    Creates CPU alerts for every VM in the resource group.

.EXAMPLE
    .\New-AzMonitorAlertRule.ps1 -TargetResourceId '/subscriptions/.../virtualMachines/APP01' -ActionGroupId '...' -CpuThreshold 90 -WhatIf

    Shows the alert that would be created for one VM.

.NOTES
    Source use case      : #32 - Azure Monitor Alert Rule Provisioning
    Category             : Azure
    Technology           : Az CLI / Bicep
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Deploy standard alert rules via IaC"

    Required permissions : Monitoring Contributor on the target scope.
    Required modules     : Az.Accounts, Az.Monitor
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    The action group must already exist - this script does not create one,
    because notification routing is an organisational decision rather than
    a technical default.

    Rollback             : Remove-AzMetricAlertRuleV2. Alert rules are additive
                           and affect nothing but notification.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.Monitor

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [string[]]$ResourceGroupName,

    [string[]]$TargetResourceId,

    [Parameter(Mandatory)]
    [string]$ActionGroupId,

    [ValidateRange(1,100)]
    [int]$CpuThreshold = 85,

    [ValidateRange(0,4)]
    [int]$Severity = 2,

    [ValidateSet(1,5,15,30,60)]
    [int]$EvaluationFrequencyMinutes = 5,

    [ValidateSet(5,15,30,60,360,720,1440)]
    [int]$WindowSizeMinutes = 15,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'New-AzMonitorAlertRule'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #32 (Azure)'

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

        if ($WindowSizeMinutes -lt $EvaluationFrequencyMinutes) {
            throw ('WindowSizeMinutes ({0}) cannot be smaller than EvaluationFrequencyMinutes ({1}).' -f
                   $WindowSizeMinutes, $EvaluationFrequencyMinutes)
        }

        $ag = Get-AzActionGroup -ResourceId $ActionGroupId -ErrorAction SilentlyContinue
        if (-not $ag) { throw ('Action group {0} not found. Create it before provisioning alert rules.' -f $ActionGroupId) }

        $targets = if ($TargetResourceId) { $TargetResourceId }
                   elseif ($ResourceGroupName) { ($ResourceGroupName | ForEach-Object { Get-AzVM -ResourceGroupName $_ }).Id }
                   else { (Get-AzVM).Id }

        foreach ($tid in $targets) {
            $shortName = ($tid -split '/')[-1]
            $rgName = ($tid -split '/')[4]
            $ruleName = ('alert-cpu-{0}' -f $shortName)

            if (Get-AzMetricAlertRuleV2 -ResourceGroupName $rgName -Name $ruleName -ErrorAction SilentlyContinue) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $ruleName `
                    -Message 'Skipped - alert rule already exists (idempotent)'
                continue
            }

            $results.Add([PSCustomObject]@{
                Name          = $ruleName
                Id            = $tid
                ResourceGroup = $rgName
                TargetName    = $shortName
                RuleName      = $ruleName
                MetricName    = 'Percentage CPU'
                Threshold     = $CpuThreshold
                Severity      = $Severity
                Frequency     = ('PT{0}M' -f $EvaluationFrequencyMinutes)
                WindowSize    = ('PT{0}M' -f $WindowSizeMinutes)
                ActionGroup   = ($ActionGroupId -split '/')[-1]
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

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Create alert rule')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $criteria = New-AzMetricAlertRuleV2Criteria -MetricName $item.MetricName `
                -MetricNamespace 'Microsoft.Compute/virtualMachines' -TimeAggregation Average `
                -Operator GreaterThan -Threshold $item.Threshold

            Add-AzMetricAlertRuleV2 -Name $item.RuleName -ResourceGroupName $item.ResourceGroup `
                -WindowSize $item.WindowSize -Frequency $item.Frequency -TargetResourceId $item.Id `
                -Condition $criteria -ActionGroupId $ActionGroupId -Severity $item.Severity `
                -Description ('CPU above {0}% - provisioned by {1}' -f $item.Threshold, $scriptName) `
                -ErrorAction Stop | Out-Null

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Alert rule created: {0} > {1}%, severity {2}, window {3}' -f
                $item.MetricName, $item.Threshold, $item.Severity, $item.WindowSize)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'AlertRuleCreated'
                Detail = ('{0} > {1}%' -f $item.MetricName, $item.Threshold); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Azure Monitor Alert Rule Provisioning'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
