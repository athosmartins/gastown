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
# contra a origem — SALVO no modo de baixo disco abaixo, onde a prova muda de
# forma (S3, não restore local) porque não há disco para as duas provas.
#
# ═══ MODO DE BAIXO DISCO (ga-i99qsp) ═══
#
# O fluxo normal acima precisa de ~250% do tamanho vivo livre: NEW_DIR (backup
# novo, ~1x) + VERIFY_DIR (restauração de verificação, ~1x) coexistindo com o
# BACKUP_DIR antigo, que fica intocado até a troca final. Isso é ótimo quando
# há disco de sobra, mas para o hq (13-14G de staging bloated, disco com só
# 7-8G livres) essa margem NUNCA existe -- e o próprio staging bloated (que o
# mecanismo existe para encolher) é a maior causa do disco estar apertado.
# Catch-22: falta espaço para o mecanismo que devolveria o espaço.
#
# Quando a margem normal não cabe mas uma única cópia nova cabe
# (RESEED_LOW_DISK_MARGIN_PCT, default 120%), o modo de baixo disco entra:
# constrói o backup novo com o antigo ainda no lugar (igual ao fluxo normal);
# só quando o disco livre APÓS construir o novo não bastar para a verificação
# (a segunda cópia), libera o antigo MAIS CEDO que o normal -- mas nunca sem
# antes provar, via S3 (a MESMA prova que dolt-backup-residue-reclaim.sh usa
# para liberar resíduo .old: manifest presente + tamanho coerente com o
# fingerprint), que a cópia local prestes a ser apagada já está espelhada lá.
# Se a prova falhar: NADA é apagado (fail-closed). Se passar e algo DEPOIS
# falhar (restore, contagem, promoção): o banco fica temporariamente SEM
# backup local -- log e saída marcam isso explicitamente ("SEM BACKUP LOCAL")
# para o chamador (dolt-s3-backup.sh) alarmar alto, porque essa janela é
# exatamente o que o desenho normal evita e só é aceita aqui por não haver
# alternativa com o disco que existe. RESEED_ALLOW_LOW_DISK=0 desliga tudo
# isto e volta ao comportamento antigo (só recusa).
set -uo pipefail

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dolt-offline-backup-sync.sh"
# ga-i99qsp: reusa a prova S3 (manifest head-object + coerência de tamanho via
# _meta/latest.json) que dolt-backup-residue-reclaim.sh já tem testada, em vez
# de reimplementar o parsing de fingerprint uma segunda vez (_parse_fingerprint_to_file
# e _size_coherent). LIB mode só define funções/variáveis, não varre nem apaga nada.
# shellcheck disable=SC1091
DOLT_BACKUP_RESIDUE_RECLAIM_LIB=1 . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dolt-backup-residue-reclaim.sh"

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
# ga-i99qsp: margem MÍNIMA para tentar o modo de baixo disco — só precisa
# caber UMA cópia nova (o antigo ainda está no lugar enquanto ela é
# construída), não duas. 120% = 1x vivo + 0,2x de folga para escrita
# concorrente durante a construção (mais apertado que os 0,5x do fluxo
# normal porque o modo de baixo disco é, por definição, para quando 0,5x de
# folga não cabe no disco que existe). Abaixo disto o script se recusa —
# nunca finge que uma cópia cabe em menos que o próprio tamanho vivo.
LOW_DISK_MARGIN_PCT="${RESEED_LOW_DISK_MARGIN_PCT:-120}"
# Escape hatch: 0 desliga o modo de baixo disco inteiro e volta ao
# comportamento antigo (recusa quando a margem normal não cabe, ponto final).
RESEED_ALLOW_LOW_DISK="${RESEED_ALLOW_LOW_DISK:-1}"
DOLT_BIN="${DOLT_BIN:-dolt}"
GC_BIN="${GC_BIN:-gc}"
# ga-o3nqy2: wiring for the shared server-free sync (dolt-offline-backup-sync.sh).
# Read only by that sourced file's functions, not visibly within this one —
# the static analyzer can't see across the dynamic source path below.
# shellcheck disable=SC2034
OFFLINE_SYNC_DOLT_CFG="$CITY/.gc/runtime/packs/dolt/dolt-config.yaml"
# shellcheck disable=SC2034
OFFLINE_SYNC_DOLT_BIN="$DOLT_BIN"
# shellcheck disable=SC2034
OFFLINE_SYNC_LOG="$LOG"
# shellcheck disable=SC2034
OFFLINE_SYNC_TIMEOUT=1800                 # same budget the old server-mediated sync step used

