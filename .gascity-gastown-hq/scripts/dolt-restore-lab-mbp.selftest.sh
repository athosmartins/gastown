#!/bin/bash
# dolt-restore-lab-mbp.selftest.sh — tests for dolt-restore-lab-mbp.sh, the mini's half (ga-3kmvyr, slice 2/4: --dry-run and --check).
#
# Hermetic: the REAL orchestrator runs against FAKES — aws (latest.json, the object listing), the live dolt and mbp-run.sh (--check
# only). Nothing of the live city, S3, the MBP or the real dolt is touched. The canary credential sits in the orchestrator's
# environment (the mini has one): it must reach neither mbp-run nor any file or output, and no sts call and no object read is ever made.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_SRC="${LABMBP_SCRIPT_UNDER_TEST:-$HERE/dolt-restore-lab-mbp.sh}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (esperado '$2', veio '$1')"; fi; }
has()  { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (nao achei '$2')"; fi; }
hasnt(){ if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (achei '$2')"; else ok "$3"; fi; }
HEAD_H="gaffd3qkn1bfe87s8tgvoiic790r1u62"

mkdir -p "$T/scripts" "$T/bin" "$T/secret" "$T/s3/hq"
cp "$ORCH_SRC" "$T/scripts/dolt-restore-lab-mbp.sh"
printf 'AKIACANARYTESTKEY123\nCANARYsecretKEY0123456789abcdef/+xyz\nCANARYtoken0123456789ABCDEFGHIJKLMNOP==\n' > "$T/secret/canary.txt"
# the S3 fixture: 5 files, one zero-size, one nested, one multipart (9 MiB = 2 parts of 8 MiB)
python3 -I - "$T/s3/hq" <<'PY'
import os, sys
r = sys.argv[1]; os.makedirs(r + "/oldgen")
open(r + "/manifest", "w").write("manifest-of-the-backup\n")
open(r + "/LOCK", "w").close()
open(r + "/abc123", "wb").write(bytes(range(256)) * 2)
open(r + "/oldgen/aaa", "wb").write(b"y" * 1000)
open(r + "/big", "wb").write(b"x" * (9 * 1024 * 1024))
PY
EXPB=$(find "$T/s3/hq" -type f -exec stat -f %z {} + | awk '{ s += $1 } END { print s }'); EXPKB=$(( (EXPB + 1023) / 1024 ))

# ---- fakes -----------------------------------------------------------------------------------------------------------------
cat > "$T/bin/aws" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_CAP/aws.argv"
case "$1 $2" in
  "s3 cp")
    case "$3" in
      */_meta/latest.json)
        [ "${FAKE_AWS_HANG:-0}" != 1 ] || exec sleep 30   # pendurado: so o timeout do orquestrador resolve
        if [ -n "${FAKE_GATE:-}" ]; then g=0; while [ ! -e "$FAKE_GATE" ] && [ "$g" -lt 300 ]; do sleep 0.2; g=$((g+1)); done; fi   # segura quem tem a trava
        [ "${FAKE_LATEST_FAIL:-0}" != 1 ] || { echo "An error occurred (AccessDenied) when calling the GetObject operation" >&2; exit 1; }
        case "${FAKE_LATEST:-ok}" in
          ok) cat "$FAKE_ROOT/latest1.json" ;;
          nohead) printf '{"run_utc":"2026-10-16T07:07:25Z","databases":{"hq":{"issues":5}}}\n' ;;
          badhead) printf '{"run_utc":"2026-10-16T07:07:25Z","databases":{"hq":{"head":"x; DROP TABLE issues"}}}\n' ;;
          norun) printf '{"databases":{"hq":{"head":"%s"}}}\n' "$FAKE_HEAD" ;;
          otherdb) printf '{"run_utc":"2026-10-16T07:07:25Z","databases":{"hq_old":{"head":"%s"}}}\n' "$FAKE_HEAD" ;;
          html) echo "<html>503 Slow Down</html>" ;;
          # entrada hostil: o que o S3 devolve nunca vira SQL do banco vivo
          tabsql) printf '{"run_utc":"2026-10-16T07:07:25Z\\t'"'"'; CREATE TABLE pwned (i int); -- ","databases":{"hq":{"head":"%s"}}}\n' "$FAKE_HEAD" ;;
          nlrun) printf '{"run_utc":"2026-10-16T07:07:25Z\\n","databases":{"hq":{"head":"%s"}}}\n' "$FAKE_HEAD" ;;
          trailrun) printf '{"run_utc":"2026-10-16T07:07:25Zjunk","databases":{"hq":{"head":"%s"}}}\n' "$FAKE_HEAD" ;;
          uniutc) printf '{"run_utc":"\\u0662\\u0660\\u0662\\u0666-10-16T07:07:25Z","databases":{"hq":{"head":"%s"}}}\n' "$FAKE_HEAD" ;;
          nlhead) printf '{"run_utc":"2026-10-16T07:07:25Z","databases":{"hq":{"head":"%s\\n"}}}\n' "$FAKE_HEAD" ;;
          tabhead) printf '{"run_utc":"2026-10-16T07:07:25Z","databases":{"hq":{"head":"%s\\t'"'"'; CREATE TABLE pwned (i int); -- "}}}\n' "$FAKE_HEAD" ;;
          longhead) printf '{"run_utc":"2026-10-16T07:07:25Z","databases":{"hq":{"head":"%sa"}}}\n' "$FAKE_HEAD" ;;
        esac ;;
      *) echo x >> "$FAKE_CAP/objreads"; exit 1 ;;   # a dry-run never reads an object
    esac ;;
  "s3api list-objects-v2")
    [ "${FAKE_LIST_HANG:-0}" != 1 ] || exec sleep 30
    [ "${FAKE_LIST_FAIL:-0}" != 1 ] || { echo "An error occurred (AccessDenied) when calling the ListObjectsV2 operation" >&2; exit 1; }
    [ "${FAKE_LIST_EMPTY:-0}" != 1 ] || { echo None; exit 0; }
    PYTHONIOENCODING=utf-8 python3 -I - "$FAKE_ROOT/s3" <<'PY'
import hashlib, os, sys
root = sys.argv[1]; E = os.environ; P = 8 * 1024 * 1024
for d, _, fs in sorted(os.walk(root + "/hq")):
    for f in sorted(fs):
        p = os.path.join(d, f); key = os.path.relpath(p, root); digs = []; n = 0
        with open(p, "rb") as fh:
            while True:
                c = fh.read(P)
                if not c: break
                digs.append(hashlib.md5(c).digest()); n += len(c)
        e = hashlib.md5(b"").hexdigest() if not digs else digs[0].hex() if len(digs) == 1 else "%s-%d" % (hashlib.md5(b"".join(digs)).hexdigest(), len(digs))
        if E.get("FAKE_LIST_ZERO") == "1": n = 0
        if E.get("FAKE_LIST_ETAG_JUNK") == key: e = "not-an-etag"
        if E.get("FAKE_LIST_SIZE_JUNK") == key: n = "12KB"
        if E.get("FAKE_LIST_SIZE_UNI") == key: n = "\u0665"
        print("%s\t%s\t\"%s\"" % (key, n, e))
