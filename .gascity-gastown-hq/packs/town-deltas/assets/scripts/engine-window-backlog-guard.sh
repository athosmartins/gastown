#!/usr/bin/env bash
# engine-window-backlog-guard.sh (ga-jwb60)
#
# Watchdog RECORRENTE para docs/pending-engine-window/ -- a fila de patches do
# engine gascity esperando build+swap coordenado pelo Mayor. O conserto
# anterior (ga-3azujf) foi um scan manual, colado num comentário de bead, e
# fechado -- o buraco reabriu no mesmo dia (16 patches parados, 4 deles
# landados na MESMA data em que aquela bead fechou). Isto substitui "alguém
# lembra de medir" por uma checagem em cadência.
#
# TERCEIRO ESTADO (mesma doutrina de scripts/gate-queue-composition.sh): um
# patch cujo estado não dá pra ler (SRC_TREE ilegível, `git apply --check`
# falha nos dois sentidos) vai para ILEGÍVEL, nunca é dobrado silenciosamente
# em PENDENTE ou JÁ-LANDOU -- classificar o ilegível como uma das duas
# convidaria à decisão errada.
#
# PENDENTE vs JÁ-LANDOU -- o mecanismo que ga-3azujf não tinha: um arquivo
# .patch presente na pasta NÃO prova que o patch ainda não foi aplicado (ver
# ga-jfz9t1: bead fechada, patch de fato aplicado, arquivo só ficou
# esquecido). A prova real, contra o source vivo do engine:
#   git apply --check           <- aplica limpo   = PENDENTE
#   git apply --check --reverse <- reverte limpo  = JÁ-LANDOU, deve sair da fila
# Um arquivo já com sufixo .APLICADO-<data>/.SUPERSEDED-<data> é MARCADO --
# já foi resolvido por um humano/processo, não passa pelo apply-check (o
# conteúdo pode nem ser mais um diff válido).
#
# DETECTION-ONLY, por desenho e por doutrina (build+swap é Mayor-scope): todo
# `git apply` nesta ordem inteira roda SOMENTE com --check -- nunca aplica de
# verdade, nunca builda, nunca troca binário, nunca dá kickstart no
# supervisor (ver selftest #2, que garante isto na fonte, não só no
# comportamento).
#
# Custo de poll: lock de instância única (idêntico ao idioma de
# gate-auto-unblock.sh -- ver ga-y0g5x: 4 instâncias simultâneas de um guard
# sem lock derrubaram o bd da cidade inteira) + cooldown de alerta
# (notify_once, idêntico ao idioma de stale-persistent-daemon-guard.sh -- ver
# ga-2uz59: 85 mails idênticos em 10h). Roda como gc order (cooldown, exec
# fresco a cada tick) -- nunca um plist cru, pra este guard nunca virar
# membro da classe de bug que observa.
#
# A composição completa é sempre impressa (a cada run); só o NOTIFY é
# cooldown-gated -- "o corte é no aviso, não na medição" (mesmo princípio do
# fix ga-2uz59 no mol-dog-doctor.sh).
#
# ga-0ehtp: também censa a pasta ERRADA -- UM NÍVEL ACIMA de CITY (ex.:
# ~/gt/docs/pending-engine-window/ quando CITY é ~/gt/.gascity-gastown-hq).
# 5 ocorrências medidas: a doutrina em town-deltas.template.md manda commitar
# o patch num caminho RELATIVO, que resolve pra cima ou pro lugar certo
# dependendo do cwd de quem commita -- os dois "seguem a instrução" (ver
# memória engine-patch-town-root-invisible-to-window). Isto é só detecção:
# nunca move o arquivo (mover sem saber distinguir "stageado errado" de
# "deliberadamente fora da fila" quebra coisa boa) -- alarma e deixa o Mayor
# decidir.
#
# Uso: bash engine-window-backlog-guard.sh [--json]
set -uo pipefail

JSON_OUT=0
[ "${1:-}" = "--json" ] && JSON_OUT=1

