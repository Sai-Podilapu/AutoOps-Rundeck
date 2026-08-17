<#
.SYNOPSIS
    Reboots one or more Windows servers under an approval gate and a maintenance window.

.DESCRIPTION
    Reboots target servers only when ALL of the following hold:

      1. A valid approval reference is supplied (-ApprovalReference) that was
         raised for THIS script, is in state Approved, and has not expired.
      2. The server is not on the protected list in Config\config.json.
      3. The current time falls inside the configured maintenance window,
         unless -IgnoreMaintenanceWindow is explicitly passed.
      4. Pre-flight checks pass: the host is reachable and, where requested,
         has no active user sessions.

    Without -ApprovalReference the script runs in REQUEST mode: it produces the
    change set, raises an approval artifact, prints the reference, and stops
    without touching anything.

    This implements the workbook guardrail verbatim: "Reboot causes downtime;
    ticket/maintenance-window driven".

.PARAMETER ComputerName
    Servers to reboot.

.PARAMETER ApprovalReference
    Approval token from New-ApprovalRequest, after a human has approved it.
    Without this the script refuses to reboot anything.

.PARAMETER RequestApproval
    Force REQUEST mode: produce the change set, raise an approval request, and
    stop, even if -ApprovalReference was also supplied. Use it to re-request
    after a set of targets has changed, and in scheduled jobs where the intent
    is always to propose rather than act.

.PARAMETER Reason
    Change reason recorded in the approval artifact and the audit log.

.PARAMETER TicketReference
    ITSM ticket number, recorded in the audit trail alongside the approval.

.PARAMETER IgnoreMaintenanceWindow
    Reboot outside the configured maintenance window. Requires an approval
    reference regardless, and is logged as an explicit override.

.PARAMETER RequireNoActiveSessions
    Refuse to reboot a server that has interactive user sessions.

.PARAMETER WaitForRecovery
    Wait for each server to come back online before continuing.

.PARAMETER RecoveryTimeoutMinutes
    How long to wait for a server to return. Default 15.

.PARAMETER Credential
    Credential for the remote operation.

.PARAMETER ConfigPath
    Override the path to config.json.

.EXAMPLE
    .\Restart-WinServerComputer.ps1 -ComputerName SRV01,SRV02 -Reason 'Monthly patching'

    REQUEST mode. Produces the change set, raises an approval request, prints
    the reference, and reboots nothing.

.EXAMPLE
    .\Restart-WinServerComputer.ps1 -ComputerName SRV01,SRV02 -ApprovalReference APR-20260808220000-4471 -WaitForRecovery

    Executes the reboot after validating the approval, then waits for both
    servers to come back.

.EXAMPLE
    .\Restart-WinServerComputer.ps1 -ComputerName SRV01 -ApprovalReference APR-... -WhatIf

    Shows what would happen without rebooting.

.NOTES
    Source use case      : #3 - Windows Server Reboot
    Category             : Windows Server
    Technology           : PowerShell
    Difficulty           : Low
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "Reboot causes downtime; ticket/maintenance-window driven"

    Required permissions : Local Administrator on the target, or the
                           SeShutdownPrivilege via a delegated group.
    Required modules     : IT-Automation-Common (bundled).
    Authentication       : Integrated Kerberos over WinRM, or -Credential.

    Rollback             : A reboot cannot be rolled back. The mitigations are
                           the approval gate, the maintenance window, and the
                           session check - all of which run BEFORE the action.
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [ValidateNotNullOrEmpty()]
    [string[]]$ComputerName,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$Reason = 'Scheduled maintenance reboot',

    [string]$TicketReference,

    [switch]$IgnoreMaintenanceWindow,

    [switch]$RequireNoActiveSessions,

    [switch]$WaitForRecovery,

    [ValidateRange(1, 240)]
    [int]$RecoveryTimeoutMinutes = 15,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Restart-WinServerComputer'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'START. Reason="{0}" Ticket="{1}" ApprovalSupplied={2}' -f
        $Reason, $TicketReference, [bool]$ApprovalReference)

    $config = $null
    try {
        $config = if ($ConfigPath) { Get-AutomationConfig -Path $ConfigPath } else { Get-AutomationConfig }
    } catch {
        # The protected-computer list and maintenance window live in config. If
        # it cannot be read we must fail closed, not reboot without guardrails.
        throw ('Cannot read configuration, refusing to proceed: {0}' -f $_.Exception.Message)
    }

    $protected = @()
    if ($config.PSObject.Properties.Name -contains 'safety' -and
        $config.safety.PSObject.Properties.Name -contains 'protectedComputers') {
        $protected = @($config.safety.protectedComputers)
    }

    $targets = [System.Collections.Generic.List[string]]::new()
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
}

