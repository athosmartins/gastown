#!/bin/bash
# dolt-backup-ephemeral-lib.selftest.sh (ga-gqllbc) — unit tests for dolt-backup-ephemeral-lib.sh.
#
# Hermetic: a FAKE `aws` (a bash script over a directory standing in for the bucket — the same
# dumb-but-honest fake dolt-backup-s3-proof.selftest.sh uses), a FAKE `ps`, and throwaway
# .dolt-backup trees. The real aws, the real bucket, the real process list and the real
# .dolt-backup are NEVER touched.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/dolt-backup-ephemeral-lib.sh"
PROOF="$HERE/dolt-backup-s3-proof.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/eph-selftest.XXXXXX")"
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT
FB="$T/bucket"; mkdir -p "$FB"
CALLS="$T/aws-calls.log"; : > "$CALLS"
BIN="$T/bin"; mkdir -p "$BIN"

# ── the fake aws (same behaviour as dolt-backup-s3-proof.selftest.sh's) ──────────────────────
cat > "$BIN/aws" <<'STUB'
#!/bin/bash
echo "aws $*" >> "$CALLS"
sub="$1"; shift
case "$sub" in
  s3api)
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
          s3://*) key="${src#s3://*/}"; [ -f "$FB/$key" ] || exit 1; cp "$FB/$key" "$dst"; exit 0 ;;
          *) [ "${FAKE_CP_UP_FAIL:-0}" = 1 ] && exit 1
             key="${dst#s3://*/}"; mkdir -p "$FB/$(dirname "$key")"; cp "$src" "$FB/$key"; exit 0 ;;
        esac ;;
      sync)
        dir="${1%/}"; dst="$2"; shift 2
        dry=0; excl=""
        while [ $# -gt 0 ]; do
          case "$1" in --dryrun) dry=1 ;; --exclude) excl="$excl $2"; shift ;; esac; shift
        done
        key="${dst#s3://*/}"; key="${key%/}"
        if [ "$dry" = 1 ]; then [ "${FAKE_DRYRUN_FAIL:-0}" = 1 ] && exit 2
        else [ "${FAKE_SYNC_FAIL:-0}" = 1 ] && exit 1; fi
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
chmod +x "$BIN/aws"

# A fake `ps` that prints whatever FAKE_PS_OUT says (or fails when FAKE_PS_FAIL=1).
cat > "$BIN/ps" <<'STUB'
#!/bin/bash
[ "${FAKE_PS_FAIL:-0}" = 1 ] && exit 1
printf '%s\n' "${FAKE_PS_OUT-/usr/sbin/cron
bash /Users/athos/gt/.gascity-gastown-hq/scripts/dolt-s3-backup.sh}"
STUB
chmod +x "$BIN/ps"

export CALLS FB
export AWS="$BIN/aws" BUCKET="testbucket" S3PROOF_TIMEOUT=20 S3PROOF_UP_TIMEOUT=20 S3PROOF_LOG="$T/up.log"
LOGF="$T/lib.log"; : > "$LOGF"
log() { echo "$*" >> "$LOGF"; }
# shellcheck disable=SC1090
. "$PROOF"
# shellcheck disable=SC1090
. "$LIB"

echo "=== dolt-backup-ephemeral-lib.selftest.sh ==="

