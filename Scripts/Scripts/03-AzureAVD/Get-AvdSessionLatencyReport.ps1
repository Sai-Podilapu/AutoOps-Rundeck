<#
.SYNOPSIS
    Reports AVD connection counts, round-trip latency and errors.

.DESCRIPTION
    Queries the AVD diagnostic tables in Log Analytics for connection volume,
    round-trip time and connection failures over the reporting window, broken
    down by user and by host.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER SubscriptionId
    Azure subscription. The current context when omitted.

.PARAMETER ResourceGroupName
    Resource group holding the Log Analytics workspace.

.PARAMETER WorkspaceName
    Log Analytics workspace receiving AVD diagnostics.

.PARAMETER LookbackHours
    Reporting window.

.PARAMETER LatencyWarnMs
    Flag average round-trip time above this.

.PARAMETER TopCount
    How many users and hosts to report.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-AvdSessionLatencyReport.ps1 -ResourceGroupName rg-avd -WorkspaceName law-avd -LookbackHours 24 -OutputFormat HTML

    Daily connection and latency report.

.EXAMPLE
    .\Get-AvdSessionLatencyReport.ps1 -ResourceGroupName rg-avd -WorkspaceName law-avd -LatencyWarnMs 100 -TopCount 50

    Tighter latency threshold, more rows.

.NOTES
    Source use case      : #8 - AVD Monitoring - Session & Latency Report
    Category             : Azure AVD
    Technology           : Log Analytics / KQL
    Difficulty           : Low
    Agent possible       : Partial
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Daily read-only report"

    Required permissions : Log Analytics Reader on the workspace.
    Required modules     : Az.Accounts, Az.OperationalInsights
    Authentication       : Inherits the Az context; managed identity preferred.

    This needs AVD diagnostic settings sending WVDConnections,
    WVDConnectionNetworkData and WVDErrors to the workspace. If a table is
    missing the query fails and that section is reported as NOT COLLECTED
    - which is not the same as no latency problems, and the report says so
    rather than showing an empty section. Round-trip time is measured to
    the gateway, not to the application, so a good number here does not
    rule out a slow session; it rules out the network being the cause.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.OperationalInsights

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$WorkspaceName,

    [ValidateRange(1,720)]
    [int]$LookbackHours = 24,

    [ValidateRange(1,10000)]
    [int]$LatencyWarnMs = 150,

    [ValidateRange(1,500)]
    [int]$TopCount = 25,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-AvdSessionLatencyReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #8 (Azure AVD)'

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
        Connect-AutomationPlatform -Platform 'AzureAVD' | Out-Null


        $azContext = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $azContext) {
            throw 'No Azure context. Run Connect-AzAccount, or use a managed identity, before this script.'
        }
        if ($SubscriptionId -and $azContext.Subscription.Id -ne $SubscriptionId) {
            $azContext = Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop
        }

        $workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName `
            -Name $WorkspaceName -ErrorAction Stop

        $sections = @(
            @{ Section = 'Latency by user'
               Query = @(
                   'WVDConnectionNetworkData'
                   ('| where TimeGenerated > ago({0}h)' -f $LookbackHours)
                   '| join kind=inner (WVDConnections | project CorrelationId, UserName, SessionHostName) on CorrelationId'
                   '| summarize AvgRttMs = avg(EstRoundTripTimeInMs), MaxRttMs = max(EstRoundTripTimeInMs), Samples = count() by UserName'
                   '| order by AvgRttMs desc'
                   ('| take {0}' -f $TopCount)
               ) -join "`n"
               Dimension = 'UserName' }
            @{ Section = 'Latency by session host'
               Query = @(
                   'WVDConnectionNetworkData'
                   ('| where TimeGenerated > ago({0}h)' -f $LookbackHours)
                   '| join kind=inner (WVDConnections | project CorrelationId, SessionHostName) on CorrelationId'
                   '| summarize AvgRttMs = avg(EstRoundTripTimeInMs), MaxRttMs = max(EstRoundTripTimeInMs), Samples = count() by SessionHostName'
                   '| order by AvgRttMs desc'
                   ('| take {0}' -f $TopCount)
               ) -join "`n"
               Dimension = 'SessionHostName' }
            @{ Section = 'Connection errors'
               Query = @(
                   'WVDErrors'
                   ('| where TimeGenerated > ago({0}h)' -f $LookbackHours)
                   '| summarize Occurrences = count(), Users = dcount(UserName) by CodeSymbolic, ServiceError'
                   '| order by Occurrences desc'
                   ('| take {0}' -f $TopCount)
               ) -join "`n"
               Dimension = 'CodeSymbolic' }
            @{ Section = 'Connection volume'
               Query = @(
                   'WVDConnections'
                   ('| where TimeGenerated > ago({0}h)' -f $LookbackHours)
                   '| where State == "Connected"'
                   '| summarize Connections = count(), Users = dcount(UserName) by SessionHostName'
                   '| order by Connections desc'
                   ('| take {0}' -f $TopCount)
               ) -join "`n"
               Dimension = 'SessionHostName' }
        )

        foreach ($section in $sections) {
            $rows = @()
            try {
                $queryResult = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspace.CustomerId `
                    -Query $section.Query -ErrorAction Stop
                $rows = @($queryResult.Results)
            } catch {
                # A missing table means diagnostics are not flowing, which is a
                # different finding from "no problems".
                $results.Add([PSCustomObject]@{
                    Name       = $section.Section
                    Id         = $section.Section
                    Section    = $section.Section
                    Subject    = ''
                    AvgRttMs   = $null
                    MaxRttMs   = $null
                    Samples    = $null
                    Connections= $null
                    Users      = $null
                    Status     = 'NOT COLLECTED'
                    Detail     = ('Query failed: {0}. Check that AVD diagnostic settings send this table to ' +
                                  'the workspace. This is NOT evidence of no problems.' -f $_.Exception.Message)
                })
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                    '{0}: NOT COLLECTED - {1}' -f $section.Section, $_.Exception.Message)
                continue
            }

            foreach ($row in $rows) {
                $subject = $row.($section.Dimension)
                $avgRtt = if ($null -ne $row.AvgRttMs) { [math]::Round([double]$row.AvgRttMs, 1) } else { $null }
                $isSlow = ($null -ne $avgRtt -and $avgRtt -gt $LatencyWarnMs)

                $results.Add([PSCustomObject]@{
                    Name       = ('{0}: {1}' -f $section.Section, $subject)
                    Id         = ('{0}-{1}' -f $section.Section, $subject)
                    Section    = $section.Section
                    Subject    = $subject
                    AvgRttMs   = $avgRtt
                    MaxRttMs   = if ($null -ne $row.MaxRttMs) { [math]::Round([double]$row.MaxRttMs, 1) } else { $null }
                    Samples    = $row.Samples
                    Connections= $row.Connections
                    Users      = $row.Users
                    Status     = if ($isSlow) { 'HighLatency' }
                                 elseif ($section.Section -eq 'Connection errors') { 'Error' }
                                 else { 'OK' }
                    Detail     = if ($isSlow) {
                                    ('Average round-trip {0} ms, over the {1} ms threshold. RTT is measured to ' +
                                     'the gateway, so this rules the network IN as a cause, not the application out.' -f $avgRtt, $LatencyWarnMs)
                                 } elseif ($row.ServiceError) { ('Service error: {0}' -f $row.ServiceError) }
                                 else { '' }
                })

                if ($isSlow) {
                    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $subject -Message (
                        'Average round-trip {0} ms over {1} sample(s)' -f $avgRtt, $row.Samples)
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AVD Monitoring - Session & Latency Report'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
