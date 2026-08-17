<#
.SYNOPSIS
    Checks and optionally corrects Windows time synchronisation using w32tm.

.DESCRIPTION
    Reports each server's time source, stratum, and offset from its configured
    peer, and — when -Resync is passed — forces a resynchronisation.

    The default behaviour is REPORT ONLY. Nothing is changed unless -Resync is
    given. The workbook rates this Low risk with no approval required, so
    -Resync executes directly, but it remains ShouldProcess-aware so -WhatIf
    gives a clean dry run.

    Time skew is a common root cause of Kerberos authentication failure, so the
    report flags any host whose offset exceeds the tolerance even when no
    correction is requested.

.PARAMETER ComputerName
    Servers to check. Defaults to the local computer.

.PARAMETER Resync
    Force a resynchronisation (w32tm /resync). Without this the script only reports.

.PARAMETER MaxOffsetSeconds
    Offset at or above which a host is flagged. Kerberos defaults to a five
    minute tolerance, so the default here is deliberately tighter at 60 seconds.

.PARAMETER RediscoverSource
    Pass /rediscover to the resync so the client re-locates its time source.
    Useful after a domain controller change.

.PARAMETER Credential
    Credential for the remote operation.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.EXAMPLE
    .\Sync-WinServerTime.ps1 -ComputerName SRV01,SRV02

    Reports time source and offset for both servers. Changes nothing.

.EXAMPLE
    .\Sync-WinServerTime.ps1 -ComputerName SRV01 -Resync -RediscoverSource

    Forces SRV01 to rediscover its time source and resynchronise.

.NOTES
    Source use case      : #7 - Windows Time Sync
    Category             : Windows Server
    Technology           : PowerShell / w32tm
    Difficulty           : Low
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Low-risk config"

    Required permissions : Local Administrator on the target for /resync.
                           The status query alone needs only remote execution rights.
    Required modules     : IT-Automation-Common (bundled). w32tm.exe is built in.
    Authentication       : Integrated Kerberos over WinRM, or -Credential.

    Rollback             : Not applicable. A resync moves the clock toward the
                           authoritative source; it does not persist a config change.
                           Use w32tm /config to alter the source, which this script
                           deliberately does not do.
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [ValidateNotNullOrEmpty()]
    [string[]]$ComputerName = $env:COMPUTERNAME,

    [switch]$Resync,

    [ValidateRange(1, 86400)]
    [int]$MaxOffsetSeconds = 60,

    [switch]$RediscoverSource,

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

    $scriptName = 'Sync-WinServerTime'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'START. Resync={0} MaxOffset={1}s Rediscover={2}' -f
        [bool]$Resync, $MaxOffsetSeconds, [bool]$RediscoverSource)

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Runs a scriptblock locally or remotely without duplicating the branch at
    # every call site. The credential is passed in explicitly rather than
    # captured from the parent scope, so the helper has no hidden dependency.
    function Invoke-OnTarget {
        param(
            [string]$Computer,
            [scriptblock]$ScriptBlock,
            [object[]]$ArgumentList,
            [System.Management.Automation.PSCredential]$RemoteCredential
        )

        if ($Computer -eq $env:COMPUTERNAME) {
            return & $ScriptBlock @ArgumentList
        }
        $p = @{ ComputerName = $Computer; ScriptBlock = $ScriptBlock; ErrorAction = 'Stop' }
        if ($ArgumentList) { $p.ArgumentList = $ArgumentList }
        if ($RemoteCredential -and
            $RemoteCredential -ne [System.Management.Automation.PSCredential]::Empty) {
            $p.Credential = $RemoteCredential
        }
        return Invoke-Command @p
    }
}

