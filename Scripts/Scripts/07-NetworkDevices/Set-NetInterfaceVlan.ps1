<#
.SYNOPSIS
    Changes the access VLAN on an interface, behind an approval gate.

.DESCRIPTION
    Moves a port to a different access VLAN. The port keeps its link but
    everything on it lands in a different broadcast domain, so the device it
    serves loses its gateway, its DHCP scope and its address. The full
    pre-change interface configuration is captured as the rollback the
    guardrail asks for.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

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

.PARAMETER VlanId
    Target access VLAN id.

.PARAMETER RollbackConfigPath
    Directory to write the pre-change interface configuration to. This file is
    the rollback the guardrail on this use case requires.

.PARAMETER IncludeTrunkPorts
    Permit acting on a trunk port. Off by default: setting an access VLAN on a
    trunk changes its mode and drops every VLAN it carried.

.PARAMETER SaveConfiguration
    Write the running configuration to startup after the change.

.PARAMETER ApprovalReference
    Approval token from New-ApprovalRequest, after a human has approved it.
    Without this the script performs no change.

.PARAMETER RequestApproval
    Force REQUEST mode - produce the change set and raise an approval request,
    then stop, even if a reference was supplied.

.PARAMETER TicketReference
    ITSM ticket number recorded in the audit trail alongside the approval
    reference.

.PARAMETER Reason
    Change reason recorded in the approval artifact and the audit log.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Set-NetInterfaceVlan.ps1 -DeviceName SW01 -Interface GigabitEthernet1/0/24 -VlanId 120 -RollbackConfigPath .\\rollback

    REPORT ONLY. Captures the rollback config and raises an approval.

.EXAMPLE
    .\Set-NetInterfaceVlan.ps1 -DeviceName SW01 -Interface GigabitEthernet1/0/24 -VlanId 120 -RollbackConfigPath .\\rollback -ApprovalReference APR-... -TicketReference CHG0012345

    Applies an approved VLAN change.

.NOTES
    Source use case      : #10 - Add/Remove Port VLAN
    Category             : Network Devices
    Technology           : Netmiko / Ansible
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : High
    Human approval needed: YES
    Guardrails (col L)   : "VLAN change can drop connectivity; approval gate + rollback config"

    Required permissions : An account with configuration privilege on the device.
    Required modules     : Posh-SSH
    Authentication       : SSH key or credential via Posh-SSH. NOTE:
                           Python/Netmiko is a better fit for multi-vendor CLI
                           parsing - see .NOTES.

    A VLAN change is quieter than a shutdown and often worse to diagnose:
    the link stays up, the port counters increment, and the device on the
    other end simply stops being able to reach anything. The target VLAN
    is verified to exist on the device before the change is proposed -
    moving a port to a VLAN the switch does not have is a silent black
    hole.

    Rollback             : The complete pre-change interface configuration is
                           captured, logged, and written to
                           -RollbackConfigPath. Re-applying that block restores
                           the port exactly. If -SaveConfiguration was NOT
                           used, a device reload also reverts the change.
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

    [Parameter(Mandatory)]
    [ValidateRange(1,4094)]
    [int]$VlanId,

    [string]$RollbackConfigPath,

    [switch]$IncludeTrunkPorts,

    [switch]$SaveConfiguration,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Ticketed VLAN change',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-NetInterfaceVlan'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #10 (Network Devices)'

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

    # Risk = High: validate before doing anything at all.
    $pre = Test-Prerequisite -RequiredModule 'Posh-SSH'
    if (-not $pre.Passed) {
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Message $pre.Summary
        throw $pre.Summary
    }
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Pre-flight passed.'

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

    if ($RequestApproval -or -not $ApprovalReference) {
        $request = New-ApprovalRequest -ScriptName $scriptName -ChangeSet $candidates `
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Change access VLAN', $candidates.Count, $Reason, $TicketReference)
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $request.Reference -Message (
            'REQUEST mode - nothing was changed. Supply -ApprovalReference {0} once approved.' -f $request.Reference)
        Write-Warning ('No change made. Approval reference: {0}' -f $request.Reference)
        Write-Output ([PSCustomObject]@{
            Mode = 'RequestApproval'; ApprovalReference = $request.Reference
            CandidateCount = $candidates.Count; Candidates = $candidates; Changed = $false })

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

    $approvalCheck = Test-ApprovalReference -Reference $ApprovalReference -ScriptName $scriptName
    if (-not $approvalCheck.IsValid) {
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $ApprovalReference -Message (
            'REFUSED to execute: {0}' -f $approvalCheck.Reason)
        throw ('Approval validation failed: {0}' -f $approvalCheck.Reason)
    }
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $ApprovalReference -Message (
        'Approval accepted. {0} Ticket={1}' -f $approvalCheck.Reason, $TicketReference)

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Change access VLAN')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Add/Remove Port VLAN'
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
