#!/bin/bash
# dolt-restore-lab-mbp.sh (ga-3kmvyr) — the weekly REAL restore drill of the S3 backup: the mini orchestrates, the MBP restores.
#
# Contents
#   Por quê · Uso · Manifest · Estado
#
# POR QUÊ: o flatten do hq (ga-2895yv, irreversível) depende de provar que o backup do S3 VOLTA. O laboratório (dolt-restore-lab.sh)
#   faz o restore; este script o põe no MBP (decisão do Athos 15/10: dado de beads não vai para o Hetzner) e confere o resultado
#   contra um manifest contado no MESMO commit que o restaurado. ESTA FATIA (2/4, ga-3kmvyr.2) é a metade do mini, só leitura: o
#   manifest AS OF e a lista dos objetos do S3. O envio ao MBP e o restore chegam na fatia 3/4 (ga-3kmvyr.3).
#
# USO   dolt-restore-lab-mbp.sh --dry-run [--db NAME]   monta o manifest AS OF e lista os objetos do S3 (só leitura no mini); sem MBP
#       dolt-restore-lab-mbp.sh --check                 o MBP está livre? (mbp-run.sh --check); sai 0 se livre, 4 se não
#
#   MANIFEST  _meta/latest.json diz o `head` do hq que está GARANTIDO dentro do backup (o backup lê o head ANTES do sync). A contagem de
#             cada tabela é `SELECT COUNT(*) … AS OF '<head>'` no banco vivo; o lab exige IGUALDADE no restaurado. head ausente no
#             vivo = UNKNOWN, nunca OK.
#   LISTA     os objetos do prefixo <db>/ do bucket: key<TAB>size<TAB>etag. Chave fora de [A-Za-z0-9._/-], com "..", fora do prefixo,
#             tamanho ou ETag ilegível, lista vazia ou que soma 0 bytes = UNKNOWN (nada é enviado a lugar nenhum).
#
# ESTADO  $STATE/lock · $STATE/runs/<UTC>/ (manifest.json, listing.tsv, orchestrator.log)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CITY="${LABMBP_CITY:-/Users/athos/gt/.gascity-gastown-hq}"
STATE="${LABMBP_STATE:-$CITY/.gc/dolt-restore-lab-mbp}"
MBP_RUN="${LABMBP_MBP_RUN:-$HERE/mbp-run.sh}"
AWS="${LABMBP_AWS:-aws}"; DOLT="${LABMBP_DOLT:-dolt}"; PY="${LABMBP_PY:-python3}"
DOLT_CFG="${LABMBP_DOLT_CFG:-$CITY/.gc/runtime/packs/dolt/dolt-config.yaml}"
BUCKET="${LABMBP_BUCKET:-urblink-dolt-backups}"

# tudo que sai do mini rumo ao MBP (mbp-run) roda SEM nenhuma variável AWS_* do ambiente: só o aws do mini enxerga a credencial
NOAWS=(env); for v in $(env | cut -d= -f1 | grep '^AWS_'); do NOAWS+=(-u "$v"); done
DB="hq"; MODE=run
LOCKED=0; WHY=""; RUN=""; OUT=""
NOBJ="?"; TOTAL_KB="?"

log() { printf '%s [lab-mbp] %s\n' "$(date '+%F %T')" "$*"; [ -z "$RUN" ] || printf '%s %s\n' "$(date '+%T')" "$*" >> "$RUN/orchestrator.log"; }
isnum() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# Um ajudante Python só (JSON/CSV sem jq). Qualquer exceção sai com status != 0: quem chama trata como "ilegível".
read -r -d '' PYHELP <<'PY' || true
import csv, json, re, sys
mode = sys.argv[1]
H = re.compile(r"[0-9a-v]{32}\Z"); N = re.compile(r"[A-Za-z0-9_]+\Z")
if mode == "meta":                      # stdin = latest.json; argv[2] = db  → run_utc<TAB>head
    d = json.load(sys.stdin); ru = d["run_utc"]; hd = d["databases"][sys.argv[2]]["head"]
    assert isinstance(ru, str) and ru and isinstance(hd, str) and H.match(hd)
    print("%s\t%s" % (ru, hd))
elif mode == "union":                   # stdin = SHOW FULL TABLES AS OF (csv); argv[2] = head → um SELECT com a contagem de cada tabela
    assert H.match(sys.argv[2]); names = []
    for r in list(csv.reader(sys.stdin))[1:]:
        if r[1] == "BASE TABLE":
            assert N.match(r[0]); names.append(r[0])
    assert names
    print(" UNION ALL ".join("SELECT '%s' AS t, COUNT(*) AS n FROM `%s` AS OF '%s'" % (n, n, sys.argv[2]) for n in names))
