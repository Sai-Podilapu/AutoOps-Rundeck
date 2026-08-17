<#
.SYNOPSIS
    Resubmits failed Commvault backup jobs, within the backup window.

.DESCRIPTION
    Finds jobs that failed or were killed over a lookback window and resubmits
    them. The workbook calls this a safe retry but requires it to be
    window-aware, so a resubmission outside the configured backup window is
    refused rather than queued.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

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
    How far back to look for failures.

.PARAMETER ClientName
    Limit to these clients.

.PARAMETER MaxJobs
    Ceiling on how many jobs may be resubmitted in one run.

.PARAMETER WindowStartHour
    First hour of the backup window, 24h local time.

.PARAMETER WindowEndHour
    Last hour of the backup window, 24h local time.

.PARAMETER IgnoreWindow
    Resubmit outside the backup window. Use only for a ticket-driven catch-up.

.PARAMETER ExcludeReasonPattern
    Do not resubmit a job whose failure reason matches these patterns - a
    retry will not fix them.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Restart-CvFailedJob.ps1 -LookbackHours 12

    Resubmit failures from the last 12 hours, if inside the window.

.EXAMPLE
    .\Restart-CvFailedJob.ps1 -LookbackHours 24 -IgnoreWindow -WhatIf

    Shows what a ticket-driven catch-up would resubmit.

.NOTES
    Source use case      : #3 - Re-run a Failed Job
    Category             : Backup Commvault
    Technology           : Commvault REST API
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Safe retry; window-aware per SOP"

    Required permissions : A CommCell user with Backup permission on the affected subclients.
    Required modules     : none beyond IT-Automation-Common
    Authentication       : Commvault REST API token obtained per call. No
                           first-party PowerShell module.

    Resubmitting a job that failed for a structural reason - expired
    licence, bad credential, a path that no longer exists - burns a backup
    window and fails identically. Those reasons are excluded by default
    via -ExcludeReasonPattern rather than retried blindly.

    Rollback             : A resubmitted job can be killed by its new job id.
                           The original failed job is not modified.
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$WebServiceUrl,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [System.Security.SecureString]$AccessToken,

    [ValidateRange(1,168)]
    [int]$LookbackHours = 12,

    [string[]]$ClientName,

    [ValidateRange(1,500)]
    [int]$MaxJobs = 25,

    [ValidateRange(0,23)]
    [int]$WindowStartHour = 22,

    [ValidateRange(0,23)]
    [int]$WindowEndHour = 5,

    [switch]$IgnoreWindow,

    [string[]]$ExcludeReasonPattern = @('*license*','*credential*','*access denied*','*no such file*'),

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Restart-CvFailedJob'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #3 (Backup Commvault)'

    try {
        $config = if ($ConfigPath) { Get-AutomationConfig -Path $ConfigPath } else { Get-AutomationConfig }
        # Recorded so an audit can tell which environment a run targeted.
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Configuration loaded for environment: {0}' -f $config.environment)
    } catch {
        # Fail closed. Safety lists and endpoints live in config; acting
        # without them would bypass the guardrails this use case requires.
        throw ('Cannot read configuration, refusing to proceed: {0}' -f $_.Exception.Message)
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
        $hour = $now.Hour

        # A window that wraps midnight (22:00-05:00) is not a simple range test.
        $inWindow = if ($WindowStartHour -le $WindowEndHour) {
            $hour -ge $WindowStartHour -and $hour -le $WindowEndHour
        } else {
            $hour -ge $WindowStartHour -or $hour -le $WindowEndHour
        }

        if (-not $inWindow -and -not $IgnoreWindow) {
            throw ('Outside the backup window ({0:00}:00-{1:00}:00, now {2:HH:mm}). Refusing to resubmit. ' +
                   'Pass -IgnoreWindow for a ticket-driven catch-up.' -f $WindowStartHour, $WindowEndHour, $now)
        }
        if (-not $inWindow) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'Running OUTSIDE the backup window because -IgnoreWindow was passed.')
        }

        $resp = Invoke-CvApi -Path ('Job?completedJobLookupTime={0}' -f ($LookbackHours * 3600))
        $considered = 0

        foreach ($j in @($resp.jobs)) {
            $s = $j.jobSummary
            if (-not $s) { continue }
            if ((Get-CvJobState -Status $s.status) -ne 'Failed') { continue }

            $client = $s.destinationClient.clientName
            if (-not $client) { $client = $s.subclient.clientName }
            if ($ClientName -and $ClientName -notcontains $client) { continue }

            $considered++

            $reason = "$($s.pendingReason)"
            $blocked = $null
            foreach ($pattern in $ExcludeReasonPattern) {
                if ($reason -like $pattern) { $blocked = $pattern; break }
            }
            if ($blocked) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('job {0}' -f $s.jobId) -Message (
                    'Not resubmitted - failure reason matches "{0}". A retry will fail the same way: {1}' -f $blocked, $reason)
                continue
            }

            if ($results.Count -ge $MaxJobs) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                    'Reached -MaxJobs ({0}). {1} further failed job(s) were NOT queued this run.' -f $MaxJobs, ($considered - $results.Count))
                break
            }

            $results.Add([PSCustomObject]@{
                Name          = ('{0} / job {1}' -f $client, $s.jobId)
                Id            = $s.jobId
                JobId         = $s.jobId
                ClientName    = $client
                SubclientName = $s.subclient.subclientName
                Operation     = $s.jobType
                BackupLevel   = $s.backupLevelName
                Status        = $s.status
                FailureReason = $reason
                FailedAt      = if ($s.jobEndTime -gt 0) { [System.DateTimeOffset]::FromUnixTimeSeconds($s.jobEndTime).LocalDateTime } else { $null }
                InWindow      = $inWindow
            })
        }
    } catch {
        $msg = $_.Exception.Message
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Message ('Discovery FAILED: {0}' -f $msg)
        $failures.Add([PSCustomObject]@{ Stage = 'Discovery'; Error = $msg })
    }
}

