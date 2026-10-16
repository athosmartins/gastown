# Rodadas dos raspadores de imóveis no servidor Hetzner (ga-mqs133)

## Contents

• Por quê e o que foi medido (16/10/2026) · Quem roda no nó e quem não roda · Como usar · Códigos de saída · O que vai e o que volta · Como preparar o nó · Como re-medir · **O que esta fatia NÃO faz (e o que falta)** · Limites conhecidos

## Por quê e o que foi medido (16/10/2026)
A rodada diária dos raspadores (`com.scrapers.daily`, 00:01, `runner.py --scraper all`) roda no mini, que vive com load 40-60. O Athos quer o servidor Hetzner trabalhando "full force o dia inteiro" (15/10). O risco da bead era o IP alemão ser barrado, então o **passo 1 foi medir de lá**, do nó `hetzner-teste` (IPv4 `2.31.41.222`, IPv6 `2a01:4f8:c012:fa40::1`), com o **código implantado** em `~/.property-scrapers/runtime/main` (não o `crew/thies`, que divergiu do que o launchd roda).

**Endereços (51, `hetzner-scrape-round.sh probe`)**: 36 respondem 2xx igual do mini e do nó; 6 falham igual dos dois lados (API que não aceita GET simples, `wimoveis`, glue-api da ZAP); 1 (`netimoveis /pesquisa`) dá 404 no mini e 403 no nó; **8 só respondem do mini**: o Cloudflare devolve 403 ("Just a moment" / "Attention Required") para o IP do servidor — `chavesnamao` (2), `netimoveis`, `larimoveis`, `ciadoimovelbh`, `imobiliariamodelobh`, `nucleoleiloes` e `venda-imoveis.caixa.gov.br`.

**Rodada real no nó** (código implantado, limitada por `--limit`):

| Raspador | Resultado no nó | Decisão |
|---|---|---|
| `primeimoveisdeluxo` | 15 de 15 | permitido |
| `vistaimobi` (alianza) | 10 (3 novos, 7 fora do escopo) | permitido |
| `oksite` (eccos) | 10 | permitido |
| `luizrenato`, `santoagostinho` | 10 de 10 cada | permitido |
| `bonsucesso` | 10 tentados, 0 erro | permitido |
| `imoview` (decisao, valore) | 20 de 20 cada, em 22 s e 24 s | permitido (homes de todos os tenants ativos respondem igual) |
| `quintoandar` | 10 arquivos, 0 erro | permitido |
| `loft` (`--use-api`) | 30 de 30; a API de condomínios devolve 429 após ~15 chamadas e o raspador a desliga no meio da rodada | permitido (limite de taxa, não bloqueio de IP) |
| `silvioximenes` | 10 de 10 | permitido |
| `anuar_donato` | 40 raspados (21 novos), 0 erro | permitido |
| `zap_vivareal` (+`_contagem`) | **403 em toda chamada de listagem da glue-api; 0 arquivo em 120 s** | **bloqueado** (é a maior do mini: ~4400 s) |
| `chavesnamao`, `netimoveis`(+`_contagem`), `larimoveis`, `ciadoimovel`, `imobiliariamodelobh`, `leilao_nucleo`, `leilao_caixa` | 403 do Cloudflare já na home | bloqueados |
| `wimoveis` | 403 "Just a moment" até do mini no curl simples | bloqueado (inconclusivo; fica local) |
| `blow` | usa credencial e é Node | nunca vai ao servidor |

Duas falsas pistas desmontadas na medição, para ninguém repeti-las: `anuar_donato` ("Errors: 10") e `silvioximenes` ("JSON PARSE ERROR") falharam numa primeira rodada feita com o `crew/thies` **antigo**; um replay byte a byte no mini e no nó deu o mesmo resultado, e com o código implantado os dois passam com 0 erro. O 403 de curl simples na glue-api da ZAP vale para o mini também, então o que decidiu a ZAP foi a rodada real (403 só no nó).

**Quanto sai do mini**: dos 14 raspadores com duração medida na rodada de 16/10 (27 537 s somados, em paralelo no mini), os permitidos somam 16 371 s, **~4,5 h (59%)**: imoview 3301, vistaimobi 3288, anuar_donato 2693, luizrenato 2319, santoagostinho 1747, bonsucesso 1593, oksite 486, primeimoveisdeluxo 439, quintoandar 201, loft 177, silvioximenes 127. A duração no nó em escala cheia **não foi medida** (só as rodadas limitadas acima); o ganho é o trabalho que deixa de competir com o load do mini.

