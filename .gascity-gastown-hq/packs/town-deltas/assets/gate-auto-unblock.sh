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
#
# ⚠️ (revisor, gate-run ga-oaqy39, blocking issue 2): busca DUAS
# namespaces (crew/*/* e fix/*) numa só chamada, e for-each-ref devolve
# tudo ORDENADO ALFABETICAMENTE — "crew" < "fix" sempre. A versão antiga
# pegava o PRIMEIRO match ({print; exit}), então se o MESMO bead tivesse
# ref em ambas (crew abandonada + fix real, ou vice-versa — a branch
# ativa de um bead pode legitimamente migrar de namespace ao longo da
# vida dele), a escolha era um acidente alfabético, nunca a mais
# recente — podendo apagar a trava da branch ERRADA e deixar o trabalho
# real sem exame e sem lock. Agora coleta TODOS os matches e escolhe
# pelo commit TIP mais recente. Se a busca de epoch falhar pra algum
# candidato (raro — a ref acabou de ser listada), ainda devolve o
# PRIMEIRO candidato visto como fallback, nunca vazio quando existe pelo
# menos um match — vazio só quando não há match nenhum (R1 genuíno).
branch_for() {
  local rig="$1" id="$2" ref best="" best_epoch=-1 epoch first=""
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    [ -n "$first" ] || first="$ref"
    epoch="$("$GIT" -C "$rig" log -1 --format='%ct' "$ref" 2>/dev/null)"
    if [ -n "${epoch:-}" ] && [ "$epoch" -gt "$best_epoch" ] 2>/dev/null; then
      best="$ref"
      best_epoch="$epoch"
    fi
  done < <("$GIT" -C "$rig" for-each-ref --format='%(refname:short)' \
      'refs/remotes/origin/crew/*/*' 'refs/remotes/origin/fix/*' 2>/dev/null \
    | awk -F/ -v id="$id" '$NF==id || substr($NF,1,length(id)+1)==id"-"')
  printf '%s' "${best:-$first}"
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

# fetch_labels <rig> <bead> → labels crus, um por linha, via stdout.
# Devolve via CÓDIGO DE SAÍDA se bd show teve sucesso (0) ou falhou (1)
# — stdout fica vazio nos DOIS casos ("confirmado zero labels" vs "não
# consegui saber"), então quem chama TEM que checar o código de saída,
# nunca só o conteúdo.
# ⚠️ (revisor, 2ª rodada adversarial pré-resubmissão): a versão anterior
# (labels_of) era chamada em SEPARADO por lock_variant, has_protected_variant
# E strip_lock — três chamadas bd show sem cache, cada uma podendo falhar
# independente das outras. Reprodução real: has_protected_variant chama
# falha (transição momentânea, "query latency alta" já documentado como
# comportamento medido do Dolt nesta cidade) e devolve "não protegido" por
# falta de dado — mas strip_lock, chamado segundos depois, tem sua PRÓPRIA
# chamada bem-sucedida e vê o estado REAL (com uma label protegida
# co-presente) — e remove tudo que vê, sem saber que a checagem de proteção
# rodou sobre dado incompleto. Buscada UMA vez por bead em main() agora e
# propagada por parâmetro pras três funções — elimina a corrida por
# construção, não só trata a falha graciosamente.
fetch_labels() {
  local out rc
  out="$("$BD" -C "$1" show "$2" --json 2>/dev/null)"
  rc=$?
  [ "$rc" -eq 0 ] && [ -n "$out" ] || return 1
  printf '%s\n' "$out" | jq -r '.[0].labels[]?' 2>/dev/null
}

# lock_variant <labels-multilinha> → a variante de trava presente, ou vazio.
lock_variant() {
  printf '%s\n' "$1" | grep '^gate:needs-human' | head -1
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

# has_protected_variant <labels-multilinha> → 0 se QUALQUER label
# presente cai fora de UNBLOCKABLE_VARIANTS (armadilha E). lock_variant()
# só olha a PRIMEIRA label (head -1); esta função varre TODAS as
# gate:needs-human* presentes NA LISTA JÁ BUSCADA, então detecta uma
# protegida mesmo co-presente com uma unblockable — o caso que escapava
# antes e que strip_lock() apagaria.
has_protected_variant() {
  local v
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    case "$v" in gate:needs-human*) : ;; *) continue ;; esac
    is_unblockable "$v" || return 0
  done <<< "$1"
  return 1
}

