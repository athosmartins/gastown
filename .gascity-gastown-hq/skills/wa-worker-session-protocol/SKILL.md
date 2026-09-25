---
name: wa-worker-session-protocol
description: Use this when you (a crew worker in whatsapp_automation — batista, mila, oracle, thies, digo, peter, or a wa-worker pool session) need to deliver an HTML mockup to Athos for review, OR when you're wrapping up work and ending a session (mid-session handoff, or work fully done and ready for the quality gate). Covers the S3 presigned-URL mockup delivery procedure and the commit-identity + gate-done completion flow.
---

# wa-worker session protocol — mockups + session end

## Mockups para Athos — S3 presigned URL + 3-4 direções (OBRIGATÓRIO)

⚠️ `mockups/` NÃO é mais anônimo-legível, e o `presign` é hoje o que TE DÁ acesso — a redação anterior aqui dizia o oposto ("presign é decorativo, não protege nem expira"), verdadeira em 25/07 e FALSA desde 31/07. A policy do bucket tem o Sid `DenyAnonymousReadOnBackupsDraftsAndMockups`, um Deny de `s3:GetObject` para `Principal:*` em `mockups/*` (idem `backups/*`, `estudos/*`, `discador-mockups/*`, `pending_drafts.json`), cuja Condition exclui `aws:PrincipalAccount: 549710416969`. Como a URL presigned assina COM a conta, o Deny não se aplica a ela — medido: sem assinatura 403, presigned 200 (wa-hvh10 + wa-ge8bs; verificação de thies-wa em 08/08, conferida contra a policy viva). ⚠️ O resto do bucket segue público por `PublicReadAccess`, e a distro CloudFront não passa pela assinatura — então isto vale para os prefixos negados acima, não para o bucket inteiro. Continue usando chave de alta entropia: ela não é mais a única barreira, mas ainda é uma.

NUNCA entregue mockup como PNG, localhost ou tunnel (cloudflared já deu 404). Athos decide VENDO no celular.

**Mockup NOVO (1ª versão): gere 3-4 direções visuais distintas antes de
construir a definitiva** — paleta/tipografia/densidade diferentes, cada uma
com 1 frase de tradeoff, nomeando no prompt de geração os padrões de "visual
padrão de IA" a evitar (gradiente genérico, cards idênticos em grade, emoji
como ícone — guia mais fundo: skill `frontend-design`). Publique as 3-4,
uma chave por arquivo, e apresente via **AskUserQuestion** (1ª opção = sua
recomendação, nunca links soltos pedindo escolha em texto livre). Protocolo
completo, com o passo a passo numerado: `whatsapp_automation/CLAUDE.md` →
"Mockups de UI/UX — protocolo obrigatório" (ga-g7x0si). Ajuste incremental
num mockup já aprovado NÃO repete as 3-4 direções — publique só a versão
atualizada.

```bash
python3 -c "import secrets; print(secrets.token_hex(8))"  # uma chave por direção
aws s3 cp <dirN.html> s3://whatsapp-viewer-549710416969/mockups/<nome>-dirN-<hex>.html --content-type "text/html; charset=utf-8"
aws s3 presign s3://whatsapp-viewer-549710416969/mockups/<nome>-dirN-<hex>.html --expires-in 604800
# → uma opção por direção no AskUserQuestion, não um envio solto
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
2. Rodar `/gate-done` para criar o marker no city DB (veja a skill `gate-done` pro fluxo completo — self-audit, verificação de push, criação do marker)
3. O launchd guard detecta o marker em ~2 min, despacha 3 revisores independentes e mergeia direto em main.
4. Você receberá mail quando o gate passar ou falhar.

`mr`/PR está PROIBIDO neste city. O gate é o único caminho para produção.
