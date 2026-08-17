# -*- coding: utf-8 -*-
"""Security Cloud - use cases 1-18.

Every row on this sheet is marked feasibility "Partial", and eight of the
eighteen are agent-assist. That shape is the point of the category: security
work automates the gathering, enrichment and correlation, and stops at the
judgement. These scripts are written to stop in the same place.
"""


def graph(scopes):
    return ("\nConnect-MgGraph -Scopes '%s' -NoWelcome -ErrorAction Stop\n"
            "Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Microsoft Graph'\n"
            % scopes)


AZ_CONNECT = r"""
$azContext = Get-AzContext -ErrorAction SilentlyContinue
if (-not $azContext) {
    throw 'No Azure context. Run Connect-AzAccount, or use a managed identity, before this script.'
}
if ($SubscriptionId -and $azContext.Subscription.Id -ne $SubscriptionId) {
    $azContext = Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop
}
Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
    'Azure context: subscription {0}' -f $azContext.Subscription.Id)
"""

SUB_PARAM = dict(name='SubscriptionId', help='Azure subscription to operate in. The current context when omitted.',
                 decl="[string]$SubscriptionId")

ITSM_HELPER = r"""
function New-SecurityTicket {
    <#
        .SYNOPSIS
            Raises one ITSM ticket for a security finding.
        .DESCRIPTION
            Posts to the ITSM endpoint from config.json using the caller's
            integrated credentials. No token is embedded anywhere; if the
            endpoint is unconfigured the caller is told so rather than the
            failure being swallowed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][hashtable]$Context
    )

    if (-not $PSCmdlet.ShouldProcess($Title, 'Raise ITSM ticket')) {
        return [PSCustomObject]@{ TicketNumber = '(WhatIf)'; Raw = $null }
    }
    if (-not $Context.TicketUrl) {
        throw 'No ITSM endpoint. Set itsm.createTicketUrl in config.json; tickets are not written to a file as a silent fallback.'
    }

    $body = @{
        short_description = $Title
        description       = $Description
        category          = $Context.Category
        assignment_group  = $Context.AssignmentGroup
    } | ConvertTo-Json -Depth 6

    $response = Invoke-RestMethod -Uri $Context.TicketUrl -Method POST -Body $body `
        -ContentType 'application/json' -UseDefaultCredentials -ErrorAction Stop

    $number = $response.result.number
    if (-not $number) { $number = $response.number }
    [PSCustomObject]@{ TicketNumber = $number; Raw = $response }
}

$itsmContext = @{
    TicketUrl       = if ($config -and $config.itsm) { $config.itsm.createTicketUrl } else { $null }
    Category        = if ($config -and $config.itsm) { $config.itsm.category } else { 'Security' }
    AssignmentGroup = if ($config -and $config.itsm) { $config.itsm.assignmentGroup } else { '' }
}
"""

STATE_HELPER = r"""
function Get-SecurityState {
    <#
        .SYNOPSIS
            Reads the set of item ids this script has already acted on.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)

    $state = @{}
    if (Test-Path -LiteralPath $Path) {
        try {
            $loaded = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
            foreach ($p in $loaded.PSObject.Properties) { $state[$p.Name] = $p.Value }
        } catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'State file unreadable ({0}); treating every item as new. Expect duplicates this run.' -f $_.Exception.Message)
        }
    }
    return $state
}

function Save-SecurityState {
    <#
        .SYNOPSIS
            Persists the acted-on set so a re-run does not duplicate work.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$State
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    $State | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding UTF8
}
"""

