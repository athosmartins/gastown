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
# Dispatch por POSIÇÃO ($3 = subcomando, sempre após "-C <rig>"), NUNCA
# por substring do argv inteiro. ⚠️ Achado ao vivo (2ª rodada
# adversarial, achado D): o TEXTO de nota/comentário deste script FALA
# SOBRE comandos bd — ex. "bd label remove falhou" — e um dispatch por
# `grep -q ' label remove '` casava esse TEXTO (passado como argumento
# de `bd comment`) com o comando ERRADO (label remove), fazendo a
# fixture de falha de label-remove disparar por acidente numa chamada
# de comment que não tinha nada a ver. Dispatch posicional não tem essa
# ambiguidade: o subcomando é sempre argv[3], nunca texto livre.
SUBCMD="${3:-}"
case "$SUBCMD" in
  list)
    cat "$FX/list.json" 2>/dev/null || echo '[]'
    exit 0
    ;;
  show)
    # bd -C <rig> show <id> --json [--include-comments]
    # ⚠️ FIEL ao bd real (ga-di6t52): --json SEM --include-comments OMITE
    # comments (confirmado ao vivo: sem a flag, .comments ausente do
    # JSON — nem vazio, AUSENTE). Dois arquivos de fixture: um fiel ao
    # "sem flag" (sem comments) e um ao "com flag" (com comments).
    # show_fail (arquivo-gatilho): simula bd show FALHANDO de verdade
    # (exit != 0), distinto de "bd show teve sucesso e devolveu bead sem
    # labels" — testa achados A/B da 2ª rodada adversarial.
    ID="${4:-}"
    [ -f "$FX/show_fail.$ID" ] && exit 1
    HAS_COMMENTS_FLAG=0
    for a in "$@"; do [ "$a" = "--include-comments" ] && HAS_COMMENTS_FLAG=1; done
    # show_fail_with_comments (arquivo-gatilho): falha SÓ a variante
    # --include-comments, deixando a chamada simples (main()'s
    # fetch_labels) intacta — testa decide()'s própria show_json fetch
    # falhando isoladamente (self-audit final, mesma classe de A/B).
    if [ "$HAS_COMMENTS_FLAG" = "1" ] && [ -f "$FX/show_fail_with_comments.$ID" ]; then
      exit 1
    fi
    if [ "$HAS_COMMENTS_FLAG" = "1" ]; then
      cat "$FX/show.$ID.full.json" 2>/dev/null || echo '[]'
    else
      cat "$FX/show.$ID.json" 2>/dev/null || echo '[]'
    fi
    exit 0
    ;;
  label)
    # bd -C <rig> label remove <id> <label>  → grava o que foi removido,
    # ou falha se a fixture pedir (label_remove_fail — blocking issue 1).
    [ "${4:-}" = "remove" ] || exit 0
    [ -f "$FX/label_remove_fail" ] && exit 1
    printf '%s %s\n' "${5:-}" "${6:-}" >> "$FX/removed.log"
    exit 0
    ;;
  comment)
    # bd -C <rig> comment <id> <texto> → grava, ou falha se a fixture
    # pedir (comment_fail) — "pior sub-caso" citado pelo revisor.
    [ -f "$FX/comment_fail" ] && exit 1
    printf '%s\n' "${@: -1}" >> "$FX/comments.log"
    exit 0
    ;;
