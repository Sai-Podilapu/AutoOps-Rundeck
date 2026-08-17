<#
.SYNOPSIS
    Reports privileged role membership and privileged actions taken.

.DESCRIPTION
    Reports who currently holds a privileged directory role and what
    privileged operations were performed over the reporting window. Standing
    membership and actual use are different questions, and both are answered
    here - an account with permanent Global Administrator and no activity is
    its own kind of finding.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER LookbackHours
    Reporting window for privileged actions.

.PARAMETER PrivilegedRole
    Roles considered privileged.

.PARAMETER MaxAuditRecords
    Ceiling on audit records retrieved.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-PrivilegedAccountUsageReport.ps1 -LookbackHours 24 -OutputFormat HTML

    Daily privileged usage report.

.EXAMPLE
    .\Get-PrivilegedAccountUsageReport.ps1 -LookbackHours 168 -PrivilegedRole 'Global Administrator'

    A week of Global Admin activity.

.NOTES
    Source use case      : #4 - Privileged Account Usage Report
    Category             : Security Cloud
    Technology           : Graph API / PIM / SIEM
    Difficulty           : Low
    Agent possible       : Partial
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Daily report of privileged actions"

    Required permissions : Microsoft Graph RoleManagement.Read.Directory, AuditLog.Read.All, Directory.Read.All.
    Required modules     : Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Reports
    Authentication       : Vendor REST API via Invoke-RestMethod, or Graph
                           where the tool is Microsoft.

    Standing (permanent) membership is separated from eligible (PIM)
    membership in the report. The distinction matters more than the count:
    ten eligible admins who activate with justification is a healthier
    posture than three permanent ones.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication
#Requires -Modules Microsoft.Graph.Identity.DirectoryManagement
#Requires -Modules Microsoft.Graph.Reports

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [ValidateRange(1,720)]
    [int]$LookbackHours = 24,

    [string[]]$PrivilegedRole = @('Global Administrator','Privileged Role Administrator','Security Administrator','Exchange Administrator','SharePoint Administrator','User Administrator','Application Administrator','Conditional Access Administrator'),

    [ValidateRange(50,10000)]
    [int]$MaxAuditRecords = 2000,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-PrivilegedAccountUsageReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #4 (Security Cloud)'

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


        Connect-MgGraph -Scopes 'RoleManagement.Read.Directory','AuditLog.Read.All','Directory.Read.All' -NoWelcome -ErrorAction Stop
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Microsoft Graph'

        $roles = @(Get-MgDirectoryRole -All -ErrorAction Stop)
        $privilegedIds = @{}

        foreach ($role in $roles) {
            if ($PrivilegedRole -notcontains $role.DisplayName) { continue }

            $members = @()
            try { $members = @(Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id -All -ErrorAction Stop) } catch {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $role.DisplayName `
                    -Message ('Members unreadable: {0}' -f $_.Exception.Message)
                continue
            }

            foreach ($member in $members) {
                $upn = $member.AdditionalProperties.userPrincipalName
                if (-not $upn) { $upn = $member.AdditionalProperties.displayName }
                $privilegedIds[$member.Id] = $upn

                $results.Add([PSCustomObject]@{
                    Name           = ('{0} / {1}' -f $role.DisplayName, $upn)
                    Id             = $member.Id
                    RecordType     = 'Membership'
                    RoleName       = $role.DisplayName
                    Principal      = $upn
                    PrincipalType  = ($member.AdditionalProperties.'@odata.type' -replace '#microsoft.graph.', '')
                    Assignment     = 'Standing (permanent)'
                    Operation      = ''
                    ActivityTime   = $null
                    Result         = ''
                    Detail         = 'Permanent membership - active whether or not it is being used'
                })
            }
        }

        # Eligible (PIM) assignments are a different posture from permanent ones.
        try {
            $eligible = @(Get-MgRoleManagementDirectoryRoleEligibilityScheduleInstance -All -ErrorAction Stop)
            foreach ($e in $eligible) {
                $roleName = ''
                try {
                    $def = Get-MgRoleManagementDirectoryRoleDefinition -UnifiedRoleDefinitionId $e.RoleDefinitionId -ErrorAction Stop
                    $roleName = $def.DisplayName
                } catch { $roleName = $e.RoleDefinitionId }
                if ($PrivilegedRole -notcontains $roleName) { continue }

                $results.Add([PSCustomObject]@{
                    Name          = ('{0} / {1}' -f $roleName, $e.PrincipalId)
                    Id            = $e.Id
                    RecordType    = 'Membership'
                    RoleName      = $roleName
                    Principal     = $e.PrincipalId
                    PrincipalType = 'user'
                    Assignment    = 'Eligible (PIM)'
                    Operation     = ''
                    ActivityTime  = $null
                    Result        = ''
                    Detail        = 'Eligible only - requires activation, which is the healthier posture'
                })
            }
        } catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'PIM eligibility unavailable ({0}); standing membership is reported without it. This is a ' +
                'P2 feature and its absence is not evidence that nobody is eligible.' -f $_.Exception.Message)
        }

        # What was actually done.
        $since = (Get-Date).AddHours(-$LookbackHours).ToString('yyyy-MM-ddTHH:mm:ssZ')
        try {
            $audit = @(Get-MgAuditLogDirectoryAudit -Filter ("activityDateTime ge {0}" -f $since) -Top $MaxAuditRecords -ErrorAction Stop)
            foreach ($record in $audit) {
                $actor = $record.InitiatedBy.User.UserPrincipalName
                if (-not $actor) { continue }
                if (-not ($privilegedIds.Values -contains $actor)) { continue }

                $results.Add([PSCustomObject]@{
                    Name          = ('{0}: {1}' -f $actor, $record.ActivityDisplayName)
                    Id            = $record.Id
                    RecordType    = 'Activity'
                    RoleName      = ''
                    Principal     = $actor
                    PrincipalType = 'user'
                    Assignment    = ''
                    Operation     = $record.ActivityDisplayName
                    ActivityTime  = $record.ActivityDateTime
                    Result        = "$($record.Result)"
                    Detail        = (($record.TargetResources | ForEach-Object { $_.DisplayName }) -join '; ')
                })
            }
        } catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'Directory audit log unavailable: {0}. Membership is reported without activity.' -f $_.Exception.Message)
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Privileged Account Usage Report'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
