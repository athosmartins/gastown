#!/usr/bin/env bash
# daemon-presence-watchdog.selftest.sh — ga-p7hymz.1: the watchdog's DEFAULT config must watch com.gascity.child-priority-janitor,
# and what it watches must be what launchd actually writes.
#
# `daemon-presence-watchdog.sh --selftest` (scenario 22c) checks the string half from its own env. This file checks the half that
# needs the plist: the heartbeat threshold must be > 2x the plist's StartInterval (a missed cycle must not kickstart a healthy job)
# and the heartbeat file must be the plist's StandardOutPath (any other name is "file absent" forever, which the watchdog reads as
# "no verdict" — silence, never an alarm).
#
# THREE STATES, on every input of `wiring`: script/plist unreadable (missing, chmod 000) → BAD "unreadable or missing"; read ok but
# the entry/key is not there (no heartbeat line, empty plist) → BAD "not found"; read ok and present → compared. The first two never
# become OK: an unreadable input reproves, it does not pass blank. The cases at the bottom INJECT each failure and require rc != 0.
#
# ga-2hd02v.1.17: the same proof for com.gascity.hetzner-occupancy-watch (last section). That job was installed on the mini with no DPW
# entry (PRESENCE-DRIFT on every cycle) and this file, which only knew the janitor, could not tell: `wiring` now takes the label as its 3rd
# argument, and reads StandardOutPath whether the <string> sits on the key's line (the watch's plist) or on the next one (the janitor's).
#
# ga-ki02nmt: the same proof for com.gascity.jsonl-export (StartInterval 900) and com.gascity.jsonl-hourly-offsite (1800), the two backup jobs that left
# the order dispatcher for launchd. `wiring` takes the upper limit of the threshold as a 4th argument (default 3000 s, unchanged for the three jobs above):
# the offsite's own rule "> 2x StartInterval" already means > 3600 s, so a 3000 s cap could never pass it; its cap is 6000 s (3 cycles = 5400 s).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DPW="${DPW_PATH:-$HERE/daemon-presence-watchdog.sh}"
PLIST="${JANITOR_PLIST_PATH:-$HERE/com.gascity.child-priority-janitor.plist}"
LBL="com.gascity.child-priority-janitor"

W="$(mktemp -d "${TMPDIR:-/tmp}/dpw-janitor-selftest.XXXXXX")"
trap 'chmod -R u+rwX "$W" 2>/dev/null; rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
nope() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

# wiring <watchdog-script> <plist> [<label> [<cap-seconds>]]: prints "OK ..."/"BAD ..." per proof; rc 1 if any BAD. <label> is the janitor's unless given;
# <cap-seconds> is the highest threshold that still "catches a hang" (3000 unless given).
wiring() {
  local s="$1" p="$2" lbl="${3-$LBL}" cap="${4-3000}" rc=0 line file max int out lre
  if [ ! -r "$s" ]; then echo "BAD watchdog script unreadable or missing ($s)"; return 1; fi
  if [ ! -r "$p" ]; then echo "BAD plist unreadable or missing ($p)"; return 1; fi
  # a label handed over EMPTY is not the janitor's: it reproves (the ${3-} default only covers an argument that was never given)
  if [ -z "$lbl" ]; then echo "BAD no label to prove (empty argument)"; return 1; fi
  # a cap that is not a whole number is a bad call, not "no cap": it reproves (vazio → BAD; falhou/ilegível → BAD, nunca um teto que deixa tudo passar)
  case "$cap" in ''|*[!0-9]*) echo "BAD cap is not a whole number ([$cap])"; return 1 ;; esac
  # vazio (sem a linha) → line vazia → BAD "no heartbeat entry"; falhou (grep rc != 0) → mesma saída vazia → BAD, nunca OK
  line="$(grep -E "^$lbl[|][^|]+[|][0-9]+" "$s" 2>/dev/null | head -1)"
  file="$(printf '%s' "$line" | awk -F'|' '{print $2}')"
  max="$(printf '%s' "$line" | awk -F'|' '{print $3}' | tr -cd '0-9')"
  if [ -n "$line" ]; then echo "OK heartbeat entry present ($line)"; else echo "BAD no heartbeat entry for $lbl in $s"; rc=1; fi
  # vazio → impossível (o label vazio reprovou acima); falhou (sed rc != 0) → lre vazio → o BAD abaixo (sem o -n o regex perderia o label e provaria outra coisa)
  lre="$(printf '%s' "$lbl" | sed 's/\./\\./g')"
  if [ -n "$lre" ] && grep -Eq "^DPW_CRITICAL=\"\\\$\{DPW_CRITICAL:-([^}]* )?${lre}[ }]" "$s" 2>/dev/null; then
    echo "OK $lbl is in the DPW_CRITICAL default (the heartbeat entry is reachable)"
  else
    echo "BAD $lbl is NOT in the DPW_CRITICAL default (a heartbeat entry for it would be dead config)"; rc=1
  fi
  # vazio → int/out vazios → BAD "not found" abaixo; falhou (sed/awk rc != 0) → mesma saída vazia → BAD, nunca OK
  # StandardOutPath: o <string> vem na linha da chave (plist do vigia de ocupação) ou na seguinte (plist do janitor); só lê a seguinte se a da chave não o tem
  int="$(sed -n 's|.*<key>StartInterval</key><integer>\([0-9][0-9]*\)</integer>.*|\1|p' "$p" 2>/dev/null | head -1)"
  out="$(awk '/<key>StandardOutPath<\/key>/{ if ($0 !~ /<string>/) getline; gsub(/.*<string>|<\/string>.*/,""); print; exit }' "$p" 2>/dev/null)"
  case "$int" in
    ''|*[!0-9]*) echo "BAD StartInterval not found in $p ([$int]) — cannot prove the threshold"; rc=1 ;;
    *)
      case "$max" in
        ''|*[!0-9]*) echo "BAD heartbeat threshold is not a number ([$max])"; rc=1 ;;
        *)
          if [ "$max" -gt $(( int * 2 )) ] && [ "$max" -le "$cap" ]; then
            echo "OK threshold ${max}s is > 2x StartInterval (${int}s) and <= ${cap} s"
          else
            echo "BAD threshold ${max}s is not in (2x StartInterval ${int}s, ${cap} s]"; rc=1
          fi ;;
      esac ;;
  esac
  if [ -n "$out" ] && [ "$(basename "$out")" = "$(basename "$file")" ]; then
    echo "OK plist StandardOutPath ($(basename "$out")) is the file the watchdog reads"
  else
    echo "BAD plist StandardOutPath ([$out]) != heartbeat file ([$file]) — the watchdog would read a file launchd never writes"; rc=1
  fi
  return $rc
}

