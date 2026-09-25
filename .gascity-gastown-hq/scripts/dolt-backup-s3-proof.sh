#!/bin/bash
# dolt-backup-s3-proof.sh (ga-btnq6h) — LIBRARY: prove what a Dolt backup copy
# ACTUALLY is before anything acts on it. Source it; never execute it directly.
#
# ═══ WHY THIS EXISTS ═══
#
# Several scripts here act on the belief "S3 already holds this backup": free the
# local staging (dolt-backup-reseed.sh's low-disk mode, dolt-gc-maintenance.sh's
# headroom release), skip a re-upload. The proof they had was "the manifest OBJECT
# exists in S3" + "its size is within a ratio of the last published fingerprint".
# Neither says the copy can be restored.
#
# MEASURED 2026-09-25 (ga-btnq6h), hq: `head-object hq/manifest` succeeded (4089 B,
# 103 tables) while ONE of the tables that manifest names was not in the bucket, and
# 31 local files (2.69 GB) never uploaded — the 2026-09-21 04:13 `aws s3 sync` had
# failed halfway (ga-tyaozh) and the following FOUR nightly runs skipped the mirror
# step. That copy could not be restored, and the old proof would have called it good.
# It only failed to authorize deleting the one complete local staging because hq's
# fingerprint entry happened to be missing that week — an accident, not a guard.
#
# ═══ WHAT "RESTORABLE" MEANS HERE ═══
#
# A Dolt backup dir is content-addressed. `manifest` (colon-separated:
#   <ver>:<storage>:<lock>:<root>:<gcgen>:<table-id>:<chunk-count>:<table-id>:...)
# names every table that makes up the store; each table is a file `<id>` or
# `<id>.darc` (archive format — a fresh backup is all .darc, older syncs left raw
# files; both are normal). A copy restores iff EVERY table its manifest names is
# present. That "closure" is what _s3proof_*_closure_ok checks — on the LOCAL dir
# (so we never mirror a broken staging over S3) and on the S3 prefix.
#
# ═══ CONTRACT ═══
#
# Every _s3proof_*_ok / _identical function returns 0 ONLY when the property was
# positively established, and 1 for BOTH "it is false" and "I could not find out"
# (missing tool, aws error, unreadable file, empty listing) — never 0 on doubt
# (error and empty must not produce the same value as "fine"; ga-p5q3 family). Each
# logs its own reason via log() when the caller defined one, else to stderr.
#
# Caller provides: AWS (aws CLI path), BUCKET. Optional: S3PROOF_TIMEOUT (read-only
# aws calls, default 300s), S3PROOF_UP_TIMEOUT (uploads, default 1500s),
# S3PROOF_LOG (file that upload output is appended to, default /dev/null),
# S3PROOF_REPAIR_ROUNDS (default 2). Bash 3.2-safe (macOS /bin/bash).
#
# Uploads use AWS_REQUEST_CHECKSUM_CALCULATION=when_required (ga-tyaozh): the aws-cli
# default wraps bodies in a non-seekable chunked encoder that aborts retries — the
# exact defect that broke hq's S3 copy. Exported here so EVERY caller inherits it
# rather than trusting each call site to remember.
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required

S3PROOF_TIMEOUT="${S3PROOF_TIMEOUT:-300}"
S3PROOF_UP_TIMEOUT="${S3PROOF_UP_TIMEOUT:-1500}"
S3PROOF_REPAIR_ROUNDS="${S3PROOF_REPAIR_ROUNDS:-2}"

_s3proof_log() {
  if declare -f log >/dev/null 2>&1; then log "$*"; else echo "[s3proof] $*" >&2; fi
}

# _s3proof_manifest_tables <manifest_file> — table ids named by the manifest, one per
# line (nothing if the file is missing/empty/unparseable). Fields 1-5 are version,
# storage, lock, root and gc-generation; from the 6th on, only the 32-char base32
# table ids match (chunk counts are short decimals).
_s3proof_manifest_tables() {
  local f="$1"
  [ -s "$f" ] || return 0
  tr ':' '\n' < "$f" | tail -n +6 | tr -d '\r' | grep -E '^[0-9a-v]{32}$' || true
}

# _s3proof_names_have <names_file> <table-id> — is <id> or <id>.darc listed?
_s3proof_names_have() {
  grep -qxF -- "$2" "$1" 2>/dev/null || grep -qxF -- "$2.darc" "$1" 2>/dev/null
}

