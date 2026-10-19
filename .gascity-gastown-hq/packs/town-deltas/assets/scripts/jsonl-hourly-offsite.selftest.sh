#!/bin/bash
# jsonl-hourly-offsite.selftest.sh (ga-c0939v) — testes do jsonl-hourly-offsite.sh e do helper jsonl_hourly.py.
#
# ESCOPO: hermético. `aws` é um stub que guarda "objetos" num diretório temporário e valida o sha256 como o S3 valida;
#   `notify` é um stub que anota e imita o roteador real (sem push forçado vai ao digest, rc 12 sob saída estrita; só o forçado chega ao telefone). Repositórios
#   git, estado e logs vivem em mktemp. Nenhuma rede, bd, dolt ou credencial, nada em ~/.aws, nada do S3 real. O helper python tem a própria suíte, chamada no fim.
# COMO RODAR: /bin/bash jsonl-hourly-offsite.selftest.sh     (rc 0 = tudo passou; última linha `=== RESULT: PASS=n FAIL=n ===`)
#   JHO_SCRIPT=/outro/jsonl-hourly-offsite.sh  roda a suíte contra uma cópia (é como se faz o teste de mutação: quebrar um guarda e ver cair).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${JHO_SCRIPT:-$HERE/jsonl-hourly-offsite.sh}"
PYH="$(dirname "$SCRIPT")/jsonl_hourly.py"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check() { # descrição, comando...
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}
eq() { # descrição, obtido, esperado
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (obtido '$2', esperado '$3')"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/jho-selftest.XXXXXX")"
case "$WORK" in "${TMPDIR:-/tmp}"/jho-selftest.*) ;; *) echo "mktemp inesperado: $WORK" >&2; exit 2 ;; esac
trap 'rm -rf "$WORK"; [ -n "${BG_PID:-}" ] && kill "$BG_PID" 2>/dev/null' EXIT

# ── stub do aws ─────────────────────────────────────────────────────────────────────────────────
mkdir -p "$WORK/bin"
cat > "$WORK/bin/aws" <<'STUB'
#!/bin/bash
# stub de `aws s3api`: objetos em $STUB_DIR/obj/<key>, metadados em $STUB_DIR/meta/<key>; injeção de falha por arquivos em $STUB_DIR/inject/
set -u
D="${STUB_DIR:?}"; mkdir -p "$D/obj" "$D/meta" "$D/inject"
echo "$*" >> "$D/calls.log"
[ "${1:-}" = s3api ] || { echo "stub: só s3api" >&2; exit 2; }
op="$2"; shift 2
bucket=""; key=""; body=""; cs=""; prefix=""; outfile=""
while [ $# -gt 0 ]; do
  case "$1" in
    --bucket) bucket="$2"; shift 2 ;; --key) key="$2"; shift 2 ;; --body) body="$2"; shift 2 ;;
    --checksum-sha256) cs="$2"; shift 2 ;; --prefix) prefix="$2"; shift 2 ;;
    --content-type|--checksum-algorithm|--checksum-mode|--output) shift 2 ;;
    *) outfile="$1"; shift ;;
  esac
done
injected() { # nome — o arquivo de injeção existe e (vazio ou contém parte da chave)
  local f="$D/inject/$1"
  [ -e "$f" ] || return 1
  [ ! -s "$f" ] && return 0
  case "$key" in *"$(cat "$f")"*) return 0 ;; esac
  return 1
}
sha64() { python3 -I -c 'import base64,hashlib,sys;print(base64.b64encode(hashlib.sha256(open(sys.argv[1],"rb").read()).digest()).decode())' "$1"; }
case "$op" in
  put-object)
    injected fail_put && { echo "An error occurred (InternalError) when calling the PutObject operation: injected" >&2; exit 254; }
    [ -f "$body" ] || { echo "stub: body inexistente" >&2; exit 2; }
    got="$(sha64 "$body")"
    if [ -n "$cs" ] && [ "$cs" != "$got" ]; then
      echo "An error occurred (InvalidRequest) when calling the PutObject operation: Value for x-amz-checksum-sha256 header is invalid." >&2; exit 254
    fi
    mkdir -p "$(dirname "$D/obj/$key")" "$(dirname "$D/meta/$key")"
    cp "$body" "$D/obj/$key"; printf '%s %s\n' "$(wc -c < "$body" | tr -d ' ')" "${cs:+$got}" > "$D/meta/$key"
    echo "$key" >> "$D/puts.log"; echo '{"ETag":"\"x\""}' ;;
  head-object)
    injected fail_head_generic && { echo "An error occurred (403) when calling the HeadObject operation: Forbidden (request id 4047QZ)" >&2; exit 254; }
    injected fail_head && { echo "Could not connect to the endpoint URL" >&2; exit 255; }
    [ -f "$D/obj/$key" ] || { echo "An error occurred (404) when calling the HeadObject operation: Not Found" >&2; exit 254; }
    read -r size sum < "$D/meta/$key" || true
    injected lie_size && size=$((size + 1))
    injected lie_checksum && sum="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    if [ -n "${sum:-}" ]; then printf '{"ContentLength": %s, "ChecksumSHA256": "%s"}\n' "$size" "$sum"; else printf '{"ContentLength": %s}\n' "$size"; fi ;;
  get-object)
    injected fail_get && { echo "An error occurred (500) when calling the GetObject operation: injected" >&2; exit 254; }
    [ -f "$D/obj/$key" ] || { echo "An error occurred (NoSuchKey) when calling the GetObject operation: The specified key does not exist." >&2; exit 254; }
    cp "$D/obj/$key" "$outfile"; echo '{}' ;;
  list-objects-v2)
    injected fail_list && { echo "An error occurred (500) when calling the ListObjectsV2 operation: injected" >&2; exit 254; }
    injected garbage_list && { echo "<html>not json</html>"; exit 0; }
    ( cd "$D/obj" && find . -type f 2>/dev/null | sed 's|^\./||' | sort ) | python3 -I -c '
import json,sys
p=sys.argv[1]; ks=[l.strip() for l in sys.stdin if l.strip().startswith(p)]
print(json.dumps({"Contents":[{"Key":k} for k in ks]} if ks else {}))' "$prefix" ;;
  delete-object)
    injected fail_delete && { echo "An error occurred (500) when calling the DeleteObject operation: injected" >&2; exit 254; }
    rm -f "$D/obj/$key" "$D/meta/$key"; echo "$key" >> "$D/deletes.log"; echo '{}' ;;
  *) echo "stub: operação não suportada: $op" >&2; exit 2 ;;
