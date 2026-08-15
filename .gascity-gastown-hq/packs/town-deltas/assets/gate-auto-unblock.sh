#!/usr/bin/env bash
# gate-auto-unblock.sh — tira o PORTEIRO HUMANO da trava do gate (ga-stu930).
#
# DECISÃO DO ATHOS (2026-08-15, textual):
#   "a trava é boa, o que questiono é a parte HUMANA. os agentes / você
#    têm que ser capazes de se auto destravarem e conduzir uma bead até
#    ela estar live depois que ela chega em 'aprovadas'"
#
# O DISJUNTOR FICA. Parar repetição cega depois de N reprovações é certo:
# 4 falhas na mesma função não são detalhe errado, é abordagem errada.
# O que sai é a exigência de um humano abrir a porta — porque medido em
# 2026-08-15, 8 de 14 beads que bateram na trava seguiam presas, algumas
# há uma semana. Trava sem porteiro é alçapão.
#
# ⚠️ ESTE SCRIPT NÃO DECIDE MÉRITO TÉCNICO. Ele aplica R1–R4, que são
# verificações mecânicas sobre o estado do git e do veredito. Quando
# nenhuma decide, ele PARA e escala (R5) — com o motivo escrito. Um
# auto-destravador que "acha" que o código está bom seria pior que a
# trava humana, não melhor.
#
# ────────────────────────────────────────────────────────────────────
# AS REGRAS, extraídas dos 8 destraves feitos à mão em 2026-08-15.
# Cada uma é o registro de uma decisão real, não uma hipótese:
#
#   R1  SEM TRABALHO → trava órfã.
#       Sem branch no remoto E sem commit próprio ⇒ não há o que revisar.
#       Limpa os labels de gate e devolve à fila.
#       (5 dos 8 casos: ga-ih4ma, ga-oko5c, ga-i0l8g, ga-aw0db, ga-avvu2)
#
#   R2  BRANCH MUDOU depois da reprovação → re-gatear direto.
#       O veredito velho fala de código que não existe mais.
#       (caso ga-nrkh92: o conserto já estava lá, e melhor que o pedido —
#        um trap EXIT cobrindo toda saída, vs o rm num ponto só)
#
#   R3  BRANCH IGUAL + veredito nomeia arquivo/mudança → trabalho
#       delimitado. Redespacha COM a instrução extraída do veredito.
#       (caso wa-uknuq: faltava UM teste, nomeado no próprio veredito)
#
#   R4  N falhas na MESMA função/mesma pergunta → escala de ESCOPO,
#       não de pessoa: exige conserto de classe + teste estrutural.
#       (caso wa-n46ay: produziu o melhor resultado do dia — um teste
#        que trava a FORMA do código e impede a 5ª rodada)
#
#   R5  Nada decidiu → escala, dizendo por que R1–R4 não bastaram.
#       Exceção rara. Sem o "por quê", vira a trava velha de novo.
#
# ────────────────────────────────────────────────────────────────────
# ⚠️ AS SETE VARIANTES (medidas 2026-08-15) — "needs-human" é SETE
# estados diferentes achatados sob um prefixo. Tratar como um só manda
# ao Athos o que é técnico, e tenta resolver sozinho o que é dele:
#
#   gate:needs-human                      genérico            → R1–R5
#   gate:needs-human:technical            decisão técnica     → R1–R5
#   gate:needs-human:branch-content-mismatch  vínculo errado  → R1–R5
#   gate:needs-human:partial-delivery     entrega parcial     → R1–R5
#   gate:needs-human:refused              pool recusou        → NÃO TOCA
#   gate:needs-human:on-device            precisa do aparelho → NÃO TOCA
#   gate:needs-human:product              decisão do ATHOS    → NÃO TOCA
#
# As três últimas não são "o gate reprovou e ninguém revisou" — são
# estados legítimos com dono fora deste script. Destravá-las seria
# empurrar trabalho para quem não pode fazê-lo (ou, no caso de
# :product, decidir no lugar do Athos).
#
# ────────────────────────────────────────────────────────────────────
# ARMADILHAS MEDIDAS que este script evita POR CONSTRUÇÃO. Todas me
# pegaram em 2026-08-15; cada uma tem cenário no selftest:
#
#   A) `git log --grep=<bead>` casa o CORPO da mensagem. Commit de OUTRO
#      bead que cite o id vira falso positivo de autoria. Eu conclui que
#      wa-x92yd tinha commit de 14/08 — era de wa-q07bf, que o citava.
#      ⇒ autoria se prova por --name-only do próprio commit, nunca grep.
#
#   B) "branch não mergeada" NÃO prova trabalho pendente. `git cherry`
#      (patch-id) devolvendo '-' significa que o conteúdo já chegou por
#      outro caminho — branch órfã. Redespachar dali é redespachar casca.
#
#   C) labels de gate são ADITIVOS entre branches irmãs: gate:failed pode
#      ser de uma tentativa antiga enquanto a atual passou.
#      ⇒ ler o VEREDITO (bead fechado), não o label.
#
#   D) reprovação pode ser de PROCESSO, não de qualidade. Em ga-xt8zrf o
#      marker dizia "failed" e o revisor tinha dado verdict:PASS — o que
#      falhou foi corrida entre branches irmãs.
#      ⇒ "failed" não significa "código ruim".
#
#   E) lock_variant() só valida a PRIMEIRA label presente (head -1), mas
#      a versão original de strip_lock() removia TODAS as gate:needs-human*
#      presentes. Achado pelo revisor do gate (ga-5l5v76), não por mim:
#      um bead com ["gate:needs-human","gate:needs-human:refused"] tem a
#      bare validada como unblockable (sorta antes da sufixada) e as DUAS
#      removidas — apagando silenciosamente uma trava NAO TOCA.
#      ⇒ se QUALQUER label presente cai fora de UNBLOCKABLE_VARIANTS, o
#        bead inteiro fica de fora — ver has_protected_variant().
#
# ────────────────────────────────────────────────────────────────────
# TEST SEAM: BD/GC/GIT/NOTIFY são sobreponíveis para o selftest hermético.
# DRY_RUN=1 → decide e loga, não muta nada.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
BD="${BD:-bd}"
GC="${GC:-gc}"
GIT="${GIT:-git}"
NOTIFY="${NOTIFY_BIN:-notify}"
DRY_RUN="${DRY_RUN:-0}"
MAYOR_ADDR="${MAYOR_ADDR:-mayor}"
LOG="${GATE_AUTO_UNBLOCK_LOG:-$CITY/.gc/logs/gate-auto-unblock.log}"

