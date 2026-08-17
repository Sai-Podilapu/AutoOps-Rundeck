<#
.SYNOPSIS
    Pulls a detailed point-in-time resource snapshot from a Windows server.

.DESCRIPTION
    A diagnostic pull rather than a fleet report: for each target it collects
    the resource summary plus the detail an engineer needs when investigating a
    specific host — top processes by memory and by CPU time, per-volume disk
    usage, network adapter throughput counters, and the largest recent system
    event-log errors.

    This script is READ-ONLY. It contains no write, modify or delete calls of
    any kind and is safe to schedule unattended.

    For a one-line-per-server fleet summary, use Get-WinServerResourceReport.ps1
    (use case #2). This script is the deeper single-host pull (use case #5).

.PARAMETER ComputerName
    Servers to pull. Accepts pipeline input. Defaults to the local computer.

.PARAMETER TopProcessCount
    How many processes to include in each of the memory and CPU lists. Default 10.

.PARAMETER SampleSeconds
    Seconds over which processor time is sampled. Default 5.

.PARAMETER IncludeEventLogErrors
    Include recent System event-log errors in the snapshot.

.PARAMETER EventLookbackHours
    How far back to read event-log errors. Default 24.

.PARAMETER Credential
    Credential for remote CIM/remoting where the caller's context is insufficient.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML. JSON is recommended — the snapshot is a nested
    object and CSV flattens away the detail that makes it useful.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.EXAMPLE
    .\Get-WinServerResourceSnapshot.ps1 -ComputerName SRV01 -OutputFormat JSON

    Pulls a full diagnostic snapshot of SRV01 as JSON.

.EXAMPLE
    .\Get-WinServerResourceSnapshot.ps1 -ComputerName SRV01 -IncludeEventLogErrors -TopProcessCount 20

    Pulls the snapshot with 20 processes per list and the last 24 hours of
    System errors.

.NOTES
    Source use case      : #5 - Windows Resource Utilization Pull
    Category             : Windows Server
    Technology           : PowerShell
    Difficulty           : Low
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Read-only"

    Required permissions : Read access to WMI/CIM, performance counters and the
                           System event log on the target.
    Required modules     : IT-Automation-Common (bundled). CimCmdlets (built in).
    Authentication       : Integrated Kerberos over WinRM, or -Credential.
#>

#Requires -Version 5.1

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [ValidateNotNullOrEmpty()]
    [string[]]$ComputerName = $env:COMPUTERNAME,

    [ValidateRange(1, 100)]
    [int]$TopProcessCount = 10,

    [ValidateRange(1, 60)]
    [int]$SampleSeconds = 5,

    [switch]$IncludeEventLogErrors,

    [ValidateRange(1, 720)]
    [int]$EventLookbackHours = 24,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-WinServerResourceSnapshot'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'START. topN={0} sample={1}s events={2}' -f
        $TopProcessCount, $SampleSeconds, [bool]$IncludeEventLogErrors)

    $results  = [System.Collections.Generic.List[PSCustomObject]]::new()
    $failures = [System.Collections.Generic.List[PSCustomObject]]::new()
}

