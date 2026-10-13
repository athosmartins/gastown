#!/usr/bin/env bash
# pytest-shim-coverage.selftest.sh — hermético: HOME e city são temporários; coverage.py não lê transcrito real nem log real (ga-fl2nek, gate-fix 1).
#
# Contents
#   Casos · Controles negativos
#
# POR QUÊ: o gate reprovou o coverage.py (a régua do aceite da ga-fl2nek) porque --desde era VALIDADO (exige fuso) e depois o texto CRU era comparado, letra a letra, com o ts
#   UTC `...Z` dos logs: o mesmo instante digitado com o deslocamento de Brasília (`-03:00`) incluía linhas anteriores ao corte e inflava a contagem sem aviso.
# CASOS: o mesmo instante em `Z`, `+00:00`, `-03:00` e `+09:00` dá o MESMO corte nos dois logs · sem fuso ou lixo → erro, sem relatório · linha sem ts ou com ts ilegível fica FORA do corte e o
#   relatório diz quantas (não some calada) · sem --desde nada é cortado e não há AVISO · linha que é JSON mas não é objeto não derruba · --dias 0 → erro · log que existe e não abre → erro,
#   não "sem log" · log ausente → "sem log" · --desde vazio → erro.
# CONTROLES M1-M4: cada mutante do coverage.py tem de ser pego (M1 lê o deslocamento como se fosse UTC, M2 engole a contagem de linhas sem ts, M3 trata log ilegível como ausente,
#   M4 deixa --desde vazio virar "sem corte").
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
COV="$HERE/pytest-shim/coverage.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/pytest-shim-coverage-selftest.XXXXXX")
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
n=0; fails=0
mkdir -p "$T/home" "$T/city/.gc/logs" "$T/mut"
export HOME="$T/home" GC_CITY_PATH="$T/city"
SHIMLOG="$T/city/.gc/logs/pytest-shim.jsonl"; MBPLOG="$T/city/.gc/logs/mbp-run.jsonl"

# três linhas ANTES, NO e DEPOIS do corte 2026-10-14T03:30:00Z — a mesma forma da reprodução do revisor (02:00Z, 03:30Z, 05:00Z)
cat > "$SHIMLOG" <<'EOF'
{"ts":"2026-10-14T02:00:00Z","ran":"local","detail":"offload-desligado"}
{"ts":"2026-10-14T03:30:00Z","ran":"mbp"}
{"ts":"2026-10-14T05:00:00Z","ran":"mbp"}
EOF
cat > "$MBPLOG" <<'EOF'
{"ts":"2026-10-14T02:00:00Z","mode":"pytest"}
{"ts":"2026-10-14T03:30:00Z","mode":"pytest"}
{"ts":"2026-10-14T05:00:00Z","mode":"exec"}
EOF

run() { # <coverage.py> args... → stdout+stderr em $T/out, rc em $RC
  local py="$1"; shift
  RC=0; python3 -I "$py" "$@" > "$T/out" 2>&1 || RC=$?; }
ok()   { n=$((n+1)); echo "ok   $1"; }
bad()  { n=$((n+1)); fails=$((fails+1)); echo "FAIL $1"; sed 's/^/       | /' "$T/out" | head -12; }
check() { # <nome> <regex que tem de aparecer em $T/out>
  if grep -Eq -- "$2" "$T/out"; then ok "$1"; else bad "$1 (esperava /$2/)"; fi; }
nocheck() { # <nome> <regex que NÃO pode aparecer>
  if grep -Eq -- "$2" "$T/out"; then bad "$1 (não podia aparecer /$2/)"; else ok "$1"; fi; }
rc_is() { if [ "$RC" = "$2" ]; then ok "$1"; else bad "$1 (rc esperado $2, veio $RC)"; fi; }
rc_not0() { if [ "$RC" != 0 ]; then ok "$1"; else bad "$1 (rc era 0)"; fi; }

