#!/usr/bin/env bash
# hetzner-ballast-newfail.selftest.sh — hermético (ga-r4lw72): `ssh` e `bd` são scripts de brinquedo que anotam a chamada; a cidade e o nó são pastas temporárias. Nada fala com o nó nem com o rig do WA.
#
# Contents
#   Casos · Controle negativo (mutantes) · Variáveis
#
# CASOS: bandeira do nó ausente = não faz nada · ssh fora = rc 98 · arquivo do nó ausente = nada confirmado (rc 0) · leitura do nó que falha, JSON ruim, forma errada = rc 3 e NADA é aberto (erro nunca vira "0 confirmadas") ·
#   lista nova = UMA bead (bug, P2, labels, corpo com a lista COMPLETA, também com 237 ids) e o estado guarda o id · mesma lista = nada · lista que muda = comentário na mesma bead · bead fechada pelo dono = abre outra ·
#   bead que não consigo ler = não abre outra · lista que zera = um comentário (wa-suite "corrigidas"; hq-mutants nunca afirma "pegos" sem alvo julgado por inteiro) · estado local ilegível = rc 3 · `bd create` sem resposta certa (rc≠0, prazo estourado, sem id — com a bead NASCIDA ou não) = rc 3, estado
#   intacto, e a volta seguinte LISTA o rig antes de abrir (acha a nossa → comenta, não duplica; não acha → abre; não consegue listar → rc 3 e nada feito) · só conta como nossa a bead com a label e não fechada.
# CONTROLE NEGATIVO: cada mutante (um trecho do script trocado) TEM que reprovar a bateria.
# VARIÁVEIS: HNF_UNDER_TEST (script a testar) · HNF_PY (python; padrão /usr/bin/python3) · HNF_NO_MUTANTS=1 · HNF_JOBS (mutantes em paralelo; padrão 4)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
NF="${HNF_UNDER_TEST:-$HERE/hetzner-ballast-newfail.py}"
PY="${HNF_PY:-/usr/bin/python3}"
T=$(cd "$(mktemp -d /tmp/hnf.XXXXXX)" && pwd -P)
cleanup() { find "$T" -mindepth 1 -delete 2> /dev/null; rmdir "$T" 2> /dev/null; }
trap cleanup EXIT
trap 'exit 143' TERM INT HUP
fails=0; n=0
ok() {  # no modo mutante, a primeira falha encerra (só interessa se a bateria reprova)
  n=$((n+1))
  if [ "$1" = 0 ]; then [ -n "${HNF_MUTANT:-}" ] || echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); [ -z "${HNF_MUTANT:-}" ] || { echo "RESULT $fails/$n"; exit 1; }; fi
}
check() { if [ "$2" = "$3" ]; then ok 0 "$1"; else ok 1 "$1 (esperado '$2', veio '$3')"; fi; }

W="$T/w"; mkdir -p "$W"
cat > "$W/ssh" <<'EOF'
#!/bin/sh
# ssh de brinquedo: anota a chamada; com $W/ssh.rc sai com esse código (255 = não conectou, 10 = arquivo ausente, 11 = não consegui ler); senão imprime $W/node.confirmed
W="$(cd "$(dirname "$0")" && pwd)"; echo "ssh $*" >> "$W/ssh.calls"
if [ -f "$W/ssh.rc" ]; then rc=$(cat "$W/ssh.rc"); [ "$rc" = 0 ] || exit "$rc"; fi
cat "$W/node.confirmed"
EOF
cat > "$W/bd" <<'EOF'
#!/bin/sh
# bd de brinquedo: bd -C RIG show ID --json | list -l LABEL --json --limit 0 | create TITULO … --stdin --json | comment ID --stdin. Anota a linha (bd.calls) e o stdin (bd.stdin.N, N = chamadas que NÃO são list).
# bd.beads = as beads do rig, uma por linha: "ID STATUS [outro|sem]" (outro = outra label, sem = sem a chave labels); o create REGISTRA a bead em bd.beads, e é o que o list devolve.
# bd.label = a label que o list dá às beads (padrão origem:lastro-wa-suite). Se bd.status existe, o show E o list dão esse status a TODAS as beads (o dono "fechou": no bd de verdade as duas leituras vêm do mesmo registro).
# Falhas por arquivo: bd.show.fail · bd.list.fail (sai 1) · bd.list.garbage (não é JSON) · bd.list.shape (JSON que não é lista) · bd.create.fail (sai 1 SEM criar) ·
#   bd.create.lands-fail (CRIA e depois sai 1) · bd.create.lands-timeout (CRIA e depois fica parado: o prazo do script tem que matá-lo) · bd.create.noid (CRIA e responde sem id) · bd.comment.fail
W="$(cd "$(dirname "$0")" && pwd)"
echo "$*" >> "$W/bd.calls"
if [ "$3" = list ]; then
  [ -f "$W/bd.list.fail" ] && exit 1
  [ -f "$W/bd.list.garbage" ] && { echo 'isto nao e json'; exit 0; }
  [ -f "$W/bd.list.shape" ] && { echo 'null'; exit 0; }
  printf '['; sep=''
  while read -r id st lb; do
    [ -n "$id" ] || continue
    [ -f "$W/bd.status" ] && st=$(cat "$W/bd.status")
    case "$lb" in outro) lab=',"labels":["outra:coisa"]';; sem) lab='';; *) lab=',"labels":["'"$(cat "$W/bd.label" 2> /dev/null || echo origem:lastro-wa-suite)"'","area:testes"]';; esac
    printf '%s{"id":"%s","status":"%s"%s}' "$sep" "$id" "$st" "$lab"; sep=','
  done < "$W/bd.beads"
  echo ']'; exit 0
fi
k=$(cat "$W/bd.n" 2> /dev/null || echo 0); k=$((k+1)); echo "$k" > "$W/bd.n"
case "$3" in
  show) [ -f "$W/bd.show.fail" ] && exit 1; echo "[{\"id\":\"$4\",\"status\":\"$(cat "$W/bd.status" 2> /dev/null || echo open)\"}]" ;;
  create) cat > "$W/bd.stdin.$k"; [ -f "$W/bd.create.fail" ] && exit 1
    echo "wa-new$k open" >> "$W/bd.beads"
    [ -f "$W/bd.create.lands-fail" ] && exit 1
    [ -f "$W/bd.create.lands-timeout" ] && exec sleep 20
    if [ -f "$W/bd.create.noid" ]; then echo '[]'; else echo "[{\"id\":\"wa-new$k\"}]"; fi ;;
  comment) cat > "$W/bd.stdin.$k"; [ -f "$W/bd.comment.fail" ] && exit 1 ;;
esac
exit 0
EOF
chmod +x "$W/ssh" "$W/bd"

