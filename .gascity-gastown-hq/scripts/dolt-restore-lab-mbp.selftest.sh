#!/bin/bash
# dolt-restore-lab-mbp.selftest.sh — tests for dolt-restore-lab-mbp.sh and dolt-restore-lab-mbp-side.sh (ga-3kmvyr).
#
# Hermetic: the REAL orchestrator and the REAL MBP wrapper run against FAKES — aws (latest.json, the object listing, the objects), the
# live dolt, ssh (runs the "remote" command locally in a clean environment), mbp-run.sh (plays the MBP: copies the pushed dir to a slot,
# runs the wrapper under `env -i`, pulls out/, wipes the slot), the lab (checks the copy it got against the S3 fixture, writes a
# report.json from the manifest it received) and notify. Nothing of the live city, S3, the MBP or the real dolt is touched.
# The canary credential is the point: it sits in the orchestrator's environment (the mini has a credential) and must be in no argv log,
# no env dump of anything that goes to the MBP, no file, no output — and no sts call is ever made.
# The first sections are the whole run (slice 3/4); the last ones are the mini's read-only half (slice 2/4): --dry-run, --check, lock, arguments.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_SRC="${LABMBP_SCRIPT_UNDER_TEST:-$HERE/dolt-restore-lab-mbp.sh}"
SIDE_SRC="${LABMBP_SIDE_UNDER_TEST:-$HERE/dolt-restore-lab-mbp-side.sh}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (esperado '$2', veio '$1')"; fi; }
has()  { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (nao achei '$2')"; fi; }
hasnt(){ if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (achei '$2')"; else ok "$3"; fi; }
HEAD_H="gaffd3qkn1bfe87s8tgvoiic790r1u62"
BKT="s3://urblink-dolt-backups"

mkdir -p "$T/scripts" "$T/bin" "$T/secret" "$T/home/gt-remote/lab/bin" "$T/tmp" "$T/s3/hq"
cp "$ORCH_SRC" "$T/scripts/dolt-restore-lab-mbp.sh"; cp "$SIDE_SRC" "$T/scripts/dolt-restore-lab-mbp-side.sh"
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
        n=$(cat "$FAKE_CAP/latest.n" 2>/dev/null || echo 0); echo $((n+1)) > "$FAKE_CAP/latest.n"
        [ "${FAKE_LATEST_HANG_AFTER:-0}" != 1 ] || [ "$n" -lt 1 ] || { trap 'touch "$FAKE_CAP/hang.term"; exit 143' TERM; sleep 30 >/dev/null 2>&1 </dev/null & wait $!; }   # so a RELEITURA do fim da rodada pendura; hang.term = o timeout do orquestrador chegou
        [ "${FAKE_LATEST_FAIL_AFTER:-0}" != 1 ] || [ "$n" -lt 1 ] || { echo "An error occurred (AccessDenied) when calling the GetObject operation" >&2; exit 1; }
        if [ -n "${FAKE_GATE:-}" ]; then g=0; while [ ! -e "$FAKE_GATE" ] && [ "$g" -lt 300 ]; do sleep 0.2; g=$((g+1)); done; fi   # segura quem tem a trava
        [ "${FAKE_LATEST_FAIL:-0}" != 1 ] || { echo "An error occurred (AccessDenied) when calling the GetObject operation" >&2; exit 1; }
        [ "$n" -lt 1 ] || [ -z "${FAKE_LATEST2:-}" ] || FAKE_LATEST="$FAKE_LATEST2"   # a RELEITURA do fim da rodada pode devolver outra coisa
        case "${FAKE_LATEST:-ok}" in
          ok) if [ "${FAKE_MOVE:-0}" = 1 ] && [ "$n" -ge 1 ]; then cat "$FAKE_ROOT/latest2.json"; else cat "$FAKE_ROOT/latest1.json"; fi ;;
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
      s3://urblink-dolt-backups/hq/*)
        echo x >> "$FAKE_CAP/objreads"
        key="${3#s3://urblink-dolt-backups/}"; ck="$FAKE_CAP/obj.$(printf '%s' "$key" | tr / _)"
        n=$(cat "$ck" 2>/dev/null || echo 0); echo $((n+1)) > "$ck"
        [ -z "${FAKE_OBJ_SLOW:-}" ] || sleep "$FAKE_OBJ_SLOW"
        [ "${FAKE_OBJ_HANG:-}" != "$key" ] || exec sleep 60   # aws cp pendurado: so o teto por objeto resolve
        if [ "${FAKE_OBJ_FAIL:-}" = "$key" ] || { [ "${FAKE_OBJ_FAIL_ONCE:-}" = "$key" ] && [ "$n" -eq 0 ]; }; then
          echo "fatal error: An error occurred (500) when calling the GetObject operation (reached max retries)" >&2; exit 1; fi
        if [ "${FAKE_OBJ_TRUNC:-}" = "$key" ]; then head -c 100 "$FAKE_ROOT/s3/$key"; exit 0; fi
        if [ "${FAKE_OBJ_CORRUPT:-}" = "$key" ]; then { printf 'Z'; tail -c +2 "$FAKE_ROOT/s3/$key"; }; exit 0; fi
        cat "$FAKE_ROOT/s3/$key" ;;
      *) exit 1 ;;
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
        if key == E.get("FAKE_LIST_ETAG_MP"): e = "0" * 32 + "-3"
        if key == E.get("FAKE_LIST_ETAG_BAD"): e = "1" * 32
        if E.get("FAKE_LIST_ETAG_JUNK") == key: e = "not-an-etag"
        if E.get("FAKE_LIST_SIZE_JUNK") == key: n = "12KB"
        if E.get("FAKE_LIST_SIZE_UNI") == key: n = "\u0665"
        print("%s\t%s\t\"%s\"" % (key, n, e))
if E.get("FAKE_LIST_DIRMARK") == "1": print("hq/emptydir/\t0\t\"d41d8cd98f00b204e9800998ecf8427e\"")
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
[ "${1:-}" = version ] && { [ "${FAKE_DOLT_VER_HANG:-0}" != 1 ] || { trap 'touch "$FAKE_CAP/hang.term"; exit 143' TERM; sleep 30 >/dev/null 2>&1 </dev/null & wait $!; }
  case "$([ -z "${FAKE_SCEN:-}" ] || sed -n 's/^dolt_run=//p' "$FAKE_SCEN")" in fail) echo "exec format error" >&2; exit 1 ;; empty) exit 0 ;; other) echo "dolt version 9.9.9"; exit 0 ;; esac   # the copy on the MBP
  echo "dolt version 2.3.1"; exit 0; }
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
cat > "$T/bin/notify" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_CAP/notify.log"
EOF
# ssh: the "MBP" is this machine in a clean environment. Records argv and its own env; can drop mid-object or tamper with the copy
# right before stream.done; after the command it looks for big files on the mini (the data must be a pipe, never a file).
cat > "$T/bin/ssh" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_CAP/ssh.calls"
[ -e "$FAKE_CAP/ssh.env" ] || env > "$FAKE_CAP/ssh.env"
cmd="${!#}"; LS="$FAKE_ROOT/mbp/gt-remote/exec/1/in/lab-src"
case "$cmd" in
  "printf x > "*stream.done*)
    case "${FAKE_TAMPER:-}" in
      missing) rm -f "$LS/manifest" ;;
      extra) echo junk > "$LS/EXTRA" ;;
      size) printf 'x' >> "$LS/manifest" ;;
    esac ;;
  *"cat > "*)
    if [ -n "${FAKE_SSH_DROP:-}" ] && printf '%s' "$cmd" | grep -qF -- "/$FAKE_SSH_DROP'"; then
      n=$(cat "$FAKE_CAP/ssh.drop.n" 2>/dev/null || echo 0); echo $((n+1)) > "$FAKE_CAP/ssh.drop.n"
      if [ "${FAKE_SSH_DROP_ONCE:-0}" != 1 ] || [ "$n" -eq 0 ]; then
        dest=$(printf '%s' "$cmd" | sed -n "s/.*cat > '\([^']*\)'.*/\1/p"); mkdir -p "$(dirname "$dest")"; head -c 1000 > "$dest"; exit 255
      fi
    fi ;;
