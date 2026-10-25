#!/bin/bash
# jsonl-archive-debt-swap.sh (ga-36r6xq, passo 1) — troca SEGURA do pack grande do jsonl-archive por (P' + N), calculados no MBP.
#
# Contexto: 515 versões do whatsapp_automation/comments.jsonl moram no pack grande P como delta de ~11 MB contra o hq/comments.jsonl (5,8 GiB). O MBP re-deltificou
# esses objetos SEM o hq (N, ~99 MiB) e reescreveu P sem eles (P', ~857 MiB; pack-objects --stdin-packs com ^N). Este script, NO MINI, pega P'+N, confere, instala,
# ESCONDE o .idx de P (git ignora um pack sem .idx), verifica que NADA se perdeu com P escondido e SÓ ENTÃO apaga P. Qualquer divergência = devolve o .idx e remove o que instalou.
#
# Ordem (cada passo só começa se o anterior passou; até o passo 9 o repositório é o de antes + arquivos de staging):
#   1 pré-condições (nada muda): df >= MIN_START_MB lido NA HORA; houve um reboot DEPOIS da autorização (AUTH_EPOCH); sem multi-pack-index; P presente e não já trocado
#   2 lock do compactador (mesmo diretório que jsonl-archive-compact.sh e jsonl-export.sh respeitam) + nenhum outro repacker do repo
#   3 identidade: o checksum do pack P (trailer do .idx) é o que o MBP usou
#   4 retrato ANTES: objetos, alcançáveis, commits, garbage
#   5 cópia para staging dentro de .git (mesmo volume) com VIGIA de df: abaixo de FLOOR_MB para a cópia
#   6 sha256 de cada arquivo = manifesto do MBP
#   7 instala P' e N (nomes pack-<hash>; .pack e .rev antes, .idx por último)
#   8 esconde P.idx  (mv para P.idx.swap-hold)
#   9 verifica COM P ESCONDIDO: objetos antes ⊆ depois; alcançáveis antes ⊆ depois; commits depois >= antes; fsck --connectivity-only; a lista de ids lê; amostra lê inteira
#  10 aprovado: apaga P (.pack .idx.swap-hold .rev); reprovado: ROLLBACK (devolve o .idx, remove P' e N instalados)
# Um repositório fica consistente em qualquer ponto de parada: se o processo morrer entre 8 e 10 (SIGKILL), `--recover` devolve o .idx (os packs a mais são só duplicata).
#
# Saída: 0 trocado | 10 uso | 20 não pode começar (df/reboot/estado) | 21 lock em uso | 22 outro repacker (ou não deu para saber) | 23 identidade do P não confere |
#        24 cópia corrompida ou nome já existe | 25 vigia de df parou a cópia | 26 multi-pack-index presente | 27 já trocado | 30 verificação reprovou (rollback FEITO) |
#        31 rollback FALHOU (alto: ver o log) | 40 falha ao apagar P depois de aprovado | 50 recover não achou nada a recuperar
#
# Testes (selftest): JDS_FREE_MB_CMD (imprime MB livres), JDS_BOOT_EPOCH, JDS_GIT, JDS_RSYNC, JDS_WATCH_S, JDS_SKIP_FSCK_SAMPLE.
set -u
set -o pipefail

PROG="jsonl-archive-debt-swap"
CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
RUNTIME="${GC_CITY_RUNTIME_DIR:-$CITY/.gc/runtime}"
REPO="${JDS_REPO:-$RUNTIME/packs/maintenance/jsonl-archive}"
LOCK="${JAC_LOCK:-$RUNTIME/jsonl-archive-compact.lock}"
GIT="${JDS_GIT:-git}"
RSYNC="${JDS_RSYNC:-rsync}"
SRC=""; AUTH_EPOCH=""; MODE="run"
MIN_START_MB="${JDS_MIN_START_MB:-5500}"
FLOOR_MB="${JDS_FLOOR_MB:-3400}"
LOCK_BUDGET_S="${JDS_LOCK_BUDGET_S:-7200}"
STATE_BASE="${JDS_STATE_DIR:-$RUNTIME/ga-36r6xq-swap}"

