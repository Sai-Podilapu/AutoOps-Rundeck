<#
.SYNOPSIS
    Releases Elastic IP addresses that are allocated but not associated.

.DESCRIPTION
    Finds allocated EIPs with no association and releases them. Releasing an
    EIP returns the address to the AWS pool permanently - it cannot be
    reclaimed, and anything with that IP in a DNS record, firewall rule or
    allow-list breaks. That irreversibility is why this is approval-gated
    despite being classed as Change/Write.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER Region
    AWS region to operate in. Defaults to the configured default region.

.PARAMETER ProfileName
    Named AWS profile / SSO profile to use. Prefer an IAM role where the host
    supports one.

.PARAMETER ExcludeTagKey
    EIPs carrying this tag are never released.

.PARAMETER ProtectedAddress
    Specific IP addresses that must never be released, whatever else is true.

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
    .\Remove-AwsUnusedElasticIp.ps1 -Region me-central-1

    REQUEST mode - lists unassociated EIPs and raises an approval. Releases
    nothing.

.EXAMPLE
    .\Remove-AwsUnusedElasticIp.ps1 -Region me-central-1 -ApprovalReference APR-... -ProtectedAddress 52.1.2.3

    Releases the approved addresses while protecting one explicitly.

.NOTES
    Source use case      : #17 - AWS Elastic IP Unused Cleanup
    Category             : AWS
    Technology           : Boto3
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "Releasing EIPs loses the IP permanently; approval gate advised"

    Required permissions : ec2:DescribeAddresses, ec2:ReleaseAddress
    Required modules     : AWS.Tools.Common, AWS.Tools.EC2
    Authentication       : IAM role or SSO profile via Set-AWSCredential. Never
                           an access key pair in code.

    An unassociated EIP still bills hourly, which is the reason to clean
    them up. But check DNS and any external allow-lists before approving -
    the cost saving is small and the breakage can be large.

    Rollback             : NONE. A released EIP returns to the shared AWS pool
                           and cannot be reclaimed. If the address appears in
                           DNS, a partner allow-list or a firewall rule,
                           releasing it is a breaking change with no undo.
#>

#Requires -Version 5.1
#Requires -Modules AWS.Tools.Common
#Requires -Modules AWS.Tools.EC2

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$Region,

    [string]$ProfileName,

    [string]$ExcludeTagKey = 'AutoOps:DoNotRelease',

    [string[]]$ProtectedAddress,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Unused Elastic IP cleanup',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Remove-AwsUnusedElasticIp'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #17 (AWS)'

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
        Connect-AutomationPlatform -Platform 'AWS' | Out-Null


        $awsArgs = @{}
        if ($Region)      { $awsArgs.Region = $Region }
        if ($ProfileName) { $awsArgs.ProfileName = $ProfileName }

        foreach ($eip in (Get-EC2Address @awsArgs)) {
            # Associated addresses are in use by definition.
            if ($eip.AssociationId -or $eip.InstanceId -or $eip.NetworkInterfaceId) { continue }

            if ($ProtectedAddress -contains $eip.PublicIp) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $eip.PublicIp `
                    -Message 'Excluded - listed in -ProtectedAddress'
                continue
            }
            if ($ExcludeTagKey -and ($eip.Tags | Where-Object Key -eq $ExcludeTagKey)) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $eip.PublicIp `
                    -Message ('Excluded - carries the {0} tag' -f $ExcludeTagKey)
                continue
            }

            $name = ($eip.Tags | Where-Object Key -eq 'Name' | Select-Object -First 1 -Expand Value)
            $results.Add([PSCustomObject]@{
                Name          = if ($name) { $name } else { $eip.PublicIp }
                Id            = $eip.AllocationId
                PublicIp      = $eip.PublicIp
                AllocationId  = $eip.AllocationId
                Domain        = "$($eip.Domain)"
                NetworkBorderGroup = $eip.NetworkBorderGroup
                EstMonthlyUsd = 3.60
                Tags          = (($eip.Tags | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join '; ')
                Warning       = 'Release is PERMANENT - verify DNS records and external allow-lists first'
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Release Elastic IP', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Release Elastic IP')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
                'RELEASING {0} permanently. Approval={1} Ticket={2}' -f $item.PublicIp, $ApprovalReference, $TicketReference)

            Remove-EC2Address -AllocationId $item.AllocationId -Force @awsArgs | Out-Null

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Elastic IP {0} released to the AWS pool. This cannot be undone.' -f $item.PublicIp)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'Released'
                Detail = ('{0} - permanent' -f $item.PublicIp); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AWS Elastic IP Unused Cleanup'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
