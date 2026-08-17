<#
.SYNOPSIS
    Applies OS patches to OCI managed instances, after a pre-patch snapshot.

.DESCRIPTION
    Installs available package updates on OS Management managed instances. A
    boot volume backup is taken before each instance is patched, because the
    guardrail requires a pre-snapshot and a patch run without a rollback point
    is not a change-window activity.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

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

.PARAMETER InstanceName
    Instance display name(s) to patch.

.PARAMETER UpdateType
    Class of update to install.

.PARAMETER OsManagementService
    Which OS Management service this tenancy uses. The newer Hub service and
    the legacy service have different CLI command groups.

.PARAMETER SkipPreSnapshot
    Patch without taking a boot volume backup first. Logged as a WARN; the
    guardrail on this use case asks for a pre-snapshot.

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
    .\Install-OciPatchUpdate.ps1 -InstanceName APP01 -UpdateType SECURITY

    REPORT ONLY. Lists pending updates and raises an approval.

.EXAMPLE
    .\Install-OciPatchUpdate.ps1 -InstanceName APP01 -UpdateType SECURITY -ApprovalReference APR-... -TicketReference CHG0012345

    Snapshots and patches an approved instance.

.NOTES
    Source use case      : #12 - OCI Patch Management (OS Mgmt Service)
    Category             : OCI
    Technology           : OCI OS Management
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "Scheduled OS patching; change-window approval + pre-snapshot"

    Required permissions : An IAM policy allowing the OS Management instance actions plus BOOT_VOLUME_BACKUP_CREATE for the pre-snapshot.
    Required modules     : none beyond IT-Automation-Common
    Authentication       : OCI CLI config profile. NOTE: there is no
                           first-party OCI PowerShell module - this wraps the
                           OCI CLI.

    Two OS Management services exist in OCI - the newer OS Management Hub
    and the legacy OS Management service - and they use different CLI
    command groups. Which one applies depends on the tenancy, so it is a
    PARAMETER rather than a guess. Set it once for your environment.
    Patching may reboot the instance depending on the packages involved;
    this script does not suppress or force a reboot.

    Rollback             : Create a new boot volume from the pre-patch backup
                           this script takes and attach it in place of the
                           current one. That is why -SkipPreSnapshot is a
                           deliberate act rather than a default.
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$CompartmentId,

    [string]$Region,

    [string]$CliProfile,

    [string]$CliConfigFile,

    [string]$OciCliPath,

    [string[]]$InstanceName,

    [ValidateSet('SECURITY','BUGFIX','ENHANCEMENT','ALL')]
    [string]$UpdateType = 'SECURITY',

    [ValidateSet('os-management-hub','os-management')]
    [string]$OsManagementService = 'os-management-hub',

    [switch]$SkipPreSnapshot,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Scheduled OS patching within an approved change window',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Install-OciPatchUpdate'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #12 (OCI)'

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

        if (-not $InstanceName) {
            throw 'Select instances with -InstanceName. This script does not patch an entire compartment by default.'
        }

        $listed = Invoke-OciCli -Argument @('compute', 'instance', 'list', '--compartment-id', $CompartmentId, '--all')
        $instances = @($listed.data | Where-Object {
            $InstanceName -contains $_.'display-name' -and "$($_.'lifecycle-state')" -eq 'RUNNING'
        })

        foreach ($vm in $instances) {
            $updates = @()
            $updateReadError = ''
            try {
                $listArgs = if ($OsManagementService -eq 'os-management-hub') {
                    @('os-management-hub', 'managed-instance', 'list-managed-instance-available-packages', '--managed-instance-id', $vm.id)
                } else {
                    @('os-management', 'managed-instance', 'list-available-updates', '--managed-instance-id', $vm.id)
                }
                $available = Invoke-OciCli -Argument $listArgs
                $updates = @($available.data.items)
                if ($updates.Count -eq 0) { $updates = @($available.data) }
            } catch {
                $updateReadError = $_.Exception.Message
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $vm.'display-name' -Message (
                    'Available updates could not be read ({0}). The instance may not be managed by {1}.' -f
                    $updateReadError, $OsManagementService)
            }

            if ($UpdateType -ne 'ALL' -and $updates.Count -gt 0) {
                $filtered = @($updates | Where-Object { "$($_.'update-type')" -eq $UpdateType -or "$($_.type)" -eq $UpdateType })
                if ($filtered.Count -gt 0) { $updates = $filtered }
            }

            if ($updates.Count -eq 0 -and -not $updateReadError) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $vm.'display-name' `
                    -Message 'Skipped - no pending updates of the requested type'
                continue
            }

            $bootVolumeId = $null
            try {
                $att = (Invoke-OciCli -Argument @('compute', 'boot-volume-attachment', 'list',
                    '--compartment-id', $CompartmentId, '--instance-id', $vm.id,
                    '--availability-domain', $vm.'availability-domain')).data
                $bootVolumeId = @($att)[0].'boot-volume-id'
            } catch {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $vm.'display-name' `
                    -Message ('Boot volume not resolvable: {0}' -f $_.Exception.Message)
            }

            if (-not $bootVolumeId -and -not $SkipPreSnapshot) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $vm.'display-name' `
                    -Message 'EXCLUDED - no boot volume found, so no pre-patch snapshot is possible. Patching without a rollback point is refused.'
                continue
            }

            $results.Add([PSCustomObject]@{
                Name          = $vm.'display-name'
                Id            = $vm.id
                InstanceId    = $vm.id
                BootVolumeId  = $bootVolumeId
                UpdateType    = $UpdateType
                PendingUpdates= $updates.Count
                UpdateNames   = ((@($updates) | Select-Object -First 10 | ForEach-Object { $_.name }) -join '; ')
                UpdateReadError = $updateReadError
                PreSnapshot   = (-not $SkipPreSnapshot)
                Service       = $OsManagementService
                RebootNote    = 'Patching may reboot the instance depending on the packages; not suppressed or forced here'
            })
        }

        if ($SkipPreSnapshot) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                '-SkipPreSnapshot was passed. Patching will proceed with NO rollback point, contrary to the ' +
                'guardrail on this use case.')
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Patch managed instance', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Patch managed instance')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            if ($item.PreSnapshot) {
                $snapName = 'prepatch-{0}-{1}' -f $item.Name, (Get-Date -Format 'yyyyMMdd-HHmm')
                $snap = Invoke-OciCli -Argument @('bv', 'boot-volume-backup', 'create',
                    '--boot-volume-id', $item.BootVolumeId, '--type', 'FULL',
                    '--display-name', $snapName, '--wait-for-state', 'AVAILABLE')

                Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                    'Pre-patch boot volume backup created: {0} ({1}). This is the rollback point.' -f $snap.data.id, $snapName)
            } else {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label `
                    -Message 'Patching with NO pre-snapshot because -SkipPreSnapshot was passed.'
            }

            $patchArgs = if ($item.Service -eq 'os-management-hub') {
                @('os-management-hub', 'managed-instance', 'install-packages', '--managed-instance-id', $item.InstanceId)
            } else {
                @('os-management', 'managed-instance', 'install-all-package-updates', '--managed-instance-id', $item.InstanceId)
            }
            $job = Invoke-OciCli -Argument $patchArgs

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                '{0} update(s) submitted via {1}. Work request: {2}. The instance may reboot.' -f
                $item.PendingUpdates, $item.Service, $job.data.id)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'PatchSubmitted'
                Detail = ('{0} update(s), pre-snapshot={1}' -f $item.PendingUpdates, $item.PreSnapshot); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'OCI Patch Management (OS Mgmt Service)'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
