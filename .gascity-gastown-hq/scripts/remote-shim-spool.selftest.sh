#!/usr/bin/env bash
# remote-shim-spool.selftest.sh — hermético: o transporte POR PUXADA do atalho (remote-shim.py com "transport":"spool" + remote-shim-pump.py + o wrapper
# de verdade, ga-w7qwl1.1). O "MBP" é uma pasta em mktemp, o "ssh" é um falso que roda o comando remoto aqui (num zsh, o shell de login do MBP) e bd/gc/gate-done
# são os falsos do lib. Nada conecta em máquina nenhuma.
# Contents
#   Casos · Variáveis
# CASOS: config do spool (extra, relativo, prazo fora de 5-3600 → 78; pasta com modo largo → 78) · sem pump.alive / velho → 75 na hora, nada gravado ·
#   cadeia inteira (cliente → spool → puxador → ssh falso → agente → wrapper → bd falso): saída, rc, stderr e stdin passam; recusa do wrapper (77), identidade
#   fora do padrão, texto com $()/crase/aspas inteiro e nada executado · 6 em paralelo · pedido torto → 78 · prazo: não pego → RETIRADO e 75 (nada rodou); pego e
#   sem resposta → 125 · stdin > 1 MB → 2 sem gravar · entrada lida até o EOF (produtor lento) ou nada (pipe mudo: 75 sem gravar; só `bd --stdin` e os hooks do gc
#   leem); entrada fechada (<&-) é vazia; saída fechada (>&-) mantém o rc · log do puxador sem argv · puxador: um só, status, stop, sai sozinho sem sessão, não toca
#   o MBP sem sessão · leituras que FALHAM (resposta corrompida → 125; stdin que não lê → 2; config, registro, pid, log, lock e o flock que falha, put que não entrega, listdir/open): estado inerte e a falha aparece
# VARIÁVEIS: SPOOL_ONLY=<grupos separados por vírgula: conf,perm,alive,chain,par,forge,tmo,pump> · FAILFAST=1 (do lib)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/remote-shim.selftest.lib.sh"
PUMP="${PUMP_UNDER_TEST:-$HERE/remote-shim-pump.py}"
want() { [ -z "${SPOOL_ONLY:-}" ] || case ",$SPOOL_ONLY," in *",$1,"*) true;; *) false;; esac; }
FAKE_SHELL=$(command -v zsh || command -v sh)

