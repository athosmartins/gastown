#!/bin/bash
# dolt-backup-swap-repair.selftest.sh — unit tests for the pure decision
# functions of dolt-backup-swap-repair.sh (ga-b14btl), then (ga-qec2rdl) the
# script itself run against a throw-away BACKUP_ROOT.
#
# Hermetic: the first half sources the script as a LIBRARY
# (DOLT_BACKUP_SWAP_REPAIR_LIB=1) with no filesystem fixture; the second half
# builds its fixtures under mktemp only, with mv and notify stubs first in PATH.
# No Dolt and no real backup directory is read or written.
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

# ── _dry_run_state: o defeito que o gate ga-p3ynfr pegou ───────────────────
# A versao anterior era `[ "$DRY_RUN" = "1" ]`: segura so com a variavel
# NAO-DEFINIDA. Definida como "true" — a convencao mais natural para um flag
# booleano — ela caia no else e EXECUTAVA O MV DE VERDADE. Estes testes existem
# para que essa forma nunca volte.
_dr() { # <esperado> <raw> <titulo>
  local got; got="$(_dry_run_state "$2")"
  [ "$got" = "$1" ] && ok "$3 ($got)" || bad "$3: esperado $1, veio $got"
}
_dr DRY  ""      "nao-definida = seco"
_dr DRY  "1"     "1 = seco"
_dr DRY  "true"  "REGRESSAO ga-p3ynfr: 'true' e SECO, nao acao"
_dr DRY  "TRUE"  "'TRUE' e seco"
_dr DRY  "yes"   "'yes' e seco"
_dr DRY  "on"    "'on' e seco"
_dr ACT  "0"     "0 = agir (opt-out explicito)"
_dr ACT  "false" "'false' = agir"
_dr ACT  "no"    "'no' = agir"
_dr ACT  "off"   "'off' = agir"
_dr UNRECOGNIZED "sim"   "valor nao reconhecido tem nome proprio, nao vira DRY calado"
_dr UNRECOGNIZED "2"     "numero fora do vocabulario = UNRECOGNIZED"
_dr UNRECOGNIZED "  1 "  "espacos em volta nao sao 1 — melhor recusar que adivinhar"

# O contrato que importa: SO 'ACT' age. Tudo que nao for ACT nao toca disco.
for v in "" 1 true TRUE yes on sim 2 "x" "  1 " "1;rm" "TrUe"; do
  st="$(_dry_run_state "$v")"
  [ "$st" = "ACT" ] && { bad "VALOR PERIGOSO: '$v' resolveu para ACT"; break; }
done
ok "nenhum valor ambiguo resolve para ACT"

# E 'nao entendi' nao pode ler igual a 'voce pediu seco'.
[ "$(_dry_run_state sim)" != "$(_dry_run_state 1)" ] \
  && ok "UNRECOGNIZED != DRY (o chamador fica sabendo que foi ignorado)" \
  || bad "UNRECOGNIZED e DRY colapsaram"

