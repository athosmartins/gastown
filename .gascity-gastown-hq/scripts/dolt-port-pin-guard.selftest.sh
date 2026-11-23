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
  case_dir s5; mkplist "$C/plists/a.plist" BEADS_DOLT_PORT 52757; printf 'dolt_server_port() { return 1; }\n' > "$C/nolive.sh"
  echo "SENTINEL" > "$C/state"
  run "$S" DPPG_LIB="$C/nolive.sh"; grep -q "UNKNOWN" "$C/log" && ! grep -q FINDING "$C/log" && [ "$(nnotify)" = 0 ] && [ "$(cat "$C/state")" = SENTINEL ] && echo live_unknown=ok || echo live_unknown=bad
  # 6 recovery: findings, then fixed -> exactly one "limpos" notify, state back to none
  case_dir s6; mkplist "$C/plists/a.plist" BEADS_DOLT_PORT 52757
  run "$S"; mkplist "$C/plists/a.plist" "" ""; run "$S"
  [ "$(nnotify)" = 2 ] && grep -q "limpos" "$W/notify-rec.log" && [ "$(cat "$C/state")" = none ] && echo recovery=ok || echo recovery=bad
  # 7 unreadable value, no finding -> INCONCLUSIVE, previous state kept, no "limpos"
  case_dir s7; mkrig "$C/rig/r" 52756; printf 'dolt.port: abc\n' > "$C/rig/r/config.yaml"; BEADS_DIRS="$C/rig/r"; echo "somesig" > "$C/state"
  run "$S"; grep -q "INCONCLUSIVE" "$C/log" && [ "$(cat "$C/state")" = somesig ] && [ "$(nnotify)" = 0 ] && echo unreadable_inconclusive=ok || echo unreadable_inconclusive=bad
  # 8 lock held -> skipped, nothing judged
  case_dir s8; mkplist "$C/plists/a.plist" BEADS_DOLT_PORT 52757; mkdir "$C/lock"
  run "$S"; grep -q "another instance" "$C/log" && ! grep -q FINDING "$C/log" && echo lock=ok || echo lock=bad
  # 9 skipped dir (the standalone beads store) is not reported
  case_dir s9; mkrig "$C/rig/skipme" 3307; BEADS_DIRS="$C/rig/skipme"
  run "$S" DPPG_SKIP_DIRS="$C/rig/skipme"; grep -q "OK: live=52756" "$C/log" && echo skip_dir=ok || echo skip_dir=bad
  # 10 detection-only: no fixture file was modified
  case_dir s10; mkplist "$C/plists/a.plist" BEADS_DOLT_PORT 52757; mkrig "$C/rig/r" 52757; BEADS_DIRS="$C/rig/r"
  before="$(cat "$C"/plists/a.plist "$C"/rig/r/* | cksum)"; run "$S"; after="$(cat "$C"/plists/a.plist "$C"/rig/r/* | cksum)"
  [ "$before" = "$after" ] && echo detection_only=ok || echo detection_only=bad
}

echo "== scenarios (real guard)"
res="$(scenarios "$GUARD")"
for l in clean stale_plist pinned_eq_live gc_dolt_port rig_three_sources rig_config_only live_unknown recovery unreadable_inconclusive lock skip_dir detection_only; do
  if printf '%s\n' "$res" | grep -qx "$l=ok"; then ok "$l"; else nope "$l ($(printf '%s\n' "$res" | grep "^$l=" || echo 'no answer'))"; fi
done

echo "== mutants (each must be caught by at least one scenario)"
mutant() { # mutant <name> <sed-expr> <expected-failing-label>
  local f="$W/mut-$1.sh"; sed "$2" "$GUARD" > "$f"; cp "$HERE/dolt-pid-lib.sh" "$W/dolt-pid-lib.sh"
  if cmp -s "$f" "$GUARD"; then nope "mutant $1: the sed did not change the guard (selftest rot)"; return; fi
  local r; r="$( ( ulimit -f 65536; scenarios "$f" ) 2>/dev/null )"
  if printf '%s\n' "$r" | grep -qx "$3=bad"; then ok "mutant $1 killed by $3"; else nope "mutant $1 SURVIVED (expected $3=bad)"; fi
}
mutant plist-cmp-inverted      's/if \[ "\$v" = "\$LIVE" \]; then FINDINGS+=("PINNED/if [ "$v" != "$LIVE" ]; then FINDINGS+=("PINNED/' pinned_eq_live
mutant unknown-live-proceeds   's/^if \[ -z "\$LIVE" \]; then/if false; then/' live_unknown
mutant notify-every-run        's/if \[ "\$SIG" != "\$PREV" \]; then/if true; then/' stale_plist
mutant no-config-yaml-check    's/^  \[ -r "\$d\/config.yaml" \] .*$/  :/' rig_config_only
mutant no-metadata-check       's/^  \[ -r "\$d\/metadata.json" \] .*$/  :/' rig_three_sources
mutant unreadable-is-clean     's/\[ "\$UNREADABLE" -gt 0 \]; then$/[ "$UNREADABLE" -gt 99999 ]; then/' unreadable_inconclusive
mutant gc-dolt-port-unwatched  's/for k in BEADS_DOLT_PORT BEADS_DOLT_SERVER_PORT GC_DOLT_PORT; do/for k in BEADS_DOLT_PORT BEADS_DOLT_SERVER_PORT; do/' gc_dolt_port
mutant no-recovery-notify      's/_notify .Porta do Dolt: pins limpos. .*; fi/true; fi/' recovery
mutant lock-ignored            's/^mkdir "\$LOCK" 2>\/dev\/null || .*$/mkdir "$LOCK" 2>\/dev\/null || true/' lock
mutant skip-dirs-ignored       's/^  case " \$SKIP_DIRS " in .*$/  :/' skip_dir

echo; echo "dolt-port-pin-guard selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
