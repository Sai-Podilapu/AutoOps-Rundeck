<#
.SYNOPSIS
    Checks TLS certificate expiry by connecting to each endpoint.

.DESCRIPTION
    Opens a TLS connection to each endpoint and reads the certificate the
    server actually presents. That is the measurement that matters: a
    certificate renewed in the vault but not deployed to the load balancer
    still expires in production.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER Endpoint
    Endpoints to check, as host or host:port.

.PARAMETER WarnDays
    Warn on certificates expiring within this many days.

.PARAMETER CriticalDays
    Report as critical within this many days.

.PARAMETER TimeoutSeconds
    Connection timeout per endpoint.

.PARAMETER IssuesOnly
    Report only endpoints with a finding.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-CertificateExpiryReport.ps1 -Endpoint www.contoso.com,api.contoso.com:8443 -WarnDays 30

    Checks two endpoints, one on a non-default port.

.EXAMPLE
    .\Get-CertificateExpiryReport.ps1 -Endpoint www.contoso.com -IssuesOnly -CriticalDays 14

    Only report if action is needed.

.NOTES
    Source use case      : #7 - SSL/TLS Certificate Expiry Monitor
    Category             : Security Cloud
    Technology           : Python / OpenSSL / ACM
    Difficulty           : Low
    Agent possible       : Partial
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Multi-platform expiry check + alert"

    Required permissions : Network access to each endpoint on its TLS port. No platform credentials are needed.
    Required modules     : none beyond IT-Automation-Common
    Authentication       : Vendor REST API via Invoke-RestMethod, or Graph
                           where the tool is Microsoft.

    This checks what is SERVED, not what is stored. A certificate renewed
    in Key Vault or ACM but not yet bound to the listener will pass every
    inventory check and still take the site down on expiry day -
    connecting is the only way to catch that. Certificate validation is
    deliberately not enforced during the probe, so that an ALREADY-EXPIRED
    or self-signed certificate is reported rather than causing the
    connection to fail and the endpoint to look unreachable.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory)]
    [string[]]$Endpoint,

    [ValidateRange(1,730)]
    [int]$WarnDays = 30,

    [ValidateRange(1,365)]
    [int]$CriticalDays = 7,

    [ValidateRange(1,120)]
    [int]$TimeoutSeconds = 10,

    [switch]$IssuesOnly,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-CertificateExpiryReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #7 (Security Cloud)'

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


        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $now = Get-Date

        foreach ($target in $Endpoint) {
            $parts = $target -split ':', 2
            $hostName = $parts[0]
            $port = if ($parts.Count -eq 2) { [int]$parts[1] } else { 443 }

            $tcpClient = $null
            $sslStream = $null
            try {
                $tcpClient = New-Object System.Net.Sockets.TcpClient
                $connect = $tcpClient.BeginConnect($hostName, $port, $null, $null)
                if (-not $connect.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))) {
                    throw ('Connection timed out after {0}s' -f $TimeoutSeconds)
                }
                $tcpClient.EndConnect($connect)

                # Validation is accepted unconditionally on purpose: the goal is to READ
                # the certificate, including an expired or untrusted one. Rejecting it
                # here would report a genuinely expired certificate as an unreachable
                # host, which is the wrong alert entirely.
                $sslStream = New-Object System.Net.Security.SslStream($tcpClient.GetStream(), $false,
                    ([System.Net.Security.RemoteCertificateValidationCallback] { $true }))
                $sslStream.AuthenticateAsClient($hostName)

                $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($sslStream.RemoteCertificate)
                $daysLeft = [math]::Round(($cert.NotAfter - $now).TotalDays, 1)

                $status = if ($cert.NotAfter -lt $now) { 'EXPIRED' }
                          elseif ($daysLeft -le $CriticalDays) { 'Critical' }
                          elseif ($daysLeft -le $WarnDays) { 'Warning' }
                          else { 'OK' }

                if ($IssuesOnly -and $status -eq 'OK') { continue }

                $sanList = ''
                $sanExtension = $cert.Extensions | Where-Object { $_.Oid.FriendlyName -eq 'Subject Alternative Name' }
                if ($sanExtension) { $sanList = ($sanExtension.Format($false) -replace 'DNS Name=', '') }

                $results.Add([PSCustomObject]@{
                    Name        = $target
                    Id          = $target
                    HostName    = $hostName
                    Port        = $port
                    Subject     = $cert.Subject
                    Issuer      = $cert.Issuer
                    NotBefore   = $cert.NotBefore
                    NotAfter    = $cert.NotAfter
                    DaysLeft    = $daysLeft
                    Thumbprint  = $cert.Thumbprint
                    SignatureAlgorithm = $cert.SignatureAlgorithm.FriendlyName
                    SubjectAltNames = $sanList
                    NameMatches = ($cert.Subject -match [regex]::Escape($hostName)) -or ($sanList -match [regex]::Escape($hostName))
                    Status      = $status
                    Error       = ''
                })

                if ($status -ne 'OK') {
                    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $target -Message (
                        '{0}: expires {1:yyyy-MM-dd} ({2} day(s))' -f $status, $cert.NotAfter, $daysLeft)
                }
            } catch {
                $results.Add([PSCustomObject]@{
                    Name = $target; Id = $target; HostName = $hostName; Port = $port
                    Subject = ''; Issuer = ''; NotBefore = $null; NotAfter = $null; DaysLeft = $null
                    Thumbprint = ''; SignatureAlgorithm = ''; SubjectAltNames = ''; NameMatches = $false
                    Status = 'Unreachable'; Error = $_.Exception.Message
                })
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $target -Message (
                    'Unreachable - certificate NOT checked: {0}' -f $_.Exception.Message)
            } finally {
                if ($sslStream) { $sslStream.Dispose() }
                if ($tcpClient) { $tcpClient.Dispose() }
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'SSL/TLS Certificate Expiry Monitor'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
