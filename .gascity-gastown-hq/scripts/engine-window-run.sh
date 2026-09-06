#!/bin/bash
# engine-window-run.sh — janela do engine, pronta pra acionar (Mayor, 2026-08-26).
#
# PEDIDO DO ATHOS (26/08, verbatim): "eu so queria ter isso pronto pra, quando
# precisar, ser facil acionar". Por isso este script NAO agenda nada, NAO roda
# sozinho e NAO tem plist. Ele so existe pra ser chamado quando ele quiser.
#
# USO
#   engine-window-run.sh            # = check. Read-only. Nao muda nada.
#   engine-window-run.sh build      # builda; NAO troca o binario vivo
#   engine-window-run.sh swap       # troca o symlink; guarda o anterior
#   engine-window-run.sh rollback   # volta pro binario anterior
#
# A ORDEM E SEMPRE check -> build -> swap. Cada fase e separada de proposito:
# uma fase que builda E troca junto nao deixa voce inspecionar o resultado
# antes de expor a cidade a ele.
#
# POR QUE O SWAP NAO DERRUBA A CIDADE
# O SO resolve o symlink no exec. Processo que ja esta rodando continua com o
# binario velho mapeado; sessao NOVA pega o novo. A troca e GRADUAL e nao
# precisa de bounce (a receita ga-hdfbux diz o mesmo: "gradual symlink swap —
# don't force a city restart"). Isso e o oposto do caso do tmux, onde o
# servidor precisava sair inteiro.
set -uo pipefail

SRC=/Users/athos/gt/.local-patches/_src-hookfix

# A JANELA E PARAMETRIZAVEL DE PROPOSITO (Mayor, 05/09). Antes estes quatro
# valores eram fixos e apontavam para a janela de 29/08. Em 05/09 eu fui rodar
# a janela e o check passou: a branch existia, a base continha o commit do
# binario vivo, o preflight rodou. Nada acusou nada — mas buildar aquilo teria
# reconstruido o que JA estava no ar, sem NENHUM dos 9 patches pendentes, e o
# unico sinal disso era o "20260829" no meio do script, que ninguem le.
# Script que precisa ser EDITADO a cada uso envelhece calado; com override por
# env, a janela nova e um argumento, nao um commit.
#   ENGINE_WINDOW=20260906 engine-window-run.sh build
# O default aponta para a janela CORRENTE — atualize-o ao consolidar uma nova.
ENGINE_WINDOW="${ENGINE_WINDOW:-20260906}"
BRANCH="${ENGINE_WINDOW_BRANCH:-consolidated/engine-window-$ENGINE_WINDOW}"
WORKTREE="${ENGINE_WINDOW_WORKTREE:-/Users/athos/gt/.gc-worktrees/engine-window-${ENGINE_WINDOW#2026}}"
LIBEXEC="$HOME/.local/libexec"
LABEL="${ENGINE_WINDOW_LABEL:-gc-1.1.1-engwin${ENGINE_WINDOW#2026}}"
TAG="${ENGINE_WINDOW_TAG:-engwin-$ENGINE_WINDOW}"
SYMLINK=/opt/homebrew/bin/gc
PREV_FILE="$HOME/.gastown/run/engine-window-prev-target"
LOG=/Users/athos/gt/.gascity-gastown-hq/.gc/logs/engine-window-run.log
PREFLIGHT=/Users/athos/gt/.gascity-gastown-hq/scripts/engine-build-preflight.sh

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
die() { log "ABORTADO: $*"; exit 1; }

ensure_worktree() {
  # Idioma seguro: git worktree remove (casa Bash(git:*), nao dispara o prompt
  # de aprovacao de Bash(rm -rf:*)) e limpa o REGISTRO, nao so os arquivos.
  if [ ! -d "$WORKTREE" ]; then
    git -C "$SRC" worktree remove --force "$WORKTREE" 2>/dev/null || true
    git -C "$SRC" worktree add --force "$WORKTREE" "$BRANCH" >/dev/null 2>&1 \
      || die "nao consegui criar worktree de $BRANCH"
    log "worktree criado: $WORKTREE ($BRANCH)"
  fi
}

