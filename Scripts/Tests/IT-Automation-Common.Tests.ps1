<#
.SYNOPSIS
    Pester tests for IT-Automation-Common.psm1.

.DESCRIPTION
    The module carries the safety controls the assessment workbook demands, so
    these tests concentrate on the properties that would be dangerous if wrong:

      - an approval reference must be refused unless it is genuinely approved,
        unexpired, and raised for the script trying to use it
      - secrets must never reach a log file or an approval artifact
      - pre-flight must fail closed on a missing module

    Written to run on both Pester 3.x (which ships with Windows PowerShell) and
    Pester 5.x, so `Should -Be` style is avoided in favour of the older
    `Should Be` where the two differ.

.NOTES
    Run:  Invoke-Pester -Path .\Tests
#>

$ModulePath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Modules\IT-Automation-Common.psm1'

Describe 'IT-Automation-Common module' {

    BeforeAll {
        Import-Module $ModulePath -Force -ErrorAction Stop
        $script:TempRoot = Join-Path -Path $env:TEMP -ChildPath ("ITAutoTests_" + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:TempRoot -ItemType Directory -Force | Out-Null
        $script:LogDir = Join-Path $script:TempRoot 'Logs'
        $script:AprDir = Join-Path $script:TempRoot 'Approvals'
    }

    AfterAll {
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Module IT-Automation-Common -Force -ErrorAction SilentlyContinue
    }

    Context 'Exported surface' {

        It 'exports exactly the eight documented helpers' {
            $expected = @(
                'Connect-AutomationPlatform', 'Export-AutomationResult', 'Get-AutomationConfig',
                'New-ApprovalRequest', 'Send-AutomationReport', 'Test-ApprovalReference',
                'Test-Prerequisite', 'Write-AutomationLog'
            )
            $actual = (Get-Command -Module IT-Automation-Common).Name | Sort-Object
            ($actual -join ',') | Should Be ($expected -join ',')
        }

        It 'does not export internal helpers' {
            (Get-Command -Module IT-Automation-Common).Name -contains 'Protect-SensitiveText' | Should Be $false
        }
    }

    Context 'Write-AutomationLog' {

        It 'writes a timestamped line containing the level and message' {
            Write-AutomationLog -Message 'unit test line' -Level INFO -ScriptName 'PesterLog' -LogDirectory $script:LogDir
            $file = Get-ChildItem -Path $script:LogDir -Filter 'PesterLog_*.log' | Select-Object -First 1
            $file | Should Not BeNullOrEmpty
            (Get-Content $file.FullName -Raw) -match 'unit test line' | Should Be $true
            (Get-Content $file.FullName -Raw) -match '\[INFO' | Should Be $true
        }

        It 'records the target in its own field so an audit can answer what was touched' {
            Write-AutomationLog -Message 'acted' -Level SUCCESS -ScriptName 'PesterTarget' `
                -LogDirectory $script:LogDir -Target 'SRV01\Spooler'
            $file = Get-ChildItem -Path $script:LogDir -Filter 'PesterTarget_*.log' | Select-Object -First 1
            (Get-Content $file.FullName -Raw) -match "target='SRV01\\Spooler'" | Should Be $true
        }

        It 'REDACTS anything that looks like a credential' {
            Write-AutomationLog -Message 'connecting with password=SuperSecret123 and token=abc123xyz' `
                -Level INFO -ScriptName 'PesterSecret' -LogDirectory $script:LogDir
            $file = Get-ChildItem -Path $script:LogDir -Filter 'PesterSecret_*.log' | Select-Object -First 1
            $content = Get-Content $file.FullName -Raw
            $content -match 'SuperSecret123' | Should Be $false
            $content -match 'abc123xyz'      | Should Be $false
            $content -match '<redacted>'     | Should Be $true
        }

        It 'redacts an AWS access key id' {
            Write-AutomationLog -Message 'key AKIAIOSFODNN7EXAMPLE used' -Level INFO `
                -ScriptName 'PesterAws' -LogDirectory $script:LogDir
            $file = Get-ChildItem -Path $script:LogDir -Filter 'PesterAws_*.log' | Select-Object -First 1
            (Get-Content $file.FullName -Raw) -match 'AKIAIOSFODNN7EXAMPLE' | Should Be $false
        }
    }

    Context 'Approval gate — the control the workbook requires on 66 use cases' {

        It 'creates a request in Pending state, never pre-approved' {
            $r = New-ApprovalRequest -ScriptName 'PesterGate' -Action 'reboot 2 servers' `
                -ChangeSet @('SRV01', 'SRV02') -ApprovalDirectory $script:AprDir
            $r.State     | Should Be 'Pending'
            $r.ItemCount | Should Be 2
            $r.Reference | Should Not BeNullOrEmpty
            $script:PendingRef = $r.Reference
        }

        It 'REFUSES a reference that is still Pending' {
            $v = Test-ApprovalReference -Reference $script:PendingRef -ApprovalDirectory $script:AprDir
            $v.IsValid | Should Be $false
            $v.Reason -match 'not ''Approved''' | Should Be $true
        }

        It 'REFUSES a reference that does not exist' {
            $v = Test-ApprovalReference -Reference 'APR-00000000000000-0000' -ApprovalDirectory $script:AprDir
            $v.IsValid | Should Be $false
            $v.Reason -match 'No approval artifact' | Should Be $true
        }

        It 'ACCEPTS a reference once a human marks it Approved' {
            $path = Join-Path $script:AprDir "$($script:PendingRef).json"
            $a = Get-Content $path -Raw | ConvertFrom-Json
            $a.State = 'Approved'; $a.ApprovedBy = 'CONTOSO\changemgr'; $a.ApprovedAt = (Get-Date).ToString('o')
            $a | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8

            $v = Test-ApprovalReference -Reference $script:PendingRef -ApprovalDirectory $script:AprDir
            $v.IsValid    | Should Be $true
            $v.ApprovedBy | Should Be 'CONTOSO\changemgr'
        }

        It 'REFUSES an approval raised for a DIFFERENT script (no replay across actions)' {
            $v = Test-ApprovalReference -Reference $script:PendingRef -ScriptName 'SomeOtherScript' `
                -ApprovalDirectory $script:AprDir
            $v.IsValid | Should Be $false
            $v.Reason -match 'was raised for' | Should Be $true
        }

        It 'REFUSES an expired approval' {
            $r = New-ApprovalRequest -ScriptName 'PesterExpiry' -Action 'x' -ChangeSet @('a') `
                -ApprovalDirectory $script:AprDir
            $path = Join-Path $script:AprDir "$($r.Reference).json"
            $a = Get-Content $path -Raw | ConvertFrom-Json
            $a.State = 'Approved'; $a.ApprovedBy = 'x'; $a.ApprovedAt = (Get-Date).AddDays(-3).ToString('o')
            $a.ExpiresAt = (Get-Date).AddDays(-2).ToString('o')
            $a | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8

            $v = Test-ApprovalReference -Reference $r.Reference -ApprovalDirectory $script:AprDir
            $v.IsValid | Should Be $false
            $v.Reason -match 'expired' | Should Be $true
        }

        It 'does not write a secret into the approval artifact' {
            $r = New-ApprovalRequest -ScriptName 'PesterAprSecret' -Action 'connect with password=Hunter2Secret' `
                -ChangeSet @('a') -ApprovalDirectory $script:AprDir
            $raw = Get-Content (Join-Path $script:AprDir "$($r.Reference).json") -Raw
            $raw -match 'Hunter2Secret' | Should Be $false
        }
    }

    Context 'Test-Prerequisite' {

        It 'fails closed when a required module is absent' {
            $p = Test-Prerequisite -RequiredModule 'ThisModuleDoesNotExist_ZZZ'
            $p.Passed | Should Be $false
            $p.Summary -match 'is not installed' | Should Be $true
        }

        It 'passes for a module that is present' {
            $p = Test-Prerequisite -RequiredModule 'Microsoft.PowerShell.Management'
            $p.Passed | Should Be $true
        }

        It 'names the failing check so the caller can log the precise reason' {
            $p = Test-Prerequisite -RequiredModule 'ThisModuleDoesNotExist_ZZZ'
            $p.Failed[0].Check | Should Be 'Module'
            $p.Failed[0].Item  | Should Be 'ThisModuleDoesNotExist_ZZZ'
        }
    }

    Context 'Export-AutomationResult' {

        It 'returns the objects it was given so it can sit mid-pipeline' {
            $in = @([PSCustomObject]@{ Name = 'a' }, [PSCustomObject]@{ Name = 'b' })
            $out = $in | Export-AutomationResult -OutputFormat Console
            @($out).Count | Should Be 2
        }

        It 'writes CSV to the requested path' {
            $p = Join-Path $script:TempRoot 'r.csv'
            @([PSCustomObject]@{ Server = 'SRV01'; FreeGB = 12 }) |
                Export-AutomationResult -OutputFormat CSV -Path $p | Out-Null
            Test-Path $p | Should Be $true
            (Get-Content $p -Raw) -match 'SRV01' | Should Be $true
        }

        It 'writes HTML with the supplied title' {
            $p = Join-Path $script:TempRoot 'r.html'
            @([PSCustomObject]@{ Server = 'SRV01' }) |
                Export-AutomationResult -OutputFormat HTML -Path $p -Title 'Disk Report' | Out-Null
            (Get-Content $p -Raw) -match 'Disk Report' | Should Be $true
        }
    }

    Context 'Get-AutomationConfig' {

        It 'throws a directive error when the config file is missing' {
            { Get-AutomationConfig -Path (Join-Path $script:TempRoot 'nope.json') } |
                Should Throw
        }

        It 'reads a valid config file' {
            $p = Join-Path $script:TempRoot 'cfg.json'
            '{ "environment": "lab", "logging": { "retentionDays": 30 } }' |
                Set-Content -LiteralPath $p -Encoding UTF8
            $c = Get-AutomationConfig -Path $p
            $c.environment | Should Be 'lab'
            $c.logging.retentionDays | Should Be 30
        }

        It 'throws on malformed JSON rather than returning a partial object' {
            $p = Join-Path $script:TempRoot 'bad.json'
            '{ not json' | Set-Content -LiteralPath $p -Encoding UTF8
            { Get-AutomationConfig -Path $p } | Should Throw
        }
    }

    Context 'Sample config integrity' {

        It 'contains no plaintext secret assignments' {
            $sample = Join-Path (Split-Path -Parent $PSScriptRoot) 'Config\config.sample.json'
            $raw = Get-Content $sample -Raw
            $raw -match '(?i)"(password|clientSecret|apiKey|accessKey|secretKey)"\s*:\s*"(?!REPLACE-ME)[^"]+"' |
                Should Be $false
        }

        It 'ships the protected-process blacklist the workbook guardrail requires' {
            $sample = Join-Path (Split-Path -Parent $PSScriptRoot) 'Config\config.sample.json'
            $c = Get-Content $sample -Raw | ConvertFrom-Json
            $c.safety.protectedProcesses -contains 'lsass' | Should Be $true
            $c.safety.protectedProcesses -contains 'csrss' | Should Be $true
        }
    }
}
