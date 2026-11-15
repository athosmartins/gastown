# Bateria noturna do WhatsApp no nó Hetzner (ga-9p6pte)

## Contents

• O que roda e quando · Instalação (precisa de root, uma vez) · Veredito e relatório
• Lotes (ga-84gkpab) · Teto de memória (ga-84gkpab) · Ids reprovados e a comparação
• Escudo do relatório (ga-84gkpab) · Vazamento medido · Limites honestos · Operação

## O que roda e quando
Todo dia às 02:00 local (`0 5 * * *`: o cron dos orders é em UTC) o order `hetzner-nightly-tests` (`packs/town-deltas/orders/`) chama `scripts/hetzner-nightly-tests.sh`:
`git archive origin/main` do WA → scratch → `mbp-run.sh --host linux` com `HETZNER_ISOLATE=1` (mesmo filtro de dados, `node_guard`, slot e supervisão do gate) → **lotes** de arquivos de `tests/`, cada um num `pytest -n auto` NOVO **dentro do netns sem rede** e de um **teto de memória** (seções abaixo) → relatório agregado ao Mayor.
Só roda no nó (`hetzner-teste`, aarch64, 16 núcleos): nunca cai no MBP nem no mini.

Por que o isolamento é obrigatório: em 04/10 um teste de branch antiga mandou um e-mail de verdade. O `runner` não tem root, o AppArmor barra userns sem privilégio e `systemd-run --user -p PrivateNetwork=yes` volta rc 0 **sem isolar** (medido). Só root consegue cortar a saída; por isso existe o helper abaixo.

## Instalação (precisa de root, uma vez)
Sem isto a bateria **não roda** (veredito INERTE toda noite). Como root no nó, com o repo em `$WA`:
```bash
install -m 0755 -o root -g root $WA/.gascity-gastown-hq/scripts/hetzner-netns-run.sh /usr/local/sbin/gt-netns-run
echo 'runner ALL=(root) NOPASSWD: /usr/local/sbin/gt-netns-run' > /etc/sudoers.d/gt-netns-run
chmod 0440 /etc/sudoers.d/gt-netns-run && visudo -cf /etc/sudoers.d/gt-netns-run
```
Prova (do mini; o `gt-iso-run` chega ao nó na primeira rodada do order, `gc order run hetzner-nightly-tests`, que sem o helper termina INERTE):
```bash
ssh hetzner-teste '~/gt-remote/bin/gt-iso-run --canary'     # tem de imprimir: GTN-ISO: isolado (sonda barrou N tentativas)
```
O canário só diz `isolado` se a sonda (TCP 1.1.1.1:53, 8.8.8.8:443, 9.9.9.9:443, UDP/DNS, interfaces além de `lo`/`gtn0`, variável com cara de segredo) não achou saída **e** o contador do nft é ≥ 1 (contador zerado = a regra não está no caminho = inerte). A evidência é o contador, não log: fora do netns inicial o kernel não loga.

## Veredito e relatório
Uma linha por noite em `$CITY/.gc/logs/hetzner-nightly.jsonl`; relatório completo em `$CITY/.gc/logs/hetzner-nightly/<dia>.md` (guardado 14 dias); e-mail ao Mayor, salvo PULADO.

| Veredito | Significa | Exit |
|---|---|---|
| COMPLETO | rodou isolado; total, falhas, **novas falhas** e duração lidos do resumo do pytest | 0 (teste que falha é dado, não falha do job) |
| INERTE | isolamento ou teto de memória não provados (helper não instalado, canário `inerte`, `GTN-CAP: inerte`, `/proc/meminfo` ilegível): **nada rodou** | 0 |
| FALHOU | nó fora, sync recusado, **algum lote NÃO RODOU** (passou do prazo dele ou do orçamento da noite, pytest morto/abortado, worker do xdist caído, resumo ilegível), total implausível, rodou sem a linha de prova (isolamento ou teto), ou **vazamento medido** (canário `nao-isolado`, ver abaixo) | 1 |
| PULADO | bandeira do nó desligada ou outra rodada em andamento (a noite PULADA deixa a linha no jsonl, sem e-mail) | 0 |

