#!/usr/bin/env bash
# hetzner-fw-ip-watch.selftest.sh — hermético: curl e gc são stubs; a cidade é um diretório temporário; nada fala com a rede nem com o mail de verdade. (ga-1h1b7vq)
#
# Contents
#   Casos · Controle negativo · Como rodar
#
# CASOS  igual · diferente (mail, cooldown, IP novo, mail que falha) · não sei (fonte cai, discorda, resposta que não é IP, IP privado, timeout) · cegueira (N falhas seguidas, cooldown, zera com leitura boa)
#   · episódio (voltou ao liberado e desviou de novo avisa na hora) · --ack · --dry-run · estado corrompido · instância única · aviso desligado · configuração inválida · plist
# CONTROLE NEGATIVO  cada mutante (um trecho literal do script trocado, que tem de existir UMA vez) TEM de reprovar a suíte; mutante que passa = teste que não pega o bug.
#   Cada um roda sob `ulimit -f` (teto de escrita por arquivo, ga-e6ug8gq) e a suíte dele pula os casos lentos (HFW_FAST=1).
# COMO RODAR  hetzner-fw-ip-watch.selftest.sh   (HFW_UNDER_TEST=<script> roda a suíte contra outra cópia · HFW_NO_MUTANTS=1 pula o controle negativo · HFW_FAST=1 pula timeout e instância única)
#   exit 0 = tudo verde · 1 = algum caso ou mutante reprovou
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="${HFW_UNDER_TEST:-$HERE/hetzner-fw-ip-watch.py}"
PLIST="$HERE/com.gascity.hetzner-fw-ip-watch.plist"
[ -f "$WATCH" ] || { echo "FATAL: $WATCH não existe — não há o que testar" >&2; exit 2; }
T=$(mktemp -d "${TMPDIR:-/tmp}/hfw-selftest.XXXXXX")
trap 'kill $(jobs -p) 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
mkdir -p "$T/bin" "$T/stub" "$T/city/.gc"
export PYTHONDONTWRITEBYTECODE=1

fails=0; n=0
ok()  { n=$((n+1)); [ "${QUIET:-0}" = 1 ] || echo "ok   $1"; }
bad() { n=$((n+1)); fails=$((fails+1)); echo "FAIL $1"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1: esperado '$2', veio '$3'"; fi; }
has()  { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1: '$2' ausente em: $(printf '%s' "$3" | head -c 400)" ;; esac; }
hasnt(){ case "$3" in *"$2"*) bad "$1: '$2' presente em: $(printf '%s' "$3" | head -c 400)" ;; *) ok "$1" ;; esac; }

# ---- stubs -------------------------------------------------------------------------------------------------------------------------------------------
cat > "$T/bin/curl" <<'EOF'
#!/bin/sh
# stub: a resposta de cada fonte vem de $STUB/curl.<host>: 1ª linha "body <texto>" | "rc <n>" | "sleep <s>"
for a; do url="$a"; done
host=${url#*//}; host=${host%%/*}
f="$STUB/curl.$host"
[ -f "$f" ] || exit 7
IFS= read -r line < "$f"
mode=${line%% *}; rest=${line#* }
case "$mode" in
  body) printf '%s' "$rest" ;;
  rc) exit "$rest" ;;
  sleep) sleep "$rest" ;;
esac
EOF
cat > "$T/bin/gc" <<'EOF'
#!/bin/sh
# stub: registra cada chamada de `mail send` (uma linha CALL + assunto + corpo) e sai com o rc de $STUB/gc.rc (padrão 0)
{ echo "CALL $*" | cut -c1-400; } >> "$STUB/gc.log"
[ -f "$STUB/gc.rc" ] && exit "$(cat "$STUB/gc.rc")"
exit 0
EOF
chmod +x "$T/bin/curl" "$T/bin/gc"
export STUB="$T/stub"

NOW=1794890000
H1=api.ipify.org; H2=ifconfig.me
LIBERADO=179.197.107.78
NOVO=200.100.50.25
NOVO2=201.2.3.4

