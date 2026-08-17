<#
.SYNOPSIS
    Scales a host pool to a target host count, respecting a minimum.

.DESCRIPTION
    Starts or stops session hosts to reach a target count for the current
    schedule window. The minimum-host floor is absolute, and a host carrying
    sessions is never stopped - it is drained and left for the next run.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER SubscriptionId
    Azure subscription. The current context when omitted.

.PARAMETER ResourceGroupName
    Resource group holding the host pool.

.PARAMETER HostPoolName
    AVD host pool name.

.PARAMETER PeakHostCount
    Hosts to run during peak hours.

.PARAMETER OffPeakHostCount
    Hosts to run outside peak hours.

.PARAMETER PeakStartHour
    First hour of the peak window, local time.

.PARAMETER PeakEndHour
    Last hour of the peak window, local time.

.PARAMETER MinimumHosts
    Absolute floor on running hosts. Never breached, whatever the schedule
    says.

.PARAMETER PeakDayOfWeek
    Days the peak window applies on.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Set-AvdHostPoolScale.ps1 -ResourceGroupName rg-avd -HostPoolName hp-prod -PeakHostCount 10 -OffPeakHostCount 2 -MinimumHosts 2

    Schedule-driven scaling with a floor of two hosts.

.EXAMPLE
    .\Set-AvdHostPoolScale.ps1 -ResourceGroupName rg-avd -HostPoolName hp-prod -PeakHostCount 10 -OffPeakHostCount 2 -WhatIf

    Shows what would start or stop.

.NOTES
    Source use case      : #4 - AVD Host Pool Scaling Automation
    Category             : Azure AVD
    Technology           : Azure Automation / Logic Apps
    Difficulty           : Medium
    Agent possible       : Partial
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Schedule/load-based scaling with min-host guardrails"

    Required permissions : Desktop Virtualization Host Pool Contributor, plus Virtual Machine Contributor on the session host VMs.
    Required modules     : Az.Accounts, Az.DesktopVirtualization, Az.Compute
    Authentication       : Inherits the Az context; managed identity preferred.

    The minimum-host floor is checked against the target BEFORE anything
    is stopped, and it wins over the schedule. Azure also has native
    scaling plans, which do load-based scaling properly and are the better
    answer for a pool that needs it; this script is the simpler
    schedule-driven alternative for pools where a scaling plan is more
    machinery than the problem deserves. A host with active sessions is
    drained rather than stopped, and picked up on a later run once it is
    empty - stopping a host with users on it is a disconnection, not a
    scale-down.

    Rollback             : Reversible - the next run scales back according to
                           the schedule. A stopped host is started again in
                           seconds to minutes; nothing on it is lost, since
                           FSLogix keeps profiles on the share rather than the
                           host.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.DesktopVirtualization