# Kill switch — mesma convenção dos irmãos (dolt-compact-routine, disk-floor-guard).
ENABLED="${GATE_AUTO_UNBLOCK_ENABLED:-1}"

# Variantes que ESTE script pode destravar. As de fora ficam de fora por
# desenho, não por esquecimento — ver bloco acima.
UNBLOCKABLE_VARIANTS="${GATE_AUTO_UNBLOCK_VARIANTS:-gate:needs-human gate:needs-human:technical gate:needs-human:branch-content-mismatch gate:needs-human:partial-delivery}"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" 2>/dev/null || true; }
say() { printf '%s\n' "$*"; log "$*"; }

[ "$ENABLED" = "1" ] || { say "gate-auto-unblock: DESLIGADO (GATE_AUTO_UNBLOCK_ENABLED=0)"; exit 0; }

# ── helpers ────────────────────────────────────────────────────────────

# rig_dir <bead_id> → diretório do rig, derivado do prefixo.
# ⚠️ prefixo NÃO é o repo de entrega (aprendido em 2026-08-15) — isto é
# só o palpite inicial; quem usa confere.
rig_dir() {
  case "$1" in
    wa-*) printf '%s' "${WA_RIG:-/Users/athos/gt/whatsapp_automation}" ;;
    ps-*) printf '%s' "${PS_RIG:-/Users/athos/gt/property_scrapers}" ;;
    *)    printf '%s' "$CITY" ;;
  esac
}

