<#
.SYNOPSIS
    Blocks or allows a mobile device's access to a mailbox.

.DESCRIPTION
    Changes the ActiveSync access state for a specific device. Blocking a
    device cuts mail access from it immediately, which is what you want for a
    lost handset and disruptive if the device id is wrong - so the script
    reports the device's identity and last sync time before the change is
    approved.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER Mailbox
    Mailbox owning the device.

.PARAMETER Operation
    Block or Allow.

.PARAMETER DeviceId
    Specific device id(s). All devices for the mailbox when omitted.

.PARAMETER StaleDays
    When -DeviceId is omitted, only act on devices that have not synced for
    this long.

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
    .\Set-ExoMobileDeviceAccess.ps1 -Mailbox user@contoso.com -Operation Block -DeviceId ABC123 -TicketReference INC0012345

    REQUEST mode - raises an approval to block one device.

.EXAMPLE
    .\Set-ExoMobileDeviceAccess.ps1 -Mailbox user@contoso.com -Operation Block -StaleDays 90 -ApprovalReference APR-...

    Blocks devices that have not synced in 90 days.

.NOTES
    Source use case      : #25 - Block/Unblock Mobile Devices
    Category             : Exchange & O365
    Technology           : Intune / EXO PowerShell
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "Device access change; ticket-driven"

    Required permissions : Exchange Online Recipient Management.
    Required modules     : ExchangeOnlineManagement
    Authentication       : App-only certificate auth via
                           Connect-ExchangeOnline.

    This changes ACCESS only. It does not wipe the device and does not
    remove company data already on it. For a lost device where data
    removal is required, use an Intune wipe as a separate, deliberate
    action.

    Rollback             : Re-run with the opposite -Operation. Blocking is
                           immediately reversible; note that a wiped device is
                           not, and this script never wipes.
#>

#Requires -Version 5.1
#Requires -Modules ExchangeOnlineManagement

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory)]
    [string]$Mailbox,

    [Parameter(Mandatory)]
    [ValidateSet('Block','Allow')]
    [string]$Operation,

    [string[]]$DeviceId,

    [ValidateRange(0,3650)]
    [int]$StaleDays = 0,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Mobile device access change',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-ExoMobileDeviceAccess'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #25 (Exchange & O365)'

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
        Connect-AutomationPlatform -Platform 'ExchangeOnline' | Out-Null


        $exoParams = @{ ShowBanner = $false; ErrorAction = 'Stop' }
        if ($config -and $config.azure) {
            if ($config.azure.applicationId)         { $exoParams.AppId = $config.azure.applicationId }
            if ($config.azure.certificateThumbprint) { $exoParams.CertificateThumbprint = $config.azure.certificateThumbprint }
            if ($config.azure.tenantId)              { $exoParams.Organization = $config.azure.tenantId }
        }
        if (-not $exoParams.AppId) {
            throw 'Exchange Online requires app-only certificate auth. Set azure.applicationId, ' +
                  'azure.certificateThumbprint and azure.tenantId in config.json.'
        }
        Connect-ExchangeOnline @exoParams
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Exchange Online (app-only certificate auth)'

        $mb = Get-Mailbox -Identity $Mailbox -ErrorAction Stop
        $devices = @(Get-MobileDevice -Mailbox $mb.Identity -ErrorAction SilentlyContinue)

        if ($devices.Count -eq 0) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $Mailbox -Message 'No mobile devices registered'
            return
        }

        foreach ($dev in $devices) {
            if ($DeviceId -and $DeviceId -notcontains $dev.DeviceId) { continue }

            $stats = $null
            try { $stats = Get-MobileDeviceStatistics -Identity $dev.Identity -ErrorAction Stop } catch {
                Write-Verbose ('No statistics for device {0}' -f $dev.DeviceId)
            }
            $lastSync = if ($stats) { $stats.LastSuccessSync } else { $null }
            $staleDaysActual = if ($lastSync) { [math]::Round(((Get-Date) - $lastSync).TotalDays, 1) } else { $null }

            # When selecting by staleness rather than by id, skip anything recently used.
            if (-not $DeviceId -and $StaleDays -gt 0) {
                if ($null -eq $staleDaysActual -or $staleDaysActual -lt $StaleDays) { continue }
            }

            $wanted = if ($Operation -eq 'Block') { 'Blocked' } else { 'Allowed' }
            if ("$($dev.DeviceAccessState)" -eq $wanted) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $dev.DeviceId `
                    -Message ('Skipped - already {0} (idempotent)' -f $wanted)
                continue
            }

            $results.Add([PSCustomObject]@{
                Name            = ('{0} : {1} {2}' -f $mb.PrimarySmtpAddress, $dev.DeviceModel, $dev.DeviceId)
                Id              = $dev.Identity
                Mailbox         = $mb.PrimarySmtpAddress
                DeviceId        = $dev.DeviceId
                DeviceModel     = $dev.DeviceModel
                DeviceOS        = $dev.DeviceOS
                DeviceUserAgent = $dev.DeviceUserAgent
                FirstSync       = $dev.FirstSyncTime
                LastSuccessSync = $lastSync
                StaleDays       = $staleDaysActual
                CurrentState    = "$($dev.DeviceAccessState)"
                DesiredState    = $wanted
                Operation       = $Operation
                Scope           = 'Access only - this does NOT wipe the device'
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

    if ($RequestApproval -or -not $ApprovalReference) {
        $request = New-ApprovalRequest -ScriptName $scriptName -ChangeSet $candidates `
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Change device access state', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Change device access state')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $accessState = if ($item.Operation -eq 'Block') { 'Block' } else { 'Allow' }

            Set-CASMailbox -Identity $item.Mailbox `
                -ActiveSyncBlockedDeviceIDs @{ $(if ($item.Operation -eq 'Block') { 'Add' } else { 'Remove' }) = $item.DeviceId } `
                -ErrorAction Stop

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Device {0} ({1}) set to {2}. Last sync {3}. Access only - device NOT wiped. Ticket={4}' -f
                $item.DeviceId, $item.DeviceModel, $accessState, $item.LastSuccessSync, $TicketReference)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = $item.Operation
                Detail = ('{0} -> {1}' -f $item.CurrentState, $item.DesiredState); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Block/Unblock Mobile Devices'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
