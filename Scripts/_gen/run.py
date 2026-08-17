# -*- coding: utf-8 -*-
"""Generate scripts for whichever spec modules are present."""
import sys, os, importlib
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import engine

SHEET_MODULE = [
    ('AWS', 'spec_aws'),
    ('Azure', 'spec_azure'),
    ('Azure AVD', 'spec_avd'),
    ('OCI', 'spec_oci'),
    ('M365', 'spec_m365'),
    ('Security Cloud', 'spec_seccloud'),
    ('Network Devices', 'spec_network'),
    ('Backup Commvault', 'spec_commvault'),
    ('Hyper-V', 'spec_hyperv'),
    ('VMware OnPrem', 'spec_vmware'),
    ('Exchange & O365', 'spec_exchange'),
    ('AD & Identity', 'spec_adid'),
]

rows = engine.load_rows()
total_w = total_s = 0
for sheet, mod in SHEET_MODULE:
    try:
        m = importlib.import_module(mod)
    except ImportError:
        continue
    w, s = engine.emit(sheet, rows[sheet], m.SPECS)
    total_w += len(w)
    total_s += len(s)
    print('%-18s written=%-3d pending=%d' % (sheet, len(w), len(s)))
    for n, t in s:
        print('        pending #%s %s' % (n, t[:60]))
print('-' * 50)
print('TOTAL written=%d pending=%d' % (total_w, total_s))
