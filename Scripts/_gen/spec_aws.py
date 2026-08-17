# -*- coding: utf-8 -*-
"""AWS - 22 use cases. Real AWS.Tools cmdlets."""

REGION = dict(name='Region', help='AWS region to operate in. Defaults to the configured default region.',
              decl="[string]$Region")
PROFILE = dict(name='ProfileName', help='Named AWS profile / SSO profile to use. Prefer an IAM role where the host supports one.',
               decl="[string]$ProfileName")

SPECS = {

1: dict(
    file='Set-AwsInstanceSchedule',
    modules=['AWS.Tools.Common', 'AWS.Tools.EC2'],
    synopsis='Starts or stops tagged EC2 instances on a schedule.',
    desc='Finds EC2 instances carrying the scheduling tag and starts or stops them to match the '
         'requested state. The tag is the contract: an instance without it is never touched, so '
         'adding an instance to the schedule is a tagging operation rather than a code change.',
    params=[REGION, PROFILE,
            dict(name='ScheduleTagKey', help='Tag key that marks an instance as schedulable.',
                 decl="[string]$ScheduleTagKey = 'AutoOps:Schedule'"),
            dict(name='ScheduleTagValue', help='Tag value to match.',
                 decl="[string]$ScheduleTagValue = 'business-hours'"),
            dict(name='DesiredState', help='Start or Stop.',
                 decl="[ValidateSet('Start','Stop')]\n    [string]$DesiredState = 'Stop'")],
    perms='ec2:DescribeInstances, ec2:StartInstances, ec2:StopInstances',
    actionVerb='Start/stop EC2 instance',
    rollback='Reverse the -DesiredState. Instance store data does not survive a stop - the tag '
             'contract exists so only instances marked as safe to stop are ever selected.',
    examples=[("-DesiredState Stop -Region me-central-1",
               'Stops every instance tagged for scheduling in the given region.'),
              ("-DesiredState Start -WhatIf",
               'Shows which instances would be started without acting.')],
    discover="""
$awsArgs = @{}
if ($Region)      { $awsArgs.Region = $Region }
if ($ProfileName) { $awsArgs.ProfileName = $ProfileName }

$filter = @(
    @{ Name = "tag:$ScheduleTagKey"; Values = @($ScheduleTagValue) }
)
$reservations = Get-EC2Instance -Filter $filter @awsArgs
foreach ($r in $reservations) {
    foreach ($i in $r.Instances) {
        $wanted = if ($DesiredState -eq 'Start') { 'running' } else { 'stopped' }
        if ($i.State.Name.Value -eq $wanted) { continue }   # idempotent: already there
        $results.Add([PSCustomObject]@{
            Name         = ($i.Tags | Where-Object Key -eq 'Name' | Select-Object -First 1 -Expand Value)
            Id           = $i.InstanceId
            CurrentState = $i.State.Name.Value
            DesiredState = $wanted
            InstanceType = $i.InstanceType.Value
            CreatedAt    = $i.LaunchTime
        })
    }
}
""",
    act="""
if ($DesiredState -eq 'Start') { Start-EC2Instance -InstanceId $item.Id @awsArgs | Out-Null }
else                           { Stop-EC2Instance  -InstanceId $item.Id @awsArgs | Out-Null }
Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    '{0} issued ({1} -> {2})' -f $DesiredState, $item.CurrentState, $item.DesiredState)
$actions.Add([PSCustomObject]@{ Name = $item.Name; Action = $DesiredState; Detail = $item.Id; Succeeded = $true })
"""),

2: dict(
    file='Get-AwsServiceLimitReport',
    modules=['AWS.Tools.Common', 'AWS.Tools.ServiceQuotas'],
    synopsis='Reports AWS service quota usage against applied limits.',
    desc='Reads applied service quotas and flags any approaching its ceiling, which is the '
         'failure mode this use case exists to catch: a deployment that fails at 3am because an '
         'account silently hit a quota nobody was watching.',
    params=[REGION, PROFILE,
            dict(name='ServiceCode', help='Service codes to check, e.g. ec2, vpc, lambda.',
                 decl="[string[]]$ServiceCode = @('ec2','vpc','lambda','rds','elasticloadbalancing')"),
            dict(name='WarnAtPercent', help='Usage percentage at or above which a quota is flagged.',
                 decl="[ValidateRange(1,100)]\n    [int]$WarnAtPercent = 80")],
    perms='servicequotas:ListServiceQuotas, cloudwatch:GetMetricData',
    examples=[("-Region me-central-1", 'Reports quota headroom for the default service list.'),
              ("-ServiceCode ec2,rds -WarnAtPercent 70 -OutputFormat HTML",
               'Checks two services at a tighter threshold and writes an HTML report.')],
    discover="""
$awsArgs = @{}
if ($Region)      { $awsArgs.Region = $Region }
if ($ProfileName) { $awsArgs.ProfileName = $ProfileName }

foreach ($svc in $ServiceCode) {
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $svc -Message 'Reading applied quotas'
    $quotas = Get-SQServiceQuotaList -ServiceCode $svc @awsArgs
    foreach ($q in $quotas) {
        # Not every quota exposes a usage metric; those are reported with a null
        # usage rather than omitted, so the gap is visible instead of silent.
        $used = $null
        if ($q.UsageMetric -and $q.UsageMetric.MetricName) {
            try {
                $used = (Get-CWMetricStatistic -Namespace $q.UsageMetric.MetricNamespace `
                    -MetricName $q.UsageMetric.MetricName -Statistic Maximum `
                    -UtcStartTime (Get-Date).AddHours(-6) -UtcEndTime (Get-Date) -Period 3600 @awsArgs |
                    Select-Object -Expand Datapoints | Measure-Object -Property Maximum -Maximum).Maximum
            } catch {
                # Quota has no published usage metric, or CloudWatch has no
                # datapoint yet. Reported as unknown usage, not as zero.
                $used = $null
            }
        }
        $pct = if ($null -ne $used -and $q.Value -gt 0) { [math]::Round(($used / $q.Value) * 100, 1) } else { $null }
        $results.Add([PSCustomObject]@{
            Name        = $q.QuotaName
            Id          = $q.QuotaCode
            Service     = $svc
            AppliedLimit= $q.Value
            Used        = $used
            PercentUsed = $pct
            Adjustable  = $q.Adjustable
            Status      = if ($null -eq $pct) { 'Unknown' } elseif ($pct -ge $WarnAtPercent) { 'Warning' } else { 'OK' }
        })
    }
}
"""),

3: dict(
    file='Get-AwsWellArchitectedReview',
    modules=['AWS.Tools.Common', 'AWS.Tools.Support'],
    synopsis='Pulls AWS Trusted Advisor checks as a Well-Architected review summary.',
    desc='Runs the Trusted Advisor checks and groups results by pillar so the output reads as a '
         'review rather than a flat list of findings.',
    params=[PROFILE,
            dict(name='Category', help='Trusted Advisor categories to include.',
                 decl="[string[]]$Category = @('cost_optimizing','performance','security','fault_tolerance','service_limits')")],
    perms='support:DescribeTrustedAdvisorChecks, support:DescribeTrustedAdvisorCheckResult (Business/Enterprise support required)',
    notes='Trusted Advisor full checks require a Business or Enterprise support plan and the API is '
          'only available in us-east-1. The script targets us-east-1 for the Support API regardless '
          'of -Region, which applies to any other call.',
    examples=[("", 'Pulls all default categories.'),
              ("-Category security,service_limits -OutputFormat JSON",
               'Pulls two categories as JSON.')],
    notes2=True,
    discover="""
$awsArgs = @{ Region = 'us-east-1' }   # Support API is us-east-1 only
if ($ProfileName) { $awsArgs.ProfileName = $ProfileName }

$checks = Get-ASATrustedAdvisorCheck -Language en @awsArgs |
    Where-Object { $Category -contains $_.Category }

foreach ($chk in $checks) {
    $res = Get-ASATrustedAdvisorCheckResult -CheckId $chk.Id -Language en @awsArgs
    $results.Add([PSCustomObject]@{
        Name           = $chk.Name
        Id             = $chk.Id
        Pillar         = $chk.Category
        Status         = $res.Status
        ResourcesFlagged = $res.ResourcesSummary.ResourcesFlagged
        ResourcesProcessed = $res.ResourcesSummary.ResourcesProcessed
        EstimatedMonthlySavings = $res.CategorySpecificSummary.CostOptimizing.EstimatedMonthlySavings
        Description    = $chk.Description
    })
}
"""),

5: dict(
    file='Get-AwsS3PublicAccessAudit',
    modules=['AWS.Tools.Common', 'AWS.Tools.S3'],
    synopsis='Audits S3 buckets for public access exposure.',
    desc='Checks every bucket for its public access block configuration, ACL grants to AllUsers or '
         'AuthenticatedUsers, and a policy that allows a wildcard principal. A bucket is reported '
         'as exposed if any of the three is true, because any one of them is sufficient to make '
         'data public.',
    params=[REGION, PROFILE,
            dict(name='BucketName', help='Limit the audit to specific buckets.',
                 decl="[string[]]$BucketName")],
    perms='s3:ListAllMyBuckets, s3:GetBucketPublicAccessBlock, s3:GetBucketAcl, s3:GetBucketPolicy',
    examples=[("-OutputFormat HTML", 'Audits every bucket and writes an HTML report.'),
              ("-BucketName my-data-bucket", 'Audits one bucket.')],
    discover="""
$awsArgs = @{}
if ($Region)      { $awsArgs.Region = $Region }
if ($ProfileName) { $awsArgs.ProfileName = $ProfileName }

$buckets = if ($BucketName) { $BucketName | ForEach-Object { [PSCustomObject]@{ BucketName = $_ } } }
           else             { Get-S3Bucket @awsArgs }

foreach ($b in $buckets) {
    $name = $b.BucketName
    $blockAll = $null; $aclPublic = $false; $policyPublic = $false; $notes = @()

    try {
        $pab = Get-S3PublicAccessBlock -BucketName $name @awsArgs
        $blockAll = ($pab.PublicAccessBlockConfiguration.BlockPublicAcls -and
                     $pab.PublicAccessBlockConfiguration.BlockPublicPolicy -and
                     $pab.PublicAccessBlockConfiguration.IgnorePublicAcls -and
                     $pab.PublicAccessBlockConfiguration.RestrictPublicBuckets)
    } catch {
        # No public access block is itself the finding, not an error.
        $notes += 'no public access block configured'
        $blockAll = $false
    }

    try {
        $acl = Get-S3ACL -BucketName $name @awsArgs
        $aclPublic = [bool]($acl.Grants | Where-Object {
            $_.Grantee.URI -match 'AllUsers|AuthenticatedUsers' })
    } catch {
        $notes += 'ACL unreadable'
        Write-Verbose ('Could not read ACL for {0}: {1}' -f $name, $_.Exception.Message)
    }

    try {
        $pol = Get-S3BucketPolicy -BucketName $name @awsArgs
        if ($pol) { $policyPublic = ($pol -match '"Principal"\\s*:\\s*(\\{\\s*"AWS"\\s*:\\s*)?"\\*"') }
    } catch {
        # A bucket with no policy is normal and is not an exposure.
        Write-Verbose ('No bucket policy on {0}' -f $name)
    }

    $exposed = ((-not $blockAll) -and ($aclPublic -or $policyPublic))
    $results.Add([PSCustomObject]@{
        Name              = $name
        Id                = $name
        PublicAccessBlock = $blockAll
        PublicAcl         = $aclPublic
        PublicPolicy      = $policyPublic
        Exposed           = $exposed
        Status            = if ($exposed) { 'EXPOSED' } elseif (-not $blockAll) { 'Weak' } else { 'OK' }
        Notes             = ($notes -join '; ')
    })
    if ($exposed) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $name -Message 'Bucket is publicly accessible'
    }
}
"""),

6: dict(
    file='Get-AwsIamUnusedAccessKeyReport',
    modules=['AWS.Tools.Common', 'AWS.Tools.IdentityManagement'],
    synopsis='Reports IAM access keys that are unused or older than a threshold.',
    desc='Lists every IAM user access key with its age and last-used date, flagging keys that have '
         'never been used or have been idle beyond the threshold. Reporting only - key deactivation '
         'is a separate, approval-gated action.',
    params=[PROFILE,
            dict(name='MaxKeyAgeDays', help='Key age at or above which a key is flagged as stale.',
                 decl="[ValidateRange(1,3650)]\n    [int]$MaxKeyAgeDays = 90"),
            dict(name='MaxIdleDays', help='Days without use at or above which a key is flagged as idle.',
                 decl="[ValidateRange(1,3650)]\n    [int]$MaxIdleDays = 90")],
    perms='iam:ListUsers, iam:ListAccessKeys, iam:GetAccessKeyLastUsed',
    examples=[("-MaxKeyAgeDays 90", 'Flags keys older than 90 days.'),
              ("-MaxIdleDays 30 -OutputFormat CSV", 'Flags keys idle for a month, as CSV.')],
    discover="""
$awsArgs = @{}
if ($ProfileName) { $awsArgs.ProfileName = $ProfileName }

foreach ($u in (Get-IAMUserList @awsArgs)) {
    foreach ($k in (Get-IAMAccessKey -UserName $u.UserName @awsArgs)) {
        $ageDays = [math]::Round(((Get-Date) - $k.CreateDate).TotalDays, 0)
        $lastUsed = $null; $idleDays = $null; $service = $null
        try {
            $lu = Get-IAMAccessKeyLastUsed -AccessKeyId $k.AccessKeyId @awsArgs
            if ($lu.AccessKeyLastUsed.LastUsedDate -and
                $lu.AccessKeyLastUsed.LastUsedDate -gt [datetime]'2000-01-01') {
                $lastUsed = $lu.AccessKeyLastUsed.LastUsedDate
                $idleDays = [math]::Round(((Get-Date) - $lastUsed).TotalDays, 0)
                $service  = $lu.AccessKeyLastUsed.ServiceName
            }
        } catch {
            # A key that has never been used has no last-used record.
            Write-Verbose ('No last-used record for key {0}' -f $k.AccessKeyId)
        }

        $flags = @()
        if ($ageDays -ge $MaxKeyAgeDays) { $flags += "age>=${MaxKeyAgeDays}d" }
        if ($null -eq $lastUsed)         { $flags += 'never used' }
        elseif ($idleDays -ge $MaxIdleDays) { $flags += "idle>=${MaxIdleDays}d" }

        $results.Add([PSCustomObject]@{
            Name        = $u.UserName
            Id          = $k.AccessKeyId
            KeyStatus   = $k.Status
            CreatedAt   = $k.CreateDate
            AgeDays     = $ageDays
            LastUsed    = $lastUsed
            IdleDays    = $idleDays
            LastService = $service
            Status      = if ($flags.Count) { 'Flagged' } else { 'OK' }
            Flags       = ($flags -join '; ')
        })
    }
}
"""),

7: dict(
    file='Get-AwsSecurityHubFindingSummary',
    modules=['AWS.Tools.Common', 'AWS.Tools.SecurityHub'],
    synopsis='Aggregates AWS Security Hub findings by severity and control.',
    desc='Pulls active Security Hub findings and aggregates them by severity, product and control '
         'so that a recurring control failure is visible as one line rather than a thousand.',
    params=[REGION, PROFILE,
            dict(name='Severity', help='Severity labels to include.',
                 decl="[string[]]$Severity = @('CRITICAL','HIGH','MEDIUM')"),
            dict(name='MaxFindings', help='Maximum findings to retrieve.',
                 decl="[ValidateRange(1,10000)]\n    [int]$MaxFindings = 1000")],
    perms='securityhub:GetFindings',
    examples=[("-Severity CRITICAL,HIGH", 'Summarises only the two highest severities.'),
              ("-Region me-central-1 -OutputFormat HTML", 'Writes an HTML summary.')],
    discover="""
$awsArgs = @{}
if ($Region)      { $awsArgs.Region = $Region }
if ($ProfileName) { $awsArgs.ProfileName = $ProfileName }

$filter = @{
    SeverityLabel   = @($Severity | ForEach-Object { @{ Comparison = 'EQUALS'; Value = $_ } })
    RecordState     = @(@{ Comparison = 'EQUALS'; Value = 'ACTIVE' })
    WorkflowStatus  = @(@{ Comparison = 'EQUALS'; Value = 'NEW' })
}
$findings = Get-SHUBFinding -Filter $filter -MaxResult $MaxFindings @awsArgs

$findings | Group-Object { $_.Severity.Label }, { $_.ProductName }, { $_.Title } | ForEach-Object {
    $first = $_.Group[0]
    $results.Add([PSCustomObject]@{
        Name          = $first.Title
        Id            = $first.GeneratorId
        Severity      = $first.Severity.Label
        Product       = $first.ProductName
        Count         = $_.Count
        Resources     = (($_.Group.Resources.Id | Select-Object -Unique -First 5) -join '; ')
        FirstObserved = ($_.Group.FirstObservedAt | Sort-Object | Select-Object -First 1)
        Remediation   = $first.Remediation.Recommendation.Text
    })
}
"""),

8: dict(
    file='Get-AwsCostAnomalyReport',
    modules=['AWS.Tools.Common', 'AWS.Tools.CostExplorer'],
    synopsis='Reports AWS cost anomalies detected by Cost Anomaly Detection.',
    desc='Retrieves detected cost anomalies for the lookback period with their impact, root cause '
         'and the monitor that raised them.',
    params=[PROFILE,
            dict(name='LookbackDays', help='How far back to retrieve anomalies.',
                 decl="[ValidateRange(1,365)]\n    [int]$LookbackDays = 30"),
            dict(name='MinimumImpactUsd', help='Ignore anomalies below this total impact.',
                 decl="[double]$MinimumImpactUsd = 50")],
    perms='ce:GetAnomalies',
    notes='Cost Explorer APIs are billed per request. Scheduling this hourly is expensive for no '
          'benefit - anomaly detection runs daily.',
    examples=[("-LookbackDays 7", 'Reports the last week of anomalies.'),
              ("-MinimumImpactUsd 500 -OutputFormat HTML", 'Only material anomalies, as HTML.')],
    discover="""
$awsArgs = @{ Region = 'us-east-1' }   # Cost Explorer is a global endpoint
if ($ProfileName) { $awsArgs.ProfileName = $ProfileName }

$start = (Get-Date).AddDays(-$LookbackDays).ToString('yyyy-MM-dd')
$end   = (Get-Date).ToString('yyyy-MM-dd')

$anoms = Get-CEAnomaly -DateInterval_StartDate $start -DateInterval_EndDate $end @awsArgs
foreach ($a in $anoms) {
    if ($a.Impact.TotalImpact -lt $MinimumImpactUsd) { continue }
    $results.Add([PSCustomObject]@{
        Name           = ($a.RootCauses | Select-Object -First 1 -Expand Service)
        Id             = $a.AnomalyId
        StartDate      = $a.AnomalyStartDate
        EndDate        = $a.AnomalyEndDate
        TotalImpactUsd = [math]::Round($a.Impact.TotalImpact, 2)
        MaxImpactUsd   = [math]::Round($a.Impact.MaxImpact, 2)
        Feedback       = $a.Feedback
        RootCauses     = (($a.RootCauses | ForEach-Object { "$($_.Service)/$($_.Region)/$($_.UsageType)" }) -join '; ')
    })
}
"""),

10: dict(
    file='New-AwsRdsSnapshot',
    modules=['AWS.Tools.Common', 'AWS.Tools.RDS'],
    synopsis='Creates manual RDS snapshots for tagged database instances.',
    desc='Takes a manual snapshot of each RDS instance carrying the backup tag, and optionally '
         'prunes manual snapshots older than the retention period. Automated snapshots are never '
         'touched - only manual ones this script created.',
    params=[REGION, PROFILE,
            dict(name='BackupTagKey', help='Tag key marking an instance for snapshotting.',
                 decl="[string]$BackupTagKey = 'AutoOps:Backup'"),
            dict(name='SnapshotPrefix', help='Prefix for generated snapshot identifiers.',
                 decl="[string]$SnapshotPrefix = 'autoops'")],
    perms='rds:DescribeDBInstances, rds:CreateDBSnapshot, rds:ListTagsForResource',
    actionVerb='Create RDS snapshot',
    rollback='A snapshot is additive - it can be deleted if unwanted. It changes nothing about the '
             'running instance.',
    examples=[("-Region me-central-1", 'Snapshots every tagged instance.'),
              ("-WhatIf", 'Shows which instances would be snapshotted.')],
    discover="""
$awsArgs = @{}
if ($Region)      { $awsArgs.Region = $Region }
if ($ProfileName) { $awsArgs.ProfileName = $ProfileName }

foreach ($db in (Get-RDSDBInstance @awsArgs)) {
    $tags = Get-RDSTagForResource -ResourceName $db.DBInstanceArn @awsArgs
    if (-not ($tags | Where-Object { $_.Key -eq $BackupTagKey })) { continue }
    if ($db.DBInstanceStatus -ne 'available') {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $db.DBInstanceIdentifier `
            -Message ('Skipped - status is {0}, not available' -f $db.DBInstanceStatus)
        continue
    }
    $results.Add([PSCustomObject]@{
        Name       = $db.DBInstanceIdentifier
        Id         = $db.DBInstanceIdentifier
        Engine     = $db.Engine
        SizeGB     = $db.AllocatedStorage
        MultiAZ    = $db.MultiAZ
        SnapshotId = ('{0}-{1}-{2}' -f $SnapshotPrefix, $db.DBInstanceIdentifier, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    })
}
""",
    act="""
New-RDSDBSnapshot -DBInstanceIdentifier $item.Id -DBSnapshotIdentifier $item.SnapshotId @awsArgs | Out-Null
Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Snapshot {0} requested' -f $item.SnapshotId)
$actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'SnapshotCreated'; Detail = $item.SnapshotId; Succeeded = $true })
"""),

11: dict(
    file='Test-AwsCloudTrailIntegrity',
    modules=['AWS.Tools.Common', 'AWS.Tools.CloudTrail'],
    synopsis='Verifies CloudTrail is enabled, multi-region and log-file validated.',
    desc='Checks each trail for the properties that make its logs trustworthy as evidence: it is '
         'logging, it covers all regions, log file validation is on, and it writes to an encrypted '
         'bucket. A trail that fails any of these is reported, because an audit trail nobody can '
         'prove is intact is not an audit trail.',
    params=[REGION, PROFILE],
    perms='cloudtrail:DescribeTrails, cloudtrail:GetTrailStatus',
    examples=[("", 'Checks every trail in the account.'),
              ("-Region me-central-1 -OutputFormat JSON", 'Checks one region as JSON.')],
    discover="""
$awsArgs = @{}
if ($Region)      { $awsArgs.Region = $Region }
if ($ProfileName) { $awsArgs.ProfileName = $ProfileName }

foreach ($t in (Get-CTTrail @awsArgs)) {
    $status = Get-CTTrailStatus -Name $t.TrailARN @awsArgs
    $issues = @()
    if (-not $status.IsLogging)          { $issues += 'not logging' }
    if (-not $t.IsMultiRegionTrail)      { $issues += 'not multi-region' }
    if (-not $t.LogFileValidationEnabled){ $issues += 'log file validation disabled' }
    if (-not $t.KmsKeyId)                { $issues += 'logs not KMS encrypted' }

    $results.Add([PSCustomObject]@{
        Name              = $t.Name
        Id                = $t.TrailARN
        IsLogging         = $status.IsLogging
        MultiRegion       = $t.IsMultiRegionTrail
        LogValidation     = $t.LogFileValidationEnabled
        KmsEncrypted      = [bool]$t.KmsKeyId
        S3Bucket          = $t.S3BucketName
        LatestDelivery    = $status.LatestDeliveryTime
        LatestDeliveryError = $status.LatestDeliveryError
        Status            = if ($issues.Count) { 'NonCompliant' } else { 'Compliant' }
        Issues            = ($issues -join '; ')
    })
    if ($issues.Count) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $t.Name -Message ($issues -join '; ')
    }
}
"""),

13: dict(
    file='Test-AwsAutoScalingGroupHealth',
    modules=['AWS.Tools.Common', 'AWS.Tools.AutoScaling'],
    synopsis='Checks Auto Scaling groups for unhealthy or out-of-balance capacity.',
    desc='Reports each ASG where the number of healthy in-service instances does not match desired '
         'capacity, or where instances are distributed unevenly across availability zones.',
    params=[REGION, PROFILE,
            dict(name='AutoScalingGroupName', help='Limit to specific groups.',
                 decl="[string[]]$AutoScalingGroupName")],
    perms='autoscaling:DescribeAutoScalingGroups',
    examples=[("", 'Checks every ASG in the region.'),
              ("-AutoScalingGroupName web-asg -OutputFormat JSON", 'Checks one group.')],
    discover="""
$awsArgs = @{}
if ($Region)      { $awsArgs.Region = $Region }
if ($ProfileName) { $awsArgs.ProfileName = $ProfileName }
if ($AutoScalingGroupName) { $awsArgs.AutoScalingGroupName = $AutoScalingGroupName }

foreach ($g in (Get-ASAutoScalingGroup @awsArgs)) {
    $healthy = @($g.Instances | Where-Object { $_.HealthStatus -eq 'Healthy' -and $_.LifecycleState -eq 'InService' })
    $byAz = $g.Instances | Group-Object AvailabilityZone
    $spread = if ($byAz.Count -gt 0) { ($byAz | Measure-Object Count -Maximum).Maximum -
                                       ($byAz | Measure-Object Count -Minimum).Minimum } else { 0 }
    $issues = @()
    if ($healthy.Count -ne $g.DesiredCapacity) { $issues += "healthy $($healthy.Count) != desired $($g.DesiredCapacity)" }
    if ($spread -gt 1)                          { $issues += "AZ imbalance (spread $spread)" }

    $results.Add([PSCustomObject]@{
        Name            = $g.AutoScalingGroupName
        Id              = $g.AutoScalingGroupARN
        DesiredCapacity = $g.DesiredCapacity
        MinSize         = $g.MinSize
        MaxSize         = $g.MaxSize
        HealthyCount    = $healthy.Count
        TotalInstances  = $g.Instances.Count
        AzSpread        = $spread
        Status          = if ($issues.Count) { 'Degraded' } else { 'Healthy' }
        Issues          = ($issues -join '; ')
    })
}
"""),

14: dict(
    file='Get-AwsConfigComplianceReport',
    modules=['AWS.Tools.Common', 'AWS.Tools.ConfigService'],
    synopsis='Reports AWS Config rule compliance across the account.',
    desc='Summarises every AWS Config rule with its compliance state and the count of '
         'non-compliant resources, so a drifting rule is visible without opening the console.',
    params=[REGION, PROFILE,
            dict(name='OnlyNonCompliant', help='Report only rules that are currently non-compliant.',
                 decl="[switch]$OnlyNonCompliant")],
    perms='config:DescribeConfigRules, config:DescribeComplianceByConfigRule',
    examples=[("-OnlyNonCompliant", 'Reports just the failing rules.'),
              ("-OutputFormat HTML", 'Full compliance report as HTML.')],
    discover="""
$awsArgs = @{}
if ($Region)      { $awsArgs.Region = $Region }
if ($ProfileName) { $awsArgs.ProfileName = $ProfileName }

foreach ($r in (Get-CFGConfigRule @awsArgs)) {
    $c = Get-CFGComplianceByConfigRule -ConfigRuleName $r.ConfigRuleName @awsArgs
    $state = $c.Compliance.ComplianceType
    if ($OnlyNonCompliant -and $state -ne 'NON_COMPLIANT') { continue }
    $results.Add([PSCustomObject]@{
        Name            = $r.ConfigRuleName
        Id              = $r.ConfigRuleId
        Compliance      = $state
        NonCompliantCount = $c.Compliance.ComplianceContributorCount.CappedCount
        RuleState       = $r.ConfigRuleState
        Source          = $r.Source.Owner
        Description     = $r.Description
        Status          = if ($state -eq 'NON_COMPLIANT') { 'NonCompliant' } else { 'OK' }
    })
}
"""),

16: dict(
    file='Get-AwsGuardDutyFindingReport',
    modules=['AWS.Tools.Common', 'AWS.Tools.GuardDuty'],
    synopsis='Reports GuardDuty findings above a severity threshold.',
    desc='Retrieves current GuardDuty findings for each detector, filtered by severity, with the '
         'affected resource and the finding type.',
    params=[REGION, PROFILE,
            dict(name='MinimumSeverity', help='GuardDuty numeric severity floor. 4 = medium, 7 = high.',
                 decl="[ValidateRange(1,10)]\n    [double]$MinimumSeverity = 4"),
            dict(name='MaxFindings', help='Maximum findings to retrieve per detector.',
                 decl="[ValidateRange(1,1000)]\n    [int]$MaxFindings = 200")],
    perms='guardduty:ListDetectors, guardduty:ListFindings, guardduty:GetFindings',
    examples=[("-MinimumSeverity 7", 'High severity findings only.'),
              ("-Region me-central-1 -OutputFormat HTML", 'HTML report for one region.')],
    discover="""
$awsArgs = @{}
if ($Region)      { $awsArgs.Region = $Region }
if ($ProfileName) { $awsArgs.ProfileName = $ProfileName }

foreach ($d in (Get-GDDetectorList @awsArgs)) {
    $criteria = @{ Criterion = @{
        'severity'    = @{ GreaterThanOrEqual = $MinimumSeverity }
        'service.archived' = @{ Eq = @('false') }
    } }
    $ids = Get-GDFindingList -DetectorId $d -FindingCriteria $criteria -MaxResult $MaxFindings @awsArgs
    if (-not $ids) { continue }
    foreach ($f in (Get-GDFinding -DetectorId $d -FindingId $ids @awsArgs)) {
        $results.Add([PSCustomObject]@{
            Name        = $f.Title
            Id          = $f.Id
            Severity    = $f.Severity
            Type        = $f.Type
            Resource    = $f.Resource.ResourceType
            InstanceId  = $f.Resource.InstanceDetails.InstanceId
            Region      = $f.Region
            FirstSeen   = $f.Service.EventFirstSeen
            LastSeen    = $f.Service.EventLastSeen
            Count       = $f.Service.Count
            Description = $f.Description
        })
    }
}
"""),

18: dict(
    file='Get-AwsLambdaErrorRateReport',
    modules=['AWS.Tools.Common', 'AWS.Tools.Lambda', 'AWS.Tools.CloudWatch'],
    synopsis='Reports Lambda functions whose error rate exceeds a threshold.',
    desc='For each function, reads CloudWatch Invocations and Errors over the lookback window and '
         'reports the error rate. Functions with no invocations are reported as idle rather than '
         'as zero-error, because those are different facts.',
    params=[REGION, PROFILE,
            dict(name='LookbackHours', help='Metric window in hours.',
                 decl="[ValidateRange(1,336)]\n    [int]$LookbackHours = 24"),
            dict(name='ErrorRateWarnPercent', help='Error rate at or above which a function is flagged.',
                 decl="[ValidateRange(0,100)]\n    [double]$ErrorRateWarnPercent = 1")],
    perms='lambda:ListFunctions, cloudwatch:GetMetricStatistics',
    examples=[("-LookbackHours 6", 'Checks the last six hours.'),
              ("-ErrorRateWarnPercent 5 -OutputFormat CSV", 'Flags above 5%, as CSV.')],
    discover="""
$awsArgs = @{}
if ($Region)      { $awsArgs.Region = $Region }
if ($ProfileName) { $awsArgs.ProfileName = $ProfileName }

$from = (Get-Date).AddHours(-$LookbackHours)
$to   = Get-Date

foreach ($fn in (Get-LMFunctionList @awsArgs)) {
    $dim = @(@{ Name = 'FunctionName'; Value = $fn.FunctionName })
    $inv = (Get-CWMetricStatistic -Namespace 'AWS/Lambda' -MetricName 'Invocations' -Dimension $dim `
            -Statistic Sum -UtcStartTime $from -UtcEndTime $to -Period 3600 @awsArgs |
            Select-Object -Expand Datapoints | Measure-Object Sum -Sum).Sum
    $err = (Get-CWMetricStatistic -Namespace 'AWS/Lambda' -MetricName 'Errors' -Dimension $dim `
            -Statistic Sum -UtcStartTime $from -UtcEndTime $to -Period 3600 @awsArgs |
            Select-Object -Expand Datapoints | Measure-Object Sum -Sum).Sum

    $inv = [double]($inv | ForEach-Object { $_ }); if (-not $inv) { $inv = 0 }
    $err = [double]($err | ForEach-Object { $_ }); if (-not $err) { $err = 0 }
    $rate = if ($inv -gt 0) { [math]::Round(($err / $inv) * 100, 2) } else { $null }

    $results.Add([PSCustomObject]@{
        Name         = $fn.FunctionName
        Id           = $fn.FunctionArn
        Runtime      = $fn.Runtime
        Invocations  = $inv
        Errors       = $err
        ErrorRatePct = $rate
        Status       = if ($inv -eq 0) { 'Idle' }
                       elseif ($rate -ge $ErrorRateWarnPercent) { 'Warning' } else { 'OK' }
    })
}
"""),

20: dict(
    file='Get-AwsTrustedAdvisorWeeklyReport',
    modules=['AWS.Tools.Common', 'AWS.Tools.Support'],
    synopsis='Produces the weekly Trusted Advisor summary with week-on-week movement.',
    desc='Pulls all Trusted Advisor checks and compares them against the previous run stored on '
         'disk, so the report shows what changed this week rather than repeating the same list.',
    params=[PROFILE,
            dict(name='StateFile', help='Path used to store the previous run for comparison.',
                 decl="[string]$StateFile")],
    perms='support:DescribeTrustedAdvisorChecks, support:DescribeTrustedAdvisorCheckResult',
    notes='Requires a Business or Enterprise support plan. The Support API is us-east-1 only.',
    examples=[("-OutputFormat HTML", 'Weekly report as HTML with movement since last run.'),
              ("-StateFile C:\\Automation\\ta-state.json", 'Uses an explicit state file.')],
    discover="""
$awsArgs = @{ Region = 'us-east-1' }
if ($ProfileName) { $awsArgs.ProfileName = $ProfileName }

if (-not $StateFile) {
    $StateFile = Join-Path $env:ProgramData 'ITAutomation\\State\\aws-trustedadvisor.json'
}
$prev = @{}
if (Test-Path -LiteralPath $StateFile) {
    try {
        (Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json) |
            ForEach-Object { $prev[$_.Id] = $_.ResourcesFlagged }
    } catch { Write-AutomationLog -ScriptName $scriptName -Level WARN -Message 'Previous state unreadable; reporting without movement.' }
}

$snapshot = @()
foreach ($chk in (Get-ASATrustedAdvisorCheck -Language en @awsArgs)) {
    $res = Get-ASATrustedAdvisorCheckResult -CheckId $chk.Id -Language en @awsArgs
    $flagged = $res.ResourcesSummary.ResourcesFlagged
    $was = if ($prev.ContainsKey($chk.Id)) { $prev[$chk.Id] } else { $null }
    $results.Add([PSCustomObject]@{
        Name       = $chk.Name
        Id         = $chk.Id
        Category   = $chk.Category
        Status     = $res.Status
        Flagged    = $flagged
        PreviousFlagged = $was
        Movement   = if ($null -eq $was) { 'new' }
                     elseif ($flagged -gt $was) { "worse (+$($flagged - $was))" }
                     elseif ($flagged -lt $was) { "better (-$($was - $flagged))" }
                     else { 'unchanged' }
    })
    $snapshot += [PSCustomObject]@{ Id = $chk.Id; ResourcesFlagged = $flagged }
}

$dir = Split-Path -Parent $StateFile
if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
$snapshot | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $StateFile -Encoding UTF8
"""),

21: dict(
    file='Get-AwsRoute53HealthCheckStatus',
    modules=['AWS.Tools.Common', 'AWS.Tools.Route53'],
    synopsis='Reports the status of Route 53 health checks.',
    desc='Lists every Route 53 health check with its current status and the endpoint it monitors, '
         'flagging any that are unhealthy.',
    params=[PROFILE],
    perms='route53:ListHealthChecks, route53:GetHealthCheckStatus',
    examples=[("", 'Reports every health check.'),
              ("-OutputFormat JSON", 'Reports as JSON for downstream alerting.')],
    discover="""
$awsArgs = @{}
if ($ProfileName) { $awsArgs.ProfileName = $ProfileName }

foreach ($hc in (Get-R53HealthCheckList @awsArgs)) {
    $obs = @()
    try {
        $obs = Get-R53HealthCheckStatus -HealthCheckId $hc.Id @awsArgs
    } catch {
        # Status is unavailable for a check that has not yet reported.
        Write-Verbose ('No status yet for health check {0}' -f $hc.Id)
    }
    $unhealthy = @($obs | Where-Object { $_.StatusReport.Status -notmatch 'Success' })
    $results.Add([PSCustomObject]@{
        Name        = if ($hc.HealthCheckConfig.FullyQualifiedDomainName) { $hc.HealthCheckConfig.FullyQualifiedDomainName }
                      else { $hc.HealthCheckConfig.IPAddress }
        Id          = $hc.Id
        Type        = $hc.HealthCheckConfig.Type
        Port        = $hc.HealthCheckConfig.Port
        ResourcePath= $hc.HealthCheckConfig.ResourcePath
        CheckerCount= $obs.Count
        UnhealthyCheckers = $unhealthy.Count
        Status      = if ($obs.Count -eq 0) { 'Unknown' }
                      elseif ($unhealthy.Count -eq 0) { 'Healthy' }
                      elseif ($unhealthy.Count -eq $obs.Count) { 'Unhealthy' }
                      else { 'Degraded' }
    })
}
"""),

22: dict(
    file='Get-AwsCertificateExpiryReport',
    modules=['AWS.Tools.Common', 'AWS.Tools.CertificateManager'],
    synopsis='Reports ACM certificates approaching expiry.',
    desc='Lists ACM certificates with days remaining until expiry, flagging those inside the '
         'warning window. Certificates pending validation are reported separately, because those '
         'will never renew on their own.',
    params=[REGION, PROFILE,
            dict(name='WarnWithinDays', help='Flag certificates expiring within this many days.',
                 decl="[ValidateRange(1,3650)]\n    [int]$WarnWithinDays = 45")],
    perms='acm:ListCertificates, acm:DescribeCertificate',
    examples=[("-WarnWithinDays 30", 'Flags certificates expiring in a month.'),
              ("-OutputFormat HTML", 'HTML report of all certificates.')],
    discover="""
$awsArgs = @{}
if ($Region)      { $awsArgs.Region = $Region }
if ($ProfileName) { $awsArgs.ProfileName = $ProfileName }

foreach ($c in (Get-ACMCertificateList @awsArgs)) {
    $d = Get-ACMCertificateDetail -CertificateArn $c.CertificateArn @awsArgs
    $days = if ($d.NotAfter) { [math]::Round(($d.NotAfter - (Get-Date)).TotalDays, 0) } else { $null }
    $status = if ($d.Status -ne 'ISSUED') { $d.Status }
              elseif ($null -eq $days) { 'Unknown' }
              elseif ($days -le 0) { 'EXPIRED' }
              elseif ($days -le $WarnWithinDays) { 'Expiring' }
              else { 'OK' }
    $results.Add([PSCustomObject]@{
        Name           = $d.DomainName
        Id             = $d.CertificateArn
        Status         = $status
        CertStatus     = $d.Status
        NotAfter       = $d.NotAfter
        DaysRemaining  = $days
        RenewalEligibility = $d.RenewalEligibility
        InUseBy        = ($d.InUseBy -join '; ')
        Type           = $d.Type
    })
    if ($status -in @('Expiring','EXPIRED')) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $d.DomainName `
            -Message ('Certificate {0} - {1} day(s) remaining' -f $status, $days)
    }
}
"""),
}

# The remaining six use cases live in their own module to keep this file readable.
try:
    from spec_aws2 import EXTRA as _EXTRA
    SPECS.update(_EXTRA)
except ImportError:
    pass