## Quem roda no nó e quem não roda
A fonte única é `scripts/hetzner-scrape-eligible.txt` (comentada com a medição). Sintaxe: `raspador` permite; `raspador:tenant` permite só o tenant; `!raspador` (ou `!raspador:tenant`) **bloqueia e vence a permissão**; o texto depois de `#` é o motivo mostrado a quem pedir. A chave é o **nome da pasta** em `scrapers/`, não o id do `runner.py` (`zap_vivareal_contagem` e `netimoveis_contagem` usam as pastas `zap_vivareal` e `netimoveis`). Raspador que não aparece **não roda** no nó: "não medi" não é "libera" (`alfenas`, `leilao_comprei`, `leilao_spy`, `mybrokerbh`, `myside`, `provincia_imoveis`, `sancruza`, `terreno_livre` nunca foram medidos).

O prod test (`story-ga-mqs133.sh`) falha se um dos bloqueados medidos virar permitido sem re-medir.

## Como usar
```bash
scripts/hetzner-scrape-round.sh check                       # bandeira, ssh, ambiente, disco do nó, código do rig e lista (chave=valor); rc 0 = pronto, 97 = o run recusaria
scripts/hetzner-scrape-round.sh eligible zap_vivareal       # BLOCK <motivo>, rc 97
scripts/hetzner-scrape-round.sh run primeimoveisdeluxo --limit 3 --stage /tmp/x      # 1 rodada em staging
scripts/hetzner-scrape-round.sh run imoview --tenant decisao -- --finalidade venda   # argumentos do raspador vão depois de --
scripts/hetzner-scrape-round.sh probe --out /tmp/matriz.txt # re-mede mini x nó (ver "Como re-medir")
scripts/hetzner-scrape-round.sh bootstrap                   # prepara o ambiente do nó (idempotente)
```
`run` imprime `stage=`, `files=` e `secs=`; o resultado fica em `$STAGE/<raspador>[-tenant]-<UTC>-<pid>/{shared/,scraper.log}` (padrão: `$CITY/.gc/hetzner-scrape/stage`). Cada rodada deixa uma linha em `$CITY/.gc/logs/hetzner-scrape.jsonl` (`why`: `ok`, `ok-sem-arquivos`, `rc-N` quando o raspador falhou, `rc-cru-N`, ou o motivo da desistência). A bandeira é a mesma do nó de testes (`$CITY/.gc/hetzner-node.on`): apagar = desligar, tudo cai para o mini.

## Códigos de saída
**96..99 sempre significam "rode local"** (mesma convenção do `mbp-run.sh`); o chamador nunca pode tratá-los como falha do raspador.

| rc | Significa |
|---|---|
| 0..94 | código do raspador, propagado |
| 95 | o raspador saiu com rc >= 95 (inclusive **124 = estourou `--timeout`**) ou o arquivo rc do nó veio ilegível; o valor cru vai SEMPRE em `scraper_rc_raw=` (`ilegivel` no segundo caso) — assim um raspador nunca "fabrica" um sinal de rode-local |
| 97 | uso errado (inclusive opção sem valor), nome inválido, raspador fora da lista **ou bloqueado**, código ou lista de elegíveis ausente (também no `check`), staging dentro da produção |
| 98 | nó indisponível ou sem condição: ssh, ambiente não preparado, disco < `HETZNER_SCRAPE_MIN_DISK_MB` (3072), conteúdo reprovado pela varredura, ssh caiu no meio (**se caiu ao disparar, a rodada PODE estar rodando no nó**: confira antes de rodar local, senão raspa em dobro) |
| 99 | desligado (falta a bandeira) |

## O que vai e o que volta
**Vai** (rsync com filtro de segurança montado por rodada; regras de segredo/dado por NOME antes de qualquer `+`, e `- *` fecha, então nome desconhecido não sai): `lib/*.py`, `config/__init__.py`, `scope.json`, os `*_tenants.json` e `scrapers/<raspador>/*.py` do raspador pedido — por caminho, nunca por extensão solta — mais, de `shared/config`, o `seen_<raspador>.json`, `seen_<raspador>_*.json` (ids de anúncios públicos) e os `<raspador>_*cache*.json` — o estado de um raspador irmão cujo nome começa por `<raspador>_` é excluído antes. **Não vai**: `.env`, credenciais, token, secret, password, cookie, session, banco, parquet, csv, `shared/data` da produção, venv, `.git` (as mesmas regras de nome valem para o código e para o estado). O **conteúdo** do que vai, código **e** estado, é varrido por `hetzner-pii-scan.py`: arquivo com lista de >=20 telefones ou >=3 CPFs derruba a rodada com rc 98 e o nó não é usado. Nenhuma credencial vai no comando; o nó não tem as do GitHub nem as do mini. O servidor é alugado: **nenhum dado de cliente, nenhum segredo**.