# strip_lock <rig> <bead> <labels-multilinha> — remove TODAS as
# variantes gate:needs-human* PRESENTES NA LISTA JÁ FORNECIDA (mesma
# leitura que has_protected_variant já validou como segura — não
# rebusca, ver fetch_labels acima pro motivo). Só é chamada depois que
# main() confirma has_protected_variant=false sobre esta MESMA lista.
# ⚠️ (revisor, gate-run ga-oaqy39, blocking issue 1): retorna 0 SÓ se
# TODA remoção confirmou sucesso (ou DRY_RUN) — antes, `>/dev/null 2>&1`
# sem checar `$?` fazia uma `bd label remove` falha ficar indistinguível
# de sucesso pra quem chama. Ver main() pra como isto agora é usado.
strip_lock() {
  local rig="$1" id="$2" labels="$3" v ok=1
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    case "$v" in gate:needs-human*) : ;; *) continue ;; esac
    if [ "$DRY_RUN" != "1" ]; then
      "$BD" -C "$rig" label remove "$id" "$v" >/dev/null 2>&1 || ok=0
    fi
  done <<< "$labels"
  [ "$ok" = "1" ]
}

# note <rig> <bead> <texto> — registra a decisão NO bead. Sem isto, o
# auto-destrave vira mutação silenciosa e ninguém audita a regra.
# ⚠️ (revisor, gate-run ga-oaqy39, blocking issue 1): retorna o exit
# status real de `bd comment` (ou 0 em DRY_RUN) — mesmo motivo do
# strip_lock acima. Pior sub-caso que isto evita: strip_lock funciona
# (label removida de verdade) e note falha — sem isto, zero rastro de
# auditoria e o script ainda afirmava sucesso, exatamente o que este
# comentário original já dizia que "não pode" acontecer.
note() {
  [ "$DRY_RUN" = "1" ] && return 0
  "$BD" -C "$1" comment "$2" "$3" >/dev/null 2>&1
}

