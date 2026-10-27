#!/bin/bash
# jsonl-export.selftest.sh — unit tests for ensure_archive_pack_config(), the
# ga-gtrc8n fix that makes the git-maintenance pack.threads/windowMemory/
# deltaCacheSize bound durable across archive-repo deletion+recreation.
#
# Hermetic: sources jsonl-export.sh in library mode (JSONL_EXPORT_LIB=1),
# which returns before dolt-target.sh is sourced — no live Dolt server, port
# resolution, or GC_CITY_PATH is ever required. Real dolt/git-push/mail/nudge
# are NEVER called; only throwaway repos under a temp directory are touched.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/jsonl-export.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# Runs "$@" as a command after sourcing jsonl-export.sh in library mode, in a
# subshell — so the sourced script's `set -euo pipefail` never leaks into
# this selftest's own shell, and each call starts from a clean function/var
# state.
lib_call() {
  (
    export JSONL_EXPORT_LIB=1
    . "$SCRIPT" >/dev/null 2>&1
    "$@"
  )
}

echo "=== jsonl-export.selftest.sh ==="

if lib_call type ensure_archive_pack_config >/dev/null 2>&1; then
  ok "ensure_archive_pack_config defined by lib-mode source"
else
  bad "ensure_archive_pack_config NOT defined — lib mode broken, or fix not yet implemented"
  echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ── AC1: a freshly created repo (the real "git init" + call path) is born ────
# ── with all three keys ───────────────────────────────────────────────────────
FRESH_REPO="$WORK/fresh-repo"
mkdir -p "$FRESH_REPO"
git -C "$FRESH_REPO" init -q
lib_call ensure_archive_pack_config "$FRESH_REPO"

threads=$(git -C "$FRESH_REPO" config --get pack.threads 2>/dev/null || echo "MISSING")
window=$(git -C "$FRESH_REPO" config --get pack.windowMemory 2>/dev/null || echo "MISSING")
deltacache=$(git -C "$FRESH_REPO" config --get pack.deltaCacheSize 2>/dev/null || echo "MISSING")

[ "$threads" = "2" ] \
  && ok "fresh repo: pack.threads = 2" \
  || bad "fresh repo: pack.threads = '$threads', want '2'"
[ "$window" = "256m" ] \
  && ok "fresh repo: pack.windowMemory = 256m" \
  || bad "fresh repo: pack.windowMemory = '$window', want '256m'"
[ "$deltacache" = "64m" ] \
  && ok "fresh repo: pack.deltaCacheSize = 64m" \
  || bad "fresh repo: pack.deltaCacheSize = '$deltacache', want '64m'"

# ── AC2: a pre-existing repo WITHOUT the keys (simulates a repo created ──────
# ── before this fix shipped) gains them on its next execution ────────────────
EXISTING_REPO="$WORK/existing-repo"
mkdir -p "$EXISTING_REPO"
git -C "$EXISTING_REPO" init -q
if git -C "$EXISTING_REPO" config --get pack.threads >/dev/null 2>&1; then
  bad "test setup invalid: existing-repo already has pack.threads before the fix runs"
else
  ok "test setup: existing-repo has no pack.threads before the fix runs (sanity check)"
fi

lib_call ensure_archive_pack_config "$EXISTING_REPO"
threads2=$(git -C "$EXISTING_REPO" config --get pack.threads 2>/dev/null || echo "MISSING")
[ "$threads2" = "2" ] \
  && ok "pre-existing repo without keys: gains pack.threads = 2 on next execution" \
  || bad "pre-existing repo without keys: pack.threads = '$threads2', want '2'"

# ── AC3: idempotent — calling it again does not duplicate or change values ──
lib_call ensure_archive_pack_config "$EXISTING_REPO"
lib_call ensure_archive_pack_config "$EXISTING_REPO"

value_count=$(git -C "$EXISTING_REPO" config --get-all pack.threads | wc -l | tr -d ' ')
threads3=$(git -C "$EXISTING_REPO" config --get pack.threads 2>/dev/null || echo "MISSING")

[ "$value_count" = "1" ] \
  && ok "idempotent: pack.threads has exactly one value after repeated calls (no duplication)" \
  || bad "idempotent: pack.threads has $value_count values after repeated calls, want 1"
[ "$threads3" = "2" ] \
  && ok "idempotent: pack.threads still = 2 after repeated calls" \
  || bad "idempotent: pack.threads = '$threads3' after repeated calls, want '2'"

# ── ga-wkoij7: the repo is born (and a pre-existing one gains it) with NO background maintenance: a plain commit must not start a geometric repack at noon ──
# vazio → the key is not set (MISSING, and the assertion fails); falhou (git config cannot read) → also MISSING, same failure
ma=$(git -C "$FRESH_REPO" config --get maintenance.auto 2>/dev/null || echo "MISSING")
ga=$(git -C "$FRESH_REPO" config --get gc.auto 2>/dev/null || echo "MISSING")
[ "$ma" = "false" ] \
  && ok "fresh repo: maintenance.auto = false (ga-wkoij7)" \
  || bad "fresh repo: maintenance.auto = '$ma', want 'false'"
[ "$ga" = "0" ] \
  && ok "fresh repo: gc.auto = 0 (ga-wkoij7)" \
  || bad "fresh repo: gc.auto = '$ga', want '0'"
git -C "$EXISTING_REPO" config maintenance.auto true     # an operator (or git) left the old value: the next run must put it back
git -C "$EXISTING_REPO" config gc.auto 6700
lib_call ensure_archive_pack_config "$EXISTING_REPO"
ma2=$(git -C "$EXISTING_REPO" config --get maintenance.auto 2>/dev/null || echo "MISSING")
ga2=$(git -C "$EXISTING_REPO" config --get gc.auto 2>/dev/null || echo "MISSING")
[ "$ma2" = "false" ] && [ "$ga2" = "0" ] \
  && ok "pre-existing repo with the git defaults: the next run sets maintenance.auto=false and gc.auto=0 in place" \
  || bad "pre-existing repo: maintenance.auto='$ma2' gc.auto='$ga2', want false/0"
[ "$(git -C "$EXISTING_REPO" config --get-all maintenance.auto | wc -l | tr -d ' ')" = "1" ] \
  && ok "maintenance.auto stays a single value (replaced, not added)" \
  || bad "maintenance.auto has several values after repeated calls"

# ── ga-fxrrav: a SHORT export must not replace the previous snapshot ────────
# Runs the WHOLE script (not lib mode) against a stub dolt-target.sh and a stub
# `gc`, so no live Dolt, mail or nudge is touched. The stub `dolt_sql` answers
# from STUB_EXPORT_ROWS (rows in the issues export) and STUB_SOURCE_COUNT (the
# source-of-truth COUNT(*); "ERR" makes it unreadable).
E2E="$WORK/e2e"
mkdir -p "$E2E/scripts" "$E2E/bin" "$E2E/city" "$E2E/state"
cp "$SCRIPT" "$E2E/scripts/jsonl-export.sh"
cp "$HERE/jsonl-archive-repack-window-lib.sh" "$E2E/scripts/jsonl-archive-repack-window-lib.sh"   # ga-wkoij7: sourced by the exporter at start
cp "$HERE/disk-headroom-lib.sh" "$E2E/scripts/disk-headroom-lib.sh"   # ga-j2f5v5: the one reader of the free disk, sourced by the exporter at start
cat > "$E2E/scripts/dolt-target.sh" <<'STUB'
# ga-l6v576: the five supplemental tables, modelled as LIVE tables. A table is a file of JSON rows in key order ($E2E_TABLE_DIR/<t>.rows), built from STUB_ROWS_<t> the first time a run
# touches it (run_export clears the directory, so every run starts from a fresh table), and the stub answers the dialect the exporter speaks: COUNT(*), ORDER BY with LIMIT / OFFSET, and
# keyset paging (WHERE (`a`, `b`) > ('x', 7)). The stub also models what the live store did to hq.comments: ONE query that returns more than STUB_READ_CAP rows is cut — a well-formed
# document, exit 0, "unexpected EOF" on stderr. A read of ROWS is `SELECT *`; a read of KEYS selects the key columns only. Per table <t>:
#   STUB_ROWS_<t>   rows in the table (default 0), ids "<t>-000000"...; with STUB_PK="id seq" three rows share an id and seq counts 0..2
#   STUB_COUNT_<t>  the COUNT(*) answer (default = the rows the table holds now; ERR = unreadable)
#   STUB_ODD_<t>    1 = the table also holds rows whose ids carry a quote, a backslash, a double quote, a space, a trailing space and non-ASCII letters (with 60 rows and pages of 7 each
#                   of them is the last row of a page, so each becomes the cursor of the next)
#   STUB_LOSE_<t>   the last N rows are never returned by a read of ROWS, however it is paged (a read of keys still sees them: the table has them, the export read is what loses them)
#   STUB_FLAKY_<t>  the first N attempts at the table (reads of rows from the start) lose their last 128 rows, later ones are whole
#   STUB_FAIL_<t>   1 = a read of rows prints part of the document and exits 1
#   STUB_GARBAGE_<t> doc = a read of rows prints a document cut off mid-way and exits 0 (the dolt that lies about its rc); empty = it prints nothing and exits 0
#   STUB_KEYS_FAIL_<t>  1 = a read of keys exits 1
#   STUB_CHURN_<t>  <page>:<ins_behind>:<del_behind>:<ins_ahead>:<del_ahead> — ONCE per run, right after the <page>th page of rows is served, other writers change the live table: rows are
#                   inserted / deleted behind the cursor (the first rows of the table) and ahead of it (its end)
#   STUB_SKIP_<t>   <page>:<count> — in every attempt the <page>th page of rows comes back without <count> of its middle rows (a server that loses rows, the cursor moving on past them)
#   STUB_DUP_<t>    <page> — the <page>th page of an attempt starts with the row the cursor stands on (a server that repeats a row)
#   STUB_STUCK_<t>  1 = a keyset page ignores its cursor and answers from the start
#   STUB_EMPTYCUT_<t>  <page>:<sig|quiet> — in every attempt the <page>th page of rows comes back as {} (with the cut's stderr line for sig): a cut that left nothing
# STUB_READ_CAP is the most rows one query returns (0 = no cap). STUB_PK is the table's primary key (id | "id seq" | none | ERR). E2E_READ_LOG gets one
# "READ <t> <rows|keys> <limit> <cursor>" per read (cursor: - from the start, off=N for an OFFSET, after=(...) for a keyset page).
dolt_dies() { echo "stub: connection reset by peer" >&2; return 1; }   # a dolt that exits non-zero, with its reason on stderr
re_supp_table='`wa`\.`?(comments|config|dependencies|labels|metadata)([^a-z_]|$)'
re_supp_select='^SELECT (.*) FROM `wa`'
re_supp_where='WHERE \((.*)\) > \((.*)\) ORDER BY'
stub_var() { local v="$1"; printf '%s' "${!v:-${2:-}}"; }   # stub_var <name> [default] — the value of an env knob
stub_table_file() {  # stub_table_file <t> — the live table's file, built on the first touch of the run
  local t="$1" f="$E2E_TABLE_DIR/$1.rows" pk=single
  if [ ! -f "$f" ]; then
    mkdir -p "$E2E_TABLE_DIR"
    case "${STUB_PK:-id}" in *" "*) pk=composite ;; esac
    jq -n -c --arg q "'" --arg t "$t" --argjson n "$(stub_var "STUB_ROWS_$t" 0)" --arg odd "$(stub_var "STUB_ODD_$t" 0)" --arg pk "$pk" '
      def pad: ("000000" + tostring)[-6:];
      ( [range($n) | if $pk == "composite" then {id: "\($t)-\(((. / 3) | floor) | pad)", seq: (. % 3), body: "text \(.)"} else {id: "\($t)-\(. | pad)", body: "text \(.)"} end]
        + (if $odd == "1" and $n >= 60 then
             ["\($t)-000012\($q)q", "\($t)-000018\\b", "\($t)-000024\"d", "\($t)-000030 sp", "\($t)-000036 ", "\($t)-000042éñ"]
             | map({id: ., body: "odd"} + (if $pk == "composite" then {seq: 0} else {} end))
           else [] end) )
      | sort_by([.id, (.seq // 0)]) | .[]' > "$f"
  fi
  printf '%s' "$f"
}
stub_literals() {  # stub_literals <sql literal list> — a JSON array of the values, or non-zero when the text is not a well-formed list of SQL literals (the way MySQL reads \\ and '')
  printf '%s' "$1" | jq -R -c --arg q "'" '
    . as $s
    | [match("\($q)((?:[^\($q)\\\\]|\($q)\($q)|\\\\.)*)\($q)|(-?[0-9]+)"; "g")] as $m
    | if ($m | map(.string) | join(", ")) != $s then error("not a literal list") else
        $m | map(if (.string | startswith($q)) then (.captures[0].string | gsub("\($q)\($q)"; $q) | gsub("\\\\(?<c>.)"; "\(.c)")) else (.string | tonumber) end)
      end'
}
stub_churn() {  # stub_churn <table file> <ins_behind> <del_behind> <ins_ahead> <del_ahead>
  jq -s -c --argjson ib "$2" --argjson db "$3" --argjson ia "$4" --argjson da "$5" '
    (if $da > 0 then .[0:(length - $da)] else . end) as $a
    | (if $db > 0 then ($a[0:1] + $a[(1 + $db):]) else $a end) as $b
    | $b[0] as $first | $b[-1] as $last
    | ($b + [range($ib) | $first + {id: ($first.id + "-ins\(.)"), body: "inserted behind"}] + [range($ia) | $last + {id: ($last.id + "-ins\(.)"), body: "inserted ahead"}])
    | sort_by([.id, (.seq // 0)]) | .[]' "$1" > "$1.new" && mv -f "$1.new" "$1"
}
stub_supp() {  # stub_supp <query> <table>
  local q="$1" tbl="$2" tf var cnt sel kind after="null" wlits="" lim=0 off=0 cap lose flaky seen pg apg att stuck dup skip cut_page out cut doc pk="${STUB_PK:-id}" cur ib db ia da _
  tf=$(stub_table_file "$tbl")
  case "$q" in
    "SELECT COUNT(*)"*)
      cnt=$(stub_var "STUB_COUNT_$tbl")
      [ "$cnt" = "ERR" ] && return 1
      [ -n "$cnt" ] || cnt=$(wc -l < "$tf" | tr -d ' ')
      printf 'row_count\n%s\n' "$cnt"; return 0 ;;
  esac
  case "$pk" in none|ERR|"") pk=id ;; esac
  sel='*'; [[ "$q" =~ $re_supp_select ]] && sel="${BASH_REMATCH[1]}"
  kind=rows; [ "$sel" = '*' ] || kind=keys
  if [[ "$q" =~ $re_supp_where ]]; then
    wlits="${BASH_REMATCH[2]}"
    if ! after=$(stub_literals "$wlits" 2>/dev/null); then echo "stub: syntax error near the key literal: $wlits" >&2; return 1; fi
  fi
  [[ "$q" =~ LIMIT\ ([0-9]+) ]] && lim="${BASH_REMATCH[1]}"
  [[ "$q" =~ OFFSET\ ([0-9]+) ]] && off="${BASH_REMATCH[1]}"
  cur="-"; [ "$after" = "null" ] || cur="after=($wlits)"; [ "$off" = "0" ] || cur="off=$off"
  [ -z "${E2E_READ_LOG:-}" ] || printf 'READ %s %s %s %s\n' "$tbl" "$kind" "$([ "$lim" = 0 ] && echo all || echo "$lim")" "$cur" >> "$E2E_READ_LOG"

  lose=$(stub_var "STUB_LOSE_$tbl" 0); cap=$(stub_var STUB_READ_CAP 0); stuck=false; dup=false; skip=0; cut_page=""
  if [ "$kind" = "keys" ]; then
    lose=0
    [ "$(stub_var "STUB_KEYS_FAIL_$tbl" 0)" = "1" ] && { dolt_dies; return; }
  else
    # which page of the attempt, and which attempt, this is — an attempt starts at the first page (no cursor, no offset)
    mkdir -p "$E2E_TABLE_DIR"
    pg=$(( $(cat "$E2E_TABLE_DIR/$tbl.pages" 2>/dev/null || echo 0) + 1 )); printf '%s' "$pg" > "$E2E_TABLE_DIR/$tbl.pages"
    if [ "$after" = "null" ] && [ "$off" = "0" ]; then
      apg=1
      flaky=$(stub_var "STUB_FLAKY_$tbl" 0)
      if [ "$flaky" -gt 0 ] && [ -n "${E2E_FLAKY_DIR:-}" ]; then
        seen=$(( $(cat "$E2E_FLAKY_DIR/$tbl" 2>/dev/null || echo 0) + 1 )); printf '%s' "$seen" > "$E2E_FLAKY_DIR/$tbl"
        [ "$seen" -gt "$flaky" ] || lose=$(( lose + 128 ))
      fi
      printf '%s' "$lose" > "$E2E_TABLE_DIR/$tbl.attempt-lose"   # what this attempt loses, for its later pages
    else
      apg=$(( $(cat "$E2E_TABLE_DIR/$tbl.apage" 2>/dev/null || echo 0) + 1 ))
      lose=$(cat "$E2E_TABLE_DIR/$tbl.attempt-lose" 2>/dev/null || echo "$lose")
    fi
    printf '%s' "$apg" > "$E2E_TABLE_DIR/$tbl.apage"
    if [ "$(stub_var "STUB_FAIL_$tbl" 0)" = "1" ]; then
      printf '{"rows":'; head -n 10 "$tf" | jq -s -c '.' | tr -d '\n'; printf '}'
      dolt_dies; return
    fi
    case "$(stub_var "STUB_GARBAGE_$tbl")" in
      doc) printf '{"rows":[{"id":"%s-0","bo' "$tbl"; return 0 ;;   # rc 0, but not a JSON document: the stream ended inside a string
      empty) return 0 ;;                                            # rc 0, nothing on stdout
    esac
    cut_page=$(stub_var "STUB_EMPTYCUT_$tbl")
    if [ -n "$cut_page" ] && [ "${cut_page%%:*}" = "$apg" ]; then
      printf '{}\n'
      [ "${cut_page#*:}" != "sig" ] || echo "[mysql] 2026/10/19 01:21:48 packets.go:58 unexpected EOF" >&2
      return 0
    fi
    skip=$(stub_var "STUB_SKIP_$tbl"); if [ -n "$skip" ] && [ "${skip%%:*}" = "$apg" ]; then skip="${skip#*:}"; else skip=0; fi
  fi
  [ "$kind" = "rows" ] && [ "$(stub_var "STUB_STUCK_$tbl" 0)" = "1" ] && stuck=true
  dup=$(stub_var "STUB_DUP_$tbl"); if [ -n "$dup" ] && [ "${apg:-0}" -eq "$dup" ]; then dup=true; else dup=false; fi

  out=$(jq -s -c --arg pk "$pk" --arg sel "$sel" --arg kind "$kind" --argjson after "$after" --argjson lim "$lim" --argjson off "$off" --argjson cap "$cap" --argjson lose "$lose" \
        --argjson stuck "$stuck" --argjson dup "$dup" --argjson skip "$skip" '
    ($pk | split(" ")) as $pks
    | def k: . as $r | [$pks[] | $r[.]];
    . as $all
    | (if $kind == "keys" then $all else $all[0:([(length - $lose), 0] | max)] end) as $vis
    | (if ($after != null) and ($stuck | not) then ($vis | map(select(k > $after))) elif $off > 0 then $vis[$off:] else $vis end) as $rest
    | (if $lim > 0 then $rest[0:$lim] else $rest end) as $page
    | (if $cap > 0 and ($page | length) > $cap then [$page[0:$cap], true] else [$page, false] end) as [$capped, $cut]
    | (if $skip > 0 and ($capped | length) > ($skip + 2) then ($capped[0:1] + $capped[(1 + $skip):]) else $capped end) as $skipped
    | (if $dup and ($after != null) then ([$all[] | select(k == $after)] + $skipped) else $skipped end) as $served
    | (if $kind == "keys" then ($sel | gsub("`"; "") | split(", ")) as $cols | ($served | map(. as $r | reduce $cols[] as $c ({}; .[$c] = $r[$c]))) else $served end) as $final
    | $cut, (if ($final | length) == 0 then {} else {rows: $final} end)' "$tf") || return 1
  cut="${out%%$'\n'*}"; doc="${out#*$'\n'}"
  printf '%s\n' "$doc"
  [ "$cut" = "false" ] || echo "[mysql] 2026/10/19 01:21:48 packets.go:58 unexpected EOF" >&2
  if [ "$kind" = "rows" ]; then   # other writers act on the live table once, after the N-th page of rows of the run
    var=$(stub_var "STUB_CHURN_$tbl")
    if [ -n "$var" ] && [ ! -e "$E2E_TABLE_DIR/$tbl.churned" ] && [ "${var%%:*}" = "$pg" ]; then
      : > "$E2E_TABLE_DIR/$tbl.churned"
      IFS=: read -r _ ib db ia da <<< "$var"
      stub_churn "$tf" "$ib" "$db" "$ia" "$da"
    fi
  fi
  return 0
}
dolt_sql() {
  local q=""
  [ -z "${E2E_DOLT_CALLS:-}" ] || printf "call\n" >> "$E2E_DOLT_CALLS"   # ga-j2f5v5: a skipped tick must not ask Dolt anything
  while [ $# -gt 0 ]; do
    case "$1" in -q) q="$2"; shift ;; esac
    shift
  done
  case "$q" in
    *KEY_COLUMN_USAGE*)
      case "${STUB_PK:-id}" in
        ERR) return 1 ;;
        none) printf 'COLUMN_NAME\n' ;;
        *) printf 'COLUMN_NAME\n%s\n' "$(printf '%s' "${STUB_PK:-id}" | tr ' ' '\n')" ;;
      esac
      return 0 ;;
  esac
  if [[ "$q" =~ $re_supp_table ]]; then stub_supp "$q" "${BASH_REMATCH[1]}"; return; fi
  case "$q" in
    "SHOW DATABASES") if [ "${STUB_NO_DBS:-0}" = "1" ]; then printf 'Database\n'; else printf 'Database\nwa\n'; fi ;;
    "SELECT COUNT(*)"*)
      [ "$STUB_SOURCE_COUNT" = "ERR" ] && return 1
      printf 'row_count\n%s\n' "$STUB_SOURCE_COUNT" ;;
    "SELECT * FROM \`wa\`.issues"*)
      # ga-aai87v: STUB_KILL_SELF=1 is the engine's SIGKILL at the order's timeout — the exporter dies mid-export, no trap runs,
      # and its scratch file stays wherever the exporter put it.
      [ "${STUB_KILL_SELF:-0}" = "1" ] && kill -9 $$
      # STUB_TEST_ROWS extra rows are ones the SQL filter lets through but the
      # jq scrub (title ^test_) removes — like a real store's leftover fixtures.
      jq -n -c --argjson n "$STUB_EXPORT_ROWS" --argjson t "${STUB_TEST_ROWS:-0}" \
        '{rows: ([range($n) | {id: "wa-\(.)", title: "real issue \(.)", issue_type: "task"}]
                 + [range($t) | {id: "wa-t\(.)", title: "test_\(.)", issue_type: "task"}])}' ;;
    "SELECT * FROM"*) printf '{"rows":[]}\n' ;;
    *) return 1 ;;
  esac
}
has_wisps_table() { return 0; }
STUB
cat > "$E2E/bin/gc" <<'STUB'
#!/bin/sh
echo "gc $*" >> "$E2E_GC_LOG"
exit 0
STUB
chmod +x "$E2E/bin/gc"
# ga-ck3sz7: the exporter runs on a PATH with NO real gc/bd (selftest-sandbox-path.lib.sh). It mails the Mayor
# (`gc mail send`) when an export comes up short; if $E2E/bin/gc vanished under it, the real `gc` further down
# $PATH would send that mail for real. Here "command not found" is the only outcome.
. "$HERE/../selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $HERE/../selftest-sandbox-path.lib.sh" >&2; exit 2; }
sandbox_path_init "$E2E" git jq || exit 2   # git: the archive repo; jq: row scrub; dolt is the stubbed dolt-target.sh, gc the stub above
# ga-l6v576: a git that cannot read the archive's tree (STUB_GIT_BLIND=1: cat-file and ls-tree exit 128; every other call is the real git). "git could not say" must not read as "HEAD has no such file".
printf '#!/bin/bash\ncase " $* " in *" cat-file "*|*" ls-tree "*) [ -n "${STUB_GIT_BLIND:-}" ] && { echo "fatal: unable to read tree (injected)" >&2; exit 128; } ;; esac\nexec %s "$@"\n' "$E2E/tools/git" > "$E2E/bin/git"; chmod +x "$E2E/bin/git"
# ga-j2f5v5: the exporter now reads the free disk. The reading is PINNED here (100 GB) for every case that is not about the disk, so a host with a low disk (this one, often) does not skip the cases below;
# the disk cases set E2E_DISK_MB / E2E_NOW per call. Exported, so the runs that do not go through run_export (default-archive case) get the same pin.
export DISK_FREE_OVERRIDE_MB=102400