elif mode == "manifest":                # stdin = t,n (csv); argv[2] = db, argv[3] = head
    t = {}
    for r in list(csv.reader(sys.stdin))[1:]:
        assert N.match(r[0]) and r[1].isdigit(); t[r[0]] = int(r[1])
    assert t and H.match(sys.argv[3])
    print(json.dumps({"schema": 1, "db": sys.argv[2], "as_of": sys.argv[3], "tables": t}, sort_keys=True))
elif mode == "listing":                 # stdin = `s3api list-objects-v2 --output text` (key, size, "etag"); argv[2] = prefix ("hq/") → key<TAB>size<TAB>etag
    K = re.compile(r"[A-Za-z0-9._/-]+\Z"); E = re.compile(r"[0-9a-f]{32}(-[0-9]+)?\Z"); rows = []
    for ln in sys.stdin.read().splitlines():
        k, s, e = ln.split("\t"); e = e.strip('"')
        assert K.match(k) and k.startswith(sys.argv[2]) and ".." not in k.split("/") and s.isdigit() and E.match(e)
        rows.append("%s\t%s\t%s" % (k, s, e))
    assert rows
    print("\n".join(rows))
PY

cleanup() { [ "$LOCKED" -eq 0 ] || rm -rf "$STATE/lock"; }
trap cleanup EXIT
trap 'exit 143' INT TERM HUP

usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d' | cut -c3-; }

take_lock() {
  mkdir -p "$STATE" || return 2
  if mkdir "$STATE/lock" 2>/dev/null; then echo "$$" > "$STATE/lock/pid"; LOCKED=1; return 0; fi
  local p; p=$(cat "$STATE/lock/pid" 2>/dev/null)
  if isnum "$p"; then
    if kill -0 "$p" 2>/dev/null; then log "outra rodada em curso (pid $p): nada a fazer"; return 1; fi
  # pid vazio/ilegível ≠ morto: só recolhe a trava velha (12 h, mais que o teto de uma rodada); a recente é de quem acabou de criá-la
  elif [ -z "$(find "$STATE/lock" -maxdepth 0 -mmin +720 2>/dev/null)" ]; then log "trava sem pid legivel e recente ($STATE/lock): nada a fazer"; return 1; fi
  log "trava de pid morto/antiga recolhida"; rm -rf "$STATE/lock"
  mkdir "$STATE/lock" 2>/dev/null || { log "outra rodada pegou a trava"; return 1; }
  echo "$$" > "$STATE/lock/pid"; LOCKED=1; return 0
}

# --- o MBP está livre? presence=livre explícito; qualquer outra coisa (uso, vazio, inalcançável, pausa) é "não" ------------------
mbp_free() {
  local o; o=$("${NOAWS[@]}" "$MBP_RUN" --host mbp --check 2>&1)
  if printf '%s\n' "$o" | grep -q '^presence=livre$'; then WHY=""; return 0; fi
  WHY=$(printf '%s\n' "$o" | grep -v -E '^[a-z_]+=' | head -1)
  WHY="${WHY:-MBP sem presence=livre}; presence=$(printf '%s\n' "$o" | sed -n 's/^presence=//p' | head -1)"; return 1
}

# --- consulta ao banco VIVO do mini (só leitura) ---------------------------------------------------------------------------
PORT=""
q() { DOLT_CLI_PASSWORD='' "$DOLT" --host 127.0.0.1 --port "$PORT" --user root --no-tls --use-db "$DB" sql -r csv -q "$1"; }

# Monta $RUN/manifest.json AS OF o head do latest.json. Deixa AS_OF, FP1 e NTAB. Falha com WHY (rc 1 = UNKNOWN).
build_manifest() {
  local meta line n tabs sql
  meta=$("$AWS" s3 cp "s3://$BUCKET/_meta/latest.json" - 2>"$RUN/aws.err") || { WHY="nao li _meta/latest.json: $(head -c 200 "$RUN/aws.err")"; return 1; }
  line=$(printf '%s' "$meta" | "$PY" -I -c "$PYHELP" meta "$DB" 2>/dev/null) || { WHY="_meta/latest.json sem run_utc/head valido para $DB"; return 1; }
  FP1="${line%%$'\t'*}"; AS_OF="${line#*$'\t'}"
  PORT=$(awk '/^listener:/{f=1} f&&/port:/{print $2; exit}' "$DOLT_CFG" 2>/dev/null)
  isnum "$PORT" || { WHY="porta do dolt ilegivel em $DOLT_CFG"; return 1; }
  n=$(q "SELECT COUNT(*) FROM dolt_log WHERE commit_hash = '$AS_OF'" 2>"$RUN/dolt.err" | tail -1)
  isnum "$n" || { WHY="nao consegui perguntar ao dolt vivo se o commit existe: $(head -c 200 "$RUN/dolt.err")"; return 1; }
  [ "$n" -ge 1 ] || { WHY="o commit $AS_OF do latest.json NAO existe no banco vivo (reescrito/flatten?): sem manifest exato, sem veredito"; return 1; }
  tabs=$(q "SHOW FULL TABLES AS OF '$AS_OF'" 2>"$RUN/dolt.err") || { WHY="SHOW TABLES AS OF falhou: $(head -c 200 "$RUN/dolt.err")"; return 1; }
  sql=$(printf '%s\n' "$tabs" | "$PY" -I -c "$PYHELP" union "$AS_OF" 2>/dev/null) || { WHY="lista de tabelas vazia ou com nome fora de [A-Za-z0-9_]"; return 1; }
  q "$sql" 2>"$RUN/dolt.err" | "$PY" -I -c "$PYHELP" manifest "$DB" "$AS_OF" > "$RUN/manifest.json" 2>/dev/null \
    && [ -s "$RUN/manifest.json" ] || { WHY="contagem AS OF falhou: $(head -c 200 "$RUN/dolt.err")"; return 1; }
  NTAB=$("$PY" -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["tables"]))' "$RUN/manifest.json" 2>/dev/null) || NTAB="?"
}

