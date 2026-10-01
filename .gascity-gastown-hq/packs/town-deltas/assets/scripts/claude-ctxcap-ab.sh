#!/bin/bash
# claude-ctxcap-ab — ga-55vrxw (E10 of P0 ga-ufskhy): context-window A/B for the pool roles.
#
# WHY. Cost is context size x number of turns, and the context is re-read from cache on every turn: measured
# 2026-10-01 over 7 h, wa-worker ~281k tokens/turn, dog ~210k, gate-reviewer ~148k, cache-read ~2/3 of the
# bill, output irrelevant. Pool sessions grow toward the 1M window without compacting. ga-kjncp (28/08) capped
# the window for the LONG-LIVED roles only and left the pool alone on purpose, because then the long-lived
# roles were ~72% of the volume; today the pool roles are ~90%, so that premise no longer holds.
#
# HOW. claude takes `--autocompact <auto|tokens>` (100k-1M). The window is a per-LAUNCH argument but the
# provider is one string for every role, so the arm is decided here, where the session is born, from a hash
# of the session name (SHA-256, salted) — fixed BEFORE the session sees a bead, so arm and bead are
# independent (same argument as the effort A/B in claude-lowprio.sh, ga-5c3msy). This wrapper is the
# `command` of [providers.claude-headless] and execs claude-lowprio.sh, which execs claude: same pid all the
# way, argv untouched except for the ONE flag below.
#
# INERT unless $GC_CITY_PATH/.gc/context-ab.conf exists. `key=value` lines (# comments):
#     salt=ga-55vrxw-1                         changes the split when a new experiment starts
#     enroll=gastown.dog wa-worker ps-worker   GC_TEMPLATE values (or GC_AGENT prefixes) that are enrolled
#     treat_window=200000                      tokens, digits only, 100000-1000000
#     treat_pct=50                             0-100, share of enrolled sessions that get the cap
# The control arm gets no flag at all (claude's own default). gate-reviewer is NOT enrolled by default: its
# recall is the value of the gate, and a compaction in the middle of a review can drop the evidence it just
# read — put it in `enroll` only on purpose, with its own salt.
#
# CROSSED WITH THE EFFORT A/B. The hash input here is "ctx-ab:<salt>:<session>", the effort arm's is
# "effort-ab:<salt>:<session>", so the two assignments are independent and the experiment is a 2x2. Read the
# result with BOTH factors; one-factor-at-a-time comparisons mix them.
#
# FAIL-OPEN, AND WHY THE VALUE IS VALIDATED HERE. claude EXITS on an --autocompact value outside auto|100k-1M
# (measured, claude 2.1.286), so a typo in the conf would not "disable the experiment", it would stop every
# enrolled session from starting. Anything doubtful — bad conf, no session name, argv already carrying
# --autocompact — leaves argv exactly as received and logs why (when $GC_CITY_PATH/.gc/logs exists; without it
# nothing can be logged, and the launch still proceeds). Only a plain number in range ever reaches claude, so
# conf text can never add a flag. Each ENROLLED launch appends one line to
# $GC_CITY_PATH/.gc/logs/claude-lowprio.log with the claude --session-id, so "did the arm reach the process"
# is a join against the transcript (compare the largest context a treated session reaches with the window).
# A launch that is not enrolled, or is switched off by a knob, logs nothing: that silence is deliberate.
#
# KNOBS: GC_CTX_AB=0 (this launch) / touch $GC_CITY_PATH/.gc/no-ctx-ab (every new launch, no config reload).
# SEAMS (tests): GC_CTXCAP_NEXT_BIN = the next hop instead of the sibling claude-lowprio.sh;
# GC_LOWPRIO_CLAUDE_BIN = the real claude, only used if the next hop is not executable.
set -u

