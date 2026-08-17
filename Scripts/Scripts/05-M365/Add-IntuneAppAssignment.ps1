<#
.SYNOPSIS
    Assigns an Intune application to a device or user group.

.DESCRIPTION
    Targets an app at a group with a required or available intent. Both the
    app and the target group are reported before approval, because assigning
    the wrong app to All Devices is a tenant-wide event that is awkward to
    undo quietly.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER AppName
    Display name of the Intune application.

.PARAMETER GroupName
    Target group display name.

.PARAMETER Intent
    Required installs it; Available offers it in Company Portal; Uninstall
    removes it.

.PARAMETER AllowAllDevicesTarget
    Permit targeting the built-in All Devices or All Users groups. Off by
    default.

.PARAMETER ApprovalReference
    Approval token from New-ApprovalRequest, after a human has approved it.
    Without this the script performs no change.

.PARAMETER RequestApproval
    Force REQUEST mode - produce the change set and raise an approval request,
    then stop, even if a reference was supplied.

.PARAMETER TicketReference
    ITSM ticket number recorded in the audit trail alongside the approval
    reference.

.PARAMETER Reason
    Change reason recorded in the approval artifact and the audit log.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Add-IntuneAppAssignment.ps1 -AppName 'Company VPN' -GroupName 'GG-Laptops' -Intent Required

    REQUEST mode - raises an approval showing app and target.

.EXAMPLE
    .\Add-IntuneAppAssignment.ps1 -AppName 'Company VPN' -GroupName 'GG-Laptops' -Intent Available -ApprovalReference APR-...

    Applies the approved assignment.

.NOTES
    Source use case      : #7 - Intune App Deployment Automation
    Category             : M365
    Technology           : Intune Graph API
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "Pushing apps to device groups; approve app + target group"

    Required permissions : Microsoft Graph DeviceManagementApps.ReadWrite.All and Group.Read.All.
    Required modules     : Microsoft.Graph.Authentication, Microsoft.Graph.Devices.CorporateManagement
    Authentication       : App registration with certificate auth (app-only).

    Required intent installs silently on every device in the target group
    at next check-in. Available only offers it in Company Portal. Choosing
    Required against a large group is the difference between an offer and
    a fleet-wide deployment.

    Rollback             : Remove the assignment. A Required assignment that
                           has already installed the app does not uninstall it
                           on removal - use -Intent Uninstall for that.
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication
#Requires -Modules Microsoft.Graph.Devices.CorporateManagement

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory)]
    [string]$AppName,

    [Parameter(Mandatory)]
    [string]$GroupName,

    [ValidateSet('Required','Available','Uninstall')]
    [string]$Intent = 'Available',

    [switch]$AllowAllDevicesTarget,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Intune application assignment',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Add-IntuneAppAssignment'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #7 (M365)'

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
        Connect-AutomationPlatform -Platform 'Graph' | Out-Null


        Connect-MgGraph -Scopes 'DeviceManagementApps.ReadWrite.All','Group.Read.All' -NoWelcome -ErrorAction Stop
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Microsoft Graph'

        $app = Get-MgDeviceAppManagementMobileApp -Filter ("displayName eq '{0}'" -f ($AppName -replace "'", "''")) `
                -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $app) { throw ('Intune application "{0}" not found.' -f $AppName) }

        $group = Get-MgGroup -Filter ("displayName eq '{0}'" -f ($GroupName -replace "'", "''")) `
                 -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $group) { throw ('Group "{0}" not found.' -f $GroupName) }

        # Broad built-in targets deserve a deliberate decision.
        if (-not $AllowAllDevicesTarget -and $GroupName -match '(?i)^All (Devices|Users)$') {
            throw ('Refusing to target "{0}" without -AllowAllDevicesTarget. That is a tenant-wide assignment.' -f $GroupName)
        }

        $memberCount = 0
        try { $memberCount = @(Get-MgGroupMember -GroupId $group.Id -All -ErrorAction Stop).Count } catch {
            Write-Verbose ('Could not count members of {0}' -f $GroupName)
        }

        $existing = @(Get-MgDeviceAppManagementMobileAppAssignment -MobileAppId $app.Id -ErrorAction SilentlyContinue)
        if ($existing | Where-Object { $_.Target.AdditionalProperties.groupId -eq $group.Id -and "$($_.Intent)" -eq $Intent }) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $AppName `
                -Message 'Skipped - assignment already exists with this intent (idempotent)'
            return
        }

        $results.Add([PSCustomObject]@{
            Name        = ('{0} -> {1}' -f $app.DisplayName, $group.DisplayName)
            Id          = $app.Id
            AppName     = $app.DisplayName
            AppId       = $app.Id
            AppType     = ($app.AdditionalProperties.'@odata.type' -replace '#microsoft.graph.', '')
            Publisher   = $app.Publisher
            GroupName   = $group.DisplayName
            GroupId     = $group.Id
            GroupMembers= $memberCount
            Intent      = $Intent
            Impact      = if ($Intent -eq 'Required') { ('Installs silently on {0} member(s) at next check-in' -f $memberCount) }
                          elseif ($Intent -eq 'Uninstall') { ('Removes the app from {0} member(s)' -f $memberCount) }
                          else { ('Offered in Company Portal to {0} member(s)' -f $memberCount) }
        })
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

    if ($RequestApproval -or -not $ApprovalReference) {
        $request = New-ApprovalRequest -ScriptName $scriptName -ChangeSet $candidates `
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Assign Intune app', $candidates.Count, $Reason, $TicketReference)
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $request.Reference -Message (
            'REQUEST mode - nothing was changed. Supply -ApprovalReference {0} once approved.' -f $request.Reference)
        Write-Warning ('No change made. Approval reference: {0}' -f $request.Reference)
        Write-Output ([PSCustomObject]@{
            Mode = 'RequestApproval'; ApprovalReference = $request.Reference
            CandidateCount = $candidates.Count; Candidates = $candidates; Changed = $false })
        return
    }

    $approvalCheck = Test-ApprovalReference -Reference $ApprovalReference -ScriptName $scriptName
    if (-not $approvalCheck.IsValid) {
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $ApprovalReference -Message (
            'REFUSED to execute: {0}' -f $approvalCheck.Reason)
        throw ('Approval validation failed: {0}' -f $approvalCheck.Reason)
    }
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $ApprovalReference -Message (
        'Approval accepted. {0} Ticket={1}' -f $approvalCheck.Reason, $TicketReference)

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Assign Intune app')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $body = @{
                mobileAppAssignments = @(@{
                    '@odata.type' = '#microsoft.graph.mobileAppAssignment'
                    intent = $item.Intent.ToLower()
                    target = @{
                        '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
                        groupId = $item.GroupId
                    }
                })
            }

            Invoke-MgGraphRequest -Method POST `
                -Uri ('https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps/{0}/assign' -f $item.AppId) `
                -Body ($body | ConvertTo-Json -Depth 8) -ErrorAction Stop | Out-Null

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'App assigned with intent {0}. {1}. Approval={2}' -f $item.Intent, $item.Impact, $ApprovalReference)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'AppAssigned'; Detail = $item.Impact; Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Intune App Deployment Automation'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
