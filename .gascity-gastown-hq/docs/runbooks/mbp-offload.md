# MBP como nó de capacidade (offload de testes e REA/APK)

## Contents

• Por quê e resultado medido (11/10/2026) · Como ligar e desligar · Como usar
• Revisor do gate (ga-xm1jfl) · Códigos de saída · O que mora no MBP (`~/gt-remote`) · Manutenção
• Limites conhecidos

## Por quê e resultado medido (11/10/2026)
O mini vive com load 40-60, swap alto e o Dolt único; o MacBook Pro (16 GB, 12 CPUs, ~130 GB livres) estava ocioso.

| Medida | Mini (carregado) | MBP via `mbp-run.sh` |
|---|---|---|
| 231 testes de lot_groups (11 arquivos) | 340 s de relógio (213 s só de testes, `nice 15`) | 11 s de relógio (4,5 s de testes) |
| 20 testes do property_scrapers | 6,4 s | 5,7 s (sem ganho: teste leve) |
| REA `analyze-javascript-application` do Bitwarden (asar de 50 MB) | falhou 2× (timeout do helper Swift e `provider_timeout` sob load 50) | rc 0 em 75 s, evidência de 12,8 MB |

O ganho vem de rodar o que é pesado (testes grandes, REA/Ghidra/Java, APK) fora do mini. O que NÃO sai do mini: Dolt, fila do Pilot, polling do `gc`/`bd`, daemons de produção.

## Como ligar e desligar
A chave é o arquivo-bandeira `$CITY/.gc/mbp-offload.on` (CITY=`/Users/athos/gt/.gascity-gastown-hq`).
```bash
scripts/mbp-offload.sh on        # liga
scripts/mbp-offload.sh off       # desliga: mbp-run.sh sai 99 e todo mundo roda local
scripts/mbp-offload.sh status    # estado, saúde do MBP (RAM, pressão, swap), últimas 5 linhas do log e recusas das últimas 72 h por motivo
scripts/mbp-offload.sh status --json   # insumo do botão do painel (bead própria, mockup antes)
scripts/mbp-offload.sh counts    # só a contagem de execuções e recusas por motivo das últimas 72 h (não fala com o MBP)
```
Sem daemon; o único launchd é o reseed noturno (ver Manutenção), que respeita esta chave. O botão do painel só chama este script.

## Como usar
```bash
# testes dirigidos (NUNCA a suíte inteira) — repo wa ou ps, worktree = diretório atual por padrão
scripts/mbp-run.sh --repo wa --dir <worktree> -- tests/test_x.py tests/test_y.py -q
# comando pesado (REA/APK): roda em ~/gt-remote/exec/<slot>, scratch apagado no fim
scripts/mbp-run.sh --exec --push /caminho/app.asar --pull out.json:/scratch/ -- \
  sh -c 'rea analyze-javascript-application in/app.asar --integrity-policy record-and-continue --json > out.json'
scripts/mbp-run.sh --check       # saúde do MBP
scripts/mbp-run.sh --seed wa|ps  # (re)semeia base + site-packages (com checagem de hash)
```
Quem chama trata rc 96..99 como "rode local", nunca como teste reprovado.

Os workers de pool (wa-worker e ps-worker) recebem essa regra no preâmbulo: seção guardada `mbp-offload-tests` do fragment `town-deltas` (ga-yvs19w), registrada em `doctrine.guarded` do `pool-roles.json` com `show_unset: false` — Mayor, crews, dog e revisores não a recebem. Com a chave desligada o `mbp-run.sh` sai 99 e o worker roda local, então a linha é segura mesmo com o offload off.

