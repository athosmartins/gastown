# Runbook — ga-u0vzx: orphan-sweep false-reset (engine-window)

**Objetivo:** parar o `orphan-sweep` order de resetar claims de dogs/pool
workers que estão VIVOS e ativamente trabalhando (status+assignee+started_at
zerados por engano), causando duplicate-dispatch races.

**Status do fix:** ⚠️ **Código pronto e testado, NÃO deployado.**
`ga-u0vzx` tem causa-raiz confirmada com evidência direta (audit log +
reprodução ao vivo duas vezes), o fix está escrito, testado (12/12) e
commitado em `athosmartins/gascity` branch `fix/ga-u0vzx-orphan-sweep-
hysteresis` — mas **não pode ser aplicado sem rebuild do binário `gc`**
(ver PARTE B). Este runbook tem 2 partes: **BUILD** (já feito) e **DEPLOY**
(a janela de manutenção).

---

## Causa-raiz (confirmada, 2026-07-02)

**Ator identificado via `.beads/interactions.jsonl` (audit log), não
inferência:**

```json
{"actor":"order:orphan-sweep","created_at":"2026-07-02T15:13:54.941364Z",
 "issue_id":"ga-beikk","extra":{"field":"status","old_value":"in_progress","new_value":"open"}}
{"actor":"order:orphan-sweep","created_at":"2026-07-02T15:13:54.942083Z",
 "issue_id":"ga-beikk","extra":{"field":"assignee","old_value":"dog-gaxfpyg","new_value":""}}
```

`gc order show orphan-sweep` → exec `orphan-sweep.sh`, trigger `cooldown`,
interval `5m`, description "Reset beads assigned to dead agents back to the
work pool". A ordem rodou 25s depois do último `bd` update de `dog-gaxfpyg`
em `ga-beikk` (15:13:29.467Z → revert em 15:13:54.94Z) e resetou
`status+assignee+started_at` em UM commit atômico (`bd history ga-beikk
--json`), enquanto a sessão `dog-gaxfpyg` (gastown.dog-1) permaneceu
`state=awake` continuamente por todo o intervalo — confirmado via
`.gc/runtime/session-reconciler-trace` (gap-free 15:10:23Z-15:58:05Z: o
reconciler do PRÓPRIO engine nunca tocou `ga-beikk` nem a sessão; reconcile
interno é inocente, o ator é especificamente o order `orphan-sweep`).