esac
env -i HOME="$FAKE_ROOT/home" PATH=/usr/bin:/bin /bin/sh -c "$cmd"; rc=$?
find "$FAKE_ROOT/tmp" "$FAKE_ROOT/state" "$FAKE_ROOT/city" "$FAKE_ROOT/cap" -type f -size +1000k 2>/dev/null | grep -c . >> "$FAKE_CAP/mini-big"
exit $rc
EOF
# the MBP: plays mbp-run.sh. --check by FAKE_PRESENCE: same lines as the REAL mbp-run --check (probe, offload_flag=, paused_local=), and each scenario gets exactly ONE thing wrong
# (pausa/ram/semp/pl1/offoff/semflag/sempl/big: presence=livre, but the MBP REFUSES or does not prove it); raw = FAKE_RAW (printf %b), rc FAKE_RAW_RC. --exec copies the push into a slot
# and runs the command under `env -i`.
cat > "$T/scripts/mbp-run.sh" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_CAP/mbprun.calls"
env > "$FAKE_CAP/mbprun.env.$$"
if [ "${1:-}" = --host ]; then
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
fi
shift; push=""; pull=""
while [ $# -gt 0 ]; do case "$1" in --push) push="$2"; shift 2 ;; --pull) pull="$2"; shift 2 ;; --) shift; break ;; *) shift ;; esac; done
echo "modes: dir=$(stat -f %Lp "$push") parent=$(stat -f %Lp "$(dirname "$push")")" >> "$FAKE_CAP/modes"
SLOT="$FAKE_ROOT/mbp/gt-remote/exec/1"
case "${FAKE_EXEC:-run}" in
  refuse98) [ "${FAKE_ATTEMPT_STUCK:-0}" != 1 ] || { rm -f "$FAKE_ROOT/state/last-attempt" && mkdir "$FAKE_ROOT/state/last-attempt"; }   # rm -f nao apaga diretorio: o marcador "nao sai"
            echo "mbp-run: MBP em uso — rode local"; exit 98 ;;
  noready) sleep "${FAKE_NOREADY_S:-4}"; exit 0 ;;
  badslot) echo "[lab-mbp] ready slot=$FAKE_BADSLOT"; sleep 2; exit 0 ;;
esac
rm -rf "$SLOT"; mkdir -p "$SLOT/in" && cp -Rp "$push" "$SLOT/in/"
# mbp-run's end-of-call cleanup is best effort ("AVISO: scratch nao foi limpo"): a slot can still hold the previous round.
# 1 = a leftover in/lab-src · 2 = in/lab-src is a link to a folder outside the slot · 3 = a leftover that cannot be removed (in/ is read-only)
# 4 = only a report.json (verdict OK) and a lab.log of the previous round in out/
case "${FAKE_STALE_SLOT:-0}" in
  1|3) mkdir -p "$SLOT/in/lab-src/oldtable"; echo old > "$SLOT/in/lab-src/oldtable/f"; [ "$FAKE_STALE_SLOT" != 3 ] || chmod 555 "$SLOT/in" ;;
  2) mkdir -p "$FAKE_ROOT/mbp/outside"; echo keep > "$FAKE_ROOT/mbp/outside/keep.txt"; ln -s "$FAKE_ROOT/mbp/outside" "$SLOT/in/lab-src" ;;
  4) mkdir -p "$SLOT/out"; echo "lab.log antigo" > "$SLOT/out/lab.log"
     python3 -I - "$SLOT/in/lab-in/manifest.json" "$SLOT/out/report.json" <<'PYSTALE'
import json, sys
m = json.load(open(sys.argv[1]))
json.dump({"verdict": "OK", "rc": 0, "reason": None, "as_of": m["as_of"], "total_s": 321, "source_kb": 13000000, "restored_kb": 14000000,
           "fetch_s": None, "restore_s": 200, "count_s": 21, "tables": {k: {"expected": v, "restored": v} for k, v in m["tables"].items()}}, open(sys.argv[2], "w"))
PYSTALE
     ;;
esac
# FAKE_FIND_FAIL=1: in the MBP session of dolt-restore-lab-mbp-side.sh, the `find -mindepth` that COUNTS the leftover exits 1 (any other find call goes through to the real one)
[ "${FAKE_FIND_FAIL:-0}" != 1 ] || { mkdir -p "$FAKE_ROOT/mbp/failbin"; printf '#!/bin/sh\ncase "$*" in *-mindepth*) exit 1 ;; esac\nexec /usr/bin/find "$@"\n' > "$FAKE_ROOT/mbp/failbin/find"; chmod +x "$FAKE_ROOT/mbp/failbin/find"; }
printf 'lab=%s\ndolt_version=%s\nleak=%s\ndisk=%s\ndolt_run=%s\n' "${SC_LAB:-ok}" "${SC_DOLT_VER:-2.3.1}" "${SC_LEAK:-0}" "${SC_DISK:-ok}" "${SC_DOLT_RUN:-ok}" > "$FAKE_ROOT/scen"
extra=(); [ "${SC_AWSENV:-0}" != 1 ] || extra=(AWS_PROFILE=leaky)
for t in ps env; do rm -f "$FAKE_ROOT/home/gt-remote/lab/bin/$t"; done   # SC_BROKEN=ps|env: that tool fails (exit 1, no output) in the MBP session
[ -z "${SC_BROKEN:-}" ] || { printf '#!/bin/sh\nexit 1\n' > "$FAKE_ROOT/home/gt-remote/lab/bin/$SC_BROKEN"; chmod +x "$FAKE_ROOT/home/gt-remote/lab/bin/$SC_BROKEN"; }
[ "${SC_PSFLAKY:-0}" != 1 ] || { printf '#!/bin/sh\ncase "$*" in *axww*) [ -e "$FAKE_CAP/ps.failed1" ] || { : > "$FAKE_CAP/ps.failed1"; exit 1; } ;; esac\nexec /bin/ps "$@"\n' > "$FAKE_ROOT/home/gt-remote/lab/bin/ps"; chmod +x "$FAKE_ROOT/home/gt-remote/lab/bin/ps"; }   # SC_PSFLAKY=1: the sampler's FIRST ps call fails, every later one works — always 1 failed + >=1 clean sample (the sampler takes the first and the last no matter how slow the machine is; a flake by call count shifted with the number of samples and sometimes failed ALL of them)
[ "${FAKE_MINI_LEAK:-0}" != 1 ] || echo "AWS_SECRET_ACCESS_KEY=whatever" > "$(dirname "$push")/stray.txt"
[ "${FAKE_MINI_LEAK:-0}" != 3 ] || { mkdir "$FAKE_ROOT/state/zz-unreadable" && chmod 000 "$FAKE_ROOT/state/zz-unreadable"; }
[ "${FAKE_MINI_LEAK:-0}" != 2 ] || echo '{"cmd":"AWS_ACCESS_KEY_ID=whatever"}' > "$FAKE_ROOT/city/.gc/logs/mbp-run.jsonl"
# 4 = ACHOU e uma pasta nao abre: o grep sai 2 com o acerto na saida (o "achar vale mais que nao terminar")
[ "${FAKE_MINI_LEAK:-0}" != 4 ] || { echo "AWS_SECRET_ACCESS_KEY=whatever" > "$(dirname "$push")/stray.txt"; mkdir "$FAKE_ROOT/state/zz-unreadable" && chmod 000 "$FAKE_ROOT/state/zz-unreadable"; }
if [ "${FAKE_EXEC:-run}" = die_after_ready ]; then   # the job dies (and mbp-run wipes the slot) while the mini is still sending
  ( cd "$SLOT" && exec env -i HOME="$FAKE_ROOT/home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" FAKE_SCEN="$FAKE_ROOT/scen" LAB_POLL_S=0.2 "$@" 2>&1 ) &
  wp=$!; n=0; until [ -d "$SLOT/in/lab-src" ] || [ $n -ge 50 ]; do sleep 0.1; n=$((n+1)); done
  sleep 1.5; kill $wp 2>/dev/null; wait $wp 2>/dev/null; [ "${FAKE_KEEP_SLOT:-0}" = 1 ] || rm -rf "$SLOT"; sleep "${FAKE_STAY_S:-0}"; echo "mbp-run: ssh caiu durante a execução — rode local"; exit 98
fi
( cd "$SLOT" && env -i HOME="$FAKE_ROOT/home" PATH="${FAKE_FIND_FAIL:+$FAKE_ROOT/mbp/failbin:}/usr/bin:/bin:/usr/sbin:/sbin" FAKE_SCEN="$FAKE_ROOT/scen" FAKE_S3="$FAKE_ROOT/s3" FAKE_CAP="$FAKE_CAP" \
    LAB_SAMPLE_S=1 LAB_POLL_S=0.2 "${extra[@]}" "$@" 2>&1 ) | cat
