# Dolt em prioridade baixa (nice ≠ 0) — detecção, cura e prevenção (ga-0k78d4)

**Sintoma:** notify **"Dolt em prioridade baixa"** (ou a linha `NICE ALARM` em
`.gc/logs/dolt-latency-alarm.log`). O `dolt sql-server` **vivo** roda com nice ≠ 0.
Sob contenção ele perde CPU para qualquer processo nice-0: **lento por construção**, e as
medianas de latência/conexões do alarme vizinho não apontam isso como causa.

**Quem age:** Mayor (ou Athos, num terminal nice 0). **Sessão pool/efêmera não reinicia o Dolt.**

---

## Por que acontece

1. **ga-rj7b1a** (`scripts/claude-lowprio.sh`) faz toda sessão pool/efêmera (dog, wa/ps-worker,
   gate-reviewer, refiners, deacon, boot) nascer em **nice 15**, e tudo que ela dispara herda esse
   nice. **Ainda não está no ar** (19/09: em `gate:queued`; o shell de uma sessão pool mediu nice 0)
   — o detector foi posto **antes**, e já vale hoje: qualquer pai com nice ≠ 0 produz o mesmo
   efeito (regra 3 abaixo: `cmd &` no zsh roda em nice +5).
2. O Dolt **não** é blindado disso: `gc-beads-bd.sh` (system pack, ~linha 2098) sobe o servidor
   como **filho de quem rodou** `gc dolt start|restart` — `nohup sh -c 'exec dolt sql-server …' &`,
   sem `nice`/`renice`/`taskpolicy`. Um start feito à mão de dentro de uma sessão embrulhada
   deixa o Dolt em nice 15 — o **oposto** do que ga-rj7b1a quer.
3. **Não afeta** o respawn normal: o supervisor roda em nice 0 (filho do launchd).

## O que o detector faz — e o que NÃO faz

Roda **dentro do job que já existe** (`com.gascity.dolt-latency-alarm`, launchd, a cada 60 s, com
trava de instância única): sem job novo, sem poll novo. **Só detecta** — não faz renice, restart
nem kill. Três estados, nunca colapsados:

| estado | quando | efeito |
|---|---|---|
| **ok** | nice do PID vivo = 0 | silêncio; se havia alarme ativo, limpa e avisa "Dolt voltou a nice 0" |
| **alarme** | nice ≠ 0 (positivo ou negativo) | **um** notify por episódio (marcador `/tmp/dolt-latency-alarm.nice-active`) |
| **desconhecido** | sem Dolt vivo, ou `ps` falhou / devolveu algo que não é UM inteiro | **nunca vale como 0**: não levanta nem limpa alarme; loga; após 3 ticks seguidos avisa **uma vez** "não consegui ler o nice" |

- O PID vem de `dolt_server_pid` (`scripts/dolt-pid-lib.sh`: executável `dolt` **e** socket LISTEN
  verificados), nunca de arquivo nem de `pgrep | head -1`.
- Alarme de nice e alarme de latência têm **marcadores separados** — um nunca limpa o outro.
- Kill switch: `DOLT_LATENCY_ALARM_ENABLED=0` (loga, não notifica; vale para os dois sinais).
  Limiar do "detector cego": `DOLT_NICE_UNKNOWN_NOTIFY_AFTER` (padrão 3; valor inválido volta a 3).
- Custo medido (19/09): **~53 ms** por tick (`dolt_server_pid` ~45 ms + `ps` ~3 ms), contra um
  tick inteiro de ~12–13 s dominado pelas sondas de latência que já existiam.

## Não dá pra consertar com `renice`

Baixar o nice exige root. Medido em 19/09 neste host, como o usuário do daemon:

```
renice 0 -p <pid>        → renice: <pid>: setpriority: Permission denied   (rc=1)
renice -n -15 -p <pid>   → renice: <pid>: setpriority: Permission denied   (rc=1)
renice 19 -p <pid>       → ok (subir o nice é permitido — o controle prova que o renice funciona)
```

A cura é **reiniciar o Dolt a partir de um pai nice 0**.

---

## Regra (doutrina)

1. **Não reinicie o Dolt de dentro de sessão pool/efêmera.** Escale para o Mayor com evidência
   (protocolo "Dolt trouble" do `CLAUDE.md`: coletar diagnóstico antes; nunca `kill -QUIT`).
2. **Depois de QUALQUER start/restart manual do Dolt, confira o nice:**

   ```bash
   source /Users/athos/gt/.gascity-gastown-hq/scripts/dolt-pid-lib.sh
   ps -o ni= -p "$(dolt_server_pid)"     # esperado: 0
   ```

   Saída vazia ou erro = **não consegui ler** (não é "0"). PID sempre do processo vivo.
3. **zsh:** um job em background (`cmd &`) roda em **nice +5** (opção `BG_NICE`, ligada por padrão —
   medido em 19/09: `sleep 25 &` → nice 5). Não rode `gc dolt start|restart` em background num zsh.

## Cura — quando o alarme disparar (Mayor/Athos, terminal nice 0)

1. **Confirme** o nice do PID vivo (comando da regra 2) e ache quem o subiu: siga a cadeia de pais
   (`ps -o pid=,ppid=,ni=,comm= -p <pid>`, depois `-p <ppid>`, …) até o primeiro ancestral com
   nice ≠ 0 — é a sessão embrulhada que fez o start à mão.
2. **Diagnóstico antes de reiniciar** (passos 1–2 do protocolo "Dolt trouble" do `CLAUDE.md`):
   `gc dolt sql -q "SHOW FULL PROCESSLIST"` e `gc dolt status`. Um restart às cegas destrói a evidência.
3. **Confira o SEU shell antes de agir:** `ps -o ni= -p $$` tem de dar `0`. Se não der, você
   reproduziria o problema — abra um terminal nice 0.
4. Reinicie **desse shell nice 0**: `gc dolt restart` (o Dolt nasce como filho de quem chamou).
5. **Verifique:** `ps -o ni= -p "$(dolt_server_pid)"` = 0. Em até ~2 ticks (2 min) o log traz
   `NICE alarm CLEARED` e chega o notify "Dolt voltou a nice 0".
6. Se o alarme **voltar** depois de um restart limpo, algo além de sessão pool está subindo o
   Dolt em nice ≠ 0: refaça o passo 1 antes de reiniciar de novo.

## Como fica no ar

- Job: `com.gascity.dolt-latency-alarm` (`/bin/bash`, `StartInterval` 60). Executa
  `scripts/dolt-latency-alarm.sh` **direto do checkout principal**: merge + deploy
  (`git pull --ff-only` do `origin/main`) = vivo no próximo tick. Não precisa recarregar plist.
  Conferir: `launchctl print gui/$(id -u)/com.gascity.dolt-latency-alarm`.
- Estado: `/tmp/dolt-latency-alarm.nice-active` (episódio) e `.nice-unknown` (streak de "não li").
  Log: `.gc/logs/dolt-latency-alarm.log`.
- Teste: `bash scripts/dolt-latency-alarm.selftest.sh` (~65 s; seção 5 = detector: `ps` real contra
  `getpriority(2)` do kernel, contrato de parse, classificação dos 3 estados e ticks completos).

## Relacionado

ga-rj7b1a (`claude-lowprio.sh`, o nice 15 das sessões pool) · ga-nnvym3 (sling) ·
`scripts/dolt-hang-watchdog.sh` (hang confirmado) · `scripts/dolt-latency-alarm.sh` (este detector)
