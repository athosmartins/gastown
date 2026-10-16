#!/bin/bash
# dolt-restore-lab-mbp.sh (ga-3kmvyr) — the weekly REAL restore drill of the S3 backup: the mini orchestrates, the MBP restores.
#
# Contents
#   Por quê · Uso · Fluxo · Sem credencial no MBP · Veredito e códigos de saída · Estado
#
# POR QUÊ: o flatten do hq (ga-2895yv, irreversível) depende de provar que o backup do S3 VOLTA. O laboratório (dolt-restore-lab.sh)
#   faz o restore; este script o põe no MBP (decisão do Athos 15/10: dado de beads não vai para o Hetzner) e confere o resultado
#   contra um manifest contado no MESMO commit que o restaurado.
#
# USO   dolt-restore-lab-mbp.sh [run] [--db NAME] [--force] [--no-notify]
#       dolt-restore-lab-mbp.sh --dry-run [--db NAME]   monta o manifest AS OF e lista os objetos do S3 (só leitura no mini); sem MBP
#       dolt-restore-lab-mbp.sh --check                 o MBP está livre? (mbp-run.sh --check); sai 0 se livre, 4 se não
#       dolt-restore-lab-mbp.sh --install-dolt          copia o dolt REAL do mini para ~/gt-remote/lab/bin/ do MBP (mesma versão)
#
# FLUXO  trava → "já rodou esta semana?" → o MBP está livre? (presence=livre) → manifest AS OF → lista dos objetos do S3 → push do
#        stage → o wrapper do MBP diz "ready" → o mini LÊ cada objeto do S3 e o ENVIA ao slot por ssh → o MBP confere a cópia contra a
#        lista → lab (file://) → pull de out/ → veredito → higiene → resumo → notify. Cada rodada: $STATE/runs/<UTC>-<pid>/.
#   MANIFEST  _meta/latest.json diz o `head` do hq que está GARANTIDO dentro do backup (o backup lê o head ANTES do sync). A contagem de
#             cada tabela é `SELECT COUNT(*) … AS OF '<head>'` no banco vivo; o lab exige IGUALDADE no restaurado. head ausente no
#             vivo = UNKNOWN, nunca OK.
#   ENVIO     um objeto por vez: `aws s3 cp s3://… -` | filtro Python (conta bytes e calcula o ETag) | `ssh MBP 'cat > slot/in/lab-src/…'`.
#             Nada é gravado no disco do mini. Cada objeto tem de fechar com a lista: bytes lidos = bytes gravados no MBP = Size da
#             lista, e o ETag (md5 do objeto; o composto de partes de 8 MiB quando o ETag tem "-N"). ETag composto cuja contagem de partes
#             NÃO é a de partes de 8 MiB (upload com outro tamanho de parte) não é recalculável: só o tamanho vale, e o resumo conta
#             quantos ("etag_nao_verificavel"). ETag que era recalculável e não fecha = UNKNOWN.
#             Falha/tamanho/ETag diferente → uma nova tentativa do objeto; falhou de novo → UNKNOWN. NUNCA restore sobre cópia parcial:
#             o wrapper só roda o lab depois de achar no disco do MBP exatamente os objetos da lista, com os tamanhos dela.
#   CORRIDA   o `run_utc` do latest.json é lido antes e depois: se andou no meio, um FAIL vira UNKNOWN (o backup foi reescrito
#             durante o envio; não é observação conclusiva). Um OK/SLOW fica (igualdade exata num commit é prova por si).
#
# SEM CREDENCIAL NO MBP (Mayor 16/10): só o mini lê o S3, com a credencial dele (cadeia padrão do aws; nada de `--env`, nada de
#   arquivo, nada de sts). O MBP recebe BYTES. Prova de higiene, só CONTAGENS (vazio/ilegível = "?", nunca 0): variáveis AWS_* do ambiente
#   da sessão remota, amostras de `ps` do MBP e arquivos do slot com cara de credencial AWS (AKIA…/ASIA…/AWS_*=), mais os arquivos do stage
#   e do estado no mini.
#
# VEREDITO  vem do report.json do lab, conferido com o rc do mbp-run (divergência = UNKNOWN). Relatório ausente = UNKNOWN.
#   0 OK · 1 FAIL · 2 UNKNOWN · 3 SLOW (as mesmas palavras do lab) · 4 ADIADO (MBP em uso/inalcançável/pausado ANTES de começar;
#   a próxima janela tenta de novo). Às LABMBP_FINAL_HOUR h (2) em diante o adiamento vira UNKNOWN: última janela da noite.
#   notify só em rc 1/2/3 (e se a higiene achar credencial onde ela não pode estar). O RTO (LABMBP_RTO_S) vale para restore+contagem; o
#   tempo do envio mini→MBP (stream_s) é medido à parte: é o do relay, maior que o de uma busca direta do S3.
#
# TETOS   todo dolt/aws do mini roda sob timeout/gtimeout (LABMBP_CALL_S, 900 s; o envio de cada objeto, no que sobra de LABMBP_STREAM_S, mínimo LABMBP_OBJ_MIN_S=30 s);
#         pendurado = UNKNOWN, e sem timeout no PATH também. Rodada pulada (já rodou, outra em curso) imprime `RESULT: SKIPPED` e sai 0.
#
# ESTADO  $STATE/lock (+ lock.reclaim, o mutex de quem recolhe uma trava velha) · last-attempt (epoch; a rodada COMEÇOU, 12 h) · last-final (epoch; OK/FAIL/SLOW,
#         LABMBP_RECENT_DAYS=6 dias) · $STATE/runs/<UTC>-<pid>/ (manifest.json, listing.tsv, orchestrator.log, summary.txt, out/)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CITY="${LABMBP_CITY:-/Users/athos/gt/.gascity-gastown-hq}"
STATE="${LABMBP_STATE:-$CITY/.gc/dolt-restore-lab-mbp}"
MBP_RUN="${LABMBP_MBP_RUN:-$HERE/mbp-run.sh}"
AWS="${LABMBP_AWS:-aws}"; DOLT="${LABMBP_DOLT:-dolt}"; PY="${LABMBP_PY:-python3}"
NOTIFY="${LABMBP_NOTIFY:-/Users/athos/.local/bin/notify}"
DOLT_CFG="${LABMBP_DOLT_CFG:-$CITY/.gc/runtime/packs/dolt/dolt-config.yaml}"
BUCKET="${LABMBP_BUCKET:-urblink-dolt-backups}"
TMO=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)   # todo dolt/aws roda sob timeout: um dolt pendurado segurava a trava
CALL_S="${LABMBP_CALL_S:-900}"; OBJ_MIN_S="${LABMBP_OBJ_MIN_S:-30}"   # teto por chamada; piso do teto de cada objeto do envio
# o ssh do envio usa o MESMO host e as MESMAS opções do mbp-run.sh (a conexão mestre é reaproveitada)
SSH="${MBP_SSH:-ssh}"; SSH_HOST="${MBP_HOST:-athos@athoss-macbook-pro.local}"
SSH_OPTS="${LABMBP_SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o ControlMaster=auto -o ControlPath=$HOME/.ssh/cm/%C -o ControlPersist=60}"
RTO="${LABMBP_RTO_S:-3600}"                  # orçamento restore+contagem; passou = SLOW. Chute até a 1ª medição (runbook).
JOB_TIMEOUT="${LABMBP_JOB_TIMEOUT_S:-12600}" # teto do mbp-run para envio+restore+contagem (o slot dele envelhece em 4 h)
STREAM_S="${LABMBP_STREAM_S:-7200}"          # teto do envio (o wrapper espera o mesmo tanto); READY_S = espera pelo "ready" do wrapper
READY_S="${LABMBP_READY_S:-900}"; POLL_S="${LABMBP_POLL_S:-1}"; RETRY_S="${LABMBP_RETRY_S:-2}"; MARGIN="${LABMBP_MARGIN_PCT:-400}"
RECENT_DAYS="${LABMBP_RECENT_DAYS:-6}"; FINAL_HOUR="${LABMBP_FINAL_HOUR:-2}"
SHAPE='[A]KIA[0-9A-Z]{16}|[A]SIA[0-9A-Z]{16}|[A]WS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY|SESSION_TOKEN)=|[a]ws_(access_key_id|secret_access_key|session_token)'
# tudo que sai do mini rumo ao MBP (mbp-run, ssh) roda SEM nenhuma variável AWS_* do ambiente: só o aws do mini enxerga a credencial
NOAWS=(env); for v in $(env | cut -d= -f1 | grep '^AWS_'); do NOAWS+=(-u "$v"); done
DB="hq"; FORCE=0; NOTIFY_ON=1; MODE=run
STAGE=""; BG=""; SLOTDIR=""; STREAMING=0; LOCKED=0; RECL=0; WHY=""; RUN=""; OUT=""
NOBJ="?"; NETAG_OK="?"; NETAG_UNV="?"; STREAM_T="?"; TOTAL_KB="?"; STREAM_T0=0