# expect_reprova <name> <script> <plist> [<needle> [<label> [<cap-seconds>]]]: wiring must return != 0, and (when given) say <needle>.
# <cap-seconds> is only ever given together with <label> (it is the 6th argument, wiring's 4th).
expect_reprova() {
  local name="$1" s="$2" p="$3" needle="${4:-}" o
  o="$(wiring "$s" "$p" ${5+"$5"} ${6+"$6"} 2>&1)"
  if [ $? -eq 0 ]; then nope "$name — passed (rc 0); a broken wiring must reprove"; return; fi
  if [ -n "$needle" ] && ! printf '%s\n' "$o" | grep -q "$needle"; then
    nope "$name — reproved, but not for the expected reason ($needle): $(printf '%s' "$o" | grep '^BAD' | head -2 | tr '\n' ' ')"; return
  fi
  ok "$name → rc != 0${needle:+ ($needle)}"
}

echo "== the real default + the real plist =="
if o="$(wiring "$DPW" "$PLIST" 2>&1)"; then ok "real default wiring proven"; else nope "real default wiring NOT proven"; fi
printf '%s\n' "$o" | sed 's/^/        | /'

echo "== injected failures: each must reprove =="
expect_reprova "plist missing" "$DPW" "$W/nonexistent-janitor.plist" "plist unreadable or missing"
expect_reprova "watchdog script missing" "$W/nonexistent-dpw.sh" "$PLIST" "watchdog script unreadable or missing"
cp "$PLIST" "$W/noperm.plist" && chmod 000 "$W/noperm.plist"
if [ -r "$W/noperm.plist" ]; then
  printf 'skip - plist still readable after chmod 000 (running as root?): permission case not exercised\n'
else
  expect_reprova "plist chmod 000" "$DPW" "$W/noperm.plist" "plist unreadable or missing"
fi
: > "$W/empty.plist"
expect_reprova "plist empty (read ok, key absent — another state)" "$DPW" "$W/empty.plist" "StartInterval not found"

