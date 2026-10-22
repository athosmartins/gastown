# Capacidade do nó Hetzner e preferência "nó primeiro" · runbook

## Contents

• O que esta fatia é — e o que não é · Estado: o que está vivo · Como usar (comandos) · Os degraus e os limites (e por quê) · Encher o nó: relógio próprio, CPU e carga externa (ga-2hd02v.2) · O veredito · Sessão ocupada × sessão viva (ga-2hd02v.1.22) · Como ligar a sombra do Pilot · Como ler a sombra · Ligar e desligar o nó primeiro (`on`) · Subir os tetos fixos · O que falta para o "nó primeiro" de verdade · Medido, inferido, não testado · Limites

Bead ga-2hd02v.1.11 (fatia da ga-2hd02v.1; objetivo do Athos: o mini para de entrar em swap, o Hetzner pago trabalha 24/7). **Entrega duas peças, em duas fatias** (a ga-2hd02v.1.11 foi recusada 3x pelo teto de tamanho do gate): (1) `scripts/hetzner-capacity.py` — fatia A, ga-5yp4n1, **tem que estar no main antes desta** — que mede o nó e responde "quantas sessões ele aguenta agora" (um teto que sobe em degraus 1→3→6→10 só com evidência, e desce sozinho) e "esta bead vai ao nó ou fica no mini" (`verdict`); (2) o **modo sombra** do Pilot (`PILOT_NODE_FIRST=shadow`) — fatia B, ga-elvr8e, esta —, que consulta o veredito para cada bead de dog do HQ e **registra** o que faria, sem mudar o despacho.

## O que esta fatia é — e o que não é

**É** a decisão, com número medido: quando o nó pode receber trabalho, e quanto. **Não é** o envio: nada aqui atribui bead a `dog-remote-<n>`, abre sessão ou toca em `city.toml`, `agents/` ou `.gc/session-ssh.json`. O dog remoto não reivindica sozinho (o atalho nega `bd ready`, `bd query`, `bd update --claim`, `gc runtime drain-ack`), então quem leva a bead ao nó precisa atribuí-la ao alias e abrir a sessão — isso é a **ga-2hd02v.1.14**, que depende desta e da ga-2hd02v.1.13 (gate-done a partir do nó).

O modo `on` **não existia nesta fatia** (um `on` que só registrasse prometeria um envio que não acontece); ele veio na **ga-2hd02v.1.14** e está descrito em "Ligar e desligar o nó primeiro (`on`)". Valor desconhecido vale `off` e avisa.

## Estado: o que está vivo

**Nada.** Mergeado ≠ vivo (vale também para o `on` da ga-2hd02v.1.14: o código do envio existe, a chave está desligada). Depois do merge: o Pilot roda com `PILOT_NODE_FIRST` ausente = `off` (a função sai na primeira linha, nenhuma consulta, nenhum arquivo). `hetzner-capacity.py` só roda se alguém o chamar; nenhum plist novo foi criado (decisão: detector com custo de poll só nasce com medição de uma execução e lock, e aqui o "relógio" é quem chama `verdict`/`step`).

## Como usar (comandos)

Tudo em `scripts/hetzner-capacity.py` (Python 3.9+, `python3 -I`). `--json` e `--dir` valem antes ou depois do comando.

| comando | o que faz | efeito |
|---|---|---|
| `status` | degrau, desde quando, últimas leituras, **o que falta para subir**, `cap` do provider, pausa | só lê (sem ssh, sem gravar) |
| `read` | uma medição avulsa do nó | só lê; exit 0 lida, 1 não consegui |
| `verdict` | mede se a última leitura tem mais de `refresh_s` (60 s), avalia os degraus, dá o veredito | grava estado e leitura; exit **0 = NÓ, 1 = MINI, 2 = NÃO SEI** |
| `step` | o mesmo ciclo sem o veredito. É o que o job `com.gascity.hetzner-capacity-step` roda a cada 180 s (ga-2hd02v.2) | grava |
| `hourly [--hours N] [--min-pct P]` | CPU **ocupada** (100 − ocioso) média por hora cheia UTC das últimas N horas completas (24; 85 %): a prova ao vivo da meta de encher o nó | só lê `readings.jsonl`; exit 0 = toda hora com leitura e ≥ P, **1 = alguma hora abaixo ou SEM leitura** (hora sem leitura não prova nada), 3 = não li o arquivo |
| `set-ceiling N --reason T` | força um degrau da lista, registrado em `events.jsonl` | grava |
| `pause --reason T` / `resume` | trava / destrava o envio ao nó **na hora** (próximo veredito) | grava `pause.json` |

