# child-priority-janitor — fatia nasce com a prioridade do pai (ga-p7hymz)

## Contents

• O problema · O que o janitor faz · O que ele NÃO mexe · Como ligar (dry-run primeiro) · Como desligar · Quando uma loja não lê (ga-u4z4hwb) · Como provar que funciona · Números medidos (18/10/2026) · Limites conhecidos

## O problema
`bd create --parent` não herda a prioridade do pai: a fatia nasce P2 e quem fatia esquece o `-p`. O Pilot e o gate ordenam por prioridade, então 4 cortes da ga-w7qwl1.1 (P0) foram tratados como P2. A regra na hora de criar está na doutrina (`town-deltas`, "Fatia nasce com a prioridade do pai"):

```bash
bd create --parent <pai> -t <tipo do pai> -p <prio do pai> ...
```

O janitor é a rede de segurança para o que escapa dessa regra. O `bd` é binário externo, então não dá para fazê-lo herdar na criação sem mexer no motor; a janela de espera é de um sweep (~5 min).

## O que o janitor faz
`scripts/child-priority-janitor.py`, a cada 297 s (`com.gascity.child-priority-janitor.plist`), em todas as lojas (HQ + as rigs de `gc rig list --json`, com lista estática de reserva).

Por loja, lista os beads abertos (`open`, `hooked`, `in_progress`, `blocked`) com `parent` e, para cada filho **mais baixo** que o pai (número maior = menos urgente):
1. sobe o filho para a prioridade do pai (ou do avô, se o pai também vai subir: a conta é feita pela cadeia, até 12 níveis);
2. grava o carimbo `gc.prio_inherited` no metadado;
3. **relê** o bead e só conta como feito se a prioridade lida é a nova (o código de saída do `bd` já mentiu antes);
4. comenta no bead dizendo o que mudou e como se opor.

**Só sobe e só uma vez por bead.** Filho mais urgente que o pai (um bug P0 cortado de uma épica P2) nunca é rebaixado. Se um humano baixar a prioridade depois, o carimbo impede o janitor de brigar.

## O que ele NÃO mexe
| Caso | Por quê |
|---|---|
| label `followup:nonblocking`, ou título com "não-bloqueante" / "non-blocking" | follow-up dos achados não-bloqueantes do gate: nasce mais baixo de propósito |
| label `priority:pinned` | saída manual: "esta prioridade é de propósito" |
| bead já carimbado `gc.prio_inherited` | uma subida por bead; o humano que baixou depois é respeitado |
| pai fechado, sumido ou **com prioridade ilegível** | fail-closed: "não consegui ler" nunca vira "suba". Follow-up sob história já feita é exatamente a dívida que deve ficar onde está |
| tipo fora de feature / bug / task / chore / epic (moléculas, marcadores do gate, ordens) | não são fatias |

`gate:nonblocking-findings` **não** é isenção: ele fica no bead-FONTE dos achados, não no follow-up, e isentá-lo deixaria a fatia real de uma P0 de fora.

Nenhum processo põe `followup:nonblocking` hoje (checado em 18/10): a isenção vale pelo título e pelo label quando alguém passar a usá-lo. Quem criar follow-up dos achados do gate deve pôr o label.

## Como ligar (dry-run primeiro)
O arquivo no repositório **não está carregado**: mergeado ≠ vivo.

```bash
# 1. dry-run na mão: lista o que SUBIRIA, não escreve nada
CHILD_PRIORITY_JANITOR_DRY_RUN=1 python3 scripts/child-priority-janitor.py

# 2. conferir cada linha "DRY_RUN: would raise <loja> <id>: P2 -> P0 (pai <id>)":
#    o pai é mesmo mais urgente? é fatia de verdade?

# 3. carregar e registrar JUNTOS (mesma mudança)
cp scripts/com.gascity.child-priority-janitor.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gascity.child-priority-janitor.plist
```

Registrar no `daemon-presence-watchdog.sh`: o nome do job em `DPW_CRITICAL` e a linha `com.gascity.child-priority-janitor|$HQ/.gc/logs/child-priority-janitor.out|900` no mapa de heartbeat (o log é o batimento: o janitor escreve uma linha por sweep). Registrar **antes** de carregar acende CRITICAL; carregar sem registrar deixa o job morrer sem ninguém ver. Por isso os dois no mesmo passo. Intervalo de heartbeat sugerido: mais que 2× o `StartInterval` (≥ 600). Feito em 19/10 (ga-p7hymz.1): 900 s = 3× o `StartInterval` de 297 s; o cenário 22c do `daemon-presence-watchdog.sh --selftest` trava a entrada (rótulo em `DPW_CRITICAL`, limite > 2× o intervalo do plist, arquivo = `StandardOutPath` do plist).

Para subir só em dry-run por um dia, ponha `CHILD_PRIORITY_JANITOR_DRY_RUN=1` no plist antes de carregar e tire depois de conferir o log.

