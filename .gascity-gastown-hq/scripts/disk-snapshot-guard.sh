#!/bin/bash
# disk-snapshot-guard.sh — proactively thins local Time Machine snapshots
# before they push /System/Volumes/Data into a Dolt-crashing ENOSPC crisis
# (ga-g5bzf follow-up, 2026-09-04, Mayor).
#
# WHY THIS EXISTS: twice in one night (2026-09-04, ~01:00 and ~07:17) local
# TM snapshots accumulated fast enough to take Dolt's data volume from >7GB
# free to 0 in well under an hour, crashing dolt sql-server with "no space
# left on device: error writing to database journal file". Both times the
# fix was the same Apple-sanctioned, non-destructive command:
#   tmutil thinlocalsnapshots / <bytes> 4
# — but it requires root, so a human (Athos) had to run it by hand each time,
# reactively, after the crash already happened. This script does the same
# command proactively, on a timer, as root, before the crisis — so nobody
# has to be woken up for it again.
#
# SAFETY: tmutil thinlocalsnapshots only purges local snapshot backing store
# (APFS purgeable space from TM's local snapshots) — it does not touch user
# files, does not touch .beads/dolt, does not touch any city data. It is the
# same command a human already ran twice tonight with no ill effect. It is a
# no-op (prints "Thinned local snapshots:" with nothing after the colon) when
# there is nothing to purge — safe to run on a timer even when not needed.
#
# THIS DOES NOT FIX THE UNDERLYING QUESTION of why local snapshots pile up
# this fast (no working TM backup destination reachable? see ga-ff6t9-adjacent
# discussion) — it only keeps the symptom from reaching Dolt's floor. If TM
# gets a real destination, this becomes a cheap no-op forever, not a wasted
# mechanism.

set -uo pipefail

CITY="/Users/athos/gt/.gascity-gastown-hq"
LOG="${CITY}/.gc/logs/disk-snapshot-guard.log"
NOTIFY_AS_USER="athos"
NOTIFY_BIN="/Users/athos/.local/bin/notify"

# Proactive floor: act well above Dolt's own documented ~3GB crash floor, so
# there's real margin left when this fires (not another race to zero).
FLOOR_GB=12
# Target: try to reclaim up to this many bytes when the floor is breached.
RECLAIM_TARGET_BYTES=40000000000

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${LOG}" 2>/dev/null; }
notify_athos() {
  sudo -u "${NOTIFY_AS_USER}" "${NOTIFY_BIN}" -t "$1" -p "${3:-3}" "$2" >/dev/null 2>&1 || true
}