# ── Codigos de retorno e fluxo principal (lastro hq-mutants, ga-qec2rdl) ────────
# Ate aqui as funcoes puras so eram lidas pelo que IMPRIMEM: o `return` de cada
# ramo, o modo lib e o laco que mexe em disco (mv, mensagens, exit) nao eram lidos
# por ninguem. Daqui em diante o status sai de cada ramo e o proprio script roda
# como programa contra um BACKUP_ROOT de mentira, com mv e notify de mentira no PATH.
# EQUIVALENTE (lastro 807c305212, L68): `notify_fail() { ... || true; }` -> `... && true` so muda
# o STATUS de notify_fail, e o unico chamador (a recusa do rename, ultimo comando do laco) nunca
# le esse status: o script sai por `exit 0`. Nenhuma saida, arquivo ou codigo de saida difere.
# EQUIVALENT 807c305212: `notify_fail() { ... || true; }` -> `&& true` so muda o STATUS de notify_fail, e o unico chamador nunca le esse status: o script sai por `exit 0`
_rc() { # <rc esperado> <titulo> <comando...>
  local want="$1" title="$2" got; shift 2
  "$@" >/dev/null 2>&1; got=$?
  [ "$got" = "$want" ] && ok "$title (rc=$got)" || bad "$title: rc esperado $want, veio $got"
}
_rc 0 "_classify_copy MISSING sai com 0" _classify_copy 0 0
_rc 0 "_classify_copy UNKNOWN sai com 0" _classify_copy "" 1
_rc 0 "_classify_copy VALID sai com 0"   _classify_copy 1 1
_rc 0 "_classify_copy INVALID sai com 0" _classify_copy 1 0
_rc 0 "_refusal_reason INDETERMINADO sai com 0" _refusal_reason UNKNOWN VALID 0 1
_rc 0 "_refusal_reason sem primaria sai com 0"  _refusal_reason MISSING VALID 0 1
_rc 0 "_refusal_reason primaria saudavel sai com 0" _refusal_reason VALID VALID 0 1
_rc 0 "_refusal_reason sem .new sai com 0"      _refusal_reason INVALID MISSING 0 1
_rc 0 "_refusal_reason .new sem manifest sai com 0" _refusal_reason INVALID INVALID 0 1
_rc 0 "_refusal_reason com .old sai com 0"      _refusal_reason INVALID VALID 1 1
_rc 0 "_refusal_reason nao verificada sai com 0" _refusal_reason INVALID VALID 0 0

# vazio → o diretorio nao existe e o `||` sai; falhou → idem: nunca segue com $T vazio
T="$(mktemp -d "${TMPDIR:-/tmp}/swaprepair.XXXXXX")" || { echo "FATAL: mktemp falhou"; exit 1; }
[ -d "$T" ] || { echo "FATAL: mktemp nao criou $T"; exit 1; }
trap 'rm -rf "$T"' EXIT

# Modo lib: `source` devolve 0, e o script EXECUTADO com LIB=1 sai 0 calado e sem tocar em nada
# (se o `return` falhasse sem o `|| exit 0`, o fluxo principal rodaria como se nada fosse).
( . "$SCRIPT" ) >/dev/null 2>&1; got=$?
[ "$got" = "0" ] && ok "modo lib: source devolve 0" || bad "modo lib: source devolveu $got"
OUT="$(DOLT_BACKUP_SWAP_REPAIR_LIB=1 DOLT_BACKUP_SWAP_REPAIR_BACKUP_ROOT="$T/nao-existe" \
  DOLT_BACKUP_SWAP_REPAIR_LOG="$T/lib.log" bash "$SCRIPT" 2>&1)"; RC=$?
[ "$RC" = "0" ] && [ -z "$OUT" ] && [ ! -e "$T/lib.log" ] \
  && ok "modo lib: executado sai 0, sem saida e sem log" \
  || bad "modo lib executado: rc=$RC saida='$OUT'"

mkdir "$T/bin" || exit 1
REAL_MV="$(command -v mv)"
[ -x "$REAL_MV" ] || { echo "FATAL: sem mv no PATH"; exit 1; }
# Os stubs nascem por printf, sem here-document (o bash 3.2.57 do no grava o temporario do
# here-document em /tmp sem olhar TMPDIR e a jaula que emula o sandbox do gate nega), e leem
# STUB_DIR / REAL_MV / MV_FAIL_N do ambiente, onde o `sr` abaixo os poe.
printf '%s\n' '#!/bin/bash' 'echo "$*" >> "$STUB_DIR/mv.log"' \
  'n=$(wc -l < "$STUB_DIR/mv.log" | tr -d " ")' '[ "${MV_FAIL_N:-0}" = "$n" ] && exit 1' \
  'exec "$REAL_MV" "$@"' > "$T/bin/mv"
printf '%s\n' '#!/bin/bash' 'echo "$*" >> "$STUB_DIR/notify.log"' > "$T/notify"
chmod +x "$T/bin/mv" "$T/notify"

