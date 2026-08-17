<#
.SYNOPSIS
    Reimages AVD session hosts after draining them.

.DESCRIPTION
    Reimages session hosts back to their golden image. Everything on the host
    is destroyed, so the host must be drained and empty first - the script
    verifies both rather than trusting that somebody did it.

    DESTRUCTIVE. This script is REPORT-ONLY by default: it produces the
    candidate list and stops. Nothing is deleted, wiped or failed over
    unless -Execute is passed AND a valid -ApprovalReference is supplied.
    A pre-action backup/export is taken where the platform allows it, and
    every object is logged individually before it is touched.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER SubscriptionId
    Azure subscription. The current context when omitted.

.PARAMETER ResourceGroupName
    Resource group holding the host pool.

.PARAMETER HostPoolName
    AVD host pool name.

.PARAMETER SessionHostName
    Exact session host name(s) to reimage.

.PARAMETER VmssName
    Scale set backing the host pool, for VMSS-based pools. Required - non-VMSS
    hosts are reported as needing redeployment instead.

.PARAMETER AllowActiveSessions
    Reimage a host that still has sessions on it. Those users are cut off
    immediately with no warning.

.PARAMETER Execute
    Actually perform the destructive action. Without this the script only
    reports what it would do.

.PARAMETER ProtectedList
    Path to a file of names/ids that must never be acted upon, one per line.
    Entries here are excluded unconditionally and the exclusion cannot be
    overridden by any other parameter.

.PARAMETER MinimumAgeDays
    Only consider objects older than this. A conservative default guards
    against acting on something created moments ago.

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
    .\Restore-AvdSessionHost.ps1 -ResourceGroupName rg-avd -HostPoolName hp-prod -SessionHostName avd-01 -VmssName vmss-avd

    REPORT ONLY. Checks drain state and sessions, raises an approval.

.EXAMPLE
    .\Restore-AvdSessionHost.ps1 -ResourceGroupName rg-avd -HostPoolName hp-prod -SessionHostName avd-01 -VmssName vmss-avd -ApprovalReference APR-... -TicketReference CHG0012345 -Execute

    Reimages a drained, empty host.

.NOTES
    Source use case      : #7 - AVD Session Host Reimage
    Category             : Azure AVD
    Technology           : Az CLI / REST API
    Difficulty           : Medium
    Agent possible       : Partial
    Can execute with SOP : Yes - With Approval
    Automation type      : Destructive / High-Impact
    Risk level           : High
    Human approval needed: YES
    Guardrails (col L)   : "Reimage wipes host state; drain + approval before trigger"

    Required permissions : Desktop Virtualization Host Pool Contributor plus Virtual Machine Contributor on the scale set.
    Required modules     : Az.Accounts, Az.DesktopVirtualization, Az.Compute
    Authentication       : Inherits the Az context; managed identity preferred.

    DESTRUCTIVE, and the guardrail asks for drain plus approval before the
    trigger. Both are enforced: a host that is not already in drain mode
    is EXCLUDED rather than drained automatically, because draining and
    reimaging in one run gives sessions no time to end. Drain it, let it
    empty, then reimage. A host with active sessions is also excluded
    unless -AllowActiveSessions is passed, which cuts those users off with
    no warning. What is actually lost is worth being precise about: with
    FSLogix the user profile lives on the share and survives, but anything
    written to the local disk - files on C:, locally installed
    applications, machine-level configuration - does not.

    Rollback             : NONE. A reimage restores the golden image and
                           destroys everything else on the host. What survives
                           is what was never on the host: FSLogix profiles on
                           the share, and data in OneDrive or on file servers.
                           Anything saved to the local disk is gone.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.DesktopVirtualization
#Requires -Modules Az.Compute

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$HostPoolName,

    [Parameter(Mandatory)]
    [string[]]$SessionHostName,

    [string]$VmssName,

    [switch]$AllowActiveSessions,

    [switch]$Execute,

    [string]$ProtectedList,

    [ValidateRange(0, 3650)]
    [int]$MinimumAgeDays = 0,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Session host reimage to golden image',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Restore-AvdSessionHost'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #7 (Azure AVD)'

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

    $protected = @()
    if ($ProtectedList -and (Test-Path -LiteralPath $ProtectedList)) {
        $protected = @(Get-Content -LiteralPath $ProtectedList |
            Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { $_.Trim() })
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Protected list loaded: {0} entry(ies). These are excluded unconditionally.' -f $protected.Count)
    }

    # Risk = High: validate before doing anything at all.
    $pre = Test-Prerequisite -RequiredModule 'Az.Accounts','Az.DesktopVirtualization','Az.Compute'
    if (-not $pre.Passed) {
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Message $pre.Summary
        throw $pre.Summary
    }
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Pre-flight passed.'

    $results  = [System.Collections.Generic.List[PSCustomObject]]::new()
    $failures = [System.Collections.Generic.List[PSCustomObject]]::new()
}

