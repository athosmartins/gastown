#!/usr/bin/env bash
# gate-auto-unblock.selftest.sh — testes herméticos do auto-destrave (ga-stu930).
#
# Substitui bd/git por shims dirigidos por fixture. Nenhum bead real é lido,
# nenhuma mutação real acontece. Sai 0 se tudo passar.
#
# CADA CENÁRIO É UM CASO REAL de 2026-08-15, não hipótese. Os nomes citam
# o bead que o originou, pra quem quebrar um teste saber o que perdeu.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/gate-auto-unblock.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '   ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '   ✗ %s\n     %s\n' "$1" "${2:-}"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT   # limpa em TODA saída (a lição do ga-nrkh92)

BIN="$TMP/bin"; mkdir -p "$BIN"
export PATH="$BIN:$PATH"

# ── shims ──────────────────────────────────────────────────────────────
# Dirigidos por arquivos em $TMP/fx: cada teste escreve a fixture e roda.
mk_shims() {
cat > "$BIN/bd" <<'SH'
#!/usr/bin/env bash
FX="${FX_DIR:?}"
case "$1$2$3" in *) :;; esac
# bd -C <rig> list --json --limit 0
if printf '%s ' "$@" | grep -q ' list '; then
  cat "$FX/list.json" 2>/dev/null || echo '[]'
  exit 0
fi
# bd -C <rig> show <id> --json
if printf '%s ' "$@" | grep -q ' show '; then
  for a in "$@"; do case "$a" in ga-*|wa-*|ps-*) ID="$a";; esac; done
  cat "$FX/show.$ID.json" 2>/dev/null || echo '[]'
  exit 0
fi
# bd label remove <id> <label>  → grava o que foi removido
if printf '%s ' "$@" | grep -q ' label remove '; then
  printf '%s %s\n' "${@: -2:1}" "${@: -1}" >> "$FX/removed.log"
  exit 0
fi
# bd comment
if printf '%s ' "$@" | grep -q ' comment '; then
  printf '%s\n' "${@: -1}" >> "$FX/comments.log"
  exit 0
fi
exit 0
SH
cat > "$BIN/git" <<'SH'
#!/usr/bin/env bash
FX="${FX_DIR:?}"
if printf '%s ' "$@" | grep -q 'for-each-ref'; then
  cat "$FX/branches.txt" 2>/dev/null; exit 0
fi
if printf '%s ' "$@" | grep -q ' cherry '; then
  [ -f "$FX/cherry_fail" ] && exit 1
  cat "$FX/cherry.txt" 2>/dev/null; exit 0
fi
if printf '%s ' "$@" | grep -q 'log -1'; then
  cat "$FX/tip_epoch.txt" 2>/dev/null; exit 0
fi
exit 0
SH
chmod +x "$BIN/bd" "$BIN/git"
}
mk_shims

# ── harness ────────────────────────────────────────────────────────────
# setup <id> <labels-json> <branches> <cherry> <tip_epoch> [comments-json]
setup() {
  FX="$TMP/fx.$1"; rm -rf "$FX"; mkdir -p "$FX"; export FX_DIR="$FX"
  printf '[{"id":"%s","status":"open","labels":%s,"comments":%s}]\n' \
    "$1" "$2" "${6:-[]}" > "$FX/show.$1.json"
  printf '[{"id":"%s","status":"open","labels":%s}]\n' "$1" "$2" > "$FX/list.json"
  printf '%s\n' "$3" > "$FX/branches.txt"
  printf '%s\n' "$4" > "$FX/cherry.txt"
  printf '%s\n' "$5" > "$FX/tip_epoch.txt"
  : > "$FX/removed.log"; : > "$FX/comments.log"
}
run() {
  GC_CITY_PATH="$TMP" WA_RIG="$TMP" PS_RIG="$TMP" \
  GATE_AUTO_UNBLOCK_LOG="$TMP/log" BD=bd GIT=git \
  bash "$SCRIPT" 2>&1
}

echo "gate-auto-unblock selftest"

# ── R1: sem branch → trava órfã (5 dos 8 casos de 15/08) ───────────────
setup ga-ih4ma '["gate:needs-human"]' '' '' ''
OUT="$(run)"
case "$OUT" in *"R1 ga-ih4ma"*) ok "R1: sem branch no remoto → trava órfã (ga-ih4ma e mais 4)";;
  *) bad "R1: sem branch deveria dar R1" "$OUT";; esac

# ── R1b: branch existe mas sem trabalho único (armadilha B) ────────────
# git cherry devolve '-' ⇒ patch já está em main por outro caminho.
# Caso real: wa-x92yd. Eu li "branch não mergeada" e concluí que havia
# trabalho a salvar. Não havia — era casca vazia.
setup wa-x92yd '["gate:needs-human"]' 'origin/crew/thies/wa-x92yd' '- 07621bfc' '1755000000'
OUT="$(run)"
case "$OUT" in *"R1 wa-x92yd"*) ok "R1b: git cherry '-' → sem trabalho único, NÃO é WIP a preservar (wa-x92yd)";;
  *) bad "R1b: cherry '-' deveria dar R1, não tratar como trabalho pendente" "$OUT";; esac

