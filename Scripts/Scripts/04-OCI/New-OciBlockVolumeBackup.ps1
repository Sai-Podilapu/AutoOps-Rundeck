<#
.SYNOPSIS
    Creates block volume backups, or assigns a backup policy.

.DESCRIPTION
    Takes on-demand backups of block volumes, or assigns an Oracle-managed
    backup policy so the platform keeps taking them. Both are additive:
    nothing existing is modified or removed.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

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

.PARAMETER VolumeName
    Block volume display name(s). All volumes in the compartment when omitted.

.PARAMETER VolumeId
    Block volume OCID(s).

.PARAMETER BackupType
    Backup type for an on-demand backup.

.PARAMETER AssignPolicyName
    Assign this Oracle-managed backup policy (Bronze, Silver, Gold) instead of
    taking an on-demand backup.

.PARAMETER DisplayNamePrefix
    Prefix for the created backup display name.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\New-OciBlockVolumeBackup.ps1 -BackupType FULL -VolumeName DATA01

    Full on-demand backup of one volume.

.EXAMPLE
    .\New-OciBlockVolumeBackup.ps1 -AssignPolicyName Silver

    Assigns the Silver policy to every volume in the compartment.

.NOTES
    Source use case      : #3 - OCI Block Volume Backup
    Category             : OCI
    Technology           : OCI Python SDK
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Additive backup via policies"

    Required permissions : An IAM policy allowing VOLUME_BACKUP_CREATE and VOLUME_INSPECT in the compartment.
    Required modules     : none beyond IT-Automation-Common
    Authentication       : OCI CLI config profile. NOTE: there is no
                           first-party OCI PowerShell module - this wraps the
                           OCI CLI.

    An INCREMENTAL backup still requires a prior full backup to restore
    from. If a volume has never had a full backup, the first incremental
    is promoted to a full by OCI automatically - this script does not
    attempt to detect or second-guess that.

    Rollback             : A backup is additive; delete it if unwanted. A
                           policy assignment is removed with
                           volume-backup-policy-assignment delete.
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

    [string[]]$VolumeName,

    [string[]]$VolumeId,

    [ValidateSet('FULL','INCREMENTAL')]
    [string]$BackupType = 'INCREMENTAL',

    [string]$AssignPolicyName,

    [string]$DisplayNamePrefix = 'auto',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'New-OciBlockVolumeBackup'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #3 (OCI)'

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

        $listed = Invoke-OciCli -Argument @('bv', 'volume', 'list', '--compartment-id', $CompartmentId, '--all')
        $volumes = @($listed.data | Where-Object { "$($_.'lifecycle-state')" -eq 'AVAILABLE' })

        $policyId = $null
        if ($AssignPolicyName) {
            $policies = Invoke-OciCli -Argument @('bv', 'volume-backup-policy', 'list')
            $policy = @($policies.data) | Where-Object { $_.'display-name' -eq $AssignPolicyName } | Select-Object -First 1
            if (-not $policy) {
                throw ('Backup policy "{0}" not found. Oracle-managed policies are Bronze, Silver and Gold.' -f $AssignPolicyName)
            }
            $policyId = $policy.id
        }

        foreach ($vol in $volumes) {
            if ($VolumeId -and $VolumeId -notcontains $vol.id) { continue }
            if ($VolumeName -and $VolumeName -notcontains $vol.'display-name') { continue }

            if ($policyId) {
                # Assigning a policy that is already assigned creates a duplicate
                # assignment rather than failing, so it is checked first.
                $assigned = $null
                try {
                    $existing = Invoke-OciCli -Argument @('bv', 'volume-backup-policy-assignment', 'get-volume-backup-policy-asset-assignment', '--asset-id', $vol.id)
                    $assigned = @($existing.data)[0]
                } catch {
                    Write-Verbose ('No existing policy assignment on {0}' -f $vol.'display-name')
                }
                if ($assigned -and $assigned.'policy-id' -eq $policyId) {
                    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $vol.'display-name' `
                        -Message ('Skipped - policy {0} is already assigned' -f $AssignPolicyName)
                    continue
                }
            }

            $results.Add([PSCustomObject]@{
                Name       = $vol.'display-name'
                Id         = $vol.id
                VolumeId   = $vol.id
                SizeInGBs  = $vol.'size-in-gbs'
                Operation  = if ($policyId) { 'AssignPolicy' } else { 'OnDemandBackup' }
                BackupType = if ($policyId) { $null } else { $BackupType }
                PolicyName = $AssignPolicyName
                PolicyId   = $policyId
                AvailabilityDomain = $vol.'availability-domain'
                BackupName = ('{0}-{1}-{2}' -f $DisplayNamePrefix, $vol.'display-name', (Get-Date -Format 'yyyyMMdd-HHmm'))
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Back up block volume')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            if ($item.Operation -eq 'AssignPolicy') {
                Invoke-OciCli -Argument @('bv', 'volume-backup-policy-assignment', 'create',
                    '--asset-id', $item.VolumeId, '--policy-id', $item.PolicyId) | Out-Null

                Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                    'Backup policy {0} assigned' -f $item.PolicyName)
                $actions.Add([PSCustomObject]@{
                    Name = $item.Name; Action = 'PolicyAssigned'; Detail = $item.PolicyName; Succeeded = $true })
            } else {
                $backup = Invoke-OciCli -Argument @('bv', 'backup', 'create',
                    '--volume-id', $item.VolumeId, '--type', $item.BackupType,
                    '--display-name', $item.BackupName)

                Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                    '{0} backup created: {1} ({2} GB volume)' -f $item.BackupType, $backup.data.id, $item.SizeInGBs)
                $actions.Add([PSCustomObject]@{
                    Name = $item.Name; Action = 'BackupCreated'
                    Detail = ('{0}, {1}' -f $item.BackupType, $backup.data.id); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'OCI Block Volume Backup'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
