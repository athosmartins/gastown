#!/usr/bin/env bash
# mol-digest-generate.selftest.sh — regression harness for the two recipe
# defects of ga-hnlog4 in packs/town-deltas/formulas/mol-digest-generate.toml.
#
# This formula has no exec script: an agent reads each step's description and
# types the shell it finds there. So the unit under test is the text the agent
# is DELIVERED — the TOML parsed by tomllib, escapes already consumed — never
# the raw source. Testing the source is how defect 2 shipped: the file read
# fine, and the parsed text was invalid shell/JSON.
#
# Defect 1 (3a): `gc events` returns only the newest 500 rows, warns on stderr
# only, and a `| jq` pipe hides its exit status. Session-lifecycle counts must
# come from the event-log segments, be exact past 500 rows, count a row once
# when a rotation race shows it in two segments, and report N/A — never 0 —
# whenever the count cannot be known.
#
# Defect 2 (step 3): the `--metadata` JSON must survive TOML unescaping.
#
# FORMULA=<path> overrides the file under test (used to prove this harness
# fails against the pre-fix formula).  Exit 0 iff every assertion holds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORMULA="${FORMULA:-$HERE/../formulas/mol-digest-generate.toml}"

P=0; F=0
ok(){ echo "  ok: $*"; P=$((P+1)); }
bad(){ echo "  BAD: $*"; F=$((F+1)); }

