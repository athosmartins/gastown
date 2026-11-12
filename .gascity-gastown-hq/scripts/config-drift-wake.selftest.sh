#!/usr/bin/env bash
# config-drift-wake.selftest.sh — selftest do config-drift-wake.py (ga-wo99v8w) com `gc` e `bd` FALSOS: o mundo é uma pasta de arquivos e nada toca a cidade de verdade.
# Uso: bash config-drift-wake.selftest.sh   (PYTHON=python3.9 roda no 3.9 do mini; CDW_UNDER_TEST=<cópia> roda um mutante; sem env nenhum também serve: é como o guard do gate o chama)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PY=$(command -v "${PYTHON:-python3}") || { echo "FAIL: sem python"; exit 2; }
SCRIPT=${CDW_UNDER_TEST:-$HERE/config-drift-wake.py}
[ -f "$SCRIPT" ] || { echo "FAIL: config-drift-wake.py não existe em $SCRIPT"; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/cdw-selftest.XXXXXX") || exit 2
HOLD=""
trap 'chmod -R u+rwx "$T" 2>/dev/null; [ -n "$HOLD" ] && kill "$HOLD" 2>/dev/null; rm -rf "$T"' EXIT
PASS=0; FAIL=0; N=0; W=""; OUT=""; RC=0
mkdir -p "$T/bin"
cat > "$T/fake.py" <<'EOF'
# gc/bd falsos: o mundo vem de $CDW_WORLD (roster[.N].json, rigs.json, store.<loja>.json, show.<id>.json, *.mode = fail|garbage|empty|hang, wake.rc, comment.rc); toda chamada é registrada em calls.log
import os, sys, time
W = os.environ["CDW_WORLD"]
who, args = sys.argv[1], sys.argv[2:]
def rd(name, default=""):
    try:
        return open(os.path.join(W, name)).read().strip()
    except OSError:
        return default
def serve(mode, path):
    if mode == "hang":
        time.sleep(60)
    if mode == "fail":
        sys.exit(1)
    if mode == "garbage":
        print("not json {")
        sys.exit(0)
    if mode != "empty":
        sys.stdout.write(open(path).read())
    sys.exit(0)
def bump(name):
    # N-ésima chamada deste arquivo; gravar o contador que falha (umask 777) não derruba o fake: a contagem volta a 1
    n = int(rd(name, "0")) + 1
    try:
        open(os.path.join(W, name), "w").write(str(n))
    except OSError:
        pass
    return n
open(os.path.join(W, "calls.log"), "a").write(who + " " + " ".join(args) + "\n")
if who == "gc" and args[:3] == ["session", "list", "--json"]:
    n = bump("roster.n")
    p = os.path.join(W, "roster.%d.json" % n)
    serve(rd("roster.%d.mode" % n, rd("roster.mode", "ok")), p if os.path.exists(p) else os.path.join(W, "roster.json"))
if who == "gc" and args[:3] == ["rig", "list", "--json"]:
    serve(rd("rigs.mode", "ok"), os.path.join(W, "rigs.json"))
if who == "gc" and args[:2] == ["session", "wake"]:
    sys.exit(int(rd("wake.rc", "0")))
if who == "bd" and args[:1] == ["-C"]:
    store, rest = os.path.basename(args[1]), args[2:]
    if rest == ["list", "--status", "in_progress", "--limit", "0", "--json"]:
        serve(rd("store.%s.mode" % store, "ok"), os.path.join(W, "store.%s.json" % store))
    if rest[:1] == ["show"] and rest[2:] == ["--json"] and store == "hq" and os.path.exists(os.path.join(W, "session.%s.json" % rest[1])):
        # bead de SESSÃO (mora no store da CIDADE, o `hq`; o motivo do sono mora nela): session.<id>.json, session.<id>.<N>.json = a N-ésima leitura dela, session.<id>.mode e session.<id>.<N>.mode = fail|garbage|empty|hang
        sid = rest[1]; n = bump("session.%s.n" % sid); pn = os.path.join(W, "session.%s.%d.json" % (sid, n))
        serve(rd("session.%s.%d.mode" % (sid, n), rd("session.%s.mode" % sid, "ok")), pn if os.path.exists(pn) else os.path.join(W, "session.%s.json" % sid))
    if rest[:1] == ["show"] and rest[2:] == ["--json"]:
        ov, mode = os.path.join(W, "show.%s.json" % rest[1]), rd("show.mode", "ok")
        if mode != "ok" or os.path.exists(ov):
            serve(mode, ov)
        import json
        hit = [b for b in json.load(open(os.path.join(W, "store.%s.json" % store))) if b.get("id") == rest[1]]
        print(json.dumps(hit))
        sys.exit(0 if hit else 1)
    if rest[:1] == ["comment"] and len(rest) == 3:
        sys.exit(int(rd("comment.rc", "0")))
open(os.path.join(W, "calls.log"), "a").write("UNEXPECTED\n")
sys.exit(99)
EOF
for x in gc bd; do printf '#!/bin/sh\nexec "%s" "%s/fake.py" %s "$@"\n' "$PY" "$T" "$x" > "$T/bin/$x"; chmod +x "$T/bin/$x"; done

fail()  { FAIL=$((FAIL+1)); echo "FAIL: $*"; [ -z "${CDW_FAILFAST:-}" ] || exit 1; }   # CDW_FAILFAST=1: para no 1º FAIL (a bateria de mutantes só precisa saber se morreu)
eq()    { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else fail "$1 — got [$2] want [$3]"; fi; }
has()   { case "$2" in *"$3"*) PASS=$((PASS+1));; *) fail "$1 — faltou [$3] em: $(printf '%s' "$2" | tail -4)";; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 — sobrou [$3]";; *) PASS=$((PASS+1));; esac; }
world() { N=$((N+1)); W="$T/w$N"; mkdir -p "$W/hq/.gc" "$W/wa"; : > "$W/calls.log"
  printf '{"rigs":[{"name":"gascity","path":"%s/hq","hq":true},{"name":"whatsapp_automation","path":"%s/wa"}]}' "$W" "$W" > "$W/rigs.json"; printf '[]' > "$W/store.hq.json"; printf '[]' > "$W/store.wa.json"; }
sessj() { printf '[{"id":"%s","title":"Pool top-up: x","status":"open","priority":2,"issue_type":"session","created_at":"2026-11-12T18:43:57Z","updated_at":"2026-11-12T19:09:49Z","metadata":{"agent_name":"%s","alias":"%s","state":"%s","sleep_reason":"%s","state_reason":"","sleep_intent":"","drain_at":"2026-11-12T19:03:07Z","session_name":"%s-sess","template":"%s","wake_mode":"fresh","continuation_reset_pending":"true"},"labels":["gc:session","template:%s"],"dependent_count":0,"dependency_count":0,"comment_count":0}]' "$1" "$2" "$2" "${5:-asleep}" "$4" "$2" "$3" "$3"; }   # a bead de sessão NA FORMA do `bd show --json` real: o motivo do sono mora em metadata.sleep_reason
# row ID ALIAS TEMPLATE STATE [MOTIVO] [FECHADA]: a linha NA FORMA REAL do `gc session list --json` (as 20 chaves que o revisor do gate leu ao vivo, NENHUMA de motivo); a sessão asleep ganha também a bead de sessão com o MOTIVO (é lá que o job o lê)
row()   { [ "$4" != asleep ] || sessj "$1" "$2" "$3" "${5:-}" > "$W/session.$1.json"
  printf '{"agent_name":"%s","alias":"%s","attached":false,"closed":%s,"command":"claude","created_at":"2026-11-12T18:43:57Z","id":"%s","last_active":"2026-11-12T19:09:49Z","last_nudge_delivered_at":"","name":"%s-sess","provider":"claude-headless","resume_flag":"--resume","resume_style":"flag","rig":"","session_key":"k","session_name":"%s-sess","state":"%s","template":"%s","title":"t","work_dir":"/w"}' "$2" "$2" "${6:-false}" "$1" "$2" "$2" "$4" "$3"; }
