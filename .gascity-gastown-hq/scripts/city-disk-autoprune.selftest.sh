#!/usr/bin/env bash
# city-disk-autoprune.selftest.sh — hermetic regression test for the
# worktree-pruning eligibility guards in city-disk-autoprune.sh (ga-x8h8m).
#
# THE BUG: the pruner's only eligibility test was "HEAD is an ancestor of
# origin/main" ("merged"). A branch freshly cut from main's own tip satisfies
# that trivially, before its first commit — so a worker still in its
# read/explore phase (nothing edited yet) looked identical to "already
# shipped", and its worktree could be removed out from under it minutes after
# creation (wa-9army, 2026-09-12). The fix adds two more required guards:
# the worktree must have existed WORKTREE_MIN_AGE_HOURS, and no live process
# may be using it right now.
#
# SAFETY: the target script ALSO always (a) sweeps every rig via `gc rig
# list` and (b) runs prune_worktrees() against the hardcoded, real
# "/Users/athos/gt" — neither is parameterized by any CITY_AUTOPRUNE_* env
# var. Left alone, a test that overrides WORKTREE_MIN_AGE_HOURS=0 to exercise
# the removal path could delete real, live worktrees on this machine
# (including the one this very fix was developed in). So this test shims
# `gc` (reports zero rigs) and `git` (no-ops any `-C` call scoped to
# /Users/athos/gt or a path under it; everything else — our own $WORK
# fixtures — passes straight through to the real git). Verify that guarantee
# holds before trusting any other assertion below.
#
# Exits 0 on PASS, non-zero on first-failure tally ("RESULT: N passed, M
# failed" is always printed).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/city-disk-autoprune.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { echo "  ok: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*" >&2; FAIL=$((FAIL+1)); }

# Canonicalize: on macOS, mktemp -d returns a /var/... path, but /var is a
# symlink to /private/var — git (and our own stat-based age check) report
# the RESOLVED path, so an un-canonicalized $WORK makes every string
# comparison below (wt_exists, last_event_for, and the target script's own
# "is this the main checkout" guard) silently mismatch against a worktree
# that is actually still sitting right there.
WORK="$(cd "$(mktemp -d)" && pwd -P)"
BG_PIDS=""
cleanup() {
  for p in $BG_PIDS; do kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

# ── safety shims (see header) ────────────────────────────────────────────────
SHIM_DIR="$WORK/bin"
mkdir -p "$SHIM_DIR"

cat > "$SHIM_DIR/gc" <<'SHIM'
#!/usr/bin/env bash
# Reports exactly one rig: the fixture path the caller names via
# SELFTEST_FIXTURE_RIG (this is how the target script's worktree-pruning
# ever reaches our fixtures at all — it is driven entirely by `gc rig list`
# output plus the hardcoded /Users/athos/gt, never by GC_CITY_PATH). With no
# fixture set, reports zero rigs so a real rig on this machine is never swept.
case "$1 $2" in
  "rig list")
    if [ -n "${SELFTEST_FIXTURE_RIG:-}" ]; then
      printf '{"rigs":[{"path":"%s"}]}' "$SELFTEST_FIXTURE_RIG"
    else
      echo '{"rigs":[]}'
    fi
    ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$SHIM_DIR/gc"

