#!/usr/bin/env bash
# engine-binary-backup-guard.sh (ga-ta2w6r)
#
# Detector RECORRENTE de "o que RODA nao tem backup". O caso medido em 20/09/2026:
# a branch consolidated/engine-window-20260919 tinha 12 commits em nenhum remoto
# (~20 patches de tres janelas) e o binario que a cidade inteira rodava foi
# compilado do topo dela -- a unica copia da fonte era um diretorio, numa
# maquina cujo disco bateu 2 GB livres no mesmo dia. Ninguem notou a 0906 ficar
# duas semanas assim: nao havia NENHUM passo nem detector para isso.
#
# O TESTE FORTE e o do binario, nao o do nome de branch: pergunta "o commit de
# que o binario EM USO deriva esta em algum remoto?" e por isso pega o caso
# mesmo se alguem renomear a branch ou compilar de outro worktree.
#   A) binarios vivos: gc (o alvo do symlink) e bd. Le o stamp que o PROPRIO
#      binario declara (main.commit / main.Build) e consulta o repo-fonte.
#   B) branches consolidated/engine-window-* do repo do engine -- indicador
#      ANTECIPADO (pega antes do build). So alarma a branch mais nova e as que
#      estao checadas em worktrees .../engine-window-*, e so depois de uma
#      carencia (BRANCH_GRACE_S: consolidar leva tempo, e nao e "esquecimento");
#      as antigas entram no relatorio como INFO (a 0823, por ex., existe so
#      neste disco, mas foi superada e nao roda -- alarmar nela pra sempre so
#      ensinaria a ignorar o guard). Roda mesmo se o binario vivo der problema.
#
# QUAL STAMP CONFIAR: ver o cabecalho de lib/engine-backup-lib.sh. Em uma linha:
# vcs.revision/-dirty dos binarios compilados em `git worktree` descrevem o repo
# ERRADO (~/gt), entao NAO sao lidos aqui -- so main.commit / main.Build.
#
# ESTADOS (mesma doutrina de gate-queue-composition.sh e do guard irmao
# engine-window-backlog-guard.sh: tres estados, nunca colapsados em booleano):
#   OK        um ref remoto contem o commit
#   MISSING   o commit so existe neste disco               -> alarme na hora (p4)
#   ORPHAN    o commit nem existe no repo-fonte            -> alarme na hora (p4)
#   UNSTAMPED o binario nao declara commit                 -> alarme na hora (p3)
#   UNKNOWN   nao consegui saber (rede, repo ilegivel)     -> alarma so apos
#             UNKNOWN_STREAK execucoes SEGUIDAS (default 3 = ~3h): um detector
#             que cala em duvida e um detector que nao existe, mas um que grita
#             a cada tremida de rede vira ruido que ninguem le.
# MISSING/ORPHAN so saem depois de um fetch que DEU CERTO (ver a lib).
#
# O guard tambem nao cala quando fica CEGO: fetch falhando (contado; alarma apos
# UNKNOWN_STREAK execucoes seguidas -- as evidencias positivas viram "velhas"),
# falha ao enumerar branches/worktrees (linha UNKNOWN visivel, mesma regra de
# sequencia) e falha ao gravar o estado (aviso alto no stderr) aparecem no
# veredito, contados -- nunca um "nada a reportar" quieto.
#
# DETECTION-ONLY, por desenho: nunca empurra, builda, troca binario, faz checkout
# nem apaga nada. O selftest prova isso pelo que o guard EXECUTA (um git de mentira
# registra cada subcomando, em todos os cenarios); grep no codigo confundiria o
# texto do alerta ("git push origin ...") com um comando. O unico efeito no
# repo-fonte e `fetch --prune`: atualiza/remove refs/remotes/*, traz objetos e
# reescreve .git/FETCH_HEAD -- nunca toca branch, tag, worktree ou index.
# Empurrar e o passo da janela (scripts/engine-window-run.sh push) -- este guard
# so avisa quando esse passo nao aconteceu.
#
# Custo de poll (ga-y0g5x: 4 instancias simultaneas de um guard sem lock
# derrubaram o bd da cidade inteira): lock de instancia unica + cooldown de
# alerta (notify_once, 24h). Roda como gc order (cooldown 1h, exec fresco), nunca
# plist cru. Diferenca deliberada do guard irmao: se o `flock` NAO EXISTE este
# script recusa (exit 2, alto) em vez de sair calado -- "nao consegui travar" nao
# e "outra instancia esta rodando", e o segundo estado esconderia um guard morto.
#
# Uso: bash engine-binary-backup-guard.sh [--json]
set -uo pipefail

