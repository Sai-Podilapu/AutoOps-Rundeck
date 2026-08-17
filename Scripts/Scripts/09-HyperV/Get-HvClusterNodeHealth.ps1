<#
.SYNOPSIS
    Reports Hyper-V failover cluster node, quorum and resource health.

.DESCRIPTION
    Checks each cluster node state, the quorum configuration and witness,
    cluster shared volume health, and any resource not online. A cluster with
    a node down but quorum intact is a different situation from one that is
    one failure away from losing quorum, and this report distinguishes them.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER Cluster
    Cluster name(s) to check.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-HvClusterNodeHealth.ps1 -Cluster HVCLUSTER01

    Reports node, quorum and CSV health.

.EXAMPLE
    .\Get-HvClusterNodeHealth.ps1 -Cluster HVCLUSTER01 -OutputFormat HTML

    Writes the health report as HTML.

.NOTES
    Source use case      : #11 - Hyper-V Cluster Node Health
    Category             : Hyper-V
    Technology           : PowerShell / Failover Cluster
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Node status, quorum, resource health"

    Required permissions : Read access to the failover cluster.
    Required modules     : FailoverClusters
    Authentication       : Integrated Kerberos over PSRemoting; SCVMM cmdlets
                           where noted.

    The FailoverClusters cmdlets do not accept -Credential; they run in
    the caller's Kerberos context. Run this as an account with cluster
    read rights rather than passing a credential, and note that in the
    scheduled task definition.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules FailoverClusters

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory)]
    [string[]]$Cluster,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-HvClusterNodeHealth'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #11 (Hyper-V)'

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


        foreach ($cl in $Cluster) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $cl -Message 'Reading cluster health'

            $nodes = @(Get-ClusterNode -Cluster $cl -ErrorAction Stop)
            $up    = @($nodes | Where-Object { $_.State -eq 'Up' })
            $quorum = Get-ClusterQuorum -Cluster $cl -ErrorAction Stop
            $csvs  = @(Get-ClusterSharedVolume -Cluster $cl -ErrorAction SilentlyContinue)
            $badCsv = @($csvs | Where-Object { $_.State -ne 'Online' })
            $res   = @(Get-ClusterResource -Cluster $cl -ErrorAction SilentlyContinue)
            $badRes = @($res | Where-Object { $_.State -ne 'Online' })

            # Node majority quorum survives (n-1)/2 failures. Reporting the margin is
            # more useful than reporting only that quorum is currently held.
            $margin = [math]::Floor(($nodes.Count - 1) / 2) - ($nodes.Count - $up.Count)

            $issues = @()
            if ($up.Count -ne $nodes.Count) { $issues += ('{0} of {1} node(s) down' -f ($nodes.Count - $up.Count), $nodes.Count) }
            if ($badCsv.Count -gt 0)        { $issues += ('{0} CSV(s) not online' -f $badCsv.Count) }
            if ($badRes.Count -gt 0)        { $issues += ('{0} resource(s) not online' -f $badRes.Count) }
            if ($margin -le 0)              { $issues += 'NO REMAINING QUORUM MARGIN - one more failure loses the cluster' }

            $results.Add([PSCustomObject]@{
                Name             = $cl
                Id               = $cl
                NodesTotal       = $nodes.Count
                NodesUp          = $up.Count
                NodesDown        = (($nodes | Where-Object { $_.State -ne 'Up' }).Name -join '; ')
                QuorumType       = "$($quorum.QuorumType)"
                QuorumResource   = $quorum.QuorumResource
                FailureMargin    = $margin
                CsvTotal         = $csvs.Count
                CsvNotOnline     = (($badCsv.Name) -join '; ')
                ResourcesNotOnline = (($badRes.Name) -join '; ')
                Status           = if ($issues.Count) { 'Degraded' } else { 'Healthy' }
                Issues           = ($issues -join '; ')
            })
            if ($issues.Count) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $cl -Message ($issues -join '; ')
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Hyper-V Cluster Node Health'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
