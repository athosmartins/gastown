#!/usr/bin/env bash
# hetzner-fw-ip-watch.selftest.sh — hermético: curl e gc são stubs; a cidade é um diretório temporário; nada fala com a rede nem com o mail de verdade. (ga-1h1b7vq)
#
# Contents
#   Casos · Controle negativo · Como rodar
#
# CASOS  igual · diferente (mail, cooldown, IP novo, mail que falha) · não sei (fonte cai, discorda, resposta que não é IP, IP privado, timeout) · cegueira (N falhas seguidas, cooldown, zera com leitura boa)
#   · episódio (voltou ao liberado e desviou de novo avisa na hora) · --ack · --dry-run · estado corrompido (texto torto, não-UTF-8, JSON fundo, campo de tipo errado, fail_reason que não grava, v float, chave extra, allowed_ip com espaço guardado normalizado; --print e --ack herdam) · write_atomic com texto que não grava (chamada direta) · estado que não grava depois do mail · instância única · aviso desligado · configuração inválida · plist
#   · o arquivo de estado e o --print em texto exato · --print só lê · fail_reason em UTF-8 (--ack grava, --print mostra) · queda inesperada (rc 1) · unidade em processo único (limites da configuração, borda do cooldown, tamanho da resposta, texto dos avisos, grupo de processos)
# CONTROLE NEGATIVO  cada mutante (um trecho literal do script trocado, que tem de existir UMA vez) TEM de reprovar a suíte; mutante que passa = teste que não pega o bug.
#   Cada um roda sob `ulimit -f` (teto de escrita por arquivo, ga-e6ug8gq) e a suíte dele pula os casos lentos (HFW_FAST=1).
# COMO RODAR  hetzner-fw-ip-watch.selftest.sh   (HFW_UNDER_TEST=<script> roda a suíte contra outra cópia · HFW_NO_MUTANTS=1 pula o controle negativo · HFW_FAST=1 pula timeout e instância única)
#   HFW_FAST=1 também pula o bloco "limites, codificação e processo" (os mutantes embutidos rodam com ele e não precisam desses casos: cada um custaria ×13)
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
has "diferente: a linha impressa traz o IP lido e o liberado" "ip=$NOVO liberado=$LIBERADO" "$out"
# vazio → arquivo ausente: o texto lido não bate e reprova; falhou/ilegível → idem (nunca passa por igual)
hfw_exp=$(printf '{\n "alarm_epoch": %s,\n "alarm_ip": "%s",\n "allowed_ip": "%s",\n "blind_alarm_epoch": null,\n "fail_reason": null,\n "fails": 0,\n "seen_epoch": %s,\n "seen_ip": "%s",\n "v": 1\n}' "$NOW" "$NOVO" "$LIBERADO" "$NOW" "$NOVO")
hfw_got=$(cat "$T/city/.gc/hetzner-fw-ip.state.json" 2>&1)
[ "$hfw_got" = "$hfw_exp" ] && ok "diferente: o arquivo de estado, texto exato (chaves em ordem alfabética, recuo de 1 espaço)" || bad "diferente: o arquivo de estado difere do esperado: $(printf '%s' "$hfw_got" | tr '\n' ' ' | head -c 300)"
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
eq "print: rc 0" 0 "$rc"
# vazio → arquivo ausente: o texto lido não bate e reprova; falhou/ilegível → idem
hfw_got=$(cat "$T/city/.gc/hetzner-fw-ip.state.json" 2>&1)
[ "$out" = "$hfw_got" ] && ok "print: é o estado gravado, texto exato (chaves em ordem alfabética, recuo de 1 espaço)" || bad "print: o texto difere do arquivo gravado: $(printf '%s' "$out" | tr '\n' ' ' | head -c 300)"

