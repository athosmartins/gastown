#!/bin/bash
# e9-arms.sh — ga-798p6w (E9, child of the P0 ga-ufskhy): the refiner as PLANNER + a complexity level, as an A/B.
#
# WHAT THIS IS. Athos's two ideas (01/10): (a) a complexity level is always assigned, which will later route the builder's
# model x effort; (b) the builder is handed a plan of HOW (files, functions, edge cases, the failing test), not just WHAT.
# Both are hypotheses about "more beads DONE, fewer tokens per bead DONE", so this ships as an experiment.
#
# TWO STAGES SHARE THIS LIBRARY. The arm, the roster, the level-from-facts rule and the plan-structure check live here and are
# the same wherever a bead is first seen:
#   * builder-start  — e9-plan.sh (WIRED: the Pilot's dispatch comment points the builder at it). It reaches every build, which
#                      is the reason it is the stage that carries the experiment: at most ~5% of built beads could pass the refiner
#                      (docs/e9-planner-complexity.md section 1).
#   * refiner        — `block` / `finalize` / `check` / `plancheck` below, for the autonomous refiner of stories. NOT wired into
#                      auto-refino-dispatcher.sh in this slice; kept, tested, and inert until a follow-up connects it. A bead that
#                      already carries a valid plan from either stage is REUSED by e9-plan.sh, never planned twice.
# The experiment ships as an experiment:
#   - COMPLEXITY is recorded for every refined bead (the level is a measurement field first, a routing key only after the
#     numbers say so — see docs/e9-planner-complexity.md for why routing itself is NOT built here);
#   - the PLAN is produced only for the beads in the treatment arm; the control arm is the refiner exactly as it is today.
#
# INERT BY DEFAULT (same promise as E8's effort A/B): with no $STATE/e9-ab.conf — or with the kill switch $STATE/no-e9-ab —
# every command below prints nothing that changes behaviour and the refiner's prompt is byte-for-byte what it was.
#
#   Turn on (Mayor's decision, not a worker's):
#     cat > "$GC_CITY_PATH/.gc/e9-ab.conf" <<'EOF'
#     planner_pct=50
#     complexity=on
#     salt=e9a
#     EOF
#   Turn off:  touch "$GC_CITY_PATH/.gc/no-e9-ab"   (or rm the conf) — takes effect on the next refine, no reload.
#
# THE LEVEL IS COMPUTED, NEVER ASSERTED. The refiner records FACTS it can read off the code (files, runtime surfaces,
# external effect, migration); this script turns them into S/M/L. A refiner that "feels" the bead is L cannot write L — and
# `check` recomputes the level from the recorded facts, so a level that disagrees with its own facts is visible.
#
# THREE STATES, NEVER TWO. Every read that can be missing has three answers and they are never collapsed: the value is there /
# the value is not there / it could not be determined (a refiner that cannot estimate says "desconhecido", which is not "S").
# A malformed conf is its own state (`invalid`), not "no conf" — a typo'd key must not silently run the experiment at 0%.
#
# Commands (all read-only unless noted; exit codes are part of the contract):
#   state                                  prints absent | killed | invalid:<why> | active  (+ the parsed values on `active`)
#   arm planner <bead-id>                  prints on | off. PURE: ignores the conf's on/off, uses its salt and pct.
#                                          exit 2 = empty id / bad conf, 3 = no sha256 tool (prints NOTHING: "no arm" is not "off")
#   arms planner                           ids on stdin → "<id> on|off" lines (the readout's recompute; stops at the first id with no arm)
#   assign <bead-id> [store]               WRITES the roster. While the experiment is active prints on|off and records who was
#                                          assigned (the control arm needs a denominator); with no conf / the kill switch prints
#                                          nothing, exit 0 (the experiment is legitimately OFF).
#                                          ONE assignment per bead per salt: a bead that already has a row gets THAT row's arm back,
#                                          whatever the conf says now (a pct ramp must not flip a re-dispatched bead).
#                                          exit 3 = no arm (bad id, no sha tool, roster unreadable), 5 = arm decided but NOT recorded
#                                          (roster unwritable), 6 = the conf is INVALID (a typo'd key: the experiment is NOT running and
#                                          nobody asked for that); all three print nothing — a bead with no roster row gets no treatment.
#                                          6 is its own code because the one real caller (the Pilot) drops stderr and logs only a
#                                          non-zero exit: with the same silent 0 as "off", a typo at turn-on ran at 0% unseen.
#   peek <bead-id>                         assign without the write: the recorded arm, else the pure arm of the current conf. Exits 0|3|6.
#   block <bead-id> <store>                the text spliced into the refiner's prompt ('' when inert); records the assignment. Exit 6
#                                          on an invalid conf, like assign.
#   complexity <files> <surfaces> <external:0|1> <migration:0|1>   prints S | M | L. exit 2 on any bad argument — never a default.
#   finalize                               reads the bead's `bd show --json` on stdin, prints the writes to apply (see below)
#   check                                  reads `bd show --json` on stdin: ok | absent | unknown | malformed | mismatch
#                                          (a level still recorded next to facts that say "desconhecido" is a mismatch, not "unknown")
#
# Arm recipe (recomputable by anyone):  bucket = first 32 bits of SHA-256("e9-planner:<salt>:<bead-id>") mod 100;
#   on <=> bucket < planner_pct.   e.g.  printf '%s' "e9-planner:e9a:ga-abc123" | shasum -a 256 | cut -c1-8
# The "e9-planner:" prefix is not decoration: E3's arm is the parity of SHA-256("pregate:<id>"), and ga-rstae's polynomial hash
# was measured to AGREE with a salted copy of itself 43% of the time. Two experiments over the same beads must not be the same
# coin; the selftest measures this arm against E3's.
#
# Complexity scale (the starting point, not the answer — the table is revised after the measurement):
#   L  if the build sends anything outside the system (externo=1: a message to a lead/client, spend, a write to a third
#      party), or needs a migration/backfill (migracao=1), or touches >=3 independent runtime surfaces, or >=8 files;
#   S  if it changes <=2 files on <=1 surface, with none of the above;
#   M  everything else.

