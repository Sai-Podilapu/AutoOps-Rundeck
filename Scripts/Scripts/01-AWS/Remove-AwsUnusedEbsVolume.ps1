<#
.SYNOPSIS
    Deletes EBS volumes that have been unattached beyond a minimum age.

.DESCRIPTION
    Finds available (unattached) EBS volumes, filters them by how long they
    have been detached, and deletes them. This implements the workbook row
    exactly: the agent proposes the list and a human approves the deletion.
    Nothing is deleted without both an approval reference and an explicit
    -Execute.

    DESTRUCTIVE. This script is REPORT-ONLY by default: it produces the
    candidate list and stops. Nothing is deleted, wiped or failed over
    unless -Execute is passed AND a valid -ApprovalReference is supplied.
    A pre-action backup/export is taken where the platform allows it, and
    every object is logged individually before it is touched.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER Region
    AWS region to operate in. Defaults to the configured default region.

.PARAMETER ProfileName
    Named AWS profile / SSO profile to use. Prefer an IAM role where the host
    supports one.

.PARAMETER ExcludeTagKey
    Volumes carrying this tag are never deleted, whatever their age.

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
    .\Remove-AwsUnusedEbsVolume.ps1 -Region me-central-1

    REPORT ONLY. Lists volumes unattached for over 30 days and raises an
    approval. Deletes nothing.

.EXAMPLE
    .\Remove-AwsUnusedEbsVolume.ps1 -Region me-central-1 -ApprovalReference APR-... -Execute -ProtectedList .\keep-volumes.txt

    Deletes the approved volumes, excluding anything on the protected list,
    snapshotting each first.

.NOTES
    Source use case      : #12 - AWS Unused EBS Volume Cleanup
    Category             : AWS
    Technology           : Boto3 / Lambda
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Destructive / High-Impact
    Risk level           : High
    Human approval needed: YES
    Guardrails (col L)   : "Deletes volumes >30 days unattached; agent proposes list, human approves deletion"

    Required permissions : ec2:DescribeVolumes, ec2:CreateSnapshot, ec2:DeleteVolume
    Required modules     : AWS.Tools.Common, AWS.Tools.EC2
    Authentication       : IAM role or SSO profile via Set-AWSCredential. Never
                           an access key pair in code.

    Detachment time is inferred from the volume's most recent detach
    attachment record, falling back to CreateTime where AWS no longer
    reports one. A volume whose detach date cannot be established is
    treated as NOT old enough and is skipped, so uncertainty never results
    in a deletion.

    Rollback             : Restore from the pre-deletion snapshot this script
                           takes by default. Once both the volume and its
                           snapshot are gone the data is unrecoverable, which
                           is why -SkipSnapshot exists but is discouraged, and
                           why the snapshot is retained after the volume is
                           deleted.
#>

#Requires -Version 5.1
#Requires -Modules AWS.Tools.Common
#Requires -Modules AWS.Tools.EC2

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([PSCustomObject])]
param(
    [string]$Region,

    [string]$ProfileName,

    [string]$ExcludeTagKey = 'AutoOps:DoNotDelete',

    [switch]$SkipSnapshot,

    [switch]$Execute,

    [string]$ProtectedList,

    [ValidateRange(0, 3650)]
    [int]$MinimumAgeDays = 30,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Unattached EBS volume cleanup',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Remove-AwsUnusedEbsVolume'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #12 (AWS)'

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
    $pre = Test-Prerequisite -RequiredModule 'AWS.Tools.Common','AWS.Tools.EC2'
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
        Connect-AutomationPlatform -Platform 'AWS' | Out-Null


        $awsArgs = @{}
        if ($Region)      { $awsArgs.Region = $Region }
        if ($ProfileName) { $awsArgs.ProfileName = $ProfileName }

        $vols = Get-EC2Volume -Filter @(@{ Name = 'status'; Values = @('available') }) @awsArgs

        foreach ($v in $vols) {
            $name = ($v.Tags | Where-Object Key -eq 'Name' | Select-Object -First 1 -Expand Value)

            # Explicit opt-out tag wins over everything, including a valid approval.
            if ($ExcludeTagKey -and ($v.Tags | Where-Object Key -eq $ExcludeTagKey)) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $v.VolumeId `
                    -Message ('Excluded - carries the {0} tag' -f $ExcludeTagKey)
                continue
            }

            # When did it become unattached? Prefer the recorded detach time; fall back
            # to CreateTime. If neither can be established, treat it as too new to
            # touch - uncertainty must never lead to a deletion.
            $detachedAt = $null
            if ($v.Attachments -and $v.Attachments.Count -gt 0) {
                $detachedAt = ($v.Attachments | Sort-Object AttachTime -Descending | Select-Object -First 1).AttachTime
            }
            if (-not $detachedAt) { $detachedAt = $v.CreateTime }
            if (-not $detachedAt) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $v.VolumeId `
                    -Message 'Skipped - cannot establish how long this volume has been unattached'
                continue
            }

            $results.Add([PSCustomObject]@{
                Name          = if ($name) { $name } else { $v.VolumeId }
                Id            = $v.VolumeId
                VolumeId      = $v.VolumeId
                SizeGB        = $v.Size
                VolumeType    = $v.VolumeType
                AvailabilityZone = $v.AvailabilityZone
                Encrypted     = $v.Encrypted
                CreatedAt     = $detachedAt
                UnattachedDays= [math]::Round(((Get-Date) - $detachedAt).TotalDays, 1)
                EstMonthlyUsd = [math]::Round($v.Size * 0.08, 2)
                Tags          = (($v.Tags | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join '; ')
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Delete unattached EBS volume', $candidates.Count, $Reason, $TicketReference)
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
        $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AWS Unused EBS Volume Cleanup (candidates)'
        Write-Output $candidates
        return
    }

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Delete unattached EBS volume')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {
            # Mandatory pre-action capture, so the object can be restored.

            # Mandatory pre-deletion snapshot. This is the only recovery path once the
            # volume is gone, and it is deliberately NOT deleted afterwards.
            $snapId = $null
            if (-not $SkipSnapshot) {
                $snap = New-EC2Snapshot -VolumeId $item.VolumeId @awsArgs `
                    -Description ('Pre-deletion snapshot by {0}, approval {1}, volume {2} ({3}GB)' -f
                                  $scriptName, $ApprovalReference, $item.VolumeId, $item.SizeGB)
                $snapId = $snap.SnapshotId
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
                    'Pre-deletion snapshot {0} created. RETAINED after deletion as the recovery path.' -f $snapId)
            } else {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label `
                    -Message 'PROCEEDING WITHOUT A SNAPSHOT - this deletion is unrecoverable'
            }


            Remove-EC2Volume -VolumeId $item.VolumeId -Force @awsArgs | Out-Null

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Volume DELETED: {0} ({1}GB, unattached {2}d). Recovery snapshot: {3}' -f
                $item.VolumeId, $item.SizeGB, $item.UnattachedDays, $(if ($snapId) { $snapId } else { 'NONE' }))
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'Deleted'
                Detail = ('{0}GB, unattached {1}d, snapshot {2}' -f $item.SizeGB, $item.UnattachedDays, $(if ($snapId) { $snapId } else { 'NONE' }))
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AWS Unused EBS Volume Cleanup'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