rc=${PIPESTATUS[0]}
grep -rIlF -f "$FAKE_ROOT/secret/canary.txt" "$SLOT" 2>/dev/null | grep -c . > "$FAKE_CAP/slot-canary-files"
if [ "${FAKE_EXEC:-run}" = drop ]; then rm -rf "$SLOT"; echo "mbp-run: ssh caiu durante a execução — rode local"; exit 98; fi
rel=${pull%%:*}; dest=${pull#*:}
[ -z "$pull" ] || { mkdir -p "$dest"; cp -Rp "$SLOT/$rel." "$dest" 2>/dev/null; }
chmod -R u+rwx "$SLOT" 2>/dev/null; rm -rf "$SLOT"
[ "${FAKE_EXEC:-run}" != killparent ] || kill -9 $PPID   # the orchestrator's subshell dies before it can record this exit code
exit $rc
EOF
# the lab, as the MBP wrapper calls it: compares the copy with the S3 fixture and writes the report
cat > "$T/scripts/dolt-restore-lab.sh" <<'EOF'
#!/bin/bash
sc() { sed -n "s/^$1=//p" "$FAKE_SCEN"; }
while [ $# -gt 0 ]; do case "$1" in --manifest) M="$2" ;; --report) R="$2" ;; --source) SRC="${2#file://}" ;; esac; shift; done
echo x >> "$FAKE_CAP/lab.invoked"; echo "${AWS_SHARED_CREDENTIALS_FILE:-unset} ${AWS_CONFIG_FILE:-unset}" > "$FAKE_CAP/lab.awsfiles"
if diff -r "$SRC" "$FAKE_S3/hq" >/dev/null 2>&1; then echo "lab: source identical to the S3 fixture"; else echo "lab: source DIFFERENT from the S3 fixture"; fi
if [ "$(sc leak)" = 1 ]; then   # a process with a credential in its argv that is GONE before the lab ends: only a periodic ps sample can see it.
  # It lives until the wrapper's sampler has recorded a hit (30 s cap), however slow ps is on a loaded machine.
  bash -c "sleep 35; :" AKIAQQQQQQQQQQQQQQQQ >/dev/null 2>&1 & lp=$!
  n=0; until grep -q '^[1-9]' out/.argv-samples 2>/dev/null || [ $n -ge 150 ]; do sleep 0.2; n=$((n+1)); done
  kill $lp 2>/dev/null; wait $lp 2>/dev/null
fi
[ "$(sc leak)" != 2 ] || { mkdir -p out; echo "AWS_SECRET_ACCESS_KEY=abc" > out/oops.txt; }
[ "$(sc leak)" != 3 ] || { echo "aws_access_key_id = abc" > in/note.txt; }
[ "$(sc leak)" != 4 ] || { mkdir -p in/locked; chmod 000 in/locked; }
[ "$(sc leak)" != 5 ] || { echo "aws_access_key_id = abc" > in/note.txt; mkdir -p in/locked; chmod 000 in/locked; }   # ACHOU e uma pasta nao abre: grep sai 2 com o acerto na saida
sleep 2
mode=$(sc lab)
[ "$mode" != norep ] || exit 0
python3 -I - "$M" "$R" "$mode" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); mode = sys.argv[3]
t = {k: {"expected": v, "restored": v} for k, v in m["tables"].items()}
v, rc = {"ok": ("OK", 0), "fail": ("FAIL", 1), "slow": ("SLOW", 3), "unknown": ("UNKNOWN", 2), "div_ok": ("OK", 0), "div_fail": ("FAIL", 1), "weird": ("OK", 0)}[mode]
if mode == "fail": t["issues"]["restored"] -= 1
json.dump({"verdict": v, "rc": rc, "reason": "razao do lab" if rc else None, "as_of": m["as_of"], "total_s": "9 RESULT: OK db=forjado" if mode == "weird" else 321, "source_kb": 13000000, "restored_kb": 14000000,
           "fetch_s": None, "restore_s": 200, "count_s": 21, "tables": t}, open(sys.argv[2], "w"))
PY
case "$mode" in ok) exit 0 ;; fail) exit 1 ;; slow) exit 3 ;; unknown) exit 2 ;; div_ok) exit 1 ;; div_fail) exit 0 ;; weird) exit 0 ;; esac
EOF
# the MBP's own tools (the wrapper puts ~/gt-remote/lab/bin first on PATH). An aws there would be a bug: it records the call.
cat > "$T/home/gt-remote/lab/bin/dolt" <<'EOF'
#!/bin/bash
[ "${1:-}" = version ] && echo "dolt version $(sed -n 's/^dolt_version=//p' "$FAKE_SCEN")"
EOF
printf '#!/bin/bash\necho x >> "$FAKE_CAP/mbp-aws-called"\nexit 1\n' > "$T/home/gt-remote/lab/bin/aws"
printf '#!/bin/bash\nshift\nexec "$@"\n' > "$T/home/gt-remote/lab/bin/timeout"
printf '#!/bin/bash\nwhile [ "${1#-}" != "$1" ]; do shift; done\nexec "$@"\n' > "$T/home/gt-remote/lab/bin/caffeinate"
cat > "$T/home/gt-remote/lab/bin/df" <<'EOF'
#!/bin/bash
case "$(sed -n 's/^disk=//p' "$FAKE_SCEN")" in
  small) printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/x 1000 900 100 90%% /\n' ;;
  junk) echo "df: sem saida util" ;;
  *) exec /bin/df "$@" ;;
esac
EOF
ln -sf "$(command -v python3)" "$T/home/gt-remote/lab/bin/python3"
# pylie: faz as vezes do python3; no modo `meta` APROVA o que FAKE_PYLIE disser (um ajudante que deixou passar valor hostil); o resto e o python3 de verdade
cat > "$T/bin/pylie" <<'EOF'
#!/bin/bash
if [ "${4:-}" = meta ]; then cat > /dev/null; printf '%b\n' "$FAKE_PYLIE"; exit 0; fi
exec python3 "$@"
EOF
mkdir -p "$T/fakedate"   # date com o segundo CONGELADO so no nome da pasta da rodada: duas rodadas "no mesmo segundo"
printf '#!/bin/bash\n[ "$*" = "-u +%%Y%%m%%dT%%H%%M%%SZ" ] && { echo 20261016T000000Z; exit 0; }\nexec /bin/date "$@"\n' > "$T/fakedate/date"
chmod +x "$T/bin/"* "$T/scripts/"*.sh "$T/home/gt-remote/lab/bin/"* "$T/fakedate/date"
printf '{"run_utc":"2026-10-16T07:07:25Z","databases":{"hq":{"issues":5,"head":"%s","backup_size":"13G"}}}\n' "$HEAD_H" > "$T/latest1.json"
printf '{"run_utc":"2026-10-16T07:59:00Z","databases":{"hq":{"issues":5,"head":"%s","backup_size":"13G"}}}\n' "$HEAD_H" > "$T/latest2.json"

