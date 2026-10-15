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
#   1 FAIL     checked and broken: no manifest in the backup, restore fails, a table is missing,
#              unreadable or below the manifest
#   2 UNKNOWN  could not check: bad/empty/other-db manifest, no dolt/python3, fetch failed,
#              disk too small, another run in progress
#   3 SLOW     everything passed but fetch+restore+count took longer than the RTO
# The exit code is the RESTORE verdict only. The flatten result is in the report and on the
# RESULT line (flatten=OK|FAIL|SKIPPED|UNKNOWN): it is research, it must not page anyone as a
# backup failure.
#
# DISK: needs LAB_DISK_MARGIN_PCT (default 400) of the backup size free — the fetched copy, the
# restored copy and gc headroom (dolt gc wants 2-2.8x the database). Unreadable = UNKNOWN.
#
# TEST: bash scripts/dolt-restore-lab.selftest.sh   (real dolt on a tiny fixture, fake aws)
# Library mode: DOLT_RESTORE_LAB_LIB=1 source dolt-restore-lab.sh
set -uo pipefail

LAB_DOLT="${LAB_DOLT:-dolt}"
LAB_AWS="${LAB_AWS:-aws}"
LAB_PY="${LAB_PY:-python3}"
LAB_TIMEOUT_BIN="${LAB_TIMEOUT_BIN:-timeout}"
LAB_FETCH_TIMEOUT="${LAB_FETCH_TIMEOUT:-14400}"
LAB_RESTORE_TIMEOUT="${LAB_RESTORE_TIMEOUT:-7200}"
LAB_FLATTEN_TIMEOUT="${LAB_FLATTEN_TIMEOUT:-7200}"
LAB_DISK_MARGIN_PCT="${LAB_DISK_MARGIN_PCT:-400}"
LAB_LOG="${LAB_LOG:-}"

RC=0; REASON=""; RUN=""; LOCK=""; LOCK_OWNED=0; KEEP=0
T_FETCH=""; T_RESTORE=""; T_COUNT=""; T_TOTAL=""; RESTORE_KB=""; SRC_KIND=""; SRC_KB=""
F_RESULT="SKIPPED"; F_WHY="nao-pedido"; F_COMMITS_BEFORE=""; F_COMMITS_AFTER=""
F_KB_BEFORE=""; F_KB_AFTER=""; F_FLATTEN_S=""; F_GC_S=""
TABLES_TSV=""; STARTED=""

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

_run_to() {  # _run_to <seconds> cmd... — a missing `timeout` degrades to no limit, said once in the log
  local secs="$1"; shift
  if command -v "$LAB_TIMEOUT_BIN" >/dev/null 2>&1; then "$LAB_TIMEOUT_BIN" "$secs" "$@"; else "$@"; fi
}

_sql_scalar() {  # _sql_scalar <dbdir> <query> — prints ONE non-empty line or fails; never a guess
  local out
  out=$(cd "$1" 2>/dev/null && _run_to 600 "$LAB_DOLT" sql -q "$2" -r csv 2>/dev/null) || return 1
  out=$(printf '%s\n' "$out" | tail -n +2 | head -1)
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

_sql_int() {  # _sql_int <dbdir> <query> — a non-negative integer or failure; text is "could not read", not a number
  local v
  v=$(_sql_scalar "$1" "$2") || return 1
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$v"
}

_count() { _sql_int "$1" "SELECT COUNT(*) FROM \`$2\`"; }  # table name was validated by the manifest parser

_du_kb() { du -sk "$1" 2>/dev/null | awk '{print $1}'; }

_write_report() {  # key=value pairs; flatten.* nests; numbers become ints; tables from $TABLES_TSV
  [ -n "${REPORT:-}" ] || return 0
  "$LAB_PY" -I - "$REPORT" "${TABLES_TSV:-}" "$@" <<'PY' || log "AVISO: nao consegui gravar o relatorio $REPORT"
import json, os, re, sys
path, tsv = sys.argv[1], sys.argv[2]
d = {}
for a in sys.argv[3:]:
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
if tsv and os.path.isfile(tsv):
    for line in open(tsv):
        n, e, r = (line.rstrip("\n").split("\t") + ["", ""])[:3]
        t[n] = {"expected": int(e), "restored": int(r) if r != "" else None}
d["tables"] = t
tmp = path + ".tmp.%d" % os.getpid()
with open(tmp, "w") as f:
    json.dump(d, f, indent=2, sort_keys=True); f.write("\n")
os.replace(tmp, path)
PY
}

cleanup() {
  if [ -n "$RUN" ] && [ "$KEEP" -eq 0 ]; then
    case "$RUN" in "$WORKDIR"/run-*) [ -d "$RUN" ] && rm -rf "$RUN" ;; esac
  fi
  if [ "$LOCK_OWNED" -eq 1 ] && [ -n "$LOCK" ]; then rm -rf "$LOCK"; fi
}

