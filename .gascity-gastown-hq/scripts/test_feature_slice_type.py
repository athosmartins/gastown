#!/usr/bin/env python3
"""Tests for feature_slice_type.py and its step in approved-state-reconciler.py (ga-2xdj1x).

Each case is a shape that was measured or that the bead names: the slice-of-a-feature task that must
become a feature, the controls that must NOT change (a task under a task, a task under a bug, an
ancestor that cannot be read), and the limits that keep a wrong reading from doing damage.

    python3 -m pytest scripts/test_feature_slice_type.py -q
"""
import importlib.util
import json
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import feature_slice_type as fst  # noqa: E402


class FakeStores:
    """In-memory bd for several stores. bd(root, args) -> (rc, stdout) like feature_slice_type.real_bd.

    Knobs, each a failure shape: list_fails (store roots whose `list` returns rc 1), list_garbage (roots
    whose `list` prints non-JSON), show_fails (ids whose `show` returns rc 1), update_rc (rc of `update`),
    update_lies (ids for which `update` says rc 0 and persists NOTHING — the shape a read-back catches),
    comment_rc."""

    def __init__(self, stores, list_fails=(), list_garbage=(), show_fails=(), update_rc=0,
                 update_lies=(), comment_rc=0):
        self.stores = {root: {b["id"]: dict(b) for b in beads} for root, beads in stores.items()}
        self.list_fails, self.show_fails = set(list_fails), set(show_fails)
        self.list_garbage = list_garbage if isinstance(list_garbage, dict) else set(list_garbage)
        self.update_rc, self.update_lies, self.comment_rc = update_rc, set(update_lies), comment_rc
        self.calls = []
        self.comments = []

    def __call__(self, root, args):
        self.calls.append((root, list(args)))
        beads = self.stores.get(root, {})
        verb = args[0]
        if verb == "list":
            if root in self.list_fails:
                return 1, ""
            if root in self.list_garbage:
                return 0, self.list_garbage[root] if isinstance(self.list_garbage, dict) else "Showing 50 issues; not json"
            want_type = args[args.index("--type") + 1]
            want_status = set(args[args.index("--status") + 1].split(","))
            rows = [b for b in beads.values()
                    if b.get("issue_type") == want_type and b.get("status", "open") in want_status]
            return 0, json.dumps(rows)
        if verb == "show":
            if args[1] in self.show_fails:
                return 1, ""
            b = beads.get(args[1])
            return 0, json.dumps([b] if b else [])
        if verb == "update":
            if self.update_rc != 0:
                return self.update_rc, ""
            if args[1] not in self.update_lies and args[1] in beads:
                beads[args[1]]["issue_type"] = args[args.index("--type") + 1]
            return 0, ""
        if verb == "comment":
            self.comments.append((root, args[1], args[2]))
            return self.comment_rc, ""
        raise AssertionError("unexpected bd call: %r" % (args,))

    def writes(self):
        return [c for c in self.calls if c[1][0] in ("update", "comment")]

    def type_of(self, root, bead_id):
        return self.stores[root][bead_id]["issue_type"]


def bead(bead_id, issue_type="task", parent=None, status="open", **extra):
    d = {"id": bead_id, "issue_type": issue_type, "status": status, "title": "t " + bead_id}
    if parent:
        d["parent"] = parent
    d.update(extra)
    return d


R = "/city/hq"


def run(stores, **kw):
    fake = stores if isinstance(stores, FakeStores) else FakeStores(stores)
    kw.setdefault("log", lambda m: None)
    counters = fst.sweep(list(fake.stores), fake, **kw)
    return fake, counters


# ── parent_id: the field, else the dotted id ─────────────────────────────────

def test_parent_field_wins_over_the_dotted_id():
    assert fst.parent_id({"id": "ga-x.1", "parent": "ga-other"}) == "ga-other"


def test_parent_from_a_dotted_id_two_and_three_levels():
    assert fst.parent_id({"id": "wa-d3ys32.2.1"}) == "wa-d3ys32.2"
    assert fst.parent_id({"id": "ga-m9x0lb.2"}) == "ga-m9x0lb"


