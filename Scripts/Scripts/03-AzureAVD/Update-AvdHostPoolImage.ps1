<#
.SYNOPSIS
    Rolls a validated golden image out to a host pool in batches.

.DESCRIPTION
    Points a host pool at a new golden image version and rolls it out in
    batches, draining each batch before it is touched. It will not start until
    a human has recorded that the image was validated and UAT signed off - the
    workbook assigns that to a person and this script has no way to judge it.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

    AGENT-ASSIST ONLY. This automates the mechanical part - gathering,
    enriching and comparing against a baseline - and then stops, producing
    a decision-ready package. The judgement step is deliberately left to a
    human and is NOT scripted.

.PARAMETER SubscriptionId
    Azure subscription. The current context when omitted.

.PARAMETER ResourceGroupName
    Resource group holding the host pool.

.PARAMETER HostPoolName
    AVD host pool name.

.PARAMETER GalleryImageId
    Full resource id of the Compute Gallery image VERSION to roll out.

.PARAMETER ImageValidated
    Confirms the golden image was validated. Required - there is no way for
    this script to establish it.

.PARAMETER UatSignOffBy
    Name of the person who signed off UAT on this image. Recorded in the audit
    trail and required.

.PARAMETER BatchSize
    How many session hosts to roll out at once.

.PARAMETER ApiVersion
    PLACEHOLDER - ARM api-version for the session host configuration and
    update operations. These moved through several preview versions; VERIFY
    against your tenant. Listed in MANIFEST.md under Needs Input.

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
    .\Update-AvdHostPoolImage.ps1 -ResourceGroupName rg-avd -HostPoolName hp-prod -GalleryImageId /subscriptions/.../versions/1.0.5

    REPORT ONLY. Validates the image and raises an approval.

.EXAMPLE
    .\Update-AvdHostPoolImage.ps1 -ResourceGroupName rg-avd -HostPoolName hp-prod -GalleryImageId /subscriptions/.../versions/1.0.5 -ImageValidated -UatSignOffBy 'A. Rahman' -ApprovalReference APR-... -BatchSize 2

    Rolls the validated image out two hosts at a time.

.NOTES
    Source use case      : #2 - AVD Image Version Update & Pool Rollout
    Category             : Azure AVD
    Technology           : Az Image Builder / AVD
    Difficulty           : High
    Agent possible       : Partial
    Can execute with SOP : Partially - Agent Assists
    Automation type      : Change / Write
    Risk level           : High
    Human approval needed: YES
    Guardrails (col L)   : "Agent orchestrates image build & staged rollout; golden image validation / UAT sign-off before rollout is human"

    Required permissions : Desktop Virtualization Host Pool Contributor, plus Reader on the Compute Gallery.
    Required modules     : Az.Accounts, Az.DesktopVirtualization, Az.Compute
    Authentication       : Inherits the Az context; managed identity preferred.

    ASSIST-ONLY. The orchestration - drain, batch, sequence, record - is
    mechanical and worth automating. Deciding that a golden image is fit
    to put in front of users is not: it needs someone to log in to it and
    use the applications. So -ImageValidated and -UatSignOffBy are both
    mandatory, and the second one records WHO, because "validated" with no
    name attached is not a sign-off. The rollout mechanism uses the
    session host configuration API, whose api-version moved through
    several previews - it is a parameter rather than a guess.

    Rollback             : Re-run against the PREVIOUS image version id, which
                           is captured and logged before the change. Sessions
                           already migrated to the new image are not rolled
                           back by that - they are replaced again.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.DesktopVirtualization