# branch_for <rig> <bead> → nome da branch no REMOTO, ou vazio.
# Casa o id exato E variantes com sufixo (-r2, -v2, -fix…), com a mesma
# regra literal do lifecycle-auditor (ga-luyz48): o hífen ancora a
# fronteira, então wa-v89e3 não casa a branch de wa-v89e3.9.
branch_for() {
  local rig="$1" id="$2"
  "$GIT" -C "$rig" for-each-ref --format='%(refname:short)' \
    'refs/remotes/origin/crew/*/*' 'refs/remotes/origin/fix/*' 2>/dev/null \
    | awk -F/ -v id="$id" '$NF==id || substr($NF,1,length(id)+1)==id"-" {print; exit}'
}

# has_own_work <rig> <branch> → "yes" | "no" | "unknown" (git cherry falhou).
# Armadilha (B): usa git cherry (patch-id), não "branch --merged" (ref).
# '-' = patch já está em main por outro caminho ⇒ NÃO é trabalho único.
# "unknown" (git cherry não RODOU — lock, rig indisponível, ref stale) NÃO
# pode virar "no": um comando que falha e um comando que roda e não acha
# nada não são a mesma coisa, e só o segundo prova órfã. Achado no
# self-audit pré-gate: a versão anterior colapsava os dois em `return 1`,
# e R1 (que APAGA o label de verdade) disparava em cima de "não sei".
has_own_work() {
  local rig="$1" br="$2" out
  [ -n "$br" ] || { printf 'no'; return 0; }
  out="$("$GIT" -C "$rig" cherry origin/main "$br" 2>/dev/null)"
  if [ $? -ne 0 ]; then
    printf 'unknown'
    return 0
  fi
  if printf '%s' "$out" | grep -q '^+'; then
    printf 'yes'
  else
    printf 'no'
  fi
}

# branch_tip_epoch <rig> <branch> → epoch do último commit, ou vazio.
branch_tip_epoch() {
  "$GIT" -C "$1" log -1 --format='%ct' "$2" 2>/dev/null
}

# labels_of <rig> <bead> → labels, um por linha.
labels_of() {
  "$BD" -C "$1" show "$2" --json 2>/dev/null | jq -r '.[0].labels[]?' 2>/dev/null
}

# lock_variant <rig> <bead> → a variante de trava presente, ou vazio.
lock_variant() {
  labels_of "$1" "$2" | grep '^gate:needs-human' | head -1
}

# is_unblockable <variante> → 0 se este script pode mexer.
# ⚠️ comparação EXATA, item a item. Em 2026-08-15 eu busquei por PREFIXO
# e removi por texto EXATO: a busca achava, a remoção nunca casava, e 4
# beads ficaram "destravadas" no meu relato e travadas na realidade.
is_unblockable() {
  local v="$1" allowed
  for allowed in $UNBLOCKABLE_VARIANTS; do
    [ "$v" = "$allowed" ] && return 0
  done
  return 1
}

# has_protected_variant <rig> <bead> → 0 se QUALQUER label presente cai
# fora de UNBLOCKABLE_VARIANTS (armadilha E). lock_variant() só olha a
# PRIMEIRA label (head -1); esta função varre TODAS as gate:needs-human*
# presentes, então detecta uma protegida mesmo co-presente com uma
# unblockable — o caso que escapava antes e que strip_lock() apagaria.
has_protected_variant() {
  local rig="$1" id="$2" v
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    is_unblockable "$v" || return 0
  done < <(labels_of "$rig" "$id" | grep '^gate:needs-human')
  return 1
}

