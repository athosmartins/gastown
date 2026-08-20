#!/usr/bin/env bash
# upstream-drift-sentinel.sh — mede o atraso dos repos de PRODUÇÃO vs upstream (ga-m7gwo).
#
# POR QUE EXISTE (Athos perguntou 01/08 "estamos muito atrasados?"; a resposta foi sim,
# e a causa da causa foi pior que o atraso):
#   O `_src-hookfix` — a árvore que compila o `gc` que a cidade INTEIRA roda — não tinha
#   remote upstream configurado. Só o fork. Então `git fetch` ali nunca trazia
#   gastownhall/gascity, e o atraso não era "ignorado": era INVISÍVEL. Ninguém decidiu
#   adiar por 8 semanas; o número não existia pra ser visto.
#   Custo real medido no dia: recompilamos o engine à mão pra baixar um poll de 2s->15s,
#   sendo que o upstream já tinha (a) o mesmo fix melhor, atacando o churn de conexão
#   (a1235ff46), e (b) o intervalo como CONFIG (9368f22a3). Pagamos duas vezes, com
#   solução pior.
#
# REGRA DE OURO DESTE SCRIPT (a lição que mais custou hoje):
#   ERRO NUNCA PODE PRODUZIR O MESMO RESULTADO QUE "SEM ATRASO".
#   Um fetch que falha, um repo que sumiu, uma rede fora — tudo isso emite status=ERRO
#   e notifica. O modo de falha que este sentinela existe pra evitar é justamente o
#   silêncio que parece saúde. Ver [[error-and-empty-must-not-produce-the-same-value]].

set -uo pipefail

LOG_DIR="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}/.gc/logs"
LOG="$LOG_DIR/upstream-drift-sentinel.log"
STATE="$LOG_DIR/.upstream-drift-sentinel.state"
mkdir -p "$LOG_DIR"

# Limite pra notificar. Escolhido a partir do incidente que originou o script: 8 semanas
# de atraso já custaram retrabalho de engine. 300 commits é ~2-3 semanas no ritmo atual
# do upstream (que commitou 33min antes da medição de 01/08) — cedo o bastante pra o
# merge ainda ser fatiável, tarde o bastante pra não virar ruído semanal.
DRIFT_ALERT_COMMITS="${DRIFT_ALERT_COMMITS:-300}"
FETCH_TIMEOUT="${FETCH_TIMEOUT:-120}"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# repo|caminho|url_upstream|ref|rotulo
#
# `rotulo` existe só pra DESAMBIGUAR a saída (ga-rw823d): os 3 nomes abaixo são
# parecidos o bastante pra já terem causado um erro de 5x numa avaliação real
# (20/08) — "gascity" foi lido como sendo o motor `gc` quando na verdade era
# outro repo, porque ~/gt/.gascity-gastown-hq COMPARTILHA o .git de ~/gt, e
# `git log` ali parece o histórico do motor sem ser. O rótulo não afeta NADA
# da medição — path/url/ref abaixo são os mesmos de sempre — só o texto que
# log/alerta imprimem, via $label mais abaixo.
REPOS="
gascity|/Users/athos/gt/.local-patches/_src-hookfix|https://github.com/gastownhall/gascity.git|main|MOTOR gc (tem cmd/gc)
beads|/Users/athos/gt/beads|https://github.com/gastownhall/beads.git|main|
gastown-legado|/Users/athos/gt|https://github.com/steveyegge/gastown.git|main|NAO é o motor (ships cmd/gt, não cmd/gc)
"

alerts=""
errors=""
summary=""

log "=== sweep início (limite=${DRIFT_ALERT_COMMITS} commits) ==="

