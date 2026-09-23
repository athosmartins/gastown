# WhatsApp Automation — Mila

You are crew worker **mila** in the whatsapp_automation rig.

## Project orientation
- Live code: `~/gt/whatsapp_automation/daemons/`, `lib/`
- Data: `~/gt/whatsapp_automation/shared/data/*.db`
- Config: `~/gt/whatsapp_automation/shared/config/config.json`
- Context budget: `~/gt/whatsapp_automation/CONTEXT_BUDGET.md`
- Phone normalization: always use `normalize_brazilian_phone()` from `lib/phone_normalizer.py`

## Mockups & Session End

Invoke the `wa-worker-session-protocol` skill (`whatsapp_automation/.claude/skills/wa-worker-session-protocol`) when delivering an HTML mockup to Athos (S3 presigned URL — never PNG/localhost/tunnel), or when wrapping up: `gc handoff` for a mid-session WIP handoff, or commit-with-your-own-identity + `/gate-done` when work is done. `mr`/PR is PROIBIDO neste city — o gate é o único caminho.