# strip_lock <rig> <bead> — remove TODAS as variantes presentes, não a
# que eu supus estar lá (ver acima). Só é chamada depois que main()
# confirma has_protected_variant=false, então "todas as presentes" já
# está restrito a variantes unblockable neste ponto.
strip_lock() {
  local rig="$1" id="$2" v
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    [ "$DRY_RUN" = "1" ] || "$BD" -C "$rig" label remove "$id" "$v" >/dev/null 2>&1
  done < <(labels_of "$rig" "$id" | grep '^gate:needs-human')
}

# note <rig> <bead> <texto> — registra a decisão NO bead. Sem isto, o
# auto-destrave vira mutação silenciosa e ninguém audita a regra.
note() {
  [ "$DRY_RUN" = "1" ] && return 0
  "$BD" -C "$1" comment "$2" "$3" >/dev/null 2>&1
}

# ── as regras ──────────────────────────────────────────────────────────
# decide <rig> <bead> → imprime "Rn|explicação". Não muta.
decide() {
  local rig="$1" id="$2" br tip last_fail_epoch verdict

  br="$(branch_for "$rig" "$id")"

  # R1 — sem trabalho: trava órfã.
  if [ -z "$br" ]; then
    printf 'R1|sem branch no remoto e sem commit próprio: não há o que revisar'
    return 0
  fi
  local work_state
  work_state="$(has_own_work "$rig" "$br")"
  if [ "$work_state" = "no" ]; then
    printf 'R1|branch %s existe mas git cherry não acusa trabalho único (patch já em main por outro caminho)' "$br"
    return 0
  fi
  if [ "$work_state" = "unknown" ]; then
    printf 'R5|git cherry falhou ao comparar %s com origin/main (rig indisponível, lock, ou ref stale) — não dá pra confirmar se há trabalho único, não é seguro tratar como órfã' "$br"
    return 0
  fi

  # Epoch da última reprovação, do MARKER (não do label — armadilha C).
  last_fail_epoch="$("$BD" -C "$rig" show "$id" --json 2>/dev/null \
    | jq -r '[.[0].comments[]?|select((.text//"")|test("GATE-FEEDBACK|VERDICT: FAIL"))]|last|.created_at // empty' 2>/dev/null \
    | { read -r d; [ -n "${d:-}" ] && date -j -f '%Y-%m-%dT%H:%M:%SZ' "$d" '+%s' 2>/dev/null || date -d "${d:-now}" '+%s' 2>/dev/null; })"

  tip="$(branch_tip_epoch "$rig" "$br")"

  # R2 — branch mudou depois da reprovação.
  if [ -n "$tip" ] && [ -n "${last_fail_epoch:-}" ] && [ "$tip" -gt "$last_fail_epoch" ] 2>/dev/null; then
    printf 'R2|branch %s tem commit posterior à última reprovação: o veredito fala de código que não existe mais' "$br"
    return 0
  fi

  # R4 antes de R3: se o mesmo ponto falhou N vezes, o problema é de
  # ESCOPO. Redespachar com instrução (R3) produziria a 5ª rodada.
  local fails
  fails="$(labels_of "$rig" "$id" | grep -c '^gate-sha-failed:')"
  if [ "${fails:-0}" -ge 3 ]; then
    printf 'R4|%s reprovações registradas: escala de ESCOPO — exigir conserto de classe + teste estrutural, não mais um caso' "$fails"
    return 0
  fi

  # R3 — veredito nomeia trabalho delimitado.
  verdict="$("$BD" -C "$rig" show "$id" --json 2>/dev/null \
    | jq -r '[.[0].comments[]?|select((.text//"")|test("VERDICT: FAIL"))]|last|.text // empty' 2>/dev/null)"
  if printf '%s' "$verdict" | grep -qE '\.(py|sh|go|js|html|json)\b'; then
    printf 'R3|veredito nomeia arquivo específico: trabalho delimitado, redespachar COM a instrução extraída'
    return 0
  fi

  # R5 — nada decidiu.
  # Armadilha (D): se last_fail_epoch está vazio, não é que a branch não
  # mudou "depois" da reprovação — é que NENHUM veredito FAIL foi achado
  # (ga-xt8zrf: label dizia "failed", revisor tinha dado PASS, quem falhou
  # foi corrida entre irmãs). A mensagem de R2 tem que dizer a diferença,
  # senão o Mayor lê "houve reprovação, branch não mudou" quando na
  # verdade não há reprovação nenhuma registrada.
  local r2_why
  if [ -z "${last_fail_epoch:-}" ]; then
    r2_why='nenhum veredito FAIL encontrado nos comentários — o label pode ser espúrio (armadilha D: reprovação de processo, não de qualidade)'
  else
    r2_why='sem commit após a reprovação'
  fi
  printf 'R5|R1 não (branch %s tem trabalho único) · R2 não (%s) · R4 não (%s reprovações, abaixo de 3) · R3 não (veredito não nomeia arquivo)' "$br" "$r2_why" "${fails:-0}"
}