bead()  { local lb=${3:-}; [ -n "$lb" ] || lb='["story:in-flight","pilot:dispatched"]'
  printf '{"id":"%s","status":"%s","issue_type":"%s","assignee":"%s","labels":%s}' "$1" "${4:-in_progress}" "${5:-task}" "$2" "$lb"; }
rows()  { local IFS=,; printf '{"sessions":[%s]}' "$*" > "$W/roster.json"; }
store() { local n=$1; shift; local IFS=,; printf '[%s]' "$*" > "$W/store.$n.json"; }
runit() { OUT=$(env PYTHONDONTWRITEBYTECODE=1 GC_CITY_PATH="$W/hq" GC_BIN="$T/bin/gc" BD_BIN="$T/bin/bd" CDW_WORLD="$W" CONFIG_DRIFT_WAKE_DRY_RUN=0 "$@" "$PY" "$SCRIPT" 2>"$W/err"); RC=$?; }
wakes() { grep '^gc session wake ' "$W/calls.log" | sed 's/^gc session wake //' | sort | tr '\n' ' ' | sed 's/ $//'; }
ncalls() { grep -c "$1" "$W/calls.log"; }
three() { world; rows "$(row ga-s1 dog-remote-1 dog-remote asleep config-drift)" "$(row ga-s2 dog-remote-2 dog-remote asleep config-drift)" "$(row ga-s3 dog-remote-3 dog-remote asleep config-drift)"
  store hq "$(bead ga-b1 dog-remote-1)" "$(bead ga-b2 dog-remote-2)" "$(bead ga-b3 dog-remote-3)"; }   # 3 candidatas, cada uma com a sua bead no HQ
rows1() { world; rows "$(row ga-s1 dog-remote-3 dog-remote asleep config-drift)"; store hq "$(bead ga-b1 dog-remote-3)"; }   # o mundo mínimo: 1 candidata com bead viva no HQ

# 1) o aceite: acorda SÓ a candidata com bead viva (2 lojas); sem bead, outro motivo, viva, fora do pool, bead estacionada e sessão fechada ficam quietas
world
rows "$(row ga-s1 dog-remote-3 dog-remote asleep config-drift)" "$(row ga-s2 wa-worker-remote-2 wa-worker-remote asleep config-drift)" "$(row ga-s3 dog-remote-4 dog-remote asleep config-drift)" \
     "$(row ga-s4 dog-remote-5 dog-remote asleep idle-timeout)" "$(row ga-s5 dog-remote-6 dog-remote active '')" "$(row ga-s6 mila-wa mila-wa asleep config-drift)" \
     "$(row ga-s7 ps-worker-1 ps-worker asleep config-drift)" "$(row ga-s8 dog-remote-7 dog-remote asleep config-drift true)"
store hq "$(bead ga-b1 dog-remote-3)" "$(bead ga-b4 dog-remote-5)" "$(bead ga-b5 dog-remote-6)" "$(bead ga-b6 mila-wa)" "$(bead ga-b8 dog-remote-7)" "$(bead ga-b7 ps-worker-1 '["next-action:mayor"]')"
store wa "$(bead wa-b2 wa-worker-remote-2)"
runit
eq "1 rc" "$RC" 0
eq "1 acorda só a candidata com bead viva" "$(wakes)" "ga-s1 ga-s2"
eq "1 comentário na loja certa de cada uma" "$(ncalls "^bd -C $W/hq comment ga-b1 config-drift-wake")/$(ncalls "^bd -C $W/wa comment wa-b2 config-drift-wake")/$(ncalls ' comment ')" "1/1/2"
has "1 census" "$OUT" "census sessoes=8 asleep=6 pool_asleep=5 com_motivo=5 candidatas=4 motivos=config-drift:4,idle-timeout:1"
has "1 sem bead dita" "$OUT" "SKIP ga-s3 alias=dog-remote-4 tpl=dog-remote — sem-bead"
has "1 bead estacionada dita" "$OUT" "SKIP ga-s7 alias=ps-worker-1 tpl=ps-worker — estado:parked"
has "1 WAKE logado com loja e bead" "$OUT" "WAKE ga-s2 alias=wa-worker-remote-2 tpl=wa-worker-remote bead=whatsapp_automation/wa-b2"
case "$(head -1 <<<"$OUT")" in "[config-drift-wake] start enabled=True dry_run=False cooldown=900s max=6 reason=config-drift probes=30 call_timeout=40s") PASS=$((PASS+1));; *) fail "1 a linha start vem primeiro e diz o que VALE";; esac
has "1 o relógio guarda a tentativa" "$(cat "$W/hq/.gc/state/config-drift-wake.json")" '"ga-s1": {"at":'

# 2) roster ilegível = nada é decidido (rc 1, nenhuma leitura de bead, nenhum wake): falhou, lixo, vazio, sem lista, sem `state` em texto, 0 sessões
for m in fail garbage empty; do rows1; printf '%s' "$m" > "$W/roster.mode"; runit
  eq "2 roster $m: rc 1" "$RC" 1; has "2 roster $m: DEGRADED" "$OUT" "DEGRADED: gc session list"; eq "2 roster $m: só 1 chamada" "$(wc -l < "$W/calls.log" | tr -d ' ')" 1; done
for body in '{"sessions":[]}' '{"sessions":[{"id":"a","status":"asleep"}]}' '{"x":1}'; do rows1; printf '%s' "$body" > "$W/roster.json"; runit; eq "2 roster $body: rc 1 sem wake" "$RC/$(wakes)" "1/"; done
rows1; runit GC_BIN=/nonexistent/gc; eq "2 gc ausente: rc 1" "$RC" 1; has "2 gc ausente dito" "$OUT" "WARN: /nonexistent/gc session list --json falhou"

# 3) loja ilegível: a candidata cuja bead pode estar lá é "não sei"; a que tem bead numa loja lida acorda; nenhuma loja lida = rc 1
rows1; rows "$(row ga-s1 dog-remote-3 dog-remote asleep config-drift)" "$(row ga-s2 wa-worker-remote-2 wa-worker-remote asleep config-drift)"; store wa "$(bead wa-b2 wa-worker-remote-2)"; printf fail > "$W/store.hq.mode"; runit
eq "3 hq ilegível: só a da wa acorda" "$RC/$(wakes)" "0/ga-s2"; has "3 hq ilegível: não sei" "$OUT" "SKIP ga-s1 alias=dog-remote-3 tpl=dog-remote — nao-sei:loja-ilegivel"
for m in fail garbage; do printf '%s' "$m" > "$W/store.wa.mode"; printf '%s' "$m" > "$W/store.hq.mode"; : > "$W/calls.log"; runit; eq "3 nenhuma loja ($m): rc 1 sem wake" "$RC/$(wakes)" "1/"; has "3 nenhuma loja ($m) dita" "$OUT" "nenhuma loja legível"; done
rows1; rows "$(row ga-s1 dog-remote-3 dog-remote asleep config-drift)" "$(row ga-s2 wa-worker-remote-2 wa-worker-remote asleep config-drift)"; store wa "$(bead wa-b2 wa-worker-remote-2)"; printf fail > "$W/rigs.mode"; runit
eq "3 rig list falhou: o HQ acorda, a wa é não-sei" "$RC/$(wakes)" "0/ga-s1"; has "3 rig list falhou dito" "$OUT" "DEGRADED stores"; has "3 rig list falhou: a wa não é 'sem bead'" "$OUT" "SKIP ga-s2 alias=wa-worker-remote-2 tpl=wa-worker-remote — nao-sei:loja-ilegivel"

