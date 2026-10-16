#!/bin/bash
# jsonl-hourly-offsite.sh (ga-c0939v) — sobe, a cada hora, o dump JSONL do jsonl-export.sh ao S3, com manifest e verificação.
#
# Contents
#   Por quê · O que sobe · Garantias · Estados e códigos de saída · Retenção · Alerta · Modo --status · Costuras de teste
#
# POR QUÊ: todos os backups do city eram diários (S3 04:00, DoltHub 03:30, restic 04:47) = RPO 24 h. O jsonl-export.sh já arquiva o dump de todos os bancos a
#   cada ~15-30 min num repo git LOCAL; o espelho que existia (dolt-s3-backup.sh, `aws s3 sync --delete`) roda uma vez por noite e copia a árvore no meio de
#   uma escrita. Meta do Athos (15/10): perder no máximo 1 h de beads. Este script é a metade "upload"; a metade "dá para restaurar" é o
#   jsonl-hourly-restore.sh — SEM a prova de restore, um objeto no S3 não conta como RPO.
#
# O QUE SOBE (medido em 16/10: ~570 MB de árvore, 122 MB gzip, ~14 s de CPU; tudo bem abaixo do limite de 5 GB do put-object)
#   jsonl-hourly/snap/<AAAAMMDDTHHMMSSZ>-<sha12 do HEAD>.tar.gz           <db>/<tabela>.jsonl de TODOS os bancos
#   jsonl-hourly/snap/<AAAAMMDDTHHMMSSZ>-<sha12>.manifest.json             contagens lidas DO ARTEFATO, sha256 por tabela, data_as_of
#   jsonl-hourly/latest.json                                               ponteiro para o último snapshot que passou em TUDO; escrito por último
#   A fonte é `git archive <sha do HEAD>`, não a árvore de trabalho: o HEAD é o único estado que o exporter garantiu completo (o gate de export curto roda antes
#   do commit). Ficam de fora os `<db>.jsonl` da raiz (cópias exatas de <db>/issues.jsonl) e as sobras `*.tmp.*` de export abortado já commitadas.
#   Bancos que casam JHO_IGNORE_DBS (padrão `bench_*,fixdepkeys_*`; "" desliga) também ficam de fora e o manifest os nomeia em `ignored_dbs`; obrigatório que case => broken.
#
# GARANTIAS (e o que cada uma NÃO garante)
#   - integridade do upload: put-object leva o sha256 calculado aqui (--checksum-sha256); o S3 recusa o objeto se os bytes
#     que chegaram não batem, e o head-object tem que devolver o mesmo tamanho E o mesmo sha256. Sem isso, o snapshot não vira "latest".
#   - legibilidade: as contagens do manifest vêm de LER o .tar.gz final tabela por tabela (o caminho que o restore percorre). Tabela ilegível, banco (não
#     ignorado) sem alguma das 6 tabelas ou banco obrigatório ausente => "broken": NADA sobe (122 MB/h de snapshot inutilizável é custo e ocuparia o piso da
#     retenção), latest.json NÃO anda, os problemas vão para o log e o run sai 1. Um banco REAL quebrado também veta (fail-closed): o acoplamento é o preço de
#     nunca anunciar como "latest" um snapshot que não restaura.
#   - NÃO garante que o restore funcione: quem prova isso é jsonl-hourly-restore.sh, rodado de verdade (docs/runbooks/jsonl-hourly-offsite.md).
#   - RPO real = idade do dump na captura + 60 min + duração do run (pior caso ~1h40, detalhe no order e no runbook); `data_as_of` diz até quando o snapshot enxerga.
#
# ESTADOS (três, e o neutro é inerte): rc 0 = snapshot novo verificado, ou HEAD igual ao último verificado cujo objeto ainda existe (só atualiza `checked_at`) ·
#   rc 1 = falhou ou ficou "broken" · rc 2 = não deu para avaliar (sem aws/git/python3/jq, archive ilegível, pouco disco, estado sem como gravar): nada foi
#   tentado e conta como run sem snapshot · rc 3 = uso. Outro run em andamento (lock vivo) => rc 0 em silêncio.
#
# RETENÇÃO (só no prefixo jsonl-hourly/snap/, só no formato exato de chave; depois do snapshot novo verificado):
#   últimas JHO_KEEP_RECENT_H (48) horas + o 1º snapshot de cada dia UTC até JHO_KEEP_DAILY_DAYS (14) + os JHO_KEEP_FLOOR (6) mais novos + o apontado por
#   latest.json. Apagar em bucket versionado cria delete marker; as versões antigas saem pela regra de 30 dias que já existe.
#
# ALERTA: JHO_ALERT_AFTER (2) execuções seguidas sem snapshot novo verificado (fail, unknown, ou run morto: `attempt_open` no estado, contado pelo run seguinte) =>
#   `notify` com NOTIFY_FORCE_PUSH=1 NOTIFY_STRICT_EXIT=1 (sem o force o roteador manda esta fonte ao digest mudo: rc 0, nada no telefone). Só rc 0 conta como entregue:
#   grava last_alert_epoch (no máx. 1 a cada JHO_ALERT_EVERY_S, 6 h) e loga "alerta enviado"; senão loga AVISO e o run seguinte tenta de novo.
#   Sem como gravar o estado, avisa sem esperar o 2º run e, sem registro do último aviso, a cada run: nunca mudo.
# MODO --status: lê latest.json do S3 e diz há quanto tempo o script bateu o ponto e até quando o dado enxerga (rc 0 vivo, 1 velho, 2 sem leitura).
#
# COSTURAS DE TESTE: JHO_LIB=1 só define funções; JHO_ARCHIVE, JHO_STATE_DIR, JHO_LOG, JHO_AWS, JHO_NOTIFY, JHO_NOW (epoch) apontam para fixtures.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${JHO_PY:-$HERE/jsonl_hourly.py}"
CITY="${GC_CITY_PATH:-${GC_CITY:-/Users/athos/gt/.gascity-gastown-hq}}"
RUNTIME="${GC_CITY_RUNTIME_DIR:-$CITY/.gc/runtime}"
ARCHIVE="${JHO_ARCHIVE:-$RUNTIME/packs/maintenance/jsonl-archive}"
STATE_DIR="${JHO_STATE_DIR:-$RUNTIME/packs/town-deltas}"
STATE_FILE="$STATE_DIR/jsonl-hourly-offsite-state.json"
LOCKDIR="$STATE_DIR/jsonl-hourly-offsite.lock.d"
WORKROOT="$STATE_DIR/jsonl-hourly-work"
LOG="${JHO_LOG:-$CITY/.gc/logs/jsonl-hourly-offsite.log}"
BUCKET="${JHO_BUCKET:-urblink-dolt-backups}"
PREFIX="${JHO_S3_PREFIX:-jsonl-hourly}"
AWS="${JHO_AWS:-$(command -v aws || echo /opt/homebrew/bin/aws)}"
NOTIFY="${JHO_NOTIFY:-/Users/athos/.local/bin/notify}"
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
S3_TIMEOUT="${JHO_S3_TIMEOUT:-1200}"
BUILD_TIMEOUT="${JHO_BUILD_TIMEOUT:-900}"
MIN_FREE_MB="${JHO_MIN_FREE_MB:-1024}"
LOCK_STALE_MIN="${JHO_LOCK_STALE_MIN:-120}"
KEEP_RECENT_H="${JHO_KEEP_RECENT_H:-48}"
KEEP_DAILY_DAYS="${JHO_KEEP_DAILY_DAYS:-14}"
KEEP_FLOOR="${JHO_KEEP_FLOOR:-6}"
ALERT_AFTER="${JHO_ALERT_AFTER:-2}"
ALERT_EVERY_S="${JHO_ALERT_EVERY_S:-21600}"
REQUIRED_DBS="${JHO_REQUIRED_DBS:-hq,whatsapp_automation}"
# bancos de teste/benchmark que o jsonl-export arquiva (bench_hq_copy tem config/metadata com 0 bytes; fixdepkeys_* são de teste): NÃO entram no
# artefato e não vetam o snapshot. `-` e não `:-`: JHO_IGNORE_DBS="" (vazio) desliga de propósito. Um obrigatório que case com o padrão => broken.
IGNORE_DBS="${JHO_IGNORE_DBS-bench_*,fixdepkeys_*}"
STATUS_MAX_CHECK_AGE_S="${JHO_STATUS_MAX_CHECK_AGE_S:-9000}"   # 2h30: dois ciclos horários + folga
STALE_SOURCE_S="${JHO_STALE_SOURCE_S:-21600}"                  # HEAD do archive mais velho que 6 h => aviso (exporter parado ou ocioso)
# ga-tyaozh: sem isso o aws-cli embrulha o corpo num AwsChunkedWrapper que não rebobina e aborta o retry (mesma razão do dolt-s3-backup.sh)
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required

