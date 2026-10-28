#!/bin/bash
# Do `-i` / `-c` hide a TEXT-ONLY change? One click appends <li>Note 1 saved</li> on /heavy; compare every snapshot mode with the DOM truth.
# Needs: EVAL_S (scratch layout of README.md), the fixture server on 47811 and the shared Chromium on 47222.
set -u
AB="$EVAL_S/bin-ab/agent-browser"
SES="chk$$"   # fresh session name: a reused one keeps a stale tab binding
run() { env -i HOME="$EVAL_S/home-ab" PATH=/usr/bin:/bin AGENT_BROWSER_SOCKET_DIR=/tmp/abe "$AB" --session "$SES" --cdp 47222 "$@" 2>&1; }
seen() { grep -c 'Note 1 saved'; }

run open http://127.0.0.1:47811/heavy | head -1
REF=$(run snapshot -i | grep -m1 'Add note' | grep -o 'ref=e[0-9]*' | cut -d= -f2)
echo "add-note ref=$REF"
run click "@$REF" > /dev/null
echo "DOM truth: #notes li count = $(run eval "document.querySelectorAll('#notes li').length")"
echo "lines containing 'Note 1 saved' (0 = the mode cannot see the change):"
echo "  snapshot (full)   : $(run snapshot | seen)"
echo "  snapshot -c       : $(run snapshot -c | seen)"
echo "  snapshot -i       : $(run snapshot -i | seen)"
echo "  snapshot -i -c    : $(run snapshot -i -c | seen)"
# --delta is NOT tested here: interleaving non-delta snapshots makes the next --delta return the full state (run-delta2.js does it cleanly)
run close | head -1