esac
STUB
chmod +x "$WORK/bin/aws"
cat > "$WORK/bin/notify" <<'STUB'
#!/bin/bash
# como o roteador real: sem NOTIFY_FORCE_PUSH=1 a fonte cai no digest mudo (rc 12 sob NOTIFY_STRICT_EXIT=1, rc 0 sem); só a chamada forçada chega ao telefone (notify.pushed). NOTIFY_RC=n força o rc.
echo "force=${NOTIFY_FORCE_PUSH:-} strict=${NOTIFY_STRICT_EXIT:-} $*" >> "${NOTIFY_LOG:?}"
[ -n "${NOTIFY_RC:-}" ] && exit "$NOTIFY_RC"
if [ "${NOTIFY_FORCE_PUSH:-}" != 1 ]; then [ "${NOTIFY_STRICT_EXIT:-}" = 1 ] && exit 12; exit 0; fi
echo "$*" >> "${NOTIFY_LOG%.log}.pushed"
STUB
chmod +x "$WORK/bin/notify"
mkdir -p "$WORK/gitbin"; printf '#!/bin/bash\ncase " $* " in *" diff "*) [ -n "${GIT_FAIL_DIFF:-}" ] && exit 128 ;; esac\nexec %s "$@"\n' "$(command -v git)" > "$WORK/gitbin/git"; chmod +x "$WORK/gitbin/git"   # git que falha só no diff (GIT_FAIL_DIFF=1)
mkdir -p "$WORK/jqbin"; printf '#!/bin/bash\ncase " $* " in *.manifest_key*) [ -n "${JQ_FAIL_MKEY:-}" ] && { echo "jq: error: injected" >&2; exit 5; } ;; esac\nexec %s "$@"\n' "$(command -v jq)" > "$WORK/jqbin/jq"; chmod +x "$WORK/jqbin/jq"   # jq que falha só ao LER .manifest_key, não ao montá-lo no latest.json (JQ_FAIL_MKEY=1)
# helper embrulhado (JHO_PY): repassa tudo ao real; WRAP=db_string estraga .databases do manifest, WRAP=retention_fail derruba o `retention`
cat > "$WORK/bin/wrap.py" <<WRAP
import json, os, subprocess, sys
REAL, mode = "$PYH", os.environ.get("WRAP", "")
if mode == "retention_fail" and sys.argv[1] == "retention": sys.exit(1)
if mode == "db_string" and sys.argv[1] == "manifest":
    r = subprocess.run([sys.executable, "-I", REAL] + sys.argv[1:], capture_output=True)
    m = json.loads(r.stdout); m["databases"] = "x"; sys.stdout.write(json.dumps(m)); sys.stderr.buffer.write(r.stderr); sys.exit(r.returncode)
os.execv(sys.executable, [sys.executable, "-I", REAL] + sys.argv[1:])
WRAP

# ── helpers de cenário ─────────────────────────────────────────────────────────────────────────
T0="$(date +%s)"
GIT() { git -C "$ARCH" "$@"; }
tbl() { # id... -> {"rows":[...]} de issues mínimas
  local out="" i
  for i in "$@"; do out="$out${out:+,}{\"id\":\"$i\",\"title\":\"t $i\",\"status\":\"open\",\"priority\":\"1\",\"issue_type\":\"task\"}"; done
  if [ -z "$out" ]; then printf '{}'; else printf '{"rows":[%s]}' "$out"; fi
}
write_db() { # db id...  (as 5 tabelas auxiliares ficam vazias)
  local db="$1"; shift
  mkdir -p "$ARCH/$db"
  tbl "$@" > "$ARCH/$db/issues.jsonl"
  local t; for t in comments dependencies labels config metadata; do printf '{}' > "$ARCH/$db/$t.jsonl"; done
}
new_env() { # nome — cria archive git com hq (2 issues) e wa (1), e zera bucket/estado
  S="$WORK/$1"; ARCH="$S/archive"; ST="$S/state/jsonl-hourly-offsite-state.json"; mkdir -p "$S/state" "$S/bucket" "$S/log"; : > "$S/notify.log"
  git init -q "$ARCH"
  write_db hq hq-1 hq-2; write_db wa wa-1
  GIT add -A >/dev/null && GIT commit -q -m init
}
commit_all() { GIT add -A >/dev/null && GIT commit -q -m "${1:-change}"; }
NOW_OFF=0
offsite() { # args... ; env extra via prefixo `env`; define OUT, RC
  # exporter vivo: reescreve os bancos na hora do relógio de mentira (mtime); SRC_STOP=n => parou n s depois de T0
  python3 -I -c 'import glob,os,sys;t=int(sys.argv[1]);[os.utime(p,(t,t)) for p in glob.glob(sys.argv[2]+"/*/issues.jsonl")]' $((T0 + (${SRC_STOP:-$NOW_OFF} < NOW_OFF ? ${SRC_STOP:-$NOW_OFF} : NOW_OFF))) "$ARCH"
  OUT="$(JHO_ARCHIVE="$ARCH" JHO_STATE_DIR="${STATE_OVR:-$S/state}" JHO_LOG="$S/log/offsite.log" JHO_AWS="${AWS_BIN:-$WORK/bin/aws}" JHO_NOTIFY="${NOTIFY_BIN:-$WORK/bin/notify}" \
        STUB_DIR="$S/bucket" NOTIFY_LOG="$S/notify.log" JHO_REQUIRED_DBS="${REQ:-hq,wa}" JHO_NOW=$((T0 + NOW_OFF)) JHO_S3_TIMEOUT=60 JHO_MIN_FREE_MB=1 \
        "$SCRIPT" "$@" 2>"$S/stderr")"
  RC=$?
}
objs()  { ( cd "$S/bucket/obj" 2>/dev/null && find . -type f | sed 's|^\./||' | sort ); }
count_objs() { objs | grep -c "$1" || true; }
putlog() { cat "$S/bucket/puts.log" 2>/dev/null; }
inject() { mkdir -p "$S/bucket/inject"; printf '%s' "${2:-}" > "$S/bucket/inject/$1"; }
clear_inject() { rm -f "$S/bucket/inject/$1"; }
jqf() { jq -r "$1" "$2" 2>/dev/null; }
LATEST() { echo "$S/bucket/obj/jsonl-hourly/latest.json"; }
ARTKEY() { objs | grep '\.tar\.gz$' | tail -1; }
pushed() { cat "$S/notify.pushed" 2>/dev/null | wc -l | tr -d ' '; }   # alertas que chegaram ao telefone (chamada forçada ao notify)