Estado em `<cidade>/.gc/hetzner-capacity/` (`state.json`, `readings.jsonl` com toda medição, `events.jsonl` com cada mudança de degrau, pausa e alarme, `config.json` opcional). Quem não consegue o lock lê o cache e não grava.

## Os degraus e os limites (e por quê)

| regra | valor padrão | por quê |
|---|---|---|
| CPU livre | o **menor** entre o ocioso de uma amostra de 2 s do `/proc/stat` e `1 − load5/núcleos` | rajada curta e carga sustentada contam as duas; o nó divide a CPU com as baterias do `mbp-run.sh` |
| sobe um degrau | janela de 480 s desde a última mudança, ≥ 3 leituras, **todas** verdes (CPU livre ≥ 10 % e RAM ≥ 40 %; era 1800 s, 6 leituras e 35 %), e em alguma o nó já tinha ≥ degrau sessões **ocupadas**, lidas com gc e bd sem falha | nunca pula; a prova de carga evita subir só porque o nó está ocioso por falta de demanda (`require_load_proof=false` dispensa) |
| desce um degrau | 2 leituras seguidas com a **RAM** < 20 %, **posteriores** à última mudança. A CPU cheia **não** desce (ga-2hd02v.2; `cpu_lowers_ceiling=true` devolve a regra antiga: CPU livre < 3 % também desce) | o nó **não tem swap**: RAM acabando mata sessão, então a RAM é o limite duro; a evidência não vale duas vezes (sem cascata 10→6→3→1 com as mesmas leituras) |
| faixa entre os limites | âmbar: mantém o degrau, ainda autoriza | sem faixa o degrau oscilaria; a config recusa limites iguais |
| leitura que falhou | cor `unknown`: não é verde, não é vermelha | atrasa a subida, nunca a adianta; não desce por falta de leitura |
| leitura velha | > 900 s não autoriza | `max_age_s` tem que ser maior que `refresh_s` (a config recusa o contrário) |

Os números são **padrões de partida**, não verdades: o runbook não mediu 6 ou 10 sessões reais. Ajuste em `config.json` (chave desconhecida ou valor inválido é erro, não "usa o padrão") depois de olhar `readings.jsonl`.

## Encher o nó: relógio próprio, CPU e carga externa (ga-2hd02v.2)

Decisão do Athos (20/10, resposta ao AskUserQuestion do Mayor, verbatim): *"se está 100% ocupado a gente fica feliz. o que nao pode é ficar menos do que 100% ocupado"* — quem ocupa o nó (o Traço BIM dele ou os builders da cidade) não importa. Medido nesse dia (média de CPU por hora, `.gc/hetzner-occupancy.jsonl`): 0–15 % entre 00h e 06h, 75–90 % de 07h a 11h, 40–62 % de 12h a 15h, com a cidade presa em 1 vaga. Três causas, três mudanças:

| causa | mudança | onde |
|---|---|---|
| a leitura só era feita quando o Pilot pedia o veredito (varredura de 25–40 min, ~2 leituras por janela): o degrau nunca subia | job `com.gascity.hetzner-capacity-step` roda `hetzner-capacity.py step` a cada **180 s**; a janela vira 480 s com 3 leituras (a escada 1→3→6→10 sobe em ~27 min com carga, não em horas) | `scripts/com.gascity.hetzner-capacity-step.plist`, `DEFAULTS` |
| subia só com 35 % de CPU **livre**: a cidade nunca levava o nó acima de ~65 % | verde = sobra para mais uma sessão: CPU livre ≥ **10 %** (~1,6 núcleo dos 16) | `cpu_up_headroom_pct` |
| 2 leituras vermelhas por CPU derrubavam o degrau, e a CPU podia ser do Traço BIM | o degrau só desce por **RAM**. A CPU < 3 % livre ainda faz o veredito do momento ser `node_hot` (a bead nova vai ao mini enquanto durar), mas o degrau fica: na leitura seguinte à saída da carga (≤ 3 min) o veredito volta a `node` com as vagas todas | `lowers_ceiling()`, `cpu_down_headroom_pct` = 3 |

O que **não** mudou: a prova de carga (o degrau só sobe se o nó já teve ≥ degrau sessões ocupadas, lidas com gc e bd), subir um degrau por vez, a RAM como limite duro (20 % desce, 40 % sobe), o cap do provider e o `max_active_sessions`. O que isto **não** faz: não distingue quem usa a CPU (sessão da cidade × externo) e não cria trabalho elegível ao nó — a madrugada parada (00h–07h, degrau 3) era falta de bead elegível, outra frente (as fatias ga-2hd02v.4.x).