grep -v "^$LBL|" "$DPW" > "$W/dpw-no-entry.sh"
expect_reprova "heartbeat entry removed" "$W/dpw-no-entry.sh" "$PLIST" "no heartbeat entry"
sed "/^$LBL|/s|child-priority-janitor\.out|some-other-file.out|" "$DPW" > "$W/dpw-wrong-file.sh"
expect_reprova "heartbeat file != plist StandardOutPath" "$W/dpw-wrong-file.sh" "$PLIST" "StandardOutPath"
sed "/^$LBL|/s/|900/|500/" "$DPW" > "$W/dpw-low.sh"
expect_reprova "threshold 500 s (< 2x StartInterval)" "$W/dpw-low.sh" "$PLIST" "threshold"
sed "/^$LBL|/s/|900/|3600/" "$DPW" > "$W/dpw-high.sh"
expect_reprova "threshold 3600 s (> 3000 s)" "$W/dpw-high.sh" "$PLIST" "threshold"
# Take the label out wherever it sits on the DPW_CRITICAL line (ga-2hd02v.1.17 appended another label after it: a mutation anchored
# on the end of the line matched nothing, the file stayed intact and the case failed as "passed (rc 0)").
sed '/^DPW_CRITICAL=/s/ com\.gascity\.child-priority-janitor\([ }]\)/\1/' "$DPW" > "$W/dpw-no-critical.sh"
expect_reprova "label removed from DPW_CRITICAL" "$W/dpw-no-critical.sh" "$PLIST" "NOT in the DPW_CRITICAL"

# ga-2hd02v.1.17: the occupancy watch. On the commit before the registration the DPW has neither its heartbeat entry nor its DPW_CRITICAL
# name, so the first case below is the one that reproves there; the rest prove, on the registered DPW, that each broken wiring reproves for
# its own reason (the needle of each case).
echo "== the occupancy watch: in the DPW default, its heartbeat is the file its plist writes =="
OCC_LBL="com.gascity.hetzner-occupancy-watch"
OCC_PLIST="${OCCUPANCY_PLIST_PATH:-$HERE/$OCC_LBL.plist}"
if o="$(wiring "$DPW" "$OCC_PLIST" "$OCC_LBL" 2>&1)"; then ok "occupancy watch: real default wiring proven"; else nope "occupancy watch: real default wiring NOT proven"; fi
printf '%s\n' "$o" | sed 's/^/        | /'
grep -v "^$OCC_LBL|" "$DPW" > "$W/occ-no-entry.sh"
expect_reprova "occupancy watch: heartbeat entry removed" "$W/occ-no-entry.sh" "$OCC_PLIST" "no heartbeat entry" "$OCC_LBL"
sed "/^$OCC_LBL|/s|hetzner-occupancy-watch\.out|hetzner-occupancy-watch.err|" "$DPW" > "$W/occ-err-file.sh"
expect_reprova "occupancy watch: heartbeat on the plist's .err, not its .out" "$W/occ-err-file.sh" "$OCC_PLIST" "StandardOutPath" "$OCC_LBL"
sed "/^$OCC_LBL|/s/|2700/|1000/" "$DPW" > "$W/occ-low.sh"
expect_reprova "occupancy watch: threshold 1000 s (< 2x StartInterval)" "$W/occ-low.sh" "$OCC_PLIST" "threshold" "$OCC_LBL"
sed "/^$OCC_LBL|/s/|2700/|3600/" "$DPW" > "$W/occ-high.sh"
expect_reprova "occupancy watch: threshold 3600 s (> 3000 s)" "$W/occ-high.sh" "$OCC_PLIST" "threshold" "$OCC_LBL"
sed '/^DPW_CRITICAL=/s/ com\.gascity\.hetzner-occupancy-watch\([ }]\)/\1/' "$DPW" > "$W/occ-no-critical.sh"
expect_reprova "occupancy watch: label removed from DPW_CRITICAL" "$W/occ-no-critical.sh" "$OCC_PLIST" "NOT in the DPW_CRITICAL" "$OCC_LBL"
expect_reprova "occupancy watch: label handed over empty" "$DPW" "$OCC_PLIST" "no label to prove" ""

