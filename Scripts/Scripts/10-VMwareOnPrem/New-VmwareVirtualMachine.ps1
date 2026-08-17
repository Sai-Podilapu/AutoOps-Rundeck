<#
.SYNOPSIS
    Provisions a vSphere virtual machine from an approved specification.

.DESCRIPTION
    Creates a VM from a template or as an empty shell with the requested CPU,
    memory and disk, after verifying the target cluster and datastore have
    capacity. The capacity check is the guardrail: the cost of a provisioning
    mistake here is paid by every workload sharing the datastore.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER VIServer
    vCenter server to connect to. Falls back to vmware.vCenterServer in
    config.json.

.PARAMETER Credential
    Credential for vCenter. Omit to use the PowerCLI credential store or SSPI.

.PARAMETER NewVMName
    Name of the VM to create.

.PARAMETER TargetCluster
    Cluster to place the VM in.

.PARAMETER Datastore
    Datastore or datastore cluster for the VM.

.PARAMETER Template
    Template to deploy from. Omit to create an empty VM.

.PARAMETER NumCpu
    Virtual CPU count.

.PARAMETER MemoryGB
    Memory in GB.

.PARAMETER DiskGB
    System disk size in GB.

.PARAMETER PortGroup
    Network port group to attach.

.PARAMETER MinimumDatastoreFreePercent
    Refuse to provision if the datastore would drop below this.

.PARAMETER ApprovalReference
    Approval token from New-ApprovalRequest, after a human has approved it.
    Without this the script performs no change.

.PARAMETER RequestApproval
    Force REQUEST mode - produce the change set and raise an approval request,
    then stop, even if a reference was supplied.

.PARAMETER TicketReference
    ITSM ticket number recorded in the audit trail alongside the approval
    reference.

.PARAMETER Reason
    Change reason recorded in the approval artifact and the audit log.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\New-VmwareVirtualMachine.ps1 -VIServer vcenter01 -NewVMName APP03 -TargetCluster PROD -Datastore DS-PROD-01 -Template W2022-STD

    REQUEST mode - validates capacity and raises an approval, creating
    nothing.

.EXAMPLE
    .\New-VmwareVirtualMachine.ps1 -VIServer vcenter01 -NewVMName APP03 -TargetCluster PROD -Datastore DS-PROD-01 -ApprovalReference APR-...

    Creates the VM after the specification has been approved.