usage() {
  cat <<EOF
uso: $PROG.sh --src <[host:]dir com os artefatos> --auth-epoch <epoch da autorização> [--repo <dir com .git>] [--recover]
  --src          diretório (local ou host:caminho para o rsync) com manifest.env, manifest.sha256, ids.txt e os packs P' e N
  --auth-epoch   epoch da autorização do Mayor; o mini tem de ter dado boot DEPOIS dele (o reboot noturno)
  --recover      só devolve o .idx escondido de uma troca interrompida e remove o que ela instalou
  env: JDS_MIN_START_MB=$MIN_START_MB  JDS_FLOOR_MB=$FLOOR_MB  JAC_LOCK=$LOCK
EOF
}
while [ $# -gt 0 ]; do
  case "$1" in
    --src) SRC="${2:-}"; shift 2 ;;
    --auth-epoch) AUTH_EPOCH="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --recover) MODE="recover"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "$PROG: argumento desconhecido: $1" >&2; usage >&2; exit 10 ;;
  esac
done
GITDIR="$REPO/.git"
[ -d "$GITDIR/objects/pack" ] || { echo "$PROG: $GITDIR/objects/pack não existe" >&2; exit 10; }
PACKDIR="$GITDIR/objects/pack"
g() { "$GIT" --git-dir="$GITDIR" "$@"; }

mkdir -p "$STATE_BASE" 2>/dev/null
STATE="$STATE_BASE/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$STATE" || { echo "$PROG: não criei $STATE" >&2; exit 10; }
LOGF="$STATE/swap.log"
ts() { date -u +%FT%TZ; }
log() { printf '[%s] %s\n' "$(ts)" "$*" | tee -a "$LOGF"; }
is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# ── três respostas, nunca duas: o df tem/não tem/não consegui ler ──
free_mb() {
  if [ -n "${JDS_FREE_MB_CMD:-}" ]; then sh -c "$JDS_FREE_MB_CMD" 2>/dev/null; return; fi
  df -Pm "$GITDIR" 2>/dev/null | awk 'NR==2 { print $4 }'
}
boot_epoch() {
  if [ -n "${JDS_BOOT_EPOCH:-}" ]; then echo "$JDS_BOOT_EPOCH"; return; fi
  # kern.boottime = "{ sec = 1792892443, usec = 501464 } Sat ...": ancora em "{ sec =" — um "sec = " solto casa DENTRO de "usec = " e devolveria os microssegundos (24/10: abortou rc 20 com boot=501464)
  # vazio (sysctl sumiu/falhou) ou formato que não casa → imprime nada → is_uint falha no passo 1 → ABORT 20, repo intacto (ilegível nunca vira "reiniciou depois da autorização")
  sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ *sec = \([0-9][0-9]*\),.*/\1/p'
}

# ── lock: o mesmo diretório do compactador (jsonl-export.sh o lê como compaction_in_flight) ──
HAVE_LOCK=0
lock_owner_alive() { local p; p="$(cat "$LOCK/pid" 2>/dev/null)"; is_uint "$p" && kill -0 "$p" 2>/dev/null; }
lock_release() { [ "$HAVE_LOCK" = 1 ] || return 0; rm -f "$LOCK/pid" "$LOCK/until" 2>/dev/null; rmdir "$LOCK" 2>/dev/null; HAVE_LOCK=0; }
lock_take() {
  mkdir -p "$(dirname "$LOCK")" 2>/dev/null
  if ! mkdir "$LOCK" 2>/dev/null; then
    # existe: vivo (dono vivo) = em uso; dono morto E mais velho que 1 min = obsoleto (reivindico); qualquer dúvida = em uso
    if lock_owner_alive; then return 1; fi
    if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      rm -f "$LOCK/pid" "$LOCK/until" 2>/dev/null; rmdir "$LOCK" 2>/dev/null || return 1
      mkdir "$LOCK" 2>/dev/null || return 1
    else
      return 1
    fi
  fi
  HAVE_LOCK=1
  printf '%s\n' "$$" > "$LOCK/pid" || { lock_release; return 1; }
  printf '%s\n' "$(( $(date +%s) + LOCK_BUDGET_S ))" > "$LOCK/until" 2>/dev/null
  return 0
}

