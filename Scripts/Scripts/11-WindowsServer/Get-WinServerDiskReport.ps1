<#
.SYNOPSIS
    Reports disk capacity and free space for one or more Windows servers.

.DESCRIPTION
    Collects logical disk capacity, free space and percentage free from each
    target server and flags volumes below the warning and critical thresholds.

    This script is READ-ONLY. It contains no write, modify or delete calls of
    any kind and is safe to schedule unattended.

.PARAMETER ComputerName
    Servers to query. Accepts pipeline input. Defaults to the local computer.

.PARAMETER WarningThresholdPercent
    Free-space percentage at or below which a volume is marked Warning. Default 20.

.PARAMETER CriticalThresholdPercent
    Free-space percentage at or below which a volume is marked Critical. Default 10.

.PARAMETER DriveType
    WMI drive type to include. 3 = local fixed disk (the default). 2 = removable,
    4 = network.

.PARAMETER Credential
    Credential for remote WMI/CIM where the caller's context is insufficient.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER SendReport
    Deliver the report through the configured notification channel.

.EXAMPLE
    .\Get-WinServerDiskReport.ps1 -ComputerName SRV01,SRV02

    Reports disk usage for two servers to the console.

.EXAMPLE
    .\Get-WinServerDiskReport.ps1 -ComputerName (Get-Content .\servers.txt) -OutputFormat HTML -SendReport

    Produces an HTML report for every server listed in servers.txt and emails it.

.NOTES
    Source use case      : #1 - Disk Reports
    Category             : Windows Server
    Technology           : PowerShell
    Difficulty           : Low
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Read-only"

    Required permissions : Read access to WMI/CIM on the target (local
                           Administrators, or a delegated WMI namespace right).
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

    [ValidateRange(0, 100)]
    [int]$WarningThresholdPercent = 20,

    [ValidateRange(0, 100)]
    [int]$CriticalThresholdPercent = 10,

    [ValidateSet(2, 3, 4)]
    [int]$DriveType = 3,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [switch]$SendReport
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-WinServerDiskReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'START. Thresholds: warning<={0}% critical<={1}%, driveType={2}' -f
        $WarningThresholdPercent, $CriticalThresholdPercent, $DriveType)

    if ($CriticalThresholdPercent -gt $WarningThresholdPercent) {
        throw ('CriticalThresholdPercent ({0}) cannot exceed WarningThresholdPercent ({1}).' -f
               $CriticalThresholdPercent, $WarningThresholdPercent)
    }

    $results  = [System.Collections.Generic.List[PSCustomObject]]::new()
    $failures = [System.Collections.Generic.List[PSCustomObject]]::new()
}

process {
    foreach ($computer in $ComputerName) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $computer -Message 'Querying logical disks'
        try {
            $cimParams = @{
                ClassName   = 'Win32_LogicalDisk'
                Filter      = "DriveType=$DriveType"
                ErrorAction = 'Stop'
            }
            if ($computer -ne $env:COMPUTERNAME) {
                $sessionParams = @{ ComputerName = $computer; ErrorAction = 'Stop' }
                if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) {
                    $sessionParams.Credential = $Credential
                }
                $session = New-CimSession @sessionParams
                $cimParams.CimSession = $session
            }

            $disks = Get-CimInstance @cimParams

            foreach ($d in $disks) {
                # A volume can legitimately report Size = 0 (an empty removable
                # bay). Dividing would throw and abort the whole server.
                $pctFree = if ($d.Size -gt 0) {
                    [math]::Round(($d.FreeSpace / $d.Size) * 100, 2)
                } else { $null }

                $status = if ($null -eq $pctFree) { 'Unknown' }
                          elseif ($pctFree -le $CriticalThresholdPercent) { 'Critical' }
                          elseif ($pctFree -le $WarningThresholdPercent)  { 'Warning' }
                          else { 'OK' }

                $results.Add([PSCustomObject]@{
                    ComputerName   = $computer
                    Drive          = $d.DeviceID
                    VolumeName     = $d.VolumeName
                    FileSystem     = $d.FileSystem
                    CapacityGB     = if ($d.Size -gt 0) { [math]::Round($d.Size / 1GB, 2) } else { 0 }
                    FreeGB         = [math]::Round($d.FreeSpace / 1GB, 2)
                    UsedGB         = if ($d.Size -gt 0) { [math]::Round(($d.Size - $d.FreeSpace) / 1GB, 2) } else { 0 }
                    PercentFree    = $pctFree
                    Status         = $status
                    CollectedAt    = (Get-Date)
                })

                if ($status -in @('Warning', 'Critical')) {
                    Write-AutomationLog -ScriptName $scriptName -Level WARN `
                        -Target ("{0}:{1}" -f $computer, $d.DeviceID) `
                        -Message ('{0} - {1}% free' -f $status, $pctFree)
                }
            }

            if ($cimParams.ContainsKey('CimSession')) {
                Remove-CimSession -CimSession $cimParams.CimSession -ErrorAction SilentlyContinue
            }
        } catch {
            $msg = $_.Exception.Message
            Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $computer `
                -Message ('Failed to query disks: {0}' -f $msg)
            $failures.Add([PSCustomObject]@{ ComputerName = $computer; Error = $msg })
        }
    }
}

end {
    $critical = @($results | Where-Object { $_.Status -eq 'Critical' })
    $warning  = @($results | Where-Object { $_.Status -eq 'Warning' })

    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'Collected {0} volume(s) across {1} server(s). Critical={2} Warning={3} Failed servers={4}' -f
        $results.Count, ($ComputerName | Select-Object -Unique).Count,
        $critical.Count, $warning.Count, $failures.Count)

    $output = $results | Sort-Object PercentFree
    $null = $output | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Windows Server Disk Report'

    if ($SendReport) {
        $rows = ($output | ConvertTo-Html -Fragment) -join [Environment]::NewLine
        $subject = 'Disk report - {0} critical, {1} warning' -f $critical.Count, $warning.Count
        Send-AutomationReport -Subject $subject -Body $rows -Channel Email | Out-Null
    }

    # Report which servers could not be reached rather than silently returning
    # a short list that looks like a clean result.
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