ARCH="$E2E/archive"
OUT=""
export E2E_TABLE_DIR="$E2E/tables"   # the stub's live supplemental tables (ga-l6v576): every run starts from fresh ones
run_export() {  # run_export <export-rows> <source-count|ERR> [scrubbed-away-rows]
  : > "$E2E/gc.log"
  : > "$E2E/dolt-calls.log"
  mkdir -p "$E2E_TABLE_DIR"; rm -f "$E2E_TABLE_DIR"/* "$E2E_TABLE_DIR"/.[!.]* 2>/dev/null
  OUT=$(
    E2E_GC_LOG="$E2E/gc.log" STUB_EXPORT_ROWS="$1" STUB_SOURCE_COUNT="$2" STUB_TEST_ROWS="${3:-0}" \
    DISK_FREE_OVERRIDE_MB="${E2E_DISK_MB:-102400}" JEX_NOW_EPOCH="${E2E_NOW:-}" E2E_DOLT_CALLS="$E2E/dolt-calls.log" \
    PATH="$SANDBOX_PATH" GC_CITY="$E2E/city" GC_PACK_STATE_DIR="${E2E_STATE:-$E2E/state}" \
    GC_JSONL_ARCHIVE_REPO="$ARCH" \
    bash "$E2E/scripts/jsonl-export.sh" 2>&1
  )
  RC=$?
}
head_rows()  { git -C "$ARCH" show HEAD:wa/issues.jsonl 2>/dev/null | jq -s -r '.[0].rows | length' 2>/dev/null || echo "?"; }
file_rows()  { jq -s -r '.[0].rows | length' "$ARCH/wa/issues.jsonl" 2>/dev/null || echo "?"; }
flat_rows()  { jq -s -r '.[0].rows | length' "$ARCH/wa.jsonl" 2>/dev/null || echo "?"; }
commits()    { git -C "$ARCH" rev-list --count HEAD 2>/dev/null || echo 0; }
mailed()     { grep -c 'mail send' "$E2E/gc.log" 2>/dev/null || true; }

# Baseline: a full export (200 rows, source agrees) becomes the first snapshot.
run_export 200 200
[ "$(head_rows)" = "200" ] && [ "$(file_rows)" = "200" ] \
  && ok "e2e baseline: full export archived (200 rows)" \
  || bad "e2e baseline: head=$(head_rows) file=$(file_rows), want 200/200 (rc=$RC): $OUT"
BASE_COMMITS=$(commits)

# Case 1 — short export, source still full (source 200 >= previous 200): the
# old code suppressed the halt but still wrote the 120-row file as the snapshot.
# 120 (not smaller) keeps the short snapshot above MIN_PREV_FOR_SPIKE_CHECK, so
# the old code's follow-up complete export is judged against it — as in prod.
run_export 120 200
[ "$(file_rows)" = "200" ] \
  && ok "short export (source >= prev): issues.jsonl keeps the previous 200 rows" \
  || bad "short export (source >= prev): issues.jsonl has $(file_rows) rows, want 200 — short export was written as snapshot"
[ "$(flat_rows)" = "200" ] \
  && ok "short export (source >= prev): flat wa.jsonl keeps the previous 200 rows" \
  || bad "short export (source >= prev): wa.jsonl has $(flat_rows) rows, want 200"
[ "$(head_rows)" = "200" ] \
  && ok "short export (source >= prev): archive HEAD still holds the 200-row snapshot" \
  || bad "short export (source >= prev): HEAD holds $(head_rows) rows, want 200 — truncated snapshot committed"
[ -z "$(git -C "$ARCH" status --porcelain)" ] \
  && ok "short export (source >= prev): archive working tree is clean" \
  || bad "short export (source >= prev): archive working tree is dirty: $(git -C "$ARCH" status --porcelain | tr '\n' ' ')"
case "$OUT" in
  *"export curto de wa: 120 vs fonte 200"*"mantido o snapshot anterior"*)
    ok "short export (source >= prev): logs 'export curto de wa: 120 vs fonte 200, mantido o snapshot anterior'" ;;
  *) bad "short export (source >= prev): missing 'export curto' log line. Output: $OUT" ;;
esac
case "$OUT" in
  *HALTED*) bad "short export (source >= prev): must not HALT (it is not a spike alarm)" ;;
  *) ok "short export (source >= prev): no HALT" ;;
esac
[ "$RC" = "0" ] \
  && ok "short export (source >= prev): exits 0" \
  || bad "short export (source >= prev): rc=$RC, want 0"
[ "$(commits)" = "$BASE_COMMITS" ] \
  && ok "short export (source >= prev): no new archive commit" \
  || bad "short export (source >= prev): commits went $BASE_COMMITS -> $(commits)"

# Case 2 — the next, complete export must NOT read as a growth spike.
run_export 200 200
case "$OUT" in
  *HALTED*) bad "recovery after short export: complete 200-row export raised a HALT (false growth spike): $OUT" ;;
  *) ok "recovery after short export: complete export does not HALT" ;;
esac
[ "$(mailed)" = "0" ] \
  && ok "recovery after short export: no spike mail sent" \
  || bad "recovery after short export: $(mailed) spike mail(s) sent"

# Case 3 — the other suppression branch: source dropped a little (5% <= 20%)
# while the export dropped a lot (40%) — still a short export.
run_export 120 190
[ "$(file_rows)" = "200" ] && [ "$(head_rows)" = "200" ] \
  && ok "short export (source drop <= threshold): previous 200-row snapshot kept" \
  || bad "short export (source drop <= threshold): file=$(file_rows) head=$(head_rows), want 200/200"

# Case 4 — a REAL drop (source fell 50%, export agrees) must still HALT and be
# recorded, so a genuine shrink is never silently swallowed by the new keep-
# previous path.
run_export 100 100
case "$OUT" in
  *HALTED*) ok "real drop (source fell with the export): still HALTs" ;;
  *) bad "real drop: expected HALT, got: $OUT" ;;
esac
[ "$(head_rows)" = "100" ] \
  && ok "real drop: HALT baseline commit records the 100-row export (existing behaviour kept)" \
  || bad "real drop: HEAD holds $(head_rows) rows, want 100"
[ "$(mailed)" -ge 1 ] \
  && ok "real drop: spike alert mail sent" \
  || bad "real drop: no spike alert mail sent"

# Case 5 — source unreadable: no way to tell short from real, so the existing
# halt is preserved (third state must not collapse into 'short export').
run_export 20 ERR
case "$OUT" in
  *HALTED*) ok "unreadable source: HALT preserved" ;;
  *) bad "unreadable source: expected HALT, got: $OUT" ;;
esac
# ga-7sxdmb: the HALT is not the only trace of the don't-know — the export was also
# never checked against the source, and every place that reports the run says so.
case "$OUT" in
  *"source count unavailable for wa"*"NOT verified against source"*)
    ok "unreadable source (HALT path): logs that the export was NOT verified against the source" ;;
  *) bad "unreadable source (HALT path): no 'NOT verified against source' log line. Output: $OUT" ;;
esac
grep -q 'DOG_DONE:.*HALTED.*unverified: wa' "$E2E/gc.log" \
  && ok "unreadable source (HALT path): the DOG_DONE nudge names 'unverified: wa'" \
  || bad "unreadable source (HALT path): DOG_DONE nudge lacks 'unverified: wa'. gc log: $(cat "$E2E/gc.log")"
git -C "$ARCH" log -1 --format=%s | grep -q 'unverified=wa' \
  && ok "unreadable source (HALT path): the HALT commit message records unverified=wa" \
  || bad "unreadable source (HALT path): HALT commit message lacks unverified=wa: $(git -C "$ARCH" log -1 --format=%s)"

# ── ga-7sxdmb: a partial export must never become the baseline, at ANY size ──
# ga-fxrrav discards a short export only when its drop trips the spike check
# (> SPIKE_THRESHOLD vs the previous snapshot). A truncated export that lost
# 15-20% slips under it, is committed as the new baseline, and the next COMPLETE
# export then reads as > 20% growth — a false HIGH escalation, same family. The
# gate is now the export against the SOURCE count, independent of the previous
# snapshot and of the threshold. Each scenario starts from its own archive.
fresh_archive() {  # fresh_archive <name>
  ARCH="$E2E/archive-$1"
  E2E_STATE="$E2E/state-$1"
  mkdir -p "$E2E_STATE"
}

# Case 6 — 800 of 1000 rows: exactly 20% short, so DELTA == 20 is NOT > 20 and
# the spike check never runs. Source is full (1000).
fresh_archive subthreshold
run_export 1000 1000
[ "$(head_rows)" = "1000" ] \
  && ok "sub-threshold: baseline full export archived (1000 rows)" \
  || bad "sub-threshold: baseline head=$(head_rows), want 1000 (rc=$RC): $OUT"
BASE_COMMITS=$(commits)
run_export 800 1000
[ "$(file_rows)" = "1000" ] && [ "$(flat_rows)" = "1000" ] \
  && ok "sub-threshold short export (800 of 1000): both files keep the previous 1000 rows" \
  || bad "sub-threshold short export: issues.jsonl=$(file_rows) wa.jsonl=$(flat_rows), want 1000/1000 — partial export written as snapshot"
[ "$(head_rows)" = "1000" ] && [ "$(commits)" = "$BASE_COMMITS" ] \
  && ok "sub-threshold short export: archive HEAD unchanged, no new commit" \
  || bad "sub-threshold short export: HEAD holds $(head_rows) rows, commits $BASE_COMMITS -> $(commits) — partial snapshot committed"
case "$OUT" in
  *"export curto de wa: 800 vs fonte 1000"*"mantido o snapshot anterior"*)
    ok "sub-threshold short export: logs 'export curto de wa: 800 vs fonte 1000, mantido o snapshot anterior'" ;;
  *) bad "sub-threshold short export: missing 'export curto' log line. Output: $OUT" ;;
esac
case "$OUT" in
  *HALTED*) bad "sub-threshold short export: must not HALT" ;;
  *) ok "sub-threshold short export: no HALT" ;;
esac
# Case 7 — the next, complete export must not read as growth.
run_export 1000 1000
case "$OUT" in
  *HALTED*) bad "recovery after sub-threshold short export: complete export raised a HALT (false growth spike): $OUT" ;;
  *) ok "recovery after sub-threshold short export: complete export does not HALT" ;;
esac
[ "$(mailed)" = "0" ] \
  && ok "recovery after sub-threshold short export: no spike mail sent" \
  || bad "recovery after sub-threshold short export: $(mailed) spike mail(s) sent"

# Case 8 — the literal ga-7sxdmb sequence (WA 5423 -> 505 -> 5425): the 505 must
# not become the base, so the 5425 export is not a +974% "spike".
fresh_archive sequence
run_export 5423 5423
run_export 505 5423
[ "$(head_rows)" = "5423" ] \
  && ok "ga-7sxdmb sequence: the 505-row export is not committed (HEAD keeps 5423)" \
  || bad "ga-7sxdmb sequence: HEAD holds $(head_rows) rows after the 505-row export, want 5423"
run_export 5425 5425
case "$OUT" in
  *HALTED*) bad "ga-7sxdmb sequence: the 5425-row export raised a HALT (false +974% spike): $OUT" ;;
  *) ok "ga-7sxdmb sequence: the 5425-row export does not HALT" ;;
esac
[ "$(mailed)" = "0" ] && [ "$(head_rows)" = "5425" ] \
  && ok "ga-7sxdmb sequence: no spike mail, HEAD advances to 5425" \
  || bad "ga-7sxdmb sequence: mails=$(mailed) head=$(head_rows), want 0 / 5425"

# Case 9 — the gate must not become the load it guards: an export a few rows
# under the source (rows removed while it ran) is a fine snapshot, not a stall.
fresh_archive churn
run_export 1000 1000
run_export 996 1000
[ "$(head_rows)" = "996" ] \
  && ok "churn: 996 of 1000 (0.4% under the source) is accepted as the new snapshot" \
  || bad "churn: HEAD holds $(head_rows) rows, want 996 — the gate discarded an export within the slack"
case "$OUT" in
  *"export curto"*) bad "churn: 996 of 1000 must not be reported as a short export: $OUT" ;;
  *) ok "churn: no 'export curto' for an export within the slack" ;;
esac

# Case 10 — the comparison is raw-export vs source (same SQL filter), NOT the
# post-scrub count: 30 rows the SQL lets through and the jq scrub removes must
# not read as a short export (that would discard every run of a store that
# carries a few leftover fixtures).
fresh_archive scrub
run_export 1000 1000
run_export 1000 1030 30
[ "$(file_rows)" = "1000" ] \
  && ok "scrub offset: scrubbed file has the 1000 real rows" \
  || bad "scrub offset: issues.jsonl has $(file_rows) rows, want 1000"
case "$OUT" in
  *"export curto"*|*"failed:"*) bad "scrub offset: rows removed by the scrub read as a short export: $OUT" ;;
  *) ok "scrub offset: 1030 raw rows vs source 1030 is a complete export" ;;
esac

# Case 11 — WHERE the archive lives. gc runs an order with GC_PACK_STATE_DIR set to
# the pack that OWNS the order (town-deltas), so a default derived from it forks
# the archive away from the one scripts/dolt-s3-backup.sh mirrors offsite (and
# dolt-gc-maintenance.sh archives pruned rows into, when enabled). The default
# must be the mirrored path.
CITY2="$E2E/city-default"
TD_STATE="$CITY2/.gc/runtime/packs/town-deltas"
mkdir -p "$TD_STATE"
: > "$E2E/gc.log"
OUT=$(
  env -u GC_JSONL_ARCHIVE_REPO -u GC_CITY_RUNTIME_DIR \
    E2E_GC_LOG="$E2E/gc.log" STUB_EXPORT_ROWS=200 STUB_SOURCE_COUNT=200 STUB_TEST_ROWS=0 \
    PATH="$SANDBOX_PATH" GC_CITY="$CITY2" GC_PACK_STATE_DIR="$TD_STATE" \
    bash "$E2E/scripts/jsonl-export.sh" 2>&1
)
RC=$?
MIRROR_REL=$(sed -n 's|^JSONL_ARCHIVE_DIR="\$CITY/\(.*\)"$|\1|p' "$HERE/../../../../scripts/dolt-s3-backup.sh" 2>/dev/null)
if [ -z "$MIRROR_REL" ]; then
  bad "default archive: could not read JSONL_ARCHIVE_DIR from scripts/dolt-s3-backup.sh — cannot tell where the offsite mirror reads"
else
  [ -d "$CITY2/$MIRROR_REL/.git" ] \
    && ok "default archive: with GC_PACK_STATE_DIR=<town-deltas> the export lands in $MIRROR_REL (what the offsite mirror reads)" \
    || bad "default archive: nothing at $CITY2/$MIRROR_REL (rc=$RC) — export forked the archive. Output: $OUT"
fi
[ ! -e "$TD_STATE/jsonl-archive" ] \
  && ok "default archive: no second archive under the owning pack's state dir" \
  || bad "default archive: a forked archive appeared at $TD_STATE/jsonl-archive"

# ── ga-7sxdmb gate round 2: the THIRD STATE of the partial-export gate ───────────
# The gate compares the export with the source's COUNT(*). When that count cannot be
# read the gate cannot tell a partial export from a complete one. It used to answer
# "not short" and commit the export with NO trace: byte-for-byte the output of a
# verified-complete export. A failing count query is likeliest exactly when Dolt is
# loaded — the truncation the gate exists for. The don't-know must be NAMED wherever
# the run is reported: the log, the DOG_DONE summary, the archive commit message.
# (Whether an unverifiable export still becomes the snapshot is deliberate — see the
# comment on the gate in jsonl-export.sh; these cases pin that behaviour too.)
unverified_seen() {  # unverified_seen <label> — the run's outputs all name the don't-know
  case "$OUT" in
    *"unavailable for wa"*"NOT verified against source"*)
      ok "$1: logs '... unavailable for wa...; export NOT verified against source'" ;;
    *) bad "$1: no 'NOT verified against source' log line — a don't-know that looks like success. Output: $OUT" ;;
  esac
  case "$OUT" in
    *"unverified: wa"*) ok "$1: the run summary names 'unverified: wa'" ;;
    *) bad "$1: run summary lacks 'unverified: wa'. Output: $OUT" ;;
  esac
  grep -q 'DOG_DONE:.*unverified: wa' "$E2E/gc.log" \
    && ok "$1: the DOG_DONE nudge names 'unverified: wa'" \
    || bad "$1: DOG_DONE nudge lacks 'unverified: wa'. gc log: $(cat "$E2E/gc.log")"
}

# Case 12 — the reviewer's repro: 850 of 1000 rows, source count unreadable.
fresh_archive unknown-partial
run_export 1000 1000
case "$OUT$(cat "$E2E/gc.log")" in
  *unverified*|*"NOT verified"*) bad "verified export: must not carry the unverified marker (it would be always-on noise): $OUT" ;;
  *) ok "verified export: no unverified marker anywhere (the signal is not always-on)" ;;
esac
BASE_COMMITS=$(commits)
run_export 850 ERR
[ "$RC" = "0" ] \
  && ok "unverified partial (850, source ERR): exits 0" \
  || bad "unverified partial: rc=$RC, want 0"
unverified_seen "unverified partial (850, source ERR)"
[ "$(head_rows)" = "850" ] && [ "$(commits)" = "$((BASE_COMMITS + 1))" ] \
  && ok "unverified partial: archived as the snapshot, as documented (HEAD 850, +1 commit)" \
  || bad "unverified partial: HEAD holds $(head_rows) rows, commits $BASE_COMMITS -> $(commits) — documented behaviour is 'archived, flagged'"
git -C "$ARCH" log -1 --format=%s | grep -q 'unverified=wa' \
  && ok "unverified partial: the archive commit message records unverified=wa" \
  || bad "unverified partial: commit message lacks unverified=wa: $(git -C "$ARCH" log -1 --format=%s)"

# Case 13 — first run (no previous snapshot, so no spike check at all), source unreadable.
fresh_archive unknown-first
run_export 200 ERR
unverified_seen "unverified first run (200, source ERR)"
[ "$(head_rows)" = "200" ] \
  && ok "unverified first run: the export is archived (HEAD 200)" \
  || bad "unverified first run: HEAD holds $(head_rows) rows, want 200"

# Cases 14/15 — the run ends WITHOUT a new commit (identical export): the signal must
# still reach the report. Two exits, so two cases: with an archive push still pending,
# and with none pending.
fresh_archive unknown-nochange
run_export 300 300
run_export 300 ERR
unverified_seen "unverified, nothing new to commit (300, source ERR)"
[ "$RC" = "0" ] \
  && ok "unverified, nothing new to commit: exits 0" \
  || bad "unverified, nothing new to commit: rc=$RC, want 0"

fresh_archive unknown-nopending
run_export 300 300
# Clear the pending-push marker (the archive has no origin, so nothing is "local-only"
# either) and the next run takes the plain "no changes" exit.
STATE_JSON="$E2E_STATE/jsonl-export-state.json"
if [ "$(jq -r '.pending_archive_push // false' "$STATE_JSON" 2>/dev/null)" != "true" ]; then
  bad "test setup invalid: no pending_archive_push in $STATE_JSON after the baseline commit"
fi
jq 'del(.pending_archive_push)' "$STATE_JSON" > "$STATE_JSON.tmp" && mv -f "$STATE_JSON.tmp" "$STATE_JSON"
run_export 300 ERR
case "$OUT" in
  *"push:"*) bad "test setup invalid: the run did not take the plain no-changes exit (it reported a push status): $OUT" ;;
esac
unverified_seen "unverified, plain no-changes exit (300, source ERR)"

# ── ga-aai87v: the export's scratch file never reaches the archive ───────────
# The exporter wrote its scratch file (issues.jsonl.tmp.XXXXXX) INSIDE the archive, in the directory `git add -A -- <db>` stages. The engine's SIGKILL at the order's
# timeout runs no trap, the file stayed, and the NEXT run's commit took it: 19 of them (16 MB) sat in the archive's HEAD and went offsite with the S3 mirror. The kill is
# simulated for real (STUB_KILL_SELF makes the stub SIGKILL the exporter mid-export), so these cases do not depend on where the file is put.
echo "=== ga-aai87v: the scratch issues.jsonl.tmp.* of a killed export never reaches the archive ==="
scratch_archive() {  # scratch_archive <name> — a fresh archive with its own scratch dir
  fresh_archive "$1"
  E2E_TMPD="$E2E/scratch-$1"
  export GC_JSONL_EXPORT_TMP_DIR="$E2E_TMPD"
}
# vazio → no scratch file under the given dirs; falhou (find could not read a dir) → the output starts with "find failed:", so a failed find is never read as "empty"
stray_in() {
  local out
  out=$(find "$@" -name 'issues.jsonl.tmp.*' -not -path '*/.git/*' 2>&1) || out="find failed: $out"
  printf '%s\n' "$out" | sed '/^$/d'
}
# vazio → 0 scratch files in HEAD; falhou/ilegível (HEAD or ls-tree unreadable) → prints "?", which none of the "= 0" / "= 1" assertions accept
tracked_stray() {
  local names
  names=$(git -C "$ARCH" ls-tree -r --name-only HEAD 2>/dev/null) || { echo "?"; return 0; }
  printf '%s\n' "$names" | grep -c 'issues\.jsonl\.tmp\.' || true
}
# vazio → archive working tree clean; falhou (git status errors) → prints "git status failed", so a broken repo is never read as clean
dirty_tree() {
  local out
  out=$(git -C "$ARCH" status --porcelain 2>&1) || out="git status failed: $out"
  printf '%s' "$out"
}
git_fixture()    { git -C "$ARCH" -c user.name=fixture -c user.email=fixture@localhost -c maintenance.auto=false "$@"; }

# Case 1 — the real sequence: a run is SIGKILLed mid-export, the next run commits.
scratch_archive killed
run_export 200 200
BASE_COMMITS=$(commits)
export STUB_KILL_SELF=1
run_export 201 201
unset STUB_KILL_SELF
[ "$RC" != "0" ] \
  && ok "killed export: the run died mid-export (rc=$RC)" \
  || bad "test setup invalid: the simulated SIGKILL did not stop the exporter (rc=0): $OUT"
[ -n "$(stray_in "$ARCH" "$E2E_TMPD")" ] \
  && ok "killed export: the dead run left its scratch file behind (the case under test exists)" \
  || bad "test setup invalid: no scratch file anywhere after the killed run"
[ -z "$(stray_in "$ARCH")" ] \
  && ok "killed export: the scratch file is NOT under the archive (outside everything git add stages)" \
  || bad "killed export: scratch file left inside the archive: $(stray_in "$ARCH" | tr '\n' ' ')"
run_export 201 201
[ "$(head_rows)" = "201" ] && [ "$(commits)" = "$((BASE_COMMITS + 1))" ] \
  && ok "after a killed export: the next export commits its snapshot (201 rows, one new commit)" \
  || bad "after a killed export: head=$(head_rows) commits $BASE_COMMITS -> $(commits), want 201 rows and +1 commit (rc=$RC): $OUT"
[ "$(tracked_stray)" = "0" ] \
  && ok "after a killed export: the snapshot commit holds no scratch file" \
  || bad "after a killed export: the archive HEAD tracks $(tracked_stray) scratch file(s): $(git -C "$ARCH" ls-tree -r --name-only HEAD | grep 'issues\.jsonl\.tmp\.' | tr '\n' ' ')"
[ -z "$(dirty_tree)" ] \
  && ok "after a killed export: archive working tree is clean" \
  || bad "after a killed export: archive working tree is dirty: $(dirty_tree | tr '\n' ' ')"

# Case 2 — what production holds today: scratch files already in HEAD (19) and one untracked. The next snapshot commit drops them; their blobs stay in history.
scratch_archive legacy
run_export 200 200
printf 'junk' > "$ARCH/wa/issues.jsonl.tmp.TRKD01"
git_fixture add -f -- wa/issues.jsonl.tmp.TRKD01 >/dev/null 2>&1 \
  && git_fixture commit -q -m "fixture: a scratch file already in HEAD" >/dev/null 2>&1
printf 'junk' > "$ARCH/wa/issues.jsonl.tmp.UNTR02"
[ "$(tracked_stray)" = "1" ] \
  && ok "legacy leftovers: fixture has 1 scratch file in HEAD and 1 untracked" \
  || bad "test setup invalid: tracked_stray=$(tracked_stray), want 1"
BASE_COMMITS=$(commits)
run_export 201 201
[ "$(tracked_stray)" = "0" ] \
  && ok "legacy leftovers: the next snapshot commit drops the tracked scratch file from HEAD" \
  || bad "legacy leftovers: HEAD still tracks $(tracked_stray) scratch file(s)"
[ -z "$(stray_in "$ARCH")" ] \
  && ok "legacy leftovers: no scratch file left in the archive working tree (tracked or untracked)" \
  || bad "legacy leftovers: still in the working tree: $(stray_in "$ARCH" | tr '\n' ' ')"
[ "$(head_rows)" = "201" ] && [ "$(commits)" = "$((BASE_COMMITS + 1))" ] \
  && ok "legacy leftovers: the real snapshot (201 rows) still commits, one new commit" \
  || bad "legacy leftovers: head=$(head_rows) commits $BASE_COMMITS -> $(commits), want 201 rows and +1 commit (rc=$RC): $OUT"
[ -z "$(dirty_tree)" ] \
  && ok "legacy leftovers: archive working tree is clean" \
  || bad "legacy leftovers: archive working tree is dirty: $(dirty_tree | tr '\n' ' ')"

# Case 3 — a dead run's leftover in the scratch dir is swept once it is old enough that no live run can own it; a fresh one (a run still going) is left alone.
scratch_archive sweep
mkdir -p "$E2E_TMPD"
printf 'old' > "$E2E_TMPD/issues.jsonl.tmp.OLD000"; touch -t 200001010000 "$E2E_TMPD/issues.jsonl.tmp.OLD000"
printf 'live' > "$E2E_TMPD/issues.jsonl.tmp.LIVE00"
run_export 200 200
[ ! -e "$E2E_TMPD/issues.jsonl.tmp.OLD000" ] \
  && ok "scratch sweep: a leftover older than the sweep age is removed" \
  || bad "scratch sweep: the old leftover is still there"
[ -e "$E2E_TMPD/issues.jsonl.tmp.LIVE00" ] \
  && ok "scratch sweep: a fresh scratch file (a run still going) is left alone" \
  || bad "scratch sweep: a fresh scratch file was deleted — it could belong to a live run"

# Case 4 — default location (no override) is the archive's sibling, and a clean run leaves nothing in it.
unset GC_JSONL_EXPORT_TMP_DIR
fresh_archive defaultdir
run_export 200 200
DEFAULT_TMPD="$(dirname "$ARCH")/.jsonl-export-tmp"
[ -d "$DEFAULT_TMPD" ] \
  && ok "default scratch dir: <archive's parent>/.jsonl-export-tmp is created" \
  || bad "default scratch dir: $DEFAULT_TMPD does not exist after a run (rc=$RC): $OUT"
# vazio → the dir is empty (a clean run left nothing); falhou (ls cannot read it) → also empty, but the -d assertion just above already failed for a missing dir
[ -z "$(ls -A "$DEFAULT_TMPD" 2>/dev/null)" ] \
  && ok "default scratch dir: a clean run leaves nothing in it" \
  || bad "default scratch dir: a clean run left: $(ls -A "$DEFAULT_TMPD" | tr '\n' ' ')"

# Case 5 — the scratch dir cannot be created: the run says so and exports nothing (the archive keeps its last snapshot), instead of falling back to a path inside the archive.
fresh_archive noscratch
run_export 200 200
BASE_COMMITS=$(commits)
printf 'not a dir' > "$E2E/scratch-is-a-file"
GC_JSONL_EXPORT_TMP_DIR="$E2E/scratch-is-a-file/sub" run_export 201 201
[ "$RC" != "0" ] && case "$OUT" in *"cannot create the scratch dir"*) true ;; *) false ;; esac \
  && ok "scratch dir not creatable: exits non-zero and names the scratch dir" \
  || bad "scratch dir not creatable: rc=$RC, want non-zero with 'cannot create the scratch dir'. Output: $OUT"
[ "$(head_rows)" = "200" ] && [ "$(commits)" = "$BASE_COMMITS" ] && [ -z "$(stray_in "$ARCH")" ] \
  && ok "scratch dir not creatable: archive untouched (HEAD still 200 rows, no new commit, nothing written inside)" \
  || bad "scratch dir not creatable: head=$(head_rows) commits $BASE_COMMITS -> $(commits) stray=$(stray_in "$ARCH" | tr '\n' ' ')"

# ── ga-iqsy9c7: a run killed at the order's timeout leaves a line in the log, and its scratch is gone before the NEXT run starts ──
# 27/10: the 840 s timeout SIGKILLed three exports in a row while hq.comments was being read; no trap runs on a SIGKILL, nothing was in the log, and each run left ~830 MB of scratch that only the 4 h age sweep took.
# The kill is the same simulated one as above (STUB_KILL_SELF = a real SIGKILL of the exporter). Dead and live pids are real ones: a pid that has exited, and a background `sleep` that is still running.
echo "=== ga-iqsy9c7: a killed run is named in the log and its scratch is swept by the next run ==="
IQ_LOG="$E2E/city/.gc/logs/jsonl-export.log"
iq_reset() { mkdir -p "$(dirname "$IQ_LOG")"; : > "$IQ_LOG"; }
# vazio → the count is 0 (grep -c prints 0); falhou (log unreadable) → prints nothing, which no "= N" assertion accepts
iq_count() { grep -c -e "$1" "$IQ_LOG" 2>/dev/null || true; }
# line number of the LAST line matching $1; vazio/falhou → "none"
iq_last_line() { local n; n=$(grep -n -e "$1" "$IQ_LOG" 2>/dev/null | tail -n 1 | cut -d: -f1); echo "${n:-none}"; }
# vazio → no streak in the state ("none"); falhou/ilegível (no state file, or jq cannot read it) → "?"
iq_streak() { local f="$E2E_STATE/jsonl-export-state.json"; [ -e "$f" ] || { echo "?"; return 0; }; jq -r '.consecutive_deaths // "none"' "$f" 2>/dev/null || echo "?"; }
iq_marker() { [ -e "$E2E_STATE/jsonl-export-inflight" ] && echo present || echo none; }
# vazio → no nudge in THIS run's gc calls (0); falhou (no gc log) → prints nothing, which no "= N" assertion accepts
iq_nudges() { grep -c 'session nudge deacon/' "$E2E/gc.log" 2>/dev/null || true; }
# a pid that has exited and been reaped (a foreground child), never a made-up number
iq_dead_pid() { bash -c 'echo $$'; }

# Case 1 — the real sequence: SIGKILL mid-export → start with no end in the log; the next run names the death, deletes the dead run's scratch BEFORE it starts, and exports.
scratch_archive iq-dead; iq_reset
run_export 200 200
BASE_COMMITS=$(commits)
export STUB_KILL_SELF=1
run_export 201 201
unset STUB_KILL_SELF
KILLED_RC=$RC
KILLED_FILE="$(stray_in "$E2E_TMPD" | head -n 1)"
KILLED_PID="$(printf '%s\n' "$KILLED_FILE" | sed -n 's/.*\.jsonl\.tmp\.p\([0-9][0-9]*\)\..*/\1/p')"
{ [ "$KILLED_RC" != "0" ] && [ -n "$KILLED_PID" ] && ! kill -0 "$KILLED_PID" 2>/dev/null; } \
  && ok "dead run: SIGKILLed mid-export (rc=$KILLED_RC), left a scratch file named with its own pid ($KILLED_PID), which no longer answers" \
  || bad "test setup invalid: rc=$KILLED_RC scratch='$KILLED_FILE' pid='$KILLED_PID' (want a death, a pid-named scratch file and a pid that no longer answers): $OUT"
{ [ "$(tail -n 1 "$IQ_LOG" | sed -n 's/.* start pid=\([0-9]*\)$/\1/p')" = "$KILLED_PID" ] && [ "$(iq_count ' start pid=')" = "2" ] && [ "$(iq_count ' end ')" = "1" ]; } \
  && ok "dead run: the log shows its start with no end (2 starts, 1 end, the last line is the start of pid $KILLED_PID)" \
  || bad "dead run: the log should end with 'start pid=$KILLED_PID' and hold 2 starts / 1 end, holds: $(tr '\n' '|' < "$IQ_LOG")"
[ "$(iq_marker)" = "present" ] \
  && ok "dead run: its inflight marker stayed (no trap runs on a SIGKILL) — that is how the next run knows" \
  || bad "dead run: no inflight marker after the kill"
[ -e "$KILLED_FILE" ] || bad "test setup invalid: the killed run's scratch file '$KILLED_FILE' is not there before the next run"
run_export 201 201
[ ! -e "$KILLED_FILE" ] && [ -z "$(ls -A "$E2E_TMPD" 2>/dev/null)" ] \
  && ok "dead run: the next run deleted its scratch (seconds old, not 4 h) — the scratch dir is empty" \
  || bad "dead run: the next run left in the scratch dir: $(ls -A "$E2E_TMPD" | tr '\n' ' ')"
case "$OUT" in
  *"swept 1 scratch file(s)"*) ok "dead run: the next run says on stdout what it swept" ;;
  *) bad "dead run: no 'swept 1 scratch file(s)' in the next run's output: $OUT" ;;
