#!/bin/bash
# dolt-restore-lab.sh (ga-ap2dd6) — restore drill for ONE Dolt backup, on ANY host.
#
# WHY: the hq backup (12.9 GB) has never had a real restore: dolt-restore-verify.sh can only
# prove the S3 manifest closes for it ("NAO e um restore"), because a restore needs ~19 GB the
# mini does not have. This script is the drill itself, host-agnostic: it fetches (S3) or opens
# (file://) a Dolt backup, RESTORES it, compares row counts against a MANIFEST, times every
# step against the RTO, and optionally measures flatten + gc on the restored copy.
#
# WHERE IT RUNS: the MBP, by the Athos's decision of 15/10 (ga-ap2dd6): no Dolt data goes to the
# Hetzner server. This file does not know the host. NOT HERE (see docs/runbooks/dolt-restore-lab.md,
# "O que falta"): the mbp-run.sh wiring, the S3 read credential, the schedule, the alert, the
# producer of the manifest. This file only touches the directory it is given.
#
#   dolt-restore-lab.sh run --db NAME --source SRC --manifest FILE --workdir DIR [options]
#     --source SRC       file:///abs/dir (a Dolt backup dir, has a `manifest` file)  or
#                        s3://bucket/prefix (fetched with `aws s3 sync` into the scratch dir)
#     --manifest FILE    JSON {"schema":1,"db":"NAME","tables":{"issues":123,...}} — row counts
#                        taken on the source side when the backup was made. COUNTS ONLY: it is
#                        safe to ship to any host. Restored count >= expected passes (rows
#                        created between the count and the snapshot only add); fewer fails.
#     --workdir DIR      absolute path; the script creates DIR/run-XXXXXX and removes only that
#     --rto-seconds N    fetch+restore+count budget (default 1800); over it = SLOW, rc 3
#     --report FILE      JSON report (counts, sizes, timings; never row contents)
#     --flatten          after the restore is verified, run the `bd flatten` recipe + dolt gc on
#                        the COPY and report commits/size before and after
#     --gc-args "ARGS"   extra args for `dolt gc` (default none, same as bd flatten's step 6)
#     --keep             keep the scratch dir (default: delete it, restored data included)
#
# EXIT CODES — three states, not two ("could not check" is not "checked and fine"):
#   0 OK       restore worked, every manifest table >= expected, within the RTO
#   1 FAIL     checked and broken: no manifest in the backup, dolt REFUSED the restore (its own
#              status 1), a table is missing/unreadable (dolt refused the query) or below the manifest
#   2 UNKNOWN  could not check: bad/empty/other-db/unknown-schema manifest, no dolt/python3/timeout,
#              fetch failed, disk too small, another run in progress, a restore or a count that did
#              not FINISH (timeout, killed by a signal, any status but dolt's own 1), a relative
#              file:// source, a source (or fetched copy) the lab cannot fully read, a bad LAB_*
#              setting, a script abort or a signal mid-run
#   3 SLOW     everything passed but fetch+restore+count took longer than the RTO
# The rule: only a CONCLUSIVE observation about the backup contents is rc 1 or rc 0; anything that
# stops the lab from reaching a conclusion is rc 2 with a reason. The exit code is the RESTORE verdict
# only. The flatten result is in the report and on the RESULT line (flatten=OK|FAIL|SKIPPED|UNKNOWN):
# it is research, it must not page anyone as a backup failure.
#
# CLEANUP: the restored copy is real data, deleted at the end. Whether that worked is on the RESULT line and in
# the report (cleanup=ok|falhou|mantido|nao-havia; run_dir=<path> when the data is still there) and, for a
# failed removal, in an AVISO log line. It never changes the exit code: whoever reads RESULT must look at it.
#
# TIMEOUT: every dolt/aws step runs under GNU `timeout` (LAB_TIMEOUT_BIN, else `timeout`, else
# `gtimeout` — macOS has only the latter, from Homebrew coreutils, and a launchd/ssh PATH may lack
# /opt/homebrew/bin). With none, the lab REFUSES (rc 2): it never silently runs without a limit. The limit is
# SOFT: `timeout` sends TERM and no more, so a dolt that ignores TERM (or sits in uninterruptible I/O) is not
# stopped by it.
#
# DISK: needs LAB_DISK_MARGIN_PCT (default 400) of the backup size free — the fetched copy, the
# restored copy and gc headroom (dolt gc wants 2-2.8x the database). Unreadable = UNKNOWN.
#
# TEST: bash scripts/dolt-restore-lab.selftest.sh   (real dolt on a tiny fixture, fake aws)
# Library mode: DOLT_RESTORE_LAB_LIB=1 source dolt-restore-lab.sh   (then arm_traps for the safety net)
set -uo pipefail

LAB_DOLT="${LAB_DOLT:-dolt}"
LAB_AWS="${LAB_AWS:-aws}"
LAB_PY="${LAB_PY:-python3}"
LAB_TIMEOUT_BIN="${LAB_TIMEOUT_BIN:-}"        # empty = try `timeout`, then `gtimeout`
LAB_FETCH_TIMEOUT="${LAB_FETCH_TIMEOUT:-14400}"
LAB_RESTORE_TIMEOUT="${LAB_RESTORE_TIMEOUT:-7200}"
LAB_FLATTEN_TIMEOUT="${LAB_FLATTEN_TIMEOUT:-7200}"
LAB_SQL_TIMEOUT="${LAB_SQL_TIMEOUT:-600}"
LAB_DISK_MARGIN_PCT="${LAB_DISK_MARGIN_PCT:-400}"
LAB_LOG="${LAB_LOG:-}"