reset()  { find "$T/stub" "$T/city/.gc" -mindepth 1 -delete 2>/dev/null; mkdir -p "$T/city/.gc"; }
src()    { printf '%s\n' "$2" > "$STUB/curl.$1"; }
both()   { src "$H1" "body $1"; src "$H2" "body $1"; }
W()      { env GC_CITY_PATH="$T/city" GC_BIN="$T/bin/gc" CURL_BIN="$T/bin/curl" HETZNER_FW_IP_NOW="${NOW_OVERRIDE:-$NOW}" "$@" python3 -B "$WATCH" $WARGS; }
run()    { out=$(W "$@" 2>"$T/err"); rc=$?; err=$(cat "$T/err"); }
calls()  { if [ -f "$STUB/gc.log" ]; then grep -c '^CALL' "$STUB/gc.log"; else echo 0; fi; }
sget()   { python3 -B -c 'import json,sys; v=json.load(open(sys.argv[1]))[sys.argv[2]]; print("null" if v is None else v)' "$T/city/.gc/hetzner-fw-ip.state.json" "$1"; }

# ---- igual ---------------------------------------------------------------------------------------------------------------------------------------------
reset; both "$LIBERADO"; WARGS=""; run
eq "igual: rc" 0 "$rc"; has "igual: estado" "estado=igual" "$out"; eq "igual: nenhum mail" 0 "$(calls)"
eq "igual: seen_ip gravado" "$LIBERADO" "$(sget seen_ip)"; eq "igual: falhas 0" 0 "$(sget fails)"
both "$LIBERADO"; printf 'body %s\n' "$LIBERADO
" > "$STUB/curl.$H1"; run
has "igual: resposta com quebra de linha final vale" "estado=igual" "$out"

# ---- diferente -----------------------------------------------------------------------------------------------------------------------------------------
reset; both "$NOVO"; run
has "diferente: estado" "estado=diferente" "$out"; has "diferente: alarme enviado" "alarme=enviado" "$out"; eq "diferente: 1 mail" 1 "$(calls)"
has "diferente: vai ao mayor por mail send" "mail send mayor" "$(cat "$STUB/gc.log")"; has "diferente: assunto traz o IP novo" "$NOVO" "$(cat "$STUB/gc.log")"
eq "diferente: liberado NÃO muda sozinho" "$LIBERADO" "$(sget allowed_ip)"; eq "diferente: alarm_ip gravado" "$NOVO" "$(sget alarm_ip)"
NOW_OVERRIDE=$((NOW+600)) run; has "cooldown: 10 min depois não repete" "alarme=cooldown" "$out"; eq "cooldown: ainda 1 mail" 1 "$(calls)"
NOW_OVERRIDE=$((NOW+10799)) run; has "cooldown: 1 s antes do fim não repete" "alarme=cooldown" "$out"; eq "cooldown: ainda 1 mail (borda)" 1 "$(calls)"
NOW_OVERRIDE=$((NOW+10800)) run; has "cooldown: no fim repete" "alarme=enviado" "$out"; eq "cooldown: 2 mails" 2 "$(calls)"
both "$NOVO2"; NOW_OVERRIDE=$((NOW+10860)) run; has "IP novo avisa na hora, sem esperar o cooldown" "alarme=enviado" "$out"; eq "IP novo: 3 mails" 3 "$(calls)"

# mail que falha não gasta o cooldown
reset; both "$NOVO"; echo 1 > "$STUB/gc.rc"; run
has "mail falha: dito na linha" "alarme=mail-falhou" "$out"; eq "mail falha: rc 0 (o vigia não cai)" 0 "$rc"; eq "mail falha: alarm_epoch NÃO gravado" null "$(sget alarm_epoch)"
find "$STUB" -name gc.rc -delete; NOW_OVERRIDE=$((NOW+600)) run
has "mail falha: a rodada seguinte tenta de novo" "alarme=enviado" "$out"; eq "mail falha: 2 chamadas no total" 2 "$(calls)"

# voltou ao liberado e desviou de novo: episódio novo, avisa na hora
reset; both "$NOVO"; run; both "$LIBERADO"; NOW_OVERRIDE=$((NOW+600)) run
has "episódio: voltou ao liberado" "estado=igual" "$out"; eq "episódio: alarm_ip limpo" null "$(sget alarm_ip)"
both "$NOVO"; NOW_OVERRIDE=$((NOW+1200)) run; has "episódio: desviou de novo avisa na hora (dentro do cooldown antigo)" "alarme=enviado" "$out"; eq "episódio: 2 mails" 2 "$(calls)"

