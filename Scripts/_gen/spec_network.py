# -*- coding: utf-8 -*-
"""Network Devices - use cases 1-18.

These wrap SSH (Posh-SSH) and capture RAW command output. That is a deliberate
limit, and it is the master prompt's own guidance: multi-vendor CLI parsing is
what Netmiko and NAPALM exist for, and a PowerShell reimplementation of their
template library would be a large, fragile and worse copy. So the PowerShell
side does what it does well - reach the device, run the right command for the
vendor, capture the output verbatim, and log it - and structured parsing is
attempted only where a vendor's output format is unambiguous and stable.
"""

VENDORS = "'cisco-ios','cisco-nxos','arista-eos','juniper-junos','generic'"

CONN_PARAMS = [
    dict(name='DeviceName',
         help='Hostname or IP of the device(s) to reach.',
         decl="[Parameter(Mandatory)]\n    [string[]]$DeviceName"),
    dict(name='Credential',
         help='SSH credential. Prompted for when omitted. Never read from configuration.',
         decl="[System.Management.Automation.PSCredential]\n    [System.Management.Automation.Credential()]\n    $Credential = [System.Management.Automation.PSCredential]::Empty"),
    dict(name='KeyFile',
         help='Private key file for key-based authentication. The credential still supplies the '
              'username; its password is used as the key passphrase if the key is encrypted.',
         decl="[string]$KeyFile"),
    dict(name='Port', help='SSH port.',
         decl="[ValidateRange(1,65535)]\n    [int]$Port = 22"),
    dict(name='Vendor',
         help='Device platform, which selects the command set. Use generic with -Command for a '
              'platform not listed.',
         decl="[ValidateSet(" + VENDORS + ")]\n    [string]$Vendor = 'cisco-ios'"),
    dict(name='Command',
         help='Run these commands instead of the built-in set for the vendor. Required for the '
              'generic vendor.',
         decl="[string[]]$Command"),
    dict(name='RawOutputPath',
         help='Directory to write one raw capture file per device. The raw output is the primary '
              'product of these scripts.',
         decl="[string]$RawOutputPath"),
    dict(name='CommandTimeoutSeconds', help='Per-command timeout.',
         decl="[ValidateRange(5,600)]\n    [int]$CommandTimeoutSeconds = 60"),
]

CONNECT = r"""
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
"""

CLEANUP = r"""
foreach ($openDevice in @($netContext.Sessions.Keys)) {
    try {
        Remove-SSHSession -SSHSession $netContext.Sessions[$openDevice] -ErrorAction Stop | Out-Null
    } catch {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $openDevice -Message (
            'SSH session could not be closed cleanly: {0}' -f $_.Exception.Message)
    }
}
"""

CONFIG_HELPER = r"""
function Invoke-NetDeviceConfig {
    <#
        .SYNOPSIS
            Sends configuration lines over an interactive shell and returns the
            full transcript.
        .DESCRIPTION
            Configuration mode needs an interactive channel; a device will not
            accept "configure terminal" as a one-shot exec command. The
            transcript is returned in full so the audit trail records what the
            device said back, not just what was sent.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$Device,
        [Parameter(Mandatory)][string[]]$ConfigLine,
        [Parameter(Mandatory)][hashtable]$Context,
        [ValidateRange(200,10000)]
        [int]$SettleMilliseconds = 800
    )

    $session = Connect-NetDevice -Device $Device -Context $Context
    $stream = New-SSHShellStream -SSHSession $session -TerminalName 'vt100' `
        -Columns 200 -Rows 4000 -Width 1600 -Height 1200 -ErrorAction Stop

    $transcript = New-Object System.Text.StringBuilder
    try {
        Start-Sleep -Milliseconds $SettleMilliseconds
        $null = $stream.Read()   # discard the banner and first prompt

        foreach ($line in $ConfigLine) {
            $stream.WriteLine($line)
            Start-Sleep -Milliseconds $SettleMilliseconds
            [void]$transcript.AppendLine(('--> {0}' -f $line))
            [void]$transcript.AppendLine($stream.Read())
        }
    } finally {
        $stream.Dispose()
    }

    $text = $transcript.ToString()
    $rejected = @($text -split "`n" | Where-Object { $_ -match '(?i)^\s*%|invalid input|syntax error|command rejected' })

    [PSCustomObject]@{
        Device     = $Device
        Transcript = $text
        Succeeded  = ($rejected.Count -eq 0)
        Rejections = ($rejected -join ' | ')
    }
}
"""


def net(body, config=False):
    return CONNECT + (CONFIG_HELPER if config else '') + body


def read_only(num, fname, synopsis, desc, cmds, notes, examples, extra_params=None,
              parse=None, perms='A read-only account on the device. No enable/config rights are needed.'):
    """A read-only capture script: run the vendor's commands, keep the output."""
    body = "$commandMap = @{\n"
    for vendor, commands in cmds:
        body += "    '%s' = @(%s)\n" % (vendor, ', '.join("'%s'" % c for c in commands))
    body += "}\n\n"
    body += r"""$commands = Resolve-NetCommandSet -Map $commandMap -Platform $Vendor -Override $Command

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

"""
    if parse:
        body += parse + "\n"
    else:
        body += ("    $parsedValue = $null\n"
                 "    $parseNote = 'Not parsed - raw output only. Structured multi-vendor parsing is "
                 "Netmiko/NAPALM territory and is deliberately not reimplemented here.'\n\n")

    body += r"""    foreach ($capture in $captures) {
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
"""
    spec = dict(
        file=fname,
        modules=['Posh-SSH'],
        synopsis=synopsis,
        desc=desc,
        params=CONN_PARAMS + (extra_params or []),
        perms=perms,
        notes=notes,
        examples=examples,
        cleanup=CLEANUP,
        discover=net(body),
    )
    return num, spec


SPECS = {}


def add(pair):
    SPECS[pair[0]] = pair[1]


RAW_NOTE = ('This script captures RAW device output and does not parse it. That is deliberate and '
            'is the master prompt\'s own guidance: turning multi-vendor CLI text into structured '
            'data is what Netmiko and NAPALM exist for, and a PowerShell reimplementation of their '
            'template library would be a large, fragile and worse copy. The verbatim capture is the '
            'product; feed it to a parser that already knows these formats.')

add(read_only(
    1, 'Get-NetDeviceInventory',
    'Captures device inventory and version information.',
    'Runs the vendor\'s version and inventory commands on each device and captures the output '
    'verbatim, giving a point-in-time record of model, serial, software version and installed '
    'modules.',
    [('cisco-ios', ['show version', 'show inventory']),
     ('cisco-nxos', ['show version', 'show inventory']),
     ('arista-eos', ['show version', 'show inventory']),
     ('juniper-junos', ['show version', 'show chassis hardware'])],
    RAW_NOTE,
    [("-DeviceName SW01,SW02 -Vendor cisco-ios -RawOutputPath .\\\\captures",
      'Inventory capture from two switches, raw output kept on disk.'),
     ("-DeviceName FW01 -Vendor generic -Command 'get system status'",
      'A platform with no built-in command set, driven explicitly.')]))

