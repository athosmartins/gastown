# Janela de manutenção: `bd` + engine `gc`

**Preparado pelo Mayor em 2026-08-07 03:4x.** Athos aprovou fazer **as duas no mesmo dia**
(a interrupção custa o mesmo: parar, subir, verificar — fazer junto paga uma vez só).
Falta só ele escolher a hora.

**Duração estimada:** 30–50 min, sendo ~15 min de indisponibilidade real.
**Melhor horário:** quando a fila do gate estiver vazia (conferir antes — passo 0).

---

## Por que fazer

| item | destrava | risco de não fazer |
|---|---|---|
| **`bd`** | perda silenciosa de escrita concorrente | **medido:** 1 de 10 escritas simultâneas some, exit 0 em todas. Um dog mediu 197 de 200 perdidas |
| **engine `gc`** | 23 beads represados, incluindo 1 P0 | ~4 encarnações de agente redescobrindo o mesmo bloqueio por bead |

O P0 (`ga-eu2x`): `gc dolt health` reporta 6 **bancos de produção** como órfãos, e aponta
para o comando mais destrutivo da cidade.

---

## O que a preparação já descobriu (e teria descarrilado a janela)

1. **O commit do binário `bd` instalado não existe no repo local.** `bd version` diz
   `main@36a23d7eefc2`; `git cat-file -e` não acha. O binário veio de outro lugar. **Não
   assuma que o repo local reflete o que está rodando.**
2. **O repo `~/gt/beads` tem DOIS remotes:** `fork` (athosmartins/beads) e `origin`
   (gastownhall/beads). O upstream `steveyegge/beads` **não é remote aqui**.
3. **Boa notícia: o conserto já está no `origin/main`.** Não precisa do steveyegge. Em
   `origin/main` o merge de metadata desceu para a camada de storage
   (`internal/storage/issueops/update.go:873`, via `storage.MergeMetadataJSON`), usando o
   valor lido **na mesma operação** em vez de um pre-read da CLI — que é a causa da perda.
   O guard quebrado (`cmd/bd/update.go:404`, `len(issue.Metadata) > 0`) não existe mais lá.
4. **Distância pequena:** `origin/main` está **6 commits** à frente do HEAD local.
5. **O patch do engine está velho:** `.local-patches/_src-hookfix`, branch
   `ftmci-incremental-hydration`, arquivo parado desde **04/06** (2 meses). **Precisa
   re-verificar contra o HEAD atual antes de aplicar** — orce isso, não só o build.

---

## Passo 0 — Pré-voo (fazer ANTES de parar qualquer coisa)

```bash
# fila do gate vazia? (se houver trabalho real, espere)
bash ~/gt/.gascity-gastown-hq/scripts/gate-queue-composition.sh

# recursos pro BUILD do engine (ga-6o4bh): disco sozinho engana — mede
# tambem swap livre, estado do GOCACHE e tendencia de load, e recomenda.
# NAO auto-aborta; a decisao de seguir/adiar continua sua. Rode de novo o
# mais perto possivel do inicio real do build (os numeros mudam em minutos —
# foi exatamente o que aconteceu na janela abortada de 26/08, ver ga-v7nk4).
bash ~/gt/.gascity-gastown-hq/scripts/engine-build-preflight.sh

# derive porta e data_dir do PROCESSO VIVO, nunca de doc
DOLT_PID=$(pgrep -f 'dolt sql-server' | head -1)
ps -o command= -p "$DOLT_PID" | tr ' ' '\n' | grep yaml   # → o config
# grep -E 'port|data_dir' <esse config>
```

**Backup do Dolt antes de tocar em `bd`** — a migração de schema é o risco real:

```bash
gc dolt backup   # ou o mecanismo canônico; confirme com `gc dolt --help`
```

⚠️ **Nunca** `rm -rf` em `.dolt/`, nem cópia manual do data_dir com o servidor no ar.

---

## Passo 1 — `bd` (o que tem perda de dado)

```bash
cd ~/gt/beads
git fetch origin
git log --oneline HEAD..origin/main        # esperado: ~6 commits
git checkout -b upgrade-$(date +%Y%m%d) origin/main

# build (confira o alvo com `make help` ou o Makefile antes)
make build   # ou: go build -o bd ./cmd/bd
```

**Antes de instalar, teste o binário novo contra um store DESCARTÁVEL**, nunca o hq:

