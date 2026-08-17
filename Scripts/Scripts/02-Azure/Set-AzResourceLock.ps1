<#
.SYNOPSIS
    Adds or removes Azure resource locks.

.DESCRIPTION
    Creates or removes CanNotDelete and ReadOnly locks. Removing a lock is
    what makes a production resource deletable, so removal is approval-gated;
    adding one is protective and still gated for consistency, since an
    unexpected ReadOnly lock breaks deployments.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER SubscriptionId
    Subscription to operate in. Falls back to azure.defaultSubscriptionId in
    config.json.

.PARAMETER ResourceGroupName
    Limit to specific resource groups.

.PARAMETER Operation
    Add or Remove.

.PARAMETER LockName
    Name of the lock.

.PARAMETER LockLevel
    CanNotDelete or ReadOnly. Required for Add.

.PARAMETER TargetResourceId
    Specific resource to lock. Omit to lock the resource group itself.

.PARAMETER LockNotes
    Reason recorded on the lock.

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
    .\Set-AzResourceLock.ps1 -Operation Add -LockName no-delete -ResourceGroupName rg-prod -LockLevel CanNotDelete

    REQUEST mode - raises an approval to protect a resource group.

.EXAMPLE
    .\Set-AzResourceLock.ps1 -Operation Remove -LockName no-delete -ResourceGroupName rg-prod -ApprovalReference APR-...

    Removes the approved lock, exposing the resource group to deletion.

.NOTES
    Source use case      : #22 - Azure Resource Lock Management
    Category             : Azure
    Technology           : Az PowerShell
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "Removing locks exposes prod resources; approval gate"

    Required permissions : Owner or User Access Administrator - lock management requires Microsoft.Authorization/locks/* which Contributor does not have.
    Required modules     : Az.Accounts, Az.Resources
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    A ReadOnly lock blocks far more than it appears to - it prevents POST
    operations, so it can stop a VM from starting or a key being listed.
    CanNotDelete is usually what people actually want.

    Rollback             : Reverse the operation. A removed lock can be
                           recreated with the same name and level, both of
                           which are recorded in the audit log before removal.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.Resources

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [string[]]$ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateSet('Add','Remove')]
    [string]$Operation,

    [Parameter(Mandatory)]
    [string]$LockName,

    [ValidateSet('CanNotDelete','ReadOnly')]
    [string]$LockLevel = 'CanNotDelete',

    [string]$TargetResourceId,

    [string]$LockNotes = 'Managed by IT automation',

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Resource lock change',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-AzResourceLock'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #22 (Azure)'

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
        Connect-AutomationPlatform -Platform 'Azure' | Out-Null


        if (-not $SubscriptionId -and $config -and $config.azure) { $SubscriptionId = $config.azure.defaultSubscriptionId }
        if ($SubscriptionId) {
            Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop | Out-Null
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message ('Subscription context: {0}' -f $SubscriptionId)
        } else {
            $ctx = Get-AzContext
            if (-not $ctx) { throw 'No Azure context. Pass -SubscriptionId or set azure.defaultSubscriptionId in config.json.' }
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'No -SubscriptionId given; using the ambient context {0}' -f $ctx.Subscription.Id)
        }

        if ($Operation -eq 'Add' -and -not $LockLevel) { throw '-LockLevel is required when adding a lock.' }
        if (-not $ResourceGroupName -and -not $TargetResourceId) {
            throw 'Specify -ResourceGroupName or -TargetResourceId. Locking at subscription scope is not supported here.'
        }

        $scopes = if ($TargetResourceId) { @($TargetResourceId) }
                  else { $ResourceGroupName | ForEach-Object { (Get-AzResourceGroup -Name $_ -ErrorAction Stop).ResourceId } }

        foreach ($scope in $scopes) {
            $existing = Get-AzResourceLock -Scope $scope -ErrorAction SilentlyContinue |
                        Where-Object Name -eq $LockName | Select-Object -First 1

            if ($Operation -eq 'Add' -and $existing) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $scope `
                    -Message ('Skipped - lock {0} already exists at {1}' -f $LockName, $existing.Properties.level)
                continue
            }
            if ($Operation -eq 'Remove' -and -not $existing) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $scope `
                    -Message ('Skipped - no lock named {0} at this scope' -f $LockName)
                continue
            }

            $results.Add([PSCustomObject]@{
                Name          = ('{0} @ {1}' -f $LockName, ($scope -split '/')[-1])
                Id            = $scope
                Operation     = $Operation
                LockName      = $LockName
                LockLevel     = if ($Operation -eq 'Add') { $LockLevel } else { "$($existing.Properties.level)" }
                Scope         = $scope
                ExistingNotes = if ($existing) { $existing.Properties.notes } else { $null }
                Impact        = if ($Operation -eq 'Remove') { 'Resource becomes deletable' } else { 'Resource becomes protected' }
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Add/remove resource lock', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Add/remove resource lock')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            if ($item.Operation -eq 'Add') {
                New-AzResourceLock -LockName $item.LockName -LockLevel $item.LockLevel -Scope $item.Scope `
                    -LockNotes $LockNotes -Force -ErrorAction Stop | Out-Null
                $detail = 'lock added at level {0}' -f $item.LockLevel
            } else {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
                    'Removing lock {0} ({1}) - the resource becomes deletable. Approval={2} Ticket={3}' -f
                    $item.LockName, $item.LockLevel, $ApprovalReference, $TicketReference)
                Remove-AzResourceLock -LockName $item.LockName -Scope $item.Scope -Force -ErrorAction Stop | Out-Null
                $detail = 'lock removed (was {0})' -f $item.LockLevel
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Azure Resource Lock Management'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
