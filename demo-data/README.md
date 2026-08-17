# Demo data — Meridian Commercial Bank

Realistic banking-operations dataset for the AutoOps demo. Everything cross-references, so
clicking through tells one story rather than showing seven unrelated lists.

| File | Contents |
|---|---|
| `overview.json` | Project KPIs, four value highlights, three live "needs attention" items, and a suggested walkthrough order |
| `jobs.json` | 12 jobs — EOD close, SWIFT, NEFT/RTGS recon, card settlement, AML feed, KYC sweep, ATM cash, regulatory extract, statements, DR verify, dormant accounts, nostro sweep (paused) |
| `workflows.json` | 7 workflows — onboarding, payment exception repair, fraud triage, loan decisioning, regulatory reporting, change release, DR drill |
| `ai-workflows.json` | 4 Dify-backed — AML disposition, complaint triage, payment RCA, KYC extraction |
| `agents.json` | 2 agents — Banking Ops Copilot, Compliance Research Analyst (both with explicit guardrails) |
| `schedule.json` | 3 schedules — EOD chain, 15-minute AML screening, month-end regulatory filing |
| `executions.json` | 10 recent runs — success, failed, running, awaiting approval, rolled back |

## The through-line

The NEFT reconciliation job **fails** (`run-10494`, 14 breaks / ₹2.41 Cr) → that failure
**triggers** the Payment Exception Repair workflow (`run-10496`, currently running) → which
auto-repairs 9 and **holds 5 at a payments-desk approval gate**. That single thread is the
strongest thing to demo: detection, automated response, and a human where money moves.

Second thread: onboarding (`run-10486`) is **held on a possible PEP match** rather than
auto-creating the account — the control working, not a failure.

## Three banking-specific points worth saying out loud

1. **Maker-checker is native.** EOD close, regulatory filing, dormant classification and loan
   decisioning all carry `requiresApproval`. A bank never lets one person rerun the ledger.
2. **AI drafts, humans decide.** The AML assistant writes the disposition narrative; the
   analyst signs it. Both agents list what they *cannot* do. Every compliance officer in the
   room will ask this — answer before they do.
3. **Deadlines are regulatory, not operational.** The month-end filing has a hard date and a
   CFO sign-off gate; late filing is a reportable breach.

## Status

These are **data files, not loaded into the running app.** The UI still serves its own mock
layer. Use them as the script and the numbers to talk to, or ask for them to be wired into
`frontend-web/src/lib/dify/difyApi.js` and the mock collections — not something to attempt
minutes before a demo.
