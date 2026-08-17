<#
.SYNOPSIS
    Terminates a Windows process under an approval gate and a protected-process blacklist.

.DESCRIPTION
    Kills a named or PID-identified process on one or more servers, subject to
    controls that cannot be bypassed:

      1. A hard PROTECTED-PROCESS BLACKLIST from Config\config.json. Killing
         lsass, csrss, wininit, services or similar bluescreens the host. These
         are refused unconditionally - there is no parameter that overrides them.
      2. A valid approval reference raised for THIS script.
      3. Explicit target confirmation - the caller must give a process name or
         a PID, and the script reports exactly what matched BEFORE acting.

    Without -ApprovalReference the script runs in REQUEST mode: it resolves the
    matching processes, raises an approval artifact listing every PID it would
    kill, and stops without terminating anything.

    This implements the workbook guardrail verbatim: "Killing wrong process
    disrupts apps; confirm PID/name + protected-process blacklist".

.PARAMETER ComputerName
    Servers to act on. Defaults to the local computer.

.PARAMETER Name
    Process name to terminate (without .exe). Wildcards are deliberately NOT
    supported - a wildcard process kill is how outages happen.

.PARAMETER ProcessId
    Specific PID to terminate. Mutually exclusive with -Name.

.PARAMETER ApprovalReference
    Approval token from New-ApprovalRequest, after a human has approved it.
    Without this the script terminates nothing.

.PARAMETER Reason
    Change reason recorded in the approval artifact and the audit log.

.PARAMETER TicketReference
    ITSM ticket number recorded in the audit trail.

.PARAMETER MinimumRuntimeMinutes
    Only consider processes that have been running at least this long. Guards
    against killing a process that has just been restarted. Default 0.

.PARAMETER Credential
    Credential for the remote operation.

.PARAMETER ConfigPath
    Override the path to config.json.

.EXAMPLE
    .\Stop-WinServerProcess.ps1 -ComputerName SRV01 -Name notepad -Reason 'Hung session'

    REQUEST mode. Lists matching PIDs, raises an approval, kills nothing.

.EXAMPLE
    .\Stop-WinServerProcess.ps1 -ComputerName SRV01 -Name notepad -ApprovalReference APR-20260808143000-9921

    Terminates the approved processes and logs every PID individually.

.EXAMPLE
    .\Stop-WinServerProcess.ps1 -ComputerName SRV01 -ProcessId 4812 -ApprovalReference APR-... -WhatIf

    Shows what would be terminated without acting.

.NOTES
    Source use case      : #6 - Windows Process Kill
    Category             : Windows Server
    Technology           : PowerShell
    Difficulty           : Low
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "Killing wrong process disrupts apps; confirm PID/name
                            + protected-process blacklist"

    Required permissions : Local Administrator on the target.
    Required modules     : IT-Automation-Common (bundled). CimCmdlets (built in).
    Authentication       : Integrated Kerberos over WinRM, or -Credential.

    Rollback             : None. A terminated process cannot be un-terminated.
                           The blacklist and approval gate run before the action
                           precisely because there is no recovery after it.
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'ByName')]
[OutputType([PSCustomObject])]
param(
    [Parameter(ValueFromPipelineByPropertyName)]
    [ValidateNotNullOrEmpty()]
    [string[]]$ComputerName = $env:COMPUTERNAME,

    [Parameter(Mandatory, ParameterSetName = 'ByName')]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^[^\*\?]+$')]   # no wildcards - see .PARAMETER Name
    [string]$Name,

    [Parameter(Mandatory, ParameterSetName = 'ById')]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$ProcessId,

    [string]$ApprovalReference,

    [string]$Reason = 'Unresponsive process',

    [string]$TicketReference,

    [ValidateRange(0, 10080)]
    [int]$MinimumRuntimeMinutes = 0,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Stop-WinServerProcess'
    $selector = if ($PSCmdlet.ParameterSetName -eq 'ByName') { "name='$Name'" } else { "pid=$ProcessId" }
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'START. Selector={0} Reason="{1}" ApprovalSupplied={2}' -f $selector, $Reason, [bool]$ApprovalReference)

    try {
        $config = if ($ConfigPath) { Get-AutomationConfig -Path $ConfigPath } else { Get-AutomationConfig }
    } catch {
        # Fail closed: without the blacklist this script must not run at all.
        throw ('Cannot read configuration, refusing to proceed without the protected-process list: {0}' -f
               $_.Exception.Message)
    }

    $blacklist = @()
    if ($config.PSObject.Properties.Name -contains 'safety' -and
        $config.safety.PSObject.Properties.Name -contains 'protectedProcesses') {
        $blacklist = @($config.safety.protectedProcesses)
    }
    if ($blacklist.Count -eq 0) {
        throw 'safety.protectedProcesses is empty in config.json. Refusing to run without a protected-process blacklist.'
    }
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'Protected-process blacklist loaded ({0} entries). These cannot be overridden.' -f $blacklist.Count)

    $candidates = [System.Collections.Generic.List[PSCustomObject]]::new()
    $results    = [System.Collections.Generic.List[PSCustomObject]]::new()
}

