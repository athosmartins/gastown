#!/usr/bin/env bash
# child-cycle-labels-sweep.selftest.sh — drives the REAL code path of child-cycle-labels-sweep.py (ga-y5z6hzh).
#
# The sweep's SQL (the parent-child edge query, labels/events by id list, UNIX_TIMESTAMP arithmetic, the marker
# lookup) is the part a canned-rows stub cannot test, so this builds a throwaway Dolt database with the real table shapes
# and lets a `bd` stub run the sweep's queries against it with `dolt sql`. ZERO calls reach the live city.
# The stub also FAILS on demand (store down, garbage, marker lookup down, a write that exits 0 and persists
# nothing) and the test checks the sweep lands in the INERT state: nothing removed, failure visible, exit 2.
# "Could not read" must never turn into "nothing to do", nor "remove returned 0" into "removed".
#
# Last test: the policy lists in the sweep must equal internal/types/label_inherit.go in the bd patch.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SWEEP="${CHILD_CYCLE_LABELS_SWEEP_PATH:-$HERE/child-cycle-labels-sweep.py}"
PATCH="${CHILD_CYCLE_LABELS_PATCH_PATH:-$HERE/../docs/pending-engine-window/ga-y5z6hzh-bd-create-parent-no-inherit-cycle-labels.bd-repo.diff}"
[ -f "$SWEEP" ] || { echo "FATAL: sweep not found at $SWEEP"; exit 1; }
command -v python3 >/dev/null || { echo "FATAL: python3 missing"; exit 1; }
command -v dolt >/dev/null || { echo "FATAL: dolt missing (needed to run the sweep's SQL for real)"; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/ccls-selftest.XXXXXX")"
trap 'rm -rf "$W"' EXIT
DB="$W/db"; CALLS="$W/calls"; OUT_F="$W/out"
mkdir -p "$W/hq/.gc" "$W/rig"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
nope() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; [ -f "$OUT_F" ] && sed 's/^/        | /' "$OUT_F" | head -24; }

# ── the bd stub: sql -> dolt; label remove -> DELETE + label_removed event; comment -> log ─────────────────
cat > "$W/bd" <<'STUB'
#!/usr/bin/env python3
import json, os, subprocess, sys
a = sys.argv[1:]
with open(os.environ["STUB_CALLS"], "a") as f:
    f.write(" ".join(a) + "\n")
mode = os.environ.get("STUB_MODE", "ok")
if a[:1] == ["-C"]:
    a = a[2:]
def dolt(q):
    return subprocess.run(["dolt", "sql", "-r", "json", "-q", q], cwd=os.environ["STUB_DB"], capture_output=True, text=True)
if a[:1] == ["sql"]:
    q = a[-1]
    if mode == "rc1":
        print(json.dumps({"error": "stub: store down"})); sys.exit(1)
    if mode == "garbage":
        print("garbage{{{ not json"); sys.exit(0)
    if mode == "marker_fail" and "source-bead:" in q:
        print(json.dumps({"error": "stub: marker lookup down"})); sys.exit(1)
    if mode == "probe_fail" and q.startswith("SELECT 1 AS n"):
        print(json.dumps({"error": "stub: pre-check down"})); sys.exit(1)
    if mode == "vanish" and q.startswith("SELECT 1 AS n"):
        # somebody else removes the label between the analysis and our pre-check
        import re
        m = re.search(r"issue_id = '([^']+)' AND label = '([^']+)'", q)
        dolt("DELETE FROM labels WHERE issue_id='%s' AND label='%s'" % (m.group(1), m.group(2)))
    p = dolt(q)
    if p.returncode != 0:
        print(json.dumps({"error": p.stderr.strip()[:200]})); sys.exit(1)
    out = p.stdout.strip()
    print(json.dumps(json.loads(out).get("rows", []) if out else []))
elif a[:2] == ["label", "remove"]:
    child, label = a[2], a[3]
    if mode == "lie_remove":
        sys.exit(0)  # exits 0, persists nothing
    q = ("DELETE FROM labels WHERE issue_id='%s' AND label='%s'; "
         "INSERT INTO events VALUES (UUID(), '%s', 'label_removed', 'Removed label: %s', NOW())") % (child, label, child, label)
    sys.exit(dolt(q).returncode)
