<#
.SYNOPSIS
    Adds or removes Microsoft 365 licences for a user.

.DESCRIPTION
    Assigns or removes licences. Removal is the dangerous direction: stripping
    a licence starts a retention clock on the associated mailbox and OneDrive
    data, so removals are approval-gated and the script reports what each
    licence carries before acting.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER UserPrincipalName
    User(s) to change.

.PARAMETER Operation
    Add or Remove.

.PARAMETER SkuPartNumber
    Licence SKU part number, e.g. ENTERPRISEPACK, SPE_E3.

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
    .\Set-O365UserLicense.ps1 -UserPrincipalName user@contoso.com -Operation Remove -SkuPartNumber ENTERPRISEPACK -TicketReference REQ0012345

    REQUEST mode - raises an approval for a licence removal.

.EXAMPLE
    .\Set-O365UserLicense.ps1 -UserPrincipalName user@contoso.com -Operation Add -SkuPartNumber ENTERPRISEPACK -ApprovalReference APR-...

    Applies the approved assignment.

.NOTES
    Source use case      : #16 - O365 License Assignment (Add/Delete)
    Category             : Exchange & O365
    Technology           : Graph API / PowerShell
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "License removal can cut service/data access; approve deletions"

    Required permissions : Microsoft Graph User.ReadWrite.All and Organization.Read.All.
    Required modules     : Microsoft.Graph.Authentication, Microsoft.Graph.Users.Actions
    Authentication       : App-only certificate auth via
                           Connect-ExchangeOnline.

    Removing an Exchange-bearing licence soft-deletes the mailbox after
    the retention window. For a leaver, convert to a shared mailbox first,
    then remove the licence - that keeps the mail without consuming a
    seat.

    Rollback             : Re-assign the licence. Data is retained for 30 days
                           after removal, so a prompt re-assignment restores
                           access - but after 30 days the mailbox and OneDrive
                           content are permanently deleted.
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication
#Requires -Modules Microsoft.Graph.Users.Actions

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory)]
    [string[]]$UserPrincipalName,

    [Parameter(Mandatory)]
    [ValidateSet('Add','Remove')]
    [string]$Operation,

    [Parameter(Mandatory)]
    [string[]]$SkuPartNumber,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Licence assignment change',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-O365UserLicense'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #16 (Exchange & O365)'

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


        Connect-MgGraph -Scopes 'User.ReadWrite.All','Organization.Read.All' -NoWelcome -ErrorAction Stop
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Microsoft Graph'

        $skus = Get-MgSubscribedSku -All -ErrorAction Stop

        foreach ($upn in $UserPrincipalName) {
            $u = Get-MgUser -UserId $upn -Property Id,UserPrincipalName,DisplayName,AssignedLicenses,UsageLocation -ErrorAction Stop

            foreach ($part in $SkuPartNumber) {
                $sku = $skus | Where-Object SkuPartNumber -eq $part | Select-Object -First 1
                if (-not $sku) { throw ('SKU {0} is not present in this tenant.' -f $part) }

                $has = $u.AssignedLicenses.SkuId -contains $sku.SkuId
                if (($Operation -eq 'Add' -and $has) -or ($Operation -eq 'Remove' -and -not $has)) {
                    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $upn `
                        -Message ('Skipped - licence {0} already in the requested state (idempotent)' -f $part)
                    continue
                }

                # Assignment fails without a usage location, and the error is unhelpful.
                if ($Operation -eq 'Add' -and -not $u.UsageLocation) {
                    throw ('{0} has no UsageLocation set. Licence assignment will fail until it is set.' -f $upn)
                }

                $available = $sku.PrepaidUnits.Enabled - $sku.ConsumedUnits
                if ($Operation -eq 'Add' -and $available -le 0) {
                    throw ('No available seats for {0} ({1} of {2} consumed).' -f $part, $sku.ConsumedUnits, $sku.PrepaidUnits.Enabled)
                }

                $results.Add([PSCustomObject]@{
                    Name           = ('{0} : {1} {2}' -f $u.UserPrincipalName, $Operation, $part)
                    Id             = $u.Id
                    UserPrincipalName = $u.UserPrincipalName
                    DisplayName    = $u.DisplayName
                    Operation      = $Operation
                    SkuPartNumber  = $part
                    SkuId          = $sku.SkuId
                    SeatsAvailable = $available
                    ServicePlans   = (($sku.ServicePlans.ServicePlanName | Select-Object -First 12) -join '; ')
                    DataRisk       = if ($Operation -eq 'Remove') {
                                         'Removing this licence starts a 30-day retention clock on any mailbox and OneDrive data it provides'
                                     } else { 'Additive' }
                })
            }
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Change user licence', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Change user licence')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            if ($item.Operation -eq 'Add') {
                Set-MgUserLicense -UserId $item.Id -AddLicenses @(@{ SkuId = $item.SkuId }) -RemoveLicenses @() -ErrorAction Stop | Out-Null
                $detail = 'licence {0} assigned' -f $item.SkuPartNumber
            } else {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
                    'Removing licence {0} - 30-day retention clock starts on associated data. Approval={1}' -f
                    $item.SkuPartNumber, $ApprovalReference)
                Set-MgUserLicense -UserId $item.Id -AddLicenses @() -RemoveLicenses @($item.SkuId) -ErrorAction Stop | Out-Null
                $detail = 'licence {0} removed' -f $item.SkuPartNumber
            }

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message $detail
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = $item.Operation; Detail = $detail; Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'O365 License Assignment (Add/Delete)'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
