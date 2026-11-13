#!/bin/bash
# disk-recovery-e2e.selftest.sh — prova PONTA A PONTA da escada de recuperação de disco do mini (ga-1p1i5jr.5, parte (a) do D5). Nunca toca na máquina.
#
# ## Contents
#   O que prova · O que NÃO prova · O mundo simulado · Segurança · Como rodar
#
# O QUE PROVA   Os selftests de cada peça (maestro .1, D2, D3, D4) trocam os vizinhos por stubs. Aqui NENHUM script da escada é trocado: o maestro REAL chama o D2, o D3 e o D4 REAIS, do jeito que o plist manda
#   (`/bin/bash disk-recovery-ladder.sh --run`, env mínimo, a cada 120 s), contra UM mundo simulado onde o df, o swap e os processos são os mesmos para os quatro. O que só aparece na composição: contrato de saída
#   (rc + UMA linha) de cada degrau lido pelo maestro de verdade, o efeito de cada degrau na re-medição do maestro, a ordem D2 → D3 → D4 e os cronômetros com os limiares de produção, o reinício que mata o próprio maestro
#   (a marca do D4 já está no disco), o teto de 6 h e a escalada, a guarda de ligação que segura o D4 e o D3 com o MESMO banco, e o relatório (disk-recovery-report.py) lendo o log que o maestro real escreveu.
# O QUE NÃO PROVA   (1) o reinício de verdade: o AppleEvent do osascript sob o launchd (o D4 diz que só o canário real mostra) e o boot que volta sozinho; (2) o job carregado e vivo no launchd (`launchctl print`) e o que ele
#   escreveu em 24 h (isso é o canário (b) e o relatório (c): scripts/disk-recovery-report.py lê o log real); (3) o `--resume` do D2 (ga-1p1i5jr.6: hoje o maestro não o chama) e o Safari/bw-serve do D3 (ga-1p1i5jr.7: o `ps`
#   simulado não lista Safari e o bw-serve não está carregado); (4) rodadas de 120 s só no cenário S-A: os outros usam 300 s (o maestro tolera até 600 s entre leituras e trata o launchd atrasado, mas com 300 s = RETRY_S
#   o degrau de cima repete a cada rodada e o D2 deixa de ser chamado enquanto ele repetir, de propósito: repetição vai do mais alto ao mais baixo); (5) a guarda de envio em voo REAL do D4 (central_sender_restart_safe.py, do repo do WhatsApp: aqui o DR4_SENDER_SAFE_PY é um stub que diz "pode reiniciar"; quem a exercita é o canário). Achado de passagem: o `out_line` do maestro apaga os bytes acentuados da linha do degrau ("não está" vira "no est" no log e no mail).
# O MUNDO       df, sysctl, launchctl, ps, footprint, curl são shims no PATH que leem o ESTADO DO MUNDO na hora da chamada (o sqlite3 só impõe a regra do mini: `-readonly` não abre banco WAL sem -wal/-shm, o estado dos bancos de ligação): livre = base − (rfb vivo) − (footprint dos daemons). Quem para o rfb de brinquedo
#   (processo de verdade, morto por TERM pelo D2) ou reinicia um daemon (kickstart do shim) faz o livre subir na re-medição seguinte; o "vazamento" desce a base a cada rodada. O reinício simulado MATA o D4 e o
#   maestro (como o shutdown mata a árvore), e o teste "faz o boot": base saudável, daemons novos, hora de boot nova.
# SEGURANÇA     nada real é parado, reiniciado ou enviado: os binários do D4 são shims, DR4_NO_REAL_REBOOT=1 vale em todo cenário, `reboot`/`shutdown`/`sudo` e `df /` são armadilhas que gravam em $W/forbidden (o teste
#   falha se algo cair nelas). O único processo real que morre é o rfb de brinquedo deste teste: o D2 só ENXERGA os processos dele (ps filtrado pelo diretório de trabalho), então o rfb de PRODUÇÃO nunca é visto nem tocado
#   se estiver rodando na máquina do teste, e várias execuções em paralelo não se enxergam.
# COMO RODAR    bash scripts/disk-recovery-e2e.selftest.sh        (~80 s no nó Linux, bash 5.2 e 3.2.57, a partir de um worktree; o mbp-run.sh NÃO o leva ao nó: está em hetzner-mac-only.hq.txt, pois usa o disk-recovery-d2-allowlist.tsv, que o filtro do nó não carrega, e o macOS é a prova que vale). ST_FAILFAST=1 sai no 1º FAIL; E2E_KEEP=1 mantém o diretório de trabalho (logs, estado, rastro). Cópias modificadas (mutantes): E2E_LADDER / E2E_D2 / E2E_D3 / E2E_D4 / E2E_REPORT=/caminho/...
#   (o arquivo da cópia TEM de manter disk-recovery-ladder / disk-recovery-d2 no nome: as travas de instância única conferem a linha de comando). E2E_BASH=/caminho/bash roda o maestro com outro bash (o plist usa /bin/bash).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LADDER="${E2E_LADDER:-$HERE/disk-recovery-ladder.sh}"; RUNG2="${E2E_D2:-$HERE/disk-recovery-d2-heavy-jobs.sh}"
RUNG3="${E2E_D3:-$HERE/disk-recovery-d3-ram-daemons.sh}"; RUNG4="${E2E_D4:-$HERE/disk-recovery-d4-guarded-reboot.sh}"
REPORT="${E2E_REPORT:-$HERE/disk-recovery-report.py}"; RBASH="${E2E_BASH:-/bin/bash}"
for _f in "$LADDER" "$RUNG2" "$RUNG3" "$RUNG4" "$REPORT"; do [ -f "$_f" ] || { echo "FATAL: $_f não existe"; exit 1; }; done
OVR=(); [ -z "${E2E_D2:-}" ] || OVR+=("DR_D2_CMD=$RUNG2"); [ -z "${E2E_D3:-}" ] || OVR+=("DR_D3_CMD=$RUNG3"); [ -z "${E2E_D4:-}" ] || OVR+=("DR_D4_CMD=$RUNG4")   # sem E2E_Dn o maestro usa o caminho PADRÃO do degrau, como em produção
for _v in $(compgen -e | grep -E '^(DR_|DR4_|D2_|SCRAPER_)'); do unset "$_v"; done   # nada do ambiente de quem chamou vaza para dentro dos cenários