**Instalar (Mayor, depois do merge):** copiar o plist para `~/Library/LaunchAgents/`, `launchctl bootstrap gui/$(id -u) <plist>`, e conferir em 3 ciclos (~9 min): `.gc/logs/hetzner-capacity-step.out` ganha uma linha `degrau N — …` por ciclo, e `python3 -I scripts/hetzner-capacity.py status` mostra `reads` subindo de 3 em 3 minutos. A linha da política do Dolt (`wait-for-dolt.policy.tsv`) já está no repo (`isento`: sem o Dolt a leitura de sessões conta o nó cheio, nunca vazio, e a de CPU/RAM segue valendo); registrar o job no `daemon-presence-watchdog.sh` (limite de 3× o ciclo = 540 s, o `.out` ganha uma linha por ciclo) é do Mayor, depois de instalado. **Retirar:** `launchctl bootout gui/$(id -u)/com.gascity.hetzner-capacity-step`; o degrau fica onde está e volta a só mexer quando o Pilot pede veredito.

**Prova ao vivo (um dia sem o Athos usando o nó):** `python3 -I scripts/hetzner-capacity.py hourly --hours 24` — exit 0 e todas as horas ≥ 85 % de CPU ocupada. Hora sem leitura (job parado, nó fora) sai como `SEM LEITURA` e exit 1: não conta como ocupada nem como livre. **Não foi medido aqui**: o mini é do Mayor e o job só existe depois do merge e da instalação; a bateria prova a política com um nó de mentira (`g_fill`, `g_hourly`) e o plist, não o nó vivo. Se, com o degrau em 10 e a CPU a menos de 85 %, a fila de beads elegíveis ao nó estiver vazia, o gargalo é oferta de trabalho, não capacidade.

## O veredito

A primeira condição que falha decide; **só `node` autoriza**.

| ordem | condição | resultado |
|---|---|---|
| 1 | `pause.json` existe (ou não dá para olhar) | MINI `paused` (NÃO SEI `pause_unreadable`) |
| 2 | config do provider ilegível / host sem `cap` | NÃO SEI `provider_config` |
| 3 | host sem `real_sessions_released_by` | MINI `not_released` |
| 4 | config do atalho ilegível | NÃO SEI `shim_config` |
| 5 | `gate_done_bin` nulo ou não executável | MINI `gate_done_off` / `gate_done_not_exec` |
| 6 | nenhuma leitura, ou a última velha | NÃO SEI `no_reading` / `reading_stale` |
| 7 | último ssh não conectou | MINI `node_down` |
| 8 | leitura ilegível | NÃO SEI `reading_unreadable` |
| 9 | vermelho | MINI `node_hot` |
| 10 | sessões do nó ilegíveis | NÃO SEI `sessions_unreadable` |
| 11 | sessões **ocupadas** ≥ **min(degrau, cap do provider)** | MINI `node_full` |
| 12 | o gate do Claude (`hetzner-claude.py gate`) mediu o login do nó **ruim**: `blocked: logged-out`, `blocked: expired` ou `blocked: quota` (ga-2hd02v.7) | MINI `claude_blocked` |
| 13 | o gate do Claude não soube dizer (comando que não executa, prazo, saída fora de 0/1, linha estranha ou vazia, `blocked: unreachable` ou `blocked: unknown`, pergunta que levantou exceção) | NÃO SEI `claude_unknown` |
| 14 | senão (o gate disse `ok`: saída 0 e a linha exata) | **NÓ** `free_slot` |

A condição 5 é o que impede ligar o envio cedo demais: uma bead entregue no nó sem `gate_done_bin` não chega ao gate (ga-2hd02v.1.13) e encalha até o `inflight-reclaim-guard` reclamá-la em 25 min.