## Como desligar
- `CHILD_PRIORITY_JANITOR_ENABLED=0` no `EnvironmentVariables` do plist (e recarregar o job): o sweep vira no-op e ainda escreve as linhas `start` / `kill-switch` no log, então o DPW não grita.
- `launchctl bootout gui/$(id -u)/com.gascity.child-priority-janitor` para parar de vez (e tirar do `DPW_CRITICAL` na mesma mudança).
- Reverter uma subida: `bd update <id> -p <n>` e `bd label add <id> priority:pinned` (o carimbo já impede nova subida; o label deixa a intenção escrita).

Outros ajustes: `CHILD_PRIORITY_JANITOR_MAX_PER_SWEEP` (padrão 15: um erro de leitura não promove o backlog inteiro), `CHILD_PRIORITY_JANITOR_BD_TIMEOUT` (60 s por chamada).

## Quando uma loja não lê (ga-u4z4hwb)
Cada loja que o `bd list` não consegue ler vira uma linha `WARN: bd list failed/unreadable in <loja> …: <causa>`. A causa é o que o `bd` disse, numa linha só e cortada em 300 caracteres:
- `bd list rc=1: <stderr>`: o `bd` rodou e falhou (`(empty stderr)` quando não escreveu nada);
- `bd list did not run (see the subprocess WARN above)`: estouro de tempo, binário ausente ou saída que não decodifica; a linha `WARN: subprocess failed` logo acima traz a exceção;
- `bd list rc=0 but stdout is not a JSON list: <cabeça do stdout>`: saiu 0, mas a saída não é a lista (vazia também cai aqui: "não consegui ler" nunca vira "loja sem filhas").

`bd update`, `bd show` e `bd comment` que falham ganham a mesma linha de causa (`WARN: bd update rc=1: <stderr> (<id>)`).

| Loja que não leu | Linha no log | rc do sweep |
|---|---|---|
| HQ, ou rig ativa (`suspended` ausente, `false`, texto ou número: só o booleano `true` isenta) | `… — store skipped (NOT read as 'no children')` | **1**, mesmo que o sweep tenha subido outra bead. Antes valia `unreadable and not raised`: uma subida em outra loja escondia a que não foi lida (reproduzido: rig ilegível + 1 subida no HQ saía 0) |
| rig com `"suspended": true` em `gc rig list --json` | `… (rig SUSPENDED) — store skipped, not counted toward the exit code` | não conta: rc 0 se nada mais falhou |

A rig suspensa **é lida** como as outras (as filhas dela sobem); só a falha de leitura dela não derruba o sweep. A linha final separa as duas: `unreadable_stores=3 (active=1 suspended=2)`.

### O Dolt isca de 23–24/11
O que o Mayor mediu ao vivo (comentário de 24/11 14:56 na ga-u4z4hwb; este conserto foi escrito no nó Hetzner, sem acesso ao mini, e não reproduziu isso):
1. depois do reboot de 23/11 23:41 o Dolt de produção estava na 52757 (era a porta dele quando o Mayor corrigiu, em 24/11);
2. às 23:43 um `bd` sob o launchd, sem `BEADS_DOLT_AUTO_START=0`, **subiu um Dolt local** (o isca) para gastown, lexbh e marketing, as rigs com `.beads/redirect` (config `mayor/rig/.beads/dolt-server-config.yaml`, porta 52756), e gravou 52756 em `mayor/rig/.beads/dolt-server.port`. O isca não tinha banco nenhum e respondia "database not found" a todo job que lia essas rigs: este janitor saiu 1 a cada sweep (o daemon-presence marcou CRASH-LOOP) e o Pilot contou as pistas como cheias;
3. o Mayor trocou os arquivos de porta pela porta viva e encerrou o isca.

Não foi medido por que o `bd` decidiu subir um servidor em vez de usar o de produção. O que já se sabia: o `dolt-port-pin-guard.sh` aponta as cópias de `dolt-server.port` das rigs com redirect como as que ninguém renova depois que a porta muda (ga-3v2zt00).

O que o janitor faz agora para não criar isso: todo `bd` que ele roda leva `BEADS_DOLT_AUTO_START=0` (o script força o valor, mesmo que o ambiente traga 1; o plist traz o mesmo). É o mesmo botão que o `gc` já liga nos `bd` que ele roda (README da ga-3risy2: «bd itself does not auto-start a server here»): sem servidor próprio para recorrer, uma porta que não responde vira erro no log (`Dolt server unreachable at …`) e nada fica ouvindo. O script vale assim que o merge chega à árvore da cidade; o plist só vale depois de reinstalado (`launchctl bootout` + `bootstrap`).

**Não testado ao vivo:** o nó onde isto foi escrito não tem `bd` nem Dolt. O selftest prova que o valor 0 chega a todo filho `bd` e que o log traz o que o `bd` escreveu em stderr; o que o `bd` faz com a variável é o contrato acima, não uma medida. Também é suposição (da bead) que o `bd` escreve o erro em stderr: se ele o escrevesse em stdout, o log diria `(empty stderr)` e a causa continuaria invisível, o que se confere no primeiro `WARN` real.

