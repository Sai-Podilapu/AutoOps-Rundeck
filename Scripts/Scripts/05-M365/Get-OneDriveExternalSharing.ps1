<#
.SYNOPSIS
    Audits OneDrive items shared with people outside the organisation.

.DESCRIPTION
    Finds OneDrive items carrying sharing links that reach external
    recipients, or anonymous "anyone" links. An anonymous link is the higher
    finding: it needs no sign-in, so it works for anybody who obtains the URL,
    including after the recipient has left.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER UserPrincipalName
    Limit to specific users. All licensed users when omitted.

.PARAMETER MaxUsers
    Maximum users to scan when -UserPrincipalName is omitted.

.PARAMETER MaxItemsPerUser
    Maximum items to examine per drive.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-OneDriveExternalSharing.ps1 -UserPrincipalName user@contoso.com

    Audits one user\u2019s OneDrive.

.EXAMPLE
    .\Get-OneDriveExternalSharing.ps1 -MaxUsers 50 -OutputFormat HTML

    Samples 50 users and writes an HTML report.

.NOTES
    Source use case      : #5 - OneDrive External Sharing Audit
    Category             : M365
    Technology           : Graph API / PowerShell
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Report externally shared files"

    Required permissions : Microsoft Graph Files.Read.All, Sites.Read.All and User.Read.All.
    Required modules     : Microsoft.Graph.Authentication, Microsoft.Graph.Files
    Authentication       : App registration with certificate auth (app-only).

    Scanning every drive is slow and rate-limited. Use -UserPrincipalName
    for a targeted audit, and treat the tenant-wide scan as a scheduled
    overnight job rather than an interactive one.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication
#Requires -Modules Microsoft.Graph.Files

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string[]]$UserPrincipalName,

    [ValidateRange(1,10000)]
    [int]$MaxUsers = 200,

    [ValidateRange(1,5000)]
    [int]$MaxItemsPerUser = 500,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-OneDriveExternalSharing'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #5 (M365)'

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


        Connect-MgGraph -Scopes 'Files.Read.All','Sites.Read.All','User.Read.All' -NoWelcome -ErrorAction Stop
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Microsoft Graph'

        $tenantDomains = @()
        try {
            $orgResp = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/organization' -ErrorAction Stop
            $tenantDomains = @($orgResp.value[0].verifiedDomains.name)
        } catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message 'Could not read verified domains; external detection may be inaccurate'
        }

        $users = if ($UserPrincipalName) { $UserPrincipalName | ForEach-Object { Get-MgUser -UserId $_ -ErrorAction Stop } }
                 else { Get-MgUser -Filter 'assignedLicenses/$count ne 0' -ConsistencyLevel eventual -CountVariable c -Top $MaxUsers -ErrorAction Stop }

        foreach ($u in $users) {
            $drive = $null
            try { $drive = Get-MgUserDrive -UserId $u.Id -ErrorAction Stop } catch {
                Write-Verbose ('No OneDrive for {0}' -f $u.UserPrincipalName)
                continue
            }

            $items = @()
            try {
                $items = Get-MgDriveItem -DriveId $drive.Id -Filter 'shared ne null' -Top $MaxItemsPerUser -ErrorAction Stop
            } catch {
                # Fall back to enumerating the root children where the filter is unsupported.
                try { $items = Get-MgDriveRootChild -DriveId $drive.Id -Top $MaxItemsPerUser -ErrorAction Stop } catch {
                    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $u.UserPrincipalName `
                        -Message ('Drive enumeration failed: {0}' -f $_.Exception.Message)
                    continue
                }
            }

            foreach ($it in $items) {
                if (-not $it.Shared) { continue }

                $perms = @()
                try { $perms = @(Get-MgDriveItemPermission -DriveId $drive.Id -DriveItemId $it.Id -ErrorAction Stop) } catch {
                    Write-Verbose ('Permissions unreadable for {0}' -f $it.Name)
                    continue
                }

                foreach ($p in $perms) {
                    $scope = $p.Link.Scope
                    $isAnonymous = ($scope -eq 'anonymous')

                    $externalRecipients = @()
                    foreach ($identity in @($p.GrantedToIdentitiesV2) + @($p.GrantedToV2)) {
                        $addr = $identity.User.AdditionalProperties.email
                        if (-not $addr) { $addr = $identity.User.UserPrincipalName }
                        if (-not $addr) { continue }
                        $domain = ($addr -split '@')[-1]
                        if ($tenantDomains -notcontains $domain) { $externalRecipients += $addr }
                    }

                    if (-not $isAnonymous -and $externalRecipients.Count -eq 0) { continue }

                    $results.Add([PSCustomObject]@{
                        Name          = ('{0} / {1}' -f $u.UserPrincipalName, $it.Name)
                        Id            = $it.Id
                        Owner         = $u.UserPrincipalName
                        ItemName      = $it.Name
                        ItemType      = if ($it.Folder) { 'Folder' } else { 'File' }
                        SizeMB        = if ($it.Size) { [math]::Round($it.Size / 1MB, 2) } else { $null }
                        WebUrl        = $it.WebUrl
                        LinkScope     = $scope
                        LinkType      = $p.Link.Type
                        IsAnonymous   = $isAnonymous
                        ExternalRecipients = ($externalRecipients -join '; ')
                        ExpiresOn     = $p.ExpirationDateTime
                        Severity      = if ($isAnonymous) { 'HIGH - anonymous link works for anyone with the URL' }
                                        else { 'Medium - shared with named external recipients' }
                    })
                    if ($isAnonymous) {
                        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $it.Name `
                            -Message ('Anonymous sharing link on {0} owned by {1}' -f $it.Name, $u.UserPrincipalName)
                    }
                }
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'OneDrive External Sharing Audit'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