CITY="${GC_CITY_PATH:-${GC_CITY:-.}}"
[ -d "$CITY/.beads" ] || { echo "ERRO: '$CITY' não parece a raiz da HQ (sem .beads/). Setei GC_CITY_PATH?" >&2; exit 2; }
# Absolutiza AGORA, antes de derivar qualquer path a partir de CITY (gate-
# feedback ga-tae4f): sem isto, CITY fica relativo sempre que GC_CITY_PATH/
# GC_CITY não estão setados (default "."), e todo $f do loop abaixo herda
# essa relatividade. O `git -C "$SRC_TREE" apply --check "$f"` mais abaixo faz
# um chdir REAL para $SRC_TREE antes de resolver $f -- um $f relativo então
# resolve contra $SRC_TREE, não contra CITY onde o arquivo de fato mora, e o
# apply falha nos dois sentidos (forward e reverse), classificando todo
# PENDENTE real como ILEGÍVEL. Resolver aqui, uma única vez, corrige todo uso
# de $CITY abaixo (PATCH_DIR, STATE_DIR, LOCK_FILE) de uma vez.
CITY=$(cd "$CITY" && pwd) || { echo "ERRO: não consegui resolver '$CITY' como caminho absoluto." >&2; exit 2; }
PATCH_DIR="$CITY/docs/pending-engine-window"

# ga-0ehtp: um patch stageado UM NÍVEL ACIMA de CITY é invisível a esta
# própria janela -- 5 ocorrências medidas, a última duas vezes no mesmo
# minuto por dogs diferentes (ver memória
# engine-patch-town-root-invisible-to-window). Derivado como "um nível acima
# de $CITY" (não hardcoded pra ~/gt) para nunca poder divergir da definição
# de PATCH_DIR -- os dois vêm da mesma variável, então um agente cujo
# GC_CITY_PATH aponte pra outro clone/town ainda tem o par correto.
WRONG_PATCH_DIR="$(dirname "$CITY")/docs/pending-engine-window"

# Fonte de verdade do engine gascity -- ver memória
# gascity-engine-locally-buildable-src-hookfix: NÃO é ~/gt/gastown (projeto
# homônimo diferente), é este caminho. Overridable só para teste.
SRC_TREE="${ENGINE_WINDOW_GUARD_SRC_TREE:-/Users/athos/gt/.local-patches/_src-hookfix}"

STATE_DIR="${GC_PACK_STATE_DIR:-${GC_CITY_RUNTIME_DIR:-$CITY/.gc/runtime}/packs/maintenance}"
SEEN_FILE="${ENGINE_WINDOW_GUARD_SEEN_FILE:-$STATE_DIR/engine-window-backlog-guard-seen.json}"
ESCALATE_AFTER_S="${ENGINE_WINDOW_GUARD_ESCALATE_AFTER_S:-86400}"        # 24h re-fire
SIZE_THRESHOLD="${ENGINE_WINDOW_GUARD_SIZE_THRESHOLD:-10}"
AGE_THRESHOLD_S="${ENGINE_WINDOW_GUARD_AGE_THRESHOLD_S:-604800}"         # 7 dias (doutrina: "patch apodrecendo 7+ dias")
LOCK_FILE="${ENGINE_WINDOW_GUARD_LOCK:-$CITY/.gc/runtime/engine-window-backlog-guard.lock}"
GIT_BIN="${GIT_BIN:-git}"
NOTIFY_BIN="${NOTIFY_BIN:-notify}"
NOW=$(date +%s)

# ── lock de instância única (ga-y0g5x) -- antes de QUALQUER trabalho real ──
# NUNCA adicione "2>/dev/null" neste `exec N>arquivo`: como é um `exec` sem
# comando (não um subshell), o redirect fica preso no fd da shell atual pro
# resto do script inteiro -- silenciaria todo `>&2` seguinte, inclusive o
# ERRO do check de SRC_TREE logo abaixo (achado rodando o selftest #10 de
# verdade: exit 2 correto, mensagem ERRO sumida).
mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
exec 9>"$LOCK_FILE" || { echo "engine-window-backlog-guard: não consegui abrir $LOCK_FILE para lock -- saindo (fail-safe, não roda sem garantia de instância única)"; exit 0; }
flock -n 9 || { echo "engine-window-backlog-guard: outra instância já rodando (lock $LOCK_FILE) -- saindo"; exit 0; }

