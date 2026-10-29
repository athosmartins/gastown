# agent-browser × MCP `playwright-cdp` — avaliação no nó e no mini (ga-30455bt, ga-g7zyxc3)

## Contents

• 1. Como foi medido · 2. Tokens por observação · 3. A tarefa canônica: chamadas e custo
• 4. `--delta` e o que o filtro esconde · 5. RAM · 6. Chrome compartilhado e `--pin-tab`
• 7. Custo estático · 8. Riscos e achados operacionais · 9. O que NÃO foi medido (só o mini) e o piloto proposto
• 10. Reproduzir e evidência · 11. Medido no mini (ga-g7zyxc3, 28/10)

Bead ga-30455bt (P3, do Mayor; origem: vídeo que o Athos mandou em 28/10). As seções 1–10 foram medidas em 28/10/2026 no nó Hetzner (Linux aarch64, 16 núcleos), contra **um Chromium compartilhado por CDP** (headless_shell 145.0.7632.0, porta de teste 47222; o desenho é o do `:9222` do mini). agent-browser **v0.40.0** (binário oficial do GitHub, sha256 `f33b4dd9…` = o digest que o GitHub publica) e `@playwright/mcp` **0.0.83** (depende de `playwright-core 1.64.0-alpha`). Fixtures: GitHub login, HN, formulário httpbin e Wikipédia "Web browser" congelados (scripts fora, CSS inline, Chromium sem DNS externo) + uma lista própria. **Nas seções 1–10 nada foi rodado no mini nem no Chrome real do Athos; a §11 (bead ga-g7zyxc3) repete a medição no mini e fecha o que o nó não alcançava.**

**Em 8 linhas**

1. **Veredito: piloto limitado no mini, só em modo CLI, sem trocar o MCP.** Com `batch` + `snapshot -i` o agent-browser custou **28–38%** do fluxo "snapshot a cada ponto" do Playwright e **57–63% do MELHOR fluxo do Playwright** (−37% com contexto-base de 30 mil tokens, −43% com 200 mil).
2. **O ganho vem do número de turnos, não do filtro de snapshot.** A própria cidade mediu (E8, `token-por-bead-e8.md`) que 53–72% do gasto dos builders é leitura de cache por turno. A mesma tarefa levou **4 chamadas** com `batch`, 8 no Playwright enxuto e 13 no agent-browser comando-a-comando. **Comando-a-comando ele não ganha**: com contexto de 200 mil custa 104% do pw-A e 142% do pw-B (§3).
3. **Por observação, `-i` corta 64–73%** (login 68%, formulário 64%, lista 72%, HN 66%, Wikipédia 73%). Mas **`-i` e `-c` somem com texto puro** — conferido contra o DOM: "Note 1 saved" só existe no `snapshot` completo; com `-c --delta` o resultado é `unchanged`. Erro de validação, toast e confirmação ficam invisíveis.
4. **RAM (Linux): ~11× menos que o Node do MCP direto e ~16× menos via `npx`.** Daemon Rust 11–12 MB de RSS (23 MB no pior caso, depois de ler a lista pesada) contra 117–140 MB (direto) e 192–204 MB (`npx`, 3 processos). No mini a métrica tem de ser `footprint`, nunca RSS (§5).
5. **`--pin-tab` funciona como documentado e o MCP atual NÃO isola.** Dois MCPs do Playwright no mesmo Chrome navegam a **mesma aba** (o primeiro passa a ver a página do segundo). Com `--pin-tab` cada sessão abre aba própria e recebe `tab_locked`/`tab_gone` em vez de agir na aba alheia. Custo: as abas ficam abertas depois do `close`.
6. **O modo MCP do agent-browser não serve de substituto**: 29 ferramentas = **16,9 mil tokens** de definições (4,5× os 3,8 mil do Playwright), sem campo de cdp nem de pin-tab; `--tools all` = 156 ferramentas, 88 mil tokens. O caminho viável é o CLI com uma skill (a do agent-browser tem 8,6 mil tokens; a `browser-control` da cidade, 2 mil).
7. **Sem conexão externa no uso normal** (strace de `open → snapshot → close`: só o socket local e a porta CDP). Mas é um projeto jovem e veloz (v0.40.0 saiu em 27/10, 696 issues abertas): fixar versão e sha256; `--allowed-domains` é **rejeitado** com CDP e `--auto-connect` sonda a 9222 sozinho (mesmo raio de explosão do perfil `~/.chrome-cdp`).
8. **NÃO medido no nó (só o mini)**: footprint no macOS, uso real (transcritos), login federado real em perfil descartável, `--pin-tab` no Chrome real `:9222/:9223`, latência, agente-com-LLM no laço (§9). **Medido depois no mini, §11**: tudo isso, menos login federado real (pede conta de alguém), passkey, `:9223` (Chrome do MBP desligado) e agente-com-LLM no laço.

