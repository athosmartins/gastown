#!/usr/bin/env bash
# pilot-dispatcher.rig-list-once.selftest.sh — ga-it7qiq: `gc rig list --json` is read ONCE per sweep.
#
# Why it exists. On 20/10 a Pilot sweep took 25-40 min against a 10 min interval. Measured (replay of the emit, load 44):
# `gc rig list --json` costs 35-60 s per call and the sweep made ~20 of them — 7 of them inside the painel emit alone,
# because _filter_built -> _ownership_guard_repos fetched the list afresh for every store: the ga-130et memo only
# survives if it is filled in the PARENT shell, and _ownership_guard_repos_prime ran at L6609, AFTER the emit (L5427)
# (ga-2wcz6 moved the function definition up and left the prime behind). The rest of the sweep re-reads it at ~12
# top-level sites. The list cannot change in a way that matters inside one sweep.
#
# The contract proved here:
#   (1) CACHE: after _pilot_rig_list_prime stored a GOOD answer, the exact read
#       `gc_json_or_unknown gc --city "$GC_CITY" rig list --json` is served from memory by the gc() shadow function —
#       from $(...), from a pipe stage, from a plain subshell and from a while-read loop — and the binary is not called
#       again. gc_json_or_unknown itself is NOT touched: it must stay byte-identical across its 4 production copies
#       (gc-json-or-unknown.selftest.sh drift guard).
#   (2) ONLY that read: any other command (session list, another city, rig list without --json) still reaches gc.
#   (3) THREE states: a failed / empty / ok:false answer is NOT cached — every later site retries exactly as before
#       (never worse than the old behaviour), and a later prime can still succeed. "could not read" never becomes
#       "the rig list is empty".
#   (4) ORDER on the REAL file (call-graph analysis): the prime runs before the first top-level statement that can reach
#       a rig-list fetch, and the repo-list prime runs before the painel emit. Non-vacuous: the analysis must see the emit
#       and _filter_built as fetch-reaching, and a mutant that puts the primes after the emit must be rejected.
#   (5) EMIT SHAPE: after the primes, 7 emit-like _filter_built calls (each in its own $(...) + pipe) cost ONE gc call;
#       without the primes (negative control, the HEAD behaviour) they cost one per call.
#
# Runs against function bodies extracted from the dispatcher (same idiom as pilot-dispatcher.ns-rig-list-gc-failure).
# Env: RLO_DISPATCHER_UNDER_TEST points at a mutant dispatcher; RLO_SKIP_MUTATION=1 skips the mutation controls.
# Exit 0 iff every check holds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${RLO_DISPATCHER_UNDER_TEST:-$HERE/pilot-dispatcher.sh}"
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

extract_fn() { awk -v fn="$1" '$0 == fn"() {" { p=1 } p { print; if ($0 == "}") exit }' "$2"; }

P=0; F=0
ok()  { echo "  ok: $*"; P=$((P+1)); }
bad() { echo "  BAD: $*"; F=$((F+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ga-it7qiq-selftest.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

echo "== pilot-dispatcher.rig-list-once.selftest (ga-it7qiq) =="

warn() { :; }
log()  { :; }

# ── load the real functions ────────────────────────────────────────────────────────────────
HAVE_PRIME=1
for fn in gc_json_or_unknown gc _pilot_rig_list_prime _ownership_guard_repos _ownership_guard_repos_prime _filter_built; do
  src="$(extract_fn "$fn" "$DISPATCHER")"
  if [ -z "$src" ]; then
    bad "$fn() is not defined in the dispatcher"
    { [ "$fn" = _pilot_rig_list_prime ] || [ "$fn" = gc ]; } && HAVE_PRIME=0
    [ "$fn" = gc_json_or_unknown ] && { echo "FATAL: cannot continue without gc_json_or_unknown" >&2; exit 2; }
    continue
  fi
  eval "$src"
done

# ── a counting stub gc; its answer is switched through a mode file ────────────────────────
BIN="$TMP/bin"; mkdir -p "$BIN"
CALLS="$TMP/gc.calls"; MODE="$TMP/gc.mode"; : > "$CALLS"; echo ok > "$MODE"
cat > "$BIN/gc" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
case "\$(cat "$MODE")" in
  ok)      echo '{"ok":true,"rigs":[{"name":"wa","path":"/p/wa","hq":false},{"name":"hq","path":"/p/hq","hq":true}]}' ;;
  fail)    exit 1 ;;
  empty)   exit 0 ;;
  okfalse) echo '{"ok":false,"error":"x"}' ;;
  session) echo '{"ok":true,"sessions":[]}' ;;
  cat)     cat ;;
  rc7)     echo '{"ok":true}'; exit 7 ;;