esac
{ [ "$(iq_count "DIED .*(pid $KILLED_PID) never finished.*; 1 in a row")" = "1" ] && [ "$(iq_count ' swept 1 scratch')" = "1" ]; } \
  && ok "dead run: the log has ONE 'DIED ... (pid $KILLED_PID) ... 1 in a row' line and the sweep line" \
  || bad "dead run: the log lacks the DIED / swept lines: $(tr '\n' '|' < "$IQ_LOG")"
# the sweep is decided before the run starts: its line sits above the new run's start line
{ [ "$(iq_last_line ' swept 1 scratch')" != "none" ] && [ "$(iq_last_line ' swept 1 scratch')" -lt "$(iq_last_line ' start pid=')" ]; } \
  && ok "dead run: the sweep is logged BEFORE the new run's start (it does not wait for the export)" \
  || bad "dead run: swept at line $(iq_last_line ' swept 1 scratch'), the new start at line $(iq_last_line ' start pid='): $(tr '\n' '|' < "$IQ_LOG")"
{ [ "$(head_rows)" = "201" ] && [ "$(commits)" = "$((BASE_COMMITS + 1))" ]; } \
  && ok "dead run: the next run still exports (201 rows, one new commit)" \
  || bad "dead run: head=$(head_rows) commits $BASE_COMMITS -> $(commits) (rc=$RC): $OUT"
{ [ "$(iq_marker)" = "none" ] && [ "$(iq_streak)" = "none" ] && [ "$(tail -n 1 "$IQ_LOG" | grep -c ' end rc=0 after ')" = "1" ]; } \
  && ok "dead run: a run that finishes removes its marker, clears the streak and logs 'end rc=0'" \
  || bad "dead run: marker=$(iq_marker) streak=$(iq_streak) last log line='$(tail -n 1 "$IQ_LOG")'"

# Case 2 — the streak: each run killed after a killed run adds one; at the 3rd the deacon is told ONCE; a run that finishes clears it.
scratch_archive iq-streak; iq_reset
run_export 200 200
export STUB_KILL_SELF=1
run_export 201 201   # killed, nothing before it to name
{ [ "$(iq_streak)" = "none" ] && [ "$(iq_count ' DIED ')" = "0" ]; } \
  && ok "streak: the first kill is not yet known to anyone (no DIED, no count)" \
  || bad "streak: after the first kill streak=$(iq_streak) DIED=$(iq_count ' DIED '): $(tr '\n' '|' < "$IQ_LOG")"
run_export 201 201   # killed; names the first death
{ [ "$(iq_streak)" = "1" ] && [ "$(iq_count '; 1 in a row')" = "1" ] && [ "$(iq_nudges)" = "0" ]; } \
  && ok "streak: the 2nd run finds the 1st dead — 1 in a row, nobody nudged" \
  || bad "streak: after 2 kills streak=$(iq_streak) '1 in a row'=$(iq_count '; 1 in a row') nudges=$(iq_nudges)"
run_export 201 201
{ [ "$(iq_streak)" = "2" ] && [ "$(iq_nudges)" = "0" ]; } \
  && ok "streak: 2 in a row, nobody nudged" \
  || bad "streak: after 3 kills streak=$(iq_streak) nudges=$(iq_nudges), want 2 and 0"
run_export 201 201
{ [ "$(iq_streak)" = "3" ] && [ "$(iq_nudges)" = "1" ]; } \
  && ok "streak: 3 in a row — the deacon is nudged once" \
  || bad "streak: after 4 kills streak=$(iq_streak) nudges=$(iq_nudges) (this run's gc calls), want 3 and 1: $(tr '\n' '|' < "$E2E/gc.log")"
run_export 201 201
{ [ "$(iq_streak)" = "4" ] && [ "$(iq_nudges)" = "0" ]; } \
  && ok "streak: the 4th in a row is counted but the deacon is not nudged again" \
  || bad "streak: after 5 kills streak=$(iq_streak) nudges=$(iq_nudges), want 4 and 0"
unset STUB_KILL_SELF
run_export 201 201
{ [ "$RC" = "0" ] && [ "$(iq_streak)" = "none" ] && [ "$(iq_count '; 5 in a row')" = "1" ] && [ "$(head_rows)" = "201" ]; } \
  && ok "streak: the run that finishes names the 5th death, exports, and clears the streak" \
  || bad "streak: rc=$RC streak=$(iq_streak) head=$(head_rows): $(tail -n 5 "$IQ_LOG" | tr '\n' '|')"