echo "=== jsonl-hourly-offsite.selftest.sh ==="
echo "bash: ${BASH_VERSION}"
[ -x "$SCRIPT" ] && ok "script presente e executável" || { bad "script ausente: $SCRIPT"; echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="; exit 1; }
check "bash -n" bash -n "$SCRIPT"

echo "-- 0. modo biblioteca"
S="$WORK/lib"; mkdir -p "$S/state"
lib() { ( export JHO_LIB=1 JHO_STATE_DIR="$S/state" JHO_LOG="$S/log" JHO_AWS="$WORK/bin/aws" STUB_DIR="$S/bucket"; . "$SCRIPT" >/dev/null 2>&1; "$@" ); }
check "lib: funções definidas, nada executado (sem estado, sem lock, sem chamada ao aws)" bash -c "[ ! -e '$S/state/jsonl-hourly-offsite-state.json' ] && [ ! -d '$S/state/jsonl-hourly-offsite.lock.d' ] && [ ! -e '$S/bucket/calls.log' ]"
eq "sha256_b64 do sha256 de ''" "$(lib sha256_b64 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855)" "47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="
lib sizes_match 5 5 && ok "sizes_match 5 5" || bad "sizes_match 5 5"
for p in "'' ''" "5 6" "a a" "'' 5"; do eval "lib sizes_match $p" && bad "sizes_match $p deveria falhar" || ok "sizes_match $p falha"; done   # vazio não é igual a vazio; não numérico não é número

echo "-- 1. caminho feliz (com lixo e bancos de benchmark no archive, árvore de trabalho suja)"; new_env happy
printf '%s' "$(tbl hq-1 hq-2)" > "$ARCH/hq.jsonl"                      # cópia legada da raiz
echo garbage > "$ARCH/hq/issues.jsonl.tmp.123"                         # sobra de export abortado, commitada
write_db bench_hq_copy b-1; : > "$ARCH/bench_hq_copy/config.jsonl"; : > "$ARCH/bench_hq_copy/metadata.jsonl"   # o que reprovou o 1º upload real
write_db fixdepkeys_0d16f874c5d7 f-1; : > "$ARCH/fixdepkeys_0d16f874c5d7/issues.jsonl.tmp.Td3hQh"
commit_all "com lixo"
HEAD_SHA="$(GIT rev-parse HEAD)"
write_db hq hq-1 hq-2 hq-3                                              # árvore de trabalho adiantada e NÃO commitada
offsite
eq "rc 0, RESULT: ok new" "$RC:${OUT%% key=*}" "0:RESULT: ok new"
eq "3 objetos: snapshot, manifest, latest.json" "$(objs | wc -l | tr -d ' ')" 3
ART="$(ARTKEY)"
echo "$ART" | grep -Eq '^jsonl-hourly/snap/[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}\.tar\.gz$' && ok "chave do snapshot no formato esperado" || bad "chave do snapshot: $ART"
case "$ART" in *"-${HEAD_SHA:0:12}.tar.gz") ok "chave leva os 12 primeiros do sha do HEAD" ;; *) bad "sha12 do HEAD fora da chave: $ART" ;; esac
eq "latest.json é o ÚLTIMO put" "$(putlog | tail -1)" "jsonl-hourly/latest.json"
eq "ordem dos puts: snapshot, manifest, latest" "$(putlog | sed 's/.*\.//' | tr '\n' ' ')" "gz json json "
grep -q -- '--checksum-sha256' "$S/bucket/calls.log" && ok "put-object leva --checksum-sha256" || bad "put-object sem --checksum-sha256"
grep -q -- '--checksum-mode ENABLED' "$S/bucket/calls.log" && ok "head-object lê o checksum (--checksum-mode ENABLED)" || bad "head-object sem --checksum-mode"
MAN="$S/bucket/obj/${ART%.tar.gz}.manifest.json"
eq "manifest: verdict ok" "$(jqf .verdict "$MAN")" ok
eq "manifest: hq=2 issues (o HEAD, não a árvore de trabalho com 3)" "$(jqf .databases.hq.issues "$MAN")" 2
eq "manifest: wa=1 issue" "$(jqf .databases.wa.issues "$MAN")" 1
eq "manifest: source.archive_head" "$(jqf .source.archive_head "$MAN")" "$HEAD_SHA"
eq "manifest: sha256 do artefato = sha256 do objeto" "$(jqf .artifact.sha256 "$MAN")" "$(python3 -I -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$S/bucket/obj/$ART")"
eq "manifest: lixo da raiz e *.tmp.* constam como excluídos" "$(jqf '.excluded | sort | join(",")' "$MAN")" "fixdepkeys_0d16f874c5d7/issues.jsonl.tmp.Td3hQh,hq.jsonl,hq/issues.jsonl.tmp.123"
eq "manifest: bancos de benchmark/teste (config/metadata com 0 bytes) ignorados e NOMEADOS, verdict ok" "$(jqf '[.verdict, (.ignored_dbs | join(","))] | join(" ")' "$MAN")" "ok bench_hq_copy,fixdepkeys_0d16f874c5d7"
eq "manifest: só hq e wa nos bancos" "$(jqf '.databases | keys | join(",")' "$MAN")" "hq,wa"
tar -tzf "$S/bucket/obj/$ART" | sort > "$S/members.txt"
eq "artefato: só os 12 <db>/<tabela>.jsonl" "$(wc -l < "$S/members.txt" | tr -d ' ')" 12
! grep -qE 'tmp|^hq\.jsonl$' "$S/members.txt" && ok "artefato: sem tmp e sem cópia legada da raiz" || bad "artefato tem lixo: $(grep -E 'tmp|^hq\.jsonl$' "$S/members.txt")"
mkdir -p "$S/x" && tar -xzf "$S/bucket/obj/$ART" -C "$S/x"
eq "artefato: hq/issues.jsonl tem 2 linhas (HEAD)" "$(python3 -I "$PYH" count "$S/x/hq/issues.jsonl" | jq -r .rows)" 2
LJ="$(LATEST)"
eq "latest.json aponta para o snapshot" "$(jqf .snapshot_key "$LJ")" "$ART"
eq "latest.json: sha256 e issues_per_db" "$(jqf '[.sha256, .issues_per_db.hq, .issues_per_db.wa] | join(",")' "$LJ")" "$(jqf .artifact.sha256 "$MAN"),2,1"
eq "latest.json: data_as_of e checked_at em ISO-8601 Z" "$(jqf '[.data_as_of, .checked_at] | map(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) | all' "$LJ")" true
eq "estado: consecutive_not_ok 0, last_success_sha = HEAD" "$(jqf '[.consecutive_not_ok, .last_success_sha] | join(",")' "$ST")" "0,$HEAD_SHA"
[ ! -d "$S/state/jsonl-hourly-offsite.lock.d" ] && ok "lock removido ao sair" || bad "lock ficou"
[ -z "$(ls -A "$S/state/jsonl-hourly-work" 2>/dev/null)" ] && ok "diretório de trabalho limpo ao sair" || bad "work dir ficou: $(ls "$S/state/jsonl-hourly-work")"
FIRST_ART="$ART"

echo "-- 2. HEAD igual ao último verificado"
NOW_OFF=600; offsite
eq "rc 0, RESULT: ok unchanged" "$RC:${OUT%% key=*}" "0:RESULT: ok unchanged"
eq "nenhum snapshot novo (continua 1 tar.gz)" "$(count_objs '\.tar\.gz$')" 1
eq "latest.json: checked_at andou (heartbeat)" "$(jqf .checked_at "$LJ")" "$(python3 -I -c 'import datetime,sys;print(datetime.datetime.fromtimestamp(int(sys.argv[1]),datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' $((T0 + 600)))"
eq "latest.json: snapshot_key intacto" "$(jqf .snapshot_key "$LJ")" "$FIRST_ART"

echo "-- 3. HEAD igual e objeto sumido"
rm -f "$S/bucket/obj/$FIRST_ART" "$S/bucket/meta/$FIRST_ART"
NOW_OFF=700; offsite
eq "rc 0 e re-upload com chave nova (RESULT: ok new: não confiou no estado local)" "$RC:$(count_objs '\.tar\.gz$'):${OUT%% key=*}:$([ "$(ARTKEY)" != "$FIRST_ART" ] && echo newkey)" "0:1:RESULT: ok new:newkey"

echo "-- 4. HEAD novo"
write_db hq hq-1 hq-2 hq-3; commit_all "hq-3"
NOW_OFF=1400; offsite
eq "rc 0, RESULT new" "$RC:${OUT%% key=*}" "0:RESULT: ok new"
eq "latest.json avançou para o snapshot novo (hq=3)" "$(jqf '[.snapshot_key == "'"$(ARTKEY)"'", .issues_per_db.hq] | join(",")' "$LJ")" "true,3"

echo "-- 5. S3 não responde (rc 2)"
NOW_OFF=2100; PUTS_BEFORE="$(putlog | wc -l | tr -d ' ')"
inject fail_head_generic
offsite
eq "rc 2, RESULT: unknown" "$RC:${OUT:0:15}" "2:RESULT: unknown"
eq "nada foi escrito e o estado conta 1 não-ok" "$(putlog | wc -l | tr -d ' '):$(jqf .consecutive_not_ok "$ST")" "$PUTS_BEFORE:1"
clear_inject fail_head_generic
NOW_OFF=2200; offsite
eq "S3 de volta: rc 0 e contador zerado" "$RC:$(jqf .consecutive_not_ok "$ST")" "0:0"