# O `gc order` pode entregar um PATH magro (launchd: /usr/bin:/bin). O guard precisa
# de flock/jq/timeout/go (Homebrew) e do notify (~/.local/bin): sem eles ele
# recusaria (flock) ou perderia o alarme (notify). Estes diretorios entram como
# FALLBACK, no FIM do PATH: nunca mandam mais que o PATH de quem chamou (um PATH que
# ja tem o Homebrew na frente segue igual; um shim de teste continua ganhando).
# EB_GUARD_EXTRA_PATH sobrescreve (vazio desliga) so pro selftest poder simular a
# AUSENCIA de uma ferramenta.
_EB_EXTRA_PATH="${EB_GUARD_EXTRA_PATH-/opt/homebrew/bin:$HOME/.local/bin:/usr/local/bin}"
[ -n "$_EB_EXTRA_PATH" ] && PATH="$PATH:$_EB_EXTRA_PATH"

JSON_OUT=0
[ "${1:-}" = "--json" ] && JSON_OUT=1

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Um detector horario nao pode ficar pendurado num fetch: 60s por remoto (a lib
# usa 90s por default; o valor so vale se o ambiente nao o definir antes).
EB_FETCH_TIMEOUT_S="${EB_FETCH_TIMEOUT_S:-60}"
# shellcheck source=lib/engine-backup-lib.sh
. "$SELF_DIR/lib/engine-backup-lib.sh" || { echo "ERRO: nao consegui carregar $SELF_DIR/lib/engine-backup-lib.sh" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "ERRO: jq nao encontrado no PATH -- o guard nao roda sem estado/JSON." >&2; exit 2; }
command -v flock >/dev/null 2>&1 || { echo "ERRO: flock nao encontrado no PATH -- recusando rodar sem garantia de instancia unica (ga-y0g5x). NAO e 'outra instancia rodando'." >&2; exit 2; }

CITY="${GC_CITY_PATH:-${GC_CITY:-.}}"
[ -d "$CITY/.beads" ] || { echo "ERRO: '$CITY' nao parece a raiz da HQ (sem .beads/). Setei GC_CITY_PATH?" >&2; exit 2; }
CITY=$(cd "$CITY" && pwd) || { echo "ERRO: nao consegui resolver '$CITY' como caminho absoluto." >&2; exit 2; }

# ---- o que vigiar (tudo sobrescrevivel: e assim que o selftest usa fixtures) ----
GC_LINK="${GC_BIN_LINK:-/opt/homebrew/bin/gc}"
GC_SRC="${ENGINE_WINDOW_GUARD_SRC_TREE:-/Users/athos/gt/.local-patches/_src-hookfix}"
BD_BIN="${ENGINE_BACKUP_GUARD_BD_BIN:-$HOME/.local/bin/bd}"
BD_SRC="${BD_SRC_ROOT:-/Users/athos/gt/beads}"
# Uma linha por artefato: nome|tipo(gc|bd)|binario|repo-fonte
ARTIFACTS="${ENGINE_BACKUP_GUARD_ARTIFACTS:-gc|gc|$GC_LINK|$GC_SRC
bd|bd|$BD_BIN|$BD_SRC}"
BRANCH_GLOB="${ENGINE_BACKUP_GUARD_BRANCH_GLOB:-consolidated/engine-window-*}"
BRANCH_GRACE_S="${ENGINE_BACKUP_GUARD_BRANCH_GRACE_S:-3600}"      # 1h: consolidando nao e "esquecido"
UNKNOWN_STREAK="${ENGINE_BACKUP_GUARD_UNKNOWN_STREAK:-3}"
ESCALATE_AFTER_S="${ENGINE_BACKUP_GUARD_ESCALATE_AFTER_S:-86400}"  # 24h re-fire
STATE_DIR="${GC_PACK_STATE_DIR:-${GC_CITY_RUNTIME_DIR:-$CITY/.gc/runtime}/packs/maintenance}"
SEEN_FILE="${ENGINE_BACKUP_GUARD_SEEN_FILE:-$STATE_DIR/engine-binary-backup-guard-seen.json}"
LOCK_FILE="${ENGINE_BACKUP_GUARD_LOCK:-$CITY/.gc/runtime/engine-binary-backup-guard.lock}"
NOTIFY_BIN="${NOTIFY_BIN:-notify}"
NOW=$(date +%s)
US=$(printf '\037')   # separador de campo nao-branco: IFS de tab/espaco engole campo vazio