elif a[:1] == ["comment"]:
    sys.exit(0)
else:
    sys.exit(0)
STUB
chmod +x "$W/bd"

# ── fixture: a closed parent P1 with cycle labels, and children covering every branch of the rules ────────
fresh_db() {
  rm -rf "$DB"; mkdir -p "$DB"; : > "$CALLS"
  ( cd "$DB" && dolt init --name t --email t@t >/dev/null 2>&1 ) || { echo "FATAL: dolt init"; exit 1; }
  python3 -I - "$DB" <<'PY'
import subprocess, sys
db = sys.argv[1]
P1_LABELS = ["gate:passed", "story:done", "area:infra", "lane:small", "exec:manual", "gate-approved:abc123", "pilot:no-auto-dispatch"]
C1_LABELS = ["gate:passed", "story:done", "area:infra", "lane:small", "gate-approved:abc123", "exec:manual"]
s = []
s.append("CREATE TABLE issues (id varchar(255) PRIMARY KEY, status varchar(32), created_at datetime)")
s.append("CREATE TABLE labels (issue_id varchar(255), label varchar(255), PRIMARY KEY (issue_id, label))")
s.append("CREATE TABLE dependencies (id varchar(36) PRIMARY KEY, issue_id varchar(255), type varchar(32), depends_on_issue_id varchar(255))")
s.append("CREATE TABLE events (id varchar(36) PRIMARY KEY, issue_id varchar(255), event_type varchar(32), comment text, created_at datetime)")
s.append("SET @t2 = DATE_SUB(NOW(), INTERVAL 2 DAY)")
s.append("SET @t30 = DATE_SUB(NOW(), INTERVAL 30 DAY)")
def issue(i, status, t): s.append("INSERT INTO issues VALUES ('%s','%s',%s)" % (i, status, t))
def label(i, l): s.append("INSERT INTO labels VALUES ('%s','%s')" % (i, l))
def child(i, parent): s.append("INSERT INTO dependencies VALUES (UUID(),'%s','parent-child','%s')" % (i, parent))
def ev(i, kind, l, secs, t="@t2"):
    verb = "Added" if kind == "label_added" else "Removed"
    s.append("INSERT INTO events VALUES (UUID(),'%s','%s','%s label: %s',DATE_ADD(%s, INTERVAL %d SECOND))" % (i, kind, verb, l, t, secs))
issue("ga-p1", "closed", "@t30"); issue("ga-p2", "open", "@t30")
for l in P1_LABELS: label("ga-p1", l)
label("ga-p2", "area:infra")
# c1: born with every label, nothing since -> its 3 completion claims are STRIPPED, exec:manual only REPORTED
issue("ga-c1", "open", "@t2"); child("ga-c1", "ga-p1")
for l in C1_LABELS: label("ga-c1", l); ev("ga-c1", "label_added", l, 0, "@t2")
# c2: born gate:passed, BUT the gate has a marker for it -> report only
issue("ga-c2", "open", "@t2"); child("ga-c2", "ga-p1"); label("ga-c2", "gate:passed"); ev("ga-c2", "label_added", "gate:passed", 0)
issue("gm-m2", "open", "@t2"); label("gm-m2", "source-bead:ga-c2")
# c3: gate:passed added an hour AFTER creation (earned, or at least not copied at birth) -> report only
issue("ga-c3", "open", "@t2"); child("ga-c3", "ga-p1"); label("ga-c3", "gate:passed"); ev("ga-c3", "label_added", "gate:passed", 3600)
# c4: born with it, removed, put back -> somebody decided -> report only
issue("ga-c4", "open", "@t2"); child("ga-c4", "ga-p1"); label("ga-c4", "gate:passed")
ev("ga-c4", "label_added", "gate:passed", 0); ev("ga-c4", "label_removed", "gate:passed", 60); ev("ga-c4", "label_added", "gate:passed", 120)
# c5: born gate:passed but its parent p2 does NOT carry it -> not inherited, not listed at all
issue("ga-c5", "open", "@t2"); child("ga-c5", "ga-p2"); label("ga-c5", "gate:passed"); label("ga-c5", "area:infra"); ev("ga-c5", "label_added", "gate:passed", 0)
# c6: CLOSED child -> out of scope
issue("ga-c6", "closed", "@t2"); child("ga-c6", "ga-p1"); label("ga-c6", "gate:passed"); ev("ga-c6", "label_added", "gate:passed", 0)
# c7: older than the 14-day window -> out of scope
issue("ga-c7", "open", "@t30"); child("ga-c7", "ga-p1"); label("ga-c7", "gate:passed"); ev("ga-c7", "label_added", "gate:passed", 0, "@t30")
# c8: a HOLD label (the town's creation default) -> report only, never stripped
issue("ga-c8", "open", "@t2"); child("ga-c8", "ga-p1"); label("ga-c8", "pilot:no-auto-dispatch"); ev("ga-c8", "label_added", "pilot:no-auto-dispatch", 0)
# c9: born with it, removed at +60s, and the label is back WITHOUT a second added event (e.g. a merge restored it) -> report only
issue("ga-c9", "open", "@t2"); child("ga-c9", "ga-p1"); label("ga-c9", "gate:passed")
ev("ga-c9", "label_added", "gate:passed", 0); ev("ga-c9", "label_removed", "gate:passed", 60)
# c10: its label_added event is stamped an HOUR BEFORE the child exists (clock skew / corrupt log) -> never "born with"
issue("ga-c10", "open", "@t2"); child("ga-c10", "ga-p1"); label("ga-c10", "gate:passed"); ev("ga-c10", "label_added", "gate:passed", -3600)
# c11: born with gate:passed, no marker, BUT somebody removed another label (lane:small) by hand 1 hour ago -> being curated -> report only
issue("ga-c11", "open", "@t2"); child("ga-c11", "ga-p1"); label("ga-c11", "gate:passed")
ev("ga-c11", "label_added", "gate:passed", 0); ev("ga-c11", "label_added", "lane:small", 0); ev("ga-c11", "label_removed", "lane:small", 2 * 86400 - 3600)
r = subprocess.run(["dolt", "sql", "-q", "; ".join(s)], cwd=db, capture_output=True, text=True)
if r.returncode != 0:
    sys.stderr.write(r.stderr); sys.exit(1)
PY
  [ $? -eq 0 ] || { echo "FATAL: fixture build failed"; exit 1; }
}

