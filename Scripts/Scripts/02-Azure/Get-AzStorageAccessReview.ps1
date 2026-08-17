<#
.SYNOPSIS
    Reviews Azure storage accounts for public exposure and weak access
    settings.

.DESCRIPTION
    Checks every storage account for public blob access, permitted network
    rules, HTTPS enforcement, minimum TLS version and shared-key access, then
    enumerates containers with public read. A container set to public read is
    the finding this exists to surface.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER SubscriptionId
    Subscription to operate in. Falls back to azure.defaultSubscriptionId in
    config.json.

.PARAMETER ResourceGroupName
    Limit to specific resource groups.

.PARAMETER SkipContainerScan
    Skip enumerating containers. Faster on large estates, but misses
    container-level exposure.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-AzStorageAccessReview.ps1 -OutputFormat HTML

    Full storage exposure review as HTML.

.EXAMPLE
    .\Get-AzStorageAccessReview.ps1 -ResourceGroupName rg-data -SkipContainerScan

    Account-level settings only.

.NOTES
    Source use case      : #30 - Azure Storage Account Access Review
    Category             : Azure
    Technology           : Az PowerShell / Storage API
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Identify public blob containers"

    Required permissions : Reader on the storage accounts, plus Storage Blob Data Reader to enumerate containers.
    Required modules     : Az.Accounts, Az.Storage
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.Storage

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [string[]]$ResourceGroupName,

    [switch]$SkipContainerScan,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-AzStorageAccessReview'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #30 (Azure)'

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

        $accounts = if ($ResourceGroupName) { $ResourceGroupName | ForEach-Object { Get-AzStorageAccount -ResourceGroupName $_ } }
                    else                    { Get-AzStorageAccount }

        foreach ($sa in $accounts) {
            $issues = @()
            if ($sa.AllowBlobPublicAccess)              { $issues += 'public blob access ALLOWED at account level' }
            if (-not $sa.EnableHttpsTrafficOnly)        { $issues += 'HTTPS not enforced' }
            if ($sa.MinimumTlsVersion -ne 'TLS1_2')     { $issues += ('minimum TLS is {0}' -f $sa.MinimumTlsVersion) }
            if ($sa.NetworkRuleSet.DefaultAction -eq 'Allow') { $issues += 'network default action is Allow (open to all networks)' }
            if ($sa.AllowSharedKeyAccess -ne $false)    { $issues += 'shared key access enabled' }

            $publicContainers = @()
            if (-not $SkipContainerScan -and $sa.AllowBlobPublicAccess) {
                try {
                    $ctx = $sa.Context
                    foreach ($c in (Get-AzStorageContainer -Context $ctx -ErrorAction Stop)) {
                        if ($c.PublicAccess -and "$($c.PublicAccess)" -ne 'Off') {
                            $publicContainers += ('{0}({1})' -f $c.Name, $c.PublicAccess)
                        }
                    }
                    if ($publicContainers.Count -gt 0) {
                        $issues += ('{0} container(s) with public read' -f $publicContainers.Count)
                    }
                } catch {
                    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $sa.StorageAccountName `
                        -Message ('Could not enumerate containers: {0}' -f $_.Exception.Message)
                }
            }

            $results.Add([PSCustomObject]@{
                Name                = $sa.StorageAccountName
                Id                  = $sa.Id
                ResourceGroup       = $sa.ResourceGroupName
                Location            = $sa.Location
                Sku                 = $sa.Sku.Name
                Kind                = "$($sa.Kind)"
                AllowBlobPublicAccess = $sa.AllowBlobPublicAccess
                HttpsOnly           = $sa.EnableHttpsTrafficOnly
                MinimumTlsVersion   = "$($sa.MinimumTlsVersion)"
                NetworkDefaultAction= "$($sa.NetworkRuleSet.DefaultAction)"
                AllowSharedKey      = $sa.AllowSharedKeyAccess
                PublicContainers    = ($publicContainers -join '; ')
                Status              = if ($publicContainers.Count -gt 0) { 'EXPOSED' }
                                      elseif ($issues.Count) { 'Weak' } else { 'OK' }
                Issues              = ($issues -join '; ')
            })
            if ($publicContainers.Count -gt 0) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $sa.StorageAccountName `
                    -Message ('PUBLIC CONTAINERS: {0}' -f ($publicContainers -join ', '))
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Azure Storage Account Access Review'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