# Case 3 — a live run's scratch stays, a dead run's goes, the age net still takes what is old whatever its name says, and what is not scratch is not touched.
scratch_archive iq-live; iq_reset
mkdir -p "$E2E_TMPD"
sleep 120 & LIVE_PID=$!
DEAD_PID="$(iq_dead_pid)"
printf 'live' > "$E2E_TMPD/comments.jsonl.tmp.p$LIVE_PID.LIVE01"; printf 'live' > "$E2E_TMPD/comments.jsonl.tmp.p$LIVE_PID.LIVE01.rows"
printf 'dead' > "$E2E_TMPD/comments.jsonl.tmp.p$DEAD_PID.DEAD01"; printf 'dead' > "$E2E_TMPD/comments.jsonl.tmp.p$DEAD_PID.DEAD01.rows"
printf 'old'  > "$E2E_TMPD/labels.jsonl.tmp.p$LIVE_PID.OLD001"; touch -t 200001010000 "$E2E_TMPD/labels.jsonl.tmp.p$LIVE_PID.OLD001"
printf 'new, no pid in the name' > "$E2E_TMPD/config.jsonl.tmp.NOPID1"
printf 'not scratch' > "$E2E_TMPD/notes.txt"
run_export 200 200
[ -e "$E2E_TMPD/comments.jsonl.tmp.p$LIVE_PID.LIVE01" ] && [ -e "$E2E_TMPD/comments.jsonl.tmp.p$LIVE_PID.LIVE01.rows" ] \
  && ok "live pid: the scratch of a process that is still running stays (file and sidecar)" \
  || bad "live pid: a live run's scratch was deleted: $(ls -A "$E2E_TMPD" | tr '\n' ' ')"
[ ! -e "$E2E_TMPD/comments.jsonl.tmp.p$DEAD_PID.DEAD01" ] && [ ! -e "$E2E_TMPD/comments.jsonl.tmp.p$DEAD_PID.DEAD01.rows" ] \
  && ok "dead pid: the scratch of a pid that has exited is deleted at once (file and sidecar), fresh as it is" \
  || bad "dead pid: still there: $(ls -A "$E2E_TMPD" | tr '\n' ' ')"
[ ! -e "$E2E_TMPD/labels.jsonl.tmp.p$LIVE_PID.OLD001" ] \
  && ok "age net: a file older than the sweep age goes even when its pid answers (the pid may have been reused)" \
  || bad "age net: the 2000-dated file with a live pid is still there"
[ -e "$E2E_TMPD/config.jsonl.tmp.NOPID1" ] && [ -e "$E2E_TMPD/notes.txt" ] \
  && ok "no pid in the name / not a scratch name: fresh files stay (the age rule alone decides, and it is not old)" \
  || bad "a fresh no-pid file or a non-scratch file was deleted: $(ls -A "$E2E_TMPD" | tr '\n' ' ')"
case "$OUT" in
  *"swept 3 scratch file(s)"*) ok "sweep: the run says it swept 3 files (the dead pid's file and sidecar, and the old one)" ;;
  *) bad "sweep: no 'swept 3 scratch file(s)' line in the output: $OUT" ;;
esac
kill "$LIVE_PID" 2>/dev/null || true; wait "$LIVE_PID" 2>/dev/null || true

# Case 4 — a marker that proves nothing counts nothing: garbage (a write cut short by a full disk) → WARN; a pid that still answers → WARN (a second export beside it), not a death.
scratch_archive iq-marker; iq_reset
run_export 200 200
printf 'garbage' > "$E2E_STATE/jsonl-export-inflight"
iq_reset
run_export 201 201
{ [ "$(iq_count ' WARN the marker .* is unreadable')" = "1" ] && [ "$(iq_count ' DIED ')" = "0" ] && [ "$(iq_streak)" = "none" ]; } \
  && ok "garbled marker: logs a WARN and counts no death" \
  || bad "garbled marker: WARN=$(iq_count ' WARN the marker') DIED=$(iq_count ' DIED ') streak=$(iq_streak): $(tr '\n' '|' < "$IQ_LOG")"
[ "$(iq_marker)" = "none" ] \
  && ok "garbled marker: replaced by this run's own and removed when it ends" \
  || bad "garbled marker: a marker is still there after the run"
sleep 120 & LIVE_PID=$!
printf '%s 1\n' "$LIVE_PID" > "$E2E_STATE/jsonl-export-inflight"
iq_reset
run_export 202 202
{ [ "$(iq_count " WARN the run pid=$LIVE_PID .* still going")" = "1" ] && [ "$(iq_count ' DIED ')" = "0" ] && [ "$(iq_streak)" = "none" ] && [ "$(head_rows)" = "202" ]; } \
  && ok "marker of a live pid: WARN 'still going', no death counted, the export goes on" \
  || bad "marker of a live pid: WARN=$(iq_count ' WARN the run pid=') DIED=$(iq_count ' DIED ') streak=$(iq_streak) head=$(head_rows): $(tr '\n' '|' < "$IQ_LOG")"
kill "$LIVE_PID" 2>/dev/null || true; wait "$LIVE_PID" 2>/dev/null || true
printf '%s 1\n' "$(iq_dead_pid)" > "$E2E_STATE/jsonl-export-inflight"
printf '{"consecutive_deaths":"many","sentinel_key":"kept"}\n' > "$E2E_STATE/jsonl-export-state.json"
iq_reset
run_export 203 203
{ [ "$(iq_count ' DIED .*the count in the state is unreadable')" = "1" ] && [ "$(jq -r '.sentinel_key // "gone"' "$E2E_STATE/jsonl-export-state.json")" = "kept" ]; } \
  && ok "dead pid, unreadable count in the state: the death is said, no count is invented, the rest of the state stays" \
  || bad "dead pid, unreadable count: $(tr '\n' '|' < "$IQ_LOG") state=$(jq -c . "$E2E_STATE/jsonl-export-state.json" 2>&1)"

# Case 5 — a run that finishes clears a streak and keeps the rest of the state.
scratch_archive iq-reset; iq_reset
run_export 200 200
jq -c '.consecutive_deaths = 2 | .sentinel_key = "kept"' "$E2E_STATE/jsonl-export-state.json" > "$E2E_STATE/s.tmp" && mv "$E2E_STATE/s.tmp" "$E2E_STATE/jsonl-export-state.json"
run_export 200 200
{ [ "$(iq_streak)" = "none" ] && [ "$(jq -r '.sentinel_key // "gone"' "$E2E_STATE/jsonl-export-state.json")" = "kept" ]; } \
  && ok "reset: a finished run clears consecutive_deaths and keeps the other keys of the state" \
  || bad "reset: streak=$(iq_streak) state=$(jq -c . "$E2E_STATE/jsonl-export-state.json" 2>&1)"

# Case 6 — nothing the run makes is left in the scratch dir, and the scrubbed copy of the issues (70 MB at hq) no longer sits in $TMPDIR: with a TMPDIR nobody can write to the run still exports.
# (GNU mktemp on the node honors TMPDIR and fails in an unwritable one; BSD mktemp on the mini ignores TMPDIR when it is given no template. So the case tells the old code from the new on the node, and on the mini — or as root, where
# the chmod blocks nothing — it only repeats the clean run.)
scratch_archive iq-clean; iq_reset
mkdir -p "$E2E/ro-tmpdir"; chmod 555 "$E2E/ro-tmpdir"
TMPDIR="$E2E/ro-tmpdir" run_export 200 200 5
chmod 755 "$E2E/ro-tmpdir"
{ [ "$RC" = "0" ] && [ "$(head_rows)" = "200" ] && [ -z "$(ls -A "$E2E_TMPD" 2>/dev/null)" ] && [ -z "$(ls -A "$E2E/ro-tmpdir" 2>/dev/null)" ]; } \
  && ok "clean run, 5 scrubbed rows, TMPDIR unwritable: exports (200 rows), both dirs end empty — the scrub's temp file is in the scratch dir, not in TMPDIR" \
  || bad "clean run with an unwritable TMPDIR: rc=$RC head=$(head_rows) scratch=$(ls -A "$E2E_TMPD" 2>/dev/null | tr '\n' ' '): $OUT"
{ [ "$(iq_count ' start pid=')" = "1" ] && [ "$(iq_count ' end rc=0 after ')" = "1" ] && [ "$(iq_marker)" = "none" ]; } \
  && ok "clean run: one start and one 'end rc=0' in the log, no marker left" \
  || bad "clean run: start=$(iq_count ' start pid=') end=$(iq_count ' end rc=0') marker=$(iq_marker): $(tr '\n' '|' < "$IQ_LOG")"
unset GC_JSONL_EXPORT_TMP_DIR