W="$(mktemp -d "${TMPDIR:-/tmp}/dr-e2e.XXXXXX")" || { echo "FATAL: mktemp"; exit 1; }
case "$W" in */dr-e2e.??????) ;; *) echo "FATAL: diretório de trabalho estranho: $W"; exit 1 ;; esac
BG=""
cleanup() { local p; for p in $BG; do kill "$p" 2>/dev/null; done; if [ "${E2E_KEEP:-0}" = 1 ]; then echo "E2E_KEEP=1: mantive $W"; return 0; fi; chmod -R u+rwx "$W" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
BIN="$W/bin"; WD="$W/world"; CITY="$W/city"; SD="$W/sd"
STATE="$CITY/.gc/disk-recovery.state"; LOG="$CITY/.gc/logs/disk-recovery.log"; OFF="$CITY/.gc/disk-recovery.off"
mkdir -p "$BIN"
PASS=0; FAIL=0; OUT=""; RC=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
nope() {
  FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; [ -n "${OUT:-}" ] && printf '%s\n' "$OUT" | sed 's/^/        | /' | tail -n 8
  if [ "${ST_FAILFAST:-0}" = 1 ]; then printf '\n(ST_FAILFAST) parei no 1º FAIL: %s passaram, %s falharam\n' "$PASS" "$FAIL"; exit 1; fi
  return 0
}
eq()    { if [ "$1" = "$2" ]; then ok "$3"; else nope "$3 (obtido '$1', esperado '$2')"; fi; }
has()   { case "$1" in *"$2"*) ok "$3" ;; *) nope "$3 (faltou: $2)" ;; esac; }
hasnt() { case "$1" in *"$2"*) nope "$3 (não devia ter: $2)" ;; *) ok "$3" ;; esac; }
section() { printf '\n== %s\n' "$1"; }
cnt() { local n; n=$(grep -c -F -- "$2" "$1" 2>/dev/null); echo "${n:-0}"; }   # linhas de um arquivo com o texto fixo ($1=arquivo $2=texto)

# ── shims do mundo simulado (PATH) ──────────────────────────────────────────────────────────────────────────────────────────────────
cat > "$BIN/df" <<'SH'
#!/bin/bash
# df do mundo: o livre do volume Data = base − o que cada consumidor VIVO usa, calculado na hora (o efeito de um degrau aparece na re-medição). `df /` é armadilha.
WD=$E2E_W/world; last=""; for a in "$@"; do last=$a; done
if [ "$last" != /System/Volumes/Data ]; then echo "df $*" >> "$E2E_W/forbidden"; printf 'Filesystem 1048576-blocks Used Available Capacity Mounted on\n/dev/disk3s1s1 471000 12000 190000 8%% /\n'; exit 0; fi
free=$(cat "$WD/base")
if [ -s "$WD/rfb.pid" ] && kill -0 "$(cat "$WD/rfb.pid")" 2>/dev/null; then free=$((free - $(cat "$WD/rfb.mb"))); fi
free=$((free - $(awk '{s += $4} END {print s + 0}' "$WD/procs"))); [ "$free" -ge 0 ] || free=0
case " $* " in *" -Pm "*) u=1048576; v=$free ;; *) u=1024; v=$((free * 1024)) ;; esac
printf 'Filesystem %s-blocks Used Available Capacity Mounted on\n/dev/disk3s5 471000 466700 %s 99%% /System/Volumes/Data\n' "$u" "$v"
SH
cat > "$BIN/sysctl" <<'SH'
#!/bin/bash
# swap = o que falta para 9000 MB de livre (só texto das mensagens); kern.boottime = a hora do boot do mundo
case "$*" in
  "-n vm.swapusage") f=$("$E2E_W/bin/df" -Pm /System/Volumes/Data | awk 'NR==2 {print $4}'); s=$((9000 - f)); [ "$s" -ge 0 ] || s=0; [ "$s" -le 6144 ] || s=6144
                     echo "total = 6144.00M  used = ${s}.00M  free = $((6144 - s)).00M  (encrypted)" ;;
  "-n kern.boottime") echo "{ sec = $(cat "$E2E_W/world/boot"), usec = 0 } Mon Nov  3 00:00:00 2026" ;;
  *) echo "sysctl $*" >> "$E2E_W/forbidden"; exit 1 ;;
esac
SH
cat > "$BIN/date" <<'SH'
#!/bin/bash
# date do mundo (-r é a forma do BSD/macOS, -d @N a do GNU: o `date -d` do macOS mexe no DST do kernel, por isso a ordem): só os carimbos de LOG (`+%F %T` do maestro e do D3, `+%Y-%m-%d %H:%M:%S` do D4) saem na hora SIMULADA, para o relatório ler horas de verdade; o resto (+%s, os laços de espera do D3, -r) é o date de verdade
case "$*" in
  "+%F %T"|"+%Y-%m-%d %H:%M:%S") n=$(cat "$E2E_W/now" 2>/dev/null)
    case "$n" in ''|*[!0-9]*) ;; *) /bin/date -r "$n" "$@" 2>/dev/null || /bin/date -d "@$n" "$@"; exit ;; esac ;;
esac
exec /bin/date "$@"
SH
cat > "$BIN/launchctl" <<'SH'
#!/bin/bash
S=$E2E_W/world
case "${1:-}" in
  list) printf 'PID\tStatus\tLabel\n'; awk '{printf "%s\t0\t%s\n", $2, $1}' "$S/procs" ;;
  kickstart) shift; [ "${1:-}" = -k ] && shift; label=${1##*/}; n=$(( $(cat "$S/counter") + 1 )); echo "$n" > "$S/counter"
             awk -v l="$label" -v n="$n" '$1 == l { $2 = n; $3 = "00:01"; $4 = 80 } { print }' "$S/procs" > "$S/procs.new" && mv "$S/procs.new" "$S/procs"
             echo "kickstart $label" >> "$E2E_W/launchctl.log" ;;
  *) echo "launchctl $*" >> "$E2E_W/forbidden"; exit 1 ;;
