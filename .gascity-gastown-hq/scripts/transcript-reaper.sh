#!/bin/bash
# transcript-reaper.sh (ga-t1ub9, same family as ga-02pnu/scratchpad-reaper.sh) —
# reaper for DEAD-session Claude Code transcripts under ~/.claude/projects/.
#
# WHY: scratchpad-reaper.sh (ga-02pnu) reaps dead-session scratch under
# /private/tmp, but ~/.claude/projects/<project>/<session-id>.jsonl accumulates
# one transcript per session FOREVER with nothing to reap it — a disjoint leak
# class scratchpad-reaper.sh never touched. By 2026-07-26 this had grown to
# 1.4GB across 1232 files; disk hit 95% and Dolt ENOSPC'd twice that day (see
# ga-t1ub9 comments).
#
# WHAT: scans ~/.claude/projects/<project>/<session-id>.jsonl for every
# project/session pair, and removes the `.jsonl` file — PLUS its same-named
# sibling directory `<project>/<session-id>/` (tool-result blobs etc, when
# present; same session, same liveness proof applies to both) — when BOTH hold:
#   1. DEAD  — <session-id> (matches `gc session list --json`'s
#      `.sessions[].session_key`, NOT `.sessions[].id`) does NOT appear in the
#      default `gc session list` output (active + suspended/asleep + anything
#      not closed). Absence = dead. Identical mechanism to
#      scratchpad-reaper.sh's _fetch_live_keys — same call, same jq, same
#      abort-on-failure discipline. A session_key is not the only proof of
#      life (ga-esorlre.1): the id must ALSO be neither the `sessionId` of a
#      running Claude process nor a value recorded in a session bead's
#      metadata — see "LIVE CONVERSATIONS" below.
#   2. STALE — the `.jsonl` file's mtime is older than MIN_AGE_HOURS (default
#      24h; lowered from the original 72h per ga-5ppqo — measured 2026-08-07:
#      at 72h only 281MB of 1.6GB total was ever eligible, since 82% of
#      volume was newer than that threshold, so the reaper could never keep
#      pace with growth even running perfectly. The 72h number traced to a
#      human habit ("o Mayor limpa manual >3d entre ciclos"), not a safety
#      requirement — condition 1 (DEAD) is what actually protects a session;
#      this is only the grace-period slack on top of it. 24h dry-run
#      validated against live data: 1056 candidates, zero overlap with the
#      live/suspended session-key set).
#
# SAFETY (ga-t1ub9's explicit ask: "CRITICO: NUNCA reapar sessao VIVA nem
# SUSPENSA (sessao suspensa resume e precisa do transcript) — checar contra o
# session list, NAO so mtime") — higher stakes than scratchpad-reaper.sh: a
# transcript is irreplaceable conversation history, not regeneratable scratch;
# deleting a SUSPENDED session's transcript permanently breaks its resume.
#   - A `gc session list` query FAILURE (nonzero exit / unparseable JSON /
#     missing `.sessions` key) aborts the ENTIRE cycle with zero deletions —
#     empty and error must never collapse to the same "safe to reap" value
#     (ga-p5q3 class: error and empty must not produce the same value when the
#     emptiness is load-bearing).
#   - The CALLER's own session (env `CLAUDE_CODE_SESSION_ID`, when set) is
#     EXCLUDED unconditionally, independent of the live-session-list result —
#     belt-and-suspenders in case the current session hasn't propagated into
#     `gc session list` yet.
#   - Only the exact `<session-id>.jsonl` file (+ its same-named sibling dir,
#     when present) is removed — never a differently-named file.
#   - A session list entry with a null/absent `session_key` (observed for a
#     registered-but-never-started slot, and for a non-Claude managed process
#     sharing the same session list) is NOT treated as dead — its work_dir's
#     entire project directory is shielded from reaping instead, since its
#     transcript filename (if any) can't be named directly. See
#     _fetch_live_keys/_shield_unresolved_session (gate:fix-attempt:1 finding).
#
# LIVE CONVERSATIONS ARE NOT session_keys (ga-esorlre.1; the epic's 12/11 adversarial review, read on the mini): the Athos
# switches conversations inside a crew (/resume), so the transcript he is using is the `sessionId`
# of that crew's ~/.claude/sessions/<pid>.json, NOT the session_key of its session bead (thies: live
# 53bf2758, bead d27b72b2; digo: live d150ee9b, bead 5eb94e99). Protecting session_keys alone
# deleted a live conversation once it had gone 24h without a write. Two more sources now feed the
# SAME live-keys file, so _should_reap stays the single gate:
#   - _fetch_live_conversations: the sessionId of every `*.json` in $SESSIONS_DIR whose pid is
#     alive (a pid that `ps` cannot answer for counts as alive);
#   - _fetch_captured_ids: every one-word metadata value of every non-closed session bead — the id
#     the capture slice (ga-esorlre.2) records there, which keeps a conversation protected in the
#     window after a reboot, when no process is alive.
# Like the session list, each source that cannot be read (sessions dir, a session file of a
# pid whose process is not provably gone, `bd query`, a failed write to the live-keys file) aborts the
# WHOLE cycle with zero deletions.
#
# OUT OF SCOPE: directories under ~/.claude/projects with NO matching `.jsonl`
# (observed to exist on this machine — a distinct leak, not what ga-t1ub9's fix
# text describes; flagged separately rather than folded in here). Does not gate
# on disk pressure itself — the caller (dolt-disk-floor-guard.sh) decides WHEN
# to invoke this; this script always applies the same dead+stale criteria.
#
# Kill switch: TRANSCRIPT_REAPER_ENABLED=0 -> dry-run regardless of
# TRANSCRIPT_REAPER_DRY_RUN (logs candidates, deletes nothing).
#
# PRODUCTION SENTINEL (ga-lfj05, completing ga-h565g's ask for this file — the
# 2026-07-26 incident where THIS script deleted 185 real transcripts because
# its selftest's harness bug left the resolved root at its REAL default
# instead of a tmp fixture): whenever the resolved root exactly equals the
# hardcoded real default AND TRANSCRIPT_REAPER_PROD!=1, main() forces a
# dry-run regardless of TRANSCRIPT_REAPER_DRY_RUN — the same harness mistake
# (forgetting to override the root) can never delete real data again unless
# the caller ALSO explicitly opts in. Set ONLY by the real caller
# (dolt-disk-floor-guard.sh's _reap_dead_transcripts) — never by a test.
#
# TEST (no real ~/.claude/projects data touched, no real deletions against live
# data — the integration test uses a disposable tmp root):
#   bash scripts/transcript-reaper.selftest.sh
# Library mode: `TRANSCRIPT_REAPER_LIB=1 source transcript-reaper.sh` defines
# the pure decision functions WITHOUT running the reap flow.
set -uo pipefail