# ---- harness ---------------------------------------------------------------------------------------------------------------
reset() {
  rm -rf "$T/state" "$T/cap" "$T/city" "$T/tmp" "$T/mbp" "$T/pwned" "$T/scen"
  mkdir -p "$T/state" "$T/cap" "$T/tmp" "$T/mbp" "$T/city/.gc/run" "$T/city/.gc/logs" "$T/city/.gc/runtime/packs/dolt"
  printf 'listener:\n  port: 4242\n' > "$T/city/.gc/runtime/packs/dolt/dolt-config.yaml"
}
# envrun [args] — FAKE_*/LABMBP_* come from the caller's environment prefix. MBP_SSH is the fake ssh unless the caller sets its own (the real-mbp-run section passes a probe stub). The mini HAS an AWS credential (the canary).
envrun() {
  env LABMBP_CITY="$T/city" LABMBP_STATE="${STATE_OVERRIDE:-$T/state}" LABMBP_AWS="$T/bin/aws" LABMBP_DOLT="$T/bin/dolt" LABMBP_NOTIFY="$T/bin/notify" \
      MBP_SSH="${MBP_SSH:-$T/bin/ssh}" MBP_HOST=fake@mbp LABMBP_SSH_OPTS="-o Fake=1" LABMBP_POLL_S=0.2 LABMBP_RETRY_S=0.2 LABMBP_NOW_HOUR="${LABMBP_NOW_HOUR:-0}" LABMBP_STREAM_S="${LABMBP_STREAM_S:-120}" \
      AWS_ACCESS_KEY_ID="$(sed -n 1p "$T/secret/canary.txt")" AWS_SECRET_ACCESS_KEY="$(sed -n 2p "$T/secret/canary.txt")" AWS_SESSION_TOKEN="$(sed -n 3p "$T/secret/canary.txt")" \
      TMPDIR="$T/tmp" FAKE_CAP="$T/cap" FAKE_ROOT="$T" "${LABMBP_TEST_BASH:-bash}" "$T/scripts/dolt-restore-lab-mbp.sh" "$@"
}
run() {
  env LABMBP_CITY="$T/city" LABMBP_STATE="${STATE_OVERRIDE:-$T/state}" LABMBP_AWS="$T/bin/aws" LABMBP_DOLT="$T/bin/dolt" FAKE_HEAD="$HEAD_H" \
      AWS_ACCESS_KEY_ID="$(sed -n 1p "$T/secret/canary.txt")" AWS_SECRET_ACCESS_KEY="$(sed -n 2p "$T/secret/canary.txt")" AWS_SESSION_TOKEN="$(sed -n 3p "$T/secret/canary.txt")" \
      FAKE_CAP="$T/cap" FAKE_ROOT="$T" "${LABMBP_TEST_BASH:-bash}" "$T/scripts/dolt-restore-lab-mbp.sh" "$@"
}
run() { OUT=$(envrun "$@" 2>&1); RC=$?; }
canary_hits() {   # files that must not hold the canary + the output of the run
  local n; n=$(grep -rIlF -f "$T/secret/canary.txt" "$T/cap" "$T/state" "$T/city" "$T/home" "$T/tmp" "$T/mbp" 2>/dev/null | grep -c .)
  printf '%s' "$OUT" | grep -qF -f "$T/secret/canary.txt" && n=$((n+1)); echo "$n"
}
cnt() { local n; n=$(grep -c "$2" "$T/cap/$1" 2>/dev/null); echo "${n:-0}"; }
calls() { cnt "$1" .; }
execs() { cnt mbprun.calls -e--exec; }
objreads() { cnt aws.argv "s3 cp $BKT/hq/"; }
summ() { cat "$T"/state/runs/*/summary.txt 2>/dev/null; }
labstream() { cat "$T"/state/runs/*/out/lab.stream 2>/dev/null; }
tmpleft() { ls -A "$T/tmp" 2>/dev/null | grep -c .; }
mbpfiles() { find "$T/mbp" -type f 2>/dev/null | grep -c .; }
labran() { [ -e "$T/cap/lab.invoked" ] && echo sim || echo nao; }
lastfinal() { [ -s "$T/state/last-final" ] && echo sim || echo nao; }
RUNDIR() { ls -d "$T"/state/runs/*/ 2>/dev/null | head -1; }

echo "== ga-3kmvyr: orquestrador do restore no MBP (o mini le o S3 e envia por ssh; nenhuma credencial vai ao MBP) =="
# ---------------------------------------------------------------------------------------------------------------------------------
echo "-- caminho feliz (OK), credencial canario no ambiente do mini"
reset; run
check "$RC" 0 "OK: rc 0"
has "$OUT" "RESULT: OK db=hq rc=0 as_of=$HEAD_H tabelas=2 objetos=5 stream_s=" "RESULT traz verdict, commit AS OF, tabelas e objetos"
check "$(python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m["as_of"], sorted(m["tables"].items()), m["schema"], m["db"])' "$(ls "$T"/state/runs/*/manifest.json)")" "$HEAD_H [('issues', 5), ('labels', 7)] 1 hq" "manifest: commit do latest.json, so BASE TABLE (a view fica de fora), contagens AS OF"
has "$(cat "$T/cap/dolt.argv")" "AS OF '$HEAD_H'" "a contagem foi feita AS OF o commit"
has "$(cat "$T/cap/dolt.argv")" "commit_hash = '$HEAD_H'" "o commit foi procurado no log do banco vivo"
has "$(cat "$T/cap/aws.argv")" "s3api list-objects-v2 --bucket urblink-dolt-backups --prefix hq/" "a lista de objetos vem do S3 (prefixo hq/)"
check "$(objreads)" 5 "os 5 objetos da lista foram lidos do S3, um cp cada"
has "$(cat "$T/cap/aws.argv")" "s3 cp $BKT/hq/oldgen/aaa -" "o objeto vai para stdout (cp ... -), nao para disco"
check "$(labstream | grep -c 'lab: source identical')" 1 "a copia que o lab recebeu e IDENTICA ao S3 (incluindo o vazio, o aninhado e o multiparte)"
check "$(labran)" sim "o lab rodou"
# credential hygiene: nothing AWS reaches the MBP
check "$(cat "$T/cap/lab.awsfiles")" "/dev/null /dev/null" "o lab roda com os arquivos de credencial/config da AWS apontados para /dev/null"
check "$(canary_hits)" 0 "CREDENCIAL: o canario nao esta em nenhum argv, env, arquivo nem na saida"
check "$(grep -c -E '^AWS_' "$T"/cap/mbprun.env.* "$T/cap/ssh.env" | awk -F: '{s+=$2} END{print s+0}')" 0 "o ambiente do mbp-run e do ssh nao carrega AWS_* (o mini tem credencial, o que vai ao MBP nao)"
hasnt "$(cat "$T/cap/mbprun.calls" "$T/cap/ssh.calls")" "--env" "mbp-run chamado sem --env"
check "$(calls sts.calls)" 0 "nenhum sts foi chamado"
check "$(calls mbp-aws-called)" 0 "o aws do MBP nunca foi chamado"
check "$(cat "$T/cap/slot-canary-files")" 0 "o slot do MBP nao tem o canario em nenhum arquivo"
check "$(grep -E -c -- "--exec --push $T/tmp/lab-mbp\.[A-Za-z0-9]+/lab-in --pull out/:$T/state/runs/[0-9TZ]+-[0-9]+/out/ -- bash in/lab-in/dolt-restore-lab-mbp-side.sh" "$T/cap/mbprun.calls")" 1 "push do stage e pull de out/ para a pasta da rodada"
has "$(cat "$T/cap/mbprun.calls")" "in/lab-in/dolt-restore-lab-mbp-side.sh --db hq --dolt-version 2.3.1 --rto-seconds 3600 --src-kb $EXPKB --margin-pct 400 --stream-wait-s 420" "o comando remoto leva so nomes e numeros (inclusive o tamanho do backup; espera = teto do envio + 300 s)"
has "$(grep -h '^MBP_RUN_TIMEOUT_S=\|^MBP_SLOT_MAX_AGE_S=' "$T"/cap/mbprun.env.* | sort | tr '\n' ' ')" "MBP_RUN_TIMEOUT_S=12600 MBP_SLOT_MAX_AGE_S=14400" "tetos do mbp-run para uma rodada longa"
check "$(cat "$T/cap/modes")" "modes: dir=700 parent=700" "stage 0700 no momento do push"
check "$(sort -u "$T/cap/mini-big" | tr -d '\n')" 0 "o mini NUNCA guardou o dado: nenhum arquivo grande no disco dele durante o envio"
check "$(mbpfiles)" 0 "o slot do MBP foi limpo no fim"
check "$(tmpleft)" 0 "o stage do mini foi apagado"
S=$(summ)
has "$S" "envio: objetos=5 kb=$EXPKB stream_s=" "resumo traz o envio: objetos e KB"
has "$S" "etag_verificado=5 etag_nao_verificavel=0" "os 5 ETags fecharam (inclusive o composto do multiparte e o do objeto vazio)"
has "$S" "dolt_version_mbp=2.3.1" "evidencia do MBP: versao do dolt"
has "$S" "copia_conferida=objetos=5 bytes=$EXPB" "evidencia do MBP: a copia conferida contra a lista"
check "$(echo "$S" | grep -c 'free_kb_before=[0-9]')" 1 "disco livre do MBP medido antes da rodada"
has "$S" "mbp-higiene: aws_env_vars=0 ps_acertos=0 arquivos-com-credencial=0" "higiene do MBP: contagens zero"
has "$S" "mini-higiene: arquivos-com-cara-de-credencial=0" "higiene do mini: zero"
hasnt "$S" "ALERTA" "sem alerta"
has "$S" "table=issues expected=5 restored=5" "resumo traz a contagem por tabela"
has "$S" "total_s=321" "resumo traz o tempo total"
has "$S" "backup_kb=13000000 restaurado_kb=14000000" "resumo traz os tamanhos"
check "$(calls notify.log)" 0 "OK nao dispara notify"
check "$(lastfinal)" sim "OK grava last-final"
check "$([ -d "$T/state/lock" ] && echo sim || echo nao)" nao "a trava foi solta"

echo "-- ja rodou esta semana"
run
check "$RC" 0 "segunda rodada: rc 0"
has "$OUT" "ja ha veredito conclusivo" "pula: ja ha veredito conclusivo"
has "$OUT" "RESULT: SKIPPED db=hq rc=0" "pula: RESULT SKIPPED (o agendador ve que nao rodou)"
check "$(execs)" 1 "o MBP nao foi tocado de novo"
run --force
check "$(execs)" 2 "--force roda de novo"
# uma tentativa que NAO deu veredito conclusivo (UNKNOWN) tambem segura as janelas seguintes por 12 h: so a primeira que acha o MBP livre trabalha
reset; SC_DOLT_VER=2.3.0 run
check "$RC" 2 "tentativa que deu UNKNOWN (dolt do MBP em outra versao)"; check "$(lastfinal)" nao "UNKNOWN nao e veredito da semana"; check "$(execs)" 1 "o MBP foi tocado uma vez"
run
check "$RC" 0 "a janela seguinte, minutos depois, pula"; has "$OUT" "uma rodada ja comecou nas ultimas 12 h" "diz por que pula"; has "$OUT" "RESULT: SKIPPED db=hq rc=0" "tentativa recente: RESULT SKIPPED"; check "$(execs)" 1 "o MBP nao foi tocado de novo"
run --force
check "$(execs)" 2 "--force ignora a tentativa recente"

