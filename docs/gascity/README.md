# Gas Town → Gas City — análise de migração

Cópia git-tracked (redundância) da investigação + spike feitos em 2026-05-30 (crew/thies).
**Fonte da verdade = beads no Dolt** (`dc-lsvz`, `dc-io31`, epic `dc-b31r` RESUME-HERE). Esta pasta é só conforto/backup.

## Conclusão (1 linha)
Migrar pra Gas City é a direção certa: custo ~4–8 person-days (só ~12 de 93 fork-commits são rebuild real), data plane Dolt/beads preservado. Fazer **faseado** (POC → parallel-run → cutover rig-a-rig, WA por último, Gas Town como rollback). Confiança ~70–75%. Decisão de executar = usuário + Mayor.

## Arquivos
- [`dc-lsvz-gascity-recomendacao.md`](dc-lsvz-gascity-recomendacao.md) — investigação, recomendação, revisão adversarial.
- [`dc-io31-spike-fork-inventory.md`](dc-io31-spike-fork-inventory.md) — inventário dos 93 fork-commits, Fase 0 (docs) + Fase 1 (validação runtime com `gc` instalado).

## Retomar
`bd show dc-b31r` → child beads `deferred` (dc-orix POC → dc-sy13 parallel-run → dc-43z6 cutover). Flipar dc-orix pra `open` quando decidir começar.

## Guardrails
Nunca apontar `gc` pro Dolt de produção (porta 3307). Spike/POC só em cópia; `gc init` sobe Dolt isolado em porta própria. Teardown: `gc stop` + `gc unregister` + `gc supervisor stop && gc supervisor uninstall`.
