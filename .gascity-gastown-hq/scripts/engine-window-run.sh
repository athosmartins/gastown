#!/bin/bash
# engine-window-run.sh — janela do engine, pronta pra acionar (Mayor, 2026-08-26).
#
# PEDIDO DO ATHOS (26/08, verbatim): "eu so queria ter isso pronto pra, quando
# precisar, ser facil acionar". Por isso este script NAO agenda nada, NAO roda
# sozinho e NAO tem plist. Ele so existe pra ser chamado quando ele quiser.
#
# USO
#   engine-window-run.sh            # = check. Read-only. Nao muda nada.
#   engine-window-run.sh push       # empurra a branch da janela pro remoto e VERIFICA o efeito
#   engine-window-run.sh build      # push (acima) + builda; NAO troca o binario vivo
#   engine-window-run.sh swap       # exige backup verificado da fonte; troca o symlink;
#                                   # depois do swap OK, origin/main anda (so ff) ate o commit do binario
#   engine-window-run.sh advance-main # so este ultimo passo (refazer apos um aviso "NAO AVANCOU")
#   engine-window-run.sh rollback   # volta pro binario anterior
#
# A ORDEM E SEMPRE check -> push -> build -> swap ('build' e 'arm' ja fazem o
# push). Cada fase e separada de proposito: uma fase que builda E troca junto
# nao deixa voce inspecionar o resultado antes de expor a cidade a ele.
#
# POR QUE O PUSH FAZ PARTE DA JANELA (ga-ta2w6r, Mayor 20/09/2026)
# A branch consolidated/engine-window-20260919 ficou com 12 commits em NENHUM
# remoto (~20 patches de tres janelas) enquanto o binario que a cidade inteira
# roda foi compilado do topo dela. A janela consolidava, compilava e trocava sem
# nenhum passo que empurrasse a fonte: etapa ausente, nao esquecimento. Agora:
#   * push/build/arm: o worktree tem que estar LIMPO e exatamente no commit da
#     branch (senao o main.commit do binario nao descreve o que foi compilado);
#     se o commit ainda nao esta em nenhum remoto a branch e empurrada (sem
#     force) e o efeito e VERIFICADO antes de compilar (se ja esta, nada a fazer);
#   * swap: recusa se o commit que o binario declara nao esta em nenhum remoto.
# Bypass deliberado e barulhento (notify): ENGINE_WINDOW_SKIP_BACKUP_CHECK=1
# (ex.: GitHub fora do ar num P0). Rollback NUNCA e barrado: voltar pro binario
# anterior tem que ser sempre possivel. O detector horario que cobre o resto:
# packs/town-deltas/assets/scripts/engine-binary-backup-guard.sh.
#
# POR QUE O SWAP TAMBEM ANDA O origin/main (ga-z36a88: achado em 21/09; Mayor pediu o ff em 23/10/2026)
# origin/main do engine ficou 17 dias / 12 commits atras do que RODAVA na cidade (so a
# consolidated/engine-window-* tinha a verdade). Quem ramificasse de "main" -- a escolha
# obvia -- reverteria em silencio correcoes vivas: o build passa, o binario roda, so as
# correcoes somem. O swap e o instante em que "o que roda" muda; e nele que "o que e o
# main" muda junto. Regras: so fast-forward (nunca force; se divergiu, avisa e nao mexe);
# publica o commit que o BINARIO declara, nao a ponta da branch (se a branch andou depois
# do build, o main nao recebe commit que nunca foi compilado); falha aqui avisa (log +
# notify) mas nunca derruba o swap, que ja aconteceu; 'build', 'push' e 'rollback' nao mexem.
#
# POR QUE O SWAP NAO DERRUBA A CIDADE
# O SO resolve o symlink no exec. Processo que ja esta rodando continua com o
# binario velho mapeado; sessao NOVA pega o novo. A troca e GRADUAL e nao
# precisa de bounce (a receita ga-hdfbux diz o mesmo: "gradual symlink swap —
# don't force a city restart"). Isso e o oposto do caso do tmux, onde o
# servidor precisava sair inteiro.
set -uo pipefail

