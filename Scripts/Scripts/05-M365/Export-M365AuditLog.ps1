<#
.SYNOPSIS
    Exports the Microsoft 365 unified audit log for SIEM ingestion.

.DESCRIPTION
    Retrieves unified audit log records for the lookback window and writes
    them in a form a SIEM can ingest. Paging is handled explicitly, because
    the search API returns a bounded page and a naive single call silently
    loses records.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER LookbackHours
    How far back to export.

.PARAMETER RecordType
    Limit to specific record types, e.g. AzureActiveDirectory, ExchangeAdmin.

.PARAMETER Operations
    Limit to specific operations.

.PARAMETER MaxRecords
    Safety ceiling on records retrieved.

.PARAMETER PageSize
    Records per API call.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Export-M365AuditLog.ps1 -LookbackHours 24 -OutputFormat JSON -OutputPath C:\\SIEM\\m365-audit.json

    Daily export as JSON for SIEM ingestion.

.EXAMPLE
    .\Export-M365AuditLog.ps1 -RecordType AzureActiveDirectory -LookbackHours 6

    Directory events only.

.NOTES
    Source use case      : #15 - M365 Admin Audit Log Export
    Category             : M365
    Technology           : Graph API / Compliance API
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Export audit logs to SIEM daily"

    Required permissions : Exchange Online View-Only Audit Logs role, plus unified audit logging enabled on the tenant.
    Required modules     : ExchangeOnlineManagement
    Authentication       : App registration with certificate auth (app-only).

    The unified audit log has ingestion latency of up to 24 hours for some
    workloads, so a run covering the last hour will be incomplete. For
    SIEM feeds, overlap the windows and de-duplicate downstream on
    RecordId rather than assuming each run is complete.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules ExchangeOnlineManagement

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [ValidateRange(1,720)]
    [int]$LookbackHours = 24,

    [string[]]$RecordType,

    [string[]]$Operations,

    [ValidateRange(100,500000)]
    [int]$MaxRecords = 50000,

    [ValidateRange(100,5000)]
    [int]$PageSize = 5000,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Export-M365AuditLog'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #15 (M365)'

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


        $exoParams = @{ ShowBanner = $false; ErrorAction = 'Stop' }
        if ($config -and $config.azure) {
            if ($config.azure.applicationId)         { $exoParams.AppId = $config.azure.applicationId }
            if ($config.azure.certificateThumbprint) { $exoParams.CertificateThumbprint = $config.azure.certificateThumbprint }
            if ($config.azure.tenantId)              { $exoParams.Organization = $config.azure.tenantId }
        }
        if (-not $exoParams.AppId) { throw 'Exchange Online requires app-only certificate auth (see config.json).' }
        Connect-ExchangeOnline @exoParams

        $end = Get-Date
        $start = $end.AddHours(-$LookbackHours)
        $sessionId = 'AutoOpsAudit-{0}' -f (Get-Date -Format 'yyyyMMddHHmmss')

        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Exporting audit records from {0:u} to {1:u}' -f $start, $end)

        $total = 0
        $more = $true

        # ReturnLargeSet pages through results; the loop must continue until an empty
        # page. A single call returns only the first page and silently loses the rest.
        while ($more -and $total -lt $MaxRecords) {
            $searchParams = @{
                StartDate   = $start
                EndDate     = $end
                SessionId   = $sessionId
                SessionCommand = 'ReturnLargeSet'
                ResultSize  = $PageSize
                ErrorAction = 'Stop'
            }
            if ($RecordType) { $searchParams.RecordType = $RecordType }
            if ($Operations) { $searchParams.Operations = $Operations }

            $page = @(Search-UnifiedAuditLog @searchParams)
            if ($page.Count -eq 0) { $more = $false; break }

            foreach ($rec in $page) {
                $data = $null
                try { $data = $rec.AuditData | ConvertFrom-Json } catch {
                    Write-Verbose ('Unparseable AuditData on record {0}' -f $rec.Identity)
                }

                $results.Add([PSCustomObject]@{
                    Name         = $rec.Operations
                    Id           = $rec.Identity
                    RecordType   = "$($rec.RecordType)"
                    CreationDate = $rec.CreationDate
                    UserIds      = $rec.UserIds
                    Operation    = $rec.Operations
                    ResultStatus = if ($data) { $data.ResultStatus } else { $null }
                    ClientIP     = if ($data) { $data.ClientIP } else { $null }
                    Workload     = if ($data) { $data.Workload } else { $null }
                    ObjectId     = if ($data) { $data.ObjectId } else { $null }
                    AuditData    = $rec.AuditData
                })
                $total++
                if ($total -ge $MaxRecords) { break }
            }

            if ($page.Count -lt $PageSize) { $more = $false }
        }

        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Exported {0} audit record(s). Note: unified audit ingestion lags up to 24h for some workloads - ' +
            'overlap windows and de-duplicate on Id downstream.' -f $total)

        if ($total -ge $MaxRecords) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'Hit the -MaxRecords ceiling of {0}. The export is TRUNCATED - narrow the window or raise the limit.' -f $MaxRecords)
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'M365 Admin Audit Log Export'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