**As condições 12 e 13 (ga-2hd02v.7).** Em 20/10 o login do Claude do nó bateu o limite semanal (`resets Oct 22, 4pm (UTC)`) e o Pilot seguiu mandando bead ao nó: a sessão parou no modal do limite (uma dog-remote ficou 85 min parada), porque nada consultava o `hetzner-claude.py gate`. Agora o veredito pergunta ao gate **ao vivo**, em paralelo com a medição do nó (o custo é o da maior das duas, até 30 s; o Pilot dá 40 s ao veredito inteiro), e só `ok` vale NÓ: são três estados, não dois. Login medido ruim = MINI (a linha do gate, com o horário em que a cota renova, vai no detalhe); não saber = NÃO SEI, que **não é** `ok`. O Claude não grava nada aqui (nenhum `pause.json`): quando o gate volta a `ok`, o veredito seguinte volta sozinho a NÓ, e a pausa do Mayor (`pause.json`) continua só dele. Só o `verdict` pergunta (`status`, `read`, `step`, `pause` e `resume` não). O gate guarda o próprio cache (120 s): no máximo um ssh a cada 2 min e, de hora em hora, uma chamada de modelo (haiku, 1 turno); em `quota` ou `expired` ele repete a chamada a cada 15 min, ou na hora em que a cota renova. O gate mede o login **do próprio nó**: se a sessão do nó passar a usar outra credencial (o item 3 da ga-2hd02v.7, não entregue aqui), o gate tem que medir essa mesma credencial. **Não testado:** o gate real chamado pelo ambiente do launchd do Pilot (ele usa por padrão o alias ssh `hetzner-teste`; se esse ambiente não o resolve, o gate diz `blocked: unreachable`, o veredito vira NÃO SEI e o nó deixa de receber bead: falha para o lado seguro, mas pararia o "nó primeiro"; confira depois do merge com `hetzner-capacity.py --json verdict`) e o tempo do veredito inteiro sob carga real.

## Sessão ocupada × sessão viva (ga-2hd02v.1.22)

**O sintoma (19/10):** desde que o nó primeiro foi ligado (15:25) o veredito era `local:node_full` (ativas 3–5, teto 3) e **nenhuma** bead foi ao nó — com as 3 `dog-remote` **ociosas**. O oráculo contava `list-running` (tmux vivas), não trabalho.

**A regra agora.** Uma `dog-remote` conta **ocupada** só se há uma bead `in_progress` atribuída ao alias dela (`dog-remote-<n>`; o nome da sessão no nó, `dog-remote-<id>`, também vale). Sem bead, a sessão é **vaga livre para o oráculo**. O Pilot, por enquanto, só aproveita a vaga se o alias estiver `new` ou `asleep` (ver "Efeito prático até a janela" abaixo): uma `dog-remote` acordada e ociosa conta livre aqui e ocupada lá. Para casar a tmux do nó com o alias o oráculo lê `gc session list --json` (`session_name` → `alias`) e `bd list --status in_progress --json`. A leitura expõe `sessions` (ocupadas, o que o veredito e a prova de carga leem), `sessions_total` (tmux vivas) e `sessions_idle` (vagas livres):

```bash
python3 -I scripts/hetzner-capacity.py --json read | jq '{sessions, sessions_total, sessions_idle, idle_why}'
```

| situação do nó | conta | veredito |
|---|---|---|
| 3 `dog-remote` vivas, nenhuma bead no alias | 0 ocupadas, 3 ociosas | **NÓ** `free_slot` (3 livres) — é o veredito do oráculo; o Pilot só a usa se algum alias estiver `new`/`asleep` |
| 3 vivas, as 3 com bead `in_progress` no alias | 3 ocupadas | MINI `node_full` |
| bead de outro dono (ex.: o próprio dog) ou sem dono | não conta | — |
| sessão sem alias, que o `gc` não lista, ou cujo alias não é de pool (`dog-remote-<n>`): `gate-reviewer-*`, `wa-worker-*`, `dog-remote-adhoc-*` | **sempre ocupada** (não há bead-por-alias que prove que está parada) | como antes |
| **`bd` ou `gc` falhou / estourou 15 s / devolveu lixo ou formato errado** | **todas ocupadas**, motivo em `idle_why` | MINI `node_full` (nunca enche o nó além do teto) |
| `bd` devolveu `[]` (lido, vazio) | ninguém trabalha → vagas | NÓ |

