<#
.SYNOPSIS
    Reports overly permissive OCI security list and NSG rules.

.DESCRIPTION
    Reviews security lists and network security groups for ingress rules open
    to the internet, and ranks them by what the rule actually exposes. A
    0.0.0.0/0 rule on an administrative port is a different finding from one
    on 443, and they are not reported the same way.

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

.PARAMETER VcnId
    Limit to these VCNs.

.PARAMETER SensitivePort
    Ports treated as administrative or high-risk when exposed to the internet.

.PARAMETER OpenCidr
    CIDRs considered "open to the world".

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-OciNetworkRuleReview.ps1 -OutputFormat HTML

    Full rule review as HTML.

.EXAMPLE
    .\Get-OciNetworkRuleReview.ps1 -VcnId ocid1.vcn... -SensitivePort 22,3389

    One VCN, two ports of interest.

.NOTES
    Source use case      : #9 - OCI Security List / NSG Rule Review
    Category             : OCI
    Technology           : OCI Network API
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Identify overly permissive rules; report only"

    Required permissions : An IAM policy allowing VCN_INSPECT, SECURITY_LIST_INSPECT and NSG read in the compartment.
    Required modules     : none beyond IT-Automation-Common
    Authentication       : OCI CLI config profile. NOTE: there is no
                           first-party OCI PowerShell module - this wraps the
                           OCI CLI.

    REPORT ONLY - nothing is changed. Whether a permissive rule is wrong
    depends on what sits behind it: a 0.0.0.0/0 rule on 443 in front of a
    public web tier is the design, and the same rule on 3389 almost never
    is. The report ranks by exposure and leaves the decision to a network
    owner.

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

    [string[]]$VcnId,

    [int[]]$SensitivePort = @(22,23,135,139,445,1433,1521,3306,3389,5432,5900,6379,9200,27017),

    [string[]]$OpenCidr = @('0.0.0.0/0','::/0'),

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-OciNetworkRuleReview'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #9 (OCI)'

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
    } catch {
        $msg = $_.Exception.Message
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Message ('Discovery FAILED: {0}' -f $msg)
        $failures.Add([PSCustomObject]@{ Stage = 'Discovery'; Error = $msg })
    }
}

end {
    $candidates = @($results)

    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message ('Collected {0} record(s).' -f $candidates.Count)
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'OCI Security List / NSG Rule Review'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