# O job pós-boot (launchd com.gascity.engine-window-postboot) roda com o PATH mínimo do launchd, sem /opt/homebrew/bin:
# o check passava (só olhava a pasta do toolchain) e o build morria em "make: go: Command not found" (11/10 23:43,
# ga-tp5hyj). Os dois lugares onde o go mora nesta máquina entram no PATH aqui, e o check confere o go de verdade.
export PATH="/opt/homebrew/bin:/usr/local/go/bin:$PATH"

# Os caminhos abaixo aceitam override por env (defaults INALTERADOS) so para o
# selftest poder rodar as fases num sandbox sem tocar no symlink vivo do gc.
SRC="${ENGINE_WINDOW_SRC:-/Users/athos/gt/.local-patches/_src-hookfix}"

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
ENGINE_WINDOW="${ENGINE_WINDOW:-20261011b}"
BRANCH="${ENGINE_WINDOW_BRANCH:-consolidated/engine-window-$ENGINE_WINDOW}"
WORKTREE="${ENGINE_WINDOW_WORKTREE:-/Users/athos/gt/.gc-worktrees/engine-window-${ENGINE_WINDOW#2026}}"
LIBEXEC="${ENGINE_WINDOW_LIBEXEC:-$HOME/.local/libexec}"
LABEL="${ENGINE_WINDOW_LABEL:-gc-1.1.1-engwin${ENGINE_WINDOW#2026}}"
TAG="${ENGINE_WINDOW_TAG:-engwin-$ENGINE_WINDOW}"
SYMLINK="${ENGINE_WINDOW_SYMLINK:-/opt/homebrew/bin/gc}"
PREV_FILE="${ENGINE_WINDOW_PREV_FILE:-$HOME/.gastown/run/engine-window-prev-target}"
LOG="${ENGINE_WINDOW_LOG:-/Users/athos/gt/.gascity-gastown-hq/.gc/logs/engine-window-run.log}"
PREFLIGHT="${ENGINE_WINDOW_PREFLIGHT:-/Users/athos/gt/.gascity-gastown-hq/scripts/engine-build-preflight.sh}"
PUSH_REMOTE="${ENGINE_WINDOW_PUSH_REMOTE:-origin}"
MAIN_BRANCH="${ENGINE_WINDOW_MAIN_BRANCH:-main}"   # ga-z36a88: a branch do remoto que o swap anda (so ff)

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
die() { log "ABORTADO: $*"; exit 1; }

# ga-ta2w6r: lib compartilhada com engine-window-swap.sh e com o guard horario.
# Mora no pack (packs/town-deltas/assets/scripts/lib/) porque os outros dois
# moram la; este script mora em scripts/, entao o caminho sai do PROPRIO local.
# Sem a lib nao ha como provar backup: recusa em vez de seguir sem o gate.
EB_LIB="${ENGINE_BACKUP_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../packs/town-deltas/assets/scripts/lib/engine-backup-lib.sh}"
[ -f "$EB_LIB" ] || { echo "ABORTADO: lib de backup ausente: $EB_LIB (ga-ta2w6r)" >&2; exit 1; }
# shellcheck source=/dev/null
. "$EB_LIB"
EB_LOG=log   # as mensagens da lib entram no mesmo log da janela

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