esac
SH
cat > "$BIN/ps" <<'SH'
#!/bin/bash
# só as duas formas que o D3 usa nos daemons simulados; o resto é o ps de verdade
S=$E2E_W/world
if [ "${1:-}" = -o ] && [ "${2:-}" = etime= ] && [ "${3:-}" = -p ]; then
  t=$(awk -v p="$4" '$2 == p {print $3; f = 1} END {exit f ? 0 : 1}' "$S/procs") && { echo "  $t"; exit 0; }
fi
[ "${1:-}" = -axo ] && [ "${2:-}" = "pid=,etime=,comm=" ] && { echo "    1 5-00:00:00 /sbin/launchd"; exit 0; }
exec /bin/ps "$@"
SH
cat > "$BIN/ps-d2" <<'SH'
#!/bin/bash
# o `ps` que o D2 enxerga: SÓ os processos do rfb de brinquedo DESTA execução (o diretório de trabalho está na linha de comando deles) + uma linha de outro usuário (o D2 trata saída vazia como ps ilegível).
# Sem o filtro o D2 casaria o rfb de PRODUÇÃO, se estivesse rodando na máquina que roda o teste, e o mataria; e vários testes em paralelo se casariam entre si (a regex larga demais vira rc 30)
echo "    1     0     0 5-00:00:00 /sbin/launchd"
/bin/ps "$@" 2>/dev/null | grep -F -- "$E2E_W/rfb/"
exit 0
SH
cat > "$BIN/sqlite3" <<'SH'
#!/bin/bash
# sqlite3 do mini (3.51): `-readonly` num banco WAL SEM -wal/-shm não abre ("unable to open database file", rc 14; medido no mini pelo revisor do gate em 03/11 e pelo D4 em 01/11, 34 de 40 leituras). O 3.45 do Linux abre: o shim impõe a regra do mini para o e2e valer igual nos dois; o resto vai ao sqlite3 de verdade
ro=0; for a in "$@"; do [ "$a" = -readonly ] && ro=1; done
if [ "$ro" = 1 ]; then for a in "$@"; do
  { [ -f "$a" ] && [ ! -e "$a-wal" ] && [ ! -e "$a-shm" ] && [ "$(head -c 20 "$a" | tail -c 2 | od -An -tx1 | tr -d ' \n')" = 0202 ]; } && { echo "Error: in prepare, unable to open database file (14)" >&2; exit 14; }
