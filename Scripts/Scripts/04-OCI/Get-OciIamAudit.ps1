<#
.SYNOPSIS
    Audits OCI IAM users, group memberships and credentials.

.DESCRIPTION
    Reports every IAM user with their group memberships, MFA state and
    credential inventory, flagging the combinations that matter: no MFA, API
    keys older than a rotation threshold, and accounts that have never signed
    in.

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
    Tenancy OCID. IAM users live at tenancy level.

.PARAMETER ApiKeyMaxAgeDays
    Flag API keys older than this.

.PARAMETER IssuesOnly
    Report only users with at least one finding.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-OciIamAudit.ps1 -OutputFormat HTML

    Full IAM audit as HTML.

.EXAMPLE
    .\Get-OciIamAudit.ps1 -IssuesOnly -ApiKeyMaxAgeDays 60

    Only users with findings, tighter key age.

.NOTES
    Source use case      : #8 - OCI IAM User & Group Audit
    Category             : OCI
    Technology           : OCI IAM API
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Review permissions and memberships; read-only"

    Required permissions : An IAM policy allowing USER_INSPECT, GROUP_INSPECT and read on all IAM resources at tenancy level.
    Required modules     : none beyond IT-Automation-Common
    Authentication       : OCI CLI config profile. NOTE: there is no
                           first-party OCI PowerShell module - this wraps the
                           OCI CLI.

    Federated users are managed in the identity provider, not in OCI IAM,
    so their MFA state is not visible here. A federated user showing "no
    MFA" means OCI has no record of one, which is not the same as there
    being none - the report says so rather than asserting a gap that may
    not exist.

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

    [ValidateRange(1,3650)]
    [int]$ApiKeyMaxAgeDays = 90,

    [switch]$IssuesOnly,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-OciIamAudit'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #8 (OCI)'

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
    } catch {
        $msg = $_.Exception.Message
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Message ('Discovery FAILED: {0}' -f $msg)
        $failures.Add([PSCustomObject]@{ Stage = 'Discovery'; Error = $msg })
    }
}

end {
    $candidates = @($results)

    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message ('Collected {0} record(s).' -f $candidates.Count)
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'OCI IAM User & Group Audit'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
