<#
.SYNOPSIS
    Audits Power Platform connectors used in flows and apps.

.DESCRIPTION
    Reports which connectors are in use across environments and flags those
    outside the approved list. Non-standard connectors are how corporate data
    leaves the tenant through a flow nobody reviewed, which is what makes this
    an audit rather than an inventory.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER ApprovedConnector
    Connectors considered standard. Anything else is flagged.

.PARAMETER EnvironmentName
    Limit to specific Power Platform environments.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-PowerPlatformConnectorAudit.ps1 -OutputFormat HTML

    Connector audit across all environments.

.EXAMPLE
    .\Get-PowerPlatformConnectorAudit.ps1 -ApprovedConnector shared_sharepointonline,shared_teams

    Audits against a tighter allow-list.

.NOTES
    Source use case      : #22 - Power Platform Connector Governance
    Category             : M365
    Technology           : Power Platform API
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Audit non-standard connectors in flows/apps"

    Required permissions : Power Platform administrator. Uses the Power Platform admin REST API through the Graph token.
    Required modules     : Microsoft.Graph.Authentication
    Authentication       : App registration with certificate auth (app-only).

    Requires the Power Platform admin API, which is a separate endpoint
    from Graph and needs a Power Platform administrator role. The
    Microsoft.PowerApps.Administration.PowerShell module is the supported
    alternative and may be simpler in an environment where that role is
    already delegated.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string[]]$ApprovedConnector = @('shared_sharepointonline','shared_office365','shared_office365users','shared_teams','shared_excelonlinebusiness','shared_onedriveforbusiness','shared_approvals','shared_flowpush'),

    [string[]]$EnvironmentName,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-PowerPlatformConnectorAudit'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #22 (M365)'

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


        Connect-MgGraph -Scopes 'https://service.powerapps.com/.default' -NoWelcome -ErrorAction Stop
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected for Power Platform admin API access'

        $apiBase = 'https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform'

        $environments = @()
        try {
            $envResp = Invoke-MgGraphRequest -Method GET `
                -Uri ('{0}/scopes/admin/environments?api-version=2020-10-01' -f $apiBase) -ErrorAction Stop
            $environments = @($envResp.value)
        } catch {
            throw ('Power Platform admin API unavailable: {0}. This needs a Power Platform administrator role, ' +
                   'or use the Microsoft.PowerApps.Administration.PowerShell module instead.' -f $_.Exception.Message)
        }

        foreach ($ppEnv in $environments) {
            $envDisplay = $ppEnv.properties.displayName
            if ($EnvironmentName -and $EnvironmentName -notcontains $envDisplay) { continue }

            $flows = @()
            try {
                $flowResp = Invoke-MgGraphRequest -Method GET `
                    -Uri ('{0}/scopes/admin/environments/{1}/v2/flows?api-version=2016-11-01' -f $apiBase, $ppEnv.name) `
                    -ErrorAction Stop
                $flows = @($flowResp.value)
            } catch {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $envDisplay `
                    -Message ('Could not enumerate flows: {0}' -f $_.Exception.Message)
                continue
            }

            foreach ($flow in $flows) {
                $connectors = @()
                foreach ($ref in $flow.properties.connectionReferences.PSObject.Properties) {
                    $connectors += $ref.Value.id -replace '^.*/apis/', ''
                }
                $connectors = @($connectors | Select-Object -Unique)
                $nonStandard = @($connectors | Where-Object { $ApprovedConnector -notcontains $_ })

                if ($nonStandard.Count -eq 0) { continue }

                $results.Add([PSCustomObject]@{
                    Name          = ('{0} / {1}' -f $envDisplay, $flow.properties.displayName)
                    Id            = $flow.name
                    Environment   = $envDisplay
                    FlowName      = $flow.properties.displayName
                    FlowState     = $flow.properties.state
                    Owner         = $flow.properties.creator.userId
                    CreatedAt     = $flow.properties.createdTime
                    AllConnectors = ($connectors -join '; ')
                    NonStandardConnectors = ($nonStandard -join '; ')
                    NonStandardCount = $nonStandard.Count
                    Risk          = 'Non-approved connector may move corporate data outside reviewed channels'
                })
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $flow.properties.displayName `
                    -Message ('Non-standard connector(s): {0}' -f ($nonStandard -join ', '))
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Power Platform Connector Governance'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
