# -*- coding: utf-8 -*-
"""M365 - use cases 12-22."""

def graph(scopes):
    return ("\nConnect-MgGraph -Scopes '%s' -NoWelcome -ErrorAction Stop\n"
            "Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Microsoft Graph'\n" % scopes)

EXTRA = {

12: dict(
    file='Get-M365SecureScore',
    modules=['Microsoft.Graph.Authentication', 'Microsoft.Graph.Security'],
    synopsis='Reports Microsoft Secure Score and alerts on score drops.',
    desc='Reads the current Secure Score, compares it against the previous run stored on disk, and '
         'reports both the movement and the control profiles that regressed. A falling score is more '
         'actionable than an absolute number, which is why the comparison is the point of this report.',
    params=[dict(name='StateFile', help='Path used to store the previous score for comparison.',
                 decl="[string]$StateFile"),
            dict(name='DropAlertPoints', help='Report a drop of at least this many points as a warning.',
                 decl="[ValidateRange(1,1000)]\n    [double]$DropAlertPoints = 5"),
            dict(name='IncludeControls', help='Include the per-control breakdown, not just the headline score.',
                 decl="[switch]$IncludeControls")],
    perms='Microsoft Graph SecurityEvents.Read.All.',
    examples=[("-OutputFormat HTML", 'Secure Score with movement since the last run.'),
              ("-IncludeControls -DropAlertPoints 2", 'Sensitive alerting with the control breakdown.')],
    discover=graph("SecurityEvents.Read.All") + """
if (-not $StateFile) {
    $StateFile = Join-Path $env:ProgramData 'ITAutomation\\State\\m365-securescore.json'
}

$scores = Invoke-MgGraphRequest -Method GET `
    -Uri 'https://graph.microsoft.com/v1.0/security/secureScores?$top=1' -ErrorAction Stop
$current = $scores.value | Select-Object -First 1
if (-not $current) { throw 'No Secure Score data returned for this tenant.' }

$previous = $null
if (Test-Path -LiteralPath $StateFile) {
    try { $previous = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json } catch {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message 'Previous score unreadable; reporting without movement.'
    }
}

$delta = if ($previous) { [math]::Round($current.currentScore - $previous.currentScore, 2) } else { $null }
$pct = if ($current.maxScore -gt 0) { [math]::Round(($current.currentScore / $current.maxScore) * 100, 1) } else { $null }

$results.Add([PSCustomObject]@{
    Name          = 'Microsoft Secure Score'
    Id            = $current.id
    RecordType    = 'Score'
    Category      = 'Tenant total'
    CurrentScore  = [math]::Round($current.currentScore, 2)
    MaxScore      = [math]::Round($current.maxScore, 2)
    PercentOfMax  = $pct
    PreviousScore = if ($previous) { [math]::Round($previous.currentScore, 2) } else { $null }
    Delta         = $delta
    Movement      = if ($null -eq $delta) { 'first run' }
                    elseif ($delta -lt 0) { ('DROPPED {0} point(s)' -f [math]::Abs($delta)) }
                    elseif ($delta -gt 0) { ('improved {0} point(s)' -f $delta) }
                    else { 'unchanged' }
    Description   = ('{0} of {1} points' -f [math]::Round($current.currentScore, 2), [math]::Round($current.maxScore, 2))
    ActiveUsers   = $current.activeUserCount
    MeasuredAt    = $current.createdDateTime
    Status        = if ($null -ne $delta -and $delta -le (-1 * $DropAlertPoints)) { 'Warning' } else { 'OK' }
})

if ($null -ne $delta -and $delta -le (-1 * $DropAlertPoints)) {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
        'Secure Score dropped {0} point(s): {1} -> {2}' -f
        [math]::Abs($delta), $previous.currentScore, $current.currentScore)
}

if ($IncludeControls) {
    $prevControls = @{}
    if ($previous -and $previous.controlScores) {
        foreach ($c in $previous.controlScores) { $prevControls[$c.controlName] = $c.score }
    }

    foreach ($c in $current.controlScores) {
        $was = if ($prevControls.ContainsKey($c.controlName)) { $prevControls[$c.controlName] } else { $null }
        $cDelta = if ($null -ne $was) { [math]::Round($c.score - $was, 2) } else { $null }

        $results.Add([PSCustomObject]@{
            Name          = $c.controlName
            Id            = $c.controlName
            RecordType    = 'Control'
            Category      = $c.controlCategory
            CurrentScore  = $c.score
            MaxScore      = $null
            PercentOfMax  = $null
            PreviousScore = $was
            Delta         = $cDelta
            Movement      = if ($null -eq $cDelta) { 'new' }
                            elseif ($cDelta -lt 0) { 'regressed' }
                            elseif ($cDelta -gt 0) { 'improved' }
                            else { 'unchanged' }
            Description   = $c.description
            ActiveUsers   = $null
            MeasuredAt    = $current.createdDateTime
            Status        = if ($null -ne $cDelta -and $cDelta -lt 0) { 'Regressed' } else { 'OK' }
        })
    }
}

$dir = Split-Path -Parent $StateFile
if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
$current | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StateFile -Encoding UTF8
"""),

13: dict(
    file='Remove-TeamsMeetingRecording',
    modules=['Microsoft.Graph.Authentication', 'Microsoft.Graph.Files'],
    synopsis='Deletes Teams meeting recordings older than a retention threshold.',
    desc='Finds meeting recordings in OneDrive beyond the retention age and deletes them. The '
         'workbook is explicit that retention and legal-hold exclusions must be confirmed first, so '
         'this script checks each item for a hold and refuses to propose anything under one.',
    params=[dict(name='UserPrincipalName', help='Limit to specific users. All licensed users when omitted.',
                 decl="[string[]]$UserPrincipalName"),
            dict(name='MaxUsers', help='Maximum users to scan when -UserPrincipalName is omitted.',
                 decl="[ValidateRange(1,10000)]\n    [int]$MaxUsers = 200"),
            dict(name='RecordingsFolder', help='Folder recordings are stored in.',
                 decl="[string]$RecordingsFolder = 'Recordings'"),
            dict(name='LegalHoldConfirmed', help='Confirms retention and legal-hold exclusions have been checked, per the SOP.',
                 decl="[switch]$LegalHoldConfirmed")],
    minage=30,
    perms='Microsoft Graph Files.ReadWrite.All and User.Read.All.',
    actionVerb='Delete meeting recording',
    reason='Teams recording retention cleanup',
    rollback='A deleted item goes to the OneDrive recycle bin and is recoverable for 93 days, then '
             'permanently removed.',
    notes='This script cannot see eDiscovery holds applied at the tenant level - it can only detect '
          'item-level retention labels. -LegalHoldConfirmed is the operator asserting that the '
          'tenant-level check was done, which is why it is mandatory rather than advisory.',
    examples=[("-MinimumAgeDays 30",
               'REPORT ONLY. Lists recordings older than 30 days and raises an approval.'),
              ("-MinimumAgeDays 30 -LegalHoldConfirmed -ApprovalReference APR-... -Execute",
               'Deletes the approved recordings.')],
    discover=graph("Files.ReadWrite.All','User.Read.All") + """
if (-not $LegalHoldConfirmed) {
    throw 'Refusing to proceed without -LegalHoldConfirmed. The SOP requires retention and ' +
          'legal-hold exclusions to be confirmed before recordings are deleted.'
}

$users = if ($UserPrincipalName) { $UserPrincipalName | ForEach-Object { Get-MgUser -UserId $_ -ErrorAction Stop } }
         else { Get-MgUser -Filter 'assignedLicenses/$count ne 0' -ConsistencyLevel eventual -CountVariable c -Top $MaxUsers -ErrorAction Stop }

$cutoff = (Get-Date).AddDays(-$MinimumAgeDays)

foreach ($u in $users) {
    $drive = $null
    try { $drive = Get-MgUserDrive -UserId $u.Id -ErrorAction Stop } catch { continue }

    $folder = $null
    try {
        $folder = Get-MgDriveRootChild -DriveId $drive.Id -ErrorAction Stop |
                  Where-Object { $_.Name -eq $RecordingsFolder -and $_.Folder } | Select-Object -First 1
    } catch {
        Write-Verbose ('No recordings folder for {0}' -f $u.UserPrincipalName)
    }
    if (-not $folder) { continue }

    $items = @()
    try { $items = @(Get-MgDriveItemChild -DriveId $drive.Id -DriveItemId $folder.Id -All -ErrorAction Stop) } catch {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $u.UserPrincipalName `
            -Message ('Could not enumerate recordings: {0}' -f $_.Exception.Message)
        continue
    }

    foreach ($it in $items) {
        if ($it.Folder) { continue }
        if ($it.CreatedDateTime -ge $cutoff) { continue }

        # Item-level retention label. Tenant-level eDiscovery holds are not
        # visible here, which is what -LegalHoldConfirmed covers.
        $hasLabel = $false
        try {
            $labelResp = Invoke-MgGraphRequest -Method GET `
                -Uri ('https://graph.microsoft.com/v1.0/drives/{0}/items/{1}/retentionLabel' -f $drive.Id, $it.Id) `
                -ErrorAction Stop
            $hasLabel = [bool]$labelResp.name
        } catch {
            Write-Verbose ('No retention label on {0}' -f $it.Name)
        }
        if ($hasLabel) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $it.Name `
                -Message 'Excluded - carries a retention label'
            continue
        }

        $results.Add([PSCustomObject]@{
            Name        = ('{0} / {1}' -f $u.UserPrincipalName, $it.Name)
            Id          = $it.Id
            Owner       = $u.UserPrincipalName
            DriveId     = $drive.Id
            ItemName    = $it.Name
            SizeMB      = if ($it.Size) { [math]::Round($it.Size / 1MB, 2) } else { $null }
            CreatedAt   = $it.CreatedDateTime
            AgeDays     = [math]::Round(((Get-Date) - $it.CreatedDateTime).TotalDays, 0)
            WebUrl      = $it.WebUrl
            RetentionLabel = 'none detected at item level'
        })
    }
}
""",
    act="""
Invoke-MgGraphRequest -Method DELETE `
    -Uri ('https://graph.microsoft.com/v1.0/drives/{0}/items/{1}' -f $item.DriveId, $item.Id) `
    -ErrorAction Stop | Out-Null

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Recording deleted: {0} ({1}MB, {2}d old). Recycle bin retains it for 93 days.' -f
    $item.ItemName, $item.SizeMB, $item.AgeDays)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'Deleted'
    Detail = ('{0}MB, {1}d old' -f $item.SizeMB, $item.AgeDays); Succeeded = $true })
"""),

14: dict(
    file='New-PlannerTask',
    modules=['Microsoft.Graph.Authentication', 'Microsoft.Graph.Planner'],
    synopsis='Creates Planner tasks from ITSM ticket fields.',
    desc='Creates tasks in a Planner plan bucket with an assignee and due date, typically driven by '
         'an ITSM ticket. Additive and low risk.',
    params=[dict(name='PlanName', help='Planner plan display name.',
                 decl="[Parameter(Mandatory)]\n    [string]$PlanName"),
            dict(name='BucketName', help='Bucket within the plan. The first bucket is used when omitted.',
                 decl="[string]$BucketName"),
            dict(name='TaskTitle', help='Task title(s) to create.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$TaskTitle"),
            dict(name='AssignTo', help='UPN of the person to assign the task to.',
                 decl="[string]$AssignTo"),
            dict(name='DueDate', help='Task due date.',
                 decl="[datetime]$DueDate"),
            dict(name='TicketReference', help='ITSM ticket driving the request. Added to the task description.',
                 decl="[string]$TicketReference")],
    perms='Microsoft Graph Tasks.ReadWrite and Group.Read.All.',
    actionVerb='Create Planner task',
    rollback='Delete the task. Planner tasks have no recycle bin, so deletion is immediate.',
    examples=[("-PlanName 'IT Operations' -TaskTitle 'Replace failed disk' -AssignTo eng@contoso.com -TicketReference INC0012345",
               'Creates an assigned task.'),
              ("-PlanName 'IT Operations' -TaskTitle 'Review backups' -DueDate '2026-09-01' -WhatIf",
               'Shows the task that would be created.')],
    discover=graph("Tasks.ReadWrite','Group.Read.All','User.Read.All") + """
$plans = @()
foreach ($g in (Get-MgGroup -Filter "groupTypes/any(c:c eq 'Unified')" -All -ErrorAction Stop)) {
    try { $plans += Get-MgGroupPlannerPlan -GroupId $g.Id -ErrorAction Stop } catch { continue }
}
$plan = $plans | Where-Object { $_.Title -eq $PlanName } | Select-Object -First 1
if (-not $plan) { throw ('Planner plan "{0}" not found, or it is not visible to this identity.' -f $PlanName) }

$buckets = @(Get-MgPlannerPlanBucket -PlannerPlanId $plan.Id -ErrorAction Stop)
$bucket = if ($BucketName) { $buckets | Where-Object Name -eq $BucketName | Select-Object -First 1 }
          else { $buckets | Select-Object -First 1 }
if (-not $bucket) { throw ('Bucket "{0}" not found in plan "{1}".' -f $BucketName, $PlanName) }

$assigneeId = $null
if ($AssignTo) {
    $assigneeId = (Get-MgUser -UserId $AssignTo -Property Id -ErrorAction Stop).Id
}

$existing = @(Get-MgPlannerPlanTask -PlannerPlanId $plan.Id -ErrorAction SilentlyContinue)

foreach ($t in $TaskTitle) {
    if ($existing.Title -contains $t) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $t `
            -Message 'Skipped - a task with this title already exists in the plan (idempotent)'
        continue
    }
    $results.Add([PSCustomObject]@{
        Name       = ('{0} / {1}' -f $plan.Title, $t)
        Id         = $plan.Id
        PlanName   = $plan.Title
        PlanId     = $plan.Id
        BucketName = $bucket.Name
        BucketId   = $bucket.Id
        TaskTitle  = $t
        AssignTo   = $AssignTo
        AssigneeId = $assigneeId
        DueDate    = $DueDate
        Ticket     = $TicketReference
    })
}
""",
    act="""
$body = @{
    planId  = $item.PlanId
    bucketId= $item.BucketId
    title   = $item.TaskTitle
}
if ($item.DueDate) { $body.dueDateTime = $item.DueDate.ToString('o') }
if ($item.AssigneeId) {
    $body.assignments = @{ $item.AssigneeId = @{
        '@odata.type' = '#microsoft.graph.plannerAssignment'
        orderHint = ' !'
    } }
}

$task = New-MgPlannerTask -BodyParameter $body -ErrorAction Stop

if ($item.Ticket) {
    try {
        # The description lives on the task details, which needs its own call
        # and an If-Match ETag.
        $details = Get-MgPlannerTaskDetail -PlannerTaskId $task.Id -ErrorAction Stop
        Update-MgPlannerTaskDetail -PlannerTaskId $task.Id `
            -IfMatch $details.AdditionalProperties.'@odata.etag' `
            -Description ('Created from ticket {0} by {1}' -f $item.Ticket, $scriptName) -ErrorAction Stop | Out-Null
    } catch {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label `
            -Message ('Task created but description could not be set: {0}' -f $_.Exception.Message)
    }
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Task created in {0}/{1}, assigned to {2}' -f
    $item.PlanName, $item.BucketName, $(if ($item.AssignTo) { $item.AssignTo } else { 'nobody' }))
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'TaskCreated'; Detail = $item.BucketName; Succeeded = $true })
"""),

15: dict(
    file='Export-M365AuditLog',
    modules=['ExchangeOnlineManagement'],
    synopsis='Exports the Microsoft 365 unified audit log for SIEM ingestion.',
    desc='Retrieves unified audit log records for the lookback window and writes them in a form a '
         'SIEM can ingest. Paging is handled explicitly, because the search API returns a bounded '
         'page and a naive single call silently loses records.',
    params=[dict(name='LookbackHours', help='How far back to export.',
                 decl="[ValidateRange(1,720)]\n    [int]$LookbackHours = 24"),
            dict(name='RecordType', help='Limit to specific record types, e.g. AzureActiveDirectory, ExchangeAdmin.',
                 decl="[string[]]$RecordType"),
            dict(name='Operations', help='Limit to specific operations.',
                 decl="[string[]]$Operations"),
            dict(name='MaxRecords', help='Safety ceiling on records retrieved.',
                 decl="[ValidateRange(100,500000)]\n    [int]$MaxRecords = 50000"),
            dict(name='PageSize', help='Records per API call.',
                 decl="[ValidateRange(100,5000)]\n    [int]$PageSize = 5000")],
    perms='Exchange Online View-Only Audit Logs role, plus unified audit logging enabled on the tenant.',
    notes='The unified audit log has ingestion latency of up to 24 hours for some workloads, so a '
          'run covering the last hour will be incomplete. For SIEM feeds, overlap the windows and '
          'de-duplicate downstream on RecordId rather than assuming each run is complete.',
    examples=[("-LookbackHours 24 -OutputFormat JSON -OutputPath C:\\\\SIEM\\\\m365-audit.json",
               'Daily export as JSON for SIEM ingestion.'),
              ("-RecordType AzureActiveDirectory -LookbackHours 6",
               'Directory events only.')],
    discover="""
$exoParams = @{ ShowBanner = $false; ErrorAction = 'Stop' }
if ($config -and $config.azure) {
    if ($config.azure.applicationId)         { $exoParams.AppId = $config.azure.applicationId }
    if ($config.azure.certificateThumbprint) { $exoParams.CertificateThumbprint = $config.azure.certificateThumbprint }
    if ($config.azure.tenantId)              { $exoParams.Organization = $config.azure.tenantId }
}
if (-not $exoParams.AppId) { throw 'Exchange Online requires app-only certificate auth (see config.json).' }
Connect-ExchangeOnline @exoParams

$end = Get-Date
$start = $end.AddHours(-$LookbackHours)
$sessionId = 'AutoOpsAudit-{0}' -f (Get-Date -Format 'yyyyMMddHHmmss')

Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
    'Exporting audit records from {0:u} to {1:u}' -f $start, $end)

$total = 0
$more = $true

# ReturnLargeSet pages through results; the loop must continue until an empty
# page. A single call returns only the first page and silently loses the rest.
while ($more -and $total -lt $MaxRecords) {
    $searchParams = @{
        StartDate   = $start
        EndDate     = $end
        SessionId   = $sessionId
        SessionCommand = 'ReturnLargeSet'
        ResultSize  = $PageSize
        ErrorAction = 'Stop'
    }
    if ($RecordType) { $searchParams.RecordType = $RecordType }
    if ($Operations) { $searchParams.Operations = $Operations }

    $page = @(Search-UnifiedAuditLog @searchParams)
    if ($page.Count -eq 0) { $more = $false; break }

    foreach ($rec in $page) {
        $data = $null
        try { $data = $rec.AuditData | ConvertFrom-Json } catch {
            Write-Verbose ('Unparseable AuditData on record {0}' -f $rec.Identity)
        }

        $results.Add([PSCustomObject]@{
            Name         = $rec.Operations
            Id           = $rec.Identity
            RecordType   = "$($rec.RecordType)"
            CreationDate = $rec.CreationDate
            UserIds      = $rec.UserIds
            Operation    = $rec.Operations
            ResultStatus = if ($data) { $data.ResultStatus } else { $null }
            ClientIP     = if ($data) { $data.ClientIP } else { $null }
            Workload     = if ($data) { $data.Workload } else { $null }
            ObjectId     = if ($data) { $data.ObjectId } else { $null }
            AuditData    = $rec.AuditData
        })
        $total++
        if ($total -ge $MaxRecords) { break }
    }

    if ($page.Count -lt $PageSize) { $more = $false }
}

Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
    'Exported {0} audit record(s). Note: unified audit ingestion lags up to 24h for some workloads - ' +
    'overlap windows and de-duplicate on Id downstream.' -f $total)

if ($total -ge $MaxRecords) {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
        'Hit the -MaxRecords ceiling of {0}. The export is TRUNCATED - narrow the window or raise the limit.' -f $MaxRecords)
}
"""),

16: dict(
    file='Set-ExoAntiSpamPolicyBaseline',
    modules=['ExchangeOnlineManagement'],
    synopsis='Compares Exchange Online anti-spam policies against a baseline and applies approved changes.',
    desc='Reports each anti-spam policy setting that is weaker than a recommended baseline, and stops. '
         'How far to tighten a policy is a mail-flow decision with business impact, so the script makes '
         'no judgement of its own: it produces the deviation list, raises an approval artifact, and only '
         'applies a setting once a messaging admin has approved the reference and named the settings to '
         'apply.',
    params=[dict(name='BaselineFile', help='JSON file of baseline settings. The built-in baseline is used when omitted.',
                 decl="[string]$BaselineFile"),
            dict(name='PolicyName', help='Limit to specific policies.',
                 decl="[string[]]$PolicyName"),
            dict(name='ApplySetting', help='Restrict the change set to these setting names. All reported deviations when omitted.',
                 decl="[string[]]$ApplySetting")],
    perms='Exchange Online Hygiene Management role to apply changes; View-Only Configuration is enough to report.',
    actionVerb='Apply anti-spam baseline setting',
    reason='Anti-spam policy hardening',
    rollback='Each change logs the previous value before it is written. To revert, run '
             'Set-HostedContentFilterPolicy -Identity <policy> -<Setting> <previous value> using the '
             'CurrentValue recorded in the audit log and the approval artifact.',
    notes='Tightening spam policy affects legitimate mail as well as spam. Quarantining instead of '
          'moving to junk, for instance, means users stop seeing false positives at all - which is '
          'safer and generates more helpdesk contact. That trade-off is the judgement this script '
          'refuses to make on its own; it is what the approval gate exists to capture. -ApplySetting '
          'lets an admin approve the review and then apply only part of it.',
    examples=[("-OutputFormat HTML", 'REPORT ONLY. Compares every policy against the baseline and raises an approval.'),
              ("-ApprovalReference APR-... -ApplySetting PhishSpamAction,HighConfidencePhishAction",
               'Applies only the two phishing settings from an approved review.')],
    discover="""
$exoParams = @{ ShowBanner = $false; ErrorAction = 'Stop' }
if ($config -and $config.azure) {
    if ($config.azure.applicationId)         { $exoParams.AppId = $config.azure.applicationId }
    if ($config.azure.certificateThumbprint) { $exoParams.CertificateThumbprint = $config.azure.certificateThumbprint }
    if ($config.azure.tenantId)              { $exoParams.Organization = $config.azure.tenantId }
}
if (-not $exoParams.AppId) { throw 'Exchange Online requires app-only certificate auth (see config.json).' }
Connect-ExchangeOnline @exoParams

# Conservative defaults reflecting common Microsoft guidance. Deliberately a
# starting point for a conversation, not a target to be applied automatically.
$baseline = @{
    SpamAction                 = 'Quarantine'
    HighConfidenceSpamAction   = 'Quarantine'
    PhishSpamAction            = 'Quarantine'
    HighConfidencePhishAction  = 'Quarantine'
    BulkSpamAction             = 'MoveToJmf'
    BulkThreshold              = 6
    MarkAsSpamBulkMail         = 'On'
    IncreaseScoreWithNumericIps = 'On'
    IncreaseScoreWithRedirectToOtherPort = 'On'
    EnableLanguageBlockList    = $false
    QuarantineRetentionPeriod  = 30
}

if ($BaselineFile) {
    if (-not (Test-Path -LiteralPath $BaselineFile)) { throw ('Baseline file not found: {0}' -f $BaselineFile) }
    $custom = Get-Content -LiteralPath $BaselineFile -Raw | ConvertFrom-Json
    $baseline = @{}
    foreach ($p in $custom.PSObject.Properties) { $baseline[$p.Name] = $p.Value }
}

$policies = if ($PolicyName) { $PolicyName | ForEach-Object { Get-HostedContentFilterPolicy -Identity $_ -ErrorAction Stop } }
            else             { Get-HostedContentFilterPolicy -ErrorAction Stop }

$reported = 0

foreach ($pol in $policies) {
    foreach ($key in $baseline.Keys) {
        $actual = $pol.$key
        $expected = $baseline[$key]
        if ($null -eq $actual) { continue }
        if ("$actual" -eq "$expected") { continue }

        $reported++

        # Every deviation is reported. -ApplySetting narrows what may be
        # changed, so an admin can approve the whole review and act on part.
        if ($ApplySetting -and $ApplySetting -notcontains $key) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0}/{1}' -f $pol.Name, $key) `
                -Message 'Deviation reported but excluded from the change set by -ApplySetting'
            continue
        }

        $results.Add([PSCustomObject]@{
            Name        = ('{0} / {1}' -f $pol.Name, $key)
            Id          = "$($pol.Identity)"
            PolicyName  = $pol.Name
            PolicyId    = "$($pol.Identity)"
            IsDefault   = $pol.IsDefault
            Setting     = $key
            CurrentValue= "$actual"
            BaselineValue = "$expected"
            BaselineRaw = $expected
            Deviation   = ('{0} is "{1}", baseline suggests "{2}"' -f $key, $actual, $expected)
            AdminDecision = 'Whether to tighten this depends on mail-flow impact - messaging admin judgement'
        })
    }
}

Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
    'Policy comparison complete. {0} deviation(s) found, {1} in the change set.' -f $reported, $results.Count)
""",
    act="""
$setParams = @{ Identity = $item.PolicyId; ErrorAction = 'Stop' }
$setParams[$item.Setting] = $item.BaselineRaw
Set-HostedContentFilterPolicy @setParams

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Applied {0}: "{1}" -> "{2}". Previous value recorded here for rollback.' -f
    $item.Setting, $item.CurrentValue, $item.BaselineValue)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'BaselineApplied'
    Detail = ('{0}: {1} -> {2}' -f $item.Setting, $item.CurrentValue, $item.BaselineValue)
    Succeeded = $true })
"""),

17: dict(
    file='Get-M365DlpMatchReport',
    modules=['ExchangeOnlineManagement'],
    synopsis='Reports Data Loss Prevention policy matches.',
    desc='Summarises DLP rule matches over the reporting window by policy, rule and action, so a '
         'rule generating constant false positives is visible as a single line rather than a stream '
         'of individual incidents.',
    params=[dict(name='LookbackDays', help='Reporting window in days.',
                 decl="[ValidateRange(1,90)]\n    [int]$LookbackDays = 7"),
            dict(name='MinimumMatches', help='Ignore rules with fewer matches than this.',
                 decl="[ValidateRange(1,100000)]\n    [int]$MinimumMatches = 1")],
    perms='Exchange Online View-Only Recipients plus Security Reader in the compliance portal.',
    notes='The DLP report aggregates by policy and rule rather than listing individual incidents. '
          'For per-incident detail, use the Purview compliance portal - deliberately not exported '
          'here, since incident bodies frequently contain the sensitive data that triggered the match.',
    examples=[("-LookbackDays 7 -OutputFormat HTML", 'Weekly DLP report as HTML.'),
              ("-LookbackDays 30 -MinimumMatches 10", 'Monthly view of the noisiest rules.')],
    discover="""
$exoParams = @{ ShowBanner = $false; ErrorAction = 'Stop' }
if ($config -and $config.azure) {
    if ($config.azure.applicationId)         { $exoParams.AppId = $config.azure.applicationId }
    if ($config.azure.certificateThumbprint) { $exoParams.CertificateThumbprint = $config.azure.certificateThumbprint }
    if ($config.azure.tenantId)              { $exoParams.Organization = $config.azure.tenantId }
}
if (-not $exoParams.AppId) { throw 'Exchange Online requires app-only certificate auth (see config.json).' }
Connect-ExchangeOnline @exoParams

$end = Get-Date
$start = $end.AddDays(-$LookbackDays)

$report = @()
try {
    $report = @(Get-DlpDetailReport -StartDate $start -EndDate $end -ErrorAction Stop)
} catch {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
        'Get-DlpDetailReport unavailable ({0}). Falling back to the aggregate DLP report.' -f $_.Exception.Message)
    try { $report = @(Get-DlpDetectionsReport -StartDate $start -EndDate $end -ErrorAction Stop) } catch {
        throw ('No DLP reporting data available: {0}' -f $_.Exception.Message)
    }
}

$grouped = $report | Group-Object { $_.DlpPolicy }, { $_.TransportRule }

foreach ($g in $grouped) {
    $first = $g.Group[0]
    if ($g.Count -lt $MinimumMatches) { continue }

    $ruleActions = @($g.Group | ForEach-Object { $_.Actions } | Where-Object { $_ } | Select-Object -Unique)
    $workloads = @($g.Group | ForEach-Object { $_.Workload } | Where-Object { $_ } | Select-Object -Unique)

    $results.Add([PSCustomObject]@{
        Name         = ('{0} / {1}' -f $first.DlpPolicy, $first.TransportRule)
        Id           = $first.TransportRule
        PolicyName   = $first.DlpPolicy
        RuleName     = $first.TransportRule
        MatchCount   = $g.Count
        Actions      = ($ruleActions -join '; ')
        Workloads    = ($workloads -join '; ')
        Severity     = $first.Severity
        FirstSeen    = ($g.Group.Date | Sort-Object | Select-Object -First 1)
        LastSeen     = ($g.Group.Date | Sort-Object | Select-Object -Last 1)
        TuningNote   = if ($g.Count -gt 100) { 'High match volume - review for false positives before treating as incidents' }
                       else { '' }
    })
}

Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
    'DLP report: {0} rule(s) with matches over {1} day(s). Incident bodies are NOT exported.' -f
    $results.Count, $LookbackDays)
"""),

18: dict(
    file='Get-EntraRiskySignInReport',
    modules=['Microsoft.Graph.Authentication', 'Microsoft.Graph.Identity.SignIns'],
    synopsis='Reports Entra ID risky sign-ins and risk detections.',
    desc='Lists sign-ins Identity Protection classified as risky, with the risk level, detection '
         'type and whether the sign-in ultimately succeeded. A risky sign-in that SUCCEEDED is the '
         'finding that matters; a blocked one is the control working.',
    params=[dict(name='LookbackDays', help='Reporting window in days.',
                 decl="[ValidateRange(1,30)]\n    [int]$LookbackDays = 1"),
            dict(name='MinimumRiskLevel', help='Lowest risk level to include.',
                 decl="[ValidateSet('low','medium','high')]\n    [string]$MinimumRiskLevel = 'medium'"),
            dict(name='MaxRecords', help='Maximum sign-ins to retrieve.',
                 decl="[ValidateRange(10,10000)]\n    [int]$MaxRecords = 1000")],
    perms='Microsoft Graph IdentityRiskEvent.Read.All and AuditLog.Read.All. Requires Entra ID P2 for full risk detail.',
    notes='Risk-based reporting requires Entra ID P2. With P1 the risk level appears but the '
          'detection detail does not, and with neither the endpoints return nothing - which the '
          'script reports as missing licensing rather than as a clean result.',
    examples=[("-LookbackDays 1 -MinimumRiskLevel medium", 'Daily risky sign-in report.'),
              ("-LookbackDays 7 -MinimumRiskLevel high -OutputFormat HTML", 'Weekly high-risk report.')],
    discover=graph("AuditLog.Read.All','IdentityRiskEvent.Read.All','Directory.Read.All") + """
$since = (Get-Date).AddDays(-$LookbackDays).ToString('yyyy-MM-ddTHH:mm:ssZ')

$levels = switch ($MinimumRiskLevel) {
    'low'    { @('low','medium','high') }
    'medium' { @('medium','high') }
    'high'   { @('high') }
}
$levelFilter = ($levels | ForEach-Object { "riskLevelDuringSignIn eq '$_'" }) -join ' or '
$filter = "createdDateTime ge $since and ($levelFilter)"

$signIns = @()
try {
    $signIns = @(Get-MgAuditLogSignIn -Filter $filter -Top $MaxRecords -ErrorAction Stop)
} catch {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
        'Risky sign-in data unavailable: {0}. This usually means the tenant lacks Entra ID P2.' -f $_.Exception.Message)
    return
}

if ($signIns.Count -eq 0) {
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'No risky sign-ins at level {0} or above in the last {1} day(s).' -f $MinimumRiskLevel, $LookbackDays)
}

foreach ($s in $signIns) {
    $succeeded = ($s.Status.ErrorCode -eq 0)

    $results.Add([PSCustomObject]@{
        Name            = $s.UserPrincipalName
        Id              = $s.Id
        UserDisplayName = $s.UserDisplayName
        SignInTime      = $s.CreatedDateTime
        AppDisplayName  = $s.AppDisplayName
        IpAddress       = $s.IPAddress
        City            = $s.Location.City
        Country         = $s.Location.CountryOrRegion
        DeviceOs        = $s.DeviceDetail.OperatingSystem
        DeviceBrowser   = $s.DeviceDetail.Browser
        RiskLevel       = "$($s.RiskLevelDuringSignIn)"
        RiskState       = "$($s.RiskState)"
        RiskDetail      = "$($s.RiskDetail)"
        RiskEventTypes  = ($s.RiskEventTypesV2 -join '; ')
        ConditionalAccessStatus = "$($s.ConditionalAccessStatus)"
        Succeeded       = $succeeded
        ErrorCode       = $s.Status.ErrorCode
        FailureReason   = $s.Status.FailureReason
        Status          = if ($succeeded) { 'RISKY SIGN-IN SUCCEEDED' } else { 'Blocked' }
    })

    if ($succeeded) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $s.UserPrincipalName -Message (
            'Risky sign-in SUCCEEDED: {0} risk from {1} ({2}) at {3:u}' -f
            $s.RiskLevelDuringSignIn, $s.IPAddress, $s.Location.CountryOrRegion, $s.CreatedDateTime)
    }
}
"""),

19: dict(
    file='Get-M365EmailThreatReport',
    modules=['ExchangeOnlineManagement'],
    synopsis='Reports Defender for Office 365 email threat detections.',
    desc='Summarises phishing and malware detections over the reporting window by threat type and '
         'delivery outcome. Messages DELIVERED despite detection are separated from those blocked, '
         'since a delivered threat needs a response and a blocked one is a statistic.',
    params=[dict(name='LookbackDays', help='Reporting window in days.',
                 decl="[ValidateRange(1,30)]\n    [int]$LookbackDays = 7"),
            dict(name='ThreatType', help='Limit to specific threat classifications.',
                 decl="[string[]]$ThreatType")],
    perms='Exchange Online Security Reader plus View-Only Audit Logs.',
    notes='Defender detail reports cover the last 30 days at most, and the current day is always '
          'partial. For older data use the Defender portal export.',
    examples=[("-LookbackDays 7 -OutputFormat HTML", 'Weekly threat report as HTML.'),
              ("-LookbackDays 1", 'Daily summary.')],
    discover="""
$exoParams = @{ ShowBanner = $false; ErrorAction = 'Stop' }
if ($config -and $config.azure) {
    if ($config.azure.applicationId)         { $exoParams.AppId = $config.azure.applicationId }
    if ($config.azure.certificateThumbprint) { $exoParams.CertificateThumbprint = $config.azure.certificateThumbprint }
    if ($config.azure.tenantId)              { $exoParams.Organization = $config.azure.tenantId }
}
if (-not $exoParams.AppId) { throw 'Exchange Online requires app-only certificate auth (see config.json).' }
Connect-ExchangeOnline @exoParams

$end = Get-Date
$start = $end.AddDays(-$LookbackDays)

$detections = @()
try {
    $detections = @(Get-MailDetailATPReport -StartDate $start -EndDate $end -ErrorAction Stop)
} catch {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
        'Get-MailDetailATPReport unavailable ({0}). Falling back to the mail traffic ATP report.' -f $_.Exception.Message)
    try { $detections = @(Get-MailTrafficATPReport -StartDate $start -EndDate $end -ErrorAction Stop) } catch {
        throw ('No Defender reporting data available: {0}' -f $_.Exception.Message)
    }
}

$grouped = $detections | Group-Object { $_.EventType }, { $_.Action }

foreach ($g in $grouped) {
    $first = $g.Group[0]
    if ($ThreatType -and $ThreatType -notcontains "$($first.EventType)") { continue }

    # "Delivered" outcomes are the ones that need a response.
    $delivered = "$($first.Action)" -match '(?i)deliver|junk|allow'

    $results.Add([PSCustomObject]@{
        Name         = ('{0} / {1}' -f $first.EventType, $first.Action)
        Id           = ('{0}-{1}' -f $first.EventType, $first.Action)
        ThreatType   = "$($first.EventType)"
        Action       = "$($first.Action)"
        MessageCount = $g.Count
        Delivered    = $delivered
        Direction    = "$($first.Direction)"
        TopSenders   = (($g.Group.SenderAddress | Group-Object | Sort-Object Count -Descending |
                         Select-Object -First 5 | ForEach-Object { '{0}({1})' -f $_.Name, $_.Count }) -join '; ')
        TopRecipients= (($g.Group.RecipientAddress | Group-Object | Sort-Object Count -Descending |
                         Select-Object -First 5 | ForEach-Object { '{0}({1})' -f $_.Name, $_.Count }) -join '; ')
        FirstSeen    = ($g.Group.Date | Sort-Object | Select-Object -First 1)
        LastSeen     = ($g.Group.Date | Sort-Object | Select-Object -Last 1)
        Status       = if ($delivered) { 'DELIVERED - needs response' } else { 'Blocked' }
    })

    if ($delivered) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $first.EventType -Message (
            '{0} message(s) classified {1} were {2} - these reached mailboxes' -f
            $g.Count, $first.EventType, $first.Action)
    }
}
"""),

20: dict(
    file='Get-M365RetentionCompliance',
    modules=['ExchangeOnlineManagement'],
    synopsis='Verifies retention policies and labels are applied where expected.',
    desc='Reports configured retention policies and label policies with their scope and enforcement '
         'state, flagging policies that are disabled, in simulation, or scoped to nothing - all of '
         'which look configured while retaining nothing.',
    params=[dict(name='PolicyName', help='Limit to specific policies.',
                 decl="[string[]]$PolicyName"),
            dict(name='IncludeLabels', help='Include retention label detail as well as policies.',
                 decl="[switch]$IncludeLabels")],
    perms='Security & Compliance View-Only Retention Management role.',
    notes='Connects to Security & Compliance PowerShell, which is a different endpoint from Exchange '
          'Online. Certificate-based app-only auth is supported there but the connection is separate, '
          'so a working EXO connection does not imply this one.',
    examples=[("-OutputFormat HTML", 'Retention compliance report as HTML.'),
              ("-IncludeLabels -OutputFormat JSON", 'Policies and labels as JSON.')],
    discover="""
$sccParams = @{ ShowBanner = $false; ErrorAction = 'Stop' }
if ($config -and $config.azure) {
    if ($config.azure.applicationId)         { $sccParams.AppId = $config.azure.applicationId }
    if ($config.azure.certificateThumbprint) { $sccParams.CertificateThumbprint = $config.azure.certificateThumbprint }
    if ($config.azure.tenantId)              { $sccParams.Organization = $config.azure.tenantId }
}
if (-not $sccParams.AppId) { throw 'Security & Compliance PowerShell requires app-only certificate auth (see config.json).' }

Connect-IPPSSession @sccParams
Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Security & Compliance PowerShell'

$policies = if ($PolicyName) { $PolicyName | ForEach-Object { Get-RetentionCompliancePolicy -Identity $_ -ErrorAction Stop } }
            else             { Get-RetentionCompliancePolicy -ErrorAction Stop }

foreach ($pol in $policies) {
    $issues = @()
    if (-not $pol.Enabled)      { $issues += 'policy is DISABLED - retaining nothing' }
    if ($pol.Mode -ne 'Enforce'){ $issues += ('mode is {0}, not Enforce' -f $pol.Mode) }

    $scopeCount = @($pol.ExchangeLocation).Count + @($pol.SharePointLocation).Count +
                  @($pol.OneDriveLocation).Count + @($pol.TeamsChannelLocation).Count +
                  @($pol.ModernGroupLocation).Count
    if ($scopeCount -eq 0) { $issues += 'no locations in scope - applies to nothing' }

    $rules = @()
    try { $rules = @(Get-RetentionComplianceRule -Policy $pol.Name -ErrorAction Stop) } catch {
        Write-Verbose ('Could not read rules for {0}' -f $pol.Name)
    }
    if ($rules.Count -eq 0) { $issues += 'no rules attached - nothing defines the retention period' }

    $results.Add([PSCustomObject]@{
        Name            = $pol.Name
        Id              = $pol.Guid
        RecordType      = 'Policy'
        Enabled         = $pol.Enabled
        Mode            = "$($pol.Mode)"
        ExchangeScope   = (@($pol.ExchangeLocation) -join '; ')
        SharePointScope = (@($pol.SharePointLocation) -join '; ')
        OneDriveScope   = (@($pol.OneDriveLocation) -join '; ')
        TeamsScope      = (@($pol.TeamsChannelLocation) -join '; ')
        ScopeCount      = $scopeCount
        RuleCount       = $rules.Count
        RetentionAction = (($rules | ForEach-Object { '{0}:{1}d' -f $_.RetentionComplianceAction, $_.RetentionDuration }) -join '; ')
        RetentionDuration = $null
        IsRecordLabel   = $null
        Regulatory      = $null
        Status          = if ($issues.Count) { 'NonCompliant' } else { 'Compliant' }
        Issues          = ($issues -join '; ')
    })
    if ($issues.Count) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $pol.Name -Message ($issues -join '; ')
    }
}

if ($IncludeLabels) {
    foreach ($lbl in (Get-ComplianceTag -ErrorAction SilentlyContinue)) {
        $results.Add([PSCustomObject]@{
            Name            = $lbl.Name
            Id              = $lbl.Guid
            RecordType      = 'Label'
            Enabled         = $true
            Mode            = ''
            ExchangeScope   = ''
            SharePointScope = ''
            OneDriveScope   = ''
            TeamsScope      = ''
            ScopeCount      = $null
            RuleCount       = $null
            RetentionAction = "$($lbl.RetentionAction)"
            RetentionDuration = $lbl.RetentionDuration
            IsRecordLabel   = $lbl.IsRecordLabel
            Regulatory      = $lbl.Regulatory
            Status          = 'Info'
            Issues          = ''
        })
    }
}
"""),

21: dict(
    file='Get-VivaInsightsUsageReport',
    modules=['Microsoft.Graph.Authentication', 'Microsoft.Graph.Reports'],
    synopsis='Reports Microsoft 365 service usage trends.',
    desc='Aggregates per-service activity from the Microsoft 365 usage reports - Exchange, Teams, '
         'SharePoint, OneDrive - giving adoption and utilisation figures at tenant level.',
    params=[dict(name='Period', help='Reporting period.',
                 decl="[ValidateSet('D7','D30','D90','D180')]\n    [string]$Period = 'D30'"),
            dict(name='Service', help='Services to include.',
                 decl="[ValidateSet('Exchange','Teams','SharePoint','OneDrive','All')]\n    [string[]]$Service = @('All')")],
    perms='Microsoft Graph Reports.Read.All.',
    notes='Tenant usage reports may be pseudonymised: if "Display concealed user information" is on '
          'in the M365 admin centre, user names are replaced with opaque identifiers. That is a '
          'privacy setting, not a fault, and this script reports the data as returned.',
    examples=[("-Period D30 -OutputFormat HTML", 'Monthly usage trends as HTML.'),
              ("-Service Teams -Period D7", 'Weekly Teams usage only.')],
    discover=graph("Reports.Read.All") + """
$wanted = if ($Service -contains 'All') { @('Exchange','Teams','SharePoint','OneDrive') } else { $Service }

$endpoints = @{
    Exchange   = "getEmailActivityUserDetail(period='{0}')"
    Teams      = "getTeamsUserActivityUserDetail(period='{0}')"
    SharePoint = "getSharePointActivityUserDetail(period='{0}')"
    OneDrive   = "getOneDriveActivityUserDetail(period='{0}')"
}

foreach ($svc in $wanted) {
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        $uri = 'https://graph.microsoft.com/v1.0/reports/' + ($endpoints[$svc] -f $Period)
        Invoke-MgGraphRequest -Method GET -Uri $uri -OutputFilePath $tmp -ErrorAction Stop
        $rows = @(Import-Csv -LiteralPath $tmp)
    } catch {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $svc `
            -Message ('Usage report unavailable: {0}' -f $_.Exception.Message)
        continue
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }

    # The "Last Activity Date" column is present across all four reports and is
    # the most reliable signal of whether an account actually uses the service.
    $active = @($rows | Where-Object { $_.'Last Activity Date' })
    $inactive = @($rows | Where-Object { -not $_.'Last Activity Date' })

    $results.Add([PSCustomObject]@{
        Name            = $svc
        Id              = $svc
        Period          = $Period
        TotalAccounts   = $rows.Count
        ActiveAccounts  = $active.Count
        InactiveAccounts= $inactive.Count
        AdoptionPercent = if ($rows.Count -gt 0) { [math]::Round(($active.Count / $rows.Count) * 100, 1) } else { $null }
        Concealed       = [bool]($rows | Where-Object { $_.'User Principal Name' -match '^[A-F0-9]{32,}$' } | Select-Object -First 1)
        ReportDate      = ($rows | Select-Object -First 1).'Report Refresh Date'
    })

    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $svc -Message (
        '{0} of {1} account(s) active over {2}' -f $active.Count, $rows.Count, $Period)
}
"""),

22: dict(
    file='Get-PowerPlatformConnectorAudit',
    modules=['Microsoft.Graph.Authentication'],
    synopsis='Audits Power Platform connectors used in flows and apps.',
    desc='Reports which connectors are in use across environments and flags those outside the '
         'approved list. Non-standard connectors are how corporate data leaves the tenant through '
         'a flow nobody reviewed, which is what makes this an audit rather than an inventory.',
    params=[dict(name='ApprovedConnector', help='Connectors considered standard. Anything else is flagged.',
                 decl="[string[]]$ApprovedConnector = @('shared_sharepointonline','shared_office365','shared_office365users','shared_teams','shared_excelonlinebusiness','shared_onedriveforbusiness','shared_approvals','shared_flowpush')"),
            dict(name='EnvironmentName', help='Limit to specific Power Platform environments.',
                 decl="[string[]]$EnvironmentName")],
    perms='Power Platform administrator. Uses the Power Platform admin REST API through the Graph token.',
    notes='Requires the Power Platform admin API, which is a separate endpoint from Graph and needs '
          'a Power Platform administrator role. The Microsoft.PowerApps.Administration.PowerShell '
          'module is the supported alternative and may be simpler in an environment where that role '
          'is already delegated.',
    examples=[("-OutputFormat HTML", 'Connector audit across all environments.'),
              ("-ApprovedConnector shared_sharepointonline,shared_teams", 'Audits against a tighter allow-list.')],
    discover="""
Connect-MgGraph -Scopes 'https://service.powerapps.com/.default' -NoWelcome -ErrorAction Stop
Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected for Power Platform admin API access'

$apiBase = 'https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform'

$environments = @()
try {
    $envResp = Invoke-MgGraphRequest -Method GET `
        -Uri ('{0}/scopes/admin/environments?api-version=2020-10-01' -f $apiBase) -ErrorAction Stop
    $environments = @($envResp.value)
} catch {
    throw ('Power Platform admin API unavailable: {0}. This needs a Power Platform administrator role, ' +
           'or use the Microsoft.PowerApps.Administration.PowerShell module instead.' -f $_.Exception.Message)
}

foreach ($ppEnv in $environments) {
    $envDisplay = $ppEnv.properties.displayName
    if ($EnvironmentName -and $EnvironmentName -notcontains $envDisplay) { continue }

    $flows = @()
    try {
        $flowResp = Invoke-MgGraphRequest -Method GET `
            -Uri ('{0}/scopes/admin/environments/{1}/v2/flows?api-version=2016-11-01' -f $apiBase, $ppEnv.name) `
            -ErrorAction Stop
        $flows = @($flowResp.value)
    } catch {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $envDisplay `
            -Message ('Could not enumerate flows: {0}' -f $_.Exception.Message)
        continue
    }

    foreach ($flow in $flows) {
        $connectors = @()
        foreach ($ref in $flow.properties.connectionReferences.PSObject.Properties) {
            $connectors += $ref.Value.id -replace '^.*/apis/', ''
        }
        $connectors = @($connectors | Select-Object -Unique)
        $nonStandard = @($connectors | Where-Object { $ApprovedConnector -notcontains $_ })

        if ($nonStandard.Count -eq 0) { continue }

        $results.Add([PSCustomObject]@{
            Name          = ('{0} / {1}' -f $envDisplay, $flow.properties.displayName)
            Id            = $flow.name
            Environment   = $envDisplay
            FlowName      = $flow.properties.displayName
            FlowState     = $flow.properties.state
            Owner         = $flow.properties.creator.userId
            CreatedAt     = $flow.properties.createdTime
            AllConnectors = ($connectors -join '; ')
            NonStandardConnectors = ($nonStandard -join '; ')
            NonStandardCount = $nonStandard.Count
            Risk          = 'Non-approved connector may move corporate data outside reviewed channels'
        })
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $flow.properties.displayName `
            -Message ('Non-standard connector(s): {0}' -f ($nonStandard -join ', '))
    }
}
"""),
}
