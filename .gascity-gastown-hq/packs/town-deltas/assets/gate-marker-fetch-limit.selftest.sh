#!/usr/bin/env bash
# gate-marker-fetch-limit.selftest.sh (ga-jnajhn, 2026-09-26)
#
# THE CLASS: a `bd list` that SWEEPS a set (counts it, decides on it, iterates it)
# but passes no --limit. `bd list --help` documents "default 50, use 0 for
# unlimited" and returns NEWEST-first, so on a set > 50 the cut removes the
# OLDEST items. For the gate queue that is exactly the overdue marker the
# aging / hard-ceiling tiers exist to protect, and the dispatcher log only says
# "Found 50 queued marker(s)".
#
# Measured 26/09/2026 on the live bd 1.1.0 binary: the default did NOT cap
# (e.g. `--status closed` returned 20461 rows with no --limit, while an explicit
# `--limit 50` returned 50). So this is a contract / portability guard, not a
# repro of an active outage: the dispatcher must not depend on an undocumented
# default that --help contradicts and that another build (or a wrapper) may
# honour. The harness below therefore stubs bd with the DOCUMENTED contract.
#
# Three proofs:
#   1. Static class guard — every set-reading `bd ... list` in the dispatcher
#      carries --limit. The scanner asserts a MINIMUM sweep count (a regex that
#      silently matches nothing must not read as "clean") and is itself proven
#      to flag a synthetic violation.
#   2. Behaviour on the REAL extracted fetch block (sentinel "marker-fetch") and
#      the REAL selection block (sentinel "marker-select"): 60 queued markers,
#      the only overdue one is the OLDEST, and the stub honours the documented
#      contract. The overdue marker must be fetched and selected.
#   3. Mutation control — the same block with ` --limit 0` stripped must fetch
#      exactly 50, lose the oldest marker and select the wrong one. Without this,
#      a stub that never truncates would let every assertion above pass vacuously.
#      (No `git show HEAD` self-certification: at any committed state HEAD is the
#      fix, so that comparison cannot be observed — see the sibling
#      gate-priority-starvation-ceiling.selftest.sh header.)
#   Also: the read-cache shim keys on the full argv, so --limit 0 and no --limit
#   never share a cache slot.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
WRAPPER="$SELF_DIR/../../../scripts/bd-list-cached.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-marker-fetch-limit.selftest (ga-jnajhn) =="

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
[ -f "$WRAPPER" ]    || { echo "FATAL: bd-list-cached.sh not found at $WRAPPER" >&2; exit 2; }
command -v jq >/dev/null 2>&1      || { echo "FATAL: jq required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── 1. static class guard ────────────────────────────────────────────────────
echo "── (1) every set-reading bd list in the dispatcher carries --limit ──"

cat > "$TMP/scan.py" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().split("\n")
logical, buf, start = [], "", 0
for n, line in enumerate(lines, 1):
    if not buf:
        start = n
    if line.rstrip().endswith("\\"):
        buf += line.rstrip()[:-1] + " "
        continue
    buf += line
    logical.append((start, buf))
    buf = ""
# `bd [-C x] list` and `bd-list-cached.sh [-C x] list`; NOT `gc ... session list`,
# `gc rig list`, `bd dep list` (a different subcommand between bd and list).
pat = re.compile(r'(?:\bbd\b|bd-list-cached\.sh"?)\s+(?:(?:-C|--city)\s+(?:"[^"]*"|\S+)\s+)?list\b')
found = bad = 0
for n, text in logical:
    if text.lstrip().startswith("#"):
        continue
    # A backtick-quoted `bd ... list` is documentation (an operator instruction in
    # a bead comment, or an inline code comment), never executed: this file runs
    # commands via $(...), not backtick substitution.
    ms = [m for m in pat.finditer(text)
          if not re.search(r'`\\?$', text[:m.start()])]
    for i, m in enumerate(ms):
        end = ms[i + 1].start() if i + 1 < len(ms) else len(text)
        found += 1
        if not re.search(r'--limit[ =]', text[m.end():end]):
            bad += 1
            print("UNBOUNDED line %d: %s" % (n, text.strip()[:110]))
print("SWEEPS %d" % found)
print("BAD %d" % bad)
PY

# scanner self-check: a synthetic bounded + a synthetic unbounded call.
cat > "$TMP/synthetic.sh" <<'SYN'
A=$(bd -C "$C" list --json --limit 0 \
  -l x)
B=$(bash "$C/scripts/bd-list-cached.sh" -C "$C" list --json \
  -l y)
# bd -C "$C" list --json   <- comment, ignored
D=$(gc --city "$C" session list --json)
E=$(bd dep list "$ID" --json)
F="ACTION: run `bd -C $C list --label source-bead:$ID --all` by hand"
G() {  # true iff present in `bd list --json <args>`
SYN
SYN_OUT="$(python3 "$TMP/scan.py" "$TMP/synthetic.sh")"
[ "$(printf '%s\n' "$SYN_OUT" | sed -n 's/^SWEEPS //p')" = "2" ] \
  && ok "scanner sees exactly the 2 bd sweeps in the synthetic file (ignores comment, gc session list, bd dep list, backtick-quoted prose)" \
  || bad "scanner miscounted synthetic sweeps: $(printf '%s' "$SYN_OUT" | tr '\n' '|')"
[ "$(printf '%s\n' "$SYN_OUT" | sed -n 's/^BAD //p')" = "1" ] \
  && ok "scanner flags the one unbounded synthetic call (a multi-line continuation is joined)" \
  || bad "scanner failed to flag the unbounded synthetic call: $(printf '%s' "$SYN_OUT" | tr '\n' '|')"

REAL_OUT="$(python3 "$TMP/scan.py" "$DISPATCHER")"
SWEEPS="$(printf '%s\n' "$REAL_OUT" | sed -n 's/^SWEEPS //p')"
BAD="$(printf '%s\n' "$REAL_OUT" | sed -n 's/^BAD //p')"
# Floor, not equality: adding a sweep must not break this test, but a regex that
# stopped matching (0) must. 9 = the 8 fixed by ga-jnajhn + _still_listed().
[ "${SWEEPS:-0}" -ge 9 ] \
  && ok "scanner found ${SWEEPS} set-reading bd list call(s) in the dispatcher (floor 9 — never a vacuous 0)" \
  || bad "scanner found only '${SWEEPS:-?}' bd list call(s) (<9) — regex drifted, or sweeps were removed"
[ "${BAD:-x}" = "0" ] \
  && ok "no unbounded bd list sweep in the dispatcher" \
  || bad "unbounded bd list sweep(s) — $(printf '%s' "$REAL_OUT" | grep '^UNBOUNDED' | tr '\n' ';')"

# ── 2. behaviour on the real blocks ──────────────────────────────────────────
echo "── (2) 60 queued markers, only the OLDEST overdue: it is fetched AND selected ──"

extract() { sed -n "/# SELFTEST-EXTRACT $2: BEGIN/,/# SELFTEST-EXTRACT $2: END/p" "$1"; }
FETCH_BLOCK="$(extract "$DISPATCHER" marker-fetch)"
SELECT_BLOCK="$(extract "$DISPATCHER" marker-select)"
[ -n "$FETCH_BLOCK" ] && [ -n "$SELECT_BLOCK" ] \
  && ok "located the live marker-fetch and marker-select blocks via sentinel extraction" \
  || { echo "FATAL: sentinel(s) missing (fetch=${#FETCH_BLOCK}B select=${#SELECT_BLOCK}B)" >&2; exit 2; }

NOW_EPOCH=1782863814
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
ago() { iso "$((NOW_EPOCH - $1))"; }

# 1 overdue (7200s > the 5400s hard ceiling) + 59 fresh, newest-first like bd.
{
  for i in $(seq 1 59); do
    who=mila; [ $((i % 3)) -eq 0 ] && who=oracle
    jq -cn --arg id "fresh-$i" --arg ts "$(ago $((60 + i * 20)))" --arg d "branch: crew/$who/fresh-$i" \
      '{id:$id, created_at:$ts, description:$d, labels:["gate-status:queued"]}'
  done
  jq -cn --arg id "oldest-overdue" --arg ts "$(ago 7200)" --arg d "branch: crew/mila/oldest-overdue" \
    '{id:$id, created_at:$ts, description:$d, labels:["gate-status:queued"]}'
} | jq -s 'sort_by(.created_at) | reverse' > "$TMP/fixture.json"
[ "$(jq length "$TMP/fixture.json")" = "60" ] && [ "$(jq -r '.[-1].id' "$TMP/fixture.json")" = "oldest-overdue" ] \
  && ok "fixture: 60 markers, newest-first, the oldest is the only overdue one" \
  || bad "fixture malformed"

FAKE_CITY="$TMP/city"; mkdir -p "$FAKE_CITY/scripts" "$TMP/cache"
cp "$WRAPPER" "$FAKE_CITY/scripts/bd-list-cached.sh"
cat > "$TMP/bd" <<'STUB'
#!/usr/bin/env bash
# bd list per its DOCUMENTED contract: newest-first, --limit default 50, 0 = unlimited.
lim=50; a=("$@")
for ((i = 0; i < ${#a[@]}; i++)); do [ "${a[i]}" = "--limit" ] && lim="${a[i+1]}"; done
if [ "$lim" = "0" ]; then jq -c '.' "$FIXTURE"; else jq -c --argjson n "$lim" '.[0:$n]' "$FIXTURE"; fi
STUB
chmod +x "$TMP/bd"

fetch() {  # $1 = fetch block; prints MARKERS_JSON. Cache OFF so every call is a live stub read.
  GC_CITY="$FAKE_CITY" BD_BIN="$TMP/bd" FIXTURE="$TMP/fixture.json" \
  BD_CACHE_OFF=1 BD_CACHE_DIR="$TMP/cache" \
  bash -c "$1"$'\nprintf "%s" "$MARKERS_JSON"' 2>/dev/null
}
select_marker() {  # $1 = MARKERS_JSON
  MARKERS_JSON="$1" \
  GATE_MARKER_NOW_OVERRIDE_EPOCH="$NOW_EPOCH" \
  GATE_MARKER_AGE_PROMOTE_SECONDS=1800 GATE_MARKER_HARD_AGE_SECONDS=5400 \
  GATE_PRIORITY_AUTHORS=oracle \
  bash -c "$SELECT_BLOCK"$'\necho "$MARKER_ID"' 2>/dev/null
}

GOT="$(fetch "$FETCH_BLOCK")"
N="$(printf '%s' "$GOT" | jq length 2>/dev/null || echo '?')"
[ "$N" = "60" ] && ok "real fetch block returns all 60 queued markers (not 50)" \
  || bad "real fetch block returned '$N' markers, expected 60"
printf '%s' "$GOT" | jq -e 'map(.id) | index("oldest-overdue") != null' >/dev/null 2>&1 \
  && ok "the OLDEST marker is in the fetched set" \
  || bad "the oldest marker was cut from the fetched set"
SEL="$(select_marker "$GOT")"
[ "$SEL" = "oldest-overdue" ] && ok "real selection picks the overdue oldest marker" \
  || bad "expected oldest-overdue, selection picked '$SEL'"

echo "── (3) mutation control: without --limit 0 the same block must lose it ──"
MUT_BLOCK="${FETCH_BLOCK// --limit 0/}"
[ "$MUT_BLOCK" != "$FETCH_BLOCK" ] && ok "mutation actually removed --limit 0 from the fetch block" \
  || bad "mutation was a no-op — the fetch block has no ' --limit 0' to strip"
MGOT="$(fetch "$MUT_BLOCK")"
MN="$(printf '%s' "$MGOT" | jq length 2>/dev/null || echo '?')"
[ "$MN" = "50" ] && ok "mutant fetch returns exactly 50 (the documented default cut — the stub is contract-faithful)" \
  || bad "mutant fetch returned '$MN', expected 50 — the stub is not exercising the default cap"
printf '%s' "$MGOT" | jq -e 'map(.id) | index("oldest-overdue") == null' >/dev/null 2>&1 \
  && ok "mutant loses the oldest marker (newest-first cut removes the overdue one)" \
  || bad "mutant unexpectedly still contains the oldest marker"
MSEL="$(select_marker "$MGOT")"
[ "$MSEL" != "oldest-overdue" ] && ok "mutant selects '$MSEL', not the overdue marker — the queue would starve it" \
  || bad "mutant still selected oldest-overdue — the test cannot tell fixed from broken"

# ── 4. cache key includes --limit ────────────────────────────────────────────
echo "── (4) read-cache shim: --limit 0 and no --limit never share a slot ──"
rm -rf "$TMP/cache2"; mkdir -p "$TMP/cache2"
shim() { BD_BIN="$TMP/bd" FIXTURE="$TMP/fixture.json" BD_CACHE_DIR="$TMP/cache2" BD_CACHE_TTL=60 \
         bash "$WRAPPER" -C testcity list --json --include-infra "$@" -l type:quality-gate-marker -l gate-status:queued 2>/dev/null; }
D1="$(shim | jq length)"            # no --limit → 50, now cached under its own key
L1="$(shim --limit 0 | jq length)"  # must NOT be served the 50-row slot
D2="$(shim | jq length)"            # and the no-limit slot is still its own
{ [ "$D1" = "50" ] && [ "$L1" = "60" ] && [ "$D2" = "50" ]; } \
  && ok "no-limit=50, --limit 0=60, no-limit again=50 — distinct cache slots (within TTL)" \
  || bad "cache slots collided: no-limit=$D1 limit0=$L1 no-limit-again=$D2"

echo
echo "gate-marker-fetch-limit selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
