#!/usr/bin/env bash
# gate-rea-check.selftest.sh (ga-jdzri9, epic ga-oe7o1p)
#
# Proves the gate's REA check: a diff that touches a source reader on config/rea_paths.txt needs a comment with a line starting `REA:` on the source
# bead; warn-only (label rea:missing + one comment) for GATE_REA_WARN_DAYS, then a reviewer PASS becomes a FAIL of class `hold`.
#
# Hermetic: a fake `bd` on PATH (state in a temp dir), a temp city, a temp stamp / off-flag / path list. It never touches a real bead, the real
# config stamp or the network. The lib is exercised under /bin/bash (3.2, the shell the dispatcher's launchd job runs) with `set -euo pipefail`.
#
# What is executed, not described:
#   1. the lib parses (bash -n under 3.2 and the current bash) and sources under the dispatcher's flags without running anything;
#   2. the comment scanner (gate-rea-comments.py): what answers the rule, what is a credential / CPF / CNPJ shape, what is NOT (dates, ids, prose),
#      and the three answers of every read (rows / none / could not read);
#   3. the switch (env wins, an unreadable override is OFF), the phase (warn -> enforce, an unreadable stamp or day count stays warn);
#   4. the path list (per rig, globs, malformed lines counted, quoted names, the real shipped list: scrapers yes, generic *_client.py no);
#   5. the verdicts off / na / pass / missing / secret / unknown against the fake bd, and that no verdict leaks into the next run;
#   6. what is written to the bead: label + ONE comment, once per bead and label, comment before label, nothing on na / pass / unknown / off;
#      and that the gate's own comment can never answer the rule;
#   7. the blocking half: only the enforce phase, only on missing / secret, reading only;
#   8. the dispatcher's LIVE blocks (lib load, Step 5 call, finalize downgrade), extracted by SELFTEST-EXTRACT sentinels and run under /bin/bash 3.2;
#   9. drift guards on where those blocks sit;
#  10. mutation checks of THIS harness: each mutant of the lib / scanner / dispatcher must turn this file red (skipped with --no-mutants).
#
# Secret-shaped fixtures are built from pieces at run time so no literal credential sits in this file.
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF="${BASH_SOURCE[0]}"
SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"
ASSETS="${REA_ST_ASSETS:-$SELF_DIR}"                        # a mutant run points this at a patched copy of lib + scanner
DISPATCHER="${REA_ST_DISPATCHER:-$SELF_DIR/quality-gate-dispatcher.sh}"
REAL_LIST="${REA_ST_PATHS:-$SELF_DIR/../../../config/rea_paths.txt}"
LIB="$ASSETS/gate-rea-check.lib.sh"
SCAN="$ASSETS/gate-rea-comments.py"
B32=/bin/bash                                               # the daemon's shell (macOS bash 3.2) - never the first `bash` on PATH
RUN_MUTANTS=1
[ "${1:-}" = "--no-mutants" ] && RUN_MUTANTS=0

PASS=0; FAIL=0
TAB=$'\t'
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (no '$3' in: $2)" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1 (found '$3' in: $2)" ;; *) ok "$1" ;; esac; }

echo "== gate-rea-check.selftest =="
for f in "$LIB" "$SCAN" "$DISPATCHER" "$REAL_LIST"; do
  if [ -r "$f" ]; then ok "present: $(basename "$f")"; else bad "missing: $f"; fi
done
[ -x "$B32" ] || { echo "FATAL: $B32 not found"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found"; exit 2; }

T=$(mktemp -d "${TMPDIR:-/tmp}/rea-selftest.XXXXXX") || { echo "FATAL: mktemp"; exit 2; }
trap 'rm -rf "$T"' EXIT
FB="$T/fb"; CITY="$T/city"; LIST="$T/rea_paths.txt"; STAMP="$T/stamp"; OFFFLAG="$T/off.flag"; QGLOG="$T/qg.log"
mkdir -p "$T/bin" "$T/home" "$FB" "$CITY/.gc"
unset GATE_REA_CHECK GATE_REA_WARN_DAYS GATE_REA_PATHS_FILE GATE_REA_STAMP_FILE GATE_REA_OFF_FLAG QG_LOG
export FAKE_BD_DIR="$FB" GC_CITY="$CITY" GATE_REA_PATHS_FILE="$LIST" GATE_REA_STAMP_FILE="$STAMP" GATE_REA_OFF_FLAG="$OFFFLAG"
export PATH="$T/bin:$PATH" HOME="$T/home"

# ── fake bd ────────────────────────────────────────────────────────────────────────────────────────────────────────────
# State lives in $FAKE_BD_DIR. comments.<id>.json = what `bd comments <id> --json` prints (absent = bd fails); labels.<id> = one label per line;
# added.<id> = one line per comment written; calls.log = every call. Switches (files): comments.down, comments.empty, comments.garbage, show.fail,
# show.garbage, comment.fail, label.fail.
cat > "$T/bin/bd" <<'FAKEBD'
#!/bin/bash
FB="${FAKE_BD_DIR:?}"
[ "${1:-}" = "-C" ] && shift 2
cmd="${1:-}"; shift
printf '%s %s\n' "$cmd" "$*" >> "$FB/calls.log"
case "$cmd" in
  comments)
    id="$1"
    [ -e "$FB/comments.down" ] && exit 1
    [ -e "$FB/comments.empty" ] && exit 0
    [ -e "$FB/comments.garbage" ] && { echo 'this is not json'; exit 0; }
    [ -e "$FB/comments.$id.json" ] || exit 1
    cat "$FB/comments.$id.json" ;;
  show)
    id="$1"
    [ -e "$FB/show.fail" ] && exit 1
    [ -e "$FB/show.garbage" ] && { echo 'garbage'; exit 0; }
    [ -e "$FB/labels.$id" ] || : > "$FB/labels.$id"
    jq -n --arg id "$id" --rawfile l "$FB/labels.$id" '[{id:$id,labels:($l|split("\n")|map(select(.!="")))}]' ;;
  comment)
    [ -e "$FB/comment.fail" ] && exit 1
    printf '%s\n' "$2" >> "$FB/added.$1" ;;
  label)
    [ "$1" = "add" ] || exit 0
    [ -e "$FB/label.fail" ] && exit 1
    printf '%s\n' "$3" >> "$FB/labels.$2" ;;
  *) exit 64 ;;
esac
FAKEBD
chmod +x "$T/bin/bd"

reset_world() {
  rm -rf "$FB"; mkdir -p "$FB"
  rm -f "$STAMP" "$OFFFLAG" "$QGLOG"
  unset GATE_REA_CHECK GATE_REA_WARN_DAYS QG_LOG
}
stamp_age_days() { printf '%s\n' "$(( $(date +%s) - $1 * 86400 ))" > "$STAMP"; }
# put_comments <bead> [<id> <text>]...  - what `bd comments <bead> --json` will print
put_comments() {
  local bead="$1"; shift
  jq -n '$ARGS.positional | [ range(0; length; 2) as $i | {id: .[$i], text: .[$i+1]} ]' --args "$@" > "$FB/comments.$bead.json"
}
writes() { # number of bd WRITE calls so far (comment / label add)
  [ -e "$FB/calls.log" ] || { echo 0; return 0; }
  grep -c '^comment \|^label add ' "$FB/calls.log" || true
}
added_count() { [ -e "$FB/added.$1" ] && wc -l < "$FB/added.$1" | tr -d ' ' || echo 0; }
labels_of() { [ -e "$FB/labels.$1" ] && tr '\n' ',' < "$FB/labels.$1" || true; }

# r32 <body> - body runs under /bin/bash 3.2 with the dispatcher's strict flags and the lib sourced. Output (stdout+stderr) -> R_OUT, status -> R_RC.
r32() {
  R_OUT=$("$B32" -c "set -euo pipefail; source '$LIB'; $1" 2>&1); R_RC=$?
}
field() { printf '%s\n' "$R_OUT" | sed -n "s/^$1=//p" | head -n 1; }