now() { date +%s; }
log() { printf '%s [lab-mbp] %s\n' "$(date '+%F %T')" "$*"; [ -z "$RUN" ] || printf '%s %s\n' "$(date '+%T')" "$*" >> "$RUN/orchestrator.log"; }
isnum() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
# Formas conferidas AQUI, na variavel que e usada (a do SQL), e nao so no ajudante: listas explicitas, sem faixa — a faixa a-v depende do locale no bash 3.2.
ishead() { case "${1:-}" in ''|*[!0123456789abcdefghijklmnopqrstuv]*) return 1 ;; esac; [ "${#1}" -eq 32 ]; }
isutc() { case "${1:-}" in ''|*[!0123456789TZ:-]*) return 1 ;; esac; [ "${#1}" -eq 20 ]; }

# Um ajudante Python só (JSON/CSV sem jq). Qualquer exceção sai com status != 0: quem chama trata como "ilegível".
read -r -d '' PYHELP <<'PY' || true
import csv, hashlib, json, re, sys
mode = sys.argv[1]
# tudo que vem do S3 e NAO CONFIAVEL: so ASCII, ancorado no fim com \Z ($ aceitaria um \n final; \d e str.isdigit() aceitam digitos Unicode)
H = re.compile(r"[0-9a-v]{32}\Z"); N = re.compile(r"[A-Za-z0-9_]+\Z"); D = re.compile(r"[0-9]+\Z")
U = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\Z")
if mode == "meta":                      # stdin = latest.json; argv[2] = db  → run_utc<TAB>head (a linha e partida no TAB: nenhum campo pode ter um)
    d = json.load(sys.stdin); ru = d["run_utc"]; hd = d["databases"][sys.argv[2]]["head"]
    assert isinstance(ru, str) and U.match(ru) and isinstance(hd, str) and H.match(hd)
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
        assert N.match(r[0]) and D.match(r[1]); t[r[0]] = int(r[1])
    assert t and H.match(sys.argv[3])
    print(json.dumps({"schema": 1, "db": sys.argv[2], "as_of": sys.argv[3], "tables": t}, sort_keys=True))
elif mode == "listing":                 # stdin = `s3api list-objects-v2 --output text` (key, size, "etag"); argv[2] = prefix ("hq/") → key<TAB>size<TAB>etag
    K = re.compile(r"[A-Za-z0-9._/-]+\Z"); E = re.compile(r"[0-9a-f]{32}(-[0-9]+)?\Z"); rows = []
    for ln in sys.stdin.read().splitlines():
        k, s, e = ln.split("\t"); e = e.strip('"')
        assert K.match(k) and k.startswith(sys.argv[2]) and ".." not in k.split("/") and D.match(s) and E.match(e)
        rows.append("%s\t%s\t%s" % (k, s, e))
    assert rows
    print("\n".join(rows))