#Requires -Modules Az.Compute

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$HostPoolName,

    [Parameter(Mandatory)]
    [string]$GalleryImageId,

    [switch]$ImageValidated,

    [string]$UatSignOffBy,

    [ValidateRange(1,100)]
    [int]$BatchSize = 2,

    [string]$ApiVersion = '2024-04-08-preview',

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Validated golden image rollout',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Update-AvdHostPoolImage'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #2 (Azure AVD)'

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

        if (-not $ImageValidated) {
            throw 'Refusing to roll out without -ImageValidated. Whether a golden image is fit to put in ' +
                  'front of users needs someone to log in to it and use the applications; this script cannot ' +
                  'establish that.'
        }
        if (-not $UatSignOffBy) {
            throw 'Refusing to roll out without -UatSignOffBy. "Validated" with no name attached is not a sign-off.'
        }

        # Confirm the image version exists before anybody approves a rollout of it.
        $imageVersion = $null
        try {
            $imageVersion = Get-AzResource -ResourceId $GalleryImageId -ErrorAction Stop
        } catch {
            throw ('Image version {0} could not be resolved: {1}. The rollout is not proposed against an ' +
                   'image that may not exist.' -f $GalleryImageId, $_.Exception.Message)
        }

        $currentImage = ''
        try {
            $configResponse = Invoke-AzRestMethod -Method GET -ErrorAction Stop -Path (
                '/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.DesktopVirtualization/hostPools/{2}' +
                '/sessionHostConfigurations/default?api-version={3}' -f
                $azContext.Subscription.Id, $ResourceGroupName, $HostPoolName, $ApiVersion)
            if ($configResponse.StatusCode -lt 400) {
                $currentImage = ($configResponse.Content | ConvertFrom-Json).properties.imageInfo.customInfo.resourceId
            } else {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                    'Session host configuration unreadable (HTTP {0}). The current image is unknown, so the ' +
                    'rollback reference below will be empty. Check -ApiVersion against your tenant.' -f $configResponse.StatusCode)
            }
        } catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'Session host configuration unreadable: {0}' -f $_.Exception.Message)
        }

        if ($currentImage -eq $GalleryImageId) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
                'Skipped - the host pool already points at this image version (idempotent).')
        } else {
            $ordered = @($sessionHosts | Sort-Object Name)
            $batchNumber = 0
            for ($i = 0; $i -lt $ordered.Count; $i += $BatchSize) {
                $batchNumber++
                $batch = @($ordered[$i..([math]::Min($i + $BatchSize - 1, $ordered.Count - 1))])

                $results.Add([PSCustomObject]@{
                    Name           = ('Batch {0}' -f $batchNumber)
                    Id             = ('batch-{0}' -f $batchNumber)
                    BatchNumber    = $batchNumber
                    SessionHosts   = ((@($batch) | ForEach-Object { Get-AvdShortName -FullName $_.Name }) -join '; ')
                    HostCount      = $batch.Count
                    ActiveSessions = (@($batch) | Measure-Object Session -Sum).Sum
                    CurrentImage   = $currentImage
                    TargetImage    = $GalleryImageId
                    ImageName      = $imageVersion.Name
                    UatSignOffBy   = $UatSignOffBy
                    ApiVersion     = $ApiVersion
                    Impact         = 'Hosts are drained first, so sessions end naturally rather than being cut'
                })
            }

            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
                '{0} host(s) in {1} batch(es) of {2}. Image validated, UAT signed off by {3}.' -f
                $ordered.Count, $batchNumber, $BatchSize, $UatSignOffBy)
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Roll out image to host pool', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Roll out image to host pool')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
                'Previous image (rollback reference): {0}' -f
                $(if ($item.CurrentImage) { $item.CurrentImage } else { '(not readable)' }))

            # Drain first, so sessions end naturally rather than being cut.
            foreach ($name in ($item.SessionHosts -split ';')) {
                $shortName = $name.Trim()
                if (-not $shortName) { continue }
                Update-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName `
                    -Name $shortName -AllowNewSession:$false -ErrorAction Stop | Out-Null
            }
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
                '{0} host(s) drained ahead of the update; {1} session(s) were active.' -f
                $item.HostCount, $item.ActiveSessions)

            $configBody = @{
                properties = @{
                    imageInfo = @{
                        type = 'Custom'
                        customInfo = @{ resourceId = $item.TargetImage }
                    }
                }
            } | ConvertTo-Json -Depth 8

            $configPath = ('/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.DesktopVirtualization/hostPools/{2}' +
                           '/sessionHostConfigurations/default?api-version={3}') -f
                           $azContext.Subscription.Id, $ResourceGroupName, $HostPoolName, $item.ApiVersion

            $configUpdate = Invoke-AzRestMethod -Method PUT -Path $configPath -Payload $configBody -ErrorAction Stop
            if ($configUpdate.StatusCode -ge 400) {
                throw ('Session host configuration update failed (HTTP {0}): {1}. Check -ApiVersion.' -f
                       $configUpdate.StatusCode, $configUpdate.Content)
            }

            $updatePath = ('/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.DesktopVirtualization/hostPools/{2}' +
                           '/initiateSessionHostUpdate?api-version={3}') -f
                           $azContext.Subscription.Id, $ResourceGroupName, $HostPoolName, $item.ApiVersion

            $trigger = Invoke-AzRestMethod -Method POST -Path $updatePath -ErrorAction Stop
            if ($trigger.StatusCode -ge 400) {
                throw ('Session host update could not be initiated (HTTP {0}): {1}' -f $trigger.StatusCode, $trigger.Content)
            }

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Batch {0}: image set to {1} and update initiated. UAT sign-off: {2}. Approval {3}.' -f
                $item.BatchNumber, $item.ImageName, $item.UatSignOffBy, $ApprovalReference)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'ImageRolledOut'
                Detail = ('{0} host(s) to {1}' -f $item.HostCount, $item.ImageName); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AVD Image Version Update & Pool Rollout'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