done; fi
PATH="${PATH#"${0%/*}":}" exec sqlite3 "$@"
SH
cat > "$BIN/footprint" <<'SH'
#!/bin/bash
fp=$(awk -v p="$2" '$2 == p {print $4; f = 1} END {exit f ? 0 : 1}' "$E2E_W/world/procs") || exit 1
printf 'x [%s]: 64-bit    Footprint: %s MB\n\n    phys_footprint: %s MB\n' "$2" "$fp" "$fp"
SH
cat > "$BIN/curl" <<'SH'
#!/bin/bash
fmt=""; url=""
while [ $# -gt 0 ]; do case "$1" in -w) fmt=$2; shift ;; -m|-o|-X|-H|-d) shift ;; -*) ;; *) url=$1 ;; esac; shift; done
body=""; case "$url" in */api/outreach/config) body='{"system_paused":"0","system_paused_by":""}' ;; esac
case "$fmt" in *'\n%{http_code}'*) printf '%s\n200' "$body" ;; *'%{http_code}'*) printf '200' ;; *) printf '%s' "$body" ;; esac
SH
cat > "$BIN/guarded" <<'SH'
#!/bin/bash
"$E2E_W/bin/launchctl" kickstart -k "gui/$(id -u)/com.whatsapp.demand-dashboard"; echo "VEREDITO: ok"
SH
cat > "$BIN/freeze" <<'SH'
#!/bin/bash
exit 10
SH
cat > "$BIN/aws" <<'SH'
#!/bin/bash
# `aws s3 ls` do run_id do rfb: uma chave stream-run-<epoch>-<pid> do processo que o D2 acabou de parar (pid do rfb de brinquedo, hora = a do D2)
echo "2026-11-03 20:00:00 100 stream-run-$((${D2_NOW:-0} - 1))-$(cat "$E2E_W/world/rfb.pid" 2>/dev/null).tabela.json"
SH
cat > "$BIN/notify" <<'SH'
#!/bin/bash
p=""; t=""; while [ $# -gt 1 ]; do case "$1" in -p) p=$2; shift 2 ;; -t) t=$2; shift 2 ;; *) shift ;; esac; done
echo "p=$p force=${NOTIFY_FORCE_PUSH:-} t=$t" >> "$E2E_W/sd/notify.log"
SH
cat > "$BIN/gc" <<'SH'
#!/bin/bash
s=""; while [ $# -gt 0 ]; do [ "$1" = -s ] && { s=$2; break; }; shift; done; echo "subj=$s" >> "$E2E_W/sd/mail.log"
SH
cat > "$BIN/reboot-stub" <<'SH'
#!/bin/bash
# o desligamento simulado: anota o pedido (com a marca do maestro JÁ no disco) e "o mini cai" — mata o D4 que me chamou e o maestro que chamou o D4, como o shutdown mata a árvore
echo "reboot" >> "$E2E_W/reboot.calls"; cp "$E2E_W/city/.gc/disk-recovery.state" "$E2E_W/state.at-reboot" 2>/dev/null; cp "$E2E_W/sd/notify.log" "$E2E_W/notify.at-reboot" 2>/dev/null
d4=$(cat "$E2E_W/city/.gc/disk-recovery-d4.state.lock.d/pid" 2>/dev/null); m=$(/bin/ps -o ppid= -p "$d4" 2>/dev/null | tr -d ' ')
case "$d4" in ''|*[!0-9]*) exit 1 ;; esac
case "$m" in ''|*[!0-9]*) ;; *) kill -TERM "$m" 2>/dev/null ;; esac
kill -TERM "$d4" 2>/dev/null; sleep 2
SH
for n in fdesetup defaults pgrep osascript launchctl-d4; do printf '#!/bin/bash\n' > "$BIN/$n"; done
echo 'echo "FileVault is Off."' >> "$BIN/fdesetup"; echo 'echo athos' >> "$BIN/defaults"; echo 'exit 1' >> "$BIN/pgrep"
echo 'echo "gui/501/x = { state = not running }"' >> "$BIN/launchctl-d4"
printf '#!/bin/bash\necho "D3.5 (stub do e2e): nada a cortar"\nexit 10\n' > "$BIN/d35-idle"   # o D3.5 (ga-1p1i5jr.8) tem selftest próprio: aqui ele é ocioso, porque o real leria o df e o launchctl DE VERDADE do mini (nunca toca na máquina)
for n in reboot shutdown sudo top secret; do printf '#!/bin/bash\necho "%s $*" >> "$E2E_W/forbidden"; exit 1\n' "$n" > "$BIN/$n"; done
printf 'import sys\nsys.stdout.write("central_sender_restart_safe: fila sem envio em voo — pode reiniciar\\n")\n' > "$W/sender_stub.py"
chmod 755 "$BIN"/*
[ "$RBASH" = /bin/bash ] || for _s in "$BIN"/*; do sed "1s|.*|#!$RBASH|" "$_s" > "$_s.new" && mv "$_s.new" "$_s" && chmod 755 "$_s"; done   # os shims rodam no MESMO bash que o plist manda (o teste sob o bash 3.2 do mini)
cat > "$W/mkdb.py" <<'PY'
import os, sqlite3, sys
# mkdb.py <pix.db> <vb.db> [pix|vb estado minutos-atrás]: recria os dois bancos de ligação (WAL, como os de produção) e, se pedido, grava UMA ligação em curso
pix, vb, extra = sys.argv[1], sys.argv[2], sys.argv[3:]
DDL = {pix: ("pix_call_log", "state", "id INTEGER PRIMARY KEY, call_id TEXT, state TEXT, started_at TEXT, ended_at TEXT, updated_at TEXT"),
       vb: ("voicebot_call_log", "status", "id INTEGER PRIMARY KEY, call_id TEXT, status TEXT, started_at TEXT, updated_at TEXT")}
for path, (table, col, cols) in DDL.items():
    con = sqlite3.connect(path); con.execute("PRAGMA journal_mode=WAL")
    con.execute("CREATE TABLE IF NOT EXISTS %s (%s)" % (table, cols)); con.execute("DELETE FROM %s" % table)
    if extra and path == (pix if extra[0] == "pix" else vb):
        con.execute("INSERT INTO %s (call_id, %s, started_at) VALUES ('c1', ?, datetime('now','localtime','-%d minutes'))" % (table, col, int(extra[2])), (extra[1],))
    con.commit(); con.close()
    for ext in ("-wal", "-shm"):   # o banco de produção é WAL SEM -wal/-shm (os apps abrem e fecham a cada operação): é esse estado que os leitores do D3 (sqlite3) e do D4 (python) têm de saber abrir
        try: os.remove(path + ext)
        except OSError: pass
PY
cat > "$W/jget.py" <<'PY'
import json, re, sys
# jget.py <caminho> ...  (JSON no stdin): caminho pontilhado `a.b`, `lista[]` (todos os itens) ou `lista[N]`; imprime os valores de cada caminho (itens separados por vírgula), um caminho por palavra
d = json.load(sys.stdin)
res = []
for path in sys.argv[1:]:
    cur = [d]
    for part in path.split("."):
        key, idx = re.match(r"^(\w+)(?:\[(\d*)\])?$", part).groups()
        vals = [c[key] for c in cur]
        cur = vals if idx is None else [x for v in vals for x in (v if idx == "" else [v[int(idx)]])]
    res.append(",".join(str(x) for x in cur))
print(" ".join(res))
PY

# ── o mundo ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
T0=1800000000; STEP=120      # hora simulada inicial; o plist roda o maestro a cada 120 s
export E2E_W="$W"            # os shims leem o estado do mundo daqui
NOW_S=$T0; LEAK=0            # LEAK = MB por minuto que a base perde (memória virando swap)
FB=""; FA=""; CALLED=""; OUTCOME=""; NEWLOG=""; T_D2=""; T_D3=""; T_D4=""; SEEN_IDLE=" "
free_now() { "$BIN/df" -Pm /System/Volumes/Data | awk 'NR==2 {print $4}'; }
procs_boot() { printf '%s\n' "com.whatsapp.demand-dashboard 5001 00:03 90" "com.whatsapp.map-viewer 5002 00:03 60" "com.whatsapp.ficha360 5003 00:03 40" "com.whatsapp.clientes-dashboard 5004 00:03 30" > "$WD/procs"; }
rfb_start() {  # $1=diretório, $2=arquivo do pid do filho. O job do rfb de brinquedo: pai `job_timeout.sh 21600 com.whatsapp.rfb-monthly-refresh` e filho `python3 .../scripts/rfb_monthly_refresh.py`, as linhas de comando que a allowlist do D2 casa
  local par kid="" i=0
  mkdir -p "$1/scripts"
  printf '#!/bin/bash\n/usr/bin/python3 "$(dirname "$0")/rfb_monthly_refresh.py" &\nwait $!\n' > "$1/scripts/job_timeout.sh"
  printf 'import time\ntime.sleep(600)\n' > "$1/scripts/rfb_monthly_refresh.py"
  bash "$1/scripts/job_timeout.sh" 21600 com.whatsapp.rfb-monthly-refresh >/dev/null 2>&1 &
  par=$!; BG="$BG $par"
  while [ -z "$kid" ] && [ "$i" -lt 50 ]; do kid=$(pgrep -P "$par" 2>/dev/null | head -n 1); [ -n "$kid" ] || sleep 0.1; i=$((i + 1)); done
  [ -n "$kid" ] && { echo "$kid" > "$2"; BG="$BG $kid"; }
  [ -n "$kid" ]
}
calls_set() { /usr/bin/python3 -I "$W/mkdb.py" "$W/pix.db" "$W/vb.db" "$@"; }   # sem argumento = nenhuma ligação; `pix dialing 3` = uma ligação pix em curso há 3 min
world_new() {  # $1=base (MB sem nenhum consumidor), $2=vazamento (MB/min): cidade, mundo, bancos e rfb NOVOS; relógio em T0
  local p; for p in $BG; do kill "$p" 2>/dev/null; done; BG=""
  rm -rf "$CITY" "$WD" "$SD" "$W/tmp" "$W/home" "$W/rodadas" "$W/rfb" "$W/reboot.calls" "$W/launchctl.log" "$W/state.at-reboot"
  mkdir -p "$CITY/.gc/logs" "$WD" "$SD" "$W/tmp" "$W/home" "$W/rodadas"
  : > "$SD/notify.log"; : > "$SD/mail.log"; : > "$W/reboot.calls"; : > "$W/launchctl.log"; : > "$W/trace"; touch "$W/forbidden"; T_D2=""; T_D3=""; T_D4=""; SEEN_IDLE=" "
  printf '%s' "$1" > "$WD/base"; LEAK=$2; echo 2200 > "$WD/rfb.mb"; echo 9000 > "$WD/counter"; NOW_S=$T0; echo $((T0 - 90000)) > "$WD/boot"
  printf '%s\n' "com.whatsapp.demand-dashboard 4001 1-02:00:00 1300" "com.whatsapp.map-viewer 4002 1-02:00:00 800" "com.whatsapp.ficha360 4003 1-02:00:00 400" "com.whatsapp.clientes-dashboard 4004 1-02:00:00 300" > "$WD/procs"
  calls_set; rfb_start "$W/rfb" "$WD/rfb.pid" || nope "o rfb de brinquedo não subiu"
}
world_boot() {  # o mini volta do reinício simulado: $1=base saudável, daemons NOVOS e pequenos, sem rfb (o launchd só o sobe às 00:15), hora de boot nova; o estado e o log da escada ficam (o disco persiste)
  NOW_S=$((NOW_S + 240)); echo $((NOW_S - 60)) > "$WD/boot"; printf '%s' "$1" > "$WD/base"; procs_boot; rm -f "$WD/rfb.pid"
}
mkenv() {  # ENVV = o env do plist (PATH, HOME, GC_CITY_PATH, BD_ACTOR) + só as costuras de teste; a hora simulada de AGORA
  ENVV=( "PATH=$BIN:$PATH" "HOME=$W/home" "TMPDIR=$W/tmp" "GC_CITY_PATH=$CITY" "BD_ACTOR=automation" "E2E_W=$W"
    "DR_NOW_FILE=$W/now" "DR_NOTIFY_BIN=$BIN/notify" "DR_GC_BIN=$BIN/gc" "DR_SETTLE_S=0" "DR_RUNG_TIMEOUT_S=120" "DR_D35_CMD=$BIN/d35-idle"
    "D2_ALLOWLIST=$HERE/disk-recovery-d2-allowlist.tsv" "D2_PS_BIN=$BIN/ps-d2" "D2_DF_BIN=$BIN/df" "D2_AWS_BIN=$BIN/aws" "D2_LAUNCHCTL_BIN=$BIN/launchctl" "D2_NOW=$NOW_S" "D2_TERM_GRACE_S=10"
    "DR_D3_PIX_DB=$W/pix.db" "DR_D3_VOICE_DB=$W/vb.db" "DR_D3_GUARDED=$BIN/guarded" "DR_D3_FREEZE_CMD=$BIN/freeze" "DR_D3_SETTLE_S=0" "DR_D3_READY_S=10" "DR_D3_ROUND_LOCK=$W/round.lock"   # a trava da rodada da campanha: ausente aqui = livre (nunca a do /tmp real da maquina)
    "DR4_NOW=$NOW_S" "DR4_BOOT_EPOCH=$(cat "$WD/boot")" "DR4_FDESETUP_BIN=$BIN/fdesetup" "DR4_DEFAULTS_BIN=$BIN/defaults" "DR4_LAUNCHCTL_BIN=$BIN/launchctl-d4"
    "DR4_PGREP_BIN=$BIN/pgrep" "DR4_SYSCTL_BIN=$BIN/sysctl" "DR4_DF_BIN=$BIN/df" "DR4_OSASCRIPT_BIN=$BIN/osascript" "DR4_CONSOLE_USER=athos"
    "DR4_SENDER_SAFE_PY=$W/sender_stub.py" "DR4_CALLS_PY=$HERE/disk-recovery-d4-calls-in-flight.py" "DR4_NIGHTLY=$HERE/nightly-reboot.sh"
    "PIX_CALL_QUEUE_DEMAND_DB=$W/pix.db" "VOICEBOT_COST_DB=$W/vb.db" "SCRAPER_RODADA_DIR=$W/rodadas" "SCRAPER_BOOT_EPOCH=$(( $(date +%s) - 100000 ))"
    "DR4_REBOOT_CMD=$BIN/reboot-stub" "DR4_NO_REAL_REBOOT=1" "DR4_GRACE_S=0" "DR4_WAIT_S=1" "DR4_REBOOT_TIMEOUT_S=15" "DR4_GUARD_TIMEOUT_S=30" ${OVR[@]+"${OVR[@]}"} )
}
run_ladder() {  # UMA rodada do launchd na hora simulada, do jeito do plist (`/bin/bash disk-recovery-ladder.sh --run`, env mínimo, cwd = a cidade) → OUT/RC (143 = o maestro morreu junto com o mini)
  mkenv; printf '%s' "$NOW_S" > "$W/now"
  OUT=$(cd "$CITY" && env -i "${ENVV[@]}" "$RBASH" "$LADDER" --run 2>&1); RC=$?
}
tick() {  # $1=segundos que passam: o mundo vaza e roda UMA rodada. FB/FA = livre antes/depois; CALLED = degraus chamados na rodada; OUTCOME = a classe do resultado do 1º deles (da linha de log do maestro)
  local n0 base
  NOW_S=$((NOW_S + $1)); base=$(cat "$WD/base"); printf '%s' $((base - LEAK * $1 / 60)) > "$WD/base"
  n0=$(grep -c "" "$LOG" 2>/dev/null); n0=${n0:-0}; FB=$(free_now)
  run_ladder
  FA=$(free_now); NEWLOG=$(tail -n +$((n0 + 1)) "$LOG" 2>/dev/null)
  CALLED=$(printf '%s\n' "$NEWLOG" | sed -n 's/.*degrau \(D[234]\): chamando.*/\1/p' | tr '\n' ' ')
  OUTCOME=$(printf '%s\n' "$NEWLOG" | sed -n 's/.*degrau D[234]: rc=[0-9]* (\([a-z]*\)).*/\1/p' | head -n 1)
  [ -z "$CALLED" ] || echo "$NOW_S ${CALLED%% *}$OUTCOME $FB $FA" >> "$W/trace"
  case "$CALLED" in *D2*) [ -n "$T_D2" ] || T_D2=$NOW_S ;; esac; case "$CALLED" in *D3*) [ -n "$T_D3" ] || T_D3=$NOW_S ;; esac; case "$CALLED" in *D4*) [ -n "$T_D4" ] || T_D4=$NOW_S ;; esac
}
fmt_t() { printf '+%02d:%02d' $(( ($1 - T0) / 3600 )) $(( ($1 - T0) % 3600 / 60 )); }
show() {
  case "$OUTCOME" in idle) case "$SEEN_IDLE" in *" $CALLED"*) return 0 ;; esac; SEEN_IDLE="$SEEN_IDLE$CALLED" ;; esac   # a repetição ociosa (rc 10) do mesmo degrau não polui o quadro
  if [ -n "$CALLED" ] || [ "$RC" != 0 ]; then printf '  %s  livre %5s -> %5s MB  rc=%-3s %s%s\n' "$(fmt_t "$NOW_S")" "$FB" "$FA" "$RC" "${CALLED:-—}" "${OUTCOME:+ ($OUTCOME)}"; fi; }