# --- ga-xpswpd.2 + ga-sgt7ls: one-time bootstrap of the root-owned copy (acts only as root) ----------------------------------
# WHY: the LaunchDaemon runs THIS file as root from a directory athos can write, so any athos process rewrites what root
# runs next round. On the first root round this block runs the installer once: it copies this guard to
# /usr/local/libexec/gascity (root:wheel) and repoints the plist there (--no-reload: the job that runs us is NOT booted
# out mid-round; the loaded job keeps the repo path until launchd loads the plist again, the plist on disk is already
# the root copy). The block itself never exits and never fails the guard (dsg_finish does the exiting, after it returns): any
# doubt (hash differs, installer missing, rc != 0) is one log line and the guard carries on exactly as before. Once the marker exists, or when we ARE the root copy, it does nothing.
# THE PIN IS A LITERAL IN THIS COMMIT, never read from a file athos can write. The installer and this file are copied into
# a private 0700 directory and only the COPIES are hashed and run. This file cannot carry its own sha256, so the pin is the
# INSTALLER's; the guard's hash handed to the installer is that of root's private copy of this file (round 1 trusts the
# bytes at the repo path, which root already runs today: the block only moves the anchor).
# ga-sgt7ls (non-blocking findings of the ga-xpswpd.2 gate):
#  - IT RUNS LAST. dsg_finish calls the bootstrap on the way out (df unreadable, disk healthy, or after the thin), never before
#    the df/floor/thin: at 4-7 GB free the thin is the urgent job and the installer waits its turn.
#  - TIME LIMIT. The installer runs in the background for at most DSG_INSTALL_TIMEOUT_S: a hung installer (launchctl, a stuck
#    volume) is TERM'd, then KILL'd, counts as a failure and cannot hold the guard (the old $(...) waited for it forever).
#  - BACKOFF. A failing installer used to re-run every 10-min round forever (~144 log lines a day). Now every failure after the
#    "already installed" check (plist target, installer missing, copy/sha problem, hash differs, rc != 0, timeout, no
#    "instalado e confirmado", marker not written) is recorded in DSG_STATE_PATH as "<pin prefix> <failures> <retry-after epoch>":
#    the next try waits 20 min, then 40, 80, ... capped at 6 h. Success deletes the file, a new pin (new installer) retries at once,
#    and deleting the file (as root) retries at once. The record is trusted only if it is root-owned and not group/other-writable
#    (dsg_root_only), numeric, for this pin, and not further out than the cap (a forged or clock-skewed file cannot park the
#    bootstrap); anything else = no record = try now. A record that cannot be written (ENOSPC, /var/db missing) = no record =
#    the next round tries again, i.e. the old behavior, never worse.
#  - PLIST TARGET. The bytes that get installed must be the bytes root runs today: before anything is staged, the plist's
#    ProgramArguments[1] must be THIS file. That is the honest limit of the round-1 trust (TOFU): the guard cannot carry its own
#    sha256 (it would change the file it hashes), so unlike the installer's --expect-sha256 contract round 1 trusts "what root
#    already runs"; the pin only covers the installer.
#  - THE LINES DO NOT VANISH. Bootstrap lines go through dsg_note: the log first; if the log cannot be written (ENOSPC, directory
#    gone) the same line goes to stderr, which launchd sends to StandardErrorPath.
DSG_INSTALLER_SHA256="6c3e14e2fe5d5049eb7f7bf351bf5b4e75baf1e01d147032ee2a77a466e15e6d"
DSG_PROG_DIR="/usr/local/libexec/gascity"
DSG_MARKER_NAME=".disk-snapshot-guard.bootstrap-ok"
DSG_PLIST_PATH="/Library/LaunchDaemons/com.gascity.disk-snapshot-guard.plist"
DSG_PLISTBUDDY_BIN="/usr/libexec/PlistBuddy"
DSG_STATE_PATH="/var/db/com.gascity.disk-snapshot-guard.bootstrap-backoff"
DSG_INSTALL_TIMEOUT_S=60
DSG_BACKOFF_BASE_S=1200
DSG_BACKOFF_MAX_S=21600

# dsg_init: who am I and which test hooks count. Runs at the top, BEFORE the df/thin, so a test LOG also covers the thin's lines.
# Sets DSG_ME (uid from `id -u`), DSG_RUID (the uid that plays root), DSG_PFX (fake-root prefix). The hooks DSG_ROOT_UID,
# DSG_ROOT_PFX and DSG_LOG only count without root: as root no DSG_* variable changes what runs or where it logs.
dsg_init() {
  local PATH=/usr/bin:/bin:/usr/sbin:/sbin
  # vazio/falhou → sem uid confirmado: DSG_ME fica vazio e o bootstrap não age (id -u, nunca $EUID: o bash aceita EUID importado do ambiente)
  DSG_ME=$(/usr/bin/id -u 2>/dev/null) || DSG_ME=""
  DSG_RUID=0; DSG_PFX=""
  if [ -n "$DSG_ME" ] && [ "$DSG_ME" != "0" ]; then
    DSG_RUID="${DSG_ROOT_UID:-0}"; DSG_PFX="${DSG_ROOT_PFX:-}"
  fi
  [ "$DSG_ME" = "$DSG_RUID" ] || return 0
  # o log de teste só vale depois de confirmado que ESTE processo faz o papel de root: um DSG_LOG solto numa rodada manual sem root não redireciona o log do guard
  if [ "$DSG_ME" != "0" ]; then LOG="${DSG_LOG:-$LOG}"; fi
}

# dsg_note <texto>: a linha do bootstrap vai para o log; se o log não grava (ENOSPC, pasta sumida) a mesma linha vai para o stderr do job (launchd -> StandardErrorPath).
# O grupo { } leva o 2>/dev/null ANTES do >> : sem ele o erro do redirecionamento que falha vazaria sem a linha.
dsg_note() {
  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${LOG}"; } 2>/dev/null || printf 'disk-snapshot-guard: %s\n' "$*" >&2
}