# ── R2: branch mudou depois da reprovação (ga-nrkh92) ──────────────────
setup ga-nrkh92 '["gate:needs-human","gate-sha-failed:aaa:code"]' \
  'origin/fix/ga-nrkh92-agent-idle-resume' '+ 8ef66141' '1900000000' \
  '[{"created_at":"2026-08-15T14:45:59Z","text":"VERDICT: FAIL blocking issue"}]'
OUT="$(run)"
case "$OUT" in *"R2 ga-nrkh92"*) ok "R2: commit posterior à reprovação → re-gatear (ga-nrkh92)";;
  *) bad "R2: tip mais novo que a falha deveria dar R2" "$OUT";; esac

# ── R4: 3+ reprovações → escala de ESCOPO, não de pessoa (wa-n46ay) ────
setup wa-n46ay '["gate:needs-human","gate-sha-failed:a:code","gate-sha-failed:b:code","gate-sha-failed:c:code"]' \
  'origin/crew/mila/wa-n46ay' '+ b40be47f' '1700000000' \
  '[{"created_at":"2026-08-15T10:00:00Z","text":"VERDICT: FAIL em lib/x.py"}]'
OUT="$(run)"
case "$OUT" in *"R4 wa-n46ay"*) ok "R4: 3+ falhas → conserto de CLASSE, não 5º pontual (wa-n46ay)";;
  *) bad "R4: 3 gate-sha-failed deveria dar R4, não R3" "$OUT";; esac

# ⚠️ CONTRAPESO do R4: sem ele o script viraria "sempre R4". Com 1 falha
# e veredito nomeando arquivo, tem que dar R3 — trabalho delimitado.
setup wa-uknuq '["gate:needs-human","gate-sha-failed:a:code"]' \
  'origin/crew/mila/wa-uknuq-r3' '+ eaf78abb' '1700000000' \
  '[{"created_at":"2026-08-15T10:00:00Z","text":"VERDICT: FAIL tests/test_pregao.py precisa da chave nova"}]'
OUT="$(run)"
case "$OUT" in *"R3 wa-uknuq"*) ok "R3: 1 falha + veredito nomeia arquivo → trabalho delimitado (wa-uknuq)";;
  *) bad "R3: deveria dar R3, não R4 — senão tudo vira 'conserto de classe'" "$OUT";; esac

# ── R5: nada decide → escala COM motivo ────────────────────────────────
setup ga-xyz '["gate:needs-human"]' 'origin/fix/ga-xyz' '+ abc' '1700000000' \
  '[{"created_at":"2026-08-15T10:00:00Z","text":"VERDICT: FAIL sem detalhe"}]'
OUT="$(run)"
case "$OUT" in *"R5 ga-xyz"*escalado*) ok "R5: nada decidiu → escala COM o motivo escrito";;
  *) bad "R5: deveria escalar dizendo por que R1-R4 não bastaram" "$OUT";; esac

# ── self-audit pré-gate: git cherry FALHA ≠ git cherry acha nada ───────
# Achado varrendo o diff inteiro antes de submeter (não um caso citado por
# revisor). has_own_work colapsava "comando não rodou" (lock, rig
# indisponível, ref stale) em "não achou trabalho" — e essa leitura
# disparava R1, que APAGA o label de verdade. Erro tem que virar R5
# (escala), nunca a mesma saída que "rodei e confirmei vazio".
setup wa-lockfail '["gate:needs-human"]' 'origin/crew/thies/wa-lockfail' '' ''
touch "$TMP/fx.wa-lockfail/cherry_fail"
OUT="$(run)"
case "$OUT" in *"R5 wa-lockfail"*"git cherry falhou"*)
    ok "self-audit: git cherry falhando (lock/rig indisponível) escala via R5, não vira R1 (falso órfão)";;
  *) bad "erro de git cherry deveria escalar (R5), não ser lido como 'sem trabalho único' (R1)" "$OUT";; esac

# ── armadilha D: label "failed" sem veredito FAIL (ga-xt8zrf) ──────────
# O marker dizia "failed", o revisor tinha dado PASS — quem falhou foi
# corrida entre branches irmãs. Sem veredito FAIL nos comentários, R5 tem
# que dizer ISSO, não fingir que houve reprovação e a branch não mudou.
setup ga-xt8zrf '["gate:needs-human"]' 'origin/fix/ga-xt8zrf' '+ dead1234' '1700000000' \
  '[{"created_at":"2026-08-15T10:00:00Z","text":"VERDICT: PASS — reviewer 1 clean"}]'