```bash
# 1. o binário roda?
./bd version

# 2. o teste que motivou tudo: 10 escritas concorrentes
#    (num store scratch, NÃO no hq)
#    esperado DEPOIS do fix: 10 de 10 chaves sobrevivem
```

**Só então** substitua `~/.local/bin/bd`, guardando o antigo:

```bash
cp ~/.local/bin/bd ~/.local/bin/bd.pre-upgrade-$(date +%Y%m%d)
cp ./bd ~/.local/bin/bd
```

### 🚨 O risco de schema (precedente P0 `v55`)

Um `bd` mais novo pode **auto-migrar o schema do HQ ao vivo** e derrubar a cidade. O
`origin/main` do beads tem commit `Guard and qualify historical upgrades to v1.2`.

**Antes de rodar qualquer comando contra o hq:**

```bash
# quantas tabelas o hq tem hoje (baseline)
gc dolt sql -q "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='hq'"
# → 30 em 2026-08-07
```

Rode o primeiro comando **de leitura** e confira se o schema mudou. Se mudou sem aviso,
**pare e restaure o binário antigo** — a migração já terá começado, e aí é restore de backup.

---

## Passo 2 — engine `gc`

```bash
cd ~/gt/.local-patches/_src-hookfix
git status internal/config/config.go     # deve estar MODIFICADO (patch não commitado)
git fetch origin && git log --oneline HEAD..origin/main
```

⚠️ **O patch é de 04/06.** Re-verifique que ele ainda aplica e ainda faz sentido contra o
HEAD atual antes de commitar. Se o arquivo mudou muito, refaça o patch em vez de forçar.

O que ele conserta: `bdReadyPoolDemandShell` / `bdReadyPoolDemandExcludeLabelArgs` /
`poolDemandLabelFilterJQ` — o filtro `pool:refused:*` que falta ao probe do DOG.
`wa-worker` e `ps-worker` já têm o equivalente como edição de template (`ga-y8qh`); só o
DOG depende do Go.

**Build do engine** — atenção ao CGO (memória: `gastown-internal-cmd-needs-icu-cgo-cppflags`):

```bash
# icu4c é necessário; NUNCA rode dois builds concorrentes no mesmo GOCACHE
export CGO_CPPFLAGS="-I$(brew --prefix icu4c)/include"
```

**Swap do binário é GRADUAL:** o SO resolve o symlink por processo, então sessões já
abertas seguem no binário velho até reiniciarem. Não espere efeito imediato, e **não
reinicie a cidade inteira** para forçar (memória: `mayor-city-restart-keepalive-loop-token-burn`).

---

## Passo 3 — Verificação (o que prova que funcionou)

```bash
# bd: a perda de escrita concorrente acabou?
#   10 escritas simultâneas → 10 chaves. Antes: 9.

# engine: o probe do DOG filtra pool:refused agora?
#   um bead com pool:refused:* NÃO deve ser oferecido a dog.

# cidade de pé?
gc dolt health
bash ~/gt/.gascity-gastown-hq/scripts/gate-queue-composition.sh
```

**Depois, reabrir os 23 represados:** eles estão `deferred` ou com
`pool:refused:engine-rebuild-required`. Rastreador: `ga-m7gwo` (agregador, com as três
medições de custo) e `ga-s2eri` (umbrella dos 3 gaps do pool).

---

## Rollback

| falha | ação |
|---|---|
| `bd` novo quebra | `cp ~/.local/bin/bd.pre-upgrade-* ~/.local/bin/bd` |
| schema migrou e a cidade caiu | parar Dolt, restaurar backup do passo 0, voltar o `bd` antigo |
| engine novo quebra | o binário antigo ainda está no disco; o swap é por processo |

**Sinal de que deu errado:** `bd` com "Error 1105", `gc dolt health` sem resposta, ou beads
sumindo de `bd list`. Ao primeiro desses, **pare e reverta** — não investigue com a cidade caída.

---

## Beads relacionados

- `ga-9tgos` — perda de escrita concorrente (a causa do `bd`), com a verificação medida
- `ga-m7gwo` — agregador do engine, 23 beads + três medições independentes de custo
- `ga-s2eri` — umbrella dos 3 gaps do pool (P1, `needs:engine-window`)
- `ga-eu2x` — o P0 que a janela destrava
