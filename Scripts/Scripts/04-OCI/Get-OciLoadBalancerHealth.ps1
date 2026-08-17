<#
.SYNOPSIS
    Reports OCI load balancer backend health and certificate expiry.

.DESCRIPTION
    Reports each load balancer with the health of its backend sets and the
    expiry date of the certificates it presents. Both are outage causes; a
    certificate that expires overnight takes a healthy backend down just as
    effectively as a failed one.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER CompartmentId
    Compartment OCID to operate in. Falls back to oci.defaultCompartmentId in
    config.json.

.PARAMETER Region
    OCI region identifier, e.g. me-dubai-1. Falls back to oci.defaultRegion in
    config.json, then to the region in the CLI profile.

.PARAMETER CliProfile
    Named profile in the OCI CLI config file. Not called -Profile because
    $Profile is a PowerShell automatic variable.

.PARAMETER CliConfigFile
    Path to the OCI CLI config file. The CLI default (~/.oci/config) is used
    when omitted.

.PARAMETER OciCliPath
    Full path to the oci executable. Resolved from PATH when omitted.

.PARAMETER LoadBalancerName
    Limit to these load balancers.

.PARAMETER CertificateWarnDays
    Warn on certificates expiring within this many days.

.PARAMETER IssuesOnly
    Report only load balancers with a finding.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-OciLoadBalancerHealth.ps1 -OutputFormat HTML

    Load balancer health and certificate report.

.EXAMPLE
    .\Get-OciLoadBalancerHealth.ps1 -IssuesOnly -CertificateWarnDays 14

    Only problems, tighter certificate window.