bk = os.environ.get("FAKE_LIST_BADKEY")
if bk: print({"1": "hq/a;touch pwned", "2": "hq/../x", "3": "other/x", "4": "hq/a b"}[bk] + "\t5\t\"d41d8cd98f00b204e9800998ecf8427e\"")
PY
    ;;
  "sts "*) echo x >> "$FAKE_CAP/sts.calls"; echo "AccessDenied" >&2; exit 254 ;;
  *) exit 1 ;;
esac
EOF
cat > "$T/bin/dolt" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_CAP/dolt.argv"
[ "${FAKE_DOLT_DOWN:-0}" != 1 ] || { echo "connection refused" >&2; exit 1; }
[ "${FAKE_DOLT_HANG:-0}" != 1 ] || exec sleep 30
q=""; while [ $# -gt 0 ]; do [ "$1" = -q ] && { q="$2"; break; }; shift; done
case "$q" in
  *"FROM dolt_log"*) printf 'COUNT(*)\n%s\n' "${FAKE_HEAD_COUNT:-1}" ;;
  "SHOW FULL TABLES AS OF"*)
    case "${FAKE_TABLES:-ok}" in
      ok) printf 'Tables_in_hq,Table_type\nissues,BASE TABLE\nblocked,VIEW\nlabels,BASE TABLE\n' ;;
      none) printf 'Tables_in_hq,Table_type\nblocked,VIEW\n' ;;
      badname) printf 'Tables_in_hq,Table_type\nissues,BASE TABLE\n"a;b",BASE TABLE\n' ;;
    esac ;;
  # the right counts only come back when EVERY table is counted AS OF a commit; a count of the live table gets other numbers
  *"UNION ALL"*)
    [ "${FAKE_COUNT_FAIL:-0}" != 1 ] || { echo "table not found" >&2; exit 1; }
    [ "${FAKE_COUNT_JUNK:-0}" != 1 ] || { printf 't,n\nissues,many\nlabels,7\n'; exit 0; }
    [ "${FAKE_COUNT_UNI:-0}" != 1 ] || { printf 't,n\nissues,\xd9\xa5\nlabels,7\n'; exit 0; }   # U+0665: str.isdigit() aceita, int() converte
    [ "${FAKE_COUNT_PARTIAL:-0}" != 1 ] || { printf 't,n\nissues,5\n'; echo "connection lost" >&2; exit 1; }   # imprime a 1a tabela e morre: o que sobra NAO pode parecer um manifest
    case "$q" in
      *'`issues` AS OF '*'`labels` AS OF '*) printf 't,n\nissues,5\nlabels,7\n' ;;
      *) printf 't,n\nissues,6\nlabels,8\n' ;;
    esac ;;
  *) echo "fake dolt: consulta inesperada: $q" >&2; exit 1 ;;
esac
EOF
# mbp-run: only --check exists in this slice. FAKE_PRESENCE chooses the answer. Same lines as the REAL mbp-run --check (probe, offload_flag=, paused_local=), and each
# scenario gets exactly ONE thing wrong (pausa/ram/semp/pl1/offoff/semflag/sempl/big: presence=livre, but the MBP REFUSES or does not prove it); raw = FAKE_RAW (printf %b), rc FAKE_RAW_RC.
cat > "$T/scripts/mbp-run.sh" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_CAP/mbprun.calls"
env > "$FAKE_CAP/mbprun.env.$$"
case "${FAKE_PRESENCE:-livre}" in
  livre) printf 'presence=livre\npresence_why=ocioso\npaused=0\navail_mb=5000\noffload_flag=on\npaused_local=0\n' ;;
  uso) printf 'presence=uso\npresence_why=teclado\npaused=0\noffload_flag=on\npaused_local=0\n' ;;
  lixo) printf 'algo=estranho\n' ;;
  vazio) ;;
  pausa) printf 'presence=livre\npaused=1\noffload_flag=on\npaused_local=0\n'; exit 99 ;;
  ram) echo "mbp-run: RAM/swap alto — rode local"; printf 'presence=livre\npaused=0\noffload_flag=on\npaused_local=0\n'; exit 98 ;;
  semp) printf 'presence=livre\npresence_why=ocioso\noffload_flag=on\npaused_local=0\n' ;;
  pl1) printf 'presence=livre\npaused=0\noffload_flag=on\npaused_local=1\n' ;;
  offoff) printf 'presence=livre\npaused=0\noffload_flag=off\npaused_local=0\n' ;;   # o que o mbp-run real imprime, com rc 0, quando o dono desligou o uso
  semflag) printf 'presence=livre\npaused=0\npaused_local=0\n' ;;
  sempl) printf 'presence=livre\npaused=0\noffload_flag=on\n' ;;
  big) printf 'presence=livre\npaused=0\noffload_flag=on\npaused_local=0\n'; i=0; while [ "$i" -lt 300 ]; do printf 'task=%0900d|x|y|z\n' 0; i=$((i+1)); done ;;   # tudo certo, e ~270 KB depois das chaves
  raw) printf '%b' "$FAKE_RAW"; exit "${FAKE_RAW_RC:-0}" ;;
  off) echo "mbp-run: MBP inalcançável (ssh rc=255) — rode local"; printf 'offload_flag=on\n'; exit 98 ;;
esac
exit 0
EOF
# pylie: faz as vezes do python3; no modo `meta` APROVA o que FAKE_PYLIE disser (um ajudante que deixou passar valor hostil); o resto e o python3 de verdade
cat > "$T/bin/pylie" <<'EOF'
#!/bin/bash
if [ "${4:-}" = meta ]; then cat > /dev/null; printf '%b\n' "$FAKE_PYLIE"; exit 0; fi
exec python3 "$@"
EOF
mkdir -p "$T/fakedate"   # date com o segundo CONGELADO so no nome da pasta da rodada: duas rodadas "no mesmo segundo"
printf '#!/bin/bash\n[ "$*" = "-u +%%Y%%m%%dT%%H%%M%%SZ" ] && { echo 20261016T000000Z; exit 0; }\nexec /bin/date "$@"\n' > "$T/fakedate/date"
chmod +x "$T/bin/"* "$T/scripts/"*.sh "$T/fakedate/date"
printf '{"run_utc":"2026-10-16T07:07:25Z","databases":{"hq":{"issues":5,"head":"%s","backup_size":"13G"}}}\n' "$HEAD_H" > "$T/latest1.json"