process {
    foreach ($computer in $ComputerName) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $computer -Message 'Pulling snapshot'
        $session = $null
        try {
            $common = @{ ErrorAction = 'Stop' }
            if ($computer -ne $env:COMPUTERNAME) {
                $sp = @{ ComputerName = $computer; ErrorAction = 'Stop' }
                if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $sp.Credential = $Credential }
                $session = New-CimSession @sp
                $common.CimSession = $session
            }

            $os = Get-CimInstance -ClassName Win32_OperatingSystem @common
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem @common

            $samples = for ($i = 0; $i -lt $SampleSeconds; $i++) {
                (Get-CimInstance -ClassName Win32_Processor @common |
                    Measure-Object -Property LoadPercentage -Average).Average
                Start-Sleep -Seconds 1
            }
            $cpuAvg = [math]::Round((($samples | Measure-Object -Average).Average), 2)

            $totalMemGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
            $freeMemGB  = [math]::Round($os.FreePhysicalMemory * 1KB / 1GB, 2)

            $allProcs = @(Get-CimInstance -ClassName Win32_Process @common)

            $topByMemory = $allProcs |
                Sort-Object -Property WorkingSetSize -Descending |
                Select-Object -First $TopProcessCount |
                ForEach-Object {
                    [PSCustomObject]@{
                        Name         = $_.Name
                        ProcessId    = $_.ProcessId
                        WorkingSetMB = [math]::Round($_.WorkingSetSize / 1MB, 2)
                        StartTime    = $_.CreationDate
                    }
                }

            # KernelModeTime/UserModeTime are cumulative 100-nanosecond ticks, so
            # this ranks total CPU consumed since start, not instantaneous load.
            $topByCpu = $allProcs |
                Sort-Object -Property { [int64]$_.KernelModeTime + [int64]$_.UserModeTime } -Descending |
                Select-Object -First $TopProcessCount |
                ForEach-Object {
                    [PSCustomObject]@{
                        Name           = $_.Name
                        ProcessId      = $_.ProcessId
                        TotalCpuSeconds = [math]::Round((([int64]$_.KernelModeTime + [int64]$_.UserModeTime) / 1e7), 1)
                        StartTime      = $_.CreationDate
                    }
                }

            $volumes = Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' @common |
                ForEach-Object {
                    [PSCustomObject]@{
                        Drive       = $_.DeviceID
                        CapacityGB  = if ($_.Size -gt 0) { [math]::Round($_.Size / 1GB, 2) } else { 0 }
                        FreeGB      = [math]::Round($_.FreeSpace / 1GB, 2)
                        PercentFree = if ($_.Size -gt 0) { [math]::Round(($_.FreeSpace / $_.Size) * 100, 2) } else { $null }
                    }
                }

            $adapters = Get-CimInstance -ClassName Win32_PerfFormattedData_Tcpip_NetworkInterface @common |
                Where-Object { $_.BytesTotalPersec -gt 0 } |
                Sort-Object -Property BytesTotalPersec -Descending |
                Select-Object -First 5 |
                ForEach-Object {
                    [PSCustomObject]@{
                        Interface       = $_.Name
                        MbpsTotal       = [math]::Round(($_.BytesTotalPersec * 8) / 1MB, 2)
                        OutputQueueLen  = $_.OutputQueueLength
                        PacketsErrors   = $_.PacketsReceivedErrors
                    }
                }

            $events = $null
            if ($IncludeEventLogErrors) {
                try {
                    $since = (Get-Date).AddHours(-$EventLookbackHours)
                    $ep = @{
                        FilterHashtable = @{ LogName = 'System'; Level = 2; StartTime = $since }
                        ErrorAction     = 'Stop'
                        MaxEvents       = 50
                    }
                    if ($computer -ne $env:COMPUTERNAME) { $ep.ComputerName = $computer }
                    if ($Credential -ne [System.Management.Automation.PSCredential]::Empty -and
                        $computer -ne $env:COMPUTERNAME) { $ep.Credential = $Credential }

                    $events = Get-WinEvent @ep |
                        Group-Object -Property Id, ProviderName |
                        Sort-Object Count -Descending |
                        Select-Object -First 10 |
                        ForEach-Object {
                            [PSCustomObject]@{
                                EventId  = $_.Group[0].Id
                                Provider = $_.Group[0].ProviderName
                                Count    = $_.Count
                                Latest   = $_.Group[0].TimeCreated
                                Message  = ($_.Group[0].Message -split "`n")[0]
                            }
                        }
                } catch {
                    # No matching events is a normal, healthy outcome and must
                    # not look like a failure of the whole snapshot.
                    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $computer `
                        -Message ('No System errors in the last {0}h (or log unreadable): {1}' -f
                                  $EventLookbackHours, $_.Exception.Message)
                }
            }

            $results.Add([PSCustomObject]@{
                ComputerName      = $computer
                OSName            = $os.Caption
                LastBootUpTime    = $os.LastBootUpTime
                UptimeDays        = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 2)
                CpuPercentAvg     = $cpuAvg
                LogicalProcessors = $cs.NumberOfLogicalProcessors
                TotalMemoryGB     = $totalMemGB
                FreeMemoryGB      = $freeMemGB
                MemoryPercentUsed = if ($totalMemGB -gt 0) {
                                        [math]::Round((($totalMemGB - $freeMemGB) / $totalMemGB) * 100, 2)
                                    } else { 0 }
                ProcessCount      = $allProcs.Count
                TopProcessesByMemory = $topByMemory
                TopProcessesByCpu    = $topByCpu
                Volumes           = $volumes
                NetworkInterfaces = $adapters
                RecentSystemErrors = $events
                CollectedAt       = (Get-Date)
            })

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $computer `
                -Message ('Snapshot collected: cpu={0}% procs={1} volumes={2}' -f
                          $cpuAvg, $allProcs.Count, @($volumes).Count)
        } catch {
            $msg = $_.Exception.Message
            Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $computer `
                -Message ('Snapshot FAILED: {0}' -f $msg)
            $failures.Add([PSCustomObject]@{ ComputerName = $computer; Error = $msg })
        } finally {
            if ($session) { Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue }
        }
    }
}

end {
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'END. Snapshots={0} Failed={1}' -f $results.Count, $failures.Count)

    if ($OutputFormat -eq 'CSV' -and $results.Count -gt 0) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
            'CSV flattens the nested process/volume detail. JSON preserves it.')
    }

    $output = $results.ToArray()
    $null = $output | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath `
        -Title 'Windows Server Resource Snapshot'

    if ($failures.Count -gt 0) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
            'Unreachable or failed: {0}' -f (($failures.ComputerName) -join ', '))
    }

    Write-Output $output

    if ($failures.Count -gt 0 -and $results.Count -eq 0) {
        exit 1
    }
}
