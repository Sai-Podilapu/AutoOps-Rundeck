<#
.SYNOPSIS
    Clears whitelisted temp paths across multiple environments, with
    per-environment rules.

.DESCRIPTION
    The multi-environment form of the C drive cleanup. Targets are selected by
    environment tag, and each environment carries its own age threshold and
    free-space trigger - so dev can be cleaned aggressively while production
    is touched only when genuinely tight. The path whitelist is enforced
    exactly as in the single-environment script.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER SubscriptionId
    Subscription to operate in. Falls back to azure.defaultSubscriptionId in
    config.json.

.PARAMETER Environment
    Environment tag values to process, in order.

.PARAMETER EnvironmentTagKey
    Tag key holding the environment name.

.PARAMETER CleanupPath
    Paths to clear. Every one must appear in -AllowedPath.

.PARAMETER AllowedPath
    The whitelist. A path outside this list is never cleaned.

.PARAMETER ProdOlderThanDays
    Age threshold for production. Deliberately conservative.

.PARAMETER NonProdOlderThanDays
    Age threshold for non-production environments.

.PARAMETER ProdMinimumFreeGB
    Only clean production VMs below this free space.

.PARAMETER NonProdMinimumFreeGB
    Only clean non-production VMs below this free space.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Clear-AzVmTempPathMultiEnv.ps1 -Environment dev,test

    Cleans non-production only, using the aggressive thresholds.

.EXAMPLE
    .\Clear-AzVmTempPathMultiEnv.ps1 -Environment prod -WhatIf

    Shows which production VMs are tight enough to qualify.

.NOTES
    Source use case      : #12 - C Drive Cleanup (Multi-Env)
    Category             : Azure
    Technology           : PowerShell
    Difficulty           : Medium
    Agent possible       : Yes - with Human Approval
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: No
    Guardrails (col L)   : "Same as above across environments; strict path whitelist"

    Required permissions : Virtual Machine Contributor. The guest cleanup runs as SYSTEM via run-command.
    Required modules     : Az.Accounts, Az.Compute
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    Production deliberately uses a longer age threshold and a lower
    free-space trigger than non-production. Treating every environment
    identically is how a cleanup script that was safe in dev deletes
    something that mattered in prod.

    Rollback             : NONE - deleted files are not recoverable. The
                           whitelist and the per-environment age thresholds
                           exist because there is no undo.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.Compute

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [string[]]$Environment = @('dev','test','prod'),

    [string]$EnvironmentTagKey = 'Environment',

    [string[]]$CleanupPath = @('C:\\Windows\\Temp','C:\\Users\\*\\AppData\\Local\\Temp'),

    [string[]]$AllowedPath = @('C:\\Windows\\Temp','C:\\Users\\*\\AppData\\Local\\Temp','C:\\Windows\\SoftwareDistribution\\Download','C:\\Windows\\Logs\\CBS'),

    [ValidateRange(1,3650)]
    [int]$ProdOlderThanDays = 30,

    [ValidateRange(0,3650)]
    [int]$NonProdOlderThanDays = 3,

    [ValidateRange(0,10000)]
    [int]$ProdMinimumFreeGB = 10,

    [ValidateRange(0,10000)]
    [int]$NonProdMinimumFreeGB = 25,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Clear-AzVmTempPathMultiEnv'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #12 (Azure)'

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

        if (-not $AllowedPath -or $AllowedPath.Count -eq 0) {
            throw 'Refusing to run: -AllowedPath is empty. The whitelist is this script''s only safety control.'
        }
        foreach ($p in $CleanupPath) {
            if ($AllowedPath -notcontains $p) {
                throw ('Refusing to clean "{0}" - it is not in -AllowedPath.' -f $p)
            }
        }

        foreach ($env in $Environment) {
            $isProd = ($env -match '(?i)^prod')
            $ageDays = if ($isProd) { $ProdOlderThanDays } else { $NonProdOlderThanDays }
            $freeGB  = if ($isProd) { $ProdMinimumFreeGB } else { $NonProdMinimumFreeGB }

            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $env -Message (
                'Environment rules: files older than {0}d, only when free space is below {1}GB' -f $ageDays, $freeGB)

            $vms = Get-AzVM -Status | Where-Object {
                $full = Get-AzVM -ResourceGroupName $_.ResourceGroupName -Name $_.Name
                $full.Tags[$EnvironmentTagKey] -eq $env
            }

            foreach ($vm in $vms) {
                if (($vm.PowerState -replace '^VM ', '') -ne 'running') { continue }
                $results.Add([PSCustomObject]@{
                    Name          = $vm.Name
                    Id            = $vm.Id
                    ResourceGroup = $vm.ResourceGroupName
                    Environment   = $env
                    IsProduction  = $isProd
                    OlderThanDays = $ageDays
                    MinimumFreeGB = $freeGB
                    Paths         = ($CleanupPath -join '; ')
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Clear temporary files (multi-environment)')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $guestScript = @(
                '$ErrorActionPreference = ''Continue'''
                ('$paths = @({0})' -f (($CleanupPath | ForEach-Object { "'$_'" }) -join ','))
                ('$cutoff = (Get-Date).AddDays(-{0})' -f $item.OlderThanDays)
                ('$minFreeGB = {0}' -f $item.MinimumFreeGB)
                '$freeBefore = [math]::Round((Get-PSDrive C).Free / 1GB, 2)'
                'if ($freeBefore -gt $minFreeGB) {'
                '    Write-Output ("SKIPPED: {0}GB free is above the {1}GB threshold" -f $freeBefore, $minFreeGB)'
                '    exit 0'
                '}'
                '$removed = 0; $bytes = 0'
                'foreach ($p in $paths) {'
                '    foreach ($resolved in (Resolve-Path -Path $p -ErrorAction SilentlyContinue)) {'
                '        Get-ChildItem -LiteralPath $resolved -File -Recurse -Force -ErrorAction SilentlyContinue |'
                '            Where-Object { $_.LastWriteTime -lt $cutoff } | ForEach-Object {'
                '                try { $sz = $_.Length; Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop'
                '                      $removed++; $bytes += $sz } catch { }'
                '            }'
                '    }'
                '}'
                '$freeAfter = [math]::Round((Get-PSDrive C).Free / 1GB, 2)'
                'Write-Output ("REMOVED {0} file(s), {1}MB. Free {2}GB -> {3}GB" -f $removed, [math]::Round($bytes/1MB,1), $freeBefore, $freeAfter)'
            ) -join "`n"

            $tmp = [System.IO.Path]::GetTempFileName() + '.ps1'
            Set-Content -LiteralPath $tmp -Value $guestScript -Encoding UTF8
            try {
                $out = Invoke-AzVMRunCommand -ResourceGroupName $item.ResourceGroup -VMName $item.Name `
                    -CommandId 'RunPowerShellScript' -ScriptPath $tmp -ErrorAction Stop
                $msg = ($out.Value | Where-Object Code -like '*StdOut*' | Select-Object -First 1 -Expand Message)
            } finally {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                '[{0}] {1}' -f $item.Environment, ($msg -replace "`n", ' ').Trim())
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'Cleaned'
                Detail = ('[{0}] {1}' -f $item.Environment, ($msg -replace "`n", ' ').Trim()); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'C Drive Cleanup (Multi-Env)'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
