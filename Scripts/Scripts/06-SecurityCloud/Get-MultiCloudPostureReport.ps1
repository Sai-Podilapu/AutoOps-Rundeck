<#
.SYNOPSIS
    Reports cloud security posture from each cloud, side by side.

.DESCRIPTION
    Collects the security posture score and finding counts from each cloud
    that is reachable and reports them alongside each other. It does not blend
    them into a single number, and the reason is in the notes.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER SubscriptionId
    Azure subscription to operate in. The current context when omitted.

.PARAMETER IncludeCloud
    Which clouds to query.

.PARAMETER AwsRegion
    AWS region for Security Hub.

.PARAMETER OciCompartmentId
    OCI compartment for Cloud Guard problems.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-MultiCloudPostureReport.ps1 -IncludeCloud All -OutputFormat HTML

    Posture from every reachable cloud.

.EXAMPLE
    .\Get-MultiCloudPostureReport.ps1 -IncludeCloud Azure,AWS -AwsRegion me-central-1

    Azure and AWS only.

.NOTES
    Source use case      : #5 - Cloud Security Posture (CSPM) Report
    Category             : Security Cloud
    Technology           : Defender CSPM / AWS Security Hub / OCI
    Difficulty           : Medium
    Agent possible       : Partial
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Aggregate posture score across clouds"

    Required permissions : Security Reader in Azure; securityhub:GetFindings in AWS; Cloud Guard read in OCI.
    Required modules     : Az.Accounts
    Authentication       : Vendor REST API via Invoke-RestMethod, or Graph
                           where the tool is Microsoft.

    NO BLENDED SCORE IS PRODUCED, deliberately. Azure Secure Score, AWS
    Security Hub and OCI Cloud Guard measure different control sets on
    different scales with different weightings; averaging them produces a
    number that moves for reasons nobody can explain and that means
    nothing to any of the three teams. Each cloud is reported on its own
    scale, and finding counts by severity - which ARE comparable - are
    totalled. A cloud that could not be queried is reported as NOT QUERIED
    rather than omitted, because a missing cloud silently improves any
    total it is left out of.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [ValidateSet('Azure','AWS','OCI','All')]
    [string[]]$IncludeCloud = @('All'),

    [string]$AwsRegion,

    [string]$OciCompartmentId,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-MultiCloudPostureReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #5 (Security Cloud)'

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


        $wanted = if ($IncludeCloud -contains 'All') { @('Azure', 'AWS', 'OCI') } else { $IncludeCloud }

        function Add-PostureRecord {
            <#
                .SYNOPSIS
                    One posture row, in a shape shared by every cloud.
            #>
            [CmdletBinding()]
            [OutputType([PSCustomObject])]
            param($Cloud, $Metric, $Value, $Scale, $Critical, $High, $Medium, $Low, $Status, $Detail)

            [PSCustomObject]@{
                Name = ('{0}: {1}' -f $Cloud, $Metric); Id = ('{0}-{1}' -f $Cloud, $Metric)
                Cloud = $Cloud; Metric = $Metric; Value = $Value; Scale = $Scale
                Critical = $Critical; High = $High; Medium = $Medium; Low = $Low
                Status = $Status; Detail = $Detail
            }
        }

        # ---- Azure -------------------------------------------------------------
        if ($wanted -contains 'Azure') {
            try {
                $azContext = Get-AzContext -ErrorAction Stop
                if ($SubscriptionId -and $azContext.Subscription.Id -ne $SubscriptionId) {
                    $azContext = Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop
                }

                $scorePath = '/subscriptions/{0}/providers/Microsoft.Security/secureScores/ascScore?api-version=2020-01-01' -f $azContext.Subscription.Id
                $scoreResponse = Invoke-AzRestMethod -Path $scorePath -Method GET -ErrorAction Stop
                $score = ($scoreResponse.Content | ConvertFrom-Json).properties.score

                $assessPath = '/subscriptions/{0}/providers/Microsoft.Security/assessments?api-version=2020-01-01' -f $azContext.Subscription.Id
                $assessResponse = Invoke-AzRestMethod -Path $assessPath -Method GET -ErrorAction Stop
                $unhealthy = @(($assessResponse.Content | ConvertFrom-Json).value |
                               Where-Object { $_.properties.status.code -eq 'Unhealthy' })

                $results.Add((Add-PostureRecord -Cloud 'Azure' -Metric 'Secure Score' `
                    -Value $(if ($score) { [math]::Round($score.percentage * 100, 1) } else { $null }) `
                    -Scale 'Azure Secure Score, 0-100% of achievable points' `
                    -Critical @($unhealthy | Where-Object { $_.properties.metadata.severity -eq 'High' }).Count `
                    -High 0 `
                    -Medium @($unhealthy | Where-Object { $_.properties.metadata.severity -eq 'Medium' }).Count `
                    -Low @($unhealthy | Where-Object { $_.properties.metadata.severity -eq 'Low' }).Count `
                    -Status 'Queried' `
                    -Detail ('{0} unhealthy assessment(s). Azure reports High/Medium/Low, so Critical carries the High count.' -f $unhealthy.Count)))
            } catch {
                $results.Add((Add-PostureRecord -Cloud 'Azure' -Metric 'Secure Score' -Value $null `
                    -Scale '' -Critical $null -High $null -Medium $null -Low $null `
                    -Status 'NOT QUERIED' -Detail ('Failed: {0}' -f $_.Exception.Message)))
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Message ('Azure posture not collected: {0}' -f $_.Exception.Message)
            }
        }

        # ---- AWS ---------------------------------------------------------------
        if ($wanted -contains 'AWS') {
            try {
                Import-Module AWS.Tools.SecurityHub -ErrorAction Stop
                $findingParams = @{ ErrorAction = 'Stop' }
                if ($AwsRegion) { $findingParams.Region = $AwsRegion }
                $findings = @(Get-SHUBFinding @findingParams |
                              Where-Object { "$($_.RecordState)" -eq 'ACTIVE' -and "$($_.Workflow.Status)" -ne 'SUPPRESSED' })

                $results.Add((Add-PostureRecord -Cloud 'AWS' -Metric 'Security Hub findings' -Value $findings.Count `
                    -Scale 'AWS Security Hub, count of active findings (no percentage equivalent)' `
                    -Critical @($findings | Where-Object { $_.Severity.Label -eq 'CRITICAL' }).Count `
                    -High @($findings | Where-Object { $_.Severity.Label -eq 'HIGH' }).Count `
                    -Medium @($findings | Where-Object { $_.Severity.Label -eq 'MEDIUM' }).Count `
                    -Low @($findings | Where-Object { $_.Severity.Label -eq 'LOW' }).Count `
                    -Status 'Queried' -Detail 'Suppressed and archived findings excluded'))
            } catch {
                $results.Add((Add-PostureRecord -Cloud 'AWS' -Metric 'Security Hub findings' -Value $null `
                    -Scale '' -Critical $null -High $null -Medium $null -Low $null `
                    -Status 'NOT QUERIED' -Detail ('Failed: {0}' -f $_.Exception.Message)))
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Message ('AWS posture not collected: {0}' -f $_.Exception.Message)
            }
        }

        # ---- OCI ---------------------------------------------------------------
        if ($wanted -contains 'OCI') {
            try {
                $ociCli = (Get-Command -Name 'oci' -ErrorAction Stop).Source
                if (-not $OciCompartmentId) { throw 'No -OciCompartmentId supplied.' }

                $previousPreference = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try {
                    $raw = & $ociCli cloud-guard problem list --compartment-id $OciCompartmentId --output json
                    $exit = $LASTEXITCODE
                } finally {
                    $ErrorActionPreference = $previousPreference
                }
                if ($exit -ne 0) { throw ('oci cloud-guard exited {0}' -f $exit) }

                $problems = @(((@($raw) -join "`n") | ConvertFrom-Json).data.items)
                $results.Add((Add-PostureRecord -Cloud 'OCI' -Metric 'Cloud Guard problems' -Value $problems.Count `
                    -Scale 'OCI Cloud Guard, count of open problems (no percentage equivalent)' `
                    -Critical @($problems | Where-Object { "$($_.'risk-level')" -eq 'CRITICAL' }).Count `
                    -High @($problems | Where-Object { "$($_.'risk-level')" -eq 'HIGH' }).Count `
                    -Medium @($problems | Where-Object { "$($_.'risk-level')" -eq 'MEDIUM' }).Count `
                    -Low @($problems | Where-Object { "$($_.'risk-level')" -eq 'LOW' }).Count `
                    -Status 'Queried' -Detail 'Open Cloud Guard problems in the compartment'))
            } catch {
                $results.Add((Add-PostureRecord -Cloud 'OCI' -Metric 'Cloud Guard problems' -Value $null `
                    -Scale '' -Critical $null -High $null -Medium $null -Low $null `
                    -Status 'NOT QUERIED' -Detail ('Failed: {0}' -f $_.Exception.Message)))
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Message ('OCI posture not collected: {0}' -f $_.Exception.Message)
            }
        }

        # Severity counts ARE comparable across clouds. Scores are not, and are not blended.
        $queried = @($results | Where-Object { $_.Status -eq 'Queried' })
        $notQueried = @($results | Where-Object { $_.Status -eq 'NOT QUERIED' })

        $results.Add((Add-PostureRecord -Cloud 'ALL' -Metric 'Findings by severity' -Value $null `
            -Scale 'Counts only. NO blended score is produced - the three scales are not comparable.' `
            -Critical (($queried | Measure-Object Critical -Sum).Sum) `
            -High (($queried | Measure-Object High -Sum).Sum) `
            -Medium (($queried | Measure-Object Medium -Sum).Sum) `
            -Low (($queried | Measure-Object Low -Sum).Sum) `
            -Status $(if ($notQueried.Count -gt 0) { 'PARTIAL' } else { 'Complete' }) `
            -Detail ('{0} cloud(s) queried, {1} NOT queried ({2}). A total that omits a cloud understates it.' -f
                $queried.Count, $notQueried.Count, (($notQueried | ForEach-Object { $_.Cloud }) -join ', '))))

        if ($notQueried.Count -gt 0) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                '{0} cloud(s) could not be queried. The totals below are PARTIAL.' -f $notQueried.Count)
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Cloud Security Posture (CSPM) Report'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
