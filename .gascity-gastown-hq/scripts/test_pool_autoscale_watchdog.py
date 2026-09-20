#!/usr/bin/env python3
"""Tests for pool-autoscale-watchdog.py's demand count (ga-uv4on5).

THE BUG. get_pool_demand() counted every ready, unassigned bead routed to the
pool. A pool worker's own probe (the engine-rendered Step-1c work query)
deliberately refuses a long list of beads -- held, vetoed, parked, epics -- so
those beads were "demand" the dogs could never claim. Demand never reached 0
(the state file's demand_first_seen_ts sat at 2026-08-30 for 20 days), the
watchdog woke a dog every cycle, and the dog found an empty queue and exited.

Only the process boundary is faked here (bd, gc, notify, the session-list
shim). The demand predicate under test is the real code. The fake `bd ready`
applies the flags that matter (--exclude-label, --limit, --unassigned, ...) the
way the real bd does: exclusions are applied server-side BEFORE --limit, which
was checked against the live bd while writing this file.
"""
import importlib.util
import itertools
import json
import os
import random
import re
import shutil
import subprocess
import time

import pytest

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
MOD_PATH = os.path.join(SCRIPTS, "pool-autoscale-watchdog.py")
POOL = "gastown.dog"

NOW = int(time.time())
PAST = NOW - 3600       # an epoch an hour ago: a Pilot hold whose time box ran out
FUTURE = NOW + 3600     # a hold that is still running

# Identity a pool worker session carries. `gc hook` reads these to also return
# work assigned to the CALLER, which must never leak into a pool-wide question.
IDENTITY_ENV = ("GC_SESSION_ID", "GC_SESSION_NAME", "GC_ALIAS",
                "GC_SESSION_ORIGIN", "GC_AGENT", "GC_TEMPLATE")


# ---------------------------------------------------------------------------
# Fixtures / doubles
# ---------------------------------------------------------------------------

def bead(bead_id, labels=(), title="repair the thing", routed_to=POOL,
         issue_type="bug", created_at="2026-09-15T08:23:38Z"):
    """One `bd ready --json` row, with every field the real command emits."""
    return {
        "id": bead_id,
        "title": title,
        "description": "Full description of the work.",
        "status": "open",
        "priority": 2,
        "issue_type": issue_type,
        "owner": "gastown.dog-1@gascity.local",
        "created_at": created_at,
        "created_by": "automation",
        "updated_at": "2026-09-20T15:21:52Z",
        "metadata": {"gc.routed_to": routed_to},
        "labels": list(labels),
        "dependency_count": 0,
        "dependent_count": 0,
        "comment_count": 0,
    }


def _done(argv, rc, out="", err=""):
    return subprocess.CompletedProcess(args=argv, returncode=rc, stdout=out, stderr=err)