# Not `set -e` / `set -u`-hostile: this file is also sourced by the selftest. No `exit` outside main().

e9_city() { printf '%s' "${GC_CITY:-${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}}"; }
e9_state_dir() { printf '%s' "${E9_STATE_DIR:-$(e9_city)/.gc}"; }

# ── conf ──────────────────────────────────────────────────────────────────────────────────────────────────────
# Sets E9_PCT, E9_COMPLEXITY, E9_SALT, E9_PARSE (absent | ok | invalid:<why>) and E9_STATE (absent | killed | invalid:<why> | active).
# It PRINTS NOTHING and callers must not wrap it in $(...): a subshell would throw the values away (the first draft did, and the
# roster recorded an empty salt). Never exits.
# The kill switch decides the REPORTED state only: the conf is still parsed, so `arm` can recompute an arm after the experiment
# was switched off (the readout needs that), and a malformed conf stays visible instead of hiding behind the switch.
e9_conf_load() {
  E9_PCT=0; E9_COMPLEXITY=off; E9_SALT=e9a; E9_PARSE=absent; E9_STATE=absent
  local dir conf line key val killed=0
  dir="$(e9_state_dir)"; conf="$dir/e9-ab.conf"
  [ -e "$dir/no-e9-ab" ] && killed=1
  if [ ! -e "$conf" ]; then if [ "$killed" = 1 ]; then E9_STATE=killed; else E9_STATE=absent; fi; return 0; fi
  E9_PARSE=ok
  if [ ! -r "$conf" ]; then E9_PARSE="invalid:unreadable"; fi
  while [ "$E9_PARSE" = ok ] && { IFS= read -r line || [ -n "$line" ]; }; do
    line="${line%%#*}"
    # trim both ends (bash 3.2: no ${var,,}, no extglob assumptions)
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    case "$line" in *=*) ;; *) E9_PARSE="invalid:no-equals:$line"; break ;; esac
    key="${line%%=*}"; val="${line#*=}"
    case "$key" in
      planner_pct)
        case "$val" in ''|*[!0-9]*) E9_PARSE="invalid:planner_pct=$val"; break ;; esac
        if [ "${#val}" -gt 3 ] || [ "$((10#$val))" -gt 100 ]; then E9_PARSE="invalid:planner_pct=$val"; break; fi
        E9_PCT=$((10#$val)) ;;
      complexity)
        case "$val" in on|off) E9_COMPLEXITY="$val" ;; *) E9_PARSE="invalid:complexity=$val"; break ;; esac ;;
      salt)
        case "$val" in ''|*[!A-Za-z0-9._-]*) E9_PARSE="invalid:salt=$val"; break ;; esac
        if [ "${#val}" -gt 32 ]; then E9_PARSE="invalid:salt-too-long"; break; fi
        E9_SALT="$val" ;;
      *) E9_PARSE="invalid:unknown-key:$key"; break ;;
    esac
  done < "$conf"
  if [ "$E9_PARSE" = ok ] && [ "$E9_PCT" -eq 0 ] && [ "$E9_COMPLEXITY" = off ]; then E9_PARSE="invalid:nothing-enabled"; fi
  if [ "$killed" = 1 ]; then E9_STATE=killed; return 0; fi
  case "$E9_PARSE" in ok) E9_STATE=active ;; *) E9_STATE="$E9_PARSE" ;; esac
}