CITY=""
newcity() {  # newcity [semflag] — cidade nova (com a bandeira do nó, salvo "semflag") e as chamadas zeradas
  CITY="$T/city$((${CN:-0}+1))"; CN=$((${CN:-0}+1)); mkdir -p "$CITY/.gc"; [ "${1:-}" = semflag ] || : > "$CITY/.gc/hetzner-node.on"
  rm -f "$W"/ssh.* "$W"/bd.* "$W"/node.confirmed; : > "$W/ssh.calls"; : > "$W/bd.calls"; : > "$W/bd.beads"; echo 0 > "$W/bd.n"
}
mkconf() {  # mkconf QUANTOS [DESLOCAMENTO=0] — o wa-suite.confirmed do nó com QUANTOS ids tests/tNNN.py::t (faixa a…→b…)
  "$PY" -I -c 'import sys, json
n, off = int(sys.argv[1]), int(sys.argv[2])
print(json.dumps({"v": 1, "main": "c" * 40, "items": {"tests/t%03d.py::t" % i: {"from": "a" * 40, "to": "b" * 40, "seen": "c" * 40} for i in range(off, off + n)}}))' "$1" "${2:-0}" > "$W/node.confirmed"
}
nf() { OUT=$(env GC_CITY_PATH="$CITY" HB_SSH="$W/ssh" HB_BD="$W/bd" HB_WA_RIG=/rig HETZNER_NODE_HOST=node HB_BD_TIMEOUT="${BDT:-}" "$PY" -I "$NF" 2>&1); RC=$?; }   # BDT=N nf → prazo do bd em N s (vazio = o padrão do script)
nx() { OUT=$(env GC_CITY_PATH="$CITY" HB_SSH="$W/ssh" HB_BD="$W/bd" HB_WA_RIG=/rig HB_HQ_RIG="${HQRIG-/hq}" HETZNER_NODE_HOST=node "$PY" -I "$NF" "$@" 2>&1); RC=$?; }   # nx ARGS… (HQRIG="" → rig do HQ vazio, cai na cidade)
nh() { nx --fonte hq-mutants; }
hqcity() { newcity; echo origem:lastro-hq-mutants > "$W/bd.label"; }
mkhq() {  # mkhq QUANTOS [DESLOCAMENTO=0] — o hq-mutants.state.json do nó com QUANTOS sobreviventes s0NN em 2 alvos (par → a.sh, ímpar → b.sh), mais um alvo SEM a chave survivors
  "$PY" -I -c 'import sys, json
n, off = int(sys.argv[1]), int(sys.argv[2])
t = {"scripts/a.sh": {"hash": "h", "survivors": {}}, "scripts/b.sh": {"hash": "h", "survivors": {}}, "scripts/c.sh": {"hash": "h", "total": 3}}
for i in range(off, off + n):
    t["scripts/%s.sh" % "ab"[i % 2]]["survivors"]["s%03d" % i] = {"id": "s%03d" % i, "file": "scripts/%s.sh" % "ab"[i % 2], "line": 10 + i, "op": "cmp", "old": "-eq", "new": "-ne", "selftest": ["scripts/%s.selftest.sh" % "ab"[i % 2]]}
print(json.dumps({"v": 1, "targets": t}))' "$1" "${2:-0}" > "$W/node.confirmed"
}
calls() { grep -c -- "$1" "$W/$2" 2> /dev/null || true; }   # calls PADRAO ARQUIVO — quantas linhas anotadas casam
state() { "$PY" -I -c 'import sys, json
try:
    v = json.load(open(sys.argv[1] + "/.gc/hetzner-ballast/" + sys.argv[3]))
except FileNotFoundError:
    print("ausente"); sys.exit(0)
except (OSError, ValueError):
    print("ilegivel"); sys.exit(0)
print(v.get(sys.argv[2]) if isinstance(v, dict) else "forma")' "$CITY" "$1" "${2:-newfail.json}"; }   # state CHAVE [ARQUIVO]

g_all() {
  newcity semflag; mkconf 3; nf
  check "newfail: sem a bandeira do nó não faz nada (rc 0, PULADO, nenhuma chamada)" "0 1 0 0" "$RC $(printf '%s' "$OUT" | grep -c PULADO) $(wc -l < "$W/ssh.calls" | tr -d ' ') $(wc -l < "$W/bd.calls" | tr -d ' ')"
  newcity; mkconf 3; echo 255 > "$W/ssh.rc"; nf
  check "newfail: ssh que não conectou (255) → rc 98 e nada foi aberto" "98 0" "$RC $(wc -l < "$W/bd.calls" | tr -d ' ')"
  newcity; echo 10 > "$W/ssh.rc"; nf
  check "newfail: arquivo ausente no nó (o wa-suite ainda não confirmou nada) → rc 0, nada aberto" "0 0 ausente" "$RC $(wc -l < "$W/bd.calls" | tr -d ' ') $(state fp)"
  newcity; echo 11 > "$W/ssh.rc"; nf
  check "newfail: o nó NÃO conseguiu ler o arquivo (rc 11) → rc 3, nunca '0 confirmadas'" "3 0" "$RC $(wc -l < "$W/bd.calls" | tr -d ' ')"
  newcity; echo 'isto nao e json' > "$W/node.confirmed"; nf
  check "newfail: arquivo do nó que não é JSON → rc 3, nada aberto" "3 0" "$RC $(wc -l < "$W/bd.calls" | tr -d ' ')"
  newcity; echo '{"v": 2, "items": {}}' > "$W/node.confirmed"; nf
  check "newfail: forma errada (v 2) → rc 3, nada aberto" "3 0" "$RC $(wc -l < "$W/bd.calls" | tr -d ' ')"
  newcity; echo '{"v": 1, "items": {"x": 5}}' > "$W/node.confirmed"; nf
  check "newfail: item que não é objeto → rc 3, nada aberto" "3 0" "$RC $(wc -l < "$W/bd.calls" | tr -d ' ')"

  newcity; mkconf 3; nf
  check "newfail: lista nova → UMA bead (create, bug, P2, stdin, json, as duas labels, no rig do WA) e o estado guarda o id" "0 1 1 1 1 1 wa-new1 3" \
    "$RC $(calls '^-C /rig create .* -t bug -p 2 --stdin --json -l origem:lastro-wa-suite -l area:testes$' bd.calls) $(calls 'create' bd.calls) $(grep -c 'tests/t000.py::t' "$W/bd.stdin.1") $(grep -c 'tests/t002.py::t' "$W/bd.stdin.1") $(grep -c '^FAIXA aaaaaaaaa .. bbbbbbbbb (3)$' "$W/bd.stdin.1") $(state bead) $(state n)"
  nf
  check "newfail: a MESMA lista de novo → nada a fazer (nenhum bd novo: continuam as 2 chamadas da abertura, o list e o create)" "0 1 2" "$RC $(printf '%s' "$OUT" | grep -c 'nada a fazer') $(wc -l < "$W/bd.calls" | tr -d ' ')"
  # (o show da volta acima não existe: a mesma lista nem lê a bead) — a lista MUDA, a bead está aberta → comentário na mesma bead
  mkconf 4; nf
  check "newfail: lista que MUDA com a bead aberta → comentário na MESMA bead (nenhum create novo), com o id novo no corpo" "0 1 1 1 wa-new1" "$RC $(calls 'comment wa-new1 --stdin' bd.calls) $(calls 'create' bd.calls) $(grep -c 'tests/t003.py::t' "$W/bd.stdin.3") $(state bead)"
  b=$(wc -l < "$W/bd.calls" | tr -d ' '); nf
  check "newfail: a lista que acabou de ser comentada, de novo → nada (o comentário gravou o estado)" "$b" "$(wc -l < "$W/bd.calls" | tr -d ' ')"
  echo closed > "$W/bd.status"; mkconf 5; nf
  check "newfail: bead FECHADA pelo dono → abre outra (2 creates no total), o estado passa a ter a nova" "0 2 1" "$RC $(calls 'create' bd.calls) $(state bead | grep -c '^wa-new')"
  : > "$W/bd.calls"; nf
  check "newfail: bead fechada pelo dono e a MESMA lista → nada (só uma lista DIFERENTE abre outra bead; o doc diz isso)" "0 0" "$RC $(wc -l < "$W/bd.calls" | tr -d ' ')"
  rm -f "$W/bd.status"; mkconf 6; : > "$W/bd.calls"; touch "$W/bd.show.fail"; nf
  check "newfail: bead que NÃO consigo ler (show falha) → rc 3 e nem create nem comment" "3 0 0" "$RC $(calls 'create' bd.calls) $(calls 'comment' bd.calls)"

  newcity; mkconf 2; nf; echo '{"v": 1, "main": "c", "items": {}}' > "$W/node.confirmed"; : > "$W/bd.calls"; nf
  check "newfail: lista que ZERA com bead → um comentário 'corrigidas' (não fecha) e n vai a 0" "0 1 0 0" "$RC $(calls 'comment' bd.calls) $(calls 'close' bd.calls) $(state n)"
  nf
  check "newfail: lista vazia de novo → nada (a bead já foi avisada)" "0 1" "$RC $(calls 'comment' bd.calls)"
  newcity; echo '{"v": 1, "main": "c", "items": {}}' > "$W/node.confirmed"; nf
  check "newfail: lista vazia e nenhuma bead nossa → nada" "0 0" "$RC $(wc -l < "$W/bd.calls" | tr -d ' ')"

  newcity; mkconf 3; mkdir -p "$CITY/.gc/hetzner-ballast"; echo 'lixo' > "$CITY/.gc/hetzner-ballast/newfail.json"; nf
  check "newfail: estado local ilegível → rc 3, não abre nem comenta (avisar de novo duplicaria)" "3 0" "$RC $(wc -l < "$W/bd.calls" | tr -d ' ')"
  # `bd create` SEM resposta certa (rc≠0, prazo estourado, sem id): a bead PODE ter nascido. O estado local não muda e a volta seguinte LISTA o rig antes de abrir:
  # acha uma nossa aberta → comenta nela; não acha → abre; não consegue listar → rc 3 e nada feito
  LIST_LINE='^-C /rig list -l origem:lastro-wa-suite --json --limit 0$'
  newcity; mkconf 3; touch "$W/bd.create.fail"; nf
  check "newfail: bd create que sai com rc≠0 SEM criar nada → rc 3, estado NÃO gravado, e o texto não afirma 'nada foi registrado' (o código não sabe)" "3 ausente 0" "$RC $(state fp) $(printf '%s' "$OUT" | grep -ci 'nada foi registrado')"
  rm -f "$W/bd.create.fail"; : > "$W/bd.calls"; nf
  check "newfail: volta seguinte: lista o rig (com --limit 0), não acha nenhuma nossa e abre a bead (1 list, 1 create, estado com o id)" "0 1 1 1" "$RC $(calls "$LIST_LINE" bd.calls) $(calls 'create' bd.calls) $(state bead | grep -c '^wa-new')"
  newcity; mkconf 3; touch "$W/bd.create.lands-fail"; nf
  check "newfail: bd create que CRIA a bead e depois sai com rc≠0 → rc 3 e estado NÃO gravado" "3 ausente" "$RC $(state fp)"
  rm -f "$W/bd.create.lands-fail"; : > "$W/bd.calls"; nf
  check "newfail: volta seguinte acha a bead que nasceu: comenta nela e NÃO abre outra (0 create, 1 bead no rig, estado com o id dela)" "0 0 1 1 wa-new1" "$RC $(calls 'create' bd.calls) $(calls 'comment wa-new1 --stdin' bd.calls) $(wc -l < "$W/bd.beads" | tr -d ' ') $(state bead)"
  check "newfail: o comentário na bead reencontrada leva a lista COMPLETA e diz que foi reencontrada" "1 1" "$(grep -c 'reencontrada' "$W/bd.stdin.2") $(grep -c 'tests/t002.py::t' "$W/bd.stdin.2")"
  newcity; mkconf 3; touch "$W/bd.create.lands-timeout"; BDT=3 nf
  check "newfail: bd create que CRIA a bead e estoura o prazo (HB_BD_TIMEOUT=3) → rc 3, o texto diz 'estourou o prazo', estado NÃO gravado" "3 1 ausente" "$RC $(printf '%s' "$OUT" | grep -c 'estourou o prazo') $(state fp)"
  rm -f "$W/bd.create.lands-timeout"; : > "$W/bd.calls"; nf
  check "newfail: volta seguinte ao prazo estourado acha a bead que nasceu: comenta nela, NÃO abre outra (0 create, 1 bead no rig)" "0 0 1 1 wa-new1" "$RC $(calls 'create' bd.calls) $(calls 'comment wa-new1 --stdin' bd.calls) $(wc -l < "$W/bd.beads" | tr -d ' ') $(state bead)"
  newcity; mkconf 3; touch "$W/bd.create.noid"; nf
  check "newfail: bd create que CRIA a bead mas responde sem o id → rc 3 e estado NÃO gravado" "3 ausente" "$RC $(state fp)"
  rm -f "$W/bd.create.noid"; : > "$W/bd.calls"; nf
  check "newfail: volta seguinte acha a bead que nasceu sem id na resposta: comenta nela, NÃO abre outra" "0 0 1 1" "$RC $(calls 'create' bd.calls) $(calls 'comment wa-new1 --stdin' bd.calls) $(wc -l < "$W/bd.beads" | tr -d ' ')"

  # não consigo LISTAR o rig: "falhou" nunca vira "nenhuma nossa" (abrir outra duplicaria)
  newcity; mkconf 3; touch "$W/bd.list.fail"; nf
  check "newfail: bd list falha → rc 3 e nem create nem comment, estado NÃO gravado" "3 0 0 ausente" "$RC $(calls 'create' bd.calls) $(calls 'comment' bd.calls) $(state fp)"
  rm -f "$W/bd.list.fail"; touch "$W/bd.list.garbage"; nf
  check "newfail: bd list devolve lixo (não é JSON) → rc 3 e nada criado" "3 0" "$RC $(calls 'create' bd.calls)"
  rm -f "$W/bd.list.garbage"; touch "$W/bd.list.shape"; nf
  check "newfail: bd list devolve JSON que não é uma lista (null) → rc 3 (nunca traceback) e nada criado" "3 0" "$RC $(calls 'create' bd.calls)"
  rm -f "$W/bd.list.shape"; : > "$W/bd.calls"; nf
  check "newfail: o rig volta a listar → abre a bead (1 create), a falha da volta anterior não ficou gravada" "0 1" "$RC $(calls 'create' bd.calls)"

  # quem conta como "nossa": a label E não fechada
  newcity; mkconf 3; printf 'wa-c1 closed\nwa-o1 open outro\nwa-s1 open sem\n' > "$W/bd.beads"; nf
  check "newfail: o rig só tem bead nossa FECHADA, bead de OUTRA label e bead SEM labels → nenhuma é nossa aberta: abre a bead (1 create, 0 comment)" "0 1 0" "$RC $(calls 'create' bd.calls) $(calls 'comment' bd.calls)"
  newcity; mkconf 3; printf 'wa-c1 closed\nwa-zz9 open\nwa-aa1 in_progress\n' > "$W/bd.beads"; nf
  check "newfail: o rig já tem 2 nossas não fechadas (uma em andamento) → comenta na de MENOR id (wa-aa1), diz as duas, 0 create, estado com wa-aa1" "0 0 1 wa-aa1 1" "$RC $(calls 'create' bd.calls) $(calls 'comment wa-aa1 --stdin' bd.calls) $(state bead) $(printf '%s' "$OUT" | grep -c 'wa-aa1, wa-zz9')"

  # estado local que NÃO grava (uma PASTA no lugar do .tmp faz o open falhar): o bd JÁ respondeu, então a saída é rc 3 com a frase "NÃO gravei" e o estado antigo intacto, nunca traceback (rc 1)
  newcity; mkconf 3; mkdir -p "$CITY/.gc/hetzner-ballast/newfail.json.tmp"; nf
  check "newfail: abriu a bead mas o estado local não grava → rc 3 e 'NÃO gravei'" "3 1 1" "$RC $(calls 'create' bd.calls) $(printf '%s' "$OUT" | grep -c 'NÃO gravei')"
  rmdir "$CITY/.gc/hetzner-ballast/newfail.json.tmp"; : > "$W/bd.calls"; nf
  check "newfail: estado destravado, a volta seguinte acha a bead que abriu e comenta nela (0 create, estado com o id): não abre outra" "0 0 1 wa-new1" "$RC $(calls 'create' bd.calls) $(calls 'comment wa-new1 --stdin' bd.calls) $(state bead)"
  newcity; mkconf 3; nf; mkdir "$CITY/.gc/hetzner-ballast/newfail.json.tmp"; mkconf 4; : > "$W/bd.calls"; nf
  check "newfail: comentou a lista nova mas o estado local não grava → rc 3, 'NÃO gravei' e o estado antigo fica (n 3)" "3 1 1 3" "$RC $(calls 'comment wa-new1 --stdin' bd.calls) $(printf '%s' "$OUT" | grep -c 'NÃO gravei') $(state n)"
  newcity; mkconf 2; nf; mkdir "$CITY/.gc/hetzner-ballast/newfail.json.tmp"; echo '{"v": 1, "main": "c", "items": {}}' > "$W/node.confirmed"; : > "$W/bd.calls"; nf
  check "newfail: comentou 'corrigidas' mas o estado local não grava → rc 3, 'NÃO gravei' e n continua 2" "3 1 1 2" "$RC $(calls 'comment' bd.calls) $(printf '%s' "$OUT" | grep -c 'NÃO gravei') $(state n)"

  newcity; mkconf 237; nf
  check "newfail: 237 confirmadas → o corpo traz os 237 ids (a lista COMPLETA, sem o corte de 15 do resumo)" "237" "$(grep -c '^  tests/t[0-9]*.py::t$' "$W/bd.stdin.1")"
}

g_hq() {  # a fonte hq-mutants (ga-2hd02v.5.6.4): lê o estado do motor, abre a bead no rig do HQ, com label, estado e rig PRÓPRIOS
  local a
  newcity; mkhq 3
  for a in "--fonte" "--fonte nada" "--fonte hq-mutants x" "hq-mutants" "--fonte wa-suite hq-mutants" "--fonte=hq-mutants"; do
    nx $a
    check "newfail[hq]: argumento '$a' que não é UMA fonte conhecida → rc 2 'uso' e nada lido nem aberto (nunca cai na fonte padrão)" "2 1 0 0" "$RC $(printf '%s' "$OUT" | grep -c 'newfail: uso:') $(wc -l < "$W/ssh.calls" | tr -d ' ') $(wc -l < "$W/bd.calls" | tr -d ' ')"
  done
  newcity semflag; mkhq 3; nh
  check "newfail[hq]: sem a bandeira do nó não faz nada (rc 0, PULADO, nenhuma chamada)" "0 1 0 0" "$RC $(printf '%s' "$OUT" | grep -c PULADO) $(wc -l < "$W/ssh.calls" | tr -d ' ') $(wc -l < "$W/bd.calls" | tr -d ' ')"
  hqcity; mkhq 3; echo 255 > "$W/ssh.rc"; nh
  check "newfail[hq]: ssh que não conectou (255) → rc 98 e nada aberto" "98 0" "$RC $(wc -l < "$W/bd.calls" | tr -d ' ')"
  hqcity; echo 10 > "$W/ssh.rc"; nh
  check "newfail[hq]: o motor ainda não gravou o estado (arquivo ausente no nó) → rc 0, nada aberto, e foi hq-mutants.state.json que se pediu ao nó" "0 0 1 ausente" "$RC $(wc -l < "$W/bd.calls" | tr -d ' ') $(calls 'hq-mutants.state.json' ssh.calls) $(state fp newfail-hq-mutants.json)"
  hqcity; echo 11 > "$W/ssh.rc"; nh
  check "newfail[hq]: o nó NÃO conseguiu ler o estado (rc 11) → rc 3, nunca '0 sobreviventes'" "3 0" "$RC $(wc -l < "$W/bd.calls" | tr -d ' ')"
  bad() { hqcity; printf '%s\n' "$2" > "$W/node.confirmed"; nh; check "newfail[hq]: $1 → rc 3 e NADA aberto (erro nunca vira '0 sobreviventes')" "3 0" "$RC $(wc -l < "$W/bd.calls" | tr -d ' ')"; }
  bad "estado do motor que não é JSON" 'isto nao e json'
  bad "versão 2" '{"v": 2, "targets": {}}'
  bad "targets que é uma lista" '{"v": 1, "targets": []}'
  bad "alvo que não é objeto" '{"v": 1, "targets": {"a.sh": []}}'
  bad "survivors que é uma lista" '{"v": 1, "targets": {"a.sh": {"survivors": []}}}'
  bad "sobrevivente que não é objeto" '{"v": 1, "targets": {"a.sh": {"survivors": {"x": 5}}}}'
  bad "sobrevivente com a linha em texto" '{"v": 1, "targets": {"a.sh": {"survivors": {"x": {"file": "a.sh", "line": "7"}}}}}'
  bad "sobrevivente com a linha booleana (True é int em Python)" '{"v": 1, "targets": {"a.sh": {"survivors": {"x": {"file": "a.sh", "line": true}}}}}'
  hqcity; echo '{"v": 1, "targets": {"scripts/c.sh": {"hash": "h"}}}' > "$W/node.confirmed"; nh
  check "newfail[hq]: alvo SEM a chave survivors (o motor também aceita) = nenhum sobrevivente na lista → rc 0, nada aberto (sem bead anterior, não há o que dizer)" "0 0" "$RC $(wc -l < "$W/bd.calls" | tr -d ' ')"

  hqcity; mkhq 3; nh
  check "newfail[hq]: lista nova → UMA bead (create no rig /hq, task, P3, stdin, json, as duas labels do hq) e o estado do hq guarda o id e n" "0 1 1 wa-new1 3" "$RC $(calls '^-C /hq create hq-mutants do lastro: 3 mutante.* -t task -p 3 --stdin --json -l origem:lastro-hq-mutants -l area:testes$' bd.calls) $(calls 'create' bd.calls) $(state bead newfail-hq-mutants.json) $(state n newfail-hq-mutants.json)"
  check "newfail[hq]: o corpo agrupa por arquivo, com linha, troca, id e o selftest de cada sobrevivente; o alvo sem sobrevivente não aparece" "1 1 1 1 0" "$(grep -c '^ARQUIVO scripts/a.sh (2)$' "$W/bd.stdin.1") $(grep -c '^ARQUIVO scripts/b.sh (1)$' "$W/bd.stdin.1") $(grep -c '^  L10 \[cmp\] -eq -> -ne  id=s000  (testes: scripts/a.selftest.sh)$' "$W/bd.stdin.1") $(grep -c '^  L12 .* id=s002' "$W/bd.stdin.1") $(grep -c 'c.sh' "$W/bd.stdin.1")"
  check "newfail[hq]: as fontes não dividem estado: o newfail.json do wa-suite não nasceu" "ausente" "$(state fp newfail.json)"
  nh
  check "newfail[hq]: a MESMA lista de novo → nada a fazer (continuam as 2 chamadas: list e create)" "0 1 2" "$RC $(printf '%s' "$OUT" | grep -c 'nada a fazer') $(wc -l < "$W/bd.calls" | tr -d ' ')"
  mkhq 4; nh
  check "newfail[hq]: lista que MUDA com a bead aberta → comentário na MESMA bead (nenhum create novo), com o id novo no corpo" "0 1 1 1" "$RC $(calls 'comment wa-new1 --stdin' bd.calls) $(calls 'create' bd.calls) $(grep -c 'id=s003' "$W/bd.stdin.3")"
  echo closed > "$W/bd.status"; mkhq 5; nh
  check "newfail[hq]: bead FECHADA pelo dono + lista diferente → abre outra (2 creates no total)" "0 2" "$RC $(calls 'create' bd.calls)"
  # zera(JSON): a lista tinha 2 sobreviventes, o nó passa a mandar JSON; o comentário da 2ª volta está em bd.stdin.2
  zera() { hqcity; mkhq 2; nh; printf '%s\n' "$1" > "$W/node.confirmed"; : > "$W/bd.calls"; nh; }
  zc() { grep -c -- "$1" "$W/bd.stdin.2" 2> /dev/null || true; }   # zc TEXTO — linhas do comentário que zera com o texto
  zera '{"v": 1, "targets": {"scripts/a.sh": {"hash": "h", "total": 2, "verdicts": {"m1": "k", "m2": "i"}, "survivors": {}}}}'
  check "newfail[hq]: lista que ZERA com TODOS os alvos julgados por inteiro → um comentário (não fecha), n a 0, diz 'nenhum sobrevive' e não afirma causa" "0 1 0 0 1 0 0" "$RC $(calls 'comment' bd.calls) $(calls 'close' bd.calls) $(state n newfail-hq-mutants.json) $(zc 'nenhum sobrevive') $(zc 'NÃO prova') $(zc 'foram pegos')"
  zera '{"v": 1, "targets": {"scripts/a.sh": {"hash": "h2", "swept": 5, "skip": "base-vermelha", "retry_after": 9999999999}}}'
  check "newfail[hq]: lista que zera porque o alvo foi PULADO (base vermelha) → o comentário diz 'NÃO prova', conta 1 alvo não julgado e o nomeia com o motivo; não diz 'nenhum sobrevive'" "0 1 0 1 1 1 0" "$RC $(calls 'comment' bd.calls) $(state n newfail-hq-mutants.json) $(zc 'NÃO prova') $(zc 'NÃO julgados por inteiro agora: 1 \[scripts/a.sh (pulado: base-vermelha)\]') $(zc 'pulado: base-vermelha') $(zc 'nenhum sobrevive')"
  zera '{"v": 1, "targets": {"scripts/a.sh": {"hash": "h", "total": 3, "verdicts": {"m1": "k"}, "survivors": {}}}}'
  check "newfail[hq]: lista que zera com mutantes POR JULGAR (total 3, 1 veredito) → 'NÃO prova' e 'restam 2 de 3 mutantes'" "1 1 0" "$(zc 'NÃO prova') $(zc 'restam 2 de 3 mutantes') $(zc 'nenhum sobrevive')"
  zera '{"v": 1, "targets": {"scripts/a.sh": {"total": 0, "verdicts": {}}}}'
  check "newfail[hq]: lista que zera com alvo SEM hash (o motor nunca o gravou como varrido) → 'NÃO prova' e 'sem hash'" "1 1 0" "$(zc 'NÃO prova') $(zc 'sem hash') $(zc 'nenhum sobrevive')"
  zera '{"v": 1, "targets": {"scripts/a.sh": {"hash": "h"}}}'
  check "newfail[hq]: lista que zera com alvo sem total nem veredito → 'NÃO prova' e 'sem total de mutantes' (ausente não é 'julgado')" "1 1 0" "$(zc 'NÃO prova') $(zc 'sem total de mutantes') $(zc 'nenhum sobrevive')"
  zera '{"v": 1, "targets": {}}'
  check "newfail[hq]: estado NOVO do motor (targets {}) depois de uma lista → comentário 'NÃO prova' com 0 alvos e 'sem nenhum alvo'; n vai a 0 e nada é fechado" "0 1 0 0 1 1 1 0" "$RC $(calls 'comment' bd.calls) $(calls 'close' bd.calls) $(state n newfail-hq-mutants.json) $(zc 'NÃO prova') $(zc 'Estado do motor: 0 alvo') $(zc 'sem nenhum alvo') $(zc 'nenhum sobrevive')"
  zera '{"v": 1, "targets": {"scripts/a.sh": {"hash": "h", "total": 1, "verdicts": {"m1": "k"}, "survivors": {}}, "scripts/b.sh": {"hash": "h3", "skip": "scan-perdido", "perdido": "heredoc aberto"}}}'
  check "newfail[hq]: um alvo julgado e outro pulado → 'NÃO prova', 2 alvos no estado, 1 não julgado (o julgado não é listado)" "1 1 1 0" "$(zc 'NÃO prova') $(zc 'Estado do motor: 2 alvo.*julgados por inteiro agora: 1 \[scripts/b.sh (pulado: scan-perdido)\]') $(zc 'scan-perdido') $(zc 'scripts/a.sh (')"
  hqcity; mkhq 3; nh
  check "newfail[hq]: o corpo da bead avisa que a linha pode estar velha (alvo apagado ou ainda não varrido de novo mantém a dele)" "1" "$(grep -c 'pode estar velha' "$W/bd.stdin.1")"
  hqcity; mkhq 40; nh
  check "newfail[hq]: 40 sobreviventes → o corpo traz os 40 (a lista COMPLETA, sem o corte de 15 do resumo)" "40" "$(grep -c 'id=s[0-9][0-9][0-9]' "$W/bd.stdin.1")"

  hqcity; mkhq 2; HQRIG= nh
  check "newfail[hq]: HB_HQ_RIG vazio → o rig do HQ é a cidade (nunca um '-C' vazio)" "0 1" "$RC $(calls "^-C $CITY create " bd.calls)"
  hqcity; mkhq 2; nh; : > "$W/bd.beads"; rm -f "$W/bd.label"; mkconf 3; nf
  check "newfail[hq]: as duas fontes na MESMA cidade: uma bead em cada rig (/hq e /rig), cada uma no seu estado" "0 1 1 wa-new1 wa-new2 2 3" "$RC $(calls '^-C /hq create' bd.calls) $(calls '^-C /rig create' bd.calls) $(state bead newfail-hq-mutants.json) $(state bead newfail.json) $(state n newfail-hq-mutants.json) $(state n newfail.json)"
  newcity; mkhq 3; printf 'x1 open\nx2 in_progress\n' > "$W/bd.beads"; nh
  check "newfail[hq]: beads com a label do wa-suite no rig NÃO são nossas (a label é a do hq): lista com ela e abre a bead (1 list, 1 create, 0 comment)" "0 1 1 0" "$RC $(calls '^-C /hq list -l origem:lastro-hq-mutants --json --limit 0$' bd.calls) $(calls 'create' bd.calls) $(calls 'comment' bd.calls)"
  hqcity; mkhq 3; printf 'x9 closed\nx7 open\nx2 in_progress\n' > "$W/bd.beads"; nh
  check "newfail[hq]: o rig já tem 2 nossas (label do hq) não fechadas → comenta na de MENOR id (x2), 0 create, estado com x2" "0 0 1 x2" "$RC $(calls 'create' bd.calls) $(calls 'comment x2 --stdin' bd.calls) $(state bead newfail-hq-mutants.json)"
  hqcity; mkhq 3; touch "$W/bd.create.lands-fail"; nh
  check "newfail[hq]: bd create que CRIA a bead e sai com rc≠0 → rc 3 e estado do hq NÃO gravado" "3 ausente" "$RC $(state fp newfail-hq-mutants.json)"
  rm -f "$W/bd.create.lands-fail"; : > "$W/bd.calls"; nh
  check "newfail[hq]: volta seguinte lista o rig do hq, acha a bead que nasceu e comenta nela (0 create, estado com o id)" "0 0 1 1 wa-new1" "$RC $(calls 'create' bd.calls) $(calls 'comment wa-new1 --stdin' bd.calls) $(calls 'list -l origem:lastro-hq-mutants' bd.calls) $(state bead newfail-hq-mutants.json)"
  hqcity; mkhq 3; mkdir -p "$CITY/.gc/hetzner-ballast"; echo lixo > "$CITY/.gc/hetzner-ballast/newfail-hq-mutants.json"; nh
  check "newfail[hq]: estado local do hq ilegível → rc 3, não abre nem comenta" "3 0" "$RC $(wc -l < "$W/bd.calls" | tr -d ' ')"
  hqcity; mkhq 3; mkdir -p "$CITY/.gc/hetzner-ballast"; echo lixo > "$CITY/.gc/hetzner-ballast/newfail.json"; nh
  check "newfail[hq]: o estado do WA ilegível não trava o do hq: abre a bead (rc 0, 1 create)" "0 1" "$RC $(calls 'create' bd.calls)"
}

nw() { TZ=BRT3 nx --fonte wa-mutants; }   # TZ fixo (UTC-3, sem tzdata): o relógio do adiamento é UTC, e um mktime no lugar do timegm só aparece fora de UTC
wamcity() { newcity; echo origem:lastro-wa-mutants > "$W/bd.label"; }
mkwam() {  # mkwam QUANTOS [DESLOCAMENTO=0] [UNI=0] — o wa-mutants.state.json do nó com QUANTOS sobreviventes w0NN em 2 alvos (par → lib/a.py, ímpar → daemons/b.py), mais um alvo SEM a chave survivors; UNI=1 → trocas com letras fora do ASCII
  "$PY" -I -c 'import sys, json
n, off, uni = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3] == "1"
t = {"lib/a.py": {"hash": "h", "survivors": {}}, "daemons/b.py": {"hash": "h", "survivors": {}}, "lib/c.py": {"hash": "h", "total": 3}}
for i in range(off, off + n):
    f = ["lib/a.py", "daemons/b.py"][i % 2]
    t[f]["survivors"]["w%03d" % i] = {"id": "w%03d" % i, "file": f, "line": 10 + i, "op": "cmp", "old": "çã" * 10 if uni else "==", "new": "óé" * 10 if uni else "!=", "selftest": ["tests/test_a.py"]}
print(json.dumps({"v": 1, "targets": t}))' "$1" "${2:-0}" "${3:-0}" > "$W/node.confirmed"
}
mkwamord() {  # 4 alvos com contagens desiguais (z 3, m 2, lib/a 1, daemons/a 1), na ordem do JSON lib/a · lib/z · daemons/m · daemons/a, e as linhas de cada alvo FORA de ordem
  "$PY" -I -c 'import json
def r(f, l, i): return {"id": i, "file": f, "line": l, "op": "cmp", "old": "==", "new": "!=", "selftest": ["tests/t.py"]}
t = {"lib/a.py": {"hash": "h", "survivors": {"o1": r("lib/a.py", 50, "o1")}},
     "lib/z.py": {"hash": "h", "survivors": {"o2": r("lib/z.py", 90, "o2"), "o3": r("lib/z.py", 20, "o3"), "o4": r("lib/z.py", 55, "o4")}},
     "daemons/m.py": {"hash": "h", "survivors": {"o5": r("daemons/m.py", 7, "o5"), "o6": r("daemons/m.py", 3, "o6")}},
     "daemons/a.py": {"hash": "h", "survivors": {"o7": r("daemons/a.py", 5, "o7")}}}
print(json.dumps({"v": 1, "targets": t}))' > "$W/node.confirmed"
}
setat() {  # setat SEG|ausente|lixo — reescreve o "at" do estado do wa-mutants: SEG segundos ATRÁS (negativo = no futuro), "ausente" tira a chave, "lixo" grava um texto que não é data
  "$PY" -I -c 'import sys, json, time
p, a = sys.argv[1], sys.argv[2]
v = json.load(open(p))
if a == "ausente":
    v.pop("at", None)
elif a == "lixo":
    v["at"] = "ontem de tarde"
else:
    v["at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - int(a)))
json.dump(v, open(p, "w"))' "$CITY/.gc/hetzner-ballast/newfail-wa-mutants.json" "$1"
}
gapcase() {  # gapcase SEG|ausente|lixo [N=4] — abre a bead com 3, muda o "at" do estado, zera as chamadas e roda de novo com a lista de N: o que o 2º `nw` fez fica em bd.calls
  wamcity; mkwam 3; nw; mkwam "${2:-4}"; setat "$1"; : > "$W/bd.calls"; nw
}

g_wam() {  # a fonte wa-mutants (ga-tmfmvxi): o MESMO formato do hq-mutants, bead no rig do WA com label PRÓPRIA e SEM ctx:ready/exec:auto, texto com teto de tamanho, comentário espaçado em 6 h
  local a sz listed k
  newcity; mkwam 3
  for a in "--fonte wa-mutant" "--fonte WA-MUTANTS" "--fonte wa-mutants x" "wa-mutants" "--fonte=wa-mutants" "--fonte hq-mutants wa-mutants"; do
    nx $a
    check "newfail[wam]: argumento '$a' que não é UMA fonte conhecida → rc 2 'uso' e nada lido nem aberto" "2 1 0 0" "$RC $(printf '%s' "$OUT" | grep -c 'newfail: uso:') $(wc -l < "$W/ssh.calls" | tr -d ' ') $(wc -l < "$W/bd.calls" | tr -d ' ')"
  done
  newcity semflag; mkwam 3; nw
  check "newfail[wam]: sem a bandeira do nó não faz nada (rc 0, PULADO, nenhuma chamada)" "0 1 0 0" "$RC $(printf '%s' "$OUT" | grep -c PULADO) $(wc -l < "$W/ssh.calls" | tr -d ' ') $(wc -l < "$W/bd.calls" | tr -d ' ')"
  wamcity; mkwam 3; echo 255 > "$W/ssh.rc"; nw
  check "newfail[wam]: ssh que não conectou (255) → rc 98 e nada aberto" "98 0" "$RC $(wc -l < "$W/bd.calls" | tr -d ' ')"
  wamcity; echo 10 > "$W/ssh.rc"; nw
  check "newfail[wam]: o motor ainda não gravou o estado (arquivo ausente no nó) → rc 0, nada aberto, e foi wa-mutants.state.json que se pediu ao nó" "0 0 1 ausente" "$RC $(wc -l < "$W/bd.calls" | tr -d ' ') $(calls 'wa-mutants.state.json' ssh.calls) $(state fp newfail-wa-mutants.json)"
  wamcity; echo 11 > "$W/ssh.rc"; nw
  check "newfail[wam]: o nó NÃO conseguiu ler o estado (rc 11) → rc 3, nunca '0 sobreviventes'" "3 0" "$RC $(wc -l < "$W/bd.calls" | tr -d ' ')"
  badw() { wamcity; printf '%s\n' "$2" > "$W/node.confirmed"; nw; check "newfail[wam]: $1 → rc 3 e NADA aberto (erro nunca vira '0 sobreviventes')" "3 0" "$RC $(wc -l < "$W/bd.calls" | tr -d ' ')"; }
  badw "estado do motor que não é JSON" 'isto nao e json'
  badw "versão 2" '{"v": 2, "targets": {}}'
  badw "sobrevivente com a linha em texto" '{"v": 1, "targets": {"lib/a.py": {"survivors": {"x": {"file": "lib/a.py", "line": "7"}}}}}'

  wamcity; mkwam 3; nw
  check "newfail[wam]: lista nova → UMA bead (create no rig /rig, task, P3, stdin, json e SÓ as duas labels da fonte: nada de ctx:ready/exec:auto, que o watchdog de rota entregaria ao pool de dogs) e o estado guarda o id e n" "0 1 1 0 0 wa-new1 3" "$RC $(calls '^-C /rig create wa-mutants do lastro: 3 mutante.* -t task -p 3 --stdin --json -l origem:lastro-wa-mutants -l area:testes$' bd.calls) $(calls 'create' bd.calls) $(calls 'ctx:ready' bd.calls) $(calls 'exec:auto' bd.calls) $(state bead newfail-wa-mutants.json) $(state n newfail-wa-mutants.json)"
  check "newfail[wam]: as fontes não dividem estado: nem o newfail.json do wa-suite nem o do hq-mutants nasceram" "ausente ausente" "$(state fp newfail.json) $(state fp newfail-hq-mutants.json)"
  check "newfail[wam]: o corpo agrupa por arquivo, com linha, troca, id e testes de cada sobrevivente; o alvo sem sobrevivente não aparece" "1 1 1 0" "$(grep -c '^ARQUIVO lib/a.py (2)$' "$W/bd.stdin.1") $(grep -c '^ARQUIVO daemons/b.py (1)$' "$W/bd.stdin.1") $(grep -c '^  L10 \[cmp\] == -> !=  id=w000  (testes: tests/test_a.py)$' "$W/bd.stdin.1") $(grep -c 'lib/c.py' "$W/bd.stdin.1")"
  check "newfail[wam]: o corpo fala do código do WA (lib/, daemons/), diz que não é dado de lead, avisa que a linha pode estar velha e que a bead só muda a cada 6 h" "1 1 1 1" "$(grep -c 'código do WA (lib/, daemons/)' "$W/bd.stdin.1") $(grep -c 'Não é lead nem dado de cliente' "$W/bd.stdin.1") $(grep -c 'pode estar velha' "$W/bd.stdin.1") $(grep -c 'no máximo a cada 6 h' "$W/bd.stdin.1")"
  check "newfail[wam]: a última linha do corpo é a fonte (de onde sai a lista inteira)" "1" "$(tail -n 1 "$W/bd.stdin.1" | grep -c '^Fonte: ~/gt-remote/ballast/wa-mutants.state.json')"
  nw
  check "newfail[wam]: a MESMA lista de novo → nada a fazer (continuam as 2 chamadas: list e create)" "0 1 2" "$RC $(printf '%s' "$OUT" | grep -c 'nada a fazer') $(wc -l < "$W/bd.calls" | tr -d ' ')"

  # o adiamento: bead nossa aberta + lista diferente. O relógio é o "at" do estado local (UTC, gravado pelo próprio script)
  wamcity; mkwam 3; nw; mkwam 4; : > "$W/bd.calls"; nw
  check "newfail[wam]: o relógio que o PRÓPRIO script grava (sem reescrever o at) também adia: a lista que muda logo depois do aviso não comenta, e o at do estado é uma data UTC" "0 1 0 3 1" "$RC $(printf '%s' "$OUT" | grep -c 'adio o comentário') $(calls 'comment' bd.calls) $(state n newfail-wa-mutants.json) $(state at newfail-wa-mutants.json | grep -c '^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}Z$')"
  gapcase 10
  check "newfail[wam]: lista que muda com a bead aberta e o último aviso de segundos atrás → ADIA: rc 0, nenhum comentário, e o estado fica na lista velha (n 3) para a próxima volta tentar de novo" "0 1 0 3 wa-new1" "$RC $(printf '%s' "$OUT" | grep -c 'adio o comentário') $(calls 'comment' bd.calls) $(state n newfail-wa-mutants.json) $(state bead newfail-wa-mutants.json)"
  gapcase 21000
  check "newfail[wam]: último aviso há 5 h50 (menos que as 6 h) → ainda adia, nenhum comentário" "0 1 0 3" "$RC $(printf '%s' "$OUT" | grep -c 'adio o comentário') $(calls 'comment' bd.calls) $(state n newfail-wa-mutants.json)"
  gapcase 21900
  check "newfail[wam]: último aviso há 6 h05 → COMENTA na mesma bead (nenhum create), a lista nova entra no estado (n 4) e o comentário traz o id novo" "0 0 1 0 4 1" "$RC $(printf '%s' "$OUT" | grep -c 'adio o comentário') $(calls 'comment wa-new1 --stdin' bd.calls) $(calls 'create' bd.calls) $(state n newfail-wa-mutants.json) $(grep -c 'id=w003' "$W/bd.stdin.3")"
  gapcase 86400 4
  check "newfail[wam]: último aviso há um dia → comenta" "1" "$(calls 'comment wa-new1 --stdin' bd.calls)"
  gapcase ausente
  check "newfail[wam]: estado local SEM o relógio (gravado por uma versão antiga) → comenta na hora (repetido é melhor que perdido)" "0 1 4" "$RC $(calls 'comment wa-new1 --stdin' bd.calls) $(state n newfail-wa-mutants.json)"
  gapcase lixo
  check "newfail[wam]: relógio que não é data → comenta na hora, sem traceback" "0 1 0" "$RC $(calls 'comment wa-new1 --stdin' bd.calls) $(printf '%s' "$OUT" | grep -c Traceback)"
  gapcase -7200
  check "newfail[wam]: relógio NO FUTURO (+2 h; o relógio do mini andou para trás) → comenta na hora: adiar para sempre seria pior que repetir" "0 1" "$RC $(calls 'comment wa-new1 --stdin' bd.calls)"
  wamcity; mkwam 3; nw; echo closed > "$W/bd.status"; mkwam 5; nw
  check "newfail[wam]: bead FECHADA pelo dono + lista diferente, mesmo com o último aviso de segundos atrás → abre outra na hora (2 creates, 0 comentário): o espaçamento é só do comentário" "0 2 0" "$RC $(calls 'create' bd.calls) $(calls 'comment' bd.calls)"
  wamcity; mkwam 3; printf 'x9 closed\nx7 open\nx2 in_progress\n' > "$W/bd.beads"; nw
  check "newfail[wam]: sem estado e o rig já tem 2 nossas (label do wa-mutants) não fechadas → comenta na de MENOR id (x2) na hora, 0 create, e a listagem foi pela label do wa-mutants" "0 0 1 x2 1" "$RC $(calls 'create' bd.calls) $(calls 'comment x2 --stdin' bd.calls) $(state bead newfail-wa-mutants.json) $(calls '^-C /rig list -l origem:lastro-wa-mutants --json --limit 0$' bd.calls)"
  wamcity; echo origem:lastro-hq-mutants > "$W/bd.label"; mkwam 3; printf 'x1 open\nx2 in_progress\n' > "$W/bd.beads"; nw
  check "newfail[wam]: beads com a label do hq-mutants no rig NÃO são nossas → abre a bead (1 create, 0 comment)" "0 1 0" "$RC $(calls 'create' bd.calls) $(calls 'comment' bd.calls)"
  wamcity; mkwam 3; touch "$W/bd.create.lands-fail"; nw
  check "newfail[wam]: bd create que CRIA a bead e sai com rc≠0 → rc 3 e estado do wa-mutants NÃO gravado" "3 ausente" "$RC $(state fp newfail-wa-mutants.json)"
  rm -f "$W/bd.create.lands-fail"; : > "$W/bd.calls"; nw
  check "newfail[wam]: volta seguinte lista o rig, acha a bead que nasceu e comenta nela (0 create, estado com o id)" "0 0 1 wa-new1" "$RC $(calls 'create' bd.calls) $(calls 'comment wa-new1 --stdin' bd.calls) $(state bead newfail-wa-mutants.json)"
  wamcity; mkwam 3; mkdir -p "$CITY/.gc/hetzner-ballast"; echo lixo > "$CITY/.gc/hetzner-ballast/newfail-wa-mutants.json"; nw
  check "newfail[wam]: estado local do wa-mutants ilegível → rc 3, não abre nem comenta" "3 0" "$RC $(wc -l < "$W/bd.calls" | tr -d ' ')"
  hqcity; mkhq 2; nh; : > "$W/bd.beads"; echo origem:lastro-wa-mutants > "$W/bd.label"; mkwam 2; nw
  check "newfail[wam]: hq-mutants e wa-mutants na MESMA cidade: um create em cada rig (/hq e /rig), cada um no seu estado" "0 1 1 wa-new1 wa-new2" "$RC $(calls '^-C /hq create' bd.calls) $(calls '^-C /rig create' bd.calls) $(state bead newfail-hq-mutants.json) $(state bead newfail-wa-mutants.json)"
  hqcity; mkhq 3; nh; mkhq 4; nh
  check "newfail[wam]: o espaçamento é só do wa-mutants: o hq-mutants com a lista mudada segundos depois do aviso comenta na hora" "1" "$(calls 'comment wa-new1 --stdin' bd.calls)"

  # a ordem e o teto de tamanho
  wamcity; mkwamord; nw
  check "newfail[wam]: o corpo põe primeiro o arquivo com MAIS sobreviventes; no empate, o nome (daemons/a.py antes de lib/a.py)" "ARQUIVO lib/z.py (3) ARQUIVO daemons/m.py (2) ARQUIVO daemons/a.py (1) ARQUIVO lib/a.py (1)" "$(grep '^ARQUIVO' "$W/bd.stdin.1" | tr '\n' ' ' | sed 's/ $//')"
  check "newfail[wam]: dentro do arquivo, por linha (o JSON as trouxe fora de ordem)" "L20L55L90L3L7L5L50" "$(grep -o '^  L[0-9]*' "$W/bd.stdin.1" | tr -d ' \n')"
  wamcity; mkwam 40; nw
  check "newfail[wam]: 40 sobreviventes cabem: os 40 no corpo (a lista COMPLETA) e nenhuma linha de 'não listados'" "40 0" "$(grep -c 'id=w[0-9][0-9][0-9]' "$W/bd.stdin.1") $(grep -c 'NÃO listados' "$W/bd.stdin.1")"
  wamcity; mkwam 800 0 1; nw
  sz=$(wc -c < "$W/bd.stdin.1" | tr -d ' '); listed=$(grep -c 'id=w[0-9][0-9][0-9]' "$W/bd.stdin.1"); k=$(sed -n 's/^+\([0-9]*\) mutante(s) em .*/\1/p' "$W/bd.stdin.1")
  check "newfail[wam]: 800 sobreviventes (com letras fora do ASCII) → o corpo tem no máximo 40000 BYTES, e passa de 30000 (o teto não corta à toa)" "1 1" "$([ "$sz" -le 40000 ] && echo 1 || echo 0) $([ "$sz" -gt 30000 ] && echo 1 || echo 0)"
  check "newfail[wam]: o que não coube vira UMA linha com a conta, e os listados + os '+K' dão os 800; a fonte continua por último" "1 800 1" "$(grep -c 'NÃO listados aqui' "$W/bd.stdin.1") $((listed + ${k:-0})) $(tail -n 1 "$W/bd.stdin.1" | grep -c '^Fonte:')"
  check "newfail[wam]: a conta '+K em M arquivo(s)' diz os 2 arquivos" "1" "$(grep -c '^+[0-9]* mutante(s) em 2 arquivo(s) NÃO listados' "$W/bd.stdin.1")"
  gapcase 21900 800
  sz=$(wc -c < "$W/bd.stdin.3" | tr -d ' ')
  check "newfail[wam]: o COMENTÁRIO com 800 sobreviventes (aviso + lista) também fica em 40000 bytes" "1 1" "$([ "$sz" -le 40000 ] && echo 1 || echo 0) $(grep -c 'MUDOU (agora 800)' "$W/bd.stdin.3")"

  # a lista que ZERA: a bead nasce com 2, o nó passa a mandar o JSON de $1; o comentário está em bd.stdin.2 (o zero NÃO espera as 6 h: a bead acabou de nascer)
  zeraw() { wamcity; mkwam 2; nw; printf '%s\n' "$1" > "$W/node.confirmed"; : > "$W/bd.calls"; nw; }
  zw() { grep -c -- "$1" "$W/bd.stdin.2" 2> /dev/null || true; }   # zw TEXTO — linhas do comentário que zera com o texto
  zeraw '{"v": 1, "targets": {"lib/a.py": {"hash": "h", "total": 2, "verdicts": {"m1": "k", "m2": "k"}, "survivors": {}}}}'
  check "newfail[wam]: lista que ZERA com TODOS os alvos julgados por inteiro → um comentário na hora (não fecha), n a 0, diz 'nenhum sobrevive' e não afirma 'NÃO prova' nem 'pegos'" "0 1 0 0 1 0 0" "$RC $(calls 'comment' bd.calls) $(calls 'close' bd.calls) $(state n newfail-wa-mutants.json) $(zw 'nenhum sobrevive') $(zw 'NÃO prova') $(zw 'foram peg')"
  nw
  check "newfail[wam]: a mesma lista vazia de novo → nada (o comentário que zera não se repete)" "0 1" "$RC $(calls 'comment' bd.calls)"
  zeraw '{"v": 1, "targets": {"lib/ok.py": {"hash": "h", "total": 1, "verdicts": {"m": "k"}, "survivors": {}}, "lib/f1.py": {"hash": "h", "skip": "familia-grande:13"}, "lib/f2.py": {"hash": "h", "skip": "familia-grande:15"}, "lib/f3.py": {"hash": "h", "skip": "familia-grande:40"}, "lib/d1.py": {"hash": "h", "skip": "denylist:os.kill"}, "lib/d2.py": {"hash": "h", "skip": "denylist:os.killpg"}, "lib/s1.py": {"hash": "h", "skip": "sem-teste"}}}'
  check "newfail[wam]: lista que zera com 6 de 7 alvos FORA da varredura por desenho → 'NÃO prova', o estado do motor tem 7 alvos, 6 não julgados, e a conta vem por motivo (3× familia-grande; 2× denylist; 1× sem-teste, nessa ordem: o número do motivo não separa os grupos)" "1 1 1 0" "$(zw 'NÃO prova') $(zw 'Estado do motor: 7 alvo(s); NÃO julgados por inteiro agora: 6 \[') $(zw '\[3× pulado: familia-grande; 2× pulado: denylist; 1× pulado: sem-teste\]') $(zw 'nenhum sobrevive')"
  zeraw '{"v": 1, "targets": {"lib/a.py": {"hash": "h", "total": 3, "verdicts": {"m1": "k"}, "survivors": {}}, "lib/b.py": {"hash": "h", "total": 9, "verdicts": {"m1": "k", "m2": "k", "m3": "k", "m4": "k"}, "survivors": {}}}}'
  check "newfail[wam]: mutantes POR JULGAR em dois alvos (restam 2 de 3 e 5 de 9) → um só motivo '2× restam N de N mutantes'" "1 1" "$(zw 'NÃO prova') $(zw '\[2× restam N de N mutantes\]')"
  zeraw '{"v": 1, "targets": {"a.py": {"hash": "h", "skip": "a"}, "b.py": {"hash": "h", "skip": "b"}, "c.py": {"hash": "h", "skip": "c"}, "d.py": {"hash": "h", "skip": "d"}, "e.py": {"hash": "h", "skip": "e"}, "f.py": {"hash": "h", "skip": "f"}, "g.py": {"hash": "h", "skip": "g"}, "h.py": {"hash": "h", "skip": "h"}, "i.py": {"hash": "h", "skip": "i"}, "j.py": {"hash": "h", "skip": "j"}}}'
  check "newfail[wam]: 10 motivos diferentes → a lista traz os 8 primeiros e '+2 motivo(s)' (o comentário não vira um despejo)" "1 1 0 1" "$(zw '1× pulado: h; +2 motivo(s)') $(zw '1× pulado: a; 1× pulado: b;') $(zw 'pulado: i') $(zw 'NÃO julgados por inteiro agora: 10 \[')"
  zeraw '{"v": 1, "targets": {}}'
  check "newfail[wam]: estado NOVO do motor (targets {}) depois de uma lista → 'NÃO prova', 0 alvos e 'sem nenhum alvo'; n vai a 0 e nada é fechado" "0 1 0 0 1 1 1" "$RC $(calls 'comment' bd.calls) $(calls 'close' bd.calls) $(state n newfail-wa-mutants.json) $(zw 'NÃO prova') $(zw 'Estado do motor: 0 alvo') $(zw 'sem nenhum alvo')"
  wamcity; echo '{"v": 1, "targets": {"lib/c.py": {"hash": "h"}}}' > "$W/node.confirmed"; nw
  check "newfail[wam]: lista vazia e nenhuma bead nossa → nada (rc 0, nenhuma chamada ao bd)" "0 0" "$RC $(wc -l < "$W/bd.calls" | tr -d ' ')"
}

g_all
g_hq
g_wam
echo "── $((n - fails))/$n ok"
if [ -n "${HNF_MUTANT:-}" ]; then echo "RESULT $fails/$n"; [ "$fails" = 0 ]; exit $?; fi

[ -n "${HNF_NO_MUTANTS:-}" ] || {
  [ "$fails" = 0 ] || { echo "── bateria sem mutante VERMELHA ($fails falhas): o controle negativo não vale, nenhum mutante contado"; exit 1; }
  echo "── controle negativo: cada mutante tem que reprovar a bateria ──"
  # DESCRIÇÃO@@ANTES@@DEPOIS — troca EXATAMENTE uma ocorrência numa cópia do script
  cat > "$T/mutants.txt" <<'MUT'
a bandeira do nó é ignorada@@    if not os.path.exists(os.path.join(CITY, ".gc", "hetzner-node.on")):@@    if False:
o corpo da bead corta a lista em 15@@        out.extend("  " + i for i in sorted(ids))@@        out.extend("  " + i for i in sorted(ids)[:15])
leitura do nó que falha vira 'ausente' (zero confirmadas)@@        return "ilegivel", "o nó não leu %s (rc=%d)" % (F["arquivo"], r.returncode)@@        return "ausente", None
JSON ruim do nó vira lista vazia@@        return "ilegivel", "%s não é JSON" % F["arquivo"]@@        return "ok", {}
bead fechada recebe comentário em vez de abrir outra@@        action = "comentar" if status == "open" else "criar"@@        action = "comentar"
bead ilegível não impede abrir outra@@        if status is None:@@        if False:
lista que muda não é percebida (a impressão digital não compara)@@    if bead and fp == last_fp:@@    if bead:
estado local ilegível vira estado vazio@@        return None, "%s ilegível (%s)" % (os.path.basename(F["estado"]), type(e).__name__)@@        return {}, ""
abre a bead sem listar o rig antes (a que a volta anterior criou sem saber é duplicada)@@        ours, why = find_ours()@@        ours, why = [], ""
achou uma bead nossa aberta e abre outra mesmo assim@@        if ours:@@        if False:
adota a bead de MAIOR id em vez da menor@@            bead, action = ours[0], "comentar"@@            bead, action = ours[-1], "comentar"
bd list que falha vira "nenhuma nossa" (abre outra)@@        return None, "não consegui listar o rig do %s (o bd não respondeu, estourou o prazo de %g s ou saiu com erro)" % (F["rig_nome"], BD_TIMEOUT)@@        return [], ""
bd list com lixo (não é JSON) vira "nenhuma nossa"@@        return None, "o bd list do rig do %s não devolveu JSON" % F["rig_nome"]@@        return [], ""
bd list com JSON que não é lista dá traceback@@    if not isinstance(v, list):@@    if False:
bead nossa FECHADA conta como aberta@@        if F["labels"][0] in (labels or []) and x["status"] != "closed":@@        if F["labels"][0] in (labels or []):
bead de OUTRA label (ou sem labels) conta como nossa@@        if F["labels"][0] in (labels or []) and x["status"] != "closed":@@        if x["status"] != "closed":
a listagem esquece o --limit 0 (trunca em 50 sem avisar)@@    r = run([BD, "-C", F["rig"], "list", "-l", F["labels"][0], "--json", "--limit", "0"], timeout=BD_TIMEOUT)@@    r = run([BD, "-C", F["rig"], "list", "-l", F["labels"][0], "--json"], timeout=BD_TIMEOUT)
o prazo do bd ignora HB_BD_TIMEOUT@@        v = float(os.environ.get("HB_BD_TIMEOUT") or 90)@@        v = 90.0
o texto da falha do create volta a afirmar que nada foi registrado@@Não sei se a bead nasceu no rig do %s;@@Nada foi registrado no rig do %s;
escrita do estado local que falha vira silêncio (rc 0)@@        die(3, "%s, mas NÃO gravei o estado local (%s): %s" % (done, e, next_round))@@        pass
a criação não grava o estado (a próxima volta não sabe da bead)@@    save_state_or_die(fp, new, len(items), "abri %s" % new, "a próxima volta lista o rig e comenta nela em vez de abrir outra")@@    pass
o comentário da lista nova não grava o estado (repete a cada volta)@@        save_state_or_die(fp, bead, len(items), "comentei a lista nova em %s" % bead, "a próxima volta repete o comentário")@@        pass
o comentário 'corrigidas' não grava o estado (repete a cada volta)@@            save_state_or_die(fp, bead, 0, "comentei em %s que a lista zerou" % bead, "a próxima volta repete o comentário")@@            pass
lista que zera não comenta@@        if bead and last_n:@@        if False:
a fonte hq-mutants usa a label do wa-suite@@labels=("origem:lastro-hq-mutants", "area:testes")@@labels=("origem:lastro-wa-suite", "area:testes")
a fonte hq-mutants divide o estado com o wa-suite@@estado="newfail-hq-mutants.json"@@estado="newfail.json"
a fonte hq-mutants pede ao nó o arquivo do wa-suite@@arquivo="hq-mutants.state.json"@@arquivo="wa-suite.confirmed"
a fonte hq-mutants abre a bead no rig do WA@@rig=os.environ.get("HB_HQ_RIG") or CITY@@rig=os.environ.get("HB_WA_RIG") or CITY
HB_HQ_RIG vazio vira o rig vazio (-C '')@@rig=os.environ.get("HB_HQ_RIG") or CITY@@rig=os.environ.get("HB_HQ_RIG", CITY)
a bead do hq nasce bug P2 (como a do wa-suite)@@tipo="task", prio="3", titulo="hq-mutants@@tipo="bug", prio="2", titulo="hq-mutants
alvo PULADO (skip) conta como julgado, e a lista que zera vira 'nenhum sobrevive'@@        if "skip" in ent:@@        if False:
alvo SEM hash conta como julgado@@        elif not ent.get("hash"):@@        elif False:
alvo sem total (ou verdicts de outro tipo) conta como julgado@@        elif type(total) is not int or not isinstance(ver, dict):@@        elif False:
mutantes por julgar (total > vereditos) contam como julgados@@        elif len(ver) < total:@@        elif False:
estado novo (targets {}) vira lista vazia limpa ('nenhum sobrevive')@@    out = [] if targets else [("estado", "sem nenhum alvo: o motor ainda não varreu nada")]@@    out = []
o comentário que zera esquece a avaliação dos alvos@@inp=F["zerou"](*aval), timeout=60)@@inp=F["zerou"](0, []), timeout=60)
o comentário que zera do hq-mutants ignora os alvos não reavaliados@@    if nao:@@    if False:
a fonte hq-mutants usa a avaliação do wa-suite (nada a declarar)@@avalia=avalia_hq, zerou=zerou_hq@@avalia=avalia_wa, zerou=zerou_hq
sobrevivente com a linha booleana passa@@type(r.get("line")) is int and @@isinstance(r.get("line"), int) and 
o corpo esquece o aviso de linha velha@@"MANTÉM a linha aqui, e ela pode estar velha: confira no arquivo atual antes de agir.", ""]@@"", ""]
só o 1º alvo do estado do motor entra na lista@@    for ent in targets.values():@@    for ent in list(targets.values())[:1]:
survivors que não é objeto passa@@        if not isinstance(surv, dict):@@        if False:
alvo que não é objeto vira "sem sobrevivente"@@        surv = ent.get("survivors", {}) if isinstance(ent, dict) else None@@        surv = ent.get("survivors", {}) if isinstance(ent, dict) else {}
alvo sem a chave survivors dá traceback@@        surv = ent.get("survivors", {}) if isinstance(ent, dict) else None@@        surv = ent["survivors"] if isinstance(ent, dict) else None
sobrevivente com a linha em texto passa@@type(r.get("line")) is int and @@
o corpo corta os sobreviventes em 15@@        out.append("ARQUIVO %s (%d)" % (rel, len(rows)))
        for line, sid, r in sorted(rows, key=lambda x: (x[0], x[1])):@@        out.append("ARQUIVO %s (%d)" % (rel, len(rows)))
        for line, sid, r in sorted(rows, key=lambda x: (x[0], x[1]))[:15]:
