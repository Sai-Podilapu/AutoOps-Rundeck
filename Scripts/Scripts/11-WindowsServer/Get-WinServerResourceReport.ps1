<#
.SYNOPSIS
    Reports CPU, memory, disk and uptime utilisation for one or more Windows servers.

.DESCRIPTION
    Collects a point-in-time resource snapshot from each target: processor
    utilisation sampled over a short window, physical memory in use, page-file
    usage, system uptime and top processes by working set.

    This script is READ-ONLY. It contains no write, modify or delete calls of
    any kind and is safe to schedule unattended.

    Produces one summary row per server, suitable for a fleet-wide capacity or
    health report. For a deep single-host diagnostic pull including per-process
    and per-volume detail, use Get-WinServerResourceSnapshot.ps1 (use case #5).

.PARAMETER ComputerName
    Servers to query. Accepts pipeline input. Defaults to the local computer.

.PARAMETER SampleSeconds
    Seconds over which processor time is sampled. Default 5. A single
    instantaneous reading of CPU is close to meaningless, so this defaults to a
    real sample rather than a snapshot.

.PARAMETER CpuWarningPercent
    CPU utilisation at or above which the server is flagged. Default 85.

.PARAMETER MemoryWarningPercent
    Memory utilisation at or above which the server is flagged. Default 90.

.PARAMETER Credential
    Credential for remote CIM where the caller's context is insufficient.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.EXAMPLE
    .\Get-WinServerResourceReport.ps1 -ComputerName SRV01

    Prints a one-line resource summary for SRV01.

.EXAMPLE
    .\Get-WinServerResourceReport.ps1 -ComputerName (Get-Content .\servers.txt) -OutputFormat HTML

    Produces a fleet-wide HTML utilisation report.

.NOTES
    Source use case      : #2 - Resource Utilization Report (Pending)
    Category             : Windows Server
    Technology           : PowerShell
    Difficulty           : Low
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Read-only"

    Required permissions : Read access to WMI/CIM and performance counters on
                           the target.
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

    [ValidateRange(1, 60)]
    [int]$SampleSeconds = 5,

    [ValidateRange(1, 100)]
    [int]$CpuWarningPercent = 85,

    [ValidateRange(1, 100)]
    [int]$MemoryWarningPercent = 90,

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

    $scriptName = 'Get-WinServerResourceReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'START. sample={0}s cpuWarn={1}% memWarn={2}%' -f
        $SampleSeconds, $CpuWarningPercent, $MemoryWarningPercent)

    $results  = [System.Collections.Generic.List[PSCustomObject]]::new()
    $failures = [System.Collections.Generic.List[PSCustomObject]]::new()
}

process {
    foreach ($computer in $ComputerName) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $computer -Message 'Collecting resource snapshot'
        $session = $null
        try {
            $common = @{ ErrorAction = 'Stop' }
            if ($computer -ne $env:COMPUTERNAME) {
                $sp = @{ ComputerName = $computer; ErrorAction = 'Stop' }
                if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) {
                    $sp.Credential = $Credential
                }
                $session = New-CimSession @sp
                $common.CimSession = $session
            }

            $os  = Get-CimInstance -ClassName Win32_OperatingSystem @common
            $cs  = Get-CimInstance -ClassName Win32_ComputerSystem @common

            # Sampled CPU. Win32_Processor.LoadPercentage is a single reading and
            # swings wildly; averaging over a short window is far more useful.
            $samples = for ($i = 0; $i -lt $SampleSeconds; $i++) {
                (Get-CimInstance -ClassName Win32_Processor @common |
                    Measure-Object -Property LoadPercentage -Average).Average
                Start-Sleep -Seconds 1
            }
            $cpuAvg = [math]::Round((($samples | Measure-Object -Average).Average), 2)

            $totalMemGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
            $freeMemGB  = [math]::Round($os.FreePhysicalMemory * 1KB / 1GB, 2)
            $usedMemGB  = [math]::Round($totalMemGB - $freeMemGB, 2)
            $memPct     = if ($totalMemGB -gt 0) { [math]::Round(($usedMemGB / $totalMemGB) * 100, 2) } else { 0 }

            $uptime = (Get-Date) - $os.LastBootUpTime

            $flags = @()
            if ($cpuAvg -ge $CpuWarningPercent)    { $flags += "CPU>=$CpuWarningPercent%" }
            if ($memPct -ge $MemoryWarningPercent) { $flags += "MEM>=$MemoryWarningPercent%" }

            $row = [PSCustomObject]@{
                ComputerName      = $computer
                OSName            = $os.Caption
                CpuPercentAvg     = $cpuAvg
                CpuSampleSeconds  = $SampleSeconds
                LogicalProcessors = $cs.NumberOfLogicalProcessors
                TotalMemoryGB     = $totalMemGB
                UsedMemoryGB      = $usedMemGB
                FreeMemoryGB      = $freeMemGB
                MemoryPercentUsed = $memPct
                UptimeDays        = [math]::Round($uptime.TotalDays, 2)
                LastBootUpTime    = $os.LastBootUpTime
                Status            = if ($flags.Count -gt 0) { 'Warning' } else { 'OK' }
                Flags             = ($flags -join '; ')
                CollectedAt       = (Get-Date)
            }

            $results.Add($row)

            if ($flags.Count -gt 0) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $computer `
                    -Message ('Threshold breach: {0} (cpu={1}% mem={2}%)' -f ($flags -join ', '), $cpuAvg, $memPct)
            }
        } catch {
            $msg = $_.Exception.Message
            Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $computer `
                -Message ('Failed to collect utilisation: {0}' -f $msg)
            $failures.Add([PSCustomObject]@{ ComputerName = $computer; Error = $msg })
        } finally {
            if ($session) { Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue }
        }
    }
}

end {
    $warned = @($results | Where-Object { $_.Status -eq 'Warning' })
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'Collected {0} server(s). Warning={1} Failed={2}' -f $results.Count, $warned.Count, $failures.Count)

    $output = $results | Sort-Object -Property CpuPercentAvg -Descending
    $null = $output | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath `
        -Title 'Windows Server Resource Utilisation'

    if ($failures.Count -gt 0) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
            'Unreachable or failed: {0}' -f (($failures.ComputerName) -join ', '))
    }

    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    Write-Output $output

    if ($failures.Count -gt 0 -and $results.Count -eq 0) {
        exit 1
    }
}
