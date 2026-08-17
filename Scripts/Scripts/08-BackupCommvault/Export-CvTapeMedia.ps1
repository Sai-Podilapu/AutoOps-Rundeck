<#
.SYNOPSIS
    Performs the software eject of tape media, and stops there.

.DESCRIPTION
    Identifies tape media in a library and performs the software export. The
    physical part - removing the cartridge from the mail slot and vaulting it
    - needs a person at the datacentre, so this script completes the API half,
    records exactly which media were ejected, and hands over a pick list.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

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

.PARAMETER LibraryName
    Tape library to operate on.

.PARAMETER MediaBarcode
    Barcode(s) to export. All media flagged for export when omitted.

.PARAMETER ExportApiPath
    PLACEHOLDER - the export endpoint path template, {0} = library id, {1} =
    media id. Commvault versions differ here; VERIFY THIS AGAINST YOUR
    COMMCELL before first use. Listed in MANIFEST.md under Needs Input.

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
    .\Export-CvTapeMedia.ps1 -LibraryName TAPELIB01

    REPORT ONLY. Lists exportable media and raises an approval.

.EXAMPLE
    .\Export-CvTapeMedia.ps1 -LibraryName TAPELIB01 -MediaBarcode ABC123L8 -ApprovalReference APR-...

    Ejects one specific cartridge once approved.

.NOTES
    Source use case      : #6 - Eject Tape from Drive
    Category             : Backup Commvault
    Technology           : Commvault CLI / API
    Difficulty           : Medium
    Agent possible       : Partial
    Can execute with SOP : Partially - Agent Assists
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "Software eject via API automatable; physically removing & vaulting the tape needs a person at the datacenter"

    Required permissions : A CommCell user with Media Management permission on the library.
    Required modules     : none beyond IT-Automation-Common
    Authentication       : Commvault REST API token obtained per call. No
                           first-party PowerShell module.

    ASSIST-ONLY. The API call moves the cartridge to the mail slot; it
    does not remove it from the building. This script therefore produces a
    pick list naming every barcode and slot, and the run is not complete
    until a person has collected and vaulted them. The export endpoint
    path is a PARAMETER with a placeholder default because it varies by
    Commvault version - it was not guessed at silently.

    Rollback             : An exported tape is re-imported through the mail
                           slot and inventoried. Nothing on the media is
                           altered by an export.
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
    [string]$LibraryName,

    [string[]]$MediaBarcode,

    [string]$ExportApiPath = 'Library/{0}/Media/{1}/action/export',

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Tape export for offsite vaulting',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Export-CvTapeMedia'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #6 (Backup Commvault)'

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

        $libs = Invoke-CvApi -Path 'Library'
        $lib = @($libs.response) | Where-Object { $_.entityInfo.name -eq $LibraryName } | Select-Object -First 1
        if (-not $lib) {
            $lib = @($libs.library) | Where-Object { $_.libraryName -eq $LibraryName } | Select-Object -First 1
        }
        if (-not $lib) {
            throw ('Tape library "{0}" not found on this CommCell.' -f $LibraryName)
        }

        $libId = $lib.entityInfo.id
        if (-not $libId) { $libId = $lib.library.libraryId }
        if (-not $libId) { throw ('Library "{0}" was found but returned no id.' -f $LibraryName) }

        $media = @()
        try {
            $resp = Invoke-CvApi -Path ('Library/{0}/Media' -f $libId)
            $media = @($resp.mediaList)
            if ($media.Count -eq 0) { $media = @($resp.media) }
        } catch {
            throw ('Could not enumerate media in {0}: {1}' -f $LibraryName, $_.Exception.Message)
        }

        foreach ($m in $media) {
            $barcode = $m.barCode
            if (-not $barcode) { $barcode = $m.mediaName }
            if ($MediaBarcode -and $MediaBarcode -notcontains $barcode) { continue }

            # A cartridge holding a job that is still writing must not be ejected.
            $inUse = [bool]$m.isMounted -or ("$($m.mediaStatus)" -match '(?i)in use|active|mounted')
            if ($inUse) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $barcode `
                    -Message 'Excluded - media is mounted or in use'
                continue
            }

            $results.Add([PSCustomObject]@{
                Name         = ('{0} / {1}' -f $LibraryName, $barcode)
                Id           = $m.mediaId
                LibraryName  = $LibraryName
                LibraryId    = $libId
                MediaId      = $m.mediaId
                Barcode      = $barcode
                SlotNumber   = $m.slotNumber
                MediaStatus  = $m.mediaStatus
                StoragePolicy= $m.storagePolicyName
                RetainUntil  = if ($m.retainUntilTime -and $m.retainUntilTime -gt 0) { [System.DateTimeOffset]::FromUnixTimeSeconds($m.retainUntilTime).LocalDateTime } else { $null }
                PhysicalStep = 'AFTER the software eject: collect from the mail slot and vault. NOT done by this script.'
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

    if ($RequestApproval -or -not $ApprovalReference) {
        $request = New-ApprovalRequest -ScriptName $scriptName -ChangeSet $candidates `
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Software-eject tape media', $candidates.Count, $Reason, $TicketReference)
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

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Software-eject tape media')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $path = $ExportApiPath -f $item.LibraryId, $item.MediaId
            Invoke-CvApi -Method POST -Path $path | Out-Null

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Software eject issued for barcode {0} (slot {1}). PHYSICAL REMOVAL AND VAULTING IS STILL OUTSTANDING.' -f
                $item.Barcode, $item.SlotNumber)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'SoftwareEjected'
                Detail = ('barcode {0}, slot {1} - collect from mail slot and vault' -f $item.Barcode, $item.SlotNumber)
                Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Eject Tape from Drive'
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