CITY="/Users/athos/gt/.gascity-gastown-hq"
TRANSCRIPT_REAL_DEFAULT_ROOT="/Users/athos/.claude/projects"
TRANSCRIPT_ROOT="${TRANSCRIPT_REAPER_ROOT:-$TRANSCRIPT_REAL_DEFAULT_ROOT}"
LOG="${TRANSCRIPT_REAPER_LOG:-$CITY/.gc/logs/transcript-reaper.log}"
GC="${GC_BIN:-gc}"
# ga-esorlre.1: where Claude Code keeps one <pid>.json per running process (the conversation it is
# using NOW), the bd that reads the session beads, and the ps that says whether a pid is alive.
SESSIONS_DIR="${TRANSCRIPT_REAPER_SESSIONS_DIR:-/Users/athos/.claude/sessions}"
BD="${BD_BIN:-bd}"
PS="${PS_BIN:-ps}"
ENABLED="${TRANSCRIPT_REAPER_ENABLED:-1}"
DRY_RUN="${TRANSCRIPT_REAPER_DRY_RUN:-0}"
MIN_AGE_HOURS="${TRANSCRIPT_REAPER_MIN_AGE_HOURS:-24}"
SELF_SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
PROD="${TRANSCRIPT_REAPER_PROD:-0}"

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null || true; }

