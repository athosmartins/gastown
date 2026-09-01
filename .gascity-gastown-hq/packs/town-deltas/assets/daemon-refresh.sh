#!/usr/bin/env bash
# daemon-refresh.sh — post-deploy daemon refresh + freshness verification (ga-iwv0).
#
# THE BUG (ga-iwv0): the story-delivery deploy step is effectively `git pull`.
# It updates files on disk but does NOT restart long-lived launchd daemons, so a
# daemon-side feature merged into an already-running process stays DORMANT until
# that process happens to restart for some other reason — while the story is
# marked story:done. (ga-d81: com.whatsapp.ban-risk-dashboard served 5-day-old
# code; every new endpoint 404'd until an ops agent kickstarted it.)
#
# THIS HELPER closes the gap. Called by story-delivery.sh AFTER a deploy, given
# the pre/post deploy SHAs and the deploy timestamp, it:
#   1. Computes the source files the deploy actually changed (git diff).
#   2. Discovers the rig's long-lived launchd daemons from their plists
#      (ProgramArguments → the .py entrypoint it runs, following wrapper .sh).
#   3. Marks a daemon AFFECTED when its entrypoint changed, when a changed
#      shared module (routes/*.py, lib/*.py, …) is imported by its entrypoint
#      (the exact ga-d81 dashboard-mounts-route scenario), OR when a changed
#      Jinja template (*.html/*.htm/*.jinja/*.jinja2/*.j2) is rendered by its
#      entrypoint via render_template(...) — templates are compiled and cached
#      in-process (TEMPLATES_AUTO_RELOAD off in prod), so a disk-only template
#      edit was otherwise invisible here (ga-jkj0: com.whatsapp.map-viewer
#      served a stale layout twice despite "deployed + verified").
#   4. SAFE daemons (read-only dashboards): kickstart -k, then VERIFY the new
#      process actually started AFTER the deploy timestamp. A daemon that stays
#      stale (restart did not take / crash-loop) FAILS verification.
#   5. SENSITIVE hot-path daemons (central_sender, webhook_receiver,
#      slot_scheduler, conversation_monitor — matched via SENSITIVE_DAEMONS):
#      NEVER auto-bounced (in-flight messages/webhooks must be drained first).
#      They are FLAGGED for a guarded restart unless a DRAIN_CMD_<label> is
#      provided, in which case drain → kickstart → verify.
#   6. (ga-ylr2m) SENSITIVE_DAEMONS is a small, hand-maintained substring list
#      — the exact registry-drift gap this closes: it silently auto-kickstarted
#      frota_dashboard/demand_dashboard/campaign_dashboard, all notify_only_
#      locked or vetoed for a physical or in-flight-state reason in WA's own
#      restart_policy.yaml, because nobody had copied their names here yet.
#      When the rig ships that file at $RUNTIME_DIR/daemons/restart_policy.yaml
#      (e.g. whatsapp_automation), it is consulted DIRECTLY: a daemon whose
#      .py entrypoint is not explicitly listed under that file's 'auto'/
#      'deploy_restart' allowlists is ALSO treated SENSITIVE here — matching
#      the policy file's own documented default ("unlisted = manual"),
#      instead of requiring a human to keep a second copy of the same list in
#      sync. SENSITIVE_DAEMONS and the policy file are a UNION (either source
#      calling a daemon sensitive makes it sensitive) — this only ever ADDS
#      scrutiny, never removes it, and a rig with no restart_policy.yaml
#      behaves identically to before. Independently, any daemon named in that
#      file's 'restart_guard_scripts:' has its guard script consulted
#      immediately before EVERY kickstart of it (SAFE or drained-SENSITIVE) —
#      this script was a 4th, previously-unguarded restart trigger alongside
#      WA's own three (deploy_daemons.sh's two loops + auto_restart_daemons.py's
#      deploy_restart branch), closing the classification_dashboard
#      send-in-flight gap for this trigger too.
#   7. (ga-j3j6s; refined ga-puq8z) Before flagging a SENSITIVE daemon at all
#      (drain path or not), check whether its CURRENT live process already
#      started after the code was COMMITTED (COMMIT_EPOCH — the committer date
#      of POST_DEPLOY_SHA, computed near Step 1 below) — the same pid-start
#      primitives verify_fresh() uses to confirm a restart THIS script
#      performed, just compared against a different reference point. If it's
#      already fresh, some OTHER mechanism (e.g. the rig's own auto-deploy, or
#      a sibling bead's own guarded restart on the same shared daemon) already
#      restarted it; flagging NEEDS_GUARDED_RESTART here is a false positive
#      that pushes a human toward an unnecessary, non-zero-risk hot-path
#      restart (real incident: com.whatsapp.map-viewer flagged ~1m45s after
#      auto-deploy had already restarted it and was serving the new template).
#      Deliberately NOT a file-mtime comparison — a daemon can serve from a
#      different tree than the changed file, which would make an mtime check
#      lie; a pid-start-epoch is a process-clock timestamp, compared only
#      against the live PID's own start time (never a file path).
#      ga-puq8z GATE-FIX: the ga-j3j6s original compared against DEPLOY_EPOCH
#      (this check's OWN "now", captured by the CALLER right before its
#      deploy step) rather than COMMIT_EPOCH. DEPLOY_EPOCH can be minutes-to-
#      hours after the commit itself (gate-queue wait, deploy retry/backoff —
#      ga-d5rrr — or just a slow sweep cycle), and any restart that already
#      happened via another path is, by construction, always BEFORE "now" —
#      so the DEPLOY_EPOCH-only comparison was nearly impossible to satisfy
#      and under-caught exactly the case point 7 exists to catch (measured
#      2026-09-01: com.whatsapp.demand-dashboard flagged twice in 15 minutes,
#      both times already running code newer than the commit each check was
#      verifying). COMMIT_EPOCH <= DEPLOY_EPOCH always holds, so this only
#      ever ADDS true-fresh detections — never masks a real stale daemon.
#   8. (ga-y108i) Complementary to point 7's "is the PROCESS fresh?" question:
#      "does this CHANGE need a restart AT ALL?" A rig can declare, in its own
#      restart_policy.yaml, a global no_restart_paths: [glob, ...] list (e.g.
#      ["daemons/static/**"]) naming paths a daemon re-reads from disk on
#      EVERY request — a live process serving one is never stale, so its age
#      is irrelevant (real incident: a commit touching only daemons/static/
#      demand_previsao.js flagged the SENSITIVE demand-dashboard daemon for a
#      guarded restart; verified by hand that the live-served md5 already
#      matched the merged blob under the pre-merge PID — restarting would have
#      changed nothing). Checked FIRST, against the FULL raw changed-file set
#      (Step 1, before the *.py/template split below) — when EVERY changed
#      file matches a declared glob, this emits OK/asset_served_per_request
#      immediately, before daemon discovery or SENSITIVE/GUARDED classification
#      ever run. Path-based, deliberately NOT extension- or directory-guessed:
#      a *.py helper can be just as exemptable as a *.js file if the RIG says
#      so (e.g. a module that only proxies static bytes), and the reverse
#      holds too — this same rig's templates/ genuinely DOES need a restart
#      (Jinja is compiled+cached at import, point 3/ga-jkj0), so a
#      no_restart_paths glob covering only static/ must never accidentally
#      swallow templates/. A partially-covered changed set (even one file
#      outside every declared glob) does NOT exempt anything — falls straight
#      through to today's classification. An undeclared/absent key is a pure
#      no-op: identical to pre-ga-y108i behavior.
#
# VERDICT (last-resort gate): the caller must NOT mark a story:done unless the
# verdict is OK/SKIPPED. A dormant or unverifiable daemon halts delivery.
#
# PROOF (ga-vmq1i): VERDICT=OK/SKIPPED collapses two very different situations
# — "we positively confirmed a live daemon came up fresh" and "we never
# actually confirmed anything is running the new code" — into the same green
# light. The caller used to phrase BOTH as "deployed + verified in prod",
# which is a false claim for the second case. PROOF disambiguates:
#   verified       — a live daemon was confirmed running code from after
#                     DEPLOY_EPOCH: either restarted by THIS script and then
#                     confirmed fresh, or (ga-j3j6s) already running fresh via
#                     some OTHER restart path (e.g. the rig's own auto-deploy)
#                     — same positive pid-start-epoch confirmation either way.
#   not_applicable — structurally certain there was nothing live to verify
#                     (no source changed, no rig daemons exist at all, or the
#                     only daemon(s) tied to the change have no live PID to
#                     begin with — e.g. a scheduled job, not a dormant one).
#   asset_served_per_request (ga-y108i) — a stronger, path-proven refinement
#                     of not_applicable: every changed file matched a
#                     rig-declared restart_policy.yaml no_restart_paths glob
#                     (header point 8), so the content is structurally proven
#                     safe rather than merely un-flagged by extension. Callers
#                     must treat it identically to verified/not_applicable
#                     (never as not_verified) — see story-delivery.sh and
#                     quality-gate-dispatcher.sh's own PROOF case arms.
#   not_verified   — everything else: environment prevented checking (not a
#                     git work tree), or changed code could not be confidently
#                     tied to any live daemon by this script's (documented,
#                     single-hop) detection — which is NOT the same as
#                     confidently ruled out. Default when unset — fail closed.
#
# Output: machine-readable key=value lines + a trailing JSON object on STDOUT;
# all human logging goes to STDERR.
#   VERDICT=OK|SKIPPED|VERIFY_FAILED|NEEDS_GUARDED_RESTART
#   AFFECTED=<labels>   RESTARTED=<labels>   FRESH_FAIL=<labels>   GUARDED=<labels>
#   WOULD_RESTART=<labels>   (ga-omfwe: DRY_RUN=1 only — labels that would be
#     restarted for real; RESTARTED is always empty under DRY_RUN=1, so the
#     two never collapse into the same string)
#   REASON=<text>   PROOF=verified|not_applicable|asset_served_per_request|not_verified
# Exit 0 when VERDICT is OK/SKIPPED (or DRY_RUN=1); non-zero otherwise.
#
# Inputs (env):
#   RUNTIME_DIR       deployed git work tree (e.g. /Users/athos/gt/whatsapp_automation)
#                     (ga-ylr2m) if $RUNTIME_DIR/daemons/restart_policy.yaml
#                     exists, it is consulted directly — see header point 6
#                     (and point 8/ga-y108i for its no_restart_paths key).
#   PRE_DEPLOY_SHA    HEAD before deploy
#   POST_DEPLOY_SHA   HEAD after deploy
#   DEPLOY_EPOCH      unix epoch captured immediately before deploy
#   SENSITIVE_DAEMONS space/newline-separated launchd-label substrings (hot-path)
#   EXTRA_RUNTIME_ROOTS (ga-00ptz) space/newline-separated absolute paths of
#                     OTHER independently-deployed clones of this same rig's
#                     repo (e.g. painel-prod, a hand-synced second checkout of
#                     whatsapp_automation kept fresh by its own deploy-sync
#                     job, not by this pipeline's git-pull). A plist entrypoint
#                     under one of these is resolved to the relpath it shares
#                     with RUNTIME_DIR — see resolve_relpath() — so a daemon
#                     running from a second clone of the SAME source is still
#                     discovered. Never invents an entrypoint: the relpath must
#                     also actually exist under RUNTIME_DIR. Empty = none
#                     (identical to pre-ga-00ptz behavior).
#   DRY_RUN           1 = report only, no kickstart/verify (default 0)
#   DRAIN_CMD_<label> optional graceful-drain command for a sensitive daemon
#                     (<label> sanitized: non-alnum → _)
# Test seams:
#   LAUNCH_AGENTS_DIR (default $HOME/Library/LaunchAgents)
#   LAUNCHCTL_BIN     (default launchctl)
#   PS_BIN            (default ps)
#   VERIFY_TIMEOUT    seconds to wait for a fresh process (default 20)
#   VERIFY_INTERVAL   poll interval seconds (default 1)

