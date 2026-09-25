#!/bin/bash
# dolt-backup-s3-proof.selftest.sh (ga-btnq6h) — unit tests for dolt-backup-s3-proof.sh.
#
# Hermetic: a FAKE `aws` (a bash script over a directory standing in for the bucket)
# and throwaway backup dirs. The real aws, the real bucket and the real .dolt-backup
# are NEVER touched. The fake is deliberately dumb-but-honest: it implements only the
# aws calls the library makes, logs every call (so tests can assert ORDER and the
# ABSENCE of --delete), and can be told to fail or silently do nothing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/dolt-backup-s3-proof.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/s3proof-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT
FB="$T/bucket"; mkdir -p "$FB"          # fake bucket root: $FB/<db>/<object>
CALLS="$T/aws-calls.log"; : > "$CALLS"

# ── the fake aws ─────────────────────────────────────────────────────────────────
cat > "$T/aws" <<'STUB'
#!/bin/bash
# fake aws — see selftest header. Env knobs: FAKE_LIST_FAIL, FAKE_SYNC_FAIL,
# FAKE_SYNC_NOOP, FAKE_DRYRUN_FAIL, FAKE_CP_UP_FAIL, FB (bucket dir), CALLS (call log).
echo "aws $* [csum=${AWS_REQUEST_CHECKSUM_CALCULATION:-<unset>}]" >> "$CALLS"
sub="$1"; shift
case "$sub" in
  s3api)   # list-objects-v2 --bucket B --prefix db/ --query ... --output text
    [ "${FAKE_LIST_FAIL:-0}" = 1 ] && exit 255
    prefix=""; while [ $# -gt 0 ]; do [ "$1" = "--prefix" ] && prefix="$2"; shift; done
    d="$FB/${prefix%/}"
    if [ ! -d "$d" ] || [ -z "$(ls -A "$d" 2>/dev/null)" ]; then echo "None"; exit 0; fi
    out=""; for f in "$d"/*; do out="${out:+$out	}${prefix}$(basename "$f")"; done
    echo "$out"; exit 0 ;;
  s3)
    op="$1"; shift
    case "$op" in
      cp)
        src="$1"; dst="$2"
        case "$src" in
          s3://*)   # download: s3://B/db/manifest -> local
            key="${src#s3://*/}"; [ -f "$FB/$key" ] || exit 1; cp "$FB/$key" "$dst"; exit 0 ;;
          *)        # upload: local -> s3://B/db/manifest
            [ "${FAKE_CP_UP_FAIL:-0}" = 1 ] && exit 1
            key="${dst#s3://*/}"; mkdir -p "$FB/$(dirname "$key")"; cp "$src" "$FB/$key"; exit 0 ;;
        esac ;;
      sync)
        dir="${1%/}"; dst="$2"; shift 2
        dry=0; excl=""
        while [ $# -gt 0 ]; do
          case "$1" in --dryrun) dry=1 ;; --exclude) excl="$excl $2"; shift ;; esac; shift
        done
        key="${dst#s3://*/}"; key="${key%/}"
        if [ "$dry" = 1 ]; then
          [ "${FAKE_DRYRUN_FAIL:-0}" = 1 ] && exit 2
        else
          [ "${FAKE_SYNC_FAIL:-0}" = 1 ] && exit 1
        fi
        mkdir -p "$FB/$key"
        for f in "$dir"/*; do
          [ -f "$f" ] || continue; n="$(basename "$f")"
          skip=0; for e in $excl; do [ "$e" = "$n" ] && skip=1; done; [ $skip = 1 ] && continue
          if [ ! -f "$FB/$key/$n" ] || [ "$(wc -c < "$f")" != "$(wc -c < "$FB/$key/$n")" ]; then
            if [ "$dry" = 1 ]; then echo "(dryrun) upload: $f to $dst$n"
            elif [ "${FAKE_SYNC_NOOP:-0}" != 1 ]; then cp "$f" "$FB/$key/$n"; fi
          fi
        done
        exit 0 ;;
    esac ;;
esac
exit 99
STUB
chmod +x "$T/aws"

export CALLS FB
export AWS="$T/aws" BUCKET="testbucket" S3PROOF_TIMEOUT=20 S3PROOF_UP_TIMEOUT=20 S3PROOF_LOG="$T/up.log"
LOGF="$T/lib.log"; : > "$LOGF"
log() { echo "$*" >> "$LOGF"; }     # the caller-provided log() the lib prefers
# shellcheck disable=SC1090
. "$LIB"

echo "=== dolt-backup-s3-proof.selftest.sh ==="

# ── helpers to build backup dirs / manifests ─────────────────────────────────────
tid() { printf '%032d' "$1"; }                      # table id: 32 digits (valid base32 charset)
LOCKH="0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; ROOTH="0bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"; GCG="00000000000000000000000000000000"
mkmanifest() { # <file> <n_tables>
  local f="$1" n="$2" i s="5:__DOLT__:$LOCKH:$ROOTH:$GCG"
  for i in $(seq 1 "$n"); do s="$s:$(tid "$i"):$((i*7))"; done
  printf '%s' "$s" > "$f"           # NO trailing newline, like real Dolt manifests
}
mkdir_backup() { # <dir> <n_tables>  — tables 1..n; odd ones raw, even ones .darc
  local d="$1" n="$2" i
  mkdir -p "$d"; mkmanifest "$d/manifest" "$n"
  for i in $(seq 1 "$n"); do
    if [ $((i%2)) -eq 1 ]; then printf 'data%s' "$i" > "$d/$(tid "$i")"; else printf 'darc%s' "$i" > "$d/$(tid "$i").darc"; fi
  done
}
reset_bucket() { rm -rf "$FB"; mkdir -p "$FB"; : > "$CALLS"; : > "$LOGF"; unset FAKE_LIST_FAIL FAKE_SYNC_FAIL FAKE_SYNC_NOOP FAKE_DRYRUN_FAIL FAKE_CP_UP_FAIL; }

# ── _s3proof_manifest_tables ─────────────────────────────────────────────────────
echo "── _s3proof_manifest_tables ──"
mkmanifest "$T/manifest-3tables" 3
got="$(_s3proof_manifest_tables "$T/manifest-3tables" | tr '\n' ' ')"
[ "$got" = "$(tid 1) $(tid 2) $(tid 3) " ] && ok "parses exactly the 3 table ids (lock/root/gcgen/counts/version excluded)" || bad "manifest parse got: '$got'"
: > "$T/mempty"; [ -z "$(_s3proof_manifest_tables "$T/mempty")" ] && ok "empty manifest → no tables" || bad "empty manifest yielded tables"
[ -z "$(_s3proof_manifest_tables "$T/does-not-exist")" ] && ok "missing manifest file → no tables (no crash)" || bad "missing manifest yielded tables"
printf 'not a manifest at all' > "$T/mgarbage"; [ -z "$(_s3proof_manifest_tables "$T/mgarbage")" ] && ok "garbage manifest → no tables" || bad "garbage manifest yielded tables"

# ── _s3proof_local_closure_ok ────────────────────────────────────────────────────
echo "── _s3proof_local_closure_ok ──"
mkdir_backup "$T/L1" 6
_s3proof_local_closure_ok "$T/L1" && ok "complete dir (mixed raw + .darc) → proven" || bad "complete dir not proven"
mkdir_backup "$T/L2" 6; rm -f "$T/L2/$(tid 3)"
_s3proof_local_closure_ok "$T/L2" && bad "dir missing table 3 was PROVEN" || ok "one named table missing → NOT proven"
mkdir_backup "$T/L3" 6; rm -f "$T/L3/manifest"
_s3proof_local_closure_ok "$T/L3" && bad "dir with no manifest was PROVEN" || ok "no manifest → NOT proven"
mkdir -p "$T/L4"; : > "$T/L4/manifest"
_s3proof_local_closure_ok "$T/L4" && bad "empty manifest was PROVEN" || ok "empty manifest → NOT proven"
_s3proof_local_closure_ok "$T/nope" && bad "nonexistent dir was PROVEN" || ok "not a directory → NOT proven"
mkdir_backup "$T/L5" 4; rm -f "$T/L5/$(tid 2).darc"; printf 'x' > "$T/L5/$(tid 2).other"
_s3proof_local_closure_ok "$T/L5" && bad "only a differently-suffixed file counted as the table" || ok "a table present under another suffix does not count (only <id> or <id>.darc)"

# ── _s3proof_s3_closure_ok — the incident replica ────────────────────────────────
echo "── _s3proof_s3_closure_ok ──"
reset_bucket; mkdir_backup "$FB/db1" 8
_s3proof_s3_closure_ok db1 && ok "complete S3 prefix → proven" || bad "complete S3 prefix not proven"
# INCIDENT REPLICA (hq, 2026-09-25): manifest present, names 8 tables, ONE not in the bucket.
reset_bucket; mkdir_backup "$FB/db1" 8; rm -f "$FB/db1/$(tid 5)"
_s3proof_s3_closure_ok db1 && bad "INCIDENT: manifest present but a named table missing was PROVEN (this is the hq 2026-09-25 defect)" || ok "INCIDENT replica: manifest object exists but a named table is missing → NOT proven"
grep -q '1 of 8 tables' "$LOGF" && ok "…and the log says exactly how many are missing (1 of 8)" || bad "log lacks the missing count: $(cat "$LOGF")"
reset_bucket; mkdir_backup "$FB/db1" 8; rm -f "$FB/db1/manifest"
_s3proof_s3_closure_ok db1 && bad "no manifest object was PROVEN" || ok "no manifest object in S3 → NOT proven"
reset_bucket; mkdir_backup "$FB/db1" 8; FAKE_LIST_FAIL=1 _s3proof_s3_closure_ok db1 && bad "list failure was PROVEN" || ok "listing fails → NOT proven (unknown ≠ fine)"
reset_bucket; mkdir -p "$FB/db1"; mkmanifest "$FB/db1/manifest" 3; rm -f "$FB/db1/"*.darc
# only manifest object exists; list returns just it, tables absent
_s3proof_s3_closure_ok db1 && bad "manifest-only prefix was PROVEN" || ok "prefix holding only a manifest → NOT proven"
reset_bucket; _s3proof_s3_closure_ok db1 && bad "empty prefix was PROVEN" || ok "empty/absent prefix → NOT proven"
reset_bucket; mkdir_backup "$FB/db1" 4; (unset AWS; _s3proof_s3_closure_ok db1) && bad "AWS unset was PROVEN" || ok "AWS unset → NOT proven (fail-closed)"
reset_bucket; mkdir_backup "$FB/db1" 4; mkdir_backup "$FB/db10" 2; rm -rf "$FB/db1"; mkdir -p "$FB/db1"
_s3proof_s3_closure_ok db1 && bad "prefix 'db1/' matched objects of 'db10/'" || ok "prefix match is exact-directory ('db1/' does not read 'db10/')"

# ── _s3proof_mirror_identical ────────────────────────────────────────────────────
echo "── _s3proof_mirror_identical ──"
reset_bucket; mkdir_backup "$T/M1" 6; mkdir_backup "$FB/db1" 6
_s3proof_mirror_identical "$T/M1" db1 && ok "S3 already holds every file → identical" || bad "identical copy not recognised"
printf 'newer' > "$T/M1/$(tid 99)"
_s3proof_mirror_identical "$T/M1" db1 && bad "a local file absent from S3 was called identical" || ok "a local file missing from S3 → NOT identical"
rm -f "$T/M1/$(tid 99)"; printf 'longer-content-than-before' > "$T/M1/$(tid 1)"
_s3proof_mirror_identical "$T/M1" db1 && bad "size-differing file was called identical" || ok "same name, different size → NOT identical"
mkdir_backup "$T/M2" 6; mkdir_backup "$FB/db1" 6; : > "$T/M2/LOCK"
_s3proof_mirror_identical "$T/M2" db1 && ok "LOCK (Dolt's own lock file) is ignored" || bad "LOCK made an otherwise-identical copy 'differ'"
grep -q -- '--exclude LOCK' "$CALLS" && ok "…via --exclude LOCK on the dry run" || bad "dry run did not exclude LOCK"
grep -q -- '--delete' "$CALLS" && bad "identity dry run used --delete" || ok "identity dry run never uses --delete"
FAKE_DRYRUN_FAIL=1 _s3proof_mirror_identical "$T/M2" db1 && bad "aws failure was called identical" || ok "aws error during the dry run → NOT identical (unknown ≠ identical)"
reset_bucket; mkdir_backup "$T/M3" 4
_s3proof_mirror_identical "$T/M3" db1 && bad "empty bucket prefix called identical to a full dir" || ok "empty S3 prefix vs full local dir → NOT identical"

# ── _s3proof_mirror_up ───────────────────────────────────────────────────────────
echo "── _s3proof_mirror_up ──"
reset_bucket; mkdir_backup "$T/U1" 6
_s3proof_mirror_up "$T/U1" db1 && ok "uploads a complete dir" || bad "mirror_up failed on a complete dir"
[ -f "$FB/db1/manifest" ] && [ -f "$FB/db1/$(tid 1)" ] && [ -f "$FB/db1/$(tid 2).darc" ] && ok "tables AND manifest landed in the bucket" || bad "bucket missing files after mirror_up"
grep -q -- '--delete' "$CALLS" && bad "mirror_up used --delete (must be additive)" || ok "mirror_up is ADDITIVE — never --delete"
SYNC_LN="$(grep -n 's3 sync' "$CALLS" | head -1 | cut -d: -f1)"; MF_LN="$(grep -n 's3 cp .*manifest s3://' "$CALLS" | head -1 | cut -d: -f1)"
[ -n "$SYNC_LN" ] && [ -n "$MF_LN" ] && [ "$SYNC_LN" -lt "$MF_LN" ] && ok "tables sync runs BEFORE the manifest upload (manifest LAST)" || bad "manifest not last (sync@$SYNC_LN manifest@$MF_LN)"
grep 's3 sync' "$CALLS" | head -1 | grep -q -- '--exclude manifest' && ok "the table sync excludes the manifest" || bad "table sync does not exclude the manifest"
# the core safety property: a failed table upload must NOT publish a manifest.
reset_bucket; mkdir_backup "$T/U2" 6
FAKE_SYNC_FAIL=1 _s3proof_mirror_up "$T/U2" db1 && bad "mirror_up reported success though the table upload failed" || ok "table upload fails → mirror_up fails"
[ ! -f "$FB/db1/manifest" ] && ok "…and the manifest was NOT uploaded (S3 never names tables it lacks)" || bad "manifest was uploaded after a failed table upload"
reset_bucket; mkdir_backup "$T/U3" 6; FAKE_CP_UP_FAIL=1 _s3proof_mirror_up "$T/U3" db1 && bad "manifest upload failure reported as success" || ok "manifest upload fails → mirror_up fails"
reset_bucket; mkdir -p "$T/U4"; printf 'x' > "$T/U4/$(tid 1)"
_s3proof_mirror_up "$T/U4" db1 && bad "uploaded a dir with no manifest" || ok "dir without a manifest → refused, nothing uploaded"
[ ! -s "$CALLS" ] && ok "…without making a single aws call" || bad "aws was called for a manifest-less dir"

# ── _s3proof_restorable_and_identical ────────────────────────────────────────────
echo "── _s3proof_restorable_and_identical ──"
reset_bucket; mkdir_backup "$T/R1" 6; mkdir_backup "$FB/db1" 6
_s3proof_restorable_and_identical "$T/R1" db1 && ok "closed local + closed S3 + identical → proven" || bad "full proof failed on a perfect mirror"
reset_bucket; mkdir_backup "$T/R2" 6; mkdir_backup "$FB/db1" 6; rm -f "$FB/db1/$(tid 5)"
_s3proof_restorable_and_identical "$T/R2" db1 && bad "broken S3 was proven" || ok "S3 not closed → NOT proven (even though local is fine)"
reset_bucket; mkdir_backup "$T/R3" 6; rm -f "$T/R3/$(tid 5)"; mkdir_backup "$FB/db1" 6
_s3proof_restorable_and_identical "$T/R3" db1 && bad "broken LOCAL dir was proven" || ok "local not closed → NOT proven"
reset_bucket; mkdir_backup "$T/R4" 6; mkdir_backup "$FB/db1" 6; printf 'extra' > "$T/R4/$(tid 50).darc"; mkmanifest "$T/R4/manifest" 6
_s3proof_restorable_and_identical "$T/R4" db1 && bad "local file S3 lacks was proven identical" || ok "S3 closed but local holds files S3 lacks → NOT proven (freeing local would lose them)"

# ── _s3proof_repair_then_prove — the hq situation ────────────────────────────────
echo "── _s3proof_repair_then_prove ──"
# hq replica: local staging is closed; S3 manifest names a table S3 lacks and S3 lacks local files.
reset_bucket; mkdir_backup "$T/P1" 10; mkdir_backup "$FB/db1" 10; rm -f "$FB/db1/$(tid 7)" "$FB/db1/$(tid 8).darc"
_s3proof_s3_closure_ok db1 && bad "setup: S3 should start broken" || ok "setup: S3 starts unrestorable (the hq state)"
_s3proof_repair_then_prove "$T/P1" db1 && ok "repair mirrors local up, then the strong proof passes" || bad "repair_then_prove did not converge on the hq replica"
_s3proof_s3_closure_ok db1 && ok "…and S3 is now restorable" || bad "S3 still broken after repair"
grep -q -- '--delete' "$CALLS" && bad "repair used --delete" || ok "repair never used --delete"
# a broken LOCAL dir is never mirrored up over S3.
reset_bucket; mkdir_backup "$T/P2" 10; rm -f "$T/P2/$(tid 3)"; mkdir_backup "$FB/db1" 10; rm -f "$FB/db1/$(tid 9)"
: > "$CALLS"
_s3proof_repair_then_prove "$T/P2" db1 && bad "broken local dir was 'repaired' into a pass" || ok "local broken → repair refused (returns not-proven)"
grep -qE 's3 sync .*P2/ s3://.* --exclude manifest|s3 cp .*P2/manifest s3://' "$CALLS" && bad "a broken local dir was UPLOADED over S3" || ok "…and nothing from the broken local dir was uploaded"
# rounds are bounded: an upload that 'succeeds' but never lands cannot loop forever.
reset_bucket; mkdir_backup "$T/P3" 6
: > "$CALLS"; FAKE_SYNC_NOOP=1 S3PROOF_REPAIR_ROUNDS=2 _s3proof_repair_then_prove "$T/P3" db1 && bad "a no-op upload was reported as proven" || ok "upload that never lands → NOT proven after the bounded rounds"
N_UP="$(grep -c 's3 sync .* --exclude manifest' "$CALLS")"
[ "$N_UP" -eq 2 ] && ok "…exactly S3PROOF_REPAIR_ROUNDS=2 repair uploads were attempted (bounded, no infinite loop)" || bad "expected 2 repair uploads, saw $N_UP"
# already-perfect: no repair upload at all.
reset_bucket; mkdir_backup "$T/P4" 6; mkdir_backup "$FB/db1" 6; : > "$CALLS"
_s3proof_repair_then_prove "$T/P4" db1 && ok "already proven → returns 0" || bad "perfect mirror not proven"
! grep -q -- '--exclude manifest' "$CALLS" && ok "…without uploading anything" || bad "uploaded although already proven"

# ── the ga-tyaozh checksum export reaches the aws child ──────────────────────────
echo "── AWS_REQUEST_CHECKSUM_CALCULATION (ga-tyaozh) ──"
[ "${AWS_REQUEST_CHECKSUM_CALCULATION:-}" = "when_required" ] && ok "exported by the lib on source" || bad "lib did not export AWS_REQUEST_CHECKSUM_CALCULATION"
reset_bucket; mkdir_backup "$T/C1" 3; _s3proof_mirror_up "$T/C1" db1 >/dev/null 2>&1
grep -q 'csum=when_required' "$CALLS" && ! grep -q 'csum=<unset>' "$CALLS" && ok "every aws child call saw when_required" || bad "an aws child call did not inherit the checksum setting: $(grep -c unset "$CALLS") unset"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