add(read_only(
    2, 'Get-NetDeviceCpu',
    'Reports device CPU utilisation.',
    'Captures CPU utilisation output. For the platforms whose format is unambiguous the headline '
    'percentage is extracted as well; for the rest the raw text is the answer.',
    [('cisco-ios', ['show processes cpu sorted']),
     ('cisco-nxos', ['show system resources']),
     ('arista-eos', ['show processes top once']),
     ('juniper-junos', ['show chassis routing-engine'])],
    'The five-second CPU figure spikes for reasons that do not matter. The five-minute average is '
    'the one worth alerting on, which is why the raw output - containing all three - is kept rather '
    'than reduced to a single number. ' + RAW_NOTE,
    [("-DeviceName SW01 -Vendor cisco-ios", 'CPU capture with the headline percentage extracted.'),
     ("-DeviceName SW01,SW02 -Vendor cisco-nxos -OutputFormat HTML", 'Two NX-OS devices as HTML.')],
    parse=r"""    # Only parsed where the format is stable and documented. Everything else
    # stays raw rather than being matched against a hopeful regex.
    $parsedValue = $null
    $parseNote = ''
    switch ($Vendor) {
        'cisco-ios' {
            if ($combined -match 'CPU utilization for five seconds:\s*(\d+)%') {
                $parsedValue = [int]$Matches[1]
                $parseNote = 'five-second CPU %, from "CPU utilization for five seconds"'
            }
        }
        'cisco-nxos' {
            if ($combined -match '(?m)^\s*CPU states\s*:\s*([\d.]+)%\s*user') {
                $parsedValue = [double]$Matches[1]
                $parseNote = 'user CPU %, from "CPU states"'
            }
        }
        default { }
    }
    if (-not $parseNote) {
        $parseNote = 'Not parsed for this vendor - raw output only.'
    }
"""))

add(read_only(
    3, 'Get-NetDeviceMemory',
    'Reports device memory utilisation.',
    'Captures memory utilisation output, extracting the used-percentage where the platform reports '
    'it in a stable format.',
    [('cisco-ios', ['show memory statistics']),
     ('cisco-nxos', ['show system resources']),
     ('arista-eos', ['show version']),
     ('juniper-junos', ['show chassis routing-engine'])],
    'Free memory on a network device is not the same measurement as on a server - a device that '
    'has allocated most of its processor pool is usually healthy, not about to fail. Treat the '
    'percentage as a trend line, not a threshold. ' + RAW_NOTE,
    [("-DeviceName SW01 -Vendor cisco-ios", 'Memory capture.'),
     ("-DeviceName SW01,SW02 -Vendor cisco-nxos -RawOutputPath .\\\\captures", 'Two devices, raw kept.')],
    parse=r"""    $parsedValue = $null
    $parseNote = ''
    switch ($Vendor) {
        'cisco-ios' {
            # "Processor   <hex>  <total>  <used>  <free> ..."
            if ($combined -match '(?m)^\s*Processor\s+\S+\s+(\d+)\s+(\d+)\s+(\d+)') {
                $total = [double]$Matches[1]
                $used = [double]$Matches[2]
                if ($total -gt 0) {
                    $parsedValue = [math]::Round(($used / $total) * 100, 1)
                    $parseNote = 'processor pool used %, from "show memory statistics"'
                }
            }
        }
        'cisco-nxos' {
            if ($combined -match 'Memory usage:\s*(\d+)K total,\s*(\d+)K used') {
                $total = [double]$Matches[1]
                $used = [double]$Matches[2]
                if ($total -gt 0) {
                    $parsedValue = [math]::Round(($used / $total) * 100, 1)
                    $parseNote = 'memory used %, from "Memory usage"'
                }
            }
        }
        default { }
    }
    if (-not $parseNote) {
        $parseNote = 'Not parsed for this vendor - raw output only.'
    }
"""))

add(read_only(
    4, 'Get-NetDeviceLoggingConfig',
    'Captures device logging configuration and destinations.',
    'Reports where a device is sending its logs and at what severity. A device logging only to its '
    'local buffer is a gap: the buffer is lost on reload, which is exactly when the logs matter.',
    [('cisco-ios', ['show logging | include Trap|Logging to|Console logging|Buffer logging']),
     ('cisco-nxos', ['show logging server', 'show logging level']),
     ('arista-eos', ['show logging | include Trap|Writing|Console']),
     ('juniper-junos', ['show configuration system syslog'])],
    'The commands here deliberately filter to the configuration header rather than dumping the log '
    'buffer - use case #17 does that. ' + RAW_NOTE,
    [("-DeviceName SW01 -Vendor cisco-ios", 'Logging configuration for one device.'),
     ("-DeviceName SW01,SW02,SW03 -OutputFormat HTML", 'Logging destinations across a fleet.')]))

add(read_only(
    5, 'Get-NetDeviceHardware',
    'Captures hardware, module and environmental status.',
    'Reports installed hardware, module inventory and environmental readings - power supplies, fans '
    'and temperature - so a failed redundant component is visible before the second one goes.',
    [('cisco-ios', ['show inventory', 'show environment all']),
     ('cisco-nxos', ['show inventory', 'show environment']),
     ('arista-eos', ['show inventory', 'show environment all']),
     ('juniper-junos', ['show chassis hardware', 'show chassis environment'])],
    'A failed redundant power supply produces no outage and no alert on many platforms; it just '
    'quietly removes the redundancy. That is the finding this capture is for. ' + RAW_NOTE,
    [("-DeviceName SW01 -Vendor cisco-ios -RawOutputPath .\\\\captures",
      'Hardware and environment capture.'),
     ("-DeviceName CORE01,CORE02 -Vendor cisco-nxos", 'Both core switches.')]))

add(read_only(
    6, 'Get-NetDeviceInterface',
    'Captures interface status and configuration.',
    'Reports the status of every interface - up, down, administratively down, err-disabled - along '
    'with description and VLAN assignment where the platform includes them.',
    [('cisco-ios', ['show interfaces status', 'show ip interface brief']),
     ('cisco-nxos', ['show interface status', 'show ip interface brief']),
     ('arista-eos', ['show interfaces status', 'show ip interface brief']),
     ('juniper-junos', ['show interfaces terse'])],
    'An err-disabled port and an administratively shut port look similar in a summary and mean very '
    'different things: one was shut by a person, the other by the switch protecting itself. The raw '
    'status column distinguishes them. ' + RAW_NOTE,
    [("-DeviceName SW01 -Vendor cisco-ios -OutputFormat CSV -OutputPath .\\\\ports.csv",
      'Interface status export.'),
     ("-DeviceName SW01,SW02 -RawOutputPath .\\\\captures", 'Two switches, raw kept.')]))