now_epoch() { echo "${JHO_NOW:-$(date +%s)}"; }
iso_now()   { python3 -I -c 'import datetime,sys;print(datetime.datetime.fromtimestamp(int(sys.argv[1]),datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$(now_epoch)"; }
stamp_now() { python3 -I -c 'import datetime,sys;print(datetime.datetime.fromtimestamp(int(sys.argv[1]),datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ"))' "$(now_epoch)"; }
log() { mkdir -p "$(dirname "$LOG")" 2>/dev/null; echo "[$(iso_now)] $*" >> "$LOG" 2>/dev/null; echo "[$(iso_now)] $*" >&2; }

# ── funções puras / de estado (testáveis em modo biblioteca) ──────────────────────────────
# O sha256 em base64 que o S3 espera em --checksum-sha256, a partir do hex.
sha256_b64() { python3 -I -c 'import base64,sys;print(base64.b64encode(bytes.fromhex(sys.argv[1])).decode())' "$1"; }

# true (0) só quando os dois números existem, são inteiros e iguais — nada de "ambos vazios = iguais".
sizes_match() {
  case "${1:-}${2:-}" in ""|*[!0-9]*) return 1 ;; esac
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ "$1" = "$2" ]
}

state_get() { # jq-path default
  local v
  if [ -f "$STATE_FILE" ] && v="$(jq -r "$1 // empty" "$STATE_FILE" 2>/dev/null)" && [ -n "$v" ]; then echo "$v"; else echo "${2:-}"; fi
}
state_write() { # json
  mkdir -p "$STATE_DIR" || return 1
  local tmp
  tmp="$(mktemp "$STATE_FILE.tmp.XXXXXX")" || return 1
  if printf '%s\n' "$1" | jq -e . > "$tmp" 2>/dev/null; then mv -f "$tmp" "$STATE_FILE"; else rm -f "$tmp"; return 1; fi
}
state_update() { # jq-filter args...  (aplica o filtro ao estado atual, ou a {} se não houver)
  local cur="{}" f="$1"; shift
  [ -f "$STATE_FILE" ] && jq -e . "$STATE_FILE" >/dev/null 2>&1 && cur="$(cat "$STATE_FILE")"
  state_write "$(printf '%s' "$cur" | jq -c "$@" "$f")"
}

