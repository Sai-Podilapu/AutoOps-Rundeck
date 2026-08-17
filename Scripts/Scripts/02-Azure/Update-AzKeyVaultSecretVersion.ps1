<#
.SYNOPSIS
    Rotates Key Vault secrets by adding a new version, keeping the previous
    one enabled.

.DESCRIPTION
    Creates a new version of a secret and leaves the prior version ENABLED, so
    consumers that pin a version keep working while the rollout is verified.
    Which applications consume a secret, and whether they survived the
    rotation, is human-led work that this script deliberately does not
    attempt.

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

.PARAMETER SubscriptionId
    Subscription to operate in. Falls back to azure.defaultSubscriptionId in
    config.json.

.PARAMETER VaultName
    Key Vault holding the secrets.

.PARAMETER SecretName
    Secret(s) to rotate.

.PARAMETER NewSecretValue
    The new value, as a SecureString. Generated if omitted.

.PARAMETER GeneratedLength
    Length of the generated value when -NewSecretValue is omitted.

.PARAMETER DisablePreviousVersion
    Disable the prior version immediately. Off by default because it breaks
    version-pinned consumers.

.PARAMETER ExpiresInDays
    Expiry to set on the new version.

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
    .\Update-AzKeyVaultSecretVersion.ps1 -VaultName kv-prod -SecretName api-key

    REQUEST mode - raises an approval to rotate one secret.

.EXAMPLE
    .\Update-AzKeyVaultSecretVersion.ps1 -VaultName kv-prod -SecretName api-key -ApprovalReference APR-...

    Rotates the secret, leaving the previous version enabled.

.NOTES
    Source use case      : #21 - Azure Key Vault Secret Rotation
    Category             : Azure
    Technology           : Azure Functions / Key Vault
    Difficulty           : High
    Agent possible       : Partial
    Can execute with SOP : Partially - Agent Assists
    Automation type      : Change / Write
    Risk level           : High
    Human approval needed: YES
    Guardrails (col L)   : "Rotation mechanics automatable per secret; mapping which apps consume each secret & validating them post-rotation is human-led"

    Required permissions : Key Vault Secrets Officer on the vault.
    Required modules     : Az.Accounts, Az.KeyVault
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    Rotation is only half the job. Mapping which applications consume each
    secret, and validating them after the change, is explicitly human-led
    per the workbook guardrail. This script rotates and reports; it cannot
    tell you what broke.

    Rollback             : The previous version remains enabled by default, so
                           consumers can be repointed to it. If
                           -DisablePreviousVersion was used, re-enable it with
                           Update-AzKeyVaultSecret.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.KeyVault

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$VaultName,

    [Parameter(Mandatory)]
    [string[]]$SecretName,

    [System.Security.SecureString]$NewSecretValue,

    [ValidateRange(16,128)]
    [int]$GeneratedLength = 32,

    [switch]$DisablePreviousVersion,

    [ValidateRange(1,3650)]
    [int]$ExpiresInDays = 365,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Scheduled secret rotation',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Update-AzKeyVaultSecretVersion'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #21 (Azure)'

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
    $pre = Test-Prerequisite -RequiredModule 'Az.Accounts','Az.KeyVault'
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
        Connect-AutomationPlatform -Platform 'Azure' | Out-Null


        if (-not $SubscriptionId -and $config -and $config.azure) { $SubscriptionId = $config.azure.defaultSubscriptionId }
        if ($SubscriptionId) {
            Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop | Out-Null
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message ('Subscription context: {0}' -f $SubscriptionId)
        } else {
            $ctx = Get-AzContext
            if (-not $ctx) { throw 'No Azure context. Pass -SubscriptionId or set azure.defaultSubscriptionId in config.json.' }
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'No -SubscriptionId given; using the ambient context {0}' -f $ctx.Subscription.Id)
        }

        # Existence check only - throws if the vault is wrong.
        Get-AzKeyVault -VaultName $VaultName -ErrorAction Stop | Out-Null

        foreach ($name in $SecretName) {
            $current = Get-AzKeyVaultSecret -VaultName $VaultName -Name $name -ErrorAction SilentlyContinue
            if (-not $current) {
                throw ('Secret {0} does not exist in {1}. This script rotates existing secrets; it does not create them.' -f $name, $VaultName)
            }

            $versions = @(Get-AzKeyVaultSecret -VaultName $VaultName -Name $name -IncludeVersions -ErrorAction SilentlyContinue)

            $results.Add([PSCustomObject]@{
                Name             = $name
                Id               = $current.Id
                VaultName        = $VaultName
                CurrentVersion   = $current.Version
                CurrentCreated   = $current.Created
                CurrentExpires   = $current.Expires
                Enabled          = $current.Enabled
                VersionCount     = $versions.Count
                ContentType      = $current.ContentType
                DisablePrevious  = [bool]$DisablePreviousVersion
                HumanFollowUp    = 'Identify consuming applications and validate them after rotation - not automated'
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

    if ($RequestApproval -or -not $ApprovalReference) {
        $request = New-ApprovalRequest -ScriptName $scriptName -ChangeSet $candidates `
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Rotate Key Vault secret', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Rotate Key Vault secret')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            if ($NewSecretValue) {
                $secureValue = $NewSecretValue
                $generated = $false
            } else {
                # Built character by character straight into a SecureString. The generated
                # value never exists as a plaintext String, so it cannot be captured by a
                # transcript, a crash dump, or an accidental Write-Output.
                $alphabet = ([char[]](
                    (48..57)  +      # 0-9
                    (65..90)  +      # A-Z
                    (97..122) +      # a-z
                    (33,35,36,37,38,42,43,45,61,63,64,95)   # punctuation, shell-safe subset
                ))
                $secureValue = New-Object System.Security.SecureString
                $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
                try {
                    $buf = New-Object byte[] 1
                    $limit = [byte](256 - (256 % $alphabet.Length))   # reject above this to avoid modulo bias
                    for ($i = 0; $i -lt $GeneratedLength; $i++) {
                        do { $rng.GetBytes($buf) } while ($buf[0] -ge $limit)
                        $secureValue.AppendChar($alphabet[$buf[0] % $alphabet.Length])
                    }
                } finally {
                    $rng.Dispose()
                }
                $secureValue.MakeReadOnly()
                $generated = $true
            }

            $new = Set-AzKeyVaultSecret -VaultName $item.VaultName -Name $item.Name -SecretValue $secureValue `
                -Expires (Get-Date).AddDays($ExpiresInDays) -ErrorAction Stop

            # The previous version stays ENABLED unless explicitly disabled, so a consumer
            # pinned to it keeps working while the rollout is verified.
            if ($DisablePreviousVersion -and $item.CurrentVersion) {
                Update-AzKeyVaultSecret -VaultName $item.VaultName -Name $item.Name `
                    -Version $item.CurrentVersion -Enable $false -ErrorAction Stop | Out-Null
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
                    'Previous version {0} DISABLED - version-pinned consumers will now fail' -f $item.CurrentVersion)
            }

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Secret rotated: version {0} -> {1} (generated={2}, previous kept enabled={3}). ' +
                'Validate consuming applications manually.' -f
                $item.CurrentVersion, $new.Version, $generated, (-not $DisablePreviousVersion))
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'Rotated'
                Detail = ('{0} -> {1}' -f $item.CurrentVersion, $new.Version); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Azure Key Vault Secret Rotation'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
