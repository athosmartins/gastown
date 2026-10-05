#!/bin/bash
# token-ledger-harvest.sh — ga-5c3msy (E8 of P0 ga-ufskhy): keep the tokens-per-bead LEDGER filling itself.
#
# WHY. The metric the town optimises is tokens per APPROVED bead, and the only per-session record of tokens is the Claude
# transcript. transcript-reaper.sh deletes a DEAD session's transcript 24h after its last write (ga-t1ub9/ga-5ppqo), so
# without a standing harvest the history evaporates and every A/B reads "no data" a day later. bead-token-meter.py
# `harvest` copies the per-session numbers into $GC_CITY_PATH/.gc/token-ledger/sessions.jsonl (idempotent, incremental,
# single-instance flock inside the tool). Run every 30 min by orders/token-ledger-harvest.toml — comfortably inside the
# reaper's 24h window, comfortably outside one run (first full scan of 1.8k transcripts: ~10 s; incremental: ~1 s).
# A gap is only PARTLY recoverable: `bead-token-meter.py backfill-s3 --since <day>` restores the top-level transcripts from the
# permanent S3 archive, but not the nested objects (subagents, tool results) — its own output says the restored spend is
# UNDERESTIMATED. A harvest that quietly stops is the failure to prevent, which is why the exit codes below reach the order runner.
#
# This wrapper only adds what an order needs around the tool: a sane PATH (orders do not run in a login shell), low
# priority (the box saturates: load 47 measured), one log line per run with rc and duration — "is the harvest alive and how
# long does it take" is one tail away — and the tool's exit code, UNCHANGED, to the order runner:
#   0  harvested (or another harvest holds the ledger lock: nothing to do — the log line says "outra colheita em curso")
#   5  the transcript FORMAT looks changed (sessions read, 0 responses); the ledger was written
#   6  something could not be READ: root missing / unreadable / empty, project unreadable, or a transcript that exists but will not
#      open (only ENOENT counts as "vanished"). Whatever WAS readable is still harvested and the ledger is written — nothing already
#      in it is lost. "Nothing to harvest" is not something the tool can know in that case, so it never exits 0 for it.
#   7  the ledger lock could not be TAKEN for a reason that is not contention (ENOLCK, EBADF, EIO...): nothing was done. Only
#      EWOULDBLOCK/EAGAIN means "another harvest holds it" (that is the rc 0 line above); anything else used to read the same
#      and the harvest then never ran, silently.
#   else  the tool crashed
# The alarm text is the FIRST line of the tool's output, so the 500-char cut of the log line below never throws it away.
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="${TOKEN_LEDGER_TOOL:-$HERE/../bead-token-meter.py}"
LOG="${TOKEN_LEDGER_LOG:-$CITY/.gc/logs/token-ledger-harvest.log}"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

t0="$(date +%s)"
out="$(nice -n 15 python3 "$TOOL" harvest 2>&1)"; rc=$?
secs=$(( $(date +%s) - t0 ))
printf '%s rc=%s secs=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" "$secs" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-500)" >> "$LOG" 2>/dev/null || true
if [ "$rc" -ne 0 ]; then
  echo "token-ledger-harvest: harvest failed rc=$rc: $out" >&2
fi
exit "$rc"