# FORCE_PUSH: sem ele o roteador do notify manda esta fonte (fora da allowlist) para o digest mudo: rc 0 e nada no telefone. STRICT_EXIT: rc != 0 = não saiu. Devolve o rc.
notify_fail() { NOTIFY_FORCE_PUSH=1 NOTIFY_STRICT_EXIT=1 "$NOTIFY" -t "Jsonl hourly offsite" -p 4 "🚨 $*" >/dev/null 2>&1; }

# Conta mais uma execução sem snapshot novo e decide se avisa. $1 = motivo curto. Fecha a tentativa (attempt_open).
register_not_ok() {
  local reason="$1" n last now arc
  now="$(now_epoch)"
  n="$(state_get '.consecutive_not_ok' 0)"; n=$((n + 1))
  last="$(state_get '.last_alert_epoch' 0)"
  # contador que não grava não vira "1 seguida, sem alerta": sem como contar, avisa já
  state_update '.consecutive_not_ok = $n | .last_not_ok_reason = $r | .last_not_ok_at = $t | .attempt_open = false' --argjson n "$n" --arg r "$reason" --arg t "$(iso_now)" || { log "AVISO: não gravei o estado; sem contador, aviso já"; n=$ALERT_AFTER; }
  if [ "$n" -ge "$ALERT_AFTER" ] && [ $((now - last)) -ge "$ALERT_EVERY_S" ]; then
    notify_fail "$n execuções seguidas sem snapshot horário novo no S3 ($reason). Último bom: $(state_get '.last_success_at' nunca)"; arc=$?
    if [ $arc -eq 0 ]; then   # só rc 0 é entregue: gasta o limite de 6 h e diz "enviado"
      state_update '.last_alert_epoch = $e' --argjson e "$now" || log "AVISO: alerta saiu mas last_alert_epoch não gravou (repete no próximo run)"
      log "alerta enviado (consecutive_not_ok=$n)"
    else
      log "AVISO: alerta NÃO entregue (rc=$arc); o próximo run tenta de novo"
    fi
  fi
}