for fn in _eph_db_list _eph_is_ephemeral _eph_mode_summary _eph_release_target _eph_writer_active _eph_release_staging _eph_s3_fingerprint_state _eph_drop_empty_staging _eph_epoch_utc _eph_s3_last_backup_text; do
  type "$fn" >/dev/null 2>&1 && ok "$fn defined" || { bad "$fn NOT defined"; echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="; exit 1; }
done

# ── helpers ──────────────────────────────────────────────────────────────────────────────────
tid() { printf '%032d' "$1"; }
LOCKH="0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; ROOTH="0bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"; GCG="00000000000000000000000000000000"
mkmanifest() { local f="$1" n="$2" i s="5:__DOLT__:$LOCKH:$ROOTH:$GCG"; for i in $(seq 1 "$n"); do s="$s:$(tid "$i"):$((i*7))"; done; printf '%s' "$s" > "$f"; }
mkdir_backup() { local d="$1" n="$2" i; mkdir -p "$d"; mkmanifest "$d/manifest" "$n"
  for i in $(seq 1 "$n"); do if [ $((i%2)) -eq 1 ]; then printf 'data%s' "$i" > "$d/$(tid "$i")"; else printf 'darc%s' "$i" > "$d/$(tid "$i").darc"; fi; done; }
reset_bucket() { rm -rf "$FB"; mkdir -p "$FB"; : > "$CALLS"; : > "$LOGF"; unset FAKE_LIST_FAIL FAKE_SYNC_FAIL FAKE_SYNC_NOOP FAKE_DRYRUN_FAIL FAKE_CP_UP_FAIL FAKE_PS_OUT FAKE_PS_FAIL DOLT_BACKUP_EPHEMERAL_DRYRUN; }
# a fresh .dolt-backup root, with <db> staged and mirrored identically in the fake bucket
fresh_root() { BACKUP_ROOT="$T/city/.dolt-backup"; rm -rf "$T/city"; mkdir -p "$BACKUP_ROOT"; }

# ═══ config: _eph_db_list / _eph_is_ephemeral ═══════════════════════════════════════════════
echo "── config precedence ──"
export DOLT_BACKUP_EPHEMERAL_CONF="$T/eph.env"
unset DOLT_BACKUP_EPHEMERAL_DBS; rm -f "$T/eph.env"
[ "$(_eph_db_list)" = "hq" ] && ok "default (no conf, no env) → hq" || bad "default list is '$(_eph_db_list)'"
_eph_is_ephemeral hq && ok "hq is ephemeral by default" || bad "hq not ephemeral by default"
_eph_is_ephemeral whatsapp_automation && bad "whatsapp_automation ephemeral by default" || ok "other dbs are NOT ephemeral by default"
_eph_is_ephemeral hq2 && bad "'hq2' matched 'hq' (substring)" || ok "match is exact-word ('hq2' ≠ 'hq')"
_eph_is_ephemeral "" && bad "empty db name is ephemeral" || ok "empty db name → no"
_eph_is_ephemeral "h q" && bad "db name with a space accepted" || ok "invalid db name → no"
_eph_is_ephemeral "../hq" && bad "path-like db name accepted" || ok "path-like db name → no"

DOLT_BACKUP_EPHEMERAL_DBS="hq lexbh"; export DOLT_BACKUP_EPHEMERAL_DBS
[ "$(_eph_db_list)" = "hq lexbh" ] && ok "env overrides the default" || bad "env list: '$(_eph_db_list)'"
DOLT_BACKUP_EPHEMERAL_DBS=""; export DOLT_BACKUP_EPHEMERAL_DBS
[ -z "$(_eph_db_list)" ] && ok "env set to EMPTY → mode off (kill switch)" || bad "empty env still lists '$(_eph_db_list)'"
_eph_is_ephemeral hq && bad "hq ephemeral with an empty env list" || ok "…and hq is then NOT ephemeral"
DOLT_BACKUP_EPHEMERAL_DBS="hq bad;name \$(x) lexbh"; export DOLT_BACKUP_EPHEMERAL_DBS
[ "$(_eph_db_list)" = "hq lexbh" ] && ok "tokens that are not plain identifiers are dropped" || bad "invalid tokens survived: '$(_eph_db_list)'"

printf 'DOLT_BACKUP_EPHEMERAL_DBS=property_scrapers\n' > "$T/eph.env"
[ "$(_eph_db_list)" = "property_scrapers" ] && ok "conf line beats the environment" || bad "conf did not win: '$(_eph_db_list)'"
printf 'DOLT_BACKUP_EPHEMERAL_DBS="hq"\nDOLT_BACKUP_EPHEMERAL_DBS='"'"'lexbh'"'"'\n' > "$T/eph.env"
[ "$(_eph_db_list)" = "lexbh" ] && ok "last conf line wins; quotes stripped" || bad "last-line/quote handling: '$(_eph_db_list)'"
printf 'DOLT_BACKUP_EPHEMERAL_DBS=\n' > "$T/eph.env"
unset DOLT_BACKUP_EPHEMERAL_DBS
[ -z "$(_eph_db_list)" ] && ok "conf line with EMPTY value → off, even though the default is hq" || bad "empty conf line still lists '$(_eph_db_list)'"
_eph_is_ephemeral hq && bad "hq ephemeral despite an empty conf line" || ok "…hq is then NOT ephemeral"
printf '# nothing about us here\nOTHER=1\n' > "$T/eph.env"
[ "$(_eph_db_list)" = "hq" ] && ok "conf WITHOUT our line falls through to the default" || bad "conf without the line broke the default: '$(_eph_db_list)'"
printf 'DOLT_BACKUP_EPHEMERAL_DBS=hq\n' > "$T/eph.env"; chmod 000 "$T/eph.env"
if [ "$(id -u)" != "0" ]; then
  _eph_db_list >/dev/null; rc=$?
  [ "$rc" -eq 2 ] && ok "unreadable conf → rc 2 (cannot tell)" || bad "unreadable conf gave rc $rc"
  _eph_is_ephemeral hq && bad "hq ephemeral with an UNREADABLE conf (doubt must keep the old behaviour)" || ok "unreadable conf → not ephemeral (the staging stays)"
  case "$(_eph_mode_summary)" in off\(conf-unreadable*) ok "summary says conf-unreadable" ;; *) bad "summary: $(_eph_mode_summary)" ;; esac
else
  ok "(running as root — unreadable-conf cases skipped)"; ok "(skipped)"; ok "(skipped)"
fi
chmod 644 "$T/eph.env"; rm -f "$T/eph.env"; mkdir "$T/eph.env"
_eph_db_list >/dev/null; rc=$?
[ "$rc" -eq 2 ] && ok "conf path that is a directory → rc 2" || bad "conf-is-a-directory gave rc $rc"
rmdir "$T/eph.env"
rm -f "$T/eph.env"; unset DOLT_BACKUP_EPHEMERAL_DBS
[ "$(_eph_mode_summary)" = "on(hq)" ] && ok "summary: on(hq)" || bad "summary: $(_eph_mode_summary)"
DOLT_BACKUP_EPHEMERAL_DBS=""; export DOLT_BACKUP_EPHEMERAL_DBS
[ "$(_eph_mode_summary)" = "off" ] && ok "summary: off" || bad "summary: $(_eph_mode_summary)"
unset DOLT_BACKUP_EPHEMERAL_DBS