Os três estados valem para as duas leituras: **lido e vazio ≠ falhou**. Falhar nunca vira "ociosa": é o veredito de antes desta mudança. **Prazo:** o `gc session list` leva 10–21 s no mini carregado (load 44, medido em 19/10) e o `bd list` ~3 s; as duas leituras correm em paralelo (custo = a maior, 25 s o gc e 15 s o bd) para caber nos 40 s que o Pilot dá ao veredito, e só são refeitas a cada `refresh_s` (60 s). Estourar o prazo é "ilegível" → ocupadas → `node_full`: se o mini passar muito tempo acima disso, o oráculo volta ao comportamento antigo (seguro, mas sem efeito) — o sinal é `idle_why` com "prazo" no `hetzner-capacity.py --json verdict` (`detail` e `reading.idle_why`). A prova de carga que sobe o degrau também é de sessão **ocupada** — dog ocioso não prova que o nó aguentou o degrau. E só vale a leitura em que o `gc` e o `bd` foram **lidos** (`idle_why` vazio): quando um deles falha, `sessions` guarda o total vivo contado como ocupado, que para o veredito é o inerte (`node_full`) mas como prova de carga seria o contrário (dog ocioso subiria o teto). Leitura assim não prova nada, e também não veta: as outras leituras da janela seguem valendo. Leitura gravada antes desta separação (sem `idle_why`) também não prova. Cobertura: grupo `g_idle` do selftest (3 ociosas com `bd`/`gc` falhando ou estourando o prazo → o teto fica em 1) e os mutantes dele.

**O que este oráculo NÃO resolve sozinho — por que `idle_timeout = "15m"` não esvaziava o nó.** O `idle_timeout` do `agents/dog-remote/agent.toml` **funciona**: o engine mata a sessão ociosa (`session.idle_killed`, `sleep_reason=idle-timeout`, `state=asleep`). Mas o Pilot abre a `dog-remote` com `gc session new`, e a bead dela fica com `session_origin=manual`; no `compute_awake_set` (tag `engwin-20261011b`) toda sessão **manual** não fechada entra no conjunto desejado (`desired[...]="manual"`) — o reconciliador a **reacorda** em 1–9 min como um claude novo, sem bead. O ciclo mata/reacorda repete, e a sessão fica sempre viva e ociosa. O conserto do engine (sessão manual que dormiu por `idle-timeout` fica dormindo até acordo explícito) está em `docs/pending-engine-window/ga-2hd02v.1.22-manual-idle-timeout-stays-asleep.patch` (+ `.README.md`), para a **janela de engine**; sem build nem troca viva.

Efeito prático até a janela: o oráculo já deixa de dizer `node_full`, mas o `_pilot_node_pick_alias` do Pilot só escolhe alias `new`/`asleep` (uma `dog-remote` acordada e ociosa continua bloqueando). Com o patch, a sessão que o `idle_timeout` mata **fica** `asleep` e o Pilot a acorda com a bead (já faz `gc session wake` em alias dormindo).

**Custo enquanto isso (lido em `packs/town-deltas/assets/pilot-dispatcher.sh`, não medido ao vivo):** com todas as `dog-remote` acordadas e ociosas o oráculo diz `node/free_slot` e o `_pilot_node_pick_alias` não acha alias. A isenção do priority yield e a passada só-nó do disk floor, que dependem do veredito `node`, claimam até `effective` beads por varredura e as soltam de volta ("o nó não ficou com a bead … claim solta"). Antes da mudança o veredito era `node_full` e nada era claimado. Quem decide se isso importa até a janela é o Mayor; a alternativa descartada por ora é fazer o Pilot reusar alias acordado-ocioso (decisão (a) do ga-2hd02v.1.22).

**WhatsApp no nó (ga-2hd02v.3): o oráculo não mudou.** A sessão `wa-worker-remote-K` não tem alias de pool de dog; cai na linha "sempre ocupada" da tabela acima, então conta como ocupada enquanto viver e o oráculo já devolve a vaga certa para N slots de WA. Quem lê a ocupação por hora (`hetzner-occupancy.jsonl`) e quantas leituras tinham sessão de WA viva é `scripts/wa-node-report.py` (seção 3); a leitura está em `hetzner-wa-node.md`, "A prova do dia seguinte".

## Como ligar a sombra do Pilot

Só depois do merge, e é do Mayor. Reversível tirando a chave.

1. `~/Library/LaunchAgents/com.gascity.pilot.plist`, em `EnvironmentVariables`: `PILOT_NODE_FIRST` = `shadow`. Depois `launchctl bootout` + `bootstrap` do plist (o Pilot lê o ambiente na partida).
2. Confira com `launchctl print gui/$(id -u)/com.gascity.pilot | grep PILOT_NODE_FIRST` e, na primeira varredura com bead de dog, a linha `node-first (sombra): …` no log do Pilot.
3. Cada consulta pode custar um ssh (≈ 3 s) no máximo a cada 60 s; entre elas o cache responde. Se o ssh ao nó travar, o Pilot espera no máximo 40 s por bead (`timeout`) e registra `unknown`.

