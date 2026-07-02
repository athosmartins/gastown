# /gt-eod — End-of-Day Sweep + Tech Debt Triage

Roda no fim do dia, antes de fechar a sessão Mayor / gastown. Pega TUDO que ficou de dívida técnica e tenta resolver (sling pra polecats, close de redundantes, cleanup de debris). Reporta o que sobrou.

## Fluxo

### Fase 1: Health Check (read-only)

Roda `/gt-health` primeiro pra mapear o terreno. Captura:
- Beads abertos de hoje (P0/P1/P2)
- Beads ativos não-resolvidos
- Worktrees dirty
- Backup branches stale
- Tarballs antigos
- Polecats stale
- Forks divergentes

### Fase 2: Triage da dívida técnica

Para cada categoria, classificar e agir:

#### 2a. Beads abertos criados HOJE

```bash
TODAY=$(date +%Y-%m-%d)
bd list --status open --created-after "$TODAY" --limit 0
```

Para cada um:
- **Trivial / pode auto-resolver** (e.g., bead duplicado, bead vazio): `bd close --reason ...`
- **Discovery-heavy mas auto-contido**: sling pra polecat fresh — `gt sling <bead> <rig>`
- **Decisão necessária do user**: deixar aberto, listar no relatório final

#### 2b. Backup branches obsoletos (>1 dia, conteúdo já em origin/main)

Para cada rig:
```bash
for rig in whatsapp_automation gastown lexbh marketing property_scrapers deacon; do
  d=~/gt/$rig
  [ -d "$d/.git" ] || continue
  for b in $(git -C "$d" branch 2>/dev/null | grep -E "backup-|wip-" | tr -d ' *'); do
    # Verifica se conteúdo da branch já está em origin/main
    diff_count=$(git -C "$d" diff origin/main "$b" --stat 2>/dev/null | tail -1)
    age_days=$(( ( $(date +%s) - $(git -C "$d" log -1 --format=%ct "$b") ) / 86400 ))
    if [ "$age_days" -gt 1 ]; then
      echo "$rig: $b (age $age_days d, diff $diff_count)"
    fi
  done
done
```

Se `diff` é apenas submodule pointers e age > 1d → `git -C "$d" branch -D "$b"`.

#### 2c. Tarballs antigos /tmp

```bash
find /tmp -name "*reset*.tar.gz" -o -name "*backup*.tar.gz" -o -name "*.patch" -mtime +3 2>/dev/null
```

Para cada um: verificar se algum bead aberto referencia o patch/backup. Se não → delete.

#### 2d. Polecats stale

```bash
for rig in whatsapp_automation gastown; do
  gt polecat stale $rig --cleanup 2>&1 | tail -5
done
```

`--cleanup` faz auto-nuke de polecats verdadeiramente stale.

#### 2e. Beads convoy órfãos

Convoys open cujo bead-tracked já fechou:
```bash
bd list --type convoy --status open --limit 0
# Para cada: verificar se DEPENDS ON tem todos closed
```

Se sim → close convoy.

#### 2f. Crew clones com mail unread sem hook firing

Triggar `gt mail poll-and-nudge` (do dc-ip3w) pra acordar crew idle:
```bash
gt mail poll-and-nudge --dry-run
gt mail poll-and-nudge  # se dry-run mostra candidatos
```

#### 2g. Beads de descrição vazia / só ref a outro bead

```bash
# Pattern: title is exactly "dc-XXXX" or empty
bd list --status open --empty-description --limit 20
```

Se title é apenas referência a outro bead já fechado → `bd close --reason "stale ref bead, target closed"`.

### Fase 3: Sling do que sobrar pra polecats

Para beads abertos que:
- Foram criados hoje OU
- São P0/P1 sem owner OU
- São tech-debt objetivamente endereçável (audit/cleanup/scan-and-fix)

E que NÃO requerem decisão do user:

```bash
gt sling <bead> <rig> --crew <appropriate-member>
# Ou se não tiver owner óbvio:
gt sling <bead> <rig> --force  # spawna polecat fresh
```

Heurística de roteamento:
- Audit / connection pool / infra → batista
- Daemon crash / regression / dashboard → última pessoa que tocou no arquivo
- Cross-codebase analysis → polecat fresh

### Fase 4: Relatório final

Gerar tabela:

| Categoria | Encontrado | Auto-resolvido | Slung | Aguardando user |
|---|---|---|---|---|
| Beads novos hoje | N | X | Y | Z |
| Backup branches stale | N | X | - | - |
| Tarballs antigos | N | X | - | - |
| Polecats stale | N | X | - | - |
| Convoys órfãos | N | X | - | - |
| P0/P1 sem owner | N | - | Y | Z |

Veredict final:
- ✅ **"Dia limpo"** — toda dívida criada hoje foi resolvida ou slung
- ⚠️ **"Dívida residual"** — itens explicitamente listados aguardando decisão sua

## Quando rodar

- Antes de `Ctrl+B D` ou fechar tmux Mayor no fim do dia
- Antes de qualquer pausa longa (fim de semana, viagem)
- Sempre que sentir que o sistema está "carregando peso"

## Constraints

- NUNCA close P0/P1 sem confirmação do user
- NUNCA delete backup branches com diff real (só pure submodule drift)
- NUNCA force-push em qualquer remote
- Sempre confirmar antes de operações destrutivas em working trees live (regra: daemons live = read-only)

## Notas

- Roda em ~3-5 minutos dependendo de quanto há pra triar
- Logs em `/tmp/gt-eod-$(date +%s).log` para auditoria posterior
- Pareado com `/gt-health` (read-only) que pode ser rodado a qualquer momento