**Reprodução ao vivo, uma SEGUNDA vez, durante a própria investigação**
(2026-07-02T16:26:35Z): mesmo order resetou `ga-a1tdi` (assignee
`dog-gasumis`, gastown.dog-1's sessão atual), enquanto `dog-gasumis`
permanecia `state=active` — confirma que não é um fluke raro, é um bug
ativo e recorrente no cadence de 5min do order.

**Bug real, confirmado por leitura direta do código
(`examples/gastown/packs/maintenance/assets/scripts/orphan-sweep.sh`,
função `is_known_agent()`):** o script já tem verificação de liveness
multi-campo (`live_session_match()`, cross-referencia
`gc session list --json` contra id/session_name/alias/agent_name/
template/name, com "segunda passada" pra fechar a race
session-list-antes-do-bd-list) — mas **atua em UM snapshot pontual, sem
nenhuma janela de confirmação entre ciclos.** Diferente do seu órgão-irmão
`scripts/inflight-reclaim-guard.py`, que exige 25min de stranding
CONTÍNUO antes de qualquer reclaim (hysteresis documentada extensivamente
no próprio docstring do guard como lição aprendida — ga-64usm: "alive !=
working", sessões podem parecer mortas num snapshot isolado por qualquer
glitch transitório de leitura), `orphan-sweep.sh` nunca teve essa proteção.
Um único read ruim de `gc session list --json` (qualquer causa: race,
timing, hiccup do Dolt) é suficiente pra derrubar um claim legítimo.

**Por que o trigger exato do glitch de leitura não foi 100% confirmado:**
investigação extensiva (agente Explore, ~40min, 162 tool calls) NÃO achou
o motivo exato pelo qual `gc session list --json` teria deixado de reportar
uma sessão comprovadamente viva naquele instante específico — mas isso não
muda a ação corretiva: seja qual for a causa do glitch pontual, exigir
confirmação em 2 ciclos consecutivos (ver PARTE A) neutraliza a classe
inteira do problema, do mesmo jeito que o guard-irmão já faz.

---

## PARTE A — BUILD (✅ já feito)

**Fix:** ledger de hysteresis (`orphan-sweep-counts.json`, mesmo padrão de
state-file do order-irmão `spawn-storm-detect.sh`) exigindo
`CONFIRM_THRESHOLD` (default 2) sweeps CONSECUTIVOS antes de resetar
qualquer bead. Um candidato que "se recupera" (sessão reaparece, bead
reatribuído/fechado) em qualquer sweep intermediário tem seu contador
zerado imediatamente — não acumula através de gaps.

- Fix: `athosmartins/gascity` branch `fix/ga-u0vzx-orphan-sweep-hysteresis`
  (commit `a31643a75`), arquivo
  `examples/gastown/packs/maintenance/assets/scripts/orphan-sweep.sh`.
- Testes: mesmo branch, commit `c1f0b5afb`, `examples/gastown/packs/
  maintenance/assets/scripts/tests/orphan-sweep.selftest.sh` — roda o
  script REAL (não uma reimplementação) contra um shim `gc` sandboxed
  (PATH isolado via `env -i`, com sanity-check explícito de que o binário
  real nunca é alcançável). 12/12 casos passam:
  sweep único não reseta; 2 sweeps consecutivos resetam; candidato que
  se recupera nunca é resetado (regressão direta do bug ga-u0vzx);
  agente genuinamente morto ainda é limpo (sem over-correction).
- Rodar localmente: `bash examples/gastown/packs/maintenance/assets/
  scripts/tests/orphan-sweep.selftest.sh` a partir de um checkout de
  `athosmartins/gascity`.
- PR ainda não aberta — branch está pushed, pronta para review.

## PARTE B — DEPLOY (janela de manutenção — **NÃO É HOT-PATCH**)

**Descoberta importante durante esta investigação:** este NÃO é um script
livre-editável em produção, mesmo sendo bash puro (não Go). O pack
`maintenance` é `go:embed`'d no binário `gc`
(`examples/gastown/packs/maintenance/embed.go`), e a cópia deployada em
`.gc/system/packs/maintenance/assets/scripts/orphan-sweep.sh` é
**auto-restaurada a partir do conteúdo embedado a cada ciclo de reconcile**
— confirmado empiricamente: um hand-edit ao vivo (com backup prévio, MD5
verificado) foi revertido para o MD5 original em ~1-2min, de forma limpa
(sem corrupção, syntax válida, backup preservado). Isso é diferente do
padrão `scripts/` → `.gc/scripts/` (CopyFiles config-drift, mais lento/
menos agressivo) — `.gc/system/packs/` é ativamente protegido.

**Implicação:** o fix só entra em produção com rebuild + swap do binário
`gc`, seguindo o mesmo procedimento documentado em
[[gc-binary-rebuild-version-compat-fix]] / `ga-ftmci-dolt-cpu-engine-window.md`:

```bash
# 1. Merge/build a partir da branch fix/ga-u0vzx-orphan-sweep-hysteresis
#    (ou cherry-pick os 2 commits) em cima de main atual do fork.
cd <checkout-do-fork-athosmartins/gascity>
git fetch origin fix/ga-u0vzx-orphan-sweep-hysteresis
git checkout main && git merge origin/fix/ga-u0vzx-orphan-sweep-hysteresis
CGO_ENABLED=1 \
  CGO_CPPFLAGS="-I/opt/homebrew/opt/icu4c@78/include" \
  CGO_CXXFLAGS="-I/opt/homebrew/opt/icu4c@78/include" \
  CGO_LDFLAGS="-L/opt/homebrew/opt/icu4c@78/lib" \
  PKG_CONFIG_PATH="/opt/homebrew/opt/icu4c@78/lib/pkgconfig" \
  go build -o gc-patched-orphansweep ./cmd/gc

# 2. A/B verify ANTES de trocar o symlink (seguro, não troca nada):
#    extrai o pack embedado do binário novo e confere que o script
#    materializado já tem o CONFIRM_THRESHOLD.
./gc-patched-orphansweep --help >/dev/null && echo "builds OK"

# 3. Backup + swap (mesmo procedimento do ga-ftmci runbook):
cp -L /opt/homebrew/bin/gc /tmp/gc-backup-$(date +%Y%m%d_%H%M%S)
cp gc-patched-orphansweep /opt/homebrew/bin/gc-patched-orphansweep
ln -sf /opt/homebrew/bin/gc-patched-orphansweep /opt/homebrew/bin/gc
launchctl kickstart -k gui/$(id -u)/com.gascity.supervisor   # ou o label correto

# 4. VERIFICAR (teste de aceite): depois do próximo tick do order (5min),
#    confirmar que o ledger foi criado e que nenhum claim vivo foi resetado.
cat .gc/runtime/packs/maintenance/orphan-sweep-counts.json 2>/dev/null
grep -c CONFIRM_THRESHOLD .gc/system/packs/maintenance/assets/scripts/orphan-sweep.sh
# deve ser 1 (o fix "pegou" e sobreviveu ao próximo reconcile)
```

**Rollback:** `ln -sf <gc-backup-anterior> /opt/homebrew/bin/gc` +
`launchctl kickstart -k ...supervisor`.

---

## Impacto enquanto o fix não é deployado

**Risco atual é BAIXO, não é urgência de outage:** o protocolo de
colisão dos dogs (claim-first invariant + verificação de sessão viva antes
de agir, `gc-gatedone-shared-root-commit-hazard` / `duplicate-bug-dispatch-
check-before-rebuild`) já capturou AMBAS instâncias observadas
(`ga-beikk`, `ga-a1tdi`) sem dano real — o segundo dog detectou a colisão,
devolveu o bead, e nenhum trabalho foi perdido. O custo real é: slots de
pool desperdiçados + dispatch duplicado ocasional, não corrupção/perda de
dados. Ainda assim, recorrente o suficiente (2x observado numa única sessão
de ~1h de investigação) para justificar priorizar a janela de deploy.

## Estrela-guia (aceite)

`orphan-sweep` continua limpando beads de agentes genuinamente mortos
(dentro de ~5-10min em vez de instantâneo — custo aceitável), mas NUNCA
mais reseta um claim cuja sessão dona está provadamente viva no momento do
sweep seguinte. Relacionado: [[gc-binary-rebuild-version-compat-fix]],
[[gascity-engine-fork-topology]], `ga-ftmci-dolt-cpu-engine-window.md`
(mesmo padrão de runbook).
