#!/usr/bin/env bash
# prod-tests/whatsapp_automation/story-ga-7kz2k.sh
#
# Story-specific prod test for ga-7kz2k — "ari_media DTMF tone duration +
# per-leg spool recording helper". Invoked by run.sh when STORY_ID=ga-7kz2k.
#
# WHAT THIS PROVES (and what it deliberately does NOT):
#
#   PROVES — the code actually DEPLOYED to the runtime carries both fixes. This
#   is the whole point: the unit tests already ran green on the branch, so the
#   only thing left worth asserting after a deploy is that the deploy carried
#   them. "Merged" and "live" are different facts.
#     1. AriMedia.send_dtmf defaults to a tone >= 180ms. A 100ms tone was being
#        discarded upstream of the IVR, so digits never registered.
#     2. AriMedia.record_leg records a SNOOP with spy=both (both sides audible),
#        not the raw leg (one direction only).
#     3. Recording names stay inside the Asterisk recording spool — a name that
#        starts with "~" or "/" is never expanded by Asterisk and the recording
#        is lost silently. That was the ~/voicebot-rec failure.
#
#   DOES NOT PROVE — that a real carrier latches onto the tones, or that a wav
#   lands on disk with audio in it. Both story criteria are worded around a LIVE
#   call (--target, RECORD=1) and no automated post-deploy check can place one.
#   Those stay human-verified; this script exists so a deploy that silently
#   dropped the change cannot masquerade as one that shipped it.
#
# No ARI, no network, no live call: a fake requests-session captures the REST
# params, so this is safe to run on every delivery.

set -uo pipefail

WA_ROOT="${WA_ROOT:-/Users/athos/gt/whatsapp_automation}"

log()  { echo "[prod-test:ga-7kz2k] $*"; }
fail() { echo "[prod-test:ga-7kz2k] FAIL: $*" >&2; exit 1; }

ARI_SRC="$WA_ROOT/lib/predictive_dialer/voicebot/ari_media.py"
[ -f "$ARI_SRC" ] || fail "ari_media.py not found at $ARI_SRC — wrong WA_ROOT or deploy incomplete?"

log "asserting deployed $ARI_SRC ..."

WA_ROOT="$WA_ROOT" python3 - <<'PY' || fail "deployed ari_media.py does not carry the ga-7kz2k fixes (see assertion above)"
import os, sys

sys.path.insert(0, os.environ["WA_ROOT"])
from lib.predictive_dialer.voicebot.ari_media import AriMedia


class FakeResp:
    def __init__(self, payload): self._p = payload
    def raise_for_status(self): pass
    def json(self): return self._p


class FakeSession:
    def __init__(self, payload):
        self.auth = None
        self.calls = []
        self._payload = payload

    def request(self, method, url, params=None, timeout=None):
        self.calls.append((method, url, params or {}))
        return FakeResp(self._payload)


def ari(session):
    return AriMedia("http://127.0.0.1:8088", "pixdialer", "pw",
                    app="pix-voicebot", session=session)


# 1. DTMF default tone duration
s = FakeSession({"id": "ch-1"})
ari(s).send_dtmf("ch-1", "1")
duration = int(s.calls[-1][2]["duration"])
assert duration >= 180, f"deployed send_dtmf default duration is {duration}ms, expected >= 180ms"
print(f"  [1/3] send_dtmf default duration = {duration}ms (>= 180) OK")

# 2. record_leg snoops BOTH directions and records the snoop, not the raw leg
s = FakeSession({"id": "snoop-1"})
rec = ari(s).record_leg("ch-call", "voicebot-1730000000")
snoop_method, snoop_url, snoop_params = s.calls[0]
assert snoop_url.endswith("/ari/channels/ch-call/snoop"), f"expected a snoop on the leg, got {snoop_url}"
assert snoop_params.get("spy") == "both", f"snoop spy={snoop_params.get('spy')!r}, expected 'both' (one direction is half-deaf audio)"
rec_url = s.calls[-1][1]
assert rec_url.endswith("/ari/channels/snoop-1/record"), f"recording the raw leg ({rec_url}) captures one direction only"
print("  [2/3] record_leg snoops spy=both and records the snoop OK")

# 3. Recording name cannot escape the Asterisk recording spool
s = FakeSession({"id": "snoop-1"})
name = ari(s).record_leg("ch-call", "~/voicebot-rec/call").name
assert not name.startswith("~"), f"recording name {name!r} starts with '~' — Asterisk will not expand it"
assert not name.startswith("/"), f"recording name {name!r} is absolute — ARI names are spool-relative"
assert ".." not in name, f"recording name {name!r} can escape the spool dir"
print(f"  [3/3] spool-relative recording name = {name!r} OK")
PY

log "story-ga-7kz2k PASS — deployed ari_media carries both fixes"
