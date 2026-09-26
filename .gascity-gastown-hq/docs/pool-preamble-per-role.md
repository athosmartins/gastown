# Preâmbulo por papel (ga-aijm2v.6, etapa 1)

**Estado:** código + testes prontos no branch `feat/ga-aijm2v.6-preambulo-por-papel`; NADA está vivo até o gate mergear e a cidade recarregar.
Em sonda real (`claude -p`, Sonnet, flags reais do pool) o 1º turno cai **≈ -53k (dog), -52k (wa-worker), -52k (ps-worker), -58k (revisor)**
tokens, fora a doutrina (mais -2 a -12k). O revisor era -68k na 1ª versão; caiu 10k quando Monitor/TaskStop/ScheduleWakeup/Skill (que ele USA) deixaram de ser negadas —
ver "Sonda, rodada 2". O número definitivo é o de sessões vivas depois do deploy — comandos na seção "Verificar".

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
| dog | `pool-dog` | dog | ≈ 23.215 † | -6,4k chars (esconde 10,3k, devolve 3,9k de carry-over) |
| wa-worker | `pool-wa-worker` | wa-worker | 24.235 | -4,3k (esconde 6,6k, devolve 2,3k) |
| ps-worker | `pool-ps-worker` | ps-worker | 23.937 | -4,3k |
| gate-reviewer, refino-gate-reviewer | `pool-reviewer` — **NÃO fiado** (ver "Revisores" abaixo); hoje `pool` | reviewer | ≈ 18.660 † **(só com o overlay religado)** | -27,0k (vale: `TD_ROLE` é env, não overlay) |

† rodada 1 (23.058 e 8.228) + o delta medido na rodada 2 (+157 e +10.432). wa-worker e ps-worker têm overlay idêntico ao da rodada 1.

Ficam como estavam (overlay `pool`, sem `TD_ROLE`): boot, deacon, auto-refiner, context-check-reviewer (sem dado de uso pra decidir), e
Mayor, crews, witness, refinery, polecat — que recebem a doutrina INTEIRA, byte-idêntica à de antes (provado no `gc prime` real).

1. **Tools**: nome BARE em `permissions.deny` REMOVE o schema do contexto (medido; vale sob `--dangerously-skip-permissions`).
   **Regra: uma tool só é negada a um papel se esse papel mediu ZERO chamadas** nos transcritos retidos (~8 dias, 18-26/09, ANTES do overlay), contando `tool_use`
   **por bloco**. Em `common.deny_tools` só vão as com zero em TODOS os papéis medidos (dog 208 sessões, wa-worker 69, gate-reviewer 825, refino-gate-reviewer 38);
   as que algum papel usa (`CronDelete` dog 1, `PushNotification` gate-reviewer 1) são negadas só aos papéis que mediram zero (`deny_tools_extra`).
   (O veredito do gate citou `EnterWorktree`/`ExitWorktree` em uso no dog, 1/2 chamadas: **não se sustenta** — o scanner por bloco e um grep exato do registro `tool_use` em TODOS os transcritos
   retidos, Mayor e crews inclusos, dão 0/0; um grep frouxo por `"name":"EnterWorktree"` também casa schemas de tool citados em sessões do Mayor. Ficam em `common`.) **O revisor USA** Monitor (13 chamadas, 10 sessões — a forma sancionada de esperar uma suíte longa, porque
   `sleep` em foreground é bloqueado), TaskStop (23), ScheduleWakeup (3), Skill (6: `refino` x3 no refino-gate-reviewer; `verification-before-completion` x2 e `browser-control` x1 no
   gate-reviewer), WebFetch/WebSearch/AskUserQuestion/PushNotification (1 cada) e SendMessage (1) — nada disso é negado. Só `Agent`, `ListAgents` e `CronDelete` (0 no revisor) ficam negadas a ele, além do `common`.
   **ps-worker tem 0 sessões nos transcritos (SEM DADO, não "zero uso")**: herda a lista do wa-worker e o `denied-attempts` pós-deploy é o que a valida.
2. **CLAUDE.md**: `claudeMdExcludes` no overlay (projeto). Precisa incluir `AGENTS.md`: ao excluir o CLAUDE.md o Claude Code cai no AGENTS.md (24k chars).
3. **Memória, por papel**: `autoMemoryEnabled` carrega o índice do PROJETO da sessão. Dog e revisores (árvore do HQ) carregam o índice do **Mayor** (19k chars) → `false`, como a bead manda.
   wa-worker/ps-worker carregam o índice do **próprio rig** (WA: 105 linhas, 216 arquivos de lições operacionais) → **mantido** (`true` explícito): é conhecimento de trabalho, custa ~5k tokens
   e cortá-lo arriscaria a taxa do gate. O selftest exige `false` nos papéis do Mayor (`common.mayor_memory_roles`). As sondas de worker desta doc foram com memória off: some ~5k.
