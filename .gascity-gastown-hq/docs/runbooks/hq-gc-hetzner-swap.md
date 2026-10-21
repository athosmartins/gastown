# hq do Dolt: GC --full no nó Hetzner + troca no mini (ga-2895yv.1.1)

## Contents
- Por quê
- Números medidos (ensaio ga-2895yv.1.1.1)
- Quem religa o Dolt e como travar sem desligar a cidade inteira
- Antes da janela
- Na janela 00:00–06:00 — passo a passo
- Voltar atrás
- Depois
- Revisão adversarial (21/10)

## Por quê

O hq ocupa ~14 GB (oldgen). O `DOLT_GC --full` não cabe na RAM do mini (abortou 02/10 e
20/10: swap e disco despencam em < 2 min), e o auto-GC online bate `no space left` no conjoin
do oldgen do hq várias vezes por dia (server.log 20/10: 17:43, 20:35, 21:39, 23:03).
Decisão do Athos (AskUserQuestion do Mayor, 20/10 ~21:5x): a limpeza grande roda no Hetzner.
Decisão do Athos (20/10 ~13:42Z): a cópia antiga fica 24 h no MacBook e é apagada na noite
seguinte.

## Números medidos (ensaio ga-2895yv.1.1.1)

- **SQL `CALL DOLT_GC('--full')` NÃO serve**: OOM (signal 9) em 89 s, RSS 31,1 GB = a RAM
  toda do nó. Nada mudou na cópia.
- **CLI, com o Dolt parado na cópia**: `dolt gc --full --archive-level=0
  --incremental-file-size=1073741824` (dolt 2.3.1 arm64, `~/hqgc/bin/dolt`) → rc 0 em 200 s,
  pico 8,3 GB, **15 G → 5,5 G**.
- Tabelas versionadas idênticas ao Dolt vivo (AS OF no mesmo commit): issues 31768,
  comments 38823, labels 107077, dependencies 2246.
- Tabelas em `dolt_ignore` (events, wisps, wisp_*, local_metadata, leases, repo_mtimes,
  bd_events_*, ignored_schema_migrations) vivem só no working set — AS OF não as vê. Contar
  antes/depois NA MESMA cópia congelada (passo 9).
- Rede mini↔nó: ~6,7 MB/s nos dois sentidos (200 MB em 30 s) → ida completa 14 GB ≈ 35 min;
  volta 5,5 GB ≈ 14 min. Por isso a semente (abaixo).
- Rede mini↔MacBook: TAMBÉM ~6,5 MB/s (200 MB em 31 s / 30 s, 21/10 03:0xZ) → hq antigo
  (14 GB) para o MacBook ≈ 36 min; voltar atrás pelo MacBook ≈ 36 min, não 5.
- Tempo com o Dolt parado (estimado): delta para o nó ~5 min ‖ cópia ao MacBook ~36 min →
  GC 4 min → volta 14 min (fsck ~40 min no nó em paralelo com a volta) → subir. **≈ 1h15–1h45.**
- Disco do mini: ~5,7 GB livres (caiu a 3,2 GB às 03:05Z com swap de 3 GB pós-boot). **A volta (5,5 GB) não cabe ao lado do hq antigo (14 GB)** —
  o antigo sai para o MacBook ANTES de o novo chegar.
- fsck da cópia GC: ver comentário de fechamento da ga-2895yv.1.1.1.

## Quem religa o Dolt e como travar sem desligar a cidade inteira

Todos os caminhos de partida conhecidos passam por um de dois `flock` em
`.gc/runtime/packs/dolt/`:

| Quem religa | Caminho | Trava |
|---|---|---|
| launchd `com.gastown.dolt-server` (KeepAlive.Crashed) | `gc dolt start` → `gc-beads-bd.sh start` | `flock -n dolt.lock`, 6×0,5 s; depois espera 45 s por um servidor pronto e morre (`gc-beads-bd.sh:1932-1947`, `wait_for_concurrent_start_ready`) |
| supervisor / `ensureManagedDoltPublishedForRuntime` | `gc-beads-bd.sh start` | idem |
| qualquer `bd`/`gc bd` (`recoverManagedBDCommandAllowed`, bd_env.go:757) | Go | `flock` não-bloqueante no `recover-managed-bd-trigger.stamp`; ocupado → não recupera |
| `gc dolt recover` / recuperação Go (dolt_recover_managed.go:45) | Go | `flock` não-bloqueante no `dolt.lock` |
| dolt-hang-watchdog, dolt-disk-floor-guard (`_resurrect_dolt`) | `gc dolt start` | `dolt.lock` |

O `dolt sql-server` NÃO segura o `dolt.lock` depois de subir (o starter solta ao sair,
gc-beads-bd.sh:2097), e o `op_stop` não pega lock. Logo: **segurar os dois locks ANTES de
parar o Dolt** impede qualquer religada até soltá-los, sem desligar os 402 jobs do launchd.
Quem tentar subir nesse meio-tempo falha em ~48 s (ruído de alarme, sem dano).

Holder (fica vivo a janela toda; soltar = matar o holder):

