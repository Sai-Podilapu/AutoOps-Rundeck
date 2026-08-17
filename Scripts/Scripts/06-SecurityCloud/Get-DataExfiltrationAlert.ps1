<#
.SYNOPSIS
    Surfaces large outbound transfers for investigation.

.DESCRIPTION
    Ranks outbound data volume by user and by destination over the reporting
    window and presents the outliers with the context an investigator needs.
    Whether any of it is exfiltration or a legitimate business transfer is an
    investigation, and that is where this script stops.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

    AGENT-ASSIST ONLY. This automates the mechanical part - gathering,
    enriching and comparing against a baseline - and then stops, producing
    a decision-ready package. The judgement step is deliberately left to a
    human and is NOT scripted.

.PARAMETER SubscriptionId
    Azure subscription to operate in. The current context when omitted.

.PARAMETER ResourceGroupName
    Resource group holding the workspace.

.PARAMETER WorkspaceName
    Log Analytics workspace name.

.PARAMETER LookbackHours
    Reporting window.

.PARAMETER ThresholdMB
    Report transfers above this size.

.PARAMETER TopCount
    How many outliers to report per dimension.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-DataExfiltrationAlert.ps1 -ResourceGroupName rg-sec -WorkspaceName law-sec -ThresholdMB 500

    Daily outbound outliers over 500 MB.

.EXAMPLE
    .\Get-DataExfiltrationAlert.ps1 -ResourceGroupName rg-sec -WorkspaceName law-sec -LookbackHours 168 -ThresholdMB 2000

    A week of large transfers.

.NOTES
    Source use case      : #17 - Data Exfiltration Detection Alert
    Category             : Security Cloud
    Technology           : DLP / Sentinel / MCAS
    Difficulty           : High
    Agent possible       : Partial
    Can execute with SOP : Partially - Agent Assists
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Alerting on large uploads automatable; confirming actual exfiltration vs legitimate business transfer is an investigation, i.e. human"

    Required permissions : Log Analytics Reader on the workspace.
    Required modules     : Az.Accounts, Az.OperationalInsights
    Authentication       : Vendor REST API via Invoke-RestMethod, or Graph
                           where the tool is Microsoft.

    AGENT-ASSIST. Volume is not evidence. Backup jobs, database
    replication, video uploads, a developer pulling a container image and
    a genuine data theft all look the same in a byte count, and the ones
    that look most alarming are usually the scheduled ones. Every finding
    therefore carries an InvestigatorNote giving the benign explanation,
    and no verdict is offered. A baseline comparison against the same
    user's previous behaviour is what makes this useful, and that
    comparison is the investigator's to make.

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

    [ValidateRange(1,1048576)]
    [int]$ThresholdMB = 500,

    [ValidateRange(1,200)]
    [int]$TopCount = 20,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-DataExfiltrationAlert'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #17 (Security Cloud)'

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
        Connect-AutomationPlatform -Platform 'Graph' | Out-Null


        $azContext = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $azContext) {
            throw 'No Azure context. Run Connect-AzAccount, or use a managed identity, before this script.'
        }
        if ($SubscriptionId -and $azContext.Subscription.Id -ne $SubscriptionId) {
            $azContext = Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop
        }
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Azure context: subscription {0}' -f $azContext.Subscription.Id)

        $workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName `
            -Name $WorkspaceName -ErrorAction Stop

        $thresholdBytes = $ThresholdMB * 1MB

        # CloudAppEvents is the Defender for Cloud Apps table. If it is not present in
        # the workspace the query fails, and that is reported as "not collected"
        # rather than as "no exfiltration".
        $queries = @(
            @{ Dimension = 'User'
               Query = @(
                   'CloudAppEvents'
                   ('| where Timestamp > ago({0}h)' -f $LookbackHours)
                   '| where isnotempty(AccountDisplayName)'
                   '| summarize TotalBytes = sum(todouble(RawEventData.bytesUploaded)), Events = count() by AccountDisplayName'
                   ('| where TotalBytes > {0}' -f $thresholdBytes)
                   '| order by TotalBytes desc'
                   ('| take {0}' -f $TopCount)
               ) -join "`n"
               Note = 'A user total is dominated by whatever they do routinely. Compare against their own previous weeks before treating it as anomalous.' }
            @{ Dimension = 'Application'
               Query = @(
                   'CloudAppEvents'
                   ('| where Timestamp > ago({0}h)' -f $LookbackHours)
                   '| summarize TotalBytes = sum(todouble(RawEventData.bytesUploaded)), Events = count() by Application'
                   ('| where TotalBytes > {0}' -f $thresholdBytes)
                   '| order by TotalBytes desc'
                   ('| take {0}' -f $TopCount)
               ) -join "`n"
               Note = 'Sanctioned applications dominate this list by design. An unsanctioned application with any volume is more interesting than a sanctioned one with a lot.' }
        )

        foreach ($queryDef in $queries) {
            $rows = @()
            try {
                $queryResult = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspace.CustomerId `
                    -Query $queryDef.Query -ErrorAction Stop
                $rows = @($queryResult.Results)
            } catch {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                    '{0} dimension NOT collected: {1}. This is not evidence of no exfiltration - the query ' +
                    'did not run.' -f $queryDef.Dimension, $_.Exception.Message)
                continue
            }

            foreach ($row in $rows) {
                $subject = if ($queryDef.Dimension -eq 'User') { $row.AccountDisplayName } else { $row.Application }
                $bytes = [double]$row.TotalBytes

                $results.Add([PSCustomObject]@{
                    Name             = ('{0}: {1}' -f $queryDef.Dimension, $subject)
                    Id               = ('{0}-{1}' -f $queryDef.Dimension, $subject)
                    Dimension        = $queryDef.Dimension
                    Subject          = $subject
                    TotalMB          = [math]::Round($bytes / 1MB, 1)
                    EventCount       = $row.Events
                    WindowHours      = $LookbackHours
                    InvestigatorNote = $queryDef.Note
                    Verdict          = 'NONE - confirming exfiltration versus legitimate business transfer is an investigation, not a threshold'
                })
            }

            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
                '{0} dimension: {1} subject(s) above {2} MB.' -f $queryDef.Dimension, $rows.Count, $ThresholdMB)
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Data Exfiltration Detection Alert'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