e9_cmd_state() {
  e9_conf_load
  if [ "$E9_STATE" = active ]; then echo "active planner_pct=$E9_PCT complexity=$E9_COMPLEXITY salt=$E9_SALT"; else echo "$E9_STATE"; fi
}

# ── arm ───────────────────────────────────────────────────────────────────────────────────────────────────────
# First 8 hex digits of SHA-256(<string>), or return 3 (prints nothing) when no tool works. Fast C tools first: shasum is a perl
# script (~0.1 s a call under load). E9_SHA_TOOLS (space-separated: sha256sum openssl shasum) exists so the selftest can take
# tools away and see the third state.
e9_sha8() {
  local d t
  for t in ${E9_SHA_TOOLS:-sha256sum openssl shasum}; do
    d=""
    case "$t" in
      sha256sum) command -v sha256sum >/dev/null 2>&1 && d="$(printf '%s' "$1" | sha256sum 2>/dev/null | cut -c1-8)" ;;
      openssl)   command -v openssl   >/dev/null 2>&1 && d="$(printf '%s' "$1" | openssl dgst -sha256 -r 2>/dev/null | cut -c1-8)" ;;
      shasum)    command -v shasum    >/dev/null 2>&1 && d="$(printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -c1-8)" ;;
    esac
    case "$d" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) printf '%s' "$d"; return 0 ;; esac
  done
  return 3
}

# e9_arm_for <bead-id>  → on|off. Uses E9_SALT/E9_PCT as left by e9_conf_load (callers load first).
e9_arm_for() {
  local bead="${1:-}" d
  [ -n "$bead" ] || return 2
  case "$bead" in *[[:space:]]*) return 2 ;; esac
  d="$(e9_sha8 "e9-planner:$E9_SALT:$bead")" || return 3
  if [ "$(( 16#$d % 100 ))" -lt "$E9_PCT" ]; then echo on; else echo off; fi
}

e9_cmd_arm() {
  local kind="${1:-}" bead="${2:-}"
  [ "$kind" = planner ] || { echo "usage: e9-arms.sh arm planner <bead-id>" >&2; return 2; }
  e9_conf_load
  case "$E9_PARSE" in
    absent)    echo "e9: no e9-ab.conf — there is no experiment, so no arm (not 'off')" >&2; return 4 ;;
    invalid:*) echo "e9: $E9_PARSE" >&2; return 2 ;;
  esac
  e9_arm_for "$bead"
}

# arms planner — bead ids on stdin, one per line → "<id> on|off" per line. Stops with exit 3 (and says which id) rather than skip one:
# a missing row is not "off". The readout recomputes thousands of arms and the loop below costs a handful of forks per id (~50 ms each at
# load 60: the readout selftest took 10+ minutes), so a batch is computed by ONE python3 process with the same recipe as e9_arm_for.
# The shell rule (e9_arm_for) stays the reference: the selftest compares the batch against the documented recipe computed independently
# AND against the shell loop, including the refusal cases. The loop is used when python3 is missing, when E9_SHA_TOOLS is set (the
# selftest takes hash tools away to see the third state, and that has to reach this command too), and when python3 fails for any reason
# other than "an id has no arm" — a crash in the fast path must never turn into a missing or partial table.
e9_cmd_arms() {
  local kind="${1:-}" id arm input out rc prog
  [ "$kind" = planner ] || { echo "usage: e9-arms.sh arms planner < ids" >&2; return 2; }
  e9_conf_load
  case "$E9_PARSE" in
    absent)    echo "e9: no e9-ab.conf — there is no experiment, so no arm (not 'off')" >&2; return 4 ;;
    invalid:*) echo "e9: $E9_PARSE" >&2; return 2 ;;
  esac
  input="$(cat)"
  if [ -z "${E9_SHA_TOOLS:-}" ] && command -v python3 >/dev/null 2>&1; then
    prog="$(cat <<'E9PYBATCH'
import hashlib, sys
salt, pct = sys.argv[1].encode(), int(sys.argv[2])
out = sys.stdout.buffer
for raw in sys.stdin.buffer.read().split(b"\n"):
    if not raw:
        continue
    if any(c in raw for c in b" \t\v\f\r"):          # the shell rule refuses an id with whitespace (it is not an id)
        out.flush()
        sys.stderr.write("e9: no arm for '%s'\n" % raw.decode("utf-8", "replace"))
        sys.exit(3)
    d = hashlib.sha256(b"e9-planner:" + salt + b":" + raw).hexdigest()[:8]
    out.write(raw + (b" on\n" if int(d, 16) % 100 < pct else b" off\n"))
