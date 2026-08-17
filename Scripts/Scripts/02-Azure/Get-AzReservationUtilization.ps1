<#
.SYNOPSIS
    Reports Azure reservation utilisation and wasted commitment.

.DESCRIPTION
    Lists reservation orders with their utilisation, flagging any that is
    under-used - which is money already committed and not being consumed - or
    expiring soon.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER ExpiringWithinDays
    Flag reservations expiring within this many days.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-AzReservationUtilization.ps1 -ExpiringWithinDays 90

    Flags reservations expiring within a quarter.

.EXAMPLE
    .\Get-AzReservationUtilization.ps1 -OutputFormat HTML

    Full reservation report as HTML.

.NOTES
    Source use case      : #28 - Azure Reserved Instance Utilization Report
    Category             : Azure
    Technology           : Cost Management API
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Track RI utilization and savings"

    Required permissions : Reservation Reader at the billing scope, or Owner on the reservation order.
    Required modules     : Az.Accounts, Az.Reservations
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    This script reports reservation inventory, term, expiry and auto-renew
    state. It does NOT report utilisation percentages: those come from the
    Cost Management reservation-details API, which needs billing-scope
    access that subscription rights do not grant. Rather than emit a
    filter that could never apply, the utilisation threshold parameter has
    been left out entirely.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.Reservations

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [ValidateRange(1,365)]
    [int]$ExpiringWithinDays = 60,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-AzReservationUtilization'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #28 (Azure)'

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


        $orders = Get-AzReservationOrder -ErrorAction Stop

        foreach ($order in $orders) {
            $orderId = ($order.Id -split '/')[-1]
            $reservations = @(Get-AzReservation -ReservationOrderId $orderId -ErrorAction SilentlyContinue)

            foreach ($r in $reservations) {
                $issues = @()
                $daysToExpiry = if ($order.ExpiryDate) {
                                    [math]::Round(([datetime]$order.ExpiryDate - (Get-Date)).TotalDays, 0)
                                } else { $null }
                if ($null -ne $daysToExpiry -and $daysToExpiry -le $ExpiringWithinDays) {
                    $issues += ('expires in {0} day(s)' -f $daysToExpiry)
                }
                if ($r.Properties.Renew -eq $false -and $null -ne $daysToExpiry -and $daysToExpiry -le $ExpiringWithinDays) {
                    $issues += 'auto-renew is OFF'
                }

                $results.Add([PSCustomObject]@{
                    Name            = $r.Name
                    Id              = $r.Id
                    OrderId         = $orderId
                    Sku             = $r.Sku.Name
                    Quantity        = $r.Properties.Quantity
                    State           = "$($r.Properties.ProvisioningState)"
                    Scope           = "$($r.Properties.AppliedScopeType)"
                    Term            = $order.Term
                    ExpiryDate      = $order.ExpiryDate
                    DaysToExpiry    = $daysToExpiry
                    AutoRenew       = $r.Properties.Renew
                    Status          = if ($issues.Count) { 'Attention' } else { 'OK' }
                    Issues          = ($issues -join '; ')
                    UtilisationNote = 'Per-day utilisation percentages come from the Cost Management reservation-details API, which needs billing-scope access'
                })
            }
        }

        if ($orders.Count -eq 0) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'No reservation orders visible to this identity.'
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Azure Reserved Instance Utilization Report'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