set -uo pipefail

RUNTIME_DIR="${RUNTIME_DIR:-}"
PRE_DEPLOY_SHA="${PRE_DEPLOY_SHA:-}"
POST_DEPLOY_SHA="${POST_DEPLOY_SHA:-}"
DEPLOY_EPOCH="${DEPLOY_EPOCH:-0}"
SENSITIVE_DAEMONS="${SENSITIVE_DAEMONS:-}"
EXTRA_RUNTIME_ROOTS="${EXTRA_RUNTIME_ROOTS:-}"
DRY_RUN="${DRY_RUN:-0}"
LAUNCH_AGENTS_DIR="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-launchctl}"
PS_BIN="${PS_BIN:-ps}"
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-20}"
VERIFY_INTERVAL="${VERIFY_INTERVAL:-1}"

log() { echo "[daemon-refresh] $*" >&2; }

# ── restart_policy.yaml consultation (ga-ylr2m) ───────────────────────────────
# See header point 6. Parsed once, up front, into space-separated .py-basename
# lists (POLICY_AUTO / POLICY_DEPLOY_RESTART / POLICY_NOTIFY_ONLY_LOCKED) plus
# a "daemon.py=script/relpath" pair list (POLICY_GUARDS) plus a space-separated
# glob-pattern list (POLICY_NO_RESTART_PATHS — ga-y108i, header point 8).
# Three distinct states,
# kept distinct on purpose (self-audit finding — "not found" and "found but
# unreadable" must NOT collapse to the same value just because both end up with
# empty POLICY_* lists):
#   no file at all       → RESTART_POLICY_YAML doesn't exist. This rig genuinely
#                           has no stricter registry; defer entirely to
#                           SENSITIVE_DAEMONS, IDENTICAL to pre-ga-ylr2m behavior.
#   file exists, parses  → POLICY_PARSE_OK=1. Empty lists here are a REAL "this
#                           policy clears nothing", handled correctly by
#                           policy_says_sensitive()'s normal per-entrypoint logic.
#   file exists, does
#   NOT parse (rare —
#   e.g. a future edit
#   breaks this subset
#   parser's assumptions) → POLICY_PARSE_OK stays unset even though the file is
#                           present. We cannot prove this rig has nothing extra
#                           to be careful about — the third state — so
#                           policy_says_sensitive()/guard_allows_restart() below
#                           treat this as "everything on this rig is sensitive
#                           and every restart is refused" until the file parses
#                           again. This can only ADD caution vs. the no-file
#                           case, never silently fall back to it.
RESTART_POLICY_YAML="$RUNTIME_DIR/daemons/restart_policy.yaml"
POLICY_AUTO=""; POLICY_DEPLOY_RESTART=""; POLICY_NOTIFY_ONLY_LOCKED=""; POLICY_GUARDS=""; POLICY_NO_RESTART_PATHS=""; POLICY_PARSE_OK=""
if [ -f "$RESTART_POLICY_YAML" ]; then
  eval "$(python3 - "$RESTART_POLICY_YAML" <<'PY' 2>/dev/null
