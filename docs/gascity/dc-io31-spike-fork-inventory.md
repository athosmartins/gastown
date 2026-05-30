# dc-io31 — Spike Gas City (Fase 0): inventário dos 93 fork-commits

**Autor:** crew/thies · **Data:** 2026-05-30 · Parent: dc-lsvz
**Risco a produção nesta fase: ZERO** — só leitura de GitHub (fork vs upstream) + docs do Gas City. Nada tocou Dolt/beads de produção.

## Fato base (verificado via GitHub API)
`athosmartins/gastown` = **93 ahead, 0 behind** de `gastownhall/gastown`. Os 93 commits foram categorizados por custo de migração, lendo o modelo real de config/override do Gas City (`coming-from-gastown.md`, `config.md`, `cli.md`, `examples/gastown/` packs).

## Resultado — distribuição de custo

| Bucket | Significado | Qtd |
|---|---|--:|
| **SYNC** | merge/sync com upstream, sem comportamento nosso → custo zero | 16 |
| **A — nativo no GC** | vira feature built-in; o commit é **deletado** na migração | 11 |
| **B — vira config** | pack / order / formula / template / doctor-check; sem Go | 20 |
| **C — rebuild real** | Go/hook custom sem caminho de config no GC → **alto custo** | **22** |
| **D — env/compat** | bash 3.2 macOS, socket-DSN, lint, test-flakiness, launchd → necessário em qualquer orquestrador | 24 |
| **TOTAL** | | 93 |

➡️ **71 dos 93 são baratos** (16 free + 11 deletados + 24 plumbing + 20 config). O custo está nos **22 do bucket C — mas eles colapsam em ~6 temas.**

## O achado decisivo (load-bearing)
O Gas City **não tem slot de config pra anexar hook shell custom de PreToolUse/Stop**. Ele instala hooks por whitelist de provider e expõe lifecycle hooks (`pre_start`/`session_setup`/`on_death`...), mas não um "rode este script no Stop/PreToolUse". Esse único gap arrasta **~9 dos 22 commits C**: todos os tap-guards (cross-clone-block, HOOK BLOCK marker, polecat PR guard) + os Stop-hooks (cost-recording `gt costs record`, auto-save WIP gt-pvx).

Os rebuilds genuinamente irredutíveis (sem primitivo GC nenhum):
- **remote-control injection** (`--remote-control` em todas as sessões) — não existe conceito no GC.
- **credential leak / pre-send detection** — sem secret-scan/pre-send hook.
- **convoy dedup** em notificações de completion (`--notify` existe, dedup não é subcomando documentado).
- **merge-queue rebase Go** (preservar cherry-pick-equivalent no `gt done`).
- **dashboard panels** (observability custom) — rebuild como surface externo.

## Estimativa
**Bucket C ≈ 8–15 person-days**, front-loaded em (1) contribuir hook-authoring custom upstream no GC — destrava ~9 commits de uma vez, (2) remote-control, (3) credential detection. Resto do C é mecânico depois disso.

## Caveat honesto (limite desta fase)
As classificações de "não tem equivalente no GC" são **derivadas de docs**, não validadas rodando `gc`. O achado mais pesado (gap de hooks custom) precisa de validação runtime: se os docs estiverem incompletos e o GC suportar hooks custom, o bucket C **cai de 22 pra ~13** e a estimativa despenca. Essa é a única incerteza que move a agulha → próxima fase.

## Próximo passo recomendado (Fase 1 — ainda zero risco a produção)
Instalar `gc` num dir sandbox + rodar o pack "Gas Town" replica, e **validar especificamente o gap de hooks custom**. Não precisa tocar Dolt de produção pra isso — só inspecionar o modelo de hooks do GC rodando. Decisão de instalar/onde fica com o usuário.

---

## Fase 1 — VALIDAÇÃO RUNTIME (gc 1.2.0 instalado + city throwaway) — 2026-05-30

**Risco a produção: ZERO** — city throwaway subiu Dolt isolado na porta 50592; produção 3307 intacta; teardown completo (supervisor uninstalled, plist removido, dir apagado, sem procs órfãos).

### O achado decisivo da Fase 0 estava ERRADO
`gc init` gera `.gc/settings.json` = **settings.json padrão do Claude Code com bloco `hooks`**. O próprio GC popula `SessionStart`, `UserPromptSubmit`, `PreCompact` com hooks shell `command`. O schema aceita nativamente **`PreToolUse`/`PostToolUse`/`Stop`**. Extra: `.beads/hooks/{on_create,on_close,on_update}` (hooks shell de beads).

➡️ "GC não tem slot pra hook custom" é **falso**. Os ~10 commits que estavam em C por causa desse gap viram **B (config)**: cross-clone-block tap-guards (61/66/67/83), cost-record Stop hook (19), auto-save WIP (34/40/44), polecat-PR guard (89), crew-commit guard (78). Bônus: `gc dashboard` nativo → painéis custom (#41) obviados (bucket A), não rebuild.

### Distribuição revisada
| Bucket | Fase 0 | **Fase 1** |
|---|--:|--:|
| SYNC | 16 | 16 |
| A (nativo) | 11 | ~12 |
| B (config) | 20 | ~30 |
| C (rebuild real) | **22** | **~12** |
| D (env/compat) | 24 | 24 |
| **Estimativa C** | 8–15 dias | **~4–8 dias** |

### C irredutível restante (~12) e resíduo
remote-control injection (79/84/88), credential pre-send (24), convoy dedup (54/87), merge-queue rebase Go (73), sling internals (1/35), witness lifecycle (42), cross-rig close routing (76).
**Resíduo (mesma checagem runtime de ~10min resolve):** (a) remote-control pode ser arg de launch de sessão (→ B?); (b) credential pre-send pode ser PreToolUse hook (→ B?); (c) durabilidade do `.gc/settings.json` (GC-managed) vs template de pack — detalhe de implementação, é config de qualquer forma.

### Bottom line atualizado
Migração é **mais barata** do que o relatório inicial sugeria. O custo NÃO é dominado por um muro de rebuilds: é ~12 commits C concentrados em ~5 temas, ~4–8 person-days, e o data plane (Dolt/beads) é preservado. O gap que parecia fatal (hooks) não existe. Recomendação dc-lsvz ("INICIAR SPIKE") confirmada e cumprida — o spike reduziu a incerteza-chave de "talvez caro" pra "moderado e bem-escopado".
