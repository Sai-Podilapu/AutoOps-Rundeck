<#
.SYNOPSIS
    Creates an Active Directory organisational unit with accidental-deletion
    protection.

.DESCRIPTION
    Creates an OU under a parent path, with protection from accidental
    deletion enabled by default. Additive and low risk, but the naming
    convention is enforced in code and the parent must already exist, so a
    typo cannot create an OU in an unexpected part of the tree.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER Server
    Domain controller to target. Uses the nearest DC when omitted.

.PARAMETER Credential
    Credential for the directory operation.

.PARAMETER OuName
    Name of the OU to create.

.PARAMETER ParentPath
    Distinguished name of the parent container.

.PARAMETER NamingPattern
    Wildcard pattern the OU name must match. Set to * to disable.

.PARAMETER ProtectFromDeletion
    Enable accidental-deletion protection. On by default.

.PARAMETER Description
    Description for the new OU.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\New-AdOrganizationalUnit.ps1 -OuName Contractors -ParentPath 'OU=Users,DC=contoso,DC=com'

    Creates a protected OU.

.EXAMPLE
    .\New-AdOrganizationalUnit.ps1 -OuName Contractors -ParentPath 'OU=Users,DC=contoso,DC=com' -WhatIf

    Shows what would be created.

.NOTES
    Source use case      : #12 - Create Organisation Unit
    Category             : AD & Identity
    Technology           : PowerShell
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Additive; naming standard in SOP"

    Required permissions : Delegated Create Organizational Unit Objects on the parent container.
    Required modules     : ActiveDirectory
    Authentication       : Delegated service account with the minimum required
                           AD rights.

    ProtectFromDeletion defaults to true. An OU deleted by accident takes
    every object beneath it, and recovering that means an authoritative
    restore - considerably more painful than clearing a checkbox when a
    deletion is genuinely intended.

    Rollback             : Remove-ADOrganizationalUnit. Deletion protection
                           must be cleared first, which is the point of
                           enabling it.
#>

#Requires -Version 5.1
#Requires -Modules ActiveDirectory

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$Server,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [Parameter(Mandatory)]
    [string[]]$OuName,

    [Parameter(Mandatory)]
    [string]$ParentPath,

    [string]$NamingPattern = '*',

    [bool]$ProtectFromDeletion = $true,

    [string]$Description,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'New-AdOrganizationalUnit'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #12 (AD & Identity)'

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
        Connect-AutomationPlatform -Platform 'ActiveDirectory' | Out-Null


        $adArgs = @{ ErrorAction = 'Stop' }
        if ($Server) { $adArgs.Server = $Server }
        if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $adArgs.Credential = $Credential }

        Import-Module ActiveDirectory -ErrorAction Stop

        try { Get-ADObject -Identity $ParentPath @adArgs | Out-Null }
        catch { throw ('Parent path does not exist: {0}' -f $ParentPath) }

        foreach ($name in $OuName) {
            if ($NamingPattern -ne '*' -and $name -notlike $NamingPattern) {
                throw ('Refusing to create "{0}": it does not match the naming pattern "{1}".' -f $name, $NamingPattern)
            }

            $dn = 'OU={0},{1}' -f $name, $ParentPath
            if (Get-ADOrganizationalUnit -Filter ("Name -eq '{0}'" -f $name) -SearchBase $ParentPath `
                    -SearchScope OneLevel @adArgs -ErrorAction SilentlyContinue) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $dn `
                    -Message 'Skipped - OU already exists (idempotent)'
                continue
            }

            $results.Add([PSCustomObject]@{
                Name             = $name
                Id               = $dn
                DistinguishedName= $dn
                ParentPath       = $ParentPath
                Description      = $Description
                ProtectFromDeletion = $ProtectFromDeletion
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Create organisational unit')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $newParams = @{
                Name = $item.Name
                Path = $item.ParentPath
                ProtectedFromAccidentalDeletion = $item.ProtectFromDeletion
            }
            if ($item.Description) { $newParams.Description = $item.Description }

            New-ADOrganizationalUnit @newParams @adArgs

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'OU created: {0}, deletion protection {1}' -f
                $item.DistinguishedName, $(if ($item.ProtectFromDeletion) { 'ENABLED' } else { 'disabled' }))
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'OuCreated'
                Detail = $item.DistinguishedName; Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Create Organisation Unit'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