# ── ga-l6v576: comments, config, dependencies, labels and metadata are read whole and checked against the source, like issues ──
# They were exported with `dolt_sql ... > file 2>/dev/null || true`: no row count, no exit code, no stderr. Dolt cuts a read that runs past ~40 s — a well-formed document, exit 0, "unexpected EOF" on
# stderr — and hq.comments (36.9k rows) came out at a multiple of 128 rows in 29 of 37 snapshots (live: 11,776 of 36,930); the gate on issues never looked at it, and the hourly manifest said `ok`.
# The stub models that cut (STUB_READ_CAP), so what these cases pin is the cure — read the table in pages that fit — and the gate behind it: a table that still comes up short is never the snapshot.
echo "=== ga-l6v576: a supplemental table cut short is never the snapshot ==="
SUPP_TABLES_ALL="comments config dependencies labels metadata"
# vazio → the table has no rows (0); falhou (file missing, not JSON) → prints "?", which no assertion below accepts
supp_file_rows() { jq -s -r 'if length == 0 then 0 else ((.[0].rows // []) | length) end' "$ARCH/wa/$1.jsonl" 2>/dev/null || echo "?"; }
# same three states for the table's blob in the archive's HEAD (no such blob → "?", never 0)
supp_head_rows() {
  local blob
  blob=$(git -C "$ARCH" show "HEAD:wa/$1.jsonl" 2>/dev/null) || { echo "?"; return 0; }
  printf '%s\n' "$blob" | jq -s -r 'if length == 0 then 0 else ((.[0].rows // []) | length) end' 2>/dev/null || echo "?"
}
export E2E_READ_LOG="$E2E/reads.log" E2E_FLAKY_DIR="$E2E/flaky" GC_JSONL_SUPP_EXPORT_RETRY_DELAY=0
mkdir -p "$E2E_FLAKY_DIR"
reset_reads() { : > "$E2E_READ_LOG"; rm -f "$E2E_FLAKY_DIR"/*; }   # the read log and the stub's flaky counters belong to one run
attempts_of() { grep -Ec "^READ $1 rows [a-z0-9]+ (-|off=0)$" "$E2E_READ_LOG" 2>/dev/null || true; }   # reads of rows of <table> that started from the top, no cursor = attempts at the whole table
supp_env_reset() {
  local x
  unset STUB_READ_CAP STUB_PK GC_JSONL_SUPP_CHUNK_ROWS GC_JSONL_SUPP_KEY_CHUNK_ROWS
  for x in $SUPP_TABLES_ALL; do
    unset "STUB_ROWS_$x" "STUB_COUNT_$x" "STUB_LOSE_$x" "STUB_FLAKY_$x" "STUB_FAIL_$x" "STUB_GARBAGE_$x" "STUB_ODD_$x" "STUB_KEYS_FAIL_$x" "STUB_CHURN_$x" "STUB_SKIP_$x" "STUB_DUP_$x" "STUB_STUCK_$x" "STUB_EMPTYCUT_$x"
  done
  unset STUB_GIT_BLIND
}
supp_env_reset

# Case 1 — the cause: no single read can return 384 rows (3 x 128), every table is bigger than that but config/metadata. The file must hold what the source holds.
fresh_archive supp-paged
export STUB_READ_CAP=384 GC_JSONL_SUPP_CHUNK_ROWS=100
export STUB_ROWS_comments=1000 STUB_ROWS_labels=2500 STUB_ROWS_dependencies=500 STUB_ROWS_config=11 STUB_ROWS_metadata=2
reset_reads
run_export 200 200
for t in $SUPP_TABLES_ALL; do
  v="STUB_ROWS_$t"; want="${!v}"
  [ "$(supp_file_rows "$t")" = "$want" ] && [ "$(supp_head_rows "$t")" = "$want" ] \
    && ok "paged read: wa/$t.jsonl holds all $want rows of the source (file and archive HEAD)" \
    || bad "paged read: wa/$t.jsonl holds $(supp_file_rows "$t") rows (HEAD $(supp_head_rows "$t")), want $want — one read is cut at 384 rows and the cut table became the snapshot"
done
case "$OUT" in
  *"failed:"*|*"partial="*) bad "paged read: a table the paging reads whole is reported as failed: $OUT" ;;
  *) ok "paged read: a complete export reports no failed table" ;;
esac
# vazio → the scratch dir holds nothing after a clean run; falhou (cannot list it) → the text is "?", never empty
[ -z "$(ls -A "$(dirname "$ARCH")/.jsonl-export-tmp" 2>/dev/null || echo '?')" ] \
  && ok "paged read: the pages are cleaned out of the scratch dir" \
  || bad "paged read: the scratch dir keeps: $(ls -A "$(dirname "$ARCH")/.jsonl-export-tmp" | tr '\n' ' ')"
supp_env_reset

# Case 2 — the whole CLASS: a table that comes up 256 rows (2 x 128) short however it is read is NOT the snapshot — for each of the five. The previous version stays, the DB is reported
# as failed with the table named, the retry is bounded, and the verified issues of the same run are still committed.
for t in $SUPP_TABLES_ALL; do
  fresh_archive "supp-short-$t"
  export "STUB_ROWS_$t=600" GC_JSONL_SUPP_CHUNK_ROWS=100
  run_export 200 200
  [ "$(supp_file_rows "$t")" = "600" ] || bad "test setup invalid: the baseline $t holds $(supp_file_rows "$t") rows, want 600: $OUT"
  BASE_COMMITS=$(commits)
  export "STUB_LOSE_$t=256"
  reset_reads
  run_export 201 201
  [ "$(supp_file_rows "$t")" = "600" ] && [ "$(supp_head_rows "$t")" = "600" ] \
    && ok "short $t: the previous 600-row version stays (file and HEAD)" \
    || bad "short $t: file holds $(supp_file_rows "$t") rows, HEAD $(supp_head_rows "$t"), want 600 — the table 256 rows short became the snapshot"
  case "$OUT" in
    *"export curto de wa.$t: "*"mantido o snapshot anterior"*) ok "short $t: logs 'export curto de wa.$t', previous kept" ;;
    *) bad "short $t: no 'export curto de wa.$t ... mantido o snapshot anterior' line. Output: $OUT" ;;
  esac
  case "$OUT" in
    *"failed: wa($t)"*) ok "short $t: the run summary lists 'failed: wa($t)'" ;;
    *) bad "short $t: the run summary does not name the failed table 'wa($t)'. Output: $OUT" ;;
  esac
  grep -q "DOG_DONE:.*wa($t)" "$E2E/gc.log" \
    && ok "short $t: the DOG_DONE nudge names wa($t)" \
    || bad "short $t: DOG_DONE nudge does not name wa($t). gc log: $(cat "$E2E/gc.log")"
  [ "$(head_rows)" = "201" ] && [ "$(commits)" = "$((BASE_COMMITS + 1))" ] \
    && ok "short $t: the verified issues still commit (201 rows, one new commit)" \
    || bad "short $t: issues head=$(head_rows) commits $BASE_COMMITS -> $(commits), want 201 rows and +1 commit — a short $t held the whole DB back"
  git -C "$ARCH" log -1 --format=%s | grep -q "partial=wa($t)" \
    && ok "short $t: the archive commit message records partial=wa($t)" \
    || bad "short $t: commit message lacks partial=wa($t): $(git -C "$ARCH" log -1 --format=%s)"
  n=$(attempts_of "$t")
  [ "$n" -ge 2 ] && [ "$n" -le 5 ] \
    && ok "short $t: read $n times — retried, and bounded" \
    || bad "short $t: $n attempts at the whole table, want 2..5 (retried, not forever)"
  [ -z "$(git -C "$ARCH" status --porcelain)" ] && [ "$RC" = "0" ] \
    && ok "short $t: exit 0, archive working tree clean" \
    || bad "short $t: rc=$RC, tree: $(git -C "$ARCH" status --porcelain | tr '\n' ' ')"
  supp_env_reset
done

# Case 3 — no previous version to keep (the first run of a DB): the short table is not written at all, and not committed.
fresh_archive supp-short-first
export STUB_ROWS_comments=600 STUB_LOSE_comments=256 GC_JSONL_SUPP_CHUNK_ROWS=100
run_export 200 200
{ [ ! -e "$ARCH/wa/comments.jsonl" ] && ! git -C "$ARCH" cat-file -e HEAD:wa/comments.jsonl 2>/dev/null; } \
  && ok "short, first run: a table with no previous version is left out — no truncated file in the working tree or HEAD" \
  || bad "short, first run: wa/comments.jsonl exists (file: $(supp_file_rows comments) rows, HEAD: $(supp_head_rows comments))"
[ "$(head_rows)" = "200" ] && case "$OUT" in *"failed: wa(comments)"*) true ;; *) false ;; esac \
  && ok "short, first run: the issues commit, and wa(comments) is reported failed" \
  || bad "short, first run: issues head=$(head_rows); output: $OUT"
supp_env_reset

# Case 4 — a transient cut heals on the retry: the first read of the table is 128 rows short, the second is whole. No failed table, the full table archived.
fresh_archive supp-flaky
export STUB_ROWS_comments=600 STUB_FLAKY_comments=1 GC_JSONL_SUPP_CHUNK_ROWS=100
reset_reads
run_export 200 200
[ "$(supp_file_rows comments)" = "600" ] \
  && ok "flaky read: the retry archives the whole table (600 rows)" \
  || bad "flaky read: comments holds $(supp_file_rows comments) rows, want 600 — the first, cut read became the snapshot"
[ "$(attempts_of comments)" = "2" ] \
  && ok "flaky read: exactly one retry (2 attempts)" \
  || bad "flaky read: $(attempts_of comments) attempts, want 2"
case "$OUT" in
  *"failed:"*|*"partial="*) bad "flaky read: a table the retry healed is reported as failed: $OUT" ;;
  *) ok "flaky read: healed by the retry, nothing reported failed" ;;
esac
supp_env_reset

# Case 5 — the read itself fails (exit 1 with part of the document on stdout): not a snapshot, and Dolt's own stderr reaches the log instead of /dev/null.
fresh_archive supp-readfail
export STUB_ROWS_comments=600 GC_JSONL_SUPP_CHUNK_ROWS=100
run_export 200 200
export STUB_FAIL_comments=1
run_export 201 201
[ "$(supp_file_rows comments)" = "600" ] && [ "$(supp_head_rows comments)" = "600" ] \
  && ok "failing read: the previous 600-row version stays (the 10-row fragment is not archived)" \
  || bad "failing read: comments holds $(supp_file_rows comments) rows (HEAD $(supp_head_rows comments)), want 600"
case "$OUT" in
  *"connection reset by peer"*) ok "failing read: Dolt's stderr is in the log (not swallowed)" ;;
  *) bad "failing read: Dolt's stderr ('connection reset by peer') is nowhere in the output: $OUT" ;;
esac
case "$OUT" in
  *"failed: wa(comments)"*) ok "failing read: the run summary lists 'failed: wa(comments)'" ;;
  *) bad "failing read: the run summary does not name wa(comments). Output: $OUT" ;;
esac
supp_env_reset

# Case 5b — dolt exits 0 but what it printed is not a JSON document (cut off mid-string, or nothing at all): the same as a failing read — the previous version stays, the run
# is reported failed, and the log says the document was unreadable. An empty page is not "a table with no rows" (Dolt prints {} for that).
for garbage in doc empty; do
  fresh_archive "supp-garbage-$garbage"
  export STUB_ROWS_comments=600 GC_JSONL_SUPP_CHUNK_ROWS=100
  run_export 200 200
  export "STUB_GARBAGE_comments=$garbage"
  run_export 201 201
  [ "$(supp_file_rows comments)" = "600" ] && [ "$(supp_head_rows comments)" = "600" ] \
    && ok "unreadable document ($garbage, rc 0): the previous 600-row version stays" \
    || bad "unreadable document ($garbage, rc 0): comments holds $(supp_file_rows comments) rows (HEAD $(supp_head_rows comments)), want 600"
  case "$OUT" in
    *"returned an unreadable document"*) ok "unreadable document ($garbage, rc 0): the log names the unreadable document" ;;
    *) bad "unreadable document ($garbage, rc 0): the log does not say the document was unreadable: $OUT" ;;
  esac
  case "$OUT" in
    *"failed: wa(comments)"*) ok "unreadable document ($garbage, rc 0): the run summary lists 'failed: wa(comments)'" ;;
    *) bad "unreadable document ($garbage, rc 0): the run summary does not name wa(comments). Output: $OUT" ;;
  esac
  supp_env_reset
done

# Case 5c — git cannot say whether the previous version of a short table exists (cat-file / ls-tree fail). The table must NOT be dropped from the snapshot on that guess: the DB is
# discarded this run (nothing committed, HEAD keeps all 600 comments) and reported failed.
fresh_archive supp-gitblind
export STUB_ROWS_comments=600 GC_JSONL_SUPP_CHUNK_ROWS=100
run_export 200 200
GB_COMMITS=$(git -C "$ARCH" rev-list --count HEAD)
export STUB_ROWS_comments=700 STUB_LOSE_comments=50 STUB_GIT_BLIND=1
run_export 201 201
[ "$(supp_head_rows comments)" = "600" ] \
  && ok "git cannot read the tree: HEAD still holds the 600-row comments (the table was not dropped from the snapshot)" \
  || bad "git cannot read the tree: HEAD holds $(supp_head_rows comments) comment rows, want 600 — a failed git read was taken for 'no previous version'"
[ "$(git -C "$ARCH" rev-list --count HEAD)" = "$GB_COMMITS" ] \
  && ok "git cannot read the tree: no commit was made for the DB" \
  || bad "git cannot read the tree: a commit was made ($(git -C "$ARCH" rev-list --count HEAD) vs $GB_COMMITS)"
case "$OUT" in
  *"failed: wa"*) ok "git cannot read the tree: the run summary lists 'failed: wa'" ;;
  *) bad "git cannot read the tree: the run summary does not name wa. Output: $OUT" ;;
esac
supp_env_reset

# Case 6 — the THIRD state, for a table with no key to page by: its COUNT(*) is the only check, and it is unreadable, so nobody can say whether the export is whole. Not discarded (a store
# whose count query is down must not freeze its archive), never silent: named in the log, the summary, the nudge and the commit message — the same four places as the unverified issues export.
fresh_archive supp-unverified
export STUB_ROWS_comments=600 STUB_PK=none
run_export 200 200
export STUB_ROWS_comments=700 STUB_COUNT_comments=ERR STUB_PK=none
run_export 201 201
[ "$(supp_file_rows comments)" = "700" ] \
  && ok "unreadable table count: the export is archived (700 rows), as documented for an unverifiable export" \
  || bad "unreadable table count: comments holds $(supp_file_rows comments) rows, want 700"
unverified_seen "unreadable table count (comments)"
git -C "$ARCH" log -1 --format=%s | grep -q 'unverified=wa' \
  && ok "unreadable table count: the archive commit message records unverified=wa" \
  || bad "unreadable table count: commit message lacks unverified=wa: $(git -C "$ARCH" log -1 --format=%s)"
case "$OUT" in
  *"failed:"*) bad "unreadable table count: an unverifiable table is reported FAILED, not unverified: $OUT" ;;
  *) ok "unreadable table count: reported unverified, not failed" ;;
esac
supp_env_reset

# Case 6b — a table WITH a key is judged by its keys, not by its count: a count query that is down changes nothing, and the export is verified, not flagged.
fresh_archive supp-count-down-keyed
export STUB_ROWS_comments=600 GC_JSONL_SUPP_CHUNK_ROWS=100
run_export 200 200
export STUB_ROWS_comments=700 STUB_COUNT_comments=ERR
run_export 201 201
[ "$(supp_file_rows comments)" = "700" ] \
  && ok "keyed table, count query down: the 700-row export is archived" \
  || bad "keyed table, count query down: comments holds $(supp_file_rows comments) rows, want 700"
case "$OUT" in
  *"unverified"*|*"failed:"*|*"NOT verified"*) bad "keyed table, count query down: the key check verified it, yet the run reports it: $OUT" ;;
  *) ok "keyed table, count query down: verified by keys — not unverified, not failed" ;;
esac
supp_env_reset

# Case 7 — no usable primary key to page by. A small table is read in ONE query and still checked; a table too big for one query is the cut again, and then the gate keeps the previous version.
fresh_archive supp-nopk
export STUB_ROWS_comments=50 STUB_READ_CAP=384 STUB_PK=none
reset_reads
run_export 200 200
[ "$(supp_file_rows comments)" = "50" ] && [ "$(attempts_of comments)" = "1" ] \
  && ok "no primary key, small table: read whole in one query (50 rows, 1 attempt)" \
  || bad "no primary key, small table: comments holds $(supp_file_rows comments) rows after $(attempts_of comments) attempts, want 50 after 1"
supp_env_reset
fresh_archive supp-pk-unreadable
export STUB_ROWS_comments=50 STUB_READ_CAP=384 STUB_PK=ERR
run_export 200 200
[ "$(supp_file_rows comments)" = "50" ] \
  && ok "primary key unreadable, small table: read whole in one query (50 rows)" \
  || bad "primary key unreadable, small table: comments holds $(supp_file_rows comments) rows, want 50"
supp_env_reset
fresh_archive supp-nopk-big
export STUB_ROWS_comments=700 GC_JSONL_SUPP_CHUNK_ROWS=100
run_export 200 200
export STUB_READ_CAP=384 STUB_PK=none
run_export 201 201
[ "$(supp_file_rows comments)" = "700" ] && case "$OUT" in *"failed: wa(comments)"*) true ;; *) false ;; esac \
  && ok "no primary key, table too big for one query: the cut read is gated — previous 700 rows kept, wa(comments) failed" \
  || bad "no primary key, big table: comments holds $(supp_file_rows comments) rows; output: $OUT"
supp_env_reset

# Case 8 — the verdict, alone. The read of a table is bracketed by two counts; rows deleted meanwhile lower the count AFTER the read, so a complete read is never short of the smaller of the two.
v() { lib_call table_export_verdict "$@" 2>/dev/null || echo "?"; }   # falhou (function missing) → "?", which no expected answer is
for spec in "344 600 600 short" "344 600 '' short" "344 '' 600 short" "598 600 598 complete" "600 600 600 complete" "0 0 0 complete" \
            "600 '' '' unknown" "'' 600 600 unknown" "abc 600 600 unknown" "5 600 abc short"; do
  eval "set -- $spec"; want="$4"
  got=$(v "$1" "$2" "$3")
  [ "$got" = "$want" ] && ok "table_export_verdict raw=$1 before='$2' after='$3' -> $want" || bad "table_export_verdict raw=$1 before='$2' after='$3' -> '$got', want $want"
done
unset -f v

# ── ga-l6v576, attempt 2: a table read in pages is not a snapshot of a LIVE table ──
# Attempt 1 paged with LIMIT/OFFSET and judged the read by its row count. Paging a live table by offset hands out duplicates (a row inserted behind the cursor moves every later row one
# place down, so the next page serves one again) and skips (a row deleted behind it moves them up, so the next page steps over one), and the count of such a read can still equal the
# source's: "complete". The read now pages by KEY (WHERE key > last) and is judged by keys: every row that was in the table before the read AND still is after it must be in the file.
# The cases below change the table BETWEEN pages and then read the FILE: no key twice, no row that was there the whole time lost.
echo "=== ga-l6v576: a table read in pages while other writers change it ==="
# vazio → no key twice (0); falhou (the file is missing or not JSON) → "?", which no assertion below accepts
supp_dup_keys() {  # supp_dup_keys <t> [jq key expression, default .id] — how many keys the file holds more than once
  local keys
  keys=$(jq -r ".rows[]? | ${2:-.id}" "$ARCH/wa/$1.jsonl" 2>/dev/null) || { echo "?"; return 0; }
  printf '%s\n' "$keys" | LC_ALL=C sort | uniq -d | grep -c . || true
}
supp_missing() {  # supp_missing <t> <n> <gone> — how many of the ids <t>-000000..<n-1> that were never deleted are not in the file; <gone> is a jq test on the row's index (false = none deleted)
  local have want
  have=$(jq -r '.rows[]? | .id' "$ARCH/wa/$1.jsonl" 2>/dev/null) || { echo "?"; return 0; }
  want=$(jq -n -r --arg t "$1" --argjson n "$2" "[range(\$n) | select((${3}) | not) | \"\\(\$t)-\\((\"000000\" + tostring)[-6:])\"] | .[]") || { echo "?"; return 0; }
  comm -13 <(printf '%s\n' "$have" | LC_ALL=C sort -u) <(printf '%s\n' "$want" | LC_ALL=C sort -u) | grep -c . || true
}
no_failed_table() {  # no_failed_table <label> — the run reports no table as failed or partial
  case "$OUT" in
    *"failed:"*|*"partial="*) bad "$1: the run reports a failed table: $OUT" ;;
    *) ok "$1: no table reported failed" ;;
  esac
}

# Case 9 — rows inserted behind the cursor (net +4: 7 in, 3 out) and, the other way, rows deleted behind it (net -4: 3 in, 7 out), between the 3rd and the 4th page of ten. By offset the
# first leaves 4 keys twice in the file, the second loses 4 rows that were in the table all along — and in both the file's row count equals the table's.
for spec in "inserted 3:7:3:0:0 '. >= 1 and . <= 3'" "deleted 3:3:7:0:0 '. >= 1 and . <= 7'"; do
  eval "set -- $spec"
  fresh_archive "supp-churn-$1"
  export STUB_ROWS_comments=1000 GC_JSONL_SUPP_CHUNK_ROWS=100 "STUB_CHURN_comments=$2"
  reset_reads
  run_export 200 200
  [ "$(supp_dup_keys comments)" = "0" ] \
    && ok "rows $1 behind the cursor: no id twice in comments.jsonl" \
    || bad "rows $1 behind the cursor: $(supp_dup_keys comments) ids are in comments.jsonl more than once — the pages overlapped"
  [ "$(supp_missing comments 1000 "$3")" = "0" ] \
    && ok "rows $1 behind the cursor: every row that was in the table the whole time is in the file" \
    || bad "rows $1 behind the cursor: $(supp_missing comments 1000 "$3") rows that were in the table the whole time are missing from the file — the pages skipped them"
  [ "$(supp_file_rows comments)" = "1000" ] \
    && ok "rows $1 behind the cursor: the file holds the 1000 rows the read went through" \
    || bad "rows $1 behind the cursor: the file holds $(supp_file_rows comments) rows, want 1000"
  no_failed_table "rows $1 behind the cursor"
  [ "$(attempts_of comments)" = "1" ] \
    && ok "rows $1 behind the cursor: read once, no retry" \
    || bad "rows $1 behind the cursor: $(attempts_of comments) attempts at the table, want 1"
  supp_env_reset
done

# Case 10 — the table loses its last 5 rows and gets 5 new ones at the front, after the 3rd page: the read holds 995 rows, the table 1000. A gate that compares COUNTS calls this read short
# (995 < 1000) and throws a whole table away; by keys it is whole — the 995 rows that were in the table before and after are all in the file.
fresh_archive supp-churn-ahead
export STUB_ROWS_comments=1000 GC_JSONL_SUPP_CHUNK_ROWS=100 STUB_CHURN_comments=3:5:0:0:5
reset_reads
run_export 200 200
[ "$(supp_file_rows comments)" = "995" ] && [ "$(supp_dup_keys comments)" = "0" ] && [ "$(supp_missing comments 995 false)" = "0" ] \
  && ok "rows added behind the cursor, rows lost ahead of it: the 995 rows read are in the file once each" \
  || bad "rows added behind, lost ahead: the file holds $(supp_file_rows comments) rows, $(supp_dup_keys comments) ids twice, $(supp_missing comments 995 false) stable ids missing"
no_failed_table "rows added behind the cursor, rows lost ahead of it"
supp_env_reset

# Case 11 — a silent loss that the table's own growth hides. After page 3, 5 rows are added at the END of the table, and in every attempt page 5 comes back without 5 of its middle rows
# (the cursor moves on past them). The file holds 1000 rows and the table 1000 before and 1005 after, so a COUNT gate calls it complete; the 5 rows that were in the table all along and
# are not in the file are what the key gate sees. The previous version (900 rows) stays.
fresh_archive supp-skip-masked
export STUB_ROWS_comments=900 GC_JSONL_SUPP_CHUNK_ROWS=100
run_export 200 200
[ "$(supp_file_rows comments)" = "900" ] || bad "test setup invalid: the baseline comments holds $(supp_file_rows comments) rows, want 900: $OUT"
export STUB_ROWS_comments=1000 STUB_CHURN_comments=3:0:0:5:0 STUB_SKIP_comments=5:5
reset_reads
run_export 201 201
[ "$(supp_file_rows comments)" = "900" ] && [ "$(supp_head_rows comments)" = "900" ] \
  && ok "5 rows lost in a page while the table grows by 5: the previous 900-row version stays (file and HEAD)" \
  || bad "5 rows lost in a page while the table grows by 5: comments holds $(supp_file_rows comments) rows (HEAD $(supp_head_rows comments)), want 900 — a count that equals the table's passed a read that lost rows"
case "$OUT" in
  *"export curto de wa.comments: "*"(tentativa 1/2)"*) ok "5 rows lost in a page while the table grows by 5: logs 'export curto de wa.comments' (tentativa 1/2)" ;;
  *) bad "5 rows lost in a page while the table grows by 5: no 'export curto de wa.comments ... (tentativa 1/2)' line. Output: $OUT" ;;
esac
case "$OUT" in
  *"failed: wa(comments)"*) ok "5 rows lost in a page while the table grows by 5: the run summary lists 'failed: wa(comments)'" ;;
  *) bad "5 rows lost in a page while the table grows by 5: the run summary does not name wa(comments). Output: $OUT" ;;
esac
supp_env_reset

# Case 12 — the server hands out a row it already gave (the 3rd page of an attempt starts with the row the cursor stands on). Whatever the count says, a key twice in the
# read is not a snapshot of the table: the read fails, the previous version stays, and the log names it.
fresh_archive supp-dup
export STUB_ROWS_comments=600 GC_JSONL_SUPP_CHUNK_ROWS=100
run_export 200 200
export STUB_ROWS_comments=700 STUB_DUP_comments=3
run_export 201 201
[ "$(supp_file_rows comments)" = "600" ] && [ "$(supp_head_rows comments)" = "600" ] \
  && ok "a key served twice: the previous 600-row version stays (file and HEAD)" \
  || bad "a key served twice: comments holds $(supp_file_rows comments) rows (HEAD $(supp_head_rows comments)), want 600 — the read with a repeated row became the snapshot"
case "$OUT" in
  *"more than once"*) ok "a key served twice: the log says a key came more than once" ;;
  *) bad "a key served twice: no 'more than once' line in the output: $OUT" ;;
esac
case "$OUT" in
  *"failed: wa(comments)"*) ok "a key served twice: the run summary lists 'failed: wa(comments)'" ;;
  *) bad "a key served twice: the run summary does not name wa(comments). Output: $OUT" ;;
esac
supp_env_reset

# Case 13 — a server that ignores the cursor answers every page from the start. The read must give up on the 2nd page, not walk 5000 pages of the same 100 rows.
fresh_archive supp-stuck
export STUB_ROWS_comments=600 GC_JSONL_SUPP_CHUNK_ROWS=100
run_export 200 200
export STUB_ROWS_comments=700 STUB_STUCK_comments=1
reset_reads
run_export 201 201
[ "$(supp_file_rows comments)" = "600" ] && [ "$(supp_head_rows comments)" = "600" ] \
  && ok "a cursor that does not advance: the previous 600-row version stays (file and HEAD)" \
  || bad "a cursor that does not advance: comments holds $(supp_file_rows comments) rows (HEAD $(supp_head_rows comments)), want 600"
case "$OUT" in
  *"did not move past the cursor"*) ok "a cursor that does not advance: the log says the page did not move past the cursor" ;;
  *) bad "a cursor that does not advance: no 'did not move past the cursor' line in the output: $OUT" ;;
esac
n=$(grep -c '^READ comments rows' "$E2E_READ_LOG" 2>/dev/null || true)
[ "$n" -ge 2 ] && [ "$n" -le 6 ] \
  && ok "a cursor that does not advance: given up after $n page reads (2 attempts), not walked to the page limit" \
  || bad "a cursor that does not advance: $n page reads of comments, want 2..6"
supp_env_reset

# Case 14 — a page bigger than what one query can return (chunk 1000, the store cuts at 384): every page is cut, comes back with rows and the cut's stderr line, and the next page resumes
# from the last key it got. Nothing is lost, and the cut alone does not fail the read.
fresh_archive supp-cutpages
export STUB_ROWS_comments=1000 STUB_READ_CAP=384 GC_JSONL_SUPP_CHUNK_ROWS=1000
reset_reads
run_export 200 200
[ "$(supp_file_rows comments)" = "1000" ] && [ "$(supp_dup_keys comments)" = "0" ] && [ "$(supp_missing comments 1000 false)" = "0" ] \
  && ok "pages cut by the store: the read resumes from the last key it got — all 1000 rows, once each" \
  || bad "pages cut by the store: the file holds $(supp_file_rows comments) rows, $(supp_dup_keys comments) ids twice, $(supp_missing comments 1000 false) missing — want 1000, 0, 0"
no_failed_table "pages cut by the store"
supp_env_reset

# Case 15 — a page that comes back EMPTY in the middle of the table. With the cut's stderr line it is the cut that left nothing: a failed read. Without one it looks like the end of the table,
# and the keys that were in the table before and after the read, and are not in the file, say it was not.
for mode in sig quiet; do
  fresh_archive "supp-emptycut-$mode"
  export STUB_ROWS_comments=600 GC_JSONL_SUPP_CHUNK_ROWS=100
  run_export 200 200
  export STUB_ROWS_comments=700 "STUB_EMPTYCUT_comments=3:$mode"
  run_export 201 201
  [ "$(supp_file_rows comments)" = "600" ] && [ "$(supp_head_rows comments)" = "600" ] \
    && ok "empty page in the middle ($mode): the previous 600-row version stays (file and HEAD)" \
    || bad "empty page in the middle ($mode): comments holds $(supp_file_rows comments) rows (HEAD $(supp_head_rows comments)), want 600 — a table read to page 2 of 7 became the snapshot"
  case "$OUT" in
    *"failed: wa(comments)"*) ok "empty page in the middle ($mode): the run summary lists 'failed: wa(comments)'" ;;
    *) bad "empty page in the middle ($mode): the run summary does not name wa(comments). Output: $OUT" ;;
  esac
  if [ "$mode" = sig ]; then
    case "$OUT" in
      *"came back empty"*"unexpected EOF"*) ok "empty page in the middle (sig): the log says the page came back empty and shows Dolt's line" ;;
      *) bad "empty page in the middle (sig): no 'came back empty' line with Dolt's 'unexpected EOF'. Output: $OUT" ;;
    esac
  else
    case "$OUT" in
      *"export curto de wa.comments: "*) ok "empty page in the middle (quiet): the key check calls the export short" ;;
      *) bad "empty page in the middle (quiet): no 'export curto de wa.comments' line. Output: $OUT" ;;
    esac
  fi
  supp_env_reset
done

# Case 16 — keys that need care in a cursor: a quote, a backslash, a double quote, a space, a trailing space, non-ASCII letters. With pages of 7 each of them is the last row of a page, so the
# next page is asked `WHERE (`id`) > ('<that key>')`; the stub reads the literal the way MySQL does and fails the query on a malformed one.
fresh_archive supp-oddkeys
export STUB_ROWS_comments=60 STUB_ODD_comments=1 GC_JSONL_SUPP_CHUNK_ROWS=7
reset_reads
run_export 200 200
[ "$(supp_file_rows comments)" = "66" ] && [ "$(supp_dup_keys comments)" = "0" ] \
  && ok "awkward keys as cursors: all 66 rows, once each" \
  || bad "awkward keys as cursors: the file holds $(supp_file_rows comments) rows, $(supp_dup_keys comments) ids twice, want 66 and 0 (output: $OUT)"
no_failed_table "awkward keys as cursors"
[ "$(attempts_of comments)" = "1" ] \
  && ok "awkward keys as cursors: read once" \
  || bad "awkward keys as cursors: $(attempts_of comments) attempts, want 1"
for lit in "'comments-000012''q'" "'comments-000018\\\\b'" "'comments-000024\"d'" "'comments-000030 sp'" "'comments-000036 '" "'comments-000042éñ'"; do
  grep -qF "after=($lit)" "$E2E_READ_LOG" \
    && ok "awkward keys as cursors: a page was asked after the literal $lit" \
    || bad "awkward keys as cursors: no page asked after the literal $lit. Reads: $(grep -F 'after=' "$E2E_READ_LOG" | tr '\n' ' ')"
done
supp_env_reset

# Case 17 — a primary key of two columns (id, seq): three rows share an id and pages of 7 end in the middle of such a group. The cursor is the row value, and compares like one.
fresh_archive supp-composite
export STUB_ROWS_comments=100 STUB_PK="id seq" GC_JSONL_SUPP_CHUNK_ROWS=7
reset_reads
run_export 200 200
[ "$(supp_file_rows comments)" = "100" ] && [ "$(supp_dup_keys comments '[.id, .seq] | @json')" = "0" ] \
  && ok "composite key: all 100 rows, each (id, seq) once" \
  || bad "composite key: the file holds $(supp_file_rows comments) rows, $(supp_dup_keys comments '[.id, .seq] | @json') keys twice, want 100 and 0 (output: $OUT)"
no_failed_table "composite key"
grep -qE '^READ comments rows 7 after=\(.comments-[0-9]+., [0-9]+\)$' "$E2E_READ_LOG" \
  && ok "composite key: a page was asked after a two-column cursor" \
  || bad "composite key: no page asked after a (id, seq) cursor. Reads: $(grep -F 'READ comments rows' "$E2E_READ_LOG" | head -3 | tr '\n' ' ')"
supp_env_reset

# Case 18 — the page size is a plain decimal number whatever its spelling: 08 is eight (bash reads 08 in arithmetic as a bad octal), and the key sweeps use pages five times as big.
fresh_archive supp-chunk08
export STUB_ROWS_comments=100 GC_JSONL_SUPP_CHUNK_ROWS=08
reset_reads
run_export 200 200
[ "$(supp_file_rows comments)" = "100" ] && [ "$(supp_dup_keys comments)" = "0" ] \
  && ok "page size 08: read in pages of 8 — all 100 rows" \
  || bad "page size 08: the file holds $(supp_file_rows comments) rows (output: $OUT)"
grep -q '^READ comments rows 8 ' "$E2E_READ_LOG" && ! grep -q '^READ comments rows 08 ' "$E2E_READ_LOG" \
  && ok "page size 08: pages of 8 rows" \
  || bad "page size 08: no read of 8 rows. Reads: $(grep -F 'READ comments rows' "$E2E_READ_LOG" | head -3 | tr '\n' ' ')"
grep -q '^READ comments keys 40 ' "$E2E_READ_LOG" \
  && ok "page size 08: the key sweeps read 40 keys a page (5 x 8)" \
  || bad "page size 08: no key sweep of 40 keys a page. Reads: $(grep -F 'READ comments keys' "$E2E_READ_LOG" | head -3 | tr '\n' ' ')"
no_failed_table "page size 08"
supp_env_reset

# Case 19 — the key sweep itself fails (the 3rd state): nobody can say whether the rows read are the table's. For a table with a key that is "unverified" as the count was before: the export is
# the file, never discarded, and named in the log, the summary, the nudge and the commit message.
fresh_archive supp-keys-unreadable
export STUB_ROWS_comments=600 GC_JSONL_SUPP_CHUNK_ROWS=100
run_export 200 200
export STUB_ROWS_comments=700 STUB_KEYS_FAIL_comments=1
run_export 201 201
[ "$(supp_file_rows comments)" = "700" ] \
  && ok "unreadable key sweep: the export is archived (700 rows), as documented for an unverifiable export" \
  || bad "unreadable key sweep: comments holds $(supp_file_rows comments) rows, want 700"
unverified_seen "unreadable key sweep (comments)"
git -C "$ARCH" log -1 --format=%s | grep -q 'unverified=wa' \
  && ok "unreadable key sweep: the archive commit message records unverified=wa" \
  || bad "unreadable key sweep: commit message lacks unverified=wa: $(git -C "$ARCH" log -1 --format=%s)"
case "$OUT" in
  *"failed:"*) bad "unreadable key sweep: an unverifiable table is reported FAILED, not unverified: $OUT" ;;
  *) ok "unreadable key sweep: reported unverified, not failed" ;;
esac
supp_env_reset

# Case 20 — the helpers, alone. The cursor literal first: how a key is written into `WHERE (`id`) > (<here>)`. A key that cannot be written safely is not written at all (FAIL), and the read
# stops there instead of building SQL out of it.
Q="'"
kl() { printf '%s' "$2" | lib_call key_tuple_literal "$1" 2>/dev/null || echo FAIL; }   # falhou (function missing, key unsafe) → FAIL, which no expected answer is
NULKEY=$(jq -n -c '{id: ([97, 0, 98] | implode)}')
for spec in \
    "id|{\"id\":\"plain\"}|${Q}plain${Q}" \
    "id|{\"id\":\"it${Q}s\"}|${Q}it${Q}${Q}s${Q}" \
    "id|{\"id\":\"a\\\\b\"}|${Q}a\\\\b${Q}" \
    "id|{\"id\":\"say \\\"x\\\" \"}|${Q}say \"x\" ${Q}" \
    "id|{\"id\":\"é\"}|${Q}é${Q}" \
    "id|{\"id\":42}|42" \
    "id|{\"id\":-7}|-7" \
    "id seq|{\"id\":\"x\",\"seq\":3}|${Q}x${Q}, 3" \
    "issue_id label|{\"issue_id\":\"hq-1\",\"label\":\"it${Q}s\"}|${Q}hq-1${Q}, ${Q}it${Q}${Q}s${Q}" \
    "id|{\"id\":null}|FAIL" \
    "id|{\"id\":true}|FAIL" \
    "id|{\"id\":1.5}|FAIL" \
    "id|{\"id\":1234567890123456}|FAIL" \
    "id|{\"other\":\"x\"}|FAIL" \
    "id|${NULKEY}|FAIL" \
    "id|not json|FAIL"; do
  cols="${spec%%|*}"; rest="${spec#*|}"; row="${rest%|*}"; want="${rest##*|}"
  got=$(kl "$cols" "$row")
  [ "$got" = "$want" ] && ok "key_tuple_literal '$cols' $row -> $want" || bad "key_tuple_literal '$cols' $row -> '$got', want $want"
done

# The key verdict. Three files of keys (one JSON array per line): the table's keys BEFORE the read, AFTER it, and the keys the read returned. A key in both sweeps was in the table the whole
# time, and the read must have it; keys deleted or inserted meanwhile are the writers' business. A spec is "before|after|export|answer", each list "a,b,c" (empty = a list with no keys,
# - = no such file).
kv_dir="$WORK/kv"; mkdir -p "$kv_dir"
kv_file() {  # kv_file <path> <a,b,c|-> — one ["key"] line per key; "-" removes the file
  local path="$1" list="$2" k
  rm -f "$path"
  [ "$list" = "-" ] && return 0
  : > "$path"
  [ -z "$list" ] && return 0
  local IFS=,
  for k in $list; do printf '["%s"]\n' "$k" >> "$path"; done
}
for spec in "a,b,c|a,b,c|a,b,c|complete" "a,b,c|a,b,c|a,c|short 1" "a,b,c|a,b,c|a,b|short 1" "a,b,c|a,b,c|c|short 2" \
            "a,b,c|a,c,d|a,b,c|complete" "a,b,c|a,c,d|a,c|complete" "a,b,c|a,c,d|a,d|short 1" \
            "a,b,c|a,b,c|a,b,c,d|complete" "a,b,c|a,b,c||short 3" \
            "|||complete" "|a,b||complete" "a,b|||complete" "a,b|a,b||short 2" \
            "-|a,b|a,b|unknown" "a,b|-|a,b|unknown" "a,b|a,b|-|unknown"; do
  IFS='|' read -r kb ka ke want <<< "$spec"
  kv_file "$kv_dir/b" "$kb"; kv_file "$kv_dir/a" "$ka"; kv_file "$kv_dir/e" "$ke"
  got=$(lib_call table_keys_verdict "$kv_dir/b" "$kv_dir/a" "$kv_dir/e" 2>/dev/null || echo "?")
  [ "$got" = "$want" ] && ok "table_keys_verdict before=[$kb] after=[$ka] export=[$ke] -> $want" || bad "table_keys_verdict before=[$kb] after=[$ka] export=[$ke] -> '$got', want $want"
done
# a key file that exists but cannot be read is not an empty one
mkdir -p "$kv_dir/isdir"; kv_file "$kv_dir/a" "a"; kv_file "$kv_dir/e" "a"
got=$(lib_call table_keys_verdict "$kv_dir/isdir" "$kv_dir/a" "$kv_dir/e" 2>/dev/null || echo "?")
[ "$got" = "unknown" ] && ok "table_keys_verdict: a before-sweep file that cannot be read -> unknown" || bad "table_keys_verdict: unreadable before-sweep file -> '$got', want unknown"

# The numbers the exporter reads from the environment feed arithmetic: a plain decimal whatever its spelling (08 is eight), the default for anything else.
nw() { lib_call env_whole_number "$@" 2>/dev/null || echo "?"; }   # falhou (function missing) → "?"
for spec in "2000|2000|1|2000" "08|2000|1|8" "007|2000|1|7" "100|2000|1|100" "|2000|1|2000" "abc|2000|1|2000" "-5|2000|1|2000" "5x|2000|1|2000" " 5|2000|1|2000" "0|2000|1|2000" "00|2000|1|2000" \
            "0|3|0|0" "00|3|0|0" "3|3|0|3" "12345678901|2000|1|2000" "999999999|2000|1|999999999"; do
  IFS='|' read -r v d m want <<< "$spec"
  got=$(nw "$v" "$d" "$m")
  [ "$got" = "$want" ] && ok "env_whole_number '$v' default $d min $m -> $want" || bad "env_whole_number '$v' default $d min $m -> '$got', want $want"
done

# ga-8z0hy7 — a commit that lands while jsonl-archive-compact.sh runs must not start git's background maintenance.
# `git commit` runs `git maintenance run --auto --quiet --detach`; on git 2.54 that is a geometric repack which merges and deletes the loose-*.pack batch
# packs, for 19+ minutes and with no lock file, and a compactor gc that is running meanwhile dies with "could not find pack 'loose-....pack'". trace2 logs the
# spawn as a child_start event of the committing process itself, synchronously (the detached process logs later), so that is what is counted — not a process listing.
echo "=== ga-8z0hy7: a commit during a compaction run starts no background maintenance; outside one it still does ==="
maint_spawns() {  # maint_spawns <trace2 file> — how many times that run's git commit started `git maintenance run --auto`
  local n; n="$(grep -c '"maintenance","run","--auto"' "$1" 2>/dev/null)"; echo "${n:-0}"
}
maint_case() {  # maint_case <name> — one fresh archive, one export (its first commit), trace2 into $E2E/t2-<name>.json; JAC_LOCK is whatever the caller exported
  fresh_archive "maint-$1"
  : > "$E2E/t2-$1.json"
  GIT_TRACE2_EVENT="$E2E/t2-$1.json" run_export 300 300
}
DEAD_PID="$(sh -c 'echo $$')"      # a pid that was alive a moment ago and is gone now
kill -0 "$DEAD_PID" 2>/dev/null && DEAD_PID=999999

# ga-wkoij7: a commit starts git's maintenance only inside the night window with room on the disk. The lock cases below pin the compaction-lock logic alone, so the window is held OPEN
# with room (the clock and the free space are seams); the window's own cases follow them.
export JAW_HOUR=2 JAW_FREE_KIB=99999999
export JAC_LOCK="$E2E/lock-absent"
maint_case nolock
[ "$(commits)" = "1" ] && [ "$(maint_spawns "$E2E/t2-nolock.json")" -ge 1 ] \
  && ok "no compaction lock, window open with room: the commit starts git's background maintenance (consolidation is not switched off)" \
  || bad "no lock, window open: commits=$(commits) spawns=$(maint_spawns "$E2E/t2-nolock.json") — want 1 commit and a maintenance run started: $OUT"

export JAC_LOCK="$E2E/lock-live"; mkdir -p "$JAC_LOCK"; echo "$$" > "$JAC_LOCK/pid"
maint_case live
[ "$(commits)" = "1" ] && [ "$(maint_spawns "$E2E/t2-live.json")" -eq 0 ] \
  && ok "a live compactor holds its lock: the commit is made and starts NO background maintenance" \
  || bad "live lock: commits=$(commits) spawns=$(maint_spawns "$E2E/t2-live.json") — want 1 commit and 0 maintenance runs started: $OUT"
case "$OUT" in *"compaction run is in flight"*) ok "the run says why (a compaction run is in flight)" ;; *) bad "no 'compaction run is in flight' line in the output: $OUT" ;; esac

export JAC_LOCK="$E2E/lock-dead"; mkdir -p "$JAC_LOCK"; echo "$DEAD_PID" > "$JAC_LOCK/pid"
maint_case dead
[ "$(commits)" = "1" ] && [ "$(maint_spawns "$E2E/t2-dead.json")" -ge 1 ] \
  && ok "a lock whose owner is dead (a run killed by the order's timeout) does not hold git's consolidation off — the commit starts it" \
  || bad "dead-owner lock: commits=$(commits) spawns=$(maint_spawns "$E2E/t2-dead.json") — want 1 commit and a maintenance run started: $OUT"

export JAC_LOCK="$E2E/lock-nopid"; mkdir -p "$JAC_LOCK"
maint_case nopid
[ "$(commits)" = "1" ] && [ "$(maint_spawns "$E2E/t2-nopid.json")" -eq 0 ] \
  && ok "a lock directory with no pid file (its mkdir, not yet its pid write; or unreadable) counts as in flight — under doubt, no background run" \
  || bad "no-pid lock: commits=$(commits) spawns=$(maint_spawns "$E2E/t2-nopid.json") — want 1 commit and 0 maintenance runs started: $OUT"

export JAC_LOCK="$E2E/lock-junk"; mkdir -p "$JAC_LOCK"; echo "not-a-pid" > "$JAC_LOCK/pid"
maint_case junk
[ "$(commits)" = "1" ] && [ "$(maint_spawns "$E2E/t2-junk.json")" -eq 0 ] \
  && ok "a pid file that holds no number counts as in flight as well" \
  || bad "junk-pid lock: commits=$(commits) spawns=$(maint_spawns "$E2E/t2-junk.json") — want 1 commit and 0 maintenance runs started: $OUT"
unset JAC_LOCK

# ga-wkoij7 — outside the night window, or without room for a repack, a commit starts NO background maintenance even with no compactor running. The repo the exporter works on already
# carries maintenance.auto=false (ensure_archive_pack_config), so the open-window cases below prove that `-c maintenance.auto=true` on the commit beats it; the closed cases are
# proven twice — on that repo, and (keyless_commit, further down) on a repo that does not carry the keys.
echo "=== ga-wkoij7: a commit starts git's repack only in the 00:00-04:59 start window with room on the disk ==="
export JAC_LOCK="$E2E/lock-absent"
WIN_LOG="$E2E/city/.gc/logs/jsonl-archive-repack-window.log"
window_case() {  # window_case <name> <JAW_HOUR> <JAW_FREE_KIB> — one fresh archive, one export, the window seams as given; trace2 in $E2E/t2-<name>.json
  rm -f "$WIN_LOG"
  JAW_HOUR="$2" JAW_FREE_KIB="$3" maint_case "$1"
}
window_case win-open 2 99999999
[ "$(commits)" = "1" ] && [ "$(maint_spawns "$E2E/t2-win-open.json")" -ge 1 ] \
  && ok "02h with 95GB free: the commit starts git's maintenance (maintenance.auto=true on that commit, over the repo's own false)" \
  || bad "02h, room: commits=$(commits) spawns=$(maint_spawns "$E2E/t2-win-open.json") — want 1 commit and a maintenance run: $OUT"
grep -q 'repack allowed' "$WIN_LOG" 2>/dev/null \
  && ok "the allowed repack is on record in the window log" \
  || bad "no 'repack allowed' line in $WIN_LOG"
window_case win-noon 12 99999999
[ "$(commits)" = "1" ] && [ "$(maint_spawns "$E2E/t2-win-noon.json")" -eq 0 ] \
  && ok "12h with room: the commit is made and starts NO background maintenance (the incident of 17/10)" \
  || bad "12h: commits=$(commits) spawns=$(maint_spawns "$E2E/t2-win-noon.json") — want 1 commit and 0 maintenance runs: $OUT"
case "$OUT" in *"outside the start window"*) ok "the run says why (outside the start window)" ;; *) bad "no 'outside the start window' line: $OUT" ;; esac
[ ! -e "$WIN_LOG" ] \
  && ok "an outside-the-window refusal (20 hours a day) is not written to the window log" \
  || bad "the window log was written for an outside-the-window refusal: $(cat "$WIN_LOG")"
window_case win-noroom 2 1000
[ "$(commits)" = "1" ] && [ "$(maint_spawns "$E2E/t2-win-noroom.json")" -eq 0 ] \
  && ok "02h but 1000KiB free: the commit is made and starts NO background maintenance" \
  || bad "02h, no room: commits=$(commits) spawns=$(maint_spawns "$E2E/t2-win-noroom.json") — want 1 commit and 0 maintenance runs: $OUT"
grep -q 'INSIDE the window' "$WIN_LOG" 2>/dev/null \
  && ok "the night's refused repack is on record in the window log (why it did not run)" \
  || bad "no 'INSIDE the window' line in $WIN_LOG"
window_case win-nofree 2 abc
[ "$(commits)" = "1" ] && [ "$(maint_spawns "$E2E/t2-win-nofree.json")" -eq 0 ] && case "$OUT" in *"cannot be read"*) true ;; *) false ;; esac \
  && ok "free space that cannot be read: no repack, and the run says it cannot read it (under doubt, inert)" \
  || bad "unreadable free space: commits=$(commits) spawns=$(maint_spawns "$E2E/t2-win-nofree.json") — want 1 commit, 0 runs, 'cannot be read': $OUT"
window_case win-noclock xx 99999999
[ "$(commits)" = "1" ] && [ "$(maint_spawns "$E2E/t2-win-noclock.json")" -eq 0 ] \
  && ok "a clock that cannot be read: no repack" \
  || bad "unreadable clock: commits=$(commits) spawns=$(maint_spawns "$E2E/t2-win-noclock.json") — want 1 commit and 0 maintenance runs: $OUT"
window_case win-h04 4 99999999
[ "$(maint_spawns "$E2E/t2-win-h04.json")" -ge 1 ] \
  && ok "04h (last hour to start): allowed" \
  || bad "04h: spawns=$(maint_spawns "$E2E/t2-win-h04.json"), want >= 1: $OUT"
window_case win-h05 5 99999999
[ "$(maint_spawns "$E2E/t2-win-h05.json")" -eq 0 ] \
  && ok "05h (a repack started now would run past 06:00): refused" \
  || bad "05h: spawns=$(maint_spawns "$E2E/t2-win-h05.json"), want 0: $OUT"
# The pack directory is the third state of "how big is the biggest pack": no pack in a readable directory = a young repo (size 0, allowed); a directory that is missing or cannot be read =
# unknown (refused). Reading the unknown as 0 would pass the room check for a repo whose biggest pack is 4.5GiB.
pack_dir_case() {  # pack_dir_case <name> <mode> — jaw_repack_allowed at 02h with 95GB free on a gitdir whose objects/pack is <ok|missing|unreadable>; prints "allowed: …" or "refused: …"
  local gd="$E2E/packdir-$1"
  mkdir -p "$gd/objects"
  case "$2" in
    ok)         mkdir -p "$gd/objects/pack" ;;
    unreadable) mkdir -p "$gd/objects/pack" && chmod 000 "$gd/objects/pack" ;;
  esac
  (
    . "$HERE/jsonl-archive-repack-window-lib.sh"
    JAW_HOUR=2 JAW_FREE_KIB=99999999 JAW_LOG=""
    if jaw_repack_allowed "$gd" >/dev/null; then echo "allowed: $JAW_REASON"; else echo "refused: $JAW_REASON"; fi
  ) 2>&1
  chmod 755 "$gd/objects/pack" 2>/dev/null   # so the sandbox cleanup can remove it
}
PD_OUT="$(pack_dir_case ok ok)"
case "$PD_OUT" in "allowed:"*) ok "an empty, readable objects/pack (a young repo): size 0, the repack is allowed" ;; *) bad "empty readable pack dir: $PD_OUT" ;; esac
PD_OUT="$(pack_dir_case missing missing)"
case "$PD_OUT" in "refused:"*"cannot be measured"*) ok "no objects/pack at all: the biggest pack cannot be measured, the repack is refused (not read as 0)" ;; *) bad "missing pack dir: $PD_OUT" ;; esac
if [ "$(id -u)" -ne 0 ]; then
  PD_OUT="$(pack_dir_case unreadable unreadable)"
  case "$PD_OUT" in "refused:"*"cannot be measured"*) ok "an objects/pack that cannot be read: refused (not read as 0)" ;; *) bad "unreadable pack dir: $PD_OUT" ;; esac
else
  echo "  SKIP: unreadable-pack-dir case (running as root: chmod 000 does not block)"
fi
# jaw_window_left_s (the compactor's night gc is given this long): seconds to 06:00, and "no time" — rc 1, nothing printed — for a clock that cannot be read or a window that has closed
# (never a number the caller could take for "plenty"). jaw_resources_ok's factor: 1 x is the compactor's gc, 2 x the exporter's repack; a factor that is not a number >= 1 refuses.
lib_out() {  # lib_out <env assignments...> -- <function> [args...] — runs one lib function in a subshell with those seams; prints "rc=<n> out=<stdout>"
  local envs=() o
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  o="$(env "${envs[@]}" JAW_LOG="" bash -c '. "$1"; shift; out="$("$@")"; echo "rc=$? out=$out"' _ "$HERE/jsonl-archive-repack-window-lib.sh" "$@" 2>&1)"
  echo "$o"
}
WL="$(lib_out JAW_HOUR=2 -- jaw_window_left_s)";                       [ "$WL" = "rc=0 out=14400" ] && ok "window left at 02h (only the hour known): 4h = 14400s" || bad "window left at 02h: $WL"
WL="$(lib_out JAW_HOUR=2 JAW_SECS_OF_DAY=21500 -- jaw_window_left_s)"; [ "$WL" = "rc=0 out=100" ]   && ok "window left with the exact time of day (05:58:20): 100s — JAW_SECS_OF_DAY wins over JAW_HOUR" || bad "window left at 21500s: $WL"
WL="$(lib_out JAW_SECS_OF_DAY=21600 -- jaw_window_left_s)";            [ "$WL" = "rc=1 out=" ]       && ok "at 06:00:00 the window is closed: rc 1, nothing printed" || bad "window left at 06:00: $WL"
WL="$(lib_out JAW_SECS_OF_DAY=notatime -- jaw_window_left_s)";         [ "$WL" = "rc=1 out=" ]       && ok "a time of day that is not a number: rc 1 (no time), not a guess" || bad "window left, garbage seconds: $WL"
WL="$(lib_out JAW_HOUR=25 -- jaw_window_left_s)";                      [ "$WL" = "rc=1 out=" ]       && ok "an hour that is not 0-23: rc 1" || bad "window left, hour 25: $WL"
WL="$(lib_out JAW_HOUR=2 JAW_END_H=x -- jaw_window_left_s)";           [ "$WL" = "rc=1 out=" ]       && ok "a window end that is not a number: rc 1" || bad "window left, end 'x': $WL"
WL="$(lib_out JAW_HOUR= JAW_SECS_OF_DAY= -- jaw_window_left_s)"
case "$WL" in "rc=0 out="[0-9]*) [ "${WL#rc=0 out=}" -gt 0 ] && [ "${WL#rc=0 out=}" -le 21600 ] && ok "no seams: the real clock gives 1..21600s (${WL#rc=0 out=}s now)" || bad "real clock out of range: $WL" ;;
              "rc=1 out=")   ok "no seams: the real clock is outside the window right now — rc 1, nothing printed" ;;
              *)             bad "real clock: $WL" ;; esac
mkpack() {  # mkpack <gitdir> <KiB> — a fake pack of that size, so the largest-pack measure has something to read
  mkdir -p "$1/objects/pack"; dd if=/dev/zero of="$1/objects/pack/pack-x.pack" bs=1024 count="$2" 2>/dev/null
}
FD="$E2E/factor"; mkpack "$FD" 1024
RF() {  # RF <free_kib> <factor-or-empty> → "rc=<n>"
  lib_out JAW_HOUR=2 JAW_SWAP_KIB=0 -- jaw_resources_ok "$FD" "$1" "$2" | sed 's/ out=.*//'
}
[ "$(RF 1024 1)" = "rc=0" ] && [ "$(RF 1023 1)" = "rc=1" ] && ok "factor 1: free >= the largest pack allows (1024KiB), one KiB less refuses" || bad "factor 1 boundary: $(RF 1024 1) $(RF 1023 1)"
[ "$(RF 1500 2)" = "rc=1" ] && [ "$(RF 2048 2)" = "rc=0" ] && ok "factor 2 (the exporter's rule): 1500KiB free is not enough for a 1024KiB pack, 2048KiB is" || bad "factor 2: $(RF 1500 2) $(RF 2048 2)"
[ "$(RF 1500 "")" = "rc=1" ] && ok "no factor given: the default is 2 x (the exporter keeps its rule)" || bad "default factor: $(RF 1500 "")"
for badf in 0 x -1 1.5; do
  [ "$(RF 99999999 "$badf")" = "rc=1" ] && ok "factor '$badf' is not a number >= 1: refused, whatever the free space" || bad "factor '$badf' accepted: $(RF 99999999 "$badf")"