# ── helpers dos cenários ────────────────────────────────────────────────────────────────────────────────────────────────────────
storm() { printf '%s' $(( $(cat "$WD/base") + $1 )) > "$WD/base"; }                  # estouro de memória: $1 negativo derruba o livre; positivo devolve
nothing_left() { local p; for p in $BG; do kill "$p" 2>/dev/null; done; rm -f "$WD/rfb.pid"; procs_boot; }   # sem rfb e com daemons pequenos: nada que o D2 ou o D3 possam liberar
sv() { sed -n "s/^$1=//p" "$STATE" 2>/dev/null | head -n 1; }
jget() { local j=$1; shift; printf '%s' "$j" | /usr/bin/python3 -I "$W/jget.py" "$@"; }   # $1=JSON, depois os caminhos (ver jget.py)
nlog() { grep -c "" "$LOG" 2>/dev/null; }; since() { tail -n +$(( $1 + 1 )) "$LOG"; }  # nº de linhas do log agora / o log depois da linha $1
trace_delta() { awk -v k="$1" '$2 == k {print $4 - $3; exit}' "$W/trace"; }          # livre depois − antes da rodada em que o degrau $1 ("D2acted") foi chamado
mkdir -p "$W/logs"
HEALTHY=14000                                                                           # base sem consumidor que dá 9000 MB livres com os 5000 MB de rfb + daemons