esac
exit 0
SH
cat > "$BIN/git" <<'SH'
#!/usr/bin/env bash
FX="${FX_DIR:?}"
# Mesmo princípio do shim bd acima: dispatch por $3 (subcomando),
# não por substring do argv inteiro.
SUBCMD="${3:-}"
case "$SUBCMD" in
  for-each-ref)
    cat "$FX/branches.txt" 2>/dev/null
    exit 0
    ;;
  cherry)
    # git -C <rig> cherry origin/main <branch> — o ÚLTIMO arg é o
    # branch. Fixture POR-BRANCH (cherry.<branch-saneado>.txt) tem
    # prioridade sobre a genérica (cherry.txt) — testa blocking issue 2:
    # dois branches do MESMO bead precisam responder DIFERENTE.
    BR="${@: -1}"; SAFE="$(printf '%s' "$BR" | tr '/' '_')"
    [ -f "$FX/cherry_fail.$SAFE" ] && exit 1
    [ -f "$FX/cherry_fail" ] && exit 1
    if [ -f "$FX/cherry.$SAFE.txt" ]; then
      cat "$FX/cherry.$SAFE.txt"
    else
      cat "$FX/cherry.txt" 2>/dev/null
    fi
    exit 0
    ;;
  log)
    # git -C <rig> log -1 --format=... <branch> — mesma lógica
    # por-branch (blocking issue 2).
    BR="${@: -1}"; SAFE="$(printf '%s' "$BR" | tr '/' '_')"
    if [ -f "$FX/tip_epoch.$SAFE.txt" ]; then
      cat "$FX/tip_epoch.$SAFE.txt"
    else
      cat "$FX/tip_epoch.txt" 2>/dev/null
    fi
    exit 0
    ;;
esac
exit 0
SH
chmod +x "$BIN/bd" "$BIN/git"
}
mk_shims

# ── harness ────────────────────────────────────────────────────────────
# setup <id> <labels-json> <branches> <cherry> <tip_epoch> [comments-json]
setup() {
  FX="$TMP/fx.$1"; rm -rf "$FX"; mkdir -p "$FX"; export FX_DIR="$FX"
  # show.$1.json: bd show --json SEM --include-comments (shape real: sem
  # a chave "comments", com "comments_omitted":true — ver nota no shim).
  printf '[{"id":"%s","status":"open","labels":%s,"comments_omitted":true}]\n' \
    "$1" "$2" > "$FX/show.$1.json"
  # show.$1.full.json: bd show --json --include-comments (com a chave).
  printf '[{"id":"%s","status":"open","labels":%s,"comments":%s}]\n' \
    "$1" "$2" "${6:-[]}" > "$FX/show.$1.full.json"
  printf '[{"id":"%s","status":"open","labels":%s}]\n' "$1" "$2" > "$FX/list.json"
  printf '%s\n' "$3" > "$FX/branches.txt"
  printf '%s\n' "$4" > "$FX/cherry.txt"
  printf '%s\n' "$5" > "$FX/tip_epoch.txt"
  : > "$FX/removed.log"; : > "$FX/comments.log"
}
run() {
  GC_CITY_PATH="$TMP" WA_RIG="$TMP" PS_RIG="$TMP" \
  GATE_AUTO_UNBLOCK_LOG="$TMP/log" GATE_AUTO_UNBLOCK_LOCK="$TMP/gate-auto-unblock.lock" \
  BD=bd GIT=git \
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
# ⚠️ (revisor, gate-run ga-oaqy39, blocking issue 3): não basta disparar
# R3 — o TEXTO do veredito extraído precisa aparecer de verdade na saída,
# senão "redespachar COM a instrução do veredito" é só alegação. A versão
# antiga disparava R3 mas o texto nunca chegava a lugar nenhum.
case "$OUT" in
  *"R3 wa-uknuq"*"tests/test_pregao.py precisa da chave nova"*)
    ok "R3: 1 falha + veredito nomeia arquivo → trabalho delimitado, instrução real propagada (wa-uknuq)";;
  *) bad "R3: deveria dar R3 E propagar o TEXTO do veredito extraído (não só disparar a regra) — senão 'instrução extraída' é alegação sem efeito" "$OUT";; esac

# ── R5: nada decide → escala COM motivo ────────────────────────────────
setup ga-xyz '["gate:needs-human"]' 'origin/fix/ga-xyz' '+ abc' '1700000000' \
  '[{"created_at":"2026-08-15T10:00:00Z","text":"VERDICT: FAIL sem detalhe"}]'