end {
    $candidates = @($results)

    if ($candidates.Count -eq 0) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'No eligible objects. Nothing to do.'
        Write-Output @()

        if ($cvLoggedIn) {
            try {
                Invoke-CvApi -Path 'Logout' -Method POST | Out-Null
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Commvault session closed.'
            } catch {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                    'Logout failed ({0}). The token expires on its own.' -f $_.Exception.Message)
            }
        }
        return
    }

    # Every candidate is logged individually BEFORE any action is taken.
    foreach ($c in $candidates) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0}' -f $c.Name) -Message 'CANDIDATE'
    }

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Resubmit failed job')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $resp = Invoke-CvApi -Method POST -Path ('Job/{0}/action/resubmit' -f $item.JobId)

            $newJobId = $resp.jobIds
            if (-not $newJobId) { $newJobId = $resp.jobId }

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Job {0} resubmitted{1}. Original failure: {2}' -f
                $item.JobId, $(if ($newJobId) { ' as ' + ($newJobId -join ',') } else { '' }), $item.FailureReason)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'Resubmitted'
                Detail = ('new job {0}' -f ($newJobId -join ',')); Succeeded = $true })
        } catch {
            $msg = $_.Exception.Message
            Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $label -Message ('FAILED: {0}' -f $msg)
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'Failed'; Detail = $msg; Succeeded = $false })
        }
    }

    $ok  = @($actions | Where-Object { $_.Succeeded })
    $bad = @($actions | Where-Object { -not $_.Succeeded })
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'END. Succeeded={0} Failed={1}' -f $ok.Count, $bad.Count)

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Re-run a Failed Job'
    Write-Output $actions.ToArray()

    if ($cvLoggedIn) {
        try {
            Invoke-CvApi -Path 'Logout' -Method POST | Out-Null
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Commvault session closed.'
        } catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'Logout failed ({0}). The token expires on its own.' -f $_.Exception.Message)
        }
    }
    if ($bad.Count -gt 0) { exit 1 }
}