# ---- estado corrompido ---------------------------------------------------------------------------------------------------------------------------------
reset; both "$LIBERADO"; echo '{"v": 1, "allowed_ip": "banana"' > "$T/city/.gc/hetzner-fw-ip.state.json"; WARGS=""; run
eq "corrompido: rc 0" 0 "$rc"; has "corrompido: recomeça da semente" "estado=igual" "$out"; has "corrompido: avisa no stderr" "corrompido" "$err"
ls "$T/city/.gc" | grep -q 'state.json.corrupt-' && ok "corrompido: a cópia ficou" || bad "corrompido: a cópia ficou"
echo '{"v": 1, "allowed_ip": "10.1.1.1", "fails": 0}' > "$T/city/.gc/hetzner-fw-ip.state.json"; run; has "liberado privado no estado: corrompido, recomeça" "corrompido" "$err"
echo '{"v": 1, "allowed_ip": "'"$LIBERADO"'", "fails": 0, "seen_epoch": "ontem"}' > "$T/city/.gc/hetzner-fw-ip.state.json"; run; has "epoch que não é inteiro: corrompido" "corrompido" "$err"
echo '[1,2]' > "$T/city/.gc/hetzner-fw-ip.state.json"; run; has "JSON que não é objeto: corrompido" "corrompido" "$err"

