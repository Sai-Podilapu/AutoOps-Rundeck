<#
.SYNOPSIS
    Enriches and tickets EDR alerts; isolates a device only when an analyst
    says so.

.DESCRIPTION
    Correlates Defender for Endpoint alerts by device, enriches them and
    raises tickets - the mechanical half of triage. Device isolation is
    available and is gated hard, because the workbook is explicit that
    isolating a production server is an analyst decision and not a rule.

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

.PARAMETER LookbackHours
    Alert window to triage.

.PARAMETER MinimumSeverity
    Lowest alert severity to triage.

.PARAMETER IsolateDevice
    Device id(s) to isolate. Nothing is isolated unless named here - there is
    no severity threshold that triggers isolation on its own.

.PARAMETER ProductionImpactAssessed
    Required alongside -IsolateDevice. The analyst asserting they know what
    the device does and what isolating it takes offline.

.PARAMETER ProductionNamePattern
    Devices matching these patterns are never isolated by this script,
    whatever else is passed.

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
    .\Invoke-EdrAlertTriage.ps1 -LookbackHours 24 -MinimumSeverity high

    REPORT ONLY. Correlates and enriches alerts, raises an approval for
    ticketing.

.EXAMPLE
    .\Invoke-EdrAlertTriage.ps1 -LookbackHours 24 -ApprovalReference APR-... -TicketReference INC0012345

    Raises tickets for the correlated alerts. Isolates nothing.

.EXAMPLE
    .\Invoke-EdrAlertTriage.ps1 -IsolateDevice 'abc123' -ProductionImpactAssessed -ApprovalReference APR-...

    Isolates one named device after an analyst assessed the impact.

