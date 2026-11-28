# Alarmes por faixa estatística (alarm-bands) · runbook

## Contents

• O que muda · Como a faixa é decidida · O que cada faixa faz · Silêncio 22-07 h · Dispensar um alarme · Contar antes e depois (os 7 dias) · Interruptores · Instalar o tick do disco · Limites e o que NÃO faz · Acrescentar uma métrica

Bead ga-4mzkfj9 (melhoria escolhida pelo Athos em 28/11, do playbook «The AI-Native SDLC»). Código: `packs/town-deltas/assets/scripts/bands.py` (motor) e `bands.yaml` (o que se julga e como), ligado ao `gate-throughput-meter.py`. Decisões e porquês: `docs/superpowers/specs/2026-11-28-alarm-bands-design.md`.

## O que muda
Vigia com limite fixo fala do **nível** («gate abaixo de 8,0/h»), não de **mudança**: com o gate estável em ~3/h o mail saía de 6 em 6 h, por dias. Agora cada métrica é julgada contra o **comportamento recente dela mesma**; a meta do Athos (8/h) continua no texto do aviso e no relatório da manhã como **referência de produto**, e deixa de ser o gatilho de repetição. Consequência assumida: um gate **estável abaixo da meta já não interrompe ninguém** (aparece só no relatório da manhã); interrompe quando **muda**.

Pilotos desta entrega: `gate_throughput` (**ao vivo**, dentro do `gate-throughput-meter.py`) e `disk_free_delta` (**só sombra**, pelo `bands.py tick`). O terceiro nome da bead, `autoheal_escalation_watch.py`, mora no rig WA: fica para uma bead lá (o motor é chamável por caminho).

## Como a faixa é decidida
Sem modelo na detecção, tudo determinístico:
- **Série**: pontos de baldes de tempo fixos. Gate: revisadas por bloco de 3 h na grade 07-10-13-16-19-22 h (hora local), só o dia ativo; um bloco que o log do dispatcher não cobre inteiro fica **de fora**, nunca vira zero. Disco: variação do espaço livre por hora (MiB/h), lida de uma série que o `tick` grava a cada 10 min; hora sem leitura (ou com leitura velha demais, > 15 min) não gera ponto.
- **Base**: média e σ dos últimos `baseline_days` (14), **sem** os 8 pontos em teste e **sem** os pontos de episódio aberto (uma falha não vira o novo normal) — enquanto um episódio está aberto a janela da base fica congelada no instante em que ele começou. Contagem baixa é julgada em √(x+3/8) (Anscombe), onde o limite inferior de 3σ ainda existe; σ nunca cai abaixo de 0,5 nessa escala (série constante não é «infinitamente certa»).
- **Regras de Western Electric**, valendo só se o ponto MAIS NOVO faz parte do padrão e só no lado de `direction`: **3σ** = 1 ponto além de 3σ · **2σ** = 2 de 3 além de 2σ · **1σ** = 4 de 5 além de 1σ, ou 8 seguidos do mesmo lado do centro.
- Base curta demais (`min_baseline_points`), série velha demais (`fresh_for_h`) ou estado ilegível **não** são «tudo certo»: viram `aprendendo` / `sem ponto novo` / `não medido`, e o meter segue na regra antiga enquanto aprende (nada regride).

## O que cada faixa faz
Cada faixa age **uma vez por episódio**; nada repete. Um episódio abre na 1ª faixa ≥ 1 e fecha depois de `recover_after_h` (6 h no gate) em faixa.

| Faixa | Ação | Detalhe |
|---|---|---|
| 1σ | só log | linha `FAIXA 1σ …` no log do vigia e evento no ledger |
| 2σ | diagnóstico + mail | `claude -p` com `--tools "Read,Grep,Glob"` e mais nenhuma ferramenta, sem identidade (nenhum `GC_*`/`BD_ACTOR`), US$ 1, 600 s; o texto vai no mail ao Mayor. Falhou ou estourou o teto? O mail sai igual, dizendo por que o diagnóstico não rodou |
| 3σ | diagnóstico (se ainda não houve) + bead + mail | bead `-t bug -p 1` com `exec:auto`, `story:approved`, rota `gastown.dog`, rótulos `origem:bands` e `bands:ep:<episódio>`; o rótulo do episódio é a identidade: tentativa repetida **acha** a bead em vez de abrir outra. Os rótulos que a fazem ser despachada são a chave `bead.labels` do `bands.yaml` (padrão `exec:auto` + `story:approved`, a mesma postura do `gate-refusal-checks.py`) |