# estado que NÃO é texto / JSON fundo / tipo errado (ga-jhjnvqe): formato errado = corrompido (cópia guardada, recomeça da semente), nunca traceback (rc 1 a cada rodada, calado para sempre)
corrupt_case() {  # corrupt_case <rótulo>: o arquivo de estado já está escrito; a rodada (fontes caídas) tem de recomeçar da semente e guardar os bytes antigos
  local lbl="$1" st="$T/city/.gc/hetzner-fw-ip.state.json"
  cp "$st" "$T/orig.state"
  src "$H1" "rc 6"; src "$H2" "rc 6"; NOW_OVERRIDE=$((NOW+600)) run
  eq "$lbl: rc 0" 0 "$rc"; has "$lbl: recomeçou da semente (falhas=1)" "falhas=1" "$out"; has "$lbl: avisa no stderr" "corrompido" "$err"; hasnt "$lbl: sem traceback" "Traceback" "$err"
  if cmp -s "$T/orig.state" "$st.corrupt-$((NOW+600))"; then ok "$lbl: a cópia guarda os bytes antigos"; else bad "$lbl: a cópia não guarda os bytes antigos"; fi
}
reset; printf '\xff\xfe\x00garbage' > "$T/city/.gc/hetzner-fw-ip.state.json"; corrupt_case "estado não-UTF-8"
reset; python3 -B -c 'import sys; sys.stdout.write("["*200000)' > "$T/city/.gc/hetzner-fw-ip.state.json"; corrupt_case "estado JSON fundo (RecursionError)"
reset; echo '{"v": 1, "allowed_ip": 5, "fails": 0}' > "$T/city/.gc/hetzner-fw-ip.state.json"; corrupt_case "allowed_ip que não é texto (número)"
reset; echo '{"v": 1, "allowed_ip": ["1.2.3.4"], "fails": 0}' > "$T/city/.gc/hetzner-fw-ip.state.json"; corrupt_case "allowed_ip que não é texto (lista)"
reset; echo '{"v": 1, "allowed_ip": "'"$LIBERADO"'", "fails": 0, "seen_ip": 7}' > "$T/city/.gc/hetzner-fw-ip.state.json"; corrupt_case "seen_ip que não é texto"
reset; echo '{"v": 1, "allowed_ip": "'"$LIBERADO"'", "fails": true}' > "$T/city/.gc/hetzner-fw-ip.state.json"; corrupt_case "fails booleano"
reset; echo '{"v": true, "allowed_ip": "'"$LIBERADO"'", "fails": 0}' > "$T/city/.gc/hetzner-fw-ip.state.json"; corrupt_case "versão booleana"
reset; echo '{"v": 1.0, "allowed_ip": "'"$LIBERADO"'", "fails": 0}' > "$T/city/.gc/hetzner-fw-ip.state.json"; corrupt_case "versão float (1.0)"
reset; echo '{"v": 1, "allowed_ip": "'"$LIBERADO"'", "fails": 0, "fail_reason": "\ud800"}' > "$T/city/.gc/hetzner-fw-ip.state.json"; corrupt_case "fail_reason com surrogate solto"
reset; echo '{"v": 1, "allowed_ip": "'"$LIBERADO"'", "fails": 0, "fail_reason": 7}' > "$T/city/.gc/hetzner-fw-ip.state.json"; corrupt_case "fail_reason que não é texto"
# chave a mais com texto que não grava de volta (surrogate solto): o estado vale, a chave extra não passa para o arquivo novo (quem pega a falha de gravação em si é o caso direto de write_atomic mais abaixo; aqui o "nenhum .tmp" só prova que nada tentou gravar a chave)
reset; echo '{"v": 1, "allowed_ip": "'"$LIBERADO"'", "fails": 0, "x": "\ud800"}' > "$T/city/.gc/hetzner-fw-ip.state.json"; both "$LIBERADO"; WARGS=""; run
eq "chave extra ilegível de gravar: rc 0" 0 "$rc"; has "chave extra: rodada normal" "estado=igual" "$out"; hasnt "chave extra: sem traceback" "Traceback" "$err"
ls "$T/city/.gc" | grep -q '\.tmp\.' && bad "chave extra: sobrou arquivo .tmp" || ok "chave extra: nenhum .tmp sobrando"
python3 -B -c 'import json,sys; sys.exit(0 if "x" not in json.load(open(sys.argv[1])) else 1)' "$T/city/.gc/hetzner-fw-ip.state.json" && ok "chave extra: não foi copiada para o estado novo" || bad "chave extra: foi copiada para o estado novo"
# allowed_ip com espaço na frente: o que foi validado (normalizado) é o que se compara e se grava; senão 2 fontes iguais ao liberado dariam "diferente" e 1 mail "( X → X)"
reset; echo '{"v": 1, "allowed_ip": " '"$LIBERADO"'", "fails": 0}' > "$T/city/.gc/hetzner-fw-ip.state.json"; both "$LIBERADO"; WARGS=""; run
eq "allowed_ip com espaço: rc 0" 0 "$rc"; has "allowed_ip com espaço: estado=igual" "estado=igual" "$out"; eq "allowed_ip com espaço: nenhum mail" 0 "$(calls)"; eq "allowed_ip com espaço: gravado normalizado" "$LIBERADO" "$(sget allowed_ip)"
# --print e --ack herdam o conserto de load_state
reset; printf '\xff\xfe\x00garbage' > "$T/city/.gc/hetzner-fw-ip.state.json"; WARGS="--print"; run
eq "print com estado não-UTF-8: rc 0" 0 "$rc"; has "print com estado não-UTF-8: mostra a semente" "\"allowed_ip\": \"$LIBERADO\"" "$out"; hasnt "print: sem traceback" "Traceback" "$err"
reset; printf '\xff\xfe\x00garbage' > "$T/city/.gc/hetzner-fw-ip.state.json"; WARGS="--ack $NOVO"; run
eq "ack com estado não-UTF-8: rc 0" 0 "$rc"; eq "ack com estado não-UTF-8: grava o IP" "$NOVO" "$(sget allowed_ip)"
reset; echo '{"v": 1, "allowed_ip": "'"$LIBERADO"'", "fails": 0, "fail_reason": "\ud800"}' > "$T/city/.gc/hetzner-fw-ip.state.json"; WARGS="--print"; run
eq "print com fail_reason que não imprime: rc 0" 0 "$rc"; hasnt "print com fail_reason que não imprime: sem traceback" "Traceback" "$err"; has "print com fail_reason que não imprime: recomeça da semente" "\"fails\": 0" "$out"
WARGS=""

