#!/bin/bash
# jsonl-hourly-restore.sh (ga-c0939v) — PROVA de restore do dump horário: tabelas -> `bd import` -> contas.
#
# Contents
#   Por quê · Uso · Códigos de saída · O que a prova cobre e o que não cobre · Segurança
#
# POR QUÊ: "RPO de 1 h" só vale se um dump de 1 h atrás VOLTA. O backup horário (jsonl-hourly-offsite.sh) sobe as
#   tabelas que o jsonl-export.sh grava (issues, comments, dependencies, labels, config, metadata, uma linha
#   `{"rows":[...]}` cada); este script faz o caminho inverso numa cópia descartável: baixa (ou lê) o artefato,
#   confere sha256 contra o manifest, converte as tabelas para o JSONL que `bd import` entende (jsonl_hourly.py convert),
#   cria um store bd EMBUTIDO novo, importa, exporta de volta e faz as contas (jsonl_hourly.py reconcile):
#       manifest − exclusões por desenho = esperado     e     esperado = o que voltou
#   além de comparar, issue por issue, status/título/prioridade/tipo/descrição e, filho por filho, labels, dependências e comentários.
#
# USO
#   jsonl-hourly-restore.sh --db NAME --from-s3 [latest|jsonl-hourly/snap/<chave>.tar.gz] [opções]
#   jsonl-hourly-restore.sh --db NAME --artifact F.tar.gz --manifest M.json [opções]
#   jsonl-hourly-restore.sh --db NAME --dump DIR [opções]        # DIR/<db>/<tabela>.jsonl; sem manifest: as contas partem das linhas lidas
#   opções: --work DIR (não é apagado) · --keep (não apaga o diretório de trabalho) · --report-out F.json ·
#           --min-free-mb N (default 3072) · --import-timeout S (default 3600) · --prefix P (prefixo do store; default = issue_prefix do dump)
#
# CÓDIGOS DE SAÍDA (três estados; "não sei" nunca vira "ok" nem "quebrado")
#   0  PROVADO: as contas fecham e nada diverge
#   1  NÃO REPRODUZ: faltou/sobrou linha, algo voltou diferente, ou o artefato não é o que o manifest descreve
#   2  não deu para concluir (sem bd/python3/aws, pouco disco, S3 inalcançável, import estourou o tempo...): sem veredito
#   3  uso errado
#
# O QUE A PROVA COBRE: as linhas que o jsonl-export.sh arquiva — o dump é ESCRUBBED (message, event, wisp, agent
#   ficam de fora por desenho: mail, wisps e sessões NÃO voltam por aqui). Exclusões que o conversor mede e o relatório
#   mostra: tombstones (o importer pula), filhos órfãos (label/dep/comentário de issue que não está no dump, por exemplo
#   de wisp escrubbado), arestas cujo alvo não está no store (issue de outro banco; o importer só aceita alvo local ou `external:`)
#   e comentários de conteúdo idêntico (mesma issue, autor, texto e data, ids diferentes) que o `bd import` funde em um só
#   (gastown: 14 de 443) — a fusão só vale se cada linha do dump voltou ao menos uma vez e nada voltou a mais.
#   Config: types.custom/status.custom do dump são aplicados ao store novo; nomes que colidem com tipos/status embutidos do bd
#   (o dump do gastown lista pinned e deferred em status.custom) saem do valor e viram AVISO, senão o bd recusa o valor inteiro.
#   NÃO cobre: histórico de commits do Dolt, branches, issues escrubbados, colunas que o importer não recebe
#   (listadas em "unmapped_columns"). O próprio `bd export` se declara "não é backup completo"; o backup completo
#   continua sendo o nightly (DOLT_BACKUP -> S3). Este é o caminho de recuperação de quem perdeu horas, não dias.
#
# SEGURANÇA: o `bd` roda com ambiente LIMPO (`env -i`, HOME e TMPDIR dentro do diretório de trabalho, sem BEADS_DOLT_*),
#   store embutido, em diretório sem `.beads` em nenhum ancestral — nada aqui fala com o Dolt de produção. Só lê o
#   dump/S3; escreve apenas no diretório de trabalho (criado por mktemp, apagado ao fim salvo --keep/--work).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${JHR_PY:-$HERE/jsonl_hourly.py}"
BUCKET="${JHO_BUCKET:-urblink-dolt-backups}"
S3_PREFIX="${JHO_S3_PREFIX:-jsonl-hourly}"
AWS="${JHO_AWS:-aws}"
BD="${JHR_BD:-bd}"
S3_TIMEOUT="${JHO_S3_TIMEOUT:-1200}"
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required   # ga-tyaozh (mesma razão do dolt-s3-backup.sh)