## Revisor do gate (ga-xm1jfl)
O revisor do gate gastava ~9,6 de 20,5 min por sessão rodando/esperando teste no mini (ga-bk5j8u). Ele monta um worktree no scratchpad e roda `python3 -m pytest` (medido nas 40 últimas transcrições: nunca `pytest` solto — por isso um atalho no PATH não pegaria nada). A troca é um comando explícito, anunciado no prompt da tarefa (parágrafo `TEST WRAPPER`, depois de `RUNNING TESTS`):
```bash
scripts/gate-pytest.sh --dir <worktree> -- tests/test_x.py tests/test_y.py -x -q   # a última linha: gate-pytest: ran=mbp|local|mbp+local rc=N secs=N ...
```
**Em que o revisor acredita.** Só em verde do MBP. O MBP não tem `shared/data`, `.env` nem o python3 do mini, então vermelho ou teste pulado lá pode ser do ambiente:
| Resultado no MBP | O que o wrapper faz | rc final |
|---|---|---|
| verde, nada pulou | vale o MBP, e o wrapper imprime `nota: verde do MBP aceito...` (esse verde pode ter passado vazio: veja Limites conhecidos) | 0 |
| verde com pulados | os alvos que pularam rodam aqui. O dono de um skip é o caminho impresso em `SKIPPED [n] caminho:linha:`, e só vale se for um alvo pedido: skip vindo de um helper (o `pytest.skip()` dentro de um módulo de apoio sai com o caminho DO HELPER), linha que o wrapper não lê ou resumo que diz mais pulados do que as linhas listam → TODOS os alvos rodam aqui (`skips-fora-dos-alvos` / `skips-nao-contados`). Mesma saída para um `-r` próprio do revisor ou um `--no-summary` (que apaga as linhas `SKIPPED` e, com `-qq`, a linha-resumo): sem relato legível não há como saber que nada pulou (`skips-ilegiveis`). Se só ALGUNS alvos pularam, os que não pularam NÃO rodam aqui: o verde deles é aceito como veio do MBP e sai a mesma `nota: verde do MBP aceito como veio SÓ para os alvos que não pularam...` | o da execução daqui |
| vermelho (rc 1) | os node ids que falharam rodam aqui primeiro. Reprovam também: vale esse rc 1 (`local-confirmou`). Passam isolados: isso não prova que o vermelho era do ambiente (um `-x`/`--maxfail` parou o MBP no 1º vermelho e o resto não rodou; falha de ordem; flake; arquivo que pulou na mesma execução), então o **comando inteiro** roda aqui (`isolado-passou;inteiro-rc=N`). Se algum id reprovado não é de um alvo pedido (conftest/plugin que coleta outro arquivo, ou linha lida errado), nenhum id roda isolado e o comando inteiro roda aqui (`ids-fora-dos-alvos`) | o da execução daqui |
| 96..99 (off, sem saúde, config, slots cheios) ou qualquer rc estranho | o comando inteiro roda aqui, igual ao de hoje | o da execução daqui |
Em todas as linhas o rc final é o da execução feita **aqui**, exceto numa: o verde do MBP é aceito como veio para os alvos que ficaram verdes lá e não pularam (todos eles, ou só os que não pularam quando outros pularam); esse verde nunca é reconferido aqui e por isso sai sempre com a linha `nota:`. "Não sei" nunca vira verde. Só um vermelho que também some no comando inteiro daqui termina em rc 0.
Ficam aqui desde o começo, **alvo a alvo** (o que fica não arrasta os outros): arquivo que cita `shared/data` em linha de código (comentário não conta — medido: um arquivo que só citava no comentário passa em 1,2 s no MBP e levava ~20 s aqui), arquivo na lista `scripts/gate-pytest.force-local` (globs, um por linha; espaços nas pontas, CRLF e a última linha sem quebra de linha são aceitos; lista AUSENTE, ilegível ou que é um diretório não é lista vazia: nada vai ao MBP e a saída traz um `AVISO`, `lista-force-local-ilegivel`), arquivo que não dá para ler (`alvo-ilegivel`), diretório como alvo, flag que depende do disco daqui (`--junitxml`, `--basetemp`, `--cov-report`, `--rootdir`...) ou do plugin de cache (`--lf`, `--ff`, `--nf`, `--sw`, `--cache-clear`, `--cache-show`, `--lfnf`...), caminho fora do worktree, repo que não é wa/ps (o repo vem do `git-common-dir`; o nome do diretório do worktree não conta). O comando que roda aqui é `python3 -m pytest <args do revisor>` e nada além (sem `-p no:cacheprovider`: com o plugin de cache desligado o pytest recusa as opções acima, rc 4). O wrapper nunca devolve 96..99: o revisor só vê o rc do pytest (0..5), o do shell se o processo daqui morre por sinal ou falta o python3 (137, 126, 127) e 4 = uso errado.
**Chaves.** `touch $CITY/.gc/gate-pytest.off` desliga SÓ este caminho e tira o parágrafo do prompt na próxima tarefa gerada (apague para religar); `mbp-offload.sh off` desliga tudo, e o parágrafo some pelo mesmo motivo. Com qualquer das duas, o prompt do revisor é byte-idêntico ao de antes (selftest `gate-test-wrapper-rules.selftest.sh`).
**Registro.** Cada execução acrescenta uma linha em `$CITY/.gc/logs/gate-pytest.jsonl`.
**Medido ao vivo (12/10, WA, mini com load 88):** 4 arquivos / 122 testes de lot_groups: 75 s rodando local (hoje) → 8 s pelo wrapper (MBP quente). Com 1 arquivo que lê dado de verdade, a divisão deu 38 s (6 s MBP + 31 s aqui). Vermelho só-de-ambiente: o MBP reprova, o id roda aqui e passa, então o comando inteiro roda aqui e, se ele também passa, o wrapper devolve 0 com `AVISO` (`isolado-passou;inteiro-rc=0`); se o inteiro reprova, rc 1 (`isolado-passou;inteiro-rc=1`); vermelho real: rc 1, `local-confirmou`. (Antes da rodada de correção do gate, o `AVISO` devolvia 0 logo após o id passar isolado, o que escondia o vermelho de `-x` e o de teste pulado na mesma execução.)
**Reconferido pelo build do wrapper (12/10, mini com load 55, ssh de verdade, não stub):** 3 arquivos / 54 testes de lot_groups: 76 s locais → 15 s pelo wrapper com o MBP quente (pytest levou 1,8 s lá) e 41 s na primeira chamada de um worktree novo (rsync frio). Vermelho de verdade: o `FAILED` real foi lido, o id rodou aqui e o wrapper devolveu rc 1 com `local-confirmou`. Teste pulado de verdade: o `SKIPPED` real foi lido, o arquivo rodou aqui, rc 0 com `skips-no-mbp:1`.

