<#
.SYNOPSIS
    Sets or clears interface descriptions.

.DESCRIPTION
    Writes an interface description, or removes one. Cosmetic: nothing about
    how the port forwards traffic changes.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

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

.PARAMETER Interface
    Exact interface name(s).

.PARAMETER Description
    Description to set. Omit with -Clear to remove the existing one.

.PARAMETER Clear
    Remove the description instead of setting one.

.PARAMETER SaveConfiguration
    Write the running configuration to startup after the change.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Set-NetInterfaceDescription.ps1 -DeviceName SW01 -Interface GigabitEthernet1/0/24 -Description 'AP-Floor3-East'

    Sets a description.

.EXAMPLE
    .\Set-NetInterfaceDescription.ps1 -DeviceName SW01 -Interface GigabitEthernet1/0/24 -Clear -WhatIf

    Shows the description that would be removed.

.NOTES
    Source use case      : #9 - Add/Remove Port Description
    Category             : Network Devices
    Technology           : Netmiko / Ansible
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Cosmetic config change; safe"

    Required permissions : An account with configuration privilege on the device.
    Required modules     : Posh-SSH
    Authentication       : SSH key or credential via Posh-SSH. NOTE:
                           Python/Netmiko is a better fit for multi-vendor CLI
                           parsing - see .NOTES.

    Cosmetic and safe, which is why this row is not approval-gated. It
    still captures the previous description before overwriting it - a port
    description is often the only record of what is attached, and losing
    it silently would be a real cost for a change described as harmless.

    Rollback             : The previous description is captured and logged
                           before the change. Re-apply it to revert, or use
                           -Clear.
#>

#Requires -Version 5.1
#Requires -Modules Posh-SSH

[CmdletBinding(SupportsShouldProcess)]
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
    [ValidatePattern('^[A-Za-z][A-Za-z0-9/._:-]*$')]
    [string[]]$Interface,

    [string]$Description,

    [switch]$Clear,

    [switch]$SaveConfiguration,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-NetInterfaceDescription'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #9 (Network Devices)'

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

        foreach ($openDevice in @($netContext.Sessions.Keys)) {
            try {
                Remove-SSHSession -SSHSession $netContext.Sessions[$openDevice] -ErrorAction Stop | Out-Null
            } catch {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $openDevice -Message (
                    'SSH session could not be closed cleanly: {0}' -f $_.Exception.Message)
            }
        }
        return
    }

    # Every candidate is logged individually BEFORE any action is taken.
    foreach ($c in $candidates) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0}' -f $c.Name) -Message 'CANDIDATE'
    }

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Set interface description')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Add/Remove Port Description'
    Write-Output $actions.ToArray()

    foreach ($openDevice in @($netContext.Sessions.Keys)) {
        try {
            Remove-SSHSession -SSHSession $netContext.Sessions[$openDevice] -ErrorAction Stop | Out-Null
        } catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $openDevice -Message (
                'SSH session could not be closed cleanly: {0}' -f $_.Exception.Message)
        }
    }
    if ($bad.Count -gt 0) { exit 1 }
}