phase_check() {
  log "=== CHECK (read-only) ==="
  local rc=0

  # 1. A branch existe e aponta pro que esperamos?
  local head; head=$(git -C "$SRC" rev-parse --short "$BRANCH" 2>/dev/null) \
    || { log "  branch ....... $BRANCH AUSENTE"; rc=1; }
  [ -n "${head:-}" ] && log "  branch ....... $BRANCH @ $head"

  # 2. A base e mesmo o commit do binario VIVO? Este e o check que impede a
  #    regressao que ja aconteceu uma vez (o vendor bump beads v1.1.0 evaporou
  #    quando alguem rebuildou da linhagem 'oficial' — ga-hdfbux/ga-9ae7o).
  local live_commit; live_commit=$(git -C "$SRC" rev-parse --short bbf90542c 2>/dev/null)
  if git -C "$SRC" merge-base --is-ancestor bbf90542c "$BRANCH" 2>/dev/null; then
    log "  base ......... OK — contem $live_commit (binario vivo hoje)"
  else
    log "  base ......... FALHOU — $BRANCH NAO contem o commit do binario vivo."
    log "                 Buildar assim REGREDIRIA o vendor beads v1.1.0 da cidade."
    rc=1
  fi

  # 3. Toolchain: go.mod pede uma versao que pode nao ser a instalada.
  local want have
  want=$(awk '/^go /{print $2; exit}' "$SRC/go.mod" 2>/dev/null)
  have=$(go version 2>/dev/null | awk '{print $3}' | sed 's/^go//')
  if [ -d "$HOME/go/pkg/mod/golang.org/toolchain@v0.0.1-go${want}.darwin-arm64" ]; then
    log "  toolchain .... OK — go.mod quer $want, ja baixado (build funciona offline)"
  elif [ "$want" = "$have" ]; then
    log "  toolchain .... OK — $have"
  else
    log "  toolchain .... ATENCAO — go.mod quer $want, local e $have e nao ha copia baixada."
    log "                 O build vai tentar BAIXAR o toolchain: precisa de rede."
  fi

  # 4. Recursos. Chama o preflight de verdade em vez de reimplementar as regras.
  if [ -x "$PREFLIGHT" ] || [ -f "$PREFLIGHT" ]; then
    log "  --- preflight de recursos ---"
    bash "$PREFLIGHT" 2>&1 | sed 's/^/  /' | tee -a "$LOG"
    # O preflight e somente-leitura e NAO aborta nada; a decisao e nossa.
    local swapfree
    swapfree=$(sysctl -n vm.swapusage 2>/dev/null | sed -n 's/.*free = \([0-9.]*\)M.*/\1/p')
    if [ -n "$swapfree" ] && [ "${swapfree%.*}" -lt 3072 ] 2>/dev/null; then
      # Logo apos um boot o swap total do macOS ainda e pequeno (1-2 swapfiles),
      # entao "free < 3GB" e o estado NORMAL de uma maquina recem-reiniciada —
      # exatamente o momento em que o post-boot roda. Reprovar por swap ai
      # mataria a janela toda vez, no unico momento em que o swap esta de fato
      # saudavel ("So o REBOOT devolve swap" — este proprio aviso). O piso de
      # 3GB so vale como reprovacao com a maquina de pe ha mais de 30min.
      local _boot_s _up_min=999
      _boot_s=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ *sec *= *\([0-9]*\).*/\1/p')
      [ -n "$_boot_s" ] && _up_min=$(( ($(date +%s) - _boot_s) / 60 ))
      if [ "$_up_min" -le 30 ]; then
        log "  swap livre ${swapfree%.*}MB < 3GB, mas uptime ${_up_min}min (boot recente):"
        log "  swap recem-zerado pelo reboot — nao reprova."
      else
        log "  ATENCAO: swap livre abaixo de 3GB. So o REBOOT devolve swap."
        log "  E o ganho do reboot expira rapido (medido 26/08: 1h40) — se for"
        log "  rebootar, builde IMEDIATAMENTE depois, nao por ultimo."
        rc=1
      fi
    fi
  else
    log "  preflight .... NAO ENCONTRADO em $PREFLIGHT (nao consegui medir recursos)"
    rc=1
  fi

  log "  binario vivo agora: $(readlink "$SYMLINK" 2>/dev/null || echo '?')"
  if [ "$rc" -eq 0 ]; then
    log "VEREDITO: pronto pra 'build'."
  else
    log "VEREDITO: NAO recomendado agora (ver ATENCAO/FALHOU acima)."
    log "          'build --force' existe, mas so use sabendo o porque."
  fi
  return "$rc"
}

