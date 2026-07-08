# Runbook — ga-z6uo: order executor store-close race (engine-window)

**Objetivo:** parar os supervisor ORDER executors (order-tracking-sweep,
gate-sweep, orphan-sweep, dolt-health, dolt-remotes-patrol,
cascade-nudge-on-blocker-close, beads-health, e qualquer outra order) de
disparar `native Dolt store: bead store closed` ao tentar fechar sua própria
tracking bead — crônico desde 2026-06-07, escalado a P1 em 2026-07-08 por
coincidir com um pico de Dolt-hotness e contribuir para o bounce de TODAS as
10 runtimes de worker da town.

**Status do fix:** ⚠️ **Código pronto e testado, NÃO deployado.** Este
runbook tem 2 partes: **BUILD** (já feito, este commit) e **DEPLOY** (a
janela de manutenção). Mirrors o padrão BUILD/DEPLOY dos runbooks
`ga-ftmci`/`ga-u0vzx` para fixes de engine.

---

## Causa-raiz (confirmada por leitura direta do código)

Repo fonte vivo: `/Users/athos/gt/.local-patches/_src-hookfix`
(`github.com/gastownhall/gascity`) — é de onde o binário `gc` rodando agora
(`/opt/homebrew/bin/gc` → `gc-patched-u0vzx`) foi buildado (confirmado via
`go version -m` batendo pseudo-versão/hash com o HEAD do checkout).

**Dois codepaths diferentes para obter um `beads.Store`:**

1. **Main reconcile loop** (`cr.beadReconcileTick`, `cmd/gc/city_runtime.go:1940`)
   usa `cr.cityBeadStore()` → um handle ÚNICO, de vida longa, cacheado em
   `controllerState.cityBeadStore` (`cmd/gc/api_state.go:135`, envolto por
   `*beads.CachingStore`). Só é trocado por inteiro num reload de
   config/store; todo consumidor busca ele FRESCO a cada chamada via
   accessor, então nunca fica "stale" do ponto de vista do chamador.

2. **Order executors** (`memoryOrderDispatcher.dispatch`,
   `cmd/gc/order_dispatch.go:397`) abrem um store NOVO **a cada tick**
   (`m.storeFn` → `openStoreAtForCity`, `cmd/gc/main.go:1203`), guardado num
   `stores := make(map[string]beads.Store)` local ao tick. Pra ordens que
   disparam, esse store é passado para uma goroutine `dispatchOne` DETACHED
   (`launchDispatchOne`, linha 627) enquanto o loop síncrono do tick
   continua. O `defer` original fechava TODOS os stores abertos naquele
   tick assim que o loop síncrono retornava — **sem esperar as goroutines
   `dispatchOne` que ele mesmo lançou terminarem de usar esses stores.**

**A race, exatamente:** `dispatchOne` (linha 949) faz seu trabalho e, no
fim, fecha a tracking bead via `closeOrderTrackingBead` → `store.CloseAll`
(linha 1002). Se o tick's próprio `defer closeStores()` já rodou antes
disso (porque o loop síncrono do tick retornou primeiro), o `store.CloseAll`
da goroutine bate num `*NativeDoltStore` já fechado:

```go
// internal/beads/native_dolt_store.go:184-192 (acquireStorage)
if s.storage == nil {
    return nil, nil, fmt.Errorf("native Dolt store: %w", ErrStoreClosed)
    // ErrStoreClosed = errors.New("bead store closed")  (internal/beads/beads.go:20)
}
```

**Por que crônico desde 06-07 mas só virou P1 em 07-08:** o impacto
steady-state é cosmético — a ORDER roda normalmente, só a escrita de
lifecycle da tracking bead falha, e o `order tracking sweep watchdog`
fecha essas tracking beads órfãs depois. A race em si é uma janela de
poucos ms (tick's defer vs. goroutine's própria escrita). Sob
Dolt-hotness (queries mais lentas → goroutines `dispatchOne` vivem mais)
essa janela alarga, aumentando a taxa de falha — e em 07-08 10:30 isso
coincidiu com um spike de storage-degraded que fez sessões perderem seu
runtime lease, bouncing as 10 runtimes de worker (recuperado ~10:38 via
create-budget throttle + spawn-storm-detect).

**NÃO é sobre "reconectar após reconnect/degradação do Dolt"** no sentido
de um handle compartilhado de longa duração ficando stale — order
executors nunca compartilham um handle de longa duração pra começo de
conversa (abrem um novo por tick). É puramente uma race de lifetime
síncrono-vs-assíncrono dentro do MESMO tick.

---

## PARTE A — BUILD (✅ já feito)

**Fix:** `dispatch()` agora rastreia as goroutines `dispatchOne` que lançou
neste tick com um `sync.WaitGroup` (`storesWG`), e adia o close dos stores
deste tick pra uma goroutine de background que espera esse WaitGroup
primeiro. Ticks que não lançam nenhuma goroutine mantêm o close síncrono
original (sem overhead extra no caso comum).

- Branch: `fix/ga-z6uo-order-dispatch-store-close-race`
  (`athosmartins/gascity`)