"Novas falhas" = as que não estavam na última noite **COMPLETO** (INERTE/FALHOU não avançam a referência). Primeira noite: "primeira rodada", sem comparação.
O relatório também diz o que foi instalado no nó (`gt-iso-run` e `gtn_stable_ids.py`, com sha256 e se estão commitados: eles vão da árvore de trabalho, então uma edição não commitada iria junto, e aparece como `NÃO COMMITADO`) e, quando o `git fetch` falhou, que a árvore testada pode estar desatualizada. O jsonl traz `fetch` (`ok`/`falhou`/`pulado`), `compare` (`ok`/`indisponivel`) e `batches` / `batches_ran` / `batches_skipped` `mac_only_excluded` e `node_held_excluded`.

## Lotes (ga-84gkpab)
Por que: a suíte inteira num pytest só (14 workers sobre ~4600 arquivos, ~77 mil `def test_`) cresce sem platô e o kernel a matava por OOM (rc=137) aos ~1700 s, três noites seguidas (13, 14 e 15/11). Agora:
- **Lista**: os `test_*.py` / `*_test.py` de `tests/` **da árvore que vai ao nó**, em ordem de caminho (`LC_ALL=C`), menos o que o `pytest.ini` manda ignorar (`norecursedirs`: os padrões do pytest + `crew` + `archive`; a poda é nossa porque o pytest só aplica `norecursedirs` ao *descer* numa pasta). Lista vazia, nome fora de `[A-Za-z0-9_./-]` ou falha ao pesar = FALHOU, nada rodou.
- **Mac-only fica de fora**: o `mbp-run` recusa a bateria inteira (rc 98, `mac-only`) se UM argumento casa com `scripts/hetzner-mac-only.txt` (ou `$CITY/.gc/hetzner-mac-only.learned`). Por isso a noite tira da lista os arquivos que casam (39 de 4614 em 15/11), conta-os (`mac_only_excluded` no jsonl) e o relatório diz "fora da rodada por regra do nó: N arquivos mac-only … NÃO os cobre". Lista mac-only ilegível = FALHOU, nada rodou; todos os arquivos mac-only = FALHOU (nada a rodar no nó).
- **O que o nó não recebe também fica de fora**: o `mbp-run` não manda ao nó (a) o que o filtro do rsync barra por nome/pasta e (b) o arquivo com LISTA de telefones/CPFs (`node_guard` + `hetzner-pii-scan.py`: 16 arquivos de `tests/` em 15/11). Alvo que não chega ao nó faz o pytest abortar o **lote inteiro** (rc 4, ou rc 5 "no tests ran" sob xdist, sem dizer qual arquivo), então a noite refaz a conta do `node_guard` (mesmo filtro, mesmo scanner, mesma árvore) e tira esses arquivos da lista: contados (`node_held_excluded` no jsonl), listados em `<dia>.retidos.lst` e o relatório diz "fora da rodada porque o nó não os recebe … NÃO os cobre". Falha fechada: filtro que não abre, `rsync -n` sem resposta/vazio ou varredura que não termina = FALHOU, nada rodou. Os testes que **importam** um arquivo retido falham na coleta no nó (como já dizia o `mbp-run`).
- **Corte**: lotes contíguos de até `HZN_BATCH_DEFS` (8000) `def test_` (peso do arquivo = quantos `def test_`, mínimo 1) e `HZN_BATCH_ARGS_MAX` (60000) bytes de linha de comando. Um `mbp-run` + um pytest NOVO por lote: a memória volta a zero entre lotes.
- **Orçamento**: a noite inteira cabe em `HZN_TIMEOUT_S` (12600) menos `HZN_FINAL_MARGIN_S` (300) para o relatório. Cada lote recebe `min(o que resta, HZN_BATCH_TIMEOUT_S=2400)`; com menos de `HZN_MIN_BATCH_S` (180) s restando o lote nem começa.
- **Lote que não coube = "não rodou", nunca verde.** Passou do prazo (rc 124), foi morto (rc ≥ 128), abortou, perdeu um worker do xdist, ou não imprimiu resumo → o relatório marca **NÃO RODOU** com o porquê, o veredito é FALHOU ("N de M lotes NÃO RODARAM (lista)") e o relatório diz "parcial, NÃO é o total da suíte": **a linha de base não anda e não há comparação**.
- **Transitório**: `GTN-CAP: inerte` ou falha do `mbp-run` (rc 96–98 sem causa de isolamento) tenta de novo até `HZN_BATCH_TRIES` (2) vezes, `HZN_RETRY_S` (90) s entre elas. No 1º lote, esgotadas as tentativas, a noite é INERTE (teto) ou FALHOU (mbp-run); nos seguintes o lote vira "não rodou". Vazamento (`nao-isolado`) em qualquer lote para tudo na hora (FALHOU, exit 1). Bandeira do nó desligada: no 1º lote = PULADO; no meio da rodada = lote "não rodou".
- **Agregado**: soma de passou/falhou/erros/pulados/xfail/xpass dos lotes; união dos ids reprovados (cada lote confere o próprio `GTN-FAILED`; um lote com lista inconsistente = comparação INDISPONÍVEL); duração = soma dos pytest + relógio total (a meta é o próprio orçamento `HZN_TIMEOUT_S`, medida no relógio). Contagem de saída do nft somada: contador ilegível em algum lote que rodou vira `?`, nunca zero.
- **Onde fica a saída**: por lote em `$CITY/.gc/logs/hetzner-nightly/<dia>.bNN.out` e junta em `<dia>.out`; a tabela do relatório tem `lote | arquivos | def test_ | workers | s | situação | detalhe`.
- **Escopo**: só `tests/` (como antes); os outros `testpaths` do `pytest.ini` não entram.