finish() {  # the ONLY exit path after argument parsing: report + RESULT line + exit code
  local now vname
  now=$(_now); T_TOTAL=$(( now - START_EPOCH ))
  vname=$(_verdict_name "$RC")
  _write_report schema=1 db="$DB" verdict="$vname" rc="$RC" reason="$REASON" host="$(hostname -s 2>/dev/null)" \
    started_at="$STARTED" finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" dolt_version="$("$LAB_DOLT" version 2>/dev/null | head -1)" \
    source_kind="$SRC_KIND" source_kb="$SRC_KB" rto_seconds="$RTO" fetch_s="$T_FETCH" restore_s="$T_RESTORE" \
    count_s="$T_COUNT" total_s="$T_TOTAL" restored_kb="$RESTORE_KB" \
    flatten.result="$F_RESULT" flatten.why="$F_WHY" flatten.commits_before="$F_COMMITS_BEFORE" \
    flatten.commits_after="$F_COMMITS_AFTER" flatten.kb_before="$F_KB_BEFORE" flatten.kb_after_gc="$F_KB_AFTER" \
    flatten.flatten_s="$F_FLATTEN_S" flatten.gc_s="$F_GC_S" flatten.gc_args="$GC_ARGS"
  printf 'RESULT: %s db=%s rc=%s total_s=%s flatten=%s report=%s\n' "$vname" "$DB" "$RC" "$T_TOTAL" "$F_RESULT" "${REPORT:-none}"
  exit "$RC"
}

_parse_manifest() {  # prints "table<TAB>count" lines; non-zero with a reason on stderr if unusable
  "$LAB_PY" -I - "$1" "$2" <<'PY'
import json, re, sys
try:
    m = json.load(open(sys.argv[1]))
except Exception as e:
    sys.exit("manifest ilegivel: %s" % type(e).__name__)
if not isinstance(m, dict) or not isinstance(m.get("tables"), dict) or not m["tables"]:
    sys.exit("manifest sem tabelas (vazio nao verifica nada)")
if m.get("db") not in (None, sys.argv[2]):
    sys.exit("manifest e de outro banco: %r" % (m.get("db"),))
for k, v in m["tables"].items():
    if not re.fullmatch(r"[A-Za-z0-9_]+", k):
        sys.exit("nome de tabela invalido no manifest")
    if isinstance(v, bool) or not isinstance(v, int) or v < 0:
        sys.exit("contagem invalida no manifest para %s" % k)
    print("%s\t%d" % (k, v))
PY
}

_take_lock() {
  LOCK="$WORKDIR/.lab.lock"
  if mkdir "$LOCK" 2>/dev/null; then printf '%s\n' "$$" > "$LOCK/pid"; LOCK_OWNED=1; return 0; fi
  local other; other=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then LOCK=""; return 1; fi
  rm -rf "$LOCK"
  if mkdir "$LOCK" 2>/dev/null; then printf '%s\n' "$$" > "$LOCK/pid"; LOCK_OWNED=1; return 0; fi
  LOCK=""; return 1
}

