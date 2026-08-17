<#
.SYNOPSIS
    Surfaces anomalies in OCI VCN flow logs for analyst review.

.DESCRIPTION
    Runs a set of queries against VCN flow logs and ranks what comes back:
    rejected-traffic concentrations, top talkers by volume, and connections on
    unusual ports. Every finding carries a note on why it might be benign.
    Deciding whether any of it is an incident is an analyst's job and is not
    attempted here.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

    AGENT-ASSIST ONLY. This automates the mechanical part - gathering,
    enriching and comparing against a baseline - and then stops, producing
    a decision-ready package. The judgement step is deliberately left to a
    human and is NOT scripted.

.PARAMETER CompartmentId
    Compartment OCID to operate in. Falls back to oci.defaultCompartmentId in
    config.json.

.PARAMETER Region
    OCI region identifier, e.g. me-dubai-1. Falls back to oci.defaultRegion in
    config.json, then to the region in the CLI profile.

.PARAMETER CliProfile
    Named profile in the OCI CLI config file. Not called -Profile because
    $Profile is a PowerShell automatic variable.

.PARAMETER CliConfigFile
    Path to the OCI CLI config file. The CLI default (~/.oci/config) is used
    when omitted.

.PARAMETER OciCliPath
    Full path to the oci executable. Resolved from PATH when omitted.

.PARAMETER LogGroupId
    Logging log group containing the VCN flow logs.

.PARAMETER LookbackHours
    Query window.

.PARAMETER MinimumRejects
    Report a source with at least this many rejected connections.

.PARAMETER MaxResults
    Ceiling on log records retrieved per query.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-OciVcnFlowLogAnomaly.ps1 -LogGroupId ocid1.loggroup... -LookbackHours 24

    Daily anomaly package for analyst review.

.EXAMPLE
    .\Get-OciVcnFlowLogAnomaly.ps1 -LogGroupId ocid1.loggroup... -MinimumRejects 200 -OutputFormat HTML

    Higher threshold, HTML output.

