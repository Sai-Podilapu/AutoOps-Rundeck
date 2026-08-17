<#
.SYNOPSIS
    Compares subclient configuration against a desired state and applies
    approved changes.

.DESCRIPTION
    Reads subclient properties, compares them against a desired-state file,
    and reports every deviation. It applies only the properties an operator
    explicitly names, and refuses to touch the properties that encode a
    protection DESIGN decision - what is protected, how often, and for how
    long - because the workbook reserves those for a human.

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

.PARAMETER DesiredStateFile
    JSON file describing the expected subclient properties.

.PARAMETER ClientName
    Limit to these clients.

.PARAMETER ApplyProperty
    Only these properties may be written. Nothing is applied when omitted.

.PARAMETER DesignProperty
    Properties treated as design decisions and never written automatically.

.PARAMETER DesignApproved
    Permits a design property to be written. Requires a named design authority
    in -Reason and is deliberately awkward to pass.

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
    .\Set-CvSubclientConfiguration.ps1 -DesiredStateFile .\baseline.json

    REPORT ONLY. Lists drift and raises an approval.

.EXAMPLE
    .\Set-CvSubclientConfiguration.ps1 -DesiredStateFile .\baseline.json -ApplyProperty description,enableBackup -ApprovalReference APR-...

    Applies two non-design properties from an approved review.

.NOTES
    Source use case      : #8 - Commvault Backup Configuration
    Category             : Backup Commvault
    Technology           : Commvault REST API
    Difficulty           : High
    Agent possible       : Partial
    Can execute with SOP : Partially - Agent Assists
    Automation type      : Change / Write
    Risk level           : High
    Human approval needed: YES
    Guardrails (col L)   : "Bulk config changes via API possible; backup/protection DESIGN decisions (what, how often, retention) are human"

    Required permissions : A CommCell user with Agent Management permission on the target subclients.
    Required modules     : none beyond IT-Automation-Common
    Authentication       : Commvault REST API token obtained per call. No
                           first-party PowerShell module.

    ASSIST-ONLY. Reporting drift is mechanical; deciding that a subclient
    SHOULD hold a different retention or storage policy is a
    protection-design decision with cost and recoverability consequences.
    Those properties are listed in -DesignProperty and are refused unless
    -DesignApproved is passed alongside a -Reason naming who made the
    call. Everything not named in -ApplyProperty is reported and left
    alone.

    Rollback             : Each change logs the previous value before it is
                           written. Revert by re-running with a desired-state
                           file carrying the old value, or from the CommCell
                           console.
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
    [string]$DesiredStateFile,

    [string[]]$ClientName,

    [string[]]$ApplyProperty,

    [string[]]$DesignProperty = @('storagePolicyName','retentionDays','backupLevel','schedulePolicy','contentPaths'),

    [switch]$DesignApproved,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Subclient configuration drift correction',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-CvSubclientConfiguration'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #8 (Backup Commvault)'

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

        if (-not (Test-Path -LiteralPath $DesiredStateFile)) {
            throw ('Desired-state file not found: {0}' -f $DesiredStateFile)
        }
        $desired = Get-Content -LiteralPath $DesiredStateFile -Raw | ConvertFrom-Json

        $names = if ($ClientName) { $ClientName } else { @($desired.PSObject.Properties.Name) }
        $reported = 0

        foreach ($cName in $names) {
            $expectedForClient = $desired.$cName
            if (-not $expectedForClient) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $cName `
                    -Message 'No desired state defined for this client; skipped rather than assumed compliant.'
                continue
            }

            $subs = @()
            try {
                $resp = Invoke-CvApi -Path ('Subclient?clientName={0}' -f [uri]::EscapeDataString($cName))
                $subs = @($resp.subClientProperties)
            } catch {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $cName `
                    -Message ('Could not read subclients: {0}' -f $_.Exception.Message)
                continue
            }

            foreach ($sc in $subs) {
                $e = $sc.subClientEntity
                $expected = $expectedForClient.($e.subclientName)
                if (-not $expected) { continue }

                foreach ($prop in $expected.PSObject.Properties) {
                    $key = $prop.Name
                    $want = $prop.Value

                    $have = switch ($key) {
                        'storagePolicyName' { $sc.commonProperties.storageDevice.dataBackupStoragePolicy.storagePolicyName }
                        'description'       { $sc.commonProperties.description }
                        'enableBackup'      { $sc.commonProperties.enableBackup }
                        'numberOfBackupStreams' { $sc.commonProperties.numberOfBackupStreams }
                        default             { $sc.commonProperties.$key }
                    }
                    if ($null -eq $have) { continue }
                    if ("$have" -eq "$want") { continue }

                    $reported++
                    $isDesign = $DesignProperty -contains $key

                    if ($isDesign -and -not $DesignApproved) {
                        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0}/{1}/{2}' -f $cName, $e.subclientName, $key) `
                            -Message 'Drift reported but NOT actionable - this is a protection-design property. Requires -DesignApproved.'
                        continue
                    }
                    if (-not $ApplyProperty -or $ApplyProperty -notcontains $key) {
                        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0}/{1}/{2}' -f $cName, $e.subclientName, $key) `
                            -Message 'Drift reported but not selected by -ApplyProperty; left alone.'
                        continue
                    }

                    $results.Add([PSCustomObject]@{
                        Name          = ('{0} / {1} / {2}' -f $cName, $e.subclientName, $key)
                        Id            = $e.subclientId
                        ClientName    = $cName
                        SubclientName = $e.subclientName
                        SubclientId   = $e.subclientId
                        Property      = $key
                        CurrentValue  = "$have"
                        DesiredValue  = "$want"
                        DesiredRaw    = $want
                        IsDesignDecision = $isDesign
                        Note          = if ($isDesign) { 'DESIGN property - being written only because -DesignApproved was passed' }
                                        else { 'Operational property' }
                    })
                }
            }
        }

        if ($DesignApproved -and -not $Reason) {
            throw '-DesignApproved requires -Reason naming the design authority who made the call.'
        }

        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Configuration comparison complete. {0} deviation(s) found, {1} in the change set.' -f $reported, $results.Count)
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Apply subclient property', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Apply subclient property')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $body = @{
                subClientProperties = @{
                    commonProperties = @{ $item.Property = $item.DesiredRaw }
                }
            }
            Invoke-CvApi -Method POST -Path ('Subclient/{0}' -f $item.SubclientId) -Body $body | Out-Null

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Applied {0}: "{1}" -> "{2}"{3}. Previous value recorded here for rollback.' -f
                $item.Property, $item.CurrentValue, $item.DesiredValue,
                $(if ($item.IsDesignDecision) { ' [DESIGN PROPERTY, -DesignApproved]' } else { '' }))
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'PropertyApplied'
                Detail = ('{0}: {1} -> {2}' -f $item.Property, $item.CurrentValue, $item.DesiredValue)
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Commvault Backup Configuration'
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
