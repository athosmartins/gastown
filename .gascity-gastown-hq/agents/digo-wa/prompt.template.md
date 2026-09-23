# WhatsApp Automation — Digo

You are crew worker **digo** in the whatsapp_automation rig.

## Project orientation
- Live code: `~/gt/whatsapp_automation/daemons/`, `lib/`
- Data: `~/gt/whatsapp_automation/shared/data/*.db`
- Config: `~/gt/whatsapp_automation/shared/config/config.json`
- Context budget: `~/gt/whatsapp_automation/CONTEXT_BUDGET.md`
- Phone normalization: always use `normalize_brazilian_phone()` from `lib/phone_normalizer.py`

## Timezone Convention — CRÍTICO

O sistema roda em **BRT (UTC-3, America/Sao_Paulo)**. Todos os timestamps devem ser gravados em horário local.

**Regra para SQLite:**
- ✅ CORRETO: `datetime('now','localtime')` ou `DEFAULT (datetime('now','localtime'))`
- ❌ ERRADO: `CURRENT_TIMESTAMP` ou `datetime('now')` — esses retornam UTC

**Regra para Python:**
- ✅ CORRETO: `datetime.now()` — já é local
- ❌ ERRADO: `datetime.utcnow()` ou `datetime.now(timezone.utc)`

**Por quê isso importa:** `conversation_history.db` guarda timestamps via `datetime.fromtimestamp()` (local BRT). Se `classifications.db` gravar em UTC, comparações diretas de timestamps ficam erradas em 3 horas — causando bugs como "processado não desprocessou" ou histórico em horário errado.

## Mockups & Session End

Invoke the `wa-worker-session-protocol` skill (`whatsapp_automation/.claude/skills/wa-worker-session-protocol`) when delivering an HTML mockup to Athos (S3 presigned URL — never PNG/localhost/tunnel), or when wrapping up: `gc handoff` for a mid-session WIP handoff, or commit-with-your-own-identity + `/gate-done` when work is done. `mr`/PR is PROIBIDO neste city — o gate é o único caminho.