# ---- não sei -------------------------------------------------------------------------------------------------------------------------------------------
reset; both "$LIBERADO"; run; src "$H1" "rc 22"; src "$H2" "body $NOVO"; NOW_OVERRIDE=$((NOW+600)) run
has "fonte cai: não sei" "estado=nao-sei" "$out"; hasnt "fonte cai: NÃO vira diferente" "estado=diferente" "$out"; eq "fonte cai: nenhum mail" 0 "$(calls)"
eq "fonte cai: seen_ip intacto" "$LIBERADO" "$(sget seen_ip)"; eq "fonte cai: falhas 1" 1 "$(sget fails)"; has "fonte cai: motivo" "fonte-sem-resposta(curl-falhou)" "$out"
src "$H1" "body $NOVO"; src "$H2" "body $NOVO2"; NOW_OVERRIDE=$((NOW+1200)) run
has "fontes discordam: não sei" "fontes-discordam" "$out"; eq "fontes discordam: nenhum mail" 0 "$(calls)"; eq "fontes discordam: falhas 2" 2 "$(sget fails)"
both "$LIBERADO"; NOW_OVERRIDE=$((NOW+1500)) run   # leitura boa zera a contagem: as 3 falhas seguidas de cima não viram o mail de cegueira aqui
src "$H1" "body <html>captive portal</html>"; src "$H2" "body $NOVO"; NOW_OVERRIDE=$((NOW+1800)) run
has "resposta que não é IP: não sei" "resposta-invalida" "$out"; eq "resposta que não é IP: nenhum mail" 0 "$(calls)"
both "192.168.1.5"; NOW_OVERRIDE=$((NOW+2400)) run; has "IP privado: não sei" "resposta-invalida" "$out"
both "127.0.0.1"; NOW_OVERRIDE=$((NOW+3000)) run; has "loopback: não sei" "resposta-invalida" "$out"
both "2001:4860:4860::8888"; NOW_OVERRIDE=$((NOW+3600)) run; has "IPv6: não sei" "resposta-invalida" "$out"
both ""; printf 'body \n' > "$STUB/curl.$H1"; printf 'body \n' > "$STUB/curl.$H2"; NOW_OVERRIDE=$((NOW+4200)) run; has "resposta vazia: não sei (vazio ≠ igual)" "estado=nao-sei" "$out"
big=$(python3 -B -c 'print("9"*100)'); both "$big"; NOW_OVERRIDE=$((NOW+4800)) run; has "resposta enorme: não sei" "resposta-grande" "$out"
rm_stub() { find "$STUB" -name 'curl.*' -delete; }
rm_stub; NOW_OVERRIDE=$((NOW+5400)) run; has "curl ausente de fonte (rc 7): não sei" "estado=nao-sei" "$out"

# ---- cegueira ------------------------------------------------------------------------------------------------------------------------------------------
reset; src "$H1" "rc 6"; src "$H2" "rc 6"
run; hasnt "cegueira: 1ª falha não avisa" "cego-enviado" "$out"; NOW_OVERRIDE=$((NOW+600)) run; hasnt "cegueira: 2ª falha não avisa" "cego-enviado" "$out"; eq "cegueira: ainda 0 mails" 0 "$(calls)"
NOW_OVERRIDE=$((NOW+1200)) run; has "cegueira: 3ª falha seguida avisa" "alarme=cego-enviado" "$out"; eq "cegueira: 1 mail" 1 "$(calls)"; has "cegueira: o assunto diz que é o vigia cego" "cego" "$(cat "$STUB/gc.log")"
NOW_OVERRIDE=$((NOW+1800)) run; has "cegueira: 4ª falha dentro do cooldown não repete" "alarme=-" "$out"; eq "cegueira: ainda 1 mail" 1 "$(calls)"
NOW_OVERRIDE=$((NOW+1200+21600)) run; has "cegueira: cooldown de 6 h vencido avisa de novo" "alarme=cego-enviado" "$out"; eq "cegueira: 2 mails" 2 "$(calls)"
both "$LIBERADO"; NOW_OVERRIDE=$((NOW+30000)) run; eq "cegueira: leitura boa zera a contagem" 0 "$(sget fails)"
src "$H1" "rc 6"; src "$H2" "rc 6"; NOW_OVERRIDE=$((NOW+30600)) run; NOW_OVERRIDE=$((NOW+31200)) run; eq "cegueira: depois do zero, 2 falhas não avisam" 2 "$(calls)"
reset; src "$H1" "rc 6"; src "$H2" "rc 6"; echo 1 > "$STUB/gc.rc"; run; NOW_OVERRIDE=$((NOW+600)) run; NOW_OVERRIDE=$((NOW+1200)) run
has "cegueira: mail que falha é dito" "cego-mail-falhou" "$out"; eq "cegueira: mail que falha não grava o cooldown" null "$(sget blind_alarm_epoch)"

