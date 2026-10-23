---
name: wa-worker-session-protocol
description: Use this when you (a crew worker in whatsapp_automation — batista, mila, oracle, thies, digo, peter, or a wa-worker pool session) need to deliver an HTML mockup to Athos for review, OR when you're wrapping up work and ending a session (mid-session handoff, or work fully done and ready for the quality gate). Covers the mockup publishing procedure (admin Mockups page, permanent URL, one card per theme with the options as tabs) and the commit-identity + gate-done completion flow.
---

# wa-worker session protocol — mockups + session end

## Contents

• Mockups para Athos — publicar na página Mockups do admin + 3-4 direções (OBRIGATÓRIO)
• Notifications · Session End

## Mockups para Athos — publicar na página Mockups do admin + 3-4 direções (OBRIGATÓRIO)

Mockup NÃO vai mais pro S3 (wa-cyvf1f): `publicar_mockup.py` grava na página Mockups do admin, atrás do Cloudflare Access, e imprime a URL PERMANENTE `https://admin.urblink.com.br/mockups/<slug>` — não expira, então não há chave nem link temporário pra gerar. (Links antigos de `mockups/` no bucket S3 seguem valendo até expirar; não publique mais nada novo lá.)

NUNCA entregue mockup como PNG, localhost ou tunnel (cloudflared já deu 404). Athos decide VENDO no celular — o entregável É a URL permanente do admin (a do GRUPO, abaixo).

🗂️ **1 tema = 1 grupo = 1 card (Athos, 04/10, wa-b0zjk4).** Cada card da página Mockups é um TEMA (ex.: "Associar demanda"); ao abrir o card (`/mockups/g/<grupo>`) o Athos vê uma barra de ABAS — A, B, C, v2, 2v2… — e o mockup troca ali mesmo. O `--grupo` escolhe o CARD, a `--direcao` escolhe a ABA. Daí duas regras, e as duas já foram violadas na prática:
- Opções do mesmo tema = o MESMO `--grupo`, uma `--direcao` por aba (A, B, C, D).
- Versão nova de um tema que já existe (v2, 2v2…) = o MESMO `--grupo` + uma `--direcao` nova → entra como NOVA ABA do card. **Regra de ouro: mesmo --grupo, nunca grupo novo** — grupo novo para o mesmo tema racha o card em dois e o Athos perde o fio (foi o que aconteceu com `pregao-associar-demanda` e `pregao-associar-demanda-v2`, medido em 04/10).

**Mockup NOVO (1ª versão): gere 3-4 direções visuais distintas antes de
construir a definitiva** — paleta/tipografia/densidade diferentes, cada uma
com 1 frase de tradeoff, nomeando no prompt de geração os padrões de "visual
padrão de IA" a evitar (gradiente genérico, cards idênticos em grade, emoji
como ícone — guia mais fundo: skill `frontend-design`). Publique as 3-4 — uma
chamada por arquivo, mesmo `--grupo`, uma letra de `--direcao` cada — e
apresente via **AskUserQuestion** (1ª opção = sua recomendação, Regra Nº 1;
nunca links soltos pedindo escolha em texto livre): o contexto da pergunta
leva o link do GRUPO, uma vez (a linha `grupo:` do script) — é UM card com as
opções em abas — e depois vai uma opção por ABA (A, B, C…), com o tradeoff na
descrição e o link com `#<aba>` (`…/g/<grupo>#a`) pra abrir direto nela.
Protocolo completo, com o passo a passo numerado:
`whatsapp_automation/docs/agent-guide/mockups-e-mbe.md` → "Mockups de UI/UX —
protocolo obrigatório" (ga-g7x0si; ficava no `CLAUDE.md` do rig até o wa-jo2qbg,
15/10). Ajuste incremental / versão nova num mockup que JÁ existe NÃO repete as
3-4 direções — publique só a versão atualizada, com o mesmo `--grupo` e
`--direcao v2` (depois `v3`, `2v2`…); ela entra como nova aba no mesmo card.
Antes de publicar, confira o nome EXATO do grupo — um `--grupo` com uma letra
diferente cria um card novo em silêncio:
`curl -s http://127.0.0.1:8097/api/mockups | jq -r '.grupos[].grupo'`.

