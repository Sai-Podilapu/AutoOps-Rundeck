<#
.SYNOPSIS
    Reports Commvault backup health across clients, jobs and libraries.

.DESCRIPTION
    Builds a health picture from three angles: job outcomes over the reporting
    window, clients with no successful backup inside their expected interval,
    and library capacity. A client that has silently stopped backing up is the
    finding that matters most, and it does not appear in a job report at all -
    it appears as an absence.

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

.PARAMETER LookbackHours
    Reporting window for job outcomes.

.PARAMETER ExpectedIntervalHours
    A client with no successful backup within this many hours is reported as
    stale.

.PARAMETER LibraryFreeSpaceWarnPercent
    Warn when a library falls below this percent free.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-CvBackupHealthReport.ps1 -LookbackHours 24 -OutputFormat HTML

    Daily health report as HTML.

.EXAMPLE
    .\Get-CvBackupHealthReport.ps1 -LookbackHours 168 -ExpectedIntervalHours 168

    Weekly view for weekly-backup clients.

.NOTES
    Source use case      : #7 - Commvault Backup Health Check
    Category             : Backup Commvault
    Technology           : Commvault REST API
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Health report only"

    Required permissions : A CommCell user with View permission on clients and libraries.
    Required modules     : none beyond IT-Automation-Common
    Authentication       : Commvault REST API token obtained per call. No
                           first-party PowerShell module.

    "No successful backup" is derived from the job history inside
    -LookbackHours. A client whose backup interval is longer than the
    lookback will look stale when it is not, which is why
    -ExpectedIntervalHours is separate from -LookbackHours and defaults
    higher.

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

    [ValidateRange(1,720)]
    [int]$LookbackHours = 24,

    [ValidateRange(1,8760)]
    [int]$ExpectedIntervalHours = 36,

    [ValidateRange(1,99)]
    [int]$LibraryFreeSpaceWarnPercent = 15,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-CvBackupHealthReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #7 (Backup Commvault)'

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

        $now = Get-Date
        $lookbackSeconds = [math]::Max($LookbackHours, $ExpectedIntervalHours) * 3600

        $jobs = @()
        try {
            $resp = Invoke-CvApi -Path ('Job?completedJobLookupTime={0}' -f $lookbackSeconds)
            $jobs = @($resp.jobs)
        } catch {
            throw ('Could not read job history: {0}' -f $_.Exception.Message)
        }

        # --- 1. Job outcome summary over the window ----------------------------
        $windowCutoff = $now.AddHours(-$LookbackHours)
        $succeeded = 0; $failed = 0; $warned = 0
        $lastGoodByClient = @{}

        foreach ($j in $jobs) {
            $s = $j.jobSummary
            if (-not $s) { continue }
            $client = $s.destinationClient.clientName
            if (-not $client) { $client = $s.subclient.clientName }
            if (-not $client) { continue }

            $ended = if ($s.jobEndTime -gt 0) { [System.DateTimeOffset]::FromUnixTimeSeconds($s.jobEndTime).LocalDateTime } else { $null }
            $state = Get-CvJobState -Status $s.status

            if ($state -eq 'Completed' -and $ended) {
                if (-not $lastGoodByClient.ContainsKey($client) -or $ended -gt $lastGoodByClient[$client]) {
                    $lastGoodByClient[$client] = $ended
                }
            }

            if ($ended -and $ended -lt $windowCutoff) { continue }
            switch ($state) {
                'Completed' { $succeeded++ }
                'Failed'    { $failed++ }
                'Warning'   { $warned++ }
                default     { }
            }
        }

        $total = $succeeded + $failed + $warned

        # All three record types share one shape so a CSV export keeps every column;
        # Export-Csv takes its header from the first object it sees.
        function ConvertTo-CvHealthRecord {
            [CmdletBinding()]
            [OutputType([PSCustomObject])]
            param($Name, $Id, $RecordType, $Detail, $Status,
                  $JobsSucceeded, $JobsFailed, $JobsWarned, $TotalJobs, $SuccessRate,
                  $LastGoodBackup, $AgeHours, $TotalSpace, $FreeSpace, $PercentFree)

            [PSCustomObject]@{
                Name = $Name; Id = $Id; RecordType = $RecordType
                JobsSucceeded = $JobsSucceeded; JobsFailed = $JobsFailed; JobsWarned = $JobsWarned
                TotalJobs = $TotalJobs; SuccessRate = $SuccessRate
                LastGoodBackup = $LastGoodBackup; AgeHours = $AgeHours
                TotalSpace = $TotalSpace; FreeSpace = $FreeSpace; PercentFree = $PercentFree
                Detail = $Detail; Status = $Status
            }
        }

        $results.Add((ConvertTo-CvHealthRecord -Name ('Job outcomes, last {0}h' -f $LookbackHours) `
            -Id 'job-summary' -RecordType 'JobSummary' `
            -JobsSucceeded $succeeded -JobsFailed $failed -JobsWarned $warned -TotalJobs $total `
            -SuccessRate $(if ($total -gt 0) { [math]::Round(($succeeded / $total) * 100, 1) } else { $null }) `
            -Detail $(if ($total -eq 0) { 'No jobs completed in the window' } else { '' }) `
            -Status $(if ($failed -gt 0) { 'Degraded' } elseif ($total -eq 0) { 'NoData' } else { 'OK' })))

        # --- 2. Clients with no recent successful backup -----------------------
        $clients = @()
        try {
            $resp = Invoke-CvApi -Path 'Client'
            $clients = @($resp.clientProperties)
        } catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'Client list unavailable ({0}); stale-client detection skipped this run.' -f $_.Exception.Message)
        }

        foreach ($c in $clients) {
            $name = $c.client.clientEntity.clientName
            if (-not $name) { continue }

            $lastGood = if ($lastGoodByClient.ContainsKey($name)) { $lastGoodByClient[$name] } else { $null }
            $ageHours = if ($lastGood) { [math]::Round(($now - $lastGood).TotalHours, 1) } else { $null }
            $stale = ($null -eq $lastGood) -or ($ageHours -gt $ExpectedIntervalHours)
            if (-not $stale) { continue }

            $results.Add((ConvertTo-CvHealthRecord -Name $name -Id $c.client.clientEntity.clientId `
                -RecordType 'StaleClient' -LastGoodBackup $lastGood -AgeHours $ageHours `
                -Detail $(if ($lastGood) { ('Last success {0}h ago, expected within {1}h' -f $ageHours, $ExpectedIntervalHours) }
                          else { ('NO successful backup in the {0}h examined' -f [math]::Max($LookbackHours, $ExpectedIntervalHours)) }) `
                -Status 'Stale'))
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $name -Message (
                'No successful backup within the expected {0}h interval' -f $ExpectedIntervalHours)
        }

        # --- 3. Library capacity ------------------------------------------------
        try {
            $libs = Invoke-CvApi -Path 'Library'
            foreach ($lib in @($libs.response)) {
                $info = $lib.libraryInfo
                if (-not $info) { continue }
                # Reported as raw values plus a percentage. The unit Commvault uses for
                # these fields varies, so they are not relabelled as GB here - the
                # percentage is unit-independent and is what the threshold tests.
                $totalSpace = $info.totalSpace
                $freeSpace = $info.freeSpace
                if (-not $totalSpace -or $totalSpace -le 0) { continue }

                $pctFree = [math]::Round(($freeSpace / $totalSpace) * 100, 1)
                $results.Add((ConvertTo-CvHealthRecord -Name $lib.entityInfo.name -Id $lib.entityInfo.id `
                    -RecordType 'Library' -TotalSpace $totalSpace -FreeSpace $freeSpace -PercentFree $pctFree `
                    -Detail ('{0}% free' -f $pctFree) `
                    -Status $(if ($pctFree -lt $LibraryFreeSpaceWarnPercent) { 'LowSpace' } else { 'OK' })))
                if ($pctFree -lt $LibraryFreeSpaceWarnPercent) {
                    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $lib.entityInfo.name -Message (
                        'Library {0}% free, below the {1}% threshold' -f $pctFree, $LibraryFreeSpaceWarnPercent)
                }
            }
        } catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'Library capacity unavailable from this endpoint ({0}); capacity section omitted rather than estimated.' -f $_.Exception.Message)
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Commvault Backup Health Check'
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