# ════════════════════════════════════════════════════════════════════════════
# PURE DECISION FUNCTIONS — unit-tested by transcript-reaper.selftest.sh.
# Identical safety contract to scratchpad-reaper.sh's (dead AND stale AND
# not-self); duplicated rather than shared so each guard stays a fully
# standalone, independently-testable script — same no-shared-lib convention
# dolt-disk-floor-guard.sh/scratchpad-reaper.sh already use.
# ════════════════════════════════════════════════════════════════════════════

# _session_is_live <session_id> <live_keys_file> → 0 (true) iff session_id
# appears as an EXACT line in live_keys_file (grep -x — a prefix match must
# never count as live).
_session_is_live() {
  local sid="$1" keyfile="$2"
  [ -f "$keyfile" ] || return 1
  grep -qxF "$sid" "$keyfile" 2>/dev/null
}

# _is_stale <mtime_epoch> <now_epoch> <min_age_hours> → 0 (true) iff the
# file's mtime is at/past min_age_hours old. Non-numeric input (a `stat`
# failure) is NEVER stale — an unreadable mtime must not silently authorize
# deletion.
_is_stale() {
  local mtime="$1" now="$2" min_hours="$3"
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  [ $(( (now - mtime) / 3600 )) -ge "$min_hours" ]
}

# _should_reap <session_id> <live_keys_file> <mtime_epoch> <now_epoch>
#              <min_age_hours> <self_session_id>
# → 0 (true) iff: not the caller's own session, AND not in the live list, AND
# stale past min_age_hours. This is the SOLE gate for deletion.
_should_reap() {
  local sid="$1" keyfile="$2" mtime="$3" now="$4" min_hours="$5" self="$6"
  [ -n "$self" ] && [ "$sid" = "$self" ] && return 1
  _session_is_live "$sid" "$keyfile" && return 1
  _is_stale "$mtime" "$now" "$min_hours"
}

# _workdir_to_project_slug <work_dir> → the Claude Code project-directory
# name derived from a working directory: every '/' and '.' becomes '-'.
# Verified against this machine's live ~/.claude/projects/ entries, e.g.
# /Users/athos/gt/.gascity-gastown-hq -> -Users-athos-gt--gascity-gastown-hq.
_workdir_to_project_slug() {
  printf '%s' "$1" | tr '/.' '-'
}

# _prod_sentinel_active <resolved_root> <real_default_root> <prod_flag> → 0
# (true) iff resolved_root exactly equals real_default_root AND prod_flag is
# not "1". This is the ga-h565g guard (completed for this file by ga-lfj05): a
# caller (test or otherwise) that fails to override the root — leaving it at
# its real-default value — must never be able to trigger deletion just
# because it ALSO forgot to opt in; both conditions are required to authorize
# touching the real default root. Identical to scratchpad-reaper.sh's
# function of the same name.
_prod_sentinel_active() {
  local root="$1" real_default="$2" prod="$3"
  [ "$root" = "$real_default" ] && [ "$prod" != "1" ]
}

# ════════════════════════════════════════════════════════════════════════════
# EXECUTION (side-effecting). transcript-reaper.selftest.sh unit-tests the
# pure functions above AND integration-tests main() end-to-end against a
# disposable tmp root (scratchpad-reaper.sh's precedent only unit-tests its
# pure functions — this goes one step further given a transcript is
# irreplaceable data, not regeneratable scratch).
# ════════════════════════════════════════════════════════════════════════════

# _shield_unresolved_session <out_file> <work_dir> <transcript_root> —
# appends every session-id found under <work_dir>'s project directory to
# <out_file> (the same live-keys file _session_is_live reads). Used for a
# `gc session list` entry that has NO session_key: we can't name its
# transcript file directly (no UUID on record), but any .jsonl already
# sitting in its project directory could be it, so all of them get the same
# protection a genuinely-live session_key would grant. No-op when work_dir
# is empty or its project directory doesn't exist — nothing to shield.
_shield_unresolved_session() {
  local out="$1" work_dir="$2" root="$3" dir f sid
  [ -n "$work_dir" ] || return 0
  dir="$root/$(_workdir_to_project_slug "$work_dir")"
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.jsonl; do
    [ -f "$f" ] || continue
    sid="$(basename "$f" .jsonl)"
    printf '%s\n' "$sid" >> "$out"
  done
}