---

## 1. Como foi medido

- **Tarefa canônica "login + 1 formulário"** (a do exemplo da bead), 11 passos iguais nas duas stacks: abrir login → preencher 2 campos → entrar → (painel) → abrir formulário → 3 textos + 1 rádio + 1 checkbox → enviar → confirmar. Refs resolvidas a partir do snapshot real de cada stack.
- **Política A** = re-snapshot em todo ponto de observação; **B** = snapshot só onde precisa de ref, verificação por URL/título; **B2/batch** = o fluxo com menos turnos que cada stack permite (Playwright: `browser_fill_form` também no login; agent-browser: um `batch` por fase).
- **Tokens**: tokenizador o200k como proxy, **calibrado contra tokens reais do Claude** nesta sessão (3 amostras de 14–24 KB, delta do `usage` do contexto menos o piso de chamadas triviais): real = **1,41 / 1,47 / 1,44 × o200k** (Playwright / agent-browser `-i` / agent-browser completo). A razão entre formatos varia ~4%, então as comparações relativas valem; o absoluto escala por ×1,44.
- **Custo** em ITE (equivalente em tokens de entrada: leitura de cache 0,1; escrita 1,25; saída 5), contando a **releitura do contexto-base a cada turno** e o custo estático (definições de ferramenta do MCP; skill do CLI). É um modelo, não fatura: premissas em `results/` e no `report.js`.
- **Limites**: páginas congeladas e sem estilo completo (9 de 29 CSS do GitHub caíram pelo teto) — o absoluto não vale para as telas reais do mini; o relativo vale (mesma árvore de acessibilidade do mesmo Chromium). Uma rodada por configuração (payload determinístico; RAM amostrada uma vez).

## 2. Tokens por observação

Tokens o200k por snapshot (real ≈ ×1,44). Playwright 0.0.83 **não devolve o snapshot inline** nas ações: devolve um *link* para `.playwright-mcp/page-*.yml` (~30 tokens); o inline vem de `browser_snapshot`.

| página | pw snapshot | pw `depth=3` | pw `find` (controles) | ab `snapshot` | ab `-i` | ab `-c` | ab `-d 3` |
|---|---|---|---|---|---|---|---|
| login (GitHub) | 507 | 212 | 490 | 336 | **160** | 253 | 319 |
| formulário | 582 | 443 | 582 | 432 | **212** | 408 | 339 |
| lista 40 linhas | 1.725 | 1.725 | 1.717 | 1.733 | **484** | 1.453 | 1.733 |
| lista HN | 13.564 | **253** | 16.211 | 6.951 | 4.650 | 5.655 | 321 |
| Wikipédia | 70.784 | **332** | 72.758 | 39.900 | 18.998 | 37.699 | 1.369 |

- `-i` vs snapshot do Playwright: **−68% / −64% / −72% / −66% / −73%**. O `snapshot` completo do agent-browser só corta 0–49%: **a economia vem do filtro interativo**, que o Playwright não tem como modo.
- O Playwright **já tem** alavancas baratas: `depth=3` dá o esqueleto da página em 250–330 tokens; `browser_find text=…` confirma uma mudança em 117–161 tokens. `browser_find` com regex largo **não** serve de `-i` (≈ o snapshot inteiro, até maior).

## 3. A tarefa canônica: chamadas e custo

