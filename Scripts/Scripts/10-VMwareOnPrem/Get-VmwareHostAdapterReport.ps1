<#
.SYNOPSIS
    Reports ESXi host vNIC and HBA adapter and driver detail.

.DESCRIPTION
    Collects physical NIC and storage HBA inventory per host with driver and
    firmware detail where the host exposes it. Driver version drift across
    hosts in the same cluster is the condition this surfaces - it causes
    failures that look random until you compare hosts.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER VIServer
    vCenter server to connect to. Falls back to vmware.vCenterServer in
    config.json.

.PARAMETER Credential
    Credential for vCenter. Omit to use the PowerCLI credential store or SSPI.

.PARAMETER ClusterName
    Limit to VMs or hosts in specific clusters.

.PARAMETER VMHostName
    Limit to specific ESXi hosts.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-VmwareHostAdapterReport.ps1 -VIServer vcenter01 -ClusterName PROD -OutputFormat CSV

    Exports adapter inventory for a cluster.

.EXAMPLE
    .\Get-VmwareHostAdapterReport.ps1 -VIServer vcenter01 -VMHostName esx01.contoso.com

    Reports one host.

.NOTES
    Source use case      : #12 - vNICs & HBA Driver Info
    Category             : VMware OnPrem
    Technology           : PowerCLI / ESXi CLI
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Read-only"

    Required permissions : vSphere read-only role. Driver detail additionally needs host CLI access through the API.
    Required modules     : VMware.VimAutomation.Core
    Authentication       : Connect-VIServer with the PowerCLI credential store
                           or an explicit -Credential.

    Driver and firmware detail comes from esxcli through the vSphere API.
    Where a host does not expose it, the adapter is still reported with
    the driver fields null rather than omitted, so the gap is visible.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Core

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$VIServer,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [string[]]$ClusterName,

    [string[]]$VMHostName,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-VmwareHostAdapterReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #12 (VMware OnPrem)'

    try {
        $config = if ($ConfigPath) { Get-AutomationConfig -Path $ConfigPath } else { Get-AutomationConfig }
        # Recorded so an audit can tell which environment a run targeted.
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Configuration loaded for environment: {0}' -f $config.environment)
    } catch {
        # Read-only: config only supplies optional notification endpoints,
        # so its absence must not stop a report from being produced.
        $config = $null
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
            'Config unavailable ({0}); continuing because this script only reads.' -f $_.Exception.Message)
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

        $vmHosts = if ($VMHostName)  { Get-VMHost -Name $VMHostName -ErrorAction Stop }
                   elseif ($ClusterName) { Get-Cluster -Name $ClusterName | Get-VMHost }
                   else                  { Get-VMHost }

        foreach ($h in $vmHosts) {
            if ($h.ConnectionState -ne 'Connected') {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $h.Name `
                    -Message ('Skipped - host is {0}' -f $h.ConnectionState)
                continue
            }

            $esxcli = $null
            try { $esxcli = Get-EsxCli -VMHost $h -V2 -ErrorAction Stop }
            catch {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $h.Name `
                    -Message ('esxcli unavailable; driver detail will be null: {0}' -f $_.Exception.Message)
            }

            foreach ($nic in (Get-VMHostNetworkAdapter -VMHost $h -Physical -ErrorAction SilentlyContinue)) {
                $driver = $null; $driverVer = $null; $fw = $null
                if ($esxcli) {
                    try {
                        $info = $esxcli.network.nic.get.Invoke(@{ nicname = $nic.Name })
                        $driver    = $info.DriverInfo.Driver
                        $driverVer = $info.DriverInfo.Version
                        $fw        = $info.DriverInfo.FirmwareVersion
                    } catch {
                        Write-Verbose ('No esxcli detail for {0}/{1}' -f $h.Name, $nic.Name)
                    }
                }
                $results.Add([PSCustomObject]@{
                    Name          = ('{0} / {1}' -f $h.Name, $nic.Name)
                    Id            = $nic.Name
                    VMHost        = $h.Name
                    Cluster       = $h.Parent.Name
                    AdapterType   = 'vmnic'
                    AdapterName   = $nic.Name
                    MacAddress    = $nic.Mac
                    LinkSpeedMb   = $nic.BitRatePerSec
                    Driver        = $driver
                    DriverVersion = $driverVer
                    Firmware      = $fw
                    EsxiVersion   = $h.Version
                    EsxiBuild     = $h.Build
                })
            }

            foreach ($hba in (Get-VMHostHba -VMHost $h -ErrorAction SilentlyContinue)) {
                $results.Add([PSCustomObject]@{
                    Name          = ('{0} / {1}' -f $h.Name, $hba.Device)
                    Id            = $hba.Device
                    VMHost        = $h.Name
                    Cluster       = $h.Parent.Name
                    AdapterType   = "HBA-$($hba.Type)"
                    AdapterName   = $hba.Device
                    MacAddress    = $null
                    LinkSpeedMb   = $null
                    Driver        = $hba.Driver
                    DriverVersion = $null
                    Firmware      = $hba.Model
                    EsxiVersion   = $h.Version
                    EsxiBuild     = $h.Build
                    HbaStatus     = "$($hba.Status)"
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

    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message ('Collected {0} record(s).' -f $candidates.Count)
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'vNICs & HBA Driver Info'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
