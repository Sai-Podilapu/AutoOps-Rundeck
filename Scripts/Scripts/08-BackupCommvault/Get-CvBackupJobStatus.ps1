<#
.SYNOPSIS
    Reports the status of Commvault backup jobs.

.DESCRIPTION
    Queries the CommCell for backup jobs over a lookback window and reports
    each one with its outcome, duration and failure reason. A specific job id
    can be queried directly.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER WebServiceUrl
    Commvault Web Service URL, e.g.
    https://commserve.contoso.com/webconsole/api. Falls back to
    commvault.webServiceUrl in config.json.

.PARAMETER Credential
    CommCell credential used to obtain a REST token. Prompted for if neither
    this nor -AccessToken is supplied. A password is never read from
    configuration.

.PARAMETER AccessToken
    An existing Commvault Authtoken as a SecureString. Preferred over
    -Credential: no login round-trip and no password is handled at all.

.PARAMETER JobId
    Report these job ids specifically instead of a time window.

.PARAMETER LookbackHours
    How far back to look when -JobId is not supplied.

.PARAMETER ClientName
    Limit to jobs for these clients.

.PARAMETER FailedOnly
    Report only jobs that failed or were killed.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-CvBackupJobStatus.ps1 -LookbackHours 24 -OutputFormat HTML

    Last 24 hours of backup jobs as HTML.

.EXAMPLE
    .\Get-CvBackupJobStatus.ps1 -JobId 123456,123457

    Status of two specific jobs.

.EXAMPLE
    .\Get-CvBackupJobStatus.ps1 -FailedOnly -LookbackHours 48

    Only the failures over two days.

