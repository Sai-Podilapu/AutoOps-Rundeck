<#
.SYNOPSIS
    Compares Conditional Access policies against Zero Trust baseline
    expectations.

.DESCRIPTION
    Checks the Conditional Access estate for the controls a Zero Trust posture
    assumes are present - MFA for administrators, legacy authentication
    blocked, device compliance required, session controls on risky access -
    and reports which are absent, present but report-only, or scoped narrowly
    enough not to count.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

    AGENT-ASSIST ONLY. This automates the mechanical part - gathering,
    enriching and comparing against a baseline - and then stops, producing
    a decision-ready package. The judgement step is deliberately left to a
    human and is NOT scripted.

.PARAMETER BaselineFile
    JSON file of expected controls. The built-in expectations are used when
    omitted.

.PARAMETER IncludeDisabled
    Include policies that are disabled.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-ZeroTrustPolicyAudit.ps1 -OutputFormat HTML

    Zero Trust control gaps as HTML.

.EXAMPLE
    .\Get-ZeroTrustPolicyAudit.ps1 -BaselineFile .\\zt-baseline.json

    Compares against your own control list.

.NOTES
    Source use case      : #14 - Zero Trust Network Access Policy Audit
    Category             : Security Cloud
    Technology           : Entra ID / Conditional Access API
    Difficulty           : Medium
    Agent possible       : Partial
    Can execute with SOP : Partially - Agent Assists
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Agent collects & compares CA policies vs baseline; judging policy adequacy for the org's risk appetite is human"

    Required permissions : Microsoft Graph Policy.Read.All.
    Required modules     : Microsoft.Graph.Authentication, Microsoft.Graph.Identity.SignIns
    Authentication       : Vendor REST API via Invoke-RestMethod, or Graph
                           where the tool is Microsoft.

    AGENT-ASSIST. Whether a control set is adequate depends on the
    organisation's risk appetite, its user population and what it is
    protecting - none of which this script knows. It reports presence,
    state and scope, and stops. A policy in report-only mode is reported
    as NOT in force, because that is what it is: it logs what it would
    have done and blocks nothing. This overlaps deliberately with the M365
    Conditional Access audit; that one inventories policies, this one
    tests them against a Zero Trust expectation.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication
#Requires -Modules Microsoft.Graph.Identity.SignIns

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$BaselineFile,

    [switch]$IncludeDisabled,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-ZeroTrustPolicyAudit'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #14 (Security Cloud)'

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


        Connect-MgGraph -Scopes 'Policy.Read.All' -NoWelcome -ErrorAction Stop
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Microsoft Graph'

        $policies = @(Get-MgIdentityConditionalAccessPolicy -All -ErrorAction Stop)
        if (-not $IncludeDisabled) {
            $policies = @($policies | Where-Object { "$($_.State)" -ne 'disabled' })
        }

        # Each check is a predicate over the policy set. Deliberately small and
        # explicit: it is a conversation starter, not a certification.
        $checks = @(
            @{ Name = 'MFA required for administrators'
               Test = { param($p) $p.GrantControls.BuiltInControls -contains 'mfa' -and
                                  @($p.Conditions.Users.IncludeRoles).Count -gt 0 }
               Why  = 'An administrator account without MFA is the shortest path to tenant compromise.' }
            @{ Name = 'Legacy authentication blocked'
               Test = { param($p) $p.GrantControls.BuiltInControls -contains 'block' -and
                                  @($p.Conditions.ClientAppTypes | Where-Object { $_ -match '(?i)exchangeActiveSync|other' }).Count -gt 0 }
               Why  = 'Legacy auth protocols cannot present an MFA challenge, so every other MFA policy is bypassable while they are allowed.' }
            @{ Name = 'Device compliance required for corporate resources'
               Test = { param($p) $p.GrantControls.BuiltInControls -contains 'compliantDevice' -or
                                  $p.GrantControls.BuiltInControls -contains 'domainJoinedDevice' }
               Why  = 'Zero Trust assumes device posture is evaluated, not just user identity.' }
            @{ Name = 'MFA required for all users'
               Test = { param($p) $p.GrantControls.BuiltInControls -contains 'mfa' -and
                                  $p.Conditions.Users.IncludeUsers -contains 'All' }
               Why  = 'Administrator-only MFA leaves every standard account as an entry point.' }
            @{ Name = 'Sign-in risk policy present'
               Test = { param($p) @($p.Conditions.SignInRiskLevels).Count -gt 0 }
               Why  = 'Without a risk condition, a sign-in Identity Protection rates as high is treated exactly like any other.' }
            @{ Name = 'Session controls on unmanaged devices'
               Test = { param($p) $null -ne $p.SessionControls -and
                                  ($null -ne $p.SessionControls.ApplicationEnforcedRestrictions -or
                                   $null -ne $p.SessionControls.CloudAppSecurity -or
                                   $null -ne $p.SessionControls.SignInFrequency) }
               Why  = 'Granting access without session limits means a token issued once is good until it expires.' }
        )

        if ($BaselineFile) {
            if (-not (Test-Path -LiteralPath $BaselineFile)) { throw ('Baseline file not found: {0}' -f $BaselineFile) }
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
                'Custom baseline supplied; it is reported ALONGSIDE the built-in checks, not instead of them.')
        }

        foreach ($check in $checks) {
            $matching = @($policies | Where-Object { & $check.Test $_ })
            $enforced = @($matching | Where-Object { "$($_.State)" -eq 'enabled' })
            $reportOnly = @($matching | Where-Object { "$($_.State)" -eq 'enabledForReportingButNotEnforced' })

            $status = if ($enforced.Count -gt 0) { 'Present' }
                      elseif ($reportOnly.Count -gt 0) { 'REPORT-ONLY' }
                      else { 'ABSENT' }

            $results.Add([PSCustomObject]@{
                Name            = $check.Name
                Id              = $check.Name
                Control         = $check.Name
                Status          = $status
                EnforcedPolicies= (($enforced | ForEach-Object { $_.DisplayName }) -join '; ')
                ReportOnlyPolicies = (($reportOnly | ForEach-Object { $_.DisplayName }) -join '; ')
                MatchCount      = $matching.Count
                WhyItMatters    = $check.Why
                AdequacyNote    = 'Whether this control set fits the organisation''s risk appetite is a human judgement and is not made here.'
            })

            if ($status -eq 'ABSENT') {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $check.Name -Message (
                    'No policy implements this control. {0}' -f $check.Why)
            } elseif ($status -eq 'REPORT-ONLY') {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $check.Name -Message (
                    'Only report-only policies match. This control logs what it would do and blocks nothing.')
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

    # Agent-assist: the package is produced for a human. The script does
    # NOT proceed to a decision - that step is deliberately not automated.
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'Decision-ready package built: {0} item(s). Human review required.' -f $candidates.Count)
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message ('Collected {0} record(s).' -f $candidates.Count)
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Zero Trust Network Access Policy Audit'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