# ga-ta2w6r: a fonte do que vai rodar tem que existir FORA deste disco ANTES de o
# binario existir. So retorna 0 com o EFEITO verificado (eb_push_branch faz um
# fetch novo e procura o commit num remoto: o rc=0 do `git push` nao basta).
# Antes disso o worktree tem que ser EXATAMENTE o commit que sera empurrado -- o
# `main.commit` do binario so descreve o que foi compilado se conteudo == commit.
# Nunca faz force-push: historia divergente no remoto e decisao de humano.
ensure_backed_up() {
  if [ "${ENGINE_WINDOW_SKIP_BACKUP_CHECK:-0}" = "1" ]; then
    log "!!! PUSH/BACKUP IGNORADO (ENGINE_WINDOW_SKIP_BACKUP_CHECK=1 -- bypass deliberado)"
    command -v notify >/dev/null 2>&1 && notify -p 4 -t 'Engine window: push/backup IGNORADO' \
      "janela $ENGINE_WINDOW segue sem provar que a fonte tem backup (bypass deliberado)" >/dev/null 2>&1
    return 0
  fi
  ensure_worktree
  local tip head dirty st
  tip=$(git -C "$WORKTREE" rev-parse --verify --quiet "refs/heads/${BRANCH}^{commit}" 2>/dev/null) \
    || { log "  backup ....... FALHOU: a branch $BRANCH nao existe"; return 1; }
  head=$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null) \
    || { log "  backup ....... FALHOU: nao consegui ler o HEAD de $WORKTREE"; return 1; }
  if [ "$head" != "$tip" ]; then
    log "  backup ....... FALHOU: $WORKTREE esta em $(printf '%.9s' "$head") mas $BRANCH aponta pra $(printf '%.9s' "$tip") -- o build compilaria algo diferente do que seria empurrado."
    return 1
  fi
  dirty=$(git -C "$WORKTREE" status --porcelain --untracked-files=no 2>/dev/null) \
    || { log "  backup ....... FALHOU: nao consegui ler o estado de $WORKTREE"; return 1; }
  if [ -n "$dirty" ]; then
    log "  backup ....... FALHOU: $WORKTREE tem mudancas nao-commitadas (o binario carregaria conteudo que nenhum commit descreve):"
    printf '%s\n' "$dirty" | sed -n '1,5p' | sed 's/^/                   /' | tee -a "$LOG"
    return 1
  fi
  # Ja esta num remoto? Entao nao ha o que empurrar. Isso torna o passo idempotente
  # E tira a rede do caminho do pos-boot quando o 'arm' (com humano por perto) ja
  # empurrou: um boot sem rede nao desperdica o reboot -- a evidencia positiva de
  # um fetch anterior vale (marcada "velhas" se ESTE fetch falhou). O que nunca
  # passa e commit sem evidencia nenhuma: esse cai no push abaixo, ou falha.
  eb_fetch_all "$WORKTREE"
  st=$(eb_backup_state "$WORKTREE" "$tip")
  case "$st" in
    OK\|*)
      log "  backup ....... OK -- $BRANCH @ $(printf '%.9s' "$tip") ja esta em ${st#*|}; nada a empurrar."
      return 0
      ;;
  esac
  log "  backup ....... empurrando $BRANCH ($(printf '%.9s' "$tip")) para $PUSH_REMOTE..."
  eb_push_branch "$WORKTREE" "$BRANCH" "$PUSH_REMOTE" \
    || { log "  backup ....... FALHOU (ver o push acima) -- nada sera buildado."; return 1; }
  log "  backup ....... OK -- $BRANCH esta em $PUSH_REMOTE."
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
  if ! command -v go >/dev/null 2>&1 || [ -z "$have" ]; then
    log "  toolchain .... FALHOU — nao ha 'go' executavel no PATH ($PATH); o build nao roda."
    rc=1
  elif [ -d "$HOME/go/pkg/mod/golang.org/toolchain@v0.0.1-go${want}.darwin-arm64" ]; then
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

  # 5. Backup da fonte (ga-ta2w6r). So LE -- sem fetch e sem push ('push'/'build'
  #    empurram) --, por isso e informativo e nao entra no rc: quem conserta e a
  #    fase seguinte, e reprovar o check por algo que o build resolve so criaria
  #    atrito (e pioraria o 'arm', que aceita check reprovado de proposito).
  if [ -n "${head:-}" ]; then
    local _bk
    EB_NO_FETCH=1 eb_fetch_all "$SRC"
    _bk=$(eb_backup_state "$SRC" "$BRANCH")
    case "$_bk" in
      OK\|*) log "  backup ....... OK (so refs locais, sem fetch) — ${_bk#*|}" ;;
      *)     log "  backup ....... PENDENTE — nenhum ref remoto LOCAL contem $BRANCH (${_bk#*|}). O check nao faz fetch e por isso nao afirma mais que isso; 'push'/'build' verificam de verdade e empurram." ;;
    esac
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
  log "=== PUSH (o backup da fonte vem ANTES do build) ==="
  ensure_backed_up || { log "BUILD NAO INICIADO: sem backup verificado da fonte nada e compilado (ga-ta2w6r). Nada foi buildado nem trocado."; return 1; }
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

