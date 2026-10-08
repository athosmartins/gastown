#!/bin/bash
# dolt-backup-ephemeral-lib.sh (ga-gqllbc) — LIBRARY: dbs whose LOCAL backup staging is
# transient. Source it; never execute it directly.
#
# ═══ WHY ═══
#
# .dolt-backup/hq is a PERMANENT 9.5 GB copy of a store whose real copy is already in S3
# (proven restorable, urblink-dolt-backups/hq/). On a machine that lives at 7-10 GB free that
# one directory is the difference between the gate's pre-review running or not (ga-ufskhy:
# 44 of 46 pre-reviews blocked by "disk < 10 GiB"), and between the nightly's 150% disk gate
# (14.4 GB for hq) passing or refusing — it refused on 09-22..25, 09-28..30 and 10-01. Nothing
# else needs the copy: S3 holds the same bytes, and the live store is the source.
#
# MEASURED 2026-10-01: hq live 9.6 GB, .dolt-backup/hq 9.5 GB, free 7.4 GB. Without the staging
# the same disk has 16.9 GB free — above the nightly's gate with room to spare.
#
# MEASURED 2026-10-08 (ga-a0woau): the staging was gone, the gate still refused 8 nights of 9
# (30/09..08/10), e.g. 08/10 04:03: livre=11595MB precisa=16843MB vivo=11229MB. A staging built
# "from scratch" is a full copy of the store, written to a disk that does not have room for one.
# The fix is a smaller build, not a looser gate: see "THE STAGING IS SEEDED" below.
#
# ═══ WHAT "EPHEMERAL" MEANS ═══
#
# For a db listed here (default: hq) the staging dir is a SCRATCH area, not a store:
#   1. the nightly (dolt-s3-backup.sh) builds it with the server-free offline sync, uploads it
#      to S3, PROVES S3 holds an identical and restorable copy (dolt-backup-s3-proof.sh), and
#      only then deletes it (_eph_release_staging below);
#   2. everything else that used to write or reseed it leaves it alone — mol-dog-backup
#      (6-hourly) skips the db, dolt-backup-reseed.sh is a no-op for it;
#   3. everything that used to read it as "the backup" reads S3 instead
#      (_eph_s3_fingerprint_state) — dolt-restore-verify.sh, mol-dog-doctor.sh.
# Why the server-mediated sync is NOT used for these dbs: a Dolt server keeps a cached view of
# a staging dir that was emptied under it, so the next `CALL DOLT_BACKUP('sync')` writes several
# GB, dies on "table file not found" and leaves a manifest-less residue (ga-yct7r1, ga-ypxbxm:
# 6.4 GB of it on 2026-09-29). Dolt 2.3.1 still has no plain `s3://` backup scheme ("unknown url
# scheme: 's3'", re-checked for this bead), so a local staging for the DURATION of one backup
# cannot be avoided — only its permanence can, and (ga-a0woau) the disk it really costs.
#
# ═══ THE STAGING IS SEEDED (ga-a0woau) ═══
#
# `dolt backup sync-url` into an EMPTY dest rewrites every chunk of the store (11 GB for hq, as
# new files). The nightly therefore seeds the dest first (dolt-offline-backup-sync.sh, "SEEDED
# MODE"): clonefile copies (`cp -c`, APFS copy-on-write, ~0 real disk) of the snapshot's
# .dolt/noms/oldgen tables plus a manifest naming them under a placeholder root. sync-url sees a
# non-empty backup, keeps those files byte for byte and writes only what oldgen does not hold
# (hq: ~0.7 GB of the live store lie outside oldgen; measured 2026-10-08 on the real store, the
# sync took 30-37 s, left 100 of 100 seeded files untouched and used ~240 MB of disk). The
# nightly's disk gate counts that credit (and only that) and REQUIRES the seed when it did: a seed
# that cannot be built is a refused night with a reason, never a fall-back to the full build the
# gate did not reserve.
# The seed is held by the staging, so while the staging exists its clonefile copies pin the
# oldgen blocks: a `dolt gc` of the live store frees nothing that the staging still shares. The
# nightly releases the staging as soon as S3 is proven (below), which ends that.
#
# ═══ WHO DELETES, AND WHY THAT IS NOT AN AGENT'S rm -rf ═══
#
# Doctrine (Athos 2026-09-16, class authorization quoted in dolt-backup-residue-reclaim.sh):
# "staging de backup com cópia remota verificada pode ser liberado pelo SISTEMA". The delete in
# _eph_release_staging is performed by the scheduled nightly itself, behind a fail-closed S3
# proof — the same shape as dolt-gc-maintenance.sh's ga-btnq6h release and
# dolt-backup-residue-reclaim.sh. An agent (an LLM mid-incident) is still barred from rm -rf on
# a Dolt-adjacent directory, and this file does not change that.
#
# ═══ KNOWN CONSEQUENCES (stated, not hidden) ═══
#
#   - The nightly's own disk gate still applies. For an ephemeral db whose staging is EMPTY and
#     whose oldgen can be cloned it is the floor (3 GB) + 150% of what the seed does NOT cover
#     (hq: ~3.3 GB, not 16.8 GB); for anything else — a staging that already holds content, a
#     store that was never GC'd, a different volume, an unreadable oldgen — it is the legacy
#     150% of live for a FULL backup. A night below it still leaves S3 unrefreshed — the
#     nightly says so loudly (notify + streak escalation), as it does today.
#   - dolt-gc-maintenance.sh's prune/flatten "backup is fresh" gate reads the LOCAL staging and
#     so stays closed for an ephemeral db. Both are off (PRUNE_ENABLED=0, FLATTEN default off);
#     whoever turns them on for hq must teach that gate to read S3 first.
#   - dolt-restore-verify.sh cannot afford a real restore of hq from S3 (~19 GB: pull + restore).
#     For an ephemeral db it checks what it can — S3 manifest closure plus fingerprint freshness
#     — and labels the result S3-OK, never OK. A real restore drill belongs after the hq GC
#     (ga-txsjgj) has made the store small enough to restore.
#
# ═══ CONFIG ═══
#
# DOLT_BACKUP_EPHEMERAL_DBS — space-separated db names. Precedence: the conf file's line
# DOLT_BACKUP_EPHEMERAL_DBS=... > the environment > the default ("hq"). A line with an EMPTY
# value turns the mode off for every db (kill switch); a conf file that exists but cannot be
# read turns it off too (doubt keeps the old behaviour: the staging stays). Conf file:
#   $GC_CITY_PATH/.gc/config/dolt-backup-ephemeral.env   (local, gitignored; override with
#   DOLT_BACKUP_EPHEMERAL_CONF)
# DOLT_BACKUP_EPHEMERAL_DRYRUN=1 — decide and log "WOULD RELEASE", delete nothing (conf line > environment;
# an unreadable conf counts as a dry run). Use it for a first night: the S3 proof still runs, the rm does not.
#
# Caller provides for the release/fingerprint helpers: AWS, BUCKET, BACKUP_ROOT, and (release
# only) dolt-backup-s3-proof.sh already sourced. A `log` function is used when defined, else stderr.
# Bash 3.2-safe (macOS /bin/bash). TEST: bash scripts/dolt-backup-ephemeral-lib.selftest.sh