OUT="$(run)"
case "$OUT" in *"R5 ga-xyz"*escalado*) ok "R5: nada decidiu → escala COM o motivo escrito";;
  *) bad "R5: deveria escalar dizendo por que R1-R4 não bastaram" "$OUT";; esac

# ── ga-9e0j8: R5 SEM cooldown reescalona IDENTICAMENTE a cada varredura
# ──────────────────────────────────────────────────────────────────────
# R5 é a ÚNICA regra que não muta nenhuma label (R1-R4 chamam strip_lock,
# que tira o bead do filtro de main() na PRÓXIMA varredura — R5 não tem
# esse freio). Sem cooldown, decide() devolve o MESMO R5|why sempre que a
# fixture não muda, e o script postava um comentário idêntico a CADA
# chamada. Medido numa bead real (wa-wpbfi): 60+ comentários idênticos em
# ~20h. Repro: MESMA fixture, script rodado 2x em sequência (as duas
# dentro do cooldown padrão de 6h) — a 2ª chamada tem que ser SUPRIMIDA,
# não postar um 2º comentário idêntico.
setup ga-r5loop '["gate:needs-human"]' 'origin/fix/ga-r5loop' '+ dead5678' '1700000000' \
  '[{"created_at":"2026-08-15T10:00:00Z","text":"VERDICT: FAIL sem detalhe"}]'
OUT1="$(run)"
OUT2="$(run)"
R5_COMMENTS="$(grep -c 'AUTO-DESTRAVE R5' "$TMP/fx.ga-r5loop/comments.log" 2>/dev/null || echo 0)"
if printf '%s' "$OUT1" | grep -q "R5 ga-r5loop.*escalado" \
   && printf '%s' "$OUT2" | grep -qi "R5 ga-r5loop.*suprimid" \
   && [ "$R5_COMMENTS" -eq 1 ]; then
  ok "ga-9e0j8: R5 escala na 1ª varredura, SUPRIME a 2ª (cooldown) — nunca mais de 1 comentário idêntico por janela"
else
  bad "ga-9e0j8: R5 deveria escalar só 1x dentro do cooldown, não repetir o comentário a cada varredura (era o bug real: 60+ comentários idênticos em 20h)" \
    "OUT1=$OUT1 OUT2=$OUT2 R5_COMMENTS=$R5_COMMENTS COMMENTS=$(cat "$TMP/fx.ga-r5loop/comments.log" 2>/dev/null)"
fi

# ── ga-9e0j8: depois que o cooldown REALMENTE decorre, R5 volta a
# escalar COM contador visível ──────────────────────────────────────────
# Cobre a outra metade do pedido do bug: suprimir não pode virar "nunca
# mais", e a mensagem tem que mostrar QUANTAS vezes já tentou. Simula o
# tempo passando adiantando o stamp diretamente (sem sleep real de 6h) —
# a varredura em si usa sempre o R5_ALERT_COOLDOWN PADRÃO (21600s); só o
# relógio é simulado, não o mecanismo. (Não usa
# GATE_AUTO_UNBLOCK_R5_COOLDOWN=0 aqui de propósito: este harness aponta
# GC_CITY_PATH/WA_RIG/PS_RIG pro MESMO $TMP, então main() varre a mesma
# fixture 3x por chamada de run() — com cooldown=0 as 3 passadas internas
# disparam TODAS, o que testaria o comparador de fronteira, não o
# "reescala depois que o tempo passa" que este caso quer cobrir.)
setup ga-r5count '["gate:needs-human"]' 'origin/fix/ga-r5count' '+ beef9012' '1700000000' \
  '[{"created_at":"2026-08-15T10:00:00Z","text":"VERDICT: FAIL sem detalhe"}]'
