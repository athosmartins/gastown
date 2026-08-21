#!/bin/bash
# dolt-backup-reseed.sh (ga-ydrg9) — re-semeia o backup de UM banco Dolt.
#
# ═══ POR QUE ISTO EXISTE ═══
#
# `dolt backup sync` é INCREMENTAL/APPEND-ONLY. Quando a origem é compactada
# (history squash via `gc dolt compact`), o backup NÃO reflete o squash: o blob
# pré-compactação vira lixo permanente no instante da compactação, e nada o
# remove. A idade dele é irrelevante -- o que importa é que ficou ÓRFÃO.
#
# MEDIDO 21/08 no hq: dos 17 arquivos do backup, UM tinha 10,61GB (datado de
# 17/08, dois dias ANTES da compactação de 19/08) e os outros 16 somavam ~1,4GB.
# 88% do desperdício era esse único órfão. Retenção por IDADE só o removeria
# meses depois, por acidente -- não é o remédio certo para esta doença.
#
# ⚠️ DOUTRINA ANTERIOR ERRADA, corrigida aqui: estava registrado nesta cidade
# que o .dolt-backup "encolhe sozinho quando a origem encolher". Não encolhe.
# Foi essa crença que deixou 12GB de backup para 5,2GB de dados vivos.
#
# ═══ O MECANISMO: RE-SEED, NUNCA PODA NO LUGAR ═══
#
# Não podamos arquivo individual do backup -- o Dolt RECUSA fsck/gc direto num
# diretório de backup (precisa de repo embrulhado em .dolt), e mexer à mão num
# formato que não se entende é como se perde backup.
#
# Em vez disso: backup NOVO em local novo -> VERIFICA que restaura -> troca.
# Isso resolve o catch-22 que travou a investigação anterior: o espaço exigido
# passa a ser o tamanho dos DADOS ATUAIS, não o do BACKUP acumulado.
#
# PROVADO EM TESTE REAL antes de virar script (lexbh, 21/08 09:41):
#   backup novo   = 1 arquivo  / 1.1M
#   backup antigo = 28 arquivos / 1.2M
#   restaurado    = 33 beads == 33 beads no vivo  (dado conferido, não só arquivo)
#
# ═══ REGRA INEGOCIÁVEL ═══
# Nada é apagado antes de o backup novo ter sido RESTAURADO e o DADO conferido
# contra a origem. "O arquivo existe" e "o backup funciona" são perguntas
# diferentes; só a segunda autoriza remover a anterior.
set -uo pipefail

DB="${1:-}"
CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
BACKUP_ROOT="${GC_BACKUP_ARTIFACT_DIR:-$CITY/.dolt-backup}"
LOG="${RESEED_LOG:-$CITY/.gc/logs/dolt-backup-reseed.log}"
# ⚠️ MARGEM — a conta que eu ERREI na primeira versão (pego pelo gate, ga-kawer3).
# Eu dimensionei para UMA cópia extra ("o novo enquanto o antigo existe") e o
# mecanismo cria DUAS ao mesmo tempo. O pico real de consumo NOVO é:
#     NEW_DIR (backup novo, ~1x vivo)
#   + VERIFY_DIR (restauração de verificação, ~1x vivo)   <-- eu tinha esquecido
#   = ~2x o tamanho vivo
# e as duas coexistem ANTES da troca (o BACKUP_DIR original ainda está lá, mas
# esse não é consumo novo). VERIFY_DIR fica sob /tmp, no MESMO volume de dados
# que o preflight mede — não é espaço "de outro lugar".
# Medido no hq: vivo 4.167MB -> minha checagem antiga exigia 6.251MB, pico real
# 8.335MB. Passaria no preflight e estouraria durante a restauração — que é
# exatamente a falha que este script existe para evitar (ga-vs55, 14/07).
# 250% = 2x do pico + 0,5x de folga para a cidade continuar escrevendo durante
# a operação (ela nunca para).
DISK_MARGIN_PCT="${RESEED_DISK_MARGIN_PCT:-250}"
DOLT_BIN="${DOLT_BIN:-dolt}"
GC_BIN="${GC_BIN:-gc}"