# Every global the traps and finish() read is set HERE, so an abort at any point still has a defined state.
RC=0; REASON=""; RUN=""; LOCK=""; LOCK_OWNED=0; KEEP=0; FINISHED=0; TIMEOUT_CMD=""; KIDS=""
T_FETCH=""; T_RESTORE=""; T_COUNT=""; T_TOTAL=""; RESTORE_KB=""; SRC_KIND=""; SRC_KB=""
F_RESULT="SKIPPED"; F_WHY="nao-pedido"; F_COMMITS_BEFORE=""; F_COMMITS_AFTER=""
F_KB_BEFORE=""; F_KB_AFTER=""; F_FLATTEN_S=""; F_GC_S=""
TABLES_TSV=""; TABLES_TXT=""; STARTED=""; MANIFEST_OK=1; SRC_BAD=""; CLEANUP="nao-havia"; DOLT_VERSION=""
DB=""; SOURCE=""; MANIFEST=""; WORKDIR=""; RTO=1800; REPORT=""; FLATTEN=0; GC_ARGS=""
REPORT_STATE="nao-pedido"; START_EPOCH=$(date +%s)

log() {
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') [restore-lab] $*"
  printf '%s\n' "$line" >&2
  [ -n "$LAB_LOG" ] && printf '%s\n' "$line" >> "$LAB_LOG" 2>/dev/null
  return 0
}

_now() { date +%s; }
_rank() { case "$1" in 1) echo 4 ;; 2) echo 3 ;; 3) echo 2 ;; *) echo 1 ;; esac; }
_verdict_name() { case "$1" in 0) echo OK ;; 1) echo FAIL ;; 2) echo UNKNOWN ;; 3) echo SLOW ;; *) echo UNKNOWN ;; esac; }

# note_rc <rc> <reason> — keep the worst verdict (FAIL > UNKNOWN > SLOW > OK) and its first reason.
note_rc() {
  if [ "$(_rank "$1")" -gt "$(_rank "$RC")" ]; then RC="$1"; REASON="$2"; fi
  log "$(_verdict_name "$1"): $2"
}

# _resolve_timeout — pick the timeout binary ONCE and prove it works. An explicit LAB_TIMEOUT_BIN is the only
# candidate; otherwise `timeout`, then `gtimeout`. Nothing usable = failure (the caller refuses with rc 2).
# The probe runs the exact form _run_to uses, so a binary that is not GNU-style (or is a stub) is caught here
# instead of surfacing later as a "restore failed".
_resolve_timeout() {
  local c
  TIMEOUT_CMD=""
  if [ -n "$LAB_TIMEOUT_BIN" ]; then set -- "$LAB_TIMEOUT_BIN"; else set -- timeout gtimeout; fi
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || continue
    # the probed command is the running bash by absolute path: the probe tests the timeout binary, not whether
    # `true` happens to be on this PATH
    if "$c" 5 "${BASH:-bash}" -c : >/dev/null 2>&1; then TIMEOUT_CMD="$c"; return 0; fi
  done
  return 1
}

# _run_to <seconds> cmd... — the command's own status; 124 = timed out. Never runs without a limit: with no
# resolved timeout binary it returns 125 (and the callers read anything but 0/1 as "did not finish").
_run_to() {
  local secs="$1"; shift
  [ -n "$TIMEOUT_CMD" ] || return 125
  "$TIMEOUT_CMD" "$secs" "$@"
}

# _st_words <status> — a status in words, for reasons
_st_words() {
  case "$1" in
    124) echo "estourou o tempo (status 124)" ;;
    125|126|127) echo "nao conseguiu rodar (status $1)" ;;
    *) if [ "$1" -gt 128 ] 2>/dev/null; then echo "morto por sinal $(( $1 - 128 )) (status $1)"; else echo "status $1"; fi ;;
  esac
}

# _posint <VARNAME> <maxdigits> <allow-zero 0|1> — VARNAME must hold digits only (no sign, no "08" octal surprise, no
# wraparound: <= maxdigits), and >0 unless zero is allowed (a 0 timeout would switch the limit OFF). On success the
# variable is rewritten in plain decimal.
_posint() {
  local v="${!1}"
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#v}" -le "$2" ] || return 1
  v=$(( 10#$v ))
  if [ "$3" -eq 0 ] && [ "$v" -eq 0 ]; then return 1; fi
  printf -v "$1" '%s' "$v"
}

# _sql_scalar <dbdir> <query> — prints ONE non-empty line. Status: 0 ok; 1 dolt REFUSED the query (its own
# status 1: e.g. the table does not exist — a conclusive answer); 2 did not finish or cannot be read (timeout,
# signal, any other status, dir missing, empty answer) — NOT a conclusion about the data.
_sql_scalar() {
  local out st
  [ -d "$1" ] || return 2
  out=$(cd "$1" || exit 126; _run_to "$LAB_SQL_TIMEOUT" "$LAB_DOLT" sql -q "$2" -r csv 2>/dev/null); st=$?
  case "$st" in 0) ;; 1) return 1 ;; *) return 2 ;; esac
  out=$(printf '%s\n' "$out" | tail -n +2 | head -1)
  [ -n "$out" ] || return 2
  printf '%s\n' "$out"
}

# _sql_int <dbdir> <query> — a non-negative integer (same 0/1/2 statuses); text where a number belongs is "2".
_sql_int() {
  local v st
  v=$(_sql_scalar "$1" "$2"); st=$?
  [ "$st" -eq 0 ] || return "$st"
  case "$v" in ''|*[!0-9]*) return 2 ;; esac
  printf '%s\n' "$v"
}

_count() { _sql_int "$1" "SELECT COUNT(*) FROM \`$2\`"; }  # table name was validated by the manifest parser

