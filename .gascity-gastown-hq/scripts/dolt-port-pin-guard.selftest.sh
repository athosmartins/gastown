#!/usr/bin/env bash
# dolt-port-pin-guard.selftest.sh (ga-3v2zt00) -- scenarios + mutants for dolt-port-pin-guard.sh.
# Hermetic: fake plists / rig dirs under a temp dir, live port forced by GC_DOLT_PORT_OVERRIDE, notify = a recorder.
# Mutants run under a write cap (ulimit -f) and a timeout; a mutant the scenarios do not catch is a FAIL.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
GUARD="$HERE/dolt-port-pin-guard.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/dppg-selftest.XXXXXX")"; trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok  $*"; }
nope() { FAIL=$((FAIL+1)); echo "  FAIL $*"; }

mkplist() { # mkplist <file> <key> <value>   (key empty -> a plist with no port var)
  { echo '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Label</key><string>x</string><key>EnvironmentVariables</key><dict><key>HOME</key><string>/h</string>'
    [ -n "$2" ] && echo "<key>$2</key><string>$3</string>"
    echo '</dict></dict></plist>'; } > "$1"
}
mkrig() { # mkrig <dir> <port> : a rig .beads with the three port sources
  mkdir -p "$1"; printf '%s\n' "$2" > "$1/dolt-server.port"; printf 'dolt.port: %s\nother: 1\n' "$2" > "$1/config.yaml"
  printf '{\n  "dolt_server_port": %s,\n  "x": 1\n}\n' "$2" > "$1/metadata.json"
}
# run <script> <env...> : fresh state per case dir $C
run() { local script="$1"; shift
  env -i PATH="$PATH" HOME="$HOME" GC_CITY="$W/city" DPPG_STATE="$C/state" DPPG_LOG="$C/log" DPPG_LOCK="$C/lock" \
    DPPG_NOTIFY="$W/notify-rec" DPPG_PLIST_GLOB="$C/plists/*.plist" DPPG_BEADS_DIRS="${BEADS_DIRS:-}" \
    GC_DOLT_PORT_OVERRIDE="${LIVE:-52756}" "$@" /bin/bash "$script"; }
case_dir() { C="$W/$1"; rm -rf "$C"; mkdir -p "$C/plists" "$C/rig"; : > "$W/notify-rec.log"; BEADS_DIRS=""; LIVE=52756; }
cat > "$W/notify-rec" <<'N'
#!/bin/sh
echo "$*" >> "$(dirname "$0")/notify-rec.log"
N
printf '#!/bin/sh\nexit 1\n' > "$W/notify-fail"; chmod +x "$W/notify-fail"
chmod +x "$W/notify-rec"; mkdir -p "$W/city/.gc/logs"
nnotify() { wc -l < "$W/notify-rec.log" | tr -d ' '; }

