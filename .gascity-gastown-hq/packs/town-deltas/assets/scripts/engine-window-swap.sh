#!/usr/bin/env bash
# engine-window-swap.sh — instala um binário `gc` recém-buildado e troca o
# symlink vivo com as verificações na ORDEM certa (verifica antes de publicar,
# nunca sobrescreve binário em uso, confirma que o supervisor subiu no binário
# novo) e REPORTA o crash-loop conhecido do supervisor em vez de escondê-lo.
# Ele não evita esse crash — ver "CAUSA" abaixo; evitá-lo ainda é problema em
# aberto (ga-6nnzt).
#
# ga-6nnzt (2026-08-29): os 3 swaps daquele dia (engwin0829, -0829b, -0829c)
# derrubaram o supervisor uma vez cada, sempre com a MESMA assinatura:
#   exception:   EXC_CRASH / SIGKILL (Code Signature Invalid)
#   termination: namespace CODESIGNING, indicator "Launch Constraint Violation"
#   morte em ~120k-170k abs-ticks após procLaunch (morto na largada, não em runtime)
# O launchd relançava por KeepAlive-on-Crashed e a 2ª tentativa pegava, então
# não houve apagão — mas cada retry custa ~17s de supervisor fora do ar, e
# qualquer request vivo nessa janela falha (foi assim que ga-64nv6 apareceu).
#
# CAUSA — AINDA NÃO RESOLVIDA. Leia isto antes de "consertar":
#
# A primeira hipótese era a assinatura: `go build` no arm64 macOS entrega o
# binário assinado pelo LINKER (flags=0x20002 adhoc,linker-signed,
# Identifier=a.out), e todo build sai com o MESMO Identifier e CDHash novo no
# mesmo caminho registrado no launchd. Parecia a colisão óbvia.
#
# ISSO FOI TESTADO E FALSIFICADO (2026-08-29 17:16). Re-assinei com
# `codesign -f -s -` antes de publicar — a assinatura virou flags=0x2(adhoc)
# com Identifier próprio (gc-1.1.1-engwin0829d, não mais a.out), `codesign -v`
# passou, o binário executou à mão — e o supervisor crashou EXATAMENTE igual:
#   gc-1.1.1-engwin0829d-2026-08-29-171610.ips
#   SIGKILL (Code Signature Invalid) / CODESIGNING / Launch Constraint Violation
# Ou seja: o flag linker-signed era pista falsa. O codesign continua neste
# script porque é barato e deixa a identidade limpa, mas NÃO é o remédio e não
# deve ser descrito como tal.
#
# O QUE O EXPERIMENTO DE CONTROLE MOSTROU (é daqui que a próxima pessoa parte):
# um `launchctl kickstart -k` no MESMO binário, sem escrever arquivo nenhum,
# NÃO crasha (medido logo depois: contagem de .ips ficou em 6, inalterada).
# Então o gatilho não é o kickstart, não é o tipo de assinatura e não é "o
# primeiro exec do arquivo" — o script já executa o binário à mão antes de
# publicar e ainda assim acontece. O gatilho é especificamente o launchd
# executar, sob launch constraints, um binário que MUDOU desde o último
# bootstrap daquele serviço. A suspeita restante (NÃO verificada) é o cache de
# launch constraint do serviço no launchd; o próximo passo natural seria testar
# `launchctl bootout` + `bootstrap` no lugar do kickstart — o que eu não fiz
# porque um bootstrap que falhe deixa o supervisor fora do ar, e isso é bem
# pior que 17s de retry.
#
# Até lá, o comportamento é: crasha 1x, o launchd relança por
# KeepAlive-on-Crashed, sobe. Este script NÃO evita isso — ele TORNA VISÍVEL
# (passo 6) para ninguém declarar swap limpo quando não foi.
#
# Uso:
#   engine-window-swap.sh <binario-buildado> <nome-do-alvo>
# Ex.:
#   engine-window-swap.sh /tmp/gc-novo gc-1.1.1-engwin0830
set -euo pipefail

SRC="${1:?uso: engine-window-swap.sh <binario-buildado> <nome-do-alvo>}"
NAME="${2:?uso: engine-window-swap.sh <binario-buildado> <nome-do-alvo>}"