N=0
fresh() { N=$((N+1)); R="$T/root$N"; mkdir "$R" || exit 1; }
mkc() { mkdir "$R/$1" || exit 1; if [ "$2" = ok ]; then : > "$R/$1/manifest"; fi; }   # <nome> bare|ok
sr() { # <DRY_RUN> <VERIFIED> [VAR=valor ...] — o script como programa contra $R; deixa $OUT e $RC
  local dry="$1" ver="$2"; shift 2
  : > "$T/notify.log"; : > "$T/mv.log"; : > "$T/swap.log"
  OUT="$(env DOLT_BACKUP_SWAP_REPAIR_LIB=0 DOLT_BACKUP_SWAP_REPAIR_BACKUP_ROOT="$R" \
    DOLT_BACKUP_SWAP_REPAIR_LOG="$T/swap.log" DOLT_BACKUP_SWAP_REPAIR_NOTIFY="$T/notify" \
    DOLT_BACKUP_SWAP_REPAIR_DRY_RUN="$dry" DOLT_BACKUP_SWAP_REPAIR_VERIFIED="$ver" \
    STUB_DIR="$T" REAL_MV="$REAL_MV" PATH="$T/bin:$PATH" "$@" bash "$SCRIPT" 2>&1)"
  RC=$?
}
has() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }
inlog() { grep -F -- "$1" "$T/swap.log" >/dev/null 2>&1; }   # arquivo ausente/ilegivel = nao achou = reprova
# arquivo ausente: o wc nao imprime numero e a comparacao com o esperado reprova, nunca conta 0
nlines() { wc -l < "$1" | tr -d ' '; }

R="$T/nao-existe"; sr "" 0
[ "$RC" = "1" ] && has "ERRO:" && inlog "BACKUP_ROOT ausente" && ! has "nenhum <db>.new" \
  && ok "BACKUP_ROOT inexistente: sai 1, diz ERRO e para" || bad "BACKUP_ROOT inexistente: rc=$RC saida='$OUT'"

fresh; sr "" 0
[ "$RC" = "0" ] && has "nenhum <db>.new presente" && inlog "nenhum .new" && ! has "nao age" \
  && ok "raiz vazia: sai 0 e diz que nao ha troca interrompida" || bad "raiz vazia: rc=$RC saida='$OUT'"

fresh; : > "$R/x.new"; mkc y ok; sr 0 1
[ "$RC" = "0" ] && has "nenhum <db>.new presente" && ! has "nao age" && [ -f "$R/x.new" ] \
  && ok "um ARQUIVO x.new nao e um diretorio .new: ignorado" || bad "arquivo x.new: rc=$RC saida='$OUT'"

fresh; mkc x ok; mkc x.new ok; sr "" 1
[ "$RC" = "0" ] && has "x: nao age" && has "TEM manifest" && ! has "nenhum <db>.new" && inlog "recusa" \
  && [ -d "$R/x.new" ] && [ -f "$R/x/manifest" ] \
  && ok "primaria saudavel: recusa nomeada e nada se move" || bad "primaria saudavel: rc=$RC saida='$OUT'"

fresh; mkc x bare; mkc x.new ok
for d in "" 1 true; do
  sr "$d" 1
  [ "$RC" = "0" ] && has "completaria (modo seco, nada feito)" && ! has "NAO aplicada" && ! has "troca completada" \
    && inlog "seco, troca interrompida" && [ ! -e "$R/x.old" ] && [ -d "$R/x.new" ] && [ ! -e "$R/x/manifest" ] \
    && ok "DRY_RUN='$d': mostra o que faria e nao move nada" || bad "DRY_RUN='$d': rc=$RC saida='$OUT'"
done
sr sim 1
[ "$RC" = "0" ] && has "NAO aplicada: DRY_RUN='sim' nao e um valor reconhecido" && ! has "completaria" \
  && inlog "nao reconhecido" && [ ! -e "$R/x.old" ] && [ -d "$R/x.new" ] \
  && ok "DRY_RUN='sim': diz que ignorou o valor e nao move nada" || bad "DRY_RUN='sim': rc=$RC saida='$OUT'"