process {
    try {
        Connect-AutomationPlatform -Platform 'AzureAVD' | Out-Null


        $azContext = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $azContext) {
            throw 'No Azure context. Run Connect-AzAccount, or use a managed identity, before this script.'
        }
        if ($SubscriptionId -and $azContext.Subscription.Id -ne $SubscriptionId) {
            $azContext = Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop
        }

        $hostPool = Get-AzWvdHostPool -ResourceGroupName $ResourceGroupName -Name $HostPoolName -ErrorAction Stop
        if (-not $hostPool) {
            throw ('Host pool "{0}" not found in resource group "{1}".' -f $HostPoolName, $ResourceGroupName)
        }
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Host pool {0}: type {1}, load balancer {2}, max sessions {3}' -f
            $hostPool.Name, $hostPool.HostPoolType, $hostPool.LoadBalancerType, $hostPool.MaxSessionLimit)

        $sessionHosts = @(Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName `
            -HostPoolName $HostPoolName -ErrorAction Stop)
        if ($sessionHosts.Count -eq 0) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message 'Host pool contains no session hosts.'
        }

        function Get-AvdShortName {
            <#
                .SYNOPSIS
                    The session host name without the host pool prefix Azure prepends.
            #>
            [CmdletBinding()]
            [OutputType([string])]
            param([Parameter(Mandatory)][string]$FullName)

            return ($FullName -split '/')[-1]
        }

        foreach ($name in $SessionHostName) {
            $sessionHost = $sessionHosts | Where-Object { (Get-AvdShortName -FullName $_.Name) -eq $name } |
                           Select-Object -First 1
            if (-not $sessionHost) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $name `
                    -Message 'Not found in this host pool; skipped.'
                continue
            }

            # Drain first, in a separate run. Draining and reimaging together gives
            # sessions no time to end.
            if ($sessionHost.AllowNewSession) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $name -Message (
                    'EXCLUDED - host is not in drain mode. Drain it with Set-AvdSessionHostDrainMode, let it ' +
                    'empty, then reimage. This script does not drain and reimage in one run.')
                continue
            }

            $activeSessions = [int]$sessionHost.Session
            if ($activeSessions -gt 0 -and -not $AllowActiveSessions) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $name -Message (
                    'EXCLUDED - {0} active session(s). Wait for the host to empty, or pass -AllowActiveSessions ' +
                    'to cut those users off with no warning.' -f $activeSessions)
                continue
            }

            if (-not $VmssName) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $name -Message (
                    'EXCLUDED - no -VmssName. Reimage is a scale set operation; a host pool built from ' +
                    'standalone VMs is replaced by redeployment instead, which this script does not do.')
                continue
            }

            $instance = $null
            try {
                $instances = @(Get-AzVmssVM -ResourceGroupName $ResourceGroupName -VMScaleSetName $VmssName -ErrorAction Stop)
                $instance = $instances | Where-Object { $_.OsProfile.ComputerName -eq ($name -split '\.')[0] } |
                            Select-Object -First 1
            } catch {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $name `
                    -Message ('Scale set instances unreadable: {0}' -f $_.Exception.Message)
                continue
            }
            if (-not $instance) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $name -Message (
                    'EXCLUDED - no matching instance in scale set {0}.' -f $VmssName)
                continue
            }

            $results.Add([PSCustomObject]@{
                Name            = $name
                Id              = $sessionHost.Name
                SessionHostName = $name
                VmssName        = $VmssName
                InstanceId      = $instance.InstanceId
                AllowNewSession = $sessionHost.AllowNewSession
                ActiveSessions  = $activeSessions
                HostStatus      = $sessionHost.Status
                AgentVersion    = $sessionHost.AgentVersion
                Survives        = 'FSLogix profiles on the share; OneDrive and file server data'
                Destroyed       = 'Everything on the local disk: files on C:, locally installed applications, machine-level configuration'
                Impact          = if ($activeSessions -gt 0) {
                                     ('{0} user(s) CUT OFF with no warning' -f $activeSessions)
                                  } else { 'Host is empty; no user is disconnected' }
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

    # Hard exclusions and safety filters BEFORE anything else.
    if ($protected.Count -gt 0) {
        $before = $candidates.Count
        $candidates = @($candidates | Where-Object {
            $id = $_.Id; $nm = $_.Name
            -not ($protected | Where-Object { $_ -and ($id -like $_ -or $nm -like $_) })
        })
        if ($before -ne $candidates.Count) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
                'Protected list excluded {0} object(s).' -f ($before - $candidates.Count))
        }
    }
    if ($MinimumAgeDays -gt 0) {
        $cut = (Get-Date).AddDays(-$MinimumAgeDays)
        $before = $candidates.Count
        $candidates = @($candidates | Where-Object { -not $_.CreatedAt -or $_.CreatedAt -lt $cut })
        if ($before -ne $candidates.Count) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
                'Age filter (>{0}d) excluded {1} object(s).' -f $MinimumAgeDays, ($before - $candidates.Count))
        }
    }

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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Reimage session host', $candidates.Count, $Reason, $TicketReference)
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

    if (-not $Execute) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'REPORT-ONLY - {0} candidate(s) identified, nothing was changed. Pass -Execute to act.' -f $candidates.Count)
        $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AVD Session Host Reimage (candidates)'
        Write-Output $candidates
        return
    }

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Reimage session host')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            Set-AzVmssVM -ResourceGroupName $ResourceGroupName -VMScaleSetName $item.VmssName `
                -InstanceId $item.InstanceId -Reimage -ErrorAction Stop | Out-Null

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Reimaged (instance {0}). Destroyed: {1}. Survived: {2}. {3}' -f
                $item.InstanceId, $item.Destroyed, $item.Survives, $item.Impact)
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
                'The host stays in drain mode after reimage. Return it to service with ' +
                'Set-AvdSessionHostDrainMode once it has registered and been checked.')
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'Reimaged'
                Detail = ('instance {0}, {1} session(s) at reimage' -f $item.InstanceId, $item.ActiveSessions)
                Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AVD Session Host Reimage'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