E9PYBATCH
)"
    out="$(printf '%s\n' "$input" | python3 -c "$prog" "$E9_SALT" "$E9_PCT")"; rc=$?
    case "$rc" in
      0) [ -z "$out" ] || printf '%s\n' "$out"; return 0 ;;
      3) [ -z "$out" ] || printf '%s\n' "$out"; return 3 ;;   # an id with no arm: the table so far, then stop — same as the loop
    esac
  fi
  while IFS= read -r id || [ -n "$id" ]; do
    [ -n "$id" ] || continue
    arm="$(e9_arm_for "$id")" || { echo "e9: no arm for '$id'" >&2; return 3; }
    printf '%s %s\n' "$id" "$arm"
  done <<< "$input"
}

# ── roster ────────────────────────────────────────────────────────────────────────────────────────────────────
e9_roster() { printf '%s' "$(e9_state_dir)/e9-roster.jsonl"; }

# e9_record <event> k=v ...   one JSON line, built by jq so a bead title or a "quote" can never corrupt the file.
e9_record() {
  local event="$1"; shift
  local args=() kv
  for kv in "$@"; do args+=(--arg "${kv%%=*}" "${kv#*=}"); done
  command -v jq >/dev/null 2>&1 || return 3
  mkdir -p "$(e9_state_dir)" 2>/dev/null || return 3
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg event "$event" ${args[@]+"${args[@]}"} \
    '{ts:$ts,event:$event} + ($ARGS.named | del(.ts,.event))' >> "$(e9_roster)" 2>/dev/null || return 3
}

# e9_recorded_arm <bead> <salt> — the arm the ROSTER holds for this bead under this salt (the first assignment wins). Three answers:
#   rc 0  prints on|off    the roster has a row for it
#   rc 1  prints nothing   there is no row (no roster file, or a readable roster without one) — the only case where an arm may be COMPUTED
#   rc 3  prints nothing   it cannot be told: the roster exists but cannot be read, jq is missing, or the row's arm is not on|off
# A line that is not a JSON object (a truncated write) is skipped, not fatal: one bad line must not make every bead look unassigned —
# that is how a bead used to collect a fresh assign row per re-dispatch. The ROW: prefix is what tells "a row without an arm" from "no row".
e9_recorded_arm() {
  local r out rc first; r="$(e9_roster)"
  [ -e "$r" ] || return 1
  { [ -f "$r" ] && [ -r "$r" ]; } || return 3
  command -v jq >/dev/null 2>&1 || return 3
  out="$(jq -R -r --arg b "$1" --arg s "$2" \
    'try fromjson catch empty | select(type=="object" and .event=="assign" and .bead==$b and .salt==$s) | "ROW:" + ((.planner_arm // "") | tostring)' "$r" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || return 3
  [ -n "$out" ] || return 1
  first="${out%%$'\n'*}"; first="${first#ROW:}"
  case "$first" in on|off) printf '%s' "$first"; return 0 ;; *) return 3 ;; esac
}

e9_bad_bead_id() { case "${1:-}" in ''|*[[:space:]]*) return 0 ;; esac; return 1; }

# e9_state_gate — what a command that hands out an arm does with the conf's state (call after e9_conf_load). Three states, three answers:
#   0  active                      carry on
#   1  absent | killed             the experiment is legitimately OFF: the caller prints nothing and exits 0
#   6  invalid:*                   the conf exists but cannot be read (a typo'd key): the experiment is NOT running and nobody chose that.
#                                  Said on stderr AND by the exit code — the one real caller discards stderr and logs only a non-zero exit.
e9_state_gate() {
  case "$E9_STATE" in
    active)        return 0 ;;
    absent|killed) return 1 ;;
    *)             echo "e9: the experiment config is unusable ($E9_STATE) — no arm is handed out, the experiment is NOT running; fix or remove $(e9_state_dir)/e9-ab.conf" >&2
                   return 6 ;;
  esac
}

