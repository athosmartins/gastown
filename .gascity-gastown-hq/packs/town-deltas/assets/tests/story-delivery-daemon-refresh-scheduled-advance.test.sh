#!/usr/bin/env bash
# story-delivery-daemon-refresh-scheduled-advance.test.sh — regression test for
# ga-xx7qt7a (extracts the real "Step 0-pre" block and the real runtime_head_at_epoch
# from story-delivery.sh, no duplication — same technique as
# story-delivery-daemon-refresh-idle-advance.test.sh).
#
# THE BUG (ga-xx7qt7a, measured 27/10): the property_scrapers baseline marker sat on
# c6246465d from 25/10 02:58 while the runtime checkout was already at 9cd23eb
# (= origin/main; deploy.sh resets it before every job). The delta touched
# lib/hetzner_dispatch.py and runner.py, so the idle check of ga-thoo16 refused it
# ("only the helper's verdict from Step 5b can move it") — and Step 5b only runs for a
# STORY delivered into that rig, of which there had been none. Nothing running could
# be older than 9cd23eb: no com.scrapers.* plist has KeepAlive, every one is a
# scheduled job, no process of the runtime was alive. The freeze was false and only
# the alarm (Step 0a) said so.
#
# WHY NOT ASK daemon-refresh.sh (measured 27/10, load 70): a DRY_RUN=1 probe of this very
# delta hit `timeout 180` without finishing discovery, and for this rig it registers
# every com.scrapers.* "with no known entrypoint" — AFFECTED=<empty> would mean "could
# not attribute", not "checked clean". The proof here is therefore rig-wide and needs no
# attribution: NOTHING launched from this runtime can be running code older than HEAD.
#
# THE FIX: when marker..HEAD holds code (the ga-thoo16 check refuses) the marker still
# moves to HEAD, rig-wide, iff ALL of this holds, each with its own three states
# (yes / no / could-not-tell — only "yes" advances):
#   - the delta lists, touches no *.plist (a plist in the delta is a job that may not be
#     installed: JOB_NOT_INSTALLED is Step 5b's call), and the checkout has no tracked
#     local modification (the files on disk ARE HEAD);
#   - the rig has no extra_runtime_roots (second clones are synced by someone else);
#   - at least ONE launchd job (a plist in LaunchAgents) names the runtime checkout, no
#     such plist is unreadable-and-naming-it, and none has KeepAlive (true, or a dict);
#   - every such job that has a live process started after HEAD arrived in the checkout
#     (runtime_head_at_epoch of its start = HEAD, or a commit whose distance to HEAD is
#     inert). A start time that cannot be read, or an arrival the reflog cannot place, is
#     "não sei", never fresh.
# The per-daemon pins ($RIG.perdaemon) are NOT touched by this path.
#
# Timeline (committer date = reflog stamp; T0 = 1760000000):
#   C0 T0+1000 base      C1 T0+2000 runner.py + lib/hetzner_dispatch.py + docs
#   C2 T0+3000 docs only C3 T0+4000 templates/com.x.job.plist + docs
#
# S1   the measured case: marker C0, HEAD C1, three scheduled jobs, none running → advances.
# S2   KeepAlive: true / dict hold; false and absent do not; a KeepAlive job that does NOT
#      name the runtime does not hold; a nested (env / bash -c) mention does tie.
# S3   a live job: started before HEAD arrived → holds; after → advances; started at an
#      inert distance (C1 start, HEAD C2) → advances; before C1 with HEAD C2 → holds.
# S4   could-not-tell: ps unreadable / garbage, launchctl failing or empty, a start the
#      reflog cannot place → holds.
# S5   plists: unreadable-and-naming-the-runtime holds, unreadable-and-not-naming it is
#      ignored (the real com.athos.ckan_pbh case), no Label (or one with a glob/separator
#      character) holds, no job at all holds.
# S6   delta with a *.plist holds; dirty checkout holds; extra_runtime_roots holds (and so
#      does a runbook read that failed).
# S7   DRY_RUN=1 writes nothing and says it WOULD; the pins file is byte-for-byte after an
#      advance; the old docs-only path still moves pins; a marker that is not an ancestor
#      and a git failure still hold.
# S8   the reason is logged once per (marker, HEAD, class), and again when the class changes.