section "fiação: o plist e os degraus são o que o maestro espera"
PL=$(/usr/bin/python3 -I -c 'import plistlib, sys; d = plistlib.load(open(sys.argv[1], "rb")); a = d["ProgramArguments"]; print(a[0], a[2], d["StartInterval"], a[1].rsplit("/", 2)[-2] + "/" + a[1].rsplit("/", 1)[-1], d["EnvironmentVariables"]["GC_CITY_PATH"] != "")' "$HERE/com.gascity.disk-recovery-ladder.plist" 2>&1)
eq "$PL" "/bin/bash --run 120 scripts/disk-recovery-ladder.sh True" "plist: /bin/bash <cidade>/scripts/disk-recovery-ladder.sh --run a cada 120 s, com GC_CITY_PATH"
for f in disk-recovery-ladder disk-recovery-d2-heavy-jobs disk-recovery-d3-ram-daemons disk-recovery-d4-guarded-reboot; do
  # o maestro trata degrau sem permissão de execução como AUSENTE e pula: o modo que vale é o do git (100755), não o do disco de quem rodou o teste
  m=$(git -C "$HERE" ls-files -s -- "$f.sh" 2>/dev/null | awk '{print $1}'); [ -n "$m" ] || m=$([ -x "$HERE/$f.sh" ] && echo 100755 || echo 100644)
  eq "$m" 100755 "$f.sh é executável (100755)"
done

section "S-A: estouro de memória — D2, D3 e D4 reais em cadeia, reinício simulado, depois o teto de 6 h (rodadas de 120 s)"
STEP=120; world_new "$((HEALTHY - 6600))" 15            # base 7400 → livre 2400 MB (rfb 2200 + daemons 2800 de pegada), perdendo 15 MB/min
rfb_start "$W/prod-lookalike" "$W/lookalike.pid" || nope "o rfb 'de produção' de mentira não subiu"   # processo IGUAL ao rfb na linha de comando, mas fora do brinquedo: o D2 do teste não pode enxergá-lo
printf '  livre inicial %s MB; vazamento 15 MB/min; quadro: hora simulada, livre antes → depois da rodada, rc do maestro, degrau chamado\n' "$(free_now)"
i=0
while [ "$i" -lt 40 ]; do
  [ $((NOW_S - T0)) -eq 2280 ] && { storm -4500; echo "  (+00:38 estouro de memória: o livre cai 4500 MB de uma vez)"; }
  tick "$STEP"; show; i=$((i + 1)); [ "$RC" = 143 ] && break