# A lista do que vai ser enviado: key<TAB>size<TAB>etag em $RUN/listing.tsv. Deixa NOBJ e TOTAL_KB. Vazia/ilegível → falha com WHY.
list_objects() {
  local raw
  raw=$("$AWS" s3api list-objects-v2 --bucket "$BUCKET" --prefix "$DB/" --query 'Contents[].[Key,Size,ETag]' --output text 2>"$RUN/aws.err") \
    || { WHY="nao consegui listar s3://$BUCKET/$DB/: $(head -c 200 "$RUN/aws.err")"; return 1; }
  printf '%s\n' "$raw" | "$PY" -I -c "$PYHELP" listing "$DB/" > "$RUN/listing.tsv" 2>/dev/null && [ -s "$RUN/listing.tsv" ] \
    || { WHY="a lista de s3://$BUCKET/$DB/ veio vazia ou fora do formato (chave fora de [A-Za-z0-9._/-], tamanho ou ETag ilegivel)"; return 1; }
  NOBJ=$(grep -c . "$RUN/listing.tsv"); TOTAL_KB=$(awk -F'\t' '{ s += $2 } END { printf "%d", (s + 1023) / 1024 }' "$RUN/listing.tsv")
  isnum "$TOTAL_KB" && [ "$TOTAL_KB" -gt 0 ] || { WHY="a lista de s3://$BUCKET/$DB/ soma 0 bytes"; return 1; }
}

finish() {  # $1 = rc final; resumo + RESULT
  local rc="$1"
  log "RESULT: ${VERDICT:-UNKNOWN} db=$DB rc=$rc as_of=${AS_OF:-?} tabelas=${NTAB:-?} objetos=$NOBJ run=${RUN:-?}"; [ -z "$WHY" ] || log "motivo: $WHY"
  exit "$rc"
}
unknown() { VERDICT=UNKNOWN; WHY="$*"; finish 2; }

main() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) MODE=dry ;; --check) MODE=check ;;
      --db) [ "$#" -ge 2 ] || { echo "--db precisa de um valor" >&2; exit 2; }; DB="$2"; shift ;;
      -h|--help|help) usage; exit 0 ;; *) echo "opcao desconhecida: $1" >&2; exit 2 ;;
    esac
    shift
  done
  case "$DB" in ''|*[!A-Za-z0-9_]*) echo "--db invalido: $DB" >&2; exit 2 ;; esac
  [ "$MODE" != run ] || { echo "o restore no MBP chega na fatia 3/4 (ga-3kmvyr.3); por ora: --dry-run ou --check" >&2; exit 2; }
  if [ "$MODE" = check ]; then mbp_free && { log "MBP livre"; exit 0; }; log "MBP nao livre: $WHY"; exit 4; fi

  take_lock; case $? in 0) ;; 1) exit 0 ;; *) unknown "nao consegui criar $STATE" ;; esac   # 1 = outra rodada (nada a fazer); 2 = sem estado, nao e 'nada a fazer'
  RUN="$STATE/runs/$(date -u +%Y%m%dT%H%M%SZ)"; OUT="$RUN/out"
  mkdir -p "$OUT" || unknown "nao consegui criar $RUN"
  build_manifest || unknown "$WHY"
  list_objects || unknown "$WHY"
  log "manifest AS OF $AS_OF ($NTAB tabelas, run_utc=$FP1):"; cat "$RUN/manifest.json"
  log "lista do S3: $NOBJ objetos, ${TOTAL_KB}KB (nada foi enviado)"; VERDICT=DRY; finish 0
}

if [ "${LABMBP_LIB:-0}" != "1" ]; then main "$@"; fi
