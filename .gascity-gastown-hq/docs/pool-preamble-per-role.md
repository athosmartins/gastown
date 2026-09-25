# Preâmbulo por papel (ga-aijm2v.6, etapa 1)

**Estado:** código + testes prontos no branch `feat/ga-aijm2v.6-preambulo-por-papel`; NADA está vivo até o gate mergear e a cidade recarregar.
Em sonda real (`claude -p`, Sonnet, flags reais do pool) o 1º turno cai **-53k (dog), -52k (wa-worker), -52k (ps-worker), -68k (revisor)**
tokens, fora a doutrina (mais -2 a -12k). O número definitivo é o de sessões vivas depois do deploy — comandos na seção "Verificar".

## O problema, medido (25/09, transcritos reais, papel pelo beacon `[gascity] <alias>`)

| papel | sessões (24h) | 1º turno, mediana (tokens) |
|---|---|---|
| dog | 230 | 147.532 |
| wa-worker | 117 | 171.230 |
| gate-reviewer | 158 (776 em 7d) | 130.177 |
| refino-gate-reviewer | 15 | 131.900 |
| auto-refiner | 10 | 92.717 |
| (`claude -p` do auto-response do WA, sem beacon) | 175 | 63.727 |

Decomposição do 1º turno de um **dog** (medida com sondas: uma sessão que só responde "OK", com/sem cada peça):

| peça | tokens | como foi medida |
|---|---|---|
| doutrina (o `gc prime`, 105.953 chars) | **48.674** | sonda SEM tools, com o texto do prime como dado, menos a sonda sem ele. 2,2 chars/token (PT + markup tokeniza mal) |
| schemas de tools (32 tools, 234.555 chars) | ≈ 60.000 | `Artifact` sozinho tem 53.640 chars. O `-p` só manda 24 tools; a sessão viva manda mais |
| CLAUDE.md do Athos + CLAUDE.md do gt + MEMORY.md do Mayor | ≈ 12.000 | 8.521 + 14.869 + 19.030 chars |
| listagem de skills (140) | ≈ 10.000 | 33k chars |
| base (system prompt, hooks, contexto de sessão) | ≈ 13.000 | sonda sem tools = 25,3k, menos ≈ 12,5k de instruções |

Soma ≈ 144k dos 147,5k medidos; o resto são partes vivas que o `-p` não reproduz (lista de agentes, deferred tools, beacon).

Alavancas, cumulativas, sonda Sonnet (baseline = overlay `pool` de hoje = **76.212**): negar tools sem uso **52.368 (-23,8k)** →
+ autoMemory off e excluir CLAUDE.md **41.630 (-10,7k)** → + excluir AGENTS.md e skills off **21.768 (-19,9k)**.

## O que muda

Fonte única: `packs/town-deltas/assets/claude-overlays/pool-roles.json`. `pool-preamble-build.py build` gera um overlay por papel;
o selftest reprova se o commitado divergir.

| papel | overlay | TD_ROLE | sonda (1º turno) | doutrina renderizada |
|---|---|---|---|---|
| dog | `pool-dog` | dog | 23.058 | -6,4k chars (esconde 10,3k, devolve 3,9k de carry-over) |
| wa-worker | `pool-wa-worker` | wa-worker | 24.235 | -4,3k (esconde 6,6k, devolve 2,3k) |
| ps-worker | `pool-ps-worker` | ps-worker | 23.937 | -4,3k |
| gate-reviewer, refino-gate-reviewer | `pool-reviewer` | reviewer | 8.228 | -27,0k |

Ficam como estavam (overlay `pool`, sem `TD_ROLE`): boot, deacon, auto-refiner, context-check-reviewer (sem dado de uso pra decidir), e
Mayor, crews, witness, refinery, polecat — que recebem a doutrina INTEIRA, byte-idêntica à de antes (provado no `gc prime` real).