class FakeCLI:
    """Stands in for subprocess.run. Records every call; refuses unknown ones."""

    def __init__(self):
        self.beads = []                       # what `bd ready` can see, before flags apply
        self.honor_exclude_labels = True      # False = a bd that silently ignores the flag
        self.bd_rc = 0
        self.bd_stdout = None                 # raw stdout override (malformed-output cases)
        self.bd_raises = None
        # (rc, stdout, stderr) of `gc hook <pool>`; default = "work exists"
        self.hook = (0, json.dumps([bead("ga-x")]), "")
        self.hook_raises = None
        self.hook_calls = []                  # [(argv, effective_env)]
        self.sessions = []
        self.calls = []

    def __call__(self, argv, **kwargs):
        self.calls.append(list(argv))
        if argv[:2] == ["bd", "ready"]:
            return self._bd_ready(argv)
        if argv[:2] == ["gc", "hook"]:
            env = kwargs.get("env")
            self.hook_calls.append((list(argv), dict(os.environ if env is None else env)))
            if self.hook_raises is not None:
                raise self.hook_raises
            return _done(argv, *self.hook)
        if argv[0] == "bash" and argv[1].endswith("gc-session-list-cached.sh"):
            return _done(argv, 0, json.dumps({"sessions": self.sessions}))
        if argv[:3] in (["gc", "session", "wake"], ["gc", "session", "pin"],
                        ["gc", "session", "unpin"]):
            return _done(argv, 0)
        if argv[0].endswith("/notify"):
            return _done(argv, 0)             # never send a real push from a test
        raise AssertionError("unexpected subprocess call: %r" % (argv,))

    def _bd_ready(self, argv):
        if self.bd_raises is not None:
            raise self.bd_raises
        if self.bd_rc != 0:
            return _done(argv, self.bd_rc, "", "bd: store unavailable")
        if self.bd_stdout is not None:
            return _done(argv, 0, self.bd_stdout)
        args, meta, exclude_labels, exclude_types = argv[2:], {}, set(), set()
        unassigned, limit, i = False, 50, 0
        while i < len(args):
            a = args[i]
            if a == "--metadata-field":
                k, v = args[i + 1].split("=", 1)
                meta[k] = v
                i += 2
            elif a == "--exclude-label":
                exclude_labels.add(args[i + 1])
                i += 2
            elif a.startswith("--exclude-type="):
                exclude_types.add(a.split("=", 1)[1])
                i += 1
            elif a == "--unassigned" or a == "--json":
                unassigned = unassigned or a == "--unassigned"
                i += 1
            elif a == "--sort":
                assert args[i + 1] == "oldest", "fake bd only knows --sort oldest"
                i += 2
            elif a.startswith("--limit="):
                limit = int(a.split("=", 1)[1])
                i += 1
            elif a == "--limit":
                limit = int(args[i + 1])
                i += 2
            else:
                raise AssertionError("fake bd ready: unsupported argument %r" % a)
        rows = [b for b in self.beads
                if all(b["metadata"].get(k) == v for k, v in meta.items())
                and (not unassigned or not b.get("assignee"))
                and b["issue_type"] not in exclude_types
                and not (self.honor_exclude_labels
                         and set(b.get("labels") or []) & exclude_labels)]
        rows.sort(key=lambda b: b["created_at"])
        return _done(argv, 0, json.dumps(rows[:limit] if limit else rows))