# 4) releitura antes de agir: sessão que já subiu, bead que mudou, releitura que falha, roster da releitura ilegível
rows1; rows "$(row ga-s1 dog-remote-3 dog-remote asleep config-drift)"; printf '%s' "{\"sessions\":[$(row ga-s1 dog-remote-3 dog-remote active '')]}" > "$W/roster.2.json"; runit
eq "4 já subiu: sem wake" "$(wakes)" ""; has "4 já subiu dito" "$OUT" "SKIP ga-s1 alias=dog-remote-3 tpl=dog-remote bead=hq/ga-b1 — a sessão mudou: nao-asleep"
rows1; printf '[%s]' "$(bead ga-b1 outra-sessao)" > "$W/show.ga-b1.json"; runit; eq "4 bead mudou de dono: sem wake" "$(wakes)" ""; has "4 bead mudou dito" "$OUT" "a bead mudou de dono ou de estado"
rows1; printf '[%s]' "$(bead ga-b1 dog-remote-3 '["blocked:external-quota-motherduck"]')" > "$W/show.ga-b1.json"; runit; eq "4 bead estacionada na releitura: sem wake" "$(wakes)" ""
rows1; printf fail > "$W/show.mode"; printf '[]' > "$W/show.ga-b1.json"; runit; eq "4 bd show falhou: sem wake" "$(wakes)" ""; has "4 bd show falhou dito" "$OUT" "bead ilegível na releitura"
rows1; printf fail > "$W/roster.2.mode"; runit; eq "4 roster da releitura ilegível: sem wake" "$(wakes)" ""; has "4 roster da releitura dito" "$OUT" "roster ilegível na releitura"

# 5) gêmea viva = trabalho em dobro (estado desconhecido conta viva; gêmea morta não impede); duas candidatas para a mesma bead = ambígua
rows1; rows "$(row ga-s1 dog-remote-3 dog-remote asleep config-drift)" "$(row ga-s9 dog-remote-3 dog-remote active '')"; runit; eq "5 gêmea ativa: sem wake" "$(wakes)" ""; has "5 gêmea dita" "$OUT" "gemea-viva"
rows "$(row ga-s1 dog-remote-3 dog-remote asleep config-drift)" "$(row ga-s9 dog-remote-3 dog-remote '' '')"; runit; eq "5 gêmea de estado desconhecido: sem wake" "$(wakes)" ""
rows "$(row ga-s1 dog-remote-3 dog-remote asleep config-drift)" "$(row ga-s9 dog-remote-3 dog-remote asleep idle-timeout)" "$(row ga-s10 dog-remote-3 dog-remote active '' true)"; runit; eq "5 gêmea asleep/fechada não impede" "$(wakes)" "ga-s1"
rows1; rows "$(row ga-s1 dog-remote-3 dog-remote asleep config-drift)" "$(row ga-s9 dog-remote-3 dog-remote asleep config-drift)"; runit; eq "5 ambígua: nenhuma acorda" "$(wakes)" ""; has "5 ambígua dita" "$OUT" "ambigua: 2 candidatas"

# 6) relógio: 1 vez por sessão a cada 15 min, gravado ANTES do wake; wake que falha também carimba; relógio ilegível = nada acorda
rows1; runit; runit; eq "6 2ª rodada logo depois: COOLDOWN" "$(wakes)" "ga-s1"; has "6 COOLDOWN dito" "$OUT" "COOLDOWN ga-s1"
NOW=$(date +%s); printf '{"ga-s1":{"at":%d,"bead":"ga-b1"}}' $((NOW-890)) > "$W/hq/.gc/state/config-drift-wake.json"; runit; eq "6 há 890 s ainda segura" "$(wakes)" "ga-s1"
printf '{"ga-s1":{"at":%d,"bead":"ga-b1"}}' $((NOW-910)) > "$W/hq/.gc/state/config-drift-wake.json"; runit; eq "6 há 910 s acorda de novo" "$(wakes)" "ga-s1 ga-s1"
printf '{"ga-s1":{"at":%d,"bead":"ga-b1"}}' $((NOW+100000)) > "$W/hq/.gc/state/config-drift-wake.json"; runit; eq "6 carimbo do futuro distante não segura" "$(wakes)" "ga-s1 ga-s1 ga-s1"
rows1; printf 3 > "$W/wake.rc"; runit; has "6 wake falhou: FAIL dito" "$OUT" "FAIL ga-s1 alias=dog-remote-3 tpl=dog-remote bead=hq/ga-b1 — gc session wake rc=3"; eq "6 wake falhou: sem comentário" "$(ncalls ' comment ')" 0
runit; has "6 wake falhou: a nova rodada NÃO repete" "$OUT" "COOLDOWN ga-s1"; eq "6 só 1 tentativa" "$(wakes)" "ga-s1"
rows1; mkdir -p "$W/hq/.gc/state"; printf 'isto não é json' > "$W/hq/.gc/state/config-drift-wake.json"; runit; eq "6 relógio corrompido: rc 0, sem wake" "$RC/$(wakes)" "0/"; has "6 corrompido dito" "$OUT" "STATE-ERROR"
eq "6 corrompido posto de lado" "$(ls "$W/hq/.gc/state")" "config-drift-wake.json.corrupt"; runit; eq "6 a rodada seguinte recomeça limpa" "$(wakes)" "ga-s1"
rows1; mkdir -p "$W/hq/.gc/state"; printf '{"ga-s1":{"at":1}}' > "$W/hq/.gc/state/config-drift-wake.json"; chmod 000 "$W/hq/.gc/state/config-drift-wake.json"
if [ "$(id -u)" = 0 ]; then echo "SKIP: relógio chmod 000 e diretório 555 (root lê tudo)"; else runit; eq "6 relógio chmod 000: sem wake" "$(wakes)" ""
  rows1; mkdir -p "$W/hq/.gc/state"; chmod 555 "$W/hq/.gc/state"; runit; eq "6 relógio não gravável: rc 1 e sem wake" "$RC/$(wakes)" "1/"; has "6 não gravável dito" "$OUT" "STATE-ERROR: não consegui gravar"; chmod 755 "$W/hq/.gc/state"; fi

# 7) ensaio: só "0" exato age; nada é escrito (nem o relógio)
for v in "" 1 false 00 " 0" off; do rows1; runit CONFIG_DRIFT_WAKE_DRY_RUN="$v"; eq "7 DRY_RUN='$v': sem wake, sem comentário, sem relógio" "$(wakes)/$(ncalls ' comment ')/$(ls "$W/hq/.gc" | tr '\n' ' ')" "/0/config-drift-wake.lock "; has "7 DRY_RUN='$v': WOULD-WAKE" "$OUT" "WOULD-WAKE ga-s1"; done
rows1; runit env -u CONFIG_DRIFT_WAKE_DRY_RUN; has "7 variável ausente = ensaio" "$OUT" "WOULD-WAKE ga-s1"; runit; eq "7 o '0' exato age" "$(wakes)" "ga-s1"