import re, shlex, sys

def scalar(v):
    v = v.strip()
    if v[:1] in "'\"" and v[-1:] == v[:1]:
        return v[1:-1]
    low = v.lower()
    if low in ("true", "false"):
        return low == "true"
    if low in ("null", "~", ""):
        return None
    if low == "{}":
        return {}
    if re.fullmatch(r"-?\d+", v):
        return int(v)
    return v

def load_policy(path):
    # Subset-YAML reader mirroring whatsapp_automation/scripts/
    # lint_restart_policy.py's load_policy(): top-level 'k: v', '- item'
    # lists, indented 'k: v' nested dicts; full-line and trailing ' #'
    # comments stripped. Keep the two in sync if that file's supported
    # subset ever changes — this is a deliberate, documented duplication of
    # a small (~30-line) already-reviewed parser, not a second design.
    out = {}
    cur_key = None
    cur_kind = None  # 'list' | 'dict'
    for raw in open(path, encoding="utf-8"):
        line = raw.split(" #", 1)[0].rstrip() if " #" in raw else raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indented = line[0] in " \t"
        s = line.strip()
        if not indented:
            key, _, val = s.partition(":")
            key = key.strip()
            if val.strip() == "":
                out[key], cur_key, cur_kind = None, key, None
            else:
                out[key], cur_key, cur_kind = scalar(val), None, None
        elif s.startswith("- "):
            if cur_kind != "list":
                out[cur_key], cur_kind = [], "list"
            out[cur_key].append(scalar(s[2:]))
        else:
            if cur_kind != "dict":
                out[cur_key], cur_kind = {}, "dict"
            k, _, v = s.partition(":")
            out[cur_key][k.strip()] = scalar(v)
    return out

try:
    policy = load_policy(sys.argv[1])
except Exception:
    policy = None   # distinct from "parsed to an empty dict" — see bash comment above

def strlist(key):
    return " ".join(str(x) for x in (policy.get(key) or []) if isinstance(x, str))

# Only emit POLICY_* (including the OK marker) on a SUCCESSFUL parse. On
# failure this prints nothing at all, so the eval below is a no-op and every
# POLICY_* var (POLICY_PARSE_OK included) keeps its pre-set empty default —
# the signal bash checks for the unparseable third state.
if policy is not None:
    print("POLICY_AUTO=" + shlex.quote(strlist("auto")))
    print("POLICY_DEPLOY_RESTART=" + shlex.quote(strlist("deploy_restart")))
    print("POLICY_NOTIFY_ONLY_LOCKED=" + shlex.quote(strlist("notify_only_locked")))
    print("POLICY_NO_RESTART_PATHS=" + shlex.quote(strlist("no_restart_paths")))
    guards = policy.get("restart_guard_scripts") or {}
    if isinstance(guards, dict):
        pairs = " ".join(f"{d}={s}" for d, s in guards.items()
                          if isinstance(d, str) and isinstance(s, str))
        print("POLICY_GUARDS=" + shlex.quote(pairs))
    print("POLICY_PARSE_OK=1")
PY
)" 2>/dev/null || true
  if [ -z "$POLICY_PARSE_OK" ]; then
    log "WARN: $RESTART_POLICY_YAML exists but could not be parsed — cannot verify its content, so every daemon on this rig is treated as policy-sensitive and every guarded restart is refused until it parses again (fail closed, not silently ignored)."
  fi
fi

# ── emit result + exit ────────────────────────────────────────────────────────
emit() {  # emit <verdict> <reason> [<proof>]  (proof defaults to not_verified — fail closed)
  local verdict="$1" reason="$2" proof="${3:-not_verified}"
  echo "VERDICT=$verdict"
  echo "AFFECTED=${AFFECTED:-}"
  echo "RESTARTED=${RESTARTED:-}"
  echo "FRESH_FAIL=${FRESH_FAIL:-}"
  echo "GUARDED=${GUARDED:-}"
  echo "ALREADY_FRESH=${ALREADY_FRESH:-}"
  echo "WOULD_RESTART=${WOULD_RESTART:-}"
  echo "REASON=$reason"
  echo "PROOF=$proof"
  # Trailing JSON for the caller's bead comment / jsonl log.
  python3 - "$verdict" "$reason" "${AFFECTED:-}" "${RESTARTED:-}" "${FRESH_FAIL:-}" "${GUARDED:-}" "$proof" "${ALREADY_FRESH:-}" "${WOULD_RESTART:-}" <<'PY' 2>/dev/null || true
import json, sys
v, reason, aff, res, ff, gd, proof, afr, wr = sys.argv[1:10]
sp = lambda s: [x for x in s.split() if x]
print("JSON=" + json.dumps({
    "verdict": v, "reason": reason,
    "affected": sp(aff), "restarted": sp(res),
    "fresh_fail": sp(ff), "guarded": sp(gd), "proof": proof,
    "already_fresh": sp(afr), "would_restart": sp(wr),
}))
PY
  if [ "$DRY_RUN" = "1" ]; then exit 0; fi
  case "$verdict" in OK|SKIPPED) exit 0 ;; *) exit 1 ;; esac
}

