<#
.SYNOPSIS
    Applies mandatory tags to Azure resources that are missing them.

.DESCRIPTION
    Finds resources missing any mandatory tag and applies the default value,
    inheriting from the parent resource group where one is available. A
    metadata-only change with no runtime effect, which is why it executes
    directly - but existing tag values are never overwritten.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER SubscriptionId
    Subscription to operate in. Falls back to azure.defaultSubscriptionId in
    config.json.

.PARAMETER ResourceGroupName
    Limit to specific resource groups.

.PARAMETER MandatoryTag
    Tag keys and their default values.

.PARAMETER InheritFromResourceGroup
    Prefer the parent resource group\u2019s tag value over the default.

.PARAMETER ResourceType
    Limit to specific resource types.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Set-AzResourceTagCompliance.ps1 -MandatoryTag @{Environment='unknown';Owner='unassigned'} -WhatIf

    Shows which resources are missing tags.

.EXAMPLE
    .\Set-AzResourceTagCompliance.ps1 -ResourceGroupName rg-prod

    Applies mandatory tags across one resource group.

.NOTES
    Source use case      : #19 - Azure Tag Compliance Enforcement
    Category             : Azure
    Technology           : Az Policy / PowerShell
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Auto-tagging is low-risk metadata change"

    Required permissions : Tag Contributor, or Contributor on the target scope.
    Required modules     : Az.Accounts, Az.Resources
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    An existing value is NEVER overwritten - only missing keys are added.
    A resource tagged Environment=prod stays prod even if the default says
    unknown.

    Rollback             : Remove the applied tags. The prior tag set is
                           recorded in the audit log before each change, so the
                           previous state is reconstructable.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.Resources

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [string[]]$ResourceGroupName,

    [hashtable]$MandatoryTag = @{ Environment = 'unknown'; Owner = 'unassigned'; CostCentre = 'unallocated' },

    [bool]$InheritFromResourceGroup = $true,

    [string[]]$ResourceType,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-AzResourceTagCompliance'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #19 (Azure)'

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

        $resources = if ($ResourceGroupName) { $ResourceGroupName | ForEach-Object { Get-AzResource -ResourceGroupName $_ } }
                     else                    { Get-AzResource }
        if ($ResourceType) { $resources = $resources | Where-Object { $ResourceType -contains $_.ResourceType } }

        $rgTagCache = @{}

        foreach ($r in $resources) {
            $current = if ($r.Tags) { $r.Tags } else { @{} }
            $toApply = @{}

            foreach ($key in $MandatoryTag.Keys) {
                if ($current.ContainsKey($key) -and $current[$key]) { continue }   # never overwrite

                $value = $MandatoryTag[$key]
                if ($InheritFromResourceGroup -and $r.ResourceGroupName) {
                    if (-not $rgTagCache.ContainsKey($r.ResourceGroupName)) {
                        $rg = Get-AzResourceGroup -Name $r.ResourceGroupName -ErrorAction SilentlyContinue
                        $rgTagCache[$r.ResourceGroupName] = if ($rg -and $rg.Tags) { $rg.Tags } else { @{} }
                    }
                    $rgTags = $rgTagCache[$r.ResourceGroupName]
                    if ($rgTags.ContainsKey($key) -and $rgTags[$key]) { $value = $rgTags[$key] }
                }
                $toApply[$key] = $value
            }

            if ($toApply.Count -eq 0) { continue }    # already compliant

            $results.Add([PSCustomObject]@{
                Name          = $r.Name
                Id            = $r.ResourceId
                ResourceGroup = $r.ResourceGroupName
                ResourceType  = $r.ResourceType
                Location      = $r.Location
                CurrentTags   = (($current.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join '; ')
                TagsToApply   = (($toApply.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join '; ')
                MissingCount  = $toApply.Count
                NewTagSet     = $toApply
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Apply mandatory tags')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
                'Prior tags: {0}' -f $(if ($item.CurrentTags) { $item.CurrentTags } else { '<none>' }))

            Update-AzTag -ResourceId $item.Id -Tag $item.NewTagSet -Operation Merge -ErrorAction Stop | Out-Null

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Applied {0} tag(s): {1}' -f $item.MissingCount, $item.TagsToApply)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'TagsApplied'; Detail = $item.TagsToApply; Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Azure Tag Compliance Enforcement'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
