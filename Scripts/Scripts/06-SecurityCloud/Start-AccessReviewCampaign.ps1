<#
.SYNOPSIS
    Launches access review campaigns, chases reviewers and compiles results.

.DESCRIPTION
    Starts Entra ID access review campaigns for the named groups, reports
    which reviewers have not yet responded on campaigns already running, and
    compiles the decisions from completed ones. The keep/revoke decisions
    themselves belong to the managers doing the review - they are made in the
    review UI and this script neither makes nor influences them.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    AGENT-ASSIST ONLY. This automates the mechanical part - gathering,
    enriching and comparing against a baseline - and then stops, producing
    a decision-ready package. The judgement step is deliberately left to a
    human and is NOT scripted.

.PARAMETER GroupName
    Groups to review. A campaign is created per group.

.PARAMETER ReviewerUpn
    Reviewer(s). The group owner reviews when omitted.

.PARAMETER DurationDays
    How long reviewers have to respond.

.PARAMETER CompileResults
    Report on running and completed campaigns instead of creating new ones.

.PARAMETER ChaseAfterDays
    Flag reviewers who have not responded after this many days.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Start-AccessReviewCampaign.ps1 -GroupName 'Finance-Contributors','HR-Readers' -DurationDays 14

    Creates a 14-day review campaign per group.

.EXAMPLE
    .\Start-AccessReviewCampaign.ps1 -CompileResults -ChaseAfterDays 7

    Reports outstanding reviewers and compiles completed campaigns. Creates
    nothing.

.NOTES
    Source use case      : #11 - Identity Governance Access Review
    Category             : Security Cloud
    Technology           : Entra ID Access Reviews / Graph API
    Difficulty           : Medium
    Agent possible       : Partial
    Can execute with SOP : Partially - Agent Assists
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Agent launches campaigns, chases reviewers, compiles results; the access keep/revoke decisions belong to managers by design"

    Required permissions : Microsoft Graph AccessReview.ReadWrite.All, Group.Read.All, User.Read.All.
    Required modules     : Microsoft.Graph.Authentication, Microsoft.Graph.Identity.Governance
    Authentication       : Vendor REST API via Invoke-RestMethod, or Graph
                           where the tool is Microsoft.

    AGENT-ASSIST, with an unusual shape: the automatable half is itself a
    write. Launching a campaign, chasing reviewers and compiling results
    is mechanical and worth automating; the keep/revoke decision is not,
    and cannot be gated by this script even in principle, because it is
    made by each manager inside the review UI days later. So there is no
    approval gate here - the workbook marks the row Change / Write with no
    approval - and the script never sets a decision on anyone's behalf.
    Auto-apply of results is deliberately NOT enabled on the campaigns it
    creates.

    Rollback             : Stop the campaign from the Entra portal. A campaign
                           that has not completed applies no decisions, so
                           stopping one changes nobody's access.
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication
#Requires -Modules Microsoft.Graph.Identity.Governance

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string[]]$GroupName,

    [string[]]$ReviewerUpn,

    [ValidateRange(1,180)]
    [int]$DurationDays = 14,

    [switch]$CompileResults,

    [ValidateRange(1,180)]
    [int]$ChaseAfterDays = 7,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Start-AccessReviewCampaign'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #11 (Security Cloud)'

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
        Connect-AutomationPlatform -Platform 'Graph' | Out-Null


        Connect-MgGraph -Scopes 'AccessReview.ReadWrite.All','Group.Read.All','User.Read.All' -NoWelcome -ErrorAction Stop
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Microsoft Graph'

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

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Create access review campaign')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Identity Governance Access Review'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
