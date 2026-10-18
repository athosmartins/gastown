# Rodadas dos raspadores de imóveis no servidor Hetzner (ga-mqs133)

## Contents

• Por quê e o que foi medido (16/10/2026) · **Rodada em escala cheia (17/10/2026)** · Quem roda no nó e quem não roda · Como usar · Códigos de saída · O que vai e o que volta · Como preparar o nó · Como re-medir · **O que esta fatia NÃO faz (e o que falta)** · Limites conhecidos

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
| `quintoandar` | 10 arquivos, 0 erro | permitido com `--limit`; **bloqueado em escala cheia por custo** (17/10, ver a seção seguinte) |
| `loft` (`--use-api`) | 30 de 30; a API de condomínios devolve 429 após ~15 chamadas e o raspador a desliga no meio da rodada | ~~permitido~~ **bloqueado em 18/10** (ver a nota abaixo) |
| `silvioximenes` | 10 de 10 | permitido |
| `anuar_donato` | 40 raspados (21 novos), 0 erro | permitido |
| `zap_vivareal` (+`_contagem`) | **403 em toda chamada de listagem da glue-api; 0 arquivo em 120 s** | **bloqueado** (é a maior do mini: ~4400 s) |
| `chavesnamao`, `netimoveis`(+`_contagem`), `larimoveis`, `ciadoimovel`, `imobiliariamodelobh`, `leilao_nucleo`, `leilao_caixa` | 403 do Cloudflare já na home | bloqueados |
| `wimoveis` | 403 "Just a moment" até do mini no curl simples | bloqueado (inconclusivo; fica local) |
| `blow` | usa credencial e é Node | nunca vai ao servidor |

Duas falsas pistas desmontadas na medição, para ninguém repeti-las: `anuar_donato` ("Errors: 10") e `silvioximenes` ("JSON PARSE ERROR") falharam numa primeira rodada feita com o `crew/thies` **antigo**; um replay byte a byte no mini e no nó deu o mesmo resultado, e com o código implantado os dois passam com 0 erro. O 403 de curl simples na glue-api da ZAP vale para o mini também, então o que decidiu a ZAP foi a rodada real (403 só no nó).

**Quanto sai do mini**: dos 14 raspadores com duração medida na rodada de 16/10 (27 537 s somados, em paralelo no mini), os 11 liberados em 16/10 somavam 16 371 s; sem o `quintoandar` (bloqueado em 17/10) são 16 170 s, **~4,5 h (59%)**: imoview 3301, vistaimobi 3288, anuar_donato 2693, luizrenato 2319, santoagostinho 1747, bonsucesso 1593, oksite 486, primeimoveisdeluxo 439, loft 177, silvioximenes 127. A duração no nó em escala cheia foi medida em 17/10 (próxima seção); o ganho é o trabalho que deixa de competir com o load do mini.

## Rodada em escala cheia (17/10/2026)
Bead ga-qeqxsb. Os 11 liberados rodaram **sem `--limit`**, juntos (11 `run` em paralelo, início 17:57Z), em staging, com **os mesmos argumentos que o `runner.py` diário passa** (`--finalidade both`, `--delay`, `--workers 8`, `--with-detail`, `--use-api`, `--radius 0.05`; sem eles a rodada não é comparável) e `--timeout 14400`. Cada resultado foi comparado arquivo a arquivo (o nome carrega id, finalidade, bairro e tipo) com o snapshot do mini das 00:01 do mesmo dia; a duração do mini é o último arquivo menos o início da pasta (aproximada, o runner não a imprime). A última rodada terminou 66 min depois da primeira; a carga do nó ficou ≤ 1,6 nos 16 núcleos nas amostras (uma a cada ~10 min), então o ritmo vem dos sites (`--delay`), não da CPU do nó.

