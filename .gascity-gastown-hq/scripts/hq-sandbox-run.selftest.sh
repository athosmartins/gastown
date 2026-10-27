#!/usr/bin/env bash
# hq-sandbox-run.selftest.sh (ga-2hd02v.5.6.1) — a jaula Landlock do lastro: escrita só onde se manda, TCP cortado, e sem jaula provada nada roda.
#
# ## Contents
#   Hermético · Casos · Mutantes · Ambiente (97)
#
# HERMÉTICO: tudo numa pasta descartável; HOME falso para o caso do --rw que anularia a jaula; as sentinelas ficam FORA do --rw e são conferidas por quem chamou (o rc de uma chamada não prova nada).
# CASOS: uso e recusas (rodam em qualquer sistema) · sem jaula (HQSB_FORCE_UNAVAILABLE) o comando NÃO roda · com jaula (só Linux com Landlock ABI >= 4, o nó): escrever, apagar, truncar e abrir TCP
#   fora do --rw falham e o estado fora fica intacto, escrever dentro e em /dev/null funciona, o rc do comando passa, `--prove` dá `provado`.
# MUTANTES do próprio lançador (cada âncora casa EXATAMENTE 1 vez, senão o caso é INVÁLIDO e reprova: âncora ambígua não prova nada, ga-31xxl5): tirar um direito da jaula, não chamar o restrict_self, deixar
#   o /dev de fora, deixar o --rw=HOME passar e seguir sem jaula quando ela falha têm de ser pegos por `--prove` ou pelos casos acima.
# AMBIENTE: sem Landlock (macOS, kernel velho) os casos de jaula e os mutantes NÃO rodam: imprime AMBIENTE e sai 97 (nunca verde sem ter provado a jaula); o gate roda este arquivo no nó (mbp-run.sh --repo hq).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SB="$HERE/hq-sandbox-run.py"
W="$(mktemp -d "${TMPDIR:-/tmp}/hq-sandbox-st.XXXXXX")" || exit 3
trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
check() { if [ "$2" = "$3" ]; then ok; else bad "$1: esperava rc $2, veio $3"; fi; }
nz() { if [ "$2" != 0 ]; then ok; else bad "$1: esperava rc diferente de 0 (o sh do nó é dash: 2, bash: 1)"; fi; }
mkdir -p "$W/rw" "$W/home" "$W/fora"
run() { python3 -I "$SB" "$@"; }

# ── uso e recusas (qualquer sistema) ───────────────────────────────────────────────────────────────────
run > /dev/null 2>&1;                                                  check "sem argumento: falta o comando" 64 $?
run --rw "$W/rw" > /dev/null 2>&1;                                     check "sem -- e sem comando" 64 $?
run --rw "$W/rw" -- > /dev/null 2>&1;                                  check "-- sem comando" 64 $?
run --bobagem > /dev/null 2>&1;                                        check "argumento desconhecido" 64 $?
run --prove > /dev/null 2>&1;                                          check "--prove sem --rw" 64 $?
run --rw "$W/nao-existe" -- true > /dev/null 2>&1;                     check "--rw que não existe" 64 $?
run --rw rw-relativo -- true > /dev/null 2>&1;                         check "--rw relativo" 64 $?
run --rw / -- true > /dev/null 2>&1;                                   check "--rw / anularia a jaula" 64 $?
HOME="$W/home" run --rw "$W/home" -- true > /dev/null 2>&1;            check "--rw = HOME anularia a jaula" 64 $?
HOME="$W/home" run --rw "$W" -- true > /dev/null 2>&1;                 check "--rw = pai do HOME anularia a jaula" 64 $?
# sem jaula o comando NÃO roda (forçado: vale no nó e fora dele); o --prove também diz inerte
rm -f "$W/rodou"
HQSB_FORCE_UNAVAILABLE=1 run --rw "$W/rw" -- touch "$W/rw/rodou" > /dev/null 2>&1; check "sem jaula: rc 97" 97 $?
[ ! -e "$W/rw/rodou" ] && ok || bad "sem jaula: o comando RODOU (fail-open)"
out=$(HQSB_FORCE_UNAVAILABLE=1 run --prove --rw "$W/rw" 2>&1); rc=$?
check "--prove sem jaula: rc 97" 97 $rc
case "$out" in "HQSB: inerte "*) ok ;; *) bad "--prove sem jaula: não disse inerte ($out)" ;; esac
out=$(HQSB_FORCE_UNAVAILABLE=1 run --probe 2>&1); rc=$?
check "--probe sem jaula: rc 97" 97 $rc
case "$out" in "HQSB: indisponivel "*) ok ;; *) bad "--probe sem jaula: não disse indisponivel ($out)" ;; esac