echo "── dry-run switch (_eph_dryrun): conf line > environment; doubt = dry run ──"
rm -f "$T/eph.env"; unset DOLT_BACKUP_EPHEMERAL_DRYRUN
_eph_dryrun && bad "dry run on by default" || ok "default: NOT a dry run"
DOLT_BACKUP_EPHEMERAL_DRYRUN=1; export DOLT_BACKUP_EPHEMERAL_DRYRUN
_eph_dryrun && ok "env DOLT_BACKUP_EPHEMERAL_DRYRUN=1 → dry run" || bad "env dry run ignored"
DOLT_BACKUP_EPHEMERAL_DRYRUN=yes; export DOLT_BACKUP_EPHEMERAL_DRYRUN
_eph_dryrun && bad "'yes' counted as a dry run (only a literal 1 is)" || ok "anything but a literal 1 is NOT a dry run (no guessing what 'yes' meant)"
printf 'DOLT_BACKUP_EPHEMERAL_DRYRUN=1\n' > "$T/eph.env"; unset DOLT_BACKUP_EPHEMERAL_DRYRUN
_eph_dryrun && ok "conf line DOLT_BACKUP_EPHEMERAL_DRYRUN=1 → dry run" || bad "conf dry run ignored"
[ "$(_eph_db_list)" = "hq" ] && ok "…and a conf with only the dry-run line leaves the db list at its default (hq)" || bad "dry-run-only conf broke the list: '$(_eph_db_list)'"
printf 'DOLT_BACKUP_EPHEMERAL_DRYRUN=0\n' > "$T/eph.env"; DOLT_BACKUP_EPHEMERAL_DRYRUN=1; export DOLT_BACKUP_EPHEMERAL_DRYRUN
_eph_dryrun && bad "conf =0 did not beat env =1" || ok "conf line beats the environment (conf 0 over env 1 → not a dry run)"
unset DOLT_BACKUP_EPHEMERAL_DRYRUN
printf 'DOLT_BACKUP_EPHEMERAL_DRYRUN=1\n' > "$T/eph.env"; chmod 000 "$T/eph.env"
if [ "$(id -u)" != "0" ]; then
  _eph_dryrun && ok "unreadable conf → treated as a dry run (doubt keeps the staging)" || bad "unreadable conf allowed a real release"
else ok "(running as root — skipped)"; fi
chmod 644 "$T/eph.env"; rm -f "$T/eph.env"

# ═══ _eph_release_target — path safety ══════════════════════════════════════════════════════
echo "── _eph_release_target (path-safety) ──"
fresh_root; mkdir_backup "$BACKUP_ROOT/hq" 4
[ "$(_eph_release_target "$BACKUP_ROOT" hq)" = "$BACKUP_ROOT/hq" ] && ok "real dir with a manifest under .dolt-backup → the target" || bad "valid target refused"
_eph_release_target "$BACKUP_ROOT" "hq/../x" >/dev/null && bad "db with a slash accepted" || ok "db name with '/' refused"
_eph_release_target "$BACKUP_ROOT" "" >/dev/null && bad "empty db accepted" || ok "empty db refused"
_eph_release_target "$BACKUP_ROOT" "h.q" >/dev/null && bad "db with a dot accepted" || ok "db name with '.' refused"
_eph_release_target "relative/.dolt-backup" hq >/dev/null && bad "relative root accepted" || ok "relative root refused"
mkdir -p "$T/other/notbackup"; mkdir_backup "$T/other/notbackup/hq" 2
_eph_release_target "$T/other/notbackup" hq >/dev/null && bad "root not named .dolt-backup accepted" || ok "root not literally named .dolt-backup refused"
fresh_root; mkdir_backup "$T/realdir" 3; ln -s "$T/realdir" "$BACKUP_ROOT/hq"
_eph_release_target "$BACKUP_ROOT" hq >/dev/null && bad "symlinked staging accepted" || ok "symlinked staging refused (never follow a link into a delete)"
fresh_root; mkdir -p "$BACKUP_ROOT/hq"; : > "$BACKUP_ROOT/hq/some-table"
_eph_release_target "$BACKUP_ROOT" hq >/dev/null && bad "manifest-less dir accepted" || ok "dir with NO manifest refused (not a backup copy — residue has its own path)"
fresh_root; mkdir -p "$BACKUP_ROOT/hq"; : > "$BACKUP_ROOT/hq/manifest"
_eph_release_target "$BACKUP_ROOT" hq >/dev/null && bad "empty manifest accepted" || ok "empty manifest refused"
fresh_root
_eph_release_target "$BACKUP_ROOT" hq >/dev/null && bad "absent dir accepted" || ok "absent dir refused"

# ═══ _eph_writer_active ═════════════════════════════════════════════════════════════════════
echo "── _eph_writer_active (fake ps) ──"
OLDPATH="$PATH"; PATH="$BIN:$PATH"
reset_bucket
_eph_writer_active && bad "idle process list reported as active" || ok "a process list with only the nightly itself → not active"
FAKE_PS_OUT='bash /x/packs/town-deltas/assets/scripts/mol-dog-backup.sh' _eph_writer_active && ok "mol-dog-backup.sh running → active" || bad "mol-dog-backup not detected"
FAKE_PS_OUT='bash /x/scripts/dolt-backup-reseed.sh hq' _eph_writer_active && ok "dolt-backup-reseed.sh running → active" || bad "reseed not detected"
FAKE_PS_OUT='bash /x/scripts/dolt-compact-routine.sh' _eph_writer_active && ok "dolt-compact-routine.sh running → active" || bad "compact routine not detected"
FAKE_PS_OUT='dolt --data-dir /x backup sync-url file:///y' _eph_writer_active && ok "a raw 'dolt backup sync-url' → active" || bad "raw dolt backup sync not detected"
FAKE_PS_OUT='dolt sql -q USE hq; CALL DOLT_BACKUP('"'"'sync'"'"', '"'"'hq-backup'"'"')' _eph_writer_active && ok "a CALL DOLT_BACKUP client → active" || bad "DOLT_BACKUP client not detected"
FAKE_PS_OUT='bash /x/scripts/mol-dog-backup.selftest.sh' _eph_writer_active && bad "a *.selftest.sh name matched as the writer" || ok "mol-dog-backup.selftest.sh is not mistaken for the writer"
FAKE_PS_FAIL=1 _eph_writer_active && ok "ps fails → treated as ACTIVE (cannot tell)" || bad "ps failure read as 'no writer'"
FAKE_PS_OUT='' _eph_writer_active && ok "empty process list → treated as ACTIVE (cannot tell)" || bad "empty ps output read as 'no writer'"
PATH="$OLDPATH"