# assign <bead> [store] [stage] — the arm the bead is IN, recorded once per (bead, salt); every later call, from any stage, prints
# THAT recorded arm. Recomputing it from the current conf instead would let a pct ramp (canary -> 50%) tell a re-dispatched bead to run
# the paid planner while the roster counts it as control — the variable decided on must be the variable acted on.
#   exit 0  the arm is printed (on|off), or nothing is printed because the experiment is not active
#   exit 3  no arm could be determined (bad id, no sha tool, roster unreadable): prints nothing — "no arm" is neither on nor off
#   exit 5  the arm was determined but could NOT be recorded: prints nothing. A bead with no roster row has no denominator slot, so it
#           gets no treatment and no hint; the exit code (not only stderr) lets a caller that discards stderr notice and log it.
e9_cmd_assign() {
  local bead="${1:-}" store="${2:-}" stage="${3:-}" arm rec rrc g=0
  e9_conf_load
  e9_state_gate || g=$?
  case "$g" in 0) ;; 1) return 0 ;; *) return "$g" ;; esac
  e9_bad_bead_id "$bead" && { echo "e9: cannot assign an arm to '$bead'" >&2; return 3; }
  rec="$(e9_recorded_arm "$bead" "$E9_SALT")"; rrc=$?
  case "$rrc" in
    0) printf '%s\n' "$rec"; return 0 ;;
    1) ;;
    *) echo "e9: the roster cannot be read, so it cannot be told whether '$bead' was already assigned — no arm (not a recompute)" >&2; return 3 ;;
  esac
  arm="$(e9_arm_for "$bead")" || { echo "e9: cannot assign an arm to '$bead' (rc=$?)" >&2; return 3; }
  # `stage` (optional) says which stage first saw the bead — refiner | pilot-dispatch | builder-start. The arm does not depend on it:
  # one assignment per bead per salt, whoever asks first records it, and every later stage reads the same answer.
  e9_record assign bead="$bead" store="$store" salt="$E9_SALT" planner_arm="$arm" planner_pct="$E9_PCT" complexity="$E9_COMPLEXITY" \
    ${stage:+stage="$stage"} \
    || { echo "e9: WARN: assignment for $bead NOT recorded (roster unwritable) — no arm handed out" >&2; return 5; }
  printf '%s\n' "$arm"
}

# peek <bead> — the arm assign WOULD print, without writing anything: the recorded arm if the roster has one, else the pure arm of
# the current conf. For inspection (`e9-plan.sh run --dry-run / --print-task`): looking at a bead must not enrol it — the roster is the
# experiment's denominator, and the first assignment fixes the arm at the pct of that moment. Same exits as assign minus 5.
e9_cmd_peek() {
  local bead="${1:-}" arm rec rrc g=0
  e9_conf_load
  e9_state_gate || g=$?
  case "$g" in 0) ;; 1) return 0 ;; *) return "$g" ;; esac
  e9_bad_bead_id "$bead" && { echo "e9: cannot peek an arm for '$bead'" >&2; return 3; }
  rec="$(e9_recorded_arm "$bead" "$E9_SALT")"; rrc=$?
  case "$rrc" in
    0) printf '%s\n' "$rec"; return 0 ;;
    1) ;;
    *) echo "e9: the roster cannot be read, so it cannot be told whether '$bead' was already assigned — no arm (not a recompute)" >&2; return 3 ;;
  esac
  arm="$(e9_arm_for "$bead")" || { echo "e9: cannot determine an arm for '$bead' (rc=$?)" >&2; return 3; }
  printf '%s\n' "$arm"
}

# ── complexity ────────────────────────────────────────────────────────────────────────────────────────────────
e9_is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 6 ]; }

e9_complexity() {
  [ $# -eq 4 ] || return 2   # a stray fifth argument is a caller bug, not something to ignore on the way to a level
  local files="${1:-}" surfaces="${2:-}" external="${3:-}" migration="${4:-}"
  e9_is_uint "$files" && e9_is_uint "$surfaces" || return 2
  case "$external" in 0|1) ;; *) return 2 ;; esac
  case "$migration" in 0|1) ;; *) return 2 ;; esac
  files=$((10#$files)); surfaces=$((10#$surfaces))
  # A bead that changes no file or touches no surface is not a build the scale can size — refuse, do not call it "S".
  [ "$files" -ge 1 ] && [ "$surfaces" -ge 1 ] || return 2
  if [ "$external" = 1 ] || [ "$migration" = 1 ] || [ "$surfaces" -ge 3 ] || [ "$files" -ge 8 ]; then echo L
  elif [ "$files" -le 2 ] && [ "$surfaces" -le 1 ]; then echo S
  else echo M; fi
}

# e9_parse_facts "<text>" → sets F_FILES F_SURF F_EXT F_MIG; return 0 ok, 1 malformed (E9_WHY says why).
# Order-insensitive key=value tokens; all four exactly once; anything else is malformed, never "close enough".
e9_parse_facts() {
  local text="$1" tok k v n_f=0 n_s=0 n_e=0 n_m=0
  E9_WHY=""; F_FILES=""; F_SURF=""; F_EXT=""; F_MIG=""
  for tok in $text; do
    case "$tok" in *=*) ;; *) E9_WHY="token-sem-igual:$tok"; return 1 ;; esac
    k="${tok%%=*}"; v="${tok#*=}"
    case "$k" in
      arquivos)    F_FILES="$v"; n_f=$((n_f+1)) ;;
      superficies) F_SURF="$v";  n_s=$((n_s+1)) ;;
      externo)     F_EXT="$v";   n_e=$((n_e+1)) ;;
      migracao)    F_MIG="$v";   n_m=$((n_m+1)) ;;
      *) E9_WHY="chave-desconhecida:$k"; return 1 ;;
    esac
  done
  if [ "$n_f$n_s$n_e$n_m" != 1111 ]; then E9_WHY="faltam-ou-repetem-chaves(arquivos/superficies/externo/migracao)"; return 1; fi
  e9_complexity "$F_FILES" "$F_SURF" "$F_EXT" "$F_MIG" >/dev/null || { E9_WHY="valores-invalidos:$text"; return 1; }
  return 0
}

