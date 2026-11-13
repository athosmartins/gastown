#!/usr/bin/env bash
# pilot-dispatcher.ns-sibling-work.selftest.sh — ga-9jrt3o7
#
# BUG: the Pilot's NEVERSTARTED recovery released wa-lytych ("never started") while a builder's worktree
# ~/gt/traco-bim-wt/wa-lytych-e5 held +677/-56 UNCOMMITTED lines (the witness saved them afterwards). Two gaps, both
# measured with the real functions on the unfixed dispatcher before this fix:
#   (1) its "did it start?" test (_beadid_has_branch) reads refs in the town root + the repos of `gc rig list`, and
#       traco-bim is NOT a gc rig (city.toml registers ps/ma/lx/gt/wa only), so its branches were never searched;
#   (2) even with the repo searched, uncommitted work in a worktree that is on a detached HEAD, or not on a bead-named
#       branch, is not a signal anywhere.
# The fix adds _ns_sibling_repos + _beadid_has_sibling_work (repos beside the town root that keep one tree per bead in
# <repo>-wt/) and one guard in _neverstarted_recover_db (+ the owner-grace condition, so its log line stays true).
#
# Contents
#   What it proves · How it runs · Negative control
#
# WHAT IT PROVES (real git repos, no stubbed git except where a failure has to be injected):
#   (1) _ns_sibling_repos: lists <town>/<name> for every <town>/<name>-wt directory that has a repo beside it; ignores a
#       -wt with no repo, a -wt that is a FILE, and the degenerate name "-wt"; an unlistable town root is rc 1 (cannot tell),
#       a listable one with no such repo is rc 0 and empty (nothing to look at).
#   (2) _beadid_has_sibling_work: rc 0 for a worktree named for the bead with uncommitted files (modified, untracked) — THE
#       incident — and for a branch naming the bead; rc 1 for a clean worktree, for another bead's dirty worktree, for a
#       registered worktree whose directory is gone, for a worktree dirty only with files git ignores; case-insensitive,
#       fixed-string (a dot in the id is not a regex dot), safe with a space in the path; the kill switch and the branch
#       seam turn it off; each of the three reads (for-each-ref, worktree list, status) that fails or times out is "cannot
#       tell" = rc 0 with a reason (and the rc), never "found nothing", and one failed read does not blind the next (a stale
#       rc cannot leak between reads); a found work item wins over a doubt from another repo; no git on PATH, an unlistable
#       town root and an empty repo list (never `git -C ""` on the caller's cwd) are handled; the status read is read-only
#       (index untouched, the flags passed); none of the three git calls reads stdin (they run inside here-string loops, where
#       a git that read stdin would swallow the rest of the repo list or of the candidate trees).
#   (3) _neverstarted_recover_db end to end (the REAL function, stubbed bd): the incident bead is KEPT with a log line that
#       names the worktree and never says "releasing never-started in-flight bead" (the big selftest greps that phrase for a
#       release); keeping it does not stop the loop (the next bead is still released); the same bead with nothing on disk, with
#       a clean worktree, or with the switch off IS released; a crew-owned bead past the owner grace is kept too and its log
#       does not claim a release; the old branch guard still wins first.
# HOW IT RUNS: the functions come VERBATIM out of the dispatcher (awk) and run in a child shell under `set -euo pipefail`
#   (the dispatcher's own flags), PATH = stub dir + tools + system dirs (selftest-sandbox-path.lib.sh: no real gc/bd), HOME
#   and git config private. Against a dispatcher without the functions the file refuses to start (exit 2): the honest red.
# NEGATIVE CONTROL: every guard switched off in a copy of the dispatcher must fail this file (see the end).
# Variables: NSW_DISPATCHER (path of the dispatcher under test) · NSW_NO_MUTANTS=1 (skip the control) · NSW_MUTANT=1 (internal)
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${NSW_DISPATCHER:-$SELF_DIR/pilot-dispatcher.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); [ -n "${NSW_MUTANT:-}" ] || echo "  ✓ $*"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $*"; [ -z "${NSW_MUTANT:-}" ] || { echo "RESULT $FAIL/$((PASS+FAIL))"; exit 1; }; }
die() { echo "FATAL: $*" >&2; exit 2; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
kv()  { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

[ -f "$DISPATCHER" ] || die "dispatcher not found at $DISPATCHER"
. "$SELF_DIR/selftest-tmproot-tripwire.lib.sh" || die "cannot source $SELF_DIR/selftest-tmproot-tripwire.lib.sh"
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || die "cannot source $SELF_DIR/selftest-sandbox-path.lib.sh"
command -v git >/dev/null 2>&1 || die "git not found"
ROOT="$(mktemp -d)"
[ -n "$ROOT" ] && [ -d "$ROOT" ] || die "could not create the scratch dir"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/home" "$ROOT/sb/bin" || die "could not create the scratch tree"
# the user's git config (commit signing, hooks, templates) must not reach the fixture repos
export HOME="$ROOT/home" XDG_CONFIG_HOME="$ROOT/home/.config" GIT_CONFIG_NOSYSTEM=1
sandbox_path_init "$ROOT/sb" jq git timeout || exit 2
REAL_GIT="$(command -v git)"
TOOLS_PATH="$ROOT/sb/tools:$_SANDBOX_SYSTEM_DIRS"

# ── the functions under test, VERBATIM from the dispatcher ──────────────────────────────────────────────────────────
extract_fn() { awk -v fn="$1" '$0 == fn"() {" { p=1 } p { print; if ($0 == "}") exit }' "$2"; }
FNS="$ROOT/fns.sh"; : > "$FNS"
for fn in _ns_label_blocks_release _beadid_has_branch _ns_sibling_repos _beadid_has_sibling_work _neverstarted_recover_db; do
  src="$(extract_fn "$fn" "$DISPATCHER")"
  [ -n "$src" ] || die "$fn() not found in $DISPATCHER — extraction failed (ga-9jrt3o7 not applied)"
  printf '%s\n\n' "$src" >> "$FNS"
done
bash -n "$FNS" 2>/dev/null || die "the extracted functions do not parse"

# ── the child drivers (a child shell under the dispatcher's own flags) ──────────────────────────────────────────────
DRV_REPOS="$ROOT/drv_repos.sh"
cat > "$DRV_REPOS" <<'EOF'
. "$FNS"
if _r=$(_ns_sibling_repos); then echo "RC=0"; else echo "RC=1"; fi
printf '%s\n' "$_r" | while IFS= read -r _l; do if [ -n "$_l" ]; then echo "REPO=$_l"; fi; done
EOF
DRV_SIB="$ROOT/drv_sib.sh"
cat > "$DRV_SIB" <<'EOF'
. "$FNS"
if _beadid_has_sibling_work "$1"; then echo "RC=0"; else echo "RC=1"; fi
echo "WHY=${_BSW_WHY:-}"
EOF
DRV_NS="$ROOT/drv_ns.sh"
cat > "$DRV_NS" <<'EOF'
. "$FNS"
warn() { echo "WARN: $*"; }
NOW=1800000000
: > "$NSW_CALLS"
_one() { printf '{"id":"%s","labels":["story:in-flight","pilot:dispatched"],"metadata":{"pilot.dispatched_at":"%s"}}' "$1" "$((NOW-AGE))"; }
INFLIGHT="[$(_one "$BEAD")"
[ -z "${BEAD2:-}" ] || INFLIGHT="$INFLIGHT,$(_one "$BEAD2")"
INFLIGHT="$INFLIGHT]"
bd() { if [ "${3:-}" = "list" ]; then printf '%s' "$INFLIGHT"; else echo "bd $*" >> "$NSW_CALLS"; fi; return 0; }
if [ "${OWNER:-0}" = "1" ]; then
  _beadid_live_crew_owner() { printf 'crew-x'; return 0; }
  _crew_progressed_since() { return 0; }
else
  _beadid_live_crew_owner() { return 1; }
  _crew_progressed_since() { return 1; }
fi
_session_is_live_builder() { return 1; }
_sling_is_live() { return 1; }
STALE_SLING_SECONDS=600; _DEADWORKER_OK=0; PILOT_NEVERSTARTED_MINUTES=15; PILOT_NEVERSTARTED_OWNER_GRACE_HOURS=24
_NS_RIG_LIST_OK=1
_T="$(dirname "$GC_CITY")"
_NS_BRANCH_REPOS="$_T"$'\n'"$_T/whatsapp_automation"
_neverstarted_recover_db "$GC_CITY" "$NOW"
if grep -q "label remove $BEAD story:in-flight" "$NSW_CALLS"; then echo "RELEASED=1"; else echo "RELEASED=0"; fi
if [ -n "${BEAD2:-}" ]; then
  if grep -q "label remove $BEAD2 story:in-flight" "$NSW_CALLS"; then echo "RELEASED2=1"; else echo "RELEASED2=0"; fi
fi
EOF

# child <town> <path> <driver> [VAR=val ...] -- <driver args...>   (everything after the driver goes to it)
child() {
  local town="$1" cpath="$2" drv="$3"; shift 3
  local -a envs=(); while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "$#" -gt 0 ] && shift
  env -i PATH="$cpath" HOME="$ROOT/home" GIT_CONFIG_NOSYSTEM=1 FNS="$FNS" GC_CITY="$town/city" "${envs[@]+"${envs[@]}"}" "$BASH" -euo pipefail "$drv" "$@" 2>&1
}
sib()   { local town="$1" cpath="$2" bead="$3"; shift 3; child "$town" "$cpath" "$DRV_SIB" "$@" -- "$bead"; }
repos() { local town="$1" cpath="$2"; shift 2; child "$town" "$cpath" "$DRV_REPOS" "$@" --; }
nsrun() { local town="$1" bead="$2" age="$3" owner="$4"; shift 4; child "$town" "$TOOLS_PATH" "$DRV_NS" BEAD="$bead" AGE="$age" OWNER="$owner" NSW_CALLS="$ROOT/calls" "$@" --; }

# a stub dir whose `git`/`timeout` shims log argv and fail ONE verb on request (NSW_FAIL_GIT / NSW_FAIL_TIMEOUT), else pass through
mkshims() { # <dir>
  mkdir -p "$1" || return 1
  cat > "$1/git" <<EOF
#!/bin/sh
echo "\$*" >> "\${NSW_GITLOG:-/dev/null}"
if [ -n "\${NSW_GIT_SLURP_STDIN:-}" ]; then cat > /dev/null; fi
if [ -n "\${NSW_FAIL_GIT:-}" ]; then case "\$*" in *"\$NSW_FAIL_GIT"*) exit 3 ;; esac; fi
exec "$REAL_GIT" "\$@"
EOF
  cat > "$1/timeout" <<EOF
#!/bin/sh
if [ -n "\${NSW_FAIL_TIMEOUT:-}" ]; then case "\$*" in *"\$NSW_FAIL_TIMEOUT"*) exit 124 ;; esac; fi
shift
exec "\$@"
EOF
  chmod +x "$1/git" "$1/timeout"
}
mkshims "$ROOT/shims" || die "could not build the shims"
SHIM_PATH="$ROOT/shims:$TOOLS_PATH"
EMPTY_PATH="$ROOT/emptybin"; mkdir -p "$EMPTY_PATH"