# Fixture pieces (assembled here so the file carries no literal credential):
P_AK="AK""IA"; P_JW="ey""J"; P_GH="gh""p_"
SECRET_KEY="${P_AK}ABCDEFGHIJKLMNOP"
SECRET_JWT="${P_JW}hbGciOiJIUzI1NiJ9.${P_JW}zdWIiOiIxMjM0NTY3ODkw.SflKxwRJSMeKKF2QT4fwpM"
SECRET_BEARER="Bea""rer abcdefghijklmnopqrstuvwxyz0123456789"
SECRET_COOKIE="Coo""kie: sessionid=a1b2c3d4e5f6g7h8"
SECRET_NAMED="to""ken=a1b2c3d4e5f6g7h8i9j0"
SECRET_URLCRED="postgres://admin:s3cr3tpass@db.example.com/x"
SECRET_PEM="-----BEGIN RSA PRIV""ATE KEY-----"
CPF_BARE="52998""224725"; CPF_FMT="529.998.224-72"
CPF_FMT_VALID="529.982.247-25"
CNPJ_BARE="11222""333000181"; CNPJ_FMT="11.222.333/0001-81"
CLEAN_REA="REA: target=portal.example/api/v2/list, command=curl -s with the browser headers, found: 12 records, because the list endpoint is public; checked 2026-10-12 at 14:03"

# ── 1. the lib parses and sources under the dispatcher's flags ─────────────────────────────────────────────────────────────
echo "── 1. lib: parses, sources under set -euo pipefail on bash 3.2, runs nothing at source time ──"
if "$B32" -n "$LIB"; then ok "lib passes bash -n on $B32"; else bad "lib bash -n FAILED on $B32"; fi
if bash -n "$LIB"; then ok "lib passes bash -n on the current bash"; else bad "lib bash -n FAILED on the current bash"; fi
if python3 -I -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$SCAN"; then ok "scanner is valid python"; else bad "scanner does not parse"; fi
reset_world
r32 'echo SOURCED=1; echo DIR=$GATE_REA_DIR; type gate_rea_step5 >/dev/null 2>&1 && echo F5=yes; type gate_rea_finalize_block >/dev/null 2>&1 && echo FF=yes'
eq "sourcing under 3.2 + set -euo pipefail succeeds" "$R_RC" "0"
eq "GATE_REA_DIR is the lib's own directory" "$(field DIR)" "$ASSETS"
eq "gate_rea_step5 is defined" "$(field F5)" "yes"
eq "gate_rea_finalize_block is defined" "$(field FF)" "yes"
eq "sourcing wrote nothing to bd and created no stamp" "$( [ -e "$FB/calls.log" ] && echo calls || echo none )$( [ -e "$STAMP" ] && echo stamp || echo nostamp )" "nonenostamp"

# ── 2. the comment scanner ────────────────────────────────────────────────────────────────────────────────────────────────
echo "── 2. scanner: what answers the rule, what is a credential / CPF / CNPJ shape, what is not ──"
scan_json() { printf '%s' "$1" | python3 -I "$SCAN"; SC_RC=$?; }
scan_text() { # scan_text <text> -> stdout of the scanner for a one-comment list
  jq -n --arg t "$1" '[{id:"c1",text:$t}]' | python3 -I "$SCAN"
}
shape_case() { # shape_case <label> <text> <expected labels | "-" clean | "NONE" no row>
  local out want
  out=$(scan_text "$2")
  if [ "$3" = "NONE" ]; then want=""; else want="c1${TAB}$3"; fi
  eq "$1" "$out" "$want"
}
shape_case "clean REA with a date and a time is an answer and clean" "$CLEAN_REA" "-"
shape_case "REA after leading blanks answers" "   REA: n/a - docs only" "-"
shape_case "REA on a later line answers" "$(printf 'did the work\nREA: target X, command Y, found, why Z')" "-"
shape_case "an empty REA: is not an answer" "REA:" "NONE"
shape_case "REA: followed by blanks only is not an answer" "REA:    " "NONE"
shape_case "lowercase rea: is not an answer" "rea: target X" "NONE"
shape_case "REA mid-line is not an answer" "see REA: target X" "NONE"
shape_case "no REA at all is not an answer" "fixed the parser" "NONE"
shape_case "an epoch and an id are not CPF/CNPJ" "REA: ts 1760000000, id 20261012153, run 20261012153044" "-"
shape_case "prose that names tokens and cookies is clean" "REA: no token needed, no cookie, session not required; found: public" "-"
shape_case "a short or path value after token= is clean" "REA: token=short and token=/var/run/thing/path" "-"
shape_case "a bare 11-digit number with bad check digits is clean" "REA: id 12345678900" "-"
shape_case "a bare 14-digit number with bad check digits is clean" "REA: id 12345678000199" "-"
shape_case "an access key shape is a key" "REA: used $SECRET_KEY here" "key"
shape_case "a JWT is a jwt" "REA: header $SECRET_JWT" "jwt"
shape_case "a bearer value is bearer" "REA: sent $SECRET_BEARER" "bearer"
shape_case "a cookie header (with a named session id) is cookie + credential" "REA: sent $SECRET_COOKIE" "cookie,credential"
shape_case "a named token with a mixed 16+ char value is credential" "REA: $SECRET_NAMED" "credential"
shape_case "credentials in a URL are url-credentials" "REA: $SECRET_URLCRED" "url-credentials"
shape_case "a PEM header is private-key" "REA: $SECRET_PEM" "private-key"
shape_case "a formatted CPF is cpf" "REA: person $CPF_FMT_VALID" "cpf"
shape_case "a formatted CPF is cpf even with bad check digits" "REA: person $CPF_FMT" "cpf"
shape_case "a bare valid CPF is cpf" "REA: person $CPF_BARE" "cpf"
shape_case "a formatted CNPJ is cnpj" "REA: company $CNPJ_FMT" "cnpj"
shape_case "a bare valid CNPJ is cnpj" "REA: company $CNPJ_BARE" "cnpj"
shape_case "two shapes in one comment are both named, sorted" "REA: $SECRET_KEY and $CPF_FMT_VALID" "cpf,key"
out=$(scan_text "REA: used $SECRET_KEY and $SECRET_JWT and $CPF_FMT_VALID")
hasnt "the scanner output never carries a matched value (key)" "$out" "$SECRET_KEY"
hasnt "the scanner output never carries a matched value (jwt)" "$out" "$SECRET_JWT"
hasnt "the scanner output never carries a matched value (cpf)" "$out" "$CPF_FMT_VALID"

out=$(printf '[]' | python3 -I "$SCAN"); rc=$?
eq "an empty list is read: exit 0, no rows" "$rc:$out" "0:"
out=$(printf 'this is not json' | python3 -I "$SCAN"); rc=$?
eq "stdin that is not JSON is unreadable: exit 2" "$rc:$out" "2:"
out=$(printf '{"id":"x","text":"REA: y"}' | python3 -I "$SCAN"); rc=$?
eq "a JSON object (not a list) is unreadable: exit 2" "$rc:$out" "2:"
out=$(printf '' | python3 -I "$SCAN"); rc=$?
eq "empty stdin is unreadable: exit 2" "$rc:$out" "2:"
out=$(printf '[{"id":"c1"}]' | python3 -I "$SCAN"); rc=$?
eq "an element with no readable text and no answer elsewhere is unreadable: exit 2" "$rc:$out" "2:"
out=$(printf '[{"id":"c1"},{"id":"c2","text":"hello"}]' | python3 -I "$SCAN"); rc=$?
eq "an unreadable element beside a readable non-answer is unreadable: exit 2" "$rc:$out" "2:"
out=$(printf '[{"id":"c1"},{"id":"c2","text":"REA: n/a - docs"}]' | python3 -I "$SCAN"); rc=$?
eq "an unreadable element beside an answering one is read: exit 0 with the row" "$rc:$out" "0:c2${TAB}-"
out=$(printf '[{"id":"c1","text":"REA: a"},{"id":"c2","text":"nope"},{"id":"c3","text":"REA: b"}]' | python3 -I "$SCAN"); rc=$?
eq "answering comments come back in bd's order" "$rc:$out" "0:c1${TAB}-"$'\n'"c3${TAB}-"
out=$(printf '[{"id":"c1","body":"REA: via body key"}]' | python3 -I "$SCAN"); rc=$?
eq "the body key is read when there is no text key" "$rc:$out" "0:c1${TAB}-"