| fluxo | chamadas | tokens de resultado | contexto adicionado (real) | ITE B=30k | vs pw-A | ITE B=200k | vs pw-A |
|---|---|---|---|---|---|---|---|
| pw-A (snapshot em 4 pontos) | 11 | 15.357 | 22.538 | 86.240 | 100% | 290.240 | 100% |
| pw-B (snapshot em 2 pontos) | 9 | 1.667 | 2.782 | 42.158 | 49% | 212.158 | 73% |
| **pw-B2 (melhor do Playwright)** | 8 | 1.656 | 2.786 | 38.624 | 45% | 191.624 | 66% |
| ab `snapshot` (A) | 13 | 7.882 | 11.774 | 84.396 | 98% | 322.396 | 111% |
| ab `-c` (A) | 13 | 6.429 | 9.693 | 80.388 | 93% | 318.388 | 110% |
| ab `-i` (A) | 13 | 5.135 | 7.828 | 76.741 | 89% | 314.741 | 108% |
| ab `-i` (B, comando-a-comando) | 13 | 477 | 1.113 | 63.648 | 74% | 301.648 | 104% |
| **ab `batch` + `-i`** | **4** | 477 | 1.006 | **24.284** | **28%** | **109.284** | **38%** |

- Custo estático incluído: 3,8 mil tokens (definições do Playwright) contra 8,6 mil (skill do agent-browser). Sem o estático, `batch` fica 46% abaixo do pw-B2 em B=30k.
- **13 chamadas do agent-browser** = um comando por chamada, com 2 `wait --url` e 2 verificações (snapshot na política A, `get title` na B); o `click` do agent-browser **não espera a navegação** (o do Playwright espera): sem `wait --url`, o `snapshot -i` seguinte devolveu `(no interactive elements)` (página em branco no meio da navegação).
- B=200k é o contexto dos crews que de fato usam o `playwright-cdp` (mayor, peter, batista): ali cada turno custa o equivalente a ~40 mil tokens de payload, e o **turno** vira a unidade de custo.

## 4. `--delta` e o que o filtro esconde

- Lista de 40 linhas, um item marcado: `-i` completo de novo = ~500 tokens; `-i --delta` = **80**; snapshot do Playwright = ~1.700; `browser_find text=` = 138–161.
- Wikipédia + widget, clique que acrescenta um `<li>` (3 cliques, 2 rodadas idênticas): `snapshot --delta` (sem `-i`) = baseline 39.508 e deltas **94 / 2.236 / 94** (o 2º é determinístico, não investigado); o Playwright refaz 70.808 a cada vez.
- **Armadilha (conferida contra o DOM: `eval` conta 1 nota; `results/compact-hides-text.txt`)**: o `snapshot` completo contém "Note 1 saved" (como `StaticText`); `-c`, `-i` e `-i -c` **não** (0 linhas). Os deltas acompanham: `-i --delta` = `unchanged` (7 tokens) e `-c --delta` = `unchanged` ou delta mínimo (7 / 58 / 7 tokens nos 3 cliques, nunca com a nota; `delta2.json`). Um agente que verifica o resultado de uma ação por `-i`/`-c` conclui "nada mudou" quando a página mostrou o feedback. Verificar por `wait --text`, `get text` ou `snapshot` completo.
- No fluxo navegando (login → painel → formulário) o `--delta` empata com `-i` (5.135 tokens nos dois): a URL muda e ele volta ao estado completo, como o README diz.

## 5. RAM

Linux, Chromium compartilhado fora da conta (igual nos dois). Dois números por stack porque o `npx` do mini põe um `npm exec` residente na frente do Node.

| stack | processos | RSS (início → 1º snapshot → fim) | PSS |
|---|---|---|---|
| Playwright MCP direto (`node cli.js`) | 1 | 117–119 → 128–130 → 139–140 MB | 92–94 → 113–115 MB |
| Playwright MCP via `npx` | 3 (`npm exec` 76 + `sh` 2 + `node` 126) | 192 → 204 MB | 132 → 143 MB |
| agent-browser (daemon Rust) | 1 | 11 → 12 MB (`batch`/B); 21–23 MB (A, após a lista HN) | 10 → 11 / 20–22 MB |

- ~11× (direto) e ~16× (npx) no uso enxuto; **~6× no pior caso** do agent-browser (23 MB). O daemon sai em 1 h ocioso (`--idle-timeout`); o do Playwright fecha só o browser.
- **No mini isto NÃO se transfere por RSS**: o `city.toml` (ga-e87w1f, 26/09) mediu 559 MB de RSS contra 6.087 MB de footprint real para os mesmos 120 processos MCP (memória comprimida do macOS). A bead pede "RSS"; no mini use `footprint -p <pid>` ou o `top` MEM.