# ---- harness ---------------------------------------------------------------------------------------------------------------
reset() {
  rm -rf "$T/state" "$T/cap" "$T/city" "$T/pwned"
  mkdir -p "$T/state" "$T/cap" "$T/city/.gc/runtime/packs/dolt"
  printf 'listener:\n  port: 4242\n' > "$T/city/.gc/runtime/packs/dolt/dolt-config.yaml"
}
# envrun [args] — FAKE_*/LABMBP_* come from the caller's environment prefix. The mini HAS an AWS credential (the canary).
envrun() {
  env LABMBP_CITY="$T/city" LABMBP_STATE="${STATE_OVERRIDE:-$T/state}" LABMBP_AWS="$T/bin/aws" LABMBP_DOLT="$T/bin/dolt" FAKE_HEAD="$HEAD_H" \
      AWS_ACCESS_KEY_ID="$(sed -n 1p "$T/secret/canary.txt")" AWS_SECRET_ACCESS_KEY="$(sed -n 2p "$T/secret/canary.txt")" AWS_SESSION_TOKEN="$(sed -n 3p "$T/secret/canary.txt")" \
      FAKE_CAP="$T/cap" FAKE_ROOT="$T" "${LABMBP_TEST_BASH:-bash}" "$T/scripts/dolt-restore-lab-mbp.sh" "$@"
}
run() { OUT=$(envrun "$@" 2>&1); RC=$?; }
canary_hits() {   # files that must not hold the canary + the output of the run
  local n; n=$(grep -rIlF -f "$T/secret/canary.txt" "$T/cap" "$T/state" "$T/city" 2>/dev/null | grep -c .)
  printf '%s' "$OUT" | grep -qF -f "$T/secret/canary.txt" && n=$((n+1)); echo "$n"
}
cnt() { local n; n=$(grep -c "$2" "$T/cap/$1" 2>/dev/null); echo "${n:-0}"; }
calls() { cnt "$1" .; }
RUNDIR() { ls -d "$T"/state/runs/*/ 2>/dev/null | head -1; }

echo "== ga-3kmvyr.2: orquestrador, metade do mini (manifest AS OF + lista do S3; nada vai ao MBP) =="
# ---------------------------------------------------------------------------------------------------------------------------------
echo "-- dry-run, caminho feliz, credencial canario no ambiente do mini"
reset; run --dry-run
check "$RC" 0 "dry-run: rc 0"
has "$OUT" "RESULT: DRY db=hq rc=0 as_of=$HEAD_H tabelas=2 objetos=5" "RESULT traz o veredito DRY, o commit AS OF, as tabelas e os objetos"
check "$(python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m["as_of"], sorted(m["tables"].items()), m["schema"], m["db"])' "$(RUNDIR)manifest.json")" "$HEAD_H [('issues', 5), ('labels', 7)] 1 hq" "manifest: commit do latest.json, so BASE TABLE (a view fica de fora), contagens AS OF"
has "$OUT" '"tables": {"issues": 5, "labels": 7}' "o manifest foi mostrado na saida"
has "$OUT" "run_utc=2026-10-16T07:07:25Z" "a impressao digital do backup (run_utc) foi registrada"
has "$(cat "$T/cap/dolt.argv")" "AS OF '$HEAD_H'" "a contagem foi feita AS OF o commit"
has "$(cat "$T/cap/dolt.argv")" "commit_hash = '$HEAD_H'" "o commit foi procurado no log do banco vivo"
has "$(cat "$T/cap/dolt.argv")" "--port 4242" "a porta vem do dolt-config.yaml da cidade"
has "$(cat "$T/cap/aws.argv")" "s3api list-objects-v2 --bucket urblink-dolt-backups --prefix hq/" "a lista de objetos vem do S3 (prefixo hq/)"
check "$(wc -l < "$(RUNDIR)listing.tsv" | tr -d ' ')" 5 "listing.tsv: 5 objetos"
check "$(grep -c '"' "$(RUNDIR)listing.tsv")" 0 "listing.tsv: aspas do ETag tiradas"
check "$(awk -F'\t' '$1=="hq/big"{print $2, ($3 ~ /^[0-9a-f]{32}-2$/ ? "mp2" : "x")}' "$(RUNDIR)listing.tsv")" "9437184 mp2" "o multiparte (9 MiB) vem com ETag -2 e o tamanho certo"
check "$(awk -F'\t' '$1=="hq/LOCK"{print $2, $3}' "$(RUNDIR)listing.tsv")" "0 d41d8cd98f00b204e9800998ecf8427e" "o objeto vazio entra na lista (tamanho 0, md5 do vazio)"
has "$OUT" "lista do S3: 5 objetos, ${EXPKB}KB (nada foi enviado)" "o tamanho total (KB) bate com o fixture"
check "$(calls objreads)" 0 "nenhum objeto foi lido do S3 (so a lista e o latest.json)"
check "$(calls mbprun.calls)" 0 "o MBP nao foi tocado"
check "$(calls sts.calls)" 0 "nenhum sts foi chamado"
check "$(canary_hits)" 0 "CREDENCIAL: o canario nao esta em nenhum arquivo nem na saida"
check "$(ls "$T/state")" "runs" "a trava foi liberada no fim (so sobrou runs/)"
has "$(cat "$(RUNDIR)orchestrator.log")" "RESULT: DRY" "orchestrator.log da rodada guarda o resultado"

echo "-- dry-run: sem o latest.json valido, sem commit no vivo, sem contagem = UNKNOWN (nunca OK)"
chk_unknown() {   # $1 = o que deve aparecer no motivo; $2 = rotulo; $3 = lista chamada? (sim/nao)
  check "$RC" 2 "$2: rc 2"
  has "$OUT" "RESULT: UNKNOWN db=hq rc=2" "$2: RESULT UNKNOWN"
  has "$OUT" "$1" "$2: o motivo diz o que faltou"
  check "$(cnt aws.argv list-objects-v2)" "$([ "$3" = sim ] && echo 1 || echo 0)" "$2: lista do S3 $([ "$3" = sim ] && echo consultada || echo nao consultada)"
  check "$(calls objreads)" 0 "$2: nenhum objeto lido"
}
reset; FAKE_LATEST_FAIL=1 run --dry-run;  chk_unknown "nao li _meta/latest.json: An error occurred (AccessDenied)" "latest.json ilegivel (S3 negou)" nao
reset; FAKE_LATEST=html run --dry-run;    chk_unknown "sem run_utc/head valido para hq" "latest.json nao e JSON" nao
reset; FAKE_LATEST=nohead run --dry-run;  chk_unknown "sem run_utc/head valido para hq" "latest.json sem head" nao
reset; FAKE_LATEST=badhead run --dry-run; chk_unknown "sem run_utc/head valido para hq" "head com cara de SQL" nao
reset; FAKE_LATEST=norun run --dry-run;   chk_unknown "sem run_utc/head valido para hq" "latest.json sem run_utc" nao
reset; FAKE_LATEST=otherdb run --dry-run; chk_unknown "sem run_utc/head valido para hq" "latest.json sem o banco pedido" nao
reset; FAKE_HEAD_COUNT=0 run --dry-run;   chk_unknown "o commit $HEAD_H do latest.json NAO existe no banco vivo" "commit ausente no vivo" nao
reset; FAKE_HEAD_COUNT=muitos run --dry-run; chk_unknown "nao consegui perguntar ao dolt vivo se o commit existe" "resposta do dolt que nao e numero" nao
reset; FAKE_DOLT_DOWN=1 run --dry-run;    chk_unknown "connection refused" "dolt vivo fora do ar" nao
reset; rm "$T/city/.gc/runtime/packs/dolt/dolt-config.yaml"; run --dry-run; chk_unknown "porta do dolt ilegivel" "sem dolt-config.yaml" nao
reset; printf 'listener:\n  port: abc\n' > "$T/city/.gc/runtime/packs/dolt/dolt-config.yaml"; run --dry-run; chk_unknown "porta do dolt ilegivel" "porta que nao e numero" nao
reset; FAKE_TABLES=none run --dry-run;    chk_unknown "lista de tabelas vazia ou com nome fora de" "banco sem nenhuma tabela base" nao
reset; FAKE_TABLES=badname run --dry-run; chk_unknown "lista de tabelas vazia ou com nome fora de" "nome de tabela com ; (nunca vira SQL)" nao
reset; FAKE_COUNT_FAIL=1 run --dry-run;   chk_unknown "contagem AS OF falhou: table not found" "contagem falhou" nao
reset; FAKE_COUNT_JUNK=1 run --dry-run;   chk_unknown "contagem AS OF falhou" "contagem que nao e numero" nao
check "$([ -e "$(RUNDIR)manifest.json" ] && echo ficou || echo nenhum)" nenhum "contagem que nao e numero: nenhum manifest.json ficou (nem vazio: o redirect do python o cria antes de falhar; so o rm -f o tira)"
reset; FAKE_COUNT_PARTIAL=1 run --dry-run; chk_unknown "contagem AS OF falhou: connection lost" "dolt que imprime a 1a tabela e morre" nao
check "$([ -e "$(RUNDIR)manifest.json" ] && echo ficou || echo nenhum)" nenhum "dolt que morre no meio: nenhum manifest.json (parcial, com cara de valido) fica na rodada"

echo "-- entrada hostil do S3 (latest.json): nada disso chega ao banco vivo — UNKNOWN e NENHUMA chamada ao dolt"
chk_hostile() {   # $1 = valor de FAKE_LATEST · $2 = rotulo
  FAKE_LATEST="$1" run --dry-run
  chk_unknown "sem run_utc/head valido para hq" "$2" nao
  check "$(calls dolt.argv)" 0 "$2: o dolt vivo nem foi chamado"
  hasnt "$OUT" "forma inesperada" "$2: ja o ajudante Python recusou (a conferencia em bash e a 2a camada, nao a 1a)"
  check "$([ -e "$T/pwned" ] && echo sim || echo nao)" nao "$2: nada foi criado"
}
reset; chk_hostile tabsql "run_utc com TAB e SQL (a injecao que partia o AS_OF)"
reset; chk_hostile nlrun "run_utc com quebra de linha no fim"
reset; chk_hostile trailrun "run_utc com lixo depois do Z"
reset; chk_hostile uniutc "run_utc com digitos Unicode"
reset; chk_hostile nlhead "head com quebra de linha no fim"
reset; chk_hostile tabhead "head com TAB e SQL"
reset; chk_hostile longhead "head com 33 caracteres"
check "$(canary_hits)" 0 "entrada hostil: o canario continua fora de qualquer arquivo e da saida"
# defesa em profundidade: um ajudante que APROVOU o valor hostil (aqui, um python3 de mentira) nao basta — a variavel que vai ao SQL e conferida em bash
chk_lie() {   # $1 = o que o ajudante "aprovou" (printf %b) · $2 = rotulo
  FAKE_PYLIE="$1" LABMBP_PY="$T/bin/pylie" run --dry-run
  chk_unknown "forma inesperada" "$2" nao
  check "$(calls dolt.argv)" 0 "$2: o dolt vivo nem foi chamado"
}
reset; FAKE_PYLIE="2026-10-16T07:07:25Z\t$HEAD_H" LABMBP_PY="$T/bin/pylie" run --dry-run
has "$OUT" "RESULT: DRY db=hq rc=0 as_of=$HEAD_H" "ajudante de mentira que diz a verdade: a rodada passa (o teste de mentira mede o que diz medir)"
reset; chk_lie "2026-10-16T07:07:25Z\t'; CREATE TABLE pwned (i int); --" "ajudante aprovou head com SQL"
reset; chk_lie "2026-10-16T07:07:25Z\t${HEAD_H}\n; CREATE TABLE pwned (i int); --" "ajudante aprovou head com quebra de linha e SQL"
reset; chk_lie "2026-10-16T07:07:25Z\t${HEAD_H}\tx" "ajudante aprovou um segundo TAB"
reset; chk_lie "x\t${HEAD_H}" "ajudante aprovou run_utc que nao e data"
reset; chk_lie "2026-10-16T07:07:25;\t${HEAD_H}" "ajudante aprovou run_utc de 20 caracteres com ; no fim"
reset; chk_lie "2026-10-16T07:07:25Z0\t${HEAD_H}" "ajudante aprovou run_utc de 21 caracteres"
reset; chk_lie "2026-10-16T07:07:25Z\t${HEAD_H}a" "ajudante aprovou head de 33 caracteres"
reset; chk_lie "2026-10-16T07:07:25Z\t${HEAD_H%?}" "ajudante aprovou head de 31 caracteres"
reset; chk_lie "2026-10-16T07:07:25Z\t$(printf %s "$HEAD_H" | tr a-z A-Z)" "ajudante aprovou head em maiusculas"
reset; chk_lie "2026-10-16T07:07:25Z\t" "ajudante aprovou head vazio"
reset; FAKE_COUNT_UNI=1 run --dry-run;    chk_unknown "contagem AS OF falhou" "contagem com digito Unicode (isdigit aceitaria)" nao
reset; FAKE_LIST_SIZE_UNI=hq/abc123 run --dry-run; chk_unknown "tamanho ou ETag ilegivel" "tamanho com digito Unicode" sim

echo "-- porta: so a do bloco listener:"
reset; printf 'listener:\n  host: 0.0.0.0\nmetrics:\n  port: 9999\n' > "$T/city/.gc/runtime/packs/dolt/dolt-config.yaml"; run --dry-run
chk_unknown "porta do dolt ilegivel" "listener sem porta e porta de OUTRO bloco depois (nao e a do dolt)" nao
check "$(calls dolt.argv)" 0 "porta de outro bloco: o dolt nao foi chamado"
reset; printf '# dolt\nmetrics:\n  port: 9999\nlistener:\n\n  # porta\n  host: 0.0.0.0\n  port: 4242 # sql\nbehavior:\n  port: 1\n' > "$T/city/.gc/runtime/packs/dolt/dolt-config.yaml"; run --dry-run
has "$(cat "$T/cap/dolt.argv")" "--port 4242 " "porta do listener: com comentario, linha em branco e outro bloco antes e depois"
hasnt "$(cat "$T/cap/dolt.argv")" "--port 9999" "a porta de outro bloco nao foi usada"

echo "-- dry-run: lista do S3 ruim = UNKNOWN"
reset; FAKE_LIST_FAIL=1 run --dry-run;    chk_unknown "nao consegui listar s3://urblink-dolt-backups/hq/: An error occurred (AccessDenied)" "listagem negada" sim
reset; FAKE_LIST_EMPTY=1 run --dry-run;   chk_unknown "veio vazia ou fora do formato" "lista vazia (None)" sim
reset; FAKE_LIST_ZERO=1 run --dry-run;    chk_unknown "soma 0 bytes" "lista que soma 0 bytes" sim
reset; FAKE_LIST_BADKEY=1 run --dry-run;  chk_unknown "chave fora de" "chave com ;" sim
reset; FAKE_LIST_BADKEY=2 run --dry-run;  chk_unknown "chave fora de" "chave com .." sim
reset; FAKE_LIST_BADKEY=3 run --dry-run;  chk_unknown "chave fora de" "chave fora do prefixo hq/" sim
reset; FAKE_LIST_BADKEY=4 run --dry-run;  chk_unknown "chave fora de" "chave com espaco" sim
reset; FAKE_LIST_ETAG_JUNK=hq/abc123 run --dry-run; chk_unknown "ETag ilegivel" "ETag que nao e md5" sim
reset; FAKE_LIST_SIZE_JUNK=hq/abc123 run --dry-run; chk_unknown "tamanho ou ETag ilegivel" "tamanho que nao e numero" sim
check "$(ls "$T/state")" "runs" "lista ruim: a trava foi liberada"
check "$(canary_hits)" 0 "lista ruim: o canario continua fora de qualquer arquivo e da saida"

echo "-- --check: o MBP esta livre?"
reset; run --check
check "$RC" 0 "livre: rc 0"
has "$OUT" "MBP livre" "livre: diz que esta livre"
check "$(cat "$T/cap/mbprun.calls")" "--host mbp --check" "so --check foi chamado no mbp-run (nenhum --exec)"
check "$(grep -h -c '^AWS_' "$T"/cap/mbprun.env.* | awk '{s+=$1} END{print s+0}')" 0 "o ambiente do mbp-run nao carrega AWS_* (o mini tem credencial, o que vai ao MBP nao)"
check "$(canary_hits)" 0 "livre: o canario nao aparece em nada"
check "$(ls "$T/state" 2>/dev/null | wc -l | tr -d ' ')" 0 "--check nao cria estado nem rodada"
reset; FAKE_PRESENCE=uso run --check
check "$RC" 4 "em uso: rc 4"
has "$OUT" "MBP nao livre: " "em uso: diz que nao esta livre"
has "$OUT" "presence=uso" "em uso: o motivo traz a presenca"
reset; FAKE_PRESENCE=lixo run --check;  check "$RC" 4 "saida sem presence=: rc 4 (nao e 'livre')"
reset; FAKE_PRESENCE=vazio run --check; check "$RC" 4 "saida vazia: rc 4 (nao e 'livre')"
reset; FAKE_PRESENCE=off run --check;   check "$RC" 4 "MBP inalcancavel (rc 98): rc 4 (nao e 'livre')"
has "$OUT" "inalcançável" "inalcancavel: o motivo do mbp-run aparece"
# a presenca e independente da pausa e da saude: um MBP que RECUSA ainda imprime presence=livre
reset; FAKE_PRESENCE=pausa run --check
check "$RC" 4 "presence=livre mas pausado (paused=1, rc 99): rc 4"
has "$OUT" "rc=99 presence=livre paused=1" "pausado: o motivo traz rc, presenca e pausa"
reset; FAKE_PRESENCE=ram run --check
check "$RC" 4 "presence=livre mas o mbp-run sai 98 (RAM/swap): rc 4"
has "$OUT" "rc=98 presence=livre paused=0" "RAM/swap: o motivo traz o rc"
reset; FAKE_PRESENCE=semp run --check
check "$RC" 4 "presence=livre sem a linha paused=: rc 4 (paused ausente nao vale 0)"
has "$OUT" "paused=?" "paused ausente: o motivo diz '?'"
reset; FAKE_PRESENCE=pl1 run --check;   check "$RC" 4 "paused_local=1: rc 4"
# o dono desligou o uso do MBP (mbp-offload off): o mbp-run real SAI 0 e so a linha offload_flag=off diz; o --exec sairia 99
reset; FAKE_PRESENCE=offoff run --check
check "$RC" 4 "offload_flag=off (mbp-run sai 0): rc 4 — presence=livre sozinha nao prova que o MBP aceita trabalho"
has "$OUT" "offload_flag=off" "offload desligado: o motivo diz qual chave falhou"
reset; FAKE_PRESENCE=semflag run --check
check "$RC" 4 "sem a linha offload_flag=: rc 4 (ausente nao vale 'on')"
has "$OUT" "offload_flag=?" "offload_flag ausente: o motivo diz '?'"
reset; FAKE_PRESENCE=sempl run --check
check "$RC" 4 "sem a linha paused_local=: rc 4 (ausente nao vale 0)"
has "$OUT" "paused_local=?" "paused_local ausente: o motivo diz '?'"
reset; FAKE_PRESENCE=big run --check
check "$RC" 0 "saida de ~270 KB com tudo certo: rc 0 (cauda longa nao vira 'chave ausente')"
# a tabela: (rotulo, saida crua do mbp-run, rc do mbp-run, rc esperado). So rc 0 E as quatro chaves exatas, no INICIO da linha, valem 'livre'.
GOOD='presence=livre\npaused=0\noffload_flag=on\npaused_local=0\n'
raw_chk() { reset; FAKE_PRESENCE=raw FAKE_RAW="$2" FAKE_RAW_RC="$3" run --check; check "$RC" "$4" "$1"; }
raw_chk "cru: as quatro chaves exatas, rc 0 -> livre"                   "$GOOD" 0 0
raw_chk "cru: tudo certo mas o mbp-run saiu 1 -> nao livre"             "$GOOD" 1 4
raw_chk "cru: chave no meio de outra linha nao conta (xpresence=)"      'xpresence=livre\npaused=0\noffload_flag=on\npaused_local=0\n' 0 4
raw_chk "cru: offload_flag so dentro de uma linha task= nao conta"      'presence=livre\npaused=0\npaused_local=0\ntask=1|offload_flag=on|x\n' 0 4
raw_chk "cru: presence=uso antes de presence=livre: vale a 1a linha"    'presence=uso\npresence=livre\npaused=0\noffload_flag=on\npaused_local=0\n' 0 4
raw_chk "cru: presence=livre com espaco no fim nao e livre"             'presence=livre \npaused=0\noffload_flag=on\npaused_local=0\n' 0 4
raw_chk "cru: presence=livres nao e livre"                              'presence=livres\npaused=0\noffload_flag=on\npaused_local=0\n' 0 4
raw_chk "cru: CRLF (presence=livre\\r) nao e livre"                     'presence=livre\r\npaused=0\noffload_flag=on\npaused_local=0\n' 0 4
raw_chk "cru: offload_flag=ON (caixa alta) nao e on"                    'presence=livre\npaused=0\noffload_flag=ON\npaused_local=0\n' 0 4
raw_chk "cru: offload_flag= vazio nao e on"                             'presence=livre\npaused=0\noffload_flag=\npaused_local=0\n' 0 4
raw_chk "cru: paused= vazio nao e 0"                                    'presence=livre\npaused=\noffload_flag=on\npaused_local=0\n' 0 4
raw_chk "cru: paused_local=01 nao e 0"                                  'presence=livre\npaused=0\noffload_flag=on\npaused_local=01\n' 0 4
reset; run --dry-run --check;           check "$RC" 2 "--dry-run e --check juntos: rc 2 (um modo por vez)"
reset; run --check --dry-run;           check "$RC" 2 "--check e --dry-run juntos: rc 2"
check "$(calls mbprun.calls)" 0 "dois modos: o MBP nao foi tocado"

echo "-- --check contra o mbp-run VERDADEIRO (so o ssh e falso): o que ele imprime e o que o orquestrador le"
# O fake de cima so prova o que EU acho que o mbp-run imprime. Aqui o script real (scripts/mbp-run.sh) roda inteiro; falso e so o ssh (a sonda
# do MBP) e a pasta da cidade (bandeira e pausa). Assim a chave que decide ("livre") e a mesma que o --exec depois exige (bandeira + sem pausa).
mkdir -p "$T/home"
cat > "$T/bin/sshprobe" <<'EOF'
#!/bin/bash
cat > /dev/null   # o script de sonda chega pelo stdin
echo x >> "$FAKE_CAP/ssh.calls"; env > "$FAKE_CAP/ssh.env.$$"
[ "${PROBE_RC:-0}" = 0 ] || exit "$PROBE_RC"
printf 'presence=%s\npresence_why=teste\npaused=%s\navail_mb=%s\ncompressed_mb=100\npressure=1\nmem_free_pct=50\npower=ac\nbatt=100\nload=1.0\nncpu=8\nswap_mb=%s\nswap_delta_mb=0\n' \
  "${PROBE_PRES:-livre}" "${PROBE_PAUSED:-0}" "${PROBE_AVAIL:-5000}" "${PROBE_SWAP:-100}"
EOF
chmod +x "$T/bin/sshprobe"
# real on|off [pause] — bandeira do offload ligada/desligada e, se pedido, a pausa do Athos no mini; PROBE_* vem do prefixo
real() {
  reset; rm -rf "$T/mbpcity"; mkdir -p "$T/mbpcity/.gc/logs"
  [ "$1" != on ] || : > "$T/mbpcity/.gc/mbp-offload.on"
  [ "${2:-}" != pause ] || echo "teste" > "$T/mbpcity/.gc/mbp-offload.pause"
  LABMBP_MBP_RUN="$HERE/mbp-run.sh" MBP_SSH="$T/bin/sshprobe" MBP_CITY="$T/mbpcity" HOME="$T/home" run --check
}
real on
check "$RC" 0 "real: bandeira ligada, sem pausa, MBP livre: rc 0"
has "$OUT" "MBP livre" "real: diz que esta livre"
check "$(calls ssh.calls)" 1 "real: o mbp-run verdadeiro sondou o MBP (uma vez, pelo ssh falso)"
check "$(grep -h -c '^AWS_' "$T"/cap/ssh.env.* | awk '{s+=$1} END{print s+0}')" 0 "real: nenhuma variavel AWS_* chega a sessao do MBP (a credencial do mini fica no mini)"
check "$(canary_hits)" 0 "real: o canario nao aparece em nada"
real off
check "$RC" 4 "real: offload DESLIGADO (mbp-offload off; o mbp-run sai 0 e o --exec sairia 99): rc 4"
has "$OUT" "offload_flag=off" "real: o motivo e a bandeira"
real on pause
check "$RC" 4 "real: pausa do Athos no mini: rc 4"
has "$OUT" "paused_local=1" "real: o motivo e a pausa local"
PROBE_PAUSED=1 real on
check "$RC" 4 "real: pausa gravada no MBP (mbp-run sai 99): rc 4"
has "$OUT" "rc=99" "real: o motivo traz o rc 99"
PROBE_PRES=uso real on
check "$RC" 4 "real: Athos usando o MBP: rc 4"
has "$OUT" "presence=uso" "real: o motivo traz a presenca"
PROBE_RC=255 real on
check "$RC" 4 "real: MBP inalcancavel (ssh 255): rc 4"
has "$OUT" "inalcançável" "real: o motivo e o do mbp-run"
PROBE_SWAP=9393 real on
check "$RC" 4 "real: swap acima do teto (o caso de hoje, 9393 MB): rc 4"
has "$OUT" "rc=98" "real: o motivo traz o rc 98"
PROBE_AVAIL=1000 real on
check "$RC" 4 "real: pouca RAM livre: rc 4"

echo "-- trava: so uma rodada por vez; estado inutilizavel nao e 'nada a fazer'"
reset; mkdir -p "$T/state/lock"; echo $$ > "$T/state/lock/pid"; run --dry-run
check "$RC" 0 "trava com pid vivo: rc 0 (outra rodada em curso)"
has "$OUT" "outra rodada em curso (pid $$): nada a fazer" "trava viva: diz o pid"
has "$OUT" "RESULT: SKIPPED db=hq rc=0" "trava viva: RESULT SKIPPED (o agendador ve que nao rodou)"
check "$(calls aws.argv)" 0 "trava viva: nada foi lido do S3"
check "$([ -d "$T/state/lock" ] && echo sim || echo nao)" sim "trava viva: a trava de quem roda NAO foi tocada"
reset; mkdir -p "$T/state/lock"; echo 1 > "$T/state/lock/pid"; run --dry-run   # pid 1 vive e e de outro usuario: kill -0 da EPERM, ps -p nao
has "$OUT" "outra rodada em curso (pid 1): nada a fazer" "trava com pid vivo de OUTRO usuario (EPERM no kill -0): continua trava"
reset; sh -c 'exit 0' & dead=$!; wait $dead; mkdir -p "$T/state/lock"; echo "$dead" > "$T/state/lock/pid"; run --dry-run
check "$RC" 0 "trava de pid morto: a rodada roda"
has "$OUT" "trava de pid morto/antiga recolhida" "pid morto: a trava velha foi recolhida"
reset; mkdir -p "$T/state/lock"; run --dry-run
check "$RC" 0 "trava sem pid e recente: rc 0 (de quem acabou de criar)"
has "$OUT" "trava sem pid legivel e recente" "sem pid e recente: nao recolhe"
check "$(calls aws.argv)" 0 "sem pid e recente: nada foi lido do S3"
reset; mkdir -p "$T/state/lock"; touch -t 202001010000 "$T/state/lock"; run --dry-run
has "$OUT" "RESULT: DRY" "trava sem pid e antiga (12 h+): recolhida e a rodada roda"
reset; mkdir -p "$T/state/lock"; echo "lixo" > "$T/state/lock/pid"; touch -t 202001010000 "$T/state/lock"; run --dry-run
has "$OUT" "RESULT: DRY" "pid ilegivel e trava antiga: recolhida"
reset; mkdir -p "$T/state/lock"; echo $$ > "$T/state/lock/pid"; touch -t 202001010000 "$T/state/lock"; run --dry-run
has "$OUT" "trava de pid morto/antiga recolhida" "trava de 12 h+ com pid VIVO (pid reaproveitado): recolhida"
has "$OUT" "RESULT: DRY" "trava velha com pid vivo: a rodada roda"
check "$(ls "$T/state")" "runs" "trava recolhida: o mutex de recolhimento foi liberado (so sobrou runs/)"
reset; sh -c 'exit 0' & dead=$!; wait $dead; mkdir -p "$T/state/lock" "$T/state/lock.reclaim"; echo "$dead" > "$T/state/lock/pid"; run --dry-run
check "$RC" 0 "trava morta + outro recolhedor com o mutex (recente): rc 0"
has "$OUT" "RESULT: SKIPPED db=hq rc=0" "mutex recente: SKIPPED (quem recolhe vai rodar)"
has "$OUT" "outra rodada esta recolhendo a trava velha" "mutex recente: diz que outra rodada esta recolhendo"
check "$(calls aws.argv)" 0 "mutex recente: nada foi lido do S3"
check "$([ -d "$T/state/lock.reclaim" ] && [ -d "$T/state/lock" ] && echo sim || echo nao)" sim "mutex recente: nem o mutex nem a trava do outro foram tocados"
reset; sh -c 'exit 0' & dead=$!; wait $dead; mkdir -p "$T/state/lock" "$T/state/lock.reclaim"; echo "$dead" > "$T/state/lock/pid"; touch -t 202001010000 "$T/state/lock.reclaim"; run --dry-run
has "$OUT" "RESULT: DRY" "mutex de 10 min+ (dono morreu dentro dele): ignorado, a rodada roda"
check "$(ls "$T/state")" "runs" "mutex velho: nada sobrou alem de runs/"
# a velhice e conferida DE NOVO dentro do mutex: a trava que ficou VIVA entre a decisao "velha" e o recolhimento nao pode ser apagada
reset; mkdir -p "$T/state/lock"; echo $$ > "$T/state/lock/pid"
out=$(LABMBP_LIB=1 LABMBP_CITY="$T/city" LABMBP_STATE="$T/state" "${LABMBP_TEST_BASH:-bash}" -c '
  . "$1"; eval "$(declare -f lock_stale | sed "1s/lock_stale/real_stale/")"
  n=0; lock_stale() { n=$((n+1)); if [ "$n" -eq 1 ]; then return 0; fi; real_stale; }   # a 1a leitura diz "velha"; ate a 2a ela ficou viva
  take_lock; rc=$?; echo "rc=$rc leituras=$n pid=$(cat "$STATE/lock/pid" 2>/dev/null) mutex=$([ -d "$STATE/lock.reclaim" ] && echo preso || echo livre) why=$WHY"' _ "$T/scripts/dolt-restore-lab-mbp.sh" 2>&1)
check "$out" "rc=1 leituras=2 pid=$$ mutex=livre why=outra rodada em curso (pid $$): nada a fazer" "trava que ficou viva entre a decisao e o recolhimento: NAO e apagada, rc 1, mutex liberado"
# trava que sumiu entre o mkdir que falhou e a leitura: nao ha o que proteger (pode recolher), e o mutex preso e solto pelo cleanup
reset
out=$(LABMBP_LIB=1 LABMBP_CITY="$T/city" LABMBP_STATE="$T/state" "${LABMBP_TEST_BASH:-bash}" -c '
  . "$1"; lock_stale; a=$?; mkdir -p "$STATE/lock.reclaim"; RECL=1; cleanup; echo "stale=$a mutex=$([ -d "$STATE/lock.reclaim" ] && echo preso || echo solto)"' _ "$T/scripts/dolt-restore-lab-mbp.sh" 2>&1)
check "$out" "stale=0 mutex=solto" "sem trava: lock_stale diz 'pode recolher'; morrer com o mutex na mao: o cleanup solta o mutex"
# varias rodadas ao mesmo tempo sobre uma trava morta: so UMA roda; quem tem a trava fica segurando (FAKE_GATE) ate as outras terminarem
reset; sh -c 'exit 0' & dead=$!; wait $dead; mkdir -p "$T/state/lock"; echo "$dead" > "$T/state/lock/pid"; rm -f "$T/gate"; rm -f "$T"/c?.out
for i in 1 2 3 4 5 6; do FAKE_GATE="$T/gate" envrun --dry-run > "$T/c$i.out" 2>&1 & done
n=0; while [ "$(grep -l 'RESULT:' "$T"/c?.out 2>/dev/null | wc -l | tr -d ' ')" -lt 5 ] && [ "$n" -lt 240 ]; do sleep 0.5; n=$((n+1)); done
: > "$T/gate"; wait
check "$(grep -l 'RESULT: DRY' "$T"/c?.out | wc -l | tr -d ' ')" 1 "6 rodadas sobre a mesma trava morta: exatamente UMA roda"
check "$(grep -l 'RESULT: SKIPPED' "$T"/c?.out | wc -l | tr -d ' ')" 5 "6 rodadas sobre a mesma trava morta: as outras 5 saem SKIPPED"
check "$(ls "$T/state/runs" | wc -l | tr -d ' ')" 1 "6 rodadas sobre a mesma trava morta: uma pasta de rodada so"
check "$(ls "$T/state")" "runs" "6 rodadas: trava e mutex liberados no fim"
# duas rodadas no MESMO segundo (a trava foi recolhida no meio) nao dividem a pasta
reset; PATH="$T/fakedate:$PATH" run --dry-run; PATH="$T/fakedate:$PATH" run --dry-run
check "$(ls "$T/state/runs" | wc -l | tr -d ' ')" 2 "duas rodadas no mesmo segundo: duas pastas (o pid entra no nome)"
check "$(ls "$T/state/runs" | grep -c '^20261016T000000Z-[0-9][0-9]*$')" 2 "o nome da pasta e <UTC>-<pid>"
check "$(ls "$T"/state/runs/*/manifest.json | wc -l | tr -d ' ')" 2 "cada rodada tem o seu manifest"
reset; chmod 555 "$T/state"
if [ -w "$T/state" ]; then echo "  SKIP: estado somente-leitura (chmod 555 nao impede este usuario)"; else
  run --dry-run
  check "$RC" 2 "mkdir da trava falha sem trava (somente-leitura): rc 2, nao o 0 de 'nada a fazer'"
  has "$OUT" "RESULT: UNKNOWN db=hq rc=2" "somente-leitura: RESULT UNKNOWN"
  has "$OUT" "nao consegui criar $T/state" "somente-leitura: o motivo diz qual pasta"
  check "$(calls aws.argv)" 0 "somente-leitura: nada foi lido do S3"
