<#
.SYNOPSIS
    Sets or clears the expiry date on an Active Directory account.

.DESCRIPTION
    Applies an account expiry date, typically for a contractor or a temporary
    account. Low risk and fully reversible, so it executes directly - but the
    script refuses a date in the past, which would disable the account
    immediately and usually is not what was meant.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER Server
    Domain controller to target. Uses the nearest DC when omitted.

.PARAMETER Credential
    Credential for the directory operation.

.PARAMETER Identity
    Account(s) to set expiry on.

.PARAMETER ExpiryDate
    Date the account expires. Omit with -ClearExpiry to remove it.

.PARAMETER ClearExpiry
    Remove the expiry date so the account never expires.

.PARAMETER AllowPastDate
    Permit a date in the past, which disables the account immediately.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Set-AdAccountExpiry.ps1 -Identity contractor1 -ExpiryDate '2026-12-31'

    Sets an expiry date.

.EXAMPLE
    .\Set-AdAccountExpiry.ps1 -Identity contractor1 -ClearExpiry

    Removes the expiry so the account no longer expires.

.NOTES
    Source use case      : #9 - Set Account Expiry
    Category             : AD & Identity
    Technology           : PowerShell
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Low-risk, reversible attribute"

    Required permissions : Delegated write on accountExpires for the target OU.
    Required modules     : ActiveDirectory
    Authentication       : Delegated service account with the minimum required
                           AD rights.

    AD stores expiry as end-of-day. An account set to expire on the 31st
    remains usable through that day and is disabled at midnight.

    Rollback             : Re-run with the previous date, or -ClearExpiry. The
                           prior value is recorded first.
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
    [string[]]$Identity,

    [datetime]$ExpiryDate,

    [switch]$ClearExpiry,

    [switch]$AllowPastDate,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-AdAccountExpiry'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #9 (AD & Identity)'

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

        if (-not $ClearExpiry -and -not $ExpiryDate) {
            throw 'Specify -ExpiryDate, or -ClearExpiry to remove the expiry.'
        }
        if ($ExpiryDate -and $ExpiryDate -lt (Get-Date) -and -not $AllowPastDate) {
            throw ('Refusing: {0:yyyy-MM-dd} is in the past and would disable the account immediately. ' +
                   'Pass -AllowPastDate if that is genuinely intended.' -f $ExpiryDate)
        }

        foreach ($id in $Identity) {
            $u = Get-ADUser -Identity $id -Properties AccountExpirationDate,Enabled,DistinguishedName,DisplayName @adArgs

            $current = $u.AccountExpirationDate
            $wanted = if ($ClearExpiry) { $null } else { $ExpiryDate }

            if (("$current" -eq "$wanted")) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $id `
                    -Message 'Skipped - expiry already at the requested value (idempotent)'
                continue
            }

            $results.Add([PSCustomObject]@{
                Name          = $u.SamAccountName
                Id            = $u.DistinguishedName
                DisplayName   = $u.DisplayName
                Enabled       = $u.Enabled
                CurrentExpiry = $current
                NewExpiry     = $wanted
                Operation     = if ($ClearExpiry) { 'Clear' } else { 'Set' }
                DaysUntilExpiry = if ($wanted) { [math]::Round(($wanted - (Get-Date)).TotalDays, 0) } else { $null }
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Set account expiry')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
                'Prior expiry: {0}' -f $(if ($item.CurrentExpiry) { $item.CurrentExpiry } else { 'never' }))

            if ($item.Operation -eq 'Clear') {
                Clear-ADAccountExpiration -Identity $item.Id @adArgs
                $detail = 'expiry cleared - account no longer expires'
            } else {
                Set-ADAccountExpiration -Identity $item.Id -DateTime $item.NewExpiry @adArgs
                $detail = 'expires {0:yyyy-MM-dd} ({1} day(s))' -f $item.NewExpiry, $item.DaysUntilExpiry
            }

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message $detail
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = ('Expiry' + $item.Operation); Detail = $detail; Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Set Account Expiry'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
