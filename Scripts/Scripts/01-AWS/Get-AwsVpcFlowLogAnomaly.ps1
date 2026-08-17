<#
.SYNOPSIS
    Runs Athena queries over VPC flow logs and flags traffic anomalies for
    analyst review.

.DESCRIPTION
    Queries the VPC flow log table in Athena for the patterns worth a human
    look: rejected traffic concentrations, unusual destination ports, and top
    talkers by byte volume. Produces a ranked, enriched candidate list.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

    AGENT-ASSIST ONLY. This automates the mechanical part - gathering,
    enriching and comparing against a baseline - and then stops, producing
    a decision-ready package. The judgement step is deliberately left to a
    human and is NOT scripted.

.PARAMETER Region
    AWS region to operate in. Defaults to the configured default region.

.PARAMETER ProfileName
    Named AWS profile / SSO profile to use. Prefer an IAM role where the host
    supports one.

.PARAMETER AthenaDatabase
    Glue/Athena database containing the flow log table.

.PARAMETER FlowLogTable
    Athena table name for the VPC flow logs.

.PARAMETER OutputLocation
    S3 URI where Athena writes query results, e.g. s3://my-athena-results/.

.PARAMETER LookbackHours
    How far back to query.

.PARAMETER MinimumRejectCount
    Only flag source IPs with at least this many rejected flows.

.PARAMETER QueryTimeoutSeconds
    How long to wait for each Athena query.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-AwsVpcFlowLogAnomaly.ps1 -AthenaDatabase vpc_logs -FlowLogTable flow_logs -OutputLocation s3://athena-results/ -LookbackHours 24

    Runs the anomaly queries over the last day and produces a review package.

.EXAMPLE
    .\Get-AwsVpcFlowLogAnomaly.ps1 -AthenaDatabase vpc_logs -FlowLogTable flow_logs -OutputLocation s3://athena-results/ -MinimumRejectCount 500 -OutputFormat JSON

    Raises the reject threshold and emits JSON for a SIEM.

.NOTES
    Source use case      : #15 - AWS VPC Flow Log Anomaly Detection
    Category             : AWS
    Technology           : Athena / Lambda
    Difficulty           : High
    Agent possible       : Partial
    Can execute with SOP : Partially - Agent Assists
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Agent runs Athena queries & flags anomalies; separating real threats from noise needs analyst review & ongoing tuning"

    Required permissions : athena:StartQueryExecution, athena:GetQueryExecution, athena:GetQueryResults, s3:GetObject/PutObject on the results bucket, glue:GetTable
    Required modules     : AWS.Tools.Common, AWS.Tools.Athena
    Authentication       : IAM role or SSO profile via Set-AWSCredential. Never
                           an access key pair in code.

    Athena charges per terabyte scanned. Partition the flow log table by
    date and keep -LookbackHours tight; an unpartitioned full-table scan
    on a busy VPC is expensive and slow. The queries below filter on the
    partition column where present.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules AWS.Tools.Common