DB="" MODE="" SRC_KEY="" ARTIFACT="" MANIFEST="" DUMP="" WORK_ARG="" KEEP=0 REPORT_OUT="" MIN_FREE_MB=3072
IMPORT_TIMEOUT=3600 PREFIX_ARG=""

log()  { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&2; }
die()  { echo "jsonl-hourly-restore: $*" >&2; exit 3; }
unknown() { echo "RESULT: UNKNOWN db=${DB} motivo=$*"; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --db) DB="${2:-}"; shift 2 ;;
    --from-s3) MODE=s3; SRC_KEY="${2:-latest}"; shift 2 ;;
    --artifact) MODE=file; ARTIFACT="${2:-}"; shift 2 ;;
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --dump) MODE=dump; DUMP="${2:-}"; shift 2 ;;
    --work) WORK_ARG="${2:-}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --report-out) REPORT_OUT="${2:-}"; shift 2 ;;
    --min-free-mb) MIN_FREE_MB="${2:-}"; shift 2 ;;
    --import-timeout) IMPORT_TIMEOUT="${2:-}"; shift 2 ;;
    --prefix) PREFIX_ARG="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "opção desconhecida: $1" ;;
  esac
done

[ -n "$DB" ] || die "falta --db"
case "$DB" in *[!A-Za-z0-9_.-]*|.*) die "--db com caracteres fora de [A-Za-z0-9_.-]" ;; esac
[ -n "$MODE" ] || die "falta a origem: --from-s3, --artifact ou --dump"
case "$MIN_FREE_MB$IMPORT_TIMEOUT" in *[!0-9]*) die "--min-free-mb e --import-timeout são inteiros" ;; esac
[ "$MODE" = file ] && { [ -n "$ARTIFACT" ] && [ -n "$MANIFEST" ] || die "--artifact exige --manifest"; }
[ "$MODE" = dump ] && { [ -d "$DUMP/$DB" ] || die "--dump: $DUMP/$DB não existe"; }

command -v python3 >/dev/null 2>&1 || unknown "python3 ausente"
command -v jq >/dev/null 2>&1 || unknown "jq ausente"
command -v "$BD" >/dev/null 2>&1 || unknown "bd ausente"
TIMEOUT="$(command -v timeout || command -v gtimeout || true)"
[ -n "$TIMEOUT" ] || unknown "timeout (GNU) ausente"
[ -f "$PY" ] || unknown "helper ausente: $PY"
py() { python3 -I "$PY" "$@"; }

# ── diretório de trabalho ─────────────────────────────────────────────────────────────
OWN_WORK=0
if [ -n "$WORK_ARG" ]; then
  WORK="$WORK_ARG"; mkdir -p "$WORK" || unknown "não consegui criar $WORK"
  [ -z "$(ls -A "$WORK" 2>/dev/null)" ] || die "--work $WORK não está vazio"
else
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/jsonl-hourly-restore.XXXXXX")" || unknown "mktemp falhou"
  OWN_WORK=1
fi
WORK="$(cd "$WORK" && pwd -P)"
cleanup() {
  if [ "$OWN_WORK" = 1 ] && [ "$KEEP" = 0 ]; then
    case "$WORK" in
      */jsonl-hourly-restore.*)
        local i=0
        while [ $i -lt 3 ]; do
          rm -rf "$WORK" 2>/dev/null
          [ ! -e "$WORK" ] && return 0
          i=$((i + 1)); sleep 1
        done
        log "AVISO: não consegui apagar $WORK (algo ainda escreve lá?); é o diretório de trabalho do restore, apague à mão" ;;
    esac
  else
    log "diretório de trabalho mantido: $WORK"
  fi
}
trap cleanup EXIT

# nenhum ancestral pode ter `.beads`: o bd sobe a árvore procurando o store e abriria o errado
d="$WORK"
while [ "$d" != "/" ] && [ -n "$d" ]; do
  [ -e "$d/.beads" ] && unknown "$d tem .beads: o bd poderia achar um store de verdade a partir de $WORK"
  d="$(dirname "$d")"
