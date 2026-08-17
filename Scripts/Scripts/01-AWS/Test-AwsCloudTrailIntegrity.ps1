<#
.SYNOPSIS
    Verifies CloudTrail is enabled, multi-region and log-file validated.

.DESCRIPTION
    Checks each trail for the properties that make its logs trustworthy as
    evidence: it is logging, it covers all regions, log file validation is on,
    and it writes to an encrypted bucket. A trail that fails any of these is
    reported, because an audit trail nobody can prove is intact is not an
    audit trail.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER Region
    AWS region to operate in. Defaults to the configured default region.

.PARAMETER ProfileName
    Named AWS profile / SSO profile to use. Prefer an IAM role where the host
    supports one.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Test-AwsCloudTrailIntegrity.ps1 

    Checks every trail in the account.

.EXAMPLE
    .\Test-AwsCloudTrailIntegrity.ps1 -Region me-central-1 -OutputFormat JSON

    Checks one region as JSON.

.NOTES
    Source use case      : #11 - AWS CloudTrail Log Integrity Check
    Category             : AWS
    Technology           : Lambda / Athena
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Verification/report; Athena queries need tuning"

    Required permissions : cloudtrail:DescribeTrails, cloudtrail:GetTrailStatus
    Required modules     : AWS.Tools.Common, AWS.Tools.CloudTrail
    Authentication       : IAM role or SSO profile via Set-AWSCredential. Never
                           an access key pair in code.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules AWS.Tools.Common
#Requires -Modules AWS.Tools.CloudTrail

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$Region,

    [string]$ProfileName,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Test-AwsCloudTrailIntegrity'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #11 (AWS)'

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

        foreach ($t in (Get-CTTrail @awsArgs)) {
            $status = Get-CTTrailStatus -Name $t.TrailARN @awsArgs
            $issues = @()
            if (-not $status.IsLogging)          { $issues += 'not logging' }
            if (-not $t.IsMultiRegionTrail)      { $issues += 'not multi-region' }
            if (-not $t.LogFileValidationEnabled){ $issues += 'log file validation disabled' }
            if (-not $t.KmsKeyId)                { $issues += 'logs not KMS encrypted' }

            $results.Add([PSCustomObject]@{
                Name              = $t.Name
                Id                = $t.TrailARN
                IsLogging         = $status.IsLogging
                MultiRegion       = $t.IsMultiRegionTrail
                LogValidation     = $t.LogFileValidationEnabled
                KmsEncrypted      = [bool]$t.KmsKeyId
                S3Bucket          = $t.S3BucketName
                LatestDelivery    = $status.LatestDeliveryTime
                LatestDeliveryError = $status.LatestDeliveryError
                Status            = if ($issues.Count) { 'NonCompliant' } else { 'Compliant' }
                Issues            = ($issues -join '; ')
            })
            if ($issues.Count) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $t.Name -Message ($issues -join '; ')
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AWS CloudTrail Log Integrity Check'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