add(read_only(
    7, 'Get-NetDeviceMacTable',
    'Captures the MAC address to interface mapping.',
    'Reports the MAC address table, which answers "what is plugged into this port" and, read the '
    'other way, "which port is this device on".',
    [('cisco-ios', ['show mac address-table']),
     ('cisco-nxos', ['show mac address-table']),
     ('arista-eos', ['show mac address-table']),
     ('juniper-junos', ['show ethernet-switching table'])],
    'The MAC table only shows what the switch has heard recently - a device that has been quiet '
    'past the ageing time is absent from it despite being connected. An empty result for a port is '
    'not evidence that nothing is attached. ' + RAW_NOTE,
    [("-DeviceName SW01 -Vendor cisco-ios", 'Full MAC table.'),
     ("-DeviceName SW01 -Vendor cisco-ios -Command 'show mac address-table address 0011.2233.4455'",
      'One specific MAC.')]))

add(read_only(
    11, 'Test-NetDeviceReachability',
    'Runs ping and traceroute from a device.',
    'Executes ping and traceroute from the device itself rather than from the automation host. That '
    'distinction is the whole point: reachability from the device\'s own routing table and source '
    'interface is what a network fault report needs.',
    [('cisco-ios', []), ('cisco-nxos', []), ('arista-eos', []), ('juniper-junos', [])],
    'Running the test from the device, not from here, is deliberate - a path that works from the '
    'automation host says nothing about the path the device would take. The ping success rate is '
    'extracted where the platform reports it in a stable format. ' + RAW_NOTE,
    [("-DeviceName SW01 -Vendor cisco-ios -Target 8.8.8.8",
      'Ping and traceroute to a public address from the switch.'),
     ("-DeviceName SW01 -Target 10.1.1.1 -SkipTraceroute", 'Ping only.')],
    extra_params=[
        dict(name='Target', help='Address or hostname to test reachability to.',
             decl="[Parameter(Mandatory)]\n    [string]$Target"),
        dict(name='SkipTraceroute', help='Run ping only.',
             decl="[switch]$SkipTraceroute"),
    ],
    parse=r"""    $parsedValue = $null
    $parseNote = ''
    if ($Vendor -in 'cisco-ios', 'cisco-nxos' -and $combined -match 'Success rate is (\d+) percent') {
        $parsedValue = [int]$Matches[1]
        $parseNote = 'ping success rate %, from "Success rate is N percent"'
    }
    if (-not $parseNote) {
        $parseNote = 'Not parsed for this vendor - raw output only.'
    }
"""))

# #11 needs its command set built from -Target at runtime, so its map is replaced.
SPECS[11]['discover'] = SPECS[11]['discover'].replace(
    """$commandMap = @{
    'cisco-ios' = @()
    'cisco-nxos' = @()
    'arista-eos' = @()
    'juniper-junos' = @()
}""",
    r"""# Built from -Target at runtime rather than being a static table.
$pingCommand = switch ($Vendor) {
    'juniper-junos' { 'ping {0} count 5' -f $Target }
    default         { 'ping {0} repeat 5' -f $Target }
}
$traceCommand = switch ($Vendor) {
    'juniper-junos' { 'traceroute {0}' -f $Target }
    default         { 'traceroute {0}' -f $Target }
}
$built = @($pingCommand)
if (-not $SkipTraceroute) { $built += $traceCommand }

$commandMap = @{
    'cisco-ios'     = $built
    'cisco-nxos'    = $built
    'arista-eos'    = $built
    'juniper-junos' = $built
}""")

add(read_only(
    12, 'Get-NetDeviceRouteTable',
    'Captures the full IP routing table.',
    'Reports the device\'s routing table in full, giving the record needed to explain why traffic '
    'went where it did.',
    [('cisco-ios', ['show ip route']),
     ('cisco-nxos', ['show ip route']),
     ('arista-eos', ['show ip route']),
     ('juniper-junos', ['show route'])],
    'A full routing table from a core device can run to thousands of lines. Use -RawOutputPath to '
    'keep it on disk rather than in console output, and use case #13 when you want one prefix. '
    + RAW_NOTE,
    [("-DeviceName CORE01 -Vendor cisco-ios -RawOutputPath .\\\\captures",
      'Full route table captured to disk.'),
     ("-DeviceName CORE01 -Vendor juniper-junos", 'Junos route table.')]))

add(read_only(
    13, 'Get-NetDeviceRouteForPrefix',
    'Captures the routing entry for one address or prefix.',
    'Asks the device how it would reach a specific address and captures the answer - the next hop, '
    'the protocol that learned the route, and the egress interface.',
    [('cisco-ios', []), ('cisco-nxos', []), ('arista-eos', []), ('juniper-junos', [])],
    'This asks the device to resolve the address against its own table, which is the question worth '
    'asking during an incident. It is not the same as searching a captured route table for a '
    'matching string. ' + RAW_NOTE,
    [("-DeviceName CORE01 -Vendor cisco-ios -Prefix 10.20.30.0/24",
      'How this device reaches that network.'),
     ("-DeviceName CORE01 -Vendor juniper-junos -Prefix 10.20.30.40", 'A single host on Junos.')],
    extra_params=[
        dict(name='Prefix', help='IP address or network to look up.',
             decl="[Parameter(Mandatory)]\n    [string]$Prefix"),
    ]))

SPECS[13]['discover'] = SPECS[13]['discover'].replace(
    """$commandMap = @{
    'cisco-ios' = @()
    'cisco-nxos' = @()
    'arista-eos' = @()
    'juniper-junos' = @()
}""",
    r"""# The device resolves the prefix against its own table; this is not a text
# search of a captured route dump.
$lookupIp = ($Prefix -split '/')[0]
$commandMap = @{
    'cisco-ios'     = @(('show ip route {0}' -f $lookupIp))
    'cisco-nxos'    = @(('show ip route {0}' -f $lookupIp))
    'arista-eos'    = @(('show ip route {0}' -f $lookupIp))
    'juniper-junos' = @(('show route {0}' -f $Prefix))
}""")

add(read_only(
    14, 'Get-NetDeviceResourceUtilization',
    'Captures CPU, memory and storage utilisation together.',
    'Runs the CPU, memory and filesystem commands in one pass so a monitoring record covers all '
    'three from the same moment, rather than three captures taken minutes apart.',
    [('cisco-ios', ['show processes cpu sorted', 'show memory statistics', 'dir']),
     ('cisco-nxos', ['show system resources', 'dir']),
     ('arista-eos', ['show processes top once', 'show version', 'dir flash:']),
     ('juniper-junos', ['show chassis routing-engine', 'show system storage'])],
    'A device out of flash storage cannot save configuration or write a crash dump, and nothing '
    'about its CPU or memory reading will hint at it. That is why storage is captured alongside, '
    'not separately. ' + RAW_NOTE,
    [("-DeviceName SW01 -Vendor cisco-ios -OutputFormat HTML", 'All three readings for one device.'),
     ("-DeviceName SW01,SW02,SW03 -RawOutputPath .\\\\captures", 'Fleet snapshot, raw kept.')]))