## Códigos de saída
0..95 = rc do pytest/comando remoto (propagado) · 99 offload desligado · 98 MBP indisponível ou sem saúde (veja o critério abaixo) · 97 configuração (uso errado, base ausente → `--seed`) · 96 três slots ocupados.
Limiares ajustáveis por ambiente: `MBP_MIN_AVAIL_MB`, `MBP_MAX_PRESSURE_LEVEL`, `MBP_MAX_SWAP_GROWTH_MB`, `MBP_SWAP_SAMPLE_S`, `MBP_MAX_SWAP_MB`, `MBP_MIN_BATT`, `MBP_MAX_SLOTS`, `MBP_RUN_TIMEOUT_S`.

### Critério de saúde do preflight (ga-9e2rjh)
O preflight faz UMA chamada ssh e recusa (rc 98) por um destes motivos; cada recusa vira uma linha no log com o campo `reason`:

| `reason` | Recusa quando | Padrão |
|---|---|---|
| `inalcancavel` | ssh não respondeu em 5 s ou caiu | — |
| `ram` | RAM disponível (free+inactive+speculative) abaixo do mínimo | 3072 MB |
| `pressao` | nível de pressão de memória do kernel acima de normal (1 normal, 2 aviso, 4 crítico) | nível 1 |
| `swap_cresce` | o swap usado CRESCEU mais que o limite entre duas leituras | 128 MB entre duas leituras com 2 s de intervalo (~3 s de relógio, medido) |
| `swap_teto` | swap usado igual ou acima do teto absoluto | 8192 MB |
| `bateria` | na bateria (sem tomada) com carga igual ou abaixo do mínimo | 40% |
| `ilegivel:<campo>` | o MBP não deu para ler `avail`, `pressure`, `swap_delta`, `swap`, `power` (tomada ou bateria) ou, na bateria, `batt` (a carga) | — |

