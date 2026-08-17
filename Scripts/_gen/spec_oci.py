# -*- coding: utf-8 -*-
"""OCI - use cases 1-15.

Oracle ships no first-party PowerShell module for OCI, so every script here
wraps the `oci` CLI and parses its JSON. The prologue below is shared by all
fifteen.
"""

CONN_PARAMS = [
    dict(name='CompartmentId',
         help='Compartment OCID to operate in. Falls back to oci.defaultCompartmentId in config.json.',
         decl="[string]$CompartmentId"),
    dict(name='Region',
         help='OCI region identifier, e.g. me-dubai-1. Falls back to oci.defaultRegion in config.json, '
              'then to the region in the CLI profile.',
         decl="[string]$Region"),
    dict(name='CliProfile',
         help='Named profile in the OCI CLI config file. Not called -Profile because $Profile is a '
              'PowerShell automatic variable.',
         decl="[string]$CliProfile"),
    dict(name='CliConfigFile',
         help='Path to the OCI CLI config file. The CLI default (~/.oci/config) is used when omitted.',
         decl="[string]$CliConfigFile"),
    dict(name='OciCliPath',
         help='Full path to the oci executable. Resolved from PATH when omitted.',
         decl="[string]$OciCliPath"),
]

CONNECT = r"""
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
"""

REQUIRE_COMPARTMENT = r"""
if (-not $CompartmentId) {
    throw 'No compartment. Pass -CompartmentId or set oci.defaultCompartmentId in config.json.'
}
"""


def oci(body, compartment=True):
    return CONNECT + (REQUIRE_COMPARTMENT if compartment else '') + body


