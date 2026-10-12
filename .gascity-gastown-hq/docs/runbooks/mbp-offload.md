# MBP como nó de capacidade (offload de testes e REA/APK)

## Contents

• Por quê e resultado medido (11/10/2026) · Como ligar e desligar · Como usar · Códigos de saída
• O que mora no MBP (`~/gt-remote`) · Manutenção · Limites conhecidos

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
- Cada execução paga ~6 s de ssh/rsync mais o preflight (intervalo de 2 s entre as duas leituras do swap + o tempo das leituras: ~3 s medidos de relógio); testes de menos de ~10 s não valiam o offload e agora valem menos ainda.
- A linha "MBP SEM SAÚDE (rc=98)" do `status` mostra só os pares `chave=valor` crus; o MOTIVO (`ram`, `swap_cresce`...) só aparece para recusas de execuções reais, que vão para o log (`mbp-offload.sh counts` e as últimas linhas do `status`); o `--check` que o `status` roda não grava recusa, então para ver "por que agora?" leia os pares `chave=valor` contra a tabela acima.
