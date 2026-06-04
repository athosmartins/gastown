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

## Notifications
```bash
notify 'Work complete: <description>'
notify -t 'Title' -p 4 'High priority'
```

## Session End

**Mid-session handoff (WIP):** `gc handoff` — auto-commit + push branch + handoff

**Trabalho concluído — use `gate-done` (NUNCA `gt mq submit` / `mr`):**

O humano NUNCA mergeia aqui. O gate (G) faz o merge direto. `mr` bloquearia para sempre.

Fluxo de conclusão:
1. Commitar tudo na branch de trabalho e fazer push: `git push origin HEAD`
2. Rodar `/gate-done` para criar o marker no city DB
3. O launchd guard detecta o marker em ~2 min, despacha 3 revisores independentes e mergeia direto em main.
4. Você receberá mail quando o gate passar ou falhar.

`mr`/PR está PROIBIDO neste city. O gate é o único caminho para produção.