add(read_only(
    16, 'Get-NetDeviceProcess',
    'Captures per-process CPU and memory consumption.',
    'Reports the process list with its resource consumption, which is the next question after a '
    'device shows high CPU: what is using it.',
    [('cisco-ios', ['show processes cpu sorted', 'show processes memory sorted']),
     ('cisco-nxos', ['show processes cpu sort', 'show processes memory']),
     ('arista-eos', ['show processes top once']),
     ('juniper-junos', ['show system processes extensive'])],
    'On many platforms a high-CPU process is a symptom of something else - an interrupt storm, a '
    'routing reconvergence - rather than the cause. The process list narrows the search; it rarely '
    'ends it. ' + RAW_NOTE,
    [("-DeviceName SW01 -Vendor cisco-ios", 'Process list sorted by CPU and by memory.'),
     ("-DeviceName SW01 -Vendor juniper-junos -RawOutputPath .\\\\captures", 'Junos process detail.')]))

add(read_only(
    17, 'Get-NetDeviceLogTail',
    'Captures the most recent log lines from a device.',
    'Retrieves the device log buffer and returns the last N lines. The tail is applied here rather '
    'than on the device, so the count means the same thing on every platform.',
    [('cisco-ios', ['show logging']),
     ('cisco-nxos', ['show logging logfile']),
     ('arista-eos', ['show logging']),
     ('juniper-junos', ['show log messages'])],
    'Platforms differ in whether they support a "last N" argument at all, and in whether it counts '
    'from the newest or oldest entry. Taking the tail locally makes -LineCount mean one thing '
    'everywhere. The device buffer is finite and is lost on reload - if these lines matter, the '
    'device should be sending them to a syslog server, which use case #4 checks. ' + RAW_NOTE,
    [("-DeviceName SW01 -Vendor cisco-ios", 'Last 100 log lines.'),
     ("-DeviceName SW01 -LineCount 500 -RawOutputPath .\\\\captures", 'A deeper tail, kept on disk.')],
    extra_params=[
        dict(name='LineCount', help='How many trailing lines to return.',
             decl="[ValidateRange(1,10000)]\n    [int]$LineCount = 100"),
    ]))

add(read_only(
    18, 'Get-NetDeviceLogSearch',
    'Captures recent log lines matching a keyword.',
    'Searches the device log buffer for a keyword and returns the most recent matches - the usual '
    'first step when an interface, a neighbour or an error code needs its history.',
    [('cisco-ios', []), ('cisco-nxos', []), ('arista-eos', []), ('juniper-junos', [])],
    'The keyword is passed to the device\'s own filter, so the device does the work rather than '
    'shipping its whole buffer over SSH. The match is the platform\'s, not a PowerShell regex: '
    'case sensitivity and pattern syntax are the device\'s. ' + RAW_NOTE,
    [("-DeviceName SW01 -Vendor cisco-ios -Keyword 'GigabitEthernet1/0/24'",
      'Every recent log line mentioning one port.'),
     ("-DeviceName SW01 -Keyword ERROR -LineCount 50", 'Last 50 lines containing ERROR.')],
    extra_params=[
        dict(name='Keyword', help='Keyword passed to the device log filter.',
             decl="[Parameter(Mandatory)]\n    [string]$Keyword"),
        dict(name='LineCount', help='How many trailing matches to return.',
             decl="[ValidateRange(1,10000)]\n    [int]$LineCount = 100"),
    ]))

SPECS[18]['discover'] = SPECS[18]['discover'].replace(
    """$commandMap = @{
    'cisco-ios' = @()
    'cisco-nxos' = @()
    'arista-eos' = @()
    'juniper-junos' = @()
}""",
    r"""# The device's own filter runs the match, so its buffer is not shipped whole
# over SSH. Pattern syntax and case sensitivity are the platform's, not ours.
$commandMap = @{
    'cisco-ios'     = @(('show logging | include {0}' -f $Keyword))
    'cisco-nxos'    = @(('show logging logfile | include {0}' -f $Keyword))
    'arista-eos'    = @(('show logging | include {0}' -f $Keyword))
    'juniper-junos' = @(('show log messages | match {0}' -f $Keyword))
}""")

# Tail trimming for #17 and #18.
for _n in (17, 18):
    SPECS[_n]['discover'] = SPECS[_n]['discover'].replace(
        "    foreach ($capture in $captures) {",
        r"""    # Trimmed here, not on the device: platforms disagree on whether a
    # "last N" argument exists and on which end it counts from.
    $captures = @($captures | ForEach-Object {
        $lines = @($_.Output -split "`n")
        $tail = if ($lines.Count -gt $LineCount) { $lines[-$LineCount..-1] } else { $lines }
        [PSCustomObject]@{
            Device = $_.Device; Command = $_.Command; Output = ($tail -join "`n")
            LineCount = $tail.Count; Succeeded = $_.Succeeded; Error = $_.Error
        }
    })

    foreach ($capture in $captures) {""")


# ---------------------------------------------------------------------------
# Change and gated rows.
# ---------------------------------------------------------------------------