echo "-- 6. snapshot broken (tabela de banco obrigatório truncada)"
GOOD_LATEST="$(jqf .snapshot_key "$LJ")"
objs > "$S/objs.before"; PUTS_BEFORE="$(putlog | wc -l | tr -d ' ')"
printf '{"rows":[{"id":"wa-1","title":"t"},{"id":"wa-2","ti' > "$ARCH/wa/issues.jsonl"; commit_all "wa truncado"
NOW_OFF=3000; offsite
eq "rc 1, RESULT: fail, a mensagem diz que nada subiu" "$RC:${OUT:0:12}:$(printf '%s' "$OUT" | grep -c 'NADA subiu')" "1:RESULT: fail:1"
eq "snapshot broken NÃO sobe: nenhum put novo" "$(putlog | wc -l | tr -d ' ')" "$PUTS_BEFORE"
eq "e o conjunto de objetos no bucket é exatamente o de antes" "$(objs | diff - "$S/objs.before" >/dev/null && echo same || echo changed)" same
grep -q 'problema: wa/issues.jsonl' "$S/log/offsite.log" && ok "o log nomeia o problema (wa/issues.jsonl), linha por linha" || bad "log sem 'problema: wa/issues.jsonl': $(tail -3 "$S/log/offsite.log")"
eq "latest.json NÃO andou" "$(jqf .snapshot_key "$LJ")" "$GOOD_LATEST"
eq "estado: consecutive_not_ok 1; last_success_sha ainda é o bom" "$(jqf '[.consecutive_not_ok, (.last_success_sha != "'"$(GIT rev-parse HEAD)"'")] | join(",")' "$ST")" "1,true"
printf '%s' "$(tbl wa-1)" > "$ARCH/wa/issues.jsonl"; commit_all "wa ok"
NOW_OFF=3600; offsite
eq "arquivo consertado: rc 0, latest.json avança, contador zera" "$RC:$(jqf .consecutive_not_ok "$ST"):$([ "$(jqf .snapshot_key "$LJ")" != "$GOOD_LATEST" ] && echo moved)" "0:0:moved"

echo "-- 6b. queda brusca de uma tabela contra o snapshot anterior => suspect, nada sobe (ga-l6v576)"; new_env susp
write_comments() { # db n — n comentários (a tabela que o export do hq cortou em 18/10)
  python3 -I -c 'import json,sys;print(json.dumps({"rows":[{"id":"c%d" % i,"issue_id":"x-1","comment":"t"} for i in range(int(sys.argv[1]))]}),end="")' "$2" > "$ARCH/$1/comments.jsonl"
}
MANOF() { echo "$S/bucket/obj/${1%.tar.gz}.manifest.json"; }
write_comments hq 400; commit_all "hq com 400 comentários"
NOW_OFF=0; offsite
eq "1º run (não há anterior): rc 0, ok new, baseline none" "$RC:${OUT%% key=*}:$(jqf .baseline.state "$(MANOF "$(ARTKEY)")")" "0:RESULT: ok new:none"
GOOD_A="$(jqf .snapshot_key "$(LATEST)")"; PUTS_BEFORE="$(putlog | wc -l | tr -d ' ')"
write_comments hq 128; commit_all "comments cortado em 128 (400 -> 128, -68%)"
NOW_OFF=700; offsite
eq "comments 400 -> 128: rc 1, RESULT: fail dizendo suspect, e NADA sobe (nenhum put novo)" "$RC:${OUT:0:12}:$(printf '%s' "$OUT" | grep -c 'suspect'):$(putlog | wc -l | tr -d ' ')" "1:RESULT: fail:1:$PUTS_BEFORE"
eq "latest.json NÃO andou" "$(jqf .snapshot_key "$(LATEST)")" "$GOOD_A"
grep -q 'suspeito: hq/comments: 400 -> 128' "$S/log/offsite.log" && ok "o log nomeia banco, tabela e os dois números" || bad "log sem 'suspeito: hq/comments: 400 -> 128': $(tail -4 "$S/log/offsite.log")"
eq "estado: consecutive_not_ok 1 (um snapshot suspect conta como run sem snapshot novo)" "$(jqf .consecutive_not_ok "$ST")" 1
write_comments hq 410; commit_all "comments voltou (410 >= 400)"
NOW_OFF=1400; offsite
eq "tabela de volta: rc 0, ok new, e o manifest diz que foi comparado contra o anterior bom" "$RC:${OUT%% key=*}:$(jqf '[.verdict, .baseline.state, .baseline.key] | join(",")' "$(MANOF "$(ARTKEY)")")" "0:RESULT: ok new:ok,compared,$GOOD_A"
GOOD_B="$(jqf .snapshot_key "$(LATEST)")"
write_comments hq 128; commit_all "purga de verdade (410 -> 128)"
NOW_OFF=2100; JHO_SUSPECT_DROP_PCT=90 offsite
eq "JHO_SUSPECT_DROP_PCT=90: a mesma queda de 69% passa (o limiar é do operador)" "$RC:${OUT%% key=*}" "0:RESULT: ok new"
write_comments hq 400; commit_all "hq 400 de novo"; NOW_OFF=2800; offsite
write_comments hq 100; commit_all "queda deliberada (400 -> 100)"
NOW_OFF=3500; offsite
eq "queda deliberada sem aceite: rc 1 suspect" "$RC:${OUT:0:12}" "1:RESULT: fail"
NOW_OFF=4200; JHO_ACCEPT_DROP=1 offsite
eq "JHO_ACCEPT_DROP=1 (um run, decisão de quem opera): rc 0, ok new, latest.json avança" "$RC:${OUT%% key=*}:$([ "$(jqf .snapshot_key "$(LATEST)")" = "$(ARTKEY)" ] && echo moved)" "0:RESULT: ok new:moved"
eq "e o manifest guarda o que foi aceito (verdict ok, suspect nomeia hq/comments, baseline.accepted)" "$(jqf '[.verdict, (.suspect | length), .baseline.accepted] | join(",")' "$(MANOF "$(ARTKEY)")")" "ok,1,true"
write_comments hq 101; commit_all "segue baixo"; NOW_OFF=4900; offsite
eq "depois do aceite o anterior é o novo piso: o run seguinte (100 -> 101) é ok sem a variável" "$RC:${OUT%% key=*}" "0:RESULT: ok new"
write_comments hq 50; commit_all "queda de 50%"
NOW_OFF=5600; inject fail_get "snap/"
offsite
eq "manifest anterior que o S3 não devolveu: NÃO trava o RPO (rc 0, ok new) mas o manifest diz baseline unavailable" "$RC:${OUT%% key=*}:$(jqf .baseline.state "$(MANOF "$(ARTKEY)")")" "0:RESULT: ok new:unavailable"
grep -q 'AVISO: sem régua' "$S/log/offsite.log" && ok "e o log avisa que a comparação não foi feita" || bad "log sem o aviso de régua ausente"
clear_inject fail_get
write_comments hq 20; commit_all "mais uma queda"
NOW_OFF=6300; inject fail_get "latest.json"
offsite
eq "latest.json que existe mas o S3 não devolve: baseline unavailable, não 'sem anterior' (none é só do 1º run)" "$RC:$(jqf .baseline.state "$(MANOF "$(ARTKEY)")")" "0:unavailable"
clear_inject fail_get

