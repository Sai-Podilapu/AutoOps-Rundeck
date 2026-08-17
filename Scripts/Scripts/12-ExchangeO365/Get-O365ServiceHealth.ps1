<#
.SYNOPSIS
    Reports current Microsoft 365 service health and active incidents.

.DESCRIPTION
    Pulls the tenant's service health overview and any active incidents or
    advisories from Microsoft Graph, so a user-reported "Outlook is slow" can
    be checked against a known Microsoft-side incident before anyone starts
    investigating locally.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER IncludeAdvisories
    Include advisories as well as incidents. Advisories are informational and
    noisy.

.PARAMETER ServiceFilter
    Limit to specific services, e.g. Exchange Online.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-O365ServiceHealth.ps1 

    Current service health and active incidents.

.EXAMPLE
    .\Get-O365ServiceHealth.ps1 -ServiceFilter 'Exchange Online' -IncludeAdvisories

    Exchange only, including advisories.

.NOTES
    Source use case      : #2 - O365 Health Check
    Category             : Exchange & O365
    Technology           : PowerShell
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Read-only"

    Required permissions : Microsoft Graph ServiceHealth.Read.All.
    Required modules     : Microsoft.Graph.Authentication
    Authentication       : App-only certificate auth via
                           Connect-ExchangeOnline.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [switch]$IncludeAdvisories,

    [string[]]$ServiceFilter,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-O365ServiceHealth'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #2 (Exchange & O365)'

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
        Connect-AutomationPlatform -Platform 'ExchangeOnline' | Out-Null


        Connect-MgGraph -Scopes 'ServiceHealth.Read.All' -NoWelcome -ErrorAction Stop

        $overview = Invoke-MgGraphRequest -Method GET `
            -Uri 'https://graph.microsoft.com/v1.0/admin/serviceAnnouncement/healthOverviews' -ErrorAction Stop

        foreach ($svc in $overview.value) {
            if ($ServiceFilter -and $ServiceFilter -notcontains $svc.service) { continue }
            $results.Add([PSCustomObject]@{
                Name        = $svc.service
                Id          = $svc.id
                RecordType  = 'ServiceStatus'
                Status      = $svc.status
                Title       = $null
                Classification = $null
                StartDateTime  = $null
                LastUpdated = $null
                IsResolved  = $null
                Detail      = ('Service status: {0}' -f $svc.status)
            })
        }

        $issues = Invoke-MgGraphRequest -Method GET `
            -Uri 'https://graph.microsoft.com/v1.0/admin/serviceAnnouncement/issues' -ErrorAction Stop

        foreach ($i in $issues.value) {
            if ($ServiceFilter -and $ServiceFilter -notcontains $i.service) { continue }
            if (-not $IncludeAdvisories -and $i.classification -ne 'incident') { continue }
            if ($i.isResolved) { continue }

            $results.Add([PSCustomObject]@{
                Name        = $i.service
                Id          = $i.id
                RecordType  = 'ActiveIssue'
                Status      = $i.status
                Title       = $i.title
                Classification = $i.classification
                StartDateTime  = $i.startDateTime
                LastUpdated = $i.lastModifiedDateTime
                IsResolved  = $i.isResolved
                Detail      = $i.impactDescription
            })
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $i.service -Message (
                'Active {0}: {1} ({2})' -f $i.classification, $i.title, $i.id)
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'O365 Health Check'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
