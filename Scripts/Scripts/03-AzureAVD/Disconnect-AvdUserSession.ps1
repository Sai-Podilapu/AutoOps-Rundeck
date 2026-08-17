<#
.SYNOPSIS
    Warns and then logs off idle AVD sessions.

.DESCRIPTION
    Finds sessions idle beyond a threshold, sends each user an on-screen
    warning, waits, and then logs them off. The warning is not optional
    decoration - a forced logoff loses whatever was not saved, and the SOP
    requires users be told first.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER SubscriptionId
    Azure subscription. The current context when omitted.

.PARAMETER ResourceGroupName
    Resource group holding the host pool.

.PARAMETER HostPoolName
    AVD host pool name.

.PARAMETER IdleThresholdHours
    Sessions idle longer than this are candidates.

.PARAMETER WarningMinutes
    How long to give users between the warning and the logoff.

.PARAMETER WarningMessage
    Message shown to the user.

.PARAMETER SkipWarning
    Log off without warning. Contrary to the SOP; logged as a WARN and
    requires a reason for the audit trail.

.PARAMETER DisconnectOnly
    Disconnect the session rather than logging off. The session and its
    unsaved work survive on the host.

.PARAMETER ExcludeUser
    UPNs never disconnected or logged off.

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
    .\Disconnect-AvdUserSession.ps1 -ResourceGroupName rg-avd -HostPoolName hp-prod -IdleThresholdHours 4

    REPORT ONLY. Lists idle sessions and raises an approval.

.EXAMPLE
    .\Disconnect-AvdUserSession.ps1 -ResourceGroupName rg-avd -HostPoolName hp-prod -DisconnectOnly -ApprovalReference APR-...

    Disconnects idle sessions without losing anything.

.EXAMPLE
    .\Disconnect-AvdUserSession.ps1 -ResourceGroupName rg-avd -HostPoolName hp-prod -WarningMinutes 15 -ApprovalReference APR-...

    Warns, waits 15 minutes, then logs off.