# ---- --ack ---------------------------------------------------------------------------------------------------------------------------------------------
reset; both "$NOVO"; run; WARGS="--ack"; run
eq "ack sem IP: rc" 0 "$rc"; has "ack sem IP: grava o IP lido" "$LIBERADO -> $NOVO" "$out"; eq "ack: liberado atualizado" "$NOVO" "$(sget allowed_ip)"; eq "ack: alarm_ip limpo" null "$(sget alarm_ip)"
WARGS=""; NOW_OVERRIDE=$((NOW+600)) run; has "ack: a rodada seguinte é igual" "estado=igual" "$out"; eq "ack: sem mail novo" 1 "$(calls)"
WARGS="--ack $NOVO2"; run; eq "ack com IP: grava" "$NOVO2" "$(sget allowed_ip)"
WARGS="--ack 10.0.0.1"; run; eq "ack com IP privado: rc 3" 3 "$rc"; eq "ack recusado não muda o liberado" "$NOVO2" "$(sget allowed_ip)"
WARGS="--ack banana"; run; eq "ack com lixo: rc 3" 3 "$rc"
reset; src "$H1" "rc 6"; src "$H2" "rc 6"; WARGS="--ack"; run; eq "ack sem IP e sem leitura: rc 3 (não adivinha)" 3 "$rc"; has "ack sem leitura: diz por quê" "não consegui ler" "$err"
[ -f "$T/city/.gc/hetzner-fw-ip.state.json" ] && bad "ack sem leitura: não criou estado" || ok "ack sem leitura: não criou estado"

# ---- --dry-run e --print -------------------------------------------------------------------------------------------------------------------------------
reset; both "$NOVO"; WARGS="--dry-run"; run
has "dry-run: diz que avisaria" "alarme=dry-run" "$out"; eq "dry-run: nenhum mail" 0 "$(calls)"; [ -f "$T/city/.gc/hetzner-fw-ip.state.json" ] && bad "dry-run: não grava estado" || ok "dry-run: não grava estado"
WARGS=""; run; WARGS="--print"; run; has "print: mostra o estado" "\"allowed_ip\": \"$LIBERADO\"" "$out"

# ---- estado corrompido ---------------------------------------------------------------------------------------------------------------------------------
reset; both "$LIBERADO"; echo '{"v": 1, "allowed_ip": "banana"' > "$T/city/.gc/hetzner-fw-ip.state.json"; WARGS=""; run
eq "corrompido: rc 0" 0 "$rc"; has "corrompido: recomeça da semente" "estado=igual" "$out"; has "corrompido: avisa no stderr" "corrompido" "$err"
ls "$T/city/.gc" | grep -q 'state.json.corrupt-' && ok "corrompido: a cópia ficou" || bad "corrompido: a cópia ficou"
echo '{"v": 1, "allowed_ip": "10.1.1.1", "fails": 0}' > "$T/city/.gc/hetzner-fw-ip.state.json"; run; has "liberado privado no estado: corrompido, recomeça" "corrompido" "$err"
echo '{"v": 1, "allowed_ip": "'"$LIBERADO"'", "fails": 0, "seen_epoch": "ontem"}' > "$T/city/.gc/hetzner-fw-ip.state.json"; run; has "epoch que não é inteiro: corrompido" "corrompido" "$err"
echo '[1,2]' > "$T/city/.gc/hetzner-fw-ip.state.json"; run; has "JSON que não é objeto: corrompido" "corrompido" "$err"