echo "-- 6c. latest.json que não entrega a chave do manifest anterior => régua indisponível, snapshot sobe mesmo assim (ga-l6v576)"; new_env mkey
write_comments hq 400; commit_all "hq com 400 comentários"
NOW_OFF=0; offsite
write_comments hq 410; commit_all "410"
NOW_OFF=700; JQ_FAIL_MKEY=1 PATH="$WORK/jqbin:$PATH" offsite
eq "jq falha ao ler manifest_key do latest.json: rc 0, ok new, baseline unavailable (não 'none')" "$RC:${OUT%% key=*}:$(jqf .baseline.state "$(MANOF "$(ARTKEY)")")" "0:RESULT: ok new:unavailable"
grep -q 'AVISO: sem régua: .*manifest_key' "$S/log/offsite.log" && ok "e o log diz que a régua faltou por causa do manifest_key" || bad "log sem o aviso de manifest_key: $(tail -4 "$S/log/offsite.log")"
write_comments hq 420; commit_all "420"
jq 'del(.manifest_key)' "$(LATEST)" > "$S/l2.json" && cp "$S/l2.json" "$(LATEST)"
NOW_OFF=1400; offsite
eq "latest.json sem a chave manifest_key: rc 0, ok new, baseline unavailable" "$RC:${OUT%% key=*}:$(jqf .baseline.state "$(MANOF "$(ARTKEY)")")" "0:RESULT: ok new:unavailable"
write_comments hq 430; commit_all "430"
NOW_OFF=2100; offsite
eq "com latest.json de novo inteiro (o run anterior o republicou): a régua volta, baseline compared" "$RC:$(jqf .baseline.state "$(MANOF "$(ARTKEY)")")" "0:compared"

echo "-- 7. banco obrigatório ausente"; new_env nodb; REQ="hq,wa,fantasma"
NOW_OFF=0; offsite
eq "rc 1, latest.json não criado, nada subiu: bucket vazio, nenhum put" "$RC:$([ -e "$(LATEST)" ] && echo has || echo none):$(objs | wc -l | tr -d ' '):$(putlog | wc -l | tr -d ' ')" "1:none:0:0"
grep -q 'banco obrigatório fantasma ausente' "$S/log/offsite.log" && ok "o log diz qual banco obrigatório faltou" || bad "log sem o banco ausente"
REQ=""

echo "-- 7b. bancos ignorados (JHO_IGNORE_DBS)"; new_env ign
write_db bench_hq_copy b-1; : > "$ARCH/bench_hq_copy/config.jsonl"; : > "$ARCH/bench_hq_copy/metadata.jsonl"; commit_all "lixo"
JHO_IGNORE_DBS="" offsite
eq "ignore desligado de propósito (JHO_IGNORE_DBS vazio): o mesmo archive vira broken, rc 1, nada sobe" "$RC:$(objs | wc -l | tr -d ' ')" "1:0"
grep -q 'problema: bench_hq_copy/config.jsonl' "$S/log/offsite.log" && ok "e o log nomeia bench_hq_copy/config.jsonl" || bad "log sem o banco de lixo"
offsite
eq "padrão (sem a variável): rc 0, snapshot e latest.json subiram" "$RC:$(objs | wc -l | tr -d ' ')" "0:3"
eq "o artefato não leva o banco de lixo" "$(tar -tzf "$S/bucket/obj/$(ARTKEY)" | grep -c bench_hq_copy || true)" 0
new_env ign2; write_db bench_hq_copy b-1; commit_all "lixo"
JHO_IGNORE_DBS="hq*,bench_*" offsite
eq "obrigatório (hq) que casa com o padrão: broken, rc 1, nada sobe" "$RC:$(objs | wc -l | tr -d ' ')" "1:0"
grep -q 'banco obrigatório hq foi ignorado' "$S/log/offsite.log" && ok "e o log diz que ele foi ignorado pelo padrão" || bad "log sem a razão: $(tail -3 "$S/log/offsite.log")"
new_env ign3; write_db benchmark_real r-1; : > "$ARCH/benchmark_real/config.jsonl"; commit_all "nome parecido"
offsite
eq "nome parecido que não casa (benchmark_real) com export quebrado continua vetando: rc 1" "$RC:$(objs | wc -l | tr -d ' ')" "1:0"
new_env keymm; NOW_OFF=0; offsite   # latest.json passa a apontar para OUTRO snapshot: não se bate o ponto em cima dele, republica
jq '.snapshot_key = "jsonl-hourly/snap/outro.tar.gz"' "$(LATEST)" > "$S/l.json" && cp "$S/l.json" "$(LATEST)"; NOW_OFF=600; offsite
eq "latest.json de outro snapshot: não bate o ponto em cima dele, republica" "${OUT%% key=*}:$(jqf .snapshot_key "$(LATEST)" | grep -c outro)" "RESULT: ok new:0"

echo "-- 8. falhas de upload (todas fail-closed)"; new_env putfail; inject fail_put
offsite
eq "put falha: rc 1, nada no bucket, estado sem sucesso" "$RC:$(objs | wc -l | tr -d ' '):$(jqf '.last_success_sha // "none"' "$ST"):$(jqf .consecutive_not_ok "$ST")" "1:0:none:1"
clear_inject fail_put
new_env lastfail; inject fail_put latest.json
offsite
eq "só latest.json falha: rc 1, artefato e manifest subiram, latest.json não existe, last_success não gravado" "$RC:$(objs | wc -l | tr -d ' '):$([ -e "$(LATEST)" ] && echo has || echo none):$(jqf '.last_success_sha // "none"' "$ST")" "1:2:none:none"
clear_inject fail_put; NOW_OFF=100; offsite
eq "sem a injeção: refaz o upload (não toma o run anterior por sucesso) e fecha" "$RC:$([ -e "$(LATEST)" ] && echo has || echo none)" "0:has"

new_env sizelie; inject lie_size
offsite
eq "S3 devolve tamanho diferente: rc 1, latest.json não criado" "$RC:$([ -e "$(LATEST)" ] && echo has || echo none)" "1:none"
clear_inject lie_size
new_env sumlie; inject lie_checksum
offsite
eq "S3 devolve sha256 diferente: rc 1, latest.json não criado" "$RC:$([ -e "$(LATEST)" ] && echo has || echo none)" "1:none"
clear_inject lie_checksum

new_env sumabsent
cat > "$WORK/bin/aws-nosum" <<'STUB'
#!/bin/bash
# aws que aceita o put mas não devolve ChecksumSHA256 no head
exec 3>&1; out="$("$(dirname "$0")/aws" "$@")"; rc=$?
case " $* " in *" head-object "*) out="$(printf '%s' "$out" | jq -c 'del(.ChecksumSHA256)')" ;; esac
printf '%s\n' "$out"; exit $rc
STUB
chmod +x "$WORK/bin/aws-nosum"
OUT="$(JHO_ARCHIVE="$ARCH" JHO_STATE_DIR="$S/state" JHO_LOG="$S/log/offsite.log" JHO_AWS="$WORK/bin/aws-nosum" JHO_NOTIFY="$WORK/bin/notify" STUB_DIR="$S/bucket" NOTIFY_LOG="$S/notify.log" JHO_REQUIRED_DBS=hq,wa JHO_NOW=$T0 JHO_MIN_FREE_MB=1 "$SCRIPT" 2>"$S/stderr")"; RC=$?
eq "S3 sem checksum no head: rc 1 (ausência não vale como igualdade)" "$RC:$([ -e "$(LATEST)" ] && echo has || echo none)" "1:none"