# _fetch_live_keys <out_file> → writes one session_key per line to out_file,
# PLUS shielded ids for sessions we can't positively name (see below).
# Returns nonzero on ANY failure to positively confirm liveness data (nonzero
# exit, empty stdout, or `.sessions` missing/null/non-array) — a failure here
# must abort the whole cycle upstream, never be read as "nobody's alive, reap
# everything" (ga-p5q3 class). NOTE: `has("sessions")` alone is NOT this check
# — has() returns true for `{"sessions": null}` too (key presence, not value
# shape), which is precisely the gate:fix-attempt:2 finding: null collapsed to
# the same outcome as `[]`, jq's `.sessions[]` then errored (exit 5) on the
# null, got swallowed by `2>/dev/null`, and _fetch_live_keys returned 0 with an
# empty keyfile — every session read as dead. `(.sessions | type) == "array"`
# rejects null/missing/non-array roots alike (verified empirically) and
# subsumes the old has() check. Deliberately no --state flag: the default
# listing (active + suspended/asleep + anything not closed) is exactly
# ga-t1ub9's stated dead-session criterion.
#
# session_key can be null/absent on a live entry — observed on this system
# for a registered-but-never-started session slot (last_active is the zero
# value) and for a non-Claude managed process tracked by the same session
# list. The original implementation dropped these via `// empty`, giving
# them ZERO reap protection: _session_is_live can only match an id it was
# told about, so if such an entry ever turns out to own a real .jsonl,
# nothing would stop it being reaped once stale — the exact third-state
# collapse (unknown treated as the wrong-direction default) this reaper's
# own safety contract forbids. We can't name their transcript file (no
# session_key), so instead of excluding them we shield by work_dir: every
# .jsonl already in that project directory is added to the SAME live-keys
# file real session_keys go into. Over-protecting a directory is the safe
# direction for an irreversible delete; under-protecting one is not.
_fetch_live_keys() {
  local out="$1" raw rc
  raw="$("$GC" session list --json 2>/dev/null)"
  rc=$?
  if [ $rc -ne 0 ] || [ -z "$raw" ]; then
    log "ABORT: 'gc session list --json' failed (rc=$rc) or returned empty — cannot verify liveness"
    return 1
  fi
  if ! printf '%s' "$raw" | jq -e '(.sessions | type) == "array"' >/dev/null 2>&1; then
    log "ABORT: 'gc session list --json' .sessions is missing, null, or non-array — cannot verify liveness"
    return 1
  fi

  : > "$out"
  printf '%s' "$raw" | jq -r '.sessions[] | select((.session_key // "") != "") | .session_key' >> "$out" 2>/dev/null

  local unresolved entry name id state wd
  unresolved="$(printf '%s' "$raw" | jq -c '.sessions[] | select((.session_key // "") == "")' 2>/dev/null)"
  if [ -n "$unresolved" ]; then
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      name="$(printf '%s' "$entry" | jq -r '.session_name // .name // "?"' 2>/dev/null)"
      id="$(printf '%s' "$entry" | jq -r '.id // "?"' 2>/dev/null)"
      state="$(printf '%s' "$entry" | jq -r '.state // "?"' 2>/dev/null)"
      wd="$(printf '%s' "$entry" | jq -r '.work_dir // empty' 2>/dev/null)"
      if [ -n "$wd" ]; then
        log "session $name ($id, state=$state) has no session_key — shielding its project dir ($wd) instead of treating it as dead"
        _shield_unresolved_session "$out" "$wd" "$TRANSCRIPT_ROOT"
      else
        log "WARNING: session $name ($id, state=$state) has no session_key AND no work_dir — cannot shield; a transcript of its would have no reap protection"
      fi
    done <<< "$unresolved"
  fi
  return 0
}

