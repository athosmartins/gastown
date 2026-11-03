# Backup do beads (exporter + upload ao S3) rodando do launchd — cutover (ga-ki02nmt)

## Contents

• Ordem do cutover (não inverter) · Critério de pronto (ga-ki02nmt) — medir, não afirmar
• Reverter (ordem inversa, também não inverter) · O que pode acender (e é esperado ou não)
• Pendências conhecidas (não são deste cutover)

**Por quê.** O despachante de orders do engine atende ~1,16 run/min contra ~14,7 pedidos/min (cada order roda a cada ~35 min, não importa o `interval`; teto de 4 orders por tick). O RPO do backup não pode depender disso. Medido em 03/11 (ga-ki02nmt):
- `jsonl-archive` (commits do exporter, horário local -03): 08:23 → 10:24 → 12:38, ou seja **um commit a cada ~2 h** com o order de 15 min;
- `latest.json` no S3: `data_as_of` 2 h 45 min atrás, `checked_at` 40 min atrás (o upload anda, o dado não);
- log do upload desde 01/11, mediana do gap entre publicações **47 min, 35 % dos gaps acima de 60 min** (meta: `latest.json` < 4500 s).

**O que muda.** Dois jobs do launchd, **mesmos scripts, mesmos timeouts, mesma cadência** dos orders:

| label | script | a cada | timeout | lock do script |
|---|---|---|---|---|
| `com.gascity.jsonl-export` | `packs/town-deltas/assets/scripts/jsonl-export.sh` | 15 min | 840 s (`timeout -k 20`) | **não tem** |
| `com.gascity.jsonl-hourly-offsite` | `packs/town-deltas/assets/scripts/jsonl-hourly-offsite.sh` | 30 min | 2400 s (`timeout -k 20`) | tem (`jsonl-hourly-offsite.lock.d`; o 2º run loga `outro run em andamento; saindo`, não sobe nada e sai 0) |

Os dois orders (`orders/jsonl-export.toml`, `orders/jsonl-hourly-offsite.toml`) **ficam no repo** como fonte do timeout/intervalo que o plist copia (`scripts/jsonl-launchd-plists.selftest.sh` exige igualdade) e entram em `city.toml` `[orders] skip` — o mesmo deploy. O order `jsonl-hourly-offsite-age` (alarme de idade do `latest.json`, tem gêmeo launchd próprio) **não** é tocado.
Os dois plists estão em `daemon-presence-watchdog.sh` (`DPW_CRITICAL` + `DPW_HEARTBEAT`): exporter 2700 s no **log do próprio script**, `.gc/logs/jsonl-export.log` (uma rodada limpa sem mudança não escreve no `.out`, então um `.out` como heartbeat daria WEDGE num job saudável); upload 5400 s no `.out` (o script loga no stderr, que o plist junta ao `.out`).

## Ordem do cutover (não inverter)

O exporter **não tem lock**: dois exporters ao mesmo tempo escrevem o mesmo archive. Por isso o order sai **antes** do plist entrar. A janela entre os passos 1 e 4 (poucos minutos) fica sem export; o próximo run recupera tudo (o export é idempotente, lê o estado atual do Dolt).

1. **Merge** (o `city.toml` com o `skip` novo entra no checkout vivo) e recarregar a config: `gc --city "$GC_CITY" reload`.
   O `daemon-presence-watchdog` **não avisa** nesta janela (até o passo 4): os dois labels estão em `DPW_CRITICAL`, o PRESENCE-DRIFT pula quem está lá e, sem o plist em `~/Library/LaunchAgents`, o laço principal só grava `WARN critical daemon ... has no plist on disk` no log dele (sem ntfy nem mail). Esquecer o passo 4 só aparece nos alarmes de idade (`latest.json` > 75 min no S3, tabela > 120 min): faça os passos 2 a 4 em seguida. Não silenciar o watchdog.
2. **Confirmar que os orders saíram:**
   ```bash
   gc --city "$GC_CITY" order list --json | jq -r '.orders[].name' | grep -E '^jsonl-(export|hourly-offsite)$' && echo AINDA-LISTADO || echo ok-fora
   ```
   `AINDA-LISTADO` depois de um `gc reload` = o skip não pegou: **parar aqui** (instalar o plist agora dá dois exporters) e avisar o Mayor. Lista que não abre não é "ok-fora": repetir.
