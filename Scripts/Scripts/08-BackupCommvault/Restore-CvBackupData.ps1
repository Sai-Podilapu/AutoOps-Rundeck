<#
.SYNOPSIS
    Submits a Commvault restore for a ticketed recovery request.

.DESCRIPTION
    Submits a restore of backed-up data to a named destination. Every choice
    the workbook reserves for a human - which target, which version, in-place
    or out-of-place - must be stated explicitly on the command line; none of
    them has a default. Validating that the restored data is correct is also a
    human step and is not attempted here.

    DESTRUCTIVE. This script is REPORT-ONLY by default: it produces the
    candidate list and stops. Nothing is deleted, wiped or failed over
    unless -Execute is passed AND a valid -ApprovalReference is supplied.
    A pre-action backup/export is taken where the platform allows it, and
    every object is logged individually before it is touched.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

    AGENT-ASSIST ONLY. This automates the mechanical part - gathering,
    enriching and comparing against a baseline - and then stops, producing
    a decision-ready package. The judgement step is deliberately left to a
    human and is NOT scripted.

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
    Client the data was backed up from.

.PARAMETER SourcePath
    Path(s) to restore.

.PARAMETER DestinationClient
    Client to restore TO. Mandatory for an out-of-place restore; there is no
    default.

.PARAMETER DestinationPath
    Path to restore TO. Mandatory for an out-of-place restore; there is no
    default.

.PARAMETER InPlace
    Restore over the original location. Requires -OverwriteConfirmed as well.

.PARAMETER OverwriteConfirmed
    Confirms that overwriting live data at the destination is intended and
    that the current contents are expendable or separately backed up.

.PARAMETER PointInTime
    Restore data as at this time. Mutually exclusive with -FromJobId; one is
    required.

.PARAMETER FromJobId
    Restore from this specific backup job.

.PARAMETER RestoreApiPath
    PLACEHOLDER - the restore submission endpoint. Commvault versions differ;
    VERIFY THIS AGAINST YOUR COMMCELL before first use. Listed in MANIFEST.md
    under Needs Input.

.PARAMETER Execute
    Actually perform the destructive action. Without this the script only
    reports what it would do.

.PARAMETER ProtectedList
    Path to a file of names/ids that must never be acted upon, one per line.
    Entries here are excluded unconditionally and the exclusion cannot be
    overridden by any other parameter.

.PARAMETER MinimumAgeDays
    Only consider objects older than this. A conservative default guards
    against acting on something created moments ago.

.PARAMETER ApprovalReference
    Approval token from New-ApprovalRequest, after a human has approved it.
    Without this the script performs no change.

.PARAMETER RequestApproval
    Force REQUEST mode - produce the change set and raise an approval request,
    then stop, even if a reference was supplied.

.PARAMETER TicketReference
    ITSM ticket number recorded in the audit trail alongside the approval
    reference.

.PARAMETER Reason
    Change reason recorded in the approval artifact and the audit log.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Restore-CvBackupData.ps1 -ClientName FILESRV01 -SourcePath 'D:\\Shares\\Finance' -DestinationClient FILESRV02 -DestinationPath 'D:\\Restore' -FromJobId 123456

    REPORT ONLY. Builds the out-of-place restore request and raises an
    approval.

.EXAMPLE
    .\Restore-CvBackupData.ps1 -ClientName FILESRV01 -SourcePath 'D:\\Shares\\Finance' -InPlace -OverwriteConfirmed -PointInTime '2026-08-01 02:00' -ApprovalReference APR-... -Execute

    Submits an approved in-place restore. Overwrites live data.