# _du_kb <dir> — prints the size in KB. Status 0 only when du itself finished clean: a du that hit "Permission denied"
# on part of the tree still prints a number, and that number is the size of what it could read, not the size.
# vazio/ilegivel → status 1 and nothing printed (callers read "" as "not measured"); falhou (du != 0) → status 1.
_du_kb() {
  local out
  out=$(du -sk "$1" 2>/dev/null) || return 1
  out=$(printf '%s\n' "$out" | awk 'NR==1{print $1}')
  case "$out" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$out"
}

# _src_readable <dir> — 0 when everything under <dir> can be read: every directory listed AND entered, every file opened.
# 1 otherwise, with the first offender in SRC_BAD. Whoever says "no manifest here" or "dolt refused this backup" must
# first know the lab could LOOK: a directory it cannot enter makes `[ -f manifest ]` false and a file it cannot open
# makes dolt exit 1, and both used to read as "backup broken". Not readable → the caller says rc 2 (not a verdict).
# vazio (listagem sem nenhuma linha) → 1; falhou (find saiu != 0, ex.: Permission denied) → 1.
_src_readable() {
  local f list="$RUN/src.list"
  SRC_BAD=""
  if ! find "$1" > "$list" 2>/dev/null; then SRC_BAD="$1 (o find nao conseguiu listar tudo)"; return 1; fi
  [ -s "$list" ] || { SRC_BAD="$1 (listagem vazia)"; return 1; }
  while IFS= read -r f; do
    if [ -d "$f" ]; then { [ -r "$f" ] && [ -x "$f" ]; } || { SRC_BAD="$f"; return 1; }
    else [ -r "$f" ] || { SRC_BAD="$f"; return 1; }
    fi
  done < "$list"
  return 0
}

# _need_readable <dir> <what> — rc 2 and out when <dir> is not fully readable
_need_readable() {
  _src_readable "$1" || { note_rc 2 "$2 ilegivel: $SRC_BAD (o laboratorio nao consegue le-la; nao e veredito sobre o backup)"; finish; }
}

_write_report() {  # key=value pairs; flatten.* nests; numbers become ints; tables from $TABLES_TXT. Returns python's status.
  [ -n "${REPORT:-}" ] || return 0
  local wst
  LAB_TABLES_TXT="${TABLES_TXT:-}" "$LAB_PY" -I - "$REPORT" "$@" <<'PY'
import json, os, re, sys
path = sys.argv[1]
d = {}
for a in sys.argv[2:]:
    k, _, v = a.partition("=")
    text = k.split(".")[-1] in ("db", "host", "reason", "why", "gc_args")
    if not text and v == "":
        v = None                      # not measured (e.g. fetch_s for a file:// source), never ""
    elif not text and re.fullmatch(r"-?\d+", v):
        v = int(v)
    if k.startswith("flatten."):
        d.setdefault("flatten", {})[k[8:]] = v
    else:
        d[k] = v
t = {}
for line in os.environ.get("LAB_TABLES_TXT", "").splitlines():
    if not line:
        continue
    n, e, r = (line.split("\t") + ["", ""])[:3]
    t[n] = {"expected": int(e), "restored": int(r) if r != "" else None}
d["tables"] = t
tmp = path + ".tmp.%d" % os.getpid()
with open(tmp, "w") as f:
    json.dump(d, f, indent=2, sort_keys=True); f.write("\n")
os.replace(tmp, path)
PY
  wst=$?
  [ "$wst" -eq 0 ] || log "AVISO: nao consegui gravar o relatorio $REPORT"
  return "$wst"
}

# _collect <pid> — appends every descendant of <pid> to KIDS (the whole tree is read BEFORE anything is killed:
# once the middle process dies its children are re-parented and can no longer be found from here)
_collect() {
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do KIDS="$KIDS $c"; _collect "$c"; done
}

_alive() {  # a zombie is not alive: it only waits for its parent to reap it
  local s; s=$(ps -p "$1" -o stat= 2>/dev/null)
  case "$s" in ""|Z*) return 1 ;; esac
  return 0
}

# _stop_children — an abort or a signal can leave the timeout/dolt processes running and writing into $RUN.
# They are grandchildren (lab -> subshell -> timeout -> dolt), so killing only the direct children would orphan
# the dolt. TERM first, then KILL for whatever is still there after ~2.5 s.
_stop_children() {
  local p n=0 alive
  command -v pgrep >/dev/null 2>&1 || return 0
  KIDS=""; _collect "$$"
  [ -n "$KIDS" ] || return 0
  kill -TERM $KIDS >/dev/null 2>&1
  while [ "$n" -lt 5 ]; do
    alive=0; for p in $KIDS; do _alive "$p" && alive=1; done
    [ "$alive" -eq 0 ] && return 0
    sleep 0.5; n=$((n+1))
  done
  kill -KILL $KIDS >/dev/null 2>&1
  return 0
}