scenarios() { # scenarios <script> -> prints "label=ok|bad" lines
  local S="$1" out
  # 1 clean world
  case_dir s1; mkplist "$C/plists/a.plist" "" ""; mkrig "$C/rig/r1" 52756; BEADS_DIRS="$C/rig/r1"
  run "$S"; grep -q "OK: live=52756" "$C/log" && [ "$(nnotify)" = 0 ] && echo clean=ok || echo clean=bad
  # 2 stale plist pin -> finding + one notify, same set again -> no second notify
  case_dir s2; mkplist "$C/plists/a.plist" BEADS_DOLT_PORT 52757
  run "$S"; run "$S"
  grep -q "FINDING: STALE a.plist BEADS_DOLT_PORT=52757" "$C/log" && [ "$(nnotify)" = 1 ] && echo stale_plist=ok || echo stale_plist=bad
  # 3 pin == live -> PINNED (time bomb), still a finding
  case_dir s3; mkplist "$C/plists/a.plist" BEADS_DOLT_SERVER_PORT 52756
  run "$S"; grep -q "FINDING: PINNED a.plist BEADS_DOLT_SERVER_PORT=52756" "$C/log" && echo pinned_eq_live=ok || echo pinned_eq_live=bad
  # 3b GC_DOLT_PORT is watched too
  case_dir s3b; mkplist "$C/plists/a.plist" GC_DOLT_PORT 52999
  run "$S"; grep -q "STALE a.plist GC_DOLT_PORT=52999" "$C/log" && echo gc_dolt_port=ok || echo gc_dolt_port=bad
  # 4 rig with the three sources stale -> three findings; rig that matches -> none
  case_dir s4; mkrig "$C/rig/old" 52757; mkrig "$C/rig/new" 52756; BEADS_DIRS="$C/rig/old $C/rig/new"
  run "$S"; [ "$(grep -c 'FINDING: STALE .*old/' "$C/log")" = 3 ] && ! grep -q 'FINDING.*new/' "$C/log" && echo rig_three_sources=ok || echo rig_three_sources=bad
  # 4b only config.yaml stale
  case_dir s4b; mkrig "$C/rig/r" 52756; printf 'dolt.port: 52757\n' > "$C/rig/r/config.yaml"; BEADS_DIRS="$C/rig/r"
  run "$S"; grep -q "r/config.yaml:dolt.port =52757" "$C/log" && ! grep -q "dolt-server.port" "$C/log" && echo rig_config_only=ok || echo rig_config_only=bad
  # 5 live port UNKNOWN -> judges nothing, no notify, state untouched
  case_dir s5; mkplist "$C/plists/a.plist" BEADS_DOLT_PORT 52757; printf 'dolt_server_live_port() { return 1; }\n' > "$C/nolive.sh"
  echo "SENTINEL" > "$C/state"
  run "$S" DPPG_LIB="$C/nolive.sh"; grep -q "UNKNOWN" "$C/log" && ! grep -q FINDING "$C/log" && [ "$(nnotify)" = 0 ] && [ "$(cat "$C/state")" = SENTINEL ] && echo live_unknown=ok || echo live_unknown=bad
  # 6 recovery: findings, then fixed -> exactly one "limpos" notify, state back to none
  case_dir s6; mkplist "$C/plists/a.plist" BEADS_DOLT_PORT 52757
  run "$S"; mkplist "$C/plists/a.plist" "" ""; run "$S"
  [ "$(nnotify)" = 2 ] && grep -q "limpos" "$W/notify-rec.log" && [ "$(cat "$C/state")" = none ] && echo recovery=ok || echo recovery=bad
  # 7 unreadable value, no finding -> INCONCLUSIVE, previous state kept, no "limpos"
  case_dir s7; mkplist "$C/plists/a.plist" "" ""; mkrig "$C/rig/r" 52756; printf 'dolt.port: abc\n' > "$C/rig/r/config.yaml"; BEADS_DIRS="$C/rig/r"; echo "somesig" > "$C/state"
  run "$S"; grep -q "INCONCLUSIVE" "$C/log" && [ "$(cat "$C/state")" = somesig ] && [ "$(nnotify)" = 0 ] && echo unreadable_inconclusive=ok || echo unreadable_inconclusive=bad
  # 8 lock held -> skipped, nothing judged
  case_dir s8; mkplist "$C/plists/a.plist" BEADS_DOLT_PORT 52757; mkdir "$C/lock"
  run "$S"; grep -q "another instance" "$C/log" && ! grep -q FINDING "$C/log" && echo lock=ok || echo lock=bad
  # 9 skipped dir (the standalone beads store) is not reported
  case_dir s9; mkplist "$C/plists/a.plist" "" ""; mkrig "$C/rig/skipme" 3307; BEADS_DIRS="$C/rig/skipme"
  run "$S" DPPG_SKIP_DIRS="$C/rig/skipme"; grep -q "OK: live=52756" "$C/log" && echo skip_dir=ok || echo skip_dir=bad
  # 10 detection-only: no fixture file was modified
  case_dir s10; mkplist "$C/plists/a.plist" BEADS_DOLT_PORT 52757; mkrig "$C/rig/r" 52757; BEADS_DIRS="$C/rig/r"
  before="$(cat "$C"/plists/a.plist "$C"/rig/r/* | cksum)"; run "$S"; after="$(cat "$C"/plists/a.plist "$C"/rig/r/* | cksum)"
  [ "$before" = "$after" ] && echo detection_only=ok || echo detection_only=bad
  # 11 gate round 2, blocking 1: the REAL lib, no override, a port FILE (52757) but no verifiable server (stubs: no pgrep hit, ps says "sleep",
  #    lsof fails) -> the file must NOT become "live": UNKNOWN, nothing judged, state untouched, no notify. (With the file as "live" the stale
  #    pin below would be read as PINNED==live, or the whole city as clean.)
  case_dir s11; mkdir -p "$C/bin" "$W/city/.beads"
  printf '#!/bin/sh\nexit 1\n' > "$C/bin/pgrep"; printf '#!/bin/sh\necho sleep\n' > "$C/bin/ps"; printf '#!/bin/sh\nexit 1\n' > "$C/bin/lsof"; chmod +x "$C/bin/pgrep" "$C/bin/ps" "$C/bin/lsof"
  printf '52757\n' > "$W/city/.beads/dolt-server.port"; mkplist "$C/plists/a.plist" BEADS_DOLT_PORT 52757; BEADS_DIRS="$W/city/.beads"; echo "SENTINEL" > "$C/state"
  run "$S" GC_DOLT_PORT_OVERRIDE= PATH="$C/bin:$PATH"
  rm -f "$W/city/.beads/dolt-server.port"
  grep -q "UNKNOWN" "$C/log" && ! grep -qE "FINDING|OK:" "$C/log" && [ "$(nnotify)" = 0 ] && [ "$(cat "$C/state")" = SENTINEL ] && echo live_file_not_live=ok || echo live_file_not_live=bad
  # 12 blocking 2: a notification that FAILS is not recorded as delivered; the next run sends it again; a delivered one is not repeated
  case_dir s12; mkplist "$C/plists/a.plist" BEADS_DOLT_PORT 52757
  run "$S" DPPG_NOTIFY="$W/notify-fail"; f1=0; [ ! -s "$C/state" ] && grep -q "NOTIFY FAILED" "$C/log" && f1=1
  run "$S"; run "$S"   # the notifier works again: exactly ONE delivery, then dedup
  [ "$f1" = 1 ] && [ "$(nnotify)" = 1 ] && [ -s "$C/state" ] && echo notify_fail_retries=ok || echo notify_fail_retries=bad
  # 12b the same for the "limpos" message: previous findings, now clean, notifier down -> state kept, retried, then none
  case_dir s12b; mkplist "$C/plists/a.plist" "" ""; echo "somesig" > "$C/state"
  run "$S" DPPG_NOTIFY="$W/notify-fail"; f2=0; [ "$(cat "$C/state")" = somesig ] && grep -q "NOTIFY FAILED" "$C/log" && f2=1
  run "$S"
  [ "$f2" = 1 ] && [ "$(nnotify)" = 1 ] && grep -q limpos "$W/notify-rec.log" && [ "$(cat "$C/state")" = none ] && echo limpos_fail_retries=ok || echo limpos_fail_retries=bad
  # 13 an EMPTY state file (interrupted write) is "none": a clean world sends no spurious "limpos"
  case_dir s13; mkplist "$C/plists/a.plist" "" ""; : > "$C/state"
  run "$S"; [ "$(nnotify)" = 0 ] && [ "$(cat "$C/state")" = none ] && echo empty_state=ok || echo empty_state=bad
  # 14 sources that cannot be judged are never "clean": each must end INCONCLUSIVE (state kept), none may say OK
  case_dir s14a; mkplist "$C/plists/a.plist" "" ""; mkrig "$C/rig/r" 52756; : > "$C/rig/r/dolt-server.port"; BEADS_DIRS="$C/rig/r"; echo keep > "$C/state"
  run "$S"; grep -q "INCONCLUSIVE" "$C/log" && [ "$(cat "$C/state")" = keep ] && r14a=1 || r14a=0                       # empty port file
  case_dir s14b; mkplist "$C/plists/a.plist" "" ""; printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict><key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string><string>BEADS_DOLT_PORT=52757 bd list</string></array></dict></plist>' > "$C/plists/b.plist"; echo keep > "$C/state"
  run "$S"; grep -q "INCONCLUSIVE" "$C/log" && grep -q "outside EnvironmentVariables" "$C/log" && r14b=1 || r14b=0         # port var outside EnvironmentVariables
  case_dir s14c; rm -rf "$C/plists"; echo keep > "$C/state"
  run "$S"; grep -q "INCONCLUSIVE" "$C/log" && grep -q "glob matched nothing" "$C/log" && r14c=1 || r14c=0                 # no plist at all
  case_dir s14d; mkplist "$C/plists/a.plist" BEADS_DOLT_PORT 52757; mkdir -p "$C/bin"; printf '#!/bin/sh\ncase "$*" in *-lE*) exit 2 ;; esac\nexec /usr/bin/grep "$@"\n' > "$C/bin/grep"; chmod +x "$C/bin/grep"; echo keep > "$C/state"
  run "$S" PATH="$C/bin:$PATH"; grep -q "INCONCLUSIVE" "$C/log" && grep -q "grep over the plists failed" "$C/log" && r14d=1 || r14d=0   # grep itself fails
  case_dir s14e; mkplist "$C/plists/a.plist" "" ""; mkrig "$C/rig/r" 52756; printf '{\n  "dolt_server_port": null\n}\n' > "$C/rig/r/metadata.json"; BEADS_DIRS="$C/rig/r"; echo keep > "$C/state"
  run "$S"; grep -q "INCONCLUSIVE" "$C/log" && r14e=1 || r14e=0                                                          # metadata key present, no number
  [ "$r14a$r14b$r14c$r14d$r14e" = 11111 ] && echo unjudgeable_not_clean=ok || echo "unjudgeable_not_clean=bad($r14a$r14b$r14c$r14d$r14e)"
  # 15 the other shapes of the same sources are READ: nested config.yaml `dolt:` + `port:`, a one-line metadata.json, a quoted value
  case_dir s15; mkrig "$C/rig/n" 52756; printf 'dolt:\n  disable-event-flush: true\n  port: 52757 # old\n' > "$C/rig/n/config.yaml"
  mkrig "$C/rig/m" 52756; printf '{"dolt_server_port": "52757", "x": 1}\n' > "$C/rig/m/metadata.json"; BEADS_DIRS="$C/rig/n $C/rig/m"
  run "$S"; grep -q "n/config.yaml:dolt.port =52757" "$C/log" && grep -q "m/metadata.json:dolt_server_port =52757" "$C/log" && echo other_shapes=ok || echo other_shapes=bad
  # 15b a nested `dolt:` block with NO port key (what the real rigs have) is "no pin", not unreadable
  case_dir s15b; mkplist "$C/plists/a.plist" "" ""; mkrig "$C/rig/n" 52756; printf 'dolt:\n  disable-event-flush: true\nbackup.enabled: false\n' > "$C/rig/n/config.yaml"; BEADS_DIRS="$C/rig/n"
  run "$S"; grep -q "OK: live=52756" "$C/log" && echo nested_no_port_clean=ok || echo nested_no_port_clean=bad
}