**Volta**: `shared/data/<raspador>/<timestamp>/`, os seen/caches atualizados e `scraper.log`, para o staging. A pasta da rodada no nó (`~/gt-remote/scrape/runs/<id>`) é apagada ao fim; as de mais de 1 dia (queda de rede) são apagadas no fim de um `run` posterior que termine (o reaper não roda se o nó nunca mais for usado com sucesso). O raspador roda **desacoplado** no nó (`setsid nohup`, `nice 5`, `timeout`): o ssh só consulta (a cada `HETZNER_SCRAPE_POLL_S`, 20 s), então uma queda de segundos não mata uma rodada de horas; `HETZNER_SCRAPE_POLL_FAILS` (15) consultas seguidas sem resposta fazem o script desistir com rc 98. Se o nó responde mas o processo sumiu sem escrever o rc (reboot do servidor, `kill -9`), o script desiste com rc 98 depois de `--timeout` + `HETZNER_SCRAPE_GRACE_S` (900 s) em vez de consultar para sempre; a pasta fica no nó e o reaper de 1 dia a apaga.

## Como preparar o nó
`hetzner-scrape-round.sh bootstrap` (sem sudo, idempotente, ~15 s com cache do `uv`): venv em `~/gt-remote/scrape/env/venv` com `requests`, `beautifulsoup4`, `pytz` e **`playwright==1.60.0`** (a mesma versão do mini, para o mesmo chromium 1223), chromium headless, e as bibliotecas de sistema que o chromium pede **sem root** — `apt-get download` + `dpkg -x` numa pasta nossa (`env/root`) e `LD_LIBRARY_PATH` em `env/libpath.txt`. Termina lançando o chromium de verdade (`CHROMIUM_OK`) e conferindo com `ldd` que não falta biblioteca. O aviso "Host system is missing dependencies ... sudo playwright install-deps" do Playwright é esperado. Se o servidor for recriado, é só rodar `bootstrap` de novo.

## Como re-medir
`hetzner-scrape-round.sh probe` mede, do mini e do nó, a home de cada raspador (`connectivity_host` do `runner.py`), o `base_url` de cada tenant ativo e as APIs conhecidas (`curl` com UA de navegador, sem cookie) e classifica: `IGUAL-OK`, `SO-O-NO-BLOQUEIA` (o nó não recebe 2xx onde o mini recebe, ou recebe uma página de desafio — "just a moment", "attention required"... — que o mini não recebe), `SO-O-MINI-FALHA`, `IGUAL-FALHA`, `DIFERE-FALHA` e `DIFERE-VERIFICAR` (200 dos dois lados com marcas diferentes: um humano olha). A palavra solta "captcha" num 200 (widget de formulário) **não** é bloqueio. O probe só mede a home: **liberar um raspador exige também uma rodada real** (`run <raspador> --limit N`) — a glue-api da ZAP mostra que a home pode enganar. Refaça quando o IP do servidor mudar.

## O que esta fatia NÃO faz (e o que falta)
Esta fatia entrega a **medição, a lista, o preparo do nó e uma rodada em staging**. Ela **não** altera o `runner.py` nem a rodada das 00:01: o `com.scrapers.daily` continua rodando tudo no mini. Falta (outras fatias; outro repositório e outro gate):
1. **Corte no `runner.py`**: o `--scraper all` passar a despachar os permitidos para `hetzner-scrape-round.sh run` (e cair no mini em rc 96..99) e **promover** o staging para `~/.property-scrapers/shared` — com trava contra a rodada local do mesmo raspador e merge dos `seen_*` (dois escritores no mesmo arquivo perdem ids).
2. **Volta do resultado**: hoje o resultado fica no staging do mini; o sync para o MotherDuck (`--sync-motherduck`, que fica no mini) lê a produção.
3. **Escala cheia**: as rodadas medidas são limitadas; a duração e o comportamento de uma rodada de horas no nó (limite de taxa dos sites, disco, `--check-pending`) ainda não foram medidos.

## Limites conhecidos
- O servidor é de um teste e o Mayor o apaga ao fim; nada aqui depende dele existir (bandeira desligada ou ssh fora = rode local).
- Datacenter reputation: o Cloudflare pode passar a barrar sites hoje liberados (ou liberar os barrados) sem aviso. A lista é um retrato de 16/10; o prod test pega a regressão do lado "bloqueado virou permitido", mas **não** o lado "permitido passou a levar 403" — uma rodada real que devolve 0 arquivo ou erro mostra isso.
- O IPv6 do nó (`2a01:4f8:c012:fa40::1`) e o IPv4 foram barrados nos mesmos sites; trocar de IP não resolve sozinho.
- Não roda raspador com credencial (`blow`, leilões com login) e não leva o `shared/data` da produção.
- Estes scripts nunca apagam o servidor (isso é do Mayor).