# estado ilegível (sem permissão de leitura) = não sei: não decide, não manda mail, não mexe no arquivo, sai com rc 3
reset; both "$NOVO"; WARGS=""; run; before=$(cat "$T/city/.gc/hetzner-fw-ip.state.json")
chmod 000 "$T/city/.gc/hetzner-fw-ip.state.json"; NOW_OVERRIDE=$((NOW+600)) run; chmod 600 "$T/city/.gc/hetzner-fw-ip.state.json"
eq "estado ilegível: rc 3" 3 "$rc"; has "estado ilegível: diz o que não conseguiu" "não consegui ler" "$err"; eq "estado ilegível: nenhum mail novo (o 1 é da 1ª rodada)" 1 "$(calls)"
[ "$before" = "$(cat "$T/city/.gc/hetzner-fw-ip.state.json")" ] && ok "estado ilegível: o arquivo não foi tocado" || bad "estado ilegível: o arquivo foi alterado"; hasnt "estado ilegível: não vira estado de semente" "estado=" "$out"
ls "$T/city/.gc" | grep -q 'state.json.corrupt-' && bad "estado ilegível: não guarda cópia de corrompido" || ok "estado ilegível: não guarda cópia de corrompido"

# ---- aviso desligado e configuração --------------------------------------------------------------------------------------------------------------------
reset; both "$NOVO"; WARGS=""; run HETZNER_FW_IP_ALARM=0
has "aviso desligado: mede e diz" "alarme=desligado" "$out"; eq "aviso desligado: nenhum mail" 0 "$(calls)"
run HETZNER_FW_IP_SOURCES=https://api.ipify.org; eq "1 fonte só: configuração inválida (rc 3)" 3 "$rc"; has "1 fonte só: diz por quê" "2 fontes" "$err"
run HETZNER_FW_IP_ALLOWED=10.0.0.1; eq "liberado privado na config: rc 3" 3 "$rc"
run HETZNER_FW_IP_BLIND_AFTER=0; eq "BLIND_AFTER=0: rc 3" 3 "$rc"
reset; both "$NOVO"; run HETZNER_FW_IP_ALLOWED=$NOVO; has "liberado por ambiente (semente, 1ª rodada)" "estado=igual" "$out"
run HETZNER_FW_IP_ALLOWED=9.9.9.9; has "semente do ambiente não vale depois da 1ª rodada (manda o estado)" "estado=igual" "$out"
reset; both "$LIBERADO"; run HETZNER_FW_IP_COOLDOWN_S=60 HETZNER_FW_IP_ALLOWED=9.9.9.9; has "semente 9.9.9.9 ≠ IP lido: diferente" "estado=diferente" "$out"

# ---- timeout e instância única (lentos) ----------------------------------------------------------------------------------------------------------------
if [ "${HFW_FAST:-0}" != 1 ]; then
  reset; src "$H1" "sleep 30"; src "$H2" "body $NOVO"; t0=$(date +%s); run HETZNER_FW_IP_CURL_TIMEOUT_S=1; t1=$(date +%s)
  has "curl que trava: não sei, não pendura" "fonte-sem-resposta(timeout)" "$out"; [ $((t1-t0)) -lt 20 ] && ok "curl que trava: terminou em $((t1-t0)) s" || bad "curl que trava: levou $((t1-t0)) s"
  reset; both "$LIBERADO"
  python3 -B -c 'import fcntl,os,sys,time
fd=os.open(sys.argv[1],os.O_RDWR|os.O_CREAT,0o644); fcntl.flock(fd,fcntl.LOCK_EX); print("held",flush=True); time.sleep(6)' "$T/city/.gc/hetzner-fw-ip.lock" > "$T/held" &
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/held" ] && break; sleep 0.3; done
  run; eq "instância única: rc 0" 0 "$rc"; has "instância única: diz que outra roda" "outra instância" "$err"; [ -f "$T/city/.gc/hetzner-fw-ip.state.json" ] && bad "instância única: não gravou estado" || ok "instância única: não gravou estado"
  wait
fi

