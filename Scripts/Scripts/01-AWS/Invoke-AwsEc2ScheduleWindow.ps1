<#
.SYNOPSIS
    Applies per-instance start/stop windows to EC2 instances from their tags.

.DESCRIPTION
    Reads a start hour and stop hour from each instance's own tags and brings
    the instance into the state its window says it should be in right now.
    Distinct from Set-AwsInstanceSchedule.ps1, which applies one state to a
    whole tagged group: this one lets each instance carry its own window,
    which is what a mixed estate needs.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER Region
    AWS region to operate in. Defaults to the configured default region.

.PARAMETER ProfileName
    Named AWS profile / SSO profile to use. Prefer an IAM role where the host
    supports one.

.PARAMETER StartHourTagKey
    Tag holding the hour (0-23, local to -ScheduleTimeZone) the instance
    should start.

.PARAMETER StopHourTagKey
    Tag holding the hour (0-23) the instance should stop.

.PARAMETER ScheduleTimeZone
    IANA/Windows time zone the window hours are expressed in. Windows are
    business-local, not UTC.

.PARAMETER SkipDays
    Days on which the window is not applied, e.g. weekends.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Invoke-AwsEc2ScheduleWindow.ps1 -Region me-central-1 -ScheduleTimeZone 'Arabian Standard Time'

    Applies each instance's own window, interpreting the hours in Gulf local
    time.

.EXAMPLE
    .\Invoke-AwsEc2ScheduleWindow.ps1 -Region me-central-1 -WhatIf

    Shows which instances are outside their window without changing anything.

.NOTES
    Source use case      : #4 - EC2 Instance Scheduler
    Category             : AWS
    Technology           : Lambda / EventBridge
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Scheduled power ops; reversible"

    Required permissions : ec2:DescribeInstances, ec2:StartInstances, ec2:StopInstances
    Required modules     : AWS.Tools.Common, AWS.Tools.EC2
    Authentication       : IAM role or SSO profile via Set-AWSCredential. Never
                           an access key pair in code.

    An instance must carry BOTH tags to be managed. A half-tagged instance
    is skipped and logged rather than guessed at, because guessing one end
    of a window is how a production server gets stopped at 9am.

    Rollback             : Reverse the action, or remove the schedule tags from
                           the instance so it is no longer managed. An instance
                           without both tags is never touched.
#>

#Requires -Version 5.1
#Requires -Modules AWS.Tools.Common
#Requires -Modules AWS.Tools.EC2

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$Region,

    [string]$ProfileName,

    [string]$StartHourTagKey = 'AutoOps:StartHour',

    [string]$StopHourTagKey = 'AutoOps:StopHour',

    [string]$ScheduleTimeZone = 'UTC',

    [ValidateSet('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')]
    [string[]]$SkipDays = @('Saturday','Sunday'),

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Invoke-AwsEc2ScheduleWindow'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #4 (AWS)'

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
        if (-not $PSCmdlet.ShouldProcess($label, 'Apply EC2 schedule window')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            if ($item.DesiredState -eq 'running') { Start-EC2Instance -InstanceId $item.Id @awsArgs | Out-Null }
            else                                  { Stop-EC2Instance  -InstanceId $item.Id @awsArgs | Out-Null }

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Window {0:00}-{1:00} {2}, local hour {3:00}: {4} -> {5}' -f
                $item.WindowStart, $item.WindowStop, $item.TimeZone, $item.LocalHour, $item.CurrentState, $item.DesiredState)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = $item.DesiredState; Detail = $item.Id; Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'EC2 Instance Scheduler'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
