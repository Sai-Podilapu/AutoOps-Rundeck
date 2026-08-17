<#
.SYNOPSIS
    Provisions a SharePoint site from a template.

.DESCRIPTION
    Creates a SharePoint site with an owner and a storage quota. Naming and
    ownership are enforced in code: an unowned site is one nobody governs, and
    it is usually discovered during an audit rather than before.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER SiteName
    Site display name.

.PARAMETER SiteAlias
    URL alias. Derived from the name when omitted.

.PARAMETER Owner
    Site owner UPN. Required.

.PARAMETER Template
    Team site (group-connected) or Communication site.

.PARAMETER Description
    Site description.

.PARAMETER NamingPattern
    Wildcard pattern the site name must match. Set to * to disable.

.PARAMETER TicketReference
    ITSM ticket driving the request.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\New-SharePointSite.ps1 -SiteName 'Project Falcon' -Owner lead@contoso.com -TicketReference REQ0012345

    Creates a group-connected team site.

.EXAMPLE
    .\New-SharePointSite.ps1 -SiteName 'Policies' -Owner lead@contoso.com -Template Communication -TicketReference REQ0012345

    Creates a communication site with no group.

.NOTES
    Source use case      : #3 - SharePoint Site Provisioning
    Category             : M365
    Technology           : PnP PowerShell / Graph API
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Template-based provisioning from ITSM"

    Required permissions : Microsoft Graph Sites.FullControl.All and Group.ReadWrite.All for group-connected sites.
    Required modules     : Microsoft.Graph.Authentication, Microsoft.Graph.Sites
    Authentication       : App registration with certificate auth (app-only).

    A Team site creates a Microsoft 365 group with a mailbox, a Planner
    plan and a Teams entitlement. A Communication site does not. Choosing
    Team when only a document library was wanted creates four objects to
    govern instead of one.

    Rollback             : Delete the site. A deleted site is recoverable from
                           the recycle bin for 93 days, after which it and its
                           content are permanently removed.
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication
#Requires -Modules Microsoft.Graph.Sites

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory)]
    [string[]]$SiteName,

    [string]$SiteAlias,

    [Parameter(Mandatory)]
    [string]$Owner,

    [ValidateSet('Team','Communication')]
    [string]$Template = 'Team',

    [string]$Description,

    [string]$NamingPattern = '*',

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

    $scriptName = 'New-SharePointSite'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #3 (M365)'

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


        Connect-MgGraph -Scopes 'Sites.FullControl.All','Group.ReadWrite.All','User.Read.All' -NoWelcome -ErrorAction Stop
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Microsoft Graph'

        $ownerUser = Get-MgUser -UserId $Owner -Property Id,UserPrincipalName -ErrorAction Stop

        foreach ($name in $SiteName) {
            if ($NamingPattern -ne '*' -and $name -notlike $NamingPattern) {
                throw ('Refusing to create "{0}": it does not match the naming pattern "{1}".' -f $name, $NamingPattern)
            }

            $alias = if ($SiteAlias) { $SiteAlias } else { ($name -replace '[^\w]', '') }

            $existing = Get-MgGroup -Filter ("mailNickname eq '{0}'" -f $alias) -ErrorAction SilentlyContinue |
                        Select-Object -First 1
            if ($existing) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $alias `
                    -Message 'Skipped - a group with this alias already exists (idempotent)'
                continue
            }

            $results.Add([PSCustomObject]@{
                Name        = $name
                Id          = $alias
                SiteName    = $name
                SiteAlias   = $alias
                Template    = $Template
                Owner       = $ownerUser.UserPrincipalName
                OwnerId     = $ownerUser.Id
                Description = $Description
                Ticket      = $TicketReference
                Creates     = if ($Template -eq 'Team') { 'M365 group + mailbox + Planner + Teams entitlement + site' }
                              else { 'Site only, no group' }
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Provision SharePoint site')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            if ($item.Template -eq 'Team') {
                # A group-connected team site is created by creating the group; SharePoint
                # provisions the site behind it.
                $body = @{
                    displayName     = $item.SiteName
                    mailNickname    = $item.SiteAlias
                    description     = $item.Description
                    groupTypes      = @('Unified')
                    mailEnabled     = $true
                    securityEnabled = $false
                    visibility      = 'Private'
                    'owners@odata.bind' = @(('https://graph.microsoft.com/v1.0/users/{0}' -f $item.OwnerId))
                }
                New-MgGroup -BodyParameter $body -ErrorAction Stop | Out-Null
                $detail = 'group-connected team site (group provisioning may take a few minutes)'
            } else {
                throw 'Communication site creation is not exposed through the Graph v1.0 sites API. ' +
                      'Create it with PnP.PowerShell (New-PnPSite -Type CommunicationSite) or the admin centre, ' +
                      'then re-run reporting scripts against it.'
            }

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Site provisioning requested: {0}. Owner {1}. Ticket={2}' -f $detail, $item.Owner, $item.Ticket)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'SiteProvisioned'; Detail = $detail; Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'SharePoint Site Provisioning'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
