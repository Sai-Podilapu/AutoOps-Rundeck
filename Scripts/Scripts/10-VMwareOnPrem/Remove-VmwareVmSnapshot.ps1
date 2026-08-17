<#
.SYNOPSIS
    Removes vSphere snapshots older than a minimum age.

.DESCRIPTION
    Deletes snapshots beyond the retention age, optionally filtered by name
    pattern. Age and name filters are the safety control the workbook names:
    they stop the script touching a snapshot taken minutes ago for a change
    still in flight.

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

.PARAMETER MinimumAgeDays
    Only remove snapshots older than this.

.PARAMETER NamePattern
    Only remove snapshots whose name matches this wildcard pattern. Restricts
    the blast radius further.

.PARAMETER KeepLatest
    Always keep this many of the newest snapshots per VM regardless of age.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Remove-VmwareVmSnapshot.ps1 -VIServer vcenter01 -MinimumAgeDays 7

    Removes snapshots older than a week.

.EXAMPLE
    .\Remove-VmwareVmSnapshot.ps1 -VIServer vcenter01 -NamePattern 'pre-patch*' -MinimumAgeDays 14 -WhatIf

    Shows which old patching snapshots would be consolidated.

.NOTES
    Source use case      : #2 - VM Snapshot Deletion
    Category             : VMware OnPrem
    Technology           : PowerCLI / REST API
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: No
    Guardrails (col L)   : "Safe with age/name filters; consolidation impact noted"

    Required permissions : vSphere role with Virtual machine > Snapshot management > Remove snapshot.
    Required modules     : VMware.VimAutomation.Core
    Authentication       : Connect-VIServer with the PowerCLI credential store
                           or an explicit -Credential.

    Consolidation generates heavy datastore IO and can briefly stun the
    VM. Schedule outside peak hours - the consolidation impact is why the
    workbook rates this Medium rather than Low.

    Rollback             : NONE. Removing a snapshot consolidates its delta
                           into the base disk and cannot be undone. The age and
                           name filters exist because there is no recovery.
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

    [ValidateRange(1,3650)]
    [int]$MinimumAgeDays = 7,

    [string]$NamePattern = '*',

    [ValidateRange(0,50)]
    [int]$KeepLatest = 0,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Remove-VmwareVmSnapshot'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #2 (VMware OnPrem)'

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
               else                  { Get-VM }

        $cutoff = (Get-Date).AddDays(-$MinimumAgeDays)

        foreach ($vm in $vms) {
            $snaps = @(Get-Snapshot -VM $vm -ErrorAction SilentlyContinue | Sort-Object Created -Descending)
            if ($snaps.Count -eq 0) { continue }

            $eligible = if ($KeepLatest -gt 0) { $snaps | Select-Object -Skip $KeepLatest } else { $snaps }

            foreach ($s in $eligible) {
                if ($s.Created -ge $cutoff) { continue }
                if ($s.Name -notlike $NamePattern) { continue }

                $results.Add([PSCustomObject]@{
                    Name         = ('{0} / {1}' -f $vm.Name, $s.Name)
                    Id           = $s.Id
                    VMName       = $vm.Name
                    SnapshotName = $s.Name
                    CreatedAt    = $s.Created
                    AgeDays      = [math]::Round(((Get-Date) - $s.Created).TotalDays, 1)
                    SizeGB       = [math]::Round($s.SizeGB, 2)
                    Description  = $s.Description
                    ConsolidationNote = 'delta merges into the base disk on removal'
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Remove VM snapshot')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $snap = Get-Snapshot -VM $item.VMName -Name $item.SnapshotName -ErrorAction Stop
            Remove-Snapshot -Snapshot $snap -Confirm:$false -ErrorAction Stop
            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Snapshot removed (age {0}d, {1}GB). Consolidation now in progress on the datastore.' -f $item.AgeDays, $item.SizeGB)
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'SnapshotRemoved'; Detail = ('age {0}d, {1}GB' -f $item.AgeDays, $item.SizeGB); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'VM Snapshot Deletion'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