4. **Skills**: `skillOverrides` — `off` (exceto a lista `keep`) no dog e no revisor; `name-only` nos workers (mantém o nome, some a descrição: não esconde ferramenta de domínio).
   O revisor mantém `refino` (o refino-gate-reviewer a invoca: é o critério que ele revisa), `browser-control` e `core.gc-*` (o rodapé do prompt manda usá-las); a tool `Skill` volta, com a listagem enxuta.
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

## Sonda, rodada 2 (correção do veredito ga-0g70nl)

Mesmo harness para todas as linhas (`claude -p`, Sonnet, `--strict-mcp-config`, diretório descartável, turno "Responda apenas: OK"; overlay = `.claude/settings.json` do papel):

| overlay | 1ª versão (`4f7ac3b0`) | corrigido | delta | por quê |
|---|---|---|---|---|
| dog | 21.152 | 21.309 | +157 | só `CronDelete` volta (o dog a usou 1x) |
| revisor | 6.840 | 17.272 | +10.432 | `Monitor`, `TaskStop`, `ScheduleWakeup`, `Skill` (listagem enxuta), `WebFetch`, `WebSearch`, `AskUserQuestion`, `PushNotification` voltam |
| wa-worker | — | 22.870 | 0 | overlay inalterado |
| ps-worker | — | 22.724 | 0 | overlay inalterado |
| base `pool` (referência) | 46.075 | | | |

⚠️ Este harness mede a base `pool` em **46.075**, não nos 76.212 da rodada 1 (aquele carregava mais contexto), então **compare linhas dentro de uma rodada, nunca valores entre rodadas** —
por isso o † acima soma só o DELTA medido. O corte do dog e do wa-worker (critério ≥ 40k) NÃO depende do revisor; o número que vale é o de sessões vivas (seção "Verificar").
Custo consciente no revisor: as 4 tools de 1 uso cada (`WebFetch`, `WebSearch`, `AskUserQuestion`, `PushNotification`) custam parte desses +10k e têm alternativa (`curl` via Bash, `notify`,
e `AskUserQuestion` num pool sem humano só penduraria a sessão); negá-las é o próximo corte — mas pela regra "zero chamada" elas ficam até o `denied-attempts` pós-deploy dizer que ninguém as usa.

## Achados que custaram caro (o que NÃO repetir)

- **A ferramenta de medição estava CEGA a ~90% das chamadas de tool, e por isso as listas de deny partiram de uma premissa falsa** (veredito do gate ga-0g70nl). O Claude Code grava **um registro JSONL por
  bloco de conteúdo** (thinking / text / tool_use), todos com o **mesmo `message.id`**; a 1ª versão de `scan_session` deduplicava por `message.id` ANTES de contar `tool_use`, então só via o 1º registro de cada
  mensagem (medido por mim nos 1.354 transcritos retidos: o scanner antigo via 3.858 dos 35.781 `tool_use` dos papéis de pool, ~11% — dog 7%, wa-worker 12%, revisores 12%). Resultado: `denied-attempts --strict` dizia "nenhuma tentativa de tool negada" quando havia 49 (gate-reviewer 45, refino-gate-reviewer 4, dog 1),
  e as listas negavam ao revisor Monitor/TaskStop/ScheduleWakeup/Skill por "0 uso" (o que o revisor faz de fato é esperar suíte com Monitor). **Ausência de detecção foi lida como ausência de uso** — a família
  error-vs-empty. Consertado: tokens/turnos seguem por `message.id` (o `usage` se repete em cada registro), `tool_use` conta por id do BLOCO. O selftest agora usa o layout real (3 registros por id) e reprova o código antigo.
  Prova com dado real: o scanner novo contra o manifesto reprovado devolve 49 tentativas e exit 1; contra o manifesto corrigido, exit 0.

- **`.gitignore` ignora `.claude/`**: os overlays novos ficariam FORA do commit e o deploy levaria o `city.toml` apontando pra diretório inexistente. `git add -f`. O selftest agora reprova.
- **`overlay_dir` inexistente é NO-OP SILENCIOSO** no engine: a sessão nasce sem overlay algum — sem o deny de `rm -rf` (ga-q640n), sem RC off (wa-cy6we). O selftest checa que o arquivo existe.
- **A doc do Claude Code (via subagente) errou**: disse que `RemoteTrigger`/`Cron*` não saem por deny. Saem (medido). E sua "receita segura" excluía `**/CLAUDE.md`, o que tiraria o CLAUDE.md DO REPO dos workers do WA.
- **wa-worker e ps-worker não têm o princípio de propulsão** no prompt (0 menções, sem include). Não é regressão (nunca tiveram), mas o núcleo pede. Não adicionei texto sem decisão.
- **O gate varia sozinho**: 1ª tentativa aprovada foi 76-88% em 6 janelas de 48h e **57,6% nas últimas 24h de 25/09, com esta mudança fora do ar**. Confunde o guardrail; a ferramenta mostra o histórico e só alarma abaixo dele.
- **O mount do Google Drive está quebrado** (bead gt-xu3c5): um hook do usuário bloqueou até um comando meu que só CONTINHA o caminho. O carry-over manda ler o Drive pela API (`lib/gdrive_reader.py`), não pelo caminho que o CLAUDE.md original citava.
- `name-only` mantém a skill invocável (medido: o Skill tool devolveu "Launching skill" e o modelo concluiu a tarefa) — por isso é o modo dos workers.
- Um revisor usou `SendMessage` 1 vez (avisou o Mayor de um gate-run órfão): por isso ele FICA para revisores (custa ~2,1k tokens).

