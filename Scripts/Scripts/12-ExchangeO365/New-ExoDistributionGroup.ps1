<#
.SYNOPSIS
    Creates a distribution group with enforced naming and ownership.

.DESCRIPTION
    Creates a distribution group only if the name matches the configured
    convention and an owner is supplied. Additive and low risk, but the naming
    and ownership standards are enforced in code - an ownerless group is the
    one nobody maintains.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER GroupName
    Display name of the group to create.

.PARAMETER PrimarySmtpAddress
    Primary SMTP address. Derived from the name when omitted.

.PARAMETER ManagedBy
    Group owner(s). At least one is required.

.PARAMETER Members
    Initial members.

.PARAMETER NamingPattern
    Wildcard pattern the display name must match. Set to * to disable.

.PARAMETER RequireSenderAuthentication
    Reject mail from outside the organisation. On by default.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\New-ExoDistributionGroup.ps1 -GroupName 'DL-Finance' -ManagedBy owner@contoso.com -Members a@contoso.com,b@contoso.com

    Creates a compliant distribution group.

.EXAMPLE
    .\New-ExoDistributionGroup.ps1 -GroupName 'Finance' -ManagedBy owner@contoso.com -WhatIf

    Fails the naming check before doing anything.

.NOTES
    Source use case      : #18 - Email Group Creation
    Category             : Exchange & O365
    Technology           : Graph API
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Additive; naming standards in SOP"

    Required permissions : Exchange Online Recipient Management role.
    Required modules     : ExchangeOnlineManagement
    Authentication       : App-only certificate auth via
                           Connect-ExchangeOnline.

    RequireSenderAuthentication defaults to true, so the group does not
    accept external mail. Open distribution groups are a common spam and
    spoofing vector; turn it off only where external senders genuinely
    need to post.

    Rollback             : Remove-DistributionGroup. A newly created empty
                           group can be removed safely.
#>

#Requires -Version 5.1
#Requires -Modules ExchangeOnlineManagement

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory)]
    [string[]]$GroupName,

    [string]$PrimarySmtpAddress,

    [Parameter(Mandatory)]
    [string[]]$ManagedBy,

    [string[]]$Members,

    [string]$NamingPattern = 'DL-*',

    [bool]$RequireSenderAuthentication = $true,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'New-ExoDistributionGroup'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #18 (Exchange & O365)'

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
        Connect-AutomationPlatform -Platform 'ExchangeOnline' | Out-Null


        $exoParams = @{ ShowBanner = $false; ErrorAction = 'Stop' }
        if ($config -and $config.azure) {
            if ($config.azure.applicationId)         { $exoParams.AppId = $config.azure.applicationId }
            if ($config.azure.certificateThumbprint) { $exoParams.CertificateThumbprint = $config.azure.certificateThumbprint }
            if ($config.azure.tenantId)              { $exoParams.Organization = $config.azure.tenantId }
        }
        if (-not $exoParams.AppId) {
            throw 'Exchange Online requires app-only certificate auth. Set azure.applicationId, ' +
                  'azure.certificateThumbprint and azure.tenantId in config.json.'
        }
        Connect-ExchangeOnline @exoParams
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Exchange Online (app-only certificate auth)'

        foreach ($name in $GroupName) {
            if ($NamingPattern -ne '*' -and $name -notlike $NamingPattern) {
                throw ('Refusing to create "{0}": it does not match the naming pattern "{1}".' -f $name, $NamingPattern)
            }

            $smtp = if ($PrimarySmtpAddress) { $PrimarySmtpAddress }
                    else { '{0}@{1}' -f ($name -replace '[^\w-]', ''), (($ManagedBy[0] -split '@')[1]) }

            if (Get-DistributionGroup -Identity $name -ErrorAction SilentlyContinue) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $name `
                    -Message 'Skipped - group already exists (idempotent)'
                continue
            }

            # Verify owners exist before creating, so a typo does not leave an
            # ownerless group behind.
            foreach ($owner in $ManagedBy) {
                if (-not (Get-Recipient -Identity $owner -ErrorAction SilentlyContinue)) {
                    throw ('Owner {0} does not exist. Refusing to create an ownerless group.' -f $owner)
                }
            }

            $results.Add([PSCustomObject]@{
                Name         = $name
                Id           = $name
                GroupName    = $name
                PrimarySmtp  = $smtp
                ManagedBy    = ($ManagedBy -join '; ')
                MemberCount  = @($Members).Count
                Members      = ($Members -join '; ')
                RequireSenderAuth = $RequireSenderAuthentication
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Create distribution group')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            New-DistributionGroup -Name $item.GroupName -PrimarySmtpAddress $item.PrimarySmtp `
                -ManagedBy $ManagedBy -Type Distribution -ErrorAction Stop | Out-Null

            Set-DistributionGroup -Identity $item.GroupName `
                -RequireSenderAuthenticationEnabled $item.RequireSenderAuth -ErrorAction Stop

            $added = 0
            foreach ($m in $Members) {
                try {
                    Add-DistributionGroupMember -Identity $item.GroupName -Member $m -ErrorAction Stop
                    $added++
                } catch {
                    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label `
                        -Message ('Could not add member {0}: {1}' -f $m, $_.Exception.Message)
                }
            }

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Group created: {0}, {1} member(s) added, external senders {2}' -f
                $item.PrimarySmtp, $added, $(if ($item.RequireSenderAuth) { 'blocked' } else { 'ALLOWED' }))
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'GroupCreated'
                Detail = ('{0}; {1} members' -f $item.PrimarySmtp, $added); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Email Group Creation'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
