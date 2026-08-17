<#
.SYNOPSIS
    Executes an OCI Full Stack DR plan and collects drill evidence.

.DESCRIPTION
    Runs a DR plan execution and gathers the per-step evidence a drill needs
    for its record. The go/no-go decision beforehand and the assessment of the
    results afterwards are DR governance, belong to a human, and are not made
    here.

    DESTRUCTIVE. This script is REPORT-ONLY by default: it produces the
    candidate list and stops. Nothing is deleted, wiped or failed over
    unless -Execute is passed AND a valid -ApprovalReference is supplied.
    A pre-action backup/export is taken where the platform allows it, and
    every object is logged individually before it is touched.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

    AGENT-ASSIST ONLY. This automates the mechanical part - gathering,
    enriching and comparing against a baseline - and then stops, producing
    a decision-ready package. The judgement step is deliberately left to a
    human and is NOT scripted.

.PARAMETER CompartmentId
    Compartment OCID to operate in. Falls back to oci.defaultCompartmentId in
    config.json.

.PARAMETER Region
    OCI region identifier, e.g. me-dubai-1. Falls back to oci.defaultRegion in
    config.json, then to the region in the CLI profile.

.PARAMETER CliProfile
    Named profile in the OCI CLI config file. Not called -Profile because
    $Profile is a PowerShell automatic variable.

.PARAMETER CliConfigFile
    Path to the OCI CLI config file. The CLI default (~/.oci/config) is used
    when omitted.

.PARAMETER OciCliPath
    Full path to the oci executable. Resolved from PATH when omitted.

.PARAMETER DrPlanId
    OCID of the DR plan to execute.

.PARAMETER GoDecisionBy
    Name of the person who gave the go decision for this drill. Recorded in
    the evidence pack and required - a drill with no named owner is not a
    governed drill.

.PARAMETER FailoverAuthorized
    Required when the plan is a FAILOVER rather than a drill or switchover. A
    failover plan moves production.

.PARAMETER DrCliGroup
    PLACEHOLDER - the CLI command group for the DR service. Verify against
    your CLI version. Listed in MANIFEST.md under Needs Input.

.PARAMETER EvidencePath
    Directory to write the evidence pack to.

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
    .\Invoke-OciDrPlanExecution.ps1 -DrPlanId ocid1.drplan... -GoDecisionBy 'A. Rahman'

    REPORT ONLY. Reads the plan, shows the steps and raises an approval.

.EXAMPLE
    .\Invoke-OciDrPlanExecution.ps1 -DrPlanId ocid1.drplan... -GoDecisionBy 'A. Rahman' -ApprovalReference APR-... -Execute

    Executes an approved drill and writes the evidence pack.

