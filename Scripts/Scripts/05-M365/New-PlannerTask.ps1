<#
.SYNOPSIS
    Creates Planner tasks from ITSM ticket fields.

.DESCRIPTION
    Creates tasks in a Planner plan bucket with an assignee and due date,
    typically driven by an ITSM ticket. Additive and low risk.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER PlanName
    Planner plan display name.

.PARAMETER BucketName
    Bucket within the plan. The first bucket is used when omitted.

.PARAMETER TaskTitle
    Task title(s) to create.

.PARAMETER AssignTo
    UPN of the person to assign the task to.

.PARAMETER DueDate
    Task due date.

.PARAMETER TicketReference
    ITSM ticket driving the request. Added to the task description.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\New-PlannerTask.ps1 -PlanName 'IT Operations' -TaskTitle 'Replace failed disk' -AssignTo eng@contoso.com -TicketReference INC0012345

    Creates an assigned task.

.EXAMPLE
    .\New-PlannerTask.ps1 -PlanName 'IT Operations' -TaskTitle 'Review backups' -DueDate '2026-09-01' -WhatIf

    Shows the task that would be created.

.NOTES
    Source use case      : #14 - Planner Task Auto-Assignment
    Category             : M365
    Technology           : Graph API / Planner
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Create tasks from ITSM ticket fields"

    Required permissions : Microsoft Graph Tasks.ReadWrite and Group.Read.All.
    Required modules     : Microsoft.Graph.Authentication, Microsoft.Graph.Planner
    Authentication       : App registration with certificate auth (app-only).

    Rollback             : Delete the task. Planner tasks have no recycle bin,
                           so deletion is immediate.
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication
#Requires -Modules Microsoft.Graph.Planner

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory)]
    [string]$PlanName,

    [string]$BucketName,

    [Parameter(Mandatory)]
    [string[]]$TaskTitle,

    [string]$AssignTo,

    [datetime]$DueDate,

    [string]$TicketReference,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'New-PlannerTask'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #14 (M365)'

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


        Connect-MgGraph -Scopes 'Tasks.ReadWrite','Group.Read.All','User.Read.All' -NoWelcome -ErrorAction Stop
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Microsoft Graph'

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
        if (-not $PSCmdlet.ShouldProcess($label, 'Create Planner task')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Planner Task Auto-Assignment'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
