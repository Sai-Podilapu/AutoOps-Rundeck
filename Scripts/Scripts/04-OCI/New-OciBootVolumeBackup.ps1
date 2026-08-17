<#
.SYNOPSIS
    Takes boot volume backups, typically before patching.

.DESCRIPTION
    Creates a boot volume backup for each selected instance so a patch run has
    something to roll back to. Additive: nothing is modified on the running
    instance.

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

.PARAMETER InstanceName
    Instance display name(s) whose boot volumes should be backed up.

.PARAMETER InstanceId
    Instance OCID(s).

.PARAMETER BackupType
    Backup type.

.PARAMETER DisplayNamePrefix
    Prefix for the created backup display name.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\New-OciBootVolumeBackup.ps1 -InstanceName APP01,APP02

    Full boot volume backups before a patch window.

.EXAMPLE
    .\New-OciBootVolumeBackup.ps1 -InstanceName APP01 -DisplayNamePrefix pre-upgrade -WhatIf

    Shows the backup that would be taken.

.NOTES
    Source use case      : #4 - OCI Boot Volume Snapshot
    Category             : OCI
    Technology           : OCI CLI
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Pre-patch snapshot; additive"

    Required permissions : An IAM policy allowing BOOT_VOLUME_BACKUP_CREATE, VOLUME_ATTACHMENT_READ and INSTANCE_INSPECT in the compartment.
    Required modules     : none beyond IT-Automation-Common
    Authentication       : OCI CLI config profile. NOTE: there is no
                           first-party OCI PowerShell module - this wraps the
                           OCI CLI.

    FULL is the default here, unlike the block volume script. A pre-patch
    snapshot whose restore depends on an earlier full backup being intact
    is not the safety net it appears to be, and a patch window is exactly
    when you do not want to discover that.

    Rollback             : Additive - delete the backup if unwanted. To use it,
                           create a new boot volume from the backup and attach
                           it; the original boot volume is untouched by this
                           script.
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

    [string[]]$InstanceId,

    [ValidateSet('FULL','INCREMENTAL')]
    [string]$BackupType = 'FULL',

    [string]$DisplayNamePrefix = 'prepatch',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'New-OciBootVolumeBackup'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #4 (OCI)'

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

        if (-not ($InstanceName -or $InstanceId)) {
            throw 'Select instances with -InstanceName or -InstanceId. This script does not back up every ' +
                  'boot volume in a compartment by default.'
        }

        $listed = Invoke-OciCli -Argument @('compute', 'instance', 'list', '--compartment-id', $CompartmentId, '--all')
        $instances = @($listed.data | Where-Object { "$($_.'lifecycle-state')" -notmatch '(?i)terminat' })

        foreach ($vm in $instances) {
            if ($InstanceId -and $InstanceId -notcontains $vm.id) { continue }
            if ($InstanceName -and $InstanceName -notcontains $vm.'display-name') { continue }

            # Scoped by instance id so no availability domain has to be guessed.
            $attachments = @()
            try {
                $resp = Invoke-OciCli -Argument @('compute', 'boot-volume-attachment', 'list',
                    '--compartment-id', $CompartmentId, '--instance-id', $vm.id,
                    '--availability-domain', $vm.'availability-domain')
                $attachments = @($resp.data)
            } catch {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $vm.'display-name' `
                    -Message ('Could not read boot volume attachment: {0}' -f $_.Exception.Message)
                continue
            }

            foreach ($att in $attachments) {
                $results.Add([PSCustomObject]@{
                    Name         = ('{0} boot volume' -f $vm.'display-name')
                    Id           = $att.'boot-volume-id'
                    InstanceName = $vm.'display-name'
                    InstanceId   = $vm.id
                    BootVolumeId = $att.'boot-volume-id'
                    LifecycleState = $vm.'lifecycle-state'
                    AvailabilityDomain = $vm.'availability-domain'
                    BackupType   = $BackupType
                    BackupName   = ('{0}-{1}-{2}' -f $DisplayNamePrefix, $vm.'display-name', (Get-Date -Format 'yyyyMMdd-HHmm'))
                })
            }
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Back up boot volume')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $backup = Invoke-OciCli -Argument @('bv', 'boot-volume-backup', 'create',
                '--boot-volume-id', $item.BootVolumeId, '--type', $item.BackupType,
                '--display-name', $item.BackupName)

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                '{0} boot volume backup created: {1}' -f $item.BackupType, $backup.data.id)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'BootBackupCreated'
                Detail = ('{0}, {1}' -f $item.BackupType, $backup.data.id); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'OCI Boot Volume Snapshot'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
