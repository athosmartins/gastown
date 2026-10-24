#!/usr/bin/env bash
# hetzner-ballast-newfail.selftest.sh — hermético (ga-r4lw72): `ssh` e `bd` são scripts de brinquedo que anotam a chamada; a cidade e o nó são pastas temporárias. Nada fala com o nó nem com o rig do WA.
#
# Contents
#   Casos · Controle negativo (mutantes) · Variáveis
#
# CASOS: bandeira do nó ausente = não faz nada · ssh fora = rc 98 · arquivo do nó ausente = nada confirmado (rc 0) · leitura do nó que falha, JSON ruim, forma errada = rc 3 e NADA é aberto (erro nunca vira "0 confirmadas") ·
#   lista nova = UMA bead (bug, P2, labels, corpo com a lista COMPLETA, também com 237 ids) e o estado guarda o id · mesma lista = nada · lista que muda = comentário na mesma bead · bead fechada pelo dono = abre outra ·
#   bead que não consigo ler = não abre outra · lista que zera = um comentário "corrigidas" · estado local ilegível = rc 3 · `bd create` sem resposta certa (rc≠0, prazo estourado, sem id — com a bead NASCIDA ou não) = rc 3, estado
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
# Se bd.status existe, o show E o list dão esse status a TODAS as beads (o dono "fechou": no bd de verdade as duas leituras vêm do mesmo registro).
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
    case "$lb" in outro) lab=',"labels":["outra:coisa"]';; sem) lab='';; *) lab=',"labels":["origem:lastro-wa-suite","area:testes"]';; esac
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
calls() { grep -c -- "$1" "$W/$2" 2> /dev/null || true; }   # calls PADRAO ARQUIVO — quantas linhas anotadas casam
state() { "$PY" -I -c 'import sys, json
try:
    v = json.load(open(sys.argv[1] + "/.gc/hetzner-ballast/newfail.json"))
except FileNotFoundError:
    print("ausente"); sys.exit(0)
except (OSError, ValueError):
    print("ilegivel"); sys.exit(0)
print(v.get(sys.argv[2]) if isinstance(v, dict) else "forma")' "$CITY" "$1"; }

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

g_all
echo "── $((n - fails))/$n ok"
if [ -n "${HNF_MUTANT:-}" ]; then echo "RESULT $fails/$n"; [ "$fails" = 0 ]; exit $?; fi

[ -n "${HNF_NO_MUTANTS:-}" ] || {
  [ "$fails" = 0 ] || { echo "── bateria sem mutante VERMELHA ($fails falhas): o controle negativo não vale, nenhum mutante contado"; exit 1; }
  echo "── controle negativo: cada mutante tem que reprovar a bateria ──"
  # DESCRIÇÃO@@ANTES@@DEPOIS — troca EXATAMENTE uma ocorrência numa cópia do script
  cat > "$T/mutants.txt" <<'MUT'
a bandeira do nó é ignorada@@    if not os.path.exists(os.path.join(CITY, ".gc", "hetzner-node.on")):@@    if False:
o corpo da bead corta a lista em 15@@        out.extend("  " + i for i in sorted(ids))@@        out.extend("  " + i for i in sorted(ids)[:15])
leitura do nó que falha vira 'ausente' (zero confirmadas)@@        return "ilegivel", "o nó não leu wa-suite.confirmed (rc=%d)" % r.returncode@@        return "ausente", None
JSON ruim do nó vira lista vazia@@        return "ilegivel", "wa-suite.confirmed não é JSON"@@        return "ok", {}
bead fechada recebe comentário em vez de abrir outra@@        action = "comentar" if status == "open" else "criar"@@        action = "comentar"
bead ilegível não impede abrir outra@@        if status is None:@@        if False:
lista que muda não é percebida (a impressão digital não compara)@@    if bead and fp == last_fp:@@    if bead:
estado local ilegível vira estado vazio@@        return None, "newfail.json ilegível (%s)" % type(e).__name__@@        return {}, ""
abre a bead sem listar o rig antes (a que a volta anterior criou sem saber é duplicada)@@        ours, why = find_ours()@@        ours, why = [], ""
achou uma bead nossa aberta e abre outra mesmo assim@@        if ours:@@        if False:
adota a bead de MAIOR id em vez da menor@@            bead, action = ours[0], "comentar"@@            bead, action = ours[-1], "comentar"
bd list que falha vira "nenhuma nossa" (abre outra)@@        return None, "não consegui listar o rig do WA (o bd não respondeu, estourou o prazo de %g s ou saiu com erro)" % BD_TIMEOUT@@        return [], ""
bd list com lixo (não é JSON) vira "nenhuma nossa"@@        return None, "o bd list do rig do WA não devolveu JSON"@@        return [], ""
bd list com JSON que não é lista dá traceback@@    if not isinstance(v, list):@@    if False:
bead nossa FECHADA conta como aberta@@        if LABELS[0] in (labels or []) and x["status"] != "closed":@@        if LABELS[0] in (labels or []):
bead de OUTRA label (ou sem labels) conta como nossa@@        if LABELS[0] in (labels or []) and x["status"] != "closed":@@        if x["status"] != "closed":
a listagem esquece o --limit 0 (trunca em 50 sem avisar)@@    r = run([BD, "-C", WA_RIG, "list", "-l", LABELS[0], "--json", "--limit", "0"], timeout=BD_TIMEOUT)@@    r = run([BD, "-C", WA_RIG, "list", "-l", LABELS[0], "--json"], timeout=BD_TIMEOUT)
o prazo do bd ignora HB_BD_TIMEOUT@@        v = float(os.environ.get("HB_BD_TIMEOUT") or 90)@@        v = 90.0
o texto da falha do create volta a afirmar que nada foi registrado@@Não sei se a bead nasceu no rig do WA;@@Nada foi registrado no rig do WA;
escrita do estado local que falha vira silêncio (rc 0)@@        die(3, "%s, mas NÃO gravei o estado local (%s): %s" % (done, e, next_round))@@        pass
a criação não grava o estado (a próxima volta não sabe da bead)@@    save_state_or_die(fp, new, len(items), "abri %s" % new, "a próxima volta lista o rig e comenta nela em vez de abrir outra")@@    pass
o comentário da lista nova não grava o estado (repete a cada volta)@@        save_state_or_die(fp, bead, len(items), "comentei a lista nova em %s" % bead, "a próxima volta repete o comentário")@@        pass
o comentário 'corrigidas' não grava o estado (repete a cada volta)@@            save_state_or_die(fp, bead, 0, "comentei em %s que foram corrigidas" % bead, "a próxima volta repete o comentário")@@            pass
lista que zera não comenta@@        if bead and last_n:@@        if False:
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