process {
    foreach ($computer in $ComputerName) {
        # Hard exclusion. Deliberately not overridable by a parameter.
        $isProtected = $protected | Where-Object { $_ -and $computer -like $_ }
        if ($isProtected) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $computer `
                -Message 'REFUSED - server is on the protected list in config.json'
            $results.Add([PSCustomObject]@{
                ComputerName = $computer; Action = 'Skipped'
                Detail = 'On protected list'; Succeeded = $false
            })
            continue
        }
        $targets.Add($computer)
    }
}

end {
    if ($targets.Count -eq 0) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message 'No eligible targets. Nothing to do.'
        Write-Output $results.ToArray()
        return
    }

    # ---------------------------------------------------- REQUEST mode ------
    # -RequestApproval forces this path even when a reference was supplied, so a
    # scheduled job can always propose rather than act.
    if ($RequestApproval -or -not $ApprovalReference) {
        if ($RequestApproval -and $ApprovalReference) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
                '-RequestApproval was set, so approval {0} is ignored and a new request is raised.' -f $ApprovalReference)
        }
        $changeSet = $targets | ForEach-Object {
            [PSCustomObject]@{ ComputerName = $_; Action = 'Restart-Computer'; Reason = $Reason; Ticket = $TicketReference }
        }
        $request = New-ApprovalRequest -ScriptName $scriptName `
            -Action ('Reboot {0} server(s): {1}. Reason: {2}' -f $targets.Count, ($targets -join ', '), $Reason) `
            -ChangeSet $changeSet

        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $request.Reference -Message (
            'REQUEST mode - no server was rebooted. Supply -ApprovalReference {0} once approved.' -f $request.Reference)

        Write-Warning ('No reboot performed. Approval reference: {0}' -f $request.Reference)
        Write-Output ([PSCustomObject]@{
            Mode = 'RequestApproval'; ApprovalReference = $request.Reference
            TargetCount = $targets.Count; Targets = $targets.ToArray(); Rebooted = $false
        })
        return
    }

    # ---------------------------------------------------- EXECUTE mode ------
    $approval = Test-ApprovalReference -Reference $ApprovalReference -ScriptName $scriptName
    if (-not $approval.IsValid) {
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $ApprovalReference `
            -Message ('REFUSED to execute: {0}' -f $approval.Reason)
        throw ('Approval validation failed: {0}' -f $approval.Reason)
    }
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $ApprovalReference `
        -Message ('Approval accepted. {0}' -f $approval.Reason)

    # Maintenance window. The workbook says this action is window-driven.
    if (-not $IgnoreMaintenanceWindow) {
        $startHour = 22; $endHour = 5
        if ($config.PSObject.Properties.Name -contains 'maintenance') {
            if ($config.maintenance.PSObject.Properties.Name -contains 'windowStartHour') {
                $startHour = [int]$config.maintenance.windowStartHour
            }
            if ($config.maintenance.PSObject.Properties.Name -contains 'windowEndHour') {
                $endHour = [int]$config.maintenance.windowEndHour
            }
        }
        $hour = (Get-Date).Hour
        # The window normally wraps midnight (22:00 -> 05:00), so the test is an
        # OR when start > end and an AND otherwise.
        $inWindow = if ($startHour -gt $endHour) { ($hour -ge $startHour) -or ($hour -lt $endHour) }
                    else { ($hour -ge $startHour) -and ($hour -lt $endHour) }
        if (-not $inWindow) {
            $msg = ('Refusing to reboot outside the maintenance window ({0:00}:00-{1:00}:00); current hour is {2:00}. ' +
                    'Pass -IgnoreMaintenanceWindow to override.') -f $startHour, $endHour, $hour
            Write-AutomationLog -ScriptName $scriptName -Level ERROR -Message $msg
            throw $msg
        }
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Inside maintenance window ({0:00}:00-{1:00}:00).' -f $startHour, $endHour)
    } else {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
            'OVERRIDE - maintenance window bypassed by -IgnoreMaintenanceWindow. Approval {0}.' -f $ApprovalReference)
    }

    foreach ($computer in $targets) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $computer -Message 'Pre-flight checks'

        $pre = Test-Prerequisite -ComputerName $computer
        if (-not $pre.Passed) {
            Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $computer `
                -Message ('Pre-flight failed, skipping: {0}' -f $pre.Summary)
            $results.Add([PSCustomObject]@{
                ComputerName = $computer; Action = 'Skipped'
                Detail = $pre.Summary; Succeeded = $false
            })
            continue
        }

        if ($RequireNoActiveSessions) {
            try {
                $sessionCount = 0
                $q = quser /server:$computer 2>$null
                if ($q) { $sessionCount = (@($q) | Select-Object -Skip 1).Count }
                if ($sessionCount -gt 0) {
                    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $computer `
                        -Message ('Skipped - {0} active session(s) and -RequireNoActiveSessions was set' -f $sessionCount)
                    $results.Add([PSCustomObject]@{
                        ComputerName = $computer; Action = 'Skipped'
                        Detail = "$sessionCount active session(s)"; Succeeded = $false
                    })
                    continue
                }
            } catch {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $computer `
                    -Message ('Could not enumerate sessions ({0}); continuing because the check is advisory' -f $_.Exception.Message)
            }
        }

        $action = "Reboot (approval $ApprovalReference, ticket $TicketReference)"
        if (-not $PSCmdlet.ShouldProcess($computer, $action)) {
            $results.Add([PSCustomObject]@{
                ComputerName = $computer; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true
            })
            continue
        }

        try {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $computer `
                -Message ('REBOOTING. Approval={0} Ticket={1} Reason="{2}"' -f $ApprovalReference, $TicketReference, $Reason)

            $rp = @{ ComputerName = $computer; Force = $true; ErrorAction = 'Stop' }
            if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $rp.Credential = $Credential }
            if ($WaitForRecovery) {
                $rp.Wait = $true; $rp.For = 'PowerShell'
                $rp.Timeout = $RecoveryTimeoutMinutes * 60
            }
            Restart-Computer @rp

            $detail = if ($WaitForRecovery) { 'Rebooted and back online' } else { 'Reboot command issued' }
            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $computer -Message $detail
            $results.Add([PSCustomObject]@{
                ComputerName = $computer; Action = 'Rebooted'; Detail = $detail; Succeeded = $true
            })
        } catch {
            $msg = $_.Exception.Message
            Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $computer `
                -Message ('Reboot FAILED: {0}' -f $msg)
            $results.Add([PSCustomObject]@{
                ComputerName = $computer; Action = 'Failed'; Detail = $msg; Succeeded = $false
            })
        }
    }

    $ok   = @($results | Where-Object { $_.Succeeded })
    $bad  = @($results | Where-Object { -not $_.Succeeded })
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'END. Succeeded={0} Failed/Skipped={1} Approval={2}' -f $ok.Count, $bad.Count, $ApprovalReference)

    Write-Output $results.ToArray()

    if ($bad.Count -gt 0) { exit 1 }
}
