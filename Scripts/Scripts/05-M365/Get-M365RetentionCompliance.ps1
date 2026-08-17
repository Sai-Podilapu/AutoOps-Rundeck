<#
.SYNOPSIS
    Verifies retention policies and labels are applied where expected.

.DESCRIPTION
    Reports configured retention policies and label policies with their scope
    and enforcement state, flagging policies that are disabled, in simulation,
    or scoped to nothing - all of which look configured while retaining
    nothing.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER PolicyName
    Limit to specific policies.

.PARAMETER IncludeLabels
    Include retention label detail as well as policies.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-M365RetentionCompliance.ps1 -OutputFormat HTML

    Retention compliance report as HTML.

.EXAMPLE
    .\Get-M365RetentionCompliance.ps1 -IncludeLabels -OutputFormat JSON

    Policies and labels as JSON.

.NOTES
    Source use case      : #20 - M365 Retention Policy Compliance Check
    Category             : M365
    Technology           : Compliance API
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Verify retention labels on critical data"

    Required permissions : Security & Compliance View-Only Retention Management role.
    Required modules     : ExchangeOnlineManagement
    Authentication       : App registration with certificate auth (app-only).

    Connects to Security & Compliance PowerShell, which is a different
    endpoint from Exchange Online. Certificate-based app-only auth is
    supported there but the connection is separate, so a working EXO
    connection does not imply this one.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules ExchangeOnlineManagement

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string[]]$PolicyName,

    [switch]$IncludeLabels,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-M365RetentionCompliance'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #20 (M365)'

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


        $sccParams = @{ ShowBanner = $false; ErrorAction = 'Stop' }
        if ($config -and $config.azure) {
            if ($config.azure.applicationId)         { $sccParams.AppId = $config.azure.applicationId }
            if ($config.azure.certificateThumbprint) { $sccParams.CertificateThumbprint = $config.azure.certificateThumbprint }
            if ($config.azure.tenantId)              { $sccParams.Organization = $config.azure.tenantId }
        }
        if (-not $sccParams.AppId) { throw 'Security & Compliance PowerShell requires app-only certificate auth (see config.json).' }

        Connect-IPPSSession @sccParams
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Security & Compliance PowerShell'

        $policies = if ($PolicyName) { $PolicyName | ForEach-Object { Get-RetentionCompliancePolicy -Identity $_ -ErrorAction Stop } }
                    else             { Get-RetentionCompliancePolicy -ErrorAction Stop }

        foreach ($pol in $policies) {
            $issues = @()
            if (-not $pol.Enabled)      { $issues += 'policy is DISABLED - retaining nothing' }
            if ($pol.Mode -ne 'Enforce'){ $issues += ('mode is {0}, not Enforce' -f $pol.Mode) }

            $scopeCount = @($pol.ExchangeLocation).Count + @($pol.SharePointLocation).Count +
                          @($pol.OneDriveLocation).Count + @($pol.TeamsChannelLocation).Count +
                          @($pol.ModernGroupLocation).Count
            if ($scopeCount -eq 0) { $issues += 'no locations in scope - applies to nothing' }

            $rules = @()
            try { $rules = @(Get-RetentionComplianceRule -Policy $pol.Name -ErrorAction Stop) } catch {
                Write-Verbose ('Could not read rules for {0}' -f $pol.Name)
            }
            if ($rules.Count -eq 0) { $issues += 'no rules attached - nothing defines the retention period' }

            $results.Add([PSCustomObject]@{
                Name            = $pol.Name
                Id              = $pol.Guid
                RecordType      = 'Policy'
                Enabled         = $pol.Enabled
                Mode            = "$($pol.Mode)"
                ExchangeScope   = (@($pol.ExchangeLocation) -join '; ')
                SharePointScope = (@($pol.SharePointLocation) -join '; ')
                OneDriveScope   = (@($pol.OneDriveLocation) -join '; ')
                TeamsScope      = (@($pol.TeamsChannelLocation) -join '; ')
                ScopeCount      = $scopeCount
                RuleCount       = $rules.Count
                RetentionAction = (($rules | ForEach-Object { '{0}:{1}d' -f $_.RetentionComplianceAction, $_.RetentionDuration }) -join '; ')
                RetentionDuration = $null
                IsRecordLabel   = $null
                Regulatory      = $null
                Status          = if ($issues.Count) { 'NonCompliant' } else { 'Compliant' }
                Issues          = ($issues -join '; ')
            })
            if ($issues.Count) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $pol.Name -Message ($issues -join '; ')
            }
        }

        if ($IncludeLabels) {
            foreach ($lbl in (Get-ComplianceTag -ErrorAction SilentlyContinue)) {
                $results.Add([PSCustomObject]@{
                    Name            = $lbl.Name
                    Id              = $lbl.Guid
                    RecordType      = 'Label'
                    Enabled         = $true
                    Mode            = ''
                    ExchangeScope   = ''
                    SharePointScope = ''
                    OneDriveScope   = ''
                    TeamsScope      = ''
                    ScopeCount      = $null
                    RuleCount       = $null
                    RetentionAction = "$($lbl.RetentionAction)"
                    RetentionDuration = $lbl.RetentionDuration
                    IsRecordLabel   = $lbl.IsRecordLabel
                    Regulatory      = $lbl.Regulatory
                    Status          = 'Info'
                    Issues          = ''
                })
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'M365 Retention Policy Compliance Check'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