O mail é sempre a última ação (cita diagnóstico e bead) e **nunca espera** por eles. Mail que falha não é carimbado: a próxima rodada tenta de novo sem gastar o diagnóstico outra vez. Tetos: 4 diagnósticos e 2 beads por dia (contados no ledger; ledger ilegível = não gasta e diz), 2 tentativas de diagnóstico e 3 de bead por episódio. O texto do modelo entra no mail e na bead dentro de `<conteudo_externo>` (dado a conferir, nunca instrução; `<` e `>` viram `‹` `›`, caractere de controle vira espaço) e na bead vai **encurtado** a 1.500 caracteres, porque quem lê a bead é um builder que age. **Decisão de segurança que é do Mayor**: uma bead nascer já aprovada, com texto derivado de logs, é o mesmo risco que o `gate-refusal-checks.py` já aceita; para exigir aprovação antes de um builder agir, troque `bead.labels` (não use `story:needs-approval`: cai na fila do Athos sem dizer o que ele faz).

## Silêncio 22-07 h
Nada interrompe entre 22 h e 7 h (hora local). O gate, que tem ritmo diário, simplesmente **não é julgado** nesse intervalo (o último bloco do dia termina às 22 h; o que ainda estiver errado de manhã aparece no 1º ponto novo, ~10 h). Métrica com `evaluate_in_silence: true` (o disco) continua sendo julgada e só a **entrega** espera a manhã.

## Dispensar um alarme
Era normal? `python3 packs/town-deltas/assets/scripts/bands.py dismiss --metric gate_throughput --reason "<por quê>" [--by nome] [--episode <id>]`. Efeito: o episódio fecha como dispensado, os pontos dele **voltam para a base**, tudo que já existe passa a ser aceito (só ponto NOVO é julgado: o mesmo dado não abre um 2º episódio) e o σ alarga em 25 % por dispensa dos últimos 30 dias (teto +100 %). O motivo fica no ledger. Sem `--reason` não dispensa. Uma faixa errada de forma permanente se corrige no `bands.yaml` (commit), não por dispensas.

## Contar antes e depois (os 7 dias)
`python3 packs/town-deltas/assets/scripts/bands.py report --days 7` (e `status` para ver o episódio aberto de cada métrica). Por métrica: o que as faixas fizeram (episódios, avisos entregues, beads, diagnósticos, dispensas; na sombra, as entregas que **teriam** saído) contra o que a regra fixa mandava (linhas do log do próprio vigia nos `--days` anteriores ao 1º evento das faixas). Um zero só vale ao lado de quanto foi olhado, por isso a linha traz o intervalo do log e quantas linhas com carimbo ele tinha. Para o gate o «antes» é «MAIL: alarme enviado ao Mayor» do `gate-throughput-meter.log`. Para o disco é uma **subcontagem declarada**: só os mails de CRITICAL (`mailing Mayor`) do guarda de disco. Ledger ilegível = `rc 2`, nunca «zero».

Critério da bead (PRONTO QUANDO): os pilotos rodando por faixa por 7 dias com esta contagem. Depois dos 7 dias a decisão de ligar o disco ao vivo é do Mayor (trocar `mode: shadow` por `live` no `bands.yaml`; os pisos fixos do disco nunca saem).