# ── fixtures: real repos ────────────────────────────────────────────────────────────────────────────────────────────
GIT() { git -c user.name=nsw -c user.email=nsw@example.invalid -c init.defaultBranch=main "$@"; }
mkrepo() { # <dir> — one commit: f.txt tracked, junk/ ignored
  GIT init -q "$1" >/dev/null 2>&1 || return 1
  printf 'base\n' > "$1/f.txt"; printf 'junk/\n' > "$1/.gitignore"
  GIT -C "$1" add f.txt .gitignore >/dev/null 2>&1 && GIT -C "$1" commit -q -m base >/dev/null 2>&1
}
mktown() { # <dir> — a town root (a repo itself, like ~/gt) with city/, a rig repo and the traco-bim sibling
  mkdir -p "$1/city" || return 1
  _refuse_if_townroot_is_os_tmp "$1" || return 1
  mkrepo "$1" && mkrepo "$1/whatsapp_automation" && mkrepo "$1/traco-bim" && mkdir -p "$1/traco-bim-wt"
}
wt_new() { # <town> <dirname> [dirty] [repo] — a detached worktree of <repo> (default traco-bim) at <repo>-wt/<dirname>
  local r="${4:-traco-bim}"
  GIT -C "$1/$r" worktree add -q --detach "$1/$r-wt/$2" >/dev/null 2>&1 || return 1
  if [ "${3:-}" = "dirty" ]; then printf 'changed\n' >> "$1/$r-wt/$2/f.txt"; printf 'new\n' > "$1/$r-wt/$2/new.txt"; fi
  return 0
}

