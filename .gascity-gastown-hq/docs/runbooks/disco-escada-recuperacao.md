## Contents
- O que é e por que existe
- Estado de instalação: o job NÃO está carregado
- Limiares
- Como o maestro decide
- Contrato dos degraus
- Interruptor, arquivos, saídas
- Três estados: o que o maestro faz quando não consegue ler
- Teto de 6 h do reinício (D4)
- Como testar
- Medição
- Decisão citável e fatias

## O que é e por que existe

De cerca de 05:00 a 10:40 de 01/11/2026 o volume Data do mini ficou entre 2 e 4 GB livres. A causa era memória virando swap
(rfb_monthly_refresh, demand-dashboard, map-viewer, Dolt), e as P0/P1 do WA ficaram paradas. Os guardas que existiam só LIMPAM
ARQUIVO e avisam (o `dolt-disk-floor-guard` diz que nunca mata nada). Esta escada age sozinha depois disso, até o reinício
guardado do mini.

`scripts/disk-recovery-ladder.sh` é só o **maestro**. Ele lê o disco, guarda há quanto tempo o disco está baixo e chama UM degrau
por rodada. Não apaga, não para e não reinicia nada por conta própria.

| Degrau | Quem | O que faz |
|---|---|---|
| D1 | `scripts/dolt-disk-floor-guard.sh` (já roda sozinho, a cada 5 min) | limpa arquivo (reapers, GOCACHE, órfãos…). O maestro NÃO o chama nem o reimplementa |
| D2 | `scripts/disk-recovery-d2-heavy-jobs.sh` (bead ga-1p1i5jr.2) | para jobs pesados reiniciáveis da allowlist |
| D3 | `scripts/disk-recovery-d3-ram-daemons.sh` (bead ga-1p1i5jr.3) | restart drenado dos daemons que mais usam RAM |
| D4 | `scripts/disk-recovery-d4-guarded-reboot.sh` (bead ga-1p1i5jr.4) | reinício guardado do mini |

## Estado de instalação: o job NÃO está carregado

O arquivo `scripts/com.gascity.disk-recovery-ladder.plist` entra no repositório, mas **nada o carregou**. Fazer merge não liga o
job. Enquanto ninguém rodar o comando abaixo, a escada não existe para o launchd.

Antes de carregar, confira que D2, D3 e D4 existem e são executáveis. Se faltar um, o maestro avisa uma vez (`notify -p 4`) e
pula para o próximo, mas a escada fica sem aquele degrau.

```
cp scripts/com.gascity.disk-recovery-ladder.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gascity.disk-recovery-ladder.plist
launchctl print gui/$(id -u)/com.gascity.disk-recovery-ladder | head -20     # a prova: o serviço existe, run interval = 120 seconds
```

Para descarregar: `launchctl bootout gui/$(id -u)/com.gascity.disk-recovery-ladder`. Para pausar sem descarregar:
`touch .gc/disk-recovery.off`.

Carregar o job é o que liga a escada: quem carrega precisa de autorização citável do Athos. A decisão de que a escada age sozinha,
a qualquer hora e com guardas, está citada na seção "Decisão citável"; o carregamento em si fica com o Mayor.

## Limiares

Medidos em MB livres de `df -Pm /System/Volumes/Data`. **Nunca `df /`**: ele lê o volume de sistema selado e mostra 71% com o
Data em 98% (`docs/runbooks/disk-guards-quem-age.md`).

| Degrau | Livre | Por quanto tempo seguido |
|---|---|---|
| D2 | ≤ 5120 MB (5 GB) | ≥ 900 s (15 min) |
| D3 | ≤ 4096 MB (4 GB) | ≥ 1800 s (30 min) |
| D4 | < 3072 MB (3 GB) | ≥ 3600 s (60 min) |
| D4, piso duro | < 1536 MB (1,5 GB) | 2 leituras SEGUIDAS (2 min), a qualquer hora |

O piso duro é parte do limiar do D4 (decisão do Athos: "< 1,5 GB a qualquer momento"). Não é um atalho para pular D2 e D3 em
episódio comum: os dois só entram depois do tempo deles. Duas leituras seguidas, e não uma, para que um pico passageiro (um
`go build` que sobe e solta) não reinicie o mini.