mkdir -p "$(dirname "$LOG")" 2>/dev/null
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [reseed] $*" | tee -a "$LOG"; }
die() { log "ABORTADO: $*"; exit 1; }

# _s3_current_backup_verified <db> <local_dir> — ga-i99qsp: prova de que o S3
# já tem uma cópia restaurável e dimensionalmente coerente de <local_dir>
# ANTES de apagá-lo no modo de baixo disco. É a MESMA prova de duas partes que
# dolt-backup-residue-reclaim.sh's _reclaim_one_residue usa para liberar
# resíduo .old (manifest presente via head-object real + tamanho coerente com
# o fingerprint de _meta/latest.json) — reusa _parse_fingerprint_to_file e
# _size_coherent da lib sourced acima em vez de reimplementar o parsing.
# Deliberadamente NÃO reusa o check de "geração mais nova que a residual" de
# _should_release_residue: aqui não existe uma residual antiga sendo
# substituída por uma nova geração já sincronizada — o que se prova é que o
# conteúdo ATUAL (ainda não tocado) já está espelhado. Fail-closed por
# construção: qualquer falha de AWS/parse/medição retorna falso, nunca
# verdadeiro (ga-p5q3) — quem chama nunca apaga sem um "true" explícito daqui.
_s3_current_backup_verified() {
  local db="$1" local_dir="$2"
  local fp_file parsed_file
  fp_file="$(mktemp "${TMPDIR:-/tmp}/dolt-reseed-fp.XXXXXX" 2>/dev/null)" || { log "prova S3: não consegui criar temp file para fingerprint"; return 1; }
  parsed_file="$(mktemp "${TMPDIR:-/tmp}/dolt-reseed-parsed.XXXXXX" 2>/dev/null)" || { rm -f "$fp_file"; log "prova S3: não consegui criar temp file para parse"; return 1; }

  local manifest_ok=0
  if timeout "$AWS_TIMEOUT_SECS" "$AWS" s3api head-object --bucket "$BUCKET" --key "$db/manifest" >/dev/null 2>&1; then
    manifest_ok=1
  fi

  local run_epoch="" size_bytes="" head=""
  if timeout "$AWS_TIMEOUT_SECS" "$AWS" s3 cp "s3://$BUCKET/_meta/latest.json" "$fp_file" >/dev/null 2>&1; then
    _parse_fingerprint_to_file "$fp_file" "$db" "$parsed_file"
    if [ -s "$parsed_file" ]; then
      IFS="$(printf '\t')" read -r run_epoch size_bytes head < "$parsed_file"
    fi
  fi
  rm -f "$fp_file" "$parsed_file" 2>/dev/null

  local local_bytes=""
  if [ -d "$local_dir" ]; then
    local local_kb; local_kb="$(du -sk "$local_dir" 2>/dev/null | awk '{print $1}')"
    case "$local_kb" in ''|*[!0-9]*) : ;; *) local_bytes=$(( local_kb * 1024 )) ;; esac
  fi

  local size_ok=0
  if _size_coherent "${size_bytes:-}" "${local_bytes:-}" "$MIN_SIZE_RATIO_PCT"; then
    size_ok=1
  fi

  log "prova S3 (modo de baixo disco) para '$db': manifest_ok=$manifest_ok size_ok=$size_ok (fingerprint=${size_bytes:-?}B local=${local_bytes:-?}B run_epoch=${run_epoch:-?} head=${head:-?})"
  [ "$manifest_ok" = "1" ] && [ "$size_ok" = "1" ]
}

