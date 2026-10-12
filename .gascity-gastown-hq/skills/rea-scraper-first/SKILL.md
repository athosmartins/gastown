---
name: rea-scraper-first
description: Use when you are about to build a NEW scraper/collector, or to fix a BROKEN one ("coleta falhou", "job falhou", scraper quebrou, autoconserto de scraper), or to learn how a site loads its data — before writing HTML parsing or browser automation, do ONE time-boxed REA pass (the `rea` CLI) to find the endpoint the site itself serves openly and its own front end calls, and record it as a `REA:` line on the bead. Gas City programa REA (epic ga-oe7o1p); loaded by wa-worker and ps-worker.
---

# rea-scraper-first — uma passada de REA antes de escrever (ou consertar) um scraper

Regra do Athos (11/10): todo scraper novo e todo conserto de scraper quebrado começam com uma passada de REA registrada na bead. Um scraper que lê o endpoint que o próprio front-end do site já chama costuma ser mais estável e mais barato de manter que um que raspa HTML ou dirige um navegador.

## Contents

- Quando usar
- Regras do programa (escopo e parada)
- Antes de começar: a máquina
- Passo a passo
- Navegador descartável
- Segredos e LGPD
- Registrar na bead: a linha REA:
- Quando parar e levar ao Athos
- O que NÃO fazer
- Refs

## Quando usar

- **Scraper novo** (coletor do PS, fonte externa do WA): a passada vem ANTES de escolher a abordagem.
- **Conserto de scraper quebrado** (bead de autoconserto: "Coleta {id}: ..." no PS, "job falhou" no WA): 20 min de REA **em paralelo ao restauro** — nunca atrasa o conserto. "REA: sem achado (time-box)" é um resultado aceito.
- **Não é esta skill:** APK, app nativo, Electron e WhatsApp on-device (outras beads do programa; o CLI completo está na skill `reverse-engineer-anything`).

## Regras do programa (escopo e parada)

- **Escopo:** achar o endpoint que o próprio site/app já serve abertamente e que o front-end dele chama.
- **PARE** se o único caminho exigir vencer uma proteção: captcha, desafio anti-bot, login de conta paga ou do gov.br. Não use a skill `captcha-solve` aqui (ela serve a outro propósito: emitir certidões) — vá para "Quando parar e levar ao Athos".
- **REA é CLI** (`rea --help`, `rea <comando> --help`). Nunca registre como MCP: o servidor MCP custa 278 MB por sessão.
- **Não rode `rea update` nem `rea --update`.** A versão está fixada em 6.4.0 (e leva um patch local de prazo): atualizar troca o pacote sem revisão e apaga o patch. Update só por bead que lê o changelog; se desconfiar, `scripts/rea-patch.sh check` (rc 0 = versão e patch ok; rc ≠ 0 = pare e avise o Mayor). Detalhe: `docs/runbooks/rea-versao-fixa-e-patch.md`.
- **Não rode `rea setup`.** Nesta máquina o `rea doctor` mostra `healthy: false` (Hopper e IDA ausentes, JDK do Ghidra ausente, e os registros de cliente MCP em `config_drift`) e sugere `rea setup`, que registraria o MCP. Para web isso é ruído: o que importa é o `rea` responder e os checks `node` e `host` estarem ok.

## Antes de começar: a máquina

Os três ao mesmo tempo, senão **espere** (não pule):

- `df -h /System/Volumes/Data` com 10 GB livres ou mais;
- swap usado até 6 GB (`sysctl -n vm.swapusage`);
- nenhum outro `rea` rodando (`pgrep -fl 'bin/rea '`).

Trabalho pesado (APK, Electron, nativo) vai para o MacBook Pro com `scripts/mbp-run.sh --exec` quando a chave estiver ligada (`scripts/mbp-offload.sh status`); rc 96..99 = rode local. O recon web leve desta skill não precisa disso.

## Passo a passo

1. **Máquina** (acima) e **navegador descartável** (abaixo) de pé numa porta sua, `$PORT`.
2. **Listar alvos:** `rea list-browser-targets http://127.0.0.1:$PORT` e anote o `targetId` da página. (`--allowed-origins` restringe a um site; formato em `--help`.)
3. **Observar enquanto você navega:** `rea observe-web-session http://127.0.0.1:$PORT <targetId> --observation-ms 20000` e, DENTRO dessa janela, abra/percorra a página com puppeteer-core ou playwright-core apontando para o MESMO `$PORT`. A observação é passiva: o REA não clica nem navega, e não vê o que aconteceu antes de anexar.
4. **Forma das respostas:** `rea inspect-web-page http://127.0.0.1:$PORT <targetId> --include-json-body-shapes` (estrutura dos JSON, sem valores).
5. **Rotas que a tela ainda não chamou:** `rea analyze-web-bundle http://127.0.0.1:$PORT <targetId> --fetch-source-maps` (análise estática dos bundles: base de API e rotas). Para uma captura já salva, `rea export-web-scripts <captura.json absoluto> <diretório absoluto que ainda não existe>`.
6. **Confirme como visitante anônimo:** chame o endpoint achado com `curl` sem cookie nem cabeçalho de autorização. Respondeu com os dados → **achado**. Exigiu cookie/token de sessão, captcha ou login → não é achado: pare. Se o único obstáculo for um token que a própria página entrega a qualquer visitante (ex.: CSRF/anônimo), anote isso na linha `REA:` e só siga se ele vier sem desafio anti-bot; na dúvida, trate como proteção e pare.
7. **Registre** a linha `REA:` (abaixo), **limpe** (navegador + scratch) e siga com o scraper.

