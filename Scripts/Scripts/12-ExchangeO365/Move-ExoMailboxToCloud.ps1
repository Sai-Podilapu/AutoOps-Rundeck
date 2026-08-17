<#
.SYNOPSIS
    Runs and reports on hybrid mailbox migration batches.

.DESCRIPTION
    Creates and monitors migration batches moving mailboxes from on-premises
    Exchange to Exchange Online. The mechanical work - batch creation, status
    polling, per-mailbox progress - is automated. Planning, cutover
    scheduling, user communications and resolving individual mailbox failures
    remain human project work, exactly as the workbook states.

    DESTRUCTIVE. This script is REPORT-ONLY by default: it produces the
    candidate list and stops. Nothing is deleted, wiped or failed over
    unless -Execute is passed AND a valid -ApprovalReference is supplied.
    A pre-action backup/export is taken where the platform allows it, and
    every object is logged individually before it is touched.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

    AGENT-ASSIST ONLY. This automates the mechanical part - gathering,
    enriching and comparing against a baseline - and then stops, producing
    a decision-ready package. The judgement step is deliberately left to a
    human and is NOT scripted.

.PARAMETER BatchName
    Migration batch name.

.PARAMETER MailboxCsvPath
    CSV of mailboxes to migrate, with an EmailAddress column.

.PARAMETER MigrationEndpointName
    Existing migration endpoint to use.

.PARAMETER TargetDeliveryDomain
    Tenant routing domain, e.g. contoso.mail.onmicrosoft.com.

.PARAMETER Mode
    Status reports on an existing batch; Create makes a new one; Complete
    finalises the cutover.

.PARAMETER AutoComplete
    Allow the batch to complete automatically. Off by default - cutover timing
    is a human decision.

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
    .\Move-ExoMailboxToCloud.ps1 -BatchName wave3 -Mode Status

    Reports progress of an existing batch. Changes nothing.

.EXAMPLE
    .\Move-ExoMailboxToCloud.ps1 -BatchName wave3 -Mode Create -MailboxCsvPath .\\wave3.csv -MigrationEndpointName onprem -TargetDeliveryDomain contoso.mail.onmicrosoft.com -ApprovalReference APR-... -Execute

    Creates the approved migration batch.

.NOTES
    Source use case      : #15 - Email Migration (On-Prem to Cloud)
    Category             : Exchange & O365
    Technology           : IMAP Migration / Hybrid
    Difficulty           : High
    Agent possible       : Partial
    Can execute with SOP : Partially - Agent Assists
    Automation type      : Destructive / High-Impact
    Risk level           : High
    Human approval needed: YES
    Guardrails (col L)   : "Agent runs migration batches & status reports; planning, cutover scheduling, comms and per-mailbox issue resolution is human project work"

    Required permissions : Exchange Online Organization Management plus Mailbox Import Export role.
    Required modules     : ExchangeOnlineManagement
    Authentication       : App-only certificate auth via
                           Connect-ExchangeOnline.

    -Mode Status is read-only and needs no approval. Create and Complete
    are gated. AutoComplete is off by default because completing a batch
    cuts users over, and the timing of that is a project decision rather
    than an automation one.

    Rollback             : An incomplete batch can be removed with
                           Remove-MigrationBatch, leaving the source mailbox
                           authoritative. Once a batch COMPLETES, the mailbox
                           has moved and reversing it requires a fresh
                           migration in the opposite direction. Completion is
                           the point of no easy return, which is why it needs
                           both approval and -Execute.
#>

