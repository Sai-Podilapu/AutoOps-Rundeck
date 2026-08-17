<#
.SYNOPSIS
    Provisions an Azure private endpoint for a target resource.

.DESCRIPTION
    Creates a private endpoint against a PaaS resource and attaches it to a
    subnet. This is a network topology change: it alters how the resource is
    reached and, once private DNS is in play, can make the public endpoint
    unreachable for existing clients. Approval-gated accordingly.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER SubscriptionId
    Subscription to operate in. Falls back to azure.defaultSubscriptionId in
    config.json.

.PARAMETER EndpointName
    Name for the new private endpoint.

.PARAMETER TargetResourceGroup
    Resource group to create the endpoint in.

.PARAMETER PrivateLinkResourceId
    Resource id of the PaaS resource to connect to.

.PARAMETER GroupId
    Sub-resource to connect to, e.g. blob, sqlServer, vault.

.PARAMETER SubnetId
    Resource id of the subnet to place the endpoint in.

.PARAMETER Location
    Azure region. Defaults to the subnet\u2019s region.

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
    .\New-AzPrivateEndpointConnection.ps1 -EndpointName pe-sa-prod -TargetResourceGroup rg-net -PrivateLinkResourceId '/subscriptions/.../storageAccounts/sa' -GroupId blob -SubnetId '/subscriptions/.../subnets/pe'

    REQUEST mode - validates and raises an approval.

.EXAMPLE
    .\New-AzPrivateEndpointConnection.ps1 -EndpointName pe-sa-prod -TargetResourceGroup rg-net -PrivateLinkResourceId '...' -GroupId blob -SubnetId '...' -ApprovalReference APR-...

    Creates the approved endpoint.

.NOTES
    Source use case      : #20 - Azure Private Endpoint Provisioning
    Category             : Azure
    Technology           : Az CLI / Terraform
    Difficulty           : High
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "Network topology change; IaC review before apply"

    Required permissions : Network Contributor on the subnet plus at least Reader on the target resource.
    Required modules     : Az.Accounts, Az.Network
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    This script creates the endpoint only. It does NOT create the private
    DNS zone or the zone group linking them, because the DNS design is
    environment-specific and getting it wrong silently breaks name
    resolution. Complete the DNS step separately.

    Rollback             : Remove-AzPrivateEndpoint. Note that removing the
                           endpoint does not restore public access if the
                           target resource\u2019s public network access was
                           disabled separately.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.Network

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$EndpointName,

    [Parameter(Mandatory)]
    [string]$TargetResourceGroup,

    [Parameter(Mandatory)]
    [string]$PrivateLinkResourceId,

    [Parameter(Mandatory)]
    [string]$GroupId,

    [Parameter(Mandatory)]
    [string]$SubnetId,

    [string]$Location,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Private endpoint provisioning',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'New-AzPrivateEndpointConnection'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #20 (Azure)'

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

        if (Get-AzPrivateEndpoint -Name $EndpointName -ResourceGroupName $TargetResourceGroup -ErrorAction SilentlyContinue) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $EndpointName `
                -Message 'Skipped - private endpoint already exists (idempotent)'
            return
        }

        $subnetParts = $SubnetId -split '/'
        $vnetRg   = $subnetParts[4]
        $vnetName = $subnetParts[8]
        $subnetName = $subnetParts[10]

        $vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $vnetRg -ErrorAction Stop
        $subnet = $vnet.Subnets | Where-Object Name -eq $subnetName | Select-Object -First 1
        if (-not $subnet) { throw ('Subnet {0} not found in {1}.' -f $subnetName, $vnetName) }

        $target = Get-AzResource -ResourceId $PrivateLinkResourceId -ErrorAction Stop

        if (-not $Location) { $Location = $vnet.Location }

        $results.Add([PSCustomObject]@{
            Name              = $EndpointName
            Id                = $EndpointName
            ResourceGroup     = $TargetResourceGroup
            Location          = $Location
            TargetResource    = $target.Name
            TargetType        = $target.ResourceType
            GroupId           = $GroupId
            VNet              = $vnetName
            Subnet            = $subnetName
            SubnetPrefix      = ($subnet.AddressPrefix -join ',')
            PrivateLinkResourceId = $PrivateLinkResourceId
            SubnetId          = $SubnetId
            DnsNote           = 'Private DNS zone and zone group are NOT created by this script - complete that step separately'
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Create private endpoint', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Create private endpoint')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $connection = New-AzPrivateLinkServiceConnection -Name ('{0}-conn' -f $item.Name) `
                -PrivateLinkServiceId $item.PrivateLinkResourceId -GroupId $item.GroupId -ErrorAction Stop

            New-AzPrivateEndpoint -Name $item.Name -ResourceGroupName $item.ResourceGroup `
                -Location $item.Location -Subnet @{ Id = $item.SubnetId } `
                -PrivateLinkServiceConnection $connection -Force -ErrorAction Stop | Out-Null

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Private endpoint created for {0} ({1}) in {2}/{3}. DNS zone group still required.' -f
                $item.TargetResource, $item.GroupId, $item.VNet, $item.Subnet)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'EndpointCreated'
                Detail = ('{0} -> {1}' -f $item.TargetResource, $item.Subnet); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Azure Private Endpoint Provisioning'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