# ---------------------------------------------------------------------------------------------------------------------------------
echo "-- vereditos do lab"
reset; SC_LAB=fail run
check "$RC" 1 "FAIL: rc 1"; has "$OUT" "RESULT: FAIL" "RESULT FAIL"
has "$(summ)" "table=issues expected=5 restored=4" "FAIL mostra a tabela que nao bate"
check "$(calls notify.log)" 1 "FAIL dispara notify"; check "$(lastfinal)" sim "FAIL e conclusivo: grava last-final"
check "$(canary_hits)" 0 "FAIL: canario ausente"
reset; SC_LAB=fail FAKE_MOVE=1 run
check "$RC" 2 "FAIL com o latest.json mudado no meio: rebaixado para UNKNOWN (rc 2)"
has "$OUT" "FAIL rebaixado" "diz que o FAIL foi rebaixado e por que"
check "$([ -e "$T/state/last-final" ] && echo sim || echo nao)" nao "FAIL rebaixado nao conta como veredito da semana"
reset; SC_LAB=fail FAKE_LATEST_FAIL_AFTER=1 run
check "$RC" 2 "FAIL e o latest.json nao relê: UNKNOWN, nao FAIL"
reset; SC_LAB=ok FAKE_MOVE=1 run
check "$RC" 0 "OK com o latest.json mudado no meio continua OK (igualdade exata num commit e prova)"
reset; SC_LAB=fail FAKE_LATEST2=tabsql run
check "$RC" 2 "FAIL e a releitura do latest.json vem hostil: UNKNOWN, nao FAIL"; has "$OUT" "FAIL rebaixado" "o rebaixamento e dito"
hasnt "$OUT" "CREATE TABLE" "o texto hostil da releitura nao chega ao log nem ao notify"; hasnt "$(cat "$T/cap/notify.log" 2>/dev/null)" "CREATE TABLE" "nem ao notify"
reset; SC_LAB=weird run
check "$RC" 0 "campo do relatorio com texto no lugar de numero: o veredito vem do campo conferido (OK)"
check "$(printf '%s\n' "$OUT" | grep -c 'RESULT:')" 1 "e a linha RESULT continua uma so (o texto forjado virou ?)"; has "$OUT" "total_s=? " "o campo ilegivel e ?"
reset; SC_LAB=slow run
check "$RC" 3 "SLOW: rc 3"; check "$(calls notify.log)" 1 "SLOW dispara notify"; check "$(lastfinal)" sim "SLOW e conclusivo"
reset; SC_LAB=unknown run
check "$RC" 2 "UNKNOWN do lab: rc 2"; check "$(calls notify.log)" 1 "UNKNOWN dispara notify"
check "$(lastfinal)" nao "UNKNOWN nao grava last-final"
check "$([ -s "$T/state/last-attempt" ] && echo sim)" sim "UNKNOWN grava last-attempt (a rodada comecou)"
run
has "$OUT" "uma rodada ja comecou nas ultimas 12 h" "a janela seguinte da mesma noite nao repete uma rodada que ja comecou"
reset; SC_LAB=norep run
check "$RC" 2 "lab sai 0 SEM relatorio: UNKNOWN, nunca OK"; hasnt "$OUT" "RESULT: OK" "sem relatorio nao ha OK"
has "$OUT" "relatorio do MBP ausente" "diz que o relatorio faltou"
reset; SC_LAB=div_fail run
check "$RC" 2 "lab sai 0 mas o relatorio diz FAIL: divergencia = UNKNOWN"; has "$OUT" "nao bate com o relatorio" "diz que nao bate"
reset; SC_LAB=div_ok run
check "$RC" 2 "lab sai 1 mas o relatorio diz OK: divergencia = UNKNOWN"

# ---------------------------------------------------------------------------------------------------------------------------------
echo "-- falha no meio do envio: UNKNOWN, nunca restore sobre copia parcial"
reset; FAKE_OBJ_FAIL_ONCE=hq/big run
check "$RC" 0 "objeto que falha uma vez e reenviado: OK"; has "$OUT" "objeto hq/big falhou" "o log diz que tentou de novo"; check "$(cnt aws.argv "s3 cp $BKT/hq/big -")" 2 "o objeto foi lido duas vezes"
check "$(labstream | grep -c 'lab: source identical')" 1 "e a copia final e identica ao S3"
reset; FAKE_SSH_DROP=big FAKE_SSH_DROP_ONCE=1 run
check "$RC" 0 "ssh cai no meio de um objeto uma vez: o objeto e reenviado inteiro, OK"
check "$(labstream | grep -c 'lab: source identical')" 1 "e o arquivo parcial deu lugar a copia inteira"
reset; FAKE_OBJ_FAIL=hq/big run
check "$RC" 2 "objeto que falha sempre: UNKNOWN"; has "$OUT" "objeto hq/big: o envio falhou" "diz qual objeto e por que"
check "$(labran)" nao "o lab NAO rodou sobre copia incompleta"; has "$(labstream)" "stream.failed" "o MBP foi avisado do fracasso do envio"
check "$(lastfinal)" nao "sem last-final"; check "$(calls notify.log)" 1 "notify"; check "$(mbpfiles)" 0 "slot limpo"; check "$(tmpleft)" 0 "stage apagado"
reset; FAKE_OBJ_TRUNC=hq/big run
check "$RC" 2 "aws sai 0 com o objeto cortado: UNKNOWN pelo tamanho"; has "$OUT" "o MBP gravou 100 bytes" "diz o tamanho gravado"; check "$(labran)" nao "o lab NAO rodou"
reset; FAKE_OBJ_CORRUPT=hq/abc123 run
check "$RC" 2 "objeto com o mesmo tamanho e conteudo diferente: UNKNOWN pelo ETag"; has "$OUT" "objeto hq/abc123: ETag" "diz o ETag"; check "$(labran)" nao "o lab NAO rodou"
reset; FAKE_OBJ_CORRUPT=hq/big run
check "$RC" 2 "multiparte corrompido (ETag composto recalculavel): UNKNOWN"; has "$OUT" "ETag composto" "diz que o composto nao fecha"
reset; FAKE_LIST_ETAG_BAD=hq/abc123 run
check "$RC" 2 "a lista diz um ETag simples que o objeto nao tem: UNKNOWN"
reset; FAKE_LIST_ETAG_MP=hq/abc123 run
check "$RC" 0 "ETag composto que nao e de partes de 8 MiB: so o tamanho vale, OK"; has "$(summ)" "etag_verificado=4 etag_nao_verificavel=1" "o resumo conta o nao verificavel"
mkdir -p "$T/s3/hq/emptydir"; reset; FAKE_LIST_DIRMARK=1 run; rmdir "$T/s3/hq/emptydir"
check "$RC" 0 "marcador de pasta na lista: a pasta e criada no MBP e o resto segue"; check "$(labstream | grep -c 'lab: source identical')" 1 "copia identica, com a pasta vazia"
reset; FAKE_OBJ_SLOW=2 LABMBP_STREAM_S=1 run
check "$RC" 2 "envio passou do teto de tempo: UNKNOWN"; has "$OUT" "o envio passou de 1s" "diz o teto"; check "$(labran)" nao "o lab NAO rodou"; has "$(labstream)" "stream.failed" "o MBP soube que acabou"
reset; FAKE_EXEC=die_after_ready FAKE_OBJ_SLOW=1 run
check "$RC" 2 "o job do MBP morre com o envio em curso: UNKNOWN"; has "$OUT" "terminou antes do fim do envio" "diz que o job acabou"
check "$(mbpfiles)" 0 "e o mini PAROU de enviar: nada recriado no slot ja limpo"
reset; FAKE_EXEC=die_after_ready FAKE_STAY_S=9 FAKE_OBJ_SLOW=1 run
check "$RC" 2 "o slot sumiu mas o mbp-run ainda nao avisou (a corrida): UNKNOWN"; check "$(mbpfiles)" 0 "e o mini NAO recriou o slot que o mbp-run apagou (a guarda do lado do MBP)"
reset; FAKE_EXEC=die_after_ready FAKE_KEEP_SLOT=1 FAKE_OBJ_SLOW=2 run
check "$RC" 2 "o job morre mas o slot fica de pe: UNKNOWN"; has "$OUT" "terminou antes do fim do envio" "diz que o job acabou"
check "$([ "$(objreads)" -lt 5 ] && echo parou || echo mandou-tudo)" parou "e o mini PAROU de ler o S3 mesmo sem a trava do slot limpo"

echo "-- a copia no disco do MBP tem de ser a lista (o wrapper confere por conta propria)"
for tm in missing:faltam=1 extra:sobram=1 size:tamanho-diferente=1; do
  reset; FAKE_TAMPER=${tm%%:*} run
  check "$RC" 2 "copia adulterada (${tm%%:*}) depois do envio: UNKNOWN"; has "$OUT" "a copia no MBP nao e a lista do S3: faltam=" "recusa com o motivo"; has "$OUT" "${tm#*:}" "e conta o que difere (${tm#*:})"
  check "$(labran)" nao "copia adulterada (${tm%%:*}): o lab NAO rodou"