esac
EOF
chmod +x "$BIN/gc"
SANDBOX_PATH="$BIN:$PATH"
GC_CITY="$TMP/city"; mkdir -p "$GC_CITY"
rigcalls() { grep -c 'rig list' "$CALLS" 2>/dev/null || true; }
reset() { : > "$CALLS"; _PILOT_RIG_LIST_JSON=""; _OWNERSHIP_GUARD_REPOS=""; _OWNERSHIP_GUARD_REPOS_DONE=""; _OWNERSHIP_GUARD_REPOS_FAILED=""; echo ok > "$MODE"; }
RIG() { PATH="$SANDBOX_PATH" gc_json_or_unknown gc --city "$GC_CITY" rig list --json; }

# ── 1. cache ──────────────────────────────────────────────────────────────────────────────
echo "-- 1. after a good prime the exact read never reaches gc again, whatever subshell shape asks --"
reset
RIG >/dev/null; RIG >/dev/null
if [ "$(rigcalls)" = "2" ]; then ok "no prime: every read hits gc (baseline, 2 reads = 2 calls)"; else bad "baseline expected 2 gc calls, got $(rigcalls)"; fi
if [ "$HAVE_PRIME" = "1" ]; then
  reset
  PATH="$SANDBOX_PATH" _pilot_rig_list_prime; PRC=$?
  [ "$PRC" = "0" ] && ok "prime returns 0 on a good answer" || bad "prime returned $PRC on a good answer"
  A="$(RIG)"; B="$(RIG | cat)"; C="$( ( RIG ) )"; D=""; while IFS= read -r l; do D="$(RIG)"; done <<< "x"
  if [ "$(rigcalls)" = "1" ]; then ok "prime + 4 reads (\$(), pipe stage, subshell, while-read) = ONE gc call"; else bad "expected 1 gc call after prime, got $(rigcalls)"; fi
  if [ "$A" = "$B" ] && [ "$B" = "$C" ] && [ "$C" = "$D" ] && printf '%s' "$A" | jq -e '.rigs | length == 2' >/dev/null 2>&1; then
    ok "every cached read returns the same, parseable rig list"
  else bad "cached reads differ or are unreadable: A=[$A] B=[$B]"; fi
else
  bad "cannot test the cache: _pilot_rig_list_prime missing"
fi

# ── 2. only that read ─────────────────────────────────────────────────────────────────────
echo "-- 2. the cache answers ONLY the exact rig-list read --"
if [ "$HAVE_PRIME" = "1" ]; then
  reset; PATH="$SANDBOX_PATH" _pilot_rig_list_prime; : > "$CALLS"; echo session > "$MODE"
  S="$(PATH="$SANDBOX_PATH" gc_json_or_unknown gc --city "$GC_CITY" session list --json)"
  O="$(PATH="$SANDBOX_PATH" gc_json_or_unknown gc --city "/some/other/city" rig list --json)"
  N="$(PATH="$SANDBOX_PATH" gc_json_or_unknown gc --city "$GC_CITY" rig list)"
  if [ "$(wc -l < "$CALLS" | tr -d ' ')" = "3" ]; then ok "session list / other city / no --json all reached gc (3 calls)"; else bad "expected 3 gc calls, got $(wc -l < "$CALLS" | tr -d ' '): $(tr '\n' '|' < "$CALLS")"; fi
  case "$S$O$N" in *'"rigs"'*) bad "a different command was answered with the cached rig list" ;; *) ok "none of them was answered with the cached rig list" ;; esac