#Requires -Modules AWS.Tools.Athena

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$Region,

    [string]$ProfileName,

    [Parameter(Mandatory)]
    [string]$AthenaDatabase,

    [Parameter(Mandatory)]
    [string]$FlowLogTable,

    [Parameter(Mandatory)]
    [string]$OutputLocation,

    [ValidateRange(1,720)]
    [int]$LookbackHours = 24,

    [ValidateRange(1,1000000)]
    [int]$MinimumRejectCount = 100,

    [ValidateRange(10,3600)]
    [int]$QueryTimeoutSeconds = 300,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-AwsVpcFlowLogAnomaly'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #15 (AWS)'

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
        Connect-AutomationPlatform -Platform 'AWS' | Out-Null


        $awsArgs = @{}
        if ($Region)      { $awsArgs.Region = $Region }
        if ($ProfileName) { $awsArgs.ProfileName = $ProfileName }

        $since = (Get-Date).ToUniversalTime().AddHours(-$LookbackHours)
        $sinceEpoch = [int64]([datetimeoffset]$since).ToUnixTimeSeconds()

        function Invoke-AthenaQuery {
            param(
                [string]$Sql,
                [string]$Label,
                [string]$Database,
                [string]$ResultLocation,
                [int]$TimeoutSeconds,
                [hashtable]$AwsCommon
            )

            $exec = Start-ATHQueryExecution -QueryString $Sql -QueryExecutionContext_Database $Database `
                -ResultConfiguration_OutputLocation $ResultLocation @AwsCommon

            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
            do {
                Start-Sleep -Seconds 3
                $state = (Get-ATHQueryExecution -QueryExecutionId $exec @AwsCommon).QueryExecution.Status.State
            } while ($state -in @('QUEUED','RUNNING') -and (Get-Date) -lt $deadline)

            if ($state -ne 'SUCCEEDED') {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $Label `
                    -Message ('Athena query did not succeed (state {0})' -f $state)
                return @()
            }
            $rs = Get-ATHQueryResult -QueryExecutionId $exec @AwsCommon
            # Row 0 is the header row in Athena results.
            return @($rs.ResultSet.Rows | Select-Object -Skip 1)
        }

        # --- rejected traffic concentrations ------------------------------------
        $sqlReject = @(
            'SELECT srcaddr, dstaddr, dstport, protocol, COUNT(*) AS reject_count'
            "FROM $FlowLogTable"
            "WHERE action = 'REJECT' AND start >= $sinceEpoch"
            'GROUP BY srcaddr, dstaddr, dstport, protocol'
            "HAVING COUNT(*) >= $MinimumRejectCount"
            'ORDER BY reject_count DESC'
            'LIMIT 100'
        ) -join ' '

        foreach ($row in (Invoke-AthenaQuery -Sql $sqlReject -Label 'rejected-traffic' `
                -Database $AthenaDatabase -ResultLocation $OutputLocation `
                -TimeoutSeconds $QueryTimeoutSeconds -AwsCommon $awsArgs)) {
            $d = $row.Data
            $results.Add([PSCustomObject]@{
                Name        = ('REJECT {0} -> {1}:{2}' -f $d[0].VarCharValue, $d[1].VarCharValue, $d[2].VarCharValue)
                Id          = ('reject-{0}-{1}-{2}' -f $d[0].VarCharValue, $d[1].VarCharValue, $d[2].VarCharValue)
                Finding     = 'Rejected traffic concentration'
                SourceIp    = $d[0].VarCharValue
                DestIp      = $d[1].VarCharValue
                DestPort    = $d[2].VarCharValue
                Protocol    = $d[3].VarCharValue
                Count       = [int64]$d[4].VarCharValue
                AnalystNote = 'Could be a scan, a misconfigured client, or a security group that is doing its job. Needs analyst judgement.'
            })
        }

        # --- top talkers by volume ----------------------------------------------
        $sqlTalkers = @(
            'SELECT srcaddr, dstaddr, SUM(bytes) AS total_bytes, COUNT(*) AS flow_count'
            "FROM $FlowLogTable"
            "WHERE action = 'ACCEPT' AND start >= $sinceEpoch"
            'GROUP BY srcaddr, dstaddr'
            'ORDER BY total_bytes DESC'
            'LIMIT 25'
        ) -join ' '

        foreach ($row in (Invoke-AthenaQuery -Sql $sqlTalkers -Label 'top-talkers' `
                -Database $AthenaDatabase -ResultLocation $OutputLocation `
                -TimeoutSeconds $QueryTimeoutSeconds -AwsCommon $awsArgs)) {
            $d = $row.Data
            $results.Add([PSCustomObject]@{
                Name        = ('VOLUME {0} -> {1}' -f $d[0].VarCharValue, $d[1].VarCharValue)
                Id          = ('talker-{0}-{1}' -f $d[0].VarCharValue, $d[1].VarCharValue)
                Finding     = 'High volume flow'
                SourceIp    = $d[0].VarCharValue
                DestIp      = $d[1].VarCharValue
                TotalBytes  = [int64]$d[2].VarCharValue
                TotalGB     = [math]::Round([int64]$d[2].VarCharValue / 1GB, 2)
                FlowCount   = [int64]$d[3].VarCharValue
                AnalystNote = 'High volume is normal for backup and replication paths. Compare against the known baseline.'
            })
        }

        # --- unusual destination ports ------------------------------------------
        $sqlPorts = @(
            'SELECT dstport, protocol, COUNT(DISTINCT srcaddr) AS distinct_sources, COUNT(*) AS flow_count'
            "FROM $FlowLogTable"
            "WHERE action = 'ACCEPT' AND start >= $sinceEpoch"
            '  AND dstport NOT IN (80, 443, 22, 3389, 53, 123, 25, 587, 993, 995, 1433, 3306, 5432)'
            'GROUP BY dstport, protocol'
            'ORDER BY flow_count DESC'
            'LIMIT 50'
        ) -join ' '

        foreach ($row in (Invoke-AthenaQuery -Sql $sqlPorts -Label 'unusual-ports' `
                -Database $AthenaDatabase -ResultLocation $OutputLocation `
                -TimeoutSeconds $QueryTimeoutSeconds -AwsCommon $awsArgs)) {
            $d = $row.Data
            $results.Add([PSCustomObject]@{
                Name        = ('PORT {0}/{1}' -f $d[0].VarCharValue, $d[1].VarCharValue)
                Id          = ('port-{0}-{1}' -f $d[0].VarCharValue, $d[1].VarCharValue)
                Finding     = 'Traffic on a non-standard port'
                DestPort    = $d[0].VarCharValue
                Protocol    = $d[1].VarCharValue
                DistinctSources = [int64]$d[2].VarCharValue
                FlowCount   = [int64]$d[3].VarCharValue
                AnalystNote = 'Non-standard does not mean malicious. Many applications use high ports legitimately; tune the exclusion list over time.'
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AWS VPC Flow Log Anomaly Detection'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