done
eq "$RC" 143 "S-A: o reinício simulado matou o maestro junto com o D4 (rc 143)"
eq "$(( (T_D2 - T0) / 60 )) $(( (T_D3 - T0) / 60 )) $(( (T_D4 - T0) / 60 ))" "18 32 42" "S-A: 1ª chamada na ordem D2 (≥ 900 s < 5 GB) → D3 (≥ 1800 s < 4 GB) → D4 (piso duro: 2 leituras < 1,5 GB seguidas)"
eq "$(trace_delta D2acted) $(trace_delta D3acted)" "2200 1220" "S-A: D2 devolveu os 2200 MB do rfb e o D3 os 1220 MB do daemon que mais pesava, vistos na re-medição do maestro"
if [ -s "$WD/rfb.pid" ] && kill -0 "$(cat "$WD/rfb.pid")" 2>/dev/null; then nope "S-A: o rfb de brinquedo seguiu vivo"; else ok "S-A: o D2 matou o rfb de brinquedo (processo de verdade, TERM)"; fi
if kill -0 "$(cat "$W/lookalike.pid")" 2>/dev/null; then ok "S-A: um processo IDÊNTICO ao rfb na linha de comando, fora do brinquedo (o 'rfb de produção'), seguiu vivo: o D2 do teste só enxerga o brinquedo"; else nope "S-A: o D2 matou um processo que não era o rfb de brinquedo"; fi
kill "$(cat "$W/lookalike.pid")" 2>/dev/null   # o de mentira só existe enquanto o D2 deste teste está agindo (um D2 de produção, se rodasse agora, também o casaria)
has "$(cat "$CITY/.gc/disk-recovery-d2.state")" "STOPPED" "S-A: o D2 gravou o registro do que parou (STOPPING antes do kill, STOPPED depois)"
eq "$(cat "$W/launchctl.log")" "kickstart com.whatsapp.demand-dashboard" "S-A: o D3 reiniciou só o daemon que mais pesava e parou ao recuperar (livre > 4608 MB)"
eq "$(cnt "$SD/notify.log" 'p=3 force= t=Disco: degrau D2 agiu')$(cnt "$SD/notify.log" 'p=4 force=1 t=Disco: degrau D3 agiu')$(cnt "$SD/mail.log" 'Disco: degrau D')" 112 "S-A: o maestro avisou o que cada degrau fez (D2 -p 3; D3 -p 4 forçado) e mandou 1 mail por ação"
eq "$(cat "$W/reboot.calls" | wc -l | tr -d ' ')" 1 "S-A: exatamente UM pedido de reinício"
has "$(cat "$W/notify.at-reboot")" "p=5 force=1 t=Disco: reiniciando o mini" "S-A: o aviso -p 5 saiu ANTES do pedido de reinício"
eq "$(sed -n 's/^acted4_ts=//p' "$W/state.at-reboot")" "$T_D4" "S-A: a marca do reinício (acted4_ts) JÁ estava no disco quando o pedido saiu"
hasnt "$(cat "$LOG")" "degrau D4: rc=" "S-A: o maestro morreu com o mini: o D4 não tem linha de resultado (o relatório conta isso como reinício pedido)"
SA_D4_FB=$FB; SA_BOOT_FB=""; N0=$(nlog)
world_boot 10000; STEP=300; LEAK=0                                             # o mini volta: base saudável, daemons novos e pequenos, hora de boot nova
for k in 1 2 3; do tick "$STEP"; [ -n "$SA_BOOT_FB" ] || SA_BOOT_FB=$FB; done
AFTER=$(since "$N0")
eq "$RC $(printf '%s\n' "$AFTER" | grep -c 'recuperou') $(printf '%s\n' "$AFTER" | grep -c 'degrau D')" "0 3 0" "S-A depois do boot: rodada normal (rc 0), os 3 cronômetros zerados (recuperou) e nenhum degrau chamado"
eq "$(sv acted4_ts)" "$T_D4" "S-A depois do boot: a hora do último reinício (acted4_ts) fica no estado (o disco persiste)"
storm -7000; printf '  (%s o disco volta a sangrar depois do boot: livre %s MB)\n' "$(fmt_t "$NOW_S")" "$(free_now)"
i=0; while [ "$i" -lt 16 ]; do tick "$STEP"; show; i=$((i + 1)); done
eq "$(cat "$W/reboot.calls" | wc -l | tr -d ' ')" 1 "S-A teto de 6 h: 60 min < 3 GB depois do reinício e NENHUM segundo reinício"
eq "$(cnt "$LOG" 'ESCALA: D4 elegível')$(cnt "$SD/notify.log" 'preciso de um humano')$(cnt "$SD/mail.log" 'D4 já disparou')" 111 "S-A teto de 6 h: escala UMA vez (notify -p 5 + mail ao Mayor) em vez de reiniciar"
eq "$(cnt "$LOG" 'degrau D4: chamando')" 1 "S-A teto de 6 h: o maestro não chamou o D4 de novo (só a chamada do reinício)"
cp "$LOG" "$W/logs/s-a-full.log"

section "S-B: nada mais a liberar (rfb parado, daemons pequenos): D2 e D3 adiam, o D4 entra pelo relógio de 60 min (rodadas de 300 s)"
STEP=300; world_new 3200 0; nothing_left; printf '  livre %s MB constante\n' "$(free_now)"
i=0; while [ "$i" -lt 20 ]; do tick "$STEP"; show; i=$((i + 1)); [ "$RC" = 143 ] && break; done
eq "$RC" 143 "S-B: o D4 reiniciou (rc 143)"
eq "$(( (T_D2 - T0) / 60 )) $(( (T_D3 - T0) / 60 )) $(( (T_D4 - T0) / 60 ))" "20 35 65" "S-B: D2 aos 900 s, D3 aos 1800 s e o D4 só aos 3600 s da 1ª leitura (a rodada de 3300 s NÃO o chamou)"
has "$(cat "$LOG")" "degrau D2: rc=10 (idle) livre antes=2980MB" "S-B: o D2 real devolveu 10 e o maestro o marcou idle"
has "$(cat "$LOG")" "D2 --run: nada a parar: rfb-monthly-refresh n" "S-B: a linha do D2 diz que não há rfb rodando (o maestro só guarda os caracteres ASCII da linha)"
has "$(cat "$LOG")" "nenhum daemon elegivel" "S-B: o D3 real devolveu 10 (nenhum daemon elegível) e o maestro o marcou idle"
cp "$LOG" "$W/logs/s-b.log"

section "S-C: ligação em curso segura o D4 (e o D3) com o MESMO banco; o reinício sai depois que ela acaba (rodadas de 300 s)"
STEP=300; world_new 3200 0; nothing_left; calls_set pix dialing 3
i=0; while [ "$i" -lt 20 ]; do tick "$STEP"; show; i=$((i + 1)); [ "$(( (NOW_S - T0) / 60 ))" -ge 95 ] && break; done
eq "$(cat "$W/reboot.calls" | wc -l | tr -d ' ')" 0 "S-C: com a ligação em curso NÃO houve reinício (D4 chamado e adiado a partir de +65 min)"
eq "$(cnt "$SD/notify.log" 'reinício adiado (calls)')" 1 "S-C: um aviso -p 5 de reinício adiado (no máximo 1 por hora)"
calls_set; i=0; while [ "$i" -lt 8 ]; do tick "$STEP"; show; i=$((i + 1)); [ "$RC" = 143 ] && break; done
eq "$RC $(cat "$W/reboot.calls" | wc -l | tr -d ' ')" "143 1" "S-C: a ligação acabou e o D4 reiniciou (uma vez)"