# _pid_liveness <pid> → 0 = a process with that pid exists, 1 = none does, 2 = cannot tell (not a
# pid at all, or ps failed or complained). `ps -p`, not `kill -0`: kill -0 answers EPERM for a
# process the caller does not own, and that would read as "gone". The caller treats 0 AND 2 as
# alive — over-protecting one transcript is the safe direction for an irreversible delete; only 1
# lets a session file stop protecting its conversation. A pid the OS has since handed to a
# stranger reads as alive too: the same direction, and it lapses when that process ends.
_pid_liveness() {
  local pid="$1" out rc
  case "$pid" in ''|*[!0-9]*|0*) return 2 ;; esac     # empty, not digits, or 0/leading zero: no real pid looks like that
  # vazio (rc 1 and not a word on stdout/stderr) → 1, no such process; falhou/ilegível (an rc other than 0 and 1, or rc 1 WITH text) → 2, the caller protects; rc 0 is a live process
  out="$("$PS" -p "$pid" -o pid= 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then return 0; fi
  if [ "$rc" -eq 1 ] && [ -z "$out" ]; then return 1; fi
  return 2
}

# _fetch_live_conversations <out_file> → APPENDS to out_file (the live-keys file _fetch_live_keys
# just wrote) the id of every conversation a RUNNING Claude process is using, read from
# $SESSIONS_DIR/<pid>.json ("sessionId"). Returns nonzero when that cannot be established, and
# the caller aborts the whole cycle (ga-p5q3 class: unreadable must never read as "nobody").
#
# WHY (ga-esorlre.1; the epic's 12/11 adversarial review, read on the mini): the conversation the Athos is using in a crew is
# NOT the session_key of its session bead — he switches conversations inside the crew (/resume) and
# the live id follows only in this file (thies: live 53bf2758, bead d27b72b2; digo: live d150ee9b,
# bead 5eb94e99). _fetch_live_keys knows session_keys only, so that transcript read as DEAD and
# was deleted once 24h stale.
#
# Per file, three states:
#   - names a usable pid + sessionId, pid alive or unknown → the sessionId is protected;
#   - same, pid gone → protects nothing (a leftover file must not pin a transcript forever; the id
#     recorded in the session bead, _fetch_captured_ids, covers the window after a reboot);
#   - does NOT name a usable pid + sessionId (not JSON, a field missing, a pid that is not a whole
#     number, a sessionId that is not a plain id) → what it protects cannot be named. Only when the
#     process in its FILE NAME is provably gone is it skipped; anything else (alive, unknown, a name
#     that is no pid) aborts.
# Only `*.json` counts: on the node (Claude Code 2.1.302) a `<pid>.<hash>.key` sits beside each one and
# is not a session file.
# A directory that cannot be listed (missing, not a directory, no r/x) aborts: it must not read as
# "no live sessions".
_fetch_live_conversations() {
  local out="$1" f base fpid parsed pid sid st files=0 live=0 gone=0 skipped=0
  local sid_re='^[A-Za-z0-9][A-Za-z0-9-]{0,79}$'     # 1-80 chars, never a leading '-': grep -qxF would read it as an option
  # vazio (no *.json in the dir) → nothing extra is protected, rc 0; falhou/ilegível (dir missing, not a dir, no r/x) → ABORT, rc 1
  if [ ! -d "$SESSIONS_DIR" ] || [ ! -r "$SESSIONS_DIR" ] || [ ! -x "$SESSIONS_DIR" ]; then
    log "ABORT: live-conversation scan: sessions dir $SESSIONS_DIR is missing or unreadable — cannot tell which conversations running processes are using"
    return 1
  fi
  for f in "$SESSIONS_DIR"/*.json; do
    [ -f "$f" ] || continue          # no match leaves the literal pattern behind when nullglob is off
    files=$((files + 1))
    base="${f##*/}"
    fpid="${base%.json}"
    # vazio (valid JSON without a usable pid/sessionId) → parsed is empty; falhou/ilegível (not JSON, unreadable) → parsed is empty too: both take the unusable-file branch below
    parsed="$(jq -r 'select((.pid | type) == "number" and (.sessionId | type) == "string") | [(.pid | tostring), .sessionId] | @tsv' "$f" 2>/dev/null)"
    pid=""; sid=""
    [ -n "$parsed" ] && IFS=$'\t' read -r pid sid <<< "$parsed"
    if [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$sid" =~ $sid_re ]]; then
      _pid_liveness "$pid"; st=$?
      if [ "$st" -eq 1 ]; then
        gone=$((gone + 1))
        continue
      fi
      live=$((live + 1))
      if ! _session_is_live "$sid" "$out"; then
        log "protecting conversation $sid: pid $pid ($base) $([ "$st" -eq 0 ] && echo 'is alive' || echo 'could not be checked') and the id is not the session_key of any listed session"
      fi
      # a write that fails (the reaper runs under disk pressure) must not leave this conversation unprotected without a word
      printf '%s\n' "$sid" >> "$out" || { log "ABORT: live-conversation scan: could not record the protected id $sid in $out"; return 1; }
      continue
    fi
    case "$fpid" in
      (''|*[!0-9]*) st=2 ;;
      (*) _pid_liveness "$fpid"; st=$? ;;
    esac
    if [ "$st" -eq 1 ]; then
      skipped=$((skipped + 1))
      log "live-conversation scan: $base names no usable pid+sessionId but its process ($fpid) is gone — ignored"
      continue
    fi
    log "ABORT: live-conversation scan: $f names no usable pid+sessionId and its process ($fpid) is not provably gone — cannot tell which conversation it protects"
    return 1
  done
  log "live-conversation scan: $SESSIONS_DIR files=$files protected=$live gone=$gone ignored_unreadable_dead=$skipped"
  return 0
}