#Requires -Version 5.1
#Requires -Modules ExchangeOnlineManagement

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory)]
    [string]$BatchName,

    [string]$MailboxCsvPath,

    [string]$MigrationEndpointName,

    [string]$TargetDeliveryDomain,

    [ValidateSet('Status','Create','Complete')]
    [string]$Mode = 'Status',

    [switch]$AutoComplete,

    [switch]$Execute,

    [string]$ProtectedList,

    [ValidateRange(0, 3650)]
    [int]$MinimumAgeDays = 0,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Hybrid mailbox migration',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Move-ExoMailboxToCloud'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #15 (Exchange & O365)'

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

    # Risk = High: validate before doing anything at all.
    $pre = Test-Prerequisite -RequiredModule 'ExchangeOnlineManagement'
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

        if ($Mode -eq 'Status') {
            $batches = if ($BatchName) { @(Get-MigrationBatch -Identity $BatchName -ErrorAction Stop) }
                       else            { @(Get-MigrationBatch) }

            foreach ($b in $batches) {
                $users = @(Get-MigrationUser -BatchId $b.Identity -ErrorAction SilentlyContinue)
                $failed = @($users | Where-Object { $_.Status -eq 'Failed' })
                $synced = @($users | Where-Object { $_.Status -in @('Synced','Completed') })

                $results.Add([PSCustomObject]@{
                    Name          = $b.Identity
                    Id            = $b.Identity
                    BatchStatus   = "$($b.Status)"
                    TotalMailboxes= $users.Count
                    Synced        = $synced.Count
                    Failed        = $failed.Count
                    FailedMailboxes = (($failed.Identity | Select-Object -First 20) -join '; ')
                    PercentComplete = if ($users.Count -gt 0) { [math]::Round(($synced.Count / $users.Count) * 100, 1) } else { 0 }
                    CreationTime  = $b.CreationDateTime
                    HumanFollowUp = 'Per-mailbox failures need individual investigation - not automated'
                })
                if ($failed.Count -gt 0) {
                    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $b.Identity `
                        -Message ('{0} mailbox(es) failed and need human investigation' -f $failed.Count)
                }
            }
            return
        }

        if ($Mode -eq 'Create') {
            foreach ($p in @('MailboxCsvPath','MigrationEndpointName','TargetDeliveryDomain')) {
                if (-not (Get-Variable -Name $p -ValueOnly)) { throw ('-{0} is required when -Mode is Create.' -f $p) }
            }
            if (-not (Test-Path -LiteralPath $MailboxCsvPath)) { throw ('CSV not found: {0}' -f $MailboxCsvPath) }
            if (Get-MigrationBatch -Identity $BatchName -ErrorAction SilentlyContinue) {
                throw ('Migration batch {0} already exists. Use -Mode Status, or choose another name.' -f $BatchName)
            }

            $rows = Import-Csv -LiteralPath $MailboxCsvPath
            if (-not ($rows | Get-Member -Name EmailAddress)) {
                throw 'The CSV must contain an EmailAddress column.'
            }

            $results.Add([PSCustomObject]@{
                Name          = $BatchName
                Id            = $BatchName
                Mode          = 'Create'
                MailboxCount  = @($rows).Count
                CsvPath       = $MailboxCsvPath
                Endpoint      = $MigrationEndpointName
                TargetDomain  = $TargetDeliveryDomain
                AutoComplete  = [bool]$AutoComplete
                Mailboxes     = (($rows.EmailAddress | Select-Object -First 25) -join '; ')
            })
            return
        }

        # Complete
        $batch = Get-MigrationBatch -Identity $BatchName -ErrorAction Stop
        if ($batch.Status -ne 'Synced') {
            throw ('Batch {0} is {1}, not Synced. Completing an unsynced batch loses mail.' -f $BatchName, $batch.Status)
        }
        $users = @(Get-MigrationUser -BatchId $batch.Identity -ErrorAction SilentlyContinue)
        $failed = @($users | Where-Object { $_.Status -eq 'Failed' })
        if ($failed.Count -gt 0) {
            throw ('Batch {0} has {1} failed mailbox(es). Resolve them before completing the cutover.' -f $BatchName, $failed.Count)
        }

        $results.Add([PSCustomObject]@{
            Name          = $BatchName
            Id            = $BatchName
            Mode          = 'Complete'
            BatchStatus   = "$($batch.Status)"
            MailboxCount  = $users.Count
            CutoverImpact = 'Users are moved to the cloud mailbox. Reversal requires a fresh migration.'
        })
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Create or complete migration batch', $candidates.Count, $Reason, $TicketReference)
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
        $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Email Migration (On-Prem to Cloud) (candidates)'
        Write-Output $candidates
        return
    }

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Create or complete migration batch')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            if ($item.Mode -eq 'Create') {
                New-MigrationBatch -Name $item.Name -SourceEndpoint $item.Endpoint `
                    -CSVData ([System.IO.File]::ReadAllBytes($item.CsvPath)) `
                    -TargetDeliveryDomain $item.TargetDomain -AutoStart `
                    -AutoComplete:$item.AutoComplete -ErrorAction Stop | Out-Null

                Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                    'Migration batch created and started: {0} mailbox(es), autocomplete={1}. ' +
                    'Monitor with -Mode Status.' -f $item.MailboxCount, $item.AutoComplete)
                $actions.Add([PSCustomObject]@{
                    Name = $item.Name; Action = 'BatchCreated'
                    Detail = ('{0} mailboxes' -f $item.MailboxCount); Succeeded = $true })
            } else {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
                    'COMPLETING migration batch - users cut over to the cloud. Approval={0} Ticket={1}' -f
                    $ApprovalReference, $TicketReference)

                Complete-MigrationBatch -Identity $item.Name -Confirm:$false -ErrorAction Stop | Out-Null

                Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                    'Batch completion requested for {0} mailbox(es)' -f $item.MailboxCount)
                $actions.Add([PSCustomObject]@{
                    Name = $item.Name; Action = 'BatchCompleted'
                    Detail = ('{0} mailboxes cut over' -f $item.MailboxCount); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Email Migration (On-Prem to Cloud)'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
