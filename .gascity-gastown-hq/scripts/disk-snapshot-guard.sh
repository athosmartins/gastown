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

# --- ga-xpswpd.2: one-time bootstrap of the root-owned copy (acts only as root) ---------------------------------
# WHY: the LaunchDaemon runs THIS file as root from a directory athos can write, so any athos process rewrites what root
# runs next round. On the first root round this block runs the installer once: it copies this guard to
# /usr/local/libexec/gascity (root:wheel) and repoints the plist there (--no-reload: the job that runs us is NOT booted
# out mid-round; the loaded job keeps the repo path until launchd loads the plist again, the plist on disk is already
# the root copy). It never exits and never fails the guard: any doubt (hash differs, installer missing, rc != 0) is one
# log line and the guard carries on exactly as before. Once the marker exists, or when we ARE the root copy, it does nothing.
# THE PIN IS A LITERAL IN THIS COMMIT, never read from a file athos can write. The installer and this file are copied into
# a private 0700 directory and only the COPIES are hashed and run. This file cannot carry its own sha256, so the pin is the
# INSTALLER's; the guard's hash handed to the installer is that of root's private copy of this file (round 1 trusts the
# bytes at the repo path, which root already runs today: the block only moves the anchor).
DSG_INSTALLER_SHA256="6c3e14e2fe5d5049eb7f7bf351bf5b4e75baf1e01d147032ee2a77a466e15e6d"
DSG_PROG_DIR="/usr/local/libexec/gascity"
DSG_MARKER_NAME=".disk-snapshot-guard.bootstrap-ok"

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

dsg_bootstrap_root() {
  local PATH=/usr/bin:/bin:/usr/sbin:/sbin
  local me="" root_uid=0 pfx="" self="" self_dir="" prog_dir="" marker="" stage="" inst="" inst_sha="" guard_sha="" out="" rc=0
  # vazio/falhou → sem uid confirmado não ajo (id -u, nunca $EUID: o bash aceita EUID importado do ambiente)
  me=$(/usr/bin/id -u 2>/dev/null) || return 0
  if [ -n "$me" ] && [ "$me" != "0" ]; then
    # ganchos de teste: só valem SEM root (como root nenhum DSG_* muda o que roda)
    root_uid="${DSG_ROOT_UID:-0}"; pfx="${DSG_ROOT_PFX:-}"
  fi
  [ "$me" = "$root_uid" ] || return 0
  # o log de teste só vale depois de confirmado que ESTE processo faz o papel de root: um DSG_LOG solto numa rodada manual sem root não redireciona o log do guard
  if [ "$me" != "0" ]; then LOG="${DSG_LOG:-$LOG}"; fi
  prog_dir="${pfx}${DSG_PROG_DIR}"
  marker="${prog_dir}/${DSG_MARKER_NAME}"
  # vazio → sem caminho próprio não sei se sou a cópia do root, não ajo; falhou/ilegível → idem
  self="${BASH_SOURCE[0]:-$0}"
  self_dir=$(cd "$(dirname "$self")" 2>/dev/null && pwd -P) || return 0
  [ "$self_dir" = "$prog_dir" ] && return 0
  # vazio/ilegível → sem marcador do root legível = ainda não instalado (o instalador é idempotente, rodar de novo não estraga)
  if dsg_root_only "$prog_dir" d "$root_uid" && [ -f "$marker" ] && dsg_root_only "$marker" - "$root_uid"; then return 0; fi

  inst="install-disk-snapshot-guard-root.sh"
  if [ -L "${self_dir}/${inst}" ] || [ ! -f "${self_dir}/${inst}" ]; then
    log "bootstrap root: SKIP — instalador ausente ou symlink em ${self_dir}: nada instalado, o guard segue como antes."
    return 0
  fi
  # vazio/falhou → sem pasta privada do root não copio nada de pasta do athos
  stage=$(/usr/bin/mktemp -d "${pfx}/var/tmp/dsg-bootstrap.XXXXXX" 2>/dev/null) || { log "bootstrap root: SKIP — mktemp falhou"; return 0; }
  if dsg_root_only "$stage" d "$root_uid" \
     && cp "${self_dir}/${inst}" "${stage}/${inst}" 2>/dev/null && cp "$self" "${stage}/disk-snapshot-guard.sh" 2>/dev/null; then
    # as cópias é que são conferidas (um arquivo trocado depois do -L não escapa do hash)
    inst_sha=$(dsg_sha256 "${stage}/${inst}") || inst_sha=""
    guard_sha=$(dsg_sha256 "${stage}/disk-snapshot-guard.sh") || guard_sha=""
    if [ -z "$inst_sha" ] || [ -z "$guard_sha" ]; then
      log "bootstrap root: SKIP — não consegui calcular o sha256 das cópias: nada instalado."
    elif [ "$inst_sha" != "$DSG_INSTALLER_SHA256" ]; then
      log "bootstrap root: SKIP — sha256 do instalador (${inst_sha}) difere do fixado neste commit: nada instalado."
    else
      # vazio → sem a linha RESULTADO não há marcador; falhou (rc ≠ 0) → idem: só "rc 0 + instalado e confirmado" grava o marcador
      out=$(cd "$stage" && /bin/bash "${stage}/${inst}" --no-reload --expect-sha256 "$guard_sha" 2>&1); rc=$?
      printf '%s\n' "$out"
      # a linha RECARGA PENDENTE conta: "confirmado no disco" não é "o job carregado já roda a cópia do root"; o ERRO conta: é o motivo quando o instalador recusa (vai no stderr dele)
      log "bootstrap root: instalador rc=${rc}: $(printf '%s\n' "$out" | grep -E '^(RESULTADO|RECARGA PENDENTE|ERRO):' | tr '\n' ' ')"
      if [ "$rc" = "0" ] && printf '%s\n' "$out" | grep -q '^RESULTADO: instalado e confirmado'; then
        # o modo do marcador é explícito (0644): com `>` ele herdaria o umask do ambiente, e um 0664/0666 é recusado pelo próprio dsg_root_only
        # (escrita de grupo/outros) — o instalador rodaria de novo a cada rodada, para sempre
        { printf 'sha256 %s\n' "$guard_sha"; date '+%Y-%m-%d %H:%M:%S'; } > "${marker}.new.$$" 2>/dev/null \
          && chmod 0644 "${marker}.new.$$" 2>/dev/null \
          && mv -f "${marker}.new.$$" "$marker" 2>/dev/null \
          || { log "bootstrap root: instalou mas não gravei o marcador em ${prog_dir}: a próxima rodada confere de novo"; rm -f "${marker}.new.$$" 2>/dev/null; }
      fi
    fi
  else
    log "bootstrap root: SKIP — pasta privada ou cópia falhou: nada instalado."
  fi
  rm -f "${stage}/${inst}" "${stage}/disk-snapshot-guard.sh" 2>/dev/null
  rmdir "$stage" 2>/dev/null
  return 0
}
dsg_bootstrap_root || true

AVAIL_KB=$(df -k /System/Volumes/Data 2>/dev/null | tail -1 | awk '{print $4}')
if [ -z "${AVAIL_KB}" ]; then
    log "SKIP: nao consegui ler df de /System/Volumes/Data — unknown state, nao age."
    exit 0
fi
AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))

if [ "${AVAIL_GB}" -ge "${FLOOR_GB}" ]; then
    # Healthy — nothing to do, don't even log every tick (would just be noise
    # every 10min forever). Only log the boundary-crossing runs below.
    exit 0
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