done

echo "-- lista do S3 ruim: nada e enviado"
for f in FAKE_LIST_FAIL FAKE_LIST_EMPTY FAKE_LIST_BADKEY; do
  reset; export "$f=1"; run; unset "$f"
  check "$RC" 2 "$f: UNKNOWN"; check "$(execs)" 0 "$f: nada foi empurrado ao MBP"; check "$(objreads)" 0 "$f: nenhum objeto lido"
  check "$([ -e "$T/state/last-attempt" ] && echo sim || echo nao)" nao "$f: a rodada nao 'comecou'"; check "$(tmpleft)" 0 "$f: sem stage"
done
reset; FAKE_LIST_BADKEY=1 run
has "$OUT" "fora do formato" "chave com caractere de shell: a lista e recusada, diz que veio fora do formato"
for bk in 2:com-ponto-ponto 3:fora-do-prefixo-hq; do
  reset; FAKE_LIST_BADKEY=${bk%%:*} run
  check "$RC" 2 "chave ${bk#*:}: UNKNOWN"; has "$OUT" "fora do formato" "chave ${bk#*:}: lista recusada"; check "$(execs)" 0 "chave ${bk#*:}: nada empurrado ao MBP"; check "$(objreads)" 0 "chave ${bk#*:}: nenhum objeto lido"
done

# ---------------------------------------------------------------------------------------------------------------------------------
echo "-- MBP nao livre / mbp-run recusa (antes de comecar)"
for pr in uso lixo off; do
  reset; FAKE_PRESENCE=$pr LABMBP_NOW_HOUR=0 run
  check "$RC" 4 "presenca '$pr' as 00h: adiado (rc 4)"
  check "$(calls aws.argv)" 0 "presenca '$pr': o S3 nem foi tocado"
  check "$(execs)" 0 "presenca '$pr': nada foi empurrado ao MBP"
  check "$(calls notify.log)" 0 "adiado nao dispara notify"
done
reset; FAKE_PRESENCE=uso LABMBP_NOW_HOUR=1 run; check "$RC" 4 "01h ainda adia"
reset; FAKE_PRESENCE=uso LABMBP_NOW_HOUR=5 run; check "$RC" 2 "05h ainda e a janela da noite: adiar vira UNKNOWN"
reset; FAKE_PRESENCE=uso LABMBP_NOW_HOUR=14 run; check "$RC" 4 "14h (rodada manual de dia) nao e a ultima janela: ADIADO"; check "$(calls notify.log)" 0 "e nao notifica"
reset; FAKE_PRESENCE=uso LABMBP_NOW_HOUR=2 run
check "$RC" 2 "02h (ultima janela): adiar vira UNKNOWN"; check "$(calls notify.log)" 1 "e dispara notify"; has "$OUT" "adiado ate a ultima janela" "diz por que"
reset; FAKE_EXEC=refuse98 LABMBP_NOW_HOUR=0 run
check "$RC" 4 "mbp-run recusa (98) antes do ready: adiado"; check "$(objreads)" 0 "recusa: nenhum objeto lido"; check "$(tmpleft)" 0 "recusa: stage apagado"
reset; FAKE_EXEC=refuse98 LABMBP_NOW_HOUR=2 run; check "$RC" 2 "mbp-run recusa na ultima janela: UNKNOWN"
# a recusa DEPOIS do launch e antes do ready nao e uma rodada que comecou: a janela seguinte da mesma noite tem de poder tentar
reset; FAKE_EXEC=refuse98 LABMBP_NOW_HOUR=0 run
check "$([ -e "$T/state/last-attempt" ] && echo sim || echo nao)" nao "recusa antes do ready: sem last-attempt (a rodada nao comecou)"
run   # sem reset: o mesmo estado, a janela seguinte (FAKE_EXEC volta ao padrao)
check "$RC" 0 "a janela seguinte roda de verdade (as 12 h do last-attempt nao a pulam)"; has "$OUT" "RESULT: OK" "e termina OK"; hasnt "$OUT" "RESULT: SKIPPED" "e nao e pulada"
reset; FAKE_EXEC=refuse98 FAKE_ATTEMPT_STUCK=1 LABMBP_NOW_HOUR=0 run
check "$RC" 2 "recusa e o last-attempt nao sai: UNKNOWN, nao o adiamento mudo"; has "$OUT" "nao consegui apagar" "diz que o marcador ficou"; check "$(calls notify.log)" 1 "e avisa"
reset; FAKE_EXEC=drop run
check "$RC" 2 "mbp-run cai (98) DEPOIS do ready e do envio: UNKNOWN (nao adiado)"; has "$OUT" "caiu ou estourou" "diz que caiu no meio"; check "$(lastfinal)" nao "sem last-final"
reset; FAKE_EXEC=killparent run
check "$RC" 2 "relatorio OK mas o rc do mbp-run se perdeu: UNKNOWN, nunca OK"; has "$OUT" "mbp-run rc=?" "diz que o rc e desconhecido"; check "$(lastfinal)" nao "sem last-final"
reset; FAKE_EXEC=noready FAKE_NOREADY_S=4 LABMBP_READY_S=1 run
check "$RC" 2 "o MBP nunca fica pronto: UNKNOWN"; has "$OUT" "o MBP nao ficou pronto em 1s" "diz que nao ficou pronto"; check "$(objreads)" 0 "nenhum objeto lido"; check "$(calls notify.log)" 1 "notify"

for bs in "/a/../b/exec/1" "/a b;touch $T/pwned/exec/1" "relativo/exec/1" "/x/exec/1x"; do
  reset; FAKE_EXEC=badslot FAKE_BADSLOT="$bs" run
  check "$RC" 2 "o wrapper devolve o slot '$bs': UNKNOWN"; has "$OUT" "caminho de slot inesperado" "recusa o caminho"
  check "$(objreads)" 0 "slot '$bs': nenhum objeto lido"; check "$([ -e "$T/pwned" ] && echo sim || echo nao)" nao "slot '$bs': nada executado"
done

echo "-- bloqueios do lado do mini"
reset; FAKE_HEAD_COUNT=0 run
check "$RC" 2 "commit do latest.json ausente no banco vivo: UNKNOWN, nunca OK"; has "$OUT" "NAO existe no banco vivo" "diz que o commit nao existe"; check "$(objreads)" 0 "nenhum objeto lido"
reset; FAKE_LATEST_FAIL=1 run
check "$RC" 2 "latest.json ilegivel: UNKNOWN"; check "$(execs)" 0 "nada foi empurrado ao MBP"
reset; printf '{"run_utc":"x","databases":{"hq":{"head":"ABC"}}}' > "$T/latest1.json"; run
check "$RC" 2 "head que nao e hash de commit: UNKNOWN"
printf '{"run_utc":"2026-10-16T07:07:25Z","databases":{"hq":{"issues":5,"head":"%s","backup_size":"13G"}}}\n' "$HEAD_H" > "$T/latest1.json"

echo "-- recusa do wrapper do MBP (antes do envio)"
reset; SC_DOLT_VER=2.3.0 run
check "$RC" 2 "dolt do MBP em outra versao: UNKNOWN"; has "$OUT" "dolt do MBP e 2.3.0, o do mini e 2.3.1" "diz as duas versoes"
check "$(objreads)" 0 "recusa antes do ready: nenhum objeto lido"; check "$(tmpleft)" 0 "stage apagado"; check "$(labran)" nao "o lab nao rodou"
reset; SC_DISK=small run
check "$RC" 2 "disco do MBP curto: UNKNOWN"; has "$OUT" "disco insuficiente no MBP (100KB livres" "diz quanto tem"; check "$(objreads)" 0 "e nenhum byte foi enviado"
reset; SC_DISK=junk run
check "$RC" 2 "disco do MBP ilegivel: UNKNOWN, nunca OK"; has "$OUT" "nao consegui medir o disco livre do MBP" "diz que nao mediu"; check "$(objreads)" 0 "nenhum byte enviado"

