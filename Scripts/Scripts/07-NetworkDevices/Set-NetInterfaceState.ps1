<#
.SYNOPSIS
    Shuts or re-enables switch interfaces, behind an approval gate.

.DESCRIPTION
    Administratively shuts or unshuts named interfaces. Shutting the wrong
    port takes something offline with no warning, so the change set shows what
    is currently on each port before anybody approves it, and the interface
    must be named exactly - no wildcards.

    DESTRUCTIVE. This script is REPORT-ONLY by default: it produces the
    candidate list and stops. Nothing is deleted, wiped or failed over
    unless -Execute is passed AND a valid -ApprovalReference is supplied.
    A pre-action backup/export is taken where the platform allows it, and
    every object is logged individually before it is touched.

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
    Exact interface name(s), e.g. GigabitEthernet1/0/24. Wildcards are
    refused.

.PARAMETER State
    Desired administrative state.

.PARAMETER IncludeUplinkPorts
    Permit acting on a port that looks like an uplink or trunk. Off by
    default: shutting an uplink takes down everything behind it.

.PARAMETER SaveConfiguration
    Write the running configuration to startup after the change.

.PARAMETER Execute
    Actually perform the destructive action. Without this the script only
    reports what it would do.

.PARAMETER ProtectedList
    Path to a file of names/ids that must never be acted upon, one per line.
    Entries here are excluded unconditionally and the exclusion cannot be
    overridden by any other parameter.

.PARAMETER MinimumAgeDays
    Only consider objects older than this. A conservative default guards
    against acting on something created moments ago.

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
    .\Set-NetInterfaceState.ps1 -DeviceName SW01 -Interface GigabitEthernet1/0/24 -State Shutdown -TicketReference INC0012345

    REPORT ONLY. Shows what is on the port and raises an approval.

.EXAMPLE
    .\Set-NetInterfaceState.ps1 -DeviceName SW01 -Interface GigabitEthernet1/0/24 -State Shutdown -ApprovalReference APR-... -TicketReference INC0012345 -Execute

    Shuts an approved port.

.NOTES
    Source use case      : #8 - Enable/Disable Interface Ports
    Category             : Network Devices
    Technology           : Netmiko / Ansible
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Destructive / High-Impact
    Risk level           : High
    Human approval needed: YES
    Guardrails (col L)   : "Shutting the wrong port causes outage; ticket + interface confirmation before change"

    Required permissions : An account with configuration privilege on the device (enable / configure terminal).
    Required modules     : Posh-SSH
    Authentication       : SSH key or credential via Posh-SSH. NOTE:
                           Python/Netmiko is a better fit for multi-vendor CLI
                           parsing - see .NOTES.

    DESTRUCTIVE. Shutting a port removes service from whatever is on it,
    immediately and without warning to the user at the other end. The
    change set therefore includes the current status, the port description
    and what the MAC table has heard on that port, so an approver is
    looking at what is connected rather than at an interface name. A port
    whose description or status suggests an uplink or trunk is excluded
    unless -IncludeUplinkPorts is passed explicitly.

    Rollback             : The previous state and the full interface
                           configuration are captured and logged before the
                           change. Re-apply the opposite state to revert. If
                           -SaveConfiguration was NOT used, a device reload
                           also reverts the change.
#>

#Requires -Version 5.1
#Requires -Modules Posh-SSH

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
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
    [ValidateSet('Shutdown','NoShutdown')]
    [string]$State,

    [switch]$IncludeUplinkPorts,

    [switch]$SaveConfiguration,

    [switch]$Execute,

    [string]$ProtectedList,

    [ValidateRange(0, 3650)]
    [int]$MinimumAgeDays = 0,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Ticketed interface state change',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-NetInterfaceState'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #8 (Network Devices)'

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

    $protected = @()
    if ($ProtectedList -and (Test-Path -LiteralPath $ProtectedList)) {
        $protected = @(Get-Content -LiteralPath $ProtectedList |
            Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { $_.Trim() })
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Protected list loaded: {0} entry(ies). These are excluded unconditionally.' -f $protected.Count)
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
    } catch {
        $msg = $_.Exception.Message
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Message ('Discovery FAILED: {0}' -f $msg)
        $failures.Add([PSCustomObject]@{ Stage = 'Discovery'; Error = $msg })
    }
}

end {
    $candidates = @($results)

    # Hard exclusions and safety filters BEFORE anything else.
    if ($protected.Count -gt 0) {
        $before = $candidates.Count
        $candidates = @($candidates | Where-Object {
            $id = $_.Id; $nm = $_.Name
            -not ($protected | Where-Object { $_ -and ($id -like $_ -or $nm -like $_) })
        })
        if ($before -ne $candidates.Count) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
                'Protected list excluded {0} object(s).' -f ($before - $candidates.Count))
        }
    }
    if ($MinimumAgeDays -gt 0) {
        $cut = (Get-Date).AddDays(-$MinimumAgeDays)
        $before = $candidates.Count
        $candidates = @($candidates | Where-Object { -not $_.CreatedAt -or $_.CreatedAt -lt $cut })
        if ($before -ne $candidates.Count) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
                'Age filter (>{0}d) excluded {1} object(s).' -f $MinimumAgeDays, ($before - $candidates.Count))
        }
    }

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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Change interface admin state', $candidates.Count, $Reason, $TicketReference)
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

    if (-not $Execute) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'REPORT-ONLY - {0} candidate(s) identified, nothing was changed. Pass -Execute to act.' -f $candidates.Count)
        $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Enable/Disable Interface Ports (candidates)'
        Write-Output $candidates

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

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Change interface admin state')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Enable/Disable Interface Ports'
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