# ga-z36a88: aviso de que origin/main NAO andou. Log + notify: se o aviso so ficasse no log, o main
# voltaria a envelhecer calado -- que e exatamente o defeito que este passo existe pra acabar.
# Sempre retorna 1, pra quem chama poder fazer `|| { main_ff_warn ...; return 1; }` numa linha so.
# O veredito e "NAO AVANCOU" (sabemos que nao andou) ou, so quando o push saiu mas o efeito nao foi
# confirmado, "NAO CONFIRMADO" (o main PODE ter andado): quem chama escolhe por MAIN_FF_VERDICT=... main_ff_warn.
main_ff_warn() {
  local verdict="${MAIN_FF_VERDICT:-NAO AVANCOU}"
  log "  origin/main .. $verdict: $*"
  log "                 Nada foi forcado nem apagado. Depois de resolver, refaca so este passo: $(basename "$0") advance-main"
  command -v notify >/dev/null 2>&1 && notify -t "Engine window: origin/main $verdict" \
    "$* -- refazer: engine-window-run.sh advance-main" >/dev/null 2>&1
  return 1
}

# ga-z36a88: anda origin/main do engine (so fast-forward) ate o commit que o binario <bin> declara no
# PROPRIO stamp (main.commit). Ver "POR QUE O SWAP TAMBEM ANDA O origin/main" no topo.
# Cada leitura tem TRES estados (tem / nao-tem / nao-consegui-saber) e so "tem, provado" empurra:
# o resto avisa e deixa tudo como esta. O push e UMA tentativa sem retry: falhar aqui e barato e
# refazivel com `advance-main`, e um retry com sleep seguraria o post-boot atras de uma rede ruim.
# rc 0 = main ja estava nesse commit (ou a frente dele), ou AVANCOU com o efeito verificado; rc 1 = nao andou.
advance_origin_main() {
  local bin="$1" remote="$PUSH_REMOTE" mbranch="$MAIN_BRANCH" stamp target main_tip old_s out rc
  log "=== ORIGIN/MAIN (fast-forward ate o commit que o binario carrega) ==="

  # vazio → binario sem commit no stamp: nao ha o que publicar, avisa e nao mexe; falhou/ilegivel → idem (eb_binary_commit devolve rc=1 nos dois)
  stamp=$(eb_binary_commit "$bin" gc) \
    || { main_ff_warn "o binario $bin nao traz commit no stamp (main.commit) -- nao sei o que publicar."; return 1; }

  # vazio → o commit do stamp nao existe em $SRC: avisa e nao mexe; falhou/ilegivel → idem (rev-parse nao distingue, os dois ficam inertes)
  target=$(git -C "$SRC" rev-parse --verify --quiet "${stamp}^{commit}" 2>/dev/null) || target=""
  [ -n "$target" ] \
    || { main_ff_warn "o commit do binario ($stamp) nao resolve em $SRC (ausente, ambiguo ou repo ilegivel)."; return 1; }

  # So publica o que a branch da janela tem. tem (rc 0) segue; nao-tem (rc 1) recusa; nao-sei (outro rc, ex.: branch ausente) recusa.
  git -C "$SRC" merge-base --is-ancestor "$target" "refs/heads/$BRANCH" 2>/dev/null; rc=$?
  case "$rc" in
    0) ;;
    1) main_ff_warn "o commit do binario ($(printf '%.9s' "$target")) NAO esta em $BRANCH -- nao publico no main algo que a branch da janela nao tem."
       return 1 ;;
    *) main_ff_warn "nao consegui comparar o commit do binario com $BRANCH (rc=$rc; a branch existe em $SRC?)."
       return 1 ;;
  esac

  # Visao FRESCA do remoto, so do remote do push: so fetch "ok" vale; falhou → nao sei o estado do main → nao empurro.
  EB_REMOTES="$remote" eb_fetch_all "$SRC"
  [ "$EB_FETCH_STATE" = "ok" ] \
    || { main_ff_warn "nao consegui ler $remote agora (${EB_FETCH_NOTE:-fetch nao executado}) -- sem visao fresca de $mbranch nao empurro."; return 1; }

  # vazio → depois de um fetch ok, $remote nao tem a branch $mbranch: nao crio (criar branch e decisao de humano); falhou/ilegivel → idem
  main_tip=$(git -C "$SRC" rev-parse --verify --quiet "refs/remotes/$remote/${mbranch}^{commit}" 2>/dev/null) || main_tip=""
  [ -n "$main_tip" ] \
    || { main_ff_warn "$remote nao tem a branch $mbranch (ou nao consegui le-la): nao crio branch -- isso e decisao de humano."; return 1; }
  old_s=$(printf '%.9s' "$main_tip")

  if [ "$main_tip" = "$target" ]; then
    log "  origin/main .. OK -- $remote/$mbranch ja esta em $(printf '%.9s' "$target") (nada a empurrar)."
    return 0
  fi
  # main ja CONTEM o commit do binario (main esta a frente) nao e erro e NAO recua. rc 1 = nao contem; outro rc = nao sei.
  git -C "$SRC" merge-base --is-ancestor "$target" "$main_tip" 2>/dev/null; rc=$?
  case "$rc" in
    0) log "  origin/main .. OK -- $remote/$mbranch ($old_s) ja contem o commit do binario ($(printf '%.9s' "$target")); o main esta a frente, nao recuo."
       return 0 ;;
    1) ;;
    *) main_ff_warn "nao consegui comparar $remote/$mbranch com o commit do binario (rc=$rc)."
       return 1 ;;
  esac
  # fast-forward? tem (rc 0) empurra; nao-tem (rc 1) = divergiu; nao-sei (outro rc) recusa.
  git -C "$SRC" merge-base --is-ancestor "$main_tip" "$target" 2>/dev/null; rc=$?
  case "$rc" in
    0) ;;
    1) main_ff_warn "$remote/$mbranch ($old_s) divergiu do commit do binario ($(printf '%.9s' "$target")): nao e fast-forward e eu NAO forco -- um humano decide (reconciliar ou refazer a janela sobre o main)."
       return 1 ;;
    *) main_ff_warn "nao consegui comparar $remote/$mbranch com o commit do binario (rc=$rc)."
       return 1 ;;
  esac

  log "  origin/main .. empurrando $(printf '%.9s' "$target") -> $remote/$mbranch (so fast-forward, sem force)..."
  out=$(eb_bounded "$EB_PUSH_TIMEOUT_S" env GIT_TERMINAL_PROMPT=0 \
    git -C "$SRC" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 \
    push "$remote" "${target}:refs/heads/${mbranch}" 2>&1) && rc=0 || rc=$?
  [ "$rc" = "0" ] \
    || { main_ff_warn "o push para $remote/$mbranch falhou (rc=$rc; remoto rejeitou ou sem rede): $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; return 1; }

  # O EFEITO, nao o rc do push: um fetch novo tem que mostrar o main no commit (ou a frente dele).
  # vazio/falhou → nao confirmo: avisa em vez de declarar sucesso.
  EB_REMOTES="$remote" eb_fetch_all "$SRC"
  main_tip=$(git -C "$SRC" rev-parse --verify --quiet "refs/remotes/$remote/${mbranch}^{commit}" 2>/dev/null) || main_tip=""
  if [ "$EB_FETCH_STATE" = "ok" ] && [ -n "$main_tip" ] \
      && git -C "$SRC" merge-base --is-ancestor "$target" "$main_tip" 2>/dev/null; then
    log "  origin/main .. AVANCOU: $remote/$mbranch $old_s -> $(printf '%.9s' "$main_tip") (fast-forward, sem force)."
    return 0
  fi
  MAIN_FF_VERDICT="NAO CONFIRMADO" main_ff_warn "o push retornou 0 mas depois dele nao consegui confirmar $remote/$mbranch em $(printf '%.9s' "$target") (main: ${main_tip:-?}; fetch: ${EB_FETCH_STATE:-?}) -- o main PODE ter andado; confira com 'git -C $SRC ls-remote $remote $mbranch'. Nao dou como feito."
  return 1
}

