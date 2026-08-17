<#
.SYNOPSIS
    Starts or stops tagged EC2 instances on a schedule.

.DESCRIPTION
    Finds EC2 instances carrying the scheduling tag and starts or stops them
    to match the requested state. The tag is the contract: an instance without
    it is never touched, so adding an instance to the schedule is a tagging
    operation rather than a code change.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER Region
    AWS region to operate in. Defaults to the configured default region.

.PARAMETER ProfileName
    Named AWS profile / SSO profile to use. Prefer an IAM role where the host
    supports one.

.PARAMETER ScheduleTagKey
    Tag key that marks an instance as schedulable.

.PARAMETER ScheduleTagValue
    Tag value to match.

.PARAMETER DesiredState
    Start or Stop.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Set-AwsInstanceSchedule.ps1 -DesiredState Stop -Region me-central-1

    Stops every instance tagged for scheduling in the given region.

.EXAMPLE
    .\Set-AwsInstanceSchedule.ps1 -DesiredState Start -WhatIf

    Shows which instances would be started without acting.

.NOTES
    Source use case      : #1 - AWS Instance Scheduler
    Category             : AWS
    Technology           : Lambda / EventBridge
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Scheduled start/stop; reversible; already automated"

    Required permissions : ec2:DescribeInstances, ec2:StartInstances, ec2:StopInstances
    Required modules     : AWS.Tools.Common, AWS.Tools.EC2
    Authentication       : IAM role or SSO profile via Set-AWSCredential. Never
                           an access key pair in code.

    Rollback             : Reverse the -DesiredState. Instance store data does
                           not survive a stop - the tag contract exists so only
                           instances marked as safe to stop are ever selected.
#>

#Requires -Version 5.1
#Requires -Modules AWS.Tools.Common
#Requires -Modules AWS.Tools.EC2

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$Region,

    [string]$ProfileName,

    [string]$ScheduleTagKey = 'AutoOps:Schedule',

    [string]$ScheduleTagValue = 'business-hours',

    [ValidateSet('Start','Stop')]
    [string]$DesiredState = 'Stop',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-AwsInstanceSchedule'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #1 (AWS)'

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
        if (-not $PSCmdlet.ShouldProcess($label, 'Start/stop EC2 instance')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            if ($DesiredState -eq 'Start') { Start-EC2Instance -InstanceId $item.Id @awsArgs | Out-Null }
            else                           { Stop-EC2Instance  -InstanceId $item.Id @awsArgs | Out-Null }
            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                '{0} issued ({1} -> {2})' -f $DesiredState, $item.CurrentState, $item.DesiredState)
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = $DesiredState; Detail = $item.Id; Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AWS Instance Scheduler'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