# the wrapper alone, in a slot of its own (no mbp-run, no orchestrator): wrun [env VAR=...] ARGS → WOUT, WRC
wrun() {
  rm -rf "$T/wslot" "$T/wrc"; mkdir -p "$T/wslot"; printf 'lab=ok\ndolt_version=2.3.1\nleak=0\ndisk=ok\n' > "$T/scen"
  ( cd "$T/wslot" && ${WPRE:-:} && env -i HOME="${WHOME:-$T/home}" PATH="${WPATH:-/usr/bin:/bin}" LAB_BREW_BIN="${WBREW:-/nonexistent}" FAKE_SCEN="$T/scen" LAB_POLL_S=0.2 \
      /bin/bash "$T/scripts/dolt-restore-lab-mbp-side.sh" --db hq --dolt-version 2.3.1 --rto-seconds 3600 --src-kb 100 "$@" > "$T/wout" 2>&1; echo $? > "$T/wrc" ) &
  local n=0; until [ -e "$T/wrc" ] || [ $n -ge 100 ]; do sleep 0.2; n=$((n+1)); done
  [ -e "$T/wrc" ] || { touch "$T/wslot/stream.failed"; until [ -e "$T/wrc" ]; do sleep 0.2; done; }   # a wrapper that never gives up is told to stop
  WRC=$(cat "$T/wrc"); WOUT=$(cat "$T/wout")
}
for tool in dolt python3 timeout; do   # a PATH of system tools WITHOUT $tool, and a MBP home whose lab/bin lacks it
  rm -rf "$T/np" "$T/nh"; mkdir -p "$T/np" "$T/nh/gt-remote/lab/bin"
  ln -sf /usr/bin/* /bin/* /usr/sbin/* /sbin/* "$T/np/" 2>/dev/null; rm -f "$T/np/$tool"; [ "$tool" != timeout ] || rm -f "$T/np/gtimeout"
  ln -sf "$T/home/gt-remote/lab/bin"/* "$T/nh/gt-remote/lab/bin/"; rm -f "$T/nh/gt-remote/lab/bin/$tool"
  WHOME="$T/nh" WPATH="$T/np" wrun --stream-wait-s 1
  check "$WRC" 2 "wrapper sem $tool no MBP: UNKNOWN"; has "$WOUT" "ferramenta ausente no MBP: $tool" "diz qual ferramenta falta"; check "$(printf '%s' "$WOUT" | grep -c 'ready slot')" 0 "e nao fica pronto para o envio"
done
wrun --stream-wait-s 1
check "$WRC" 2 "wrapper: o mini nunca manda o fim do envio: UNKNOWN pelo teto de espera"; has "$WOUT" "nao terminou o envio em 1s" "diz o teto"
WPRE='touch stream.failed' wrun --stream-wait-s 1
check "$WRC" 2 "slot reusado com stream.failed velho: UNKNOWN so pelo teto"; has "$WOUT" "nao terminou o envio em 1s" "o wrapper esperou o envio desta rodada"; hasnt "$WOUT" "stream.failed" "e nao deu o envio velho como falha desta"

echo "-- higiene detecta credencial"
reset; SC_BROKEN=env run
check "$RC" 0 "env quebrado no MBP: o veredito do restore fica"; has "$(summ)" "aws_env_vars=?" "a contagem fica '?', nunca 0"; has "$(summ)" "ALERTA" "e a prova nao medida avisa"; check "$(calls notify.log)" 1 "notify"
reset; SC_BROKEN=ps run
check "$RC" 0 "ps quebrado no MBP: o veredito do restore fica"; has "$(summ)" "ps_acertos=?" "sem nenhuma amostra de ps, os acertos ficam '?', nunca 0"; has "$(summ)" "ALERTA" "e a prova nao medida avisa"; check "$(calls notify.log)" 1 "notify"
reset; SC_PSFLAKY=1 run
EVD() { cat "$T"/state/runs/*/out/evidence.txt 2>/dev/null; }   # the wrapper's evidence, pulled back with out/
check "$RC" 0 "ps falha em algumas amostras e as outras nao acham nada: o veredito fica"; has "$(EVD)" "argv_samples_falhas=1" "o cenario e PARCIAL de verdade: 1 amostra falhou"; hasnt "$(EVD)" "argv_samples=0 " "e ao menos uma amostra limpa (senao seria o caso 'ps quebrado', ja coberto acima)"; has "$(summ)" "ps_acertos=?" "zero parcial nao e zero: fica '?'"; has "$(summ)" "ALERTA" "e a prova incompleta avisa"; check "$(calls notify.log)" 1 "notify"
reset; SC_PSFLAKY=1 SC_LEAK=1 run
has "$(EVD)" "argv_samples_falhas=1" "ps falhou em 1 amostra e as outras rodaram"; check "$(summ | grep -c 'ps_acertos=[1-9]')" 1 "ps falha em algumas amostras mas uma achou a credencial: o achado conta"; has "$(summ)" "ALERTA" "e grita"
reset; SC_AWSENV=1 run
check "$RC" 0 "variavel AWS_* na sessao remota nao muda o veredito do restore"; has "$(summ)" "aws_env_vars=1" "a contagem aparece"; has "$(summ)" "ALERTA" "mas o resumo grita"; check "$(calls notify.log)" 1 "e dispara notify mesmo com OK"
reset; SC_LEAK=1 run
has "$(summ)" "ALERTA" "credencial no argv de um processo do MBP: ALERTA"; check "$(summ | grep -c 'ps_acertos=[1-9]')" 1 "o ps do MBP achou"; check "$(calls notify.log)" 1 "notify"
reset; SC_LEAK=2 run
has "$(summ)" "ALERTA" "credencial gravada em out/ do slot do MBP: ALERTA"; check "$(summ | grep -c 'arquivos-com-credencial=[1-9]')" 1 "o grep do slot achou o arquivo"
reset; SC_LEAK=3 run
has "$(summ)" "ALERTA" "credencial gravada em in/ do slot do MBP: ALERTA"
reset; SC_LEAK=4 run
check "$RC" 0 "grep do slot nao consegue ler uma pasta: o veredito fica"; has "$(summ)" "arquivos-com-credencial=?" "a contagem fica '?', nunca 0"; has "$(summ)" "ALERTA" "e a prova nao medida avisa"; check "$(calls notify.log)" 1 "notify"
# ACHOU e uma pasta nao abriu: o achado nunca vira "nao consegui saber". Com lab UNKNOWN o '?' e ignorado, entao so o numero faz o alerta subir.
reset; SC_LEAK=5 run
check "$RC" 0 "credencial no slot E uma pasta que nao abre: o veredito fica"; has "$(summ)" "arquivos-com-credencial=1" "o achado conta 1, nao '?'"; has "$(summ)" "ALERTA" "e grita"
reset; SC_LEAK=5 SC_LAB=unknown run
has "$(summ)" "arquivos-com-credencial=1" "lab UNKNOWN: o achado tambem conta 1"; has "$(summ)" "ALERTA" "e o alerta sobe mesmo onde o '?' seria ignorado"
reset; FAKE_MINI_LEAK=1 run
check "$RC" 0 "arquivo com cara de credencial no stage do mini nao muda o veredito"; has "$(summ)" "mini-higiene: arquivos-com-cara-de-credencial=1" "o grep do mini achou"; has "$(summ)" "ALERTA" "e grita"
reset; FAKE_MINI_LEAK=2 run
has "$(summ)" "mini-higiene: arquivos-com-cara-de-credencial=1" "credencial no log do mbp-run: o grep do mini achou"
reset; FAKE_MINI_LEAK=3 run; chmod -R u+rwx "$T/state/zz-unreadable" 2>/dev/null
check "$RC" 0 "grep do mini nao consegue ler uma pasta: o veredito fica"; has "$(summ)" "mini-higiene: arquivos-com-cara-de-credencial=?" "a contagem fica '?', nunca 0"
has "$(summ)" "ALERTA" "e a prova nao medida avisa"; check "$(calls notify.log)" 1 "notify"
reset; FAKE_MINI_LEAK=4 run; chmod -R u+rwx "$T/state/zz-unreadable" 2>/dev/null
check "$RC" 0 "credencial no stage do mini E uma pasta que nao abre: o veredito fica"; has "$(summ)" "mini-higiene: arquivos-com-cara-de-credencial=1" "o achado conta 1, nao '?'"; has "$(summ)" "ALERTA" "e grita"
reset; FAKE_MINI_LEAK=4 SC_LAB=unknown run; chmod -R u+rwx "$T/state/zz-unreadable" 2>/dev/null
has "$(summ)" "mini-higiene: arquivos-com-cara-de-credencial=1" "lab UNKNOWN: o achado do mini tambem conta 1"; has "$(summ)" "ALERTA" "e o alerta sobe mesmo onde o '?' seria ignorado"

