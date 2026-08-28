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
#   7. (ga-j3j6s) Before flagging a SENSITIVE daemon at all (drain path or
#      not), check whether its CURRENT live process already started after
#      DEPLOY_EPOCH — the same pid-start-epoch comparison verify_fresh() uses
#      to confirm a restart THIS script performed. If it's already fresh, some
#      OTHER mechanism (e.g. the rig's own auto-deploy) already restarted it;
#      flagging NEEDS_GUARDED_RESTART here is a false positive that pushes a
#      human toward an unnecessary, non-zero-risk hot-path restart (real
#      incident: com.whatsapp.map-viewer flagged ~1m45s after auto-deploy had
#      already restarted it and was serving the new template). Deliberately
#      NOT a file-mtime comparison — a daemon can serve from a different tree
#      than the changed file, which would make an mtime check lie; DEPLOY_EPOCH
#      is a process-clock timestamp tied to the deploy event itself, compared
#      only against the live PID's own start time (never a file path).
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
#   REASON=<text>   PROOF=verified|not_applicable|not_verified
# Exit 0 when VERDICT is OK/SKIPPED (or DRY_RUN=1); non-zero otherwise.
#
# Inputs (env):
#   RUNTIME_DIR       deployed git work tree (e.g. /Users/athos/gt/whatsapp_automation)
#                     (ga-ylr2m) if $RUNTIME_DIR/daemons/restart_policy.yaml
#                     exists, it is consulted directly — see header point 6.
#   PRE_DEPLOY_SHA    HEAD before deploy
#   POST_DEPLOY_SHA   HEAD after deploy
#   DEPLOY_EPOCH      unix epoch captured immediately before deploy
#   SENSITIVE_DAEMONS space/newline-separated launchd-label substrings (hot-path)
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
# a "daemon.py=script/relpath" pair list (POLICY_GUARDS). Three distinct states,
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
POLICY_AUTO=""; POLICY_DEPLOY_RESTART=""; POLICY_NOTIFY_ONLY_LOCKED=""; POLICY_GUARDS=""; POLICY_PARSE_OK=""
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
  echo "REASON=$reason"
  echo "PROOF=$proof"
  # Trailing JSON for the caller's bead comment / jsonl log.
  python3 - "$verdict" "$reason" "${AFFECTED:-}" "${RESTARTED:-}" "${FRESH_FAIL:-}" "${GUARDED:-}" "$proof" "${ALREADY_FRESH:-}" <<'PY' 2>/dev/null || true
import json, sys
v, reason, aff, res, ff, gd, proof, afr = sys.argv[1:9]
sp = lambda s: [x for x in s.split() if x]
print("JSON=" + json.dumps({
    "verdict": v, "reason": reason,
    "affected": sp(aff), "restarted": sp(res),
    "fresh_fail": sp(ff), "guarded": sp(gd), "proof": proof,
    "already_fresh": sp(afr),
}))
PY
  if [ "$DRY_RUN" = "1" ]; then exit 0; fi
  case "$verdict" in OK|SKIPPED) exit 0 ;; *) exit 1 ;; esac
}

AFFECTED=""; RESTARTED=""; FRESH_FAIL=""; GUARDED=""; ALREADY_FRESH=""

# ── preconditions ─────────────────────────────────────────────────────────────
if [ -z "$RUNTIME_DIR" ] || ! git -C "$RUNTIME_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log "runtime '$RUNTIME_DIR' is not a git work tree — skip (static daemon_restarts still apply)."
  emit SKIPPED "runtime not a git work tree" not_verified
fi
if [ -z "$PRE_DEPLOY_SHA" ] || [ -z "$POST_DEPLOY_SHA" ] || [ "$PRE_DEPLOY_SHA" = "$POST_DEPLOY_SHA" ]; then
  log "no SHA delta ($PRE_DEPLOY_SHA .. $POST_DEPLOY_SHA) — deploy changed nothing — skip."
  emit SKIPPED "no source change in deploy" not_applicable
fi

# ── Step 1: changed files in this deploy ──────────────────────────────────────
CHANGED="$(git -C "$RUNTIME_DIR" diff --name-only "$PRE_DEPLOY_SHA" "$POST_DEPLOY_SHA" 2>/dev/null || true)"
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
plist_args() {  # plist_args <plist>
  python3 - "$1" <<'PY' 2>/dev/null
import sys, plistlib
try:
    d = plistlib.load(open(sys.argv[1], 'rb'))
except Exception:
    sys.exit(0)
for a in (d.get('ProgramArguments') or []):
    print(a)
PY
}