else bad "cannot test: prime missing"; fi

echo "-- 2b. transparent for everything else: exit status, stdin and extra arguments reach the binary --"
if [ "$HAVE_PRIME" = "1" ]; then
  reset; PATH="$SANDBOX_PATH" _pilot_rig_list_prime; : > "$CALLS"; echo rc7 > "$MODE"
  PATH="$SANDBOX_PATH" gc --city "$GC_CITY" status; R7=$?
  [ "$R7" = "7" ] && ok "the binary's exit status (7) passes through the shadow" || bad "exit status through the shadow was $R7 (want 7)"
  echo cat > "$MODE"; GOT_IN="$(printf 'payload' | PATH="$SANDBOX_PATH" gc --city "$GC_CITY" session submit)"
  [ "$GOT_IN" = "payload" ] && ok "stdin passes through the shadow to the binary" || bad "stdin was lost through the shadow: [$GOT_IN]"
  echo session > "$MODE"; : > "$CALLS"
  PATH="$SANDBOX_PATH" gc --city "$GC_CITY" rig list --json --verbose >/dev/null
  [ "$(wc -l < "$CALLS" | tr -d ' ')" = "1" ] && ok "a sixth argument ('rig list --json --verbose') is not the cached read: it reached the binary" || bad "an extra argument was answered from the cache"
else bad "cannot test: prime / gc shadow missing"; fi

# ── 3. three states ───────────────────────────────────────────────────────────────────────
echo "-- 3. a failed / empty / ok:false answer is NOT cached; sites keep retrying as before --"
if [ "$HAVE_PRIME" = "1" ]; then
  for mode in fail empty okfalse; do
    reset; echo "$mode" > "$MODE"
    PATH="$SANDBOX_PATH" _pilot_rig_list_prime; PRC=$?
    RIG >/dev/null 2>&1; RIG >/dev/null 2>&1
    n="$(rigcalls)"
    if [ "$PRC" != "0" ] && [ "$n" = "3" ]; then ok "mode=$mode: prime fails (rc $PRC), nothing cached, the 2 later reads each retried (3 gc calls)"
    else bad "mode=$mode: prime rc=$PRC, gc calls=$n (want rc!=0 and 3 calls)"; fi
  done
  reset; echo fail > "$MODE"; PATH="$SANDBOX_PATH" _pilot_rig_list_prime; echo ok > "$MODE"; PATH="$SANDBOX_PATH" _pilot_rig_list_prime; PRC=$?; : > "$CALLS"; RIG >/dev/null
  if [ "$PRC" = "0" ] && [ "$(rigcalls)" = "0" ]; then ok "a prime that fails first can still succeed later, and then serves the cache"; else bad "recovery prime: rc=$PRC, calls after=$(rigcalls)"; fi
else bad "cannot test: prime missing"; fi

