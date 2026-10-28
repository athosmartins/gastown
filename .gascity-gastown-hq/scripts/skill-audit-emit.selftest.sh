#!/usr/bin/env bash
# Selftest for skill-audit-emit.sh — proves ERROR paths notify (ga-4zpf), not just log.
# Distinct from skill-audit.selftest.sh, which tests the wrapped skill-audit.sh auditor.
# ga-iu0fvlo: o caminho FELIZ também tem caso (cenário 3: o skill-drift.json chega a ser escrito, sem temporário sobrando, e a rodada boa não notifica). Os dois cenários de erro não o pegavam:
#   com `printf … > "$tmp" && mv …` trocado por `||` o mv nunca roda no caminho bom e a métrica do dashboard congela sem aviso. Mutante embutido: o trecho troca UMA vez, o cenário tem de FALHAR.
# EQUIVALENTE (287db99fd8, L29 `notify_fail() { … || true; }` com `||→&&`): sem `set -e`, o rc de notify_fail não é lido por ninguém (as duas chamadas são seguidas de `exit 2` explícito), então
#   a função devolver 0 ou o rc do notify dá no mesmo; não há cenário que veja a diferença.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
J="$SELF_DIR/skill-audit-emit.sh"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
NOTIFY_LOG="$TMP/notify.log"
cat > "$TMP/notify" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$NOTIFY_LOG"
EOF
chmod +x "$TMP/notify"

echo "── Scenario 1: auditor produces no JSON ──"
ISO1="$TMP/iso1"; mkdir -p "$ISO1"
cp "$J" "$ISO1/skill-audit-emit.sh"
cat > "$ISO1/skill-audit.sh" <<'EOF'
#!/usr/bin/env bash
exit 0   # produces NOTHING on stdout — simulates a broken auditor
EOF
chmod +x "$ISO1/skill-audit.sh"
: > "$NOTIFY_LOG"
SKILL_AUDIT_NOTIFY="$TMP/notify" SKILL_AUDIT_CITY="$ISO1/city" bash "$ISO1/skill-audit-emit.sh" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] && ok "1: exits 2 when auditor produces no JSON" || bad "1: expected exit 2, got $rc"
grep -qi 'skill-audit-emit' "$NOTIFY_LOG" 2>/dev/null && ok "1: notify_fail fired when auditor produced no JSON (ga-4zpf)" || bad "1: no-JSON FATAL did NOT notify — silent failure (ga-4zpf regression)"

echo ""
echo "── Scenario 2: output dir not writable ──"
ISO2="$TMP/iso2"; mkdir -p "$ISO2"
cp "$J" "$ISO2/skill-audit-emit.sh"
cat > "$ISO2/skill-audit.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"ok":true,"drift_count":0,"offpath_count":0,"skills_checked":1}'
EOF
chmod +x "$ISO2/skill-audit.sh"
mkdir -p "$ISO2/city/.gc/state" "$ISO2/city/.gc/logs"
chmod 555 "$ISO2/city/.gc/state"
: > "$NOTIFY_LOG"
SKILL_AUDIT_NOTIFY="$TMP/notify" SKILL_AUDIT_CITY="$ISO2/city" bash "$ISO2/skill-audit-emit.sh" >/dev/null 2>&1
rc=$?
chmod 755 "$ISO2/city/.gc/state"
[ "$rc" -eq 2 ] && ok "2: exits 2 when state dir is not writable" || bad "2: expected exit 2, got $rc"
grep -qi 'skill-audit-emit' "$NOTIFY_LOG" 2>/dev/null && ok "2: notify_fail fired when output write failed (ga-4zpf)" || bad "2: write-failure FATAL did NOT notify — silent failure (ga-4zpf regression)"

echo ""
echo "── Scenario 3: auditor ok → the metric file lands (ga-iu0fvlo) ──"
chk() { local m=$1; shift; if "$@"; then echo "ok   $m"; else echo "FAIL $m"; fi; }   # roda o teste e imprime uma linha; arquivo ausente/ilegível reprova (cmp/grep devolvem ≠ 0), nunca passa
# conta as linhas para que um cenário que morre sem imprimir nada reprove em vez de sumir: vazio → bad; falhou/ilegível → bad
tally() { local want=$1 got=0 l; while IFS= read -r l; do case $l in "ok   "*) ok "${l#ok   }"; got=$((got+1)) ;; "FAIL "*) bad "${l#FAIL }"; got=$((got+1)) ;; esac; done
          [ "$got" -eq "$want" ] || bad "cenário produziu $got de $want verificações"; }
# $1 = pasta isolada · $2 = emissor sob teste · $3 = rc do auditor falso · $4 = JSON que ele imprime; o rc do emissor fica em EMIT_RC
run_emit() {
  local d=$1 src=$2 arc=$3 json=$4
  rm -rf "$d"; mkdir -p "$d/city/.gc/state" "$d/city/.gc/logs"; cp "$src" "$d/skill-audit-emit.sh"
  printf '%s\n' "$json" > "$d/want"
  printf '#!/usr/bin/env bash\ncat %q\nexit %s\n' "$d/want" "$arc" > "$d/skill-audit.sh"; chmod +x "$d/skill-audit.sh"
  : > "$NOTIFY_LOG"
  SKILL_AUDIT_NOTIFY="$TMP/notify" SKILL_AUDIT_CITY="$d/city" bash "$d/skill-audit-emit.sh" >/dev/null 2>&1; EMIT_RC=$?
}
sc_feliz() {   # $1 = emissor sob teste
  local d="$TMP/iso3" f
  run_emit "$d" "$1" 0 '{"ok":true,"drift_count":0,"offpath_count":0,"skills_checked":1}'; f="$d/city/.gc/state/skill-drift.json"
  chk "3: auditor limpo: o emissor sai 0 (rc $EMIT_RC)" test "$EMIT_RC" -eq 0
  chk "3: skill-drift.json existe e é o JSON do auditor" cmp -s "$f" "$d/want"
  chk "3: nenhum .skill-drift.* temporário sobra (o mv levou o arquivo)" test -z "$(find "$d/city/.gc/state" -name '.skill-drift.*')"
  chk "3: o log leva o resumo da rodada" grep -q 'ok=True drift=0 offpath=0 checked=1 -> ' "$d/city/.gc/logs/skill-audit.log"
  chk "3: rodada boa não notifica" test ! -s "$NOTIFY_LOG"
}
tally 5 < <(sc_feliz "$J")

echo ""
echo "── Mutants: one loose edit of the emitter, the scenario must FAIL ──"
mutant() {   # nome · trecho original · trecho frouxo · cenário que tem de pegar
  local name=$1 old=$2 new=$3 case_fn=$4 res
  if ! python3 - "$J" "$old" "$new" > "$TMP/mut.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
if src.count(sys.argv[2]) != 1:
    sys.exit(3)
sys.stdout.write(src.replace(sys.argv[2], sys.argv[3]))
PY
  then bad "mutante $name: o trecho original não aparece exatamente uma vez no emissor (o emissor mudou?)"; return; fi
  res=$($case_fn "$TMP/mut.sh" 2>&1)
  if printf '%s\n' "$res" | grep -q '^FAIL'; then ok "mutante $name morto por $case_fn"; else bad "mutante $name SOBREVIVEU a $case_fn"; fi
}
mutant escrita-pulada '> "$tmp" && mv -f "$tmp" "$OUT"' '> "$tmp" || mv -f "$tmp" "$OUT"' sc_feliz

echo ""
echo "skill-audit-emit selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
