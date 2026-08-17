<#
.SYNOPSIS
    Runs SSM patch installation against EC2 instances after approval.

.DESCRIPTION
    Reports current patch compliance, then runs AWS-RunPatchBaseline in
    Install mode against the non-compliant instances. Patching changes
    servers, so this is approval-gated and takes a pre-patch EBS snapshot of
    each target by default - the "pre/post snapshot" the workbook guardrail
    calls for.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER Region
    AWS region to operate in. Defaults to the configured default region.

.PARAMETER ProfileName
    Named AWS profile / SSO profile to use. Prefer an IAM role where the host
    supports one.

.PARAMETER InstanceId
    Limit to specific instance ids.

.PARAMETER PatchGroupTag
    Only patch instances carrying this Patch Group tag value.

.PARAMETER RebootOption
    RebootIfNeeded or NoReboot. NoReboot leaves patches staged until the next
    restart.

.PARAMETER SkipPreSnapshot
    Skip the pre-patch EBS snapshot. Not recommended - the snapshot is the
    rollback path.

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
    .\Install-AwsEc2PatchBaseline.ps1 -Region me-central-1 -PatchGroupTag prod-linux

    REQUEST mode - reports non-compliant instances and raises an approval.

.EXAMPLE
    .\Install-AwsEc2PatchBaseline.ps1 -Region me-central-1 -PatchGroupTag prod-linux -ApprovalReference APR-... -RebootOption RebootIfNeeded

    Patches the approved instances, allowing reboots.

.NOTES
    Source use case      : #9 - AWS EC2 Patch Compliance (SSM)
    Category             : AWS
    Technology           : SSM Patch Manager
    Difficulty           : Medium
    Agent possible       : Partial
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "Patching changes servers; agent runs after change-window approval; pre/post snapshot in SOP"

    Required permissions : ssm:DescribeInstancePatchStates, ssm:SendCommand, ec2:CreateSnapshot, ec2:DescribeInstances
    Required modules     : AWS.Tools.Common, AWS.Tools.SimpleSystemsManagement, AWS.Tools.EC2
    Authentication       : IAM role or SSO profile via Set-AWSCredential. Never
                           an access key pair in code.

    RebootOption defaults to NoReboot so a patch run cannot restart a
    production server on its own. Patches that need a reboot stay staged
    until one happens, and the compliance report will keep showing them as
    missing until then - that is expected, not a failure.

    Rollback             : Restore the instance volume from the pre-patch
                           snapshot this script takes. That snapshot IS the
                           rollback plan, which is why -SkipPreSnapshot is
                           discouraged.
#>

#Requires -Version 5.1
#Requires -Modules AWS.Tools.Common
#Requires -Modules AWS.Tools.SimpleSystemsManagement
#Requires -Modules AWS.Tools.EC2

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$Region,

    [string]$ProfileName,

    [string[]]$InstanceId,

    [string]$PatchGroupTag,

    [ValidateSet('RebootIfNeeded','NoReboot')]
    [string]$RebootOption = 'NoReboot',

    [switch]$SkipPreSnapshot,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Scheduled patch installation',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Install-AwsEc2PatchBaseline'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #9 (AWS)'

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
        Connect-AutomationPlatform -Platform 'AWS' | Out-Null


        $awsArgs = @{}
        if ($Region)      { $awsArgs.Region = $Region }
        if ($ProfileName) { $awsArgs.ProfileName = $ProfileName }

        $states = if ($InstanceId) { Get-SSMInstancePatchStateList -InstanceId $InstanceId @awsArgs }
                  else             { Get-SSMInstancePatchState @awsArgs }

        foreach ($s in $states) {
            $missing = [int]$s.MissingCount + [int]$s.FailedCount
            if ($missing -le 0) { continue }                       # already compliant

            $inst = (Get-EC2Instance -InstanceId $s.InstanceId @awsArgs).Instances | Select-Object -First 1
            if (-not $inst) { continue }

            if ($PatchGroupTag) {
                $pg = $inst.Tags | Where-Object Key -eq 'Patch Group' | Select-Object -First 1 -Expand Value
                if ($pg -ne $PatchGroupTag) { continue }
            }

            $rootVol = ($inst.BlockDeviceMappings | Where-Object { $_.DeviceName -eq $inst.RootDeviceName } |
                        Select-Object -First 1).Ebs.VolumeId

            $results.Add([PSCustomObject]@{
                Name            = ($inst.Tags | Where-Object Key -eq 'Name' | Select-Object -First 1 -Expand Value)
                Id              = $s.InstanceId
                PlatformType    = $inst.PlatformDetails
                MissingCount    = $s.MissingCount
                FailedCount     = $s.FailedCount
                InstalledCount  = $s.InstalledCount
                BaselineId      = $s.BaselineId
                LastOperation   = $s.OperationEndTime
                RootVolumeId    = $rootVol
                RebootOption    = $RebootOption
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Install patch baseline', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Install patch baseline')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            # Pre-patch snapshot first - it is the documented rollback path.
            $snapId = $null
            if (-not $SkipPreSnapshot -and $item.RootVolumeId) {
                $snap = New-EC2Snapshot -VolumeId $item.RootVolumeId @awsArgs `
                    -Description ('Pre-patch snapshot by {0} for {1} on {2}' -f $scriptName, $item.Id, (Get-Date -Format 'yyyy-MM-dd HH:mm'))
                $snapId = $snap.SnapshotId
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
                    'Pre-patch snapshot {0} taken of volume {1}' -f $snapId, $item.RootVolumeId)
            } elseif (-not $item.RootVolumeId) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label `
                    -Message 'No root EBS volume found - proceeding without a pre-patch snapshot'
            }

            $cmd = Send-SSMCommand -InstanceId $item.Id -DocumentName 'AWS-RunPatchBaseline' @awsArgs `
                -Parameter @{ Operation = @('Install'); RebootOption = @($item.RebootOption) } `
                -Comment ('Patch install via {0}, approval {1}' -f $scriptName, $ApprovalReference)

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Patch command {0} sent ({1} missing, reboot={2}). Pre-patch snapshot: {3}' -f
                $cmd.CommandId, $item.MissingCount, $item.RebootOption, $(if ($snapId) { $snapId } else { 'none' }))
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'PatchCommandSent'
                Detail = ('commandId {0}; snapshot {1}' -f $cmd.CommandId, $(if ($snapId) { $snapId } else { 'none' }))
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AWS EC2 Patch Compliance (SSM)'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