fi
chmod 755 "$T/state"
# trava velha que NAO da para recolher (mutex que nao nasce, mutex velho que nao sai, trava que nao e apagada) e erro rc 2, nunca o "nada a fazer" do SKIPPED
reset; sh -c 'exit 0' & dead=$!; wait $dead; mkdir -p "$T/state/lock"; echo "$dead" > "$T/state/lock/pid"; chmod 555 "$T/state"
if [ -w "$T/state" ]; then echo "  SKIP: estado somente-leitura (chmod 555 nao impede este usuario)"; else
  run --dry-run
  check "$RC" 2 "trava morta, mutex que nao nasce (somente-leitura): rc 2, nao o 0 de 'outra rodada recolhendo'"
  has "$OUT" "RESULT: UNKNOWN db=hq rc=2" "mutex que nao nasce: RESULT UNKNOWN"
  hasnt "$OUT" "recolhendo" "mutex que nao nasce: nao culpa 'outra rodada recolhendo'"
  check "$(calls aws.argv)" 0 "mutex que nao nasce: nada foi lido do S3"
fi
chmod 755 "$T/state"
reset; sh -c 'exit 0' & dead=$!; wait $dead; mkdir -p "$T/state/lock" "$T/state/lock.reclaim"; echo "$dead" > "$T/state/lock/pid"; touch -t 202001010000 "$T/state/lock.reclaim"; chmod 555 "$T/state"
if [ -w "$T/state" ]; then echo "  SKIP: estado somente-leitura (chmod 555 nao impede este usuario)"; else
  run --dry-run
  check "$RC" 2 "mutex velho que nao sai (somente-leitura): rc 2, nao o 0 de 'outra rodada recolhendo'"
  has "$OUT" "RESULT: UNKNOWN db=hq rc=2" "mutex velho que nao sai: RESULT UNKNOWN"
  check "$(calls aws.argv)" 0 "mutex velho que nao sai: nada foi lido do S3"
