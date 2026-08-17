<#
.SYNOPSIS
    Restarts a Windows service, restricted to a configured whitelist.

.DESCRIPTION
    Restarts one or more services on one or more servers. Two controls apply:

      1. A RESTARTABLE-SERVICE WHITELIST from Config\config.json. Only services
         on that list may be restarted. This is the workbook guardrail -
         "whitelist of restartable services in SOP" - implemented as code
         rather than left to documentation.
      2. A PROTECTED-SERVICE BLACKLIST that is refused unconditionally even if
         someone adds one of those names to the whitelist by mistake.

    The workbook classifies this as a common L1 fix with no approval required,
    so it executes directly. It is still ShouldProcess-aware, so -WhatIf gives a
    clean dry run, and prior state is captured before each restart.

.PARAMETER Name
    Service name(s) to restart. Must appear in safety.restartableServices.

.PARAMETER ComputerName
    Servers to act on. Defaults to the local computer.

.PARAMETER WaitSeconds
    How long to wait for the service to reach Running after restart. Default 30.

.PARAMETER SkipIfAlreadyRunningFor
    Skip the restart if the service has been running for at least this many
    minutes and is healthy. Makes repeat runs idempotent in the practical sense
    of not bouncing a service that is already fine. Default 0 (always restart).

.PARAMETER Credential
    Credential for the remote operation.

.PARAMETER ConfigPath
    Override the path to config.json.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.EXAMPLE
    .\Restart-WinServerService.ps1 -Name Spooler -ComputerName SRV01

    Restarts the print spooler on SRV01 after checking it is whitelisted.

.EXAMPLE
    .\Restart-WinServerService.ps1 -Name Spooler,W32Time -ComputerName SRV01,SRV02 -WhatIf

    Shows what would be restarted without acting.

.NOTES
    Source use case      : #4 - Windows Service Restart
    Category             : Windows Server
    Technology           : PowerShell
    Difficulty           : Low
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Common L1 fix; whitelist of restartable services in SOP"

    Required permissions : Service control rights on the target (typically local
                           Administrator).
    Required modules     : IT-Automation-Common (bundled).
    Authentication       : Integrated Kerberos over WinRM, or -Credential.

    Rollback             : Prior state (status and start type) is captured and
                           logged before each restart, so an operator can restore
                           the previous condition manually if a restart misbehaves.
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
    [ValidateNotNullOrEmpty()]
    [string[]]$Name,

    [Parameter(ValueFromPipelineByPropertyName)]
    [ValidateNotNullOrEmpty()]
    [string[]]$ComputerName = $env:COMPUTERNAME,

    [ValidateRange(1, 600)]
    [int]$WaitSeconds = 30,

    [ValidateRange(0, 10080)]
    [int]$SkipIfAlreadyRunningFor = 0,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [string]$ConfigPath,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Restart-WinServerService'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'START. Services={0} Servers={1}' -f ($Name -join ','), ($ComputerName -join ','))

    try {
        $config = if ($ConfigPath) { Get-AutomationConfig -Path $ConfigPath } else { Get-AutomationConfig }
    } catch {
        throw ('Cannot read configuration, refusing to proceed without the service whitelist: {0}' -f
               $_.Exception.Message)
    }

    $whitelist = @()
    $blacklist = @()
    if ($config.PSObject.Properties.Name -contains 'safety') {
        if ($config.safety.PSObject.Properties.Name -contains 'restartableServices') {
            $whitelist = @($config.safety.restartableServices)
        }
        if ($config.safety.PSObject.Properties.Name -contains 'protectedServices') {
            $blacklist = @($config.safety.protectedServices)
        }
    }
    if ($whitelist.Count -eq 0) {
        throw 'safety.restartableServices is empty in config.json. Refusing to run without a whitelist.'
    }
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'Whitelist has {0} service(s); blacklist has {1}.' -f $whitelist.Count, $blacklist.Count)

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
}