_EPH_DEFAULT_DBS="hq"
# Command lines that mean "something is writing/reading the staging right now". The nightly's
# OWN name is deliberately absent (the nightly is the caller; its single-instance lock already
# keeps a second copy out), and so is dolt-offline-backup-sync.sh (a sourced library, never a
# process of its own).
_EPH_WRITER_RE="${DOLT_BACKUP_EPHEMERAL_WRITER_RE:-(^|[ /])(mol-dog-backup|dolt-backup-reseed|dolt-backup-swap-repair|dolt-backup-residue-reclaim|dolt-compact-routine)\\.sh( |\$)|dolt( .*)? backup (sync|restore)|DOLT_BACKUP}"

_eph_log() {
  if declare -f log >/dev/null 2>&1; then log "$*"; else echo "[ephemeral] $*" >&2; fi
}

_eph_conf_path() {
  printf '%s' "${DOLT_BACKUP_EPHEMERAL_CONF:-${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}/.gc/config/dolt-backup-ephemeral.env}"
}

# _eph_conf_line <KEY> — prints the value of the LAST "KEY=value" line of the conf file (quotes
# stripped) and returns 0; returns 1 when the file or the line is absent (the caller falls through to
# the environment, then the default); returns 2 when the file exists but cannot be read (the caller
# must treat that as doubt). Never fails the caller's shell: use it as `v="$(...)" || rc=$?`.
_eph_conf_line() {
  local key="$1" f raw
  f="$(_eph_conf_path)"
  [ -e "$f" ] || return 1
  { [ -f "$f" ] && [ -r "$f" ]; } || return 2
  grep -q "^${key}=" "$f" 2>/dev/null || return 1
  raw="$(grep "^${key}=" "$f" 2>/dev/null | tail -1)"
  raw="${raw#"${key}"=}"
  printf '%s' "$raw" | tr -d "\"'"
  return 0
}

