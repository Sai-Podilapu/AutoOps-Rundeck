<#
.SYNOPSIS
    Reports OCI budgets, spend against them and their alert rules.

.DESCRIPTION
    Lists budgets with actual and forecast spend as OCI reports them, together
    with the alert rules attached. A budget with no alert rule is reported as
    a finding - it tracks spend and tells nobody.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

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

.PARAMETER TenancyId
    Tenancy OCID. Budgets live at tenancy level, not in a child compartment.

.PARAMETER WarnAtPercent
    Report a budget consumed beyond this percentage.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-OciBudgetAlert.ps1 -OutputFormat HTML

    Budget report as HTML.

.EXAMPLE
    .\Get-OciBudgetAlert.ps1 -WarnAtPercent 60

    Earlier warning threshold.

.NOTES
    Source use case      : #5 - OCI Cost & Budget Alert
    Category             : OCI
    Technology           : OCI Budget API / Events
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Threshold alerting only"

    Required permissions : An IAM policy allowing BUDGET_INSPECT and USAGE_REPORT read at tenancy level.
    Required modules     : none beyond IT-Automation-Common
    Authentication       : OCI CLI config profile. NOTE: there is no
                           first-party OCI PowerShell module - this wraps the
                           OCI CLI.

    Spend figures are read from the Budgets API as OCI computed them;
    nothing is recalculated here. OCI updates those figures periodically
    rather than continuously, so a budget crossed minutes ago may not show
    it yet.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$CompartmentId,

    [string]$Region,

    [string]$CliProfile,

    [string]$CliConfigFile,

    [string]$OciCliPath,

    [string]$TenancyId,

    [ValidateRange(1,500)]
    [int]$WarnAtPercent = 80,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-OciBudgetAlert'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #5 (OCI)'

    try {
        $config = if ($ConfigPath) { Get-AutomationConfig -Path $ConfigPath } else { Get-AutomationConfig }
        # Recorded so an audit can tell which environment a run targeted.
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Configuration loaded for environment: {0}' -f $config.environment)
    } catch {
        # Read-only: config only supplies optional notification endpoints,
        # so its absence must not stop a report from being produced.
        $config = $null
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
            'Config unavailable ({0}); continuing because this script only reads.' -f $_.Exception.Message)
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
    } catch {
        $msg = $_.Exception.Message
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Message ('Discovery FAILED: {0}' -f $msg)
        $failures.Add([PSCustomObject]@{ Stage = 'Discovery'; Error = $msg })
    }
}

end {
    $candidates = @($results)

    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message ('Collected {0} record(s).' -f $candidates.Count)
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'OCI Cost & Budget Alert'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
