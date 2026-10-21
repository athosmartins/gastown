#!/bin/bash
# dolt-hold-lib.sh (ga-3risy2) — o hold do Dolt gerenciado, lido pelos guards da cidade.
#
# ## Contents
# - O que é · Formato · Três respostas · Quem usa · Paridade com o engine
#
# O QUE É: um arquivo, $PACK_STATE_DIR/dolt-hold (padrão
#   $CITY/.gc/runtime/packs/dolt/dolt-hold; GC_DOLT_HOLD_FILE troca o caminho), que diz
#   "o Dolt está parado DE PROPÓSITO; ninguém o sobe". Sem ele, parar o Dolt para uma
#   troca de pasta / GC offline / ensaio de restore exigia desligar a cidade inteira: o
#   tick do controller, o retry do bd, o launchd (com.gastown.dolt-server) e os guards
#   abaixo religavam o Dolt em segundos. Quem põe e tira o hold: scripts/dolt-hold.sh.
# FORMATO: linhas "chave=valor" (# comenta a linha inteira). expires_at=<epoch, só dígitos>
#   solta o hold nessa hora; owner= e reason= saem nas mensagens; arquivo vazio (um touch)
#   segura até ser apagado.
# TRÊS RESPOSTAS, não duas: sem hold / hold / "não consegui saber". A terceira SEGURA, como
#   o hold ativo: o que o hold protege é o ato destrutivo (subir ou matar um Dolt sobre uma
#   pasta que alguém está trocando), então sob dúvida o estado inerte é "não mexer no Dolt".
#   Só arquivo ausente ou expiração vencida solta.
# QUEM USA: dolt-hang-watchdog.sh (não sonda, não conta strike, não reinicia),
#   dolt-disk-floor-guard.sh (_resurrect_dolt não sobe o Dolt e não pagina falha de
#   ressurreição) e scripts/dolt-hold.sh (on/off/status). Só LÊ: nunca apaga um hold vencido.
# PARIDADE COM O ENGINE: a função dolt_hold_blocks abaixo é a MESMA do engine
#   (examples/bd/assets/scripts/dolt-hold.sh no patch docs/pending-engine-window/
#   ga-3risy2-dolt-hold.patch), byte a byte; o Go (cmd/gc/dolt_hold.go) segue as mesmas regras.
#   scripts/dolt-hold.selftest.sh falha se a cópia daqui divergir do patch. Mexeu numa,
#   mexa na outra.
#
# NÃO cobre: alarmes que PAGAM quando o Dolt cai (gate-recovery-watchdog, throughput-stall,
#   pipeline-throughput-heartbeat, dolt-latency-alarm...). Eles não sobem nada, só avisam —
#   durante um hold esperado, a janela deve silenciá-los como já faz hoje (hqswap.sh).

