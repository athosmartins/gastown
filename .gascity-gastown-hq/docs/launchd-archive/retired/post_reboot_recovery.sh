#!/bin/bash
# Post-reboot recovery after the 2026-07-10 disk-full incident (reclaims 32GB
# stale swap via reboot). Auto-runs ONCE at the first login after the 2 AM reboot
# (via com.athos.post-reboot-recovery LaunchAgent), then self-removes.
# Safe/non-interactive steps only. Chrome CDP + Mayor are left to Athos (see notes).
set -uo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
LOG=/tmp/post_reboot_recovery.log
{
  echo "=== post-reboot recovery $(date) ==="

  echo "--- disk (expect ~86% used after swap reclaim) ---"
  df -h /System/Volumes/Data | awk 'NR==2{print $4" free ("$5")"}'
  echo "--- swap (expect small again) ---"
  sysctl vm.swapusage 2>/dev/null

  echo "--- scraper daily armed? (LaunchAgents auto-load at login) ---"
  if launchctl list 2>/dev/null | grep -q 'com.scrapers.daily$'; then
    echo "daily: loaded OK"
  else
    launchctl load "$HOME/Library/LaunchAgents/com.scrapers.daily.plist" 2>/dev/null && echo "daily: reloaded"
    launchctl load "$HOME/Library/LaunchAgents/com.scrapers.daily-catchup.plist" 2>/dev/null && echo "catchup: reloaded"
  fi

  echo "--- Dolt health ---"
  gc dolt status 2>&1 | head -4 || echo "gc dolt status unavailable"

  echo "--- pre-download bge-m3 for lexbh v_pipeline (needs the freed disk) ---"
  LEXBH_PY="$HOME/.lexbh/.venv/bin/python"
  if [ -x "$LEXBH_PY" ]; then
    "$LEXBH_PY" - <<'PY' 2>&1 | tail -3
try:
    from sentence_transformers import SentenceTransformer
    SentenceTransformer("BAAI/bge-m3", device="cpu")
    print("bge-m3: cached OK — v_pipeline chunk_index unblocked")
except Exception as e:
    print(f"bge-m3 download FAILED: {e}")
PY
  else
    echo "lexbh venv not found — skipping bge-m3"
  fi

  echo "=== NOT auto-started (Athos's call) ==="
  echo "  Chrome CDP:  ~/launch-chrome-cdp.sh"
  echo "  Mayor tmux:  see the hq-mayor block in ~/.claude/CLAUDE.md (NODE_OPTIONS workaround)"
  echo "=== done. Ping Batista (property_scrapers) to validate v_pipeline + daily ==="
} >"$LOG" 2>&1

# notify Athos with a one-line summary
FREE=$(df -h /System/Volumes/Data | awk 'NR==2{print $4}')
command -v notify >/dev/null 2>&1 && notify -t 'Post-reboot recovery' \
  "Disco livre: ${FREE}. Daily re-armado, bge-m3 cacheado. Falta subir Chrome CDP + Mayor (manual). Log: $LOG"

# self-remove (one-shot): boot out + delete the LaunchAgent and this script
launchctl bootout "gui/$(id -u)/com.athos.post-reboot-recovery" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/com.athos.post-reboot-recovery.plist"
rm -f "$HOME/.property-scrapers/post_reboot_recovery.sh"