## 6. Chrome compartilhado e `--pin-tab`

Um Chromium, uma aba `about:blank` (como os Chromes gerenciados do mini).

| cenário | resultado |
|---|---|
| 2 MCPs Playwright | PW1 abre `/tab/A1`; PW2 abre `/tab/B1` **na mesma aba**; PW1 passa a ver `TAB-B1`; depois PW2 renavega e PW1 vê `TAB-B2`. Nenhum abre aba própria. |
| 2 sessões agent-browser **sem** `--pin-tab` | mesma colisão (o README chama de "legado") |
| 2 sessões **com** `--pin-tab` | cada `open` cria aba própria (a `about:blank` fica); `a` segue em `TAB-A1` enquanto `b` vai a `B1`→`B2`; aba aberta por um humano não rouba a de ninguém |
| `b` tenta tomar a aba de `a` | `tab_locked: … pinned by session 'a'` (exit 1) |
| aba de `a` fechada por fora | `tab_gone` (exit 1) em `get title` e `eval`; `b` segue; recuperação com `tab new` |
| após `close` das duas | **as abas ficam abertas** (Chrome vivo): agentes precisam de `tab close` |

- Nome de sessão reaproveitado guarda o vínculo antigo: o 1º `--pin-tab` depois de a aba sumir dá `tab_gone` (alto e recuperável). Crews de vida longa devem usar id único por sessão.
- O MCP do Playwright **hoje** pisa na aba alheia; vale para o `:9222` se dois crews com `playwright-cdp` rodarem juntos, independente de qualquer troca.

## 7. Custo estático

| item | bytes | tokens o200k |
|---|---|---|
| Playwright MCP `tools/list` (25 ferramentas) | 17.616 | **3.764** |
| agent-browser MCP `core` (29 ferramentas) | 79.991 | **16.851** |
| agent-browser MCP `--tools all` (156 ferramentas) | 417.365 | 87.943 |
| agent-browser skill `core` (`SKILL.md`) | 39.038 | 8.571 |
| agent-browser `--help` / `references/commands.md` | 28.109 / 35.705 | 6.065 / 7.926 |
| skill `browser-control` da cidade | 7.557 | 2.046 |

Cada ferramenta MCP do agent-browser repete ~17 flags globais (~3 KB por definição). O binário solto **não traz a skill** (`skills get core` → "Skills directory not found"; ela vem no pacote npm de 120 MB, com `postinstall`).

## 8. Riscos e achados operacionais

- **Usar sem disciplina custa mais**: comando-a-comando, sem `batch`, sem `wait` e com `snapshot` completo, o agent-browser empata ou perde (§3).
- **Visibilidade**: `-i`/`-c` escondem texto puro (§4); `click` não espera navegação (§3); abas ficam após `close`; vínculo de sessão persiste.
- **Segurança**: no Chrome compartilhado nenhuma allowlist vale (`--allowed-domains` rejeita CDP/auto-connect/perfil/restore); `--auto-connect` sonda 9222/9229 e lê o `DevToolsActivePort`; há importação de login de perfil do Chrome e "auth vault". Os controles que sobram: `--action-policy`, `--confirm-actions`, `--content-boundaries`, `--max-output`. Texto de página e descrições WebMCP são **dado não confiável**.
- **Proveniência**: o npm traz `postinstall` e 120 MB; usar o binário de release com sha256 conferido (linux-arm64 conferido aqui; **darwin-arm64: `b064c9107a0431c76d8916e47c2c8ac322f49c2b2720d6c9036ab538ec1ed911`**, digest publicado, não baixado).
- **Estabilidade**: v0.40.0 de 27/10 depois de ~9,5 meses de projeto (≈ uma minor por semana, pela numeração) e 696 issues abertas. O MCP atual roda `npx @playwright/mcp@latest` **sem versão fixa** (hoje 0.0.83 → `playwright 1.64.0-alpha`): o mesmo risco já existe do lado de lá.
- Socket Unix limitado a 103 bytes: caminho de HOME/sessão longo falha (`AGENT_BROWSER_SOCKET_DIR` curto resolve).

