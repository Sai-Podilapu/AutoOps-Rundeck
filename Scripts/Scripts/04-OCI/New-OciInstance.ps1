<#
.SYNOPSIS
    Provisions OCI compute instances from an approved shape and image.

.DESCRIPTION
    Launches compute instances after a human has approved the shape and image.
    The change set names the shape, its OCPU and memory allocation, and the
    image, because those are what determine the bill and are what the
    guardrail asks an approver to look at.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER CompartmentId
    Compartment OCID to operate in. Falls back to oci.defaultCompartmentId in
    config.json.

.PARAMETER Region
    OCI region identifier, e.g. me-dubai-1. Falls back to oci.defaultRegion in
    config.json, then to the region in the CLI profile.

.PARAMETER CliProfile
    Named profile in the OCI CLI config file. Not called -Profile because
    $Profile is a PowerShell automatic variable.

.PARAMETER CliConfigFile
    Path to the OCI CLI config file. The CLI default (~/.oci/config) is used
    when omitted.

.PARAMETER OciCliPath
    Full path to the oci executable. Resolved from PATH when omitted.

.PARAMETER DisplayName
    Display name(s) for the new instance(s).

.PARAMETER Shape
    Compute shape, e.g. VM.Standard.E4.Flex.

.PARAMETER ImageId
    Image OCID to launch from.

.PARAMETER SubnetId
    Subnet OCID to attach the primary VNIC to.

.PARAMETER AvailabilityDomain
    Availability domain. The first in the compartment when omitted.

.PARAMETER Ocpus
    OCPU count for a flexible shape.

.PARAMETER MemoryInGBs
    Memory in GB for a flexible shape.

.PARAMETER SshAuthorizedKeyFile
    Path to a public key file placed in the instance metadata.

.PARAMETER FreeformTag
    Freeform tags applied at launch, as key=value pairs.

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
    .\New-OciInstance.ps1 -DisplayName APP03 -Shape VM.Standard.E4.Flex -Ocpus 2 -MemoryInGBs 32 -ImageId ocid1.image... -SubnetId ocid1.subnet...

    REPORT ONLY. Builds the launch request and raises an approval.

.EXAMPLE
    .\New-OciInstance.ps1 -DisplayName APP03 -Shape VM.Standard.E4.Flex -ImageId ocid1.image... -SubnetId ocid1.subnet... -ApprovalReference APR-...

    Launches an approved instance.