done

free_mb() { df -Pk "$1" | awk 'NR==2 {print int($4/1024)}'; }
FREE="$(free_mb "$WORK")"
[ -n "$FREE" ] && [ "$FREE" -ge "$MIN_FREE_MB" ] || unknown "pouco disco em $WORK: ${FREE:-?} MB livres < $MIN_FREE_MB"

mkdir -p "$WORK/dump" "$WORK/home" "$WORK/tmp" "$WORK/store"

# ── 1. origem -> artefato verificado -> tabelas ──────────────────────────────────────
s3get() { # key dest
  "$TIMEOUT" "$S3_TIMEOUT" "$AWS" s3api get-object --bucket "$BUCKET" --key "$1" "$2" >/dev/null 2>"$WORK/aws.err"
}
if [ "$MODE" = s3 ]; then
  if [ "$SRC_KEY" = latest ]; then
    s3get "$S3_PREFIX/latest.json" "$WORK/latest.json" || unknown "S3: não li $S3_PREFIX/latest.json ($(tail -1 "$WORK/aws.err" 2>/dev/null))"
    SRC_KEY="$(jq -r '.snapshot_key // empty' "$WORK/latest.json")"
    [ -n "$SRC_KEY" ] || unknown "latest.json sem snapshot_key"
  fi
  case "$SRC_KEY" in "$S3_PREFIX"/snap/*.tar.gz) ;; *) die "chave fora de $S3_PREFIX/snap/*.tar.gz: $SRC_KEY" ;; esac
  MANIFEST="$WORK/manifest.json"; ARTIFACT="$WORK/snapshot.tar.gz"
  s3get "${SRC_KEY%.tar.gz}.manifest.json" "$MANIFEST" || unknown "S3: não li o manifest de $SRC_KEY"
  log "baixando $SRC_KEY"
  s3get "$SRC_KEY" "$ARTIFACT" || unknown "S3: não baixei $SRC_KEY ($(tail -1 "$WORK/aws.err" 2>/dev/null))"
fi

MAN_ARG=""
if [ "$MODE" = dump ]; then
  rm -rf "$WORK/dump"; ln -s "$DUMP" "$WORK/dump" 2>/dev/null || unknown "não consegui ligar $DUMP"
else
  jq -e '.schema == 1 and (.databases | type == "object")' "$MANIFEST" >/dev/null 2>&1 || unknown "manifest ilegível ou de outro schema: $MANIFEST"
  want_sha="$(jq -r '.artifact.sha256 // empty' "$MANIFEST")"; want_bytes="$(jq -r '.artifact.bytes // empty' "$MANIFEST")"
  [ -n "$want_sha" ] && [ -n "$want_bytes" ] || unknown "manifest sem artifact.sha256/bytes"
  got_bytes="$(wc -c < "$ARTIFACT" | tr -d ' ')"
  got_sha="$(python3 -I -c 'import hashlib,sys;h=hashlib.sha256();f=open(sys.argv[1],"rb")
while True:
    b=f.read(1<<20)
    if not b: break
    h.update(b)
print(h.hexdigest())' "$ARTIFACT")" || unknown "não consegui calcular o sha256 de $ARTIFACT"
  if [ "$got_bytes" != "$want_bytes" ] || [ "$got_sha" != "$want_sha" ]; then
    echo "RESULT: FAIL db=$DB motivo=artefato difere do manifest (bytes $got_bytes/$want_bytes sha256 ${got_sha:0:12}/${want_sha:0:12})"
    exit 1
  fi
  log "artefato confere com o manifest (sha256 ${got_sha:0:12}, $got_bytes bytes)"
  jq -e --arg db "$DB" '.databases[$db] | type == "object"' "$MANIFEST" >/dev/null 2>&1 || unknown "banco $DB não está no manifest"
  MAN_ARG="--manifest $MANIFEST"
  py extract --archive "$ARTIFACT" --db "$DB" --out "$WORK/dump" > "$WORK/extract.json" 2>"$WORK/extract.err" \
    || unknown "extração de $DB falhou: $(head -c 300 "$WORK/extract.json" "$WORK/extract.err" 2>/dev/null | tr '\n' ' ')"
  # sha256 de cada tabela extraída contra o que o manifest registrou na hora do build
  bad="$(jq -r --slurpfile m "$MANIFEST" '.files[] | . as $f | ($m[0].files // [] | map(select(.path == $f.path)) | .[0]) as $e | select($e == null or $e.sha256 != $f.sha256 or $e.bytes != $f.bytes) | $f.path' "$WORK/extract.json")"
  if [ -n "$bad" ]; then echo "RESULT: FAIL db=$DB motivo=tabela diferente do registrado no manifest: $(echo "$bad" | tr '\n' ' ')"; exit 1; fi
fi

# ── 2. converter ────────────────────────────────────────────────────────────────────────
log "convertendo tabelas de $DB"
py convert --dump "$WORK/dump" --db "$DB" --out "$WORK/import.jsonl" > "$WORK/convert.json" 2>"$WORK/convert.err"
rc=$?
if [ $rc -ne 0 ]; then
  echo "RESULT: FAIL db=$DB motivo=dump não converteu: $(head -c 300 "$WORK/convert.json" | tr '\n' ' ')"; exit 1
fi
IMPORT_BYTES="$(wc -c < "$WORK/import.jsonl" | tr -d ' ')"
FREE="$(free_mb "$WORK")"
need=$(( IMPORT_BYTES / 1048576 * 3 + 512 ))
[ "$FREE" -ge "$need" ] || unknown "pouco disco para importar: ${FREE} MB livres < ~${need} MB (3× o import + 512)"

# ── 3. store descartável + import ───────────────────────────────────────────────────────
PREFIX="${PREFIX_ARG:-$(jq -r '.config.issue_prefix // empty' "$WORK/convert.json")}"
[ -n "$PREFIX" ] || PREFIX="$DB"
case "$PREFIX" in *[!A-Za-z0-9_]*) PREFIX="$(echo "$PREFIX" | tr -c 'A-Za-z0-9_' '_')" ;; esac
sbd() { ( cd "$WORK/store" && env -i HOME="$WORK/home" PATH="$PATH" TMPDIR="$WORK/tmp" BD_NON_INTERACTIVE=1 BEADS_DOLT_AUTO_START=0 DOLT_DISABLE_EVENT_FLUSH=1 "$BD" "$@" ); }
log "bd init (embutido) prefixo=$PREFIX"
sbd init -p "$PREFIX" --non-interactive >"$WORK/init.out" 2>&1 || unknown "bd init falhou: $(tail -2 "$WORK/init.out" | tr '\n' ' ')"
# O bd recusa o valor INTEIRO de types.custom/status.custom se UM item colide com um nome que ele já traz de fábrica (o status.custom do gastown
# lista `pinned` e `deferred`, hoje embutidos): sem isto `done`, que vem junto e não colide, nunca era registrado e o import reprovava na
# primeira issue `done` (medido no gastown real, 16/10: "invalid status: done" na 251ª). Colidir = já vale no import, então o item sai e o
# comando é repetido; o log diz o que saiu. Qualquer outra recusa segue como AVISO e quem reprova é a validação do import (falha fechada).
set_custom() { # chave valor
  local key="$1" val="$2" dropped="" bad item rest found n=0 old_ifs
  while [ -n "$val" ] && [ "$n" -lt 20 ]; do
    n=$((n + 1))
    if sbd config set "$key" "$val" >"$WORK/config-$key.out" 2>&1; then
      [ -z "$dropped" ] || log "AVISO: $key: ${dropped#,} colide(m) com nome embutido do bd (já vale no import) e saiu(ram) do config; aplicado: $val"
      return 0
    fi
    bad="$(sed -n 's/.*custom [a-z]* "\([^"]*\)" collides with built-in.*/\1/p' "$WORK/config-$key.out" | head -1)"
    [ -n "$bad" ] || break
    rest=""; found=0; old_ifs="$IFS"; IFS=,
    for item in $val; do
      case "$item" in "$bad"|"$bad":*) found=1; continue ;; esac
      rest="${rest:+$rest,}$item"
    done
    IFS="$old_ifs"
    [ "$found" = 1 ] || break
    dropped="$dropped,$bad"; val="$rest"
  done
  if [ -z "$val" ] && [ -n "$dropped" ]; then
    log "AVISO: $key: todos os itens (${dropped#,}) colidem com nomes embutidos do bd; nada a configurar"
    return 0
  fi
  log "AVISO: config $key não aplicada ($(tail -1 "$WORK/config-$key.out")) — o import segue; o reconcile diz se algo deixou de voltar"
  return 1
}
for key in types.custom status.custom; do
  val="$(jq -r --arg k "$key" '.config[$k] // empty' "$WORK/convert.json")"
  [ -n "$val" ] || continue
  set_custom "$key" "$val" || true