## Revisores: o overlay `pool-reviewer` NÃO está fiado (ga-swnkfm, 26/09)

Os revisores (gate-reviewer, refino-gate-reviewer) **não têm `work_dir`: rodam na RAIZ da cidade**. `overlay_dir` faz JSON-merge em `<workdir>/.claude/settings.json`,
e o `<cidade>/.gc/settings.json` — o `--settings` de TODAS as sessões — é derivado desse arquivo (engine: `installClaude` = defaults embutidos + `<cidade>/.claude/settings.json`).
O `pool-reviewer` fiado na raiz virou a config da cidade inteira: `gate-done` OFF (builder não conseguia submeter ao gate), CLAUDE.md do Athos/gt fora, memória off, deny de `Agent`/`EnterWorktree`.
O merge (`internal/overlay/merge.go`) **só adiciona chave**, então reverter o `overlay_dir` não limpou: a sobra voltou (2ª ocorrência) e só saiu limpando os DOIS arquivos à mão.

Estado hoje: os 2 revisores usam o overlay base `pool`; a economia de -27k chars de doutrina do revisor continua valendo (é `TD_ROLE`, env); a de tools/skills/CLAUDE.md (a sonda mediu ≈ -58k tokens no 1º turno do revisor, ver o topo) **não**.
O manifesto declara isso (`roles.reviewer.workdir = "city-root"` diz ONDE roda; `wired_overlay = "pool"` diz o que está fiado) e três coisas enforçam:
1. `pool-preamble-build.selftest.sh` (C/C3): papel `city-root` só pode ter o overlay base; `own` exige `work_dir`; com mutações (o teste antigo EXIGIA o `pool-reviewer`).
2. `scripts/overlay-root-leak-guard.py` (+ `.selftest.sh`, order `overlay-root-leak-guard` a cada 10 min): lê `gc config show` E os dois arquivos vivos; vermelho se agente na raiz tem overlay de papel, se dois agentes com overlays diferentes dividem um `work_dir`, ou se raiz/`.gc` já contêm chave de papel. `rc 2` = não consegui saber (nunca "limpo").
3. Um crash do guard sai `rc 2`, não `rc 1`: erro não se passa por achado.

Religar o `pool-reviewer` (só com prova de spawn real): dê aos 2 revisores um `work_dir` FIXO e próprio (não use `{{.AgentBase}}`: é um diretório por sessão, ~800/semana), troque `roles.reviewer.workdir` para `"own"` e REMOVA `wired_overlay`/`_wired_overlay_why` (o campo do Mayor, 49cd6f040, que registra o overlay desligado),
aponte o `overlay_dir` dos 2 `agent.toml` para `.../pool-reviewer`, rode o selftest (C) e o guard, e confira com um spawn real que `<cidade>/.claude/settings.json` e `<cidade>/.gc/settings.json` ficaram intactos (guard `rc 0`). **Mayor agenda o reload.**

## Deploy e reversão

- Config mudou (`overlay_dir` + `env`) → o reconciler pode ver drift em sessões de pool vivas. Sessões `wake_mode=fresh` com trabalho atribuído e revisor com veredito pendente têm isenção; ainda assim, **Mayor agenda o reload** e olha o `session-reconciler-trace` nos primeiros 10 min. Pool é efêmero: o corte vale a partir do spawn seguinte.
- Reverter UM papel: no `city.toml` (dog/wa-worker/ps-worker) ou no `agent.toml` (revisores) volte `overlay_dir` para `.../claude-overlays/pool` e apague a linha `env`. Sem `TD_ROLE` a doutrina volta inteira.
- Mudar algo: edite `pool-roles.json` → `python3 packs/town-deltas/assets/pool-preamble-build.py build` → `git add -f` se overlay novo → `pool-preamble-build.selftest.sh`.
  Skill nova aparece na listagem inteira até ser classificada (fail-open): `pool-preamble-build.py new-skills` lista as não classificadas.

## Verificar ANTES do deploy (e sempre que mexer nas listas de deny)

```bash
A=packs/town-deltas/assets/pool-preamble-measure.py
python3 $A denied-attempts --since-hours 240 --strict   # SEM --cutover: os transcritos são de ANTES do overlay = a demanda real. Tem que sair 0.
```
Papel do manifesto sem nenhuma sessão na amostra aparece como **SEM DADO** (hoje: ps-worker) — não como "sem tentativas". Transcrito apagado no meio da varredura é descartado e CONTADO.

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
- `AskUserQuestion` em pool sem humano pendura a sessão; 1 uso em ~8 dias (um revisor). Custa ~1,8k tokens; fica por ora — junto com `WebFetch`/`WebSearch`/`PushNotification` no revisor (ver "Sonda, rodada 2").