def test_a_root_has_no_parent():
    assert fst.parent_id({"id": "ga-2xdj1x"}) is None
    assert fst.parent_id({"id": "ga-2xdj1x", "parent": ""}) is None


def test_a_dot_that_is_not_a_numeric_tail_is_not_a_parent():
    assert fst.parent_id({"id": "mol-foo.step"}) is None


def test_a_malformed_parent_field_is_not_the_same_as_no_parent():
    with pytest.raises(fst._Unreadable):
        fst.parent_id({"id": "ga-x.1", "parent": {"id": "ga-x"}})


# ── the verdict: three answers, never collapsed ──────────────────────────────

def lookup_of(*beads):
    table = {b["id"]: b for b in beads}
    return lambda i: ("ok", table[i]) if i in table else ("missing", None)


def test_task_under_a_feature_is_a_slice_of_it():
    f = bead("ga-f")
    f["issue_type"] = "feature"
    assert fst.ancestor_verdict(bead("ga-f.1", parent="ga-f"), lookup_of(f)) == (fst.FEATURE, "ga-f")


def test_a_slice_of_a_slice_climbs_through_the_task_in_the_middle():
    f = bead("ga-f", "feature")
    mid = bead("ga-f.2", parent="ga-f")        # a slice that is still a task
    assert fst.ancestor_verdict(bead("ga-f.2.1", parent="ga-f.2"), lookup_of(f, mid)) == (fst.FEATURE, "ga-f")


def test_CONTROL_task_under_a_task_stays_a_task():
    root = bead("ga-t")
    assert fst.ancestor_verdict(bead("ga-t.1", parent="ga-t"), lookup_of(root))[0] == fst.NO_FEATURE


def test_CONTROL_task_under_a_bug_stays_a_task():
    assert fst.ancestor_verdict(bead("ga-b.1", parent="ga-b"), lookup_of(bead("ga-b", "bug")))[0] == fst.NO_FEATURE


def test_CONTROL_an_epic_above_is_not_enough():
    assert fst.ancestor_verdict(bead("wa-e.4", parent="wa-e"), lookup_of(bead("wa-e", "epic")))[0] == fst.NO_FEATURE


def test_the_nearest_non_task_ancestor_decides_a_bug_between_task_and_feature():
    f, b = bead("ga-f", "feature"), bead("ga-f.1", "bug", parent="ga-f")
    assert fst.ancestor_verdict(bead("ga-f.1.1", parent="ga-f.1"), lookup_of(f, b))[0] == fst.NO_FEATURE


def test_CONTROL_ancestor_that_cannot_be_read_is_unreadable_not_no_feature():
    v = fst.ancestor_verdict(bead("ga-f.1", parent="ga-f"), lambda i: ("error", None))
    assert v[0] == fst.UNREADABLE


def test_ancestor_that_is_gone_is_unreadable_too():
    assert fst.ancestor_verdict(bead("ga-f.1", parent="ga-f"), lookup_of())[0] == fst.UNREADABLE


def test_unreadable_in_the_middle_of_the_climb_wins_even_if_a_feature_may_be_above():
    mid = bead("ga-f.2", parent="ga-f")
    lk = lambda i: ("ok", mid) if i == "ga-f.2" else ("error", None)       # ga-f itself unreadable
    assert fst.ancestor_verdict(bead("ga-f.2.1", parent="ga-f.2"), lk)[0] == fst.UNREADABLE


def test_ancestor_without_a_type_is_unreadable():
    no_type = {"id": "ga-f", "title": "x"}
    assert fst.ancestor_verdict(bead("ga-f.1", parent="ga-f"), lookup_of(no_type))[0] == fst.UNREADABLE


def test_a_cycle_is_unreadable_not_a_loop():
    a, b = bead("ga-a", parent="ga-b"), bead("ga-b", parent="ga-a")
    assert fst.ancestor_verdict(a, lookup_of(a, b))[0] == fst.UNREADABLE


def test_a_chain_deeper_than_the_limit_is_unreadable():
    chain = [bead("ga-n%d" % i, parent="ga-n%d" % (i + 1)) for i in range(fst.MAX_CLIMB + 2)]
    assert fst.ancestor_verdict(chain[0], lookup_of(*chain))[0] == fst.UNREADABLE


