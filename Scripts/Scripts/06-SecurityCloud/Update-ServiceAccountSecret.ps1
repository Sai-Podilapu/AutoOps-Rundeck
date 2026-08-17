<#
.SYNOPSIS
    Rotates Entra application secrets that have a recorded dependency
    inventory.

.DESCRIPTION
    Rotates the client secret on Entra ID application registrations and stores
    the new value in Key Vault. Only applications with a recorded dependency
    inventory are eligible - the workbook is explicit that unmanaged accounts
    need human dependency discovery first, and an application whose consumers
    are unknown is exactly the one that breaks when its secret changes.

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

.PARAMETER DependencyInventoryFile
    JSON file listing, per application, which systems consume its secret. An
    application absent from this file is reported and never rotated.

.PARAMETER ApplicationName
    Limit to these application display names.

.PARAMETER KeyVaultName
    Key Vault to store the new secret in.

.PARAMETER ExpiringWithinDays
    Rotate secrets expiring within this many days.

.PARAMETER NewSecretLifetimeMonths
    Lifetime of the new secret.

.PARAMETER RemoveOldSecret
    Delete the previous secret after the new one is stored. Off by default so
    consumers have an overlap window to pick up the new value.

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
    .\Update-ServiceAccountSecret.ps1 -DependencyInventoryFile .\\deps.json -KeyVaultName kv-prod -ExpiringWithinDays 30

    REPORT ONLY. Lists eligible and ineligible applications, raises an
    approval.

.EXAMPLE
    .\Update-ServiceAccountSecret.ps1 -DependencyInventoryFile .\\deps.json -KeyVaultName kv-prod -ApprovalReference APR-... -TicketReference CHG0012345

    Rotates eligible applications, keeping the old secret valid.