s3key_artifact() { echo "$PREFIX/snap/$1.tar.gz"; }       # $1 = stem <stamp>-<sha12>
s3key_manifest() { echo "$PREFIX/snap/$1.manifest.json"; }
s3key_latest()   { echo "$PREFIX/latest.json"; }

# aws s3api com timeout; stdout = JSON da resposta, rc = rc do aws.
s3api() { "$TIMEOUT_BIN" "$S3_TIMEOUT" "$AWS" s3api "$@"; }

# head-object -> JSON em stdout; rc 0 existe, 1 não existe (404), 2 erro de outra natureza (não sei).
s3_head() { # key
  local out rc
  out="$(s3api head-object --bucket "$BUCKET" --key "$1" --checksum-mode ENABLED --output json 2>&1)"; rc=$?
  if [ $rc -eq 0 ]; then printf '%s' "$out"; return 0; fi
  case "$out" in *"Not Found"*|*"(404)"*|*NoSuchKey*) return 1 ;; esac   # "404" solto casaria com qualquer erro que o cite (id de request, 403...)
  printf '%s' "$out" >&2; return 2
}

# put-object de um arquivo com sha256 conferido pelo S3. $1=key $2=arquivo $3=sha256 hex $4=content-type
s3_put_verified() {
  local key="$1" file="$2" sha="$3" ctype="${4:-application/octet-stream}" b64 bytes head len cs
  b64="$(sha256_b64 "$sha")" || return 1
  bytes="$(wc -c < "$file" | tr -d ' ')"
  s3api put-object --bucket "$BUCKET" --key "$key" --body "$file" --content-type "$ctype" \
        --checksum-algorithm SHA256 --checksum-sha256 "$b64" --output json >/dev/null 2>>"$LOG" || { log "put-object de $key falhou"; return 1; }
  head="$(s3_head "$key")" || { log "head-object de $key falhou depois do put"; return 1; }
  len="$(printf '%s' "$head" | jq -r '.ContentLength // empty')"
  cs="$(printf '%s' "$head" | jq -r '.ChecksumSHA256 // empty')"
  sizes_match "$len" "$bytes" || { log "$key: tamanho no S3 ($len) != local ($bytes)"; return 1; }
  [ -n "$cs" ] && [ "$cs" = "$b64" ] || { log "$key: sha256 no S3 ('$cs') != local ('$b64')"; return 1; }
  return 0
}

if [ "${JHO_LIB:-0}" = "1" ]; then return 0 2>/dev/null || exit 0; fi