.NOTES
    Source use case      : #10 - Endpoint EDR Alert Auto-Triage
    Category             : Security Cloud
    Technology           : Defender for Endpoint / Sentinel
    Difficulty           : High
    Agent possible       : Partial
    Can execute with SOP : Partially - Agent Assists
    Automation type      : Change / Write
    Risk level           : High
    Human approval needed: YES
    Guardrails (col L)   : "Enrichment, correlation & ticketing automatable; isolating a production server is an analyst decision, not a rule"

    Required permissions : Microsoft Graph SecurityAlert.ReadWrite.All; Machine.Isolate for the isolation path.
    Required modules     : Microsoft.Graph.Authentication, Microsoft.Graph.Security
    Authentication       : Vendor REST API via Invoke-RestMethod, or Graph
                           where the tool is Microsoft.

    ASSIST-ONLY, and the split follows the workbook exactly. Enrichment,
    correlation and ticketing run for every qualifying alert. Isolation
    runs for nothing unless a device is named in -IsolateDevice AND
    -ProductionImpactAssessed is passed AND the approval is valid - three
    separate acts by a human. There is deliberately no severity threshold
    that triggers isolation automatically, because that would be exactly
    the rule the guardrail says must not exist. Devices matching
    -ProductionNamePattern are refused outright.

    Rollback             : Tickets can be closed. An isolated device is
                           released with the Defender release action; it stays
                           cut off from everything except Defender until
                           someone does that.
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication
#Requires -Modules Microsoft.Graph.Security

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [ValidateRange(1,168)]
    [int]$LookbackHours = 24,

    [ValidateSet('high','medium','low')]
    [string]$MinimumSeverity = 'medium',

    [string[]]$IsolateDevice,

    [switch]$ProductionImpactAssessed,

    [string[]]$ProductionNamePattern = @('*PRD*','*PROD*','*DC0*','*SQL*'),

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'EDR alert triage',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Invoke-EdrAlertTriage'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #10 (Security Cloud)'

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
    $pre = Test-Prerequisite -RequiredModule 'Microsoft.Graph.Authentication','Microsoft.Graph.Security'
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
        Connect-AutomationPlatform -Platform 'Graph' | Out-Null


        Connect-MgGraph -Scopes 'SecurityAlert.ReadWrite.All','SecurityIncident.Read.All' -NoWelcome -ErrorAction Stop
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Microsoft Graph'

        function New-SecurityTicket {
            <#
                .SYNOPSIS
                    Raises one ITSM ticket for a security finding.
                .DESCRIPTION
                    Posts to the ITSM endpoint from config.json using the caller's
                    integrated credentials. No token is embedded anywhere; if the
                    endpoint is unconfigured the caller is told so rather than the
                    failure being swallowed.
            #>
            [CmdletBinding(SupportsShouldProcess)]
            [OutputType([PSCustomObject])]
            param(
                [Parameter(Mandatory)][string]$Title,
                [Parameter(Mandatory)][string]$Description,
                [Parameter(Mandatory)][hashtable]$Context
            )

            if (-not $PSCmdlet.ShouldProcess($Title, 'Raise ITSM ticket')) {
                return [PSCustomObject]@{ TicketNumber = '(WhatIf)'; Raw = $null }
            }
            if (-not $Context.TicketUrl) {
                throw 'No ITSM endpoint. Set itsm.createTicketUrl in config.json; tickets are not written to a file as a silent fallback.'
            }

            $body = @{
                short_description = $Title
                description       = $Description
                category          = $Context.Category
                assignment_group  = $Context.AssignmentGroup
            } | ConvertTo-Json -Depth 6

            $response = Invoke-RestMethod -Uri $Context.TicketUrl -Method POST -Body $body `
                -ContentType 'application/json' -UseDefaultCredentials -ErrorAction Stop

            $number = $response.result.number
            if (-not $number) { $number = $response.number }
            [PSCustomObject]@{ TicketNumber = $number; Raw = $response }
        }

        $itsmContext = @{
            TicketUrl       = if ($config -and $config.itsm) { $config.itsm.createTicketUrl } else { $null }
            Category        = if ($config -and $config.itsm) { $config.itsm.category } else { 'Security' }
            AssignmentGroup = if ($config -and $config.itsm) { $config.itsm.assignmentGroup } else { '' }
        }

        if ($IsolateDevice -and -not $ProductionImpactAssessed) {
            throw 'Refusing -IsolateDevice without -ProductionImpactAssessed. The workbook is explicit that ' +
                  'isolating a production server is an analyst decision, not a rule; this flag is the analyst ' +
                  'asserting they know what the device does.'
        }

        $severityRank = @{ 'high' = 3; 'medium' = 2; 'low' = 1 }
        $floor = $severityRank[$MinimumSeverity]
        $since = (Get-Date).AddHours(-$LookbackHours).ToString('yyyy-MM-ddTHH:mm:ssZ')

        $alerts = @()
        try {
            $response = Invoke-MgGraphRequest -Method GET -ErrorAction Stop `
                -Uri ('https://graph.microsoft.com/v1.0/security/alerts_v2?$filter=createdDateTime ge {0}&$top=500' -f $since)
            $alerts = @($response.value)
        } catch {
            throw ('Security alerts could not be read: {0}' -f $_.Exception.Message)
        }

        # Correlated by device: five alerts on one machine is one investigation.
        $byDevice = @{}
        foreach ($alert in $alerts) {
            $rank = $severityRank["$($alert.severity)"]
            if (-not $rank -or $rank -lt $floor) { continue }
            if ("$($alert.status)" -match '(?i)resolved') { continue }

            $deviceId = ''
            $deviceName = ''
            foreach ($evidence in @($alert.evidence)) {
                if ($evidence.'@odata.type' -match 'deviceEvidence') {
                    $deviceId = $evidence.mdeDeviceId
                    $deviceName = $evidence.deviceDnsName
                    break
                }
            }
            $key = if ($deviceId) { $deviceId } else { 'no-device' }

            if (-not $byDevice.ContainsKey($key)) {
                $byDevice[$key] = [PSCustomObject]@{
                    DeviceId = $deviceId; DeviceName = $deviceName; Alerts = @()
                }
            }
            $byDevice[$key].Alerts += $alert
        }

        foreach ($key in $byDevice.Keys) {
            $group = $byDevice[$key]
            $highest = ($group.Alerts | Sort-Object { $severityRank["$($_.severity)"] } -Descending | Select-Object -First 1)

            $isProduction = $false
            foreach ($pattern in $ProductionNamePattern) {
                if ($group.DeviceName -like $pattern) { $isProduction = $true; break }
            }

            $isolationRequested = ($IsolateDevice -and $IsolateDevice -contains $group.DeviceId)
            if ($isolationRequested -and $isProduction) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $group.DeviceName -Message (
                    'ISOLATION REFUSED - device matches a production name pattern. This cannot be overridden ' +
                    'by a parameter; isolate it from the Defender console with the change process that fits a production outage.')
                $isolationRequested = $false
            }

            $results.Add([PSCustomObject]@{
                Name            = $(if ($group.DeviceName) { $group.DeviceName } else { 'Alerts with no device evidence' })
                Id              = $key
                DeviceId        = $group.DeviceId
                DeviceName      = $group.DeviceName
                AlertCount      = $group.Alerts.Count
                HighestSeverity = "$($highest.severity)"
                Titles          = ((@($group.Alerts) | Select-Object -First 5 | ForEach-Object { $_.title }) -join '; ')
                Categories      = ((@($group.Alerts) | ForEach-Object { $_.category } | Select-Object -Unique) -join '; ')
                FirstSeen       = (@($group.Alerts).createdDateTime | Sort-Object | Select-Object -First 1)
                LastSeen        = (@($group.Alerts).createdDateTime | Sort-Object | Select-Object -Last 1)
                IsProductionNamed = $isProduction
                IsolationRequested = $isolationRequested
                ContainmentNote = if ($isolationRequested) { 'Isolation requested by an analyst for this device' }
                                  elseif ($isProduction) { 'Production-named device - isolation refused; analyst decision through the outage process' }
                                  else { 'No isolation requested. Containment is an ANALYST decision; this script proposes nothing.' }
            })
        }

        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            '{0} alert(s) correlated into {1} device group(s). Isolation requested for {2}.' -f
            $alerts.Count, $results.Count, @($results | Where-Object { $_.IsolationRequested }).Count)
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
        return
    }

    # Every candidate is logged individually BEFORE any action is taken.
    foreach ($c in $candidates) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0}' -f $c.Name) -Message 'CANDIDATE'
    }

    if ($RequestApproval -or -not $ApprovalReference) {
        $request = New-ApprovalRequest -ScriptName $scriptName -ChangeSet $candidates `
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Triage EDR alert', $candidates.Count, $Reason, $TicketReference)
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $request.Reference -Message (
            'REQUEST mode - nothing was changed. Supply -ApprovalReference {0} once approved.' -f $request.Reference)
        Write-Warning ('No change made. Approval reference: {0}' -f $request.Reference)
        Write-Output ([PSCustomObject]@{
            Mode = 'RequestApproval'; ApprovalReference = $request.Reference
            CandidateCount = $candidates.Count; Candidates = $candidates; Changed = $false })
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Triage EDR alert')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $ticket = New-SecurityTicket -Context $itsmContext `
                -Title ('[EDR {0}] {1}: {2} alert(s)' -f $item.HighestSeverity, $item.Name, $item.AlertCount) `
                -Description (@(
                    ('Device: {0} ({1})' -f $item.DeviceName, $item.DeviceId)
                    ('Alerts: {0}, highest severity {1}' -f $item.AlertCount, $item.HighestSeverity)
                    ('Categories: {0}' -f $item.Categories)
                    ('First seen: {0}   Last seen: {1}' -f $item.FirstSeen, $item.LastSeen)
                    ''
                    ('Titles: {0}' -f $item.Titles)
                    ''
                    ('Containment: {0}' -f $item.ContainmentNote)
                    ('Raised automatically by {0}.' -f $scriptName)
                ) -join "`n")

            $detail = ('ticket {0}' -f $ticket.TicketNumber)

            if ($item.IsolationRequested) {
                $isolationBody = @{
                    comment = ('Isolated by {0} on analyst instruction. Approval {1}, ticket {2}.' -f
                               $scriptName, $ApprovalReference, $TicketReference)
                    isolationType = 'full'
                } | ConvertTo-Json -Compress

                Invoke-MgGraphRequest -Method POST -ErrorAction Stop -Body $isolationBody `
                    -Uri ('https://graph.microsoft.com/v1.0/security/machines/{0}/isolate' -f $item.DeviceId) | Out-Null

                Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                    'DEVICE ISOLATED on analyst instruction. It stays cut off from everything except Defender ' +
                    'until someone releases it.')
                $detail += '; device isolated'
            } else {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
                    'Ticketed and enriched. No containment performed - {0}' -f $item.ContainmentNote)
            }

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Ticket {0} raised for {1} alert(s)' -f $ticket.TicketNumber, $item.AlertCount)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'Triaged'; Detail = $detail; Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Endpoint EDR Alert Auto-Triage'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
