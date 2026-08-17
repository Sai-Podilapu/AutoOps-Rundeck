<#
.SYNOPSIS
    Reports EKS node health and cordons NotReady nodes after approval.

.DESCRIPTION
    Checks node readiness across EKS clusters via kubectl and reports any node
    that is NotReady. The remediation - cordoning the node so the scheduler
    stops placing pods on it - is gated behind approval, because cordoning
    affects where workloads can run and a transiently NotReady node usually
    recovers on its own.

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

.PARAMETER ClusterName
    EKS cluster(s) to check. All clusters in the region when omitted.

.PARAMETER KubectlPath
    Path to the kubectl executable.

.PARAMETER NotReadyMinutes
    Only propose cordoning a node that has been NotReady for at least this
    long. Guards against transient flaps.

.PARAMETER Drain
    Also drain the node after cordoning, evicting its pods. Considerably more
    disruptive than a cordon alone.

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
    .\Set-AwsEksNodeSchedulable.ps1 -Region me-central-1

    REQUEST mode - reports NotReady nodes across all clusters and raises an
    approval.

.EXAMPLE
    .\Set-AwsEksNodeSchedulable.ps1 -Region me-central-1 -ClusterName prod-eks -ApprovalReference APR-... -Drain

    Cordons and drains the approved nodes.

.NOTES
    Source use case      : #19 - AWS EKS Node Health Check
    Category             : AWS
    Technology           : Boto3 / kubectl
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "Auto-cordon of NotReady nodes affects workloads; gate the remediation step"

    Required permissions : eks:ListClusters, eks:DescribeCluster, plus a kubeconfig with node get/patch rights in the cluster.
    Required modules     : AWS.Tools.Common, AWS.Tools.EKS
    Authentication       : IAM role or SSO profile via Set-AWSCredential. Never
                           an access key pair in code.

    Requires kubectl on PATH and a kubeconfig for each cluster. The script
    calls "aws eks update-kubeconfig" through the AWS CLI before querying,
    so the AWS CLI must also be installed. Cordoning does NOT evict
    running pods - only -Drain does that.

    Rollback             : Uncordon the node: kubectl uncordon <node>. A
                           drained node additionally needs its evicted pods to
                           reschedule, which the scheduler does automatically
                           once the node is uncordoned and Ready.
#>

#Requires -Version 5.1
#Requires -Modules AWS.Tools.Common
#Requires -Modules AWS.Tools.EKS

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$Region,

    [string]$ProfileName,

    [string[]]$ClusterName,

    [string]$KubectlPath = 'kubectl',

    [ValidateRange(1,1440)]
    [int]$NotReadyMinutes = 15,

    [switch]$Drain,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'EKS node remediation',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-AwsEksNodeSchedulable'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #19 (AWS)'

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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Cordon EKS node', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Cordon EKS node')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AWS EKS Node Health Check'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
