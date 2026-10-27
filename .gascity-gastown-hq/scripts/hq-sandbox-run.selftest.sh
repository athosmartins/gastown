#!/usr/bin/env bash
# hq-sandbox-run.selftest.sh (ga-2hd02v.5.6.1) — a jaula Landlock do lastro: escrita só onde se manda, TCP cortado, e sem jaula provada nada roda.
#
# ## Contents
#   Hermético · Casos · Mutantes · Ambiente (97)
#
# HERMÉTICO: tudo numa pasta descartável; HOME falso para o caso do --rw que anularia a jaula; as sentinelas ficam FORA do --rw e são conferidas por quem chamou (o rc de uma chamada não prova nada).
# CASOS: uso e recusas (rodam em qualquer sistema; inclusive o HOME vazio, que não existe ou é "/": sem HOME legível a recusa de --rw = HOME não se confere) · sem jaula (HQSB_FORCE_UNAVAILABLE) o comando NÃO
#   roda · com jaula (só Linux com Landlock ABI >= 4, o nó): escrever, apagar, truncar e abrir TCP fora do --rw falham e o estado fora fica intacto, escrever dentro e em /dev/null funciona, o rc do comando
#   passa, `--prove` dá `provado` (com um --rw e com dois).
# MUTANTES do próprio lançador (cada âncora casa EXATAMENTE 1 vez, senão o caso é INVÁLIDO e reprova: âncora ambígua não prova nada, ga-31xxl5):
#   · UM direito da jaula zerado por vez (`A_X = 0`, tira o direito do ruleset E da regra do /dev): a prova tem de acusar EXATAMENTE os motivos daquele direito (`filho-nao-barrou-truncar alterado-s_truncar`...),
#     nem mais (a jaula que nem sobe acusaria tudo, e foi assim que o mutante sem-truncar morria por acidente, com o EINVAL do /dev) nem menos. Um caso confere que cada direito do lançador TEM seu mutante.
#   · não chamar o restrict_self, tirar o TCP, deixar o /dev de fora, uma regra que o ruleset não trata (a jaula não sobe), só o 1º --rw na jaula, o --rw=HOME passar, o HOME ilegível passar e seguir sem jaula
#     quando ela falha: pegos por `--prove` (com os motivos) ou pelos casos de recusa.
#   · a prova enganada (o filho mente, o connect falha por outro motivo, o filho não roda, o filho solta byte que não é UTF-8): ela diz inerte, nunca provado, e nunca um traceback.
#   · todo mutante de `--prove` é conferido também por não deixar `.hqsb-prova-*` num --rw.
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
mkdir -p "$W/rw" "$W/rw2" "$W/home" "$W/fora"
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
# HOME que não dá para ler deixaria a recusa acima inerte em silêncio: vazio (expanduser devolve "/"), pasta que não existe, "/" → recusa (64) mesmo com um --rw legítimo
HOME="" run --rw "$W/rw" -- true > /dev/null 2>&1;                     check "HOME vazio: recusa (a guarda do HOME não se confere)" 64 $?
HOME="$W/nao-existe" run --rw "$W/rw" -- true > /dev/null 2>&1;        check "HOME que não existe: recusa" 64 $?
HOME=/ run --rw "$W/rw" -- true > /dev/null 2>&1;                      check "HOME = /: recusa" 64 $?
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
  out=$(run --prove --rw "$W/rw" --rw "$W/rw2" 2>&1); rc=$?
  check "--prove com dois --rw: rc 0" 0 $rc
  case "$out" in "HQSB: provado abi="*"em 2 pasta(s)"*) ok ;; *) bad "--prove com dois --rw: não provou os dois ($out)" ;; esac
  [ -z "$(ls -A "$W/rw" "$W/rw2" | grep hqsb-prova)" ] && ok || bad "--prove com dois --rw deixou sobra"

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
  RWARGS=(--rw "$W/rw")
  # os motivos de `HQSB: inerte A B C (rc filho=N...)`, um por palavra e em ordem: o que o --prove do mutante reprovou
  motivos() { printf '%s\n' "$1" | grep -m1 '^HQSB: inerte ' | sed -e 's/^HQSB: inerte //' -e 's/ (rc filho=.*$//' | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//'; }
  sem_sobra() { if [ -z "$(ls -A "$W/rw" "$W/rw2" | grep hqsb-prova)" ]; then ok; else bad "mutante $1: o --prove deixou .hqsb-prova- num --rw"; fi; }
  # prova do mutante: `--prove` tem de dar 97 + inerte, e o que reprova é conferido de um destes dois jeitos
  #   pmut  NOME DESC ANTIGO NOVO [BASE]            só rc 97 + inerte (o que importa é que a prova não diga provado)
  #   pexat NOME DESC "MOTIVOS" ANTIGO NOVO [BASE]  os motivos são EXATAMENTE esses (nem a mais: a jaula que não sobe acusaria tudo; nem a menos: o direito perdido tem de se acusar)
  #   ptem  NOME DESC "MOTIVOS" ANTIGO NOVO [BASE]  os motivos INCLUEM esses (para o mutante que reprova junto muita coisa)
  prova_mut() {   # prova_mut NOME -> out, rc
    out=$(python3 -I "$W/mut-$1.py" --prove "${RWARGS[@]}" 2>&1); rc=$?
  }
  inerte_ou() { [ "$rc" = 97 ] && case "$out" in "HQSB: inerte "*) true ;; *) false ;; esac; }
  pmut() {
    mut "$1" "$3" "$4" "${5:-}" || return
    prova_mut "$1"
    if inerte_ou; then ok; else bad "mutante $1 SOBREVIVEU ($2): --prove deu rc $rc: $out"; fi
    sem_sobra "$1"
  }
  pexat() {
    mut "$1" "$4" "$5" "${6:-}" || return
    prova_mut "$1"
    local got want
    got=$(motivos "$out"); want=$(printf '%s\n' $3 | sort | tr '\n' ' ' | sed 's/ $//')
    if inerte_ou && [ "$got" = "$want" ]; then ok; else bad "mutante $1 ($2): esperava inerte com [$want], veio rc $rc com [$got] ($out)"; fi
    sem_sobra "$1"
  }
  ptem() {
    mut "$1" "$4" "$5" "${6:-}" || return
    prova_mut "$1"
    local got m falta=""
    got=" $(motivos "$out") "
    for m in $3; do case "$got" in *" $m "*) ;; *) falta="$falta $m" ;; esac; done
    if inerte_ou && [ -z "$falta" ]; then ok; else bad "mutante $1 ($2): faltou acusar [$falta ] (rc $rc: $out)"; fi
    sem_sobra "$1"
  }

  # um direito por vez. `zera NOME BIT MOTIVOS`: tira o direito do ruleset e da regra do /dev (é uma constante só) e a prova tem de acusar os MOTIVOS desse direito e mais nada. As operações de fora que o
  # direito perdido deixa passar saem como `filho-nao-barrou-X` (o filho vê) e como o fato que o pai vê (`alterado-`, `sumiu-`, `apareceu-fora:`, `tcp-conectou`); o que só o errno separa (dispositivo: EPERM
  # em vez de EACCES) só tem o primeiro; o mover entre pastas (A_REFER, EXDEV) é provado por dentro
  n_direitos=$(grep -Ec '^(A_|NET_)[A-Z_]+ = 1 << [0-9]+$' "$SB"); n_zerados=0
  zera() {
    n_zerados=$((n_zerados+1))
    pexat "zera-$1" "sem $1 a jaula deixa passar a operação desse direito" "$3" "$1 = 1 << $2
" "$1 = 0
"
  }
  zera A_WRITE_FILE     1  "filho-nao-barrou-escrever alterado-s_escrever"
  zera A_REMOVE_DIR     4  "filho-nao-barrou-rmdir sumiu-vazia"
  zera A_REMOVE_FILE    5  "filho-nao-barrou-apagar sumiu-s_apagar"
  zera A_MAKE_CHAR      6  "filho-nao-barrou-dispchar"
  zera A_MAKE_DIR       7  "filho-nao-barrou-pasta apareceu-fora:n-pasta"
  zera A_MAKE_REG       8  "filho-nao-barrou-criar apareceu-fora:n-reg"
  zera A_MAKE_SOCK      9  "filho-nao-barrou-soquete apareceu-fora:n-sock"
  zera A_MAKE_FIFO      10 "filho-nao-barrou-fifo apareceu-fora:n-fifo"
  zera A_MAKE_BLOCK     11 "filho-nao-barrou-dispbloco"
  zera A_MAKE_SYM       12 "filho-nao-barrou-elo apareceu-fora:n-elo"
  zera A_REFER          13 "dentro-movido"
  zera A_TRUNCATE       14 "filho-nao-barrou-truncar alterado-s_truncar"
  zera NET_BIND_TCP     0  "filho-nao-barrou-bind"
  zera NET_CONNECT_TCP  1  "filho-nao-barrou-tcp tcp-conectou"
  # classe: direito novo no lançador sem mutante aqui = direito que a prova não vê
  [ "$n_zerados" = "$n_direitos" ] && ok || bad "o lançador trata $n_direitos direitos e o selftest zera $n_zerados: falta o mutante do que ficou de fora"

  pmut sem-restrict   "a jaula nunca é fechada"                       'if libc.syscall(SYS_RESTRICT, fd, 0) != 0:' 'if False:'
  pexat sem-tcp       "bind/connect TCP deixam de ser tratados"        "filho-nao-barrou-tcp filho-nao-barrou-bind tcp-conectou" 'NET_BIND_TCP | NET_CONNECT_TCP))' '0))'
  pexat sem-dev       "/dev some das regras (jaula que barra tudo)"    "dentro-devnull" 'for d in list(rw) + ["/dev"]:' 'for d in list(rw):'
  # a jaula que NÃO SOBE (a regra do /dev pede o READ_FILE, que o ruleset não trata: EINVAL no add_rule): é o que o mutante sem-truncar antigo fazia por acidente. Aqui é de propósito, e a prova tem de dizer que
  # o filho não rodou (`filho-sem-saida`) e mostrar o motivo do launcher filho (add_rule errno=22), em vez de achar que um direito perdido foi pego
  ptem jaula-nao-sobe "add_rule do /dev recusado: nada roda"           "filho-sem-saida filho-nao-barrou-escrever filho-nao-barrou-truncar dentro-escrita" 'FS_WRITE if d != "/dev" else A_WRITE_FILE | A_TRUNCATE' 'FS_WRITE if d != "/dev" else A_WRITE_FILE | A_TRUNCATE | (1 << 2)'
  case "$out" in *"add_rule /dev errno=22"*) ok ;; *) bad "jaula-nao-sobe: a prova não mostrou por que a jaula não subiu ($out)" ;; esac
  # --prove prova TODOS os --rw: só o 1º na jaula → os 10 passos de dentro do 2º falham
  RWARGS=(--rw "$W/rw" --rw "$W/rw2")
  pexat so-primeiro-rw "só o 1º --rw entra na jaula" "dentro1-escrita dentro1-pasta dentro1-movido dentro1-apagado dentro1-rmdir dentro1-truncado dentro1-elo dentro1-fifo dentro1-soquete dentro1-devnull" 'for d in list(rw) + ["/dev"]:' 'for d in list(rw[:1]) + ["/dev"]:'
  RWARGS=(--rw "$W/rw")
  # fachada: a jaula não fecha E o filho mente que barrou — só o que o PAI confere (sentinela, pasta de fora, conexão aceita) pode pegar
  mut sem-restrict-f 'if libc.syscall(SYS_RESTRICT, fd, 0) != 0:' 'if False:' && ptem fachada "o filho mente: só os fatos vistos pelo pai pegam" "alterado-s_escrever alterado-s_truncar sumiu-s_apagar sumiu-vazia tcp-conectou" 'print("%s:ESCAPOU" % nome)' 'print("%s:barrado" % nome)' "$W/mut-sem-restrict-f.py"
  # terceiro estado: "o connect falhou" não é "a jaula barrou". Sem os direitos de rede E apontando para uma porta fechada, o connect volta ECONNREFUSED e o pai não vê conexão aceita: só o filho
  # separar EACCES de qualquer outro erro impede o `provado` falso. E o filho que nem chega a rodar (interpretador que não existe) tem de dar inerte, não provado.
  mut sem-tcp-recusado 'NET_BIND_TCP | NET_CONNECT_TCP))' '0))' \
    && pexat connect-recusado "o connect falha por outro motivo (ECONNREFUSED) e a prova diz provado" "filho-nao-barrou-tcp filho-nao-barrou-bind" 'socket.create_connection(("127.0.0.1", porta), 3)' 'socket.create_connection(("127.0.0.1", 1), 3)' "$W/mut-sem-tcp-recusado.py"
  ptem filho-nao-roda "o filho da prova não executa e a prova diz provado" "filho-sem-saida filho-nao-barrou-escrever dentro-escrita" 'sys.executable, "-I", "-c", PROVA_FILHO, fora' '"/nao/existe/python", "-I", "-c", PROVA_FILHO, fora'
  # o filho que solta byte que não é UTF-8: a prova segue (os fatos são do pai) ou diz inerte, mas nunca estoura em traceback com rc 1. O controle: sem o errors="replace" e com o except estreito, estoura
  lixo_ok() { local o r; o=$(python3 -I "$1" --prove --rw "$W/rw" 2>&1); r=$?; case "$o" in *Traceback*) return 1 ;; esac; case "$o" in "HQSB: "*) [ "$r" = 0 ] || [ "$r" = 97 ] ;; *) return 1 ;; esac; }
  if mut lixo-no-filho 'fora, porta = sys.argv[1], int(sys.argv[2])' 'fora, porta = sys.argv[1], int(sys.argv[2]); sys.stdout.buffer.write(bytes([255, 254, 10]))'; then
    if lixo_ok "$W/mut-lixo-no-filho.py"; then ok; else bad "filho com byte inválido: a prova estourou (traceback ou rc que não é 0/97)"; fi
    mut lixo-sem-replace 'universal_newlines=True, errors="replace"' 'universal_newlines=True' "$W/mut-lixo-no-filho.py" \
      && mut lixo-except-estreito 'except Exception as e:' 'except (OSError, subprocess.SubprocessError) as e:' "$W/mut-lixo-sem-replace.py" \
      && { if lixo_ok "$W/mut-lixo-except-estreito.py"; then bad "o caso do byte inválido não pega o decode estrito com except estreito (controle sem dentes)"; else ok; fi; }
    sem_sobra lixo
  fi
  # mutantes de recusa. home-livre: a recusa de --rw = HOME some. home-ilegivel: o HOME vazio deixa de ser recusado. sem-jaula-segue: com a jaula falhando o comando roda assim mesmo. Quem mata é o caso de recusa/fail-open acima
  mut home-livre 'if r == "/" or r == home or home.startswith(r.rstrip("/") + "/"):' 'if r == "/":' \
    && { HOME="$W/home" python3 -I "$W/mut-home-livre.py" --rw "$W/home" -- true > /dev/null 2>&1; rc=$?
         if [ "$rc" = 64 ]; then bad "mutante home-livre SOBREVIVEU: o --rw = HOME ainda é recusado"; else ok; fi; }
  mut home-ilegivel 'if not os.path.isabs(home) or not os.path.isdir(home) or home == "/":' 'if False:' \
    && { HOME="" python3 -I "$W/mut-home-ilegivel.py" --rw "$W/rw" -- true > /dev/null 2>&1; rc=$?
         if [ "$rc" = 64 ]; then bad "mutante home-ilegivel SOBREVIVEU: o HOME vazio ainda é recusado"; else ok; fi; }
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
