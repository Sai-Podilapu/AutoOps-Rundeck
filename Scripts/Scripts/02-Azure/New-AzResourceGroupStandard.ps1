<#
.SYNOPSIS
    Creates resource groups with enforced naming and mandatory tags.

.DESCRIPTION
    Creates a resource group only if its name matches the configured naming
    convention and all mandatory tags are supplied. Additive and low risk, but
    the standards are enforced here rather than left to the SOP, because a
    resource group created without an owner tag is the one nobody can
    attribute cost to six months later.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER SubscriptionId
    Subscription to operate in. Falls back to azure.defaultSubscriptionId in
    config.json.

.PARAMETER NewResourceGroupName
    Name of the resource group to create.

.PARAMETER Location
    Azure region.

.PARAMETER Tag
    Tags to apply. Must include every key in -MandatoryTagKey.

.PARAMETER NamingPattern
    Wildcard pattern the name must match. Set to * to disable the check.

.PARAMETER MandatoryTagKey
    Tag keys that must be present before a group is created.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\New-AzResourceGroupStandard.ps1 -NewResourceGroupName rg-app-prod -Location uaenorth -Tag @{Owner='ops';Environment='prod';CostCentre='CC100'}

    Creates a compliant resource group.

.EXAMPLE
    .\New-AzResourceGroupStandard.ps1 -NewResourceGroupName badname -Location uaenorth -WhatIf

    Fails the naming check before doing anything.

.NOTES
    Source use case      : #5 - Create Resource Groups
    Category             : Azure
    Technology           : Az CLI / Terraform
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Additive; naming/tag standards in SOP"

    Required permissions : Contributor at subscription scope.
    Required modules     : Az.Accounts, Az.Resources
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    Rollback             : Remove-AzResourceGroup. An empty resource group can
                           be deleted safely; one containing resources cannot,
                           which is why this script only ever creates empty
                           ones.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.Resources

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string[]]$NewResourceGroupName,

    [Parameter(Mandatory)]
    [string]$Location,

    [hashtable]$Tag = @{},

    [string]$NamingPattern = 'rg-*',

    [string[]]$MandatoryTagKey = @('Owner','Environment','CostCentre'),

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'New-AzResourceGroupStandard'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #5 (Azure)'

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

        $missingTags = @($MandatoryTagKey | Where-Object { -not $Tag.ContainsKey($_) })
        if ($missingTags.Count -gt 0) {
            throw ('Refusing to create: mandatory tag(s) missing - {0}. Supply them via -Tag.' -f ($missingTags -join ', '))
        }

        foreach ($rgName in $NewResourceGroupName) {
            if ($NamingPattern -ne '*' -and $rgName -notlike $NamingPattern) {
                throw ('Refusing to create "{0}": it does not match the naming pattern "{1}".' -f $rgName, $NamingPattern)
            }

            # Idempotent: an existing group is reported, not recreated.
            $existing = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
            if ($existing) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $rgName `
                    -Message ('Skipped - already exists in {0}' -f $existing.Location)
                continue
            }

            $results.Add([PSCustomObject]@{
                Name     = $rgName
                Id       = $rgName
                Location = $Location
                Tags     = (($Tag.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join '; ')
                TagCount = $Tag.Count
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Create resource group')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            New-AzResourceGroup -Name $item.Name -Location $item.Location -Tag $Tag -Force -ErrorAction Stop | Out-Null
            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Resource group created in {0} with {1} tag(s)' -f $item.Location, $item.TagCount)
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'Created'; Detail = $item.Location; Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Create Resource Groups'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
