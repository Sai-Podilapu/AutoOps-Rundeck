# -*- coding: utf-8 -*-
"""Script generator.

Emits one complete PowerShell script per workbook use case. The SAFETY
SKELETON is derived mechanically from the workbook columns, which is the point:
columns I, J, K and H are the specification for how a script must behave, so
they drive code generation rather than documentation.

  col I = Read / Report            -> no write cmdlets emitted at all
  col I = Change / Write           -> SupportsShouldProcess + prior-state capture
  col I = Destructive / High-Impact-> ConfirmImpact High + two-phase -Execute
  col K = Yes                      -> -ApprovalReference gate, refuses without it
  col J = High                     -> pre-flight validation + post-action verify
  col H = Partially - Agent Assists-> gather/enrich only, stops for a human

Each use case supplies only what is genuinely specific to it: the cmdlets that
discover candidates, and the cmdlets that act on one.
"""
import io, json, os, re

ROOT = r'D:\AutoOps\scripts'
OUT = os.path.join(ROOT, 'Scripts')

FOLDER = {
    'AWS': '01-AWS', 'Azure': '02-Azure', 'Azure AVD': '03-AzureAVD', 'OCI': '04-OCI',
    'M365': '05-M365', 'Security Cloud': '06-SecurityCloud', 'Network Devices': '07-NetworkDevices',
    'Backup Commvault': '08-BackupCommvault', 'Hyper-V': '09-HyperV', 'VMware OnPrem': '10-VMwareOnPrem',
    'Windows Server': '11-WindowsServer', 'Exchange & O365': '12-ExchangeO365',
    'AD & Identity': '13-ADIdentity',
}

# Platform -> (Connect-AutomationPlatform value, default #Requires modules, auth note)
PLATFORM = {
    'AWS':              ('AWS', ['AWS.Tools.Common'], 'IAM role or SSO profile via Set-AWSCredential. Never an access key pair in code.'),
    'Azure':            ('Azure', ['Az.Accounts'], 'Managed identity preferred; otherwise service principal with certificate.'),
    'Azure AVD':        ('AzureAVD', ['Az.Accounts', 'Az.DesktopVirtualization'], 'Inherits the Az context; managed identity preferred.'),
    'OCI':              ('OCI', [], 'OCI CLI config profile. NOTE: there is no first-party OCI PowerShell module - this wraps the OCI CLI.'),
    'M365':             ('Graph', ['Microsoft.Graph.Authentication'], 'App registration with certificate auth (app-only).'),
    'Security Cloud':   ('Graph', ['Microsoft.Graph.Authentication'], 'Vendor REST API via Invoke-RestMethod, or Graph where the tool is Microsoft.'),
    'Network Devices':  ('WindowsServer', ['Posh-SSH'], 'SSH key or credential via Posh-SSH. NOTE: Python/Netmiko is a better fit for multi-vendor CLI parsing - see .NOTES.'),
    'Backup Commvault': ('Commvault', [], 'Commvault REST API token obtained per call. No first-party PowerShell module.'),
    'Hyper-V':          ('HyperV', ['Hyper-V'], 'Integrated Kerberos over PSRemoting; SCVMM cmdlets where noted.'),
    'VMware OnPrem':    ('VMware', ['VMware.VimAutomation.Core'], 'Connect-VIServer with the PowerCLI credential store or an explicit -Credential.'),
    'Windows Server':   ('WindowsServer', [], 'Integrated Kerberos over WinRM, or -Credential.'),
    'Exchange & O365':  ('ExchangeOnline', ['ExchangeOnlineManagement'], 'App-only certificate auth via Connect-ExchangeOnline.'),
    'AD & Identity':    ('ActiveDirectory', ['ActiveDirectory'], 'Delegated service account with the minimum required AD rights.'),
}

READ, CHANGE, DESTRUCTIVE = 'Read / Report', 'Change / Write', 'Destructive / High-Impact'


def wrap(text, width, indent):
    """Wrap help text without breaking words, preserving the indent."""
    words, lines, cur = text.split(), [], ''
    for w in words:
        if len(cur) + len(w) + 1 > width:
            lines.append(cur)
            cur = w
        else:
            cur = (cur + ' ' + w).strip()
    if cur:
        lines.append(cur)
    return ('\n' + indent).join(lines)