# sweep MODE [args...]  — output in $OUT_F, rc in $RC
sweep() {
  local mode="$1"; shift
  env BD_BIN="$W/bd" GC_BIN="${GC_BIN_OVERRIDE:-/usr/bin/false}" GC_CITY_PATH="$W/hq" \
      CHILD_CYCLE_LABELS_SWEEP_LOCK="$W/lock" STUB_DB="$DB" STUB_CALLS="$CALLS" STUB_MODE="$mode" \
      python3 -I "$SWEEP" --path "$W/rig" "$@" > "$OUT_F" 2>&1
  RC=$?
}
labels_of() { ( cd "$DB" && dolt sql -r csv -q "SELECT label FROM labels WHERE issue_id='$1' ORDER BY label" 2>/dev/null | tail -n +2 | paste -sd, - ); }
n_calls() { grep -c -- "$1" "$CALLS" 2>/dev/null || true; }
section() { awk -v h="$1" '/^## /{p=($0 ~ h)} p' "$OUT_F"; }

# ── 1. dry-run: lists, mutates nothing ────────────────────────────────────────────────────────────────────
fresh_db; before="$(labels_of ga-c1)"
sweep ok
[ "$RC" -eq 0 ] && ok "dry-run exits 0" || nope "dry-run exit code $RC, want 0"
s="$(section STRIP)"
c=$(printf '%s\n' "$s" | grep -c 'ga-c1 ') ; [ "$c" -eq 3 ] && ok "c1: exactly 3 completion claims listed for STRIP" || nope "c1 STRIP lines = $c, want 3"
for l in 'gate:passed' 'story:done' 'gate-approved:abc123'; do
  printf '%s\n' "$s" | grep 'ga-c1 ' | grep -q -- "$l" && ok "c1: $l is a strip candidate" || nope "c1: $l missing from STRIP"
