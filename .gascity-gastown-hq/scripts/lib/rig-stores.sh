#!/usr/bin/env bash
# lib/rig-stores.sh — shared "derive bead-store list from the live rig list,
# never a hardcoded HQ/WA/PS default" helper (ga-wz03iq).
#
# WHY: lifecycle-coherence-janitor.sh's LCJ_STORES was hardcoded to
# HQ/whatsapp_automation/property_scrapers since 2026-06-22. `gc rig list`
# grew to 7 rigs since (lexbh, marketing, gastown, deacon added) and every
# script with the same hardcoded default silently never walked those 4 —
# confirmed live: lx-fdl sat past its own pilot:held-until for 19 days,
# invisible to `bd ready`, purely because the janitor that would have undeferred
# it never had lexbh in its store list (ga-3xfndz). This file extracts that
# fix's derivation logic into one shared, independently-tested place instead of
# re-deriving (and re-risking a subtly-different bug) in every one of the ~10
# callers that had the same class of hardcoded list.
#
# CONTRACT (both functions below):
#   - Success: prints data to stdout, exits 0.
#   - Failure (gc missing/non-zero/timed out, unparseable JSON, zero rigs):
#     prints NOTHING, exits 1. Never exits 0 with empty output, never exits
#     non-zero WITH output — a caller can trust "exit 0" and "non-empty" to
#     always agree.
#   - Pure: no logging, no notification, no global state. Callers differ in
#     whether they have a log()/notify() of their own (and what it's called),
#     so deciding how loudly to complain about a fallback is the CALLER's job
#     — same division of responsibility as lifecycle-coherence-janitor.sh's
#     own _lcj_derive_stores(). The canonical caller idiom, safe under both
#     `set -e` and plain `set -u` (the `if VAR=$(fn); then` form never trips
#     -e, unlike a bare assignment checked afterwards with `[ -n ... ]`):
#
#       if _dyn=$(rig_stores_paths "$GC"); then
#         STORES="$_dyn"
#       else
#         log "DEGRADED <name>-stores: gc rig list failed/timed out/returned nothing parseable — using static fallback ($STORES)."
#         "$NOTIFY" -t "<script>" -p 4 "gc rig list falhou/vazio — usando lista estatica de fallback" 2>/dev/null || true
#       fi
#
#   - `gc rig list --json` alone can take 8-17s under load (ga-eu2x) — bounded
#     by an explicit timeout (default 20s, same bound as ga-3xfndz) so a slow
#     city never blocks a caller's sweep indefinitely.
#
# rig_stores_tsv [gc_bin] [timeout_sec]
#   One line per live rig: "<prefix>\t<path>\t<name>". Paths are deduplicated
#   (two rig entries can share a path in edge cases; a caller iterating stores
#   must never visit the same store twice in one sweep).
#
# rig_stores_paths [gc_bin] [timeout_sec] [separator]
#   Convenience wrapper over rig_stores_tsv: prints ONLY the paths, joined by
#   `separator` (default: one space; pass ":" for a colon-separated var like
#   GIT_LOCK_RIG_ROOTS). This is what most callers want.
#
# rig_store_for_prefix <prefix> <tsv>
#   Looks up a single rig's path by its bead-id prefix (e.g. "wa", "lx") in an
#   ALREADY-DERIVED tsv (from rig_stores_tsv) — takes the tsv as an argument
#   rather than re-deriving, because a caller that needs this per-item in a
#   loop (e.g. resolving each stuck story's own store by its id prefix) must
#   derive once up front and reuse, never shell out to `gc rig list` per item.
#   Exit 1 (no output) if the tsv is empty or the prefix isn't in it — the
#   caller decides the fallback (same contract as above).

rig_stores_tsv() {
  local gc_bin="${1:-gc}" to="${2:-20}"
  timeout "$to" "$gc_bin" rig list --json 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
rigs = d.get("rigs") if isinstance(d, dict) else d
if not isinstance(rigs, list):
    sys.exit(1)
out = []
seen = set()
for r in rigs:
    if not isinstance(r, dict):
        continue
    p = (r.get("path") or r.get("work_dir") or "").strip()
    if not p or p in seen:
        continue
    seen.add(p)
    prefix = (r.get("prefix") or "").strip()
    name = (r.get("name") or "").strip()
    out.append(prefix + "\t" + p + "\t" + name)
if not out:
    sys.exit(1)
print("\n".join(out))
' 2>/dev/null
}

rig_stores_paths() {
  local gc_bin="${1:-gc}" to="${2:-20}" sep="${3:- }" tsv
  tsv=$(rig_stores_tsv "$gc_bin" "$to") || return 1
  [ -z "$tsv" ] && return 1
  printf '%s\n' "$tsv" | cut -f2 | paste -sd "$sep" -
}

rig_store_for_prefix() {
  local prefix="$1" tsv="$2" hit
  [ -z "$tsv" ] && return 1
  hit=$(printf '%s\n' "$tsv" | awk -F'\t' -v p="$prefix" '$1==p{print $2; exit}')
  [ -z "$hit" ] && return 1
  printf '%s\n' "$hit"
}