section "S-C2: o D3 real lê a MESMA ligação (outro leitor, mesmo banco) e não reinicia o daemon (rodadas de 300 s)"
STEP=300; world_new 3940 0; nothing_left; printf '%s\n' "com.whatsapp.demand-dashboard 5001 00:03 90" "com.whatsapp.map-viewer 4002 1-02:00:00 800" "com.whatsapp.ficha360 5003 00:03 40" "com.whatsapp.clientes-dashboard 5004 00:03 30" > "$WD/procs"
calls_set pix dialing 3; i=0; while [ "$i" -lt 8 ]; do tick "$STEP"; i=$((i + 1)); done
has "$(cat "$LOG")" "D3 adiado, nada reiniciado: ligacao em curso (pix=1 voicebot=0) antes de map-viewer" "S-C2: o D3 adiou com a ligação em curso (livre $FB MB, o map-viewer de 800 MB estava elegível)"
eq "$(cat "$W/launchctl.log")" "" "S-C2: nenhum daemon foi reiniciado com a ligação em curso"

section "S-D: hora saudável e depois um pico isolado < 1,5 GB: UMA leitura não reinicia (rodadas de 120 s)"
STEP=120; world_new "$HEALTHY" 0
for k in 1 2 3; do tick "$STEP"; done
eq "$(cnt "$LOG" 'ok: livre=')$(cnt "$LOG" 'degrau')" "10" "S-D: disco saudável: 1 batimento no log e nenhum degrau"
storm -8500; tick "$STEP"; show; has "$(cat "$LOG")" "seguidas=1/2" "S-D: a leitura de pico (livre $FB MB) conta 1 de 2 seguidas"
storm 8500; tick "$STEP"; tick "$STEP"
eq "$(cat "$W/reboot.calls" | wc -l | tr -d ' ')$(cnt "$LOG" 'degrau D4: chamando')$(sv hard_n)" "000" "S-D: o pico passou: nenhum reinício, o D4 nem foi chamado e a contagem de leituras seguidas voltou a 0"

section "S-F: interruptor (touch .gc/disk-recovery.off) por 70 min com o disco baixo (rodadas de 300 s)"
STEP=300; world_new 3200 0; nothing_left
tick "$STEP"; tick "$STEP"; touch "$OFF"; i=0; rcs=""
while [ "$i" -lt 14 ]; do tick "$STEP"; rcs="$rcs$RC "; i=$((i + 1)); done
eq "$rcs" "10 10 10 10 10 10 10 10 10 10 10 10 10 10 " "S-F: com o interruptor ligado toda rodada sai 10 sem ler nem agir"
rm -f "$OFF"; tick "$STEP"; tick "$STEP"
eq "$RC" 0 "S-F: interruptor desligado: o maestro volta"
has "$(cat "$LOG")" "lacuna: última leitura" "S-F: o tempo sem leitura NÃO conta como 'abaixo do limiar' (lacuna zerou os cronômetros)"
eq "$(cnt "$LOG" 'degrau D')" 0 "S-F: nenhum degrau foi chamado em 80 min de disco baixo (era o interruptor)"
cp "$LOG" "$W/logs/s-f.log"

section "relatório (disk-recovery-report.py) lendo os logs que o maestro REAL escreveu"
rep() { /usr/bin/python3 -I "$REPORT" --min-hours 0 --json "$@"; }
R=$(rep --log "$W/logs/s-a-full.log"); RRC=$?
eq "$RRC" 0 "relatório de S-A: aceite ATENDIDO (rc 0)"
eq "$(jget "$R" rungs.D2.acted rungs.D2.returned_mb rungs.D3.acted rungs.D3.returned_mb)" "1 2200 1 1220" "relatório de S-A: D2 e D3 agiram 1x cada e devolveram o que o mundo mediu (2200 e 1220 MB)"
eq "$(jget "$R" rungs.D4.calls rungs.D4.reboots_inferred rungs.D4.no_result)" "1 1 1" "relatório de S-A: 1 chamada do D4, sem linha de resultado = 1 reinício pedido (inferido)"
eq "$(jget "$R" rungs.D4.after_boot_mb)" "$((SA_BOOT_FB - SA_D4_FB))" "relatório de S-A: o D4 devolveu a diferença da 1ª leitura depois do boot (${SA_BOOT_FB} MB) para a da chamada (${SA_D4_FB} MB)"
eq "$(jget "$R" 'windows[].verdict')" "OK,OK,OK_ADIADA" "relatório de S-A: 3 janelas < 3 GB: as duas com degrau que agiu e a pós-boot (só chamadas adiadas + escalada)"
R=$(rep --log "$W/logs/s-b.log"); set -- $(jget "$R" rungs.D2.idle rungs.D3.idle rungs.D4.reboots_inferred acceptance)
{ [ "$1" -ge 1 ] && [ "$2" -ge 1 ] && [ "$3" = 1 ] && [ "$4" = ATENDIDO ]; } && ok "relatório de S-B: D2 ($1x) e D3 ($2x) adiaram, 1 reinício pedido, aceite ATENDIDO" || nope "relatório de S-B: idle D2=$1 D3=$2 reinícios=$3 aceite=$4"
R=$(rep --log "$W/logs/s-f.log"); RRC=$?
eq "$RRC $(jget "$R" acceptance 'windows[0].calls')" "1 NAO_ATENDIDO []" "relatório de S-F (controle negativo): janela > 60 min com disco < 3 GB e NENHUMA ação da escada = NÃO ATENDIDO, rc 1"
rep --log "$W/nao-existe.log" >/dev/null 2>&1; eq "$?" 3 "relatório de um log que não existe: rc 3 (não sei), nunca '0 eventos'"
: > "$W/logs/vazio.log"; R=$(rep --log "$W/logs/vazio.log"); eq "$(jget "$R" acceptance readings)" "NAO_VERIFICADO 0" "relatório de um log vazio: NÃO VERIFICADO (a escada não escreveu nada), nunca ATENDIDO"

section "nada vazou nem tocou na máquina"
eq "$(cat "$W/forbidden")" "" "nenhum reboot/shutdown/sudo, nenhum 'df /' e nenhum launchctl/sysctl fora do combinado"
printf '\n%s passaram, %s falharam\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