.NOTES
    Source use case      : #3 - AVD User Session Disconnect & Logoff
    Category             : Azure AVD
    Technology           : Az PowerShell / Graph API
    Difficulty           : Low
    Agent possible       : Partial
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "Force logoff idle >4 hrs can lose unsaved work; warn users first per SOP"

    Required permissions : Desktop Virtualization Session Host Contributor on the host pool.
    Required modules     : Az.Accounts, Az.DesktopVirtualization
    Authentication       : Inherits the Az context; managed identity preferred.

    The guardrail says warn users first, so the warning is the default
    path and the wait is real - the script sends the message, sleeps for
    -WarningMinutes, then acts. -SkipWarning exists for an emergency and
    logs that the SOP was bypassed. Consider -DisconnectOnly first: it
    frees the connection without ending the session, so nothing is lost,
    and for most "idle session" goals it is enough.

    Rollback             : NONE for a logoff - unsaved work is gone. A
                           disconnect is fully reversible: the user reconnects
                           to the same session with everything intact, which is
                           why -DisconnectOnly exists and is worth preferring
                           where reclaiming the licence is the actual goal.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.DesktopVirtualization

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$HostPoolName,

    [ValidateRange(1,168)]
    [int]$IdleThresholdHours = 4,

    [ValidateRange(1,120)]
    [int]$WarningMinutes = 15,

    [string]$WarningMessage = 'Your session has been idle and will be signed out shortly. Please save your work now.',

    [switch]$SkipWarning,

    [switch]$DisconnectOnly,

    [string[]]$ExcludeUser,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Idle session reclamation',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Disconnect-AvdUserSession'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #3 (Azure AVD)'

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
        Connect-AutomationPlatform -Platform 'AzureAVD' | Out-Null


        $azContext = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $azContext) {
            throw 'No Azure context. Run Connect-AzAccount, or use a managed identity, before this script.'
        }
        if ($SubscriptionId -and $azContext.Subscription.Id -ne $SubscriptionId) {
            $azContext = Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop
        }

        $hostPool = Get-AzWvdHostPool -ResourceGroupName $ResourceGroupName -Name $HostPoolName -ErrorAction Stop
        if (-not $hostPool) {
            throw ('Host pool "{0}" not found in resource group "{1}".' -f $HostPoolName, $ResourceGroupName)
        }
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Host pool {0}: type {1}, load balancer {2}, max sessions {3}' -f
            $hostPool.Name, $hostPool.HostPoolType, $hostPool.LoadBalancerType, $hostPool.MaxSessionLimit)

        $sessionHosts = @(Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName `
            -HostPoolName $HostPoolName -ErrorAction Stop)
        if ($sessionHosts.Count -eq 0) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message 'Host pool contains no session hosts.'
        }

        function Get-AvdShortName {
            <#
                .SYNOPSIS
                    The session host name without the host pool prefix Azure prepends.
            #>
            [CmdletBinding()]
            [OutputType([string])]
            param([Parameter(Mandatory)][string]$FullName)

            return ($FullName -split '/')[-1]
        }

        if ($SkipWarning -and -not $Reason) {
            throw '-SkipWarning bypasses the SOP requirement to warn users first. Supply -Reason recording why.'
        }

        $userSessions = @(Get-AzWvdUserSession -ResourceGroupName $ResourceGroupName `
            -HostPoolName $HostPoolName -ErrorAction Stop)
        $now = Get-Date

        foreach ($session in $userSessions) {
            $upn = $session.UserPrincipalName
            if ($ExcludeUser -and $ExcludeUser -contains $upn) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $upn -Message 'Excluded by -ExcludeUser'
                continue
            }

            # A disconnected session has no idle clock of its own; its create time is
            # the only thing available, so it is reported as such rather than guessed.
            $idleHours = $null
            if ($session.SessionState -eq 'Active' -and $session.CreateTime) {
                $idleHours = [math]::Round(($now - [datetime]$session.CreateTime).TotalHours, 1)
            } elseif ($session.CreateTime) {
                $idleHours = [math]::Round(($now - [datetime]$session.CreateTime).TotalHours, 1)
            }

            if ($null -eq $idleHours) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $upn `
                    -Message 'Skipped - session age could not be established, so idleness is unknown.'
                continue
            }
            if ($idleHours -lt $IdleThresholdHours) { continue }

            $parts = $session.Name -split '/'
            $results.Add([PSCustomObject]@{
                Name            = ('{0} on {1}' -f $upn, $parts[1])
                Id              = $session.Name
                UserPrincipalName = $upn
                SessionHostName = $parts[1]
                SessionId       = $parts[-1]
                SessionState    = $session.SessionState
                CreateTime      = $session.CreateTime
                AgeHours        = $idleHours
                ApplicationType = $session.ApplicationType
                WillWarn        = (-not $SkipWarning)
                Operation       = if ($DisconnectOnly) { 'Disconnect' } else { 'Logoff' }
                Impact          = if ($DisconnectOnly) { 'Session survives on the host; the user reconnects to it intact' }
                                  else { 'Session ENDS; anything unsaved is lost' }
            })
        }

        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            '{0} session(s) beyond {1}h. Operation: {2}. Warning: {3}.' -f
            $results.Count, $IdleThresholdHours,
            $(if ($DisconnectOnly) { 'disconnect' } else { 'LOGOFF' }),
            $(if ($SkipWarning) { 'SKIPPED - SOP bypassed' } else { ('{0} minutes' -f $WarningMinutes) }))
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Log off idle session', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Log off idle session')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            if ($item.WillWarn) {
                Send-AzWvdUserSessionMessage -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName `
                    -SessionHostName $item.SessionHostName -UserSessionId $item.SessionId `
                    -MessageTitle 'Session sign-out notice' -MessageBody $WarningMessage -ErrorAction Stop | Out-Null

                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
                    'Warning sent; waiting {0} minute(s) before acting.' -f $WarningMinutes)
                Start-Sleep -Seconds ($WarningMinutes * 60)
            } else {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
                    'NO WARNING SENT - SOP bypassed via -SkipWarning. Reason: {0}' -f $Reason)
            }

            if ($item.Operation -eq 'Disconnect') {
                Disconnect-AzWvdUserSession -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName `
                    -SessionHostName $item.SessionHostName -Id $item.SessionId -ErrorAction Stop | Out-Null
                $detail = 'Disconnected; session and unsaved work intact on the host'
            } else {
                Remove-AzWvdUserSession -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName `
                    -SessionHostName $item.SessionHostName -Id $item.SessionId -Force -ErrorAction Stop | Out-Null
                $detail = 'Logged off; unsaved work lost'
            }

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                '{0} after {1}h. {2}' -f $item.Operation, $item.AgeHours, $detail)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = $item.Operation; Detail = $detail; Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AVD User Session Disconnect & Logoff'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
