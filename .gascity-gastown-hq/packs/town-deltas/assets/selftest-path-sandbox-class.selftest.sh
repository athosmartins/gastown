#!/usr/bin/env bash
# selftest-path-sandbox-class.selftest.sh — ga-ck3sz7: keep the CLASS of ga-d21b40 closed. A pack selftest that stubs
# `gc` / `bd` in a dir it puts in front of the REAL PATH must run the script under test on the gc/bd-free PATH from
# selftest-sandbox-path.lib.sh — otherwise the stub is a promise kept only while the fixture dir exists.
#
# THE CLASS (ga-d21b40, 29/09): a selftest ran the script under test with PATH="$T/bin:$PATH", `$T/bin/gc` being a
# logging stub. The harness died, $T went away with the stub, the script under test lived on, `command -v gc` walked
# down $PATH to /opt/homebrew/bin/gc — the REAL one — and two false "Reaper anomalies" mails reached the Mayor.
# ga-d21b40 fixed the 3 reaper selftests; ga-ck3sz7 converted the ~27 others that had the same shape. Without a guard the
# next selftest written by copying an old one brings the hole back, and nobody notices until a real mail/sling/close goes out.
#
# WHAT IS A LEAKY SELFTEST (all three, judged per FILE, on non-comment lines):
#   1. it writes a `gc` or `bd` stub into a file      (> …/gc, > …/bd, cp|ln|mv|install|tee … /gc|/bd)
#   2. it builds a PATH that still reaches the real one (PATH=…$PATH…, or PATH=…/opt/homebrew/bin…, or …/.local/bin…:
#      the real gc is /opt/homebrew/bin/gc and the real bd is /opt/homebrew/bin/bd -> ~/.local/bin/bd)
#   3. it does NOT use the sandbox (a non-comment line naming selftest-sandbox-path.lib.sh AND a sandbox_path_init call)
# A file that stubs gc/bd only as shell FUNCTIONS (nothing on disk to vanish) or that builds an explicit
# PATH="$stubs:/usr/bin:/bin" never matches 1+2, so it is not asked to convert.
#
# WHAT THIS GUARD DOES NOT SEE (say so, do not pretend): the judgment is per file, not per PATH assignment — a file that
# sandboxes one section and leaks in another passes; a stub written under a variable name (for t in gc bd; do … "$D/$t")
# is not recognised; a PATH assembled in two steps (p="$x:$PATH"; PATH="$p") is not recognised. It closes the copy-an-old-
# selftest route, which is how the class spread, not every conceivable spelling.
#
# EXEMPTIONS are explicit, carry a REASON, and go stale LOUDLY: an exempt file that no longer matches the class (it was
# converted, or stopped stubbing gc/bd) or that no longer exists FAILS this guard until it is taken off the list —
# otherwise the list only ever grows and stops meaning anything.
#
#   A  the detector on fixtures: each leaky shape is caught, each safe shape is let through
#   B  the exemption list: honoured while accurate, STALE when the file converted, STALE when the file is gone
#   C  the real tree: no leaky selftest outside the exemption list
#
# SANDBOX_CLASS_SCAN_ROOT points C at another copy of the pack (used to replay the pre-conversion tree: C must FAIL there).
# Runs under macOS /bin/bash 3.2 and BSD grep/awk: no associative arrays, no `$` inside a regex group.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_NAME="$(basename "${BASH_SOURCE[0]}")"
PACK_ROOT="${SANDBOX_CLASS_SCAN_ROOT:-$HERE/..}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/         /'; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sandbox-class-selftest.XXXXXX")" || exit 1
trap 'rm -rf "$ROOT"' EXIT

# Reasoned exemptions: <path relative to the pack root> and WHY it cannot take the sandboxed PATH.
EXEMPT_LIST="assets/gate-marker-desc-bsd-sed.selftest.sh"
exemption_reason() {
  case "$1" in
    assets/gate-marker-desc-bsd-sed.selftest.sh)
      echo "the script under test (scripts/gate-queue-composition.sh:77) PREPENDS each of ~/.local/bin, /opt/homebrew/bin, /usr/local/bin that is absent from the PATH it is given — i.e. AHEAD of the shim dir, where the real gc/bd live. A sandboxed PATH would lose to the real bd; the selftest therefore names those dirs AFTER its shims so the script prepends nothing. Fix belongs in the script (an opt-out of the prepend), not here" ;;
    *) return 1 ;;
  esac
}