# ── the sweep ────────────────────────────────────────────────────────────────

def test_sweep_retypes_a_slice_of_a_feature_and_says_why():
    fake, c = run({R: [bead("ga-f", "feature"), bead("ga-f.1", parent="ga-f")]})
    assert fake.type_of(R, "ga-f.1") == "feature"
    assert (c["fixed"], c["write_failed"]) == (1, 0)
    assert len(fake.comments) == 1 and "ga-f" in fake.comments[0][2] and "feature" in fake.comments[0][2]


def test_sweep_uses_a_closed_ancestor_that_the_open_listing_does_not_hold():
    # the parent is closed (not in the open listing): it is found with `show`, as live data needs
    fake, c = run({R: [bead("ga-f", "feature", status="closed"), bead("ga-f.3", parent="ga-f")]})
    assert fake.type_of(R, "ga-f.3") == "feature" and c["fixed"] == 1


def test_sweep_CONTROL_leaves_task_under_task_and_task_under_bug_alone():
    fake, c = run({R: [bead("ga-t"), bead("ga-t.1", parent="ga-t"),
                       bead("ga-b", "bug"), bead("ga-b.1", parent="ga-b")]})
    assert fake.writes() == []
    assert (c["fixed"], c["no_feature"]) == (0, 2)


def test_sweep_CONTROL_unreadable_ancestor_changes_nothing_and_is_counted():
    fake = FakeStores({R: [bead("ga-f", "feature"), bead("ga-f.1", parent="ga-f"), bead("ga-g.1", parent="ga-g")]},
                      show_fails={"ga-f"})
    _, c = run(fake)
    assert fake.writes() == []
    assert c["unreadable"] == 2 and sorted(c["unreadable_ids"]) == ["ga-f.1", "ga-g.1"]
    assert c["fixed"] == 0 and c["no_feature"] == 0


def test_sweep_dry_run_logs_and_writes_nothing():
    msgs = []
    fake, c = run({R: [bead("ga-f", "feature"), bead("ga-f.1", parent="ga-f")]}, dry_run=True, log=msgs.append)
    assert fake.writes() == [] and fake.type_of(R, "ga-f.1") == "task"
    assert (c["would_fix"], c["fixed"]) == (1, 0)
    assert any("DRY_RUN" in m and "ga-f.1" in m for m in msgs)


def test_sweep_audit_form_classifies_and_never_writes():
    fake, c = run({R: [bead("ga-f", "feature"), bead("ga-f.1", parent="ga-f")]}, apply=False)
    assert fake.writes() == [] and c["feature"] == 1 and c["feature_ids"] == ["ga-f.1"]


def test_sweep_a_write_that_does_not_persist_is_failed_not_fixed():
    # bd said rc 0 and kept the old type — the read-back is what tells (bd's return code has lied before)
    fake = FakeStores({R: [bead("ga-f", "feature"), bead("ga-f.1", parent="ga-f")]}, update_lies={"ga-f.1"})
    _, c = run(fake)
    assert (c["fixed"], c["write_failed"]) == (0, 1)
    assert fake.comments == []                     # no "retyped" comment on a bead that was not retyped


def test_sweep_a_failing_update_is_failed_and_does_not_comment():
    fake = FakeStores({R: [bead("ga-f", "feature"), bead("ga-f.1", parent="ga-f")]}, update_rc=1)
    _, c = run(fake)
    assert (c["fixed"], c["write_failed"]) == (0, 1) and fake.comments == []


def test_sweep_a_comment_that_fails_does_not_undo_the_retype():
    fake = FakeStores({R: [bead("ga-f", "feature"), bead("ga-f.1", parent="ga-f")]}, comment_rc=1)
    _, c = run(fake)
    assert fake.type_of(R, "ga-f.1") == "feature" and c["fixed"] == 1


def test_sweep_cap_bounds_the_attempts_of_one_cycle():
    beads = [bead("ga-f", "feature")] + [bead("ga-f.%d" % i, parent="ga-f") for i in range(1, 6)]
    fake, c = run({R: beads}, max_fixes=2)
    assert (c["fixed"], c["deferred"]) == (2, 3)
    assert sum(1 for b in fake.stores[R].values() if b["issue_type"] == "task") == 3


