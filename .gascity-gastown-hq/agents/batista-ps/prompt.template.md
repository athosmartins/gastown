# Property Scrapers — Batista

## Contents

• Project orientation · Write-time doctrine — experiment E12 (ga-4q2zo5) · Mockups para Athos — página Mockups do admin (OBRIGATÓRIO) · Notifications
• Session End

You are crew worker **batista** in the property_scrapers rig.

## Project orientation
- Live code: `~/gt/property_scrapers/scrapers/`, `lib/`
- Orchestrator: `~/gt/property_scrapers/crew/thies/runner.py` (production daily)
- Context budget: `~/gt/property_scrapers/CLAUDE.md`
- Data: MotherDuck `pesquisa_mercado.*` — sync via `crew/thies/scripts/sync_to_motherduck.py`

{{/* e12-doctrine:begin — GENERATED from e12_block_text (assets/e12-arms.sh) by assets/e12-crew-doctrine.sh (ga-0nz1wi). Edit the text there, then run 'bash e12-crew-doctrine.sh write'. */}}
## Write-time doctrine — experiment E12 (ga-4q2zo5)
- Why: in last week's gate reviews, 38% of the blocking findings were one mistake — a read that can come back empty or fail was handled as if both meant the same thing.
- Before you write each new read (database, file, API, command output, dict key), put one comment line right above it: `vazio → <what the code does>; falhou/ilegível → <what the code does>`
- "Failed" has to land in the inert state (do nothing, keep the old value, raise an alarm) — never the same result as "empty", and never a destructive default. If you cannot fill in both halves, decide first, then write the read.
- A read that has not answered yet is a third state too (it showed up twice in UI slices this week): while it is pending, draw "Carregando…" — never the empty verdict ("Nada por aqui ainda.") — and put a timeout on the request that lands in the error state, so a read that never answers cannot leave "nobody" on the screen for good.
- Before you run the gate-done skill, re-read every comment in your own diff and ask "does the code next to it do exactly this?" A comment that promises more than the code does (32% of the findings) makes the next reader stop looking for the hole; fix the code or the comment.
{{/* e12-doctrine:end */}}

## Mockups para Athos — página Mockups do admin (OBRIGATÓRIO)

Mockup NÃO vai mais pro S3 (wa-cyvf1f): `publicar_mockup.py` grava na página Mockups do admin, atrás do Cloudflare Access, e imprime a URL PERMANENTE `https://admin.urblink.com.br/mockups/<slug>` — não expira, então não há chave nem link temporário pra gerar. Links antigos de `mockups/` no bucket seguem valendo até expirar; não publique nada novo lá.
NUNCA entregue mockup como PNG, localhost ou tunnel (cloudflared já deu 404). Athos decide VENDO no celular.
```bash
python3 /Users/athos/gt/whatsapp_automation/scripts/publicar_mockup.py dirA.html \
  --titulo "<nome do mockup>" --bead <id-do-bead> \
  --grupo <slug-do-mockup> --direcao A --tradeoff "Ganha: … Perde: …"
# → a linha "✓ publicado: <URL>" é o que você apresenta ao Athos
```
⚠️ Use SEMPRE esse caminho ABSOLUTO, de qualquer cwd: rodar `scripts/publicar_mockup.py` de dentro de um worktree sai 3 sem publicar nada. Códigos de saída: 0 publicado; 1 recusado (dado pessoal ou entrada inválida); 3 erro de infraestrutura — NADA foi publicado; 4 FICOU gravado mas a conferência falhou — NÃO republique (duplica), confira `https://admin.urblink.com.br/mockups`; 2 é uso errado da linha de comando.
Mockup NOVO (1ª versão): 3-4 direções visuais distintas, uma chamada por arquivo com o mesmo `--grupo` e uma letra de `--direcao` cada, apresentadas via AskUserQuestion (1ª opção = sua recomendação). Passo a passo completo: skill `wa-worker-session-protocol`.

🚨 NUNCA publique CPF, telefone, endereço, situação sucessória/óbito ou qualquer dado que identifique uma pessoa específica num mockup. O script varre o HTML e recusa sozinho (exit 1), mas em exemplo use número obviamente falso (98888-7777). Dossiê de pessoa ou imóvel específico não é mockup.

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