SPECS[8] = dict(
    file='Set-NetInterfaceState',
    modules=['Posh-SSH'],
    synopsis='Shuts or re-enables switch interfaces, behind an approval gate.',
    desc='Administratively shuts or unshuts named interfaces. Shutting the wrong port takes '
         'something offline with no warning, so the change set shows what is currently on each port '
         'before anybody approves it, and the interface must be named exactly - no wildcards.',
    params=CONN_PARAMS + [
        dict(name='Interface',
             help='Exact interface name(s), e.g. GigabitEthernet1/0/24. Wildcards are refused.',
             decl="[Parameter(Mandatory)]\n    [ValidatePattern('^[A-Za-z][A-Za-z0-9/._:-]*$')]\n    [string[]]$Interface"),
        dict(name='State', help='Desired administrative state.',
             decl="[Parameter(Mandatory)]\n    [ValidateSet('Shutdown','NoShutdown')]\n    [string]$State"),
        dict(name='IncludeUplinkPorts',
             help='Permit acting on a port that looks like an uplink or trunk. Off by default: '
                  'shutting an uplink takes down everything behind it.',
             decl="[switch]$IncludeUplinkPorts"),
        dict(name='SaveConfiguration', help='Write the running configuration to startup after the change.',
             decl="[switch]$SaveConfiguration")],
    minage=0,
    perms='An account with configuration privilege on the device (enable / configure terminal).',
    actionVerb='Change interface admin state',
    reason='Ticketed interface state change',
    rollback='The previous state and the full interface configuration are captured and logged before '
             'the change. Re-apply the opposite state to revert. If -SaveConfiguration was NOT used, '
             'a device reload also reverts the change.',
    notes='DESTRUCTIVE. Shutting a port removes service from whatever is on it, immediately and '
          'without warning to the user at the other end. The change set therefore includes the '
          'current status, the port description and what the MAC table has heard on that port, so '
          'an approver is looking at what is connected rather than at an interface name. A port '
          'whose description or status suggests an uplink or trunk is excluded unless '
          '-IncludeUplinkPorts is passed explicitly.',
    examples=[("-DeviceName SW01 -Interface GigabitEthernet1/0/24 -State Shutdown -TicketReference INC0012345",
               'REPORT ONLY. Shows what is on the port and raises an approval.'),
              ("-DeviceName SW01 -Interface GigabitEthernet1/0/24 -State Shutdown "
               "-ApprovalReference APR-... -TicketReference INC0012345 -Execute",
               'Shuts an approved port.')],
    cleanup=CLEANUP,
    discover=net(r"""
if (-not $TicketReference) {
    throw 'A -TicketReference is required. The guardrail on this use case is ticket-driven change ' +
          'with interface confirmation, and an interface shut with no ticket has neither.'
}

$stateMap = @{
    'cisco-ios'     = @{ Config = 'configure terminal'; Enter = 'interface {0}'; Down = 'shutdown'; Up = 'no shutdown'; Exit = 'end'; Save = 'write memory' }
    'cisco-nxos'    = @{ Config = 'configure terminal'; Enter = 'interface {0}'; Down = 'shutdown'; Up = 'no shutdown'; Exit = 'end'; Save = 'copy running-config startup-config' }
    'arista-eos'    = @{ Config = 'configure';          Enter = 'interface {0}'; Down = 'shutdown'; Up = 'no shutdown'; Exit = 'end'; Save = 'write memory' }
    'juniper-junos' = @{ Config = 'configure';          Enter = 'edit interfaces {0}'; Down = 'set disable'; Up = 'delete disable'; Exit = 'commit and-quit'; Save = '' }
}
if (-not $stateMap.ContainsKey($Vendor)) {
    throw ('No interface configuration syntax is defined for vendor "{0}". Commands are not guessed at.' -f $Vendor)
}
$syntax = $stateMap[$Vendor]

foreach ($device in $DeviceName) {
    $statusText = ''
    $macText = ''
    try {
        $statusCmd = if ($Vendor -eq 'juniper-junos') { 'show interfaces terse' } else { 'show interfaces status' }
        $statusText = (Invoke-NetDeviceCommand -Device $device -CommandList @($statusCmd) -Context $netContext).Output
        $macCmd = if ($Vendor -eq 'juniper-junos') { 'show ethernet-switching table' } else { 'show mac address-table' }
        $macText = (Invoke-NetDeviceCommand -Device $device -CommandList @($macCmd) -Context $netContext).Output
    } catch {
        throw ('Could not read current interface state from {0}: {1}. Refusing to change a port ' +
               'whose current state is unknown.' -f $device, $_.Exception.Message)
    }

    foreach ($ifName in $Interface) {
        $runningConfig = ''
        try {
            $cfgCmd = if ($Vendor -eq 'juniper-junos') { 'show configuration interfaces {0}' -f $ifName }
                      else { 'show running-config interface {0}' -f $ifName }
            $capture = Invoke-NetDeviceCommand -Device $device -CommandList @($cfgCmd) -Context $netContext
            $runningConfig = $capture.Output
            if (-not $capture.Succeeded) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target ('{0}/{1}' -f $device, $ifName) `
                    -Message ('Interface configuration could not be read: {0}' -f $capture.Error)
            }
        } catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target ('{0}/{1}' -f $device, $ifName) `
                -Message ('Interface configuration unreadable: {0}' -f $_.Exception.Message)
        }

        if (-not $runningConfig) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target ('{0}/{1}' -f $device, $ifName) `
                -Message 'EXCLUDED - the interface returned no configuration, so it may not exist on this device.'
            continue
        }

        $statusLine = (@($statusText -split "`n") | Where-Object { $_ -match [regex]::Escape($ifName) } | Select-Object -First 1)
        $description = ''
        if ($runningConfig -match '(?im)^\s*description\s+(.+)$') { $description = $Matches[1].Trim() }

        $isCurrentlyDown = $runningConfig -match '(?im)^\s*shutdown\s*$' -or $runningConfig -match '(?im)^\s*disable;?\s*$'
        $wantDown = ($State -eq 'Shutdown')
        if ($isCurrentlyDown -eq $wantDown) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0}/{1}' -f $device, $ifName) `
                -Message ('Skipped - interface is already {0}' -f $State)
            continue
        }

        # An uplink is the port whose loss takes everything behind it with it.
        $looksLikeUplink = ($description -match '(?i)uplink|trunk|core|wan|isp|port-?channel|lag') -or
                           ($runningConfig -match '(?im)^\s*switchport mode trunk') -or
                           ($ifName -match '(?i)^(port-?channel|ae|te|hundredgig|fortygig|twentyfivegig)')
        if ($looksLikeUplink -and -not $IncludeUplinkPorts) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target ('{0}/{1}' -f $device, $ifName) `
                -Message 'EXCLUDED - looks like an uplink or trunk. Pass -IncludeUplinkPorts to include it deliberately.'
            continue
        }

        $macsOnPort = @(@($macText -split "`n") | Where-Object { $_ -match [regex]::Escape($ifName) })

        $results.Add([PSCustomObject]@{
            Name            = ('{0} / {1}' -f $device, $ifName)
            Id              = ('{0}|{1}' -f $device, $ifName)
            Device          = $device
            Interface       = $ifName
            Vendor          = $Vendor
            RequestedState  = $State
            CurrentlyDown   = $isCurrentlyDown
            StatusLine      = "$statusLine"
            Description     = $description
            LooksLikeUplink = $looksLikeUplink
            MacAddressesOnPort = $macsOnPort.Count
            ConnectedEvidence  = (($macsOnPort | Select-Object -First 5) -join ' | ')
            RunningConfig   = $runningConfig
            Ticket          = $TicketReference
            Impact          = if ($wantDown) { 'Removes service from whatever is on this port, immediately' }
                              else { 'Restores the port; whatever is attached comes back online' }
        })
    }
}
""", config=True),
    act=r"""
# The previous configuration is the rollback, so it is in the audit trail
# before the change, not after.
Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
    'Pre-change interface configuration (rollback reference): {0}' -f
    ($item.RunningConfig -replace "`r?`n", ' | '))

$syntax = $stateMap[$item.Vendor]
$configLines = @(
    $syntax.Config
    ($syntax.Enter -f $item.Interface)
    $(if ($item.RequestedState -eq 'Shutdown') { $syntax.Down } else { $syntax.Up })
    $syntax.Exit
)
if ($SaveConfiguration -and $syntax.Save) { $configLines += $syntax.Save }

$configResult = Invoke-NetDeviceConfig -Device $item.Device -ConfigLine $configLines -Context $netContext
if (-not $configResult.Succeeded) {
    throw ('Device rejected the configuration: {0}' -f $configResult.Rejections)
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Interface set to {0} (was {1}, {2} MAC(s) seen on the port, ticket {3}). Transcript: {4}' -f
    $item.RequestedState, $(if ($item.CurrentlyDown) { 'down' } else { 'up' }),
    $item.MacAddressesOnPort, $item.Ticket, ($configResult.Transcript -replace "`r?`n", ' | '))
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = $item.RequestedState
    Detail = ('{0} MAC(s) were on the port' -f $item.MacAddressesOnPort); Succeeded = $true })
""")