Entram só beads de dog do HQ (pool `gastown.dog`, bead da própria cidade). Ficam fora, sem consulta, as marcadas com `node:never`, `needs:engine-window` ou `exec:manual` (`PILOT_NODE_FIRST_VETO_LABELS`; o veto vale por token inteiro).

## Como ler a sombra

`.gc/logs/node-first-shadow.jsonl`, uma linha por bead: `{story, ts, shadow:true, verdict, reason, ceiling, effective, active, free, reading…}`.

```bash
# quantas iriam ao nó e por que as outras não
jq -s 'group_by(.verdict+":"+.reason) | map({k: .[0].verdict+":"+.[0].reason, n: length}) | sort_by(-.n)' "$GC_CITY_PATH/.gc/logs/node-first-shadow.jsonl"
```

Leia com `status` ao lado: se quase tudo é `local gate_done_off`, o gargalo é a 1.13, não o nó.

## Ligar e desligar o nó primeiro (`on`)

Bead ga-2hd02v.1.14. **Ligar é do Mayor**, depois das pré-condições abaixo; o merge entrega a chave em `off`. `PILOT_NODE_FIRST` = `off` (padrão) | `shadow` (só registra) | `on` (leva a bead ao nó).

**Pré-condições para `on`** (o Mayor confere, nesta ordem):

1. `shadow` rodando **≥ 2 h** com **≥ 20 decisões** no `node-first-shadow.jsonl`, e a proporção `node`/`mini` lida (seção anterior): se quase tudo é `mini gate_done_off`, o `on` não tem o que despachar.
2. `scripts/hetzner-capacity.py status` mostra degrau ≥ 1, `gate_done_bin` ligado (ga-2hd02v.1.13) e o nó sem `pause.json`.
As beads com `node:never`, `needs:engine-window` ou `exec:manual` ficam no mini também com `on` (o mesmo veto da sombra, sem consulta).

**O que o Pilot faz** com `on`, por bead de dog do HQ (pool `gastown.dog`, nunca WA/PS — essas são da ga-2hd02v.1.10), quando o oráculo diz `node` (exit 0, JSON `node`, `effective` inteiro > 0):

1. escolhe o 1º alias `dog-remote-<n>` livre com `n ≤ effective` (lê `gc session list --json`; alias dormindo é **acordado**, não duplicado; vaga conta por template, não só por alias);
2. `bd update <bead> --assignee dog-remote-<n> --status in_progress` (o atalho do nó nega `bd update --claim`, então a bead já chega atribuída e o dog a acha com `bd list --status in_progress --assignee "$GC_ALIAS"`);
3. `gc session new dog-remote --alias dog-remote-<n> --no-attach` (ou `session wake`), dentro de `PILOT_SPAWN_TIMEOUT_SECS`; uma sessão lenta gasta o orçamento de spawn do sweep, como no caminho do mini;
4. `gc session nudge dog-remote-<n>` com o aviso, e grava `pilot.sling_bead`. Resultado do despacho: **`node_ok`**.

O alias remoto já conta como **builder vivo** para o `inflight-reclaim-guard` e para o TTL (o alias casa com id/name/alias da sessão e o `last_active` é fresco); a bateria trava isso. Sem sessão viva ou sem sinal de vida, o reclaim solta a bead no TTL de sempre (25 min).

**Falha em qualquer passo = a bead vai ao mini.** O Pilot fecha a sessão (se chegou a tocá-la) e só depois solta a bead com uma escrita guardada (`bd update --if-assignee dog-remote-<n> --assignee "" --status open`: nunca pisa em quem pegou a bead depois), e **confirma lendo a bead** (sem dono e `open`). Confirmado → segue o despacho normal ao mini. **Não confirmado** (bead ilegível, com outro dono, ou ainda `in_progress`) → o Pilot **não** manda ao mini (a bead poderia ser construída duas vezes), deixa o claim para o TTL (30 min) e conta **`node_rollback_unconfirmed`**, que aparece em `failed_other` do evento `pilot_sweep`, de propósito: é falha, não política.

