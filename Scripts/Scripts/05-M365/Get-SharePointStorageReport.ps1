<#
.SYNOPSIS
    Reports SharePoint site storage usage against quota.

.DESCRIPTION
    Lists sites with their storage consumption and remaining headroom,
    flagging any above the threshold. Headroom matters more than raw size: a
    900GB site on a 1TB quota is a problem and a 900GB site on a 5TB quota is
    not.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER WarnAtPercent
    Flag a site using at least this much of its quota.

.PARAMETER MinimumSizeGB
    Ignore sites smaller than this, to keep the report focused.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-SharePointStorageReport.ps1 -WarnAtPercent 80 -OutputFormat HTML

    Storage report as HTML.

.EXAMPLE
    .\Get-SharePointStorageReport.ps1 -MinimumSizeGB 10 -OutputFormat CSV

    Only sites over 10GB.

.NOTES
    Source use case      : #4 - SharePoint Storage Quota Report
    Category             : M365
    Technology           : PnP PowerShell
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Quota threshold alerting"

    Required permissions : Microsoft Graph Sites.Read.All and Reports.Read.All.
    Required modules     : Microsoft.Graph.Authentication, Microsoft.Graph.Sites
    Authentication       : App registration with certificate auth (app-only).

    Storage figures come from the SharePoint usage report, which lags
    actual usage by 1-2 days. A site that grew sharply yesterday may not
    show it yet.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication
#Requires -Modules Microsoft.Graph.Sites

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [ValidateRange(1,100)]
    [int]$WarnAtPercent = 80,

    [double]$MinimumSizeGB = 1,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-SharePointStorageReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #4 (M365)'

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


        Connect-MgGraph -Scopes 'Sites.Read.All','Reports.Read.All' -NoWelcome -ErrorAction Stop
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Microsoft Graph'

        # The usage report is a CSV download rather than a JSON collection.
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            Invoke-MgGraphRequest -Method GET `
                -Uri "https://graph.microsoft.com/v1.0/reports/getSharePointSiteUsageDetail(period='D7')" `
                -OutputFilePath $tmp -ErrorAction Stop

            $rows = Import-Csv -LiteralPath $tmp
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }

        foreach ($row in $rows) {
            $usedBytes = [double]($row.'Storage Used (Byte)')
            $quotaBytes = [double]($row.'Storage Allocated (Byte)')
            $usedGB = [math]::Round($usedBytes / 1GB, 2)

            if ($usedGB -lt $MinimumSizeGB) { continue }

            $pct = if ($quotaBytes -gt 0) { [math]::Round(($usedBytes / $quotaBytes) * 100, 1) } else { $null }

            $results.Add([PSCustomObject]@{
                Name          = $row.'Site URL'
                Id            = $row.'Site Id'
                OwnerDisplay  = $row.'Owner Display Name'
                OwnerUpn      = $row.'Owner Principal Name'
                UsedGB        = $usedGB
                QuotaGB       = [math]::Round($quotaBytes / 1GB, 2)
                PercentUsed   = $pct
                FileCount     = $row.'File Count'
                ActiveFileCount = $row.'Active File Count'
                LastActivity  = $row.'Last Activity Date'
                Template      = $row.'Root Web Template'
                Status        = if ($null -ne $pct -and $pct -ge $WarnAtPercent) { 'Warning' } else { 'OK' }
            })
            if ($null -ne $pct -and $pct -ge $WarnAtPercent) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $row.'Site URL' `
                    -Message ('Storage {0}% of quota ({1}GB of {2}GB)' -f $pct, $usedGB, [math]::Round($quotaBytes/1GB,2))
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'SharePoint Storage Quota Report'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