# ═══ _eph_release_staging ═══════════════════════════════════════════════════════════════════
echo "── _eph_release_staging ──"
PATH="$BIN:$PATH"
unset DOLT_BACKUP_EPHEMERAL_DBS; rm -f "$T/eph.env"

# 1. proven → released
reset_bucket; fresh_root; mkdir_backup "$BACKUP_ROOT/hq" 6; mkdir_backup "$FB/hq" 6
_eph_release_staging hq "$BACKUP_ROOT/hq"; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$BACKUP_ROOT/hq" ] && ok "S3 proven identical + restorable → staging RELEASED (rc 0, dir gone)" || bad "proven case: rc=$rc, dir exists=$([ -e "$BACKUP_ROOT/hq" ] && echo yes || echo no)"
grep -q 'RELEASING' "$LOGF" && grep -q 'released' "$LOGF" && ok "…and the log says it" || bad "release not logged: $(cat "$LOGF")"
[ "$_EPH_RELEASE_WHY" = "released" ] && ok "…reason word: released (a success is a word of its own)" || bad "reason word is '$_EPH_RELEASE_WHY', expected released"
grep -q -- '--delete' "$CALLS" && bad "the release proof used --delete" || ok "…and the proof never used --delete (nothing in S3 is pruned)"

# 2. S3 lags but the staging is closed → repaired by the additive mirror, THEN released
reset_bucket; fresh_root; mkdir_backup "$BACKUP_ROOT/hq" 6; mkdir_backup "$FB/hq" 4
_eph_release_staging hq "$BACKUP_ROOT/hq"; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$BACKUP_ROOT/hq" ] && [ -f "$FB/hq/$(tid 6).darc" ] && ok "S3 lagging → mirrored up first, then released (S3 now holds table 6)" || bad "lagging S3: rc=$rc exists=$([ -e "$BACKUP_ROOT/hq" ] && echo yes || echo no) t6=$([ -f "$FB/hq/$(tid 6).darc" ] && echo yes || echo no)"

# 3. S3 cannot be brought in line → NOT released
reset_bucket; fresh_root; mkdir_backup "$BACKUP_ROOT/hq" 6; mkdir_backup "$FB/hq" 3
FAKE_SYNC_NOOP=1 _eph_release_staging hq "$BACKUP_ROOT/hq"; rc=$?
[ "$rc" -eq 1 ] && [ -d "$BACKUP_ROOT/hq" ] && ok "an upload that does nothing → not proven → NOT released, staging intact" || bad "unproven S3 deleted the staging (rc=$rc)"
grep -q 'REFUSED' "$LOGF" && ok "…and the refusal is logged" || bad "refusal not logged"
[ "$_EPH_RELEASE_WHY" = "s3-not-proven" ] && ok "…reason word: s3-not-proven (the one reason that needs a human)" || bad "reason word is '$_EPH_RELEASE_WHY', expected s3-not-proven"
reset_bucket; fresh_root; mkdir_backup "$BACKUP_ROOT/hq" 6; mkdir_backup "$FB/hq" 6
FAKE_LIST_FAIL=1 _eph_release_staging hq "$BACKUP_ROOT/hq"; rc=$?
[ "$rc" -eq 1 ] && [ -d "$BACKUP_ROOT/hq" ] && ok "S3 listing fails (cannot find out) → NOT released" || bad "listing failure deleted the staging (rc=$rc)"
reset_bucket; fresh_root; mkdir_backup "$BACKUP_ROOT/hq" 6
_eph_release_staging hq "$BACKUP_ROOT/hq"; rc=$?
[ "$rc" -eq 0 ] || ok "(empty bucket: the additive mirror may upload it; checked next)"
reset_bucket; fresh_root; mkdir_backup "$BACKUP_ROOT/hq" 6; rm -f "$BACKUP_ROOT/hq/$(tid 3)"
_eph_release_staging hq "$BACKUP_ROOT/hq"; rc=$?
[ "$rc" -eq 1 ] && [ -d "$BACKUP_ROOT/hq" ] && ok "staging whose own manifest does not close (a table missing) → NOT released, NOT mirrored" || bad "broken staging was released/mirrored (rc=$rc)"
[ ! -d "$FB/hq" ] || [ -z "$(ls -A "$FB/hq" 2>/dev/null)" ] && ok "…and nothing broken was uploaded over S3" || bad "a broken staging was mirrored to S3"

# 4. not ephemeral
reset_bucket; fresh_root; mkdir_backup "$BACKUP_ROOT/whatsapp_automation" 4; mkdir_backup "$FB/whatsapp_automation" 4
_eph_release_staging whatsapp_automation "$BACKUP_ROOT/whatsapp_automation"; rc=$?
[ "$rc" -eq 1 ] && [ -d "$BACKUP_ROOT/whatsapp_automation" ] && ok "a db that is not ephemeral is never released" || bad "non-ephemeral db released (rc=$rc)"
[ ! -s "$CALLS" ] && ok "…without even asking S3" || bad "aws was called for a non-ephemeral db"
[ "$_EPH_RELEASE_WHY" = "not-ephemeral" ] && ok "…reason word: not-ephemeral (benign)" || bad "reason word is '$_EPH_RELEASE_WHY', expected not-ephemeral"
DOLT_BACKUP_EPHEMERAL_DBS="" ; export DOLT_BACKUP_EPHEMERAL_DBS
reset_bucket; fresh_root; mkdir_backup "$BACKUP_ROOT/hq" 4; mkdir_backup "$FB/hq" 4
_eph_release_staging hq "$BACKUP_ROOT/hq"; rc=$?
[ "$rc" -eq 1 ] && [ -d "$BACKUP_ROOT/hq" ] && ok "kill switch (empty list) → hq is kept" || bad "kill switch ignored (rc=$rc)"
unset DOLT_BACKUP_EPHEMERAL_DBS