# scan_leaky <root> — print (relative to <root>) every *.selftest.sh under it that matches the class, one per line.
# awk runs once per xargs batch, not once per file: the pack has ~270 selftests and this runs on every gate pass.
# THREE outcomes, not two: leaks found / nothing found / could not scan. If xargs or awk fails the scan returns 3 and
# class_verdict says UNSCANNABLE — an empty result from a broken scan must never read as "no leaks".
SCAN_AWK="$ROOT/scan.awk"
cat > "$SCAN_AWK" <<'AWK'
function flush() {
  if (file != "" && stubs && keeps && !(libref && init)) print file
}
FNR == 1 { flush(); file = FILENAME; stubs = 0; keeps = 0; libref = 0; init = 0 }
/^[[:space:]]*#/ { next }
{
  l = $0 " "
  if (l ~ />[[:space:]]*[^[:space:]>]*\/(gc|bd)["' \t]/) stubs = 1
  if (l ~ /(^|[[:space:];&|(])(cp|ln|mv|install|tee)[[:space:]][^;|&]*\/(gc|bd)["' \t]/) stubs = 1
  if (l ~ /[A-Za-z_]*PATH=[^ \t]*\$\{?PATH[}":\t ]/) keeps = 1
  if (l ~ /[A-Za-z_]*PATH=[^ \t]*(\/opt\/homebrew\/bin|\.local\/bin)/) keeps = 1
  if (l ~ /selftest-sandbox-path\.lib\.sh/) libref = 1
  if (l ~ /(^|[^A-Za-z_])sandbox_path_init[ \t]/) init = 1
}
END { flush() }
AWK
scan_leaky() {
  local root="$1" list out
  list="$ROOT/scan.list"; out="$ROOT/scan.out"
  find "$root" -name '*.selftest.sh' ! -name "$SELF_NAME" 2>/dev/null | sort > "$list"
  [ -s "$list" ] || return 0
  # xargs keeps the awk invocation count low without blowing the arg limit; FNR==1 resets state per file.
  xargs awk -f "$SCAN_AWK" < "$list" > "$out" 2> "$ROOT/scan.err" || return 3
  sed "s#^${root%/}/##" "$out" | sort
}

# class_verdict <root> <exempt-list> — print one line per problem; return non-zero if any.
#   LEAK  <file>            matches the class and is not exempt
#   STALE <file> <why>      exempt, but no longer matches the class / no longer exists
#   UNSCANNABLE <root>      the scan itself failed — no verdict on the tree (NOT the same as "no leaks")
class_verdict() {
  local root="$1" exempt="$2" leaky bad=0 f
  leaky="$(scan_leaky "$root")" || { echo "UNSCANNABLE $root (awk/xargs failed: $(head -c 200 "$ROOT/scan.err" 2>/dev/null | tr '\n' ' '))"; return 1; }
  for f in $leaky; do
    case " $exempt " in *" $f "*) : ;; *) echo "LEAK  $f"; bad=1 ;; esac
  done
  for f in $exempt; do
    if [ ! -f "$root/$f" ]; then echo "STALE $f (file no longer exists — take it off EXEMPT_LIST)"; bad=1
    elif ! grep -Fxq -- "$f" <<<"$leaky"; then echo "STALE $f (no longer matches the class — converted or stopped stubbing gc/bd — take it off EXEMPT_LIST)"; bad=1
    fi
  done
  return $bad
}

# ══ A: the detector on fixtures ══════════════════════════════════════════════════════════════════════════════
echo "A: detector on fixtures"
FX="$ROOT/fx/assets"; mkdir -p "$FX"
fx() { cat > "$FX/$1.selftest.sh"; }

fx leak-gc-ambient <<'EOF'
mkdir -p "$T/bin"
cat > "$T/bin/gc" <<'SHIM'
echo stub
SHIM
PATH="$T/bin:$PATH" bash "$SCRIPT"
EOF
fx leak-bd-redirect-quoted <<'EOF'
printf '#!/bin/sh\nexit 0\n' > "$BIN/bd"
env PATH="$BIN:$PATH" bash "$SCRIPT"
EOF
fx leak-explicit-homebrew <<'EOF'
cat > "$BIN/gc" <<'SHIM'
exit 0
SHIM
PATH="$BIN:/opt/homebrew/bin:/usr/bin:/bin" bash "$SCRIPT"
EOF
fx leak-explicit-local-bin <<'EOF'
cat > "$BIN/bd" <<'SHIM'
exit 0
SHIM
export PATH="$BIN:$HOME/.local/bin:/usr/bin"
EOF
fx leak-copied-stub <<'EOF'
cp "$FIXTURES/fake-gc" "$T/bin/gc"
PATH="$T/bin:${PATH}" bash "$SCRIPT"
EOF
fx leak-lib-only-in-comment <<'EOF'
# TODO: source selftest-sandbox-path.lib.sh and call sandbox_path_init here
cat > "$T/bin/gc" <<'SHIM'
exit 0
SHIM
PATH="$T/bin:$PATH" bash "$SCRIPT"
EOF
fx leak-lib-sourced-never-used <<'EOF'
. "$HERE/selftest-sandbox-path.lib.sh" || exit 2
cat > "$T/bin/gc" <<'SHIM'
exit 0
SHIM
PATH="$T/bin:$PATH" bash "$SCRIPT"
EOF

fx safe-converted <<'EOF'
. "$HERE/selftest-sandbox-path.lib.sh" || exit 2
mkdir -p "$T/bin"
cat > "$T/bin/gc" <<'SHIM'
exit 0
SHIM
sandbox_path_init "$T" jq || exit 2
PATH="$SANDBOX_PATH" bash "$SCRIPT"
EOF
fx safe-converted-via-variable <<'EOF'
LIB="$HERE/selftest-sandbox-path.lib.sh"
. "$LIB" || exit 2
cat > "$T/bin/bd" <<'SHIM'
exit 0
SHIM
sandbox_path_init "$T" || exit 2
# the harness itself may keep the ambient PATH: PATH="$SENT:$PATH" — the file uses the sandbox, that is the judgment
EOF
fx safe-explicit-system-path <<'EOF'
cat > "$BIN/gc" <<'SHIM'
exit 0
SHIM
PATH="$BIN:/usr/bin:/bin:/usr/local/bin" bash "$SCRIPT"
EOF
fx safe-stubs-something-else <<'EOF'
cat > "$BIN/curl" <<'SHIM'
exit 0
SHIM
PATH="$BIN:$PATH" bash "$SCRIPT"
EOF
fx safe-gc-lookalike-names <<'EOF'
cat > "$BIN/gcloud" <<'SHIM'
exit 0
SHIM
cat > "$BIN/mygc" <<'SHIM'
exit 0
SHIM
cat > "$BIN/bdx" <<'SHIM'
exit 0
SHIM
PATH="$BIN:$PATH" bash "$SCRIPT"
EOF
fx safe-function-stub <<'EOF'
bd() { echo "bd $*" >> "$LOG"; }
export -f bd
PATH="$PATH" bash "$SCRIPT"
EOF
fx safe-comment-only <<'EOF'
# the old way: PATH="$T/bin:$PATH" with cat > "$T/bin/gc" — do not do this
echo nothing
EOF
fx safe-other-path-var <<'EOF'
cat > "$BIN/gc" <<'SHIM'
exit 0
SHIM
PYTHONPATH="$X:$PYTHONPATH" LD_LIBRARY_PATH="$L:$LD_LIBRARY_PATH" MANPATH="$M" bash "$SCRIPT"
EOF
# a nested selftest is found too, and the guard never scans itself
mkdir -p "$FX/scripts"; cp "$FX/leak-gc-ambient.selftest.sh" "$FX/scripts/leak-nested.selftest.sh"
cp "$FX/leak-gc-ambient.selftest.sh" "$FX/$SELF_NAME"
printf 'echo not a selftest\n' > "$FX/leak-not-a-selftest.sh"

GOT="$(scan_leaky "$ROOT/fx" | tr '\n' ' ')"
for want in leak-gc-ambient leak-bd-redirect-quoted leak-explicit-homebrew leak-explicit-local-bin leak-copied-stub leak-lib-only-in-comment leak-lib-sourced-never-used; do
  case " $GOT " in *" assets/$want.selftest.sh "*) ok "A caught: $want" ;; *) nok "A MISSED a leaky shape: $want" "scan said: $GOT" ;; esac
done
case " $GOT " in *" assets/scripts/leak-nested.selftest.sh "*) ok "A caught: a selftest in a subdirectory" ;; *) nok "A MISSED the nested selftest" "scan said: $GOT" ;; esac
for safe in safe-converted safe-converted-via-variable safe-explicit-system-path safe-stubs-something-else safe-gc-lookalike-names safe-function-stub safe-comment-only safe-other-path-var; do
  case " $GOT " in *" assets/$safe.selftest.sh "*) nok "A FALSE POSITIVE: $safe is safe and was flagged" ;; *) ok "A let through: $safe" ;; esac