## Teto de memória (ga-84gkpab)
Cada lote roda dentro de `systemd-run --user --scope -p MemoryMax=<teto> -p MemorySwapMax=0` (o `gt-iso-run`, no nó). Estourar o teto mata **só aquele pytest** (o cgroup), nunca o nó; sem swap o teto é duro.
- **`-n` e teto derivados na hora**, do `MemAvailable` (nunca um número fixo): `teto = min(MemAvailable − GTN_RESERVE_MB(6144), GTN_CEIL_MAX_MB(20480))`; `workers = min((teto − GTN_BASE_MB(2048)) / GTN_PERWORKER_MB(1200), nproc − 2)`. O `WA_PYTEST_MAX_WORKERS` acompanha (o conftest do WA limita a 2 por padrão). Base 2048 e 1200 MB por worker vêm da medição de ga-84gkpab (15/11, lote de 554 arquivos / ~8000 testes, 7 workers, nó compartilhado): pico do escopo ≈ 5,8 GB = ~0,9 GB de base + 0,7–0,8 GB por worker, ~50% de folga. Os 1800/4096 anteriores eram o alvo tirado da suíte INTEIRA num pytest só (ver `hetzner-ballast.md`); em lotes não se confirmam. **Reajuste com o pico de uma noite real completa** (`memory.peak` do escopo).
- **Leitura que falha = inerte, nunca um padrão**: `/proc/meminfo` ilegível, `MemAvailable` insuficiente, `systemd-run --user` sem o controlador de memória delegado ou o cgroup sem o `memory.max` esperado → `GTN-CAP: inerte …`, exit 97, nada roda.
- **Prova do teto**: o `gt-iso-run` imprime `GTN-CAP: MemoryMax=…M MemorySwapMax=0 workers=N (MemAvailable=… reserva=… base=… por-worker=… cpus=…)` depois de ler o `memory.max` do próprio cgroup do scope. O nightly **exige** essa linha (e `GTN-ISO: isolado`) em todo lote que terminou 0/1: sem ela o lote é "sem prova" e a noite FALHOU. O relatório cita a linha do 1º lote.
- `GTN_WORKERS` explícito (quem chama escolheu: `wa-suite` do ballast, selftests) desliga o modo automático e imprime `GTN-CAP: sem-teto (…)`; **o nightly não define `GTN_WORKERS`**.
- Requisitos do nó (conferidos em 15/11): cgroup v2, controlador `memory` delegado ao gerenciador do usuário `runner`, linger ligado, sem swap. Para conferir: `ssh hetzner-teste '~/gt-remote/bin/gt-iso-run --canary'` e `ssh hetzner-teste 'cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers'` (tem de listar `memory`).

