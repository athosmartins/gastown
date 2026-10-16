#!/bin/bash
# dolt-restore-lab-mbp-side.sh (ga-3kmvyr) — the MBP half of dolt-restore-lab-mbp.sh.
#
# Runs INSIDE an `mbp-run.sh --exec` slot (cwd = the slot scratch dir, ~/gt-remote/exec/<n>) with the stage dir pushed to ./in/lab-in/:
#   manifest.json           row counts AS OF one commit, taken on the mini
#   listing.tsv             the S3 listing the mini streams from: key<TAB>size<TAB>etag, one object per line
#   dolt-restore-lab.sh     the lab
#
# NO AWS CREDENTIAL COMES HERE (Mayor 16/10): the mini reads the backup from S3 with its own credential and streams each object over
# ssh into ./in/lab-src/. The MBP only ever sees bytes. This wrapper prints "[lab-mbp] ready slot=<dir>", waits for the mini to drop
# stream.done (or stream.failed) in the slot, checks that what arrived is EXACTLY the listing (every key, every size, nothing extra:
# a partial copy never reaches the lab), runs the lab on file://, and records — as counts only — that no AWS credential showed up
# in this session (env names, argv, files of the slot).
#
#   dolt-restore-lab-mbp-side.sh --db NAME --dolt-version X.Y.Z --rto-seconds N --src-kb N [--margin-pct N] [--stream-wait-s N]
#
# ./out/ (pulled by the caller): report.json (the lab's), lab.log, evidence.txt — NUMBERS and fixed words only, never a row.
# Exit: the lab's (0 OK, 1 FAIL, 2 UNKNOWN, 3 SLOW); 2 when this wrapper cannot get to the lab (tool, wrong dolt, disk, incomplete copy).
set -uo pipefail

STAGE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLOT="$PWD"; OUT="$SLOT/out"; SRC="$SLOT/in/lab-src"
DB=""; WANT_DOLT=""; RTO=""; SRC_KB=""; MARGIN=400; WAIT_S=10800
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || { echo "[lab-mbp] opcao $1 sem valor"; exit 2; }
  case "$1" in
    --db) DB="$2" ;; --dolt-version) WANT_DOLT="$2" ;; --rto-seconds) RTO="$2" ;; --src-kb) SRC_KB="$2" ;; --margin-pct) MARGIN="$2" ;;
    --stream-wait-s) WAIT_S="$2" ;;
    *) echo "[lab-mbp] opcao desconhecida: $1"; exit 2 ;;
  esac
  shift 2
done
mkdir -p "$OUT" || { echo "[lab-mbp] nao consegui criar $OUT"; exit 2; }
EV="$OUT/evidence.txt"; : > "$EV"
ev() { printf '%s\n' "$*" >> "$EV"; }
say() { printf '[lab-mbp] %s\n' "$*"; }
die() { say "UNKNOWN: $*"; ev "wrapper_refused=$*"; exit 2; }
isnum() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

[ -n "$DB" ] && [ -n "$WANT_DOLT" ] || die "faltou --db ou --dolt-version"
for n in "$RTO" "$SRC_KB" "$MARGIN" "$WAIT_S"; do isnum "$n" && [ "$n" -gt 0 ] || die "--rto-seconds, --src-kb, --margin-pct e --stream-wait-s precisam de inteiro > 0"; done
# the tool the lab installs by hand lives in ~/gt-remote/lab/bin (the exact dolt of the mini); brew's after it
export PATH="$HOME/gt-remote/lab/bin:${LAB_BREW_BIN:-/opt/homebrew/bin}:$PATH"
export DOLT_DISABLE_EVENT_FLUSH=1

