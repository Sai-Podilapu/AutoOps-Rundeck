<#
.SYNOPSIS
    Performs a point-in-time restore of an Azure SQL database to an isolated
    test target.

.DESCRIPTION
    Restores a database to a NEW, separately-named target so the production
    database is never touched. The target name is derived from a fixed prefix,
    and the script refuses if the resulting name would collide with an
    existing database - which is what keeps a restore test from becoming an
    outage.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER SubscriptionId
    Subscription to operate in. Falls back to azure.defaultSubscriptionId in
    config.json.

.PARAMETER ServerName
    Azure SQL logical server.

.PARAMETER SourceDatabaseName
    Database to restore from.

.PARAMETER SqlResourceGroup
    Resource group containing the SQL server.

.PARAMETER RestoreTargetPrefix
    Prefix for the restored copy. The fixed prefix is what keeps the restore
    isolated.

.PARAMETER PointInTimeMinutesAgo
    How far back to restore from.

.PARAMETER RemoveAfterMinutes
    Delete the restored copy after this many minutes. 0 keeps it.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Test-AzSqlDatabaseRestore.ps1 -ServerName sql-prod -SqlResourceGroup rg-sql -SourceDatabaseName appdb

    Restores appdb to restoretest-appdb-<timestamp>.

.EXAMPLE
    .\Test-AzSqlDatabaseRestore.ps1 -ServerName sql-prod -SqlResourceGroup rg-sql -SourceDatabaseName appdb -RemoveAfterMinutes 60

    Restores, then deletes the copy an hour later.

.NOTES
    Source use case      : #23 - Azure SQL Database Backup Restore Test
    Category             : Azure
    Technology           : Az CLI / SQL API
    Difficulty           : Medium
    Agent possible       : Yes - with Human Approval
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Restore to isolated test target; safe when SOP fixes target naming"

    Required permissions : SQL DB Contributor on the server.
    Required modules     : Az.Accounts, Az.Sql
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    A restored database bills as a full database from the moment it
    exists. Use -RemoveAfterMinutes, or clean it up manually, or the
    restore test quietly becomes a recurring cost.

    Rollback             : Delete the restored copy. The source database is
                           never modified, so there is nothing to roll back on
                           it.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.Sql

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ServerName,

    [Parameter(Mandatory)]
    [string[]]$SourceDatabaseName,

    [Parameter(Mandatory)]
    [string]$SqlResourceGroup,

    [ValidateNotNullOrEmpty()]
    [string]$RestoreTargetPrefix = 'restoretest-',

    [ValidateRange(10,43200)]
    [int]$PointInTimeMinutesAgo = 60,

    [ValidateRange(0,10080)]
    [int]$RemoveAfterMinutes = 0,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Test-AzSqlDatabaseRestore'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #23 (Azure)'

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

        # Existence check only - throws if the server is wrong, which is the point.
        Get-AzSqlServer -ResourceGroupName $SqlResourceGroup -ServerName $ServerName -ErrorAction Stop | Out-Null
        $restorePoint = (Get-Date).AddMinutes(-$PointInTimeMinutesAgo)

        foreach ($dbName in $SourceDatabaseName) {
            $db = Get-AzSqlDatabase -ResourceGroupName $SqlResourceGroup -ServerName $ServerName `
                    -DatabaseName $dbName -ErrorAction Stop

            if ($db.EarliestRestoreDate -and $restorePoint -lt $db.EarliestRestoreDate) {
                throw ('Requested restore point {0:u} is before the earliest available {1:u} for {2}.' -f
                       $restorePoint, $db.EarliestRestoreDate, $dbName)
            }

            $targetName = ('{0}{1}-{2}' -f $RestoreTargetPrefix, $dbName, (Get-Date -Format 'yyyyMMdd-HHmm'))

            # The isolation guarantee: never restore onto an existing database.
            if (Get-AzSqlDatabase -ResourceGroupName $SqlResourceGroup -ServerName $ServerName `
                    -DatabaseName $targetName -ErrorAction SilentlyContinue) {
                throw ('Refusing: target database {0} already exists.' -f $targetName)
            }
            if ($targetName -eq $dbName) {
                throw 'Refusing: the restore target name matches the source. Check -RestoreTargetPrefix.'
            }

            $results.Add([PSCustomObject]@{
                Name              = $dbName
                Id                = $db.ResourceId
                ServerName        = $ServerName
                ResourceGroup     = $SqlResourceGroup
                SourceDatabase    = $dbName
                TargetDatabase    = $targetName
                RestorePoint      = $restorePoint
                EarliestRestore   = $db.EarliestRestoreDate
                SourceEdition     = $db.Edition
                SourceServiceObjective = $db.CurrentServiceObjectiveName
                RemoveAfterMinutes= $RemoveAfterMinutes
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Restore database to test target')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            Restore-AzSqlDatabase -FromPointInTimeBackup -PointInTime $item.RestorePoint `
                -ResourceGroupName $item.ResourceGroup -ServerName $item.ServerName `
                -TargetDatabaseName $item.TargetDatabase -ResourceId $item.Id -ErrorAction Stop | Out-Null

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Restored {0} to {1} at point-in-time {2:u}. Source untouched.' -f
                $item.SourceDatabase, $item.TargetDatabase, $item.RestorePoint)

            if ($item.RemoveAfterMinutes -gt 0) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
                    'Waiting {0} minute(s) before removing the test copy' -f $item.RemoveAfterMinutes)
                Start-Sleep -Seconds ($item.RemoveAfterMinutes * 60)
                Remove-AzSqlDatabase -ResourceGroupName $item.ResourceGroup -ServerName $item.ServerName `
                    -DatabaseName $item.TargetDatabase -Force -ErrorAction Stop | Out-Null
                Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                    'Test copy {0} removed' -f $item.TargetDatabase)
            }

            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'Restored'
                Detail = ('-> {0}' -f $item.TargetDatabase); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Azure SQL Database Backup Restore Test'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