```bash
python3 /Users/athos/gt/whatsapp_automation/scripts/publicar_mockup.py dirA.html \
  --titulo "<nome do mockup>" --bead <id-do-bead> \
  --grupo <slug-do-mockup> --direcao A --tradeoff "Ganha: … Perde: …"
# → imprime DUAS URLs: "✓ publicado: …/mockups/<slug>" (a OPÇÃO, o HTML cru) e "grupo: …/mockups/g/<grupo>#<aba>" (o CARD, já na aba da opção; sem #<aba> na URL, abre na 1ª aba) — é a do GRUPO que vai pro Athos
```

⚠️ Use SEMPRE esse caminho ABSOLUTO, de qualquer cwd: rodar `scripts/publicar_mockup.py` de dentro de um worktree sai 3 sem publicar nada (`shared/data` é gitignored no whatsapp_automation e o worktree de worker não o tem). Códigos de saída: 0 publicado; 1 recusado (dado pessoal ou entrada inválida); 3 erro de infraestrutura — NADA foi publicado; 4 FICOU gravado mas a conferência falhou — NÃO republique (duplica), confira `https://admin.urblink.com.br/mockups`; 2 é uso errado da linha de comando. O HTML roda isolado no admin: `localStorage`/`sessionStorage`/cookie falham lá — proteja com try/catch (o script avisa).

Cite as URLs no bead de origem (comentário): as da OPÇÃO (`✓ publicado:`) E a do GRUPO. O Guard #13 do pre-push (`scripts/check_mockup_protocol_guard.py` do rig) só reconhece URL de OPÇÃO (`…/mockups/<slug>-<8 hex>`); a URL do grupo (`…/mockups/g/<grupo>`) NÃO o satisfaz — citar só o link do grupo não destrava o push.

🚨 NUNCA publique CPF, telefone, endereço, situação sucessória/óbito ou qualquer dado que identifique uma pessoa específica num mockup. O script varre o HTML e recusa sozinho (exit 1), mas em exemplo use número obviamente falso (98888-7777). Dossiê de pessoa ou imóvel específico não é mockup: o lugar é `shared/data/estudos` (também no admin, atrás do Cloudflare Access).

✅ **Exceção (Athos, 10/10, wa-sq2wsa): mockup de tela do app do incorporador com o conteúdo da MBE** (Martins Bernardes Empreendimentos, a empresa de referência do app do incorporador, `terreno_publico`; o Athos é sócio dela) **pode mostrar endereço, desenho e quarteirão reais dos terrenos** — a página Mockups tem o mesmo login do admin (o guia do rig registra a verificação de 10/10: `/mockups` redireciona para o Cloudflare Access). Pergunta e resposta, verbatim: *"Então: nos mockups com o conteúdo da MBE, libero endereço e desenho real dos terrenos?"* → *"Libera endereço e desenho (Recomendado)"*. Continua **PROIBIDO** mesmo nesse caso: nome, CPF/CNPJ, telefone, e-mail, óbito/situação sucessória e processo de **proprietário**. Fora desse caso (outra empresa, outro tema), a regra acima vale inteira. O conteúdo da MBE entra no mockup só por leitura: agir na conta dela continua proibido sem ordem do Athos naquele momento (guia do rig, `docs/agent-guide/mockups-e-mbe.md`, seção "Martins Bernardes Empreendimentos").

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
   O **Step 2b do `/gate-done` (pré-revisão, experimento A/B ga-gnr3tw) está ENCERRADO desde 03/10/2026** (ga-ufskhy.1; chave `.gc/pregate.off`): não há nada para rodar nele, vá direto ao Step 3. O texto antigo do passo (comando + tabela de saídas) continua no histórico do git, para o caso de o programa ser religado.
3. O launchd guard detecta o marker em ~2 min, despacha 3 revisores independentes e mergeia direto em main.
4. Você receberá mail quando o gate passar ou falhar.

`mr`/PR está PROIBIDO neste city. O gate é o único caminho para produção.
