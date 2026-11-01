#!/usr/bin/env bash
# wa-node-evidence-return.selftest.sh — hermético: o log de rota é de mentira numa pasta temporária; nada de cidade, bd, gc ou rede. (ga-t05a1z9, item 4)
#
# Contents
#   Casos · Controle negativo · Como rodar
#
# CASOS: ida com evidência + release depois = solta · ida com evidência sem release = segue · ida SEM evidência não conta · release ANTERIOR à ida não é volta · release rc != 0 não é volta · ida fora da janela
#   · `out` ilegível numa ida = "não sei", contado à parte (nunca "sem evidência") · linha de lixo contada e avisada · log ausente/ilegível = rc 3 (nunca zero beads) · log vazio = "nenhuma" com rc 0 · uso errado = rc 2
#   · evidencia-de-doc também vale · `out` com texto antes do JSON · a última ida de cada bead manda · saída --json.
# CONTROLE NEGATIVO: cada mutante troca UMA linha do relatório numa cópia e o caso designado tem de reprovar.
# COMO RODAR: bash scripts/wa-node-evidence-return.selftest.sh   (macOS /bin/bash 3.2 e Linux)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REP="$HERE/wa-node-evidence-return.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/wa-node-evret.XXXXXX")
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
fails=0; n=0
ok()  { n=$((n+1)); echo "ok   $1"; }
bad() { n=$((n+1)); echo "FAIL $1"; fails=$((fails+1)); }
PY=${WA_NODE_SELFTEST_PY:-python3}

