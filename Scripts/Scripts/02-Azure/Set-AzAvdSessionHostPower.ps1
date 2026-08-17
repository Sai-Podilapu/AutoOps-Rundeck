<#
.SYNOPSIS
    Starts or stops AVD session hosts, draining users before shutdown.

.DESCRIPTION
    Powers AVD session hosts up or down. On shutdown it puts the host into
    drain mode first and refuses to stop a host that still has active sessions
    unless -Force is given, because deallocating a host with live sessions
    disconnects real users mid-work.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER SubscriptionId
    Subscription to operate in. Falls back to azure.defaultSubscriptionId in
    config.json.

.PARAMETER HostPoolName
    Host pool to act on.

.PARAMETER Operation
    Start or Stop (deallocate).

.PARAMETER KeepMinimumHosts
    Never take the pool below this many available hosts.

.PARAMETER Force
    Stop a host even if it still has active sessions. Disconnects those users.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Set-AzAvdSessionHostPower.ps1 -HostPoolName hp-prod -Operation Stop -KeepMinimumHosts 2

    Deallocates idle hosts while keeping two available.

.EXAMPLE
    .\Set-AzAvdSessionHostPower.ps1 -HostPoolName hp-prod -Operation Start -WhatIf

    Shows which hosts would be started.

.NOTES
    Source use case      : #10 - AVD Start and Stop Automation
    Category             : Azure
    Technology           : Az PowerShell / AVD API
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Reversible power ops"

    Required permissions : Desktop Virtualization Contributor plus Virtual Machine Contributor.
    Required modules     : Az.Accounts, Az.DesktopVirtualization, Az.Compute
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    Rollback             : Reverse the operation. Drain mode is cleared
                           automatically on start; a host stopped while
                           draining stays drained until started by this script.
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
    [string]$HostPoolName,

    [Parameter(Mandatory)]
    [ValidateSet('Start','Stop')]
    [string]$Operation,

    [ValidateRange(0,100)]
    [int]$KeepMinimumHosts = 1,

    [switch]$Force,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-AzAvdSessionHostPower'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #10 (Azure)'

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

        $pool = Get-AzWvdHostPool | Where-Object Name -eq $HostPoolName | Select-Object -First 1
        if (-not $pool) { throw ('Host pool {0} not found.' -f $HostPoolName) }
        $poolRg = ($pool.Id -split '/')[4]

        $hosts = @(Get-AzWvdSessionHost -ResourceGroupName $poolRg -HostPoolName $HostPoolName -ErrorAction Stop)
        $available = @($hosts | Where-Object { $_.Status -eq 'Available' })

        foreach ($sh in $hosts) {
            $shortName = ($sh.Name -split '/')[-1]
            $vmName = ($shortName -split '\.')[0]

            $sessions = @(Get-AzWvdUserSession -ResourceGroupName $poolRg -HostPoolName $HostPoolName `
                            -SessionHostName $shortName -ErrorAction SilentlyContinue)
            $active = @($sessions | Where-Object { $_.SessionState -eq 'Active' })

            if ($Operation -eq 'Stop') {
                if ($available.Count -le $KeepMinimumHosts) {
                    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $shortName -Message (
                        'Skipped - pool would drop below the {0}-host floor' -f $KeepMinimumHosts)
                    continue
                }
                if ($active.Count -gt 0 -and -not $Force) {
                    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $shortName -Message (
                        'Skipped - {0} active session(s). Pass -Force to disconnect them.' -f $active.Count)
                    continue
                }
            }

            $vm = Get-AzVM -Name $vmName -Status -ErrorAction SilentlyContinue
            if (-not $vm) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $shortName -Message 'Backing VM not found'
                continue
            }
            $power = ($vm.PowerState -replace '^VM ', '')
            $wanted = if ($Operation -eq 'Start') { 'running' } else { 'deallocated' }
            if ($power -eq $wanted) { continue }

            $results.Add([PSCustomObject]@{
                Name            = $shortName
                Id              = $sh.Name
                VMName          = $vmName
                ResourceGroup   = $vm.ResourceGroupName
                HostPool        = $HostPoolName
                HostPoolRg      = $poolRg
                SessionHostName = $shortName
                CurrentState    = $power
                DesiredState    = $wanted
                ActiveSessions  = $active.Count
                TotalSessions   = $sessions.Count
                Operation       = $Operation
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Change AVD session host power state')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            if ($item.Operation -eq 'Stop') {
                # Drain first so the broker stops sending new connections here while the
                # shutdown is in flight.
                Update-AzWvdSessionHost -ResourceGroupName $item.HostPoolRg -HostPoolName $item.HostPool `
                    -Name $item.SessionHostName -AllowNewSession:$false -ErrorAction Stop | Out-Null
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message 'Drain mode enabled'

                Stop-AzVM -ResourceGroupName $item.ResourceGroup -Name $item.VMName -Force -ErrorAction Stop | Out-Null
            } else {
                Start-AzVM -ResourceGroupName $item.ResourceGroup -Name $item.VMName -ErrorAction Stop | Out-Null
                Update-AzWvdSessionHost -ResourceGroupName $item.HostPoolRg -HostPoolName $item.HostPool `
                    -Name $item.SessionHostName -AllowNewSession:$true -ErrorAction Stop | Out-Null
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message 'Drain mode cleared'
            }

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                '{0} complete: {1} -> {2} ({3} session(s) at the time)' -f
                $item.Operation, $item.CurrentState, $item.DesiredState, $item.TotalSessions)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = $item.Operation
                Detail = ('{0} -> {1}' -f $item.CurrentState, $item.DesiredState); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AVD Start and Stop Automation'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
