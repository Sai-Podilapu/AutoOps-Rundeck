<#
.SYNOPSIS
    Modifies Active Directory user attributes per a ticket.

.DESCRIPTION
    Updates directory attributes such as title, department, manager or
    telephone. The prior value of every attribute is captured before the
    change, so the audit trail answers what it was as well as what it became.

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
    Account(s) to modify.

.PARAMETER Attribute
    Attributes and new values, e.g. @{ Title = \u2018Manager\u2019; Department
    = \u2018Finance\u2019 }.

.PARAMETER AllowedAttribute
    Attributes this script may change. Anything outside the list is refused.

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
    .\Set-AdUserAttribute.ps1 -Identity jsmith -Attribute @{Title='Senior Analyst';Department='Finance'} -TicketReference REQ0012345

    REQUEST mode - raises an approval showing old and new values.

.EXAMPLE
    .\Set-AdUserAttribute.ps1 -Identity jsmith -Attribute @{Title='Senior Analyst'} -ApprovalReference APR-...

    Applies the approved change.

.NOTES
    Source use case      : #8 - Account Modification
    Category             : AD & Identity
    Technology           : PowerShell
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "Attribute changes per ticket"

    Required permissions : Delegated write on the specific attributes for the target OU.
    Required modules     : ActiveDirectory
    Authentication       : Delegated service account with the minimum required
                           AD rights.

    The allow-list deliberately excludes security-relevant attributes such
    as userAccountControl, memberOf, and anything under msExch or msDS.
    Those have their own scripts and their own approval paths; folding
    them in here would let a routine attribute ticket change group
    membership.

    Rollback             : Re-run with the prior values, which are recorded in
                           the audit log before the change.
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
    [hashtable]$Attribute,

    [string[]]$AllowedAttribute = @('Title','Department','Company','Office','OfficePhone','MobilePhone','Manager','Description','StreetAddress','City','State','PostalCode','Country','EmployeeID','EmployeeNumber'),

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Directory attribute change',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-AdUserAttribute'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #8 (AD & Identity)'

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
        Connect-AutomationPlatform -Platform 'ActiveDirectory' | Out-Null


        $adArgs = @{ ErrorAction = 'Stop' }
        if ($Server) { $adArgs.Server = $Server }
        if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $adArgs.Credential = $Credential }

        Import-Module ActiveDirectory -ErrorAction Stop

        foreach ($key in $Attribute.Keys) {
            if ($AllowedAttribute -notcontains $key) {
                throw ('Refusing to modify "{0}" - it is not in -AllowedAttribute. Security-relevant ' +
                       'attributes have their own scripts and approval paths.' -f $key)
            }
        }

        foreach ($id in $Identity) {
            $props = @($Attribute.Keys) + @('DistinguishedName','DisplayName')
            $u = Get-ADUser -Identity $id -Properties $props @adArgs

            $changes = @()
            $priorValues = @{}
            foreach ($key in $Attribute.Keys) {
                $old = $u.$key
                $new = $Attribute[$key]
                $priorValues[$key] = "$old"
                if ("$old" -eq "$new") { continue }              # idempotent
                $changes += ('{0}: "{1}" -> "{2}"' -f $key, $old, $new)
            }

            if ($changes.Count -eq 0) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $id `
                    -Message 'Skipped - all attributes already at the requested values (idempotent)'
                continue
            }

            $results.Add([PSCustomObject]@{
                Name        = $u.SamAccountName
                Id          = $u.DistinguishedName
                DisplayName = $u.DisplayName
                Changes     = ($changes -join '; ')
                ChangeCount = $changes.Count
                PriorValues = $priorValues
                NewValues   = $Attribute
                Ticket      = $TicketReference
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Modify user attributes', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Modify user attributes')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
                'Prior values: {0}' -f (($item.PriorValues.GetEnumerator() | ForEach-Object { '{0}="{1}"' -f $_.Key, $_.Value }) -join '; '))

            $setParams = @{ Identity = $item.Id }
            $replace = @{}
            foreach ($key in $item.NewValues.Keys) {
                # Manager takes a DN; the rest are ordinary attribute writes.
                if ($key -eq 'Manager') { $setParams.Manager = $item.NewValues[$key] }
                else { $replace[$key] = $item.NewValues[$key] }
            }
            if ($replace.Count -gt 0) { $setParams.Replace = $replace }

            Set-ADUser @setParams @adArgs

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                '{0} attribute(s) changed: {1}. Ticket={2}' -f $item.ChangeCount, $item.Changes, $TicketReference)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'AttributesChanged'; Detail = $item.Changes; Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Account Modification'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