# e9_level_of_facts "<facts text>" → prints S | M | L when the facts parse, else `unknown`. Absent facts, "desconhecido: …" and malformed
# facts all read as unknown: a level that no recorded fact supports is not a level. Always exit 0 — callers branch on the printed word.
# This (not the recorded story.complexidade) is what a re-dispatch reads: the metadata can outlive the facts it was computed from.
e9_level_of_facts() {
  local t lvl
  t="$(printf '%s' "${1:-}" | tr '\n' ' ' | sed 's/^ *//; s/ *$//')"
  case "$t" in ''|desconhecido*) echo unknown; return 0 ;; esac
  if e9_parse_facts "$t" && lvl="$(e9_complexity "$F_FILES" "$F_SURF" "$F_EXT" "$F_MIG")"; then echo "$lvl"; else echo unknown; fi
  return 0
}

# bd show --json → the one object (bd prints an array for `show`); metadata may be missing or not an object.
e9_bead_field() {   # <json> <jq-filter>
  printf '%s' "$1" | jq -r "(if type==\"array\" then .[0] else . end) | $2" 2>/dev/null
}

# Reads: facts (string|""), level label(s), recorded metadata level, plan. Sets E9_J_* globals. return 1 if not JSON.
e9_bead_load() {
  local json="$1"
  # `bd show` of an id it cannot find prints [] — that is "could not read the bead", not "the bead has no complexity".
  printf '%s' "$json" | jq -e '(if type=="array" then .[0] else . end) | type=="object"' >/dev/null 2>&1 || return 1
  E9_J_FACTS="$(e9_bead_field "$json" '(if (.metadata|type)=="object" then .metadata else {} end) | .["story.complexidade_fatos"] // "" | if type=="string" then . else "" end')"
  E9_J_LEVEL_META="$(e9_bead_field "$json" '(if (.metadata|type)=="object" then .metadata else {} end) | .["story.complexidade"] // "" | if type=="string" then . else "" end')"
  E9_J_LABELS="$(e9_bead_field "$json" '[(.labels // [])[] | select(type=="string" and startswith("complexity:"))] | join(",")')"
  E9_J_PLAN="$(e9_bead_field "$json" '(if (.metadata|type)=="object" then .metadata else {} end) | .["story.plano_tecnico"] // "" | if type=="string" then . else "" end')"
  return 0
}

# finalize: the refiner wrote the FACTS; this decides what the dispatcher writes — the level is computed here, in code.
# Prints one directive per line:  SET <key>=<value> | UNSET <key> | LABEL <l> | UNLABEL <l> | STATUS <word>=<value>
e9_cmd_finalize() {
  local json lvl old trimmed keep=""
  json="$(cat)"
  e9_bead_load "$json" || { echo "STATUS complexity=unreadable"; return 0; }
  trimmed="$(printf '%s' "$E9_J_FACTS" | tr '\n' ' ' | sed 's/^ *//; s/ *$//')"
  case "$trimmed" in
    '')            e9_unlabel_stale ""; e9_unset_stale; echo "STATUS complexity=absent"; return 0 ;;
    desconhecido*) e9_unlabel_stale ""; e9_unset_stale; echo "STATUS complexity=unknown"; return 0 ;;
  esac
  if e9_parse_facts "$trimmed"; then
    lvl="$(e9_complexity "$F_FILES" "$F_SURF" "$F_EXT" "$F_MIG")"
    e9_unlabel_stale "complexity:$lvl"
    echo "SET story.complexidade=$lvl"
    echo "LABEL complexity:$lvl"
    echo "STATUS complexity=ok:$lvl"
  else
    e9_unlabel_stale ""; e9_unset_stale
    echo "STATUS complexity=malformed:$E9_WHY"
  fi
}

# The level RECORDED in the metadata of a bead whose facts no longer support one has to go with its label: the reuse path and `check` read
# the metadata, so a label-only cleanup leaves "could not tell" rendering as the previous known level (gate ga-shag3i, blocking issue 1).
# Nothing is emitted when no level is recorded, so a bead that never had one gets no pointless write.
e9_unset_stale() { [ -z "$E9_J_LEVEL_META" ] || echo "UNSET story.complexidade"; }

# A level left by an earlier attempt whose facts have since changed must not survive (keep = the label that stays, if any).
e9_unlabel_stale() {
  local old
  for old in $(printf '%s' "$E9_J_LABELS" | tr ',' ' '); do [ "$old" = "$1" ] || echo "UNLABEL $old"; done
}