AFFECTED=""; RESTARTED=""; FRESH_FAIL=""; GUARDED=""; ALREADY_FRESH=""; WOULD_RESTART=""

# ── preconditions ─────────────────────────────────────────────────────────────
if [ -z "$RUNTIME_DIR" ] || ! git -C "$RUNTIME_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log "runtime '$RUNTIME_DIR' is not a git work tree — skip (static daemon_restarts still apply)."
  emit SKIPPED "runtime not a git work tree" not_verified
fi
if [ -z "$PRE_DEPLOY_SHA" ] || [ -z "$POST_DEPLOY_SHA" ] || [ "$PRE_DEPLOY_SHA" = "$POST_DEPLOY_SHA" ]; then
  log "no SHA delta ($PRE_DEPLOY_SHA .. $POST_DEPLOY_SHA) — deploy changed nothing — skip."
  emit SKIPPED "no source change in deploy" not_applicable
fi

# ── commit-epoch (ga-puq8z) ─────────────────────────────────────────────────────
# The committer date of POST_DEPLOY_SHA — used below by already_fresh() as the
# freshness reference INSTEAD OF DEPLOY_EPOCH alone. DEPLOY_EPOCH is captured
# by the CALLER right before ITS OWN deploy step for THIS specific bead/story's
# check — which can be minutes-to-hours after the commit itself (gate-queue
# wait, deploy retry/backoff — ga-d5rrr, or simply a slow sweep cycle). A
# daemon already refreshed by some OTHER path in that gap has a pid-start
# strictly AFTER the commit but strictly BEFORE DEPLOY_EPOCH: genuinely
# fresh, but the DEPLOY_EPOCH-only comparison called that stale and flagged an
# unnecessary hot-path restart (measured 2026-09-01:
# com.whatsapp.demand-dashboard flagged twice within 15 minutes, both times
# already running code newer than the commit under review — ga-puq8z).
# COMMIT_EPOCH <= DEPLOY_EPOCH always holds (code cannot deploy before it is
# committed), so using it as the already_fresh() threshold only ever ADDS
# true-fresh detections — it never masks a real stale daemon the old
# DEPLOY_EPOCH-only check would have caught (see T27 in the test suite).
# Falls back to DEPLOY_EPOCH (the old, more conservative reference) if `git
# show` cannot produce a value — fail toward existing behavior, not toward a
# wider window, when the commit date is unverifiable.
COMMIT_EPOCH="$(git -C "$RUNTIME_DIR" show -s --format=%ct "$POST_DEPLOY_SHA" 2>/dev/null || true)"
case "$COMMIT_EPOCH" in ''|*[!0-9]*) COMMIT_EPOCH="$DEPLOY_EPOCH" ;; esac

# ── Step 1: changed files in this deploy ──────────────────────────────────────
CHANGED="$(git -C "$RUNTIME_DIR" diff --name-only "$PRE_DEPLOY_SHA" "$POST_DEPLOY_SHA" 2>/dev/null || true)"

# (ga-y108i, header point 8) no_restart_paths short-circuit — checked against
# the FULL raw changed set, before the *.py/template split below, so it also
# covers a *.py (or any other extension) file living under a declared path.
# Only engages when the rig's restart_policy.yaml declares the key AND
# parsed successfully (POLICY_NO_RESTART_PATHS stays "" on no file, an
# unparseable file, or an undeclared key — identical no-op in all three
# cases, matching "path not listed -> current behavior, no change").
if [ -n "${CHANGED// /}" ] && [ -n "${POLICY_NO_RESTART_PATHS// /}" ]; then
  changed_uncovered=""
  # POLICY_NO_RESTART_PATHS holds glob-pattern TEXT (e.g. "daemons/static/**")
  # meant to be split on spaces below — but left unquoted, bash also runs
  # pathname expansion on each split word against the process's ambient CWD
  # (never RUNTIME_DIR), so a CWD that happens to contain a matching subtree
  # silently swaps a real filename in for the pattern string and this
  # short-circuit fails to fire (gate-review finding on ga-y108i, T25).
  # `set -f` disables that expansion for the split only; the `case` pattern
  # match just below is unaffected either way — it is shell pattern matching
  # against a string, never filesystem globbing.
  set -f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    covered=0
    for pat in $POLICY_NO_RESTART_PATHS; do
      # shellcheck disable=SC2254  # deliberate glob match, not literal
      case "$f" in $pat) covered=1; break ;; esac
    done
    [ "$covered" -eq 1 ] || changed_uncovered="$changed_uncovered $f"
  done <<< "$CHANGED"
  set +f
  if [ -z "${changed_uncovered// /}" ]; then
    log "every changed file matches restart_policy.yaml's no_restart_paths — OK (content re-read from disk per request; no live process needs a restart)."
    emit OK "all changed files match declared no_restart_paths" asset_served_per_request
  fi
fi

CHANGED_PY="$(echo "$CHANGED" | grep -E '\.py$' || true)"
CHANGED_TEMPLATES="$(echo "$CHANGED" | grep -E '\.(html|htm|jinja2?|j2)$' || true)"
if [ -z "$CHANGED_PY" ] && [ -z "$CHANGED_TEMPLATES" ]; then
  log "deploy changed no *.py or template files — no daemon code affected — OK."
  emit OK "no python source or template changed" not_applicable
fi
log "changed python files:"; echo "$CHANGED_PY" | sed 's/^/[daemon-refresh]   /' >&2
log "changed template files:"; echo "$CHANGED_TEMPLATES" | sed 's/^/[daemon-refresh]   /' >&2