## Interruptores
- `GTM_BANDS=0` no plist do meter: só a regra fixa antiga (nem o diretório das faixas é criado). `GTM_BANDS=shadow`: a regra fixa decide e as faixas só **contam** (ledger).
- `mode: shadow` de uma métrica no `bands.yaml`: o mesmo, por métrica.
- `BANDS_DIAGNOSE=0`: some o agente que só lê (nem consome tentativa nem vaga do dia). `diagnose.enabled` / `bead.enabled: false` no `bands.yaml`: idem, versionado.
- `GTM_ENABLED=0`: desliga o meter inteiro. `GTM_BANDS_CONFIG=<arquivo>`: outro `bands.yaml` (testes). `bands.py check` valida o arquivo (rc 2 se inválido; chave desconhecida é erro).
- Se as faixas não sobem (arquivo ilegível, typo, módulo quebrado) o meter **avisa no log (`WARN: faixas indisponíveis`) e a regra fixa decide**: nunca silêncio.

## Instalar o tick do disco
Decisão do Mayor (nada se carrega sozinho). Antes: `python3 packs/town-deltas/assets/scripts/bands.py tick --dry-run` (não mede nem grava; mostra o que julgaria). Instalar: `cp packs/town-deltas/assets/bands-tick.plist ~/Library/LaunchAgents/com.gascity.bands-tick.plist && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gascity.bands-tick.plist`. Conferir depois: `.gc/state/bands/series/disk_free_delta.jsonl` ganha uma linha a cada ~10 min e `bands.py status` fala da métrica. O volume lido é `/private/var/vm` (o mesmo de `disk-headroom-lib.sh`): **sem queda para outro volume** (no macOS `/` é o volume selado e conta outra história). A série precisa de ~2,5 dias de leitura para a base (`min_baseline_points: 48` mais os 8 pontos em teste, um por hora).

## Limites e o que NÃO faz
- Não toca os pisos de disco que **agem** (`dolt-disk-floor-guard`, `disk-pressure-monitor`, ballast…): são proteção, ficam como estão; a faixa de disco só conta.
- **Nada disto rodou ao vivo**: o nó onde foi escrito não tem Dolt, `gc`, `bd` nem o `claude` do mini. O motor e o meter foram testados com binários falsos que gravam o que receberam (`bands.selftest.py`, `gate-throughput-meter.selftest.sh`) e por mutantes; a 1ª rodada real é o teste de campo.
- O «runbook pré-aprovado» do 3σ da bead **não foi implementado**: não existe nenhum runbook com autorização citável (regra Nº 4 do Athos), e rodar comando por faixa sem isso seria ação irreversível. O 3σ **propõe** (bead); o ponto de extensão é um adaptador novo em `RealAdapters`.
- A base precisa de log: o do dispatcher cobre quantos dias estiver (sem 28 blocos ≈ 6 dias, o meter fica na regra fixa); um episódio aberto congela a janela, mas só enquanto o log ainda tiver os pontos de antes dele.
- Alarme que a faixa **cala** por ser estável não some do mundo: a meta continua no relatório da manhã (`gate-daily-report.py`, linha 7, inalterado). Quem quiser interrupção por nível usa `GTM_BANDS=0`.
- Fuso: grade e silêncio em UTC-3 fixo (sem horário de verão desde 2019), como o resto do meter.

## Acrescentar uma métrica
1. Bloco em `bands.yaml` (comece com `mode: shadow`). `bands.py check` valida; o `actions` por faixa só aceita `log` na 1σ, `diagnose`/`mail` na 2σ e também `bead` na 3σ.
2. Quem mede: um vigia que já conhece a série chama `bands.process(...)` com os pontos (`gate-throughput-meter.py` é o exemplo: `block_points`, `make_gate_driver`, `run_bands`); uma métrica que se mede sozinha usa `driver: tick` + um `collector` (hoje só `disk_free_delta`) e roda no `bands.py tick`.
3. As palavras do aviso: subclasse de `bands.Driver` (`facts`, `evidence`, `mail`, `bead`).
4. Contagem «antes»: `legacy_log` (relativo à cidade) + `legacy_pattern` (regex) com a linha que a regra antiga deixava no log.
5. Selftest que **falha sem** a mudança (o estilo de `bands.selftest.py`): leitura de dado que pode faltar tem de cair no estado inerte, nunca no mesmo resultado de «vazio».