# No `pipefail` at file level (ga-uel7sb): see story-delivery-daemon-refresh-staleness-alarm.test.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY="${DELIVERY_UNDER_TEST:-$SCRIPT_DIR/../story-delivery.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

BLOCK="$(sed -n '/# ── Step 0-pre: daemon-refresh baseline/,/# ── Step 0a: daemon-refresh baseline staleness alarm/p' "$DELIVERY" | sed '$d')"
if [ -z "$BLOCK" ]; then
  nok "Step 0-pre block exists in $(basename "$DELIVERY")" "no '# ── Step 0-pre: daemon-refresh baseline' header found"
  echo ""; echo "story-delivery scheduled-job advance tests: $PASS passed, $FAIL failed"; exit 1
fi
HEAD_FN="$(sed -n '/^runtime_head_at_epoch() {/,/^}/p' "$DELIVERY")"
if [ -z "$HEAD_FN" ]; then
  nok "runtime_head_at_epoch exists in $(basename "$DELIVERY")"
  echo ""; echo "story-delivery scheduled-job advance tests: $PASS passed, $FAIL failed"; exit 1
fi

# The live-process cases turn a ps start time into an epoch with BSD `date -j -f`, as the
# helper does; where that does not exist (the Linux node) they are SKIPPED, loudly.
BSD_DATE=0
[ "$(TZ=UTC date -j -f '%a %b %e %T %Y' 'Thu Jan  1 00:01:40 1970' +%s 2>/dev/null)" = "100" ] && BSD_DATE=1

G() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
T0=1760000000
gitc() { local r="$1" e="$2"; shift 2; GIT_COMMITTER_DATE="@$e +0000" GIT_AUTHOR_DATE="@$e +0000" G -C "$r" "$@"; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# mk_repo <dir> <upto 0..3>: linear history C0..C<upto>, HEAD on the last one. The commits carry
# fixed dates and identity, so the SHAs are identical across the repos built here.
mk_repo() {
  local d="$1" upto="$2"
  mkdir -p "$d"; git init -q -b main "$d"
  mkdir -p "$d/docs" "$d/lib" "$d/tests" "$d/templates"
  echo "print(1)" > "$d/runner.py"; echo "x=1" > "$d/lib/util.py"; echo "# r" > "$d/README.md"
  echo a > "$d/docs/a.md"; echo t > "$d/tests/test_a.py"
  G -C "$d" add -A; gitc "$d" $((T0+1000)) commit -q -m C0
  [ "$upto" -ge 1 ] || return 0
  echo "print(2)" > "$d/runner.py"; echo "h=1" > "$d/lib/hetzner_dispatch.py"; echo b > "$d/docs/b.md"
  G -C "$d" add -A; gitc "$d" $((T0+2000)) commit -q -m C1
  [ "$upto" -ge 2 ] || return 0
  echo c > "$d/docs/c.md"; G -C "$d" add -A; gitc "$d" $((T0+3000)) commit -q -m C2
  [ "$upto" -ge 3 ] || return 0
  echo "<plist/>" > "$d/templates/com.x.job.plist"; echo d > "$d/docs/d.md"
  G -C "$d" add -A; gitc "$d" $((T0+4000)) commit -q -m C3
}
RT1="$TMP_ROOT/rt1"; RT2="$TMP_ROOT/rt2"; RT3="$TMP_ROOT/rt3"
mk_repo "$RT1" 1; mk_repo "$RT2" 2; mk_repo "$RT3" 3
sha_of() { G -C "$RT3" rev-parse "$1"; }
C0="$(sha_of "HEAD~3")"; C1="$(sha_of "HEAD~2")"; C2="$(sha_of "HEAD~1")"; C3="$(sha_of HEAD)"
[ "$(G -C "$RT1" rev-parse HEAD)" = "$C1" ] && [ "$(G -C "$RT2" rev-parse HEAD)" = "$C2" ] \
  || { nok "fixture: the three repos share their history (same SHAs)"; echo "$PASS passed, $FAIL failed"; exit 1; }

# ── fixture world: LaunchAgents dir, launchctl and ps stubs, baseline dir ──
new_city() {
  CITY="$(mktemp -d "$TMP_ROOT/city.XXXXXX")"
  BASE="$CITY/.gc/runtime/daemon-refresh-baseline"; mkdir -p "$BASE"
  AGENTS="$CITY/agents"; mkdir -p "$AGENTS"
  BIN="$CITY/bin"; mkdir -p "$BIN"
  PS_DIR="$CITY/ps"; mkdir -p "$PS_DIR"
  LT_FILE="$CITY/launchctl.table"; LT_FAIL="$CITY/launchctl.fail"
  LOG_FILE="$CITY/log.log"; : > "$LOG_FILE"
  cat > "$BIN/launchctl" <<'SH'
#!/bin/sh
[ -f "$LT_FAIL" ] && exit 1
[ -f "$LT_FILE" ] && cat "$LT_FILE"
exit 0
SH
  cat > "$BIN/ps" <<'SH'
#!/bin/sh
pid=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-p" ]; then pid="$2"; shift; fi
  shift
done
if [ -n "$pid" ] && [ -f "$PS_DIR/$pid" ]; then cat "$PS_DIR/$pid"; exit 0; fi
exit 1
SH
  chmod +x "$BIN/launchctl" "$BIN/ps"
  EXTRA_OUT=""; EXTRA_FAIL=0; BREAK_GIT=0
  set_table
}
# set_table [label=pid ...]: pid "-" = loaded but idle. Unrelated rows are always present.
set_table() {
  { printf 'PID\tStatus\tLabel\n'
    printf -- '-\t0\tcom.apple.unrelated.one\n812\t0\tcom.apple.unrelated.two\n'
    local kv; for kv in "$@"; do printf '%s\t0\t%s\n' "${kv#*=}" "${kv%%=*}"; done
  } > "$LT_FILE"
}
# set_ps <pid> <epoch>: what `ps -o lstart= -p <pid>` prints (UTC, as the block runs with TZ=UTC).
set_ps() { TZ=UTC date -j -r "$2" '+%a %b %e %T %Y' > "$PS_DIR/$1" 2>/dev/null || echo "bad date" > "$PS_DIR/$1"; }

# mkplist <label> <ka: none|true|false|dict> <string naming (or not) the runtime> [<nest: arg|env|bash>]
mkplist() {
  local label="$1" ka="$2" path="$3" nest="${4:-arg}" kaxml="" progxml envxml=""
  case "$ka" in
    true)  kaxml='<key>KeepAlive</key><true/>' ;;
    false) kaxml='<key>KeepAlive</key><false/>' ;;
    dict)  kaxml='<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>' ;;
    none)  ;;
  esac
  case "$nest" in
    arg)  progxml="<string>/usr/bin/python3</string><string>$path/runner.py</string>" ;;
    bash) progxml="<string>/bin/bash</string><string>-c</string><string>cd $path &amp;&amp; ./go.sh</string>" ;;
    env)  progxml="<string>/usr/bin/python3</string><string>/opt/elsewhere/x.py</string>"
          envxml="<key>EnvironmentVariables</key><dict><key>PYTHONPATH</key><string>$path/lib</string></dict>" ;;
  esac
  cat > "$AGENTS/$label.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>$label</string>
<key>ProgramArguments</key><array>$progxml</array>$envxml$kaxml</dict></plist>
EOF
}
# the measured roster: three scheduled jobs named after the real ones, all tied to <rt>
sched_roster() { local rt="$1" l; for l in com.scrapers.daily com.scrapers.watchdog com.scrapers.blow; do mkplist "$l" none "$rt"; done; }