while IFS='|' read -r name path url ref tag; do
  [ -z "$name" ] && continue

  # Rótulo de exibição: nome + caminho SEMPRE (o path é o discriminador que não
  # mente — dois repos podem ter nome parecido, nunca o mesmo path), mais o
  # rótulo motor/não-motor quando houver. Usado em TODA mensagem de log/alerta
  # daqui pra baixo em vez de $name puro — a lógica de medição (git fetch/
  # rev-list acima em $path/$url/$ref) não muda uma linha.
  label="$name ($path)"
  [ -n "$tag" ] && label="$label [$tag]"

  if [ ! -d "$path/.git" ] && ! git -C "$path" rev-parse --git-dir >/dev/null 2>&1; then
    log "  $label: ERRO — não é repo git"
    errors="${errors}\n  · $label: repo ausente"
    continue
  fi

  # Fetch com timeout. NÃO silenciamos stderr: se falhar, queremos o motivo no log.
  fetch_err=$(timeout "$FETCH_TIMEOUT" git -C "$path" fetch "$url" "$ref" 2>&1 >/dev/null)
  frc=$?
  if [ $frc -ne 0 ]; then
    # 124 = timeout do coreutils/BSD timeout. Distinguir dos demais importa: timeout
    # costuma ser rede/upstream lento; erro != 124 costuma ser auth/URL/repo sumido.
    if [ $frc -eq 124 ]; then
      log "  $label: ERRO — fetch estourou ${FETCH_TIMEOUT}s (rede? upstream lento?)"
      errors="${errors}\n  · $label: fetch TIMEOUT ${FETCH_TIMEOUT}s"
    else
      log "  $label: ERRO — fetch falhou (rc=$frc): $(printf '%s' "$fetch_err" | head -2 | tr '\n' ' ')"
      errors="${errors}\n  · $label: fetch falhou (rc=$frc)"
    fi
    continue
  fi

  # Comparar a NOSSA cabeça de trabalho com o upstream.
  counts=$(git -C "$path" rev-list --left-right --count FETCH_HEAD...HEAD 2>&1)
  if [ $? -ne 0 ]; then
    log "  $label: ERRO — rev-list falhou: $(printf '%s' "$counts" | head -1)"
    errors="${errors}\n  · $label: rev-list falhou"
    continue
  fi

  behind=$(printf '%s' "$counts" | awk '{print $1}')
  ahead=$(printf '%s' "$counts" | awk '{print $2}')

  # Guarda explícita: se não vier número, é ERRO — não "zero atraso".
  case "$behind" in ''|*[!0-9]*)
    log "  $label: ERRO — contagem não-numérica ('$counts')"
    errors="${errors}\n  · $label: contagem inválida"
    continue ;;
  esac

  mb=$(git -C "$path" merge-base FETCH_HEAD HEAD 2>/dev/null)
  age=$(git -C "$path" log -1 --format='%cr' "$mb" 2>/dev/null)
  up_last=$(git -C "$path" log -1 --format='%cr' FETCH_HEAD 2>/dev/null)

  log "  $label: atrás=$behind à_frente=$ahead divergimos_há=${age:-?} upstream_commitou=${up_last:-?}"
  summary="${summary}\n  · $label: ${behind} atrás / ${ahead} à frente (divergimos há ${age:-?})"

  if [ "$behind" -ge "$DRIFT_ALERT_COMMITS" ]; then
    alerts="${alerts}\n  · $label: ${behind} commits atrás (divergimos há ${age:-?})"
  fi
done <<< "$REPOS"

printf '%s|%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$(printf '%b' "$summary" | tr '\n' ';')" > "$STATE"

# --- Notificação -----------------------------------------------------------
# ERRO notifica SEMPRE, mesmo sem atraso detectado: um sentinela que falha calado
# é pior que não ter sentinela — passa a sensação de cobertura sem a cobertura.
if [ -n "$errors" ]; then
  log "SWEEP COM ERRO(S)"
  if command -v notify >/dev/null 2>&1; then
    notify -t "Sentinela de upstream FALHOU" -p 4 \
      "$(printf 'O sentinela não conseguiu medir o atraso — isso NÃO significa que está em dia:%b' "$errors")"
  fi
fi

if [ -n "$alerts" ]; then
  log "ALERTA: atraso acima do limite"
  if command -v notify >/dev/null 2>&1; then
    notify -t "Repos atrasados vs upstream" -p 3 \
      "$(printf 'Acima de %s commits — merge fica mais caro a cada semana:%b\n\nDetalhe: bead ga-m7gwo' "$DRIFT_ALERT_COMMITS" "$alerts")"
  fi
else
  [ -z "$errors" ] && log "OK — todos abaixo do limite de ${DRIFT_ALERT_COMMITS}"
fi

log "=== sweep fim ==="
exit 0
