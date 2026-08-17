<#
.SYNOPSIS
    Provisions a new Hyper-V virtual machine from an approved specification.

.DESCRIPTION
    Creates a Generation 2 VM with the requested CPU, memory, disk and
    network, then leaves it powered off for the build process to take over.
    Host capacity is checked before the VM is created, because the workbook
    guardrail for this row is capacity impact.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER ComputerName
    Hyper-V host(s) to act against. Defaults to the local host.

.PARAMETER Credential
    Credential for the remote Hyper-V host.

.PARAMETER NewVMName
    Name of the VM to create.

.PARAMETER MemoryStartupGB
    Startup memory in GB.

.PARAMETER ProcessorCount
    Virtual processor count.

.PARAMETER DiskSizeGB
    Size of the new system VHDX in GB.

.PARAMETER SwitchName
    Virtual switch to connect the VM to.

.PARAMETER VhdPath
    Directory for the new VHDX. Defaults to the host default virtual hard disk
    path.

.PARAMETER MinimumHostFreeGB
    Refuse to provision if the host storage would drop below this.

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
    .\New-HvVirtualMachine.ps1 -ComputerName HV01 -NewVMName APP03 -SwitchName 'Prod-vSwitch' -MemoryStartupGB 8 -ProcessorCount 4

    REQUEST mode - produces the spec and raises an approval, creating nothing.

.EXAMPLE
    .\New-HvVirtualMachine.ps1 -ComputerName HV01 -NewVMName APP03 -SwitchName 'Prod-vSwitch' -ApprovalReference APR-...

    Creates the VM after the specification has been approved.

.NOTES
    Source use case      : #4 - Hyper-V New VM Provisioning
    Category             : Hyper-V
    Technology           : PowerShell / SCVMM
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "Capacity impact; approve spec before deploy"

    Required permissions : Hyper-V Administrators on the host, plus write access to the VHD path.
    Required modules     : Hyper-V
    Authentication       : Integrated Kerberos over PSRemoting; SCVMM cmdlets
                           where noted.

    Rollback             : Remove-VM plus deletion of the VHDX. The VM is
                           created powered off, so a mistaken provision
                           consumes storage but affects no running workload.
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
    [ValidateNotNullOrEmpty()]
    [string]$NewVMName,

    [ValidateRange(1,1024)]
    [int]$MemoryStartupGB = 4,

    [ValidateRange(1,240)]
    [int]$ProcessorCount = 2,

    [ValidateRange(10,65536)]
    [int]$DiskSizeGB = 100,

    [Parameter(Mandatory)]
    [string]$SwitchName,

    [string]$VhdPath,

    [ValidateRange(0,100000)]
    [int]$MinimumHostFreeGB = 100,

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

    $scriptName = 'New-HvVirtualMachine'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #4 (Hyper-V)'

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

            # Refuse a duplicate name before anything else - this is not idempotent by
            # nature and a second VM with the same name is a real incident.
            $existing = Get-VM -Name $NewVMName @hvArgs -ErrorAction SilentlyContinue
            if ($existing) {
                throw ('A VM named {0} already exists on {1}. Refusing to provision a duplicate.' -f $NewVMName, $hv)
            }

            $hostInfo = Get-VMHost @hvArgs
            $targetPath = if ($VhdPath) { $VhdPath } else { $hostInfo.VirtualHardDiskPath }

            # Capacity check - the workbook guardrail for this row.
            $drive = Split-Path -Qualifier $targetPath
            $freeGB = $null
            try {
                $cim = @{ ClassName = 'Win32_LogicalDisk'; Filter = "DeviceID='$drive'"; ErrorAction = 'Stop' }
                if ($hv -ne $env:COMPUTERNAME) { $cim.ComputerName = $hv }
                $freeGB = [math]::Round((Get-CimInstance @cim).FreeSpace / 1GB, 1)
            } catch {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $hv `
                    -Message ('Could not read free space on {0}: {1}' -f $drive, $_.Exception.Message)
            }
            if ($null -ne $freeGB -and ($freeGB - $DiskSizeGB) -lt $MinimumHostFreeGB) {
                throw ('Refusing to provision: {0} would leave {1}GB free on {2}, below the {3}GB floor.' -f
                       $hv, [math]::Round($freeGB - $DiskSizeGB, 1), $drive, $MinimumHostFreeGB)
            }

            $results.Add([PSCustomObject]@{
                Name            = ('{0}\{1}' -f $hv, $NewVMName)
                Id              = $NewVMName
                VMName          = $NewVMName
                HyperVHost      = $hv
                MemoryStartupGB = $MemoryStartupGB
                ProcessorCount  = $ProcessorCount
                DiskSizeGB      = $DiskSizeGB
                SwitchName      = $SwitchName
                VhdFullPath     = (Join-Path $targetPath ('{0}.vhdx' -f $NewVMName))
                HostFreeGB      = $freeGB
                HostFreeAfterGB = if ($null -ne $freeGB) { [math]::Round($freeGB - $DiskSizeGB, 1) } else { $null }
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

    if ($RequestApproval -or -not $ApprovalReference) {
        $request = New-ApprovalRequest -ScriptName $scriptName -ChangeSet $candidates `
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Provision new VM', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Provision new VM')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $hvArgs = @{ ComputerName = $item.HyperVHost; ErrorAction = 'Stop' }
            if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $hvArgs.Credential = $Credential }

            New-VM -Name $item.VMName -MemoryStartupBytes ($item.MemoryStartupGB * 1GB) `
                   -NewVHDPath $item.VhdFullPath -NewVHDSizeBytes ($item.DiskSizeGB * 1GB) `
                   -SwitchName $item.SwitchName -Generation 2 @hvArgs | Out-Null

            Set-VMProcessor -VMName $item.VMName -Count $item.ProcessorCount @hvArgs

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'VM provisioned: {0} vCPU, {1}GB RAM, {2}GB disk on {3}. Left powered OFF for build.' -f
                $item.ProcessorCount, $item.MemoryStartupGB, $item.DiskSizeGB, $item.SwitchName)
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'Provisioned'; Detail = $item.VhdFullPath; Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Hyper-V New VM Provisioning'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