# ---- lock de instancia unica -- antes de QUALQUER trabalho real ----
# NUNCA ponha "2>/dev/null" neste `exec N>arquivo`: sem comando, o redirect fica
# preso no fd da shell inteira e silenciaria todo `>&2` seguinte.
mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
exec 9>"$LOCK_FILE" || { echo "engine-binary-backup-guard: nao consegui abrir $LOCK_FILE para lock (exit 2, nao e 'outra instancia')." >&2; exit 2; }
flock -n 9 || { echo "engine-binary-backup-guard: outra instancia ja rodando (lock $LOCK_FILE) -- saindo"; exit 0; }

mkdir -p "$STATE_DIR" 2>/dev/null || true
[ -f "$SEEN_FILE" ] || echo '{}' > "$SEEN_FILE" 2>/dev/null || true
SEEN_JSON=$(cat "$SEEN_FILE" 2>/dev/null || echo '{}')
[ -n "$SEEN_JSON" ] || SEEN_JSON='{}'
# Estado ilegivel: recomeca do zero. Pior caso REAL: um re-alerta a mais E as sequencias
# de UNKNOWN recomecam (o alarme por incerteza atrasa ate UNKNOWN_STREAK execucoes).
# MISSING/ORPHAN/UNSTAMPED nao dependem de estado: esses alarmes nunca se perdem por aqui.
printf '%s' "$SEEN_JSON" | jq -e . >/dev/null 2>&1 || SEEN_JSON='{}'

# Cooldown de alerta -- so governa o NOTIFY; a medicao e o relatorio nunca sao suprimidos.
# O cooldown so e CARIMBADO depois que o notify confirma a entrega (exit 0). Sem isso,
# um notify ausente ou com falha de rede carimbaria "avisado" e calaria o alarme por
# 24h -- tentativa nao e entrega. Falha -> aviso no stderr, contador NOTIFY_FAILED
# (sai no veredito e no JSON) e nova tentativa na proxima execucao.
NOTIFY_FAILED=0
notify_once() {
    local key="$1" title="$2" body="$3" prio="${4:-3}" last nb
    last=$(printf '%s' "$SEEN_JSON" | jq -r --arg k "notify:$key" '.[$k] // 0' 2>/dev/null) || last=0
    case "$last" in '' | *[!0-9]*) last=0 ;; esac
    if [ "$last" != "0" ] && [ $((NOW - last)) -lt "$ESCALATE_AFTER_S" ]; then
        return 1
    fi
    nb=$(command -v "$NOTIFY_BIN" 2>/dev/null) || nb=""
    if [ -z "$nb" ]; then
        echo "AVISO: notify ('$NOTIFY_BIN') nao encontrado -- ALARME NAO ENTREGUE: $title" >&2
        NOTIFY_FAILED=$((NOTIFY_FAILED + 1))
        return 1
    fi
    if ! "$nb" -t "$title" -p "$prio" "$body" >/dev/null 2>&1; then
        echo "AVISO: notify falhou (exit != 0) -- ALARME NAO CONFIRMADO, tento de novo na proxima execucao: $title" >&2
        NOTIFY_FAILED=$((NOTIFY_FAILED + 1))
        return 1
    fi
    SEEN_JSON=$(printf '%s' "$SEEN_JSON" | jq --arg k "notify:$key" --argjson n "$NOW" '.[$k] = $n' 2>/dev/null) || true
    [ -n "$SEEN_JSON" ] || SEEN_JSON='{}'
    return 0
}