# write_atomic direto (ga-jhjnvqe, gate-fix 1): nenhuma entrada do estado chega até aqui com texto que não grava (load_state valida tudo), então só uma chamada direta exercita o `except ValueError`:
# texto com surrogate solto tem de virar Fail (rc 3 no main), o arquivo antigo fica intacto e nenhum .tmp sobra
mkdir -p "$T/wa"; echo antigo > "$T/wa/x.json"
wa=$(python3 -B -c '
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("hfw_under_test", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
p = os.path.join(sys.argv[2], "x.json")
try:
    m.write_atomic(p, "\ud800")
    print("SEM-ERRO")
except m.Fail as e:
    print("Fail")
except BaseException as e:
    print("OUTRA:" + type(e).__name__)
print("tmp=" + ",".join(sorted(f for f in os.listdir(sys.argv[2]) if ".tmp." in f)))
print("conteudo=" + open(p).read().strip())
' "$WATCH" "$T/wa" 2>&1)
has "write_atomic com texto que não grava: vira Fail" "Fail" "$(printf '%s\n' "$wa" | sed -n 1p)"; eq "write_atomic com texto que não grava: nenhum .tmp sobra" "tmp=" "$(printf '%s\n' "$wa" | sed -n 2p)"; eq "write_atomic com texto que não grava: o arquivo antigo fica intacto" "conteudo=antigo" "$(printf '%s\n' "$wa" | sed -n 3p)"

# estado ilegível (sem permissão de leitura) = não sei: não decide, não manda mail, não mexe no arquivo, sai com rc 3
reset; both "$NOVO"; WARGS=""; run; before=$(cat "$T/city/.gc/hetzner-fw-ip.state.json")
chmod 000 "$T/city/.gc/hetzner-fw-ip.state.json"; NOW_OVERRIDE=$((NOW+600)) run; chmod 600 "$T/city/.gc/hetzner-fw-ip.state.json"
eq "estado ilegível: rc 3" 3 "$rc"; has "estado ilegível: diz o que não conseguiu" "não consegui ler" "$err"; eq "estado ilegível: nenhum mail novo (o 1 é da 1ª rodada)" 1 "$(calls)"
[ "$before" = "$(cat "$T/city/.gc/hetzner-fw-ip.state.json")" ] && ok "estado ilegível: o arquivo não foi tocado" || bad "estado ilegível: o arquivo foi alterado"; hasnt "estado ilegível: não vira estado de semente" "estado=" "$out"
ls "$T/city/.gc" | grep -q 'state.json.corrupt-' && bad "estado ilegível: não guarda cópia de corrompido" || ok "estado ilegível: não guarda cópia de corrompido"

# mail enviado mas estado que não grava (ga-jhjnvqe): rc 3 e o stderr diz que o mail saiu, para o mail repetido da rodada seguinte ter explicação no log
reset; both "$NOVO"; WARGS=""; run; both "$NOVO2"; chmod 555 "$T/city/.gc"; NOW_OVERRIDE=$((NOW+600)) run; chmod 755 "$T/city/.gc"
eq "mail enviado, estado não gravado: rc 3" 3 "$rc"; has "mail enviado, estado não gravado: o stderr diz que o mail saiu" "mail enviado, estado não gravado" "$err"; has "mail enviado, estado não gravado: e por que não gravou" "não consegui gravar" "$err"; eq "mail enviado, estado não gravado: o mail de fato saiu" 2 "$(calls)"
reset; both "$NOVO"; run; chmod 555 "$T/city/.gc"; NOW_OVERRIDE=$((NOW+600)) run; chmod 755 "$T/city/.gc"
eq "estado não grava sem mail na rodada: rc 3" 3 "$rc"; hasnt "estado não grava sem mail na rodada: NÃO afirma mail enviado" "mail enviado" "$err"; eq "estado não grava sem mail na rodada: ainda 1 mail" 1 "$(calls)"

# ---- aviso desligado e configuração --------------------------------------------------------------------------------------------------------------------
reset; both "$NOVO"; WARGS=""; run HETZNER_FW_IP_ALARM=0
has "aviso desligado: mede e diz" "alarme=desligado" "$out"; eq "aviso desligado: nenhum mail" 0 "$(calls)"
run HETZNER_FW_IP_SOURCES=https://api.ipify.org; eq "1 fonte só: configuração inválida (rc 3)" 3 "$rc"; has "1 fonte só: diz por quê" "2 fontes" "$err"
run HETZNER_FW_IP_ALLOWED=10.0.0.1; eq "liberado privado na config: rc 3" 3 "$rc"
run HETZNER_FW_IP_BLIND_AFTER=0; eq "BLIND_AFTER=0: rc 3" 3 "$rc"
reset; both "$NOVO"; run HETZNER_FW_IP_ALLOWED=$NOVO; has "liberado por ambiente (semente, 1ª rodada)" "estado=igual" "$out"
run HETZNER_FW_IP_ALLOWED=9.9.9.9; has "semente do ambiente não vale depois da 1ª rodada (manda o estado)" "estado=igual" "$out"
reset; both "$LIBERADO"; run HETZNER_FW_IP_COOLDOWN_S=60 HETZNER_FW_IP_ALLOWED=9.9.9.9; has "semente 9.9.9.9 ≠ IP lido: diferente" "estado=diferente" "$out"

# ---- limites, codificação e processo -------------------------------------------------------------------------------------------------------------------
# Só na rodada principal (HFW_FAST=1 pula): os mutantes embutidos rodam com ele e já têm o que precisam. A unidade importa o script uma vez e confere o que o fluxo inteiro não alcança.
# EQUIVALENT 46f87c0f5c da64613a6a: parse_ip's `len(s) > 15` guard (and the `not s or` before it) only repeats what ipaddress.IPv4Address already refuses: an IPv4 literal is at most 4 x 3 digits + 3 dots = 15 characters, so `15 -> 16` lets one more length reach the library, which raises the ValueError the next lines turn into the same None, and `or -> and` makes the guard never fire (empty and long strings reach that same ValueError); MEASURED on 350653 inputs (every 4-octet combination of 15 octet spellings, random strings, non-str values, which the `isinstance` check above the guard already answers None for) under python 3.9 and 3.12: same value or same exception class, with a control (`> 14`) that diverges
# EQUIVALENT 57ed46e654: `return ips[0]` -> `ips[1]` in read_public_ip: load_config refuses fewer than 2 sources, the `if motivos` return above leaves one answer per source, and `len(set(ips)) != 1` returns unless all of them are equal, so ips[1] IS ips[0]; MEASURED on 775 scenarios (2-4 sources x agree/disagree/fail) with a control (discord not refused) that diverges; a 1-source config would raise IndexError, which load_config makes unreachable
# EQUIVALENT a99c2dbb42: run_cmd's `universal_newlines=True` -> False: the same call passes errors="replace", and CPython opens the pipes in text mode when encoding, errors, text or universal_newlines is set, so the flag adds nothing; MEASURED on 8 commands (CR, CRLF, invalid UTF-8, empty, 70 KB, missing binary) under python 3.9 and 3.12: same (rc, out, err, why) including the types, with a control (no text flag at all) that diverges
PYU='import importlib.machinery, importlib.util, os, signal, subprocess, sys, tempfile, time
from types import SimpleNamespace
sys.dont_write_bytecode = True
ld = importlib.machinery.SourceFileLoader("hfw", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("hfw", ld))
ld.exec_module(m)
bad = []
nchk = [0]
def chk(name, got, want):
    nchk[0] += 1
    try:
        g = got()
    except Exception as e:
        g = "raised " + type(e).__name__
    if g != want:
        bad.append(name)
        print("FAIL %s: esperado %r, veio %r" % (name, want, g))
def raises(f, cls):
    try:
        f()
    except cls:
        return True
    except Exception as e:
        return "outra excecao " + type(e).__name__
    return False
def cfg(**kw):
    env = {"GC_CITY_PATH": "/cidade"}
    env.update(kw)
    return m.load_config(env)
# configuracao: os padroes e os limites (cooldown 0 vale; timeout do curl abaixo de 1 nao)
c = cfg()
chk("config: padroes", lambda: (c.blind_after, c.cooldown_s, c.blind_cooldown_s, c.curl_timeout_s, c.alarm_on), (3, 10800, 21600, 10, True))
chk("config: COOLDOWN_S=0 vale", lambda: cfg(HETZNER_FW_IP_COOLDOWN_S="0").cooldown_s, 0)
chk("config: BLIND_COOLDOWN_S=0 vale", lambda: cfg(HETZNER_FW_IP_BLIND_COOLDOWN_S="0").blind_cooldown_s, 0)
chk("config: CURL_TIMEOUT_S=1 vale", lambda: cfg(HETZNER_FW_IP_CURL_TIMEOUT_S="1").curl_timeout_s, 1)
chk("config: CURL_TIMEOUT_S=0 e recusado", lambda: raises(lambda: cfg(HETZNER_FW_IP_CURL_TIMEOUT_S="0"), ValueError), True)
# borda do cooldown: no mesmo instante do aviso ele ainda nao acabou
chk("due: nunca avisou", lambda: m.due(None, 100, 10800), True)
chk("due: no mesmo instante do aviso", lambda: m.due(1000, 1000, 10800), False)
chk("due: 1 s antes do fim", lambda: m.due(1000, 1000 + 10799, 10800), False)
chk("due: no fim", lambda: m.due(1000, 1000 + 10800, 10800), True)
chk("due: relogio que recuou avisa", lambda: m.due(1000, 999, 10800), True)
chk("due: cooldown 0 avisa sempre", lambda: m.due(1000, 1000, 0), True)
# o IPv4 publico mais longo tem 15 caracteres e vale; com 16 nao e IP
chk("parse_ip: IPv4 publico de 15 caracteres", lambda: m.parse_ip("123.123.123.123"), "123.123.123.123")
chk("parse_ip: 16 caracteres nao e IP", lambda: m.parse_ip("1234.123.123.123"), None)
# leitura de uma fonte e envio do mail com o processo trocado por um gravador: argv e limite de tempo sao o comportamento
real_run = m.run_cmd
rec = []
resp = []
def fake_run(argv, timeout):
    rec.append((list(argv), timeout))
    return resp.pop(0)
m.run_cmd = fake_run
try:
    cc = SimpleNamespace(curl_bin="CURL", curl_timeout_s=7)
    resp[:] = [(0, "179.197.107.78\n", "", None)]
    chk("read_source: resposta boa", lambda: m.read_source(cc, "https://h/ip"), ("179.197.107.78", None))
    chk("read_source: argv do curl e teto de fora (max-time + 5)", lambda: rec[-1], (["CURL", "-4", "-fsS", "--max-time", "7", "https://h/ip"], 12))
    for size, want in ((64, "resposta-invalida"), (65, "resposta-grande")):
        resp[:] = [(0, "9" * size, "", None)]
        chk("read_source: corpo de %d caracteres" % size, lambda: m.read_source(cc, "u"), (None, want))
    cm = SimpleNamespace(gc_bin="GC", city="/cidade")
    resp[:] = [(0, "", "", None)]
    chk("send_mail: enviou", lambda: m.send_mail(cm, "S", "B"), True)
    chk("send_mail: argv do mail ao mayor e limite de 45 s", lambda: rec[-1], (["GC", "--city", "/cidade", "mail", "send", "mayor", "-s", "S", "-m", "B"], 45))
finally:
    m.run_cmd = real_run
# o texto dos avisos
cmsg = SimpleNamespace(city="/cidade", sources=["https://api.ipify.org", "https://ifconfig.me/ip"], cooldown_s=10800, blind_cooldown_s=21600)
stc = {"fails": 3, "fail_reason": "fonte-sem-resposta(timeout)", "allowed_ip": "1.2.3.4"}
chk("changed_message: cita as fontes pelo host", lambda: "(as 2 fontes api.ipify.org e ifconfig.me concordam)" in m.changed_message(cmsg, "1.2.3.4", "5.6.7.8")[1], True)
chk("changed_message: diz que repete a cada 3 h", lambda: "Repete a cada 3 h enquanto" in m.changed_message(cmsg, "1.2.3.4", "5.6.7.8")[1], True)
chk("blind_message: proximo aviso em no minimo 6 h", lambda: "em no m\xednimo 6 h;" in m.blind_message(cmsg, stc)[1], True)
# processo de verdade: um comando que trava vira timeout e leva o grupo de processos inteiro (o neto tambem)
def vivo(p):
    out = subprocess.run(["ps", "-o", "stat=", "-p", str(p)], stdout=subprocess.PIPE, universal_newlines=True).stdout.strip()
    return bool(out) and not out.startswith("Z")
pf = os.path.join(tempfile.mkdtemp(), "pid")
chk("run_cmd: comando que trava termina como timeout", lambda: m.run_cmd(["sh", "-c", "sleep 60 & echo $! > " + pf + "; wait"], 2), (None, "", "", "timeout"))
# vazio -> sem arquivo de pid (o sh nem rodou): vira pid 0 e o teste do grupo abaixo reprova com "sem pid"; arquivo ilegivel ou vazio -> o int() levanta e o bloco todo cai com traceback (o shell reprova a unidade, nunca passa)
pid = int(open(pf).read().strip()) if os.path.exists(pf) else 0
for _ in range(50):
    if not pid or not vivo(pid):
        break
    time.sleep(0.1)
chk("run_cmd: o grupo inteiro morre no timeout (o neto tambem)", lambda: vivo(pid) if pid else "sem pid", False)
if pid and vivo(pid):
    os.kill(pid, signal.SIGKILL)
# o mesmo caminho do timeout com o Popen trocado: quem recebe SIGKILL e quanto se espera pelos canos depois dele
class FP(object):
    last = None
    def __init__(self, argv, **kw):
        self.pid = 424242
        self.returncode = None
        self.waits = []
        FP.last = self
    def communicate(self, timeout=None):
        self.waits.append(timeout)
        if len(self.waits) == 1:
            raise subprocess.TimeoutExpired("falso", timeout)
        return ("", "")
real_popen, real_killpg = subprocess.Popen, os.killpg
sent = []
subprocess.Popen = FP
os.killpg = lambda pid, sig: sent.append((pid, sig))
try:
    got_fp = m.run_cmd(["x"], 3)
finally:
    subprocess.Popen, os.killpg = real_popen, real_killpg
chk("run_cmd (Popen falso): devolve timeout", lambda: got_fp, (None, "", "", "timeout"))
chk("run_cmd (Popen falso): SIGKILL no grupo do filho", lambda: sent, [(424242, signal.SIGKILL)])
chk("run_cmd (Popen falso): espera no maximo 5 s pelos canos depois do kill", lambda: FP.last.waits, [3, 5])
print("CHECKS %d" % nchk[0])
print("DONE %d" % len(bad))'
if [ "${HFW_FAST:-0}" != 1 ]; then
  # vazio → sem a linha DONE o bloco não terminou e reprova; falhou/ilegível (traceback, python ausente) → idem, com o começo da saída na mensagem
  hfw_unit=$(python3 -B -c "$PYU" "$WATCH" 2>&1)
  case "$hfw_unit" in
    *"DONE 0") ok "unidade: $(printf '%s\n' "$hfw_unit" | sed -n 's/^CHECKS //p') checagens em um processo só (configuração, borda do cooldown, corpo da resposta, texto dos avisos, grupo de processos)" ;;
    *) bad "unidade: $(printf '%s' "$hfw_unit" | head -c 700)" ;;
  esac
  # fail_reason (a única chave de texto livre que o estado aceita; chave extra não passa) com texto fora do ASCII: o --ack a regrava em UTF-8 (não como \u), e o --print o mostra inteiro
  reset; printf '{"v": 1, "allowed_ip": "%s", "fails": 0, "fail_reason": "ação"}\n' "$LIBERADO" > "$T/city/.gc/hetzner-fw-ip.state.json"; WARGS="--ack $NOVO"; run
  # vazio → arquivo ausente: o grep não acha e reprova; falhou/ilegível → idem
  grep -q '"fail_reason": "ação"' "$T/city/.gc/hetzner-fw-ip.state.json" 2>/dev/null && ok "estado: o fail_reason volta gravado em UTF-8" || bad "estado: o fail_reason perdeu o UTF-8 (ou o arquivo sumiu)"
  WARGS="--print"; run; has "print: mostra o UTF-8 inteiro" '"fail_reason": "ação"' "$out"
  # --print só lê: o estado corrompido é dito, a cópia que uma rodada normal guardaria não é feita
  reset; echo '{"v": 1, "allowed_ip": "banana"' > "$T/city/.gc/hetzner-fw-ip.state.json"; WARGS="--print"; run
  has "print: estado corrompido só é dito" "a cópia iria para" "$err"
  [ -f "$T/city/.gc/hetzner-fw-ip.state.json" ] && ok "print: o arquivo corrompido continua no lugar" || bad "print: o arquivo corrompido foi movido"
  ls "$T/city/.gc" | grep -q 'state.json.corrupt-' && bad "print: não cria cópia de corrompido" || ok "print: não cria cópia de corrompido"
  # queda inesperada (um relógio que o gmtime não aguenta): traceback no stderr e rc 1, nunca rc 0
  reset; both "$LIBERADO"; WARGS=""; NOW_OVERRIDE=99999999999999999999 run
  eq "queda inesperada: rc 1" 1 "$rc"; has "queda inesperada: traceback no stderr" "Traceback" "$err"