OUT1="$(run)"
R5_DIR="$TMP/.gc/runtime/gate-auto-unblock-r5-alerted"
STAMP_COUNT="$(awk '{print $2}' "$R5_DIR/ga-r5count" 2>/dev/null)"
# adianta o stamp pra "9h atrás" (> cooldown de 6h), mantendo o contador —
# é exatamente o que o tempo passando faria, só sem esperar de verdade.
printf '%s %s' "$(( $(date -u +%s) - 32400 ))" "${STAMP_COUNT:-1}" > "$R5_DIR/ga-r5count"
OUT2="$(run)"
R5_COMMENTS2="$(grep -c 'AUTO-DESTRAVE R5' "$TMP/fx.ga-r5count/comments.log" 2>/dev/null || echo 0)"
if [ "$R5_COMMENTS2" -eq 2 ] \
   && grep -q 'tentativa #1' "$TMP/fx.ga-r5count/comments.log" 2>/dev/null \
   && grep -q 'tentativa #2' "$TMP/fx.ga-r5count/comments.log" 2>/dev/null; then
  ok "ga-9e0j8: depois que o cooldown decorre, R5 volta a escalar com contador visível (#1 → #2)"
else
  bad "ga-9e0j8: depois do cooldown decorrido deveria reescalar 1x mais E mostrar o contador crescendo" \
    "OUT1=$OUT1 OUT2=$OUT2 COMMENTS=$(cat "$TMP/fx.ga-r5count/comments.log" 2>/dev/null)"
fi

# ── blocking issue 1 (revisor, gate-run ga-woesw): R5 falhando ao
# ESCALAR (bd comment falha) não pode consumir o cooldown ─────────────
# should_alert_r5() gravava o stamp (epoch+contador) ANTES de main() sequer
# tentar note() — o R5 case block só decide chamar note() DEPOIS de já ter
# recebido rc0 de should_alert_r5, que por sua vez já tinha gravado o
# arquivo como efeito colateral da própria chamada. Se note() falhasse
# (bd comment real falhando), o script reportava "FALHA R5 ... escalação
# NÃO registrada" — mas o stamp já dizia "tentativa #1 feita agora", então
# a PRÓXIMA varredura via cooldown ainda quente e SUPRIMIA, achando que já
# tinha escalado quando na verdade nunca chegou a postar nada: o bead fica
# mudo até o cooldown (6h) decorrer, mesmo bug de fundo do ticket original
# (escalação que devia ser acionável vira silêncio), só que agora causado
# pelo PRÓPRIO mecanismo de cooldown em vez da falta dele.
setup ga-r5notefail '["gate:needs-human"]' 'origin/fix/ga-r5notefail' '+ fadefeed' '1700000000' \
  '[{"created_at":"2026-08-15T10:00:00Z","text":"VERDICT: FAIL sem detalhe"}]'
touch "$TMP/fx.ga-r5notefail/comment_fail"
OUT1="$(run)"
rm -f "$TMP/fx.ga-r5notefail/comment_fail"
OUT2="$(run)"
R5_COMMENTS3="$(grep -c 'AUTO-DESTRAVE R5' "$TMP/fx.ga-r5notefail/comments.log" 2>/dev/null || echo 0)"
if printf '%s' "$OUT1" | grep -q "FALHA R5 ga-r5notefail" \
   && printf '%s' "$OUT2" | grep -q "R5 ga-r5notefail.*escalado" \
   && printf '%s' "$OUT2" | grep -q 'tentativa #1' \
   && [ "$R5_COMMENTS3" -eq 1 ]; then
  ok "blocking issue 1 (ga-woesw): note() falhando NÃO consome o cooldown — retenta e escala na próxima varredura, ainda na tentativa #1"
else
  bad "blocking issue 1 (ga-woesw): quando bd comment falha, should_alert_r5 não pode ter gravado o stamp — a próxima varredura tem que RETENTAR (não suprimir achando que já escalou)" \
    "OUT1=$OUT1 OUT2=$OUT2 R5_COMMENTS3=$R5_COMMENTS3 COMMENTS=$(cat "$TMP/fx.ga-r5notefail/comments.log" 2>/dev/null)"
fi

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