SPECS[9] = dict(
    file='Set-NetInterfaceDescription',
    modules=['Posh-SSH'],
    synopsis='Sets or clears interface descriptions.',
    desc='Writes an interface description, or removes one. Cosmetic: nothing about how the port '
         'forwards traffic changes.',
    params=CONN_PARAMS + [
        dict(name='Interface', help='Exact interface name(s).',
             decl="[Parameter(Mandatory)]\n    [ValidatePattern('^[A-Za-z][A-Za-z0-9/._:-]*$')]\n    [string[]]$Interface"),
        dict(name='Description',
             help='Description to set. Omit with -Clear to remove the existing one.',
             decl="[string]$Description"),
        dict(name='Clear', help='Remove the description instead of setting one.',
             decl="[switch]$Clear"),
        dict(name='SaveConfiguration', help='Write the running configuration to startup after the change.',
             decl="[switch]$SaveConfiguration")],
    perms='An account with configuration privilege on the device.',
    actionVerb='Set interface description',
    rollback='The previous description is captured and logged before the change. Re-apply it to '
             'revert, or use -Clear.',
    notes='Cosmetic and safe, which is why this row is not approval-gated. It still captures the '
          'previous description before overwriting it - a port description is often the only record '
          'of what is attached, and losing it silently would be a real cost for a change described '
          'as harmless.',
    examples=[("-DeviceName SW01 -Interface GigabitEthernet1/0/24 -Description 'AP-Floor3-East'",
               'Sets a description.'),
              ("-DeviceName SW01 -Interface GigabitEthernet1/0/24 -Clear -WhatIf",
               'Shows the description that would be removed.')],
    cleanup=CLEANUP,
    discover=net(r"""
if (-not $Clear -and -not $Description) {
    throw 'Supply -Description, or -Clear to remove the existing one.'
}
if ($Clear -and $Description) {
    throw '-Clear and -Description are mutually exclusive.'
}

$descMap = @{
    'cisco-ios'     = @{ Config = 'configure terminal'; Enter = 'interface {0}'; Set = 'description {0}'; Remove = 'no description'; Exit = 'end'; Save = 'write memory' }
    'cisco-nxos'    = @{ Config = 'configure terminal'; Enter = 'interface {0}'; Set = 'description {0}'; Remove = 'no description'; Exit = 'end'; Save = 'copy running-config startup-config' }
    'arista-eos'    = @{ Config = 'configure';          Enter = 'interface {0}'; Set = 'description {0}'; Remove = 'no description'; Exit = 'end'; Save = 'write memory' }
    'juniper-junos' = @{ Config = 'configure';          Enter = 'edit interfaces {0}'; Set = 'set description "{0}"'; Remove = 'delete description'; Exit = 'commit and-quit'; Save = '' }
}
if (-not $descMap.ContainsKey($Vendor)) {
    throw ('No description syntax is defined for vendor "{0}". Commands are not guessed at.' -f $Vendor)
}

foreach ($device in $DeviceName) {
    foreach ($ifName in $Interface) {
        $runningConfig = ''
        try {
            $cfgCmd = if ($Vendor -eq 'juniper-junos') { 'show configuration interfaces {0}' -f $ifName }
                      else { 'show running-config interface {0}' -f $ifName }
            $runningConfig = (Invoke-NetDeviceCommand -Device $device -CommandList @($cfgCmd) -Context $netContext).Output
        } catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target ('{0}/{1}' -f $device, $ifName) `
                -Message ('Interface configuration unreadable: {0}' -f $_.Exception.Message)
        }
        if (-not $runningConfig) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target ('{0}/{1}' -f $device, $ifName) `
                -Message 'EXCLUDED - the interface returned no configuration, so it may not exist on this device.'
            continue
        }

        $current = ''
        if ($runningConfig -match '(?im)^\s*description\s+(.+)$') { $current = $Matches[1].Trim() }

        $wanted = if ($Clear) { '' } else { $Description }
        if ($current -eq $wanted) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0}/{1}' -f $device, $ifName) `
                -Message 'Skipped - the description already has this value (idempotent)'
            continue
        }

        $results.Add([PSCustomObject]@{
            Name               = ('{0} / {1}' -f $device, $ifName)
            Id                 = ('{0}|{1}' -f $device, $ifName)
            Device             = $device
            Interface          = $ifName
            Vendor             = $Vendor
            CurrentDescription = $current
            NewDescription     = $wanted
            Operation          = if ($Clear) { 'Clear' } else { 'Set' }
        })
    }
}
""", config=True),
    act=r"""
Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
    'Previous description (rollback reference): "{0}"' -f $item.CurrentDescription)

$syntax = $descMap[$item.Vendor]
$configLines = @(
    $syntax.Config
    ($syntax.Enter -f $item.Interface)
    $(if ($item.Operation -eq 'Clear') { $syntax.Remove } else { ($syntax.Set -f $item.NewDescription) })
    $syntax.Exit
)
if ($SaveConfiguration -and $syntax.Save) { $configLines += $syntax.Save }

$configResult = Invoke-NetDeviceConfig -Device $item.Device -ConfigLine $configLines -Context $netContext
if (-not $configResult.Succeeded) {
    throw ('Device rejected the configuration: {0}' -f $configResult.Rejections)
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Description "{0}" -> "{1}"' -f $item.CurrentDescription, $item.NewDescription)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = $item.Operation
    Detail = ('"{0}" -> "{1}"' -f $item.CurrentDescription, $item.NewDescription); Succeeded = $true })
""")