# ═════════════════════════════ execução ═════════════════════════════════════════════════
MODE="run"
case "${1:-}" in
  --status) MODE="status" ;;
  "") ;;
  -h|--help) sed -n '2,44p' "${BASH_SOURCE[0]}"; exit 0 ;;
  *) echo "uso: jsonl-hourly-offsite.sh [--status]" >&2; exit 3 ;;
esac

unknown() { # rc 2, sem veredito. Em run conta como run sem snapshot (antes só stderr: PATH sem /opt/homebrew/bin falhava toda hora, mudo); em --status só diz
  if [ "$MODE" = run ]; then log "UNKNOWN: $*"; register_not_ok "unknown: $*"; echo "RESULT: unknown $*"; else echo "UNKNOWN: $*" >&2; fi
  exit 2
}
[ -n "$TIMEOUT_BIN" ] || unknown "timeout (GNU) ausente"
for t in jq git python3; do command -v "$t" >/dev/null 2>&1 || unknown "$t ausente"; done
[ -x "$AWS" ] || command -v "$AWS" >/dev/null 2>&1 || unknown "aws ausente ($AWS)"
[ -f "$PY" ] || unknown "helper ausente: $PY"

# ── --status ─────────────────────────────────────────────────────────────────────────────
if [ "$MODE" = status ]; then
  tmp="$(mktemp "${TMPDIR:-/tmp}/jho-status.XXXXXX")" || exit 2
  trap 'rm -f "$tmp"' EXIT
  if ! s3api get-object --bucket "$BUCKET" --key "$(s3key_latest)" "$tmp" >/dev/null 2>&1; then
    echo "STATUS: UNKNOWN não li $(s3key_latest) no S3"; exit 2
  fi
  checked="$(jq -r '.checked_at // empty' "$tmp")"; asof="$(jq -r '.data_as_of // empty' "$tmp")"
  [ -n "$checked" ] && [ -n "$asof" ] || { echo "STATUS: UNKNOWN latest.json sem checked_at/data_as_of"; exit 2; }
  ages="$(python3 -I -c '
import datetime,sys
def ep(s): return int(datetime.datetime.strptime(s,"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp())
now=int(sys.argv[3]); print(now-ep(sys.argv[1]), now-ep(sys.argv[2]))' "$checked" "$asof" "$(now_epoch)")" || { echo "STATUS: UNKNOWN datas ilegíveis"; exit 2; }
  check_age="${ages% *}"; asof_age="${ages#* }"
  if [ "$check_age" -le "$STATUS_MAX_CHECK_AGE_S" ]; then verdict=OK; rc=0; else verdict=STALE; rc=1; fi
  echo "STATUS: $verdict checked_at=$checked (há ${check_age}s) data_as_of=$asof (há ${asof_age}s) snapshot=$(jq -r '.snapshot_key' "$tmp")"
  exit $rc
fi

# ── lock (mkdir atômico; dono = pid; reclama se o dono morreu ou passou de LOCK_STALE_MIN) ─────────────
mkdir -p "$STATE_DIR" || unknown "não criei $STATE_DIR"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  holder="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
  # sem pid ainda NÃO é dono morto: o outro run fez o mkdir e ainda não gravou o pid. Só reclama depois de 1 min.
  if [ -z "$holder" ] && [ -z "$(find "$LOCKDIR" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
    log "lock sem pid e com menos de 1 min: outro run está começando; saindo"; exit 0
  fi
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null && [ -z "$(find "$LOCKDIR" -maxdepth 0 -mmin +"$LOCK_STALE_MIN" 2>/dev/null)" ]; then
    log "outro run em andamento (pid $holder); saindo"; exit 0
  fi
  log "lock de pid '$holder' morto ou com mais de ${LOCK_STALE_MIN} min: reclamando"
  case "$LOCKDIR" in */jsonl-hourly-offsite.lock.d) rm -rf "$LOCKDIR" ;; esac
  mkdir "$LOCKDIR" 2>/dev/null || { log "não consegui pegar o lock"; exit 0; }
fi
echo $$ > "$LOCKDIR/pid"
WD="$WORKROOT/run.$$"
cleanup() {
  case "$LOCKDIR" in */jsonl-hourly-offsite.lock.d) rm -rf "$LOCKDIR" ;; esac
  case "$WD" in "$WORKROOT"/run.*) rm -rf "$WD" ;; esac
}
trap cleanup EXIT
# sobras de runs mortos (só o nosso padrão, só com mais de 3 h)
if [ -d "$WORKROOT" ]; then find "$WORKROOT" -maxdepth 1 -name 'run.*' -type d -mmin +180 -exec rm -rf {} + 2>/dev/null; fi
mkdir -p "$WD"

