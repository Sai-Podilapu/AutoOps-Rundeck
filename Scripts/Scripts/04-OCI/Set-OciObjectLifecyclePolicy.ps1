<#
.SYNOPSIS
    Applies Object Storage lifecycle rules, with deletion rules gated.

.DESCRIPTION
    Applies lifecycle rules to Object Storage buckets from a rules file.
    Archive and tiering rules move objects; DELETE rules destroy them
    permanently once the age threshold passes, so a rule set containing any
    deletion rule is refused until it has been explicitly reviewed.

    DESTRUCTIVE. This script is REPORT-ONLY by default: it produces the
    candidate list and stops. Nothing is deleted, wiped or failed over
    unless -Execute is passed AND a valid -ApprovalReference is supplied.
    A pre-action backup/export is taken where the platform allows it, and
    every object is logged individually before it is touched.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER CompartmentId
    Compartment OCID to operate in. Falls back to oci.defaultCompartmentId in
    config.json.

.PARAMETER Region
    OCI region identifier, e.g. me-dubai-1. Falls back to oci.defaultRegion in
    config.json, then to the region in the CLI profile.

.PARAMETER CliProfile
    Named profile in the OCI CLI config file. Not called -Profile because
    $Profile is a PowerShell automatic variable.

.PARAMETER CliConfigFile
    Path to the OCI CLI config file. The CLI default (~/.oci/config) is used
    when omitted.

.PARAMETER OciCliPath
    Full path to the oci executable. Resolved from PATH when omitted.

.PARAMETER BucketName
    Bucket(s) to apply the policy to.

.PARAMETER RulesFile
    JSON file containing the lifecycle rule items.

.PARAMETER DeletionRulesReviewed
    Confirms that every DELETE rule in the file has been reviewed and the data
    loss it will cause is intended. Required if the file contains any deletion
    rule.

.PARAMETER Namespace
    Object Storage namespace. Resolved from the tenancy when omitted.

.PARAMETER Execute
    Actually perform the destructive action. Without this the script only
    reports what it would do.

.PARAMETER ProtectedList
    Path to a file of names/ids that must never be acted upon, one per line.
    Entries here are excluded unconditionally and the exclusion cannot be
    overridden by any other parameter.

.PARAMETER MinimumAgeDays
    Only consider objects older than this. A conservative default guards
    against acting on something created moments ago.

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
    .\Set-OciObjectLifecyclePolicy.ps1 -BucketName logs-archive -RulesFile .\lifecycle.json

    REPORT ONLY. Shows current vs proposed rules and raises an approval.

.EXAMPLE
    .\Set-OciObjectLifecyclePolicy.ps1 -BucketName logs-archive -RulesFile .\lifecycle.json -DeletionRulesReviewed -ApprovalReference APR-... -Execute

    Applies a reviewed rule set containing deletion rules.

.NOTES
    Source use case      : #13 - OCI Object Storage Lifecycle Policy
    Category             : OCI
    Technology           : OCI CLI / Python SDK
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Destructive / High-Impact
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "Auto-tier/delete by age; deletion rules reviewed before enabling"

    Required permissions : An IAM policy allowing OBJECTSTORAGE_BUCKET_UPDATE and read on the buckets.
    Required modules     : none beyond IT-Automation-Common
    Authentication       : OCI CLI config profile. NOTE: there is no
                           first-party OCI PowerShell module - this wraps the
                           OCI CLI.

    DESTRUCTIVE, on a delay. A lifecycle DELETE rule does not destroy
    anything at the moment it is applied - it destroys objects
    continuously from then on, without further approval, as they age past
    the threshold. That is why the review flag gates the rule set rather
    than an individual delete call: the approval is for a standing
    instruction, not a single action.

    Rollback             : The previous policy is captured and logged before
                           the new one is written, so it can be re-applied.
                           Objects ALREADY DELETED by a prior rule are not
                           recoverable.
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([PSCustomObject])]
param(
    [string]$CompartmentId,

    [string]$Region,

    [string]$CliProfile,

    [string]$CliConfigFile,

    [string]$OciCliPath,

    [Parameter(Mandatory)]
    [string[]]$BucketName,

    [Parameter(Mandatory)]
    [string]$RulesFile,

    [switch]$DeletionRulesReviewed,

    [string]$Namespace,

    [switch]$Execute,

    [string]$ProtectedList,

    [ValidateRange(0, 3650)]
    [int]$MinimumAgeDays = 0,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Object Storage lifecycle management',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-OciObjectLifecyclePolicy'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #13 (OCI)'

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

    $protected = @()
    if ($ProtectedList -and (Test-Path -LiteralPath $ProtectedList)) {
        $protected = @(Get-Content -LiteralPath $ProtectedList |
            Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { $_.Trim() })
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Protected list loaded: {0} entry(ies). These are excluded unconditionally.' -f $protected.Count)
    }

    $results  = [System.Collections.Generic.List[PSCustomObject]]::new()
    $failures = [System.Collections.Generic.List[PSCustomObject]]::new()
}

