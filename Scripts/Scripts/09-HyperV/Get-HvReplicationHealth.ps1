<#
.SYNOPSIS
    Reports Hyper-V Replica health and replication lag.

.DESCRIPTION
    Checks every replication-enabled VM for its health state, mode and the age
    of the last replicated change. Replication that is technically enabled but
    hours behind is the failure this catches - it looks healthy in the console
    until you need it.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER ComputerName
    Hyper-V host(s) to act against. Defaults to the local host.

.PARAMETER Credential
    Credential for the remote Hyper-V host.

.PARAMETER MaxLagMinutes
    Flag replication whose last successful replication is older than this.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-HvReplicationHealth.ps1 -ComputerName HV01,HV02

    Reports replication health across two hosts.

.EXAMPLE
    .\Get-HvReplicationHealth.ps1 -MaxLagMinutes 15 -OutputFormat HTML

    Applies a tight lag threshold and writes HTML.

.NOTES
    Source use case      : #7 - Hyper-V Replication Health Check
    Category             : Hyper-V
    Technology           : PowerShell / Hyper-V Replica
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Verify replication lag and state"

    Required permissions : Hyper-V Administrators on the host.
    Required modules     : Hyper-V
    Authentication       : Integrated Kerberos over PSRemoting; SCVMM cmdlets
                           where noted.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Hyper-V

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string[]]$ComputerName = $env:COMPUTERNAME,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [ValidateRange(1,10080)]
    [int]$MaxLagMinutes = 60,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-HvReplicationHealth'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #7 (Hyper-V)'

    try {
        $config = if ($ConfigPath) { Get-AutomationConfig -Path $ConfigPath } else { Get-AutomationConfig }
        # Recorded so an audit can tell which environment a run targeted.
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Configuration loaded for environment: {0}' -f $config.environment)
    } catch {
        # Read-only: config only supplies optional notification endpoints,
        # so its absence must not stop a report from being produced.
        $config = $null
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
            'Config unavailable ({0}); continuing because this script only reads.' -f $_.Exception.Message)
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

            $repl = @(Get-VMReplication @hvArgs -ErrorAction SilentlyContinue)
            if ($repl.Count -eq 0) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $hv -Message 'No replication-enabled VMs on this host'
                continue
            }

            foreach ($r in $repl) {
                $lagMin = $null
                if ($r.LastReplicationTime) {
                    $lagMin = [math]::Round(((Get-Date) - $r.LastReplicationTime).TotalMinutes, 1)
                }
                $issues = @()
                if ($r.Health -ne 'Normal')                      { $issues += "health is $($r.Health)" }
                if ($r.State -notin @('Replicating','ReadyForInitialReplication')) { $issues += "state is $($r.State)" }
                if ($null -eq $lagMin)                           { $issues += 'never replicated' }
                elseif ($lagMin -gt $MaxLagMinutes)              { $issues += "lag ${lagMin}min" }

                $results.Add([PSCustomObject]@{
                    Name                = ('{0}\{1}' -f $hv, $r.VMName)
                    Id                  = $r.VMName
                    HyperVHost          = $hv
                    ReplicationState    = "$($r.State)"
                    ReplicationHealth   = "$($r.Health)"
                    ReplicationMode     = "$($r.Mode)"
                    PrimaryServer       = $r.PrimaryServerName
                    ReplicaServer       = $r.ReplicaServerName
                    LastReplication     = $r.LastReplicationTime
                    LagMinutes          = $lagMin
                    FrequencySeconds    = $r.FrequencySec
                    Status              = if ($issues.Count) { 'Unhealthy' } else { 'Healthy' }
                    Issues              = ($issues -join '; ')
                })
                if ($issues.Count) {
                    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target ('{0}\{1}' -f $hv, $r.VMName) `
                        -Message ($issues -join '; ')
                }
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

    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message ('Collected {0} record(s).' -f $candidates.Count)
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Hyper-V Replication Health Check'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