# _flatten <dbdir> <counts-tsv> — the `bd flatten` recipe (Tim Sehn) with plain dolt on the COPY:
# new branch, soft-reset to the root commit, one snapshot commit, swap the branch, dolt gc.
# EVERY step is checked: an unchecked `reset` once left a no-op "flatten" that looked fine.
_flatten() {
  local d="$1" tsv="$2" roots nroots root br t e r n s0 s1 s2
  F_RESULT=UNKNOWN
  F_COMMITS_BEFORE=$(_sql_int "$d" "SELECT COUNT(*) FROM dolt_log") || { F_WHY="sem-contagem-de-commits"; return 0; }
  F_KB_BEFORE=$(_du_kb "$d/.dolt")
  if [ "$F_COMMITS_BEFORE" -le 2 ]; then F_RESULT=SKIPPED; F_WHY="nada-a-achatar(commits=$F_COMMITS_BEFORE)"; return 0; fi
  roots=$(cd "$d" && _run_to 600 "$LAB_DOLT" sql -q "SELECT commit_hash FROM dolt_commit_ancestors WHERE parent_hash IS NULL" -r csv 2>/dev/null | tail -n +2)
  nroots=$(printf '%s\n' "$roots" | grep -c .)
  if [ "$nroots" -ne 1 ]; then F_WHY="raiz-nao-encontrada-ou-ambigua($nroots)"; return 0; fi
  root="$roots"
  br=$(_sql_scalar "$d" "SELECT active_branch()") || { F_WHY="sem-branch-ativo"; return 0; }
  s0=$(_now)
  if ! ( cd "$d" \
      && _run_to "$LAB_FLATTEN_TIMEOUT" "$LAB_DOLT" checkout -b lab_flat >/dev/null 2>&1 \
      && _run_to "$LAB_FLATTEN_TIMEOUT" "$LAB_DOLT" reset --soft "$root" >/dev/null 2>&1 \
      && _run_to "$LAB_FLATTEN_TIMEOUT" "$LAB_DOLT" add -A >/dev/null 2>&1 \
      && _run_to "$LAB_FLATTEN_TIMEOUT" "$LAB_DOLT" commit -m "flatten (restore-lab)" >/dev/null 2>&1 \
      && _run_to "$LAB_FLATTEN_TIMEOUT" "$LAB_DOLT" branch -f "$br" lab_flat >/dev/null 2>&1 \
      && _run_to "$LAB_FLATTEN_TIMEOUT" "$LAB_DOLT" checkout "$br" >/dev/null 2>&1 \
      && _run_to "$LAB_FLATTEN_TIMEOUT" "$LAB_DOLT" branch -D lab_flat >/dev/null 2>&1 ); then
    F_RESULT=FAIL; F_WHY="passo-do-flatten-falhou"; F_FLATTEN_S=$(( $(_now) - s0 )); return 0
  fi
  s1=$(_now); F_FLATTEN_S=$(( s1 - s0 ))
  # shellcheck disable=SC2086
  if ! ( cd "$d" && _run_to "$LAB_FLATTEN_TIMEOUT" "$LAB_DOLT" gc $GC_ARGS >/dev/null 2>&1 ); then
    F_RESULT=FAIL; F_WHY="dolt-gc-falhou-ou-estourou-o-tempo"; F_GC_S=$(( $(_now) - s1 )); return 0
  fi
  s2=$(_now); F_GC_S=$(( s2 - s1 ))
  F_KB_AFTER=$(_du_kb "$d/.dolt")
  F_COMMITS_AFTER=$(_sql_int "$d" "SELECT COUNT(*) FROM dolt_log") || { F_RESULT=FAIL; F_WHY="sem-contagem-de-commits-depois"; return 0; }
  if [ "$F_COMMITS_AFTER" -ge "$F_COMMITS_BEFORE" ]; then F_RESULT=FAIL; F_WHY="historia-nao-encolheu($F_COMMITS_BEFORE->$F_COMMITS_AFTER)"; return 0; fi
  while IFS="$(printf '\t')" read -r t e r; do
    [ -n "$t" ] || continue
    n=$(_count "$d" "$t") || { F_RESULT=FAIL; F_WHY="tabela-ilegivel-depois-do-flatten:$t"; return 0; }
    if [ "$n" != "$r" ]; then F_RESULT=FAIL; F_WHY="contagem-mudou-no-flatten:$t($r->$n)"; return 0; fi
  done < "$tsv"
  F_RESULT=OK; F_WHY="commits $F_COMMITS_BEFORE->$F_COMMITS_AFTER, ${F_KB_BEFORE}KB->${F_KB_AFTER}KB"
}