# ── blocking issue 2 (revisor, gate-run ga-oaqy39): branch_for deve
# escolher o branch mais RECENTE entre múltiplos matches, não o que
# ordena primeiro alfabeticamente ───────────────────────────────────────
# for-each-ref devolve crew/*/* e fix/* JUNTOS, ORDENADOS — "crew" < "fix"
# sempre. Sem este fix, se o MESMO bead tivesse branch nas duas
# namespaces (uma abandonada, outra real — a branch ativa de um bead
# pode legitimamente migrar de namespace ao longo da vida dele), a
# escolha era sempre a crew/*/* por acidente alfabético, nunca a mais
# recente. Fixture: branch crew ANTIGA sem trabalho único (dispararia R1
# destrutivo se fosse escolhida) + branch fix mais NOVA com trabalho
# único de verdade. Só passa se a nova for a escolhida.
setup wa-multi '["gate:needs-human"]' \
  "$(printf 'origin/crew/oldcrew/wa-multi\norigin/fix/wa-multi-newer')" '' ''
echo '-' > "$TMP/fx.wa-multi/cherry.origin_crew_oldcrew_wa-multi.txt"
echo '1000000000' > "$TMP/fx.wa-multi/tip_epoch.origin_crew_oldcrew_wa-multi.txt"
echo '+ abcdef01' > "$TMP/fx.wa-multi/cherry.origin_fix_wa-multi-newer.txt"
echo '1900000000' > "$TMP/fx.wa-multi/tip_epoch.origin_fix_wa-multi-newer.txt"
OUT="$(run)"
case "$OUT" in
  *"R5 wa-multi"*"origin/fix/wa-multi-newer"*)
    ok "blocking issue 2: escolhe o branch mais RECENTE (fix/wa-multi-newer), não o alfabeticamente primeiro (crew/oldcrew/wa-multi)";;
  *"R1 wa-multi"*)
    bad "blocking issue 2: escolheu a branch crew ABANDONADA (alfabeticamente primeira) e disparou R1 — a branch fix REAL com trabalho pendente ficaria sem lock e sem exame" "$OUT";;
  *) bad "blocking issue 2: resultado inesperado" "$OUT";;
esac

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

# ── self-audit pré-gate (resubmissão): last_fail_epoch não pode virar
# "agora" quando $d vem vazio ────────────────────────────────────────
# A versão antiga usava `date -d "${d:-now}"` como fallback. Neste Mac
# (BSD date) isso FALHA e mascara o problema — mas em qualquer host onde
# `date -d now` tenha sucesso (GNU date), "não há veredito FAIL" vira
# silenciosamente "o veredito foi AGORA", quebrando a própria mensagem de
# armadilha D. Shim de `date` que aceita -d e recusa -j -f (perfil GNU),
# escopado só a este run via PATH — não afeta o resto do arquivo.
FAKE_DATE_BIN="$TMP/fakedate"; mkdir -p "$FAKE_DATE_BIN"
cat > "$FAKE_DATE_BIN/date" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "-j" ] && exit 1; done
printf '9999999999\n'
SH
chmod +x "$FAKE_DATE_BIN/date"

setup ga-xt8zrf-gnu '["gate:needs-human"]' 'origin/fix/ga-xt8zrf-gnu' '+ dead1234' '1700000000' \
  '[{"created_at":"2026-08-15T10:00:00Z","text":"VERDICT: PASS — reviewer 1 clean"}]'
OUT="$(PATH="$FAKE_DATE_BIN:$PATH" run)"
case "$OUT" in *"R5 ga-xt8zrf-gnu"*"nenhum veredito FAIL"*)
    ok "armadilha D sobrevive em host com GNU date (last_fail_epoch não vira 'agora' quando \$d vazio)";;
  *) bad "em host GNU-date, last_fail_epoch viraria 'agora' e a mensagem mudaria para 'sem commit apos a reprovacao'" "$OUT";; esac

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

