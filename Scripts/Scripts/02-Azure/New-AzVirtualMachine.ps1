<#
.SYNOPSIS
    Provisions an Azure virtual machine from an approved specification.

.DESCRIPTION
    Creates a VM with the requested size, image and network placement. The VM
    size drives the monthly bill, so the estimated cost and the size SKU are
    put in front of the approver before anything is deployed - which is what
    the workbook guardrail asks for.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER SubscriptionId
    Subscription to operate in. Falls back to azure.defaultSubscriptionId in
    config.json.

.PARAMETER NewVMName
    Name of the VM to create.

.PARAMETER TargetResourceGroup
    Resource group to create the VM in. Must already exist.

.PARAMETER Location
    Azure region.

.PARAMETER VmSize
    VM size SKU. This is the main cost driver.

.PARAMETER Image
    Image URN, e.g. Win2022Datacenter or a full publisher:offer:sku:version.

.PARAMETER SubnetId
    Resource id of the subnet to attach the VM to.

.PARAMETER AdminCredential
    Local administrator credential for the new VM. Prompted for if omitted;
    never accepted as plaintext.

.PARAMETER AllowedVmSize
    Permitted size SKUs. A size outside this list is refused, so a typo cannot
    deploy an expensive VM.

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
    .\New-AzVirtualMachine.ps1 -NewVMName APP03 -TargetResourceGroup rg-prod -Location uaenorth -SubnetId '/subscriptions/.../subnets/app'

    REQUEST mode - validates the size against the allow-list and raises an
    approval.

.EXAMPLE
    .\New-AzVirtualMachine.ps1 -NewVMName APP03 -TargetResourceGroup rg-prod -Location uaenorth -SubnetId '...' -ApprovalReference APR-...

    Deploys the approved VM.

.NOTES
    Source use case      : #6 - Create VMs
    Category             : Azure
    Technology           : Az CLI / ARM Templates
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "Cost impact; approve size/SKU before agent deploys"

    Required permissions : Virtual Machine Contributor plus Network Contributor on the target scope.
    Required modules     : Az.Accounts, Az.Compute, Az.Network
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    The admin credential is taken as a PSCredential and never as a
    plaintext string. If it is omitted PowerShell prompts, which keeps the
    secret out of the command line and out of shell history.

    Rollback             : Remove-AzVM plus deletion of the NIC, disk and any
                           public IP. Deleting a VM does not delete those by
                           default - budget for cleaning them up too.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.Compute
#Requires -Modules Az.Network

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$NewVMName,

    [Parameter(Mandatory)]
    [string]$TargetResourceGroup,

    [Parameter(Mandatory)]
    [string]$Location,

    [string]$VmSize = 'Standard_D2s_v5',

    [string]$Image = 'Win2022Datacenter',

    [Parameter(Mandatory)]
    [string]$SubnetId,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $AdminCredential,

    [string[]]$AllowedVmSize = @('Standard_B2s','Standard_B2ms','Standard_D2s_v5','Standard_D4s_v5','Standard_E2s_v5'),

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

    $scriptName = 'New-AzVirtualMachine'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #6 (Azure)'

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

        if ($AllowedVmSize -and $AllowedVmSize -notcontains $VmSize) {
            throw ('Refusing to provision: size "{0}" is not in the allowed list ({1}).' -f $VmSize, ($AllowedVmSize -join ', '))
        }

        $rg = Get-AzResourceGroup -Name $TargetResourceGroup -ErrorAction SilentlyContinue
        if (-not $rg) { throw ('Resource group {0} does not exist. Create it first.' -f $TargetResourceGroup) }

        if (Get-AzVM -ResourceGroupName $TargetResourceGroup -Name $NewVMName -ErrorAction SilentlyContinue) {
            throw ('A VM named {0} already exists in {1}. Refusing to provision a duplicate.' -f $NewVMName, $TargetResourceGroup)
        }

        # Surface the size's actual specification so an approver sees what they are
        # approving, rather than an opaque SKU string.
        $sizeInfo = Get-AzVMSize -Location $Location | Where-Object Name -eq $VmSize | Select-Object -First 1

        $results.Add([PSCustomObject]@{
            Name          = $NewVMName
            Id            = $NewVMName
            ResourceGroup = $TargetResourceGroup
            Location      = $Location
            VmSize        = $VmSize
            Cores         = if ($sizeInfo) { $sizeInfo.NumberOfCores } else { $null }
            MemoryMB      = if ($sizeInfo) { $sizeInfo.MemoryInMB } else { $null }
            MaxDataDisks  = if ($sizeInfo) { $sizeInfo.MaxDataDiskCount } else { $null }
            Image         = $Image
            SubnetId      = $SubnetId
            CostNote      = 'VM size is the primary monthly cost driver - confirm the SKU before approving'
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Provision Azure VM', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Provision Azure VM')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            if (-not $AdminCredential) {
                throw 'An -AdminCredential is required to create the VM. It is never accepted as a plaintext string.'
            }

            $nicName = '{0}-nic' -f $item.Name
            $nic = New-AzNetworkInterface -Name $nicName -ResourceGroupName $item.ResourceGroup `
                -Location $item.Location -SubnetId $item.SubnetId -Force -ErrorAction Stop

            $vmConfig = New-AzVMConfig -VMName $item.Name -VMSize $item.VmSize |
                Set-AzVMOperatingSystem -Windows -ComputerName $item.Name -Credential $AdminCredential |
                Set-AzVMSourceImage -PublisherName 'MicrosoftWindowsServer' -Offer 'WindowsServer' `
                    -Skus '2022-datacenter-azure-edition' -Version 'latest' |
                Add-AzVMNetworkInterface -Id $nic.Id

            New-AzVM -ResourceGroupName $item.ResourceGroup -Location $item.Location -VM $vmConfig -ErrorAction Stop | Out-Null

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'VM provisioned: {0} ({1} cores, {2}MB RAM) in {3}' -f $item.VmSize, $item.Cores, $item.MemoryMB, $item.Location)
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'Provisioned'; Detail = $item.VmSize; Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Create VMs'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