# dsg_root_only <path> [d|-] <root uid> → rc 0 if it is a non-symlink of the wanted type owned by that uid with no group/other write.
dsg_root_only() {
  local line="" mode="" links="" uid="" rest=""
  [ -L "$1" ] && return 1
  # vazio → rc 1 (sem dono/modo não afirmo nada); falhou/ilegível → rc 1 também: quem chama trata como NÃO instalado/NÃO seguro
  line=$(ls -ldn "$1" 2>/dev/null) || return 1
  [ -n "$line" ] || return 1
  read -r mode links uid rest <<< "$line"
  [ "${mode:0:1}" = "$2" ] && [ "$uid" = "$3" ] && [ "${mode:5:1}" != "w" ] && [ "${mode:8:1}" != "w" ]
}

dsg_sha256() {
  local out=""
  # vazio → rc 1; falhou/ilegível → rc 1: sem hash o bloco não instala, nunca "hash vazio == hash fixado"
  out=$(/usr/bin/shasum -a 256 "$1" 2>/dev/null) || out=$(/usr/bin/sha256sum "$1" 2>/dev/null) || return 1
  out="${out%% *}"
  case "$out" in (''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#out}" = "64" ] || return 1
  printf '%s\n' "$out"
}

# dsg_run_limited <segundos> <arquivo de saída> <pasta> <comando...>: roda o comando em segundo plano (stdout+stderr no arquivo, stdin em /dev/null) e espera até <segundos>.
# Passou do limite → TERM (nele e nos filhos), até 2 s depois KILL, rc 124. Dentro do limite o rc é o do comando. rc 125 = nem o arquivo de saída eu consegui criar (nada rodou).
# O laço não usa `wait` antes do fim: um processo em estado D que nem o KILL derruba fica abandonado e o guard segue (o rc 124 vale igual). O `2>/dev/null` da função
# esconde o aviso "Terminated" do bash para o filho morto.
dsg_run_limited() {
  local secs="$1" outf="$2" dir="$3" pid="" t0="$SECONDS" rc=0 g=0
  shift 3
  # falhou (sem arquivo de saída) → rc 125: nada rodou, quem chama conta como falha do instalador
  : > "$outf" || return 125
  ( cd "$dir" && exec "$@" ) > "$outf" 2>&1 < /dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ $((SECONDS - t0)) -ge "$secs" ]; then
      pkill -TERM -P "$pid"; kill -TERM "$pid"
      g=0; while [ "$g" -lt 10 ] && kill -0 "$pid" 2>/dev/null; do /bin/sleep 0.2; g=$((g + 1)); done
      if kill -0 "$pid" 2>/dev/null; then pkill -KILL -P "$pid"; kill -KILL "$pid"; /bin/sleep 0.5; fi
      kill -0 "$pid" 2>/dev/null || wait "$pid"
      return 124
    fi
    /bin/sleep 0.2
  done
  wait "$pid"; rc=$?
  return "$rc"
} 2>/dev/null

