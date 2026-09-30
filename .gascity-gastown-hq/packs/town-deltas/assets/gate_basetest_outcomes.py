"""pytest plugin for the gate's base-commit test check (ga-kisvqp).

Loaded with ``-p gate_basetest_outcomes`` by quality-gate-guard.sh, from a copy in the run's
scratch dir (never from this directory: putting this directory on PYTHONPATH would expose every
sibling script as an importable module and could shadow the test's own imports).

It records ONE outcome per test node -- pass | fail | skip | collect-error -- and writes them as
JSON lines to the path in $GATE_BT_OUTCOMES, in a single step at session end, closed by an
``{"end": true}`` line. The single step is the point: the reader treats a file without the end
line as a run it could not read, so a pytest killed by the timeout, or one that crashed, can never
leave behind a partial file that looks like "these were all the tests".

Outcome per node is the WORST of its setup/call/teardown phases (a test that passed and then
failed in teardown is a failure). A collection error is keyed by the file's node id, and a
module-level skip (``pytest.importorskip`` of a missing dependency) is recorded as a skip -- the
file did not run, which is not the same as the file having no tests.
"""
import json
import os

_RANK = {"pass": 0, "skip": 1, "fail": 2, "collect-error": 3}
_results = {}


def _put(nodeid, outcome):
    prev = _results.get(nodeid)
    if prev is None or _RANK[outcome] > _RANK[prev]:
        _results[nodeid] = outcome


def pytest_runtest_logreport(report):
    if report.when == "call":
        if report.passed:
            outcome = "pass"
        elif report.skipped:
            outcome = "skip"  # skip and xfail both land here: neither is evidence either way
        else:
            outcome = "fail"
    elif report.failed:
        outcome = "fail"  # setup or teardown error
    elif report.skipped and report.when == "setup":
        outcome = "skip"
    else:
        return
    _put(report.nodeid, outcome)


def pytest_collectreport(report):
    if report.failed:
        _put(report.nodeid or "<collection>", "collect-error")
    elif report.skipped:
        _put(report.nodeid or "<collection>", "skip")


def pytest_sessionfinish(session):
    path = os.environ.get("GATE_BT_OUTCOMES")
    if not path:
        return
    tmp = path + ".part"
    with open(tmp, "w") as f:
        for nodeid, outcome in _results.items():
            f.write(json.dumps({"id": nodeid, "o": outcome}) + "\n")
        f.write(json.dumps({"end": True, "n": len(_results)}) + "\n")
    os.replace(tmp, path)
