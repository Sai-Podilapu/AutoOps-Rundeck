# -*- coding: utf-8 -*-
"""Backup Commvault - use cases 1-9.

Commvault has no first-party PowerShell module, so every script here talks to
the v11 REST API through Invoke-RestMethod. The session prologue below is
shared by all nine and is the only place a credential is ever handled.
"""

# Common connection parameters, repeated on every script in this category.
CONN_PARAMS = [
    dict(name='WebServiceUrl',
         help='Commvault Web Service URL, e.g. https://commserve.contoso.com/webconsole/api. '
              'Falls back to commvault.webServiceUrl in config.json.',
         decl="[string]$WebServiceUrl"),
    dict(name='Credential',
         help='CommCell credential used to obtain a REST token. Prompted for if neither this nor '
              '-AccessToken is supplied. A password is never read from configuration.',
         decl="[System.Management.Automation.PSCredential]\n    [System.Management.Automation.Credential()]\n    $Credential = [System.Management.Automation.PSCredential]::Empty"),
    dict(name='AccessToken',
         help='An existing Commvault Authtoken as a SecureString. Preferred over -Credential: no '
              'login round-trip and no password is handled at all.',
         decl="[System.Security.SecureString]$AccessToken"),
]

# ---------------------------------------------------------------------------
# Session prologue. Prepended to every discover block.
#
# The password->base64 conversion Commvault's /Login requires means the secret
# exists as a managed string for the duration of one call. That is unavoidable
# for this API; the BSTR is zeroed immediately and -AccessToken avoids it
# entirely, which is why -AccessToken is documented as preferred.
# ---------------------------------------------------------------------------
CONNECT = r"""
function Invoke-CvApi {
    <#
        .SYNOPSIS
            Issues one authenticated call against the Commvault REST API.
        .DESCRIPTION
            Resolves the path against the web service base URL and attaches the
            session Authtoken. Defined inside the script rather than the shared
            module because it depends on this run's session state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [ValidateSet('GET', 'POST', 'PUT', 'DELETE')]
        [string]$Method = 'GET',

        $Body
    )

    $uri = '{0}/{1}' -f $cvBase, $Path.TrimStart('/')
    $callParams = @{
        Uri         = $uri
        Method      = $Method
        Headers     = $cvHeaders
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $callParams.Body = ($Body | ConvertTo-Json -Depth 12 -Compress)
    }
    Invoke-RestMethod @callParams
}

if (-not $WebServiceUrl) {
    if ($config -and $config.commvault -and $config.commvault.webServiceUrl) {
        $WebServiceUrl = $config.commvault.webServiceUrl
    }
}
if (-not $WebServiceUrl) {
    throw 'No Commvault web service URL. Pass -WebServiceUrl or set commvault.webServiceUrl in config.json.'
}
$cvBase = $WebServiceUrl.TrimEnd('/')

# PowerShell 5.1 still negotiates TLS 1.0 by default against some endpoints.
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

$cvHeaders = @{ 'Accept' = 'application/json'; 'Content-Type' = 'application/json' }
$cvLoggedIn = $false

if ($AccessToken) {
    $tokenPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AccessToken)
    try {
        $cvHeaders['Authtoken'] = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($tokenPtr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenPtr)
    }
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Using the supplied access token; no login performed.'
} else {
    if ($Credential -eq [System.Management.Automation.PSCredential]::Empty) {
        $Credential = Get-Credential -Message 'CommCell credentials for the Commvault REST API'
    }

    # /Login wants the password base64-encoded, so it must be a plain string
    # for exactly as long as the request body is built. The BSTR is zeroed in
    # the finally block whether or not the call succeeds.
    $pwdPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
    try {
        $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($pwdPtr)
        $encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($plainPassword))
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pwdPtr)
        Remove-Variable -Name plainPassword -ErrorAction SilentlyContinue
    }

    $loginResponse = Invoke-RestMethod -Uri ('{0}/Login' -f $cvBase) -Method POST -Headers $cvHeaders `
        -Body (@{ username = $Credential.UserName; password = $encoded } | ConvertTo-Json -Compress) `
        -ErrorAction Stop
    Remove-Variable -Name encoded -ErrorAction SilentlyContinue

    if (-not $loginResponse.token) {
        throw ('Commvault login failed for {0}: no token returned.' -f $Credential.UserName)
    }
    $cvHeaders['Authtoken'] = $loginResponse.token
    $cvLoggedIn = $true
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message (
        'Authenticated to Commvault as {0}' -f $Credential.UserName)
}
"""

# Emitted on every exit path by the engine's cleanup hook.
CLEANUP = r"""
if ($cvLoggedIn) {
    try {
        Invoke-CvApi -Path 'Logout' -Method POST | Out-Null
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Commvault session closed.'
    } catch {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
            'Logout failed ({0}). The token expires on its own.' -f $_.Exception.Message)
    }
}
"""

# Job status codes Commvault reports, grouped the way an operator thinks.
JOB_STATE = r"""
function Get-CvJobState {
    <#
        .SYNOPSIS
            Buckets a Commvault job status string into Active / Failed / Completed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Status)

    switch -Regex ($Status) {
        '(?i)running|waiting|pending|queued|suspend'          { 'Active';    break }
        '(?i)fail|kill|error'                                 { 'Failed';    break }
        '(?i)completed w/ one or more errors|complete.*error' { 'Warning';   break }
        '(?i)complete|success'                                { 'Completed'; break }
        default                                               { 'Unknown' }
    }
}
"""


def cv(body, jobstate=False):
    """Session prologue + optional job-state helper + the use case's own work."""
    return CONNECT + (JOB_STATE if jobstate else '') + body