LIBEXEC="${GC_LIBEXEC_DIR:-$HOME/.local/libexec}"
LINK="${GC_BIN_LINK:-/opt/homebrew/bin/gc}"
LABEL="${GC_SUPERVISOR_LABEL:-com.gascity.supervisor}"
DEST="$LIBEXEC/$NAME"

log() { printf '[engine-window-swap] %s\n' "$*"; }
die() { printf '[engine-window-swap] ERRO: %s\n' "$*" >&2; exit 1; }

[ -f "$SRC" ] || die "binário de origem não existe: $SRC"
[ -d "$LIBEXEC" ] || die "libexec não existe: $LIBEXEC"
[ -e "$DEST" ] && die "$DEST já existe — escolha outro nome, nunca sobrescreva um binário que pode estar em uso"

PREV="$(readlink -f "$LINK" 2>/dev/null || true)"
log "symlink atual -> ${PREV:-<nenhum>}"

# 1. instala
install -m 0755 "$SRC" "$DEST"
log "instalado: $DEST ($(wc -c <"$DEST" | tr -d ' ') bytes)"

# 2. re-assina. NÃO evita o crash (falsificado — ver cabeçalho); mantido por ser
#    barato e por dar identidade própria a cada versão em vez de `a.out`.
before="$(codesign -dvvv "$DEST" 2>&1 | grep -oE 'flags=0x[0-9a-f]+\([^)]*\)' | head -1 || true)"
codesign -f -s - "$DEST" 2>/dev/null || die "codesign falhou em $DEST"
after="$(codesign -dvvv "$DEST" 2>&1 | grep -oE 'flags=0x[0-9a-f]+\([^)]*\)' | head -1 || true)"
log "assinatura: ${before:-?} -> ${after:-?}"
case "$after" in
  *linker-signed*) die "ainda linker-signed depois do codesign — NÃO trocando o symlink" ;;
esac

# 3. verifica ANTES de publicar. Um binário que não roda não pode virar o gc vivo.
codesign -v "$DEST" 2>/dev/null || die "codesign -v reprovou $DEST"
"$DEST" --help >/dev/null 2>&1 || die "$DEST não executa (--help falhou)"
log "verificado: assinatura válida + executa"

# 4. troca o symlink
ln -sfn "$DEST" "$LINK"
log "symlink -> $(readlink -f "$LINK")"

# 5. reinicia o supervisor
uid="$(id -u)"
launchctl kickstart -k "gui/$uid/$LABEL" || die "kickstart falhou"
log "kickstart enviado para $LABEL"

# 6. confirma que subiu NO BINÁRIO NOVO — e que não entrou em crash-loop.
#    O bug original se auto-resolvia no retry, então "está de pé" não basta:
#    tem que estar de pé E sem crash report novo.
ok=0
for _ in $(seq 1 20); do
  sleep 2
  pid="$(launchctl print "gui/$uid/$LABEL" 2>/dev/null | awk '/^\tpid =/{print $3}')"
  [ -n "${pid:-}" ] || continue
  live="$(lsof -p "$pid" 2>/dev/null | awk '$4=="txt"{print $NF}' | grep -F "$DEST" | head -1 || true)"
  [ -n "$live" ] && { ok=1; break; }
done
[ "$ok" = 1 ] || die "supervisor não apareceu rodando $DEST — investigue antes de seguir"
log "supervisor pid=$pid rodando $DEST"

crash="$(find "$HOME/Library/Logs/DiagnosticReports" -name "$NAME-*.ips" -mmin -5 2>/dev/null | head -1 || true)"
if [ -n "$crash" ]; then
  log "ESPERADO (ga-6nnzt, ainda sem remédio): crash report novo -> $crash"
  log "       O supervisor subiu no retry do launchd; ~17s fora do ar. Isso NAO"
  log "       e falha deste swap nem motivo pra re-swapar — re-swapar so gera"
  log "       outro crash. Confira a assinatura do .ips: se for CODESIGNING /"
  log "       Launch Constraint Violation, e o mesmo problema conhecido."
else
  log "nenhum crash report novo — swap limpo"
fi

log "anterior: ${PREV:-<nenhum>} (mantido, rollback = ln -sfn <anterior> $LINK)"