3. **Confirmar que nada está em voo:**
   ```bash
   pgrep -fl 'jsonl-export\.sh' || echo sem-export
   ls "$GC_CITY/.gc/runtime/packs/town-deltas/jsonl-hourly-offsite.lock.d" 2>/dev/null && cat "$GC_CITY/.gc/runtime/packs/town-deltas/jsonl-hourly-offsite.lock.d/pid" || echo sem-lock-do-upload
   ```
   Export em voo (até 14 min): esperar terminar. Lock do upload de pid vivo: esperar (ou deixar; o lock do script cobre este lado).
4. **Instalar e carregar** (cópia simples, sem `-p`: o `story-ga-c0939v.7` usa o mtime do plist instalado como marcador do cutover):
   ```bash
   for l in com.gascity.jsonl-export com.gascity.jsonl-hourly-offsite; do
     cp "$GC_CITY/scripts/$l.plist" ~/Library/LaunchAgents/$l.plist
     launchctl enable "gui/$(id -u)/$l"   # inofensivo na 1ª vez; depois de um Reverter o label está disabled e o bootstrap falharia
     launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/$l.plist
   done
   ```
   `RunAtLoad` roda um ciclo agora. Um `bootstrap` que diz `Input/output error` com o label já carregado = já estava instalado: `launchctl bootout gui/$(id -u)/<label>` e repetir.
5. **Conferir** (não é para acreditar neste texto):
   ```bash
   for l in com.gascity.jsonl-export com.gascity.jsonl-hourly-offsite; do launchctl print "gui/$(id -u)/$l" | grep -E 'state =|runs =|last exit'; done
   tail -3 "$GC_CITY/.gc/logs/jsonl-export.log" "$GC_CITY/.gc/logs/jsonl-export-launchd.out" "$GC_CITY/.gc/logs/jsonl-hourly-offsite-launchd.out"
   git -C "$GC_CITY/.gc/runtime/packs/maintenance/jsonl-archive" log -5 --format='%h %cI %s'
   bash "$GC_CITY/packs/town-deltas/assets/scripts/jsonl-hourly-offsite.sh" --status
   bash "$GC_CITY/packs/town-deltas/assets/prod-tests/gascity/story-ga-7sxdmb.sh"
   ```
   O `story-ga-7sxdmb.sh` agora exige: 0 orders rodando `jsonl-export.sh`, os dois nomes fora do `gc order list`, os dois labels carregados apontando para o script deste city, e os dois nomes no `skip`. `story-ga-c0939v.2.sh` e `.7.sh` exigem plist instalado idêntico ao do repo.

## Critério de pronto (ga-ki02nmt) — medir, não afirmar

Por 24 h, com carga alta incluída:
- `git -C "$GC_CITY/.gc/runtime/packs/maintenance/jsonl-archive" log --since='24 hours ago' --format='%cI'` com commits a cada ~15 min;
- `jsonl-hourly-offsite.sh --status` com `latest.json` < 4500 s o tempo todo (o alarme de idade, `--age-check`, já mede isso a cada 10 min).

### Limite que o launchd não resolve: a política de disco do exporter (ga-j2f5v5)

Com **menos de 5 GiB livres** o `jsonl-export.sh` se espaça sozinho para **no máximo 1 export por hora** (`skipped-low-disk (cadência estendida)` em `.gc/logs/jsonl-export.log`); na classe CRÍTICA do Dolt (< 4096 MB livres) só com o último export > 3 h. Medido em 03/11: 4942 MB livres, ou seja, abaixo da linha. **Enquanto o disco ficar abaixo de 5 GiB, o launchd tica a cada 15 min mas o exporter pula 3 de cada 4 ticks, e o critério "commit a cada ~15 min" não é atingível por este cutover.** O que destrava é espaço em disco (rodada de limpeza do Mayor), não mudar a política: ela existe porque cada run pesa ~700 MB e um ENOSPC no journal do Dolt já aconteceu (15/10, 17/10). Medir o critério só com o disco ≥ 5 GiB livres.

## Reverter (ordem inversa, também não inverter)

