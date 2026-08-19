"""Replay recorded runs against this build.

Two modes, answering two different questions.

``check`` — the regression gate. Runs every golden case with its recorded model
replies, so nothing varies except our own code, and reports any step whose
directive, phase, tool calls or citations moved. Fast, free, no credentials,
safe in CI. This is the one that should block a merge.

``compare`` — the judgement call. Takes the state of a REAL run out of
``agent_runs.transcript`` and re-reduces it live against whatever model or agent
version you name, then prints what changed. It costs tokens and gives a
different answer every time, which is exactly why it is a manual act and not a
test: it tells you whether a prompt change is an improvement, and only a person
can decide that.

    python -m evals.replay check
    python -m evals.replay check --dir evals/golden --verbose
    python -m evals.replay compare --state run-812.json --model claude-sonnet-5
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path

from agent_runtime.app.reduce import reduce
from agent_runtime.app.state import ReduceRequest, Vendor
from evals import cases

GOLDEN = Path(__file__).parent / "golden"


@dataclass
class Failure:
    case: str
    step: int
    field: str
    expected: object
    actual: object

    def __str__(self) -> str:
        return (
            f"  {self.case} step {self.step}: {self.field}\n"
            f"      expected: {self.expected!r}\n"
            f"      actual:   {self.actual!r}"
        )


class _Scripted:
    """The recorded model. Mirrors what the runtime asks of a real one."""

    def __init__(self, script: list):
        self.script = list(script)
        self.exhausted = False

    def _next(self):
        if not self.script:
            self.exhausted = True
            raise AssertionError("the case ran out of recorded model replies")
        return self.script.pop(0)

    def invoke(self, messages, config=None):
        return self._next()

    def bind_tools(self, tools):
        return self

    def with_structured_output(self, schema, include_raw=False):
        return _Structured(self, include_raw)


class _Structured:
    def __init__(self, model: _Scripted, include_raw: bool = False):
        self.model = model
        self.include_raw = include_raw

    def invoke(self, messages, config=None):
        parsed = self.model._next()
        if not self.include_raw:
            return parsed
        return {"raw": None, "parsed": parsed, "parsing_error": None}


def run_case(case: cases.Case) -> list[Failure]:
    """Drives one case end to end and returns everything that moved."""
    import agent_runtime.graph.context as context

    failures: list[Failure] = []
    state = None
    original = context.build_model

    for index, step in enumerate(case.steps, start=1):
        model = _Scripted(step.script)
        context.build_model = lambda *args, **kwargs: model
        try:
            response = reduce(
                ReduceRequest(
                    agent=case.agent,
                    tools=case.tools,
                    state=state,
                    event=step.event,
                    unavailable=case.unavailable,
                )
            )
        finally:
            context.build_model = original

        state = response.state
        failures.extend(_compare(case.name, index, step.expect, response))

        if response.directive.value in {"FINISH", "FAIL"} and index < len(case.steps):
            failures.append(
                Failure(case.name, index, "directive",
                        "a non-terminal directive (more steps recorded)",
                        response.directive.value)
            )
            break

    return failures


def _compare(name: str, index: int, expect: cases.Expectation, response) -> list[Failure]:
    found: list[Failure] = []

    def check(field: str, expected, actual):
        if expected is not None and expected != actual:
            found.append(Failure(name, index, field, expected, actual))

    check("directive", expect.directive, response.directive.value)
    check("phase", expect.phase, response.phase.value)
    check("tool_calls", expect.tool_calls, [call.name for call in response.tool_calls])
    check("citations", expect.citations, response.citations)
    if expect.has_uncited is not None:
        check("has_uncited", expect.has_uncited, bool(response.uncited_claims))

    for fragment in expect.output_contains:
        if fragment not in (response.output or ""):
            found.append(Failure(name, index, "output_contains", fragment, response.output))

    return found


def check(directory: Path, verbose: bool) -> int:
    paths = cases.discover(directory)
    if not paths:
        print(f"No cases in {directory}. Nothing to check — that is a gap, not a pass.")
        return 1

    failures: list[Failure] = []
    for path in paths:
        try:
            case = cases.load(path)
        except cases.BadCase as exc:
            print(f"UNREADABLE {path.name}: {exc}")
            failures.append(Failure(path.name, 0, "case", "a readable case", str(exc)))
            continue

        result = run_case(case)
        failures.extend(result)
        status = "ok" if not result else f"{len(result)} difference(s)"
        if verbose or result:
            print(f"{'PASS' if not result else 'FAIL'}  {case.name}  ({len(case.steps)} steps, {status})")

    print()
    if failures:
        print(f"{len(failures)} difference(s) from the recorded behaviour:\n")
        for failure in failures:
            print(failure)
        return 1

    print(f"{len(paths)} case(s) replayed with no change in behaviour.")
    return 0


def compare(state_path: Path, model: str, vendor: str, ref: str) -> int:
    """Re-reduce a real run's state live. Costs tokens; needs a real key."""
    key = os.environ.get("EVAL_API_KEY", "")
    if not key:
        print("Set EVAL_API_KEY to the vendor key this comparison should bill.")
        return 2

    saved = json.loads(state_path.read_text(encoding="utf-8"))
    # Accept either a bare state blob or a whole `agent_runs` row dumped as
    # JSON, because the second is what you get straight out of a database
    # client and re-shaping it by hand is exactly the friction that stops
    # anyone running this.
    state = saved.get("transcript", saved)
    if isinstance(state, str):
        state = json.loads(state)

    response = reduce(
        ReduceRequest(
            agent={
                "ref": ref,
                "model": model,
                "vendor": Vendor(vendor),
                "credentials": {"apiKey": key},
            },
            tools=saved.get("tools", []),
            state=state,
            event={"kind": "TOOL_RESULTS", "results": []},
        )
    )

    print(f"directive : {response.directive.value}")
    print(f"phase     : {response.phase.value}")
    print(f"citations : {response.citations}")
    print(f"tokens    : {response.usage.prompt_tokens} in, {response.usage.completion_tokens} out")
    if response.uncited_claims:
        print(f"UNCITED   : {response.uncited_claims}")
    if response.error:
        print(f"error     : {response.error}")
    print("\n--- output ---")
    print(response.output or "(none)")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="evals.replay", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    checker = sub.add_parser("check", help="replay the golden cases offline")
    checker.add_argument("--dir", type=Path, default=GOLDEN)
    checker.add_argument("--verbose", action="store_true")

    live = sub.add_parser("compare", help="re-reduce a real run against a live model")
    live.add_argument("--state", type=Path, required=True)
    live.add_argument("--model", required=True)
    live.add_argument("--vendor", default="ANTHROPIC")
    live.add_argument("--ref", default="linux.server_health_check")

    args = parser.parse_args(argv)
    if args.command == "check":
        return check(args.dir, args.verbose)
    return compare(args.state, args.model, args.vendor, args.ref)


if __name__ == "__main__":
    sys.exit(main())