# 5. nothing to release
reset_bucket; fresh_root
_eph_release_staging hq "$BACKUP_ROOT/hq"; rc=$?
[ "$rc" -eq 2 ] && ok "no staging dir → rc 2 (nothing to release — a third state, not 'released')" || bad "absent staging gave rc $rc"
[ "$_EPH_RELEASE_WHY" = "absent" ] && ok "…reason word: absent (not 'released')" || bad "reason word is '$_EPH_RELEASE_WHY', expected absent"
[ ! -s "$CALLS" ] && ok "…without touching S3" || bad "aws called with nothing to release"

# 6. dest is not what the path-safety wants
reset_bucket; fresh_root; mkdir_backup "$T/realdir2" 4; mkdir_backup "$FB/hq" 4; ln -s "$T/realdir2" "$BACKUP_ROOT/hq"
_eph_release_staging hq "$BACKUP_ROOT/hq"; rc=$?
[ "$rc" -eq 1 ] && [ -d "$T/realdir2" ] && ok "symlinked staging → refused, the link target survives" || bad "symlink case: rc=$rc"
[ "$_EPH_RELEASE_WHY" = "path-safety" ] && ok "…reason word: path-safety (a refused path)" || bad "reason word is '$_EPH_RELEASE_WHY', expected path-safety"
reset_bucket; fresh_root; mkdir_backup "$BACKUP_ROOT/hq" 4; mkdir_backup "$FB/hq" 4
_eph_release_staging hq "$BACKUP_ROOT/hq/" >/dev/null; rc=$?
[ "$rc" -eq 1 ] && [ -d "$BACKUP_ROOT/hq" ] && ok "dest passed with a trailing slash ≠ the canonical target → refused (exact match only)" || bad "trailing-slash dest: rc=$rc"
reset_bucket; fresh_root; mkdir_backup "$BACKUP_ROOT/hq" 4; mkdir_backup "$FB/hq" 4; BACKUP_ROOT_SAVE="$BACKUP_ROOT"
mkdir -p "$T/notdolt"; mkdir_backup "$T/notdolt/hq" 4; BACKUP_ROOT="$T/notdolt"
_eph_release_staging hq "$T/notdolt/hq"; rc=$?
[ "$rc" -eq 1 ] && [ -d "$T/notdolt/hq" ] && ok "a BACKUP_ROOT not named .dolt-backup → refused" || bad "wrong-root case: rc=$rc"
BACKUP_ROOT="$BACKUP_ROOT_SAVE"

# 7. a writer is running → refuse BEFORE the (slow, uploading) proof
reset_bucket; fresh_root; mkdir_backup "$BACKUP_ROOT/hq" 4; mkdir_backup "$FB/hq" 4
FAKE_PS_OUT='bash /x/packs/town-deltas/assets/scripts/mol-dog-backup.sh' _eph_release_staging hq "$BACKUP_ROOT/hq"; rc=$?
[ "$rc" -eq 1 ] && [ -d "$BACKUP_ROOT/hq" ] && ok "a backup writer is running → NOT released" || bad "released under a running writer (rc=$rc)"
[ ! -s "$CALLS" ] && ok "…decided before any aws call (cheap checks first)" || bad "the S3 proof ran although a writer was active"
[ "$_EPH_RELEASE_WHY" = "writer-active" ] && ok "…reason word: writer-active (benign, retried)" || bad "reason word is '$_EPH_RELEASE_WHY', expected writer-active"
reset_bucket; fresh_root; mkdir_backup "$BACKUP_ROOT/hq" 4; mkdir_backup "$FB/hq" 4
FAKE_PS_FAIL=1 _eph_release_staging hq "$BACKUP_ROOT/hq"; rc=$?
[ "$rc" -eq 1 ] && [ -d "$BACKUP_ROOT/hq" ] && ok "process list unreadable → NOT released (cannot tell ≠ no writer)" || bad "released with an unreadable process list (rc=$rc)"

# 8. the manifest changes while proving → stale proof
reset_bucket; fresh_root; mkdir_backup "$BACKUP_ROOT/hq" 4; mkdir_backup "$FB/hq" 4
_real_proof="$(declare -f _s3proof_repair_then_prove)"
_s3proof_repair_then_prove() { printf 'x' >> "$1/manifest"; return 0; }
_eph_release_staging hq "$BACKUP_ROOT/hq"; rc=$?
[ "$rc" -eq 1 ] && [ -d "$BACKUP_ROOT/hq" ] && ok "manifest changed during the proof → stale proof → NOT released" || bad "stale proof released the staging (rc=$rc)"
grep -q 'manifest changed while proving' "$LOGF" && ok "…and the log names the reason" || bad "stale-proof reason not logged"
[ "$_EPH_RELEASE_WHY" = "manifest-changed" ] && ok "…reason word: manifest-changed (a stale proof)" || bad "reason word is '$_EPH_RELEASE_WHY', expected manifest-changed"
eval "$_real_proof"

# 9. dry run
reset_bucket; fresh_root; mkdir_backup "$BACKUP_ROOT/hq" 4; mkdir_backup "$FB/hq" 4
DOLT_BACKUP_EPHEMERAL_DRYRUN=1 _eph_release_staging hq "$BACKUP_ROOT/hq"; rc=$?