H="$ROOT/wh"
mktown "$H" || die "cannot build the fixture town"
wt_new "$H" wa-lytych-e5 dirty                                  # THE incident: detached HEAD + modified + untracked
GIT -C "$H/traco-bim" branch pool/wa-brnch-e5 >/dev/null 2>&1   # a branch naming the bead, no worktree
wt_new "$H" wa-clean-e5                                         # created, nothing done
wt_new "$H" wa-other-e5 dirty                                   # another bead's work
wt_new "$H" WA-UPPER-e5 dirty                                   # upper case in the directory name
wt_new "$H" ga-fxX2-e5 dirty                                    # decoy for the dotted id ga-fx.2
wt_new "$H" ga-fx.3-e5 dirty                                    # the real dotted id
wt_new "$H" "wa-space x-e5" dirty                               # a space in the path
wt_new "$H" wa-gone-e5; rm -rf "$H/traco-bim-wt/wa-gone-e5"     # registered, directory gone
wt_new "$H" wa-ignrd-e5; mkdir -p "$H/traco-bim-wt/wa-ignrd-e5/junk"; printf 'x\n' > "$H/traco-bim-wt/wa-ignrd-e5/junk/x"   # dirty only with ignored files
wt_new "$H" wa-badst-e5; printf 'garbage\n' > "$H/traco-bim-wt/wa-badst-e5/.git"                                              # git status cannot read it
wt_new "$H" wa-ro-e5; printf 'x\n' > "$H/traco-bim-wt/wa-ro-e5/untracked.txt"                                                 # dirty (found) — used for the read-only check
GIT -C "$H/traco-bim" branch pool/WA-UPBR-e5 >/dev/null 2>&1    # upper case in a REF name
GIT -C "$H/traco-bim" branch pool/ga-fxX4-e5 >/dev/null 2>&1    # decoy REF for the dotted id ga-fx.4
wt_new "$H" wa-two-aa-e5; printf 'garbage\n' > "$H/traco-bim-wt/wa-two-aa-e5/.git"   # two trees for one bead: the first cannot be read…
wt_new "$H" wa-two-zz-e5 dirty                                                         # …the second holds the work
mkdir -p "$H/orphan-wt" "$H/-wt"; mkrepo "$H/afile"; : > "$H/afile-wt"                                                        # discovery decoys
_wl="$(GIT -C "$H/traco-bim" worktree list --porcelain 2>/dev/null)"   # captured first: a `| grep -q` under pipefail can SIGPIPE the writer (ga-8w22n)
case "$_wl" in *"$H/traco-bim-wt/wa-gone-e5"*) ;; *) die "fixture: the gone worktree is not registered (the test would be vacuous)" ;; esac

echo "pilot-dispatcher.ns-sibling-work.selftest — ga-9jrt3o7"

# ── (1) _ns_sibling_repos ───────────────────────────────────────────────────────────────────────────────────────────
echo "── (1) which repos count as siblings"
out="$(repos "$H" "$TOOLS_PATH")"
[ "$(kv "$out" RC)" = 0 ] && ok "a readable town root → rc 0" || bad "town root rc: $out"
[ "$(printf '%s\n' "$out" | grep -c '^REPO=')" = 1 ] && [ "$(kv "$out" REPO)" = "$H/traco-bim" ] \
  && ok "exactly traco-bim, from traco-bim-wt/ (decoys ignored: -wt with no repo, -wt that is a file, the name '-wt')" || bad "sibling list: $out"
N="$ROOT/wn"; mkdir -p "$N/city"
out="$(repos "$N" "$TOOLS_PATH")"
[ "$(kv "$out" RC)" = 0 ] && ! has "$out" "REPO=" && ok "a town root with no <name>-wt → rc 0 and EMPTY (nothing to look at, not 'cannot tell')" || bad "empty town: $out"
out="$(repos "$ROOT/nonexistent-town" "$TOOLS_PATH")"
[ "$(kv "$out" RC)" = 1 ] && ! has "$out" "REPO=" && ok "a town root that cannot be listed → rc 1 (cannot tell), no list" || bad "unlistable town: $out"

# ── (2) _beadid_has_sibling_work ────────────────────────────────────────────────────────────────────────────────────
echo "── (2) the work signal"
out="$(sib "$H" "$TOOLS_PATH" wa-lytych)"
[ "$(kv "$out" RC)" = 0 ] && has "$(kv "$out" WHY)" "traco-bim-wt/wa-lytych-e5" && has "$(kv "$out" WHY)" "uncommitted" \
  && ok "THE incident: detached worktree named for the bead with uncommitted files → rc 0, the reason names the worktree" || bad "incident: $out"
out="$(sib "$H" "$TOOLS_PATH" wa-brnch)"
[ "$(kv "$out" RC)" = 0 ] && has "$(kv "$out" WHY)" "pool/wa-brnch-e5" && ok "a branch naming the bead in the sibling repo (no worktree) → rc 0, the reason names the ref" || bad "branch only: $out"
out="$(sib "$H" "$TOOLS_PATH" wa-upbr)"
[ "$(kv "$out" RC)" = 0 ] && has "$(kv "$out" WHY)" "pool/WA-UPBR-e5" && ok "case-insensitive on REFS too: pool/WA-UPBR-e5 is wa-upbr's branch" || bad "ref case: $out"
out="$(sib "$H" "$TOOLS_PATH" ga-fx.4)"
[ "$(kv "$out" RC)" = 1 ] && ok "fixed-string on REFS too: the dot of ga-fx.4 is not a regex dot (the decoy ref pool/ga-fxX4-e5 is not its branch)" || bad "ref regex dot: $out"
out="$(sib "$H" "$TOOLS_PATH" wa-two)"
[ "$(kv "$out" RC)" = 0 ] && has "$(kv "$out" WHY)" "uncommitted changes in worktree" && has "$(kv "$out" WHY)" "wa-two-zz-e5" \
  && ok "two trees for one bead, the first unreadable: the second one's work is still FOUND, not reported as a doubt (one failed read does not blind the next)" || bad "two trees: $out"