# 8) chaves de desligar, trava de instância única, import do vocabulário canônico
for k in 0 ""; do rows1; runit CONFIG_DRIFT_WAKE_ENABLED="$k"; eq "8 ENABLED='$k': nenhuma chamada" "$RC/$(wc -l < "$W/calls.log" | tr -d ' ')" "0/0"; has "8 ENABLED='$k': kill-switch" "$OUT" "kill-switch"; done
rows1; : > "$W/hq/.gc/config-drift-wake.off"; runit; eq "8 arquivo .off: nenhuma chamada" "$RC/$(wc -l < "$W/calls.log" | tr -d ' ')" "0/0"
rows1; "$PY" -c 'import fcntl,sys,time; f=open(sys.argv[1],"w"); fcntl.flock(f,2); open(sys.argv[2],"w").write("x"); time.sleep(20)' "$W/hq/.gc/config-drift-wake.lock" "$W/held" & HOLD=$!
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do [ -f "$W/held" ] && break; sleep 0.2; done
runit; eq "8 lock tomado: rc 0 sem chamadas" "$RC/$(wc -l < "$W/calls.log" | tr -d ' ')" "0/0"; has "8 lock tomado dito" "$OUT" "outra instância segura o lock"; kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null; HOLD=""
rows1; mkdir -p "$W/solo"; cp "$SCRIPT" "$W/solo/config-drift-wake.py"; OUT=$(env PYTHONDONTWRITEBYTECODE=1 GC_CITY_PATH="$W/hq" GC_BIN="$T/bin/gc" BD_BIN="$T/bin/bd" CDW_WORLD="$W" CONFIG_DRIFT_WAKE_DRY_RUN=0 "$PY" "$W/solo/config-drift-wake.py" 2>&1); RC=$?
eq "8 sem bead_state: rc 1, nada classificado" "$RC/$(wc -l < "$W/calls.log" | tr -d ' ')" "1/0"; has "8 sem bead_state: FATAL dito" "$OUT" "FATAL: bead_state não importou"

# 9) quem conta como sessão de pool (o motivo é lido da bead de sessão; onde ele mora está na seção 14)
rows1; rows "$(row ga-t1 x-1 whatsapp_automation/wa-worker asleep config-drift)" "$(row ga-t2 x-2 gastown.dog asleep config-drift)" "$(row ga-t3 wa-worker-remote-mbp-1 wa-worker-remote-mbp asleep config-drift)" \
  "$(row ga-t4 x-4 crew asleep config-drift)" '{"id":"ga-t5","session_name":"wa-worker-remote-gawispabc","alias":"x-5","state":"asleep"}' \
  "$(row ga-t6 x-6 dog-remote asleep ' Config_Drift ')" "$(row ga-t7 x-7 dog-remote asleep config-drift-x)" "$(row ga-t8 x-8 dog-remote asleep '')" '{"id":"ga-t9","alias":"x-9","template":"ps-worker","state":"asleep"}' "$(row ga-t10 x-10 dog-remote asleep 'config drift')"
sessj ga-t5 x-5 wa-worker-remote config-drift > "$W/session.ga-t5.json"; sessj ga-t9 x-9 ps-worker config-drift > "$W/session.ga-t9.json"
store hq "$(bead b1 x-1)" "$(bead b2 x-2)" "$(bead b3 wa-worker-remote-mbp-1)" "$(bead b4 x-4)" "$(bead b5 x-5)" "$(bead b6 x-6)" "$(bead b7 x-7)" "$(bead b8 x-8)" "$(bead b9 x-9)" "$(bead b10 x-10)"; runit
eq "9 template por qualificador e por nome, motivo normalizado (caixa, sublinhado, espaço); MBP/crew/outro motivo/sem motivo fora" "$(wakes)" "ga-t1 ga-t10 ga-t2 ga-t5 ga-t6 ga-t9"
rows1; runit CONFIG_DRIFT_WAKE_TEMPLATES=ps-worker; eq "9 TEMPLATES do env" "$(wakes)" ""
rows1; rows "$(row -x dog-remote-3 dog-remote asleep config-drift)" "$(row 'a b' dog-remote-3 dog-remote asleep config-drift)"; runit; eq "9 id que o gc leria como opção/texto: ninguém acorda, nenhuma leitura com ele" "$(wakes)/$(grep -c ' show -x' "$W/calls.log")/$(grep -c ' show a b' "$W/calls.log")" "/0/0"; has "9 id inaceitável dito" "$OUT" "id inaceitável"
rows1; rows "$(row 'ga-s1\n' dog-remote-3 dog-remote asleep config-drift)"; runit; eq "9 id com quebra de linha no FIM (o fim-de-linha do regex a aceitaria): ninguém acorda, nenhuma leitura com ele" "$(wakes)/$(grep -c ' show ga-s1' "$W/calls.log")" "/0"; has "9 id com quebra de linha no fim dito" "$OUT" "id inaceitável"
L100=$(printf 'a%.0s' $(seq 1 100)); L101="${L100}a"
rows1; rows "$(row "$L100" dog-remote-3 dog-remote asleep config-drift)"; runit; eq "9 id de 100 caracteres (o limite): lido na sonda e na releitura, e acorda" "$(grep -c " show $L100 " "$W/calls.log")/$(wakes | wc -w | tr -d ' ')" "2/1"
rows1; rows "$(row "$L101" dog-remote-3 dog-remote asleep config-drift)"; runit; eq "9 id de 101 caracteres: nenhuma leitura com ele" "$(grep -c " show $L101 " "$W/calls.log")" 0; has "9 id de 101 caracteres dito" "$OUT" "id inaceitável"

# 10) a bead: só `stranded` pede o dono; sem a chave de rótulos = nenhum; tipo fora de feature/bug/task/chore, dono diferente e claim do Pilot não contam
for spec in 'pilot:dispatching|["pilot:dispatching"]|claim-do-pilot' 'gate:needs-fix|["gate:needs-fix"]|estado:gate_failed' 'gate:queued|["gate:queued"]|estado:at_gate' 'story:done|["story:done"]|entregue' 'gate:passed|["gate:passed"]|entregue' 'delivery:partial|["delivery:partial"]|entregue'; do IFS='|' read -r nm lb why <<<"$spec"
  rows1; store hq "$(bead ga-b1 dog-remote-3 "$lb")"; runit; eq "10 $nm: sem wake" "$(wakes)" ""; has "10 $nm: $why" "$OUT" "$why"; done
rows1; store hq '{"id":"ga-b1","status":"in_progress","issue_type":"task","assignee":"dog-remote-3"}'; runit; eq "10 bead sem a chave labels = nenhum rótulo: acorda" "$(wakes)" "ga-s1"
rows1; store hq "$(bead ga-b1 dog-remote-3 '"x"')"; runit; eq "10 labels que não é lista: ilegível, sem wake" "$(wakes)" ""
rows1; store hq "$(bead ga-b1 dog-remote-3 '' open)"; runit; eq "10 bead não in_progress: sem wake" "$(wakes)" ""; has "10 bead não in_progress nem conta como a bead da sessão: sem-bead" "$OUT" "— sem-bead"
rows1; store hq "$(bead ga-b1 dog-remote-3 '' in_progress epic)"; runit; eq "10 tipo epic: sem wake" "$(wakes)" ""
rows1; store hq "$(bead ga-b1 dog-remote-3 '["blocked:x"]')" "$(bead ga-b2 dog-remote-3)"; runit; eq "10 duas beads: acorda pela que pede o dono" "$(wakes)/$(ncalls 'comment ga-b2')" "ga-s1/1"
rows1; store hq "$(bead ga-b1 ga-s1)"; runit; eq "10 assignee = id da sessão também casa" "$(wakes)" "ga-s1"

