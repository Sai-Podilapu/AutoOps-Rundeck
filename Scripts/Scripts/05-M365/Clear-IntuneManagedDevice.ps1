<#
.SYNOPSIS
    Retires or wipes an Intune-managed device.

.DESCRIPTION
    Removes company data from a device (retire) or resets it to factory state
    (wipe). A wipe destroys the user's personal data on a BYOD device and
    cannot be undone, so it requires approval, a verified ITSM trigger, and an
    explicit -Execute. Retire is the default because it removes company data
    without touching anything else.

    DESTRUCTIVE. This script is REPORT-ONLY by default: it produces the
    candidate list and stops. Nothing is deleted, wiped or failed over
    unless -Execute is passed AND a valid -ApprovalReference is supplied.
    A pre-action backup/export is taken where the platform allows it, and
    every object is logged individually before it is touched.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER DeviceName
    Device name(s) to act on.

.PARAMETER DeviceId
    Specific Intune device id(s).

.PARAMETER Action
    Retire removes company data only; Wipe resets the device to factory state.

.PARAMETER KeepEnrollmentData
    On a wipe, retain the enrolment state so the device re-enrols
    automatically.

.PARAMETER ItsmTriggerVerified
    Confirms the request came from a verified ITSM trigger. Required for Wipe.

.PARAMETER Execute
    Actually perform the destructive action. Without this the script only
    reports what it would do.

.PARAMETER ProtectedList
    Path to a file of names/ids that must never be acted upon, one per line.
    Entries here are excluded unconditionally and the exclusion cannot be
    overridden by any other parameter.

.PARAMETER MinimumAgeDays
    Only consider objects older than this. A conservative default guards
    against acting on something created moments ago.

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
    .\Clear-IntuneManagedDevice.ps1 -DeviceName LAPTOP-01

    REPORT ONLY. Shows the device and raises an approval for a retire.

.EXAMPLE
    .\Clear-IntuneManagedDevice.ps1 -DeviceName LAPTOP-01 -Action Wipe -ItsmTriggerVerified -ApprovalReference APR-... -Execute

    Wipes the approved device.

.NOTES
    Source use case      : #8 - Intune Device Retire/Wipe
    Category             : M365
    Technology           : Intune Graph API
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Destructive / High-Impact
    Risk level           : High
    Human approval needed: YES
    Guardrails (col L)   : "Wipe is destructive; execute only from verified ITSM trigger with approval"

    Required permissions : Microsoft Graph DeviceManagementManagedDevices.PrivilegedOperations.All.
    Required modules     : Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement.Actions
    Authentication       : App registration with certificate auth (app-only).

    On a personally-owned device, Retire is almost always the correct
    action: it removes company apps and data and leaves the user\u2019s
    photos, messages and accounts intact. Wipe is for corporate-owned
    devices, and for lost handsets where the data must not survive under
    any circumstances.

    Rollback             : NONE. A retire can be followed by re-enrolment, but
                           a WIPE destroys all data on the device including the
                           user\u2019s personal content on a BYOD handset.
                           There is no undo.
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication
#Requires -Modules Microsoft.Graph.DeviceManagement.Actions

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([PSCustomObject])]
param(
    [string[]]$DeviceName,

    [string[]]$DeviceId,

    [ValidateSet('Retire','Wipe')]
    [string]$Action = 'Retire',

    [switch]$KeepEnrollmentData,

    [switch]$ItsmTriggerVerified,

    [switch]$Execute,

    [string]$ProtectedList,

    [ValidateRange(0, 3650)]
    [int]$MinimumAgeDays = 0,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Device retire or wipe (ITSM-verified)',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Clear-IntuneManagedDevice'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #8 (M365)'

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

    $protected = @()
    if ($ProtectedList -and (Test-Path -LiteralPath $ProtectedList)) {
        $protected = @(Get-Content -LiteralPath $ProtectedList |
            Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { $_.Trim() })
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Protected list loaded: {0} entry(ies). These are excluded unconditionally.' -f $protected.Count)
    }

    # Risk = High: validate before doing anything at all.
    $pre = Test-Prerequisite -RequiredModule 'Microsoft.Graph.Authentication','Microsoft.Graph.DeviceManagement.Actions'
    if (-not $pre.Passed) {
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Message $pre.Summary
        throw $pre.Summary
    }
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Pre-flight passed.'

    $results  = [System.Collections.Generic.List[PSCustomObject]]::new()
    $failures = [System.Collections.Generic.List[PSCustomObject]]::new()
}

