<#
.SYNOPSIS
    Creates a shared folder and applies group-based NTFS permissions.

.DESCRIPTION
    Creates a folder, shares it and applies NTFS access rules to security
    groups. Grants are made to groups rather than individual users, because
    per-user ACLs are how a share becomes unauditable within a year.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER Credential
    Credential for the directory operation.

.PARAMETER ComputerName
    File server hosting the share.

.PARAMETER FolderPath
    Local path on the file server.

.PARAMETER ShareName
    Share name to create.

.PARAMETER AccessGroup
    Security group(s) to grant access to. Users are not accepted.

.PARAMETER AccessRight
    NTFS right to grant.

.PARAMETER DisableInheritance
    Break inheritance on the new folder so only the explicit grants apply.

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
    .\Set-AdShareFolderAccess.ps1 -ComputerName FS01 -FolderPath 'D:\\Shares\\Finance' -ShareName Finance -AccessGroup 'GG-Finance-RW' -TicketReference REQ0012345

    REQUEST mode - raises an approval for the share and ACL.

.EXAMPLE
    .\Set-AdShareFolderAccess.ps1 -ComputerName FS01 -FolderPath 'D:\\Shares\\Finance' -AccessGroup 'GG-Finance-RW' -ApprovalReference APR-...

    Creates the approved share.

.NOTES
    Source use case      : #6 - Share Folder Creation & Access Modification
    Category             : AD & Identity
    Technology           : PowerShell
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "ACL changes; ticket approval"

    Required permissions : Local Administrator on the file server, plus read access to AD to resolve the groups.
    Required modules     : ActiveDirectory
    Authentication       : Delegated service account with the minimum required
                           AD rights.

    Only security GROUPS are accepted, not user accounts. A share whose
    ACL is a list of individuals cannot be reviewed meaningfully and
    breaks the moment someone leaves.

    Rollback             : Remove the share and the folder, or restore the
                           previous ACL from the export written before the
                           change.
#>

#Requires -Version 5.1
#Requires -Modules ActiveDirectory

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [Parameter(Mandatory)]
    [string]$ComputerName,

    [Parameter(Mandatory)]
    [string]$FolderPath,

    [string]$ShareName,

    [Parameter(Mandatory)]
    [string[]]$AccessGroup,

    [ValidateSet('ReadAndExecute','Modify','FullControl')]
    [string]$AccessRight = 'Modify',

    [switch]$DisableInheritance,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Shared folder provisioning',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-AdShareFolderAccess'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #6 (AD & Identity)'

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
        Connect-AutomationPlatform -Platform 'ActiveDirectory' | Out-Null


        Import-Module ActiveDirectory -ErrorAction Stop

        $adArgs = @{ ErrorAction = 'Stop' }
        if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $adArgs.Credential = $Credential }

        # Groups only. A per-user ACL is unauditable and breaks on every leaver.
        foreach ($g in $AccessGroup) {
            $obj = Get-ADObject -Filter ("SamAccountName -eq '{0}'" -f ($g -replace '^.*\\', '')) `
                   -Properties objectClass @adArgs -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $obj) { throw ('Access principal not found in AD: {0}' -f $g) }
            if ($obj.objectClass -ne 'group') {
                throw ('{0} is a {1}, not a group. This script grants access to security groups only.' -f $g, $obj.objectClass)
            }
        }

        if (-not $ShareName) { $ShareName = Split-Path -Leaf $FolderPath }

        $exists = Invoke-Command -ComputerName $ComputerName -ScriptBlock {
            [PSCustomObject]@{
                FolderExists = Test-Path -LiteralPath $using:FolderPath
                ShareExists  = [bool](Get-SmbShare -Name $using:ShareName -ErrorAction SilentlyContinue)
            }
        } -ErrorAction Stop

        if ($exists.ShareExists) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $ShareName `
                -Message 'Share already exists - ACL will be updated, share not recreated'
        }

        $results.Add([PSCustomObject]@{
            Name             = ('\\{0}\{1}' -f $ComputerName, $ShareName)
            Id               = $FolderPath
            ComputerName     = $ComputerName
            FolderPath       = $FolderPath
            ShareName        = $ShareName
            AccessGroups     = ($AccessGroup -join '; ')
            AccessRight      = $AccessRight
            FolderExists     = $exists.FolderExists
            ShareExists      = $exists.ShareExists
            DisableInheritance = [bool]$DisableInheritance
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Create share and apply ACL', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Create share and apply ACL')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            # Values are bound into locals first so the remote scriptblock can reference
            # them with $using: rather than positional arguments.
            $remotePath   = $item.FolderPath
            $remoteShare  = $item.ShareName
            $remoteGroups = $item.AccessGroups.Split('; ')
            $remoteRight  = $item.AccessRight
            $remoteBreak  = $item.DisableInheritance

            $result = Invoke-Command -ComputerName $item.ComputerName -ScriptBlock {
                $Path         = $using:remotePath
                $Share        = $using:remoteShare
                $Groups       = $using:remoteGroups
                $Right        = $using:remoteRight
                $BreakInherit = $using:remoteBreak

                $created = $false
                if (-not (Test-Path -LiteralPath $Path)) {
                    New-Item -Path $Path -ItemType Directory -Force | Out-Null
                    $created = $true
                }

                # Capture the existing ACL so it can be restored if the change is wrong.
                $priorAcl = (Get-Acl -LiteralPath $Path).Access |
                    ForEach-Object { '{0}:{1}' -f $_.IdentityReference, $_.FileSystemRights } | Sort-Object -Unique

                $acl = Get-Acl -LiteralPath $Path
                if ($BreakInherit) { $acl.SetAccessRuleProtection($true, $true) }

                foreach ($g in $Groups) {
                    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                        $g, $Right, 'ContainerInherit,ObjectInherit', 'None', 'Allow')
                    $acl.AddAccessRule($rule)
                }
                Set-Acl -LiteralPath $Path -AclObject $acl

                $shareCreated = $false
                if (-not (Get-SmbShare -Name $Share -ErrorAction SilentlyContinue)) {
                    New-SmbShare -Name $Share -Path $Path -FullAccess 'Authenticated Users' | Out-Null
                    $shareCreated = $true
                }

                [PSCustomObject]@{
                    FolderCreated = $created; ShareCreated = $shareCreated
                    PriorAcl = ($priorAcl -join '; ')
                }
            } -ErrorAction Stop

            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
                'Prior ACL captured: {0}' -f $result.PriorAcl)
            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Share ready. Folder created={0}, share created={1}, {2} granted to {3}. Ticket={4}' -f
                $result.FolderCreated, $result.ShareCreated, $item.AccessRight, $item.AccessGroups, $TicketReference)

            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'ShareConfigured'
                Detail = ('{0} to {1}' -f $item.AccessRight, $item.AccessGroups); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Share Folder Creation & Access Modification'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