# check: audit a bead that was already finalized — does the level it carries agree with its own facts?
# exit: 0 ok · 10 absent · 11 malformed · 12 mismatch · 13 unreadable · 14 unknown
e9_cmd_check() {
  local json trimmed lvl nlab
  json="$(cat)"
  e9_bead_load "$json" || { echo unreadable; return 13; }
  trimmed="$(printf '%s' "$E9_J_FACTS" | tr '\n' ' ' | sed 's/^ *//; s/ *$//')"
  if [ -z "$trimmed" ] && [ -z "$E9_J_LEVEL_META" ] && [ -z "$E9_J_LABELS" ]; then echo absent; return 10; fi
  case "$trimmed" in desconhecido*)
    # "could not tell" with a level still recorded next to it: the level is a leftover from facts that are gone, not a measurement
    if [ -n "$E9_J_LEVEL_META" ] || [ -n "$E9_J_LABELS" ]; then echo "mismatch recorded=${E9_J_LEVEL_META:-$E9_J_LABELS} recomputed=unknown"; return 12; fi
    echo unknown; return 14 ;;
  esac
  if [ -z "$trimmed" ]; then echo "malformed:nivel-sem-fatos"; return 11; fi
  e9_parse_facts "$trimmed" || { echo "malformed:$E9_WHY"; return 11; }
  lvl="$(e9_complexity "$F_FILES" "$F_SURF" "$F_EXT" "$F_MIG")"
  nlab="$(printf '%s' "$E9_J_LABELS" | tr ',' '\n' | grep -c . || true)"
  [ "$nlab" -le 1 ] || { echo "malformed:varios-labels:$E9_J_LABELS"; return 11; }
  case "$E9_J_LEVEL_META" in ''|S|M|L) ;; *) echo "malformed:nivel-invalido:$E9_J_LEVEL_META"; return 11 ;; esac
  if [ -n "$E9_J_LEVEL_META" ] && [ "$E9_J_LEVEL_META" != "$lvl" ]; then echo "mismatch recorded=$E9_J_LEVEL_META recomputed=$lvl"; return 12; fi
  if [ -n "$E9_J_LABELS" ] && [ "$E9_J_LABELS" != "complexity:$lvl" ]; then echo "mismatch recorded=$E9_J_LABELS recomputed=$lvl"; return 12; fi
  [ -n "$E9_J_LEVEL_META" ] || { echo "malformed:fatos-sem-nivel-gravado"; return 11; }
  echo "ok level=$lvl"
}

# plan structure: all five section headings present, each followed by some text before the next heading. (Whether the plan is
# RIGHT is the builder's and the gate's call, not ours — this only refuses an empty shell, which is worse than no plan because
# it looks like one.) Headings must start a line (leading blanks allowed).
# reads $E9_J_PLAN → ok | absent | incomplete:<ARQUIVOS(ausente)|ABORDAGEM(vazia)|..., comma-separated>
e9_plan_status() {
  [ -n "$(printf '%s' "$E9_J_PLAN" | tr -d '[:space:]')" ] || { echo absent; return 0; }
  printf '%s\n' "$E9_J_PLAN" | awk '
    BEGIN { n = split("ARQUIVOS:|ABORDAGEM:|CASOS-LIMITE:|TESTE QUE REPROVA:|NAO VERIFIQUEI:", S, "|"); cur = 0 }
    { line = $0; sub(/^[ \t]+/, "", line); hit = 0
      for (i = 1; i <= n; i++) if (index(line, S[i]) == 1) {
        cur = i; seen[i] = 1; hit = 1
        rest = substr(line, length(S[i]) + 1); if (rest ~ /[^ \t\r]/) filled[i] = 1
        break }
      if (!hit && cur && line ~ /[^ \t\r]/) filled[cur] = 1 }
    END { m = ""
      for (i = 1; i <= n; i++) {
        name = S[i]; sub(/:$/, "", name)
        if (!seen[i]) m = m (m == "" ? "" : ",") name "(ausente)"
        else if (!filled[i]) m = m (m == "" ? "" : ",") name "(vazia)" }
      if (m == "") print "ok"; else print "incomplete:" m }'
}

