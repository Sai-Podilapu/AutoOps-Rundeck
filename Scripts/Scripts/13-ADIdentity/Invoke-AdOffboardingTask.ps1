<#
.SYNOPSIS
    Runs individual offboarding sub-tasks as a selectable set.

.DESCRIPTION
    The offboarding steps as separately selectable operations - disable, move
    OU, strip groups, hide from GAL, reset password, set expiry - for cases
    where the full leaver sequence is not wanted. Multi-step identity change,
    so it runs as an approved workflow with each step logged individually.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER Server
    Domain controller to target. Uses the nearest DC when omitted.

.PARAMETER Credential
    Credential for the directory operation.

.PARAMETER Identity
    Account(s) to act on.

.PARAMETER Task
    Sub-tasks to run, in the order given.

.PARAMETER TargetOU
    Destination OU. Required for MoveOU.

.PARAMETER ExpiryDate
    Account expiry date. Required for SetExpiry.

.PARAMETER KeepGroups
    Groups to leave in place when running RemoveGroups.

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
    .\Invoke-AdOffboardingTask.ps1 -Identity jsmith -Task Disable,RemoveGroups -TicketReference HR0012345

    REQUEST mode - raises an approval for two sub-tasks.

.EXAMPLE
    .\Invoke-AdOffboardingTask.ps1 -Identity jsmith -Task Disable,RemoveGroups,MoveOU -TargetOU 'OU=Leavers,DC=contoso,DC=com' -ApprovalReference APR-...

    Runs the approved sub-tasks in order.

.NOTES
    Source use case      : #5 - Offboarding sub-tasks (Disable, move OU, manager removal)
    Category             : AD & Identity
    Technology           : PowerShell
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : High
    Human approval needed: YES
    Guardrails (col L)   : "Multi-step identity changes; run as approved workflow"

    Required permissions : Delegated user management on the relevant OUs.
    Required modules     : ActiveDirectory
    Authentication       : Delegated service account with the minimum required
                           AD rights.

    Tasks run in the order supplied. Put MoveOU last: moving the object
    first changes its distinguished name, and the later tasks would then
    be operating on a stale identity.

    Rollback             : Each task is individually reversible: re-enable,
                           move back, re-add groups from the audit log, unhide,
                           clear expiry. The pre-change state is captured
                           before the first task.
#>

#Requires -Version 5.1
#Requires -Modules ActiveDirectory

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$Server,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [Parameter(Mandatory)]
    [string[]]$Identity,

    [Parameter(Mandatory)]
    [ValidateSet('Disable','MoveOU','RemoveGroups','HideFromGal','ResetPassword','SetExpiry')]
    [string[]]$Task,

    [string]$TargetOU,

    [datetime]$ExpiryDate,

    [string[]]$KeepGroups,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Offboarding sub-task workflow',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Invoke-AdOffboardingTask'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #5 (AD & Identity)'

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

        if ($Task -contains 'MoveOU' -and -not $TargetOU) { throw '-TargetOU is required for the MoveOU task.' }
        if ($Task -contains 'SetExpiry' -and -not $ExpiryDate) { throw '-ExpiryDate is required for the SetExpiry task.' }
        if ($TargetOU) {
            try { Get-ADOrganizationalUnit -Identity $TargetOU @adArgs | Out-Null }
            catch { throw ('Target OU does not exist: {0}' -f $TargetOU) }
        }

        # MoveOU changes the DN, invalidating it for anything that follows.
        if ($Task -contains 'MoveOU' -and $Task[-1] -ne 'MoveOU') {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'MoveOU is not the last task. It changes the distinguished name, so later tasks may fail. ' +
                'Reorder with MoveOU last.')
        }

        foreach ($id in $Identity) {
            $u = Get-ADUser -Identity $id -Properties MemberOf,Enabled,DistinguishedName,DisplayName,AccountExpirationDate @adArgs
            $groups = @($u.MemberOf | ForEach-Object { (Get-ADGroup -Identity $_ @adArgs).Name })
            $toRemove = @($groups | Where-Object { $KeepGroups -notcontains $_ })

            $results.Add([PSCustomObject]@{
                Name            = $u.SamAccountName
                Id              = $u.DistinguishedName
                DisplayName     = $u.DisplayName
                CurrentlyEnabled= $u.Enabled
                CurrentOU       = ($u.DistinguishedName -replace '^CN=[^,]+,', '')
                CurrentExpiry   = $u.AccountExpirationDate
                Tasks           = ($Task -join ' -> ')
                TargetOU        = $TargetOU
                ExpiryDate      = $ExpiryDate
                AllGroups       = ($groups -join '; ')
                GroupsToRemove  = ($toRemove -join '; ')
                RemoveGroupCount= $toRemove.Count
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Run offboarding sub-tasks', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Run offboarding sub-tasks')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $done = @()
            $currentId = $item.Id

            foreach ($t in $Task) {
                switch ($t) {
                    'Disable' {
                        Disable-ADAccount -Identity $currentId @adArgs
                        $done += 'Disable'
                    }
                    'ResetPassword' {
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
                        Set-ADAccountPassword -Identity $currentId -NewPassword $newSecurePassword -Reset @adArgs
                        $done += 'ResetPassword'
                    }
                    'RemoveGroups' {
                        $n = 0
                        foreach ($g in ($item.GroupsToRemove -split '; ')) {
                            if (-not $g) { continue }
                            try { Remove-ADGroupMember -Identity $g -Members $item.Name -Confirm:$false @adArgs; $n++ }
                            catch { Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label `
                                        -Message ('Could not remove from {0}' -f $g) }
                        }
                        $done += ('RemoveGroups({0})' -f $n)
                    }
                    'HideFromGal' {
                        try { Set-ADUser -Identity $currentId -Replace @{ msExchHideFromAddressLists = $true } @adArgs
                              $done += 'HideFromGal' }
                        catch { Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label `
                                    -Message 'Could not hide from address lists (Exchange schema may be absent)' }
                    }
                    'SetExpiry' {
                        Set-ADAccountExpiration -Identity $currentId -DateTime $item.ExpiryDate @adArgs
                        $done += ('SetExpiry({0:yyyy-MM-dd})' -f $item.ExpiryDate)
                    }
                    'MoveOU' {
                        Move-ADObject -Identity $currentId -TargetPath $item.TargetOU @adArgs
                        # The DN has changed; re-resolve so any later task uses the new one.
                        $currentId = (Get-ADUser -Identity $item.Name @adArgs).DistinguishedName
                        $done += 'MoveOU'
                    }
                }
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message ('Task complete: {0}' -f $t)
            }

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Sub-tasks complete: {0}. Ticket={1} Approval={2}' -f ($done -join ', '), $TicketReference, $ApprovalReference)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'SubTasksRun'; Detail = ($done -join ', '); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Offboarding sub-tasks (Disable, move OU, manager removal)'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