# ---- plist ---------------------------------------------------------------------------------------------------------------------------------------------
if [ -f "$PLIST" ]; then
  pl=$(python3 -B -c 'import plistlib,sys; d=plistlib.load(open(sys.argv[1],"rb")); print(d["Label"], d["StartInterval"], d["ProgramArguments"][-1].rsplit("/",1)[-1], d["RunAtLoad"], d["EnvironmentVariables"]["GC_CITY_PATH"])' "$PLIST" 2>&1)
  eq "plist: label, intervalo, script, RunAtLoad, cidade" "com.gascity.hetzner-fw-ip-watch 600 hetzner-fw-ip-watch.py True /Users/athos/gt/.gascity-gastown-hq" "$pl"
else
  bad "plist: $PLIST não existe"
fi
grep -q '^com.gascity.hetzner-fw-ip-watch	' "$HERE/wait-for-dolt.policy.tsv" && ok "policy: label registrado em wait-for-dolt.policy.tsv" || bad "policy: label ausente em wait-for-dolt.policy.tsv"

# ---- controle negativo ---------------------------------------------------------------------------------------------------------------------------------
if [ -z "${HFW_UNDER_TEST:-}" ] && [ "${HFW_NO_MUTANTS:-0}" != 1 ]; then
  mutant() {  # mutant <id> <trecho literal> <troca>
    local id="$1" from="$2" to="$3" cnt dest="$T/mut-$1.py"
    cnt=$(python3 -B -c 'import sys; print(open(sys.argv[1],encoding="utf-8").read().count(sys.argv[2]))' "$WATCH" "$from")
    if [ "$cnt" != 1 ]; then bad "mutante $id: o trecho existe $cnt vez(es) (precisa ser 1)"; return; fi
    python3 -B -c 'import sys; s=open(sys.argv[1],encoding="utf-8").read(); open(sys.argv[2],"w",encoding="utf-8").write(s.replace(sys.argv[3],sys.argv[4]))' "$WATCH" "$dest" "$from" "$to"
    if ( ulimit -f 524288; HFW_UNDER_TEST="$dest" HFW_FAST=1 QUIET=1 timeout -k 5 300 bash "$0" >/dev/null 2>&1 ); then bad "mutante $id SOBREVIVEU (a suíte não o pega)"; else ok "mutante $id morto"; fi
  }
  mutant M1-discordancia 'if len(set(ips)) != 1:' 'if len(set(ips)) < 0:'
  mutant M2-fonte-que-cai 'if motivos:' 'if False:'
  mutant M3-ip-publico 'return str(ip) if ip.is_global else None' 'return str(ip)'
  mutant M4-episodio 'st["alarm_ip"], st["alarm_epoch"] = None, None  # voltou ao liberado' 'pass  # voltou ao liberado'
  mutant M5-cooldown 'elif st["alarm_ip"] == ip and not due(st["alarm_epoch"], now, c.cooldown_s):' 'elif False:'
  mutant M6-mail-falha 'if send_mail(c, subj, body):
                    st["alarm_ip"], st["alarm_epoch"] = ip, now' 'if send_mail(c, subj, body) or True:
                    st["alarm_ip"], st["alarm_epoch"] = ip, now'
  mutant M7-zera-falhas 'st["fails"], st["fail_reason"] = 0, None' 'st["fails"], st["fail_reason"] = st["fails"], None'
  mutant M8-cegueira-n 'if st["fails"] >= c.blind_after and' 'if st["fails"] > c.blind_after and'
  mutant M9-novo-ip 'elif st["alarm_ip"] == ip and' 'elif True and'
  mutant M10-ack-cego 'ip, why = read_public_ip(c)
        if ip is None:
            raise Fail("--ack sem IP' 'ip, why = read_public_ip(c)
        if False:
            raise Fail("--ack sem IP'
  mutant M11-dry-run 'elif dry:
                alarme = "dry-run"' 'elif False:
                alarme = "dry-run"'
  mutant M13-estado-ilegivel 'raise Fail("não consegui ler %s: %s" % (path, e))' 'return new_state(c)'
  mutant M12-liberado-sozinho 'st["seen_ip"], st["seen_epoch"] = ip, now' 'st["seen_ip"], st["seen_epoch"], st["allowed_ip"] = ip, now, ip'
fi

echo "---"; echo "casos: $n · falhas: $fails"
[ "$fails" = 0 ]