# dsg_backoff_load <arquivo> <agora> <uid do root> <prefixo do pin> → imprime "<falhas> <retry_after>" se há registro VÁLIDO; senão não imprime nada e rc 1 (= tenta já).
dsg_backoff_load() {
  local f1="" f2="" f3="" f4="" n=0 at=0
  # vazio/falhou/ilegível/não é do root → sem registro (rc 1): tenta já, o comportamento de antes do backoff; um arquivo que o athos escreve (dono errado, escrita de grupo/outros, symlink) não adia o conserto
  dsg_root_only "$1" - "$3" || return 1
  # vazio/sem a quebra de linha final/ilegível → sem registro (rc 1); o 2>/dev/null vem ANTES do < para o erro de abertura não vazar
  read -r f1 f2 f3 f4 2>/dev/null < "$1" || return 1
  [ "$f1" = "$4" ] && [ -z "$f4" ] || return 1
  case "$f2" in (''|*[!0-9]*) return 1 ;; esac
  case "$f3" in (''|*[!0-9]*) return 1 ;; esac
  [ "${#f2}" -le 4 ] && [ "${#f3}" -le 11 ] || return 1
  n=$((10#$f2)); at=$((10#$f3))
  # um retry_after além do teto não saiu de nós (arquivo forjado, relógio que voltou): ignoro e tento já
  [ "$at" -le $(( $2 + DSG_BACKOFF_MAX_S )) ] || return 1
  printf '%s %s\n' "$n" "$at"
}

# dsg_backoff_fail <arquivo> <agora> <prefixo do pin> <falhas até aqui>: grava "<pin> <falhas+1> <agora+espera>" (espera 1200 s, dobra a cada falha, teto 21600 s) e anota uma linha.
dsg_backoff_fail() {
  local state="$1" now="$2" pinp="$3" n=0 delay="$DSG_BACKOFF_BASE_S" i=1
  n=$(( $4 + 1 ))
  while [ "$i" -lt "$n" ] && [ "$delay" -lt "$DSG_BACKOFF_MAX_S" ]; do delay=$((delay * 2)); i=$((i + 1)); done
  [ "$delay" -le "$DSG_BACKOFF_MAX_S" ] || delay="$DSG_BACKOFF_MAX_S"
  # o modo é explícito (0644) e o rename é atômico: com `>` o registro herdaria o umask e dsg_root_only recusaria um 0664/0666
  { printf '%s %s %s\n' "$pinp" "$n" "$((now + delay))"; } 2>/dev/null > "${state}.new.$$" \
    && chmod 0644 "${state}.new.$$" 2>/dev/null \
    && mv -f "${state}.new.$$" "$state" 2>/dev/null \
    || { dsg_note "bootstrap root: não gravei o estado do backoff em ${state}: a próxima rodada tenta de novo"; rm -f "${state}.new.$$" 2>/dev/null; return 0; }
  dsg_note "bootstrap root: falha nº ${n} seguida; a próxima tentativa só depois de ${delay}s (apagar ${state} = tentar já)"
}

# dsg_bootstrap_try <self> <self_dir> <pfx> <uid do root> <prog_dir> <marker> <limite em s> → rc 0 só se o instalador confirmou E o marcador foi gravado;
# qualquer outra coisa é rc 1 (falha: quem chama registra o backoff).
dsg_bootstrap_try() {
  local PATH=/usr/bin:/bin:/usr/sbin:/sbin
  local self="$1" self_dir="$2" pfx="$3" root_uid="$4" prog_dir="$5" marker="$6" tmo="$7"
  local inst="install-disk-snapshot-guard-root.sh" plist="" pb="" target="" stage="" inst_sha="" guard_sha="" out="" rc=0 good=0
  # as linhas do instalador que vão para o log: o resultado, a recarga pendente e o ERRO (o motivo quando ele recusa)
  local keep='^(RESULTADO|RECARGA PENDENTE|ERRO):'
  plist="${pfx}${DSG_PLIST_PATH}"; pb="$DSG_PLISTBUDDY_BIN"
  # o PlistBuddy falso do teste só vale sem root (como no instalador)
  if [ "$root_uid" != "0" ]; then pb="${DSG_PLISTBUDDY:-$pb}"; fi
  # vazio/falhou/ilegível → target vazio: não sei para onde o root aponta, então não instalo (um plist que não leio não prova que estes são os bytes que o root roda)
  target=$("$pb" -c "Print :ProgramArguments:1" "$plist" 2>/dev/null) || target=""
  if [ -z "$target" ] || { [ "$target" != "$self" ] && [ "$target" != "${self_dir}/${self##*/}" ]; }; then
    dsg_note "bootstrap root: SKIP — o plist (${plist}) não aponta para este arquivo (aponta para '${target}', rodando '${self}'): nada instalado."
    return 1
  fi
  if [ -L "${self_dir}/${inst}" ] || [ ! -f "${self_dir}/${inst}" ]; then
    dsg_note "bootstrap root: SKIP — instalador ausente ou symlink em ${self_dir}: nada instalado, o guard segue como antes."
    return 1
  fi
  # vazio/falhou → sem pasta privada do root não copio nada de pasta do athos
  stage=$(/usr/bin/mktemp -d "${pfx}/var/tmp/dsg-bootstrap.XXXXXX" 2>/dev/null) || { dsg_note "bootstrap root: SKIP — mktemp falhou"; return 1; }
  if dsg_root_only "$stage" d "$root_uid" \
     && cp "${self_dir}/${inst}" "${stage}/${inst}" 2>/dev/null && cp "$self" "${stage}/disk-snapshot-guard.sh" 2>/dev/null; then
    # as cópias é que são conferidas (um arquivo trocado depois do -L não escapa do hash)
    inst_sha=$(dsg_sha256 "${stage}/${inst}") || inst_sha=""
    guard_sha=$(dsg_sha256 "${stage}/disk-snapshot-guard.sh") || guard_sha=""
    if [ -z "$inst_sha" ] || [ -z "$guard_sha" ]; then
      dsg_note "bootstrap root: SKIP — não consegui calcular o sha256 das cópias: nada instalado."
    elif [ "$inst_sha" != "$DSG_INSTALLER_SHA256" ]; then
      dsg_note "bootstrap root: SKIP — sha256 do instalador (${inst_sha}) difere do fixado neste commit: nada instalado."
    else
      dsg_run_limited "$tmo" "${stage}/installer.out" "$stage" /bin/bash "${stage}/${inst}" --no-reload --expect-sha256 "$guard_sha"; rc=$?
      # vazio/falhou/ilegível → out vazio: sem a linha RESULTADO não há marcador (rc 124 e 125 também não gravam)
      out=$(cat "${stage}/installer.out" 2>/dev/null) || out=""
      printf '%s\n' "$out"
      # a linha RECARGA PENDENTE conta: "confirmado no disco" não é "o job carregado já roda a cópia do root"; o ERRO conta: é o motivo quando o instalador recusa (vai no stderr dele)
      if [ "$rc" = "124" ]; then
        dsg_note "bootstrap root: instalador estourou ${tmo}s e foi morto (rc=124): $(printf '%s\n' "$out" | grep -E "$keep" | tr '\n' ' ')"
      else
        dsg_note "bootstrap root: instalador rc=${rc}: $(printf '%s\n' "$out" | grep -E "$keep" | tr '\n' ' ')"
      fi
      if [ "$rc" = "0" ] && printf '%s\n' "$out" | grep -q '^RESULTADO: instalado e confirmado'; then
        # o modo do marcador é explícito (0644): com `>` ele herdaria o umask do ambiente, e um 0664/0666 é recusado pelo próprio dsg_root_only
        # (escrita de grupo/outros) — o instalador rodaria de novo a cada rodada, para sempre
        { printf 'sha256 %s\n' "$guard_sha"; date '+%Y-%m-%d %H:%M:%S'; } 2>/dev/null > "${marker}.new.$$" \
          && chmod 0644 "${marker}.new.$$" 2>/dev/null \
          && mv -f "${marker}.new.$$" "$marker" 2>/dev/null \
          && good=1 \
          || { dsg_note "bootstrap root: instalou mas não gravei o marcador em ${prog_dir}: a cópia do root está instalada; sem o marcador a próxima tentativa (depois do backoff) vai achar que o plist já aponta para outro arquivo"; rm -f "${marker}.new.$$" 2>/dev/null; }
      fi
    fi
  else
    dsg_note "bootstrap root: SKIP — pasta privada ou cópia falhou: nada instalado."
  fi
  rm -f "${stage}/${inst}" "${stage}/disk-snapshot-guard.sh" "${stage}/installer.out" 2>/dev/null
  rmdir "$stage" 2>/dev/null
  [ "$good" = "1" ]
}

dsg_bootstrap_root() {
  local PATH=/usr/bin:/bin:/usr/sbin:/sbin
  local self="" self_dir="" prog_dir="" marker="" state="" now="" pinp="" tmo="$DSG_INSTALL_TIMEOUT_S" rec="" fails=0 retry_at=0
  # vazio/falhou → sem uid confirmado por dsg_init, ou não sou o root do papel: não ajo
  [ "$DSG_ME" = "$DSG_RUID" ] || return 0
  prog_dir="${DSG_PFX}${DSG_PROG_DIR}"
  marker="${prog_dir}/${DSG_MARKER_NAME}"
  # vazio → sem caminho próprio não sei se sou a cópia do root, não ajo; falhou/ilegível → idem
  self="${BASH_SOURCE[0]:-$0}"
  self_dir=$(cd "$(dirname "$self")" 2>/dev/null && pwd -P) || return 0
  [ "$self_dir" = "$prog_dir" ] && return 0
  # vazio/ilegível → sem marcador do root legível = ainda não instalado (o instalador é idempotente, rodar de novo não estraga)
  if dsg_root_only "$prog_dir" d "$DSG_RUID" && [ -f "$marker" ] && dsg_root_only "$marker" - "$DSG_RUID"; then return 0; fi

  # os ganchos de relógio e de limite só valem SEM root
  # vazio/falhou/não numérico → now vazio = sem relógio: não leio nem gravo backoff e tento (o comportamento de antes)
  now=$(/bin/date +%s 2>/dev/null) || now=""
  if [ "$DSG_ME" != "0" ]; then
    if [ -n "${DSG_NOW:-}" ]; then now="$DSG_NOW"; fi
    if [ -n "${DSG_INSTALL_TIMEOUT:-}" ]; then tmo="$DSG_INSTALL_TIMEOUT"; fi
  fi
  case "$now" in (''|*[!0-9]*) now="" ;; esac
  [ "${#now}" -le 11 ] || now=""
  case "$tmo" in (''|*[!0-9]*|0) tmo="$DSG_INSTALL_TIMEOUT_S" ;; esac
  [ "${#tmo}" -le 4 ] || tmo="$DSG_INSTALL_TIMEOUT_S"
  state="${DSG_PFX}${DSG_STATE_PATH}"
  pinp="${DSG_INSTALLER_SHA256:0:16}"
  if [ -n "$now" ]; then
    # vazio/inválido (sem registro, de outro pin, forjado) → rec vazio = tenta agora; só um registro válido e ainda no futuro adia (em silêncio: a linha já saiu quando a falha foi registrada)
    rec=$(dsg_backoff_load "$state" "$now" "$DSG_RUID" "$pinp") || rec=""
    if [ -n "$rec" ]; then
      read -r fails retry_at <<< "$rec"
      [ "$now" -lt "$retry_at" ] && return 0
    fi
  fi

  if dsg_bootstrap_try "$self" "$self_dir" "$DSG_PFX" "$DSG_RUID" "$prog_dir" "$marker" "$tmo"; then
    rm -f "$state" 2>/dev/null
  elif [ -n "$now" ]; then
    dsg_backoff_fail "$state" "$now" "$pinp" "$fails"
  fi
  return 0
}

# dsg_finish <rc>: toda saída do guard passa por aqui; o bootstrap roda por ÚLTIMO (depois do df, do piso e do thin), nunca antes.
dsg_finish() {
  dsg_bootstrap_root || true
  exit "${1:-0}"
}
dsg_init

AVAIL_KB=$(df -k /System/Volumes/Data 2>/dev/null | tail -1 | awk '{print $4}')
if [ -z "${AVAIL_KB}" ]; then
    log "SKIP: nao consegui ler df de /System/Volumes/Data — unknown state, nao age."
    dsg_finish 0
fi
AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))