# ── blocking issue 1 (revisor, gate-run ga-oaqy39): bd label remove
# falhando NÃO pode ser reportado como sucesso ──────────────────────────
# Antes, `strip_lock`/`note` engoliam `>/dev/null 2>&1` sem checar $?, e
# main() fazia say+acted++ incondicional logo depois — uma falha real
# ficava indistinguível de sucesso no log e na linha-resumo.
setup ga-labelfail '["gate:needs-human"]' '' '' ''
touch "$TMP/fx.ga-labelfail/label_remove_fail"
OUT="$(run)"
if printf '%s' "$OUT" | grep -q "FALHA R1 ga-labelfail" \
   && printf '%s' "$OUT" | grep -q "0 destravadas sem humano"; then
  ok "blocking issue 1: bd label remove falhando → reportado como FALHA, não contado como destravada"
else
  bad "blocking issue 1: label remove falhando deveria reportar FALHA e não incrementar 'destravadas'" "$OUT"
fi

# ── blocking issue 1, pior sub-caso citado pelo revisor: strip_lock
# FUNCIONA (label removida de verdade) e note FALHA (zero rastro) ──────
setup ga-notefail '["gate:needs-human"]' '' '' ''
touch "$TMP/fx.ga-notefail/comment_fail"
OUT="$(run)"
if printf '%s' "$OUT" | grep -q "FALHA R1 ga-notefail" \
   && [ -s "$TMP/fx.ga-notefail/removed.log" ] \
   && printf '%s' "$OUT" | grep -q "0 destravadas sem humano"; then
  ok "blocking issue 1 (pior sub-caso): label REALMENTE removida + comentário falho → ainda reportado como FALHA, não como sucesso silencioso"
else
  bad "blocking issue 1: quando note falha após strip_lock ter sucesso, o script não pode alegar sucesso (mutação real sem rastro de auditoria)" \
    "OUT=$OUT REMOVED=$(cat "$TMP/fx.ga-notefail/removed.log" 2>/dev/null)"
fi

# ── achado D (2ª rodada adversarial): quando strip_lock FALHA, o
# COMENTÁRIO PERMANENTE no bead precisa dizer FALHA — não só o stdout do
# script. Reprodução do revisor: script dizia "FALHA" no log, mas o
# comentário gravado NO BEAD ainda afirmava "Labels de gate removidos...
# Nenhum humano precisou olhar" — o rastro de auditoria (o que sobrevive
# de verdade, o que um humano investigando o bead realmente lê) mentia.
setup ga-labelfail-note '["gate:needs-human"]' '' '' ''
touch "$TMP/fx.ga-labelfail-note/label_remove_fail"
run >/dev/null 2>&1
# ⚠️ auto-descoberto ao escrever este teste (não citado pelo revisor):
# uma PRIMEIRA versão do fix embutia o texto de SUCESSO inteiro dentro da
# mensagem de falha, como contexto ("Tentativa era: ..."). Isso incluía
# "Nenhum humano precisou olhar" — a MESMA frase que este teste checa a
# AUSÊNCIA — dentro de uma mensagem que É uma falha. Corrigido pra
# construir a mensagem de falha SEM nenhuma frase de outcome de sucesso.
if grep -q 'AUTO-DESTRAVE R1 FALHOU' "$TMP/fx.ga-labelfail-note/comments.log" 2>/dev/null \
   && ! grep -q 'Nenhum humano precisou olhar' "$TMP/fx.ga-labelfail-note/comments.log" 2>/dev/null; then
  ok "achado D: comentário PERMANENTE no bead diz FALHOU quando strip_lock falha, sem nenhuma frase de sucesso misturada"
else
  bad "achado D: o comentário gravado no bead precisa refletir a falha real, sem reusar frase de outcome de sucesso" \
    "$(cat "$TMP/fx.ga-labelfail-note/comments.log" 2>/dev/null)"
fi