.NOTES
    Source use case      : #14 - OCI VCN Flow Log Analysis
    Category             : OCI
    Technology           : OCI Logging / CLI
    Difficulty           : High
    Agent possible       : Yes
    Can execute with SOP : Partially - Agent Assists
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Agent surfaces anomalies; interpretation & incident declaration need analyst judgment"

    Required permissions : An IAM policy allowing LOG_GROUP_INSPECT and read on the log content.
    Required modules     : none beyond IT-Automation-Common
    Authentication       : OCI CLI config profile. NOTE: there is no
                           first-party OCI PowerShell module - this wraps the
                           OCI CLI.

    AGENT-ASSIST ONLY. Flow log volume makes manual review impractical,
    which is what this automates; separating a real threat from a
    misconfigured health check is not automatable and is deliberately left
    alone. Every finding carries an AnalystNote giving the benign
    explanation, because a ranked list with no counter-argument reads as a
    list of incidents.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$CompartmentId,

    [string]$Region,

    [string]$CliProfile,

    [string]$CliConfigFile,

    [string]$OciCliPath,

    [Parameter(Mandatory)]
    [string]$LogGroupId,

    [ValidateRange(1,168)]
    [int]$LookbackHours = 24,

    [ValidateRange(1,100000)]
    [int]$MinimumRejects = 50,

    [ValidateRange(10,50000)]
    [int]$MaxResults = 5000,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-OciVcnFlowLogAnomaly'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #14 (OCI)'

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
        Connect-AutomationPlatform -Platform 'OCI' | Out-Null


        function Invoke-OciCli {
            <#
                .SYNOPSIS
                    Runs one oci CLI command and returns its parsed JSON output.
                .DESCRIPTION
                    Appends the profile, config file, region and --output json, runs the
                    CLI, and throws on a non-zero exit code. Defined inside the script
                    rather than in the shared module because it depends on this run's
                    resolved CLI path and profile.
            #>
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)]
                [string[]]$Argument,

                [switch]$Raw
            )

            $cliArgs = @($Argument)
            if ($ociProfile)    { $cliArgs += @('--profile', $ociProfile) }
            if ($ociConfigFile) { $cliArgs += @('--config-file', $ociConfigFile) }
            if ($Region)        { $cliArgs += @('--region', $Region) }
            $cliArgs += @('--output', 'json')

            $errFile = [System.IO.Path]::GetTempFileName()
            $previousPreference = $ErrorActionPreference
            # Windows PowerShell turns redirected native stderr into terminating errors
            # under 'Stop', even when the process exits 0. The exit code is the signal
            # that actually matters, so the preference is relaxed for the call only.
            $ErrorActionPreference = 'Continue'
            $exitCode = 0
            try {
                $stdout = & $ociCli @cliArgs 2>$errFile
                $exitCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $previousPreference
            }

            $stderrText = ''
            if (Test-Path -LiteralPath $errFile) {
                $stderrText = "$(Get-Content -LiteralPath $errFile -Raw)"
                Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
            }

            if ($exitCode -ne 0) {
                # Redacted on the way into the log by Write-AutomationLog.
                throw ('oci {0} failed (exit {1}): {2}' -f ($Argument -join ' '), $exitCode, $stderrText.Trim())
            }

            $text = (@($stdout) -join "`n").Trim()
            if ($Raw) { return $text }
            if (-not $text) { return $null }
            try {
                return ($text | ConvertFrom-Json)
            } catch {
                throw ('oci {0} returned output that is not JSON: {1}' -f ($Argument -join ' '),
                       $text.Substring(0, [math]::Min(200, $text.Length)))
            }
        }

        $ociCli = if ($OciCliPath) { $OciCliPath } else { 'oci' }
        $resolvedCli = Get-Command -Name $ociCli -ErrorAction SilentlyContinue
        if (-not $resolvedCli) {
            throw ('The OCI CLI was not found ("{0}"). Install it and ensure it is on PATH, or pass ' +
                   '-OciCliPath. There is no first-party OCI PowerShell module; this script wraps the CLI.' -f $ociCli)
        }
        $ociCli = $resolvedCli.Source

        $ociProfile = $CliProfile
        $ociConfigFile = $CliConfigFile
        if ($config -and $config.oci) {
            if (-not $ociProfile -and $config.oci.profileName)          { $ociProfile = $config.oci.profileName }
            if (-not $Region -and $config.oci.defaultRegion)            { $Region = $config.oci.defaultRegion }
            if (-not $CompartmentId -and $config.oci.defaultCompartmentId) { $CompartmentId = $config.oci.defaultCompartmentId }
        }

        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Using OCI CLI at {0}{1}{2}' -f $ociCli,
            $(if ($ociProfile) { ", profile '$ociProfile'" } else { ', default profile' }),
            $(if ($Region) { ", region '$Region'" } else { ', region from profile' }))

        if (-not $CompartmentId) {
            throw 'No compartment. Pass -CompartmentId or set oci.defaultCompartmentId in config.json.'
        }

        $end = Get-Date
        $start = $end.AddHours(-$LookbackHours)
        $startIso = $start.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $endIso = $end.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

        $records = @()
        try {
            $query = 'search "{0}/{1}"' -f $CompartmentId, $LogGroupId
            $resp = Invoke-OciCli -Argument @('logging-search', 'search-logs',
                '--search-query', $query,
                '--time-start', $startIso, '--time-end', $endIso,
                '--limit', "$MaxResults")
            $records = @($resp.data.results)
        } catch {
            throw ('Log search failed: {0}. Confirm the log group OCID and that flow logs are enabled on ' +
                   'the subnets of interest.' -f $_.Exception.Message)
        }

        if ($records.Count -eq 0) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'No flow log records returned for the window. Either there was no traffic, or flow logging ' +
                'is not enabled on the subnets - those are very different situations and this query cannot ' +
                'tell them apart.')
        }
        if ($records.Count -ge $MaxResults) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'Hit the -MaxResults ceiling of {0}. The analysis below is based on a TRUNCATED sample and ' +
                'the rankings may not reflect the full window.' -f $MaxResults)
        }

        $flows = @()
        foreach ($rec in $records) {
            $d = $rec.data
            if (-not $d) { continue }
            $flows += [PSCustomObject]@{
                Source      = "$($d.sourceAddress)"
                Destination = "$($d.destinationAddress)"
                Port        = "$($d.destinationPort)"
                Action      = "$($d.action)"
                Bytes       = [int64]("0" + "$($d.bytesOut)")
                Packets     = [int64]("0" + "$($d.packets)")
            }
        }

        # --- rejected traffic concentrations ---------------------------------
        foreach ($g in ($flows | Where-Object { $_.Action -match '(?i)reject|deny|drop' } |
                        Group-Object Source | Where-Object { $_.Count -ge $MinimumRejects } |
                        Sort-Object Count -Descending | Select-Object -First 25)) {
            $ports = @($g.Group.Port | Group-Object | Sort-Object Count -Descending | Select-Object -First 5)
            $results.Add([PSCustomObject]@{
                Name        = ('Rejected traffic from {0}' -f $g.Name)
                Id          = ('reject-{0}' -f $g.Name)
                Finding     = 'RejectedConcentration'
                Source      = $g.Name
                Destination = ''
                Ports       = (($ports | ForEach-Object { '{0}({1})' -f $_.Name, $_.Count }) -join '; ')
                EventCount  = $g.Count
                Bytes       = ($g.Group | Measure-Object Bytes -Sum).Sum
                AnalystNote = 'Could be a scan, or a decommissioned client still retrying, or a health check ' +
                              'against a port that moved. Check whether the source is one of yours before treating it as hostile.'
            })
        }

        # --- top talkers by volume -------------------------------------------
        foreach ($g in ($flows | Where-Object { $_.Action -match '(?i)accept|allow' } |
                        Group-Object Source | Sort-Object { ($_.Group | Measure-Object Bytes -Sum).Sum } -Descending |
                        Select-Object -First 10)) {
            $sum = ($g.Group | Measure-Object Bytes -Sum).Sum
            $results.Add([PSCustomObject]@{
                Name        = ('Top talker {0}' -f $g.Name)
                Id          = ('talker-{0}' -f $g.Name)
                Finding     = 'TopTalker'
                Source      = $g.Name
                Destination = (($g.Group.Destination | Select-Object -Unique | Select-Object -First 3) -join '; ')
                Ports       = (($g.Group.Port | Group-Object | Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object { $_.Name }) -join '; ')
                EventCount  = $g.Count
                Bytes       = $sum
                AnalystNote = 'Volume alone is not suspicious. Backup, replication and log shipping all look ' +
                              'like this. Compare against what this host is supposed to do.'
            })
        }

        # --- unusual destination ports ---------------------------------------
        $commonPorts = @('22','53','80','123','443','445','3306','1521','5432','8080','8443')
        foreach ($g in ($flows | Where-Object { $_.Action -match '(?i)accept|allow' -and $commonPorts -notcontains $_.Port } |
                        Group-Object Port | Sort-Object Count -Descending | Select-Object -First 15)) {
            $results.Add([PSCustomObject]@{
                Name        = ('Unusual port {0}' -f $g.Name)
                Id          = ('port-{0}' -f $g.Name)
                Finding     = 'UnusualPort'
                Source      = (($g.Group.Source | Select-Object -Unique | Select-Object -First 5) -join '; ')
                Destination = (($g.Group.Destination | Select-Object -Unique | Select-Object -First 5) -join '; ')
                Ports       = $g.Name
                EventCount  = $g.Count
                Bytes       = ($g.Group | Measure-Object Bytes -Sum).Sum
                AnalystNote = 'Unusual only relative to a fixed common-port list. Application-specific ports ' +
                              'and ephemeral ranges land here routinely.'
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

    # Agent-assist: the package is produced for a human. The script does
    # NOT proceed to a decision - that step is deliberately not automated.
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'Decision-ready package built: {0} item(s). Human review required.' -f $candidates.Count)
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message ('Collected {0} record(s).' -f $candidates.Count)
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'OCI VCN Flow Log Analysis'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