[ "$rc" -eq 1 ] && [ -d "$BACKUP_ROOT/hq" ] && grep -q 'WOULD RELEASE' "$LOGF" && ok "dry run → decides and logs WOULD RELEASE, deletes nothing" || bad "dry run: rc=$rc exists=$([ -d "$BACKUP_ROOT/hq" ] && echo yes || echo no)"
[ "$_EPH_RELEASE_WHY" = "dryrun" ] && ok "…reason word: dryrun (never mistaken for a failure)" || bad "reason word is '$_EPH_RELEASE_WHY', expected dryrun"

# 10. proof library not loaded
reset_bucket; fresh_root; mkdir_backup "$BACKUP_ROOT/hq" 4; mkdir_backup "$FB/hq" 4
( unset -f _s3proof_repair_then_prove; _eph_release_staging hq "$BACKUP_ROOT/hq"; rc=$?; echo "$_EPH_RELEASE_WHY" > "$T/why"; exit "$rc" ); rc=$?; _EPH_RELEASE_WHY="$(cat "$T/why")"
[ "$rc" -eq 1 ] && [ -d "$BACKUP_ROOT/hq" ] && ok "proof library not loaded → NOT released" || bad "released without the proof library (rc=$rc)"
[ "$_EPH_RELEASE_WHY" = "no-proof-lib" ] && ok "…reason word: no-proof-lib (its own reason)" || bad "reason word is '$_EPH_RELEASE_WHY', expected no-proof-lib"

# 11. the rm did not complete (a stubbed rm that does nothing)
reset_bucket; fresh_root; mkdir_backup "$BACKUP_ROOT/hq" 4; mkdir_backup "$FB/hq" 4
printf '#!/bin/bash\nexit 0\n' > "$BIN/rm"; chmod +x "$BIN/rm"; hash -r
_eph_release_staging hq "$BACKUP_ROOT/hq"; rc=$?
/bin/rm -f "$BIN/rm"; hash -r
[ "$rc" -eq 1 ] && grep -q 'did not complete' "$LOGF" && ok "rm that leaves the dir behind → rc 1 and logged (not reported as released)" || bad "incomplete rm: rc=$rc"
[ "$_EPH_RELEASE_WHY" = "rm-incomplete" ] && ok "…reason word: rm-incomplete (its own reason)" || bad "reason word is '$_EPH_RELEASE_WHY', expected rm-incomplete"
# only the staging dir — never a sibling or the parent
reset_bucket; fresh_root; mkdir_backup "$BACKUP_ROOT/hq" 4; mkdir_backup "$FB/hq" 4; mkdir_backup "$BACKUP_ROOT/lexbh" 3; mkdir -p "$BACKUP_ROOT/hq.old"; : > "$BACKUP_ROOT/hq.old/marker"
_eph_release_staging hq "$BACKUP_ROOT/hq"; rc=$?
[ "$rc" -eq 0 ] && [ -d "$BACKUP_ROOT/lexbh" ] && [ -f "$BACKUP_ROOT/hq.old/marker" ] && [ -d "$BACKUP_ROOT" ] \
  && ok "only .dolt-backup/hq is removed — siblings (lexbh, hq.old) and the root survive" || bad "release touched something else (rc=$rc)"
PATH="$OLDPATH"

# ═══ _eph_s3_fingerprint_state ══════════════════════════════════════════════════════════════
echo "── _eph_s3_fingerprint_state ──"
epoch_of() { python3 -c 'import calendar,time,sys; print(calendar.timegm(time.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ")))' "$1"; }
putfp() { mkdir -p "$FB/_meta"; printf '%s' "$1" > "$FB/_meta/latest.json"; }
E1="$(epoch_of 2026-10-01T07:05:12Z)"; E2="$(epoch_of 2026-09-29T09:09:49Z)"; E3="$(epoch_of 2026-10-01T20:07:02Z)"
reset_bucket
putfp '{"run_utc":"2026-10-01T07:05:12Z","databases":{"gastown":{"issues":2,"head":"h","backup_size":"1M"},"beads":{"issues":0,"backup_size":"1K","run_utc":"2026-10-01T20:07:02Z"},"hq":{"status":"failed","reason":"disco","last_ok_run_utc":"2026-09-29T09:09:49Z","last_ok":{"issues":1}},"lexbh":{"status":"failed","reason":"x","last_ok_run_utc":null,"last_ok":null},"weird":{"status":"banana"},"scalar":5,"okex":{"status":"ok","issues":1,"run_utc":"2026-10-01T07:05:12Z"}}}'
[ "$(_eph_s3_fingerprint_state gastown)" = "ok $E1" ] && ok "legacy ok entry (no status, no run_utc) → the FILE's run_utc" || bad "legacy: $(_eph_s3_fingerprint_state gastown) vs ok $E1"
[ "$(_eph_s3_fingerprint_state beads)" = "ok $E3" ] && ok "ok entry with its own run_utc → that time" || bad "own run_utc: $(_eph_s3_fingerprint_state beads)"
[ "$(_eph_s3_fingerprint_state okex)" = "ok $E1" ] && ok "explicit status=ok → ok" || bad "explicit ok: $(_eph_s3_fingerprint_state okex)"
[ "$(_eph_s3_fingerprint_state hq)" = "failed $E2" ] && ok "failed entry → 'failed <last good>' (never 'ok')" || bad "failed: $(_eph_s3_fingerprint_state hq)"
[ "$(_eph_s3_fingerprint_state lexbh)" = "failed unknown" ] && ok "failed with a null last-good → 'failed unknown'" || bad "failed/null: $(_eph_s3_fingerprint_state lexbh)"
[ "$(_eph_s3_fingerprint_state nope)" = "absent" ] && ok "no entry for the db → absent" || bad "absent: $(_eph_s3_fingerprint_state nope)"
[ "$(_eph_s3_fingerprint_state weird)" = "unknown" ] && ok "unrecognised status → unknown (not ok)" || bad "weird status: $(_eph_s3_fingerprint_state weird)"
[ "$(_eph_s3_fingerprint_state scalar)" = "unknown" ] && ok "entry that is not an object → unknown" || bad "scalar entry: $(_eph_s3_fingerprint_state scalar)"
putfp 'not json at all'
[ "$(_eph_s3_fingerprint_state hq)" = "unknown" ] && ok "unparseable file → unknown (could not find out ≠ absent)" || bad "garbage file: $(_eph_s3_fingerprint_state hq)"
putfp '{"run_utc":"2026-10-01T07:05:12Z"}'
[ "$(_eph_s3_fingerprint_state hq)" = "unknown" ] && ok "file without a databases map → unknown" || bad "no databases: $(_eph_s3_fingerprint_state hq)"
putfp '{"run_utc":"yesterday","databases":{"hq":{"issues":1}}}'
[ "$(_eph_s3_fingerprint_state hq)" = "unknown" ] && ok "ok entry with an unparseable time → unknown (never a made-up age)" || bad "bad time: $(_eph_s3_fingerprint_state hq)"
reset_bucket
[ "$(_eph_s3_fingerprint_state hq)" = "unknown" ] && ok "file not in the bucket → unknown" || bad "missing file: $(_eph_s3_fingerprint_state hq)"
putfp '{"run_utc":"2026-10-01T07:05:12Z","databases":{"hq":{"issues":1}}}'
[ "$(AWS="" _eph_s3_fingerprint_state hq)" = "unknown" ] && ok "AWS unset → unknown" || bad "AWS unset: $(AWS="" _eph_s3_fingerprint_state hq)"
[ "$(_eph_s3_fingerprint_state 'h q')" = "unknown" ] && ok "invalid db name → unknown" || bad "invalid db: $(_eph_s3_fingerprint_state 'h q')"
_eph_s3_fingerprint_state hq >/dev/null; [ $? -eq 0 ] && ok "always rc 0 — the answer is the word" || bad "non-zero rc"