# _fetch_captured_ids <out_file> → APPENDS to out_file every metadata value, of every non-closed
# session bead, that could be a conversation id (one word, at most 80 chars). This is the id the
# capture slice (ga-esorlre.2) records in the session bead, e.g. session.live_conversation_id: it
# keeps the conversation protected in the window after a reboot, when no process is alive and
# $SESSIONS_DIR holds nothing live. No key name is hard-coded, so the two slices cannot drift
# apart: a value that is not the name of a transcript matches nothing and costs nothing, one that is
# keeps that transcript. `gc session list --json` is not a known source of free-form bead metadata
# (the fields known here are session_key, id, name, state, work_dir, alias, template), hence `bd query`
# — the form nightly-reboot.sh and quality-gate-dispatcher.sh already use (nightly-reboot.sh measured
# `bd list` blind to ephemeral session beads). Returns nonzero when the beads cannot be read.
_fetch_captured_ids() {
  local out="$1" raw rc n ids
  # vazio ([] — no non-closed session bead) → nothing captured, rc 0, but only while no live session is known either (below); falhou/ilegível (bd rc != 0, empty or non-JSON answer, not a list of objects, metadata that is not an object) → ABORT, rc 1
  raw="$("$BD" -C "$CITY" query --json 'type=session AND status!=closed' --limit=0 2>/dev/null)"
  rc=$?
  if [ $rc -ne 0 ] || [ -z "$raw" ]; then
    log "ABORT: captured-id scan: 'bd query' for the session beads failed (rc=$rc) or returned nothing — cannot read the conversation ids recorded in them"
    return 1
  fi
  if ! printf '%s' "$raw" | jq -e 'type == "array" and all(.[]; type == "object" and (.metadata == null or (.metadata | type) == "object"))' >/dev/null 2>&1; then
    log "ABORT: captured-id scan: 'bd query' did not answer a list of beads with object metadata — cannot read the conversation ids recorded in them"
    return 1
  fi
  n="$(printf '%s' "$raw" | jq 'length' 2>/dev/null)"
  # an empty list while sessions are known live is not believed: gc and bd read the same store, so the query is broken, not "nothing captured"
  if [ "$n" = "0" ] && [ -s "$out" ]; then
    log "ABORT: captured-id scan: 'bd query' returned no session bead although live sessions are listed — the answer is not believed"
    return 1
  fi
  ids="$(printf '%s' "$raw" | jq -r '.[] | (.metadata // {}) | to_entries[] | .value | select(type == "string" and length >= 1 and length <= 80 and (test("\\s") | not))' 2>/dev/null)"
  rc=$?
  if [ $rc -ne 0 ]; then
    log "ABORT: captured-id scan: could not extract the metadata values from the 'bd query' answer (jq rc=$rc)"
    return 1
  fi
  # same reason as in the live-conversation scan: a failed write is a failure, not "nothing captured"
  if [ -n "$ids" ] && ! printf '%s\n' "$ids" >> "$out"; then
    log "ABORT: captured-id scan: could not record the metadata values in $out"
    return 1
  fi
  log "captured-id scan: session beads=$n values kept=$(printf '%s' "$ids" | grep -c .)"
  return 0
}