# cleanup — delete the scratch dir ($RUN, restored data included) and release the lock. Sets CLEANUP, which the RESULT
# line and the report carry: nao-havia (no scratch dir was ever created) | ok (removed) | mantido (--keep) | falhou
# (still there after the retries: the restored copy is STILL ON THIS HOST). The exit code is the restore verdict, so
# this field and the AVISO log line are the only places that say the data stayed — a failed removal is never silent.
cleanup() {
  local i=0 gone=0 err=""
  CLEANUP="nao-havia"
  if [ -n "$RUN" ] && [ "$KEEP" -eq 1 ]; then
    CLEANUP="mantido"; log "mantido por --keep: $RUN (os dados restaurados ficam la; apague a mao quando acabar)"
  elif [ -n "$RUN" ]; then
    case "$RUN" in
      "$WORKDIR"/run-*)
        # a child that was just told to stop may still be writing: retry a few times instead of leaving gigabytes behind.
        # "Gone" needs rm's own status AND the path absent: `[ ! -e ]` alone is also true when the path cannot be looked at.
        while [ "$i" -lt 5 ]; do
          if err=$(rm -rf "$RUN" 2>&1) && [ ! -e "$RUN" ]; then gone=1; break; fi
          i=$((i+1)); [ "$i" -lt 5 ] && sleep 1
        done
        if [ "$gone" -eq 1 ]; then CLEANUP="ok"
        else
          CLEANUP="falhou"; err=$(printf '%s\n' "$err" | head -1)
          log "AVISO: nao consegui apagar $RUN (${err:-o rm nao disse nada e o caminho continua la}); os dados restaurados continuam neste host, apague a mao"
        fi ;;
      *) CLEANUP="falhou"; log "AVISO: recusei apagar $RUN (fora de $WORKDIR/run-*); os dados restaurados continuam neste host, apague a mao" ;;
    esac
  fi
  if [ "$LOCK_OWNED" -eq 1 ] && [ -n "$LOCK" ]; then rm -rf "$LOCK"; LOCK_OWNED=0; fi
  return 0
}

# _emit_result — write the report, print the RESULT line. Used by _wrap_up only, AFTER cleanup (so both can say whether
# the restored copy is still on this host).
_emit_result() {
  local vname leftover=""
  vname=$(_verdict_name "$RC")
  case "$CLEANUP" in falhou|mantido) leftover="$RUN" ;; esac
  REPORT_STATE="${REPORT:-none}"
  if [ -n "$REPORT" ] && ! _write_report schema=1 db="$DB" verdict="$vname" rc="$RC" reason="$REASON" host="$(hostname -s 2>/dev/null)" \
    started_at="$STARTED" finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" dolt_version="$DOLT_VERSION" \
    source_kind="$SRC_KIND" source_kb="$SRC_KB" rto_seconds="$RTO" fetch_s="$T_FETCH" restore_s="$T_RESTORE" \
    count_s="$T_COUNT" total_s="$T_TOTAL" restored_kb="$RESTORE_KB" timeout_bin="$TIMEOUT_CMD" \
    flatten.result="$F_RESULT" flatten.why="$F_WHY" flatten.commits_before="$F_COMMITS_BEFORE" \
    flatten.commits_after="$F_COMMITS_AFTER" flatten.kb_before="$F_KB_BEFORE" flatten.kb_after_gc="$F_KB_AFTER" \
    flatten.flatten_s="$F_FLATTEN_S" flatten.gc_s="$F_GC_S" flatten.gc_args="$GC_ARGS" cleanup="$CLEANUP" run_dir="$leftover"; then
    REPORT_STATE="falhou"      # asked for, not written: the caller must not go looking for (or trust) a file
  fi
  printf 'RESULT: %s db=%s rc=%s total_s=%s flatten=%s cleanup=%s report=%s\n' "$vname" "$DB" "$RC" "$T_TOTAL" "$F_RESULT" "$CLEANUP" "$REPORT_STATE"
}

# _wrap_up — the end of every run, in this order: stop the clock (total_s runs up to the end of the flatten and leaves the
# removal of the restored copy out, so a slow rm cannot read as a slow run), delete the scratch dir, THEN write the
# report and the RESULT line.
# FINISHED is set only after the cleanup, right before emitting: a signal that lands during the removal reaches
# on_exit with FINISHED=0 and still ends as UNKNOWN with a RESULT line (never silence), and the retry there finishes
# the removal; setting it before emitting keeps the EXIT trap from reporting twice (nor looping) if emitting trips.
_wrap_up() {
  local t
  T_TOTAL=$(( $(_now) - START_EPOCH ))
  # The counts live in $RUN, which cleanup is about to delete and the report is written after it: take them now.
  # vazio (no file: the run ended before any count) → TABLES_TXT stays as it was ("" → "tables": {} in the report).
  # falhou (the file is there but cat cannot read it) → the same: a failed read never replaces what an earlier pass took —
  # on_exit runs this again when a signal lands DURING cleanup, by which time the file may already be gone.
  if [ -n "$TABLES_TSV" ] && [ -f "$TABLES_TSV" ] && t=$(cat "$TABLES_TSV" 2>/dev/null); then TABLES_TXT="$t"; fi
  cleanup
  FINISHED=1
  _emit_result
}

# finish — the normal exit: cleanup + report + RESULT line + exit code.
finish() {
  _wrap_up
  exit "$RC"
}

# on_exit — the EXIT trap, armed by arm_traps. Reached with FINISHED=0 means the script stopped by itself
# (a `set -u` abort, an arithmetic error, a bug) or was killed by SIGTERM/SIGHUP: that is UNKNOWN (rc 2) with
# a RESULT line and a report, never the bare rc 1 of a bash abort and never silence. (A signal death keeps its
# 128+N status for the caller — bash does not let an EXIT trap change it — but RESULT and the report say UNKNOWN.)
on_exit() {
  local st=$?
  if [ "$FINISHED" -eq 0 ]; then
    note_rc 2 "rodada abortada antes de concluir (erro do script ou sinal; status $st)"
    _stop_children
    _wrap_up
  fi
  exit "$RC"
}

arm_traps() { trap on_exit EXIT; }

