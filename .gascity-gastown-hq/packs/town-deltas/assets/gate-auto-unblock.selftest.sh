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
# ga-ck3sz7: o script roda num PATH SEM bd/gc reais (selftest-sandbox-path.lib.sh). Este script MUTA beads
# (bd label remove/update/comment); se $BIN sumisse debaixo dele enquanto roda, o `bd` REAL mais adiante no PATH
# receberia essas mutações. Aqui "command not found" é o único desfecho.
. "$HERE/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $HERE/selftest-sandbox-path.lib.sh" >&2; exit 2; }
sandbox_path_init "$TMP" jq flock || exit 2   # jq: label/comment parsing; flock: the single-instance lock
export PATH="$SANDBOX_PATH"

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
    # label_remove_fail.<label> (arquivo-gatilho, ga-fykclp): falha SÓ a remoção
    # dessa label, deixando as outras passarem — o caso em que o gate:needs-human*
    # sai e o next-action:mayor não (ou o inverso), que o gatilho global acima não
    # consegue distinguir.
    [ -f "$FX/label_remove_fail.${6:-}" ] && exit 1
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
    # git -C <rig> for-each-ref --format=... <pattern1> [<pattern2> ...]
    # Filtra branches.txt pelos padrões de path recebidos, como o git
    # real faria — sem filtrar, o shim devolve tudo sempre e não
    # consegue provar que o SUT pediu o namespace certo (ga-rdx5h:
    # branch_for não buscava refs/remotes/origin/feat/*, e um mock que
    # ignora os padrões mascararia esse bug pra sempre — qualquer teste
    # passaria com ou sem o fix).
    # for_each_ref_fail (arquivo-gatilho, ga-hi28wr): o git real sai !=0
    # (128 "not a git repository", lock, disco cheio) SEM listar nada — o
    # terceiro estado "não consegui olhar", distinto de "olhei e não há".
    [ -f "$FX/for_each_ref_fail" ] && exit 128
    shift 3
    patterns=()
    fmt="refname:short"
    for a in "$@"; do
      case "$a" in
        --format=%\(refname\)) fmt="refname" ;;
        --format=*) ;;
        *) patterns+=("$a") ;;
      esac
    done
    while IFS= read -r ln; do
      [ -n "$ln" ] || continue
      # branches.txt guarda refname:short ("origin/fix/…"); os padrões
      # recebidos são full ref path ("refs/remotes/origin/fix/*") — o
      # git real casa contra o nome INTEIRO da ref, não o short form.
      full="refs/remotes/$ln"
      for p in "${patterns[@]}"; do
        case "$full" in
          $p)
            # --format=%(refname) imprime a ref inteira; o default do shim
            # continua o short form, como o git real com refname:short.
            if [ "$fmt" = "refname" ]; then printf '%s\n' "$full"; else printf '%s\n' "$ln"; fi
            break ;;
        esac
      done
    done < "$FX/branches.txt" 2>/dev/null
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
  diff)
    # git -C <rig> diff origin/main...<branch> — a MEDIÇÃO do diff (ga-ph10ox5): diff.txt é o texto que o git devolveria.
    # diff_fail (arquivo-gatilho): o git real sai !=0 sem texto (lock, ref ou base ausente) e a lib engole o rc — o terceiro
    # estado "não consegui medir". Sem diff.txt o diff vem VAZIO, que a lib também lê como "não deu pra medir".
    [ -f "$FX/diff_fail" ] && exit 128
    # A FIAÇÃO também é conferida: o script tem que pedir a base E a ponta como refs de origin, com três pontos (merge-base..ponta).
    # Outra forma sai 128, como um git real diante de um nome que não existe.
    case "${@: -1}" in origin/main...origin/*) ;; *) exit 128 ;; esac
    cat "$FX/diff.txt" 2>/dev/null
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
if printf '%s' "$OUT1" | grep "R5 ga-r5loop.*escalado" >/dev/null \
   && printf '%s' "$OUT2" | grep -i "R5 ga-r5loop.*suprimid" >/dev/null \
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
if printf '%s' "$OUT1" | grep "FALHA R5 ga-r5notefail" >/dev/null \
   && printf '%s' "$OUT2" | grep "R5 ga-r5notefail.*escalado" >/dev/null \
   && printf '%s' "$OUT2" | grep 'tentativa #1' >/dev/null \
   && [ "$R5_COMMENTS3" -eq 1 ]; then
  ok "blocking issue 1 (ga-woesw): note() falhando NÃO consome o cooldown — retenta e escala na próxima varredura, ainda na tentativa #1"
else
  bad "blocking issue 1 (ga-woesw): quando bd comment falha, should_alert_r5 não pode ter gravado o stamp — a próxima varredura tem que RETENTAR (não suprimir achando que já escalou)" \
    "OUT1=$OUT1 OUT2=$OUT2 R5_COMMENTS3=$R5_COMMENTS3 COMMENTS=$(cat "$TMP/fx.ga-r5notefail/comments.log" 2>/dev/null)"
fi

# ── ga-dv2gk: R4 sem memória de estado reescalona indefinidamente (mesma
# classe de ga-9e0j8, agora em R4, não só R5) ───────────────────────────
# Caso real: wa-klhib, 6 ciclos de strip+comentário em 8h, ZERO commit
# novo — o portão reaplicava gate:needs-human entre varreduras e R4
# (fails só CRESCE, nunca prova trabalho novo) reagia de novo a cada
# 20min sobre o MESMO estado. Mede por ARQUIVO, não por texto de OUT: o
# harness varre a MESMA fixture 3x por chamada de run() (GC_CITY_PATH/
# WA_RIG/PS_RIG apontam pro mesmo $TMP — mesmo aviso do teste de
# recontagem do R5 acima), então mesmo a 1ª chamada de run() já mistura
# 1 ação real + 2 supressões no próprio OUT — só a contagem em arquivo
# separa "agiu 1x" de "agiu a cada passada". Sem veredito FAIL na
# fixture, de propósito: mantém R2/R3 fora do caminho, isolando só o
# comportamento de R4.
setup ga-dv2gkloop '["gate:needs-human","gate-sha-failed:a:code","gate-sha-failed:b:code","gate-sha-failed:c:code"]' \
  'origin/fix/ga-dv2gkloop' '+ cafefeed' '1700000000'
run >/dev/null 2>&1   # 1ª varredura: 3 passes internos, só o 1º deveria agir de verdade
run >/dev/null 2>&1   # 2ª varredura: MESMO tip — as 3 passes deveriam suprimir
R4_COMMENTS="$(grep -c 'AUTO-DESTRAVE R4' "$TMP/fx.ga-dv2gkloop/comments.log" 2>/dev/null || echo 0)"
R4_REMOVED="$(wc -l < "$TMP/fx.ga-dv2gkloop/removed.log" 2>/dev/null | tr -d ' ')"
if [ "$R4_COMMENTS" -eq 1 ] && [ "${R4_REMOVED:-0}" -eq 1 ]; then
  ok "ga-dv2gk: R4 age 1x só por estado de branch — 2 varreduras (6 passes internos) produzem 1 strip + 1 comentário, não 6 (era o bug real: wa-klhib, 6 ciclos em 8h sem avanço)"
else
  bad "ga-dv2gk: R4 deveria agir 1x por tip de branch, não repetir strip+comentário a cada varredura sem commit novo" \
    "R4_COMMENTS=$R4_COMMENTS R4_REMOVED=$R4_REMOVED REMOVED=$(cat "$TMP/fx.ga-dv2gkloop/removed.log" 2>/dev/null) COMMENTS=$(cat "$TMP/fx.ga-dv2gkloop/comments.log" 2>/dev/null)"
fi

# ── ga-dv2gk: commit novo (tip muda) reabilita R4 — suprimir não pode
# virar "nunca mais" ─────────────────────────────────────────────────
printf '1700000999\n' > "$TMP/fx.ga-dv2gkloop/tip_epoch.txt"
run >/dev/null 2>&1
R4_COMMENTS2="$(grep -c 'AUTO-DESTRAVE R4' "$TMP/fx.ga-dv2gkloop/comments.log" 2>/dev/null || echo 0)"
if [ "$R4_COMMENTS2" -eq 2 ]; then
  ok "ga-dv2gk: branch com commit novo reabilita R4 (2º estado distinto → 2ª ação real, supressão não é permanente)"
else
  bad "ga-dv2gk: depois de um commit novo (tip mudou), R4 deveria poder agir de novo" \
    "R4_COMMENTS2=$R4_COMMENTS2 COMMENTS=$(cat "$TMP/fx.ga-dv2gkloop/comments.log" 2>/dev/null)"
fi

# ── ga-dv2gk: note() falhando NÃO pode marcar R4 como já-agido (mesmo
# idioma do blocking issue 1 do R5 acima, ga-woesw, agora para R4) ──────
# Se mark_r4_acted gravasse o stamp incondicionalmente (ou strip_lock
# sozinho bastasse), uma falha real de bd comment deixaria o bead
# permanentemente "escalado" no registro deste script sem nunca ter
# postado nada nele — silêncio disfarçado de sucesso.
setup ga-dv2gknotefail '["gate:needs-human","gate-sha-failed:a:code","gate-sha-failed:b:code","gate-sha-failed:c:code"]' \
  'origin/fix/ga-dv2gknotefail' '+ deadbee0' '1700000000'
touch "$TMP/fx.ga-dv2gknotefail/comment_fail"
run >/dev/null 2>&1
rm -f "$TMP/fx.ga-dv2gknotefail/comment_fail"
run >/dev/null 2>&1
R4_COMMENTS3="$(grep -c 'AUTO-DESTRAVE R4' "$TMP/fx.ga-dv2gknotefail/comments.log" 2>/dev/null || echo 0)"
if [ "$R4_COMMENTS3" -eq 1 ]; then
  ok "ga-dv2gk: note() falhando não marca R4 como já-agido — próxima varredura retenta e escala de verdade (mesmo idioma do ga-woesw)"
else
  bad "ga-dv2gk: quando bd comment falha, mark_r4_acted não pode ter gravado o stamp — a próxima varredura tem que RETENTAR, não suprimir achando que já agiu" \
    "R4_COMMENTS3=$R4_COMMENTS3 COMMENTS=$(cat "$TMP/fx.ga-dv2gknotefail/comments.log" 2>/dev/null)"
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

# ── ga-rdx5h: branch_for ignora refs/remotes/origin/feat/* ─────────────
# Caso real (ga-06mt3k, branch feat/ga-06mt3k-capacity-hierarchy): o
# glob de for-each-ref só busca 'crew/*/*' e 'fix/*' — 'feat/*' (o
# prefixo OBRIGATÓRIO pra branch de story/feature nesta cidade, exigido
# pelo push guard) nunca é considerado. branch_for() devolve vazio
# mesmo com a branch existindo com commits reais, R1 dispara
# "sem branch no remoto e sem commit próprio", e apply_and_report
# remove o gate:needs-human de verdade — silenciosamente derrotando o
# circuit breaker (ga-stu930) pra toda uma classe de branch.
setup ga-06mt3k '["gate:needs-human"]' \
  'origin/feat/ga-06mt3k-capacity-hierarchy' '+ 173b5ffc5' '1755000000'
OUT="$(run)"
case "$OUT" in
  *"R1 ga-06mt3k"*)
    bad "ga-rdx5h: branch feat/* com trabalho único foi lida como órfã (R1) — branch_for não busca refs/remotes/origin/feat/*, derrotando o circuit breaker" "$OUT";;
  *"ga-06mt3k"*"feat/ga-06mt3k-capacity-hierarchy"*)
    ok "ga-rdx5h: branch feat/* agora é resolvida por branch_for — não vira mais órfão falso (ga-06mt3k, evidência ao vivo do bug)";;
  *) bad "ga-rdx5h: resultado inesperado para branch feat/*" "$OUT";;
esac

# ── ga-hi28wr: branch_for tinha a PRÓPRIA lista de namespaces ──────────
# ga-rdx5h consertou a INSTÂNCIA (uma linha a mais, feat/*) e a lacuna voltou
# nos outros cinco prefixos que a lista única (delivery-branch-patterns.sh,
# ga-x7m5rg) já conhece: feature/ refactor/ docs/ chore/ test/. Bead entregue
# numa dessas fazia branch_for() devolver vazio → R1 → gate:needs-human
# REMOVIDO de verdade. O conserto é de CLASSE: a lista vem da lib, e este
# teste percorre a lib (não uma cópia dos prefixos) — prefixo novo na lib
# entra aqui sozinho. Cada caso afere o EFEITO (nenhum label removido), não só
# o texto da saída.
LIB_PREFIXES="$(. "$HERE/delivery-branch-patterns.sh" && printf '%s' "$GC_DELIVERY_BRANCH_PREFIXES")"
n=0
for pfx in $LIB_PREFIXES; do
  n=$((n+1)); id="ga-hb$n"
  setup "$id" '["gate:needs-human"]' "origin/$pfx/$id-slug" '+ 173b5ffc5' '1755000000'
  OUT="$(run)"
  if [ -s "$TMP/fx.$id/removed.log" ] || case "$OUT" in *"R1 $id"*) true;; *) false;; esac; then
    bad "ga-hi28wr: branch $pfx/$id-slug com trabalho único foi lida como órfã (R1) — branch_for não enxerga o namespace $pfx/ e o gate:needs-human foi removido" "$OUT | removed: $(cat "$TMP/fx.$id/removed.log")"
  else
    case "$OUT" in
      *"$id"*"$pfx/$id-slug"*) ok "ga-hi28wr: $pfx/<id>-slug resolve em branch_for e preserva o gate:needs-human";;
      *) bad "ga-hi28wr: resultado inesperado para $pfx/$id-slug" "$OUT";;
    esac
  fi
done
# A forma SEM slug (<prefix>/<id> pelado) é um glob separado na lib (ga-r7uec).
for pfx in refactor docs; do
  id="ga-hbb-$pfx"
  setup "$id" '["gate:needs-human"]' "origin/$pfx/$id" '+ 173b5ffc5' '1755000000'
  OUT="$(run)"
  if [ -s "$TMP/fx.$id/removed.log" ] || case "$OUT" in *"R1 $id"*) true;; *) false;; esac; then
    bad "ga-hi28wr: branch $pfx/$id (sem slug) lida como órfã — gate:needs-human removido" "$OUT | removed: $(cat "$TMP/fx.$id/removed.log")"
  else
    ok "ga-hi28wr: $pfx/<id> pelado (sem slug) também resolve em branch_for"
  fi
done

# A escolha entre namespaces continua sendo o commit TIP mais recente (revisor
# ga-oaqy39, blocking issue 2) — a lib só decide QUAIS refs são candidatas. A
# prioridade da lib é "fix/ primeiro"; se alguém trocasse a escolha por ela,
# a fix/ ANTIGA e sem trabalho único (dispararia R1 destrutivo) ganharia da
# refactor/ NOVA com trabalho de verdade.
setup ga-hbmix '["gate:needs-human"]' \
  "$(printf 'origin/fix/ga-hbmix-old\norigin/refactor/ga-hbmix-new')" '' ''
echo '-' > "$TMP/fx.ga-hbmix/cherry.origin_fix_ga-hbmix-old.txt"
echo '1000000000' > "$TMP/fx.ga-hbmix/tip_epoch.origin_fix_ga-hbmix-old.txt"
echo '+ abcdef01' > "$TMP/fx.ga-hbmix/cherry.origin_refactor_ga-hbmix-new.txt"
echo '1900000000' > "$TMP/fx.ga-hbmix/tip_epoch.origin_refactor_ga-hbmix-new.txt"
OUT="$(run)"
case "$OUT" in
  *"R5 ga-hbmix"*"origin/refactor/ga-hbmix-new"*)
    ok "ga-hi28wr: entre namespaces vale o tip mais recente (refactor/ novo), não a prioridade fix/-primeiro da lib";;
  *"R1 ga-hbmix"*)
    bad "ga-hi28wr: escolheu a fix/ ANTIGA por prioridade de prefixo e disparou R1 — a refactor/ real ficaria sem lock e sem exame" "$OUT";;
  *) bad "ga-hi28wr: resultado inesperado na escolha entre namespaces" "$OUT";;
esac

# Id MAIS LONGO que apenas começa com o id do bead não é a entrega dele.
setup ga-hbd1 '["gate:needs-human"]' \
  "$(printf 'origin/refactor/ga-hbd12\norigin/docs/ga-hbd1x-foo')" '+ 173b5ffc5' '1755000000'
OUT="$(run)"
case "$OUT" in
  *"R1 ga-hbd1 "*) ok "ga-hi28wr: refs de OUTRO bead (id mais longo com o mesmo começo) não contam como entrega — segue R1 genuíno";;
  *) bad "ga-hi28wr: ref de bead diferente foi tomada como entrega de ga-hbd1" "$OUT";;
esac

# Terceiro estado: o git NÃO conseguiu listar as refs (128, lock, disco). Isso
# não é "olhei e não há branch" — e R1 APAGA o label de verdade. Tem que cair no
# mesmo estado que has_own_work usa para "não sei" (R5), sem remover nada.
setup ga-hbfail '["gate:needs-human"]' 'origin/refactor/ga-hbfail-x' '+ 173b5ffc5' '1755000000'
: > "$TMP/fx.ga-hbfail/for_each_ref_fail"
OUT="$(run)"
if [ -s "$TMP/fx.ga-hbfail/removed.log" ] || case "$OUT" in *"R1 ga-hbfail"*) true;; *) false;; esac; then
  bad "ga-hi28wr: for-each-ref FALHOU e foi lido como 'sem branch' (R1) — gate:needs-human removido sobre dado que nunca foi lido" "$OUT | removed: $(cat "$TMP/fx.ga-hbfail/removed.log")"
else
  case "$OUT" in
    *"R5 ga-hbfail"*) ok "ga-hi28wr: for-each-ref falhando escala via R5 ('não sei'), não vira R1 (falso órfão)";;
    *) bad "ga-hi28wr: for-each-ref falhando deveria cair em R5" "$OUT";;
  esac
fi

# Lib compartilhada ausente/ilegível = falha de DEPLOY, não evidência de que não
# há branch: sem ela nenhuma regra R1-R4 tem base. O script para ALTO (rc != 0,
# visível no launchctl list) e não toca em bead nenhum.
mkdir -p "$TMP/nolib"; cp "$SCRIPT" "$TMP/nolib/gate-auto-unblock.sh"
setup ga-hbnolib '["gate:needs-human"]' 'origin/refactor/ga-hbnolib-x' '+ 173b5ffc5' '1755000000'
OUT="$(GC_CITY_PATH="$TMP" WA_RIG="$TMP" PS_RIG="$TMP" \
  GATE_AUTO_UNBLOCK_LOG="$TMP/log" GATE_AUTO_UNBLOCK_LOCK="$TMP/gate-auto-unblock-nolib.lock" \
  BD=bd GIT=git bash "$TMP/nolib/gate-auto-unblock.sh" 2>&1)"; NOLIB_RC=$?
if [ "$NOLIB_RC" -ne 0 ] && ! [ -s "$TMP/fx.ga-hbnolib/removed.log" ] \
   && case "$OUT" in *"delivery-branch-patterns.sh"*) true;; *) false;; esac \
   && case "$OUT" in *"R1 ga-hbnolib"*) false;; *) true;; esac; then
  ok "ga-hi28wr: sem delivery-branch-patterns.sh o script para ALTO (rc=$NOLIB_RC), nomeia a lib e não toca em bead (falha de deploy ≠ 'sem branch')"
else
  bad "ga-hi28wr: lib ausente deveria parar com rc != 0, nomear a lib e não mutar nada (rc=$NOLIB_RC)" "$OUT | removed: $(cat "$TMP/fx.ga-hbnolib/removed.log" 2>/dev/null)"
fi

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
OUT="$(PATH="$FAKE_DATE_BIN:$SANDBOX_PATH" run)"
case "$OUT" in *"R5 ga-xt8zrf-gnu"*"nenhum veredito FAIL"*)
    ok "armadilha D sobrevive em host com GNU date (last_fail_epoch não vira 'agora' quando \$d vazio)";;
  *) bad "em host GNU-date, last_fail_epoch viraria 'agora' e a mensagem mudaria para 'sem commit apos a reprovacao'" "$OUT";; esac

# ── VARIANTES: as três que este script NÃO pode tocar ──────────────────
for v in gate:needs-human:product gate:needs-human:on-device gate:needs-human:refused; do
  setup ga-var "[\"$v\"]" '' '' ''
  OUT="$(run)"
  if printf '%s' "$OUT" | grep "SKIP ga-var" >/dev/null; then
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
if printf '%s' "$OUT" | grep "SKIP ga-mixed" >/dev/null && [ ! -s "$TMP/fx.ga-mixed/removed.log" ]; then
  ok "armadilha E: variante protegida co-presente com unblockable → SKIP, nenhuma label tocada (ga-5l5v76)"
else
  bad "armadilha E: deveria pular o bead inteiro sem remover nenhuma label" \
    "OUT=$OUT REMOVED=$(cat "$TMP/fx.ga-mixed/removed.log" 2>/dev/null)"
fi

# ── ga-m8u5or: bead de descoberta de fonte NASCE parada, não é trava órfã ─
# source_discovery.py cria "[fonte] Avaliar scraper" com
# gate:needs-human,discovery:source,scraper:build — de propósito, para esperar
# o sign-off do Athos. Nunca teve branch nem commit, então R1 lia "sem
# trabalho" como trava órfã e, ~70s depois do nascimento (04/10 15:03:40,
# ga-t7js0e/ga-5wq3hj/ga-mpfnaf), tirava o gate:needs-human: a bead voltava
# "à fila" e o resto da máquina (auto-refino, armar, repor rota) passava a
# tratá-la como trabalho comum. Repro exato: sem branch, label genérica.
setup ga-disc '["gate:needs-human","discovery:source","scraper:build","parent:ga-jazy9"]' '' '' ''
OUT="$(run)"
if printf '%s' "$OUT" | grep "SKIP ga-disc" >/dev/null \
   && ! printf '%s' "$OUT" | grep -E "R[1-5] ga-disc" >/dev/null \
   && [ ! -s "$TMP/fx.ga-disc/removed.log" ] && [ ! -s "$TMP/fx.ga-disc/comments.log" ]; then
  ok "ga-m8u5or: discovery:source sem branch → SKIP, gate:needs-human intacto, nenhum comentário"
else
  bad "ga-m8u5or: bead discovery:source parada de propósito foi tratada como trava órfã" \
    "OUT=$OUT REMOVED=$(cat "$TMP/fx.ga-disc/removed.log" 2>/dev/null) COMMENTS=$(cat "$TMP/fx.ga-disc/comments.log" 2>/dev/null)"
fi

# ── ga-m8u5or (gate fix-attempt 1): o estacionamento acaba no sign-off ──
# discovery:source é PROVENIÊNCIA permanente — continua na bead depois da
# aprovação. A exceção só se justifica ("até o sign-off do Athos") enquanto
# story:approved está AUSENTE; com ele presente a bead é trabalho comum e
# volta ao caminho R1-R5. O teste acima só fixa o lado pré-aprovação; os
# quatro abaixo fixam o outro lado da fronteira (e a ordem frente às
# escalações), que o predicado largo demais deixava passar:
#  (a) aprovada + sem branch → R1 libera a trava velha (o fluxo aprovar→
#      construir). Antes: SKIP "até o sign-off" DEPOIS do sign-off, trava
#      eterna até alguém tirar gate:needs-human à mão.
#  (b) aprovada + cap de gate:fix-attempt esgotado → R5 (chamar humano).
#  (c) aprovada + construída + 3 reprovações → R4 (escala de escopo).
#  (d) AINDA SEM aprovação mas com evidência de escalação (cap / reclaim) →
#      R5, não SKIP: bead "parada de propósito" nunca deveria ter sido
#      despachada, então essa evidência é "um humano precisa olhar", e o
#      estacionamento não pode silenciá-la.
setup ga-appr '["gate:needs-human","discovery:source","scraper:build","parent:ga-jazy9","story:approved"]' '' '' ''
OUT="$(run)"
if printf '%s' "$OUT" | grep "R1 ga-appr" >/dev/null \
   && ! printf '%s' "$OUT" | grep "SKIP ga-appr" >/dev/null \
   && [ -s "$TMP/fx.ga-appr/removed.log" ]; then
  ok "ga-m8u5or: discovery:source + story:approved + sem branch → R1 libera a trava (sign-off dado, estacionamento acabou)"
else
  bad "ga-m8u5or: bead discovery:source JÁ APROVADA continua travada com a log 'até o sign-off' — o predicado não olha story:approved" \
    "OUT=$OUT REMOVED=$(cat "$TMP/fx.ga-appr/removed.log" 2>/dev/null)"
fi

setup ga-apprcap '["gate:needs-human","discovery:source","scraper:build","story:approved","gate:fix-attempt:3"]' \
  'origin/fix/ga-apprcap-scraper' '+ b40be47f' '1700000000' ''
OUT="$(run)"
if printf '%s' "$OUT" | grep "R5 ga-apprcap" >/dev/null \
   && ! printf '%s' "$OUT" | grep -E "SKIP ga-apprcap|R[1-4] ga-apprcap" >/dev/null \
   && [ ! -s "$TMP/fx.ga-apprcap/removed.log" ]; then
  ok "ga-m8u5or: discovery:source + story:approved + gate:fix-attempt:3 → R5 (chamar humano), não SKIP silencioso"
else
  bad "ga-m8u5or: a escalação R5 de cap-esgotado sumiu para bead discovery:source aprovada (SKIP engoliu o 'um humano precisa olhar')" \
    "OUT=$OUT REMOVED=$(cat "$TMP/fx.ga-apprcap/removed.log" 2>/dev/null)"
fi

setup ga-apprr4 '["gate:needs-human","discovery:source","scraper:build","story:approved","gate-sha-failed:a:code","gate-sha-failed:b:code","gate-sha-failed:c:code"]' \
  'origin/fix/ga-apprr4-scraper' '+ b40be47f' '1700000000' \
  '[{"created_at":"2026-08-15T10:00:00Z","text":"VERDICT: FAIL em lib/x.py"}]'
OUT="$(run)"
if printf '%s' "$OUT" | grep "R4 ga-apprr4" >/dev/null \
   && ! printf '%s' "$OUT" | grep "SKIP ga-apprr4" >/dev/null; then
  ok "ga-m8u5or: discovery:source + story:approved + construída + 3 reprovações → R4 (escala de escopo), não SKIP"
else
  bad "ga-m8u5or: R2-R4 ficaram mortas para bead discovery:source aprovada e construída (controle sem discovery:source dá R4)" \
    "OUT=$OUT REMOVED=$(cat "$TMP/fx.ga-apprr4/removed.log" 2>/dev/null)"
fi

setup ga-parkcap '["gate:needs-human","discovery:source","scraper:build","gate:fix-attempt:3"]' \
  'origin/fix/ga-parkcap-scraper' '+ b40be47f' '1700000000' ''
OUT="$(run)"
if printf '%s' "$OUT" | grep "R5 ga-parkcap" >/dev/null \
   && ! printf '%s' "$OUT" | grep "SKIP ga-parkcap" >/dev/null \
   && [ ! -s "$TMP/fx.ga-parkcap/removed.log" ]; then
  ok "ga-m8u5or: discovery:source SEM aprovação + gate:fix-attempt:3 → R5 — o estacionamento não silencia a escalação de cap"
else
  bad "ga-m8u5or: a checagem de estacionamento vem ANTES de has_fix_attempt_cap_escalation e engole o R5 (cap esgotado, sem aprovação)" \
    "OUT=$OUT REMOVED=$(cat "$TMP/fx.ga-parkcap/removed.log" 2>/dev/null)"
fi

setup ga-parkrecl '["gate:needs-human","discovery:source","scraper:build","pilot:reclaim-count:escalated-at-3"]' '' '' ''
OUT="$(run)"
if printf '%s' "$OUT" | grep "R5 ga-parkrecl" >/dev/null \
   && ! printf '%s' "$OUT" | grep "SKIP ga-parkrecl" >/dev/null \
   && [ ! -s "$TMP/fx.ga-parkrecl/removed.log" ]; then
  ok "ga-m8u5or: discovery:source SEM aprovação + pilot:reclaim-count:escalated-at-* → R5 — o estacionamento não silencia a escalação de reclaim"
else
  bad "ga-m8u5or: a checagem de estacionamento vem ANTES de has_reclaim_escalation e engole o R5 (reclaim esgotado, sem aprovação)" \
    "OUT=$OUT REMOVED=$(cat "$TMP/fx.ga-parkrecl/removed.log" 2>/dev/null)"
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
if printf '%s' "$OUT" | grep "FALHA R1 ga-labelfail" >/dev/null \
   && printf '%s' "$OUT" | grep "0 destravadas sem humano" >/dev/null; then
  ok "blocking issue 1: bd label remove falhando → reportado como FALHA, não contado como destravada"
else
  bad "blocking issue 1: label remove falhando deveria reportar FALHA e não incrementar 'destravadas'" "$OUT"
fi

# ── blocking issue 1, pior sub-caso citado pelo revisor: strip_lock
# FUNCIONA (label removida de verdade) e note FALHA (zero rastro) ──────
setup ga-notefail '["gate:needs-human"]' '' '' ''
touch "$TMP/fx.ga-notefail/comment_fail"
OUT="$(run)"
if printf '%s' "$OUT" | grep "FALHA R1 ga-notefail" >/dev/null \
   && [ -s "$TMP/fx.ga-notefail/removed.log" ] \
   && printf '%s' "$OUT" | grep "0 destravadas sem humano" >/dev/null; then
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
if printf '%s' "$OUT" | grep "SKIP ga-showfail.*bd show falhou" >/dev/null \
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
if printf '%s' "$OUT" | grep "R5 ga-showjsonfail" >/dev/null \
   && printf '%s' "$OUT" | grep "não consegui checar\|checagem não RODOU\|não RODOU" >/dev/null; then
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
" | grep VALID >/dev/null; then
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
if printf '%s' "$OUT" | grep "outra instância já rodando" >/dev/null \
   && [ ! -s "$TMP/fx.ga-lockheld/removed.log" ] && [ ! -s "$TMP/fx.ga-lockheld/comments.log" ]; then
  ok "flock: trava de instância única funciona de verdade — 2ª execução sai sem tocar nenhum bead (precedente ga-y0g5x)"
else
  bad "flock: com o lock já detido por outro processo, o script deveria sair imediatamente sem mutar nada" "$OUT"
fi

# ── ga-18uhg0 (Mayor triage, Opção B): pilot:reclaim-count:escalated-at-*
# pula R1-R4 incondicionalmente, mesmo no caso mais óbvio de R1 (sem
# branch, sem commit) ───────────────────────────────────────────────────
# R1 e a escalação de reclaim-cap leem a MESMA evidência ("sem branch,
# sem commit") de jeitos OPOSTOS: R1 vê trava órfã e solta; a escalação
# viu isso como o motivo de chamar um humano. Sem a checagem, R1
# desfazia a escalação bem no bead em que ela mais importa. Caso real
# medido: wa-v6k32 (12/09, ~02:13–07:36) — 4x despachado, 0 commits,
# reclaim-cap esgotado às 06:09, R1 destravou às 06:21 sem nenhum humano
# olhar, Pilot reabriu o ciclo às 07:36.
setup wa-v6k32 '["gate:needs-human","pilot:reclaim-count:escalated-at-3"]' '' '' ''
OUT="$(run)"
if printf '%s' "$OUT" | grep "R5 wa-v6k32" >/dev/null \
   && ! printf '%s' "$OUT" | grep -E "R[1-4] wa-v6k32" >/dev/null \
   && [ ! -s "$TMP/fx.wa-v6k32/removed.log" ]; then
  ok "ga-18uhg0: reclaim-cap esgotado + sem branch/commit → força R5 (chamar humano), não R1 (trava órfã) — wa-v6k32 ao vivo"
else
  bad "ga-18uhg0: um bead com reclaim-cap esgotado e sem branch deveria escalar (R5), não ser lido como trava órfã e destravado (R1) — reabre o ciclo despacho↔reclaim↔escalação" \
    "OUT=$OUT REMOVED=$(cat "$TMP/fx.wa-v6k32/removed.log" 2>/dev/null)"
fi

# ── ga-18uhg0: o mesmo guard vence mesmo quando decide() teria dado R3
# (trabalho delimitado) — prova que é "R1-R4 incondicionalmente", não só
# um desvio do caso R1 sem-branch ───────────────────────────────────────
# Mesma fixture do teste R3 (wa-uknuq) acima — branch com trabalho único
# real + veredito nomeando um arquivo — mas com o label de reclaim-cap
# escalado também presente. Sem o guard, decide() chegaria em R3 (não
# R1); com o guard, nem R3 pode decidir por este bead.
setup wa-reclaimr3 '["gate:needs-human","pilot:reclaim-count:escalated-at-2","gate-sha-failed:a:code"]' \
  'origin/crew/mila/wa-reclaimr3-r3' '+ eaf78abb' '1700000000' \
  '[{"created_at":"2026-08-15T10:00:00Z","text":"VERDICT: FAIL tests/test_pregao.py precisa da chave nova"}]'
OUT="$(run)"
if printf '%s' "$OUT" | grep "R5 wa-reclaimr3" >/dev/null \
   && ! printf '%s' "$OUT" | grep -E "R[1-4] wa-reclaimr3" >/dev/null \
   && [ ! -s "$TMP/fx.wa-reclaimr3/removed.log" ]; then
  ok "ga-18uhg0: reclaim-cap escalado vence mesmo quando branch+veredito dariam R3 — nenhuma de R1-R4 decide por este bead"
else
  bad "ga-18uhg0: mesmo com branch e veredito nomeando arquivo (que normalmente dá R3), um bead com reclaim-cap escalado deveria forçar R5, não R3" \
    "OUT=$OUT REMOVED=$(cat "$TMP/fx.wa-reclaimr3/removed.log" 2>/dev/null)"
fi

# ── ga-3pkhtc: gate:fix-attempt cap esgotado (quality-gate-dispatcher.sh,
# GATE_FIX_CAP=3) é a MESMA classe de blind spot que ga-18uhg0 já corrigiu
# para o cap de reclaim — mas para o cap IRMÃO, e este nunca ganhou o
# guard equivalente. Caso real: uma escalação de cap (gate:needs-human +
# gate:needs-human:technical) foi aplicada e VERIFICADA por
# gate_apply_needs_human() (ga-55syh) — a mensagem "verified applied"
# estava correta no momento em que foi escrita — mas a bead não tinha
# commit novo ainda (típico logo após a 3ª reprovação), então R1 leu
# "sem trabalho novo" como trava órfã e removeu o label ~20min depois
# (StartInterval do gate-auto-unblock.plist), sem NUNCA olhar
# gate:fix-attempt:N. O freio de 3 tentativas virou letra morta: bastava
# esperar a próxima varredura. Mesma fixture do teste R1 sem-branch
# (ga-ih4ma) acima, mas com gate:fix-attempt:3 (cap) também presente.
setup ga-3pkhtc '["gate:needs-human","gate:needs-human:technical","gate:fix-attempt:3"]' '' '' ''
OUT="$(run)"
if printf '%s' "$OUT" | grep "R5 ga-3pkhtc" >/dev/null \
   && ! printf '%s' "$OUT" | grep -E "R[1-4] ga-3pkhtc" >/dev/null \
   && [ ! -s "$TMP/fx.ga-3pkhtc/removed.log" ]; then
  ok "ga-3pkhtc: gate:fix-attempt:3 (cap) + sem branch/commit → força R5 (chamar humano), não R1 (trava órfã) — o mesmo bug do ga-18uhg0, cap irmão"
else
  bad "ga-3pkhtc: bead com gate:fix-attempt no cap deveria escalar (R5), não ser lida como trava órfã e destravada (R1) — reabre o ciclo despacho→reprovação→auto-limpeza" \
    "OUT=$OUT REMOVED=$(cat "$TMP/fx.ga-3pkhtc/removed.log" 2>/dev/null)"
fi

# ── ga-3pkhtc: o mesmo guard vence mesmo quando decide() teria dado R4
# (3+ gate-sha-failed:*, branch com trabalho único) — prova "R1-R4
# incondicionalmente", não só um desvio do caso R1 sem-branch. Este é o
# caminho que a investigação ao vivo apontou como o mais provável: um
# bead cap-esgotado quase sempre também carrega 3+ gate-sha-failed:*
# (mesma reprovação repetida conta pros dois contadores independentes).
setup wa-fixattemptr4 '["gate:needs-human","gate:needs-human:technical","gate:fix-attempt:3","gate-sha-failed:a:code","gate-sha-failed:b:code","gate-sha-failed:c:code"]' \
  'origin/crew/mila/wa-fixattemptr4' '+ b40be47f' '1700000000' \
  '[{"created_at":"2026-08-15T10:00:00Z","text":"VERDICT: FAIL em lib/x.py"}]'
OUT="$(run)"
if printf '%s' "$OUT" | grep "R5 wa-fixattemptr4" >/dev/null \
   && ! printf '%s' "$OUT" | grep -E "R[1-4] wa-fixattemptr4" >/dev/null \
   && [ ! -s "$TMP/fx.wa-fixattemptr4/removed.log" ]; then
  ok "ga-3pkhtc: gate:fix-attempt:3 vence mesmo quando 3+ gate-sha-failed:* dariam R4 — nenhuma de R1-R4 decide por este bead"
else
  bad "ga-3pkhtc: mesmo com branch+trabalho+3 gate-sha-failed:* (que normalmente dá R4 — 'escala de ESCOPO, redespacha com teste estrutural'), um bead com gate:fix-attempt no cap deveria forçar R5, não R4 — R4 auto-redespacharia exatamente o que o circuit-breaker foi desenhado pra impedir" \
    "OUT=$OUT REMOVED=$(cat "$TMP/fx.wa-fixattemptr4/removed.log" 2>/dev/null)"
fi

# ── ga-3pkhtc: reset sentinel (gate:fix-attempt:0) — um reset HUMANO
# deliberado precisa continuar liberando R1-R4, mesmo com um
# gate:fix-attempt:N>=cap remanescente (resíduo de bump automático, não
# tocado pelo reset — ga-26df, mesmo arquivo). Sem isto, o guard novo
# criaria o bug ESPELHO: um bead genuinamente resetado ficaria invisível
# a R1-R4 PRA SEMPRE, nunca mais destravável automaticamente.
setup ga-3pkhtc-reset '["gate:needs-human","gate:fix-attempt:0","gate:fix-attempt:3"]' '' '' ''
OUT="$(run)"
if printf '%s' "$OUT" | grep "R1 ga-3pkhtc-reset" >/dev/null; then
  ok "ga-3pkhtc: gate:fix-attempt:0 (reset humano) vence um :3 remanescente — R1-R4 voltam a decidir normalmente (ga-26df, mesma semântica que quality-gate-dispatcher.sh já usa pro próprio contador)"
else
  bad "ga-3pkhtc: gate:fix-attempt:0 deveria sinalizar reset humano e liberar R1-R4 de novo, mesmo com um :3 remanescente coexistindo" "$OUT"
fi

# ── ga-fykclp: next-action:mayor deixado junto da trava ─────────────────
# O approved-state-reconciler (ga-gm5rv5) estaciona bead técnico com
# next-action:mayor + "Pergunta:" e MANTÉM gate:needs-human*. Quando este
# script tirava só o gate, o next-action:mayor ficava e o veto do Pilot
# (next-action:* sem verbo de build) continuava — o bead "destravado" não
# voltava pra fila e nada acusava.

# (1) caso base: coexistiu com o gate → sai junto, e ANTES do gate (a varredura
# lista por gate:needs-human*; se o gate saísse primeiro e este falhasse, o
# bead sairia do escopo da varredura com o veto preso pra sempre).
setup ga-fykclp-ok '["gate:needs-human","next-action:mayor"]' '' '' ''
OUT="$(run)"
RL="$TMP/fx.ga-fykclp-ok/removed.log"
NA_LN="$(grep -n '^ga-fykclp-ok next-action:mayor$' "$RL" 2>/dev/null | head -1 | cut -d: -f1)"
GT_LN="$(grep -n '^ga-fykclp-ok gate:needs-human$' "$RL" 2>/dev/null | head -1 | cut -d: -f1)"
if printf '%s' "$OUT" | grep "R1 ga-fykclp-ok" >/dev/null \
   && [ -n "$NA_LN" ] && [ -n "$GT_LN" ] && [ "$NA_LN" -lt "$GT_LN" ] \
   && grep -q 'next-action:mayor' "$TMP/fx.ga-fykclp-ok/comments.log" 2>/dev/null \
   && printf '%s' "$OUT" | grep -E '(^|[^0-9])[1-9][0-9]* destravadas sem humano' >/dev/null; then
  ok "ga-fykclp: next-action:mayor que coexistia com gate:needs-human* sai junto, ANTES do gate, e o comentário de auditoria o nomeia"
else
  bad "ga-fykclp: o auto-destrave deixou next-action:mayor pra trás (veto do Pilot permanece), ou removeu fora de ordem, ou calou no comentário" \
    "OUT=$OUT REMOVED=$(cat "$RL" 2>/dev/null) COMMENT=$(cat "$TMP/fx.ga-fykclp-ok/comments.log" 2>/dev/null)"
fi

# (2) a CLASSE, não o literal: next-action:<outro> é delegação a crew nomeada
# (ver reconciler, "ready, but delegated") e um nome parecido não casa — nada
# disso é do reconciler, então nada disso sai.
setup ga-fykclp-other '["gate:needs-human","next-action:wa-worker-constroi","next-action:mayor-review"]' '' '' ''
OUT="$(run)"
RL="$TMP/fx.ga-fykclp-other/removed.log"
if printf '%s' "$OUT" | grep "R1 ga-fykclp-other" >/dev/null \
   && grep -q '^ga-fykclp-other gate:needs-human$' "$RL" \
   && ! grep -q 'next-action' "$RL"; then
  ok "ga-fykclp: só next-action:mayor EXATO sai — next-action:<crew> e nome parecido (next-action:mayor-review) ficam"
else
  bad "ga-fykclp: removeu next-action:* que não é o do reconciler (apagaria delegação a crew)" "OUT=$OUT REMOVED=$(cat "$RL" 2>/dev/null)"
fi

# (3) variante protegida (:product = decisão do ATHOS): nenhuma label é tocada,
# nem o next-action:mayor — o script não está destravando nada.
setup ga-fykclp-prod '["gate:needs-human","gate:needs-human:product","next-action:mayor"]' '' '' ''
OUT="$(run)"
if printf '%s' "$OUT" | grep "SKIP ga-fykclp-prod" >/dev/null && [ ! -s "$TMP/fx.ga-fykclp-prod/removed.log" ]; then
  ok "ga-fykclp: bead com variante protegida (:product) segue intocado — next-action:mayor fica"
else
  bad "ga-fykclp: tocou em bead protegido (:product é do Athos)" "OUT=$OUT REMOVED=$(cat "$TMP/fx.ga-fykclp-prod/removed.log" 2>/dev/null)"
fi

# (4) R5 (escala pro humano, não destrava): o bead continua parado, então o
# marcador de "vez do Mayor" tem que sobreviver.
setup ga-fykclp-r5 '["gate:needs-human","next-action:mayor"]' 'origin/fix/ga-fykclp-r5' '+ abc' '1700000000' \
  '[{"created_at":"2026-08-15T10:00:00Z","text":"VERDICT: FAIL sem detalhe"}]'
OUT="$(run)"
if printf '%s' "$OUT" | grep "R5 ga-fykclp-r5" >/dev/null && [ ! -s "$TMP/fx.ga-fykclp-r5/removed.log" ]; then
  ok "ga-fykclp: R5 (escalado, não destravado) não remove next-action:mayor"
else
  bad "ga-fykclp: R5 não destrava nada — remover next-action:mayor aqui apagaria o aviso ao Mayor de um bead que segue parado" \
    "OUT=$OUT REMOVED=$(cat "$TMP/fx.ga-fykclp-r5/removed.log" 2>/dev/null)"
fi

# (5) falha ao remover next-action:mayor: o GATE NÃO PODE sair (senão o bead
# deixa a varredura e o veto fica órfão sem retry) e o comentário permanente
# tem que dizer exatamente isso — sem prometer gate removido, sem frase de sucesso.
setup ga-fykclp-nafail '["gate:needs-human","next-action:mayor"]' '' '' ''
touch "$TMP/fx.ga-fykclp-nafail/label_remove_fail.next-action:mayor"
OUT="$(run)"
CM="$TMP/fx.ga-fykclp-nafail/comments.log"
if printf '%s' "$OUT" | grep "FALHA R1 ga-fykclp-nafail" >/dev/null \
   && printf '%s' "$OUT" | grep "0 destravadas sem humano" >/dev/null \
   && ! grep -q 'gate:needs-human' "$TMP/fx.ga-fykclp-nafail/removed.log" \
   && grep -q 'AUTO-DESTRAVE R1 FALHOU' "$CM" \
   && grep -q 'next-action:mayor' "$CM" \
   && grep -qi 'nenhuma.*gate:needs-human.*tocada' "$CM" \
   && ! grep -q 'Nenhum humano precisou olhar' "$CM"; then
  ok "ga-fykclp: next-action:mayor falhando → gate NÃO sai (bead segue na varredura), FALHA reportada, comentário diz o que de fato aconteceu"
else
  bad "ga-fykclp: falha em next-action:mayor tem que deixar o gate no lugar e dizer isso no bead" \
    "OUT=$OUT REMOVED=$(cat "$TMP/fx.ga-fykclp-nafail/removed.log" 2>/dev/null) COMMENT=$(cat "$CM" 2>/dev/null)"
fi

# (6) o inverso: next-action:mayor saiu, o gate falhou. O comentário não pode
# esconder que o gate pode seguir lá nem omitir que o marcador já se foi.
setup ga-fykclp-gtfail '["gate:needs-human","next-action:mayor"]' '' '' ''
touch "$TMP/fx.ga-fykclp-gtfail/label_remove_fail.gate:needs-human"
OUT="$(run)"
CM="$TMP/fx.ga-fykclp-gtfail/comments.log"
if printf '%s' "$OUT" | grep "FALHA R1 ga-fykclp-gtfail" >/dev/null \
   && grep -q '^ga-fykclp-gtfail next-action:mayor$' "$TMP/fx.ga-fykclp-gtfail/removed.log" \
   && grep -q 'AUTO-DESTRAVE R1 FALHOU' "$CM" \
   && grep -q 'AINDA ESTAR PRESENTES' "$CM" \
   && grep -q 'next-action:mayor.*removido' "$CM" \
   && ! grep -q 'Nenhum humano precisou olhar' "$CM"; then
  ok "ga-fykclp: gate falhando depois de next-action:mayor sair → FALHA, comentário avisa que o gate pode seguir e que o marcador já foi removido"
else
  bad "ga-fykclp: falha do gate com next-action:mayor já removido tem que ser reportada com os dois fatos" \
    "OUT=$OUT REMOVED=$(cat "$TMP/fx.ga-fykclp-gtfail/removed.log" 2>/dev/null) COMMENT=$(cat "$CM" 2>/dev/null)"
fi

# (7) DRY_RUN decide, não muta — incluindo o next-action:mayor.
setup ga-fykclp-dry '["gate:needs-human","next-action:mayor"]' '' '' ''
DRY_RUN=1 GC_CITY_PATH="$TMP" WA_RIG="$TMP" PS_RIG="$TMP" \
  GATE_AUTO_UNBLOCK_LOG="$TMP/log" GATE_AUTO_UNBLOCK_LOCK="$TMP/gate-auto-unblock-fykclp-dry.lock" \
  bash "$SCRIPT" >/dev/null 2>&1
if [ ! -s "$TMP/fx.ga-fykclp-dry/removed.log" ] && [ ! -s "$TMP/fx.ga-fykclp-dry/comments.log" ]; then
  ok "ga-fykclp: DRY_RUN=1 não remove next-action:mayor"
else
  bad "ga-fykclp: DRY_RUN mutou" "$(cat "$TMP/fx.ga-fykclp-dry/removed.log" "$TMP/fx.ga-fykclp-dry/comments.log" 2>/dev/null)"
fi

# ── ga-ph10ox5: bead ESTACIONADA pelo dispatcher (ga-5w2gpw) não é re-gateada às cegas ───────────
# CASO REAL (wa-nen4us, 09/11, 7037 linhas contra o teto de 6000): o Step 5c do dispatcher estaciona — marker em error,
# gate:needs-human:technical, comentário "ga-5w2gpw PARKED before review" na bead — SEM veredito. O R2 comparava a ponta com o
# ÚLTIMO FAIL (antigo: estacionar não é FAIL), casava sempre, tirava a trava e re-submetia: 4 voltas em 67 min, 8 mails ao Mayor,
# ninguém agiu em 5 h. Commit novo não encolhe um diff acima do teto: o que decide se re-gatear adianta é o diff ATUAL caber.
PK_FAIL_OLD='2026-11-06T10:00:00Z'; PK_FAIL_NEW='2026-11-08T10:00:00Z'; PK_PARK_AT='2026-11-09T05:38:00Z'
PK_TIP=1794202200      # 2026-11-09T05:30:00Z: depois da reprovação antiga, antes do estacionamento
PK_TIP_OLD=1793959200  # 2026-11-06T10:00:00Z: ANTES da reprovação de 08/11 (só R3/R4 agem sobre uma ponta que não mudou)
cj() { jq -cn --arg t "$1" --arg x "$2" '{created_at:$t,text:$x}'; }   # um comentário, no formato do `bd show --json --include-comments`
set_diff() { awk -v n="$1" -v w="${2:-20}" 'BEGIN { s = "+"; for (j = 1; j < w; j++) s = s "x"; for (i = 1; i <= n; i++) print s }' > "$FX/diff.txt"; }
pk_inert() { [ ! -s "$FX/removed.log" ] && [ ! -s "$FX/comments.log" ]; }       # nenhuma label tocada, nenhum comentário postado
pk_regra() { case "$OUT" in *"$1 $2 "*) return 0 ;; esac; return 1; }          # pk_regra R2 <id>: a linha "R2 <id> — …" está na saída

# O texto do estacionamento NÃO é digitado aqui: sai do bloco REAL do Step 5c do dispatcher (as mesmas sentinelas SELFTEST-EXTRACT
# do gate-e6d), rodado sob stubs. Assim o contrato "o que o dispatcher escreve é o que esta varredura reconhece" quebra AQUI, alto,
# se alguém reescrever o comentário — e não em silêncio, no dia em que o loop voltar.
DISPATCHER="$HERE/quality-gate-dispatcher.sh"; TASKLIB="$HERE/gate-review-task.lib.sh"
sed -n '/^# SELFTEST-EXTRACT gate-diff-budget: BEGIN/,/^# SELFTEST-EXTRACT gate-diff-budget: END/p' "$DISPATCHER" > "$TMP/pk-budget.sh"
sed -n '/^# SELFTEST-EXTRACT gate-diff-park: BEGIN/,/^# SELFTEST-EXTRACT gate-diff-park: END/p' "$DISPATCHER" > "$TMP/pk-block.sh"
cat > "$TMP/pk-stubs.sh" <<'STUBS'
git_rig() {
  case "$*" in
    "diff --stat "*) echo " 1 file changed"; return 0 ;;
    "diff "*"...origin/"*) [ "${PK_GITFAIL:-0}" = "1" ] && return 1; awk -v n="$PK_LINES" 'BEGIN { for (i = 1; i <= n; i++) print "+xxxxxxxxxxxxxxxxxxxx" }'; return 0 ;;
  esac
  return 0
}
bd() { [ "${3:-}" = comment ] && [ "${4:-}" = "pk-bead" ] && printf '%s' "${@: -1}" > "$PK_OUT"; return 0; }
gc() { return 0; }
set_gate_status() { return 0; }
gate_apply_needs_human() { echo armed; }
gate_needs_human_clause() { echo "Auto-retry is now DISABLED (label gate:needs-human, verified applied); the Pilot will not re-dispatch it."; }
log() { :; }; warn() { :; }; err() { :; }
STUBS
# pk_dispatcher_comment <linhas do diff> [PK_GITFAIL=1] → o comentário que o dispatcher posta na bead-fonte ao estacionar
pk_dispatcher_comment() {
  local out="$TMP/pk-bead-comment.$RANDOM"; : > "$out"
  env PK_LINES="$1" PK_OUT="$out" ${2:+"$2"} TMP="$TMP" TASKLIB="$TASKLIB" bash -c '
    set -euo pipefail
    . "$TMP/pk-stubs.sh"; . "$TASKLIB"; . "$TMP/pk-budget.sh"
    DEFAULT_BRANCH=main; BRANCH=fix/x; RIG=whatsapp_automation; RIG_PATH=/fake; GIT_DIR_PATH=/fake; IS_CONTAINER_RIG=0
    MARKER_ID=pk-mk; BEAD_ID=pk-bead; BEAD_CITY=bead-city; GC_CITY=gc-city; AUTHOR=""; QG_LOG="$TMP/pk-qg.log"
    CHANGED_FILES="f1.py"; DIFF_FILE_COUNT=1
    . "$TMP/pk-block.sh"
  ' >/dev/null 2>&1
  cat "$out"
}
PK_TEXT="$(pk_dispatcher_comment 7037)"                       # diff grande demais (os 7037 do caso real)
PK_TEXT_UNREAD="$(pk_dispatcher_comment 10 PK_GITFAIL=1)"     # a outra face do Step 5c: arquivos listados, diff que não se lê
case "$PK_TEXT" in
  "ga-5w2gpw PARKED before review (marker "*"GATE_DIFF_LINE_BUDGET"*)
    ok "contrato: o bloco REAL do Step 5c posta na bead-fonte «ga-5w2gpw PARKED before review (marker …» (diff grande demais)";;
  *) bad "contrato: não obtive o comentário de estacionamento do dispatcher (bloco Step 5c ausente ou reescrito) — o que esta varredura reconhece precisa ser o que ele escreve" "$PK_TEXT"
     PK_TEXT='ga-5w2gpw PARKED before review (marker pk-mk): branch fix/x has a diff of 7037 lines (GATE_DIFF_LINE_BUDGET)';;
esac
case "$PK_TEXT_UNREAD" in
  "ga-5w2gpw PARKED before review (marker "*"no readable diff"*) ok "contrato: o mesmo comentário abre o estacionamento por diff ilegível («has no readable diff»)";;
  *) bad "contrato: o estacionamento por diff ilegível não começa por «ga-5w2gpw PARKED before review (marker …»" "$PK_TEXT_UNREAD"
     PK_TEXT_UNREAD='ga-5w2gpw PARKED before review (marker pk-mk): branch fix/x has no readable diff';;
esac

PK_LABELS='["gate:needs-human","gate:needs-human:technical","gate-sha-failed:aaa:code"]'
PK_COM="[$(cj "$PK_FAIL_OLD" 'VERDICT: FAIL blocking issue em lib/x.py'),$(cj "$PK_PARK_AT" "$PK_TEXT")]"

# (1) O BUG: park de tamanho + ponta posterior a um FAIL antigo + diff acima do teto → R2 NÃO dispara. Duas varreduras seguidas:
# a segunda é o loop de 20 min do caso real — tem que continuar segurando, sem consumir nada.
setup wa-nen4us "$PK_LABELS" 'origin/fix/wa-nen4us-bh' '+ abc1234' "$PK_TIP" "$PK_COM"
set_diff 21
OUT="$(GATE_DIFF_LINE_BUDGET=20 run)"; OUT2="$(GATE_DIFF_LINE_BUDGET=20 run)"
if pk_regra HOLD wa-nen4us && ! pk_regra R2 wa-nen4us && ! pk_regra R3 wa-nen4us && ! pk_regra R4 wa-nen4us && ! pk_regra R5 wa-nen4us \
   && pk_inert \
   && printf '%s' "$OUT" | grep -E '[1-9][0-9]* seguradas' >/dev/null && printf '%s' "$OUT" | grep -E ' 0 destravadas sem humano' >/dev/null; then
  case "$OUT2" in *"HOLD wa-nen4us"*) ok "ga-ph10ox5: park de tamanho + ponta posterior ao FAIL antigo + diff acima do teto → R2 NÃO dispara: HOLD, nada tocado, segue segurando na 2ª varredura (wa-nen4us)";;
    *) bad "ga-ph10ox5: a 2ª varredura parou de segurar" "OUT2=$OUT2";; esac
else
  bad "ga-ph10ox5: bead estacionada por tamanho com ponta posterior ao FAIL antigo foi re-gateada (o loop de wa-nen4us) — esperado HOLD, sem R2/R3/R4/R5 e sem tocar label nem comentário" \
    "OUT=$OUT REMOVED=$(cat "$FX/removed.log" 2>/dev/null) COMMENT=$(cat "$FX/comments.log" 2>/dev/null)"
fi

# (2) o MESMO bead com o diff dentro do teto → R2 dispara (a trava só segura enquanto o diff não cabe).
setup wa-pk-fits "$PK_LABELS" 'origin/fix/wa-pk-fits-x' '+ abc1234' "$PK_TIP" "$PK_COM"
set_diff 10
OUT="$(GATE_DIFF_LINE_BUDGET=20 run)"
if pk_regra R2 wa-pk-fits && ! pk_regra HOLD wa-pk-fits && grep -q '^wa-pk-fits gate:needs-human' "$FX/removed.log"; then
  ok "ga-ph10ox5: com o diff DENTRO do teto, R2 dispara e tira a trava (o branch encolheu: re-gatear volta a adiantar)"
else
  bad "ga-ph10ox5: diff que cabe tem que liberar o R2" "OUT=$OUT REMOVED=$(cat "$FX/removed.log" 2>/dev/null)"
fi

# (3) diff que NÃO se mede → não re-gateia (inerte) e CONTA como «não consegui medir». Os dois jeitos: o git falha (rc != 0) e o
# git responde sem texto. "Não sei" nunca vira "cabe".
setup wa-pk-diffail "$PK_LABELS" 'origin/fix/wa-pk-diffail-x' '+ abc1234' "$PK_TIP" "$PK_COM"
touch "$FX/diff_fail"
OUT="$(GATE_DIFF_LINE_BUDGET=20 run)"
if pk_regra SEM-MEDIDA wa-pk-diffail && ! pk_regra R2 wa-pk-diffail && ! pk_regra HOLD wa-pk-diffail && pk_inert \
   && printf '%s' "$OUT" | grep -E '[1-9][0-9]* sem medir' >/dev/null; then
  ok "ga-ph10ox5: git diff FALHANDO → R2 não dispara, nada tocado, conta como «sem medir» (não vira «cabe»)"
else
  bad "ga-ph10ox5: diff que falhou ao medir tem que ficar inerte e contado, nunca liberar o R2" "OUT=$OUT"
fi
setup wa-pk-nodiff "$PK_LABELS" 'origin/fix/wa-pk-nodiff-x' '+ abc1234' "$PK_TIP" "$PK_COM"
OUT="$(GATE_DIFF_LINE_BUDGET=20 run)"          # sem diff.txt: o git responde sem texto
if pk_regra SEM-MEDIDA wa-pk-nodiff && ! pk_regra R2 wa-pk-nodiff && pk_inert; then
  ok "ga-ph10ox5: git diff SEM texto (base ou ref ausente) → inerte e contado, não vira «cabe»"
else
  bad "ga-ph10ox5: diff sem texto não pode liberar o R2" "OUT=$OUT"
fi

# (4) sem a lib de medição ao lado do script não há como medir → inerte; com a lib, a MESMA cópia libera o R2 (o controle prova que
# o resultado da cópia sem lib não é artefato da cópia).
for v in nolib withlib; do mkdir -p "$TMP/$v"; cp "$HERE/gate-auto-unblock.sh" "$HERE/delivery-branch-patterns.sh" "$TMP/$v/"; done
cp "$HERE/gate-review-task.lib.sh" "$TMP/withlib/"
SCRIPT_REAL="$SCRIPT"
setup wa-pk-nolib "$PK_LABELS" 'origin/fix/wa-pk-nolib-x' '+ abc1234' "$PK_TIP" "$PK_COM"
set_diff 10
SCRIPT="$TMP/nolib/gate-auto-unblock.sh"; OUT="$(GATE_DIFF_LINE_BUDGET=20 run)"
if pk_regra SEM-MEDIDA wa-pk-nolib && ! pk_regra R2 wa-pk-nolib && pk_inert && printf '%s' "$OUT" | grep -i 'gate-review-task.lib.sh' >/dev/null; then
  ok "ga-ph10ox5: sem gate-review-task.lib.sh ao lado → «sem medir» dizendo QUE a lib faltou, R2 não dispara mesmo com o diff pequeno"
else
  bad "ga-ph10ox5: sem a lib de medição o script não pode liberar o R2 (nem calar o motivo)" "OUT=$OUT"
fi
setup wa-pk-withlib "$PK_LABELS" 'origin/fix/wa-pk-withlib-x' '+ abc1234' "$PK_TIP" "$PK_COM"
set_diff 10
SCRIPT="$TMP/withlib/gate-auto-unblock.sh"; OUT="$(GATE_DIFF_LINE_BUDGET=20 run)"
SCRIPT="$SCRIPT_REAL"
if pk_regra R2 wa-pk-withlib; then ok "ga-ph10ox5: (controle) a mesma cópia COM a lib libera o R2 com o diff pequeno"; else bad "ga-ph10ox5: controle da cópia com a lib falhou" "OUT=$OUT"; fi
# lib que carrega mas NÃO entrega a medição (função que falha sem dar cobertura): o terceiro estado de novo — inerte, nunca «cabe»
mkdir -p "$TMP/badlib"; cp "$HERE/gate-auto-unblock.sh" "$HERE/delivery-branch-patterns.sh" "$TMP/badlib/"
printf '%s\n' 'gate_build_diff_payload() { return 1; }' > "$TMP/badlib/gate-review-task.lib.sh"
setup wa-pk-badlib "$PK_LABELS" 'origin/fix/wa-pk-badlib-x' '+ abc1234' "$PK_TIP" "$PK_COM"
set_diff 10
SCRIPT="$TMP/badlib/gate-auto-unblock.sh"; OUT="$(GATE_DIFF_LINE_BUDGET=20 run)"
SCRIPT="$SCRIPT_REAL"
if pk_regra SEM-MEDIDA wa-pk-badlib && ! pk_regra R2 wa-pk-badlib && pk_inert; then ok "ga-ph10ox5: lib que falha sem dar cobertura → «sem medir», inerte (a ausência de resposta nunca vira «cabe»)"; else bad "ga-ph10ox5: lib inútil liberou o R2" "OUT=$OUT"; fi

# (5) «e qualquer regra que re-gateie»: sem R2 (ponta ANTES da reprovação de 08/11), o R3 redespacharia com a instrução do
# veredito e o R4 escalaria o escopo — as duas tiram a trava, então o estacionamento tem que segurar as duas também.
PK_COM_R3="[$(cj "$PK_FAIL_NEW" 'VERDICT: FAIL tests/test_pregao.py precisa da chave nova'),$(cj "$PK_PARK_AT" "$PK_TEXT")]"
setup wa-pk-r3 '["gate:needs-human:technical","gate-sha-failed:a:code"]' 'origin/fix/wa-pk-r3-x' '+ eaf78abb' "$PK_TIP_OLD" "$PK_COM_R3"
set_diff 21
OUT="$(GATE_DIFF_LINE_BUDGET=20 run)"
if pk_regra HOLD wa-pk-r3 && ! pk_regra R3 wa-pk-r3 && ! pk_regra R2 wa-pk-r3 && pk_inert; then
  ok "ga-ph10ox5: o R3 também não re-gateia bead estacionada com o diff acima do teto (veredito antigo nomeando arquivo)"
else
  bad "ga-ph10ox5: R3 re-gateou uma bead estacionada por tamanho (o loop trocaria de regra, não acabaria)" "OUT=$OUT"
fi
setup wa-pk-r3ctl '["gate:needs-human:technical","gate-sha-failed:a:code"]' 'origin/fix/wa-pk-r3ctl-x' '+ eaf78abb' "$PK_TIP_OLD" "$PK_COM_R3"
set_diff 10
OUT="$(GATE_DIFF_LINE_BUDGET=20 run)"
if pk_regra R3 wa-pk-r3ctl; then ok "ga-ph10ox5: (controle) a mesma bead com o diff pequeno cai no R3 — o cenário acima é mesmo território do R3"; else bad "ga-ph10ox5: controle do R3 falhou" "OUT=$OUT"; fi
PK_LABELS_R4='["gate:needs-human:technical","gate-sha-failed:a:code","gate-sha-failed:b:code","gate-sha-failed:c:code"]'
setup wa-pk-r4 "$PK_LABELS_R4" 'origin/fix/wa-pk-r4-x' '+ b40be47f' "$PK_TIP_OLD" "$PK_COM_R3"
set_diff 21
OUT="$(GATE_DIFF_LINE_BUDGET=20 run)"
if pk_regra HOLD wa-pk-r4 && ! pk_regra R4 wa-pk-r4 && pk_inert; then
  ok "ga-ph10ox5: o R4 também não age sobre bead estacionada com o diff acima do teto"
else
  bad "ga-ph10ox5: R4 agiu sobre uma bead estacionada por tamanho" "OUT=$OUT"
fi
setup wa-pk-r4ctl "$PK_LABELS_R4" 'origin/fix/wa-pk-r4ctl-x' '+ b40be47f' "$PK_TIP_OLD" "$PK_COM_R3"
set_diff 10
OUT="$(GATE_DIFF_LINE_BUDGET=20 run)"
if pk_regra R4 wa-pk-r4ctl; then ok "ga-ph10ox5: (controle) a mesma bead com o diff pequeno cai no R4"; else bad "ga-ph10ox5: controle do R4 falhou" "OUT=$OUT"; fi

# (6) CONTROLE NEGATIVO: o R2 clássico (FAIL de código + commit novo, SEM estacionamento) segue disparando — mesmo com um diff acima
# do teto: a medição só é consultada quando o último evento do gate é um estacionamento.
setup wa-pk-classic "$PK_LABELS" 'origin/fix/wa-pk-classic-x' '+ abc1234' "$PK_TIP" "[$(cj "$PK_FAIL_OLD" 'VERDICT: FAIL blocking issue em lib/x.py')]"
set_diff 21
OUT="$(GATE_DIFF_LINE_BUDGET=20 run)"
if pk_regra R2 wa-pk-classic && ! pk_regra HOLD wa-pk-classic; then
  ok "ga-ph10ox5: (controle negativo) FAIL de código + commit novo, sem estacionamento, segue disparando R2 — mesmo com diff grande"
else
  bad "ga-ph10ox5: o R2 clássico parou de disparar" "OUT=$OUT"
fi

# (7) a ORDEM importa: estacionamento mais VELHO que a última reprovação não segura nada (houve revisão depois dele).
setup wa-pk-stale "$PK_LABELS" 'origin/fix/wa-pk-stale-x' '+ abc1234' "$PK_TIP" "[$(cj "$PK_FAIL_OLD" "$PK_TEXT"),$(cj "$PK_FAIL_NEW" 'VERDICT: FAIL blocking issue em lib/x.py')]"
set_diff 21
OUT="$(GATE_DIFF_LINE_BUDGET=20 run)"
if pk_regra R2 wa-pk-stale && ! pk_regra HOLD wa-pk-stale; then
  ok "ga-ph10ox5: estacionamento mais velho que a última reprovação não segura o R2 (o último evento foi um veredito)"
else
  bad "ga-ph10ox5: estacionamento VELHO segurou o R2" "OUT=$OUT"
fi
# …e no mesmo instante (ordem indecidível) o lado seguro é segurar; carimbo ilegível idem: nunca presumir que o park é antigo.
setup wa-pk-tie "$PK_LABELS" 'origin/fix/wa-pk-tie-x' '+ abc1234' "$PK_TIP" "[$(cj "$PK_FAIL_NEW" 'VERDICT: FAIL blocking issue em lib/x.py'),$(cj "$PK_FAIL_NEW" "$PK_TEXT")]"
set_diff 21
OUT="$(GATE_DIFF_LINE_BUDGET=20 run)"
if pk_regra HOLD wa-pk-tie && ! pk_regra R2 wa-pk-tie; then ok "ga-ph10ox5: estacionamento e reprovação no MESMO instante → segura (a ordem não se decide, o lado inerte vence)"; else bad "ga-ph10ox5: empate de carimbo liberou o R2" "OUT=$OUT"; fi
setup wa-pk-garbage "$PK_LABELS" 'origin/fix/wa-pk-garbage-x' '+ abc1234' "$PK_TIP" "[$(cj "$PK_FAIL_OLD" 'VERDICT: FAIL blocking issue em lib/x.py'),$(cj 'ontem de manhã' "$PK_TEXT")]"
set_diff 21
OUT="$(GATE_DIFF_LINE_BUDGET=20 run)"
if pk_regra HOLD wa-pk-garbage && ! pk_regra R2 wa-pk-garbage; then ok "ga-ph10ox5: carimbo do estacionamento ILEGÍVEL → mede e segura (não presume que é antigo)"; else bad "ga-ph10ox5: carimbo ilegível liberou o R2" "OUT=$OUT"; fi

# …o ÚLTIMO estacionamento é o que vale (dois: um de antes da reprovação de 08/11, outro depois) e quem só CITA a frase no meio de
# outro comentário não estaciona nada (o padrão é ancorado no começo do texto).
setup wa-pk-two "$PK_LABELS" 'origin/fix/wa-pk-two-x' '+ abc1234' "$PK_TIP" "[$(cj "$PK_FAIL_OLD" "$PK_TEXT"),$(cj "$PK_FAIL_NEW" 'VERDICT: FAIL blocking issue em lib/x.py'),$(cj "$PK_PARK_AT" "$PK_TEXT")]"
set_diff 21
OUT="$(GATE_DIFF_LINE_BUDGET=20 run)"
if pk_regra HOLD wa-pk-two && ! pk_regra R2 wa-pk-two; then ok "ga-ph10ox5: com dois estacionamentos vale o ÚLTIMO (o de depois da reprovação segura)"; else bad "ga-ph10ox5: o estacionamento mais novo tem que valer" "OUT=$OUT"; fi
setup wa-pk-quote "$PK_LABELS" 'origin/fix/wa-pk-quote-x' '+ abc1234' "$PK_TIP" "[$(cj "$PK_FAIL_OLD" 'VERDICT: FAIL blocking issue em lib/x.py'),$(cj "$PK_PARK_AT" "Mayor: reli o comentário «ga-5w2gpw PARKED before review (marker m): …» da outra bead; esta aqui só mudou de ponta")]"
set_diff 21
OUT="$(GATE_DIFF_LINE_BUDGET=20 run)"
if pk_regra R2 wa-pk-quote && ! pk_regra HOLD wa-pk-quote; then ok "ga-ph10ox5: um comentário que só CITA a frase do estacionamento no meio do texto não conta como estacionamento"; else bad "ga-ph10ox5: citação da frase foi lida como estacionamento" "OUT=$OUT"; fi

# (8) sem NENHUM FAIL na bead (nunca foi revisada): o estacionamento é o último evento. Acima do teto segura (em vez do R5 que
# diria «nenhum veredito FAIL encontrado… label espúrio», mentira aqui); com diff que cabe, nada muda: R5 como sempre.
setup wa-pk-nofail '["gate:needs-human:technical"]' 'origin/fix/wa-pk-nofail-x' '+ abc1234' "$PK_TIP" "[$(cj "$PK_PARK_AT" "$PK_TEXT")]"
set_diff 21
OUT="$(GATE_DIFF_LINE_BUDGET=20 run)"
if pk_regra HOLD wa-pk-nofail && ! pk_regra R5 wa-pk-nofail && pk_inert; then ok "ga-ph10ox5: bead nunca revisada e estacionada por tamanho → HOLD, não o R5 com texto de «label espúrio»"; else bad "ga-ph10ox5: bead estacionada sem FAIL tem que segurar" "OUT=$OUT"; fi
setup wa-pk-nofailfit '["gate:needs-human:technical"]' 'origin/fix/wa-pk-nofailfit-x' '+ abc1234' "$PK_TIP" "[$(cj "$PK_PARK_AT" "$PK_TEXT")]"
set_diff 10
OUT="$(GATE_DIFF_LINE_BUDGET=20 run)"
if pk_regra R5 wa-pk-nofailfit && ! pk_regra HOLD wa-pk-nofailfit; then ok "ga-ph10ox5: (controle) sem FAIL e com diff que cabe o caminho antigo segue: R5"; else bad "ga-ph10ox5: sem FAIL e diff pequeno devia seguir pro R5" "OUT=$OUT"; fi

# (9) a MESMA régua do dispatcher, nos defaults da lib (nenhuma cópia do 6000 aqui): 6000 linhas cabem, 6001 não.
setup wa-pk-d6000 "$PK_LABELS" 'origin/fix/wa-pk-d6000-x' '+ abc1234' "$PK_TIP" "$PK_COM"
set_diff 6000
OUT="$(run)"
if pk_regra R2 wa-pk-d6000 && ! pk_regra HOLD wa-pk-d6000; then ok "ga-ph10ox5: teto padrão — um diff de EXATAMENTE 6000 linhas cabe (R2 libera)"; else bad "ga-ph10ox5: 6000 linhas é o teto, cabe" "OUT=$OUT"; fi
setup wa-pk-d6001 "$PK_LABELS" 'origin/fix/wa-pk-d6001-x' '+ abc1234' "$PK_TIP" "$PK_COM"
set_diff 6001
OUT="$(run)"
if pk_regra HOLD wa-pk-d6001 && ! pk_regra R2 wa-pk-d6001; then ok "ga-ph10ox5: teto padrão — 6001 linhas já NÃO cabem (HOLD), a mesma régua do dispatcher"; else bad "ga-ph10ox5: 6001 linhas passam do teto padrão" "OUT=$OUT"; fi
# o teto de BYTES também conta (poucas linhas, muito largas), e um teto de ambiente ilegível volta ao padrão — nunca a «sem teto»
setup wa-pk-bytes "$PK_LABELS" 'origin/fix/wa-pk-bytes-x' '+ abc1234' "$PK_TIP" "$PK_COM"
set_diff 10 200
OUT="$(GATE_DIFF_BYTE_BUDGET=1000 run)"
if pk_regra HOLD wa-pk-bytes && ! pk_regra R2 wa-pk-bytes; then ok "ga-ph10ox5: o teto de BYTES também segura (10 linhas de 200 bytes contra GATE_DIFF_BYTE_BUDGET=1000)"; else bad "ga-ph10ox5: teto de bytes ignorado" "OUT=$OUT"; fi
setup wa-pk-garbbud "$PK_LABELS" 'origin/fix/wa-pk-garbbud-x' '+ abc1234' "$PK_TIP" "$PK_COM"
set_diff 21
OUT="$(GATE_DIFF_LINE_BUDGET=abc run)"
if pk_regra R2 wa-pk-garbbud && ! pk_regra HOLD wa-pk-garbbud; then ok "ga-ph10ox5: GATE_DIFF_LINE_BUDGET ilegível volta ao teto padrão da lib (21 linhas cabem), não vira «teto zero»"; else bad "ga-ph10ox5: teto ilegível tem que cair no padrão" "OUT=$OUT"; fi

# (10) a outra face do Step 5c — estacionada porque o diff NÃO SE LIA: o mesmo critério, só um diff medido e inteiro libera.
PK_COM_UNREAD="[$(cj "$PK_FAIL_OLD" 'VERDICT: FAIL blocking issue em lib/x.py'),$(cj "$PK_PARK_AT" "$PK_TEXT_UNREAD")]"
setup wa-pk-unread "$PK_LABELS" 'origin/fix/wa-pk-unread-x' '+ abc1234' "$PK_TIP" "$PK_COM_UNREAD"
touch "$FX/diff_fail"
OUT="$(GATE_DIFF_LINE_BUDGET=20 run)"
if pk_regra SEM-MEDIDA wa-pk-unread && ! pk_regra R2 wa-pk-unread && pk_inert; then ok "ga-ph10ox5: estacionada por diff ilegível e o diff segue ilegível → inerte e contado"; else bad "ga-ph10ox5: park por diff ilegível, ainda ilegível, não pode re-gatear" "OUT=$OUT"; fi
setup wa-pk-unreadok "$PK_LABELS" 'origin/fix/wa-pk-unreadok-x' '+ abc1234' "$PK_TIP" "$PK_COM_UNREAD"
set_diff 10
OUT="$(GATE_DIFF_LINE_BUDGET=20 run)"
if pk_regra R2 wa-pk-unreadok; then ok "ga-ph10ox5: estacionada por diff ilegível e agora o diff se lê e cabe → R2 libera"; else bad "ga-ph10ox5: diff que voltou a ler e cabe tem que liberar o R2" "OUT=$OUT"; fi

# (11) DRY_RUN não muda nada no caminho do HOLD (a decisão sai no log, a bead fica como está)
setup wa-pk-dry "$PK_LABELS" 'origin/fix/wa-pk-dry-x' '+ abc1234' "$PK_TIP" "$PK_COM"
set_diff 21
OUT="$(DRY_RUN=1 GATE_DIFF_LINE_BUDGET=20 run)"
if pk_regra HOLD wa-pk-dry && pk_inert; then ok "ga-ph10ox5: DRY_RUN=1 mantém o HOLD sem tocar em nada"; else bad "ga-ph10ox5: DRY_RUN no HOLD" "OUT=$OUT"; fi

# (12) git REAL de ponta a ponta: repo + origin de verdade, com refs/remotes/origin/{main,fix/…} como no rig. O shim devolve o diff
# pronto e só prova a fiação pela FORMA do argumento; aqui o git é o de verdade (cherry, for-each-ref, git diff A...B) e o diff
# medido tem que ser o do repo: 30 linhas de arquivo novo = 36 linhas de diff.
GIT_REAL="$(PATH="$_SANDBOX_SYSTEM_DIRS:/usr/local/bin:/opt/homebrew/bin" command -v git 2>/dev/null)"
PK_REPO="$TMP/pk-real"; PK_REAL_OK=0
if [ -n "$GIT_REAL" ]; then
  pk_git() { "$GIT_REAL" -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false "$@"; }
  mkdir -p "$PK_REPO" \
    && pk_git init -q --bare "$PK_REPO/origin.git" && pk_git init -q "$PK_REPO/work" \
    && pk_git -C "$PK_REPO/work" symbolic-ref HEAD refs/heads/main \
    && echo base > "$PK_REPO/work/base.txt" && pk_git -C "$PK_REPO/work" add -A && pk_git -C "$PK_REPO/work" commit -q -m base \
    && pk_git -C "$PK_REPO/work" remote add origin "$PK_REPO/origin.git" && pk_git -C "$PK_REPO/work" push -q origin main \
    && pk_git -C "$PK_REPO/work" checkout -q -b fix/wa-pk-real-x \
    && awk 'BEGIN { for (i = 1; i <= 30; i++) print "line " i " xxxxxxxxxxxxxxxx" }' > "$PK_REPO/work/big.txt" \
    && pk_git -C "$PK_REPO/work" add -A && pk_git -C "$PK_REPO/work" commit -q -m big \
    && pk_git -C "$PK_REPO/work" push -q origin fix/wa-pk-real-x && pk_git -C "$PK_REPO/work" fetch -q origin \
    && PK_REAL_OK=1
fi
run_real() {
  GC_CITY_PATH="$PK_REPO/work" WA_RIG="$PK_REPO/work" PS_RIG="$PK_REPO/work" \
  GATE_AUTO_UNBLOCK_LOG="$TMP/log" GATE_AUTO_UNBLOCK_LOCK="$TMP/gate-auto-unblock.lock" \
  BD=bd GIT="$GIT_REAL" bash "$SCRIPT" 2>&1
}
if [ "$PK_REAL_OK" = "1" ]; then
  setup wa-pk-real "$PK_LABELS" '' '' '' "$PK_COM"
  OUT="$(GATE_DIFF_LINE_BUDGET=20 run_real)"
  if pk_regra HOLD wa-pk-real && ! pk_regra R2 wa-pk-real && pk_inert && printf '%s' "$OUT" | grep -F '36 linhas' >/dev/null; then
    ok "ga-ph10ox5: git REAL — o diff de 30 linhas novas mede 36 e passa do teto 20: HOLD, nada tocado"
  else
    bad "ga-ph10ox5: git real, diff acima do teto, tinha que segurar medindo 36 linhas" "OUT=$OUT"
  fi
  setup wa-pk-real "$PK_LABELS" '' '' '' "$PK_COM"
  OUT="$(GATE_DIFF_LINE_BUDGET=100 run_real)"
  if pk_regra R2 wa-pk-real && ! pk_regra HOLD wa-pk-real && grep -q '^wa-pk-real gate:needs-human' "$FX/removed.log"; then
    ok "ga-ph10ox5: git REAL — o mesmo branch com o teto em 100 cabe: R2 libera"
  else
    bad "ga-ph10ox5: git real, diff dentro do teto, tinha que liberar o R2" "OUT=$OUT"
  fi
else
  bad "ga-ph10ox5: não consegui montar o repo git real (git='$GIT_REAL') — o cenário de ponta a ponta não rodou"
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