Todos os números têm uma variável `DR_<NOME>` (ver o cabeçalho do script). Um valor que não é número cai no padrão e o log diz.

## Como o maestro decide

1. **Cronômetro por nível.** Ao entrar no nível (`livre ≤ limiar`) o cronômetro começa. Só conta tempo de rodadas que o maestro
   leu.
2. **Histerese de 512 MB.** O cronômetro só ZERA quando o livre volta a `limiar + 512 MB`. Entre o limiar e `limiar + 512 MB` ele
   nem começa nem zera. Um disco que oscila em volta de 3 GB por 5 h não reinicia o relógio de 60 min a cada subida de 100 MB.
3. **Lacuna.** Mais de 600 s entre duas leituras (máquina parada, launchd fora, df ilegível) ou relógio que andou para trás zera
   cronômetros e marcas. Tempo que ninguém observou não vale como "60 min abaixo" para reiniciar uma máquina. A hora do último
   reinício (`acted4_ts`) fica.
4. **Um degrau por rodada.** A 1ª chamada de cada degrau no episódio vai em ordem D2 → D3 → D4. As repetições vão do mais alto
   para o mais baixo. Se o D2 repetisse primeiro a cada 5 min e o launchd atrasasse as rodadas para 5 min, ele ocuparia toda
   rodada e o D3 e o D4 nunca teriam vez.
5. **Re-mede depois de cada degrau.** Se o espaço voltou a `limiar + 512 MB`, os cronômetros zeram e o degrau seguinte não entra.
6. **Repetição.** Degrau que devolveu 0 (agiu) não repete por 30 min. Degrau que devolveu 10, 20 ou 30 repete em 5 min.
7. **Degrau ausente** (arquivo não existe ou sem permissão de execução): loga `degrau ausente`, avisa UMA vez e a rodada segue
   para o próximo degrau que tenha o tempo vencido. O maestro nunca chama o D4 sem o tempo do limiar dele.

Cada ação gera: 1 linha de log, `notify` (D2 `-p 3`, D3 `-p 4`, D4 `-p 5`, falha `-p 4` no mínimo) e mail ao Mayor. Prioridade 4 ou
mais vai com `NOTIFY_FORCE_PUSH=1`, porque o `notify` decide push ou resumo mudo pela REDAÇÃO da mensagem e não pelo `-p`
(ga-ff6t9: um aviso de disco crítico real já caiu no resumo mudo).

## Contrato dos degraus

Cada degrau é chamado `<script> --run` (real) ou `<script> --dry-run` (só diz o que faria). Escreve UMA linha em stdout. Saídas:

| rc | Significado | O maestro faz |
|---|---|---|
| 0 | agiu e terminou | marca `acted`, notify + mail, não repete esse degrau por 30 min |
| 10 | nada a fazer, ou a guarda adiou | marca `idle`, repete em 5 min, sem aviso |
| 20 | falhou | marca `failed`, notify `-p 4` + mail, saída 20, repete em 5 min |
| 30 | não consegui ler o estado (não agiu) | marca `unknown`, notify `-p 3` (no máximo 1 por hora), repete em 5 min |
| outro / passou de 900 s | falha | tratado como 20 (o estouro de tempo recebe TERM). Exceção: não conseguir nem lançar o degrau (mktemp falhou) conta como 30 |

O notify e o mail são do maestro. Os degraus não avisam por conta própria.

## Interruptor, arquivos, saídas

| O quê | Onde |
|---|---|
| Desligar o maestro | `touch .gc/disk-recovery.off` (apague para voltar). Sai 10 sem ler nem agir |
| Estado | `.gc/disk-recovery.state` (chave=valor, escrito inteiro e trocado com `mv`) |
| Log | `.gc/logs/disk-recovery.log` (gira em 5 MB, 1 backup `.1`). Durante um episódio, 1 linha de leitura por rodada; sem episódio, 1 batimento por hora |
| stdout / stderr do launchd | `.gc/logs/disk-recovery-ladder.out` e `.err` |
| Trava | `.gc/disk-recovery.lock` (diretório + pid). Instância única. Trava de pid morto, ou de pid vivo que não é o maestro, é refeita |