def test_sweep_a_store_that_cannot_be_listed_is_counted_and_the_others_still_run():
    other = "/city/wa"
    fake = FakeStores({R: [bead("ga-f", "feature"), bead("ga-f.1", parent="ga-f")],
                       other: [bead("wa-f", "feature"), bead("wa-f.1", parent="wa-f")]}, list_fails={R})
    _, c = run(fake)
    assert c["stores_unreadable"] == 1 and c["fixed"] == 1
    assert fake.type_of(other, "wa-f.1") == "feature" and fake.type_of(R, "ga-f.1") == "task"


def test_sweep_a_listing_that_is_not_json_is_an_unreadable_store_not_zero_tasks():
    fake = FakeStores({R: [bead("ga-f", "feature"), bead("ga-f.1", parent="ga-f")]}, list_garbage={R})
    _, c = run(fake)
    assert c["stores_unreadable"] == 1 and c["tasks"] == 0 and fake.writes() == []


@pytest.mark.parametrize("payload", ['{"error": "database is locked"}', "42", '{"issues": null}', '"nope"'])
def test_sweep_valid_json_of_the_wrong_shape_is_an_unreadable_store_not_zero_tasks(payload):
    # rc 0 and parseable, but not a list of beads: an error object must not read as "no tasks here"
    fake = FakeStores({R: [bead("ga-f", "feature"), bead("ga-f.1", parent="ga-f")]}, list_garbage={R: payload})
    _, c = run(fake)
    assert c["stores_unreadable"] == 1 and c["tasks"] == 0 and fake.writes() == []


def test_sweep_an_empty_store_is_a_real_answer_not_an_error():
    _, c = run({R: []})
    assert c["stores_unreadable"] == 0 and c["tasks"] == 0


def test_sweep_never_touches_a_workflow_bead_even_with_a_feature_parent():
    fake, c = run({R: [bead("ga-f", "feature"),
                       bead("ga-f.1", parent="ga-f", metadata={"molecule_id": "ga-mol"}),
                       bead("ga-f.2", parent="ga-f", metadata={"gc.root_bead_id": "ga-root"})]})
    assert fake.writes() == [] and c["skipped_workflow"] == 2


def test_sweep_a_routing_metadata_alone_does_not_exempt_a_slice():
    # gc.routed_to is on ordinary beads (it is how a pool bead is routed); it is not a workflow marker
    fake, c = run({R: [bead("ga-f", "feature"),
                       bead("ga-f.1", parent="ga-f", metadata={"gc.routed_to": "gastown.dog"})]})
    assert fake.type_of(R, "ga-f.1") == "feature" and c["fixed"] == 1


def test_sweep_is_idempotent_the_second_pass_finds_nothing_to_do():
    fake, _ = run({R: [bead("ga-f", "feature"), bead("ga-f.1", parent="ga-f"), bead("ga-f.2", parent="ga-f")]})
    n = len(fake.comments)
    c2 = fst.sweep(list(fake.stores), fake, log=lambda m: None)
    assert c2["fixed"] == 0 and c2["feature"] == 0 and len(fake.comments) == n


def test_sweep_asks_for_every_open_status_and_all_rows():
    fake, _ = run({R: []})
    args = fake.calls[0][1]
    assert args[args.index("--status") + 1] == "open,in_progress,blocked,deferred"
    assert args[args.index("--limit") + 1] == "0"          # bd list truncates at 50 without it (ga-21kmp)


def test_sweep_works_from_the_dotted_id_when_bd_gives_no_parent_field():
    fake, c = run({R: [bead("wa-d3ys32", "feature"), bead("wa-d3ys32.2"), bead("wa-d3ys32.2.1")]})
    assert fake.type_of(R, "wa-d3ys32.2") == "feature" and fake.type_of(R, "wa-d3ys32.2.1") == "feature"
    assert c["fixed"] == 2


# ── the step inside approved-state-reconciler.py ─────────────────────────────

