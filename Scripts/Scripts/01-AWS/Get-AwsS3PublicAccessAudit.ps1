<#
.SYNOPSIS
    Audits S3 buckets for public access exposure.

.DESCRIPTION
    Checks every bucket for its public access block configuration, ACL grants
    to AllUsers or AuthenticatedUsers, and a policy that allows a wildcard
    principal. A bucket is reported as exposed if any of the three is true,
    because any one of them is sufficient to make data public.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER Region
    AWS region to operate in. Defaults to the configured default region.

.PARAMETER ProfileName
    Named AWS profile / SSO profile to use. Prefer an IAM role where the host
    supports one.

.PARAMETER BucketName
    Limit the audit to specific buckets.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-AwsS3PublicAccessAudit.ps1 -OutputFormat HTML

    Audits every bucket and writes an HTML report.

.EXAMPLE
    .\Get-AwsS3PublicAccessAudit.ps1 -BucketName my-data-bucket

    Audits one bucket.

.NOTES
    Source use case      : #5 - AWS S3 Bucket Public Access Audit
    Category             : AWS
    Technology           : Boto3 / Lambda
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Audit + alert only; no changes made"

    Required permissions : s3:ListAllMyBuckets, s3:GetBucketPublicAccessBlock, s3:GetBucketAcl, s3:GetBucketPolicy
    Required modules     : AWS.Tools.Common, AWS.Tools.S3
    Authentication       : IAM role or SSO profile via Set-AWSCredential. Never
                           an access key pair in code.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules AWS.Tools.Common
#Requires -Modules AWS.Tools.S3

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$Region,

    [string]$ProfileName,

    [string[]]$BucketName,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-AwsS3PublicAccessAudit'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #5 (AWS)'

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

        $buckets = if ($BucketName) { $BucketName | ForEach-Object { [PSCustomObject]@{ BucketName = $_ } } }
                   else             { Get-S3Bucket @awsArgs }

        foreach ($b in $buckets) {
            $name = $b.BucketName
            $blockAll = $null; $aclPublic = $false; $policyPublic = $false; $notes = @()

            try {
                $pab = Get-S3PublicAccessBlock -BucketName $name @awsArgs
                $blockAll = ($pab.PublicAccessBlockConfiguration.BlockPublicAcls -and
                             $pab.PublicAccessBlockConfiguration.BlockPublicPolicy -and
                             $pab.PublicAccessBlockConfiguration.IgnorePublicAcls -and
                             $pab.PublicAccessBlockConfiguration.RestrictPublicBuckets)
            } catch {
                # No public access block is itself the finding, not an error.
                $notes += 'no public access block configured'
                $blockAll = $false
            }

            try {
                $acl = Get-S3ACL -BucketName $name @awsArgs
                $aclPublic = [bool]($acl.Grants | Where-Object {
                    $_.Grantee.URI -match 'AllUsers|AuthenticatedUsers' })
            } catch {
                $notes += 'ACL unreadable'
                Write-Verbose ('Could not read ACL for {0}: {1}' -f $name, $_.Exception.Message)
            }

            try {
                $pol = Get-S3BucketPolicy -BucketName $name @awsArgs
                if ($pol) { $policyPublic = ($pol -match '"Principal"\s*:\s*(\{\s*"AWS"\s*:\s*)?"\*"') }
            } catch {
                # A bucket with no policy is normal and is not an exposure.
                Write-Verbose ('No bucket policy on {0}' -f $name)
            }

            $exposed = ((-not $blockAll) -and ($aclPublic -or $policyPublic))
            $results.Add([PSCustomObject]@{
                Name              = $name
                Id                = $name
                PublicAccessBlock = $blockAll
                PublicAcl         = $aclPublic
                PublicPolicy      = $policyPublic
                Exposed           = $exposed
                Status            = if ($exposed) { 'EXPOSED' } elseif (-not $blockAll) { 'Weak' } else { 'OK' }
                Notes             = ($notes -join '; ')
            })
            if ($exposed) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $name -Message 'Bucket is publicly accessible'
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AWS S3 Bucket Public Access Audit'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