o corpo esquece o id do sobrevivente@@r.get("new", "").replace("\n", "\\n"), sid, "  (testes: %s)" % fam if fam else ""))@@r.get("new", "").replace("\n", "\\n"), "", "  (testes: %s)" % fam if fam else ""))
fonte que não conheço cai na padrão (wa-suite)@@    die(2, "uso: hetzner-ballast-newfail.py [--fonte %s]" % "|".join(sorted(FONTES)))@@    return "wa-suite"
nome de fonte desconhecido dá traceback em vez de rc 2@@    if len(argv) == 2 and argv[0] == "--fonte" and argv[1] in FONTES:@@    if len(argv) == 2 and argv[0] == "--fonte":
sem argumento a fonte padrão passa a ser hq-mutants@@        return "wa-suite"@@        return "hq-mutants"
a bead do wa-mutants nasce com ctx:ready e exec:auto (o watchdog de rota a entrega ao pool de dogs)@@labels=("origem:lastro-wa-mutants", "area:testes")@@labels=("origem:lastro-wa-mutants", "area:testes", "ctx:ready", "exec:auto")
a fonte wa-mutants usa a label do wa-suite@@labels=("origem:lastro-wa-mutants", "area:testes")@@labels=("origem:lastro-wa-suite", "area:testes")
a fonte wa-mutants usa a label do hq-mutants@@labels=("origem:lastro-wa-mutants", "area:testes")@@labels=("origem:lastro-hq-mutants", "area:testes")
a fonte wa-mutants divide o estado com o hq-mutants@@estado="newfail-wa-mutants.json"@@estado="newfail-hq-mutants.json"
a fonte wa-mutants pede ao nó o arquivo do hq-mutants@@arquivo="wa-mutants.state.json"@@arquivo="hq-mutants.state.json"
a fonte wa-mutants abre a bead no rig do HQ@@rig=os.environ.get("HB_WA_RIG", "/Users/athos/gt/whatsapp_automation"), rig_nome="WA", labels=("origem:lastro-wa-mutants"@@rig=os.environ.get("HB_HQ_RIG") or CITY, rig_nome="WA", labels=("origem:lastro-wa-mutants"
a bead do wa-mutants nasce bug P2@@tipo="task", prio="3", titulo="wa-mutants@@tipo="bug", prio="2", titulo="wa-mutants
a fonte wa-mutants fica sem o espaçamento do comentário@@zerou=zerou_wam, gap_s=WAM_GAP_S@@zerou=zerou_wam, gap_s=0
o espaçamento do comentário nunca é aplicado@@        if action == "comentar" and F.get("gap_s") and too_soon(state, F["gap_s"]):@@        if False:
o espaçamento vale para TODAS as fontes (o hq-mutants também adia)@@        if action == "comentar" and F.get("gap_s") and too_soon(state, F["gap_s"]):@@        if action == "comentar" and too_soon(state, F.get("gap_s") or WAM_GAP_S):
o espaçamento vale também para abrir bead nova (bead fechada)@@        if action == "comentar" and F.get("gap_s") and too_soon(state, F["gap_s"]):@@        if F.get("gap_s") and too_soon(state, F["gap_s"]):
o adiamento grava o estado (a lista velha some sem aviso)@@            return 0
    lead = "A lista de %s@@            save_state(fp, bead, len(items))
            return 0
    lead = "A lista de %s
o relógio no futuro adia para sempre@@    return 0 <= time.time() - t < gap@@    return time.time() - t < gap
o espaçamento é o dobro das 6 h@@    return 0 <= time.time() - t < gap@@    return 0 <= time.time() - t < gap * 2
o espaçamento é metade das 6 h@@    return 0 <= time.time() - t < gap@@    return 0 <= time.time() - t < gap / 2
estado sem relógio dá traceback@@    except (TypeError, ValueError):@@    except ValueError:
relógio que não é data dá traceback@@    except (TypeError, ValueError):@@    except TypeError:
o relógio é lido como hora local (não UTC)@@        t = calendar.timegm(@@        t = time.mktime(
o estado não grava o relógio@@"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())@@"at": ""
o wa-mutants lista os arquivos por nome (não pelo que tem mais sobreviventes)@@key=lambda kv: (-len(kv[1]), kv[0])@@key=lambda kv: kv[0]
o wa-mutants lista primeiro o arquivo com MENOS sobreviventes@@key=lambda kv: (-len(kv[1]), kv[0])@@key=lambda kv: (len(kv[1]), kv[0])
o empate entre arquivos fica na ordem do JSON@@key=lambda kv: (-len(kv[1]), kv[0])@@key=lambda kv: (-len(kv[1]),)
as linhas do arquivo ficam na ordem do JSON@@        flat.append(("ARQUIVO %s (%d)" % (rel, len(rows)), None))
        for line, sid, r in sorted(rows, key=lambda x: (x[0], x[1])):@@        flat.append(("ARQUIVO %s (%d)" % (rel, len(rows)), None))
        for line, sid, r in rows:
o cabeçalho do arquivo conta um a mais@@        flat.append(("ARQUIVO %s (%d)" % (rel, len(rows)), None))@@        flat.append(("ARQUIVO %s (%d)" % (rel, len(rows) + 1), None))
o wa-mutants não tem teto de tamanho@@    teto = WAM_CAP - 700@@    teto = WAM_CAP * 100
o teto ignora o cabeçalho do texto@@    used = sum(len(x.encode("utf-8")) + 1 for x in head)@@    used = 0
o teto conta caracteres, não bytes@@        used += len(txt.encode("utf-8")) + 1@@        used += len(txt) + 1
o teto deixa passar 5000 bytes a mais@@        if used > teto:@@        if used > teto + 5000:
o que não coube some sem a linha da conta@@    if rest:@@    if False:
a linha da conta erra por um@@% (len(rest), len(set(rest)), WAM_CAP))@@% (len(rest) - 1, len(set(rest)), WAM_CAP))
a linha da conta conta os cabeçalhos e as linhas em branco@@    rest = [rel for _, rel in flat[k:] if rel is not None]@@    rest = [txt for txt, _ in flat[k:]]
o corpo do wa-mutants esquece a linha da fonte@@    out.append(fonte)@@    pass
o corpo do wa-mutants diz o intervalo errado@@% (WAM_GAP_S // 3600), ""]@@% 1, ""]
o corpo do wa-mutants esquece o aviso de linha velha@@"MANTÉM a linha aqui, e ela pode estar velha: confira no arquivo atual antes de agir." % (WAM_GAP_S@@"" % (WAM_GAP_S
o corpo do wa-mutants esquece o id do sobrevivente@@, sid, "  (testes: %s)" % fam if fam else ""), rel))@@, "", "  (testes: %s)" % fam if fam else ""), rel))
a lista que zera do wa-mutants nunca diz que todos foram julgados@@    if not nao:@@    if False:
os motivos do wa-mutants não são agrupados@@        k = re.sub(r"\d+", "N", ":".join(why.split(":")[:2]))@@        k = why
os motivos do wa-mutants separam os números (restam 2 de 3 ≠ restam 5 de 9)@@        k = re.sub(r"\d+", "N", ":".join(why.split(":")[:2]))@@        k = ":".join(why.split(":")[:2])
os motivos do wa-mutants só olham a 1ª parte (pulado)@@        k = re.sub(r"\d+", "N", ":".join(why.split(":")[:2]))@@        k = re.sub(r"\d+", "N", ":".join(why.split(":")[:1]))
os motivos do wa-mutants olham 3 partes (familia-grande:13 ≠ :15)@@        k = re.sub(r"\d+", "N", ":".join(why.split(":")[:2]))@@        k = re.sub(r"\d+", "N", ":".join(why.split(":")[:3]))
cada alvo conta uma vez só por motivo@@        por[k] = por.get(k, 0) + 1@@        por[k] = 1
os motivos saem em ordem alfabética (não pelo que tem mais alvos)@@    top = sorted(por.items(), key=lambda kv: (-kv[1], kv[0]))@@    top = sorted(por.items(), key=lambda kv: kv[0])
os motivos saem do menor para o maior@@    top = sorted(por.items(), key=lambda kv: (-kv[1], kv[0]))@@    top = sorted(por.items(), key=lambda kv: (kv[1], kv[0]))
a lista dos motivos não é cortada em 8@@for k, c in top[:8])@@for k, c in top)
a lista dos motivos erra o '+K motivo(s)'@@(len(top) - 8) if len(top) > 8 else ""@@(len(top)) if len(top) > 8 else ""
o comentário que zera do wa-mutants diz 0 alvos não julgados@@nem por isso foi pego. Confira ~/gt-remote/ballast/wa-mutants.state.json no nó antes de fechar esta bead." % (n, len(nao), quais))@@nem por isso foi pego. Confira ~/gt-remote/ballast/wa-mutants.state.json no nó antes de fechar esta bead." % (n, 0, quais))
o comentário que zera do wa-mutants erra o total de alvos do estado do motor@@nem por isso foi pego. Confira ~/gt-remote/ballast/wa-mutants.state.json no nó antes de fechar esta bead." % (n, len(nao), quais))@@nem por isso foi pego. Confira ~/gt-remote/ballast/wa-mutants.state.json no nó antes de fechar esta bead." % (0, len(nao), quais))
MUT
  "$PY" -I - "$NF" "$T/mutants.txt" "$T" > "$T/mutants.idx" <<'PYEOF'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
