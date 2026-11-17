#!/usr/bin/env bash
# hetzner-tmp-reaper.selftest.sh — ga-d4iob2s. Prova scripts/hetzner-tmp-reaper.py sem tocar no /tmp de verdade: idade da ÁRVORE (mtime e ctime), dono,
# exceções, em-uso (cwd, fd, argv, socket ligado), contêineres claude-* e pytest-of-*, link não seguido, o teto de tempo, entrada que some no meio da pasta, idade/teto
# que não são número, e os 3 estados (df, /proc, varredura, keep.txt, gravação do status/log: leitura ou gravação que falha NÃO vira "limpo"). O /proc é de mentira (--proc) e o relógio também (--now); o /proc real só no caso 12 (Linux). Fecha com mutantes do reaper
# que este arquivo tem de reprovar. Env: TMP_REAPER_UNDER_TEST (outro reaper), TR_SKIP_MUTANTS=1 (pula o caso 14). Roda em bash 3.2 e 5.
set -uo pipefail
SELF="${BASH_SOURCE[0]}"; SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"; SELF="$SELF_DIR/$(basename "$SELF")"
REAPER="${TMP_REAPER_UNDER_TEST:-$SELF_DIR/hetzner-tmp-reaper.py}"
PASS=0; FAIL=0; SKIP=0
ok()   { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
chk()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: obtido [$2], esperado [$3]"; fi; }
have() { [ -e "$1" ] || [ -L "$1" ]; }
gone() { if have "$2"; then bad "$1: ainda existe"; else ok "$1: apagado"; fi; }
kept() { if have "$2"; then ok "$1: mantido"; else bad "$1: foi apagado"; fi; }
[ "$(id -u)" -ne 0 ] || { echo "RESULT: FAIL (rode como usuário comum: o reaper recusa root)"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3"; echo "RESULT: FAIL"; exit 1; }
[ -r "$REAPER" ] || { echo "RESULT: FAIL (sem o reaper: $REAPER)"; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tmp-reaper-st.XXXXXX")" || { echo "FATAL: mktemp"; exit 1; }
PIDS=""
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null; done; chmod -R u+rwx "$WORK" 2>/dev/null; find "$WORK" -depth -delete 2>/dev/null; }
trap cleanup EXIT

# fx.py monta uma cena: T = o /tmp de mentira (1777), S = pasta de estado, P = /proc de mentira, OUT = fora da raiz. Relógio da cena: criado em NOW0; o de mentira
# do reaper será NOW0+500 com janela de 100 s: o que foi criado agora tem idade 500 s (velho); mtime NOW0+450 tem 50 s (recente).
cat > "$WORK/fx.py" << 'PY'
import os, sys
T, S, P, OUT, now0, oldm = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], float(sys.argv[5]), sys.argv[6] == "oldm"
FUT = now0 + 450
def put(rel, mtime=None):
    p = os.path.join(T, rel); os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write("x")
    m = mtime if mtime is not None else (now0 - 86400 if oldm else None)
    if m is not None: os.utime(p, (m, m))
os.chmod(T, 0o1777)
for r in ("old-file", "old-dir/a/b/c.txt", "tmux-1000/gc-remote", "custom-keep-dir/f", "inuse-cwd/sub/deeper/f", "inuse-fd/lock", "inuse-argv/x", "inuse-sock/s",
          "claude-1000/proj-old/s/scratch.txt", "claude-1000/proj-inuse/work/f", "mode000/f", "with-mount/sub/f", "pytest-of-runner/pytest-0/t.py", "no-search/f"):
    put(r)
put("fresh-file", FUT); put("fresh-deep/x/y/z.txt", FUT); put("claude-1000/proj-fresh/s/scratch.txt", FUT); put("pytest-of-runner/pytest-1/t.py", FUT)
os.makedirs(os.path.join(OUT, "precious")); open(os.path.join(OUT, "precious", "keep.txt"), "w").write("x")
os.symlink(os.path.join(OUT, "precious"), os.path.join(T, "link-old")); os.symlink(os.path.join(OUT, "precious"), os.path.join(T, "old-dir", "inner-link"))
if oldm:  # mtime velho em TUDO (pastas também) e ctime de agora: o que tar -x e chmod deixam
    for dp, dn, fn in os.walk(T, topdown=False):
        for n in dn + fn: os.utime(os.path.join(dp, n), (now0 - 86400,) * 2, follow_symlinks=False)
os.chmod(os.path.join(T, "mode000"), 0)
os.chmod(os.path.join(T, "no-search"), 0o444)   # legível sem busca: o nome do filho aparece, o carimbo dele não (EACCES no stat)
open(os.path.join(S, "keep.txt"), "w").write("# o que fica\ncustom-keep-*\n")
def proc(pid, cwd=None, fd=None, cmd=None):
    d = os.path.join(P, pid); os.makedirs(os.path.join(d, "fd"), exist_ok=True)
    if cwd: os.symlink(cwd, os.path.join(d, "cwd"))
    if fd: os.symlink(fd, os.path.join(d, "fd", "5"))
    if cmd is not None: open(os.path.join(d, "cmdline"), "wb").write(cmd)
proc("4242", cwd=T + "/inuse-cwd/sub/deeper"); proc("4243", fd=T + "/inuse-fd/lock")
proc("4244", cmd=("bash\0-c\0cp a --out=" + T + "/inuse-argv/x\0").encode()); proc("4245", cwd=T + "/claude-1000/proj-inuse/work")
os.makedirs(os.path.join(P, "net")); os.symlink("socket:[1]", os.path.join(P, "4242", "fd", "9"))
open(os.path.join(P, "mounts"), "w").write("proc /proc proc rw 0 0\ntmpfs " + T + "/with-mount/sub tmpfs rw 0 0\n")   # um bind do MESMO disco: o st_dev não o vê
open(os.path.join(P, "net", "unix"), "w").write("Num       RefCount Protocol Flags    Type St Inode Path\n0000: 00000002 00000000 00010000 0001 01 7 @abstrato\n"
    "0000: 00000002 00000000 00010000 0001 01 8 " + T + "/inuse-sock/s\n0000: 00000003 00000000 00000000 0001 03 9\n")
PY

# cena <nome> [oldm]: cria $WORK/<nome>/{tmp,state,proc,out}; NOW0 é a hora da criação
scene() {
  W="$WORK/$1"; T="$W/tmp"; S="$W/state"; P="$W/proc"; OUT_DIR="$W/out"
  mkdir -p "$S" "$P" "$OUT_DIR" && mkdir -m 1777 "$T" && NOW0=$(date +%s) || { bad "cena $1"; return 1; }
  python3 -I "$WORK/fx.py" "$T" "$S" "$P" "$OUT_DIR" "$NOW0" "${2:-new}" || { bad "cena $1: fx.py"; return 1; }
}
AGE=0.0277778   # 100 s
# run <args...>: o reaper na cena atual → OUT (o JSON da stdout) e RC
run() { OUT=$(python3 -I "$REAPER" --root "$T" --state "$S" --proc "$P" --max-age-hours "$AGE" "$@" 2>"$WORK/err"); RC=$?; }
jget() { python3 -I -c 'import json,sys
d=json.loads(sys.argv[1])
for k in sys.argv[2].split("."):
    d=d.get(k) if isinstance(d,dict) else None
print("<none>" if d is None else json.dumps(d,sort_keys=True) if isinstance(d,(list,dict)) else d)' "$1" "$2" 2>/dev/null || echo "<json-ruim>"; }
FAKE=500

echo "=== 1. dry-run: julga tudo e não apaga nada"
scene s1 && run --dry-run --now $((NOW0 + FAKE))
chk "dry-run: rc" "$RC" 0; chk "dry-run: result" "$(jget "$OUT" result)" LIMPO; chk "dry-run: dry_run" "$(jget "$OUT" dry_run)" True
chk "unidades julgadas (14 de 1º nível + 3 filhos de claude-1000 + 2 de pytest-of-runner)" "$(jget "$OUT" scanned)" 19
chk "apagáveis (arquivo, árvore, link, modo 000, projeto velho, pytest velho)" "$(jget "$OUT" reapable)" 6; chk "apagados" "$(jget "$OUT" reaped)" 0
chk "mantidos: recente (a árvore decide, não a pasta)" "$(jget "$OUT" kept.recente)" 4
chk "mantidos: ilegivel (filho sem carimbo legível: frescura desconhecida, não é 'velho')" "$(jget "$OUT" kept.ilegivel)" 1
chk "mantidos: em-uso (cwd, fd, argv, socket, cwd em projeto)" "$(jget "$OUT" kept.em-uso)" 5
chk "mantidos: excecao (tmux-*, keep.txt)" "$(jget "$OUT" kept.excecao)" 2
chk "mantidos: montagem (ponto de montagem do mesmo disco dentro da unidade)" "$(jget "$OUT" kept.montagem)" 1
for x in old-file old-dir link-old mode000 claude-1000/proj-old pytest-of-runner/pytest-0; do kept "dry-run: $x" "$T/$x"; done
chk "dry-run não grava status" "$(have "$S/status.json" && echo gravou || echo nao)" nao

echo "=== 2. de verdade: apaga o velho, mantém o resto, não segue link"
run --now $((NOW0 + FAKE))
chk "rc" "$RC" 0; chk "result" "$(jget "$OUT" result)" LIMPO; chk "apagados" "$(jget "$OUT" reaped)" 6
chk "censo de quem vazou (sufixo vira *, filho de contêiner vira contêiner/*)" "$(jget "$OUT" top)" '[["claude-1000/*", 1], ["link-old", 1], ["mode000", 1], ["old-*", 1], ["old-dir", 1], ["pytest-of-runner/*", 1]]'
for x in old-file old-dir link-old mode000 claude-1000/proj-old pytest-of-runner/pytest-0; do gone "$x" "$T/$x"; done
for x in fresh-file fresh-deep inuse-cwd inuse-fd inuse-argv inuse-sock tmux-1000 custom-keep-dir with-mount/sub/f claude-1000 claude-1000/proj-fresh claude-1000/proj-inuse pytest-of-runner pytest-of-runner/pytest-1 no-search; do kept "$x" "$T/$x"; done
kept "alvo do link fora da raiz" "$OUT_DIR/precious/keep.txt"
chk "status.json = a saída" "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["epoch"])' "$S/status.json" 2>/dev/null)" "$(jget "$OUT" epoch)"
chk "uma linha no log" "$(wc -l < "$S/reaper.log" | tr -d ' ')" 1
run --now $((NOW0 + FAKE)); chk "2ª rodada: nada a apagar" "$(jget "$OUT" reaped)" 0; chk "2ª rodada: result" "$(jget "$OUT" result)" LIMPO

echo "=== 3. dono: o que não é meu nunca é tocado (dry-run, dono de mentira)"
scene s3 && TMP_REAPER_UID=1 run --dry-run --now $((NOW0 + FAKE))
chk "tudo alheio (14 + os 2 contêineres, que sem dono meu não se abrem)" "$(jget "$OUT" kept.alheio)" 16; chk "nada apagável" "$(jget "$OUT" reapable)" 0

echo "=== 4. ctime: mtime velho com ctime novo (tar -x, chmod) é recente"
scene s4 oldm && run --dry-run --now $((NOW0 + 30)); chk "nada apagável" "$(jget "$OUT" reapable)" 0

echo "=== 5. keep.txt: linha fora do alfabeto deixa o reaper inerte (a boa ao lado da ruim)"
n5=0
for badline in '../etc' 'dois nomes' '$(id)'; do
  n5=$((n5 + 1)); scene "s5-$n5" && printf 'custom-keep-*\n%s\n' "$badline" > "$S/keep.txt"; run --now $((NOW0 + FAKE))
  chk "linha [$badline]: rc" "$RC" 2; chk "linha [$badline]: motivo" "$(jget "$OUT" motivo)" keep; kept "linha [$badline]: nada apagado" "$T/old-file"
done

echo "=== 6. leitura que falha NÃO é 'nada a limpar'"
scene s6; run --proc "$W/nao-existe" --now $((NOW0 + FAKE))
chk "/proc ilegível: rc" "$RC" 2; chk "/proc ilegível: result" "$(jget "$OUT" result)" NAO-CONSEGUI; chk "/proc ilegível: motivo" "$(jget "$OUT" motivo)" proc; kept "/proc ilegível: nada apagado" "$T/old-file"
mkdir -p "$W/p2/net"; : > "$W/p2/net/unix"; run --proc "$W/p2" --now $((NOW0 + FAKE))
chk "/proc sem o mounts (bind do mesmo disco ficaria invisível): rc" "$RC" 2; chk "... motivo" "$(jget "$OUT" motivo)" proc; kept "... nada apagado" "$T/old-file"
mkdir -p "$W/p3"; : > "$W/p3/mounts"; run --proc "$W/p3" --now $((NOW0 + FAKE))
chk "/proc sem o net/unix (socket ligado ficaria invisível): rc" "$RC" 2; chk "... motivo" "$(jget "$OUT" motivo)" proc; kept "... nada apagado" "$T/old-file"
TMP_REAPER_FAKE_DF=fail run --now $((NOW0 + FAKE)); chk "df ilegível: rc" "$RC" 2; chk "df ilegível: motivo" "$(jget "$OUT" motivo)" df; kept "df ilegível: nada apagado" "$T/old-file"
chmod 1333 "$T"; run --now $((NOW0 + FAKE)); chk "varredura ilegível: rc" "$RC" 2; chk "varredura ilegível: motivo" "$(jget "$OUT" motivo)" scan; chmod 1777 "$T"
kept "varredura ilegível: nada apagado" "$T/old-file"
chmod 0755 "$T"; run --now $((NOW0 + FAKE)); chk "raiz sem sticky (não é um /tmp): rc" "$RC" 2; chk "raiz sem sticky: motivo" "$(jget "$OUT" motivo)" root; chmod 1777 "$T"
kept "raiz sem sticky: nada apagado" "$T/old-file"

echo "=== 7. alarme: disco > 90% ou inodes > 80% (estrito)"
for spec in "90,80:-" "90.1,80:disco" "90,80.1:inodes" "95,85:disco,inodes"; do
  TMP_REAPER_FAKE_DF="${spec%%:*}" run --dry-run --now $((NOW0 + FAKE)); want="${spec#*:}"
  got=$(python3 -I -c 'import json,sys; print(",".join(json.loads(sys.argv[1])["alerta"]) or "-")' "$OUT" 2>/dev/null)
  chk "df ${spec%%:*}: alerta" "$got" "$want"
done

echo "=== 8. teto de tempo: sem tempo não apaga e diz PARCIAL"
# cena só de ARQUIVOS velhos: o rm_tree (que tem o seu próprio teto) nunca entra, então só a checagem do laço principal pode parar a rodada, qualquer que seja a ordem do listdir
W="$WORK/s8"; T="$W/tmp"; S="$W/state"; P="$W/proc"; mkdir -p "$S" "$P/net" && mkdir -m 1777 "$T" && : > "$P/mounts" && : > "$P/net/unix" && NOW0=$(date +%s) || bad "cena s8"
for i in 1 2 3; do echo x > "$T/old-$i"; done
run --max-seconds 0 --now $((NOW0 + FAKE)); chk "result" "$(jget "$OUT" result)" PARCIAL; chk "rc" "$RC" 0; chk "apagados" "$(jget "$OUT" reaped)" 0
chk "nenhuma unidade nem chegou a ser julgada (só o laço principal para antes do lstat)" "$(jget "$OUT" scanned)" 0
for i in 1 2 3; do kept "old-$i" "$T/old-$i"; done
run --now $((NOW0 + FAKE)); chk "com tempo: result" "$(jget "$OUT" result)" LIMPO; chk "com tempo: apagados" "$(jget "$OUT" reaped)" 3

echo "=== 9. instância única: com o lock tomado, PULADO e nada apagado"
scene s9
OUT=$(python3 -I -c 'import fcntl,subprocess,sys
f = open(sys.argv[1], "a"); fcntl.flock(f, fcntl.LOCK_EX)
print(subprocess.run(sys.argv[2:], capture_output=True, text=True).stdout)' "$S/lock" python3 -I "$REAPER" --root "$T" --state "$S" --proc "$P" --max-age-hours "$AGE" --now $((NOW0 + FAKE)))
chk "result" "$(jget "$OUT" result)" PULADO; kept "nada apagado" "$T/old-file"

echo "=== 10. root recusa; falha ao gravar o status depois de apagar nunca é LIMPO"
scene s10; TMP_REAPER_PRETEND_ROOT=1 run --now $((NOW0 + FAKE)); chk "root: rc" "$RC" 64; kept "root: nada apagado" "$T/old-file"
chmod 0555 "$S"; run --now $((NOW0 + FAKE)); chmod 0755 "$S"
chk "status sem poder gravar: rc" "$RC" 2; chk "status sem poder gravar: motivo" "$(jget "$OUT" motivo)" escrever; chk "o que foi apagado foi apagado" "$(jget "$OUT" reaped)" 6
# idade ou teto que não é número finito: o nan passava por `<= 0`, e com ele todo carimbo é "mais velho que o corte" (apagaria até o fresco)
scene s10n
for badv in nan inf 0; do run --max-age-hours "$badv" --now $((NOW0 + FAKE)); chk "idade [$badv]: rc" "$RC" 64; kept "idade [$badv]: nada apagado" "$T/old-file"; done
run --max-seconds nan --now $((NOW0 + FAKE)); chk "teto [nan]: rc" "$RC" 64; kept "teto [nan]: nada apagado" "$T/old-file"
# o log persistente não pode dizer LIMPO de uma rodada cujo status não foi gravado (e o contrário: status gravado, log não)
scene s10l; : > "$S/reaper.log"; chmod 0555 "$S"; run --now $((NOW0 + FAKE)); chmod 0755 "$S"
chk "só o log grava: rc" "$RC" 2; chk "só o log grava: a linha diz NAO-CONSEGUI/escrever" "$(grep -c 'NAO-CONSEGUI/escrever' "$S/reaper.log")" 1; chk "só o log grava: nenhuma linha LIMPO" "$(grep -c ' LIMPO ' "$S/reaper.log")" 0
scene s10s; mkdir "$S/reaper.log"; run --now $((NOW0 + FAKE)); st10="$(cat "$S/status.json" 2>/dev/null)"
chk "só o status grava: rc" "$RC" 2; chk "só o status grava: o status.json diz NAO-CONSEGUI" "$(jget "$st10" result)" NAO-CONSEGUI; chk "só o status grava: motivo" "$(jget "$st10" motivo)" escrever

echo "=== 10b. crash: sai com 70 e deixa a linha CRASH no reaper.log (o stderr do cron é zerado a cada disparo)"
mkdir -p "$WORK/h/gt-remote/tmp-reaper"; TMP_REAPER_UID=abc HOME="$WORK/h" run --dry-run --now $((NOW0 + FAKE))
chk "rc" "$RC" 70; chk "linha CRASH no log" "$(grep -c ' CRASH ValueError' "$WORK/h/gt-remote/tmp-reaper/reaper.log" 2>/dev/null)" 1

echo "=== 11. log com teto: passou de 1 MB vira reaper.log.1"
scene s11
python3 -I -c 'open("'"$S"'/reaper.log","w").write("x" * 1100000)'; run --now $((NOW0 + FAKE))
chk "reaper.log.1" "$(have "$S/reaper.log.1" && echo sim || echo nao)" sim; chk "reaper.log recomeçou (1 linha)" "$(wc -l < "$S/reaper.log" | tr -d ' ')" 1

echo "=== 12. /proc real (Linux): cwd de processo vivo e socket ligado protegem"
if [ -r /proc/self/cwd ] && [ -r /proc/net/unix ]; then
  scene s12; mkdir -p "$T/real-cwd" "$T/real-sock"
  ( cd "$T/real-cwd" && exec sleep 120 ) & CWDPID=$!; PIDS="$PIDS $CWDPID"
  python3 -I -c 'import socket,sys,time
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); time.sleep(120)' "$T/real-sock/s" & PIDS="$PIDS $!"
  i=0; while [ "$i" -lt 60 ]; do have "$T/real-sock/s" && [ "$(readlink "/proc/$CWDPID/cwd")" = "$(cd "$T/real-cwd" && pwd -P)" ] && break; sleep 0.3; i=$((i + 1)); done   # espera os dois de pé (até 18 s: o nó roda a load 14, o mini a 50)
  python3 -I "$REAPER" --root "$T" --state "$S" --max-age-hours "$AGE" --now $((NOW0 + FAKE)) > "$WORK/out12" 2>&1
  kept "cwd de processo vivo" "$T/real-cwd"; kept "socket unix ligado" "$T/real-sock"; gone "o velho sem uso saiu" "$T/old-file"
else echo "  ~ SKIP: sem /proc"; SKIP=$((SKIP+1)); fi

echo "=== 13. por dentro: identidade conferida antes de apagar (mudou) e ERROS quando algo não apaga (não dá para provocar como usuário comum)"
cat > "$WORK/unit.py" << 'PY'
import contextlib, importlib.util, io, json, os, sys, time
spec = importlib.util.spec_from_file_location("reaper", sys.argv[1]); r = importlib.util.module_from_spec(spec); spec.loader.exec_module(r)
w = sys.argv[2]
def say(good, what): print(("OK " if good else "BAD ") + what)
p = os.path.join(w, "ident"); open(p, "w").write("1"); st = os.lstat(p)
open(p, "w").write("2"); os.utime(p, (st.st_atime, st.st_mtime + 5))   # mesmo inode, carimbo outro: mudou depois do julgamento
say(r.reap(p, st, st.st_dev, os.geteuid(), time.monotonic() + 9) == (0, 0, "mudou") and os.path.exists(p), "reap: carimbo diferente do julgamento = mudou, não apaga")
def mk(name):
    d = os.path.join(w, name); os.makedirs(os.path.join(d, "sub"))
    for i in range(10): open(os.path.join(d, "f%d" % i), "w").write("x")
    open(os.path.join(d, "sub", "g"), "w").write("x")
    return d
real_unlink = os.unlink
def first_unlink_fails(exc, really):   # a 1ª chamada falha como `exc`; `really` = a entrada sumiu mesmo (outro apagador a levou entre o scandir e o unlink)
    hit = []
    def f(path, *a, **k):
        if not hit:
            hit.append(path)
            if really: real_unlink(path)
            raise exc(path)
        return real_unlink(path, *a, **k)
    return f, hit
d = mk("vanish"); os.unlink, hit = first_unlink_fails(lambda p: FileNotFoundError(2, "sumiu", p), True)
try: st = os.lstat(d); res = r.reap(d, st, st.st_dev, os.geteuid(), time.monotonic() + 9)
finally: os.unlink = real_unlink
say(len(hit) == 1 and not os.path.exists(d) and res[1] == 0, "entrada que some entre o scandir e o unlink: a unidade sai inteira (pasta incluída) e não é erro [%r]" % (res,))
d = mk("noperm"); os.unlink, hit = first_unlink_fails(lambda p: PermissionError(13, "nega", p), False)
try: st = os.lstat(d); res = r.reap(d, st, st.st_dev, os.geteuid(), time.monotonic() + 9)
finally: os.unlink = real_unlink
say(len(hit) == 1 and res[1] >= 1 and os.path.isdir(d) and sorted(os.listdir(d)) == [os.path.basename(hit[0])], "unlink que falha: conta erro e segue com as irmãs (só a que falhou sobra) [%r]" % (res,))
big = os.path.join(w, "big"); os.mkdir(big)
for i in range(4100): open(os.path.join(big, "f%d" % i), "w").close()
class Clock:   # 1ª leitura dentro do prazo, as seguintes estouradas: o teto cai no meio da pasta, depois de 4096 unlinks
    k = 0
    def monotonic(self): self.k += 1; return 0 if self.k == 1 else 10
real_time = r.time; r.time = Clock()
try: r.rm_tree(big, os.lstat(big).st_dev, os.geteuid(), 5); got = "sem Budget"
except r.Budget as e: got = e.args[0] if e.args else None
finally: r.time = real_time
say(got == 4096, "teto no meio da pasta: o Budget leva quantas entradas já saíram [%r]" % (got,))
mp = os.path.join(w, "mproc"); os.makedirs(mp); open(os.path.join(mp, "mounts"), "w").write("tmpfs /tmp/x\\040y\\011z\\134w tmpfs rw 0 0\nproc /proc proc rw 0 0\n")
say(r.read_mounts(mp, "/tmp") == ["/tmp/x y\tz\\w"], "read_mounts: \\040, \\011 e \\134 do /proc/mounts viram espaço, tab e barra [%r]" % (r.read_mounts(mp, "/tmp"),))
root = os.path.join(w, "errroot"); os.makedirs(os.path.join(w, "errproc", "net")); open(os.path.join(w, "errproc", "net", "unix"), "w").write("h\n"); open(os.path.join(w, "errproc", "mounts"), "w").write("")
os.mkdir(root); os.chmod(root, 0o1777); open(os.path.join(root, "a"), "w").write("x")
r.reap = lambda *a, **k: (0, 1, None)
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    rc = r.main(["--root", root, "--state", os.path.join(w, "errstate"), "--proc", os.path.join(w, "errproc"), "--max-age-hours", "0.0001", "--now", str(time.time() + 9999)])
d = json.loads(buf.getvalue())
say(rc == 1 and d["result"] == "ERROS" and d["falhou"] == ["a"] and d["reaped"] == 0, "uma unidade que não apaga: ERROS, rc 1, o nome em falhou, reaped 0")
root2 = os.path.join(w, "partroot"); os.mkdir(root2); os.chmod(root2, 0o1777)
for n in ("a", "b"): open(os.path.join(root2, n), "w").write("x")
calls = []
def fake_reap(*a, **k):   # a 1ª unidade (qualquer que seja) não apaga; a 2ª estoura o teto depois de apagar 3 entradas
    calls.append(a[0])
    if len(calls) == 1: return (0, 1, None)
    raise r.Budget(3)
r.reap = fake_reap
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    rc = r.main(["--root", root2, "--state", os.path.join(w, "partstate"), "--proc", os.path.join(w, "errproc"), "--max-age-hours", "0.0001", "--now", str(time.time() + 9999)])
d = json.loads(buf.getvalue()); log = open(os.path.join(w, "partstate", "reaper.log")).read()
say(rc == 0 and d["result"] == "PARCIAL" and d["errors"] == 1 and d["inodes_apagados"] == 3, "teto no meio de uma unidade: PARCIAL, o erro e as entradas que ela já apagou continuam contados [%r]" % ((rc, d["result"], d["errors"], d["inodes_apagados"]),))
say(" PARCIAL " in log and "erros=1" in log, "o reaper.log traz erros=N: PARCIAL com erro não some [%s]" % log.strip())
PY
UNIT=$(python3 -I "$WORK/unit.py" "$REAPER" "$WORK" 2>&1)
while IFS= read -r line; do case "$line" in "OK "*) ok "${line#OK }" ;; *) bad "$line" ;; esac; done <<< "$UNIT"

