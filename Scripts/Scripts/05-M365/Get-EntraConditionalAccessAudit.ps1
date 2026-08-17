<#
.SYNOPSIS
    Exports and audits Entra ID Conditional Access policies.

.DESCRIPTION
    Exports every Conditional Access policy with its conditions, grant
    controls and state, flagging the configurations worth questioning:
    policies left in report-only, policies with no MFA requirement, and
    excluded users who quietly bypass the control.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER IncludeDisabled
    Include policies that are disabled.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-EntraConditionalAccessAudit.ps1 -OutputFormat HTML

    Full CA policy export as HTML.

.EXAMPLE
    .\Get-EntraConditionalAccessAudit.ps1 -IncludeDisabled -OutputFormat JSON

    Everything including disabled policies.

.NOTES
    Source use case      : #10 - Entra ID Conditional Access Policy Audit
    Category             : M365
    Technology           : Graph API / PowerShell
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Export and review CA policies"

    Required permissions : Microsoft Graph Policy.Read.All.
    Required modules     : Microsoft.Graph.Authentication, Microsoft.Graph.Identity.SignIns
    Authentication       : App registration with certificate auth (app-only).

    An exclusion list is the usual place a Conditional Access policy is
    undermined. Break-glass accounts belong there deliberately; anything
    else in the list should be justified, so exclusions are reported
    explicitly rather than summarised away.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication
#Requires -Modules Microsoft.Graph.Identity.SignIns

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [switch]$IncludeDisabled,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-EntraConditionalAccessAudit'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #10 (M365)'

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


        Connect-MgGraph -Scopes 'Policy.Read.All' -NoWelcome -ErrorAction Stop
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Microsoft Graph'

        $policies = Get-MgIdentityConditionalAccessPolicy -All -ErrorAction Stop

        foreach ($p in $policies) {
            if (-not $IncludeDisabled -and "$($p.State)" -eq 'disabled') { continue }

            $grants = @($p.GrantControls.BuiltInControls)
            $excludedUsers = @($p.Conditions.Users.ExcludeUsers)
            $excludedGroups = @($p.Conditions.Users.ExcludeGroups)
            $excludedRoles = @($p.Conditions.Users.ExcludeRoles)

            $issues = @()
            if ("$($p.State)" -eq 'enabledForReportingButNotEnforced') { $issues += 'REPORT-ONLY - not enforcing' }
            if ($grants -notcontains 'mfa' -and $grants -notcontains 'compliantDevice' -and
                $grants -notcontains 'domainJoinedDevice') { $issues += 'no MFA or device requirement' }
            if (($excludedUsers.Count + $excludedGroups.Count + $excludedRoles.Count) -gt 0) {
                $issues += ('{0} exclusion(s) bypass this policy' -f ($excludedUsers.Count + $excludedGroups.Count + $excludedRoles.Count))
            }
            if ($p.Conditions.Users.IncludeUsers -contains 'All' -and $excludedUsers.Count -eq 0 -and
                $excludedGroups.Count -eq 0) {
                $issues += 'applies to All users with no break-glass exclusion'
            }

            $results.Add([PSCustomObject]@{
                Name            = $p.DisplayName
                Id              = $p.Id
                State           = "$($p.State)"
                CreatedAt       = $p.CreatedDateTime
                ModifiedAt      = $p.ModifiedDateTime
                IncludeUsers    = (($p.Conditions.Users.IncludeUsers) -join '; ')
                ExcludeUsers    = ($excludedUsers -join '; ')
                ExcludeGroups   = ($excludedGroups -join '; ')
                ExcludeRoles    = ($excludedRoles -join '; ')
                IncludeApps     = (($p.Conditions.Applications.IncludeApplications) -join '; ')
                ClientAppTypes  = (($p.Conditions.ClientAppTypes) -join '; ')
                Platforms       = (($p.Conditions.Platforms.IncludePlatforms) -join '; ')
                Locations       = (($p.Conditions.Locations.IncludeLocations) -join '; ')
                GrantControls   = ($grants -join '; ')
                GrantOperator   = "$($p.GrantControls.Operator)"
                SessionControls = if ($p.SessionControls) { 'configured' } else { 'none' }
                Status          = if ($issues.Count) { 'Review' } else { 'OK' }
                Issues          = ($issues -join '; ')
            })
            if ($issues.Count) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $p.DisplayName -Message ($issues -join '; ')
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Entra ID Conditional Access Policy Audit'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
