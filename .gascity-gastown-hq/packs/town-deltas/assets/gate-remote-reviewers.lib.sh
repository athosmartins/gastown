#!/usr/bin/env bash
# gate-remote-reviewers.lib.sh — qual revisor o gate abre: o do nó Hetzner primeiro, o local só se o nó não puder (ga-2hd02v.1.9)
#
# Contents: O que é · A flag · O nó · gate_remote_flag_state · gate_remote_node_state · gate_remote_pick_template
#
# O QUE É. Escolhe, a cada revisor que o quality-gate-dispatcher vai abrir, entre `gate-reviewer` (mini) e `gate-reviewer-remote` (a
# sessão tem `-remote-` no nome; o provider híbrido a manda ao nó). A TAREFA é a mesma: esta lib decide ONDE o Claude roda, nunca O QUE
# revisa. Só ESCOLHE: não abre nada e só pergunta ao nó o `list-running`. Runbook: docs/runbooks/gate-reviewer-remote.md.
# O dispatcher a carrega à prova de falha (lib ausente ou quebrada = tudo local) e chama `gate_remote_pick_template` SEM `$(...)` (o
# log escreve em stdout e seria engolido), lendo GATE_REMOTE_PICK_TEMPLATE, GATE_REMOTE_PICK_KIND (inert = flag desligada | node |
# fallback = flag ligada e o nó não serve) e GATE_REMOTE_PICK_WHY (uma linha de log).
#
# A FLAG $GC_CITY/.gc/gate-remote-reviewers.on (precedente: gate-e5-second-reviewer.on); criá-la é o passo de ligar, decisão do Mayor
# depois do flip da 1.6. Três estados: ligada / desligada / ilegível. O NÓ: `room`, `full`, `unready` (o start seria recusado) ou
# `unknown` (não deu para ver), e `unknown` NÃO é `room`. Cabe = (vivas no nó < `cap` do host em .gc/session-ssh.json) E (remotos vivos
# < max_active_sessions do template); os dois tetos são LIDOS. Saída não entendida (rc≠0, estouro, linha estranha, jq/`timeout`
# ausente, teto ilegível) vira o template local: o pior erro é um revisor rodar onde sempre rodou, nunca um gate sem revisor. Cada
# leitura diz o que faz quando vem VAZIA e quando FALHA (regra E12). Bash 3.2: só funções e atribuições no topo (o dispatcher roda sob
# `set -euo pipefail`); toda função devolve 0 e comunica por stdout/globais.

GATE_REMOTE_TEMPLATE="${GATE_REMOTE_TEMPLATE:-gate-reviewer-remote}"
GATE_REMOTE_LOCAL_TEMPLATE="${GATE_REMOTE_LOCAL_TEMPLATE:-gate-reviewer}"
# Segundos que o `list-running` pode levar. Só inteiro >= 1; vazio, texto ou 0 voltam ao padrão (`timeout 0` = sem limite).
GATE_REMOTE_PROBE_SECS="${GATE_REMOTE_PROBE_SECS:-30}"

GATE_REMOTE_PICK_TEMPLATE=""
GATE_REMOTE_PICK_KIND=""
GATE_REMOTE_PICK_WHY=""

# gate_remote_flag_state — "on", "off" ou "unreadable".
#   arquivo existe e se lê       → on
#   arquivo não existe           → off  (vazio É a resposta: ninguém ligou)
#   a pasta não se enxerga, o caminho não se monta (GC_CITY vazio), o arquivo existe e não se lê, ou é link quebrado
#                                → unreadable (não deu para ver; o chamador trata como desligada e DIZ isso no log)
gate_remote_flag_state() {
  local f="${GATE_REMOTE_FLAG_FILE:-}" d=""
  if [ -z "$f" ]; then
    [ -n "${GC_CITY:-}" ] || { printf 'unreadable'; return 0; }
    f="${GC_CITY}/.gc/gate-remote-reviewers.on"
  fi
  d="$(dirname "$f" 2>/dev/null)" || d=""
  if [ -z "$d" ] || [ ! -d "$d" ] || [ ! -x "$d" ]; then printf 'unreadable'; return 0; fi
  if [ -L "$f" ] && [ ! -e "$f" ]; then printf 'unreadable'; return 0; fi
  if [ -e "$f" ]; then
    if [ -r "$f" ]; then printf 'on'; else printf 'unreadable'; fi
    return 0
  fi
  printf 'off'
  return 0
}