out="$(sib "$H" "$TOOLS_PATH" wa-clean)"
[ "$(kv "$out" RC)" = 1 ] && ok "a clean worktree named for the bead (created, nothing done) → rc 1: there is no work to protect" || bad "clean worktree: $out"
out="$(sib "$H" "$TOOLS_PATH" wa-nada)"
[ "$(kv "$out" RC)" = 1 ] && ok "nothing for the bead anywhere → rc 1 (the control: the guard does not keep everything)" || bad "nothing: $out"
out="$(sib "$H" "$TOOLS_PATH" "")"
[ "$(kv "$out" RC)" = 1 ] && ok "an empty bead id → rc 1 (nothing to look for: never 'grep -F \"\"', which matches every ref)" || bad "empty id: $out"
out="$(sib "$H" "$TOOLS_PATH" wa-zzzzz)"
[ "$(kv "$out" RC)" = 1 ] && ok "another bead's dirty worktree does not count (wa-other-e5 is not wa-zzzzz)" || bad "cross-talk: $out"
out="$(sib "$H" "$TOOLS_PATH" wa-upper)"
[ "$(kv "$out" RC)" = 0 ] && ok "case-insensitive: WA-UPPER-e5 is wa-upper's worktree (same as the branch test's grep -i)" || bad "case: $out"
out="$(sib "$H" "$TOOLS_PATH" ga-fx.2)"
[ "$(kv "$out" RC)" = 1 ] && ok "fixed-string: the dot of ga-fx.2 is not a regex dot (the decoy ga-fxX2-e5 is not its tree)" || bad "regex dot: $out"
out="$(sib "$H" "$TOOLS_PATH" ga-fx.3)"
[ "$(kv "$out" RC)" = 0 ] && has "$(kv "$out" WHY)" "ga-fx.3-e5" && ok "the real dotted id ga-fx.3 is found (the id is not mangled)" || bad "dotted id: $out"
out="$(sib "$H" "$TOOLS_PATH" wa-space)"
[ "$(kv "$out" RC)" = 0 ] && has "$(kv "$out" WHY)" "wa-space x-e5" && ok "a space in the worktree path is handled (git -C quoted)" || bad "space: $out"
out="$(sib "$H" "$TOOLS_PATH" wa-gone)"
[ "$(kv "$out" RC)" = 1 ] && ok "a worktree registered in git whose directory is gone → rc 1 (no tree holds work; git worktree prune cleans the registry)" || bad "gone dir: $out"
out="$(sib "$H" "$TOOLS_PATH" wa-ignrd)"
[ "$(kv "$out" RC)" = 1 ] && ok "dirty only with files git ignores → rc 1 (git's own definition of dirty)" || bad "ignored only: $out"
out="$(sib "$H" "$TOOLS_PATH" wa-badst)"
[ "$(kv "$out" RC)" = 0 ] && has "$(kv "$out" WHY)" "cannot read" && has "$(kv "$out" WHY)" "wa-badst-e5" \
  && ok "git status cannot read the worktree (corrupt .git file) → rc 0 'cannot read', not 'clean'" || bad "status fails: $out"

echo "── (2b) a read that fails or times out is 'cannot tell', one site at a time"
# for-each-ref and worktree list are tried with a bead that has NOTHING on disk (a found item would win over the doubt and hide it);
# status needs a bead that has a worktree to read: wa-lytych
for pair in "for-each-ref:wa-nada" "worktree list:wa-nada" "status:wa-lytych"; do
  v="${pair%%:*}"; b="${pair##*:}"
  out="$(sib "$H" "$SHIM_PATH" "$b" NSW_FAIL_TIMEOUT="$v")"
  [ "$(kv "$out" RC)" = 0 ] && has "$(kv "$out" WHY)" "cannot read" && has "$(kv "$out" WHY)" "rc=124" && ok "'git $v' timing out (rc 124) → rc 0 'cannot read: … rc=124', never 'found nothing'" || bad "timeout of $v: $out"
  out="$(sib "$H" "$SHIM_PATH" "$b" NSW_FAIL_GIT="$v")"
  [ "$(kv "$out" RC)" = 0 ] && has "$(kv "$out" WHY)" "cannot read" && has "$(kv "$out" WHY)" "rc=3" && ok "'git $v' exiting non-zero → rc 0 'cannot read: … rc=3' (the log shows which read failed and how)" || bad "failure of $v: $out"
done
out="$(sib "$H" "$SHIM_PATH" wa-lytych NSW_FAIL_GIT=for-each-ref)"
[ "$(kv "$out" RC)" = 0 ] && has "$(kv "$out" WHY)" "uncommitted" && ok "the refs read failing does not blind the worktree read: the dirty tree is still FOUND" || bad "for-each-ref down, worktree scan lost: $out"
out="$(sib "$H" "$SHIM_PATH" wa-nada NSW_FAIL_GIT=status)"
[ "$(kv "$out" RC)" = 1 ] && ok "a failing 'git status' is not consulted for a bead with no worktree of its own (rc 1: 'cannot tell' is per read, not global)" || bad "status failing for wa-nada: $out"
out="$(sib "$H" "$SHIM_PATH" wa-lytych NSW_FAIL_GIT=status)"
has "$(kv "$out" WHY)" "wa-lytych-e5" && ok "…and the reason names the worktree whose status could not be read" || bad "doubt reason without the worktree: $out"