# 11) teto por rodada, falha do comentário, intervalo e estado do env ilegíveis voltam ao padrão (a linha start mostra o que VALE)
three; runit CONFIG_DRIFT_WAKE_MAX_PER_RUN=2; eq "11 teto 2: 2 wakes" "$(wakes)" "ga-s1 ga-s2"; has "11 ADIADA dita" "$OUT" "ADIADA ga-s3"
three; printf 1 > "$W/wake.rc"; runit CONFIG_DRIFT_WAKE_MAX_PER_RUN=2; eq "11 o teto conta o wake que falhou" "$(wakes)" "ga-s1 ga-s2"; has "11 ADIADA depois de 2 falhas" "$OUT" "ADIADA ga-s3"
three; runit CONFIG_DRIFT_WAKE_MAX_PER_RUN=2 CONFIG_DRIFT_WAKE_DRY_RUN=1; eq "11 o teto conta o ensaio" "$(grep -c 'WOULD-WAKE' <<<"$OUT")/$(grep -c 'ADIADA' <<<"$OUT")" "2/1"
rows1; printf 1 > "$W/comment.rc"; runit; eq "11 comentário falhou: o wake vale, rc 0" "$RC/$(wakes)" "0/ga-s1"; has "11 comentário falhou dito" "$OUT" "WARN: comentário em hq/ga-b1 não gravado"
for spec in 'abc|abc|abc|abc' '30|3|0|0' '-5|-5|-5|-5' '|||'; do IFS='|' read -r cd ct mx pr <<<"$spec"; rows1; runit CONFIG_DRIFT_WAKE_COOLDOWN_SEC="$cd" CONFIG_DRIFT_WAKE_CALL_TIMEOUT="$ct" CONFIG_DRIFT_WAKE_MAX_PER_RUN="$mx" CONFIG_DRIFT_WAKE_MAX_PROBES="$pr"
  has "11 env '$spec' ilegível ou abaixo do mínimo: padrão" "$OUT" "cooldown=900s max=6 reason=config-drift probes=30 call_timeout=40s"; done

# 12) lacunas que a bateria de mutantes apontou: gêmea `stopped`, id repetido e gêmea que só aparece na releitura; relógio torto; .gc inutilizável; chamada que trava; formatos de lista; comentário
rows1; rows "$(row ga-s1 dog-remote-3 dog-remote asleep config-drift)" "$(row ga-s9 dog-remote-3 dog-remote stopped '')"; runit; eq "12 gêmea stopped não impede" "$(wakes)" "ga-s1"
rows1; printf '{"sessions":[%s,%s]}' "$(row ga-s1 dog-remote-3 dog-remote asleep config-drift)" "$(row ga-s1 dog-remote-3 dog-remote asleep config-drift)" > "$W/roster.2.json"; runit; eq "12 id repetido na releitura: sem wake" "$(wakes)" ""; has "12 id repetido dito" "$OUT" "o id se repete"
rows1; printf '{"sessions":[%s,%s]}' "$(row ga-s1 dog-remote-3 dog-remote asleep config-drift)" "$(row ga-s9 dog-remote-3 dog-remote active '')" > "$W/roster.2.json"; runit; eq "12 gêmea que sobe entre as leituras: sem wake" "$(wakes)" ""; has "12 gêmea da releitura dita" "$OUT" "— gemea viva"
for body in '[]' '{"a":1}' '{"a":{"at":"x"}}' '{"a":{"at":true}}' '{"a":{}}'; do rows1; mkdir -p "$W/hq/.gc/state"; printf '%s' "$body" > "$W/hq/.gc/state/config-drift-wake.json"; runit
  eq "12 relógio $body: rc 0, sem wake, posto de lado" "$RC/$(wakes)/$(ls "$W/hq/.gc/state")" "0//config-drift-wake.json.corrupt"; done
rows1; mkdir -p "$W/hq/.gc/state"; printf '{"velha":{"at":%d}}' $((NOW-200000)) > "$W/hq/.gc/state/config-drift-wake.json"; runit; lacks "12 relógio de 2 dias cai do arquivo quando a rodada grava" "$(cat "$W/hq/.gc/state/config-drift-wake.json")" velha
rows1; : > "$W/hq/.gc/state"; runit; eq "12 .gc/state é arquivo: rc 1 sem wake" "$RC/$(wakes)" "1/"; has "12 não consigo pô-lo de lado dito" "$OUT" "não consigo pô-lo de lado"
rows1; rmdir "$W/hq/.gc"; : > "$W/hq/.gc"; runit; eq "12 .gc é arquivo: rc 1 sem chamadas" "$RC/$(wc -l < "$W/calls.log" | tr -d ' ')" "1/0"; has "12 sem lock dito" "$OUT" "NÃO roda sem a trava"
world; rows "$(row ga-s5 dog-remote-6 dog-remote active '')"; runit; eq "12 sem candidata: UMA chamada só" "$RC/$(wc -l < "$W/calls.log" | tr -d ' ')" "0/1"
rows1; runit CONFIG_DRIFT_WAKE_COOLDOWN_SEC=60 CONFIG_DRIFT_WAKE_CALL_TIMEOUT=5 CONFIG_DRIFT_WAKE_MAX_PER_RUN=1 CONFIG_DRIFT_WAKE_MAX_PROBES=1; has "12 os mínimos exatos valem" "$OUT" "cooldown=60s max=1 reason=config-drift probes=1 call_timeout=5s"
rows1; runit CONFIG_DRIFT_WAKE_TEMPLATES=" , "; eq "12 lista só de separadores volta ao padrão" "$(wakes)" "ga-s1"
rows1; rows "$(row ga-s1 dog-remote-3 dog-remote asleep idle-timeout)"; runit CONFIG_DRIFT_WAKE_REASON=Idle_Timeout; eq "12 REASON do env, normalizado" "$(wakes)" "ga-s1"; has "12 o start diz o motivo que vale" "$OUT" "reason=idle-timeout"
rows1; printf '[%s]' "$(row ga-s1 dog-remote-3 dog-remote asleep config-drift)" > "$W/roster.json"; printf '[{"name":"gascity","path":"%s/hq","hq":true}]' "$W" > "$W/rigs.json"; runit; eq "12 roster e rigs como lista pura" "$(wakes)" "ga-s1"
rows1; rows "$(row ga-s2 wa-worker-remote-2 wa-worker-remote asleep config-drift)"; store wa "$(bead wa-b2 wa-worker-remote-2)"; printf '{"rigs":[]}' > "$W/rigs.json"; runit; has "12 rigs vazio = só o HQ, e completo" "$OUT" "SKIP ga-s2 alias=wa-worker-remote-2 tpl=wa-worker-remote — sem-bead"
rows1; printf '[%s]\n1 issues\n' "$(bead ga-b1 dog-remote-3)" > "$W/store.hq.json"; printf '[%s]' "$(bead ga-b1 dog-remote-3)" > "$W/show.ga-b1.json"; runit; eq "12 linha-resumo depois do array" "$(wakes)" "ga-s1"
rows1; printf '[%s]' "$(bead outra-bead dog-remote-3)" > "$W/show.ga-b1.json"; runit; eq "12 bd show de outra bead: sem wake" "$(wakes)" ""; has "12 outra bead dita" "$OUT" "bead ilegível na releitura"
rows1; store hq '{"status":"in_progress","issue_type":"task","assignee":"dog-remote-3"}'; runit; eq "12 bead sem id: sem wake e sem queda" "$RC/$(wakes)" "0/"; has "12 bead sem id dita" "$OUT" "— sem-bead"
rows1; printf hang > "$W/roster.mode"; runit CONFIG_DRIFT_WAKE_CALL_TIMEOUT=5; eq "12 roster que trava: rc 1 sem wake" "$RC/$(wakes)" "1/"; has "12 o teto da chamada vira DEGRADED" "$OUT" "TimeoutExpired"
rows1; runit; has "12 comentário com sessão, alias, template e motivo" "$(grep ' comment ' "$W/calls.log")" 'a sessão ga-s1 (dog-remote-3, template dog-remote) estava asleep · config-drift com esta bead in_progress; `gc session wake ga-s1` emitido'; lacks "12 caminho feliz sem WARN" "$OUT" "WARN"