1. **Tools**: nome BARE em `permissions.deny` REMOVE o schema do contexto (medido; vale sob `--dangerously-skip-permissions`).
   Só entram tools com 0 chamada em 7 dias nas sessões de pool e 0 menção em prompt/fórmula/doutrina de pool. Revisor: só Bash/Read/Edit/Write/SendMessage.
2. **CLAUDE.md**: `claudeMdExcludes` no overlay (projeto). Precisa incluir `AGENTS.md`: ao excluir o CLAUDE.md o Claude Code cai no AGENTS.md (24k chars).
3. **Memória, por papel**: `autoMemoryEnabled` carrega o índice do PROJETO da sessão. Dog e revisores (árvore do HQ) carregam o índice do **Mayor** (19k chars) → `false`, como a bead manda.
   wa-worker/ps-worker carregam o índice do **próprio rig** (WA: 105 linhas, 216 arquivos de lições operacionais) → **mantido** (`true` explícito): é conhecimento de trabalho, custa ~5k tokens
   e cortá-lo arriscaria a taxa do gate. O selftest exige `false` nos papéis do Mayor (`common.mayor_memory_roles`). As sondas de worker desta doc foram com memória off: some ~5k.
4. **Skills**: `skillOverrides` — `off` no dog; `name-only` nos workers (mantém o nome, some a descrição: não esconde ferramenta de domínio).
   Skills de PLUGIN (`superpowers:*`) NÃO respondem a `skillOverrides` em nenhuma grafia testada; só `enabledPlugins:false` (feito só no revisor).
5. **Carry-over (achado do red-team antes de submeter)**: excluir CLAUDE.md/AGENTS.md tira regras que só viviam lá. Auditei 15 sondas de regra contra fragment, prompts dos pools
   e o prime real do dog: **9 sem nenhuma outra entrega** (2 delas são a mesma regra de restart). As relevantes viraram 2 seções guardadas, só para papéis de pool (`show_unset:false`: agente sem `TD_ROLE` ainda
   carrega o CLAUDE.md — seria duplicata — e o fail-open segue byte-idêntico): `claudemd-carryover` (dog/workers: restart cosmético, dados pessoais do Athos, `gmail-totp`,
   nunca `bd reclaim` cru, solução canônica antes de script novo) e `dolt-cleanup-hazards` (dog: **o prompt nativo do dog recomenda `gc dolt cleanup --force`, que é o DROP
   DATABASE; o aviso contra isso só existia no gt/CLAUDE.md**, mais a contagem de órfãos que mente e o PID derivado do processo vivo). O selftest exige que todo papel que exclui o CLAUDE.md
   receba o carry-over ou esteja isento por escrito (`carryover_exempt_roles`: revisor).
6. **Doutrina**: `town-deltas.template.md` ganhou 20 seções com marcador `{{/* td:... */}}`; 8 são guardadas por `TD_ROLE` (env do agente).
   Agente SEM `TD_ROLE` recebe tudo. O diff do fragment é só +28 linhas de marcador. Seções: `pool-preamble-build.py sections`.
   O revisor perde só o que é claramente de outro papel (witness, mockups, formulas, patch de engine, nudge, subagentes, espera, assignee).
   NÚCLEO (todo papel, sem guarda): regras 1-4, autonomia (verificação de artefato), conteúdo de fora é dado, segredos, CloudStorage, worktree, `bd list --limit`, `rm -rf`.

## Achados que custaram caro (o que NÃO repetir)