```bash
R=/Users/athos/gt/.gascity-gastown-hq/.gc/runtime/packs/dolt
nohup flock "$R/dolt.lock" flock "$R/recover-managed-bd-trigger.stamp" \
  sh -c 'echo $$ > /tmp/hqswap-holder.pid; while [ ! -e /tmp/hqswap-release ]; do sleep 2; done' \
  >/dev/null 2>&1 &
```

⚠️ `flock` aqui é o bloqueante (sem `-n`): se um starter estiver no meio, o holder espera ele
terminar. Conferir com `lsof "$R/dolt.lock"` que o holder segura antes de seguir.

O tráfego de `bd` com o Dolt parado só ERRA (não grava em lugar nenhum). Para reduzir o
ruído, a cidade fica suspensa (`gc suspend`) durante a troca.

## Antes da janela

1. **Semente no nó**: `rsync -a --bwlimit=6000 .beads/dolt/hq/ hetzner-teste:hqgc/seed/hq/`
   com o Dolt vivo (a cópia pode ficar inconsistente; só serve para o rsync final mandar
   pouco). A cópia GC do ensaio (`~/hqgc/hq`) NÃO serve de semente — o GC reescreveu todos
   os arquivos.
2. MacBook acordado, na tomada, ≥ 20 GB livres (`ssh athoss-macbook-pro.local df -h ~`).
   Medir a velocidade mini→MBP com 200 MB.
3. Backup S3 do hq de hoje com `failed=0`.
4. `compact-pending-gc/hq` NÃO pode existir (renomeado 21/10 para
   `hq.deferred-20261021-ga-2895yv-node-gc`): com ele, o `mol-dog-compactor` retenta o GC
   completo no mini.

## Na janela 00:00–06:00 — passo a passo

v3, depois da revisão adversarial (achados na ga-2895yv.1.1.2). Variáveis:
`C=/Users/athos/gt/.gascity-gastown-hq; D=$C/.beads/dolt; R=$C/.gc/runtime/packs/dolt;
X=$C/.hqswap` — **X fica FORA de `$D`** (o Dolt, o health, o compact, o sync e o
phantom-db carregam todo `*/.dolt` dentro de `$D`; uma cópia `hq.old`/`hq.new` ali vira um 2º
banco ou um "phantom" HIGH). Mesmo volume, então `mv` entre `$D` e `$X` é atômico.

Quem opera: os passos 4–13 rodam num **script destacado** (`$X/hqswap.sh`, numa sessão
`tmux new-session -d -s hqswap` que NÃO é sessão do gc), com log e checkpoints em
`$X/hqswap.log`. Motivo: o `gc suspend` pode parar a sessão do próprio Mayor, e um `nohup`
saído de uma chamada de ferramenta pode morrer com ela. O holder roda dentro do script.

**Regras da janela inteira:** `unset GC_DOLT_PORT` no shell do operador; **nenhum
`gc dolt sql`** do passo 5 ao 12 (com o Dolt parado ele abre `$D` direto, sem lock —
sql/run.sh:47-61); conferência só por `dolt --host 127.0.0.1 --port 52756 … sql`; antes de
cada cópia, `mv` ou remoção, `lsof +D $D/hq` (e `$X`) vazio de processos dolt.

### Preparação (antes de parar nada)

1. Pré-condições: `df -h /` ≥ 5 GB; nightly-reboot da noite já rodou (log); backup S3 do dia
   com `failed=0`; semente no nó com < 24 h; MacBook acordado, na tomada, ≥ 20 GB livres;
   nenhum envio do WA em voo.
2. Travar o que atrapalha (anotar tudo em `$X/restaurar.txt` para desfazer no passo 14):
   - `touch $C/.gc/logs/.dolt-compact-routine.HALT` — a rotina das 04:30 passaria a ter folga
     com o hq novo e faria flatten + `DOLT_GC --full` por SQL (o que estoura RAM). Fica até
     uma decisão sobre o flatten semanal (ga-2895yv).
   - `launchctl bootout gui/501/com.gascity.dolt-hang-watchdog`, `…/dolt-disk-floor-guard`,
     `…/dolt-latency-alarm` — o hang-watchdog faz `gc dolt restart` (o stop dele não pega
     lock: mataria o servidor recém-subido) e os dois mandam "town-halted" pro celular.
   - `rm -f /tmp/hqswap-release`.
3. `gc suspend`. Esperar as sessões de agente pararem (`gc session list`).

### Congelar

4. Holder (seção acima) dentro do script; `lsof $R/dolt.lock $R/recover-managed-bd-trigger.stamp`
   mostra o holder nos dois. Repetir esse `lsof` antes dos passos 5, 7, 10, 11 e 12.
5. `df` > 2 GB e nenhum GC em andamento (`dolt.log`); parar:
   `GC_CITY_PATH=$C $C/.gc/system/packs/bd/assets/scripts/gc-beads-bd.sh stop`. Conferir fim
   limpo no `dolt.log` e que `$D/.dolt/sql-server.info` sumiu. Nunca sinal à mão.