echo "── (2c) a broken sibling repo, a found item wins over a doubt, no git, switches"
B="$ROOT/wb"; mktown "$B" || die "cannot build the broken-repo town"
wt_new "$B" wa-lytych-e5 dirty
GIT -C "$B/traco-bim" branch pool/wa-brnb-e5 >/dev/null 2>&1
mkdir -p "$B/broken" "$B/broken-wt"; printf 'gitdir: /nonexistent/nsw\n' > "$B/broken/.git"
out="$(sib "$B" "$TOOLS_PATH" wa-nada)"
[ "$(kv "$out" RC)" = 0 ] && has "$(kv "$out" WHY)" "cannot read" && has "$(kv "$out" WHY)" "$B/broken" \
  && ok "a sibling repo git cannot read → rc 0 'cannot read: … broken' even for a bead it has nothing to do with (inert, visible)" || bad "broken repo: $out"
out="$(sib "$B" "$TOOLS_PATH" wa-lytych)"
[ "$(kv "$out" RC)" = 0 ] && has "$(kv "$out" WHY)" "uncommitted" && ok "a found dirty worktree wins over the doubt from the broken repo (the reason says what was FOUND)" || bad "found vs doubt: $out"
out="$(sib "$B" "$TOOLS_PATH" wa-brnb)"
[ "$(kv "$out" RC)" = 0 ] && has "$(kv "$out" WHY)" "pool/wa-brnb-e5" && ok "a healthy repo read AFTER a broken one still finds its branch (a failed read's status does not leak into the next repo)" || bad "branch after broken repo: $out"
out="$(sib "$H" "$EMPTY_PATH" wa-nada)"
[ "$(kv "$out" RC)" = 0 ] && has "$(kv "$out" WHY)" "git is not on PATH" && ok "no git on PATH → rc 0 'git is not on PATH' (cannot tell), like _beadid_has_branch" || bad "no git: $out"
CW="$ROOT/cwdrepo"; mkrepo "$CW" && GIT -C "$CW" branch wa-cwdbr-e5 >/dev/null 2>&1 || die "cannot build the cwd repo"
out="$(cd "$CW" && sib "$N" "$TOOLS_PATH" wa-cwdbr)"
[ "$(kv "$out" RC)" = 1 ] && ok "no sibling repo at all, caller's cwd inside a repo that HAS a ref for the bead → rc 1 (an empty repo list never turns into 'git -C \"\"' on the cwd)" || bad "empty repo list read the cwd: $out"
out="$(sib "$ROOT/nonexistent-town" "$TOOLS_PATH" wa-lytych)"
[ "$(kv "$out" RC)" = 0 ] && has "$(kv "$out" WHY)" "cannot read" && ok "an unlistable town root → rc 0 'cannot read' (the doubt lands in KEEP, not in 'no siblings')" || bad "unlistable town: $out"
out="$(sib "$H" "$TOOLS_PATH" wa-lytych PILOT_NS_SIBLING_WORK=0)"
[ "$(kv "$out" RC)" = 1 ] && ok "kill switch PILOT_NS_SIBLING_WORK=0 → rc 1 (the pre-fix behaviour, by construction)" || bad "kill switch: $out"
out="$(sib "$H" "$TOOLS_PATH" wa-lytych PILOT_TEST_BRANCH_BEADS=)"
[ "$(kv "$out" RC)" = 1 ] && ok "a test that fakes the branch world (PILOT_TEST_BRANCH_BEADS defined, even empty) gets no sibling repos: the big selftest stays hermetic" || bad "branch seam: $out"

