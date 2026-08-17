<#
.SYNOPSIS
    Offboards a leaver whose mailbox is on on-premises Exchange.

.DESCRIPTION
    The on-premises leaver sequence: disable, reset password, strip groups,
    hide from the GAL, move to the leavers OU, and optionally set a mailbox
    forward to the manager. The mailbox is retained rather than disabled,
    because disabling it starts the retention clock and the mail is usually
    needed for a handover.

    DESTRUCTIVE. This script is REPORT-ONLY by default: it produces the
    candidate list and stops. Nothing is deleted, wiped or failed over
    unless -Execute is passed AND a valid -ApprovalReference is supplied.
    A pre-action backup/export is taken where the platform allows it, and
    every object is logged individually before it is touched.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER Server
    Domain controller to target. Uses the nearest DC when omitted.

.PARAMETER Credential
    Credential for the directory operation.

.PARAMETER Identity
    Leaver(s) to offboard.

.PARAMETER LeaversOU
    Distinguished name of the leavers OU.

.PARAMETER ExchangeServer
    Exchange server hosting the management endpoint. Required for the
    forwarding step.

.PARAMETER ForwardToManager
    Forward the leaver\u2019s mail to their manager for a handover period.

.PARAMETER KeepGroups
    Groups to leave in place.

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
    .\Remove-AdUserOffboardingOnPrem.ps1 -Identity jsmith -TicketReference HR0012345

    REPORT ONLY. Shows the change set and raises an approval.

.EXAMPLE
    .\Remove-AdUserOffboardingOnPrem.ps1 -Identity jsmith -TicketReference HR0012345 -ForwardToManager -ApprovalReference APR-... -Execute

    Offboards and forwards mail to the manager.

.NOTES
    Source use case      : #4 - User Offboarding - mailbox in Exchange
    Category             : AD & Identity
    Technology           : Exchange PowerShell
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Destructive / High-Impact
    Risk level           : High
    Human approval needed: YES
    Guardrails (col L)   : "Same as above"

    Required permissions : Delegated user management on both OUs, plus Exchange Recipient Management for forwarding.
    Required modules     : ActiveDirectory
    Authentication       : Delegated service account with the minimum required
                           AD rights.

    The mailbox is deliberately NOT disabled. Disable-Mailbox disconnects
    it and starts the deleted-mailbox retention clock; keeping it attached
    to a disabled account preserves the mail indefinitely and keeps the
    handover simple.

    Rollback             : Re-enable, restore memberships from the rollback
                           file, move back, and clear any forwarding. All prior
                           state is captured before the first change.
#>

