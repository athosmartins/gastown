# /gt-health — Comprehensive Gas Town Health Check

Roda checagens cobrindo divergência de upstream (incluindo cross-fork), saúde de worktrees em TODOS os rigs, backlog crítico, e debris acumulado. Use no início da sessão (após `gtstart`), no meio do dia, ou sempre que quiser sanity check.

**Rigs cobertos (descobertos dinamicamente):** todos sob `~/gt/` exceto `mayor/` e diretórios sem `.git`. Atualmente: whatsapp_automation, gastown, lexbh, marketing, property_scrapers, deacon.

## Eixos verificados

### 1. Divergência por clone — TODOS os rigs (cada clone vs SEU origin/main)

Loop sobre cada rig, depois cada sub-clone (root, crew/*, refinery/rig, witness/rig, polecats ativos):

```bash
for rig_root in ~/gt/*/; do
  rig_name=$(basename "$rig_root")
  [ "$rig_name" = "mayor" ] && continue
  [ -d "$rig_root/.git" ] || [ -f "$rig_root/.git" ] || continue

  echo "=== $rig_name ==="
  for d in "$rig_root" "$rig_root"crew/*/ "$rig_root"refinery/rig "$rig_root"witness/rig "$rig_root"polecats/*/$rig_name; do
    [ -d "$d/.git" ] || [ -f "$d/.git" ] || continue
    branch=$(git -C "$d" branch --show-current 2>/dev/null)
    ab=$(git -C "$d" rev-list --left-right --count HEAD...origin/main 2>/dev/null)
    dirty=$(git -C "$d" status --short 2>/dev/null | wc -l | xargs)
    label=$(echo "$d" | sed "s|$HOME/gt/||")
    echo "  $label | $branch | ahead/behind=$ab | dirty=$dirty"
  done
done
```

Para cada linha:
- branch ≠ main e não é `crew/*/dc-*` → suspeito
- ahead > 0 em main (não em feature branch) → trabalho local não pushado
- dirty > 0 → uncommitted work, investigar antes de qualquer reset

### 2. Divergência cross-fork (forks vs canônico do steveyegge)

Repos que são FORKS do gas-town source: identificar via `git remote -v` mostrando steveyegge.

```bash
for d in ~/go/src/gastown ~/gt/gastown ~/gt/deacon; do
  [ -d "$d/.git" ] || continue
  if git -C "$d" remote -v 2>/dev/null | grep -q "steveyegge"; then
    echo "=== $d (fork) ==="
    git -C "$d" fetch --all 2>&1 | tail -2
    git -C "$d" rev-list --left-right --count fork/main...origin/main 2>/dev/null
    # Output: <fork-ahead> <upstream-ahead>
  fi
done
```

**Alerta se behind > 50:** débito acumulado tipo o caso 203 behind descoberto em 2026-05-06 (dc-bsza).

Aviso do gt CLI: `gt --version 2>&1 | grep "behind"` — binary desatualizado vs source local.

### 3. Backlog crítico (rig-agnóstico — bd list global)

```bash
bd list --priority-max P1 --status open --limit 0
bd list --status open --updated-before "$(date -v-3d +%Y-%m-%d)" --limit 20
```

- P0/P1 sem owner ou sem progresso em >1 dia → flag forte
- Beads idle >3 dias → candidatos a triage/close
- Convoys orfãos (open mas tracking bead já fechado) → close

### 4. Tmux session hygiene

```bash
tmux_socket="${GT_TMUX_SOCKET:-$(basename "${TMUX%%,*}")}"
tmux -L "$tmux_socket" list-sessions
```

Para cada sessão suspeita (não-padrão como zzor-*, *-witness órfão sem rig correspondente):
```bash
tmux -L "$tmux_socket" capture-pane -t <session> -p | tail -5
```
"Pane is dead" → kill.

### 5. Stale backup branches em TODOS os rigs

```bash
for d in ~/gt/*/; do
  rig_name=$(basename "$d")
  [ "$rig_name" = "mayor" ] && continue
  branches=$(git -C "$d" branch 2>/dev/null | grep -E "backup-|wip-|safe-" | head -5)
  [ -n "$branches" ] && echo "=== $rig_name ===" && echo "$branches"
done
```

Backups com >3 dias e conteúdo já em origin/main → candidatos a delete.

### 6. Tarballs antigos em /tmp

```bash
ls -la /tmp/*reset*.tar.gz /tmp/*backup*.tar.gz /tmp/*.patch 2>/dev/null
```

>3 dias + sem patch ativo dependente → delete.

### 7. Daemon liveness por rig

Cada rig tem seus próprios daemons. Listar e checar processos + health endpoints conhecidos:

```bash
ps aux | grep -E "daemon|dashboard|worker|api" | grep -v grep | awk '{print $2, $11, $12}' | head -30

# Health endpoints conhecidos (ajustar conforme rig)
curl -s -o /dev/null -w "WA demand:8095: HTTP %{http_code}\n" -m 3 http://localhost:8095/api/outreach/config
curl -s -o /dev/null -w "WA admin:8097: HTTP %{http_code}\n" -m 3 http://localhost:8097/
# Adicionar mais à medida que outros rigs ganharem daemons HTTP
```

### 8. Polecats stale em TODOS os rigs

```bash
for rig in whatsapp_automation gastown lexbh marketing property_scrapers deacon; do
  [ -d "$HOME/gt/$rig/polecats" ] || continue
  echo "=== $rig polecats ==="
  gt polecat stale $rig 2>&1 | tail -10
done
```

### 9. Dolt server health

```bash
gt dolt status
ss -tan state time-wait 2>/dev/null | grep ":3307" | wc -l
```

Connections > 100 ou TIME_WAIT > 100 → flag.

### 10. Mail inbox (Mayor + cada crew member)

```bash
gt mail inbox -u
for rig in whatsapp_automation gastown lexbh marketing property_scrapers deacon; do
  for crew in $(ls $HOME/gt/$rig/crew 2>/dev/null); do
    cnt=$(gt mail inbox $rig/crew/$crew -u 2>/dev/null | grep -oE "[0-9]+ unread" | head -1)
    [ -n "$cnt" ] && [ "$cnt" != "0 unread" ] && echo "$rig/crew/$crew: $cnt"
  done
done
```

Unread P0/P1 escalations não-acked → flag.

### 11. Cota do Claude (quota — janela 5h + semanal)

```bash
# Sinal de VERDADE (não chute): lê os eventos reais de "You've hit your … limit"
# que o Claude Code grava no transcript + soma o uso real de tokens na janela 5h.
~/gt/.gascity-gastown-hq/scripts/claude-quota-check.sh        # relatório legível
~/gt/.gascity-gastown-hq/scripts/claude-quota-check.sh --json # p/ scripts (exit 2 = LIMITED)
```

LIMITED (🔴) → cota esgotada de verdade, espere o reset (a linha mostra quando).
not limited (🟢) → se algo estiver travado, **NÃO é cota** → investigue infra.
Substitui o `check-credit-usage.sh` quebrado (estimava a janela por tempo de
relógio → dava "-11300%"). Lição ga-wjlv9 (2026-06-10): nunca mais diagnosticar
cota no chute.

## Output esperado

Tabela markdown agrupada por eixo + por rig dentro de cada eixo. Anomalias em **bold**. Sem anomalias → "✅ Sistema limpo".

## Veredict

- 🟢 **Saudável** — nada fora do esperado
- 🟡 **Atenção** — divergências cosméticas ou trabalho não-crítico pendente
- 🔴 **Bloqueio** — P0/P1 idle, fork muito atrás do canônico, daemon caído, crew com trabalho crítico não comitado, ou divergência cross-fork > 50 commits

## Notas

- Roda em ~60-90 segundos (loops por rig somam tempo)
- Read-only — não modifica nada
- Para sweep + auto-fix da dívida técnica: use `/gt-eod`