main() {
  if [ ! -d "$TRANSCRIPT_ROOT" ]; then
    log "TRANSCRIPT_ROOT $TRANSCRIPT_ROOT does not exist — nothing to do"
    return 0
  fi

  if _prod_sentinel_active "$TRANSCRIPT_ROOT" "$TRANSCRIPT_REAL_DEFAULT_ROOT" "$PROD"; then
    log "SENTINEL: resolved root ($TRANSCRIPT_ROOT) equals the real default and no production opt-in is set (TRANSCRIPT_REAPER_PROD=1) — forcing dry-run this cycle (ga-h565g production sentinel)"
    DRY_RUN=1
  fi

  local keyfile now reaped=0 freed_kb=0 candidates=0
  keyfile="$(mktemp "${TMPDIR:-/tmp}/transcript-reaper-live.XXXXXX" 2>/dev/null || echo "/tmp/transcript-reaper-live.$$")"
  trap 'rm -f "$keyfile"' RETURN

  if ! _fetch_live_keys "$keyfile"; then
    log "ABORT: skipping reap cycle entirely — could not establish a trustworthy live-session set"
    return 1
  fi
  # ga-esorlre.1: session_key is not the conversation the Athos is using. Both scans APPEND to the
  # file _fetch_live_keys just truncated and wrote, so _should_reap stays the single gate.
  if ! _fetch_live_conversations "$keyfile"; then
    log "ABORT: skipping reap cycle entirely — could not establish which conversations running processes are using"
    return 1
  fi
  if ! _fetch_captured_ids "$keyfile"; then
    log "ABORT: skipping reap cycle entirely — could not read the conversation ids recorded in the session beads"
    return 1
  fi

  now=$(date +%s)
  shopt -s nullglob
  local file sid proj mtime kb sib_dir sib_kb total_kb ok
  for file in "$TRANSCRIPT_ROOT"/*/*.jsonl; do
    [ -f "$file" ] || continue
    proj="$(basename "$(dirname "$file")")"
    sid="$(basename "$file" .jsonl)"
    mtime="$(stat -f %m "$file" 2>/dev/null || echo "")"
    if _should_reap "$sid" "$keyfile" "$mtime" "$now" "$MIN_AGE_HOURS" "$SELF_SESSION_ID"; then
      candidates=$((candidates + 1))
      sib_dir="$(dirname "$file")/$sid"
      kb="$(du -sk "$file" 2>/dev/null | awk '{print $1}')"
      sib_kb=0
      [ -d "$sib_dir" ] && sib_kb="$(du -sk "$sib_dir" 2>/dev/null | awk '{print $1}')"
      total_kb=$(( ${kb:-0} + ${sib_kb:-0} ))
      if [ "$ENABLED" != "1" ] || [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN would reap: $proj/$sid.jsonl (${total_kb}KB, sibling_dir=$([ -d "$sib_dir" ] && echo yes || echo no))"
      else
        ok=1
        rm -f "$file" 2>>"$LOG" || ok=0
        if [ -d "$sib_dir" ]; then
          rm -rf "$sib_dir" 2>>"$LOG" || ok=0
        fi
        if [ "$ok" = "1" ]; then
          reaped=$((reaped + 1))
          freed_kb=$((freed_kb + total_kb))
          log "reaped: $proj/$sid.jsonl (${total_kb}KB freed)"
        else
          log "FAILED to reap: $proj/$sid.jsonl (partial deletion possible — check manually)"
        fi
      fi
    fi
  done

  log "cycle complete: candidates=$candidates reaped=$reaped freed_kb=$freed_kb root=$TRANSCRIPT_ROOT min_age_hours=$MIN_AGE_HOURS enabled=$ENABLED dry_run=$DRY_RUN"
}

# ── run unless sourced as a library (selftest sources with TRANSCRIPT_REAPER_LIB=1) ──
if [ "${TRANSCRIPT_REAPER_LIB:-0}" != "1" ]; then
  main
  exit $?
fi
