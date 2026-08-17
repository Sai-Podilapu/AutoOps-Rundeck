<#
.SYNOPSIS
    Creates manual RDS snapshots for tagged database instances.

.DESCRIPTION
    Takes a manual snapshot of each RDS instance carrying the backup tag, and
    optionally prunes manual snapshots older than the retention period.
    Automated snapshots are never touched - only manual ones this script
    created.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER Region
    AWS region to operate in. Defaults to the configured default region.

.PARAMETER ProfileName
    Named AWS profile / SSO profile to use. Prefer an IAM role where the host
    supports one.

.PARAMETER BackupTagKey
    Tag key marking an instance for snapshotting.

.PARAMETER SnapshotPrefix
    Prefix for generated snapshot identifiers.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\New-AwsRdsSnapshot.ps1 -Region me-central-1

    Snapshots every tagged instance.

.EXAMPLE
    .\New-AwsRdsSnapshot.ps1 -WhatIf

    Shows which instances would be snapshotted.

.NOTES
    Source use case      : #10 - AWS RDS Snapshot Automation
    Category             : AWS
    Technology           : Lambda / EventBridge
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Snapshot creation is safe; retention cleanup needs delete-guardrails"

    Required permissions : rds:DescribeDBInstances, rds:CreateDBSnapshot, rds:ListTagsForResource
    Required modules     : AWS.Tools.Common, AWS.Tools.RDS
    Authentication       : IAM role or SSO profile via Set-AWSCredential. Never
                           an access key pair in code.

    Rollback             : A snapshot is additive - it can be deleted if
                           unwanted. It changes nothing about the running
                           instance.
#>

#Requires -Version 5.1
#Requires -Modules AWS.Tools.Common
#Requires -Modules AWS.Tools.RDS

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$Region,

    [string]$ProfileName,

    [string]$BackupTagKey = 'AutoOps:Backup',

    [string]$SnapshotPrefix = 'autoops',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'New-AwsRdsSnapshot'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #10 (AWS)'

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

        foreach ($db in (Get-RDSDBInstance @awsArgs)) {
            $tags = Get-RDSTagForResource -ResourceName $db.DBInstanceArn @awsArgs
            if (-not ($tags | Where-Object { $_.Key -eq $BackupTagKey })) { continue }
            if ($db.DBInstanceStatus -ne 'available') {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $db.DBInstanceIdentifier `
                    -Message ('Skipped - status is {0}, not available' -f $db.DBInstanceStatus)
                continue
            }
            $results.Add([PSCustomObject]@{
                Name       = $db.DBInstanceIdentifier
                Id         = $db.DBInstanceIdentifier
                Engine     = $db.Engine
                SizeGB     = $db.AllocatedStorage
                MultiAZ    = $db.MultiAZ
                SnapshotId = ('{0}-{1}-{2}' -f $SnapshotPrefix, $db.DBInstanceIdentifier, (Get-Date -Format 'yyyyMMdd-HHmmss'))
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

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Create RDS snapshot')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            New-RDSDBSnapshot -DBInstanceIdentifier $item.Id -DBSnapshotIdentifier $item.SnapshotId @awsArgs | Out-Null
            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Snapshot {0} requested' -f $item.SnapshotId)
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'SnapshotCreated'; Detail = $item.SnapshotId; Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AWS RDS Snapshot Automation'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