new_env stubsane
echo hello > "$S/body"; BAD64="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
STUB_DIR="$S/bucket" "$WORK/bin/aws" s3api put-object --bucket b --key k --body "$S/body" --checksum-sha256 "$BAD64" >/dev/null 2>&1 && bad "stub aceitou checksum errado (o stub tem que poder reprovar)" || ok "o stub recusa checksum errado, como o S3"
[ ! -e "$S/bucket/obj/k" ] && ok "e não guarda o objeto recusado" || bad "stub guardou objeto recusado"

echo "-- 9. pré-voo inerte"; new_env lowdisk
OUT="$(JHO_ARCHIVE="$ARCH" JHO_STATE_DIR="$S/state" JHO_LOG="$S/log/offsite.log" JHO_AWS="$WORK/bin/aws" JHO_NOTIFY="$WORK/bin/notify" STUB_DIR="$S/bucket" NOTIFY_LOG="$S/notify.log" JHO_MIN_FREE_MB=999999999 JHO_NOW=$T0 "$SCRIPT" 2>"$S/stderr")"; RC=$?
eq "pouco disco: rc 2, RESULT unknown, nenhuma chamada ao aws" "$RC:${OUT:0:15}:$([ -e "$S/bucket/calls.log" ] && echo called || echo none)" "2:RESULT: unknown:none"
new_env notrepo; rm -rf "$ARCH/.git"; offsite
eq "archive que não é repo git: rc 2, sem aws" "$RC:$([ -e "$S/bucket/calls.log" ] && echo called || echo none)" "2:none"
new_env nocommit; rm -rf "$ARCH/.git"; git init -q "$ARCH"; offsite
eq "repo sem commit: rc 2, sem aws" "$RC:$([ -e "$S/bucket/calls.log" ] && echo called || echo none)" "2:none"
offsite --nao-existe
eq "argumento inválido: rc 3" "$RC" 3

echo "-- 10. lock"; new_env lock
sleep 120 & BG_PID=$!
mkdir -p "$S/state/jsonl-hourly-offsite.lock.d"; echo "$BG_PID" > "$S/state/jsonl-hourly-offsite.lock.d/pid"
offsite
eq "lock com dono vivo: rc 0, silêncio, nada enviado, e NÃO apagou o lock do outro run" "$RC:$([ -e "$S/bucket/calls.log" ] && echo called || echo none):$([ "$(cat "$S/state/jsonl-hourly-offsite.lock.d/pid" 2>/dev/null)" = "$BG_PID" ] && echo kept || echo gone)" "0:none:kept"
kill "$BG_PID" 2>/dev/null; wait "$BG_PID" 2>/dev/null; BG_PID=""
offsite
eq "lock de dono morto: reclamado, run completa" "$RC:$(count_objs '\.tar\.gz$')" "0:1"
[ ! -d "$S/state/jsonl-hourly-offsite.lock.d" ] && ok "lock removido no fim" || bad "lock ficou"
new_env lockpid; mkdir -p "$S/state/jsonl-hourly-offsite.lock.d"
offsite
eq "lock SEM pid e recém-criado (o outro run ainda está começando): rc 0, nada enviado, lock intacto" "$RC:$([ -e "$S/bucket/calls.log" ] && echo called || echo none):$([ -d "$S/state/jsonl-hourly-offsite.lock.d" ] && echo kept || echo gone)" "0:none:kept"
touch -t 202001010000 "$S/state/jsonl-hourly-offsite.lock.d"; offsite
eq "lock sem pid e velho (mais de 1 min): reclamado, run completa" "$RC:$(count_objs '\.tar\.gz$')" "0:1"

echo "-- 11. alerta por falhas seguidas"; new_env alert
printf '{"rows":[{"id":"hq-1"' > "$ARCH/hq/issues.jsonl"; commit_all "quebrado"
NOW_OFF=0; offsite;   eq "falha 1: rc 1, sem alerta" "$RC:$(wc -l < "$S/notify.log" | tr -d ' ')" "1:0"
NOW_OFF=900; offsite; eq "falha 2: rc 1, 1 alerta" "$RC:$(wc -l < "$S/notify.log" | tr -d ' ')" "1:1"
grep -q -- '-p 4' "$S/notify.log" && grep -q 'Jsonl hourly offsite' "$S/notify.log" && ok "alerta: título e prioridade 4" || bad "alerta mal formado: $(cat "$S/notify.log")"
NOW_OFF=1800; offsite; eq "falha 3 (15 min depois): sem novo alerta (limite de 1 a cada 6 h)" "$(wc -l < "$S/notify.log" | tr -d ' ')" 1
NOW_OFF=$((7 * 3600)); offsite; eq "falha 4 (7 h depois): novo alerta" "$(wc -l < "$S/notify.log" | tr -d ' ')" 2
printf '%s' "$(tbl hq-1 hq-2)" > "$ARCH/hq/issues.jsonl"; commit_all "conserto"
NOW_OFF=$((7 * 3600 + 900)); offsite; eq "conserto: rc 0, contador zera" "$RC:$(jqf .consecutive_not_ok "$S/state/jsonl-hourly-offsite-state.json")" "0:0"
printf '{"rows":[{"id":"hq-1"' > "$ARCH/hq/issues.jsonl"; commit_all "quebrou de novo"
NOW_OFF=$((7 * 3600 + 1800)); offsite
eq "quebrou de novo: 1ª falha da nova série não alerta" "$RC:$(wc -l < "$S/notify.log" | tr -d ' ')" "1:2"
# o alerta tem que CHEGAR (push forçado, saída estrita) e só então conta como enviado; senão AVISO, limite de 6 h intocado e nova tentativa no run seguinte
broke() { printf '{"rows":[{"id":"hq-1"' > "$ARCH/hq/issues.jsonl"; commit_all "quebrado"; }
new_env push; broke; NOW_OFF=0; offsite; NOW_OFF=900; offsite
eq "alerta chegou ao telefone (push forçado) e o log diz enviado" "$(pushed):$(grep -c 'alerta enviado' "$S/log/offsite.log")" "1:1"
undelivered() { # nome VAR=valor — notify que sai sem entregar (12 = digest/teto; binário ausente = 127)
  new_env "$1"; broke; export "$2"; NOW_OFF=0; offsite; NOW_OFF=900; offsite
  eq "$2: alerta não entregue: AVISO no log, sem 'enviado', sem last_alert_epoch" "$(grep -c 'alerta NÃO entregue' "$S/log/offsite.log"):$(grep -c 'alerta enviado' "$S/log/offsite.log"):$(jqf '.last_alert_epoch // "none"' "$ST")" "1:0:none"
  unset "${2%%=*}"; NOW_OFF=1800; offsite
  eq "$2: o run seguinte (notify de volta, ainda dentro das 6 h) entrega" "$(pushed)" 1
}
undelivered alert12 NOTIFY_RC=12; undelivered alert127 "NOTIFY_BIN=$WORK/bin/inexistente"
new_env prelock; AWS_BIN=/nao/existe; NOW_OFF=0; offsite; r1="$RC:$(grep -c 'UNKNOWN: aws ausente' "$S/log/offsite.log"):$(jqf .consecutive_not_ok "$ST")"
NOW_OFF=900; offsite; unset AWS_BIN
eq "pré-lock (aws ausente): rc 2, linha no log e conta como run sem snapshot" "$r1" "2:1:1"
eq "pré-lock: a 2ª seguida alerta e o alerta chega" "$(pushed)" 1
new_env nostate; : > "$S/arquivo"; STATE_OVR="$S/arquivo/x" offsite
eq "sem como gravar o estado: rc 2 e, sem contador, o alerta sai já (não fica mudo)" "$RC:$(pushed)" "2:1"
# lock que não se cria (estado existe e não grava; lock velho que não sai) não é "outro run": rc 2 e, sem como gravar o contador, o alerta sai já; nunca rc 0 mudo
new_env nolock; chmod 555 "$S/state"; offsite; chmod 755 "$S/state"
eq "lock não criado (estado sem permissão de escrita): rc 2, UNKNOWN no log e o alerta sai" "$RC:$(grep -c 'UNKNOWN: não consegui criar o lock' "$S/log/offsite.log"):$(pushed)" "2:1:1"
new_env stuck; L="$S/state/jsonl-hourly-offsite.lock.d"; mkdir "$L"; echo 99999999 > "$L/pid"; touch -t 202001010000 "$L"; chmod 555 "$S/state"; offsite; chmod 755 "$S/state"
eq "lock velho que não sai (rm -rf falha): rc 2, UNKNOWN e o alerta sai" "$RC:$(grep -c 'UNKNOWN: não consegui pegar o lock' "$S/log/offsite.log"):$(pushed)" "2:1:1"
new_env dead; broke; printf '{"consecutive_not_ok":0,"attempt_open":true}\n' > "$ST"; NOW_OFF=0; offsite
eq "run anterior morto (timeout do order, kill, reboot) conta: com a falha de agora são 2 seguidas e o alerta sai" "$RC:$(pushed)" "1:1"
NOW_OFF=900; offsite
eq "a tentativa fechou: o run morto não é recontado" "$(grep -c 'run anterior não terminou' "$S/log/offsite.log")" 1

