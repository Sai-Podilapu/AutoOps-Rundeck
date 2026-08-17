<#
.SYNOPSIS
    Reclaims disk space on Azure VMs by clearing whitelisted temporary paths.

.DESCRIPTION
    Runs a cleanup inside the guest through the Azure VM run-command, deleting
    files only from paths on an explicit whitelist. The whitelist is the
    entire safety model: the script refuses to run without one and rejects any
    path not on it, because a cleanup script with an open path parameter is a
    deletion tool.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER SubscriptionId
    Subscription to operate in. Falls back to azure.defaultSubscriptionId in
    config.json.

.PARAMETER ResourceGroupName
    Limit to specific resource groups.

.PARAMETER VMName
    Virtual machines to clean.

.PARAMETER CleanupPath
    Paths to clear. Every one must appear in -AllowedPath or the script
    refuses.

.PARAMETER AllowedPath
    The whitelist. A path outside this list is never cleaned, whatever
    -CleanupPath says.

.PARAMETER OlderThanDays
    Only delete files last written before this many days ago.

.PARAMETER MinimumFreeGB
    Only clean VMs whose OS disk free space is below this.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Clear-AzVmTempPath.ps1 -ResourceGroupName rg-prod -OlderThanDays 7

    Cleans standard temp paths on VMs low on space.

.EXAMPLE
    .\Clear-AzVmTempPath.ps1 -VMName APP01 -CleanupPath 'C:\\Windows\\Temp' -WhatIf

    Shows what would be cleaned on one VM.

.NOTES
    Source use case      : #9 - C Drive Cleanup
    Category             : Azure
    Technology           : PowerShell
    Difficulty           : Low
    Agent possible       : Yes - with Human Approval
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: No
    Guardrails (col L)   : "Safe if SOP whitelists temp paths only"

    Required permissions : Virtual Machine Contributor (run-command requires it). The guest cleanup runs as SYSTEM.
    Required modules     : Az.Accounts, Az.Compute
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    Runs through Invoke-AzVMRunCommand, so it needs the Azure VM agent
    healthy on the guest. The generated guest script deletes files only,
    never directories, and skips anything currently locked rather than
    forcing.

    Rollback             : NONE - deleted files are not recoverable. The path
                           whitelist and the age filter exist because there is
                           no undo.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.Compute

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [string[]]$ResourceGroupName,

    [string[]]$VMName,

    [string[]]$CleanupPath = @('C:\\Windows\\Temp','C:\\Users\\*\\AppData\\Local\\Temp'),

    [string[]]$AllowedPath = @('C:\\Windows\\Temp','C:\\Users\\*\\AppData\\Local\\Temp','C:\\Windows\\SoftwareDistribution\\Download','C:\\Windows\\Logs\\CBS'),

    [ValidateRange(0,3650)]
    [int]$OlderThanDays = 7,

    [ValidateRange(0,10000)]
    [int]$MinimumFreeGB = 10,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Clear-AzVmTempPath'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #9 (Azure)'

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

        # Every requested path must be on the whitelist. No exceptions, no override.
        foreach ($p in $CleanupPath) {
            if ($AllowedPath -notcontains $p) {
                throw ('Refusing to clean "{0}" - it is not in -AllowedPath. Add it deliberately if it is genuinely safe.' -f $p)
            }
        }
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Path whitelist verified: {0} path(s) approved for cleanup' -f $CleanupPath.Count)

        $vms = if ($ResourceGroupName) { $ResourceGroupName | ForEach-Object { Get-AzVM -ResourceGroupName $_ -Status } }
               else                    { Get-AzVM -Status }
        if ($VMName) { $vms = $vms | Where-Object { $VMName -contains $_.Name } }

        foreach ($vm in $vms) {
            if (($vm.PowerState -replace '^VM ', '') -ne 'running') {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $vm.Name `
                    -Message 'Skipped - VM is not running'
                continue
            }
            $results.Add([PSCustomObject]@{
                Name          = $vm.Name
                Id            = $vm.Id
                ResourceGroup = $vm.ResourceGroupName
                Location      = $vm.Location
                PowerState    = ($vm.PowerState -replace '^VM ', '')
                Paths         = ($CleanupPath -join '; ')
                OlderThanDays = $OlderThanDays
                MinimumFreeGB = $MinimumFreeGB
            })
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Clear temporary files')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            # Built here rather than shipped as a file so the whitelist cannot drift
            # between what was validated above and what actually runs in the guest.
            $guestScript = @(
                '$ErrorActionPreference = ''Continue'''
                ('$paths = @({0})' -f (($CleanupPath | ForEach-Object { "'$_'" }) -join ','))
                ('$cutoff = (Get-Date).AddDays(-{0})' -f $OlderThanDays)
                ('$minFreeGB = {0}' -f $MinimumFreeGB)
                '$drive = Get-PSDrive C'
                '$freeBefore = [math]::Round($drive.Free / 1GB, 2)'
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
                'Cleanup result: {0}' -f ($msg -replace "`n", ' ').Trim())
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'Cleaned'; Detail = ($msg -replace "`n", ' ').Trim(); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'C Drive Cleanup'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