done
printf '%s\n' "$s" | grep -q -E 'ga-c[2-8] ' && nope "STRIP section lists a child that must not be stripped" || ok "only c1 is in the STRIP section"
r="$(section REPORT)"
printf '%s\n' "$r" | grep 'ga-c1 ' | grep -q 'exec:manual' && ok "c1 exec:manual is REPORTED (a hold is not stripped)" || nope "c1 exec:manual not in REPORT"
printf '%s\n' "$r" | grep 'ga-c2 ' | grep -q 'gate reviewed' && ok "c2: reviewed by the gate -> report only" || nope "c2 not reported as gate-reviewed"
printf '%s\n' "$r" | grep 'ga-c3 ' | grep -q 'not proven born-with' && ok "c3: added late -> report only" || nope "c3 not reported as late"
printf '%s\n' "$r" | grep 'ga-c4 ' | grep -q 'not proven born-with' && ok "c4: removed and re-added -> report only" || nope "c4 not reported"
printf '%s\n' "$r" | grep 'ga-c8 ' | grep -q 'not a completion claim' && ok "c8: pilot hold label -> report only" || nope "c8 not reported as hold"
printf '%s\n' "$r" | grep 'ga-c9 ' | grep -q 'not proven born-with' && ok "c9: removed since (no re-add event) -> report only" || nope "c9 not reported"
printf '%s\n' "$r" | grep 'ga-c10 ' | grep -q 'not proven born-with' && ok "c10: event stamped before the child existed -> report only" || nope "c10 not reported"
printf '%s\n' "$r" | grep 'ga-c11 ' | grep -q 'hand-edited in the last 6h' && ok "c11: labels hand-edited an hour ago -> report only (someone is on it)" || nope "c11 not reported as being curated"
for x in ga-c5 ga-c6 ga-c7; do
  grep -q "$x " "$OUT_F" && nope "$x must not appear (parent lacks the label / closed / outside the window)" || ok "$x is out of scope and not listed"
done
[ "$(n_calls ' label remove ')" -eq 0 ] && ok "dry-run: no 'label remove' call" || nope "dry-run issued a label remove"
[ "$(labels_of ga-c1)" = "$before" ] && ok "dry-run: c1 labels unchanged" || nope "dry-run changed c1 labels"

# ── 2. --apply: strips exactly the three claims, confirms, comments ───────────────────────────────────────
fresh_db
sweep ok --apply
[ "$RC" -eq 0 ] && ok "apply exits 0" || nope "apply exit code $RC, want 0"
want="area:infra,exec:manual,lane:small"
[ "$(labels_of ga-c1)" = "$want" ] && ok "apply: c1 keeps area/lane/exec:manual, loses the 3 claims" || nope "apply: c1 labels = $(labels_of ga-c1), want $want"
[ "$(labels_of ga-c2)" = "gate:passed" ] && ok "apply: c2 (gate reviewed) untouched" || nope "apply touched c2"
[ "$(labels_of ga-c3)" = "gate:passed" ] && ok "apply: c3 (added late) untouched" || nope "apply touched c3"
[ "$(labels_of ga-c4)" = "gate:passed" ] && ok "apply: c4 (removed+re-added) untouched" || nope "apply touched c4"
[ "$(labels_of ga-c8)" = "pilot:no-auto-dispatch" ] && ok "apply: c8 hold label untouched" || nope "apply touched c8"
[ "$(labels_of ga-c9)" = "gate:passed" ] && ok "apply: c9 (removed since) untouched" || nope "apply touched c9"
[ "$(labels_of ga-c10)" = "gate:passed" ] && ok "apply: c10 (negative delta) untouched" || nope "apply touched c10"
[ "$(labels_of ga-c11)" = "gate:passed" ] && ok "apply: c11 (being curated) untouched" || nope "apply touched c11"
[ "$(labels_of ga-c6)" = "gate:passed" ] && [ "$(labels_of ga-c7)" = "gate:passed" ] && ok "apply: closed / old children untouched" || nope "apply touched c6/c7"
[ "$(labels_of ga-p1 | tr ',' '\n' | sort | paste -sd, -)" = "area:infra,exec:manual,gate-approved:abc123,gate:passed,lane:small,pilot:no-auto-dispatch,story:done" ] && ok "apply: the PARENT is never touched" || nope "apply changed the parent"
[ "$(n_calls ' label remove ')" -eq 3 ] && ok "apply: exactly 3 single-label removes" || nope "apply: $(n_calls ' label remove ') removes, want 3"
[ "$(n_calls ' comment ga-c1 ')" -eq 3 ] && ok "apply: one audit comment per removal" || nope "apply: $(n_calls ' comment ga-c1 ') comments, want 3"
grep -q 'OK removed' "$OUT_F" && ok "apply: output says removed" || nope "apply output lacks 'OK removed'"