echo "-- 12. retenção"; new_env ret
seed_stems() { python3 -I - "$S/bucket" "$T0" <<'PYEOF'
import datetime, os, sys
root, t0 = sys.argv[1], int(sys.argv[2])
for h in list(range(1, 21)) + list(range(60, 121)):   # 20 snapshots DENTRO da janela de 48 h (o piso de 6 não os cobre todos) + 61 fora dela
    t = datetime.datetime.fromtimestamp(t0 - h * 3600, datetime.timezone.utc)
    stem = t.strftime("%Y%m%dT%H%M%SZ") + "-%012x" % (0x100 + h)
    for ext in ("tar.gz", "manifest.json"):
        p = os.path.join(root, "obj", "jsonl-hourly", "snap", stem + "." + ext)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").write("x")
for extra in ("jsonl-hourly/snap/notes.txt", "jsonl-hourly/_probe/x", "jsonl-hourly/snap/20200101T000000Z-zzzzzzzzzzzz.tar.gz"):
    p = os.path.join(root, "obj", extra)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write("keep")
PYEOF
}
seed_stems
( cd "$S/bucket/obj" && find . -type f | sed 's|^\./||' | grep '^jsonl-hourly/snap/' | sort ) > "$S/before.txt"
NOW_OFF=0; offsite
eq "rc 0" "$RC" 0
LISTED="$( (cat "$S/before.txt"; echo "$(jqf .snapshot_key "$(LATEST)")"; echo "$(jqf .manifest_key "$(LATEST)")") | sort -u)"
EXPECT="$(printf '%s\n' "$LISTED" | python3 -I "$PYH" retention --prefix jsonl-hourly --now "$T0" --floor 6 --protect "$(jqf .snapshot_key "$(LATEST)")" | sort)"
GOT="$(sort "$S/bucket/deletes.log" 2>/dev/null)"
[ -n "$GOT" ] && ok "retenção apagou algo ($(echo "$GOT" | wc -l | tr -d ' ') chaves)" || bad "retenção não apagou nada"
eq "o que foi apagado = o que o helper manda apagar (listagem -> helper -> delete)" "$GOT" "$EXPECT"
for k in jsonl-hourly/snap/notes.txt jsonl-hourly/_probe/x jsonl-hourly/snap/20200101T000000Z-zzzzzzzzzzzz.tar.gz jsonl-hourly/latest.json; do
  [ -e "$S/bucket/obj/$k" ] && ok "retenção não tocou em $k" || bad "retenção apagou $k"
done
[ -e "$S/bucket/obj/$(jqf .snapshot_key "$(LATEST)")" ] && ok "o snapshot novo (latest) sobreviveu" || bad "retenção apagou o latest"
INWIN_GONE=0
for h in $(seq 1 20); do
  stem="$(python3 -I -c 'import datetime,sys;t=int(sys.argv[1])-int(sys.argv[2])*3600;print(datetime.datetime.fromtimestamp(t,datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")+"-%012x"%(0x100+int(sys.argv[2])))' "$T0" "$h")"
  [ -e "$S/bucket/obj/jsonl-hourly/snap/$stem.tar.gz" ] || INWIN_GONE=$((INWIN_GONE + 1))
done
eq "a janela padrão (48 h) vale no script: os 20 snapshots de 1 a 20 h atrás sobreviveram" "$INWIN_GONE" 0
eq "nenhum snapshot ficou pela metade (tar.gz sem manifest ou o contrário)" "$(objs | grep -E '^jsonl-hourly/snap/[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}\.' | sed -E 's/\.(tar\.gz|manifest\.json)$//' | sort | uniq -c | awk '$1!=2' | wc -l | tr -d ' ')" 0

new_env retfail; seed_stems; inject fail_list
offsite
eq "listagem falha: o run continua OK (rc 0), snapshot novo no S3, nada apagado" "$RC:$([ -e "$(LATEST)" ] && echo has):$([ -e "$S/bucket/deletes.log" ] && echo deleted || echo none)" "0:has:none"
grep -q 'retenção pulada' "$S/log/offsite.log" && ok "e registra que a retenção foi pulada" || bad "sem registro de retenção pulada"
clear_inject fail_list
new_env retdel; seed_stems; inject fail_delete
offsite
eq "delete falha: o run continua OK (rc 0), com aviso por chave" "$RC:$(grep -c 'não apaguei' "$S/log/offsite.log" | awk '{print ($1>0)?"warned":"silent"}')" "0:warned"
clear_inject fail_delete
new_env retjunk; seed_stems; inject garbage_list
offsite
eq "listagem ILEGÍVEL (não só falha): rc 0, nada apagado, e o log diz que pulou (não '0 chaves')" "$RC:$([ -e "$S/bucket/deletes.log" ] && echo deleted || echo none):$(grep -c 'retenção pulada' "$S/log/offsite.log"):$(grep -c 'retenção: ' "$S/log/offsite.log")" "0:none:1:0"
clear_inject garbage_list
new_env rethelp; seed_stems
WRAP=retention_fail JHO_PY="$WORK/bin/wrap.py" offsite
eq "helper de retenção falha: rc 0, nada apagado, e o log diz que pulou (não '0 apagadas')" "$RC:$([ -e "$S/bucket/deletes.log" ] && echo deleted || echo none):$(grep -c 'o helper falhou' "$S/log/offsite.log"):$(grep -c 'retenção: ' "$S/log/offsite.log")" "0:none:1:0"
new_env nolatest
WRAP=db_string JHO_PY="$WORK/bin/wrap.py" offsite
eq "latest.json que não monta: rc 1 e nenhum latest.json no bucket (nem um vazio)" "$RC:$([ -e "$(LATEST)" ] && echo has || echo none)" "1:none"
case "$OUT" in "RESULT: fail não montei latest.json"*) ok "e o RESULT diz que não montou" ;; *) bad "esperava 'fail não montei latest.json' (obtido: $OUT)" ;; esac