echo "=== 14. mutantes do reaper: cada um tem de fazer ESTE arquivo reprovar"
if [ "${TR_SKIP_MUTANTS:-0}" = 1 ]; then echo "  ~ SKIP: TR_SKIP_MUTANTS=1"; SKIP=$((SKIP+1)); else
child() { TMP_REAPER_UNDER_TEST="$1" TR_SKIP_MUTANTS=1 bash "$SELF" > "$2" 2>&1 < /dev/null; }
cp "$REAPER" "$WORK/mut-ctl.py"
if child "$WORK/mut-ctl.py" "$WORK/mut-ctl.out"; then ok "controle: o reaper intacto passa pela mesma máquina"; else bad "controle: o reaper intacto REPROVOU (as mortes abaixo não valem)"; fi
while IFS= read -r line; do   # id@@trecho exato (1 vez no reaper)@@troca
  id="${line%%@@*}"; rest="${line#*@@}"; old="${rest%%@@*}"; new="${rest#*@@}"
  if ! python3 -I - "$REAPER" "$WORK/mut-$id.py" "$old" "$new" << 'PY'
import sys
src, dst, old, new = sys.argv[1:5]
t = open(src).read()
if t.count(old) != 1: sys.exit("ancora %r: %d ocorrencias" % (old, t.count(old)))
open(dst, "w").write(t.replace(old, new))
PY
  then bad "mutante $id: âncora"; continue; fi
  if child "$WORK/mut-$id.py" "$WORK/mut-$id.out"; then bad "mutante $id SOBREVIVEU"
  elif grep -q '^RESULT: FAIL (' "$WORK/mut-$id.out"; then ok "mutante $id morreu"; else bad "mutante $id quebrou o arquivo sem RESULT (morte à toa)"; fi
