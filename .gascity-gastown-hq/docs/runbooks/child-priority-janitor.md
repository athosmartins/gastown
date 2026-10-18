# child-priority-janitor — fatia nasce com a prioridade do pai (ga-p7hymz)

## Contents

• O problema · O que o janitor faz · O que ele NÃO mexe · Como ligar (dry-run primeiro) · Como desligar · Como provar que funciona · Números medidos (18/10/2026) · Limites conhecidos

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

Registrar no `daemon-presence-watchdog.sh`: o nome do job em `DPW_CRITICAL` e a linha `com.gascity.child-priority-janitor|$HQ/.gc/logs/child-priority-janitor.out|<segundos>` no mapa de heartbeat (o log é o batimento: o janitor escreve uma linha por sweep). Registrar **antes** de carregar acende CRITICAL; carregar sem registrar deixa o job morrer sem ninguém ver. Por isso os dois no mesmo passo. Intervalo de heartbeat sugerido: mais que 2× o `StartInterval` (≥ 600).

Para subir só em dry-run por um dia, ponha `CHILD_PRIORITY_JANITOR_DRY_RUN=1` no plist antes de carregar e tire depois de conferir o log.

## Como desligar
- `CHILD_PRIORITY_JANITOR_ENABLED=0` no `EnvironmentVariables` do plist (e recarregar o job): o sweep vira no-op e ainda escreve as linhas `start` / `kill-switch` no log, então o DPW não grita.
- `launchctl bootout gui/$(id -u)/com.gascity.child-priority-janitor` para parar de vez (e tirar do `DPW_CRITICAL` na mesma mudança).
- Reverter uma subida: `bd update <id> -p <n>` e `bd label add <id> priority:pinned` (o carimbo já impede nova subida; o label deixa a intenção escrita).

Outros ajustes: `CHILD_PRIORITY_JANITOR_MAX_PER_SWEEP` (padrão 15: um erro de leitura não promove o backlog inteiro), `CHILD_PRIORITY_JANITOR_BD_TIMEOUT` (60 s por chamada).

## Como provar que funciona
```bash
python3 scripts/child-priority-janitor.py --selftest    # 39 casos
```
Cobre, entre outros, os três casos pedidos na issue: filho P2 de pai P0 → P0; follow-up → intacto; pai com prioridade ilegível → intacto (fail-closed). Prioridade 0 é tratada de forma explícita (0 é falso em Python: `if prio:` perderia todos os pais P0). A suíte foi mutacionada (14 mutantes + 1 achado de lacuna, `ptarget != cur`, que ganhou o caso "filho sob intermediário mais urgente"): cada mutante reprova o selftest; o único sobrevivente conhecido (`want != cur` no laço principal) é equivalente, porque `target()` nunca devolve valor maior que o atual.

```bash
bash scripts/child-priority-janitor.selftest.sh         # 17 casos, com `bd`/`gc`/`notify` de mentira
```
O `--selftest` troca todo I/O por função falsa e nunca roda o código que chama `bd`/`gc` e lê o que eles imprimem; o `.selftest.sh` roda o janitor de verdade contra executáveis de mentira que FALHAM (rc 1, lixo, saída vazia, binário ausente, timeout, `update` que sai 0 e não grava, releitura ilegível) e confere que ele fica inerte: nenhum `bd update`, nenhum comentário, loja ilegível pulada e contada, rc 1. Nove mutantes (tirar o teste de rc, aceitar lixo ou vazio como "sem filhos", tirar a releitura, deixar a exceção subir, tirar o kill-switch ou o dry-run) reprovam esse teste.

Em produção, a prova é a releitura: depois de um sweep, `bd show <id> --json | jq .priority` no filho tem que ser o do pai, e o comentário do janitor está no bead.

## Números medidos (18/10/2026)
Dry-run ao vivo em todas as lojas: **7 candidatos** (3 no HQ, 4 na whatsapp_automation), todos coerentes (pai mais urgente, filho aberto, sem isenção). Tempo de uma rodada: **~22 s** — por isso `StartInterval` 297, bem acima da rodada (um detector custa poll: ga-y0g5x), fora dos 300 s / 318 s dos outros janitors para não somar a tempestade de conexões no Dolt. Trava `flock` de instância única: duas rodadas nunca se sobrepõem.

## Limites conhecidos
- A espera é de até um sweep (~5 min): a fatia pode ser pega pelo Pilot como P2 nesse intervalo. A regra de criação (`-p <prio do pai>`) é o que fecha essa janela; o janitor cobre quem esquece.
- Só olha o `parent` explícito do bead; não deduz pai pelo prefixo do id (`wa-x.1.2` → `wa-x.1`), ao contrário de `feature_slice_type.py`. Fatia sem campo `parent` fica de fora.
- Subir prioridade desloca trabalho na fila do Pilot e do gate: é o efeito pretendido, mas o dry-run deve ser lido antes do primeiro sweep real.