# ── 4. order on the REAL file ─────────────────────────────────────────────────────────────
echo "-- 4. ordering on the real dispatcher: primes run before anything that can fetch, and before the painel emit --"
cat > "$TMP/order.py" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
FN_OPEN = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{")
def strip_comment(ln):
    # drop a trailing ` # ...` only when the text before it has balanced quotes (a `#` inside a string stays)
    for m in re.finditer(r"\s#", ln):
        head = ln[:m.start()]
        if head.count('"') % 2 == 0 and head.count("'") % 2 == 0:
            return head
    return ln
defs, top, cur = {}, [], None
for no, ln in enumerate(lines, 1):
    code = "" if ln.lstrip().startswith("#") else strip_comment(ln)
    if cur is None:
        m = FN_OPEN.match(ln)
        if m:
            if ln.rstrip().endswith("}") and ln.count("{") == ln.count("}"):
                defs[m.group(1)] = ln
            else:
                cur = m.group(1); defs[cur] = code
        elif code.strip():
            top.append((no, code))
    else:
        defs[cur] += "\n" + code
        if re.match(r"^\}\s*$", ln):
            cur = None
ident = lambda f: re.compile(r"(?<![A-Za-z0-9_])" + re.escape(f) + r"(?![A-Za-z0-9_])")
# a real read = a call of gc_json_or_unknown (or gc itself) on `rig list --json`. The memo layer and the prime mention the
# text too (the cache key / the one allowed fetch) but are not call sites that cost a fetch, so they never seed the set.
fetch = re.compile(r"gc_json_or_unknown\s+gc\b[^\n]*\brig list --json|(?<![A-Za-z0-9_])gc\s+--city\b[^\n]*\brig list --json")
MEMO = {"gc_json_or_unknown", "gc", "_pilot_rig_list_prime"}
reach = {n for n, b in defs.items() if n not in MEMO and fetch.search(b)}
changed = True
while changed:
    changed = False
    for n, b in defs.items():
        if n not in reach and n not in MEMO and any(ident(f).search(b) for f in reach):
            reach.add(n); changed = True
missing = [f for f in ("_pilot_emit_dispatchable", "_filter_built", "_ownership_guard_repos_prime") if f not in reach]
if missing:
    print("VACUOUS: not seen as reaching a rig-list fetch: " + ", ".join(missing)); sys.exit(2)
cmd_word = lambda code: code.strip().split(None, 1)[0] if code.strip() else ""
def first_call(name):
    for no, code in top:
        if cmd_word(code) == name:
            return no
    return None
prime = first_call("_pilot_rig_list_prime")
repo_prime = first_call("_ownership_guard_repos_prime")
emit = first_call("_pilot_emit_dispatchable")
if prime is None or repo_prime is None or emit is None:
    print("MISSING top-level call: prime=%s repo_prime=%s emit=%s" % (prime, repo_prime, emit)); sys.exit(1)
hits = []
for no, code in top:
    if cmd_word(code) in ("warn", "log", "echo", "_pilot_rig_list_prime"):
        continue
    for f in sorted(reach):
        if ident(f).search(code):
            hits.append((no, f)); break
    else:
        if fetch.search(code):
            hits.append((no, "<top-level fetch>"))
first_no, first_fn = min(hits)
problems = []
if not prime < first_no:
    problems.append("rig-list prime at L%d is not before the first top-level statement that can fetch (L%d %s)" % (prime, first_no, first_fn))
if not repo_prime < emit:
    problems.append("_ownership_guard_repos_prime first called at L%d, AFTER the painel emit at L%d: every store's _filter_built refetches" % (repo_prime, emit))
if problems:
    print("; ".join(problems)); sys.exit(1)
print("rig-list prime L%d < repo prime L%d < emit L%d; first other fetch-reaching statement L%d (%s)" % (prime, repo_prime, emit, first_no, first_fn))
PY
if ! command -v python3 >/dev/null 2>&1; then bad "python3 missing — ordering NOT checked"; else
  OUT="$(python3 -I "$TMP/order.py" "$DISPATCHER" 2>&1)"; RC=$?
  case "$RC" in 0) ok "$OUT" ;; 1) bad "$OUT" ;; *) bad "ordering analysis could not run: $OUT" ;; esac
fi