elif mode == "pass":                    # stdin → stdout, intacto; argv[2] = arquivo que recebe "bytes etag" (md5 por parte de 8 MiB, como o aws cli grava)
    P = 8 * 1024 * 1024; inp = sys.stdin.buffer; out = sys.stdout.buffer; digs = []; n = 0
    while True:
        c = inp.read(P)
        if not c: break
        digs.append(hashlib.md5(c).digest()); n += len(c); out.write(c)
    out.flush()
    e = hashlib.md5(b"").hexdigest() if not digs else digs[0].hex() if len(digs) == 1 else "%s-%d" % (hashlib.md5(b"".join(digs)).hexdigest(), len(digs))
    open(sys.argv[2], "w").write("%d %s\n" % (n, e))
elif mode == "report":                  # argv[2] = report.json → verdict rc total_s source_kb restored_kb fetch_s restore_s count_s reason
    r = json.load(open(sys.argv[2])); V = re.compile(r"(OK|FAIL|SLOW|UNKNOWN|[0-9]+(\.[0-9]+)?)\Z")   # relatorio vem do MBP: so numero ou veredito conhecido chega ao RESULT; o resto e "?"
    g = lambda k: str(r[k]) if r.get(k) is not None and V.match(str(r[k])) else "?"
    why = str(r.get("reason") or "")[:300].replace("\t", " ").replace("\n", " ")
    print("\t".join([g(k) for k in ("verdict", "rc", "total_s", "source_kb", "restored_kb", "fetch_s", "restore_s", "count_s")] + [why]))
elif mode == "tables":                  # argv[2] = report.json → "table=T expected=N restored=M" (contagens, nunca linhas)
    for k, v in sorted((json.load(open(sys.argv[2])).get("tables") or {}).items()):
        print("table=%s expected=%s restored=%s" % (k, v.get("expected"), v.get("restored")))
PY

mark() { # $1 = nome do arquivo no slot do MBP (stream.done|stream.failed); melhor esforço, curto
  [ -n "$SLOTDIR" ] || return 0
  "${NOAWS[@]}" "$SSH" $SSH_OPTS "$SSH_HOST" "printf x > '$SLOTDIR/$1'" </dev/null >/dev/null 2>&1 || true
}
cleanup() {
  [ "$STREAMING" -eq 0 ] || mark stream.failed
  [ -z "$BG" ] || kill "$BG" 2>/dev/null
  [ -z "$STAGE" ] || rm -rf "$STAGE" 2>/dev/null
  [ "$LOCKED" -eq 0 ] || rm -rf "$STATE/lock"
  [ "$RECL" -eq 0 ] || rmdir "$STATE/lock.reclaim" 2>/dev/null
}
trap cleanup EXIT
# SIGTERM/INT/HUP: o bash so roda este trap quando o filho em primeiro plano (dolt/aws sob timeout) termina, entao um kill espera ate CALL_S;
# um kill -9 nao roda trap nenhum e deixa a trava para o proximo recolher (pid morto) — nada fica preso para sempre.
trap 'exit 143' INT TERM HUP

usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d' | cut -c3-; }

# A trava existente pode ser recolhida? 0 = sim (sumiu, pid morto ou velha) · 1 = nao (WHY diz por que). Le o estado de AGORA, nao um valor guardado.
lock_stale() {
  local p; p=$(cat "$STATE/lock/pid" 2>/dev/null)
  [ -d "$STATE/lock" ] || return 0
  # 12 h = mais que o teto de uma rodada: a trava mais velha e de uma rodada que morreu, mesmo que o pid exista (pid reaproveitado apos reboot)
  [ -z "$(find "$STATE/lock" -maxdepth 0 -mmin +720 2>/dev/null)" ] || return 0
  if isnum "$p"; then   # kill -0 da EPERM para pid de outro usuario: ps -p nao
    if kill -0 "$p" 2>/dev/null || ps -p "$p" >/dev/null 2>&1; then WHY="outra rodada em curso (pid $p): nada a fazer"; return 1; fi
    return 0
  fi
  WHY="trava sem pid legivel e recente ($STATE/lock): nada a fazer"; return 1   # pid vazio/ilegivel nao e morto: e de quem acabou de criar
}

# Uma rodada por vez. 0 = trava tomada · 1 = outra rodada em curso (WHY diz qual) · 2 = nao deu para criar a trava (NAO e "nada a fazer").
# Recolher trava velha e o unico passo que apaga a trava de OUTRA rodada: um recolhedor por vez (mutex lock.reclaim), velhice conferida DE NOVO la dentro.
take_lock() {
  mkdir -p "$STATE" || return 2
  local m="$STATE/lock.reclaim" rc=0
  if ! mkdir "$STATE/lock" 2>/dev/null; then
    [ -d "$STATE/lock" ] || return 2   # mkdir falhou e nao ha trava (EACCES/EROFS/ENOSPC): nao e "outra rodada em curso"
    lock_stale || return 1
    [ -z "$(find "$m" -maxdepth 0 -mmin +10 2>/dev/null)" ] || rmdir "$m" 2>/dev/null || [ ! -d "$m" ] || return 2   # mutex de 10 min+ = de quem morreu dentro dele (ms); que nao sai = rc 2. Dois recolhedores quebrando o MESMO mutex morto juntos ainda se atropelam: dupla falha rara
    mkdir "$m" 2>/dev/null || { [ -d "$m" ] || return 2; WHY="outra rodada esta recolhendo a trava velha: nada a fazer"; return 1; }; RECL=1   # sem mutex NEM dir: erro, nao "outra rodada"
    if lock_stale; then log "trava de pid morto/antiga recolhida"
      if ! rm -rf "$STATE/lock" 2>/dev/null; then WHY="nao consegui apagar a trava velha $STATE/lock"; rc=2   # trava velha que nao sai nao e "outra rodada pegou"
      elif mkdir "$STATE/lock" 2>/dev/null; then LOCKED=1; echo "$$" > "$STATE/lock/pid" || rc=2   # LOCKED antes: pid que nao grava, o cleanup apaga a trava
      elif [ -d "$STATE/lock" ]; then WHY="outra rodada pegou a trava"; rc=1; else rc=2; fi
    else rc=1; fi
    rmdir "$m" 2>/dev/null; RECL=0; return "$rc"
  fi
  LOCKED=1; echo "$$" > "$STATE/lock/pid" || return 2
}

