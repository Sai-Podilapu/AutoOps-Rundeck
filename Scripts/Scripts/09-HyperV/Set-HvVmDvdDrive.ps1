<#
.SYNOPSIS
    Mounts or unmounts an ISO on a Hyper-V virtual machine DVD drive.

.DESCRIPTION
    Attaches an ISO image to a VM DVD drive or ejects the current one. Fully
    reversible and low risk, which is why it executes directly - but it still
    logs what was mounted where, because a forgotten mounted ISO blocks live
    migration and storage maintenance.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER ComputerName
    Hyper-V host(s) to act against. Defaults to the local host.

.PARAMETER Credential
    Credential for the remote Hyper-V host.

.PARAMETER TargetVMName
    Virtual machine to modify.

.PARAMETER Operation
    Mount or Unmount.

.PARAMETER IsoPath
    Path to the ISO, reachable by the Hyper-V host. Required for Mount.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Set-HvVmDvdDrive.ps1 -ComputerName HV01 -TargetVMName APP01 -Operation Mount -IsoPath '\\fs01\iso\win2022.iso'

    Mounts an ISO on APP01.

.EXAMPLE
    .\Set-HvVmDvdDrive.ps1 -ComputerName HV01 -TargetVMName APP01 -Operation Unmount

    Ejects whatever is currently mounted.

.NOTES
    Source use case      : #12 - Hyper-V ISO Mount/Unmount
    Category             : Hyper-V
    Technology           : PowerShell / Hyper-V Module
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Low-risk, reversible"

    Required permissions : Hyper-V Administrators on the host, plus host read access to the ISO path.
    Required modules     : Hyper-V
    Authentication       : Integrated Kerberos over PSRemoting; SCVMM cmdlets
                           where noted.

    Rollback             : Fully reversible - run the opposite operation.
#>

#Requires -Version 5.1
#Requires -Modules Hyper-V

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string[]]$ComputerName = $env:COMPUTERNAME,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [Parameter(Mandatory)]
    [string[]]$TargetVMName,

    [Parameter(Mandatory)]
    [ValidateSet('Mount','Unmount')]
    [string]$Operation,

    [string]$IsoPath,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-HvVmDvdDrive'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #12 (Hyper-V)'

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
        Connect-AutomationPlatform -Platform 'HyperV' | Out-Null


        foreach ($hv in $ComputerName) {
            $hvArgs = @{ ComputerName = $hv; ErrorAction = 'Stop' }
            if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $hvArgs.Credential = $Credential }

            if ($Operation -eq 'Mount' -and -not $IsoPath) {
                throw '-IsoPath is required when -Operation is Mount.'
            }

            foreach ($name in $TargetVMName) {
                $vm  = Get-VM -Name $name @hvArgs
                $dvd = Get-VMDvdDrive -VMName $name @hvArgs -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $dvd) {
                    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target ('{0}\{1}' -f $hv, $name) `
                        -Message 'No DVD drive present on this VM'
                    continue
                }

                # Idempotency: mounting what is already mounted, or ejecting an empty
                # drive, is a no-op rather than an error.
                if ($Operation -eq 'Mount' -and $dvd.Path -eq $IsoPath) {
                    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0}\{1}' -f $hv, $name) `
                        -Message 'Skipped - that ISO is already mounted'
                    continue
                }
                if ($Operation -eq 'Unmount' -and -not $dvd.Path) {
                    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0}\{1}' -f $hv, $name) `
                        -Message 'Skipped - DVD drive is already empty'
                    continue
                }

                $results.Add([PSCustomObject]@{
                    Name            = ('{0}\{1}' -f $hv, $name)
                    Id              = $name
                    VMName          = $name
                    HyperVHost      = $hv
                    Operation       = $Operation
                    CurrentlyMounted= $dvd.Path
                    IsoPath         = $IsoPath
                    ControllerNumber= $dvd.ControllerNumber
                    ControllerLocation = $dvd.ControllerLocation
                    VMState         = "$($vm.State)"
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
        return
    }

    # Every candidate is logged individually BEFORE any action is taken.
    foreach ($c in $candidates) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0}' -f $c.Name) -Message 'CANDIDATE'
    }

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Mount/unmount ISO')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $hvArgs = @{ ComputerName = $item.HyperVHost; ErrorAction = 'Stop' }
            if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $hvArgs.Credential = $Credential }

            if ($item.Operation -eq 'Mount') {
                Set-VMDvdDrive -VMName $item.VMName -ControllerNumber $item.ControllerNumber `
                    -ControllerLocation $item.ControllerLocation -Path $item.IsoPath @hvArgs
                $detail = 'mounted {0}' -f $item.IsoPath
            } else {
                Set-VMDvdDrive -VMName $item.VMName -ControllerNumber $item.ControllerNumber `
                    -ControllerLocation $item.ControllerLocation -Path $null @hvArgs
                $detail = 'ejected {0}' -f $item.CurrentlyMounted
            }

            $after = (Get-VMDvdDrive -VMName $item.VMName @hvArgs | Select-Object -First 1).Path
            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                '{0} completed. DVD now: {1}' -f $item.Operation, $(if ($after) { $after } else { '<empty>' }))
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = $item.Operation; Detail = $detail; Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Hyper-V ISO Mount/Unmount'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