SPECS = {

1: dict(
    file='Set-OciInstancePowerState',
    modules=[],
    synopsis='Starts, stops or reboots OCI compute instances.',
    desc='Performs a controlled power operation on compute instances selected by name, OCID or '
         'freeform tag, logging every instance before it is touched. Instances already in the '
         'requested state are skipped rather than re-issued.',
    params=CONN_PARAMS + [
        dict(name='Action', help='Power action to perform.',
             decl="[Parameter(Mandatory)]\n    [ValidateSet('START','STOP','SOFTSTOP','SOFTRESET','RESET')]\n    [string]$Action"),
        dict(name='InstanceName', help='Instance display name(s) to act on.',
             decl="[string[]]$InstanceName"),
        dict(name='InstanceId', help='Instance OCID(s) to act on.',
             decl="[string[]]$InstanceId"),
        dict(name='TagKey', help='Act on instances carrying this freeform tag key.',
             decl="[string]$TagKey"),
        dict(name='TagValue', help='Required value for -TagKey.',
             decl="[string]$TagValue")],
    perms='An IAM policy allowing INSTANCE_POWER_ACTIONS and INSTANCE_INSPECT in the compartment.',
    actionVerb='Power action on instance',
    rollback='Reversible: START undoes STOP and vice versa. RESET is an immediate power cycle with no '
             'guest shutdown, so an in-flight write can be lost - SOFTRESET is the graceful form.',
    notes='STOP and RESET differ in kind, not degree. SOFTSTOP and SOFTRESET ask the guest OS to shut '
          'down; STOP and RESET pull the power. Both are offered because a hung instance needs the '
          'hard form, but the difference is stated here rather than buried in the API.',
    examples=[("-Action STOP -TagKey schedule -TagValue nightly",
               'Graceful-selection stop of every instance tagged schedule=nightly.'),
              ("-Action START -InstanceName APP01,APP02 -WhatIf",
               'Shows which instances would be started.')],
    discover=oci(r"""
if (-not ($InstanceName -or $InstanceId -or $TagKey)) {
    throw 'Select instances with -InstanceName, -InstanceId or -TagKey. This script does not act on ' +
          'an entire compartment by default.'
}
if ($TagKey -and -not $TagValue) {
    throw '-TagKey requires -TagValue. Matching on the presence of a key alone is too broad for a power operation.'
}

$listed = Invoke-OciCli -Argument @('compute', 'instance', 'list', '--compartment-id', $CompartmentId, '--all')
$instances = @($listed.data)

foreach ($vm in $instances) {
    $state = "$($vm.'lifecycle-state')"
    if ($state -match '(?i)terminat') { continue }

    $matched = $false
    if ($InstanceId -and $InstanceId -contains $vm.id) { $matched = $true }
    if ($InstanceName -and $InstanceName -contains $vm.'display-name') { $matched = $true }
    if ($TagKey) {
        $tags = $vm.'freeform-tags'
        if ($tags -and "$($tags.$TagKey)" -eq $TagValue) { $matched = $true }
    }
    if (-not $matched) { continue }

    # Re-issuing a power action against an instance already in that state is a
    # no-op at best and an error at worst.
    $alreadyThere = switch ($Action) {
        'START'                       { $state -eq 'RUNNING' }
        { $_ -in 'STOP', 'SOFTSTOP' } { $state -eq 'STOPPED' }
        default                       { $false }
    }
    if ($alreadyThere) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $vm.'display-name' `
            -Message ('Skipped - already {0}' -f $state)
        continue
    }

    $results.Add([PSCustomObject]@{
        Name           = $vm.'display-name'
        Id             = $vm.id
        InstanceId     = $vm.id
        LifecycleState = $state
        Shape          = $vm.shape
        AvailabilityDomain = $vm.'availability-domain'
        Action         = $Action
        Graceful       = ($Action -in 'SOFTSTOP', 'SOFTRESET')
        TimeCreated    = $vm.'time-created'
    })
}
"""),
    act=r"""
Invoke-OciCli -Argument @('compute', 'instance', 'action',
    '--instance-id', $item.InstanceId, '--action', $item.Action) | Out-Null

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    '{0} issued (was {1}){2}' -f $item.Action, $item.LifecycleState,
    $(if (-not $item.Graceful -and $item.Action -ne 'START') { ' - HARD power operation, no guest shutdown' } else { '' }))
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = $item.Action
    Detail = ('was {0}' -f $item.LifecycleState); Succeeded = $true })
"""),

2: dict(
    file='New-OciInstance',
    modules=[],
    synopsis='Provisions OCI compute instances from an approved shape and image.',
    desc='Launches compute instances after a human has approved the shape and image. The change set '
         'names the shape, its OCPU and memory allocation, and the image, because those are what '
         'determine the bill and are what the guardrail asks an approver to look at.',
    params=CONN_PARAMS + [
        dict(name='DisplayName', help='Display name(s) for the new instance(s).',
             decl="[Parameter(Mandatory)]\n    [string[]]$DisplayName"),
        dict(name='Shape', help='Compute shape, e.g. VM.Standard.E4.Flex.',
             decl="[Parameter(Mandatory)]\n    [string]$Shape"),
        dict(name='ImageId', help='Image OCID to launch from.',
             decl="[Parameter(Mandatory)]\n    [string]$ImageId"),
        dict(name='SubnetId', help='Subnet OCID to attach the primary VNIC to.',
             decl="[Parameter(Mandatory)]\n    [string]$SubnetId"),
        dict(name='AvailabilityDomain', help='Availability domain. The first in the compartment when omitted.',
             decl="[string]$AvailabilityDomain"),
        dict(name='Ocpus', help='OCPU count for a flexible shape.',
             decl="[ValidateRange(1,128)]\n    [int]$Ocpus = 1"),
        dict(name='MemoryInGBs', help='Memory in GB for a flexible shape.',
             decl="[ValidateRange(1,2048)]\n    [int]$MemoryInGBs = 16"),
        dict(name='SshAuthorizedKeyFile', help='Path to a public key file placed in the instance metadata.',
             decl="[string]$SshAuthorizedKeyFile"),
        dict(name='FreeformTag', help='Freeform tags applied at launch, as key=value pairs.',
             decl="[string[]]$FreeformTag")],
    perms='An IAM policy allowing INSTANCE_CREATE, plus USE on the subnet and READ on the image.',
    actionVerb='Launch instance',
    reason='Approved compute provisioning',
    rollback='Terminate the instance. Terminating within the first hour still incurs the minimum '
             'billing increment for the shape.',
    notes='COST IMPACT. This script reports the shape, OCPU and memory being requested so an approver '
          'can price it against their own rate card. It does NOT compute or estimate a cost figure - '
          'OCI pricing depends on the tenancy agreement and there is no API here that would make such '
          'a number true. An invented estimate on an approval artifact would be worse than none.',
    examples=[("-DisplayName APP03 -Shape VM.Standard.E4.Flex -Ocpus 2 -MemoryInGBs 32 -ImageId ocid1.image... -SubnetId ocid1.subnet...",
               'REPORT ONLY. Builds the launch request and raises an approval.'),
              ("-DisplayName APP03 -Shape VM.Standard.E4.Flex -ImageId ocid1.image... -SubnetId ocid1.subnet... -ApprovalReference APR-...",
               'Launches an approved instance.')],
    discover=oci(r"""
if (-not $AvailabilityDomain) {
    $ads = Invoke-OciCli -Argument @('iam', 'availability-domain', 'list', '--compartment-id', $CompartmentId)
    $AvailabilityDomain = @($ads.data)[0].name
    if (-not $AvailabilityDomain) { throw 'Could not resolve an availability domain in this compartment.' }
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'Availability domain not supplied; using {0}' -f $AvailabilityDomain)
}

# Confirm the image and shape exist before an approver is asked about them.
$image = Invoke-OciCli -Argument @('compute', 'image', 'get', '--image-id', $ImageId)
if (-not $image.data) { throw ('Image {0} not found.' -f $ImageId) }

$shapeInfo = $null
try {
    $shapes = Invoke-OciCli -Argument @('compute', 'shape', 'list', '--compartment-id', $CompartmentId, '--all')
    $shapeInfo = @($shapes.data) | Where-Object { $_.shape -eq $Shape } | Select-Object -First 1
} catch {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
        'Shape list unavailable ({0}); proceeding with the shape as given.' -f $_.Exception.Message)
}
if ($shapes -and -not $shapeInfo) {
    throw ('Shape "{0}" is not available in this compartment.' -f $Shape)
}

$isFlex = $Shape -match '(?i)\.Flex$'

$existing = @()
try {
    $listed = Invoke-OciCli -Argument @('compute', 'instance', 'list', '--compartment-id', $CompartmentId, '--all')
    $existing = @($listed.data | Where-Object { "$($_.'lifecycle-state')" -notmatch '(?i)terminat' })
} catch {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message 'Could not list existing instances; duplicate-name check skipped.'
}

foreach ($dn in $DisplayName) {
    if ($existing.'display-name' -contains $dn) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $dn `
            -Message 'Skipped - an instance with this display name already exists (idempotent)'
        continue
    }

    $results.Add([PSCustomObject]@{
        Name        = $dn
        Id          = $dn
        DisplayName = $dn
        Shape       = $Shape
        IsFlexShape = $isFlex
        Ocpus       = if ($isFlex) { $Ocpus } else { $shapeInfo.ocpus }
        MemoryInGBs = if ($isFlex) { $MemoryInGBs } else { $shapeInfo.'memory-in-gbs' }
        ImageId     = $ImageId
        ImageName   = $image.data.'display-name'
        OperatingSystem = ('{0} {1}' -f $image.data.'operating-system', $image.data.'operating-system-version')
        SubnetId    = $SubnetId
        AvailabilityDomain = $AvailabilityDomain
        CostNote    = 'Cost NOT calculated - price the shape above against your own rate card'
    })
}
"""),
    act=r"""
$launchArgs = @('compute', 'instance', 'launch',
    '--compartment-id', $CompartmentId,
    '--availability-domain', $item.AvailabilityDomain,
    '--display-name', $item.DisplayName,
    '--shape', $item.Shape,
    '--image-id', $item.ImageId,
    '--subnet-id', $item.SubnetId,
    '--wait-for-state', 'RUNNING')

if ($item.IsFlexShape) {
    $launchArgs += @('--shape-config',
        (@{ ocpus = $item.Ocpus; memoryInGBs = $item.MemoryInGBs } | ConvertTo-Json -Compress))
}

$metadata = @{}
if ($SshAuthorizedKeyFile) {
    if (-not (Test-Path -LiteralPath $SshAuthorizedKeyFile)) {
        throw ('SSH public key file not found: {0}' -f $SshAuthorizedKeyFile)
    }
    $metadata['ssh_authorized_keys'] = (Get-Content -LiteralPath $SshAuthorizedKeyFile -Raw).Trim()
}
if ($metadata.Count -gt 0) {
    $launchArgs += @('--metadata', ($metadata | ConvertTo-Json -Compress))
}

if ($FreeformTag) {
    $tagMap = @{}
    foreach ($pair in $FreeformTag) {
        $kv = $pair -split '=', 2
        if ($kv.Count -eq 2) { $tagMap[$kv[0]] = $kv[1] }
    }
    if ($tagMap.Count -gt 0) {
        $launchArgs += @('--freeform-tags', ($tagMap | ConvertTo-Json -Compress))
    }
}

$launched = Invoke-OciCli -Argument $launchArgs

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Instance launched: {0}, shape {1} ({2} OCPU / {3} GB), image {4}' -f
    $launched.data.id, $item.Shape, $item.Ocpus, $item.MemoryInGBs, $item.ImageName)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'Launched'
    Detail = ('{0}, {1}' -f $launched.data.id, $item.Shape); Succeeded = $true })
"""),

3: dict(
    file='New-OciBlockVolumeBackup',
    modules=[],
    synopsis='Creates block volume backups, or assigns a backup policy.',
    desc='Takes on-demand backups of block volumes, or assigns an Oracle-managed backup policy so '
         'the platform keeps taking them. Both are additive: nothing existing is modified or removed.',
    params=CONN_PARAMS + [
        dict(name='VolumeName', help='Block volume display name(s). All volumes in the compartment when omitted.',
             decl="[string[]]$VolumeName"),
        dict(name='VolumeId', help='Block volume OCID(s).',
             decl="[string[]]$VolumeId"),
        dict(name='BackupType', help='Backup type for an on-demand backup.',
             decl="[ValidateSet('FULL','INCREMENTAL')]\n    [string]$BackupType = 'INCREMENTAL'"),
        dict(name='AssignPolicyName',
             help='Assign this Oracle-managed backup policy (Bronze, Silver, Gold) instead of taking '
                  'an on-demand backup.',
             decl="[string]$AssignPolicyName"),
        dict(name='DisplayNamePrefix', help='Prefix for the created backup display name.',
             decl="[string]$DisplayNamePrefix = 'auto'")],
    perms='An IAM policy allowing VOLUME_BACKUP_CREATE and VOLUME_INSPECT in the compartment.',
    actionVerb='Back up block volume',
    rollback='A backup is additive; delete it if unwanted. A policy assignment is removed with '
             'volume-backup-policy-assignment delete.',
    notes='An INCREMENTAL backup still requires a prior full backup to restore from. If a volume has '
          'never had a full backup, the first incremental is promoted to a full by OCI automatically - '
          'this script does not attempt to detect or second-guess that.',
    examples=[("-BackupType FULL -VolumeName DATA01",
               'Full on-demand backup of one volume.'),
              ("-AssignPolicyName Silver", 'Assigns the Silver policy to every volume in the compartment.')],
    discover=oci(r"""
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
"""),
    act=r"""
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
"""),

4: dict(
    file='New-OciBootVolumeBackup',
    modules=[],
    synopsis='Takes boot volume backups, typically before patching.',
    desc='Creates a boot volume backup for each selected instance so a patch run has something to '
         'roll back to. Additive: nothing is modified on the running instance.',
    params=CONN_PARAMS + [
        dict(name='InstanceName', help='Instance display name(s) whose boot volumes should be backed up.',
             decl="[string[]]$InstanceName"),
        dict(name='InstanceId', help='Instance OCID(s).',
             decl="[string[]]$InstanceId"),
        dict(name='BackupType', help='Backup type.',
             decl="[ValidateSet('FULL','INCREMENTAL')]\n    [string]$BackupType = 'FULL'"),
        dict(name='DisplayNamePrefix', help='Prefix for the created backup display name.',
             decl="[string]$DisplayNamePrefix = 'prepatch'")],
    perms='An IAM policy allowing BOOT_VOLUME_BACKUP_CREATE, VOLUME_ATTACHMENT_READ and '
          'INSTANCE_INSPECT in the compartment.',
    actionVerb='Back up boot volume',
    rollback='Additive - delete the backup if unwanted. To use it, create a new boot volume from the '
             'backup and attach it; the original boot volume is untouched by this script.',
    notes='FULL is the default here, unlike the block volume script. A pre-patch snapshot whose '
          'restore depends on an earlier full backup being intact is not the safety net it appears '
          'to be, and a patch window is exactly when you do not want to discover that.',
    examples=[("-InstanceName APP01,APP02", 'Full boot volume backups before a patch window.'),
              ("-InstanceName APP01 -DisplayNamePrefix pre-upgrade -WhatIf",
               'Shows the backup that would be taken.')],
    discover=oci(r"""
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
"""),
    act=r"""
$backup = Invoke-OciCli -Argument @('bv', 'boot-volume-backup', 'create',
    '--boot-volume-id', $item.BootVolumeId, '--type', $item.BackupType,
    '--display-name', $item.BackupName)

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    '{0} boot volume backup created: {1}' -f $item.BackupType, $backup.data.id)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'BootBackupCreated'
    Detail = ('{0}, {1}' -f $item.BackupType, $backup.data.id); Succeeded = $true })
"""),

5: dict(
    file='Get-OciBudgetAlert',
    modules=[],
    synopsis='Reports OCI budgets, spend against them and their alert rules.',
    desc='Lists budgets with actual and forecast spend as OCI reports them, together with the alert '
         'rules attached. A budget with no alert rule is reported as a finding - it tracks spend and '
         'tells nobody.',
    params=CONN_PARAMS + [
        dict(name='TenancyId', help='Tenancy OCID. Budgets live at tenancy level, not in a child compartment.',
             decl="[string]$TenancyId"),
        dict(name='WarnAtPercent', help='Report a budget consumed beyond this percentage.',
             decl="[ValidateRange(1,500)]\n    [int]$WarnAtPercent = 80")],
    perms='An IAM policy allowing BUDGET_INSPECT and USAGE_REPORT read at tenancy level.',
    notes='Spend figures are read from the Budgets API as OCI computed them; nothing is recalculated '
          'here. OCI updates those figures periodically rather than continuously, so a budget crossed '
          'minutes ago may not show it yet.',
    examples=[("-OutputFormat HTML", 'Budget report as HTML.'),
              ("-WarnAtPercent 60", 'Earlier warning threshold.')],
    discover=oci(r"""
if (-not $TenancyId) {
    if ($config -and $config.oci -and $config.oci.tenancyId) { $TenancyId = $config.oci.tenancyId }
}
if (-not $TenancyId) {
    throw 'Budgets are defined at tenancy level. Pass -TenancyId or set oci.tenancyId in config.json.'
}

$listed = Invoke-OciCli -Argument @('budgets', 'budget', 'list', '--compartment-id', $TenancyId, '--all')
$budgets = @($listed.data)

if ($budgets.Count -eq 0) {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
        'No budgets defined in this tenancy. Nothing is tracking spend.')
}

foreach ($b in $budgets) {
    $rules = @()
    try {
        $resp = Invoke-OciCli -Argument @('budgets', 'alert-rule', 'list', '--budget-id', $b.id, '--all')
        $rules = @($resp.data)
    } catch {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $b.'display-name' `
            -Message ('Could not read alert rules: {0}' -f $_.Exception.Message)
    }

    $amount = $b.amount
    $actual = $b.'actual-spend'
    $forecast = $b.'forecasted-spend'
    $pct = if ($amount -and $amount -gt 0 -and $null -ne $actual) { [math]::Round(($actual / $amount) * 100, 1) } else { $null }

    $issues = @()
    if ($rules.Count -eq 0) { $issues += 'NO alert rule - this budget notifies nobody' }
    if ($null -ne $pct -and $pct -ge $WarnAtPercent) { $issues += ('{0}% consumed' -f $pct) }
    if ($null -ne $forecast -and $amount -and $forecast -gt $amount) { $issues += 'forecast exceeds the budget' }

    $results.Add([PSCustomObject]@{
        Name            = $b.'display-name'
        Id              = $b.id
        TargetType      = $b.'target-type'
        Amount          = $amount
        ActualSpend     = $actual
        ForecastSpend   = $forecast
        PercentConsumed = $pct
        ResetPeriod     = $b.'reset-period'
        AlertRuleCount  = $rules.Count
        AlertThresholds = (($rules | ForEach-Object { '{0}{1}' -f $_.threshold, $(if ($_.'threshold-type' -eq 'PERCENTAGE') { '%' } else { '' }) }) -join '; ')
        Status          = if ($issues.Count) { 'Attention' } else { 'OK' }
        Issues          = ($issues -join '; ')
    })

    if ($issues.Count) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $b.'display-name' -Message ($issues -join '; ')
    }
}
""", compartment=False)),

6: dict(
    file='Get-OciCompartmentInventory',
    modules=[],
    synopsis='Inventories every resource in a compartment.',
    desc='Uses the OCI resource search to enumerate resources across a compartment and summarises '
         'them by type and lifecycle state, so an inventory does not depend on knowing in advance '
         'which services are in use.',
    params=CONN_PARAMS + [
        dict(name='IncludeSubcompartments', help='Include compartments beneath the target.',
             decl="[switch]$IncludeSubcompartments"),
        dict(name='ResourceType', help='Limit to these resource types.',
             decl="[string[]]$ResourceType"),
        dict(name='SummaryOnly', help='Report counts by type rather than every individual resource.',
             decl="[switch]$SummaryOnly")],
    perms='An IAM policy allowing read on all-resources in the compartment, plus COMPARTMENT_INSPECT.',
    notes='The resource search indexes most but not all OCI resource types, and the index updates '
          'asynchronously. A resource created seconds ago may not appear yet. This is a search '
          'result, not a billing-grade inventory, and is labelled as such rather than presented as '
          'complete.',
    examples=[("-OutputFormat CSV -OutputPath .\\inventory.csv", 'Full inventory as CSV.'),
              ("-SummaryOnly -IncludeSubcompartments", 'Counts by type across the subtree.')],
    discover=oci(r"""
$compartments = @([PSCustomObject]@{ id = $CompartmentId; name = '(target)' })
if ($IncludeSubcompartments) {
    try {
        $resp = Invoke-OciCli -Argument @('iam', 'compartment', 'list', '--compartment-id', $CompartmentId,
            '--compartment-id-in-subtree', 'true', '--all')
        $compartments += @($resp.data | Where-Object { "$($_.'lifecycle-state')" -eq 'ACTIVE' })
    } catch {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
            'Subcompartment list failed ({0}); reporting the target compartment only.' -f $_.Exception.Message)
    }
}
$compartmentIds = @($compartments | ForEach-Object { $_.id } | Select-Object -Unique)
$nameById = @{}
foreach ($c in $compartments) { $nameById[$c.id] = $c.name }

$found = @()
try {
    $resp = Invoke-OciCli -Argument @('search', 'resource', 'structured-search',
        '--query-text', 'query all resources')
    $found = @($resp.data.items)
} catch {
    throw ('Resource search failed: {0}. This script depends on the search service being available ' +
           'in the region.' -f $_.Exception.Message)
}

$scoped = @($found | Where-Object { $compartmentIds -contains $_.'compartment-id' })
if ($ResourceType) {
    $scoped = @($scoped | Where-Object { $ResourceType -contains $_.'resource-type' })
}

Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
    '{0} resource(s) in scope across {1} compartment(s). Source: resource search index, which ' +
    'updates asynchronously - very recent resources may be absent.' -f $scoped.Count, $compartmentIds.Count)

if ($SummaryOnly) {
    foreach ($g in ($scoped | Group-Object 'resource-type' | Sort-Object Count -Descending)) {
        $states = $g.Group | Group-Object 'lifecycle-state' |
                  ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }
        $results.Add([PSCustomObject]@{
            Name           = $g.Name
            Id             = $g.Name
            ResourceType   = $g.Name
            Count          = $g.Count
            LifecycleStates= ($states -join '; ')
            CompartmentName= ''
            DisplayName    = ''
            TimeCreated    = $null
        })
    }
} else {
    foreach ($r in $scoped) {
        $results.Add([PSCustomObject]@{
            Name           = $r.'display-name'
            Id             = $r.identifier
            ResourceType   = $r.'resource-type'
            Count          = 1
            LifecycleStates= $r.'lifecycle-state'
            CompartmentName= $(if ($nameById.ContainsKey($r.'compartment-id')) { $nameById[$r.'compartment-id'] } else { $r.'compartment-id' })
            DisplayName    = $r.'display-name'
            TimeCreated    = $r.'time-created'
        })
    }
}
""")),

7: dict(
    file='Set-OciResourceTagCompliance',
    modules=[],
    synopsis='Reports resources missing required tags, and optionally applies them.',
    desc='Finds resources that lack the required freeform tags and reports them. With -AutoTag it '
         'applies the default values, which is a metadata-only change. Resource types it has no '
         'updater for are reported as flagged rather than silently counted as compliant.',
    params=CONN_PARAMS + [
        dict(name='RequiredTag',
             help='Required tag keys, optionally with a default value as key=value. A key with no '
                  'default can be reported but not auto-applied.',
             decl="[Parameter(Mandatory)]\n    [string[]]$RequiredTag"),
        dict(name='AutoTag', help='Apply the default values to non-compliant resources.',
             decl="[switch]$AutoTag"),
        dict(name='ResourceType', help='Limit to these resource types.',
             decl="[string[]]$ResourceType")],
    perms='An IAM policy allowing read on all-resources plus manage on the resource types being tagged.',
    actionVerb='Apply required tag',
    rollback='Tags are metadata. Remove or overwrite the applied tag to revert; no resource behaviour '
             'changes as a result of this script.',
    notes='OCI has no single tag-update call. Each resource type has its own update command, so this '
          'script carries an explicit map of the types it can write - instance, block volume, boot '
          'volume, VCN, subnet, bucket. Anything else is REPORTED as non-compliant and marked as '
          'having no updater, which is honest; silently treating it as compliant would not be.',
    examples=[("-RequiredTag CostCenter,Owner", 'Reports resources missing either tag.'),
              ("-RequiredTag 'CostCenter=UNASSIGNED','Owner=itops' -AutoTag -WhatIf",
               'Shows which resources would be tagged.')],
    discover=oci(r"""
$required = @{}
foreach ($t in $RequiredTag) {
    $kv = $t -split '=', 2
    $required[$kv[0]] = if ($kv.Count -eq 2) { $kv[1] } else { $null }
}

# One update command per resource type. A type absent from this map is
# reported, never quietly passed.
$updaters = @{
    'Instance'   = @('compute', 'instance', 'update', '--instance-id')
    'Volume'     = @('bv', 'volume', 'update', '--volume-id')
    'BootVolume' = @('bv', 'boot-volume', 'update', '--boot-volume-id')
    'Vcn'        = @('network', 'vcn', 'update', '--vcn-id')
    'Subnet'     = @('network', 'subnet', 'update', '--subnet-id')
    'Bucket'     = @('os', 'bucket', 'update', '--bucket-name')
}

$resp = Invoke-OciCli -Argument @('search', 'resource', 'structured-search', '--query-text', 'query all resources')
$found = @($resp.data.items | Where-Object { $_.'compartment-id' -eq $CompartmentId })
if ($ResourceType) {
    $found = @($found | Where-Object { $ResourceType -contains $_.'resource-type' })
}

foreach ($r in $found) {
    $tags = $r.'freeform-tags'
    $missing = @()
    foreach ($key in $required.Keys) {
        $have = if ($tags) { $tags.$key } else { $null }
        if (-not $have) { $missing += $key }
    }
    if ($missing.Count -eq 0) { continue }

    $type = "$($r.'resource-type')"
    $canUpdate = $updaters.ContainsKey($type)
    $appliable = @($missing | Where-Object { $required[$_] })

    $results.Add([PSCustomObject]@{
        Name          = $r.'display-name'
        Id            = $r.identifier
        ResourceId    = $r.identifier
        ResourceType  = $type
        MissingTags   = ($missing -join '; ')
        AppliableTags = ($appliable -join '; ')
        ExistingTags  = if ($tags) { (($tags.PSObject.Properties | ForEach-Object { '{0}={1}' -f $_.Name, $_.Value }) -join '; ') } else { '' }
        HasUpdater    = $canUpdate
        Actionable    = ($canUpdate -and $AutoTag -and $appliable.Count -gt 0)
        Note          = if (-not $canUpdate) { ('REPORTED ONLY - no update command mapped for resource type {0}' -f $type) }
                        elseif (-not $AutoTag) { 'Reported only - pass -AutoTag to apply' }
                        elseif ($appliable.Count -eq 0) { 'No default value supplied for the missing tag(s); cannot auto-apply' }
                        else { '' }
    })
}

# Only actionable rows reach the change loop; everything else stays in the log.
$notActionable = @($results | Where-Object { -not $_.Actionable })
if ($notActionable.Count -gt 0) {
    foreach ($n in $notActionable) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $n.Name -Message $n.Note
    }
}
"""),
    act=r"""
if (-not $item.Actionable) {
    $actions.Add([PSCustomObject]@{
        Name = $item.Name; Action = 'ReportedOnly'; Detail = $item.Note; Succeeded = $true })
} else {
    $updaters = @{
        'Instance'   = @('compute', 'instance', 'update', '--instance-id')
        'Volume'     = @('bv', 'volume', 'update', '--volume-id')
        'BootVolume' = @('bv', 'boot-volume', 'update', '--boot-volume-id')
        'Vcn'        = @('network', 'vcn', 'update', '--vcn-id')
        'Subnet'     = @('network', 'subnet', 'update', '--subnet-id')
        'Bucket'     = @('os', 'bucket', 'update', '--bucket-name')
    }

    # Merge onto the existing tags; --freeform-tags replaces the whole map.
    $merged = @{}
    foreach ($pair in ($item.ExistingTags -split ';')) {
        $kv = $pair.Trim() -split '=', 2
        if ($kv.Count -eq 2 -and $kv[0]) { $merged[$kv[0]] = $kv[1] }
    }
    foreach ($key in ($item.AppliableTags -split ';')) {
        $k = $key.Trim()
        if ($k) { $merged[$k] = $required[$k] }
    }

    $updateArgs = @($updaters[$item.ResourceType]) + @($item.ResourceId,
        '--freeform-tags', ($merged | ConvertTo-Json -Compress), '--force')
    Invoke-OciCli -Argument $updateArgs | Out-Null

    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
        'Tags applied: {0}' -f $item.AppliableTags)
    $actions.Add([PSCustomObject]@{
        Name = $item.Name; Action = 'Tagged'; Detail = $item.AppliableTags; Succeeded = $true })
}
"""),

8: dict(
    file='Get-OciIamAudit',
    modules=[],
    synopsis='Audits OCI IAM users, group memberships and credentials.',
    desc='Reports every IAM user with their group memberships, MFA state and credential inventory, '
         'flagging the combinations that matter: no MFA, API keys older than a rotation threshold, '
         'and accounts that have never signed in.',
    params=CONN_PARAMS + [
        dict(name='TenancyId', help='Tenancy OCID. IAM users live at tenancy level.',
             decl="[string]$TenancyId"),
        dict(name='ApiKeyMaxAgeDays', help='Flag API keys older than this.',
             decl="[ValidateRange(1,3650)]\n    [int]$ApiKeyMaxAgeDays = 90"),
        dict(name='IssuesOnly', help='Report only users with at least one finding.',
             decl="[switch]$IssuesOnly")],
    perms='An IAM policy allowing USER_INSPECT, GROUP_INSPECT and read on all IAM resources at '
          'tenancy level.',
    notes='Federated users are managed in the identity provider, not in OCI IAM, so their MFA state '
          'is not visible here. A federated user showing "no MFA" means OCI has no record of one, '
          'which is not the same as there being none - the report says so rather than asserting a '
          'gap that may not exist.',
    examples=[("-OutputFormat HTML", 'Full IAM audit as HTML.'),
              ("-IssuesOnly -ApiKeyMaxAgeDays 60", 'Only users with findings, tighter key age.')],
    discover=oci(r"""
if (-not $TenancyId) {
    if ($config -and $config.oci -and $config.oci.tenancyId) { $TenancyId = $config.oci.tenancyId }
}
if (-not $TenancyId) {
    throw 'IAM users live at tenancy level. Pass -TenancyId or set oci.tenancyId in config.json.'
}

$users = @((Invoke-OciCli -Argument @('iam', 'user', 'list', '--compartment-id', $TenancyId, '--all')).data)
$groups = @((Invoke-OciCli -Argument @('iam', 'group', 'list', '--compartment-id', $TenancyId, '--all')).data)
$groupNameById = @{}
foreach ($g in $groups) { $groupNameById[$g.id] = $g.name }

$keyCutoff = (Get-Date).AddDays(-$ApiKeyMaxAgeDays)

foreach ($u in $users) {
    $memberships = @()
    try {
        $resp = Invoke-OciCli -Argument @('iam', 'user', 'list-groups', '--user-id', $u.id, '--all')
        $memberships = @($resp.data | ForEach-Object { $_.name })
    } catch {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $u.name `
            -Message ('Group membership unreadable: {0}' -f $_.Exception.Message)
    }

    $apiKeys = @()
    try { $apiKeys = @((Invoke-OciCli -Argument @('iam', 'user', 'api-key', 'list', '--user-id', $u.id)).data) } catch {
        Write-Verbose ('No API keys readable for {0}' -f $u.name)
    }
    $authTokens = @()
    try { $authTokens = @((Invoke-OciCli -Argument @('iam', 'auth-token', 'list', '--user-id', $u.id)).data) } catch {
        Write-Verbose ('No auth tokens readable for {0}' -f $u.name)
    }

    $staleKeys = @($apiKeys | Where-Object {
        $_.'time-created' -and ([datetime]$_.'time-created') -lt $keyCutoff
    })

    $isFederated = "$($u.'identity-provider-id')" -ne ''
    $issues = @()
    if (-not $u.'is-mfa-activated') {
        $issues += if ($isFederated) { 'no MFA recorded in OCI (federated - check the IdP)' } else { 'MFA not enabled' }
    }
    if ($staleKeys.Count -gt 0) { $issues += ('{0} API key(s) older than {1}d' -f $staleKeys.Count, $ApiKeyMaxAgeDays) }
    if ($memberships.Count -eq 0) { $issues += 'no group membership - cannot do anything, or is a leftover' }
    if ("$($u.'lifecycle-state')" -ne 'ACTIVE') { $issues += ('lifecycle state {0}' -f $u.'lifecycle-state') }

    if ($IssuesOnly -and $issues.Count -eq 0) { continue }

    $results.Add([PSCustomObject]@{
        Name           = $u.name
        Id             = $u.id
        Description    = $u.description
        Email          = $u.email
        EmailVerified  = $u.'email-verified'
        LifecycleState = $u.'lifecycle-state'
        IsFederated    = $isFederated
        MfaActivated   = $u.'is-mfa-activated'
        Groups         = ($memberships -join '; ')
        GroupCount     = $memberships.Count
        ApiKeyCount    = $apiKeys.Count
        StaleApiKeys   = $staleKeys.Count
        AuthTokenCount = $authTokens.Count
        TimeCreated    = $u.'time-created'
        Status         = if ($issues.Count) { 'Attention' } else { 'OK' }
        Issues         = ($issues -join '; ')
    })

    if ($issues.Count) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $u.name -Message ($issues -join '; ')
    }
}
""", compartment=False)),

9: dict(
    file='Get-OciNetworkRuleReview',
    modules=[],
    synopsis='Reports overly permissive OCI security list and NSG rules.',
    desc='Reviews security lists and network security groups for ingress rules open to the internet, '
         'and ranks them by what the rule actually exposes. A 0.0.0.0/0 rule on an administrative port '
         'is a different finding from one on 443, and they are not reported the same way.',
    params=CONN_PARAMS + [
        dict(name='VcnId', help='Limit to these VCNs.',
             decl="[string[]]$VcnId"),
        dict(name='SensitivePort',
             help='Ports treated as administrative or high-risk when exposed to the internet.',
             decl="[int[]]$SensitivePort = @(22,23,135,139,445,1433,1521,3306,3389,5432,5900,6379,9200,27017)"),
        dict(name='OpenCidr', help='CIDRs considered "open to the world".',
             decl="[string[]]$OpenCidr = @('0.0.0.0/0','::/0')")],
    perms='An IAM policy allowing VCN_INSPECT, SECURITY_LIST_INSPECT and NSG read in the compartment.',
    notes='REPORT ONLY - nothing is changed. Whether a permissive rule is wrong depends on what sits '
          'behind it: a 0.0.0.0/0 rule on 443 in front of a public web tier is the design, and the '
          'same rule on 3389 almost never is. The report ranks by exposure and leaves the decision '
          'to a network owner.',
    examples=[("-OutputFormat HTML", 'Full rule review as HTML.'),
              ("-VcnId ocid1.vcn... -SensitivePort 22,3389", 'One VCN, two ports of interest.')],
    discover=oci(r"""
$vcns = @((Invoke-OciCli -Argument @('network', 'vcn', 'list', '--compartment-id', $CompartmentId, '--all')).data)
if ($VcnId) { $vcns = @($vcns | Where-Object { $VcnId -contains $_.id }) }

function Test-OciOpenRule {
    <#
        .SYNOPSIS
            Classifies one ingress rule as open, and how badly.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param($Rule, [string[]]$OpenCidrList, [int[]]$SensitivePortList)

    $source = "$($Rule.source)"
    $isOpen = $OpenCidrList -contains $source
    if (-not $isOpen) { return $null }

    $proto = "$($Rule.protocol)"
    $protoName = switch ($proto) { '1' { 'ICMP' } '6' { 'TCP' } '17' { 'UDP' } 'all' { 'ALL' } default { $proto } }

    $portText = 'all'
    $hitPorts = @()
    $range = $null
    if ($Rule.'tcp-options')      { $range = $Rule.'tcp-options'.'destination-port-range' }
    elseif ($Rule.'udp-options')  { $range = $Rule.'udp-options'.'destination-port-range' }

    if ($range -and $null -ne $range.min) {
        $portText = if ($range.min -eq $range.max) { "$($range.min)" } else { '{0}-{1}' -f $range.min, $range.max }
        $hitPorts = @($SensitivePortList | Where-Object { $_ -ge $range.min -and $_ -le $range.max })
    } else {
        # No port restriction means every sensitive port is reachable.
        $hitPorts = @($SensitivePortList)
    }

    $severity = if ($protoName -eq 'ALL' -or $portText -eq 'all') { 'Critical' }
                elseif ($hitPorts.Count -gt 0) { 'High' }
                else { 'Review' }

    [PSCustomObject]@{
        Source = $source; Protocol = $protoName; Ports = $portText
        SensitivePortsExposed = ($hitPorts -join ','); Severity = $severity
    }
}

foreach ($vcn in $vcns) {
    foreach ($sl in @((Invoke-OciCli -Argument @('network', 'security-list', 'list',
                        '--compartment-id', $CompartmentId, '--vcn-id', $vcn.id, '--all')).data)) {
        $idx = 0
        foreach ($rule in @($sl.'ingress-security-rules')) {
            $idx++
            $finding = Test-OciOpenRule -Rule $rule -OpenCidrList $OpenCidr -SensitivePortList $SensitivePort
            if (-not $finding) { continue }

            $results.Add([PSCustomObject]@{
                Name        = ('{0} / {1} rule {2}' -f $vcn.'display-name', $sl.'display-name', $idx)
                Id          = $sl.id
                VcnName     = $vcn.'display-name'
                Container   = $sl.'display-name'
                ContainerType = 'SecurityList'
                RuleIndex   = $idx
                Source      = $finding.Source
                Protocol    = $finding.Protocol
                Ports       = $finding.Ports
                SensitivePortsExposed = $finding.SensitivePortsExposed
                Stateless   = $rule.'is-stateless'
                Severity    = $finding.Severity
                RuleDescription = $rule.description
                OwnerDecision = 'Whether this exposure is intended depends on what is behind it - network owner judgement'
            })
        }
    }

    foreach ($nsg in @((Invoke-OciCli -Argument @('network', 'nsg', 'list',
                        '--compartment-id', $CompartmentId, '--vcn-id', $vcn.id, '--all')).data)) {
        $rules = @()
        try { $rules = @((Invoke-OciCli -Argument @('network', 'nsg', 'rules', 'list', '--nsg-id', $nsg.id, '--all')).data) } catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $nsg.'display-name' `
                -Message ('NSG rules unreadable: {0}' -f $_.Exception.Message)
            continue
        }

        foreach ($rule in ($rules | Where-Object { "$($_.direction)" -eq 'INGRESS' })) {
            $finding = Test-OciOpenRule -Rule $rule -OpenCidrList $OpenCidr -SensitivePortList $SensitivePort
            if (-not $finding) { continue }

            $results.Add([PSCustomObject]@{
                Name        = ('{0} / {1} / {2}' -f $vcn.'display-name', $nsg.'display-name', $rule.id)
                Id          = $nsg.id
                VcnName     = $vcn.'display-name'
                Container   = $nsg.'display-name'
                ContainerType = 'NSG'
                RuleIndex   = $rule.id
                Source      = $finding.Source
                Protocol    = $finding.Protocol
                Ports       = $finding.Ports
                SensitivePortsExposed = $finding.SensitivePortsExposed
                Stateless   = $rule.'is-stateless'
                Severity    = $finding.Severity
                RuleDescription = $rule.description
                OwnerDecision = 'Whether this exposure is intended depends on what is behind it - network owner judgement'
            })
        }
    }
}

foreach ($critical in ($results | Where-Object { $_.Severity -eq 'Critical' })) {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $critical.Name -Message (
        'Open to {0} on {1}/{2}' -f $critical.Source, $critical.Protocol, $critical.Ports)
}
""")),

10: dict(
    file='Set-OciAutonomousDbState',
    modules=[],
    synopsis='Starts or stops OCI Autonomous Databases on a schedule.',
    desc='Starts or stops Autonomous Databases selected by tag, so a dev environment can be shut '
         'down outside working hours. Selection is deliberately tag-driven: a production database '
         'without the schedule tag is never a candidate.',
    params=CONN_PARAMS + [
        dict(name='Action', help='Power action.',
             decl="[Parameter(Mandatory)]\n    [ValidateSet('START','STOP')]\n    [string]$Action"),
        dict(name='TagKey', help='Freeform tag key identifying schedulable databases.',
             decl="[string]$TagKey = 'schedule'"),
        dict(name='TagValue', help='Required value for -TagKey.',
             decl="[string]$TagValue = 'dev'"),
        dict(name='DatabaseName', help='Act on these display names instead of the tag selection.',
             decl="[string[]]$DatabaseName")],
    perms='An IAM policy allowing AUTONOMOUS_DATABASE_CONTENT_READ and the START/STOP actions in the '
          'compartment.',
    actionVerb='Power action on Autonomous DB',
    rollback='Fully reversible - START undoes STOP. Sessions are terminated by a stop, so in-flight '
             'work is lost even though the data is not.',
    notes='Stopping an Autonomous Database terminates connected sessions. That is fine for the dev '
          'environments this is intended for and is not fine anywhere else, which is why selection '
          'is by tag rather than by compartment. -DatabaseName exists for a named one-off and '
          'bypasses the tag filter deliberately and visibly.',
    examples=[("-Action STOP -TagKey schedule -TagValue dev",
               'Stops every database tagged schedule=dev.'),
              ("-Action START -DatabaseName DEVADW01 -WhatIf", 'Shows the named database that would start.')],
    discover=oci(r"""
$dbs = @((Invoke-OciCli -Argument @('db', 'autonomous-database', 'list',
    '--compartment-id', $CompartmentId, '--all')).data)

foreach ($db in $dbs) {
    $state = "$($db.'lifecycle-state')"
    if ($state -match '(?i)terminat') { continue }

    if ($DatabaseName) {
        if ($DatabaseName -notcontains $db.'display-name') { continue }
    } else {
        $tags = $db.'freeform-tags'
        if (-not $tags -or "$($tags.$TagKey)" -ne $TagValue) { continue }
    }

    $alreadyThere = ($Action -eq 'START' -and $state -eq 'AVAILABLE') -or
                    ($Action -eq 'STOP' -and $state -eq 'STOPPED')
    if ($alreadyThere) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $db.'display-name' `
            -Message ('Skipped - already {0}' -f $state)
        continue
    }
    if ($state -notin 'AVAILABLE', 'STOPPED') {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $db.'display-name' `
            -Message ('Skipped - lifecycle state {0} is not a safe starting point for a power action' -f $state)
        continue
    }

    $results.Add([PSCustomObject]@{
        Name           = $db.'display-name'
        Id             = $db.id
        DatabaseId     = $db.id
        DbName         = $db.'db-name'
        LifecycleState = $state
        Action         = $Action
        CpuCoreCount   = $db.'cpu-core-count'
        DataStorageTB  = $db.'data-storage-size-in-tbs'
        IsFreeTier     = $db.'is-free-tier'
        SelectedBy     = if ($DatabaseName) { 'explicit -DatabaseName' } else { ('tag {0}={1}' -f $TagKey, $TagValue) }
        Impact         = if ($Action -eq 'STOP') { 'Terminates connected sessions' } else { '' }
    })
}
"""),
    act=r"""
$verb = if ($item.Action -eq 'START') { 'start' } else { 'stop' }
Invoke-OciCli -Argument @('db', 'autonomous-database', $verb,
    '--autonomous-database-id', $item.DatabaseId) | Out-Null

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    '{0} issued (was {1}, selected by {2}){3}' -f
    $item.Action, $item.LifecycleState, $item.SelectedBy,
    $(if ($item.Action -eq 'STOP') { ' - connected sessions terminated' } else { '' }))
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = $item.Action
    Detail = ('was {0}' -f $item.LifecycleState); Succeeded = $true })
"""),

11: dict(
    file='Get-OciLoadBalancerHealth',
    modules=[],
    synopsis='Reports OCI load balancer backend health and certificate expiry.',
    desc='Reports each load balancer with the health of its backend sets and the expiry date of the '
         'certificates it presents. Both are outage causes; a certificate that expires overnight '
         'takes a healthy backend down just as effectively as a failed one.',
    params=CONN_PARAMS + [
        dict(name='LoadBalancerName', help='Limit to these load balancers.',
             decl="[string[]]$LoadBalancerName"),
        dict(name='CertificateWarnDays', help='Warn on certificates expiring within this many days.',
             decl="[ValidateRange(1,365)]\n    [int]$CertificateWarnDays = 30"),
        dict(name='IssuesOnly', help='Report only load balancers with a finding.',
             decl="[switch]$IssuesOnly")],
    perms='An IAM policy allowing LOAD_BALANCER_INSPECT in the compartment.',
    notes='Backend health is read from the load balancer health API, which reports the balancer\'s own '
          'view. A backend marked OK still only means the health check passed - it says nothing about '
          'whether the application behind it is returning correct answers.',
    examples=[("-OutputFormat HTML", 'Load balancer health and certificate report.'),
              ("-IssuesOnly -CertificateWarnDays 14", 'Only problems, tighter certificate window.')],
    discover=oci(r"""
$lbs = @((Invoke-OciCli -Argument @('lb', 'load-balancer', 'list', '--compartment-id', $CompartmentId, '--all')).data)
if ($LoadBalancerName) { $lbs = @($lbs | Where-Object { $LoadBalancerName -contains $_.'display-name' }) }
$certCutoff = (Get-Date).AddDays($CertificateWarnDays)

foreach ($lb in $lbs) {
    $issues = @()

    $health = $null
    try { $health = (Invoke-OciCli -Argument @('lb', 'load-balancer-health', 'get', '--load-balancer-id', $lb.id)).data } catch {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $lb.'display-name' `
            -Message ('Health unavailable: {0}' -f $_.Exception.Message)
    }
    if ($health) {
        $status = "$($health.status)"
        if ($status -ne 'OK') { $issues += ('overall health {0}' -f $status) }
        if (@($health.'critical-state-backend-set-names').Count -gt 0) {
            $issues += ('backend sets CRITICAL: {0}' -f (@($health.'critical-state-backend-set-names') -join ','))
        }
        if (@($health.'warning-state-backend-set-names').Count -gt 0) {
            $issues += ('backend sets WARNING: {0}' -f (@($health.'warning-state-backend-set-names') -join ','))
        }
    }

    $certSummary = @()
    $certs = @()
    try { $certs = @((Invoke-OciCli -Argument @('lb', 'certificate', 'list', '--load-balancer-id', $lb.id)).data) } catch {
        Write-Verbose ('No certificates readable on {0}' -f $lb.'display-name')
    }
    foreach ($cert in $certs) {
        # The listing returns the PEM; the expiry has to come out of the
        # certificate itself rather than a field.
        $expiry = $null
        if ($cert.'public-certificate') {
            try {
                $pem = "$($cert.'public-certificate')" -replace '-----BEGIN CERTIFICATE-----', '' -replace '-----END CERTIFICATE-----', ''
                $bytes = [System.Convert]::FromBase64String(($pem -replace '\s', ''))
                $x509 = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($bytes)
                $expiry = $x509.NotAfter
            } catch {
                Write-Verbose ('Certificate {0} on {1} could not be parsed' -f $cert.'certificate-name', $lb.'display-name')
            }
        }
        $certSummary += ('{0}{1}' -f $cert.'certificate-name', $(if ($expiry) { ' expires ' + $expiry.ToString('yyyy-MM-dd') } else { ' (expiry not parseable)' }))
        if ($expiry -and $expiry -lt $certCutoff) {
            $issues += ('certificate {0} expires {1:yyyy-MM-dd}' -f $cert.'certificate-name', $expiry)
        }
    }

    if ($IssuesOnly -and $issues.Count -eq 0) { continue }

    $results.Add([PSCustomObject]@{
        Name          = $lb.'display-name'
        Id            = $lb.id
        LifecycleState= $lb.'lifecycle-state'
        ShapeName     = $lb.'shape-name'
        IsPrivate     = $lb.'is-private'
        IpAddresses   = ((@($lb.'ip-addresses') | ForEach-Object { $_.'ip-address' }) -join '; ')
        OverallHealth = if ($health) { $health.status } else { 'unavailable' }
        BackendSetsTotal = @($lb.'backend-sets'.PSObject.Properties).Count
        BackendSetsCritical = (@($health.'critical-state-backend-set-names') -join '; ')
        BackendSetsWarning  = (@($health.'warning-state-backend-set-names') -join '; ')
        Certificates  = ($certSummary -join '; ')
        Status        = if ($issues.Count) { 'Attention' } else { 'OK' }
        Issues        = ($issues -join '; ')
    })

    if ($issues.Count) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $lb.'display-name' -Message ($issues -join '; ')
    }
}
""")),

12: dict(
    file='Install-OciPatchUpdate',
    modules=[],
    synopsis='Applies OS patches to OCI managed instances, after a pre-patch snapshot.',
    desc='Installs available package updates on OS Management managed instances. A boot volume '
         'backup is taken before each instance is patched, because the guardrail requires a '
         'pre-snapshot and a patch run without a rollback point is not a change-window activity.',
    params=CONN_PARAMS + [
        dict(name='InstanceName', help='Instance display name(s) to patch.',
             decl="[string[]]$InstanceName"),
        dict(name='UpdateType', help='Class of update to install.',
             decl="[ValidateSet('SECURITY','BUGFIX','ENHANCEMENT','ALL')]\n    [string]$UpdateType = 'SECURITY'"),
        dict(name='OsManagementService',
             help='Which OS Management service this tenancy uses. The newer Hub service and the '
                  'legacy service have different CLI command groups.',
             decl="[ValidateSet('os-management-hub','os-management')]\n    [string]$OsManagementService = 'os-management-hub'"),
        dict(name='SkipPreSnapshot',
             help='Patch without taking a boot volume backup first. Logged as a WARN; the guardrail '
                  'on this use case asks for a pre-snapshot.',
             decl="[switch]$SkipPreSnapshot")],
    perms='An IAM policy allowing the OS Management instance actions plus BOOT_VOLUME_BACKUP_CREATE '
          'for the pre-snapshot.',
    actionVerb='Patch managed instance',
    reason='Scheduled OS patching within an approved change window',
    rollback='Create a new boot volume from the pre-patch backup this script takes and attach it in '
             'place of the current one. That is why -SkipPreSnapshot is a deliberate act rather than '
             'a default.',
    notes='Two OS Management services exist in OCI - the newer OS Management Hub and the legacy OS '
          'Management service - and they use different CLI command groups. Which one applies depends '
          'on the tenancy, so it is a PARAMETER rather than a guess. Set it once for your environment. '
          'Patching may reboot the instance depending on the packages involved; this script does not '
          'suppress or force a reboot.',
    examples=[("-InstanceName APP01 -UpdateType SECURITY",
               'REPORT ONLY. Lists pending updates and raises an approval.'),
              ("-InstanceName APP01 -UpdateType SECURITY -ApprovalReference APR-... -TicketReference CHG0012345",
               'Snapshots and patches an approved instance.')],
    discover=oci(r"""
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
"""),
    act=r"""
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
"""),

13: dict(
    file='Set-OciObjectLifecyclePolicy',
    modules=[],
    synopsis='Applies Object Storage lifecycle rules, with deletion rules gated.',
    desc='Applies lifecycle rules to Object Storage buckets from a rules file. Archive and tiering '
         'rules move objects; DELETE rules destroy them permanently once the age threshold passes, '
         'so a rule set containing any deletion rule is refused until it has been explicitly '
         'reviewed.',
    params=CONN_PARAMS + [
        dict(name='BucketName', help='Bucket(s) to apply the policy to.',
             decl="[Parameter(Mandatory)]\n    [string[]]$BucketName"),
        dict(name='RulesFile', help='JSON file containing the lifecycle rule items.',
             decl="[Parameter(Mandatory)]\n    [string]$RulesFile"),
        dict(name='DeletionRulesReviewed',
             help='Confirms that every DELETE rule in the file has been reviewed and the data loss '
                  'it will cause is intended. Required if the file contains any deletion rule.',
             decl="[switch]$DeletionRulesReviewed"),
        dict(name='Namespace', help='Object Storage namespace. Resolved from the tenancy when omitted.',
             decl="[string]$Namespace")],
    minage=0,
    perms='An IAM policy allowing OBJECTSTORAGE_BUCKET_UPDATE and read on the buckets.',
    actionVerb='Apply lifecycle policy',
    reason='Object Storage lifecycle management',
    rollback='The previous policy is captured and logged before the new one is written, so it can be '
             're-applied. Objects ALREADY DELETED by a prior rule are not recoverable.',
    notes='DESTRUCTIVE, on a delay. A lifecycle DELETE rule does not destroy anything at the moment '
          'it is applied - it destroys objects continuously from then on, without further approval, '
          'as they age past the threshold. That is why the review flag gates the rule set rather '
          'than an individual delete call: the approval is for a standing instruction, not a single '
          'action.',
    examples=[("-BucketName logs-archive -RulesFile .\\lifecycle.json",
               'REPORT ONLY. Shows current vs proposed rules and raises an approval.'),
              ("-BucketName logs-archive -RulesFile .\\lifecycle.json -DeletionRulesReviewed -ApprovalReference APR-... -Execute",
               'Applies a reviewed rule set containing deletion rules.')],
    discover=oci(r"""
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
"""),
    act=r"""
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
"""),

14: dict(
    file='Get-OciVcnFlowLogAnomaly',
    modules=[],
    synopsis='Surfaces anomalies in OCI VCN flow logs for analyst review.',
    desc='Runs a set of queries against VCN flow logs and ranks what comes back: rejected-traffic '
         'concentrations, top talkers by volume, and connections on unusual ports. Every finding '
         'carries a note on why it might be benign. Deciding whether any of it is an incident is an '
         'analyst\'s job and is not attempted here.',
    params=CONN_PARAMS + [
        dict(name='LogGroupId', help='Logging log group containing the VCN flow logs.',
             decl="[Parameter(Mandatory)]\n    [string]$LogGroupId"),
        dict(name='LookbackHours', help='Query window.',
             decl="[ValidateRange(1,168)]\n    [int]$LookbackHours = 24"),
        dict(name='MinimumRejects', help='Report a source with at least this many rejected connections.',
             decl="[ValidateRange(1,100000)]\n    [int]$MinimumRejects = 50"),
        dict(name='MaxResults', help='Ceiling on log records retrieved per query.',
             decl="[ValidateRange(10,50000)]\n    [int]$MaxResults = 5000")],
    perms='An IAM policy allowing LOG_GROUP_INSPECT and read on the log content.',
    notes='AGENT-ASSIST ONLY. Flow log volume makes manual review impractical, which is what this '
          'automates; separating a real threat from a misconfigured health check is not automatable '
          'and is deliberately left alone. Every finding carries an AnalystNote giving the benign '
          'explanation, because a ranked list with no counter-argument reads as a list of incidents.',
    examples=[("-LogGroupId ocid1.loggroup... -LookbackHours 24",
               'Daily anomaly package for analyst review.'),
              ("-LogGroupId ocid1.loggroup... -MinimumRejects 200 -OutputFormat HTML",
               'Higher threshold, HTML output.')],
    discover=oci(r"""
$end = Get-Date
$start = $end.AddHours(-$LookbackHours)
$startIso = $start.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$endIso = $end.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

$records = @()
try {
    $query = 'search "{0}/{1}"' -f $CompartmentId, $LogGroupId
    $resp = Invoke-OciCli -Argument @('logging-search', 'search-logs',
        '--search-query', $query,
        '--time-start', $startIso, '--time-end', $endIso,
        '--limit', "$MaxResults")
    $records = @($resp.data.results)
} catch {
    throw ('Log search failed: {0}. Confirm the log group OCID and that flow logs are enabled on ' +
           'the subnets of interest.' -f $_.Exception.Message)
}

if ($records.Count -eq 0) {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
        'No flow log records returned for the window. Either there was no traffic, or flow logging ' +
        'is not enabled on the subnets - those are very different situations and this query cannot ' +
        'tell them apart.')
}
if ($records.Count -ge $MaxResults) {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
        'Hit the -MaxResults ceiling of {0}. The analysis below is based on a TRUNCATED sample and ' +
        'the rankings may not reflect the full window.' -f $MaxResults)
}

$flows = @()
foreach ($rec in $records) {
    $d = $rec.data
    if (-not $d) { continue }
    $flows += [PSCustomObject]@{
        Source      = "$($d.sourceAddress)"
        Destination = "$($d.destinationAddress)"
        Port        = "$($d.destinationPort)"
        Action      = "$($d.action)"
        Bytes       = [int64]("0" + "$($d.bytesOut)")
        Packets     = [int64]("0" + "$($d.packets)")
    }
}

# --- rejected traffic concentrations ---------------------------------
foreach ($g in ($flows | Where-Object { $_.Action -match '(?i)reject|deny|drop' } |
                Group-Object Source | Where-Object { $_.Count -ge $MinimumRejects } |
                Sort-Object Count -Descending | Select-Object -First 25)) {
    $ports = @($g.Group.Port | Group-Object | Sort-Object Count -Descending | Select-Object -First 5)
    $results.Add([PSCustomObject]@{
        Name        = ('Rejected traffic from {0}' -f $g.Name)
        Id          = ('reject-{0}' -f $g.Name)
        Finding     = 'RejectedConcentration'
        Source      = $g.Name
        Destination = ''
        Ports       = (($ports | ForEach-Object { '{0}({1})' -f $_.Name, $_.Count }) -join '; ')
        EventCount  = $g.Count
        Bytes       = ($g.Group | Measure-Object Bytes -Sum).Sum
        AnalystNote = 'Could be a scan, or a decommissioned client still retrying, or a health check ' +
                      'against a port that moved. Check whether the source is one of yours before treating it as hostile.'
    })
}

# --- top talkers by volume -------------------------------------------
foreach ($g in ($flows | Where-Object { $_.Action -match '(?i)accept|allow' } |
                Group-Object Source | Sort-Object { ($_.Group | Measure-Object Bytes -Sum).Sum } -Descending |
                Select-Object -First 10)) {
    $sum = ($g.Group | Measure-Object Bytes -Sum).Sum
    $results.Add([PSCustomObject]@{
        Name        = ('Top talker {0}' -f $g.Name)
        Id          = ('talker-{0}' -f $g.Name)
        Finding     = 'TopTalker'
        Source      = $g.Name
        Destination = (($g.Group.Destination | Select-Object -Unique | Select-Object -First 3) -join '; ')
        Ports       = (($g.Group.Port | Group-Object | Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object { $_.Name }) -join '; ')
        EventCount  = $g.Count
        Bytes       = $sum
        AnalystNote = 'Volume alone is not suspicious. Backup, replication and log shipping all look ' +
                      'like this. Compare against what this host is supposed to do.'
    })
}

# --- unusual destination ports ---------------------------------------
$commonPorts = @('22','53','80','123','443','445','3306','1521','5432','8080','8443')
foreach ($g in ($flows | Where-Object { $_.Action -match '(?i)accept|allow' -and $commonPorts -notcontains $_.Port } |
                Group-Object Port | Sort-Object Count -Descending | Select-Object -First 15)) {
    $results.Add([PSCustomObject]@{
        Name        = ('Unusual port {0}' -f $g.Name)
        Id          = ('port-{0}' -f $g.Name)
        Finding     = 'UnusualPort'
        Source      = (($g.Group.Source | Select-Object -Unique | Select-Object -First 5) -join '; ')
        Destination = (($g.Group.Destination | Select-Object -Unique | Select-Object -First 5) -join '; ')
        Ports       = $g.Name
        EventCount  = $g.Count
        Bytes       = ($g.Group | Measure-Object Bytes -Sum).Sum
        AnalystNote = 'Unusual only relative to a fixed common-port list. Application-specific ports ' +
                      'and ephemeral ranges land here routinely.'
    })
}
""")),

15: dict(
    file='Invoke-OciDrPlanExecution',
    modules=[],
    synopsis='Executes an OCI Full Stack DR plan and collects drill evidence.',
    desc='Runs a DR plan execution and gathers the per-step evidence a drill needs for its record. '
         'The go/no-go decision beforehand and the assessment of the results afterwards are DR '
         'governance, belong to a human, and are not made here.',
    params=CONN_PARAMS + [
        dict(name='DrPlanId', help='OCID of the DR plan to execute.',
             decl="[Parameter(Mandatory)]\n    [string]$DrPlanId"),
        dict(name='GoDecisionBy',
             help='Name of the person who gave the go decision for this drill. Recorded in the '
                  'evidence pack and required - a drill with no named owner is not a governed drill.',
             decl="[Parameter(Mandatory)]\n    [string]$GoDecisionBy"),
        dict(name='FailoverAuthorized',
             help='Required when the plan is a FAILOVER rather than a drill or switchover. A '
                  'failover plan moves production.',
             decl="[switch]$FailoverAuthorized"),
        dict(name='DrCliGroup',
             help='PLACEHOLDER - the CLI command group for the DR service. Verify against your CLI '
                  'version. Listed in MANIFEST.md under Needs Input.',
             decl="[string]$DrCliGroup = 'disaster-recovery'"),
        dict(name='EvidencePath', help='Directory to write the evidence pack to.',
             decl="[string]$EvidencePath")],
    minage=0,
    perms='An IAM policy allowing DR_PLAN_EXECUTION_CREATE and inspect on the DR protection groups.',
    actionVerb='Execute DR plan',
    reason='Scheduled DR drill',
    rollback='Depends entirely on the plan type. A DRILL plan is designed to be non-disruptive and '
             'is cleaned up by its own steps. A SWITCHOVER is reversed by switching back. A FAILOVER '
             'has moved production and there is no undo - that is why it needs a second flag.',
    notes='ASSIST-ONLY AND DESTRUCTIVE. The mechanical part - executing the runbook and collecting '
          'step-level evidence - is exactly what should be automated, and a drill run by hand '
          'produces worse evidence than one run by script. The judgement parts are not automated at '
          'all: whether to proceed, and whether the result counts as a pass. -GoDecisionBy records '
          'who made the first call; the second is left entirely to the drill review. The plan TYPE is '
          'read before execution and a FAILOVER plan is refused without -FailoverAuthorized, because '
          'the difference between a drill and moving production is one plan selection.',
    examples=[("-DrPlanId ocid1.drplan... -GoDecisionBy 'A. Rahman'",
               'REPORT ONLY. Reads the plan, shows the steps and raises an approval.'),
              ("-DrPlanId ocid1.drplan... -GoDecisionBy 'A. Rahman' -ApprovalReference APR-... -Execute",
               'Executes an approved drill and writes the evidence pack.')],
    discover=oci(r"""
$plan = $null
try {
    $plan = (Invoke-OciCli -Argument @($DrCliGroup, 'dr-plan', 'get', '--dr-plan-id', $DrPlanId)).data
} catch {
    throw ('Could not read DR plan {0}: {1}. If the command group is wrong for your CLI version, ' +
           'pass -DrCliGroup.' -f $DrPlanId, $_.Exception.Message)
}
if (-not $plan) { throw ('DR plan {0} returned no data.' -f $DrPlanId) }

$planType = "$($plan.type)"

# A drill and a production failover are one plan selection apart.
if ($planType -match '(?i)^failover' -and -not $FailoverAuthorized) {
    throw ('DR plan {0} is of type {1}, which MOVES PRODUCTION. Refusing without ' +
           '-FailoverAuthorized. If a drill was intended, select a DRILL plan instead.' -f
           $plan.'display-name', $planType)
}

$steps = @()
foreach ($group in @($plan.'plan-groups')) {
    foreach ($step in @($group.steps)) {
        $steps += [PSCustomObject]@{
            GroupName = $group.'display-name'
            StepName  = $step.'display-name'
            Type      = $step.type
            IsEnabled = $step.'is-enabled'
        }
    }
}

$enabledSteps = @($steps | Where-Object { $_.IsEnabled })

Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
    'DR plan "{0}" type {1}: {2} step(s), {3} enabled. Go decision recorded as: {4}' -f
    $plan.'display-name', $planType, $steps.Count, $enabledSteps.Count, $GoDecisionBy)

$results.Add([PSCustomObject]@{
    Name          = $plan.'display-name'
    Id            = $plan.id
    DrPlanId      = $plan.id
    PlanType      = $planType
    LifecycleState= $plan.'lifecycle-state'
    ProtectionGroupId = $plan.'dr-protection-group-id'
    PeerRegion    = $plan.'peer-region'
    TotalSteps    = $steps.Count
    EnabledSteps  = $enabledSteps.Count
    StepSummary   = ((@($enabledSteps) | Select-Object -First 15 | ForEach-Object { '{0}/{1}' -f $_.GroupName, $_.StepName }) -join '; ')
    GoDecisionBy  = $GoDecisionBy
    MovesProduction = ($planType -match '(?i)^failover')
    HumanStep     = 'Assessing whether the execution result counts as a PASS is a drill-review decision, not made by this script.'
})
"""),
    act=r"""
$execName = 'drill-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmm')
$execution = Invoke-OciCli -Argument @($DrCliGroup, 'dr-plan-execution', 'create',
    '--plan-id', $item.DrPlanId, '--display-name', $execName)

$executionId = $execution.data.id
if (-not $executionId) { throw 'DR plan execution was submitted but no execution id was returned.' }

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'DR plan execution {0} started for plan "{1}" (type {2}). Go decision by: {3}' -f
    $executionId, $item.Name, $item.PlanType, $item.GoDecisionBy)

# Evidence is the deliverable of a drill, so it is captured even though the
# execution itself may still be running.
$evidence = $null
try {
    $evidence = (Invoke-OciCli -Argument @($DrCliGroup, 'dr-plan-execution', 'get',
        '--dr-plan-execution-id', $executionId)).data
} catch {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label `
        -Message ('Execution detail not yet readable: {0}' -f $_.Exception.Message)
}

$evidenceDir = if ($EvidencePath) { $EvidencePath }
               else { Join-Path $env:ProgramData 'ITAutomation\Reports\DR' }
if (-not (Test-Path -LiteralPath $evidenceDir)) {
    New-Item -Path $evidenceDir -ItemType Directory -Force | Out-Null
}
$evidenceFile = Join-Path $evidenceDir ('dr-evidence-{0}.json' -f $executionId)

@{
    ExecutionId   = $executionId
    PlanId        = $item.DrPlanId
    PlanName      = $item.Name
    PlanType      = $item.PlanType
    GoDecisionBy  = $item.GoDecisionBy
    TicketReference = $TicketReference
    ApprovalReference = $ApprovalReference
    StartedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
    ExecutionDetail = $evidence
    AssessmentNote = 'PASS/FAIL assessment is a human drill-review decision and is deliberately absent from this pack.'
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $evidenceFile -Encoding UTF8

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Evidence pack written: {0}. RESULTS ASSESSMENT IS STILL OUTSTANDING.' -f $evidenceFile)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'DrExecutionStarted'
    Detail = ('execution {0}, evidence {1}' -f $executionId, $evidenceFile); Succeeded = $true })
"""),
}