START="$(now_epoch)"
# run que começou e nunca registrou desfecho (morto pelo timeout do order, kill, reboot) deixou attempt_open: conta agora como run sem snapshot
# vazio → false (não há run morto); falhou/ilegível → false também: sem prova de run morto, o inerte é não contar (o AVISO de estado não gravado já grita)
if [ "$(state_get '.attempt_open' false)" = true ]; then log "run anterior não terminou (timeout do order, kill ou reboot): conta como run sem snapshot"; register_not_ok "run anterior não terminou"; fi
state_update '.last_attempt_at = $t | .attempt_open = true' --arg t "$(iso_now)" || log "AVISO: não gravei o estado"

# ── pré-voo: tudo aqui é rc 2 (sem veredito), nada foi tentado ───────────────────────────────
git -C "$ARCHIVE" rev-parse --git-dir >/dev/null 2>&1 || unknown "archive não é um repo git: $ARCHIVE"
SHA="$(git -C "$ARCHIVE" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" || unknown "archive sem HEAD"
HEAD_EPOCH="$(git -C "$ARCHIVE" log -1 --format=%ct "$SHA" 2>/dev/null)"
case "$HEAD_EPOCH" in ""|*[!0-9]*) unknown "não li a data do HEAD $SHA" ;; esac
FREE="$(df -Pk "$STATE_DIR" | awk 'NR==2 {print int($4/1024)}')"
[ -n "$FREE" ] && [ "$FREE" -ge "$MIN_FREE_MB" ] || unknown "pouco disco em $STATE_DIR (${FREE:-?} MB < $MIN_FREE_MB MB)"

SHA12="${SHA:0:12}"
STAMP="$(stamp_now)"
STEM="$STAMP-$SHA12"
HEAD_AGE=$(( $(now_epoch) - HEAD_EPOCH ))
[ "$HEAD_AGE" -gt "$STALE_SOURCE_S" ] && log "AVISO: o HEAD do archive tem ${HEAD_AGE}s (> ${STALE_SOURCE_S}s): exporter parado, ou nada mudou desde então"

# ── HEAD igual ao último verificado e o objeto ainda existe: só bate o ponto ───────────────────────
LAST_SHA="$(state_get '.last_success_sha' '')"; LAST_KEY="$(state_get '.last_success_key' '')"
if [ "$LAST_SHA" = "$SHA" ] && [ -n "$LAST_KEY" ]; then
  s3_head "$LAST_KEY" >/dev/null; hrc=$?
  if [ $hrc -eq 0 ]; then
    LAST_STEM="$(basename "${LAST_KEY%.tar.gz}")"
    cur="$(mktemp "$WD/latest.XXXXXX")"
    # vazio/sem snapshot_key/de outro snapshot → não bate o ponto, vai para o snapshot novo; falhou/ilegível → idem (nunca reescreve um latest.json que não é o nosso)
    if s3api get-object --bucket "$BUCKET" --key "$(s3key_latest)" "$cur" >/dev/null 2>&1 && jq -e --arg k "$LAST_KEY" '.snapshot_key == $k' "$cur" >/dev/null 2>&1; then
      jq --arg t "$(iso_now)" '.checked_at = $t' "$cur" > "$WD/latest.new" 2>/dev/null \
        && LSHA="$(python3 -I -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$WD/latest.new")" \
        && s3_put_verified "$(s3key_latest)" "$WD/latest.new" "$LSHA" application/json \
        && { state_update '.consecutive_not_ok = 0 | .attempt_open = false | .last_check_at = $t' --arg t "$(iso_now)" || log "AVISO: estado não gravado (o contador de falhas pode ficar sem zerar)"
             log "HEAD $SHA12 já está no S3 ($LAST_STEM): ponto batido"; echo "RESULT: ok unchanged key=$LAST_KEY head_age_s=$HEAD_AGE"; exit 0; }
      log "não consegui reescrever latest.json; sigo para um snapshot novo"
    else
      log "latest.json não lido, ilegível ou de outro snapshot; sigo para um snapshot novo"
    fi
  elif [ $hrc -eq 2 ]; then
    unknown "S3 não respondeu ao head-object de $LAST_KEY"
  else
    log "último snapshot ($LAST_KEY) sumiu do S3: subindo de novo"
  fi