# ga-ki02nmt: the two JSONL backup jobs that run from launchd instead of the order dispatcher. One function, run once per job:
#   jsonl_job_cases <label> <plist> <heartbeat-limit> <cap> <out-basename> <err-basename>
# Each mutation below edits a COPY of the watchdog script (or of the plist) and the case must reprove FOR ITS OWN REASON (the needle). A sed that matches
# nothing leaves the copy intact, the wiring passes, and the case fails as "passed (rc 0)": a mutation that misses cannot pass silently.
jsonl_job_cases() {
  local lbl="$1" plist="$2" lim="$3" cap="$4" outb="$5" errb="$6" tag="${1#com.gascity.}" lre o
  lre="$(printf '%s' "$lbl" | sed 's/\./\\./g')"
  echo "== $tag: in the DPW default, its heartbeat is the file its plist writes =="
  if o="$(wiring "$DPW" "$plist" "$lbl" "$cap" 2>&1)"; then ok "$tag: real default wiring proven"; else nope "$tag: real default wiring NOT proven"; fi
  printf '%s\n' "$o" | sed 's/^/        | /'
  grep -v "^$lbl|" "$DPW" > "$W/$tag-no-entry.sh"
  expect_reprova "$tag: heartbeat entry removed" "$W/$tag-no-entry.sh" "$plist" "no heartbeat entry" "$lbl" "$cap"
  sed "/^$lre|/s|$outb|$errb|" "$DPW" > "$W/$tag-err-file.sh"
  expect_reprova "$tag: heartbeat on the plist's $errb, not its $outb" "$W/$tag-err-file.sh" "$plist" "StandardOutPath" "$lbl" "$cap"
  sed "/^$lre|/s/|$lim\$/|1000/;/^$lre|/s/|$lim}\"\$/|1000}\"/" "$DPW" > "$W/$tag-low.sh"
  expect_reprova "$tag: threshold 1000 s (< 2x StartInterval)" "$W/$tag-low.sh" "$plist" "threshold" "$lbl" "$cap"
  sed "/^$lre|/s/|$lim\$/|$((cap + 600))/;/^$lre|/s/|$lim}\"\$/|$((cap + 600))}\"/" "$DPW" > "$W/$tag-high.sh"
  expect_reprova "$tag: threshold $((cap + 600)) s (> ${cap} s)" "$W/$tag-high.sh" "$plist" "threshold" "$lbl" "$cap"
  sed "/^DPW_CRITICAL=/s/ $lre\([ }]\)/\1/" "$DPW" > "$W/$tag-no-critical.sh"
  expect_reprova "$tag: label removed from DPW_CRITICAL" "$W/$tag-no-critical.sh" "$plist" "NOT in the DPW_CRITICAL" "$lbl" "$cap"
  # the plist's StandardOutPath points somewhere else: the heartbeat file is then one launchd never writes (the watchdog reads "file absent" = no verdict, forever)
  sed "/<key>StandardOutPath<\\/key>/{n;s|$outb|some-other-file.out|;}" "$plist" > "$W/$tag-other-out.plist"
  expect_reprova "$tag: plist StandardOutPath is another file" "$DPW" "$W/$tag-other-out.plist" "StandardOutPath" "$lbl" "$cap"
  expect_reprova "$tag: cap that is not a number" "$DPW" "$plist" "cap is not a whole number" "$lbl" "abc"
  expect_reprova "$tag: cap handed over empty" "$DPW" "$plist" "cap is not a whole number" "$lbl" ""
  expect_reprova "$tag: label handed over empty" "$DPW" "$plist" "no label to prove" "" "$cap"
}
JX_LBL="com.gascity.jsonl-export"
JO_LBL="com.gascity.jsonl-hourly-offsite"
JX_PLIST="${JSONL_EXPORT_PLIST_PATH:-$HERE/$JX_LBL.plist}"
JO_PLIST="${JSONL_OFFSITE_PLIST_PATH:-$HERE/$JO_LBL.plist}"
# the exporter: 900 s cycle -> limit 2700 s (3 cycles, under the default 3000 s cap); the offsite: 1800 s cycle -> limit 5400 s, cap 6000 s
jsonl_job_cases "$JX_LBL" "$JX_PLIST" 2700 3000 "jsonl-export-launchd.out" "jsonl-export-launchd.err"
jsonl_job_cases "$JO_LBL" "$JO_PLIST" 5400 6000 "jsonl-hourly-offsite-launchd.out" "jsonl-hourly-offsite-launchd.err"
# the offsite's .out is ALSO its StandardErrorPath (the script logs to stderr; a stdout-only file would never advance): a plist that sends stderr elsewhere
# keeps wiring() green (it reads StandardOutPath only), so this one is its own check, on the plist.
# vazio (chave ausente) → err vazio → reprova; falhou/ilegível (awk rc != 0) → mesma saída vazia → reprova, nunca passa em branco
jo_out="$(awk '/<key>StandardOutPath<\/key>/{ if ($0 !~ /<string>/) getline; gsub(/.*<string>|<\/string>.*/,""); print; exit }' "$JO_PLIST" 2>/dev/null)"
jo_err="$(awk '/<key>StandardErrorPath<\/key>/{ if ($0 !~ /<string>/) getline; gsub(/.*<string>|<\/string>.*/,""); print; exit }' "$JO_PLIST" 2>/dev/null)"
if [ -n "$jo_out" ] && [ "$jo_out" = "$jo_err" ]; then
  ok "jsonl-hourly-offsite: StandardErrorPath == StandardOutPath ($jo_out): the script's stderr log lines advance the heartbeat"
else
  nope "jsonl-hourly-offsite: StandardErrorPath [$jo_err] != StandardOutPath [$jo_out]: the heartbeat would never advance (the script logs to stderr)"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