# arquivo de epoch com idade < $2 segundos? ausente/ilegível → NÃO (rodar é o lado seguro: a rodada não perde a semana por causa disso)
fresh() { local t; t=$(cat "$STATE/$1" 2>/dev/null); isnum "$t" && [ $(( $(now) - t )) -lt "$2" ]; }

# --- o MBP esta livre? So se o mbp-run --check sai 0 E CADA chave abaixo esta na saida com o valor de "livre": presence=livre paused=0 paused_local=0
# offload_flag=on. A presenca e independente da pausa e da saude (um MBP que RECUSA ainda imprime presence=livre) e o offload desligado
# (mbp-offload off => o --exec sai 99) so aparece na linha offload_flag=, nunca no rc. Linha ausente/vazia/outra = nao provada = "nao".
mbp_free() {
  local o rc kv k v seen="" bad=0 nl=$'\n'; o=$("${NOAWS[@]}" "$MBP_RUN" --host mbp --check 2>&1); rc=$?
  for kv in presence=livre paused=0 paused_local=0 offload_flag=on; do   # sem pipe: um grep -q que sai cedo faz o printf morrer de SIGPIPE e o `!` le "ausente"
    k=${kv%%=*}; v=$nl$o$nl; case "$v" in *"$nl$k="*) v=${v#*"$nl$k="}; v=${v%%"$nl"*} ;; *) v="?" ;; esac   # 1a linha k=...; ausente = ?
    seen="$seen $k=$v"; [ "$v" = "${kv#*=}" ] || bad=1
  done
  if [ "$rc" -eq 0 ] && [ "$bad" -eq 0 ]; then WHY=""; return 0; fi
  WHY=$(printf '%s\n' "$o" | grep -v -E '^[a-z_]+=' | head -1); WHY="${WHY:-MBP nao provou estar livre}; rc=$rc$seen"; return 1
}

# --- consulta ao banco VIVO do mini (só leitura) ---------------------------------------------------------------------------
PORT=""
bounded() { local rc; "$TMO" -k 10 "$CALL_S" "$@"; rc=$?; [ "$rc" -ne 124 ] || echo "sem resposta em ${CALL_S}s (timeout): ${1##*/}" >&2; return "$rc"; }
q() { DOLT_CLI_PASSWORD='' bounded "$DOLT" --host 127.0.0.1 --port "$PORT" --user root --no-tls --use-db "$DB" sql -r csv -q "$1"; }

# Monta $RUN/manifest.json AS OF o head do latest.json. Deixa AS_OF, FP1 e NTAB. Falha com WHY (rc 1 = UNKNOWN).
build_manifest() {
  local meta line n tabs sql cnt
  meta=$(bounded "$AWS" s3 cp "s3://$BUCKET/_meta/latest.json" - 2>"$RUN/aws.err") || { WHY="nao li _meta/latest.json: $(head -c 200 "$RUN/aws.err")"; return 1; }
  line=$(printf '%s' "$meta" | "$PY" -I -c "$PYHELP" meta "$DB" 2>/dev/null) || { WHY="_meta/latest.json sem run_utc/head valido para $DB"; return 1; }
  FP1="${line%%$'\t'*}"; AS_OF="${line#*$'\t'}"
  # o que decide e o que age sao a mesma variavel: AS_OF vai DENTRO do SQL, entao e conferido aqui, mesmo que o ajudante tenha aprovado
  ishead "$AS_OF" && isutc "$FP1" || { WHY="_meta/latest.json sem run_utc/head valido para $DB (forma inesperada)"; return 1; }
  PORT=$(awk '/^listener:/{f=1; next} f && /^[^ \t#]/{exit} f && /^[ \t]+port:/{print $2; exit}' "$DOLT_CFG" 2>/dev/null)   # so a porta do bloco listener:
  isnum "$PORT" || { WHY="porta do dolt ilegivel em $DOLT_CFG"; return 1; }
  n=$(q "SELECT COUNT(*) FROM dolt_log WHERE commit_hash = '$AS_OF'" 2>"$RUN/dolt.err" | tail -1)
  isnum "$n" || { WHY="nao consegui perguntar ao dolt vivo se o commit existe: $(head -c 200 "$RUN/dolt.err")"; return 1; }
  [ "$n" -ge 1 ] || { WHY="o commit $AS_OF do latest.json NAO existe no banco vivo (reescrito/flatten?): sem manifest exato, sem veredito"; return 1; }
  tabs=$(q "SHOW FULL TABLES AS OF '$AS_OF'" 2>"$RUN/dolt.err") || { WHY="SHOW TABLES AS OF falhou: $(head -c 200 "$RUN/dolt.err")"; return 1; }
  sql=$(printf '%s\n' "$tabs" | "$PY" -I -c "$PYHELP" union "$AS_OF" 2>/dev/null) || { WHY="lista de tabelas vazia ou com nome fora de [A-Za-z0-9_]"; return 1; }
  cnt=$(q "$sql" 2>"$RUN/dolt.err") && printf '%s\n' "$cnt" | "$PY" -I -c "$PYHELP" manifest "$DB" "$AS_OF" > "$RUN/manifest.json" 2>/dev/null \
    && [ -s "$RUN/manifest.json" ] || { rm -f "$RUN/manifest.json"; WHY="contagem AS OF falhou: $(head -c 200 "$RUN/dolt.err")"; return 1; }   # dolt que morre no meio: nenhum manifest parcial fica com cara de valido
  NTAB=$("$PY" -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["tables"]))' "$RUN/manifest.json" 2>/dev/null) || NTAB="?"
}

