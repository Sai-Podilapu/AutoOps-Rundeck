<#
.SYNOPSIS
    Starts, stops (deallocates) or restarts Azure virtual machines.

.DESCRIPTION
    Brings selected VMs to the requested power state. Stop always DEALLOCATES,
    because a stopped-but-allocated VM still bills for compute - which defeats
    the purpose of a power schedule and is the mistake this script exists to
    avoid.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER SubscriptionId
    Subscription to operate in. Falls back to azure.defaultSubscriptionId in
    config.json.

.PARAMETER ResourceGroupName
    Limit to specific resource groups.

.PARAMETER VMName
    Limit to specific virtual machines.

.PARAMETER Operation
    Start, Stop (deallocate) or Restart.

.PARAMETER TagFilterKey
    Only act on VMs carrying this tag key.

.PARAMETER TagFilterValue
    Tag value to match when -TagFilterKey is given.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Set-AzVmPowerState.ps1 -Operation Stop -TagFilterKey Environment -TagFilterValue dev

    Deallocates every dev-tagged VM.

.EXAMPLE
    .\Set-AzVmPowerState.ps1 -Operation Start -ResourceGroupName rg-prod -WhatIf

    Shows which VMs would start.

.NOTES
    Source use case      : #1 - Azure VM Stop & Start
    Category             : Azure
    Technology           : Az PowerShell / CLI
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Reversible power ops; ideal agent task"

    Required permissions : Virtual Machine Contributor on the target scope.
    Required modules     : Az.Accounts, Az.Compute
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    Rollback             : Reverse the operation. Deallocation releases the
                           dynamic public IP unless the VM uses a static one -
                           check before scheduling a stop on anything reached
                           by IP.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.Compute

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [string[]]$ResourceGroupName,

    [string[]]$VMName,

    [Parameter(Mandatory)]
    [ValidateSet('Start','Stop','Restart')]
    [string]$Operation,

    [string]$TagFilterKey,

    [string]$TagFilterValue,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-AzVmPowerState'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #1 (Azure)'

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
        Connect-AutomationPlatform -Platform 'Azure' | Out-Null


        if (-not $SubscriptionId -and $config -and $config.azure) { $SubscriptionId = $config.azure.defaultSubscriptionId }
        if ($SubscriptionId) {
            Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop | Out-Null
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message ('Subscription context: {0}' -f $SubscriptionId)
        } else {
            $ctx = Get-AzContext
            if (-not $ctx) { throw 'No Azure context. Pass -SubscriptionId or set azure.defaultSubscriptionId in config.json.' }
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'No -SubscriptionId given; using the ambient context {0}' -f $ctx.Subscription.Id)
        }

        $vms = if ($ResourceGroupName) { $ResourceGroupName | ForEach-Object { Get-AzVM -ResourceGroupName $_ -Status } }
               else                    { Get-AzVM -Status }

        if ($VMName) { $vms = $vms | Where-Object { $VMName -contains $_.Name } }

        foreach ($vm in $vms) {
            if ($TagFilterKey) {
                $full = Get-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name
                $tagVal = $full.Tags[$TagFilterKey]
                if (-not $tagVal) { continue }
                if ($TagFilterValue -and $tagVal -ne $TagFilterValue) { continue }
            }

            $power = ($vm.PowerState -replace '^VM ', '')
            $wanted = switch ($Operation) {
                'Start'   { 'running' }
                'Stop'    { 'deallocated' }
                'Restart' { 'running' }
            }
            # Idempotent: a restart always acts, the other two skip if already there.
            if ($Operation -ne 'Restart' -and $power -eq $wanted) { continue }

            $results.Add([PSCustomObject]@{
                Name          = $vm.Name
                Id            = $vm.Id
                ResourceGroup = $vm.ResourceGroupName
                Location      = $vm.Location
                VmSize        = $vm.HardwareProfile.VmSize
                CurrentState  = $power
                DesiredState  = $wanted
                Operation     = $Operation
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Change Azure VM power state')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            switch ($item.Operation) {
                'Start'   { Start-AzVM   -ResourceGroupName $item.ResourceGroup -Name $item.Name -ErrorAction Stop | Out-Null }
                # -Force suppresses the prompt only; deallocation is what actually stops billing.
                'Stop'    { Stop-AzVM    -ResourceGroupName $item.ResourceGroup -Name $item.Name -Force -ErrorAction Stop | Out-Null }
                'Restart' { Restart-AzVM -ResourceGroupName $item.ResourceGroup -Name $item.Name -ErrorAction Stop | Out-Null }
            }

            $after = (Get-AzVM -ResourceGroupName $item.ResourceGroup -Name $item.Name -Status).Statuses |
                     Where-Object Code -like 'PowerState/*' | Select-Object -First 1 -Expand DisplayStatus
            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                '{0} complete: {1} -> {2}' -f $item.Operation, $item.CurrentState, $after)
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = $item.Operation; Detail = $after; Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Azure VM Stop & Start'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