# ── ambiente: tem Landlock? ────────────────────────────────────────────────────────────────────────────
JAIL=0
out=$(run --probe 2>&1) && case "$out" in "HQSB: abi="*) JAIL=1 ;; esac
if [ "$JAIL" != 1 ]; then
  SKIP=1
  echo "AMBIENTE: sem Landlock ABI >= 4 aqui ($out): os casos de jaula e os mutantes NÃO rodaram (o nó roda)"
else
  # ── com jaula ──────────────────────────────────────────────────────────────────────────────────────
  echo vivo > "$W/fora/sentinela"
  run --rw "$W/rw" -- sh -c "echo x > '$W/fora/novo'" > /dev/null 2>&1;   nz "escrever fora do --rw falha" $?
  [ ! -e "$W/fora/novo" ] && ok || bad "escrever fora: o arquivo apareceu"
  run --rw "$W/rw" -- rm -f "$W/fora/sentinela" > /dev/null 2>&1;         check "apagar fora do --rw falha" 1 $?
  [ "$(cat "$W/fora/sentinela" 2> /dev/null)" = vivo ] && ok || bad "apagar fora: a sentinela sumiu ou mudou"
  run --rw "$W/rw" -- sh -c ": > '$W/fora/sentinela'" > /dev/null 2>&1;   nz "truncar fora do --rw falha" $?
  [ "$(cat "$W/fora/sentinela" 2> /dev/null)" = vivo ] && ok || bad "truncar fora: a sentinela foi truncada"
  run --rw "$W/rw" -- mkdir "$W/fora/pasta" > /dev/null 2>&1;             check "criar pasta fora do --rw falha" 1 $?
  run --rw "$W/rw" -- ln -s x "$W/fora/elo" > /dev/null 2>&1;             check "criar symlink fora do --rw falha" 1 $?
  [ "$(ls "$W/fora")" = sentinela ] && ok || bad "fora do --rw apareceu algo: $(ls "$W/fora" | tr '\n' ' ')"
  run --rw "$W/rw" -- sh -c "echo dentro > '$W/rw/a' && cat '$W/rw/a' && mkdir '$W/rw/d' && rm '$W/rw/a'" > "$W/saida" 2>&1; check "escrever, criar pasta e apagar DENTRO do --rw funciona" 0 $?
  [ "$(head -n 1 "$W/saida")" = dentro ] && ok || bad "dentro: não leu o que escreveu ($(cat "$W/saida"))"
  run --rw "$W/rw" -- sh -c "echo x > /dev/null" > /dev/null 2>&1;        check "/dev/null continua gravável" 0 $?
  run --rw "$W/rw" -- sh -c "exit 7" > /dev/null 2>&1;                    check "o rc do comando passa" 7 $?
  run --rw "$W/rw" -- /nao/existe/mesmo > /dev/null 2>&1;                 check "comando inexistente: 127" 127 $?
  # TCP: o pai escuta, o filho preso tenta conectar; quem confere é o pai
  python3 -I - "$SB" "$W/rw" > "$W/tcp.out" 2>&1 << 'PY'
import socket, subprocess, sys
sb, rw = sys.argv[1:3]
lis = socket.socket(); lis.bind(("127.0.0.1", 0)); lis.listen(2); lis.setblocking(False)
port = lis.getsockname()[1]
code = "import socket,sys; socket.create_connection(('127.0.0.1', %d), 3)" % port
p = subprocess.run([sys.executable, sb, "--rw", rw, "--", sys.executable, "-I", "-c", code], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    lis.accept(); acc = 1
except BlockingIOError:
    acc = 0
# controle positivo: o MESMO código, sem a jaula, conecta (senão "ninguém conectou" não provaria nada)
q = subprocess.run([sys.executable, "-I", "-c", code], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    lis.accept(); acc2 = 1
except BlockingIOError:
    acc2 = 0
print("preso_rc=%d aceitou=%d solto_rc=%d aceitou_solto=%d" % (p.returncode, acc, q.returncode, acc2))
PY
  [ "$(cat "$W/tcp.out")" = "preso_rc=1 aceitou=0 solto_rc=0 aceitou_solto=1" ] && ok || bad "TCP: $(cat "$W/tcp.out")"
  out=$(run --prove --rw "$W/rw" 2>&1); rc=$?
  check "--prove: rc 0" 0 $rc
  case "$out" in "HQSB: provado abi="*) ok ;; *) bad "--prove: não disse provado ($out)" ;; esac
  [ -z "$(ls -A "$W/rw" | grep hqsb-prova)" ] && ok || bad "--prove deixou sobra no --rw"

  # ── mutantes do lançador ───────────────────────────────────────────────────────────────────────────
  # mut NOME ANTIGO NOVO [BASE]: copia o lançador (ou o BASE, para empilhar dois mutantes), troca ANTIGO por NOVO (tem de casar exatamente 1 vez) e deixa o resultado em $W/mut-NOME.py
  mut() {
    python3 -I - "${4:-$SB}" "$W/mut-$1.py" "$2" "$3" << 'PY' || { [ "${MUT_QUIET:-}" = 1 ] || bad "mutante $1: INVÁLIDO (âncora não casa exatamente 1 vez)"; return 1; }
import sys
src, dst, old, new = sys.argv[1:5]
t = open(src, encoding="utf-8").read()
n = t.count(old)
if n != 1:
    print("âncora casa %d vezes: %r" % (n, old[:70]), file=sys.stderr); sys.exit(1)
open(dst, "w", encoding="utf-8").write(t.replace(old, new))
PY
  }
  # mutante que a prova tem de recusar: `--prove` do mutante precisa dar 97 + inerte
  pmut() {
    mut "$1" "$3" "$4" "${5:-}" || return
    out=$(python3 -I "$W/mut-$1.py" --prove --rw "$W/rw" 2>&1); rc=$?
    if [ "$rc" = 97 ] && case "$out" in "HQSB: inerte "*) true ;; *) false ;; esac; then ok; else bad "mutante $1 SOBREVIVEU ($2): --prove deu rc $rc: $out"; fi
  }
  pmut sem-restrict   "a jaula nunca é fechada"                       'if libc.syscall(SYS_RESTRICT, fd, 0) != 0:' 'if False:'
  pmut sem-remove     "apagar arquivo deixa de ser tratado"            ' | A_REMOVE_FILE | A_MAKE' ' | A_MAKE'
  pmut sem-truncar    "truncar deixa de ser tratado"                   'A_REFER | A_TRUNCATE