_parse_manifest() {  # prints "table<TAB>count" lines; non-zero with a reason on stderr if unusable
  "$LAB_PY" -I - "$1" "$2" <<'PY'
import json, re, sys
try:
    m = json.load(open(sys.argv[1]))
except Exception as e:
    sys.exit("manifest ilegivel: %s" % type(e).__name__)
if not isinstance(m, dict):
    sys.exit("manifest nao e um objeto JSON")
# `schema` and `db` are REQUIRED and strictly typed: a manifest that does not say which database it counts, or in
# which format, cannot be trusted to check this one (an absent key used to pass; `true` and 1.0 are not the int 1).
if type(m.get("schema")) is not int or m["schema"] != 1:
    sys.exit("manifest sem schema 1 conhecido (veio %r)" % (m.get("schema"),))
if type(m.get("db")) is not str or m["db"] != sys.argv[2]:
    sys.exit("manifest e de outro banco ou nao diz de qual: %r" % (m.get("db"),))
if not isinstance(m.get("tables"), dict) or not m["tables"]:
    sys.exit("manifest sem tabelas (vazio nao verifica nada)")
for k, v in m["tables"].items():
    if not re.fullmatch(r"[A-Za-z0-9_]+", k):
        sys.exit("nome de tabela invalido no manifest")
    if type(v) is not int or v < 0 or v > 10**15:
        sys.exit("contagem invalida no manifest para %s" % k)
    print("%s\t%d" % (k, v))
PY
}

# _take_lock — mkdir lock with the owner's pid inside. Two ways to get this wrong, both fixed: (1) the owner writes
# its pid a moment AFTER the mkdir, so an empty pid is "being written", not "stale" — wait ~3s before calling it
# abandoned; (2) `kill -0` fails with EPERM on a live pid of another user and would read as "dead" — `ps -p` does not.
_take_lock() {
  LOCK="$WORKDIR/.lab.lock"
  local other="" tries=0
  if mkdir "$LOCK" 2>/dev/null; then printf '%s\n' "$$" > "$LOCK/pid"; LOCK_OWNED=1; return 0; fi
  while [ -d "$LOCK" ]; do
    other=$(cat "$LOCK/pid" 2>/dev/null)
    [ -n "$other" ] && break
    tries=$((tries+1)); [ "$tries" -ge 4 ] && break
    sleep 1
  done
  if [ -n "$other" ] && ps -p "$other" >/dev/null 2>&1; then LOCK=""; return 1; fi
  rm -rf "$LOCK"
  if mkdir "$LOCK" 2>/dev/null; then printf '%s\n' "$$" > "$LOCK/pid"; LOCK_OWNED=1; return 0; fi
  LOCK=""; return 1
}

# _fstep <dbdir> <name> <dolt args...> — one flatten step on the copy. 0 = done. Otherwise F_RESULT/F_WHY are set
# and 1 is returned: dolt's own refusal (status 1) is FAIL; a timeout, a signal or any other status is UNKNOWN —
# "did not finish" is not "broke" (same rule as the restore).
_fstep() {
  local d="$1" name="$2" st; shift 2
  ( cd "$d" || exit 126; _run_to "$LAB_FLATTEN_TIMEOUT" "$LAB_DOLT" "$@" >/dev/null 2>&1 ); st=$?
  [ "$st" -eq 0 ] && return 0
  if [ "$st" -eq 1 ]; then F_RESULT=FAIL; F_WHY="passo-do-flatten-falhou:$name"
  else F_RESULT=UNKNOWN; F_WHY="passo-do-flatten-nao-terminou:$name($(_st_words "$st"))"; fi
  return 1
}

# _fsql_fail <status> <what> — F_RESULT/F_WHY for a count that did not give a number after the flatten
_fsql_fail() {
  if [ "$1" -eq 1 ]; then F_RESULT=FAIL; F_WHY="$2-recusado-depois-do-flatten"
  else F_RESULT=UNKNOWN; F_WHY="$2-nao-terminou-depois-do-flatten"; fi
}

# _flatten <dbdir> <counts-tsv> — the `bd flatten` recipe (Tim Sehn) with plain dolt on the COPY:
# new branch, soft-reset to the root commit, one snapshot commit, swap the branch, dolt gc.
# EVERY step is checked: an unchecked `reset` once left a no-op "flatten" that looked fine.
_flatten() {
  local d="$1" tsv="$2" roots nroots root br t e r n st s0 s1 s2
  F_RESULT=UNKNOWN; F_WHY="flatten-interrompido-antes-de-concluir"   # what a signal in the middle of it leaves in the report
  F_COMMITS_BEFORE=$(_sql_int "$d" "SELECT COUNT(*) FROM dolt_log") || { F_WHY="sem-contagem-de-commits"; return 0; }
  # vazio/falhou → "" = tamanho nao medido (null no relatorio, "?" no motivo); informativo, nao muda o veredito do flatten
  F_KB_BEFORE=$(_du_kb "$d/.dolt")
  if [ "$F_COMMITS_BEFORE" -le 2 ]; then F_RESULT=SKIPPED; F_WHY="nada-a-achatar(commits=$F_COMMITS_BEFORE)"; return 0; fi
  roots=$(cd "$d" && _run_to "$LAB_SQL_TIMEOUT" "$LAB_DOLT" sql -q "SELECT commit_hash FROM dolt_commit_ancestors WHERE parent_hash IS NULL" -r csv 2>/dev/null | tail -n +2)
  nroots=$(printf '%s\n' "$roots" | grep -c .)
  if [ "$nroots" -ne 1 ]; then F_WHY="raiz-nao-encontrada-ou-ambigua($nroots)"; return 0; fi
  root="$roots"
  br=$(_sql_scalar "$d" "SELECT active_branch()") || { F_WHY="sem-branch-ativo"; return 0; }
  s0=$(_now)
  if ! { _fstep "$d" checkout-b checkout -b lab_flat \
      && _fstep "$d" reset reset --soft "$root" \
      && _fstep "$d" add add -A \
      && _fstep "$d" commit commit -m "flatten (restore-lab)" \
      && _fstep "$d" branch-f branch -f "$br" lab_flat \
      && _fstep "$d" checkout checkout "$br" \
      && _fstep "$d" branch-D branch -D lab_flat; }; then
    F_FLATTEN_S=$(( $(_now) - s0 )); return 0
  fi
  s1=$(_now); F_FLATTEN_S=$(( s1 - s0 ))
  # shellcheck disable=SC2086
  if ! _fstep "$d" gc gc $GC_ARGS; then F_GC_S=$(( $(_now) - s1 )); return 0; fi
  s2=$(_now); F_GC_S=$(( s2 - s1 ))
  F_KB_AFTER=$(_du_kb "$d/.dolt")   # vazio/falhou → "" (nao medido), como acima
  F_COMMITS_AFTER=$(_sql_int "$d" "SELECT COUNT(*) FROM dolt_log"); st=$?
  if [ "$st" -ne 0 ]; then F_COMMITS_AFTER=""; _fsql_fail "$st" "contagem-de-commits"; return 0; fi
  if [ "$F_COMMITS_AFTER" -ge "$F_COMMITS_BEFORE" ]; then F_RESULT=FAIL; F_WHY="historia-nao-encolheu($F_COMMITS_BEFORE->$F_COMMITS_AFTER)"; return 0; fi
  while IFS="$(printf '\t')" read -r t e r; do
    [ -n "$t" ] || continue
    n=$(_count "$d" "$t"); st=$?
    if [ "$st" -ne 0 ]; then _fsql_fail "$st" "tabela:$t"; return 0; fi
    if [ "$n" != "$r" ]; then F_RESULT=FAIL; F_WHY="contagem-mudou-no-flatten:$t($r->$n)"; return 0; fi
  done < "$tsv"
  F_RESULT=OK; F_WHY="commits $F_COMMITS_BEFORE->$F_COMMITS_AFTER, ${F_KB_BEFORE:-?}KB->${F_KB_AFTER:-?}KB"
}