# ── varredura ──────────────────────────────────────────────────────────
main() {
  local rig id variant rule why n=0 acted=0
  for rig in "$CITY" "${WA_RIG:-/Users/athos/gt/whatsapp_automation}" "${PS_RIG:-/Users/athos/gt/property_scrapers}"; do
    [ -d "$rig" ] || continue
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      n=$((n+1))
      variant="$(lock_variant "$rig" "$id")"
      if has_protected_variant "$rig" "$id"; then
        say "SKIP $id — carrega variante protegida (NAO TOCA) entre as labels gate:needs-human* presentes (pode coexistir com uma unblockable, ex. '$variant' — armadilha E); nenhuma label é tocada"
        continue
      fi
      IFS='|' read -r rule why <<< "$(decide "$rig" "$id")"
      case "$rule" in
        R1)
          strip_lock "$rig" "$id"
          note "$rig" "$id" "AUTO-DESTRAVE R1 (ga-stu930): trava órfã — $why. Labels de gate removidos; bead volta à fila. Nenhum humano precisou olhar."
          say "R1 $id — $why"; acted=$((acted+1)) ;;
        R2)
          strip_lock "$rig" "$id"
          note "$rig" "$id" "AUTO-DESTRAVE R2 (ga-stu930): $why. Re-submeter ao gate: o veredito anterior é sobre código que já mudou."
          say "R2 $id — $why"; acted=$((acted+1)) ;;
        R3)
          strip_lock "$rig" "$id"
          note "$rig" "$id" "AUTO-DESTRAVE R3 (ga-stu930): $why. Redespachado com a instrução do veredito, não com 'conserte'."
          say "R3 $id — $why"; acted=$((acted+1)) ;;
        R4)
          strip_lock "$rig" "$id"
          note "$rig" "$id" "AUTO-DESTRAVE R4 (ga-stu930): $why. ⚠️ NÃO faça o 5º conserto pontual — o padrão de repetição É o achado. Exigir teste ESTRUTURAL, que trave a forma do código."
          say "R4 $id — $why"; acted=$((acted+1)) ;;
        R5)
          note "$rig" "$id" "AUTO-DESTRAVE R5 (ga-stu930): nenhuma regra decidiu — $why. Escalando ao Mayor COM o motivo, que é o que a trava antiga não fazia."
          say "R5 $id — escalado: $why" ;;
        *)
          say "ERRO $id — decide() não devolveu regra (saída: '$rule')" ;;
      esac
    done < <("$BD" -C "$rig" list --json --limit 0 2>/dev/null \
              | jq -r '.[]|select(.status!="closed")|select((.labels//[])|any(startswith("gate:needs-human")))|.id' 2>/dev/null)
  done
  say "gate-auto-unblock: $n travadas examinadas, $acted destravadas sem humano"
}

main "$@"