#Requires -Modules Az.Compute

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$HostPoolName,

    [Parameter(Mandatory)]
    [ValidateRange(1,500)]
    [int]$PeakHostCount,

    [Parameter(Mandatory)]
    [ValidateRange(0,500)]
    [int]$OffPeakHostCount,

    [ValidateRange(0,23)]
    [int]$PeakStartHour = 7,

    [ValidateRange(0,23)]
    [int]$PeakEndHour = 18,

    [ValidateRange(1,500)]
    [int]$MinimumHosts = 1,

    [string[]]$PeakDayOfWeek = @('Monday','Tuesday','Wednesday','Thursday','Friday'),

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-AvdHostPoolScale'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #4 (Azure AVD)'

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
        Connect-AutomationPlatform -Platform 'AzureAVD' | Out-Null


        $azContext = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $azContext) {
            throw 'No Azure context. Run Connect-AzAccount, or use a managed identity, before this script.'
        }
        if ($SubscriptionId -and $azContext.Subscription.Id -ne $SubscriptionId) {
            $azContext = Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop
        }

        $hostPool = Get-AzWvdHostPool -ResourceGroupName $ResourceGroupName -Name $HostPoolName -ErrorAction Stop
        if (-not $hostPool) {
            throw ('Host pool "{0}" not found in resource group "{1}".' -f $HostPoolName, $ResourceGroupName)
        }
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Host pool {0}: type {1}, load balancer {2}, max sessions {3}' -f
            $hostPool.Name, $hostPool.HostPoolType, $hostPool.LoadBalancerType, $hostPool.MaxSessionLimit)

        $sessionHosts = @(Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName `
            -HostPoolName $HostPoolName -ErrorAction Stop)
        if ($sessionHosts.Count -eq 0) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message 'Host pool contains no session hosts.'
        }

        function Get-AvdShortName {
            <#
                .SYNOPSIS
                    The session host name without the host pool prefix Azure prepends.
            #>
            [CmdletBinding()]
            [OutputType([string])]
            param([Parameter(Mandatory)][string]$FullName)

            return ($FullName -split '/')[-1]
        }

        $now = Get-Date
        $isPeakDay = $PeakDayOfWeek -contains "$($now.DayOfWeek)"
        $isPeakHour = if ($PeakStartHour -le $PeakEndHour) {
            $now.Hour -ge $PeakStartHour -and $now.Hour -le $PeakEndHour
        } else {
            $now.Hour -ge $PeakStartHour -or $now.Hour -le $PeakEndHour
        }
        $isPeak = ($isPeakDay -and $isPeakHour)
        $target = if ($isPeak) { $PeakHostCount } else { $OffPeakHostCount }

        # The floor wins over the schedule, always.
        if ($target -lt $MinimumHosts) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
                'Schedule target {0} is below the -MinimumHosts floor of {1}; the floor wins.' -f $target, $MinimumHosts)
            $target = $MinimumHosts
        }

        $vmByHost = @{}
        foreach ($sessionHost in $sessionHosts) {
            $shortName = Get-AvdShortName -FullName $sessionHost.Name
            $vmName = ($shortName -split '\.')[0]
            $vm = $null
            try {
                $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $vmName -Status -ErrorAction Stop
            } catch {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $shortName `
                    -Message ('Backing VM not resolved in {0}: {1}' -f $ResourceGroupName, $_.Exception.Message)
                continue
            }
            $powerState = ($vm.Statuses | Where-Object { $_.Code -like 'PowerState/*' } | Select-Object -First 1).Code
            $vmByHost[$shortName] = [PSCustomObject]@{
                VmName = $vmName; PowerState = "$powerState"; SessionHost = $sessionHost
                IsRunning = ("$powerState" -eq 'PowerState/running')
            }
        }

        $running = @($vmByHost.Values | Where-Object { $_.IsRunning })
        $stopped = @($vmByHost.Values | Where-Object { -not $_.IsRunning })

        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            '{0} window: {1} host(s) running, target {2}, floor {3}.' -f
            $(if ($isPeak) { 'PEAK' } else { 'off-peak' }), $running.Count, $target, $MinimumHosts)

        if ($running.Count -lt $target) {
            foreach ($candidate in (@($stopped) | Select-Object -First ($target - $running.Count))) {
                $results.Add([PSCustomObject]@{
                    Name           = $candidate.VmName
                    Id             = $candidate.VmName
                    VmName         = $candidate.VmName
                    SessionHostName = (Get-AvdShortName -FullName $candidate.SessionHost.Name)
                    Operation      = 'Start'
                    PowerState     = $candidate.PowerState
                    ActiveSessions = $candidate.SessionHost.Session
                    Window         = if ($isPeak) { 'peak' } else { 'off-peak' }
                    TargetCount    = $target
                    RunningCount   = $running.Count
                    Impact         = 'Host starts and joins the pool'
                })
            }
        } elseif ($running.Count -gt $target) {
            $toStop = $running.Count - $target
            # Emptiest first, so the fewest people are affected by a drain.
            foreach ($candidate in (@($running | Sort-Object { $_.SessionHost.Session }) | Select-Object -First $toStop)) {
                $sessions = [int]$candidate.SessionHost.Session
                $results.Add([PSCustomObject]@{
                    Name           = $candidate.VmName
                    Id             = $candidate.VmName
                    VmName         = $candidate.VmName
                    SessionHostName = (Get-AvdShortName -FullName $candidate.SessionHost.Name)
                    Operation      = if ($sessions -gt 0) { 'Drain' } else { 'Stop' }
                    PowerState     = $candidate.PowerState
                    ActiveSessions = $sessions
                    Window         = if ($isPeak) { 'peak' } else { 'off-peak' }
                    TargetCount    = $target
                    RunningCount   = $running.Count
                    Impact         = if ($sessions -gt 0) {
                                        ('{0} active session(s) - drained, not stopped. A later run picks it up once empty.' -f $sessions)
                                     } else { 'Empty host stopped' }
                })
            }
        } else {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
                'Already at target ({0} host(s)); nothing to do.' -f $target)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Scale host pool')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            switch ($item.Operation) {
                'Start' {
                    Start-AzVM -ResourceGroupName $ResourceGroupName -Name $item.VmName -ErrorAction Stop | Out-Null
                    Update-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName `
                        -Name $item.SessionHostName -AllowNewSession:$true -ErrorAction SilentlyContinue | Out-Null
                    $detail = 'Started and allowed to take new sessions'
                }
                'Drain' {
                    Update-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName `
                        -Name $item.SessionHostName -AllowNewSession:$false -ErrorAction Stop | Out-Null
                    $detail = ('Drained, NOT stopped - {0} active session(s) left connected' -f $item.ActiveSessions)
                }
                'Stop' {
                    Update-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName `
                        -Name $item.SessionHostName -AllowNewSession:$false -ErrorAction SilentlyContinue | Out-Null
                    Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $item.VmName -Force -ErrorAction Stop | Out-Null
                    $detail = 'Stopped (deallocated)'
                }
            }

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                '{0} in the {1} window (target {2}). {3}' -f $item.Operation, $item.Window, $item.TargetCount, $detail)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = $item.Operation; Detail = $detail; Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AVD Host Pool Scaling Automation'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