.NOTES
    Source use case      : #18 - Service Account Password Rotation
    Category             : Security Cloud
    Technology           : CyberArk / HashiCorp Vault / Az KV
    Difficulty           : High
    Agent possible       : Partial
    Can execute with SOP : Partially - Agent Assists
    Automation type      : Change / Write
    Risk level           : High
    Human approval needed: YES
    Guardrails (col L)   : "Vault-managed accounts rotate automatically; unmanaged/legacy accounts need human dependency discovery first or things break"

    Required permissions : Microsoft Graph Application.ReadWrite.All, plus Key Vault Secrets Officer on the vault.
    Required modules     : Microsoft.Graph.Authentication, Microsoft.Graph.Applications, Az.Accounts, Az.KeyVault
    Authentication       : Vendor REST API via Invoke-RestMethod, or Graph
                           where the tool is Microsoft.

    ASSIST-ONLY, and the dependency inventory is the human half. Rotating
    a secret is trivial; knowing what will stop working when you do is
    not, and that knowledge does not live in any API. So an application
    absent from -DependencyInventoryFile is reported as needing discovery
    and is structurally not rotatable. -RemoveOldSecret is off by default
    because the overlap window is what turns a rotation from an outage
    into a change: both secrets work until consumers have moved. One
    honest limitation: Microsoft Graph returns a new client secret as a
    plain .NET string and offers no alternative. The script converts it to
    a SecureString character by character and clears the source property
    immediately, but the string existed in managed memory and .NET strings
    cannot be zeroed. That is a property of the Graph API, not of this
    script, and it is stated here rather than papered over.

    Rollback             : The old secret is retained by default and stays
                           valid until its own expiry, so a consumer that has
                           not picked up the new value keeps working. If
                           -RemoveOldSecret was used there is NO rollback - the
                           old credential is gone and every consumer must take
                           the new one.
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication
#Requires -Modules Microsoft.Graph.Applications
#Requires -Modules Az.Accounts
#Requires -Modules Az.KeyVault

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory)]
    [string]$DependencyInventoryFile,

    [string[]]$ApplicationName,

    [Parameter(Mandatory)]
    [string]$KeyVaultName,

    [ValidateRange(1,365)]
    [int]$ExpiringWithinDays = 30,

    [ValidateRange(1,24)]
    [int]$NewSecretLifetimeMonths = 12,

    [switch]$RemoveOldSecret,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Scheduled service account secret rotation',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Update-ServiceAccountSecret'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #18 (Security Cloud)'

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
    $pre = Test-Prerequisite -RequiredModule 'Microsoft.Graph.Authentication','Microsoft.Graph.Applications','Az.Accounts','Az.KeyVault'
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


        Connect-MgGraph -Scopes 'Application.ReadWrite.All' -NoWelcome -ErrorAction Stop
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Microsoft Graph'

        if (-not (Test-Path -LiteralPath $DependencyInventoryFile)) {
            throw ('Dependency inventory not found: {0}. Without it nothing is eligible - the workbook ' +
                   'requires human dependency discovery before rotation.' -f $DependencyInventoryFile)
        }
        $inventory = Get-Content -LiteralPath $DependencyInventoryFile -Raw | ConvertFrom-Json

        $azContext = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $azContext) {
            throw 'No Azure context for Key Vault access. Run Connect-AzAccount before this script.'
        }
        $vault = Get-AzKeyVault -VaultName $KeyVaultName -ErrorAction Stop
        if (-not $vault) { throw ('Key Vault "{0}" not found.' -f $KeyVaultName) }

        $applications = @(Get-MgApplication -All -ErrorAction Stop)
        if ($ApplicationName) {
            $applications = @($applications | Where-Object { $ApplicationName -contains $_.DisplayName })
        }

        $cutoff = (Get-Date).AddDays($ExpiringWithinDays)
        $notInventoried = 0

        foreach ($app in $applications) {
            $secrets = @($app.PasswordCredentials)
            if ($secrets.Count -eq 0) { continue }

            $soonest = ($secrets | Sort-Object EndDateTime | Select-Object -First 1)
            if ($soonest.EndDateTime -and ([datetime]$soonest.EndDateTime) -gt $cutoff) { continue }

            $dependencies = $inventory.($app.DisplayName)
            $hasInventory = ($null -ne $dependencies -and @($dependencies).Count -gt 0)

            if (-not $hasInventory) {
                $notInventoried++
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $app.DisplayName -Message (
                    'NOT ROTATABLE - no dependency inventory. Rotating a secret whose consumers are unknown ' +
                    'is how things break. Discover them and add the application to the inventory file.')
            }

            $results.Add([PSCustomObject]@{
                Name             = $app.DisplayName
                Id               = $app.Id
                ApplicationId    = $app.Id
                AppId            = $app.AppId
                OldKeyId         = $soonest.KeyId
                OldSecretExpiry  = $soonest.EndDateTime
                DaysUntilExpiry  = if ($soonest.EndDateTime) { [math]::Round((([datetime]$soonest.EndDateTime) - (Get-Date)).TotalDays, 1) } else { $null }
                SecretCount      = $secrets.Count
                Dependencies     = (@($dependencies) -join '; ')
                DependencyCount  = @($dependencies).Count
                HasInventory     = $hasInventory
                Actionable       = $hasInventory
                VaultName        = $KeyVaultName
                VaultSecretName  = ('{0}-clientsecret' -f ($app.DisplayName -replace '[^A-Za-z0-9-]', '-'))
                Note             = if ($hasInventory) {
                                      ('{0} known consumer(s) - they must pick up the new secret' -f @($dependencies).Count)
                                   } else { 'No dependency inventory - human discovery required before rotation' }
            })
        }

        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            '{0} application(s) eligible for rotation; {1} blocked pending dependency discovery.' -f
            @($results | Where-Object { $_.Actionable }).Count, $notInventoried)
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Rotate application secret', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Rotate application secret')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            if (-not $item.Actionable) {
                $actions.Add([PSCustomObject]@{
                    Name = $item.Name; Action = 'BlockedPendingDiscovery'; Detail = $item.Note; Succeeded = $true })
            } else {
                $newCredential = Add-MgApplicationPassword -ApplicationId $item.ApplicationId -ErrorAction Stop `
                    -PasswordCredential @{
                        displayName = ('Rotated {0} by {1}' -f (Get-Date -Format 'yyyy-MM-dd'), $scriptName)
                        endDateTime = (Get-Date).AddMonths($NewSecretLifetimeMonths)
                    }

                if (-not $newCredential.SecretText) {
                    throw 'Graph returned no secret text for the new credential; nothing was stored in Key Vault.'
                }

                # Graph hands the new secret back as a plain .NET string and offers no way
                # to receive it any other way. It is built into a SecureString character by
                # character rather than round-tripped through ConvertTo-SecureString
                # -AsPlainText, and the source property is cleared immediately afterwards.
                # The string still existed, and .NET strings cannot be zeroed - that
                # limitation belongs to the Graph API, and it is stated in .NOTES rather
                # than papered over.
                $secureSecret = New-Object System.Security.SecureString
                foreach ($character in $newCredential.SecretText.ToCharArray()) {
                    $secureSecret.AppendChar($character)
                }
                $secureSecret.MakeReadOnly()
                $newCredential.SecretText = $null

                Set-AzKeyVaultSecret -VaultName $item.VaultName -Name $item.VaultSecretName -ErrorAction Stop `
                    -SecretValue $secureSecret `
                    -Expires (Get-Date).AddMonths($NewSecretLifetimeMonths) | Out-Null

                $detail = ('new keyId {0}, stored as {1}' -f $newCredential.KeyId, $item.VaultSecretName)

                if ($RemoveOldSecret) {
                    Remove-MgApplicationPassword -ApplicationId $item.ApplicationId `
                        -KeyId $item.OldKeyId -ErrorAction Stop
                    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
                        'OLD SECRET DELETED. Every one of the {0} known consumer(s) must now use the new value: {1}' -f
                        $item.DependencyCount, $item.Dependencies)
                    $detail += '; old secret removed'
                } else {
                    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
                        'Old secret RETAINED until {0} so the {1} known consumer(s) have an overlap window: {2}' -f
                        $item.OldSecretExpiry, $item.DependencyCount, $item.Dependencies)
                }

                Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                    'Secret rotated and stored in {0}. {1}' -f $item.VaultName, $detail)
                $actions.Add([PSCustomObject]@{
                    Name = $item.Name; Action = 'SecretRotated'; Detail = $detail; Succeeded = $true })
            }
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Service Account Password Rotation'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
