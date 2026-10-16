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
        [ "${FAKE_LATEST_FAIL:-0}" != 1 ] || { echo "An error occurred (AccessDenied) when calling the GetObject operation" >&2; exit 1; }
        case "${FAKE_LATEST:-ok}" in
          ok) cat "$FAKE_ROOT/latest1.json" ;;
          nohead) printf '{"run_utc":"2026-10-16T07:07:25Z","databases":{"hq":{"issues":5}}}\n' ;;
          badhead) printf '{"run_utc":"2026-10-16T07:07:25Z","databases":{"hq":{"head":"x; DROP TABLE issues"}}}\n' ;;
          norun) printf '{"databases":{"hq":{"head":"%s"}}}\n' "$FAKE_HEAD" ;;
          otherdb) printf '{"run_utc":"2026-10-16T07:07:25Z","databases":{"hq_old":{"head":"%s"}}}\n' "$FAKE_HEAD" ;;
          html) echo "<html>503 Slow Down</html>" ;;
        esac ;;
      *) echo x >> "$FAKE_CAP/objreads"; exit 1 ;;   # a dry-run never reads an object
    esac ;;
  "s3api list-objects-v2")
    [ "${FAKE_LIST_HANG:-0}" != 1 ] || exec sleep 30
    [ "${FAKE_LIST_FAIL:-0}" != 1 ] || { echo "An error occurred (AccessDenied) when calling the ListObjectsV2 operation" >&2; exit 1; }
    [ "${FAKE_LIST_EMPTY:-0}" != 1 ] || { echo None; exit 0; }
    python3 -I - "$FAKE_ROOT/s3" <<'PY'
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
    case "$q" in
      *'`issues` AS OF '*'`labels` AS OF '*) printf 't,n\nissues,5\nlabels,7\n' ;;
      *) printf 't,n\nissues,6\nlabels,8\n' ;;
    esac ;;
  *) echo "fake dolt: consulta inesperada: $q" >&2; exit 1 ;;
esac
EOF
# mbp-run: only --check exists in this slice. FAKE_PRESENCE chooses the answer (pausa/ram/semp/pl1: presence=livre, mas o MBP RECUSA ou nao prova paused=0).
cat > "$T/scripts/mbp-run.sh" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_CAP/mbprun.calls"
env > "$FAKE_CAP/mbprun.env.$$"
case "${FAKE_PRESENCE:-livre}" in
  livre) printf 'presence=livre\npresence_why=ocioso\npaused=0\navail_mb=5000\n' ;;
  uso) printf 'presence=uso\npresence_why=teclado\npaused=0\n' ;;
  lixo) printf 'algo=estranho\n' ;;
  vazio) ;;
  pausa) printf 'presence=livre\npaused=1\n'; exit 99 ;;
  ram) echo "mbp-run: RAM/swap alto — rode local"; printf 'presence=livre\npaused=0\n'; exit 98 ;;
  semp) printf 'presence=livre\npresence_why=ocioso\n' ;;
  pl1) printf 'presence=livre\npaused=0\npaused_local=1\n' ;;
  off) echo "mbp-run: MBP inalcançável (ssh rc=255) — rode local"; printf 'offload_flag=on\n'; exit 98 ;;
esac
exit 0
EOF
chmod +x "$T/bin/"* "$T/scripts/"*.sh
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
check "$([ -s "$(RUNDIR)manifest.json" ] && echo cheio || echo vazio)" vazio "contagem que nao e numero: nenhum manifest utilizavel ficou"

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
reset; run --dry-run --check;           check "$RC" 2 "--dry-run e --check juntos: rc 2 (um modo por vez)"
reset; run --check --dry-run;           check "$RC" 2 "--check e --dry-run juntos: rc 2"
check "$(calls mbprun.calls)" 0 "dois modos: o MBP nao foi tocado"

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
reset; chmod 555 "$T/state"
if [ -w "$T/state" ]; then echo "  SKIP: estado somente-leitura (chmod 555 nao impede este usuario)"; else
  run --dry-run
  check "$RC" 2 "mkdir da trava falha sem trava (somente-leitura): rc 2, nao o 0 de 'nada a fazer'"
  has "$OUT" "RESULT: UNKNOWN db=hq rc=2" "somente-leitura: RESULT UNKNOWN"
  has "$OUT" "nao consegui criar $T/state" "somente-leitura: o motivo diz qual pasta"
  check "$(calls aws.argv)" 0 "somente-leitura: nada foi lido do S3"
fi
chmod 755 "$T/state"
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