# UNKNOWN seguido: contador persistido. Resultado em STREAK_N (nao use $(...):
# subshell perderia a atualizacao de SEEN_JSON).
STREAK_N=0
streak_bump() {
    local n
    n=$(printf '%s' "$SEEN_JSON" | jq -r --arg k "streak:$1" '.[$k] // 0' 2>/dev/null) || n=0
    case "$n" in '' | *[!0-9]*) n=0 ;; esac
    STREAK_N=$((n + 1))
    SEEN_JSON=$(printf '%s' "$SEEN_JSON" | jq --arg k "streak:$1" --argjson n "$STREAK_N" '.[$k] = $n' 2>/dev/null) || true
    [ -n "$SEEN_JSON" ] || SEEN_JSON='{}'
}
streak_reset() {
    SEEN_JSON=$(printf '%s' "$SEEN_JSON" | jq --arg k "streak:$1" 'del(.[$k])' 2>/dev/null) || true
    [ -n "$SEEN_JSON" ] || SEEN_JSON='{}'
}

ALARMS=0
UNKNOWNS=0
ROWS=""
FETCH_NOTES=""
FETCHED_REPO=""   # repo cujo fetch ja rodou nesta execucao (um fetch por repo por run)
# kind US nome US commit US estado US detalhe US alarme(0/1) US escopo US binario
add_row() { ROWS="${ROWS}${1}${US}${2}${US}${3}${US}${4}${US}${5}${US}${6}${US}${7}${US}${8}
"; }

FETCH_FAILS=0
# Fetch que falha nao e "sem novidade": e o guard ficando CEGO para pushes e
# apagamentos novos (as evidencias positivas passam a ser 'velhas'). Visivel no
# relatorio, contado no veredito, e alarma apos UNKNOWN_STREAK execucoes seguidas.
note_fetch() {   # <rotulo> <repo>   (le EB_FETCH_STATE/EB_FETCH_NOTE do ultimo eb_fetch_all)
    FETCH_NOTES="${FETCH_NOTES}  [$1] $EB_FETCH_NOTE
"
    if [ "$EB_FETCH_STATE" = "failed" ]; then
        FETCH_FAILS=$((FETCH_FAILS + 1))
        streak_bump "fetch:$2"
        if [ "$STREAK_N" -ge "$UNKNOWN_STREAK" ]; then
            ALARMS=$((ALARMS + 1))
            notify_once "fetch:$2" "Guard de backup CEGO: fetch falhando em $1 ha $STREAK_N execucoes" \
                "$EB_FETCH_NOTE (repo $2). Sem fetch o guard so ve refs velhas: pushes e apagamentos novos passam despercebidos." 3 >/dev/null || true
        fi
    else
        streak_reset "fetch:$2"
    fi
}
# Falha ao ENUMERAR (worktrees/branches) tambem e terceiro estado: vira uma linha
# UNKNOWN visivel, com a mesma regra de sequencia -- nunca "nao ha branches".
list_failed() {   # <chave> <detalhe>
    local balarm=0
    UNKNOWNS=$((UNKNOWNS + 1))
    streak_bump "$1"
    if [ "$STREAK_N" -ge "$UNKNOWN_STREAK" ]; then
        balarm=1
        ALARMS=$((ALARMS + 1))
        notify_once "$1" "Guard de backup: nao consigo enumerar as branches da janela ha $STREAK_N execucoes" "$2" 3 >/dev/null || true
    fi
    add_row branch "($1)" "" UNKNOWN "$2" "$balarm" "listagem" ""
}

# ---------------- A) binarios vivos ----------------
while IFS='|' read -r name kind bin repo <&3; do
    [ -n "$name" ] || continue
    real=$(readlink -f "$bin" 2>/dev/null) || real=""
    [ -n "$real" ] || real="$bin"
    commit=""
    alarm=0
    if [ ! -x "$real" ]; then
        state="UNKNOWN"
        detail="binario nao encontrado/executavel: $bin"
    elif ! commit=$(eb_binary_commit "$real" "$kind"); then
        state="UNSTAMPED"
        detail="$real nao declara commit (ldflags main.commit/main.Build): nao da pra provar backup"
    else
        eb_fetch_all "$repo"
        FETCHED_REPO="$repo"
        note_fetch "$name" "$repo"
        r=$(eb_backup_state "$repo" "$commit")
        state="${r%%|*}"
        detail="${r#*|}"
    fi

    case "$state" in
        OK)
            streak_reset "art:$name"
            ;;
        MISSING)
            alarm=1
            hint=$(eb_branch_hint "$repo" "$commit")
            notify_once "art:$name:$commit:$state" "Engine SEM backup: $name roda de commit fora de qualquer remoto" \
                "$name ($real) deriva do commit $commit, que NENHUM remoto contem: a fonte do que roda so existe neste disco, e um incidente de disco a perde. Empurre: git -C $repo push origin ${hint:-<branch que contem $commit>}." 4 >/dev/null || true
            ;;
        ORPHAN)
            alarm=1
            notify_once "art:$name:$commit:$state" "Engine SEM fonte rastreavel: $name" \
                "$name ($real) deriva do commit $commit, que nem existe no repo-fonte $repo (nem apos fetch): a fonte pode nao existir em lugar nenhum. Compilou de outro checkout? Ache-o e empurre." 4 >/dev/null || true
            ;;
        UNSTAMPED)
            alarm=1
            notify_once "art:$name:unstamped:$real" "Binario $name sem commit rastreavel" \
                "$detail" 3 >/dev/null || true
            ;;
        *)
            UNKNOWNS=$((UNKNOWNS + 1))
            streak_bump "art:$name"
            if [ "$STREAK_N" -ge "$UNKNOWN_STREAK" ]; then
                alarm=1
                notify_once "art:$name:unknown" "Nao consigo verificar o backup de $name ha $STREAK_N execucoes" \
                    "$detail" 3 >/dev/null || true
            fi
            ;;
    esac
    [ "$alarm" = "1" ] && ALARMS=$((ALARMS + 1))
    add_row artifact "$name" "$commit" "$state" "$detail" "$alarm" "vivo" "$real"

    # ---------------- B) branches da janela (so no repo do engine) ----------------
    # Independe do binario: se o gc vivo nao foi lido, o indicador antecipado ainda vale.
    if [ "$kind" = "gc" ] && git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
        if [ "$FETCHED_REPO" != "$repo" ]; then
            eb_fetch_all "$repo"
            FETCHED_REPO="$repo"
            note_fetch "$name/branches" "$repo"
        fi
        if wt_out=$(git -C "$repo" worktree list --porcelain 2>/dev/null); then
            wt_branches=$(printf '%s\n' "$wt_out" \
                | awk '/^worktree /{p=$2} /^branch /{b=$2; sub("^refs/heads/","",b); if (p ~ /\/engine-window-/) print b}') || wt_branches=""
            streak_reset "br:worktrees"
        else
            wt_branches=""
            list_failed "br:worktrees" "git worktree list falhou em $repo: o escopo 'worktree-da-janela' esta indisponivel (so a branch mais nova e checada)"
        fi
        if blines=$(git -C "$repo" for-each-ref --sort=-committerdate \
            --format="%(refname:short)${US}%(objectname)${US}%(committerdate:unix)" "refs/heads/$BRANCH_GLOB" 2>/dev/null); then
            streak_reset "br:list"
        else
            blines=""
            list_failed "br:list" "git for-each-ref falhou em $repo: nao consegui enumerar as branches $BRANCH_GLOB"
        fi
        newest=""
        while IFS="$US" read -r b tip ct <&4; do
            [ -n "$b" ] || continue
            [ -n "$newest" ] || newest="$b"
            scope="fora"
            [ "$b" = "$newest" ] && scope="mais-nova"
            if [ -n "$wt_branches" ] && printf '%s\n' "$wt_branches" | grep -qxF -- "$b"; then scope="worktree-da-janela"; fi
            br=$(eb_backup_state "$repo" "$tip")
            bstate="${br%%|*}"
            bdetail="${br#*|}"
            balarm=0
            case "$ct" in '' | *[!0-9]*) ct="$NOW" ;; esac
            bage=$((NOW - ct))
            if [ "$scope" = "fora" ]; then
                :   # informativo: nao alarma (ver cabecalho, item B)
            elif [ "$bstate" = "MISSING" ]; then
                if [ "$bage" -ge "$BRANCH_GRACE_S" ]; then
                    balarm=1
                    notify_once "br:$b" "Branch da janela SEM backup: $b" \
                        "$b ($tip) so existe neste disco ha $((bage / 3600))h (repo $repo). Empurre: git -C $repo push origin $b  (ou: scripts/engine-window-run.sh push)." 4 >/dev/null || true
                else
                    bdetail="$bdetail [dentro da carencia: $((bage / 60))min < $((BRANCH_GRACE_S / 60))min]"
                fi
            elif [ "$bstate" = "UNKNOWN" ]; then
                UNKNOWNS=$((UNKNOWNS + 1))
                streak_bump "br:$b"
                if [ "$STREAK_N" -ge "$UNKNOWN_STREAK" ]; then
                    balarm=1
                    notify_once "br:$b:unknown" "Nao consigo verificar o backup de $b ha $STREAK_N execucoes" "$bdetail" 3 >/dev/null || true
                fi
            else
                streak_reset "br:$b"
            fi
            [ "$balarm" = "1" ] && ALARMS=$((ALARMS + 1))
            add_row branch "$b" "$tip" "$bstate" "$bdetail" "$balarm" "$scope" ""
        done 4<<EOF