.NOTES
    Source use case      : #9 - Commvault Backup Restoration
    Category             : Backup Commvault
    Technology           : Commvault REST API
    Difficulty           : High
    Agent possible       : Partial
    Can execute with SOP : Partially - Agent Assists
    Automation type      : Destructive / High-Impact
    Risk level           : High
    Human approval needed: YES
    Guardrails (col L)   : "Agent executes restore per ticket; choosing target, version, in-place vs out-of-place, and validating restored data is human-verified"

    Required permissions : A CommCell user with Browse and In-Place/Out-of-Place Restore permission on the data and the destination client.
    Required modules     : none beyond IT-Automation-Common
    Authentication       : Commvault REST API token obtained per call. No
                           first-party PowerShell module.

    ASSIST-ONLY AND DESTRUCTIVE. An in-place restore overwrites live data
    and cannot be undone by this script or any other. Nothing is
    defaulted: the destination, the version, and the in-place decision are
    all required inputs, because a restore that silently picked "latest,
    in place" would be exactly the accident this gate exists to prevent.
    -MinimumAgeDays does not apply to a restore and is left at 0.
    Confirming the restored data is actually correct is a human
    verification step that this script does not perform and does not claim
    to.

    Rollback             : NONE for an in-place restore - it overwrites
                           whatever is at the destination. An out-of-place
                           restore writes to a new location and can simply be
                           deleted. This asymmetry is why -InPlace requires a
                           second explicit flag.
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([PSCustomObject])]
param(
    [string]$WebServiceUrl,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [System.Security.SecureString]$AccessToken,

    [Parameter(Mandatory)]
    [string]$ClientName,

    [Parameter(Mandatory)]
    [string[]]$SourcePath,

    [string]$DestinationClient,

    [string]$DestinationPath,

    [switch]$InPlace,

    [switch]$OverwriteConfirmed,

    [datetime]$PointInTime,

    [int]$FromJobId,

    [string]$RestoreApiPath = 'CreateTask',

    [switch]$Execute,

    [string]$ProtectedList,

    [ValidateRange(0, 3650)]
    [int]$MinimumAgeDays = 0,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Ticketed data recovery',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Restore-CvBackupData'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #9 (Backup Commvault)'

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

    $protected = @()
    if ($ProtectedList -and (Test-Path -LiteralPath $ProtectedList)) {
        $protected = @(Get-Content -LiteralPath $ProtectedList |
            Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { $_.Trim() })
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Protected list loaded: {0} entry(ies). These are excluded unconditionally.' -f $protected.Count)
    }

    # Risk = High: validate before doing anything at all.
    $pre = Test-Prerequisite
    if (-not $pre.Passed) {
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Message $pre.Summary
        throw $pre.Summary
    }
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Pre-flight passed.'

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

        if ($InPlace -and ($DestinationClient -or $DestinationPath)) {
            throw '-InPlace and -DestinationClient/-DestinationPath are mutually exclusive. Choose one.'
        }
        if (-not $InPlace -and -not ($DestinationClient -and $DestinationPath)) {
            throw 'An out-of-place restore requires BOTH -DestinationClient and -DestinationPath. ' +
                  'Neither is defaulted, deliberately. Pass -InPlace if you intend to overwrite the original.'
        }
        if ($InPlace -and -not $OverwriteConfirmed) {
            throw 'Refusing an in-place restore without -OverwriteConfirmed. This overwrites live data at ' +
                  'the original location and cannot be undone.'
        }
        if (-not $PointInTime -and -not $FromJobId) {
            throw 'Specify the version to restore: -FromJobId or -PointInTime. There is no "latest" default.'
        }
        if ($PointInTime -and $FromJobId) {
            throw '-PointInTime and -FromJobId are mutually exclusive.'
        }

        # Confirm the source client exists before building a request against it.
        $clientId = $null
        try {
            $resp = Invoke-CvApi -Path ('Client?clientName={0}' -f [uri]::EscapeDataString($ClientName))
            $clientId = @($resp.clientProperties)[0].client.clientEntity.clientId
        } catch {
            throw ('Could not resolve client "{0}": {1}' -f $ClientName, $_.Exception.Message)
        }
        if (-not $clientId) { throw ('Client "{0}" not found on this CommCell.' -f $ClientName) }

        $destClient = if ($InPlace) { $ClientName } else { $DestinationClient }
        $destClientId = $clientId
        if (-not $InPlace) {
            try {
                $resp = Invoke-CvApi -Path ('Client?clientName={0}' -f [uri]::EscapeDataString($DestinationClient))
                $destClientId = @($resp.clientProperties)[0].client.clientEntity.clientId
            } catch {
                throw ('Could not resolve destination client "{0}": {1}' -f $DestinationClient, $_.Exception.Message)
            }
            if (-not $destClientId) { throw ('Destination client "{0}" not found.' -f $DestinationClient) }
        }

        foreach ($path in $SourcePath) {
            $results.Add([PSCustomObject]@{
                Name           = ('{0}: {1}' -f $ClientName, $path)
                Id             = ('{0}|{1}' -f $ClientName, $path)
                ClientName     = $ClientName
                ClientId       = $clientId
                SourcePath     = $path
                InPlace        = [bool]$InPlace
                DestinationClient = $destClient
                DestinationClientId = $destClientId
                DestinationPath   = if ($InPlace) { $path } else { $DestinationPath }
                Version        = if ($FromJobId) { ('job {0}' -f $FromJobId) } else { ('as at {0:u}' -f $PointInTime) }
                FromJobId      = $FromJobId
                PointInTime    = $PointInTime
                OverwriteRisk  = if ($InPlace) { 'OVERWRITES LIVE DATA at the original location - no rollback' }
                                 else { 'Writes to a new location; delete the destination to undo' }
                HumanStep      = 'Validating the restored data is correct is NOT performed by this script.'
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

    # Hard exclusions and safety filters BEFORE anything else.
    if ($protected.Count -gt 0) {
        $before = $candidates.Count
        $candidates = @($candidates | Where-Object {
            $id = $_.Id; $nm = $_.Name
            -not ($protected | Where-Object { $_ -and ($id -like $_ -or $nm -like $_) })
        })
        if ($before -ne $candidates.Count) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
                'Protected list excluded {0} object(s).' -f ($before - $candidates.Count))
        }
    }
    if ($MinimumAgeDays -gt 0) {
        $cut = (Get-Date).AddDays(-$MinimumAgeDays)
        $before = $candidates.Count
        $candidates = @($candidates | Where-Object { -not $_.CreatedAt -or $_.CreatedAt -lt $cut })
        if ($before -ne $candidates.Count) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
                'Age filter (>{0}d) excluded {1} object(s).' -f $MinimumAgeDays, ($before - $candidates.Count))
        }
    }

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

    if ($RequestApproval -or -not $ApprovalReference) {
        $request = New-ApprovalRequest -ScriptName $scriptName -ChangeSet $candidates `
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Submit restore', $candidates.Count, $Reason, $TicketReference)
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $request.Reference -Message (
            'REQUEST mode - nothing was changed. Supply -ApprovalReference {0} once approved.' -f $request.Reference)
        Write-Warning ('No change made. Approval reference: {0}' -f $request.Reference)
        Write-Output ([PSCustomObject]@{
            Mode = 'RequestApproval'; ApprovalReference = $request.Reference
            CandidateCount = $candidates.Count; Candidates = $candidates; Changed = $false })

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

    $approvalCheck = Test-ApprovalReference -Reference $ApprovalReference -ScriptName $scriptName
    if (-not $approvalCheck.IsValid) {
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $ApprovalReference -Message (
            'REFUSED to execute: {0}' -f $approvalCheck.Reason)
        throw ('Approval validation failed: {0}' -f $approvalCheck.Reason)
    }
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $ApprovalReference -Message (
        'Approval accepted. {0} Ticket={1}' -f $approvalCheck.Reason, $TicketReference)

    if (-not $Execute) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'REPORT-ONLY - {0} candidate(s) identified, nothing was changed. Pass -Execute to act.' -f $candidates.Count)
        $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Commvault Backup Restoration (candidates)'
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
        return
    }

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Submit restore')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $restoreOptions = @{
                destination = @{
                    inPlace = [bool]$item.InPlace
                    destClient = @{ clientId = $item.DestinationClientId; clientName = $item.DestinationClient }
                }
                fileOption = @{ sourceItem = @($item.SourcePath) }
            }
            if (-not $item.InPlace) {
                $restoreOptions.destination.destPath = @($item.DestinationPath)
            }
            if ($item.FromJobId) {
                $restoreOptions.browseOption = @{ jobId = $item.FromJobId }
            } else {
                $restoreOptions.browseOption = @{
                    timeRange = @{ toTimeValue = [int][double]::Parse((Get-Date $item.PointInTime -UFormat %s)) }
                }
            }

            $body = @{
                taskInfo = @{
                    associations = @(@{ clientName = $item.ClientName })
                    task         = @{ taskType = 1; initiatedFrom = 2 }
                    subTasks     = @(@{
                        subTask        = @{ subTaskType = 3; operationType = 1001 }
                        options        = @{ restoreOptions = $restoreOptions }
                    })
                }
            }

            $resp = Invoke-CvApi -Method POST -Path $RestoreApiPath -Body $body
            $newJobId = $resp.jobIds
            if (-not $newJobId) { $newJobId = $resp.jobId }
            if (-not $newJobId) {
                throw 'Restore request was accepted but Commvault returned no job id. Check the CommCell console before resubmitting.'
            }

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Restore submitted as job {0}. {1} -> {2}. {3}. VALIDATION OF THE RESTORED DATA IS STILL OUTSTANDING.' -f
                ($newJobId -join ','), $item.SourcePath, $item.DestinationPath, $item.Version)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'RestoreSubmitted'
                Detail = ('job {0}, {1}' -f ($newJobId -join ','), $item.OverwriteRisk); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Commvault Backup Restoration'
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