- Commit: `3285feaae1cce0ea04103481d477a6ebd16dbbf3`
- Arquivos: `cmd/gc/order_dispatch.go` (+41/-8),
  `cmd/gc/order_dispatch_test.go` (+100 incl. novo teste de regressão
  `TestOrderDispatchDoesNotCloseStoreWhileAsyncDispatchInFlight`, que
  reproduz a race com um exec bloqueante e prova que o store não fecha
  enquanto a goroutine ainda está usando ele)
- Também corrigidos 3 testes pré-existentes
  (`TestDispatchClosesEveryOpenedStoreHandle`,
  `TestDispatchClosesRigAndLegacyCityStoreHandles`,
  `TestDispatchDeduplicatesStoreHandlesAcrossOrders`) cujo
  `time.Sleep(50ms) // let dispatchOne goroutines finish` rodava DEPOIS do
  assert em vez de antes — inofensivo enquanto o close era síncrono, virou
  falha real com o close agora deferido a uma goroutine.

**Testado:**
```
cd /Users/athos/gt/.local-patches/_src-hookfix
ICU=$(brew --prefix icu4c@78)
export CGO_CPPFLAGS="-I$ICU/include" CGO_LDFLAGS="-L$ICU/lib"
go build ./cmd/gc/...                                    # limpo
go test ./cmd/gc/... -count=1                             # PASS, 575s, 0 failures
go test ./cmd/gc/... -race -run 'TestOrderDispatch|TestOrderDispatcher' -v   # PASS, sem races
```

**Proveniência:** o WaitGroup fix + teste de regressão foram escritos por
uma encarnação anterior da sessão `gastown.dog-2` (dog-ga5e06, dispatch
`ga-vw39`) que morreu antes de commitar (ver comment trail em `ga-vw39` /
`ga-5vdk` / `ga-e869` — 3 dispatches duplicados subsequentes corretamente
detectaram o trabalho em andamento e recuaram, um deles filed `ga-qfo3`
pro false-reclaim que causou parte da confusão). Esta sessão (dispatch
`ga-wtp9`) herdou o WIP, verificou que compilava, achou e corrigiu as 3
regressões de teste acima, rodou a suite completa + race detector, e fez
o commit/push.

---

## PARTE B — DEPLOY (janela de manutenção — NÃO fazer casualmente)

⚠️ **A própria ga-z6uo avisa: NÃO "consertar" isso kickstartando o
supervisor reflexivamente** — isso só limpa o sintoma temporariamente e
arrisca um re-read storm → mais bounces enquanto o Dolt está quente. O
deploy abaixo só deve rodar numa janela deliberada, não como reação
automática a este runbook.

```bash
# 1. Build o binário novo a partir do branch acima
cd /Users/athos/gt/.local-patches/_src-hookfix
git fetch origin && git checkout fix/ga-z6uo-order-dispatch-store-close-race
git pull --ff-only
ICU=$(brew --prefix icu4c@78)
export CGO_CPPFLAGS="-I$ICU/include" CGO_LDFLAGS="-L$ICU/lib"
go build -o /tmp/gc-z6uo ./cmd/gc

# 2. Smoke-test local antes de instalar
GC_CITY=/Users/athos/gt/.gascity-gastown-hq /tmp/gc-z6uo session list --json >/dev/null && echo OK

# 3. Backup do binário atual (reversível)
cp -L /opt/homebrew/bin/gc /tmp/gc-backup-$(date +%Y%m%d_%H%M%S)

# 4. Instalar ao lado
cp /tmp/gc-z6uo /opt/homebrew/bin/gc-patched-z6uo

# 5. Repontar o symlink
ln -sf /opt/homebrew/bin/gc-patched-z6uo /opt/homebrew/bin/gc

# 6. Reiniciar o supervisor
launchctl kickstart -k "gui/$(id -u)/com.gascity.supervisor"

# 7. VERIFICAR (teste de aceite — ver seção abaixo)
```

**Rollback:**
```bash
ln -sf /opt/homebrew/bin/gc-patched-u0vzx /opt/homebrew/bin/gc
launchctl kickstart -k "gui/$(id -u)/com.gascity.supervisor"
```
(`gc-patched-u0vzx` é o binário-bom atual no momento em que este runbook foi
escrito — confirmar com `readlink /opt/homebrew/bin/gc` antes de assumir,
pode ter mudado se outro engine fix foi deployado nesse meio tempo.)

---

## Estrela-guia (aceite)

Depois do deploy, por pelo menos 1h de operação normal:

```bash
grep -c "native Dolt store: bead store closed" ~/.gc/supervisor.log
# comparar contagem ANTES do timestamp do restart vs DEPOIS — deve parar de
# crescer (0 novas ocorrências pós-deploy)
```

- `order tracking sweep watchdog` não deveria mais encontrar tracking beads
  órfãs deixadas por essa race especificamente (outras causas de órfã ainda
  são válidas — não é o único motivo desse watchdog existir).
- Nenhuma sessão perde runtime lease por causa desta race durante o próximo
  pico de Dolt-hotness (correlacionar com `gc dolt health` / CPU do Dolt).

Complementa `ga-qfo3` (false-reclaim durante long-running dog dispatch,
já mergeado) — ambos contribuíram pro mesmo incidente de 07-08 10:30-10:38.