# ── outro repacker deste usuário trabalhando NESTE repo? 0 = nenhum (resposta confiável), 1 = achei, 2 = não sei (tratado como 1) ──
other_repacker() {
  local real pslist cands pids out rc line pid="" cwd found=0 unknown=0 seen=" " p
  OTHER_WHO=""
  real="$(cd "$REPO" 2>/dev/null && pwd -P)" || return 2
  pslist="$(ps -U "$(id -u)" -o pid=,command= 2>/dev/null)" || return 2
  [ -n "$pslist" ] || return 2
  cands="$(printf '%s\n' "$pslist" | awk -v me="$$" '
    $1 == me { next }
    { g = 0
      for (i = 2; i <= NF; i++) {
        if (!g) { if ($i ~ /(^|\/)git$/) g = 1; continue }
        if ($i ~ /^(maintenance|repack|gc|pack-objects|multi-pack-index|index-pack|prune|prune-packed|commit-graph)$/) { print $1; break }
      }
    }')"
  [ -n "$cands" ] || return 0
  pids="$(printf '%s\n' "$cands" | tr '\n' ',' | sed 's/,$//')"
  command -v lsof >/dev/null 2>&1 || return 2
  out="$(lsof -w -a -d cwd -F pn -p "$pids" 2>&1)"; rc=$?
  [ "$rc" -le 1 ] || return 2
  while IFS= read -r line; do
    case "$line" in
      "") ;;
      p*) pid="${line#p}" ;;
      f*) ;;
      n*) cwd="${line#n}"; seen="$seen$pid "
          case "$cwd" in
            "$real"|"$real"/*) found=1; [ -n "$OTHER_WHO" ] || OTHER_WHO="pid $pid" ;;
            /*) ;;
            *) unknown=1 ;;
          esac ;;
      *) return 2 ;;
    esac
  done <<EOF
$out
EOF
  [ "$found" -eq 1 ] && return 1
  for p in $cands; do
    case "$seen" in *" $p "*) continue ;; esac
    if kill -0 "$p" 2>/dev/null; then unknown=1; fi
  done
  [ "$unknown" -eq 1 ] && return 2
  return 0
}

# ── estado da troca (para o rollback e o recover) ──
OLD=""; INSTALLED=""; HOLD=""; STAGE=""; PHASE="pre"
rollback() {  # devolve o .idx e tira o que foi instalado; 0 = estado de antes restaurado, 1 = falhou (ALTO)
  local rc=0 f
  if [ -n "$HOLD" ] && [ -e "$HOLD" ]; then
    if [ -e "$PACKDIR/$OLD.idx" ]; then log "ROLLBACK: $OLD.idx já existe e o hold também — NÃO sobrescrevo"; rc=1
    else mv "$HOLD" "$PACKDIR/$OLD.idx" || { log "ROLLBACK: não consegui devolver o .idx de $OLD"; rc=1; }; fi
  fi
  for f in $INSTALLED; do  # .idx primeiro: o pack some do git antes dos arquivos
    rm -f "$PACKDIR/$f.idx" "$PACKDIR/$f.rev" "$PACKDIR/$f.pack" 2>/dev/null
  done
  [ -n "$STAGE" ] && [ -d "$STAGE" ] && { find "$STAGE" -mindepth 1 -delete 2>/dev/null; rmdir "$STAGE" 2>/dev/null; }
  if [ "$rc" -eq 0 ] && [ -n "$OLD" ] && [ -s "$PACKDIR/$OLD.idx" ] && [ -s "$PACKDIR/$OLD.pack" ]; then log "ROLLBACK: feito — $OLD.idx de volta, instalados removidos"; else [ "$rc" -eq 0 ] && log "ROLLBACK: nada a devolver"; fi
  return $rc
}
on_exit() {
  local rc=$?
  if [ "$PHASE" = hidden ]; then log "interrompido com o .idx escondido — rollback"; rollback || log "ROLLBACK FALHOU: rode --recover"; fi
  [ -n "$STAGE" ] && [ -d "$STAGE" ] && { find "$STAGE" -mindepth 1 -delete 2>/dev/null; rmdir "$STAGE" 2>/dev/null; }
  lock_release
  exit $rc
}
trap on_exit EXIT
trap 'log "sinal recebido"; exit 143' INT TERM HUP

# ───────────────────────────── --recover ─────────────────────────────
if [ "$MODE" = recover ]; then
  log "=== RECOVER $PROG repo=$REPO ==="
  lock_take || { log "lock em uso — não recupero com outro processo vivo"; exit 21; }
  holds="$(ls "$PACKDIR"/*.idx.swap-hold 2>/dev/null)"
  [ -n "$holds" ] || { log "nenhum .idx.swap-hold — nada a recuperar"; exit 50; }
  for h in $holds; do
    b="$(basename "$h" .idx.swap-hold)"
    if [ -e "$PACKDIR/$b.idx" ]; then log "$b.idx já existe — não sobrescrevo $h"; exit 31; fi
    mv "$h" "$PACKDIR/$b.idx" && log "devolvi $b.idx" || { log "falhou ao devolver $b.idx"; exit 31; }
  done
  log "RECOVER feito. Os packs pack-* instalados pela troca (se houver) ficam como duplicata; apague por nome se quiser o disco de volta."
  exit 0
fi

# ───────────────────────────── troca ─────────────────────────────
T0=$(date +%s)
[ -n "$SRC" ] || { usage >&2; exit 10; }
is_uint "$AUTH_EPOCH" || { echo "$PROG: --auth-epoch obrigatório (epoch)" >&2; exit 10; }
log "=== $PROG repo=$REPO src=$SRC ==="

# 1) pré-condições — nada muda até aqui
FREE0="$(free_mb)"
is_uint "$FREE0" || { log "ABORT 20: não consegui ler o df — não começo (ilegível não é 'tem espaço')"; exit 20; }
[ "$FREE0" -ge "$MIN_START_MB" ] || { log "ABORT 20: df $FREE0 MB < $MIN_START_MB MB (condição do Mayor: começar só com df >= $MIN_START_MB lido na hora)"; exit 20; }
BOOT="$(boot_epoch)"
is_uint "$BOOT" || { log "ABORT 20: não consegui ler o boot do mini — não começo"; exit 20; }
[ "$BOOT" -gt "$AUTH_EPOCH" ] || { log "ABORT 20: o mini deu boot em $BOOT, antes/igual à autorização ($AUTH_EPOCH) — falta o reboot noturno"; exit 20; }
HOUR="$(date +%H)"; case "$HOUR" in 00|01|02|03|04) WIN="dentro da janela 00-05h" ;; *) WIN="FORA da janela 00-05h (preferência do Mayor, não exigência)" ;; esac
log "pré-condições ok: df ${FREE0} MB (>= $MIN_START_MB), boot $BOOT > autorização $AUTH_EPOCH, $WIN"
if ls "$PACKDIR"/*.idx.swap-hold >/dev/null 2>&1; then log "ABORT 20: há um .idx.swap-hold de uma troca interrompida em $PACKDIR — rode --recover antes"; exit 20; fi
if [ -e "$PACKDIR/multi-pack-index" ]; then log "ABORT 26: há multi-pack-index em $PACKDIR — remover/reescrever à mão antes (apagar P com ele apontando para P o quebraria)"; exit 26; fi

# manifesto do MBP
MAN="$STATE/manifest"; mkdir -p "$MAN"
$RSYNC -a -e "ssh -o BatchMode=yes -o ConnectTimeout=8" "${SRC%/}/manifest.env" "${SRC%/}/manifest.sha256" "${SRC%/}/ids.txt" "$MAN/" 2>>"$LOGF" || { log "ABORT 24: não busquei o manifesto de $SRC"; exit 24; }
# manifest.env vem de OUTRA máquina: NÃO se executa com `source`. Só estas chaves, só valores de caracteres seguros (nomes de pack, hex, números).
mget() { sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$MAN/manifest.env" | sed -n '1p'; }
safe() { case "$1" in *[!A-Za-z0-9._\ -]*) return 1 ;; *) return 0 ;; esac; }
OLD_PACK="$(mget OLD_PACK)"; OLD_CHECKSUM="$(mget OLD_CHECKSUM)"; NEW_PACKS="$(mget NEW_PACKS)"; NEED_MB="$(mget NEED_MB)"
for v in "$OLD_PACK" "$OLD_CHECKSUM" "$NEW_PACKS" "$NEED_MB"; do safe "$v" || { log "ABORT 24: manifest.env tem caractere fora do permitido"; exit 24; }; done
[ -n "$OLD_PACK" ] && [ -n "$OLD_CHECKSUM" ] && [ -n "$NEW_PACKS" ] || { log "ABORT 24: manifest.env incompleto"; exit 24; }
OLD="$OLD_PACK"
if [ ! -e "$PACKDIR/$OLD.pack" ]; then log "ABORT 27: $OLD.pack não está mais em $PACKDIR — troca já feita (ou o pack foi consolidado por outro caminho)"; exit 27; fi
[ -s "$PACKDIR/$OLD.idx" ] || { log "ABORT 20: $OLD.idx ausente (hold de uma troca interrompida? rode --recover)"; exit 20; }

# 2) lock + outro repacker
lock_take || { log "ABORT 21: o lock do compactador está em uso ($LOCK, dono $(cat "$LOCK/pid" 2>/dev/null)) — não rodo com compactação em andamento"; exit 21; }
log "lock tomado ($LOCK, pid $$, até +${LOCK_BUDGET_S}s)"
other_repacker; orc=$?
if [ "$orc" -ne 0 ]; then log "ABORT 22: outro repacker neste repo (rc=$orc ${OTHER_WHO:-não deu para saber}) — sem resposta confiável de 'nenhum' eu não troco"; exit 22; fi

# 3) identidade do P
CK="$(tail -c 40 "$PACKDIR/$OLD.idx" | head -c 20 | od -An -tx1 | tr -d ' \n')"
[ "$CK" = "$OLD_CHECKSUM" ] || { log "ABORT 23: checksum do $OLD no mini ($CK) != o que o MBP usou ($OLD_CHECKSUM) — P' não vale para este P"; exit 23; }
log "identidade ok: $OLD checksum $CK"

# 4) retrato ANTES (sob o lock)
t=$(date +%s)
g cat-file --batch-all-objects --batch-check='%(objectname)' | sort > "$STATE/objs.before" || { log "ABORT 20: cat-file ANTES falhou"; exit 20; }
g rev-list --objects --all | awk '{print $1}' | sort -u > "$STATE/reach.before" || { log "ABORT 20: rev-list ANTES falhou"; exit 20; }
COMMITS_B="$(g rev-list --all --count)"; is_uint "$COMMITS_B" && [ "$COMMITS_B" -gt 0 ] || { log "ABORT 20: o repo não tem commits alcançáveis ($COMMITS_B) — conferência seria vazia"; exit 20; }
OBJ_B="$(wc -l < "$STATE/objs.before" | tr -d ' ')"; REACH_B="$(wc -l < "$STATE/reach.before" | tr -d ' ')"
GARB_B="$(g count-objects -v | awk '/^garbage:/ {print $2}')"; PACKS_B="$(g count-objects -v | awk '/^size-pack:/ {print $2}')"
log "ANTES: $OBJ_B objetos, $REACH_B alcançáveis, $COMMITS_B commits, garbage $GARB_B, size-pack ${PACKS_B} KiB ($(( $(date +%s) - t ))s)"
[ "$OBJ_B" -gt 0 ] && [ "$REACH_B" -gt 0 ] || { log "ABORT 20: contagem ANTES vazia"; exit 20; }

# 5) cópia com vigia de df
STAGE="$GITDIR/swap-stage.$$"; mkdir -p "$STAGE" || { log "ABORT 24: sem staging"; exit 24; }
FILES=""
for n in $NEW_PACKS; do FILES="$FILES $n.pack $n.idx $n.rev"; done
# NEED_MB vazio/ilegível no manifesto → segue SEM a pré-checagem, mas dizendo: a cópia fica só com o vigia de df (a cópia não muda o repo; o piso de partida de 5500 MB já dá folga)
if [ -n "${NEED_MB:-}" ] && is_uint "$NEED_MB"; then
  [ $(( FREE0 - NEED_MB )) -ge "$FLOOR_MB" ] || { log "ABORT 20: df $FREE0 MB - $NEED_MB MB da troca ficaria abaixo do piso $FLOOR_MB MB"; exit 20; }
else
  log "AVISO: NEED_MB ausente/ilegível no manifesto ('${NEED_MB:-}') — sem pré-checagem de espaço; só o vigia de df (piso $FLOOR_MB MB) protege a cópia"
fi
ARGS=""; for f in $FILES; do ARGS="$ARGS ${SRC%/}/$f"; done
log "copiando $(echo $FILES | wc -w | tr -d ' ') arquivos de $SRC (vigia de df: para abaixo de $FLOOR_MB MB)"
t=$(date +%s)
# shellcheck disable=SC2086
$RSYNC -a -e "ssh -o BatchMode=yes -o ConnectTimeout=8" $ARGS "$STAGE/" >>"$LOGF" 2>&1 &
RSP=$!
bad=0; TRIP=""
while kill -0 "$RSP" 2>/dev/null; do
  sleep "${JDS_WATCH_S:-3}"
  f="$(free_mb)"
  if is_uint "$f"; then bad=0; else bad=$((bad + 1)); fi
  if [ "$bad" -ge 3 ]; then TRIP="df ilegível 3x"; elif is_uint "$f" && [ "$f" -lt "$FLOOR_MB" ]; then TRIP="df ${f} MB < piso ${FLOOR_MB} MB"; fi
  if [ -n "$TRIP" ]; then kill "$RSP" 2>/dev/null; sleep 1; kill -9 "$RSP" 2>/dev/null; break; fi
done
wait "$RSP" 2>/dev/null; RSRC=$?
if [ -n "$TRIP" ]; then log "ABORT 25: vigia de df parou a cópia: $TRIP — staging removido, nada mudou no repo"; exit 25; fi
[ "$RSRC" -eq 0 ] || { log "ABORT 24: rsync rc=$RSRC"; exit 24; }
log "cópia feita em $(( $(date +%s) - t ))s; df agora $(free_mb) MB"

# 6) sha256 contra o manifesto
t=$(date +%s)
( cd "$STAGE" && for f in $FILES; do grep -F " $f" "$MAN/manifest.sha256" | sed -n '1p' ; done > "$STATE/sha.expected" && shasum -a 256 -c "$STATE/sha.expected" >> "$LOGF" 2>&1 ) || { log "ABORT 24: sha256 da cópia NÃO confere com o manifesto do MBP"; exit 24; }
[ "$(wc -l < "$STATE/sha.expected" | tr -d ' ')" = "$(echo $FILES | wc -w | tr -d ' ')" ] || { log "ABORT 24: o manifesto não cobre todos os arquivos"; exit 24; }
log "sha256 ok em $(echo $FILES | wc -w | tr -d ' ') arquivos ($(( $(date +%s) - t ))s)"

# 7) instala (nomes pack-<hash>; .pack e .rev antes, .idx POR ÚLTIMO)
NEWNAMES=""
for n in $NEW_PACKS; do
  b="pack-${n#*-}"
  if [ -e "$PACKDIR/$b.pack" ] || [ -e "$PACKDIR/$b.idx" ]; then log "ABORT 24: $b já existe em $PACKDIR — não sobrescrevo"; exit 24; fi
  NEWNAMES="$NEWNAMES $b"
done
for n in $NEW_PACKS; do
  b="pack-${n#*-}"
  mv "$STAGE/$n.pack" "$PACKDIR/$b.pack" && mv "$STAGE/$n.rev" "$PACKDIR/$b.rev" && mv "$STAGE/$n.idx" "$PACKDIR/$b.idx" || { INSTALLED="$INSTALLED $b"; log "ABORT 24: mv de $n falhou"; rollback; exit 24; }
  INSTALLED="$INSTALLED $b"
done
rmdir "$STAGE" 2>/dev/null; STAGE=""
log "instalados:$INSTALLED"

# 8) esconde o .idx de P
HOLD="$PACKDIR/$OLD.idx.swap-hold"
mv "$PACKDIR/$OLD.idx" "$HOLD" || { log "ABORT 31: não escondi $OLD.idx"; HOLD=""; rollback; exit 31; }
PHASE=hidden
log "$OLD.idx ESCONDIDO — verificando com P fora de vista"

# 9) verificação com P escondido
FAIL=""
t=$(date +%s)
g cat-file --batch-all-objects --batch-check='%(objectname)' | sort > "$STATE/objs.after" || FAIL="$FAIL cat-file-depois"
if [ -z "$FAIL" ]; then
  LOST="$(comm -23 "$STATE/objs.before" "$STATE/objs.after" | wc -l | tr -d ' ')"
  OBJ_A="$(wc -l < "$STATE/objs.after" | tr -d ' ')"
  log "objetos: antes $OBJ_B, depois $OBJ_A, sumiram $LOST (acréscimos do exportador são esperados)"
  [ "$LOST" = 0 ] || FAIL="$FAIL objetos-sumiram($LOST)"
fi
g rev-list --objects --all | awk '{print $1}' | sort -u > "$STATE/reach.after" || FAIL="$FAIL rev-list-depois"
if [ -z "$FAIL" ]; then
  RLOST="$(comm -23 "$STATE/reach.before" "$STATE/reach.after" | wc -l | tr -d ' ')"
  COMMITS_A="$(g rev-list --all --count)"
  log "alcançáveis: antes $REACH_B, depois $(wc -l < "$STATE/reach.after" | tr -d ' '), sumiram $RLOST; commits antes $COMMITS_B, depois $COMMITS_A"
  [ "$RLOST" = 0 ] || FAIL="$FAIL alcancaveis-sumiram($RLOST)"
  is_uint "$COMMITS_A" && [ "$COMMITS_A" -ge "$COMMITS_B" ] || FAIL="$FAIL commits($COMMITS_B->$COMMITS_A)"
fi
if [ -z "$FAIL" ]; then
  g fsck --connectivity-only --no-dangling --no-progress > "$STATE/fsck.txt" 2>&1; FRC=$?
  if [ "$FRC" -ne 0 ] || grep -q -i -E "^(missing|broken|error|fatal)" "$STATE/fsck.txt"; then FAIL="$FAIL fsck(rc=$FRC)"; head -5 "$STATE/fsck.txt" | while IFS= read -r l; do log "  fsck: $l"; done; else log "fsck --connectivity-only ok"; fi
fi
if [ -z "$FAIL" ] && [ -s "$MAN/ids.txt" ]; then
  # cat-file que falhou (rc != 0) ou que respondeu menos linhas do que ids → "não li" = REPROVA; nunca vira "0 ausentes" (grep -c sobre uma saída vazia imprime 0)
  NIDS="$(awk 'END { print NR }' "$MAN/ids.txt")"
  g cat-file --batch-check < "$MAN/ids.txt" > "$STATE/ids.check"; IRC=$?
  NANS="$(awk 'END { print NR }' "$STATE/ids.check")"
  MISS="$(grep -c ' missing$' "$STATE/ids.check")"
  if [ "$IRC" -ne 0 ] || [ "$NANS" != "$NIDS" ]; then
    log "lista de ids ($NIDS): cat-file rc=$IRC e respondeu $NANS linhas — não consegui ler"
    FAIL="$FAIL ids-nao-li(rc=$IRC,$NANS/$NIDS)"
  else
    log "lista de ids ($NIDS): $MISS ausentes"
    [ "$MISS" = 0 ] || FAIL="$FAIL ids-ausentes($MISS)"
  fi
fi
if [ -z "$FAIL" ] && [ -s "$MAN/ids.txt" ] && [ -z "${JDS_SKIP_FSCK_SAMPLE:-}" ]; then
  # amostra lida INTEIRA do estado sem P: primeiro, do meio e último da lista (inflata e resolve a cadeia de delta de verdade)
  for pos in 1 $(( NIDS / 2 + 1 )) "$NIDS"; do
    id="$(sed -n "${pos}p" "$MAN/ids.txt")"
    sz="$(g cat-file -s "$id" 2>/dev/null)"; got="$(g cat-file blob "$id" 2>/dev/null | wc -c | tr -d ' ')"
    if is_uint "$sz" && [ "$sz" = "$got" ]; then log "amostra $pos ($id): $got bytes lidos = tamanho declarado"; else FAIL="$FAIL amostra($id:$sz!=$got)"; fi
  done
fi
log "verificação levou $(( $(date +%s) - t ))s"

# 10) decisão
if [ -n "$FAIL" ]; then
  log "REPROVADO:$FAIL — ROLLBACK"
  if rollback; then PHASE=done; log "RESULT_DEBT_SWAP status=reprovado-rollback-feito falhas='$FAIL' secs=$(( $(date +%s) - T0 ))"; exit 30; fi
  log "RESULT_DEBT_SWAP status=ROLLBACK-FALHOU falhas='$FAIL'"; PHASE=done; exit 31
fi
SZ_OLD=$(( $(stat -f %z "$PACKDIR/$OLD.pack" 2>/dev/null || stat -c %s "$PACKDIR/$OLD.pack") / 1048576 ))
PHASE=done   # a partir daqui o rollback NÃO existe mais: o que sobra é apagar P
rm -f "$HOLD" "$PACKDIR/$OLD.pack" "$PACKDIR/$OLD.rev" "$PACKDIR/$OLD.mtimes" || { log "ERRO 40: falha ao apagar $OLD depois de aprovado"; exit 40; }
[ ! -e "$PACKDIR/$OLD.pack" ] && [ ! -e "$HOLD" ] || { log "ERRO 40: $OLD ainda existe"; exit 40; }
FREE1="$(free_mb)"
GARB_A="$(g count-objects -v | awk '/^garbage:/ {print $2}')"; PACKS_A="$(g count-objects -v | awk '/^size-pack:/ {print $2}')"
log "P apagado ($SZ_OLD MiB). df: antes $FREE0 MB -> agora ${FREE1:-?} MB; size-pack ${PACKS_B} -> ${PACKS_A} KiB; garbage $GARB_B -> $GARB_A"
log "RESULT_DEBT_SWAP status=ok df_before_mb=$FREE0 df_after_mb=${FREE1:-?} objects_before=$OBJ_B objects_after=$OBJ_A reachable_before=$REACH_B commits_before=$COMMITS_B commits_after=$COMMITS_A size_pack_before_kib=$PACKS_B size_pack_after_kib=$PACKS_A garbage_before=$GARB_B garbage_after=$GARB_A p_mib=$SZ_OLD secs=$(( $(date +%s) - T0 )) state=$STATE"
exit 0