# --- tools. ausente → rc 2 with the NAME of what is missing (a restore drill that cannot start is UNKNOWN, never FAIL). No aws here.
for t in dolt python3; do command -v "$t" >/dev/null 2>&1 || die "ferramenta ausente no MBP: $t"; done
TO=$(command -v timeout || command -v gtimeout) || die "ferramenta ausente no MBP: timeout/gtimeout (brew install coreutils)"
# `dolt version` with a throwaway home: the host's ~/.dolt is never created, and the version check cannot hang on the network
PROBE="$SLOT/dolt-probe-home"; mkdir -p "$PROBE"
HAVE_DOLT=$(DOLT_ROOT_PATH="$PROBE" "$TO" 60 dolt version 2>/dev/null | head -1 | awk '{print $3}')
rm -rf "$PROBE"
ev "dolt_version_mbp=${HAVE_DOLT:-?}"; ev "dolt_version_wanted=$WANT_DOLT"
[ -n "$HAVE_DOLT" ] || die "nao consegui ler a versao do dolt do MBP"
[ "$HAVE_DOLT" = "$WANT_DOLT" ] || die "dolt do MBP e $HAVE_DOLT, o do mini e $WANT_DOLT (rode --install-dolt no orquestrador)"

# --- disk free BEFORE anything is streamed (KB): the copy, the restored database and the gc headroom all land on this disk.
# vazio/falhou → "?" and a refusal: a stream that fills the disk of the Athos's notebook is worse than a missed week.
FREE_KB=$(df -Pk "$SLOT" 2>/dev/null | awk 'NR==2{print $4}')
ev "free_kb_before=${FREE_KB:-?}"
isnum "$FREE_KB" || die "nao consegui medir o disco livre do MBP"
NEED_KB=$(( SRC_KB * MARGIN / 100 )); ev "need_kb=$NEED_KB"
[ "$FREE_KB" -ge "$NEED_KB" ] || die "disco insuficiente no MBP (${FREE_KB}KB livres < ${NEED_KB}KB = ${MARGIN}% do backup); nao e falha do backup"

# --- credential hygiene, part 1: the AWS_* variables of THIS session (names only; there must be none). vazio/falhou → "?", never 0.
# (an `env` that fails or prints nothing is "?", not the 0 that `grep -c` would print for an empty input)
if ENVOUT=$(env 2>/dev/null) && [ -n "$ENVOUT" ]; then AWSV=$(printf '%s\n' "$ENVOUT" | cut -d= -f1 | grep -c '^AWS_'); else AWSV="?"; fi
isnum "$AWSV" || AWSV="?"
ev "aws_env_vars=$AWSV"
unset AWS_PROFILE; export AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_CONFIG_FILE=/dev/null

# caffeinate keeps the MBP from idle-sleeping in the middle of a multi-hour stream+restore (a sleep would freeze it and drop the ssh)
command -v caffeinate >/dev/null 2>&1 && { caffeinate -i -s -w $$ >/dev/null 2>&1 & } || ev "caffeinate=ausente"

# --- the handshake. The caller reads the slot path from this line and starts the stream; it ends with stream.done / stream.failed.
mkdir -p "$SRC" || die "nao consegui criar $SRC"
say "ready slot=$SLOT"
DEADLINE=$(( $(date +%s) + WAIT_S ))
while [ ! -e "$SLOT/stream.done" ]; do
  [ ! -e "$SLOT/stream.failed" ] || die "o mini nao conseguiu terminar o envio dos objetos (stream.failed)"
  [ "$(date +%s)" -lt "$DEADLINE" ] || die "o mini nao terminou o envio em ${WAIT_S}s"
  sleep "${LAB_POLL_S:-2}"
done