marker() { tr -d '[:space:]' < "$BASE/property_scrapers.sha" 2>/dev/null || true; }
seed_marker() { printf '%s\n' "$1" > "$BASE/property_scrapers.sha"; }
PD_SEED() {
  printf '%s\n' "com.scrapers.daily $C0" "com.scrapers.watchdog $C0 stuck" "com.scrapers.nosha" > "$BASE/property_scrapers.perdaemon"
}

# run_block <rt> [dry]: the real block under the production shell options.
run_block() {
  local RTX="$1" dry="${2:-0}"
  (
    set -euo pipefail
    GC_CITY="$CITY"; DRY_RUN="$dry"
    export LAUNCH_AGENTS_DIR="$AGENTS" LAUNCHCTL_BIN="$BIN/launchctl" PS_BIN="$BIN/ps" TZ=UTC PS_DIR LT_FILE LT_FAIL
    [ "$BREAK_GIT" != "1" ] || export GIT_DIR="$TMP_ROOT/no-such-git-dir"
    log()  { echo "$*" >> "$LOG_FILE"; }
    warn() { echo "WARN: $*" >> "$LOG_FILE"; }
    err()  { echo "ERR: $*" >> "$LOG_FILE"; }
    get_runbook_field() {
      case "$2" in
        runtime_dir) echo "$RTX" ;;
        extra_runtime_roots) [ "$EXTRA_FAIL" != "1" ] || return 1; [ -z "$EXTRA_OUT" ] || printf '%s\n' "$EXTRA_OUT"; return 0 ;;
        *) return 1 ;;
      esac
    }
    eval "$HEAD_FN"
    for _t in _once; do eval "$BLOCK"; done
  ) >"$CITY/block.out" 2>&1
  BLOCK_RC=$?
  LOG_CONTENT="$(cat "$LOG_FILE" 2>/dev/null || true)"
}
logged() { case "$LOG_CONTENT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# expect_advance <name> <sha> / expect_hold <name> <sha> [<text the log must contain>]
expect_advance() {
  [ "$BLOCK_RC" -eq 0 ] || { nok "$1: block exits 0 under set -euo pipefail" "rc=$BLOCK_RC out=$(cat "$CITY/block.out")"; return; }
  if [ "$(marker)" = "$2" ]; then ok "$1: marker advanced"; else nok "$1: marker advanced" "got '$(marker)' want '$2' LOG=[$LOG_CONTENT]"; fi
}
expect_hold() {
  [ "$BLOCK_RC" -eq 0 ] || { nok "$1: block exits 0 under set -euo pipefail" "rc=$BLOCK_RC out=$(cat "$CITY/block.out")"; return; }
  if [ "$(marker)" != "$2" ]; then nok "$1: marker NOT advanced" "got '$(marker)' want to stay '$2'"; return; fi
  if [ -n "${3:-}" ]; then
    if logged "$3"; then ok "$1: held, and the log says why ($3)"; else nok "$1: the reason names '$3'" "LOG=[$LOG_CONTENT]"; fi
  else
    ok "$1: marker NOT advanced"
  fi
}

# ── S1: the measured case ────────────────────────────────────────────────────
new_city; seed_marker "$C0"; PD_SEED; sched_roster "$RT1"; set_table com.scrapers.daily=- com.scrapers.watchdog=- com.scrapers.blow=-
printf '%s' "$C0 $C1" > "$BASE/property_scrapers.idle-advance-why"
PD_BEFORE="$(cat "$BASE/property_scrapers.perdaemon")"
run_block "$RT1"
expect_advance "S1 scheduled jobs only, none running (the 27/10 property_scrapers case)" "$C1"
logged "ga-xx7qt7a" && ok "S1 the log names the bead" || nok "S1 log names ga-xx7qt7a" "LOG=[$LOG_CONTENT]"
logged "3 job(s) launched from the runtime, none with KeepAlive, 0 with a live process" \
  && ok "S1 the summary counts 3 jobs tied to the runtime and 0 live processes" || nok "S1 summary" "LOG=[$LOG_CONTENT]"
[ "$(cat "$BASE/property_scrapers.perdaemon")" = "$PD_BEFORE" ] \
  && ok "S1 the per-daemon pins file is byte-for-byte untouched (incl. the 'stuck' pin)" || nok "S1 pins file changed"
[ ! -e "$BASE/property_scrapers.idle-advance-why" ] && ok "S1 the stale 'why' memo is cleared on advance" || nok "S1 why memo left behind"

# ── S2: KeepAlive ────────────────────────────────────────────────────────────
new_city; seed_marker "$C0"; sched_roster "$RT1"; mkplist com.scrapers.keeper true "$RT1"
run_block "$RT1"; expect_hold "S2a KeepAlive=true job tied to the runtime" "$C0" "com.scrapers.keeper"
logged "KeepAlive" && ok "S2a the reason says KeepAlive" || nok "S2a reason says KeepAlive" "LOG=[$LOG_CONTENT]"
new_city; seed_marker "$C0"; sched_roster "$RT1"; mkplist com.scrapers.keeper dict "$RT1"
run_block "$RT1"; expect_hold "S2b KeepAlive as a dict (conditional respawn) is still KeepAlive" "$C0" "com.scrapers.keeper"
new_city; seed_marker "$C0"; sched_roster "$RT1"; mkplist com.scrapers.explicit-false false "$RT1"
run_block "$RT1"; expect_advance "S2c KeepAlive explicitly false is not KeepAlive" "$C1"
new_city; seed_marker "$C0"; sched_roster "$RT1"; mkplist com.other.keeper true "/opt/some/other/checkout"
run_block "$RT1"; expect_advance "S2d a KeepAlive job that does NOT name the runtime does not hold it" "$C1"
new_city; seed_marker "$C0"; sched_roster "$RT1"; mkplist com.scrapers.keeper-env true "$RT1" env
run_block "$RT1"; expect_hold "S2e KeepAlive job that names the runtime only in EnvironmentVariables" "$C0" "com.scrapers.keeper-env"
new_city; seed_marker "$C0"; sched_roster "$RT1"; mkplist com.scrapers.keeper-bash true "$RT1" bash
run_block "$RT1"; expect_hold "S2f KeepAlive job that names the runtime only inside a bash -c string" "$C0" "com.scrapers.keeper-bash"

# ── S3: live processes (BSD date needed) ─────────────────────────────────────
if [ "$BSD_DATE" = "1" ]; then
  new_city; seed_marker "$C0"; sched_roster "$RT1"; set_table com.scrapers.daily=4242; set_ps 4242 $((T0+1500))
  run_block "$RT1"; expect_hold "S3a job running since BEFORE HEAD arrived in the checkout" "$C0" "com.scrapers.daily"
  logged "4242" && ok "S3a the reason names the pid" || nok "S3a reason names the pid" "LOG=[$LOG_CONTENT]"
  new_city; seed_marker "$C0"; sched_roster "$RT1"; set_table com.scrapers.daily=4242; set_ps 4242 $((T0+2500))
  run_block "$RT1"; expect_advance "S3b job running that started AFTER HEAD arrived" "$C1"
  logged "1 with a live process" && ok "S3b the live-process branch was exercised (1 live process counted)" || nok "S3b live branch" "LOG=[$LOG_CONTENT]"
  new_city; seed_marker "$C0"; sched_roster "$RT2"; set_table com.scrapers.daily=4242; set_ps 4242 $((T0+2500))
  run_block "$RT2"; expect_advance "S3c job started at C1, HEAD is C2 (C1..C2 is docs-only): inert distance" "$C2"
  logged "1 with a live process" && ok "S3c the inert-distance branch was exercised (1 live process counted)" || nok "S3c live branch" "LOG=[$LOG_CONTENT]"
  new_city; seed_marker "$C0"; sched_roster "$RT2"; set_table com.scrapers.daily=4242; set_ps 4242 $((T0+1500))
  run_block "$RT2"; expect_hold "S3d job started at C0, HEAD is C2 (C0..C2 holds code)" "$C0" "com.scrapers.daily"
  new_city; seed_marker "$C0"; sched_roster "$RT1"; set_table com.scrapers.daily=4242; set_ps 4242 $((T0+500))
  run_block "$RT1"; expect_hold "S3e job started before the reflog remembers anything" "$C0" "com.scrapers.daily"
else
  echo "  SKIP - S3a-S3e live-process cases need BSD date -j -f (this host has none)"
fi

# ── S4: could-not-tell ───────────────────────────────────────────────────────
new_city; seed_marker "$C0"; sched_roster "$RT1"; set_table com.scrapers.daily=4242   # no ps file → ps fails
run_block "$RT1"; expect_hold "S4a live pid whose start time ps cannot read" "$C0" "com.scrapers.daily"
new_city; seed_marker "$C0"; sched_roster "$RT1"; set_table com.scrapers.daily=4242; echo "garbage in the lstart column" > "$PS_DIR/4242"
run_block "$RT1"; expect_hold "S4b live pid whose start time does not parse" "$C0" "com.scrapers.daily"
new_city; seed_marker "$C0"; sched_roster "$RT1"; : > "$LT_FAIL"
run_block "$RT1"; expect_hold "S4c launchctl list fails" "$C0" "launchctl"
new_city; seed_marker "$C0"; sched_roster "$RT1"; : > "$LT_FILE"
run_block "$RT1"; expect_hold "S4d launchctl list prints nothing (not even its header)" "$C0" "launchctl"
new_city; seed_marker "$C0"; sched_roster "$RT1"; set_table com.scrapers.daily=notanumber
run_block "$RT1"; expect_hold "S4e a pid column that is neither a number nor '-'" "$C0" "com.scrapers.daily"
new_city; seed_marker "$C0"; sched_roster "$RT1"; rm -rf "$AGENTS"
run_block "$RT1"; expect_hold "S4f the LaunchAgents directory cannot be read" "$C0" "LaunchAgents"

# ── S5: plists ───────────────────────────────────────────────────────────────
new_city; seed_marker "$C0"; sched_roster "$RT1"; printf 'not xml <<< %s/runner.py\n' "$RT1" > "$AGENTS/com.broken.names-runtime.plist"
run_block "$RT1"; expect_hold "S5a unreadable plist that NAMES the runtime" "$C0" "com.broken.names-runtime.plist"
new_city; seed_marker "$C0"; sched_roster "$RT1"; printf 'not xml at all\n' > "$AGENTS/com.athos.ckan_pbh.plist"
run_block "$RT1"; expect_advance "S5b unreadable plist that does NOT name the runtime is not this rig's job" "$C1"
new_city; seed_marker "$C0"; sched_roster "$RT1"
cat > "$AGENTS/nolabel.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>ProgramArguments</key><array><string>$RT1/runner.py</string></array></dict></plist>
EOF
run_block "$RT1"; expect_hold "S5c plist that names the runtime but has no Label (cannot be asked of launchd)" "$C0" "nolabel.plist"
new_city; seed_marker "$C0"
run_block "$RT1"; expect_hold "S5d no launchd job names the runtime: an empty roster is not proof" "$C0" "no launchd job"
new_city; seed_marker "$C0"; sched_roster "$RT1"; ln -s "$TMP_ROOT/does-not-exist" "$AGENTS/dead-link.plist"
run_block "$RT1"; expect_hold "S5e a plist that cannot be read at all (dead symlink) is unknown, not absent" "$C0" "dead-link.plist"
new_city; seed_marker "$C0"; sched_roster "$RT1"; mkplist 'com.scrapers.*' none "$RT1"
run_block "$RT1"; expect_hold "S5f a label with a glob character cannot be told apart from a pattern: held as unknown" "$C0" "NOLABEL"

# ── S6: delta / checkout / rig ───────────────────────────────────────────────
new_city; seed_marker "$C0"; sched_roster "$RT3"
run_block "$RT3"; expect_hold "S6a delta C0..C3 carries a *.plist" "$C0" "plist"
new_city; seed_marker "$C0"; sched_roster "$RT1"; echo "print(3)" >> "$RT1/runner.py"
run_block "$RT1"; G -C "$RT1" checkout -q -- runner.py
expect_hold "S6b tracked file modified in the runtime checkout" "$C0" "runner.py"
new_city; seed_marker "$C0"; sched_roster "$RT1"; EXTRA_OUT="/Users/x/painel-prod"
run_block "$RT1"; expect_hold "S6c rig has extra_runtime_roots" "$C0" "extra_runtime_roots"
new_city; seed_marker "$C0"; sched_roster "$RT1"; EXTRA_FAIL=1
run_block "$RT1"; expect_hold "S6d the runbook read of extra_runtime_roots failed" "$C0" "extra_runtime_roots"
new_city; seed_marker "$C0"; sched_roster "$RT1"; BREAK_GIT=1
run_block "$RT1"; expect_hold "S6e git itself failing" "$C0"
new_city; seed_marker "$C2"; sched_roster "$RT1"     # C2 is not an ancestor of RT1's HEAD (C1)
run_block "$RT1"; expect_hold "S6f marker is not an ancestor of HEAD (reset): this path does not engage" "$C2"

# ── S7: dry run, old path, pins ──────────────────────────────────────────────
new_city; seed_marker "$C0"; PD_SEED; sched_roster "$RT1"; PD_BEFORE="$(cat "$BASE/property_scrapers.perdaemon")"
run_block "$RT1" 1
[ "$(marker)" = "$C0" ] && [ "$(cat "$BASE/property_scrapers.perdaemon")" = "$PD_BEFORE" ] \
  && ok "S7a DRY_RUN=1 writes nothing" || nok "S7a DRY_RUN=1 wrote something" "marker=$(marker)"
case "$LOG_CONTENT" in *WOULD*advance*ga-xx7qt7a*) ok "S7a DRY_RUN=1 says it WOULD advance" ;; *) nok "S7a DRY_RUN=1 log" "LOG=[$LOG_CONTENT]" ;; esac
# the ga-thoo16 path must keep moving pins, and must not need a single launchd job to do it
new_city; seed_marker "$C1"; printf '%s\n' "com.scrapers.daily $C1" > "$BASE/property_scrapers.perdaemon"; mkplist com.scrapers.keeper true "$RT2"
run_block "$RT2"
[ "$(marker)" = "$C2" ] && [ "$(cat "$BASE/property_scrapers.perdaemon")" = "com.scrapers.daily $C2" ] \
  && ok "S7b docs-only delta: the ga-thoo16 path still moves marker and pins, KeepAlive job or not" \
  || nok "S7b docs-only path" "marker=$(marker) pins=$(cat "$BASE/property_scrapers.perdaemon")"

# ── S8: the reason is logged once per (marker, HEAD, class) ──────────────────
new_city; seed_marker "$C0"; sched_roster "$RT1"; mkplist com.scrapers.keeper true "$RT1"
run_block "$RT1"; N1="$(grep -c "NOT advanced" "$LOG_FILE")"
run_block "$RT1"; N2="$(grep -c "NOT advanced" "$LOG_FILE")"
[ "$N1" = "1" ] && [ "$N2" = "1" ] && ok "S8a same reason class twice: logged once" || nok "S8a dedup" "after 1st: $N1, after 2nd: $N2"
rm -f "$AGENTS/com.scrapers.keeper.plist"; : > "$LT_FAIL"       # a different class now
run_block "$RT1"; N3="$(grep -c "NOT advanced" "$LOG_FILE")"
[ "$N3" = "2" ] && ok "S8b the reason class changed (KeepAlive → launchctl): logged again" || nok "S8b class change" "count=$N3 LOG=[$(cat "$LOG_FILE")]"

echo ""
echo "story-delivery scheduled-job advance tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