# _s3proof_local_closure_ok <dir> — every table the LOCAL manifest names exists in <dir>.
_s3proof_local_closure_ok() {
  local dir="$1" tabs t n=0 miss=0
  if [ ! -d "$dir" ]; then
    _s3proof_log "local closure: '$dir' is not a directory — NOT proven"; return 1
  fi
  if [ ! -s "$dir/manifest" ]; then
    _s3proof_log "local closure: no manifest in '$dir' — NOT proven (a backup dir without a manifest does not restore)"; return 1
  fi
  tabs="$(_s3proof_manifest_tables "$dir/manifest")"
  if [ -z "$tabs" ]; then
    _s3proof_log "local closure: manifest in '$dir' names no tables (or is unparseable) — NOT proven"; return 1
  fi
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    n=$((n+1))
    if [ ! -f "$dir/$t" ] && [ ! -f "$dir/$t.darc" ]; then miss=$((miss+1)); fi
  done <<EOF
$tabs
EOF
  if [ "$miss" -ne 0 ]; then
    _s3proof_log "local closure: $miss of $n manifest tables missing in '$dir' — NOT proven"; return 1
  fi
  _s3proof_log "local closure OK: $n/$n manifest tables present in '$dir'"
  return 0
}

# _s3proof_s3_closure_ok <db> — every table the S3 manifest names exists in the bucket.
_s3proof_s3_closure_ok() {
  local db="$1" mf names tabs t n=0 miss=0 rc
  if [ -z "${AWS:-}" ] || [ -z "${BUCKET:-}" ]; then
    _s3proof_log "s3 closure: AWS/BUCKET not set — NOT proven"; return 1
  fi
  mf="$(mktemp "${TMPDIR:-/tmp}/s3proof-manifest.XXXXXX")" || { _s3proof_log "s3 closure: mktemp failed — NOT proven"; return 1; }
  names="$(mktemp "${TMPDIR:-/tmp}/s3proof-names.XXXXXX")" || { rm -f "$mf"; _s3proof_log "s3 closure: mktemp failed — NOT proven"; return 1; }
  if ! timeout "$S3PROOF_TIMEOUT" "$AWS" s3 cp "s3://$BUCKET/$db/manifest" "$mf" --only-show-errors >/dev/null 2>&1; then
    _s3proof_log "s3 closure: cannot read s3://$BUCKET/$db/manifest — NOT proven"; rm -f "$mf" "$names"; return 1
  fi
  timeout "$S3PROOF_TIMEOUT" "$AWS" s3api list-objects-v2 --bucket "$BUCKET" --prefix "$db/" \
      --query 'Contents[].Key' --output text 2>/dev/null \
    | tr '\t' '\n' | awk -v p="$db/" 'index($0,p)==1 {print substr($0,length(p)+1)}' > "$names"
  rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ] || [ ! -s "$names" ]; then
    _s3proof_log "s3 closure: could not list s3://$BUCKET/$db/ (rc=$rc, or empty) — NOT proven"; rm -f "$mf" "$names"; return 1
  fi
  tabs="$(_s3proof_manifest_tables "$mf")"
  if [ -z "$tabs" ]; then
    _s3proof_log "s3 closure: S3 manifest for '$db' names no tables (or is unparseable) — NOT proven"; rm -f "$mf" "$names"; return 1
  fi
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    n=$((n+1))
    _s3proof_names_have "$names" "$t" || miss=$((miss+1))
  done <<EOF
$tabs
EOF
  rm -f "$mf" "$names"
  if [ "$miss" -ne 0 ]; then
    _s3proof_log "s3 closure: $miss of $n tables named by s3://$BUCKET/$db/manifest are MISSING from the bucket — the S3 copy does NOT restore"; return 1
  fi
  _s3proof_log "s3 closure OK: $n/$n tables named by s3://$BUCKET/$db/manifest exist in the bucket"
  return 0
}

