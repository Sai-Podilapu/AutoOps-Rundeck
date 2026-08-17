<#
.SYNOPSIS
    Deletes Azure managed disks that are unattached beyond a minimum age.

.DESCRIPTION
    Finds managed disks in the Unattached state and deletes them after
    approval. A snapshot of each disk is taken and retained before deletion,
    so an orphaned disk that turns out to have mattered is still recoverable.

    DESTRUCTIVE. This script is REPORT-ONLY by default: it produces the
    candidate list and stops. Nothing is deleted, wiped or failed over
    unless -Execute is passed AND a valid -ApprovalReference is supplied.
    A pre-action backup/export is taken where the platform allows it, and
    every object is logged individually before it is touched.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER SubscriptionId
    Subscription to operate in. Falls back to azure.defaultSubscriptionId in
    config.json.

.PARAMETER ResourceGroupName
    Limit to specific resource groups.

.PARAMETER ExcludeTagKey
    Disks carrying this tag are never deleted.

.PARAMETER SkipSnapshot
    Skip the pre-deletion snapshot. Strongly discouraged - the snapshot is the
    only recovery path.

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
    .\Remove-AzUnattachedDisk.ps1 -MinimumAgeDays 30

    REPORT ONLY. Lists unattached disks older than 30 days and raises an
    approval.

.EXAMPLE
    .\Remove-AzUnattachedDisk.ps1 -MinimumAgeDays 30 -ApprovalReference APR-... -Execute

    Deletes the approved disks, snapshotting each first.

.NOTES
    Source use case      : #16 - Azure Disk Unattached Cleanup
    Category             : Azure
    Technology           : Az CLI / PowerShell
    Difficulty           : Medium
    Agent possible       : Yes - with Human Approval
    Can execute with SOP : Yes - With Approval
    Automation type      : Destructive / High-Impact
    Risk level           : High
    Human approval needed: YES
    Guardrails (col L)   : "Deletes orphaned disks; approval list before delete"

    Required permissions : Contributor on the resource group holding the disks.
    Required modules     : Az.Accounts, Az.Compute
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    Azure does not record when a disk became unattached, so age is
    measured from the disk's creation time. A recently created but
    already-orphaned disk will therefore not be proposed until it ages
    past the threshold - deliberately conservative.

    Rollback             : Create a new disk from the pre-deletion snapshot
                           this script retains. Once both the disk and its
                           snapshot are gone the data is unrecoverable.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.Compute

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [string[]]$ResourceGroupName,

    [string]$ExcludeTagKey = 'AutoOps:DoNotDelete',

    [switch]$SkipSnapshot,

    [switch]$Execute,

    [string]$ProtectedList,

    [ValidateRange(0, 3650)]
    [int]$MinimumAgeDays = 30,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Orphaned managed disk cleanup',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Remove-AzUnattachedDisk'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #16 (Azure)'

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
    $pre = Test-Prerequisite -RequiredModule 'Az.Accounts','Az.Compute'
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

        $disks = if ($ResourceGroupName) { $ResourceGroupName | ForEach-Object { Get-AzDisk -ResourceGroupName $_ } }
                 else                    { Get-AzDisk }

        foreach ($d in $disks) {
            if ($d.DiskState -ne 'Unattached') { continue }

            if ($ExcludeTagKey -and $d.Tags -and $d.Tags.ContainsKey($ExcludeTagKey)) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $d.Name `
                    -Message ('Excluded - carries the {0} tag' -f $ExcludeTagKey)
                continue
            }

            $results.Add([PSCustomObject]@{
                Name          = $d.Name
                Id            = $d.Id
                ResourceGroup = $d.ResourceGroupName
                Location      = $d.Location
                SizeGB        = $d.DiskSizeGB
                Sku           = $d.Sku.Name
                DiskState     = "$($d.DiskState)"
                OsType        = "$($d.OsType)"
                CreatedAt     = $d.TimeCreated
                AgeDays       = [math]::Round(((Get-Date) - $d.TimeCreated).TotalDays, 1)
                EstMonthlyUsd = [math]::Round($d.DiskSizeGB * 0.05, 2)
                Tags          = if ($d.Tags) { (($d.Tags.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join '; ') } else { '' }
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Delete unattached managed disk', $candidates.Count, $Reason, $TicketReference)
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
        $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Azure Disk Unattached Cleanup (candidates)'
        Write-Output $candidates
        return
    }

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Delete unattached managed disk')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {
            # Mandatory pre-action capture, so the object can be restored.

            # Mandatory pre-deletion snapshot, retained afterwards as the recovery path.
            $snapName = $null
            if (-not $SkipSnapshot) {
                $disk = Get-AzDisk -ResourceGroupName $item.ResourceGroup -DiskName $item.Name -ErrorAction Stop
                $snapName = ('predelete-{0}-{1}' -f $item.Name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
                $cfg = New-AzSnapshotConfig -SourceUri $disk.Id -Location $item.Location -CreateOption Copy -SkuName Standard_LRS `
                    -Tag @{ CreatedBy = $scriptName; Reason = 'pre-deletion recovery point'; Approval = "$ApprovalReference" }
                New-AzSnapshot -ResourceGroupName $item.ResourceGroup -SnapshotName $snapName -Snapshot $cfg -ErrorAction Stop | Out-Null
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
                    'Pre-deletion snapshot {0} created and RETAINED as the recovery path' -f $snapName)
            } else {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label `
                    -Message 'PROCEEDING WITHOUT A SNAPSHOT - this deletion is unrecoverable'
            }


            Remove-AzDisk -ResourceGroupName $item.ResourceGroup -DiskName $item.Name -Force -ErrorAction Stop | Out-Null

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Disk DELETED: {0} ({1}GB, age {2}d). Recovery snapshot: {3}' -f
                $item.Name, $item.SizeGB, $item.AgeDays, $(if ($snapName) { $snapName } else { 'NONE' }))
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'Deleted'
                Detail = ('{0}GB; snapshot {1}' -f $item.SizeGB, $(if ($snapName) { $snapName } else { 'NONE' }))
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Azure Disk Unattached Cleanup'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