SPECS = {

1: dict(
    file='Get-CvBackupJobStatus',
    modules=[],
    synopsis='Reports the status of Commvault backup jobs.',
    desc='Queries the CommCell for backup jobs over a lookback window and reports each one with its '
         'outcome, duration and failure reason. A specific job id can be queried directly.',
    params=CONN_PARAMS + [
        dict(name='JobId', help='Report these job ids specifically instead of a time window.',
             decl="[int[]]$JobId"),
        dict(name='LookbackHours', help='How far back to look when -JobId is not supplied.',
             decl="[ValidateRange(1,720)]\n    [int]$LookbackHours = 24"),
        dict(name='ClientName', help='Limit to jobs for these clients.',
             decl="[string[]]$ClientName"),
        dict(name='FailedOnly', help='Report only jobs that failed or were killed.',
             decl="[switch]$FailedOnly")],
    perms='A CommCell user with View permission on the clients being reported.',
    notes='Job failure reasons come back on the job summary as a delay reason code plus text. Where '
          'Commvault returns no reason the field is left empty rather than filled with a guess.',
    examples=[("-LookbackHours 24 -OutputFormat HTML", 'Last 24 hours of backup jobs as HTML.'),
              ("-JobId 123456,123457", 'Status of two specific jobs.'),
              ("-FailedOnly -LookbackHours 48", 'Only the failures over two days.')],
    cleanup=CLEANUP,
    discover=cv(r"""
$jobs = @()

if ($JobId) {
    foreach ($id in $JobId) {
        try {
            $resp = Invoke-CvApi -Path ('Job/{0}' -f $id)
            if ($resp.jobs) { $jobs += $resp.jobs }
        } catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $id `
                -Message ('Job could not be read: {0}' -f $_.Exception.Message)
        }
    }
} else {
    $lookbackSeconds = $LookbackHours * 3600
    $resp = Invoke-CvApi -Path ('Job?completedJobLookupTime={0}' -f $lookbackSeconds)
    if ($resp.jobs) { $jobs = @($resp.jobs) }
}

foreach ($j in $jobs) {
    $s = $j.jobSummary
    if (-not $s) { continue }

    $client = $s.destinationClient.clientName
    if (-not $client) { $client = $s.subclient.clientName }
    if ($ClientName -and $ClientName -notcontains $client) { continue }

    $state = Get-CvJobState -Status $s.status
    if ($FailedOnly -and $state -ne 'Failed') { continue }

    # Commvault returns epoch seconds. 0 means "not set", not 1970.
    $start = if ($s.jobStartTime -gt 0) { [System.DateTimeOffset]::FromUnixTimeSeconds($s.jobStartTime).LocalDateTime } else { $null }
    $endTime = if ($s.jobEndTime -gt 0) { [System.DateTimeOffset]::FromUnixTimeSeconds($s.jobEndTime).LocalDateTime } else { $null }

    $results.Add([PSCustomObject]@{
        Name          = ('{0} / job {1}' -f $client, $s.jobId)
        Id            = $s.jobId
        ClientName    = $client
        SubclientName = $s.subclient.subclientName
        BackupSet     = $s.subclient.backupsetName
        Operation     = $s.jobType
        BackupLevel   = $s.backupLevelName
        Status        = $s.status
        State         = $state
        PercentDone   = $s.percentComplete
        StartedAt     = $start
        EndedAt       = $endTime
        DurationMin   = if ($start -and $endTime) { [math]::Round(($endTime - $start).TotalMinutes, 1) } else { $null }
        SizeGB        = if ($s.sizeOfApplication) { [math]::Round($s.sizeOfApplication / 1GB, 2) } else { $null }
        FailedFiles   = $s.totalFailedFiles
        FailureReason = $s.pendingReason
        StoragePolicy = $s.storagePolicy.storagePolicyName
    })

    if ($state -eq 'Failed') {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target ('job {0}' -f $s.jobId) -Message (
            '{0} on {1}: {2}' -f $s.status, $client, $s.pendingReason)
    }
}
""", jobstate=True)),

2: dict(
    file='Start-CvBackupJob',
    modules=[],
    synopsis='Triggers a Commvault backup on demand.',
    desc='Starts a backup at the requested level for one or more subclients and reports the job ids '
         'raised. Additive and safe to trigger on demand, which is what the workbook guardrail says.',
    params=CONN_PARAMS + [
        dict(name='ClientName', help='Client(s) whose subclients should be backed up.',
             decl="[Parameter(Mandatory)]\n    [string[]]$ClientName"),
        dict(name='SubclientName', help='Limit to these subclients. All subclients on the client when omitted.',
             decl="[string[]]$SubclientName"),
        dict(name='BackupLevel', help='Backup level to request.',
             decl="[ValidateSet('Full','Incremental','Differential','Synthetic_Full')]\n    [string]$BackupLevel = 'Incremental'"),
        dict(name='AllowConcurrent',
             help='Submit even when a job is already running for the subclient. Off by default: a '
                  'second concurrent job usually queues behind the first and confuses the schedule.',
             decl="[switch]$AllowConcurrent")],
    perms='A CommCell user with Backup permission on the target subclients.',
    actionVerb='Start backup',
    rollback='A running backup can be killed from the CommCell console or by job id. A completed '
             'backup creates an extra restore point and needs no rollback.',
    notes='Requesting Full where the schedule expects Incremental changes the storage consumed and '
          'the next synthetic-full chain. The level is therefore explicit rather than defaulted to '
          'Full, and the job id of every submission is logged so it can be tracked or killed.',
    examples=[("-ClientName SQLPROD01 -BackupLevel Full",
               'Full backup of every subclient on one client.'),
              ("-ClientName FILESRV01 -SubclientName 'default' -BackupLevel Incremental -WhatIf",
               'Shows what would be submitted without submitting it.')],
    cleanup=CLEANUP,
    discover=cv(r"""
$running = @{}
try {
    $active = Invoke-CvApi -Path 'Job?jobCategory=Active'
    foreach ($a in @($active.jobs)) {
        $key = '{0}|{1}' -f $a.jobSummary.subclient.clientName, $a.jobSummary.subclient.subclientName
        $running[$key] = $a.jobSummary.jobId
    }
} catch {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
        'Could not read active jobs ({0}); the concurrent-job check cannot be applied this run.' -f $_.Exception.Message)
}

foreach ($cName in $ClientName) {
    $subs = @()
    try {
        $resp = Invoke-CvApi -Path ('Subclient?clientName={0}' -f [uri]::EscapeDataString($cName))
        $subs = @($resp.subClientProperties)
    } catch {
        throw ('Could not enumerate subclients for {0}: {1}' -f $cName, $_.Exception.Message)
    }
    if ($subs.Count -eq 0) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $cName -Message 'No subclients returned.'
        continue
    }

    foreach ($sc in $subs) {
        $e = $sc.subClientEntity
        if ($SubclientName -and $SubclientName -notcontains $e.subclientName) { continue }

        $key = '{0}|{1}' -f $e.clientName, $e.subclientName
        if (-not $AllowConcurrent -and $running.ContainsKey($key)) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $key -Message (
                'Skipped - job {0} is already running for this subclient' -f $running[$key])
            continue
        }

        $results.Add([PSCustomObject]@{
            Name          = ('{0} / {1}' -f $e.clientName, $e.subclientName)
            Id            = $e.subclientId
            ClientName    = $e.clientName
            SubclientName = $e.subclientName
            BackupSet     = $e.backupsetName
            AgentType     = $e.appName
            SubclientId   = $e.subclientId
            BackupLevel   = $BackupLevel
            StoragePolicy = $sc.commonProperties.storageDevice.dataBackupStoragePolicy.storagePolicyName
        })
    }
}
"""),
    act=r"""
$resp = Invoke-CvApi -Method POST -Path (
    'Subclient/{0}/action/backup?backupLevel={1}' -f $item.SubclientId, $item.BackupLevel)

$newJobId = $resp.jobIds
if (-not $newJobId) { $newJobId = $resp.jobId }
if (-not $newJobId) {
    throw 'Backup request was accepted but Commvault returned no job id.'
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    '{0} backup submitted as job {1}' -f $item.BackupLevel, ($newJobId -join ','))
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'BackupStarted'
    Detail = ('{0}, job {1}' -f $item.BackupLevel, ($newJobId -join ',')); Succeeded = $true })
"""),

3: dict(
    file='Restart-CvFailedJob',
    modules=[],
    synopsis='Resubmits failed Commvault backup jobs, within the backup window.',
    desc='Finds jobs that failed or were killed over a lookback window and resubmits them. The '
         'workbook calls this a safe retry but requires it to be window-aware, so a resubmission '
         'outside the configured backup window is refused rather than queued.',
    params=CONN_PARAMS + [
        dict(name='LookbackHours', help='How far back to look for failures.',
             decl="[ValidateRange(1,168)]\n    [int]$LookbackHours = 12"),
        dict(name='ClientName', help='Limit to these clients.',
             decl="[string[]]$ClientName"),
        dict(name='MaxJobs', help='Ceiling on how many jobs may be resubmitted in one run.',
             decl="[ValidateRange(1,500)]\n    [int]$MaxJobs = 25"),
        dict(name='WindowStartHour', help='First hour of the backup window, 24h local time.',
             decl="[ValidateRange(0,23)]\n    [int]$WindowStartHour = 22"),
        dict(name='WindowEndHour', help='Last hour of the backup window, 24h local time.',
             decl="[ValidateRange(0,23)]\n    [int]$WindowEndHour = 5"),
        dict(name='IgnoreWindow', help='Resubmit outside the backup window. Use only for a ticket-driven catch-up.',
             decl="[switch]$IgnoreWindow"),
        dict(name='ExcludeReasonPattern',
             help='Do not resubmit a job whose failure reason matches these patterns - a retry will '
                  'not fix them.',
             decl="[string[]]$ExcludeReasonPattern = @('*license*','*credential*','*access denied*','*no such file*')")],
    perms='A CommCell user with Backup permission on the affected subclients.',
    actionVerb='Resubmit failed job',
    rollback='A resubmitted job can be killed by its new job id. The original failed job is not '
             'modified.',
    notes='Resubmitting a job that failed for a structural reason - expired licence, bad credential, '
          'a path that no longer exists - burns a backup window and fails identically. Those reasons '
          'are excluded by default via -ExcludeReasonPattern rather than retried blindly.',
    examples=[("-LookbackHours 12", 'Resubmit failures from the last 12 hours, if inside the window.'),
              ("-LookbackHours 24 -IgnoreWindow -WhatIf",
               'Shows what a ticket-driven catch-up would resubmit.')],
    cleanup=CLEANUP,
    discover=cv(r"""
$now = Get-Date
$hour = $now.Hour

# A window that wraps midnight (22:00-05:00) is not a simple range test.
$inWindow = if ($WindowStartHour -le $WindowEndHour) {
    $hour -ge $WindowStartHour -and $hour -le $WindowEndHour
} else {
    $hour -ge $WindowStartHour -or $hour -le $WindowEndHour
}

if (-not $inWindow -and -not $IgnoreWindow) {
    throw ('Outside the backup window ({0:00}:00-{1:00}:00, now {2:HH:mm}). Refusing to resubmit. ' +
           'Pass -IgnoreWindow for a ticket-driven catch-up.' -f $WindowStartHour, $WindowEndHour, $now)
}
if (-not $inWindow) {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
        'Running OUTSIDE the backup window because -IgnoreWindow was passed.')
}

$resp = Invoke-CvApi -Path ('Job?completedJobLookupTime={0}' -f ($LookbackHours * 3600))
$considered = 0

foreach ($j in @($resp.jobs)) {
    $s = $j.jobSummary
    if (-not $s) { continue }
    if ((Get-CvJobState -Status $s.status) -ne 'Failed') { continue }

    $client = $s.destinationClient.clientName
    if (-not $client) { $client = $s.subclient.clientName }
    if ($ClientName -and $ClientName -notcontains $client) { continue }

    $considered++

    $reason = "$($s.pendingReason)"
    $blocked = $null
    foreach ($pattern in $ExcludeReasonPattern) {
        if ($reason -like $pattern) { $blocked = $pattern; break }
    }
    if ($blocked) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('job {0}' -f $s.jobId) -Message (
            'Not resubmitted - failure reason matches "{0}". A retry will fail the same way: {1}' -f $blocked, $reason)
        continue
    }

    if ($results.Count -ge $MaxJobs) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
            'Reached -MaxJobs ({0}). {1} further failed job(s) were NOT queued this run.' -f $MaxJobs, ($considered - $results.Count))
        break
    }

    $results.Add([PSCustomObject]@{
        Name          = ('{0} / job {1}' -f $client, $s.jobId)
        Id            = $s.jobId
        JobId         = $s.jobId
        ClientName    = $client
        SubclientName = $s.subclient.subclientName
        Operation     = $s.jobType
        BackupLevel   = $s.backupLevelName
        Status        = $s.status
        FailureReason = $reason
        FailedAt      = if ($s.jobEndTime -gt 0) { [System.DateTimeOffset]::FromUnixTimeSeconds($s.jobEndTime).LocalDateTime } else { $null }
        InWindow      = $inWindow
    })
}
""", jobstate=True),
    act=r"""
$resp = Invoke-CvApi -Method POST -Path ('Job/{0}/action/resubmit' -f $item.JobId)

$newJobId = $resp.jobIds
if (-not $newJobId) { $newJobId = $resp.jobId }

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Job {0} resubmitted{1}. Original failure: {2}' -f
    $item.JobId, $(if ($newJobId) { ' as ' + ($newJobId -join ',') } else { '' }), $item.FailureReason)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'Resubmitted'
    Detail = ('new job {0}' -f ($newJobId -join ',')); Succeeded = $true })
"""),

4: dict(
    file='Get-CvActiveJob',
    modules=[],
    synopsis='Lists Commvault jobs currently running, pending or suspended.',
    desc='Reports every job the CommCell currently has in flight, with elapsed time and progress, '
         'and flags jobs that are stuck in a pending state or running far longer than expected.',
    params=CONN_PARAMS + [
        dict(name='ClientName', help='Limit to these clients.',
             decl="[string[]]$ClientName"),
        dict(name='LongRunningHours', help='Flag a job running longer than this as long-running.',
             decl="[ValidateRange(1,168)]\n    [int]$LongRunningHours = 12")],
    perms='A CommCell user with View permission on the clients being reported.',
    notes='The active-job filter is applied server-side where the CommCell honours it and again in '
          'the script. A server that ignores the query parameter therefore still produces a correct '
          'list rather than every job it knows about.',
    examples=[("-OutputFormat Console", 'What is running right now.'),
              ("-LongRunningHours 6 -OutputFormat HTML", 'Flags anything running over six hours.')],
    cleanup=CLEANUP,
    discover=cv(r"""
$resp = Invoke-CvApi -Path 'Job?jobCategory=Active'
$now = Get-Date

foreach ($j in @($resp.jobs)) {
    $s = $j.jobSummary
    if (-not $s) { continue }

    # Filtered again here: the server-side category parameter is honoured by
    # most CommCell versions, but a correct list must not depend on that.
    if ((Get-CvJobState -Status $s.status) -ne 'Active') { continue }

    $client = $s.destinationClient.clientName
    if (-not $client) { $client = $s.subclient.clientName }
    if ($ClientName -and $ClientName -notcontains $client) { continue }

    $start = if ($s.jobStartTime -gt 0) { [System.DateTimeOffset]::FromUnixTimeSeconds($s.jobStartTime).LocalDateTime } else { $null }
    $elapsed = if ($start) { [math]::Round(($now - $start).TotalHours, 2) } else { $null }
    $isPending = "$($s.status)" -match '(?i)pending|waiting|queued'
    $isLong = ($null -ne $elapsed -and $elapsed -gt $LongRunningHours)

    $results.Add([PSCustomObject]@{
        Name          = ('{0} / job {1}' -f $client, $s.jobId)
        Id            = $s.jobId
        ClientName    = $client
        SubclientName = $s.subclient.subclientName
        Operation     = $s.jobType
        BackupLevel   = $s.backupLevelName
        Status        = $s.status
        PercentDone   = $s.percentComplete
        StartedAt     = $start
        ElapsedHours  = $elapsed
        SizeGB        = if ($s.sizeOfApplication) { [math]::Round($s.sizeOfApplication / 1GB, 2) } else { $null }
        StoragePolicy = $s.storagePolicy.storagePolicyName
        PendingReason = $s.pendingReason
        Attention     = if ($isPending) { 'PENDING - not making progress' }
                        elseif ($isLong) { ('Running over {0}h' -f $LongRunningHours) }
                        else { '' }
    })

    if ($isPending) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target ('job {0}' -f $s.jobId) -Message (
            'Pending on {0}: {1}' -f $client, $s.pendingReason)
    } elseif ($isLong) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target ('job {0}' -f $s.jobId) -Message (
            'Running {0}h on {1}, over the {2}h threshold' -f $elapsed, $client, $LongRunningHours)
    }
}
""", jobstate=True)),

5: dict(
    file='Get-CvScheduledJob',
    modules=[],
    synopsis='Lists Commvault schedules due in the next two days.',
    desc='Reports the schedules configured on the CommCell together with their next run time, so an '
         'operator can see what is due before a change window. Schedules whose next run time the API '
         'does not return are reported with their pattern and a null next-run rather than a computed '
         'guess.',
    params=CONN_PARAMS + [
        dict(name='LookaheadDays', help='How far ahead to report.',
             decl="[ValidateRange(1,30)]\n    [int]$LookaheadDays = 2"),
        dict(name='ClientName', help='Limit to these clients.',
             decl="[string[]]$ClientName"),
        dict(name='IncludeDisabled', help='Include schedules that are currently disabled.',
             decl="[switch]$IncludeDisabled")],
    perms='A CommCell user with View permission on the clients being reported.',
    notes='Commvault returns a schedule pattern; whether it also returns a resolved next-run epoch '
          'varies by version and pattern type. This script reports the next run where the API '
          'supplies it and NULL where it does not - it does not re-implement Commvault\'s scheduler '
          'to fill the gap, because a computed time that disagreed with the CommCell would be worse '
          'than no time at all. Schedules with a null next run are still listed, with their pattern.',
    examples=[("-LookaheadDays 2 -OutputFormat HTML", 'What is scheduled over the next two days.'),
              ("-LookaheadDays 7 -ClientName SQLPROD01", 'A week ahead for one client.')],
    cleanup=CLEANUP,
    discover=cv(r"""
$resp = Invoke-CvApi -Path 'Schedules'
$horizon = (Get-Date).AddDays($LookaheadDays)
$now = Get-Date
$unresolved = 0

foreach ($task in @($resp.taskDetail)) {
    $client = 'CommCell'
    $assoc = @($task.associations)[0]
    if ($assoc -and $assoc.clientName) { $client = $assoc.clientName }
    if ($ClientName -and $ClientName -notcontains $client) { continue }

    foreach ($sub in @($task.subTasks)) {
        $pattern = $sub.pattern
        $enabled = -not ($task.task.taskFlags -and $task.task.taskFlags.disabled)
        if (-not $enabled -and -not $IncludeDisabled) { continue }

        # Present on most versions; absent on some pattern types. Absent is
        # reported as absent.
        $next = $null
        if ($pattern -and $pattern.nextScheduleTime -and $pattern.nextScheduleTime -gt 0) {
            $next = [System.DateTimeOffset]::FromUnixTimeSeconds($pattern.nextScheduleTime).LocalDateTime
        }

        if ($null -eq $next) {
            $unresolved++
        } elseif ($next -lt $now -or $next -gt $horizon) {
            continue
        }

        $results.Add([PSCustomObject]@{
            Name          = ('{0} / {1}' -f $client, $sub.subTask.subTaskName)
            Id            = $sub.subTask.subTaskId
            ClientName    = $client
            ScheduleName  = $sub.subTask.subTaskName
            TaskName      = $task.task.taskName
            Operation     = $sub.subTask.operationType
            BackupLevel   = $sub.options.backupOpts.backupLevel
            Enabled       = $enabled
            NextRun       = $next
            HoursUntil    = if ($next) { [math]::Round(($next - $now).TotalHours, 1) } else { $null }
            FreqType      = $pattern.freq_type
            PatternSummary= if ($pattern) { ('freq={0} interval={1} time={2}' -f $pattern.freq_type, $pattern.freq_interval, $pattern.active_start_time) } else { '' }
            NextRunSource = if ($next) { 'reported by CommCell' } else { 'NOT returned by this endpoint - pattern shown instead' }
        })
    }
}

if ($unresolved -gt 0) {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
        '{0} schedule(s) had no next-run time from the API and are listed with their pattern instead. ' +
        'They are NOT filtered by the {1}-day horizon.' -f $unresolved, $LookaheadDays)
}
""")),

6: dict(
    file='Export-CvTapeMedia',
    modules=[],
    synopsis='Performs the software eject of tape media, and stops there.',
    desc='Identifies tape media in a library and performs the software export. The physical part - '
         'removing the cartridge from the mail slot and vaulting it - needs a person at the '
         'datacentre, so this script completes the API half, records exactly which media were '
         'ejected, and hands over a pick list.',
    params=CONN_PARAMS + [
        dict(name='LibraryName', help='Tape library to operate on.',
             decl="[Parameter(Mandatory)]\n    [string]$LibraryName"),
        dict(name='MediaBarcode', help='Barcode(s) to export. All media flagged for export when omitted.',
             decl="[string[]]$MediaBarcode"),
        dict(name='ExportApiPath',
             help='PLACEHOLDER - the export endpoint path template, {0} = library id, {1} = media '
                  'id. Commvault versions differ here; VERIFY THIS AGAINST YOUR COMMCELL before '
                  'first use. Listed in MANIFEST.md under Needs Input.',
             decl="[string]$ExportApiPath = 'Library/{0}/Media/{1}/action/export'")],
    perms='A CommCell user with Media Management permission on the library.',
    actionVerb='Software-eject tape media',
    reason='Tape export for offsite vaulting',
    rollback='An exported tape is re-imported through the mail slot and inventoried. Nothing on the '
             'media is altered by an export.',
    notes='ASSIST-ONLY. The API call moves the cartridge to the mail slot; it does not remove it from '
          'the building. This script therefore produces a pick list naming every barcode and slot, '
          'and the run is not complete until a person has collected and vaulted them. The export '
          'endpoint path is a PARAMETER with a placeholder default because it varies by Commvault '
          'version - it was not guessed at silently.',
    examples=[("-LibraryName TAPELIB01", 'REPORT ONLY. Lists exportable media and raises an approval.'),
              ("-LibraryName TAPELIB01 -MediaBarcode ABC123L8 -ApprovalReference APR-...",
               'Ejects one specific cartridge once approved.')],
    cleanup=CLEANUP,
    discover=cv(r"""
$libs = Invoke-CvApi -Path 'Library'
$lib = @($libs.response) | Where-Object { $_.entityInfo.name -eq $LibraryName } | Select-Object -First 1
if (-not $lib) {
    $lib = @($libs.library) | Where-Object { $_.libraryName -eq $LibraryName } | Select-Object -First 1
}
if (-not $lib) {
    throw ('Tape library "{0}" not found on this CommCell.' -f $LibraryName)
}

$libId = $lib.entityInfo.id
if (-not $libId) { $libId = $lib.library.libraryId }
if (-not $libId) { throw ('Library "{0}" was found but returned no id.' -f $LibraryName) }

$media = @()
try {
    $resp = Invoke-CvApi -Path ('Library/{0}/Media' -f $libId)
    $media = @($resp.mediaList)
    if ($media.Count -eq 0) { $media = @($resp.media) }
} catch {
    throw ('Could not enumerate media in {0}: {1}' -f $LibraryName, $_.Exception.Message)
}

foreach ($m in $media) {
    $barcode = $m.barCode
    if (-not $barcode) { $barcode = $m.mediaName }
    if ($MediaBarcode -and $MediaBarcode -notcontains $barcode) { continue }

    # A cartridge holding a job that is still writing must not be ejected.
    $inUse = [bool]$m.isMounted -or ("$($m.mediaStatus)" -match '(?i)in use|active|mounted')
    if ($inUse) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $barcode `
            -Message 'Excluded - media is mounted or in use'
        continue
    }

    $results.Add([PSCustomObject]@{
        Name         = ('{0} / {1}' -f $LibraryName, $barcode)
        Id           = $m.mediaId
        LibraryName  = $LibraryName
        LibraryId    = $libId
        MediaId      = $m.mediaId
        Barcode      = $barcode
        SlotNumber   = $m.slotNumber
        MediaStatus  = $m.mediaStatus
        StoragePolicy= $m.storagePolicyName
        RetainUntil  = if ($m.retainUntilTime -and $m.retainUntilTime -gt 0) { [System.DateTimeOffset]::FromUnixTimeSeconds($m.retainUntilTime).LocalDateTime } else { $null }
        PhysicalStep = 'AFTER the software eject: collect from the mail slot and vault. NOT done by this script.'
    })
}
"""),
    act=r"""
$path = $ExportApiPath -f $item.LibraryId, $item.MediaId
Invoke-CvApi -Method POST -Path $path | Out-Null

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Software eject issued for barcode {0} (slot {1}). PHYSICAL REMOVAL AND VAULTING IS STILL OUTSTANDING.' -f
    $item.Barcode, $item.SlotNumber)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'SoftwareEjected'
    Detail = ('barcode {0}, slot {1} - collect from mail slot and vault' -f $item.Barcode, $item.SlotNumber)
    Succeeded = $true })
"""),

7: dict(
    file='Get-CvBackupHealthReport',
    modules=[],
    synopsis='Reports Commvault backup health across clients, jobs and libraries.',
    desc='Builds a health picture from three angles: job outcomes over the reporting window, clients '
         'with no successful backup inside their expected interval, and library capacity. A client '
         'that has silently stopped backing up is the finding that matters most, and it does not '
         'appear in a job report at all - it appears as an absence.',
    params=CONN_PARAMS + [
        dict(name='LookbackHours', help='Reporting window for job outcomes.',
             decl="[ValidateRange(1,720)]\n    [int]$LookbackHours = 24"),
        dict(name='ExpectedIntervalHours',
             help='A client with no successful backup within this many hours is reported as stale.',
             decl="[ValidateRange(1,8760)]\n    [int]$ExpectedIntervalHours = 36"),
        dict(name='LibraryFreeSpaceWarnPercent', help='Warn when a library falls below this percent free.',
             decl="[ValidateRange(1,99)]\n    [int]$LibraryFreeSpaceWarnPercent = 15")],
    perms='A CommCell user with View permission on clients and libraries.',
    notes='"No successful backup" is derived from the job history inside -LookbackHours. A client '
          'whose backup interval is longer than the lookback will look stale when it is not, which '
          'is why -ExpectedIntervalHours is separate from -LookbackHours and defaults higher.',
    examples=[("-LookbackHours 24 -OutputFormat HTML", 'Daily health report as HTML.'),
              ("-LookbackHours 168 -ExpectedIntervalHours 168", 'Weekly view for weekly-backup clients.')],
    cleanup=CLEANUP,
    discover=cv(r"""
$now = Get-Date
$lookbackSeconds = [math]::Max($LookbackHours, $ExpectedIntervalHours) * 3600

$jobs = @()
try {
    $resp = Invoke-CvApi -Path ('Job?completedJobLookupTime={0}' -f $lookbackSeconds)
    $jobs = @($resp.jobs)
} catch {
    throw ('Could not read job history: {0}' -f $_.Exception.Message)
}

# --- 1. Job outcome summary over the window ----------------------------
$windowCutoff = $now.AddHours(-$LookbackHours)
$succeeded = 0; $failed = 0; $warned = 0
$lastGoodByClient = @{}

foreach ($j in $jobs) {
    $s = $j.jobSummary
    if (-not $s) { continue }
    $client = $s.destinationClient.clientName
    if (-not $client) { $client = $s.subclient.clientName }
    if (-not $client) { continue }

    $ended = if ($s.jobEndTime -gt 0) { [System.DateTimeOffset]::FromUnixTimeSeconds($s.jobEndTime).LocalDateTime } else { $null }
    $state = Get-CvJobState -Status $s.status

    if ($state -eq 'Completed' -and $ended) {
        if (-not $lastGoodByClient.ContainsKey($client) -or $ended -gt $lastGoodByClient[$client]) {
            $lastGoodByClient[$client] = $ended
        }
    }

    if ($ended -and $ended -lt $windowCutoff) { continue }
    switch ($state) {
        'Completed' { $succeeded++ }
        'Failed'    { $failed++ }
        'Warning'   { $warned++ }
        default     { }
    }
}

$total = $succeeded + $failed + $warned

# All three record types share one shape so a CSV export keeps every column;
# Export-Csv takes its header from the first object it sees.
function ConvertTo-CvHealthRecord {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param($Name, $Id, $RecordType, $Detail, $Status,
          $JobsSucceeded, $JobsFailed, $JobsWarned, $TotalJobs, $SuccessRate,
          $LastGoodBackup, $AgeHours, $TotalSpace, $FreeSpace, $PercentFree)

    [PSCustomObject]@{
        Name = $Name; Id = $Id; RecordType = $RecordType
        JobsSucceeded = $JobsSucceeded; JobsFailed = $JobsFailed; JobsWarned = $JobsWarned
        TotalJobs = $TotalJobs; SuccessRate = $SuccessRate
        LastGoodBackup = $LastGoodBackup; AgeHours = $AgeHours
        TotalSpace = $TotalSpace; FreeSpace = $FreeSpace; PercentFree = $PercentFree
        Detail = $Detail; Status = $Status
    }
}

$results.Add((ConvertTo-CvHealthRecord -Name ('Job outcomes, last {0}h' -f $LookbackHours) `
    -Id 'job-summary' -RecordType 'JobSummary' `
    -JobsSucceeded $succeeded -JobsFailed $failed -JobsWarned $warned -TotalJobs $total `
    -SuccessRate $(if ($total -gt 0) { [math]::Round(($succeeded / $total) * 100, 1) } else { $null }) `
    -Detail $(if ($total -eq 0) { 'No jobs completed in the window' } else { '' }) `
    -Status $(if ($failed -gt 0) { 'Degraded' } elseif ($total -eq 0) { 'NoData' } else { 'OK' })))

# --- 2. Clients with no recent successful backup -----------------------
$clients = @()
try {
    $resp = Invoke-CvApi -Path 'Client'
    $clients = @($resp.clientProperties)
} catch {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
        'Client list unavailable ({0}); stale-client detection skipped this run.' -f $_.Exception.Message)
}

foreach ($c in $clients) {
    $name = $c.client.clientEntity.clientName
    if (-not $name) { continue }

    $lastGood = if ($lastGoodByClient.ContainsKey($name)) { $lastGoodByClient[$name] } else { $null }
    $ageHours = if ($lastGood) { [math]::Round(($now - $lastGood).TotalHours, 1) } else { $null }
    $stale = ($null -eq $lastGood) -or ($ageHours -gt $ExpectedIntervalHours)
    if (-not $stale) { continue }

    $results.Add((ConvertTo-CvHealthRecord -Name $name -Id $c.client.clientEntity.clientId `
        -RecordType 'StaleClient' -LastGoodBackup $lastGood -AgeHours $ageHours `
        -Detail $(if ($lastGood) { ('Last success {0}h ago, expected within {1}h' -f $ageHours, $ExpectedIntervalHours) }
                  else { ('NO successful backup in the {0}h examined' -f [math]::Max($LookbackHours, $ExpectedIntervalHours)) }) `
        -Status 'Stale'))
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $name -Message (
        'No successful backup within the expected {0}h interval' -f $ExpectedIntervalHours)
}

# --- 3. Library capacity ------------------------------------------------
try {
    $libs = Invoke-CvApi -Path 'Library'
    foreach ($lib in @($libs.response)) {
        $info = $lib.libraryInfo
        if (-not $info) { continue }
        # Reported as raw values plus a percentage. The unit Commvault uses for
        # these fields varies, so they are not relabelled as GB here - the
        # percentage is unit-independent and is what the threshold tests.
        $totalSpace = $info.totalSpace
        $freeSpace = $info.freeSpace
        if (-not $totalSpace -or $totalSpace -le 0) { continue }

        $pctFree = [math]::Round(($freeSpace / $totalSpace) * 100, 1)
        $results.Add((ConvertTo-CvHealthRecord -Name $lib.entityInfo.name -Id $lib.entityInfo.id `
            -RecordType 'Library' -TotalSpace $totalSpace -FreeSpace $freeSpace -PercentFree $pctFree `
            -Detail ('{0}% free' -f $pctFree) `
            -Status $(if ($pctFree -lt $LibraryFreeSpaceWarnPercent) { 'LowSpace' } else { 'OK' })))
        if ($pctFree -lt $LibraryFreeSpaceWarnPercent) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $lib.entityInfo.name -Message (
                'Library {0}% free, below the {1}% threshold' -f $pctFree, $LibraryFreeSpaceWarnPercent)
        }
    }
} catch {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
        'Library capacity unavailable from this endpoint ({0}); capacity section omitted rather than estimated.' -f $_.Exception.Message)
}
""", jobstate=True)),

8: dict(
    file='Set-CvSubclientConfiguration',
    modules=[],
    synopsis='Compares subclient configuration against a desired state and applies approved changes.',
    desc='Reads subclient properties, compares them against a desired-state file, and reports every '
         'deviation. It applies only the properties an operator explicitly names, and refuses to '
         'touch the properties that encode a protection DESIGN decision - what is protected, how '
         'often, and for how long - because the workbook reserves those for a human.',
    params=CONN_PARAMS + [
        dict(name='DesiredStateFile', help='JSON file describing the expected subclient properties.',
             decl="[Parameter(Mandatory)]\n    [string]$DesiredStateFile"),
        dict(name='ClientName', help='Limit to these clients.',
             decl="[string[]]$ClientName"),
        dict(name='ApplyProperty', help='Only these properties may be written. Nothing is applied when omitted.',
             decl="[string[]]$ApplyProperty"),
        dict(name='DesignProperty',
             help='Properties treated as design decisions and never written automatically.',
             decl="[string[]]$DesignProperty = @('storagePolicyName','retentionDays','backupLevel','schedulePolicy','contentPaths')"),
        dict(name='DesignApproved',
             help='Permits a design property to be written. Requires a named design authority in '
                  '-Reason and is deliberately awkward to pass.',
             decl="[switch]$DesignApproved")],
    perms='A CommCell user with Agent Management permission on the target subclients.',
    actionVerb='Apply subclient property',
    reason='Subclient configuration drift correction',
    rollback='Each change logs the previous value before it is written. Revert by re-running with a '
             'desired-state file carrying the old value, or from the CommCell console.',
    notes='ASSIST-ONLY. Reporting drift is mechanical; deciding that a subclient SHOULD hold a '
          'different retention or storage policy is a protection-design decision with cost and '
          'recoverability consequences. Those properties are listed in -DesignProperty and are '
          'refused unless -DesignApproved is passed alongside a -Reason naming who made the call. '
          'Everything not named in -ApplyProperty is reported and left alone.',
    examples=[("-DesiredStateFile .\\baseline.json", 'REPORT ONLY. Lists drift and raises an approval.'),
              ("-DesiredStateFile .\\baseline.json -ApplyProperty description,enableBackup -ApprovalReference APR-...",
               'Applies two non-design properties from an approved review.')],
    cleanup=CLEANUP,
    discover=cv(r"""
if (-not (Test-Path -LiteralPath $DesiredStateFile)) {
    throw ('Desired-state file not found: {0}' -f $DesiredStateFile)
}
$desired = Get-Content -LiteralPath $DesiredStateFile -Raw | ConvertFrom-Json

$names = if ($ClientName) { $ClientName } else { @($desired.PSObject.Properties.Name) }
$reported = 0

foreach ($cName in $names) {
    $expectedForClient = $desired.$cName
    if (-not $expectedForClient) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $cName `
            -Message 'No desired state defined for this client; skipped rather than assumed compliant.'
        continue
    }

    $subs = @()
    try {
        $resp = Invoke-CvApi -Path ('Subclient?clientName={0}' -f [uri]::EscapeDataString($cName))
        $subs = @($resp.subClientProperties)
    } catch {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $cName `
            -Message ('Could not read subclients: {0}' -f $_.Exception.Message)
        continue
    }

    foreach ($sc in $subs) {
        $e = $sc.subClientEntity
        $expected = $expectedForClient.($e.subclientName)
        if (-not $expected) { continue }

        foreach ($prop in $expected.PSObject.Properties) {
            $key = $prop.Name
            $want = $prop.Value

            $have = switch ($key) {
                'storagePolicyName' { $sc.commonProperties.storageDevice.dataBackupStoragePolicy.storagePolicyName }
                'description'       { $sc.commonProperties.description }
                'enableBackup'      { $sc.commonProperties.enableBackup }
                'numberOfBackupStreams' { $sc.commonProperties.numberOfBackupStreams }
                default             { $sc.commonProperties.$key }
            }
            if ($null -eq $have) { continue }
            if ("$have" -eq "$want") { continue }

            $reported++
            $isDesign = $DesignProperty -contains $key

            if ($isDesign -and -not $DesignApproved) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0}/{1}/{2}' -f $cName, $e.subclientName, $key) `
                    -Message 'Drift reported but NOT actionable - this is a protection-design property. Requires -DesignApproved.'
                continue
            }
            if (-not $ApplyProperty -or $ApplyProperty -notcontains $key) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0}/{1}/{2}' -f $cName, $e.subclientName, $key) `
                    -Message 'Drift reported but not selected by -ApplyProperty; left alone.'
                continue
            }

            $results.Add([PSCustomObject]@{
                Name          = ('{0} / {1} / {2}' -f $cName, $e.subclientName, $key)
                Id            = $e.subclientId
                ClientName    = $cName
                SubclientName = $e.subclientName
                SubclientId   = $e.subclientId
                Property      = $key
                CurrentValue  = "$have"
                DesiredValue  = "$want"
                DesiredRaw    = $want
                IsDesignDecision = $isDesign
                Note          = if ($isDesign) { 'DESIGN property - being written only because -DesignApproved was passed' }
                                else { 'Operational property' }
            })
        }
    }
}

if ($DesignApproved -and -not $Reason) {
    throw '-DesignApproved requires -Reason naming the design authority who made the call.'
}

Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
    'Configuration comparison complete. {0} deviation(s) found, {1} in the change set.' -f $reported, $results.Count)
"""),
    act=r"""
$body = @{
    subClientProperties = @{
        commonProperties = @{ $item.Property = $item.DesiredRaw }
    }
}
Invoke-CvApi -Method POST -Path ('Subclient/{0}' -f $item.SubclientId) -Body $body | Out-Null

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Applied {0}: "{1}" -> "{2}"{3}. Previous value recorded here for rollback.' -f
    $item.Property, $item.CurrentValue, $item.DesiredValue,
    $(if ($item.IsDesignDecision) { ' [DESIGN PROPERTY, -DesignApproved]' } else { '' }))
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'PropertyApplied'
    Detail = ('{0}: {1} -> {2}' -f $item.Property, $item.CurrentValue, $item.DesiredValue)
    Succeeded = $true })
"""),

9: dict(
    file='Restore-CvBackupData',
    modules=[],
    synopsis='Submits a Commvault restore for a ticketed recovery request.',
    desc='Submits a restore of backed-up data to a named destination. Every choice the workbook '
         'reserves for a human - which target, which version, in-place or out-of-place - must be '
         'stated explicitly on the command line; none of them has a default. Validating that the '
         'restored data is correct is also a human step and is not attempted here.',
    params=CONN_PARAMS + [
        dict(name='ClientName', help='Client the data was backed up from.',
             decl="[Parameter(Mandatory)]\n    [string]$ClientName"),
        dict(name='SourcePath', help='Path(s) to restore.',
             decl="[Parameter(Mandatory)]\n    [string[]]$SourcePath"),
        dict(name='DestinationClient',
             help='Client to restore TO. Mandatory for an out-of-place restore; there is no default.',
             decl="[string]$DestinationClient"),
        dict(name='DestinationPath',
             help='Path to restore TO. Mandatory for an out-of-place restore; there is no default.',
             decl="[string]$DestinationPath"),
        dict(name='InPlace',
             help='Restore over the original location. Requires -OverwriteConfirmed as well.',
             decl="[switch]$InPlace"),
        dict(name='OverwriteConfirmed',
             help='Confirms that overwriting live data at the destination is intended and that the '
                  'current contents are expendable or separately backed up.',
             decl="[switch]$OverwriteConfirmed"),
        dict(name='PointInTime',
             help='Restore data as at this time. Mutually exclusive with -FromJobId; one is required.',
             decl="[datetime]$PointInTime"),
        dict(name='FromJobId', help='Restore from this specific backup job.',
             decl="[int]$FromJobId"),
        dict(name='RestoreApiPath',
             help='PLACEHOLDER - the restore submission endpoint. Commvault versions differ; VERIFY '
                  'THIS AGAINST YOUR COMMCELL before first use. Listed in MANIFEST.md under Needs '
                  'Input.',
             decl="[string]$RestoreApiPath = 'CreateTask'")],
    minage=0,
    perms='A CommCell user with Browse and In-Place/Out-of-Place Restore permission on the data and '
          'the destination client.',
    actionVerb='Submit restore',
    reason='Ticketed data recovery',
    rollback='NONE for an in-place restore - it overwrites whatever is at the destination. An '
             'out-of-place restore writes to a new location and can simply be deleted. This '
             'asymmetry is why -InPlace requires a second explicit flag.',
    notes='ASSIST-ONLY AND DESTRUCTIVE. An in-place restore overwrites live data and cannot be undone '
          'by this script or any other. Nothing is defaulted: the destination, the version, and the '
          'in-place decision are all required inputs, because a restore that silently picked "latest, '
          'in place" would be exactly the accident this gate exists to prevent. -MinimumAgeDays does '
          'not apply to a restore and is left at 0. Confirming the restored data is actually correct '
          'is a human verification step that this script does not perform and does not claim to.',
    examples=[("-ClientName FILESRV01 -SourcePath 'D:\\\\Shares\\\\Finance' -DestinationClient FILESRV02 "
               "-DestinationPath 'D:\\\\Restore' -FromJobId 123456",
               'REPORT ONLY. Builds the out-of-place restore request and raises an approval.'),
              ("-ClientName FILESRV01 -SourcePath 'D:\\\\Shares\\\\Finance' -InPlace -OverwriteConfirmed "
               "-PointInTime '2026-08-01 02:00' -ApprovalReference APR-... -Execute",
               'Submits an approved in-place restore. Overwrites live data.')],
    cleanup=CLEANUP,
    discover=cv(r"""
if ($InPlace -and ($DestinationClient -or $DestinationPath)) {
    throw '-InPlace and -DestinationClient/-DestinationPath are mutually exclusive. Choose one.'
}
if (-not $InPlace -and -not ($DestinationClient -and $DestinationPath)) {
    throw 'An out-of-place restore requires BOTH -DestinationClient and -DestinationPath. ' +
          'Neither is defaulted, deliberately. Pass -InPlace if you intend to overwrite the original.'
}
if ($InPlace -and -not $OverwriteConfirmed) {
    throw 'Refusing an in-place restore without -OverwriteConfirmed. This overwrites live data at ' +
          'the original location and cannot be undone.'
}
if (-not $PointInTime -and -not $FromJobId) {
    throw 'Specify the version to restore: -FromJobId or -PointInTime. There is no "latest" default.'
}
if ($PointInTime -and $FromJobId) {
    throw '-PointInTime and -FromJobId are mutually exclusive.'
}

# Confirm the source client exists before building a request against it.
$clientId = $null
try {
    $resp = Invoke-CvApi -Path ('Client?clientName={0}' -f [uri]::EscapeDataString($ClientName))
    $clientId = @($resp.clientProperties)[0].client.clientEntity.clientId
} catch {
    throw ('Could not resolve client "{0}": {1}' -f $ClientName, $_.Exception.Message)
}
if (-not $clientId) { throw ('Client "{0}" not found on this CommCell.' -f $ClientName) }

$destClient = if ($InPlace) { $ClientName } else { $DestinationClient }
$destClientId = $clientId
if (-not $InPlace) {
    try {
        $resp = Invoke-CvApi -Path ('Client?clientName={0}' -f [uri]::EscapeDataString($DestinationClient))
        $destClientId = @($resp.clientProperties)[0].client.clientEntity.clientId
    } catch {
        throw ('Could not resolve destination client "{0}": {1}' -f $DestinationClient, $_.Exception.Message)
    }
    if (-not $destClientId) { throw ('Destination client "{0}" not found.' -f $DestinationClient) }
}

foreach ($path in $SourcePath) {
    $results.Add([PSCustomObject]@{
        Name           = ('{0}: {1}' -f $ClientName, $path)
        Id             = ('{0}|{1}' -f $ClientName, $path)
        ClientName     = $ClientName
        ClientId       = $clientId
        SourcePath     = $path
        InPlace        = [bool]$InPlace
        DestinationClient = $destClient
        DestinationClientId = $destClientId
        DestinationPath   = if ($InPlace) { $path } else { $DestinationPath }
        Version        = if ($FromJobId) { ('job {0}' -f $FromJobId) } else { ('as at {0:u}' -f $PointInTime) }
        FromJobId      = $FromJobId
        PointInTime    = $PointInTime
        OverwriteRisk  = if ($InPlace) { 'OVERWRITES LIVE DATA at the original location - no rollback' }
                         else { 'Writes to a new location; delete the destination to undo' }
        HumanStep      = 'Validating the restored data is correct is NOT performed by this script.'
    })
}
"""),
    act=r"""
$restoreOptions = @{
    destination = @{
        inPlace = [bool]$item.InPlace
        destClient = @{ clientId = $item.DestinationClientId; clientName = $item.DestinationClient }
    }
    fileOption = @{ sourceItem = @($item.SourcePath) }
}
if (-not $item.InPlace) {
    $restoreOptions.destination.destPath = @($item.DestinationPath)
}
if ($item.FromJobId) {
    $restoreOptions.browseOption = @{ jobId = $item.FromJobId }
} else {
    $restoreOptions.browseOption = @{
        timeRange = @{ toTimeValue = [int][double]::Parse((Get-Date $item.PointInTime -UFormat %s)) }
    }
}

$body = @{
    taskInfo = @{
        associations = @(@{ clientName = $item.ClientName })
        task         = @{ taskType = 1; initiatedFrom = 2 }
        subTasks     = @(@{
            subTask        = @{ subTaskType = 3; operationType = 1001 }
            options        = @{ restoreOptions = $restoreOptions }
        })
    }
}

$resp = Invoke-CvApi -Method POST -Path $RestoreApiPath -Body $body
$newJobId = $resp.jobIds
if (-not $newJobId) { $newJobId = $resp.jobId }
if (-not $newJobId) {
    throw 'Restore request was accepted but Commvault returned no job id. Check the CommCell console before resubmitting.'
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Restore submitted as job {0}. {1} -> {2}. {3}. VALIDATION OF THE RESTORED DATA IS STILL OUTSTANDING.' -f
    ($newJobId -join ','), $item.SourcePath, $item.DestinationPath, $item.Version)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'RestoreSubmitted'
    Detail = ('job {0}, {1}' -f ($newJobId -join ','), $item.OverwriteRisk); Succeeded = $true })
"""),
}

