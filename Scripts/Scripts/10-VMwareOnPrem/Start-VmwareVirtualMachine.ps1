<#
.SYNOPSIS
    Powers on vSphere virtual machines.

.DESCRIPTION
    Powers on selected VMs and waits for VMware Tools to report running, so
    the result reflects a booted guest rather than only a started VM.
    Reversible and low risk, so it executes directly - but it still logs every
    VM it touched.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER VIServer
    vCenter server to connect to. Falls back to vmware.vCenterServer in
    config.json.

.PARAMETER Credential
    Credential for vCenter. Omit to use the PowerCLI credential store or SSPI.

.PARAMETER VMName
    Limit to specific virtual machines.

.PARAMETER ClusterName
    Limit to VMs or hosts in specific clusters.

.PARAMETER WaitForToolsSeconds
    How long to wait for VMware Tools to report running. 0 skips the wait.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Start-VmwareVirtualMachine.ps1 -VIServer vcenter01 -VMName APP01,APP02

    Powers on two VMs and waits for Tools.

.EXAMPLE
    .\Start-VmwareVirtualMachine.ps1 -VIServer vcenter01 -VMName APP01 -WaitForToolsSeconds 0

    Issues the power-on without waiting for the guest.

.NOTES
    Source use case      : #7 - VM Power On
    Category             : VMware OnPrem
    Technology           : PowerCLI / REST
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Reversible"

    Required permissions : vSphere role with Virtual machine > Interaction > Power on.
    Required modules     : VMware.VimAutomation.Core
    Authentication       : Connect-VIServer with the PowerCLI credential store
                           or an explicit -Credential.

    Rollback             : Power the VM off again with
                           Stop-VmwareVirtualMachine.ps1.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Core

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$VIServer,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [string[]]$VMName,

    [string[]]$ClusterName,

    [ValidateRange(0,3600)]
    [int]$WaitForToolsSeconds = 300,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Start-VmwareVirtualMachine'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #7 (VMware OnPrem)'

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
        Connect-AutomationPlatform -Platform 'VMware' | Out-Null


        if (-not $VIServer -and $config -and $config.vmware) { $VIServer = $config.vmware.vCenterServer }
        if (-not $VIServer) { throw 'No vCenter specified. Pass -VIServer or set vmware.vCenterServer in config.json.' }

        $viParams = @{ Server = $VIServer; ErrorAction = 'Stop' }
        if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $viParams.Credential = $Credential }
        $vc = Connect-VIServer @viParams
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $VIServer -Message (
            'Connected to vCenter {0} (version {1})' -f $vc.Name, $vc.Version)

        $vms = if ($VMName)          { Get-VM -Name $VMName -ErrorAction Stop }
               elseif ($ClusterName) { Get-Cluster -Name $ClusterName | Get-VM }
               else                  { throw 'Specify -VMName or -ClusterName. Powering on every VM in vCenter is not a safe default.' }

        foreach ($vm in $vms) {
            if ($vm.PowerState -eq 'PoweredOn') {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $vm.Name -Message 'Skipped - already powered on'
                continue
            }
            $results.Add([PSCustomObject]@{
                Name       = $vm.Name
                Id         = $vm.Id
                VMName     = $vm.Name
                PowerState = "$($vm.PowerState)"
                VMHost     = $vm.VMHost.Name
                NumCpu     = $vm.NumCpu
                MemoryGB   = $vm.MemoryGB
            })
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Power on VM')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            Start-VM -VM $item.VMName -Confirm:$false -ErrorAction Stop | Out-Null

            $toolsState = 'not waited for'
            if ($WaitForToolsSeconds -gt 0) {
                $deadline = (Get-Date).AddSeconds($WaitForToolsSeconds)
                do {
                    Start-Sleep -Seconds 5
                    $toolsState = (Get-VM -Name $item.VMName).ExtensionData.Guest.ToolsRunningStatus
                } while ($toolsState -ne 'guestToolsRunning' -and (Get-Date) -lt $deadline)

                if ($toolsState -ne 'guestToolsRunning') {
                    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
                        'Powered on but VMware Tools did not report running within {0}s (state: {1})' -f $WaitForToolsSeconds, $toolsState)
                }
            }

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Powered on. Tools state: {0}' -f $toolsState)
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'PoweredOn'; Detail = ('tools: {0}' -f $toolsState); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'VM Power On'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
