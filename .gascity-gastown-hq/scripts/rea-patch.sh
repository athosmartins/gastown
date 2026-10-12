#!/bin/bash
# rea-patch.sh — keeps the installed REA (npm package `rea-agents`) on ONE pinned version and
# re-applies the local patches we keep in git (ga-pfc2ww, programa REA ga-oe7o1p).
#
#   rea-patch.sh check    read-only. Exit 0 only if the version is the pinned one AND every
#                         patched file is in its patched state.  (also: `status`, or no argument)
#   rea-patch.sh apply    idempotent. Applies what the manifest lists, verified by sha256 before
#                         the file is replaced and again after. Refuses on a version mismatch.
#
# Why this exists: REA runs with the user's permissions, and `rea update` / `rea --update` replaces the
# package (npm install --global) — it moves the version with no review AND drops our patch (60 s -> 300 s
# for the Swift helper compile; without it REA fails under this host's load). So the version is pinned
# here, the patch is data in git, and a version change is a bead that reviews the changelog first
# (docs/runbooks/rea-versao-fixa-e-patch.md).
#
# Layout (override the root with REA_PATCH_ROOT — selftest only):
#   rea-patches/PIN                   the pinned version, one line (e.g. 6.4.0)
#   rea-patches/<PIN>/MANIFEST.tsv    relpath <TAB> pristine sha256 <TAB> patched sha256 <TAB> patch file
#   rea-patches/<PIN>/*.patch         unified diffs, -p1, relative to the package root
# Package dir: $REA_PKG_DIR, else derived from the LIVE `rea` binary (readlink -f), never from a path
# written down in a doc — the MBP keeps its own copy under ~/gt-remote/rea and can be targeted with it.
#
# State per file comes from the file's sha256, not from "did patch exit 0": pristine / patched / neither.
# "Neither" (someone edited it another way, or upstream changed it) is never touched.
#
# Why `patch` and not `git apply`: /opt/homebrew is itself a git repo, and `git apply` run inside a
# subdirectory of a repo silently skips patch paths outside that subdirectory's prefix — a no-op that
# exits 0. `patch -p1 -F0` (no fuzz) has no such mode, and the hash check proves the effect anyway.
#
# Exit codes — three states, so "can't tell" never reads as "fine":
#   0  ok      version == pin and every listed file is patched (apply: nothing left to do, or done)
#   1  drift   installed version != pin, or a file is still pristine (check); apply refuses a version mismatch
#   2  unknown package/manifest unreadable, or a file is neither pristine nor patched. Nothing is modified.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_ROOT="${REA_PATCH_ROOT:-$HERE/rea-patches}"

say() { printf 'rea-patch: %s\n' "$*"; }
err() { printf 'rea-patch: %s\n' "$*" >&2; }

usage() { err "usage: rea-patch.sh [check|status|apply]"; }

sha256_of() { shasum -a 256 -- "$1" 2>/dev/null | awk '{print $1}'; }

# Package dir of the live install: .../rea-agents/scripts/rea.mjs -> .../rea-agents
resolve_pkg() {
  local bin real
  if [ -n "${REA_PKG_DIR:-}" ]; then printf '%s\n' "$REA_PKG_DIR"; return 0; fi
  bin="$(command -v rea 2>/dev/null)" || return 1
  real="$(readlink -f "$bin" 2>/dev/null)" || return 1
  [ -n "$real" ] || return 1
  dirname "$(dirname "$real")"
}

# Version of the package at $1, only if it really is rea-agents.
pkg_version() {
  local pj="$1/package.json" name ver
  [ -r "$pj" ] || return 1
  name="$(jq -r '.name // empty' "$pj" 2>/dev/null)" || return 1
  ver="$(jq -r '.version // empty' "$pj" 2>/dev/null)" || return 1
  [ "$name" = "rea-agents" ] && [ -n "$ver" ] || return 1
  printf '%s\n' "$ver"
}

# applied | pristine | modified | unreadable   (args: pkg relpath pristine_sha patched_sha)
file_state() {
  local f="$1/$2" h
  [ -r "$f" ] || { echo unreadable; return; }
  h="$(sha256_of "$f")"
  if [ -z "$h" ]; then echo unreadable
  elif [ "$h" = "$4" ]; then echo applied
  elif [ "$h" = "$3" ]; then echo pristine
  else echo modified
  fi
}

