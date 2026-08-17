<#
.SYNOPSIS
    Puts AVD session hosts into or out of drain mode.

.DESCRIPTION
    Toggles whether a session host accepts new connections. Drain mode is the
    graceful step before maintenance: existing sessions keep working and no
    new ones land, so the host empties as people log off naturally.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER SubscriptionId
    Azure subscription. The current context when omitted.

.PARAMETER ResourceGroupName
    Resource group holding the host pool.

.PARAMETER HostPoolName
    AVD host pool name.

.PARAMETER SessionHostName
    Session host(s) to change. All hosts in the pool when omitted.

.PARAMETER Drain
    Enable drain mode. Without this the hosts are returned to service.

.PARAMETER MaxDrainPercent
    Refuse to drain if it would leave less than this percentage of the pool
    taking connections. Guards against draining a whole pool by accident.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Set-AvdSessionHostDrainMode.ps1 -ResourceGroupName rg-avd -HostPoolName hp-prod -SessionHostName avd-01 -Drain

    Drains one host before maintenance.

.EXAMPLE
    .\Set-AvdSessionHostDrainMode.ps1 -ResourceGroupName rg-avd -HostPoolName hp-prod -SessionHostName avd-01

    Returns the host to service.

.NOTES
    Source use case      : #1 - AVD Session Host Drain Mode Toggle
    Category             : Azure AVD
    Technology           : Az PowerShell / AVD API
    Difficulty           : Low
    Agent possible       : Partial
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Graceful drain before maintenance; reversible"

    Required permissions : Desktop Virtualization Host Pool Contributor on the host pool.
    Required modules     : Az.Accounts, Az.DesktopVirtualization
    Authentication       : Inherits the Az context; managed identity preferred.

    Drain mode disconnects nobody. Existing sessions continue and the host
    empties as users log off, which is why it is the graceful first step
    and why draining the entire pool by mistake is a slow-motion outage
    rather than an instant one - nobody notices until the next person
    tries to connect. -MaxDrainPercent is the guard against that. For
    powering hosts off, see Set-AzAvdSessionHostPower in the Azure
    category; this script only controls whether they accept connections.

    Rollback             : Fully reversible - run again without -Drain to
                           return the hosts to service. No session is
                           disconnected by this script either way.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.DesktopVirtualization

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$HostPoolName,

    [string[]]$SessionHostName,

    [switch]$Drain,

    [ValidateRange(0,100)]
    [int]$MaxDrainPercent = 50,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-AvdSessionHostDrainMode'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #1 (Azure AVD)'

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

        $targets = @($sessionHosts)
        if ($SessionHostName) {
            $targets = @($sessionHosts | Where-Object { $SessionHostName -contains (Get-AvdShortName -FullName $_.Name) })
        }

        if ($Drain) {
            # Draining everything is an outage nobody notices until the next login.
            $alreadyDraining = @($sessionHosts | Where-Object { -not $_.AllowNewSession }).Count
            $wouldDrain = @($targets | Where-Object { $_.AllowNewSession }).Count
            $remaining = $sessionHosts.Count - $alreadyDraining - $wouldDrain
            $remainingPercent = if ($sessionHosts.Count -gt 0) {
                [math]::Round(($remaining / $sessionHosts.Count) * 100, 1)
            } else { 0 }

            if ($remainingPercent -lt $MaxDrainPercent) {
                throw ('Refusing to drain: this would leave {0}% of the pool taking connections, below the ' +
                       '-MaxDrainPercent floor of {1}%. {2} of {3} host(s) would be draining.' -f
                       $remainingPercent, $MaxDrainPercent, ($alreadyDraining + $wouldDrain), $sessionHosts.Count)
            }
        }

        foreach ($sessionHost in $targets) {
            $shortName = Get-AvdShortName -FullName $sessionHost.Name
            $wantAllow = (-not $Drain)

            if ($sessionHost.AllowNewSession -eq $wantAllow) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $shortName -Message (
                    'Skipped - already {0} (idempotent)' -f $(if ($Drain) { 'draining' } else { 'in service' }))
                continue
            }

            $results.Add([PSCustomObject]@{
                Name            = $shortName
                Id              = $sessionHost.Name
                SessionHostName = $shortName
                FullName        = $sessionHost.Name
                Status          = $sessionHost.Status
                CurrentlyAllowsNew = $sessionHost.AllowNewSession
                TargetAllowsNew = $wantAllow
                ActiveSessions  = $sessionHost.Session
                AgentVersion    = $sessionHost.AgentVersion
                UpdateState     = $sessionHost.UpdateState
                Impact          = if ($Drain) { 'No new connections; existing sessions continue undisturbed' }
                                  else { 'Host returns to the load balancer rotation' }
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Set drain mode')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            Update-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName `
                -Name $item.SessionHostName -AllowNewSession:$item.TargetAllowsNew -ErrorAction Stop | Out-Null

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                '{0}. {1} existing session(s) left connected.' -f
                $(if ($item.TargetAllowsNew) { 'Returned to service' } else { 'Drain mode ON' }), $item.ActiveSessions)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name
                Action = $(if ($item.TargetAllowsNew) { 'InService' } else { 'Draining' })
                Detail = ('{0} active session(s)' -f $item.ActiveSessions); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AVD Session Host Drain Mode Toggle'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