# ── achados A/B (2ª rodada adversarial): bd show FALHANDO (não "bead
# sem labels", de verdade FALHANDO) não pode ser lido como "confirmei
# zero labels" em NENHUM consumidor — nem proteção, nem contagem de
# reprovações, nem remoção. Antes, labels_of() era rebuscado
# separadamente por lock_variant/has_protected_variant/strip_lock, sem
# cache, e uma falha intermitente entre essas chamadas podia fazer
# has_protected_variant aprovar um bead que strip_lock (numa chamada
# BEM-SUCEDIDA logo depois) via como tendo uma label protegida — e
# removia mesmo assim. Agora main() busca UMA vez via fetch_labels() e
# propaga; se a busca falhar, o bead inteiro é pulado, nunca tratado
# como "sem labels" ou "sem proteção". Fixture: bead com label PROTEGIDA
# (:refused) e bd show configurado pra FALHAR sempre.
setup ga-showfail '["gate:needs-human","gate:needs-human:refused"]' '' '' ''
touch "$TMP/fx.ga-showfail/show_fail.ga-showfail"
OUT="$(run)"
if printf '%s' "$OUT" | grep -q "SKIP ga-showfail.*bd show falhou" \
   && [ ! -s "$TMP/fx.ga-showfail/removed.log" ]; then
  ok "achados A/B: bd show falhando → bead inteiro pulado, label protegida NUNCA removida (elimina a corrida de rebusca separada)"
else
  bad "achados A/B: bd show falhando deveria pular o bead sem tocar nenhuma label, nunca tratar 'não consegui saber' como 'confirmei seguro'" \
    "OUT=$OUT REMOVED=$(cat "$TMP/fx.ga-showfail/removed.log" 2>/dev/null)"
fi

# ── self-audit final (mesma classe de A/B, achada por mim ao reler o
# arquivo inteiro antes de resubmeter, não pelo revisor): decide()'s
# PRÓPRIA busca de show_json (--include-comments, pra last_fail_epoch e
# verdict) não checava seu próprio código de saída — se falhasse, R5
# dizia "nenhum veredito FAIL encontrado" (que implica checagem
# bem-sucedida) quando na verdade a checagem nem rodou. Não-destrutivo
# (R5 nunca muta labels), mas é a mesma classe "não sei" virando "sei que
# não" que o revisor já cobrou 3x. Fixture: fetch_labels (chamada SEM
# --include-comments) funciona normal, mas a chamada COM
# --include-comments falha.
setup ga-showjsonfail '["gate:needs-human"]' 'origin/fix/ga-showjsonfail' '+ abc999' '1700000000'
touch "$TMP/fx.ga-showjsonfail/show_fail_with_comments.ga-showjsonfail"
OUT="$(run)"
if printf '%s' "$OUT" | grep -q "R5 ga-showjsonfail" \
   && printf '%s' "$OUT" | grep -q "não consegui checar\|checagem não RODOU\|não RODOU"; then
  ok "self-audit final: decide()'s show_json falhando → R5 diz 'não consegui checar', não finge que checou e não achou nada"
else
  bad "self-audit final: quando a própria busca de comments falha, a mensagem de R5 não pode alegar que checou e não achou veredito FAIL" "$OUT"
fi

# ── achado C (2ª rodada adversarial): cut -c é POR BYTE sob LC_ALL=C
# (confirmado ao vivo neste host) — corte no meio de um caractere UTF-8
# multi-byte (ç, ã, é) produz bytes inválidos que quebram QUALQUER
# leitura futura do bead via jq. Fixture: veredito longo o bastante pra
# cair EXATAMENTE no limite de 200 no meio de "çã".
# ⚠️ bash 3.2 (stock macOS) tem uma armadilha DESTE PRÓPRIO harness (não
# do script sob teste): passar um "$(...)" com chaves {..,..} DIRETO como
# argumento de comando (não numa atribuição VAR=) faz bash 3.2 aplicar
# BRACE EXPANSION mesmo dentro de aspas duplas aninhadas, partindo o JSON
# em DOIS comandos python3 separados. Atribuir a uma var PRIMEIRO evita.
LONG_VERDICT="VERDICT: FAIL tests/x.py $(python3 -c "print('a'*175)")çãXXXXXXXXXX"
UTF8_COMMENTS_JSON="$(python3 -c "import json,sys; print(json.dumps([{'created_at':'2026-08-15T10:00:00Z','text':sys.argv[1]}]))" "$LONG_VERDICT")"
setup ga-utf8 '["gate:needs-human"]' 'origin/fix/ga-utf8' '+ abc123' '1700000000' "$UTF8_COMMENTS_JSON"
OUT="$(LC_ALL=C run)"
if printf '%s' "$OUT" | python3 -c "
import sys
try:
    sys.stdin.buffer.read().decode('utf-8')
    print('VALID')