sr 0 0
[ "$RC" = "0" ] && has "restore+contagem" && ! has "troca completada" && [ ! -e "$R/x.old" ] && [ -d "$R/x.new" ] \
  && ok "agir sem a prova de restore (VERIFIED=0): recusa e nao move nada" || bad "VERIFIED=0: rc=$RC saida='$OUT'"

fresh; mkc x bare; mkc x.new ok; sr 0 1
[ "$RC" = "0" ] && has "troca completada" && ! has "FALHOU" && inlog "troca completada" && [ ! -s "$T/notify.log" ] \
  && [ -f "$R/x/manifest" ] && [ -d "$R/x.old" ] && [ ! -e "$R/x.old/manifest" ] && [ ! -e "$R/x.new" ] \
  && [ "$(nlines "$T/mv.log")" = "2" ] \
  && ok "agir: invalida vira .old, .new vira primaria, sem alarme" || bad "agir: rc=$RC saida='$OUT'"

# Um log que nao grava nao pode virar "rename falhou" quando os dois mv deram certo.
fresh; mkc x bare; mkc x.new ok; sr 0 1 DOLT_BACKUP_SWAP_REPAIR_LOG="$T/nao/existe/swap.log"
[ "$RC" = "0" ] && has "troca completada" && ! has "FALHOU" && [ ! -s "$T/notify.log" ] && [ -f "$R/x/manifest" ] \
  && ok "log ilegivel: a troca feita continua sendo 'completada', sem alarme falso" || bad "log ilegivel: rc=$RC saida='$OUT'"

fresh; mkc x bare; mkc x.new ok; sr 0 1 MV_FAIL_N=1
[ "$RC" = "0" ] && has "FALHOU ao renomear" && ! has "troca completada" && inlog "FALHA no rename" \
  && grep -F "rename falhou" "$T/notify.log" >/dev/null && [ "$(nlines "$T/mv.log")" = "1" ] \
  && [ ! -e "$R/x.old" ] && [ -d "$R/x.new" ] \
  && ok "1o mv falha: avisa, notifica e nao tenta o 2o" || bad "1o mv falha: rc=$RC saida='$OUT'"
fresh; mkc x bare; mkc x.new ok; sr 0 1 MV_FAIL_N=2
[ "$RC" = "0" ] && has "FALHOU ao renomear" && ! has "troca completada" && grep -F "rename falhou" "$T/notify.log" >/dev/null \
  && [ "$(nlines "$T/mv.log")" = "2" ] \
  && ok "2o mv falha: avisa e notifica, nunca diz 'completada'" || bad "2o mv falha: rc=$RC saida='$OUT'"

fresh; mkc x bare; mkc x.new ok; mkc x.old ok; sr 0 1
[ "$RC" = "0" ] && has "residue-reclaim" && ! has "troca completada" && [ -d "$R/x.new" ] && [ ! -e "$R/x/manifest" ] \
  && ok ".old do ciclo anterior: recusa e nao sobrescreve" || bad ".old existente: rc=$RC saida='$OUT'"
fresh; mkc x.new ok; sr 0 1
[ "$RC" = "0" ] && has "nao existe copia primaria" && ! has "FALHOU" && [ ! -e "$R/x" ] && [ -d "$R/x.new" ] \
  && ok "sem primaria: recusa e nao inventa uma" || bad "sem primaria: rc=$RC saida='$OUT'"
fresh; mkc a ok; mkc a.new ok; mkc b bare; mkc b.new ok; sr 0 1
[ "$RC" = "0" ] && has "a: nao age" && has "b: troca completada" && ! has "nenhum <db>.new" && [ -f "$R/b/manifest" ] \
  && ok "dois bancos: cada um decide sozinho e o laco segue" || bad "dois bancos: rc=$RC saida='$OUT'"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" = "0" ] || exit 1
exit 0