.NOTES
    Source use case      : #2 - OCI Instance Provisioning
    Category             : OCI
    Technology           : Terraform / OCI CLI
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "Cost impact; approve shape/image before deploy"

    Required permissions : An IAM policy allowing INSTANCE_CREATE, plus USE on the subnet and READ on the image.
    Required modules     : none beyond IT-Automation-Common
    Authentication       : OCI CLI config profile. NOTE: there is no
                           first-party OCI PowerShell module - this wraps the
                           OCI CLI.

    COST IMPACT. This script reports the shape, OCPU and memory being
    requested so an approver can price it against their own rate card. It
    does NOT compute or estimate a cost figure - OCI pricing depends on
    the tenancy agreement and there is no API here that would make such a
    number true. An invented estimate on an approval artifact would be
    worse than none.

    Rollback             : Terminate the instance. Terminating within the first
                           hour still incurs the minimum billing increment for
                           the shape.
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$CompartmentId,

    [string]$Region,

    [string]$CliProfile,

    [string]$CliConfigFile,

    [string]$OciCliPath,

    [Parameter(Mandatory)]
    [string[]]$DisplayName,

    [Parameter(Mandatory)]
    [string]$Shape,

    [Parameter(Mandatory)]
    [string]$ImageId,

    [Parameter(Mandatory)]
    [string]$SubnetId,

    [string]$AvailabilityDomain,

    [ValidateRange(1,128)]
    [int]$Ocpus = 1,

    [ValidateRange(1,2048)]
    [int]$MemoryInGBs = 16,

    [string]$SshAuthorizedKeyFile,

    [string[]]$FreeformTag,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Approved compute provisioning',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'New-OciInstance'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #2 (OCI)'

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
        Connect-AutomationPlatform -Platform 'OCI' | Out-Null


        function Invoke-OciCli {
            <#
                .SYNOPSIS
                    Runs one oci CLI command and returns its parsed JSON output.
                .DESCRIPTION
                    Appends the profile, config file, region and --output json, runs the
                    CLI, and throws on a non-zero exit code. Defined inside the script
                    rather than in the shared module because it depends on this run's
                    resolved CLI path and profile.
            #>
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)]
                [string[]]$Argument,

                [switch]$Raw
            )

            $cliArgs = @($Argument)
            if ($ociProfile)    { $cliArgs += @('--profile', $ociProfile) }
            if ($ociConfigFile) { $cliArgs += @('--config-file', $ociConfigFile) }
            if ($Region)        { $cliArgs += @('--region', $Region) }
            $cliArgs += @('--output', 'json')

            $errFile = [System.IO.Path]::GetTempFileName()
            $previousPreference = $ErrorActionPreference
            # Windows PowerShell turns redirected native stderr into terminating errors
            # under 'Stop', even when the process exits 0. The exit code is the signal
            # that actually matters, so the preference is relaxed for the call only.
            $ErrorActionPreference = 'Continue'
            $exitCode = 0
            try {
                $stdout = & $ociCli @cliArgs 2>$errFile
                $exitCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $previousPreference
            }

            $stderrText = ''
            if (Test-Path -LiteralPath $errFile) {
                $stderrText = "$(Get-Content -LiteralPath $errFile -Raw)"
                Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
            }

            if ($exitCode -ne 0) {
                # Redacted on the way into the log by Write-AutomationLog.
                throw ('oci {0} failed (exit {1}): {2}' -f ($Argument -join ' '), $exitCode, $stderrText.Trim())
            }

            $text = (@($stdout) -join "`n").Trim()
            if ($Raw) { return $text }
            if (-not $text) { return $null }
            try {
                return ($text | ConvertFrom-Json)
            } catch {
                throw ('oci {0} returned output that is not JSON: {1}' -f ($Argument -join ' '),
                       $text.Substring(0, [math]::Min(200, $text.Length)))
            }
        }

        $ociCli = if ($OciCliPath) { $OciCliPath } else { 'oci' }
        $resolvedCli = Get-Command -Name $ociCli -ErrorAction SilentlyContinue
        if (-not $resolvedCli) {
            throw ('The OCI CLI was not found ("{0}"). Install it and ensure it is on PATH, or pass ' +
                   '-OciCliPath. There is no first-party OCI PowerShell module; this script wraps the CLI.' -f $ociCli)
        }
        $ociCli = $resolvedCli.Source

        $ociProfile = $CliProfile
        $ociConfigFile = $CliConfigFile
        if ($config -and $config.oci) {
            if (-not $ociProfile -and $config.oci.profileName)          { $ociProfile = $config.oci.profileName }
            if (-not $Region -and $config.oci.defaultRegion)            { $Region = $config.oci.defaultRegion }
            if (-not $CompartmentId -and $config.oci.defaultCompartmentId) { $CompartmentId = $config.oci.defaultCompartmentId }
        }

        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Using OCI CLI at {0}{1}{2}' -f $ociCli,
            $(if ($ociProfile) { ", profile '$ociProfile'" } else { ', default profile' }),
            $(if ($Region) { ", region '$Region'" } else { ', region from profile' }))

        if (-not $CompartmentId) {
            throw 'No compartment. Pass -CompartmentId or set oci.defaultCompartmentId in config.json.'
        }

        if (-not $AvailabilityDomain) {
            $ads = Invoke-OciCli -Argument @('iam', 'availability-domain', 'list', '--compartment-id', $CompartmentId)
            $AvailabilityDomain = @($ads.data)[0].name
            if (-not $AvailabilityDomain) { throw 'Could not resolve an availability domain in this compartment.' }
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
                'Availability domain not supplied; using {0}' -f $AvailabilityDomain)
        }

        # Confirm the image and shape exist before an approver is asked about them.
        $image = Invoke-OciCli -Argument @('compute', 'image', 'get', '--image-id', $ImageId)
        if (-not $image.data) { throw ('Image {0} not found.' -f $ImageId) }

        $shapeInfo = $null
        try {
            $shapes = Invoke-OciCli -Argument @('compute', 'shape', 'list', '--compartment-id', $CompartmentId, '--all')
            $shapeInfo = @($shapes.data) | Where-Object { $_.shape -eq $Shape } | Select-Object -First 1
        } catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'Shape list unavailable ({0}); proceeding with the shape as given.' -f $_.Exception.Message)
        }
        if ($shapes -and -not $shapeInfo) {
            throw ('Shape "{0}" is not available in this compartment.' -f $Shape)
        }

        $isFlex = $Shape -match '(?i)\.Flex$'

        $existing = @()
        try {
            $listed = Invoke-OciCli -Argument @('compute', 'instance', 'list', '--compartment-id', $CompartmentId, '--all')
            $existing = @($listed.data | Where-Object { "$($_.'lifecycle-state')" -notmatch '(?i)terminat' })
        } catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message 'Could not list existing instances; duplicate-name check skipped.'
        }

        foreach ($dn in $DisplayName) {
            if ($existing.'display-name' -contains $dn) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $dn `
                    -Message 'Skipped - an instance with this display name already exists (idempotent)'
                continue
            }

            $results.Add([PSCustomObject]@{
                Name        = $dn
                Id          = $dn
                DisplayName = $dn
                Shape       = $Shape
                IsFlexShape = $isFlex
                Ocpus       = if ($isFlex) { $Ocpus } else { $shapeInfo.ocpus }
                MemoryInGBs = if ($isFlex) { $MemoryInGBs } else { $shapeInfo.'memory-in-gbs' }
                ImageId     = $ImageId
                ImageName   = $image.data.'display-name'
                OperatingSystem = ('{0} {1}' -f $image.data.'operating-system', $image.data.'operating-system-version')
                SubnetId    = $SubnetId
                AvailabilityDomain = $AvailabilityDomain
                CostNote    = 'Cost NOT calculated - price the shape above against your own rate card'
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Launch instance', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Launch instance')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $launchArgs = @('compute', 'instance', 'launch',
                '--compartment-id', $CompartmentId,
                '--availability-domain', $item.AvailabilityDomain,
                '--display-name', $item.DisplayName,
                '--shape', $item.Shape,
                '--image-id', $item.ImageId,
                '--subnet-id', $item.SubnetId,
                '--wait-for-state', 'RUNNING')

            if ($item.IsFlexShape) {
                $launchArgs += @('--shape-config',
                    (@{ ocpus = $item.Ocpus; memoryInGBs = $item.MemoryInGBs } | ConvertTo-Json -Compress))
            }

            $metadata = @{}
            if ($SshAuthorizedKeyFile) {
                if (-not (Test-Path -LiteralPath $SshAuthorizedKeyFile)) {
                    throw ('SSH public key file not found: {0}' -f $SshAuthorizedKeyFile)
                }
                $metadata['ssh_authorized_keys'] = (Get-Content -LiteralPath $SshAuthorizedKeyFile -Raw).Trim()
            }
            if ($metadata.Count -gt 0) {
                $launchArgs += @('--metadata', ($metadata | ConvertTo-Json -Compress))
            }

            if ($FreeformTag) {
                $tagMap = @{}
                foreach ($pair in $FreeformTag) {
                    $kv = $pair -split '=', 2
                    if ($kv.Count -eq 2) { $tagMap[$kv[0]] = $kv[1] }
                }
                if ($tagMap.Count -gt 0) {
                    $launchArgs += @('--freeform-tags', ($tagMap | ConvertTo-Json -Compress))
                }
            }

            $launched = Invoke-OciCli -Argument $launchArgs

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Instance launched: {0}, shape {1} ({2} OCPU / {3} GB), image {4}' -f
                $launched.data.id, $item.Shape, $item.Ocpus, $item.MemoryInGBs, $item.ImageName)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'Launched'
                Detail = ('{0}, {1}' -f $launched.data.id, $item.Shape); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'OCI Instance Provisioning'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