# A lista do que vai ser enviado: key<TAB>size<TAB>etag em $RUN/listing.tsv. Deixa NOBJ e TOTAL_KB. Vazia/ilegível → falha com WHY.
list_objects() {
  local raw
  raw=$(bounded "$AWS" s3api list-objects-v2 --bucket "$BUCKET" --prefix "$DB/" --query 'Contents[].[Key,Size,ETag]' --output text 2>"$RUN/aws.err") \
    || { WHY="nao consegui listar s3://$BUCKET/$DB/: $(head -c 200 "$RUN/aws.err")"; return 1; }
  printf '%s\n' "$raw" | "$PY" -I -c "$PYHELP" listing "$DB/" > "$RUN/listing.tsv" 2>/dev/null && [ -s "$RUN/listing.tsv" ] \
    || { WHY="a lista de s3://$BUCKET/$DB/ veio vazia ou fora do formato (chave fora de [A-Za-z0-9._/-], tamanho ou ETag ilegivel)"; return 1; }
  NOBJ=$(grep -c . "$RUN/listing.tsv"); TOTAL_KB=$(awk -F'\t' '{ s += $2 } END { printf "%d", (s + 1023) / 1024 }' "$RUN/listing.tsv")
  isnum "$TOTAL_KB" && [ "$TOTAL_KB" -gt 0 ] || { WHY="a lista de s3://$BUCKET/$DB/ soma 0 bytes"; return 1; }
}

# --- o envio. Um objeto: S3 → filtro (conta bytes, calcula ETag) → ssh cat. Deixa WHY quando falha. ------------------------------
stream_one() {  # $1 key  $2 size  $3 etag
  local key="$1" size="$2" etag="$3" dest got getag lim rc
  dest="$SLOTDIR/in/lab-src/${key#"$DB"/}"; rm -f "$RUN/obj.sum"
  lim=$(( STREAM_S - ($(now) - STREAM_T0) )); [ "$lim" -ge "$OBJ_MIN_S" ] || lim="$OBJ_MIN_S"   # o que sobra do teto do envio: um aws cp pendurado nao segura a rodada
  got=$(nice -n 10 "$TMO" -k 10 "$lim" "$AWS" s3 cp "s3://$BUCKET/$key" - 2>"$RUN/aws.err" </dev/null | nice -n 10 "$PY" -I -c "$PYHELP" pass "$RUN/obj.sum" 2>>"$RUN/aws.err" \
        | "${NOAWS[@]}" "$SSH" $SSH_OPTS "$SSH_HOST" "[ -d '$SLOTDIR/in/lab-src' ] && mkdir -p '${dest%/*}' && cat > '$dest' && wc -c < '$dest'" 2>>"$RUN/aws.err") \
    || { rc=$?; [ "$rc" -ne 124 ] || echo "aws s3 cp sem resposta em ${lim}s (timeout)" >> "$RUN/aws.err"
         WHY="objeto $key: o envio falhou ($(tr '\n' ' ' < "$RUN/aws.err" | head -c 200))"; return 1; }
  got=$(printf '%s' "$got" | tr -d ' \n')
  [ "$got" = "$size" ] || { WHY="objeto $key: o MBP gravou ${got:-?} bytes, a lista do S3 diz $size"; return 1; }
  # o filtro repassa os bytes intactos: "bytes gravados no MBP = Size" ja prova os bytes lidos; dele so se usa o ETag
  read -r _ getag < "$RUN/obj.sum" 2>/dev/null || { WHY="objeto $key: sem a soma de conferencia do filtro"; return 1; }
  if [ "$getag" = "$etag" ]; then NETAG_OK=$((NETAG_OK + 1))
  else case "$etag" in
    # composto: se a contagem de partes é a de partes de 8 MiB e a soma não fecha, o objeto veio errado; se a contagem é outra, o upload
    # usou outro tamanho de parte, o ETag não é recalculável e só o tamanho vale (o resumo conta quantos)
    *-*) if [ "${etag##*-}" = "$(( (size + 8388607) / 8388608 ))" ]; then WHY="objeto $key: ETag composto $getag, a lista diz $etag (o objeto mudou ou veio corrompido)"; return 1; fi
         NETAG_UNV=$((NETAG_UNV + 1)) ;;
    *) WHY="objeto $key: ETag $getag, a lista diz $etag (o objeto mudou ou veio corrompido)"; return 1 ;;
  esac; fi
}
job_gone() { [ -e "$STAGE/mbprc" ] || return 1; WHY="o job no MBP terminou antes do fim do envio (mbp-run rc=$(cat "$STAGE/mbprc" 2>/dev/null))"; }
stream_all() {  # lê $RUN/listing.tsv; deixa NOBJ_SENT e STREAM_T
  local key size etag t0 n=0; NETAG_OK=0; NETAG_UNV=0; t0=$(now); STREAM_T0=$t0
  while IFS=$'\t' read -r key size etag; do
    if [ $(( $(now) - t0 )) -gt "$STREAM_S" ]; then WHY="o envio passou de ${STREAM_S}s (objeto $key e os seguintes nao foram enviados)"; return 1; fi
    # o job do MBP acabou (caiu, estourou o teto, o slot foi limpo): continuar enviando recriaria 13 GB de lixo num slot sem dono
    job_gone && return 1
    case "$key" in
      */) "${NOAWS[@]}" "$SSH" $SSH_OPTS "$SSH_HOST" "[ -d '$SLOTDIR/in/lab-src' ] && mkdir -p '$SLOTDIR/in/lab-src/${key#"$DB"/}'" </dev/null >/dev/null 2>&1 || { WHY="nao consegui criar a pasta $key no MBP"; return 1; }
          continue ;;
    esac
    stream_one "$key" "$size" "$etag" || { job_gone && return 1; log "objeto $key falhou ($WHY); tentando de novo"; sleep "$RETRY_S"; stream_one "$key" "$size" "$etag" || { job_gone; return 1; }; }
    n=$((n + 1)); [ $((n % 20)) -ne 0 ] || log "enviados $n/$NOBJ objetos ($(( $(now) - t0 ))s)"
  done < "$RUN/listing.tsv"
  STREAM_T=$(( $(now) - t0 ))
}

