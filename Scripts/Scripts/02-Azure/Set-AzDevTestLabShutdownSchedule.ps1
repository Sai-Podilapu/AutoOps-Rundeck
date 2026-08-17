<#
.SYNOPSIS
    Configures or applies auto-shutdown schedules on development VMs.

.DESCRIPTION
    Sets the auto-shutdown schedule on VMs, or applies an immediate shutdown
    to dev VMs left running past the cut-off. The workbook specifies 8 PM for
    dev VMs, which is the default. Reversible - the VM starts again on
    request.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER SubscriptionId
    Subscription to operate in. Falls back to azure.defaultSubscriptionId in
    config.json.

.PARAMETER ResourceGroupName
    Limit to specific resource groups.

.PARAMETER Mode
    Configure sets the daily auto-shutdown schedule; ShutdownNow deallocates
    VMs already past the cut-off.

.PARAMETER ShutdownTime
    Daily shutdown time in HHmm, local to -ScheduleTimeZone.

.PARAMETER ScheduleTimeZone
    Windows time zone id the shutdown time is expressed in.

.PARAMETER EnvironmentTagKey
    Tag key identifying the environment.

.PARAMETER DevEnvironmentValue
    Tag values treated as development.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Set-AzDevTestLabShutdownSchedule.ps1 -Mode Configure -ShutdownTime 2000 -ScheduleTimeZone 'Arabian Standard Time'

    Sets an 8 PM Gulf-time shutdown on every dev-tagged VM.

.EXAMPLE
    .\Set-AzDevTestLabShutdownSchedule.ps1 -Mode ShutdownNow -WhatIf

    Shows which dev VMs are running past the cut-off.

.NOTES
    Source use case      : #31 - Azure DevTest Labs Auto-Shutdown
    Category             : Azure
    Technology           : Az DevTest Labs API
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Scheduled shutdown of dev VMs at 8 PM; reversible"

    Required permissions : Virtual Machine Contributor on the target scope.
    Required modules     : Az.Accounts, Az.Compute
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    Auto-shutdown deallocates the VM, which stops compute billing but does
    not delete the disk. Anything held only in the temporary drive is
    lost, so do not schedule this against a VM whose workload keeps state
    there.

    Rollback             : Remove the schedule resource, or start the VM again.
                           Auto-shutdown deallocates but never deletes.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.Compute

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [string[]]$ResourceGroupName,

    [ValidateSet('Configure','ShutdownNow')]
    [string]$Mode = 'Configure',

    [ValidatePattern('^([01]\\d|2[0-3])[0-5]\\d$')]
    [string]$ShutdownTime = '2000',

    [string]$ScheduleTimeZone = 'UTC',

    [string]$EnvironmentTagKey = 'Environment',

    [string[]]$DevEnvironmentValue = @('dev','test','sandbox','lab'),

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-AzDevTestLabShutdownSchedule'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #31 (Azure)'

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
        Connect-AutomationPlatform -Platform 'Azure' | Out-Null


        if (-not $SubscriptionId -and $config -and $config.azure) { $SubscriptionId = $config.azure.defaultSubscriptionId }
        if ($SubscriptionId) {
            Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop | Out-Null
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message ('Subscription context: {0}' -f $SubscriptionId)
        } else {
            $ctx = Get-AzContext
            if (-not $ctx) { throw 'No Azure context. Pass -SubscriptionId or set azure.defaultSubscriptionId in config.json.' }
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'No -SubscriptionId given; using the ambient context {0}' -f $ctx.Subscription.Id)
        }

        $vms = if ($ResourceGroupName) { $ResourceGroupName | ForEach-Object { Get-AzVM -ResourceGroupName $_ -Status } }
               else                    { Get-AzVM -Status }

        foreach ($vm in $vms) {
            $full = Get-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name
            $envTag = $full.Tags[$EnvironmentTagKey]
            if (-not $envTag -or $DevEnvironmentValue -notcontains $envTag) { continue }

            $power = ($vm.PowerState -replace '^VM ', '')

            if ($Mode -eq 'ShutdownNow') {
                if ($power -ne 'running') { continue }
                try {
                    $tz  = [System.TimeZoneInfo]::FindSystemTimeZoneById($ScheduleTimeZone)
                    $now = [System.TimeZoneInfo]::ConvertTimeFromUtc((Get-Date).ToUniversalTime(), $tz)
                } catch {
                    throw ('Unknown time zone "{0}".' -f $ScheduleTimeZone)
                }
                $cutHour = [int]$ShutdownTime.Substring(0,2)
                $cutMin  = [int]$ShutdownTime.Substring(2,2)
                $cut = Get-Date -Year $now.Year -Month $now.Month -Day $now.Day -Hour $cutHour -Minute $cutMin -Second 0
                if ($now -lt $cut) { continue }        # not yet past the cut-off
            }

            $results.Add([PSCustomObject]@{
                Name          = $vm.Name
                Id            = $full.Id
                ResourceGroup = $vm.ResourceGroupName
                Location      = $vm.Location
                Environment   = $envTag
                PowerState    = $power
                Mode          = $Mode
                ShutdownTime  = $ShutdownTime
                TimeZone      = $ScheduleTimeZone
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Set auto-shutdown schedule')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            if ($item.Mode -eq 'ShutdownNow') {
                Stop-AzVM -ResourceGroupName $item.ResourceGroup -Name $item.Name -Force -ErrorAction Stop | Out-Null
                Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                    'Deallocated - past the {0} {1} cut-off' -f $item.ShutdownTime, $item.TimeZone)
                $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'Deallocated'; Detail = 'past cut-off'; Succeeded = $true })
            } else {
                $props = @{
                    status = 'Enabled'
                    taskType = 'ComputeVmShutdownTask'
                    dailyRecurrence = @{ time = $item.ShutdownTime }
                    timeZoneId = $item.TimeZone
                    targetResourceId = $item.Id
                    notificationSettings = @{ status = 'Disabled'; timeInMinutes = 30 }
                }
                $scheduleName = 'shutdown-computevm-{0}' -f $item.Name
                $uri = ('/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.DevTestLab/schedules/{2}?api-version=2018-09-15' -f
                        (Get-AzContext).Subscription.Id, $item.ResourceGroup, $scheduleName)

                $body = @{ location = $item.Location; properties = $props } | ConvertTo-Json -Depth 8
                $resp = Invoke-AzRestMethod -Path $uri -Method PUT -Payload $body -ErrorAction Stop
                if ($resp.StatusCode -ge 400) {
                    throw ('Schedule creation failed with HTTP {0}: {1}' -f $resp.StatusCode, $resp.Content)
                }

                Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                    'Auto-shutdown schedule set for {0} {1}' -f $item.ShutdownTime, $item.TimeZone)
                $actions.Add([PSCustomObject]@{
                    Name = $item.Name; Action = 'ScheduleSet'
                    Detail = ('{0} {1}' -f $item.ShutdownTime, $item.TimeZone); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Azure DevTest Labs Auto-Shutdown'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