# ── as regras ──────────────────────────────────────────────────────────
# decide <rig> <bead> <labels-multilinha> → imprime "Rn|explicação". Não
# muta. <labels-multilinha> é a mesma lista já buscada por main() (ver
# fetch_labels) — reusada aqui pra contar gate-sha-failed:* sem mais uma
# chamada bd show.
decide() {
  local rig="$1" id="$2" labels="$3" br tip last_fail_epoch verdict

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
  # ⚠️ self-audit pré-gate (resubmissão): a versão anterior usava
  # `date -d "${d:-now}"` como fallback quando $d vinha vazio (sem veredito
  # FAIL, caso normal da armadilha D) — em qualquer host onde `date -d now`
  # tenha sucesso (GNU date; BSD date FALHA nisso, o que mascarava o bug
  # neste Mac), isso substitui silenciosamente "não sei/não há" pelo epoch
  # de AGORA, e last_fail_epoch nunca mais fica vazio — quebrando a própria
  # detecção de armadilha D mais abaixo. Sem "$d" não HÁ o que parsear:
  # sai vazio, sem tentar nenhum comando de data.
  #
  # ⚠️ self-audit ciclo 3 (revisor, ga-di6t52): `bd show --json` OMITE
  # comments por padrão — precisa de --include-comments explícito
  # (confirmado ao vivo contra o bd real: .comments ausente do JSON sem a
  # flag, mesmo em bead com comentário de verdade). Sem isto, tanto
  # last_fail_epoch quanto verdict (mais abaixo) ficavam SEMPRE vazios em
  # produção — R2 e R3 nunca disparavam, e a mensagem de armadilha D em R5
  # mentia pra TODO bead, inclusive os com veredito FAIL real registrado.
  # O selftest não pegou porque o shim de `bd` sempre devolvia comments,
  # flag ou não (ver nota em gate-auto-unblock.selftest.sh). Busca UMA
  # vez com a flag e reaproveita pro verdict abaixo — antes eram duas
  # chamadas bd show por bead, e --include-comments é documentadamente
  # mais custosa ("may be slow on issues with many comments").
  # ⚠️ self-audit final (mesma classe, agora aplicada a esta PRÓPRIA
  # chamada): captura show_rc — se este bd show falhar, last_fail_epoch
  # e verdict ficam vazios pelo MESMO motivo de "confirmei vazio", mas
  # aqui o motivo real é "não consegui checar". Não-destrutivo (R2/R3 já
  # ficam seguros com last_fail_epoch/verdict vazios, e R5 nunca muta) —
  # mas a MENSAGEM de R5 não pode dizer "nenhum veredito FAIL encontrado"
  # (que implica checagem bem-sucedida) quando na verdade a checagem nem
  # rodou. show_rc alimenta essa distinção na mensagem de R5 abaixo.
  local show_json show_rc
  show_json="$("$BD" -C "$rig" show "$id" --json --include-comments 2>/dev/null)"
  show_rc=$?
  last_fail_epoch="$(printf '%s' "$show_json" \
    | jq -r '[.[0].comments[]?|select((.text//"")|test("GATE-FEEDBACK|VERDICT: FAIL"))]|last|.created_at // empty' 2>/dev/null \
    | { read -r d; [ -n "${d:-}" ] || exit 0; date -j -f '%Y-%m-%dT%H:%M:%SZ' "$d" '+%s' 2>/dev/null || date -d "$d" '+%s' 2>/dev/null; })"

  tip="$(branch_tip_epoch "$rig" "$br")"

  # R2 — branch mudou depois da reprovação.
  if [ -n "$tip" ] && [ -n "${last_fail_epoch:-}" ] && [ "$tip" -gt "$last_fail_epoch" ] 2>/dev/null; then
    printf 'R2|branch %s tem commit posterior à última reprovação: o veredito fala de código que não existe mais' "$br"
    return 0
  fi

  # R4 antes de R3: se o mesmo ponto falhou N vezes, o problema é de
  # ESCOPO. Redespachar com instrução (R3) produziria a 5ª rodada.
  # Conta sobre $labels (já buscado por main()) — não mais bd show novo.
  local fails
  fails="$(printf '%s\n' "$labels" | grep -c '^gate-sha-failed:')"
  if [ "${fails:-0}" -ge 3 ]; then
    printf 'R4|%s reprovações registradas: escala de ESCOPO — exigir conserto de classe + teste estrutural, não mais um caso' "$fails"
    return 0
  fi

  # R3 — veredito nomeia trabalho delimitado.
  # Reaproveita show_json (buscado acima com --include-comments) — mesmo
  # bug/mesmo fix que last_fail_epoch, mesma chamada bd show.
  verdict="$(printf '%s' "$show_json" \
    | jq -r '[.[0].comments[]?|select((.text//"")|test("VERDICT: FAIL"))]|last|.text // empty' 2>/dev/null)"
  if printf '%s' "$verdict" | grep -qE '\.(py|sh|go|js|html|json)\b'; then
    # ⚠️ (revisor, gate-run ga-oaqy39, blocking issue 3): $verdict era
    # extraído e usado SÓ no teste grep -q acima — o texto nunca chegava
    # ao retorno de decide() nem ao comentário de main(), então
    # "redespachar COM a instrução do veredito" era uma alegação sem
    # efeito (comentário promete mais do que o código entrega). Sanitiza
    # pra UMA linha limitada — sem newline (main()'s `IFS='|' read -r
    # rule why <<<` só lê a primeira linha, um veredito real e
    # multi-linha truncaria em silêncio) e sem '|' (é o separador de
    # campo do protocolo Rn|why deste script) — e propaga de verdade.
    # ⚠️ (revisor, 2ª rodada adversarial): `cut -c1-200` é POR BYTE sob
    # LC_ALL=C (confirmado ao vivo neste host — locale desta cidade, e o
    # plist launchd nem seta LC_ALL/LANG, então herda C por padrão), não
    # por CARACTERE — um corte no meio de um caractere UTF-8 multi-byte
    # (ç, ã, é — este texto é majoritariamente PT-BR) produz bytes
    # inválidos que quebram o `jq` de QUALQUER leitura futura deste bead.
    # `iconv -f UTF-8 -t UTF-8 -c` descarta silenciosamente a sequência
    # incompleta ao final em vez de propagá-la — verificado empiricamente
    # (corte forçado no meio de "çã": sem isto vira erro de decode; com
    # isto, UTF-8 válido).
    local verdict_line
    verdict_line="$(printf '%s' "$verdict" | tr '\n' ' ' | tr '|' '-' | cut -c1-200 \
      | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null)"
    printf 'R3|veredito nomeia arquivo específico: trabalho delimitado, redespachar COM a instrução extraída — "%s"' "$verdict_line"
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
  if [ "$show_rc" -ne 0 ]; then
    r2_why='bd show --include-comments falhou — não dá pra confirmar se há ou não veredito FAIL, não é seguro presumir nenhum (distinto de armadilha D: aqui a checagem não RODOU)'
  elif [ -z "${last_fail_epoch:-}" ]; then
    r2_why='nenhum veredito FAIL encontrado nos comentários — o label pode ser espúrio (armadilha D: reprovação de processo, não de qualidade)'
  else
    r2_why='sem commit após a reprovação'
  fi
  printf 'R5|R1 não (branch %s tem trabalho único) · R2 não (%s) · R4 não (%s reprovações, abaixo de 3) · R3 não (veredito não nomeia arquivo)' "$br" "$r2_why" "${fails:-0}"
}