fi

# ── build: git archive do HEAD -> tar.gz filtrado ──────────────────────────────────────────────────
fail() { log "FALHOU: $*"; register_not_ok "$*"; echo "RESULT: fail $*"; exit 1; }
log "snapshot $STEM (HEAD $SHA12, dado de há ${HEAD_AGE}s)"
set -o pipefail
( git -C "$ARCHIVE" archive --format=tar "$SHA" | nice -n 15 "$TIMEOUT_BIN" "$BUILD_TIMEOUT" python3 -I "$PY" build --out "$WD/snap.tar.gz" --files-out "$WD/files.json" --ignore-db "$IGNORE_DBS" ) > "$WD/build.out" 2> "$WD/build.err" \
  || fail "build do artefato falhou: $(tail -c 300 "$WD/build.err" "$WD/build.out" 2>/dev/null | tr '\n' ' ')"
nice -n 15 "$TIMEOUT_BIN" "$BUILD_TIMEOUT" python3 -I "$PY" inspect "$WD/snap.tar.gz" > "$WD/inspect.json" 2> "$WD/inspect.err"
irc=$?
[ -s "$WD/inspect.json" ] || fail "inspect não produziu saída (rc=$irc): $(tail -c 300 "$WD/inspect.err" | tr '\n' ' ')"
ART="$(s3key_artifact "$STEM")"
python3 -I "$PY" manifest --inspect "$WD/inspect.json" --built "$WD/files.json" --captured-epoch "$(now_epoch)" --head-epoch "$HEAD_EPOCH" \
  --head-sha "$SHA" --key "$ART" --require "$REQUIRED_DBS" > "$WD/manifest.json" 2> "$WD/manifest.err"
mrc=$?
[ -s "$WD/manifest.json" ] || fail "manifest não gerado: $(tail -c 300 "$WD/manifest.err" | tr '\n' ' ')"
VERDICT="$(jq -r '.verdict' "$WD/manifest.json")"
ART_SHA="$(jq -r '.artifact.sha256' "$WD/manifest.json")"; ART_BYTES="$(jq -r '.artifact.bytes' "$WD/manifest.json")"
sizes_match "$ART_BYTES" "$(wc -c < "$WD/snap.tar.gz" | tr -d ' ')" || fail "bytes do manifest != bytes do arquivo"
# broken não sobe NADA: ~122 MB por hora de um snapshot declarado inutilizável não é "cópia a mais", é custo e ruído, e ocuparia o piso da
# retenção no lugar de um bom. Os problemas inteiros vão para o log (o alerta leva o começo); a próxima hora tenta de novo com o HEAD seguinte.
if [ "$VERDICT" != ok ] || [ $mrc -ne 0 ]; then
  jq -r '.problems[]' "$WD/manifest.json" 2>/dev/null | while IFS= read -r pb; do log "problema: $pb"; done
  fail "snapshot $STEM broken ($(jq -r '.problems | join("; ")' "$WD/manifest.json" | head -c 400)); NADA subiu, latest.json não andou"
fi