fi
chmod 755 "$T/state"
reset; sh -c 'exit 0' & dead=$!; wait $dead; mkdir -p "$T/state/lock/sub"; echo "$dead" > "$T/state/lock/pid"; echo x > "$T/state/lock/sub/f"; chmod 555 "$T/state/lock/sub"
if [ -w "$T/state/lock/sub" ]; then echo "  SKIP: pasta somente-leitura (chmod 555 nao impede este usuario)"; else
  run --dry-run
  check "$RC" 2 "trava velha que nao pode ser apagada: rc 2, nao o 0 de 'outra rodada pegou a trava'"
  has "$OUT" "RESULT: UNKNOWN db=hq rc=2" "trava que nao sai: RESULT UNKNOWN"
  has "$OUT" "nao consegui apagar a trava velha" "trava que nao sai: o motivo diz que a trava velha nao saiu"
  hasnt "$OUT" "pegou a trava" "trava que nao sai: nao culpa 'outra rodada pegou a trava'"
  check "$([ -d "$T/state/lock.reclaim" ] && echo preso || echo livre)" livre "trava que nao sai: o mutex foi liberado"
  check "$(calls aws.argv)" 0 "trava que nao sai: nada foi lido do S3"
fi
chmod -R u+w "$T/state"
reset; um=$(umask); umask 0222   # a trava nasce 0555: o mkdir passa, mas o pid nao pode ser gravado dentro dela
if [ "$(id -u)" = 0 ]; then echo "  SKIP: pid nao gravavel (root escreve em dir 0555)"; else
  run --dry-run
  check "$RC" 2 "pid da trava nao gravavel: rc 2 (nao o 0 de 'nada a fazer')"
  has "$OUT" "RESULT: UNKNOWN db=hq rc=2" "pid nao gravavel: RESULT UNKNOWN"
  check "$([ -d "$T/state/lock" ] && echo sim || echo nao)" nao "pid nao gravavel: a trava meio criada foi apagada"
  check "$(calls aws.argv)" 0 "pid nao gravavel: nada foi lido do S3"