# dolt_hold_blocks returns 0 (true) when a managed-Dolt hold forbids starting,
# recovering or restarting the server, and sets DOLT_HOLD_MESSAGE to a one-line
# explanation. It returns 1 (false) when there is no hold, or the hold has
# expired.
#
# A hold means "Dolt is down on purpose": a database directory is being
# swapped, a GC is running offline, a restore is being rehearsed. Without it the
# controller tick, the bd retry and the city's watchdogs bring a stopped Dolt
# back within seconds (ga-3risy2).
#
# The hold is the file $PACK_STATE_DIR/dolt-hold (GC_DOLT_HOLD_FILE overrides).
# Same file and same rules as cmd/gc/dolt_hold.go; keep the two in step:
#   - optional "key=value" lines, "#" starts a comment line;
#   - expires_at=<unix seconds, digits only> releases the hold at that time;
#   - owner= and reason= are shown in the message;
#   - an empty file (a bare touch) holds until it is removed.
#
# There are three answers, not two: no hold, hold, and "could not tell". The
# last one blocks. What a hold guards is the destructive action (starting or
# killing a Dolt on a directory somebody is swapping), so under doubt the inert
# answer is "do not touch Dolt". Only an absent file or a passed expiry
# releases it.
#
# Needs PACK_STATE_DIR unless GC_DOLT_HOLD_FILE is set. Read-only: it never
# removes an expired file.
dolt_hold_blocks() {
    DOLT_HOLD_MESSAGE=""
    _dh_file="${GC_DOLT_HOLD_FILE:-}"
    if [ -z "$_dh_file" ]; then
        if [ -z "${PACK_STATE_DIR:-}" ]; then
            # No path to look at: cannot know whether a hold exists.
            DOLT_HOLD_MESSAGE="dolt hold: pack state dir unknown, cannot look for the hold file; treating it as a hold"
            return 0
        fi
        _dh_file="$PACK_STATE_DIR/dolt-hold"
    fi

    # Parent directory absent -> nobody can have placed a hold there. Parent
    # present but not a directory, or not searchable -> unreadable (blocks),
    # as ENOTDIR/EACCES are in Go. File absent -> no hold. File present but not
    # a readable regular file -> unreadable. (Only the immediate parent is
    # checked; a regular file further up the path reads as "absent" here.)
    _dh_dir=$(dirname "$_dh_file")
    if [ ! -e "$_dh_dir" ] && [ ! -h "$_dh_dir" ]; then
        return 1
    fi
    if [ ! -d "$_dh_dir" ]; then
        DOLT_HOLD_MESSAGE="dolt hold file $_dh_file could not be read ($_dh_dir is not a directory); treating it as a hold"
        return 0
    fi
    if [ ! -x "$_dh_dir" ]; then
        DOLT_HOLD_MESSAGE="dolt hold file $_dh_file could not be read (directory not searchable); treating it as a hold"
        return 0
    fi
    if [ ! -e "$_dh_file" ] && [ ! -h "$_dh_file" ]; then
        return 1
    fi
    if [ ! -f "$_dh_file" ] || [ ! -r "$_dh_file" ]; then
        DOLT_HOLD_MESSAGE="dolt hold file $_dh_file could not be read (not a readable regular file); treating it as a hold"
        return 0
    fi

    # Empty file -> hold with no expiry; read failure -> unreadable (blocks).
    # Capped at 4 KiB like the Go reader, so a wrong file is not slurped.
    if ! _dh_content=$(LC_ALL=C head -c 4096 "$_dh_file" 2>/dev/null); then
        DOLT_HOLD_MESSAGE="dolt hold file $_dh_file could not be read; treating it as a hold"
        return 0
    fi

    _dh_expires=""
    _dh_owner=""
    _dh_reason=""
    _dh_saw_expiry=0
    while IFS= read -r _dh_line; do
        _dh_line=${_dh_line#"${_dh_line%%[![:space:]]*}"}
        _dh_line=${_dh_line%"${_dh_line##*[![:space:]]}"}
        case "$_dh_line" in
            ''|'#'*) continue ;;
            *=*) ;;
            *) continue ;;
        esac
        _dh_key=${_dh_line%%=*}
        _dh_val=${_dh_line#*=}
        _dh_key=${_dh_key%"${_dh_key##*[![:space:]]}"}
        _dh_val=${_dh_val#"${_dh_val%%[![:space:]]*}"}
        case "$_dh_key" in
            expires_at)
                [ "$_dh_saw_expiry" -eq 1 ] && continue # first one wins, as in Go
                _dh_saw_expiry=1
                # No expires_at line -> holds until removed. Blank, non-digit
                # or zero -> unreadable (blocks): the hold is there but when
                # to release it is unknown.
                case "$_dh_val" in
                    ''|*[!0-9]*)
                        DOLT_HOLD_MESSAGE="dolt hold file $_dh_file has expires_at='$_dh_val' (not a positive unix time); treating it as a hold"
                        return 0
                        ;;
                esac
                if ! [ "$_dh_val" -gt 0 ] 2>/dev/null; then
                    DOLT_HOLD_MESSAGE="dolt hold file $_dh_file has expires_at='$_dh_val' (not a positive unix time); treating it as a hold"
                    return 0
                fi
                _dh_expires="$_dh_val"
                ;;
            owner) _dh_owner="$_dh_val" ;;
            reason) _dh_reason="$_dh_val" ;;
        esac
    done <<EOF
