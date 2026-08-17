<#
.SYNOPSIS
    Raises ITSM tickets for high-severity Defender for Cloud alerts.

.DESCRIPTION
    Reads active Defender for Cloud alerts and raises one ITSM ticket per
    high-severity alert. Ticketing is the safe half of triage, which is why
    this row is not gated - but it is only safe if it is idempotent, so alerts
    already ticketed are recorded and skipped.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER SubscriptionId
    Azure subscription to operate in. The current context when omitted.

.PARAMETER MinimumSeverity
    Lowest alert severity to ticket.

.PARAMETER LookbackHours
    Only consider alerts detected within this window.

.PARAMETER StateFile
    Path recording alerts already ticketed, so a re-run does not duplicate
    them.

.PARAMETER MaxTickets
    Ceiling on tickets raised in one run.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\New-DefenderAlertTicket.ps1 -MinimumSeverity High -LookbackHours 24

    Ticket high-severity alerts from the last day.

.EXAMPLE
    .\New-DefenderAlertTicket.ps1 -MinimumSeverity Medium -MaxTickets 20 -WhatIf

    Shows what would be raised.

.NOTES
    Source use case      : #1 - Azure Defender for Cloud Alert Triage
    Category             : Security Cloud
    Technology           : Defender API / Logic Apps
    Difficulty           : Medium
    Agent possible       : Partial
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Auto-create ITSM tickets for HIGH alerts; ticketing is safe"

    Required permissions : Security Reader on the subscription, plus write access to the ITSM endpoint.
    Required modules     : Az.Accounts, Az.Security
    Authentication       : Vendor REST API via Invoke-RestMethod, or Graph
                           where the tool is Microsoft.

    The dangerous failure here is not a wrong ticket, it is a thousand
    right ones. An alert storm without the state file would raise a ticket
    per alert per run, so the ticketed set is persisted and -MaxTickets
    caps a single run; hitting the cap is logged with the count that was
    left, rather than silently truncating.

    Rollback             : Close the ticket. No security control or resource is
                           modified by this script.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.Security

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [ValidateSet('High','Medium','Low')]
    [string]$MinimumSeverity = 'High',

    [ValidateRange(1,720)]
    [int]$LookbackHours = 24,

    [string]$StateFile,

    [ValidateRange(1,500)]
    [int]$MaxTickets = 50,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'New-DefenderAlertTicket'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #1 (Security Cloud)'

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
        Connect-AutomationPlatform -Platform 'Graph' | Out-Null


        $azContext = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $azContext) {
            throw 'No Azure context. Run Connect-AzAccount, or use a managed identity, before this script.'
        }
        if ($SubscriptionId -and $azContext.Subscription.Id -ne $SubscriptionId) {
            $azContext = Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop
        }
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Azure context: subscription {0}' -f $azContext.Subscription.Id)

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

        function Get-SecurityState {
            <#
                .SYNOPSIS
                    Reads the set of item ids this script has already acted on.
            #>
            [CmdletBinding()]
            [OutputType([hashtable])]
            param([Parameter(Mandatory)][string]$Path)

            $state = @{}
            if (Test-Path -LiteralPath $Path) {
                try {
                    $loaded = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
                    foreach ($p in $loaded.PSObject.Properties) { $state[$p.Name] = $p.Value }
                } catch {
                    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                        'State file unreadable ({0}); treating every item as new. Expect duplicates this run.' -f $_.Exception.Message)
                }
            }
            return $state
        }

        function Save-SecurityState {
            <#
                .SYNOPSIS
                    Persists the acted-on set so a re-run does not duplicate work.
            #>
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)][string]$Path,
                [Parameter(Mandatory)][hashtable]$State
            )

            $dir = Split-Path -Parent $Path
            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                New-Item -Path $dir -ItemType Directory -Force | Out-Null
            }
            $State | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding UTF8
        }

        if (-not $StateFile) {
            $StateFile = Join-Path $env:ProgramData 'ITAutomation\State\defender-alert-tickets.json'
        }
        $ticketed = Get-SecurityState -Path $StateFile

        $severityRank = @{ 'High' = 3; 'Medium' = 2; 'Low' = 1 }
        $floor = $severityRank[$MinimumSeverity]
        $cutoff = (Get-Date).AddHours(-$LookbackHours)

        $alerts = @(Get-AzSecurityAlert -ErrorAction Stop)
        $skippedExisting = 0

        foreach ($alert in $alerts) {
            if ("$($alert.Status)" -match '(?i)dismissed|resolved') { continue }

            $rank = $severityRank["$($alert.AlertSeverity)"]
            if (-not $rank -or $rank -lt $floor) { continue }

            $detected = $alert.TimeGeneratedUtc
            if (-not $detected) { $detected = $alert.StartTimeUtc }
            if ($detected -and ([datetime]$detected) -lt $cutoff) { continue }

            $key = "$($alert.SystemAlertId)"
            if (-not $key) { $key = "$($alert.Name)" }
            if ($ticketed.ContainsKey($key)) {
                $skippedExisting++
                continue
            }

            if ($results.Count -ge $MaxTickets) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                    'Reached -MaxTickets ({0}). Further eligible alerts were NOT ticketed this run.' -f $MaxTickets)
                break
            }

            $results.Add([PSCustomObject]@{
                Name            = $alert.AlertDisplayName
                Id              = $key
                AlertId         = $key
                Severity        = "$($alert.AlertSeverity)"
                Status          = "$($alert.Status)"
                DetectedAt      = $detected
                ResourceId      = $alert.CompromisedEntity
                Description     = $alert.Description
                RemediationSteps= (@($alert.RemediationSteps) -join ' ')
                Intent          = $alert.Intent
                StateFile       = $StateFile
            })
        }

        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            '{0} alert(s) eligible for ticketing; {1} already ticketed on a previous run and skipped.' -f
            $results.Count, $skippedExisting)
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

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Raise ticket for alert')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $ticket = New-SecurityTicket -Context $itsmContext `
                -Title ('[{0}] Defender for Cloud: {1}' -f $item.Severity, $item.Name) `
                -Description (@(
                    ('Alert: {0}' -f $item.Name)
                    ('Severity: {0}' -f $item.Severity)
                    ('Detected: {0}' -f $item.DetectedAt)
                    ('Affected resource: {0}' -f $item.ResourceId)
                    ''
                    $item.Description
                    ''
                    ('Remediation guidance from Defender: {0}' -f $item.RemediationSteps)
                    ('Raised automatically by {0}. Alert id {1}.' -f $scriptName, $item.AlertId)
                ) -join "`n")

            # Recorded immediately, so a failure later in the batch cannot cause this
            # alert to be ticketed twice on the next run.
            $ticketed[$item.AlertId] = @{ Ticket = $ticket.TicketNumber; At = (Get-Date).ToUniversalTime().ToString('o') }
            Save-SecurityState -Path $item.StateFile -State $ticketed

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Ticket {0} raised for {1} alert' -f $ticket.TicketNumber, $item.Severity)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'TicketRaised'; Detail = $ticket.TicketNumber; Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Azure Defender for Cloud Alert Triage'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