## 9. O que NÃO foi medido (só o mini) e o piloto proposto

**Não medido** — cada item só se fecha no mini:

1. **Footprint no macOS** dos dois (`footprint -p`), não RSS. **→ medido, §11.3.**
2. **Linha de base de uso real**: chamadas `mcp__playwright-cdp__*` e tokens reais de resultado nos transcritos de hoje (a medição de 26/09 deu ~196 chamadas em 8 dias ≈ 25/dia; se for esse o volume, o ganho absoluto é pequeno). **→ medido, §11.4: 84 chamadas em 9 dias.**
3. **Login federado real** (redirect OAuth, popup, iframe, passkey) — em **perfil descartável**, nunca no `~/.chrome-cdp` do Athos. **→ só a mecânica, contra um IdP de teste (§11.6).**
4. **`--pin-tab` no Chrome real `:9222/:9223`** (≥136) com abas descartáveis. **→ `:9222` medido; `:9223` não (§11.5).**
5. Latência por chamada e **agente-com-LLM no laço** (aqui o payload é determinístico; o comportamento do modelo com a skill não foi medido). **→ latência medida (§11.2); agente-com-LLM no laço, não (§11.8).**

**Sem custo de migração, hoje**: skill `browser-control` ensinar higiene de snapshot no Playwright (`depth=3` para orientar, `browser_find` para confirmar, `browser_fill_form`) e **fixar a versão** do `@playwright/mcp`.

**Piloto (se o Mayor quiser)**: um crew, **CLI**, ao lado do MCP (que não sai); skill com `batch`, `snapshot -i` + `wait --url|--text`, confirmação por `get text`/snapshot completo, `--pin-tab` + id único de sessão, `tab close` no fim, `--action-policy` para o irreversível e `--content-boundaries`; binário e sha256 fixos. Critério de saída: os itens 1–5 acima.

## 10. Reproduzir e evidência

Tudo em `agent-browser-vs-playwright-mcp-ga-30455bt/`: `README.md` (passo a passo e adaptação para o mini), `scripts/` (harness), `results/` (saídas medidas: `report.txt`, `task-*.json`, `micro.json`, `delta2.json`, `calibration.json`, `share-test.txt`, `pin-test.txt`, `compact-hides-text.txt`, `strace-connect.txt`, `probe-tools.txt`, `static-sizes.txt`). As respostas brutas por passo ficaram no scratchpad do nó (não publicadas: têm conteúdo de páginas de terceiros).

A medição do mini (§11) tem a sua pasta de evidência, `agent-browser-vs-playwright-mcp-ga-30455bt/mini/` (scripts macOS, 3 rodadas, fluxos federados, mitigação de aba, baseline de uso, `README.md`), na branch **`worker/dog-gastown-dog-6-ga-g7zyxc3-mini` @ `89c745906`** (continuação da `worker/dog-remote-gawispa2pmaz` @ `10b8adbd4`, do nó). As duas ficam fora da main de propósito: harness e `results/` passam do teto de 1000 linhas do gate.

## 11. Medido no mini (ga-g7zyxc3, 28/10)

Mesmo harness do nó, versão macOS. Chrome **156.0.8078.49** descartável (headless, perfil novo, porta 47222), `@playwright/mcp` 0.0.83, agent-browser v0.40.0 darwin-arm64 (sha256 `b064c910…ed911`, conferido no download contra o digest que o GitHub publica). O mini esteve a **load average 43–82 em 10 núcleos** durante toda a medição: os tempos são sob a carga normal dele, não de máquina ociosa. Fixtures re-congeladas no dia (a home do HN mudou): vale o relativo, não o absoluto.

**Em 7 linhas**