def build(sheet, row, spec):
    """Render one complete .ps1 from a workbook row plus its use-case spec."""
    num = row['num']
    task = row['task']
    atype = row['atype']
    risk = row['risk']
    approval = str(row['approval']).strip().lower() == 'yes'
    assists = 'partially' in str(row['sop']).lower()
    guard = row['remarks'] or ''
    fname = spec['file']
    plat_key, def_mods, auth = PLATFORM[sheet]
    mods = spec.get('modules', def_mods)
    is_dest = atype == DESTRUCTIVE
    is_read = atype == READ
    is_change = atype == CHANGE
    high_risk = str(risk).strip().lower() == 'high'

    L = []
    A = L.append

    # ------------------------------------------------------------ help ----
    A('<#')
    A('.SYNOPSIS')
    A('    ' + wrap(spec['synopsis'], 74, '    '))
    A('')
    A('.DESCRIPTION')
    A('    ' + wrap(spec['desc'], 74, '    '))
    A('')
    if is_read:
        A('    This script is READ-ONLY. It issues no write, modify or delete call and')
        A('    is safe to schedule unattended.')
    elif is_dest:
        A('    DESTRUCTIVE. This script is REPORT-ONLY by default: it produces the')
        A('    candidate list and stops. Nothing is deleted, wiped or failed over')
        A('    unless -Execute is passed AND a valid -ApprovalReference is supplied.')
        A('    A pre-action backup/export is taken where the platform allows it, and')
        A('    every object is logged individually before it is touched.')
    elif is_change:
        A('    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is')
        A('    captured and logged before each change so the previous condition is')
        A('    recoverable.')
    if approval:
        A('')
        A('    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST')
        A('    mode: it produces the change set, raises an approval artifact, prints')
        A('    the reference and stops without acting.')
    if assists:
        A('')
        A('    AGENT-ASSIST ONLY. This automates the mechanical part - gathering,')
        A('    enriching and comparing against a baseline - and then stops, producing')
        A('    a decision-ready package. The judgement step is deliberately left to a')
        A('    human and is NOT scripted.')
    A('')

    # parameters in help
    for p in spec.get('params', []):
        A('.PARAMETER ' + p['name'])
        A('    ' + wrap(p['help'], 74, '    '))
        A('')
    if is_dest:
        A('.PARAMETER Execute')
        A('    ' + wrap('Actually perform the destructive action. Without this the script '
                        'only reports what it would do.', 74, '    '))
        A('')
        A('.PARAMETER ProtectedList')
        A('    ' + wrap('Path to a file of names/ids that must never be acted upon, one per '
                        'line. Entries here are excluded unconditionally and the exclusion '
                        'cannot be overridden by any other parameter.', 74, '    '))
        A('')
        A('.PARAMETER MinimumAgeDays')
        A('    ' + wrap('Only consider objects older than this. A conservative default '
                        'guards against acting on something created moments ago.', 74, '    '))
        A('')
    if approval:
        A('.PARAMETER ApprovalReference')
        A('    ' + wrap('Approval token from New-ApprovalRequest, after a human has approved '
                        'it. Without this the script performs no change.', 74, '    '))
        A('')
        A('.PARAMETER RequestApproval')
        A('    ' + wrap('Force REQUEST mode - produce the change set and raise an approval '
                        'request, then stop, even if a reference was supplied.', 74, '    '))
        A('')
        A('.PARAMETER TicketReference')
        A('    ' + wrap('ITSM ticket number recorded in the audit trail alongside the '
                        'approval reference.', 74, '    '))
        A('')
        A('.PARAMETER Reason')
        A('    ' + wrap('Change reason recorded in the approval artifact and the audit log.',
                        74, '    '))
        A('')
    A('.PARAMETER OutputFormat')
    A('    Console, CSV, JSON or HTML.')
    A('')
    A('.PARAMETER OutputPath')
    A('    Destination file for CSV/JSON/HTML output.')
    A('')
    A('.PARAMETER ConfigPath')
    A('    Override the path to Config\\config.json.')
    A('')

    # examples - at least two, real ones
    for ex in spec['examples']:
        A('.EXAMPLE')
        A('    .\\{0}.ps1 {1}'.format(fname, ex[0]))
        A('')
        A('    ' + wrap(ex[1], 74, '    '))
        A('')

    A('.NOTES')
    A('    Source use case      : #{0} - {1}'.format(num, task))
    A('    Category             : {0}'.format(sheet))
    A('    Technology           : {0}'.format(row['tech']))
    A('    Difficulty           : {0}'.format(row['diff']))
    A('    Agent possible       : {0}'.format(row['possible']))
    A('    Can execute with SOP : {0}'.format(row['sop']))
    A('    Automation type      : {0}'.format(atype))
    A('    Risk level           : {0}'.format(risk))
    A('    Human approval needed: {0}'.format('YES' if approval else 'No'))
    A('    Guardrails (col L)   : "{0}"'.format(guard))
    A('')
    A('    Required permissions : {0}'.format(spec.get('perms', 'See the platform SOP.')))
    A('    Required modules     : {0}'.format(', '.join(mods) if mods else 'none beyond IT-Automation-Common'))
    A('    Authentication       : ' + wrap(auth, 52, '                           '))
    if spec.get('notes'):
        A('')
        A('    ' + wrap(spec['notes'], 70, '    '))
    A('')
    A('    Rollback             : ' + wrap(spec.get('rollback', 'Not applicable - this script makes no change.'),
                                           52, '                           '))
    A('#>')
    A('')

    # -------------------------------------------------------- requires ----
    A('#Requires -Version 5.1')
    for m in mods:
        A('#Requires -Modules {0}'.format(m))
    A('')

    # ------------------------------------------------------ cmdletbind ----
    if is_dest:
        A("[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]")
    elif is_change:
        A('[CmdletBinding(SupportsShouldProcess)]')
    else:
        A('[CmdletBinding()]')
    A('[OutputType([PSCustomObject])]')
    A('param(')
    parts = []
    for p in spec.get('params', []):
        parts.append('    ' + p['decl'])
    if is_dest:
        parts.append('    [switch]$Execute')
        parts.append('    [string]$ProtectedList')
        parts.append('    [ValidateRange(0, 3650)]\n    [int]$MinimumAgeDays = {0}'.format(spec.get('minage', 30)))
    if approval:
        parts.append('    [string]$ApprovalReference')
        parts.append('    [switch]$RequestApproval')
        parts.append('    [string]$TicketReference')
        parts.append("    [string]$Reason = '{0}'".format(spec.get('reason', 'Operational automation')))
    parts.append("    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]\n    [string]$OutputFormat = 'Console'")
    parts.append('    [string]$OutputPath')
    parts.append('    [string]$ConfigPath')
    A(',\n\n'.join(parts))
    A(')')
    A('')

    # ------------------------------------------------------------ begin ---
    A('begin {')
    A("    $ErrorActionPreference = 'Stop'")
    A("    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\\..\\Modules\\IT-Automation-Common.psm1') -Force")
    A('')
    A("    $scriptName = '{0}'".format(fname))
    A("    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #{0} ({1})'".format(num, sheet))
    A('')
    A('    try {')
    A('        $config = if ($ConfigPath) { Get-AutomationConfig -Path $ConfigPath } else { Get-AutomationConfig }')
    A('        # Recorded so an audit can tell which environment a run targeted.')
    A("        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (")
    A("            'Configuration loaded for environment: {0}' -f $config.environment)")
    A('    } catch {')
    if is_read:
        A('        # Read-only: config only supplies optional notification endpoints,')
        A('        # so its absence must not stop a report from being produced.')
        A('        $config = $null')
        A('        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (')
        A("            'Config unavailable ({0}); continuing because this script only reads.' -f $_.Exception.Message)")
    else:
        A('        # Fail closed. Safety lists and endpoints live in config; acting')
        A('        # without them would bypass the guardrails this use case requires.')
        A("        throw ('Cannot read configuration, refusing to proceed: {0}' -f $_.Exception.Message)")
    A('    }')
    A('')
    if is_dest:
        A('    $protected = @()')
        A('    if ($ProtectedList -and (Test-Path -LiteralPath $ProtectedList)) {')
        A('        $protected = @(Get-Content -LiteralPath $ProtectedList |')
        A("            Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { $_.Trim() })")
        A("        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (")
        A("            'Protected list loaded: {0} entry(ies). These are excluded unconditionally.' -f $protected.Count)")
        A('    }')
        A('')
    if high_risk:
        A('    # Risk = High: validate before doing anything at all.')
        A('    $pre = Test-Prerequisite{0}'.format(
            ' -RequiredModule ' + ','.join("'%s'" % m for m in mods) if mods else ''))
        A('    if (-not $pre.Passed) {')
        A("        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Message $pre.Summary")
        A('        throw $pre.Summary')
        A('    }')
        A("    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Pre-flight passed.'")
        A('')
    A('    $results  = [System.Collections.Generic.List[PSCustomObject]]::new()')
    A('    $failures = [System.Collections.Generic.List[PSCustomObject]]::new()')
    A('}')
    A('')

    # ---------------------------------------------------------- process ---
    A('process {')
    A('    try {')
    if spec.get('connect', True):
        A("        Connect-AutomationPlatform -Platform '{0}'{1} | Out-Null".format(
            plat_key, ' -Confirm:$false' if False else ''))
        A('')
    for line in spec['discover'].rstrip('\n').split('\n'):
        A('        ' + line if line.strip() else '')
    A('    } catch {')
    A('        $msg = $_.Exception.Message')
    A("        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Message ('Discovery FAILED: {0}' -f $msg)")
    A('        $failures.Add([PSCustomObject]@{ Stage = ' + "'Discovery'; Error = $msg })")
    A('    }')
    A('}')
    A('')

    # -------------------------------------------------------------- end ---
    A('end {')
    A('    $candidates = @($results)')
    A('')
    # Who stops here, and why.
    #
    #   read-only                     -> always stops; there is nothing to act on
    #   assist-only WITHOUT approval  -> stops, because no gate exists to
    #                                    authorise an action, and the workbook
    #                                    says the judgement is a human's
    #   assist-only WITH approval     -> continues to the gated path: the
    #                                    approval IS the human decision point,
    #                                    and the default is still report-only
    #
    # Letting "assist" short-circuit a gated row would declare the approval
    # parameters and never use them - the script would silently be unable to act.
    #
    # 'assist_action' is a deliberate, per-row exception to the middle case. It
    # marks a row where the AUTOMATABLE half is itself a write, and the human
    # judgement happens somewhere the script could not gate even in principle -
    # inside a workflow the script starts, decided by people who are not the
    # operator running it. Access Review campaigns are the example: launching
    # the campaign and chasing reviewers is the automation; the keep/revoke
    # decision belongs to each manager, in the review UI, by design. Forcing
    # such a row to report-only would contradict the workbook, which marks it
    # Change / Write with no approval required. Every use of this flag is listed
    # in MANIFEST.md.
    stops_for_human = is_read or (assists and not approval and not spec.get('assist_action'))

    if stops_for_human:
        if assists:
            A('    # Agent-assist: the package is produced for a human. The script does')
            A('    # NOT proceed to a decision - that step is deliberately not automated.')
            A("    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (")
            A("        'Decision-ready package built: {0} item(s). Human review required.' -f $candidates.Count)")
        A("    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message ('Collected {0} record(s).' -f $candidates.Count)")
        A('    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title ' + "'{0}'".format(task.replace("'", "''")))
        A('    Write-Output $candidates')
        if spec.get('cleanup'):
            A('')
            for line in spec['cleanup'].rstrip('\n').split('\n'):
                A('    ' + line if line.strip() else '')
            A('')
        A("    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'")
        A('    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }')
        A('}')
        return '\n'.join(L) + '\n'

    # -- change / destructive from here -------------------------------------
    if is_dest:
        A('    # Hard exclusions and safety filters BEFORE anything else.')
        A('    if ($protected.Count -gt 0) {')
        A('        $before = $candidates.Count')
        A('        $candidates = @($candidates | Where-Object {')
        A('            $id = $_.Id; $nm = $_.Name')
        A('            -not ($protected | Where-Object { $_ -and ($id -like $_ -or $nm -like $_) })')
        A('        })')
        A('        if ($before -ne $candidates.Count) {')
        A("            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (")
        A("                'Protected list excluded {0} object(s).' -f ($before - $candidates.Count))")
        A('        }')
        A('    }')
        A('    if ($MinimumAgeDays -gt 0) {')
        A('        $cut = (Get-Date).AddDays(-$MinimumAgeDays)')
        A('        $before = $candidates.Count')
        A('        $candidates = @($candidates | Where-Object { -not $_.CreatedAt -or $_.CreatedAt -lt $cut })')
        A('        if ($before -ne $candidates.Count) {')
        A("            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (")
        A("                'Age filter (>{0}d) excluded {1} object(s).' -f $MinimumAgeDays, ($before - $candidates.Count))")
        A('        }')
        A('    }')
        A('')

    # A session opened during discovery has to be closed on EVERY exit path,
    # including the ones that return early without acting.
    def cleanup(pad):
        if not spec.get('cleanup'):
            return
        for line in spec['cleanup'].rstrip('\n').split('\n'):
            A(pad + line if line.strip() else '')

    A('    if ($candidates.Count -eq 0) {')
    A("        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'No eligible objects. Nothing to do.'")
    A('        Write-Output @()')
    cleanup('        ')
    A('        return')
    A('    }')
    A('')
    A('    # Every candidate is logged individually BEFORE any action is taken.')
    A('    foreach ($c in $candidates) {')
    A("        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0}' -f $c.Name) -Message 'CANDIDATE'")
    A('    }')
    A('')

    if approval:
        A('    if ($RequestApproval -or -not $ApprovalReference) {')
        A('        $request = New-ApprovalRequest -ScriptName $scriptName -ChangeSet $candidates `')
        A("            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f " + "'{0}'".format(spec.get('actionVerb', 'Act on').replace("'", "''")) + ", $candidates.Count, $Reason, $TicketReference)")
        A("        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $request.Reference -Message (")
        A("            'REQUEST mode - nothing was changed. Supply -ApprovalReference {0} once approved.' -f $request.Reference)")
        A("        Write-Warning ('No change made. Approval reference: {0}' -f $request.Reference)")
        A('        Write-Output ([PSCustomObject]@{')
        A("            Mode = 'RequestApproval'; ApprovalReference = $request.Reference")
        A('            CandidateCount = $candidates.Count; Candidates = $candidates; Changed = $false })')
        cleanup('        ')
        A('        return')
        A('    }')
        A('')
        A('    $approvalCheck = Test-ApprovalReference -Reference $ApprovalReference -ScriptName $scriptName')
        A('    if (-not $approvalCheck.IsValid) {')
        A("        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $ApprovalReference -Message (")
        A("            'REFUSED to execute: {0}' -f $approvalCheck.Reason)")
        A("        throw ('Approval validation failed: {0}' -f $approvalCheck.Reason)")
        A('    }')
        A("    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $ApprovalReference -Message (")
        A("        'Approval accepted. {0} Ticket={1}' -f $approvalCheck.Reason, $TicketReference)")
        A('')

    if is_dest:
        A('    if (-not $Execute) {')
        A("        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (")
        A("            'REPORT-ONLY - {0} candidate(s) identified, nothing was changed. Pass -Execute to act.' -f $candidates.Count)")
        A('        $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title ' + "'{0} (candidates)'".format(task.replace("'", "''")))
        A('        Write-Output $candidates')
        cleanup('        ')
        A('        return')
        A('    }')
        A('')

    A('    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()')
    A('    foreach ($item in $candidates) {')
    A("        $label = '{0}' -f $item.Name")
    A('        if (-not $PSCmdlet.ShouldProcess($label, ' + "'{0}'".format(spec.get('actionVerb', 'Change').replace("'", "''")) + ')) {')
    A('            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = ' + "'WhatIf'; Detail = 'Not executed'; Succeeded = $true })")
    A('            continue')
    A('        }')
    A('        try {')
    if is_dest and spec.get('backup'):
        A('            # Mandatory pre-action capture, so the object can be restored.')
        for line in spec['backup'].rstrip('\n').split('\n'):
            A('            ' + line if line.strip() else '')
        A('')
    for line in spec['act'].rstrip('\n').split('\n'):
        A('            ' + line if line.strip() else '')
    A('        } catch {')
    A('            $msg = $_.Exception.Message')
    A("            Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $label -Message ('FAILED: {0}' -f $msg)")
    A('            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = ' + "'Failed'; Detail = $msg; Succeeded = $false })")
    A('        }')
    A('    }')
    A('')
    A('    $ok  = @($actions | Where-Object { $_.Succeeded })')
    A('    $bad = @($actions | Where-Object { -not $_.Succeeded })')
    A("    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (")
    A("        'END. Succeeded={0} Failed={1}' -f $ok.Count, $bad.Count)")
    A('')
    A('    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title ' + "'{0}'".format(task.replace("'", "''")))
    A('    Write-Output $actions.ToArray()')
    cleanup('    ')
    A('    if ($bad.Count -gt 0) { exit 1 }')
    A('}')
    return '\n'.join(L) + '\n'


def emit(sheet, rows, specs):
    """Write every spec'd script for one sheet. Returns (written, skipped)."""
    folder = os.path.join(OUT, FOLDER[sheet])
    if not os.path.isdir(folder):
        os.makedirs(folder)
    written, skipped = [], []
    for row in rows:
        n = int(row['num'])
        if n not in specs:
            skipped.append((n, row['task']))
            continue
        spec = specs[n]
        text = build(sheet, row, spec)
        path = os.path.join(folder, spec['file'] + '.ps1')
        with open(path, 'wb') as fh:
            fh.write(b'\xef\xbb\xbf' + text.encode('utf-8'))
        written.append((n, spec['file']))
    return written, skipped


def load_rows():
    return json.load(io.open(os.path.join(ROOT, '_usecases.json'), encoding='utf-8'))