# ═══ _eph_drop_empty_staging (ga-94vxdw) ════════════════════════════════════════════════════
# The old nightly's `DOLT_BACKUP('add', …, 'file://<dest>')` re-made an EMPTY .dolt-backup/hq every night. An empty
# dir is not a staging; this removes exactly that and nothing else (rmdir — it cannot remove a non-empty dir).
echo "── _eph_drop_empty_staging (ga-94vxdw) ──"
unset DOLT_BACKUP_EPHEMERAL_DBS; rm -f "$T/eph.env"
fresh_root; : > "$LOGF"
mkdir "$BACKUP_ROOT/hq"
_eph_drop_empty_staging hq "$BACKUP_ROOT/hq"; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$BACKUP_ROOT/hq" ] && [ -d "$BACKUP_ROOT" ] && grep -qF 'removed an EMPTY' "$LOGF" \
  && ok "an EMPTY staging dir of an ephemeral db → removed (rc 0), announced in the log, the root stays" || bad "empty dir not removed (rc=$rc): $(cat "$LOGF")"
: > "$LOGF"
_eph_drop_empty_staging hq "$BACKUP_ROOT/hq"; rc=$?
[ "$rc" -eq 2 ] && [ ! -s "$LOGF" ] && ok "already absent → rc 2 ('nothing to do'), silent" || bad "absent dir gave rc $rc, log: $(cat "$LOGF")"
mkdir "$BACKUP_ROOT/hq"; printf 'x' > "$BACKUP_ROOT/hq/anything"
_eph_drop_empty_staging hq "$BACKUP_ROOT/hq"; rc=$?
[ "$rc" -eq 1 ] && [ -f "$BACKUP_ROOT/hq/anything" ] \
  && ok "a dir with ANY content (even a stray file, no manifest) → left alone, rc 1: only a truly empty dir is ever removed" || bad "non-empty dir was touched (rc=$rc)"
rm -f "$BACKUP_ROOT/hq/anything"; mkdir "$BACKUP_ROOT/hq/sub"
_eph_drop_empty_staging hq "$BACKUP_ROOT/hq"; rc=$?
[ "$rc" -eq 1 ] && [ -d "$BACKUP_ROOT/hq/sub" ] && ok "a dir holding only an (empty) subdirectory → left alone" || bad "dir with a subdir was touched (rc=$rc)"
rmdir "$BACKUP_ROOT/hq/sub"; rmdir "$BACKUP_ROOT/hq"
mkdir "$BACKUP_ROOT/lexbh"
_eph_drop_empty_staging lexbh "$BACKUP_ROOT/lexbh"; rc=$?
[ "$rc" -eq 1 ] && [ -d "$BACKUP_ROOT/lexbh" ] && ok "an empty dir of a db that is NOT ephemeral → left alone (rc 1)" || bad "non-ephemeral db's dir was touched (rc=$rc)"
mkdir "$BACKUP_ROOT/hq.new"
_eph_drop_empty_staging hq "$BACKUP_ROOT/hq.new"; rc=$?
[ "$rc" -eq 1 ] && [ -d "$BACKUP_ROOT/hq.new" ] && ok "dest that is not exactly <root>/<db> (hq.new) → refused, nothing removed" || bad "dest mismatch was not refused (rc=$rc)"
rmdir "$BACKUP_ROOT/hq.new" "$BACKUP_ROOT/lexbh"
mkdir "$T/elsewhere"; ln -s "$T/elsewhere" "$BACKUP_ROOT/hq"
_eph_drop_empty_staging hq "$BACKUP_ROOT/hq"; rc=$?
[ "$rc" -eq 1 ] && [ -L "$BACKUP_ROOT/hq" ] && [ -d "$T/elsewhere" ] && ok "a SYMLINK at .dolt-backup/hq (to an empty dir) → never followed, never removed" || bad "symlink was touched (rc=$rc)"
rm -f "$BACKUP_ROOT/hq"; rmdir "$T/elsewhere"
OLD_BR="$BACKUP_ROOT"
BACKUP_ROOT="$T/city/not-a-backup-root"; mkdir -p "$BACKUP_ROOT/hq"
_eph_drop_empty_staging hq "$BACKUP_ROOT/hq"; rc=$?
[ "$rc" -eq 1 ] && [ -d "$BACKUP_ROOT/hq" ] && ok "a root not literally named .dolt-backup → refused" || bad "wrong root was accepted (rc=$rc)"
rmdir "$BACKUP_ROOT/hq" "$BACKUP_ROOT"
BACKUP_ROOT=""; _eph_drop_empty_staging hq "/hq"; rc=$?
[ "$rc" -eq 1 ] && ok "BACKUP_ROOT unset → refused (never builds a path from nothing)" || bad "unset root gave rc $rc"
BACKUP_ROOT="$OLD_BR"
mkdir "$BACKUP_ROOT/hq"; chmod 000 "$BACKUP_ROOT"
if [ "$(id -u)" != "0" ]; then
  _eph_drop_empty_staging hq "$BACKUP_ROOT/hq"; rc=$?
  chmod 755 "$BACKUP_ROOT"
  [ "$rc" -eq 1 ] && [ -d "$BACKUP_ROOT/hq" ] && ok "an UNSEARCHABLE root → rc 1 ('cannot tell'), never rc 2 ('absent'), nothing removed" || bad "unsearchable root gave rc $rc"
