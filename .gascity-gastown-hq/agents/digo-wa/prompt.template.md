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

## Mockups para Athos — S3 presigned URL (OBRIGATÓRIO)

⚠️ `mockups/` NÃO é mais anônimo-legível, e o `presign` é hoje o que TE DÁ acesso — a redação anterior aqui dizia o oposto ("presign é decorativo, não protege nem expira"), verdadeira em 25/07 e FALSA desde 31/07. A policy do bucket tem o Sid `DenyAnonymousReadOnBackupsDraftsAndMockups`, um Deny de `s3:GetObject` para `Principal:*` em `mockups/*` (idem `backups/*`, `estudos/*`, `discador-mockups/*`, `pending_drafts.json`), cuja Condition exclui `aws:PrincipalAccount: 549710416969`. Como a URL presigned assina COM a conta, o Deny não se aplica a ela — medido: sem assinatura 403, presigned 200 (wa-hvh10 + wa-ge8bs; verificação de thies-wa em 08/08, conferida contra a policy viva). ⚠️ O resto do bucket segue público por `PublicReadAccess`, e a distro CloudFront não passa pela assinatura — então isto vale para os prefixos negados acima, não para o bucket inteiro. Continue usando chave de alta entropia: ela não é mais a única barreira, mas ainda é uma.
NUNCA entregue mockup como PNG, localhost ou tunnel (cloudflared já deu 404). Athos decide VENDO no celular.
```bash
python3 -c "import secrets; print(secrets.token_hex(8))"  # chave de alta entropia
aws s3 cp <arquivo.html> s3://whatsapp-viewer-549710416969/mockups/<nome>-<hex>.html --content-type "text/html; charset=utf-8"
aws s3 presign s3://whatsapp-viewer-549710416969/mockups/<nome>-<hex>.html --expires-in 604800
# → envie esse URL ao Athos
```

🚨 NUNCA suba CPF, telefone, endereço, situação sucessória/óbito ou qualquer dado que identifique uma pessoa específica nesse bucket — o link é público pra sempre.

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
1. Commitar tudo na branch de trabalho com SUA PRÓPRIA identidade — NUNCA
   `git commit` puro, que herda `athosmartins` do `~/.gitconfig` global e
   torna a autoria não-citável (ga-qpsen):
   ```bash
   git -c user.name="$GC_ALIAS" -c user.email="${GC_ALIAS}@gascity.local" commit -m "<type>(<bead>): <descrição>"
   git push origin HEAD
   ```
2. Rodar `/gate-done` para criar o marker no city DB
3. O launchd guard detecta o marker em ~2 min, despacha 3 revisores independentes e mergeia direto em main.
4. Você receberá mail quando o gate passar ou falhar.

`mr`/PR está PROIBIDO neste city. O gate é o único caminho para produção.