MBP="$T/mbp"; SPOOL="$MBP/shim"; STATE="$T/state"; SB="$T/sbin"; mkdir -p "$MBP" "$STATE/mbp/running" "$SB"
SIDE="$T/ssh-argv.log"
cat > "$SB/ssh" <<EOF
#!/bin/sh
# ssh falso: tira as opções (-o X, -t), o destino, e roda o comando remoto como o sshd faria: no shell de login do "MBP"
printf '%s\n' "\$*" >> "$SIDE"
while [ \$# -gt 0 ]; do case "\$1" in -o) shift 2;; -*) shift;; *) break;; esac; done
shift
[ -z "\${FAKE_SSH_FAIL:-}" ] || { echo "ssh: connect to host mbp port 22: No route to host" >&2; exit 255; }
exec $FAKE_SHELL -c "\$1"
EOF
chmod +x "$SB/ssh"

SHIMCONF="$T/shim-spool.json"
printf '{"transport":"spool","spool_dir":"%s","timeout_s":30}' "$SPOOL" > "$SHIMCONF"
cat > "$T/session-ssh.json" <<EOF
{"hosts": {"mbp": {"ssh": "athos@mbp.local", "cap": 2, "remote_root": "$MBP/bundle", "remote_home": "$MBP", "path_extra": ["/opt/homebrew/bin"],
  "shim": {"spool_dir": "$SPOOL", "wrapper_config": "$CONF", "parallel": 4, "idle_exit_s": 2, "poll_s": 2}}}}
EOF
export GC_SSH_CONFIG="$T/session-ssh.json" GC_EXEC_STATE_DIR="$STATE" GC_SSH_BIN="$SB/ssh"
touch "$STATE/mbp/running/remote-test-remote-mbp-1"   # uma sessão registrada: é o que mantém o puxador de pé

shim() {  # shim TOOL ARG... → RC, $T/out, $T/err (ambiente da sessão no "MBP": identidade e um segredo plantado que NÃO pode ir). Entrada: $STDIN_CMD (um produtor, num pipe) ou $STDIN_FILE ou /dev/null
  local tool=$1; shift
  if [ -n "${STDIN_CMD:-}" ]; then exec 7< <(eval "$STDIN_CMD"); else exec 7< "${STDIN_FILE:-/dev/null}"; fi
  if [ -n "${OUT_DEAD:-}" ]; then exec 8> >(true); sleep 0.3; else exec 8> "$T/out"; fi   # OUT_DEAD: a saída é um pipe cujo leitor já saiu. STDIN_FD=-: a entrada fechada (<&-)
  env -i HOME="$HOME" USER="$USER" PATH="$T/shimbin:/usr/bin:/bin" REMOTE_SHIM_CONF="${SHIM_CONF:-$SHIMCONF}" GC_ALIAS="${SID_ALIAS:-gastown.dog-1}" GC_AGENT="${SID_ALIAS:-gastown.dog-1}" \
    GC_SESSION_NAME=dog-gavycydh GC_SESSION_ID=ga-vycydh AWS_SECRET_ACCESS_KEY=SEGREDO-PLANTADO-9 "$T/shimbin/$tool" "$@" >&8 2> "$T/err" <&"${STDIN_FD:-7}"
  RC=$?; exec 7<&- 8>&-
}
mkdir -p "$T/shimbin"; python3 -I "$S" install --bin-dir "$T/shimbin" --apply >/dev/null 2>&1
printf 'texto vindo do stdin' > "$T/stdin.txt"
pump() { python3 -I "$PUMP" "$@"; }
alive() { mkdir -p "$SPOOL"; chmod 700 "$MBP" "$SPOOL"; touch "$SPOOL/pump.alive"; }
up() {  # sobe o puxador (desacoplado, como o provedor faz) e espera ele tocar o pump.alive de verdade
  rm -f "$SPOOL/pump.alive"; mkdir -p "$SPOOL"; chmod 700 "$MBP" "$SPOOL"; pump ensure --host mbp
  for _ in $(seq 1 40); do [ -e "$SPOOL/pump.alive" ] && return 0; sleep 0.25; done; return 1
}
trap 'pump stop --host mbp >/dev/null 2>&1; kill $(jobs -p) 2>/dev/null; cleanup' EXIT

if want conf; then
echo "== config do spool"
mkdir -p "$SPOOL"; chmod 700 "$SPOOL"; alive
for c in '{"transport":"spool","spool_dir":"relativo/x"}' '{"transport":"spool","spool_dir":"/x","host":"h"}' '{"transport":"spool"}' '{"transport":"spool","spool_dir":"'"$SPOOL"'","timeout_s":4}' \
         '{"transport":"spool","spool_dir":"'"$SPOOL"'","timeout_s":3601}' '{"transport":"spool","spool_dir":"'"$SPOOL"'","timeout_s":true}' '{"transport":"carrier-pigeon","spool_dir":"'"$SPOOL"'"}'; do
  printf '%s' "$c" > "$T/bad.json"; SHIM_CONF="$T/bad.json" shim bd show ga-1
  [ "$RC" = 78 ] && has "$T/err" "config ausente ou ruim"; ok $? "config recusada (78): $(printf '%s' "$c" | cut -c1-70)"
done
for v in 0 601 '"60"' true 1.5; do  # stdin_eof_s: inteiro de 1 a 600 (true é int para o python: tem que ser recusado também)
  printf '{"transport":"spool","spool_dir":"%s","stdin_eof_s":%s}' "$SPOOL" "$v" > "$T/bad.json"; SHIM_CONF="$T/bad.json" shim bd show ga-1; [ "$RC" = 78 ] && has "$T/err" "config ausente ou ruim"; ok $? "stdin_eof_s=$v recusado (78)"
done
printf '{"transport":"spool","spool_dir":"%s"}' "$SPOOL" > "$T/ok.json"; b=$(calls); up
SHIM_CONF="$T/ok.json" shim bd show ga-1; [ "$RC" = 0 ] && [ "$(calls)" = $((b+1))  ]; ok $? "config só com transport+spool_dir vale (timeout_s padrão 330)"
# config AO LADO do script (o MBP: a sessão não leva variável e nada vai para o ~/.config do Athos). HOME sem ~/.config, PATH sem REMOTE_SHIM_CONF.
BB="$T/besidebin"; mkdir -p "$BB" "$T/nohome"; python3 -I "$S" install --bin-dir "$BB" --apply >/dev/null 2>&1
beside() {  # beside [VAR=valor…] → RC, $T/out, $T/err: o atalho instalado em $BB, sem REMOTE_SHIM_CONF a menos que passado
  env -i HOME="$T/nohome" USER="$USER" PATH="$BB:/usr/bin:/bin" GC_ALIAS=gastown.dog-1 GC_AGENT=gastown.dog-1 "$@" "$BB/bd" show ga-1 > "$T/out" 2> "$T/err" < /dev/null; RC=$?
}
beside; [ "$RC" = 78 ] && has "$T/err" "$T/nohome/.config/remote-shim/shim.json"; ok $? "sem variável, sem arquivo ao lado e sem ~/.config: 78 dizendo o caminho padrão"
cp "$T/ok.json" "$BB/remote-shim.json"; b=$(calls); beside; [ "$RC" = 0 ] && [ "$(calls)" = $((b+1)) ] && [ ! -e "$T/nohome/.config" ]; ok $? "remote-shim.json ao lado do script vale sem variável nenhuma (o HOME não tem config e o atalho não cria nenhum ~/.config)"
printf '{"transport":"spool","spool_dir":"relativo"}' > "$BB/remote-shim.json"; beside; [ "$RC" = 78 ] && has "$T/err" "$BB/remote-shim.json"; ok $? "arquivo ao lado ruim: 78 dizendo ESSE caminho (não cai no padrão em silêncio)"
b=$(calls); beside REMOTE_SHIM_CONF="$T/ok.json"; [ "$RC" = 0 ] && [ "$(calls)" = $((b+1)) ]; ok $? "REMOTE_SHIM_CONF vale mais que o arquivo ao lado"
rm -f "$BB/remote-shim.json"; ln -s "$T/ok.json" "$BB/remote-shim.json"; b=$(calls); beside; [ "$RC" = 0 ] && [ "$(calls)" = $((b+1)) ]; ok $? "arquivo ao lado que é link: lê o conteúdo do alvo"
rm -f "$BB/remote-shim.json"
pump stop --host mbp >/dev/null 2>&1
fi

if want perm; then
echo "== pasta do spool"
rm -rf "$SPOOL"; mkdir -p "$SPOOL"; chmod 755 "$SPOOL"; touch "$SPOOL/pump.alive"; b=$(calls)
shim bd show ga-1; [ "$RC" = 78 ] && has "$T/err" "modo 0700" && [ "$(calls)" = "$b" ] && [ -z "$(ls "$SPOOL/req" 2>/dev/null)" ]; ok $? "spool com modo 0755: recusado (78), nada gravado, nada rodou"
chmod 700 "$SPOOL"; rm -rf "$SPOOL"; ln -s "$T" "$SPOOL"; shim bd show ga-1
[ "$RC" = 78 ]; ok $? "spool que é um link simbólico: recusado (78)"
rm -f "$SPOOL"
fi

if want alive; then
echo "== o mini não está puxando"
rm -rf "$SPOOL"; mkdir -p "$SPOOL"; chmod 700 "$SPOOL"; b=$(calls); t0=$(date +%s)
shim bd show ga-1; t1=$(date +%s)
[ "$RC" = 75 ] && has "$T/err" "pump.alive ausente" && [ $((t1-t0)) -le 2 ] && [ "$(calls)" = "$b" ] && [ -z "$(ls "$SPOOL/req" | grep -v '^$')" ]; ok $? "sem pump.alive: 75 na hora, nada gravado no spool, nada rodou"
touch -t 202001010000 "$SPOOL/pump.alive"; shim bd show ga-1
[ "$RC" = 75 ] && has "$T/err" "parado há"; ok $? "pump.alive velho (>60 s): 75 na hora"
fi

if want chain; then
echo "== cadeia inteira: cliente → spool → puxador → ssh → agente → wrapper"
rm -rf "$SPOOL"; pump stop --host mbp >/dev/null 2>&1; rm -f "$STATE/mbp/shim-pump."*; up
st=$(pump status --host mbp); printf '%s' "$st" | grep -q "rodando=sim"; ok $? "status: puxador rodando"
PUMP_REAL=$(python3 -I -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$PUMP")  # o puxador se relança com o realpath: conta SÓ os deste arquivo (outra rodada, com outro puxador, não entra na conta)
p0=$(pump status --host mbp | sed -n 's/.* pid=\([0-9]*\).*/\1/p'); pump ensure --host mbp; sleep 0.5; p1=$(pump status --host mbp | sed -n 's/.* pid=\([0-9]*\).*/\1/p')
[ -n "$p0" ] && [ "$p0" = "$p1" ] && [ "$(pgrep -f -- "-I $PUMP_REAL run --host mbp" | wc -l | tr -d ' ')" = 1 ]; ok $? "ensure com um puxador vivo não sobe outro (mesmo pid, um processo só)"
b=$(calls); shim bd show ga-1 --json
[ "$RC" = 0 ] && [ "$(calls)" = $((b+1)) ] && has "$T/out" "FAKE-bd-OUT" && lastis "argv=[show][ga-1][--json]" && lastis "actor=gastown.dog-1"; ok $? "bd show: chega ao bd falso com argv e ator, saída volta"
shim bd close ga-1 --reason FAIL7; [ "$RC" = 7 ] && has "$T/err" "fake-err"; ok $? "rc 7 e stderr do comando passam"
STDIN_FILE="$T/stdin.txt" shim bd comment ga-1 --stdin; [ "$RC" = 0 ] && has "$T/out" "STDIN<texto vindo do stdin>"; ok $? "stdin passa (o texto de um comentário)"
b=$(calls); shim bd sql "select 1"; [ "$RC" = 77 ] && has "$T/err" "RECUSADO" && [ "$(calls)" = "$b" ]; ok $? "bd sql: 77 do wrapper, o bd falso não roda"
b=$(calls); SID_ALIAS=outra-coisa shim bd show ga-1; [ "$RC" = 77 ] && [ "$(calls)" = "$b" ]; ok $? "identidade fora do padrão: 77, nada roda"
b=$(calls); shim gc prime; [ "$RC" = 77 ] && [ "$(calls)" = "$b" ]; ok $? "gc prime sem --hook: 77"
shim gc handoff --auto "context cycle"; [ "$RC" = 0 ] && lastis "argv=[handoff][--auto][context cycle]"; ok $? 'espaço e aspas no argv chegam intactos'
shim bd comment ga-1 $'linha1\n$(touch '"$T"'/PWNED-shell) `touch '"$T"'/PWNED-shell2` "aspas" \\ fim'
[ "$RC" = 0 ] && lastis 'linha1\n$(touch' && [ ! -e "$T/PWNED-shell" ] && [ ! -e "$T/PWNED-shell2" ]; ok $? '$(), crase, aspas e barra chegam inteiros; nada é executado (no zsh do "MBP" e no mini)'
shim bd comment ga-1 "$(python3 -I -c 'print("ção ✓ ñ " * 40)')"; [ "$RC" = 0 ] && lastis "ção ✓ ñ"; ok $? "UTF-8 inteiro"
shim bd show ga-1 --json; ! grep -q "SEGREDO-PLANTADO" "$FB/calls.log" "$T/out" "$T/err" "$LOGF"; ok $? "segredo plantado no ambiente da sessão não vai nem para o bd nem para o log do wrapper"
awk -F'\t' '$2=="?" && $3=="gastown.dog-1" && $4=="ok"' "$LOGF" | grep -q .; ok $? "o log de auditoria do wrapper registrou o pedido (cliente \"?\": não houve ssh de entrada)"
! grep -qE 'ga-1|SEGREDO|show|eyJ0b29s|[A-Za-z0-9_=-]{40,}' "$STATE/mbp/shim-pump.log" && grep -qE 'id=[0-9]{13}-[0-9]+-[0-9a-f]{8} rc=0 .* put=ok' "$STATE/mbp/shim-pump.log"; ok $? "o log do puxador tem id, rc, tamanhos e o resultado do put, e não guarda argv (nem em base64: o pedido vai como PROTO+base64, eyJ0b29s é o começo do JSON codificado)"
[ -z "$(ls "$SPOOL/req" "$SPOOL/claimed" "$SPOOL/resp" | grep -v '^$' | grep -v ':$')" ]; ok $? "nada sobra em req/, claimed/ nem resp/ depois dos pedidos (o cliente apaga a resposta que leu)"
grep -q "ControlPath" "$SIDE" && grep -q "BatchMode=yes" "$SIDE" && ! grep -qE 'IdentityFile|-i ' "$SIDE"; ok $? "o puxador usa o ssh no molde do provedor (BatchMode, ControlPath) e sem chave nova (nem -i nem IdentityFile)"
python3 -I - "$S" "$PUMP" <<'PYEOF'; ok $? "o formato do id do cliente é o que o agente aceita; cut(): resposta acima de 8 MiB é cortada com marca, abaixo disso passa inteira"
import importlib.util, sys
def load(n, p):
    s = importlib.util.spec_from_file_location(n, p); m = importlib.util.module_from_spec(s); sys.modules[n] = m; s.loader.exec_module(m); return m
c = load("rs", sys.argv[1]); p = load("pump", sys.argv[2])
assert c.SPOOL_ID.pattern == p.SPOOL_ID.pattern, (c.SPOOL_ID.pattern, p.SPOOL_ID.pattern)
r = p.Pump.cut(b"x" * (9 << 20))
assert len(r) < (8 << 20) + 100 and r.endswith(b"8 MiB ...]\n") and p.Pump.cut(b"abc") == b"abc"
PYEOF
fi

if want par; then
echo "== pedidos em paralelo"
up; pids=""; b=$(calls); for i in 1 2 3 4 5 6; do ( env -i HOME="$HOME" USER="$USER" PATH="$T/shimbin:/usr/bin:/bin" REMOTE_SHIM_CONF="$SHIMCONF" GC_ALIAS=gastown.dog-1 GC_AGENT=gastown.dog-1 "$T/shimbin/bd" show "par-$i" > "$T/par$i.out" 2>&1; echo $? > "$T/par$i.rc" ) & pids="$pids $!"; done; wait $pids
okc=0; for i in 1 2 3 4 5 6; do [ "$(cat "$T/par$i.rc" 2>/dev/null)" = 0 ] && grep -q FAKE-bd-OUT "$T/par$i.out" && okc=$((okc+1)); done
[ "$okc" = 6 ] && [ "$(calls)" = $((b+6)) ]; ok $? "6 pedidos ao mesmo tempo (paralelo 4): os 6 respondem e cada um roda uma vez"
fi

if want forge; then
echo "== pedido torto no spool"
up; b=$(calls); mkdir -p "$SPOOL/req"; i1="1700000000001-111-aaaaaaaa"; i2="1700000000002-222-bbbbbbbb"; i3="1700000000003-333-cccccccc"
printf 'isto nao e json' > "$SPOOL/req/$i1.json"
printf '{"v":1,"id":"1700000000009-9-dddddddd","cmd":"rs1 x","stdin_b64":""}' > "$SPOOL/req/$i2.json"
printf '{"v":1,"id":"%s","cmd":"rs1 x","stdin_b64":""}' "$i3" > "$SPOOL/req/nome-que-nao-e-id.json"
for _ in $(seq 1 60); do [ -e "$SPOOL/resp/$i1.json" ] && [ -e "$SPOOL/resp/$i2.json" ] && break; sleep 0.25; done
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["rc"]==78 and d["id"]==sys.argv[2], d' "$SPOOL/resp/$i1.json" "$i1"; ok $? "JSON ilegível: o agente responde 78 (nada chega ao wrapper)"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["rc"]==78 and d["id"]==sys.argv[2], d' "$SPOOL/resp/$i2.json" "$i2"; ok $? "id de dentro diferente do nome do arquivo: 78"
sleep 1; [ ! -e "$SPOOL/req/nome-que-nao-e-id.json" ] && [ ! -e "$SPOOL/resp/nome-que-nao-e-id.json" ] && [ "$b" = "$(calls)" ]; ok $? "arquivo com nome que não é id: apagado, sem resposta; nenhum dos três pedidos tortos chegou ao bd/gc falso"
fi

if want tmo; then
echo "== prazo"
pump stop --host mbp >/dev/null 2>&1
forge() {  # forge PLANTA: roda um bd show no cliente (sem puxador) e, quando o pedido aparece em req/, chama a função PLANTA (vê $rid) para pôr a "resposta" → RC, $T/out, $T/err
  rm -f "$SPOOL/req/"* "$SPOOL/resp/"* "$SPOOL/claimed/"*; alive; ( SHIM_CONF="$SHIMCONF" shim bd show ga-1; echo "$RC" > "$T/forged.rc" ) & local fg=$! f
  for _ in $(seq 1 50); do f=$(ls "$SPOOL/req" 2>/dev/null | grep '\.json$' | head -1); [ -n "$f" ] && break; sleep 0.1; done
  rid=${f%.json}; "$1"; wait $fg; RC=$(cat "$T/forged.rc")
}
plant_forged() { printf '{"id":"1700000000000-1-00000000","rc":0,"stdout_b64":"%s","stderr_b64":""}' "$(printf 'RESPOSTA-FALSA' | base64)" > "$SPOOL/resp/$rid.json"; }
plant_garbage() { printf 'isto nao e json{{{' > "$SPOOL/resp/$rid.json"; }
plant_dir() { mkdir -p "$SPOOL/resp/$rid.json"; }
forge plant_forged; [ "$RC" = 125 ] && ! has "$T/out" "RESPOSTA-FALSA"; ok $? "resposta cujo id de dentro não é o do pedido: 125, a saída não é usada"
forge plant_garbage; [ "$RC" = 125 ] && has "$T/err" "ilegível" && ! has "$T/out" "FAKE-bd-OUT"; ok $? "resposta corrompida no spool (JSON ilegível): 125, o pedido pode ter rodado; não repete e não inventa saída"
forge plant_dir; rmdir "$SPOOL/resp/$rid.json"; [ "$RC" = 125 ] && has "$T/err" "ilegível"; ok $? "resposta que não abre (IsADirectoryError): 125, o mesmo"
rm -f "$SPOOL/req/"* "$SPOOL/resp/"* "$SPOOL/claimed/"*
alive; printf '{"transport":"spool","spool_dir":"%s","timeout_s":5}' "$SPOOL" > "$T/short.json"; b=$(calls); t0=$(date +%s)
SHIM_CONF="$T/short.json" shim bd show ga-1; t1=$(date +%s)
[ "$RC" = 75 ] && has "$T/err" "NADA rodou" && [ $((t1-t0)) -ge 5 ] && [ -z "$(ls "$SPOOL/req" | grep -v '^$')" ] && [ "$(calls)" = "$b" ]; ok $? "pedido que ninguém pegou: retirado do spool no prazo, 75, nada rodou"
# um "agente" que PEGA o pedido (move para claimed/) e some sem responder
mkdir -p "$SPOOL/claimed"; ( for _ in $(seq 1 100); do f=$(ls "$SPOOL/req" 2>/dev/null | grep '\.json$' | head -1); [ -n "$f" ] && { mv "$SPOOL/req/$f" "$SPOOL/claimed/$f"; break; }; sleep 0.1; done ) & CL=$!
touch "$SPOOL/pump.alive"; b=$(calls); t0=$(date +%s)
SHIM_CONF="$T/short.json" shim bd show ga-1; t1=$(date +%s); wait $CL 2>/dev/null
[ "$RC" = 125 ] && has "$T/err" "pode ter rodado" && [ $((t1-t0)) -ge 5 ] && [ "$(calls)" = "$b" ]; ok $? "pedido pego e sem resposta: 125 (pode ter rodado), depois de dar mais um tempo"
b=$(calls)
head -c 1048577 /dev/zero > "$T/big.bin"; alive; STDIN_FILE="$T/big.bin" shim bd comment ga-1 --stdin
[ "$RC" = 2 ] && has "$T/err" "maior que" && [ -z "$(ls "$SPOOL/req" | grep -v '^$')" ]; ok $? "entrada padrão acima de 1 MB: 2, nada gravado"
b=$(calls); alive   # entrada aberta só para ESCRITA (0>): o select diz "pronto" e o read dá EBADF (uma pasta nem chega lá: o python se recusa a subir)
env -i HOME="$HOME" USER="$USER" PATH="$T/shimbin:/usr/bin:/bin" REMOTE_SHIM_CONF="$SHIMCONF" GC_ALIAS=gastown.dog-1 GC_AGENT=gastown.dog-1 "$T/shimbin/bd" comment ga-1 --stdin > "$T/out" 2> "$T/err" 0> "$T/so-escrita"; RC=$?
[ "$RC" = 2 ] && has "$T/err" "não consegui ler a entrada padrão" && [ -z "$(ls "$SPOOL/req" | grep -v '^$')" ] && [ "$(calls)" = "$b" ]; ok $? "entrada padrão que falha ao ler (EBADF): 2, nada gravado, nada rodou; não manda a entrada pela metade"
# --- a entrada padrão é lida INTEIRA (até o EOF) ou o comando não roda: silêncio de um pipe aberto não é "acabou" (o hook do claude e o `bd comment --stdin` de uma sessão vêm de pipes)
sbody() {  # sbody CONF TOOL ARG... → RC, $GOT (a entrada que o pedido levou, decodificada; vazio se nenhum pedido foi gravado). Sem puxador: o "mini" é este teste, que lê req/ e planta a resposta
  rm -f "$SPOOL/req/"* "$SPOOL/resp/"* "$SPOOL/claimed/"* "$T/sb.rc"; alive; GOT=; local f=; ( SHIM_CONF=$1 shim "${@:2}"; echo "$RC" > "$T/sb.rc" ) & local sb=$!
  for _ in $(seq 1 200); do f=$(ls "$SPOOL/req" 2>/dev/null | grep '\.json$' | head -1); { [ -n "$f" ] || [ -e "$T/sb.rc" ]; } && break; sleep 0.1; done
  [ -n "$f" ] && { GOT=$(python3 -I -c 'import base64,json,sys; sys.stdout.write(base64.b64decode(json.load(open(sys.argv[1]))["stdin_b64"]).decode())' "$SPOOL/req/$f")
    printf '{"id":"%s","rc":0,"stdout_b64":"%s","stderr_b64":""}' "${f%.json}" "${SB_OUT:-}" > "$SPOOL/resp/$f"; }
  wait $sb; RC=$(cat "$T/sb.rc")
}
printf '{"transport":"spool","spool_dir":"%s","timeout_s":5,"stdin_eof_s":2}' "$SPOOL" > "$T/eof2.json"
STDIN_CMD='sleep 1.5; printf "texto lento"' sbody "$SHIMCONF" bd comment ga-1 --stdin
[ "$RC" = 0 ] && [ "$GOT" = "texto lento" ]; ok $? "bd comment --stdin com produtor lento (1,5 s antes do primeiro byte): o texto vai inteiro"
STDIN_CMD='printf "parte1 "; sleep 3; printf "parte2"' sbody "$SHIMCONF" bd comment ga-1 --stdin
[ "$RC" = 0 ] && [ "$GOT" = "parte1 parte2" ]; ok $? "bd comment --stdin com pausa de 3 s no meio: espera o EOF, nada cortado"
STDIN_CMD='sleep 1; printf "{\"hook\":\"SessionStart\"}"' sbody "$SHIMCONF" gc prime --hook
[ "$RC" = 0 ] && [ "$GOT" = '{"hook":"SessionStart"}' ]; ok $? "gc prime --hook: o JSON do hook que chega depois de 1 s vai inteiro"
STDIN_CMD='printf "lixo no pipe"' sbody "$SHIMCONF" bd show ga-1
[ "$RC" = 0 ] && [ -z "$GOT" ]; ok $? "bd show (não lê a entrada): o pedido leva entrada vazia, sem ler o que haja no pipe"
t0=$(date +%s); STDIN_CMD='sleep 6' sbody "$SHIMCONF" bd show ga-1; t1=$(date +%s)
[ "$RC" = 0 ] && [ -z "$GOT" ] && [ $((t1-t0)) -lt 4 ]; ok $? "bd show com pipe aberto e mudo: não espera por ele e roda"
STDIN_CMD='printf "lixo no pipe"' sbody "$SHIMCONF" gc mail inbox
[ "$RC" = 0 ] && [ -z "$GOT" ]; ok $? "gc mail inbox (não lê a entrada): entrada vazia também; só os hooks do gc levam a entrada"
t0=$(date +%s); STDIN_CMD='sleep 8' sbody "$T/eof2.json" bd comment ga-1 --stdin; t1=$(date +%s)
[ "$RC" = 75 ] && has "$T/err" "não terminou" && [ -z "$GOT" ] && [ -z "$(ls "$SPOOL/req" | grep -v '^$')" ] && [ $((t1-t0)) -ge 2 ]; ok $? "bd comment --stdin com pipe aberto e mudo: sem EOF em stdin_eof_s → 75 e NADA gravado no spool (não comenta vazio)"
STDIN_CMD='sleep 8' sbody "$T/eof2.json" gc prime --hook
[ "$RC" = 75 ] && has "$T/err" "não terminou" && [ -z "$GOT" ] && [ -z "$(ls "$SPOOL/req" | grep -v '^$')" ]; ok $? "gc prime --hook com pipe aberto e mudo: o mesmo, 75 sem gravar (não vira hook sem entrada)"
STDIN_CMD='printf "metade"; sleep 8' sbody "$T/eof2.json" bd comment ga-1 --stdin
[ "$RC" = 75 ] && [ -z "$GOT" ] && [ -z "$(ls "$SPOOL/req" | grep -v '^$')" ]; ok $? "bd comment --stdin que escreve e não fecha: 75, o que veio não é enviado (nada de comentário pela metade)"
for c in "gc mail check" "bd comment ga-1 --stdin"; do STDIN_FD=- sbody "$SHIMCONF" $c
  [ "$RC" = 0 ] && [ -z "$GOT" ] && ! has "$T/err" Traceback; ok $? "$c com a entrada fechada (<&-): vazia como /dev/null, o pedido vai e o código é o do mini (0), não um traceback com 1 (\"caixa vazia\")"; done
OUT_DEAD=1 SB_OUT=eA== sbody "$SHIMCONF" gc mail check
[ "$RC" = 0 ]; ok $? "resposta com a saída fechada (pipe sem leitor): o código do comando sai intacto (0), nem 1 nem 120"
fi

if want pump; then
echo "== o puxador"
pump stop --host mbp >/dev/null 2>&1; rm -f "$STATE/mbp/shim-pump."*; alive; : > "$SIDE"
rm -f "$STATE/mbp/running/"*
pump ensure --host mbp; sleep 0.5
for _ in $(seq 1 40); do [ "$(pump status --host mbp | head -1 | grep -c 'rodando=nao')" = 1 ] && break; sleep 0.5; done
pump status --host mbp | head -1 | grep -q "rodando=nao"; ok $? "sem sessão registrada o puxador sai sozinho (idle_exit_s=2)"
n1=$(wc -l < "$SIDE" | tr -d ' '); sleep 3; n2=$(wc -l < "$SIDE" | tr -d ' ')
[ "$n1" = "$n2" ]; ok $? "e depois de sair não toca mais o MBP (nenhum ssh novo)"
touch "$STATE/mbp/running/remote-test-remote-mbp-1"; pump ensure --host mbp; sleep 1.5
pump status --host mbp | head -1 | grep -q "rodando=sim"; ok $? "ensure com sessão registrada sobe o puxador"
b=$(calls); alive; shim bd show ga-1; [ "$RC" = 0 ] && [ "$(calls)" = $((b+1)) ]; ok $? "e ele atende"
pump stop --host mbp | grep -q "encerrado" && pump status --host mbp | head -1 | grep -q "rodando=nao"; ok $? "stop encerra, e o status depois do stop diz que não roda"
pump stop --host mbp >/dev/null 2>&1; rm -f "$STATE/mbp/shim-pump."*
chmod 755 "$SPOOL"; touch "$STATE/mbp/running/remote-test-remote-mbp-1"; pump ensure --host mbp; sleep 2.5; pump stop --host mbp >/dev/null 2>&1; chmod 700 "$SPOOL"
grep -q "get falhou rc=78" "$STATE/mbp/shim-pump.log"; ok $? "agente: spool com modo largo no MBP → 78, o puxador não puxa nada"
rm -f "$STATE/mbp/shim-pump."*
python3 -I - "$PUMP" "$SPOOL" <<'PYEOF'; ok $? "agente: put de um id que NINGUÉM pegou não cria resposta; o de um id pego cria, e só uma vez"
import importlib.util, json, os, subprocess, sys
s = importlib.util.spec_from_file_location("pump", sys.argv[1]); m = importlib.util.module_from_spec(s); sys.modules["pump"] = m; s.loader.exec_module(m)
sp = sys.argv[2]; os.makedirs(sp + "/claimed", exist_ok=True); os.makedirs(sp + "/resp", exist_ok=True)
def put(rid):
    line = json.dumps({"id": rid, "rc": 0, "stdout_b64": "", "stderr_b64": ""}) + "\n"
    return subprocess.run([sys.executable, "-I", "-c", m.AGENT, sp, "put"], input=line.encode(), capture_output=True)
a, b = "1700000000100-1-aaaaaaaa", "1700000000200-1-bbbbbbbb"
open(sp + "/claimed/" + b + ".json", "w").close()
assert put(a).returncode == 0 and not os.path.exists(sp + "/resp/" + a + ".json")
assert put(b).returncode == 0 and os.path.exists(sp + "/resp/" + b + ".json") and not os.path.exists(sp + "/claimed/" + b + ".json")
os.unlink(sp + "/resp/" + b + ".json")
assert put(b).returncode == 0 and not os.path.exists(sp + "/resp/" + b + ".json")
PYEOF
FAKE_SSH_FAIL=1 pump ensure --host mbp; sleep 3; pump stop --host mbp >/dev/null 2>&1
grep -q "get falhou rc=255" "$STATE/mbp/shim-pump.log"; ok $? "ssh falhando: o puxador registra e espera em vez de girar (não cai)"
# leituras do puxador que FALHAM: o estado é o inerte (não sobe, não mata, não afirma o que não sabe) e a falha aparece
rm -f "$STATE/mbp/shim-pump."*; pstat() { pump status --host mbp | head -1; }
GC_SSH_CONFIG="$T/nao-existe.json" pump ensure --host mbp > "$T/pe.out" 2>&1; rc=$?
[ "$rc" != 0 ] && grep -q "configuração ilegível" "$T/pe.out" && pstat | grep -q "rodando=nao"; ok $? "puxador: configuração ausente (FileNotFoundError) → recusa visível, nenhum puxador sobe"
printf 'garbage{{{' > "$T/corrompida.json"; GC_SSH_CONFIG="$T/corrompida.json" pump status --host mbp > "$T/pe.out" 2>&1; rc=$?
[ "$rc" != 0 ] && grep -q "configuração ilegível" "$T/pe.out"; ok $? "puxador: configuração corrompida → recusa visível, não inventa estado"
rm -rf "$STATE/mbp/running"; : > "$STATE/mbp/running"
pstat | grep -q "sessoes_registradas=sim"; ok $? "puxador: registro de sessões que não lê (NotADirectoryError) conta como sessão viva, não como vazio"
rm -f "$STATE/mbp/running"; pstat | grep -q "sessoes_registradas=nao"; ok $? "puxador: registro que não existe → nenhuma sessão registrada"
mkdir -p "$STATE/mbp/running"; touch "$STATE/mbp/running/remote-test-remote-mbp-1"
[ "$(pump status --host mbp | wc -l | tr -d ' ')" = 1 ]; ok $? "puxador: status de quem nunca rodou (sem log) é uma linha só, sem aviso"
mkdir "$STATE/mbp/shim-pump.log"; pump status --host mbp > "$T/pe.out" 2>&1; rc=$?
[ "$rc" = 0 ] && head -1 "$T/pe.out" | grep -q "rodando=nao" && grep -q "log do puxador ilegível" "$T/pe.out"; ok $? "puxador: status com o log ilegível (IsADirectoryError) segue informando e AVISA que o rabo do log não veio"
rmdir "$STATE/mbp/shim-pump.log"
: > "$T/state-arquivo"; GC_EXEC_STATE_DIR="$T/state-arquivo" pump status --host mbp > "$T/pe.out" 2>&1; rc=$?
[ "$rc" != 0 ] && grep -q "não consegui abrir o lock" "$T/pe.out" && ! grep -q "rodando=nao" "$T/pe.out"; ok $? "puxador: o lock não abre (NotADirectoryError) → não afirma que não há puxador, diz que não sabe"
up; p0=$(pstat | sed -n 's/.* pid=\([0-9]*\).*/\1/p'); printf 'garbage' > "$STATE/mbp/shim-pump.pid"
pump stop --host mbp > "$T/pe.out" 2>&1; rc=$?; st=$(pstat); printf '%s' "$p0" > "$STATE/mbp/shim-pump.pid"   # o pid volta ANTES de qualquer conclusão: o trap do EXIT tem que conseguir encerrar o puxador mesmo se o stop acima falhar
[ "$rc" = 1 ] && grep -q "não consegui ler o pid" "$T/pe.out" && printf '%s' "$st" | grep -q "rodando=sim"; ok $? "puxador: lock preso e pid ilegível (garbage) → stop recusa encerrar às cegas (rc 1, avisa) e o puxador segue de pé"
pump stop --host mbp | grep -q "encerrado"; ok $? "puxador: com o pid de volta, o mesmo stop encerra"
python3 -I - "$PUMP" <<'PYEOF'; ok $? "puxador: o flock que FALHA (ENOLCK) não é 'ocupado' (held() diz que não sabe, serve() sai ≠ 0 sem pid) e o put que devolve ok 0 não é entrega (NÃO CONFIRMADA no log)"
import errno, importlib.util, os, sys
s = importlib.util.spec_from_file_location("pump", sys.argv[1]); m = importlib.util.module_from_spec(s); sys.modules["pump"] = m; s.loader.exec_module(m)
cfg = m.Cfg("mbp"); os.makedirs(cfg.state, exist_ok=True)
def busy(*a): raise BlockingIOError(errno.EWOULDBLOCK, "busy")
def boom(*a): raise OSError(errno.ENOLCK, "No locks available")
m.fcntl.flock = boom
try: m.held(cfg); raise AssertionError("held() afirmou algo sem saber")
except SystemExit as e: assert "não sei" in str(e), e
assert m.Pump(cfg).serve() == 1 and not os.path.exists(cfg.state + "/shim-pump.pid")
m.fcntl.flock = busy
assert m.held(cfg) is True and m.Pump(cfg).serve() == 0
def put_log(replies):
    it, log = iter(replies), cfg.state + "/shim-pump.log"
    open(log, "w").close(); p = m.Pump(cfg); p.inflight = 1
    p.run_wrapper = lambda c, i: (0, b"", b""); p.ssh_run = lambda *a, **k: next(it)
    p.job("1700000000400-1-dddddddd", "x", b""); return open(log).read()
assert "put=NÃO CONFIRMADA" in put_log([(0, b"ok 0\n", b"")]) and "put=NÃO CONFIRMADA" in put_log([(255, b"", b"x"), (0, b"ok 0\n", b"")])
PYEOF
python3 -I - "$PUMP" "$T/agent-spool" <<'PYEOF'; ok $? "agente: leitura do spool que FALHA (PermissionError em listdir e em open) → sai ≠ 0 sem pegar nada / responde 78 sem entregar o pedido"
import importlib.util, json, os, subprocess, sys
s = importlib.util.spec_from_file_location("pump", sys.argv[1]); m = importlib.util.module_from_spec(s); sys.modules["pump"] = m; s.loader.exec_module(m)
sp, rid = sys.argv[2], "1700000000300-1-cccccccc"; os.makedirs(sp, 0o700, exist_ok=True); os.chmod(sp, 0o700); os.makedirs(sp + "/req", 0o700, exist_ok=True)
with open(sp + "/req/" + rid + ".json", "w") as f: json.dump({"v": 1, "id": rid, "cmd": "rs1 x", "stdin_b64": ""}, f)
def get(prelude): return subprocess.run([sys.executable, "-I", "-c", prelude + m.AGENT, sp, "get", "1", "1"], capture_output=True, timeout=30)
r = get("import os\ndef _boom(*a, **k): raise PermissionError(13, 'injetado')\nos.listdir = _boom\n")
assert r.returncode != 0 and b"PermissionError" in r.stderr and r.stdout == b"" and os.path.exists(sp + "/req/" + rid + ".json") and not os.listdir(sp + "/claimed"), r
r = get("import builtins\n_o = builtins.open\ndef _f(p, *a, **k):\n    if '/claimed/' in str(p): raise PermissionError(13, 'injetado')\n    return _o(p, *a, **k)\nbuiltins.open = _f\n")
d = json.load(open(sp + "/resp/" + rid + ".json"))
assert r.returncode == 0 and r.stdout == b"" and d["rc"] == 78 and not os.listdir(sp + "/claimed") and not os.path.exists(sp + "/req/" + rid + ".json"), (r, d)
PYEOF
# --- a última faxina do spool no stop (ga-w7qwl1.1.7): resposta que ninguém leu não fica no MBP até o próximo ensure. Velhos = 300 s (acima da carência de 90 s e abaixo do KEEP_S de 900: o sweep do
# puxador vivo NÃO os leva, então quem apaga é a faxina do stop); poupados = 60 s e 0 s (dentro da carência: um puxador novo pode já ter escrito uma resposta que o cliente ainda vai ler)
pump stop --host mbp >/dev/null 2>&1; rm -f "$STATE/mbp/shim-pump."*; mkdir -p "$STATE/mbp/running"; touch "$STATE/mbp/running/remote-test-remote-mbp-1"
age() { python3 -I -c 'import os,sys,time; t=time.time()-float(sys.argv[2]); os.utime(sys.argv[1],(t,t))' "$1" "$2"; }   # age ARQUIVO SEGUNDOS: o mtime volta SEGUNDOS no tempo
oldid=1700000000500-1-aaaaaaaa; midid=1700000000600-1-bbbbbbbb; newid=1700000000700-1-cccccccc
plant() {  # plant [req]: spool novo com velhos em resp/ e claimed/ (com "req": também em req/ e um .tmp velho em resp/) e dois poupados em resp/; req/ só sem puxador vivo, que pegaria o pedido
  rm -rf "$SPOOL"; mkdir -p "$SPOOL/req" "$SPOOL/resp" "$SPOOL/claimed"; chmod 700 "$SPOOL"; touch "$SPOOL/pump.alive"
  : > "$SPOOL/resp/$oldid.json"; age "$SPOOL/resp/$oldid.json" 300; : > "$SPOOL/claimed/$oldid.json"; age "$SPOOL/claimed/$oldid.json" 300
  : > "$SPOOL/resp/$midid.json"; age "$SPOOL/resp/$midid.json" 60; : > "$SPOOL/resp/$newid.json"
  if [ "${1:-}" = req ]; then : > "$SPOOL/req/$oldid.json"; age "$SPOOL/req/$oldid.json" 300; : > "$SPOOL/resp/.$oldid.tmp"; age "$SPOOL/resp/.$oldid.tmp" 300; fi
}
stopr() { pump stop --host mbp > "$T/st.out" 2> "$T/st.err"; SRC=$?; }   # → SRC, $T/st.out, $T/st.err
plant; up; stopr
[ "$SRC" = 0 ] && grep -q "encerrado" "$T/st.out" && grep -q "faxina do spool: limpei" "$T/st.out" && [ ! -e "$SPOOL/resp/$oldid.json" ] && [ ! -e "$SPOOL/claimed/$oldid.json" ]; ok $? "stop com o puxador vivo: depois de encerrar, a faxina apaga a resposta e o claimed/ velhos (300 s, acima da carência) e diz 'limpei'"
[ -e "$SPOOL/resp/$midid.json" ] && [ -e "$SPOOL/resp/$newid.json" ] && [ -e "$SPOOL/pump.alive" ] && grep -q "limpei 2 arquivo(s) velho(s); poupei 2 dentro da carência" "$T/st.out" && grep -q "faxina de parada: limpei 2 " "$STATE/mbp/shim-pump.log"; ok $? "a faxina do stop poupa o que está DENTRO da carência (o de 60 s e o de 0 s) e o pump.alive; a conta (limpei 2, poupei 2) vai ao stdout e ao log do puxador"
plant req; stopr
[ "$SRC" = 0 ] && grep -q "não há puxador rodando" "$T/st.out" && grep -q "limpei 4 arquivo(s) velho(s)" "$T/st.out" && [ -z "$(ls -A "$SPOOL/req")" ] && [ -z "$(ls -A "$SPOOL/claimed")" ] && [ ! -e "$SPOOL/resp/$oldid.json" ] && [ ! -e "$SPOOL/resp/.$oldid.tmp" ] && [ -e "$SPOOL/resp/$midid.json" ] && [ -e "$SPOOL/resp/$newid.json" ]; ok $? "stop de quem já tinha saído sozinho: a faxina roda também, em req/, resp/ (inclusive o .tmp velho) e claimed/ (4 saem), ao lado de 'não há puxador rodando'"
stopr
[ "$SRC" = 0 ] && grep -q "não havia nada velho; poupei 2 dentro da carência" "$T/st.out" && ! grep -q "limpei" "$T/st.out" && [ -e "$SPOOL/resp/$midid.json" ] && [ -e "$SPOOL/resp/$newid.json" ]; ok $? "stop sem nada velho no spool: 'não havia', sai 0, e os 2 poupados da carência continuam lá"
rm -rf "$SPOOL"; stopr
[ "$SRC" = 0 ] && grep -q "não havia" "$T/st.out" && [ ! -e "$SPOOL" ]; ok $? "stop sem a pasta do spool no MBP: 'não havia', sai 0, e a faxina não cria a pasta"
plant req; FAKE_SSH_FAIL=1 stopr
[ "$SRC" != 0 ] && grep -q "NÃO DEU PARA VER" "$T/st.err" && grep -q "rc=255" "$T/st.err" && ! grep -qE "limpei|não havia" "$T/st.out" "$T/st.err" && [ -e "$SPOOL/resp/$oldid.json" ] && [ -e "$SPOOL/req/$oldid.json" ]; ok $? "stop com o ssh fora (rc 255): NÃO DEU PARA VER com o rc, sai ≠ 0, e não diz 'limpei' nem 'não havia' (o que sobrou segue lá)"
plant req; chmod 755 "$SPOOL"; stopr; chmod 700 "$SPOOL"
[ "$SRC" != 0 ] && grep -q "NÃO DEU PARA VER" "$T/st.err" && grep -q "rc=78" "$T/st.err" && [ -e "$SPOOL/resp/$oldid.json" ] && [ -e "$SPOOL/req/$oldid.json" ] && [ -e "$SPOOL/resp/$newid.json" ]; ok $? "stop com o spool de modo largo (0755): o agente recusa (78), NÃO DEU PARA VER, sai ≠ 0, e nada é apagado numa pasta que não é minha"
plant; mkdir "$SPOOL/resp/pasta-velha"; age "$SPOOL/resp/pasta-velha" 300; stopr
[ "$SRC" != 0 ] && grep -q "NÃO DEU PARA LIMPAR" "$T/st.err" && grep -q "limpei 2" "$T/st.err" && [ ! -e "$SPOOL/resp/$oldid.json" ] && [ -d "$SPOOL/resp/pasta-velha" ] && [ -e "$SPOOL/resp/$newid.json" ]; ok $? "stop com um velho que não sai (uma pasta onde devia haver arquivo): apaga o que dá, NÃO DEU PARA LIMPAR com a conta, sai ≠ 0 (apagar que falha não é 'limpei')"
python3 -I - "$PUMP" "$T/reap-spool" <<'PYEOF'; ok $? "agente reap: a carência é de 1 a 2 minutos; sem a pasta do spool diz 'sem-spool' e não cria nada; listdir que FALHA (PermissionError) não vira 'nada a limpar' (sai ≠ 0, nada apagado); uma pasta que falta dentro do spool é só 'nada ali'"
import importlib.util, os, re, subprocess, sys, time
s = importlib.util.spec_from_file_location("pump", sys.argv[1]); m = importlib.util.module_from_spec(s); sys.modules["pump"] = m; s.loader.exec_module(m)
sp = sys.argv[2]
def reap(prelude=""): return subprocess.run([sys.executable, "-I", "-c", prelude + m.AGENT, sp, "reap"], capture_output=True, timeout=30)
g = re.search(r"REAP_GRACE_S = ([0-9]+)", m.AGENT)
assert g and 60 <= int(g.group(1)) <= 120, g
r = reap()
assert r.returncode == 0 and r.stdout.split() == [b"reap", b"sem-spool"] and not os.path.exists(sp), (r, os.path.exists(sp))
os.makedirs(sp + "/resp", 0o700); os.chmod(sp, 0o700)
f = sp + "/resp/1700000000800-1-dddddddd.json"; open(f, "w").close(); os.utime(f, (time.time() - 300,) * 2)
r = reap("import os\ndef _boom(*a, **k): raise PermissionError(13, 'injetado')\nos.listdir = _boom\n")
assert r.returncode != 0 and b"PermissionError" in r.stderr and r.stdout == b"" and os.path.exists(f), r
r = reap()
assert r.returncode == 0 and r.stdout.split() == [b"reap", b"1", b"0", b"0"] and not os.path.exists(f) and not os.path.exists(sp + "/req"), r
PYEOF
python3 -I - "$PUMP" <<'PYEOF'; ok $? "puxador: a resposta do agente que não entendo (vazia, lixo, forma errada, rc ≠ 0, ssh que nem lança) é NÃO DEU PARA VER e sai 1, nunca 'não havia'; as formas certas dão limpei / não havia e sai 0; apagar que falhou (3º número) é NÃO DEU PARA LIMPAR e sai 1"
import contextlib, importlib.util, io, sys
s = importlib.util.spec_from_file_location("pump", sys.argv[1]); m = importlib.util.module_from_spec(s); sys.modules["pump"] = m; s.loader.exec_module(m)
cfg = m.Cfg("mbp")
def run(reply):
    def fake(self, *a, **k):
        if isinstance(reply, Exception): raise reply
        return reply
    m.Pump.ssh_run = fake
    o, e = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(o), contextlib.redirect_stderr(e): rc = m.reap_spool(cfg)
    return rc, o.getvalue(), e.getvalue()
for reply in [(0, b"", b""), (0, b"lixo\n", b""), (0, b"reap 1 2\n", b""), (0, b"reap 1 2 x\n", b""), (255, b"", b"ssh: sem rota"), (78, b"reap 0 0 0\n", b"modo errado"), OSError(2, "No such file or directory")]:
    rc, o, e = run(reply)
    assert rc == 1 and "NÃO DEU PARA VER" in e and "limpei" not in o + e and "não havia" not in o + e, (reply, rc, o, e)
rc, o, e = run((0, b"reap sem-spool\n", b"")); assert rc == 0 and "não havia" in o and e == "", (rc, o, e)
rc, o, e = run((0, b"reap 0 3 0\n", b"")); assert rc == 0 and "não havia nada velho; poupei 3 dentro da carência" in o and e == "", (rc, o, e)
rc, o, e = run((0, b"reap 3 1 0\n", b"")); assert rc == 0 and "limpei 3 arquivo(s) velho(s); poupei 1 dentro da carência" in o and e == "", (rc, o, e)
rc, o, e = run((0, b"reap 3 1 2\n", b"")); assert rc == 1 and "NÃO DEU PARA LIMPAR" in e and "limpei 3" in e and o == "", (rc, o, e)
PYEOF
fi

echo
echo "$n casos, $fails falha(s), $skipped sem rodar"
exit $((fails > 0))