done
log "bd import ($(( IMPORT_BYTES / 1048576 )) MB)"
start=$(date +%s)
"$TIMEOUT" "$IMPORT_TIMEOUT" env -i HOME="$WORK/home" PATH="$PATH" TMPDIR="$WORK/tmp" BD_NON_INTERACTIVE=1 BEADS_DOLT_AUTO_START=0 DOLT_DISABLE_EVENT_FLUSH=1 \
  sh -c 'cd "$1" && exec "$2" import --allow-stale "$3" --json' _ "$WORK/store" "$BD" "$WORK/import.jsonl" \
  >"$WORK/import.result.json" 2>"$WORK/import.err"
rc=$?
IMPORT_S=$(( $(date +%s) - start ))
if [ $rc -eq 124 ]; then unknown "bd import passou de ${IMPORT_TIMEOUT}s"; fi
if [ $rc -ne 0 ]; then
  # o motivo real vem em .error do JSON de stdout (--json); o stderr do bd só tem o contador de progresso ("250/2560 issues committed")
  why="$(jq -r '.error // empty' "$WORK/import.result.json" 2>/dev/null | head -c 400)"
  [ -n "$why" ] || why="$(tail -3 "$WORK/import.err" | tr '\n' ' ' | head -c 400)"
  echo "RESULT: FAIL db=$DB motivo=bd import rc=$rc: $why"; exit 1