# Sets PIN PKG VERSION and the parallel arrays ROW_REL ROW_PRI ROW_PAT ROW_PATCH.
# Returns 2 (after saying why) when anything needed to decide cannot be read or is malformed.
load_context() {
  local rel pri pat pfile hex='^[0-9a-f]{64}$'
  ROW_REL=(); ROW_PRI=(); ROW_PAT=(); ROW_PATCH=()

  PIN="$(tr -d '[:space:]' 2>/dev/null < "$PATCH_ROOT/PIN")"
  [[ "$PIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { err "UNKNOWN: $PATCH_ROOT/PIN missing or not a x.y.z version"; return 2; }

  PKG="$(resolve_pkg)" || { err "UNKNOWN: no rea-agents install found (no \`rea\` on PATH and REA_PKG_DIR unset)"; return 2; }
  VERSION="$(pkg_version "$PKG")" || { err "UNKNOWN: $PKG is not a readable rea-agents package (package.json)"; return 2; }

  local manifest="$PATCH_ROOT/$PIN/MANIFEST.tsv"
  [ -r "$manifest" ] || { err "UNKNOWN: no patch manifest for pinned version $PIN ($manifest)"; return 2; }
  while IFS=$'\t' read -r rel pri pat pfile || [ -n "$rel" ]; do
    case "$rel" in ''|'#'*) continue ;; esac
    if [[ "$rel" = /* || "$rel" = *..* ]]; then err "UNKNOWN: manifest path not relative to the package: $rel"; return 2; fi
    if ! [[ "$pri" =~ $hex && "$pat" =~ $hex ]] || [ "$pri" = "$pat" ]; then
      err "UNKNOWN: manifest row for $rel has a bad or equal pristine/patched sha256"; return 2
    fi
    # An empty name would make this "$PATCH_ROOT/$PIN/" — a readable DIRECTORY — and pass; so name a plain file, no path parts.
    if [ -z "$pfile" ] || [[ "$pfile" = */* ]] || [ ! -f "$PATCH_ROOT/$PIN/$pfile" ] || [ ! -r "$PATCH_ROOT/$PIN/$pfile" ]; then
      err "UNKNOWN: manifest row for $rel names no readable patch file in $PATCH_ROOT/$PIN (got: '${pfile}')"; return 2
    fi
    ROW_REL+=("$rel"); ROW_PRI+=("$pri"); ROW_PAT+=("$pat"); ROW_PATCH+=("$pfile")
  done < "$manifest"
  return 0
}

cmd_check() {
  local i st rc=0 n ok=0
  load_context || return 2
  n=${#ROW_REL[@]}   # only after load_context filled the arrays
  if [ "$VERSION" != "$PIN" ]; then
    say "DRIFT: installed rea-agents $VERSION but pinned $PIN ($PKG). Version changes go through a bead — docs/runbooks/rea-versao-fixa-e-patch.md"
    return 1
  fi
  for ((i = 0; i < n; i++)); do
    st="$(file_state "$PKG" "${ROW_REL[i]}" "${ROW_PRI[i]}" "${ROW_PAT[i]}")"
    case "$st" in
      applied)  ok=$((ok + 1)); say "applied   ${ROW_REL[i]}" ;;
      pristine) [ "$rc" -lt 1 ] && rc=1; say "DRIFT: not patched ${ROW_REL[i]} (run: rea-patch.sh apply)" ;;
      *)        rc=2; say "UNKNOWN: ${ROW_REL[i]} is $st — neither the pristine $PIN file nor our patched one" ;;
    esac
  done
  [ "$rc" -eq 0 ] && say "OK rea-agents $VERSION (pinned), $ok/$n patched file(s) in place — $PKG"
  return "$rc"
}

# Patch one file through a temp copy, prove the result by hash, then swap it in with a rename.
apply_one() {
  local rel="$1" patched="$2" pfile="$3" tmp got after staged
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/rea-patch.XXXXXX")" || { err "UNKNOWN: cannot create a temp dir"; return 2; }
  mkdir -p "$tmp/$(dirname "$rel")" && cp -p -- "$PKG/$rel" "$tmp/$rel" || { rm -rf "$tmp"; err "UNKNOWN: cannot stage $rel"; return 2; }
  if ! patch -p1 -F0 -s -d "$tmp" -i "$PATCH_ROOT/$PIN/$pfile" > "$tmp/patch.out" 2>&1; then
    err "REFUSED: $pfile does not apply cleanly to $rel (no fuzz). patch said: $(head -c 400 "$tmp/patch.out")"
    rm -rf "$tmp"; return 2
  fi
  got="$(sha256_of "$tmp/$rel")"
  if [ "$got" != "$patched" ]; then
    err "REFUSED: $rel after patching has sha256 ${got:-<none>}, manifest says $patched — package left untouched"
    rm -rf "$tmp"; return 2
  fi
  staged="$PKG/$rel.rea-patch.$$"
  if ! cp -p -- "$tmp/$rel" "$staged" || ! mv -f -- "$staged" "$PKG/$rel"; then
    rm -f -- "$staged"; rm -rf "$tmp"; err "UNKNOWN: could not install the patched $rel (package dir not writable?)"; return 2
  fi
  rm -rf "$tmp"
  after="$(sha256_of "$PKG/$rel")"
  [ "$after" = "$patched" ] || { err "UNKNOWN: $rel has sha256 ${after:-<none>} after install, expected $patched"; return 2; }
  say "APPLIED   $rel"
}

cmd_apply() {
  local i st n todo=0
  local -a states=()
  load_context || return 2
  n=${#ROW_REL[@]}   # only after load_context filled the arrays
  if [ "$VERSION" != "$PIN" ]; then
    err "REFUSED: installed rea-agents is $VERSION, pinned $PIN. Not patching a version nobody reviewed — docs/runbooks/rea-versao-fixa-e-patch.md"
    return 1
  fi
  # Classify everything first: all-or-nothing, so a set is never left half patched because the 2nd file was odd.
  for ((i = 0; i < n; i++)); do
    st="$(file_state "$PKG" "${ROW_REL[i]}" "${ROW_PRI[i]}" "${ROW_PAT[i]}")"
    states+=("$st")
    case "$st" in
      pristine) todo=$((todo + 1)) ;;
      applied) ;;
      *) err "REFUSED: ${ROW_REL[i]} is $st — neither the pristine $PIN file nor our patched one. Nothing was changed."; return 2 ;;
    esac
  done
  for ((i = 0; i < n; i++)); do
    if [ "${states[i]}" = applied ]; then say "already   ${ROW_REL[i]}"; continue; fi
    apply_one "${ROW_REL[i]}" "${ROW_PAT[i]}" "${ROW_PATCH[i]}" || return 2
  done
  say "OK rea-agents $VERSION (pinned), $n/$n patched file(s) in place ($todo applied now) — $PKG"
}

case "${1:-check}" in
  check|status) cmd_check ;;
  apply)        cmd_apply ;;
  -h|--help)    usage; exit 0 ;;
  *)            usage; exit 2 ;;
esac