fi
umask "$um"
reset; : > "$T/notadir"; STATE_OVERRIDE="$T/notadir/state" run --dry-run
check "$RC" 2 "estado que nao da para criar: rc 2 (nao o 0 de 'nada a fazer')"
has "$OUT" "RESULT: UNKNOWN db=hq rc=2" "estado inutilizavel: RESULT UNKNOWN"
has "$OUT" "nao consegui criar $T/notadir/state" "estado inutilizavel: o motivo diz qual pasta"
check "$(calls aws.argv)" 0 "estado inutilizavel: nada foi lido do S3"

echo "-- timeout: dolt/aws pendurado = UNKNOWN (a trava nao fica presa); sem timeout no PATH = UNKNOWN"
reset; FAKE_DOLT_HANG=1 LABMBP_CALL_S=2 run --dry-run; chk_unknown "sem resposta em 2s (timeout): dolt" "dolt vivo pendurado" nao
check "$(ls "$T/state")" "runs" "dolt pendurado: a trava foi liberada"
reset; FAKE_AWS_HANG=1 LABMBP_CALL_S=2 run --dry-run;  chk_unknown "sem resposta em 2s (timeout): aws" "aws pendurado (latest.json)" nao
reset; FAKE_LIST_HANG=1 LABMBP_CALL_S=2 run --dry-run; chk_unknown "sem resposta em 2s (timeout): aws" "aws pendurado (listagem)" sim
reset; mkdir -p "$T/nobin"; for c in env bash cut grep date dirname cat rm mkdir sed head tail awk find ps python3 ls; do ln -sf "$(command -v $c)" "$T/nobin/$c"; done
PATH="$T/nobin" run --dry-run; chk_unknown "sem timeout/gtimeout no PATH" "sem timeout no PATH" nao
check "$(calls dolt.argv)" 0 "sem timeout: o dolt nem foi chamado"