fi

# ── 4. exportar de volta e fazer as contas ─────────────────────────────────────────────
sbd export >"$WORK/export.jsonl" 2>"$WORK/export.err" || unknown "bd export do store restaurado falhou: $(tail -1 "$WORK/export.err")"
STORE_MB="$(du -sk "$WORK/store/.beads" 2>/dev/null | awk '{print int($1/1024)}')"
py reconcile --db "$DB" $MAN_ARG --convert-stats "$WORK/convert.json" --imported "$WORK/import.jsonl" --exported "$WORK/export.jsonl" \
  >"$WORK/report.json" 2>"$WORK/reconcile.err"
rrc=$?
[ -s "$WORK/report.json" ] || unknown "reconcile não produziu relatório: $(head -c 300 "$WORK/reconcile.err")"
[ -n "$REPORT_OUT" ] && cp "$WORK/report.json" "$REPORT_OUT"

echo "── $DB: manifest − exclusões por desenho = esperado · restaurado ──"
jq -r '.table[] | "  \(.table): manifest=\(.manifest) − excluídos=\(.excluded_by_design) = esperado=\(.expected) · restaurado=\(.restored) (diff \(.diff))"' "$WORK/report.json"
jq -r '"  exclusões: tombstones=\(.exclusions.tombstones) órfãos=\(.exclusions.orphans) arestas-sem-alvo=\(.exclusions.dangling_dependencies) comentários-idênticos-fundidos=\(.exclusions.duplicate_comments_collapsed)"' "$WORK/report.json"
jq -r 'if (.unmapped_columns|length) > 0 then "  colunas não recebidas pelo importer (linhas com valor): \(.unmapped_columns)" else empty end' "$WORK/report.json"
jq -r '.problems[]? | "  PROBLEMA: \(.)"' "$WORK/report.json"
SUMMARY="db=$DB import_s=$IMPORT_S import_mb=$(( IMPORT_BYTES / 1048576 )) store_mb=${STORE_MB:-?} $(jq -r '[.table[] | "\(.table)=\(.restored)/\(.expected)"] | join(" ")' "$WORK/report.json") dup_comments=$(jq -r '.exclusions.duplicate_comments_collapsed' "$WORK/report.json")"
if [ $rrc -eq 0 ]; then
  echo "RESULT: OK $SUMMARY"
  exit 0
fi
echo "RESULT: FAIL $SUMMARY"
exit 1