if [ "${AVAIL_GB}" -ge "${FLOOR_GB}" ]; then
    # Healthy — nothing to do, don't even log every tick (would just be noise
    # every 10min forever). Only log the boundary-crossing runs below.
    dsg_finish 0
fi

log "=== piso furado: ${AVAIL_GB}GB livre (< ${FLOOR_GB}GB) — tentando thin ==="
BEFORE_KB="${AVAIL_KB}"

THIN_OUT=$(tmutil thinlocalsnapshots / "${RECLAIM_TARGET_BYTES}" 4 2>&1)
THIN_RC=$?
log "tmutil rc=${THIN_RC}: ${THIN_OUT}"

sleep 3
AFTER_KB=$(df -k /System/Volumes/Data 2>/dev/null | tail -1 | awk '{print $4}')
AFTER_GB=$(( AFTER_KB / 1024 / 1024 ))
FREED_MB=$(( (AFTER_KB - BEFORE_KB) / 1024 ))
log "resultado: ${AVAIL_GB}GB -> ${AFTER_GB}GB livre (freed ~${FREED_MB}MB)"

if [ "${FREED_MB}" -ge 500 ]; then
    notify_athos "Disco: guard liberou espaço" "${AVAIL_GB}GB -> ${AFTER_GB}GB (snapshot local do TM, automático)." 2
elif [ "${AFTER_GB}" -lt 3 ]; then
    # Thinning ran but didn't help enough and we're still at Dolt's real
    # crash floor — this is the one case worth waking a human for.
    log "ALERTA: piso critico mesmo apos thin — pode nao ser TM desta vez."
    notify_athos "Disco AINDA crítico após thin" "${AFTER_GB}GB livre — thin não resolveu. Precisa olhar (não é só snapshot desta vez)." 5
fi
dsg_finish 0