.NOTES
    Source use case      : #3 - Provision VM in vSphere
    Category             : VMware OnPrem
    Technology           : PowerCLI / Terraform
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "Capacity/cost impact; approve spec"

    Required permissions : vSphere role with Virtual machine > Inventory > Create new, plus datastore allocate space.
    Required modules     : VMware.VimAutomation.Core
    Authentication       : Connect-VIServer with the PowerCLI credential store
                           or an explicit -Credential.

    Rollback             : Remove-VM. The VM is created powered off, so a
                           mistaken provision consumes storage but affects no
                           running workload.
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

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$NewVMName,

    [Parameter(Mandatory)]
    [string]$TargetCluster,

    [Parameter(Mandatory)]
    [string]$Datastore,

    [string]$Template,

    [ValidateRange(1,128)]
    [int]$NumCpu = 2,

    [ValidateRange(1,6144)]
    [int]$MemoryGB = 4,

    [ValidateRange(1,62000)]
    [int]$DiskGB = 60,

    [string]$PortGroup,

    [ValidateRange(1,99)]
    [int]$MinimumDatastoreFreePercent = 20,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'New VM provisioning',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'New-VmwareVirtualMachine'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #3 (VMware OnPrem)'

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

        if (Get-VM -Name $NewVMName -ErrorAction SilentlyContinue) {
            throw ('A VM named {0} already exists in {1}. Refusing to provision a duplicate.' -f $NewVMName, $VIServer)
        }

        $cluster = Get-Cluster -Name $TargetCluster -ErrorAction Stop
        $ds      = Get-Datastore -Name $Datastore -ErrorAction Stop

        $freeAfterGB  = $ds.FreeSpaceGB - $DiskGB
        $freeAfterPct = if ($ds.CapacityGB -gt 0) { [math]::Round(($freeAfterGB / $ds.CapacityGB) * 100, 1) } else { 0 }
        if ($freeAfterPct -lt $MinimumDatastoreFreePercent) {
            throw ('Refusing to provision: datastore {0} would be {1}% free after a {2}GB disk, below the {3}% floor.' -f
                   $ds.Name, $freeAfterPct, $DiskGB, $MinimumDatastoreFreePercent)
        }

        # Cluster CPU/memory headroom, so an approver sees the capacity impact.
        $hosts = @(Get-VMHost -Location $cluster)
        $totalMemGB = [math]::Round((($hosts | Measure-Object MemoryTotalGB -Sum).Sum), 1)
        $usedMemGB  = [math]::Round((($hosts | Measure-Object MemoryUsageGB -Sum).Sum), 1)

        $results.Add([PSCustomObject]@{
            Name              = $NewVMName
            Id                = $NewVMName
            VMName            = $NewVMName
            Cluster           = $cluster.Name
            Datastore         = $ds.Name
            Template          = $Template
            NumCpu            = $NumCpu
            MemoryGB          = $MemoryGB
            DiskGB            = $DiskGB
            PortGroup         = $PortGroup
            DatastoreFreeGB   = [math]::Round($ds.FreeSpaceGB, 1)
            DatastoreFreeAfterPct = $freeAfterPct
            ClusterMemoryTotalGB  = $totalMemGB
            ClusterMemoryUsedGB   = $usedMemGB
            ClusterHosts      = $hosts.Count
        })
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

    if ($RequestApproval -or -not $ApprovalReference) {
        $request = New-ApprovalRequest -ScriptName $scriptName -ChangeSet $candidates `
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Provision vSphere VM', $candidates.Count, $Reason, $TicketReference)
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $request.Reference -Message (
            'REQUEST mode - nothing was changed. Supply -ApprovalReference {0} once approved.' -f $request.Reference)
        Write-Warning ('No change made. Approval reference: {0}' -f $request.Reference)
        Write-Output ([PSCustomObject]@{
            Mode = 'RequestApproval'; ApprovalReference = $request.Reference
            CandidateCount = $candidates.Count; Candidates = $candidates; Changed = $false })
        return
    }

    $approvalCheck = Test-ApprovalReference -Reference $ApprovalReference -ScriptName $scriptName
    if (-not $approvalCheck.IsValid) {
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $ApprovalReference -Message (
            'REFUSED to execute: {0}' -f $approvalCheck.Reason)
        throw ('Approval validation failed: {0}' -f $approvalCheck.Reason)
    }
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $ApprovalReference -Message (
        'Approval accepted. {0} Ticket={1}' -f $approvalCheck.Reason, $TicketReference)

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Provision vSphere VM')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $newParams = @{
                Name        = $item.VMName
                ResourcePool= (Get-Cluster -Name $item.Cluster)
                Datastore   = (Get-Datastore -Name $item.Datastore)
                Confirm     = $false
                ErrorAction = 'Stop'
            }
            if ($item.Template) {
                $newParams.Template = (Get-Template -Name $item.Template -ErrorAction Stop)
            } else {
                $newParams.NumCpu    = $item.NumCpu
                $newParams.MemoryGB  = $item.MemoryGB
                $newParams.DiskGB    = $item.DiskGB
                $newParams.GuestId   = 'windows2019srvNext_64Guest'
            }
            if ($item.PortGroup) { $newParams.PortGroup = (Get-VirtualPortGroup -Name $item.PortGroup -ErrorAction Stop) }

            $created = New-VM @newParams

            # A template deployment inherits the template's spec, so the requested CPU and
            # memory are applied afterwards rather than assumed.
            if ($item.Template) {
                Set-VM -VM $created -NumCpu $item.NumCpu -MemoryGB $item.MemoryGB -Confirm:$false -ErrorAction Stop | Out-Null
            }

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'VM provisioned: {0} vCPU, {1}GB RAM, {2}GB disk on {3}. Left powered OFF for build.' -f
                $item.NumCpu, $item.MemoryGB, $item.DiskGB, $item.Datastore)
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'Provisioned'; Detail = ('cluster {0}' -f $item.Cluster); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Provision VM in vSphere'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
