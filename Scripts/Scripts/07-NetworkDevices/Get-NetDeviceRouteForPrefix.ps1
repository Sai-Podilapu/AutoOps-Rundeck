<#
.SYNOPSIS
    Captures the routing entry for one address or prefix.

.DESCRIPTION
    Asks the device how it would reach a specific address and captures the
    answer - the next hop, the protocol that learned the route, and the egress
    interface.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER DeviceName
    Hostname or IP of the device(s) to reach.

.PARAMETER Credential
    SSH credential. Prompted for when omitted. Never read from configuration.

.PARAMETER KeyFile
    Private key file for key-based authentication. The credential still
    supplies the username; its password is used as the key passphrase if the
    key is encrypted.

.PARAMETER Port
    SSH port.

.PARAMETER Vendor
    Device platform, which selects the command set. Use generic with -Command
    for a platform not listed.

.PARAMETER Command
    Run these commands instead of the built-in set for the vendor. Required
    for the generic vendor.

.PARAMETER RawOutputPath
    Directory to write one raw capture file per device. The raw output is the
    primary product of these scripts.

.PARAMETER CommandTimeoutSeconds
    Per-command timeout.

.PARAMETER Prefix
    IP address or network to look up.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-NetDeviceRouteForPrefix.ps1 -DeviceName CORE01 -Vendor cisco-ios -Prefix 10.20.30.0/24

    How this device reaches that network.

.EXAMPLE
    .\Get-NetDeviceRouteForPrefix.ps1 -DeviceName CORE01 -Vendor juniper-junos -Prefix 10.20.30.40

    A single host on Junos.