# ga-z36a88: o passo acima, avulso, sobre o binario que esta NO AR agora (o alvo do symlink) -- pra refazer
# depois de um aviso "NAO AVANCOU" ou de um swap com ENGINE_WINDOW_SKIP_BACKUP_CHECK=1 sem rede.
phase_advance_main() {
  local live
  # vazio/falhou → nao sei qual binario esta no ar: avisa e nao mexe (publicar sem saber o que roda e o defeito original).
  live=$(readlink "$SYMLINK" 2>/dev/null) || live=""
  [ -n "$live" ] \
    || { main_ff_warn "nao consegui ler $SYMLINK -- sem saber qual binario esta no ar nao publico nada."; return 1; }
  advance_origin_main "$live"
}

phase_swap() {
  local out="$LIBEXEC/$LABEL"
  [ -x "$out" ] || die "nao existe $out — rode 'build' primeiro."
  "$out" version >/dev/null 2>&1 || die "$out nao roda. Nao vou trocar."
  # ga-ta2w6r: nunca expor a cidade a um binario cuja fonte so existe neste disco.
  # O gate le o stamp do PROPRIO binario (main.commit), nao a branch: pega tambem
  # o caso do binario ter sido compilado de outro worktree/branch.
  eb_require_backed_up "$out" "$SRC" gc "$LABEL" \
    || { log "SWAP RECUSADO -- o symlink NAO foi tocado (motivo acima)."; return 1; }
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
  # ga-z36a88: o swap JA aconteceu. Daqui pra baixo, falha de ff do origin/main avisa (log + notify, dentro da
  # funcao) e NUNCA vira falha do swap. O `return 0` e explicito de proposito: o rc do swap deixa de depender do
  # ultimo comando (antes era o `command -v notify`, que da 1 sem notify instalado e fazia o post-boot logar
  # "SWAP FALHOU" depois de um swap que deu certo).
  advance_origin_main "$out" || true
  return 0
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
  # ga-ta2w6r: o push acontece AGORA, com humano por perto e rede de pe -- nao no
  # pos-boot, onde uma falha de rede desperdicaria o reboot (o ganho expira em
  # ~1h40). Sem backup verificado nao se arma.
  ensure_backed_up || die "nao armo: a fonte da janela nao tem backup verificado (motivo acima). Resolva e arme de novo (ou ENGINE_WINDOW_SKIP_BACKUP_CHECK=1, deliberadamente)."
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
  push)     log "=== PUSH ==="; ensure_backed_up ;;
  build)    phase_build "$@" ;;
  swap)     phase_swap ;;
  advance-main) phase_advance_main ;;
  rollback)  phase_rollback ;;
  arm)       phase_arm ;;
  disarm)    phase_disarm ;;
  post-boot) phase_post_boot ;;
  *) echo "uso: $(basename "$0") [check|push|build|swap|advance-main|rollback|arm|disarm]"; exit 2 ;;
esac