Saídas do script: **0** rodada feita · **10** interruptor ligado ou outra instância rodando · **20** um degrau falhou · **30**
não consegui ler (relógio, df, swap, estado não gravável) e por isso não agi · **2** uso.

`--dry-run` lê o estado salvo, aplica a leitura de agora numa cópia em memória e chama os degraus com `--dry-run`. Não grava
estado nem log, não avisa, não manda mail e não toma a trava.

## Três estados: o que o maestro faz quando não consegue ler

"Não consegui ler" nunca vira "tem bastante disco" nem "disco baixo".

| Não consegui ler | O maestro |
|---|---|
| `df` do volume Data (falhou, vazio, número inválido, ponto de montagem diferente) | NÃO chama degrau nenhum, loga, `notify -p 4` (no máximo 1 por hora), sai 30. Os cronômetros NÃO zeram |
| swap (`sysctl vm.swapusage`) | idem. O swap é leitura obrigatória (contexto das mensagens; a causa de 01/11 foi memória virando swap) |
| relógio (`date +%s`) | NÃO chama degrau nenhum, loga e sai 30. Sem notify: sem hora não há como limitar o aviso a 1 por hora |
| estado salvo (corrompido, vazio, sem a marca `v=1`, campo inválido, última linha sem `\n` com valor inválido) | põe de lado como `disk-recovery.state.corrupt-<hora>`, escreve WARN no log, os cronômetros recomeçam do zero e a rodada SEGUE (sai 0). Nada dispara por um histórico que não li |
| gravar o estado (disco cheio, sem permissão) | WARN no log e saída 30 (se nenhum degrau falhou). A escada fica cega para o TEMPO: cada rodada relê o arquivo antigo |

Em todos os casos de df/swap ilegíveis os cronômetros salvos ficam como estavam; se a falta de leitura passar de 10 min, a lacuna
os zera na próxima leitura boa.

## Teto de 6 h do reinício (D4)