rows1; printf '{"sessions":["junk",7,%s]}' "$(row ga-s1 dog-remote-3 dog-remote asleep config-drift)" > "$W/roster.json"; store hq '"junk"' 7 "$(bead ga-b1 dog-remote-3)"; printf '[%s]' "$(bead ga-b1 dog-remote-3)" > "$W/show.ga-b1.json"; runit
eq "12 elemento que não é objeto, no roster e na loja, é ignorado" "$RC/$(wakes)" "0/ga-s1"
world; rows '{"id":"ga-v1","name":"nm-1","template":"dog-remote","state":"asleep"}' '{"id":"ga-v2","agent_name":"ag-1","template":"dog-remote","state":"asleep"}' "$(row ga-v3 dog-remote-9 dog-remote asleep config-drift)"
sessj ga-v1 nm-1 dog-remote config-drift > "$W/session.ga-v1.json"; sessj ga-v2 ag-1 dog-remote config-drift > "$W/session.ga-v2.json"
store hq "$(bead ga-b1 nm-1)" "$(bead ga-b2 ag-1)" "$(bead ga-b3 dog-remote-9-sess)"; runit; eq "12 o assignee casa por name, agent_name e session_name" "$(wakes)" "ga-v1 ga-v2 ga-v3"
three; rows "$(row ga-s3 dog-remote-3 dog-remote asleep config-drift)" "$(row ga-s2 dog-remote-2 dog-remote asleep config-drift)" "$(row ga-s1 dog-remote-1 dog-remote asleep config-drift)"; runit CONFIG_DRIFT_WAKE_MAX_PER_RUN=2; eq "12 o teto vale em ordem de id, não de roster" "$(wakes)" "ga-s1 ga-s2"
rows1; a=$(date -u +%H:%M); runit TZ=Asia/Tokyo; b=$(date -u +%H:%M); CM=$(grep ' comment ' "$W/calls.log"); c=$(printf '%s' "$CM" | sed 's/.*emitido às \([0-9:]*\) UTC.*/\1/')
case "$c" in "$a"|"$b") PASS=$((PASS+1));; *) fail "12 hora do comentário [$c] não é a UTC [$a..$b]";; esac; has "12 o comentário diz quando tenta de novo" "$CM" "daqui a 15 min"
has "12 o relógio guarda a bead" "$(cat "$W/hq/.gc/state/config-drift-wake.json")" '"bead": "ga-b1"'; has "12 a rodada fecha com elapsed" "$OUT" "elapsed="
rows1; rows "$(row ga-s1 'dog-remote-3\nWAKE FORGED' dog-remote asleep config-drift)"; store hq "$(bead ga-b1 'dog-remote-3\nWAKE FORGED')"; runit; eq "12 alias com quebra de linha: o log não ganha linha forjada" "$(grep -c '^WAKE FORGED' <<<"$OUT")/$(wakes)" "0/ga-s1"
rows1; store hq "$(bead 'ga-b1\nWAKE FORGED' dog-remote-3)"; runit; eq "12 id de bead com quebra de linha: não é bead que o job aceite (o id nunca chega ao bd), o log não ganha linha forjada" "$(grep -c '^WAKE FORGED' <<<"$OUT")/$(wakes)/$(ncalls ' comment ')" "0//0"; has "12 id de bead inaceitável: sem-bead" "$OUT" "— sem-bead"
rows1; rows "$(row ga-s1 "$(printf 'a%.0s' $(seq 1 200))" dog-remote asleep config-drift)"; store hq "$(bead ga-b1 "$(printf 'a%.0s' $(seq 1 200))")"; runit; lacks "12 o alias no log é cortado em 80" "$OUT" "$(printf 'a%.0s' $(seq 1 81))"
three; store hq '{"id":"ga-b1","status":"in_progress","issue_type":"task","assignee":"dog-remote-1","labels":[{"x":1}]}' "$(bead ga-b2 dog-remote-2)" "$(bead ga-b3 dog-remote-3)"; runit
eq "12 bead torta na planificação não derruba a rodada" "$RC/$(wakes)" "0/ga-s2 ga-s3"; has "12 bead torta dita" "$OUT" "SKIP ga-s1 alias=dog-remote-1 tpl=dog-remote — erro:TypeError"
rows1; printf '[{"id":"ga-b1","status":"in_progress","issue_type":"task","assignee":"dog-remote-3","labels":[{"x":1}]}]' > "$W/show.ga-b1.json"; runit; eq "12 bead torta na releitura: SKIP dito, sem wake" "$RC/$(wakes)" "0/"; has "12 bead torta da releitura dita" "$OUT" "bead=hq/ga-b1 — erro:TypeError"

rows1; printf '{"sessions":[%s]}' "$(row ga-s1 dog-remote-3 dog-remote asleep config-drift true)" > "$W/roster.2.json"; runit; eq "12 sessão fechada na releitura: sem wake" "$(wakes)" ""; has "12 fechada na releitura dita" "$OUT" "a sessão mudou: fechada"
rows1; mkdir -p "$W/hq/.gc/state"; printf '{"ga-s1":{"at":%d,"bead":"ga-b1"}}' $((NOW+5000)) > "$W/hq/.gc/state/config-drift-wake.json"; runit; eq "12 carimbo do futuro (dentro de 24 h, fora do intervalo) não segura" "$(wakes)" "ga-s1"
rows1; printf '%s\n' '#!/bin/sh' 'exit 3' > "$T/bin/gc3"; chmod +x "$T/bin/gc3"; runit GC_BIN="$T/bin/gc3"; eq "12 gc que sai com 3: rc 1, sem wake" "$RC/$(wakes)" "1/"
if [ "$(id -u)" = 0 ]; then echo "SKIP: relógio que grava e não relê (root lê tudo)"; else rows1; mkdir -p "$W/hq/.gc/state"; printf 0 > "$W/roster.n"; U=$(umask); umask 777; runit; umask "$U"
  eq "12 relógio que grava mas não relê igual: rc 1, sem wake" "$RC/$(wakes)" "1/"; has "12 não confere na releitura dito" "$OUT" "não confere na releitura"; fi

# 13) o plist-fonte e o script falam do mesmo job (o que o launchd vai rodar, com os tetos que as leituras lentas pedem)
"$PY" - "$HERE/com.gascity.config-drift-wake.plist" > "$T/plist.out" 2>&1 <<'EOF'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb")); e = p["EnvironmentVariables"]; iv = p["StartInterval"]
checks = [("label", p["Label"] == "com.gascity.config-drift-wake"), ("script", p["ProgramArguments"][1].endswith("/scripts/config-drift-wake.py")),
          ("fora do degrau de 300 s", isinstance(iv, int) and iv % 300 != 0 and iv > 120), ("batimento no .out", p["StandardOutPath"].endswith("/.gc/logs/config-drift-wake.out")),
          ("teto de chamada entre a latência medida e o intervalo", 90 <= int(e["CONFIG_DRIFT_WAKE_CALL_TIMEOUT"]) < iv), ("age (0 exato)", e["CONFIG_DRIFT_WAKE_DRY_RUN"] == "0"),
          ("cidade", e["GC_CITY_PATH"].endswith("/.gascity-gastown-hq")), ("sem KeepAlive", "KeepAlive" not in p)]
for name, ok in checks:
    print(("ok " if ok else "BAD ") + name)
