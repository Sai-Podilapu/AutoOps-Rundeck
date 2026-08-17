<#
.SYNOPSIS
    Reports SIEM log sources that have stopped sending data.

.DESCRIPTION
    Reports the most recent ingestion time per data type in the Sentinel
    workspace and flags anything that has gone quiet. A silent log source is
    the most dangerous SIEM failure there is: the dashboards stay green and
    the detections simply stop firing.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER SubscriptionId
    Azure subscription to operate in. The current context when omitted.

.PARAMETER ResourceGroupName
    Resource group holding the workspace.

.PARAMETER WorkspaceName
    Log Analytics workspace name.

.PARAMETER SilentMinutes
    A source silent for longer than this is reported.

.PARAMETER LookbackHours
    How far back to look for each source's last record.

.PARAMETER ExpectedDataType
    Data types that must be present. One missing entirely from the window is
    reported as absent, which a last-seen query alone would never surface.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-SiemLogSourceHealth.ps1 -ResourceGroupName rg-sec -WorkspaceName law-sec -SilentMinutes 15

    Standard 15-minute silence check.

.EXAMPLE
    .\Get-SiemLogSourceHealth.ps1 -ResourceGroupName rg-sec -WorkspaceName law-sec -ExpectedDataType SecurityEvent,Syslog,SigninLogs

    Also reports expected sources that are missing entirely.

.NOTES
    Source use case      : #12 - SIEM Log Source Health Check
    Category             : Security Cloud
    Technology           : Sentinel / Splunk API
    Difficulty           : Low
    Agent possible       : Partial
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Alert if log source silent >15 min"

    Required permissions : Log Analytics Reader on the workspace.
    Required modules     : Az.Accounts, Az.OperationalInsights
    Authentication       : Vendor REST API via Invoke-RestMethod, or Graph
                           where the tool is Microsoft.

    A source that has been silent longer than the lookback window does not
    appear in the results at all - it has no recent record to be late.
    That is why -ExpectedDataType exists: it is the only way to
    distinguish "quiet" from "gone", and the difference is exactly the
    failure this check is for.

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

    [ValidateRange(1,10080)]
    [int]$SilentMinutes = 15,

    [ValidateRange(1,720)]
    [int]$LookbackHours = 24,

    [string[]]$ExpectedDataType,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-SiemLogSourceHealth'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #12 (Security Cloud)'

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

        $query = @(
            'Usage'
            ('| where TimeGenerated > ago({0}h)' -f $LookbackHours)
            '| summarize LastSeen = max(TimeGenerated), TotalMB = sum(Quantity) by DataType'
            '| order by LastSeen asc'
        ) -join "`n"

        $queryResult = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspace.CustomerId -Query $query -ErrorAction Stop
        $rows = @($queryResult.Results)
        $now = Get-Date
        $seenTypes = @{}

        foreach ($row in $rows) {
            $lastSeen = [datetime]$row.LastSeen
            $silentFor = [math]::Round(($now - $lastSeen).TotalMinutes, 1)
            $seenTypes[$row.DataType] = $true

            $isSilent = $silentFor -gt $SilentMinutes
            $results.Add([PSCustomObject]@{
                Name           = $row.DataType
                Id             = $row.DataType
                DataType       = $row.DataType
                LastSeen       = $lastSeen
                SilentMinutes  = $silentFor
                VolumeMB       = [math]::Round([double]$row.TotalMB, 2)
                Status         = if ($isSilent) { 'SILENT' } else { 'OK' }
                Detail         = if ($isSilent) { ('No data for {0} minute(s), threshold {1}' -f $silentFor, $SilentMinutes) } else { '' }
            })

            if ($isSilent) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $row.DataType -Message (
                    'Log source silent for {0} minute(s)' -f $silentFor)
            }
        }

        # A source gone longer than the window has no row to be late. Only an explicit
        # expectation catches that.
        foreach ($expected in @($ExpectedDataType)) {
            if ($seenTypes.ContainsKey($expected)) { continue }

            $results.Add([PSCustomObject]@{
                Name          = $expected
                Id            = $expected
                DataType      = $expected
                LastSeen      = $null
                SilentMinutes = $null
                VolumeMB      = 0
                Status        = 'ABSENT'
                Detail        = ('Expected data type sent NOTHING in the last {0}h. This is worse than silent - ' +
                                 'it has no recent record at all.' -f $LookbackHours)
            })
            Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $expected -Message (
                'Expected log source ABSENT for the whole {0}h window' -f $LookbackHours)
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'SIEM Log Source Health Check'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