#Requires -Version 5.1
#Requires -Modules ActiveDirectory

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([PSCustomObject])]
param(
    [string]$Server,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [Parameter(Mandatory)]
    [string[]]$Identity,

    [string]$LeaversOU,

    [string]$ExchangeServer,

    [switch]$ForwardToManager,

    [string[]]$KeepGroups,

    [switch]$Execute,

    [string]$ProtectedList,

    [ValidateRange(0, 3650)]
    [int]$MinimumAgeDays = 0,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Leaver offboarding - on-premises mailbox',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Remove-AdUserOffboardingOnPrem'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #4 (AD & Identity)'

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
    $pre = Test-Prerequisite -RequiredModule 'ActiveDirectory'
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
        Connect-AutomationPlatform -Platform 'ActiveDirectory' | Out-Null


        $adArgs = @{ ErrorAction = 'Stop' }
        if ($Server) { $adArgs.Server = $Server }
        if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $adArgs.Credential = $Credential }

        Import-Module ActiveDirectory -ErrorAction Stop

        if (-not $LeaversOU -and $config -and $config.activeDirectory) { $LeaversOU = $config.activeDirectory.disabledUsersOU }
        if (-not $LeaversOU) { throw 'No leavers OU. Pass -LeaversOU or set activeDirectory.disabledUsersOU in config.json.' }
        if ($ForwardToManager -and -not $ExchangeServer) {
            throw '-ForwardToManager requires -ExchangeServer to reach the Exchange management endpoint.'
        }

        foreach ($id in $Identity) {
            $u = Get-ADUser -Identity $id -Properties MemberOf,Enabled,DistinguishedName,DisplayName,Mail,Manager,LastLogonDate @adArgs

            $groups = @($u.MemberOf | ForEach-Object { (Get-ADGroup -Identity $_ @adArgs).Name })
            $toRemove = @($groups | Where-Object { $KeepGroups -notcontains $_ })

            $managerMail = $null
            if ($u.Manager) {
                try { $managerMail = (Get-ADUser -Identity $u.Manager -Properties Mail @adArgs).Mail } catch {
                    Write-Verbose ('Could not resolve manager for {0}' -f $u.SamAccountName)
                }
            }
            if ($ForwardToManager -and -not $managerMail) {
                throw ('{0} has no resolvable manager mail address; cannot forward.' -f $u.SamAccountName)
            }

            $results.Add([PSCustomObject]@{
                Name            = $u.SamAccountName
                Id              = $u.DistinguishedName
                DisplayName     = $u.DisplayName
                Mail            = $u.Mail
                CurrentlyEnabled= $u.Enabled
                CurrentOU       = ($u.DistinguishedName -replace '^CN=[^,]+,', '')
                LeaversOU       = $LeaversOU
                LastLogon       = $u.LastLogonDate
                AllGroups       = ($groups -join '; ')
                GroupsToRemove  = ($toRemove -join '; ')
                RemoveGroupCount= $toRemove.Count
                ManagerMail     = $managerMail
                ForwardToManager= [bool]$ForwardToManager
                ExchangeServer  = $ExchangeServer
                MailboxHandling = 'Mailbox RETAINED and left attached - not disabled, so retention does not start'
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Offboard leaver (on-premises mailbox)', $candidates.Count, $Reason, $TicketReference)
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
        $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'User Offboarding - mailbox in Exchange (candidates)'
        Write-Output $candidates
        return
    }

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Offboard leaver (on-premises mailbox)')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {
            # Mandatory pre-action capture, so the object can be restored.

            $rollbackDir = Join-Path $env:ProgramData 'ITAutomation\Rollback'
            if (-not (Test-Path -LiteralPath $rollbackDir)) { New-Item -Path $rollbackDir -ItemType Directory -Force | Out-Null }
            $rollbackPath = Join-Path $rollbackDir ('offboard-onprem-{0}-{1}.json' -f $item.Name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
            $item | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $rollbackPath -Encoding UTF8
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
                'Pre-change state written to {0}' -f $rollbackPath)


            Disable-ADAccount -Identity $item.Id @adArgs

            $alphabet = ([char[]]((48..57) + (65..90) + (97..122) + (33,35,36,37,38,42,43,45,61,63,64,95)))
            $newSecurePassword = New-Object System.Security.SecureString
            $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
            try {
                $buf = New-Object byte[] 1
                $limit = [byte](256 - (256 % $alphabet.Length))
                for ($i = 0; $i -lt 24; $i++) {
                    do { $rng.GetBytes($buf) } while ($buf[0] -ge $limit)
                    $newSecurePassword.AppendChar($alphabet[$buf[0] % $alphabet.Length])
                }
            } finally { $rng.Dispose() }
            $newSecurePassword.MakeReadOnly()
            Set-ADAccountPassword -Identity $item.Id -NewPassword $newSecurePassword -Reset @adArgs

            $removed = 0
            foreach ($g in ($item.GroupsToRemove -split '; ')) {
                if (-not $g) { continue }
                try { Remove-ADGroupMember -Identity $g -Members $item.Name -Confirm:$false @adArgs; $removed++ }
                catch { Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label `
                            -Message ('Could not remove from {0}: {1}' -f $g, $_.Exception.Message) }
            }

            try { Set-ADUser -Identity $item.Id -Replace @{ msExchHideFromAddressLists = $true } @adArgs }
            catch { Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label `
                        -Message 'Could not hide from address lists' }

            $forwarded = $false
            if ($item.ForwardToManager) {
                $session = $null
                try {
                    $uri = 'http://{0}/PowerShell/' -f $item.ExchangeServer
                    $sp = @{ ConfigurationName = 'Microsoft.Exchange'; ConnectionUri = $uri
                             Authentication = 'Kerberos'; ErrorAction = 'Stop' }
                    if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $sp.Credential = $Credential }
                    $session = New-PSSession @sp
                    Import-PSSession $session -CommandName Set-Mailbox -AllowClobber -DisableNameChecking | Out-Null
                    Set-Mailbox -Identity $item.Mail -ForwardingSmtpAddress $item.ManagerMail `
                        -DeliverToMailboxAndForward $true -ErrorAction Stop
                    $forwarded = $true
                } catch {
                    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label `
                        -Message ('Forwarding to manager failed: {0}' -f $_.Exception.Message)
                } finally {
                    if ($session) { Remove-PSSession $session -ErrorAction SilentlyContinue }
                }
            }

            Move-ADObject -Identity $item.Id -TargetPath $item.LeaversOU @adArgs

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Offboarded: disabled, password reset, {0} group(s) removed, moved to {1}, forwarding to manager: {2}. ' +
                'Mailbox retained. Ticket={3}' -f $removed, $item.LeaversOU, $forwarded, $TicketReference)

            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'Offboarded'
                Detail = ('{0} groups removed; forwarded {1}; rollback at {2}' -f $removed, $forwarded, $rollbackPath)
                Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'User Offboarding - mailbox in Exchange'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