| Raspador | Nó | Mini (≈) | Arquivos nó / mini | Do mini que o nó trouxe | Erros e bloqueio no nó | Decisão |
|---|---|---|---|---|---|---|
| `imoview` (11 tenants) | 3920 s | 3362 s | 4498 / 5044 | 4498; tenant `valore` 0 de 546 | `valore` HTTP 500 (0 arquivo, **rc 0**); `buritis` p1 ReadTimeout; `mdimoveis` p149 500; 0 × 403/429 | permitido; `valore` sozinho: 546 de 546, 0 erro, 217 s |
| `vistaimobi` | 2486 s | 2680 s | 1357 / 1337 | 1337 (100%; +20 no tenant `primer`) | 0 | permitido |
| `anuar_donato` | 3977 s | 2487 s | 1379 / 1379 | 1379 (100%) | 1 × 500 num detalhe | permitido (1,6× mais lento que o mini) |
| `luizrenato` | 1697 s | 1477 s | 702 / 695 | 686 (98,7%) | 0 erro; 16 "rate-limit gap" (mini 31) | permitido |
| `santoagostinho` | 1774 s | 1841 s | 1185 / 1191 | 1185 (99,5%) | 4 × 502 do site (mini 0); 2 arquivos sem explicação | permitido |
| `bonsucesso` | 2124 s | 2252 s | 952 / 941 | 941 (100%; +11) | 0 | permitido |
| `oksite` | 404 s | 573 s | 804 / 805 | 804 (99,9%) | 0 | permitido |
| `primeimoveisdeluxo` | 464 s | 437 s | 28 / 28 | 28 (100%) | 0 | permitido |
| `loft` (`--use-api`) | 201 s | 167 s | 9347 / 9369 | 9099 (97,1%) | API de condomínios devolve 429 e o raspador a desliga, igual no mini (linhas "condomínio DESLIGADO" em 17/10: mini 14, nó 15) | ~~permitido~~ **bloqueado em 18/10** (ver a nota abaixo) |
| `silvioximenes` | 158 s | 138 s | 549 / 549 | 549 (100%) | 0 | permitido |
| `quintoandar` | **3146 s** | **193 s** | 9688 / 9986 | 9370 (93,8%) | 25 × 503 (o mini teve 1 erro de anúncio, de qualquer status); **0** × 403/429 | **bloqueado por custo** |

**O que a escala mostrou**
- **Nenhum bloqueio de IP em escala** nos 10 que ficam: zero 403 do Cloudflare e zero 429 que o mini não tenha também. O único 429 é o da API de condomínios da Loft, igual nos dois lados.
- **`quintoandar` sai da lista** (agora `!quintoandar`, com o motivo). O site responde ao nó; o problema é custo: sem o snapshot anterior, que o nó não recebe, o raspador não usa a API em lote (`chamadas=0` contra 49 no mini) e relê 4881 páginas uma a uma (`ids_html=4881` contra 65). 16× mais lento e 25 × 503 (o mini teve 1 erro de anúncio). É o mesmo motivo do `NODE_VETO` do runner, agora também na lista.
- **`imoview`/`valore`: rc 0 com tenant inteiro falho.** O `valore` foi o primeiro tenant e levou 500 do site; o raspador imprimiu `Failed tenants: ['valore']` e saiu **rc 0** com 4498 arquivos. O wrapper registrou `ok` e o `min_expected` do runner para o `imoview` (3500) aceita 4498. Foi transitório (sozinho, 5 min depois, 546 de 546), mas mostra que uma rodada "boa" pode vir sem 11% do dia. Aberto como `ps-bvrj` (repositório property_scrapers).
- **A linha `RESULT: N scraped` conta tentativas, não arquivos** (`bonsucesso` 1479 contra 952 arquivos, com 525 fora do escopo; `santoagostinho` 1191 contra 1185, por 502 nos detalhes). Compare arquivos em disco.
- **A comparação por nome de arquivo subestima**: um anúncio que muda de bairro ou tipo entre as 00:01 e a rodada do nó aparece uma vez como "só no nó" e uma como "só no mini" (`loft`: 248 e 270).
- **11 `run` em paralelo pela mesma conexão ssh** fazem o servidor recusar novas sessões na conexão compartilhada (`Session open refused by peer`; causa provável: limite de sessões por conexão do sshd, não confirmado) e o ssh volta sozinho para conexão direta. Nenhuma rodada falhou por isso; com mais de ~10 em paralelo, espere mais ruído nos logs.
- **Duração**: o conjunto dos 10 que ficam (≈ 4,3 h de relógio somado no mini, em 17/10) saiu em 66 min no nó, em paralelo.