except UnicodeDecodeError:
    print('INVALID')
" | grep -q VALID; then
  ok "achado C: verdict_line truncado permanece UTF-8 válido mesmo cortando no meio de um caractere multi-byte"
else
  bad "achado C: cut -c1-200 sob LC_ALL=C corrompeu UTF-8 (corte no meio de ç/ã) — precisa de iconv -c" "$OUT"
fi

# ── flock: trava de instância única (revisor, gate-run ga-2ywzoo) ──────
# Precedente real desta cidade (ga-y0g5x): guard StartInterval SEM trava
# de instância única teve execuções empilhadas pelo launchd sob carga (4
# simultâneas medidas) e derrubou o bd/Dolt da cidade inteira. Prova de
# exclusão mútua DE VERDADE, não só leitura de código: um processo
# SEPARADO segura o MESMO arquivo de lock via flock antes do script
# rodar; o script tem que sair IMEDIATAMENTE, sem tocar em nenhum bead,
# nunca esperar o lock liberar.
LOCKTEST="$TMP/flocktest.lock"
READYFILE="$TMP/flocktest.ready"
rm -f "$READYFILE"
setup ga-lockheld '["gate:needs-human"]' '' '' ''
(
  exec 9>"$LOCKTEST"
  flock -n 9 || exit 1
  touch "$READYFILE"
  sleep 2
) &
HOLDER_PID=$!
# poll curto até o holder confirmar que pegou o lock — evita race de
# tempo fixo (sleep N) contra quando o subshell de fato adquire o flock.
for _i in $(seq 1 50); do [ -f "$READYFILE" ] && break; sleep 0.05; done
OUT="$(GC_CITY_PATH="$TMP" WA_RIG="$TMP" PS_RIG="$TMP" GATE_AUTO_UNBLOCK_LOG="$TMP/log" \
  GATE_AUTO_UNBLOCK_LOCK="$LOCKTEST" BD=bd GIT=git bash "$SCRIPT" 2>&1)"
wait "$HOLDER_PID" 2>/dev/null
if printf '%s' "$OUT" | grep -q "outra instância já rodando" \
   && [ ! -s "$TMP/fx.ga-lockheld/removed.log" ] && [ ! -s "$TMP/fx.ga-lockheld/comments.log" ]; then
  ok "flock: trava de instância única funciona de verdade — 2ª execução sai sem tocar nenhum bead (precedente ga-y0g5x)"
else
  bad "flock: com o lock já detido por outro processo, o script deveria sair imediatamente sem mutar nada" "$OUT"
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
  GATE_AUTO_UNBLOCK_LOG="$TMP/log" GATE_AUTO_UNBLOCK_LOCK="$TMP/gate-auto-unblock-dry.lock" \
  bash "$SCRIPT" >/dev/null 2>&1
if [ ! -s "$TMP/fx.ga-dry/removed.log" ] && [ ! -s "$TMP/fx.ga-dry/comments.log" ]; then
  ok "DRY_RUN=1 decide mas não muta nada"
else
  bad "DRY_RUN mutou" "$(cat "$TMP/fx.ga-dry/removed.log" "$TMP/fx.ga-dry/comments.log" 2>/dev/null)"
fi

echo
printf 'gate-auto-unblock selftest: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
