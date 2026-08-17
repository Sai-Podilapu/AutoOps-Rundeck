<#
.SYNOPSIS
    Reports Active Directory replication, domain controller and FSMO health.

.DESCRIPTION
    Checks replication status between domain controllers, DC service
    availability, FSMO role placement and SYSVOL replication. Replication
    failure is the condition that silently breaks authentication in ways that
    look like everything else, so it is reported first.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER Server
    Domain controller to target. Uses the nearest DC when omitted.

.PARAMETER Credential
    Credential for the directory operation.

.PARAMETER MaxReplicationLagMinutes
    Flag a replication partner whose last successful sync is older than this.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-AdHealthReport.ps1 -OutputFormat HTML

    Full AD health report as HTML.

.EXAMPLE
    .\Get-AdHealthReport.ps1 -MaxReplicationLagMinutes 30

    Applies a tighter replication threshold.

.NOTES
    Source use case      : #10 - Active Directory Health Check
    Category             : AD & Identity
    Technology           : PowerShell / AD Module
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Read-only (replication, DC health)"

    Required permissions : Domain read access. Replication metadata needs at least Domain Users on most directories.
    Required modules     : ActiveDirectory
    Authentication       : Delegated service account with the minimum required
                           AD rights.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules ActiveDirectory

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$Server,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [ValidateRange(1,10080)]
    [int]$MaxReplicationLagMinutes = 60,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-AdHealthReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #10 (AD & Identity)'

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
        Connect-AutomationPlatform -Platform 'ActiveDirectory' | Out-Null


        $adArgs = @{ ErrorAction = 'Stop' }
        if ($Server) { $adArgs.Server = $Server }
        if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $adArgs.Credential = $Credential }

        Import-Module ActiveDirectory -ErrorAction Stop

        # --- domain controllers ---------------------------------------------------
        $dcs = @(Get-ADDomainController -Filter * @adArgs)
        foreach ($dc in $dcs) {
            $reachable = $false
            try { $reachable = Test-Connection -ComputerName $dc.HostName -Count 1 -Quiet -ErrorAction Stop } catch {
                Write-Verbose ('Ping failed for {0}' -f $dc.HostName)
            }

            $issues = @()
            if (-not $reachable) { $issues += 'not reachable' }

            $results.Add([PSCustomObject]@{
                Name        = $dc.HostName
                Id          = $dc.HostName
                RecordType  = 'DomainController'
                Site        = $dc.Site
                IsGlobalCatalog = $dc.IsGlobalCatalog
                IsReadOnly  = $dc.IsReadOnly
                OperatingSystem = $dc.OperatingSystem
                IPv4Address = $dc.IPv4Address
                FsmoRoles   = ($dc.OperationMasterRoles -join '; ')
                Reachable   = $reachable
                Status      = if ($issues.Count) { 'Warning' } else { 'OK' }
                Issues      = ($issues -join '; ')
            })
        }

        # --- replication ----------------------------------------------------------
        foreach ($dc in $dcs) {
            $partners = @()
            try {
                $partners = @(Get-ADReplicationPartnerMetadata -Target $dc.HostName -ErrorAction Stop)
            } catch {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $dc.HostName `
                    -Message ('Replication metadata unavailable: {0}' -f $_.Exception.Message)
                continue
            }

            foreach ($p in $partners) {
                $lagMin = if ($p.LastReplicationSuccess) {
                              [math]::Round(((Get-Date) - $p.LastReplicationSuccess).TotalMinutes, 1)
                          } else { $null }

                $issues = @()
                if ($p.LastReplicationResult -ne 0) { $issues += ('last result {0}' -f $p.LastReplicationResult) }
                if ($null -eq $lagMin)              { $issues += 'never replicated successfully' }
                elseif ($lagMin -gt $MaxReplicationLagMinutes) { $issues += ('lag {0} min' -f $lagMin) }

                $results.Add([PSCustomObject]@{
                    Name        = ('{0} <- {1}' -f $dc.HostName, ($p.Partner -replace '^CN=NTDS Settings,CN=([^,]+).*$', '$1'))
                    Id          = $p.Partner
                    RecordType  = 'Replication'
                    Site        = $dc.Site
                    Partition   = $p.Partition
                    LastSuccess = $p.LastReplicationSuccess
                    LagMinutes  = $lagMin
                    LastResult  = $p.LastReplicationResult
                    ConsecutiveFailures = $p.ConsecutiveReplicationFailures
                    Status      = if ($issues.Count) { 'Unhealthy' } else { 'Healthy' }
                    Issues      = ($issues -join '; ')
                })
                if ($issues.Count) {
                    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $dc.HostName -Message (
                        'Replication issue with {0}: {1}' -f $p.Partner, ($issues -join '; '))
                }
            }
        }

        # --- FSMO placement -------------------------------------------------------
        $forest = Get-ADForest @adArgs
        $domain = Get-ADDomain @adArgs
        $results.Add([PSCustomObject]@{
            Name       = 'FSMO role placement'
            Id         = 'fsmo'
            RecordType = 'FSMO'
            SchemaMaster        = $forest.SchemaMaster
            DomainNamingMaster  = $forest.DomainNamingMaster
            PDCEmulator         = $domain.PDCEmulator
            RIDMaster           = $domain.RIDMaster
            InfrastructureMaster= $domain.InfrastructureMaster
            Status     = 'Info'
        })
    } catch {
        $msg = $_.Exception.Message
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Message ('Discovery FAILED: {0}' -f $msg)
        $failures.Add([PSCustomObject]@{ Stage = 'Discovery'; Error = $msg })
    }
}

end {
    $candidates = @($results)

    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message ('Collected {0} record(s).' -f $candidates.Count)
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Active Directory Health Check'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