## Quem roda no nó e quem não roda
**Nota 18/10 (ga-hpf4w4): `loft` saiu do nó (`!loft`).** Na rodada real de 18/10, 9 dos 10 raspadores ficaram idênticos ao mini, mas o `loft` veio com 7752 em vez de ~9300 (-17,5%): HTTP 503 truncou 4 lotes e o lote foi promovido como completo (rc 0, erros 0). Volta à lista `PERMITIDOS` quando a ps-jo75 (property_scrapers) fechar. Os outros 9 seguem no nó e `.gc/hetzner-node.on` não muda.

A fonte única é `scripts/hetzner-scrape-eligible.txt` (comentada com a medição). Sintaxe: `raspador` permite; `raspador:tenant` permite só o tenant; `!raspador` (ou `!raspador:tenant`) **bloqueia e vence a permissão**; o texto depois de `#` é o motivo mostrado a quem pedir. **Sem `--tenant` o raspador roda TODOS os tenants ativos**, então um `!raspador:tenant` bloqueia a rodada inteira (o `run` e o `eligible` recusam, citam o tenant e mandam rodar com `--tenant <outro>`); `raspador:tenant` sem `--tenant` também não roda. Espaço em volta de `!` e `:` e maiúsculas são ignorados; uma linha que não seja `nome` nem `nome:tenant` (ex.: `!alpha beta`) faz o script recusar a lista **inteira** (ilegível, rc 97), porque um bloqueio que não casa liberaria em silêncio. O `--tenant` tem de vir **antes** do `--`: um `--tenant` (inteiro, abreviado como `--ten`, ou com `=`) depois do `--` é recusado, porque o raspador ficaria com o último e rodaria outro tenant que não o checado. A chave é o **nome da pasta** em `scrapers/`, não o id do `runner.py` (`zap_vivareal_contagem` e `netimoveis_contagem` usam as pastas `zap_vivareal` e `netimoveis`). Raspador que não aparece **não roda** no nó: "não medi" não é "libera" (`alfenas`, `leilao_comprei`, `leilao_spy`, `mybrokerbh`, `myside`, `provincia_imoveis`, `sancruza`, `terreno_livre` nunca foram medidos).

O prod test (`story-ga-mqs133.sh`) falha se um dos bloqueados medidos virar permitido sem re-medir.