echo "-- slot reusado com a sobra da rodada anterior (o gate achou: o mbp-run so avisa quando nao limpa o scratch)"
# a sobra em in/lab-src faz a conferencia "exatamente a lista do S3" falhar (sobram=N) toda semana e entra na medida de disco livre; um
# report.json velho, com o lab saindo 0 sem escrever um novo, seria lido como o resultado DESTA rodada
reset; run
has "$(EVD)" "src_sobra_apagada=0" "slot limpo: nada a apagar e a evidencia diz 0"
reset; FAKE_STALE_SLOT=1 run
check "$RC" 0 "slot com lab-src da rodada anterior: so a copia desta rodada e conferida e a rodada termina OK"; has "$OUT" "RESULT: OK" "OK de verdade"
has "$(EVD)" "src_sobra_apagada=2" "a evidencia conta o que apagou (a pasta oldtable e o arquivo dentro dela)"; hasnt "$OUT" "sobram" "e a conferencia da copia nao reclama de sobra"
# dolt-restore-lab-mbp-side.sh: a contagem e so evidencia: o find que falha nao impede nem esconde a limpeza, e o que nao deu para contar nunca vira "0 apagados"
reset; FAKE_STALE_SLOT=1 FAKE_FIND_FAIL=1 run
check "$RC" 0 "o find que conta a sobra falha: a sobra sai do mesmo jeito e a rodada termina OK"; has "$OUT" "RESULT: OK" "OK de verdade (a copia foi conferida sem a sobra)"
has "$(EVD)" "src_sobra_apagada=?" "a contagem que nao deu fica '?'"; hasnt "$(EVD)" "src_sobra_apagada=0" "e nunca vira 0"
reset; FAKE_STALE_SLOT=4 SC_LAB=norep run
check "$RC" 2 "report.json OK velho no slot e o lab sai 0 sem relatorio novo: UNKNOWN, nunca o OK de outra rodada"; hasnt "$OUT" "RESULT: OK" "sem relatorio desta rodada nao ha OK"
has "$OUT" "relatorio do MBP ausente" "diz que o relatorio faltou (o velho foi apagado antes)"
reset; FAKE_STALE_SLOT=2 run
check "$RC" 2 "in/lab-src e um link para fora do slot: UNKNOWN"; has "$OUT" "e um link" "diz por que"
check "$(objreads)" 0 "nenhum objeto lido"; check "$(labran)" nao "o lab nao rodou"; check "$(cat "$T/mbp/outside/keep.txt" 2>/dev/null)" keep "o alvo do link ficou intacto (nada fora do slot foi apagado)"
reset; FAKE_STALE_SLOT=3 run
check "$RC" 2 "sobra que nao da para apagar: UNKNOWN, nao segue por cima de pasta que nao e provadamente nossa"; has "$OUT" "nao consegui apagar a sobra" "diz que a sobra ficou"
check "$(objreads)" 0 "nenhum objeto lido"; check "$(labran)" nao "o lab nao rodou"

echo "-- orquestrador morto no meio do envio"
reset
( FAKE_OBJ_SLOW=2 envrun --force > "$T/kill.out" 2>&1 ) & KP=$!
n=0; until grep -q "s3 cp $BKT/hq/" "$T/cap/aws.argv" 2>/dev/null || [ $n -ge 100 ]; do sleep 0.2; n=$((n+1)); done
OP=$(cat "$T/state/lock/pid" 2>/dev/null); [ -z "$OP" ] || kill "$OP"
wait $KP; KRC=$?
n=0; until [ ! -d "$T/mbp/gt-remote/exec/1" ] || [ $n -ge 150 ]; do sleep 0.2; n=$((n+1)); done
check "$KRC" 143 "TERM no meio do envio: o orquestrador sai com 143"
check "$(labran)" nao "o lab NAO rodou sobre o que ja tinha chegado"
has "$(labstream)" "stream.failed" "o MBP foi avisado e desistiu"
check "$([ -d "$T/state/lock" ] && echo sim || echo nao)" nao "a trava foi solta"; check "$(tmpleft)" 0 "o stage foi apagado"; check "$(lastfinal)" nao "sem last-final"

echo "-- estado inutilizavel numa rodada real: UNKNOWN e aviso, nao o silencio de 'nada a fazer'"
reset; : > "$T/notadir"; STATE_OVERRIDE="$T/notadir/state" run
check "$RC" 2 "rodada real sem estado: rc 2"; has "$OUT" "nao consegui criar $T/notadir/state" "o motivo diz qual pasta"
check "$(execs)" 0 "sem estado nao toca o MBP"; check "$(calls notify.log)" 1 "e avisa (rc 2 de uma rodada real)"

echo "== a metade do mini, so leitura (fatia 2/4): --dry-run, --check, trava, argumentos =="
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
# o restore de verdade tambem nao fica pendurado: cada chamada tem teto e o objeto tem o seu (o que sobra do teto do envio, no minimo 30 s)
reset; FAKE_DOLT_VER_HANG=1 LABMBP_CALL_S=3 run
check "$RC" 2 "dolt version pendurado: UNKNOWN"; check "$([ -e "$T/cap/hang.term" ] && echo sim || echo nao)" sim "dolt version pendurado: o teto matou a chamada (nao esperou ela acabar)"; has "$OUT" "nao consegui ler a versao do dolt do mini" "dolt version pendurado: diz o que faltou"; check "$(execs)" 0 "dolt version pendurado: o MBP nao foi tocado"
reset; SC_LAB=fail FAKE_LATEST_HANG_AFTER=1 LABMBP_CALL_S=3 run
check "$RC" 2 "FAIL e a releitura do latest.json pendurada: UNKNOWN, nao FAIL"; check "$([ -e "$T/cap/hang.term" ] && echo sim || echo nao)" sim "releitura pendurada: o teto matou a chamada"; has "$OUT" "FAIL rebaixado" "releitura pendurada: diz que rebaixou"; check "$(lastfinal)" nao "releitura pendurada: nao conta como veredito"
reset; FAKE_OBJ_HANG=hq/LOCK LABMBP_STREAM_S=1 LABMBP_OBJ_MIN_S=2 run   # hq/LOCK e o 1o da lista (ordem binaria): nenhum objeto antes dele gasta o 1 s do envio, nem com a maquina carregada
check "$RC" 2 "aws cp de um objeto pendurado: UNKNOWN"; has "$OUT" "objeto hq/LOCK: o envio falhou" "objeto pendurado: diz qual"; has "$OUT" "aws s3 cp sem resposta em 2s (timeout)" "objeto pendurado: o piso do teto vale quando o envio ja estourou"; check "$(labran)" nao "objeto pendurado: o lab NAO rodou"
reset; FAKE_OBJ_HANG=hq/abc123 LABMBP_STREAM_S=20 LABMBP_OBJ_MIN_S=2 run
check "$RC" 2 "objeto pendurado com tempo de envio sobrando: UNKNOWN"; has "$OUT" "aws s3 cp sem resposta em " "tempo sobrando: diz o teto"; has "$OUT" "tentando de novo" "tempo sobrando: o objeto foi tentado de novo"; hasnt "$(printf '%s\n' "$OUT" | grep 'tentando de novo')" "sem resposta em 2s" "o teto da 1a tentativa e o que SOBRA do envio, nao o piso (a 2a ja nao tem sobra)"

echo "-- argumentos"
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

echo "-- so da rodada completa: --dry-run nao envia nem avisa; --install-dolt"
reset; run --dry-run; check "$(objreads)" 0 "--dry-run nao le objeto"; check "$(execs)" 0 "--dry-run nao toca o MBP"; check "$(calls notify.log)" 0 "--dry-run nao notifica"
check "$([ -e "$T/state/last-attempt" ] && echo sim || echo nao)" nao "--dry-run nao marca tentativa"
reset; run --install-dolt
check "$RC" 0 "--install-dolt: rc 0"; has "$OUT" "dolt version 2.3.1" "instala e mostra a versao"; check "$([ -x "$T/home/gt-remote/lab/bin/dolt" ] && echo sim)" sim "o dolt do mini foi copiado para ~/gt-remote/lab/bin"
check "$(grep -c -E '^AWS_' "$T"/cap/mbprun.env.* | awk -F: '{s+=$2} END{print s+0}')" 0 "--install-dolt tambem roda sem AWS_*"
has "$OUT" "mesma versao do mini" "e diz que conferiu a versao com a do mini"
# o dolt copiado que NAO roda: `... version | head -1` devolvia o rc do head (0) e o passo dizia sucesso (gate ga-qbxlln)
reset; SC_DOLT_RUN=fail run --install-dolt
check "$RC" 1 "dolt copiado nao roda: --install-dolt FALHA"; has "$OUT" "o dolt copiado NAO roda: exec format error" "o erro do dolt aparece"; hasnt "$OUT" "mesma versao do mini" "e nao diz que instalou"
reset; SC_DOLT_RUN=empty run --install-dolt
check "$RC" 2 "dolt copiado sai 0 sem dizer a versao: UNKNOWN"; has "$OUT" "nao provei que o dolt do MBP roda" "diz o que faltou"; hasnt "$OUT" "mesma versao do mini" "e nao diz que instalou"
reset; SC_DOLT_RUN=other run --install-dolt
check "$RC" 1 "dolt do MBP com versao diferente da do mini: FAIL"; has "$OUT" "o dolt do MBP e 9.9.9 e o do mini e 2.3.1" "diz as duas versoes"
reset; FAKE_DOLT_VER_HANG=1 LABMBP_CALL_S=2 run --install-dolt
check "$RC" 2 "versao do dolt do mini ilegivel: UNKNOWN"; has "$OUT" "nao consegui ler a versao do dolt do mini" "diz o que faltou"; check "$(execs)" 0 "e o MBP nao foi tocado"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
