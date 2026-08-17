<#
.SYNOPSIS
    Lists Commvault schedules due in the next two days.

.DESCRIPTION
    Reports the schedules configured on the CommCell together with their next
    run time, so an operator can see what is due before a change window.
    Schedules whose next run time the API does not return are reported with
    their pattern and a null next-run rather than a computed guess.

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

.PARAMETER LookaheadDays
    How far ahead to report.

.PARAMETER ClientName
    Limit to these clients.

.PARAMETER IncludeDisabled
    Include schedules that are currently disabled.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-CvScheduledJob.ps1 -LookaheadDays 2 -OutputFormat HTML

    What is scheduled over the next two days.

.EXAMPLE
    .\Get-CvScheduledJob.ps1 -LookaheadDays 7 -ClientName SQLPROD01

    A week ahead for one client.

.NOTES
    Source use case      : #5 - Display Scheduled Jobs (next 2 days)
    Category             : Backup Commvault
    Technology           : Commvault REST API
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Read-only"

    Required permissions : A CommCell user with View permission on the clients being reported.
    Required modules     : none beyond IT-Automation-Common
    Authentication       : Commvault REST API token obtained per call. No
                           first-party PowerShell module.

    Commvault returns a schedule pattern; whether it also returns a
    resolved next-run epoch varies by version and pattern type. This
    script reports the next run where the API supplies it and NULL where
    it does not - it does not re-implement Commvault's scheduler to fill
    the gap, because a computed time that disagreed with the CommCell
    would be worse than no time at all. Schedules with a null next run are
    still listed, with their pattern.

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

    [ValidateRange(1,30)]
    [int]$LookaheadDays = 2,

    [string[]]$ClientName,

    [switch]$IncludeDisabled,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-CvScheduledJob'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #5 (Backup Commvault)'

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

        $resp = Invoke-CvApi -Path 'Schedules'
        $horizon = (Get-Date).AddDays($LookaheadDays)
        $now = Get-Date
        $unresolved = 0

        foreach ($task in @($resp.taskDetail)) {
            $client = 'CommCell'
            $assoc = @($task.associations)[0]
            if ($assoc -and $assoc.clientName) { $client = $assoc.clientName }
            if ($ClientName -and $ClientName -notcontains $client) { continue }

            foreach ($sub in @($task.subTasks)) {
                $pattern = $sub.pattern
                $enabled = -not ($task.task.taskFlags -and $task.task.taskFlags.disabled)
                if (-not $enabled -and -not $IncludeDisabled) { continue }

                # Present on most versions; absent on some pattern types. Absent is
                # reported as absent.
                $next = $null
                if ($pattern -and $pattern.nextScheduleTime -and $pattern.nextScheduleTime -gt 0) {
                    $next = [System.DateTimeOffset]::FromUnixTimeSeconds($pattern.nextScheduleTime).LocalDateTime
                }

                if ($null -eq $next) {
                    $unresolved++
                } elseif ($next -lt $now -or $next -gt $horizon) {
                    continue
                }

                $results.Add([PSCustomObject]@{
                    Name          = ('{0} / {1}' -f $client, $sub.subTask.subTaskName)
                    Id            = $sub.subTask.subTaskId
                    ClientName    = $client
                    ScheduleName  = $sub.subTask.subTaskName
                    TaskName      = $task.task.taskName
                    Operation     = $sub.subTask.operationType
                    BackupLevel   = $sub.options.backupOpts.backupLevel
                    Enabled       = $enabled
                    NextRun       = $next
                    HoursUntil    = if ($next) { [math]::Round(($next - $now).TotalHours, 1) } else { $null }
                    FreqType      = $pattern.freq_type
                    PatternSummary= if ($pattern) { ('freq={0} interval={1} time={2}' -f $pattern.freq_type, $pattern.freq_interval, $pattern.active_start_time) } else { '' }
                    NextRunSource = if ($next) { 'reported by CommCell' } else { 'NOT returned by this endpoint - pattern shown instead' }
                })
            }
        }

        if ($unresolved -gt 0) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                '{0} schedule(s) had no next-run time from the API and are listed with their pattern instead. ' +
                'They are NOT filtered by the {1}-day horizon.' -f $unresolved, $LookaheadDays)
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Display Scheduled Jobs (next 2 days)'
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
