<#
.SYNOPSIS
    Starts or stops OCI Autonomous Databases on a schedule.

.DESCRIPTION
    Starts or stops Autonomous Databases selected by tag, so a dev environment
    can be shut down outside working hours. Selection is deliberately
    tag-driven: a production database without the schedule tag is never a
    candidate.

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
    Power action.

.PARAMETER TagKey
    Freeform tag key identifying schedulable databases.

.PARAMETER TagValue
    Required value for -TagKey.

.PARAMETER DatabaseName
    Act on these display names instead of the tag selection.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Set-OciAutonomousDbState.ps1 -Action STOP -TagKey schedule -TagValue dev

    Stops every database tagged schedule=dev.

.EXAMPLE
    .\Set-OciAutonomousDbState.ps1 -Action START -DatabaseName DEVADW01 -WhatIf

    Shows the named database that would start.

.NOTES
    Source use case      : #10 - OCI Autonomous DB Start/Stop
    Category             : OCI
    Technology           : OCI DB API / CLI
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Dev-env schedule; reversible"

    Required permissions : An IAM policy allowing AUTONOMOUS_DATABASE_CONTENT_READ and the START/STOP actions in the compartment.
    Required modules     : none beyond IT-Automation-Common
    Authentication       : OCI CLI config profile. NOTE: there is no
                           first-party OCI PowerShell module - this wraps the
                           OCI CLI.

    Stopping an Autonomous Database terminates connected sessions. That is
    fine for the dev environments this is intended for and is not fine
    anywhere else, which is why selection is by tag rather than by
    compartment. -DatabaseName exists for a named one-off and bypasses the
    tag filter deliberately and visibly.

    Rollback             : Fully reversible - START undoes STOP. Sessions are
                           terminated by a stop, so in-flight work is lost even
                           though the data is not.
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
    [ValidateSet('START','STOP')]
    [string]$Action,

    [string]$TagKey = 'schedule',

    [string]$TagValue = 'dev',

    [string[]]$DatabaseName,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-OciAutonomousDbState'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #10 (OCI)'

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
        if (-not $PSCmdlet.ShouldProcess($label, 'Power action on Autonomous DB')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'OCI Autonomous DB Start/Stop'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
