#!/bin/bash
# dolt-backup-swap-repair.selftest.sh — unit tests for the pure decision
# functions of dolt-backup-swap-repair.sh (ga-b14btl).
#
# Hermetic: sources the script as a LIBRARY (DOLT_BACKUP_SWAP_REPAIR_LIB=1).
# No filesystem fixture, no Dolt, no backup directory is read or written.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/dolt-backup-swap-repair.sh"

export DOLT_BACKUP_SWAP_REPAIR_LIB=1
# shellcheck disable=SC1090
. "$SCRIPT"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== dolt-backup-swap-repair.selftest.sh ==="

for fn in _classify_copy _should_complete_swap _refusal_reason; do
  type "$fn" >/dev/null 2>&1 && ok "$fn definida em lib mode" \
    || { bad "$fn NAO definida — lib mode quebrado"; echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="; exit 1; }
done

# ── _classify_copy: os quatro estados precisam ser DISTINTOS ────────────────
_cc() { # <esperado> <has_dir> <has_man> <titulo>
  local got; got="$(_classify_copy "$2" "$3")"
  [ "$got" = "$1" ] && ok "$4 ($got)" || bad "$4: esperado $1, veio $got"
}
_cc MISSING 0 0 "sem diretorio = MISSING"
_cc MISSING 0 1 "sem diretorio domina o manifest"
_cc VALID   1 1 "diretorio + manifest = VALID"
_cc INVALID 1 0 "diretorio sem manifest = INVALID (nao e backup)"
_cc UNKNOWN "" 1 "has_dir ilegivel = UNKNOWN, nunca MISSING"
_cc UNKNOWN 1 "" "has_manifest ilegivel = UNKNOWN, nunca INVALID"
_cc UNKNOWN x y "lixo nos dois = UNKNOWN"

# O CORACAO: "nao e backup" e "nao consegui saber" NAO podem colidir.
[ "$(_classify_copy 1 0)" != "$(_classify_copy 1 '')" ] \
  && ok "INVALID != UNKNOWN (o terceiro estado nao colapsa)" \
  || bad "INVALID e UNKNOWN produzem o MESMO valor — o defeito que este script existe pra evitar"

# ── _should_complete_swap: so age no caso exato ────────────────────────────
_sc() { # <esperado 0|1> <primary> <new> <old_exists> <verified> <titulo>
  local exp="$1"; shift
  local p="$1" n="$2" o="$3" v="$4" t="$5"
  if _should_complete_swap "$p" "$n" "$o" "$v"; then got=0; else got=1; fi
  [ "$got" = "$exp" ] && ok "$t" || bad "$t: esperado rc=$exp, veio rc=$got"
}
_sc 0 INVALID VALID   0 1 "CASO REAL (ga-odtd3f): primaria invalida + .new valida + sem .old + verificada -> AGE"
_sc 1 INVALID VALID   0 0 "mesma forma mas NAO verificada -> recusa (manifest nao prova restore)"
_sc 1 INVALID VALID   1 1 "ja existe .old -> recusa (promover sobrescreveria a unica recuperavel)"
_sc 1 VALID   VALID   0 1 "primaria SAUDAVEL -> recusa (nao ha o que reparar)"
_sc 1 INVALID INVALID 0 1 "as DUAS sem manifest -> recusa (nenhuma restaura)"
_sc 1 INVALID MISSING 0 1 "sem .new pra promover -> recusa"
_sc 1 UNKNOWN VALID   0 1 "primaria ILEGIVEL -> recusa (fail-closed)"
_sc 1 INVALID UNKNOWN 0 1 ".new ILEGIVEL -> recusa (fail-closed)"
_sc 1 MISSING VALID   0 1 "sem primaria -> recusa"
_sc 1 ""      ""      "" "" "tudo vazio -> recusa (fail-closed)"

# ── _refusal_reason: um no-op NUNCA e silencioso, e nomeia o bloqueio CERTO ─
_rr() { # <substring esperada> <primary> <new> <old> <verified> <titulo>
  local exp="$1"; shift
  local got; got="$(_refusal_reason "$1" "$2" "$3" "$4")"
  case "$got" in *"$exp"*) ok "$5" ;; *) bad "$5: '$got' nao contem '$exp'" ;; esac
}
_rr "INDETERMINADO" UNKNOWN VALID   0 1 "ilegivel diz INDETERMINADO, nao 'nada a fazer'"
_rr "TEM manifest"  VALID   VALID   0 1 "primaria saudavel e nomeada como saudavel"
_rr "sem backup valido" INVALID MISSING 0 1 "sem .new avisa que o banco esta SEM backup"
_rr "nenhuma copia restaura" INVALID INVALID 0 1 "as duas invalidas: avisa que nenhuma restaura"
_rr "residue-reclaim" INVALID VALID 1 1 "com .old presente, aponta o dono certo (residue-reclaim)"
_rr "restore+contagem" INVALID VALID 0 0 "nao-verificada explica que manifest != restaura"

# A recusa por ILEGIVEL e a recusa por SAUDAVEL nao podem ler igual.
[ "$(_refusal_reason UNKNOWN VALID 0 1)" != "$(_refusal_reason VALID VALID 0 1)" ] \
  && ok "recusa por ilegivel != recusa por saudavel" \
  || bad "as duas recusas produzem o mesmo texto"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" = "0" ] || exit 1
exit 0