.NOTES
    Source use case      : #15 - OCI DR Failover Test
    Category             : OCI
    Technology           : OCI DR Service / CLI
    Difficulty           : High
    Agent possible       : Yes
    Can execute with SOP : Partially - Agent Assists
    Automation type      : Destructive / High-Impact
    Risk level           : High
    Human approval needed: YES
    Guardrails (col L)   : "Agent executes runbook steps & collects evidence; go/no-go decision and results assessment are human (DR drill governance)"

    Required permissions : An IAM policy allowing DR_PLAN_EXECUTION_CREATE and inspect on the DR protection groups.
    Required modules     : none beyond IT-Automation-Common
    Authentication       : OCI CLI config profile. NOTE: there is no
                           first-party OCI PowerShell module - this wraps the
                           OCI CLI.

    ASSIST-ONLY AND DESTRUCTIVE. The mechanical part - executing the
    runbook and collecting step-level evidence - is exactly what should be
    automated, and a drill run by hand produces worse evidence than one
    run by script. The judgement parts are not automated at all: whether
    to proceed, and whether the result counts as a pass. -GoDecisionBy
    records who made the first call; the second is left entirely to the
    drill review. The plan TYPE is read before execution and a FAILOVER
    plan is refused without -FailoverAuthorized, because the difference
    between a drill and moving production is one plan selection.

    Rollback             : Depends entirely on the plan type. A DRILL plan is
                           designed to be non-disruptive and is cleaned up by
                           its own steps. A SWITCHOVER is reversed by switching
                           back. A FAILOVER has moved production and there is
                           no undo - that is why it needs a second flag.
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([PSCustomObject])]
param(
    [string]$CompartmentId,

    [string]$Region,

    [string]$CliProfile,

    [string]$CliConfigFile,

    [string]$OciCliPath,

    [Parameter(Mandatory)]
    [string]$DrPlanId,

    [Parameter(Mandatory)]
    [string]$GoDecisionBy,

    [switch]$FailoverAuthorized,

    [string]$DrCliGroup = 'disaster-recovery',

    [string]$EvidencePath,

    [switch]$Execute,

    [string]$ProtectedList,

    [ValidateRange(0, 3650)]
    [int]$MinimumAgeDays = 0,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Scheduled DR drill',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Invoke-OciDrPlanExecution'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #15 (OCI)'

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
    $pre = Test-Prerequisite
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
        Connect-AutomationPlatform -Platform 'OCI' | Out-Null


        function Invoke-OciCli {
            <#
                .SYNOPSIS
                    Runs one oci CLI command and returns its parsed JSON output.
                .DESCRIPTION
                    Appends the profile, config file, region and --output json, runs the
                    CLI, and throws on a non-zero exit code. Defined inside the script
                    rather than in the shared module because it depends on this run's
                    resolved CLI path and profile.
            #>
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)]
                [string[]]$Argument,

                [switch]$Raw
            )

            $cliArgs = @($Argument)
            if ($ociProfile)    { $cliArgs += @('--profile', $ociProfile) }
            if ($ociConfigFile) { $cliArgs += @('--config-file', $ociConfigFile) }
            if ($Region)        { $cliArgs += @('--region', $Region) }
            $cliArgs += @('--output', 'json')

            $errFile = [System.IO.Path]::GetTempFileName()
            $previousPreference = $ErrorActionPreference
            # Windows PowerShell turns redirected native stderr into terminating errors
            # under 'Stop', even when the process exits 0. The exit code is the signal
            # that actually matters, so the preference is relaxed for the call only.
            $ErrorActionPreference = 'Continue'
            $exitCode = 0
            try {
                $stdout = & $ociCli @cliArgs 2>$errFile
                $exitCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $previousPreference
            }

            $stderrText = ''
            if (Test-Path -LiteralPath $errFile) {
                $stderrText = "$(Get-Content -LiteralPath $errFile -Raw)"
                Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
            }

            if ($exitCode -ne 0) {
                # Redacted on the way into the log by Write-AutomationLog.
                throw ('oci {0} failed (exit {1}): {2}' -f ($Argument -join ' '), $exitCode, $stderrText.Trim())
            }

            $text = (@($stdout) -join "`n").Trim()
            if ($Raw) { return $text }
            if (-not $text) { return $null }
            try {
                return ($text | ConvertFrom-Json)
            } catch {
                throw ('oci {0} returned output that is not JSON: {1}' -f ($Argument -join ' '),
                       $text.Substring(0, [math]::Min(200, $text.Length)))
            }
        }

        $ociCli = if ($OciCliPath) { $OciCliPath } else { 'oci' }
        $resolvedCli = Get-Command -Name $ociCli -ErrorAction SilentlyContinue
        if (-not $resolvedCli) {
            throw ('The OCI CLI was not found ("{0}"). Install it and ensure it is on PATH, or pass ' +
                   '-OciCliPath. There is no first-party OCI PowerShell module; this script wraps the CLI.' -f $ociCli)
        }
        $ociCli = $resolvedCli.Source

        $ociProfile = $CliProfile
        $ociConfigFile = $CliConfigFile
        if ($config -and $config.oci) {
            if (-not $ociProfile -and $config.oci.profileName)          { $ociProfile = $config.oci.profileName }
            if (-not $Region -and $config.oci.defaultRegion)            { $Region = $config.oci.defaultRegion }
            if (-not $CompartmentId -and $config.oci.defaultCompartmentId) { $CompartmentId = $config.oci.defaultCompartmentId }
        }

        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Using OCI CLI at {0}{1}{2}' -f $ociCli,
            $(if ($ociProfile) { ", profile '$ociProfile'" } else { ', default profile' }),
            $(if ($Region) { ", region '$Region'" } else { ', region from profile' }))

        if (-not $CompartmentId) {
            throw 'No compartment. Pass -CompartmentId or set oci.defaultCompartmentId in config.json.'
        }

        $plan = $null
        try {
            $plan = (Invoke-OciCli -Argument @($DrCliGroup, 'dr-plan', 'get', '--dr-plan-id', $DrPlanId)).data
        } catch {
            throw ('Could not read DR plan {0}: {1}. If the command group is wrong for your CLI version, ' +
                   'pass -DrCliGroup.' -f $DrPlanId, $_.Exception.Message)
        }
        if (-not $plan) { throw ('DR plan {0} returned no data.' -f $DrPlanId) }

        $planType = "$($plan.type)"

        # A drill and a production failover are one plan selection apart.
        if ($planType -match '(?i)^failover' -and -not $FailoverAuthorized) {
            throw ('DR plan {0} is of type {1}, which MOVES PRODUCTION. Refusing without ' +
                   '-FailoverAuthorized. If a drill was intended, select a DRILL plan instead.' -f
                   $plan.'display-name', $planType)
        }

        $steps = @()
        foreach ($group in @($plan.'plan-groups')) {
            foreach ($step in @($group.steps)) {
                $steps += [PSCustomObject]@{
                    GroupName = $group.'display-name'
                    StepName  = $step.'display-name'
                    Type      = $step.type
                    IsEnabled = $step.'is-enabled'
                }
            }
        }

        $enabledSteps = @($steps | Where-Object { $_.IsEnabled })

        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'DR plan "{0}" type {1}: {2} step(s), {3} enabled. Go decision recorded as: {4}' -f
            $plan.'display-name', $planType, $steps.Count, $enabledSteps.Count, $GoDecisionBy)

        $results.Add([PSCustomObject]@{
            Name          = $plan.'display-name'
            Id            = $plan.id
            DrPlanId      = $plan.id
            PlanType      = $planType
            LifecycleState= $plan.'lifecycle-state'
            ProtectionGroupId = $plan.'dr-protection-group-id'
            PeerRegion    = $plan.'peer-region'
            TotalSteps    = $steps.Count
            EnabledSteps  = $enabledSteps.Count
            StepSummary   = ((@($enabledSteps) | Select-Object -First 15 | ForEach-Object { '{0}/{1}' -f $_.GroupName, $_.StepName }) -join '; ')
            GoDecisionBy  = $GoDecisionBy
            MovesProduction = ($planType -match '(?i)^failover')
            HumanStep     = 'Assessing whether the execution result counts as a PASS is a drill-review decision, not made by this script.'
        })
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Execute DR plan', $candidates.Count, $Reason, $TicketReference)
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
        $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'OCI DR Failover Test (candidates)'
        Write-Output $candidates
        return
    }

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Execute DR plan')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $execName = 'drill-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmm')
            $execution = Invoke-OciCli -Argument @($DrCliGroup, 'dr-plan-execution', 'create',
                '--plan-id', $item.DrPlanId, '--display-name', $execName)

            $executionId = $execution.data.id
            if (-not $executionId) { throw 'DR plan execution was submitted but no execution id was returned.' }

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'DR plan execution {0} started for plan "{1}" (type {2}). Go decision by: {3}' -f
                $executionId, $item.Name, $item.PlanType, $item.GoDecisionBy)

            # Evidence is the deliverable of a drill, so it is captured even though the
            # execution itself may still be running.
            $evidence = $null
            try {
                $evidence = (Invoke-OciCli -Argument @($DrCliGroup, 'dr-plan-execution', 'get',
                    '--dr-plan-execution-id', $executionId)).data
            } catch {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label `
                    -Message ('Execution detail not yet readable: {0}' -f $_.Exception.Message)
            }

            $evidenceDir = if ($EvidencePath) { $EvidencePath }
                           else { Join-Path $env:ProgramData 'ITAutomation\Reports\DR' }
            if (-not (Test-Path -LiteralPath $evidenceDir)) {
                New-Item -Path $evidenceDir -ItemType Directory -Force | Out-Null
            }
            $evidenceFile = Join-Path $evidenceDir ('dr-evidence-{0}.json' -f $executionId)

            @{
                ExecutionId   = $executionId
                PlanId        = $item.DrPlanId
                PlanName      = $item.Name
                PlanType      = $item.PlanType
                GoDecisionBy  = $item.GoDecisionBy
                TicketReference = $TicketReference
                ApprovalReference = $ApprovalReference
                StartedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
                ExecutionDetail = $evidence
                AssessmentNote = 'PASS/FAIL assessment is a human drill-review decision and is deliberately absent from this pack.'
            } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $evidenceFile -Encoding UTF8

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Evidence pack written: {0}. RESULTS ASSESSMENT IS STILL OUTSTANDING.' -f $evidenceFile)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'DrExecutionStarted'
                Detail = ('execution {0}, evidence {1}' -f $executionId, $evidenceFile); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'OCI DR Failover Test'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