echo "── (2d) the status read must not touch the worktree"
RO="$H/traco-bim-wt/wa-ro-e5"; : > "$ROOT/gitlog"
IDX="$(git -C "$RO" rev-parse --git-path index 2>/dev/null)"; case "$IDX" in /*) ;; *) IDX="$RO/$IDX" ;; esac
sleep 1; touch "$RO/f.txt"      # same content, newer mtime: a plain `git status` would refresh and REWRITE the index
before="$(cksum < "$IDX")"
out="$(sib "$H" "$SHIM_PATH" wa-ro NSW_GITLOG="$ROOT/gitlog")"
after="$(cksum < "$IDX")"
[ "$(kv "$out" RC)" = 0 ] && ok "the worktree is found (dirty)" || bad "ro worktree: $out"
[ "$before" = "$after" ] && ok "the index file is byte-identical after the read (--no-optional-locks: a live builder's worktree is never rewritten)" || bad "the read REWROTE the worktree index ($before → $after)"
sline="$(grep -F "status" "$ROOT/gitlog" | head -1)"
has "$sline" "--no-optional-locks" && ok "the status call carries --no-optional-locks" || bad "status call without --no-optional-locks: $sline"
has "$sline" "core.fsmonitor=false" && ok "the status call carries -c core.fsmonitor=false (the flag is what is proven: git's fsmonitor daemon cannot be observed on this platform)" || bad "status call without core.fsmonitor=false: $sline"
has "$sline" "-C $RO" && ok "the status call is scoped with -C <the worktree>" || bad "status call not scoped to the worktree: $sline"

echo "── (2e) the git calls run inside here-string loops (the repo list, the candidate list): none may read stdin"
# A git that read stdin would swallow the REST of the list it is looped over. Two sibling repos, the work only in the second one
# (aaa is read first), and two candidate trees in aaa, the dirty one second; the git shim reads stdin when NSW_GIT_SLURP_STDIN=1.
SS="$ROOT/ws"; mktown "$SS" || die "cannot build the stdin-test town"
mkrepo "$SS/aaa"; mkdir -p "$SS/aaa-wt"
wt_new "$SS" wa-slurpa-a1 "" aaa; wt_new "$SS" wa-slurpa-a2 dirty aaa      # first repo: first tree clean, second dirty
wt_new "$SS" wa-slurpb-e5 dirty                                            # second repo (traco-bim): the only work for wa-slurpb
for slurp in "" 1; do
  sl="not reading"; [ -z "$slurp" ] || sl="reading"
  out="$(sib "$SS" "$SHIM_PATH" wa-slurpb NSW_GIT_SLURP_STDIN="$slurp")"
  [ "$(kv "$out" RC)" = 0 ] && has "$(kv "$out" WHY)" "wa-slurpb-e5" && ok "work in the SECOND sibling repo is found (git $sl stdin): the refs and worktree-list reads of the first repo leave the repo list alone" || bad "second repo lost (git $sl stdin): $out"
  out="$(sib "$SS" "$SHIM_PATH" wa-slurpa NSW_GIT_SLURP_STDIN="$slurp")"
  [ "$(kv "$out" RC)" = 0 ] && has "$(kv "$out" WHY)" "wa-slurpa-a2" && ok "the SECOND candidate tree of a repo is read (git $sl stdin): the status read of the first leaves the candidate list alone" || bad "second candidate lost (git $sl stdin): $out"
done

# ── (3) the real _neverstarted_recover_db ───────────────────────────────────────────────────────────────────────────
echo "── (3) NEVERSTARTED end to end"
out="$(nsrun "$H" wa-lytych 7200 0)"
[ "$(kv "$out" RELEASED)" = 0 ] && ok "THE bug: the incident bead (aged 2 h, no branch in the rig repos, dirty traco-bim worktree) is KEPT" || bad "incident bead released: $out"
has "$out" "wa-lytych-e5" && has "$out" "ga-9jrt3o7" && ok "the log line names the worktree and the bead (ga-9jrt3o7)" || bad "keep log line: $out"
! has "$out" "releasing never-started in-flight bead" && ok "…and never says 'releasing never-started in-flight bead' (the big selftest greps that phrase for a RELEASE)" || bad "the keep line contains the release phrase: $out"
out="$(nsrun "$H" wa-nada 7200 0)"
[ "$(kv "$out" RELEASED)" = 1 ] && has "$out" "releasing never-started in-flight bead wa-nada" && ok "control: the same flow DOES release a bead with nothing on disk (the harness reaches the release)" || bad "control bead not released: $out"
out="$(nsrun "$H" wa-lytych 7200 0 BEAD2=wa-nada)"
[ "$(kv "$out" RELEASED)" = 0 ] && [ "$(kv "$out" RELEASED2)" = 1 ] && ok "two in-flight beads: keeping the first does not stop the loop (the second, with nothing on disk, is still released)" || bad "two beads: $out"
out="$(nsrun "$H" wa-clean 7200 0)"
[ "$(kv "$out" RELEASED)" = 1 ] && ok "a clean worktree is not work: released" || bad "clean-worktree bead kept: $out"
out="$(nsrun "$H" wa-lytych 7200 0 PILOT_NS_SIBLING_WORK=0)"
[ "$(kv "$out" RELEASED)" = 1 ] && ok "kill switch off → the incident bead is released again (the pre-fix behaviour)" || bad "kill switch did not restore the old behaviour: $out"
out="$(child "$H" "$SHIM_PATH" "$DRV_NS" BEAD=wa-nada AGE=7200 OWNER=0 NSW_CALLS="$ROOT/calls" NSW_FAIL_TIMEOUT=for-each-ref --)"
[ "$(kv "$out" RELEASED)" = 0 ] && has "$out" "cannot read" && ok "a read that times out → the bead is KEPT and the log says why (doubt = inert, never released)" || bad "doubt released the bead: $out"
out="$(nsrun "$H" wa-brnch 7200 0)"
[ "$(kv "$out" RELEASED)" = 0 ] && ok "a branch in the sibling repo (not a gc rig, so invisible to _beadid_has_branch) keeps the bead too" || bad "branch-only bead released: $out"
GIT -C "$H" branch wa-hqbr-x >/dev/null 2>&1      # a branch in the TOWN repo, which _NS_BRANCH_REPOS does search
out="$(nsrun "$H" wa-hqbr 7200 0)"
[ "$(kv "$out" RELEASED)" = 0 ] && ! has "$out" "ga-9jrt3o7" && ok "the old branch guard still wins first: a branch in the town repo keeps the bead without consulting the sibling guard" || bad "old branch guard broken: $out"
out="$(nsrun "$H" wa-lytych 100000 1)"
[ "$(kv "$out" RELEASED)" = 0 ] && ! has "$out" "releasing as declined/skipped" && ok "crew-owned bead past the owner grace WITH a dirty sibling worktree: kept, and the log does not promise a release" || bad "owner-grace + sibling work: $out"
out="$(nsrun "$H" wa-nada 100000 1)"
[ "$(kv "$out" RELEASED)" = 1 ] && has "$out" "releasing as declined/skipped" && ok "control: crew-owned past the grace with nothing on disk is still released as declined/skipped" || bad "owner-grace control: $out"

# ── negative control ────────────────────────────────────────────────────────────────────────────────────────────────
# Each record of the table below switches ONE guard off in a COPY of the dispatcher (the anchor must occur exactly once and the copy must
# still parse, else the kill would be vacuous); the copy is then run through this very file and has to FAIL (exit 1). The identity row
# replaces a line by itself and has to SURVIVE (exit 0): it proves a "killed" is not the harness dying (a loader FATAL exits 2).
if [ -z "${NSW_MUTANT:-}" ] && [ -z "${NSW_NO_MUTANTS:-}" ]; then
  echo "── negative control: every guard switched off in a copy of the dispatcher must fail this file"
  MUTDIR="$ROOT/mut"; mkdir -p "$MUTDIR" || die "cannot create $MUTDIR"
  cat > "$ROOT/mutate.py" <<'PYEOF'
import os, sys
src_path, table_path, outdir = sys.argv[1:4]
src = open(src_path, encoding="utf-8").read()
recs, cur, mode = [], None, None
for line in open(table_path, encoding="utf-8").read().split("\n"):
    if line.startswith("@@ "):
        cur = {"name": line[3:], "old": [], "new": []}; recs.append(cur); mode = None
    elif line == "<<<":
        mode = "old"
    elif line == ">>>":
        mode = "new"
    elif cur is not None and mode:
        cur[mode].append(line)
for i, r in enumerate(recs, 1):
    for k in ("old", "new"):
        while r[k] and r[k][-1] == "":
            r[k].pop()
    old, new = "\n".join(r["old"]), "\n".join(r["new"])
    n = src.count(old) if old else 0
    if n != 1:
        print("%d\t%s\tANCHOR-COUNT=%d" % (i, r["name"], n)); continue
    open(os.path.join(outdir, "m%d.sh" % i), "w", encoding="utf-8").write(src.replace(old, new))
    print("%d\t%s\tOK" % (i, r["name"]))
PYEOF
  cat > "$ROOT/mutants.txt" <<'TBLEOF'
@@ identity: the kill-switch line replaced by itself (must SURVIVE)
<<<
  [ "${PILOT_NS_SIBLING_WORK:-1}" = "0" ] && return 1
>>>
  [ "${PILOT_NS_SIBLING_WORK:-1}" = "0" ] && return 1
@@ kill switch ignored
<<<
  [ "${PILOT_NS_SIBLING_WORK:-1}" = "0" ] && return 1
>>>
  :
@@ an empty bead id is looked up (grep -F "" matches every ref)
<<<
  [ -n "$_bid" ] || return 1
  [ "${PILOT_NS_SIBLING_WORK:-1}" = "0" ] && return 1
>>>
  [ "${PILOT_NS_SIBLING_WORK:-1}" = "0" ] && return 1
@@ the town root is GC_CITY itself, not its parent
<<<
  _town=$(dirname "$GC_CITY")
>>>
  _town="$GC_CITY"
@@ a town with no sibling repo answers "cannot tell" (rc 1) instead of "nothing to look at"
<<<
      printf '%s\n' "$_repo"
    fi
  done
  return 0
>>>
      printf '%s\n' "$_repo"
    fi
  done
  return 1
@@ branch seam (PILOT_TEST_BRANCH_BEADS) ignored
<<<
  [ -n "${PILOT_TEST_BRANCH_BEADS+x}" ] && return 1
>>>
  :
@@ no-git guard dropped
<<<
  command -v git >/dev/null 2>&1 || { _BSW_WHY="cannot read: git is not on PATH"; return 0; }
>>>
  :
@@ unlistable town root reads as "no sibling work"
<<<
    _BSW_WHY="cannot read: the town root $(dirname "$GC_CITY") cannot be listed"
    return 0
>>>
    _BSW_WHY="cannot read: the town root $(dirname "$GC_CITY") cannot be listed"
    return 1
@@ _ns_sibling_repos does not check the town root
<<<
  [ -d "$_town" ] && [ -r "$_town" ] && [ -x "$_town" ] || return 1
>>>
  :
@@ a -wt that is a FILE is listed
<<<
    [ -d "$_d" ] || continue
    _name="${_d##*/}"
