---
name: wa-worker-session-protocol
description: Use this when you (a crew worker in whatsapp_automation — batista, mila, oracle, thies, digo, peter, or a wa-worker pool session) need to deliver an HTML mockup to Athos for review, OR when you're wrapping up work and ending a session (mid-session handoff, or work fully done and ready for the quality gate). Covers the mockup publishing procedure (admin Mockups page, permanent URL) and the commit-identity + gate-done completion flow.
---

# wa-worker session protocol — mockups + session end

## Mockups para Athos — publicar na página Mockups do admin + 3-4 direções (OBRIGATÓRIO)

Mockup NÃO vai mais pro S3 (wa-cyvf1f): `publicar_mockup.py` grava na página Mockups do admin, atrás do Cloudflare Access, e imprime a URL PERMANENTE `https://admin.urblink.com.br/mockups/<slug>` — não expira, então não há chave nem link temporário pra gerar. (Links antigos de `mockups/` no bucket S3 seguem valendo até expirar; não publique mais nada novo lá.)

NUNCA entregue mockup como PNG, localhost ou tunnel (cloudflared já deu 404). Athos decide VENDO no celular.

**Mockup NOVO (1ª versão): gere 3-4 direções visuais distintas antes de
construir a definitiva** — paleta/tipografia/densidade diferentes, cada uma
com 1 frase de tradeoff, nomeando no prompt de geração os padrões de "visual
padrão de IA" a evitar (gradiente genérico, cards idênticos em grade, emoji
como ícone — guia mais fundo: skill `frontend-design`). Publique as 3-4 — uma
chamada por arquivo, mesmo `--grupo`, uma letra de `--direcao` cada — e
apresente via **AskUserQuestion** (1ª opção = sua recomendação, nunca links
soltos pedindo escolha em texto livre). Protocolo completo, com o passo a
passo numerado: `whatsapp_automation/CLAUDE.md` → "Mockups de UI/UX —
protocolo obrigatório" (ga-g7x0si). Ajuste incremental num mockup já aprovado
NÃO repete as 3-4 direções — publique só a versão atualizada, com o mesmo
`--grupo` e `--direcao v2` (depois `v3`…).

```bash
python3 /Users/athos/gt/whatsapp_automation/scripts/publicar_mockup.py dirA.html \
  --titulo "<nome do mockup>" --bead <id-do-bead> \
  --grupo <slug-do-mockup> --direcao A --tradeoff "Ganha: … Perde: …"
# → a linha "✓ publicado: <URL>" vira uma opção por direção no AskUserQuestion, não um envio solto
```

⚠️ Use SEMPRE esse caminho ABSOLUTO, de qualquer cwd: rodar `scripts/publicar_mockup.py` de dentro de um worktree sai 3 sem publicar nada (`shared/data` é gitignored no whatsapp_automation e o worktree de worker não o tem). Códigos de saída: 0 publicado; 1 recusado (dado pessoal ou entrada inválida); 3 erro de infraestrutura — NADA foi publicado; 4 FICOU gravado mas a conferência falhou — NÃO republique (duplica), confira `https://admin.urblink.com.br/mockups`; 2 é uso errado da linha de comando. O HTML roda isolado no admin: `localStorage`/`sessionStorage`/cookie falham lá — proteja com try/catch (o script avisa).

🚨 NUNCA publique CPF, telefone, endereço, situação sucessória/óbito ou qualquer dado que identifique uma pessoa específica num mockup. O script varre o HTML e recusa sozinho (exit 1), mas em exemplo use número obviamente falso (98888-7777). Dossiê de pessoa ou imóvel específico não é mockup: o lugar é `shared/data/estudos` (também no admin, atrás do Cloudflare Access).

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
2. Rodar `/gate-done` para criar o marker no city DB (veja a skill `gate-done` pro fluxo completo — self-audit, verificação de push, criação do marker). `/gate-done` é um SLASH COMMAND nativo (`commands/gate-done.md`), materializado na sua própria sessão — NÃO é um script em disco. Nunca rode `find`/`ls -R` tentando localizá-lo: se `/gate-done` não aparecer disponível, isso é sinal de que a sessão não tem o command materializado (bug a reportar, não um arquivo a caçar) — ver ga-awsf9k, uma sessão wisp que tentou `find / -maxdepth 6 -iname gate-done*` a partir da raiz.
   Dentro do `/gate-done` há o **Step 2b (pré-revisão, experimento A/B ga-gnr3tw)**: para METADE das beads (função fixa do id da bead — você não escolhe) ele roda o prompt do próprio revisor do gate no SEU diff antes de gastar um ciclo de gate; nas demais imprime `SKIPPED … control-arm` e segue. Rode-o em background (leva minutos), leia o veredito: `FAIL` = conserte o que for real (a CLASSE, varrendo o diff todo), commite e rode `/gate-done` de novo (máx. 3 vezes por bead); `INCONCLUSIVE` = não é veredito, siga para o Step 3 e registre o motivo. Não use `--force` para "ver em que braço está".
3. O launchd guard detecta o marker em ~2 min, despacha 3 revisores independentes e mergeia direto em main.
4. Você receberá mail quando o gate passar ou falhar.

`mr`/PR está PROIBIDO neste city. O gate é o único caminho para produção.