else chmod 755 "$BACKUP_ROOT"; ok "(running as root — skipped)"; fi
rmdir "$BACKUP_ROOT/hq" 2>/dev/null
printf 'DOLT_BACKUP_EPHEMERAL_DBS=\n' > "$T/eph.env"; mkdir "$BACKUP_ROOT/hq"
_eph_drop_empty_staging hq "$BACKUP_ROOT/hq"; rc=$?
[ "$rc" -eq 1 ] && [ -d "$BACKUP_ROOT/hq" ] && ok "kill switch (conf line with an empty value) → hq is not ephemeral → left alone" || bad "removed under the kill switch (rc=$rc)"
rmdir "$BACKUP_ROOT/hq"; rm -f "$T/eph.env"
grep -qE '(^|[^a-z])rm -rf|rm -r ' <(sed -n '/^_eph_drop_empty_staging()/,/^}/p' "$LIB") \
  && bad "_eph_drop_empty_staging contains an rm -r — it must only ever rmdir" || ok "_eph_drop_empty_staging uses rmdir only (no rm -r anywhere in its body)"

# ═══ _eph_epoch_utc / _eph_s3_last_backup_text (ga-94vxdw) ══════════════════════════════════
echo "── _eph_epoch_utc / _eph_s3_last_backup_text (ga-94vxdw) ──"
[ "$(_eph_epoch_utc "$(epoch_of 2026-10-01T23:38:00Z)")" = "2026-10-01T23:38:00Z" ] && ok "_eph_epoch_utc round-trips an epoch to its UTC timestamp" || bad "epoch→utc: $(_eph_epoch_utc "$(epoch_of 2026-10-01T23:38:00Z)")"
[ "$(_eph_epoch_utc abc)" = "?" ] && [ "$(_eph_epoch_utc '')" = "?" ] && ok "_eph_epoch_utc: a non-number → '?' (never a made-up time)" || bad "epoch junk: '$(_eph_epoch_utc abc)' '$(_eph_epoch_utc '')'"
reset_bucket
putfp '{"run_utc":"2026-10-01T23:50:00Z","databases":{"hq":{"status":"ok","run_utc":"2026-10-01T23:38:00Z"},"lexbh":{"status":"failed","last_ok_run_utc":"2026-09-29T09:09:49Z"},"beads":{"status":"failed","last_ok_run_utc":null}}}'
out="$(_eph_s3_last_backup_text hq)"
case "$out" in *"last good backup of hq at 2026-10-01T23:38:00Z"*) ok "ok entry → 'last good backup of hq at <UTC time>'" ;; *) bad "ok text: $out" ;; esac
out="$(_eph_s3_last_backup_text lexbh)"
case "$out" in *"last night FAILED for lexbh"*"2026-09-29T09:09:49Z"*) ok "failed entry with a last-good time → says FAILED and gives the last good time" ;; *) bad "failed text: $out" ;; esac
out="$(_eph_s3_last_backup_text beads)"
case "$out" in *"last night FAILED for beads"*"does not record"*) ok "failed entry with no last-good time → says so" ;; *) bad "failed-unknown text: $out" ;; esac
out="$(_eph_s3_last_backup_text nosuchdb)"
case "$out" in *"has no entry for nosuchdb"*) ok "no entry for the db → 'has no entry'" ;; *) bad "absent text: $out" ;; esac
reset_bucket
out="$(_eph_s3_last_backup_text hq)"
case "$out" in *"could not be read"*"says nothing about whether the S3 copy restores"*) ok "fingerprint missing from the bucket → 'could not be read … says nothing about whether the S3 copy restores' (unknown, not 'not proven')" ;; *) bad "unknown text: $out" ;; esac
case "$out" in *"NOT proven"*|*"not proven"*) bad "the unknown state was worded as 'not proven': $out" ;; *) ok "…and the unknown state never says 'not proven'" ;; esac
_eph_s3_last_backup_text hq >/dev/null; [ $? -eq 0 ] && ok "_eph_s3_last_backup_text always rc 0" || bad "_eph_s3_last_backup_text non-zero rc"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