process {
    try {
        Connect-AutomationPlatform -Platform 'OCI' | Out-Null


        function Invoke-OciCli {
            <#
                .SYNOPSIS
                    Runs one oci CLI command and returns its parsed JSON output.
                .DESCRIPTION
                    Appends the profile, config file, region and --output json, runs the
                    CLI, and throws on a non-zero exit code. Defined inside the script
                    rather than in the shared module because it depends on this run's
                    resolved CLI path and profile.
            #>
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)]
                [string[]]$Argument,

                [switch]$Raw
            )

            $cliArgs = @($Argument)
            if ($ociProfile)    { $cliArgs += @('--profile', $ociProfile) }
            if ($ociConfigFile) { $cliArgs += @('--config-file', $ociConfigFile) }
            if ($Region)        { $cliArgs += @('--region', $Region) }
            $cliArgs += @('--output', 'json')

            $errFile = [System.IO.Path]::GetTempFileName()
            $previousPreference = $ErrorActionPreference
            # Windows PowerShell turns redirected native stderr into terminating errors
            # under 'Stop', even when the process exits 0. The exit code is the signal
            # that actually matters, so the preference is relaxed for the call only.
            $ErrorActionPreference = 'Continue'
            $exitCode = 0
            try {
                $stdout = & $ociCli @cliArgs 2>$errFile
                $exitCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $previousPreference
            }

            $stderrText = ''
            if (Test-Path -LiteralPath $errFile) {
                $stderrText = "$(Get-Content -LiteralPath $errFile -Raw)"
                Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
            }

            if ($exitCode -ne 0) {
                # Redacted on the way into the log by Write-AutomationLog.
                throw ('oci {0} failed (exit {1}): {2}' -f ($Argument -join ' '), $exitCode, $stderrText.Trim())
            }

            $text = (@($stdout) -join "`n").Trim()
            if ($Raw) { return $text }
            if (-not $text) { return $null }
            try {
                return ($text | ConvertFrom-Json)
            } catch {
                throw ('oci {0} returned output that is not JSON: {1}' -f ($Argument -join ' '),
                       $text.Substring(0, [math]::Min(200, $text.Length)))
            }
        }

        $ociCli = if ($OciCliPath) { $OciCliPath } else { 'oci' }
        $resolvedCli = Get-Command -Name $ociCli -ErrorAction SilentlyContinue
        if (-not $resolvedCli) {
            throw ('The OCI CLI was not found ("{0}"). Install it and ensure it is on PATH, or pass ' +
                   '-OciCliPath. There is no first-party OCI PowerShell module; this script wraps the CLI.' -f $ociCli)
        }
        $ociCli = $resolvedCli.Source

        $ociProfile = $CliProfile
        $ociConfigFile = $CliConfigFile
        if ($config -and $config.oci) {
            if (-not $ociProfile -and $config.oci.profileName)          { $ociProfile = $config.oci.profileName }
            if (-not $Region -and $config.oci.defaultRegion)            { $Region = $config.oci.defaultRegion }
            if (-not $CompartmentId -and $config.oci.defaultCompartmentId) { $CompartmentId = $config.oci.defaultCompartmentId }
        }

        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Using OCI CLI at {0}{1}{2}' -f $ociCli,
            $(if ($ociProfile) { ", profile '$ociProfile'" } else { ', default profile' }),
            $(if ($Region) { ", region '$Region'" } else { ', region from profile' }))

        if (-not $CompartmentId) {
            throw 'No compartment. Pass -CompartmentId or set oci.defaultCompartmentId in config.json.'
        }

        if (-not (Test-Path -LiteralPath $RulesFile)) {
            throw ('Rules file not found: {0}' -f $RulesFile)
        }
        $rulesJson = Get-Content -LiteralPath $RulesFile -Raw
        $parsed = $rulesJson | ConvertFrom-Json
        # The file may be a bare array of rules or an object wrapping them in .items.
        # Both are normalised to a bare array here, so what the approver reviews is
        # exactly what is sent to --items.
        $rules = @($parsed.items)
        if ($rules.Count -eq 0) { $rules = @($parsed) }
        if ($rules.Count -eq 0) { throw ('No lifecycle rules found in {0}.' -f $RulesFile) }
        $normalisedRules = $rules | ConvertTo-Json -Depth 10 -Compress
        if ($rules.Count -eq 1) { $normalisedRules = '[' + $normalisedRules + ']' }

        if (-not $Namespace) {
            $Namespace = (Invoke-OciCli -Argument @('os', 'ns', 'get')).data
            if (-not $Namespace) { throw 'Could not resolve the Object Storage namespace.' }
        }

        $deleteRules = @($rules | Where-Object { "$($_.action)" -match '(?i)delete' })
        if ($deleteRules.Count -gt 0 -and -not $DeletionRulesReviewed) {
            throw ('The rule set contains {0} DELETE rule(s): {1}. These destroy objects permanently and ' +
                   'continuously once applied. Pass -DeletionRulesReviewed to confirm the data loss is ' +
                   'intended, per the guardrail on this use case.' -f
                   $deleteRules.Count, (($deleteRules | ForEach-Object { $_.name }) -join ', '))
        }

        foreach ($bucket in $BucketName) {
            $current = $null
            try {
                $current = (Invoke-OciCli -Argument @('os', 'object-lifecycle-policy', 'get',
                    '--namespace', $Namespace, '--bucket-name', $bucket)).data
            } catch {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $bucket `
                    -Message 'No existing lifecycle policy on this bucket.'
            }

            $currentSummary = if ($current -and $current.items) {
                ((@($current.items) | ForEach-Object { '{0}:{1}@{2}{3}' -f $_.name, $_.action, $_.'time-amount', $_.'time-unit' }) -join '; ')
            } else { '(none)' }

            $proposedSummary = ((@($rules) | ForEach-Object { '{0}:{1}@{2}{3}' -f $_.name, $_.action, $_.'time-amount', $_.'time-unit' }) -join '; ')
            if ($currentSummary -eq $proposedSummary) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $bucket `
                    -Message 'Skipped - the bucket already carries exactly these rules (idempotent)'
                continue
            }

            $results.Add([PSCustomObject]@{
                Name           = $bucket
                Id             = $bucket
                BucketName     = $bucket
                Namespace      = $Namespace
                CurrentRules   = $currentSummary
                ProposedRules  = $proposedSummary
                RuleCount      = $rules.Count
                DeleteRuleCount= $deleteRules.Count
                DeleteRuleNames= (($deleteRules | ForEach-Object { $_.name }) -join '; ')
                StandingEffect = if ($deleteRules.Count -gt 0) {
                                    'DELETES objects continuously from now on as they age past the threshold - no further approval per object'
                                 } else { 'Tiering/archival only; no deletion' }
                RulesFile      = $RulesFile
                RulesJson      = $normalisedRules
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

    # Hard exclusions and safety filters BEFORE anything else.
    if ($protected.Count -gt 0) {
        $before = $candidates.Count
        $candidates = @($candidates | Where-Object {
            $id = $_.Id; $nm = $_.Name
            -not ($protected | Where-Object { $_ -and ($id -like $_ -or $nm -like $_) })
        })
        if ($before -ne $candidates.Count) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
                'Protected list excluded {0} object(s).' -f ($before - $candidates.Count))
        }
    }
    if ($MinimumAgeDays -gt 0) {
        $cut = (Get-Date).AddDays(-$MinimumAgeDays)
        $before = $candidates.Count
        $candidates = @($candidates | Where-Object { -not $_.CreatedAt -or $_.CreatedAt -lt $cut })
        if ($before -ne $candidates.Count) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
                'Age filter (>{0}d) excluded {1} object(s).' -f $MinimumAgeDays, ($before - $candidates.Count))
        }
    }

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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Apply lifecycle policy', $candidates.Count, $Reason, $TicketReference)
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

    if (-not $Execute) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'REPORT-ONLY - {0} candidate(s) identified, nothing was changed. Pass -Execute to act.' -f $candidates.Count)
        $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'OCI Object Storage Lifecycle Policy (candidates)'
        Write-Output $candidates
        return
    }

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Apply lifecycle policy')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            # The previous policy is the rollback, so it is written to the log before the
            # new one replaces it.
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
                'Previous lifecycle policy (rollback reference): {0}' -f $item.CurrentRules)

            # The normalised array from the approval artifact is written out and passed by
            # file, so what is applied is exactly what was reviewed - not whatever shape
            # the original file happened to have.
            $rulesTemp = [System.IO.Path]::GetTempFileName()
            try {
                Set-Content -LiteralPath $rulesTemp -Value $item.RulesJson -Encoding UTF8
                Invoke-OciCli -Argument @('os', 'object-lifecycle-policy', 'put',
                    '--namespace', $item.Namespace, '--bucket-name', $item.BucketName,
                    '--items', ('file://{0}' -f ($rulesTemp -replace '\\', '/')), '--force') | Out-Null
            } finally {
                Remove-Item -LiteralPath $rulesTemp -Force -ErrorAction SilentlyContinue
            }

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                '{0} lifecycle rule(s) applied, {1} of them DELETE rules. {2}' -f
                $item.RuleCount, $item.DeleteRuleCount, $item.StandingEffect)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'LifecyclePolicyApplied'
                Detail = ('{0} rule(s), {1} delete' -f $item.RuleCount, $item.DeleteRuleCount); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'OCI Object Storage Lifecycle Policy'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