.NOTES
    Source use case      : #13 - Display IP Route (specific IP/network)
    Category             : Network Devices
    Technology           : Netmiko CLI
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Read-only"

    Required permissions : A read-only account on the device. No enable/config rights are needed.
    Required modules     : Posh-SSH
    Authentication       : SSH key or credential via Posh-SSH. NOTE:
                           Python/Netmiko is a better fit for multi-vendor CLI
                           parsing - see .NOTES.

    This asks the device to resolve the address against its own table,
    which is the question worth asking during an incident. It is not the
    same as searching a captured route table for a matching string. This
    script captures RAW device output and does not parse it. That is
    deliberate and is the master prompt's own guidance: turning
    multi-vendor CLI text into structured data is what Netmiko and NAPALM
    exist for, and a PowerShell reimplementation of their template library
    would be a large, fragile and worse copy. The verbatim capture is the
    product; feed it to a parser that already knows these formats.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Posh-SSH

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory)]
    [string[]]$DeviceName,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [string]$KeyFile,

    [ValidateRange(1,65535)]
    [int]$Port = 22,

    [ValidateSet('cisco-ios','cisco-nxos','arista-eos','juniper-junos','generic')]
    [string]$Vendor = 'cisco-ios',

    [string[]]$Command,

    [string]$RawOutputPath,

    [ValidateRange(5,600)]
    [int]$CommandTimeoutSeconds = 60,

    [Parameter(Mandatory)]
    [string]$Prefix,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-NetDeviceRouteForPrefix'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #13 (Network Devices)'

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
        Connect-AutomationPlatform -Platform 'WindowsServer' | Out-Null


        # Connection settings are gathered once and passed explicitly to every helper.
        # Relying on dynamic scoping to reach $Port or $KeyFile from inside a nested
        # function works, but it hides the dependency from a reader and from static
        # analysis alike.
        $netContext = @{
            Credential = $Credential
            KeyFile    = $KeyFile
            Port       = $Port
            TimeoutSec = $CommandTimeoutSeconds
            RawPath    = $RawOutputPath
            ScriptName = $scriptName
            Sessions   = @{}
        }

        function Connect-NetDevice {
            <#
                .SYNOPSIS
                    Opens one SSH session to a device and caches it for this run.
            #>
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)][string]$Device,
                [Parameter(Mandatory)][hashtable]$Context
            )

            if ($Context.Sessions.ContainsKey($Device)) { return $Context.Sessions[$Device] }

            $sessionParams = @{
                ComputerName = $Device
                Credential   = $Context.Credential
                Port         = $Context.Port
                AcceptKey    = $true
                ErrorAction  = 'Stop'
            }
            if ($Context.KeyFile) {
                if (-not (Test-Path -LiteralPath $Context.KeyFile)) {
                    throw ('Key file not found: {0}' -f $Context.KeyFile)
                }
                $sessionParams.KeyFile = $Context.KeyFile
            }

            $session = New-SSHSession @sessionParams
            $Context.Sessions[$Device] = $session
            Write-AutomationLog -ScriptName $Context.ScriptName -Level INFO -Target $Device -Message (
                'SSH session established (id {0})' -f $session.SessionId)
            return $session
        }

        function Invoke-NetDeviceCommand {
            <#
                .SYNOPSIS
                    Runs commands on a device and returns their RAW output verbatim.
                .DESCRIPTION
                    No interpretation of the output happens here. The text a device
                    returns is the record, and it is preserved unaltered.
            #>
            [CmdletBinding()]
            [OutputType([PSCustomObject])]
            param(
                [Parameter(Mandatory)][string]$Device,
                [Parameter(Mandatory)][string[]]$CommandList,
                [Parameter(Mandatory)][hashtable]$Context
            )

            $session = Connect-NetDevice -Device $Device -Context $Context
            foreach ($cmd in $CommandList) {
                $text = ''
                $failed = ''
                try {
                    $response = Invoke-SSHCommand -SSHSession $session -Command $cmd -TimeOut $Context.TimeoutSec -ErrorAction Stop
                    $text = (@($response.Output) -join "`n")
                    # A device that rejects a command answers on stdout, not with a
                    # non-zero exit status, so the text has to be inspected.
                    if ($text -match '(?im)^\s*%\s*(invalid|incomplete|ambiguous|unknown)') {
                        $failed = ($text -split "`n" | Where-Object { $_ -match '^\s*%' } | Select-Object -First 1).Trim()
                    }
                } catch {
                    $failed = $_.Exception.Message
                }

                [PSCustomObject]@{
                    Device    = $Device
                    Command   = $cmd
                    Output    = $text
                    LineCount = if ($text) { @($text -split "`n").Count } else { 0 }
                    Succeeded = ($failed -eq '')
                    Error     = $failed
                }
            }
        }

        function Resolve-NetCommandSet {
            <#
                .SYNOPSIS
                    Picks the command set for a vendor, or explains why it cannot.
            #>
            [CmdletBinding()]
            [OutputType([string[]])]
            param(
                [Parameter(Mandatory)][hashtable]$Map,
                [Parameter(Mandatory)][string]$Platform,
                [string[]]$Override
            )

            if ($Override) { return $Override }
            if ($Map.ContainsKey($Platform)) { return $Map[$Platform] }

            throw ('No built-in command set for vendor "{0}" in this script. Pass -Command with the ' +
                   'commands for your platform, or use a vendor from: {1}. Commands are NOT guessed at ' +
                   'for an unlisted platform.' -f $Platform, (($Map.Keys | Sort-Object) -join ', '))
        }

        function Save-NetRawOutput {
            <#
                .SYNOPSIS
                    Writes the verbatim capture for one device to disk.
            #>
            [CmdletBinding()]
            [OutputType([string])]
            param(
                [Parameter(Mandatory)][string]$Device,
                [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
                [Parameter(Mandatory)][hashtable]$Context
            )

            if (-not $Context.RawPath) { return '' }
            if (-not (Test-Path -LiteralPath $Context.RawPath)) {
                New-Item -Path $Context.RawPath -ItemType Directory -Force | Out-Null
            }
            $safe = $Device -replace '[^A-Za-z0-9._-]', '_'
            $file = Join-Path $Context.RawPath ('{0}-{1}-{2}.txt' -f $safe, $Context.ScriptName, (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Set-Content -LiteralPath $file -Value $Text -Encoding UTF8
            return $file
        }

        if ($Credential -eq [System.Management.Automation.PSCredential]::Empty) {
            $Credential = Get-Credential -Message 'SSH credentials for the network device(s)'
        }
        if ($Vendor -eq 'generic' -and -not $Command) {
            throw 'Vendor "generic" has no built-in command set. Pass -Command with the commands to run.'
        }
        # The device resolves the prefix against its own table; this is not a text
        # search of a captured route dump.
        $lookupIp = ($Prefix -split '/')[0]
        $commandMap = @{
            'cisco-ios'     = @(('show ip route {0}' -f $lookupIp))
            'cisco-nxos'    = @(('show ip route {0}' -f $lookupIp))
            'arista-eos'    = @(('show ip route {0}' -f $lookupIp))
            'juniper-junos' = @(('show route {0}' -f $Prefix))
        }

        $commands = Resolve-NetCommandSet -Map $commandMap -Platform $Vendor -Override $Command

        foreach ($device in $DeviceName) {
            $captures = @()
            try {
                $captures = @(Invoke-NetDeviceCommand -Device $device -CommandList $commands -Context $netContext)
            } catch {
                Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $device -Message (
                    'Unreachable or authentication failed: {0}' -f $_.Exception.Message)
                $results.Add([PSCustomObject]@{
                    Name = $device; Id = $device; Device = $device; Vendor = $Vendor
                    Command = ($commands -join '; '); Succeeded = $false; LineCount = 0
                    ParsedValue = $null; ParseNote = ''; RawFile = ''
                    Error = $_.Exception.Message; RawOutput = ''
                })
                continue
            }

            $combined = (($captures | ForEach-Object {
                ('===== {0} :: {1} =====' -f $_.Device, $_.Command) + "`n" + $_.Output
            }) -join "`n`n")
            $rawFile = Save-NetRawOutput -Device $device -Text $combined -Context $netContext

            $parsedValue = $null
            $parseNote = 'Not parsed - raw output only. Structured multi-vendor parsing is Netmiko/NAPALM territory and is deliberately not reimplemented here.'

            foreach ($capture in $captures) {
                if (-not $capture.Succeeded) {
                    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $device -Message (
                        'Command rejected: "{0}" -> {1}' -f $capture.Command, $capture.Error)
                }

                $results.Add([PSCustomObject]@{
                    Name        = ('{0}: {1}' -f $device, $capture.Command)
                    Id          = $device
                    Device      = $device
                    Vendor      = $Vendor
                    Command     = $capture.Command
                    Succeeded   = $capture.Succeeded
                    LineCount   = $capture.LineCount
                    ParsedValue = $parsedValue
                    ParseNote   = $parseNote
                    RawFile     = $rawFile
                    Error       = $capture.Error
                    RawOutput   = $capture.Output
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Display IP Route (specific IP/network)'
    Write-Output $candidates


    foreach ($openDevice in @($netContext.Sessions.Keys)) {
        try {
            Remove-SSHSession -SSHSession $netContext.Sessions[$openDevice] -ErrorAction Stop | Out-Null
        } catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $openDevice -Message (
                'SSH session could not be closed cleanly: {0}' -f $_.Exception.Message)
        }
    }

    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