SPECS[10] = dict(
    file='Set-NetInterfaceVlan',
    modules=['Posh-SSH'],
    synopsis='Changes the access VLAN on an interface, behind an approval gate.',
    desc='Moves a port to a different access VLAN. The port keeps its link but everything on it '
         'lands in a different broadcast domain, so the device it serves loses its gateway, its '
         'DHCP scope and its address. The full pre-change interface configuration is captured as '
         'the rollback the guardrail asks for.',
    params=CONN_PARAMS + [
        dict(name='Interface', help='Exact interface name(s).',
             decl="[Parameter(Mandatory)]\n    [ValidatePattern('^[A-Za-z][A-Za-z0-9/._:-]*$')]\n    [string[]]$Interface"),
        dict(name='VlanId', help='Target access VLAN id.',
             decl="[Parameter(Mandatory)]\n    [ValidateRange(1,4094)]\n    [int]$VlanId"),
        dict(name='RollbackConfigPath',
             help='Directory to write the pre-change interface configuration to. This file is the '
                  'rollback the guardrail on this use case requires.',
             decl="[string]$RollbackConfigPath"),
        dict(name='IncludeTrunkPorts',
             help='Permit acting on a trunk port. Off by default: setting an access VLAN on a trunk '
                  'changes its mode and drops every VLAN it carried.',
             decl="[switch]$IncludeTrunkPorts"),
        dict(name='SaveConfiguration', help='Write the running configuration to startup after the change.',
             decl="[switch]$SaveConfiguration")],
    perms='An account with configuration privilege on the device.',
    actionVerb='Change access VLAN',
    reason='Ticketed VLAN change',
    rollback='The complete pre-change interface configuration is captured, logged, and written to '
             '-RollbackConfigPath. Re-applying that block restores the port exactly. If '
             '-SaveConfiguration was NOT used, a device reload also reverts the change.',
    notes='A VLAN change is quieter than a shutdown and often worse to diagnose: the link stays up, '
          'the port counters increment, and the device on the other end simply stops being able to '
          'reach anything. The target VLAN is verified to exist on the device before the change is '
          'proposed - moving a port to a VLAN the switch does not have is a silent black hole.',
    examples=[("-DeviceName SW01 -Interface GigabitEthernet1/0/24 -VlanId 120 -RollbackConfigPath .\\\\rollback",
               'REPORT ONLY. Captures the rollback config and raises an approval.'),
              ("-DeviceName SW01 -Interface GigabitEthernet1/0/24 -VlanId 120 "
               "-RollbackConfigPath .\\\\rollback -ApprovalReference APR-... -TicketReference CHG0012345",
               'Applies an approved VLAN change.')],
    cleanup=CLEANUP,
    discover=net(r"""
$vlanMap = @{
    'cisco-ios'  = @{ Config = 'configure terminal'; Enter = 'interface {0}'; Set = 'switchport access vlan {0}'; Exit = 'end'; Save = 'write memory'; ShowVlan = 'show vlan brief' }
    'cisco-nxos' = @{ Config = 'configure terminal'; Enter = 'interface {0}'; Set = 'switchport access vlan {0}'; Exit = 'end'; Save = 'copy running-config startup-config'; ShowVlan = 'show vlan brief' }
    'arista-eos' = @{ Config = 'configure';          Enter = 'interface {0}'; Set = 'switchport access vlan {0}'; Exit = 'end'; Save = 'write memory'; ShowVlan = 'show vlan' }
}
if (-not $vlanMap.ContainsKey($Vendor)) {
    throw ('No access-VLAN syntax is defined for vendor "{0}". Junos switching syntax differs enough ' +
           'that it is not assumed here. Commands are not guessed at.' -f $Vendor)
}
$syntax = $vlanMap[$Vendor]

foreach ($device in $DeviceName) {
    # A port moved to a VLAN the switch does not have is a silent black hole.
    $vlanText = ''
    try {
        $vlanText = (Invoke-NetDeviceCommand -Device $device -CommandList @($syntax.ShowVlan) -Context $netContext).Output
    } catch {
        throw ('Could not read the VLAN list from {0}: {1}. Refusing to move a port to a VLAN whose ' +
               'existence is unverified.' -f $device, $_.Exception.Message)
    }
    $vlanExists = @($vlanText -split "`n") | Where-Object { $_ -match ('^\s*{0}\s' -f $VlanId) }
    if (-not $vlanExists) {
        throw ('VLAN {0} does not exist on {1}. Moving a port to a non-existent VLAN silently ' +
               'blackholes it. Create the VLAN first.' -f $VlanId, $device)
    }

    foreach ($ifName in $Interface) {
        $runningConfig = ''
        try {
            $runningConfig = (Invoke-NetDeviceCommand -Device $device `
                -CommandList @(('show running-config interface {0}' -f $ifName)) -Context $netContext).Output
        } catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target ('{0}/{1}' -f $device, $ifName) `
                -Message ('Interface configuration unreadable: {0}' -f $_.Exception.Message)
        }
        if (-not $runningConfig) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target ('{0}/{1}' -f $device, $ifName) `
                -Message 'EXCLUDED - the interface returned no configuration, so it may not exist on this device.'
            continue
        }

        $isTrunk = $runningConfig -match '(?im)^\s*switchport mode trunk'
        if ($isTrunk -and -not $IncludeTrunkPorts) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target ('{0}/{1}' -f $device, $ifName) `
                -Message 'EXCLUDED - trunk port. Setting an access VLAN changes its mode and drops every VLAN it carried. Pass -IncludeTrunkPorts to include it deliberately.'
            continue
        }

        $currentVlan = ''
        if ($runningConfig -match '(?im)^\s*switchport access vlan\s+(\d+)') { $currentVlan = $Matches[1] }
        if ($currentVlan -eq "$VlanId") {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0}/{1}' -f $device, $ifName) `
                -Message ('Skipped - already in VLAN {0} (idempotent)' -f $VlanId)
            continue
        }

        $description = ''
        if ($runningConfig -match '(?im)^\s*description\s+(.+)$') { $description = $Matches[1].Trim() }

        # Written now, while the port still works.
        $rollbackFile = ''
        if ($RollbackConfigPath) {
            if (-not (Test-Path -LiteralPath $RollbackConfigPath)) {
                New-Item -Path $RollbackConfigPath -ItemType Directory -Force | Out-Null
            }
            $safe = ('{0}-{1}' -f $device, $ifName) -replace '[^A-Za-z0-9._-]', '_'
            $rollbackFile = Join-Path $RollbackConfigPath ('{0}-{1}.cfg' -f $safe, (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Set-Content -LiteralPath $rollbackFile -Value $runningConfig -Encoding UTF8
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0}/{1}' -f $device, $ifName) `
                -Message ('Rollback configuration written: {0}' -f $rollbackFile)
        } else {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target ('{0}/{1}' -f $device, $ifName) `
                -Message 'No -RollbackConfigPath given; the rollback exists only in this log.'
        }

        $results.Add([PSCustomObject]@{
            Name         = ('{0} / {1}' -f $device, $ifName)
            Id           = ('{0}|{1}' -f $device, $ifName)
            Device       = $device
            Interface    = $ifName
            Vendor       = $Vendor
            CurrentVlan  = $currentVlan
            NewVlan      = $VlanId
            Description  = $description
            IsTrunk      = $isTrunk
            RollbackFile = $rollbackFile
            RunningConfig= $runningConfig
            Impact       = 'Port stays up; whatever is attached lands in a different broadcast domain and loses its gateway, DHCP scope and address'
        })
    }
}
""", config=True),
    act=r"""
Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
    'Pre-change interface configuration (rollback{0}): {1}' -f
    $(if ($item.RollbackFile) { ' also at ' + $item.RollbackFile } else { ' - LOG ONLY' }),
    ($item.RunningConfig -replace "`r?`n", ' | '))

$syntax = $vlanMap[$item.Vendor]
$configLines = @(
    $syntax.Config
    ($syntax.Enter -f $item.Interface)
    ($syntax.Set -f $item.NewVlan)
    $syntax.Exit
)
if ($SaveConfiguration -and $syntax.Save) { $configLines += $syntax.Save }

$configResult = Invoke-NetDeviceConfig -Device $item.Device -ConfigLine $configLines -Context $netContext
if (-not $configResult.Succeeded) {
    throw ('Device rejected the configuration: {0}' -f $configResult.Rejections)
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Access VLAN {0} -> {1}. Transcript: {2}' -f
    $(if ($item.CurrentVlan) { $item.CurrentVlan } else { '(unset)' }), $item.NewVlan,
    ($configResult.Transcript -replace "`r?`n", ' | '))
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'VlanChanged'
    Detail = ('{0} -> {1}' -f $item.CurrentVlan, $item.NewVlan); Succeeded = $true })
""")

