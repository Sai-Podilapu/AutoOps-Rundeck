<#
.SYNOPSIS
    Expands a Hyper-V virtual hard disk.

.DESCRIPTION
    Grows a VHDX to a new size. Expansion only - the script refuses to shrink,
    because shrinking a VHDX below the guest partition layout destroys data.
    Expanding the VHDX does not extend the guest partition; that remains a
    deliberate second step inside the guest, which is why the workbook marks
    this ticket-driven.

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

.PARAMETER TargetVMName
    Virtual machine whose disk is being expanded.

.PARAMETER ControllerLocation
    Disk location on the controller. Use Get-VMHardDiskDrive to identify it.

.PARAMETER NewSizeGB
    New total size in GB. Must be larger than the current size.

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
    .\Resize-HvVirtualDisk.ps1 -ComputerName HV01 -TargetVMName APP01 -NewSizeGB 200

    REQUEST mode - validates and raises an approval, changing nothing.

.EXAMPLE
    .\Resize-HvVirtualDisk.ps1 -ComputerName HV01 -TargetVMName APP01 -NewSizeGB 200 -ApprovalReference APR-...

    Performs the approved expansion.

.NOTES
    Source use case      : #8 - Hyper-V Disk Expand
    Category             : Hyper-V
    Technology           : PowerShell / Resize-VHD
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "Expanding is safe-ish but touches guest partition; ticket-driven"

    Required permissions : Hyper-V Administrators on the host, plus write access to the VHD path.
    Required modules     : Hyper-V
    Authentication       : Integrated Kerberos over PSRemoting; SCVMM cmdlets
                           where noted.

    Expanding the VHDX does NOT extend the partition or filesystem inside
    the guest. After this completes, extend the volume in the guest OS.
    The script reports the new VHDX size, not new usable space, and says
    so in its output.

    Rollback             : NONE for the VHDX itself - a VHDX cannot be safely
                           shrunk afterwards. Take a checkpoint with
                           New-HvVmCheckpoint.ps1 first if you need a way back.
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
    [string]$TargetVMName,

    [ValidateRange(0,63)]
    [int]$ControllerLocation = 0,

    [Parameter(Mandatory)]
    [ValidateRange(1,65536)]
    [int]$NewSizeGB,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Disk capacity expansion',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Resize-HvVirtualDisk'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #8 (Hyper-V)'

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

            $disk = Get-VMHardDiskDrive -VMName $TargetVMName @hvArgs |
                    Where-Object { $_.ControllerLocation -eq $ControllerLocation } |
                    Select-Object -First 1
            if (-not $disk) {
                throw ('No hard disk at controller location {0} on VM {1}.' -f $ControllerLocation, $TargetVMName)
            }

            $vhd = Get-VHD -Path $disk.Path -ComputerName $hv -ErrorAction Stop
            $currentGB = [math]::Round($vhd.Size / 1GB, 2)

            # Refuse to shrink. Resize-VHD -ToMinimumSize exists but shrinking below the
            # guest partition layout destroys data, so this script only ever grows.
            if ($NewSizeGB -le $currentGB) {
                throw ('Refusing to resize: requested {0}GB is not larger than the current {1}GB. ' +
                       'This script expands only.' -f $NewSizeGB, $currentGB)
            }

            $vm = Get-VM -Name $TargetVMName @hvArgs
            $results.Add([PSCustomObject]@{
                Name           = ('{0}\{1} : {2}' -f $hv, $TargetVMName, (Split-Path -Leaf $disk.Path))
                Id             = $disk.Path
                VMName         = $TargetVMName
                HyperVHost     = $hv
                VhdPath        = $disk.Path
                VhdType        = "$($vhd.VhdType)"
                CurrentSizeGB  = $currentGB
                NewSizeGB      = $NewSizeGB
                IncreaseGB     = [math]::Round($NewSizeGB - $currentGB, 2)
                VMState        = "$($vm.State)"
                GuestActionRequired = 'Extend the partition inside the guest OS after this completes.'
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Expand virtual disk', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Expand virtual disk')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            Resize-VHD -Path $item.VhdPath -SizeBytes ($item.NewSizeGB * 1GB) -ComputerName $item.HyperVHost -ErrorAction Stop

            # Verify the new size rather than assuming it took.
            $after = Get-VHD -Path $item.VhdPath -ComputerName $item.HyperVHost
            $afterGB = [math]::Round($after.Size / 1GB, 2)

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'VHDX expanded {0}GB -> {1}GB. GUEST ACTION STILL REQUIRED: extend the partition inside the VM.' -f
                $item.CurrentSizeGB, $afterGB)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'Expanded'
                Detail = ('{0}GB -> {1}GB; guest partition extension still required' -f $item.CurrentSizeGB, $afterGB)
                Succeeded = ($afterGB -ge $item.NewSizeGB) })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Hyper-V Disk Expand'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