# ── 3. idempotent: a second apply finds nothing left to strip ─────────────────────────────────────────────
: > "$CALLS"; sweep ok --apply
[ "$RC" -eq 0 ] && [ "$(n_calls ' label remove ')" -eq 0 ] && ok "second apply: nothing to strip, no remove" || nope "second apply removed again (rc=$RC)"
grep -q '0 strip candidate' "$OUT_F" && ok "second apply: reports 0 strip candidates" || nope "second apply still lists candidates"

# ── 4. --max caps the writes ─────────────────────────────────────────────────────────────────────────────
fresh_db; sweep ok --apply --max 2
[ "$(n_calls ' label remove ')" -eq 2 ] && ok "--max 2: exactly 2 removes" || nope "--max 2 did $(n_calls ' label remove ') removes"
grep -q 'skipped (--max 2 reached)' "$OUT_F" && ok "--max 2: the 3rd is reported skipped" || nope "--max 2: no skipped line"

# ── 5. READ FAILURES land inert (exit 2, nothing removed), never as 'nothing to do' ───────────────────────
for mode in rc1 garbage; do
  fresh_db; sweep "$mode" --apply
  [ "$RC" -eq 2 ] && ok "$mode: exit 2" || nope "$mode: exit $RC, want 2"
  grep -q 'UNREADABLE' "$OUT_F" && ok "$mode: output says UNREADABLE" || nope "$mode: failure not visible"
  [ "$(n_calls ' label remove ')" -eq 0 ] && ok "$mode: nothing removed" || nope "$mode: removed something"
  grep -q ' 0 strip candidate' "$OUT_F" && grep -q '0 unreadable' "$OUT_F" && nope "$mode: read as 'clean store'" || ok "$mode: not presented as a clean store"
done
fresh_db; sweep marker_fail --apply
[ "$RC" -eq 2 ] && ok "marker lookup down: exit 2" || nope "marker lookup down: exit $RC, want 2"
[ "$(n_calls ' label remove ')" -eq 0 ] && ok "marker lookup down: NOTHING stripped (downgraded to report-only)" || nope "marker lookup down: stripped without knowing whether the gate saw it"
grep -q 'marker lookup unreadable' "$OUT_F" && ok "marker lookup down: note says so" || nope "marker lookup down: no note"
fresh_db; before="$(labels_of ga-c1)"; sweep lie_remove --apply
[ "$RC" -eq 2 ] && ok "lying remove (rc 0, nothing persisted): exit 2" || nope "lying remove: exit $RC, want 2"
grep -q 'FAILED.*still there' "$OUT_F" && ok "lying remove: reported FAILED, not removed" || nope "lying remove believed"
[ "$(n_calls ' comment ga-c1 ')" -eq 0 ] && ok "lying remove: no 'removed' audit comment written" || nope "lying remove: wrote an audit comment"

fresh_db; sweep vanish --apply
[ "$RC" -eq 0 ] && ok "label removed by someone else first: exit 0" || nope "vanished label: exit $RC, want 0"
[ "$(n_calls ' label remove ')" -eq 0 ] && ok "vanished label: no 'label remove' issued" || nope "vanished label: removed anyway"
[ "$(n_calls ' comment ga-c1 ')" -eq 0 ] && ok "vanished label: no 'removed' audit comment (it was not us)" || nope "vanished label: wrote an audit comment"
grep -q 'already gone' "$OUT_F" && ok "vanished label: output says already gone" || nope "vanished label: not reported"
fresh_db; sweep vanish --apply --max 1
[ "$(grep -c 'already gone' "$OUT_F")" -eq 3 ] && ok "already-gone does not count toward --max (all 3 examined with --max 1)" || nope "already-gone consumed the --max budget"
fresh_db; sweep probe_fail --apply
[ "$RC" -eq 2 ] && ok "pre-check unreadable: exit 2" || nope "pre-check unreadable: exit $RC, want 2"
[ "$(n_calls ' label remove ')" -eq 0 ] && ok "pre-check unreadable: NO blind write" || nope "pre-check unreadable: wrote blind"
grep -q 'pre-check unreadable' "$OUT_F" && ok "pre-check unreadable: said so" || nope "pre-check unreadable: silent"

