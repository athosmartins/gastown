#!/usr/bin/env bash
# binary-swap.sh — troca QUALQUER binário desta cidade (bd, gt, …) re-assinando
# no CAMINHO FINAL. Irmão do engine-window-swap.sh, que faz o mesmo para o gc.
#
# POR QUE EXISTE (2026-08-30, ga-poo7z): troquei o `bd` com um `cp` cru e ele
# passou a morrer com SIGKILL instantâneo — inclusive `bd --version`, que não
# toca banco nenhum. Perdi tempo diagnosticando "hang" porque `exit=137` é
# AMBÍGUO: timeout e SIGKILL de code signing dão o mesmo código.
#
#   ⏱️  O DISCRIMINADOR É O TEMPO DECORRIDO, e é de graça:
#         137 em ~0s        -> assinatura rejeitada pelo SO
#         137 em N segundos -> timeout de verdade
#   Sem cronometrar, os dois são indistinguíveis e você diagnostica o errado.
#
# A assinatura ad-hoc é feita no caminho de BUILD; copiar para o caminho final
# cria um inode novo que o kernel rejeita. Re-assinar no destino resolve —
# medido: antes exit=137 em 0s, depois exit=0 em 1s.
#
# Uso: binary-swap.sh <binário-novo> <destino> [identifier]
#   binary-swap.sh ~/build/bd ~/.local/bin/bd com.steveyegge.bd
set -euo pipefail

SRC="${1:?uso: binary-swap.sh <binário-novo> <destino> [identifier]}"
DEST="${2:?uso: binary-swap.sh <binário-novo> <destino> [identifier]}"
IDENT="${3:-com.gastown.$(basename "$DEST")}"

log() { printf '[binary-swap] %s\n' "$*"; }
die() { printf '[binary-swap] ERRO: %s\n' "$*" >&2; exit 1; }

[ -f "$SRC" ] || die "origem não existe: $SRC"

# Backup datado — rollback é um cp de volta.
if [ -f "$DEST" ]; then
  BK="$DEST.bak-$(date +%Y%m%d-%H%M%S)"
  cp "$DEST" "$BK" && log "backup: $BK"
fi

cp "$SRC" "$DEST" && chmod 0755 "$DEST"
log "instalado: $DEST ($(wc -c <"$DEST" | tr -d ' ') bytes)"

# O passo que este script existe para não deixar esquecer.
codesign --force --sign - --identifier "$IDENT" "$DEST" 2>/dev/null || die "codesign falhou"
codesign -v "$DEST" 2>/dev/null || die "codesign -v reprovou"
log "re-assinado no destino como $IDENT"

# Verificação CRONOMETRADA: prova que executa, e distingue as duas mortes.
start=$(date +%s)
if "$DEST" --version >/dev/null 2>&1 || "$DEST" --help >/dev/null 2>&1; then
  log "verificado: executa ($(( $(date +%s) - start ))s)"
else
  rc=$?; el=$(( $(date +%s) - start ))
  [ "$rc" = 137 ] && [ "$el" -lt 3 ] && die "SIGKILL em ${el}s = assinatura ainda rejeitada (não é timeout)"
  die "não executa (exit=$rc, ${el}s)"
fi
log "pronto. rollback: cp ${BK:-<sem backup>} $DEST"