# --- what arrived must be EXACTLY the listing: every key present, same size, no extra file. (The mini already checked size and etag
# of each object on the way out; this reads the disk of THIS machine.) falhou/ilegível → UNKNOWN.
CHK=$(python3 -I - "$STAGE/listing.tsv" "$SRC" "$DB/" <<'PY'
import os, sys
lst, root, pre = sys.argv[1:4]
want = {}
for ln in open(lst):
    k, s, _ = ln.rstrip("\n").split("\t")
    if k.endswith("/"): continue
    assert k.startswith(pre); want[k[len(pre):]] = int(s)
have = {}
for d, _, fs in os.walk(root):
    for f in fs:
        p = os.path.join(d, f); have[os.path.relpath(p, root)] = os.lstat(p).st_size
miss = sorted(set(want) - set(have)); extra = sorted(set(have) - set(want)); bad = sorted(k for k in want if k in have and want[k] != have[k])
if miss or extra or bad:
    print("faltam=%d sobram=%d tamanho-diferente=%d (primeiro: %s)" % (len(miss), len(extra), len(bad), (miss + extra + bad)[0])); sys.exit(1)
print("objetos=%d bytes=%d" % (len(want), sum(want.values())))
PY
) || die "a copia no MBP nao e a lista do S3: ${CHK:-listing.tsv ilegivel}"
ev "copia_conferida=$CHK"; say "copia conferida ($CHK)"

# --- credential hygiene, part 2: a sample of `ps` every 10 s counting command lines that LOOK like an AWS credential. The pattern uses
# [A]-style brackets so the grep's own command line does not match itself. Counts only.
SHAPE='[A]KIA[0-9A-Z]{16}|[A]SIA[0-9A-Z]{16}|[A]WS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY|SESSION_TOKEN)=|[a]ws_(access_key_id|secret_access_key|session_token)'
sample() { local p; if p=$(ps -axww -o command= 2>/dev/null) && [ -n "$p" ]; then printf '%s\n' "$p" | grep -c -E "$SHAPE"; else echo "?"; fi; }
SAMPLES="$OUT/.argv-samples"; : > "$SAMPLES"
( while :; do sample >> "$SAMPLES"; sleep "${LAB_SAMPLE_S:-10}"; done ) &
SAMPLER=$!

# --- the lab, on the local copy. The copy is already on disk, so the lab's own gate needs margin - 100%.
export LAB_DISK_MARGIN_PCT=$(( MARGIN > 100 ? MARGIN - 100 : 1 )) LAB_RESTORE_TIMEOUT=7200 LAB_SQL_TIMEOUT=900
bash "$STAGE/dolt-restore-lab.sh" run --db "$DB" --source "file://$SRC" --manifest "$STAGE/manifest.json" \
  --workdir "$SLOT/work" --report "$OUT/report.json" --rto-seconds "$RTO" 2>&1 | tee "$OUT/lab.log"
LABRC=${PIPESTATUS[0]}

# --- hygiene evidence. vazio (no sample taken) → "?", never 0; falhou (grep could not scan) → "?". `lab-src` (the backup) and the shell
# scripts (which name the variables in comments) are not scanned; `work` is the lab's own scratch.
sample >> "$SAMPLES"; kill "$SAMPLER" 2>/dev/null; wait "$SAMPLER" 2>/dev/null
# a sample that could not read `ps` is a "?" line: it is not counted as a clean sample; no clean sample at all → hits "?"
NS=$(grep -c '^[0-9]' "$SAMPLES" 2>/dev/null); NH=$(awk '/^[0-9]+$/ { s += $1 } END { print s + 0 }' "$SAMPLES" 2>/dev/null); NQ=$(grep -c '^?' "$SAMPLES" 2>/dev/null)
[ "${NS:-0}" -gt 0 ] 2>/dev/null && ev "argv_samples=$NS argv_hits=$NH argv_samples_falhas=${NQ:-0}" || ev "argv_samples=0 argv_hits=? argv_samples_falhas=${NQ:-?}"
rm -f "$SAMPLES"
HITS=$(grep -rIlE --exclude='*.sh' --exclude-dir=lab-src "$SHAPE" "$SLOT/in" "$SLOT/out" 2>/dev/null); GST=$?
case "$GST" in 0) ev "slot_files_with_credential=$(printf '%s\n' "$HITS" | grep -c .)" ;; 1) ev "slot_files_with_credential=0" ;; *) ev "slot_files_with_credential=?" ;; esac
ev "lab_rc=$LABRC"
exit "$LABRC"