@pytest.fixture()
def wd():
    spec = importlib.util.spec_from_file_location("pool_autoscale_watchdog", MOD_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture()
def fake(wd, monkeypatch):
    cli = FakeCLI()
    monkeypatch.setattr(wd.subprocess, "run", cli)
    monkeypatch.setattr(wd.time, "sleep", lambda s: None)
    monkeypatch.setattr(wd, "_paw_ledger", lambda *a, **k: None)
    return cli


# ---------------------------------------------------------------------------
# The reported bug: held beads are not demand
# ---------------------------------------------------------------------------

HELD_LABELS = [
    # exact labels the pool probe excludes
    "story:needs-human", "needs-human", "ctx:thin", "story:needs-approval",
    "story:epic", "needs:engine-window", "pilot:no-auto-dispatch", "story:blocked",
    "delivery:partial", "scope:needs-review", "exec:manual", "needs-human-decision",
    "auto-refino:refining", "auto-refino:escalated", "refino:info-gap",
    "refino:policy-gap", "story:unrefined", "story:refinement-in-progress",
    "story:refino-review", "story:refino-escalado", "story:needs-device",
    "on-device", "phone-proxy", "gate:queued", "gate:reviewing",
    # prefix families the probe filters in jq
    "pool:refused:engine-rebuild-required", "blocked:waiting-on-ga-123",
    "blocked-reason:decision", "gate:needs-human:technical",
    "pilot:refused-reason:needs-mayor-decision",
    "pilot:text-veto:diagnostic-only-text-pattern",
    # a Pilot hold, bare and with a time box that is still running
    "pilot:held", "pilot:held-until:%d" % FUTURE,
    # already being worked elsewhere: the probe does NOT exclude these, the
    # watchdog does on purpose (ga-ms1jm / ga-lx7om double-dispatch)
    "story:in-flight", "pilot:dispatched",
]


@pytest.mark.parametrize("label", HELD_LABELS,
                         ids=[re.sub(r"\d{6,}", "EPOCH", l) for l in HELD_LABELS])
def test_bead_carrying_a_hold_label_is_not_demand(wd, fake, label):
    """Break caught: a held bead counted as demand keeps the watchdog waking
    dogs that find nothing to claim."""
    fake.beads = [bead("ga-held", labels=["area:infra", "framework", label])]
    assert wd.get_pool_demand(POOL) == 0
    assert fake.hook_calls == [], "nothing claimable, so the pool probe has no question to settle"


@pytest.mark.parametrize("label", ["pilot:no-auto-dispatch", "delivery:partial", "story:in-flight"])
def test_held_bead_is_not_demand_even_if_bd_ignores_exclude_label(wd, fake, label):
    """Break caught: bd has silently ignored flags before. If --exclude-label
    stopped working, only the watchdog's own check keeps the bug from returning."""
    fake.honor_exclude_labels = False
    fake.beads = [bead("ga-held", labels=[label])]
    assert wd.get_pool_demand(POOL) == 0


def test_bead_without_hold_labels_is_demand(wd, fake):
    """Break caught: over-filtering that reports 0 while real work waits."""
    fake.beads = [bead("ga-open", labels=["area:infra", "framework", "ctx:ready"])]
    assert wd.get_pool_demand(POOL) == 1


def test_only_claimable_beads_are_counted(wd, fake):
    """Break caught: held beads riding along in the count (the bead saw 11)."""
    fake.beads = [
        bead("ga-h1", labels=["pilot:no-auto-dispatch"]),
        bead("ga-h2", labels=["delivery:partial", "scope:needs-review"]),
        bead("ga-o1", labels=["ctx:ready"]),
        bead("ga-o2"),
        bead("ga-h3", labels=["pilot:text-veto:diagnostic-only-text-pattern"]),
    ]
    assert wd.get_pool_demand(POOL) == 2


def test_bead_with_no_labels_at_all_is_demand(wd, fake):
    """Break caught: reading a label-less row as unreadable. bd may omit the
    labels key or send null for a bead nobody has labelled; that is plain work."""
    omitted = bead("ga-omitted")
    del omitted["labels"]
    null = bead("ga-null")
    null["labels"] = None
    fake.beads = [omitted, null]
    assert wd.get_pool_demand(POOL) == 2


def test_rows_that_are_not_beads_never_count_and_never_crash(wd, fake):
    """Break caught: one malformed row from bd taking the whole cycle down (or
    being counted as work)."""
    fake.bd_stdout = json.dumps([None, "oops", 7,
                                 {"id": "ga-1", "labels": "not-a-list"},
                                 {"id": "ga-2", "labels": [3]}])
    assert wd.get_pool_demand(POOL) == 0


def test_bead_already_assigned_is_not_demand(wd, fake):
    """Break caught: a bead somebody already claimed woken a dog for."""
    taken = bead("ga-taken")
    taken["assignee"] = "gastown.dog-1"
    fake.beads = [taken]
    assert wd.get_pool_demand(POOL) == 0


def test_bead_routed_to_another_pool_is_not_this_pools_demand(wd, fake):
    fake.beads = [bead("ga-wa", routed_to="whatsapp_automation/wa-worker")]
    assert wd.get_pool_demand(POOL) == 0


def test_epic_typed_bead_is_not_demand(wd, fake):
    fake.beads = [bead("ga-epic", issue_type="epic", title="Consolidate everything")]
    assert wd.get_pool_demand(POOL) == 0


def test_hold_labelled_beads_do_not_crowd_claimable_work_out_of_the_window(wd, fake):
    """Break caught: asking bd for the 20 oldest WITHOUT excluding held labels
    first fills the window with held beads and hides real work behind them --
    the probe's own window is filled after those exclusions."""
    held = [bead("ga-h%02d" % i, labels=["pilot:no-auto-dispatch"],
                 created_at="2026-09-01T00:%02d:00Z" % i) for i in range(25)]
    fake.beads = held + [bead("ga-ok", created_at="2026-09-20T00:00:00Z")]
    assert wd.get_pool_demand(POOL) == 1


# ---------------------------------------------------------------------------
# Pilot holds expire; epics are not work
# ---------------------------------------------------------------------------

def test_expired_pilot_hold_no_longer_blocks_demand(wd, fake):
    """Break caught: treating pilot:held-until as permanent (what park_labels'
    prefix rule does) never wakes a dog for a bead the Pilot has released."""
    fake.beads = [bead("ga-released", labels=["pilot:held", "pilot:held-until:%d" % PAST])]
    assert wd.get_pool_demand(POOL) == 1


def test_latest_expiry_wins_when_hold_labels_disagree(wd, fake):
    fake.beads = [bead("ga-held", labels=["pilot:held-until:%d" % PAST,
                                          "pilot:held-until:%d" % FUTURE])]
    assert wd.get_pool_demand(POOL) == 0


def test_unreadable_hold_expiry_is_treated_as_held(wd, fake):
    """Under doubt the inert answer wins: no demand, no wake."""
    fake.beads = [bead("ga-odd", labels=["pilot:held-until:soon"])]
    assert wd.get_pool_demand(POOL) == 0


@pytest.mark.parametrize("title", [
    "EPIC: consolidate the label vocabulary",
    "ÉPICO: migrar o painel",
    "epic: lower case still counts",
    "Epic  two spaces after the word",
])
def test_epic_titled_bead_is_not_demand(wd, fake, title):
    fake.beads = [bead("ga-epic", title=title)]
    assert wd.get_pool_demand(POOL) == 0


def test_title_that_merely_starts_with_epic_is_still_demand(wd, fake):
    """Break caught: an over-broad epic pattern hiding real work."""
    fake.beads = [bead("ga-real", title="Epicenter latency alarm keeps firing")]
    assert wd.get_pool_demand(POOL) == 1


# ---------------------------------------------------------------------------
# The pool's own probe has the last word on "nothing to claim"
# ---------------------------------------------------------------------------

def test_probe_reporting_empty_overrules_the_watchdogs_count(wd, fake):
    """Break caught: vocabulary drift (the class behind this bug, 9 times over)
    silently wakes dogs again. The probe is the arbiter of what a dog can claim."""
    fake.beads = [bead("ga-a"), bead("ga-b")]
    fake.hook = (1, "[]\n", 'warning: builtin pack "gastown" on disk differs from the copy embedded')
    assert wd.get_pool_demand(POOL) == 0


@pytest.mark.parametrize("rc,out,err", [
    (1, "", 'gc hook: agent "gastown.dog" not found in config'),
    (1, "", 'gc hook: agent "gastown.dog" is suspended'),
    (2, "", "usage: gc hook [agent]"),
    (0, "", ""),
], ids=["unknown-agent", "suspended-agent", "usage-error", "ok-without-body"])
def test_probe_failure_is_not_read_as_an_empty_queue(wd, fake, rc, out, err):
    """Break caught: `gc hook` exits 1 for errors too. Only a positively empty
    answer may veto demand, or a broken probe starves the pool."""
    fake.beads = [bead("ga-a"), bead("ga-b")]
    fake.hook = (rc, out, err)
    assert wd.get_pool_demand(POOL) == 2


def test_probe_timeout_is_not_read_as_an_empty_queue(wd, fake):
    fake.beads = [bead("ga-a"), bead("ga-b")]
    fake.hook_raises = subprocess.TimeoutExpired(["gc", "hook", POOL], 30)
    assert wd.get_pool_demand(POOL) == 2


def test_probe_confirming_work_keeps_the_count(wd, fake):
    fake.beads = [bead("ga-a"), bead("ga-b"), bead("ga-c")]
    fake.hook = (0, json.dumps([bead("ga-a")]), "")
    assert wd.get_pool_demand(POOL) == 3


def test_probe_is_asked_about_the_pool_not_about_the_caller(wd, fake, monkeypatch):
    """Break caught: with a session identity in the environment `gc hook` also
    returns work assigned to that caller, so the probe would never say empty."""
    for var in IDENTITY_ENV:
        monkeypatch.setenv(var, "leaked-from-a-dog-shell")
    fake.beads = [bead("ga-a")]
    wd.get_pool_demand(POOL)
    assert fake.hook_calls, "the pool probe was never consulted"
    argv, env = fake.hook_calls[0]
    assert argv == ["gc", "hook", POOL]
    assert [v for v in IDENTITY_ENV if v in env] == []


def test_disagreement_with_the_probe_is_reported_once_per_episode(wd, fake, capsys):
    """Break caught: a stale mirror that vetoes silently never gets fixed."""
    fake.beads = [bead("ga-a")]
    fake.hook = (1, "[]", "")
    wd.get_pool_demand(POOL)
    wd.get_pool_demand(POOL)
    assert capsys.readouterr().out.count("PROBE-DISAGREE") == 1


def test_disagreement_is_reported_again_once_the_two_have_agreed_in_between(wd, fake, capsys):
    """Break caught: a flag that never clears mutes every later drift report."""
    fake.beads = [bead("ga-a")]
    fake.hook = (1, "[]", "")
    wd.get_pool_demand(POOL)                                    # episode 1
    fake.hook = (0, json.dumps([bead("ga-a")]), "")
    wd.get_pool_demand(POOL)                                    # they agree again
    fake.hook = (1, "[]", "")
    wd.get_pool_demand(POOL)                                    # episode 2
    assert capsys.readouterr().out.count("PROBE-DISAGREE") == 2


# ---------------------------------------------------------------------------
# Three states: found / none / could not tell
# ---------------------------------------------------------------------------

def test_empty_ready_list_is_zero_demand(wd, fake):
    fake.beads = []
    assert wd.get_pool_demand(POOL) == 0
    assert fake.hook_calls == []


def test_bd_failure_is_an_error_not_zero_demand(wd, fake):
    """Break caught: error collapsing to 0 would let an outage unpin the pool."""
    fake.bd_rc = 1
    assert wd.get_pool_demand(POOL) == -1


def test_bd_timeout_is_an_error(wd, fake):
    fake.bd_raises = subprocess.TimeoutExpired(["bd", "ready"], 20)
    assert wd.get_pool_demand(POOL) == -1


@pytest.mark.parametrize("stdout", ["", "not json at all", '{"error": "boom"}', "null"],
                         ids=["empty", "garbage", "object", "null"])
def test_unparseable_bd_output_is_an_error(wd, fake, stdout):
    fake.bd_stdout = stdout
    assert wd.get_pool_demand(POOL) == -1


# ---------------------------------------------------------------------------
# End to end: the symptom the bead reported
# ---------------------------------------------------------------------------

def _asleep_dog():
    return {"id": "ga-s1", "name": "gastown.dog-1", "template": POOL,
            "state": "asleep", "closed": False}


def test_cycle_with_only_held_beads_neither_wakes_nor_pins_and_resets_the_clock(wd, fake):
    """Break caught: the daemon's state kept demand_first_seen_ts at
    1788133695 (2026-08-30) for 20 days and woke+pinned a dog every cycle."""
    fake.beads = [bead("ga-h1", labels=["pilot:no-auto-dispatch"]),
                  bead("ga-h2", labels=["delivery:partial", "scope:needs-review"]),
                  bead("ga-h3", labels=["pilot:text-veto:diagnostic-only-text-pattern"])]
    fake.sessions = [_asleep_dog()]
    state = {POOL: {"pinned_ids": [], "demand_first_seen_ts": 1788133695.0,
                    "idle_first_seen_ts": 0.0}}
    wd.run_cycle({POOL: 3}, state, {})
    assert state[POOL]["demand_first_seen_ts"] == 0.0
    assert [c for c in fake.calls if c[:3] == ["gc", "session", "wake"]] == []
    assert [c for c in fake.calls if c[:3] == ["gc", "session", "pin"]] == []


def test_cycle_with_claimable_work_still_wakes_and_pins_an_asleep_dog(wd, fake):
    """Break caught: the fix must not turn the watchdog into one that never scales."""
    fake.beads = [bead("ga-open", labels=["ctx:ready"])]
    fake.sessions = [_asleep_dog()]
    state = {POOL: {"pinned_ids": [], "demand_first_seen_ts": time.time() - 3600,
                    "idle_first_seen_ts": 0.0}}
    wd.run_cycle({POOL: 3}, state, {})
    assert ["gc", "session", "wake", "ga-s1"] in fake.calls
    assert ["gc", "session", "pin", "ga-s1"] in fake.calls


# ---------------------------------------------------------------------------
# Drift guard: the watchdog's copy of the probe vocabulary vs the live engine
# ---------------------------------------------------------------------------

def _rendered_probe():
    if shutil.which("gc") is None:
        pytest.skip("gc is not on PATH: cannot render the pool probe")
    env = {k: v for k, v in os.environ.items() if k not in IDENTITY_ENV}
    try:
        r = subprocess.run(["gc", "prime", POOL], capture_output=True, text=True,
                           timeout=180, env=env)
    except (OSError, subprocess.TimeoutExpired) as exc:
        pytest.skip("gc prime unavailable: %s" % exc)
    if r.returncode != 0:
        pytest.skip("gc prime %s exited %d: %s" % (POOL, r.returncode, r.stderr[-200:]))
    m = re.search(r'probe_pool_demand\(\) \{.*?\}; probe_pool_demand "\$1"', r.stdout, re.S)
    assert m, ("gc prime rendered no probe_pool_demand(): the engine changed the shape "
               "of the pool probe -- re-derive the watchdog's mirror from it")
    return m.group(0)


@pytest.fixture(scope="module")
def engine_probe():
    return _rendered_probe()


def test_vocabulary_matches_the_engine_probe(wd, engine_probe):
    """Break caught: an engine window that adds or drops a probe exclusion while
    the watchdog keeps counting (or ignoring) it -- the drift behind ga-uv4on5."""
    probe = engine_probe
    exact = set(re.findall(r'--exclude-label "([^"]+)"', probe))
    prefixes = set(re.findall(r'startswith\("([^"]+)"\)', probe))
    bare_holds = set(re.findall(r'\. == "([^"]+)"', probe))
    epic = {p.replace("\\\\", "\\") for p in re.findall(r'test\("([^"]+)"; *"i"\)', probe)}
    assert exact and prefixes and bare_holds and epic, "extraction found nothing to compare"
    assert exact == set(wd.PROBE_EXCLUDE_LABELS)
    assert prefixes == set(wd.PROBE_EXCLUDE_LABEL_PREFIXES) | {wd.PROBE_HELD_UNTIL_PREFIX}
    assert bare_holds == {wd.PROBE_HELD_LABEL}
    assert epic == {wd.PROBE_EPIC_TITLE_RE.pattern}


def test_predicate_agrees_with_the_engine_probe_on_generated_beads(wd, engine_probe):
    """Break caught: the engine changes what its jq stage keeps -- a comparison,
    a new condition -- while the watchdog's predicate keeps answering the old
    question. Vocabulary equality cannot see logic drift; running the engine's
    own jq program over the same beads can."""
    if shutil.which("jq") is None:
        pytest.skip("jq is not on PATH")
    m = re.search(r"""--limit=20 2>/dev/null \| jq -c --argjson now_ts "\$\(date \+%s\)" '\\''(.*?)'\\'' 2>/dev/null""",
                  engine_probe, re.S)
    assert m, ("the engine's pool probe no longer has the jq stage this test extracts: "
               "re-derive the watchdog's predicate from it")
    program = m.group(1)

    # Labels the jq stage itself is responsible for. Exact labels (bd's own
    # --exclude-label) and the watchdog-only ones are not part of that stage.
    benign = ["area:infra", "ctx:ready", "framework", "lane:small", "next-action:mayor", "story:approved"]
    prefixed = ["pool:refused", "pool:refused:engine-rebuild-required", "blocked:x", "blocked-reason:decision",
                "gate:needs-human", "gate:needs-human:technical", "pilot:refused-reason:needs-mayor-decision",
                "pilot:text-veto", "pilot:text-veto:diagnostic-only-text-pattern", "blocked-on:x", "gate:needs-fix"]
    holds = ["pilot:held", "pilot:held-count:ga-lfvs6:3", "pilot:held-until:0"] + \
            ["pilot:held-until:%d" % (NOW + d) for d in (-3600, -1, 0, 1, 3600)]
    titles = ["fix the thing", "EPIC: consolidate", "ÉPICO: migrar", "épico: minúsculo", "epic lower",
              "Epic  spaced", "EPIC", "EPICx: nope", "Epicenter alarm", "EPIC\tTab", "", None]

    rnd = random.Random(20260920)
    pool = benign * 2 + prefixed + holds
    beads = []
    for _ in range(300):
        beads.append({"labels": rnd.sample(pool, rnd.randint(0, 4)), "title": rnd.choice(titles)})
    beads += [{"labels": [l], "title": "plain"} for l in benign + prefixed + holds]
    beads += [{"labels": [a, b], "title": "plain"} for a, b in itertools.permutations(holds, 2)]
    for i, b in enumerate(beads):
        b["id"] = "ga-%d" % i
        b["metadata"] = {}
        if b["title"] is None:
            del b["title"]

    run = subprocess.run(["jq", "-c", "--argjson", "now_ts", str(NOW), program],
                         input=json.dumps(beads), capture_output=True, text=True)
    assert run.returncode == 0, run.stderr
    engine_keeps = {b["id"] for b in json.loads(run.stdout)}
    watchdog_keeps = {b["id"] for b in beads if wd.probe_would_serve(b, NOW)}
    assert watchdog_keeps == engine_keeps
    assert engine_keeps and len(engine_keeps) < len(beads), "the fixture must exercise both outcomes"

    # A malformed expiry makes jq abort the whole array (the probe then sees
    # nothing), so those are compared one bead at a time. The watchdog reads
    # them as held.
    for label in ("pilot:held-until:soon", "pilot:held-until:"):
        bad = {"id": "ga-bad", "labels": [label], "title": "plain", "metadata": {}}
        run = subprocess.run(["jq", "-c", "--argjson", "now_ts", str(NOW), program],
                             input=json.dumps([bad]), capture_output=True, text=True)
        engine_serves = run.returncode == 0 and json.loads(run.stdout) != []
        assert engine_serves is False
        assert wd.probe_would_serve(bad, NOW) is False