SPECS[15] = dict(
    file='Set-NetDeviceNtp',
    modules=['Posh-SSH'],
    synopsis='Configures NTP servers on network devices and reports sync state.',
    desc='Reports each device\'s current NTP configuration and synchronisation state, and applies '
         'the standard server list where it differs. Low risk, and worth getting right: log '
         'timestamps that disagree across devices make an incident timeline useless.',
    params=CONN_PARAMS + [
        dict(name='NtpServer',
             help='Standard NTP server list from the SOP. Reported against, and applied when '
                  '-Apply is passed.',
             decl="[Parameter(Mandatory)]\n    [string[]]$NtpServer"),
        dict(name='Apply', help='Add missing NTP servers. Reports only when omitted.',
             decl="[switch]$Apply"),
        dict(name='RemoveUnlisted',
             help='Also remove NTP servers that are not in -NtpServer. Off by default: an unlisted '
                  'server may be a deliberate local reference.',
             decl="[switch]$RemoveUnlisted"),
        dict(name='SaveConfiguration', help='Write the running configuration to startup after the change.',
             decl="[switch]$SaveConfiguration")],
    perms='An account with configuration privilege on the device; read-only is enough to report.',
    actionVerb='Configure NTP server',
    rollback='The previous NTP configuration is captured and logged before any change. Re-apply it '
             'to revert.',
    notes='Reports by default and changes nothing without -Apply. Removing servers is separately '
          'opt-in because an unlisted NTP source is often a deliberate local reference rather than '
          'drift, and stripping a device down to servers it cannot reach leaves it worse than it '
          'started - unsynchronised with no fallback.',
    examples=[("-DeviceName SW01,SW02 -NtpServer 10.0.0.10,10.0.0.11",
               'REPORT ONLY. Shows current NTP state against the standard.'),
              ("-DeviceName SW01 -NtpServer 10.0.0.10,10.0.0.11 -Apply -SaveConfiguration",
               'Adds the missing standard servers and saves.')],
    cleanup=CLEANUP,
    discover=net(r"""
$ntpMap = @{
    'cisco-ios'     = @{ Config = 'configure terminal'; Add = 'ntp server {0}'; Remove = 'no ntp server {0}'; Exit = 'end'; Save = 'write memory'; Show = @('show ntp status', 'show running-config | include ^ntp server') }
    'cisco-nxos'    = @{ Config = 'configure terminal'; Add = 'ntp server {0}'; Remove = 'no ntp server {0}'; Exit = 'end'; Save = 'copy running-config startup-config'; Show = @('show ntp peer-status', 'show running-config | include ^ntp server') }
    'arista-eos'    = @{ Config = 'configure';          Add = 'ntp server {0}'; Remove = 'no ntp server {0}'; Exit = 'end'; Save = 'write memory'; Show = @('show ntp status', 'show running-config | include ^ntp server') }
    'juniper-junos' = @{ Config = 'configure';          Add = 'set system ntp server {0}'; Remove = 'delete system ntp server {0}'; Exit = 'commit and-quit'; Save = ''; Show = @('show ntp associations', 'show configuration system ntp') }
}
if (-not $ntpMap.ContainsKey($Vendor)) {
    throw ('No NTP syntax is defined for vendor "{0}". Commands are not guessed at.' -f $Vendor)
}
$syntax = $ntpMap[$Vendor]

foreach ($device in $DeviceName) {
    $ntpText = ''
    try {
        $captures = @(Invoke-NetDeviceCommand -Device $device -CommandList $syntax.Show -Context $netContext)
        $ntpText = (($captures | ForEach-Object { $_.Output }) -join "`n")
    } catch {
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $device `
            -Message ('Unreachable or NTP state unreadable: {0}' -f $_.Exception.Message)
        continue
    }

    $configured = @()
    foreach ($line in ($ntpText -split "`n")) {
        if ($line -match '(?i)ntp server\s+(\S+)') { $configured += $Matches[1] }
    }
    $configured = @($configured | Select-Object -Unique)

    $synchronised = $ntpText -match '(?i)clock is synchronized|synchronised|reach.*\d'
    $missing = @($NtpServer | Where-Object { $configured -notcontains $_ })
    $unlisted = @($configured | Where-Object { $NtpServer -notcontains $_ })

    if ($missing.Count -eq 0 -and (-not $RemoveUnlisted -or $unlisted.Count -eq 0)) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $device `
            -Message 'Skipped - NTP configuration already matches the standard (idempotent)'
        continue
    }
    if (-not $Apply) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $device -Message (
            'Reported only: {0} missing, {1} unlisted. Pass -Apply to change it.' -f $missing.Count, $unlisted.Count)
    }

    $results.Add([PSCustomObject]@{
        Name             = $device
        Id               = $device
        Device           = $device
        Vendor           = $Vendor
        Synchronised     = [bool]$synchronised
        ConfiguredServers= ($configured -join '; ')
        StandardServers  = ($NtpServer -join '; ')
        MissingServers   = ($missing -join '; ')
        UnlistedServers  = ($unlisted -join '; ')
        WillAdd          = if ($Apply) { ($missing -join '; ') } else { '' }
        WillRemove       = if ($Apply -and $RemoveUnlisted) { ($unlisted -join '; ') } else { '' }
        Actionable       = [bool]$Apply
        PreviousConfig   = $ntpText
    })
}
""", config=True),
    act=r"""
if (-not $item.Actionable) {
    $actions.Add([PSCustomObject]@{
        Name = $item.Name; Action = 'ReportedOnly'
        Detail = ('missing: {0}' -f $item.MissingServers); Succeeded = $true })
} else {
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
        'Previous NTP configuration (rollback reference): {0}' -f
        ($item.PreviousConfig -replace "`r?`n", ' | '))

    $syntax = $ntpMap[$item.Vendor]
    $configLines = @($syntax.Config)
    foreach ($server in ($item.WillAdd -split ';')) {
        $s = $server.Trim()
        if ($s) { $configLines += ($syntax.Add -f $s) }
    }
    foreach ($server in ($item.WillRemove -split ';')) {
        $s = $server.Trim()
        if ($s) { $configLines += ($syntax.Remove -f $s) }
    }
    $configLines += $syntax.Exit
    if ($SaveConfiguration -and $syntax.Save) { $configLines += $syntax.Save }

    $configResult = Invoke-NetDeviceConfig -Device $item.Device -ConfigLine $configLines -Context $netContext
    if (-not $configResult.Succeeded) {
        throw ('Device rejected the configuration: {0}' -f $configResult.Rejections)
    }

    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
        'NTP updated. Added: {0}. Removed: {1}. Synchronisation takes several minutes to settle.' -f
        $(if ($item.WillAdd) { $item.WillAdd } else { 'none' }),
        $(if ($item.WillRemove) { $item.WillRemove } else { 'none' }))
    $actions.Add([PSCustomObject]@{
        Name = $item.Name; Action = 'NtpConfigured'
        Detail = ('added {0}' -f $item.WillAdd); Succeeded = $true })
}
""")