$blines
EOF
    fi
done 3<<EOF
$ARTIFACTS
EOF

DUR=$(($(date +%s) - NOW))
# Evidencia positiva marcada "velha" = o fetch falhou: contada, pra nao ficar so no texto.
STALE=$(printf '%s' "$ROWS" | grep -c 'possivelmente velhas') || STALE=0

# Falha ao gravar o estado (disco cheio, permissao) tambem e terceiro estado: sem
# gravar, o cooldown e as sequencias de UNKNOWN nao persistem -- o guard segue
# avisando, mas sem dedupe e sem nunca completar uma sequencia. Aviso ALTO, nunca
# quieto. Gravado ANTES de imprimir, pra o relatorio poder dizer que falhou.
STATE_WRITE_FAILED=0
if ! printf '%s\n' "$SEEN_JSON" > "$SEEN_FILE" 2>/dev/null; then
    STATE_WRITE_FAILED=1
    echo "AVISO: nao consegui gravar o estado em $SEEN_FILE -- cooldown e sequencias de UNKNOWN NAO persistem (disco cheio? permissao?)." >&2
fi

if [ "$JSON_OUT" = "1" ]; then
    printf '%s' "$ROWS" | jq -R -s --argjson alarms "$ALARMS" --argjson unknowns "$UNKNOWNS" --argjson nf "$NOTIFY_FAILED" \
        --argjson ff "$FETCH_FAILS" --argjson stale "$STALE" --argjson swf "$STATE_WRITE_FAILED" --argjson dur "$DUR" --arg us "$US" '
        { alarms: $alarms, unknowns: $unknowns, notify_failed: $nf, fetch_failed: $ff, stale: $stale,
          state_write_failed: ($swf == 1), duration_s: $dur,
          rows: ( split("\n") | map(select(length > 0) | split($us)
                  | { kind: .[0], name: .[1], commit: .[2], state: .[3], detail: .[4], alarm: (.[5] == "1"), scope: .[6], binary: .[7] }) ) }'