echo "-- 13. --status"; new_env status
NOW_OFF=0; offsite
NOW_OFF=1800; offsite --status; eq "30 min depois: rc 0, STATUS: OK" "$RC:${OUT%% *}:$(echo "$OUT" | awk '{print $2}')" "0:STATUS::OK"
NOW_OFF=$((3 * 3600)); offsite --status; eq "3 h depois: rc 1, STALE, e o STATUS diz até quando o dado enxerga" "$RC:$(echo "$OUT" | awk '{print $2}'):$(echo "$OUT" | grep -c 'data_as_of=')" "1:STALE:1"
printf '{"snapshot_key":"x"}' > "$(LATEST)"
offsite --status; eq "latest.json sem checked_at/data_as_of: rc 2, UNKNOWN" "$RC:$(echo "$OUT" | awk '{print $2}')" "2:UNKNOWN"
rm -f "$(LATEST)"; offsite --status; eq "sem latest.json: rc 2, UNKNOWN" "$RC:$(echo "$OUT" | awk '{print $2}')" "2:UNKNOWN"
inject fail_get; NOW_OFF=0; offsite --status; eq "S3 falhando na leitura: rc 2, UNKNOWN (não dá OK nem STALE)" "$RC:$(echo "$OUT" | awk '{print $2}')" "2:UNKNOWN"
new_env fut; NOW_OFF=0; offsite; jq '.checked_at = "2999-01-01T00:00:00Z"' "$(LATEST)" > "$S/l.json" && cp "$S/l.json" "$(LATEST)"
offsite --status; eq "checked_at no futuro: rc 2, UNKNOWN (idade negativa não é OK)" "$RC:$(echo "$OUT" | awk '{print $2}')" "2:UNKNOWN"

# ── 13b. fonte parada x fonte ociosa ─────────────────────────────────────────────────────────────
# HEAD velho NÃO é exporter parado (ele só comita quando o dado muda: 7 intervalos > 6 h em 12 dias, com ele rodando); parado = não reescreve os bancos (mtime). Parado ou ilegível: sem "ponto batido".
echo "-- 13b. fonte parada x fonte ociosa"; new_env idle; NOW_OFF=0; offsite
NOW_OFF=$((7 * 3600)); offsite; r1="$RC:${OUT%% key=*}"; offsite --status
eq "exporter ocioso (HEAD de 7 h, mas ele reescreve os bancos): unchanged, STATUS OK, sem alerta" "$r1:$(echo "$OUT" | awk '{print $2}'):$(pushed)" "0:RESULT: ok unchanged:OK:0"
new_env srcdead; SRC_STOP=0; NOW_OFF=0; offsite
NOW_OFF=$((5 * 3600)); offsite; C5="$(jqf .checked_at "$(LATEST)")"
eq "exporter parado há 5 h (< 6 h): ainda dentro da folga, rc 0" "$RC:$(jqf .consecutive_not_ok "$ST")" "0:0"
NOW_OFF=$((7 * 3600)); offsite
eq "parado há 7 h: rc 1, fail fonte parada, conta 1, latest.json sem checked_at novo" "$RC:${OUT:0:25}:$(jqf .consecutive_not_ok "$ST"):$([ "$(jqf .checked_at "$(LATEST)")" = "$C5" ] && echo same)" "1:RESULT: fail fonte parada:1:same"
NOW_OFF=$((8 * 3600)); offsite
eq "2ª seguida: conta 2 e o alerta chega ao telefone nomeando a fonte" "$(jqf .consecutive_not_ok "$ST"):$(pushed):$(grep -c 'fonte parada' "$S/notify.pushed")" "2:1:1"
offsite --status; eq "STATUS: STALE (o checked_at não andou)" "$RC:$(echo "$OUT" | awk '{print $2}')" "1:STALE"
write_db hq hq-1 hq-2 hq-3; commit_all "hq-3"; NOW_OFF=$((9 * 3600)); offsite
eq "HEAD novo com o exporter parado: o snapshot sobe, mas rc 1, fail fonte parada e a contagem não zera" "$RC:${OUT:0:25}:$(count_objs '\.tar\.gz$'):$(jqf .consecutive_not_ok "$ST")" "1:RESULT: fail fonte parada:2:3"
unset SRC_STOP
new_env stuckc; NOW_OFF=0; offsite; write_db hq hq-1 hq-2 hq-3   # o exporter ESCREVE (mtime novo) e não comita: árvore adiante do HEAD
NOW_OFF=$((5 * 3600)); offsite; C5="$(jqf .checked_at "$(LATEST)")"; r1="$RC"
NOW_OFF=$((7 * 3600)); offsite
eq "escreve e não comita: 5 h (< 6 h) ainda ok; 7 h: rc 1, fail fonte parada, conta 1, checked_at parado" "$r1:$RC:${OUT:0:25}:$(jqf .consecutive_not_ok "$ST"):$([ "$(jqf .checked_at "$(LATEST)")" = "$C5" ] && echo same)" "0:1:RESULT: fail fonte parada:1:same"
NOW_OFF=$((8 * 3600)); offsite
eq "2ª seguida: conta 2 e o alerta chega ao telefone dizendo que não comita" "$(jqf .consecutive_not_ok "$ST"):$(pushed):$(grep -c 'não comita' "$S/notify.pushed")" "2:1:1"
commit_all "hq-3"; NOW_OFF=$((9 * 3600)); offsite
eq "o exporter volta a comitar (árvore = HEAD): snapshot novo, rc 0, conta zera" "$RC:${OUT%% key=*}:$(jqf .consecutive_not_ok "$ST")" "0:RESULT: ok new:0"
new_env gitdiff; NOW_OFF=0; offsite; NOW_OFF=$((7 * 3600)); GIT_FAIL_DIFF=1 PATH="$WORK/gitbin:$PATH" offsite
eq "git diff falha (HEAD de 7 h): não sei, e não sei não é vivo: rc 1, fail fonte parada" "$RC:${OUT:0:25}:$(printf '%s' "$OUT" | grep -c 'comparar a árvore')" "1:RESULT: fail fonte parada:1"
new_env nomtime; NOW_OFF=0; offsite; rm -f "$ARCH/wa/issues.jsonl"; NOW_OFF=600; offsite
eq "sem como ler quando o exporter escreveu (arquivo ausente): não vale como vivo, rc 1" "$RC:${OUT:0:25}" "1:RESULT: fail fonte parada"

echo "-- 14. helper python (suíte própria)"
if [ -n "${JHO_SKIP_PYSUITE:-}" ]; then
  # só para a campanha de mutantes do SHELL (a suíte python tem a campanha dela); numa rodada normal isto nunca é ligado
  echo "  (pulado: JHO_SKIP_PYSUITE está ligado)"
else
  PYOUT="$(cd "$(dirname "$PYH")" && python3 -I "$(dirname "$PYH")/jsonl_hourly.selftest.py" 2>&1)"; PYRC=$?
  echo "$PYOUT" | grep -E 'FAIL' | head -20
  PYSUM="$(echo "$PYOUT" | grep 'RESULT:' | tail -1)"
  eq "jsonl_hourly.selftest.py: rc 0 ($PYSUM)" "$PYRC" 0
  PP="$(echo "$PYSUM" | sed -E 's/.*PASS=([0-9]+).*/\1/')"; PF="$(echo "$PYSUM" | sed -E 's/.*FAIL=([0-9]+).*/\1/')"
  case "$PP$PF" in ""|*[!0-9]*) ;; *) PASS=$((PASS + PP)); FAIL=$((FAIL + PF)) ;; esac
fi

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