# =============================== A. o mesmo instante, quatro grafias ===============================
for spec in "Z|2026-10-14T03:30:00Z" "+00:00|2026-10-14T03:30:00+00:00" "-03:00 (o caso do revisor)|2026-10-14T00:30:00-03:00" "+09:00|2026-10-14T12:30:00+09:00"; do
  label="${spec%%|*}"; val="${spec#*|}"
  run "$COV" --desde "$val"; rc_is "A $label: rc 0" 0
  check   "A $label: log do atalho — 2 rodadas (03:30Z e 05:00Z), a de 02:00Z fica de fora" 'rodadas pelo atalho: 2 '
  check   "A $label: mbp-run.jsonl cortado no mesmo instante — 2 execuções" 'execuções no MBP: 2;'
  check   "A $label: o rótulo mostra o corte que VALE, em UTC" 'desde 2026-10-14T03:30:00Z'
done
run "$COV" --desde "2026-10-14T00:30:00-03:00"
check "A o rótulo também mostra o que foi digitado quando difere do UTC" 'digitado 2026-10-14T00:30:00-03:00'
run "$COV" --desde "2026-10-14T03:30:00Z"
nocheck "A em UTC o rótulo não repete o digitado" 'digitado'

# =============================== B. entrada ruim → erro, sem relatório ===============================
run "$COV" --desde "2026-10-14T03:30:00"; rc_not0 "B sem fuso → erro"; check "B sem fuso: a mensagem diz que falta fuso" 'sem fuso'; nocheck "B sem fuso: nenhum relatório" 'rodadas pelo atalho'
run "$COV" --desde "lixo"; rc_not0 "B lixo → erro"; nocheck "B lixo: nenhum relatório" 'rodadas pelo atalho'
run "$COV" --desde "2026-10-14"; rc_not0 "B só data (sem hora/fuso) → erro"
run "$COV" --desde ""; rc_not0 "B --desde vazio (VAR não definida no shell) → erro, não vira 'sem corte'"; nocheck "B --desde vazio: nenhum relatório" 'rodadas pelo atalho'
run "$COV" --dias 0; rc_not0 "B --dias 0 → erro (não vira '0 rodadas' como se fosse medida)"
run "$COV" --dias -3; rc_not0 "B --dias negativo → erro"

# =============================== C. sem --desde nada é cortado ===============================
run "$COV"; rc_is "C sem --desde: rc 0" 0
check   "C sem --desde: as 3 rodadas do log do atalho" 'rodadas pelo atalho: 3 '
check   "C sem --desde: as 3 execuções do mbp-run" 'execuções no MBP: 2;|execuções no MBP: 3;'
nocheck "C sem --desde: sem AVISO de ts" 'sem ts legível'

# =============================== D. linha sem ts / com ts ilegível: FORA do corte e dita ===============================
cp "$SHIMLOG" "$T/shim.ok"; cp "$MBPLOG" "$T/mbp.ok"
cat >> "$SHIMLOG" <<'EOF'
{"ran":"mbp"}
{"ts":"ontem","ran":"mbp"}
{"ts":"2026-10-14T06:00:00","ran":"mbp"}
[1,2]
não é json
EOF
cat >> "$MBPLOG" <<'EOF'
{"mode":"pytest"}
EOF
run "$COV" --desde "2026-10-14T03:30:00Z"; rc_is "D rc 0" 0
check   "D log do atalho: as 3 linhas sem ts legível (ausente, 'ontem', sem fuso) ficam FORA e são contadas" '3 linha\(s\) do log do atalho sem ts legível ficaram FORA do corte'
check   "D log do atalho: as 2 rodadas boas continuam sendo 2 (a sem-ts não infla)" 'rodadas pelo atalho: 2 '
check   "D log do atalho: a linha que é JSON mas não é objeto e a que não é JSON são ditas (2 ilegíveis)" '2 linha\(s\) ilegível'
check   "D mbp-run.jsonl: a linha sem ts é dita" '1 linha\(s\) do mbp-run.jsonl sem ts legível ficaram FORA do corte'
run "$COV"; check "D sem --desde a linha sem ts ENTRA (não há corte para ela falhar): 6 objetos" 'rodadas pelo atalho: 6 '
cp "$T/shim.ok" "$SHIMLOG"; cp "$T/mbp.ok" "$MBPLOG"