# _s3proof_mirror_identical <dir> <db> — nothing in <dir> would still be uploaded (S3
# already has every file, same size, not older). `LOCK` is excluded: it is Dolt's own
# 0-byte lock file, rewritten on every open and irrelevant to a restore. NO --delete
# in the dry run: extra objects in S3 are harmless to "S3 has everything local has".
_s3proof_mirror_identical() {
  local dir="$1" db="$2" out rc pending
  if [ -z "${AWS:-}" ] || [ -z "${BUCKET:-}" ]; then
    _s3proof_log "mirror check: AWS/BUCKET not set — NOT proven"; return 1
  fi
  out="$(timeout "$S3PROOF_TIMEOUT" "$AWS" s3 sync "$dir/" "s3://$BUCKET/$db/" --dryrun --exclude LOCK 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    _s3proof_log "mirror check: aws s3 sync --dryrun failed (rc=$rc) — cannot tell whether S3 matches '$dir' — NOT proven"; return 1
  fi
  case "$out" in
    *"(dryrun)"*)
      pending="$(printf '%s\n' "$out" | grep -c '(dryrun)')"
      _s3proof_log "mirror check: $pending file(s) in '$dir' are missing from / differ in s3://$BUCKET/$db/ — NOT identical"; return 1 ;;
  esac
  _s3proof_log "mirror check OK: s3://$BUCKET/$db/ already holds everything in '$dir'"
  return 0
}

# _s3proof_mirror_up <dir> <db> — ADDITIVE upload (never --delete): tables first, the
# manifest LAST, so at every instant the S3 manifest only names tables that already
# exist (a `sync` uploads in arbitrary order; a manifest that lands before its tables
# is precisely how a half-finished run leaves an unrestorable copy). Costs no local
# disk. Returns 0 iff both phases succeeded.
_s3proof_mirror_up() {
  local dir="$1" db="$2" lg="${S3PROOF_LOG:-/dev/null}"
  if [ -z "${AWS:-}" ] || [ -z "${BUCKET:-}" ]; then
    _s3proof_log "mirror up: AWS/BUCKET not set — refusing"; return 1
  fi
  if [ ! -s "$dir/manifest" ]; then
    _s3proof_log "mirror up: no manifest in '$dir' — refusing to upload a backup dir that cannot restore"; return 1
  fi
  if ! timeout "$S3PROOF_UP_TIMEOUT" "$AWS" s3 sync "$dir/" "s3://$BUCKET/$db/" \
        --exclude manifest --exclude LOCK --only-show-errors >> "$lg" 2>&1; then
    _s3proof_log "mirror up: table upload to s3://$BUCKET/$db/ FAILED — manifest NOT touched"; return 1
  fi
  if ! timeout "$S3PROOF_UP_TIMEOUT" "$AWS" s3 cp "$dir/manifest" "s3://$BUCKET/$db/manifest" --only-show-errors >> "$lg" 2>&1; then
    _s3proof_log "mirror up: manifest upload to s3://$BUCKET/$db/ FAILED"; return 1
  fi
  _s3proof_log "mirror up OK: tables then manifest uploaded to s3://$BUCKET/$db/ (additive, no --delete)"
  return 0
}

# _s3proof_restorable_and_identical <dir> <db> — the STRONG proof: <dir> is itself a
# closed backup, S3 is a closed (restorable) backup, and S3 already holds every file
# in <dir>. Only then does freeing <dir> lose nothing S3 does not also have.
_s3proof_restorable_and_identical() {
  local dir="$1" db="$2"
  _s3proof_local_closure_ok "$dir" || return 1
  _s3proof_s3_closure_ok "$db" || return 1
  _s3proof_mirror_identical "$dir" "$db" || return 1
  return 0
}

# _s3proof_repair_then_prove <dir> <db> — prove; if not proven, repair by mirroring
# <dir> up (only when <dir> is itself closed — never propagate a broken copy), and
# prove again, at most S3PROOF_REPAIR_ROUNDS times (a concurrent writer can move <dir>
# between rounds). Returns 0 ONLY if a full proof passed after the last action.
_s3proof_repair_then_prove() {
  local dir="$1" db="$2" round=0
  while :; do
    if _s3proof_restorable_and_identical "$dir" "$db"; then return 0; fi
    round=$((round+1))
    if [ "$round" -gt "$S3PROOF_REPAIR_ROUNDS" ]; then
      _s3proof_log "repair/prove: still NOT proven after $S3PROOF_REPAIR_ROUNDS repair round(s) for '$db'"; return 1
    fi
    _s3proof_local_closure_ok "$dir" || { _s3proof_log "repair/prove: local copy is not a closed backup — not mirroring it"; return 1; }
    _s3proof_log "repair/prove: round $round — mirroring '$dir' to S3 for '$db'"
    _s3proof_mirror_up "$dir" "$db" || return 1
  done
}