@pytest.fixture
def arc(monkeypatch):
    spec = importlib.util.spec_from_file_location("arc_under_test", os.path.join(HERE, "approved-state-reconciler.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    monkeypatch.setattr(m, "RIG_ROOTS", [R])
    monkeypatch.setattr(m, "DRY_RUN", False)
    monkeypatch.setattr(m, "FEATURE_SLICE_TYPE_ENABLED", True)
    monkeypatch.setattr(m, "_bd_approved", None)
    monkeypatch.setattr(m, "_bd_slice_run", None)
    return m


def test_step_retypes_through_the_seam_and_keeps_the_counters_in_state(arc):
    fake = FakeStores({R: [bead("ga-f", "feature"), bead("ga-f.1", parent="ga-f")]})
    arc._bd_slice_run = fake
    state = {}
    c = arc._sweep_feature_slice_types(1234.0, state)
    assert c["fixed"] == 1 and fake.type_of(R, "ga-f.1") == "feature"
    assert state["slice_type_last"]["fixed"] == 1 and state["slice_type_last"]["ts"] == 1234.0
    assert "unreadable_ids" not in state["slice_type_last"]        # lists stay out of the state file


def test_step_honours_the_reconciler_dry_run(arc):
    fake = FakeStores({R: [bead("ga-f", "feature"), bead("ga-f.1", parent="ga-f")]})
    arc._bd_slice_run, arc.DRY_RUN = fake, True
    c = arc._sweep_feature_slice_types()
    assert fake.writes() == [] and c["would_fix"] == 1


def test_step_has_its_own_kill_switch(arc):
    fake = FakeStores({R: [bead("ga-f", "feature"), bead("ga-f.1", parent="ga-f")]})
    arc._bd_slice_run, arc.FEATURE_SLICE_TYPE_ENABLED = fake, False
    assert arc._sweep_feature_slice_types() is None and fake.calls == []


def test_step_stays_out_of_the_stubbed_world_of_the_reconciler_selftest(arc, monkeypatch):
    # ~100 hermetic scenarios stub _bd_approved and never expect a live bd: no seam of its own -> no bd call
    monkeypatch.setattr(fst, "real_bd", lambda *a, **k: pytest.fail("the step reached a live bd from a stubbed world"))
    arc._bd_approved = lambda root: []
    assert arc._sweep_feature_slice_types() is None


def _hermetic_cycle(arc, monkeypatch):
    """run_cycle with every read outside the step stubbed. RIG_ROOTS names a directory that does not exist,
    so the story:approved loop skips it ("directory not found") and only the slice-type step uses the seam."""
    for name in ("_is_pilot_alive", "_gate_marker_source_beads", "_gate_queue_depth", "_gate_queue_throughput",
                 "_read_pilot_dispatchable", "_read_pilot_sweep_pause_state", "_pilot_cap_evidence"):
        monkeypatch.setattr(arc, name, lambda *a, **k: None)
    monkeypatch.setattr(arc, "RIG_ROOTS", [R])


def test_run_cycle_runs_the_step(arc, monkeypatch):
    _hermetic_cycle(arc, monkeypatch)
    arc._bd_slice_run = FakeStores({R: [bead("ga-f", "feature"), bead("ga-f.1", parent="ga-f")]})
    state = {}
    assert arc.run_cycle(1000.0, state) == (0, 0, 0)
    assert arc._bd_slice_run.type_of(R, "ga-f.1") == "feature"
    assert state["slice_type_last"]["fixed"] == 1


def test_run_cycle_survives_a_crash_in_the_step_and_says_so(arc, monkeypatch, capsys):
    _hermetic_cycle(arc, monkeypatch)
    arc._bd_slice_run = FakeStores({})
    monkeypatch.setattr(arc.feature_slice_type, "sweep", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom")))
    assert arc.run_cycle(1000.0, {}) == (0, 0, 0)
    out = capsys.readouterr().out
    assert "slice-type step UNEXPECTED ERROR" in out and "cycle done" in out


def test_a_typo_in_the_cap_env_does_not_stop_the_reconciler_at_import(monkeypatch):
    monkeypatch.setenv("ARC_FEATURE_SLICE_TYPE_MAX_FIXES", "lots")
    spec = importlib.util.spec_from_file_location("arc_typo", os.path.join(HERE, "approved-state-reconciler.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    assert m.FEATURE_SLICE_TYPE_MAX_FIXES == fst.DEFAULT_MAX_FIXES