process {
    foreach ($computer in $ComputerName) {
        $session = $null
        try {
            $common = @{ ErrorAction = 'Stop' }
            if ($computer -ne $env:COMPUTERNAME) {
                $sp = @{ ComputerName = $computer; ErrorAction = 'Stop' }
                if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $sp.Credential = $Credential }
                $session = New-CimSession @sp
                $common.CimSession = $session
            }

            $filter = if ($PSCmdlet.ParameterSetName -eq 'ByName') {
                          "Name='{0}.exe' OR Name='{0}'" -f $Name
                      } else {
                          "ProcessId=$ProcessId"
                      }
            $procs = @(Get-CimInstance -ClassName Win32_Process -Filter $filter @common)

            if ($procs.Count -eq 0) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $computer `
                    -Message ('No process matched {0}' -f $selector)
                continue
            }

            foreach ($p in $procs) {
                $bare = [System.IO.Path]::GetFileNameWithoutExtension($p.Name)

                # HARD REFUSAL. Not overridable, by design.
                $isProtected = $blacklist | Where-Object { $_ -and $bare -eq $_ }
                if ($isProtected) {
                    Write-AutomationLog -ScriptName $scriptName -Level ERROR `
                        -Target ("{0}:{1}({2})" -f $computer, $bare, $p.ProcessId) `
                        -Message 'REFUSED - process is on the protected blacklist and cannot be terminated by this tool'
                    $results.Add([PSCustomObject]@{
                        ComputerName = $computer; ProcessName = $bare; ProcessId = $p.ProcessId
                        Action = 'Refused'; Detail = 'Protected process'; Succeeded = $false
                    })
                    continue
                }

                $runtimeMin = $null
                if ($p.CreationDate) {
                    $runtimeMin = [math]::Round(((Get-Date) - $p.CreationDate).TotalMinutes, 1)
                    if ($runtimeMin -lt $MinimumRuntimeMinutes) {
                        Write-AutomationLog -ScriptName $scriptName -Level WARN `
                            -Target ("{0}:{1}({2})" -f $computer, $bare, $p.ProcessId) `
                            -Message ('Skipped - running {0} min, below MinimumRuntimeMinutes {1}' -f
                                      $runtimeMin, $MinimumRuntimeMinutes)
                        $results.Add([PSCustomObject]@{
                            ComputerName = $computer; ProcessName = $bare; ProcessId = $p.ProcessId
                            Action = 'Skipped'; Detail = "Runtime ${runtimeMin}min below minimum"; Succeeded = $false
                        })
                        continue
                    }
                }

                $candidates.Add([PSCustomObject]@{
                    ComputerName   = $computer
                    ProcessName    = $bare
                    ProcessId      = $p.ProcessId
                    WorkingSetMB   = [math]::Round($p.WorkingSetSize / 1MB, 2)
                    CreationDate   = $p.CreationDate
                    RuntimeMinutes = $runtimeMin
                    CommandLine    = $p.CommandLine
                })
            }
        } catch {
            $msg = $_.Exception.Message
            Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $computer `
                -Message ('Failed to enumerate processes: {0}' -f $msg)
            $results.Add([PSCustomObject]@{
                ComputerName = $computer; ProcessName = $null; ProcessId = $null
                Action = 'Failed'; Detail = $msg; Succeeded = $false
            })
        } finally {
            if ($session) { Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue }
        }
    }
}