# =============================== E. log ausente ≠ log que não abre ===============================
find "$T/city/.gc/logs" -name 'pytest-shim.jsonl' -delete
run "$COV" --desde "2026-10-14T03:30:00Z"; rc_is "E log do atalho ausente: rc 0" 0; check "E log ausente: o relatório diz que não existe" 'sem pytest-shim.jsonl'
cp "$T/shim.ok" "$SHIMLOG"
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$SHIMLOG"
  run "$COV" --desde "2026-10-14T03:30:00Z"; rc_not0 "E log que existe e não abre → erro"; check "E log ilegível: a mensagem diz que não conseguiu ler" 'não consegui ler'; nocheck "E log ilegível NÃO vira 'sem log'" 'sem pytest-shim.jsonl'
  chmod 644 "$SHIMLOG"
else
  echo "skip E (root lê qualquer arquivo)"
fi

# =============================== M. controles negativos: cada mutante tem de ser pego ===============================
mutant() { # <nome> <sed-expr>
  cp "$COV" "$T/mut/$1.py"; sed -i.bak -e "$2" "$T/mut/$1.py"
  if cmp -s "$COV" "$T/mut/$1.py"; then n=$((n+1)); fails=$((fails+1)); echo "FAIL mutante $1: o sed não mudou nada (o controle não controla)"; return 1; fi
  return 0; }
caught() { n=$((n+1)); if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: o mutante NÃO foi pego (esperava '$2', veio '$3')"; fails=$((fails+1)); fi; }

# M1: o deslocamento é lido como se o relógio fosse UTC (o bug do gate: a hora digitada em -03:00 vale como se fosse Z)
mutant m1 's/return d.astimezone(timezone.utc) if d.tzinfo is not None else None/return d.replace(tzinfo=timezone.utc) if d.tzinfo is not None else None/' && {
  run "$T/mut/m1.py" --desde "2026-10-14T00:30:00-03:00"
  caught "M1 -03:00 lido como UTC: o corte sai 3 h cedo e entram 3 rodadas (os casos A -03:00 e +09:00 reprovam o mutante)" "3" "$(sed -n 's/.*rodadas pelo atalho: \([0-9]*\) .*/\1/p' "$T/out" | head -1)"; }
# M2: a contagem de linhas sem ts é engolida (o aviso nunca aparece)
mutant m2 's/^\( *\)no_ts += 1$/\1no_ts += 0/' && {
  cp "$T/shim.ok" "$SHIMLOG"; echo '{"ran":"mbp"}' >> "$SHIMLOG"
  run "$T/mut/m2.py" --desde "2026-10-14T03:30:00Z"
  caught "M2 linha sem ts some calada: o AVISO não sai (o caso D reprova o mutante)" "0" "$(grep -c 'sem ts legível' "$T/out")"; cp "$T/shim.ok" "$SHIMLOG"; }
# M3: log que existe e não abre vira "ainda não existe"
if [ "$(id -u)" != 0 ]; then
  mutant m3 's/sys.exit(f"não consegui ler {path}: {e}")/return None, 0, 0/' && {
    chmod 000 "$SHIMLOG"; run "$T/mut/m3.py" --desde "2026-10-14T03:30:00Z"; chmod 644 "$SHIMLOG"
    caught "M3 log ilegível tratado como ausente: rc 0 e 'sem pytest-shim.jsonl' (o caso E reprova o mutante)" "0" "$RC"; }
fi

# M4: --desde vazio volta a significar "sem corte" (o `is not None` vira truthiness)
mutant m4 's/    if a.desde is not None:/    if a.desde:/' && {
  run "$T/mut/m4.py" --desde ""
  caught "M4 --desde vazio vira 'sem corte' calado: rc 0 (o caso B reprova o mutante)" "0" "$RC"; }

echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