1. **O veredito do nó se mantém no mini.** Tokens e custo relativo reproduzem: `batch` + `snapshot -i` = **28% / 38%** do fluxo "snapshot a cada ponto" (contexto-base 30 mil / 200 mil), o melhor fluxo do Playwright = 45% / 66%, comando-a-comando = 74% / 104% (iguais ao nó).
2. **O volume real é pequeno.** **84 chamadas** `mcp__playwright-cdp__*` em 9 dias (4 sessões, 67 KB de texto de resultado); **só 2 foram `browser_snapshot`**. O ganho por observação (§2) atinge uma fração mínima do uso; o que a troca poupa de verdade é memória (item 3).
3. **Memória (footprint, não RSS): o agent-browser pesa 4–14 MB, o MCP do Playwright 85–106 MB (direto) ou ~135 MB via `npx`**, e uma sessão viva de 20 h chegou a **283 MB**. Cada sessão com o MCP carregado paga isso mesmo sem usar o browser.
4. **Mecânica federada:** redirect e popup funcionam nas duas stacks; **iframe de outra origem: no agent-browser o `click @ref` é recusado** (só `fill` e teclado passam), no Playwright funciona.
5. **Aba própria funciona:** `browser_tabs{new}` isola dois MCPs no mesmo Chrome, com duas armadilhas medidas (§11.5). `--pin-tab` no `:9222` real: **1 aba nova, as 3 dos agentes intocadas, estado restaurado no `tab close`**.
6. **O `npx @playwright/mcp@latest` do mini estourou os 30 s do health check do Claude sob carga** (31–35 s no `initialize`, 3 de 3; o `claude mcp get` marcou "Failed to connect"; não verifiquei se uma sessão real perde a ferramenta). Fixado em 0.0.83 e lançado **direto com node** (2,8–8,9 s, 5 de 5): feito (§11.7).
7. **Não medido:** agente-com-LLM no laço, login federado real, passkey, `:9223` (§11.8).

### 11.1 Tarefa canônica: chamadas, tokens, custo (3 rodadas × 8 fluxos)

| fluxo | chamadas | resultado (o200k) | ITE B=30k | vs pw-A | ITE B=200k | vs pw-A |
|---|---|---|---|---|---|---|
| pw-A (snapshot em 4 pontos) | 11 | 15.330 | 86.178 | 100% | 290.178 | 100% |
| pw-B (snapshot em 2 pontos) | 9 | 1.724 | 42.327 | 49% | 212.327 | 73% |
| **pw-B2 (melhor do Playwright)** | 8 | 1.713 | 38.786 | 45% | 191.786 | 66% |
| ab `snapshot` (A) | 13 | 7.820 | 84.204 | 98% | 322.203 | 111% |
| ab `-c` (A) | 13 | 6.374 | 80.213 | 93% | 318.213 | 110% |
| ab `-i` (A) | 13 | 5.084 | 76.578 | 89% | 314.578 | 108% |
| ab `-i` (B, comando-a-comando) | 13 | 461 | 63.593 | 74% | 301.593 | 104% |
| **ab `batch` + `-i`** | **4** | 461 | 24.245 | **28%** | 109.245 | **38%** |

O payload é determinístico (min = máx nas 3 rodadas). Mesmo modelo de custo do §3 (ITE, estático incluído) com **K = 1,44 herdado do nó, sem recalibrar no mini**. Por página, `depth=3` no Playwright: HN 13.483 → 253, Wikipédia 70.794 → 329, login 515 → 223, lista de 40 linhas 1.722 → 1.722; `ab -i`: 160 / 4.615 / 19.010 / 484 (login / HN / Wikipédia / lista); `--delta` na lista: 80 tokens contra ~500 do `-i` completo. `results/micro.json`.

### 11.2 Latência

Mediana do fluxo inteiro em segundos [mín–máx, n=3]: pw-A 17,4 [13,6–35,5], pw-B 7,5 [3,4–23,6], pw-B2 14,1 [7,6–59,6], ab `-i` B 3,4 [1,3–11,8], ab `batch` 6,8 [5,9–15,1]. **A dispersão entre rodadas (até 8×) é maior que a diferença entre as stacks: n=3 sob load 43–74 não ranqueia.** O que se vê por chamada: no CLI cada comando é um processo (chamada "quente" de 37 ms a ~1,9 s, conforme o que a página devolve; a 1ª, que sobe o daemon e carrega a página, 1,3–5,1 s); no Playwright as ações rodam no processo já aberto e esperam a navegação (clique do login 1,5–5,5 s). Latência não decide; o que decide é o número de turnos do modelo (§3).

### 11.3 Memória no macOS (`footprint`, MB; mediana entre rodadas)