done << 'EOF'
own@@if st.st_uid != me:@@if False:
desc@@stack, n = ([top] if stat.S_ISDIR(st0.st_mode) else []), 0@@stack, n = [], 0
ctime@@return max(s.st_mtime, s.st_ctime) > cut@@return s.st_mtime > cut
keep@@elif any(fnmatch.fnmatchcase(os.path.basename(path), p) for p in pats):@@elif False:
uso-cwd@@links = [os.path.join(base, "cwd"), os.path.join(base, "exe")]@@links = [os.path.join(base, "exe")]
uso-fd@@links += [os.path.join(base, "fd", n) for n in os.listdir(os.path.join(base, "fd"))]@@links += []
uso-argv@@paths += ([tok] if tok.startswith(root + "/") else []) + pat.findall(tok)@@pass
uso-sock@@paths.append(cols[7].strip())@@pass
conteiner@@if stat.S_ISDIR(cs.st_mode) and cs.st_uid == me and not any(@@if False and cs.st_uid == me and not any(
conteiner-dono@@cs.st_uid == me and not any(@@True and not any(
df-falha@@raise Inert("df", "TMP_REAPER_FAKE_DF=%s" % fake)@@return 0.0, 0.0
scan-falha@@raise Inert("scan", "%s: %s" % (root, e))@@names = []
proc-falha@@raise Inert("proc", "%s: %s" % (proc, e))@@return set()
keep-ruim@@if ln and not NAME_OK.fullmatch(ln):@@if False:
dry@@elif a.dry_run:@@elif False:
tempo@@if time.monotonic() >= deadline:@@if False:
limiar@@v is not None and v > lim@@v is not None and v >= lim
link-dentro@@if e.is_dir(follow_symlinks=False):@@if e.is_dir():
mudou@@(st.st_dev, st.st_ino, st.st_mtime_ns, st.st_ctime_ns):@@(st.st_dev, st.st_ino, s2.st_mtime_ns, s2.st_ctime_ns):
lock@@fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)@@pass
log-teto@@os.path.getsize(log) > LOG_MAX@@os.path.getsize(log) > LOG_MAX * 1000
escrever@@err = str(e)@@err = None
erros@@if res["result"] == "LIMPO" and res["errors"]:@@if False:
root-recusa@@os.environ.get("TMP_REAPER_PRETEND_ROOT") or @@
censo@@return head + "/*"@@return rel
crash-sem-log@@with open(os.path.expanduser("~/gt-remote/tmp-reaper/reaper.log"), "a") as f:@@with open(os.devnull, "a") as f:
montagem-bind@@st.st_dev != rs.st_dev or any(m == path or m.startswith(path + "/") for m in mounts)@@st.st_dev != rs.st_dev
mounts-falha@@raise Inert("proc", "%s/mounts: %s" % (proc, e))@@return []
mounts-escape@@chr(int(m.group(1), 8))@@" "
conteiner-pytest@@CONTAINERS = ("claude-[0-9]*", "pytest-of-*")@@CONTAINERS = ("claude-[0-9]*",)
unlink-sumiu@@except FileNotFoundError: pass@@except FileNotFoundError: raise
unlink-erro@@except OSError: bad += 1@@except OSError: raise
sem-busca@@except OSError: return "ilegivel"@@except OSError: continue
nan@@not (0 < a.max_age_hours < math.inf) or not (0 <= a.max_seconds < math.inf)@@a.max_age_hours <= 0
teto-nan@@ or not (0 <= a.max_seconds < math.inf)@@
budget-conta@@res["inodes_apagados"] += e.args[0] if e.args and isinstance(e.args[0], int) else 0@@pass
escrever-log@@flipped = dict(res, result="NAO-CONSEGUI", motivo="escrever", detalhe=err)@@flipped = res
EOF
fi

echo
if [ "$FAIL" -eq 0 ]; then echo "RESULT: PASS ($PASS passed, $SKIP skipped)"; else echo "RESULT: FAIL ($FAIL failed, $PASS passed, $SKIP skipped)"; fi
[ "$FAIL" -eq 0 ]