NOW=$(date +%s)
iso() { "$PY" -I -c 'import sys,datetime; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
# ida <min atrás> <bead> <rc> <info JSON array | -> ; out = o JSON do classificador (basis derivado), ou vazio quando info é "-"
ida() { local ts; ts=$(iso $((NOW - $1*60))); local out
  if [ "$4" = "-" ]; then out=""; else out=$("$PY" -I -c 'import json,sys; print(json.dumps(json.dumps({"verdict":"node","basis":"text","reasons":["prova-no-texto:1-teste(s)+1-codigo"],"paths":[],"tests":[],"info":json.loads(sys.argv[1])})))' "$4"); fi
  if [ -z "$out" ]; then out='""'; fi
  printf '{"ts":"%s","event":"pilot-node-route","bead":"%s","mode":"auto","rc":%s,"out":%s}\n' "$ts" "$2" "$3" "$out"; }
rel() { printf '{"ts":"%s","event":"release","bead":"%s","rc":%s,"detail":"solta"}\n' "$(iso $((NOW - $1*60)))" "$2" "${3:-0}"; }

L="$T/rota.jsonl"
run() { OUT=$("$PY" -I "${CLS:-$REP}" --route-log "$L" "$@" 2>"$T/err"); RC=$?; }
expect() { # expect <rótulo> <rc> <regex da saída> [args...]
  local label="$1" rc="$2" rx="$3"; shift 3; run "$@"
  if [ "$RC" = "$rc" ] && { [ "$rx" = "-" ] || printf '%s' "$OUT" | grep -q -E -e "$rx"; }; then ok "$label"; else bad "$label (rc=$RC, esperado $rc; saída: $(printf '%s' "$OUT" | tr '\n' '|' | cut -c1-260))"; fi
}
expect_not() { # expect_not <rótulo> <rc> <regex que NÃO pode aparecer> [args...]
  local label="$1" rc="$2" rx="$3"; shift 3; run "$@"
  if [ "$RC" = "$rc" ] && ! printf '%s' "$OUT" | grep -q -E -e "$rx"; then ok "$label"; else bad "$label (rc=$RC, esperado $rc sem /$rx/; saída: $(printf '%s' "$OUT" | tr '\n' '|' | cut -c1-260))"; fi
}
EV='["producao","evidencia-de-dado:queue.db"]'; DOC='["evidencia-de-doc:docs/data_dictionary.md"]'; SEM='["producao","tela-ao-vivo"]'

# ---- soltas × seguem
{ ida 120 wa-a 0 "$EV"; rel 60 wa-a; ida 90 wa-b 0 "$EV"; } > "$L"
expect "bead com evidência que foi ao nó e foi SOLTA depois = voltou" 0 'soltas depois.*: 1  wa-a'
expect "o JSON diz 2 idas com evidência, 1 solta, 1 segue" 0 '"foram_ao_no_com_evidencia": 2, "soltas_depois": 1, "seguem_no_no": 1' --json
expect "texto: a que ficou aparece em 'seguem no nó'" 0 'seguem no nó.*: 1  wa-b'
# ---- o que NÃO conta
{ ida 120 wa-c 0 "$SEM"; rel 60 wa-c; } > "$L"
expect "ida SEM evidência não entra (mesmo solta depois)" 0 'nenhuma bead com evidência'
{ rel 120 wa-d; ida 60 wa-d 0 "$EV"; } > "$L"
expect "release ANTERIOR à ida não é volta" 0 '"soltas_depois": 0, "seguem_no_no": 1' --json
{ ida 120 wa-e 0 "$EV"; rel 60 wa-e 13; } > "$L"
expect "release com rc != 0 (escrita falhou) não é volta" 0 '"soltas_depois": 0, "seguem_no_no": 1' --json
{ ida 120 wa-f 10 "$EV"; } > "$L"
expect "linha com rc != 0 (o veredito foi mini) não é ida ao nó" 0 'nenhuma bead com evidência'
{ ida $((60*24*3)) wa-g 0 "$EV"; } > "$L"
expect "ida fora da janela (3 dias, janela de 24 h) fica de fora" 0 'nenhuma bead com evidência' --hours 24
expect "a mesma ida entra com a janela padrão (7 dias)" 0 '"foram_ao_no_com_evidencia": 1' --json
# ---- três estados
{ ida 60 wa-h 0 - ; } > "$L"
expect "ida sem out legível: 'não sei', contada à parte (nunca 'sem evidência')" 0 '"foram_ao_no_com_evidencia": 0.*"idas_sem_out_legivel": 1' --json
expect "e o texto AVISA que não deu para saber" 0 'AVISO: 1 ida\(s\) ao nó sem `out` legível'
{ printf '{"ts":"%s","event":"pilot-node-route","bead":"wa-m","mode":"auto","rc":0,"out":"{\\"verdict\\": corrupt"}\n' "$(iso $((NOW - 60*60)))"; } > "$L"
expect "out com JSON corrompido (corrupt): 'não sei', contado à parte, nunca 'sem evidência'" 0 '"foram_ao_no_com_evidencia": 0.*"idas_sem_out_legivel": 1' --json
{ ida 60 wa-i 0 "$EV"; echo 'linha corrupt: nao e json'; echo '{"event":"release"}'; echo '[1,2]'; } > "$L"
expect "linhas ilegíveis (lixo, sem bead/hora, não-objeto) são CONTADAS, não omitidas" 0 '"linhas_ilegiveis": 3' --json
expect "e o texto AVISA delas" 0 'AVISO: 3 linha\(s\) do log de rota ilegível'
expect "a ida legível ao lado do lixo continua valendo" 0 '"foram_ao_no_com_evidencia": 1' --json
: > "$L"
expect "log VAZIO (existe, sem linha) = nenhuma bead, rc 0" 0 'nenhuma bead com evidência'
rm -f "$L"
expect "log AUSENTE = rc 3, e diz que NÃO é zero beads" 3 '-'
if grep -q 'ausente' "$T/err" && grep -q 'NÃO é zero beads' "$T/err"; then ok "log ausente: a razão vai ao stderr"; else bad "log ausente: stderr sem a razão ($(cat "$T/err"))"; fi
mkdir "$L"
expect "log ILEGÍVEL (é uma pasta) = rc 3" 3 '-'
if grep -q 'ilegível' "$T/err"; then ok "log ilegível: a razão vai ao stderr"; else bad "log ilegível: stderr sem a razão ($(cat "$T/err"))"; fi
rmdir "$L"
# ---- formas do out e da marca
{ ida 60 wa-j 0 "$DOC"; } > "$L"
expect "evidencia-de-doc também conta" 0 '"foram_ao_no_com_evidencia": 1' --json
{ printf '{"ts":"%s","event":"pilot-node-route","bead":"wa-k","mode":"auto","rc":0,"out":"[wa-node-dispatch] despachada\\n{\\"verdict\\": \\"node\\", \\"info\\": [\\"evidencia-de-dado:x.log\\"]}"}\n' "$(iso $((NOW - 60*60)))"; } > "$L"
expect "out com texto ANTES do JSON: lê a última linha que é objeto" 0 '"foram_ao_no_com_evidencia": 1' --json
{ ida 200 wa-l 0 "$EV"; rel 150 wa-l; ida 100 wa-l 0 "$EV"; } > "$L"
expect "a ÚLTIMA ida manda: solta antes da 2ª ida = segue no nó" 0 '"soltas_depois": 0, "seguem_no_no": 1' --json
# ---- uso
expect "--hours 0 = uso errado, rc 2" 2 '-' --hours 0
expect "--hours abc = uso errado, rc 2" 2 '-' --hours abc
expect "argumento desconhecido = rc 2" 2 '-' --nada

# ---- controle negativo: um mutante por linha; o caso designado tem de reprovar
mutant() { # mutant <nome> <trecho original> <trecho novo> <preparo do log (função)> <rc> <regex> [args do relatório]
  local name="$1" orig="$2" new="$3" prep="$4" rc="$5" rx="$6"; shift 6; local M="$T/mut-$name.py"
  if ! "$PY" -I - "$REP" "$M" "$orig" "$new" <<'EOF'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
if sys.argv[3] not in src:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(sys.argv[3], sys.argv[4], 1))
EOF
  then bad "mutante $name: o trecho original não existe (o relatório mudou? atualize o mutante)"; return; fi
  $prep; CLS="$REP"; run "$@"
  if ! { [ "$RC" = "$rc" ] && { [ "$rx" = "-" ] || printf '%s' "$OUT" | grep -q -E -e "$rx"; }; }; then bad "mutante $name VAZIO: o relatório ORIGINAL já reprova o caso (rc=$RC; saída: $(printf '%s' "$OUT" | cut -c1-200))"; CLS=""; return; fi
  CLS="$M"; run "$@"
  if [ "$RC" = "$rc" ] && { [ "$rx" = "-" ] || printf '%s' "$OUT" | grep -q -E -e "$rx"; }; then bad "mutante $name SOBREVIVEU (o caso ainda passa)"; else ok "mutante $name morreu"; fi
  CLS=""
}
prep_antes() { { rel 120 wa-d; ida 60 wa-d 0 "$EV"; } > "$L"; }
prep_semout() { { ida 60 wa-h 0 - ; } > "$L"; }
prep_semev() { { ida 120 wa-c 0 "$SEM"; rel 60 wa-c; } > "$L"; }
prep_lixo() { { ida 60 wa-i 0 "$EV"; echo 'linha corrupt: nao e json'; } > "$L"; }
prep_rc13() { { ida 120 wa-e 0 "$EV"; rel 60 wa-e 13; } > "$L"; }
prep_ultima() { { ida 200 wa-l 0 "$EV"; rel 150 wa-l; ida 100 wa-l 0 "$EV"; } > "$L"; }
prep_ausente() { rm -rf "$L"; }
mutant release-antes-vale 'any(r > t for r in released.get(b, []))' 'any(r > 0 for r in released.get(b, []))' prep_antes 0 '"soltas_depois": 0, "seguem_no_no": 1' --json
mutant out-ilegivel-vira-sem  'unreadable_out += 1' 'pass' prep_semout 0 '"idas_sem_out_legivel": 1' --json
mutant sem-marca-vale-tudo 'return any(isinstance(x, str) and x.startswith(MARCAS) for x in d["info"])' 'return True' prep_semev 0 'nenhuma bead com evidencia|nenhuma bead com evidência'
mutant lixo-some 'bad += 1' 'pass' prep_lixo 0 '"linhas_ilegiveis": 1' --json
mutant release-rc-ignorado 'elif ev == "release" and r.get("rc") == 0:' 'elif ev == "release":' prep_rc13 0 '"soltas_depois": 0, "seguem_no_no": 1' --json
mutant ultima-ida-ignorada 'sent[bead] = max(sent.get(bead, 0), ts)' 'sent[bead] = min(sent.get(bead, ts), ts)' prep_ultima 0 '"soltas_depois": 0, "seguem_no_no": 1' --json
mutant ausente-vira-zero 'return EX_NOLOG' 'return EX_OK' prep_ausente 3 '-'

echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