process {
    foreach ($computer in $ComputerName) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $computer -Message 'Querying time status'
        try {
            $raw = Invoke-OnTarget -Computer $computer -RemoteCredential $Credential -ScriptBlock {
                [PSCustomObject]@{
                    Status = (& w32tm.exe /query /status 2>&1) -join "`n"
                    Source = (& w32tm.exe /query /source 2>&1) -join "`n"
                    Local  = (Get-Date)
                }
            }

            $source  = ($raw.Source).Trim()
            $stratum = $null
            $offsetSeconds = $null

            if ($raw.Status -match 'Stratum:\s*(\d+)') { $stratum = [int]$Matches[1] }

            # w32tm reports "Phase Offset: 0.0123456s" on most builds. Localised
            # or older builds may not, so a missing offset is reported as unknown
            # rather than silently treated as zero.
            if ($raw.Status -match 'Phase Offset:\s*([-\d\.]+)s') {
                $offsetSeconds = [math]::Round([double]$Matches[1], 4)
            }

            $absOffset = if ($null -ne $offsetSeconds) { [math]::Abs($offsetSeconds) } else { $null }
            $status = if ($null -eq $absOffset) { 'Unknown' }
                      elseif ($absOffset -ge $MaxOffsetSeconds) { 'OutOfTolerance' }
                      else { 'InTolerance' }

            if ($status -eq 'OutOfTolerance') {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $computer `
                    -Message ('Offset {0}s exceeds tolerance {1}s (source: {2})' -f
                              $offsetSeconds, $MaxOffsetSeconds, $source)
            }

            $row = [PSCustomObject]@{
                ComputerName    = $computer
                TimeSource      = $source
                Stratum         = $stratum
                OffsetSeconds   = $offsetSeconds
                Status          = $status
                ResyncPerformed = $false
                ResyncResult    = $null
                CheckedAt       = (Get-Date)
            }

            if ($Resync) {
                if ($PSCmdlet.ShouldProcess($computer, 'w32tm /resync')) {
                    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $computer `
                        -Message ('Resyncing (rediscover={0})' -f [bool]$RediscoverSource)
                    try {
                        $out = Invoke-OnTarget -Computer $computer -RemoteCredential $Credential -ArgumentList @([bool]$RediscoverSource) `
                            -ScriptBlock {
                                param($Rediscover)
                                if ($Rediscover) { (& w32tm.exe /resync /rediscover 2>&1) -join ' ' }
                                else             { (& w32tm.exe /resync 2>&1) -join ' ' }
                            }
                        $row.ResyncPerformed = $true
                        $row.ResyncResult = ($out).Trim()

                        if ($out -match 'successfully') {
                            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $computer `
                                -Message 'Resync completed successfully'
                        } else {
                            # w32tm exits 0 in cases where it did not actually
                            # resync, so the text is checked rather than trusted.
                            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $computer `
                                -Message ('Resync returned: {0}' -f $row.ResyncResult)
                        }
                    } catch {
                        $row.ResyncResult = $_.Exception.Message
                        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $computer `
                            -Message ('Resync FAILED: {0}' -f $_.Exception.Message)
                    }
                } else {
                    $row.ResyncResult = 'WhatIf - not executed'
                }
            }

            $results.Add($row)
        } catch {
            $msg = $_.Exception.Message
            Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $computer `
                -Message ('Failed to query time status: {0}' -f $msg)
            $results.Add([PSCustomObject]@{
                ComputerName = $computer; TimeSource = $null; Stratum = $null
                OffsetSeconds = $null; Status = 'Failed'; ResyncPerformed = $false
                ResyncResult = $msg; CheckedAt = (Get-Date)
            })
        }
    }
}

end {
    $outOf  = @($results | Where-Object { $_.Status -eq 'OutOfTolerance' })
    $failed = @($results | Where-Object { $_.Status -eq 'Failed' })
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'END. Checked={0} OutOfTolerance={1} Failed={2}' -f $results.Count, $outOf.Count, $failed.Count)

    $output = $results.ToArray()
    $null = $output | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath `
        -Title 'Windows Time Synchronisation'

    Write-Output $output

    if ($failed.Count -gt 0) { exit 1 }
}
