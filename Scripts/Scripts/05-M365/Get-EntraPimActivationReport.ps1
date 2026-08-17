<#
.SYNOPSIS
    Reports Privileged Identity Management role activations.

.DESCRIPTION
    Lists PIM role activations over the lookback window with the activating
    user, role, justification and duration. Activations outside working hours
    and activations without a justification are flagged, since both are worth
    a second look in a privileged-access review.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER LookbackDays
    How far back to report.

.PARAMETER OutOfHoursStart
    Hour after which an activation is considered out of hours.

.PARAMETER OutOfHoursEnd
    Hour before which an activation is considered out of hours.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-EntraPimActivationReport.ps1 -LookbackDays 1

    Daily privileged activation report.

.EXAMPLE
    .\Get-EntraPimActivationReport.ps1 -LookbackDays 7 -OutputFormat HTML

    Weekly report as HTML.

.NOTES
    Source use case      : #11 - Entra ID PIM Role Activation Report
    Category             : M365
    Technology           : Graph API / PIM API
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Daily privileged activation tracking"

    Required permissions : Microsoft Graph RoleAssignmentSchedule.Read.Directory and RoleManagement.Read.Directory. Requires Entra ID P2.
    Required modules     : Microsoft.Graph.Authentication, Microsoft.Graph.Identity.Governance
    Authentication       : App registration with certificate auth (app-only).

    PIM requires an Entra ID P2 licence. Without it these endpoints return
    nothing, which the script reports as an absence of PIM rather than as
    an absence of activations.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication
#Requires -Modules Microsoft.Graph.Identity.Governance

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [ValidateRange(1,90)]
    [int]$LookbackDays = 1,

    [ValidateRange(0,23)]
    [int]$OutOfHoursStart = 19,

    [ValidateRange(0,23)]
    [int]$OutOfHoursEnd = 7,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-EntraPimActivationReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #11 (M365)'

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


        Connect-MgGraph -Scopes 'RoleAssignmentSchedule.Read.Directory','RoleManagement.Read.Directory','Directory.Read.All' -NoWelcome -ErrorAction Stop
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Microsoft Graph'

        $since = (Get-Date).AddDays(-$LookbackDays)

        $requests = @()
        try {
            $requests = @(Get-MgRoleManagementDirectoryRoleAssignmentScheduleRequest -All -ErrorAction Stop |
                          Where-Object { $_.CreatedDateTime -ge $since })
        } catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'PIM data unavailable: {0}. This usually means the tenant lacks Entra ID P2.' -f $_.Exception.Message)
            return
        }

        if ($requests.Count -eq 0) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
                'No PIM activations in the last {0} day(s).' -f $LookbackDays)
        }

        $roleCache = @{}

        foreach ($r in $requests) {
            if ("$($r.Action)" -notmatch 'selfActivate|adminAssign') { continue }

            if (-not $roleCache.ContainsKey($r.RoleDefinitionId)) {
                try {
                    $roleCache[$r.RoleDefinitionId] = (Get-MgRoleManagementDirectoryRoleDefinition `
                        -UnifiedRoleDefinitionId $r.RoleDefinitionId -ErrorAction Stop).DisplayName
                } catch { $roleCache[$r.RoleDefinitionId] = $r.RoleDefinitionId }
            }

            $principal = $r.PrincipalId
            try {
                $u = Get-MgUser -UserId $r.PrincipalId -Property UserPrincipalName,DisplayName -ErrorAction Stop
                $principal = $u.UserPrincipalName
            } catch {
                Write-Verbose ('Could not resolve principal {0}' -f $r.PrincipalId)
            }

            $hour = $r.CreatedDateTime.Hour
            $outOfHours = if ($OutOfHoursStart -gt $OutOfHoursEnd) { ($hour -ge $OutOfHoursStart) -or ($hour -lt $OutOfHoursEnd) }
                          else { ($hour -ge $OutOfHoursStart) -and ($hour -lt $OutOfHoursEnd) }

            $flags = @()
            if ($outOfHours) { $flags += 'activated out of hours' }
            if (-not $r.Justification) { $flags += 'no justification given' }
            if ("$($r.Action)" -eq 'adminAssign') { $flags += 'admin-assigned rather than self-activated' }

            $results.Add([PSCustomObject]@{
                Name          = ('{0} : {1}' -f $principal, $roleCache[$r.RoleDefinitionId])
                Id            = $r.Id
                Principal     = $principal
                RoleName      = $roleCache[$r.RoleDefinitionId]
                Action        = "$($r.Action)"
                Status        = "$($r.Status)"
                ActivatedAt   = $r.CreatedDateTime
                StartDateTime = $r.ScheduleInfo.StartDateTime
                Expiration    = $r.ScheduleInfo.Expiration.EndDateTime
                DurationHours = if ($r.ScheduleInfo.Expiration.Duration) { "$($r.ScheduleInfo.Expiration.Duration)" } else { $null }
                Justification = $r.Justification
                OutOfHours    = $outOfHours
                Flags         = ($flags -join '; ')
            })
            if ($flags.Count) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $principal -Message (
                    '{0} activation: {1}' -f $roleCache[$r.RoleDefinitionId], ($flags -join '; '))
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Entra ID PIM Role Activation Report'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