' 'A_REFER
'
  pmut sem-make-dir   "criar pasta deixa de ser tratado"               '(1 << 6) | (1 << 7) | (1 << 8)' '(1 << 6) | (1 << 8)'
  pmut sem-tcp        "bind/connect TCP deixam de ser tratados"        'NET_BIND_TCP | NET_CONNECT_TCP))' '0))'
  pmut sem-dev        "/dev some das regras (jaula que barra tudo)"    'for d in list(rw) + ["/dev"]:' 'for d in list(rw):'
  # fachada: a jaula não fecha E o filho mente que barrou — só o que o PAI confere (sentinela, pasta de fora, conexão aceita) pode pegar
  mut sem-restrict-f 'if libc.syscall(SYS_RESTRICT, fd, 0) != 0:' 'if False:' && pmut fachada "o filho mente: só os fatos vistos pelo pai pegam" 'print("%s:ESCAPOU" % nome)' 'print("%s:barrado" % nome)' "$W/mut-sem-restrict-f.py"
  # mutantes de recusa. home-livre: a recusa de --rw = HOME some. sem-jaula-segue: com a jaula falhando o comando roda assim mesmo. Quem mata é o caso de recusa/fail-open acima
  mut home-livre 'if r == "/" or r == home or home.startswith(r.rstrip("/") + "/"):' 'if r == "/":' \
    && { HOME="$W/home" python3 -I "$W/mut-home-livre.py" --rw "$W/home" -- true > /dev/null 2>&1; rc=$?
         if [ "$rc" = 64 ]; then bad "mutante home-livre SOBREVIVEU: o --rw = HOME ainda é recusado"; else ok; fi; }
  mut sem-jaula-segue 'print("hq-sandbox-run: sem jaula, o comando NÃO roda (%s)" % e, file=sys.stderr)
        return 97' 'print("hq-sandbox-run: sem jaula (%s)" % e, file=sys.stderr)' \
    && { rm -f "$W/rw/rodou-mut"; HQSB_FORCE_UNAVAILABLE=1 python3 -I "$W/mut-sem-jaula-segue.py" --rw "$W/rw" -- touch "$W/rw/rodou-mut" > /dev/null 2>&1
         if [ -e "$W/rw/rodou-mut" ]; then ok; else bad "mutante sem-jaula-segue SOBREVIVEU: o comando não rodou sem jaula, o caso não pega o fail-open"; fi; }
  # controle do controle: o `mut` recusa uma âncora ambígua e uma que não casa
  if MUT_QUIET=1 mut ancora-ambigua 'import' 'import' 2> /dev/null; then bad "mut aceitou âncora que casa várias vezes"; else ok; fi
  if MUT_QUIET=1 mut ancora-ausente 'texto-que-nao-existe-no-lancador' 'y' 2> /dev/null; then bad "mut aceitou âncora que não casa"; else ok; fi
fi

echo "hq-sandbox-run selftest: $PASS passed, $FAIL failed$([ "$SKIP" = 1 ] && echo ", casos de jaula e mutantes NÃO rodaram (AMBIENTE)")"
[ "$FAIL" -eq 0 ] || exit 1
[ "$SKIP" -eq 0 ] || exit 97
exit 0