echo "== mol-digest-generate.selftest (ga-hnlog4) =="
[ -f "$FORMULA" ] || { echo "FATAL: $FORMULA not found"; exit 1; }
command -v python3 >/dev/null && command -v jq >/dev/null || { echo "FATAL: python3 and jq required"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- extraction of DELIVERED text --------------------------------------------
# region <step-id> <begin-marker> <end-marker>: delivered lines between markers.
# fence  <step-id> <needle>: the delivered fenced code block containing needle.
extract() { python3 - "$FORMULA" "$@" <<'PY'
import sys, tomllib
path, mode, step, a = sys.argv[1:5]
b = sys.argv[5] if len(sys.argv) > 5 else None
d = tomllib.load(open(path, "rb"))
text = next(s["description"] for s in d["steps"] if s["id"] == step)
lines = text.split("\n")
out = []
if mode == "region":
    on = False
    for l in lines:
        if b in l and on: break
        if on: out.append(l)
        if a in l: on = True
elif mode == "fence":
    blk = None
    for l in lines:
        if l.startswith("```"):
            if blk is None: blk = []
            else:
                if any(a in x for x in blk): out = blk; break
                blk = None
        elif blk is not None: blk.append(l)
sys.stdout.write("\n".join(out) + ("\n" if out else ""))
PY
}

# ---- fixture: a fake city event log ------------------------------------------
# Window under test: SINCE=2026-09-25T00:00:00Z .. UNTIL=2026-09-26T00:00:00Z.
# The generator computes the expected counts itself (python datetimes), so the
# recipe's jq is never checked against itself.
cat > "$TMP/gen.py" <<'PY'
import gzip, json, os, sys, datetime as dt
root = sys.argv[1]
os.makedirs(root + "/.gc")
UTC = dt.timezone.utc; BRT = dt.timezone(dt.timedelta(hours=-3))
S = dt.datetime(2026, 9, 25, tzinfo=UTC); U = dt.datetime(2026, 9, 26, tzinfo=UTC)
def T(*a): return dt.datetime(*a, tzinfo=UTC)
seq = [1000]; truth = {"session.woke": set(), "session.stopped": set(), "session.crashed": set()}
def ts(t, style):
    if style == "Z": return t.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    if style == "utc0": return t.astimezone(UTC).isoformat()
    return t.astimezone(BRT).isoformat()
def row(typ, t, style="brt", seq_=None):
    if seq_ is None: seq[0] += 1; seq_ = seq[0]
    if typ in truth and S <= t < U: truth[typ].add(seq_)
    return {"seq": seq_, "type": typ, "ts": ts(t, style), "actor": "gc", "subject": "x"}
def spread(typ, t0, n, step_s, style="brt"):
    return [row(typ, t0 + dt.timedelta(seconds=step_s * i), style) for i in range(n)]
def write(name, rows, gz=True):
    body = "".join(json.dumps(r) + "\n" for r in rows).encode()
    p = root + "/.gc/" + name
    (gzip.open(p, "wb") if gz else open(p, "wb")).write(body)
def rot(t): return row("events.rotated", t)

# unneeded, corrupt archive older than SINCE: proves it is never read
open(root + "/.gc/events.jsonl.archive-20260920T091533Z-seq-1-2.gz", "wb").write(b"not gzip at all")
# A: rotation stamp 9/24 04:13Z < SINCE -> never needed
A = [rot(T(2026, 9, 23, 3, 0, 0))] + spread("session.woke", T(2026, 9, 23, 4), 40, 60) + spread("session.stopped", T(2026, 9, 23, 5), 30, 60)
A += spread("session.crashed", T(2026, 9, 23, 6), 1, 60)                      # before window
write("events.jsonl.archive-20260924T041351Z-seq-1001-1100.gz", A)
# B: 9/24 04:13Z .. 9/25 17:54Z (straddles SINCE)
B = [rot(T(2026, 9, 24, 4, 13, 51))]
B += spread("session.woke", T(2026, 9, 24, 10), 20, 60)                       # before window
B += [row("session.woke", dt.datetime(2026, 9, 24, 20, 59, 59, tzinfo=BRT))]  # 23:59:59Z  -> out
B += [row("session.woke", dt.datetime(2026, 9, 24, 21, 0, 0, tzinfo=BRT))]    # exactly SINCE -> in
B += spread("session.woke", T(2026, 9, 25, 0, 1), 300, 30)
B += spread("session.woke", T(2026, 9, 25, 3, 0), 5, 60, "Z") + spread("session.woke", T(2026, 9, 25, 3, 10), 5, 60, "utc0")
B += spread("session.stopped", T(2026, 9, 24, 12), 10, 60) + spread("session.stopped", T(2026, 9, 25, 1), 200, 30)
B += spread("bead.closed", T(2026, 9, 25, 2), 50, 60)                          # noise
B += spread("session.crashed", T(2026, 9, 25, 4), 2, 60)
write("events.jsonl.archive-20260925T175422Z-seq-1101-1900.gz", B)
# C: 9/25 17:54Z .. 9/26 13:11Z (straddles UNTIL)
C = [rot(T(2026, 9, 25, 17, 54, 22))]
C += spread("session.woke", T(2026, 9, 25, 18), 300, 60)
C += [row("session.woke", dt.datetime(2026, 9, 25, 20, 59, 59, tzinfo=BRT))]  # 23:59:59Z -> in
dup = row("session.woke", T(2026, 9, 25, 19, 30, 0, 500000))                  # will also appear in live
C += [row("session.woke", dt.datetime(2026, 9, 25, 21, 0, 0, tzinfo=BRT))]    # exactly UNTIL -> out
C += [row("session.woke", dt.datetime(2026, 9, 25, 22, 30, 0, tzinfo=BRT))]   # 01:30Z 9/26 -> out; sorts BEFORE UNTIL as a raw string
C += spread("session.woke", T(2026, 9, 26, 1), 15, 60)
C += spread("session.stopped", T(2026, 9, 25, 18), 200, 60) + [dup]
C += spread("session.crashed", T(2026, 9, 25, 19), 1, 60) + spread("session.crashed", T(2026, 9, 26, 2), 1, 60)
write("events.jsonl.archive-20260926T131152Z-seq-1901-2900.gz", C)
# live: after UNTIL, plus a rotation-race duplicate of an in-window row
L = [rot(T(2026, 9, 26, 13, 11, 52))] + spread("session.woke", T(2026, 9, 26, 13, 12), 8, 60)
L += [dup] + spread("bead.closed", T(2026, 9, 26, 13, 13), 5, 10)
write("events.jsonl", L, gz=False)
json.dump({"woke": len(truth["session.woke"]), "stopped": len(truth["session.stopped"]), "crashed": len(truth["session.crashed"])}, open(root + "/expected.json", "w"))
PY
CITY="$TMP/city"; python3 "$TMP/gen.py" "$CITY" || { echo "FATAL: fixture generation failed"; exit 1; }
EXP_W=$(jq -r .woke "$CITY/expected.json"); EXP_S=$(jq -r .stopped "$CITY/expected.json"); EXP_C=$(jq -r .crashed "$CITY/expected.json")

# a `gc` that behaves like the real one under load, to prove the recipe does not depend on it
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gc" <<'STUB'
#!/usr/bin/env bash
echo "Error: context deadline exceeded" >&2
exit 1
STUB
chmod +x "$TMP/bin/gc"

# ---- defect 1: session lifecycle counts ---------------------------------------
BLOCK="$TMP/lifecycle.sh"
extract region collect-data "# BEGIN session-lifecycle-counts" "# END session-lifecycle-counts" > "$BLOCK"
if [ ! -s "$BLOCK" ]; then
  bad "collect-data has no '# BEGIN/END session-lifecycle-counts' block — 3a still calls the capped 'gc events'"
else
  # run_block <shell> <city> <since> <until> -> "woke=<n> stopped=<n>"
  run_block() {
    PATH="$TMP/bin:$PATH" GC_CITY_PATH="$2" SINCE="$3" UNTIL="$4" "$1" "$BLOCK" 2>/dev/null | tail -n 1
  }
  W0=2026-09-25T00:00:00Z; W1=2026-09-26T00:00:00Z

  echo "-- exact counts past the 500-row cap, gc unusable"
  if [ "$EXP_W" -gt 500 ]; then ok "fixture is past the CLI cap ($EXP_W woke > 500)"; else bad "fixture too small to exercise the cap ($EXP_W)"; fi
  for sh in bash zsh; do
    command -v "$sh" >/dev/null || { echo "  (skip $sh: not installed)"; continue; }
    got=$(run_block "$sh" "$CITY" "$W0" "$W1")
    want="session.woke=$EXP_W session.stopped=$EXP_S session.crashed=$EXP_C"
    [ "$got" = "$want" ] && ok "$sh: $got" || bad "$sh: got '$got', want '$want'"
  done

  echo "-- a count that cannot be known is N/A, never 0"
  got=$(run_block bash "$TMP/nonexistent" "$W0" "$W1")
  [ "$got" = "session.woke=N/A session.stopped=N/A session.crashed=N/A" ] && ok "no event log -> N/A" || bad "no event log: got '$got'"

  cp -R "$CITY" "$TMP/city-corrupt"
  printf 'not gzip' > "$TMP/city-corrupt/.gc/events.jsonl.archive-20260926T131152Z-seq-1901-2900.gz"
  got=$(run_block bash "$TMP/city-corrupt" "$W0" "$W1")
  [ "$got" = "session.woke=N/A session.stopped=N/A session.crashed=N/A" ] && ok "corrupt needed archive -> N/A" || bad "corrupt archive: got '$got'"

  # 9/21 is after the corrupt archive's stamp (9/20), so the oldest SELECTED
  # segment is archive A, whose first event (9/23) is later than SINCE: the
  # coverage check, not an unreadable file, is what must say N/A here.
  got=$(run_block bash "$CITY" "2026-09-21T00:00:00Z" "2026-09-22T00:00:00Z")
  [ "$got" = "session.woke=N/A session.stopped=N/A session.crashed=N/A" ] && ok "window older than the oldest kept segment -> N/A" || bad "pruned coverage: got '$got'"

  echo "-- a covered but quiet window is a real 0"
  got=$(run_block bash "$CITY" "2026-09-26T13:30:00Z" "2026-09-26T13:40:00Z")
  [ "$got" = "session.woke=0 session.stopped=0 session.crashed=0" ] && ok "quiet window -> 0" || bad "quiet window: got '$got'"
fi

# the capped CLI call must be gone from the session-lifecycle step text
if extract fence collect-data 'session.woke' | grep -q 'gc events --since'; then
  bad "collect-data still pipes 'gc events --since' (500-row cap) for session events"
else
  ok "no capped 'gc events --since' call for session events"
fi

# ---- defect 2: --metadata must be valid JSON as delivered ---------------------
echo "-- step 3 archive command, as delivered"
CREATE="$TMP/create.sh"
extract fence generate-and-send 'gc bd create --type=message' | sed -e 's/{{period}}/daily/g' -e 's/{{date}}/2026-09-25/g' > "$CREATE"
if [ ! -s "$CREATE" ]; then
  bad "no delivered block with 'gc bd create --type=message'"
else
  cat > "$TMP/bin/gc" <<STUB
#!/usr/bin/env bash
# records every argument on its own line; \`bd create\` answers with an id
if [ "\$1 \$2" = "bd create" ]; then printf '%s\n' "\$@" > "$TMP/create.args"; echo wisp-test1; fi
STUB
  rm -f "$TMP/create.args"
  PATH="$TMP/bin:$PATH" SINCE=2026-09-25T00:00:00Z UNTIL=2026-09-26T00:00:00Z DATE=2026-09-25 bash "$CREATE" >/dev/null 2>&1
  META=$(awk 'f{print; exit} $0=="--metadata"{f=1}' "$TMP/create.args" 2>/dev/null)
  if printf '%s' "$META" | jq -e '.["digest.since"] == "2026-09-25T00:00:00Z" and .["digest.until"] == "2026-09-26T00:00:00Z"' >/dev/null 2>&1; then
    ok "--metadata parses and carries digest.since/digest.until"
  else
    bad "--metadata is not the expected JSON; the agent would pass: '$META'"
  fi
fi

echo "== $P ok, $F bad =="
[ "$F" -eq 0 ]
