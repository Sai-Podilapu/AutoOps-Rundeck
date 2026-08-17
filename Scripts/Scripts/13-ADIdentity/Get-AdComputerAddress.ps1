<#
.SYNOPSIS
    Resolves hostnames and IP addresses for Active Directory computers.

.DESCRIPTION
    Looks up computer objects and resolves their current DNS addresses,
    reporting where AD and DNS disagree. A stale DNS record pointing at a
    reused address is a common cause of connecting to the wrong machine, and
    this surfaces it.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER Server
    Domain controller to target. Uses the nearest DC when omitted.

.PARAMETER Credential
    Credential for the directory operation.

.PARAMETER ComputerName
    Computer name(s) to look up. Accepts partial names with wildcards.

.PARAMETER IPAddress
    Reverse lookup: find which computer holds this address.

.PARAMETER StaleDays
    Flag a computer whose AD password was last set longer ago than this.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-AdComputerAddress.ps1 -ComputerName 'SRV*'

    Resolves every computer whose name starts with SRV.

.EXAMPLE
    .\Get-AdComputerAddress.ps1 -IPAddress 10.1.2.3

    Finds which computer currently answers on that address.

.NOTES
    Source use case      : #11 - Identify Hostname & IP Address
    Category             : AD & Identity
    Technology           : PowerShell / ADSI
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Read-only lookup"

    Required permissions : Domain read access.
    Required modules     : ActiveDirectory
    Authentication       : Delegated service account with the minimum required
                           AD rights.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules ActiveDirectory

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$Server,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [string[]]$ComputerName,

    [string[]]$IPAddress,

    [ValidateRange(1,3650)]
    [int]$StaleDays = 90,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-AdComputerAddress'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #11 (AD & Identity)'

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
        Connect-AutomationPlatform -Platform 'ActiveDirectory' | Out-Null


        $adArgs = @{ ErrorAction = 'Stop' }
        if ($Server) { $adArgs.Server = $Server }
        if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $adArgs.Credential = $Credential }

        Import-Module ActiveDirectory -ErrorAction Stop

        if ($IPAddress) {
            foreach ($ip in $IPAddress) {
                $hostName = $null
                try { $hostName = [System.Net.Dns]::GetHostEntry($ip).HostName } catch {
                    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $ip `
                        -Message 'No reverse DNS record'
                }

                $adComputer = $null
                if ($hostName) {
                    $short = ($hostName -split '\.')[0]
                    $adComputer = Get-ADComputer -Filter ("Name -eq '{0}'" -f $short) `
                        -Properties OperatingSystem,PasswordLastSet,Description @adArgs -ErrorAction SilentlyContinue
                }

                $results.Add([PSCustomObject]@{
                    Name         = if ($hostName) { $hostName } else { $ip }
                    Id           = $ip
                    LookupType   = 'Reverse'
                    QueriedValue = $ip
                    ResolvedHost = $hostName
                    InActiveDirectory = [bool]$adComputer
                    DistinguishedName = if ($adComputer) { $adComputer.DistinguishedName } else { $null }
                    OperatingSystem   = if ($adComputer) { $adComputer.OperatingSystem } else { $null }
                    PasswordLastSet   = if ($adComputer) { $adComputer.PasswordLastSet } else { $null }
                    Status       = if (-not $hostName) { 'NoDnsRecord' }
                                   elseif (-not $adComputer) { 'DnsButNotInAD' }
                                   else { 'OK' }
                })
            }
            return
        }

        $filter = if ($ComputerName) { $ComputerName } else { @('*') }
        foreach ($pattern in $filter) {
            $computers = Get-ADComputer -Filter ("Name -like '{0}'" -f $pattern) `
                -Properties OperatingSystem,PasswordLastSet,DNSHostName,Description,Enabled @adArgs

            foreach ($c in $computers) {
                $resolved = @()
                try { $resolved = @([System.Net.Dns]::GetHostAddresses($c.DNSHostName) |
                                   Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                                   ForEach-Object { $_.IPAddressToString }) } catch {
                    Write-Verbose ('DNS resolution failed for {0}' -f $c.DNSHostName)
                }

                $staleDaysActual = if ($c.PasswordLastSet) {
                                       [math]::Round(((Get-Date) - $c.PasswordLastSet).TotalDays, 0)
                                   } else { $null }

                $issues = @()
                if ($resolved.Count -eq 0) { $issues += 'does not resolve in DNS' }
                if ($null -ne $staleDaysActual -and $staleDaysActual -gt $StaleDays) {
                    $issues += ('computer password {0}d old - object may be stale' -f $staleDaysActual)
                }
                if (-not $c.Enabled) { $issues += 'account disabled' }

                $results.Add([PSCustomObject]@{
                    Name         = $c.Name
                    Id           = $c.DistinguishedName
                    LookupType   = 'Forward'
                    QueriedValue = $pattern
                    DnsHostName  = $c.DNSHostName
                    IPAddresses  = ($resolved -join '; ')
                    OperatingSystem = $c.OperatingSystem
                    Enabled      = $c.Enabled
                    PasswordLastSet = $c.PasswordLastSet
                    StaleDays    = $staleDaysActual
                    Description  = $c.Description
                    Status       = if ($issues.Count) { 'Warning' } else { 'OK' }
                    Issues       = ($issues -join '; ')
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Identify Hostname & IP Address'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