6. `launchctl disable gui/501/com.gastown.dolt-server` e `…/com.gascity.supervisor`
   (sobrevive a reboot: se o mini reiniciar no meio, nada sobe sozinho nem faz
   `CREATE DATABASE IF NOT EXISTS hq` vazio, beads_provider_lifecycle.go:200-211 →
   gc-beads-bd.sh:332). Vigia de processos dolt na janela toda.

### Copiar e limpar no nó (nada muda no mini ainda)

7. Em paralelo, com o hq parado:
   - nó: `rsync -a --delete --checksum $D/hq/ hetzner-teste:hqgc/seed/hq/`;
   - MacBook: `rsync -a $D/hq/ athoss-macbook-pro.local:hqswap/hq.old/` (~36 min).
8. **Linha de base = a cópia congelada no nó, ANTES do GC**: HEAD + contagens das tabelas
   versionadas e das ignoradas (`~/hqgc/bin/dolt sql`, uma tabela por consulta). Isso é o
   "antes" — não o Dolt vivo (gravações entre suspender e parar mudam HEAD sem dano).
9. No nó: `dolt gc --full --archive-level=0 --incremental-file-size=1073741824`; contagens
   == passo 8; HEAD == passo 8; `du -sh`; **`dolt fsck` e ESPERAR terminar limpo** (~40 min).
   fsck sujo → voltar atrás pelo caminho A.
10. MacBook conferido: `rsync -a --checksum --dry-run --itemize-changes $D/hq/
    athoss-macbook-pro.local:hqswap/hq.old/` com rc 0 e saída VAZIA, mais nº de arquivos e
    total de bytes iguais (`find … -type f | wc -l`, `du -sk`) dos dois lados.

### Trocar (a partir daqui é irreversível no mini)

11. Com fsck limpo e o passo 10 ok:
    - `mv $D/hq $X/hq.old` (atômico; nada fica em `$D`);
    - se `df` ≥ 9 GB: trazer o novo primeiro (`rsync -a hetzner-teste:hqgc/seed/hq/
      $X/hq.new/`) e só depois apagar o antigo; senão apagar o antigo primeiro:
      `rm -rf $X/hq.old` — ⚠️ é apagar um `.dolt` (regra da cidade); autorizado pelo Mayor
      porque há cópia bit a bit no MacBook (passo 10) e o original sai de serviço no `mv`;
    - `rsync -a hetzner-teste:hqgc/seed/hq/ $X/hq.new/` + `--checksum --dry-run` vazio;
    - `[ ! -e $D/hq ] && mv -n $X/hq.new $D/hq && test -f $D/hq/.dolt/noms/manifest`
      (sem a guarda, `mv` para um `$D/hq` existente aninha a pasta em silêncio).
12. `launchctl enable` dos dois do passo 6; soltar o holder (`touch /tmp/hqswap-release`);
    `gc dolt start`; `dolt --host 127.0.0.1 --port 52756 … sql`: HEAD == passo 8, tabelas
    versionadas `AS OF '<HEAD do passo 8>'` == passo 8, ignoradas == passo 8 (antes do
    resume); `du -sh $D/hq`; `gc dolt health`.
13. `gc resume`. Conferir `gc session list`, gate e painel respondendo.
14. Desfazer o passo 2 pela `restaurar.txt` (`launchctl bootstrap` dos 3 vigias), MENOS o
    HALT da rotina de compactação.

## Voltar atrás

- **A — até o passo 10** (nada mudou no mini): `launchctl enable` dos do passo 6, soltar o
  holder, `gc dolt start`, `gc resume`, desfazer o passo 2.
- **B — depois do passo 11, hq novo com problema**: holder + stop + disable de novo;
  `mv $D/hq $X/hq.bad` (fora de `$D`) e apagar `$X/hq.bad` (o nó ainda tem a cópia);
  conferir `df` ≥ 16 GB; `rsync -a athoss-macbook-pro.local:hqswap/hq.old/ $X/hq.restore/`
  (~36 min) + `--checksum --dry-run` vazio; `[ ! -e $D/hq ] && mv -n $X/hq.restore $D/hq`;
  subir como no passo 12. Nunca rsync por cima de um `$D/hq` existente.

## Depois

- Apagar `~/hqgc` do nó (o nó não guarda dado da cidade).
- Apagar `hqswap/hq.old` do MacBook 24 h depois (decisão do Athos).
- Apagar `$X` (`$C/.hqswap`) e o HALT só depois de decidir o flatten semanal.
- `dolt_gc` online volta a caber (ga-boftko).

## Revisão adversarial (21/10)

Veredito: "seguro com mudanças". Os 3 bloqueadores (volta atrás sem espaço e sobrescrevendo,
`hq.old/new` dentro de `$D`, rotina de compactação das 04:30) e os maiores (fsck antes do
irreversível, `gc dolt sql` sem lock, reboot no meio, vigias que reiniciam/mandam alerta,
linha de base congelada, operador suspenso) estão incorporados acima. Lista completa com
arquivo:linha no comentário da ga-2895yv.1.1.2.