# _eph_db_list — prints the ephemeral db names, space-separated (nothing = mode off). Returns
# 0 when the list is trustworthy, 2 when a conf file exists but could not be read (the caller
# must treat that as "off" — and may say so). Names that are not plain identifiers are dropped:
# a db name ends up in a path that gets deleted.
_eph_db_list() {
  local raw="" tok out="" rc=0
  raw="$(_eph_conf_line DOLT_BACKUP_EPHEMERAL_DBS)" || rc=$?
  case "$rc" in
    0) ;;
    1) if [ "${DOLT_BACKUP_EPHEMERAL_DBS+set}" = set ]; then raw="$DOLT_BACKUP_EPHEMERAL_DBS"; else raw="$_EPH_DEFAULT_DBS"; fi ;;
    *) return 2 ;;
  esac
  for tok in $raw; do
    case "$tok" in ''|*[!A-Za-z0-9_]*) continue ;; esac
    out="$out $tok"
  done
  printf '%s' "${out# }"
  return 0
}

# _eph_dryrun — 0 iff the release must only be logged, never performed: DOLT_BACKUP_EPHEMERAL_DRYRUN=1
# in the conf file, else in the environment. A conf that cannot be read counts as a dry run (doubt keeps
# the staging). Anything but a literal 1 is "not a dry run".
_eph_dryrun() {
  local v="" rc=0
  v="$(_eph_conf_line DOLT_BACKUP_EPHEMERAL_DRYRUN)" || rc=$?
  case "$rc" in
    0) ;;
    1) v="${DOLT_BACKUP_EPHEMERAL_DRYRUN:-0}" ;;
    *) return 0 ;;
  esac
  [ "$v" = "1" ]
}

# _eph_is_ephemeral <db> — 0 iff <db> is on the list. An unreadable conf, an empty list and an
# invalid name are all "no".
_eph_is_ephemeral() {
  local db="$1" l tok
  case "$db" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
  l="$(_eph_db_list)" || return 1
  for tok in $l; do [ "$tok" = "$db" ] && return 0; done
  return 1
}

# _eph_mode_summary — one word-ish line for the log: "on(hq)", "off" or "off(conf-unreadable)".
_eph_mode_summary() {
  local l rc=0
  l="$(_eph_db_list)" || rc=$?
  if [ "$rc" -eq 2 ]; then printf 'off(conf-unreadable: %s)' "$(_eph_conf_path)"; return 0; fi
  if [ -z "$l" ]; then printf 'off'; else printf 'on(%s)' "$l"; fi
}