echo "-- argumentos"
reset; run
check "$RC" 2 "sem --dry-run nem --check: rc 2 (o restore chega na fatia 3/4)"
has "$OUT" "fatia 3/4" "sem modo: a mensagem diz quando o restore chega"
check "$(calls aws.argv)" 0 "sem modo: nada foi lido do S3"
check "$(calls mbprun.calls)" 0 "sem modo: o MBP nao foi tocado"
reset; run --dry-run --db 'hq;x';  check "$RC" 2 "--db com ';': rc 2"
reset; run --dry-run --db;         check "$RC" 2 "--db sem valor: rc 2"
reset; run --dry-run --assim;      check "$RC" 2 "opcao desconhecida: rc 2"
check "$(calls aws.argv)" 0 "argumento ruim: nada foi lido do S3"
reset; run --help
check "$RC" 0 "--help: rc 0"
has "$OUT" "dolt-restore-lab-mbp.sh --dry-run" "--help mostra o uso"
reset; run --dry-run --db hq_old
check "$RC" 2 "--db outro: latest.json sem esse banco: rc 2"
has "$OUT" "RESULT: UNKNOWN db=hq_old rc=2" "--db outro: RESULT diz o banco pedido"
has "$OUT" "sem run_utc/head valido para hq_old" "--db outro: o motivo diz o banco"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