run_lab() {
  local srcdir fetchdir restored_dir t e n s0 s1 avail need
  STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ); START_EPOCH=$(_now)
  case "$DB" in ''|*[!A-Za-z0-9_]*) note_rc 2 "--db invalido"; finish ;; esac
  case "$WORKDIR" in /?*) ;; *) note_rc 2 "--workdir precisa ser caminho absoluto"; finish ;; esac
  case "$WORKDIR" in /|"${HOME:-/nonexistent}"|"${HOME:-/nonexistent}"/) note_rc 2 "--workdir recusado: $WORKDIR"; finish ;; esac
  if [ -e "$WORKDIR/.dolt" ] || [ -e "$WORKDIR/.beads" ]; then note_rc 2 "--workdir parece um banco vivo (.dolt/.beads)"; finish; fi
  command -v "$LAB_PY" >/dev/null 2>&1 || { note_rc 2 "python3 ausente"; finish; }
  command -v "$LAB_DOLT" >/dev/null 2>&1 || { note_rc 2 "dolt ausente"; finish; }
  case "$RTO" in ''|*[!0-9]*) note_rc 2 "--rto-seconds invalido"; finish ;; esac
  TABLES_TSV=""
  mkdir -p "$WORKDIR" 2>/dev/null || { note_rc 2 "nao consegui criar $WORKDIR"; finish; }
  _take_lock || { note_rc 2 "outra rodada em curso em $WORKDIR"; finish; }
  RUN=$(mktemp -d "$WORKDIR/run-XXXXXX") || { note_rc 2 "mktemp falhou em $WORKDIR"; finish; }
  TABLES_TSV="$RUN/tables.tsv"
  # Own dolt home inside the scratch dir: `dolt commit` (flatten) needs an identity a fresh host does
  # not have, and this way the host user's ~/.dolt is never read or written. Removed with $RUN.
  export DOLT_ROOT_PATH="$RUN/dolt-home"; mkdir -p "$DOLT_ROOT_PATH"
  "$LAB_DOLT" config --global --add user.name restore-lab >/dev/null 2>&1
  "$LAB_DOLT" config --global --add user.email restore-lab@localhost >/dev/null 2>&1
  # The manifest first: if it is unusable we still drill (the timing is worth having) but the verdict is UNKNOWN.
  MANIFEST_OK=1
  if ! _parse_manifest "$MANIFEST" "$DB" > "$RUN/expected.tsv" 2> "$RUN/manifest.err"; then
    MANIFEST_OK=0; note_rc 2 "$(head -1 "$RUN/manifest.err")"
  fi
  case "$SOURCE" in
    file://?*) SRC_KIND="file"; srcdir="${SOURCE#file://}" ;;
    s3://?*)   SRC_KIND="s3" ;;
    *) note_rc 2 "--source precisa ser file:///dir ou s3://bucket/prefix"; finish ;;
  esac
  if [ "$SRC_KIND" = file ]; then
    [ -d "$srcdir" ] || { note_rc 2 "origem nao existe: $srcdir"; finish; }
    SRC_KB=$(_du_kb "$srcdir")
  else
    SRC_KB=$("$LAB_AWS" s3 ls --recursive --summarize "$SOURCE" 2>/dev/null | awk '/Total Size:/{printf "%d", $3/1024}')
  fi
  avail=$(df -Pk "$WORKDIR" 2>/dev/null | awk 'NR==2{print $4}')
  case "$SRC_KB" in ''|*[!0-9]*) note_rc 2 "nao consegui medir o tamanho do backup"; finish ;; esac
  case "$avail" in ''|*[!0-9]*) note_rc 2 "nao consegui medir o disco livre"; finish ;; esac
  need=$(( SRC_KB * LAB_DISK_MARGIN_PCT / 100 ))
  log "backup ~${SRC_KB}KB, preciso ~${need}KB (margem ${LAB_DISK_MARGIN_PCT}%), livre ${avail}KB"
  if [ "$avail" -lt "$need" ]; then note_rc 2 "disco insuficiente (${avail}KB < ${need}KB); nao e falha do backup"; finish; fi

  if [ "$SRC_KIND" = s3 ]; then
    fetchdir="$RUN/fetch/$DB"; mkdir -p "$fetchdir"; s0=$(_now)
    if ! _run_to "$LAB_FETCH_TIMEOUT" "$LAB_AWS" s3 sync "$SOURCE" "$fetchdir" --only-show-errors >/dev/null 2>&1; then
      T_FETCH=$(( $(_now) - s0 )); note_rc 2 "aws s3 sync falhou ou estourou o tempo (credencial, rede ou bucket)"; finish
    fi
    T_FETCH=$(( $(_now) - s0 )); srcdir="$fetchdir"
  fi
  if [ ! -f "$srcdir/manifest" ]; then note_rc 1 "backup sem arquivo manifest do dolt (nao restaura)"; finish; fi

  mkdir -p "$RUN/restored"; s0=$(_now)
  if ! ( cd "$RUN/restored" && _run_to "$LAB_RESTORE_TIMEOUT" "$LAB_DOLT" backup restore "file://$srcdir" "$DB" >/dev/null 2>&1 ); then
    T_RESTORE=$(( $(_now) - s0 )); note_rc 1 "dolt backup restore falhou"; finish
  fi
  T_RESTORE=$(( $(_now) - s0 )); restored_dir="$RUN/restored/$DB"
  RESTORE_KB=$(_du_kb "$restored_dir")
  [ "$SRC_KIND" = s3 ] && [ "$KEEP" -eq 0 ] && rm -rf "$RUN/fetch"   # frees the fetched copy: gc needs the room

  s0=$(_now)
  if [ "$MANIFEST_OK" -eq 1 ]; then
    : > "$TABLES_TSV"
    while IFS="$(printf '\t')" read -r t e; do
      [ -n "$t" ] || continue
      if n=$(_count "$restored_dir" "$t"); then
        printf '%s\t%s\t%s\n' "$t" "$e" "$n" >> "$TABLES_TSV"
        [ "$n" -ge "$e" ] || note_rc 1 "tabela $t: restaurado $n < esperado $e"
      else
        printf '%s\t%s\t\n' "$t" "$e" >> "$TABLES_TSV"
        note_rc 1 "tabela $t ausente ou ilegivel no banco restaurado"
      fi
    done < "$RUN/expected.tsv"
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
  DB=""; SOURCE=""; MANIFEST=""; WORKDIR=""; RTO=1800; REPORT=""; FLATTEN=0; GC_ARGS=""
  case "$cmd" in run) ;; -h|--help|help|"") usage; return 0 ;; *) echo "subcomando desconhecido: $cmd" >&2; return 2 ;; esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --db) DB="${2:-}"; shift 2 ;;
      --source) SOURCE="${2:-}"; shift 2 ;;
      --manifest) MANIFEST="${2:-}"; shift 2 ;;
      --workdir) WORKDIR="${2:-}"; shift 2 ;;
      --rto-seconds) RTO="${2:-}"; shift 2 ;;
      --report) REPORT="${2:-}"; shift 2 ;;
      --gc-args) GC_ARGS="${2:-}"; shift 2 ;;
      --flatten) FLATTEN=1; shift ;;
      --keep) KEEP=1; shift ;;
      *) echo "opcao desconhecida: $1" >&2; return 2 ;;
    esac
  done
  trap cleanup EXIT
  run_lab
}

if [ "${DOLT_RESTORE_LAB_LIB:-0}" != "1" ]; then main "$@"; fi