# _eph_release_target <root> <db> — the directory that may be released, or rc 1. Path-safety is
# the same as dolt-gc-maintenance.sh's _gc_release_target: an absolute root literally named
# .dolt-backup, a plain identifier as db, a real directory (never a symlink) whose parent is
# exactly that root, and one that holds a manifest (something that IS a backup copy).
_eph_release_target() {
  local root="$1" db="$2" t
  case "$db" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
  case "$root" in /*) ;; *) return 1 ;; esac
  [ "$(basename "$root")" = ".dolt-backup" ] || return 1
  t="$root/$db"
  [ -d "$t" ] && [ ! -L "$t" ] || return 1
  [ "$(cd "$root" 2>/dev/null && pwd -P)" = "$(cd "$(dirname "$t")" 2>/dev/null && pwd -P)" ] || return 1
  [ -s "$t/manifest" ] || return 1
  printf '%s' "$t"
}

# _eph_drop_empty_staging <db> <dest> — ga-94vxdw. An EMPTY directory is not a staging. For an
# ephemeral db the old nightly made exactly that, every night: its `CALL DOLT_BACKUP('add', …,
# 'file://<dest>')` CREATES <dest> (real Dolt does, even for a name that is already registered — measured on
# 2.3.1), so a staging released on purpose at night N came back, empty, at night N+1 — and every reader
# then took "a directory with no manifest" for a broken backup, not for "no staging, by design"
# (2026-10-02 04:01: "local closure: no manifest … NOT proven", about a dir that had not existed when the
# night began). The loop no longer registers a remote for a staging that is absent; this clears the
# leftovers the old behaviour already made.
# Removes <dest> only if ALL hold: the db is ephemeral; the path is what _eph_release_target demands
# (absolute root literally named .dolt-backup, plain identifier, a real directory — never a symlink —
# directly under that root; here without the manifest, whose absence is the point); and `rmdir`
# succeeds, which it does ONLY for a directory with nothing in it. Anything inside it, an unreadable
# directory, a busy one: rmdir fails and nothing changes. It never uses rm -rf, so it cannot delete data.
# Return codes (three states that must not collapse):
#   0  an empty <dest> was removed;
#   2  nothing to do — <dest> does not exist (and its parent can be searched, so "absent" is not a guess);
#   1  left as it is: not ephemeral, path-safety, or not removable (non-empty / unreadable / busy).
_eph_drop_empty_staging() {
  local db="$1" dest="$2" root t
  _eph_is_ephemeral "$db" || return 1
  case "$db" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
  root="${BACKUP_ROOT:-}"
  case "$root" in /*) ;; *) return 1 ;; esac
  [ "$(basename "$root")" = ".dolt-backup" ] || return 1
  [ -d "$root" ] && [ -x "$root" ] || return 1
  t="$root/$db"
  [ "$dest" = "$t" ] || return 1
  [ -e "$t" ] || [ -L "$t" ] || return 2
  [ -d "$t" ] && [ ! -L "$t" ] || return 1
  [ "$(cd "$root" 2>/dev/null && pwd -P)" = "$(cd "$(dirname "$t")" 2>/dev/null && pwd -P)" ] || return 1
  rmdir "$t" 2>/dev/null || return 1
  _eph_log "$db: ephemeral staging: removed an EMPTY $t — a directory with nothing in it is not a staging; an earlier DOLT_BACKUP add left it behind (ga-94vxdw)"
  return 0
}

# _eph_writer_active — 0 iff a process that writes or reads the staging is running, OR we cannot
# tell (no ps output): only a clean "no such process" (grep rc 1) is "not active".
_eph_writer_active() {
  local procs rc
  procs="$(ps -axo command= 2>/dev/null)"; rc=$?
  { [ "$rc" -eq 0 ] && [ -n "$procs" ]; } || return 0
  printf '%s\n' "$procs" | grep -Eq "$_EPH_WRITER_RE"; rc=$?
  [ "$rc" -eq 1 ] && return 1
  return 0
}

# _eph_release_staging <db> <dest> — free <dest> (the local staging of an ephemeral db) AFTER
# proving S3 holds an identical, restorable copy. Return codes (three states that must not
# collapse):
#   0  released — the directory is gone;
#   2  nothing to release — <dest> does not exist (the S3 state is NOT asserted here);
#   1  NOT released: the db is not ephemeral, the path or manifest is not what it should be,
#      S3 is not proven, the staging changed or got busy while proving, a dry run, or the rm
#      did not complete. Each logs its reason; nothing is deleted on a guess.
# The reason is also left, as one word, in the global _EPH_RELEASE_WHY so a caller can tell the
# benign ones from the ones that need a human without parsing the log:
#   released | absent | not-ephemeral | path-safety | no-proof-lib | writer-active |
#   s3-not-proven | manifest-changed | dryrun | rm-incomplete
# Order: cheap decisions first, the S3 proof (slow, touches aws, may upload) only when the rest
# already says yes, and whatever could have moved during that proof re-checked right before the rm.
_EPH_RELEASE_WHY=""
_eph_release_staging() {
  local db="$1" dest="$2" target fp_before fp_after kb mb
  _EPH_RELEASE_WHY="not-ephemeral"
  _eph_is_ephemeral "$db" || { _eph_log "$db: ephemeral staging: not releasing — $db is not an ephemeral-staging db (mode $(_eph_mode_summary))"; return 1; }
  _EPH_RELEASE_WHY="absent"
  [ -e "$dest" ] || return 2
  _EPH_RELEASE_WHY="path-safety"
  if ! target="$(_eph_release_target "${BACKUP_ROOT:-}" "$db")" || [ "$target" != "$dest" ]; then
    _eph_log "$db: ephemeral staging: not releasing — $dest is not a plain real directory directly under \$BACKUP_ROOT with a manifest (path-safety), nothing deleted"
    return 1
  fi
  _EPH_RELEASE_WHY="no-proof-lib"
  if ! declare -f _s3proof_repair_then_prove >/dev/null 2>&1; then
    _eph_log "$db: ephemeral staging: not releasing — the S3 proof library (dolt-backup-s3-proof.sh) is not loaded"
    return 1
  fi
  _EPH_RELEASE_WHY="writer-active"
  if _eph_writer_active; then
    _eph_log "$db: ephemeral staging: not releasing — a backup writer is running (or the process list could not be read); the next run retries"
    return 1
  fi
  fp_before="$(cksum < "$target/manifest" 2>/dev/null)"
  _eph_log "$db: ephemeral staging: proving S3 holds an identical, restorable copy before releasing $target"
  _EPH_RELEASE_WHY="s3-not-proven"
  if ! _s3proof_repair_then_prove "$target" "$db"; then
    _eph_log "$db: ephemeral staging: REFUSED — S3 is not proven restorable and identical to the local staging; NOTHING deleted (see the proof lines above)"
    return 1
  fi
  # The proof may have taken minutes (it can upload). Anything that changed the staging or
  # started writing to it meanwhile makes the proof stale.
  fp_after="$(cksum < "$target/manifest" 2>/dev/null)"
  if [ -z "$fp_before" ] || [ "$fp_before" != "$fp_after" ]; then
    _EPH_RELEASE_WHY="manifest-changed"
    _eph_log "$db: ephemeral staging: REFUSED — the staging's manifest changed while proving S3 (a writer touched it); the proof is stale, NOTHING deleted"
    return 1
  fi
  if _eph_writer_active; then
    _EPH_RELEASE_WHY="writer-active"
    _eph_log "$db: ephemeral staging: REFUSED — a backup writer started while proving S3; NOTHING deleted"
    return 1
  fi
  kb="$(du -sk "$target" 2>/dev/null | awk '{print $1}')"
  case "${kb:-}" in ''|*[!0-9]*) mb="?" ;; *) mb="$((kb / 1024))" ;; esac
  if _eph_dryrun; then
    _EPH_RELEASE_WHY="dryrun"
    _eph_log "$db: ephemeral staging: DRYRUN — WOULD RELEASE ${mb}MB at $target (S3 proven identical + restorable); nothing deleted"
    return 1
  fi
  _eph_log "$db: ephemeral staging: S3 proven identical + restorable — RELEASING $target (${mb}MB); the next backup rebuilds it from the live store"
  rm -rf -- "$target"
  if [ -e "$target" ]; then
    _EPH_RELEASE_WHY="rm-incomplete"
    _eph_log "$db: ephemeral staging: rm of $target did not complete — left partially removed (no manifest = not a backup); S3 holds the full copy, and the next run's residue handling deletes the rest"
    return 1
  fi
  _EPH_RELEASE_WHY="released"
  _eph_log "$db: ephemeral staging: released ${mb}MB — $db has no local staging by design; its backup is in s3://${BUCKET:-?}/$db/"
  return 0
}

# _eph_fingerprint_py <file> <db> — the JSON reading half of _eph_s3_fingerprint_state, a
# function of its own so the python heredoc is never nested inside a $( ) (bash 3.2 mis-parses
# that). Prints exactly one line; see _eph_s3_fingerprint_state for the words.
_eph_fingerprint_py() {
  python3 - "$@" 2>/dev/null <<'PY'
import json, sys, calendar, time

def to_epoch(s):
    try:
        return calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ"))
    except Exception:
        return None

try:
    d = json.load(open(sys.argv[1]))
    dbs = d["databases"]
    if not isinstance(dbs, dict):
        raise ValueError
except Exception:
    print("unknown")
    sys.exit(0)
e = dbs.get(sys.argv[2])
if e is None:
    print("absent")
    sys.exit(0)
if not isinstance(e, dict):
    print("unknown")
    sys.exit(0)
st = e.get("status")
if st is None or st == "ok":
    ts = e.get("run_utc") if isinstance(e.get("run_utc"), str) else d.get("run_utc")
    ep = to_epoch(ts) if isinstance(ts, str) else None
    print("ok %d" % ep if ep is not None else "unknown")
elif st == "failed":
    ts = e.get("last_ok_run_utc")
    ep = to_epoch(ts) if isinstance(ts, str) else None
    print("failed %d" % ep if ep is not None else "failed unknown")
else:
    print("unknown")
PY
}

# _eph_s3_fingerprint_state <db> — what S3's run fingerprint (_meta/latest.json) says about
# <db>'s backup, as one line, in five states that must never collapse:
#   ok <epoch>        the db's entry is a good backup taken at <epoch>
#   failed <epoch>    last night failed; <epoch> is the last good one
#   failed unknown    last night failed and the last good time is not recorded
#   absent            the file was read and has no entry for <db>
#   unknown           the file could not be fetched or parsed — "could not find out"
# Same reading rules as dolt-s3-backup.sh's _build_run_fingerprint: an entry with no status is a
# legacy ok entry; its time is the entry's own run_utc, else the file's. Always rc 0 — the
# answer is the word; callers must test it, not the exit code.
_eph_s3_fingerprint_state() {
  local db="$1" tmp out
  case "$db" in ''|*[!A-Za-z0-9_]*) echo unknown; return 0 ;; esac
  if [ -z "${AWS:-}" ] || [ -z "${BUCKET:-}" ] || ! command -v python3 >/dev/null 2>&1; then echo unknown; return 0; fi
  tmp="$(mktemp 2>/dev/null)" || { echo unknown; return 0; }
  if ! timeout "${S3PROOF_TIMEOUT:-300}" "$AWS" s3 cp "s3://$BUCKET/_meta/latest.json" "$tmp" --only-show-errors >/dev/null 2>&1; then
    rm -f "$tmp"; echo unknown; return 0
  fi
  out="$(_eph_fingerprint_py "$tmp" "$db")"
  rm -f "$tmp"
  case "$out" in
    "ok "[0-9]*|"failed "[0-9]*|"failed unknown"|absent|unknown) echo "$out" ;;
    *) echo unknown ;;
  esac
  return 0
}

# _eph_epoch_utc <epoch> — "2026-10-01T23:38:00Z" for an epoch (BSD `date -r`, GNU `date -d` as the
# fallback); "epoch <n>" if neither date can format it, "?" if <epoch> is not a number.
_eph_epoch_utc() {
  local ep="$1" out
  case "$ep" in ''|*[!0-9]*) echo "?"; return 0 ;; esac
  out="$(date -u -r "$ep" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
  [ -n "$out" ] || out="$(date -u -d "@$ep" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
  [ -n "$out" ] || out="epoch $ep"
  echo "$out"
}

# _eph_s3_last_backup_text <db> — ga-94vxdw. ONE phrase for a log line: what S3's run fingerprint
# (_eph_s3_fingerprint_state) says about the last backup of <db>. For a night refused for disk with
# the staging absent BY DESIGN the log can no longer point at a local manifest, so it points here —
# the proof that is still valid is the one S3 carries. Five states, each worded for what it IS:
# "could not be read" is the unknown, and it says that it says nothing about the S3 copy — never
# "not proven". Always rc 0.
_eph_s3_last_backup_text() {
  local db="$1" st ep
  st="$(_eph_s3_fingerprint_state "$db")"
  case "$st" in
    "ok "[0-9]*)     ep="${st#ok }"
                     printf "S3's fingerprint (_meta/latest.json) puts the last good backup of %s at %s" "$db" "$(_eph_epoch_utc "$ep")" ;;
    "failed "[0-9]*) ep="${st#failed }"
                     printf "S3's fingerprint (_meta/latest.json) says the last night FAILED for %s; its last good backup was at %s" "$db" "$(_eph_epoch_utc "$ep")" ;;
    "failed unknown") printf "S3's fingerprint (_meta/latest.json) says the last night FAILED for %s and does not record its last good backup" "$db" ;;
    absent)          printf "S3's fingerprint (_meta/latest.json) has no entry for %s" "$db" ;;
    *)               printf "S3's fingerprint (_meta/latest.json) could not be read (unknown — that says nothing about whether the S3 copy restores)" ;;
  esac
  return 0
}