| processo | footprint | RSS do `ps` |
|---|---|---|
| Playwright MCP direto (`node`) | 85–106 | 50–118 |
| Playwright MCP via `npx` (`npm exec` + `node`, 2 proc.) | 134–136 | 64–110 |
| agent-browser, daemon Rust | 4,3–14,0 | 9,4–14,1 |
| sessões `playwright-cdp` vivas hoje (`npm exec` + `node`, ~20 h) | 110, 117 e 283 | — |

~20× menos no uso enxuto (5 MB contra ~100 MB), ~8× no pior caso do agent-browser (14 MB, depois do fluxo A) e 10–27× contra o `npx`. **O RSS não serve**: para o mesmo Node oscila de 50 a 118 MB (0,5× a 1,2× do footprint) e no daemon Rust fica acima dele. O daemon só existe enquanto se usa (`--idle-timeout`, 1 h, §5); o MCP fica carregado a sessão inteira.

### 11.4 Uso real do `playwright-cdp` (transcritos de `~/.claude/projects`, 9 dias, só agregados)

998 arquivos lidos, 0 ilegíveis, **4 sessões**, **84 chamadas** (27/10: 3; 28/10: 39; 42 sem carimbo de dia), 67 KB de texto de resultado. Por ferramenta: `browser_run_code_unsafe` 32, `browser_take_screenshot` 14, `browser_navigate` 10, `browser_console_messages` 8, `browser_evaluate` 6, `browser_tabs` 4, `browser_click` 4, **`browser_snapshot` 2**, `browser_resize` 2, `browser_find` 2. A medição de 26/09 deu 196 chamadas em 8 dias: o uso por dia caiu cerca de 2,6× (24,5 contra 9,3). O agente típico dirige o browser por `browser_run_code_unsafe` e screenshot, não por snapshot: a higiene de snapshot (já na skill) e o `-i` mexem na minoria das chamadas. Limites: só as sessões cujo transcrito ainda existe; imagens (screenshots) não entram nos bytes.

### 11.5 Aba compartilhada, aba própria e `--pin-tab`

- **Reproduz o nó, no Chrome 156/macOS:** dois Playwright MCP no mesmo Chrome ficam na **mesma aba** (o 1º passa a ver a página do 2º); o agent-browser sem pin também. Com `--pin-tab` (sessões novas): abas próprias, `tab_locked`, `tab_gone` recuperável com `tab new`, abas ficam após `close`.
- **A mitigação `browser_tabs{new}` isola** (medido; `mini/results/share-mitigation.txt`): com os dois começando por ela, ou com um já trabalhando na aba inicial e o outro chegando, cada um viu só a sua. **Duas armadilhas:** (1) `browser_tabs list` lista **todas** as abas do Chrome, as de outros agentes também: um `select 0` seguido de navegação sequestrou a aba do outro; (2) depois de `browser_tabs close` a aba atual passa para uma vizinha, que pode ser de outro agente.
- **`--pin-tab` no `:9222` real** (bead autorizando, 1 sessão, 1 aba `data:` leve, footprint 1.774 MB antes contra o teto de 4.096 do watchdog): 3 abas de agentes antes, 4 durante, 3 depois, **mesmos títulos e URLs**; footprint 1.774 → 1.804 MB. Ensaio no descartável antes: com **zero** páginas abertas o `open` cria uma `about:blank` extra que o `tab close` não leva; no Chrome real, que tem páginas, não apareceu.
- **Achados novos do `--pin-tab`:** nome de sessão reaproveitado depois de a aba sumir faz até o `open` falhar com `tab_gone` (a mensagem manda usar `tab new`); com pin o id da aba do app não é `t1` (há uma `about:blank` antes), então ids de aba têm de ser lidos do `tab list`, nunca fixos.
- **`:9223` não medido:** o túnel ssh está de pé, mas o MBP recusa a conexão na `:9222` (`connect failed: Connection refused` no log do túnel; `curl` dá http 000 em ~12–31 ms). O Chrome CDP do MBP está desligado: precisa de ação na máquina do MBP.

### 11.6 Mecânica do login federado (IdP de teste local, duas origens, `demo-user`, sem conta real)