# ── 5. the emit shape ─────────────────────────────────────────────────────────────────────
echo "-- 5. emit-like: 7 stores, each _filter_built in its own \$(...) + pipe --"
emit_like() { local i; for i in 1 2 3 4 5 6 7; do _x="$(printf '[]' | PATH="$SANDBOX_PATH" _filter_built 2>/dev/null)"; done; }
reset; emit_like
NEG="$(rigcalls)"
if [ "$NEG" -ge 7 ] 2>/dev/null; then ok "negative control (HEAD behaviour, no primes): 7 stores = $NEG gc rig list calls"; else bad "negative control did not reproduce the refetch storm (got $NEG, want >= 7)"; fi
if [ "$HAVE_PRIME" = "1" ]; then
  reset
  PATH="$SANDBOX_PATH" _pilot_rig_list_prime || true
  PATH="$SANDBOX_PATH" _ownership_guard_repos_prime || true
  emit_like
  POS="$(rigcalls)"
  if [ "$POS" = "1" ]; then ok "with the primes: the same 7 stores = ONE gc rig list call"; else bad "with the primes the emit shape still made $POS gc calls (want 1)"; fi
else bad "cannot test: prime missing"; fi

# ── 6. mutation controls ──────────────────────────────────────────────────────────────────
if [ "${RLO_SKIP_MUTATION:-0}" != "1" ] && [ "$HAVE_PRIME" = "1" ] && [ -z "${RLO_DISPATCHER_UNDER_TEST:-}" ]; then
  echo "-- 6. mutation controls: each reverts one property and THIS file must fail --"
  # mutant A: the primes run after the emit again (the HEAD layout)
  python3 -I - "$DISPATCHER" "$TMP/mutA.sh" <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf-8").read().split("\n")
out, moved = [], []
for ln in t:
    if re.match(r"^_pilot_rig_list_prime( \|\| true)?\s*$", ln) or (re.match(r"^_ownership_guard_repos_prime( \|\| true)?\s*$", ln) and not moved):
        moved.append(ln); continue
    out.append(ln)
idx = max(i for i, l in enumerate(out) if re.match(r"^_ttl_recover_db ", l))
out[idx:idx] = moved
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(out))
PY
  RLO_DISPATCHER_UNDER_TEST="$TMP/mutA.sh" RLO_SKIP_MUTATION=1 bash "$HERE/$(basename "${BASH_SOURCE[0]}")" >"$TMP/mutA.out" 2>&1 \
    && bad "mutant A (primes after the emit) was NOT rejected" || ok "mutant A (primes after the emit) is rejected"
  # mutant B: the shadow never serves the cache
  python3 -I - "$DISPATCHER" "$TMP/mutB.sh" <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
t2 = t.replace('if [ -n "${_PILOT_RIG_LIST_JSON:-}" ] && [ "$#" -eq 5 ]', 'if false && [ "$#" -eq 5 ]', 1)
assert t2 != t, "anchor B not found"
open(sys.argv[2], "w", encoding="utf-8").write(t2)
PY
  RLO_DISPATCHER_UNDER_TEST="$TMP/mutB.sh" RLO_SKIP_MUTATION=1 bash "$HERE/$(basename "${BASH_SOURCE[0]}")" >"$TMP/mutB.out" 2>&1 \
    && bad "mutant B (cache never served) was NOT rejected" || ok "mutant B (cache never served) is rejected"
  # mutant C: the shadow serves the rig list for ANY city
  python3 -I - "$DISPATCHER" "$TMP/mutC.sh" <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
t2 = t.replace(' && [ "$2" = "${GC_CITY:-}" ]', '', 1)
assert t2 != t, "anchor C not found"
open(sys.argv[2], "w", encoding="utf-8").write(t2)
PY
  RLO_DISPATCHER_UNDER_TEST="$TMP/mutC.sh" RLO_SKIP_MUTATION=1 bash "$HERE/$(basename "${BASH_SOURCE[0]}")" >"$TMP/mutC.out" 2>&1 \
    && bad "mutant C (any city served from the cache) was NOT rejected" || ok "mutant C (any city served from the cache) is rejected"
fi

echo
echo "== rig-list-once: $P passed, $F failed =="
[ "$F" -eq 0 ]