end {
    if ($candidates.Count -eq 0) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message 'No eligible process to terminate.'
        Write-Output $results.ToArray()
        return
    }

    # ---------------------------------------------------- REQUEST mode ------
    if (-not $ApprovalReference) {
        foreach ($c in $candidates) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO `
                -Target ("{0}:{1}({2})" -f $c.ComputerName, $c.ProcessName, $c.ProcessId) `
                -Message ('CANDIDATE for termination - {0} MB, running {1} min' -f $c.WorkingSetMB, $c.RuntimeMinutes)
        }
        $request = New-ApprovalRequest -ScriptName $scriptName `
            -Action ('Terminate {0} process(es) matching {1}. Reason: {2}' -f $candidates.Count, $selector, $Reason) `
            -ChangeSet $candidates.ToArray()

        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $request.Reference -Message (
            'REQUEST mode - nothing was terminated. Supply -ApprovalReference {0} once approved.' -f $request.Reference)

        Write-Warning ('No process terminated. Approval reference: {0}' -f $request.Reference)
        Write-Output ([PSCustomObject]@{
            Mode = 'RequestApproval'; ApprovalReference = $request.Reference
            CandidateCount = $candidates.Count; Candidates = $candidates.ToArray(); Terminated = $false
        })
        return
    }

    # ---------------------------------------------------- EXECUTE mode ------
    $approval = Test-ApprovalReference -Reference $ApprovalReference -ScriptName $scriptName
    if (-not $approval.IsValid) {
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $ApprovalReference `
            -Message ('REFUSED to execute: {0}' -f $approval.Reason)
        throw ('Approval validation failed: {0}' -f $approval.Reason)
    }
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $ApprovalReference `
        -Message ('Approval accepted. {0}' -f $approval.Reason)

    foreach ($c in $candidates) {
        $label = "{0}:{1}({2})" -f $c.ComputerName, $c.ProcessName, $c.ProcessId
        $action = "Terminate process (approval $ApprovalReference, ticket $TicketReference)"

        if (-not $PSCmdlet.ShouldProcess($label, $action)) {
            $results.Add([PSCustomObject]@{
                ComputerName = $c.ComputerName; ProcessName = $c.ProcessName; ProcessId = $c.ProcessId
                Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true
            })
            continue
        }

        # Log the specific object BEFORE acting on it - the workbook requires
        # every object acted upon to be individually recorded.
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
            'TERMINATING. Approval={0} Ticket={1} Reason="{2}"' -f $ApprovalReference, $TicketReference, $Reason)

        $session = $null
        try {
            $common = @{ ErrorAction = 'Stop' }
            if ($c.ComputerName -ne $env:COMPUTERNAME) {
                $sp = @{ ComputerName = $c.ComputerName; ErrorAction = 'Stop' }
                if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $sp.Credential = $Credential }
                $session = New-CimSession @sp
                $common.CimSession = $session
            }
            $proc = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$($c.ProcessId)" @common

            # Idempotency: the process may already be gone between the candidate
            # scan and the approved execution. That is a success, not a failure.
            if (-not $proc) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label `
                    -Message 'Already gone - no action needed'
                $results.Add([PSCustomObject]@{
                    ComputerName = $c.ComputerName; ProcessName = $c.ProcessName; ProcessId = $c.ProcessId
                    Action = 'AlreadyGone'; Detail = 'Process no longer running'; Succeeded = $true
                })
                continue
            }

            $rc = Invoke-CimMethod -InputObject $proc -MethodName Terminate @common
            if ($rc.ReturnValue -eq 0) {
                Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message 'Terminated'
                $results.Add([PSCustomObject]@{
                    ComputerName = $c.ComputerName; ProcessName = $c.ProcessName; ProcessId = $c.ProcessId
                    Action = 'Terminated'; Detail = 'ReturnValue 0'; Succeeded = $true
                })
            } else {
                Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $label `
                    -Message ('Terminate returned {0}' -f $rc.ReturnValue)
                $results.Add([PSCustomObject]@{
                    ComputerName = $c.ComputerName; ProcessName = $c.ProcessName; ProcessId = $c.ProcessId
                    Action = 'Failed'; Detail = "ReturnValue $($rc.ReturnValue)"; Succeeded = $false
                })
            }
        } catch {
            $msg = $_.Exception.Message
            Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $label `
                -Message ('Terminate FAILED: {0}' -f $msg)
            $results.Add([PSCustomObject]@{
                ComputerName = $c.ComputerName; ProcessName = $c.ProcessName; ProcessId = $c.ProcessId
                Action = 'Failed'; Detail = $msg; Succeeded = $false
            })
        } finally {
            if ($session) { Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue }
        }
    }

    $ok  = @($results | Where-Object { $_.Succeeded })
    $bad = @($results | Where-Object { -not $_.Succeeded })
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'END. Succeeded={0} Failed/Refused={1} Approval={2}' -f $ok.Count, $bad.Count, $ApprovalReference)

    Write-Output $results.ToArray()

    if ($bad.Count -gt 0) { exit 1 }
}