if ! "$GIT_BIN" -C "$SRC_TREE" rev-parse --git-dir >/dev/null 2>&1; then
    echo "ERRO: SRC_TREE '$SRC_TREE' não é um repo git legível -- não dá pra classificar PENDENTE/JÁ-LANDOU de nada. Isto é ILEGÍVEL, não 'fila vazia'." >&2
    exit 2
fi

mkdir -p "$STATE_DIR" 2>/dev/null || true
[ -f "$SEEN_FILE" ] || echo '{}' > "$SEEN_FILE" 2>/dev/null || true
SEEN_JSON=$(cat "$SEEN_FILE" 2>/dev/null || echo '{}')
[ -n "$SEEN_JSON" ] || SEEN_JSON='{}'

# Cooldown de alerta -- mesma forma de stale-persistent-daemon-guard.sh:
# dispara no máximo 1x por ESCALATE_AFTER_S por chave. Só governa o NOTIFY;
# a medição/composição acima nunca é suprimida.
notify_once() {
    local key="$1" title="$2" body="$3" last
    last=$(printf '%s' "$SEEN_JSON" | jq -r --arg k "$key" '.[$k] // 0' 2>/dev/null || echo 0)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ "$last" != "0" ] && [ $(( NOW - last )) -lt "$ESCALATE_AFTER_S" ]; then
        return 1
    fi
    "$NOTIFY_BIN" -t "$title" -p 3 "$body" >/dev/null 2>&1 || true
    SEEN_JSON=$(printf '%s' "$SEEN_JSON" | jq --arg k "$key" --argjson n "$NOW" '.[$k] = $n' 2>/dev/null) || true
    [ -n "$SEEN_JSON" ] || SEEN_JSON='{}'
    return 0
}

TOTAL=0; PENDING=0; LANDED=0; UNKNOWN=0; MARKED=0; OTHER=0
PENDING_L=""; LANDED_L=""; UNKNOWN_L=""; MARKED_L=""; OTHER_L=""
OLDEST_BACKLOG_AGE=0
OLDEST_BACKLOG_ID=""

