<#
.SYNOPSIS
    Reports Intune device compliance state with owner detail.

.DESCRIPTION
    Lists managed devices with their compliance state, last sync and enrolled
    owner. Devices that have not checked in for a long time are reported
    separately from non-compliant ones, because a stale device is not the same
    problem as a failing one.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER OnlyNonCompliant
    Report only devices that are not compliant.

.PARAMETER StaleSyncDays
    Flag devices that have not synced for this many days.

.PARAMETER OperatingSystem
    Limit to specific platforms.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-IntuneDeviceCompliance.ps1 -OnlyNonCompliant -OutputFormat HTML

    Non-compliant devices with owners, as HTML.

.EXAMPLE
    .\Get-IntuneDeviceCompliance.ps1 -StaleSyncDays 30 -OperatingSystem Windows

    Stale Windows devices only.

.NOTES
    Source use case      : #6 - Intune Device Compliance Report
    Category             : M365
    Technology           : Graph API / Intune
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Non-compliant device report with owner info"

    Required permissions : Microsoft Graph DeviceManagementManagedDevices.Read.All.
    Required modules     : Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement
    Authentication       : App registration with certificate auth (app-only).

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication
#Requires -Modules Microsoft.Graph.DeviceManagement

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [switch]$OnlyNonCompliant,

    [ValidateRange(1,365)]
    [int]$StaleSyncDays = 14,

    [string[]]$OperatingSystem,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-IntuneDeviceCompliance'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #6 (M365)'

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


        Connect-MgGraph -Scopes 'DeviceManagementManagedDevices.Read.All' -NoWelcome -ErrorAction Stop
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Microsoft Graph'

        $devices = Get-MgDeviceManagementManagedDevice -All -ErrorAction Stop

        foreach ($d in $devices) {
            if ($OperatingSystem -and $OperatingSystem -notcontains $d.OperatingSystem) { continue }

            $staleDays = if ($d.LastSyncDateTime) {
                             [math]::Round(((Get-Date) - $d.LastSyncDateTime).TotalDays, 1)
                         } else { $null }

            $issues = @()
            if ($d.ComplianceState -ne 'compliant') { $issues += ('compliance: {0}' -f $d.ComplianceState) }
            if ($null -eq $staleDays)               { $issues += 'never synced' }
            elseif ($staleDays -gt $StaleSyncDays)  { $issues += ('last sync {0}d ago' -f $staleDays) }
            if ($d.IsEncrypted -eq $false)          { $issues += 'not encrypted' }
            if ($d.JailBroken -eq 'True')           { $issues += 'JAILBROKEN' }

            if ($OnlyNonCompliant -and $issues.Count -eq 0) { continue }

            $results.Add([PSCustomObject]@{
                Name            = $d.DeviceName
                Id              = $d.Id
                UserPrincipalName = $d.UserPrincipalName
                UserDisplayName = $d.UserDisplayName
                OperatingSystem = $d.OperatingSystem
                OsVersion       = $d.OsVersion
                Model           = $d.Model
                Manufacturer    = $d.Manufacturer
                SerialNumber    = $d.SerialNumber
                ComplianceState = "$($d.ComplianceState)"
                OwnerType       = "$($d.ManagedDeviceOwnerType)"
                EnrolledOn      = $d.EnrolledDateTime
                LastSync        = $d.LastSyncDateTime
                StaleDays       = $staleDays
                IsEncrypted     = $d.IsEncrypted
                JailBroken      = $d.JailBroken
                Status          = if ($issues.Count) { 'NonCompliant' } else { 'Compliant' }
                Issues          = ($issues -join '; ')
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

    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message ('Collected {0} record(s).' -f $candidates.Count)
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Intune Device Compliance Report'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