Como o isca aparece de fora: rigs com redirect falhando com "database not found" enquanto o HQ lê bem, e um `dolt-server.port` diferente da porta viva. O `dolt-port-pin-guard.sh` (se estiver carregado) alerta nesse segundo caso. Antes de encerrar qualquer processo, descubra qual é o `dolt sql-server` de produção com `dolt_server_pid` (`scripts/dolt-pid-lib.sh`), nunca por `pgrep | head -1`, e escale ao Mayor.

**Fora deste conserto** (a CLASSE ficou aberta aqui; a ga-d3ryi7k, em `docs/runbooks/bd-dolt-auto-start.md`, fecha o que o repositório controla): os outros plists da cidade não traziam `BEADS_DOLT_AUTO_START=0` (medido em 24/11: 38 em `scripts/` e 65 em `packs/town-deltas/assets/`), então qualquer outro `bd` sob o launchd podia repetir o isca; `dolt.auto-start: false` no `.beads/config.yaml` das rigs com redirect fecharia pela raiz, mas esses arquivos moram nos repositórios das rigs; e o Pilot (o Mayor cita a ga-1fssl) seguia lendo pista que não leu como "pista cheia". **Situação depois da ga-d3ryi7k:** os 103 plists do repositório trazem a variável e um lint no pre-push recusa plist novo sem ela; o Pilot passou a dizer «NÃO MEDIDAS» e a manter a passada do nó; continuam por fazer, no mini, a cópia instalada dos plists e o `dolt.auto-start: false` nas rigs (o runbook novo traz os comandos e a prova).

## Como provar que funciona
```bash
python3 scripts/child-priority-janitor.py --selftest    # 67 casos
```
Cobre, entre outros, os três casos pedidos na issue: filho P2 de pai P0 → P0; follow-up → intacto; pai com prioridade ilegível → intacto (fail-closed). Prioridade 0 é tratada de forma explícita (0 é falso em Python: `if prio:` perderia todos os pais P0). A suíte foi mutacionada (14 mutantes + 1 achado de lacuna, `ptarget != cur`, que ganhou o caso "filho sob intermediário mais urgente"): cada mutante reprova o selftest; o único sobrevivente conhecido (`want != cur` no laço principal) é equivalente, porque `target()` nunca devolve valor maior que o atual.

```bash
bash scripts/child-priority-janitor.selftest.sh         # 50 casos, com `bd`/`gc`/`notify` de mentira
```
O `--selftest` troca todo I/O por função falsa e nunca roda o código que chama `bd`/`gc` e lê o que eles imprimem; o `.selftest.sh` roda o janitor de verdade contra executáveis de mentira que FALHAM (rc 1, lixo, saída vazia, binário ausente, timeout, `update` que sai 0 e não grava, releitura ilegível) e confere que ele fica inerte: nenhum `bd update`, nenhum comentário, loja ilegível pulada e contada, rc 1. Nove mutantes (tirar o teste de rc, aceitar lixo ou vazio como "sem filhos", tirar a releitura, deixar a exceção subir, tirar o kill-switch ou o dry-run) reprovam esse teste.

Mutação da ga-u4z4hwb (24/11, nó Hetzner): dos 121 candidatos do `hq-mutate.py gen` neste arquivo, 120 morrem e o único sobrevivente é o equivalente já declarado no `.selftest.sh` (`51343d2b3a`, `ptarget < cur`, linha 175: por isso as linhas acima de `_parse_list` não mudaram, o id carrega a linha). Mais 36 mutantes escritos à mão, que o motor não gera (valor do `AUTO_START`, tetos de 300 e 120 caracteres, a política do rc, os `WARN` de `show`/`update`/`comment`, `suspended` lido como verdadeiro-ou-falso, dry-run sem a variável), morrem todos. E os 21 casos novos do `.selftest.sh` reprovam o janitor anterior: contra o código de antes, 29 ok e 21 falhas.

Em produção, a prova é a releitura: depois de um sweep, `bd show <id> --json | jq .priority` no filho tem que ser o do pai, e o comentário do janitor está no bead.

## Números medidos (18/10/2026)
Dry-run ao vivo em todas as lojas: **7 candidatos** (3 no HQ, 4 na whatsapp_automation), todos coerentes (pai mais urgente, filho aberto, sem isenção). Tempo de uma rodada: **~22 s** — por isso `StartInterval` 297, bem acima da rodada (um detector custa poll: ga-y0g5x), fora dos 300 s / 318 s dos outros janitors para não somar a tempestade de conexões no Dolt. Trava `flock` de instância única: duas rodadas nunca se sobrepõem.

## Limites conhecidos
- A espera é de até um sweep (~5 min): a fatia pode ser pega pelo Pilot como P2 nesse intervalo. A regra de criação (`-p <prio do pai>`) é o que fecha essa janela; o janitor cobre quem esquece.
- Só olha o `parent` explícito do bead; não deduz pai pelo prefixo do id (`wa-x.1.2` → `wa-x.1`), ao contrário de `feature_slice_type.py`. Fatia sem campo `parent` fica de fora.
- Subir prioridade desloca trabalho na fila do Pilot e do gate: é o efeito pretendido, mas o dry-run deve ser lido antes do primeiro sweep real.