**O priority yield não segura a bead que o nó quer (ga-2hd02v.1.19).** O yield da ga-5fn5p3 ("capacidade vai à prioridade": enquanto uma P0/P1 espera vaga num pool cheio, nenhuma P2+ abre sessão em pool algum) protege a capacidade do **mini**; a vaga do nó não é a que essa P0 espera (uma bead do WA vai ao wa-worker, não ao dog-remote). Medido em 19/10 16:35, na 1ª varredura com `on`: `priority yield: 192 P2+ candidate(s) ceded this sweep to P0 wa-7rjyod (wa-worker 2/2)`, `dispatched=0` e o `node-first-shadow.jsonl` sem linha nova: o yield cedia **antes** do gancho do nó. Agora, com `on`, a bead de dog do HQ (sem rótulo de veto, não rig-native) **não cede** se o oráculo diz `node` com `effective` > 0: uma consulta ao oráculo por varredura e no máximo `effective` beads isentas por varredura (o resto cede sem escrever nada). Cede como antes quando o oráculo diz `local`, não sabe, não respondeu ou respondeu incoerente, e também com `shadow` (só registra), `off` e `DRY_RUN`. A bead isenta que o nó não ficou com (sem alias livre, sessão que não abriu, aviso que falhou, 2ª consulta que já diz `local`) **cede na hora**: nunca cai no mini por isso, porque o mini é o que o yield protege. No log, `ga-2hd02v.1.19: <id> … NÃO cede a P0 …` marca a isenção e `cedida a P0/P1 … o nó não ficou com a bead` marca a que cedeu depois. Prova: `pilot-dispatcher.node-yield.selftest.sh`. **Não cobre** o pool top-up do dog (`_pilot_priority_yield_for_id`).

**A varredura pausada por disk floor ainda faz a passada só-nó (ga-2hd02v.1.20).** A pausa por disk floor (`disk_free` abaixo de 5120 MB; o swap do mini faz o disco oscilar 3–6 GB: 33 de 53 varreduras em 19/10) protege o disco do **mini**, e despachar ao nó não o gasta (o worktree e o build são no Hetzner). Com `on`, fora do `DRY_RUN` e com o disco **confirmado** baixo, a varredura não sai mais no gate: segue em **passada só-nó**, e a pausa `disk-floor` continua gravada para o painel. Nela só vai adiante a bead de dog do HQ com veredito `node` e vaga (a mesma regra do priority yield acima) e, com `PILOT_WA_NODE_ROUTE=label|auto`, a bead de WA que o gancho do nó de WA leva (ga-8okir7: `hetzner-wa-node.md`, "A escada de modos do Pilot"; e, com `PILOT_WA_NODE_EXEMPT=on|shadow`, a passada de WA no nó também roda nela e leva a bead carimbada `wa-worker` que a pista da só-nó descartaria: ga-2hd02v.3.9, `hetzner-wa-node.md`, "A passada de WA no nó"); o que não é candidata é pulado **antes** da claim, sem escrever nada; a que o nó não ficou solta a claim e **nunca** vai ao mini; não há pool top-up (a guarda é o 1º gate de `_pilot_pool_topup`; as duas chamadas ficam no topo do arquivo, sem `if`, porque TOPUP-6 e ga-swnsg3-e do selftest grande exigem); o limpa-pausa não roda; e a varredura não conta nem zera o streak de estagnação do Step 5 nem o contador de cessões consecutivas do priority yield (a checagem do ga-2lca0l, chamada em toda varredura no topo do arquivo, sai na 1ª guarda dela nessa passada: com `PRIORITY_YIELDED` em 0 ela o apagaria). Oráculo mudo, ilegível ou `local` = nada. Cota 5h e pressão de RAM pausam tudo antes do gate; drain e quiet hours pausam tudo depois dele. `off`, `shadow`, valor desconhecido e `DRY_RUN` pausam como antes, e disco ilegível segue o fail-open de sempre (não liga a passada). No log, `Disk floor: passada só-nó` marca a varredura, e o desfecho dos pulados é `disk_floor_node_only` em `refused_by_guard` do evento `pilot_sweep` (desfecho de guarda, não falha). Prova: `pilot-dispatcher.disk-floor-node-only.selftest.sh`.

**Como ler:**

```bash
# nos logs do Pilot: o que foi ao nó e o que voltou
grep -E "node-first \(on\)|Dispatch complete \(node\)|ga-2hd02v.1.14" "$GC_CITY_PATH/.gc/logs/pilot-dispatcher.log" | tail -40
# beads hoje no nó
bd list --status in_progress --json --limit 0 | jq -r '.[] | select((.assignee // "") | test("^dog-remote-[0-9]+$")) | "\(.id) \(.assignee)"'
```

Se `node_rollback_unconfirmed` aparecer, olhe a bead (`bd show <id>`): se ainda estiver atribuída a `dog-remote-<n>` sem sessão viva, `bd update <id> --assignee "" --status open` a devolve ao pool; se o dono for outro, não mexa.