# apply_and_report <rig> <id> <labels> <rule> <why> <sucesso-sufixo> —
# chamada comum a R1-R4: strip_lock + note. Devolve 0 SÓ se as duas
# confirmarem sucesso de verdade (revisor, gate-run ga-oaqy39, blocking
# issue 1) — main() reporta FALHA em vez de contar como "destravada"
# quando qualquer uma falha, em vez do say/acted++ incondicional de antes.
# ⚠️ (revisor, 2ª rodada adversarial, achado D): o TEXTO do comentário é
# escolhido DEPOIS de strip_lock rodar, não antes — a versão anterior
# montava o texto de sucesso e mandava pro note() incondicionalmente,
# então mesmo quando o log do script já dizia "FALHA", o COMENTÁRIO
# PERMANENTE no bead ainda afirmava "labels removidos... nenhum humano
# precisou olhar". O rastro de auditoria tem que refletir o que
# REALMENTE aconteceu, não o que a regra pretendia fazer.
# ⚠️ (self-audit, achando o achado D próprio, ao escrever o teste): a
# PRIMEIRA correção passava o <sucesso-sufixo> JÁ MONTADO pra dentro da
# mensagem de FALHA também ("Tentativa era: ..."), pra dar contexto — mas
# esse sufixo de sucesso ("Nenhum humano precisou olhar") é EXATAMENTE o
# tipo de frase que um leitor futuro (humano ou automação fazendo
# substring-match) pode ler fora de contexto e concluir sucesso onde
# houve falha. Agora <rule>/<why> (a DECISÃO, neutra) são compartilhados
# entre os dois casos, e o sufixo de OUTCOME ("Nenhum humano precisou
# olhar", "Re-submeter ao gate", etc.) só entra na mensagem quando o
# sucesso é REAL — a mensagem de falha nunca contém frase de sucesso.
apply_and_report() {
  local rig="$1" id="$2" labels="$3" rule="$4" why="$5" success_suffix="$6"
  local strip_ok=1 note_ok=1 note_text
  strip_lock "$rig" "$id" "$labels" || strip_ok=0
  if [ "$strip_ok" = "1" ]; then
    note_text="AUTO-DESTRAVE $rule (ga-stu930): $why. $success_suffix"
  else
    note_text="AUTO-DESTRAVE $rule FALHOU (ga-stu930): $why — mas bd label remove falhou pra uma ou mais variantes gate:needs-human*; label(s) podem AINDA ESTAR PRESENTES, NÃO trate este bead como destravado."
  fi
  note "$rig" "$id" "$note_text" || note_ok=0
  [ "$strip_ok" = "1" ] && [ "$note_ok" = "1" ]
}

