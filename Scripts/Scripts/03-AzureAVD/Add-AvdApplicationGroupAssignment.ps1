<#
.SYNOPSIS
    Assigns users or groups to an AVD application group.

.DESCRIPTION
    Grants the Desktop Virtualization User role on an application group, which
    is what makes a RemoteApp or desktop appear in someone's feed.
    Ticket-driven: the workbook says the ticket is the approval, so the ticket
    reference is required.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER SubscriptionId
    Azure subscription. The current context when omitted.

.PARAMETER ResourceGroupName
    Resource group holding the application group.

.PARAMETER ApplicationGroupName
    Application group to grant access to.

.PARAMETER PrincipalUpn
    User principal name(s) to assign.

.PARAMETER PrincipalGroupName
    Entra group display name(s) to assign.

.PARAMETER TicketReference
    ITSM ticket driving the request. Required - on this use case the ticket IS
    the approval.

.PARAMETER RoleName
    Role to assign.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Add-AvdApplicationGroupAssignment.ps1 -ResourceGroupName rg-avd -ApplicationGroupName ag-finance -PrincipalGroupName 'AVD-Finance-Users' -TicketReference REQ0012345

    Grants a group access to a RemoteApp group.

.EXAMPLE
    .\Add-AvdApplicationGroupAssignment.ps1 -ResourceGroupName rg-avd -ApplicationGroupName ag-finance -PrincipalUpn user@contoso.com -TicketReference REQ0012345 -WhatIf

    Shows the assignment that would be created.

.NOTES
    Source use case      : #6 - AVD Application Group Assignment
    Category             : Azure AVD
    Technology           : Graph API / Az PowerShell
    Difficulty           : Low
    Agent possible       : Partial
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "ITSM-driven RemoteApp group assignment; ticket is the approval"

    Required permissions : User Access Administrator or Owner on the application group, to create role assignments.
    Required modules     : Az.Accounts, Az.DesktopVirtualization, Az.Resources
    Authentication       : Inherits the Az context; managed identity preferred.

    This row is not approval-gated because the workbook says the ticket is
    the approval, so -TicketReference is mandatory rather than optional as
    it is elsewhere in the library. Assigning a group rather than
    individual users is almost always the better answer - it moves the
    access decision to group membership, where it can be reviewed by the
    Access Review campaigns in the Security Cloud category.

    Rollback             : Remove the role assignment with
                           Remove-AzRoleAssignment. The application disappears
                           from the user's feed at their next refresh.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.DesktopVirtualization
#Requires -Modules Az.Resources

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$ApplicationGroupName,

    [string[]]$PrincipalUpn,

    [string[]]$PrincipalGroupName,

    [Parameter(Mandatory)]
    [string]$TicketReference,

    [string]$RoleName = 'Desktop Virtualization User',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Add-AvdApplicationGroupAssignment'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #6 (Azure AVD)'

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
        Connect-AutomationPlatform -Platform 'AzureAVD' | Out-Null


        $azContext = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $azContext) {
            throw 'No Azure context. Run Connect-AzAccount, or use a managed identity, before this script.'
        }
        if ($SubscriptionId -and $azContext.Subscription.Id -ne $SubscriptionId) {
            $azContext = Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop
        }

        if (-not $PrincipalUpn -and -not $PrincipalGroupName) {
            throw 'Supply -PrincipalUpn or -PrincipalGroupName.'
        }

        $appGroup = Get-AzWvdApplicationGroup -ResourceGroupName $ResourceGroupName `
            -Name $ApplicationGroupName -ErrorAction Stop
        if (-not $appGroup) {
            throw ('Application group "{0}" not found in "{1}".' -f $ApplicationGroupName, $ResourceGroupName)
        }

        $existing = @(Get-AzRoleAssignment -Scope $appGroup.Id -ErrorAction SilentlyContinue)

        foreach ($upn in @($PrincipalUpn)) {
            $principal = Get-AzADUser -UserPrincipalName $upn -ErrorAction SilentlyContinue
            if (-not $principal) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $upn -Message 'User not found; skipped.'
                continue
            }
            if ($existing | Where-Object { $_.ObjectId -eq $principal.Id -and $_.RoleDefinitionName -eq $RoleName }) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $upn `
                    -Message 'Skipped - already assigned (idempotent)'
                continue
            }

            $results.Add([PSCustomObject]@{
                Name          = ('{0} -> {1}' -f $upn, $ApplicationGroupName)
                Id            = $principal.Id
                PrincipalId   = $principal.Id
                PrincipalName = $upn
                PrincipalType = 'User'
                ApplicationGroup = $ApplicationGroupName
                ApplicationGroupType = $appGroup.ApplicationGroupType
                Scope         = $appGroup.Id
                RoleName      = $RoleName
                Ticket        = $TicketReference
                Advice        = 'Assigning an Entra group instead moves this decision to group membership, where an access review can see it'
            })
        }

        foreach ($groupName in @($PrincipalGroupName)) {
            $principal = Get-AzADGroup -DisplayName $groupName -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $principal) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $groupName -Message 'Group not found; skipped.'
                continue
            }
            if ($existing | Where-Object { $_.ObjectId -eq $principal.Id -and $_.RoleDefinitionName -eq $RoleName }) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $groupName `
                    -Message 'Skipped - already assigned (idempotent)'
                continue
            }

            $results.Add([PSCustomObject]@{
                Name          = ('{0} -> {1}' -f $groupName, $ApplicationGroupName)
                Id            = $principal.Id
                PrincipalId   = $principal.Id
                PrincipalName = $groupName
                PrincipalType = 'Group'
                ApplicationGroup = $ApplicationGroupName
                ApplicationGroupType = $appGroup.ApplicationGroupType
                Scope         = $appGroup.Id
                RoleName      = $RoleName
                Ticket        = $TicketReference
                Advice        = ''
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Assign application group access')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            New-AzRoleAssignment -ObjectId $item.PrincipalId -RoleDefinitionName $item.RoleName `
                -Scope $item.Scope -ErrorAction Stop | Out-Null

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                '{0} "{1}" granted {2} on {3} ({4}). Ticket {5}.' -f
                $item.PrincipalType, $item.PrincipalName, $item.RoleName,
                $item.ApplicationGroup, $item.ApplicationGroupType, $item.Ticket)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'AccessGranted'
                Detail = ('{0} on {1}' -f $item.RoleName, $item.ApplicationGroup); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AVD Application Group Assignment'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