**Desligar** (na hora, sem perder nada): tire `PILOT_NODE_FIRST` do plist (volta a `off`) ou ponha `shadow`, e `launchctl bootout` + `bootstrap`. Beads já no nó **terminam lá** ou voltam pelo reclaim no TTL; o Pilot não puxa de volta bead em andamento. Para travar só o envio sem reiniciar o Pilot: `scripts/hetzner-capacity.py pause --reason <texto>` (próximo veredito já diz `mini paused`).

**`DRY_RUN=1`** com `on` não consulta o nó (a consulta mede e grava estado) e imprime o plano de 4 passos por bead de dog (ou o veto que a deixa no mini); nada é escrito.

## Subir os tetos fixos

O degrau é o teto de **operação**; o limite duro são dois números fixos que hoje estão baixos: `cap` do host em `.gc/session-ssh.json` (4) e `max_active_sessions` em `agents/dog-remote/agent.toml` (1). O veredito usa o **menor** entre o degrau e o `cap`, então com `cap` 4 o degrau 6 e 10 não adiantam. Suba os dois **só quando o degrau chegar lá** (`status` mostra), em janela de config viva e com backup ao lado; o `cap` vale no próximo start (conferido no código: cada operação do provider é um processo novo que lê o JSON de novo); o `max_active_sessions` é do engine e **não foi testado aqui** se vale sem recarga, então confira antes de contar com ele.

## O que falta para o "nó primeiro" de verdade

1. **ga-2hd02v.1.13** no ar (`gate_done_bin` ligado).
2. **ga-2hd02v.1.14** (entregue, desligado): o valor `on` do Pilot, descrito acima.
3. A sombra rodando ≥ 2 h com ≥ 20 decisões (pré-condição do `on`), lida; ≥ 24 h é o ideal.
4. A decisão do Mayor de ligar `on`. Não testado até aqui com o Pilot vivo: ver abaixo.

## Medido, inferido, não testado

**Medido (19/10, 03:5x −03, contra o nó vivo, só leitura):** `read` devolveu CPU livre 64,9–65,0 %, RAM disponível 93,8–94,3 %, 16 núcleos, 1 sessão (o `dog-remote-1`); `vmstat 2 2` e `free -m` no próprio nó deram RAM 93,8 % e ocioso instantâneo 74 %, coerentes (o número do script é o mais conservador por desenho). O nó **não tem swap** (`SwapTotal 0`). Bateria `scripts/hetzner-capacity.selftest.sh` no nó (`mbp-run.sh --repo hq`): 68 s, contra 5 min 39 s no mini sob load 60–70; os mutantes da bateria reprovam todos.
**Inferido:** os limiares de CPU e RAM (CPU 10/3 % desde a ga-2hd02v.2, antes 35/10 %; RAM 40/20 %) e a janela de 480 s (antes 30 min); que uma sessão `claude` ociosa pesa pouco na CPU do nó.
**Não testado:** `PILOT_NODE_FIRST=on` no Pilot vivo (a ga-2hd02v.1.14 foi provada com a bateria `pilot-dispatcher.node-dispatch.selftest.sh` e seus mutantes, sem `gc` nem `bd` reais); a isenção do priority yield (ga-2hd02v.1.19) com uma P0 do WA presa em pool cheio no Pilot vivo (só stubs: `pilot-dispatcher.node-yield.selftest.sh`); a passada só-nó do disk floor (ga-2hd02v.1.20, e a bead de WA que ela leva desde a ga-8okir7) numa varredura viva com o disco do mini abaixo do piso (só as regiões extraídas do dispatcher e o helper com oráculo falso, `pilot-dispatcher.disk-floor-node-only.selftest.sh`: nenhuma varredura inteira com `bd` falso); uma sessão real com carga de build no nó; o custo do `verdict` dentro de uma varredura real do Pilot sob load 60+; `PILOT_NODE_FIRST=shadow` no Pilot vivo; os degraus 6 e 10.

## Limites

O contador de sessões vem do `list-running` do provider (o socket dele), não de todo processo do nó: carga de outro inquilino (as baterias do `mbp-run.sh`, a ga-zri39b) aparece na CPU e na RAM, não nas sessões. O oráculo decide por UM nó; MBP e outros hosts são outra conversa. A sombra mede o que o Pilot **perguntaria**, não o que o nó aguentaria sob o envio real: quando o `on` existir, o degrau 1 é a primeira medição de verdade.