Reinício em laço é impossível por construção. O `acted4_ts` é gravado ANTES de chamar o D4 (um reinício que mata o maestro no
meio não perde a marca). Depois de um D4 que devolveu 0, o maestro não chama `d4 --run` de novo por 6 h. Se o disco segue abaixo
de 3 GB, ele **escala** em vez de reiniciar: `notify -p 5` com push forçado e mail ao Mayor, uma vez por episódio ("segue baixo
depois do reinício, preciso de um humano"). Se o D4 devolve 10 ou 20, a marca volta ao valor anterior e ele tenta de novo em 5
min (a guarda adiou, ou falhou sem reiniciar). O comentário na ga-1p1i5jr.4 pede que o próprio D4 tenha o cooldown dele também (defesa em profundidade); o maestro não depende disso.

## Como testar

```
scripts/heavy-guard.sh --what selftest-hq --max-file-mb 512 -- bash scripts/disk-recovery-ladder.selftest.sh
```

O selftest é hermético: df, swap, relógio, degraus, `notify` e `gc mail` são simulados, e as rodadas do launchd são chamadas com a
hora que o teste escolhe (6 h de teto passam em segundos). O trecho que lê `df` e `sysctl` de verdade é testado com shims no PATH,
e o shim do `df` prova que o maestro nunca lê `df /`. Cobre cada fronteira dos limiares (5120/5121, 4096/4097, 3071/3072,
1535/1536 MB e 899/900 s), a histerese, a lacuna, a ordem e um degrau por rodada, o piso duro, cada código de saída dos degraus,
degrau ausente, o teto de 6 h (inclusive o maestro morto no meio do D4), df/swap/relógio/estado ilegíveis, o interruptor, a trava,
o dry-run, configuração inválida, notify e mail com defeito ou travados, rotação do log e estado não gravável.

Resultado da última rodada completa: 285 verificações, 0 falhas. Uma rodada anterior, com 282 verificações, levou 3 min 13 s no mini
com load ≈ 35; por isso o selftest roda sob o `heavy-guard`, que é da classe `selftest`. O guarda vale para o volume INTEIRO: com o
disco apertado ele recusa (rc 75) ou interrompe (rc 78) mesmo que a queda venha de outro job. Nesse caso espere folga e rode de novo;
não baixe o piso do guarda para passar. `--min-free-mb` e `--max-disk-drop-mb` existem para ajustar o piso e o limite de queda numa
chamada, mas o piso nunca deve ir abaixo de 4096.

Para testar uma cópia modificada do maestro (mutantes): `DR_LADDER_PATH=/caminho/copia.sh bash scripts/disk-recovery-ladder.selftest.sh`.
Com `ST_FAILFAST=1` o selftest para no primeiro FAIL e sai 1 com `(ST_FAILFAST) parei no 1º FAIL: N passaram, M falharam`, o que
acelera o teste de mutantes (um mutante "pego" é um que faz o selftest sair 1).

Teste de mutação (01/11/2026): 22 cópias do maestro, cada uma com UMA alteração de 1 a 2 linhas (limiares com `<` no lugar de `<=`
e o contrário, sem histerese, sem a regra da lacuna, sem o filtro de 2 leituras do piso duro, o tempo do limiar ignorado, marca do D4
gravada depois da chamada, `df /`, df ou swap ilegível tratado como 0, sem trava, sem `NOTIFY_FORCE_PUSH`, sem o teto de 6 h, as
duas passadas na ordem trocada, marca do D4 mantida em rc 10, dry-run gravando estado, prioridade do D3 trocada, um comando
qualquer no lugar do degrau, estado sem `v=1` aceito, última linha do estado sem `\n` descartada, interruptor ignorado). O selftest
pegou as 22. Dois só caíram, por acaso, no teste da trava de instância única: o `df /` (o teste "df chamado SEMPRE com -Pm
/System/Volumes/Data" também o pega, conferido sem failfast) e a ordem da 1ª passada invertida, que NENHUM teste mirava, porque com
rodadas a cada 5 min o cronômetro de um nível só vence depois de o de baixo já ter sido chamado. Por isso foi acrescentada a seção
"1ª passada com VÁRIOS degraus vencidos ao mesmo tempo" (estado escrito à mão); com ela esse mutante cai também nos testes da própria
ordem (conferido sem failfast).

## Medição

Rodada que não chama degrau, com `df` e `sysctl` REAIS e estado, log e trava num diretório de teste (nada do estado real), no mini
com load ≈ 35 (01/11/2026 ~11:50, 5 rodadas): **0,44 s** a 1ª (sem estado salvo) e **2,3 a 2,8 s** as outras, contra o intervalo de
120 s. `df -Pm /System/Volumes/Data` e `sysctl -n vm.swapusage` levam menos de 0,05 s cada; o resto é o bash e os subprocessos
(`date`, `awk`, `du`…) com o load alto. Uma medição anterior no mesmo dia, com load ≈ 40, deu 3,7 a 5,2 s. Uma rodada que chama um degrau
demora o que o degrau demorar, no máximo 900 s (depois disso o degrau recebe TERM); o launchd não inicia outra enquanto esta roda e a
trava cobre o resto. Depois de um degrau o maestro atualiza a hora da última leitura, então a demora do degrau não conta como lacuna.

## Decisão citável e fatias

- **Decisão do Athos:** AskUserQuestion na sessão do Mayor, 01/11/2026 ~11:00 BRT, resposta "A qualquer hora, com guardas
  (Recomendado)". Citada na epic ga-1p1i5jr.
- **Fatias:** ga-1p1i5jr.1 (este maestro, o plist e o selftest), .2 (D2), .3 (D3), .4 (D4). Os nomes dos scripts e o contrato de
  chamada e de saída foram postados como comentário nas três beads irmãs antes de elas serem pegas.
- **Limite conhecido:** o maestro mede só o volume Data. Ele não decide QUAL daemon consome a RAM (isso é do D3) nem se é seguro
  reiniciar (isso é da guarda do D4).