# ── 3. the switch ─────────────────────────────────────────────────────────────────────────────────────────────────────────
echo "── 3. switch: env wins, an unreadable override is OFF ──"
reset_world
sw() { r32 "$1; echo SW=\$(gate_rea_switch_state)"; field SW; }
eq "no env, no flag -> on" "$(sw ':')" "on"
eq "GATE_REA_CHECK=1 -> on" "$(sw 'export GATE_REA_CHECK=1')" "on"
eq "GATE_REA_CHECK=0 -> off" "$(sw 'export GATE_REA_CHECK=0')" "off"
eq "GATE_REA_CHECK=yes -> env-invalido (OFF, said so)" "$(sw 'export GATE_REA_CHECK=yes')" "env-invalido"
eq "GATE_REA_CHECK=true -> env-invalido" "$(sw 'export GATE_REA_CHECK=true')" "env-invalido"
: > "$OFFFLAG"
eq "off-flag file present, no env -> off" "$(sw ':')" "off"
eq "env 1 beats the off-flag file" "$(sw 'export GATE_REA_CHECK=1')" "on"
rm -f "$OFFFLAG"; ln -s "$T/nowhere" "$OFFFLAG"
eq "a dangling symlink as the off-flag still counts as present -> off" "$(sw ':')" "off"
rm -f "$OFFFLAG"

# ── 4. the phase ──────────────────────────────────────────────────────────────────────────────────────────────────────────
echo "── 4. phase: warn for GATE_REA_WARN_DAYS from the first run, then enforce; unreadable stays warn ──"
ph() { r32 "$1; gate_rea_phase; echo PHASE=\$GATE_REA_PHASE; echo AT=\$GATE_REA_ENFORCE_AT; echo WHY=\$GATE_REA_PHASE_WHY"; }
reset_world
before=$(date +%s)
ph ':'
eq "first call: warn" "$(field PHASE)" "warn"
[ -e "$STAMP" ] && ok "first call writes the stamp" || bad "first call did not write the stamp"
at=$(field AT); want=$((before + 14 * 86400))
if [ -n "$at" ] && [ "$at" -ge "$want" ] && [ "$at" -le "$((want + 30))" ]; then ok "enforce date is stamp + 14 days"; else bad "enforce date wrong (got '$at', want ~$want)"; fi
stamp_age_days 13; ph ':'
eq "13 days after the stamp: still warn" "$(field PHASE)" "warn"
stamp_age_days 15; ph ':'
eq "15 days after the stamp: enforce" "$(field PHASE)" "enforce"
stamp_age_days 3; ph 'export GATE_REA_WARN_DAYS=2'
eq "GATE_REA_WARN_DAYS=2, stamp 3 days old: enforce" "$(field PHASE)" "enforce"
stamp_age_days 0; ph 'export GATE_REA_WARN_DAYS=0'
eq "GATE_REA_WARN_DAYS=0: enforce at once" "$(field PHASE)" "enforce"
stamp_age_days 40; ph 'export GATE_REA_WARN_DAYS=abc'
eq "a day count that is not a number: warn, even with an old stamp" "$(field PHASE)" "warn"
has "...and it says why" "$(field WHY)" "not a whole number"
stamp_age_days 40; ph 'export GATE_REA_WARN_DAYS=12345'
eq "a 5-digit day count: warn" "$(field PHASE)" "warn"
echo "garbage" > "$STAMP"; ph ':'
eq "an unreadable stamp: warn, never enforce" "$(field PHASE)" "warn"
has "...and it says why" "$(field WHY)" "unreadable"
: > "$STAMP"; ph ':'
eq "an empty stamp: warn" "$(field PHASE)" "warn"
printf '%s\n' "99999999999" > "$STAMP"; ph ':'
eq "an 11-digit stamp: warn" "$(field PHASE)" "warn"
rm -f "$STAMP"; mkdir -p "$T/ro"; chmod 555 "$T/ro"
if [ "$(id -u)" = "0" ]; then
  ok "(skipped: running as root, a read-only directory does not stop root)"
else
  r32 "export GATE_REA_STAMP_FILE='$T/ro/sub/stamp'; gate_rea_phase; echo PHASE=\$GATE_REA_PHASE; echo WHY=\$GATE_REA_PHASE_WHY"
  eq "a stamp that cannot be written: warn" "$(field PHASE)" "warn"
  has "...and it says so" "$(field WHY)" "could not be recorded"
fi
chmod 755 "$T/ro"

# ── 5. the path list ──────────────────────────────────────────────────────────────────────────────────────────────────────
echo "── 5. path list: per rig, globs, malformed lines counted, quoted names ──"
cat > "$LIST" <<'EOF'
# a comment line
rigA scrapers/*
rigA tools/fetch.py   # trailing comment
rigB other/*

malformed-one-field
rigA three fields here
EOF
pm() { # pm <rig> <files> -> RC, MATCHED (joined by +), SKIPPED
  r32 "gate_rea_paths_match '$1' \"\$(printf '%b' '$2')\" && rc=0 || rc=\$?; echo RC=\$rc; echo M=\$(printf '%s' \"\$GATE_REA_MATCHED_LIST\" | tr '\n' '+'); echo SK=\$GATE_REA_PATHS_SKIPPED"
}
pm rigA 'scrapers/a/scraper.py\nREADME.md\ntools/fetch.py\nother/z.py'
eq "rigA: glob + exact entries match, other rig's entries do not" "$(field M)" "scrapers/a/scraper.py+tools/fetch.py+"
eq "rc 0 when the list was read" "$(field RC)" "0"
eq "two malformed list lines are counted" "$(field SK)" "2"
pm rigB 'scrapers/a/scraper.py\nother/z.py'
eq "rigB sees only its own entries" "$(field M)" "other/z.py+"
pm rigC 'scrapers/a/scraper.py'
eq "a rig with no entry is never checked: nothing matches, rc 0" "$(field RC):$(field M)" "0:"
pm rigA ''
eq "no changed files: nothing matches, rc 0" "$(field RC):$(field M)" "0:"
pm rigA '"scrapers/caf\\303\\251/scraper.py"'
eq "a git-quoted name still matches on its ASCII prefix" "$(field M)" "scrapers/caf\\303\\251/scraper.py+"
r32 "export GATE_REA_PATHS_FILE='$T/does-not-exist'; gate_rea_paths_match rigA 'scrapers/a.py' && rc=0 || rc=\$?; echo RC=\$rc"
eq "a missing list is rc 2 (could not tell), not 'nothing matches'" "$(field RC)" "2"
mkdir -p "$T/listdir"
r32 "export GATE_REA_PATHS_FILE='$T/listdir'; gate_rea_paths_match rigA 'scrapers/a.py' && rc=0 || rc=\$?; echo RC=\$rc"
eq "a list that is a directory is rc 2" "$(field RC)" "2"

echo "── 5b. the shipped list (config/rea_paths.txt) ──"
rpm() { r32 "export GATE_REA_PATHS_FILE='$REAL_LIST'; gate_rea_paths_match '$1' \"\$(printf '%b' '$2')\" && rc=0 || rc=\$?; echo RC=\$rc; echo M=\$(printf '%s' \"\$GATE_REA_MATCHED_LIST\" | tr '\n' '+'); echo SK=\$GATE_REA_PATHS_SKIPPED"; }
rpm property_scrapers 'scrapers/alfenas/scraper.py'
eq "property_scrapers: a per-source scraper is on the list" "$(field M)" "scrapers/alfenas/scraper.py+"
eq "the shipped list has no malformed line" "$(field SK)" "0"
rpm property_scrapers 'lib/leilao_common.py'
eq "property_scrapers: a source-specific helper outside scrapers/ is on the list" "$(field M)" "lib/leilao_common.py+"
rpm property_scrapers 'lib/some_client.py\nlib/http_client.py\nREADME.md\ntests/test_x.py'
eq "property_scrapers: a generic *_client.py, a README and a test are NOT on the list" "$(field M)" ""
rpm whatsapp_automation 'daemons/md_usage_scraper.py\nprocesso_lookup/pdpj_api.py'
eq "whatsapp_automation: external-source readers are on the list" "$(field M)" "daemons/md_usage_scraper.py+processo_lookup/pdpj_api.py+"
rpm whatsapp_automation 'lib/whapi_client.py\nlib/pipedrive_client.py\nlib/assertiva_client.py'
eq "whatsapp_automation: clients of paid / documented APIs are NOT on the list" "$(field M)" ""
rpm whatsapp_automation 'scrapers/alfenas/scraper.py'
eq "a property_scrapers path in the whatsapp_automation rig is not matched (the list is per rig)" "$(field M)" ""
rpm gascity 'packs/town-deltas/assets/quality-gate-dispatcher.sh'
eq "the gascity rig has no entry: never checked" "$(field M)" ""
if grep -q '_client\.py' <(sed 's/#.*//' "$REAL_LIST"); then bad "the shipped list names a *_client.py"; else ok "the shipped list names no *_client.py"; fi