# Resolve a (possibly $VAR-prefixed or absolute) .py token to a relpath that
# exists under RUNTIME_DIR; echoes nothing if it cannot be resolved.
resolve_relpath() {  # resolve_relpath <token>
  local t="$1" c
  # absolute under runtime
  case "$t" in
    "$RUNTIME_DIR"/*) c="${t#"$RUNTIME_DIR"/}"; [ -f "$RUNTIME_DIR/$c" ] && { echo "$c"; return; } ;;
  esac
  # strip a leading shell-var segment: $BASEDIR/ ${WA_ROOT}/ etc.
  c="$(echo "$t" | sed -E 's#^.*\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/##')"
  [ -n "$c" ] && [ "$c" != "$t" ] && [ -f "$RUNTIME_DIR/$c" ] && { echo "$c"; return; }
  return 1
}

# label -> space-separated entrypoint relpaths (parallel arrays via temp files)
DISCO_DIR="$(mktemp -d "${TMPDIR:-/tmp}/daemon-disco.XXXXXX")"
trap 'rm -rf "$DISCO_DIR"' EXIT
DAEMON_LABELS=""

shopt -s nullglob
for plist in "$LAUNCH_AGENTS_DIR"/*.plist; do
  label="$(basename "$plist" .plist)"
  entry=""
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
  done < <(plist_args "$plist")
  entry="$(echo "$entry" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
  [ -n "${entry// /}" ] || continue
  echo "$entry" > "$DISCO_DIR/$label"
  DAEMON_LABELS="$DAEMON_LABELS $label"
done
shopt -u nullglob

if [ -z "${DAEMON_LABELS// /}" ]; then
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

  # import-level: a changed shared module (not this daemon's own entrypoint) is
  # referenced by name inside one of the entrypoint files.
  if [ "$affected" -eq 0 ]; then
    for stem in $CHANGED_STEMS; do
      case " $own_stems " in *" $stem "*) continue ;; esac   # own entrypoint → handled above
      for e in $entries; do
        if [ -f "$RUNTIME_DIR/$e" ] && grep -Eq "\\b${stem}\\b" "$RUNTIME_DIR/$e" 2>/dev/null; then
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

# already_fresh <label> (ga-j3j6s) -> 0 if the CURRENTLY-live process already
# started after DEPLOY_EPOCH — a ONE-SHOT snapshot check (no wait/retry loop,
# unlike verify_fresh()): we are not waiting for a restart WE are about to
# perform, we are asking whether one already happened via some other path.
# Same primitives as verify_fresh() (daemon_pid + pid_start_epoch), so this
# carries the identical evidentiary weight — see header point 7 for why a
# file-mtime comparison would be the wrong (and misleading) alternative.
already_fresh() {  # already_fresh <label>
  local label="$1" pid se
  pid="$(daemon_pid "$label")"
  [ -n "$pid" ] || return 1
  se="$(pid_start_epoch "$pid" || echo 0)"
  [ -n "$se" ] && [ "$se" -gt "$DEPLOY_EPOCH" ] 2>/dev/null
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
      fi
      RESTARTED="$RESTARTED $label"
      if [ "$DRY_RUN" != "1" ] && ! verify_fresh "$label"; then
        FRESH_FAIL="$FRESH_FAIL $label"
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
  fi
  RESTARTED="$RESTARTED $label"
  if [ "$DRY_RUN" != "1" ] && ! verify_fresh "$label"; then
    FRESH_FAIL="$FRESH_FAIL $label"
  fi
done

RESTARTED="$(echo "$RESTARTED" | tr ' ' '\n' | grep -v '^$' | tr '\n' ' ' | sed 's/ $//')"
FRESH_FAIL="$(echo "$FRESH_FAIL" | tr ' ' '\n' | grep -v '^$' | tr '\n' ' ' | sed 's/ $//')"
GUARDED="$(echo "$GUARDED" | tr ' ' '\n' | grep -v '^$' | tr '\n' ' ' | sed 's/ $//')"
ALREADY_FRESH="$(echo "$ALREADY_FRESH" | tr ' ' '\n' | grep -v '^$' | tr '\n' ' ' | sed 's/ $//')"

# ── Step 5: verdict ───────────────────────────────────────────────────────────
if [ -n "${FRESH_FAIL// /}" ]; then
  emit VERIFY_FAILED "restarted daemon(s) did not come up fresh:${FRESH_FAIL}" not_verified
elif [ -n "${GUARDED// /}" ]; then
  emit NEEDS_GUARDED_RESTART "sensitive hot-path daemon(s) need a guarded restart:${GUARDED}" not_verified
elif [ -n "${RESTARTED// /}" ]; then
  emit OK "all affected daemons restarted + verified fresh:${RESTARTED}" verified
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
