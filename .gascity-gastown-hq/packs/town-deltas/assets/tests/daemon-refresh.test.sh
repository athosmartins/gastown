#!/usr/bin/env bash
# daemon-refresh.test.sh — unit tests for daemon-refresh.sh (ga-iwv0).
#
# Proves the post-deploy daemon-refresh helper:
#   1. Does nothing when no daemon code changed (no false restarts).
#   2. Auto-restarts an affected SAFE dashboard and verifies it came up
#      fresh (process start AFTER the deploy timestamp) → VERDICT=OK.
#   3. HALTS (VERDICT=VERIFY_FAILED, non-zero exit) when a restarted daemon
#      is still running stale (start time BEFORE deploy) — the dormant-deploy
#      case the bug is about; story:done must be impossible here.
#   4. Never auto-bounces a SENSITIVE hot-path daemon: it is flagged for a
#      guarded restart → VERDICT=NEEDS_GUARDED_RESTART, non-zero exit.
#   5. Resolves import-level changes: a changed routes/*.py module marks the
#      dashboard that imports it as affected (the exact ga-d81 scenario).
#   6. Resolves template-only changes: a changed *.html a dashboard renders via
#      render_template(...) marks it affected even with zero *.py changes (the
#      ga-jkj0 scenario — Jinja templates are cached in-process). An unrelated
#      template change (not referenced by any daemon) stays OK, no restart.
#   7. (ga-vmq1i) Emits a PROOF=verified|not_applicable|not_verified field
#      distinguishing a POSITIVE restart+fresh confirmation from a VERDICT=OK/
#      SKIPPED that never actually confirmed anything live is running the new
#      code — the caller (story-delivery.sh) must never say "verified in prod"
#      on anything but PROOF=verified.
#   8. (ga-j3j6s) Does NOT flag a SENSITIVE daemon for a guarded restart when
#      its live process already started after the deploy via some OTHER
#      restart path (e.g. the rig's own auto-deploy) — false-positive alarms
#      push a human toward an unnecessary hot-path restart. A genuinely-stale
#      SENSITIVE sibling in the SAME deploy still correctly wins the overall
#      verdict (NEEDS_GUARDED_RESTART is never masked).
#   9. (ga-00ptz) Discovers a daemon whose plist entrypoint lives under a
#      SEPARATE, independently-deployed clone of the same repo (e.g. real-world
#      painel-prod vs. whatsapp_automation) when that clone's root is listed in
#      EXTRA_RUNTIME_ROOTS — instead of silently dropping it from discovery and
#      reporting the false "touches no live daemon".
#  10. (ga-omfwe) DRY_RUN=1 never kickstarts, never populates RESTARTED, and
#      never reports PROOF=verified — it reports the preview in WOULD_RESTART
#      instead, so a dry-run preview can never be textually indistinguishable
#      from a real, confirmed restart.
#  11. (ga-y108i) A rig-declared restart_policy.yaml no_restart_paths glob
#      (e.g. daemons/static/**) short-circuits to VERDICT=OK/
#      PROOF=asset_served_per_request — never NEEDS_GUARDED_RESTART, even for
#      a SENSITIVE daemon — when EVERY changed file matches, whether the
#      match is on a *.js asset (T21) or the daemon's own *.py entrypoint
#      (T22, the stronger proof: bypasses the extension-based early-exit
#      entirely). A partially-covered mixed diff does NOT exempt (T23), and
#      an unrelated path (templates/, still genuinely restart-needed per
#      point 6/ga-jkj0) is never accidentally swallowed by an unrelated glob
#      (T24).
#  12. (ga-dk7fw) UNCONDITIONALLY (no restart_policy.yaml needed), tests/**,
#      docs/**, and *.md resolve to PROOF=not_applicable — not the weaker
#      not_verified an isolated, unimported change fell back to pre-fix (T28,
#      T29). The delta matters past daemon-refresh.sh's own output: story-
#      delivery.sh labels a story delivery:daemon-unverified and rewrites its
#      done-notification to "DAEMON LIVENESS NOT VERIFIED" for any PROOF tier
#      other than verified/not_applicable/asset_served_per_request — so a
#      not_verified tier on a tests-only change was live, actionable-looking
#      noise on a bead with zero daemon relevance. Deliberately NOT extended
#      to static/**/templates/** (still point-8/opt-in-only, unchanged — see
#      point 3/ga-jkj0). A co-changed real module in the SAME deploy as a
#      tests/ file is never swallowed by this (T30) — same all-or-nothing
#      shape as point 11.
#  13. (ga-tdzsh) A plist that fails to parse is escalated (ERROR-level log
#      line + the new PARSE_ERROR_LOADED field/JSON key) only when launchd
#      actually has that label loaded (T31) — never when nothing is loaded
#      under it at all (T32, the current real state of the two known-broken
#      plists on the live machine: com.athos.ckan_pbh, com.urblink.inbound-
#      review-3d — a run today must produce zero escalation). The load check
#      is launchd LOAD status, not live-PID presence: a label loaded but
#      currently idle (no PID) still escalates (T33) — daemon_pid() alone
#      cannot tell "not loaded" and "loaded but idle" apart, the exact
#      ambiguity that let com.gastown.dolt-server's broken plist hide.
#  14. (wa-jts45) A *.plist this deploy commits for a brand-new SCHEDULED job
#      has no live PID for points 1-13 to compare staleness against — every
#      check above them answers "is a daemon's live PROCESS stale?", a
#      question that is structurally silent about a process that was never
#      installed at all. VERDICT=JOB_NOT_INSTALLED now fires, BEFORE any
#      other check runs, when a *.plist changed by this deploy is missing
#      from LAUNCH_AGENTS_DIR (T37) or present but not `launchctl list`-loaded
#      (T38) — the exact wa-sas9j incident: merged + gate:passed + "daemon
#      fresh" were all simultaneously true while the job never existed on
#      disk for a month. A plist that IS installed+loaded is untouched by
#      this check and falls through to existing behavior (T39). A plist
#      declaring native `<key>Disabled</key><true/>` is intentionally manual
#      and never flagged (T40). Deliberately does NOT also require "has it
#      produced a successful run yet": a job installed by THIS deploy may
#      legitimately not have reached its next scheduled window yet, so that
#      bar would false-positive on every ordinary nightly-job delivery — left
#      to a human follow-up once installed+loaded is confirmed (see the
#      JOB_NOT_INSTALLED ACTION text at the call sites in
#      quality-gate-dispatcher.sh).
#  15. (wa-flysp) Every label landing in GUARDED is ALSO classified into
#      GUARDED_OWN (its own entrypoint/template is itself in the diff — T57)
#      or GUARDED_CLOSURE_ONLY (reached only via a transitively-changed
#      import/route-hop — T58), new always-present fields (T60) that partition
#      GUARDED without changing its own membership (T58's backward-compat
#      check). REASON renders OWN-FILE-CHANGED before CLOSURE-ONLY when both
#      are present (T59) — the actionable half is never buried under noise —
#      and a 100%-closure-only GUARDED list still renders its section rather
#      than silently omitting the split (T58, mirrors the exact bug class
#      whatsapp_automation's own daemon_refresh_advisory.py::render_advisory()
#      was fixed for).
#  16. (ga-8q1ulq) When $RUNTIME_DIR/scripts/compute_symbol_reachability.py
#      exists, every label in GUARDED is independently classified a THIRD
#      way — SYMBOL-CONFIRMED (T62), SEM EVIDÊNCIA DE SÍMBOLO (T63), or NÃO
#      CALCULADO (T64, a subprocess crash — NEVER folded into "no evidence").
#      A mixed batch renders all three sections, in that order, without
#      changing VERDICT or GUARDED membership (T66). A rig without the
#      script behaves identically to today — no new section, all three new
#      fields empty (T65). A per-daemon timeout (T67) or an exhausted total
#      budget (T68) both degrade to NÃO CALCULADO rather than stalling the
#      halt. The window prefers BEAD_MERGE_PRE_SHA/BEAD_MERGE_SHA over the
#      wider PRE_DEPLOY_SHA/POST_DEPLOY_SHA when the point-14 ancestor-guard
#      passes (T69) — a stub compute_symbol_reachability.py records its own
#      argv so these tests can assert on --before/--after directly, not just
#      the classification outcome.
#
# All external effects (launchctl, ps) are injected via LAUNCHCTL_BIN / PS_BIN
# and a mock state dir, so the test touches NO real daemons. The plist scan and
# the lstart→epoch date parse run for real.

# No `pipefail` at file level (ga-uel7sb): assertions below are `X | grep ...`
# -style pipes, and under pipefail an early-exiting reader can SIGPIPE the
# writer mid-write, turning a PASSING assertion into a false FAIL under load
# (measured: 1.9% per assertion at load 45; see ga-uel7sb). daemon-refresh.sh
# under test runs as its own subprocess (bash "$HELPER"), with its own `set`
# options — unaffected by this file's.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../daemon-refresh.sh"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/daemon-refresh-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

# ── assertion helpers ─────────────────────────────────────────────────────────
ok()   { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok()  { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

# field <name> <stdout>  →  echoes the value of "name=..." line from helper output
field() { echo "$2" | grep "^$1=" | head -1 | sed "s/^$1=//"; }

# ── fixture builders ──────────────────────────────────────────────────────────
# epoch→lstart string in the exact format `ps -o lstart=` emits on macOS.
lstart_of() { date -r "$1" "+%a %b %e %T %Y"; }

make_plist() {  # make_plist <dir> <label> <prog-arg> [<prog-arg>...]
  local dir="$1" label="$2"; shift 2
  local args="" a
  for a in "$@"; do args="$args      <string>$a</string>
"; done
  cat > "$dir/$label.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
$args  </array>
</dict>
</plist>
EOF
}

# build a fresh mock environment for one case; sets globals:
#   RUNTIME, AGENTS, MOCK, BIN, PRE, POST, DEPLOY_EPOCH
new_case() {
  local name="$1"
  CASE_DIR="$TMP_ROOT/$name"
  RUNTIME="$CASE_DIR/runtime"
  AGENTS="$CASE_DIR/agents"
  MOCK="$CASE_DIR/mock"
  BIN="$CASE_DIR/bin"
  mkdir -p "$RUNTIME" "$AGENTS" "$MOCK" "$BIN"

  # a git work tree representing the deployed rig
  git -C "$RUNTIME" init -q
  git -C "$RUNTIME" config user.email t@t.t
  git -C "$RUNTIME" config user.name t
  mkdir -p "$RUNTIME/daemons" "$RUNTIME/routes" "$RUNTIME/launchd"

  # mock launchctl: `list <label>` prints the current PID (when one is seeded)
  # and, per ga-tdzsh, exits 0 iff the label is known to the mock at all
  # (seed_running OR seed_loaded was called for it — real launchd's own
  # "loaded regardless of live-PID" contract) or 1 ("Could not find service")
  # when it is not — this is what daemon_is_loaded() in the helper under test
  # actually checks. `kickstart ... label` logs the call and, if a
  # post-restart pid/lstart is seeded, swaps them in.
  cat > "$BIN/launchctl" <<'LCEOF'
#!/usr/bin/env bash
S="$MOCK_DIR"; cmd="${1:-}"; shift || true
case "$cmd" in
  list)
    label="${1:-}"
    if [ -n "$label" ] && { [ -f "$S/pid.$label" ] || [ -f "$S/loaded.$label" ]; }; then
      [ -f "$S/pid.$label" ] && printf '\t"PID" = %s;\n' "$(cat "$S/pid.$label")"
      exit 0
    fi
    echo "Could not find service \"$label\" in domain for port" >&2
    exit 1
    ;;
  kickstart)
    last=""; for a in "$@"; do last="$a"; done
    label="${last##*/}"
    echo "$label" >> "$S/kicks.log"
    if [ -f "$S/restart_pid.$label" ]; then
      np="$(cat "$S/restart_pid.$label")"
      echo "$np" > "$S/pid.$label"
      [ -f "$S/restart_lstart.$label" ] && cat "$S/restart_lstart.$label" > "$S/start.$np"
    fi
    ;;
esac
exit 0
LCEOF
  chmod +x "$BIN/launchctl"

  # mock ps: emulate `ps -o lstart= -p <pid>`
  cat > "$BIN/ps" <<'PSEOF'
#!/usr/bin/env bash
S="$MOCK_DIR"; pid=""; prev=""
for a in "$@"; do [ "$prev" = "-p" ] && pid="$a"; prev="$a"; done
[ -n "$pid" ] && [ -f "$S/start.$pid" ] && cat "$S/start.$pid"
exit 0
PSEOF
  chmod +x "$BIN/ps"

  DEPLOY_EPOCH=$(( $(date +%s) - 600 ))   # deploy happened 10 min ago
  STALE_LSTART="$(lstart_of $(( DEPLOY_EPOCH - 3600 )) )"   # before deploy
  FRESH_LSTART="$(lstart_of $(( DEPLOY_EPOCH + 60 )) )"     # after deploy
  # ga-puq8z: the "deploy" commit run_helper creates below is, by default,
  # dated at DEPLOY_EPOCH (not wall-clock "now") — matching this fixture's
  # existing implicit assumption (used by every pre-ga-puq8z test) that the
  # commit and the deploy happen at the same moment. T26/T27 override this to
  # put the commit BEFORE DEPLOY_EPOCH, modeling a gate-queue/backoff delay
  # between when code was actually committed and when this check got around
  # to running.
  POST_COMMIT_EPOCH="$DEPLOY_EPOCH"
}

# seed a daemon that is currently running a STALE process (pre-deploy start)
seed_running() {  # seed_running <label> <pid> <lstart>
  echo "$2" > "$MOCK/pid.$1"
  echo "$3" > "$MOCK/start.$2"
}
# seed what a kickstart of <label> will produce
seed_restart() {  # seed_restart <label> <newpid> <lstart>
  echo "$2" > "$MOCK/restart_pid.$1"
  echo "$3" > "$MOCK/restart_lstart.$1"
}
# seed a daemon that is LOADED in launchd but has NO live PID right now (e.g.
# a KeepAlive=false job between runs) — distinct from seed_running, which
# implies both loaded AND a live PID. Used to prove daemon_is_loaded() (ga-tdzsh)
# checks LOAD status, not PID presence — daemon_pid() alone is empty for both
# this case and "not loaded at all", the exact ambiguity the bug is about.
seed_loaded() {  # seed_loaded <label>
  : > "$MOCK/loaded.$1"
}

# ga-8q1ulq: a stub compute_symbol_reachability.py, CLI-compatible with the
# real one (--repo/--entrypoint/--closure*/--before/--after, one JSON object
# on stdout) but driven by a control file per <entrypoint-relpath> instead of
# real AST analysis — the underlying algorithm is wa-th4b1's own tested
# concern, not this HQ integration's. Reads $MOCK_DIR the same way the
# launchctl/ps mocks above do (inherited from run_helper's exported
# MOCK_DIR, no extra wiring). Also records its own argv per entrypoint so
# tests can assert on --closure/--before/--after directly (T69).
make_symbol_script() {  # make_symbol_script <runtime-dir>
  mkdir -p "$1/scripts"
  cat > "$1/scripts/compute_symbol_reachability.py" <<'PYEOF'
#!/usr/bin/env python3
# ga-4oh2r6: --batch added alongside the original single-entry CLI (unchanged
# below). Both branches share the SAME per-entrypoint seed_symbol_result()
# mode file, so an existing single-entry test's seeding still works verbatim
# if pointed at --batch instead.
import argparse, json, os, sys, time
ap = argparse.ArgumentParser()
ap.add_argument("--repo", default="")
ap.add_argument("--entrypoint")
ap.add_argument("--closure", action="append", default=[])
ap.add_argument("--before", required=True)
ap.add_argument("--after", required=True)
ap.add_argument("--batch")
args = ap.parse_args()
mock = os.environ.get("MOCK_DIR", "")


def result_for(entrypoint):
    sanitized = entrypoint.replace("/", "_")
    mode = "no_evidence"
    ctrl = os.path.join(mock, "symbol_mode." + sanitized) if mock else ""
    if ctrl and os.path.exists(ctrl):
        with open(ctrl) as f:
            mode = f.read().strip()
    if mode == "confirmed":
        return {"reaches": True, "via": "direct", "path": ["handler"], "changed_symbols": ["handler"], "warnings": []}
    if mode == "confirmed_graph":
        return {"reaches": True, "via": "graph", "path": ["entry", "mid", "handler"], "changed_symbols": ["handler"], "warnings": []}
    if mode == "no_evidence":
        return {"reaches": False, "via": None, "path": [], "changed_symbols": ["other"], "warnings": []}
    # ga-j3lh6p: the REAL calculator returns reaches=False in several cases that
    # are NOT "analysed cleanly, no call-graph path" (compute_symbol_reachability
    # .py lines ~501-550). These modes reproduce its exact warning wording so the
    # producer's clean/unevaluable split is tested against the real contract.
    #   benign      — a CLOSURE file absent at --after (added by a later commit,
    #                 or deleted): the analysis of everything else is complete.
    #   syntax      — the ENTRYPOINT failed to parse: "reaches=False por padrão
    #                 seguro" is a could-not-evaluate, not a negative answer.
    #   unevaluable — the ENTRYPOINT is absent at --after: "não dá pra avaliar".
    #   closure_syn — a closure file failed the structural diff: its changed
    #                 symbols were dropped, so a false negative is possible.
    #   nowarnkey   — a calculator that predates the "warnings" field entirely.
    if mode == "no_evidence_benign_warning":
        return {"reaches": False, "via": None, "path": [], "changed_symbols": ["other"],
                "warnings": ["lib/added_later.py: ausente em --after (abc1234) — ignorado"]}
    if mode == "no_evidence_syntax_error":
        return {"reaches": False, "via": None, "path": [], "changed_symbols": [],
                "warnings": ["daemons/x.py: SyntaxError (invalid syntax (<unknown>, line 1)) — reaches=False por padrão seguro"]}
    if mode == "no_evidence_unevaluable":
        return {"reaches": False, "via": None, "path": [], "changed_symbols": [],
                "warnings": ["lib/added_later.py: ausente em --after (abc1234) — ignorado",
                             "daemons/x.py: ausente em --after, não dá pra avaliar"]}
    if mode == "no_evidence_closure_syntax_error":
        return {"reaches": False, "via": None, "path": [], "changed_symbols": ["other"],
                "warnings": ["lib/broken.py: SyntaxError no diff estrutural (invalid syntax) — ignorado"]}
    if mode == "no_evidence_nowarnkey":
        return {"reaches": False, "via": None, "path": [], "changed_symbols": ["other"]}
    return mode  # "crash" | "hang" | "badjson" | "missing" — handled by caller


if args.batch:
    with open(args.batch, encoding="utf-8") as f:
        manifest = json.load(f)
    if mock:
        with open(os.path.join(mock, "symbol_batch_argv.json"), "w") as f:
            json.dump({"before": args.before, "after": args.after, "batch": args.batch,
                       "n_entries": len(manifest["entries"])}, f)
        # ga-4oh2r6: counts INVOCATIONS of this stub in --batch mode, not
        # entries processed -- the whole point being tested is "N GUARDED
        # daemons -> ONE process", so this file's own byte content (an
        # incrementing counter, not a boolean flag) is what proves that, not
        # just its existence (which a regression back to N separate calls,
        # each overwriting the same filename, would leave looking identical).
        counter_path = os.path.join(mock, "symbol_batch_invocations")
        try:
            with open(counter_path) as f:
                n = int(f.read().strip() or "0")
        except FileNotFoundError:
            n = 0
        with open(counter_path, "w") as f:
            f.write(str(n + 1))
    for entry in manifest["entries"]:
        r = result_for(entry["entrypoint"])
        if r == "crash":
            sys.exit(1)
        elif r == "hang":
            time.sleep(20)
        elif r == "missing":
            continue  # this entry never gets a JSONL line -- process keeps going
        elif r == "badjson":
            print("not valid json")
            sys.stdout.flush()
        else:
            out = dict(r)
            out["label"] = entry["label"]
            print(json.dumps(out))
            sys.stdout.flush()
    sys.exit(0)

# single-entry CLI — unchanged from the pre-ga-4oh2r6 stub.
sanitized = args.entrypoint.replace("/", "_")
if mock:
    with open(os.path.join(mock, "symbol_argv." + sanitized), "w") as f:
        json.dump(vars(args), f)
r = result_for(args.entrypoint)
if r == "crash":
    sys.exit(1)
elif r == "hang":
    time.sleep(20)
elif r == "badjson":
    print("not valid json")
elif isinstance(r, dict):
    print(json.dumps(r))
sys.exit(0)
PYEOF
  chmod +x "$1/scripts/compute_symbol_reachability.py"
}
# seed_symbol_result <entrypoint-relpath> <mode>  — mode is one of
# confirmed|confirmed_graph|no_evidence|crash|hang|badjson|missing (default
# when unseeded: no_evidence). "missing" (ga-4oh2r6) only means anything in
# --batch mode: the entry is silently omitted from the JSONL output instead
# of crashing the whole invocation — models one daemon's line never arriving
# without taking the rest of the batch down with it.
seed_symbol_result() {
  local sanitized="${1//\//_}"
  echo "$2" > "$MOCK/symbol_mode.$sanitized"
}

run_helper() {  # run_helper <changed-relpaths...>  (commits a deploy diff first)
  # PRE = current HEAD; mutate the listed files; POST = new HEAD.
  ( cd "$RUNTIME"
    git add -A >/dev/null 2>&1
    git commit -q -m base --allow-empty
  )
  PRE=$(git -C "$RUNTIME" rev-parse HEAD)
  local f
  for f in "$@"; do
    mkdir -p "$RUNTIME/$(dirname "$f")"
    echo "# changed $(date +%s%N)" >> "$RUNTIME/$f"
  done
  ( cd "$RUNTIME"
    git add -A >/dev/null 2>&1
    GIT_AUTHOR_DATE="@$POST_COMMIT_EPOCH" GIT_COMMITTER_DATE="@$POST_COMMIT_EPOCH" \
      git commit -q -m deploy --allow-empty
  )
  POST=$(git -C "$RUNTIME" rev-parse HEAD)

  MOCK_DIR="$MOCK" \
  RUNTIME_DIR="$RUNTIME" \
  PRE_DEPLOY_SHA="$PRE" POST_DEPLOY_SHA="$POST" \
  BEAD_MERGE_PRE_SHA="${BEAD_MERGE_PRE_SHA:-}" BEAD_MERGE_SHA="${BEAD_MERGE_SHA:-}" \
  DEPLOY_EPOCH="$DEPLOY_EPOCH" \
  SENSITIVE_DAEMONS="$SENSITIVE_DAEMONS" \
  EXTRA_RUNTIME_ROOTS="${EXTRA_RUNTIME_ROOTS:-}" \
  FORCE_RESTART_LABELS="${FORCE_RESTART_LABELS:-}" \
  LAUNCH_AGENTS_DIR="$AGENTS" \
  LAUNCHCTL_BIN="$BIN/launchctl" PS_BIN="$BIN/ps" \
  VERIFY_TIMEOUT=2 VERIFY_INTERVAL=0.2 \
  SYMBOL_REACHABILITY_TOTAL_TIMEOUT="${SYMBOL_REACHABILITY_TOTAL_TIMEOUT:-10}" \
  DRY_RUN="${DRY_RUN:-0}" \
  bash "$HELPER" 2>/dev/null
}

# like run_helper, but merges stderr into the captured output — needed for
# T19/T20, which assert on the WARN log() emits (stdout-only capture would
# never see it; every other test's `2>/dev/null` is why this is a separate
# function rather than a change to run_helper itself).
run_helper_stderr() {  # run_helper_stderr <changed-relpaths...>
  ( cd "$RUNTIME"
    git add -A >/dev/null 2>&1
    git commit -q -m base --allow-empty
  )
  PRE=$(git -C "$RUNTIME" rev-parse HEAD)
  local f
  for f in "$@"; do
    mkdir -p "$RUNTIME/$(dirname "$f")"
    echo "# changed $(date +%s%N)" >> "$RUNTIME/$f"
  done
  ( cd "$RUNTIME"
    git add -A >/dev/null 2>&1
    GIT_AUTHOR_DATE="@$POST_COMMIT_EPOCH" GIT_COMMITTER_DATE="@$POST_COMMIT_EPOCH" \
      git commit -q -m deploy --allow-empty
  )
  POST=$(git -C "$RUNTIME" rev-parse HEAD)

  MOCK_DIR="$MOCK" \
  RUNTIME_DIR="$RUNTIME" \
  PRE_DEPLOY_SHA="$PRE" POST_DEPLOY_SHA="$POST" \
  DEPLOY_EPOCH="$DEPLOY_EPOCH" \
  SENSITIVE_DAEMONS="$SENSITIVE_DAEMONS" \
  EXTRA_RUNTIME_ROOTS="${EXTRA_RUNTIME_ROOTS:-}" \
  FORCE_RESTART_LABELS="${FORCE_RESTART_LABELS:-}" \
  LAUNCH_AGENTS_DIR="$AGENTS" \
  LAUNCHCTL_BIN="$BIN/launchctl" PS_BIN="$BIN/ps" \
  VERIFY_TIMEOUT=2 VERIFY_INTERVAL=0.2 \
  DRY_RUN="${DRY_RUN:-0}" \
  bash "$HELPER" 2>&1
}