SPECS = {

1: dict(
    file='New-DefenderAlertTicket',
    modules=['Az.Accounts', 'Az.Security'],
    synopsis='Raises ITSM tickets for high-severity Defender for Cloud alerts.',
    desc='Reads active Defender for Cloud alerts and raises one ITSM ticket per high-severity alert. '
         'Ticketing is the safe half of triage, which is why this row is not gated - but it is only '
         'safe if it is idempotent, so alerts already ticketed are recorded and skipped.',
    params=[SUB_PARAM,
            dict(name='MinimumSeverity', help='Lowest alert severity to ticket.',
                 decl="[ValidateSet('High','Medium','Low')]\n    [string]$MinimumSeverity = 'High'"),
            dict(name='LookbackHours', help='Only consider alerts detected within this window.',
                 decl="[ValidateRange(1,720)]\n    [int]$LookbackHours = 24"),
            dict(name='StateFile', help='Path recording alerts already ticketed, so a re-run does not duplicate them.',
                 decl="[string]$StateFile"),
            dict(name='MaxTickets', help='Ceiling on tickets raised in one run.',
                 decl="[ValidateRange(1,500)]\n    [int]$MaxTickets = 50")],
    perms='Security Reader on the subscription, plus write access to the ITSM endpoint.',
    actionVerb='Raise ticket for alert',
    rollback='Close the ticket. No security control or resource is modified by this script.',
    notes='The dangerous failure here is not a wrong ticket, it is a thousand right ones. An alert '
          'storm without the state file would raise a ticket per alert per run, so the ticketed set '
          'is persisted and -MaxTickets caps a single run; hitting the cap is logged with the count '
          'that was left, rather than silently truncating.',
    examples=[("-MinimumSeverity High -LookbackHours 24", 'Ticket high-severity alerts from the last day.'),
              ("-MinimumSeverity Medium -MaxTickets 20 -WhatIf", 'Shows what would be raised.')],
    discover=AZ_CONNECT + ITSM_HELPER + STATE_HELPER + r"""
if (-not $StateFile) {
    $StateFile = Join-Path $env:ProgramData 'ITAutomation\State\defender-alert-tickets.json'
}
$ticketed = Get-SecurityState -Path $StateFile

$severityRank = @{ 'High' = 3; 'Medium' = 2; 'Low' = 1 }
$floor = $severityRank[$MinimumSeverity]
$cutoff = (Get-Date).AddHours(-$LookbackHours)

$alerts = @(Get-AzSecurityAlert -ErrorAction Stop)
$skippedExisting = 0

foreach ($alert in $alerts) {
    if ("$($alert.Status)" -match '(?i)dismissed|resolved') { continue }

    $rank = $severityRank["$($alert.AlertSeverity)"]
    if (-not $rank -or $rank -lt $floor) { continue }

    $detected = $alert.TimeGeneratedUtc
    if (-not $detected) { $detected = $alert.StartTimeUtc }
    if ($detected -and ([datetime]$detected) -lt $cutoff) { continue }

    $key = "$($alert.SystemAlertId)"
    if (-not $key) { $key = "$($alert.Name)" }
    if ($ticketed.ContainsKey($key)) {
        $skippedExisting++
        continue
    }

    if ($results.Count -ge $MaxTickets) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
            'Reached -MaxTickets ({0}). Further eligible alerts were NOT ticketed this run.' -f $MaxTickets)
        break
    }

    $results.Add([PSCustomObject]@{
        Name            = $alert.AlertDisplayName
        Id              = $key
        AlertId         = $key
        Severity        = "$($alert.AlertSeverity)"
        Status          = "$($alert.Status)"
        DetectedAt      = $detected
        ResourceId      = $alert.CompromisedEntity
        Description     = $alert.Description
        RemediationSteps= (@($alert.RemediationSteps) -join ' ')
        Intent          = $alert.Intent
        StateFile       = $StateFile
    })
}

Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
    '{0} alert(s) eligible for ticketing; {1} already ticketed on a previous run and skipped.' -f
    $results.Count, $skippedExisting)
""",
    act=r"""
$ticket = New-SecurityTicket -Context $itsmContext `
    -Title ('[{0}] Defender for Cloud: {1}' -f $item.Severity, $item.Name) `
    -Description (@(
        ('Alert: {0}' -f $item.Name)
        ('Severity: {0}' -f $item.Severity)
        ('Detected: {0}' -f $item.DetectedAt)
        ('Affected resource: {0}' -f $item.ResourceId)
        ''
        $item.Description
        ''
        ('Remediation guidance from Defender: {0}' -f $item.RemediationSteps)
        ('Raised automatically by {0}. Alert id {1}.' -f $scriptName, $item.AlertId)
    ) -join "`n")

# Recorded immediately, so a failure later in the batch cannot cause this
# alert to be ticketed twice on the next run.
$ticketed[$item.AlertId] = @{ Ticket = $ticket.TicketNumber; At = (Get-Date).ToUniversalTime().ToString('o') }
Save-SecurityState -Path $item.StateFile -State $ticketed

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Ticket {0} raised for {1} alert' -f $ticket.TicketNumber, $item.Severity)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'TicketRaised'; Detail = $ticket.TicketNumber; Succeeded = $true })
"""),

2: dict(
    file='Invoke-SentinelPhishingTriage',
    modules=['Az.Accounts'],
    synopsis='Triages Sentinel phishing incidents, closing only high-confidence known patterns.',
    desc='Classifies open phishing incidents against a file of known high-confidence patterns. Those '
         'that match are closed with a classification; everything else is left open and reported for '
         'an analyst. Sender blocking is not performed at all - the workbook assigns that decision to '
         'an analyst and this script does not take it.',
    params=[SUB_PARAM,
            dict(name='ResourceGroupName', help='Resource group holding the Sentinel workspace.',
                 decl="[Parameter(Mandatory)]\n    [string]$ResourceGroupName"),
            dict(name='WorkspaceName', help='Log Analytics workspace Sentinel runs on.',
                 decl="[Parameter(Mandatory)]\n    [string]$WorkspaceName"),
            dict(name='KnownPatternFile',
                 help='JSON file of high-confidence patterns. An incident matching one of these is '
                      'eligible for automatic closure; nothing else is.',
                 decl="[Parameter(Mandatory)]\n    [string]$KnownPatternFile"),
            dict(name='LookbackHours', help='Only consider incidents created within this window.',
                 decl="[ValidateRange(1,720)]\n    [int]$LookbackHours = 24"),
            dict(name='IncidentTitleFilter', help='Substring identifying phishing incidents.',
                 decl="[string]$IncidentTitleFilter = 'phish'")],
    perms='Microsoft Sentinel Responder on the workspace.',
    actionVerb='Close phishing incident',
    reason='Automated phishing triage of known patterns',
    rollback='Reopen the incident in Sentinel. The classification and comment this script writes are '
             'part of the incident record and remain visible after reopening.',
    notes='ASSIST-ONLY. Two things are deliberately not automated. Ambiguous verdicts stay open and '
          'are reported, because a phishing incident closed wrongly is a real one nobody looks at '
          'again. And sender blocking is not performed under any flag - blocking a sender has effects '
          'well beyond the incident that prompted it, and the workbook assigns that call to an '
          'analyst. Where the evidence supports one, the report says so and leaves it to them.',
    examples=[("-ResourceGroupName rg-sec -WorkspaceName law-sec -KnownPatternFile .\\\\patterns.json",
               'REPORT ONLY. Classifies incidents and raises an approval.'),
              ("-ResourceGroupName rg-sec -WorkspaceName law-sec -KnownPatternFile .\\\\patterns.json -ApprovalReference APR-...",
               'Closes the high-confidence matches.')],
    discover=AZ_CONNECT + r"""
if (-not (Test-Path -LiteralPath $KnownPatternFile)) {
    throw ('Known-pattern file not found: {0}. Without it nothing is high-confidence and nothing ' +
           'would be eligible for closure.' -f $KnownPatternFile)
}
$patterns = @((Get-Content -LiteralPath $KnownPatternFile -Raw | ConvertFrom-Json).patterns)
if ($patterns.Count -eq 0) {
    throw ('No patterns defined in {0}.' -f $KnownPatternFile)
}

$base = ('/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.OperationalInsights/workspaces/{2}' +
         '/providers/Microsoft.SecurityInsights') -f $azContext.Subscription.Id, $ResourceGroupName, $WorkspaceName

$response = Invoke-AzRestMethod -Path ('{0}/incidents?api-version=2023-02-01' -f $base) -Method GET -ErrorAction Stop
if ($response.StatusCode -ge 400) {
    throw ('Sentinel incidents could not be read (HTTP {0}): {1}' -f $response.StatusCode, $response.Content)
}
$incidents = @(($response.Content | ConvertFrom-Json).value)
$cutoff = (Get-Date).AddHours(-$LookbackHours)

foreach ($incident in $incidents) {
    $p = $incident.properties
    if ("$($p.status)" -eq 'Closed') { continue }
    if ($IncidentTitleFilter -and "$($p.title)" -notmatch [regex]::Escape($IncidentTitleFilter)) { continue }
    if ($p.createdTimeUtc -and ([datetime]$p.createdTimeUtc) -lt $cutoff) { continue }

    $haystack = '{0} {1}' -f $p.title, $p.description
    $matched = @($patterns | Where-Object { $haystack -match $_.match })
    $isHighConfidence = ($matched.Count -gt 0)

    # A blockable sender is evidence for an analyst, not an instruction. This
    # script never blocks one.
    $senderEvidence = ''
    if ($haystack -match '(?i)from[:\s]+([^\s<>]+@[^\s<>]+)') { $senderEvidence = $Matches[1] }

    if (-not $isHighConfidence) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $p.incidentNumber -Message (
            'Left OPEN for analyst - no high-confidence pattern matched. Severity {0}.' -f $p.severity)
    }

    $results.Add([PSCustomObject]@{
        Name             = ('#{0} {1}' -f $p.incidentNumber, $p.title)
        Id               = $incident.name
        IncidentName     = $incident.name
        IncidentNumber   = $p.incidentNumber
        Title            = $p.title
        Severity         = $p.severity
        Status           = $p.status
        CreatedUtc       = $p.createdTimeUtc
        Owner            = $p.owner.assignedTo
        HighConfidence   = $isHighConfidence
        MatchedPattern   = (($matched | ForEach-Object { $_.name }) -join '; ')
        Classification   = if ($isHighConfidence) { @($matched)[0].classification } else { '' }
        SenderEvidence   = $senderEvidence
        SenderBlockNote  = if ($senderEvidence) {
                              ('Sender {0} appears in this incident. Blocking it is an ANALYST decision and is not performed by this script.' -f $senderEvidence)
                           } else { '' }
        ApiBase          = $base
        Actionable       = $isHighConfidence
    })
}

$ambiguous = @($results | Where-Object { -not $_.HighConfidence })
Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
    '{0} incident(s) matched a high-confidence pattern; {1} left open for analyst review. ' +
    'No sender was blocked.' -f ($results.Count - $ambiguous.Count), $ambiguous.Count)
""",
    act=r"""
if (-not $item.Actionable) {
    $actions.Add([PSCustomObject]@{
        Name = $item.Name; Action = 'LeftForAnalyst'
        Detail = 'No high-confidence pattern matched'; Succeeded = $true })
} else {
    $body = @{
        properties = @{
            title          = $item.Title
            severity       = $item.Severity
            status         = 'Closed'
            classification = if ($item.Classification) { $item.Classification } else { 'TruePositive' }
            classificationComment = ('Closed automatically by {0}: matched high-confidence pattern "{1}". Approval {2}, ticket {3}.' -f
                $scriptName, $item.MatchedPattern, $ApprovalReference, $TicketReference)
        }
    } | ConvertTo-Json -Depth 6

    $update = Invoke-AzRestMethod -Method PUT -Payload $body `
        -Path ('{0}/incidents/{1}?api-version=2023-02-01' -f $item.ApiBase, $item.IncidentName) -ErrorAction Stop
    if ($update.StatusCode -ge 400) {
        throw ('Incident update failed (HTTP {0}): {1}' -f $update.StatusCode, $update.Content)
    }

    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
        'Incident closed as {0} on pattern "{1}"{2}' -f
        $item.Classification, $item.MatchedPattern,
        $(if ($item.SenderEvidence) { '. Sender block NOT performed - analyst decision.' } else { '' }))
    $actions.Add([PSCustomObject]@{
        Name = $item.Name; Action = 'IncidentClosed'; Detail = $item.MatchedPattern; Succeeded = $true })
}
"""),

3: dict(
    file='Invoke-EntraRiskyUserRemediation',
    modules=['Microsoft.Graph.Authentication', 'Microsoft.Graph.Identity.SignIns', 'Microsoft.Graph.Users.Actions'],
    synopsis='Remediates high-confidence risky users, and only those.',
    desc='Acts on users Identity Protection rates as high risk, and leaves everything below that for '
         'an analyst. The default remediation revokes sessions - effective against a live token and '
         'survivable if wrong. Blocking sign-in is available and requires a second explicit flag, '
         'because a false-positive lockout costs a real user their working day.',
    params=[dict(name='Action', help='Remediation to apply.',
                 decl="[ValidateSet('RevokeSessions','ConfirmCompromised','BlockSignIn')]\n    [string]$Action = 'RevokeSessions'"),
            dict(name='MinimumRiskLevel',
                 help='Only users at this risk level are actionable. Anything lower is reported for '
                      'an analyst and never acted on.',
                 decl="[ValidateSet('high')]\n    [string]$MinimumRiskLevel = 'high'"),
            dict(name='LockoutAccepted',
                 help='Required for -Action BlockSignIn. Confirms that locking these accounts out is '
                      'intended and that a false positive is an acceptable cost here.',
                 decl="[switch]$LockoutAccepted"),
            dict(name='ExcludeUser', help='UPNs never acted on, whatever their risk level.',
                 decl="[string[]]$ExcludeUser"),
            dict(name='MaxUsers', help='Ceiling on users acted on in one run.',
                 decl="[ValidateRange(1,1000)]\n    [int]$MaxUsers = 25")],
    perms='Microsoft Graph IdentityRiskyUser.ReadWrite.All, User.ReadWrite.All. Requires Entra ID P2.',
    actionVerb='Remediate risky user',
    reason='Identity Protection high-risk remediation',
    rollback='RevokeSessions cannot be undone but costs only a re-authentication. BlockSignIn is '
             'reversed by re-enabling the account. ConfirmCompromised writes to the risk record and '
             'is reversed by dismissing the risk.',
    notes='ASSIST-ONLY, and the parameter set enforces it: -MinimumRiskLevel accepts only "high". '
          'Medium and low risk users are reported and are structurally not actionable, because the '
          'workbook says ambiguous cases go to an analyst and a parameter that could be widened would '
          'not honour that. The three actions are ordered by how much they cost when wrong, and the '
          'most expensive one needs -LockoutAccepted on top of the approval.',
    examples=[("-Action RevokeSessions", 'REPORT ONLY. Lists high-risk users and raises an approval.'),
              ("-Action RevokeSessions -ApprovalReference APR-... -TicketReference INC0012345",
               'Revokes sessions for approved high-risk users.'),
              ("-Action BlockSignIn -LockoutAccepted -ApprovalReference APR-...",
               'Blocks sign-in. Locks the user out until an admin re-enables them.')],
    discover=graph("IdentityRiskyUser.ReadWrite.All','User.ReadWrite.All','User.Read.All") + r"""
if ($Action -eq 'BlockSignIn' -and -not $LockoutAccepted) {
    throw 'Refusing -Action BlockSignIn without -LockoutAccepted. A false-positive lockout costs a ' +
          'real user their working day, which is why this action needs a second explicit decision.'
}

$risky = @()
try {
    $risky = @(Get-MgRiskyUser -All -ErrorAction Stop)
} catch {
    throw ('Risky user data unavailable: {0}. This usually means the tenant lacks Entra ID P2.' -f $_.Exception.Message)
}

$reportedOnly = 0

foreach ($user in $risky) {
    if ("$($user.RiskState)" -notmatch '(?i)atRisk|confirmedCompromised') { continue }
    if ($ExcludeUser -and $ExcludeUser -contains $user.UserPrincipalName) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $user.UserPrincipalName `
            -Message 'Excluded by -ExcludeUser'
        continue
    }

    $level = "$($user.RiskLevel)"
    # -MinimumRiskLevel has a single-value ValidateSet, so this comparison can
    # only ever be against 'high'. Written as a comparison rather than a
    # hard-coded string so the constraint lives in one place - the parameter.
    $actionable = ($level -eq $MinimumRiskLevel)

    if (-not $actionable) {
        $reportedOnly++
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $user.UserPrincipalName -Message (
            'Reported for analyst - risk level {0} is not high-confidence. Not actionable.' -f $level)
    }

    $detections = @()
    try {
        $detections = @(Get-MgRiskDetection -Filter ("userId eq '{0}'" -f $user.Id) -Top 5 -ErrorAction Stop)
    } catch {
        Write-Verbose ('No risk detections readable for {0}' -f $user.UserPrincipalName)
    }

    if ($actionable -and ($results | Where-Object { $_.Actionable }).Count -ge $MaxUsers) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
            'Reached -MaxUsers ({0}). Further high-risk users were NOT queued this run.' -f $MaxUsers)
        continue
    }

    $results.Add([PSCustomObject]@{
        Name           = $user.UserPrincipalName
        Id             = $user.Id
        UserId         = $user.Id
        DisplayName    = $user.UserDisplayName
        RiskLevel      = $level
        RiskState      = "$($user.RiskState)"
        RiskDetail     = "$($user.RiskDetail)"
        LastUpdated    = $user.RiskLastUpdatedDateTime
        DetectionTypes = (($detections | ForEach-Object { $_.RiskEventType }) -join '; ')
        DetectionIps   = (($detections | ForEach-Object { $_.IpAddress }) -join '; ')
        RequestedAction= $Action
        Actionable     = $actionable
        AnalystNote    = if ($actionable) { '' }
                         else { ('Risk level {0} - the workbook assigns this case to an analyst. Not actionable by this script.' -f $level) }
    })
}

Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
    '{0} high-risk user(s) actionable; {1} reported for analyst review only.' -f
    ($results | Where-Object { $_.Actionable }).Count, $reportedOnly)
""",
    act=r"""
if (-not $item.Actionable) {
    $actions.Add([PSCustomObject]@{
        Name = $item.Name; Action = 'ReportedForAnalyst'; Detail = $item.AnalystNote; Succeeded = $true })
} else {
    switch ($item.RequestedAction) {
        'RevokeSessions' {
            Revoke-MgUserSignInSession -UserId $item.UserId -ErrorAction Stop | Out-Null
            $detail = 'Sessions revoked; the user re-authenticates on next access'
        }
        'ConfirmCompromised' {
            Confirm-MgRiskyUserCompromised -UserIds @($item.UserId) -ErrorAction Stop | Out-Null
            $detail = 'Marked confirmed-compromised in Identity Protection'
        }
        'BlockSignIn' {
            Update-MgUser -UserId $item.UserId -AccountEnabled:$false -ErrorAction Stop | Out-Null
            $detail = 'Sign-in BLOCKED; the account stays locked until an admin re-enables it'
        }
    }

    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
        '{0} applied to {1} risk user ({2}). {3}' -f
        $item.RequestedAction, $item.RiskLevel, $item.DetectionTypes, $detail)
    $actions.Add([PSCustomObject]@{
        Name = $item.Name; Action = $item.RequestedAction; Detail = $detail; Succeeded = $true })
}
"""),

4: dict(
    file='Get-PrivilegedAccountUsageReport',
    modules=['Microsoft.Graph.Authentication', 'Microsoft.Graph.Identity.DirectoryManagement', 'Microsoft.Graph.Reports'],
    synopsis='Reports privileged role membership and privileged actions taken.',
    desc='Reports who currently holds a privileged directory role and what privileged operations were '
         'performed over the reporting window. Standing membership and actual use are different '
         'questions, and both are answered here - an account with permanent Global Administrator and '
         'no activity is its own kind of finding.',
    params=[dict(name='LookbackHours', help='Reporting window for privileged actions.',
                 decl="[ValidateRange(1,720)]\n    [int]$LookbackHours = 24"),
            dict(name='PrivilegedRole', help='Roles considered privileged.',
                 decl="[string[]]$PrivilegedRole = @('Global Administrator','Privileged Role Administrator','Security Administrator','Exchange Administrator','SharePoint Administrator','User Administrator','Application Administrator','Conditional Access Administrator')"),
            dict(name='MaxAuditRecords', help='Ceiling on audit records retrieved.',
                 decl="[ValidateRange(50,10000)]\n    [int]$MaxAuditRecords = 2000")],
    perms='Microsoft Graph RoleManagement.Read.Directory, AuditLog.Read.All, Directory.Read.All.',
    notes='Standing (permanent) membership is separated from eligible (PIM) membership in the report. '
          'The distinction matters more than the count: ten eligible admins who activate with '
          'justification is a healthier posture than three permanent ones.',
    examples=[("-LookbackHours 24 -OutputFormat HTML", 'Daily privileged usage report.'),
              ("-LookbackHours 168 -PrivilegedRole 'Global Administrator'", 'A week of Global Admin activity.')],
    discover=graph("RoleManagement.Read.Directory','AuditLog.Read.All','Directory.Read.All") + r"""
$roles = @(Get-MgDirectoryRole -All -ErrorAction Stop)
$privilegedIds = @{}

foreach ($role in $roles) {
    if ($PrivilegedRole -notcontains $role.DisplayName) { continue }

    $members = @()
    try { $members = @(Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id -All -ErrorAction Stop) } catch {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $role.DisplayName `
            -Message ('Members unreadable: {0}' -f $_.Exception.Message)
        continue
    }

    foreach ($member in $members) {
        $upn = $member.AdditionalProperties.userPrincipalName
        if (-not $upn) { $upn = $member.AdditionalProperties.displayName }
        $privilegedIds[$member.Id] = $upn

        $results.Add([PSCustomObject]@{
            Name           = ('{0} / {1}' -f $role.DisplayName, $upn)
            Id             = $member.Id
            RecordType     = 'Membership'
            RoleName       = $role.DisplayName
            Principal      = $upn
            PrincipalType  = ($member.AdditionalProperties.'@odata.type' -replace '#microsoft.graph.', '')
            Assignment     = 'Standing (permanent)'
            Operation      = ''
            ActivityTime   = $null
            Result         = ''
            Detail         = 'Permanent membership - active whether or not it is being used'
        })
    }
}

# Eligible (PIM) assignments are a different posture from permanent ones.
try {
    $eligible = @(Get-MgRoleManagementDirectoryRoleEligibilityScheduleInstance -All -ErrorAction Stop)
    foreach ($e in $eligible) {
        $roleName = ''
        try {
            $def = Get-MgRoleManagementDirectoryRoleDefinition -UnifiedRoleDefinitionId $e.RoleDefinitionId -ErrorAction Stop
            $roleName = $def.DisplayName
        } catch { $roleName = $e.RoleDefinitionId }
        if ($PrivilegedRole -notcontains $roleName) { continue }

        $results.Add([PSCustomObject]@{
            Name          = ('{0} / {1}' -f $roleName, $e.PrincipalId)
            Id            = $e.Id
            RecordType    = 'Membership'
            RoleName      = $roleName
            Principal     = $e.PrincipalId
            PrincipalType = 'user'
            Assignment    = 'Eligible (PIM)'
            Operation     = ''
            ActivityTime  = $null
            Result        = ''
            Detail        = 'Eligible only - requires activation, which is the healthier posture'
        })
    }
} catch {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
        'PIM eligibility unavailable ({0}); standing membership is reported without it. This is a ' +
        'P2 feature and its absence is not evidence that nobody is eligible.' -f $_.Exception.Message)
}

# What was actually done.
$since = (Get-Date).AddHours(-$LookbackHours).ToString('yyyy-MM-ddTHH:mm:ssZ')
try {
    $audit = @(Get-MgAuditLogDirectoryAudit -Filter ("activityDateTime ge {0}" -f $since) -Top $MaxAuditRecords -ErrorAction Stop)
    foreach ($record in $audit) {
        $actor = $record.InitiatedBy.User.UserPrincipalName
        if (-not $actor) { continue }
        if (-not ($privilegedIds.Values -contains $actor)) { continue }

        $results.Add([PSCustomObject]@{
            Name          = ('{0}: {1}' -f $actor, $record.ActivityDisplayName)
            Id            = $record.Id
            RecordType    = 'Activity'
            RoleName      = ''
            Principal     = $actor
            PrincipalType = 'user'
            Assignment    = ''
            Operation     = $record.ActivityDisplayName
            ActivityTime  = $record.ActivityDateTime
            Result        = "$($record.Result)"
            Detail        = (($record.TargetResources | ForEach-Object { $_.DisplayName }) -join '; ')
        })
    }
} catch {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
        'Directory audit log unavailable: {0}. Membership is reported without activity.' -f $_.Exception.Message)
}
"""),

5: dict(
    file='Get-MultiCloudPostureReport',
    modules=['Az.Accounts'],
    synopsis='Reports cloud security posture from each cloud, side by side.',
    desc='Collects the security posture score and finding counts from each cloud that is reachable '
         'and reports them alongside each other. It does not blend them into a single number, and '
         'the reason is in the notes.',
    params=[SUB_PARAM,
            dict(name='IncludeCloud', help='Which clouds to query.',
                 decl="[ValidateSet('Azure','AWS','OCI','All')]\n    [string[]]$IncludeCloud = @('All')"),
            dict(name='AwsRegion', help='AWS region for Security Hub.',
                 decl="[string]$AwsRegion"),
            dict(name='OciCompartmentId', help='OCI compartment for Cloud Guard problems.',
                 decl="[string]$OciCompartmentId")],
    perms='Security Reader in Azure; securityhub:GetFindings in AWS; Cloud Guard read in OCI.',
    notes='NO BLENDED SCORE IS PRODUCED, deliberately. Azure Secure Score, AWS Security Hub and OCI '
          'Cloud Guard measure different control sets on different scales with different weightings; '
          'averaging them produces a number that moves for reasons nobody can explain and that means '
          'nothing to any of the three teams. Each cloud is reported on its own scale, and finding '
          'counts by severity - which ARE comparable - are totalled. A cloud that could not be '
          'queried is reported as NOT QUERIED rather than omitted, because a missing cloud silently '
          'improves any total it is left out of.',
    examples=[("-IncludeCloud All -OutputFormat HTML", 'Posture from every reachable cloud.'),
              ("-IncludeCloud Azure,AWS -AwsRegion me-central-1", 'Azure and AWS only.')],
    discover=r"""
$wanted = if ($IncludeCloud -contains 'All') { @('Azure', 'AWS', 'OCI') } else { $IncludeCloud }

function Add-PostureRecord {
    <#
        .SYNOPSIS
            One posture row, in a shape shared by every cloud.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param($Cloud, $Metric, $Value, $Scale, $Critical, $High, $Medium, $Low, $Status, $Detail)

    [PSCustomObject]@{
        Name = ('{0}: {1}' -f $Cloud, $Metric); Id = ('{0}-{1}' -f $Cloud, $Metric)
        Cloud = $Cloud; Metric = $Metric; Value = $Value; Scale = $Scale
        Critical = $Critical; High = $High; Medium = $Medium; Low = $Low
        Status = $Status; Detail = $Detail
    }
}

# ---- Azure -------------------------------------------------------------
if ($wanted -contains 'Azure') {
    try {
        $azContext = Get-AzContext -ErrorAction Stop
        if ($SubscriptionId -and $azContext.Subscription.Id -ne $SubscriptionId) {
            $azContext = Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop
        }

        $scorePath = '/subscriptions/{0}/providers/Microsoft.Security/secureScores/ascScore?api-version=2020-01-01' -f $azContext.Subscription.Id
        $scoreResponse = Invoke-AzRestMethod -Path $scorePath -Method GET -ErrorAction Stop
        $score = ($scoreResponse.Content | ConvertFrom-Json).properties.score

        $assessPath = '/subscriptions/{0}/providers/Microsoft.Security/assessments?api-version=2020-01-01' -f $azContext.Subscription.Id
        $assessResponse = Invoke-AzRestMethod -Path $assessPath -Method GET -ErrorAction Stop
        $unhealthy = @(($assessResponse.Content | ConvertFrom-Json).value |
                       Where-Object { $_.properties.status.code -eq 'Unhealthy' })

        $results.Add((Add-PostureRecord -Cloud 'Azure' -Metric 'Secure Score' `
            -Value $(if ($score) { [math]::Round($score.percentage * 100, 1) } else { $null }) `
            -Scale 'Azure Secure Score, 0-100% of achievable points' `
            -Critical @($unhealthy | Where-Object { $_.properties.metadata.severity -eq 'High' }).Count `
            -High 0 `
            -Medium @($unhealthy | Where-Object { $_.properties.metadata.severity -eq 'Medium' }).Count `
            -Low @($unhealthy | Where-Object { $_.properties.metadata.severity -eq 'Low' }).Count `
            -Status 'Queried' `
            -Detail ('{0} unhealthy assessment(s). Azure reports High/Medium/Low, so Critical carries the High count.' -f $unhealthy.Count)))
    } catch {
        $results.Add((Add-PostureRecord -Cloud 'Azure' -Metric 'Secure Score' -Value $null `
            -Scale '' -Critical $null -High $null -Medium $null -Low $null `
            -Status 'NOT QUERIED' -Detail ('Failed: {0}' -f $_.Exception.Message)))
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message ('Azure posture not collected: {0}' -f $_.Exception.Message)
    }
}

# ---- AWS ---------------------------------------------------------------
if ($wanted -contains 'AWS') {
    try {
        Import-Module AWS.Tools.SecurityHub -ErrorAction Stop
        $findingParams = @{ ErrorAction = 'Stop' }
        if ($AwsRegion) { $findingParams.Region = $AwsRegion }
        $findings = @(Get-SHUBFinding @findingParams |
                      Where-Object { "$($_.RecordState)" -eq 'ACTIVE' -and "$($_.Workflow.Status)" -ne 'SUPPRESSED' })

        $results.Add((Add-PostureRecord -Cloud 'AWS' -Metric 'Security Hub findings' -Value $findings.Count `
            -Scale 'AWS Security Hub, count of active findings (no percentage equivalent)' `
            -Critical @($findings | Where-Object { $_.Severity.Label -eq 'CRITICAL' }).Count `
            -High @($findings | Where-Object { $_.Severity.Label -eq 'HIGH' }).Count `
            -Medium @($findings | Where-Object { $_.Severity.Label -eq 'MEDIUM' }).Count `
            -Low @($findings | Where-Object { $_.Severity.Label -eq 'LOW' }).Count `
            -Status 'Queried' -Detail 'Suppressed and archived findings excluded'))
    } catch {
        $results.Add((Add-PostureRecord -Cloud 'AWS' -Metric 'Security Hub findings' -Value $null `
            -Scale '' -Critical $null -High $null -Medium $null -Low $null `
            -Status 'NOT QUERIED' -Detail ('Failed: {0}' -f $_.Exception.Message)))
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message ('AWS posture not collected: {0}' -f $_.Exception.Message)
    }
}

# ---- OCI ---------------------------------------------------------------
if ($wanted -contains 'OCI') {
    try {
        $ociCli = (Get-Command -Name 'oci' -ErrorAction Stop).Source
        if (-not $OciCompartmentId) { throw 'No -OciCompartmentId supplied.' }

        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $raw = & $ociCli cloud-guard problem list --compartment-id $OciCompartmentId --output json
            $exit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        if ($exit -ne 0) { throw ('oci cloud-guard exited {0}' -f $exit) }

        $problems = @(((@($raw) -join "`n") | ConvertFrom-Json).data.items)
        $results.Add((Add-PostureRecord -Cloud 'OCI' -Metric 'Cloud Guard problems' -Value $problems.Count `
            -Scale 'OCI Cloud Guard, count of open problems (no percentage equivalent)' `
            -Critical @($problems | Where-Object { "$($_.'risk-level')" -eq 'CRITICAL' }).Count `
            -High @($problems | Where-Object { "$($_.'risk-level')" -eq 'HIGH' }).Count `
            -Medium @($problems | Where-Object { "$($_.'risk-level')" -eq 'MEDIUM' }).Count `
            -Low @($problems | Where-Object { "$($_.'risk-level')" -eq 'LOW' }).Count `
            -Status 'Queried' -Detail 'Open Cloud Guard problems in the compartment'))
    } catch {
        $results.Add((Add-PostureRecord -Cloud 'OCI' -Metric 'Cloud Guard problems' -Value $null `
            -Scale '' -Critical $null -High $null -Medium $null -Low $null `
            -Status 'NOT QUERIED' -Detail ('Failed: {0}' -f $_.Exception.Message)))
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message ('OCI posture not collected: {0}' -f $_.Exception.Message)
    }
}

# Severity counts ARE comparable across clouds. Scores are not, and are not blended.
$queried = @($results | Where-Object { $_.Status -eq 'Queried' })
$notQueried = @($results | Where-Object { $_.Status -eq 'NOT QUERIED' })

$results.Add((Add-PostureRecord -Cloud 'ALL' -Metric 'Findings by severity' -Value $null `
    -Scale 'Counts only. NO blended score is produced - the three scales are not comparable.' `
    -Critical (($queried | Measure-Object Critical -Sum).Sum) `
    -High (($queried | Measure-Object High -Sum).Sum) `
    -Medium (($queried | Measure-Object Medium -Sum).Sum) `
    -Low (($queried | Measure-Object Low -Sum).Sum) `
    -Status $(if ($notQueried.Count -gt 0) { 'PARTIAL' } else { 'Complete' }) `
    -Detail ('{0} cloud(s) queried, {1} NOT queried ({2}). A total that omits a cloud understates it.' -f
        $queried.Count, $notQueried.Count, (($notQueried | ForEach-Object { $_.Cloud }) -join ', '))))

if ($notQueried.Count -gt 0) {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
        '{0} cloud(s) could not be queried. The totals below are PARTIAL.' -f $notQueried.Count)
}
"""),

6: dict(
    file='Start-VulnerabilityScan',
    modules=[],
    synopsis='Triggers a vulnerability scan and exports the results.',
    desc='Launches a scan on the configured scanner - typically after a patch window - and exports '
         'the findings. Additive: the scan reads the estate, it does not change it.',
    params=[dict(name='Scanner', help='Scanner platform.',
                 decl="[ValidateSet('tenable-io','tenable-sc','qualys')]\n    [string]$Scanner = 'tenable-io'"),
            dict(name='ScanId', help='Scan id(s) to launch.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$ScanId"),
            dict(name='ApiBaseUrl', help='Scanner API base URL. Falls back to vulnerability.apiBaseUrl in config.json.',
                 decl="[string]$ApiBaseUrl"),
            dict(name='AccessKey', help='API access key as a SecureString.',
                 decl="[System.Security.SecureString]$AccessKey"),
            dict(name='SecretKey', help='API secret key as a SecureString.',
                 decl="[System.Security.SecureString]$SecretKey"),
            dict(name='WaitForCompletion', help='Wait for the scan to finish and export the results.',
                 decl="[switch]$WaitForCompletion"),
            dict(name='WaitTimeoutMinutes', help='Give up waiting after this long. The scan keeps running.',
                 decl="[ValidateRange(1,1440)]\n    [int]$WaitTimeoutMinutes = 120"),
            dict(name='ExportPath', help='Directory to write exported results to.',
                 decl="[string]$ExportPath")],
    perms='A scanner API account with permission to launch the named scans.',
    actionVerb='Launch vulnerability scan',
    rollback='Stop the scan from the scanner console. A scan changes nothing on the targets, so there '
             'is nothing to undo beyond the load it generates.',
    notes='A scan is read-only against the estate but it is not free: credentialed scans generate '
          'real load and can trip intrusion detection. Run it in the window, not alongside the patch '
          'job. The Qualys endpoint paths differ enough between deployments that they are exposed as '
          'a parameter rather than assumed - see MANIFEST.md under Needs Input.',
    examples=[("-Scanner tenable-io -ScanId 42 -WaitForCompletion -ExportPath .\\\\scans",
               'Post-patch scan, waits and exports.'),
              ("-Scanner tenable-io -ScanId 42,43 -WhatIf", 'Shows the scans that would launch.')],
    discover=r"""
if (-not $ApiBaseUrl) {
    if ($config -and $config.vulnerability -and $config.vulnerability.apiBaseUrl) {
        $ApiBaseUrl = $config.vulnerability.apiBaseUrl
    }
}
if (-not $ApiBaseUrl) {
    throw 'No scanner API URL. Pass -ApiBaseUrl or set vulnerability.apiBaseUrl in config.json.'
}
if (-not $AccessKey -or -not $SecretKey) {
    throw 'Both -AccessKey and -SecretKey are required, as SecureStrings. Scanner API keys are never read from configuration.'
}

$scanBase = $ApiBaseUrl.TrimEnd('/')

# Both halves of the key are needed in the header, so each exists as a plain
# string only for as long as the header is built. Both BSTRs are zeroed.
$accessPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AccessKey)
$secretPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecretKey)
try {
    $accessPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($accessPtr)
    $secretPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($secretPtr)
    $scanHeaders = switch ($Scanner) {
        'qualys'   { @{ 'X-Requested-With' = 'ITAutomation'; 'Authorization' = ('Basic {0}' -f
                        [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(('{0}:{1}' -f $accessPlain, $secretPlain)))) } }
        default    { @{ 'X-ApiKeys' = ('accessKey={0};secretKey={1}' -f $accessPlain, $secretPlain); 'Accept' = 'application/json' } }
    }
} finally {
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($accessPtr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secretPtr)
    Remove-Variable -Name accessPlain, secretPlain -ErrorAction SilentlyContinue
}

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

foreach ($id in $ScanId) {
    $detail = $null
    if ($Scanner -ne 'qualys') {
        try {
            $detail = Invoke-RestMethod -Uri ('{0}/scans/{1}' -f $scanBase, $id) -Headers $scanHeaders `
                -Method GET -ErrorAction Stop
        } catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $id `
                -Message ('Scan detail unreadable: {0}' -f $_.Exception.Message)
        }

        $currentStatus = "$($detail.info.status)"
        if ($currentStatus -match '(?i)running|pending') {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $id `
                -Message ('Skipped - scan is already {0}' -f $currentStatus)
            continue
        }
    }

    $results.Add([PSCustomObject]@{
        Name        = ('{0} scan {1}' -f $Scanner, $id)
        Id          = $id
        ScanId      = $id
        Scanner     = $Scanner
        ScanName    = $detail.info.name
        LastStatus  = "$($detail.info.status)"
        Targets     = $detail.info.targets
        ApiBase     = $scanBase
        WillWait    = [bool]$WaitForCompletion
    })
}
""",
    act=r"""
$launchUri = switch ($item.Scanner) {
    'qualys' { '{0}/api/2.0/fo/scan/?action=launch&scan_ref={1}' -f $item.ApiBase, $item.ScanId }
    default  { '{0}/scans/{1}/launch' -f $item.ApiBase, $item.ScanId }
}
$launch = Invoke-RestMethod -Uri $launchUri -Headers $scanHeaders -Method POST -ErrorAction Stop

$uuid = $launch.scan_uuid
Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Scan launched{0}' -f $(if ($uuid) { ' (uuid ' + $uuid + ')' } else { '' }))

$finalStatus = 'launched'
if ($item.WillWait -and $item.Scanner -ne 'qualys') {
    $deadline = (Get-Date).AddMinutes($WaitTimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 60
        $poll = Invoke-RestMethod -Uri ('{0}/scans/{1}' -f $item.ApiBase, $item.ScanId) `
            -Headers $scanHeaders -Method GET -ErrorAction Stop
        $finalStatus = "$($poll.info.status)"
        if ($finalStatus -notmatch '(?i)running|pending') { break }
    }

    if ($finalStatus -match '(?i)running|pending') {
        # The scan is still going. Saying so beats reporting a timeout as a result.
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
            'Still {0} after {1} minute(s). The scan CONTINUES on the scanner; only the wait ended. No results exported.' -f
            $finalStatus, $WaitTimeoutMinutes)
    } elseif ($ExportPath) {
        if (-not (Test-Path -LiteralPath $ExportPath)) {
            New-Item -Path $ExportPath -ItemType Directory -Force | Out-Null
        }
        $exportFile = Join-Path $ExportPath ('scan-{0}-{1}.json' -f $item.ScanId, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $poll | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $exportFile -Encoding UTF8
        Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
            'Scan {0}; results exported to {1}' -f $finalStatus, $exportFile)
    }
}

$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'ScanLaunched'; Detail = $finalStatus; Succeeded = $true })
"""),

7: dict(
    file='Get-CertificateExpiryReport',
    modules=[],
    synopsis='Checks TLS certificate expiry by connecting to each endpoint.',
    desc='Opens a TLS connection to each endpoint and reads the certificate the server actually '
         'presents. That is the measurement that matters: a certificate renewed in the vault but not '
         'deployed to the load balancer still expires in production.',
    params=[dict(name='Endpoint', help='Endpoints to check, as host or host:port.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$Endpoint"),
            dict(name='WarnDays', help='Warn on certificates expiring within this many days.',
                 decl="[ValidateRange(1,730)]\n    [int]$WarnDays = 30"),
            dict(name='CriticalDays', help='Report as critical within this many days.',
                 decl="[ValidateRange(1,365)]\n    [int]$CriticalDays = 7"),
            dict(name='TimeoutSeconds', help='Connection timeout per endpoint.',
                 decl="[ValidateRange(1,120)]\n    [int]$TimeoutSeconds = 10"),
            dict(name='IssuesOnly', help='Report only endpoints with a finding.',
                 decl="[switch]$IssuesOnly")],
    perms='Network access to each endpoint on its TLS port. No platform credentials are needed.',
    notes='This checks what is SERVED, not what is stored. A certificate renewed in Key Vault or ACM '
          'but not yet bound to the listener will pass every inventory check and still take the site '
          'down on expiry day - connecting is the only way to catch that. Certificate validation is '
          'deliberately not enforced during the probe, so that an ALREADY-EXPIRED or self-signed '
          'certificate is reported rather than causing the connection to fail and the endpoint to '
          'look unreachable.',
    examples=[("-Endpoint www.contoso.com,api.contoso.com:8443 -WarnDays 30",
               'Checks two endpoints, one on a non-default port.'),
              ("-Endpoint www.contoso.com -IssuesOnly -CriticalDays 14", 'Only report if action is needed.')],
    discover=r"""
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
$now = Get-Date

foreach ($target in $Endpoint) {
    $parts = $target -split ':', 2
    $hostName = $parts[0]
    $port = if ($parts.Count -eq 2) { [int]$parts[1] } else { 443 }

    $tcpClient = $null
    $sslStream = $null
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $connect = $tcpClient.BeginConnect($hostName, $port, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))) {
            throw ('Connection timed out after {0}s' -f $TimeoutSeconds)
        }
        $tcpClient.EndConnect($connect)

        # Validation is accepted unconditionally on purpose: the goal is to READ
        # the certificate, including an expired or untrusted one. Rejecting it
        # here would report a genuinely expired certificate as an unreachable
        # host, which is the wrong alert entirely.
        $sslStream = New-Object System.Net.Security.SslStream($tcpClient.GetStream(), $false,
            ([System.Net.Security.RemoteCertificateValidationCallback] { $true }))
        $sslStream.AuthenticateAsClient($hostName)

        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($sslStream.RemoteCertificate)
        $daysLeft = [math]::Round(($cert.NotAfter - $now).TotalDays, 1)

        $status = if ($cert.NotAfter -lt $now) { 'EXPIRED' }
                  elseif ($daysLeft -le $CriticalDays) { 'Critical' }
                  elseif ($daysLeft -le $WarnDays) { 'Warning' }
                  else { 'OK' }

        if ($IssuesOnly -and $status -eq 'OK') { continue }

        $sanList = ''
        $sanExtension = $cert.Extensions | Where-Object { $_.Oid.FriendlyName -eq 'Subject Alternative Name' }
        if ($sanExtension) { $sanList = ($sanExtension.Format($false) -replace 'DNS Name=', '') }

        $results.Add([PSCustomObject]@{
            Name        = $target
            Id          = $target
            HostName    = $hostName
            Port        = $port
            Subject     = $cert.Subject
            Issuer      = $cert.Issuer
            NotBefore   = $cert.NotBefore
            NotAfter    = $cert.NotAfter
            DaysLeft    = $daysLeft
            Thumbprint  = $cert.Thumbprint
            SignatureAlgorithm = $cert.SignatureAlgorithm.FriendlyName
            SubjectAltNames = $sanList
            NameMatches = ($cert.Subject -match [regex]::Escape($hostName)) -or ($sanList -match [regex]::Escape($hostName))
            Status      = $status
            Error       = ''
        })

        if ($status -ne 'OK') {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $target -Message (
                '{0}: expires {1:yyyy-MM-dd} ({2} day(s))' -f $status, $cert.NotAfter, $daysLeft)
        }
    } catch {
        $results.Add([PSCustomObject]@{
            Name = $target; Id = $target; HostName = $hostName; Port = $port
            Subject = ''; Issuer = ''; NotBefore = $null; NotAfter = $null; DaysLeft = $null
            Thumbprint = ''; SignatureAlgorithm = ''; SubjectAltNames = ''; NameMatches = $false
            Status = 'Unreachable'; Error = $_.Exception.Message
        })
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $target -Message (
            'Unreachable - certificate NOT checked: {0}' -f $_.Exception.Message)
    } finally {
        if ($sslStream) { $sslStream.Dispose() }
        if ($tcpClient) { $tcpClient.Dispose() }
    }
}
"""),

8: dict(
    file='Get-FirewallRuleChangeAudit',
    modules=['Az.Accounts', 'Az.Monitor'],
    synopsis='Reports firewall and security group rule changes.',
    desc='Reads the control-plane change record for network security rules and reports every '
         'modification with who made it and when. Read-only: it audits changes, it does not reverse '
         'them.',
    params=[SUB_PARAM,
            dict(name='LookbackHours', help='Reporting window.',
                 decl="[ValidateRange(1,720)]\n    [int]$LookbackHours = 24"),
            dict(name='IncludeCloud', help='Which clouds to audit.',
                 decl="[ValidateSet('Azure','AWS','All')]\n    [string[]]$IncludeCloud = @('All')"),
            dict(name='AwsRegion', help='AWS region for CloudTrail.',
                 decl="[string]$AwsRegion")],
    perms='Reader on the Azure subscription; cloudtrail:LookupEvents in AWS.',
    notes='The Azure Activity Log retains 90 days and AWS CloudTrail event history 90 days by '
          'default. A lookback longer than that returns nothing for the earlier part of the window '
          'and says so, rather than presenting a short answer as a complete one. Palo Alto and other '
          'appliance firewalls are not covered here - their change logs are on the appliance and '
          'need their own credentials.',
    examples=[("-LookbackHours 24 -OutputFormat HTML", 'Yesterday\'s rule changes across clouds.'),
              ("-IncludeCloud Azure -LookbackHours 168", 'A week of Azure NSG and firewall changes.')],
    discover=r"""
$wanted = if ($IncludeCloud -contains 'All') { @('Azure', 'AWS') } else { $IncludeCloud }
$since = (Get-Date).AddHours(-$LookbackHours)

if ($LookbackHours -gt (90 * 24)) {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
        'A {0}h lookback exceeds the 90-day default retention of both sources. Results before that ' +
        'point are missing, not empty.' -f $LookbackHours)
}

if ($wanted -contains 'Azure') {
    try {
        $azContext = Get-AzContext -ErrorAction Stop
        if ($SubscriptionId -and $azContext.Subscription.Id -ne $SubscriptionId) {
            $azContext = Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop
        }

        $events = @(Get-AzLog -StartTime $since -EndTime (Get-Date) -MaxRecord 1000 -WarningAction SilentlyContinue -ErrorAction Stop)
        $ruleEvents = @($events | Where-Object {
            "$($_.Authorization.Action)" -match '(?i)networkSecurityGroups|azureFirewalls|firewallPolicies|securityRules' -and
            "$($_.Authorization.Action)" -match '(?i)/write$|/delete$'
        })

        foreach ($e in $ruleEvents) {
            $results.Add([PSCustomObject]@{
                Name        = ('{0}: {1}' -f $e.Caller, $e.Authorization.Action)
                Id          = $e.Id
                Cloud       = 'Azure'
                ChangedAt   = $e.EventTimestamp
                Caller      = $e.Caller
                Operation   = $e.Authorization.Action
                ResourceId  = $e.ResourceId
                ResourceType= $e.ResourceType.Value
                Status      = "$($e.Status.Value)"
                SourceIp    = $e.HttpRequest.ClientIpAddress
                CorrelationId = $e.CorrelationId
                Detail      = $e.SubStatus.Value
            })
        }
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Azure: {0} network security rule change(s) in the window.' -f $ruleEvents.Count)
    } catch {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
            'Azure change audit NOT collected: {0}' -f $_.Exception.Message)
    }
}

if ($wanted -contains 'AWS') {
    try {
        Import-Module AWS.Tools.CloudTrail -ErrorAction Stop
        $lookupParams = @{
            StartTime   = $since
            EndTime     = (Get-Date)
            ErrorAction = 'Stop'
        }
        if ($AwsRegion) { $lookupParams.Region = $AwsRegion }

        $sgEventNames = @('AuthorizeSecurityGroupIngress', 'AuthorizeSecurityGroupEgress',
                          'RevokeSecurityGroupIngress', 'RevokeSecurityGroupEgress',
                          'CreateSecurityGroup', 'DeleteSecurityGroup',
                          'CreateNetworkAclEntry', 'DeleteNetworkAclEntry')

        foreach ($eventName in $sgEventNames) {
            $attr = New-Object Amazon.CloudTrail.Model.LookupAttribute
            $attr.AttributeKey = 'EventName'
            $attr.AttributeValue = $eventName
            $found = @(Find-CTEvent @lookupParams -LookupAttribute $attr)

            foreach ($e in $found) {
                $results.Add([PSCustomObject]@{
                    Name        = ('{0}: {1}' -f $e.Username, $e.EventName)
                    Id          = $e.EventId
                    Cloud       = 'AWS'
                    ChangedAt   = $e.EventTime
                    Caller      = $e.Username
                    Operation   = $e.EventName
                    ResourceId  = (($e.Resources | ForEach-Object { $_.ResourceName }) -join '; ')
                    ResourceType= (($e.Resources | ForEach-Object { $_.ResourceType }) -join '; ')
                    Status      = 'Recorded'
                    SourceIp    = ''
                    CorrelationId = $e.EventId
                    Detail      = $e.EventSource
                })
            }
        }
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'AWS: {0} security group / NACL change event(s) in the window.' -f
            @($results | Where-Object { $_.Cloud -eq 'AWS' }).Count)
    } catch {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
            'AWS change audit NOT collected: {0}' -f $_.Exception.Message)
    }
}
"""),

9: dict(
    file='Get-CisBenchmarkCompliance',
    modules=['Az.Accounts', 'Az.PolicyInsights'],
    synopsis='Reports CIS benchmark compliance from cloud-native policy engines.',
    desc='Reads compliance state from Azure Policy and AWS Config for the CIS initiatives already '
         'assigned there, and reports the pass rate per control. It does not implement its own '
         'benchmark checks - the cloud providers maintain theirs, and a second opinion computed here '
         'would just be a worse one.',
    params=[SUB_PARAM,
            dict(name='InitiativeNameFilter', help='Substring identifying the CIS initiative assignment in Azure Policy.',
                 decl="[string]$InitiativeNameFilter = 'CIS'"),
            dict(name='IncludeCloud', help='Which clouds to query.',
                 decl="[ValidateSet('Azure','AWS','All')]\n    [string[]]$IncludeCloud = @('All')"),
            dict(name='ConformancePackName', help='AWS Config conformance pack carrying the CIS rules.',
                 decl="[string]$ConformancePackName"),
            dict(name='AwsRegion', help='AWS region for Config.',
                 decl="[string]$AwsRegion"),
            dict(name='NonCompliantOnly', help='Report only failing controls.',
                 decl="[switch]$NonCompliantOnly")],
    perms='Reader plus Security Reader in Azure; config:Describe* in AWS.',
    notes='This reports what the cloud\'s own policy engine already evaluated. If no CIS initiative '
          'is assigned in Azure Policy, or no conformance pack deployed in AWS Config, the script '
          'reports that nothing is being evaluated rather than reporting zero failures - which would '
          'read as a clean bill of health for a benchmark nobody is running.',
    examples=[("-IncludeCloud All -NonCompliantOnly -OutputFormat HTML",
               'Failing CIS controls across Azure and AWS.'),
              ("-IncludeCloud Azure -InitiativeNameFilter 'CIS Microsoft Azure Foundations'",
               'One specific Azure initiative.')],
    discover=r"""
$wanted = if ($IncludeCloud -contains 'All') { @('Azure', 'AWS') } else { $IncludeCloud }

if ($wanted -contains 'Azure') {
    try {
        $azContext = Get-AzContext -ErrorAction Stop
        if ($SubscriptionId -and $azContext.Subscription.Id -ne $SubscriptionId) {
            $azContext = Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop
        }

        $states = @(Get-AzPolicyState -ErrorAction Stop |
                    Where-Object { "$($_.PolicySetDefinitionName)" -match [regex]::Escape($InitiativeNameFilter) -or
                                   "$($_.PolicyDefinitionReferenceId)" -match [regex]::Escape($InitiativeNameFilter) })

        if ($states.Count -eq 0) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'No Azure Policy states matched "{0}". NOTHING is being evaluated against CIS in this ' +
                'subscription - that is not the same as passing.' -f $InitiativeNameFilter)
        }

        foreach ($group in ($states | Group-Object PolicyDefinitionName)) {
            $nonCompliant = @($group.Group | Where-Object { "$($_.ComplianceState)" -eq 'NonCompliant' })
            if ($NonCompliantOnly -and $nonCompliant.Count -eq 0) { continue }

            $results.Add([PSCustomObject]@{
                Name            = $group.Name
                Id              = $group.Name
                Cloud           = 'Azure'
                Control         = $group.Name
                Evaluated       = $group.Count
                Compliant       = ($group.Count - $nonCompliant.Count)
                NonCompliant    = $nonCompliant.Count
                CompliancePercent = if ($group.Count -gt 0) { [math]::Round((($group.Count - $nonCompliant.Count) / $group.Count) * 100, 1) } else { $null }
                Status          = if ($nonCompliant.Count -gt 0) { 'NonCompliant' } else { 'Compliant' }
                FailingResources= (($nonCompliant | Select-Object -First 5 | ForEach-Object { $_.ResourceId }) -join '; ')
            })
        }
    } catch {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
            'Azure CIS compliance NOT collected: {0}' -f $_.Exception.Message)
    }
}

if ($wanted -contains 'AWS') {
    try {
        Import-Module AWS.Tools.ConfigService -ErrorAction Stop
        if (-not $ConformancePackName) {
            throw 'No -ConformancePackName supplied; AWS Config cannot be queried for CIS without one.'
        }
        $packParams = @{ ConformancePackName = $ConformancePackName; ErrorAction = 'Stop' }
        if ($AwsRegion) { $packParams.Region = $AwsRegion }

        $ruleCompliance = @(Get-CFGConformancePackCompliance @packParams)

        foreach ($rule in $ruleCompliance) {
            $isCompliant = "$($rule.ComplianceType)" -eq 'COMPLIANT'
            if ($NonCompliantOnly -and $isCompliant) { continue }

            $results.Add([PSCustomObject]@{
                Name            = $rule.ConfigRuleName
                Id              = $rule.ConfigRuleName
                Cloud           = 'AWS'
                Control         = $rule.ConfigRuleName
                Evaluated       = 1
                Compliant       = if ($isCompliant) { 1 } else { 0 }
                NonCompliant    = if ($isCompliant) { 0 } else { 1 }
                CompliancePercent = if ($isCompliant) { 100 } else { 0 }
                Status          = "$($rule.ComplianceType)"
                FailingResources= ''
            })
        }
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'AWS conformance pack "{0}": {1} rule(s) evaluated.' -f $ConformancePackName, $ruleCompliance.Count)
    } catch {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
            'AWS CIS compliance NOT collected: {0}' -f $_.Exception.Message)
    }
}
"""),

10: dict(
    file='Invoke-EdrAlertTriage',
    modules=['Microsoft.Graph.Authentication', 'Microsoft.Graph.Security'],
    synopsis='Enriches and tickets EDR alerts; isolates a device only when an analyst says so.',
    desc='Correlates Defender for Endpoint alerts by device, enriches them and raises tickets - the '
         'mechanical half of triage. Device isolation is available and is gated hard, because the '
         'workbook is explicit that isolating a production server is an analyst decision and not a '
         'rule.',
    params=[dict(name='LookbackHours', help='Alert window to triage.',
                 decl="[ValidateRange(1,168)]\n    [int]$LookbackHours = 24"),
            dict(name='MinimumSeverity', help='Lowest alert severity to triage.',
                 decl="[ValidateSet('high','medium','low')]\n    [string]$MinimumSeverity = 'medium'"),
            dict(name='IsolateDevice',
                 help='Device id(s) to isolate. Nothing is isolated unless named here - there is no '
                      'severity threshold that triggers isolation on its own.',
                 decl="[string[]]$IsolateDevice"),
            dict(name='ProductionImpactAssessed',
                 help='Required alongside -IsolateDevice. The analyst asserting they know what the '
                      'device does and what isolating it takes offline.',
                 decl="[switch]$ProductionImpactAssessed"),
            dict(name='ProductionNamePattern',
                 help='Devices matching these patterns are never isolated by this script, whatever '
                      'else is passed.',
                 decl="[string[]]$ProductionNamePattern = @('*PRD*','*PROD*','*DC0*','*SQL*')")],
    perms='Microsoft Graph SecurityAlert.ReadWrite.All; Machine.Isolate for the isolation path.',
    actionVerb='Triage EDR alert',
    reason='EDR alert triage',
    rollback='Tickets can be closed. An isolated device is released with the Defender release action; '
             'it stays cut off from everything except Defender until someone does that.',
    notes='ASSIST-ONLY, and the split follows the workbook exactly. Enrichment, correlation and '
          'ticketing run for every qualifying alert. Isolation runs for nothing unless a device is '
          'named in -IsolateDevice AND -ProductionImpactAssessed is passed AND the approval is valid '
          '- three separate acts by a human. There is deliberately no severity threshold that '
          'triggers isolation automatically, because that would be exactly the rule the guardrail '
          'says must not exist. Devices matching -ProductionNamePattern are refused outright.',
    examples=[("-LookbackHours 24 -MinimumSeverity high",
               'REPORT ONLY. Correlates and enriches alerts, raises an approval for ticketing.'),
              ("-LookbackHours 24 -ApprovalReference APR-... -TicketReference INC0012345",
               'Raises tickets for the correlated alerts. Isolates nothing.'),
              ("-IsolateDevice 'abc123' -ProductionImpactAssessed -ApprovalReference APR-...",
               'Isolates one named device after an analyst assessed the impact.')],
    discover=graph("SecurityAlert.ReadWrite.All','SecurityIncident.Read.All") + ITSM_HELPER + r"""
if ($IsolateDevice -and -not $ProductionImpactAssessed) {
    throw 'Refusing -IsolateDevice without -ProductionImpactAssessed. The workbook is explicit that ' +
          'isolating a production server is an analyst decision, not a rule; this flag is the analyst ' +
          'asserting they know what the device does.'
}

$severityRank = @{ 'high' = 3; 'medium' = 2; 'low' = 1 }
$floor = $severityRank[$MinimumSeverity]
$since = (Get-Date).AddHours(-$LookbackHours).ToString('yyyy-MM-ddTHH:mm:ssZ')

$alerts = @()
try {
    $response = Invoke-MgGraphRequest -Method GET -ErrorAction Stop `
        -Uri ('https://graph.microsoft.com/v1.0/security/alerts_v2?$filter=createdDateTime ge {0}&$top=500' -f $since)
    $alerts = @($response.value)
} catch {
    throw ('Security alerts could not be read: {0}' -f $_.Exception.Message)
}

# Correlated by device: five alerts on one machine is one investigation.
$byDevice = @{}
foreach ($alert in $alerts) {
    $rank = $severityRank["$($alert.severity)"]
    if (-not $rank -or $rank -lt $floor) { continue }
    if ("$($alert.status)" -match '(?i)resolved') { continue }

    $deviceId = ''
    $deviceName = ''
    foreach ($evidence in @($alert.evidence)) {
        if ($evidence.'@odata.type' -match 'deviceEvidence') {
            $deviceId = $evidence.mdeDeviceId
            $deviceName = $evidence.deviceDnsName
            break
        }
    }
    $key = if ($deviceId) { $deviceId } else { 'no-device' }

    if (-not $byDevice.ContainsKey($key)) {
        $byDevice[$key] = [PSCustomObject]@{
            DeviceId = $deviceId; DeviceName = $deviceName; Alerts = @()
        }
    }
    $byDevice[$key].Alerts += $alert
}

foreach ($key in $byDevice.Keys) {
    $group = $byDevice[$key]
    $highest = ($group.Alerts | Sort-Object { $severityRank["$($_.severity)"] } -Descending | Select-Object -First 1)

    $isProduction = $false
    foreach ($pattern in $ProductionNamePattern) {
        if ($group.DeviceName -like $pattern) { $isProduction = $true; break }
    }

    $isolationRequested = ($IsolateDevice -and $IsolateDevice -contains $group.DeviceId)
    if ($isolationRequested -and $isProduction) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $group.DeviceName -Message (
            'ISOLATION REFUSED - device matches a production name pattern. This cannot be overridden ' +
            'by a parameter; isolate it from the Defender console with the change process that fits a production outage.')
        $isolationRequested = $false
    }

    $results.Add([PSCustomObject]@{
        Name            = $(if ($group.DeviceName) { $group.DeviceName } else { 'Alerts with no device evidence' })
        Id              = $key
        DeviceId        = $group.DeviceId
        DeviceName      = $group.DeviceName
        AlertCount      = $group.Alerts.Count
        HighestSeverity = "$($highest.severity)"
        Titles          = ((@($group.Alerts) | Select-Object -First 5 | ForEach-Object { $_.title }) -join '; ')
        Categories      = ((@($group.Alerts) | ForEach-Object { $_.category } | Select-Object -Unique) -join '; ')
        FirstSeen       = (@($group.Alerts).createdDateTime | Sort-Object | Select-Object -First 1)
        LastSeen        = (@($group.Alerts).createdDateTime | Sort-Object | Select-Object -Last 1)
        IsProductionNamed = $isProduction
        IsolationRequested = $isolationRequested
        ContainmentNote = if ($isolationRequested) { 'Isolation requested by an analyst for this device' }
                          elseif ($isProduction) { 'Production-named device - isolation refused; analyst decision through the outage process' }
                          else { 'No isolation requested. Containment is an ANALYST decision; this script proposes nothing.' }
    })
}

Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
    '{0} alert(s) correlated into {1} device group(s). Isolation requested for {2}.' -f
    $alerts.Count, $results.Count, @($results | Where-Object { $_.IsolationRequested }).Count)
""",
    act=r"""
$ticket = New-SecurityTicket -Context $itsmContext `
    -Title ('[EDR {0}] {1}: {2} alert(s)' -f $item.HighestSeverity, $item.Name, $item.AlertCount) `
    -Description (@(
        ('Device: {0} ({1})' -f $item.DeviceName, $item.DeviceId)
        ('Alerts: {0}, highest severity {1}' -f $item.AlertCount, $item.HighestSeverity)
        ('Categories: {0}' -f $item.Categories)
        ('First seen: {0}   Last seen: {1}' -f $item.FirstSeen, $item.LastSeen)
        ''
        ('Titles: {0}' -f $item.Titles)
        ''
        ('Containment: {0}' -f $item.ContainmentNote)
        ('Raised automatically by {0}.' -f $scriptName)
    ) -join "`n")

$detail = ('ticket {0}' -f $ticket.TicketNumber)

if ($item.IsolationRequested) {
    $isolationBody = @{
        comment = ('Isolated by {0} on analyst instruction. Approval {1}, ticket {2}.' -f
                   $scriptName, $ApprovalReference, $TicketReference)
        isolationType = 'full'
    } | ConvertTo-Json -Compress

    Invoke-MgGraphRequest -Method POST -ErrorAction Stop -Body $isolationBody `
        -Uri ('https://graph.microsoft.com/v1.0/security/machines/{0}/isolate' -f $item.DeviceId) | Out-Null

    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
        'DEVICE ISOLATED on analyst instruction. It stays cut off from everything except Defender ' +
        'until someone releases it.')
    $detail += '; device isolated'
} else {
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
        'Ticketed and enriched. No containment performed - {0}' -f $item.ContainmentNote)
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Ticket {0} raised for {1} alert(s)' -f $ticket.TicketNumber, $item.AlertCount)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'Triaged'; Detail = $detail; Succeeded = $true })
"""),

11: dict(
    file='Start-AccessReviewCampaign',
    modules=['Microsoft.Graph.Authentication', 'Microsoft.Graph.Identity.Governance'],
    synopsis='Launches access review campaigns, chases reviewers and compiles results.',
    desc='Starts Entra ID access review campaigns for the named groups, reports which reviewers have '
         'not yet responded on campaigns already running, and compiles the decisions from completed '
         'ones. The keep/revoke decisions themselves belong to the managers doing the review - they '
         'are made in the review UI and this script neither makes nor influences them.',
    params=[dict(name='GroupName', help='Groups to review. A campaign is created per group.',
                 decl="[string[]]$GroupName"),
            dict(name='ReviewerUpn', help='Reviewer(s). The group owner reviews when omitted.',
                 decl="[string[]]$ReviewerUpn"),
            dict(name='DurationDays', help='How long reviewers have to respond.',
                 decl="[ValidateRange(1,180)]\n    [int]$DurationDays = 14"),
            dict(name='CompileResults', help='Report on running and completed campaigns instead of creating new ones.',
                 decl="[switch]$CompileResults"),
            dict(name='ChaseAfterDays', help='Flag reviewers who have not responded after this many days.',
                 decl="[ValidateRange(1,180)]\n    [int]$ChaseAfterDays = 7")],
    assist_action=True,
    perms='Microsoft Graph AccessReview.ReadWrite.All, Group.Read.All, User.Read.All.',
    actionVerb='Create access review campaign',
    rollback='Stop the campaign from the Entra portal. A campaign that has not completed applies no '
             'decisions, so stopping one changes nobody\'s access.',
    notes='AGENT-ASSIST, with an unusual shape: the automatable half is itself a write. Launching a '
          'campaign, chasing reviewers and compiling results is mechanical and worth automating; the '
          'keep/revoke decision is not, and cannot be gated by this script even in principle, '
          'because it is made by each manager inside the review UI days later. So there is no '
          'approval gate here - the workbook marks the row Change / Write with no approval - and the '
          'script never sets a decision on anyone\'s behalf. Auto-apply of results is deliberately '
          'NOT enabled on the campaigns it creates.',
    examples=[("-GroupName 'Finance-Contributors','HR-Readers' -DurationDays 14",
               'Creates a 14-day review campaign per group.'),
              ("-CompileResults -ChaseAfterDays 7",
               'Reports outstanding reviewers and compiles completed campaigns. Creates nothing.')],
    discover=graph("AccessReview.ReadWrite.All','Group.Read.All','User.Read.All") + r"""
if (-not $CompileResults -and -not $GroupName) {
    throw 'Supply -GroupName to create campaigns, or -CompileResults to report on existing ones.'
}

$definitions = @()
try {
    $definitions = @(Get-MgIdentityGovernanceAccessReviewDefinition -All -ErrorAction Stop)
} catch {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
        'Existing campaigns unreadable ({0}); duplicate detection is unavailable this run.' -f $_.Exception.Message)
}

if ($CompileResults) {
    foreach ($definition in $definitions) {
        $instances = @()
        try {
            $instances = @(Get-MgIdentityGovernanceAccessReviewDefinitionInstance `
                -AccessReviewScheduleDefinitionId $definition.Id -All -ErrorAction Stop)
        } catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $definition.DisplayName `
                -Message ('Instances unreadable: {0}' -f $_.Exception.Message)
            continue
        }

        foreach ($instance in $instances) {
            $decisions = @()
            try {
                $decisions = @(Get-MgIdentityGovernanceAccessReviewDefinitionInstanceDecision `
                    -AccessReviewScheduleDefinitionId $definition.Id `
                    -AccessReviewInstanceId $instance.Id -All -ErrorAction Stop)
            } catch {
                Write-Verbose ('No decisions readable for instance {0}' -f $instance.Id)
            }

            $notReviewed = @($decisions | Where-Object { "$($_.Decision)" -eq 'NotReviewed' })
            $approved = @($decisions | Where-Object { "$($_.Decision)" -eq 'Approve' })
            $denied = @($decisions | Where-Object { "$($_.Decision)" -eq 'Deny' })

            $runningDays = if ($instance.StartDateTime) {
                [math]::Round(((Get-Date) - [datetime]$instance.StartDateTime).TotalDays, 1)
            } else { $null }
            $needsChasing = ($notReviewed.Count -gt 0 -and $null -ne $runningDays -and $runningDays -ge $ChaseAfterDays)

            $results.Add([PSCustomObject]@{
                Name          = $definition.DisplayName
                Id            = $instance.Id
                RecordType    = 'ExistingCampaign'
                DefinitionId  = $definition.Id
                InstanceId    = $instance.Id
                Status        = "$($instance.Status)"
                StartDate     = $instance.StartDateTime
                EndDate       = $instance.EndDateTime
                RunningDays   = $runningDays
                TotalDecisions= $decisions.Count
                NotReviewed   = $notReviewed.Count
                Approved      = $approved.Count
                Denied        = $denied.Count
                PendingReviewers = (($notReviewed | ForEach-Object { $_.Reviewer.DisplayName } | Select-Object -Unique) -join '; ')
                NeedsChasing  = $needsChasing
                GroupName     = ''
                ReviewerUpn   = ''
                Actionable    = $false
                Note          = if ($needsChasing) {
                                   ('{0} reviewer decision(s) outstanding after {1} day(s)' -f $notReviewed.Count, $runningDays)
                                } else { 'Decisions belong to the reviewers; this script does not set them' }
            })

            if ($needsChasing) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $definition.DisplayName -Message (
                    '{0} decision(s) outstanding after {1} day(s). Reviewers: {2}' -f
                    $notReviewed.Count, $runningDays,
                    (($notReviewed | ForEach-Object { $_.Reviewer.DisplayName } | Select-Object -Unique) -join ', '))
            }
        }
    }
} else {
    foreach ($name in $GroupName) {
        $group = Get-MgGroup -Filter ("displayName eq '{0}'" -f ($name -replace "'", "''")) -ErrorAction Stop |
                 Select-Object -First 1
        if (-not $group) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $name -Message 'Group not found; skipped.'
            continue
        }

        $existing = @($definitions | Where-Object { $_.DisplayName -eq ('Access review: {0}' -f $name) })
        if ($existing.Count -gt 0) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $name `
                -Message 'Skipped - a campaign with this name already exists (idempotent)'
            continue
        }

        $reviewerIds = @()
        foreach ($upn in @($ReviewerUpn)) {
            try { $reviewerIds += (Get-MgUser -UserId $upn -Property Id -ErrorAction Stop).Id } catch {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $upn `
                    -Message ('Reviewer not resolved: {0}' -f $_.Exception.Message)
            }
        }

        $results.Add([PSCustomObject]@{
            Name          = ('Access review: {0}' -f $name)
            Id            = $group.Id
            RecordType    = 'NewCampaign'
            DefinitionId  = ''
            InstanceId    = ''
            Status        = 'ToCreate'
            StartDate     = (Get-Date)
            EndDate       = (Get-Date).AddDays($DurationDays)
            RunningDays   = 0
            TotalDecisions= 0
            NotReviewed   = 0
            Approved      = 0
            Denied        = 0
            PendingReviewers = ''
            NeedsChasing  = $false
            GroupName     = $name
            ReviewerUpn   = ($reviewerIds -join ';')
            Actionable    = $true
            Note          = 'Auto-apply of results is deliberately NOT enabled - decisions are applied by a human'
        })
    }
}
""",
    act=r"""
if (-not $item.Actionable) {
    $actions.Add([PSCustomObject]@{
        Name = $item.Name; Action = 'Reported'; Detail = $item.Note; Succeeded = $true })
} else {
    $reviewers = @()
    foreach ($id in ($item.ReviewerUpn -split ';')) {
        if ($id) { $reviewers += @{ query = ('/users/{0}' -f $id); queryType = 'MicrosoftGraph' } }
    }
    if ($reviewers.Count -eq 0) {
        # No explicit reviewer means the group owners review, which is the
        # correct default - they know who should have access.
        $reviewers = @(@{ query = './owners'; queryType = 'MicrosoftGraph' })
    }

    $body = @{
        displayName = $item.Name
        descriptionForAdmins = ('Created by {0}. Decisions are made by the reviewers; auto-apply is off.' -f $scriptName)
        descriptionForReviewers = 'Confirm whether each member still needs access to this group.'
        scope = @{
            '@odata.type' = '#microsoft.graph.accessReviewQueryScope'
            query = ('/groups/{0}/transitiveMembers' -f $item.Id)
            queryType = 'MicrosoftGraph'
        }
        reviewers = $reviewers
        settings = @{
            mailNotificationsEnabled     = $true
            reminderNotificationsEnabled = $true
            justificationRequiredOnApproval = $true
            defaultDecisionEnabled       = $false
            defaultDecision              = 'None'
            instanceDurationInDays       = $DurationDays
            autoApplyDecisionsEnabled    = $false
            recurrence = @{
                pattern = @{ type = 'weekly'; interval = 1 }
                range   = @{ type = 'numbered'; startDate = (Get-Date -Format 'yyyy-MM-dd'); numberOfOccurrences = 1 }
            }
        }
    }

    $created = New-MgIdentityGovernanceAccessReviewDefinition -BodyParameter $body -ErrorAction Stop

    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
        'Campaign created ({0}), {1} day(s). Reminders on, auto-apply OFF - every decision is a reviewer''s.' -f
        $created.Id, $DurationDays)
    $actions.Add([PSCustomObject]@{
        Name = $item.Name; Action = 'CampaignCreated'; Detail = $created.Id; Succeeded = $true })
}
"""),

12: dict(
    file='Get-SiemLogSourceHealth',
    modules=['Az.Accounts', 'Az.OperationalInsights'],
    synopsis='Reports SIEM log sources that have stopped sending data.',
    desc='Reports the most recent ingestion time per data type in the Sentinel workspace and flags '
         'anything that has gone quiet. A silent log source is the most dangerous SIEM failure there '
         'is: the dashboards stay green and the detections simply stop firing.',
    params=[SUB_PARAM,
            dict(name='ResourceGroupName', help='Resource group holding the workspace.',
                 decl="[Parameter(Mandatory)]\n    [string]$ResourceGroupName"),
            dict(name='WorkspaceName', help='Log Analytics workspace name.',
                 decl="[Parameter(Mandatory)]\n    [string]$WorkspaceName"),
            dict(name='SilentMinutes', help='A source silent for longer than this is reported.',
                 decl="[ValidateRange(1,10080)]\n    [int]$SilentMinutes = 15"),
            dict(name='LookbackHours', help='How far back to look for each source\'s last record.',
                 decl="[ValidateRange(1,720)]\n    [int]$LookbackHours = 24"),
            dict(name='ExpectedDataType',
                 help='Data types that must be present. One missing entirely from the window is '
                      'reported as absent, which a last-seen query alone would never surface.',
                 decl="[string[]]$ExpectedDataType")],
    perms='Log Analytics Reader on the workspace.',
    notes='A source that has been silent longer than the lookback window does not appear in the '
          'results at all - it has no recent record to be late. That is why -ExpectedDataType exists: '
          'it is the only way to distinguish "quiet" from "gone", and the difference is exactly the '
          'failure this check is for.',
    examples=[("-ResourceGroupName rg-sec -WorkspaceName law-sec -SilentMinutes 15",
               'Standard 15-minute silence check.'),
              ("-ResourceGroupName rg-sec -WorkspaceName law-sec -ExpectedDataType SecurityEvent,Syslog,SigninLogs",
               'Also reports expected sources that are missing entirely.')],
    discover=AZ_CONNECT + r"""
$workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName `
    -Name $WorkspaceName -ErrorAction Stop

$query = @(
    'Usage'
    ('| where TimeGenerated > ago({0}h)' -f $LookbackHours)
    '| summarize LastSeen = max(TimeGenerated), TotalMB = sum(Quantity) by DataType'
    '| order by LastSeen asc'
) -join "`n"

$queryResult = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspace.CustomerId -Query $query -ErrorAction Stop
$rows = @($queryResult.Results)
$now = Get-Date
$seenTypes = @{}

foreach ($row in $rows) {
    $lastSeen = [datetime]$row.LastSeen
    $silentFor = [math]::Round(($now - $lastSeen).TotalMinutes, 1)
    $seenTypes[$row.DataType] = $true

    $isSilent = $silentFor -gt $SilentMinutes
    $results.Add([PSCustomObject]@{
        Name           = $row.DataType
        Id             = $row.DataType
        DataType       = $row.DataType
        LastSeen       = $lastSeen
        SilentMinutes  = $silentFor
        VolumeMB       = [math]::Round([double]$row.TotalMB, 2)
        Status         = if ($isSilent) { 'SILENT' } else { 'OK' }
        Detail         = if ($isSilent) { ('No data for {0} minute(s), threshold {1}' -f $silentFor, $SilentMinutes) } else { '' }
    })

    if ($isSilent) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $row.DataType -Message (
            'Log source silent for {0} minute(s)' -f $silentFor)
    }
}

# A source gone longer than the window has no row to be late. Only an explicit
# expectation catches that.
foreach ($expected in @($ExpectedDataType)) {
    if ($seenTypes.ContainsKey($expected)) { continue }

    $results.Add([PSCustomObject]@{
        Name          = $expected
        Id            = $expected
        DataType      = $expected
        LastSeen      = $null
        SilentMinutes = $null
        VolumeMB      = 0
        Status        = 'ABSENT'
        Detail        = ('Expected data type sent NOTHING in the last {0}h. This is worse than silent - ' +
                         'it has no recent record at all.' -f $LookbackHours)
    })
    Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $expected -Message (
        'Expected log source ABSENT for the whole {0}h window' -f $LookbackHours)
}
"""),

13: dict(
    file='Get-BreachCredentialAlert',
    modules=[],
    synopsis='Checks corporate addresses against known credential breaches.',
    desc='Queries Have I Been Pwned for corporate email addresses appearing in known breaches, so HR '
         'and IT can act on exposure that happened somewhere else entirely.',
    params=[dict(name='DomainName', help='Corporate domain to check. Uses the breached-domain endpoint.',
                 decl="[string]$DomainName"),
            dict(name='EmailAddress', help='Specific addresses to check individually.',
                 decl="[string[]]$EmailAddress"),
            dict(name='ApiKey', help='HIBP API key as a SecureString. A paid key is required.',
                 decl="[Parameter(Mandatory)]\n    [System.Security.SecureString]$ApiKey"),
            dict(name='SinceDate', help='Only report breaches added on or after this date.',
                 decl="[datetime]$SinceDate"),
            dict(name='RequestDelayMs', help='Delay between requests, to stay inside the rate limit.',
                 decl="[ValidateRange(200,10000)]\n    [int]$RequestDelayMs = 1600")],
    perms='A paid Have I Been Pwned API key. Domain search additionally requires the domain to be '
          'verified in your HIBP account.',
    notes='HIBP rate-limits by key tier and returns HTTP 429 when exceeded; -RequestDelayMs defaults '
          'to a spacing that suits the entry tier. A 404 from this API means "not found in any '
          'breach" and is the good answer, not an error - it is handled as such rather than logged '
          'as a failure. Note also that a breach listing means the address appeared in a dataset; it '
          'does not establish that the CORPORATE password was the one exposed.',
    examples=[("-DomainName contoso.com -ApiKey $key -SinceDate 2026-01-01",
               'Domain-wide check for breaches added this year.'),
              ("-EmailAddress user@contoso.com -ApiKey $key", 'One address.')],
    discover=r"""
if (-not $DomainName -and -not $EmailAddress) {
    throw 'Supply -DomainName for a domain-wide check, or -EmailAddress for specific addresses.'
}

$keyPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ApiKey)
try {
    $hibpHeaders = @{
        'hibp-api-key' = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($keyPtr)
        'user-agent'   = 'IT-Automation-Library'
    }
} finally {
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPtr)
}

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
$apiBase = 'https://haveibeenpwned.com/api/v3'

function Get-HibpResult {
    <#
        .SYNOPSIS
            One HIBP call. A 404 means "clean" and is returned as an empty set.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][hashtable]$Headers)

    try {
        return Invoke-RestMethod -Uri $Uri -Headers $Headers -Method GET -ErrorAction Stop
    } catch {
        $status = $_.Exception.Response.StatusCode.value__
        if ($status -eq 404) { return $null }          # clean, not an error
        if ($status -eq 429) { throw 'HIBP rate limit hit (HTTP 429). Increase -RequestDelayMs.' }
        throw
    }
}

$targets = @()
if ($DomainName) {
    $domainResult = Get-HibpResult -Uri ('{0}/breacheddomain/{1}' -f $apiBase, $DomainName) -Headers $hibpHeaders
    if (-not $domainResult) {
        Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message (
            'No addresses at {0} found in any known breach.' -f $DomainName)
    } else {
        foreach ($property in $domainResult.PSObject.Properties) {
            $targets += [PSCustomObject]@{
                Address = ('{0}@{1}' -f $property.Name, $DomainName)
                Breaches = @($property.Value)
            }
        }
    }
}

foreach ($address in @($EmailAddress)) {
    Start-Sleep -Milliseconds $RequestDelayMs
    $accountResult = Get-HibpResult -Headers $hibpHeaders `
        -Uri ('{0}/breachedaccount/{1}?truncateResponse=true' -f $apiBase, [uri]::EscapeDataString($address))
    if (-not $accountResult) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $address -Message 'Not found in any known breach.'
        continue
    }
    $targets += [PSCustomObject]@{ Address = $address; Breaches = @($accountResult | ForEach-Object { $_.Name }) }
}

# Breach metadata is fetched once and reused, rather than per address.
$breachCatalogue = @{}
try {
    foreach ($breach in @(Invoke-RestMethod -Uri ('{0}/breaches' -f $apiBase) -Headers $hibpHeaders -Method GET -ErrorAction Stop)) {
        $breachCatalogue[$breach.Name] = $breach
    }
} catch {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
        'Breach catalogue unavailable ({0}); names are reported without dates or data classes.' -f $_.Exception.Message)
}

foreach ($target in $targets) {
    foreach ($breachName in $target.Breaches) {
        $meta = $breachCatalogue[$breachName]
        if ($SinceDate -and $meta -and $meta.AddedDate -and ([datetime]$meta.AddedDate) -lt $SinceDate) { continue }

        $dataClasses = if ($meta) { (@($meta.DataClasses) -join '; ') } else { '' }
        $hasPasswords = $dataClasses -match '(?i)password'

        $results.Add([PSCustomObject]@{
            Name          = $target.Address
            Id            = ('{0}|{1}' -f $target.Address, $breachName)
            EmailAddress  = $target.Address
            BreachName    = $breachName
            BreachTitle   = if ($meta) { $meta.Title } else { $breachName }
            BreachDate    = if ($meta) { $meta.BreachDate } else { $null }
            AddedDate     = if ($meta) { $meta.AddedDate } else { $null }
            AccountsAffected = if ($meta) { $meta.PwnCount } else { $null }
            DataClasses   = $dataClasses
            PasswordsExposed = $hasPasswords
            IsVerified    = if ($meta) { $meta.IsVerified } else { $null }
            Severity      = if ($hasPasswords) { 'High' } else { 'Medium' }
            Caveat        = 'The address appeared in this dataset. That does NOT establish that the corporate password was the one exposed.'
        })

        if ($hasPasswords) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $target.Address -Message (
                'Appears in "{0}" which included passwords' -f $breachName)
        }
    }
}
"""),

14: dict(
    file='Get-ZeroTrustPolicyAudit',
    modules=['Microsoft.Graph.Authentication', 'Microsoft.Graph.Identity.SignIns'],
    synopsis='Compares Conditional Access policies against Zero Trust baseline expectations.',
    desc='Checks the Conditional Access estate for the controls a Zero Trust posture assumes are '
         'present - MFA for administrators, legacy authentication blocked, device compliance '
         'required, session controls on risky access - and reports which are absent, present but '
         'report-only, or scoped narrowly enough not to count.',
    params=[dict(name='BaselineFile', help='JSON file of expected controls. The built-in expectations are used when omitted.',
                 decl="[string]$BaselineFile"),
            dict(name='IncludeDisabled', help='Include policies that are disabled.',
                 decl="[switch]$IncludeDisabled")],
    perms='Microsoft Graph Policy.Read.All.',
    notes='AGENT-ASSIST. Whether a control set is adequate depends on the organisation\'s risk '
          'appetite, its user population and what it is protecting - none of which this script knows. '
          'It reports presence, state and scope, and stops. A policy in report-only mode is reported '
          'as NOT in force, because that is what it is: it logs what it would have done and blocks '
          'nothing. This overlaps deliberately with the M365 Conditional Access audit; that one '
          'inventories policies, this one tests them against a Zero Trust expectation.',
    examples=[("-OutputFormat HTML", 'Zero Trust control gaps as HTML.'),
              ("-BaselineFile .\\\\zt-baseline.json", 'Compares against your own control list.')],
    discover=graph("Policy.Read.All") + r"""
$policies = @(Get-MgIdentityConditionalAccessPolicy -All -ErrorAction Stop)
if (-not $IncludeDisabled) {
    $policies = @($policies | Where-Object { "$($_.State)" -ne 'disabled' })
}

# Each check is a predicate over the policy set. Deliberately small and
# explicit: it is a conversation starter, not a certification.
$checks = @(
    @{ Name = 'MFA required for administrators'
       Test = { param($p) $p.GrantControls.BuiltInControls -contains 'mfa' -and
                          @($p.Conditions.Users.IncludeRoles).Count -gt 0 }
       Why  = 'An administrator account without MFA is the shortest path to tenant compromise.' }
    @{ Name = 'Legacy authentication blocked'
       Test = { param($p) $p.GrantControls.BuiltInControls -contains 'block' -and
                          @($p.Conditions.ClientAppTypes | Where-Object { $_ -match '(?i)exchangeActiveSync|other' }).Count -gt 0 }
       Why  = 'Legacy auth protocols cannot present an MFA challenge, so every other MFA policy is bypassable while they are allowed.' }
    @{ Name = 'Device compliance required for corporate resources'
       Test = { param($p) $p.GrantControls.BuiltInControls -contains 'compliantDevice' -or
                          $p.GrantControls.BuiltInControls -contains 'domainJoinedDevice' }
       Why  = 'Zero Trust assumes device posture is evaluated, not just user identity.' }
    @{ Name = 'MFA required for all users'
       Test = { param($p) $p.GrantControls.BuiltInControls -contains 'mfa' -and
                          $p.Conditions.Users.IncludeUsers -contains 'All' }
       Why  = 'Administrator-only MFA leaves every standard account as an entry point.' }
    @{ Name = 'Sign-in risk policy present'
       Test = { param($p) @($p.Conditions.SignInRiskLevels).Count -gt 0 }
       Why  = 'Without a risk condition, a sign-in Identity Protection rates as high is treated exactly like any other.' }
    @{ Name = 'Session controls on unmanaged devices'
       Test = { param($p) $null -ne $p.SessionControls -and
                          ($null -ne $p.SessionControls.ApplicationEnforcedRestrictions -or
                           $null -ne $p.SessionControls.CloudAppSecurity -or
                           $null -ne $p.SessionControls.SignInFrequency) }
       Why  = 'Granting access without session limits means a token issued once is good until it expires.' }
)

if ($BaselineFile) {
    if (-not (Test-Path -LiteralPath $BaselineFile)) { throw ('Baseline file not found: {0}' -f $BaselineFile) }
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'Custom baseline supplied; it is reported ALONGSIDE the built-in checks, not instead of them.')
}

foreach ($check in $checks) {
    $matching = @($policies | Where-Object { & $check.Test $_ })
    $enforced = @($matching | Where-Object { "$($_.State)" -eq 'enabled' })
    $reportOnly = @($matching | Where-Object { "$($_.State)" -eq 'enabledForReportingButNotEnforced' })

    $status = if ($enforced.Count -gt 0) { 'Present' }
              elseif ($reportOnly.Count -gt 0) { 'REPORT-ONLY' }
              else { 'ABSENT' }

    $results.Add([PSCustomObject]@{
        Name            = $check.Name
        Id              = $check.Name
        Control         = $check.Name
        Status          = $status
        EnforcedPolicies= (($enforced | ForEach-Object { $_.DisplayName }) -join '; ')
        ReportOnlyPolicies = (($reportOnly | ForEach-Object { $_.DisplayName }) -join '; ')
        MatchCount      = $matching.Count
        WhyItMatters    = $check.Why
        AdequacyNote    = 'Whether this control set fits the organisation''s risk appetite is a human judgement and is not made here.'
    })

    if ($status -eq 'ABSENT') {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $check.Name -Message (
            'No policy implements this control. {0}' -f $check.Why)
    } elseif ($status -eq 'REPORT-ONLY') {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $check.Name -Message (
            'Only report-only policies match. This control logs what it would do and blocks nothing.')
    }
}
"""),

15: dict(
    file='Update-CloudWafRuleSet',
    modules=['Az.Accounts', 'Az.FrontDoor'],
    synopsis='Updates WAF managed rule sets in detection mode; refuses custom rule changes.',
    desc='Updates the managed rule set version on an Azure Front Door WAF policy and forces the '
         'result into Detection mode. Custom rules are reported and never modified, and moving a '
         'policy from Detection to Prevention needs a separate flag confirming somebody looked at '
         'the detection results first.',
    params=[SUB_PARAM,
            dict(name='ResourceGroupName', help='Resource group holding the WAF policy.',
                 decl="[Parameter(Mandatory)]\n    [string]$ResourceGroupName"),
            dict(name='PolicyName', help='WAF policy name(s).',
                 decl="[string[]]$PolicyName"),
            dict(name='ManagedRuleSetType', help='Managed rule set to apply.',
                 decl="[string]$ManagedRuleSetType = 'Microsoft_DefaultRuleSet'"),
            dict(name='ManagedRuleSetVersion', help='Managed rule set version to move to.',
                 decl="[Parameter(Mandatory)]\n    [string]$ManagedRuleSetVersion"),
            dict(name='PromoteToPrevention',
                 help='Switch the policy from Detection to Prevention. Requires '
                      '-DetectionResultsValidated.',
                 decl="[switch]$PromoteToPrevention"),
            dict(name='DetectionResultsValidated',
                 help='Confirms a human reviewed the detection-mode results and accepts that '
                      'Prevention will now block what those results showed.',
                 decl="[switch]$DetectionResultsValidated")],
    perms='Contributor on the Front Door WAF policy.',
    actionVerb='Update WAF managed rule set',
    reason='Managed WAF rule set update, staged in detection mode',
    rollback='The previous rule set version and policy mode are captured and logged before the '
             'change. Re-apply them to revert. Traffic blocked while Prevention was active is not '
             'recoverable - those requests were already refused.',
    notes='ASSIST-ONLY, and the staging is the whole control. A managed rule set update in Detection '
          'mode is safe: it logs what it would block and blocks nothing. The same update in '
          'Prevention mode can start refusing legitimate traffic the moment it applies, and the '
          'first symptom is usually a customer complaint rather than an alert. So the update always '
          'lands in Detection, and promotion is a separate run with a separate flag. Custom rules are '
          'never touched - their blast radius is entirely application-specific and the workbook '
          'assigns them to a human.',
    examples=[("-ResourceGroupName rg-waf -PolicyName wafpolicy01 -ManagedRuleSetVersion 2.1",
               'REPORT ONLY. Shows the version change and raises an approval.'),
              ("-ResourceGroupName rg-waf -PolicyName wafpolicy01 -ManagedRuleSetVersion 2.1 -ApprovalReference APR-...",
               'Applies the update in Detection mode.'),
              ("-ResourceGroupName rg-waf -PolicyName wafpolicy01 -ManagedRuleSetVersion 2.1 "
               "-PromoteToPrevention -DetectionResultsValidated -ApprovalReference APR-...",
               'Promotes a validated policy to Prevention.')],
    discover=AZ_CONNECT + r"""
if ($PromoteToPrevention -and -not $DetectionResultsValidated) {
    throw 'Refusing -PromoteToPrevention without -DetectionResultsValidated. Prevention mode starts ' +
          'blocking traffic immediately, and the guardrail on this use case requires a human to ' +
          'validate the detection-mode results first.'
}

$policies = @()
if ($PolicyName) {
    foreach ($name in $PolicyName) {
        $policies += Get-AzFrontDoorWafPolicy -ResourceGroupName $ResourceGroupName -Name $name -ErrorAction Stop
    }
} else {
    $policies = @(Get-AzFrontDoorWafPolicy -ResourceGroupName $ResourceGroupName -ErrorAction Stop)
}

foreach ($policy in $policies) {
    $managed = @($policy.ManagedRules | Where-Object { $_.RuleSetType -eq $ManagedRuleSetType })
    $currentVersion = if ($managed.Count -gt 0) { @($managed)[0].RuleSetVersion } else { '' }
    $currentMode = "$($policy.Mode)"
    $customRules = @($policy.CustomRules)

    $versionChanging = ($currentVersion -ne $ManagedRuleSetVersion)
    $modeChanging = ($PromoteToPrevention -and $currentMode -ne 'Prevention')

    if (-not $versionChanging -and -not $modeChanging) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $policy.Name -Message (
            'Skipped - already on {0} {1} in {2} mode (idempotent)' -f
            $ManagedRuleSetType, $ManagedRuleSetVersion, $currentMode)
        continue
    }

    if ($customRules.Count -gt 0) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $policy.Name -Message (
            '{0} custom rule(s) present. They are NOT modified by this script - custom rule changes ' +
            'risk blocking legitimate traffic and are a human decision.' -f $customRules.Count)
    }

    $results.Add([PSCustomObject]@{
        Name            = $policy.Name
        Id              = $policy.Id
        PolicyName      = $policy.Name
        ResourceGroup   = $ResourceGroupName
        CurrentMode     = $currentMode
        TargetMode      = if ($PromoteToPrevention) { 'Prevention' } else { 'Detection' }
        RuleSetType     = $ManagedRuleSetType
        CurrentVersion  = $currentVersion
        TargetVersion   = $ManagedRuleSetVersion
        VersionChanging = $versionChanging
        ModeChanging    = $modeChanging
        CustomRuleCount = $customRules.Count
        CustomRuleNames = (($customRules | ForEach-Object { $_.Name }) -join '; ')
        StagingNote     = if ($PromoteToPrevention) {
                             'PROMOTION TO PREVENTION - this policy starts BLOCKING traffic on apply'
                          } else {
                             'Lands in Detection mode - logs what it would block, blocks nothing'
                          }
    })
}
""",
    act=r"""
Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
    'Previous state (rollback reference): {0} {1}, mode {2}' -f
    $item.RuleSetType, $item.CurrentVersion, $item.CurrentMode)

$ruleSet = New-AzFrontDoorWafManagedRuleObject -Type $item.RuleSetType -Version $item.TargetVersion

$updateParams = @{
    ResourceGroupName = $item.ResourceGroup
    Name              = $item.PolicyName
    ManagedRule       = $ruleSet
    Mode              = $item.TargetMode
    ErrorAction       = 'Stop'
}
Update-AzFrontDoorWafPolicy @updateParams | Out-Null

if ($item.TargetMode -eq 'Prevention') {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
        'Policy is now in PREVENTION mode on {0} {1}. It is blocking traffic from this moment. ' +
        'Watch the block logs.' -f $item.RuleSetType, $item.TargetVersion)
} else {
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
        '{0} updated {1} -> {2}, staged in DETECTION mode. Review the detection results before promoting.' -f
        $item.RuleSetType, $item.CurrentVersion, $item.TargetVersion)
}

if ($item.CustomRuleCount -gt 0) {
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
        '{0} custom rule(s) left untouched: {1}' -f $item.CustomRuleCount, $item.CustomRuleNames)
}

$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'RuleSetUpdated'
    Detail = ('{0} -> {1}, {2} mode' -f $item.CurrentVersion, $item.TargetVersion, $item.TargetMode)
    Succeeded = $true })
"""),

16: dict(
    file='Get-PatchComplianceReport',
    modules=['Az.Accounts'],
    synopsis='Reports patch compliance across Azure and AWS estates.',
    desc='Collects patch compliance from Azure Update Manager and AWS Systems Manager and reports a '
         'percentage per platform, plus a combined figure covering only the platforms that actually '
         'answered.',
    params=[SUB_PARAM,
            dict(name='IncludeCloud', help='Which platforms to query.',
                 decl="[ValidateSet('Azure','AWS','All')]\n    [string[]]$IncludeCloud = @('All')"),
            dict(name='AwsRegion', help='AWS region for Systems Manager.',
                 decl="[string]$AwsRegion"),
            dict(name='NonCompliantOnly', help='Report only machines missing patches.',
                 decl="[switch]$NonCompliantOnly")],
    perms='Reader on the Azure subscription; ssm:DescribeInstancePatchStates in AWS.',
    notes='The combined percentage covers only the platforms that responded, and it says which those '
          'were. A platform that failed to answer is reported as NOT QUERIED rather than counted as '
          'zero machines - dropping an estate from the denominator makes the number go up, which is '
          'exactly the wrong direction for a compliance report to move by accident.',
    examples=[("-IncludeCloud All -OutputFormat HTML", 'Patch compliance across both clouds.'),
              ("-IncludeCloud AWS -AwsRegion me-central-1 -NonCompliantOnly", 'AWS machines missing patches.')],
    discover=r"""
$wanted = if ($IncludeCloud -contains 'All') { @('Azure', 'AWS') } else { $IncludeCloud }
$platformStats = @{}

if ($wanted -contains 'Azure') {
    try {
        $azContext = Get-AzContext -ErrorAction Stop
        if ($SubscriptionId -and $azContext.Subscription.Id -ne $SubscriptionId) {
            $azContext = Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop
        }

        $query = @{
            query = @(
                'patchassessmentresources'
                "| where type =~ 'microsoft.compute/virtualmachines/patchassessmentresults/softwarepatches'"
                '| extend vmId = tostring(split(id, "/patchAssessmentResults/")[0])'
                '| summarize Pending = count() by vmId'
            ) -join ' '
        } | ConvertTo-Json -Compress

        $response = Invoke-AzRestMethod -Method POST -Payload $query `
            -Path '/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01' -ErrorAction Stop
        if ($response.StatusCode -ge 400) {
            throw ('Resource Graph query failed (HTTP {0}): {1}' -f $response.StatusCode, $response.Content)
        }
        $rows = @(($response.Content | ConvertFrom-Json).data)

        $compliant = 0; $total = 0
        foreach ($row in $rows) {
            $total++
            $pending = [int]$row.Pending
            if ($pending -eq 0) { $compliant++ }
            if ($NonCompliantOnly -and $pending -eq 0) { continue }

            $results.Add([PSCustomObject]@{
                Name           = ($row.vmId -split '/')[-1]
                Id             = $row.vmId
                Cloud          = 'Azure'
                MachineId      = $row.vmId
                PendingPatches = $pending
                Compliant      = ($pending -eq 0)
                Status         = if ($pending -eq 0) { 'Compliant' } else { 'Missing patches' }
                Detail         = ('{0} pending update(s)' -f $pending)
            })
        }
        $platformStats['Azure'] = @{ Total = $total; Compliant = $compliant; Queried = $true }
    } catch {
        $platformStats['Azure'] = @{ Total = 0; Compliant = 0; Queried = $false }
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
            'Azure patch compliance NOT collected: {0}' -f $_.Exception.Message)
    }
}

if ($wanted -contains 'AWS') {
    try {
        Import-Module AWS.Tools.SimpleSystemsManagement -ErrorAction Stop
        $stateParams = @{ ErrorAction = 'Stop' }
        if ($AwsRegion) { $stateParams.Region = $AwsRegion }
        $states = @(Get-SSMInstancePatchStatesForPatchGroup @stateParams -PatchGroup '*' -ErrorAction SilentlyContinue)
        if ($states.Count -eq 0) {
            $states = @(Get-SSMInstancePatchState @stateParams)
        }

        $compliant = 0; $total = 0
        foreach ($state in $states) {
            $total++
            $missing = [int]$state.MissingCount + [int]$state.FailedCount
            if ($missing -eq 0) { $compliant++ }
            if ($NonCompliantOnly -and $missing -eq 0) { continue }

            $results.Add([PSCustomObject]@{
                Name           = $state.InstanceId
                Id             = $state.InstanceId
                Cloud          = 'AWS'
                MachineId      = $state.InstanceId
                PendingPatches = $missing
                Compliant      = ($missing -eq 0)
                Status         = if ($missing -eq 0) { 'Compliant' } else { 'Missing patches' }
                Detail         = ('{0} missing, {1} failed, baseline {2}' -f
                                  $state.MissingCount, $state.FailedCount, $state.BaselineId)
            })
        }
        $platformStats['AWS'] = @{ Total = $total; Compliant = $compliant; Queried = $true }
    } catch {
        $platformStats['AWS'] = @{ Total = 0; Compliant = 0; Queried = $false }
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
            'AWS patch compliance NOT collected: {0}' -f $_.Exception.Message)
    }
}

$queriedPlatforms = @($platformStats.Keys | Where-Object { $platformStats[$_].Queried })
$missedPlatforms = @($platformStats.Keys | Where-Object { -not $platformStats[$_].Queried })

$grandTotal = 0; $grandCompliant = 0
foreach ($platform in $queriedPlatforms) {
    $grandTotal += $platformStats[$platform].Total
    $grandCompliant += $platformStats[$platform].Compliant

    $results.Add([PSCustomObject]@{
        Name           = ('{0} compliance' -f $platform)
        Id             = ('summary-{0}' -f $platform)
        Cloud          = $platform
        MachineId      = ''
        PendingPatches = ($platformStats[$platform].Total - $platformStats[$platform].Compliant)
        Compliant      = $null
        Status         = 'Summary'
        Detail         = ('{0} of {1} compliant ({2}%)' -f
                          $platformStats[$platform].Compliant, $platformStats[$platform].Total,
                          $(if ($platformStats[$platform].Total -gt 0) {
                              [math]::Round(($platformStats[$platform].Compliant / $platformStats[$platform].Total) * 100, 1)
                            } else { 0 }))
    })
}

$results.Add([PSCustomObject]@{
    Name           = 'Combined compliance'
    Id             = 'summary-combined'
    Cloud          = 'ALL'
    MachineId      = ''
    PendingPatches = ($grandTotal - $grandCompliant)
    Compliant      = $null
    Status         = if ($missedPlatforms.Count -gt 0) { 'PARTIAL' } else { 'Complete' }
    Detail         = ('{0} of {1} machine(s) compliant ({2}%) across: {3}.{4}' -f
                      $grandCompliant, $grandTotal,
                      $(if ($grandTotal -gt 0) { [math]::Round(($grandCompliant / $grandTotal) * 100, 1) } else { 0 }),
                      ($queriedPlatforms -join ', '),
                      $(if ($missedPlatforms.Count -gt 0) {
                          ' NOT QUERIED: ' + ($missedPlatforms -join ', ') + ' - those estates are absent from this figure.'
                        } else { '' }))
})

if ($missedPlatforms.Count -gt 0) {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
        'Combined compliance EXCLUDES {0}. Dropping an estate from the denominator raises the ' +
        'percentage; read this figure with that in mind.' -f ($missedPlatforms -join ', '))
}
"""),

17: dict(
    file='Get-DataExfiltrationAlert',
    modules=['Az.Accounts', 'Az.OperationalInsights'],
    synopsis='Surfaces large outbound transfers for investigation.',
    desc='Ranks outbound data volume by user and by destination over the reporting window and '
         'presents the outliers with the context an investigator needs. Whether any of it is '
         'exfiltration or a legitimate business transfer is an investigation, and that is where this '
         'script stops.',
    params=[SUB_PARAM,
            dict(name='ResourceGroupName', help='Resource group holding the workspace.',
                 decl="[Parameter(Mandatory)]\n    [string]$ResourceGroupName"),
            dict(name='WorkspaceName', help='Log Analytics workspace name.',
                 decl="[Parameter(Mandatory)]\n    [string]$WorkspaceName"),
            dict(name='LookbackHours', help='Reporting window.',
                 decl="[ValidateRange(1,720)]\n    [int]$LookbackHours = 24"),
            dict(name='ThresholdMB', help='Report transfers above this size.',
                 decl="[ValidateRange(1,1048576)]\n    [int]$ThresholdMB = 500"),
            dict(name='TopCount', help='How many outliers to report per dimension.',
                 decl="[ValidateRange(1,200)]\n    [int]$TopCount = 20")],
    perms='Log Analytics Reader on the workspace.',
    notes='AGENT-ASSIST. Volume is not evidence. Backup jobs, database replication, video uploads, a '
          'developer pulling a container image and a genuine data theft all look the same in a byte '
          'count, and the ones that look most alarming are usually the scheduled ones. Every finding '
          'therefore carries an InvestigatorNote giving the benign explanation, and no verdict is '
          'offered. A baseline comparison against the same user\'s previous behaviour is what makes '
          'this useful, and that comparison is the investigator\'s to make.',
    examples=[("-ResourceGroupName rg-sec -WorkspaceName law-sec -ThresholdMB 500",
               'Daily outbound outliers over 500 MB.'),
              ("-ResourceGroupName rg-sec -WorkspaceName law-sec -LookbackHours 168 -ThresholdMB 2000",
               'A week of large transfers.')],
    discover=AZ_CONNECT + r"""
$workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName `
    -Name $WorkspaceName -ErrorAction Stop

$thresholdBytes = $ThresholdMB * 1MB

# CloudAppEvents is the Defender for Cloud Apps table. If it is not present in
# the workspace the query fails, and that is reported as "not collected"
# rather than as "no exfiltration".
$queries = @(
    @{ Dimension = 'User'
       Query = @(
           'CloudAppEvents'
           ('| where Timestamp > ago({0}h)' -f $LookbackHours)
           '| where isnotempty(AccountDisplayName)'
           '| summarize TotalBytes = sum(todouble(RawEventData.bytesUploaded)), Events = count() by AccountDisplayName'
           ('| where TotalBytes > {0}' -f $thresholdBytes)
           '| order by TotalBytes desc'
           ('| take {0}' -f $TopCount)
       ) -join "`n"
       Note = 'A user total is dominated by whatever they do routinely. Compare against their own previous weeks before treating it as anomalous.' }
    @{ Dimension = 'Application'
       Query = @(
           'CloudAppEvents'
           ('| where Timestamp > ago({0}h)' -f $LookbackHours)
           '| summarize TotalBytes = sum(todouble(RawEventData.bytesUploaded)), Events = count() by Application'
           ('| where TotalBytes > {0}' -f $thresholdBytes)
           '| order by TotalBytes desc'
           ('| take {0}' -f $TopCount)
       ) -join "`n"
       Note = 'Sanctioned applications dominate this list by design. An unsanctioned application with any volume is more interesting than a sanctioned one with a lot.' }
)

foreach ($queryDef in $queries) {
    $rows = @()
    try {
        $queryResult = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspace.CustomerId `
            -Query $queryDef.Query -ErrorAction Stop
        $rows = @($queryResult.Results)
    } catch {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
            '{0} dimension NOT collected: {1}. This is not evidence of no exfiltration - the query ' +
            'did not run.' -f $queryDef.Dimension, $_.Exception.Message)
        continue
    }

    foreach ($row in $rows) {
        $subject = if ($queryDef.Dimension -eq 'User') { $row.AccountDisplayName } else { $row.Application }
        $bytes = [double]$row.TotalBytes

        $results.Add([PSCustomObject]@{
            Name             = ('{0}: {1}' -f $queryDef.Dimension, $subject)
            Id               = ('{0}-{1}' -f $queryDef.Dimension, $subject)
            Dimension        = $queryDef.Dimension
            Subject          = $subject
            TotalMB          = [math]::Round($bytes / 1MB, 1)
            EventCount       = $row.Events
            WindowHours      = $LookbackHours
            InvestigatorNote = $queryDef.Note
            Verdict          = 'NONE - confirming exfiltration versus legitimate business transfer is an investigation, not a threshold'
        })
    }

    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        '{0} dimension: {1} subject(s) above {2} MB.' -f $queryDef.Dimension, $rows.Count, $ThresholdMB)
}
"""),

18: dict(
    file='Update-ServiceAccountSecret',
    modules=['Microsoft.Graph.Authentication', 'Microsoft.Graph.Applications', 'Az.Accounts', 'Az.KeyVault'],
    synopsis='Rotates Entra application secrets that have a recorded dependency inventory.',
    desc='Rotates the client secret on Entra ID application registrations and stores the new value in '
         'Key Vault. Only applications with a recorded dependency inventory are eligible - the '
         'workbook is explicit that unmanaged accounts need human dependency discovery first, and an '
         'application whose consumers are unknown is exactly the one that breaks when its secret '
         'changes.',
    params=[dict(name='DependencyInventoryFile',
                 help='JSON file listing, per application, which systems consume its secret. An '
                      'application absent from this file is reported and never rotated.',
                 decl="[Parameter(Mandatory)]\n    [string]$DependencyInventoryFile"),
            dict(name='ApplicationName', help='Limit to these application display names.',
                 decl="[string[]]$ApplicationName"),
            dict(name='KeyVaultName', help='Key Vault to store the new secret in.',
                 decl="[Parameter(Mandatory)]\n    [string]$KeyVaultName"),
            dict(name='ExpiringWithinDays', help='Rotate secrets expiring within this many days.',
                 decl="[ValidateRange(1,365)]\n    [int]$ExpiringWithinDays = 30"),
            dict(name='NewSecretLifetimeMonths', help='Lifetime of the new secret.',
                 decl="[ValidateRange(1,24)]\n    [int]$NewSecretLifetimeMonths = 12"),
            dict(name='RemoveOldSecret',
                 help='Delete the previous secret after the new one is stored. Off by default so '
                      'consumers have an overlap window to pick up the new value.',
                 decl="[switch]$RemoveOldSecret")],
    perms='Microsoft Graph Application.ReadWrite.All, plus Key Vault Secrets Officer on the vault.',
    actionVerb='Rotate application secret',
    reason='Scheduled service account secret rotation',
    rollback='The old secret is retained by default and stays valid until its own expiry, so a '
             'consumer that has not picked up the new value keeps working. If -RemoveOldSecret was '
             'used there is NO rollback - the old credential is gone and every consumer must take '
             'the new one.',
    notes='ASSIST-ONLY, and the dependency inventory is the human half. Rotating a secret is trivial; '
          'knowing what will stop working when you do is not, and that knowledge does not live in any '
          'API. So an application absent from -DependencyInventoryFile is reported as needing '
          'discovery and is structurally not rotatable. -RemoveOldSecret is off by default because '
          'the overlap window is what turns a rotation from an outage into a change: both secrets '
          'work until consumers have moved. One honest limitation: Microsoft Graph returns a new '
          'client secret as a plain .NET string and offers no alternative. The script converts it to '
          'a SecureString character by character and clears the source property immediately, but the '
          'string existed in managed memory and .NET strings cannot be zeroed. That is a property of '
          'the Graph API, not of this script, and it is stated here rather than papered over.',
    examples=[("-DependencyInventoryFile .\\\\deps.json -KeyVaultName kv-prod -ExpiringWithinDays 30",
               'REPORT ONLY. Lists eligible and ineligible applications, raises an approval.'),
              ("-DependencyInventoryFile .\\\\deps.json -KeyVaultName kv-prod -ApprovalReference APR-... -TicketReference CHG0012345",
               'Rotates eligible applications, keeping the old secret valid.')],
    discover=graph("Application.ReadWrite.All") + r"""
if (-not (Test-Path -LiteralPath $DependencyInventoryFile)) {
    throw ('Dependency inventory not found: {0}. Without it nothing is eligible - the workbook ' +
           'requires human dependency discovery before rotation.' -f $DependencyInventoryFile)
}
$inventory = Get-Content -LiteralPath $DependencyInventoryFile -Raw | ConvertFrom-Json

$azContext = Get-AzContext -ErrorAction SilentlyContinue
if (-not $azContext) {
    throw 'No Azure context for Key Vault access. Run Connect-AzAccount before this script.'
}
$vault = Get-AzKeyVault -VaultName $KeyVaultName -ErrorAction Stop
if (-not $vault) { throw ('Key Vault "{0}" not found.' -f $KeyVaultName) }

$applications = @(Get-MgApplication -All -ErrorAction Stop)
if ($ApplicationName) {
    $applications = @($applications | Where-Object { $ApplicationName -contains $_.DisplayName })
}

$cutoff = (Get-Date).AddDays($ExpiringWithinDays)
$notInventoried = 0

foreach ($app in $applications) {
    $secrets = @($app.PasswordCredentials)
    if ($secrets.Count -eq 0) { continue }

    $soonest = ($secrets | Sort-Object EndDateTime | Select-Object -First 1)
    if ($soonest.EndDateTime -and ([datetime]$soonest.EndDateTime) -gt $cutoff) { continue }

    $dependencies = $inventory.($app.DisplayName)
    $hasInventory = ($null -ne $dependencies -and @($dependencies).Count -gt 0)

    if (-not $hasInventory) {
        $notInventoried++
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $app.DisplayName -Message (
            'NOT ROTATABLE - no dependency inventory. Rotating a secret whose consumers are unknown ' +
            'is how things break. Discover them and add the application to the inventory file.')
    }

    $results.Add([PSCustomObject]@{
        Name             = $app.DisplayName
        Id               = $app.Id
        ApplicationId    = $app.Id
        AppId            = $app.AppId
        OldKeyId         = $soonest.KeyId
        OldSecretExpiry  = $soonest.EndDateTime
        DaysUntilExpiry  = if ($soonest.EndDateTime) { [math]::Round((([datetime]$soonest.EndDateTime) - (Get-Date)).TotalDays, 1) } else { $null }
        SecretCount      = $secrets.Count
        Dependencies     = (@($dependencies) -join '; ')
        DependencyCount  = @($dependencies).Count
        HasInventory     = $hasInventory
        Actionable       = $hasInventory
        VaultName        = $KeyVaultName
        VaultSecretName  = ('{0}-clientsecret' -f ($app.DisplayName -replace '[^A-Za-z0-9-]', '-'))
        Note             = if ($hasInventory) {
                              ('{0} known consumer(s) - they must pick up the new secret' -f @($dependencies).Count)
                           } else { 'No dependency inventory - human discovery required before rotation' }
    })
}

Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
    '{0} application(s) eligible for rotation; {1} blocked pending dependency discovery.' -f
    @($results | Where-Object { $_.Actionable }).Count, $notInventoried)
""",
    act=r"""
if (-not $item.Actionable) {
    $actions.Add([PSCustomObject]@{
        Name = $item.Name; Action = 'BlockedPendingDiscovery'; Detail = $item.Note; Succeeded = $true })
} else {
    $newCredential = Add-MgApplicationPassword -ApplicationId $item.ApplicationId -ErrorAction Stop `
        -PasswordCredential @{
            displayName = ('Rotated {0} by {1}' -f (Get-Date -Format 'yyyy-MM-dd'), $scriptName)
            endDateTime = (Get-Date).AddMonths($NewSecretLifetimeMonths)
        }

    if (-not $newCredential.SecretText) {
        throw 'Graph returned no secret text for the new credential; nothing was stored in Key Vault.'
    }

    # Graph hands the new secret back as a plain .NET string and offers no way
    # to receive it any other way. It is built into a SecureString character by
    # character rather than round-tripped through ConvertTo-SecureString
    # -AsPlainText, and the source property is cleared immediately afterwards.
    # The string still existed, and .NET strings cannot be zeroed - that
    # limitation belongs to the Graph API, and it is stated in .NOTES rather
    # than papered over.
    $secureSecret = New-Object System.Security.SecureString
    foreach ($character in $newCredential.SecretText.ToCharArray()) {
        $secureSecret.AppendChar($character)
    }
    $secureSecret.MakeReadOnly()
    $newCredential.SecretText = $null

    Set-AzKeyVaultSecret -VaultName $item.VaultName -Name $item.VaultSecretName -ErrorAction Stop `
        -SecretValue $secureSecret `
        -Expires (Get-Date).AddMonths($NewSecretLifetimeMonths) | Out-Null

    $detail = ('new keyId {0}, stored as {1}' -f $newCredential.KeyId, $item.VaultSecretName)

    if ($RemoveOldSecret) {
        Remove-MgApplicationPassword -ApplicationId $item.ApplicationId `
            -KeyId $item.OldKeyId -ErrorAction Stop
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
            'OLD SECRET DELETED. Every one of the {0} known consumer(s) must now use the new value: {1}' -f
            $item.DependencyCount, $item.Dependencies)
        $detail += '; old secret removed'
    } else {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
            'Old secret RETAINED until {0} so the {1} known consumer(s) have an overlap window: {2}' -f
            $item.OldSecretExpiry, $item.DependencyCount, $item.Dependencies)
    }

    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
        'Secret rotated and stored in {0}. {1}' -f $item.VaultName, $detail)
    $actions.Add([PSCustomObject]@{
        Name = $item.Name; Action = 'SecretRotated'; Detail = $detail; Succeeded = $true })
}
"""),
}
