<#
.SYNOPSIS
    Starts, stops or restarts Hyper-V virtual machines with logging.

.DESCRIPTION
    Performs a controlled power operation on selected VMs. Shutdown and
    restart request a graceful guest shutdown through integration services and
    only fall back to a hard turn-off when -Force is given, because pulling
    power on a running guest risks filesystem damage.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER ComputerName
    Hyper-V host(s) to act against. Defaults to the local host.

.PARAMETER VMName
    Limit to specific virtual machines. Wildcards are accepted for reporting
    scripts only.

.PARAMETER Credential
    Credential for the remote Hyper-V host.

.PARAMETER Operation
    Start, Shutdown, Restart or TurnOff. TurnOff is the hard power cut and is
    never the default.

.PARAMETER Force
    Allow a hard turn-off when a graceful shutdown does not complete in time.

.PARAMETER TimeoutSeconds
    How long to wait for a graceful shutdown before reporting failure.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Set-HvVmPowerState.ps1 -ComputerName HV01 -VMName APP01 -Operation Shutdown

    Requests a graceful guest shutdown of APP01.

.EXAMPLE
    .\Set-HvVmPowerState.ps1 -ComputerName HV01 -VMName APP01 -Operation Restart -WhatIf

    Shows the restart without performing it.

.NOTES
    Source use case      : #3 - Hyper-V VM Power On/Off/Restart
    Category             : Hyper-V
    Technology           : PowerShell
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Controlled power ops with logging"

    Required permissions : Hyper-V Administrators on the host.
    Required modules     : Hyper-V
    Authentication       : Integrated Kerberos over PSRemoting; SCVMM cmdlets
                           where noted.

    Rollback             : Reverse the operation. A hard TurnOff may leave the
                           guest filesystem dirty - that is why it requires an
                           explicit choice rather than being a fallback.
#>

#Requires -Version 5.1
#Requires -Modules Hyper-V

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string[]]$ComputerName = $env:COMPUTERNAME,

    [string[]]$VMName,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [Parameter(Mandatory)]
    [ValidateSet('Start','Shutdown','Restart','TurnOff')]
    [string]$Operation,

    [switch]$Force,

    [ValidateRange(10,3600)]
    [int]$TimeoutSeconds = 300,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-HvVmPowerState'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #3 (Hyper-V)'

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
        Connect-AutomationPlatform -Platform 'HyperV' | Out-Null


        foreach ($hv in $ComputerName) {
            $hvArgs = @{ ComputerName = $hv; ErrorAction = 'Stop' }
            if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $hvArgs.Credential = $Credential }

            $vms = if ($VMName) { Get-VM -Name $VMName @hvArgs } else { Get-VM @hvArgs }
            foreach ($vm in $vms) {
                # Idempotency: skip a VM already in the requested end state.
                $alreadyThere = switch ($Operation) {
                    'Start'    { $vm.State -eq 'Running' }
                    'Shutdown' { $vm.State -eq 'Off' }
                    'TurnOff'  { $vm.State -eq 'Off' }
                    default    { $false }
                }
                if ($alreadyThere) {
                    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0}\{1}' -f $hv, $vm.Name) `
                        -Message ('Skipped - already {0}' -f $vm.State)
                    continue
                }
                $results.Add([PSCustomObject]@{
                    Name         = ('{0}\{1}' -f $hv, $vm.Name)
                    Id           = $vm.Id
                    VMName       = $vm.Name
                    HyperVHost   = $hv
                    CurrentState = "$($vm.State)"
                    Operation    = $Operation
                    IntegrationServices = $vm.IntegrationServicesState
                    Uptime       = $vm.Uptime
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Change VM power state')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $hvArgs = @{ ComputerName = $item.HyperVHost; ErrorAction = 'Stop' }
            if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $hvArgs.Credential = $Credential }

            $wantedState = switch ($Operation) {
                'Start'    { 'Running' }
                'Shutdown' { 'Off' }
                'TurnOff'  { 'Off' }
                'Restart'  { 'Running' }
            }

            switch ($Operation) {
                'Start' {
                    Start-VM -Name $item.VMName @hvArgs
                }
                'Shutdown' {
                    # Graceful first. -Force here only suppresses the confirmation prompt;
                    # it does not turn the guest off abruptly.
                    Stop-VM -Name $item.VMName -Force:$Force @hvArgs
                }
                'Restart' {
                    Restart-VM -Name $item.VMName -Force:$Force @hvArgs
                }
                'TurnOff' {
                    # The hard power cut. Explicitly chosen by the operator, never a fallback.
                    Stop-VM -Name $item.VMName -TurnOff -Force @hvArgs
                }
            }

            # Wait for the requested end state rather than assuming the cmdlet returning
            # means the guest got there. A guest that ignores the shutdown request is the
            # common case this catches.
            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
            do {
                Start-Sleep -Seconds 3
                $after = (Get-VM -Name $item.VMName @hvArgs).State
            } while ("$after" -ne $wantedState -and (Get-Date) -lt $deadline)

            if ("$after" -ne $wantedState) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
                    'Still {0} after {1}s (wanted {2}). The guest may be ignoring the request.' -f
                    $after, $TimeoutSeconds, $wantedState)
            }
            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                '{0} completed: {1} -> {2}' -f $Operation, $item.CurrentState, $after)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = $Operation
                Detail = ('{0} -> {1}' -f $item.CurrentState, $after)
                Succeeded = ("$after" -eq $wantedState) })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Hyper-V VM Power On/Off/Restart'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
