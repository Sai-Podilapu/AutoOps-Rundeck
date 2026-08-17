<#
.SYNOPSIS
    Starts, stops or reboots OCI compute instances.

.DESCRIPTION
    Performs a controlled power operation on compute instances selected by
    name, OCID or freeform tag, logging every instance before it is touched.
    Instances already in the requested state are skipped rather than
    re-issued.

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

.PARAMETER Action
    Power action to perform.

.PARAMETER InstanceName
    Instance display name(s) to act on.

.PARAMETER InstanceId
    Instance OCID(s) to act on.

.PARAMETER TagKey
    Act on instances carrying this freeform tag key.

.PARAMETER TagValue
    Required value for -TagKey.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Set-OciInstancePowerState.ps1 -Action STOP -TagKey schedule -TagValue nightly

    Graceful-selection stop of every instance tagged schedule=nightly.

.EXAMPLE
    .\Set-OciInstancePowerState.ps1 -Action START -InstanceName APP01,APP02 -WhatIf

    Shows which instances would be started.

.NOTES
    Source use case      : #1 - OCI Instance Start/Stop/Reboot
    Category             : OCI
    Technology           : OCI CLI / Python SDK
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Controlled power ops with audit logging"

    Required permissions : An IAM policy allowing INSTANCE_POWER_ACTIONS and INSTANCE_INSPECT in the compartment.
    Required modules     : none beyond IT-Automation-Common
    Authentication       : OCI CLI config profile. NOTE: there is no
                           first-party OCI PowerShell module - this wraps the
                           OCI CLI.

    STOP and RESET differ in kind, not degree. SOFTSTOP and SOFTRESET ask
    the guest OS to shut down; STOP and RESET pull the power. Both are
    offered because a hung instance needs the hard form, but the
    difference is stated here rather than buried in the API.

    Rollback             : Reversible: START undoes STOP and vice versa. RESET
                           is an immediate power cycle with no guest shutdown,
                           so an in-flight write can be lost - SOFTRESET is the
                           graceful form.
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
    [ValidateSet('START','STOP','SOFTSTOP','SOFTRESET','RESET')]
    [string]$Action,

    [string[]]$InstanceName,

    [string[]]$InstanceId,

    [string]$TagKey,

    [string]$TagValue,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-OciInstancePowerState'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #1 (OCI)'

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
        if (-not $PSCmdlet.ShouldProcess($label, 'Power action on instance')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            Invoke-OciCli -Argument @('compute', 'instance', 'action',
                '--instance-id', $item.InstanceId, '--action', $item.Action) | Out-Null

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                '{0} issued (was {1}){2}' -f $item.Action, $item.LifecycleState,
                $(if (-not $item.Graceful -and $item.Action -ne 'START') { ' - HARD power operation, no guest shutdown' } else { '' }))
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = $item.Action
                Detail = ('was {0}' -f $item.LifecycleState); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'OCI Instance Start/Stop/Reboot'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