run_lab() {
  local srcdir fetchdir restored_dir t e n st s0 s1 avail need v ls_out phys ncount=0
  # After a command the dolt CLI starts a detached `dolt send-metrics`. Under host load it runs late — after cleanup
  # has removed $RUN — and recreates $RUN/dolt-home/.dolt, so the workdir keeps a stray run-* directory (an intermittent
  # leftover at load 60-100; measured: 12 of 12 dolt-homes came back with it on, 0 of 12 with it off). It also sends
  # telemetry from the lab host. Off for every dolt this script runs, the `dolt version` of the report included.
  export DOLT_DISABLE_EVENT_FLUSH=1
  STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ); START_EPOCH=$(_now)
  # A report left by an earlier run must never be mistaken for this one's (best effort: if it cannot be removed it
  # cannot be overwritten either, and the RESULT line then says report=falhou).
  [ -n "$REPORT" ] && rm -f "$REPORT" 2>/dev/null
  case "$DB" in ''|*[!A-Za-z0-9_]*) note_rc 2 "--db invalido"; finish ;; esac
  case "$WORKDIR" in /?*) ;; *) note_rc 2 "--workdir precisa ser caminho absoluto"; finish ;; esac
  case "$WORKDIR" in /|"${HOME:-/nonexistent}"|"${HOME:-/nonexistent}"/) note_rc 2 "--workdir recusado: $WORKDIR"; finish ;; esac
  if [ -e "$WORKDIR/.dolt" ] || [ -e "$WORKDIR/.beads" ]; then note_rc 2 "--workdir parece um banco vivo (.dolt/.beads)"; finish; fi
  command -v "$LAB_PY" >/dev/null 2>&1 || { note_rc 2 "python3 ausente"; finish; }
  command -v "$LAB_DOLT" >/dev/null 2>&1 || { note_rc 2 "dolt ausente"; finish; }
  _posint RTO 9 1 || { note_rc 2 "--rto-seconds invalido (inteiro >= 0, ate 9 digitos)"; finish; }
  # The LAB_* settings feed shell arithmetic and `timeout`: validate them as digits BEFORE they are used. An
  # unvalidated "abc" is an unbound variable under `set -u`; "08" is octal; 20 digits wrap around 64 bits; and a
  # timeout of 0 means "no limit" to GNU timeout — none of those may reach a command.
  for v in LAB_FETCH_TIMEOUT LAB_RESTORE_TIMEOUT LAB_FLATTEN_TIMEOUT LAB_SQL_TIMEOUT; do
    _posint "$v" 9 0 || { note_rc 2 "$v invalido (segundos, inteiro > 0, ate 9 digitos; 0 desligaria o limite)"; finish; }
  done
  _posint LAB_DISK_MARGIN_PCT 6 0 || { note_rc 2 "LAB_DISK_MARGIN_PCT invalido (percentual inteiro > 0, ate 6 digitos)"; finish; }
  _resolve_timeout || { note_rc 2 "timeout ausente ou nao funciona (LAB_TIMEOUT_BIN='${LAB_TIMEOUT_BIN:-}'; procurei timeout e gtimeout no PATH). macOS: brew install coreutils (gtimeout) e ponha /opt/homebrew/bin no PATH; o laboratorio nao roda sem limite de tempo"; finish; }
  TABLES_TSV=""
  mkdir -p "$WORKDIR" 2>/dev/null || { note_rc 2 "nao consegui criar $WORKDIR"; finish; }
  _take_lock || { note_rc 2 "outra rodada em curso em $WORKDIR"; finish; }
  RUN=$(mktemp -d "$WORKDIR/run-XXXXXX") || { note_rc 2 "mktemp falhou em $WORKDIR"; finish; }
  TABLES_TSV="$RUN/tables.tsv"
  # Own dolt home inside the scratch dir: `dolt commit` (flatten) needs an identity a fresh host does
  # not have, and this way the host user's ~/.dolt is never read or written. Removed with $RUN.
  export DOLT_ROOT_PATH="$RUN/dolt-home"
  if ! { mkdir -p "$DOLT_ROOT_PATH" \
      && _run_to "$LAB_SQL_TIMEOUT" "$LAB_DOLT" config --global --add user.name restore-lab >/dev/null 2>&1 \
      && _run_to "$LAB_SQL_TIMEOUT" "$LAB_DOLT" config --global --add user.email restore-lab@localhost >/dev/null 2>&1; }; then
    note_rc 2 "nao consegui preparar o DOLT_ROOT_PATH do laboratorio (identidade do dolt)"; finish
  fi
  # The version for the report is read HERE — with the lab's own dolt home and under the timeout — and never in
  # _emit_result: a refusal before this point has no home of its own, and `dolt version` run with the host's would
  # create ~/.dolt there (and its version check can reach the network, which a hung connection would turn into a hung
  # exit path). vazio/falhou/estourou o tempo → "" = relatorio dolt_version null (nao medido); nunca muda o veredito.
  DOLT_VERSION=$(_run_to 60 "$LAB_DOLT" version 2>/dev/null | head -1)
  # The manifest first: if it is unusable we still drill (the timing is worth having) but the verdict is UNKNOWN.
  MANIFEST_OK=1
  if ! _parse_manifest "$MANIFEST" "$DB" > "$RUN/expected.tsv" 2> "$RUN/manifest.err"; then
    MANIFEST_OK=0; note_rc 2 "$(head -1 "$RUN/manifest.err")"
  fi
  case "$SOURCE" in
    file://?*)
      SRC_KIND="file"; srcdir="${SOURCE#file://}"
      # `dolt backup restore` runs from another cwd ($RUN/restored): a relative path would be measured here and
      # restored from there, and the miss would read as a broken backup. "/" itself is refused (du of the whole disk).
      case "$srcdir" in /?*) ;; *) note_rc 2 "--source file:// precisa de caminho absoluto (file:///dir): $SOURCE"; finish ;; esac ;;
    s3://?*)   SRC_KIND="s3" ;;
    *) note_rc 2 "--source precisa ser file:///dir ou s3://bucket/prefix"; finish ;;
  esac
  if [ "$SRC_KIND" = file ]; then
    [ -d "$srcdir" ] || { note_rc 2 "origem nao existe: $srcdir"; finish; }
    # A symlink to the backup dir is followed ONCE, here: handed the link itself, `du` says 0KB and `find` lists the link
    # alone, so the disk gate and the readability walk below would be looking at nothing. Not enterable → not readable.
    phys=$(cd "$srcdir" 2>/dev/null && pwd -P) \
      || { note_rc 2 "origem ilegivel: $srcdir (o laboratorio nao consegue entrar nela; nao e veredito sobre o backup)"; finish; }
    srcdir="$phys"
    _need_readable "$srcdir" "origem"
    # vazio/falhou → "" → rc 2 "nao consegui medir" logo abaixo; a leitura parcial que o du aceitaria como tamanho nao passa
    SRC_KB=$(_du_kb "$srcdir")
  else
    command -v "$LAB_AWS" >/dev/null 2>&1 || { note_rc 2 "aws ausente (origem s3:// precisa do aws CLI)"; finish; }
    # the status counts: an `aws s3 ls` that printed a size and then failed is not a size
    ls_out=$(_run_to "$LAB_FETCH_TIMEOUT" "$LAB_AWS" s3 ls --recursive --summarize "$SOURCE" 2>/dev/null) || ls_out=""
    SRC_KB=$(printf '%s\n' "$ls_out" | awk '/Total Size:/{printf "%d", $3/1024}')
  fi
  avail=$(df -Pk "$WORKDIR" 2>/dev/null | awk 'NR==2{print $4}')
  case "$SRC_KB" in ''|*[!0-9]*) note_rc 2 "nao consegui medir o tamanho do backup"; finish ;; esac
  case "$avail" in ''|*[!0-9]*) note_rc 2 "nao consegui medir o disco livre"; finish ;; esac
  # 12 digits of KB is an exabyte: anything longer is a garbled number, and would wrap the multiplication below
  [ "${#SRC_KB}" -le 12 ] && [ "${#avail}" -le 12 ] || { note_rc 2 "tamanho do backup ou disco livre fora do intervalo"; finish; }
  need=$(( SRC_KB * LAB_DISK_MARGIN_PCT / 100 ))
  log "backup ~${SRC_KB}KB, preciso ~${need}KB (margem ${LAB_DISK_MARGIN_PCT}%), livre ${avail}KB"
  if [ "$avail" -lt "$need" ]; then note_rc 2 "disco insuficiente (${avail}KB < ${need}KB); nao e falha do backup"; finish; fi

  if [ "$SRC_KIND" = s3 ]; then
    fetchdir="$RUN/fetch/$DB"; mkdir -p "$fetchdir"; s0=$(_now)
    if ! _run_to "$LAB_FETCH_TIMEOUT" "$LAB_AWS" s3 sync "$SOURCE" "$fetchdir" --only-show-errors >/dev/null 2>&1; then
      T_FETCH=$(( $(_now) - s0 )); note_rc 2 "aws s3 sync falhou ou estourou o tempo (credencial, rede ou bucket)"; finish
    fi
    T_FETCH=$(( $(_now) - s0 )); srcdir="$fetchdir"
    _need_readable "$srcdir" "copia baixada do s3"
  fi
  # `-f` is a verdict only because the walk above proved this directory can be listed and entered (a manifest that
  # could not be looked at used to be "backup sem manifest", rc 1)
  if [ ! -f "$srcdir/manifest" ]; then note_rc 1 "backup sem arquivo manifest do dolt (nao restaura)"; finish; fi

  # The restore verdict. 0 = restored. Exactly 1 = dolt itself said no (a broken .darc, a bad backup): FAIL. Anything
  # else — the timeout (124), a kill (>=128), a Go panic (2), no timeout binary (125) — means the restore did not
  # FINISH, which says nothing about the backup: UNKNOWN. (Disk full mid-restore also exits 1; the margin check
  # above is what guards that.)
  mkdir -p "$RUN/restored" || { note_rc 2 "nao consegui criar $RUN/restored"; finish; }
  s0=$(_now)
  ( cd "$RUN/restored" || exit 126; _run_to "$LAB_RESTORE_TIMEOUT" "$LAB_DOLT" backup restore "file://$srcdir" "$DB" >/dev/null 2>&1 ); st=$?
  T_RESTORE=$(( $(_now) - s0 )); restored_dir="$RUN/restored/$DB"
  case "$st" in
    0) ;;
    1) note_rc 1 "dolt backup restore falhou (o dolt recusou o backup, status 1)"; finish ;;
    *) note_rc 2 "dolt backup restore nao terminou: $(_st_words "$st") (LAB_RESTORE_TIMEOUT=${LAB_RESTORE_TIMEOUT}s)"; finish ;;
  esac
  if [ ! -d "$restored_dir/.dolt" ]; then note_rc 2 "dolt backup restore terminou sem criar o banco $DB (nao e um veredito sobre o backup)"; finish; fi
  RESTORE_KB=$(_du_kb "$restored_dir")   # vazio/falhou → "" (nao medido: restored_kb null), nao muda o veredito
  [ "$SRC_KIND" = s3 ] && [ "$KEEP" -eq 0 ] && rm -rf "$RUN/fetch"   # frees the fetched copy: gc needs the room

  s0=$(_now)
  if [ "$MANIFEST_OK" -eq 1 ]; then
    : > "$TABLES_TSV"
    while IFS="$(printf '\t')" read -r t e; do
      [ -n "$t" ] || continue
      ncount=$((ncount+1))
      n=$(_count "$restored_dir" "$t"); st=$?
      case "$st" in
        0) printf '%s\t%s\t%s\n' "$t" "$e" "$n" >> "$TABLES_TSV"
           [ "$n" -ge "$e" ] || note_rc 1 "tabela $t: restaurado $n < esperado $e" ;;
        1) printf '%s\t%s\t\n' "$t" "$e" >> "$TABLES_TSV"
           note_rc 1 "tabela $t ausente ou ilegivel no banco restaurado (o dolt recusou a consulta)" ;;
        *) printf '%s\t%s\t\n' "$t" "$e" >> "$TABLES_TSV"
           note_rc 2 "contagem da tabela $t nao terminou ou veio ilegivel (LAB_SQL_TIMEOUT=${LAB_SQL_TIMEOUT}s): nao e veredito sobre o backup" ;;
      esac
    done < "$RUN/expected.tsv"
    # vazio → UNKNOWN: "0 tabelas conferidas" must not read as "every table checked" (the parser rejects an empty
    # manifest, but an OK has to rest on a count made, not on a parser that was expected to say no)
    [ "$ncount" -gt 0 ] || note_rc 2 "nenhuma tabela do manifest foi conferida (a lista de tabelas chegou vazia)"
  fi
  T_COUNT=$(( $(_now) - s0 ))
  if [ $(( $(_now) - START_EPOCH )) -gt "$RTO" ]; then note_rc 3 "fetch+restore+contagem em $(( $(_now) - START_EPOCH ))s, acima do RTO de ${RTO}s"; fi

  if [ "$FLATTEN" -eq 1 ]; then
    if [ "$RC" -eq 0 ] || [ "$RC" -eq 3 ]; then _flatten "$restored_dir" "$TABLES_TSV"
    else F_RESULT=SKIPPED; F_WHY="restore-nao-verificado"; fi
    log "flatten: $F_RESULT ($F_WHY)"
  fi
  [ "$RC" -eq 0 ] && log "OK: restore verificado em $(( $(_now) - START_EPOCH ))s (RTO ${RTO}s)"
  finish
}

usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d' | cut -c3-; }

main() {
  local cmd="${1:-}"
  [ "$#" -gt 0 ] && shift
  case "$cmd" in run) ;; -h|--help|help|"") usage; return 0 ;; *) echo "subcomando desconhecido: $cmd" >&2; return 2 ;; esac
  while [ "$#" -gt 0 ]; do
    # an option that takes a value and has none (trailing `--rto-seconds`) used to leave `shift 2` failing in an
    # endless loop: it is a usage error, rc 2, before anything else happens
    case "$1" in
      --db|--source|--manifest|--workdir|--rto-seconds|--report|--gc-args)
        if [ "$#" -lt 2 ]; then echo "opcao $1 precisa de um valor" >&2; return 2; fi ;;
    esac
    case "$1" in
      --db) DB="$2"; shift 2 ;;
      --source) SOURCE="$2"; shift 2 ;;
      --manifest) MANIFEST="$2"; shift 2 ;;
      --workdir) WORKDIR="$2"; shift 2 ;;
      --rto-seconds) RTO="$2"; shift 2 ;;
      --report) REPORT="$2"; shift 2 ;;
      --gc-args) GC_ARGS="$2"; shift 2 ;;
      --flatten) FLATTEN=1; F_WHY="rodada-terminou-antes-do-flatten"; shift ;;   # not "nao-pedido": it WAS asked
      --keep) KEEP=1; shift ;;
      *) echo "opcao desconhecida: $1" >&2; return 2 ;;
    esac
  done
  arm_traps
  run_lab
}

if [ "${DOLT_RESTORE_LAB_LIB:-0}" != "1" ]; then main "$@"; fi
