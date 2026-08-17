<#
.SYNOPSIS
    Triggers a Commvault backup on demand.

.DESCRIPTION
    Starts a backup at the requested level for one or more subclients and
    reports the job ids raised. Additive and safe to trigger on demand, which
    is what the workbook guardrail says.

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

.PARAMETER ClientName
    Client(s) whose subclients should be backed up.

.PARAMETER SubclientName
    Limit to these subclients. All subclients on the client when omitted.

.PARAMETER BackupLevel
    Backup level to request.

.PARAMETER AllowConcurrent
    Submit even when a job is already running for the subclient. Off by
    default: a second concurrent job usually queues behind the first and
    confuses the schedule.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Start-CvBackupJob.ps1 -ClientName SQLPROD01 -BackupLevel Full

    Full backup of every subclient on one client.

.EXAMPLE
    .\Start-CvBackupJob.ps1 -ClientName FILESRV01 -SubclientName 'default' -BackupLevel Incremental -WhatIf

    Shows what would be submitted without submitting it.

.NOTES
    Source use case      : #2 - Run a Backup
    Category             : Backup Commvault
    Technology           : Commvault REST API
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Additive; safe to trigger on demand"

    Required permissions : A CommCell user with Backup permission on the target subclients.
    Required modules     : none beyond IT-Automation-Common
    Authentication       : Commvault REST API token obtained per call. No
                           first-party PowerShell module.

    Requesting Full where the schedule expects Incremental changes the
    storage consumed and the next synthetic-full chain. The level is
    therefore explicit rather than defaulted to Full, and the job id of
    every submission is logged so it can be tracked or killed.

    Rollback             : A running backup can be killed from the CommCell
                           console or by job id. A completed backup creates an
                           extra restore point and needs no rollback.
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

    [Parameter(Mandatory)]
    [string[]]$ClientName,

    [string[]]$SubclientName,

    [ValidateSet('Full','Incremental','Differential','Synthetic_Full')]
    [string]$BackupLevel = 'Incremental',

    [switch]$AllowConcurrent,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Start-CvBackupJob'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #2 (Backup Commvault)'

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

        $running = @{}
        try {
            $active = Invoke-CvApi -Path 'Job?jobCategory=Active'
            foreach ($a in @($active.jobs)) {
                $key = '{0}|{1}' -f $a.jobSummary.subclient.clientName, $a.jobSummary.subclient.subclientName
                $running[$key] = $a.jobSummary.jobId
            }
        } catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'Could not read active jobs ({0}); the concurrent-job check cannot be applied this run.' -f $_.Exception.Message)
        }

        foreach ($cName in $ClientName) {
            $subs = @()
            try {
                $resp = Invoke-CvApi -Path ('Subclient?clientName={0}' -f [uri]::EscapeDataString($cName))
                $subs = @($resp.subClientProperties)
            } catch {
                throw ('Could not enumerate subclients for {0}: {1}' -f $cName, $_.Exception.Message)
            }
            if ($subs.Count -eq 0) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $cName -Message 'No subclients returned.'
                continue
            }

            foreach ($sc in $subs) {
                $e = $sc.subClientEntity
                if ($SubclientName -and $SubclientName -notcontains $e.subclientName) { continue }

                $key = '{0}|{1}' -f $e.clientName, $e.subclientName
                if (-not $AllowConcurrent -and $running.ContainsKey($key)) {
                    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $key -Message (
                        'Skipped - job {0} is already running for this subclient' -f $running[$key])
                    continue
                }

                $results.Add([PSCustomObject]@{
                    Name          = ('{0} / {1}' -f $e.clientName, $e.subclientName)
                    Id            = $e.subclientId
                    ClientName    = $e.clientName
                    SubclientName = $e.subclientName
                    BackupSet     = $e.backupsetName
                    AgentType     = $e.appName
                    SubclientId   = $e.subclientId
                    BackupLevel   = $BackupLevel
                    StoragePolicy = $sc.commonProperties.storageDevice.dataBackupStoragePolicy.storagePolicyName
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Start backup')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $resp = Invoke-CvApi -Method POST -Path (
                'Subclient/{0}/action/backup?backupLevel={1}' -f $item.SubclientId, $item.BackupLevel)

            $newJobId = $resp.jobIds
            if (-not $newJobId) { $newJobId = $resp.jobId }
            if (-not $newJobId) {
                throw 'Backup request was accepted but Commvault returned no job id.'
            }

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                '{0} backup submitted as job {1}' -f $item.BackupLevel, ($newJobId -join ','))
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'BackupStarted'
                Detail = ('{0}, job {1}' -f $item.BackupLevel, ($newJobId -join ',')); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Run a Backup'
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