>>>
    _name="${_d##*/}"
@@ the -wt suffix is not stripped from the repo name
<<<
    _name="${_name%-wt}"
>>>
    :
@@ the degenerate name '-wt' is not skipped
<<<
    [ -n "$_name" ] || continue
>>>
    :
@@ a repo beside the -wt dir is not required
<<<
    if [ -d "$_repo/.git" ] || [ -f "$_repo/.git" ]; then
>>>
    if true; then
@@ a repo whose .git is a FILE is not accepted
<<<
    if [ -d "$_repo/.git" ] || [ -f "$_repo/.git" ]; then
>>>
    if [ -d "$_repo/.git" ]; then
@@ an empty repo list falls through to git -C "" (the caller's cwd)
<<<
  fi
  while IFS= read -r _repo; do
    [ -n "$_repo" ] || continue
>>>
  fi
  while IFS= read -r _repo; do
    :
@@ the refs read failing reads as "no refs"
<<<
    if [ "$_rc" -ne 0 ]; then
      _doubt="${_doubt:+$_doubt; }git for-each-ref rc=$_rc in $_repo"
>>>
    if false; then
      _doubt="${_doubt:+$_doubt; }git for-each-ref rc=$_rc in $_repo"
@@ the branch scan is dropped
<<<
    elif _hit=$(grep -iF -m 1 -- "$_bid" <<< "$_refs"); then
>>>
    elif false; then
@@ the ref match is case-sensitive
<<<
    elif _hit=$(grep -iF -m 1 -- "$_bid" <<< "$_refs"); then
>>>
    elif _hit=$(grep -F -m 1 -- "$_bid" <<< "$_refs"); then
@@ the ref match is a regex, not a fixed string
<<<
    elif _hit=$(grep -iF -m 1 -- "$_bid" <<< "$_refs"); then
>>>
    elif _hit=$(grep -i -m 1 -- "$_bid" <<< "$_refs"); then
@@ the worktree list failing reads as "no worktrees"
<<<
    if [ "$_rc" -ne 0 ]; then
      _doubt="${_doubt:+$_doubt; }git worktree list rc=$_rc in $_repo"
>>>
    if false; then
      _doubt="${_doubt:+$_doubt; }git worktree list rc=$_rc in $_repo"
@@ the worktree match is case-sensitive
<<<
    _cand=$(grep '^worktree ' <<< "$_wl" | grep -iF -- "$_bid") || _cand=""
>>>
    _cand=$(grep '^worktree ' <<< "$_wl" | grep -F -- "$_bid") || _cand=""
@@ the worktree match is a regex, not a fixed string
<<<
    _cand=$(grep '^worktree ' <<< "$_wl" | grep -iF -- "$_bid") || _cand=""
>>>
    _cand=$(grep '^worktree ' <<< "$_wl" | grep -i -- "$_bid") || _cand=""
@@ the "worktree " prefix is not stripped from the registry line
<<<
      _wt="${_wt#worktree }"
>>>
      :
@@ a registered worktree whose directory is gone is not skipped
<<<
      [ -d "$_wt" ] || continue
>>>
      :
@@ the status failing reads as "clean"
<<<
      if [ "$_rc" -ne 0 ]; then
        _doubt="${_doubt:+$_doubt; }git status rc=$_rc in $_wt"
>>>
      if false; then
        _doubt="${_doubt:+$_doubt; }git status rc=$_rc in $_wt"
@@ the dirty check is dropped
<<<
      if [ -n "$_st" ]; then
>>>
      if false; then
@@ status without --no-optional-locks (rewrites a live builder's index)
<<<
git -C "$_wt" --no-optional-locks -c core.fsmonitor=false status --porcelain
>>>
git -C "$_wt" -c core.fsmonitor=false status --porcelain
@@ status without core.fsmonitor=false
<<<
git -C "$_wt" --no-optional-locks -c core.fsmonitor=false status --porcelain
>>>
git -C "$_wt" --no-optional-locks status --porcelain
@@ the refs read is not bounded by timeout
<<<
_refs=$(timeout 8 git -C "$_repo" for-each-ref
>>>
_refs=$(git -C "$_repo" for-each-ref
@@ the worktree list is not bounded by timeout
<<<
_wl=$(timeout 8 git -C "$_repo" worktree list
>>>
_wl=$(git -C "$_repo" worktree list
@@ the status read is not bounded by timeout
<<<
_st=$(timeout 8 git -C "$_wt" --no-optional-locks
>>>
_st=$(git -C "$_wt" --no-optional-locks
@@ the refs read can read the caller's stdin
<<<
refs/heads refs/remotes 2>/dev/null </dev/null) || _rc=$?
>>>
refs/heads refs/remotes 2>/dev/null) || _rc=$?
@@ the worktree-list read can read the caller's stdin
<<<
worktree list --porcelain 2>/dev/null </dev/null) || _rc=$?
>>>
worktree list --porcelain 2>/dev/null) || _rc=$?
@@ the status read can read the caller's stdin
<<<
status --porcelain 2>/dev/null </dev/null) || _rc=$?
>>>
status --porcelain 2>/dev/null) || _rc=$?
@@ the sibling guard stops the whole loop instead of moving to the next bead
<<<
(ga-9jrt3o7)."
      continue
>>>
(ga-9jrt3o7)."
      break
@@ a failed read's rc leaks into the refs read of the next repo
<<<
    _rc=0
    _refs=$(timeout 8
>>>
    _rc=${_rc:-0}
    _refs=$(timeout 8
@@ a failed refs read's rc leaks into the worktree-list read of the same repo
<<<
    _rc=0
    _wl=$(timeout 8
>>>
    _rc=${_rc:-0}
    _wl=$(timeout 8
@@ a failed status read's rc leaks into the next worktree's status read
<<<
      _rc=0
      _st=$(timeout 8
>>>
      _rc=${_rc:-0}
      _st=$(timeout 8
@@ a doubt at the end reads as "nothing found"
<<<
    _BSW_WHY="cannot read: $_doubt"
    return 0
>>>
    _BSW_WHY="cannot read: $_doubt"
    return 1
@@ a dirty worktree reads as "nothing found"
<<<
        _BSW_WHY="uncommitted changes in worktree $_wt"
        return 0
>>>
        _BSW_WHY="uncommitted changes in worktree $_wt"
        return 1
@@ a branch hit reads as "nothing found"
<<<
      _BSW_WHY="branch '$_hit' in $_repo"
      return 0
>>>
      _BSW_WHY="branch '$_hit' in $_repo"
      return 1
@@ NEVERSTARTED does not consult the sibling guard
<<<
    if _beadid_has_sibling_work "$_bid"; then
      warn "NEVERSTARTED: $_bid kept in flight
>>>
    if false; then
      warn "NEVERSTARTED: $_bid kept in flight
@@ the sibling guard warns but does not keep the bead
<<<
(ga-9jrt3o7)."
      continue
>>>
(ga-9jrt3o7)."
      :
@@ the keep log line carries the release phrase the selftests grep
<<<
kept in flight — a repo beside the town root: ${_BSW_WHY:-no reason recorded}
>>>
releasing never-started in-flight bead $_bid: ${_BSW_WHY:-no reason recorded}
@@ the owner-grace condition ignores sibling work (its log would promise a release)
<<<
         && ! _beadid_has_sibling_work "$_bid" \
         && _crew_progressed_since "$_crew_owner" "$_stamp"; then
>>>
         && _crew_progressed_since "$_crew_owner" "$_stamp"; then
TBLEOF
  python3 -I "$ROOT/mutate.py" "$DISPATCHER" "$ROOT/mutants.txt" "$MUTDIR" > "$ROOT/mutlist" 2>"$ROOT/mutate.err" || die "the mutant generator failed: $(cat "$ROOT/mutate.err")"
  # the runs go 4 at a time; each writes <rc>\t<first failing line> to its own file, read back in table order
  while IFS="$(printf '\t')" read -r idx name status; do
    [ "$status" = OK ] || continue
    while [ "$(jobs -r | wc -l | tr -d ' ')" -ge 4 ]; do sleep 0.2; done
    bash -n "$MUTDIR/m$idx.sh" 2>/dev/null || { printf '99\tdoes not parse\n' > "$MUTDIR/r$idx"; continue; }
    ( r="$(NSW_MUTANT=1 NSW_DISPATCHER="$MUTDIR/m$idx.sh" "$BASH" "$0" 2>&1)"; rc=$?
      printf '%s\t%s\n' "$rc" "$(printf '%s\n' "$r" | grep -m1 '✗' | sed 's/^ *✗ *//' | cut -c1-120)" > "$MUTDIR/r$idx.tmp" && mv "$MUTDIR/r$idx.tmp" "$MUTDIR/r$idx" ) &
  done < "$ROOT/mutlist"
  wait
  while IFS="$(printf '\t')" read -r idx name status; do
    if [ "$status" != OK ]; then bad "mutant '$name': the anchor does not match exactly once ($status)"; continue; fi
    res="$(cat "$MUTDIR/r$idx" 2>/dev/null)"; rc="${res%%$(printf '\t')*}"; why="${res#*$(printf '\t')}"
    case "$name" in
      identity*) [ "$rc" = 0 ] && ok "identity row SURVIVES (a kill is not the harness dying)" || bad "identity row did not survive (rc=$rc): the harness is not re-runnable on a copy — $why" ;;
      *) case "$rc" in
           1)  ok "mutant '$name' KILLED — $why" ;;
           0)  bad "mutant '$name' SURVIVED" ;;
           *)  bad "mutant '$name': the run ended rc=${rc:-?} ($why): a vacuous kill" ;;
         esac ;;
    esac
  done < "$ROOT/mutlist"
fi

echo "── $PASS ok, $FAIL falhas"
[ "$FAIL" = 0 ]