fi

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
  mutant M14-estado-nao-utf8 'except UnicodeDecodeError:' 'except ZeroDivisionError:'
  mutant M15-json-fundo 'except (ValueError, RecursionError):' 'except ValueError:'
  mutant M16-ip-tipo-errado 'if not isinstance(text, str):' 'if False:'
  mutant M17-grava-ValueError 'except (OSError, ValueError) as e:  # ValueError' 'except OSError as e:  # ValueError'
  mutant M18-mail-sem-estado 'if mail_saiu:' 'if False:'
  mutant M19-chave-extra 'base.update({k: st[k] for k in base if k in st})' 'base.update(st)'
  mutant M20-versao-bool ' and not isinstance(st.get("v"), bool)' ''
  mutant M21-fails-bool ' and not isinstance(st.get("fails"), bool)' ''
  mutant M22-fail-reason-nao-grava 'ok = ok and (st.get("fail_reason") is None or writable_text(st["fail_reason"]))' 'ok = ok and True'
  mutant M23-ip-normalizado 'base[k] = parse_ip(base[k])  #' 'pass  #'
  mutant M24-versao-float 'isinstance(st.get("v"), int) and not isinstance(st.get("v"), bool) and st["v"] == 1' 'st.get("v") == 1 and not isinstance(st.get("v"), bool)'
  mutant M25-texto-sem-encode 'x.encode("utf-8")' 'pass'
  mutant M12-liberado-sozinho 'st["seen_ip"], st["seen_epoch"] = ip, now' 'st["seen_ip"], st["seen_epoch"], st["allowed_ip"] = ip, now, ip'
fi

echo "---"; echo "casos: $n · falhas: $fails"
[ "$fails" = 0 ]