# --- higiene do lado do mini: arquivos do stage, do estado e do log do mbp-run com cara de credencial AWS. Só contagem. -------
mini_hygiene() {  # → HY_FILES (contagem ou "?")
  local hits st p
  set --; for p in "$STAGE" "$STATE" "$CITY/.gc/logs/mbp-run.jsonl"; do [ -z "$p" ] || [ ! -e "$p" ] || set -- "$@" "$p"; done
  [ "$#" -gt 0 ] || { HY_FILES="?"; return; }
  # só caminhos que existem: grep sai 2 por um caminho ausente mesmo achando acerto em outro, e isso viraria "?"
  hits=$(grep -rIlE --exclude='*.sh' "$SHAPE" "$@" 2>/dev/null); st=$?
  case "$st" in 0) HY_FILES=$(printf '%s\n' "$hits" | grep -c .) ;; 1) HY_FILES=0 ;; *) HY_FILES="?" ;; esac
}

# --- classifica o resultado. $1 = rc do mbp-run. Deixa VERDICT FINAL_RC WHY e as medidas. -----------------------------------
classify() {
  local line v rc
  VERDICT=UNKNOWN; FINAL_RC=2; TOTAL="?"; SRC_KB="?"; REST_KB="?"; TREST="?"; TCOUNT="?"
  line=$("$PY" -I -c "$PYHELP" report "$OUT/report.json" 2>/dev/null) || line=""
  if [ -z "$line" ]; then
    # o wrapper do MBP diz POR QUE nao chegou ao lab (ferramenta ausente, dolt de outra versao, disco, copia incompleta); sem relatorio nao ha veredito
    WHY="relatorio do MBP ausente ou ilegivel (mbp-run rc=$1): $(grep -h '^\[lab-mbp\] UNKNOWN' "$OUT/lab.stream" 2>/dev/null | tail -1 | head -c 300)"; return
  fi
  IFS=$'\t' read -r v rc TOTAL SRC_KB REST_KB _ TREST TCOUNT WHY <<<"$line"
  case "$1:$v:$rc" in
    0:OK:0) VERDICT=OK; FINAL_RC=0 ;;
    1:FAIL:1) VERDICT=FAIL; FINAL_RC=1 ;;
    3:SLOW:3) VERDICT=SLOW; FINAL_RC=3 ;;
    2:UNKNOWN:2) ;;
    *) WHY="mbp-run rc=$1 nao bate com o relatorio do lab ($v rc=$rc): sem veredito" ;;
  esac
}