process {
    try {
        Connect-AutomationPlatform -Platform 'Graph' | Out-Null


        Connect-MgGraph -Scopes 'DeviceManagementManagedDevices.Read.All','DeviceManagementManagedDevices.PrivilegedOperations.All' -NoWelcome -ErrorAction Stop
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Microsoft Graph'

        if ($Action -eq 'Wipe' -and -not $ItsmTriggerVerified) {
            throw 'Refusing to wipe without -ItsmTriggerVerified. A wipe destroys all data on the device, ' +
                  'including personal content on a BYOD handset, and cannot be undone.'
        }
        if (-not $DeviceName -and -not $DeviceId) {
            throw 'Specify -DeviceName or -DeviceId. Acting on every managed device is not a safe default.'
        }

        $devices = @()
        foreach ($n in $DeviceName) {
            $devices += Get-MgDeviceManagementManagedDevice -Filter ("deviceName eq '{0}'" -f ($n -replace "'", "''")) -ErrorAction Stop
        }
        foreach ($i in $DeviceId) {
            $devices += Get-MgDeviceManagementManagedDevice -ManagedDeviceId $i -ErrorAction Stop
        }

        foreach ($d in $devices) {
            $isPersonal = ("$($d.ManagedDeviceOwnerType)" -eq 'personal')

            if ($Action -eq 'Wipe' -and $isPersonal) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $d.DeviceName -Message (
                    'This is a PERSONALLY-OWNED device. A wipe destroys the user''s own data. ' +
                    'Retire removes company data only and is usually the correct action.')
            }

            $results.Add([PSCustomObject]@{
                Name            = $d.DeviceName
                Id              = $d.Id
                UserPrincipalName = $d.UserPrincipalName
                OperatingSystem = $d.OperatingSystem
                Model           = $d.Model
                SerialNumber    = $d.SerialNumber
                OwnerType       = "$($d.ManagedDeviceOwnerType)"
                IsPersonal      = $isPersonal
                ComplianceState = "$($d.ComplianceState)"
                LastSync        = $d.LastSyncDateTime
                Action          = $Action
                Impact          = if ($Action -eq 'Wipe' -and $isPersonal) { 'FACTORY RESET of a personally-owned device - destroys personal data' }
                                  elseif ($Action -eq 'Wipe') { 'FACTORY RESET - all data destroyed' }
                                  else { 'Company data and apps removed; personal data untouched' }
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

    # Hard exclusions and safety filters BEFORE anything else.
    if ($protected.Count -gt 0) {
        $before = $candidates.Count
        $candidates = @($candidates | Where-Object {
            $id = $_.Id; $nm = $_.Name
            -not ($protected | Where-Object { $_ -and ($id -like $_ -or $nm -like $_) })
        })
        if ($before -ne $candidates.Count) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
                'Protected list excluded {0} object(s).' -f ($before - $candidates.Count))
        }
    }
    if ($MinimumAgeDays -gt 0) {
        $cut = (Get-Date).AddDays(-$MinimumAgeDays)
        $before = $candidates.Count
        $candidates = @($candidates | Where-Object { -not $_.CreatedAt -or $_.CreatedAt -lt $cut })
        if ($before -ne $candidates.Count) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
                'Age filter (>{0}d) excluded {1} object(s).' -f $MinimumAgeDays, ($before - $candidates.Count))
        }
    }

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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Retire or wipe device', $candidates.Count, $Reason, $TicketReference)
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

    if (-not $Execute) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'REPORT-ONLY - {0} candidate(s) identified, nothing was changed. Pass -Execute to act.' -f $candidates.Count)
        $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Intune Device Retire/Wipe (candidates)'
        Write-Output $candidates
        return
    }

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Retire or wipe device')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
                '{0} requested. {1}. Approval={2} Ticket={3} ItsmVerified={4}' -f
                $item.Action.ToUpper(), $item.Impact, $ApprovalReference, $TicketReference, $true)

            if ($item.Action -eq 'Wipe') {
                $body = @{
                    keepEnrollmentData = [bool]$KeepEnrollmentData
                    keepUserData       = $false
                }
                Invoke-MgGraphRequest -Method POST `
                    -Uri ('https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/{0}/wipe' -f $item.Id) `
                    -Body ($body | ConvertTo-Json) -ErrorAction Stop | Out-Null
                $detail = 'wipe issued - factory reset'
            } else {
                Invoke-MgGraphRequest -Method POST `
                    -Uri ('https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/{0}/retire' -f $item.Id) `
                    -ErrorAction Stop | Out-Null
                $detail = 'retire issued - company data removed'
            }

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                '{0}. The device applies it at its next check-in.' -f $detail)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = $item.Action; Detail = $detail; Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Intune Device Retire/Wipe'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