$_dh_content
EOF

    if [ -n "$_dh_expires" ]; then
        _dh_now=$(date +%s 2>/dev/null) || _dh_now=""
        case "$_dh_now" in
            ''|*[!0-9]*)
                # The clock could not be read: cannot tell whether it expired.
                DOLT_HOLD_MESSAGE="dolt hold file $_dh_file has an expiry but the clock could not be read; treating it as a hold"
                return 0
                ;;
        esac
        if [ "$_dh_now" -ge "$_dh_expires" ]; then
            return 1 # expired -> released
        fi
    fi

    DOLT_HOLD_MESSAGE="dolt is on hold ($_dh_file)"
    [ -n "$_dh_owner" ] && DOLT_HOLD_MESSAGE="$DOLT_HOLD_MESSAGE by $_dh_owner"
    [ -n "$_dh_reason" ] && DOLT_HOLD_MESSAGE="$DOLT_HOLD_MESSAGE: $_dh_reason"
    if [ -n "$_dh_expires" ]; then
        _dh_when=$(date -u -r "$_dh_expires" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) \
            || _dh_when=$(date -u -d "@$_dh_expires" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) \
            || _dh_when="unix $_dh_expires"
        DOLT_HOLD_MESSAGE="$DOLT_HOLD_MESSAGE; expires $_dh_when"
    fi
    DOLT_HOLD_MESSAGE="$DOLT_HOLD_MESSAGE; remove the file to release it"
    return 0
}

# _dolt_hold_pack_state_dir [city] — a pasta de estado do pack dolt, pela mesma conta do
# engine: GC_PACK_STATE_DIR, depois GC_CITY_RUNTIME_DIR/packs/dolt, depois
# <cidade>/.gc/runtime/packs/dolt. A cidade vem de $1, depois de $CITY, depois de
# $GC_CITY_PATH. Imprime nada (e retorna 1) se não der para saber.
_dolt_hold_pack_state_dir() {
  local _city="${1:-${CITY:-${GC_CITY_PATH:-}}}"
  if [ -n "${GC_PACK_STATE_DIR:-}" ]; then
    printf '%s\n' "$GC_PACK_STATE_DIR"
  elif [ -n "${GC_CITY_RUNTIME_DIR:-}" ]; then
    printf '%s\n' "$GC_CITY_RUNTIME_DIR/packs/dolt"
  elif [ -n "$_city" ]; then
    printf '%s\n' "$_city/.gc/runtime/packs/dolt"
  else
    return 1
  fi
}

# dolt_hold_city_path [city] — o arquivo de hold desta cidade (GC_DOLT_HOLD_FILE vence).
dolt_hold_city_path() {
  local _d
  if [ -n "${GC_DOLT_HOLD_FILE:-}" ]; then
    printf '%s\n' "$GC_DOLT_HOLD_FILE"
    return 0
  fi
  _d=$(_dolt_hold_pack_state_dir "${1:-}") || return 1
  printf '%s/dolt-hold\n' "$_d"
}

# dolt_hold_city_blocks [city] — o hold vale para esta cidade? 0 = segura (DOLT_HOLD_MESSAGE
# diz por quê); 1 = solto. Sem cidade nenhuma o dolt_hold_blocks responde "não sei" e segura.
dolt_hold_city_blocks() {
  local PACK_STATE_DIR
  # vazio (cidade desconhecida) → PACK_STATE_DIR vazio e dolt_hold_blocks segura; falhou → idem
  PACK_STATE_DIR=$(_dolt_hold_pack_state_dir "${1:-}") || PACK_STATE_DIR=""
  dolt_hold_blocks
}