finish() {  # $1 = rc final; resumo + RESULT + notify
  local rc="$1" msg
  msg="RESULT: ${VERDICT:-UNKNOWN} db=$DB rc=$rc as_of=${AS_OF:-?} tabelas=${NTAB:-?} objetos=$NOBJ stream_s=$STREAM_T total_s=${TOTAL:-?} restore_s=${TREST:-?} count_s=${TCOUNT:-?} backup_kb=${SRC_KB:-?} restaurado_kb=${REST_KB:-?} run=${RUN:-?}"
  log "$msg"; [ -z "$WHY" ] || log "motivo: $WHY"
  if [ "$NOTIFY_ON" -eq 1 ] && { [ "$rc" -eq 1 ] || [ "$rc" -eq 2 ] || [ "$rc" -eq 3 ] || [ "${LEAK:-0}" -eq 1 ]; } && [ "$MODE" = run ]; then
    "$NOTIFY" -t "Dolt restore-lab (MBP)" -p 4 "${VERDICT:-UNKNOWN} db=$DB rc=$rc ${WHY:-} (ver $RUN)" 2>/dev/null || true
  fi
  exit "$rc"
}
unknown() { VERDICT=UNKNOWN; WHY="$*"; finish 2; }
defer() {  # antes de começar: na última janela da noite vira UNKNOWN (adiar para sempre seria esconder o problema)
  local h; h=$(date +%H); h=$((10#${LABMBP_NOW_HOUR:-$h}))
  if [ "$h" -ge "$FINAL_HOUR" ]; then unknown "adiado ate a ultima janela e nao rodou: $*"; fi
  VERDICT=ADIADO; WHY="$*"; finish 4
}

install_dolt() {
  local d; d=$(mktemp -d "${TMPDIR:-/tmp}/lab-dolt.XXXXXX") || exit 2; STAGE="$d"
  mkdir "$d/lab-bin" && cp -L "$(command -v "$DOLT")" "$d/lab-bin/dolt" && chmod 755 "$d/lab-bin/dolt" || { log "nao consegui copiar o dolt do mini"; exit 2; }
  "${NOAWS[@]}" "$MBP_RUN" --exec --push "$d/lab-bin" -- sh -c 'mkdir -p "$HOME/gt-remote/lab/bin" && cp in/lab-bin/dolt "$HOME/gt-remote/lab/bin/dolt" && chmod 755 "$HOME/gt-remote/lab/bin/dolt" && "$HOME/gt-remote/lab/bin/dolt" version | head -1'
  exit $?
}

# Lança o job no MBP em segundo plano e junta as saídas: a linha "ready" vira $STAGE/slot; o rc do mbp-run vira $STAGE/mbprc.
launch() {
  ( "${NOAWS[@]}" MBP_RUN_TIMEOUT_S="$JOB_TIMEOUT" MBP_SLOT_MAX_AGE_S=$(( JOB_TIMEOUT + 1800 )) "$MBP_RUN" --exec --push "$STAGE/lab-in" --pull "out/:$OUT/" -- \
      bash in/lab-in/dolt-restore-lab-mbp-side.sh --db "$DB" --dolt-version "$WANT_DOLT" --rto-seconds "$RTO" --src-kb "$TOTAL_KB" \
        --margin-pct "$MARGIN" --stream-wait-s "$(( STREAM_S + 300 ))" 2>&1 \
    | while IFS= read -r line; do
        printf '%s\n' "$line" >> "$OUT/lab.stream"
        case "$line" in "[lab-mbp] ready slot="*) printf '%s\n' "${line#*slot=}" > "$STAGE/slot.tmp"; mv "$STAGE/slot.tmp" "$STAGE/slot" ;; esac
      done
    echo "${PIPESTATUS[0]}" > "$STAGE/mbprc.tmp"; mv "$STAGE/mbprc.tmp" "$STAGE/mbprc" ) 2>/dev/null &
  BG=$!
}

setmode() { { [ "$MODE" = run ] || [ "$MODE" = "$1" ]; } || { echo "so um modo por vez (--dry-run ou --check)" >&2; exit 2; }; MODE="$1"; }

main() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      run) ;; --dry-run) setmode dry ;; --check) setmode check ;; --install-dolt) setmode install ;; --force) FORCE=1 ;; --no-notify) NOTIFY_ON=0 ;;
      --db) [ "$#" -ge 2 ] || { echo "--db precisa de um valor" >&2; exit 2; }; DB="$2"; shift ;;
      -h|--help|help) usage; exit 0 ;; *) echo "opcao desconhecida: $1" >&2; exit 2 ;;
    esac
    shift
  done
  case "$DB" in ''|*[!A-Za-z0-9_]*) echo "--db invalido: $DB" >&2; exit 2 ;; esac
  [ "$MODE" != install ] || install_dolt
  if [ "$MODE" = check ]; then mbp_free && { log "MBP livre"; exit 0; }; log "MBP nao livre: $WHY"; exit 4; fi

  [ -n "$TMO" ] || unknown "sem timeout/gtimeout no PATH (brew install coreutils; o PATH do launchd precisa de /opt/homebrew/bin)"
  take_lock; case $? in 0) ;; 1) VERDICT=SKIPPED; finish 0 ;; *) unknown "${WHY:-nao consegui criar $STATE (ou a trava dentro dela)}" ;; esac   # SKIPPED: o agendador ve que nao rodou
  T0=$(now); RUN="$STATE/runs/$(date -u +%Y%m%dT%H%M%SZ)-$$"; OUT="$RUN/out"   # com o pid: duas rodadas no mesmo segundo (trava recolhida) nao dividem a pasta
  { mkdir -p "$STATE/runs" && mkdir "$RUN" && mkdir "$OUT"; } || unknown "nao consegui criar $RUN"
  if [ "$MODE" = run ] && [ "$FORCE" -eq 0 ]; then
    if fresh last-final $(( RECENT_DAYS * 86400 )); then VERDICT=SKIPPED; WHY="ja ha veredito conclusivo nos ultimos $RECENT_DAYS dias: nada a fazer"; finish 0; fi
    if fresh last-attempt 43200; then VERDICT=SKIPPED; WHY="uma rodada ja comecou nas ultimas 12 h (veja $STATE/runs): nada a fazer"; finish 0; fi
  fi
  if [ "$MODE" = run ]; then mbp_free || defer "$WHY"; fi

  build_manifest || unknown "$WHY"
  list_objects || unknown "$WHY"
  if [ "$MODE" = dry ]; then
    log "manifest AS OF $AS_OF ($NTAB tabelas, run_utc=$FP1):"; cat "$RUN/manifest.json"   # third-state-waiver: so exibe; build_manifest ja provou o arquivo nao-vazio
    log "lista do S3: $NOBJ objetos, ${TOTAL_KB}KB (nada foi enviado)"; VERDICT=DRY; finish 0
  fi
  WANT_DOLT=$(bounded "$DOLT" version 2>/dev/null | head -1 | awk '{print $3}')
  [ -n "$WANT_DOLT" ] || unknown "nao consegui ler a versao do dolt do mini (o MBP precisa da mesma)"

  STAGE=$(mktemp -d "${TMPDIR:-/tmp}/lab-mbp.XXXXXX") && chmod 700 "$STAGE" && mkdir -m 700 "$STAGE/lab-in" || unknown "nao consegui criar o stage 0700"
  cp "$RUN/manifest.json" "$RUN/listing.tsv" "$HERE/dolt-restore-lab.sh" "$HERE/dolt-restore-lab-mbp-side.sh" "$STAGE/lab-in/" || unknown "nao consegui montar o stage"
  date +%s > "$STATE/last-attempt"
  log "rodada: db=$DB as_of=$AS_OF tabelas=$NTAB objetos=$NOBJ backup=${TOTAL_KB}KB dolt=$WANT_DOLT rto=${RTO}s envio<=${STREAM_S}s"
  launch

  # espera o "ready" (o wrapper já checou ferramentas, dolt e disco) ou o fim do job (recusa)
  local t=$(( $(now) + READY_S ))
  while [ ! -e "$STAGE/slot" ] && [ ! -e "$STAGE/mbprc" ] && [ "$(now)" -lt "$t" ]; do sleep "$POLL_S"; done
  STREAM_OK=0
  if [ -e "$STAGE/slot" ]; then
    SLOTDIR=$(cat "$STAGE/slot")
    if printf '%s' "$SLOTDIR" | grep -Eq '^/[A-Za-z0-9._/-]+/exec/[0-9]+$' && ! printf '%s' "$SLOTDIR" | grep -q '\.\.'; then
      STREAMING=1
      if stream_all; then STREAM_OK=1; STREAMING=0; mark stream.done; else STREAMING=0; mark stream.failed; fi
    else
      WHY="o wrapper do MBP devolveu um caminho de slot inesperado: $(printf '%s' "$SLOTDIR" | head -c 80)"; SLOTDIR=""; STREAMING=0
    fi
  elif [ ! -e "$STAGE/mbprc" ]; then
    WHY="o MBP nao ficou pronto em ${READY_S}s"
  fi
  # sem "ready" nem rc o job ainda pode estar pendurado (até o teto do mbp-run): não se espera por ele, a trap larga o subshell
  if [ -e "$STAGE/slot" ] || [ -e "$STAGE/mbprc" ]; then wait "$BG" 2>/dev/null; BG=""; fi
  MBPRC=$(cat "$STAGE/mbprc" 2>/dev/null); isnum "$MBPRC" || MBPRC="?"
  rm -rf "$STAGE/lab-in"      # o stage não guarda nada que precise sobreviver ao job
  if [ ! -e "$STAGE/slot" ]; then
    case "$MBPRC" in 96|97|98|99) defer "mbp-run recusou antes de a rodada comecar (rc=$MBPRC): $(tail -1 "$OUT/lab.stream" 2>/dev/null)" ;; esac
  fi
  if [ "$STREAM_OK" -eq 1 ]; then
    classify "$MBPRC"
  else
    VERDICT=UNKNOWN; FINAL_RC=2; TOTAL="?"; SRC_KB="?"; REST_KB="?"; TREST="?"; TCOUNT="?"
    [ -n "$WHY" ] || WHY="relatorio do MBP ausente (mbp-run rc=$MBPRC): $(grep -h '^\[lab-mbp\] UNKNOWN' "$OUT/lab.stream" 2>/dev/null | tail -1 | head -c 300)"
  fi
  case "$VERDICT:$MBPRC" in UNKNOWN:98|UNKNOWN:124|UNKNOWN:143|UNKNOWN:255) WHY="$WHY; o MBP caiu ou estourou o tempo (mbp-run rc=$MBPRC)" ;; esac

  # corrida com o backup das 04:00: FAIL só é conclusivo se o latest.json ficou parado durante o envio
  if [ "$VERDICT" = FAIL ]; then
    meta2=$(bounded "$AWS" s3 cp "s3://$BUCKET/_meta/latest.json" - 2>/dev/null | "$PY" -I -c "$PYHELP" meta "$DB" 2>/dev/null) || meta2=""
    if [ "${meta2%%$'\t'*}" != "$FP1" ]; then
      VERDICT=UNKNOWN; FINAL_RC=2
      WHY="FAIL rebaixado: o latest.json do backup mudou (ou nao consegui reler) durante a rodada (run_utc antes=$FP1 depois=${meta2%%$'\t'*}); $WHY"
    fi
  fi

  mini_hygiene; LEAK=0; HYGQ=0
  EVID=$(cat "$OUT/evidence.txt" 2>/dev/null)
  mbp_hits=$(printf '%s\n' "$EVID" | sed -n 's/.*argv_hits=\([^ ]*\).*/\1/p' | tail -1); mbp_files=$(printf '%s\n' "$EVID" | sed -n 's/^slot_files_with_credential=//p' | tail -1)
  mbp_env=$(printf '%s\n' "$EVID" | sed -n 's/^aws_env_vars=//p' | tail -1)
  # contagem > 0 = credencial onde não podia; contagem ilegível ("?") com o lab já rodado = a prova de higiene não foi feita: também avisa
  for x in "$mbp_hits" "$mbp_files" "$mbp_env" "$HY_FILES"; do if isnum "$x"; then [ "$x" -eq 0 ] || LEAK=1; else HYGQ=1; fi; done
  case "$VERDICT" in OK|FAIL|SLOW) [ "$HYGQ" -eq 0 ] || LEAK=1 ;; *) HYGQ=0 ;; esac
  {
    echo "verdict=$VERDICT rc=$FINAL_RC db=$DB as_of=$AS_OF tabelas=$NTAB total_s=$TOTAL restore_s=$TREST count_s=$TCOUNT backup_kb=$SRC_KB restaurado_kb=$REST_KB wall_s=$(( $(now) - T0 ))"
    echo "envio: objetos=$NOBJ kb=$TOTAL_KB stream_s=$STREAM_T etag_verificado=$NETAG_OK etag_nao_verificavel=$NETAG_UNV"
    "$PY" -I -c "$PYHELP" tables "$OUT/report.json" 2>/dev/null
    echo "mbp-evidence: $(printf '%s' "$EVID" | tr '\n' ' ')"
    echo "mini-higiene: arquivos-com-cara-de-credencial=$HY_FILES"
    echo "mbp-higiene: aws_env_vars=${mbp_env:-?} ps_acertos=${mbp_hits:-?} arquivos-com-credencial=${mbp_files:-?}"
    [ "$LEAK" -eq 0 ] || echo "ALERTA: ha credencial AWS onde nao podia, ou a prova de higiene nao foi medida ('?'): veja as contagens acima"
  } > "$RUN/summary.txt"
  cat "$RUN/summary.txt"
  case "$VERDICT" in OK|FAIL|SLOW) date +%s > "$STATE/last-final" ;; esac
  finish "$FINAL_RC"
}

if [ "${LABMBP_LIB:-0}" != "1" ]; then main "$@"; fi
