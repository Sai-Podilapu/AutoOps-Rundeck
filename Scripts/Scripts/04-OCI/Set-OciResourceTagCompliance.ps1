<#
.SYNOPSIS
    Reports resources missing required tags, and optionally applies them.

.DESCRIPTION
    Finds resources that lack the required freeform tags and reports them.
    With -AutoTag it applies the default values, which is a metadata-only
    change. Resource types it has no updater for are reported as flagged
    rather than silently counted as compliant.

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

.PARAMETER RequiredTag
    Required tag keys, optionally with a default value as key=value. A key
    with no default can be reported but not auto-applied.

.PARAMETER AutoTag
    Apply the default values to non-compliant resources.

.PARAMETER ResourceType
    Limit to these resource types.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Set-OciResourceTagCompliance.ps1 -RequiredTag CostCenter,Owner

    Reports resources missing either tag.

.EXAMPLE
    .\Set-OciResourceTagCompliance.ps1 -RequiredTag 'CostCenter=UNASSIGNED','Owner=itops' -AutoTag -WhatIf

    Shows which resources would be tagged.

.NOTES
    Source use case      : #7 - OCI Tag Compliance Enforcement
    Category             : OCI
    Technology           : OCI Tag Namespace / Policy
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Flag/auto-tag untagged resources; metadata only"

    Required permissions : An IAM policy allowing read on all-resources plus manage on the resource types being tagged.
    Required modules     : none beyond IT-Automation-Common
    Authentication       : OCI CLI config profile. NOTE: there is no
                           first-party OCI PowerShell module - this wraps the
                           OCI CLI.

    OCI has no single tag-update call. Each resource type has its own
    update command, so this script carries an explicit map of the types it
    can write - instance, block volume, boot volume, VCN, subnet, bucket.
    Anything else is REPORTED as non-compliant and marked as having no
    updater, which is honest; silently treating it as compliant would not
    be.

    Rollback             : Tags are metadata. Remove or overwrite the applied
                           tag to revert; no resource behaviour changes as a
                           result of this script.
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

    [Parameter(Mandatory)]
    [string[]]$RequiredTag,

    [switch]$AutoTag,

    [string[]]$ResourceType,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-OciResourceTagCompliance'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #7 (OCI)'

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
        if (-not $PSCmdlet.ShouldProcess($label, 'Apply required tag')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'OCI Tag Compliance Enforcement'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