done
# A repo recreated WITHOUT the two keys (the exporter recreates it when .git goes missing; ensure_archive_pack_config runs only afterwards): the commit itself must start nothing outside the
# window, by its own -c flags. commit_archive_snapshot lives past the library-mode return, so its text is lifted out of the script and run against a bare repo with no keys.
keyless_commit() {  # keyless_commit <name> <JAW_HOUR> — one commit in a fresh repo with NO maintenance/gc keys; trace2 in $E2E/t2-<name>.json
  local kr="$E2E/keyless-$1"
  mkdir -p "$kr" && git -C "$kr" init -q && : > "$E2E/t2-$1.json"
  printf 'x\n' > "$kr/f.txt" && git -C "$kr" add f.txt
  (
    . "$HERE/jsonl-archive-repack-window-lib.sh"
    eval "$(sed -n '/^compaction_in_flight() {/,/^}/p;/^commit_archive_snapshot() {/,/^}/p' "$SCRIPT")"
    COMPACT_LOCK="$E2E/lock-absent"; ARCHIVE_REPO="$kr"; JAW_LOG=""
    cd "$kr" && JAW_HOUR="$2" JAW_FREE_KIB=99999999 GIT_TRACE2_EVENT="$E2E/t2-$1.json" commit_archive_snapshot "keyless" "selftest"
  ) >/dev/null 2>&1
}
keyless_commit keyless-open 2
[ "$(git -C "$E2E/keyless-keyless-open" rev-list --count HEAD 2>/dev/null)" = "1" ] && [ "$(maint_spawns "$E2E/t2-keyless-open.json")" -ge 1 ] \
  && ok "keyless repo, 02h: the commit starts maintenance (the spawn detector sees it)" \
  || bad "keyless repo, 02h: commits=$(git -C "$E2E/keyless-keyless-open" rev-list --count HEAD 2>/dev/null) spawns=$(maint_spawns "$E2E/t2-keyless-open.json") — want 1 and >= 1"