done
case " $GOT " in *" assets/$SELF_NAME "*) nok "A the guard scanned itself" ;; *) ok "A the guard does not scan itself" ;; esac
case " $GOT " in *leak-not-a-selftest.sh*) nok "A scanned a file that is not *.selftest.sh" ;; *) ok "A only *.selftest.sh files are scanned" ;; esac

# ══ B: the exemption list ════════════════════════════════════════════════════════════════════════════════════
echo "B: exemption list"
BAD="$ROOT/b/assets"; mkdir -p "$BAD"
cp "$FX/leak-gc-ambient.selftest.sh" "$BAD/exempt-me.selftest.sh"
V="$(class_verdict "$ROOT/b" "assets/exempt-me.selftest.sh")"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$V" ] && ok "B an exempt leaky file is honoured (no verdict)" || nok "B an exempt leaky file was not honoured" "$V"
V="$(class_verdict "$ROOT/b" "")"; rc=$?
[ "$rc" -ne 0 ] && grep -q '^LEAK  assets/exempt-me.selftest.sh' <<<"$V" && ok "B the same file without the exemption is a LEAK" || nok "B a leaky file was not reported" "rc=$rc $V"
cp "$FX/safe-converted.selftest.sh" "$BAD/exempt-me.selftest.sh"
V="$(class_verdict "$ROOT/b" "assets/exempt-me.selftest.sh")"; rc=$?
[ "$rc" -ne 0 ] && grep -q '^STALE assets/exempt-me.selftest.sh (no longer matches' <<<"$V" && ok "B an exemption for a since-converted file is STALE (fails until removed)" || nok "B a stale exemption went unnoticed" "rc=$rc $V"
V="$(class_verdict "$ROOT/b" "assets/exempt-me.selftest.sh assets/ghost.selftest.sh")"; rc=$?
[ "$rc" -ne 0 ] && grep -q '^STALE assets/ghost.selftest.sh (file no longer exists' <<<"$V" && ok "B an exemption for a file that is gone is STALE" || nok "B a dangling exemption went unnoticed" "rc=$rc $V"
V="$(class_verdict "$ROOT/b" "")"; rc=$?
[ "$rc" -eq 0 ] && ok "B a converted file with no exemption is clean" || nok "B a converted file was reported" "$V"
_good_awk="$SCAN_AWK"; SCAN_AWK="$ROOT/broken.awk"; printf 'this is ( not awk\n' > "$SCAN_AWK"
V="$(class_verdict "$ROOT/b" "")"; rc=$?
SCAN_AWK="$_good_awk"
[ "$rc" -ne 0 ] && grep -q '^UNSCANNABLE ' <<<"$V" && ok "B a scan that FAILS is UNSCANNABLE, never an empty (clean) verdict" || nok "B a failed scan was not reported as such" "rc=$rc $V"
for f in $EXEMPT_LIST; do
  R="$(exemption_reason "$f")" && [ -n "$R" ] && ok "B every exemption carries a reason: $f" || nok "B exemption without a reason: $f"
done

# ══ C: the real tree ═════════════════════════════════════════════════════════════════════════════════════════
echo "C: the pack ($PACK_ROOT)"
N="$(find "$PACK_ROOT" -name '*.selftest.sh' 2>/dev/null | wc -l | tr -d ' ')"
if [ "${N:-0}" -lt 20 ]; then
  nok "C found only $N selftests under $PACK_ROOT — the scan is looking in the wrong place, and an empty scan proves nothing"
else
  ok "C scanning $N selftests"
  V="$(class_verdict "$PACK_ROOT" "$EXEMPT_LIST")"; rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "C no selftest stubs gc/bd in front of the real PATH outside the exemption list"
  else
    nok "C selftests that would reach the REAL gc/bd if their fixture dir vanished" "$V
fix: run the script under test on PATH=\"\$SANDBOX_PATH\" — source selftest-sandbox-path.lib.sh, call sandbox_path_init \"\$T\" <harmless tools>
     (see reaper-selftest-path-leak.selftest.sh for the leak test pattern). If the script under test cannot take a sandboxed PATH, add it to
     EXEMPT_LIST here with the measured reason."
  fi
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