.NOTES
    Source use case      : #11 - OCI Load Balancer Health Check
    Category             : OCI
    Technology           : OCI LB API
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Backend set health + certificate check"

    Required permissions : An IAM policy allowing LOAD_BALANCER_INSPECT in the compartment.
    Required modules     : none beyond IT-Automation-Common
    Authentication       : OCI CLI config profile. NOTE: there is no
                           first-party OCI PowerShell module - this wraps the
                           OCI CLI.

    Backend health is read from the load balancer health API, which
    reports the balancer's own view. A backend marked OK still only means
    the health check passed - it says nothing about whether the
    application behind it is returning correct answers.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$CompartmentId,

    [string]$Region,

    [string]$CliProfile,

    [string]$CliConfigFile,

    [string]$OciCliPath,

    [string[]]$LoadBalancerName,

    [ValidateRange(1,365)]
    [int]$CertificateWarnDays = 30,

    [switch]$IssuesOnly,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-OciLoadBalancerHealth'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #11 (OCI)'

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
        Connect-AutomationPlatform -Platform 'OCI' | Out-Null


        function Invoke-OciCli {
            <#
                .SYNOPSIS
                    Runs one oci CLI command and returns its parsed JSON output.
                .DESCRIPTION
                    Appends the profile, config file, region and --output json, runs the
                    CLI, and throws on a non-zero exit code. Defined inside the script
                    rather than in the shared module because it depends on this run's
                    resolved CLI path and profile.
            #>
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)]
                [string[]]$Argument,

                [switch]$Raw
            )

            $cliArgs = @($Argument)
            if ($ociProfile)    { $cliArgs += @('--profile', $ociProfile) }
            if ($ociConfigFile) { $cliArgs += @('--config-file', $ociConfigFile) }
            if ($Region)        { $cliArgs += @('--region', $Region) }
            $cliArgs += @('--output', 'json')

            $errFile = [System.IO.Path]::GetTempFileName()
            $previousPreference = $ErrorActionPreference
            # Windows PowerShell turns redirected native stderr into terminating errors
            # under 'Stop', even when the process exits 0. The exit code is the signal
            # that actually matters, so the preference is relaxed for the call only.
            $ErrorActionPreference = 'Continue'
            $exitCode = 0
            try {
                $stdout = & $ociCli @cliArgs 2>$errFile
                $exitCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $previousPreference
            }

            $stderrText = ''
            if (Test-Path -LiteralPath $errFile) {
                $stderrText = "$(Get-Content -LiteralPath $errFile -Raw)"
                Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
            }

            if ($exitCode -ne 0) {
                # Redacted on the way into the log by Write-AutomationLog.
                throw ('oci {0} failed (exit {1}): {2}' -f ($Argument -join ' '), $exitCode, $stderrText.Trim())
            }

            $text = (@($stdout) -join "`n").Trim()
            if ($Raw) { return $text }
            if (-not $text) { return $null }
            try {
                return ($text | ConvertFrom-Json)
            } catch {
                throw ('oci {0} returned output that is not JSON: {1}' -f ($Argument -join ' '),
                       $text.Substring(0, [math]::Min(200, $text.Length)))
            }
        }

        $ociCli = if ($OciCliPath) { $OciCliPath } else { 'oci' }
        $resolvedCli = Get-Command -Name $ociCli -ErrorAction SilentlyContinue
        if (-not $resolvedCli) {
            throw ('The OCI CLI was not found ("{0}"). Install it and ensure it is on PATH, or pass ' +
                   '-OciCliPath. There is no first-party OCI PowerShell module; this script wraps the CLI.' -f $ociCli)
        }
        $ociCli = $resolvedCli.Source

        $ociProfile = $CliProfile
        $ociConfigFile = $CliConfigFile
        if ($config -and $config.oci) {
            if (-not $ociProfile -and $config.oci.profileName)          { $ociProfile = $config.oci.profileName }
            if (-not $Region -and $config.oci.defaultRegion)            { $Region = $config.oci.defaultRegion }
            if (-not $CompartmentId -and $config.oci.defaultCompartmentId) { $CompartmentId = $config.oci.defaultCompartmentId }
        }

        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Using OCI CLI at {0}{1}{2}' -f $ociCli,
            $(if ($ociProfile) { ", profile '$ociProfile'" } else { ', default profile' }),
            $(if ($Region) { ", region '$Region'" } else { ', region from profile' }))

        if (-not $CompartmentId) {
            throw 'No compartment. Pass -CompartmentId or set oci.defaultCompartmentId in config.json.'
        }

        $lbs = @((Invoke-OciCli -Argument @('lb', 'load-balancer', 'list', '--compartment-id', $CompartmentId, '--all')).data)
        if ($LoadBalancerName) { $lbs = @($lbs | Where-Object { $LoadBalancerName -contains $_.'display-name' }) }
        $certCutoff = (Get-Date).AddDays($CertificateWarnDays)

        foreach ($lb in $lbs) {
            $issues = @()

            $health = $null
            try { $health = (Invoke-OciCli -Argument @('lb', 'load-balancer-health', 'get', '--load-balancer-id', $lb.id)).data } catch {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $lb.'display-name' `
                    -Message ('Health unavailable: {0}' -f $_.Exception.Message)
            }
            if ($health) {
                $status = "$($health.status)"
                if ($status -ne 'OK') { $issues += ('overall health {0}' -f $status) }
                if (@($health.'critical-state-backend-set-names').Count -gt 0) {
                    $issues += ('backend sets CRITICAL: {0}' -f (@($health.'critical-state-backend-set-names') -join ','))
                }
                if (@($health.'warning-state-backend-set-names').Count -gt 0) {
                    $issues += ('backend sets WARNING: {0}' -f (@($health.'warning-state-backend-set-names') -join ','))
                }
            }

            $certSummary = @()
            $certs = @()
            try { $certs = @((Invoke-OciCli -Argument @('lb', 'certificate', 'list', '--load-balancer-id', $lb.id)).data) } catch {
                Write-Verbose ('No certificates readable on {0}' -f $lb.'display-name')
            }
            foreach ($cert in $certs) {
                # The listing returns the PEM; the expiry has to come out of the
                # certificate itself rather than a field.
                $expiry = $null
                if ($cert.'public-certificate') {
                    try {
                        $pem = "$($cert.'public-certificate')" -replace '-----BEGIN CERTIFICATE-----', '' -replace '-----END CERTIFICATE-----', ''
                        $bytes = [System.Convert]::FromBase64String(($pem -replace '\s', ''))
                        $x509 = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($bytes)
                        $expiry = $x509.NotAfter
                    } catch {
                        Write-Verbose ('Certificate {0} on {1} could not be parsed' -f $cert.'certificate-name', $lb.'display-name')
                    }
                }
                $certSummary += ('{0}{1}' -f $cert.'certificate-name', $(if ($expiry) { ' expires ' + $expiry.ToString('yyyy-MM-dd') } else { ' (expiry not parseable)' }))
                if ($expiry -and $expiry -lt $certCutoff) {
                    $issues += ('certificate {0} expires {1:yyyy-MM-dd}' -f $cert.'certificate-name', $expiry)
                }
            }

            if ($IssuesOnly -and $issues.Count -eq 0) { continue }

            $results.Add([PSCustomObject]@{
                Name          = $lb.'display-name'
                Id            = $lb.id
                LifecycleState= $lb.'lifecycle-state'
                ShapeName     = $lb.'shape-name'
                IsPrivate     = $lb.'is-private'
                IpAddresses   = ((@($lb.'ip-addresses') | ForEach-Object { $_.'ip-address' }) -join '; ')
                OverallHealth = if ($health) { $health.status } else { 'unavailable' }
                BackendSetsTotal = @($lb.'backend-sets'.PSObject.Properties).Count
                BackendSetsCritical = (@($health.'critical-state-backend-set-names') -join '; ')
                BackendSetsWarning  = (@($health.'warning-state-backend-set-names') -join '; ')
                Certificates  = ($certSummary -join '; ')
                Status        = if ($issues.Count) { 'Attention' } else { 'OK' }
                Issues        = ($issues -join '; ')
            })

            if ($issues.Count) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $lb.'display-name' -Message ($issues -join '; ')
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'OCI Load Balancer Health Check'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