mkdir -p "$(dirname "$LOG")" 2>/dev/null
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [reseed] $*" | tee -a "$LOG"; }
die() { log "ABORTADO: $*"; exit 1; }

[ -n "$DB" ] || die "uso: $0 <nome-do-banco>"

BACKUP_DIR="$BACKUP_ROOT/$DB"
NEW_DIR="$BACKUP_DIR.new"
OLD_DIR="$BACKUP_DIR.old"
REMOTE="reseed-$DB"

log "=== re-seed de '$DB' ==="

# ── Preflight 1: o banco existe e responde? ───────────────────────────────────
# Terceiro estado: falha de QUERY e "banco vazio" não podem virar o mesmo valor.
# Se não conseguimos ler a origem, não temos com o que comparar depois -- e um
# re-seed sem verificação possível é pior que nenhum re-seed.
LIVE_COUNT=$(timeout 60 "$GC_BIN" dolt sql -q "SELECT COUNT(*) FROM \`$DB\`.issues" 2>/dev/null \
             | grep -oE '^\| *[0-9]+' | grep -oE '[0-9]+' | head -1)
if [ -z "$LIVE_COUNT" ]; then
  die "não consegui ler a contagem de issues do banco vivo '$DB'. Sem baseline não há verificação possível, e sem verificação não se troca backup."
fi
log "origem viva: $LIVE_COUNT issues (baseline de verificação)"

# ── Preflight 2: espaço em disco ──────────────────────────────────────────────
LIVE_KB=$(du -sk "$CITY/.beads/dolt/$DB" 2>/dev/null | awk '{print $1}')
[ -n "$LIVE_KB" ] || die "não consegui medir o tamanho vivo de '$DB'"
NEED_KB=$(( LIVE_KB * DISK_MARGIN_PCT / 100 ))
# Volume de DADOS. ⚠️ `df /` MENTE no macOS (reporta o volume de SISTEMA, selado
# e de tamanho fixo) -- já quase fez um P0 vivo ser fechado nesta cidade.
FREE_KB=$(df -k /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $4}')
[ -n "$FREE_KB" ] || die "não consegui medir o disco livre"
log "espaço: preciso ~$((NEED_KB/1024))MB, livre $((FREE_KB/1024))MB"
if [ "$FREE_KB" -lt "$NEED_KB" ]; then
  die "disco insuficiente. NÃO iniciando: um sync que enche o disco no meio é exatamente como se corrompe o Dolt (precedente: ga-vs55, 14/07)."
fi

# ── Preflight 3: estado limpo ─────────────────────────────────────────────────
[ -e "$NEW_DIR" ] && die "$NEW_DIR já existe — resíduo de uma execução anterior. Investigue antes; não vou sobrescrever backup."
[ -e "$OLD_DIR" ] && die "$OLD_DIR já existe — resíduo de uma execução anterior. Investigue antes."

cleanup_remote() {
  timeout 30 "$GC_BIN" dolt sql -q "USE \`$DB\`; CALL DOLT_BACKUP('remove','$REMOTE')" >/dev/null 2>&1
}
trap cleanup_remote EXIT

# ── Passo 1: backup novo, em local novo ───────────────────────────────────────
mkdir -p "$NEW_DIR" || die "não consegui criar $NEW_DIR"
log "registrando remote temporário '$REMOTE' -> $NEW_DIR"
timeout 60 "$GC_BIN" dolt sql -q "USE \`$DB\`; CALL DOLT_BACKUP('add','$REMOTE','file://$NEW_DIR')" >/dev/null 2>&1 \
  || die "falhou ao registrar o remote temporário"

log "sincronizando (backup completo do estado ATUAL)..."
timeout 1800 "$GC_BIN" dolt sql -q "USE \`$DB\`; CALL DOLT_BACKUP('sync','$REMOTE')" >/dev/null 2>&1 \
  || { rm -rf "$NEW_DIR"; die "sync falhou. Nada foi trocado; o backup antigo segue intacto."; }

