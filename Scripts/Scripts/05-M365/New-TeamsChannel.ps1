<#
.SYNOPSIS
    Creates a Teams channel in an existing team from an ITSM request.

.DESCRIPTION
    Creates a standard or private channel. The ticket is the approval for this
    row, so the script requires a ticket reference and records it, but does
    not raise a separate approval artifact.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER TeamName
    Display name or id of the team to create the channel in.

.PARAMETER ChannelName
    Channel display name.

.PARAMETER ChannelType
    Standard is visible to all team members; Private is restricted to its own
    members.

.PARAMETER Description
    Channel description.

.PARAMETER Owner
    Owner UPN. Required for a private channel.

.PARAMETER TicketReference
    ITSM ticket driving the request. Recorded in the audit trail.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\New-TeamsChannel.ps1 -TeamName 'Finance' -ChannelName 'Budget-2027' -TicketReference REQ0012345

    Creates a standard channel.

.EXAMPLE
    .\New-TeamsChannel.ps1 -TeamName 'Finance' -ChannelName 'Audit' -ChannelType Private -Owner lead@contoso.com -TicketReference REQ0012345

    Creates a private channel with an owner.

.NOTES
    Source use case      : #1 - Teams Channel Auto-Provisioning
    Category             : M365
    Technology           : Graph API / PowerShell
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "ITSM-driven creation; ticket is the approval"

    Required permissions : Microsoft Graph Channel.Create and Group.Read.All.
    Required modules     : Microsoft.Graph.Authentication, Microsoft.Graph.Teams
    Authentication       : App registration with certificate auth (app-only).

    A private channel gets its own SharePoint site collection and does not
    inherit the team\u2019s permissions. That isolation is the point, but
    it also means the team owners cannot see its content - choose Standard
    unless isolation is genuinely required.

    Rollback             : Remove the channel. A deleted channel is recoverable
                           for 30 days, but its files live in the SharePoint
                           site and are removed with it.
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication
#Requires -Modules Microsoft.Graph.Teams

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory)]
    [string]$TeamName,

    [Parameter(Mandatory)]
    [string[]]$ChannelName,

    [ValidateSet('Standard','Private')]
    [string]$ChannelType = 'Standard',

    [string]$Description,

    [string]$Owner,

    [Parameter(Mandatory)]
    [string]$TicketReference,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'New-TeamsChannel'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #1 (M365)'

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


        Connect-MgGraph -Scopes 'Group.Read.All','Channel.ReadBasic.All','ChannelSettings.ReadWrite.All' -NoWelcome -ErrorAction Stop
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Microsoft Graph'

        $team = Get-MgGroup -Filter ("displayName eq '{0}'" -f ($TeamName -replace "'", "''")) -ErrorAction SilentlyContinue |
                Where-Object { $_.ResourceProvisioningOptions -contains 'Team' } | Select-Object -First 1
        if (-not $team) { $team = Get-MgGroup -GroupId $TeamName -ErrorAction SilentlyContinue }
        if (-not $team) { throw ('Team "{0}" not found, or the group is not Teams-enabled.' -f $TeamName) }

        if ($ChannelType -eq 'Private' -and -not $Owner) {
            throw 'A private channel requires -Owner. Graph will not create one without an initial owner.'
        }

        $existing = @(Get-MgTeamChannel -TeamId $team.Id -ErrorAction SilentlyContinue)

        foreach ($name in $ChannelName) {
            if ($existing.DisplayName -contains $name) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $name `
                    -Message 'Skipped - channel already exists (idempotent)'
                continue
            }
            $results.Add([PSCustomObject]@{
                Name        = ('{0} / {1}' -f $team.DisplayName, $name)
                Id          = $team.Id
                TeamName    = $team.DisplayName
                TeamId      = $team.Id
                ChannelName = $name
                ChannelType = $ChannelType
                Description = $Description
                Owner       = $Owner
                Ticket      = $TicketReference
                Isolation   = if ($ChannelType -eq 'Private') { 'Private - own SharePoint site, invisible to team owners' }
                              else { 'Standard - visible to all team members' }
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
        return
    }

    # Every candidate is logged individually BEFORE any action is taken.
    foreach ($c in $candidates) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0}' -f $c.Name) -Message 'CANDIDATE'
    }

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Create Teams channel')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $body = @{
                displayName = $item.ChannelName
                description = $item.Description
                membershipType = $item.ChannelType.ToLower()
            }
            if ($item.ChannelType -eq 'Private') {
                $body.members = @(@{
                    '@odata.type' = '#microsoft.graph.aadUserConversationMember'
                    'user@odata.bind' = ('https://graph.microsoft.com/v1.0/users(''{0}'')' -f $item.Owner)
                    roles = @('owner')
                })
            }

            New-MgTeamChannel -TeamId $item.TeamId -BodyParameter $body -ErrorAction Stop | Out-Null

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                '{0} channel created in {1}. Ticket={2}. {3}' -f
                $item.ChannelType, $item.TeamName, $item.Ticket, $item.Isolation)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'ChannelCreated'; Detail = $item.ChannelType; Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Teams Channel Auto-Provisioning'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