phase_build() {
  if [ "${2:-}" != "--force" ] && [ "${1:-}" != "--force" ]; then
    phase_check || die "check reprovou. Use 'build --force' se for deliberado."
  else
    log "--force: pulando o veredito do check (deliberado)."
    phase_check || true
  fi
  ensure_worktree
  log "=== BUILD ==="
  # Tag pra o binario se identificar em 'gc version' (o Makefile deriva VERSION
  # de git describe --tags --exact-match; sem tag ele reporta 'dev', que e
  # indistinguivel de qualquer outro build local).
  git -C "$WORKTREE" tag -f "$TAG" >/dev/null 2>&1 || true
  mkdir -p "$LIBEXEC"
  local out="$LIBEXEC/$LABEL"
  log "compilando -> $out (pode demorar; GOCACHE quente ajuda)"
  ( cd "$WORKTREE" && make build BUILD_DIR="$LIBEXEC" BINARY="$LABEL" ) 2>&1 | tail -20 | tee -a "$LOG"
  [ -x "$out" ] || die "build nao produziu binario executavel em $out"
  log "build OK: $(ls -la "$out" | awk '{print $5" bytes"}')"
  # Prova de vida: o binario novo tem que RODAR antes de ser candidato a swap.
  if "$out" version >/dev/null 2>&1; then
    log "prova de vida OK: '$LABEL version' respondeu"
    log "  reporta: $("$out" version 2>&1 | head -2 | tr '\n' ' ')"
  else
    die "o binario buildou mas NAO RODA ('$out version' falhou). Nao vou trocar nada."
  fi
  log "PRONTO. Nada foi trocado ainda — rode 'swap' quando quiser expor a cidade."
}

phase_swap() {
  local out="$LIBEXEC/$LABEL"
  [ -x "$out" ] || die "nao existe $out — rode 'build' primeiro."
  "$out" version >/dev/null 2>&1 || die "$out nao roda. Nao vou trocar."
  local prev; prev=$(readlink "$SYMLINK" 2>/dev/null) || die "nao consegui ler $SYMLINK"
  mkdir -p "$(dirname "$PREV_FILE")"
  printf '%s\n' "$prev" > "$PREV_FILE"
  log "=== SWAP ==="
  log "  de : $prev"
  log "  pra: $out"
  ln -sfn "$out" "$SYMLINK" || die "falhou ao trocar o symlink"
  local now; now=$(readlink "$SYMLINK")
  [ "$now" = "$out" ] || die "symlink nao ficou como esperado (esta: $now)"
  log "swap OK. Anterior guardado em $PREV_FILE (rollback disponivel)."
  log "A troca e GRADUAL: sessoes ja rodando seguem no binario velho; sessoes"
  log "novas pegam o novo. Nao e preciso derrubar a cidade."
  command -v notify >/dev/null 2>&1 && notify -t 'Engine window: swap feito' \
    "gc agora aponta pra $LABEL. Rollback: engine-window-run.sh rollback"
}

phase_rollback() {
  [ -f "$PREV_FILE" ] || die "nao ha alvo anterior gravado em $PREV_FILE"
  local prev; prev=$(cat "$PREV_FILE")
  [ -x "$prev" ] || die "o binario anterior ($prev) nao existe mais"
  log "=== ROLLBACK -> $prev ==="
  ln -sfn "$prev" "$SYMLINK" || die "falhou ao restaurar"
  log "rollback OK: $(readlink "$SYMLINK")"
}


# ─────────────────────────────────────────────────────────────────────────────
# FASE 2 — o que roda SOZINHO depois do reboot.
#
# POR QUE DUAS FASES: o reboot mata quem o disparou. Um "reboot && build" numa
# linha so nunca chega no build. Entao a fase 1 ARMA um job do launchd que
# dispara no proximo boot, e a fase 2 e esse job.
#
# POR QUE EU NAO REBOOTO: reiniciar a maquina e ato do Athos, nao meu (guardrail
# permanente: nada de restart da cidade sem avisar antes). O 'arm' valida, arma e
# PARA — quem aperta o botao e ele.
# ─────────────────────────────────────────────────────────────────────────────
PLIST="$HOME/Library/LaunchAgents/com.gascity.engine-window-postboot.plist"
LABEL_PLIST="com.gascity.engine-window-postboot"

phase_arm() {
  phase_check || log "AVISO: check reprovou (esperado se o swap ainda nao foi devolvido — o reboot resolve isso). Armando mesmo assim."
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL_PLIST</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$(cd "$(dirname "$0")" && pwd)/$(basename "$0")</string>
    <string>post-boot</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
PLISTEOF
  # NAO carregamos aqui de proposito. RunAtLoad dispara no LOAD, e um
  # bootstrap agora faria o build rodar NA HORA, no meio do dia (medido:
  # aconteceu na primeira versao deste script, 17:33 — o guard de recursos
  # barrou o build, mas o job nunca deveria ter disparado). Deixar o plist
  # no diretorio basta: o launchd carrega no proximo login/boot, e e ai que
  # o RunAtLoad deve disparar.
  [ -f "$PLIST" ] || die "nao consegui escrever o plist"
  log "=== ARMADO ==="
  log "  O build vai rodar SOZINHO no proximo boot e trocar o binario se passar."
  log "  Resultado + rollback: $LOG"
  log ""
  log "  AGORA E COM VOCE: reinicie a maquina quando quiser."
  log "  Pra desarmar sem reiniciar: $(basename "$0") disarm"
}