entries, cur = [], None
for line in open(sys.argv[2], encoding="utf-8").read().rstrip("\n").split("\n"):
    if cur is None or (cur.count("@@") >= 2 and re.match(r"^[^@\s][^@]*@@", line)):
        if cur is not None:
            entries.append(cur)
        cur = line
    else:
        cur += "\n" + line
if cur:
    entries.append(cur)
for i, e in enumerate(entries, 1):
    parts = e.split("@@")
    if len(parts) != 3 or src.count(parts[1]) != 1:
        print("%d\tBAD\t%s" % (i, parts[0]))
        continue
    open("%s/mut%d.py" % (sys.argv[3], i), "w", encoding="utf-8").write(src.replace(parts[1], parts[2]))
    print("%d\tOK\t%s" % (i, parts[0]))
PYEOF
  JOBS=${HNF_JOBS:-4}
  while IFS="$(printf '\t')" read -r idx st desc; do
    if [ "$st" != OK ]; then ok 1 "mutante '$desc': a âncora não casa exatamente 1 vez (o script mudou?)"; continue; fi
    while [ "$(jobs -r | wc -l | tr -d ' ')" -ge "$JOBS" ]; do sleep 0.3; done
    ( HNF_MUTANT=1 HNF_UNDER_TEST="$T/mut$idx.py" bash "$0" 2>&1 | tail -n 1 > "$T/mres.$idx" ) &
  done < "$T/mutants.idx"
  wait
  while IFS="$(printf '\t')" read -r idx st desc; do
    [ "$st" = OK ] || continue
    r=$(cat "$T/mres.$idx" 2> /dev/null)
    case "$r" in "RESULT 0/"*) ok 1 "mutante '$desc' NÃO foi pego ($r)";; "RESULT "*) ok 0 "mutante '$desc' pego ($r)";; *) ok 1 "mutante '$desc': sem resultado ($r)";; esac
  done < "$T/mutants.idx"
}
echo "── $((n - fails))/$n ok"
[ "$fails" = 0 ]