Flags e formatos exatos: `rea <comando> --help`. Os comandos acima são os de web do `rea` instalado (conferidos em `rea --help`).

## Navegador descartável

Sempre um Chrome NOVO, com perfil novo e porta sua. **Nunca** o Chrome do Athos: 9222 (mini) e 9223 (MBP) carregam as sessões reais logadas dele.

```bash
SCR="<scratchpad da sessão>/rea-<bead>"; mkdir -p "$SCR"          # fora de qualquer repo
PORT=9301                                                          # livre: lsof -nP -iTCP:$PORT -sTCP:LISTEN vazio; NUNCA 9222/9223
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new \
  --user-data-dir="$SCR/profile" --remote-debugging-port=$PORT \
  --no-first-run --no-default-browser-check about:blank >/dev/null 2>&1 &
CHROME_PID=$!
# ... passos 2-6 ...
kill "$CHROME_PID"; safe-clean "$SCR"                              # no fim, SEMPRE (inclusive se parar no meio)
```

Para dirigir a página, use os snippets de conexão da skill `browser-control` — **cópia viva:** `/Users/athos/gt/.gascity-gastown-hq/skills/browser-control/SKILL.md` (é a que a sua sessão carrega por symlink; a de `~/.claude/skills/browser-control` é a pessoal do Athos e diverge). Leia antes as seções "Resolução dos módulos no mini (pré-requisito)" e "Blast radius / segurança (LER)", e troque o endpoint dos snippets por `http://127.0.0.1:$PORT`.

## Segredos e LGPD

- Capturas e perfil ficam só no scratchpad da sessão, fora dos repos, e são apagados no fechamento (`safe-clean <caminho absoluto>`; `rm -rf` direto trava a sessão num pedido de aprovação).
- A saída do `rea` omite por desenho cookies, cabeçalhos de autorização e valores de storage, mas **não presuma que vem limpa**: a doc do REA diz que URLs locais mantêm valores de query string, e `--include-script-sources` traz o texto dos scripts — chave de API embutida em URL ou em JS pode aparecer. Releia a saída antes de citar qualquer trecho; não cole isso em bead, mail, nudge nem commit.
- Se a resposta do endpoint trouxer dado pessoal de terceiro (CPF, CNPJ, telefone), não guarde a resposta: registre só o esquema.

## Registrar na bead: a linha REA:

Um comentário que COMEÇA com `REA:` — alvo, comando, achou ou não achou, por quê. Só alvo, comando, caminho do endpoint (sem valores de query) e formato da resposta (nomes de campo, nunca valores). Nunca token, cookie, JWT, CPF/CNPJ.

```bash
bd -C <rig-da-bead> comment <bead> "REA: loja.example.com; observe-web-session + inspect-web-page --include-json-body-shapes; ACHOU GET /api/v2/listings?page=N (JSON: items[], total, next); responde anônimo, sem cookie; vira a fonte do scraper no lugar do HTML."
bd -C <rig-da-bead> comment <bead> "REA: portal.example.gov; observe-web-session + analyze-web-bundle; NÃO ACHOU — a listagem vem renderizada no servidor, sem chamada de dados; sem achado (time-box 20 min)."
```

Para scraper novo as beads do programa (ps-2ymk, wa-iuqow1, ps-0gsi) não fixam um teto — os 20 min são do autoconserto: escolha um e escreva-o na linha. Quando o playbook do rig já tiver o campo "REA tentado?" (beads ps-2ymk e wa-iuqow1 do programa; ainda abertas), registre lá também. Ao fechar a bead do scraper, deixe o placar antes×depois que o programa exige.

## Quando parar e levar ao Athos

Parou por captcha, anti-bot, login pago ou gov.br? Não avance e não "só tente". Três passos, nesta ordem:

1. `bd -C <rig-da-bead> comment <bead> "REA: <alvo>; <comando>; PAREI — o único caminho exige <captcha|anti-bot|login pago|gov.br>."`
2. `bd -C <rig-da-bead> update <bead> --set-metadata athos.acao="<o que ele escolhe, 1-3 linhas, em produto>"`
3. `bd -C <rig-da-bead> label add <bead> next-action:athos`

A pergunta é de múltipla escolha, com a sua recomendação em 1º e o tradeoff de cada opção, por exemplo: (1) manter o scraper atual com fallback com data, sem o endpoint — recomendado: sem risco, mas continua mais caro de manter; (2) autorizar tentar o caminho protegido — ganha o endpoint, mas é exatamente o que o programa decidiu não fazer; (3) outra instrução.

## O que NÃO fazer

- `rea setup`, `rea update`/`rea --update`, registrar o REA como MCP, ou usar a skill `captcha-solve` neste fluxo.
- Anexar a 9222/9223, ou a qualquer Chrome que não seja o seu descartável.
- Rodar com menos de 10 GB livres, swap acima de 6 GB, ou com outro `rea` ativo.
- Interagir com o site além de ler: nada de enviar formulário, criar conta ou disparar ação; ritmo de visitante humano, sem rajada.
- Deixar Chrome, perfil ou captura vivos depois de terminar ou de parar.
- Fechar a bead sem a linha `REA:`.

## Refs

- Épico do programa: `ga-oe7o1p` (decisões do Athos de 11/10). Esta skill: `ga-ttl3y2`.
- Skill `reverse-engineer-anything` (o CLI inteiro; `references/runtime-observation.md` descreve a observação passiva de navegador).
- Skill `browser-control` (cópia viva em HQ) e `docs/runbooks/mbp-offload.md` (MBP, `mbp-run.sh --exec`).