# Itera TODOS os arquivos da pasta (não só *.patch*) para que um artefato de
# tipo novo (ex.: um .sh ou .md ainda sem sufixo, como já existem casos
# JÁ-marcados em produção: ga-jx6pvl-compact-run.sh.APLICADO-*) nunca fique
# invisível ao censo -- cai em OUTRO em vez de simplesmente não ser contado
# em lugar nenhum (AC1: "reporta a composição, não só a contagem").
shopt -s nullglob
for f in "$PATCH_DIR"/*; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    relpath="docs/pending-engine-window/$base"

    case "$base" in
        *.patch.APLICADO-*|*.patch.SUPERSEDED-*)
            # Já resolvido por humano/processo -- não tenta ler como diff.
            TOTAL=$((TOTAL+1))
            MARKED=$((MARKED+1)); MARKED_L="$MARKED_L\n    $base"
            continue
            ;;
        *.patch)
            TOTAL=$((TOTAL+1))
            ;;
        *)
            # Não é um .patch nem um .patch já marcado -- tipo de artefato que
            # este guard não sabe classificar (ex.: RECIPE.md, .sh cru). Conta
            # à parte, nunca dobra em PENDENTE/LANDOU/ILEGÍVEL por omissão.
            OTHER=$((OTHER+1)); OTHER_L="$OTHER_L\n    $base"
            continue
            ;;
    esac

    age_epoch=$("$GIT_BIN" -C "$CITY" log --format=%at -- "$relpath" 2>/dev/null | tail -1)
    case "$age_epoch" in ''|*[!0-9]*) age_epoch="$NOW" ;; esac
    age_s=$(( NOW - age_epoch ))
    age_d=$(( age_s / 86400 ))

    # Único mecanismo NOVO desta ordem (sem precedente no repo): a prova
    # PENDENTE-vs-JÁ-LANDOU via git apply --check/--reverse contra o source
    # vivo. Ambos SEMPRE com --check -- nunca muta SRC_TREE de verdade
    # (garantido também estaticamente, ver selftest #2).
    forward_ok=0; reverse_ok=0
    "$GIT_BIN" -C "$SRC_TREE" apply --check "$f" >/dev/null 2>&1 && forward_ok=1
    "$GIT_BIN" -C "$SRC_TREE" apply --check --reverse "$f" >/dev/null 2>&1 && reverse_ok=1

    if [ "$forward_ok" = "1" ] && [ "$reverse_ok" = "0" ]; then
        PENDING=$((PENDING+1)); PENDING_L="$PENDING_L\n    $base  (${age_d}d)"
        [ "$age_s" -gt "$OLDEST_BACKLOG_AGE" ] && { OLDEST_BACKLOG_AGE=$age_s; OLDEST_BACKLOG_ID=$base; }
    elif [ "$forward_ok" = "0" ] && [ "$reverse_ok" = "1" ]; then
        LANDED=$((LANDED+1)); LANDED_L="$LANDED_L\n    $base  (${age_d}d) -- já está na árvore, deve sair da fila"
    else
        # Cobre tanto "nem aplica nem reverte" (drift/conflito real) quanto o
        # caso raro "os dois lados aplicam limpo" (patch vazio/anômalo) --
        # ambos são ilegíveis com confiança, não um PENDENTE ou LANDOU forçado.
        UNKNOWN=$((UNKNOWN+1)); UNKNOWN_L="$UNKNOWN_L\n    $base  (${age_d}d) -- nem aplica nem reverte limpo, olhe de novo"
        [ "$age_s" -gt "$OLDEST_BACKLOG_AGE" ] && { OLDEST_BACKLOG_AGE=$age_s; OLDEST_BACKLOG_ID=$base; }
    fi
done
shopt -u nullglob

# ga-0ehtp: censo da pasta ERRADA (só *.patch cru -- um patch fresco
# stageado no lugar certo por engano, nunca um .patch.APLICADO-*/.SUPERSEDED-*
# já resolvido, que não faz sentido aparecer ali por este mecanismo). Leitura
# apenas -- nunca rm/mv (ver selftest #15, que garante isto na fonte).
WRONG_LOC=0
WRONG_LOC_L=""
WRONG_LOC_FIRST=""
shopt -s nullglob
for f in "$WRONG_PATCH_DIR"/*.patch; do
    [ -f "$f" ] || continue
    wb=$(basename "$f")
    WRONG_LOC=$((WRONG_LOC+1))
    WRONG_LOC_L="$WRONG_LOC_L\n    $wb"
    [ -n "$WRONG_LOC_FIRST" ] || WRONG_LOC_FIRST="$wb"
done
shopt -u nullglob

# "Fila" para efeito de limiar = PENDENTE + ILEGÍVEL -- os dois ainda exigem
# ação (uma janela de engine, ou um humano olhando o conflito). JÁ-LANDOU é
# limpeza de arquivo, não bloqueio, e não empurra o alerta.
BACKLOG=$((PENDING + UNKNOWN))
BREACHED=0
if [ "$BACKLOG" -gt "$SIZE_THRESHOLD" ] || [ "$OLDEST_BACKLOG_AGE" -gt "$AGE_THRESHOLD_S" ]; then
    BREACHED=1
fi

if [ "$JSON_OUT" = "1" ]; then
    printf '{"total":%d,"pending":%d,"landed":%d,"unknown":%d,"marked":%d,"other":%d,"backlog":%d,"oldest_backlog_age_s":%d,"threshold_breached":%s,"wrong_location_count":%d}\n' \
        "$TOTAL" "$PENDING" "$LANDED" "$UNKNOWN" "$MARKED" "$OTHER" "$BACKLOG" "$OLDEST_BACKLOG_AGE" \
        "$([ "$BREACHED" = "1" ] && echo true || echo false)" \
        "$WRONG_LOC"
else
    echo "═══ COMPOSIÇÃO docs/pending-engine-window ═══"
    echo "  total de arquivos (patch):  $TOTAL"
    echo "  PENDENTE:   $PENDING   <- aplica limpo contra $SRC_TREE, responde a uma janela de engine"
    echo "  ILEGÍVEL:   $UNKNOWN   <- nem aplica nem reverte limpo, olhe de novo"
    echo "  JÁ LANDOU:  $LANDED   <- reverse-check limpo, é limpeza de arquivo, não bloqueio"
    echo "  MARCADO:    $MARKED   <- sufixo .APLICADO/.SUPERSEDED, já resolvido"
    echo "  OUTRO:      $OTHER   <- não é .patch nem .patch marcado, fora do censo acima"
    # %b (não a var como FORMAT direto -- gate-feedback ga-tae4f secundário):
    # ainda expande os \n literais acumulados acima em newline real, mas um
    # '%' num nome de arquivo de patch fica como dado, nunca reinterpretado
    # como novo especificador de formato.
    [ -n "$PENDING_L" ] && { echo; echo "  PENDENTE:"; printf '%b\n' "$PENDING_L"; }
    [ -n "$UNKNOWN_L" ] && { echo; echo "  ILEGÍVEL:"; printf '%b\n' "$UNKNOWN_L"; }
    [ -n "$LANDED_L" ]  && { echo; echo "  JÁ LANDOU:"; printf '%b\n' "$LANDED_L"; }
    [ -n "$MARKED_L" ]  && { echo; echo "  MARCADO:"; printf '%b\n' "$MARKED_L"; }
    [ -n "$OTHER_L" ]   && { echo; echo "  OUTRO:"; printf '%b\n' "$OTHER_L"; }
    [ "$WRONG_LOC" -gt 0 ] && { echo; echo "  🚨 LOCALIZAÇÃO ERRADA ($WRONG_PATCH_DIR): $WRONG_LOC   <- INVISÍVEL à janela, mova para $PATCH_DIR"; printf '%b\n' "$WRONG_LOC_L"; }
fi

if [ "$BREACHED" = "1" ]; then
    oldest_d=$(( OLDEST_BACKLOG_AGE / 86400 ))
    age_threshold_d=$(( AGE_THRESHOLD_S / 86400 ))
    notify_once "engine-window-backlog" "Fila de engine window passou do limiar" \
        "docs/pending-engine-window: $BACKLOG pendente(s)/ilegível(is) (limiar $SIZE_THRESHOLD), mais antigo ($OLDEST_BACKLOG_ID) há ${oldest_d}d (limiar ${age_threshold_d}d)." \
        >/dev/null || true
fi

# ga-0ehtp: independente do limiar de tamanho/idade -- UM patch já na pasta
# errada já é o bug inteiro (é invisível a QUALQUER janela, não só a uma
# fila grande). Chave de dedup própria, mesmo notify_once/cooldown das
# outras (ESCALATE_AFTER_S) -- sem parâmetro novo, sem risco pro
# comportamento já testado dos outros dois alarmes.
if [ "$WRONG_LOC" -gt 0 ]; then
    notify_once "engine-window-wrong-location" "Patch de engine na pasta ERRADA" \
        "$WRONG_PATCH_DIR tem $WRONG_LOC patch(es) INVISÍVEL(EIS) à janela -- mova para $PATCH_DIR. Ex.: $WRONG_LOC_FIRST" \
        >/dev/null || true
fi

echo "$SEEN_JSON" > "$SEEN_FILE" 2>/dev/null || true
exit 0