O swap usado, sozinho, NÃO recusa até o teto: o macOS não devolve swap depois de uma pressão, então um valor alto e parado não diz nada sobre a pressão de agora. Campo ilegível recusa com motivo próprio (`ilegivel:*`) e entra no log como `null`, nunca como 0: "não consegui ler" não se confunde com "li zero". `mem_free_pct` (`memory_pressure`) e `compressed_mb` só são reportados em `--check`; não decidem.

## O que mora no MBP (`~/gt-remote`)
- `whatsapp_automation/`, `property_scrapers/`: árvores-base (sem .git, venv, shared/data, *.db, logs, .beads…).
- `mirror/<repo>-<slot>/`: um espelho por slot (clone APFS da base na 1ª vez, depois `rsync --delete` do worktree do chamador).
- `venv/` (WA, python3.14) e `venv-ps/` (PS, python3.11): site-packages copiados do mini (um `pip install` novo falha em `Levenshtein`); hash em `.sp-hash`.
- `slots/N`: trava por `mkdir`; dono = `host:pid:epoch`; dono morto ou idade > 4 h é liberado por quem chega.
- `exec/N`: scratch do modo `--exec`, apagado no fim (capturas de REA nunca ficam).
- `rea/`: REA 6.4.0 instalado com Node 22 (`brew install node@22 ghidra`, ghidra/openjdk@21/node@22 fixados com `brew pin`). O Node 25 do MBP não serve ao REA (exige 22.19+, 24.11+ ou 26+).
- Log das execuções e das recusas do preflight: `$CITY/.gc/logs/mbp-run.jsonl` (ts, repo, modo, slot, rc, segundos; a recusa tem `"mode":"preflight"`, `reason` e os números que a causaram).

## Manutenção
- **Reseed noturno (ga-wuwuk7):** `scripts/mbp-nightly-reseed.sh`, disparado pelo launchd `com.gascity.mbp-nightly-reseed` (`scripts/com.gascity.mbp-nightly-reseed.plist`, instalado em `~/Library/LaunchAgents/`) todo dia às **05:50**: depois do rebuild das 04:45 e do restic (04:47-05:37), antes do lotes-rebuild das 06:30, longe do reboot (23:00, dreno até ~00:30). Roda `mbp-run.sh --seed wa` e `--seed ps` (rsync da base; site-packages só recopia quando o hash dos dist-info muda). Última linha do stdout: `VEREDITO: <x>`; uma linha jsonl por execução em `$CITY/.gc/logs/mbp-nightly-reseed.jsonl`; saída do launchd em `.gc/logs/mbp-nightly-reseed-launchd.{out,err}`.
  - `OK`: os dois repos com rc 0 (o texto diz se o site-packages "já bate" ou foi recopiado).
  - `FALHOU`: algum repo saiu com rc != 0 ou estourou o prazo (1800 s por repo). Um `notify` prio 4 nomeia o repo, o rc e o que ele quer dizer; o outro repo roda mesmo assim; exit 1. **rc 98 (MBP sem saúde) conta como FALHOU**: a base envelheceu e alguém precisa saber. Também é `FALHOU` (com notify, sem semear nada) o que impede de *saber* se pode rodar: não conseguir olhar a chave (`.gc` sem acesso), não conseguir criar, tomar ou remover o lock (`.gc` sem permissão ou disco cheio, `.gc/mbp-nightly-reseed.lock` que é arquivo, lock velho que não sai, lock tomado e reocupado em seguida), não conseguir gravar o pid do dono, ou não conseguir medir a idade de um lock sem pid. O notify cita a causa e a mensagem do sistema.
  - `PULADO`: nada tentado por escolha, sem notify, exit 0, **e só com evidência positiva**: chave desligada (`.gc/mbp-offload.on` ausente com `.gc` acessível), dreno do reboot vivo (`~/.gastown/run/city-drain.level`, linha 4 no futuro) ou outro reseed em andamento (lock `.gc/mbp-nightly-reseed.lock` com pid vivo, ou sem pid e criado há menos de 60 s). Um `mkdir` do lock que falha não é essa evidência: sem lock depois da falha, ou com dono morto que não dá para remover, é `FALHOU`. Dreno com "até" a mais de 6 h e lock com mais de ~2 prazos de idade não pulam: avisam (`WARN`) e seguem, para que um arquivo podre não vire noite perdida em silêncio.
  - À mão: `scripts/mbp-nightly-reseed.sh` (mesmas regras); autoteste hermético: `scripts/mbp-nightly-reseed.selftest.sh`. Ver o último veredito: `tail -n 3 $CITY/.gc/logs/mbp-nightly-reseed.jsonl`.
  - Não reseme com teste rodando no MBP (hash novo pode trocar o site-packages debaixo do teste); às 05:50 não há.