# ── varredura ──────────────────────────────────────────────────────────
main() {
  local rig id variant rule why n=0 acted=0 labels
  for rig in "$CITY" "${WA_RIG:-/Users/athos/gt/whatsapp_automation}" "${PS_RIG:-/Users/athos/gt/property_scrapers}"; do
    [ -d "$rig" ] || continue
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      n=$((n+1))
      # ⚠️ (revisor, 2ª rodada adversarial, achados A/B): labels buscadas
      # UMA vez aqui e propagadas — não mais uma chamada bd show por
      # função (lock_variant/has_protected_variant/strip_lock/decide
      # antes cada uma rebuscava, sem cache, criando uma corrida real
      # entre validar proteção e agir). Se a busca falhar, NÃO dá pra
      # confirmar proteção nem trabalho — pula o bead (a próxima
      # varredura tenta de novo), nunca trata "não consegui saber" como
      # "confirmei que está tudo bem".
      labels="$(fetch_labels "$rig" "$id")"
      if [ $? -ne 0 ]; then
        say "SKIP $id — bd show falhou ao buscar labels; não é seguro decidir sem confirmar o estado atual (próxima varredura tenta de novo)"
        continue
      fi
      variant="$(lock_variant "$labels")"
      if has_protected_variant "$labels"; then
        say "SKIP $id — carrega variante protegida (NAO TOCA) entre as labels gate:needs-human* presentes (pode coexistir com uma unblockable, ex. '$variant' — armadilha E); nenhuma label é tocada"
        continue
      fi
      IFS='|' read -r rule why <<< "$(decide "$rig" "$id" "$labels")"
      case "$rule" in
        R1)
          if apply_and_report "$rig" "$id" "$labels" "R1" "trava órfã — $why" "Labels de gate removidos; bead volta à fila. Nenhum humano precisou olhar."; then
            say "R1 $id — $why"; acted=$((acted+1))
          else
            say "FALHA R1 $id — bd label remove ou bd comment falhou (label pode ainda estar presente); verificar manualmente — $why"
          fi ;;
        R2)
          if apply_and_report "$rig" "$id" "$labels" "R2" "$why" "Re-submeter ao gate: o veredito anterior é sobre código que já mudou."; then
            say "R2 $id — $why"; acted=$((acted+1))
          else
            say "FALHA R2 $id — bd label remove ou bd comment falhou (label pode ainda estar presente); verificar manualmente — $why"
          fi ;;
        R3)
          if apply_and_report "$rig" "$id" "$labels" "R3" "$why" "Redespachado com a instrução do veredito, não com 'conserte'."; then
            say "R3 $id — $why"; acted=$((acted+1))
          else
            say "FALHA R3 $id — bd label remove ou bd comment falhou (label pode ainda estar presente); verificar manualmente — $why"
          fi ;;
        R4)
          if apply_and_report "$rig" "$id" "$labels" "R4" "$why" "⚠️ NÃO faça o 5º conserto pontual — o padrão de repetição É o achado. Exigir teste ESTRUTURAL, que trave a forma do código."; then
            say "R4 $id — $why"; acted=$((acted+1))
          else
            say "FALHA R4 $id — bd label remove ou bd comment falhou (label pode ainda estar presente); verificar manualmente — $why"
          fi ;;
        R5)
          if note "$rig" "$id" "AUTO-DESTRAVE R5 (ga-stu930): nenhuma regra decidiu — $why. Escalando ao Mayor COM o motivo, que é o que a trava antiga não fazia."; then
            say "R5 $id — escalado: $why"
          else
            say "FALHA R5 $id — bd comment falhou, escalação NÃO registrada no bead; verificar manualmente — $why"
          fi ;;
        *)
          say "ERRO $id — decide() não devolveu regra (saída: '$rule')" ;;
      esac
    done < <("$BD" -C "$rig" list --json --limit 0 2>/dev/null \
              | jq -r '.[]|select(.status!="closed")|select((.labels//[])|any(startswith("gate:needs-human")))|.id' 2>/dev/null)
  done
  say "gate-auto-unblock: $n travadas examinadas, $acted destravadas sem humano"
}

main "$@"