# ════════════════════════════════════════════════════════════════════════════
# T1: no daemon code changed → OK, nothing restarted
# ════════════════════════════════════════════════════════════════════════════
SENSITIVE_DAEMONS="central-sender conversation-monitor slot-scheduler webhook"
new_case t1
# a daemon exists, but the deploy only touched a README
cat > "$RUNTIME/daemons/foo_dashboard.py" <<<'print("foo")'
make_plist "$AGENTS" com.test.foo-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/foo_dashboard.py"
seed_running com.test.foo-dashboard 1001 "$STALE_LSTART"
OUT=$(run_helper README.md); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T1 verdict OK on no daemon change" || nok "T1 verdict" "got '$V' rc=$RC out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T1 exit 0" || nok "T1 exit" "rc=$RC"
[ ! -f "$MOCK/kicks.log" ] && ok "T1 no kickstart called" || nok "T1 kickstart" "called: $(cat "$MOCK/kicks.log" 2>/dev/null)"
# ga-vmq1i: nothing daemon-relevant changed — a structurally-certain non-issue,
# not a positive verification. Must NOT claim "verified".
[ "$(field PROOF "$OUT")" = "not_applicable" ] && ok "T1 PROOF=not_applicable (nothing daemon-relevant changed)" || nok "T1 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T2: affected SAFE dashboard → restarted + fresh → OK
# ════════════════════════════════════════════════════════════════════════════
new_case t2
cat > "$RUNTIME/daemons/ban_risk_dashboard.py" <<<'print("dash")'
make_plist "$AGENTS" com.test.ban-risk-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/ban_risk_dashboard.py"
seed_running com.test.ban-risk-dashboard 2001 "$STALE_LSTART"
seed_restart com.test.ban-risk-dashboard 2099 "$FRESH_LSTART"
OUT=$(run_helper daemons/ban_risk_dashboard.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T2 verdict OK" || nok "T2 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T2 exit 0" || nok "T2 exit" "rc=$RC"
echo "$(field AFFECTED "$OUT")" | grep "com.test.ban-risk-dashboard" >/dev/null && ok "T2 dashboard affected" || nok "T2 affected" "$(field AFFECTED "$OUT")"
echo "$(field RESTARTED "$OUT")" | grep "com.test.ban-risk-dashboard" >/dev/null && ok "T2 dashboard restarted" || nok "T2 restarted" "$(field RESTARTED "$OUT")"
grep -q "com.test.ban-risk-dashboard" "$MOCK/kicks.log" 2>/dev/null && ok "T2 kickstart invoked" || nok "T2 kickstart" "log: $(cat "$MOCK/kicks.log" 2>/dev/null)"
# ga-vmq1i: a live daemon was actually restarted AND confirmed fresh — the one
# case that earns the word "verified".
[ "$(field PROOF "$OUT")" = "verified" ] && ok "T2 PROOF=verified (real restart+fresh confirmed)" || nok "T2 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T3: affected SAFE dashboard, but stays stale after restart → VERIFY_FAILED
# ════════════════════════════════════════════════════════════════════════════
new_case t3
cat > "$RUNTIME/daemons/ban_risk_dashboard.py" <<<'print("dash")'
make_plist "$AGENTS" com.test.ban-risk-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/ban_risk_dashboard.py"
seed_running com.test.ban-risk-dashboard 3001 "$STALE_LSTART"
# no seed_restart → kickstart does not refresh the process; still stale start
OUT=$(run_helper daemons/ban_risk_dashboard.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "VERIFY_FAILED" ] && ok "T3 verdict VERIFY_FAILED" || nok "T3 verdict" "got '$V' out=[$OUT]"
[ "$RC" -ne 0 ] && ok "T3 non-zero exit (halts delivery)" || nok "T3 exit" "rc=$RC (must be non-zero)"
echo "$(field FRESH_FAIL "$OUT")" | grep "com.test.ban-risk-dashboard" >/dev/null && ok "T3 dashboard in FRESH_FAIL" || nok "T3 fresh_fail" "$(field FRESH_FAIL "$OUT")"
[ "$(field PROOF "$OUT")" = "not_verified" ] && ok "T3 PROOF=not_verified" || nok "T3 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T4: affected SENSITIVE hot-path daemon → flagged, NOT bounced → NEEDS_GUARDED_RESTART
# ════════════════════════════════════════════════════════════════════════════
new_case t4
cat > "$RUNTIME/daemons/central_sender.py" <<<'print("send")'
# wrapper-style plist: program runs a wrapper .sh that execs the .py
cat > "$RUNTIME/launchd/central-sender-wrapper.sh" <<EOF
#!/usr/bin/env bash
exec "\$BASEDIR/venv/bin/python3" "\$BASEDIR/daemons/central_sender.py"
EOF
make_plist "$AGENTS" com.test.central-sender /bin/bash "$RUNTIME/launchd/central-sender-wrapper.sh"
seed_running com.test.central-sender 4001 "$STALE_LSTART"
OUT=$(run_helper daemons/central_sender.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T4 verdict NEEDS_GUARDED_RESTART" || nok "T4 verdict" "got '$V' out=[$OUT]"
[ "$RC" -ne 0 ] && ok "T4 non-zero exit (halts delivery)" || nok "T4 exit" "rc=$RC (must be non-zero)"
echo "$(field GUARDED "$OUT")" | grep "com.test.central-sender" >/dev/null && ok "T4 sensitive daemon flagged GUARDED" || nok "T4 guarded" "$(field GUARDED "$OUT")"
! grep -q "com.test.central-sender" "$MOCK/kicks.log" 2>/dev/null && ok "T4 sensitive daemon NOT auto-bounced" || nok "T4 no-bounce" "kickstart was called: $(cat "$MOCK/kicks.log" 2>/dev/null)"
[ "$(field PROOF "$OUT")" = "not_verified" ] && ok "T4 PROOF=not_verified" || nok "T4 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T5: import-level — changed routes/*.py marks the dashboard that imports it
# ════════════════════════════════════════════════════════════════════════════
new_case t5
cat > "$RUNTIME/routes/channel_admin_api.py" <<<'def register(app): pass'
cat > "$RUNTIME/daemons/ban_risk_dashboard.py" <<'PYEOF'
from routes.channel_admin_api import register
register(None)
PYEOF
make_plist "$AGENTS" com.test.ban-risk-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/ban_risk_dashboard.py"
seed_running com.test.ban-risk-dashboard 5001 "$STALE_LSTART"
seed_restart com.test.ban-risk-dashboard 5099 "$FRESH_LSTART"
# deploy changed ONLY the route file, not the dashboard entrypoint
OUT=$(run_helper routes/channel_admin_api.py); RC=$?
V=$(field VERDICT "$OUT")
echo "$(field AFFECTED "$OUT")" | grep "com.test.ban-risk-dashboard" >/dev/null && ok "T5 importing dashboard marked affected" || nok "T5 affected" "$(field AFFECTED "$OUT")"
[ "$V" = "OK" ] && ok "T5 verdict OK after fresh restart" || nok "T5 verdict" "got '$V' out=[$OUT]"
[ "$(field PROOF "$OUT")" = "verified" ] && ok "T5 PROOF=verified" || nok "T5 proof" "got '$(field PROOF "$OUT")'"
# wa-xokje: a LIVE, successfully-restarted daemon must never show up in
# AFFECTED_NOT_RUNNING — that field is exclusively for the no-PID branch T6
# exercises below, not a general "not a problem" bucket.
echo "$(field AFFECTED_NOT_RUNNING "$OUT")" | grep "com.test.ban-risk-dashboard" >/dev/null \
  && nok "T5 AFFECTED_NOT_RUNNING must not contain a live daemon" "$(field AFFECTED_NOT_RUNNING "$OUT")" \
  || ok "T5 AFFECTED_NOT_RUNNING correctly excludes the live daemon"

# ════════════════════════════════════════════════════════════════════════════
# T6: affected daemon is NOT currently running (no PID — e.g. a scheduled job) →
#     do not kickstart it (would wrongly TRIGGER a one-shot job); verdict OK.
# ════════════════════════════════════════════════════════════════════════════
new_case t6
cat > "$RUNTIME/daemons/daily_scraper.py" <<<'print("scrape")'
make_plist "$AGENTS" com.test.daily-scraper "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/daily_scraper.py"
# deliberately DO NOT seed_running → daemon has no live PID
OUT=$(run_helper daemons/daily_scraper.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T6 verdict OK (not-running affected daemon is skipped)" || nok "T6 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T6 exit 0" || nok "T6 exit" "rc=$RC"
[ ! -f "$MOCK/kicks.log" ] && ok "T6 scheduled/down job NOT kickstarted" || nok "T6 kickstart" "called: $(cat "$MOCK/kicks.log" 2>/dev/null)"
echo "$(field RESTARTED "$OUT")" | grep "daily-scraper" >/dev/null && nok "T6 should not restart" "restarted=$(field RESTARTED "$OUT")" || ok "T6 not in RESTARTED"
# wa-xokje: this is the field a caller needs to tell "reaches only a
# self-healing scheduled job" apart from "reaches a live daemon" — without
# it, AFFECTED alone can't distinguish this case from T5's.
echo "$(field AFFECTED_NOT_RUNNING "$OUT")" | grep "com.test.daily-scraper" >/dev/null \
  && ok "T6 AFFECTED_NOT_RUNNING names the not-running scheduled job" \
  || nok "T6 AFFECTED_NOT_RUNNING" "$(field AFFECTED_NOT_RUNNING "$OUT")"
# ga-vmq1i (THE BUG THIS FIX IS ABOUT): AFFECTED is non-empty here but RESTARTED
# is empty (the daemon was never running to restart). Before this fix, the
# fall-through branch unconditionally emitted "all affected daemons restarted
# + verified fresh:" with a literally EMPTY restarted list — VERDICT=OK with
# zero daemons actually confirmed fresh, which is exactly the false-positive
# "verified in prod" claim ga-vmq1i reports. Must be not_applicable (nothing
# LIVE to verify), never "verified".
[ "$(field PROOF "$OUT")" = "not_applicable" ] && ok "T6 PROOF=not_applicable (affected daemon not live — nothing to verify, must NOT claim verified)" || nok "T6 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T7: template-only change — a changed *.html a dashboard renders via
#     render_template(...) marks it affected with ZERO *.py changes (ga-jkj0:
#     com.whatsapp.map-viewer served a stale layout — Jinja compiles+caches
#     templates in-process, so a disk-only edit was invisible pre-fix).
# ════════════════════════════════════════════════════════════════════════════
new_case t7
cat > "$RUNTIME/daemons/map_viewer_dashboard.py" <<'PYEOF'
from flask import render_template
def index():
    return render_template("map_viewer.html")
PYEOF
mkdir -p "$RUNTIME/templates"
cat > "$RUNTIME/templates/map_viewer.html" <<<'<html>old</html>'
make_plist "$AGENTS" com.test.map-viewer "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/map_viewer_dashboard.py"
seed_running com.test.map-viewer 6001 "$STALE_LSTART"
seed_restart com.test.map-viewer 6099 "$FRESH_LSTART"
# deploy changed ONLY the template, not the .py entrypoint
OUT=$(run_helper templates/map_viewer.html); RC=$?
V=$(field VERDICT "$OUT")
echo "$(field AFFECTED "$OUT")" | grep "com.test.map-viewer" >/dev/null && ok "T7 template-rendering dashboard marked affected" || nok "T7 affected" "$(field AFFECTED "$OUT")"
[ "$V" = "OK" ] && ok "T7 verdict OK after fresh restart" || nok "T7 verdict" "got '$V' out=[$OUT]"
grep -q "com.test.map-viewer" "$MOCK/kicks.log" 2>/dev/null && ok "T7 kickstart invoked" || nok "T7 kickstart" "log: $(cat "$MOCK/kicks.log" 2>/dev/null)"
[ "$(field PROOF "$OUT")" = "verified" ] && ok "T7 PROOF=verified" || nok "T7 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T8: unrelated template change — a changed *.html NOT referenced by any
#     daemon's render_template(...) call must NOT trigger a restart (precision
#     / no-cascade: template matching must not over-fire on every template
#     edit in the runtime tree).
# ════════════════════════════════════════════════════════════════════════════
new_case t8
cat > "$RUNTIME/daemons/map_viewer_dashboard.py" <<'PYEOF'
from flask import render_template
def index():
    return render_template("map_viewer.html")
PYEOF
mkdir -p "$RUNTIME/templates"
cat > "$RUNTIME/templates/map_viewer.html" <<<'<html>old</html>'
cat > "$RUNTIME/templates/unrelated.html" <<<'<html>other</html>'
make_plist "$AGENTS" com.test.map-viewer "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/map_viewer_dashboard.py"
seed_running com.test.map-viewer 7001 "$STALE_LSTART"
# deploy changes a template nobody renders
OUT=$(run_helper templates/unrelated.html); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T8 verdict OK on unrelated template change" || nok "T8 verdict" "got '$V' out=[$OUT]"
echo "$(field AFFECTED "$OUT")" | grep "com.test.map-viewer" >/dev/null && nok "T8 should not be affected" "$(field AFFECTED "$OUT")" || ok "T8 map-viewer not marked affected"
[ ! -f "$MOCK/kicks.log" ] && ok "T8 no kickstart called (no cascade)" || nok "T8 kickstart" "called: $(cat "$MOCK/kicks.log" 2>/dev/null)"
# ga-vmq1i: a template DID change (CHANGED_TEMPLATES non-empty) but detection
# tied it to no live daemon. Unlike T1 (structurally certain nothing relevant
# changed), this is the single-hop-detection blind spot the script's own
# comments acknowledge (render_template only checked one hop deep) — we
# cannot be CONFIDENT this is a true negative, so it must read as
# not_verified, not a confident not_applicable/verified.
[ "$(field PROOF "$OUT")" = "not_verified" ] && ok "T8 PROOF=not_verified (py/template changed but tied to no live daemon — can't confidently call it N/A)" || nok "T8 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T9 (ga-ylr2m): a daemon whose .py is NOT in restart_policy.yaml's 'auto'/
# 'deploy_restart' (simply unlisted here) is treated SENSITIVE by the POLICY
# alone — even though its launchd label matches NO SENSITIVE_DAEMONS
# substring. This is the exact registry-drift gap ga-ylr2m closes:
# daemon-refresh.sh used to auto-kickstart anything not in the small
# hand-copied SENSITIVE_DAEMONS list, bypassing WA's own stricter
# "unlisted = manual" default (the real incident: frota_dashboard/
# demand_dashboard/campaign_dashboard auto-kickstarted despite being
# notify_only_locked/vetoed in restart_policy.yaml).
# ════════════════════════════════════════════════════════════════════════════
new_case t9
cat > "$RUNTIME/daemons/frota_dashboard.py" <<<'print("frota")'
make_plist "$AGENTS" com.test.frota-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/frota_dashboard.py"
seed_running com.test.frota-dashboard 8001 "$STALE_LSTART"
cat > "$RUNTIME/daemons/restart_policy.yaml" <<'EOF'
auto:
  - chip_kpi_dashboard.py
deploy_restart:
  - central_sender.py
notify_only_locked:
  - frota_dashboard.py
EOF
OUT=$(run_helper daemons/frota_dashboard.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T9 verdict NEEDS_GUARDED_RESTART (policy-sensitive, no SENSITIVE_DAEMONS match)" || nok "T9 verdict" "got '$V' out=[$OUT]"
[ "$RC" -ne 0 ] && ok "T9 non-zero exit (halts delivery)" || nok "T9 exit" "rc=$RC"
echo "$(field GUARDED "$OUT")" | grep "com.test.frota-dashboard" >/dev/null && ok "T9 flagged GUARDED by restart_policy.yaml alone" || nok "T9 guarded" "$(field GUARDED "$OUT")"
! grep -q "com.test.frota-dashboard" "$MOCK/kicks.log" 2>/dev/null && ok "T9 NOT auto-bounced" || nok "T9 no-bounce" "kickstart was called: $(cat "$MOCK/kicks.log" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# T10 (ga-ylr2m): a daemon EXPLICITLY listed in restart_policy.yaml's 'auto'
# still auto-restarts normally — the policy consultation only ADDS scrutiny
# for unlisted daemons, never blocks one the policy explicitly clears (no
# regression for the already-reviewed-safe majority).
# ════════════════════════════════════════════════════════════════════════════
new_case t10
cat > "$RUNTIME/daemons/chip_kpi_dashboard.py" <<<'print("kpi")'
make_plist "$AGENTS" com.test.chip-kpi "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/chip_kpi_dashboard.py"
seed_running com.test.chip-kpi 8101 "$STALE_LSTART"
seed_restart com.test.chip-kpi 8199 "$FRESH_LSTART"
cat > "$RUNTIME/daemons/restart_policy.yaml" <<'EOF'
auto:
  - chip_kpi_dashboard.py
notify_only_locked:
  - frota_dashboard.py
EOF
OUT=$(run_helper daemons/chip_kpi_dashboard.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T10 verdict OK (policy-cleared daemon still auto-restarts)" || nok "T10 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T10 exit 0" || nok "T10 exit" "rc=$RC"
grep -q "com.test.chip-kpi" "$MOCK/kicks.log" 2>/dev/null && ok "T10 kickstart invoked" || nok "T10 kickstart" "log: $(cat "$MOCK/kicks.log" 2>/dev/null)"
[ "$(field PROOF "$OUT")" = "verified" ] && ok "T10 PROOF=verified" || nok "T10 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T11 (ga-ylr2m): a daemon in 'auto' (policy-cleared, and NOT matching
# SENSITIVE_DAEMONS either) but with a restart_guard_scripts: entry whose
# guard script exits 1 (something in flight) — the guard BLOCKS the
# auto-kickstart. Closes the classification_dashboard send-in-flight gap:
# daemon-refresh.sh was a previously-unguarded 4th restart trigger alongside
# WA's own three.
# ════════════════════════════════════════════════════════════════════════════
new_case t11
cat > "$RUNTIME/daemons/classification_dashboard.py" <<<'print("cls")'
make_plist "$AGENTS" com.test.classification-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/classification_dashboard.py"
seed_running com.test.classification-dashboard 8201 "$STALE_LSTART"
mkdir -p "$RUNTIME/scripts"
cat > "$RUNTIME/scripts/cls_guard.py" <<'EOF'
#!/usr/bin/env python3
import sys
print("1 send in flight", file=sys.stderr)
sys.exit(1)
EOF
chmod +x "$RUNTIME/scripts/cls_guard.py"
cat > "$RUNTIME/daemons/restart_policy.yaml" <<'EOF'
auto:
  - classification_dashboard.py
restart_guard_scripts:
  classification_dashboard.py: scripts/cls_guard.py
EOF
OUT=$(run_helper daemons/classification_dashboard.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T11 verdict NEEDS_GUARDED_RESTART (guard refused)" || nok "T11 verdict" "got '$V' out=[$OUT]"
[ "$RC" -ne 0 ] && ok "T11 non-zero exit (halts delivery)" || nok "T11 exit" "rc=$RC"
echo "$(field GUARDED "$OUT")" | grep "com.test.classification-dashboard" >/dev/null && ok "T11 flagged GUARDED by guard script refusal" || nok "T11 guarded" "$(field GUARDED "$OUT")"
! grep -q "com.test.classification-dashboard" "$MOCK/kicks.log" 2>/dev/null && ok "T11 NOT auto-bounced (guard blocked kickstart)" || nok "T11 no-bounce" "kickstart was called: $(cat "$MOCK/kicks.log" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# T12 (ga-ylr2m): same daemon+guard as T11, but the guard script exits 0
# (nothing in flight) — kickstart proceeds normally.
# ════════════════════════════════════════════════════════════════════════════
new_case t12
cat > "$RUNTIME/daemons/classification_dashboard.py" <<<'print("cls")'
make_plist "$AGENTS" com.test.classification-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/classification_dashboard.py"
seed_running com.test.classification-dashboard 8301 "$STALE_LSTART"
seed_restart com.test.classification-dashboard 8399 "$FRESH_LSTART"
mkdir -p "$RUNTIME/scripts"
cat > "$RUNTIME/scripts/cls_guard.py" <<'EOF'
#!/usr/bin/env python3
import sys
print("nothing in flight", file=sys.stderr)
sys.exit(0)
EOF
chmod +x "$RUNTIME/scripts/cls_guard.py"
cat > "$RUNTIME/daemons/restart_policy.yaml" <<'EOF'
auto:
  - classification_dashboard.py
restart_guard_scripts:
  classification_dashboard.py: scripts/cls_guard.py
EOF
OUT=$(run_helper daemons/classification_dashboard.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T12 verdict OK (guard allowed)" || nok "T12 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T12 exit 0" || nok "T12 exit" "rc=$RC"
grep -q "com.test.classification-dashboard" "$MOCK/kicks.log" 2>/dev/null && ok "T12 kickstart invoked (guard allowed)" || nok "T12 kickstart" "log: $(cat "$MOCK/kicks.log" 2>/dev/null)"
[ "$(field PROOF "$OUT")" = "verified" ] && ok "T12 PROOF=verified" || nok "T12 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T13 (ga-ylr2m, self-audit finding): restart_policy.yaml EXISTS but fails to
# parse (invalid UTF-8 — a stand-in for "this rig's file broke the subset
# parser's assumptions"). This is a DIFFERENT state from "no policy file" and
# must NOT collapse to the same value: since we cannot verify what the file
# says, the daemon must be treated as sensitive (not silently safe) — the
# exact third-state defect class the mandatory pre-gate self-audit exists to
# catch. Locks in policy_says_sensitive()'s documented parse-failure contract
# directly. NOTE, verified by hand: for THIS specific daemon shape (no
# SENSITIVE_DAEMONS match, no DRAIN_CMD), the pre-fix code reaches the same
# NEEDS_GUARDED_RESTART verdict BY COINCIDENCE — an unparsed file silently
# left POLICY_AUTO/POLICY_DEPLOY_RESTART empty, and an empty allowlist never
# contains any daemon either way, sensitive-by-omission regardless of WHY it's
# empty. This test does not by itself prove the fix (it passes before and
# after); it pins the intended behavior against a future regression. T14
# below isolates the one path (guard_allows_restart, reached via
# SENSITIVE_DAEMONS + DRAIN_CMD, bypassing policy_says_sensitive entirely)
# where the pre-fix silent-empty behavior was a real, provable gap.
# ════════════════════════════════════════════════════════════════════════════
new_case t13
cat > "$RUNTIME/daemons/unremarkable_dashboard.py" <<<'print("plain")'
make_plist "$AGENTS" com.test.unremarkable "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/unremarkable_dashboard.py"
seed_running com.test.unremarkable 8401 "$STALE_LSTART"
printf '\xff\xfeauto:\n  - unremarkable_dashboard.py\n' > "$RUNTIME/daemons/restart_policy.yaml"
OUT=$(run_helper daemons/unremarkable_dashboard.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T13 verdict NEEDS_GUARDED_RESTART (unparseable policy fails closed)" || nok "T13 verdict" "got '$V' out=[$OUT]"
[ "$RC" -ne 0 ] && ok "T13 non-zero exit (halts delivery)" || nok "T13 exit" "rc=$RC"
echo "$(field GUARDED "$OUT")" | grep "com.test.unremarkable" >/dev/null && ok "T13 flagged GUARDED despite being in the (unreadable) 'auto' list" || nok "T13 guarded" "$(field GUARDED "$OUT")"
! grep -q "com.test.unremarkable" "$MOCK/kicks.log" 2>/dev/null && ok "T13 NOT auto-bounced" || nok "T13 no-bounce" "kickstart was called: $(cat "$MOCK/kicks.log" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# T14 (ga-ylr2m, self-audit finding — the one path T13 alone does not reach):
# a SENSITIVE_DAEMONS-matched daemon WITH a configured DRAIN_CMD, on a rig
# whose restart_policy.yaml exists but fails to parse. is_sensitive() already
# routes this into the SENSITIVE+DRAIN branch regardless of what the policy
# file says, so policy_says_sensitive()'s own fail-closed behavior is never
# even consulted here — this isolates guard_allows_restart()'s OWN fail-closed
# check. Pre-fix, an unparseable file silently produced an empty POLICY_GUARDS
# — indistinguishable from "no guard configured" — so the drain+kickstart
# would proceed even though the (unreadable) file might have named a guard
# that would have refused it.
# ════════════════════════════════════════════════════════════════════════════
new_case t14
cat > "$RUNTIME/daemons/central_sender.py" <<<'print("send")'
make_plist "$AGENTS" com.test.central-sender "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/central_sender.py"
seed_running com.test.central-sender 8501 "$STALE_LSTART"
printf '\xff\xfeauto:\n  - central_sender.py\n' > "$RUNTIME/daemons/restart_policy.yaml"
export DRAIN_CMD_com_test_central_sender="true"
OUT=$(run_helper daemons/central_sender.py); RC=$?
unset DRAIN_CMD_com_test_central_sender
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T14 verdict NEEDS_GUARDED_RESTART (unparseable policy blocks even the DRAIN_CMD path)" || nok "T14 verdict" "got '$V' out=[$OUT]"
[ "$RC" -ne 0 ] && ok "T14 non-zero exit (halts delivery)" || nok "T14 exit" "rc=$RC"
echo "$(field GUARDED "$OUT")" | grep "com.test.central-sender" >/dev/null && ok "T14 flagged GUARDED" || nok "T14 guarded" "$(field GUARDED "$OUT")"
! grep -q "com.test.central-sender" "$MOCK/kicks.log" 2>/dev/null && ok "T14 NOT drained/bounced" || nok "T14 no-bounce" "kickstart was called: $(cat "$MOCK/kicks.log" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# T15 (ga-j3j6s): a SENSITIVE hot-path daemon whose CURRENT process already
# started AFTER the deploy (some OTHER mechanism — e.g. the rig's own
# auto-deploy — already restarted it) must NOT be flagged NEEDS_GUARDED_RESTART.
# Before this fix, the sensitive-with-no-drain-path branch unconditionally
# flagged GUARDED without ever checking whether the live process is already
# running the new code — a false positive that sends a human toward an
# unnecessary hot-path restart (real incident: com.whatsapp.map-viewer,
# auto-deploy had already restarted it before the alarm fired). The freshness
# check reuses DEPLOY_EPOCH/pid-start-epoch — the SAME comparison
# verify_fresh() already uses elsewhere in this file — never a file-mtime
# comparison (the ga-j3j6s bead's own caution: a daemon can serve from a
# different tree than the changed file, which would make an mtime check lie).
# ════════════════════════════════════════════════════════════════════════════
new_case t15
cat > "$RUNTIME/daemons/central_sender.py" <<<'print("send")'
make_plist "$AGENTS" com.test.central-sender "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/central_sender.py"
# already fresh: the live process started AFTER DEPLOY_EPOCH, exactly like
# verify_fresh() would confirm — but NOTHING in this script triggered that
# restart; some other mechanism (e.g. auto-deploy) did.
seed_running com.test.central-sender 9001 "$FRESH_LSTART"
OUT=$(run_helper daemons/central_sender.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T15 verdict OK (already-fresh sensitive daemon not flagged)" || nok "T15 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T15 exit 0" || nok "T15 exit" "rc=$RC"
echo "$(field GUARDED "$OUT")" | grep "com.test.central-sender" >/dev/null && nok "T15 should NOT be GUARDED" "$(field GUARDED "$OUT")" || ok "T15 not flagged GUARDED"
echo "$(field ALREADY_FRESH "$OUT")" | grep "com.test.central-sender" >/dev/null && ok "T15 recorded in ALREADY_FRESH" || nok "T15 already_fresh" "$(field ALREADY_FRESH "$OUT")"
! grep -q "com.test.central-sender" "$MOCK/kicks.log" 2>/dev/null && ok "T15 NOT kickstarted (already fresh — no restart needed at all)" || nok "T15 no-kickstart" "kickstart was called: $(cat "$MOCK/kicks.log" 2>/dev/null)"
[ "$(field PROOF "$OUT")" = "verified" ] && ok "T15 PROOF=verified (freshness positively confirmed, just via a different restart path)" || nok "T15 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T16 (ga-j3j6s): a MIXED deploy — one SENSITIVE daemon already fresh (skipped,
# no flag) and a DIFFERENT SENSITIVE daemon still genuinely stale (correctly
# flagged) — the overall verdict must still be NEEDS_GUARDED_RESTART (GUARDED
# outranks ALREADY_FRESH), proving the already-fresh short-circuit for one
# daemon can never mask a real guarded-restart need for another daemon in the
# same deploy.
# ════════════════════════════════════════════════════════════════════════════
new_case t16
cat > "$RUNTIME/daemons/central_sender.py" <<<'print("send")'
cat > "$RUNTIME/daemons/slot_scheduler.py" <<<'print("sched")'
make_plist "$AGENTS" com.test.central-sender "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/central_sender.py"
make_plist "$AGENTS" com.test.slot-scheduler "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/slot_scheduler.py"
seed_running com.test.central-sender 9101 "$FRESH_LSTART"   # already fresh
seed_running com.test.slot-scheduler 9201 "$STALE_LSTART"   # still stale
OUT=$(run_helper daemons/central_sender.py daemons/slot_scheduler.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T16 verdict NEEDS_GUARDED_RESTART (one stale daemon still wins over an already-fresh sibling)" || nok "T16 verdict" "got '$V' out=[$OUT]"
[ "$RC" -ne 0 ] && ok "T16 non-zero exit (halts delivery)" || nok "T16 exit" "rc=$RC"
echo "$(field GUARDED "$OUT")" | grep "com.test.slot-scheduler" >/dev/null && ok "T16 stale daemon flagged GUARDED" || nok "T16 guarded (stale)" "$(field GUARDED "$OUT")"
echo "$(field GUARDED "$OUT")" | grep "com.test.central-sender" >/dev/null && nok "T16 fresh daemon should NOT be in GUARDED" "$(field GUARDED "$OUT")" || ok "T16 fresh daemon not in GUARDED"
echo "$(field ALREADY_FRESH "$OUT")" | grep "com.test.central-sender" >/dev/null && ok "T16 fresh daemon recorded in ALREADY_FRESH" || nok "T16 already_fresh" "$(field ALREADY_FRESH "$OUT")"
! grep -q "com.test.central-sender" "$MOCK/kicks.log" 2>/dev/null && ok "T16 fresh daemon NOT kickstarted" || nok "T16 no-kickstart" "kickstart log: $(cat "$MOCK/kicks.log" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# T17 (ga-00ptz): a daemon's plist entrypoint lives under a SEPARATE,
# independently-deployed clone of the SAME repo (real-world: painel-prod vs.
# whatsapp_automation — two independent `git clone`s of one upstream, kept in
# sync by an unrelated deploy-sync mechanism, not by story-delivery.sh's own
# git-pull). Pre-fix, resolve_relpath() only matched a plist path literal
# under RUNTIME_DIR (or with a $VAR/ prefix to strip) — an absolute path under
# this second clone matched neither, so the daemon was silently dropped in
# Step 2 and never reached Step 3's AFFECTED check, regardless of what
# changed: VERDICT=OK/PROOF=not_verified/"touches no live daemon" for a
# daemon that is, in fact, live and running the changed file. Listing the
# second clone's root in EXTRA_RUNTIME_ROOTS fixes discovery: the SAME
# relpath must also exist under RUNTIME_DIR (the tree actually being diffed),
# so this only ever grants visibility into a file genuinely present in both
# trees — it can never invent an entrypoint out of thin air.
# ════════════════════════════════════════════════════════════════════════════
new_case t17
SECOND_CLONE="$CASE_DIR/second_clone"
mkdir -p "$SECOND_CLONE/daemons"
cat > "$SECOND_CLONE/daemons/painel_visibilidade.py" <<<'print("painel")'
cat > "$RUNTIME/daemons/painel_visibilidade.py" <<<'print("painel")'
make_plist "$AGENTS" com.test.painel-visibilidade "$SECOND_CLONE/venv/bin/python3" "$SECOND_CLONE/daemons/painel_visibilidade.py"
seed_running com.test.painel-visibilidade 9301 "$STALE_LSTART"
seed_restart com.test.painel-visibilidade 9399 "$FRESH_LSTART"
EXTRA_RUNTIME_ROOTS="$SECOND_CLONE"
OUT=$(run_helper daemons/painel_visibilidade.py); RC=$?
unset EXTRA_RUNTIME_ROOTS
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T17 verdict OK" || nok "T17 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T17 exit 0" || nok "T17 exit" "rc=$RC"
echo "$(field AFFECTED "$OUT")" | grep "com.test.painel-visibilidade" >/dev/null && ok "T17 daemon under second clone discovered + affected" || nok "T17 affected" "$(field AFFECTED "$OUT")"
echo "$(field RESTARTED "$OUT")" | grep "com.test.painel-visibilidade" >/dev/null && ok "T17 daemon restarted" || nok "T17 restarted" "$(field RESTARTED "$OUT")"
[ "$(field PROOF "$OUT")" = "verified" ] && ok "T17 PROOF=verified (no longer a false 'touches no live daemon')" || nok "T17 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T18: (ga-omfwe) DRY_RUN=1 on an affected SAFE dashboard → previews via
# WOULD_RESTART, never populates RESTARTED, never kickstarts, never claims
# PROOF=verified. Pre-fix, this case reported RESTARTED and PROOF=verified
# identically to a real restart (T2) even though nothing ran.
# ════════════════════════════════════════════════════════════════════════════
new_case t18
cat > "$RUNTIME/daemons/ban_risk_dashboard.py" <<<'print("dash")'
make_plist "$AGENTS" com.test.ban-risk-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/ban_risk_dashboard.py"
seed_running com.test.ban-risk-dashboard 4001 "$STALE_LSTART"
seed_restart com.test.ban-risk-dashboard 4099 "$FRESH_LSTART"
DRY_RUN=1
OUT=$(run_helper daemons/ban_risk_dashboard.py); RC=$?
unset DRY_RUN
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T18 verdict OK" || nok "T18 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T18 exit 0" || nok "T18 exit" "rc=$RC"
echo "$(field RESTARTED "$OUT")" | grep "com.test.ban-risk-dashboard" >/dev/null && nok "T18 RESTARTED must stay empty under DRY_RUN=1" "$(field RESTARTED "$OUT")" || ok "T18 RESTARTED empty (pre-fix bug: populated even under DRY_RUN=1)"
echo "$(field WOULD_RESTART "$OUT")" | grep "com.test.ban-risk-dashboard" >/dev/null && ok "T18 WOULD_RESTART reports the preview" || nok "T18 would_restart" "$(field WOULD_RESTART "$OUT")"
[ "$(field PROOF "$OUT")" = "not_applicable" ] && ok "T18 PROOF=not_applicable (never 'verified' when nothing ran)" || nok "T18 proof" "got '$(field PROOF "$OUT")' (pre-fix bug: this was 'verified')"
[ ! -f "$MOCK/kicks.log" ] && ok "T18 no kickstart called under DRY_RUN=1" || nok "T18 kickstart" "called: $(cat "$MOCK/kicks.log" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# T19 (ga-otn7u): a plist with a literal "--" inside an XML <!-- --> comment
# (expat rejects it; Apple's own launchd parser tolerates it — the exact shape
# of 5 live plists found broken this way, incl. throughput-stall-watchdog.plist
# itself) used to be silently DROPPED from discovery: plist_args() caught ANY
# exception and exited 0, indistinguishable from "this plist genuinely has no
# ProgramArguments". Post-fix, plist_args() exits 1 on a parse failure and the
# caller logs a WARN naming the plist — and a HEALTHY sibling plist in the same
# LAUNCH_AGENTS_DIR is still discovered and processed normally (one broken
# plist must not blind discovery of every other daemon).
# ════════════════════════════════════════════════════════════════════════════
new_case t19
cat > "$RUNTIME/daemons/ban_risk_dashboard.py" <<<'print("dash")'
make_plist "$AGENTS" com.test.ban-risk-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/ban_risk_dashboard.py"
seed_running com.test.ban-risk-dashboard 9501 "$STALE_LSTART"
seed_restart com.test.ban-risk-dashboard 9599 "$FRESH_LSTART"
cat > "$AGENTS/com.test.broken-comment.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.test.broken-comment</string>
  <!-- a stray double-hyphen -- inside this comment breaks plistlib's expat
       parser even though launchd itself loads this file fine -->
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/true</string>
  </array>
</dict>
</plist>
EOF
OUT=$(run_helper_stderr daemons/ban_risk_dashboard.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T19 verdict OK (healthy daemon still processed normally)" || nok "T19 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T19 exit 0" || nok "T19 exit" "rc=$RC"
echo "$(field RESTARTED "$OUT")" | grep "com.test.ban-risk-dashboard" >/dev/null && ok "T19 healthy sibling still restarted+verified" || nok "T19 restarted" "$(field RESTARTED "$OUT")"
echo "$OUT" | grep "com.test.broken-comment.plist could not be parsed" >/dev/null && ok "T19 WARN names the broken plist (pre-fix: no warning existed anywhere)" || nok "T19 warn" "no distinguishing WARN in output: [$OUT]"
[ "$(field PROOF "$OUT")" = "verified" ] && ok "T19 PROOF=verified (the healthy daemon's own verification is unaffected by its broken sibling)" || nok "T19 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T20 (ga-otn7u): EVERY plist in LAUNCH_AGENTS_DIR is unparseable — pre-fix,
# this collapsed to the exact same "no rig daemons discovered — OK" as a
# directory that genuinely has zero rig daemons in it (both produced
# PROOF=not_applicable, an unearned claim of certainty — the exact
# error-and-empty-must-not-produce-the-same-value defect class). Post-fix this
# must read as not_verified: discovery could not confirm the directory is
# empty of daemons, it only knows it could not read what's there.
# ════════════════════════════════════════════════════════════════════════════
new_case t20
cat > "$RUNTIME/daemons/some_other_thing.py" <<<'print("x")'
cat > "$AGENTS/com.test.broken-only.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.test.broken-only</string>
  <!-- another stray double-hyphen -- here -->
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/true</string>
  </array>
</dict>
</plist>
EOF
OUT=$(run_helper_stderr daemons/some_other_thing.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T20 verdict OK" || nok "T20 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T20 exit 0" || nok "T20 exit" "rc=$RC"
echo "$OUT" | grep "com.test.broken-only.plist could not be parsed" >/dev/null && ok "T20 WARN names the broken plist" || nok "T20 warn" "no distinguishing WARN in output: [$OUT]"
[ "$(field PROOF "$OUT")" = "not_verified" ] && ok "T20 PROOF=not_verified (discovery incomplete, not confirmed-empty — pre-fix bug: this was not_applicable, indistinguishable from a genuinely empty dir)" || nok "T20 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T21 (ga-y108i): a SENSITIVE hot-path daemon, currently STALE, whose deploy
# touched ONLY a file under a rig-declared no_restart_paths glob (a static
# asset a handler re-reads from disk on every request — never needs a
# restart to serve new bytes). Must emit OK with PROOF=asset_served_per_request
# instead of flagging NEEDS_GUARDED_RESTART — the real incident this closes:
# a commit touching only daemons/static/demand_previsao.js flagged the
# demand-dashboard daemon (policy-unlisted → sensitive) and mailed the Mayor;
# the restart was proven pointless by hand (live-served md5 already matched
# the merged blob, pre-merge PID still running). The changed file here is
# *.js — not *.py/template — so a pre-fix run already reaches VERDICT=OK via
# the unrelated extension-based early-exit; the assertion that actually
# distinguishes pre/post-fix is PROOF (not_applicable pre-fix vs. the more
# specific asset_served_per_request post-fix). T22 below is the stronger
# proof that does not depend on that early-exit at all.
# ════════════════════════════════════════════════════════════════════════════
new_case t21
cat > "$RUNTIME/daemons/demand_dashboard.py" <<<'print("demand")'
make_plist "$AGENTS" com.test.demand-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/demand_dashboard.py"
seed_running com.test.demand-dashboard 9601 "$STALE_LSTART"
cat > "$RUNTIME/daemons/restart_policy.yaml" <<'EOF'
no_restart_paths:
  - daemons/static/**
EOF
OUT=$(run_helper daemons/static/demand_previsao.js); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T21 verdict OK (static asset under no_restart_paths)" || nok "T21 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T21 exit 0" || nok "T21 exit" "rc=$RC"
[ "$(field PROOF "$OUT")" = "asset_served_per_request" ] && ok "T21 PROOF=asset_served_per_request" || nok "T21 proof" "got '$(field PROOF "$OUT")'"
[ ! -f "$MOCK/kicks.log" ] && ok "T21 no kickstart called" || nok "T21 kickstart" "called: $(cat "$MOCK/kicks.log" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# T22 (ga-y108i): stronger proof than T21 — the changed file IS the daemon's
# own *.py entrypoint (so pre-fix this reaches AFFECTED/SENSITIVE/GUARDED via
# the normal direct-match *.py path, NOT the extension-based early-exit T21
# also passes through), but that entrypoint lives under a declared
# no_restart_paths glob (a static-file server that only ever proxies bytes
# from disk). The declaration is deliberately PATH-based, not
# extension-based, per the bug's own caution: a *.py helper can be just as
# exemptable as a *.js file. Must be OK/asset_served_per_request, never
# NEEDS_GUARDED_RESTART.
# ════════════════════════════════════════════════════════════════════════════
new_case t22
mkdir -p "$RUNTIME/daemons/static"
cat > "$RUNTIME/daemons/static/serve_static.py" <<<'print("serve")'
make_plist "$AGENTS" com.test.demand-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/static/serve_static.py"
seed_running com.test.demand-dashboard 9701 "$STALE_LSTART"
cat > "$RUNTIME/daemons/restart_policy.yaml" <<'EOF'
no_restart_paths:
  - daemons/static/**
EOF
OUT=$(run_helper daemons/static/serve_static.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T22 verdict OK (entrypoint *.py under no_restart_paths, not flagged)" || nok "T22 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T22 exit 0" || nok "T22 exit" "rc=$RC"
[ "$(field PROOF "$OUT")" = "asset_served_per_request" ] && ok "T22 PROOF=asset_served_per_request" || nok "T22 proof" "got '$(field PROOF "$OUT")'"
[ ! -f "$MOCK/kicks.log" ] && ok "T22 no kickstart called" || nok "T22 kickstart" "called: $(cat "$MOCK/kicks.log" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# T23 (ga-y108i): partial coverage must NOT exempt — a MIXED deploy where one
# changed file matches no_restart_paths (a static asset) and a SEPARATE
# changed file does not (the daemon's own *.py entrypoint, elsewhere in the
# tree). The whole changed set must be covered, not just one file in it —
# otherwise an innocuous static-asset tweak riding along in the same commit
# as a real logic change would wrongly suppress a needed guarded-restart flag.
# ════════════════════════════════════════════════════════════════════════════
new_case t23
mkdir -p "$RUNTIME/daemons/static"
cat > "$RUNTIME/daemons/frota_dashboard.py" <<<'print("frota")'
make_plist "$AGENTS" com.test.frota-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/frota_dashboard.py"
seed_running com.test.frota-dashboard 9801 "$STALE_LSTART"
cat > "$RUNTIME/daemons/restart_policy.yaml" <<'EOF'
no_restart_paths:
  - daemons/static/**
EOF
OUT=$(run_helper daemons/static/some_asset.js daemons/frota_dashboard.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T23 verdict NEEDS_GUARDED_RESTART (mixed diff, entrypoint change NOT covered by no_restart_paths)" || nok "T23 verdict" "got '$V' out=[$OUT]"
[ "$RC" -ne 0 ] && ok "T23 non-zero exit" || nok "T23 exit" "rc=$RC"
echo "$(field GUARDED "$OUT")" | grep "com.test.frota-dashboard" >/dev/null && ok "T23 flagged GUARDED despite one covered file in the same diff" || nok "T23 guarded" "$(field GUARDED "$OUT")"

# ════════════════════════════════════════════════════════════════════════════
# T24 (ga-y108i): a declared no_restart_paths glob must be PRECISE — it must
# NOT accidentally cover an unrelated path. This same rig's Jinja templates
# ARE compiled/cached at import (ga-jkj0) and still genuinely need a restart
# even though daemons/static/** is separately declared no-restart. A changed
# template (rendered by an explicitly-SAFE daemon) must still restart
# normally when it does not match the declared glob.
# ════════════════════════════════════════════════════════════════════════════
new_case t24
cat > "$RUNTIME/daemons/map_viewer_dashboard.py" <<'PYEOF'
from flask import render_template
def index():
    return render_template("map_viewer.html")
PYEOF
mkdir -p "$RUNTIME/templates"
cat > "$RUNTIME/templates/map_viewer.html" <<<'<html>old</html>'
make_plist "$AGENTS" com.test.map-viewer "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/map_viewer_dashboard.py"
seed_running com.test.map-viewer 9901 "$STALE_LSTART"
seed_restart com.test.map-viewer 9999 "$FRESH_LSTART"
cat > "$RUNTIME/daemons/restart_policy.yaml" <<'EOF'
auto:
  - map_viewer_dashboard.py
no_restart_paths:
  - daemons/static/**
EOF
OUT=$(run_helper templates/map_viewer.html); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T24 verdict OK after real restart (no_restart_paths glob correctly does not cover templates/)" || nok "T24 verdict" "got '$V' out=[$OUT]"
grep -q "com.test.map-viewer" "$MOCK/kicks.log" 2>/dev/null && ok "T24 kickstart invoked (template change still triggers real restart)" || nok "T24 kickstart" "log: $(cat "$MOCK/kicks.log" 2>/dev/null)"
[ "$(field PROOF "$OUT")" = "verified" ] && ok "T24 PROOF=verified (real restart, not asset_served_per_request)" || nok "T24 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T25 (ga-y108i gate-fix): the no_restart_paths short-circuit must be
# CWD-independent. POLICY_NO_RESTART_PATHS holds glob-pattern TEXT (e.g.
# "daemons/static/**"); a bare `for pat in $POLICY_NO_RESTART_PATHS` performs
# bash pathname expansion on each split word, so a CWD that merely happens to
# contain a matching subtree (unrelated to RUNTIME_DIR — e.g. an adjacent
# worktree checkout, or an agent session that cd'd into a rig directory to
# debug) silently substitutes real filenames for the pattern string, the
# short-circuit fails to fire, and the deploy falls through to
# NEEDS_GUARDED_RESTART even though every changed file matches the declared
# glob. Same fixture as T22 (a *.py entrypoint under the glob, bypassing the
# unrelated extension-based early-exit so this assertion depends entirely on
# the short-circuit), but run from a CWD seeded with a colliding
# daemons/static/ subtree instead of the test runner's own CWD.
# ════════════════════════════════════════════════════════════════════════════
new_case t25
mkdir -p "$RUNTIME/daemons/static"
cat > "$RUNTIME/daemons/static/serve_static.py" <<<'print("serve")'
make_plist "$AGENTS" com.test.demand-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/static/serve_static.py"
seed_running com.test.demand-dashboard 9702 "$STALE_LSTART"
cat > "$RUNTIME/daemons/restart_policy.yaml" <<'EOF'
no_restart_paths:
  - daemons/static/**
EOF
COLLIDE_CWD="$CASE_DIR/unrelated_cwd"
mkdir -p "$COLLIDE_CWD/daemons/static"
: > "$COLLIDE_CWD/daemons/static/unrelated_file.py"
OUT=$(cd "$COLLIDE_CWD" && run_helper daemons/static/serve_static.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T25 verdict OK from a CWD with a colliding daemons/static/ subtree (no_restart_paths glob not corrupted by CWD pathname expansion)" || nok "T25 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T25 exit 0" || nok "T25 exit" "rc=$RC"
[ "$(field PROOF "$OUT")" = "asset_served_per_request" ] && ok "T25 PROOF=asset_served_per_request" || nok "T25 proof" "got '$(field PROOF "$OUT")'"
[ ! -f "$MOCK/kicks.log" ] && ok "T25 no kickstart called" || nok "T25 kickstart" "called: $(cat "$MOCK/kicks.log" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# T26 (ga-puq8z): a SENSITIVE daemon whose live process restarted (some OTHER
# path — e.g. a sibling bead's own guarded restart) AFTER the commit under
# review was made, but BEFORE DEPLOY_EPOCH (this check's own start time), must
# NOT be flagged NEEDS_GUARDED_RESTART. Pre-fix, already_fresh() compared the
# pid's start time against DEPLOY_EPOCH alone — captured by the CALLER right
# before ITS OWN deploy step, which can be minutes-to-hours after the commit
# itself (gate-queue wait, deploy retry/backoff, a slow sweep cycle). A daemon
# already refreshed in that gap has a pid-start strictly AFTER the commit but
# strictly BEFORE DEPLOY_EPOCH — genuinely fresh, but the old DEPLOY_EPOCH-only
# comparison called it stale and flagged an unnecessary hot-path restart.
# Real incident (measured 2026-09-01): com.whatsapp.demand-dashboard flagged
# twice within 15 minutes, both times already running code newer than the
# commit each check was verifying — this is that exact shape, reproduced
# deterministically via POST_COMMIT_EPOCH (see new_case()/run_helper()).
# gate-fix-2 (gate_run=ga-9a45d, Reviewer-1 FAIL): the first gate-fix reported
# this case as PROOF=verified — the same confidence tag verify_fresh() earns
# by confirming a restart THIS script itself performed. That overclaims: a
# launchd KeepAlive respawn of a crashed SENSITIVE daemon landing between the
# commit and DEPLOY_EPOCH would pass the identical pid-start-vs-COMMIT_EPOCH
# test while still running pre-deploy code. This is a correlation, not proof
# — VERDICT stays OK (still no unneeded guarded restart) but PROOF must be
# not_verified, matching every other case in this script that cannot
# positively confirm live freshness.
# ════════════════════════════════════════════════════════════════════════════
SENSITIVE_DAEMONS="central-sender conversation-monitor slot-scheduler webhook demand-dashboard"
new_case t26
POST_COMMIT_EPOCH=$(( DEPLOY_EPOCH - 3000 ))            # commit made 50 min before this check started
ALREADY_FRESH_MID_LSTART="$(lstart_of $(( DEPLOY_EPOCH - 300 )) )"  # daemon restarted 5 min before this check — AFTER the commit, BEFORE DEPLOY_EPOCH
cat > "$RUNTIME/daemons/demand_dashboard.py" <<<'print("demand")'
make_plist "$AGENTS" com.test.demand-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/demand_dashboard.py"
seed_running com.test.demand-dashboard 9301 "$ALREADY_FRESH_MID_LSTART"
OUT=$(run_helper daemons/demand_dashboard.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T26 verdict OK (daemon already fresher than the commit under review, despite predating DEPLOY_EPOCH)" || nok "T26 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T26 exit 0" || nok "T26 exit" "rc=$RC"
echo "$(field GUARDED "$OUT")" | grep "com.test.demand-dashboard" >/dev/null && nok "T26 should NOT be GUARDED" "$(field GUARDED "$OUT")" || ok "T26 not flagged GUARDED"
echo "$(field ALREADY_FRESH "$OUT")" | grep "com.test.demand-dashboard" >/dev/null && ok "T26 recorded in ALREADY_FRESH" || nok "T26 already_fresh" "$(field ALREADY_FRESH "$OUT")"
! grep -q "com.test.demand-dashboard" "$MOCK/kicks.log" 2>/dev/null && ok "T26 NOT kickstarted" || nok "T26 no-kickstart" "kickstart was called: $(cat "$MOCK/kicks.log" 2>/dev/null)"
[ "$(field PROOF "$OUT")" = "not_verified" ] && ok "T26 PROOF=not_verified (pid-start-vs-commit is a plausibility check, not proof — gate-fix-2)" || nok "T26 proof" "got '$(field PROOF "$OUT")', want not_verified"

# ════════════════════════════════════════════════════════════════════════════
# T27 (ga-puq8z): companion to T26 — a SENSITIVE daemon whose live process
# predates the COMMIT itself (genuinely stale, not merely "before
# DEPLOY_EPOCH") must still be flagged NEEDS_GUARDED_RESTART. Proves the
# COMMIT_EPOCH-based comparison introduced for T26 does not widen the
# already-fresh window enough to swallow a real stale daemon — the class of
# regression T16 already guards for DEPLOY_EPOCH, mirrored here for
# COMMIT_EPOCH.
# ════════════════════════════════════════════════════════════════════════════
new_case t27
POST_COMMIT_EPOCH=$(( DEPLOY_EPOCH - 3000 ))            # commit made 50 min before this check started
STILL_STALE_LSTART="$(lstart_of $(( DEPLOY_EPOCH - 4000 )) )"  # daemon started BEFORE the commit itself
cat > "$RUNTIME/daemons/demand_dashboard.py" <<<'print("demand")'
make_plist "$AGENTS" com.test.demand-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/demand_dashboard.py"
seed_running com.test.demand-dashboard 9401 "$STILL_STALE_LSTART"
OUT=$(run_helper daemons/demand_dashboard.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T27 verdict NEEDS_GUARDED_RESTART (process predates the commit itself — genuinely stale)" || nok "T27 verdict" "got '$V' out=[$OUT]"
[ "$RC" -ne 0 ] && ok "T27 non-zero exit" || nok "T27 exit" "rc=$RC"
echo "$(field GUARDED "$OUT")" | grep "com.test.demand-dashboard" >/dev/null && ok "T27 flagged GUARDED" || nok "T27 guarded" "$(field GUARDED "$OUT")"

# ════════════════════════════════════════════════════════════════════════════
# T28 (ga-dk7fw, header point 9): an ISOLATED tests/*.py change — a single
# test file, entrypoints unrelated to it — must resolve with the CLEAN,
# structurally-certain PROOF=not_applicable, not the weaker not_verified.
#
# IMPORTANT (measured directly against the pre-fix script before writing this
# test, so this assertion is not guesswork): VERDICT was already OK for this
# exact fixture pre-fix too — Step 3's "changed code touches no live daemon"
# fallback already resolves an isolated, unimported test file to OK, via
# PROOF=not_verified. So the observable delta here is NOT the verdict/exit
# code (both are OK) — it is PROOF/REASON. That distinction is NOT cosmetic:
# story-delivery.sh (Delivery COMPLETE branch) special-cases PROOF via a
# `case "$REFRESH_PROOF" in verified|not_applicable|asset_served_per_request)
# : ;; *) ...esac` — anything OTHER than those three tiers (not_verified
# included) adds a delivery:daemon-unverified label to the STORY bead and
# rewrites its done-notification to "DAEMON LIVENESS NOT VERIFIED — merged
# code may still be dormant". Pre-fix, a story whose branch touched ONLY a
# test file got that exact label and scary wording despite zero daemon
# relevance — the real, evidenced noise class this fix removes, one hop
# downstream of daemon-refresh.sh itself (see the wa-zmmyd citation on
# ga-dk7fw for the full incident this traces back to — the ACTUAL alert
# there was legitimate, driven by real production files in the same deploy;
# T30 below reproduces that mixed-commit shape and proves it still flags).
# ════════════════════════════════════════════════════════════════════════════
SENSITIVE_DAEMONS="campaign central-sender"
new_case t28
cat > "$RUNTIME/daemons/campaign_scheduler.py" <<<'def run(): pass'
cat > "$RUNTIME/daemons/central_sender.py" <<<'def send(): pass'
make_plist "$AGENTS" com.test.campaign-scheduler "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/campaign_scheduler.py"
make_plist "$AGENTS" com.test.central-sender "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/central_sender.py"
seed_running com.test.campaign-scheduler 9801 "$STALE_LSTART"
seed_running com.test.central-sender 9802 "$STALE_LSTART"
# deploy changed ONLY an isolated test file — the exact wa-zmmyd shape
OUT=$(run_helper tests/test_campaign_alltime_dedup_wa_zmmyd.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T28 verdict OK (tests/-only change)" || nok "T28 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T28 exit 0" || nok "T28 exit" "rc=$RC"
[ -z "$(field AFFECTED "$OUT")" ] && ok "T28 no daemon marked AFFECTED" || nok "T28 affected" "$(field AFFECTED "$OUT")"
[ ! -f "$MOCK/kicks.log" ] && ok "T28 no kickstart called" || nok "T28 kickstart" "called: $(cat "$MOCK/kicks.log" 2>/dev/null)"
[ "$(field PROOF "$OUT")" = "not_applicable" ] && ok "T28 PROOF=not_applicable (structurally certain, not merely undetected — the delta from pre-fix not_verified that clears story-delivery.sh's delivery:daemon-unverified case)" || nok "T28 proof" "got '$(field PROOF "$OUT")', want not_applicable"
echo "$(field REASON "$OUT")" | grep -i "structurally inert" >/dev/null && ok "T28 REASON names the structurally-inert path class" || nok "T28 reason" "$(field REASON "$OUT")"

# ════════════════════════════════════════════════════════════════════════════
# T29 (ga-dk7fw): docs/**, *.md-only changes — the other two path classes
# ACEITE item 1 names — resolve the same way as T28 (same mechanism, both
# default patterns exercised together: a nested docs/ file and a root *.md
# file NOT under docs/, matching the "*.md" pattern independently of "docs/**").
# ════════════════════════════════════════════════════════════════════════════
SENSITIVE_DAEMONS="campaign central-sender"
new_case t29
cat > "$RUNTIME/daemons/campaign_scheduler.py" <<<'def run(): pass'
make_plist "$AGENTS" com.test.campaign-scheduler "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/campaign_scheduler.py"
seed_running com.test.campaign-scheduler 9803 "$STALE_LSTART"
OUT=$(run_helper docs/architecture/campaign_scheduler.md CONTRIBUTING.md); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T29 verdict OK (docs/ + root *.md change)" || nok "T29 verdict" "got '$V' out=[$OUT]"
[ -z "$(field AFFECTED "$OUT")" ] && ok "T29 no daemon marked AFFECTED" || nok "T29 affected" "$(field AFFECTED "$OUT")"
[ "$(field PROOF "$OUT")" = "not_applicable" ] && ok "T29 PROOF=not_applicable" || nok "T29 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T30 (ga-dk7fw ACEITE item 2 — no escape hatch): a MIXED deploy where a
# changed shared module IS genuinely imported by a daemon, alongside an
# unrelated tests/*.py file in the SAME deploy, must still flag normally —
# the tests/ file must never exempt real, co-changed production code. This is
# the actual shape of the wa-zmmyd incident (verified against its own posted
# daemon-refresh log: the real CHANGED set was 4 production .py files plus 2
# tests/*.py files, all in one deploy — the alert was correct because of the
# 4 real files, not caused by the 2 test files).
# ════════════════════════════════════════════════════════════════════════════
SENSITIVE_DAEMONS="campaign central-sender"
new_case t30
mkdir -p "$RUNTIME/lib"
cat > "$RUNTIME/lib/dedup_check.py" <<<'def is_duplicate(): pass'
cat > "$RUNTIME/daemons/central_sender.py" <<'PYEOF'
from lib.dedup_check import is_duplicate
is_duplicate()
PYEOF
make_plist "$AGENTS" com.test.central-sender "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/central_sender.py"
seed_running com.test.central-sender 9804 "$STALE_LSTART"
OUT=$(run_helper lib/dedup_check.py tests/test_dedup_check_wa_zmmyd.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T30 verdict NEEDS_GUARDED_RESTART (mixed lib/+tests/ deploy still flags the real lib/ change)" || nok "T30 verdict" "got '$V' out=[$OUT]"
[ "$RC" -ne 0 ] && ok "T30 non-zero exit" || nok "T30 exit" "rc=$RC"
echo "$(field GUARDED "$OUT")" | grep "com.test.central-sender" >/dev/null && ok "T30 sensitive daemon flagged GUARDED despite co-changed tests/ file" || nok "T30 guarded" "$(field GUARDED "$OUT")"

# ════════════════════════════════════════════════════════════════════════════
# T31 (ga-tdzsh): a plist that fails to parse, but launchd DOES have that
# label loaded (with a live PID) — the real coverage gap this bug is about: a
# live daemon invisible to discovery because its own plist is unparseable
# (real incident: com.gastown.dolt-server, the city's data plane, hidden this
# way until 2026-09-02/ga-dgrzf). Must escalate distinctly from a merely
# unparseable-and-UNLOADED plist (T19/T20 above, unchanged): an ERROR-level
# log line naming the daemon, and the label present in the new
# PARSE_ERROR_LOADED structured field. A healthy sibling daemon in the same
# scan is still processed normally either way (same point T19 already proves).
# ════════════════════════════════════════════════════════════════════════════
new_case t31
cat > "$RUNTIME/daemons/ban_risk_dashboard.py" <<<'print("dash")'
make_plist "$AGENTS" com.test.ban-risk-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/ban_risk_dashboard.py"
seed_running com.test.ban-risk-dashboard 9901 "$STALE_LSTART"
seed_restart com.test.ban-risk-dashboard 9999 "$FRESH_LSTART"
cat > "$AGENTS/com.test.broken-loaded.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.test.broken-loaded</string>
  <!-- a stray double-hyphen -- inside this comment breaks plistlib's expat
       parser even though launchd itself loads this file fine -->
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/true</string>
  </array>
</dict>
</plist>
EOF
seed_running com.test.broken-loaded 9911 "$STALE_LSTART"   # loaded + live PID; the plist itself still never parses
OUT=$(run_helper_stderr daemons/ban_risk_dashboard.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T31 verdict OK (healthy sibling daemon still processed normally)" || nok "T31 verdict" "got '$V' out=[$OUT]"
echo "$OUT" | grep "ERROR:.*com.test.broken-loaded.plist could not be parsed" >/dev/null && ok "T31 ERROR-level line names the LOADED broken daemon (pre-fix: this line did not exist — only an unescalated WARN)" || nok "T31 error-line" "no escalated ERROR line in output: [$OUT]"
echo "$(field PARSE_ERROR_LOADED "$OUT")" | grep -x "com.test.broken-loaded" >/dev/null && ok "T31 PARSE_ERROR_LOADED carries the loaded label (pre-fix: field did not exist at all)" || nok "T31 parse_error_loaded" "got '$(field PARSE_ERROR_LOADED "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T32 (ga-tdzsh): a plist that fails to parse, and launchd has NO record of
# that label at all (dead symlink / stale file — the current, real state of
# com.athos.ckan_pbh and com.urblink.inbound-review-3d on the live machine,
# per ga-dgrzf). Must NOT escalate — this is the ACEITE bar: a run today, with
# both known-broken plists unloaded, must not produce an escalatable alarm.
# No ERROR-level line, PARSE_ERROR_LOADED stays empty. The plist is still
# named in PARSE_ERROR_UNLOADED and a low-priority note — visible for cleanup,
# just never confused for a live gap.
# ════════════════════════════════════════════════════════════════════════════
new_case t32
cat > "$RUNTIME/daemons/ban_risk_dashboard.py" <<<'print("dash")'
make_plist "$AGENTS" com.test.ban-risk-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/ban_risk_dashboard.py"
seed_running com.test.ban-risk-dashboard 9921 "$STALE_LSTART"
seed_restart com.test.ban-risk-dashboard 9929 "$FRESH_LSTART"
cat > "$AGENTS/com.test.broken-unloaded.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.test.broken-unloaded</string>
  <!-- a stray double-hyphen -- here, and nothing loaded under this label -->
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/true</string>
  </array>
</dict>
</plist>
EOF
# deliberately NOT seeded as running or loaded — mirrors a dead symlink/stale file
OUT=$(run_helper_stderr daemons/ban_risk_dashboard.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T32 verdict OK" || nok "T32 verdict" "got '$V' out=[$OUT]"
! echo "$OUT" | grep "ERROR:.*com.test.broken-unloaded" >/dev/null && ok "T32 no ERROR-level line for an unloaded broken plist (THE ACEITE bar)" || nok "T32 no-error" "escalated when it should not have: [$OUT]"
[ -z "$(field PARSE_ERROR_LOADED "$OUT")" ] && ok "T32 PARSE_ERROR_LOADED stays empty" || nok "T32 parse_error_loaded" "got '$(field PARSE_ERROR_LOADED "$OUT")'"
echo "$(field PARSE_ERROR_UNLOADED "$OUT")" | grep -x "com.test.broken-unloaded" >/dev/null && ok "T32 PARSE_ERROR_UNLOADED still records it (visible, just not escalated)" || nok "T32 parse_error_unloaded" "got '$(field PARSE_ERROR_UNLOADED "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T33 (ga-tdzsh): the escalation check is launchd LOAD status, not live-PID
# presence — a label loaded but with NO current PID (e.g. a KeepAlive=false
# job between runs) must still escalate. Proves daemon_is_loaded() cannot be
# satisfied by reusing daemon_pid(), which is empty for BOTH "not loaded" and
# "loaded but idle" — the exact ambiguity ga-tdzsh is about.
# ════════════════════════════════════════════════════════════════════════════
new_case t33
cat > "$RUNTIME/daemons/ban_risk_dashboard.py" <<<'print("dash")'
make_plist "$AGENTS" com.test.ban-risk-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/ban_risk_dashboard.py"
seed_running com.test.ban-risk-dashboard 9941 "$STALE_LSTART"
seed_restart com.test.ban-risk-dashboard 9949 "$FRESH_LSTART"
cat > "$AGENTS/com.test.broken-idle.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.test.broken-idle</string>
  <!-- a stray double-hyphen -- here; loaded but between runs, no live PID -->
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/true</string>
  </array>
</dict>
</plist>
EOF
seed_loaded com.test.broken-idle   # loaded, but NO live PID
OUT=$(run_helper_stderr daemons/ban_risk_dashboard.py); RC=$?
echo "$OUT" | grep "ERROR:.*com.test.broken-idle.plist could not be parsed" >/dev/null && ok "T33 ERROR line fires for a loaded-but-idle daemon (load status, not PID presence)" || nok "T33 error-line" "no escalated ERROR line: [$OUT]"
echo "$(field PARSE_ERROR_LOADED "$OUT")" | grep -x "com.test.broken-idle" >/dev/null && ok "T33 PARSE_ERROR_LOADED carries the idle-but-loaded label" || nok "T33 parse_error_loaded" "got '$(field PARSE_ERROR_LOADED "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T34 (ga-q617u): route-blueprint hop — a changed lib/*.py module whose ONLY
# caller is a daemons/routes/*.py blueprint file (never imported directly by
# the entrypoint that mounts it) must still mark that entrypoint's daemon
# affected. Real incident: lib/assertiva_cache.py's read_pessoas_ref_items
# changed; its only caller was daemons/routes/pregao.py, mounted by
# classification_dashboard.py via `from routes import ..., pregao, ...` —
# classification_dashboard.py itself never imports assertiva_cache, so the
# single-hop entrypoint-only scan (pre-fix) never flagged it, while two
# UNRELATED daemons that import assertiva_cache directly (for a different
# function) got flagged instead — a false negative on the one daemon that
# actually mattered, hidden behind two false positives on daemons that
# didn't. THIS test proves the false-negative half: the routes-mounted
# daemon must appear in AFFECTED (fails pre-fix: AFFECTED is empty and
# VERDICT/PROOF land on the ga-vmq1i "touches no live daemon"/not_verified
# branch instead of restarting + verifying fresh).
# ════════════════════════════════════════════════════════════════════════════
new_case t34
mkdir -p "$RUNTIME/daemons/routes" "$RUNTIME/lib"
cat > "$RUNTIME/lib/assertiva_cache.py" <<<'def read_pessoas_ref_items(cpf): return []'
cat > "$RUNTIME/daemons/routes/pregao.py" <<'PYEOF'
from lib import assertiva_cache as _ac

def handler():
    return _ac.read_pessoas_ref_items("00000000000")
PYEOF
cat > "$RUNTIME/daemons/classification_dashboard.py" <<'PYEOF'
from routes import pregao

def index():
    return pregao.handler()
PYEOF
make_plist "$AGENTS" com.test.classification-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/classification_dashboard.py"
seed_running com.test.classification-dashboard 9501 "$STALE_LSTART"
seed_restart com.test.classification-dashboard 9599 "$FRESH_LSTART"
# deploy changes ONLY the shared lib module — not the routes file, not the entrypoint
OUT=$(run_helper lib/assertiva_cache.py); RC=$?
V=$(field VERDICT "$OUT")
echo "$(field AFFECTED "$OUT")" | grep "com.test.classification-dashboard" >/dev/null && ok "T34 route-mounted dashboard marked affected via routes/*.py hop" || nok "T34 affected" "$(field AFFECTED "$OUT")"
[ "$V" = "OK" ] && ok "T34 verdict OK after fresh restart" || nok "T34 verdict" "got '$V' out=[$OUT]"
grep -q "com.test.classification-dashboard" "$MOCK/kicks.log" 2>/dev/null && ok "T34 kickstart invoked" || nok "T34 kickstart" "log: $(cat "$MOCK/kicks.log" 2>/dev/null)"
[ "$(field PROOF "$OUT")" = "verified" ] && ok "T34 PROOF=verified" || nok "T34 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T35 (ga-q617u): precision guard — a daemon with a routes/ sibling directory
# must NOT be marked affected via an UNRELATED routes/*.py file it never
# mounts (no cross-dashboard cascade: daemons/routes/ is shared by multiple
# dashboards in the real rig, and each one only mounts a subset of it). Proves
# daemon_imports_stem_via_routes()'s own-mount gate is load-bearing, not just
# "does a routes/ dir exist next to me".
# ════════════════════════════════════════════════════════════════════════════
new_case t35
mkdir -p "$RUNTIME/daemons/routes" "$RUNTIME/lib"
cat > "$RUNTIME/lib/assertiva_cache.py" <<<'def read_pessoas_ref_items(cpf): return []'
cat > "$RUNTIME/daemons/routes/pregao.py" <<'PYEOF'
from lib import assertiva_cache as _ac

def handler():
    return _ac.read_pessoas_ref_items("00000000000")
PYEOF
cat > "$RUNTIME/daemons/routes/cls_shared.py" <<<'def other(): pass'
# demand_dashboard mounts ONLY cls_shared — never pregao
cat > "$RUNTIME/daemons/demand_dashboard.py" <<'PYEOF'
from routes import cls_shared

def index():
    return cls_shared.other()
PYEOF
make_plist "$AGENTS" com.test.demand-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/demand_dashboard.py"
seed_running com.test.demand-dashboard 9601 "$STALE_LSTART"
OUT=$(run_helper lib/assertiva_cache.py); RC=$?
V=$(field VERDICT "$OUT")
echo "$(field AFFECTED "$OUT")" | grep "com.test.demand-dashboard" >/dev/null && nok "T35 should not be affected (never mounts pregao)" "$(field AFFECTED "$OUT")" || ok "T35 demand-dashboard not marked affected (no cross-dashboard cascade)"
[ "$V" = "OK" ] && ok "T35 verdict OK" || nok "T35 verdict" "got '$V' out=[$OUT]"
[ ! -f "$MOCK/kicks.log" ] && ok "T35 no kickstart called" || nok "T35 kickstart" "called: $(cat "$MOCK/kicks.log" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# T36 (ga-q617u): the NEEDS_GUARDED_RESTART REASON text must warn the GUARDED
# list itself can be INCOMPLETE (a daemon reached only through a deeper import
# chain than this scan follows can be silently missing), not just that a
# LISTED daemon might be a false positive — pre-fix the message covered only
# the false-positive half ("may be a false positive"), which is what let a
# real incident's daemon list be read as complete when it was not (ga-q617u:
# "o aviso do detector ate diz 'may be a false positive' — mas ele nao avisa
# que pode ter um falso NEGATIVO").
# ════════════════════════════════════════════════════════════════════════════
new_case t36
cat > "$RUNTIME/daemons/central_sender.py" <<<'print("send")'
make_plist "$AGENTS" com.test.central-sender "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/central_sender.py"
seed_running com.test.central-sender 9701 "$STALE_LSTART"
OUT=$(run_helper daemons/central_sender.py); RC=$?
V=$(field VERDICT "$OUT")
REASON="$(field REASON "$OUT")"
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T36 verdict NEEDS_GUARDED_RESTART" || nok "T36 verdict" "got '$V' out=[$OUT]"
echo "$REASON" | grep -i "false positive" >/dev/null && ok "T36 REASON still warns a listed daemon may be a false positive" || nok "T36 false-positive wording" "$REASON"
echo "$REASON" | grep -iE "incomplete|missing|false negative" >/dev/null && ok "T36 REASON now warns the list itself may be INCOMPLETE (false negative)" || nok "T36 incompleteness wording" "$REASON"

# ════════════════════════════════════════════════════════════════════════════
# T37 (wa-jts45): a brand-new scheduled-job *.plist committed by this deploy,
#     never installed under LAUNCH_AGENTS_DIR at all → VERDICT=JOB_NOT_INSTALLED,
#     non-zero exit, BEFORE Step 1's own "no .py/template changed" short-circuit
#     ever gets a chance to emit OK (this deploy touches ZERO *.py/template
#     files — if Step 1b did not run first, pre-fix behavior would emit
#     VERDICT=OK here). This is the exact wa-sas9j incident: merged +
#     gate:passed + "daemon fresh" were all simultaneously true while the job
#     never existed on disk for a month.
#
# Deliberately does NOT use run_helper() here: that helper's per-file loop
# APPENDS a "# changed ..." marker line to each listed path, which is fine for
# a .py/.html fixture but would corrupt a *.plist's XML (trailing garbage
# after </plist>) and end up testing the "unparseable plist" skip path
# instead of a well-formed one that simply isn't installed.
# ════════════════════════════════════════════════════════════════════════════
new_case t37
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && git commit -q -m base --allow-empty )
PRE=$(git -C "$RUNTIME" rev-parse HEAD)
make_plist "$RUNTIME/launchd" com.test.newjob "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/newjob.py"
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && \
  GIT_AUTHOR_DATE="@$POST_COMMIT_EPOCH" GIT_COMMITTER_DATE="@$POST_COMMIT_EPOCH" \
  git commit -q -m deploy )
POST=$(git -C "$RUNTIME" rev-parse HEAD)
# deliberately do NOT copy the plist into $AGENTS (LAUNCH_AGENTS_DIR) — that
# omission IS the bug this test proves gets caught.
OUT=$(MOCK_DIR="$MOCK" RUNTIME_DIR="$RUNTIME" PRE_DEPLOY_SHA="$PRE" POST_DEPLOY_SHA="$POST" \
  DEPLOY_EPOCH="$DEPLOY_EPOCH" SENSITIVE_DAEMONS="$SENSITIVE_DAEMONS" \
  EXTRA_RUNTIME_ROOTS="${EXTRA_RUNTIME_ROOTS:-}" LAUNCH_AGENTS_DIR="$AGENTS" \
  LAUNCHCTL_BIN="$BIN/launchctl" PS_BIN="$BIN/ps" VERIFY_TIMEOUT=2 VERIFY_INTERVAL=0.2 \
  DRY_RUN=0 bash "$HELPER" 2>/dev/null); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "JOB_NOT_INSTALLED" ] && ok "T37 verdict JOB_NOT_INSTALLED (plist committed, never installed)" || nok "T37 verdict" "got '$V' out=[$OUT]"
[ "$RC" -ne 0 ] && ok "T37 non-zero exit" || nok "T37 exit" "rc=$RC"
echo "$(field REASON "$OUT")" | grep "com.test.newjob" >/dev/null && ok "T37 REASON names the missing label" || nok "T37 reason" "$(field REASON "$OUT")"
[ "$(field PROOF "$OUT")" = "not_verified" ] && ok "T37 PROOF=not_verified" || nok "T37 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T38 (wa-jts45): the plist IS present under LAUNCH_AGENTS_DIR (someone copied
#     the file) but launchd never loaded it (no `launchctl load`/bootstrap run)
#     → VERDICT=JOB_NOT_INSTALLED — file-presence alone is not proof the job
#     will ever fire; launchd has to know about the label too.
# ════════════════════════════════════════════════════════════════════════════
new_case t38
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && git commit -q -m base --allow-empty )
PRE=$(git -C "$RUNTIME" rev-parse HEAD)
make_plist "$RUNTIME/launchd" com.test.copiedonly "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/copiedonly.py"
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && \
  GIT_AUTHOR_DATE="@$POST_COMMIT_EPOCH" GIT_COMMITTER_DATE="@$POST_COMMIT_EPOCH" \
  git commit -q -m deploy )
POST=$(git -C "$RUNTIME" rev-parse HEAD)
make_plist "$AGENTS" com.test.copiedonly "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/copiedonly.py"
# deliberately do NOT seed_loaded/seed_running → the mock launchctl's `list`
# reports "not found", matching a real machine where the file was copied by
# hand but never loaded.
OUT=$(MOCK_DIR="$MOCK" RUNTIME_DIR="$RUNTIME" PRE_DEPLOY_SHA="$PRE" POST_DEPLOY_SHA="$POST" \
  DEPLOY_EPOCH="$DEPLOY_EPOCH" SENSITIVE_DAEMONS="$SENSITIVE_DAEMONS" \
  EXTRA_RUNTIME_ROOTS="${EXTRA_RUNTIME_ROOTS:-}" LAUNCH_AGENTS_DIR="$AGENTS" \
  LAUNCHCTL_BIN="$BIN/launchctl" PS_BIN="$BIN/ps" VERIFY_TIMEOUT=2 VERIFY_INTERVAL=0.2 \
  DRY_RUN=0 bash "$HELPER" 2>/dev/null); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "JOB_NOT_INSTALLED" ] && ok "T38 verdict JOB_NOT_INSTALLED (plist present, not loaded)" || nok "T38 verdict" "got '$V' out=[$OUT]"
[ "$RC" -ne 0 ] && ok "T38 non-zero exit" || nok "T38 exit" "rc=$RC"
echo "$(field REASON "$OUT")" | grep "com.test.copiedonly" >/dev/null && ok "T38 REASON names the unloaded label" || nok "T38 reason" "$(field REASON "$OUT")"

# ════════════════════════════════════════════════════════════════════════════
# T39 (wa-jts45): the plist IS installed AND loaded — Step 1b must NOT flag it,
#     and must let the deploy fall through to whatever Step 1+ would otherwise
#     conclude (here: no *.py/template changed → OK/not_applicable, proving
#     Step 1b adds no false positive on a correctly-delivered scheduled job).
# ════════════════════════════════════════════════════════════════════════════
new_case t39
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && git commit -q -m base --allow-empty )
PRE=$(git -C "$RUNTIME" rev-parse HEAD)
make_plist "$RUNTIME/launchd" com.test.goodjob "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/goodjob.py"
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && \
  GIT_AUTHOR_DATE="@$POST_COMMIT_EPOCH" GIT_COMMITTER_DATE="@$POST_COMMIT_EPOCH" \
  git commit -q -m deploy )
POST=$(git -C "$RUNTIME" rev-parse HEAD)
make_plist "$AGENTS" com.test.goodjob "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/goodjob.py"
seed_loaded com.test.goodjob
OUT=$(MOCK_DIR="$MOCK" RUNTIME_DIR="$RUNTIME" PRE_DEPLOY_SHA="$PRE" POST_DEPLOY_SHA="$POST" \
  DEPLOY_EPOCH="$DEPLOY_EPOCH" SENSITIVE_DAEMONS="$SENSITIVE_DAEMONS" \
  EXTRA_RUNTIME_ROOTS="${EXTRA_RUNTIME_ROOTS:-}" LAUNCH_AGENTS_DIR="$AGENTS" \
  LAUNCHCTL_BIN="$BIN/launchctl" PS_BIN="$BIN/ps" VERIFY_TIMEOUT=2 VERIFY_INTERVAL=0.2 \
  DRY_RUN=0 bash "$HELPER" 2>/dev/null); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T39 verdict OK (installed+loaded scheduled job is not flagged)" || nok "T39 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T39 exit 0" || nok "T39 exit" "rc=$RC"

# ════════════════════════════════════════════════════════════════════════════
# T40 (wa-jts45): a plist declaring native <key>Disabled</key><true/> is
#     intentionally manual — changing it must never be flagged even though it
#     is neither installed nor loaded (that is the point of Disabled=true).
# ════════════════════════════════════════════════════════════════════════════
new_case t40
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && git commit -q -m base --allow-empty )
PRE=$(git -C "$RUNTIME" rev-parse HEAD)
mkdir -p "$RUNTIME/launchd"
cat > "$RUNTIME/launchd/com.test.manualjob.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.test.manualjob</string>
  <key>ProgramArguments</key><array><string>/usr/bin/true</string></array>
  <key>Disabled</key><true/>
</dict>
</plist>
PLIST
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && \
  GIT_AUTHOR_DATE="@$POST_COMMIT_EPOCH" GIT_COMMITTER_DATE="@$POST_COMMIT_EPOCH" \
  git commit -q -m deploy )
POST=$(git -C "$RUNTIME" rev-parse HEAD)
# deliberately NOT installed anywhere — Disabled=true must skip it regardless.
OUT=$(MOCK_DIR="$MOCK" RUNTIME_DIR="$RUNTIME" PRE_DEPLOY_SHA="$PRE" POST_DEPLOY_SHA="$POST" \
  DEPLOY_EPOCH="$DEPLOY_EPOCH" SENSITIVE_DAEMONS="$SENSITIVE_DAEMONS" \
  EXTRA_RUNTIME_ROOTS="${EXTRA_RUNTIME_ROOTS:-}" LAUNCH_AGENTS_DIR="$AGENTS" \
  LAUNCHCTL_BIN="$BIN/launchctl" PS_BIN="$BIN/ps" VERIFY_TIMEOUT=2 VERIFY_INTERVAL=0.2 \
  DRY_RUN=0 bash "$HELPER" 2>/dev/null); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T40 verdict OK (Disabled=true job never flagged)" || nok "T40 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T40 exit 0" || nok "T40 exit" "rc=$RC"

# ════════════════════════════════════════════════════════════════════════════
# T41 (gate ga-ax0t9): UM deploy que carrega os DOIS problemas ao mesmo tempo —
#     (a) um plist de job agendado que nunca foi instalado, e (b) um daemon
#     SENSITIVE existente cujo entrypoint mudou e que segue rodando codigo velho.
#
#     Antes do conserto, o Step 1b chamava emit direto, e emit ENCERRA o script:
#     o Step 2 nunca rodava. O resultado era VERDICT=JOB_NOT_INSTALLED com
#     GUARDED VAZIO — indistinguivel de "nao havia outro problema" —, e o
#     kicks.log do launchctl fake nem chegava a ser criado, prova de que a
#     checagem de obsolescencia nao aconteceu. Regressao real contra o
#     comportamento anterior: o Step 2 pegava esse caso sozinho (ver T4).
#
#     Este teste FALHA contra o codigo pre-conserto (GUARDED vem vazio) e passa
#     depois. Sem ele, nada fica vermelho se alguem voltar a encerrar no 1b.
# ════════════════════════════════════════════════════════════════════════════
new_case t41
# (b) daemon SENSITIVE ja instalado e rodando com start ANTIGO
cat > "$RUNTIME/daemons/central_sender.py" <<<'print("send v1")'
cat > "$RUNTIME/launchd/central-sender-wrapper.sh" <<EOF
#!/usr/bin/env bash
exec "\$BASEDIR/venv/bin/python3" "\$BASEDIR/daemons/central_sender.py"
EOF
make_plist "$AGENTS" com.test.central-sender /bin/bash "$RUNTIME/launchd/central-sender-wrapper.sh"
seed_running com.test.central-sender 4101 "$STALE_LSTART"
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && git commit -q -m base --allow-empty )
PRE=$(git -C "$RUNTIME" rev-parse HEAD)
# UM unico commit de deploy faz as duas coisas
cat > "$RUNTIME/daemons/central_sender.py" <<<'print("send v2")'
make_plist "$RUNTIME/launchd" com.test.newjob "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/newjob.py"
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && \
  GIT_AUTHOR_DATE="@$POST_COMMIT_EPOCH" GIT_COMMITTER_DATE="@$POST_COMMIT_EPOCH" \
  git commit -q -m deploy )
POST=$(git -C "$RUNTIME" rev-parse HEAD)
# (a) de proposito NAO copiamos com.test.newjob.plist pra $AGENTS
OUT=$(MOCK_DIR="$MOCK" RUNTIME_DIR="$RUNTIME" PRE_DEPLOY_SHA="$PRE" POST_DEPLOY_SHA="$POST" \
  DEPLOY_EPOCH="$DEPLOY_EPOCH" SENSITIVE_DAEMONS="$SENSITIVE_DAEMONS" \
  EXTRA_RUNTIME_ROOTS="${EXTRA_RUNTIME_ROOTS:-}" LAUNCH_AGENTS_DIR="$AGENTS" \
  LAUNCHCTL_BIN="$BIN/launchctl" PS_BIN="$BIN/ps" VERIFY_TIMEOUT=2 VERIFY_INTERVAL=0.2 \
  DRY_RUN=0 bash "$HELPER" 2>/dev/null); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "JOB_NOT_INSTALLED" ] && ok "T41 verdict JOB_NOT_INSTALLED (job nao instalado continua sendo o veredito)" || nok "T41 verdict" "got '$V' out=[$OUT]"
[ "$RC" -ne 0 ] && ok "T41 non-zero exit" || nok "T41 exit" "rc=$RC"
# O CORACAO DESTE TESTE: o Step 2 rodou, e o daemon obsoleto aparece.
echo "$(field GUARDED "$OUT")" | grep "com.test.central-sender" >/dev/null && ok "T41 daemon SENSITIVE obsoleto aparece em GUARDED (Step 2 rodou)" || nok "T41 guarded VAZIO — Step 2 nao rodou" "GUARDED='$(field GUARDED "$OUT")' out=[$OUT]"
R41="$(field REASON "$OUT")"
echo "$R41" | grep "com.test.newjob" >/dev/null && ok "T41 REASON nomeia o job nao instalado" || nok "T41 reason job" "$R41"
echo "$R41" | grep -i "NEEDS_GUARDED_RESTART" >/dev/null && ok "T41 REASON tambem nomeia o achado do Step 2" || nok "T41 reason step2" "$R41"
! grep -q "com.test.central-sender" "$MOCK/kicks.log" 2>/dev/null && ok "T41 daemon sensivel NAO foi bouncado" || nok "T41 no-bounce" "kickstart: $(cat "$MOCK/kicks.log" 2>/dev/null)"
[ "$(field PROOF "$OUT")" = "not_verified" ] && ok "T41 PROOF=not_verified (nada foi verificado)" || nok "T41 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T42 (gate ga-3khhu): a deploy that (a) makes a purely cosmetic edit to an
#     already-installed+loaded+LIVE SAFE daemon's plist (its .py never
#     changes), (b) separately ships a genuinely-broken never-installed
#     scheduled-job plist, and (c) touches an unrelated .py file (so the "no
#     python/template changed" short-circuit above doesn't pre-empt Step 2-4,
#     the same reason T41 needed one).
#
#     Pre-fix, AFFECTED="$SJ_CHECKED" swept EVERY plist label this deploy
#     touched into AFFECTED — fine ones included — and Step 4's kickstart loop
#     walks every AFFECTED label. Reproduced live against 40b5e9b7: the FINE,
#     unrelated, live daemon (com.test.safeexisting) got swept in and actually
#     kickstarted — a real unwanted production restart of a daemon with zero
#     code change and zero installation problem, exactly the side effect the
#     SENSITIVE_DAEMONS/guard/drain machinery exists to prevent, reachable
#     through a different door. Same root cause also self-contradicted the
#     log: "installed+loaded:$SJ_CHECKED" could (and did) name a label the
#     line directly above it had just reported MISSING.
#
#     This test FAILS against the pre-fix code (com.test.safeexisting shows up
#     in kicks.log) and passes after.
# ════════════════════════════════════════════════════════════════════════════
new_case t42
# (a) SAFE daemon, already correctly delivered: plist exists in $AGENTS,
# loaded+live, and its OWN .py never changes this deploy.
cat > "$RUNTIME/daemons/safeexisting.py" <<<'print("nothing changed here")'
make_plist "$RUNTIME/launchd" com.test.safeexisting "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/safeexisting.py"
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && git commit -q -m base --allow-empty )
PRE=$(git -C "$RUNTIME" rev-parse HEAD)
make_plist "$AGENTS" com.test.safeexisting "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/safeexisting.py"
seed_running com.test.safeexisting 4201 "$STALE_LSTART"
# ONE deploy commit does all three things at once:
# (a) cosmetic edit to safeexisting's plist — Label/entrypoint unchanged
make_plist "$RUNTIME/launchd" com.test.safeexisting "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/safeexisting.py" --cosmetic-flag
# (b) a genuinely never-installed scheduled job
make_plist "$RUNTIME/launchd" com.test.newjob "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/newjob.py"
# (c) unrelated .py, mapping to no daemon, just to clear the short-circuit
cat > "$RUNTIME/daemons/unrelated_util.py" <<<'print("unrelated")'
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && \
  GIT_AUTHOR_DATE="@$POST_COMMIT_EPOCH" GIT_COMMITTER_DATE="@$POST_COMMIT_EPOCH" \
  git commit -q -m deploy )
POST=$(git -C "$RUNTIME" rev-parse HEAD)
# (b) de proposito NAO copiamos com.test.newjob.plist pra $AGENTS
OUT=$(MOCK_DIR="$MOCK" RUNTIME_DIR="$RUNTIME" PRE_DEPLOY_SHA="$PRE" POST_DEPLOY_SHA="$POST" \
  DEPLOY_EPOCH="$DEPLOY_EPOCH" SENSITIVE_DAEMONS="$SENSITIVE_DAEMONS" \
  EXTRA_RUNTIME_ROOTS="${EXTRA_RUNTIME_ROOTS:-}" LAUNCH_AGENTS_DIR="$AGENTS" \
  LAUNCHCTL_BIN="$BIN/launchctl" PS_BIN="$BIN/ps" VERIFY_TIMEOUT=2 VERIFY_INTERVAL=0.2 \
  DRY_RUN=0 bash "$HELPER" 2>"$MOCK/stderr.log"); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "JOB_NOT_INSTALLED" ] && ok "T42 verdict JOB_NOT_INSTALLED (job nao instalado continua sendo o veredito)" || nok "T42 verdict" "got '$V' out=[$OUT]"
[ "$RC" -ne 0 ] && ok "T42 non-zero exit" || nok "T42 exit" "rc=$RC"
# O CORACAO DESTE TESTE: o daemon fino (zero mudanca de codigo, zero problema
# de instalacao) nunca foi kickstartado.
! grep -q "com.test.safeexisting" "$MOCK/kicks.log" 2>/dev/null && ok "T42 daemon SAFE ja-fino NAO foi kickstartado" || nok "T42 kickstart indevido" "kickstart: $(cat "$MOCK/kicks.log" 2>/dev/null)"
! echo "$(field AFFECTED "$OUT")" | grep "com.test.safeexisting" >/dev/null && ok "T42 AFFECTED exclui o daemon fino" || nok "T42 AFFECTED nao deveria conter o daemon fino" "AFFECTED=$(field AFFECTED "$OUT")"
R42="$(field REASON "$OUT")"
echo "$R42" | grep "com.test.newjob" >/dev/null && ok "T42 REASON nomeia o job nao instalado" || nok "T42 reason job" "$R42"
# O log nao pode se autocontradizer: newjob (MISSING) nao pode aparecer na
# linha "installed+loaded".
! grep "installed+loaded" "$MOCK/stderr.log" 2>/dev/null | grep "com.test.newjob" >/dev/null && ok "T42 log nao se autocontradiz sobre newjob" || nok "T42 log autocontraditorio: newjob aparece como installed+loaded" "$(grep 'installed+loaded' "$MOCK/stderr.log" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# T43 (ga-pntex): daemon_imports_stem()'s python3 call count must not scale
#     with N (daemons) x M (changed .py stems). Pre-fix, Step 3 re-invokes a
#     fresh python3 ast.parse of the SAME entrypoint file once per candidate
#     stem — for N daemons whose entrypoints import nothing relevant, M
#     changed files cost N*M spawns. Measured live: a 33min citywide gate
#     stall, ~1-2 daemons/min, ~1% CPU throughout — the cost is process-spawn
#     overhead, not computation (ga-pntex).
#
#     Proof shape: run the SAME 3-daemon fixture twice — once with 2 changed
#     stems, once with 10 — via a python3 call-counting shim on PATH (records
#     one line per invocation, then execs the real interpreter, so the
#     helper's actual behavior/output is untouched). Post-fix, cost depends
#     only on the number of UNIQUE files needing an import-stem extraction
#     (3 entrypoints, cached), never on how many stems each gets checked
#     against — so the two counts must be EXACTLY equal. Pre-fix they are not
#     (3+3*2=9 vs. 3+3*10=33 calls): this test FAILS against the pre-fix code
#     and PASSES after.
# ════════════════════════════════════════════════════════════════════════════
new_case t43
for d in dA dB dC; do
  cat > "$RUNTIME/daemons/${d}.py" <<PY
print("$d daemon — imports nothing relevant to this test")
PY
  make_plist "$RUNTIME/launchd" "com.test.$d" "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/${d}.py"
done
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && git commit -q -m base --allow-empty )
for d in dA dB dC; do
  make_plist "$AGENTS" "com.test.$d" "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/${d}.py"
done

# python3 call-counting shim: append one line per invocation to $PY_CALL_LOG,
# then exec the real interpreter — daemon-refresh.sh's behavior/output is
# completely unaffected, only the CALL COUNT is observed.
REAL_PYTHON3="$(command -v python3)"
mkdir -p "$BIN/countpy"
cat > "$BIN/countpy/python3" <<COUNTEOF
#!/usr/bin/env bash
echo x >> "\$PY_CALL_LOG"
exec "$REAL_PYTHON3" "\$@"
COUNTEOF
chmod +x "$BIN/countpy/python3"

count_py_calls() {  # count_py_calls <changed-relpaths...> -> prints call count
  : > "$MOCK/py_calls.log"
  ( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && git commit -q -m base --allow-empty )
  local pre post f
  pre=$(git -C "$RUNTIME" rev-parse HEAD)
  for f in "$@"; do
    mkdir -p "$RUNTIME/$(dirname "$f")"
    echo "# changed $(date +%s%N)" >> "$RUNTIME/$f"
  done
  ( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && \
    GIT_AUTHOR_DATE="@$POST_COMMIT_EPOCH" GIT_COMMITTER_DATE="@$POST_COMMIT_EPOCH" \
    git commit -q -m deploy --allow-empty )
  post=$(git -C "$RUNTIME" rev-parse HEAD)
  PATH="$BIN/countpy:$PATH" \
  PY_CALL_LOG="$MOCK/py_calls.log" \
  MOCK_DIR="$MOCK" RUNTIME_DIR="$RUNTIME" PRE_DEPLOY_SHA="$pre" POST_DEPLOY_SHA="$post" \
  DEPLOY_EPOCH="$DEPLOY_EPOCH" SENSITIVE_DAEMONS="$SENSITIVE_DAEMONS" \
  EXTRA_RUNTIME_ROOTS="${EXTRA_RUNTIME_ROOTS:-}" LAUNCH_AGENTS_DIR="$AGENTS" \
  LAUNCHCTL_BIN="$BIN/launchctl" PS_BIN="$BIN/ps" VERIFY_TIMEOUT=2 VERIFY_INTERVAL=0.2 \
  DRY_RUN=0 bash "$HELPER" >/dev/null 2>&1
  wc -l < "$MOCK/py_calls.log" | tr -d ' '
}

COUNT_SMALL=$(count_py_calls lib/aux01.py lib/aux02.py)
COUNT_LARGE=$(count_py_calls lib/aux03.py lib/aux04.py lib/aux05.py lib/aux06.py lib/aux07.py lib/aux08.py lib/aux09.py lib/aux10.py lib/aux11.py lib/aux12.py)
[ "$COUNT_SMALL" -eq "$COUNT_LARGE" ] && ok "T43 python3 call count does not grow with the number of changed stems (2 changed: $COUNT_SMALL calls, 10 changed: $COUNT_LARGE calls)" || nok "T43 python3 call count scales with changed-file count (N*M spawn storm, ga-pntex)" "2 changed files -> $COUNT_SMALL python3 calls; 10 changed files -> $COUNT_LARGE calls (must be equal — cost must depend on unique files touched, not on how many stems each is checked against)"

# ════════════════════════════════════════════════════════════════════════════
# T44 (ga-pntex): a changed tests/**/docs/** file must never contribute its
#     own basename as a candidate "stem" for the import-level check — same
#     universal claim DEFAULT_NO_RESTART_PATTERNS already established above
#     for the whole-changeset short-circuit (point 9/ga-dk7fw: "no daemon on
#     any rig imports a test or doc file"), applied per-file here.
#
#     This is not just a perf nit: pre-fix, a changed tests/*.py file whose
#     BASENAME happens to collide with a real module name some daemon
#     genuinely imports produces a false-positive AFFECTED — flagging (and
#     for a SENSITIVE daemon, holding the gate on) a daemon nothing about
#     this deploy actually touched. Fixture: com.test.dashboard's entrypoint
#     imports a real lib/shared_helper.py. This deploy changes ONLY
#     tests/shared_helper.py (unrelated content, same basename) —
#     lib/shared_helper.py itself never changes. com.test.dashboard must NOT
#     be flagged AFFECTED.
# ════════════════════════════════════════════════════════════════════════════
new_case t44
mkdir -p "$RUNTIME/lib" "$RUNTIME/lib2" "$RUNTIME/tests"
cat > "$RUNTIME/lib/shared_helper.py" <<<'X = 1'
cat > "$RUNTIME/daemons/dashboard.py" <<'PY'
from lib import shared_helper
PY
make_plist "$RUNTIME/launchd" com.test.dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/dashboard.py"
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && git commit -q -m base --allow-empty )
PRE=$(git -C "$RUNTIME" rev-parse HEAD)
make_plist "$AGENTS" com.test.dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/dashboard.py"
# a same-named TEST file changes (lib/shared_helper.py itself is untouched)
# PLUS an unrelated real file, so this is a MIXED changeset — an all-tests
# changeset would exit early via the whole-changeset short-circuit above for
# an unrelated reason and would prove nothing about the per-file check below
# (same reason T30/T42 needed a mixed changeset too).
echo "# unrelated test edit" >> "$RUNTIME/tests/shared_helper.py"
cat > "$RUNTIME/lib2/unrelated_util.py" <<<'print("unrelated")'
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && \
  GIT_AUTHOR_DATE="@$POST_COMMIT_EPOCH" GIT_COMMITTER_DATE="@$POST_COMMIT_EPOCH" \
  git commit -q -m deploy )
POST=$(git -C "$RUNTIME" rev-parse HEAD)
OUT=$(MOCK_DIR="$MOCK" RUNTIME_DIR="$RUNTIME" PRE_DEPLOY_SHA="$PRE" POST_DEPLOY_SHA="$POST" \
  DEPLOY_EPOCH="$DEPLOY_EPOCH" SENSITIVE_DAEMONS="$SENSITIVE_DAEMONS" \
  EXTRA_RUNTIME_ROOTS="${EXTRA_RUNTIME_ROOTS:-}" LAUNCH_AGENTS_DIR="$AGENTS" \
  LAUNCHCTL_BIN="$BIN/launchctl" PS_BIN="$BIN/ps" VERIFY_TIMEOUT=2 VERIFY_INTERVAL=0.2 \
  DRY_RUN=0 bash "$HELPER" 2>/dev/null); RC=$?
AFF44=$(field AFFECTED "$OUT")
case " $AFF44 " in
  *" com.test.dashboard "*) nok "T44 tests/-path basename collision must not flag an unrelated daemon" "AFFECTED=[$AFF44] — changed tests/shared_helper.py (lib/shared_helper.py itself never changed) must never make daemon-refresh.sh treat com.test.dashboard as affected" ;;
  *) ok "T44 changed tests/-path file's basename never becomes a checkable stem (com.test.dashboard correctly NOT flagged)" ;;
esac


# ════════════════════════════════════════════════════════════════════════════
# T45 (ga-9ps272, wa-p7g7g): the exact reported production shape — CLAUDE.md +
# 2 docs/*.md (all three covered by DEFAULT_NO_RESTART_PATTERNS) PLUS a NEW
# standalone scripts/*.sh (uncovered — not tests/**, docs/**, nor *.md, and
# not a .py/template either) PLUS a NEW tests/*.py, zero real lib/daemons
# code touched. Pre-fix this measured VERDICT=OK/PROOF=not_verified (Step 3's
# generic "touches no live daemon" fallback, NOT a false AFFECTED/GUARDED —
# confirmed directly against the pre-fix script before writing this test, same
# discipline as T28's own comment). The observable delta is PROOF/REASON, but
# it is not cosmetic: story-delivery.sh/quality-gate-dispatcher.sh treat any
# PROOF other than verified/not_applicable/asset_served_per_request as
# "daemon liveness not verified" and label the delivery delivery:daemon-
# unverified — live, actionable-looking noise on a delivery with zero daemon
# relevance, the uncovered .sh companion being the only reason gate 1
# (point 9/ga-dk7fw, T28/T29) didn't already resolve this the same way.
# ════════════════════════════════════════════════════════════════════════════
SENSITIVE_DAEMONS="campaign central-sender webhook"
new_case t45
cat > "$RUNTIME/daemons/campaign_scheduler.py" <<<'def run(): pass'
cat > "$RUNTIME/daemons/central_sender.py" <<<'def send(): pass'
cat > "$RUNTIME/daemons/webhook_listener.py" <<<'def listen(): pass'
make_plist "$AGENTS" com.test.campaign-scheduler "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/campaign_scheduler.py"
make_plist "$AGENTS" com.test.central-sender "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/central_sender.py"
make_plist "$AGENTS" com.test.webhook-listener "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/webhook_listener.py"
seed_running com.test.campaign-scheduler 9901 "$STALE_LSTART"
seed_running com.test.central-sender 9902 "$STALE_LSTART"
seed_running com.test.webhook-listener 9903 "$STALE_LSTART"
OUT=$(run_helper CLAUDE.md docs/a.md docs/b.md scripts/restart_demand_dashboard_guarded.sh tests/test_restart_demand_dashboard_guarded.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T45 verdict OK" || nok "T45 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T45 exit 0" || nok "T45 exit" "rc=$RC"
[ -z "$(field AFFECTED "$OUT")" ] && ok "T45 no daemon marked AFFECTED" || nok "T45 affected" "$(field AFFECTED "$OUT")"
[ -z "$(field GUARDED "$OUT")" ] && ok "T45 no daemon GUARDED" || nok "T45 guarded" "$(field GUARDED "$OUT")"
[ ! -f "$MOCK/kicks.log" ] && ok "T45 no kickstart called" || nok "T45 kickstart" "called: $(cat "$MOCK/kicks.log" 2>/dev/null)"
[ "$(field PROOF "$OUT")" = "not_applicable" ] && ok "T45 PROOF=not_applicable (the actual fix — was not_verified pre-fix, which trips delivery:daemon-unverified downstream)" || nok "T45 proof" "got '$(field PROOF "$OUT")', want not_applicable"
echo "$(field REASON "$OUT")" | grep -i "excluding tests/docs/md" >/dev/null && ok "T45 REASON names the excluded structurally-inert python" || nok "T45 reason" "$(field REASON "$OUT")"
# ════════════════════════════════════════════════════════════════════════════
# T46 (ga-9lsuq0, header point 14): a bare-name stem COLLISION between two
# UNRELATED real modules that share a basename in different directories must
# NOT flag a daemon that imports only ONE of them, when deploy_deps.json
# covers its entrypoint — the exact false-positive class daemon_imports_stem()
# cannot see (it extracts bare identifiers with no path resolution: `from lib
# import helpers` makes "helpers" a checkable stem regardless of which file
# on disk that name actually resolves to). Fixture: dashboard.py imports
# ONLY lib/helpers.py; this deploy changes ONLY the unrelated, same-named
# daemons/routes/helpers.py — lib/helpers.py itself never changes.
# ════════════════════════════════════════════════════════════════════════════
new_case t46
mkdir -p "$RUNTIME/lib" "$RUNTIME/daemons/routes"
cat > "$RUNTIME/lib/helpers.py" <<<'def real(): return 1'
cat > "$RUNTIME/daemons/routes/helpers.py" <<<'def unrelated(): return 2'
cat > "$RUNTIME/daemons/dashboard.py" <<'PYEOF'
from lib import helpers
def index():
    return helpers.real()
PYEOF
cat > "$RUNTIME/daemons/deploy_deps.json" <<'JSONEOF'
{
  "_generated_by": "scripts/gen_daemon_deps.py",
  "daemons": {
    "daemons/dashboard.py": {
      "label": "com.test.dashboard",
      "closure": ["daemons/dashboard.py", "lib/helpers.py"]
    }
  }
}
JSONEOF
make_plist "$AGENTS" com.test.dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/dashboard.py"
seed_running com.test.dashboard 10001 "$STALE_LSTART"
OUT=$(run_helper daemons/routes/helpers.py); RC=$?
V=$(field VERDICT "$OUT")
echo "$(field AFFECTED "$OUT")" | grep "com.test.dashboard" >/dev/null && nok "T46 bare-name collision must not flag when deploy_deps.json's real closure clears it" "AFFECTED=[$(field AFFECTED "$OUT")] — dashboard.py's closure names lib/helpers.py only, never daemons/routes/helpers.py" || ok "T46 deploy_deps.json closure correctly rejects the unrelated same-named file"
[ "$V" = "OK" ] && ok "T46 verdict OK (no false-positive restart)" || nok "T46 verdict" "got '$V' out=[$OUT]"
[ ! -f "$MOCK/kicks.log" ] && ok "T46 no kickstart called" || nok "T46 kickstart" "called: $(cat "$MOCK/kicks.log" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# T47 (ga-9lsuq0, header point 14): a real dependency reached through a lib-
# to-lib import chain (entrypoint → lib/a.py → lib/b.py) is invisible to the
# ad-hoc scan — daemon_imports_stem_via_routes()'s one extra hop is scoped
# ONLY to <entrypoint-dir>/routes/*.py (ga-q617u), so a plain lib/*.py chain
# gets none of it: a genuine false negative, structurally identical to the
# ga-q617u incident this fix generalizes past its one routes-shaped hop.
# deploy_deps.json's real recursive closure (gen_daemon_deps.py's closure())
# catches it directly.
# ════════════════════════════════════════════════════════════════════════════
new_case t47
mkdir -p "$RUNTIME/lib"
cat > "$RUNTIME/lib/b.py" <<<'def deep(): return 3'
cat > "$RUNTIME/lib/a.py" <<'PYEOF'
from lib import b
def mid():
    return b.deep()
PYEOF
cat > "$RUNTIME/daemons/dashboard2.py" <<'PYEOF'
from lib import a
def index():
    return a.mid()
PYEOF
cat > "$RUNTIME/daemons/deploy_deps.json" <<'JSONEOF'
{
  "_generated_by": "scripts/gen_daemon_deps.py",
  "daemons": {
    "daemons/dashboard2.py": {
      "label": "com.test.dashboard2",
      "closure": ["daemons/dashboard2.py", "lib/a.py", "lib/b.py"]
    }
  }
}
JSONEOF
make_plist "$AGENTS" com.test.dashboard2 "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/dashboard2.py"
seed_running com.test.dashboard2 10101 "$STALE_LSTART"
seed_restart com.test.dashboard2 10199 "$FRESH_LSTART"
# deploy changes ONLY lib/b.py — 2 hops from the entrypoint through a plain
# lib/*.py chain (not a routes/*.py hop) — invisible without deploy_deps.json
OUT=$(run_helper lib/b.py); RC=$?
V=$(field VERDICT "$OUT")
echo "$(field AFFECTED "$OUT")" | grep "com.test.dashboard2" >/dev/null && ok "T47 deep lib-to-lib dependency caught via deploy_deps.json's real recursive closure" || nok "T47 affected" "$(field AFFECTED "$OUT")"
[ "$V" = "OK" ] && ok "T47 verdict OK after fresh restart" || nok "T47 verdict" "got '$V' out=[$OUT]"
grep -q "com.test.dashboard2" "$MOCK/kicks.log" 2>/dev/null && ok "T47 kickstart invoked" || nok "T47 kickstart" "log: $(cat "$MOCK/kicks.log" 2>/dev/null)"
[ "$(field PROOF "$OUT")" = "verified" ] && ok "T47 PROOF=verified" || nok "T47 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T48 (ga-9lsuq0, header point 14): deploy_deps.json EXISTS but is not valid
# JSON → WARN logged, every entrypoint falls back to the existing ad-hoc scan
# for this run — fail-SOFT, never a hard script failure, and never silently
# treated as "nothing to restart" either. Reuses T46's exact collision
# fixture: proves the fallback is REAL (still produces T46's pre-fix false
# positive here), not merely a no-op that happens to also pass.
# ════════════════════════════════════════════════════════════════════════════
new_case t48
mkdir -p "$RUNTIME/lib" "$RUNTIME/daemons/routes"
cat > "$RUNTIME/lib/helpers.py" <<<'def real(): return 1'
cat > "$RUNTIME/daemons/routes/helpers.py" <<<'def unrelated(): return 2'
cat > "$RUNTIME/daemons/dashboard.py" <<'PYEOF'
from lib import helpers
def index():
    return helpers.real()
PYEOF
echo '{not valid json' > "$RUNTIME/daemons/deploy_deps.json"
make_plist "$AGENTS" com.test.dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/dashboard.py"
seed_running com.test.dashboard 10201 "$STALE_LSTART"
OUT=$(run_helper_stderr daemons/routes/helpers.py); RC=$?
echo "$OUT" | grep -i "could not be read" >/dev/null && ok "T48 WARN logged for unparseable deploy_deps.json" || nok "T48 warn" "$OUT"
echo "$(field AFFECTED "$OUT")" | grep "com.test.dashboard" >/dev/null && ok "T48 falls back to the ad-hoc scan (same collision as T46, now unprotected — proves fail-SOFT, not a silent no-op)" || nok "T48 affected" "$(field AFFECTED "$OUT")"

# ════════════════════════════════════════════════════════════════════════════
# T49 (ga-9lsuq0, header point 14): a daemon whose entrypoint deploy_deps.json
# does NOT mention (e.g. added after the last gen_daemon_deps.py run) must
# still get the FULL ad-hoc scan — deploy_deps.json's presence is per-
# entrypoint opt-in, never a blanket switch that starves an uncovered
# daemon of the only check it had. Reuses T5's exact routes-import fixture,
# with an unrelated, non-covering deploy_deps.json present alongside it.
# ════════════════════════════════════════════════════════════════════════════
new_case t49
cat > "$RUNTIME/routes/channel_admin_api.py" <<<'def register(app): pass'
cat > "$RUNTIME/daemons/ban_risk_dashboard.py" <<'PYEOF'
from routes.channel_admin_api import register
register(None)
PYEOF
cat > "$RUNTIME/daemons/deploy_deps.json" <<'JSONEOF'
{
  "_generated_by": "scripts/gen_daemon_deps.py",
  "daemons": {
    "daemons/some_other_dashboard.py": {
      "label": "com.test.some-other",
      "closure": ["daemons/some_other_dashboard.py"]
    }
  }
}
JSONEOF
make_plist "$AGENTS" com.test.ban-risk-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/ban_risk_dashboard.py"
seed_running com.test.ban-risk-dashboard 10301 "$STALE_LSTART"
seed_restart com.test.ban-risk-dashboard 10399 "$FRESH_LSTART"
OUT=$(run_helper routes/channel_admin_api.py); RC=$?
V=$(field VERDICT "$OUT")
echo "$(field AFFECTED "$OUT")" | grep "com.test.ban-risk-dashboard" >/dev/null && ok "T49 uncovered daemon still caught by the existing ad-hoc scan (deploy_deps.json presence never starves an entrypoint it doesn't mention)" || nok "T49 affected" "$(field AFFECTED "$OUT")"
[ "$V" = "OK" ] && ok "T49 verdict OK after fresh restart" || nok "T49 verdict" "got '$V' out=[$OUT]"
[ "$(field PROOF "$OUT")" = "verified" ] && ok "T49 PROOF=verified" || nok "T49 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T50 (ga-fzfqsu): a daemon launched via `python -m <module>` (no .py anywhere
# in ProgramArguments — e.g. `flask run`, which resolves its app via FLASK_APP/
# an env var, not an argv token) is invisible to Step 2 discovery pre-fix: no
# arg ends in .py or .sh, so DAEMON_LABELS never includes it and the whole scan
# short-circuits to "no rig daemons discovered" before Step 3/4 ever run —
# exactly the real br.urblink.lexbh incident (`python -m flask run --port
# 7842`, dashboard/app.py changed, the live process never refreshed by the
# automated bug/task gate-PASS deploy path). Proves two things together,
# matching how quality-gate-dispatcher.sh actually drives this post-fix: (a) a
# plist whose WorkingDirectory falls under RUNTIME_DIR is discovered as a rig
# daemon even with zero resolvable .py entrypoint, and (b) FORCE_RESTART_LABELS
# (the daemon_restarts static-override list from delivery-runbooks.toml,
# threaded through by the caller) forces it into AFFECTED regardless of
# whether ad-hoc entrypoint matching could ever have found it — so it is both
# restarted AND its freshness is genuinely verified (PROOF=verified), not just
# blindly kicked and forgotten.
# ════════════════════════════════════════════════════════════════════════════
new_case t50
mkdir -p "$RUNTIME/dashboard"
cat > "$RUNTIME/dashboard/app.py" <<<'print("lexbh dashboard")'
cat > "$AGENTS/com.test.lexbh-dashboard.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.test.lexbh-dashboard</string>
  <key>ProgramArguments</key>
  <array>
    <string>$RUNTIME/.venv/bin/python</string>
    <string>-m</string>
    <string>flask</string>
    <string>run</string>
    <string>--port</string>
    <string>7842</string>
  </array>
  <key>WorkingDirectory</key><string>$RUNTIME</string>
</dict>
</plist>
EOF
seed_running com.test.lexbh-dashboard 20001 "$STALE_LSTART"
seed_restart com.test.lexbh-dashboard 20099 "$FRESH_LSTART"
FORCE_RESTART_LABELS="com.test.lexbh-dashboard"
OUT=$(run_helper dashboard/app.py); RC=$?
FORCE_RESTART_LABELS=""
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T50 verdict OK" || nok "T50 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T50 exit 0" || nok "T50 exit" "rc=$RC"
echo "$(field AFFECTED "$OUT")" | grep "com.test.lexbh-dashboard" >/dev/null && ok "T50 python-m daemon forced into AFFECTED via daemon_restarts override" || nok "T50 affected" "$(field AFFECTED "$OUT")"
echo "$(field RESTARTED "$OUT")" | grep "com.test.lexbh-dashboard" >/dev/null && ok "T50 python-m daemon restarted" || nok "T50 restarted" "$(field RESTARTED "$OUT")"
grep -q "com.test.lexbh-dashboard" "$MOCK/kicks.log" 2>/dev/null && ok "T50 kickstart invoked" || nok "T50 kickstart" "log: $(cat "$MOCK/kicks.log" 2>/dev/null)"
[ "$(field PROOF "$OUT")" = "verified" ] && ok "T50 PROOF=verified (real restart+fresh confirmed, not a blind fire-and-forget kick)" || nok "T50 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T51 (ga-9lug2k): deploy_deps.json covers EVERY entrypoint this run discovers
# (the fixture's one daemon), and the flagged daemon's affected=1 came from
# that real recursive closure, not the ad-hoc scan. The NEEDS_GUARDED_RESTART
# REASON must say coverage is complete for this run (no "verify by hand / may
# be incomplete") while still naming the two risks that survive JSON coverage
# regardless: the JSON itself going stale, and template/asset reachability,
# which deploy_deps.json's closure never tracks (header point 14).
# ════════════════════════════════════════════════════════════════════════════
new_case t51
cat > "$RUNTIME/daemons/central_sender.py" <<<'print("send")'
cat > "$RUNTIME/daemons/deploy_deps.json" <<'JSONEOF'
{
  "_generated_by": "scripts/gen_daemon_deps.py",
  "daemons": {
    "daemons/central_sender.py": {
      "label": "com.test.central-sender",
      "closure": ["daemons/central_sender.py"]
    }
  }
}
JSONEOF
make_plist "$AGENTS" com.test.central-sender "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/central_sender.py"
seed_running com.test.central-sender 5101 "$STALE_LSTART"
OUT=$(run_helper daemons/central_sender.py); RC=$?
V=$(field VERDICT "$OUT")
REASON="$(field REASON "$OUT")"
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T51 verdict NEEDS_GUARDED_RESTART" || nok "T51 verdict" "got '$V' out=[$OUT]"
echo "$REASON" | grep -i "real recursive closure" >/dev/null && ok "T51 REASON asserts full-closure coverage (deploy_deps.json 1/1)" || nok "T51 full-closure wording" "$REASON"
echo "$REASON" | grep -i "does NOT apply here" >/dev/null && ok "T51 REASON retires the false-negative caveat for this run" || nok "T51 retired caveat" "$REASON"
echo "$REASON" | grep -i "template" >/dev/null && ok "T51 REASON still names template/asset reachability as a residual risk" || nok "T51 template caveat kept" "$REASON"
echo "$REASON" | grep -i "stale" >/dev/null && ok "T51 REASON still names JSON staleness as a residual risk" || nok "T51 staleness caveat kept" "$REASON"

# ════════════════════════════════════════════════════════════════════════════
# T52 (ga-9lug2k): control — deploy_deps.json exists but does NOT cover every
# entrypoint this run discovers (a second declared daemon it never mentions)
# → coverage is partial (1/2), so the REASON must keep the ORIGINAL
# conservative wording (verify by hand / may be incomplete), never T51's
# full-closure claim. Proves T51's assertion is earned per-run from the real
# coverage count, not triggered merely by deploy_deps.json existing.
# ════════════════════════════════════════════════════════════════════════════
new_case t52
cat > "$RUNTIME/daemons/central_sender.py" <<<'print("send")'
cat > "$RUNTIME/daemons/ban_risk_dashboard.py" <<<'print("dash")'
cat > "$RUNTIME/daemons/deploy_deps.json" <<'JSONEOF'
{
  "_generated_by": "scripts/gen_daemon_deps.py",
  "daemons": {
    "daemons/central_sender.py": {
      "label": "com.test.central-sender",
      "closure": ["daemons/central_sender.py"]
    }
  }
}
JSONEOF
make_plist "$AGENTS" com.test.central-sender "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/central_sender.py"
make_plist "$AGENTS" com.test.ban-risk-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/ban_risk_dashboard.py"
seed_running com.test.central-sender 5201 "$STALE_LSTART"
seed_running com.test.ban-risk-dashboard 5202 "$STALE_LSTART"
OUT=$(run_helper daemons/central_sender.py); RC=$?
V=$(field VERDICT "$OUT")
REASON="$(field REASON "$OUT")"
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T52 verdict NEEDS_GUARDED_RESTART" || nok "T52 verdict" "got '$V' out=[$OUT]"
echo "$REASON" | grep -i "verify by hand" >/dev/null && ok "T52 REASON keeps the conservative wording (coverage is partial: 1/2 entrypoints)" || nok "T52 conservative wording kept" "$REASON"
! echo "$REASON" | grep -i "does NOT apply here" >/dev/null && ok "T52 REASON does NOT claim full-closure coverage" || nok "T52 wrongly claimed full closure" "$REASON"

# ════════════════════════════════════════════════════════════════════════════
# T53 (ga-0fawwr): per-daemon baseline narrowing. Simulates the reported
# incident directly: the RIG-WIDE PRE_DEPLOY_SHA a caller feeds this script is
# frozen at C0 (some OTHER, unmodeled daemon on the same rig is still stuck
# GUARDED, so the caller's own shared marker never advanced past it) — but
# com.test.bigclosure's OWN last-individually-clean point is C1 (a PREVIOUS
# cycle already resolved the one real change to its closure, lib/shared.py,
# and the caller recorded that as this label's DAEMON_BASELINE_OVERRIDES
# entry). Nothing in bigclosure's closure changes again between C1 and C2
# (POST) — only a DIFFERENT daemon's own dependency (lib/otherlib.py) does.
# Pre-fix (or with the override ignored), bigclosure would be flagged
# AFFECTED on every cycle regardless, purely because the wide C0..C2 window
# still contains the OLD lib/shared.py change — exactly the "restart quase
# todo ciclo" measured live in the bug report. Proves both halves together:
# the false positive is suppressed AND a real one (otherdaemon — no override
# yet, so it is evaluated against the wide window exactly like before this
# fix) is not accidentally swept away with it.
# ════════════════════════════════════════════════════════════════════════════
new_case t53
mkdir -p "$RUNTIME/lib"
cat > "$RUNTIME/lib/shared.py" <<<'def v(): return 1'
cat > "$RUNTIME/lib/otherlib.py" <<<'def v(): return 1'
cat > "$RUNTIME/daemons/bigclosure.py" <<'PYEOF'
from lib import shared
def index():
    return shared.v()
PYEOF
cat > "$RUNTIME/daemons/otherdaemon.py" <<'PYEOF'
from lib import otherlib
def run():
    return otherlib.v()
PYEOF
cat > "$RUNTIME/daemons/deploy_deps.json" <<'JSONEOF'
{
  "_generated_by": "scripts/gen_daemon_deps.py",
  "daemons": {
    "daemons/bigclosure.py": {
      "label": "com.test.bigclosure",
      "closure": ["daemons/bigclosure.py", "lib/shared.py"]
    }
  }
}
JSONEOF
make_plist "$AGENTS" com.test.bigclosure "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/bigclosure.py"
make_plist "$AGENTS" com.test.otherdaemon "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/otherdaemon.py"
seed_running com.test.bigclosure 30001 "$STALE_LSTART"
seed_running com.test.otherdaemon 30002 "$STALE_LSTART"
seed_restart com.test.otherdaemon 30099 "$FRESH_LSTART"

( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && git commit -q -m t53-base --allow-empty )
SHA_C0=$(git -C "$RUNTIME" rev-parse HEAD)
echo "def v(): return 2" > "$RUNTIME/lib/shared.py"
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && git commit -q -m t53-c1 --allow-empty )
SHA_C1=$(git -C "$RUNTIME" rev-parse HEAD)
echo "def v(): return 2" > "$RUNTIME/lib/otherlib.py"
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && GIT_AUTHOR_DATE="@$POST_COMMIT_EPOCH" GIT_COMMITTER_DATE="@$POST_COMMIT_EPOCH" git commit -q -m t53-c2 --allow-empty )
SHA_C2=$(git -C "$RUNTIME" rev-parse HEAD)

OUT=$(MOCK_DIR="$MOCK" RUNTIME_DIR="$RUNTIME" \
  PRE_DEPLOY_SHA="$SHA_C0" POST_DEPLOY_SHA="$SHA_C2" \
  DEPLOY_EPOCH="$DEPLOY_EPOCH" SENSITIVE_DAEMONS="" EXTRA_RUNTIME_ROOTS="" \
  FORCE_RESTART_LABELS="" \
  DAEMON_BASELINE_OVERRIDES="com.test.bigclosure $SHA_C1" \
  LAUNCH_AGENTS_DIR="$AGENTS" LAUNCHCTL_BIN="$BIN/launchctl" PS_BIN="$BIN/ps" \
  VERIFY_TIMEOUT=2 VERIFY_INTERVAL=0.2 DRY_RUN=0 \
  bash "$HELPER" 2>/dev/null); RC=$?
echo "$(field AFFECTED "$OUT")" | grep "com.test.bigclosure" >/dev/null \
  && nok "T53 bigclosure must be downgraded out of AFFECTED (its own closure is clean since its override point C1)" "AFFECTED=[$(field AFFECTED "$OUT")]" \
  || ok "T53 bigclosure downgraded out of AFFECTED via its per-daemon override"
echo "$(field AFFECTED "$OUT")" | grep "com.test.otherdaemon" >/dev/null \
  && ok "T53 otherdaemon (no override yet) still correctly AFFECTED via the wide window — real staleness never hidden" \
  || nok "T53 otherdaemon affected" "$(field AFFECTED "$OUT")"
grep -q "com.test.bigclosure" "$MOCK/kicks.log" 2>/dev/null \
  && nok "T53 bigclosure must not be kickstarted" "log: $(cat "$MOCK/kicks.log")" \
  || ok "T53 bigclosure never kickstarted (downgrade reaches Step 4 too, not just the AFFECTED report)"
grep -q "com.test.otherdaemon" "$MOCK/kicks.log" 2>/dev/null \
  && ok "T53 otherdaemon correctly kickstarted" \
  || nok "T53 otherdaemon kickstart" "log: $(cat "$MOCK/kicks.log" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# T54 (ga-0fawwr): an override whose sha resolves to a real commit but is NOT
# an ancestor of POST_DEPLOY_SHA (a diverged/rewritten branch, or simply a
# stale/foreign value that ended up in the wrong rig's file) must be ignored
# outright — the same ancestor-safety contract story-delivery.sh's own
# rig-wide marker already enforces. Falls back to the ORIGINAL wide-window
# verdict: still correctly AFFECTED, never silently cleared by an unusable
# override.
# ════════════════════════════════════════════════════════════════════════════
new_case t54
mkdir -p "$RUNTIME/lib"
cat > "$RUNTIME/lib/shared.py" <<<'def v(): return 1'
cat > "$RUNTIME/daemons/bigclosure.py" <<'PYEOF'
from lib import shared
def index():
    return shared.v()
PYEOF
cat > "$RUNTIME/daemons/deploy_deps.json" <<'JSONEOF'
{
  "_generated_by": "scripts/gen_daemon_deps.py",
  "daemons": {
    "daemons/bigclosure.py": {
      "label": "com.test.bigclosure",
      "closure": ["daemons/bigclosure.py", "lib/shared.py"]
    }
  }
}
JSONEOF
make_plist "$AGENTS" com.test.bigclosure "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/bigclosure.py"
seed_running com.test.bigclosure 30101 "$STALE_LSTART"

( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && git commit -q -m t54-base --allow-empty )
SHA_C0=$(git -C "$RUNTIME" rev-parse HEAD)
git -C "$RUNTIME" checkout -q --orphan t54-side
echo side > "$RUNTIME/side.txt"
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && git commit -q -m t54-side --allow-empty )
SHA_SIDE=$(git -C "$RUNTIME" rev-parse HEAD)
git -C "$RUNTIME" checkout -q main 2>/dev/null || git -C "$RUNTIME" checkout -q master
echo "def v(): return 2" > "$RUNTIME/lib/shared.py"
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && GIT_AUTHOR_DATE="@$POST_COMMIT_EPOCH" GIT_COMMITTER_DATE="@$POST_COMMIT_EPOCH" git commit -q -m t54-c1 --allow-empty )
SHA_C1=$(git -C "$RUNTIME" rev-parse HEAD)

OUT=$(MOCK_DIR="$MOCK" RUNTIME_DIR="$RUNTIME" \
  PRE_DEPLOY_SHA="$SHA_C0" POST_DEPLOY_SHA="$SHA_C1" \
  DEPLOY_EPOCH="$DEPLOY_EPOCH" SENSITIVE_DAEMONS="" EXTRA_RUNTIME_ROOTS="" \
  FORCE_RESTART_LABELS="" \
  DAEMON_BASELINE_OVERRIDES="com.test.bigclosure $SHA_SIDE" \
  LAUNCH_AGENTS_DIR="$AGENTS" LAUNCHCTL_BIN="$BIN/launchctl" PS_BIN="$BIN/ps" \
  VERIFY_TIMEOUT=2 VERIFY_INTERVAL=0.2 DRY_RUN=0 \
  bash "$HELPER" 2>/dev/null); RC=$?
echo "$(field AFFECTED "$OUT")" | grep "com.test.bigclosure" >/dev/null \
  && ok "T54 non-ancestor override safely ignored — falls back to the wide-window verdict (still AFFECTED)" \
  || nok "T54 affected" "AFFECTED=[$(field AFFECTED "$OUT")]"

# ════════════════════════════════════════════════════════════════════════════
# T55 (ga-gjum0y): a scheduled-job plist committed by this deploy, never
#     installed under LAUNCH_AGENTS_DIR at all (same shape as T37) — but this
#     time its label is recorded in restart_policy.yaml's scheduled_job_opt_out.
#     A missing plist has nowhere to carry a Disabled=true key (T40's
#     mechanism doesn't reach this case at all), so this is the ONLY way to
#     express "never installed on purpose" for a job that was never installed.
#     Must resolve OK, exactly like T39's installed+loaded control — never
#     JOB_NOT_INSTALLED, and never SKIPPED/not_applicable either (this proves
#     the exemption reaches all the way to a real verdict, not just a
#     different-flavored non-OK).
# ════════════════════════════════════════════════════════════════════════════
new_case t55
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && git commit -q -m base --allow-empty )
PRE=$(git -C "$RUNTIME" rev-parse HEAD)
make_plist "$RUNTIME/launchd" com.test.optoutmissing "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/optoutmissing.py"
cat > "$RUNTIME/daemons/restart_policy.yaml" <<'EOF'
scheduled_job_opt_out:
  - com.test.optoutmissing   # T55 fixture: recorded decision, never installed
EOF
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && \
  GIT_AUTHOR_DATE="@$POST_COMMIT_EPOCH" GIT_COMMITTER_DATE="@$POST_COMMIT_EPOCH" \
  git commit -q -m deploy )
POST=$(git -C "$RUNTIME" rev-parse HEAD)
# deliberately do NOT copy the plist into $AGENTS — opt-out must cover this.
OUT=$(MOCK_DIR="$MOCK" RUNTIME_DIR="$RUNTIME" PRE_DEPLOY_SHA="$PRE" POST_DEPLOY_SHA="$POST" \
  DEPLOY_EPOCH="$DEPLOY_EPOCH" SENSITIVE_DAEMONS="$SENSITIVE_DAEMONS" \
  EXTRA_RUNTIME_ROOTS="${EXTRA_RUNTIME_ROOTS:-}" LAUNCH_AGENTS_DIR="$AGENTS" \
  LAUNCHCTL_BIN="$BIN/launchctl" PS_BIN="$BIN/ps" VERIFY_TIMEOUT=2 VERIFY_INTERVAL=0.2 \
  DRY_RUN=0 bash "$HELPER" 2>/dev/null); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T55 verdict OK (scheduled_job_opt_out covers a never-installed job)" || nok "T55 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T55 exit 0" || nok "T55 exit" "rc=$RC"

# ════════════════════════════════════════════════════════════════════════════
# T56 (ga-gjum0y): companion to T55 — the plist IS installed under
#     LAUNCH_AGENTS_DIR (someone copied the file, or it was installed long
#     ago) but launchd never has it loaded (same shape as T38, e.g. a rig
#     owner ran `launchctl disable` on it — a launchd-side database, never
#     written back into the plist's own Disabled key, so T40's mechanism
#     cannot see it either). Its label is ALSO in scheduled_job_opt_out.
#     Must resolve OK, not JOB_NOT_INSTALLED.
# ════════════════════════════════════════════════════════════════════════════
new_case t56
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && git commit -q -m base --allow-empty )
PRE=$(git -C "$RUNTIME" rev-parse HEAD)
make_plist "$RUNTIME/launchd" com.test.optoutunloaded "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/optoutunloaded.py"
cat > "$RUNTIME/daemons/restart_policy.yaml" <<'EOF'
scheduled_job_opt_out:
  - com.test.optoutunloaded   # T56 fixture: recorded decision, launchctl-disabled
EOF
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && \
  GIT_AUTHOR_DATE="@$POST_COMMIT_EPOCH" GIT_COMMITTER_DATE="@$POST_COMMIT_EPOCH" \
  git commit -q -m deploy )
POST=$(git -C "$RUNTIME" rev-parse HEAD)
make_plist "$AGENTS" com.test.optoutunloaded "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/optoutunloaded.py"
# deliberately do NOT seed_loaded/seed_running — mirrors `launchctl disable`.
OUT=$(MOCK_DIR="$MOCK" RUNTIME_DIR="$RUNTIME" PRE_DEPLOY_SHA="$PRE" POST_DEPLOY_SHA="$POST" \
  DEPLOY_EPOCH="$DEPLOY_EPOCH" SENSITIVE_DAEMONS="$SENSITIVE_DAEMONS" \
  EXTRA_RUNTIME_ROOTS="${EXTRA_RUNTIME_ROOTS:-}" LAUNCH_AGENTS_DIR="$AGENTS" \
  LAUNCHCTL_BIN="$BIN/launchctl" PS_BIN="$BIN/ps" VERIFY_TIMEOUT=2 VERIFY_INTERVAL=0.2 \
  DRY_RUN=0 bash "$HELPER" 2>/dev/null); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T56 verdict OK (scheduled_job_opt_out covers an installed-but-unloaded job)" || nok "T56 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T56 exit 0" || nok "T56 exit" "rc=$RC"

# ════════════════════════════════════════════════════════════════════════════
# T57 (wa-flysp, header point 16): a SENSITIVE daemon GUARDED because its own
# entrypoint file is directly in the diff (same fixture as T4) must be
# classified GUARDED_OWN, not GUARDED_CLOSURE_ONLY — and REASON must render
# an OWN-FILE-CHANGED section, with no CLOSURE-ONLY section (nothing to put
# in it).
# ════════════════════════════════════════════════════════════════════════════
# explicit, not inherited: SENSITIVE_DAEMONS has been reassigned several
# times above (e.g. line ~1714) for earlier sections' own fixtures — T57-T60
# below set exactly what they need rather than depending on whatever the
# last preceding test happened to leave behind.
SENSITIVE_DAEMONS="central-sender slot-scheduler"
new_case t57
cat > "$RUNTIME/daemons/central_sender.py" <<<'print("send")'
make_plist "$AGENTS" com.test.central-sender "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/central_sender.py"
seed_running com.test.central-sender 57001 "$STALE_LSTART"
OUT=$(run_helper daemons/central_sender.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T57 verdict NEEDS_GUARDED_RESTART" || nok "T57 verdict" "got '$V' out=[$OUT]"
echo "$(field GUARDED_OWN "$OUT")" | grep "com.test.central-sender" >/dev/null && ok "T57 own-file-changed daemon lands in GUARDED_OWN" || nok "T57 guarded_own" "$(field GUARDED_OWN "$OUT")"
echo "$(field GUARDED_CLOSURE_ONLY "$OUT")" | grep "com.test.central-sender" >/dev/null && nok "T57 must NOT be in GUARDED_CLOSURE_ONLY" "$(field GUARDED_CLOSURE_ONLY "$OUT")" || ok "T57 not in GUARDED_CLOSURE_ONLY"
[ -z "$(field GUARDED_CLOSURE_ONLY "$OUT")" ] && ok "T57 GUARDED_CLOSURE_ONLY empty (nothing closure-only this run)" || nok "T57 guarded_closure_only empty" "$(field GUARDED_CLOSURE_ONLY "$OUT")"
R57="$(field REASON "$OUT")"
echo "$R57" | grep "OWN-FILE-CHANGED" >/dev/null && ok "T57 REASON renders an OWN-FILE-CHANGED section" || nok "T57 reason own-section" "$R57"
echo "$R57" | grep "CLOSURE-ONLY" >/dev/null && nok "T57 REASON must NOT render a CLOSURE-ONLY section (nothing to show)" "$R57" || ok "T57 no CLOSURE-ONLY section"
# same partition must reach the trailing JSON, not just the KEY=value lines.
echo "$OUT" | grep '^JSON=' | sed 's/^JSON=//' | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["guarded_own"] == ["com.test.central-sender"], d["guarded_own"]
assert d["guarded_closure_only"] == [], d["guarded_closure_only"]
' 2>/tmp/t57_json_err \
  && ok "T57 JSON guarded_own/guarded_closure_only match the KEY=value lines" \
  || nok "T57 JSON" "$(cat /tmp/t57_json_err 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# T58 (wa-flysp, header point 16): a SENSITIVE daemon GUARDED only via
# import-level reachability (same shape as T5's fixture, but SENSITIVE +
# no drain instead of SAFE) — its OWN file never changed, only a routes/*.py
# module it imports. Must classify GUARDED_CLOSURE_ONLY, not GUARDED_OWN, and
# REASON must render a CLOSURE-ONLY section with no OWN-FILE-CHANGED section.
# The pre-existing flat GUARDED field must still contain it too (backward
# compat: no existing caller's parsing of GUARDED= may change).
# ════════════════════════════════════════════════════════════════════════════
new_case t58
cat > "$RUNTIME/routes/channel_admin_api.py" <<<'def register(app): pass'
cat > "$RUNTIME/daemons/central_sender.py" <<'PYEOF'
from routes.channel_admin_api import register
register(None)
PYEOF
make_plist "$AGENTS" com.test.central-sender "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/central_sender.py"
seed_running com.test.central-sender 58001 "$STALE_LSTART"
# deploy changes ONLY the imported route file, never central_sender.py itself
OUT=$(run_helper routes/channel_admin_api.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T58 verdict NEEDS_GUARDED_RESTART" || nok "T58 verdict" "got '$V' out=[$OUT]"
echo "$(field GUARDED "$OUT")" | grep "com.test.central-sender" >/dev/null && ok "T58 still in flat GUARDED (backward compat)" || nok "T58 guarded" "$(field GUARDED "$OUT")"
echo "$(field GUARDED_CLOSURE_ONLY "$OUT")" | grep "com.test.central-sender" >/dev/null && ok "T58 import-only daemon lands in GUARDED_CLOSURE_ONLY" || nok "T58 guarded_closure_only" "$(field GUARDED_CLOSURE_ONLY "$OUT")"
echo "$(field GUARDED_OWN "$OUT")" | grep "com.test.central-sender" >/dev/null && nok "T58 must NOT be in GUARDED_OWN" "$(field GUARDED_OWN "$OUT")" || ok "T58 not in GUARDED_OWN"
[ -z "$(field GUARDED_OWN "$OUT")" ] && ok "T58 GUARDED_OWN empty (nothing own-file-changed this run)" || nok "T58 guarded_own empty" "$(field GUARDED_OWN "$OUT")"
R58="$(field REASON "$OUT")"
echo "$R58" | grep "CLOSURE-ONLY" >/dev/null && ok "T58 REASON renders a CLOSURE-ONLY section" || nok "T58 reason closure-section" "$R58"
# the exact historical bug class this guards against (mirrors WA's own
# daemon-refresh-step5-ranking.selftest.sh "GUARDED but zero symbol-confirmed
# must still show its section" case): a 100%-closure-only GUARDED list must
# not silently omit the OWN-FILE-CHANGED header's absence — it must render
# ZERO own-file-changed daemons, not skip discussing the split at all.
echo "$R58" | grep "OWN-FILE-CHANGED" >/dev/null && nok "T58 REASON must NOT render an OWN-FILE-CHANGED section (nothing to show)" "$R58" || ok "T58 no OWN-FILE-CHANGED section"

# ════════════════════════════════════════════════════════════════════════════
# T59 (wa-flysp, header point 16): a MIXED deploy — one SENSITIVE daemon
# GUARDED via its own file changing, a DIFFERENT SENSITIVE daemon GUARDED
# only via import-level reachability — both land in GUARDED (unchanged
# behavior), but must split correctly into the two new buckets, AND the
# rendered REASON must place the OWN-FILE-CHANGED section BEFORE the
# CLOSURE-ONLY section (the actionable half must never be buried after the
# noise — the whole point of this bead).
# ════════════════════════════════════════════════════════════════════════════
new_case t59
cat > "$RUNTIME/daemons/central_sender.py" <<<'print("send")'
cat > "$RUNTIME/routes/channel_admin_api.py" <<<'def register(app): pass'
cat > "$RUNTIME/daemons/slot_scheduler.py" <<'PYEOF'
from routes.channel_admin_api import register
register(None)
PYEOF
make_plist "$AGENTS" com.test.central-sender "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/central_sender.py"
make_plist "$AGENTS" com.test.slot-scheduler "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/slot_scheduler.py"
seed_running com.test.central-sender 59001 "$STALE_LSTART"
seed_running com.test.slot-scheduler 59101 "$STALE_LSTART"
# this deploy changes central_sender.py's OWN file AND the route slot_scheduler
# only imports — never slot_scheduler.py itself.
OUT=$(run_helper daemons/central_sender.py routes/channel_admin_api.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T59 verdict NEEDS_GUARDED_RESTART" || nok "T59 verdict" "got '$V' out=[$OUT]"
echo "$(field GUARDED_OWN "$OUT")" | grep "com.test.central-sender" >/dev/null && ok "T59 central-sender in GUARDED_OWN" || nok "T59 guarded_own central" "$(field GUARDED_OWN "$OUT")"
echo "$(field GUARDED_CLOSURE_ONLY "$OUT")" | grep "com.test.slot-scheduler" >/dev/null && ok "T59 slot-scheduler in GUARDED_CLOSURE_ONLY" || nok "T59 guarded_closure_only slot" "$(field GUARDED_CLOSURE_ONLY "$OUT")"
echo "$(field GUARDED_OWN "$OUT")" | grep "com.test.slot-scheduler" >/dev/null && nok "T59 slot-scheduler must NOT be in GUARDED_OWN" "$(field GUARDED_OWN "$OUT")" || ok "T59 slot-scheduler correctly excluded from GUARDED_OWN"
echo "$(field GUARDED_CLOSURE_ONLY "$OUT")" | grep "com.test.central-sender" >/dev/null && nok "T59 central-sender must NOT be in GUARDED_CLOSURE_ONLY" "$(field GUARDED_CLOSURE_ONLY "$OUT")" || ok "T59 central-sender correctly excluded from GUARDED_CLOSURE_ONLY"
R59="$(field REASON "$OUT")"
OWN_POS="${R59%%OWN-FILE-CHANGED*}"
CLOSURE_POS="${R59%%CLOSURE-ONLY*}"
[ "${#OWN_POS}" -lt "${#CLOSURE_POS}" ] && ok "T59 OWN-FILE-CHANGED section renders BEFORE CLOSURE-ONLY (actionable half first)" || nok "T59 section order" "$R59"

# ════════════════════════════════════════════════════════════════════════════
# T60 (wa-flysp, header point 16): GUARDED_OWN/GUARDED_CLOSURE_ONLY must be
# ALWAYS-PRESENT fields (even empty) on a verdict that never reaches Step 4's
# GUARDED branch at all — same convention as AFFECTED_NOT_RUNNING/
# PARSE_ERROR_LOADED. Reuses T2's plain SAFE-auto-restart fixture.
# ════════════════════════════════════════════════════════════════════════════
new_case t60
cat > "$RUNTIME/daemons/ban_risk_dashboard.py" <<<'print("dash")'
make_plist "$AGENTS" com.test.ban-risk-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/ban_risk_dashboard.py"
seed_running com.test.ban-risk-dashboard 60001 "$STALE_LSTART"
seed_restart com.test.ban-risk-dashboard 60099 "$FRESH_LSTART"
OUT=$(run_helper daemons/ban_risk_dashboard.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T60 verdict OK" || nok "T60 verdict" "got '$V' out=[$OUT]"
echo "$OUT" | grep '^GUARDED_OWN=' >/dev/null && ok "T60 GUARDED_OWN field present (even empty) on a non-GUARDED verdict" || nok "T60 guarded_own present" "out=[$OUT]"
echo "$OUT" | grep '^GUARDED_CLOSURE_ONLY=' >/dev/null && ok "T60 GUARDED_CLOSURE_ONLY field present (even empty) on a non-GUARDED verdict" || nok "T60 guarded_closure_only present" "out=[$OUT]"
[ -z "$(field GUARDED_OWN "$OUT")" ] && ok "T60 GUARDED_OWN empty" || nok "T60 guarded_own empty" "$(field GUARDED_OWN "$OUT")"
[ -z "$(field GUARDED_CLOSURE_ONLY "$OUT")" ] && ok "T60 GUARDED_CLOSURE_ONLY empty" || nok "T60 guarded_closure_only empty" "$(field GUARDED_CLOSURE_ONLY "$OUT")"

# ════════════════════════════════════════════════════════════════════════════
# T61 (wa-flysp, header point 16, pre-flight self-audit finding): a
# FORCE_RESTART_LABELS entry (same python-m/unresolvable-entrypoint shape as
# T50, but SENSITIVE + no drain here instead of SAFE) never runs through
# Step 3's own_hit loop at all — it is added to AFFECTED entirely outside
# that loop, precisely because Step 2 couldn't discover an entrypoint for it.
# Without an explicit own-hit classification for this path, it would default
# to GUARDED_CLOSURE_ONLY by omission — mislabeling an explicit operator
# override (the STRONGEST signal this script has, stronger than an ordinary
# own-file-changed match) as "known noise, verify by hand". Must land in
# GUARDED_OWN instead.
# ════════════════════════════════════════════════════════════════════════════
new_case t61
mkdir -p "$RUNTIME/dashboard"
cat > "$RUNTIME/dashboard/app.py" <<<'print("forced sensitive dashboard")'
cat > "$AGENTS/com.test.central-sender-forced.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.test.central-sender-forced</string>
  <key>ProgramArguments</key>
  <array>
    <string>$RUNTIME/.venv/bin/python</string>
    <string>-m</string>
    <string>flask</string>
    <string>run</string>
  </array>
  <key>WorkingDirectory</key><string>$RUNTIME</string>
</dict>
</plist>
EOF
seed_running com.test.central-sender-forced 61001 "$STALE_LSTART"
# deliberately NO seed_restart, NO drain command: sensitive + no drain path -> GUARDED
FORCE_RESTART_LABELS="com.test.central-sender-forced"
OUT=$(run_helper dashboard/app.py); RC=$?
FORCE_RESTART_LABELS=""
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T61 verdict NEEDS_GUARDED_RESTART" || nok "T61 verdict" "got '$V' out=[$OUT]"
echo "$(field GUARDED "$OUT")" | grep "com.test.central-sender-forced" >/dev/null && ok "T61 forced-in daemon still in flat GUARDED" || nok "T61 guarded" "$(field GUARDED "$OUT")"
echo "$(field GUARDED_OWN "$OUT")" | grep "com.test.central-sender-forced" >/dev/null && ok "T61 FORCE_RESTART_LABELS entry classified GUARDED_OWN, not closure-only noise" || nok "T61 guarded_own" "$(field GUARDED_OWN "$OUT")"
echo "$(field GUARDED_CLOSURE_ONLY "$OUT")" | grep "com.test.central-sender-forced" >/dev/null && nok "T61 must NOT be in GUARDED_CLOSURE_ONLY" "$(field GUARDED_CLOSURE_ONLY "$OUT")" || ok "T61 correctly excluded from GUARDED_CLOSURE_ONLY"

# ════════════════════════════════════════════════════════════════════════════
# T62 (ga-8q1ulq, header point 17): rig HAS compute_symbol_reachability.py,
# and it reports reaches=true for the one GUARDED daemon -> SYMBOL-CONFIRMED.
# ════════════════════════════════════════════════════════════════════════════
SENSITIVE_DAEMONS="central-sender"
new_case t62
make_symbol_script "$RUNTIME"
cat > "$RUNTIME/daemons/central_sender.py" <<<'print("send")'
make_plist "$AGENTS" com.test.central-sender "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/central_sender.py"
seed_running com.test.central-sender 62001 "$STALE_LSTART"
seed_symbol_result daemons/central_sender.py confirmed
OUT=$(run_helper daemons/central_sender.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T62 verdict NEEDS_GUARDED_RESTART" || nok "T62 verdict" "got '$V' out=[$OUT]"
echo "$(field GUARDED_SYMBOL_CONFIRMED "$OUT")" | grep "com.test.central-sender" >/dev/null && ok "T62 lands in GUARDED_SYMBOL_CONFIRMED" || nok "T62 guarded_symbol_confirmed" "$(field GUARDED_SYMBOL_CONFIRMED "$OUT")"
[ -z "$(field GUARDED_SYMBOL_NO_EVIDENCE "$OUT")" ] && ok "T62 GUARDED_SYMBOL_NO_EVIDENCE empty" || nok "T62 guarded_symbol_no_evidence" "$(field GUARDED_SYMBOL_NO_EVIDENCE "$OUT")"
[ -z "$(field GUARDED_SYMBOL_NOT_COMPUTED "$OUT")" ] && ok "T62 GUARDED_SYMBOL_NOT_COMPUTED empty" || nok "T62 guarded_symbol_not_computed" "$(field GUARDED_SYMBOL_NOT_COMPUTED "$OUT")"
echo "$(field REASON "$OUT")" | grep "SYMBOL-CONFIRMED" >/dev/null && ok "T62 REASON renders a SYMBOL-CONFIRMED section" || nok "T62 reason" "$(field REASON "$OUT")"

# ════════════════════════════════════════════════════════════════════════════
# T63 (ga-8q1ulq, header point 17): same shape as T62, but the calculator
# reports reaches=false (no evidence of a call-graph path) -> SEM EVIDÊNCIA
# DE SÍMBOLO, never silently promoted to SYMBOL-CONFIRMED.
# ════════════════════════════════════════════════════════════════════════════
new_case t63
make_symbol_script "$RUNTIME"
cat > "$RUNTIME/daemons/central_sender.py" <<<'print("send")'
make_plist "$AGENTS" com.test.central-sender "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/central_sender.py"
seed_running com.test.central-sender 63001 "$STALE_LSTART"
seed_symbol_result daemons/central_sender.py no_evidence
OUT=$(run_helper daemons/central_sender.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T63 verdict NEEDS_GUARDED_RESTART" || nok "T63 verdict" "got '$V' out=[$OUT]"
echo "$(field GUARDED_SYMBOL_NO_EVIDENCE "$OUT")" | grep "com.test.central-sender" >/dev/null && ok "T63 lands in GUARDED_SYMBOL_NO_EVIDENCE" || nok "T63 guarded_symbol_no_evidence" "$(field GUARDED_SYMBOL_NO_EVIDENCE "$OUT")"
[ -z "$(field GUARDED_SYMBOL_CONFIRMED "$OUT")" ] && ok "T63 GUARDED_SYMBOL_CONFIRMED empty" || nok "T63 guarded_symbol_confirmed" "$(field GUARDED_SYMBOL_CONFIRMED "$OUT")"
[ -z "$(field GUARDED_SYMBOL_NOT_COMPUTED "$OUT")" ] && ok "T63 GUARDED_SYMBOL_NOT_COMPUTED empty" || nok "T63 guarded_symbol_not_computed" "$(field GUARDED_SYMBOL_NOT_COMPUTED "$OUT")"
echo "$(field REASON "$OUT")" | grep "SEM EVIDÊNCIA DE SÍMBOLO" >/dev/null && ok "T63 REASON renders a SEM EVIDÊNCIA DE SÍMBOLO section" || nok "T63 reason" "$(field REASON "$OUT")"

# ════════════════════════════════════════════════════════════════════════════
# T64 (ga-8q1ulq, header point 17 / ACEITE item 2): the calculator subprocess
# CRASHES (nonzero exit) for the one GUARDED daemon -> NÃO CALCULADO. Must
# NEVER be folded into SEM EVIDÊNCIA DE SÍMBOLO (a crash is not a negative
# answer), and must NEVER change VERDICT or pull the label out of the flat
# GUARDED list — this layer only reorders/annotates.
# ════════════════════════════════════════════════════════════════════════════
new_case t64
make_symbol_script "$RUNTIME"
cat > "$RUNTIME/daemons/central_sender.py" <<<'print("send")'
make_plist "$AGENTS" com.test.central-sender "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/central_sender.py"
seed_running com.test.central-sender 64001 "$STALE_LSTART"
seed_symbol_result daemons/central_sender.py crash
OUT=$(run_helper daemons/central_sender.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T64 verdict still NEEDS_GUARDED_RESTART (unaffected by the crash)" || nok "T64 verdict" "got '$V' out=[$OUT]"
echo "$(field GUARDED "$OUT")" | grep "com.test.central-sender" >/dev/null && ok "T64 label still in flat GUARDED (membership unaffected)" || nok "T64 guarded" "$(field GUARDED "$OUT")"
echo "$(field GUARDED_SYMBOL_NOT_COMPUTED "$OUT")" | grep "com.test.central-sender" >/dev/null && ok "T64 lands in GUARDED_SYMBOL_NOT_COMPUTED" || nok "T64 guarded_symbol_not_computed" "$(field GUARDED_SYMBOL_NOT_COMPUTED "$OUT")"
[ -z "$(field GUARDED_SYMBOL_NO_EVIDENCE "$OUT")" ] && ok "T64 NOT folded into GUARDED_SYMBOL_NO_EVIDENCE" || nok "T64 guarded_symbol_no_evidence must be empty" "$(field GUARDED_SYMBOL_NO_EVIDENCE "$OUT")"
[ -z "$(field GUARDED_SYMBOL_CONFIRMED "$OUT")" ] && ok "T64 GUARDED_SYMBOL_CONFIRMED empty" || nok "T64 guarded_symbol_confirmed" "$(field GUARDED_SYMBOL_CONFIRMED "$OUT")"
echo "$(field REASON "$OUT")" | grep "NÃO CALCULADO" >/dev/null && ok "T64 REASON renders a NÃO CALCULADO section" || nok "T64 reason" "$(field REASON "$OUT")"

# ════════════════════════════════════════════════════════════════════════════
# T65 (ga-8q1ulq, header point 17 / ACEITE item 3): a rig WITHOUT
# scripts/compute_symbol_reachability.py behaves identically to today — no
# error, no new REASON section, all three new fields stay empty. Same
# fixture shape as T62-64, just never calls make_symbol_script.
# ════════════════════════════════════════════════════════════════════════════
new_case t65
cat > "$RUNTIME/daemons/central_sender.py" <<<'print("send")'
make_plist "$AGENTS" com.test.central-sender "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/central_sender.py"
seed_running com.test.central-sender 65001 "$STALE_LSTART"
OUT=$(run_helper daemons/central_sender.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T65 verdict NEEDS_GUARDED_RESTART" || nok "T65 verdict" "got '$V' out=[$OUT]"
[ -z "$(field GUARDED_SYMBOL_CONFIRMED "$OUT")" ] && ok "T65 GUARDED_SYMBOL_CONFIRMED empty (no calculator on this rig)" || nok "T65 guarded_symbol_confirmed" "$(field GUARDED_SYMBOL_CONFIRMED "$OUT")"
[ -z "$(field GUARDED_SYMBOL_NO_EVIDENCE "$OUT")" ] && ok "T65 GUARDED_SYMBOL_NO_EVIDENCE empty" || nok "T65 guarded_symbol_no_evidence" "$(field GUARDED_SYMBOL_NO_EVIDENCE "$OUT")"
[ -z "$(field GUARDED_SYMBOL_NOT_COMPUTED "$OUT")" ] && ok "T65 GUARDED_SYMBOL_NOT_COMPUTED empty" || nok "T65 guarded_symbol_not_computed" "$(field GUARDED_SYMBOL_NOT_COMPUTED "$OUT")"
R65="$(field REASON "$OUT")"
echo "$R65" | grep -E "SYMBOL-CONFIRMED|SEM EVIDÊNCIA DE SÍMBOLO|NÃO CALCULADO" >/dev/null && nok "T65 REASON must NOT mention any symbol-ranking section" "$R65" || ok "T65 no symbol-ranking section in REASON"

# ════════════════════════════════════════════════════════════════════════════
# T66 (ga-8q1ulq, header point 17; updated ga-4oh2r6 for batch mode): a MIXED
# GUARDED batch — one CONFIRMED, one NO_EVIDENCE, one whose line never
# arrives (NOT_COMPUTED) — all three sections must render, in that order,
# and VERDICT/flat-GUARDED membership stay exactly what point 16 alone would
# have produced (this layer only reorders/annotates). Also checks the
# trailing JSON, not just the KEY=value lines.
#
# Uses seed mode "missing", not "crash", for the third daemon (ga-4oh2r6):
# in the single-process --batch world all three entries share ONE manifest
# and one invocation, processed in whatever order $GUARDED iterates them —
# "crash" (sys.exit(1) mid-loop) would non-deterministically also wipe out
# any sibling entries the stub hadn't reached yet, making this test's outcome
# depend on iteration order instead of on the thing it's actually testing.
# "missing" (this bead's own addition to the stub) omits just the one
# entry's JSONL line while the stub keeps going — order-independent, and the
# realistic shape of "this daemon's answer never arrived" (a genuinely
# crashing whole-batch invocation is covered separately, T64/T67).
# ════════════════════════════════════════════════════════════════════════════
new_case t66
make_symbol_script "$RUNTIME"
cat > "$RUNTIME/daemons/central_sender.py" <<<'print("send")'
cat > "$RUNTIME/daemons/slot_scheduler.py" <<<'print("slot")'
cat > "$RUNTIME/daemons/conversation_monitor.py" <<<'print("conv")'
make_plist "$AGENTS" com.test.central-sender "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/central_sender.py"
make_plist "$AGENTS" com.test.slot-scheduler "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/slot_scheduler.py"
make_plist "$AGENTS" com.test.conversation-monitor "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/conversation_monitor.py"
seed_running com.test.central-sender 66001 "$STALE_LSTART"
seed_running com.test.slot-scheduler 66101 "$STALE_LSTART"
seed_running com.test.conversation-monitor 66201 "$STALE_LSTART"
seed_symbol_result daemons/central_sender.py confirmed
seed_symbol_result daemons/slot_scheduler.py no_evidence
seed_symbol_result daemons/conversation_monitor.py missing
SENSITIVE_DAEMONS="central-sender slot-scheduler conversation-monitor"
OUT=$(run_helper daemons/central_sender.py daemons/slot_scheduler.py daemons/conversation_monitor.py); RC=$?
SENSITIVE_DAEMONS="central-sender"
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T66 verdict NEEDS_GUARDED_RESTART" || nok "T66 verdict" "got '$V' out=[$OUT]"
for l in com.test.central-sender com.test.slot-scheduler com.test.conversation-monitor; do
  echo "$(field GUARDED "$OUT")" | grep "$l" >/dev/null && ok "T66 $l still in flat GUARDED" || nok "T66 guarded $l" "$(field GUARDED "$OUT")"
done
echo "$(field GUARDED_SYMBOL_CONFIRMED "$OUT")" | grep "com.test.central-sender" >/dev/null && ok "T66 central-sender in GUARDED_SYMBOL_CONFIRMED" || nok "T66 confirmed" "$(field GUARDED_SYMBOL_CONFIRMED "$OUT")"
echo "$(field GUARDED_SYMBOL_NO_EVIDENCE "$OUT")" | grep "com.test.slot-scheduler" >/dev/null && ok "T66 slot-scheduler in GUARDED_SYMBOL_NO_EVIDENCE" || nok "T66 no_evidence" "$(field GUARDED_SYMBOL_NO_EVIDENCE "$OUT")"
echo "$(field GUARDED_SYMBOL_NOT_COMPUTED "$OUT")" | grep "com.test.conversation-monitor" >/dev/null && ok "T66 conversation-monitor in GUARDED_SYMBOL_NOT_COMPUTED" || nok "T66 not_computed" "$(field GUARDED_SYMBOL_NOT_COMPUTED "$OUT")"
R66="$(field REASON "$OUT")"
CONF_POS="${R66%%SYMBOL-CONFIRMED*}"
NOEV_POS="${R66%%SEM EVIDÊNCIA DE SÍMBOLO*}"
NC_POS="${R66%%NÃO CALCULADO*}"
[ "${#CONF_POS}" -lt "${#NOEV_POS}" ] && [ "${#NOEV_POS}" -lt "${#NC_POS}" ] && ok "T66 sections render in order SYMBOL-CONFIRMED, SEM EVIDÊNCIA DE SÍMBOLO, NÃO CALCULADO" || nok "T66 section order" "$R66"
echo "$OUT" | grep '^JSON=' | sed 's/^JSON=//' | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["guarded_symbol_confirmed"] == ["com.test.central-sender"], d["guarded_symbol_confirmed"]
assert d["guarded_symbol_no_evidence"] == ["com.test.slot-scheduler"], d["guarded_symbol_no_evidence"]
assert d["guarded_symbol_not_computed"] == ["com.test.conversation-monitor"], d["guarded_symbol_not_computed"]
' 2>/tmp/t66_json_err \
  && ok "T66 JSON guarded_symbol_* fields match the KEY=value lines" \
  || nok "T66 JSON" "$(cat /tmp/t66_json_err 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# T67 (ga-8q1ulq, header point 17 / ACEITE item 4; updated ga-4oh2r6): the
# batch invocation hanging is bounded by SYMBOL_REACHABILITY_TOTAL_TIMEOUT —
# degrades to NÃO CALCULADO instead of stalling the halt past its budget.
# There is no more PER-DAEMON timeout to test separately (point 18 removed
# it along with the per-label subprocess loop it governed): a single-entry
# batch makes the total budget BE the effective per-daemon bound, which is
# exactly what this test now exercises. The stub's "hang" mode sleeps 20s;
# the test overrides the TOTAL timeout down to 1s so this stays a fast test.
# ════════════════════════════════════════════════════════════════════════════
new_case t67
make_symbol_script "$RUNTIME"
cat > "$RUNTIME/daemons/central_sender.py" <<<'print("send")'
make_plist "$AGENTS" com.test.central-sender "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/central_sender.py"
seed_running com.test.central-sender 67001 "$STALE_LSTART"
seed_symbol_result daemons/central_sender.py hang
SYMBOL_REACHABILITY_TOTAL_TIMEOUT=1
OUT=$(run_helper daemons/central_sender.py); RC=$?
SYMBOL_REACHABILITY_TOTAL_TIMEOUT=10
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T67 verdict NEEDS_GUARDED_RESTART" || nok "T67 verdict" "got '$V' out=[$OUT]"
echo "$(field GUARDED_SYMBOL_NOT_COMPUTED "$OUT")" | grep "com.test.central-sender" >/dev/null && ok "T67 hung batch invocation degrades to GUARDED_SYMBOL_NOT_COMPUTED" || nok "T67 guarded_symbol_not_computed" "$(field GUARDED_SYMBOL_NOT_COMPUTED "$OUT")"

# ════════════════════════════════════════════════════════════════════════════
# T68 (ga-8q1ulq, header point 17 / ACEITE item 4; updated ga-4oh2r6):
# SYMBOL_REACHABILITY_TOTAL_TIMEOUT=0 means the whole batch's budget is
# already spent before the (single, now) invocation would even happen —
# every GUARDED label is degraded to NÃO CALCULADO WITHOUT the calculator
# ever being invoked at all (no symbol_batch_argv.json recorded — this is
# the explicit `-le 0` pre-check point 18 added specifically because
# `timeout 0 cmd` does NOT mean "time out instantly"; verified live,
# coreutils treats a 0 duration as no bound). Two daemons in one manifest
# prove this is the one shared budget check, not something re-evaluated per
# label the way the old per-label loop's SECONDS-based check was.
# ════════════════════════════════════════════════════════════════════════════
new_case t68
make_symbol_script "$RUNTIME"
cat > "$RUNTIME/daemons/central_sender.py" <<<'print("send")'
cat > "$RUNTIME/daemons/slot_scheduler.py" <<<'print("slot")'
make_plist "$AGENTS" com.test.central-sender "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/central_sender.py"
make_plist "$AGENTS" com.test.slot-scheduler "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/slot_scheduler.py"
seed_running com.test.central-sender 68001 "$STALE_LSTART"
seed_running com.test.slot-scheduler 68101 "$STALE_LSTART"
seed_symbol_result daemons/central_sender.py confirmed
seed_symbol_result daemons/slot_scheduler.py confirmed
SENSITIVE_DAEMONS="central-sender slot-scheduler"
SYMBOL_REACHABILITY_TOTAL_TIMEOUT=0
OUT=$(run_helper daemons/central_sender.py daemons/slot_scheduler.py); RC=$?
SYMBOL_REACHABILITY_TOTAL_TIMEOUT=10
SENSITIVE_DAEMONS="central-sender"
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T68 verdict NEEDS_GUARDED_RESTART" || nok "T68 verdict" "got '$V' out=[$OUT]"
NC68="$(field GUARDED_SYMBOL_NOT_COMPUTED "$OUT")"
echo "$NC68" | grep "com.test.central-sender" >/dev/null && echo "$NC68" | grep "com.test.slot-scheduler" >/dev/null \
  && ok "T68 exhausted total budget degrades BOTH daemons to GUARDED_SYMBOL_NOT_COMPUTED" \
  || nok "T68 guarded_symbol_not_computed" "$NC68"
[ ! -e "$MOCK/symbol_batch_argv.json" ] \
  && ok "T68 calculator never invoked once the total budget was already spent" \
  || nok "T68 stub should not have been called" "symbol_batch_argv.json exists under $MOCK"

# ════════════════════════════════════════════════════════════════════════════
# T69 (ga-8q1ulq, header point 17 / ACEITE item 1): the reachability window
# prefers this bead's own BEAD_MERGE_PRE_SHA/BEAD_MERGE_SHA over the wider
# PRE_DEPLOY_SHA/POST_DEPLOY_SHA once a later, unrelated bystander commit
# widens the deploy window beyond this bead's own range (header point 14's
# "runtime fell behind" shape) — proven against the stub's own recorded
# argv, not just the classification outcome. Bypasses run_helper() (which
# owns its own base/deploy commit dance) to construct the three-commit
# history this needs.
# ════════════════════════════════════════════════════════════════════════════
new_case t69
make_symbol_script "$RUNTIME"
cat > "$RUNTIME/daemons/central_sender.py" <<<'print("send")'
make_plist "$AGENTS" com.test.central-sender "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/central_sender.py"
seed_running com.test.central-sender 69001 "$STALE_LSTART"
SENSITIVE_DAEMONS="central-sender"
( cd "$RUNTIME"; git add -A >/dev/null 2>&1; git commit -q -m base --allow-empty )
WIDE_PRE=$(git -C "$RUNTIME" rev-parse HEAD)
echo "# changed $(date +%s%N)" >> "$RUNTIME/daemons/central_sender.py"
( cd "$RUNTIME"; git add -A >/dev/null 2>&1; git commit -q -m "bead merge" --allow-empty )
BEAD_PRE="$WIDE_PRE"
BEAD_POST=$(git -C "$RUNTIME" rev-parse HEAD)
echo "# bystander $(date +%s%N)" >> "$RUNTIME/README.md"
( cd "$RUNTIME"; git add -A >/dev/null 2>&1; git commit -q -m bystander --allow-empty )
WIDE_POST=$(git -C "$RUNTIME" rev-parse HEAD)
OUT=$(MOCK_DIR="$MOCK" RUNTIME_DIR="$RUNTIME" \
  PRE_DEPLOY_SHA="$WIDE_PRE" POST_DEPLOY_SHA="$WIDE_POST" \
  BEAD_MERGE_PRE_SHA="$BEAD_PRE" BEAD_MERGE_SHA="$BEAD_POST" \
  DEPLOY_EPOCH="$DEPLOY_EPOCH" SENSITIVE_DAEMONS="$SENSITIVE_DAEMONS" \
  EXTRA_RUNTIME_ROOTS="" FORCE_RESTART_LABELS="" \
  LAUNCH_AGENTS_DIR="$AGENTS" LAUNCHCTL_BIN="$BIN/launchctl" PS_BIN="$BIN/ps" \
  VERIFY_TIMEOUT=2 VERIFY_INTERVAL=0.2 \
  SYMBOL_REACHABILITY_TOTAL_TIMEOUT=10 \
  DRY_RUN=0 bash "$HELPER" 2>/dev/null); RC=$?
SENSITIVE_DAEMONS="central-sender"
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T69 verdict NEEDS_GUARDED_RESTART" || nok "T69 verdict" "got '$V' out=[$OUT]"
# ga-4oh2r6: --before/--after are now batch-level args (one manifest, one
# call), recorded by the stub to symbol_batch_argv.json instead of a
# per-daemon symbol_argv.<entrypoint> file.
ARGV_FILE="$MOCK/symbol_batch_argv.json"
[ -f "$ARGV_FILE" ] && ok "T69 calculator was invoked (batch argv recorded)" || nok "T69 argv file" "missing $ARGV_FILE"
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d["before"] == sys.argv[2], (d["before"], sys.argv[2])
assert d["after"] == sys.argv[3], (d["after"], sys.argv[3])
' "$ARGV_FILE" "$BEAD_PRE" "$BEAD_POST" 2>/tmp/t69_err \
  && ok "T69 --before/--after use the bead's own merge range, not the wider deploy window" \
  || nok "T69 window preference" "$(cat /tmp/t69_err 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# T70 (ga-4oh2r6): the actual regression this bead fixes — FIVE GUARDED
# daemons in one run must trigger exactly ONE compute_symbol_reachability.py
# invocation, not five. Measured in production before this fix: 17 GUARDED
# daemons -> 17 separate subprocesses, each re-fetching+re-parsing its own
# entrypoint+closure from scratch with zero sharing, blowing both the old
# per-daemon (5s) and total (30s) budgets -- 17/17 landed on NÃO CALCULADO on
# the feature's first real production run (story-delivery.log:120141-120158).
# Proven via symbol_batch_invocations, an incrementing counter the stub
# writes on every --batch invocation (not just file existence, which a
# regression back to N separate calls overwriting the same filename would
# leave looking identical) -- and independently, via the manifest's own
# recorded entry count (n_entries) matching all five labels in one shot.
# ════════════════════════════════════════════════════════════════════════════
new_case t70
make_symbol_script "$RUNTIME"
T70_LABELS="alpha bravo charlie delta echo"
T70_FILES=""
for n in $T70_LABELS; do
  cat > "$RUNTIME/daemons/${n}_daemon.py" <<EOF
print("$n")
EOF
  make_plist "$AGENTS" "com.test.$n" "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/${n}_daemon.py"
  T70_FILES="$T70_FILES daemons/${n}_daemon.py"
done
i=70100
for n in $T70_LABELS; do
  seed_running "com.test.$n" "$i" "$STALE_LSTART"
  seed_symbol_result "daemons/${n}_daemon.py" confirmed
  i=$((i+1))
done
SENSITIVE_DAEMONS="$T70_LABELS"
# shellcheck disable=SC2086 -- $T70_FILES is intentionally word-split (list of relpaths)
OUT=$(run_helper $T70_FILES); RC=$?
SENSITIVE_DAEMONS="central-sender"
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T70 verdict NEEDS_GUARDED_RESTART" || nok "T70 verdict" "got '$V' out=[$OUT]"
for n in $T70_LABELS; do
  echo "$(field GUARDED_SYMBOL_CONFIRMED "$OUT")" | grep "com.test.$n" >/dev/null \
    && ok "T70 com.test.$n correctly SYMBOL-CONFIRMED" \
    || nok "T70 com.test.$n missing from GUARDED_SYMBOL_CONFIRMED" "$(field GUARDED_SYMBOL_CONFIRMED "$OUT")"
done
INVOCATIONS="$(cat "$MOCK/symbol_batch_invocations" 2>/dev/null || echo "<missing>")"
[ "$INVOCATIONS" = "1" ] \
  && ok "T70 exactly ONE compute_symbol_reachability.py invocation for 5 GUARDED daemons (was 5 before ga-4oh2r6)" \
  || nok "T70 invocation count" "symbol_batch_invocations=$INVOCATIONS (expected 1)"
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d["n_entries"] == 5, d["n_entries"]
' "$MOCK/symbol_batch_argv.json" 2>/tmp/t70_err \
  && ok "T70 the one invocation carried all 5 entries in its manifest" \
  || nok "T70 manifest entry count" "$(cat /tmp/t70_err 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# T71-T83 (ga-j3lh6p, header point 19): GUARDED_LOCKED_COSMETIC.
#
# THE BUG (wa-z66jb 20/09, wa-ho1ol same day): a story's merge touched a shared
# lib that com.whatsapp.demand-dashboard imports. That daemon is
# notify_only_locked in restart_policy.yaml ("Trava humana: NUNCA auto" — it
# hosts the outreach_worker in-process, a restart halts outreach), so NO
# automation ever restarts it, so the delivery consumer that holds a story for a
# still-stale guarded daemon holds it FOREVER (delivery:deploy-pending), and the
# Mayor closed each by hand after ~20min of investigation. The report already
# contained the answer — the symbol split said "no call-graph path from this
# entrypoint to a changed symbol" — but nothing consumed it.
#
# This layer names, in ONE place that owns both facts (the policy file and the
# symbol split), the GUARDED subset that is BOTH (a) locked against automation
# AND (b) CLEANLY evaluated to "no path". It only ANNOTATES: VERDICT and GUARDED
# never change. Consumers decide what to do with it.
#
# The load-bearing rule (erro != vazio): reaches=false is NOT always "analysed,
# found nothing". The calculator also returns it for an unparseable/absent
# ENTRYPOINT ("reaches=False por padrão seguro", "não dá pra avaliar") and after
# dropping a closure file whose structural diff failed. Those must be NOT
# COMPUTED — never no-evidence — or a broken analysis would release a delivery.
# Only the one benign warning (a closure file absent at --after: added by a later
# commit, or deleted) leaves the answer trustworthy.
# ════════════════════════════════════════════════════════════════════════════
# json_list <key> <helper-output> -> the trailing JSON's list field, space-joined
json_list() {
  echo "$2" | grep '^JSON=' | sed 's/^JSON=//' | python3 -c '
import json, sys
print(" ".join(json.load(sys.stdin)[sys.argv[1]]))' "$1" 2>/dev/null
}
# a running, STALE, notify_only_locked demand-dashboard — fixture shared by T71-T80
locked_dd_case() {  # locked_dd_case <case-name> <pid>
  new_case "$1"
  make_symbol_script "$RUNTIME"
  cat > "$RUNTIME/daemons/demand_dashboard.py" <<<'print("dd")'
  make_plist "$AGENTS" com.test.demand-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/demand_dashboard.py"
  seed_running com.test.demand-dashboard "$2" "$STALE_LSTART"
  # The inline comment mirrors the REAL restart_policy.yaml, whose entries carry
  # trailing prose (`- demand_dashboard.py    # hospeda o outreach_worker ... —
  # restart = halt de outreach`). If the subset YAML loader kept that prose, the
  # basename would never match and the daemon would silently NOT read as locked —
  # so the fixture must exercise the real syntax, not a tidied-up copy of it.
  cat > "$RUNTIME/daemons/restart_policy.yaml" <<'EOF'
auto:
  - chip_kpi_dashboard.py   # KPI dashboard, safe to bounce
notify_only_locked:
  - demand_dashboard.py    # hospeda o outreach_worker in-process — restart = halt de outreach
EOF
}
DD=com.test.demand-dashboard

# T71 — THE REPRO: locked + cleanly no-evidence -> named cosmetic.
SENSITIVE_DAEMONS="central-sender"
locked_dd_case t71 71001
seed_symbol_result daemons/demand_dashboard.py no_evidence
OUT=$(run_helper daemons/demand_dashboard.py); RC=$?
[ "$(field VERDICT "$OUT")" = "NEEDS_GUARDED_RESTART" ] && ok "T71 verdict stays NEEDS_GUARDED_RESTART (this layer annotates, never changes it)" || nok "T71 verdict" "got '$(field VERDICT "$OUT")' out=[$OUT]"
[ "$(field GUARDED "$OUT")" = "$DD" ] && ok "T71 flat GUARDED unchanged (the daemon is still stale)" || nok "T71 guarded" "$(field GUARDED "$OUT")"
[ "$(field GUARDED_SYMBOL_NO_EVIDENCE "$OUT")" = "$DD" ] && ok "T71 lands in GUARDED_SYMBOL_NO_EVIDENCE" || nok "T71 no_evidence" "$(field GUARDED_SYMBOL_NO_EVIDENCE "$OUT")"
[ "$(field GUARDED_LOCKED_COSMETIC "$OUT")" = "$DD" ] && ok "T71 GUARDED_LOCKED_COSMETIC names the locked + no-evidence daemon" || nok "T71 locked_cosmetic" "got '$(field GUARDED_LOCKED_COSMETIC "$OUT")' — the field is missing or wrong"
echo "$(field REASON "$OUT")" | grep "TRAVA HUMANA SEM EVIDÊNCIA" >/dev/null && ok "T71 REASON renders a TRAVA HUMANA SEM EVIDÊNCIA section" || nok "T71 reason" "$(field REASON "$OUT")"
[ "$(json_list guarded_locked_cosmetic "$OUT")" = "$DD" ] && ok "T71 trailing JSON guarded_locked_cosmetic matches the KEY=value line" || nok "T71 json" "got '$(json_list guarded_locked_cosmetic "$OUT")'"
! grep -q "$DD" "$MOCK/kicks.log" 2>/dev/null && ok "T71 the locked daemon was NOT bounced" || nok "T71 no-bounce" "kickstart was called: $(cat "$MOCK/kicks.log" 2>/dev/null)"

# T72 — CONTROL (acceptance 2): locked but the symbol IS reached -> must NOT be cosmetic.
locked_dd_case t72 72001
seed_symbol_result daemons/demand_dashboard.py confirmed
OUT=$(run_helper daemons/demand_dashboard.py)
echo "$OUT" | grep '^GUARDED_LOCKED_COSMETIC=$' >/dev/null && ok "T72 GUARDED_LOCKED_COSMETIC is present and empty (present-even-empty contract)" || nok "T72 line" "missing or non-empty: '$(field GUARDED_LOCKED_COSMETIC "$OUT")' present=$(echo "$OUT" | grep -c '^GUARDED_LOCKED_COSMETIC=')"
[ "$(field GUARDED_SYMBOL_CONFIRMED "$OUT")" = "$DD" ] && ok "T72 stays SYMBOL-CONFIRMED — a real stale is never demoted" || nok "T72 confirmed" "$(field GUARDED_SYMBOL_CONFIRMED "$OUT")"
echo "$(field REASON "$OUT")" | grep "TRAVA HUMANA SEM EVIDÊNCIA" >/dev/null && nok "T72 REASON wrongly renders the cosmetic section" "$(field REASON "$OUT")" || ok "T72 REASON has no cosmetic section"

# T73 — CONTROL (acceptance 3): the calculator never answered for it -> NOT COMPUTED, never cosmetic.
locked_dd_case t73 73001
seed_symbol_result daemons/demand_dashboard.py missing
OUT=$(run_helper daemons/demand_dashboard.py)
echo "$OUT" | grep '^GUARDED_LOCKED_COSMETIC=$' >/dev/null && ok "T73 GUARDED_LOCKED_COSMETIC present and empty" || nok "T73 line" "present=$(echo "$OUT" | grep -c '^GUARDED_LOCKED_COSMETIC=') value='$(field GUARDED_LOCKED_COSMETIC "$OUT")'"
[ "$(field GUARDED_SYMBOL_NOT_COMPUTED "$OUT")" = "$DD" ] && ok "T73 lands in GUARDED_SYMBOL_NOT_COMPUTED" || nok "T73 not_computed" "$(field GUARDED_SYMBOL_NOT_COMPUTED "$OUT")"

# T74 — CONTROL: cleanly no-evidence but NOT locked (a restartable daemon) -> unchanged, never cosmetic.
SENSITIVE_DAEMONS="central-sender"
new_case t74
make_symbol_script "$RUNTIME"
cat > "$RUNTIME/daemons/central_sender.py" <<<'print("send")'
make_plist "$AGENTS" com.test.central-sender "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/central_sender.py"
seed_running com.test.central-sender 74001 "$STALE_LSTART"
cat > "$RUNTIME/daemons/restart_policy.yaml" <<'EOF'
notify_only_locked:
  - demand_dashboard.py
EOF
seed_symbol_result daemons/central_sender.py no_evidence
OUT=$(run_helper daemons/central_sender.py)
echo "$OUT" | grep '^GUARDED_LOCKED_COSMETIC=$' >/dev/null && ok "T74 GUARDED_LOCKED_COSMETIC present and empty" || nok "T74 line" "present=$(echo "$OUT" | grep -c '^GUARDED_LOCKED_COSMETIC=') value='$(field GUARDED_LOCKED_COSMETIC "$OUT")'"
[ "$(field GUARDED_SYMBOL_NO_EVIDENCE "$OUT")" = "com.test.central-sender" ] && ok "T74 still classified NO_EVIDENCE (only the cosmetic subset needs the lock)" || nok "T74 no_evidence" "$(field GUARDED_SYMBOL_NO_EVIDENCE "$OUT")"

# T75 — the entrypoint failed to PARSE: "reaches=False por padrão seguro" is a
# could-not-evaluate. It must be NOT COMPUTED, not no-evidence (RED before this bead).
locked_dd_case t75 75001
seed_symbol_result daemons/demand_dashboard.py no_evidence_syntax_error
OUT=$(run_helper daemons/demand_dashboard.py)
echo "$OUT" | grep '^GUARDED_LOCKED_COSMETIC=$' >/dev/null && ok "T75 GUARDED_LOCKED_COSMETIC present and empty" || nok "T75 line" "present=$(echo "$OUT" | grep -c '^GUARDED_LOCKED_COSMETIC=') value='$(field GUARDED_LOCKED_COSMETIC "$OUT")'"
[ -z "$(field GUARDED_SYMBOL_NO_EVIDENCE "$OUT")" ] && ok "T75 an unparseable entrypoint is NOT reported as 'no evidence'" || nok "T75 no_evidence" "unevaluable label collapsed into no-evidence: '$(field GUARDED_SYMBOL_NO_EVIDENCE "$OUT")'"
[ "$(field GUARDED_SYMBOL_NOT_COMPUTED "$OUT")" = "$DD" ] && ok "T75 an unparseable entrypoint lands in NOT_COMPUTED" || nok "T75 not_computed" "$(field GUARDED_SYMBOL_NOT_COMPUTED "$OUT")"

# T76 — the ONE benign warning (a closure file absent at --after: added later, or
# deleted) leaves the answer trustworthy. Without this the feature would only
# ever release the story at the tip of the runtime, and never a bead merged
# before a later commit added a file to the closure JSON.
locked_dd_case t76 76001
seed_symbol_result daemons/demand_dashboard.py no_evidence_benign_warning
OUT=$(run_helper daemons/demand_dashboard.py)
[ "$(field GUARDED_SYMBOL_NO_EVIDENCE "$OUT")" = "$DD" ] && ok "T76 benign 'ausente em --after — ignorado' still counts as no-evidence" || nok "T76 no_evidence" "$(field GUARDED_SYMBOL_NO_EVIDENCE "$OUT")"
[ "$(field GUARDED_LOCKED_COSMETIC "$OUT")" = "$DD" ] && ok "T76 ...and is cosmetic (a later-added closure file must not defeat the release)" || nok "T76 locked_cosmetic" "got '$(field GUARDED_LOCKED_COSMETIC "$OUT")'"

# T77 — the ENTRYPOINT itself is absent at --after ("não dá pra avaliar") even
# though a benign warning is ALSO present: any non-benign warning disqualifies.
locked_dd_case t77 77001
seed_symbol_result daemons/demand_dashboard.py no_evidence_unevaluable
OUT=$(run_helper daemons/demand_dashboard.py)
echo "$OUT" | grep '^GUARDED_LOCKED_COSMETIC=$' >/dev/null && ok "T77 GUARDED_LOCKED_COSMETIC present and empty" || nok "T77 line" "present=$(echo "$OUT" | grep -c '^GUARDED_LOCKED_COSMETIC=') value='$(field GUARDED_LOCKED_COSMETIC "$OUT")'"
[ "$(field GUARDED_SYMBOL_NOT_COMPUTED "$OUT")" = "$DD" ] && ok "T77 'não dá pra avaliar' lands in NOT_COMPUTED even alongside a benign warning" || nok "T77 not_computed" "$(field GUARDED_SYMBOL_NOT_COMPUTED "$OUT")"

# T78 — a CLOSURE file failed the structural diff (its changed symbols were
# dropped): a false negative is possible, so it cannot be trusted as no-evidence.
locked_dd_case t78 78001
seed_symbol_result daemons/demand_dashboard.py no_evidence_closure_syntax_error
OUT=$(run_helper daemons/demand_dashboard.py)
echo "$OUT" | grep '^GUARDED_LOCKED_COSMETIC=$' >/dev/null && ok "T78 GUARDED_LOCKED_COSMETIC present and empty" || nok "T78 line" "present=$(echo "$OUT" | grep -c '^GUARDED_LOCKED_COSMETIC=') value='$(field GUARDED_LOCKED_COSMETIC "$OUT")'"
[ "$(field GUARDED_SYMBOL_NOT_COMPUTED "$OUT")" = "$DD" ] && ok "T78 a dropped closure diff lands in NOT_COMPUTED" || nok "T78 not_computed" "$(field GUARDED_SYMBOL_NOT_COMPUTED "$OUT")"

# T79 — a calculator that predates the "warnings" field: cleanliness cannot be
# verified, so it is never trusted (absent != empty).
locked_dd_case t79 79001
seed_symbol_result daemons/demand_dashboard.py no_evidence_nowarnkey
OUT=$(run_helper daemons/demand_dashboard.py)
echo "$OUT" | grep '^GUARDED_LOCKED_COSMETIC=$' >/dev/null && ok "T79 GUARDED_LOCKED_COSMETIC present and empty" || nok "T79 line" "present=$(echo "$OUT" | grep -c '^GUARDED_LOCKED_COSMETIC=') value='$(field GUARDED_LOCKED_COSMETIC "$OUT")'"
[ "$(field GUARDED_SYMBOL_NOT_COMPUTED "$OUT")" = "$DD" ] && ok "T79 a result with no 'warnings' key lands in NOT_COMPUTED" || nok "T79 not_computed" "$(field GUARDED_SYMBOL_NOT_COMPUTED "$OUT")"

# T80 — restart_policy.yaml EXISTS but is unreadable: we cannot know the daemon is
# locked, so nothing may be called cosmetic (same fail-closed rule as T13).
locked_dd_case t80 80001
printf '\xff\xfenotify_only_locked:\n  - demand_dashboard.py\n' > "$RUNTIME/daemons/restart_policy.yaml"
seed_symbol_result daemons/demand_dashboard.py no_evidence
OUT=$(run_helper daemons/demand_dashboard.py)
echo "$OUT" | grep '^GUARDED_LOCKED_COSMETIC=$' >/dev/null && ok "T80 unreadable policy: GUARDED_LOCKED_COSMETIC present and empty (cannot prove locked)" || nok "T80 line" "present=$(echo "$OUT" | grep -c '^GUARDED_LOCKED_COSMETIC=') value='$(field GUARDED_LOCKED_COSMETIC "$OUT")'"
[ "$(field GUARDED "$OUT")" = "$DD" ] && ok "T80 still GUARDED (fails closed to sensitive)" || nok "T80 guarded" "$(field GUARDED "$OUT")"

# T81 — a MIXED batch: only the locked + cleanly-no-evidence one is cosmetic.
new_case t81
make_symbol_script "$RUNTIME"
cat > "$RUNTIME/daemons/demand_dashboard.py" <<<'print("dd")'
cat > "$RUNTIME/daemons/campaign_dashboard.py" <<<'print("cd")'
cat > "$RUNTIME/daemons/central_sender.py" <<<'print("send")'
make_plist "$AGENTS" com.test.demand-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/demand_dashboard.py"
make_plist "$AGENTS" com.test.campaign-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/campaign_dashboard.py"
make_plist "$AGENTS" com.test.central-sender "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/central_sender.py"
seed_running com.test.demand-dashboard 81001 "$STALE_LSTART"
seed_running com.test.campaign-dashboard 81101 "$STALE_LSTART"
seed_running com.test.central-sender 81201 "$STALE_LSTART"
cat > "$RUNTIME/daemons/restart_policy.yaml" <<'EOF'
notify_only_locked:
  - demand_dashboard.py
  - campaign_dashboard.py
EOF
seed_symbol_result daemons/demand_dashboard.py no_evidence
seed_symbol_result daemons/campaign_dashboard.py confirmed
seed_symbol_result daemons/central_sender.py no_evidence
SENSITIVE_DAEMONS="central-sender"
OUT=$(run_helper daemons/demand_dashboard.py daemons/campaign_dashboard.py daemons/central_sender.py)
SENSITIVE_DAEMONS="central-sender"
[ "$(field GUARDED_LOCKED_COSMETIC "$OUT")" = "com.test.demand-dashboard" ] && ok "T81 cosmetic = ONLY the locked + no-evidence daemon (not the locked+confirmed, not the unlocked+no-evidence)" || nok "T81 locked_cosmetic" "got '$(field GUARDED_LOCKED_COSMETIC "$OUT")' guarded='$(field GUARDED "$OUT")'"
[ "$(json_list guarded_locked_cosmetic "$OUT")" = "com.test.demand-dashboard" ] && ok "T81 JSON agrees" || nok "T81 json" "got '$(json_list guarded_locked_cosmetic "$OUT")'"
for l in com.test.demand-dashboard com.test.campaign-dashboard com.test.central-sender; do
  echo "$(field GUARDED "$OUT")" | grep "$l" >/dev/null && ok "T81 $l still in flat GUARDED" || nok "T81 guarded $l" "$(field GUARDED "$OUT")"
done

# T82 — an entrypoint explicitly allow-listed for automatic restart (deploy_restart)
# is NOT locked even if it is ALSO (contradictorily) listed notify_only_locked: the
# same "explicitly safe first" precedence policy_says_sensitive() applies. A daemon
# automation CAN restart is not stuck forever, so it is never cosmetic-locked.
locked_dd_case t82 82001
cat > "$RUNTIME/daemons/restart_policy.yaml" <<'EOF'
deploy_restart:
  - demand_dashboard.py
notify_only_locked:
  - demand_dashboard.py
EOF
seed_symbol_result daemons/demand_dashboard.py no_evidence
SENSITIVE_DAEMONS="demand-dashboard"
OUT=$(run_helper daemons/demand_dashboard.py)
SENSITIVE_DAEMONS="central-sender"
echo "$OUT" | grep '^GUARDED_LOCKED_COSMETIC=$' >/dev/null && ok "T82 an allow-listed entrypoint is not cosmetic-locked (explicitly-safe precedence)" || nok "T82 line" "present=$(echo "$OUT" | grep -c '^GUARDED_LOCKED_COSMETIC=') value='$(field GUARDED_LOCKED_COSMETIC "$OUT")' guarded='$(field GUARDED "$OUT")'"

# T83 — present-even-empty on a verdict that has no guarded daemon at all (every
# other emit path): a consumer can read the field unconditionally.
new_case t83
cat > "$RUNTIME/daemons/foo_dashboard.py" <<<'print("foo")'
make_plist "$AGENTS" com.test.foo-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/foo_dashboard.py"
seed_running com.test.foo-dashboard 83001 "$STALE_LSTART"
OUT=$(run_helper README.md)
echo "$OUT" | grep '^GUARDED_LOCKED_COSMETIC=$' >/dev/null && ok "T83 GUARDED_LOCKED_COSMETIC is present even when empty, on an OK verdict" || nok "T83 line" "present=$(echo "$OUT" | grep -c '^GUARDED_LOCKED_COSMETIC=')"
[ "$(echo "$OUT" | grep '^JSON=' | sed 's/^JSON=//' | python3 -c 'import json,sys; print(json.load(sys.stdin).get("guarded_locked_cosmetic"))' 2>/dev/null)" = "[]" ] && ok "T83 trailing JSON carries guarded_locked_cosmetic: []" || nok "T83 json" "key missing or wrong"

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo "daemon-refresh tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