- `rea update` no MBP só por bead que revisa o changelog (REA roda com as permissões do usuário). Versão fixa, patch dos 300 s e roteiro de atualização: `docs/runbooks/rea-versao-fixa-e-patch.md`.
- Segredos: o MBP usa o mesmo acesso do mini (decisão do Athos, 11/10); o comando enviado nunca carrega segredo.

## Limites conhecidos
- **Swap do MBP (resolvido em ga-9e2rjh):** o macOS não devolve o arquivo de swap depois de uma pressão; o MBP ocioso fica em 4,9-5,2 GB "usados". O limiar fixo de 5 GB recusou, em 11/10, uma execução com 5.248 MB de swap e 3,8 GB de RAM disponível. O critério agora é RAM + pressão + crescimento do swap (tabela acima), e o limiar de swap virou só um teto absoluto, que subiu de 5 para 8 GB. Medição de aceite: recusas indevidas = 0 em 3 dias. Conferir com `scripts/mbp-offload.sh counts` (ou a linha "últimas 72 h" do `status`): recusa por `swap_teto` ou `swap_cresce` com RAM e pressão normais é o sinal de que o critério precisa de ajuste; `ilegivel:*` é o MBP respondendo lixo, não swap alto. A contagem tem três respostas que não se confundem: `sem log ainda`, `ilegível` (o log existe mas não deu para ler) e `recusas: nenhuma` (lido, e sem recusa). Linha do log que não deu para ler (truncada, sem motivo, data inválida) vem avisada no fim ("N linha(s) ilegível(is) no log"): se aparecer, a contagem não está completa, então olhe o log antes de concluir "0 recusas indevidas".
  Efeito no reseed noturno: se o preflight recusar o MBP (rc 98), o `--seed` sai 98 e a noite vira `FALHOU` com notify. É o sinal certo (a base não foi atualizada); a correção é no critério de saúde, não silenciar o reseed.
- Teste que lê `shared/data/*.db` falha no MBP (os bancos não são enviados): o runner imprime uma nota; rode esse teste local.
- Teste que lê dado POR UM CAMINHO QUE O WRAPPER NÃO VÊ (constante numa lib, não `shared/data` literal no arquivo) pode passar VAZIO no MBP. O wrapper do revisor só confere aqui o que o MBP reprova ou pula; um verde vazio passa, e ele não tem como saber qual é. Por isso DIZ: todo verde do MBP aceito sem reconferência (de todos os alvos, ou só dos que não pularam quando outros pularam) sai com a linha `nota: verde do MBP aceito...` (fail-open visível, antes da linha `gate-pytest: ran=...`), e o parágrafo do prompt manda o revisor tratar esse verde como não verificado quando o código testado lê dado e rodar esses arquivos aqui com `python3 -m pytest`. Quando acontecer de verdade, acrescente o arquivo em `scripts/gate-pytest.force-local`.
- Cada execução paga ~6 s de ssh/rsync mais o preflight (intervalo de 2 s entre as duas leituras do swap + o tempo das leituras: ~3 s medidos de relógio); testes de menos de ~10 s não valiam o offload e agora valem menos ainda. Vermelho no MBP que passa isolado aqui custa o MBP + o id + o comando inteiro aqui (o preço de não esconder um `-x` ou um pulado); só acontece no vermelho que o MBP inventa, que é raro.
- A linha "MBP SEM SAÚDE (rc=98)" do `status` mostra só os pares `chave=valor` crus; o MOTIVO (`ram`, `swap_cresce`...) só aparece para recusas de execuções reais, que vão para o log (`mbp-offload.sh counts` e as últimas linhas do `status`); o `--check` que o `status` roda não grava recusa, então para ver "por que agora?" leia os pares `chave=valor` contra a tabela acima.
