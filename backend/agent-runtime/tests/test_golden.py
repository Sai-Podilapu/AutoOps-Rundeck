"""Runs the golden cases as part of the ordinary test suite.

The harness has a CLI of its own (``python -m evals.replay check``) for when you
want to look at a diff. This exists so that nobody has to remember to: a prompt
edit that changes how a real recorded run behaves fails ``pytest`` like any
other regression.
"""

from __future__ import annotations

import pytest

from evals import cases, replay


def _paths():
    found = cases.discover(replay.GOLDEN)
    assert found, (
        f"No golden cases in {replay.GOLDEN}. An empty regression suite passes "
        f"silently, which is worse than no suite at all."
    )
    return found


@pytest.mark.parametrize("path", _paths(), ids=lambda path: path.stem)
def test_recorded_behaviour_has_not_changed(path):
    case = cases.load(path)
    failures = replay.run_case(case)

    assert not failures, "\n" + "\n".join(str(failure) for failure in failures)