NEW_FILES=$(find "$NEW_DIR" -name "*.darc" 2>/dev/null | wc -l | tr -d ' ')
OLD_FILES=$(find "$BACKUP_DIR" -name "*.darc" 2>/dev/null | wc -l | tr -d ' ')
log "backup novo: $NEW_FILES arquivo(s) | antigo: $OLD_FILES arquivo(s)"

# ── Passo 2: VERIFICAR restaurando e conferindo o DADO ────────────────────────
# Este passo é o motivo do script existir. Sem ele estaríamos trocando um backup
# provado por um desconhecido -- exatamente o risco que a regra proíbe.
VERIFY_DIR=$(mktemp -d "/tmp/reseed-verify-$DB.XXXXXX") || die "não consegui criar diretório de verificação"
cleanup_all() { cleanup_remote; rm -rf "$VERIFY_DIR" 2>/dev/null; }
trap cleanup_all EXIT

log "restaurando o backup novo para conferência..."
if ! ( cd "$VERIFY_DIR" && timeout 1800 "$DOLT_BIN" backup restore "file://$NEW_DIR" "${DB}_verify" >/dev/null 2>&1 ); then
  rm -rf "$NEW_DIR"
  die "o backup novo NÃO RESTAURA. Nada foi trocado; o antigo segue intacto. Isto é o mecanismo funcionando: descobrimos ANTES de apagar."
fi

RESTORED_COUNT=$(cd "$VERIFY_DIR/${DB}_verify" 2>/dev/null && timeout 120 "$DOLT_BIN" sql -q "SELECT COUNT(*) FROM issues" 2>/dev/null \
                 | grep -oE '^\| *[0-9]+' | grep -oE '[0-9]+' | head -1)
if [ -z "$RESTORED_COUNT" ]; then
  rm -rf "$NEW_DIR"
  die "restaurou mas NÃO consegui LER o dado restaurado. 'Não sei' não é 'está ok' — nada foi trocado."
fi

# Libera a cópia de verificação ASSIM QUE o dado foi lido. Não reduz o PICO
# (que acontece durante a restauração), mas encurta a janela em que ele
# persiste — antes ficava ocupado até o fim do script, atravessando a troca.
rm -rf "$VERIFY_DIR" 2>/dev/null
trap cleanup_remote EXIT

log "conferência: restaurado=$RESTORED_COUNT vs vivo=$LIVE_COUNT"
# A origem pode ter crescido durante o sync (a cidade escreve o tempo todo), por
# isso >= e não ==. Menos que o baseline significaria PERDA, e aí abortamos.
if [ "$RESTORED_COUNT" -lt "$LIVE_COUNT" ]; then
  rm -rf "$NEW_DIR"
  die "o backup novo tem MENOS dado que a origem ($RESTORED_COUNT < $LIVE_COUNT). Nada foi trocado."
fi

# ── Passo 3: trocar (só agora, com prova na mão) ──────────────────────────────
log "verificação OK. Trocando."
mv "$BACKUP_DIR" "$OLD_DIR" || die "falhou ao mover o backup antigo; nada trocado"
if ! mv "$NEW_DIR" "$BACKUP_DIR"; then
  mv "$OLD_DIR" "$BACKUP_DIR"   # rollback
  die "falhou ao promover o backup novo — RESTAURADO o antigo ao lugar."
fi

# Reaponta o remote canônico (o caminho não mudou, mas o conteúdo sim).
OLD_SIZE=$(du -sh "$OLD_DIR" 2>/dev/null | awk '{print $1}')
NEW_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
log "trocado. antigo=$OLD_SIZE ($OLD_FILES arquivos) -> novo=$NEW_SIZE ($NEW_FILES arquivos)"

# ⚠️ NÃO apagamos o antigo automaticamente. Ele fica em .old para um humano
# remover depois de olhar. Apagar backup é irreversível, e a economia de disco
# não vale o risco de um automatismo errar em silêncio. O ganho já está
# garantido: o novo está no lugar e verificado.
log "antigo preservado em $OLD_DIR — remova à mão quando estiver confortável."
log "=== re-seed de '$DB' concluído com sucesso ==="
exit 0