- **`.gitignore` ignora `.claude/`**: os overlays novos ficariam FORA do commit e o deploy levaria o `city.toml` apontando pra diretório inexistente. `git add -f`. O selftest agora reprova.
- **`overlay_dir` inexistente é NO-OP SILENCIOSO** no engine: a sessão nasce sem overlay algum — sem o deny de `rm -rf` (ga-q640n), sem RC off (wa-cy6we). O selftest checa que o arquivo existe.
- **A doc do Claude Code (via subagente) errou**: disse que `RemoteTrigger`/`Cron*` não saem por deny. Saem (medido). E sua "receita segura" excluía `**/CLAUDE.md`, o que tiraria o CLAUDE.md DO REPO dos workers do WA.
- **wa-worker e ps-worker não têm o princípio de propulsão** no prompt (0 menções, sem include). Não é regressão (nunca tiveram), mas o núcleo pede. Não adicionei texto sem decisão.
- **O gate varia sozinho**: 1ª tentativa aprovada foi 76-88% em 6 janelas de 48h e **57,6% nas últimas 24h de 25/09, com esta mudança fora do ar**. Confunde o guardrail; a ferramenta mostra o histórico e só alarma abaixo dele.
- **O mount do Google Drive está quebrado** (bead gt-xu3c5): um hook do usuário bloqueou até um comando meu que só CONTINHA o caminho. O carry-over manda ler o Drive pela API (`lib/gdrive_reader.py`), não pelo caminho que o CLAUDE.md original citava.
- `name-only` mantém a skill invocável (medido: o Skill tool devolveu "Launching skill" e o modelo concluiu a tarefa) — por isso é o modo dos workers.
- Um revisor usou `SendMessage` 1 vez (avisou o Mayor de um gate-run órfão): por isso ele FICA para revisores (custa ~2,1k tokens).

## Deploy e reversão

- Config mudou (`overlay_dir` + `env`) → o reconciler pode ver drift em sessões de pool vivas. Sessões `wake_mode=fresh` com trabalho atribuído e revisor com veredito pendente têm isenção; ainda assim, **Mayor agenda o reload** e olha o `session-reconciler-trace` nos primeiros 10 min. Pool é efêmero: o corte vale a partir do spawn seguinte.
- Reverter UM papel: no `city.toml` (dog/wa-worker/ps-worker) ou no `agent.toml` (revisores) volte `overlay_dir` para `.../claude-overlays/pool` e apague a linha `env`. Sem `TD_ROLE` a doutrina volta inteira.
- Mudar algo: edite `pool-roles.json` → `python3 packs/town-deltas/assets/pool-preamble-build.py build` → `git add -f` se overlay novo → `pool-preamble-build.selftest.sh`.
  Skill nova aparece na listagem inteira até ser classificada (fail-open): `pool-preamble-build.py new-skills` lista as não classificadas.

## Verificar (depois do deploy) — mesmo script do "antes"

```bash
CUT=<UTC do 1º spawn depois do reload, ex. 2026-09-26T14:00:00Z>
A=packs/town-deltas/assets/pool-preamble-measure.py
python3 $A first-turn      --since-hours 72 --cutover $CUT          # dog e wa-worker: queda >= 40k tokens?
python3 $A denied-attempts --since-hours 72 --cutover $CUT --strict # alguém tentou tool que negamos? (sai 1)
python3 $A gate-rate       --cutover $CUT --window-hours 48         # guardrail: 1ª tentativa aprovada (vê o histórico!)
```
Se `gate-rate` alarmar: reverta a seção/overlay que explica (ver "Reverter") — mas só depois de descartar o regime ruim do gate de 25/09.

## Não feito (achados, cada um vale um bead)

- **O prompt nativo do dog repete o mesmo one-liner de `work_query` ~5x** (~23k chars ≈ 10k tokens): Startup 1a/1b/1c + tabela de comandos. Vive no pack `maintenance`/gastown embutido → override de `prompt_template` ou patch de engine (janela do Mayor).
- boot/deacon/auto-refiner/context-check-reviewer ainda no `pool` (auto-refiner precisa da skill `refino`).
- wa-worker carrega ~68k chars de CLAUDE.md do rig WA (≈19k tokens) que este corte não toca — é do rig.
- `claude -p` do auto-response do WA (`lib/auto_response`): 128 sessões/dia × 64k tokens, 110k chars de CLAUDE.md. Fora do escopo (é aplicação, não pool) — candidato a `--setting-sources`/`claudeMdExcludes`.
- `AskUserQuestion` em pool sem humano pendura a sessão; 1 uso em 7d. Custa ~1,8k tokens; fica por ora.