phase_disarm() {
  launchctl bootout "gui/$(id -u)/$LABEL_PLIST" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST" 2>/dev/null
  log "DESARMADO — nada vai rodar no proximo boot."
}

disarm_file_only() {
  # So remove o arquivo do plist — NUNCA chame launchctl bootout/unload daqui.
  # Medido ao vivo (ga-i64v6, 29/08): quando phase_post_boot roda como a
  # instancia REAL que o launchd carregou via RunAtLoad, um bootout do PROPRIO
  # label mata este processo na hora — launchd nao distingue "pedido por mim
  # mesmo" de "pedido por outro processo", e a remocao do servico saiu no log
  # unificado no MESMO milissegundo do trigger, antes de chegar em "DESARMADO"
  # ou no build. (O disarm manual via 'engine-window-run.sh disarm' nao tem
  # este risco — quem chama nao e a instancia rodando sob o job, entao
  # phase_disarm com bootout continua correto e util la, inclusive como
  # cancelamento forcado de um post-boot em andamento.) Apagar o arquivo basta
  # para o efeito que post-boot precisa: RunAtLoad so dispara se o plist
  # existir no proximo login/boot.
  rm -f "$PLIST" 2>/dev/null
  log "DESARMADO (arquivo removido) — nada vai rodar no proximo boot."
}

phase_post_boot() {
  # Guarda: so rode se a maquina REALMENTE acabou de bootar. Sem isto, um
  # load manual do plist dispara um build pesado no meio do expediente.
  local boot_s now_s up_min
  boot_s=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ *sec *= *\([0-9]*\).*/\1/p')
  now_s=$(date +%s)
  if [ -n "$boot_s" ]; then
    up_min=$(( (now_s - boot_s) / 60 ))
    if [ "$up_min" -gt 30 ]; then
      log "POS-BOOT RECUSADO: maquina de pe ha ${up_min}min (>30). Isto nao e um boot recente."
      disarm_file_only
      return 0
    fi
  else
    log "POS-BOOT RECUSADO: nao consegui ler kern.boottime — sob duvida, nao rodo."
    disarm_file_only; return 0
  fi
  log "=== POS-BOOT: janela do engine disparou (uptime ${up_min}min) ==="
  # Desarma PRIMEIRO. Se o build travar, o job nao pode disparar de novo no
  # boot seguinte — um job que se re-arma sozinho e como o guard que virou a
  # carga que deveria observar. So o arquivo — nunca phase_disarm (bootout)
  # aqui: esta funcao roda COMO a instancia que o launchd carregou, e um
  # bootout do proprio label mata este processo na hora (ver disarm_file_only).
  disarm_file_only
  # A cidade sobe pelo supervisor; da tempo dela assentar antes de competir por CPU.
  local waited=0
  while [ "$waited" -lt 300 ]; do
    pgrep -f 'gc supervisor run' >/dev/null 2>&1 && break
    sleep 15; waited=$((waited+15))
  done
  log "supervisor visivel apos ${waited}s (ou timeout) — seguindo"
  sleep 60   # deixa o swap/IO do boot assentar antes de medir recursos
  phase_build || { log "BUILD FALHOU — NADA foi trocado. Binario atual intacto."; \
    command -v notify >/dev/null 2>&1 && notify -p 4 -t 'Janela do engine FALHOU' "build nao passou; nada trocado. Ver $LOG"; return 1; }
  phase_swap  || { log "SWAP FALHOU — binario atual intacto."; return 1; }
  log "=== JANELA CONCLUIDA COM SUCESSO ==="
  command -v notify >/dev/null 2>&1 && notify -t 'Janela do engine OK' \
    "engine trocado pro build novo e verificado. Rollback: engine-window-run.sh rollback"
}

mkdir -p "$(dirname "$LOG")"
case "${1:-check}" in
  check)    phase_check ;;
  build)    phase_build "$@" ;;
  swap)     phase_swap ;;
  rollback)  phase_rollback ;;
  arm)       phase_arm ;;
  disarm)    phase_disarm ;;
  post-boot) phase_post_boot ;;
  *) echo "uso: $(basename "$0") [check|build|swap|rollback|arm|disarm]"; exit 2 ;;
esac