## Como usar
```bash
scripts/hetzner-scrape-round.sh check                       # bandeira, ssh, ambiente, disco do nó, código do rig e lista (chave=valor); rc 0 = pronto, 97 = o run recusaria
scripts/hetzner-scrape-round.sh eligible zap_vivareal       # BLOCK <motivo>, rc 97 (tenant opcional, só minúsculas como no `run`: `eligible delta T9` é 97 'tenant inválido', nunca ALLOW)
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
| 97 | uso errado (inclusive opção sem valor e `--tenant` depois do `--`), nome inválido, raspador fora da lista **ou bloqueado** (inclusive sem `--tenant` quando há `!raspador:tenant`), código ou lista de elegíveis ausente, ilegível ou com linha malformada (também no `check`, que mostra `eligible_entries=ilegivel`), tenant inválido ou argumento sobrando no `eligible`, `probe` sem endereço de raspador/tenant para medir **ou com algum `*_tenants.json` ilegível** (o probe inteiro recusa, nunca pula o arquivo), staging dentro da produção |
| 98 | nó indisponível ou sem condição: ssh, ambiente não preparado, disco < `HETZNER_SCRAPE_MIN_DISK_MB` (3072), conteúdo reprovado pela varredura, `probe` em que o mini ou o nó não mediu nenhum endereço, ssh caiu no meio (**se caiu ao disparar, a rodada PODE estar rodando no nó**: confira antes de rodar local, senão raspa em dobro; o mesmo vale depois de disparado — sem rc no prazo, ssh caiu nas consultas, resultado não voltou: a pasta da rodada, e talvez o raspador, continuam no nó e a mensagem diz onde) |
| 99 | desligado (falta a bandeira) |

## O que vai e o que volta
**Vai** (rsync com filtro de segurança montado por rodada; regras de segredo/dado por NOME antes de qualquer `+`, e `- *` fecha, então nome desconhecido não sai): `lib/*.py`, `config/__init__.py`, `scope.json`, os `*_tenants.json` e `scrapers/<raspador>/*.py` do raspador pedido — por caminho, nunca por extensão solta — mais, de `shared/config`, o `seen_<raspador>.json`, `seen_<raspador>_*.json` (ids de anúncios públicos) e os `<raspador>_*cache*.json` — o estado de um raspador irmão cujo nome começa por `<raspador>_` é excluído antes. **Não vai**: `.env`, credenciais, token, secret, password, cookie, session, banco, parquet, csv, `shared/data` da produção, venv, `.git` (as mesmas regras de nome valem para o código e para o estado). O **conteúdo** do que vai, código **e** estado, é varrido por `hetzner-pii-scan.py`: arquivo com lista de >=20 telefones ou >=3 CPFs derruba a rodada com rc 98 e o nó não é usado. Nenhuma credencial vai no comando; o nó não tem as do GitHub nem as do mini. O servidor é alugado: **nenhum dado de cliente, nenhum segredo**.

**Volta**: `shared/data/<raspador>/<timestamp>/`, os seen/caches atualizados e `scraper.log`, para o staging. A pasta da rodada no nó (`~/gt-remote/scrape/runs/<id>`) é apagada ao fim; as de 2 dias ou mais (`find -mtime +1`; queda de rede) são apagadas no fim de um `run` posterior que termine (o reaper não roda se o nó nunca mais for usado com sucesso). O raspador roda **desacoplado** no nó (`setsid nohup`, `nice 5`, `timeout`): o ssh só consulta (a cada `HETZNER_SCRAPE_POLL_S`, 20 s), então uma queda de segundos não mata uma rodada de horas; `HETZNER_SCRAPE_POLL_FAILS` (15) consultas seguidas sem resposta fazem o script desistir com rc 98. Se o nó responde mas o processo sumiu sem escrever o rc (reboot do servidor, `kill -9`), o script desiste com rc 98 depois de `--timeout` + `HETZNER_SCRAPE_GRACE_S` (900 s) em vez de consultar para sempre; a pasta fica no nó e o reaper (pastas de 2 dias ou mais) a apaga. O `timeout` leva `-k 30`: um raspador que ignora o SIGTERM é morto 30 s depois e o rc (124/137) é escrito, em vez de a rodada ser dada por perdida com o processo ainda rodando.

## Como preparar o nó
`hetzner-scrape-round.sh bootstrap` (sem sudo, idempotente, ~15 s com cache do `uv`): venv em `~/gt-remote/scrape/env/venv` com `requests`, `beautifulsoup4`, `pytz` e **`playwright==1.60.0`** (a mesma versão do mini, para o mesmo chromium 1223), chromium headless, e as bibliotecas de sistema que o chromium pede **sem root** — `apt-get download` + `dpkg -x` numa pasta nossa (`env/root`) e `LD_LIBRARY_PATH` em `env/libpath.txt`. Termina lançando o chromium de verdade (`CHROMIUM_OK`) e conferindo com `ldd` que não falta biblioteca. O aviso "Host system is missing dependencies ... sudo playwright install-deps" do Playwright é esperado. Se o servidor for recriado, é só rodar `bootstrap` de novo.

## Como re-medir
`hetzner-scrape-round.sh probe` mede, do mini e do nó, a home de cada raspador (`connectivity_host` do `runner.py`), o `base_url` de cada tenant ativo e as APIs conhecidas (`curl` com UA de navegador, sem cookie) e classifica: `IGUAL-OK`, `SO-O-NO-BLOQUEIA` (o nó não recebe 2xx onde o mini recebe, ou recebe uma página de desafio — "just a moment", "attention required"... — que o mini não recebe), `SO-O-MINI-FALHA`, `IGUAL-FALHA`, `DIFERE-FALHA` e `DIFERE-VERIFICAR` (200 dos dois lados com marcas diferentes: um humano olha). A palavra solta "captcha" num 200 (widget de formulário) **não** é bloqueio. O probe só mede a home: **liberar um raspador exige também uma rodada real** (`run <raspador> --limit N`) — a glue-api da ZAP mostra que a home pode enganar. Se o mini (ou o nó) não alcançar nenhum endereço (000 em todos) o probe sai 98 em vez de imprimir uma tabela inteira de `SO-O-MINI-FALHA` (ou de `SO-O-NO-BLOQUEIA`); e um `*_tenants.json` que não parseia, ou com entrada que não é objeto, faz o probe sair 97 nomeando o arquivo. Refaça quando o IP do servidor mudar.

## O que esta fatia NÃO faz (e o que falta)
Esta fatia entrega a **medição, a lista, o preparo do nó e uma rodada em staging**. O próprio script **não** altera o `runner.py` nem a rodada das 00:01. Falta (outras fatias; outro repositório e outro gate):
1. **Corte no `runner.py`**: o `--scraper all` despachar os permitidos para `hetzner-scrape-round.sh run` (e cair no mini em rc 96..99) e **promover** o staging para `~/.property-scrapers/shared` — com trava contra a rodada local do mesmo raspador e merge dos `seen_*` (dois escritores no mesmo arquivo perdem ids). **O código existe e está implantado** (`NodeSlot` em `lib/hetzner_dispatch.py`, bead ps-toid, arquivos de 16/10 11:45; operação e como desligar: `docs/HETZNER_NODE.md` do property_scrapers). Conferido em 17/10: o script só chegou ao main às 14:07 e o plist do `com.scrapers.daily` não define `HETZNER_SCRAPE_ROUND`, então o runner usa o script padrão; **com a bandeira `.gc/hetzner-node.on` ligada, a rodada das 00:01 de 18/10 deve ser a primeira a despachar os 10 liberados ao nó e promover o resultado** (previsto pelo código, ainda não observado). Para segurar: apagar a bandeira (o script responde rc 99 e tudo cai para o mini) ou `HETZNER_SCRAPE_ROUND=` vazio no ambiente do launchd.
2. **Volta do resultado**: o sync para o MotherDuck (`--sync-motherduck`, que fica no mini) lê a produção; o que o runner promove do staging passa a estar lá.
3. ~~Escala cheia~~ **feita em 17/10** (seção acima). Ainda não medido: o comportamento do `--check-pending` e o disco do nó numa sequência de dias.

## Limites conhecidos
- O servidor é de um teste e o Mayor o apaga ao fim; nada aqui depende dele existir (bandeira desligada ou ssh fora = rode local).
- Datacenter reputation: o Cloudflare pode passar a barrar sites hoje liberados (ou liberar os barrados) sem aviso. A lista é um retrato de 16/10; o prod test pega a regressão do lado "bloqueado virou permitido", mas **não** o lado "permitido passou a levar 403" — uma rodada real que devolve 0 arquivo ou erro mostra isso.
- O IPv6 do nó (`2a01:4f8:c012:fa40::1`) e o IPv4 foram barrados nos mesmos sites; trocar de IP não resolve sozinho.
- Não roda raspador com credencial (`blow`, leilões com login) e não leva o `shared/data` da produção.
- Raspador multi-tenant pode sair **rc 0 com um tenant inteiro falho** (`imoview`: `Failed tenants: [...]`), e o wrapper registra `ok`: o rc do raspador é propagado por desenho. Quem decide se a rodada é aceitável é o runner (piso `min_expected` global, que 4498 de ~5044 atravessa). Conserto em `ps-bvrj`; até lá, depois de uma rodada despachada ao nó, olhe `Failed tenants` no `scraper.log` do staging.
- A lista é um retrato de 16/10 (probe e `--limit`) e 17/10 (escala cheia de ~14:57 a 16:04 BRT, um dia só). Uma segunda rodada em outro dia vale antes de tratar a escala cheia como definitiva: o Cloudflare pode mudar o que barra sem aviso (primeiro item acima).
- Estes scripts nunca apagam o servidor (isso é do Mayor).