keyless_commit keyless-noon 12
[ "$(git -C "$E2E/keyless-keyless-noon" rev-list --count HEAD 2>/dev/null)" = "1" ] && [ "$(maint_spawns "$E2E/t2-keyless-noon.json")" -eq 0 ] \
  && ok "keyless repo, 12h: the commit starts NO maintenance on its own flags (git's default would have)" \
  || bad "keyless repo, 12h: commits=$(git -C "$E2E/keyless-keyless-noon" rev-list --count HEAD 2>/dev/null) spawns=$(maint_spawns "$E2E/t2-keyless-noon.json") — want 1 and 0"
unset JAC_LOCK JAW_HOUR JAW_FREE_KIB

# the lib is not optional: an exporter that cannot load it must stop, not commit with a gate that is silently absent
mkdir -p "$E2E/scripts-nolib"; cp "$SCRIPT" "$E2E/scripts-nolib/jsonl-export.sh"
NOLIB_OUT="$(PATH="$SANDBOX_PATH" GC_CITY="$E2E/city" bash "$E2E/scripts-nolib/jsonl-export.sh" 2>&1)"; NOLIB_RC=$?
[ "$NOLIB_RC" -ne 0 ] && case "$NOLIB_OUT" in *"cannot load"*"jsonl-archive-repack-window-lib.sh"*) true ;; *) false ;; esac \
  && ok "no window lib next to the exporter: it exits non-zero and names the missing file" \
  || bad "no lib: rc=$NOLIB_RC, want non-zero with 'cannot load ...jsonl-archive-repack-window-lib.sh': $NOLIB_OUT"

# The cases above point BOTH scripts at one directory with JAC_LOCK, so nothing in them would notice the two DEFAULTS drifting apart — and then the exporter would look for a lock the
# compactor never takes, and every commit would start the background repack again with all of the above still green. So: the same environment, the default path each one derives.
# (--print-config prints the compactor's effective `lock=`; the exporter's is the one assignment, evaluated here with the city and runtime variables it reads.)
echo "=== ga-8z0hy7: the exporter looks for the compaction lock where the compactor takes it (default paths) ==="
CMP_SCRIPT="$HERE/jsonl-archive-compact.sh"
EXP_LOCK_LINE="$(grep -E '^COMPACT_LOCK=' "$SCRIPT")"
lock_paths_agree() {  # lock_paths_agree <label> <city dir> <runtime dir or ""> — the runtime variable is exported only when given
  local label="$1" city="$2" rt="$3" exp_path cmp_path
  exp_path="$( unset JAC_LOCK GC_CITY_RUNTIME_DIR; [ -n "$rt" ] && export GC_CITY_RUNTIME_DIR="$rt"; CITY="$city"; eval "$EXP_LOCK_LINE"; printf '%s' "${COMPACT_LOCK:-}" )"
  cmp_path="$( unset JAC_LOCK JAC_STATE JAC_LOG GC_CITY_RUNTIME_DIR; [ -n "$rt" ] && export GC_CITY_RUNTIME_DIR="$rt"; GC_CITY_PATH="$city" "$CMP_SCRIPT" --print-config 2>/dev/null | sed -n 's/.* lock=//p' )"
  if [ -n "$exp_path" ] && [ "$exp_path" = "$cmp_path" ]; then ok "$label: both resolve to $exp_path"
  else bad "$label: the exporter looks at [$exp_path], the compactor takes [$cmp_path] — a commit would never see the compaction lock"; fi
}
lock_paths_agree "runtime dir given (GC_CITY_RUNTIME_DIR, as the supervisor sets it)" "$E2E/city-x" "$E2E/runtime-x"
lock_paths_agree "no runtime dir given (derived from the city)" "$E2E/city-y" ""

echo "=== ga-48e0du: the order declares a timeout the run fits in — and one that cannot stack ==="
# With no `timeout` the engine kills an exec order at 300 s (orders.Order.TimeoutOrDefault; see mol-dog-reaper.toml, ga-x2fj8h). The exporter commits ONLY after every database has been
# exported (the one commit_archive_snapshot after the loop), so a run killed before that leaves the files written and NOTHING committed: on 2026-10-16 the archive HEAD froze at 12:08:15Z while
# eight runs in a row were killed at 5m02s-5m06s (`gc order history jsonl-export`; the last run that finished took 4m07s, so the ceiling was already 82% used). The data did not grow
# (hq/issues.jsonl 71.39 -> 71.97 MB between the last commit and the fix); the host load did (84 on 10 cores). A run now needs about 6-8 minutes — an ESTIMATE from file mtimes, not a stopwatch.
# The script has no single-flight lock, so the timeout must also stay under the 15 m interval: two exports in one git working tree is the ga-fxrrav failure.
ORDER_TOML="$HERE/../../orders/jsonl-export.toml"
order_field() {  # order_field <file> <key> — the value of `key = "..."` on a non-comment line (a `# key = ...` line does not count)
  # vazio → prints nothing (the caller turns that into "not declared"); falhou/ilegível → the caller checks the file is readable BEFORE calling, so nothing here is read from a missing file
  grep -E "^[[:space:]]*$2[[:space:]]*=" "$1" | head -1 | sed -E 's/^[^=]*=[[:space:]]*"?([0-9a-z]*)"?.*$/\1/'
}
dur_s() {  # dur_s <Ns|Nm|Nh> — seconds on stdout; returns 1 (prints nothing) for empty or anything that is not one plain duration
  # 10# on purpose: a leading zero ("0840s") is decimal here, not an octal error in $(( ))
  case "$1" in ''|*[!0-9smh]*) return 1 ;; esac
  local n="${1%[smh]}" u="${1: -1}"
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  case "$u" in s) echo $((10#$n)) ;; m) echo $((10#$n * 60)) ;; h) echo $((10#$n * 3600)) ;; *) return 1 ;; esac
}
order_timeout_verdict() {  # order_timeout_verdict <order toml> — "ok", or the reason it is not. Every doubt is a reason: nothing here defaults to ok.
  local f="$1" t i ts is
  [ -r "$f" ] || { echo "cannot read $f"; return 0; }
  t="$(order_field "$f" timeout)"; i="$(order_field "$f" interval)"
  [ -n "$t" ] || { echo "no timeout declared: the engine's 300 s default applies"; return 0; }
  ts="$(dur_s "$t")" || { echo "timeout '$t' is not one plain Ns/Nm/Nh duration"; return 0; }
  is="$(dur_s "$i")" || { echo "interval '$i' unreadable: cannot tell whether runs can stack"; return 0; }
  [ "$ts" -ge 600 ] || { echo "timeout ${ts}s is under 600 s: a run needs about 6-8 min"; return 0; }
  [ "$ts" -lt "$is" ] || { echo "timeout ${ts}s is not under the ${is}s interval and the script has no lock: two exports could overlap"; return 0; }
  echo ok
}
v="$(order_timeout_verdict "$ORDER_TOML")"
[ "$v" = ok ] && ok "jsonl-export.toml: timeout declared, at least 600 s, and under the interval" || bad "jsonl-export.toml: $v"
# the check bites: each of these order files must be refused for its own reason, and only the sound ones pass
mk_order() {  # mk_order <name> <interval value or ""> <timeout line or ""> — writes $WORK/order-<name>.toml and prints its path
  { printf '[order]\nexec = "x"\ntrigger = "cooldown"\n'; [ -n "$2" ] && printf 'interval = "%s"\n' "$2"; [ -n "$3" ] && printf '%s\n' "$3"; } > "$WORK/order-$1.toml"
  printf '%s' "$WORK/order-$1.toml"
}
expect_verdict() {  # expect_verdict <label> <file> <"ok" | substring of the reason>
  local got; got="$(order_timeout_verdict "$2")"
  if [ "$3" = ok ]; then [ "$got" = ok ] && ok "$1 -> ok" || bad "$1 -> '$got', wanted ok"
  else case "$got" in *"$3"*) ok "$1 -> refused ($3)" ;; *) bad "$1 -> '$got', wanted a refusal naming '$3'" ;; esac; fi
}
expect_verdict "no timeout line"                          "$(mk_order none 15m '')"                                         "no timeout declared"
expect_verdict "only a commented-out timeout"             "$(mk_order commented 15m '# timeout = "840s"')"                  "no timeout declared"
expect_verdict "timeout 300s (the engine default)"        "$(mk_order t300 15m 'timeout = "300s"')"                         "under 600"
expect_verdict "timeout equal to the interval"            "$(mk_order teq 15m 'timeout = "900s"')"                          "not under"
expect_verdict "timeout above the interval"               "$(mk_order t1800 15m 'timeout = "1800s"')"                       "not under"
expect_verdict "timeout 'ten' (not a duration)"           "$(mk_order tten 15m 'timeout = "ten"')"                          "not one plain"
expect_verdict "timeout 1h30m (compound, not accepted)"   "$(mk_order tcomp 15m 'timeout = "1h30m"')"                       "not one plain"
expect_verdict "no interval at all"                       "$(mk_order noint '' 'timeout = "840s"')"                         "interval '' unreadable"
expect_verdict "order file missing"                       "$WORK/order-does-not-exist.toml"                                 "cannot read"
expect_verdict "timeout 840s"                             "$(mk_order t840 15m 'timeout = "840s"')"                         ok
expect_verdict "timeout 14m, trailing comment"            "$(mk_order t14m 15m 'timeout = "14m"   # headroom, see the header')" ok
expect_verdict "timeout 0840s (leading zero is decimal)"  "$(mk_order t0840 15m 'timeout = "0840s"')"                       ok

# ── ga-j2f5v5: the export's cadence follows the disk ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# Measured 18/10: every 15-min run rewrote ~400 MB of JSONL, dipped the disk ~700 MB and kept a new loose blob per changed file, with the disk already under Dolt's CRITICAL floor. Now a low disk spaces the run out
# (1 h under 5 GB, 3 h in Dolt's CRITICAL class), says so in the log, and a disk that cannot be read does NOT stop the export (it is the backup). The disk and the clock are pinned (E2E_DISK_MB / E2E_NOW), so the
# result does not depend on the host's real free space.
echo "=== ga-j2f5v5: a low disk spaces the export out; an unreadable disk does not ==="
T0=1792320000            # a fixed instant; the exporter's clock is JEX_NOW_EPOCH = T0 + the case's offset
JEX_TLOG="$E2E/city/.gc/logs/jsonl-export.log"
iso_of() { jq -nr --argjson e "$1" '$e | todate'; }
# vazio → "none" (no state file, or no last_export_at in it); falhou/ilegível (the file is there and jq cannot read it) → "?", which no assertion below accepts
stamp()  { local f="$E2E_STATE/jsonl-export-state.json"; [ -e "$f" ] || { echo none; return 0; }; jq -r '.last_export_at // "none"' "$f" 2>/dev/null || echo "?"; }
dolt_calls() { wc -l < "$E2E/dolt-calls.log" 2>/dev/null | tr -d ' '; }
cad() {  # cad <disk MB|word> <seconds after T0> <rows> — one run on that disk at that instant; the source agrees with the rows
  E2E_DISK_MB="$1" E2E_NOW=$((T0 + $2)) run_export "$3" "$3"
}
is_skip() { case "$OUT" in *"skipped-low-disk (cadência estendida)"*) return 0 ;; *) return 1 ;; esac; }
yn() { if "$@"; then echo yes; else echo no; fi; }
reset_tlog() { mkdir -p "$(dirname "$JEX_TLOG")"; : > "$JEX_TLOG"; }

# the verdict itself, boundary by boundary (pure: lib mode, no run). The default floors: new work 5120 MB, Dolt CRITICAL = free GiB rounded down <= 3, i.e. under 4096 MB; 1 h and 3 h.
vt() {  # vt <label> <want: prefix of the verdict line> <free> <last> <now> [env assignments...]
  local label="$1" want="$2" got; shift 2
  got="$(env "${@:4}" bash -c 'export JSONL_EXPORT_LIB=1; . "$0" >/dev/null 2>&1; jex_cadence_verdict "$1" "$2" "$3"' "$SCRIPT" "$1" "$2" "$3")"
  case "$got" in "$want"*) ok "verdict: $label -> $got" ;; *) bad "verdict: $label -> '$got', want '$want...'" ;; esac
}
N=$T0
vt "plenty of disk (10 GB), stamp a second old"            "run|disk-ok"                   10240 $((N-1))     $N
vt "exactly the new-work floor (5120 MB) is not low"        "run|disk-ok"                   5120  $((N-1))     $N
vt "5119 MB, 59 min 59 s since the last export"             "skip|tier=low "                5119  $((N-3599))  $N
vt "5119 MB, exactly 1 h since the last export"             "run|due-low"                   5119  $((N-3600))  $N
vt "4096 MB is NOT Dolt-critical (free GiB = 4): low tier"  "skip|tier=low "                4096  $((N-100))   $N
vt "4095 MB IS Dolt-critical (free GiB rounds down to 3)"   "skip|tier=critical "           4095  $((N-3601))  $N
vt "critical, 2 h 59 min 59 s since the last export"        "skip|tier=critical "           4095  $((N-10799)) $N
vt "critical, exactly 3 h since the last export"            "run|due-critical"              4095  $((N-10800)) $N
vt "disk unreadable (empty) with a fresh stamp"             "run|disk-unreadable"           ""    $((N-5))     $N
vt "disk unreadable (not a number) with a fresh stamp"      "run|disk-unreadable"           "n/a" $((N-5))     $N
vt "low disk, never stamped"                                "run|no-last-export"            2048  ""           $N
vt "low disk, stamp is not a number"                        "run|last-export-unreadable"    2048  "yesterday"  $N
vt "low disk, stamp of 20 digits (would wrap the arithmetic)" "run|last-export-unreadable"  2048  "99999999999999999999" $N
vt "low disk, stamp in the future"                          "run|last-export-in-the-future" 2048  $((N+50))    $N
vt "low disk, the clock cannot be read"                     "run|clock-unreadable"          2048  100         ""
vt "kill switch DISK_HEADROOM_ENABLED=0 at 100 MB"          "run|disk-ok"                   100   $((N-1))     $N DISK_HEADROOM_ENABLED=0
vt "1 h interval set to 0 turns the low tier off"           "run|due-low"                   5000  $((N-1))     $N JEX_LOW_DISK_INTERVAL_S=0
vt "DOLT_DISK_FLOOR_CRITICAL_GB=1: 3000 MB is only low"     "skip|tier=low "                3000  $((N-100))   $N DOLT_DISK_FLOOR_CRITICAL_GB=1
vt "DOLT_DISK_FLOOR_CRITICAL_GB=1: 2000 MB is critical"     "skip|tier=critical "           2000  $((N-4000))  $N DOLT_DISK_FLOOR_CRITICAL_GB=1
vt "DOLT_DISK_FLOOR_CRITICAL_GB=08 is eight, not an octal error" "skip|tier=critical "     9000  $((N-4000))  $N DOLT_DISK_FLOOR_CRITICAL_GB=08
vt "DOLT_DISK_FLOOR_CRITICAL_GB=lots falls back to 3"       "skip|tier=low "                4096  $((N-100))   $N DOLT_DISK_FLOOR_CRITICAL_GB=lots