else
    echo "═══ BACKUP DO QUE RODA (ga-ta2w6r) ═══"
    echo "  O que roda hoje:"
    printf '%s' "$ROWS" | while IFS="$US" read -r kind name commit state detail alarm scope binary; do
        [ "$kind" = "artifact" ] || continue
        printf '    %-3s %-9s %-10s %s\n' "$name" "$state" "${commit:--}" "$binary"
        printf '        -> %s\n' "$detail"
    done
    echo "  Branches $BRANCH_GLOB (repo $GC_SRC):"
    printf '%s' "$ROWS" | while IFS="$US" read -r kind name commit state detail alarm scope binary; do
        [ "$kind" = "branch" ] || continue
        tag=""
        [ "$scope" = "fora" ] && tag="  [fora do escopo: informativo, nao alarma]"
        [ "$alarm" = "1" ] && tag="  [ALARME]"
        printf '    %-42s %-8s %.9s  (%s)%s\n' "$name" "$state" "$commit" "$scope" "$tag"
        [ "$state" != "OK" ] && printf '        -> %s\n' "$detail"
    done
    printf '%s' "$FETCH_NOTES"
    SW=""
    [ "$STATE_WRITE_FAILED" = "1" ] && SW=", ESTADO NAO GRAVADO"
    echo "  VEREDITO: $ALARMS alarme(s) ativo(s), $UNKNOWNS desconhecido(s), $FETCH_FAILS fetch(es) FALHARAM, $STALE evidencia(s) possivelmente velha(s), $NOTIFY_FAILED alerta(s) NAO entregue(s)${SW}  (medido: ${DUR}s)"
fi

exit 0