| fluxo | Playwright MCP | agent-browser | agent-browser + `--pin-tab` |
|---|---|---|---|
| redirect (OAuth) | ✓ 7 chamadas, 900 tokens | ✓ **3** chamadas (`batch`), 290 | — |
| popup (`window.open` + `postMessage`) | ✓ 12 chamadas, 1.138 (`browser_tabs list` + `select` no popup, de volta ao índice 0) | ✓ 9 chamadas, 381 (o popup já vira a aba ativa; trocar por id `tN`) | ✓ 9 chamadas, 407 (troca explícita por id; a aba do app é `t2`) |
| iframe de outra origem | ✓ 5 chamadas, 647 (refs `f1e5`…) | **`click @ref` recusado** ("outside the viewport", também com viewport 1280×900); `fill` e `press Enter` funcionam (conferido à mão e no script; no script custou 6 chamadas, por causa das 2 tentativas recusadas) | — |
| passkey virtual | nenhum dos dois expõe WebAuthn virtual como comando (no Playwright, só por `browser_run_code_unsafe` + CDP) | não há caminho no CLI | — |

Os refs de iframe aparecem no `snapshot -i` do agent-browser e o `fill` funciona; só o clique falha, e o teclado contorna. Medido com um iframe de **outra origem** (o caso real de IdP); iframe de mesma origem não foi testado. Login federado **real** pede uma conta: agir em nome de alguém exige autorização citável (Regra 4) e não é decisão do dog.

### 11.7 Versão do `@playwright/mcp`

- **Hoje não muda comportamento:** as 3 sessões vivas rodavam 0.0.83 (mesmo cache do npx, `@latest` = 0.0.83 desde 28/09). Fixar só impede a deriva.
- **Início do servidor (spawn → `initialize`, ms):** `npx @latest` 34.809 / 33.471 / 31.350 (load 82) e 11.113 / 17.944 (load 54–75); `npx @0.0.83` no cache 23.369 / 69.214 / 45.463 (a 1ª vez, com instalação, passou de 90 s); **`node …/cli.js` direto 8.913 / 6.117 / 2.802 / 4.164 / 5.330.** O custo é o `npm exec` subindo numa máquina saturada, não só o registry: fixar a versão no `npx` não resolveria.
- **Feito:** `@playwright/mcp` 0.0.83 (`--ignore-scripts`; o `integrity` do lock é igual ao `dist.integrity` do registry) em `~/.local/share/playwright-mcp`, lançado direto com node; `claude mcp get playwright-cdp` passou de "Failed to connect" para `✔ Connected`. Antes era `npx @playwright/mcp@latest --cdp-endpoint http://127.0.0.1:9222`; para voltar: `claude mcp remove playwright-cdp -s user && claude mcp add playwright-cdp -s user -- npx @playwright/mcp@latest --cdp-endpoint http://127.0.0.1:9222`. O `install.sh` da skill reproduz a instalação (testado em HOME falso, 2 execuções: instala e depois não faz nada). Sessão viva só troca no restart.
- **Fica de fora:** o plugin `playwright@claude-plugins-official` segue com `npx @playwright/mcp@latest`, mas os overlays das sessões nomeadas o derrubam (`city.toml`, ga-e87w1f); só afeta sessões fora deles. Há ainda uma entrada velha `playwright-working` (`npx -y @playwright/mcp`) numa pasta de projeto do Drive, fora do escopo.

### 11.8 O que continua sem medida

- **Agente-com-LLM no laço** (tokens, turnos e custo reais com o modelo usando a skill): não rodei. Pede sessões `claude -p` isoladas de hooks, plugins e CLAUDE.md numa máquina a load 75, para um uso real de ~9 chamadas por dia; se o Mayor quiser, é bead própria.
- **Login federado real** e **passkey virtual**: ver §11.6.
- **`:9223`**: ver §11.5. **K do tokenizador** não foi recalibrado no mini (a razão entre formatos varia ~4%, o absoluto escala por K).

**Para o Mayor decidir.** (a) Se o objetivo é **memória** (a cidade já mediu 6 GB de footprint em 120 processos MCP, `city.toml` ga-e87w1f), o CLI vale como opção barata para os crews que de fato dirigem o browser: 5–14 MB contra 100–283 MB por sessão. (b) Se o objetivo é **token por chamada**, 84 chamadas em 9 dias não pagam uma migração; a higiene de snapshot, já na skill, cobre o que dá. A troca do MCP continua só com nova decisão.
