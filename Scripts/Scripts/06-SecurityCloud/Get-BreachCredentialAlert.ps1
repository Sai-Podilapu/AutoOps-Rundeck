<#
.SYNOPSIS
    Checks corporate addresses against known credential breaches.

.DESCRIPTION
    Queries Have I Been Pwned for corporate email addresses appearing in known
    breaches, so HR and IT can act on exposure that happened somewhere else
    entirely.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER DomainName
    Corporate domain to check. Uses the breached-domain endpoint.

.PARAMETER EmailAddress
    Specific addresses to check individually.

.PARAMETER ApiKey
    HIBP API key as a SecureString. A paid key is required.

.PARAMETER SinceDate
    Only report breaches added on or after this date.

.PARAMETER RequestDelayMs
    Delay between requests, to stay inside the rate limit.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-BreachCredentialAlert.ps1 -DomainName contoso.com -ApiKey $key -SinceDate 2026-01-01

    Domain-wide check for breaches added this year.

.EXAMPLE
    .\Get-BreachCredentialAlert.ps1 -EmailAddress user@contoso.com -ApiKey $key

    One address.

.NOTES
    Source use case      : #13 - Dark Web Credential Monitoring Alert
    Category             : Security Cloud
    Technology           : HaveIBeenPwned API / Logic Apps
    Difficulty           : Low
    Agent possible       : Partial
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Alert HR/IT if corporate email found in breach"

    Required permissions : A paid Have I Been Pwned API key. Domain search additionally requires the domain to be verified in your HIBP account.
    Required modules     : none beyond IT-Automation-Common
    Authentication       : Vendor REST API via Invoke-RestMethod, or Graph
                           where the tool is Microsoft.

    HIBP rate-limits by key tier and returns HTTP 429 when exceeded;
    -RequestDelayMs defaults to a spacing that suits the entry tier. A 404
    from this API means "not found in any breach" and is the good answer,
    not an error - it is handled as such rather than logged as a failure.
    Note also that a breach listing means the address appeared in a
    dataset; it does not establish that the CORPORATE password was the one
    exposed.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$DomainName,

    [string[]]$EmailAddress,

    [Parameter(Mandatory)]
    [System.Security.SecureString]$ApiKey,

    [datetime]$SinceDate,

    [ValidateRange(200,10000)]
    [int]$RequestDelayMs = 1600,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-BreachCredentialAlert'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #13 (Security Cloud)'

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


        if (-not $DomainName -and -not $EmailAddress) {
            throw 'Supply -DomainName for a domain-wide check, or -EmailAddress for specific addresses.'
        }

        $keyPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ApiKey)
        try {
            $hibpHeaders = @{
                'hibp-api-key' = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($keyPtr)
                'user-agent'   = 'IT-Automation-Library'
            }
        } finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPtr)
        }

        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $apiBase = 'https://haveibeenpwned.com/api/v3'

        function Get-HibpResult {
            <#
                .SYNOPSIS
                    One HIBP call. A 404 means "clean" and is returned as an empty set.
            #>
            [CmdletBinding()]
            param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][hashtable]$Headers)

            try {
                return Invoke-RestMethod -Uri $Uri -Headers $Headers -Method GET -ErrorAction Stop
            } catch {
                $status = $_.Exception.Response.StatusCode.value__
                if ($status -eq 404) { return $null }          # clean, not an error
                if ($status -eq 429) { throw 'HIBP rate limit hit (HTTP 429). Increase -RequestDelayMs.' }
                throw
            }
        }

        $targets = @()
        if ($DomainName) {
            $domainResult = Get-HibpResult -Uri ('{0}/breacheddomain/{1}' -f $apiBase, $DomainName) -Headers $hibpHeaders
            if (-not $domainResult) {
                Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message (
                    'No addresses at {0} found in any known breach.' -f $DomainName)
            } else {
                foreach ($property in $domainResult.PSObject.Properties) {
                    $targets += [PSCustomObject]@{
                        Address = ('{0}@{1}' -f $property.Name, $DomainName)
                        Breaches = @($property.Value)
                    }
                }
            }
        }

        foreach ($address in @($EmailAddress)) {
            Start-Sleep -Milliseconds $RequestDelayMs
            $accountResult = Get-HibpResult -Headers $hibpHeaders `
                -Uri ('{0}/breachedaccount/{1}?truncateResponse=true' -f $apiBase, [uri]::EscapeDataString($address))
            if (-not $accountResult) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $address -Message 'Not found in any known breach.'
                continue
            }
            $targets += [PSCustomObject]@{ Address = $address; Breaches = @($accountResult | ForEach-Object { $_.Name }) }
        }

        # Breach metadata is fetched once and reused, rather than per address.
        $breachCatalogue = @{}
        try {
            foreach ($breach in @(Invoke-RestMethod -Uri ('{0}/breaches' -f $apiBase) -Headers $hibpHeaders -Method GET -ErrorAction Stop)) {
                $breachCatalogue[$breach.Name] = $breach
            }
        } catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'Breach catalogue unavailable ({0}); names are reported without dates or data classes.' -f $_.Exception.Message)
        }

        foreach ($target in $targets) {
            foreach ($breachName in $target.Breaches) {
                $meta = $breachCatalogue[$breachName]
                if ($SinceDate -and $meta -and $meta.AddedDate -and ([datetime]$meta.AddedDate) -lt $SinceDate) { continue }

                $dataClasses = if ($meta) { (@($meta.DataClasses) -join '; ') } else { '' }
                $hasPasswords = $dataClasses -match '(?i)password'

                $results.Add([PSCustomObject]@{
                    Name          = $target.Address
                    Id            = ('{0}|{1}' -f $target.Address, $breachName)
                    EmailAddress  = $target.Address
                    BreachName    = $breachName
                    BreachTitle   = if ($meta) { $meta.Title } else { $breachName }
                    BreachDate    = if ($meta) { $meta.BreachDate } else { $null }
                    AddedDate     = if ($meta) { $meta.AddedDate } else { $null }
                    AccountsAffected = if ($meta) { $meta.PwnCount } else { $null }
                    DataClasses   = $dataClasses
                    PasswordsExposed = $hasPasswords
                    IsVerified    = if ($meta) { $meta.IsVerified } else { $null }
                    Severity      = if ($hasPasswords) { 'High' } else { 'Medium' }
                    Caveat        = 'The address appeared in this dataset. That does NOT establish that the corporate password was the one exposed.'
                })

                if ($hasPasswords) {
                    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $target.Address -Message (
                        'Appears in "{0}" which included passwords' -f $breachName)
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Dark Web Credential Monitoring Alert'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