## Ids reprovados e a comparação
Os ids que falharam vêm do **plugin** `scripts/gtn_stable_ids.py`, que os imprime no fim da sessão (só no controlador do xdist): uma linha `GTN-FAIL: <id em JSON>` por id e `GTN-FAILED: n=<ids> reports=<falhas+erros>`. Não vêm da linha `FAILED <id> - <mensagem>` do resumo: o id de um parametrize pode ter ` - ` dentro (`[ADE V - Setor 4]`) e cortar no primeiro ` - ` juntava irmãos numa linha só, sem nenhum sinal. (Reproduzido com o pytest 9 + xdist de verdade. Varredura estática do revisor do gate nos testes do WA: 24 pontos de parametrize com ` - `, 5 deles com irmãos que colidiriam.)
O script confere o que leu: o número de linhas `GTN-FAIL` tem de ser `n`, `reports` tem de ser as falhas + erros do resumo do pytest, a linha `GTN-FAILED` tem de aparecer **uma** vez e toda `GTN-FAIL` tem de ser JSON. Qualquer divergência, ou a ausência da linha, vira **comparação INDISPONÍVEL**: o relatório diz o porquê, a linha de base **não anda** e nunca sai "0 novas". "Zero falhas" só vale com `n=0 reports=0` e o resumo também dizendo zero.
A linha de base é `$CITY/.gc/logs/hetzner-nightly/last-complete.failed` (um id em JSON por linha, `jq -r . last-complete.failed` para ler) com `last-complete.meta`; a limpeza de 14 dias **não** apaga esses dois. Uma linha de base em outro formato dá "comparação indisponível" (e é substituída pela de hoje, se a de hoje for confiável).

## Escudo do relatório (ga-84gkpab)
O mesmo plugin envolve a montagem do relatório de cada teste (`pytest_runtest_makereport`) por fora. Motivo (trial de 15/11): o `conftest.py` raiz do WA roda `git ls-files` dentro desse hook quando um teste reprova com `FileNotFoundError` (wa-fsatxi); o teste `test_alimentador_lista_ok_false_alarme_wa_79apps.py::test_aviso_liga_strict_exit_e_o_timeout_cobre_o_autodispatch` troca `subprocess.run` por um falso (`stdout=None`) **e** lê `scripts/notify`, que o nó não recebe. O `r.stdout.split(...)` do conftest levanta `AttributeError`, o worker do xdist sai e o controlador aborta a sessão inteira (rc=3, `INTERNALERROR`): 7.997 testes do lote 1 perdidos por causa de um. No mini o arquivo existe, o hook nem corre e ninguém vê. Reproduz em ~30 s com o arquivo sozinho no nó (`-n 0`).
Com o escudo, se um hook da suíte levantar exceção ao montar o relatório, o relatório é refeito do jeito padrão do pytest, **sem o hook que quebrou**: o teste continua **reprovando** (o arquivo falta de verdade no nó), nada vira verde, só deixa de derrubar o lote. A saída leva `GTN-ESCUDO: um hook da suíte quebrou ... em <id>` (e a seção `GTN-ESCUDO` na falha) e o controlador imprime `GTN-ESCUDO: n=<quantos>` junto dos `GTN-FAIL` (só quando n > 0). Se nem o relatório padrão sai, a exceção original segue adiante: o lote aborta e fica "não rodou", como antes.
A correção de fato é de uma linha no `conftest.py` do WA (tratar `stdout` que não é texto como "não sei" em `_filtrado_pelo_espelho`); o escudo cobre essa e qualquer outra quebra do mesmo tipo até lá. Teste: `scripts/gtn_stable_ids.selftest.sh` (escudo com `-n 2` e `-n 0`; o mutante sem o escudo reproduz o rc=3).

## Vazamento medido
`GTN-ISO: nao-isolado ...` no canário = a sonda **saiu** pela rede (ou achou interface/segredo). Não é "falta instalar o helper" (isso é `inerte`): o isolamento existe e **não segura**. A noite termina FALHOU, exit 1, assunto "VAZAMENTO MEDIDO", e a suíte não rodou. Antes de reativar: rode `ssh hetzner-teste '~/gt-remote/bin/gt-iso-run --canary'` à mão e leia o que a sonda achou na linha `GTN-ISO: nao-isolado ...`: `tcp:<ip>:<porta>` ou `udp:<ip>:<porta>` (conectou), `dns` (resolveu nome), `if:<interfaces>` (há interface além de `lo`/`gtn0`) ou `env:<variáveis>` (variável com cara de segredo). Confira também se o `/usr/local/sbin/gt-netns-run` instalado é o do repo (`diff` com `scripts/hetzner-netns-run.sh`). Não reative a bateria antes de entender o que vazou.

