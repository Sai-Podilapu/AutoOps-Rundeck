<#
.SYNOPSIS
    Reports IAM access keys that are unused or older than a threshold.

.DESCRIPTION
    Lists every IAM user access key with its age and last-used date, flagging
    keys that have never been used or have been idle beyond the threshold.
    Reporting only - key deactivation is a separate, approval-gated action.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER ProfileName
    Named AWS profile / SSO profile to use. Prefer an IAM role where the host
    supports one.

.PARAMETER MaxKeyAgeDays
    Key age at or above which a key is flagged as stale.

.PARAMETER MaxIdleDays
    Days without use at or above which a key is flagged as idle.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-AwsIamUnusedAccessKeyReport.ps1 -MaxKeyAgeDays 90

    Flags keys older than 90 days.

.EXAMPLE
    .\Get-AwsIamUnusedAccessKeyReport.ps1 -MaxIdleDays 30 -OutputFormat CSV

    Flags keys idle for a month, as CSV.

.NOTES
    Source use case      : #6 - AWS IAM Unused Access Key Report
    Category             : AWS
    Technology           : Boto3 / IAM
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Report only; key deactivation should stay human-approved"

    Required permissions : iam:ListUsers, iam:ListAccessKeys, iam:GetAccessKeyLastUsed
    Required modules     : AWS.Tools.Common, AWS.Tools.IdentityManagement
    Authentication       : IAM role or SSO profile via Set-AWSCredential. Never
                           an access key pair in code.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules AWS.Tools.Common
#Requires -Modules AWS.Tools.IdentityManagement

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$ProfileName,

    [ValidateRange(1,3650)]
    [int]$MaxKeyAgeDays = 90,

    [ValidateRange(1,3650)]
    [int]$MaxIdleDays = 90,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-AwsIamUnusedAccessKeyReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #6 (AWS)'

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
        if ($ProfileName) { $awsArgs.ProfileName = $ProfileName }

        foreach ($u in (Get-IAMUserList @awsArgs)) {
            foreach ($k in (Get-IAMAccessKey -UserName $u.UserName @awsArgs)) {
                $ageDays = [math]::Round(((Get-Date) - $k.CreateDate).TotalDays, 0)
                $lastUsed = $null; $idleDays = $null; $service = $null
                try {
                    $lu = Get-IAMAccessKeyLastUsed -AccessKeyId $k.AccessKeyId @awsArgs
                    if ($lu.AccessKeyLastUsed.LastUsedDate -and
                        $lu.AccessKeyLastUsed.LastUsedDate -gt [datetime]'2000-01-01') {
                        $lastUsed = $lu.AccessKeyLastUsed.LastUsedDate
                        $idleDays = [math]::Round(((Get-Date) - $lastUsed).TotalDays, 0)
                        $service  = $lu.AccessKeyLastUsed.ServiceName
                    }
                } catch {
                    # A key that has never been used has no last-used record.
                    Write-Verbose ('No last-used record for key {0}' -f $k.AccessKeyId)
                }

                $flags = @()
                if ($ageDays -ge $MaxKeyAgeDays) { $flags += "age>=${MaxKeyAgeDays}d" }
                if ($null -eq $lastUsed)         { $flags += 'never used' }
                elseif ($idleDays -ge $MaxIdleDays) { $flags += "idle>=${MaxIdleDays}d" }

                $results.Add([PSCustomObject]@{
                    Name        = $u.UserName
                    Id          = $k.AccessKeyId
                    KeyStatus   = $k.Status
                    CreatedAt   = $k.CreateDate
                    AgeDays     = $ageDays
                    LastUsed    = $lastUsed
                    IdleDays    = $idleDays
                    LastService = $service
                    Status      = if ($flags.Count) { 'Flagged' } else { 'OK' }
                    Flags       = ($flags -join '; ')
                })
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AWS IAM Unused Access Key Report'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