# helper: epoch of a pid's start time (parses `ps -o lstart=`)
pid_start_epoch() {  # pid_start_epoch <pid>
  local pid="$1" ls
  [ -n "$pid" ] || return 1
  ls="$($PS_BIN -o lstart= -p "$pid" 2>/dev/null)"
  ls="${ls%"${ls##*[![:space:]]}"}"   # rtrim trailing whitespace ps pads with
  [ -n "$ls" ] || return 1
  date -j -f "%a %b %e %T %Y" "$ls" +%s 2>/dev/null
}

# helper: current PID for a launchd label
daemon_pid() {  # daemon_pid <label>
  $LAUNCHCTL_BIN list "$1" 2>/dev/null \
    | awk -F'=' '/"PID"/ {gsub(/[^0-9]/,"",$2); print $2; exit}'
}

# ── Step 2: discover the rig's daemons + their entrypoint files ───────────────
# For each plist, read ProgramArguments. An arg under RUNTIME_DIR that is a .py
# file is an entrypoint; a wrapper .sh under RUNTIME_DIR is followed to the .py
# it execs. A plist with no entrypoint under RUNTIME_DIR is not a rig daemon.
plist_args() {  # plist_args <plist>; exit 0 (possibly empty output) when the
                 # plist parses but has no usable ProgramArguments, exit 1 when
                 # plistlib could not parse the file at all. The caller must be
                 # able to tell "not a rig daemon" apart from "could not tell"
                 # (ga-otn7u) — collapsing both into exit 0 is what made 5
                 # daemons permanently invisible to discovery.
  python3 - "$1" <<'PY' 2>/dev/null
import sys, plistlib
try:
    d = plistlib.load(open(sys.argv[1], 'rb'))
except Exception:
    sys.exit(1)
for a in (d.get('ProgramArguments') or []):
    print(a)
PY
}

# Resolve a (possibly $VAR-prefixed or absolute) .py token to a relpath that
# exists under RUNTIME_DIR; echoes nothing if it cannot be resolved.
resolve_relpath() {  # resolve_relpath <token>
  local t="$1" c root
  # absolute under runtime
  case "$t" in
    "$RUNTIME_DIR"/*) c="${t#"$RUNTIME_DIR"/}"; [ -f "$RUNTIME_DIR/$c" ] && { echo "$c"; return; } ;;
  esac
  # absolute under a configured EXTRA_RUNTIME_ROOTS entry (ga-00ptz): a second,
  # independently-deployed clone of this SAME rig's repo (e.g. painel-prod).
  # The relpath it shares with RUNTIME_DIR must also actually exist there —
  # this only grants visibility into a file genuinely present in both trees,
  # never invents an entrypoint out of thin air.
  for root in $EXTRA_RUNTIME_ROOTS; do
    case "$t" in
      "$root"/*) c="${t#"$root"/}"; [ -f "$RUNTIME_DIR/$c" ] && { echo "$c"; return; } ;;
    esac
  done
  # strip a leading shell-var segment: $BASEDIR/ ${WA_ROOT}/ etc.
  c="$(echo "$t" | sed -E 's#^.*\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/##')"
  [ -n "$c" ] && [ "$c" != "$t" ] && [ -f "$RUNTIME_DIR/$c" ] && { echo "$c"; return; }
  return 1
}

# label -> space-separated entrypoint relpaths (parallel arrays via temp files)
DISCO_DIR="$(mktemp -d "${TMPDIR:-/tmp}/daemon-disco.XXXXXX")"
trap 'rm -rf "$DISCO_DIR"' EXIT
DAEMON_LABELS=""
PARSE_ERROR_LABELS=""

shopt -s nullglob
for plist in "$LAUNCH_AGENTS_DIR"/*.plist; do
  label="$(basename "$plist" .plist)"
  entry=""
  args_out="$(plist_args "$plist")"; rc=$?
  if [ "$rc" -ne 0 ]; then
    log "WARN: $plist could not be parsed by plistlib — its daemon (if any) is invisible to auto-refresh discovery until the XML is fixed (common cause: a literal '--' inside an <!-- --> comment, which Apple's launchd parser tolerates but plistlib does not). Verify with: python3 -c \"import plistlib; plistlib.load(open('$plist','rb'))\""
    PARSE_ERROR_LABELS="$PARSE_ERROR_LABELS $label"
  fi
  while IFS= read -r arg; do
    [ -n "$arg" ] || continue
    case "$arg" in
      *.py)
        rel="$(resolve_relpath "$arg" || true)"
        [ -n "$rel" ] && entry="$entry $rel"
        ;;
      *.sh)
        # wrapper under runtime → follow to the .py it execs
        wrel="$(resolve_relpath "$arg" || true)"
        if [ -n "$wrel" ]; then
          while IFS= read -r tok; do
            prel="$(resolve_relpath "$tok" || true)"
            [ -n "$prel" ] && entry="$entry $prel"
          done < <(grep -oE '[^"[:space:]]+\.py' "$RUNTIME_DIR/$wrel" 2>/dev/null || true)
        fi
        ;;
    esac
  done <<< "$args_out"
  entry="$(echo "$entry" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
  [ -n "${entry// /}" ] || continue
  echo "$entry" > "$DISCO_DIR/$label"
  DAEMON_LABELS="$DAEMON_LABELS $label"
done
shopt -u nullglob

if [ -n "${PARSE_ERROR_LABELS// /}" ]; then
  log "WARN: $(echo "$PARSE_ERROR_LABELS" | wc -w | tr -d ' ') plist(s) could not be parsed and were skipped during discovery:$PARSE_ERROR_LABELS"
fi

if [ -z "${DAEMON_LABELS// /}" ]; then
  if [ -n "${PARSE_ERROR_LABELS// /}" ]; then
    log "no rig daemons discovered under $LAUNCH_AGENTS_DIR for runtime $RUNTIME_DIR, but discovery could not read every plist — this is incomplete, not a confirmed-empty scan (see WARNs above)."
    emit OK "no rig daemons discovered but discovery incomplete (unparseable plists — see WARNs)" not_verified
  fi
  log "no rig daemons discovered under $LAUNCH_AGENTS_DIR for runtime $RUNTIME_DIR — OK (nothing to refresh)."
  emit OK "no rig daemons discovered" not_applicable
fi

# precompute changed basenames + stems for matching
CHANGED_BASENAMES="$(echo "$CHANGED_PY" | while read -r f; do [ -n "$f" ] && basename "$f"; done)"
CHANGED_STEMS="$(echo "$CHANGED_BASENAMES" | sed 's/\.py$//' | grep -v '^$' || true)"
CHANGED_TEMPLATE_BASENAMES="$(echo "$CHANGED_TEMPLATES" | while read -r f; do [ -n "$f" ] && basename "$f"; done)"

# is_sensitive <label>
is_sensitive() {
  local label="$1" sub
  for sub in $SENSITIVE_DAEMONS; do
    [ -n "$sub" ] || continue
    case "$label" in *"$sub"*) return 0 ;; esac
  done
  return 1
}

# policy_says_sensitive <label> (ga-ylr2m) -> 0 if restart_policy.yaml (when
# present) does NOT explicitly clear ALL of this daemon's entrypoints for
# auto-restart. Mirrors that file's own documented default ("unlisted =
# manual, notify-only") instead of this script's historical default
# ("unlisted = safe") — the registry-drift gap ga-ylr2m closes. No policy
# file, or a daemon whose entrypoint didn't resolve to a relpath (see
# resolve_relpath), means no opinion — returns 1 (not sensitive BY THIS
# SOURCE; SENSITIVE_DAEMONS is still checked independently by the caller via
# `||` — this only ever ADDS scrutiny, never removes it). A policy file that
# EXISTS but failed to parse (POLICY_PARSE_OK unset — see the loader comment
# above) is the third state: unconditionally sensitive, since "couldn't read
# it" must never collapse into the same value as "read it, nothing applies".
# Reads $DISCO_DIR/$label, populated for every label by Step 2 above.
policy_says_sensitive() {
  local label="$1" entries entry base locked_hit
  [ -f "$RESTART_POLICY_YAML" ] || return 1
  if [ -z "$POLICY_PARSE_OK" ]; then
    log "$label: restart_policy.yaml exists but did not parse — treating as sensitive (fail closed, unverifiable != cleared)."
    return 0
  fi
  entries="$(cat "$DISCO_DIR/$label" 2>/dev/null || true)"
  [ -n "${entries// /}" ] || return 1
  for entry in $entries; do
    base="$(basename "$entry")"
    case " $POLICY_AUTO $POLICY_DEPLOY_RESTART " in
      *" $base "*) continue ;;   # this entrypoint is explicitly allow-listed safe
    esac
    locked_hit=0
    case " $POLICY_NOTIFY_ONLY_LOCKED " in *" $base "*) locked_hit=1 ;; esac
    if [ "$locked_hit" -eq 1 ]; then
      log "$label ($base): restart_policy.yaml notify_only_locked — human trava, never auto."
    else
      log "$label ($base): not in restart_policy.yaml's 'auto'/'deploy_restart' — unlisted defaults to manual there."
    fi
    return 0   # at least one entrypoint is NOT explicitly safe -> sensitive
  done
  return 1   # every entrypoint explicitly allow-listed safe
}

# guard_allows_restart <label> (ga-ylr2m) -> 0 if no configured guard objects.
# Consults restart_policy.yaml's restart_guard_scripts: for ANY of this
# daemon's entrypoints, mirroring whatsapp_automation/scripts/
# auto_restart_daemons.py's guard_allows_restart(): guard script exit 0 =
# proceed; any non-zero (1=in-flight, 2=don't know, a crash, a timeout) = do
# NOT restart — the third state ("don't know") collapses to the safe one,
# never to "proceed" (ga-mlsc0's own discipline, reused verbatim here). No
# entry for this daemon -> always allowed, IDENTICAL to before this change —
# the guard only ever SUBTRACTS a restart that would otherwise have happened,
# never adds one. Closes the "consult restart_guard_scripts before an
# auto-kickstart" half of ga-ylr2m: this script was a 4th, previously-
# unguarded restart trigger alongside WA's own three. A policy file that
# EXISTS but failed to parse (POLICY_PARSE_OK unset) refuses unconditionally
# — we cannot rule out a real guard entry we simply failed to read, and
# "couldn't verify" must fail the same way an active guard refusal does, not
# the same way "verified, no guard configured" does.
guard_allows_restart() {
  local label="$1" entries entry base pair d s script rc
  if [ -f "$RESTART_POLICY_YAML" ] && [ -z "$POLICY_PARSE_OK" ]; then
    log "$label: restart_policy.yaml exists but did not parse — cannot verify whether a guard applies; refusing restart (fail closed)."
    return 1
  fi
  [ -n "$POLICY_GUARDS" ] || return 0
  entries="$(cat "$DISCO_DIR/$label" 2>/dev/null || true)"
  for entry in $entries; do
    base="$(basename "$entry")"
    for pair in $POLICY_GUARDS; do
      d="${pair%%=*}"; s="${pair#*=}"
      [ "$d" = "$base" ] || continue
      script="$RUNTIME_DIR/$s"
      if [ ! -f "$script" ]; then
        log "$label ($base) guard script declared but missing on disk: $script — treating as refused (fail closed)."
        return 1
      fi
      timeout 15 python3 "$script" --quiet
      rc=$?
      if [ "$rc" -ne 0 ]; then
        log "$label ($base) guard $s refused (exit $rc) — not restarting."
        return 1
      fi
      log "$label ($base) guard $s: OK."
    done
  done
  return 0
}

# extract literal render_template("...") / render_template('...') first-arg
# names referenced in a file — same single-hop precision as the import-level
# .py match below (checks the daemon's own entrypoint, not its full transitive
# closure).
daemon_template_names() {  # daemon_template_names <file>
  local f="$1"
  [ -f "$f" ] || return 0
  python3 - "$f" <<'PY' 2>/dev/null
import re, sys
try:
    src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
except Exception:
    sys.exit(0)
for m in re.findall(r'render_template\(\s*[\'"]([^\'"]+)[\'"]', src):
    print(m)
PY
}

# does <file> genuinely IMPORT <stem> — via the file's own AST, not a text
# grep, so a name merely MENTIONED in a comment/docstring/string literal
# never counts (ga-dn9ye: a bare `\bstem\b` grep over the whole file matched
# a filename named in a comment like "consumed by admin_dashboard.py",
# flagging daemons that never imported it). A single-line anchored regex
# (`^\s*(import|from)\s+.*\bstem\b`) fixes that but breaks on a parenthesized
# multi-line `from X import (\n    stem,\n)` — common, and exactly what the
# first gate review caught as a regression (ga-dn9ye attempt 1) — because the
# line with the stem doesn't itself start with import/from. Real AST parsing
# has neither problem: comments/docstrings/strings are never Import nodes,
# and multi-line/backslash-continued/aliased forms all parse the same as a
# single-line one. On a genuine parse failure, exits 1 (not affected) — same
# fail-soft shape as daemon_template_names() above; every entrypoint here is
# a live, running production daemon, so in practice it always parses.
daemon_imports_stem() {  # daemon_imports_stem <file> <stem>
  local f="$1" stem="$2"
  [ -f "$f" ] || return 1
  python3 - "$f" "$stem" <<'PY' 2>/dev/null
import ast, sys
path, stem = sys.argv[1], sys.argv[2]
try:
    tree = ast.parse(open(path, encoding="utf-8", errors="replace").read())
except Exception:
    sys.exit(1)
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        for alias in node.names:
            if stem in alias.name.split('.'):
                sys.exit(0)
    elif isinstance(node, ast.ImportFrom):
        if node.module and stem in node.module.split('.'):
            sys.exit(0)
        for alias in node.names:
            if alias.name == stem:
                sys.exit(0)
sys.exit(1)
PY
}

# ── Step 3: resolve affected daemons ──────────────────────────────────────────
for label in $DAEMON_LABELS; do
  entries="$(cat "$DISCO_DIR/$label")"
  affected=0
  own_stems=""
  for e in $entries; do own_stems="$own_stems $(basename "$e" .py)"; done

  # direct: an entrypoint relpath or basename is in the changed set
  for e in $entries; do
    if echo "$CHANGED_PY" | grep -qxF "$e"; then affected=1; break; fi
    eb="$(basename "$e")"
    if echo "$CHANGED_BASENAMES" | grep -qxF "$eb"; then affected=1; break; fi
  done

  # import-level: a changed shared module (not this daemon's own entrypoint)
  # is actually imported by one of the entrypoint files — see
  # daemon_imports_stem() above for why this is real AST parsing, not a
  # grep/regex (ga-dn9ye: a bare text match flagged a comment MENTION as an
  # import; the first, regex-anchored fix then missed a multi-line
  # parenthesized import — both classes need real parsing, not text
  # matching).
  if [ "$affected" -eq 0 ]; then
    for stem in $CHANGED_STEMS; do
      case " $own_stems " in *" $stem "*) continue ;; esac   # own entrypoint → handled above
      for e in $entries; do
        if daemon_imports_stem "$RUNTIME_DIR/$e" "$stem"; then
          affected=1; break
        fi
      done
      [ "$affected" -eq 1 ] && break
    done
  fi

  # template: a changed template this daemon's own entrypoint renders via
  # render_template(...) (ga-jkj0 — Jinja templates are cached in-process and
  # a disk-only change is otherwise invisible to this script).
  if [ "$affected" -eq 0 ] && [ -n "${CHANGED_TEMPLATE_BASENAMES// /}" ]; then
    for e in $entries; do
      [ -f "$RUNTIME_DIR/$e" ] || continue
      while IFS= read -r tmpl; do
        [ -n "$tmpl" ] || continue
        tb="$(basename "$tmpl")"
        if echo "$CHANGED_TEMPLATE_BASENAMES" | grep -qxF "$tb"; then
          affected=1; break
        fi
      done < <(daemon_template_names "$RUNTIME_DIR/$e")
      [ "$affected" -eq 1 ] && break
    done
  fi

  [ "$affected" -eq 1 ] || continue
  AFFECTED="$AFFECTED $label"
  log "AFFECTED: $label (entrypoints:$entries)"
done

AFFECTED="$(echo "$AFFECTED" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')"
if [ -z "${AFFECTED// /}" ]; then
  # ga-vmq1i: py/template files DID change but detection (single-hop entrypoint
  # scan — see the import-level/template-level comments above) tied them to no
  # live daemon. That is NOT the same certainty as "nothing daemon-relevant
  # changed" (the earlier not_applicable emits) — it may be a real non-issue,
  # or it may be exactly the blind spot the detection comments already flag.
  # Report not_verified so the caller never claims this was confirmed live.
  log "no running daemon is affected by the changed code — OK."
  emit OK "changed code touches no live daemon" not_verified
fi

# ── Step 4: restart (safe) / flag (sensitive) + verify freshness ──────────────
verify_fresh() {  # verify_fresh <label> -> 0 if a process started after DEPLOY_EPOCH
  local label="$1" waited=0 pid se
  while :; do
    pid="$(daemon_pid "$label")"
    if [ -n "$pid" ]; then
      se="$(pid_start_epoch "$pid" || echo 0)"
      if [ -n "$se" ] && [ "$se" -gt "$DEPLOY_EPOCH" ] 2>/dev/null; then
        log "verify $label: pid $pid started $se > deploy $DEPLOY_EPOCH — FRESH."
        return 0
      fi
    fi
    # bash sleep accepts fractional on macOS
    awk "BEGIN{exit !($waited < $VERIFY_TIMEOUT)}" || break
    sleep "$VERIFY_INTERVAL"
    waited="$(awk "BEGIN{print $waited + $VERIFY_INTERVAL}")"
  done
  log "verify $label: no process started after deploy within ${VERIFY_TIMEOUT}s — STALE."
  return 1
}

# already_fresh <label> (ga-j3j6s; refined ga-puq8z) -> 0 if the CURRENTLY-live
# process already started after the code was COMMITTED (COMMIT_EPOCH, computed
# above from POST_DEPLOY_SHA) — a ONE-SHOT snapshot check (no wait/retry loop,
# unlike verify_fresh()): we are not waiting for a restart WE are about to
# perform, we are asking whether one already happened via some other path.
# Deliberately COMMIT_EPOCH, not DEPLOY_EPOCH: DEPLOY_EPOCH is "now" from THIS
# check's own point of view, so a restart that already happened via another
# path is — by construction — always BEFORE it; comparing against DEPLOY_EPOCH
# alone made this check nearly impossible to satisfy and produced exactly the
# false positives ga-puq8z measured (see the COMMIT_EPOCH comment above). Same
# primitives as verify_fresh() (daemon_pid + pid_start_epoch), so this carries
# the identical evidentiary weight — see header point 7 for why a file-mtime
# comparison would be the wrong (and misleading) alternative.
already_fresh() {  # already_fresh <label>
  local label="$1" pid se
  pid="$(daemon_pid "$label")"
  [ -n "$pid" ] || return 1
  se="$(pid_start_epoch "$pid" || echo 0)"
  [ -n "$se" ] && [ "$se" -gt "$COMMIT_EPOCH" ] 2>/dev/null
}

for label in $AFFECTED; do
  # Only refresh LONG-LIVED daemons that are running RIGHT NOW (have a live PID).
  # A discovered job with no current PID is a scheduled/one-shot agent (e.g. a
  # daily scraper) or an already-down daemon — kickstarting it would wrongly
  # TRIGGER the job, not "refresh" it, and there is no running stale process to
  # fix. This is precisely the bug's domain: a long-lived process already running
  # stale code. Skip the rest.
  if [ -z "$(daemon_pid "$label")" ]; then
    log "AFFECTED $label is not currently running (scheduled/one-shot or down) — not a dormant-running-daemon; skipping refresh."
    continue
  fi
  if is_sensitive "$label" || policy_says_sensitive "$label"; then
    if already_fresh "$label"; then
      log "SENSITIVE $label: current process already started after deploy (DEPLOY_EPOCH=$DEPLOY_EPOCH) — already running the new code via some other restart path; not flagging for guarded restart (ga-j3j6s)."
      ALREADY_FRESH="$ALREADY_FRESH $label"
      continue
    fi
    sani="${label//[^A-Za-z0-9_]/_}"
    drain_var="DRAIN_CMD_${sani}"
    drain="${!drain_var:-}"
    if [ -n "$drain" ]; then
      if ! guard_allows_restart "$label"; then
        log "SENSITIVE $label: guard refused — NOT draining/restarting; flagged for guarded restart."
        GUARDED="$GUARDED $label"
        continue
      fi
      log "SENSITIVE $label: draining via \$$drain_var then restarting (guarded path)."
      if [ "$DRY_RUN" != "1" ]; then
        eval "$drain" >&2 2>&1 || log "WARN: drain command for $label failed (rc=$?) — continuing to restart."
        $LAUNCHCTL_BIN kickstart -k "gui/$(id -u)/$label" 2>/dev/null \
          || $LAUNCHCTL_BIN kickstart "$label" 2>/dev/null \
          || log "WARN: kickstart failed for $label"
        RESTARTED="$RESTARTED $label"
        if ! verify_fresh "$label"; then
          FRESH_FAIL="$FRESH_FAIL $label"
        fi
      else
        WOULD_RESTART="$WOULD_RESTART $label"
      fi
    else
      log "SENSITIVE $label: NO drain path configured — NOT auto-bounced; flagged for guarded restart."
      GUARDED="$GUARDED $label"
    fi
    continue
  fi

  # SAFE (read-only dashboard etc.): consult any configured guard (ga-ylr2m),
  # then kickstart -k + verify freshness.
  if ! guard_allows_restart "$label"; then
    log "SAFE $label: guard refused — NOT auto-bounced; flagged for guarded restart."
    GUARDED="$GUARDED $label"
    continue
  fi
  log "SAFE $label: kickstart -k + verify fresh."
  if [ "$DRY_RUN" != "1" ]; then
    $LAUNCHCTL_BIN kickstart -k "gui/$(id -u)/$label" 2>/dev/null \
      || $LAUNCHCTL_BIN kickstart "$label" 2>/dev/null \
      || log "WARN: kickstart failed for $label (label wrong or not loaded?)"
    RESTARTED="$RESTARTED $label"
    if ! verify_fresh "$label"; then
      FRESH_FAIL="$FRESH_FAIL $label"
    fi
  else
    WOULD_RESTART="$WOULD_RESTART $label"
  fi
done

RESTARTED="$(echo "$RESTARTED" | tr ' ' '\n' | grep -v '^$' | tr '\n' ' ' | sed 's/ $//')"
FRESH_FAIL="$(echo "$FRESH_FAIL" | tr ' ' '\n' | grep -v '^$' | tr '\n' ' ' | sed 's/ $//')"
GUARDED="$(echo "$GUARDED" | tr ' ' '\n' | grep -v '^$' | tr '\n' ' ' | sed 's/ $//')"
ALREADY_FRESH="$(echo "$ALREADY_FRESH" | tr ' ' '\n' | grep -v '^$' | tr '\n' ' ' | sed 's/ $//')"
WOULD_RESTART="$(echo "$WOULD_RESTART" | tr ' ' '\n' | grep -v '^$' | tr '\n' ' ' | sed 's/ $//')"

# ── Step 5: verdict ───────────────────────────────────────────────────────────
if [ -n "${FRESH_FAIL// /}" ]; then
  emit VERIFY_FAILED "restarted daemon(s) did not come up fresh:${FRESH_FAIL}" not_verified
elif [ -n "${GUARDED// /}" ]; then
  # ga-puq8z ACEITE 2: affected-daemon detection above (Step 3) is single-hop
  # import/template-closure matching, not a proof that the daemon's live code
  # path actually reaches the changed symbols — say so here rather than
  # asserting staleness outright, so a human evaluating this hold knows it can
  # be a false positive and checks pid-start vs. commit time before acting.
  emit NEEDS_GUARDED_RESTART "sensitive hot-path daemon(s) need a guarded restart (import/template-closure match, not proven reachable to the changed symbols — may be a false positive):${GUARDED}" not_verified
elif [ -n "${RESTARTED// /}" ]; then
  emit OK "all affected daemons restarted + verified fresh:${RESTARTED}" verified
elif [ -n "${WOULD_RESTART// /}" ]; then
  # ga-omfwe: DRY_RUN=1 skips both the kickstart and verify_fresh calls, so
  # this run confirmed nothing — RESTARTED must never be populated here (the
  # pre-fix bug: it was, and this branch was unreachable because RESTARTED
  # always won first). PROOF=not_applicable, matching the "nothing live to
  # refresh" branch below: verification wasn't attempted, not that it failed.
  emit OK "DRY RUN — no action taken; would restart daemon(s):${WOULD_RESTART}" not_applicable
elif [ -n "${ALREADY_FRESH// /}" ]; then
  # ga-j3j6s: sensitive daemon(s) whose live process already started after
  # DEPLOY_EPOCH via some other restart path (e.g. the rig's own auto-deploy)
  # — positively confirmed fresh via the identical epoch comparison
  # verify_fresh() uses, just without THIS script performing the restart.
  emit OK "affected sensitive daemon(s) already running post-deploy code, no restart needed:${ALREADY_FRESH}" verified
else
  # ga-vmq1i: AFFECTED was non-empty, but every affected daemon was skipped for
  # having no live PID (a scheduled/one-shot job, per the Step-4 loop above) —
  # RESTARTED is empty, so nothing was actually restarted or confirmed fresh.
  # The pre-fix code emitted this exact case as "...restarted + verified
  # fresh:" with a literally empty list, which is the concrete false-positive
  # ga-vmq1i reports. Nothing live exists to be stale, so not_applicable —
  # never "verified".
  emit OK "no affected daemon currently running — nothing live to refresh" not_applicable
fi