city="${GC_CITY_PATH:-}"
claude_bin="${GC_LOWPRIO_CLAUDE_BIN:-claude}"
case "$0" in */*) here="${0%/*}" ;; *) here="." ;; esac
next="${GC_CTXCAP_NEXT_BIN:-$here/claude-lowprio.sh}"

log=""
if [ -n "$city" ] && [ -d "$city/.gc/logs" ]; then
  log="$city/.gc/logs/claude-lowprio.log"
fi

# One line per decision. Best-effort by design: a logging failure must never touch the launch itself.
note() {
  [ -n "$log" ] || return 0
  printf '%s pid=%s agent=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "${GC_AGENT:-?}" "$*" >> "$log" 2>/dev/null || true
}

argv=("$@")
ab_conf=""
[ -n "$city" ] && ab_conf="$city/.gc/context-ab.conf"
if [ -n "$ab_conf" ] && [ -f "$ab_conf" ] && [ "${GC_CTX_AB:-}" != "0" ] && [ ! -e "$city/.gc/no-ctx-ab" ]; then
  ab_salt=""; ab_enroll=""; ab_win=""; ab_pct=""; ab_bad=""
  while IFS='=' read -r ab_k ab_v || [ -n "$ab_k" ]; do
    ab_k="${ab_k//[[:space:]]/}"
    case "$ab_k" in ''|'#'*) continue ;; esac
    ab_v="${ab_v%%#*}"; ab_v="${ab_v#"${ab_v%%[![:space:]]*}"}"; ab_v="${ab_v%"${ab_v##*[![:space:]]}"}"
    case "$ab_v" in *[!A-Za-z0-9._\ -]*) ab_bad="$ab_k has characters outside [A-Za-z0-9._ -]"; break ;; esac
    case "$ab_k" in
      salt) ab_salt="$ab_v" ;; enroll) ab_enroll="$ab_v" ;; treat_window) ab_win="$ab_v" ;; treat_pct) ab_pct="$ab_v" ;;
      *) ab_bad="unknown key '$ab_k'"; break ;;
    esac
  done < "$ab_conf"
  # The length is bounded BEFORE any numeric test: `[ N -lt X ]` on a number that overflows returns 2 (an error),
  # both clauses read as false, and "could not compare" would pass as "in range" — straight into claude, which
  # exits on it. A leading zero is refused too: only the canonical form is ever handed to claude.
  case "$ab_win" in ''|0*|*[!0-9]*) ab_bad="${ab_bad:-treat_window '$ab_win' is not a plain number}" ;; *)
    if [ "${#ab_win}" -gt 7 ] || [ "$ab_win" -lt 100000 ] || [ "$ab_win" -gt 1000000 ]; then ab_bad="${ab_bad:-treat_window '$ab_win' is outside 100000-1000000}"; fi ;;
  esac
  case "$ab_pct" in ''|*[!0-9]*) ab_bad="${ab_bad:-treat_pct '$ab_pct' is not 0-100}" ;; *)
    if [ "${#ab_pct}" -gt 3 ] || [ "$ab_pct" -gt 100 ]; then ab_bad="${ab_bad:-treat_pct '$ab_pct' is not 0-100}"; fi ;;
  esac
  [ -n "$ab_salt" ] && [ -n "$ab_enroll" ] || ab_bad="${ab_bad:-salt/enroll missing}"
  if [ -n "$ab_bad" ]; then
    note "CTX-AB WARN conf $ab_conf ignored: $ab_bad"
  else
    ab_tpl="${GC_TEMPLATE:-}"; ab_in=""
    for ab_t in $ab_enroll; do
      if [ "$ab_tpl" = "$ab_t" ]; then ab_in=1; break; fi
      case "${GC_AGENT:-}" in "$ab_t"|"$ab_t"-*) ab_in=1; break ;; esac
    done
    if [ -n "$ab_in" ]; then
      ab_sn="${GC_SESSION_NAME:-}"
      ab_have=""; ab_uuid="?"
      for ((ab_i = 0; ab_i < ${#argv[@]}; ab_i++)); do
        case "${argv[$ab_i]}" in
          --) break ;;
          --autocompact|--autocompact=*) ab_have=1 ;;
          --session-id) ab_uuid="${argv[$((ab_i + 1))]:-?}" ;;
        esac
      done
      if [ -z "$ab_sn" ]; then
        note "CTX-AB WARN template=$ab_tpl has no GC_SESSION_NAME - left alone"
      elif [ -n "$ab_have" ]; then
        note "CTX-AB SKIP template=$ab_tpl session=$ab_sn uuid=$ab_uuid already launched with --autocompact - left alone"
      elif ! ab_out="$(printf '%s' "ctx-ab:$ab_salt:$ab_sn" | shasum -a 256 2>/dev/null)" || [ -z "$ab_out" ]; then
        note "CTX-AB WARN template=$ab_tpl session=$ab_sn shasum failed - left alone"
      else
        ab_h="${ab_out%% *}"
        ab_n=$(( 16#${ab_h:0:8} % 100 ))
        if [ "$ab_n" -lt "$ab_pct" ]; then
          # Prepended, never appended: an option placed after a `--` or a trailing prompt would be read as text.
          argv=(--autocompact "$ab_win" ${argv[@]+"${argv[@]}"})
          note "CTX-AB arm=treat template=$ab_tpl session=$ab_sn uuid=$ab_uuid window=$ab_win n=$ab_n pct=$ab_pct salt=$ab_salt"
        else
          note "CTX-AB arm=control template=$ab_tpl session=$ab_sn uuid=$ab_uuid window=auto n=$ab_n pct=$ab_pct salt=$ab_salt"
        fi
      fi
    fi
  fi
fi

if [ -x "$next" ]; then
  exec "$next" ${argv[@]+"${argv[@]}"}
fi
note "CTX-AB WARN next hop $next is not executable - launching $claude_bin directly"
exec "$claude_bin" ${argv[@]+"${argv[@]}"}