# 4 GB (the Mayor's case): the 2nd run inside the hour is a skip, and a skip touches NOTHING — no Dolt call, no commit, no new stamp
fresh_archive disk4g; reset_tlog
cad 4096 0 200
[ "$(head_rows)" = "200" ] && [ "$(stamp)" = "$(iso_of $T0)" ] \
  && ok "4 GB, first run: exports (200 rows) and stamps last_export_at = $(iso_of $T0)" \
  || bad "4 GB, first run: head=$(head_rows) stamp=$(stamp), want 200 and $(iso_of $T0) (rc=$RC): $OUT"
C4=$(commits)
cad 4096 900 250
if is_skip && [ "$RC" = "0" ] && [ "$(dolt_calls)" = "0" ] && [ "$(head_rows)" = "200" ] && [ "$(commits)" = "$C4" ] && [ "$(stamp)" = "$(iso_of $T0)" ]; then
  ok "4 GB, 15 min later (source now has 250): skipped, rc 0, no Dolt call, archive still 200 rows, no commit, stamp untouched"
else
  bad "4 GB, 15 min later: skip=$(yn is_skip) rc=$RC dolt_calls=$(dolt_calls) head=$(head_rows) commits $C4 -> $(commits) stamp=$(stamp): $OUT"
fi
grep -q 'skipped-low-disk (cadência estendida) — tier=low free=4096MB' "$JEX_TLOG" \
  && ok "4 GB skip: the log file says 'skipped-low-disk (cadência estendida)' with the tier and the reading" \
  || bad "4 GB skip: nothing in $JEX_TLOG: $(tr '\n' '|' < "$JEX_TLOG" 2>&1)"
cad 4096 3599 250
{ is_skip && [ "$(head_rows)" = "200" ]; } && ok "4 GB, 59 min 59 s later: still a skip" || bad "4 GB, 59 min 59 s later: skip=$(yn is_skip) head=$(head_rows): $OUT"
cad 4096 3600 250
if ! is_skip && [ "$(head_rows)" = "250" ] && [ "$(stamp)" = "$(iso_of $((T0 + 3600)))" ] && [ "$(commits)" = "$((C4 + 1))" ]; then
  ok "4 GB, exactly 1 h later: exports (250 rows, one new commit) and the stamp moves to $(iso_of $((T0 + 3600)))"
else
  bad "4 GB, exactly 1 h later: skip=$(yn is_skip) head=$(head_rows) stamp=$(stamp) commits $C4 -> $(commits) (rc=$RC): $OUT"
fi

# 2 GB (Dolt's CRITICAL class): the hour is NOT enough, 3 h is
fresh_archive disk2g; reset_tlog
cad 2048 0 200
C2=$(commits)
cad 2048 3600 210
{ is_skip && [ "$(head_rows)" = "200" ] && [ "$(dolt_calls)" = "0" ]; } \
  && ok "2 GB, 1 h later: skipped (the low-disk hour has passed, Dolt's 3 h has not)" \
  || bad "2 GB, 1 h later: skip=$(yn is_skip) head=$(head_rows) dolt_calls=$(dolt_calls): $OUT"
cad 2048 10799 210
{ is_skip && [ "$(head_rows)" = "200" ]; } && ok "2 GB, 2 h 59 min 59 s later: still a skip" || bad "2 GB, 2 h 59 min 59 s later: skip=$(yn is_skip) head=$(head_rows): $OUT"
cad 2048 10800 210
{ ! is_skip && [ "$(head_rows)" = "210" ] && [ "$(commits)" = "$((C2 + 1))" ]; } \
  && ok "2 GB, exactly 3 h later: exports (210 rows, one new commit)" \
  || bad "2 GB, exactly 3 h later: skip=$(yn is_skip) head=$(head_rows) commits $C2 -> $(commits) (rc=$RC): $OUT"
grep -q 'tier=critical free=2048MB' "$JEX_TLOG" && grep -q 'run (due-critical) free=2048MB' "$JEX_TLOG" \
  && ok "2 GB: the log names the tier of the skips and the run that was due" \
  || bad "2 GB: the log lacks the critical skip or the due run: $(tr '\n' '|' < "$JEX_TLOG")"

# a df that cannot be read: the export RUNS, every time (it is the backup) — and says why
fresh_archive dfbroken; reset_tlog
cad broken 0 200
cad broken 60 210
{ ! is_skip && [ "$(head_rows)" = "210" ]; } \
  && ok "df unreadable: both runs export (second one a minute after the first, 210 rows)" \
  || bad "df unreadable: skip=$(yn is_skip) head=$(head_rows) (rc=$RC): $OUT"
grep -q 'run (disk-unreadable) free=unreadableMB' "$JEX_TLOG" \
  && ok "df unreadable: the log says 'run (disk-unreadable)'" \
  || bad "df unreadable: the log does not say why it ran: $(tr '\n' '|' < "$JEX_TLOG")"

# control: plenty of disk exports on every tick, and writes no line to the log
fresh_archive disk10g; reset_tlog
cad 10240 0 200; cad 10240 1 210; cad 10240 2 220
{ ! is_skip && [ "$(head_rows)" = "220" ] && [ "$(commits)" = "3" ]; } \
  && ok "control, 10 GB: three runs in three seconds all export (220 rows, 3 commits)" \
  || bad "control, 10 GB: skip=$(yn is_skip) head=$(head_rows) commits=$(commits) (rc=$RC): $OUT"
# the run's own `start pid=N` / `end rc=N` lines (ga-iqsy9c7) are not cadence lines: they are there on every run, so what must stay empty is the log WITHOUT them.
# vazio → no cadence line; falhou (the log cannot be read) → the text is "?", which is not empty
cadence_lines() { grep -v -e ' start pid=[0-9]' -e ' end rc=[0-9]' -e ' end signal ' "$JEX_TLOG" 2>/dev/null || { [ $? -eq 1 ] || echo '?'; }; }
[ -z "$(cadence_lines)" ] && ok "control, 10 GB: a healthy disk writes no cadence line to the log (only the run's start/end)" || bad "control, 10 GB: the log has cadence lines: $(cadence_lines | tr '\n' '|')"

# a stamp nobody can trust never blocks the export: garbage, and a stamp from the future
fresh_archive badstamp; reset_tlog
printf '{"last_export_at":"yesterday"}\n' > "$E2E_STATE/jsonl-export-state.json"
cad 2048 0 200
{ ! is_skip && [ "$(head_rows)" = "200" ] && [ "$(stamp)" = "$(iso_of $T0)" ]; } \
  && ok "garbage last_export_at at 2 GB: exports and replaces it with a valid stamp" \
  || bad "garbage last_export_at: skip=$(yn is_skip) head=$(head_rows) stamp=$(stamp) (rc=$RC): $OUT"
printf '{"last_export_at":"%s"}\n' "$(iso_of $((T0 + 99999)))" > "$E2E_STATE/jsonl-export-state.json"
cad 2048 900 210
{ ! is_skip && [ "$(head_rows)" = "210" ] && [ "$(stamp)" = "$(iso_of $((T0 + 900)))" ]; } \
  && ok "last_export_at in the future at 2 GB: exports and replaces it" \
  || bad "future last_export_at: skip=$(yn is_skip) head=$(head_rows) stamp=$(stamp) (rc=$RC): $OUT"

# a tick that exports nothing (Dolt lists no database) does not use up the hour
fresh_archive nodbs; reset_tlog
export STUB_NO_DBS=1
cad 2048 0 200
unset STUB_NO_DBS
{ [ "$RC" = "0" ] && [ "$(stamp)" = "none" ]; } \
  && ok "no database to export: exits 0 and leaves last_export_at unset" \
  || bad "no database to export: rc=$RC stamp=$(stamp): $OUT"
cad 2048 60 200
{ ! is_skip && [ "$(head_rows)" = "200" ]; } \
  && ok "…so the next tick (a minute later, 2 GB) still exports" \
  || bad "after a tick with no database: skip=$(yn is_skip) head=$(head_rows) (rc=$RC): $OUT"

# a run the engine kills mid-export cost the disk all the same: it counts, and it does not wedge the exporter for good
fresh_archive killcounts; reset_tlog
export STUB_KILL_SELF=1
cad 2048 0 200
unset STUB_KILL_SELF
{ [ "$RC" != "0" ] && [ "$(stamp)" = "$(iso_of $T0)" ]; } \
  && ok "killed mid-export at 2 GB: the run died (rc=$RC) and had already stamped last_export_at" \
  || bad "killed mid-export: rc=$RC stamp=$(stamp), want a death and $(iso_of $T0): $OUT"
# ga-iqsy9c7: the kill leaves its scratch, and the skipped tick that follows — the low disk is why it skips, and the disk is what the scratch eats — deletes it, instead of leaving it to the next export an hour or 3 h away
KC_DIR="$(dirname "$ARCH")/.jsonl-export-tmp"
KC_LEFT="$(stray_in "$KC_DIR")"
{ [ -n "$KC_LEFT" ] && [ "${KC_LEFT#find failed}" = "$KC_LEFT" ]; } \
  && ok "killed mid-export at 2 GB: the dead run left its scratch (the case under test exists)" \
  || bad "test setup invalid: the killed run left '$KC_LEFT' in $KC_DIR"
cad 2048 900 200
{ is_skip && [ "$(dolt_calls)" = "0" ]; } \
  && ok "…the next tick (15 min later) is a skip: a killed export is not retried every tick" \
  || bad "after a killed export: skip=$(yn is_skip) dolt_calls=$(dolt_calls): $OUT"
{ [ -z "$(stray_in "$KC_DIR")" ] && [ "$(grep -c ' swept 1 scratch' "$JEX_TLOG" 2>/dev/null || true)" = "1" ] && tail -n 1 "$JEX_TLOG" | grep -q 'skipped-low-disk'; } \
  && ok "…and that skipped tick already swept the dead run's scratch (logged, before the skip line) without asking Dolt anything" \
  || bad "skipped tick after a kill: scratch='$(stray_in "$KC_DIR" | tr '\n' ' ')' swept lines=$(grep -c ' swept 1 scratch' "$JEX_TLOG" 2>/dev/null || true): $(tr '\n' '|' < "$JEX_TLOG")"
cad 2048 10800 200
{ ! is_skip && [ "$(head_rows)" = "200" ]; } \
  && ok "…and 3 h after it the export runs and archives (200 rows)" \
  || bad "3 h after a killed export: skip=$(yn is_skip) head=$(head_rows) (rc=$RC): $OUT"
[ "$(grep -c ' DIED .*; 1 in a row' "$JEX_TLOG" 2>/dev/null || true)" = "1" ] \
  && ok "…and that run names the kill in the log ('DIED ... 1 in a row'), which the skipped tick between left to it" \
  || bad "3 h after a kill: no 'DIED ... 1 in a row' in the log: $(tr '\n' '|' < "$JEX_TLOG")"

# a skipped tick still delivers the pending spike alert (it is retried BEFORE the cadence is decided)
fresh_archive alertskip; reset_tlog
cad 2048 0 200
jq -c '.pending_spike_alerts = {wa: {database: "wa", prev_count: 1000, current_count: 500, delta: 50, threshold: 20}}' "$E2E_STATE/jsonl-export-state.json" > "$E2E_STATE/s.tmp" && mv "$E2E_STATE/s.tmp" "$E2E_STATE/jsonl-export-state.json"
cad 2048 900 200
{ is_skip && [ "$(mailed)" = "1" ] && [ "$(jq -r '.pending_spike_alerts // "cleared"' "$E2E_STATE/jsonl-export-state.json")" = "cleared" ] && [ "$(stamp)" = "$(iso_of $T0)" ]; } \
  && ok "skipped tick: the pending spike alert is still mailed once and cleared; the stamp stays" \
  || bad "skipped tick with a pending alert: skip=$(yn is_skip) mails=$(mailed) alerts=$(jq -c '.pending_spike_alerts // "cleared"' "$E2E_STATE/jsonl-export-state.json") stamp=$(stamp): $OUT"

# the log is bounded: 1100 old lines + one skip leave a short file that ends with the skip
fresh_archive logtrim; reset_tlog
cad 2048 0 200
i=0; while [ $i -lt 1100 ]; do echo "2026-10-17T00:00:00Z old line $i"; i=$((i + 1)); done > "$JEX_TLOG"
cad 2048 900 200
n=$(wc -l < "$JEX_TLOG" | tr -d ' ')
{ is_skip && [ "$n" -le 305 ] && [ "$n" -ge 2 ] && tail -n 1 "$JEX_TLOG" | grep -q 'skipped-low-disk'; } \
  && ok "log trimmed: 1100 old lines + a skip leave $n lines, the last one the skip" \
  || bad "log trim: skip=$(yn is_skip) lines=$n last='$(tail -n 1 "$JEX_TLOG")'"

# the stamp cannot be built (jq fails on exactly that rewrite): the state file is left AS IT WAS — never replaced by an empty answer — and the run still exports
fresh_archive stampfail; reset_tlog
printf '{"sentinel_key":"kept","pending_spike_alerts":{"wa":{"database":"wa","prev_count":1000,"current_count":500,"delta":50,"threshold":20}}}\n' > "$E2E_STATE/jsonl-export-state.json"
STATE_BEFORE="$(jq -S -c . "$E2E_STATE/jsonl-export-state.json")"
REAL_JQ="$(command -v jq)"
printf '#!/bin/sh\nif [ "${STUB_JQ_FAIL_STAMP:-0}" = 1 ]; then for a in "$@"; do case "$a" in *"last_export_at = \\$t"*) exit 5 ;; esac; done; fi\nexec "%s" "$@"\n' "$REAL_JQ" > "$E2E/bin/jq"
chmod +x "$E2E/bin/jq"
export STUB_JQ_FAIL_STAMP=1
cad 4096 0 200
unset STUB_JQ_FAIL_STAMP
# falhou/ilegível (the file is not a JSON object any more) → "UNREADABLE", which the assertion below does not accept
STATE_AFTER="$(jq -c '{sentinel: .sentinel_key, stamp: (.last_export_at // "none")}' "$E2E_STATE/jsonl-export-state.json" 2>/dev/null || echo UNREADABLE)"
rm -f "$E2E/bin/jq"
# (the run itself rewrites last_logged_mode, pending_archive_push and resets consecutive_push_failures, so the state is not compared whole: a key nothing in the exporter touches must survive, and there must be no stamp)
{ [ "$RC" = "0" ] && [ "$(head_rows)" = "200" ] && [ "$STATE_AFTER" = '{"sentinel":"kept","stamp":"none"}' ]; } \
  && ok "stamp cannot be built: the run still exports (200 rows), the state keeps its other keys and gets no last_export_at (not blanked)" \
  || bad "stamp cannot be built: rc=$RC head=$(head_rows) state_after=$STATE_AFTER stamp=$(stamp) (before: $STATE_BEFORE): $OUT"
case "$OUT" in *"could not build the updated state, last_export_at not stamped"*"could not stamp last_export_at"*) ok "stamp cannot be built: both warnings reach stderr" ;; *) bad "stamp cannot be built: warnings missing: $OUT" ;; esac

# the guard's lib missing next to the exporter: the run still exports (a backup that cannot find its guard runs), and says so
mkdir -p "$E2E/scripts-nodisk" "$E2E/city-nodisk" "$E2E/state-nodisk"
cp "$SCRIPT" "$E2E/scripts-nodisk/jsonl-export.sh"
cp "$HERE/jsonl-archive-repack-window-lib.sh" "$E2E/scripts-nodisk/"
cp "$E2E/scripts/dolt-target.sh" "$E2E/scripts-nodisk/"
nodisk_run() {  # nodisk_run <rows> — exporter without disk-headroom-lib.sh, on a 2 GB reading and a pinned clock (which the guard could not use anyway)
  : > "$E2E/gc.log"
  OUT=$(E2E_GC_LOG="$E2E/gc.log" STUB_EXPORT_ROWS="$1" STUB_SOURCE_COUNT="$1" STUB_TEST_ROWS=0 DISK_FREE_OVERRIDE_MB=2048 JEX_NOW_EPOCH=$T0 \
    PATH="$SANDBOX_PATH" GC_CITY="$E2E/city-nodisk" GC_PACK_STATE_DIR="$E2E/state-nodisk" GC_JSONL_ARCHIVE_REPO="$E2E/archive-nodisk" \
    bash "$E2E/scripts-nodisk/jsonl-export.sh" 2>&1)
  RC=$?
}
nodisk_run 200; nodisk_run 210
ARCH="$E2E/archive-nodisk"
{ [ "$RC" = "0" ] && [ "$(head_rows)" = "210" ] && case "$OUT" in *"disk-headroom-lib.sh could not be loaded"*"exports"*) true ;; *) false ;; esac; } \
  && ok "no disk lib next to the exporter: both runs export (210 rows) and each says the cadence guard is OFF" \
  || bad "no disk lib: rc=$RC head=$(head_rows): $OUT"

# the alarm that watches the exporter (jsonl-hourly-offsite.sh: "fonte parada" = no <db>/issues.jsonl rewrite for JHO_STALE_SOURCE_S) must stay quiet through the longest skip. That is 3 h (the critical
# interval) + one tick (the order interval, 15 min) + one run (the order timeout, 840 s). Read from the files, so a change to either side shows up here.
OFFSITE="$HERE/jsonl-hourly-offsite.sh"
stale_def="$(sed -n 's/^STALE_SOURCE_S="${JHO_STALE_SOURCE_S:-\([0-9][0-9]*\)}".*/\1/p' "$OFFSITE" 2>/dev/null | head -1)"
crit_def="$(sed -n 's/^JEX_CRITICAL_DISK_INTERVAL_S="${JEX_CRITICAL_DISK_INTERVAL_S:-\([0-9][0-9]*\)}"$/\1/p' "$SCRIPT" | head -1)"
low_def="$(sed -n 's/^JEX_LOW_DISK_INTERVAL_S="${JEX_LOW_DISK_INTERVAL_S:-\([0-9][0-9]*\)}"$/\1/p' "$SCRIPT" | head -1)"
ord_int="$(dur_s "$(order_field "$ORDER_TOML" interval)")" || ord_int=""
ord_to="$(dur_s "$(order_field "$ORDER_TOML" timeout)")" || ord_to=""
if [ -z "$stale_def" ] || [ -z "$crit_def" ] || [ -z "$low_def" ] || [ -z "$ord_int" ] || [ -z "$ord_to" ]; then
  bad "offsite alarm check cannot read its inputs: JHO_STALE_SOURCE_S='$stale_def' critical='$crit_def' low='$low_def' order interval='$ord_int' timeout='$ord_to' — the comparison is not made, and not assumed"
else
  worst=$((crit_def + ord_int + ord_to))
  [ "$worst" -lt "$stale_def" ] \
    && ok "longest skip (critical ${crit_def}s + tick ${ord_int}s + run ${ord_to}s = ${worst}s) is under the offsite 'fonte parada' alarm (${stale_def}s)" \
    || bad "longest skip ${worst}s is NOT under the offsite alarm ${stale_def}s: the cadence guard would raise 'fonte parada'"
  [ "$low_def" -lt "$crit_def" ] && [ "$low_def" -gt "$ord_int" ] \
    && ok "intervals are ordered: tick ${ord_int}s < low-disk ${low_def}s < critical ${crit_def}s" \
    || bad "intervals out of order: tick ${ord_int}s, low ${low_def}s, critical ${crit_def}s"
fi
# the CRITICAL class is the guard's own: same variable, same default (jsonl-archive-compact.sh does the same check)
GUARD="$HERE/../../../../scripts/dolt-disk-floor-guard.sh"
gdef="$(sed -n 's/^FLOOR_CRITICAL_GB="${DOLT_DISK_FLOOR_CRITICAL_GB:-\([0-9][0-9]*\)}".*/\1/p' "$GUARD" 2>/dev/null | head -1)"
edef="$(sed -n 's/^JEX_DOLT_CRITICAL_GB="${DOLT_DISK_FLOOR_CRITICAL_GB:-\([0-9][0-9]*\)}"$/\1/p' "$SCRIPT" | head -1)"
if [ -z "$gdef" ] || [ -z "$edef" ]; then
  bad "Dolt CRITICAL default: cannot read both sides (guard='$gdef' exporter='$edef' from $GUARD) — the exporter's floor can no longer be checked against the guard's"
else
  [ "$gdef" = "$edef" ] && ok "Dolt CRITICAL default: exporter ${edef} GiB = dolt-disk-floor-guard.sh ${gdef} GiB (same variable, same default)" || bad "Dolt CRITICAL default drifted: exporter ${edef} GiB vs guard ${gdef} GiB"
fi

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