# ── 6. store listing: failing `gc rig list` is exit 2, not an empty city ──────────────────────────────────
fresh_db
env BD_BIN="$W/bd" GC_BIN=/usr/bin/false GC_CITY_PATH="$W/hq" CHILD_CYCLE_LABELS_SWEEP_LOCK="$W/lock" STUB_DB="$DB" STUB_CALLS="$CALLS" STUB_MODE=ok \
    python3 -I "$SWEEP" > "$OUT_F" 2>&1; RC=$?
[ "$RC" -eq 2 ] && grep -q 'cannot list stores' "$OUT_F" && ok "gc rig list down: exit 2 with a message" || nope "gc rig list down: rc=$RC"

# ── 7. kill-switch and usage ─────────────────────────────────────────────────────────────────────────────
fresh_db; CHILD_CYCLE_LABELS_SWEEP_ENABLED=0 sweep ok --apply
[ "$RC" -eq 0 ] && [ ! -s "$CALLS" ] && ok "kill-switch: exit 0, no bd call" || nope "kill-switch ignored (rc=$RC)"
sweep ok --days 0; [ "$RC" -eq 3 ] && ok "bad usage (--days 0): exit 3" || nope "--days 0 exit $RC, want 3"

# ── 8. unsafe tokens are refused, never interpolated ─────────────────────────────────────────────────────
python3 -I - "$SWEEP" <<'PY' && ok "unsafe id/label is refused (Unreadable), not escaped" || nope "unsafe token was interpolated"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sweep", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
for bad in ("x'; DROP TABLE labels; --", "a b", "", "ga-1\n", None):
    try:
        m._quote(bad)
    except m.Unreadable:
        continue
    sys.exit(1)
assert m._quote("source-bead:ga-c1") == "'source-bead:ga-c1'"
PY

# ── 9. policy mirror: the sweep's lists must equal internal/types/label_inherit.go in the bd patch ───────
if [ -f "$PATCH" ]; then
  python3 -I - "$SWEEP" "$PATCH" > "$OUT_F" 2>&1 <<'PY' && ok "policy lists equal the Go patch (no drift)" || nope "policy drift between the sweep and the bd patch"
import importlib.util, re, sys
spec = importlib.util.spec_from_file_location("sweep", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
diff = open(sys.argv[2], encoding="utf-8").read()
# the added lines of the new file internal/types/label_inherit.go
block = None
for part in re.split(r"(?m)^diff --git ", diff):
    if part.startswith("a/internal/types/label_inherit.go "):
        block = part
if block is None:
    print("label_inherit.go not found in the patch"); sys.exit(1)
go = "\n".join(l[1:] for l in block.splitlines() if l.startswith("+") and not l.startswith("+++"))
def body(start):
    i = go.index(start)
    j = go.index("\n}", i)
    return go[i:j]
prefixes = tuple(re.findall(r'^\s*"([^"]+)",', body("var nonInheritableLabelPrefixes"), re.M))
exact = frozenset(re.findall(r'^\s*"([^"]+)":\s*\{\}', body("var nonInheritableLabels"), re.M))
story = frozenset(re.findall(r'^\s*"([^"]+)":\s*\{\}', body("var inheritableStoryLabels"), re.M))
ns = re.search(r'const storyNamespace = "([^"]+)"', go).group(1)
bad = 0
for name, go_v, py_v in (("prefixes", set(prefixes), set(m.NON_INHERITABLE_PREFIXES)),
                         ("exact", set(exact), set(m.NON_INHERITABLE_EXACT)),
                         ("story allow", set(story), set(m.STORY_INHERITABLE)),
                         ("story namespace", {ns}, {m.STORY_NAMESPACE})):
    if not go_v:
        print("%s: parsed EMPTY from the Go patch (parser broken?)" % name); bad = 1
    elif go_v != py_v:
        print("%s differ: only-go=%s only-py=%s" % (name, sorted(go_v - py_v), sorted(py_v - go_v))); bad = 1
sys.exit(bad)
PY
else
  echo "no patch at $PATCH" > "$OUT_F"; nope "bd patch not found: the policy mirror cannot be checked"
fi

echo "---"; echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