# ── the prompt block ──────────────────────────────────────────────────────────────────────────────────────────
e9_block_text() {   # <bead> <store> <with_plan:0|1> <with_complexity:0|1>
  local bead="$1" store="$2" plan="$3" cx="$4"
  printf '\n'
  printf 'EXPERIMENT E9 (ga-798p6w) — extra, MEASURED instructions for this story. They never change your REFINE-vs-ESCALATE\n'
  printf 'decision: a story you could refine without them is still refined with them, and a story you would escalate is still\n'
  printf 'escalated. Do the two things below with READ-ONLY tools only (ls, grep, Read): do not run the project'"'"'s code, do not\n'
  printf 'call any external API, do not edit any file, and do not send mail/nudges or comment on beads other than this story.\n'
  if [ "$cx" = 1 ]; then
    printf '\nCOMPLEXITY FACTS — write them in a separate call BEFORE the REFINE write-back below:\n'
    printf '  bd -C "%s" update "%s" --set-metadata "story.complexidade_fatos=arquivos=<N> superficies=<N> externo=<0|1> migracao=<0|1>"\n' "$store" "$bead"
    printf '  arquivos    = how many source files the build will change (read the code the story touches; >=1)\n'
    printf '  superficies = how many independent runtime surfaces it touches: routes/endpoints + daemons/launchd jobs + scheduled\n'
    printf '                jobs (a shared library counts once, however many callers it has; >=1)\n'
    printf '  externo     = 1 if the build sends anything OUTSIDE the system (a message to a lead/client, any spend, a write to a\n'
    printf '                third party such as Pipedrive/whapi/Google), else 0\n'
    printf '  migracao    = 1 if it needs a schema/data migration or a backfill, else 0\n'
    printf 'Write FACTS, never a level: the level (S/M/L) is computed from them by code after you finish. If you cannot establish\n'
    printf 'one of them from the code, do NOT guess — write exactly "story.complexidade_fatos=desconhecido: <why you could not tell>".\n'
  fi
  if [ "$plan" = 1 ]; then
    printf '\nTECHNICAL PLAN — the builder starts from this instead of exploring. Write it, also BEFORE the REFINE write-back:\n'
    printf '  bd -C "%s" update "%s" --set-metadata "story.plano_tecnico=<the plan, plain text, at most 40 lines>"\n' "$store" "$bead"
    printf 'Use exactly these five section headings, each on its own line, in this order:\n'
    printf '  ARQUIVOS:           one line per file to change — path, and what changes (name the functions when you can)\n'
    printf '  ABORDAGEM:          3-6 lines: the change, in the order it should be made\n'
    printf '  CASOS-LIMITE:       every input/state the change must handle — INCLUDING the third state: a read that can fail or\n'
    printf '                      come back empty must not look the same as one that succeeded — and what the code does in each\n'
    printf '  TESTE QUE REPROVA:  the first test to write, what it asserts, and why it FAILS on the current code\n'
    printf '  NAO VERIFIQUEI:     what you could not confirm in the code; write "nada" only if that is true\n'
    printf 'Every path and function you name must exist: check with ls/grep before you write it. A plan that names a file or\n'
    printf 'function that is not there is worse than no plan. This section is engineering, not product: the product fields\n'
    printf '(F1/F2/F6) keep their product language; the plan lives only in story.plano_tecnico.\n'
  fi
  printf '\n'
}

e9_cmd_block() {
  local bead="${1:-}" store="${2:-}" arm plan=0 cx=0 g=0
  [ -n "$bead" ] || return 2
  e9_conf_load
  e9_state_gate || g=$?
  case "$g" in 0) ;; 1) return 0 ;; *) return "$g" ;; esac
  arm="$(e9_cmd_assign "$bead" "$store")" || return 0   # cannot assign → no block at all: no arm is not "off", and not "on"
  [ "$arm" = on ] && plan=1
  [ "$E9_COMPLEXITY" = on ] && cx=1
  [ "$plan" = 1 ] || [ "$cx" = 1 ] || return 0
  e9_block_text "$bead" "$store" "$plan" "$cx"
}

# `finalize` cannot see the arm (it only gets the bead JSON), so the dispatcher asks for the plan check separately.
e9_cmd_plancheck() { local json; json="$(cat)"; e9_bead_load "$json" || { echo unreadable; return 0; }; e9_plan_status; }

e9_main() {
  local cmd="${1:-}"; [ $# -gt 0 ] && shift
  case "$cmd" in
    state)      e9_cmd_state ;;
    arm)        e9_cmd_arm "$@" ;;
    arms)       e9_cmd_arms "$@" ;;
    assign)     e9_cmd_assign "$@" ;;
    peek)       e9_cmd_peek "$@" ;;
    block)      e9_cmd_block "$@" ;;
    complexity) e9_complexity "$@" || { echo "e9: bad complexity arguments: $*" >&2; return 2; } ;;
    finalize)   e9_cmd_finalize ;;
    check)      e9_cmd_check ;;
    plancheck)  e9_cmd_plancheck ;;
    *) echo "usage: e9-arms.sh state | arm planner <id> | arms planner (ids on stdin) | assign <id> [store] | peek <id> | block <id> <store> | complexity <f> <s> <ext> <mig> | finalize | check | plancheck" >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  e9_main "$@"
  exit $?
fi