process {
    foreach ($computer in $ComputerName) {
        foreach ($svcName in $Name) {

            $label = "{0}\{1}" -f $computer, $svcName

            # Blacklist wins over whitelist, always.
            if ($blacklist -contains $svcName) {
                Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $label `
                    -Message 'REFUSED - service is on the protected blacklist'
                $results.Add([PSCustomObject]@{
                    ComputerName = $computer; ServiceName = $svcName; Action = 'Refused'
                    PreviousStatus = $null; CurrentStatus = $null
                    Detail = 'Protected service'; Succeeded = $false
                })
                continue
            }

            if ($whitelist -notcontains $svcName) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label `
                    -Message 'REFUSED - service is not in safety.restartableServices'
                $results.Add([PSCustomObject]@{
                    ComputerName = $computer; ServiceName = $svcName; Action = 'Refused'
                    PreviousStatus = $null; CurrentStatus = $null
                    Detail = 'Not whitelisted'; Succeeded = $false
                })
                continue
            }

            $session = $null
            try {
                $common = @{ ErrorAction = 'Stop' }
                if ($computer -ne $env:COMPUTERNAME) {
                    $sp = @{ ComputerName = $computer; ErrorAction = 'Stop' }
                    if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $sp.Credential = $Credential }
                    $session = New-CimSession @sp
                    $common.CimSession = $session
                }

                $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$svcName'" @common
                if (-not $svc) {
                    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message 'Service not found'
                    $results.Add([PSCustomObject]@{
                        ComputerName = $computer; ServiceName = $svcName; Action = 'NotFound'
                        PreviousStatus = $null; CurrentStatus = $null
                        Detail = 'Service does not exist on this host'; Succeeded = $false
                    })
                    continue
                }

                # Capture prior state before changing anything, so the previous
                # condition is recoverable by hand if the restart misbehaves.
                $prevState     = $svc.State
                $prevStartMode = $svc.StartMode
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label `
                    -Message ('Prior state captured: State={0} StartMode={1}' -f $prevState, $prevStartMode)

                if ($SkipIfAlreadyRunningFor -gt 0 -and $prevState -eq 'Running' -and $svc.ProcessId -gt 0) {
                    $p = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$($svc.ProcessId)" @common
                    if ($p -and $p.CreationDate) {
                        $runMin = ((Get-Date) - $p.CreationDate).TotalMinutes
                        if ($runMin -ge $SkipIfAlreadyRunningFor) {
                            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label `
                                -Message ('Skipped - already running {0} min (>= {1})' -f
                                          [math]::Round($runMin, 1), $SkipIfAlreadyRunningFor)
                            $results.Add([PSCustomObject]@{
                                ComputerName = $computer; ServiceName = $svcName; Action = 'Skipped'
                                PreviousStatus = $prevState; CurrentStatus = $prevState
                                Detail = 'Healthy and above minimum runtime'; Succeeded = $true
                            })
                            continue
                        }
                    }
                }

                if (-not $PSCmdlet.ShouldProcess($label, 'Restart service')) {
                    $results.Add([PSCustomObject]@{
                        ComputerName = $computer; ServiceName = $svcName; Action = 'WhatIf'
                        PreviousStatus = $prevState; CurrentStatus = $prevState
                        Detail = 'Not executed'; Succeeded = $true
                    })
                    continue
                }

                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message 'Restarting'

                $gsParams = @{ Name = $svcName; ErrorAction = 'Stop' }
                if ($computer -ne $env:COMPUTERNAME) { $gsParams.ComputerName = $computer }

                $svcObj = Get-Service @gsParams
                if ($svcObj.Status -ne 'Stopped') {
                    $svcObj.Stop()
                    $svcObj.WaitForStatus('Stopped', (New-TimeSpan -Seconds $WaitSeconds))
                }
                $svcObj.Start()
                $svcObj.WaitForStatus('Running', (New-TimeSpan -Seconds $WaitSeconds))
                $svcObj.Refresh()

                # Post-action verification: confirm the intended end state rather
                # than assuming the command worked.
                $newState = $svcObj.Status
                if ($newState -eq 'Running') {
                    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label `
                        -Message ('Restarted. {0} -> {1}' -f $prevState, $newState)
                    $results.Add([PSCustomObject]@{
                        ComputerName = $computer; ServiceName = $svcName; Action = 'Restarted'
                        PreviousStatus = $prevState; CurrentStatus = "$newState"
                        Detail = 'Verified Running'; Succeeded = $true
                    })
                } else {
                    Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $label `
                        -Message ('Restart did not reach Running; state is {0}' -f $newState)
                    $results.Add([PSCustomObject]@{
                        ComputerName = $computer; ServiceName = $svcName; Action = 'Failed'
                        PreviousStatus = $prevState; CurrentStatus = "$newState"
                        Detail = 'Did not reach Running'; Succeeded = $false
                    })
                }
            } catch {
                $msg = $_.Exception.Message
                Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $label `
                    -Message ('Restart FAILED: {0}' -f $msg)
                $results.Add([PSCustomObject]@{
                    ComputerName = $computer; ServiceName = $svcName; Action = 'Failed'
                    PreviousStatus = $null; CurrentStatus = $null
                    Detail = $msg; Succeeded = $false
                })
            } finally {
                if ($session) { Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue }
            }
        }
    }
}

end {
    $ok  = @($results | Where-Object { $_.Succeeded })
    $bad = @($results | Where-Object { -not $_.Succeeded })
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'END. Succeeded={0} Failed/Refused={1}' -f $ok.Count, $bad.Count)

    $output = $results.ToArray()
    $null = $output | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath `
        -Title 'Windows Service Restart'

    Write-Output $output

    if ($bad.Count -gt 0) { exit 1 }
}
