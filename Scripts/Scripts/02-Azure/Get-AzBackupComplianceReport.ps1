<#
.SYNOPSIS
    Reports which Azure VMs are protected by a backup policy and which are
    not.

.DESCRIPTION
    Cross-references every VM against Recovery Services vault protection,
    reporting unprotected VMs and any protected item whose last backup failed
    or is stale. An unprotected production VM is the finding this exists to
    surface.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER SubscriptionId
    Subscription to operate in. Falls back to azure.defaultSubscriptionId in
    config.json.

.PARAMETER ResourceGroupName
    Limit to specific resource groups.

.PARAMETER StaleBackupHours
    Flag a protected item whose last successful backup is older than this.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-AzBackupComplianceReport.ps1 -OutputFormat HTML

    Backup compliance across the subscription.

.EXAMPLE
    .\Get-AzBackupComplianceReport.ps1 -StaleBackupHours 24 -OutputFormat CSV

    Tighter staleness threshold, as CSV.

.NOTES
    Source use case      : #18 - Azure Backup Policy Compliance Report
    Category             : Azure
    Technology           : Az Backup / PowerShell
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Verify all VMs have backup policy"

    Required permissions : Reader plus Backup Reader on the subscription.
    Required modules     : Az.Accounts, Az.Compute, Az.RecoveryServices
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.Compute
#Requires -Modules Az.RecoveryServices

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [string[]]$ResourceGroupName,

    [ValidateRange(1,8760)]
    [int]$StaleBackupHours = 36,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-AzBackupComplianceReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #18 (Azure)'

    try {
        $config = if ($ConfigPath) { Get-AutomationConfig -Path $ConfigPath } else { Get-AutomationConfig }
        # Recorded so an audit can tell which environment a run targeted.
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Configuration loaded for environment: {0}' -f $config.environment)
    } catch {
        # Read-only: config only supplies optional notification endpoints,
        # so its absence must not stop a report from being produced.
        $config = $null
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
            'Config unavailable ({0}); continuing because this script only reads.' -f $_.Exception.Message)
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

        $vms = if ($ResourceGroupName) { $ResourceGroupName | ForEach-Object { Get-AzVM -ResourceGroupName $_ } }
               else                    { Get-AzVM }

        # Build the protected set once rather than querying per VM.
        $protected = @{}
        foreach ($vault in (Get-AzRecoveryServicesVault)) {
            Set-AzRecoveryServicesVaultContext -Vault $vault -ErrorAction SilentlyContinue
            try {
                $containers = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM -Status Registered -ErrorAction Stop
                foreach ($c in $containers) {
                    $items = Get-AzRecoveryServicesBackupItem -Container $c -WorkloadType AzureVM -ErrorAction SilentlyContinue
                    foreach ($i in $items) {
                        $vmShort = ($i.VirtualMachineId -split '/')[-1]
                        $protected[$vmShort] = [PSCustomObject]@{
                            Vault = $vault.Name; Policy = $i.ProtectionPolicyName
                            Status = $i.ProtectionStatus; State = $i.ProtectionState
                            LastBackup = $i.LastBackupTime; LastBackupStatus = $i.LastBackupStatus
                        }
                    }
                }
            } catch {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $vault.Name `
                    -Message ('Could not enumerate backup items: {0}' -f $_.Exception.Message)
            }
        }

        foreach ($vm in $vms) {
            $p = $protected[$vm.Name]
            $issues = @()
            if (-not $p) {
                $issues += 'NOT PROTECTED'
            } else {
                if ($p.LastBackupStatus -and $p.LastBackupStatus -ne 'Completed') { $issues += ('last backup {0}' -f $p.LastBackupStatus) }
                if ($p.LastBackup) {
                    $ageH = [math]::Round(((Get-Date) - $p.LastBackup).TotalHours, 1)
                    if ($ageH -gt $StaleBackupHours) { $issues += ('last backup {0}h ago' -f $ageH) }
                } else {
                    $issues += 'no successful backup recorded'
                }
            }

            $results.Add([PSCustomObject]@{
                Name             = $vm.Name
                Id               = $vm.Id
                ResourceGroup    = $vm.ResourceGroupName
                Location         = $vm.Location
                Protected        = [bool]$p
                Vault            = if ($p) { $p.Vault } else { $null }
                Policy           = if ($p) { $p.Policy } else { $null }
                ProtectionState  = if ($p) { "$($p.State)" } else { $null }
                LastBackup       = if ($p) { $p.LastBackup } else { $null }
                LastBackupStatus = if ($p) { "$($p.LastBackupStatus)" } else { $null }
                Status           = if ($issues.Count) { 'NonCompliant' } else { 'Compliant' }
                Issues           = ($issues -join '; ')
            })
            if ($issues.Count) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $vm.Name -Message ($issues -join '; ')
            }
        }
    } catch {
        $msg = $_.Exception.Message
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Message ('Discovery FAILED: {0}' -f $msg)
        $failures.Add([PSCustomObject]@{ Stage = 'Discovery'; Error = $msg })
    }
}

end {
    $candidates = @($results)

    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message ('Collected {0} record(s).' -f $candidates.Count)
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Azure Backup Policy Compliance Report'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