# ── upload: artefato, manifest e, só depois, latest.json ──────────────────────────────────────────────
s3_put_verified "$ART" "$WD/snap.tar.gz" "$ART_SHA" application/gzip || fail "upload do artefato não verificou"
MAN_SHA="$(python3 -I -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$WD/manifest.json")"
s3_put_verified "$(s3key_manifest "$STEM")" "$WD/manifest.json" "$MAN_SHA" application/json || fail "upload do manifest não verificou"
jq -n --arg key "$ART" --arg mkey "$(s3key_manifest "$STEM")" --arg sha "$ART_SHA" --argjson bytes "$ART_BYTES" \
      --arg asof "$(jq -r '.data_as_of' "$WD/manifest.json")" --arg cap "$(jq -r '.captured_at' "$WD/manifest.json")" \
      --arg head "$SHA" --arg chk "$(iso_now)" --argjson db "$(jq -c '.databases | map_values(.issues)' "$WD/manifest.json")" \
      '{schema:1, snapshot_key:$key, manifest_key:$mkey, sha256:$sha, bytes:$bytes, data_as_of:$asof, captured_at:$cap, checked_at:$chk, source_head:$head, issues_per_db:$db}' > "$WD/latest.json" \
  || fail "não montei latest.json (jq falhou): nada foi publicado como ponteiro"
LSHA="$(python3 -I -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$WD/latest.json")"
s3_put_verified "$(s3key_latest)" "$WD/latest.json" "$LSHA" application/json || fail "upload de latest.json não verificou"

state_update '.consecutive_not_ok = 0 | .attempt_open = false | .last_success_at = $t | .last_success_sha = $s | .last_success_key = $k | .last_success_bytes = $b | .last_success_data_as_of = $a' \
  --arg t "$(iso_now)" --arg s "$SHA" --arg k "$ART" --argjson b "$ART_BYTES" --arg a "$(jq -r '.data_as_of' "$WD/manifest.json")" || log "AVISO: estado não gravado"
DUR=$(( $(now_epoch) - START ))
log "OK $STEM: $ART_BYTES bytes, $(jq -r '[.databases | to_entries[] | .value.issues] | add' "$WD/manifest.json") issues em $(jq -r '.databases | length' "$WD/manifest.json") bancos (ignorados: $(jq -r '.ignored_dbs | join(",") | if . == "" then "nenhum" else . end' "$WD/manifest.json")), ${DUR}s"

# ── retenção (falha aqui é aviso: o snapshot novo já está seguro) ────────────────────────────────────
# listagem que falhou OU veio ilegível => pula (nunca vira "0 chaves"); helper que falhou => pula, e não lê o delete.txt parcial dele.
if listing="$(s3api list-objects-v2 --bucket "$BUCKET" --prefix "$PREFIX/snap/" --output json 2>>"$LOG")" \
   && printf '%s' "$listing" | jq -r '.Contents[]?.Key' > "$WD/keys.txt" 2>/dev/null; then
  if python3 -I "$PY" retention --prefix "$PREFIX" --now "$(now_epoch)" --keep-recent-h "$KEEP_RECENT_H" --keep-daily-days "$KEEP_DAILY_DAYS" \
       --floor "$KEEP_FLOOR" --protect "$ART" < "$WD/keys.txt" > "$WD/delete.txt" 2>>"$LOG"; then
    ndel=0
    while IFS= read -r k; do
      [ -n "$k" ] || continue
      if s3api delete-object --bucket "$BUCKET" --key "$k" >/dev/null 2>>"$LOG"; then ndel=$((ndel + 1)); else log "AVISO: não apaguei $k"; fi
    done < "$WD/delete.txt"
    log "retenção: $(wc -l < "$WD/keys.txt" | tr -d ' ') chaves, $ndel apagadas"
  else
    log "AVISO: retenção pulada (o helper falhou; nada apagado)"
  fi
else
  log "AVISO: retenção pulada (list-objects-v2 falhou ou veio ilegível)"
fi
echo "RESULT: ok new key=$ART bytes=$ART_BYTES head_age_s=$HEAD_AGE dur_s=$DUR"
exit 0