# ── 6. the verdicts ───────────────────────────────────────────────────────────────────────────────────────────────────────
echo "── 6. gate_rea_check: off / na / pass / missing / secret / unknown, and no leak between runs ──"
cat > "$LIST" <<'EOF'
rigA scrapers/*
EOF
FILES_HIT=$'scrapers/a/scraper.py\nREADME.md'
FILES_MISS=$'README.md\ndocs/x.md'
ck() { # ck <setup> [files] [rig] -> VERDICT / PHASE / MATCHED / FIRST / DETAIL / CID / SHAPES
  local f="${2-$FILES_HIT}" rig="${3-rigA}"
  r32 "$1; gate_rea_check '$rig' '$CITY' 'b-1' \"\$(printf '%s' '$f')\"; echo VERDICT=\$GATE_REA_VERDICT; echo PHASE=\$GATE_REA_PHASE; echo MATCHED=\$GATE_REA_MATCHED; echo FIRST=\$GATE_REA_FIRST; echo DETAIL=\$GATE_REA_DETAIL; echo CID=\$GATE_REA_COMMENT_ID; echo SHAPES=\$GATE_REA_SHAPES"
}
reset_world; put_comments b-1 c1 "worked on it"
ck 'export GATE_REA_CHECK=0'
eq "switch off -> verdict off" "$(field VERDICT)" "off"
eq "switch off -> bd was not called at all" "$( [ -e "$FB/calls.log" ] && echo called || echo none )" "none"
ck 'export GATE_REA_CHECK=maybe'
eq "an unreadable switch -> verdict off" "$(field VERDICT)" "off"
has "...and the detail says the switch could not be read" "$(field DETAIL)" "switch could not be read"
ck ':' "$FILES_MISS"
eq "no changed file on the list -> na" "$(field VERDICT)" "na"
eq "na does not read the comments" "$( [ -e "$FB/calls.log" ] && echo called || echo none )" "none"
ck ':' "$FILES_HIT" "rigZ"
eq "a rig with no entry -> na" "$(field VERDICT)" "na"
ck 'export GATE_REA_PATHS_FILE=/nonexistent/list'
eq "a missing path list -> unknown (never na, never pass)" "$(field VERDICT)" "unknown"
has "...and it says the list is the problem" "$(field DETAIL)" "path list"
reset_world; put_comments b-1 c1 "worked on it" c2 "more words"
ck ':'
eq "touches the list, no REA comment -> missing" "$(field VERDICT)" "missing"
eq "missing: the first matched file is named" "$(field FIRST)" "scrapers/a/scraper.py"
eq "missing: one file matched" "$(field MATCHED)" "1"
reset_world; put_comments b-1 c1 "worked on it" c2 "$CLEAN_REA"
ck ':'
eq "a clean REA comment -> pass" "$(field VERDICT)" "pass"
eq "pass names the comment" "$(field CID)" "c2"
reset_world; put_comments b-1 c1 "REA: n/a - only the log line changed"
ck ':'
eq "the formatted exception line REA: n/a - <reason> -> pass" "$(field VERDICT)" "pass"
reset_world; put_comments b-1 c1 "REA: cmd used $SECRET_JWT and found it"
ck ':'
eq "the latest REA comment has a JWT shape -> secret" "$(field VERDICT)" "secret"
eq "secret: the shape is named" "$(field SHAPES)" "jwt"
hasnt "secret: the value is not in the detail" "$(field DETAIL)" "$SECRET_JWT"
reset_world; put_comments b-1 c1 "REA: first try $SECRET_KEY" c2 "$CLEAN_REA"
ck ':'
eq "an earlier REA comment had a shape but the latest is clean -> pass (the latest counts)" "$(field VERDICT)" "pass"
reset_world; put_comments b-1 c1 "$CLEAN_REA" c2 "REA: second try $CPF_FMT_VALID"
ck ':'
eq "the latest REA comment has a CPF shape -> secret" "$(field VERDICT)" "secret"
reset_world; touch "$FB/comments.down"
ck ':'
eq "bd comments fails -> unknown (never missing)" "$(field VERDICT)" "unknown"
reset_world; touch "$FB/comments.empty"
ck ':'
eq "bd comments prints nothing -> unknown" "$(field VERDICT)" "unknown"
reset_world; touch "$FB/comments.garbage"
ck ':'
eq "bd comments prints non-JSON -> unknown" "$(field VERDICT)" "unknown"
reset_world; printf '[{"id":"c1"}]' > "$FB/comments.b-1.json"
ck ':'
eq "a comment list whose only element is unreadable -> unknown" "$(field VERDICT)" "unknown"
reset_world; put_comments b-1 c1 "$CLEAN_REA"
r32 "gate_rea_check rigA '$CITY' '' 'scrapers/a.py'; echo V=\$GATE_REA_VERDICT"
eq "no source bead id -> unknown" "$(field V)" "unknown"
mkdir -p "$T/noscan"; cp "$LIB" "$T/noscan/"
reset_world; put_comments b-1 c1 "$CLEAN_REA"
R_OUT=$("$B32" -c "set -euo pipefail; source '$T/noscan/gate-rea-check.lib.sh'; gate_rea_check rigA '$CITY' b-1 'scrapers/a.py'; echo V=\$GATE_REA_VERDICT" 2>&1); R_RC=$?
eq "the scanner file missing -> unknown (a scan that could not run is never pass)" "$(field V)" "unknown"
reset_world; put_comments b-1 c1 "worked"
r32 "gate_rea_check rigA '$CITY' b-1 'scrapers/a/x.py'; echo V1=\$GATE_REA_VERDICT; echo F1=\$GATE_REA_FIRST; gate_rea_check rigA '$CITY' b-1 'README.md'; echo V2=\$GATE_REA_VERDICT; echo F2=\$GATE_REA_FIRST; echo C2=\$GATE_REA_COMMENT_ID; echo M2=\$GATE_REA_MATCHED"
eq "run 1 missing" "$(field V1)" "missing"
eq "run 2 na right after a missing: the verdict does not leak" "$(field V2)" "na"
eq "run 2: the first-matched file does not leak" "$(field F2)" ""
eq "run 2: the matched count does not leak" "$(field M2)" "0"

# ── 7. what is written to the bead ────────────────────────────────────────────────────────────────────────────────────────
echo "── 7. gate_rea_text / gate_rea_mark: ONE comment per bead and label, comment before label ──"
for kind in missing secret; do
  r32 "GATE_REA_PHASE=warn; GATE_REA_ENFORCE_AT=\$(( \$(date +%s) + 86400 )); GATE_REA_MATCHED=2; GATE_REA_FIRST=scrapers/a.py; GATE_REA_COMMENT_ID=c9; GATE_REA_SHAPES=jwt; gate_rea_text $kind some/branch b-1"
  txt="$R_OUT"
  eq "gate text ($kind) is one line" "$(printf '%s\n' "$txt" | wc -l | tr -d ' ')" "1"
  case "$txt" in *\\*) bad "gate text ($kind) carries a backslash (the FAIL path echoes with -e)" ;; *) ok "gate text ($kind) carries no backslash" ;; esac
  out=$(scan_text "$txt")
  eq "gate text ($kind) does not answer the rule by itself" "$out" ""
done
r32 "GATE_REA_PHASE=warn; GATE_REA_ENFORCE_AT=1900000000; GATE_REA_MATCHED=2; GATE_REA_FIRST=scrapers/a.py; gate_rea_text missing some/branch b-1"
has "warn text names the enforce date" "$R_OUT" "a warning until 2030-03-17"
has "warn text names the fix command" "$R_OUT" "bd comments add b-1"
has "warn text names the n/a exception" "$R_OUT" "REA: n/a - the reason"
r32 "GATE_REA_PHASE=enforce; GATE_REA_ENFORCE_AT=1; GATE_REA_MATCHED=2; GATE_REA_FIRST=scrapers/a.py; gate_rea_text missing some/branch b-1"
has "enforce text says the gate refuses the PASS" "$R_OUT" "refuses the PASS until this is fixed"
r32 "GATE_REA_PHASE=warn; GATE_REA_ENFORCE_AT=; gate_rea_when"
eq "no enforce date -> a phrase, not an empty string" "$R_OUT" "the end of the warn window"

reset_world
r32 "gate_rea_mark '$CITY' b-1 rea:missing 'hello'"
eq "mark on a bead without the label -> done" "$R_OUT" "done"
eq "...one comment written" "$(added_count b-1)" "1"
eq "...the label written" "$(labels_of b-1)" "rea:missing,"
r32 "gate_rea_mark '$CITY' b-1 rea:missing 'hello again'"
eq "mark again -> already" "$R_OUT" "already"
eq "...no second comment" "$(added_count b-1)" "1"
reset_world; touch "$FB/comment.fail"
r32 "gate_rea_mark '$CITY' b-1 rea:missing 'hello'"
eq "a comment that fails -> failed" "$R_OUT" "failed"
eq "...and NO label (so the next sweep tries again)" "$(labels_of b-1)" ""
reset_world; touch "$FB/label.fail"
r32 "gate_rea_mark '$CITY' b-1 rea:missing 'hello'"
eq "a label that fails after the comment -> failed" "$R_OUT" "failed"
reset_world; touch "$FB/show.fail"
r32 "gate_rea_mark '$CITY' b-1 rea:missing 'hello'"
eq "bd show fails -> unreadable" "$R_OUT" "unreadable"
eq "...and nothing was written" "$(writes)" "0"
reset_world; touch "$FB/show.garbage"
r32 "gate_rea_mark '$CITY' b-1 rea:missing 'hello'"
eq "bd show prints garbage -> unreadable" "$R_OUT" "unreadable"
eq "...and nothing was written" "$(writes)" "0"
r32 "gate_rea_mark '$CITY' '' rea:missing 'hello'"
eq "an empty bead id -> unreadable" "$R_OUT" "unreadable"

echo "── 7b. gate_rea_step5: label + one comment, once; nothing under doubt ──"
st5() { r32 "$1; gate_rea_step5 rigA '$CITY' b-1 \"\$(printf '%s' '${2-$FILES_HIT}')\" some/branch mk-1; echo RC=\$?"; }
reset_world; put_comments b-1 c1 "worked on it"
st5 ':'
eq "step5 on a missing REA never fails the caller" "$(field RC)" "0"
eq "step5 missing -> label rea:missing" "$(labels_of b-1)" "rea:missing,"
eq "step5 missing -> exactly one comment" "$(added_count b-1)" "1"
has "the comment is the REA-CHECK text" "$(cat "$FB/added.b-1")" "REA-CHECK (ga-jdzri9"
st5 ':'
eq "step5 again (a gate-fix re-run) -> still one comment" "$(added_count b-1)" "1"
has "step5 again says 'already' in the log" "$R_OUT" "rea:missing: already"
st5 ':' "$FILES_MISS"
eq "step5 on a diff off the list writes nothing more" "$(added_count b-1)" "1"
reset_world; put_comments b-1 c1 "worked on it"
st5 ':' "$FILES_MISS"
eq "step5 na -> no write at all" "$(writes)" "0"
eq "step5 na -> no bd call at all" "$( [ -e "$FB/calls.log" ] && echo called || echo none )" "none"
reset_world; put_comments b-1 c1 "$CLEAN_REA"
st5 ':'
eq "step5 pass -> no write" "$(writes)" "0"
has "step5 pass says so in the log" "$R_OUT" "is clean"
reset_world; put_comments b-1 c1 "REA: $SECRET_KEY"
st5 ':'
eq "step5 secret -> label rea:secret-in-comment" "$(labels_of b-1)" "rea:secret-in-comment,"
eq "step5 secret -> one comment" "$(added_count b-1)" "1"
hasnt "step5 secret: the value is not in the comment written to the bead" "$(cat "$FB/added.b-1")" "$SECRET_KEY"
hasnt "step5 secret: the value is not in the log line" "$R_OUT" "$SECRET_KEY"
has "step5 secret: the comment names the shape" "$(cat "$FB/added.b-1")" "shape of: key"
reset_world; touch "$FB/comments.down"
st5 ':'
eq "step5 unknown (bd comments down) -> no write" "$(writes)" "0"
has "step5 unknown says COULD NOT TELL" "$R_OUT" "COULD NOT TELL"
reset_world; put_comments b-1 c1 "worked on it"
st5 'export GATE_REA_CHECK=0'
eq "step5 with the switch off -> no bd call" "$( [ -e "$FB/calls.log" ] && echo called || echo none )" "none"
reset_world; put_comments b-1 c1 "worked on it"; touch "$FB/comment.fail"
st5 ':'
eq "step5 when the comment cannot be written -> no label, caller still ok" "$(labels_of b-1):$(field RC)" ":0"
has "...and the log says failed" "$R_OUT" "rea:missing: failed"
reset_world; put_comments b-1 c1 "REA: first $SECRET_KEY" c2 "$CLEAN_REA"
st5 ':'
has "a clean latest comment after a shaped earlier one: pass, with the NOTE" "$R_OUT" "the earlier REA comment c1 has the shape of: key"
eq "...and no write" "$(writes)" "0"

echo "── 7c. the apuração record (QG_LOG) ──"
reset_world; put_comments b-1 c1 "REA: $SECRET_KEY"
export QG_LOG="$QGLOG"
st5 ':'
unset QG_LOG
rec=$(tail -n 1 "$QGLOG" 2>/dev/null || true)
eq "one rea_check record was appended" "$(jq -r '.event' <<< "$rec" 2>/dev/null)" "rea_check"
eq "...with the verdict" "$(jq -r '.verdict' <<< "$rec" 2>/dev/null)" "secret"
eq "...the shapes" "$(jq -r '.shapes' <<< "$rec" 2>/dev/null)" "key"
eq "...the moment" "$(jq -r '.at' <<< "$rec" 2>/dev/null)" "step5"
eq "...the bead" "$(jq -r '.bead' <<< "$rec" 2>/dev/null)" "b-1"
hasnt "...and never the value" "$(cat "$QGLOG")" "$SECRET_KEY"
reset_world; put_comments b-1 c1 "worked"
st5 ':' "$FILES_MISS"
eq "step5 na writes no record when QG_LOG is unset" "$( [ -e "$QGLOG" ] && echo log || echo none )" "none"

# ── 8. the blocking half ──────────────────────────────────────────────────────────────────────────────────────────────────
echo "── 8. gate_rea_finalize_block: enforce phase only, missing / secret only, read-only ──"
fb() { r32 "$1; GATE_REA_BLOCK_REASON=stale; gate_rea_finalize_block rigA '$CITY' b-1 \"\$(printf '%s' '${2-$FILES_HIT}')\" some/branch; echo REASON=\$GATE_REA_BLOCK_REASON; echo V=\$GATE_REA_VERDICT; echo P=\$GATE_REA_PHASE"; }
reset_world; put_comments b-1 c1 "worked"; stamp_age_days 20
fb ':'
eq "enforce + missing -> a block reason" "$( [ -n "$(field REASON)" ] && echo block || echo none )" "block"
eq "...phase is enforce" "$(field P)" "enforce"
has "...it says it is not a code rejection" "$(field REASON)" "not a code rejection"
has "...it names the n/a exception" "$(field REASON)" "REA: n/a - the reason"
has "...it names the branch and bead" "$(field REASON)" "some/branch"
case "$(field REASON)" in *\\*) bad "block reason carries a backslash" ;; *) ok "block reason carries no backslash" ;; esac
eq "finalize only reads: no write" "$(writes)" "0"
reset_world; put_comments b-1 c1 "worked"; stamp_age_days 2
fb ':'
eq "warn phase + missing -> no block (and the stale reason is cleared)" "$(field REASON)" ""
reset_world; put_comments b-1 c1 "$CLEAN_REA"; stamp_age_days 20
fb ':'
eq "enforce + pass -> no block" "$(field REASON)" ""
reset_world; put_comments b-1 c1 "REA: n/a - only a log line"; stamp_age_days 20
fb ':'
eq "enforce + the n/a exception line -> no block" "$(field REASON)" ""
reset_world; put_comments b-1 c1 "worked"; stamp_age_days 20
fb ':' "$FILES_MISS"
eq "enforce + diff off the list (na) -> no block" "$(field REASON)" ""
reset_world; touch "$FB/comments.down"; stamp_age_days 20
fb ':'
eq "enforce + bd comments down (unknown) -> no block" "$(field REASON)" ""
eq "...the verdict is unknown" "$(field V)" "unknown"
reset_world; put_comments b-1 c1 "worked"; stamp_age_days 20
fb 'export GATE_REA_CHECK=0'
eq "enforce + switch off -> no block" "$(field REASON)" ""
reset_world; put_comments b-1 c1 "worked"; stamp_age_days 20
fb 'export GATE_REA_PATHS_FILE=/nonexistent/list'
eq "enforce + path list missing (unknown) -> no block" "$(field REASON)" ""
reset_world; put_comments b-1 c1 "worked"; echo garbage > "$STAMP"
fb ':'
eq "an unreadable stamp (warn) + missing -> no block" "$(field REASON)" ""
reset_world; put_comments b-1 c1 "REA: $SECRET_JWT"; stamp_age_days 20
fb ':'
eq "enforce + secret -> a block reason" "$( [ -n "$(field REASON)" ] && echo block || echo none )" "block"
has "...it names the comment" "$(field REASON)" "(c1)"
has "...it names the shape" "$(field REASON)" "jwt"
hasnt "...and never the value" "$(field REASON)" "$SECRET_JWT"
eq "finalize (secret) only reads: no write" "$(writes)" "0"

# ── 9. the dispatcher's live blocks ───────────────────────────────────────────────────────────────────────────────────────
echo "── 9. dispatcher blocks, extracted by SELFTEST-EXTRACT and run under $B32 with set -euo pipefail ──"
extract_block() { sed -n "/# SELFTEST-EXTRACT ${2}: BEGIN/,/# SELFTEST-EXTRACT ${2}: END/p" "$1" | sed '1d;$d'; }
LOAD_BLOCK=$(extract_block "$DISPATCHER" rea-lib-load)
STEP5_BLOCK=$(extract_block "$DISPATCHER" rea-step5)
FIN_BLOCK=$(extract_block "$DISPATCHER" rea-finalize)
for n in LOAD_BLOCK STEP5_BLOCK FIN_BLOCK; do
  if [ -n "${!n}" ]; then ok "extracted $n ($(printf '%s\n' "${!n}" | wc -l | tr -d ' ') lines)"; else bad "could not extract $n (sentinel renamed / removed?)"; fi
done

CITYX="$T/cityx"; mkdir -p "$CITYX/packs/town-deltas/assets"
load_run() { # load_run <city> -> runs the lib-load block; prints OK / FN / AFTER
  R_OUT=$("$B32" -c "set -euo pipefail; GC_CITY='$1'; $LOAD_BLOCK
echo LIBOK=\$GATE_REA_LIB_OK; if type gate_rea_check >/dev/null 2>&1; then echo FN=yes; else echo FN=no; fi; echo AFTER=1" 2>&1); R_RC=$?
}
cp "$LIB" "$SCAN" "$CITYX/packs/town-deltas/assets/"
load_run "$CITYX"
eq "lib present: GATE_REA_LIB_OK=1, functions defined, the dispatcher goes on" "$(field LIBOK):$(field FN):$(field AFTER)" "1:yes:1"
rm -f "$CITYX/packs/town-deltas/assets/gate-rea-check.lib.sh"
load_run "$CITYX"
eq "lib missing: GATE_REA_LIB_OK=0, no functions, the dispatcher goes on" "$(field LIBOK):$(field FN):$(field AFTER)" "0:no:1"
printf 'return 1\n' > "$CITYX/packs/town-deltas/assets/gate-rea-check.lib.sh"
load_run "$CITYX"
eq "lib that returns non-zero at source time: GATE_REA_LIB_OK=0, the dispatcher goes on" "$(field LIBOK):$(field AFTER)" "0:1"

# Step 5 block: needs the lib sourced + the dispatcher's variables.
s5_run() { # s5_run <libok> <setup> <changed files>
  R_OUT=$("$B32" -c "set -euo pipefail; source '$LIB'; GATE_REA_LIB_OK=$1; GC_CITY='$CITY'; RIG=rigA; BEAD_CITY='$CITY'; BEAD_ID=b-1; BRANCH=some/branch; MARKER_ID=mk-1; CHANGED_FILES=\"\$(printf '%s' '$3')\"; $2
$STEP5_BLOCK
echo AFTER=1" 2>&1); R_RC=$?
}
reset_world; put_comments b-1 c1 "worked"
s5_run 1 ':' "$FILES_HIT"
eq "step5 block, lib ok, missing REA -> label written, the dispatcher goes on" "$(labels_of b-1):$(field AFTER)" "rea:missing,:1"
reset_world; put_comments b-1 c1 "worked"
s5_run 0 ':' "$FILES_HIT"
eq "step5 block, lib NOT loaded -> nothing written, the dispatcher goes on" "$(writes):$(field AFTER)" "0:1"
reset_world; put_comments b-1 c1 "worked"
R_OUT=$("$B32" -c "set -euo pipefail; source '$LIB'; GATE_REA_LIB_OK=1; GC_CITY='$CITY'; BRANCH=b; CHANGED_FILES='scrapers/a.py'
$STEP5_BLOCK
echo AFTER=1" 2>&1); R_RC=$?
eq "step5 block with RIG / BEAD_ID / MARKER_ID / BEAD_CITY all unset does not trip set -u" "$(field AFTER)" "1"
eq "...and writes nothing" "$(writes)" "0"
reset_world; put_comments b-1 c1 "worked"; touch "$FB/comments.down"
s5_run 1 ':' "$FILES_HIT"
eq "step5 block with bd down -> the dispatcher goes on, nothing written" "$(writes):$(field AFTER)" "0:1"

# Finalize block: the dispatcher's variables + stubs for git_rig / warn.
fin_run() { # fin_run <verdict> <libok> <bead_id> <git_mode: ok|fail> <class> -> OVERALL / CLASS / REASONS / WARN lines
  R_OUT=$("$B32" -c "set -euo pipefail; source '$LIB'
warn() { echo \"WARN: \$*\"; }
git_rig() { if [ '$4' = fail ]; then return 1; fi; printf 'scrapers/a/scraper.py\nREADME.md\n'; }
GATE_REA_LIB_OK=$2; GC_CITY='$CITY'; RIG=rigA; BEAD_CITY='$CITY'; BEAD_ID='$3'; BRANCH=some/branch; DEFAULT_BRANCH=main; BRANCH_SHA=abc123
OVERALL_VERDICT='$1'; GATE_SHA_FAIL_CLASS='$5'; FAIL_REASONS=''
$FIN_BLOCK
echo OVERALL=\$OVERALL_VERDICT; echo CLASS=\$GATE_SHA_FAIL_CLASS; echo REASONS=\$FAIL_REASONS" 2>&1); R_RC=$?
}
reset_world; put_comments b-1 c1 "worked"; stamp_age_days 20
fin_run PASS 1 b-1 ok code
eq "finalize block: PASS + enforce + missing -> FAIL" "$(field OVERALL)" "FAIL"
eq "...of class hold (not a code rejection)" "$(field CLASS)" "hold"
has "...with the REA reason as the FAIL reason" "$(field REASONS)" "REA check (ga-jdzri9)"
case "$(field REASONS)" in *\\*) bad "FAIL reason carries a backslash (echo -e)" ;; *) ok "FAIL reason carries no backslash (echo -e is safe)" ;; esac
eq "...and the block wrote nothing to the bead" "$(writes)" "0"
reset_world; put_comments b-1 c1 "worked"; stamp_age_days 2
fin_run PASS 1 b-1 ok code
eq "finalize block: warn phase -> stays PASS, class untouched" "$(field OVERALL):$(field CLASS)" "PASS:code"
reset_world; put_comments b-1 c1 "$CLEAN_REA"; stamp_age_days 20
fin_run PASS 1 b-1 ok code
eq "finalize block: enforce + clean REA -> stays PASS" "$(field OVERALL):$(field CLASS)" "PASS:code"
reset_world; put_comments b-1 c1 "worked"; stamp_age_days 20
fin_run PASS 1 b-1 fail code
eq "finalize block: git cannot list the files -> stays PASS (could not tell)" "$(field OVERALL):$(field CLASS)" "PASS:code"
has "...and the log says it could not list them" "$R_OUT" "could not list the changed files"
eq "...and bd was not asked anything" "$( [ -e "$FB/calls.log" ] && echo called || echo none )" "none"
reset_world; put_comments b-1 c1 "worked"; stamp_age_days 20
fin_run FAIL 1 b-1 ok code
eq "finalize block: an already-FAIL verdict is untouched" "$(field OVERALL):$(field CLASS)" "FAIL:code"
eq "...and bd was not asked anything" "$( [ -e "$FB/calls.log" ] && echo called || echo none )" "none"
reset_world; put_comments b-1 c1 "worked"; stamp_age_days 20
fin_run PASS 1 '' ok code
eq "finalize block: no source bead id -> stays PASS" "$(field OVERALL)" "PASS"
fin_run PASS 0 b-1 ok code
eq "finalize block: lib not loaded -> stays PASS" "$(field OVERALL)" "PASS"
reset_world; put_comments b-1 c1 "worked"; stamp_age_days 20; touch "$FB/comments.down"
fin_run PASS 1 b-1 ok code
eq "finalize block: enforce but bd comments down -> stays PASS" "$(field OVERALL):$(field CLASS)" "PASS:code"
reset_world; put_comments b-1 c1 "worked"; stamp_age_days 20
R_OUT=$("$B32" -c "set -euo pipefail; source '$LIB'; warn() { :; }; git_rig() { printf 'scrapers/a.py\n'; }
GATE_REA_LIB_OK=1; GC_CITY='$CITY'; BRANCH=b; DEFAULT_BRANCH=main; OVERALL_VERDICT=PASS; GATE_SHA_FAIL_CLASS=code; FAIL_REASONS=''
$FIN_BLOCK
echo AFTER=\$OVERALL_VERDICT" 2>&1); R_RC=$?
eq "finalize block with RIG / BEAD_ID / BEAD_CITY / BRANCH_SHA all unset does not trip set -u" "$(field AFTER)" "PASS"
R_OUT=$("$B32" -c "set -euo pipefail; source '$LIB'; warn() { :; }; git_rig() { printf 'scrapers/a.py\n'; }
GATE_REA_LIB_OK=1; GC_CITY='$CITY'; BEAD_ID=b-1; BRANCH=b; DEFAULT_BRANCH=main; OVERALL_VERDICT=PASS; GATE_SHA_FAIL_CLASS=code; FAIL_REASONS=''
$FIN_BLOCK
echo AFTER=\$OVERALL_VERDICT" 2>&1); R_RC=$?
eq "finalize block with a bead id but RIG / BEAD_CITY / BRANCH_SHA unset does not trip set -u (the rig is not checked: na)" "$(field AFTER)" "PASS"

# ── 10. drift guards ──────────────────────────────────────────────────────────────────────────────────────────────────────
echo "── 10. drift guards: where the blocks sit in the dispatcher ──"
ln_of() { grep -n -- "$1" "$DISPATCHER" | head -1 | cut -d: -f1; }
LOAD_LN=$(ln_of '^# SELFTEST-EXTRACT rea-lib-load: BEGIN')
TIER_LN=$(ln_of '^log "Tier: \$TIER  required_reviewers')
S5_LN=$(ln_of '^# SELFTEST-EXTRACT rea-step5: BEGIN')
FIN_LN=$(ln_of '^# SELFTEST-EXTRACT rea-finalize: BEGIN')
ALLPASS_LN=$(ln_of 'ALL PASS — proceeding to merge branch')
FS_LN=$(ln_of 'ga-3wgx8: .* full suite red on')
E5_LN=$(ln_of '^# ga-syxaki (E5): arm + big-diff trigger')
if [ -n "$LOAD_LN" ] && [ -n "$S5_LN" ] && [ "$LOAD_LN" -lt "$S5_LN" ]; then ok "the lib is sourced (line $LOAD_LN) before the Step 5 call (line $S5_LN)"; else bad "lib load must precede the Step 5 call (load=$LOAD_LN step5=$S5_LN)"; fi
if [ -n "$TIER_LN" ] && [ -n "$S5_LN" ] && [ "$TIER_LN" -lt "$S5_LN" ]; then ok "the Step 5 call is AFTER the tier classification (log \"Tier:\" at line $TIER_LN, call at line $S5_LN)"; else bad "the REA step must follow the tier classification (tier=$TIER_LN step5=$S5_LN)"; fi
if [ -n "$S5_LN" ] && [ -n "$E5_LN" ] && [ "$S5_LN" -lt "$E5_LN" ]; then ok "the Step 5 call is BEFORE the E5 arm decision (line $E5_LN)"; else bad "the Step 5 call must sit before the E5 arm block (step5=$S5_LN e5=$E5_LN)"; fi
if [ -n "$FIN_LN" ] && [ -n "$ALLPASS_LN" ] && [ "$FIN_LN" -lt "$ALLPASS_LN" ]; then ok "the finalize block (line $FIN_LN) runs before 'ALL PASS - proceeding to merge' (line $ALLPASS_LN)"; else bad "the REA finalize block must precede the merge (fin=$FIN_LN allpass=$ALLPASS_LN)"; fi
if [ -n "$FIN_LN" ] && [ -n "$FS_LN" ] && [ "$FS_LN" -lt "$FIN_LN" ]; then ok "the finalize block follows the full-suite downgrade (line $FS_LN)"; else bad "the REA finalize block must follow the full-suite block (fs=$FS_LN fin=$FIN_LN)"; fi
case "$FIN_BLOCK" in *'OVERALL_VERDICT="FAIL"'*'GATE_SHA_FAIL_CLASS="hold"'*) ok "the finalize block classifies its FAIL as hold" ;; *) bad "the finalize block must set GATE_SHA_FAIL_CLASS=\"hold\" after OVERALL_VERDICT=\"FAIL\"" ;; esac
for bad_word in gate_apply_needs_human 'gc mail' 'bd -C' 'exit ' 'return '; do
  case "$FIN_BLOCK" in *"$bad_word"*) bad "the finalize block must not contain '$bad_word' (no needs-human, no mail, no bd write, never exits)" ;; *) ok "the finalize block has no '$bad_word'" ;; esac
done
for bad_word in 'exit ' 'OVERALL_VERDICT' 'FAIL_REASONS'; do
  case "$STEP5_BLOCK" in *"$bad_word"*) bad "the Step 5 block must not contain '$bad_word' (it never blocks and never exits)" ;; *) ok "the Step 5 block has no '$bad_word'" ;; esac
done
case "$STEP5_BLOCK" in *'GATE_REA_LIB_OK'*) ok "the Step 5 call is guarded by GATE_REA_LIB_OK" ;; *) bad "the Step 5 call must test GATE_REA_LIB_OK" ;; esac
case "$FIN_BLOCK" in *'GATE_REA_LIB_OK'*) ok "the finalize block is guarded by GATE_REA_LIB_OK" ;; *) bad "the finalize block must test GATE_REA_LIB_OK" ;; esac
n_load=$(grep -c 'SELFTEST-EXTRACT rea-lib-load: BEGIN' "$DISPATCHER" || true)
eq "exactly one rea-lib-load sentinel pair" "$n_load" "1"
if bash -n "$DISPATCHER"; then ok "dispatcher passes bash -n"; else bad "dispatcher bash -n FAILED"; fi
if [ -r "$SELF_DIR/../../../config/rea_paths.txt" ] || [ -n "${REA_ST_PATHS:-}" ]; then ok "config/rea_paths.txt is where the dispatcher's default looks (\$GC_CITY/config/rea_paths.txt)"; else bad "config/rea_paths.txt is not at <city>/config/"; fi

# ── 11. mutation checks of this harness ───────────────────────────────────────────────────────────────────────────────────
if [ "$RUN_MUTANTS" = "1" ] && [ -z "${REA_ST_ASSETS:-}" ] && [ -z "${REA_ST_DISPATCHER:-}" ]; then
  echo "── 11. mutants: each break of the lib / scanner / dispatcher must turn this file red ──"
  MU="$T/mut"; mkdir -p "$MU"
  mutant() { # mutant <name> <file: lib|scan|disp> <python snippet that edits S (the text)>
    local name="$1" kind="$2" code="$3" d="$MU/$1" src
    mkdir -p "$d"; cp "$LIB" "$SCAN" "$d/"; cp "$DISPATCHER" "$d/quality-gate-dispatcher.sh"
    case "$kind" in lib) src="$d/gate-rea-check.lib.sh" ;; scan) src="$d/gate-rea-comments.py" ;; disp) src="$d/quality-gate-dispatcher.sh" ;; esac
    if ! python3 -I - "$src" "$code" <<'PYMUT'
import sys
p, code = sys.argv[1], sys.argv[2]
S = open(p, encoding="utf-8").read()
before = S
ns = {"S": S}
exec(code, ns)
S = ns["S"]
if S == before:
    sys.stderr.write("mutant changed nothing\n"); sys.exit(3)
open(p, "w", encoding="utf-8").write(S)
PYMUT
    then bad "mutant $name could not be built (the code it mutates moved?)"; return 0; fi
    # each mutant is a full run of this file (~30s): they run side by side, the verdicts are read after `wait`
    MUTANT_NAMES="$MUTANT_NAMES $name"
    ( REA_ST_ASSETS="$d" REA_ST_DISPATCHER="$d/quality-gate-dispatcher.sh" bash "$SELF" --no-mutants >"$d/out.txt" 2>&1; echo $? > "$d/rc" ) &
  }
  MUTANT_NAMES=""
  mutant unreadable-comments-read-as-missing lib 'S = S.replace("GATE_REA_COMMENTS=\"unknown\"; GATE_REA_COMMENT_ID=\"\"", "GATE_REA_COMMENTS=\"missing\"; GATE_REA_COMMENT_ID=\"\"", 1)'
  mutant unknown-verdict-blocks lib 'S = S.replace("      missing) GATE_REA_BLOCK_REASON=", "      unknown|missing) GATE_REA_BLOCK_REASON=", 1)'
  mutant warn-phase-blocks lib 'S = S.replace("if [ \"$GATE_REA_PHASE\" = \"enforce\" ]; then\n    case", "if true; then\n    case", 1)'
  mutant mark-forgets-the-label-check lib 'S = S.replace("    yes) printf '"'"'already'"'"'; return 0 ;;", "    yes) ;;", 1)'
  mutant label-before-comment lib 'S = S.replace("  bd -C \"$city\" comment \"$bead\" \"$text\" >/dev/null 2>&1 || { printf '"'"'failed'"'"'; return 0; }\n  bd -C \"$city\" label add \"$bead\" \"$label\" -q >/dev/null 2>&1 || { printf '"'"'failed'"'"'; return 0; }", "  bd -C \"$city\" label add \"$bead\" \"$label\" -q >/dev/null 2>&1 || { printf '"'"'failed'"'"'; return 0; }\n  bd -C \"$city\" comment \"$bead\" \"$text\" >/dev/null 2>&1 || { printf '"'"'failed'"'"'; return 0; }", 1)'
  mutant unreadable-stamp-enforces lib 'S = S.replace("is unreadable - staying in warn\"; return 0", "is unreadable\"; GATE_REA_PHASE=\"enforce\"; return 0", 1)'
  mutant bad-switch-value-is-on lib 'S = S.replace("*) printf '"'"'env-invalido'"'"'; return 0 ;;", "*) printf '"'"'on'"'"'; return 0 ;;", 1)'
  mutant gate-text-answers-the-rule lib 'S = S.replace("printf '"'"'REA-CHECK (ga-jdzri9, %s): branch", "printf '"'"'REA: (ga-jdzri9, %s): branch", 1)'
  mutant verdict-leaks-between-runs lib 'S = S.replace("GATE_REA_FIRST=\"\"; GATE_REA_PHASE=\"warn\"", "GATE_REA_PHASE=\"warn\"", 1)'
  mutant scanner-empty-REA-answers scan 'S = S.replace("^[ \\t]*REA:[ \\t]*\\S", "^[ \\t]*REA:", 1)'
  mutant scanner-unreadable-is-empty scan 'S = S.replace("    if not rows and unreadable:\n        return 2", "    if not rows and unreadable:\n        return 0", 1)'
  mutant scanner-flags-every-long-number scan 'S = S.replace("        if len(run) == 11 and _cpf_ok(run):", "        if len(run) >= 8:", 1)'
  mutant scanner-misses-jwt scan 'S = S.replace("    (\"jwt\", re.compile(", "    (\"jwt-off\", re.compile(", 1)'
  mutant scanner-echoes-values scan 'S = S.replace("            rows.append((ident, \",\".join(sorted(shapes(text))) or \"-\"))", "            rows.append((ident, \",\".join(sorted(shapes(text))) or \"-\") if not shapes(text) else (ident, text))", 1)'
  mutant finalize-forgets-hold disp 'S = S.replace("    GATE_SHA_FAIL_CLASS=\"hold\"  # ga-jdzri9:", "    : # ga-jdzri9:", 1)'
  mutant finalize-runs-on-a-fail-verdict disp 'S = S.replace("# SELFTEST-EXTRACT rea-finalize: BEGIN\nGATE_REA_BLOCK_REASON=\"\"\nif [ \"$OVERALL_VERDICT\" = \"PASS\" ]", "# SELFTEST-EXTRACT rea-finalize: BEGIN\nGATE_REA_BLOCK_REASON=\"\"\nif true", 1)'
  mutant step5-unguarded-by-lib-flag disp 'S = S.replace("if [ \"${GATE_REA_LIB_OK:-0}\" = \"1\" ]; then\n  gate_rea_step5", "if true; then\n  gate_rea_step5", 1)'
  wait
  for name in $MUTANT_NAMES; do
    d="$MU/$name"; rc=$(cat "$d/rc" 2>/dev/null || echo missing)
    if [ "$rc" = "missing" ] || [ "$rc" = "2" ]; then bad "mutant $name did not run to a verdict (rc=$rc; see $d/out.txt)"
    elif [ "$rc" != "0" ]; then ok "mutant $name turns the selftest red ($(grep -c '✗' "$d/out.txt" || true) assertion(s) failed)"
    else bad "mutant $name was NOT caught - the selftest still passes"; fi
  done
fi

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi
