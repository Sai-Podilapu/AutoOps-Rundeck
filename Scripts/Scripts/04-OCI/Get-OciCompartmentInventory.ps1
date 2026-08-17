<#
.SYNOPSIS
    Inventories every resource in a compartment.

.DESCRIPTION
    Uses the OCI resource search to enumerate resources across a compartment
    and summarises them by type and lifecycle state, so an inventory does not
    depend on knowing in advance which services are in use.

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

.PARAMETER IncludeSubcompartments
    Include compartments beneath the target.

.PARAMETER ResourceType
    Limit to these resource types.

.PARAMETER SummaryOnly
    Report counts by type rather than every individual resource.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-OciCompartmentInventory.ps1 -OutputFormat CSV -OutputPath .\inventory.csv

    Full inventory as CSV.

.EXAMPLE
    .\Get-OciCompartmentInventory.ps1 -SummaryOnly -IncludeSubcompartments

    Counts by type across the subtree.

.NOTES
    Source use case      : #6 - OCI Compartment Resource Inventory
    Category             : OCI
    Technology           : OCI CLI / Python SDK
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Read-only inventory per compartment"

    Required permissions : An IAM policy allowing read on all-resources in the compartment, plus COMPARTMENT_INSPECT.
    Required modules     : none beyond IT-Automation-Common
    Authentication       : OCI CLI config profile. NOTE: there is no
                           first-party OCI PowerShell module - this wraps the
                           OCI CLI.

    The resource search indexes most but not all OCI resource types, and
    the index updates asynchronously. A resource created seconds ago may
    not appear yet. This is a search result, not a billing-grade
    inventory, and is labelled as such rather than presented as complete.

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

    [switch]$IncludeSubcompartments,

    [string[]]$ResourceType,

    [switch]$SummaryOnly,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-OciCompartmentInventory'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #6 (OCI)'

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

        if (-not $CompartmentId) {
            throw 'No compartment. Pass -CompartmentId or set oci.defaultCompartmentId in config.json.'
        }

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
    } catch {
        $msg = $_.Exception.Message
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Message ('Discovery FAILED: {0}' -f $msg)
        $failures.Add([PSCustomObject]@{ Stage = 'Discovery'; Error = $msg })
    }
}

end {
    $candidates = @($results)

    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message ('Collected {0} record(s).' -f $candidates.Count)
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'OCI Compartment Resource Inventory'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
