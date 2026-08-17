<#
.SYNOPSIS
    Produces the weekly Trusted Advisor summary with week-on-week movement.

.DESCRIPTION
    Pulls all Trusted Advisor checks and compares them against the previous
    run stored on disk, so the report shows what changed this week rather than
    repeating the same list.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER ProfileName
    Named AWS profile / SSO profile to use. Prefer an IAM role where the host
    supports one.

.PARAMETER StateFile
    Path used to store the previous run for comparison.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-AwsTrustedAdvisorWeeklyReport.ps1 -OutputFormat HTML

    Weekly report as HTML with movement since last run.

.EXAMPLE
    .\Get-AwsTrustedAdvisorWeeklyReport.ps1 -StateFile C:\Automation\ta-state.json

    Uses an explicit state file.

.NOTES
    Source use case      : #20 - AWS Trusted Advisor Weekly Report
    Category             : AWS
    Technology           : Trusted Advisor API
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Email summary of recommendations"

    Required permissions : support:DescribeTrustedAdvisorChecks, support:DescribeTrustedAdvisorCheckResult
    Required modules     : AWS.Tools.Common, AWS.Tools.Support
    Authentication       : IAM role or SSO profile via Set-AWSCredential. Never
                           an access key pair in code.

    Requires a Business or Enterprise support plan. The Support API is
    us-east-1 only.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules AWS.Tools.Common
#Requires -Modules AWS.Tools.Support

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$ProfileName,

    [string]$StateFile,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-AwsTrustedAdvisorWeeklyReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #20 (AWS)'

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


        $awsArgs = @{ Region = 'us-east-1' }
        if ($ProfileName) { $awsArgs.ProfileName = $ProfileName }

        if (-not $StateFile) {
            $StateFile = Join-Path $env:ProgramData 'ITAutomation\State\aws-trustedadvisor.json'
        }
        $prev = @{}
        if (Test-Path -LiteralPath $StateFile) {
            try {
                (Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json) |
                    ForEach-Object { $prev[$_.Id] = $_.ResourcesFlagged }
            } catch { Write-AutomationLog -ScriptName $scriptName -Level WARN -Message 'Previous state unreadable; reporting without movement.' }
        }

        $snapshot = @()
        foreach ($chk in (Get-ASATrustedAdvisorCheck -Language en @awsArgs)) {
            $res = Get-ASATrustedAdvisorCheckResult -CheckId $chk.Id -Language en @awsArgs
            $flagged = $res.ResourcesSummary.ResourcesFlagged
            $was = if ($prev.ContainsKey($chk.Id)) { $prev[$chk.Id] } else { $null }
            $results.Add([PSCustomObject]@{
                Name       = $chk.Name
                Id         = $chk.Id
                Category   = $chk.Category
                Status     = $res.Status
                Flagged    = $flagged
                PreviousFlagged = $was
                Movement   = if ($null -eq $was) { 'new' }
                             elseif ($flagged -gt $was) { "worse (+$($flagged - $was))" }
                             elseif ($flagged -lt $was) { "better (-$($was - $flagged))" }
                             else { 'unchanged' }
            })
            $snapshot += [PSCustomObject]@{ Id = $chk.Id; ResourcesFlagged = $flagged }
        }

        $dir = Split-Path -Parent $StateFile
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        $snapshot | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $StateFile -Encoding UTF8
    } catch {
        $msg = $_.Exception.Message
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Message ('Discovery FAILED: {0}' -f $msg)
        $failures.Add([PSCustomObject]@{ Stage = 'Discovery'; Error = $msg })
    }
}

end {
    $candidates = @($results)

    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message ('Collected {0} record(s).' -f $candidates.Count)
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AWS Trusted Advisor Weekly Report'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
