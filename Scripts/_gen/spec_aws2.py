# -*- coding: utf-8 -*-
"""AWS - the remaining 6 use cases, including the library's first Destructive row."""

REGION = dict(name='Region', help='AWS region to operate in. Defaults to the configured default region.',
              decl="[string]$Region")
PROFILE = dict(name='ProfileName', help='Named AWS profile / SSO profile to use. Prefer an IAM role where the host supports one.',
               decl="[string]$ProfileName")

EXTRA = {

4: dict(
    file='Invoke-AwsEc2ScheduleWindow',
    modules=['AWS.Tools.Common', 'AWS.Tools.EC2'],
    synopsis='Applies per-instance start/stop windows to EC2 instances from their tags.',
    desc='Reads a start hour and stop hour from each instance\'s own tags and brings the instance '
         'into the state its window says it should be in right now. Distinct from '
         'Set-AwsInstanceSchedule.ps1, which applies one state to a whole tagged group: this one '
         'lets each instance carry its own window, which is what a mixed estate needs.',
    params=[REGION, PROFILE,
            dict(name='StartHourTagKey', help='Tag holding the hour (0-23, local to -ScheduleTimeZone) the instance should start.',
                 decl="[string]$StartHourTagKey = 'AutoOps:StartHour'"),
            dict(name='StopHourTagKey', help='Tag holding the hour (0-23) the instance should stop.',
                 decl="[string]$StopHourTagKey = 'AutoOps:StopHour'"),
            dict(name='ScheduleTimeZone', help='IANA/Windows time zone the window hours are expressed in. Windows are business-local, not UTC.',
                 decl="[string]$ScheduleTimeZone = 'UTC'"),
            dict(name='SkipDays', help='Days on which the window is not applied, e.g. weekends.',
                 decl="[ValidateSet('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')]\n    [string[]]$SkipDays = @('Saturday','Sunday')")],
    perms='ec2:DescribeInstances, ec2:StartInstances, ec2:StopInstances',
    actionVerb='Apply EC2 schedule window',
    rollback='Reverse the action, or remove the schedule tags from the instance so it is no longer '
             'managed. An instance without both tags is never touched.',
    notes='An instance must carry BOTH tags to be managed. A half-tagged instance is skipped and '
          'logged rather than guessed at, because guessing one end of a window is how a production '
          'server gets stopped at 9am.',
    examples=[("-Region me-central-1 -ScheduleTimeZone 'Arabian Standard Time'",
               'Applies each instance\'s own window, interpreting the hours in Gulf local time.'),
              ("-Region me-central-1 -WhatIf",
               'Shows which instances are outside their window without changing anything.')],
    discover="""
$awsArgs = @{}
if ($Region)      { $awsArgs.Region = $Region }
if ($ProfileName) { $awsArgs.ProfileName = $ProfileName }

# Resolve "now" in the window's own zone. Comparing a business window against
# UTC is the classic way these schedulers fire an hour out twice a year.
try {
    $tz  = [System.TimeZoneInfo]::FindSystemTimeZoneById($ScheduleTimeZone)
    $now = [System.TimeZoneInfo]::ConvertTimeFromUtc((Get-Date).ToUniversalTime(), $tz)
} catch {
    throw ('Unknown time zone "{0}": {1}' -f $ScheduleTimeZone, $_.Exception.Message)
}

if ($SkipDays -contains $now.DayOfWeek.ToString()) {
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'Today is {0}, which is in -SkipDays. No schedule applied.' -f $now.DayOfWeek)
    return
}

foreach ($r in (Get-EC2Instance @awsArgs)) {
    foreach ($i in $r.Instances) {
        $startTag = $i.Tags | Where-Object Key -eq $StartHourTagKey | Select-Object -First 1 -Expand Value
        $stopTag  = $i.Tags | Where-Object Key -eq $StopHourTagKey  | Select-Object -First 1 -Expand Value
        if (-not $startTag -and -not $stopTag) { continue }

        # A half-tagged instance is a configuration error, not a schedule.
        if (-not $startTag -or -not $stopTag) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $i.InstanceId -Message (
                'Skipped - only one of {0}/{1} is set. Both are required.' -f $StartHourTagKey, $StopHourTagKey)
            continue
        }

        $startHour = 0; $stopHour = 0
        if (-not [int]::TryParse($startTag, [ref]$startHour) -or
            -not [int]::TryParse($stopTag,  [ref]$stopHour)) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $i.InstanceId `
                -Message ('Skipped - schedule tags are not integers ({0}/{1})' -f $startTag, $stopTag)
            continue
        }

        # The window wraps midnight when start > stop (e.g. 22 -> 06).
        $h = $now.Hour
        $inWindow = if ($startHour -le $stopHour) { ($h -ge $startHour) -and ($h -lt $stopHour) }
                    else                          { ($h -ge $startHour) -or  ($h -lt $stopHour) }

        $wanted  = if ($inWindow) { 'running' } else { 'stopped' }
        $current = $i.State.Name.Value
        if ($current -eq $wanted) { continue }                       # idempotent
        if ($current -notin @('running','stopped')) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $i.InstanceId `
                -Message ('Skipped - instance is {0}, mid-transition' -f $current)
            continue
        }

        $results.Add([PSCustomObject]@{
            Name         = ($i.Tags | Where-Object Key -eq 'Name' | Select-Object -First 1 -Expand Value)
            Id           = $i.InstanceId
            CurrentState = $current
            DesiredState = $wanted
            WindowStart  = $startHour
            WindowStop   = $stopHour
            LocalHour    = $h
            TimeZone     = $ScheduleTimeZone
            InstanceType = $i.InstanceType.Value
        })
    }
}
""",
    act="""
if ($item.DesiredState -eq 'running') { Start-EC2Instance -InstanceId $item.Id @awsArgs | Out-Null }
else                                  { Stop-EC2Instance  -InstanceId $item.Id @awsArgs | Out-Null }

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Window {0:00}-{1:00} {2}, local hour {3:00}: {4} -> {5}' -f
    $item.WindowStart, $item.WindowStop, $item.TimeZone, $item.LocalHour, $item.CurrentState, $item.DesiredState)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = $item.DesiredState; Detail = $item.Id; Succeeded = $true })
"""),

9: dict(
    file='Install-AwsEc2PatchBaseline',
    modules=['AWS.Tools.Common', 'AWS.Tools.SimpleSystemsManagement', 'AWS.Tools.EC2'],
    synopsis='Runs SSM patch installation against EC2 instances after approval.',
    desc='Reports current patch compliance, then runs AWS-RunPatchBaseline in Install mode against '
         'the non-compliant instances. Patching changes servers, so this is approval-gated and '
         'takes a pre-patch EBS snapshot of each target by default - the "pre/post snapshot" the '
         'workbook guardrail calls for.',
    params=[REGION, PROFILE,
            dict(name='InstanceId', help='Limit to specific instance ids.',
                 decl="[string[]]$InstanceId"),
            dict(name='PatchGroupTag', help='Only patch instances carrying this Patch Group tag value.',
                 decl="[string]$PatchGroupTag"),
            dict(name='RebootOption', help='RebootIfNeeded or NoReboot. NoReboot leaves patches staged until the next restart.',
                 decl="[ValidateSet('RebootIfNeeded','NoReboot')]\n    [string]$RebootOption = 'NoReboot'"),
            dict(name='SkipPreSnapshot', help='Skip the pre-patch EBS snapshot. Not recommended - the snapshot is the rollback path.',
                 decl="[switch]$SkipPreSnapshot")],
    perms='ssm:DescribeInstancePatchStates, ssm:SendCommand, ec2:CreateSnapshot, ec2:DescribeInstances',
    actionVerb='Install patch baseline',
    reason='Scheduled patch installation',
    rollback='Restore the instance volume from the pre-patch snapshot this script takes. That '
             'snapshot IS the rollback plan, which is why -SkipPreSnapshot is discouraged.',
    notes='RebootOption defaults to NoReboot so a patch run cannot restart a production server on '
          'its own. Patches that need a reboot stay staged until one happens, and the compliance '
          'report will keep showing them as missing until then - that is expected, not a failure.',
    examples=[("-Region me-central-1 -PatchGroupTag prod-linux",
               'REQUEST mode - reports non-compliant instances and raises an approval.'),
              ("-Region me-central-1 -PatchGroupTag prod-linux -ApprovalReference APR-... -RebootOption RebootIfNeeded",
               'Patches the approved instances, allowing reboots.')],
    discover="""
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
""",
    act="""
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
"""),

12: dict(
    file='Remove-AwsUnusedEbsVolume',
    modules=['AWS.Tools.Common', 'AWS.Tools.EC2'],
    synopsis='Deletes EBS volumes that have been unattached beyond a minimum age.',
    desc='Finds available (unattached) EBS volumes, filters them by how long they have been '
         'detached, and deletes them. This implements the workbook row exactly: the agent proposes '
         'the list and a human approves the deletion. Nothing is deleted without both an approval '
         'reference and an explicit -Execute.',
    params=[REGION, PROFILE,
            dict(name='ExcludeTagKey', help='Volumes carrying this tag are never deleted, whatever their age.',
                 decl="[string]$ExcludeTagKey = 'AutoOps:DoNotDelete'"),
            dict(name='SkipSnapshot', help='Skip the pre-deletion snapshot. Strongly discouraged - the snapshot is the only recovery path.',
                 decl="[switch]$SkipSnapshot")],
    minage=30,
    perms='ec2:DescribeVolumes, ec2:CreateSnapshot, ec2:DeleteVolume',
    actionVerb='Delete unattached EBS volume',
    reason='Unattached EBS volume cleanup',
    rollback='Restore from the pre-deletion snapshot this script takes by default. Once both the '
             'volume and its snapshot are gone the data is unrecoverable, which is why -SkipSnapshot '
             'exists but is discouraged, and why the snapshot is retained after the volume is deleted.',
    notes='Detachment time is inferred from the volume\'s most recent detach attachment record, '
          'falling back to CreateTime where AWS no longer reports one. A volume whose detach date '
          'cannot be established is treated as NOT old enough and is skipped, so uncertainty never '
          'results in a deletion.',
    examples=[("-Region me-central-1",
               'REPORT ONLY. Lists volumes unattached for over 30 days and raises an approval. Deletes nothing.'),
              ("-Region me-central-1 -ApprovalReference APR-... -Execute -ProtectedList .\\keep-volumes.txt",
               'Deletes the approved volumes, excluding anything on the protected list, snapshotting each first.')],
    discover="""
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
""",
    backup="""
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
""",
    act="""
Remove-EC2Volume -VolumeId $item.VolumeId -Force @awsArgs | Out-Null

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Volume DELETED: {0} ({1}GB, unattached {2}d). Recovery snapshot: {3}' -f
    $item.VolumeId, $item.SizeGB, $item.UnattachedDays, $(if ($snapId) { $snapId } else { 'NONE' }))
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'Deleted'
    Detail = ('{0}GB, unattached {1}d, snapshot {2}' -f $item.SizeGB, $item.UnattachedDays, $(if ($snapId) { $snapId } else { 'NONE' }))
    Succeeded = $true })
"""),

15: dict(
    file='Get-AwsVpcFlowLogAnomaly',
    modules=['AWS.Tools.Common', 'AWS.Tools.Athena'],
    synopsis='Runs Athena queries over VPC flow logs and flags traffic anomalies for analyst review.',
    desc='Queries the VPC flow log table in Athena for the patterns worth a human look: rejected '
         'traffic concentrations, unusual destination ports, and top talkers by byte volume. '
         'Produces a ranked, enriched candidate list.',
    params=[REGION, PROFILE,
            dict(name='AthenaDatabase', help='Glue/Athena database containing the flow log table.',
                 decl="[Parameter(Mandatory)]\n    [string]$AthenaDatabase"),
            dict(name='FlowLogTable', help='Athena table name for the VPC flow logs.',
                 decl="[Parameter(Mandatory)]\n    [string]$FlowLogTable"),
            dict(name='OutputLocation', help='S3 URI where Athena writes query results, e.g. s3://my-athena-results/.',
                 decl="[Parameter(Mandatory)]\n    [string]$OutputLocation"),
            dict(name='LookbackHours', help='How far back to query.',
                 decl="[ValidateRange(1,720)]\n    [int]$LookbackHours = 24"),
            dict(name='MinimumRejectCount', help='Only flag source IPs with at least this many rejected flows.',
                 decl="[ValidateRange(1,1000000)]\n    [int]$MinimumRejectCount = 100"),
            dict(name='QueryTimeoutSeconds', help='How long to wait for each Athena query.',
                 decl="[ValidateRange(10,3600)]\n    [int]$QueryTimeoutSeconds = 300")],
    perms='athena:StartQueryExecution, athena:GetQueryExecution, athena:GetQueryResults, s3:GetObject/PutObject on the results bucket, glue:GetTable',
    notes='Athena charges per terabyte scanned. Partition the flow log table by date and keep '
          '-LookbackHours tight; an unpartitioned full-table scan on a busy VPC is expensive and '
          'slow. The queries below filter on the partition column where present.',
    examples=[("-AthenaDatabase vpc_logs -FlowLogTable flow_logs -OutputLocation s3://athena-results/ -LookbackHours 24",
               'Runs the anomaly queries over the last day and produces a review package.'),
              ("-AthenaDatabase vpc_logs -FlowLogTable flow_logs -OutputLocation s3://athena-results/ -MinimumRejectCount 500 -OutputFormat JSON",
               'Raises the reject threshold and emits JSON for a SIEM.')],
    discover="""
$awsArgs = @{}
if ($Region)      { $awsArgs.Region = $Region }
if ($ProfileName) { $awsArgs.ProfileName = $ProfileName }

$since = (Get-Date).ToUniversalTime().AddHours(-$LookbackHours)
$sinceEpoch = [int64]([datetimeoffset]$since).ToUnixTimeSeconds()

function Invoke-AthenaQuery {
    param(
        [string]$Sql,
        [string]$Label,
        [string]$Database,
        [string]$ResultLocation,
        [int]$TimeoutSeconds,
        [hashtable]$AwsCommon
    )

    $exec = Start-ATHQueryExecution -QueryString $Sql -QueryExecutionContext_Database $Database `
        -ResultConfiguration_OutputLocation $ResultLocation @AwsCommon

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds 3
        $state = (Get-ATHQueryExecution -QueryExecutionId $exec @AwsCommon).QueryExecution.Status.State
    } while ($state -in @('QUEUED','RUNNING') -and (Get-Date) -lt $deadline)

    if ($state -ne 'SUCCEEDED') {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $Label `
            -Message ('Athena query did not succeed (state {0})' -f $state)
        return @()
    }
    $rs = Get-ATHQueryResult -QueryExecutionId $exec @AwsCommon
    # Row 0 is the header row in Athena results.
    return @($rs.ResultSet.Rows | Select-Object -Skip 1)
}

# --- rejected traffic concentrations ------------------------------------
$sqlReject = @(
    'SELECT srcaddr, dstaddr, dstport, protocol, COUNT(*) AS reject_count'
    "FROM $FlowLogTable"
    "WHERE action = 'REJECT' AND start >= $sinceEpoch"
    'GROUP BY srcaddr, dstaddr, dstport, protocol'
    "HAVING COUNT(*) >= $MinimumRejectCount"
    'ORDER BY reject_count DESC'
    'LIMIT 100'
) -join ' '

foreach ($row in (Invoke-AthenaQuery -Sql $sqlReject -Label 'rejected-traffic' `
        -Database $AthenaDatabase -ResultLocation $OutputLocation `
        -TimeoutSeconds $QueryTimeoutSeconds -AwsCommon $awsArgs)) {
    $d = $row.Data
    $results.Add([PSCustomObject]@{
        Name        = ('REJECT {0} -> {1}:{2}' -f $d[0].VarCharValue, $d[1].VarCharValue, $d[2].VarCharValue)
        Id          = ('reject-{0}-{1}-{2}' -f $d[0].VarCharValue, $d[1].VarCharValue, $d[2].VarCharValue)
        Finding     = 'Rejected traffic concentration'
        SourceIp    = $d[0].VarCharValue
        DestIp      = $d[1].VarCharValue
        DestPort    = $d[2].VarCharValue
        Protocol    = $d[3].VarCharValue
        Count       = [int64]$d[4].VarCharValue
        AnalystNote = 'Could be a scan, a misconfigured client, or a security group that is doing its job. Needs analyst judgement.'
    })
}

# --- top talkers by volume ----------------------------------------------
$sqlTalkers = @(
    'SELECT srcaddr, dstaddr, SUM(bytes) AS total_bytes, COUNT(*) AS flow_count'
    "FROM $FlowLogTable"
    "WHERE action = 'ACCEPT' AND start >= $sinceEpoch"
    'GROUP BY srcaddr, dstaddr'
    'ORDER BY total_bytes DESC'
    'LIMIT 25'
) -join ' '

foreach ($row in (Invoke-AthenaQuery -Sql $sqlTalkers -Label 'top-talkers' `
        -Database $AthenaDatabase -ResultLocation $OutputLocation `
        -TimeoutSeconds $QueryTimeoutSeconds -AwsCommon $awsArgs)) {
    $d = $row.Data
    $results.Add([PSCustomObject]@{
        Name        = ('VOLUME {0} -> {1}' -f $d[0].VarCharValue, $d[1].VarCharValue)
        Id          = ('talker-{0}-{1}' -f $d[0].VarCharValue, $d[1].VarCharValue)
        Finding     = 'High volume flow'
        SourceIp    = $d[0].VarCharValue
        DestIp      = $d[1].VarCharValue
        TotalBytes  = [int64]$d[2].VarCharValue
        TotalGB     = [math]::Round([int64]$d[2].VarCharValue / 1GB, 2)
        FlowCount   = [int64]$d[3].VarCharValue
        AnalystNote = 'High volume is normal for backup and replication paths. Compare against the known baseline.'
    })
}

# --- unusual destination ports ------------------------------------------
$sqlPorts = @(
    'SELECT dstport, protocol, COUNT(DISTINCT srcaddr) AS distinct_sources, COUNT(*) AS flow_count'
    "FROM $FlowLogTable"
    "WHERE action = 'ACCEPT' AND start >= $sinceEpoch"
    '  AND dstport NOT IN (80, 443, 22, 3389, 53, 123, 25, 587, 993, 995, 1433, 3306, 5432)'
    'GROUP BY dstport, protocol'
    'ORDER BY flow_count DESC'
    'LIMIT 50'
) -join ' '

foreach ($row in (Invoke-AthenaQuery -Sql $sqlPorts -Label 'unusual-ports' `
        -Database $AthenaDatabase -ResultLocation $OutputLocation `
        -TimeoutSeconds $QueryTimeoutSeconds -AwsCommon $awsArgs)) {
    $d = $row.Data
    $results.Add([PSCustomObject]@{
        Name        = ('PORT {0}/{1}' -f $d[0].VarCharValue, $d[1].VarCharValue)
        Id          = ('port-{0}-{1}' -f $d[0].VarCharValue, $d[1].VarCharValue)
        Finding     = 'Traffic on a non-standard port'
        DestPort    = $d[0].VarCharValue
        Protocol    = $d[1].VarCharValue
        DistinctSources = [int64]$d[2].VarCharValue
        FlowCount   = [int64]$d[3].VarCharValue
        AnalystNote = 'Non-standard does not mean malicious. Many applications use high ports legitimately; tune the exclusion list over time.'
    })
}
"""),

17: dict(
    file='Remove-AwsUnusedElasticIp',
    modules=['AWS.Tools.Common', 'AWS.Tools.EC2'],
    synopsis='Releases Elastic IP addresses that are allocated but not associated.',
    desc='Finds allocated EIPs with no association and releases them. Releasing an EIP returns the '
         'address to the AWS pool permanently - it cannot be reclaimed, and anything with that IP '
         'in a DNS record, firewall rule or allow-list breaks. That irreversibility is why this is '
         'approval-gated despite being classed as Change/Write.',
    params=[REGION, PROFILE,
            dict(name='ExcludeTagKey', help='EIPs carrying this tag are never released.',
                 decl="[string]$ExcludeTagKey = 'AutoOps:DoNotRelease'"),
            dict(name='ProtectedAddress', help='Specific IP addresses that must never be released, whatever else is true.',
                 decl="[string[]]$ProtectedAddress")],
    perms='ec2:DescribeAddresses, ec2:ReleaseAddress',
    actionVerb='Release Elastic IP',
    reason='Unused Elastic IP cleanup',
    rollback='NONE. A released EIP returns to the shared AWS pool and cannot be reclaimed. If the '
             'address appears in DNS, a partner allow-list or a firewall rule, releasing it is a '
             'breaking change with no undo.',
    notes='An unassociated EIP still bills hourly, which is the reason to clean them up. But check '
          'DNS and any external allow-lists before approving - the cost saving is small and the '
          'breakage can be large.',
    examples=[("-Region me-central-1",
               'REQUEST mode - lists unassociated EIPs and raises an approval. Releases nothing.'),
              ("-Region me-central-1 -ApprovalReference APR-... -ProtectedAddress 52.1.2.3",
               'Releases the approved addresses while protecting one explicitly.')],
    discover="""
$awsArgs = @{}
if ($Region)      { $awsArgs.Region = $Region }
if ($ProfileName) { $awsArgs.ProfileName = $ProfileName }

foreach ($eip in (Get-EC2Address @awsArgs)) {
    # Associated addresses are in use by definition.
    if ($eip.AssociationId -or $eip.InstanceId -or $eip.NetworkInterfaceId) { continue }

    if ($ProtectedAddress -contains $eip.PublicIp) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $eip.PublicIp `
            -Message 'Excluded - listed in -ProtectedAddress'
        continue
    }
    if ($ExcludeTagKey -and ($eip.Tags | Where-Object Key -eq $ExcludeTagKey)) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $eip.PublicIp `
            -Message ('Excluded - carries the {0} tag' -f $ExcludeTagKey)
        continue
    }

    $name = ($eip.Tags | Where-Object Key -eq 'Name' | Select-Object -First 1 -Expand Value)
    $results.Add([PSCustomObject]@{
        Name          = if ($name) { $name } else { $eip.PublicIp }
        Id            = $eip.AllocationId
        PublicIp      = $eip.PublicIp
        AllocationId  = $eip.AllocationId
        Domain        = "$($eip.Domain)"
        NetworkBorderGroup = $eip.NetworkBorderGroup
        EstMonthlyUsd = 3.60
        Tags          = (($eip.Tags | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join '; ')
        Warning       = 'Release is PERMANENT - verify DNS records and external allow-lists first'
    })
}
""",
    act="""
Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
    'RELEASING {0} permanently. Approval={1} Ticket={2}' -f $item.PublicIp, $ApprovalReference, $TicketReference)

Remove-EC2Address -AllocationId $item.AllocationId -Force @awsArgs | Out-Null

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Elastic IP {0} released to the AWS pool. This cannot be undone.' -f $item.PublicIp)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'Released'
    Detail = ('{0} - permanent' -f $item.PublicIp); Succeeded = $true })
"""),

19: dict(
    file='Set-AwsEksNodeSchedulable',
    modules=['AWS.Tools.Common', 'AWS.Tools.EKS'],
    synopsis='Reports EKS node health and cordons NotReady nodes after approval.',
    desc='Checks node readiness across EKS clusters via kubectl and reports any node that is '
         'NotReady. The remediation - cordoning the node so the scheduler stops placing pods on it '
         '- is gated behind approval, because cordoning affects where workloads can run and a '
         'transiently NotReady node usually recovers on its own.',
    params=[REGION, PROFILE,
            dict(name='ClusterName', help='EKS cluster(s) to check. All clusters in the region when omitted.',
                 decl="[string[]]$ClusterName"),
            dict(name='KubectlPath', help='Path to the kubectl executable.',
                 decl="[string]$KubectlPath = 'kubectl'"),
            dict(name='NotReadyMinutes', help='Only propose cordoning a node that has been NotReady for at least this long. Guards against transient flaps.',
                 decl="[ValidateRange(1,1440)]\n    [int]$NotReadyMinutes = 15"),
            dict(name='Drain', help='Also drain the node after cordoning, evicting its pods. Considerably more disruptive than a cordon alone.',
                 decl="[switch]$Drain")],
    perms='eks:ListClusters, eks:DescribeCluster, plus a kubeconfig with node get/patch rights in the cluster.',
    actionVerb='Cordon EKS node',
    reason='EKS node remediation',
    rollback='Uncordon the node: kubectl uncordon <node>. A drained node additionally needs its '
             'evicted pods to reschedule, which the scheduler does automatically once the node is '
             'uncordoned and Ready.',
    notes='Requires kubectl on PATH and a kubeconfig for each cluster. The script calls '
          '"aws eks update-kubeconfig" through the AWS CLI before querying, so the AWS CLI must '
          'also be installed. Cordoning does NOT evict running pods - only -Drain does that.',
    examples=[("-Region me-central-1",
               'REQUEST mode - reports NotReady nodes across all clusters and raises an approval.'),
              ("-Region me-central-1 -ClusterName prod-eks -ApprovalReference APR-... -Drain",
               'Cordons and drains the approved nodes.')],
    discover="""
$awsArgs = @{}
if ($Region)      { $awsArgs.Region = $Region }
if ($ProfileName) { $awsArgs.ProfileName = $ProfileName }

if (-not (Get-Command $KubectlPath -ErrorAction SilentlyContinue)) {
    throw ('kubectl not found at "{0}". Install it or pass -KubectlPath.' -f $KubectlPath)
}

$clusters = if ($ClusterName) { $ClusterName } else { Get-EKSClusterList @awsArgs }

foreach ($cl in $clusters) {
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $cl -Message 'Updating kubeconfig and querying nodes'

    $awsCliArgs = @('eks', 'update-kubeconfig', '--name', $cl)
    if ($Region)      { $awsCliArgs += @('--region', $Region) }
    if ($ProfileName) { $awsCliArgs += @('--profile', $ProfileName) }
    & aws @awsCliArgs 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $cl `
            -Message 'aws eks update-kubeconfig failed - skipping this cluster'
        continue
    }

    $raw = & $KubectlPath get nodes -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $cl `
            -Message ('kubectl get nodes failed: {0}' -f ($raw -join ' '))
        continue
    }

    $nodes = ($raw | ConvertFrom-Json).items
    foreach ($n in $nodes) {
        $readyCond = $n.status.conditions | Where-Object { $_.type -eq 'Ready' } | Select-Object -First 1
        if (-not $readyCond) { continue }
        if ($readyCond.status -eq 'True') { continue }         # healthy

        $since = $null; $mins = $null
        if ($readyCond.lastTransitionTime) {
            $since = [datetime]$readyCond.lastTransitionTime
            $mins  = [math]::Round(((Get-Date).ToUniversalTime() - $since.ToUniversalTime()).TotalMinutes, 1)
        }

        # A node that flapped a minute ago usually recovers by itself.
        if ($null -ne $mins -and $mins -lt $NotReadyMinutes) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $n.metadata.name `
                -Message ('Skipped - NotReady for only {0} min, below the {1} min threshold' -f $mins, $NotReadyMinutes)
            continue
        }

        $results.Add([PSCustomObject]@{
            Name             = ('{0}/{1}' -f $cl, $n.metadata.name)
            Id               = $n.metadata.name
            Cluster          = $cl
            NodeName         = $n.metadata.name
            ReadyStatus      = $readyCond.status
            Reason           = $readyCond.reason
            Message          = $readyCond.message
            NotReadySince    = $since
            NotReadyMinutes  = $mins
            AlreadyCordoned  = [bool]$n.spec.unschedulable
            InstanceType     = $n.metadata.labels.'node.kubernetes.io/instance-type'
            KubeletVersion   = $n.status.nodeInfo.kubeletVersion
            PlannedAction    = if ($Drain) { 'cordon + drain (evicts pods)' } else { 'cordon only (no eviction)' }
        })
    }
}
""",
    act="""
if ($item.AlreadyCordoned) {
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message 'Already cordoned - no action needed'
    $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'AlreadyCordoned'; Detail = 'idempotent'; Succeeded = $true })
} else {
    $awsCliArgs = @('eks', 'update-kubeconfig', '--name', $item.Cluster)
    if ($Region)      { $awsCliArgs += @('--region', $Region) }
    if ($ProfileName) { $awsCliArgs += @('--profile', $ProfileName) }
    & aws @awsCliArgs 2>&1 | Out-Null

    $out = & $KubectlPath cordon $item.NodeName 2>&1
    if ($LASTEXITCODE -ne 0) { throw ('kubectl cordon failed: {0}' -f ($out -join ' ')) }
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message 'Node cordoned - scheduler will place no new pods here'

    $detail = 'cordoned'
    if ($Drain) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message 'Draining node - this EVICTS running pods'
        $dout = & $KubectlPath drain $item.NodeName --ignore-daemonsets --delete-emptydir-data --timeout=300s 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $label `
                -Message ('Drain failed (node remains cordoned): {0}' -f ($dout -join ' '))
            $detail = 'cordoned; drain FAILED'
        } else {
            $detail = 'cordoned and drained'
        }
    }
    $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'Cordoned'; Detail = $detail; Succeeded = $true })
}
"""),
}