# _run_reseed <db> — todo o mecanismo (preflights, construção, verificação,
# troca), extraído para função só para caber num LIB mode testável
# (DOLT_BACKUP_RESEED_LIB=1) sem mudar nenhum comportamento do fluxo normal.
# Assim como o script linear que isto substitui, termina o processo via
# die()/exit — não devolve controle ao chamador em caso de erro.
_run_reseed() {
  local DB="$1"
  [ -n "$DB" ] || die "uso: $0 <nome-do-banco>"

  local BACKUP_DIR="$BACKUP_ROOT/$DB"
  local NEW_DIR="$BACKUP_DIR.new"
  local OLD_DIR="$BACKUP_DIR.old"

  log "=== re-seed de '$DB' ==="

  # ── Preflight 1: o banco existe e responde? ─────────────────────────────────
  # Terceiro estado: falha de QUERY e "banco vazio" não podem virar o mesmo valor.
  # Se não conseguimos ler a origem, não temos com o que comparar depois -- e um
  # re-seed sem verificação possível é pior que nenhum re-seed.
  local LIVE_COUNT
  LIVE_COUNT=$(timeout 60 "$GC_BIN" dolt sql -q "SELECT COUNT(*) FROM \`$DB\`.issues" 2>/dev/null \
               | grep -oE '^\| *[0-9]+' | grep -oE '[0-9]+' | head -1)
  if [ -z "$LIVE_COUNT" ]; then
    die "não consegui ler a contagem de issues do banco vivo '$DB'. Sem baseline não há verificação possível, e sem verificação não se troca backup."
  fi
  log "origem viva: $LIVE_COUNT issues (baseline de verificação)"

  # ── Preflight 2: espaço em disco ────────────────────────────────────────────
  local LIVE_KB NEED_KB FREE_KB
  LIVE_KB=$(du -sk "$CITY/.beads/dolt/$DB" 2>/dev/null | awk '{print $1}')
  [ -n "$LIVE_KB" ] || die "não consegui medir o tamanho vivo de '$DB'"
  NEED_KB=$(( LIVE_KB * DISK_MARGIN_PCT / 100 ))
  # Volume de DADOS. ⚠️ `df /` MENTE no macOS (reporta o volume de SISTEMA, selado
  # e de tamanho fixo) -- já quase fez um P0 vivo ser fechado nesta cidade.
  FREE_KB=$(df -k /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $4}')
  [ -n "$FREE_KB" ] || die "não consegui medir o disco livre"
  log "espaço: preciso ~$((NEED_KB/1024))MB (fluxo normal, ${DISK_MARGIN_PCT}%), livre $((FREE_KB/1024))MB"

  local LOW_DISK_MODE=0
  if [ "$FREE_KB" -lt "$NEED_KB" ]; then
    if [ "$RESEED_ALLOW_LOW_DISK" != "1" ]; then
      die "disco insuficiente. NÃO iniciando: um sync que enche o disco no meio é exatamente como se corrompe o Dolt (precedente: ga-vs55, 14/07). (modo de baixo disco desabilitado via RESEED_ALLOW_LOW_DISK=0)"
    fi
    local LOW_NEED_KB=$(( LIVE_KB * LOW_DISK_MARGIN_PCT / 100 ))
    if [ "$FREE_KB" -lt "$LOW_NEED_KB" ]; then
      die "disco insuficiente até para o modo de baixo disco (preciso ~$((LOW_NEED_KB/1024))MB para UMA cópia nova, livre $((FREE_KB/1024))MB). NÃO iniciando: um sync que enche o disco no meio é exatamente como se corrompe o Dolt (precedente: ga-vs55, 14/07)."
    fi
    LOW_DISK_MODE=1
    log "modo de baixo disco ativado para '$DB': livre $((FREE_KB/1024))MB cobre uma cópia nova (~$((LOW_NEED_KB/1024))MB) mas não as duas do fluxo normal (~$((NEED_KB/1024))MB) -- vou liberar o backup antigo, com prova do S3, SE precisar do espaço dele para a verificação."
  fi

  # ── Preflight 3: estado limpo ────────────────────────────────────────────────
  [ -e "$NEW_DIR" ] && die "$NEW_DIR já existe — resíduo de uma execução anterior. Investigue antes; não vou sobrescrever backup."
  [ -e "$OLD_DIR" ] && die "$OLD_DIR já existe — resíduo de uma execução anterior. Investigue antes."

  # ── Passo 1: backup novo, em local novo ─────────────────────────────────────
  # ga-o3nqy2: server-free (dolt-offline-backup-sync.sh) — sem isso, o mesmo
  # CALL DOLT_BACKUP via servidor que falha no hq desde 11/09 (corte de conexão
  # em 30s, listener.read_timeout_millis) falharia aqui igual, e para hq
  # (6,8GB+) um sync completo estoura esse timeout com folga.
  mkdir -p "$NEW_DIR" || die "não consegui criar $NEW_DIR"
  log "sincronizando via caminho offline (sem servidor, sem timeout de conexão)..."
  _offline_backup_sync "$DB" "$NEW_DIR" \
    || { rm -rf "$NEW_DIR"; die "sync offline falhou. Nada foi trocado; o backup antigo segue intacto."; }

  local NEW_FILES OLD_FILES
  NEW_FILES=$(find "$NEW_DIR" -name "*.darc" 2>/dev/null | wc -l | tr -d ' ')
  OLD_FILES=$(find "$BACKUP_DIR" -name "*.darc" 2>/dev/null | wc -l | tr -d ' ')
  log "backup novo: $NEW_FILES arquivo(s) | antigo: $OLD_FILES arquivo(s)"

  # ── Passo 1.5 (só no modo de baixo disco): liberar o antigo SE precisar ─────
  # do espaço dele para caber a verificação (a segunda cópia). Deferido até
  # aqui de propósito -- o mais tarde possível -- para maximizar a chance de
  # NUNCA precisar tocar no antigo (se o uso real veio menor que a estimativa
  # conservadora do Preflight 2, por exemplo) e minimizar a janela sem backup
  # local quando precisar mesmo.
  local OLD_FREED_EARLY=0
  if [ "$LOW_DISK_MODE" = "1" ]; then
    local FREE_KB_NOW VERIFY_NEED_KB
    FREE_KB_NOW=$(df -k /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $4}')
    VERIFY_NEED_KB=$(( LIVE_KB * LOW_DISK_MARGIN_PCT / 100 ))
    if [ -z "$FREE_KB_NOW" ] || [ "$FREE_KB_NOW" -lt "$VERIFY_NEED_KB" ]; then
      log "modo de baixo disco: livre agora $((${FREE_KB_NOW:-0}/1024))MB não cobre a verificação (~$((VERIFY_NEED_KB/1024))MB) -- avaliando liberar o backup antigo ($BACKUP_DIR) antes de continuar."
      if ! _s3_current_backup_verified "$DB" "$BACKUP_DIR"; then
        rm -rf "$NEW_DIR"
        die "modo de baixo disco: prova do S3 FALHOU para '$DB' (manifest ausente ou tamanho incoerente) -- NADA foi apagado. O backup antigo segue intacto em $BACKUP_DIR; o novo (não verificado) foi descartado."
      fi
      local OLD_FREED_SIZE; OLD_FREED_SIZE="$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')"
      log "modo de baixo disco: prova do S3 OK para '$DB' -- liberando o antigo ($BACKUP_DIR, ~${OLD_FREED_SIZE:-?}) ANTES da verificação, para caber o restore."
      if ! rm -rf "$BACKUP_DIR"; then
        rm -rf "$NEW_DIR"
        die "modo de baixo disco: rm -rf do backup antigo falhou -- NADA foi trocado, mas investigue $BACKUP_DIR manualmente (pode estar parcialmente removido)."
      fi
      OLD_FREED_EARLY=1
      log "modo de baixo disco: antigo liberado (~${OLD_FREED_SIZE:-?}). ATENÇÃO: '$DB' fica SEM BACKUP LOCAL até a verificação abaixo terminar -- o S3 (verificado agora) é o único fallback nesta janela."
    else
      log "modo de baixo disco: livre agora $((FREE_KB_NOW/1024))MB já cobre a verificação (~$((VERIFY_NEED_KB/1024))MB) -- mantendo o antigo intacto por enquanto, mesma prudência do fluxo normal."
    fi
  fi

  # ── Passo 2: VERIFICAR restaurando e conferindo o DADO ──────────────────────
  # Este passo é o motivo do script existir. Sem ele estaríamos trocando um backup
  # provado por um desconhecido -- exatamente o risco que a regra proíbe.
  local VERIFY_DIR
  VERIFY_DIR=$(mktemp -d "/tmp/reseed-verify-$DB.XXXXXX") || die "não consegui criar diretório de verificação"
  cleanup_verify_dir() { rm -rf "$VERIFY_DIR" 2>/dev/null; }
  trap cleanup_verify_dir EXIT

  log "restaurando o backup novo para conferência..."
  if ! ( cd "$VERIFY_DIR" && timeout 1800 "$DOLT_BIN" backup restore "file://$NEW_DIR" "${DB}_verify" >/dev/null 2>&1 ); then
    rm -rf "$NEW_DIR"
    if [ "$OLD_FREED_EARLY" = "1" ]; then
      die "SEM BACKUP LOCAL: modo de baixo disco já tinha liberado o antigo (com prova do S3), e o backup novo NÃO RESTAURA. '$DB' está sem backup local agora -- o S3 verificado antes da liberação é o único fallback. Investigue imediatamente."
    fi
    die "o backup novo NÃO RESTAURA. Nada foi trocado; o antigo segue intacto. Isto é o mecanismo funcionando: descobrimos ANTES de apagar."
  fi

  local RESTORED_COUNT
  RESTORED_COUNT=$(cd "$VERIFY_DIR/${DB}_verify" 2>/dev/null && timeout 120 "$DOLT_BIN" sql -q "SELECT COUNT(*) FROM issues" 2>/dev/null \
                   | grep -oE '^\| *[0-9]+' | grep -oE '[0-9]+' | head -1)
  if [ -z "$RESTORED_COUNT" ]; then
    rm -rf "$NEW_DIR"
    if [ "$OLD_FREED_EARLY" = "1" ]; then
      die "SEM BACKUP LOCAL: modo de baixo disco já tinha liberado o antigo (com prova do S3), e não consegui LER o dado restaurado do novo. '$DB' está sem backup local agora -- o S3 verificado antes da liberação é o único fallback. Investigue imediatamente."
    fi
    die "restaurou mas NÃO consegui LER o dado restaurado. 'Não sei' não é 'está ok' — nada foi trocado."
  fi

  # Libera a cópia de verificação ASSIM QUE o dado foi lido. Não reduz o PICO
  # (que acontece durante a restauração), mas encurta a janela em que ele
  # persiste — antes ficava ocupado até o fim do script, atravessando a troca.
  rm -rf "$VERIFY_DIR" 2>/dev/null

  log "conferência: restaurado=$RESTORED_COUNT vs vivo=$LIVE_COUNT"
  # A origem pode ter crescido durante o sync (a cidade escreve o tempo todo), por
  # isso >= e não ==. Menos que o baseline significaria PERDA, e aí abortamos.
  if [ "$RESTORED_COUNT" -lt "$LIVE_COUNT" ]; then
    rm -rf "$NEW_DIR"
    if [ "$OLD_FREED_EARLY" = "1" ]; then
      die "SEM BACKUP LOCAL: modo de baixo disco já tinha liberado o antigo (com prova do S3), e o novo tem MENOS dado que a origem ($RESTORED_COUNT < $LIVE_COUNT). '$DB' está sem backup local agora -- o S3 verificado antes da liberação é o único fallback. Investigue imediatamente."
    fi
    die "o backup novo tem MENOS dado que a origem ($RESTORED_COUNT < $LIVE_COUNT). Nada foi trocado."
  fi

  # ── Passo 3: trocar (só agora, com prova na mão) ────────────────────────────
  log "verificação OK. Trocando."

  if [ "$OLD_FREED_EARLY" = "1" ]; then
    # O antigo já foi liberado (com prova do S3) lá no Passo 1.5 -- não há
    # ".old" para criar, só promover o novo já verificado direto ao lugar.
    if ! mv "$NEW_DIR" "$BACKUP_DIR"; then
      die "SEM BACKUP LOCAL: modo de baixo disco já tinha liberado o antigo, e promover o novo (verificado) TAMBÉM falhou. '$DB' está SEM BACKUP LOCAL agora. $NEW_DIR (verificado, mv falhou no meio) pode estar parcialmente movido; investigue AGORA -- o S3 é o único fallback."
    fi
    local NEW_SIZE; NEW_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
    log "trocado (modo de baixo disco — sem período de .old, antigo já liberado com prova do S3). novo=$NEW_SIZE ($NEW_FILES arquivos)"
    log "=== re-seed de '$DB' concluído com sucesso (modo de baixo disco) ==="
    exit 0
  fi

  mv "$BACKUP_DIR" "$OLD_DIR" || die "falhou ao mover o backup antigo; nada trocado"
  if ! mv "$NEW_DIR" "$BACKUP_DIR"; then
    # gate-fix 2 (ga-kawer3): o rollback abaixo não pode se autodeclarar
    # bem-sucedido sem checar o próprio resultado -- é a REGRA INEGOCIÁVEL do
    # topo do arquivo (nunca declarar êxito sem verificar) aplicada ao próprio
    # caminho de recuperação. "mv foi chamado" e "o antigo está de volta" são
    # perguntas diferentes; só a segunda autoriza dizer "RESTAURADO".
    if mv "$OLD_DIR" "$BACKUP_DIR"; then
      die "falhou ao promover o backup novo — rollback confirmado, antigo RESTAURADO em $BACKUP_DIR. O novo (verificado, mas não promovido) segue intacto em $NEW_DIR para investigação; não foi apagado."
    else
      die "FALHA DUPLA -- o cenário mais grave que este script pode produzir: falhou ao promover o novo E o rollback do antigo TAMBÉM falhou. $BACKUP_DIR pode estar ausente ou vazio agora. NÃO toque em nada: o antigo (bom) pode ainda estar em $OLD_DIR e o novo (verificado) em $NEW_DIR, mas qual sobreviveu não está confirmado. Investigue manualmente antes de qualquer ação."
    fi
  fi

  # Reaponta o remote canônico (o caminho não mudou, mas o conteúdo sim).
  local OLD_SIZE NEW_SIZE
  OLD_SIZE=$(du -sh "$OLD_DIR" 2>/dev/null | awk '{print $1}')
  NEW_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
  log "trocado. antigo=$OLD_SIZE ($OLD_FILES arquivos) -> novo=$NEW_SIZE ($NEW_FILES arquivos)"

  # ⚠️ NÃO apagamos o antigo automaticamente. Ele fica em .old para um humano
  # (ou para dolt-backup-residue-reclaim.sh, com prova do S3) remover depois.
  # Apagar backup é irreversível, e a economia de disco não vale o risco de um
  # automatismo errar em silêncio. O ganho já está garantido: o novo está no
  # lugar e verificado.
  log "antigo preservado em $OLD_DIR — remova à mão quando estiver confortável, ou deixe o residue-reclaim liberar quando o S3 confirmar."
  log "=== re-seed de '$DB' concluído com sucesso ==="
  exit 0
}

# Library mode: `DOLT_BACKUP_RESEED_LIB=1 source dolt-backup-reseed.sh` defines
# the functions above (including _run_reseed and _s3_current_backup_verified)
# without executing anything — no live dolt/aws call, nothing deleted. Used by
# dolt-backup-reseed.selftest.sh.
if [ "${DOLT_BACKUP_RESEED_LIB:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

_run_reseed "$DB"