echo "== scenarios (real guard)"
res="$(scenarios "$GUARD")"
for l in clean stale_plist pinned_eq_live gc_dolt_port rig_three_sources rig_config_only live_unknown recovery unreadable_inconclusive lock skip_dir detection_only live_file_not_live notify_fail_retries limpos_fail_retries empty_state unjudgeable_not_clean other_shapes nested_no_port_clean; do
  if printf '%s\n' "$res" | grep -qx "$l=ok"; then ok "$l"; else nope "$l ($(printf '%s\n' "$res" | grep "^$l=" || echo 'no answer'))"; fi
done

echo "== mutants (each must be caught by at least one scenario)"
mutant() { # mutant <name> <sed-expr> <expected-failing-label>
  local f="$W/mut-$1.sh"; sed "$2" "$GUARD" > "$f"; cp "$HERE/dolt-pid-lib.sh" "$W/dolt-pid-lib.sh"
  if cmp -s "$f" "$GUARD"; then nope "mutant $1: the sed did not change the guard (selftest rot)"; return; fi
  local r; r="$( ( ulimit -f 65536; scenarios "$f" ) 2>/dev/null )"
  if printf '%s\n' "$r" | grep -qE "^$3=bad"; then ok "mutant $1 killed by $3"; else nope "mutant $1 SURVIVED (expected $3=bad)"; fi
}
mutant plist-cmp-inverted      's/if \[ "\$v" = "\$LIVE" \]; then FINDINGS+=("PINNED/if [ "$v" != "$LIVE" ]; then FINDINGS+=("PINNED/' pinned_eq_live
mutant unknown-live-proceeds   's/^if \[ -z "\$LIVE" \]; then/if false; then/' live_unknown
mutant notify-every-run        's/if \[ "\$SIG" != "\$PREV" \]; then/if true; then/' stale_plist
mutant no-config-yaml-check    's/^  if \[ -r "\$d\/config.yaml" \]; then$/  if false; then/' rig_config_only
mutant no-metadata-check       's/^  if \[ -r "\$d\/metadata.json" \]; then$/  if false; then/' rig_three_sources
mutant unreadable-is-clean     's/\[ "\$UNREADABLE" -gt 0 \]; then$/[ "$UNREADABLE" -gt 99999 ]; then/' unreadable_inconclusive
mutant gc-dolt-port-unwatched  's/for k in BEADS_DOLT_PORT BEADS_DOLT_SERVER_PORT GC_DOLT_PORT; do/for k in BEADS_DOLT_PORT BEADS_DOLT_SERVER_PORT; do/' gc_dolt_port
mutant no-recovery-notify      's/^  elif _notify .Porta do Dolt: pins limpos. \(.*\); then$/  elif true; then/' recovery
mutant lock-ignored            's/^mkdir "\$LOCK" 2>\/dev\/null || .*$/mkdir "$LOCK" 2>\/dev\/null || true/' lock
mutant live-from-file           's/^LIVE="\$(dolt_server_live_port 2>/LIVE="$(dolt_server_port 2>/' live_file_not_live
mutant notify-rc-swallowed      's/^_notify() { .*$/_notify() { command -v "$NOTIFY_CMD" >\/dev\/null 2>\&1 \&\& "$NOTIFY_CMD" -p 3 -t "$1" "$2" >\/dev\/null 2>\&1 || true; }/' notify_fail_retries
mutant limpos-state-unconditional 's/^  elif _notify .Porta do Dolt: pins limpos. \(.*\); then$/  elif { _notify "x" "y" || true; }; then/' limpos_fail_retries
mutant empty-state-is-empty     's/\[ -n "\$PREV" \] || PREV=none/true/' empty_state
mutant grep-failure-is-clean    's/\[ "\$_grc" -gt 1 \]/[ "$_grc" -gt 99 ]/' unjudgeable_not_clean
mutant glob-empty-is-clean      's/^if \[ "\${#_plists\[@\]}" -eq 0 \] || \[ ! -e "\${_plists\[0\]}" \]; then$/if false; then/' unjudgeable_not_clean
mutant empty-port-file-is-clean 's/_chk dolt-server.port "\${_v:-?}"/_chk dolt-server.port "$_v"/' unjudgeable_not_clean
mutant nested-config-ignored    's/indolt \&\& \/\^\[ \\t\]+port/indolt \&\& \/^NEVER[ \\t]+port/' other_shapes
mutant skip-dirs-ignored       's/^  case " \$SKIP_DIRS " in .*$/  :/' skip_dir

echo; echo "dolt-port-pin-guard selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