Só o `bootout` **não segura**: os dois labels estão em `DPW_CRITICAL`, e a cada sweep (~5 min) o watchdog religa (`launchctl bootstrap`, com alerta ABSENT) todo label crítico descarregado cujo plist ainda está em `~/Library/LaunchAgents`; o `RunAtLoad` dispara um export na hora e, com o `skip` fora, são dois exporters. Só o `launchctl disable` é respeitado (`SKIP ... launchctl-disabled`: nem religa nem alerta; `_deliberately_disabled`, ga-4zyex; cenário 2b do `daemon-presence-watchdog.sh --selftest`). Então `disable` **antes** do `bootout`:

```bash
for l in com.gascity.jsonl-export com.gascity.jsonl-hourly-offsite; do
  launchctl disable "gui/$(id -u)/$l"   # persiste (reboot incluído): é o que segura o watchdog
  launchctl bootout "gui/$(id -u)/$l"
done
pgrep -fl 'jsonl-export\.sh' || echo sem-export   # esperar o run em voo terminar
```
**Só depois** tirar `"jsonl-export"` e `"jsonl-hourly-offsite"` de `city.toml` `[orders] skip` (e `gc reload`). Tirar o `skip` com o plist ainda carregado, ou com o label só descarregado, sem `disable` (o watchdog o religa), = dois exporters. Remover os arquivos de `~/Library/LaunchAgents` e os plists de `scripts/` junto; o `daemon-presence-watchdog` deixa de listar os labels ao tirá-los de `DPW_CRITICAL`/`DPW_HEARTBEAT` (com o label `disabled`, o PRESENCE-DRIFT de um plist que sobrar em `scripts/` fica calado: `SKIP`, ga-d0s6dc). O `disable` continua gravado no launchd depois disso: um novo cutover passa pelo `launchctl enable` do passo 4.

## O que pode acender (e é esperado ou não)

| sinal | o que é |
|---|---|
| silêncio entre o `reload` e o passo 4 | sem export e **sem alerta do watchdog** (passo 1: só um `WARN` no log dele); quem acende é o alarme de idade, quando o `latest.json` passar de 75 min (S3) ou a tabela de 120 min |
| ABSENT/auto-bootstrap do watchdog num label | o label saiu do launchd **sem** estar `disabled` e o plist está em `~/Library/LaunchAgents`: o watchdog recarrega sozinho (alerta + `RunAtLoad`); se repete, ver `launchctl print`. Depois de um Reverter é o erro a evitar (faltou o `disable`: o job volta e, sem o `skip`, são dois exporters) |
| `SKIP <label>: launchctl-disabled (parada deliberada)` no log do watchdog | esperado depois de um Reverter: é o `disable` segurando, sem religar e sem alerta. Para voltar a rodar: passo 4 (`enable` + `bootstrap`) |
| heartbeat velho (2700 s exporter, 5400 s upload) → `kickstart -k` | exporter: o `jsonl-export.log` não ganhou `start`/`end`/`skipped-low-disk` em 45 min (o launchd não disparou, ou a rodada nem abriu). Upload: o `.out` sem linha por 90 min. Arquivo do heartbeat **ausente** = sem veredito (`_log_age` vazio), nunca WEDGE: quem cobre é o alarme de idade |
| `.out` do exporter vazio ou parado, com o `jsonl-export.log` andando | normal: rodada limpa sem mudança não imprime nada no stdout. Não é defeito |
| `failed: ...` no resumo do exporter (`.out`, DOG_DONE) com rc 0 | um banco falhou e o run seguiu: NÃO conta como CRASH-LOOP (igual ao order). Ler o resumo e o `jsonl-export.log` |
| CRASH-LOOP no upload | 2 runs seguidos com rc != 0 (rc 1 = falha de upload, rc 2 = não deu para avaliar): o script já manda o próprio alerta; é falha real, não do launchd |
| `skipped-low-disk` no `.out` e no `jsonl-export.log` do exporter | política de disco acima, não defeito |

## Pendências conhecidas (não são deste cutover)

- **Lock do exporter:** só o upload tem single-flight. Segurança de hoje = launchd não sobe 2ª instância do mesmo label + `skip` no mesmo deploy + a ordem acima. Um lock dentro do `jsonl-export.sh` é a defesa de verdade (follow-up).
- `engine patch max_dispatches_per_tick=8`, o plist do `jsonl-table-age` e a mudança da ordem de leitura do exporter são de outros beads.
- Medição dos 5 orders de 30 s (gate-sweep × 4 rigs, dolt-health): no comentário do bead ga-ki02nmt (proposta: gate-sweep 30 s → 300 s, dolt-health 30 s → 120 s).