.NOTES
    Source use case      : #1 - Backup Job Status Check
    Category             : Backup Commvault
    Technology           : Commvault REST API
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Read-only status query"

    Required permissions : A CommCell user with View permission on the clients being reported.
    Required modules     : none beyond IT-Automation-Common
    Authentication       : Commvault REST API token obtained per call. No
                           first-party PowerShell module.

    Job failure reasons come back on the job summary as a delay reason
    code plus text. Where Commvault returns no reason the field is left
    empty rather than filled with a guess.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$WebServiceUrl,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [System.Security.SecureString]$AccessToken,

    [int[]]$JobId,

    [ValidateRange(1,720)]
    [int]$LookbackHours = 24,

    [string[]]$ClientName,

    [switch]$FailedOnly,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-CvBackupJobStatus'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #1 (Backup Commvault)'

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
        Connect-AutomationPlatform -Platform 'Commvault' | Out-Null


        function Invoke-CvApi {
            <#
                .SYNOPSIS
                    Issues one authenticated call against the Commvault REST API.
                .DESCRIPTION
                    Resolves the path against the web service base URL and attaches the
                    session Authtoken. Defined inside the script rather than the shared
                    module because it depends on this run's session state.
            #>
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)]
                [string]$Path,

                [ValidateSet('GET', 'POST', 'PUT', 'DELETE')]
                [string]$Method = 'GET',

                $Body
            )

            $uri = '{0}/{1}' -f $cvBase, $Path.TrimStart('/')
            $callParams = @{
                Uri         = $uri
                Method      = $Method
                Headers     = $cvHeaders
                ErrorAction = 'Stop'
            }
            if ($null -ne $Body) {
                $callParams.Body = ($Body | ConvertTo-Json -Depth 12 -Compress)
            }
            Invoke-RestMethod @callParams
        }

        if (-not $WebServiceUrl) {
            if ($config -and $config.commvault -and $config.commvault.webServiceUrl) {
                $WebServiceUrl = $config.commvault.webServiceUrl
            }
        }
        if (-not $WebServiceUrl) {
            throw 'No Commvault web service URL. Pass -WebServiceUrl or set commvault.webServiceUrl in config.json.'
        }
        $cvBase = $WebServiceUrl.TrimEnd('/')

        # PowerShell 5.1 still negotiates TLS 1.0 by default against some endpoints.
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

        $cvHeaders = @{ 'Accept' = 'application/json'; 'Content-Type' = 'application/json' }
        $cvLoggedIn = $false

        if ($AccessToken) {
            $tokenPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AccessToken)
            try {
                $cvHeaders['Authtoken'] = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($tokenPtr)
            } finally {
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenPtr)
            }
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Using the supplied access token; no login performed.'
        } else {
            if ($Credential -eq [System.Management.Automation.PSCredential]::Empty) {
                $Credential = Get-Credential -Message 'CommCell credentials for the Commvault REST API'
            }

            # /Login wants the password base64-encoded, so it must be a plain string
            # for exactly as long as the request body is built. The BSTR is zeroed in
            # the finally block whether or not the call succeeds.
            $pwdPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
            try {
                $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($pwdPtr)
                $encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($plainPassword))
            } finally {
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pwdPtr)
                Remove-Variable -Name plainPassword -ErrorAction SilentlyContinue
            }

            $loginResponse = Invoke-RestMethod -Uri ('{0}/Login' -f $cvBase) -Method POST -Headers $cvHeaders `
                -Body (@{ username = $Credential.UserName; password = $encoded } | ConvertTo-Json -Compress) `
                -ErrorAction Stop
            Remove-Variable -Name encoded -ErrorAction SilentlyContinue

            if (-not $loginResponse.token) {
                throw ('Commvault login failed for {0}: no token returned.' -f $Credential.UserName)
            }
            $cvHeaders['Authtoken'] = $loginResponse.token
            $cvLoggedIn = $true
            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message (
                'Authenticated to Commvault as {0}' -f $Credential.UserName)
        }

        function Get-CvJobState {
            <#
                .SYNOPSIS
                    Buckets a Commvault job status string into Active / Failed / Completed.
            #>
            [CmdletBinding()]
            [OutputType([string])]
            param([string]$Status)

            switch -Regex ($Status) {
                '(?i)running|waiting|pending|queued|suspend'          { 'Active';    break }
                '(?i)fail|kill|error'                                 { 'Failed';    break }
                '(?i)completed w/ one or more errors|complete.*error' { 'Warning';   break }
                '(?i)complete|success'                                { 'Completed'; break }
                default                                               { 'Unknown' }
            }
        }

        $jobs = @()

        if ($JobId) {
            foreach ($id in $JobId) {
                try {
                    $resp = Invoke-CvApi -Path ('Job/{0}' -f $id)
                    if ($resp.jobs) { $jobs += $resp.jobs }
                } catch {
                    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $id `
                        -Message ('Job could not be read: {0}' -f $_.Exception.Message)
                }
            }
        } else {
            $lookbackSeconds = $LookbackHours * 3600
            $resp = Invoke-CvApi -Path ('Job?completedJobLookupTime={0}' -f $lookbackSeconds)
            if ($resp.jobs) { $jobs = @($resp.jobs) }
        }

        foreach ($j in $jobs) {
            $s = $j.jobSummary
            if (-not $s) { continue }

            $client = $s.destinationClient.clientName
            if (-not $client) { $client = $s.subclient.clientName }
            if ($ClientName -and $ClientName -notcontains $client) { continue }

            $state = Get-CvJobState -Status $s.status
            if ($FailedOnly -and $state -ne 'Failed') { continue }

            # Commvault returns epoch seconds. 0 means "not set", not 1970.
            $start = if ($s.jobStartTime -gt 0) { [System.DateTimeOffset]::FromUnixTimeSeconds($s.jobStartTime).LocalDateTime } else { $null }
            $endTime = if ($s.jobEndTime -gt 0) { [System.DateTimeOffset]::FromUnixTimeSeconds($s.jobEndTime).LocalDateTime } else { $null }

            $results.Add([PSCustomObject]@{
                Name          = ('{0} / job {1}' -f $client, $s.jobId)
                Id            = $s.jobId
                ClientName    = $client
                SubclientName = $s.subclient.subclientName
                BackupSet     = $s.subclient.backupsetName
                Operation     = $s.jobType
                BackupLevel   = $s.backupLevelName
                Status        = $s.status
                State         = $state
                PercentDone   = $s.percentComplete
                StartedAt     = $start
                EndedAt       = $endTime
                DurationMin   = if ($start -and $endTime) { [math]::Round(($endTime - $start).TotalMinutes, 1) } else { $null }
                SizeGB        = if ($s.sizeOfApplication) { [math]::Round($s.sizeOfApplication / 1GB, 2) } else { $null }
                FailedFiles   = $s.totalFailedFiles
                FailureReason = $s.pendingReason
                StoragePolicy = $s.storagePolicy.storagePolicyName
            })

            if ($state -eq 'Failed') {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target ('job {0}' -f $s.jobId) -Message (
                    '{0} on {1}: {2}' -f $s.status, $client, $s.pendingReason)
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Backup Job Status Check'
    Write-Output $candidates


    if ($cvLoggedIn) {
        try {
            Invoke-CvApi -Path 'Logout' -Method POST | Out-Null
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Commvault session closed.'
        } catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'Logout failed ({0}). The token expires on its own.' -f $_.Exception.Message)
        }
    }

    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
