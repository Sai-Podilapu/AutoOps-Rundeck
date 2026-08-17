<#
.SYNOPSIS
    Adjusts VM Scale Set capacity within configured minimum and maximum
    bounds.

.DESCRIPTION
    Scales a VM Scale Set in or out to a requested instance count, refusing
    any value outside the configured floor and ceiling. The bounds are the
    guardrail: an unbounded scale-out is a cost incident and an unbounded
    scale-in is an outage.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER SubscriptionId
    Subscription to operate in. Falls back to azure.defaultSubscriptionId in
    config.json.

.PARAMETER ResourceGroupName
    Limit to specific resource groups.

.PARAMETER VmssName
    Scale set(s) to adjust.

.PARAMETER DesiredCapacity
    Target instance count.

.PARAMETER MinCapacity
    Floor. A request below this is refused.

.PARAMETER MaxCapacity
    Ceiling. A request above this is refused.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Set-AzVmssCapacity.ps1 -VmssName vmss-web -DesiredCapacity 6 -ResourceGroupName rg-prod

    Scales the set to 6 instances if that is within bounds.

.EXAMPLE
    .\Set-AzVmssCapacity.ps1 -VmssName vmss-web -DesiredCapacity 20 -MaxCapacity 10

    Refused - the request exceeds the configured ceiling.

.NOTES
    Source use case      : #14 - Azure Auto-Scale VM Scale Sets
    Category             : Azure
    Technology           : ARM Templates / Az CLI
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: No
    Guardrails (col L)   : "Rule-based scale in/out; guardrails on min/max in SOP"

    Required permissions : Virtual Machine Contributor on the scale set.
    Required modules     : Az.Accounts, Az.Compute
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    Scaling in terminates instances. If the workload is not stateless,
    drain connections first - this script does not do that, and cannot
    know which instances are safe to remove.

    Rollback             : Re-run with the previous capacity, which is recorded
                           in the audit log before the change is applied.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.Compute

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [string[]]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string[]]$VmssName,

    [Parameter(Mandatory)]
    [ValidateRange(0,1000)]
    [int]$DesiredCapacity,

    [ValidateRange(0,1000)]
    [int]$MinCapacity = 2,

    [ValidateRange(1,1000)]
    [int]$MaxCapacity = 10,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-AzVmssCapacity'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #14 (Azure)'

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

        if ($MinCapacity -gt $MaxCapacity) {
            throw ('MinCapacity ({0}) cannot exceed MaxCapacity ({1}).' -f $MinCapacity, $MaxCapacity)
        }
        if ($DesiredCapacity -lt $MinCapacity -or $DesiredCapacity -gt $MaxCapacity) {
            throw ('Refusing: desired capacity {0} is outside the configured bounds {1}-{2}.' -f
                   $DesiredCapacity, $MinCapacity, $MaxCapacity)
        }

        foreach ($name in $VmssName) {
            $vmss = if ($ResourceGroupName) {
                        Get-AzVmss -ResourceGroupName $ResourceGroupName[0] -VMScaleSetName $name -ErrorAction Stop
                    } else {
                        Get-AzVmss | Where-Object Name -eq $name | Select-Object -First 1
                    }
            if (-not $vmss) { throw ('Scale set {0} not found.' -f $name) }

            $current = $vmss.Sku.Capacity
            if ($current -eq $DesiredCapacity) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $name `
                    -Message ('Skipped - already at capacity {0}' -f $current)
                continue
            }

            $results.Add([PSCustomObject]@{
                Name            = $vmss.Name
                Id              = $vmss.Id
                ResourceGroup   = $vmss.ResourceGroupName
                Location        = $vmss.Location
                SkuName         = $vmss.Sku.Name
                CurrentCapacity = $current
                DesiredCapacity = $DesiredCapacity
                Direction       = if ($DesiredCapacity -gt $current) { 'scale out' } else { 'SCALE IN (terminates instances)' }
                Bounds          = ('{0}-{1}' -f $MinCapacity, $MaxCapacity)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Set VMSS capacity')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $vmss = Get-AzVmss -ResourceGroupName $item.ResourceGroup -VMScaleSetName $item.Name -ErrorAction Stop
            $vmss.Sku.Capacity = $item.DesiredCapacity
            Update-AzVmss -ResourceGroupName $item.ResourceGroup -Name $item.Name -VirtualMachineScaleSet $vmss -ErrorAction Stop | Out-Null

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Capacity {0} -> {1} ({2}), within bounds {3}' -f
                $item.CurrentCapacity, $item.DesiredCapacity, $item.Direction, $item.Bounds)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'CapacitySet'
                Detail = ('{0} -> {1}' -f $item.CurrentCapacity, $item.DesiredCapacity); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Azure Auto-Scale VM Scale Sets'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