OUT="$(run)"
case "$OUT" in *"R5 ga-xt8zrf"*"nenhum veredito FAIL"*)
    ok "armadilha D: sem VERDICT:FAIL nos comentários → R5 diz isso, não finge reprovação (ga-xt8zrf)";;
  *) bad "armadilha D: deveria escalar dizendo que não há veredito FAIL, não 'sem commit após a reprovação'" "$OUT";; esac

# ── VARIANTES: as três que este script NÃO pode tocar ──────────────────
for v in gate:needs-human:product gate:needs-human:on-device gate:needs-human:refused; do
  setup ga-var "[\"$v\"]" '' '' ''
  OUT="$(run)"
  if printf '%s' "$OUT" | grep -q "SKIP ga-var"; then
    ok "variante $v NÃO é tocada (tem dono fora deste script)"
  else
    bad "variante $v foi tocada — :product é decisão do Athos, :on-device precisa do aparelho" "$OUT"
  fi
done

# ── armadilha E: variante protegida co-presente com uma unblockable ────
# Achado pelo revisor do gate (ga-5l5v76), não citado por mim: lock_variant
# só valida a PRIMEIRA label (head -1). Um bead com
# ["gate:needs-human","gate:needs-human:refused"] tem a bare validada como
# unblockable — e a versão antiga de strip_lock() removia AS DUAS,
# apagando a trava :refused em silêncio. Repro exato do revisor: sem
# branch (forçaria R1 se a variante protegida não travasse o bead antes).
setup ga-mixed '["gate:needs-human","gate:needs-human:refused"]' '' '' ''
OUT="$(run)"
if printf '%s' "$OUT" | grep -q "SKIP ga-mixed" && [ ! -s "$TMP/fx.ga-mixed/removed.log" ]; then
  ok "armadilha E: variante protegida co-presente com unblockable → SKIP, nenhuma label tocada (ga-5l5v76)"
else
  bad "armadilha E: deveria pular o bead inteiro sem remover nenhuma label" \
    "OUT=$OUT REMOVED=$(cat "$TMP/fx.ga-mixed/removed.log" 2>/dev/null)"
fi

# ── REGRESSÃO do meu erro de 15/08: prefixo vs exato ───────────────────
# Busquei travadas por PREFIXO (^gate:needs-human) e removi por texto
# EXATO ("gate:needs-human"). A busca achava, a remoção nunca casava, e
# reportei 8 destravadas quando 4 seguiam presas.
setup ga-pref '["gate:needs-human:technical"]' '' '' ''
run >/dev/null 2>&1
if grep -q 'gate:needs-human:technical' "$TMP/fx.ga-pref/removed.log" 2>/dev/null; then
  ok "remove a variante REALMENTE presente, não a que se supõe (regressão 15/08)"
else
  bad "removeu label errado: buscou por prefixo e removeu por exato" "$(cat "$TMP/fx.ga-pref/removed.log" 2>/dev/null)"
fi

# ── a decisão fica registrada no bead (auditabilidade) ─────────────────
setup ga-note '["gate:needs-human"]' '' '' ''
run >/dev/null 2>&1
if grep -q 'AUTO-DESTRAVE R1' "$TMP/fx.ga-note/comments.log" 2>/dev/null; then
  ok "grava no bead qual regra decidiu e por quê (sem isso é mutação silenciosa)"
else
  bad "não registrou a decisão no bead" "$(cat "$TMP/fx.ga-note/comments.log" 2>/dev/null)"
fi

# ── kill switch ────────────────────────────────────────────────────────
setup ga-off '["gate:needs-human"]' '' '' ''
OUT="$(GATE_AUTO_UNBLOCK_ENABLED=0 GC_CITY_PATH="$TMP" WA_RIG="$TMP" PS_RIG="$TMP" \
      GATE_AUTO_UNBLOCK_LOG="$TMP/log" bash "$SCRIPT" 2>&1)"
case "$OUT" in *DESLIGADO*) ok "kill switch desliga tudo (GATE_AUTO_UNBLOCK_ENABLED=0)";;
  *) bad "kill switch não funcionou" "$OUT";; esac

# ── DRY_RUN não muta ───────────────────────────────────────────────────
setup ga-dry '["gate:needs-human"]' '' '' ''
DRY_RUN=1 GC_CITY_PATH="$TMP" WA_RIG="$TMP" PS_RIG="$TMP" \
  GATE_AUTO_UNBLOCK_LOG="$TMP/log" bash "$SCRIPT" >/dev/null 2>&1
if [ ! -s "$TMP/fx.ga-dry/removed.log" ] && [ ! -s "$TMP/fx.ga-dry/comments.log" ]; then
  ok "DRY_RUN=1 decide mas não muta nada"
else
  bad "DRY_RUN mutou" "$(cat "$TMP/fx.ga-dry/removed.log" "$TMP/fx.ga-dry/comments.log" 2>/dev/null)"
fi

echo
printf 'gate-auto-unblock selftest: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
