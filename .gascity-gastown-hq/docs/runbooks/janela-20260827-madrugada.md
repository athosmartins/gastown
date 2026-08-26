# Janela madrugada 27/08 — engine (preparo feito em 26/08 à tarde)

> **Estado do preparo:** a parte fiddly já está feita. A janela não precisa
> aplicar 25 patches no escuro — só fazer checkout, buildar e trocar.

## A DECISÃO QUE DESTRAVOU: de qual base buildar

**Base correta = `bbf90542c`** (tag `preserve/ga-hdfbux1-vendor-beads-110-compat`).
É o commit de onde saiu o `gc-1.1.1-vendor110` que a cidade roda hoje —
confirmado: o `gc start` reporta `buildID=bbf90542c-dirty`.

**NÃO buildar de:**
- `ftmci-incremental-hydration` (HEAD do tree) — checkpoint de 17/08 cuja
  própria mensagem diz *"will be reset"*, e **não é ancestral do binário vivo**.
- `consolidated/engine-window-20260823` — é HEAD+3, não vivo+3; também diverge.

Qualquer uma das duas **perderia a cadeia de 4 commits do vendor bump
`beads v1.1.0`** (e46057a25, 25618224a, ad8e0eb01, bbf90542c), regredindo a
dependência de beads da cidade inteira. Esse era o risco real, e é por isso
que a janela de 26/08 não devia ter rodado às cegas.

## O QUE JÁ ESTÁ PRONTO

Branch **`consolidated/engine-window-20260827`** (commit `c258abce5`),
no repo `~/gt/.local-patches/_src-hookfix`:
- base `bbf90542c` + **23 patches** da fila, empilhados e commitados, worktree limpo.
- **0 dos patches da fila estavam no binário vivo** — ou seja, esses 23 fixes
  entregam zero hoje. Essa é a razão de peso pra janela acontecer.

## COMPOSIÇÃO MEDIDA DA FILA (26/08 14:1x, contra a base certa)

| estado | n | o que fazer |
|---|---|---|
| empilham limpo — **já commitados na branch** | 23 | nada, é só buildar |
| cópia redundante (`ga-okcgb-...-signal` ≡ `...-durable-signal`, byte-idênticos) | 1 | apagar a cópia |
| colide de verdade (`ga-avvu2` × `ga-ael6v`/`ga-ih4ma`/`ga-sm8z4b` em config.go) | 1 | rebase pequeno |
| apodrecidos na mesma região quente de `config.go` (~3172–3349) | 9 | re-autorar sobre a branch nova |
| template mudou de lugar (`ga-kpu1g`: `gate-done.md`) | 1 | reapontar |
| **repo errado** (`wa-msxg5` → é do **beads**, `cmd/bd/`+`issue.go`) | 1 | tirar da fila do engine |

Os 9 apodrecidos são a família pool-probe/dispatch-filter e **conflitam entre
si** — precisam ser re-autorados em sequência por um agente só, não em paralelo.

## PRÉ-VOO — o portão que reprova hoje

`scripts/engine-build-preflight.sh` (read-only, não inicia nem aborta nada):

```
2. Swap livre .... 1.38GB (minimo 3GB)   ABAIXO   <-- reprova
```

**Só o reboot devolve swap** (a memória virtual do macOS só encolhe no boot).

## A ORDEM — e o achado de 26/08 que a justifica

1. **reboot** (devolve swap + disco)
2. **build do engine IMEDIATAMENTE depois** — não deixe pra depois
3. compactação / resto
4. verificação

**Por que o build vem ANTES de tudo o mais:** medido em 26/08. A janela do
almoço fez reboot 12:31 → compactação → e o build ficou pro fim, como bloco
opcional. Às 14:11, 1h40 depois do reboot, o swap livre já tinha voltado a
1.38GB e o preflight reprovava de novo — **no mesmo portão, pelo mesmo motivo
que reprovava antes do reboot** (0.81GB). O ganho de swap do reboot tem
prazo de validade curto. Quem chegar depois na fila não pega recurso.

Isso **não** é vazamento: é o ratchet normal de memória virtual do macOS, e o
próprio runbook do almoço já previa o re-crescimento. É uma restrição de
sequência, não um bug a caçar.

## CRITÉRIO DE SUCESSO — o binário, não "voltou a subir"

Lição do restart do tmux (ga-7fpc9, mesmo dia): uma cidade que volta com o
binário ANTIGO é visualmente idêntica a uma consertada. Não aceite "subiu" como
prova. Confira o artefato no processo vivo:

```
gc version            # deve deixar de reportar bbf90542c
lsof -nP -p <pid>     # confirme o binário realmente mapeado
```

## PENDÊNCIAS QUE NÃO SÃO DESTA JANELA

- `ga-3azujf` — bead que rastreia a fila de engine.
- `ga-ju6ob` — senha do Mac no Bitwarden (precisa do Athos).
- Compactação: ~3GB do hq se auto-curam às 04:30 via marker `pending_gc`.
