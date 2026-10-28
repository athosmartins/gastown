# agent-browser × MCP `playwright-cdp` — avaliação no nó (ga-30455bt)

## Contents

• 1. Como foi medido · 2. Tokens por observação · 3. A tarefa canônica: chamadas e custo
• 4. `--delta` e o que o filtro esconde · 5. RAM · 6. Chrome compartilhado e `--pin-tab`
• 7. Custo estático · 8. Riscos e achados operacionais · 9. O que NÃO foi medido (só o mini) e o piloto proposto
• 10. Reproduzir e evidência

Bead ga-30455bt (P3, do Mayor; origem: vídeo que o Athos mandou em 28/10). Medido em 28/10/2026 no nó Hetzner (Linux aarch64, 16 núcleos), contra **um Chromium compartilhado por CDP** (headless_shell 145.0.7632.0, porta de teste 47222; o desenho é o do `:9222` do mini). agent-browser **v0.40.0** (binário oficial do GitHub, sha256 `f33b4dd9…` = o digest que o GitHub publica) e `@playwright/mcp` **0.0.83** (depende de `playwright-core 1.64.0-alpha`). Fixtures: GitHub login, HN, formulário httpbin e Wikipédia "Web browser" congelados (scripts fora, CSS inline, Chromium sem DNS externo) + uma lista própria. **Nada aqui foi rodado no mini nem no Chrome real do Athos.**

**Em 8 linhas**

1. **Veredito: piloto limitado no mini, só em modo CLI, sem trocar o MCP.** Com `batch` + `snapshot -i` o agent-browser custou **28–38%** do fluxo "snapshot a cada ponto" do Playwright e **57–63% do MELHOR fluxo do Playwright** (−37% com contexto-base de 30 mil tokens, −43% com 200 mil).
2. **O ganho vem do número de turnos, não do filtro de snapshot.** A própria cidade mediu (E8, `token-por-bead-e8.md`) que 53–72% do gasto dos builders é leitura de cache por turno. A mesma tarefa levou **4 chamadas** com `batch`, 8 no Playwright enxuto e 13 no agent-browser comando-a-comando. **Comando-a-comando ele não ganha**: com contexto de 200 mil custa 104% do pw-A e 142% do pw-B (§3).
3. **Por observação, `-i` corta 64–73%** (login 68%, formulário 64%, lista 72%, HN 66%, Wikipédia 73%). Mas **`-i` e `-c` somem com texto puro** — conferido contra o DOM: "Note 1 saved" só existe no `snapshot` completo; com `-c --delta` o resultado é `unchanged`. Erro de validação, toast e confirmação ficam invisíveis.
4. **RAM (Linux): ~11× menos que o Node do MCP direto e ~16× menos via `npx`.** Daemon Rust 11–12 MB de RSS (23 MB no pior caso, depois de ler a lista pesada) contra 117–140 MB (direto) e 192–204 MB (`npx`, 3 processos). No mini a métrica tem de ser `footprint`, nunca RSS (§5).
5. **`--pin-tab` funciona como documentado e o MCP atual NÃO isola.** Dois MCPs do Playwright no mesmo Chrome navegam a **mesma aba** (o primeiro passa a ver a página do segundo). Com `--pin-tab` cada sessão abre aba própria e recebe `tab_locked`/`tab_gone` em vez de agir na aba alheia. Custo: as abas ficam abertas depois do `close`.
6. **O modo MCP do agent-browser não serve de substituto**: 29 ferramentas = **16,9 mil tokens** de definições (4,5× os 3,8 mil do Playwright), sem campo de cdp nem de pin-tab; `--tools all` = 156 ferramentas, 88 mil tokens. O caminho viável é o CLI com uma skill (a do agent-browser tem 8,6 mil tokens; a `browser-control` da cidade, 2 mil).
7. **Sem conexão externa no uso normal** (strace de `open → snapshot → close`: só o socket local e a porta CDP). Mas é um projeto jovem e veloz (v0.40.0 saiu em 27/10, 696 issues abertas): fixar versão e sha256; `--allowed-domains` é **rejeitado** com CDP e `--auto-connect` sonda a 9222 sozinho (mesmo raio de explosão do perfil `~/.chrome-cdp`).
8. **NÃO medido (só o mini)**: footprint no macOS, uso real (transcritos), login federado real em perfil descartável, `--pin-tab` no Chrome real `:9222/:9223`, latência, agente-com-LLM no laço. Sem isso a troca continua **sem medida** (§9).

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

1. **Footprint no macOS** dos dois (`footprint -p`), não RSS.
2. **Linha de base de uso real**: chamadas `mcp__playwright-cdp__*` e tokens reais de resultado nos transcritos de hoje (a medição de 26/09 deu ~196 chamadas em 8 dias ≈ 25/dia; se for esse o volume, o ganho absoluto é pequeno).
3. **Login federado real** (redirect OAuth, popup, iframe, passkey) — em **perfil descartável**, nunca no `~/.chrome-cdp` do Athos.
4. **`--pin-tab` no Chrome real `:9222/:9223`** (≥136) com abas descartáveis.
5. Latência por chamada e **agente-com-LLM no laço** (aqui o payload é determinístico; o comportamento do modelo com a skill não foi medido).

**Sem custo de migração, hoje**: skill `browser-control` ensinar higiene de snapshot no Playwright (`depth=3` para orientar, `browser_find` para confirmar, `browser_fill_form`) e **fixar a versão** do `@playwright/mcp`.

**Piloto (se o Mayor quiser)**: um crew, **CLI**, ao lado do MCP (que não sai); skill com `batch`, `snapshot -i` + `wait --url|--text`, confirmação por `get text`/snapshot completo, `--pin-tab` + id único de sessão, `tab close` no fim, `--action-policy` para o irreversível e `--content-boundaries`; binário e sha256 fixos. Critério de saída: os itens 1–5 acima.

## 10. Reproduzir e evidência

Tudo em `agent-browser-vs-playwright-mcp-ga-30455bt/`: `README.md` (passo a passo e adaptação para o mini), `scripts/` (harness), `results/` (saídas medidas: `report.txt`, `task-*.json`, `micro.json`, `delta2.json`, `calibration.json`, `share-test.txt`, `pin-test.txt`, `compact-hides-text.txt`, `strace-connect.txt`, `probe-tools.txt`, `static-sizes.txt`). As respostas brutas por passo ficaram no scratchpad do nó (não publicadas: têm conteúdo de páginas de terceiros).