EOF
case "$(cat "$T/plist.out")" in *BAD*|*Traceback*|"") fail "13 plist-fonte: $(cat "$T/plist.out")";; *) PASS=$((PASS+1));; esac

# 14) gate-fix (ga-wo99v8w, gate ga-99a733q): o motivo do sono mora na BEAD DE SESSÃO (`bd show <id>`, metadata.sleep_reason), NÃO na linha do roster. O fixture da 1ª entrega punha a chave do motivo em toda linha fake: o teste passava por construção e o job real não via nada.
# 14a) os fixtures têm a forma REAL: a linha do roster com as 20 chaves que o revisor leu ao vivo (nenhuma de motivo) e a bead de sessão com o motivo em metadata
rows1; "$PY" - "$W/roster.json" "$W/session.ga-s1.json" > "$T/shape.out" 2>&1 <<'EOF'
import json, sys
r, b = json.load(open(sys.argv[1]))["sessions"][0], json.load(open(sys.argv[2]))[0]
real = set("agent_name alias attached closed command created_at id last_active last_nudge_delivered_at name provider resume_flag resume_style rig session_key session_name state template title work_dir".split())
print("ok" if set(r) == real else "BAD chaves da linha: %s" % sorted(set(r) ^ real))
print("ok" if not any(k in r for k in ("sleep_reason", "reason", "metadata", "state_reason")) else "BAD motivo na linha do roster")
print("ok" if b["issue_type"] == "session" and b["metadata"]["sleep_reason"] == "config-drift" and b["metadata"]["state"] == "asleep" else "BAD bead de sessão")
EOF
eq "14a fixtures na forma real: linha sem motivo, motivo na bead de sessão" "$(tr '\n' ' ' < "$T/shape.out")" "ok ok ok "
# 14b) a bead de sessão REAL (ga-wisp-aveig, `bd show --json` ao vivo em 12/11; sem command, core_hash_breakdown, instance_token, session_key e work_dir): `drained` não acorda; a mesma bead com `config-drift` acorda
cat > "$T/aveig.json" <<'EOF'
[{"id":"ga-wisp-aveig","title":"Pool top-up: x","status":"open","priority":2,"issue_type":"session","created_at":"2026-11-12T18:43:57Z","updated_at":"2026-11-12T19:09:49Z","metadata":{"agent_name":"ps-worker","alias":"ps-worker","alias_history":"","builtin_ancestor":"claude","churn_count":"0","command":"<removido>","continuation_epoch":"1","continuation_reset_pending":"true","core_hash_breakdown":"<removido>","creation_complete_at":"2026-11-12T19:00:03Z","detached_at":"","drain_at":"2026-11-12T19:03:07Z","effective_sleep_after_idle":"off","generation":"2","held_until":"","instance_token":"<removido>","last_nudge_delivered_at":"2026-11-12T19:00:29Z","last_woke_at":"","live_hash":"","pending_create_claim":"","pending_create_started_at":"","provider":"claude-headless","provider_kind":"claude","quarantined_until":"","requested_sleep_after_idle":"off","resume_command":"","resume_flag":"--resume","resume_style":"flag","session_key":"<removido>","session_name":"ps-worker-gawispaveig","session_origin":"manual","sleep_capability":"full","sleep_intent":"","sleep_policy_fingerprint":"value=off|class=interactive_fresh|source=legacy_off|wake=fresh|cap=full|deps=|template=ps-worker","sleep_policy_source":"legacy_off","sleep_reason":"drained","started_config_hash":"","started_live_hash":"","startup_dialog_verified":"","state":"asleep","state_reason":"","synced_at":"2026-11-12T19:08:32Z","template":"ps-worker","wait_hold":"","wake_attempts":"0","wake_mode":"fresh","wake_request":"","wake_requested_at":"","work_dir":"<removido>"},"no_history":true,"labels":["gc:session","template:ps-worker"],"dependent_count":0,"dependency_count":0,"comment_count":0,"revision":974979435893204583}]
EOF
world; rows "$(row ga-wisp-aveig ps-worker ps-worker asleep drained)"; cp "$T/aveig.json" "$W/session.ga-wisp-aveig.json"; store hq "$(bead ga-b1 ps-worker)"; runit
eq "14b bead real com sleep_reason=drained: sem wake, rc 0" "$RC/$(wakes)" "0/"; has "14b o motivo lido da bead real aparece no census" "$OUT" "pool_asleep=1 com_motivo=1 candidatas=0 motivos=drained:1"
world; rows "$(row ga-wisp-aveig ps-worker ps-worker asleep drained)"; sed 's/"sleep_reason":"drained"/"sleep_reason":"config-drift"/' "$T/aveig.json" > "$W/session.ga-wisp-aveig.json"; store hq "$(bead ga-b1 ps-worker)"; runit
eq "14b a mesma bead real com sleep_reason=config-drift acorda" "$RC/$(wakes)" "0/ga-wisp-aveig"
# 14c) cego: sessão de pool asleep na linha, mas nenhuma bead de sessão traz motivo legível = rc 1 e WARN (antes: rc 0, batimento fresco e o job cego para sempre)
world; rows "$(row ga-s1 dog-remote-1 dog-remote asleep config-drift)" "$(row ga-s2 dog-remote-2 dog-remote asleep config-drift)"; store hq "$(bead ga-b1 dog-remote-1)" "$(bead ga-b2 dog-remote-2)"
for s in ga-s1 ga-s2; do printf '[{"id":"%s","issue_type":"session","metadata":{"state":"asleep","state_reason":"","sleep_intent":""}}]' "$s" > "$W/session.$s.json"; done; runit
eq "14c a bead de sessão sem a chave do motivo: rc 1, sem wake" "$RC/$(wakes)" "1/"
has "14c cego dito" "$OUT" "WARN BEAD-SEM-MOTIVO: nenhuma das 2 sessões de pool asleep"; has "14c census" "$OUT" "pool_asleep=2 com_motivo=0 candidatas=0 motivos=sem-motivo:2"
for s in ga-s1 ga-s2; do printf fail > "$W/session.$s.mode"; sessj $s x dog-remote config-drift > "$W/session.$s.json"; done; : > "$W/calls.log"; runit
eq "14c bd show da sessão falha em todas: rc 1, sem wake" "$RC/$(wakes)" "1/"; has "14c census nao-sei" "$OUT" "pool_asleep=2 com_motivo=0 candidatas=0 motivos=nao-sei:2"; has "14c cego dito (falha)" "$OUT" "WARN BEAD-SEM-MOTIVO"
printf ok > "$W/session.ga-s1.mode"; sessj ga-s1 dog-remote-1 dog-remote drained > "$W/session.ga-s1.json"; : > "$W/calls.log"; runit
eq "14c uma legível (outro motivo) e uma ilegível: rc 0, não é cegueira" "$RC/$(wakes)" "0/"; has "14c census misto" "$OUT" "pool_asleep=2 com_motivo=1 candidatas=0 motivos=drained:1,nao-sei:1"; lacks "14c sem WARN de cegueira" "$OUT" "BEAD-SEM-MOTIVO"
# 14d) o roster não é a fonte: chave de motivo na LINHA (a forma que a 1ª entrega inventou) é ignorada; manda a bead de sessão
world; rows '{"id":"ga-s1","alias":"dog-remote-1","template":"dog-remote","state":"asleep","closed":false,"sleep_reason":"config-drift","reason":"config-drift","metadata":{"sleep_reason":"config-drift"}}'; sessj ga-s1 dog-remote-1 dog-remote drained > "$W/session.ga-s1.json"; store hq "$(bead ga-b1 dog-remote-1)"; runit
eq "14d motivo na linha do roster é ignorado: a bead de sessão diz drained" "$(wakes)" ""; has "14d o census conta o motivo da bead" "$OUT" "motivos=drained:1"
# 14e) a leitura da bead de sessão tem três estados: falhou/lixo/vazio/trava, OUTRA bead, sem metadata, metadata torta, bead inexistente = não sei (sem wake); motivo de tipo estranho = sem motivo
for m in fail garbage empty; do rows1; printf '%s' "$m" > "$W/session.ga-s1.mode"; runit; eq "14e bd show da sessão ($m): sem wake, rc 1" "$RC/$(wakes)" "1/"; has "14e ($m) nao-sei" "$OUT" "motivos=nao-sei:1"; done
rows1; printf hang > "$W/session.ga-s1.mode"; runit CONFIG_DRIFT_WAKE_BD_TIMEOUT=5; eq "14e bd show da sessão que trava: sem wake, rc 1" "$RC/$(wakes)" "1/"; has "14e o teto da chamada vira WARN" "$OUT" "TimeoutExpired"
for body in "[$(bead outra-bead dog-remote-3)]" '[{"id":"ga-s1"}]' '[{"id":"ga-s1","metadata":"x"}]' '[{"id":"ga-s1","metadata":null}]' '{"id":"ga-s1"}' '[]'; do rows1; printf '%s' "$body" > "$W/session.ga-s1.json"; runit; eq "14e corpo $body: sem wake" "$(wakes)" ""; has "14e corpo $body: não sei" "$OUT" "motivos=nao-sei:1"; done
rows1; rm -f "$W/session.ga-s1.json"; runit; eq "14e bead de sessão inexistente: sem wake" "$(wakes)" ""; has "14e inexistente: não sei" "$OUT" "motivos=nao-sei:1"
rows1; printf '[{"id":"ga-s1","metadata":{"sleep_reason":5}}]' > "$W/session.ga-s1.json"; runit; eq "14e motivo que não é texto: sem wake, e é sem-motivo (a bead respondeu)" "$(wakes)" ""; has "14e sem-motivo" "$OUT" "motivos=sem-motivo:1"
ESC=$(printf '\\u%04x' 27); rows1; sessj ga-s1 dog-remote-3 dog-remote "x${ESC}[31mred" > "$W/session.ga-s1.json"; runit; has "14e o motivo da bead é texto de fora: o census o sanea (o ESC vira ?)" "$OUT" "motivos=x??31mred:1"
# 14f) a releitura antes de agir lê a bead de sessão DE NOVO: motivo que mudou, leitura que falha ou devolve OUTRA bead = sem wake
rows1; sessj ga-s1 dog-remote-3 dog-remote drained > "$W/session.ga-s1.2.json"; runit; eq "14f o motivo mudou entre as leituras: sem wake" "$(wakes)" ""; has "14f dito" "$OUT" "bead=hq/ga-b1 — a sessão mudou: motivo:drained"
rows1; sessj ga-s1 dog-remote-3 dog-remote '' > "$W/session.ga-s1.2.json"; runit; eq "14f a releitura veio sem motivo: sem wake" "$(wakes)" ""; has "14f dito" "$OUT" "bead=hq/ga-b1 — a sessão mudou: sem-motivo"
rows1; printf fail > "$W/session.ga-s1.2.mode"; runit; eq "14f a releitura da bead de sessão falhou: sem wake" "$(wakes)" ""; has "14f dito" "$OUT" "bead=hq/ga-b1 — bead de sessão ilegível na releitura"
rows1; printf '[%s]' "$(bead outra-bead dog-remote-3)" > "$W/session.ga-s1.2.json"; runit; eq "14f a releitura devolve OUTRA bead: sem wake" "$(wakes)" ""; has "14f dito" "$OUT" "bead de sessão ilegível na releitura"
# 14g) teto de leituras por rodada (CONFIG_DRIFT_WAKE_MAX_PROBES, 30): o que passa dele é "não sei", dito, nunca "sem motivo"
world; R=(); for i in $(seq 31 -1 1); do R+=("$(row "$(printf 'ga-p%02d' "$i")" "dog-remote-$i" dog-remote asleep idle-timeout)"); done; rows "${R[@]}"; runit   # o roster vem em ordem DECRESCENTE: o teto corta pelo id, não pela ordem do roster
eq "14g 31 sessões de pool asleep: 30 leituras de bead de sessão e 1 de roster" "$(grep -c ' show ga-p' "$W/calls.log")/$(ncalls 'session list')" "30/1"
eq "14g o teto corta o último id (ga-p31), não o último do roster" "$(ncalls ' show ga-p31 ')/$(ncalls ' show ga-p01 ')" "0/1"
has "14g o que passou do teto é dito" "$OUT" "WARN: 1 sessões de pool asleep além do teto de 30 leituras"; has "14g census" "$OUT" "pool_asleep=31 com_motivo=30 candidatas=0 motivos=idle-timeout:30,nao-sei:1"
: > "$W/calls.log"; runit CONFIG_DRIFT_WAKE_MAX_PROBES=2; eq "14g MAX_PROBES do env" "$(grep -c ' show ga-p' "$W/calls.log")" 2; has "14g o teto do env conta o que passou" "$OUT" "WARN: 29 sessões de pool asleep além do teto de 2 leituras"
# 14g') id que não é texto numa linha de pool asleep (lista, número): dito, sem queda, sem leitura
world; rows '{"id":["x"],"alias":"dog-remote-1","template":"dog-remote","state":"asleep"}' '{"id":7,"alias":"dog-remote-2","template":"dog-remote","state":"asleep"}'; runit
eq "14g' id que não é texto: rc 1 (cego), sem wake, só o roster foi lido" "$RC/$(wakes)/$(wc -l < "$W/calls.log" | tr -d ' ')" "1//1"; has "14g' census" "$OUT" "pool_asleep=2 com_motivo=0 candidatas=0 motivos=nao-sei:2"; eq "14g' um aviso por id que não é texto (lista e número)" "$(grep -c 'id inaceitável' <<<"$OUT")" 2
# 14h) id de bead que o bd leria como opção (`-x`) nunca vira argumento de `bd show` nem de `bd comment`
rows1; store hq "$(bead -x dog-remote-3)"; runit; eq "14h bead com id -x: sem wake e nenhuma chamada com ele" "$(wakes)/$(grep -c ' -x' "$W/calls.log")" "/0"; has "14h dito" "$OUT" "— sem-bead"
rows1; store hq "$(bead 'ga-b1\n' dog-remote-3)"; runit; eq "14h bead com id terminado em quebra de linha: sem wake e sem comentário" "$(wakes)/$(ncalls ' comment ')" "/0"; has "14h dito" "$OUT" "— sem-bead"
# 14i) o custo da rodada: sem pool asleep = só o roster; pool asleep sem candidata = roster + UMA leitura de bead de sessão por sessão (sem rig list nem bd list); ativa, fora do pool e fechada não são lidas
world; rows "$(row ga-s5 dog-remote-6 dog-remote active '')" "$(row ga-s6 mila-wa mila-wa asleep config-drift)" "$(row ga-s8 dog-remote-7 dog-remote asleep config-drift true)"; runit; eq "14i ativa, fora do pool e fechada: só o roster" "$RC/$(wc -l < "$W/calls.log" | tr -d ' ')" "0/1"
world; rows "$(row ga-s4 dog-remote-5 dog-remote asleep idle-timeout)"; runit; eq "14i pool asleep sem candidata: roster + 1 leitura da bead de sessão" "$RC/$(wc -l < "$W/calls.log" | tr -d ' ')/$(ncalls ' show ga-s4 --json')" "0/2/1"

echo "config-drift-wake.selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