# ── selftest ─────────────────────────────────────────────────────────────────
# Runs only when this file is EXECUTED directly (not sourced) with --selftest,
# so every other caller sourcing it (the normal path) pays zero cost.
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ] && [ "${1:-}" = "--selftest" ]; then
  set -u
  PASS=0; FAIL=0
  ok()  { PASS=$((PASS+1)); echo "  OK: $1"; }
  bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1 (got: ${2:-})"; }

  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT

  # Fixture: 7 live rigs, matching the real `gc rig list --json` shape
  # (confirmed live 2026-09-15), including 4 the old hardcoded HQ/WA/PS
  # default never carried (lexbh, marketing, gastown, deacon) — this is the
  # exact gap lx-fdl fell through for 19 days (ga-3xfndz).
  cat > "$TMP/gc-multirig" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  *"rig list --json"*) cat <<'JSON'
{"rigs":[
  {"name":"gascity","path":"/fixture/gascity","prefix":"ga"},
  {"name":"whatsapp_automation","path":"/fixture/wa","prefix":"wa"},
  {"name":"property_scrapers","path":"/fixture/ps","prefix":"ps"},
  {"name":"lexbh","path":"/fixture/lexbh","prefix":"lx"},
  {"name":"marketing","path":"/fixture/marketing","prefix":"ma"},
  {"name":"gastown","path":"/fixture/gastown","prefix":"gt"},
  {"name":"deacon","path":"/fixture/deacon","prefix":"dc"}
]}
JSON
    ;;
  *) echo '{}' ;;
esac
SHIM
  chmod +x "$TMP/gc-multirig"

  cat > "$TMP/gc-broken" <<'SHIM'
#!/usr/bin/env bash
exit 1
SHIM
  chmod +x "$TMP/gc-broken"

  cat > "$TMP/gc-hang" <<'SHIM'
#!/usr/bin/env bash
sleep 30
SHIM
  chmod +x "$TMP/gc-hang"

  # 1. Success case: derived paths include a rig OUTSIDE the old static 3
  #    (lexbh) — REPROVA against any pre-ga-wz03iq caller, since none of them
  #    could ever have produced this path no matter what `gc rig list`
  #    returned (it was never consulted at all).
  _paths=$(rig_stores_paths "$TMP/gc-multirig")
  case " $_paths " in
    *" /fixture/lexbh "*) ok "rig_stores_paths includes a rig outside the old static 3 (lexbh)" ;;
    *) bad "rig_stores_paths did not include lexbh" "$_paths" ;;
  esac
  _n=$(printf '%s\n' "$_paths" | tr ' ' '\n' | grep -c .)
  [ "$_n" -eq 7 ] && ok "rig_stores_paths carries all 7 live rigs, none dropped" \
    || bad "expected 7 paths" "$_n ($_paths)"

  # 2. Colon separator (git-lock-hygiene.sh / debris-janitor.sh's shape)
  _colon=$(rig_stores_paths "$TMP/gc-multirig" 20 ":")
  case "$_colon" in
    *":"*"/fixture/gastown"*) ok "rig_stores_paths honors a custom separator (colon)" ;;
    *) bad "colon-separated form malformed" "$_colon" ;;
  esac

  # 3. Failure case: gc exits non-zero → NOTHING printed, exit 1 — never a
  #    truncated/empty-looking "success".
  if _out=$(rig_stores_paths "$TMP/gc-broken" 2>/dev/null); then
    bad "rig_stores_paths must fail (exit!=0) when gc fails" "exit 0, out='$_out'"
  else
    [ -z "$_out" ] && ok "rig_stores_paths on gc failure: exit!=0 AND empty output" \
      || bad "gc failure produced non-empty output" "$_out"
  fi

  # 4. Timeout case: a hanging gc must be bounded, not hang the caller.
  _t0=$(date +%s)
  if _out=$(rig_stores_paths "$TMP/gc-hang" 2 2>/dev/null); then
    bad "rig_stores_paths must fail when gc times out" "exit 0, out='$_out'"
  else
    _elapsed=$(( $(date +%s) - _t0 ))
    [ "$_elapsed" -lt 10 ] && [ -z "$_out" ] \
      && ok "rig_stores_paths bounds a hanging gc (returned in ${_elapsed}s, empty output)" \
      || bad "timeout not honored" "elapsed=${_elapsed}s out='$_out'"
  fi

  # 5. Prefix lookup, from an already-derived tsv (no second subprocess).
  _tsv=$(rig_stores_tsv "$TMP/gc-multirig")
  _lx=$(rig_store_for_prefix "lx" "$_tsv")
  [ "$_lx" = "/fixture/lexbh" ] && ok "rig_store_for_prefix resolves a live prefix (lx)" \
    || bad "rig_store_for_prefix(lx)" "$_lx"
  if rig_store_for_prefix "zz" "$_tsv" >/dev/null 2>&1; then
    bad "rig_store_for_prefix must fail for an unknown prefix" ""
  else
    ok "rig_store_for_prefix fails closed for an unknown prefix (caller supplies its own fallback)"
  fi

  echo ""
  echo "rig-stores.sh selftest: PASS=$PASS FAIL=$FAIL"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi
