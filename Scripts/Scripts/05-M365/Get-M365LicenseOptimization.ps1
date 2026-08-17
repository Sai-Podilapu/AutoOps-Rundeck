<#
.SYNOPSIS
    Reports unassigned and under-used Microsoft 365 licences.

.DESCRIPTION
    Cross-references purchased licence counts against assignments and sign-in
    activity, identifying unassigned seats and licences held by dormant
    accounts. Both cost money; the second is also a security finding, since a
    dormant licensed account is a live target.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER DormantDays
    Treat an account with no sign-in for this long as dormant.

.PARAMETER EstimatedCostPerSeat
    Optional monthly cost per seat, used to quantify the finding.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-M365LicenseOptimization.ps1 -DormantDays 90 -OutputFormat HTML

    Optimisation report as HTML.

.EXAMPLE
    .\Get-M365LicenseOptimization.ps1 -EstimatedCostPerSeat @{ENTERPRISEPACK=23}

    Quantifies waste for one SKU.

.NOTES
    Source use case      : #9 - M365 License Optimization Report
    Category             : M365
    Technology           : Graph API / License API
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Identify unassigned/underused licenses"

    Required permissions : Microsoft Graph Organization.Read.All, User.Read.All and AuditLog.Read.All.
    Required modules     : Microsoft.Graph.Authentication, Microsoft.Graph.Users
    Authentication       : App registration with certificate auth (app-only).

    Sign-in activity needs Entra ID P1 or above. Without it,
    lastSignInDateTime is null for every user and no account can be
    classified as dormant - the script reports that explicitly rather than
    reporting everyone as dormant.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication
#Requires -Modules Microsoft.Graph.Users

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [ValidateRange(1,3650)]
    [int]$DormantDays = 60,

    [hashtable]$EstimatedCostPerSeat = @{},

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-M365LicenseOptimization'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #9 (M365)'

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
        Connect-AutomationPlatform -Platform 'Graph' | Out-Null


        Connect-MgGraph -Scopes 'Organization.Read.All','User.Read.All','AuditLog.Read.All' -NoWelcome -ErrorAction Stop
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Microsoft Graph'

        $skus = Get-MgSubscribedSku -All -ErrorAction Stop
        $cutoff = (Get-Date).AddDays(-$DormantDays)
        $noActivityData = 0

        # --- unassigned seats -----------------------------------------------------
        foreach ($sku in $skus) {
            $unassigned = $sku.PrepaidUnits.Enabled - $sku.ConsumedUnits
            if ($unassigned -le 0) { continue }

            $cost = if ($EstimatedCostPerSeat.ContainsKey($sku.SkuPartNumber)) {
                        [double]$EstimatedCostPerSeat[$sku.SkuPartNumber] } else { $null }

            $results.Add([PSCustomObject]@{
                Name        = $sku.SkuPartNumber
                Id          = $sku.SkuId
                Finding     = 'Unassigned seats'
                SkuPartNumber = $sku.SkuPartNumber
                Purchased   = $sku.PrepaidUnits.Enabled
                Assigned    = $sku.ConsumedUnits
                Unassigned  = $unassigned
                UserPrincipalName = $null
                LastSignIn  = $null
                EstMonthlyWaste = if ($null -ne $cost) { [math]::Round($unassigned * $cost, 2) } else { $null }
                Recommendation = 'Reduce the subscription count, or assign the spare seats'
            })
        }

        # --- licences on dormant accounts ----------------------------------------
        $users = Get-MgUser -Filter 'assignedLicenses/$count ne 0' -ConsistencyLevel eventual -CountVariable c -All `
            -Property Id,UserPrincipalName,DisplayName,AssignedLicenses,SignInActivity,AccountEnabled -ErrorAction Stop

        foreach ($u in $users) {
            $lastSignIn = $u.SignInActivity.LastSignInDateTime
            if (-not $lastSignIn) { $noActivityData++; continue }   # unknown is not dormant
            if ($lastSignIn -ge $cutoff) { continue }

            foreach ($lic in $u.AssignedLicenses) {
                $sku = $skus | Where-Object SkuId -eq $lic.SkuId | Select-Object -First 1
                if (-not $sku) { continue }
                $cost = if ($EstimatedCostPerSeat.ContainsKey($sku.SkuPartNumber)) {
                            [double]$EstimatedCostPerSeat[$sku.SkuPartNumber] } else { $null }

                $results.Add([PSCustomObject]@{
                    Name        = $u.UserPrincipalName
                    Id          = $u.Id
                    Finding     = 'Licence on a dormant account'
                    SkuPartNumber = $sku.SkuPartNumber
                    Purchased   = $null
                    Assigned    = $null
                    Unassigned  = $null
                    UserPrincipalName = $u.UserPrincipalName
                    AccountEnabled = $u.AccountEnabled
                    LastSignIn  = $lastSignIn
                    DormantDays = [math]::Round(((Get-Date) - $lastSignIn).TotalDays, 0)
                    EstMonthlyWaste = $cost
                    Recommendation = 'Confirm the account is still needed; if it is a leaver, offboard and reclaim the licence'
                })
            }
        }

        if ($noActivityData -gt 0) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                '{0} licensed user(s) have no sign-in activity data and were NOT classified as dormant. ' +
                'This usually means the tenant lacks Entra ID P1.' -f $noActivityData)
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'M365 License Optimization Report'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