# _gate_remote_template_cap — max_active_sessions do template remoto, ou nada.
#   linha ausente / arquivo ausente / valor que não é inteiro >= 1 → imprime NADA (o chamador trata como `unknown`, nunca inventa teto)
_gate_remote_template_cap() {
  local toml="${GATE_REMOTE_AGENT_TOML:-${GC_CITY:-}/agents/${GATE_REMOTE_TEMPLATE}/agent.toml}" v=""
  [ -r "$toml" ] || return 0
  v="$(sed -n 's/^max_active_sessions *= *\([0-9][0-9]*\).*/\1/p' "$toml" 2>/dev/null | head -n 1)" || v=""
  case "$v" in ''|*[!0-9]*|0) return 0 ;; esac
  printf '%s' "$v"
  return 0
}

# _gate_remote_host_facts — "cap=<n> rig=<0|1> rel=<0|1>" do host que os revisores usam, ou nada.
#   O host é $GC_SSH_HOST, senão o default_host (o nome `gate-reviewer-remote-adhoc-<10>` não pede host). Com mais de um host na config
#   e sem $GC_SSH_HOST o `list-running` junta todos e o `cap` de um só não vale para a soma: imprime NADA.
#   arquivo ausente/ilegível, jq ausente ou falhou, host fora da config, cap que não é inteiro >= 0 → imprime NADA (= unknown)
_gate_remote_host_facts() {
  local cfg="${GATE_REMOTE_SSH_CONFIG:-${GC_SSH_CONFIG:-${GC_CITY:-}/.gc/session-ssh.json}}" out=""
  [ -r "$cfg" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  out="$(jq -r '
      (env.GC_SSH_HOST // "") as $e
      | (.hosts // null) as $hs
      | if ($hs|type) != "object" then empty
        elif ($e == "" and ($hs|length) != 1) then empty
        else (if $e != "" then $e else (.default_host // ($hs|keys[0])) end) as $hn
          | ($hs[$hn] // null) as $h
          | if ($h|type) != "object" then empty
            elif (($h.cap|type) != "number") or ($h.cap < 0) or (($h.cap|floor) != $h.cap) then empty
            else "cap=\($h.cap) rig=\(if (($h.worktree_rigs|type) == "object") and (($h.worktree_rigs["gate-reviewer"]|type) == "string") and (($h.worktree_rigs["gate-reviewer"]|length) > 0) then 1 else 0 end) rel=\(if (($h.real_sessions_released_by|type) == "string") and (($h.real_sessions_released_by|length) > 0) then 1 else 0 end)"
            end
        end' "$cfg" 2>/dev/null)" || out=""
  printf '%s' "$out"
  return 0
}

# gate_remote_node_state — uma linha: "room", "full:<porquê>", "unready:<porquê>" ou "unknown:<porquê>".
gate_remote_node_state() {
  local ssh_bin="${GATE_REMOTE_SSH_BIN:-${GC_CITY:-}/scripts/gc-session-ssh}" secs="$GATE_REMOTE_PROBE_SECS"
  local tbin="" facts="" cap="" rig="" rel="" tcap="" raw="" rc=0 line="" total=0 rem=0
  case "$secs" in ''|*[!0-9]*|0) secs=30 ;; esac

  # Config do host. VAZIO ou ilegível = não sabemos os tetos = unknown (nunca "cabe").
  facts="$(_gate_remote_host_facts)" || facts=""
  case "$facts" in
    "cap="*" rig="*" rel="*) : ;;
    *) printf 'unknown:host config unreadable or ambiguous (cap not read)'; return 0 ;;
  esac
  cap="${facts#cap=}"; cap="${cap%% *}"
  rig="${facts#* rig=}"; rig="${rig%% *}"
  rel="${facts#* rel=}"; rel="${rel%% *}"
  if [ "$rel" != "1" ]; then printf 'unready:host has no real_sessions_released_by (the start would be refused)'; return 0; fi
  if [ "$rig" != "1" ]; then printf 'unready:host worktree_rigs has no "gate-reviewer" (the start would be refused, exit 13)'; return 0; fi

  # Teto do template. Ausente/ilegível = unknown.
  tcap="$(_gate_remote_template_cap)" || tcap=""
  [ -n "$tcap" ] || { printf 'unknown:template max_active_sessions unreadable'; return 0; }

  # Quem está vivo no nó. `list-running` imprime um nome por linha; rc≠0 é host fora do ar/lista parcial = unknown.
  # Saída VAZIA com rc 0 é a resposta "nenhuma sessão" (cabe), e só vale com rc 0.
  [ -x "$ssh_bin" ] || { printf 'unknown:%s not executable' "$ssh_bin"; return 0; }
  tbin="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
  [ -n "$tbin" ] || { printf 'unknown:no timeout/gtimeout binary to bound the node probe'; return 0; }
  raw="$("$tbin" -k 5 "$secs" "$ssh_bin" list-running 2>/dev/null)" && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then printf 'unknown:node probe timed out after %ss' "$secs"; else printf 'unknown:node probe failed (rc=%s)' "$rc"; fi
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in
      *[!A-Za-z0-9_.-]*) printf 'unknown:node probe returned a line that is not a session name'; return 0 ;;
    esac
    total=$((total + 1))
    case "$line" in "${GATE_REMOTE_TEMPLATE}"-*) rem=$((rem + 1)) ;; esac
  done <<EOF
$raw
EOF
  if [ "$total" -ge "$cap" ]; then printf 'full:node has %s of %s sessions' "$total" "$cap"; return 0; fi
  if [ "$rem" -ge "$tcap" ]; then printf 'full:node has %s of %s %s sessions' "$rem" "$tcap" "$GATE_REMOTE_TEMPLATE"; return 0; fi
  printf 'room'
  return 0
}

# gate_remote_pick_template — decide o template do PRÓXIMO revisor. Seta as três globais; devolve sempre 0.
gate_remote_pick_template() {
  local fs="" ns=""
  GATE_REMOTE_PICK_TEMPLATE="$GATE_REMOTE_LOCAL_TEMPLATE"
  GATE_REMOTE_PICK_KIND="inert"
  GATE_REMOTE_PICK_WHY="gate-remote-reviewers.on absent"
  fs="$(gate_remote_flag_state)" || fs="unreadable"
  case "$fs" in
    off) return 0 ;;
    on) : ;;
    *) GATE_REMOTE_PICK_KIND="fallback"; GATE_REMOTE_PICK_WHY="remote-reviewer flag UNREADABLE - local reviewer"; return 0 ;;
  esac
  ns="$(gate_remote_node_state)" || ns="unknown:node state call failed"
  case "$ns" in
    room)
      GATE_REMOTE_PICK_TEMPLATE="$GATE_REMOTE_TEMPLATE"; GATE_REMOTE_PICK_KIND="node"
      GATE_REMOTE_PICK_WHY="node has room - remote reviewer first" ;;
    full:*|unready:*|unknown:*)
      GATE_REMOTE_PICK_KIND="fallback"; GATE_REMOTE_PICK_WHY="${ns%%:*} (${ns#*:}) - local reviewer" ;;
    *)
      GATE_REMOTE_PICK_KIND="fallback"; GATE_REMOTE_PICK_WHY="unexpected node state - local reviewer" ;;
  esac
  return 0
}