## Limites honestos
- **"Sem rede" é um network namespace, só isso.** Soquetes unix do sistema de arquivos (spool de um MTA local, D-Bus, `docker.sock`) não são cobertos nem pelo netns nem pela sonda do canário: um teste que escreva num deles ainda alcança o serviço do nó que o expõe. Não conferi quais desses existem no nó; o canário não tem sonda para eles.
- O helper de root **nunca rodou num kernel real**: o selftest usa stubs. A prova de que ele isola é o canário no nó, depois da instalação. Os critérios "zero conexões de saída" e "1ª rodada completa registrada" só se confirmam na primeira noite COMPLETO.
- A suíte tem ~18 erros de coleta de base (`--continue-on-collection-errors`) e falhas que só existem no macOS (launchd etc.). A linha de base já os inclui; o sinal útil é "novas vs a noite anterior", não o total absoluto.
- Sem o helper instalado, o e-mail INERTE chega toda noite; para calar, desligue o order ou a bandeira do nó (abaixo).
- O lock da rodada (`$CITY/.gc/hetzner-nightly.lock`) vale enquanto o pid está vivo **e** o lock tem menos que prazo + 30 min; mais velho que isso é um pid reaproveitado depois de uma queda e é tomado (com aviso no log). Um dono legítimo morre pelo prazo (`HZN_TIMEOUT_S`, 2 h 30), então não confunde com rodada em andamento.
- Não há piso relativo ao total da última noite COMPLETA: o piso é fixo (`HZN_MIN_TOTAL`, 1000), muito abaixo dos ~68 mil testes esperados; uma rodada que execute só uma fração da suíte e passe do piso ainda é COMPLETO. O sinal para isso é o total no relatório.
- Prazo 12600 s (3 h 30; a ordem tem 13500 s e começa 05:00Z, então termina antes do `hetzner-node-reseed` das 08:55Z): medido em 15/11, de dia, com o nó a load ~18, os 4 primeiros lotes de ~8000 testes levaram 1113 / 947 / 868 / 1353 s com 10, 10, 13 e 13 workers (média ~1070 s: 10 lotes ≈ 11000 s, e foi isso que não coube nos 9000 s anteriores: a rodada manual chegou ao lote 5 com 4082 s de orçamento e 6 lotes por fazer, ~6400 s de trabalho, e foi interrompida). O tempo do lote NÃO segue o número de workers (13 workers levaram mais que 10): segue o que o lote testa. Antes, com 7 workers, ~1200 s por lote, dos quais ~500 s são COLETA (cada worker do xdist coleta todos os arquivos do lote; ~0,5 s por arquivo) — a coleta se repete em todo worker e em todo lote, por isso mais lotes não encurtam a noite; só mais workers encurtam a execução. O relatório traz segundos e workers por lote. O `WA_PYTEST_MAX_WORKERS` é necessário porque o conftest do WA limita a 2 workers por padrão; o `gt-iso-run` o define a partir do `-n` derivado.
- As pastas antigas em `/dev/shm` do nó (de rodadas anteriores à correção) **não são limpas por este script**; limpeza é de outro item.
- Determinismo da coleta (xdist aborta com "Different tests were collected" se os workers discordam): ids com horário/época e a ordem de parâmetros por hashseed causavam isso. O plugin `scripts/gtn_stable_ids.py` normaliza os ids (e imprime os ids reprovados, seção acima) e `PYTHONHASHSEED=0` fixa a ordem: duas coletas completas (68.479 testes) deram diff vazio. Não provado: a comparação entre workers numa rodada real.

## Operação
```bash
gc order show hetzner-nightly-tests                       # Source tem de ser .../packs/town-deltas/orders/...
tail -3 $CITY/.gc/logs/hetzner-nightly.jsonl              # um veredito por noite
gc order run hetzner-nightly-tests                        # rodar agora (precisa do helper instalado, senão INERTE)
# desligar: acrescente "hetzner-nightly-tests" à lista `skip` de `[orders]` no city.toml (ou apague a bandeira $CITY/.gc/hetzner-node.on: a noite vira PULADO, sem e-mail)
# (ga-84gkpab.1 desligou-o em 15/11 até o redesenho em lotes; o aceite de ga-84gkpab é uma noite verde no jsonl e tirar o nome da lista `skip` no mesmo deploy)
bash scripts/hetzner-nightly-tests.selftest.sh && bash scripts/hetzner-iso-run.selftest.sh && bash scripts/hetzner-netns-run.selftest.sh
# o único que roda o pytest + xdist DE VERDADE (precisa de um python com os dois: GTN_PYTHON; sem ele sai 3, "NÃO RODOU", nunca 0):
bash scripts/gtn_stable_ids.selftest.sh
```
Referências: `docs/runbooks/mbp-offload.md` (seção do nó Linux, filtro de dados, `node_guard`), `scripts/hetzner-netns-run.sh` (o que o comando enxerga dentro do netns).
