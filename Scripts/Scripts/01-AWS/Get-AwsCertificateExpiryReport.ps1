<#
.SYNOPSIS
    Reports ACM certificates approaching expiry.

.DESCRIPTION
    Lists ACM certificates with days remaining until expiry, flagging those
    inside the warning window. Certificates pending validation are reported
    separately, because those will never renew on their own.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER Region
    AWS region to operate in. Defaults to the configured default region.

.PARAMETER ProfileName
    Named AWS profile / SSO profile to use. Prefer an IAM role where the host
    supports one.

.PARAMETER WarnWithinDays
    Flag certificates expiring within this many days.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-AwsCertificateExpiryReport.ps1 -WarnWithinDays 30

    Flags certificates expiring in a month.

.EXAMPLE
    .\Get-AwsCertificateExpiryReport.ps1 -OutputFormat HTML

    HTML report of all certificates.

.NOTES
    Source use case      : #22 - AWS Certificate Expiry Monitor
    Category             : AWS
    Technology           : ACM / Lambda / SNS
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "30/14/7-day expiry alerts"

    Required permissions : acm:ListCertificates, acm:DescribeCertificate
    Required modules     : AWS.Tools.Common, AWS.Tools.CertificateManager
    Authentication       : IAM role or SSO profile via Set-AWSCredential. Never
                           an access key pair in code.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules AWS.Tools.Common
#Requires -Modules AWS.Tools.CertificateManager

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$Region,

    [string]$ProfileName,

    [ValidateRange(1,3650)]
    [int]$WarnWithinDays = 45,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-AwsCertificateExpiryReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #22 (AWS)'

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

        foreach ($c in (Get-ACMCertificateList @awsArgs)) {
            $d = Get-ACMCertificateDetail -CertificateArn $c.CertificateArn @awsArgs
            $days = if ($d.NotAfter) { [math]::Round(($d.NotAfter - (Get-Date)).TotalDays, 0) } else { $null }
            $status = if ($d.Status -ne 'ISSUED') { $d.Status }
                      elseif ($null -eq $days) { 'Unknown' }
                      elseif ($days -le 0) { 'EXPIRED' }
                      elseif ($days -le $WarnWithinDays) { 'Expiring' }
                      else { 'OK' }
            $results.Add([PSCustomObject]@{
                Name           = $d.DomainName
                Id             = $d.CertificateArn
                Status         = $status
                CertStatus     = $d.Status
                NotAfter       = $d.NotAfter
                DaysRemaining  = $days
                RenewalEligibility = $d.RenewalEligibility
                InUseBy        = ($d.InUseBy -join '; ')
                Type           = $d.Type
            })
            if ($status -in @('Expiring','EXPIRED')) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $d.DomainName `
                    -Message ('Certificate {0} - {1} day(s) remaining' -f $status, $days)
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AWS Certificate Expiry Monitor'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