cat > "$SHIM_DIR/git" <<'SHIM'
#!/usr/bin/env bash
REAL_GIT="$(command -v -p git)"
prev=""
for a in "$@"; do
  if [ "$prev" = "-C" ]; then
    case "$a" in
      /Users/athos/gt|/Users/athos/gt/*) exit 0 ;;   # no-op: the real, live tree
    esac
  fi
  prev="$a"
done
exec "$REAL_GIT" "$@"
SHIM
chmod +x "$SHIM_DIR/git"

# ── fixture + run helpers ─────────────────────────────────────────────────────
new_city() {  # new_city <city-dir> — a throwaway "bare remote" + "main" checkout
  local city="$1"
  rm -rf "$city"; mkdir -p "$city/.gc/logs"
  git init -q --bare "$city/bare.git"
  git init -q -b main "$city/main"
  git -C "$city/main" config user.email t@example.com
  git -C "$city/main" config user.name t
  echo one > "$city/main/f.txt"
  git -C "$city/main" add f.txt
  git -C "$city/main" commit -q -m init
  git -C "$city/main" remote add origin "$city/bare.git"
  git -C "$city/main" push -q origin main
  git -C "$city/main" fetch -q origin
}

LOG_ENV=""
run() {  # run <city> [extra CITY_AUTOPRUNE_* env assignments...]
  local city="$1"; shift
  LOG_ENV="$city/.gc/logs/autoprune.jsonl"
  env -i PATH="$SHIM_DIR:$PATH" HOME="$HOME" \
      GC_CITY_PATH="$city" \
      SELFTEST_FIXTURE_RIG="$city/main" \
      CITY_AUTOPRUNE_LOG="$LOG_ENV" \
      CITY_AUTOPRUNE_TRANSCRIPT_ROOT="$city/no-transcripts" \
      CITY_AUTOPRUNE_LOG_CAP_MB=999999999 \
      CITY_AUTOPRUNE_ENABLED=1 \
      "$@" \
      bash "$SCRIPT" >/dev/null 2>&1
}

wt_exists() {  # wt_exists <repo> <wt-path>
  git -C "$1" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}' | grep -qxF "$2"
}

last_event_for() {  # last_event_for <wt-path> -> last jsonl line mentioning it
  grep -F "\"wt\":\"$1\"" "$LOG_ENV" 2>/dev/null | tail -1
}

# ── safety self-check: prove the shims actually neutralize the real tree ────
echo "== test 0 (safety self-check): a run with the removal guards wide open never touches the real /Users/athos/gt tree =="
before_wt_count="$(git -C /Users/athos/gt worktree list --porcelain 2>/dev/null | grep -c '^worktree ')"
city="$WORK/c0"; new_city "$city"
run "$city" CITY_AUTOPRUNE_WORKTREE_MIN_AGE_HOURS=0
after_wt_count="$(git -C /Users/athos/gt worktree list --porcelain 2>/dev/null | grep -c '^worktree ')"
if [ "$before_wt_count" = "$after_wt_count" ]; then ok "real tree worktree count unchanged ($before_wt_count)"; else bad "real tree worktree count changed: $before_wt_count -> $after_wt_count — STOP, investigate before trusting any other result"; fi

echo "== test 1: worktree freshly branched off origin/main tip (default min-age) survives a prune pass — THE regression =="
city="$WORK/c1"; new_city "$city"
wt="$city/wt-young"
git -C "$city/main" worktree add -q "$wt" -b young origin/main
run "$city"   # default CITY_AUTOPRUNE_WORKTREE_MIN_AGE_HOURS=24, no override
if wt_exists "$city/main" "$wt"; then ok "fresh merged worktree NOT removed"; else bad "fresh worktree was removed — the exact ga-x8h8m bug"; fi
case "$(last_event_for "$wt")" in *skip_worktree_too_young*) ok "logged skip_worktree_too_young";; *) bad "expected skip_worktree_too_young, got: $(last_event_for "$wt")";; esac

echo "== test 2: same shape, min-age overridden to 0h -> eligible and removed =="
city="$WORK/c2"; new_city "$city"
wt="$city/wt-old"
git -C "$city/main" worktree add -q "$wt" -b old origin/main
run "$city" CITY_AUTOPRUNE_WORKTREE_MIN_AGE_HOURS=0
if wt_exists "$city/main" "$wt"; then bad "old-enough idle merged worktree was NOT removed"; else ok "old-enough idle merged worktree removed"; fi
case "$(last_event_for "$wt")" in *removed_worktree*) ok "logged removed_worktree";; *) bad "expected removed_worktree, got: $(last_event_for "$wt")";; esac

echo "== test 3: old enough + merged but a live process has it as cwd -> survives =="
city="$WORK/c3"; new_city "$city"
wt="$city/wt-live"
git -C "$city/main" worktree add -q "$wt" -b live origin/main
( cd "$wt" && exec sleep 30 ) & bgpid=$!; BG_PIDS="$BG_PIDS $bgpid"
sleep 0.3   # let the subshell finish its cd before we probe it
run "$city" CITY_AUTOPRUNE_WORKTREE_MIN_AGE_HOURS=0
if wt_exists "$city/main" "$wt"; then ok "live (cwd-in-use) worktree NOT removed"; else bad "live worktree was removed while a process sat in it"; fi
case "$(last_event_for "$wt")" in *skip_worktree_live_process*) ok "logged skip_worktree_live_process";; *) bad "expected skip_worktree_live_process, got: $(last_event_for "$wt")";; esac
kill "$bgpid" 2>/dev/null || true; wait "$bgpid" 2>/dev/null || true

echo "== test 4: old enough + merged + idle but DIRTY -> survives (pre-existing git-refuses behavior, unaffected by the new guards) =="
city="$WORK/c4"; new_city "$city"
wt="$city/wt-dirty"
git -C "$city/main" worktree add -q "$wt" -b dirty origin/main
echo changed >> "$wt/f.txt"
run "$city" CITY_AUTOPRUNE_WORKTREE_MIN_AGE_HOURS=0
if wt_exists "$city/main" "$wt"; then ok "dirty worktree NOT removed"; else bad "dirty worktree was removed"; fi
case "$(last_event_for "$wt")" in *skip_worktree_dirty_or_locked*) ok "logged skip_worktree_dirty_or_locked";; *) bad "expected skip_worktree_dirty_or_locked, got: $(last_event_for "$wt")";; esac

echo "== test 5: unmerged (diverged) branch -> survives regardless of age override =="
city="$WORK/c5"; new_city "$city"
wt="$city/wt-diverged"
git -C "$city/main" worktree add -q "$wt" -b diverged origin/main
echo two > "$wt/g.txt"; git -C "$wt" add g.txt; git -C "$wt" commit -q -m "extra, never pushed"
run "$city" CITY_AUTOPRUNE_WORKTREE_MIN_AGE_HOURS=0
if wt_exists "$city/main" "$wt"; then ok "unmerged worktree NOT removed"; else bad "unmerged worktree was removed"; fi

echo "== test 6: DRY_RUN=1 on an otherwise-eligible worktree -> logs would_remove_worktree, removes nothing =="
city="$WORK/c6"; new_city "$city"
wt="$city/wt-dry"
git -C "$city/main" worktree add -q "$wt" -b dry origin/main
run "$city" CITY_AUTOPRUNE_WORKTREE_MIN_AGE_HOURS=0 CITY_AUTOPRUNE_DRY_RUN=1
if wt_exists "$city/main" "$wt"; then ok "dry-run left the worktree in place"; else bad "dry-run actually removed the worktree"; fi
case "$(last_event_for "$wt")" in *would_remove_worktree*) ok "logged would_remove_worktree";; *) bad "expected would_remove_worktree, got: $(last_event_for "$wt")";; esac

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
echo "PASS"
