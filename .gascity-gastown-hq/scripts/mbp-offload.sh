#!/usr/bin/env bash
# mbp-offload.sh — chave de ligar/desligar/pausar o uso do MacBook Pro como nó de capacidade (Athos 11/10 e 12/10).
#
# Contents
#   Uso · O que é a chave · Modos · Saída JSON
#
# USO
#   mbp-offload.sh on        liga (cria $CITY/.gc/mbp-offload.on)
#   mbp-offload.sh off       desliga (remove o arquivo; mbp-run.sh passa a sair 99 e todo mundo roda local)
#   mbp-offload.sh pause     "pausar até eu liberar" (ga-77c1qg): nada novo começa e o que já roda no MBP cai para prioridade de
#                            fundo. Grava $CITY/.gc/mbp-offload.pause aqui E ~/gt-remote/PAUSE no MBP (o mesmo interruptor também se
#                            aciona de lá: `~/gt-remote/bin/gascity-mbp pausar`). Alias: pausar
#   mbp-offload.sh resume    libera a pausa nos dois lados. Só apaga a pausa daqui depois de confirmar que a do MBP saiu (MBP
#                            inalcançável = continua pausada, com aviso: estado inerte); `resume --local-only` apaga só a daqui.
#                            Alias: liberar
#   mbp-offload.sh install-mbp   copia o `gascity-mbp` (pausar/liberar/status/barra de menu) e a biblioteca de presença para
#                            ~/gt-remote/bin/ no MBP
#   mbp-offload.sh status    modo agora (desligado | pausado | LIVRE | EM USO) e POR QUÊ, o que está rodando no MBP (repo, teste, há
#                            quanto tempo), o total do dia, saúde do MBP (RAM livre, pressão de memória, swap e seu crescimento,
#                            tomada/bateria, load) + últimas 5 linhas do log + a contagem de recusas por motivo nas últimas 72 h
#                            (é por ela que se mede "recusa indevida", ga-9e2rjh)
#   mbp-offload.sh status --json   o mesmo em JSON (insumo do botão do painel)
#   mbp-offload.sh counts    só a linha da contagem das últimas 72 h (sem falar com o MBP): "<N> execuções; recusas: <motivo>=<n>"
#                            ou "sem log ainda" ou "ilegível"; linhas do log que não deu para ler vêm avisadas, nunca omitidas
#   mbp-offload.sh today     só o total de hoje (sem falar com o MBP): "<N> execuções, <M> min no MBP (livre: a, em uso: b)" e, se o nó Linux rodou
#                            algo, " + <K> no nó Linux (<T> min)"
#   mbp-offload.sh node on|off|status   a bandeira do NÓ LINUX de testes (Hetzner, ga-zri39b): $CITY/.gc/hetzner-node.on. É independente da chave do MBP: `off`
#                            e `pause` acima NÃO desligam o nó (que é máquina dedicada), e o nó ligado segue valendo com o MBP desligado ou pausado. Desligar o nó =
#                            `node off` (apaga a bandeira; o servidor em si é do Mayor). Quem decide a cadeia nó -> MBP -> mini é o mbp-run.sh
#
# A CHAVE é só arquivo-bandeira: sem daemon, sem launchd, sem estado escondido. O botão do painel (bead própria, mockup antes)
# apenas chama este script.
#
# MODOS (ga-77c1qg; o MBP é o notebook de trabalho do Athos, o mini é o servidor)
#   DESLIGADO  falta a bandeira .on: tudo roda local.
#   PAUSADO    o Athos mandou parar (daqui ou do MBP): tudo roda local; o que já roda lá vai para prioridade de fundo.
#   LIVRE      ele está fora (tela bloqueada, ou 10 min sem teclado/mouse e nenhum app segurando a tela): até um slot por núcleo.
#   EM USO     ele está no MBP, ou não deu para saber: 1 execução por vez, em prioridade de fundo, e só com o MBP saudável.
set -o pipefail
CITY=${MBP_CITY:-${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}}
FLAG="$CITY/.gc/mbp-offload.on"
PAUSE="$CITY/.gc/mbp-offload.pause"
LOG="$CITY/.gc/logs/mbp-run.jsonl"
NODEFLAG="$CITY/.gc/hetzner-node.on"
RUN="${MBP_OFFLOAD_RUN:-$(cd "$(dirname "$0")" && pwd)/mbp-run.sh}"

# Contagem das últimas 72 h: "<N> execuções; recusas: <motivo>=<n> ..." ou "...; recusas: nenhuma".
# Três estados que NUNCA se confundem: log ausente → "sem log ainda"; jq falhou/não existe/log ilegível → "ilegível" (nunca
# "nenhuma"); lido e sem recusa → "nenhuma". Linha que não dá para ler (não é JSON objeto, ts que não vira data, "mode" que não é
# texto, ou recusa sem motivo em texto) NÃO derruba a leitura e NÃO some em silêncio: vira "; N linha(s) ilegível(is) no log (não contadas)".
# Sem isso, uma linha de recusa truncada deixava "recusas: nenhuma" mentir justo na medição de "recusa indevida". Linha
# ilegível não tem ts confiável, então conta mesmo fora da janela de 72 h (melhor avisar a mais do que esconder).
recent_counts() {
  local out
  [ -f "$LOG" ] || { echo "sem log ainda"; return; }
  # jq que não consegue abrir o arquivo ainda imprime a conta de uma entrada vazia ("0 execuções; recusas: nenhuma") ANTES de sair
  # com erro: por isso a saída só vale se o rc for 0 (falhou → só "ilegível", nunca o veredito de uma leitura que não houve)
  # PRECEDÊNCIA DO JQ: "A + B as $x | ..." é "(A+B) as $x" no jq 1.8.1 mas "A + (B as $x | ...)" no 1.7.1 do /usr/bin (o que o launchd,
  # de PATH mínimo, resolve) — por isso a soma de $bad vem entre parênteses; o selftest roda estes casos sob cada jq, por caminho.
  out=$(jq -Rrs --argjson since "$(( $(date +%s) - 259200 ))" '
    # hosts conhecidos: hetzner|mbp (linha SEM "host" = mbp, de antes do campo). Outro valor não se classifica: é avisado, nunca contado como do MBP.
    def hostok: (if has("host") then .host else "mbp" end) | . == "hetzner" or . == "mbp";
    [split("\n")[] | select(length > 0)
      | (try fromjson catch null)
      | if type == "object" and ((try (.ts | fromdateiso8601) catch null) | type) == "number"
        then {l: ., t: (.ts | fromdateiso8601)} else {bad: 1} end] as $e
    | [$e[] | select(.l and .t >= $since) | .l] as $w
    | (([$e[] | select(.bad)] | length) + ([$w[] | select((.mode | type) != "string" or (.mode == "preflight" and (.reason | type) != "string") or (hostok | not))] | length)) as $bad
    | ([$w[] | select((.mode | type) == "string" and .mode != "preflight" and hostok)] | length) as $runs
    | [$w[] | select(.mode == "preflight" and (.reason | type) == "string" and hostok)] as $ref
    | "\($runs) execuções; recusas: " + (if ($ref | length) == 0 then "nenhuma" else ($ref | group_by((if .host == "hetzner" then "hetzner:" else "" end) + .reason) | map("\(if .[0].host == "hetzner" then "hetzner:" else "" end)\(.[0].reason)=\(length)") | join(" ")) end)
      + (if $bad > 0 then "; \($bad) linha(s) ilegível(is) no log (não contadas)" else "" end)
  ' "$LOG" 2>/dev/null) || { echo "ilegível"; return; }
  [ -n "$out" ] || { echo "ilegível"; return; }
  printf '%s\n' "$out"
}

# Total de hoje (desde a meia-noite LOCAL), do log: "<N> execuções, <M> min no MBP (livre: a, em uso: b[, sem presença registrada: c])".
# Mesmos três estados da contagem de 72 h: log ausente → "sem log ainda"; jq falhou/relógio ilegível → "ilegível" (nunca "0
# execuções"); lido → o total. Linha do log que não dá para ler não derruba nem some: vem avisada (inclusive a de host que não é hetzner|mbp e a de secs que não é número: sem ela
# os "N execuções" teriam mais linhas que os minutos somados, e o total pareceria completo). Recusas do preflight não são execução.
# São minutos de MBP LITERAIS: a execução do lado de MBP de uma sombra ("shadow":1) conta aqui, porque o MBP trabalhou de verdade (o relatório diário a tira, que mede o nó).
# (a soma de $bad vem entre parênteses e o $r é ligado no começo da pipeline: o "A + B as $x" do jq 1.7.1 lê diferente do 1.8.1.)
today_counts() {
  local out since
  [ -f "$LOG" ] || { echo "sem log ainda"; return; }
  since=$(date -v0H -v0M -v0S +%s 2>/dev/null) || { echo "ilegível"; return; }
  case "$since" in ''|*[!0-9]*) echo "ilegível"; return ;; esac
  out=$(jq -Rrs --argjson since "$since" '
    def hostok: (if has("host") then .host else "mbp" end) | . == "hetzner" or . == "mbp";
    [split("\n")[] | select(length > 0)
      | (try fromjson catch null)
      | if type == "object" and ((try (.ts | fromdateiso8601) catch null) | type) == "number" and ((.mode | type) == "string")
        then {l: ., t: (.ts | fromdateiso8601)} else {bad: 1} end] as $e
    | ([$e[] | select(.bad)] | length) as $bad0
    | [$e[] | select(.l and .t >= $since and .l.mode != "preflight") | .l] as $win
    | [$win[] | select(hostok and ((.secs | type) == "number"))] as $all
    | (($bad0 + (($win | length) - ($all | length)))) as $bad
    | [$all[] | select(.host == "hetzner")] as $nr
    | [$all[] | select(.host != "hetzner")] as $r
    | ([$r[] | select(.presence == "livre")] | length) as $livre
    | ([$r[] | select(.presence == "uso")] | length) as $uso
    | (($r | length) - $livre - $uso) as $sem
    | (([$r[] | (.secs | numbers)] | add) // 0) as $secs
    | (([$nr[] | (.secs | numbers)] | add) // 0) as $nsecs
    | "\($r | length) execuções, \(($secs / 60) | floor) min no MBP (livre: \($livre), em uso: \($uso)"
      + (if $sem > 0 then ", sem presença registrada: \($sem)" else "" end) + ")"
      + (if ($nr | length) > 0 then " + \($nr | length) no nó Linux (\(($nsecs / 60) | floor) min)" else "" end)
      + (if $bad > 0 then "; \($bad) linha(s) ilegível(is) no log (não contadas)" else "" end)
  ' "$LOG" 2>/dev/null) || { echo "ilegível"; return; }
  [ -n "$out" ] || { echo "ilegível"; return; }
  printf '%s\n' "$out"
}

# valor de uma chave k=v da saída do `mbp-run.sh --check` (última ocorrência não vazia vale; vazio = "não consegui saber")
kv() { printf '%s\n' "$2" | sed -n "s/^$1=//p" | head -1; }

# "há 2 min 10 s" a partir de segundos
ago() { local s=$1; if [ "$s" -lt 60 ]; then echo "${s} s"; elif [ "$s" -lt 3600 ]; then echo "$((s / 60)) min $((s % 60)) s"; else echo "$((s / 3600)) h $(((s % 3600) / 60)) min"; fi; }

# Linhas "task=<slot>|<dono host:pid:epoch>|<info>|<mtime>" (do preflight) → uma linha legível por tarefa. Dono do MESMO host com
# pid morto é slot ÓRFÃO (o próximo mbp-run o recolhe): aparece como tal, nunca como "rodando".
tasks_text() { # saída do --check
  local line n owner info h p e now age st me="$(hostname -s 2>/dev/null)"
  now=$(date +%s)
  printf '%s\n' "$1" | sed -n 's/^task=//p' | while IFS='|' read -r n owner info _; do
    [ -n "$n" ] || continue
    h=${owner%%:*}; p=${owner#*:}; p=${p%%:*}; e=${owner##*:}
    st=""; age=""
    case "$e" in ''|*[!0-9]*) ;; *) age=" há $(ago $(( now - e )))" ;; esac
    if [ "$h" = "$me" ] && [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then st=" [ÓRFÃO: dono $owner morto — o próximo mbp-run recolhe]"; fi
    printf '  slot %s: %s%s%s\n' "$n" "${info:-?}" "$age" "$st"
  done
}
tasks_count_live() { # quantas tarefas não-órfãs
  local n=0 line owner h p me="$(hostname -s 2>/dev/null)"
  while IFS='|' read -r _ owner _; do
    h=${owner%%:*}; p=${owner#*:}; p=${p%%:*}
    if [ "$h" = "$me" ] && [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then continue; fi
    n=$((n + 1))
  done < <(printf '%s\n' "$1" | sed -n 's/^task=//p')
  echo "$n"
}

why_text() { # presence_why idle_s
  case "$1" in
    bloqueada) echo "tela bloqueada" ;;
    ocioso) echo "sem teclado/mouse há ${2:-?} s" ;;
    input_recente) echo "teclado/mouse há ${2:-?} s" ;;
    tela_em_uso) echo "um app segura a tela acesa (chamada/vídeo/apresentação), mesmo sem teclado/mouse há ${2:-?} s" ;;
    forcado) echo "forçado por MBP_FORCE_PRESENCE=uso" ;;
    ilegivel:*) echo "não consegui ler a presença (${1#ilegivel:}): por segurança conta como em uso" ;;
    *) echo "${1:-sem motivo}" ;;
  esac
}

# a hora em que a bandeira do nó vale como ligada = o MTIME do arquivo, nunca o texto gravado dentro dele: a janela de 24 h da sombra
# (mbp-run.sh shadow_window_open) conta pelo mtime, e `touch` a reabre (runbook). Pelo conteúdo, depois de um touch o status seguiria dizendo
# a hora antiga do `node on`. Vazio = desligado / mtime ilegível (quem chama mostra "?", nunca uma data inventada; no --json: desligado = null, ligado e ilegível = "unreadable").
node_since() {
  [ -f "$NODEFLAG" ] || return 0
  local m; m=$(stat -f %m "$NODEFLAG" 2>/dev/null || stat -c %Y "$NODEFLAG" 2>/dev/null)
  case "$m" in ''|*[!0-9]*) return 0 ;; esac
  date -u -r "$m" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$m" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}
node_state_text() {
  if [ -f "$NODEFLAG" ]; then echo "LIGADO desde $(node_since | grep . || echo '?') (a sombra de 24 h conta daí; desliga: mbp-offload.sh node off)"
  else echo "DESLIGADO (liga: mbp-offload.sh node on) — as baterias seguem a cadeia de sempre"; fi
}

cmd=${1:-status}
case "$cmd" in
  on)  mkdir -p "$(dirname "$FLAG")" && date -u +%Y-%m-%dT%H:%M:%SZ > "$FLAG" && echo "MBP offload: LIGADO" ;;
  off) rm -f "$FLAG"; echo "MBP offload: DESLIGADO (tudo roda local)" ;;
  pause|pausar)
    origin=${MBP_PAUSE_ORIGIN:-painel}
    mkdir -p "$(dirname "$PAUSE")" && printf 'origem=%s desde=%s\n' "$origin" "$(date +%Y-%m-%dT%H:%M:%S%z)" > "$PAUSE" || { echo "MBP offload: NÃO consegui gravar a pausa em $PAUSE" >&2; exit 1; }
    # a pausa chega ao MBP para que o que já roda lá seja rebaixado; sem MBP, a pausa daqui já impede qualquer execução nova
    if MBP_PAUSE_ORIGIN="$origin" "$RUN" --remote-pause on >/dev/null 2>&1; then echo "MBP offload: PAUSADO (aqui e no MBP): nada novo começa; o que já roda lá cai para prioridade de fundo"
    else echo "MBP offload: PAUSADO aqui (nada novo começa). AVISO: o MBP não recebeu a pausa (inalcançável?): o que já roda lá NÃO foi rebaixado" ; fi ;;
  resume|liberar)
    if [ "${2:-}" = "--local-only" ]; then rm -f "$PAUSE"; echo "MBP offload: pausa daqui removida (a do MBP, se existir, NÃO foi tocada)"
    elif "$RUN" --remote-pause off >/dev/null 2>&1; then rm -f "$PAUSE"; echo "MBP offload: LIBERADO (pausa removida aqui e no MBP)"
    else
      echo "MBP offload: NÃO liberei — não consegui confirmar a remoção da pausa no MBP (inalcançável?). A pausa continua valendo (estado seguro)." >&2
      echo "  tente de novo quando o MBP responder; se o MBP está fora de vez: mbp-offload.sh resume --local-only" >&2
      exit 1
    fi ;;
  install-mbp) "$RUN" --install-tools ;;
  node)
    case "${2:-status}" in
      on)
        # já ligado: NÃO regrava. A janela de 24 h da sombra conta do mtime da bandeira (mbp-run.sh shadow_window_open), então regravar = recomeçar a sombra sem querer.
        # Reabrir de propósito: `touch` na bandeira (ou node off && node on).
        if [ -f "$NODEFLAG" ]; then echo "Nó Linux de testes: já LIGADO desde $(node_since | grep . || echo '?') — a bandeira NÃO foi regravada (regravar reabriria a sombra de 24 h; para reabri-la de propósito: touch $NODEFLAG)"
        else mkdir -p "$(dirname "$NODEFLAG")" && date -u +%Y-%m-%dT%H:%M:%SZ > "$NODEFLAG" && echo "Nó Linux de testes: LIGADO (a sombra de 24 h começa agora; o MBP, a pausa dele e o mini seguem como reserva)" || { echo "Nó Linux: NÃO consegui gravar $NODEFLAG" >&2; exit 1; }
        fi ;;
      off) rm -f "$NODEFLAG"; [ -e "$NODEFLAG" ] && { echo "Nó Linux: NÃO consegui apagar $NODEFLAG" >&2; exit 1; }; echo "Nó Linux de testes: DESLIGADO (bandeira apagada; o servidor em si é do Mayor)" ;;
      status) node_state_text ;;
      *) echo "uso: $0 node on|off|status" >&2; exit 2 ;;
    esac ;;
  status)
    state=off; [ -f "$FLAG" ] && state=on
    health=$(MBP_CITY="$CITY" "$RUN" --check 2>/dev/null); hrc=$?
    recent=$(tail -n 5 "$LOG" 2>/dev/null)
    presence=$(kv presence "$health"); pwhy=$(kv presence_why "$health"); idle=$(kv idle_s "$health")
    paused_l=$([ -e "$PAUSE" ] && echo 1 || echo 0); paused_r=$(kv paused "$health")
    cap=$(kv slot_cap "$health"); pinfo=$(kv pause_info "$health"); plinfo=$(kv pause_local_info "$health")
    reach=1; [ -n "$paused_r" ] || reach=0     # o remoto sempre responde paused=0|1; vazio = o ssh não chegou
    # modo: a primeira regra que vale decide
    if [ "$state" = off ]; then mode=desligado; mwhy="falta a bandeira de liga"
    elif [ "$paused_l" = 1 ] || [ "$paused_r" = 1 ]; then mode=pausado; mwhy="${plinfo:-${pinfo:-pausa}}"
    elif [ "$reach" = 0 ]; then mode=inalcancavel; mwhy="ssh não respondeu"
    elif [ "$presence" = livre ]; then mode=livre; mwhy="$pwhy"
    else mode=em_uso; mwhy="${pwhy:-ilegivel:presenca}"; fi
    if [ "${2:-}" = "--json" ]; then
      tasks_raw=$(printf '%s\n' "$health" | sed -n 's/^task=//p')
      tasks_json=$(printf '%s\n' "$tasks_raw" | jq -Rn '[inputs | select(length > 0) | split("|") | {slot: .[0], owner: (.[1] // ""), info: (.[2] // ""), mtime: (.[3] // "")}]' 2>/dev/null) || tasks_json=null
      hj=$(printf '%s\n' "$health" | awk -F= 'NF==2 && $1!="" && $1!="task" {printf "%s\"%s\":\"%s\"", (n++?",":""), $1, $2}')
      recent_json=$(printf '%s\n' "$recent" | jq -Rn '[inputs | select(length > 0) | (try fromjson catch {unreadable: .})]' 2>/dev/null) || recent_json=null
      jq -n --arg offload "$state" --arg mode "$mode" --arg why "$mwhy" --arg presence "$presence" --arg idle "$idle" --arg cap "$cap" \
        --arg today "$(today_counts)" --arg nodeflag "$([ -f "$NODEFLAG" ] && echo on || echo off)" --arg nodesince "$(node_since)" --argjson healthy "$([ $hrc -eq 0 ] && echo true || echo false)" \
        --argjson paused_local "$([ "$paused_l" = 1 ] && echo true || echo false)" --argjson paused_mbp "$([ "$paused_r" = 1 ] && echo true || echo false)" \
        --argjson health "{$hj}" --argjson tasks "$tasks_json" --argjson recent "$recent_json" \
        '{offload: $offload, mode: $mode, mode_why: $why, presence: $presence, idle_s: ($idle | tonumber? // null), slot_cap: ($cap | tonumber? // null),
          paused: {local: $paused_local, mbp: $paused_mbp}, tasks: $tasks, today: $today, healthy: $healthy, health: $health, recent: $recent,
          node: {flag: $nodeflag, since: (if $nodeflag == "off" then null elif $nodesince == "" then "unreadable" else $nodesince end)}}'
    else
      echo "MBP offload: $(echo $state | tr a-z A-Z)  (since: $( [ -f "$FLAG" ] && cat "$FLAG" || echo - ))"
      case "$mode" in
        desligado) echo "Modo: DESLIGADO — tudo roda local (liga: mbp-offload.sh on)" ;;
        pausado) echo "Modo: PAUSADO ($mwhy) — nada novo começa no MBP; o que já roda lá cai para prioridade de fundo (libera: mbp-offload.sh resume, ou 'gascity-mbp liberar' no MBP)" ;;
        inalcancavel) echo "Modo: INDEFINIDO — MBP inalcançável por ssh; tudo roda local" ;;
        livre) echo "Modo: LIVRE — Athos fora ($(why_text "$mwhy" "$idle")): até ${cap:-?} tarefas ao mesmo tempo, carga alta permitida" ;;
        em_uso) echo "Modo: EM USO — tratado como \"Athos no MBP\" ($(why_text "$mwhy" "$idle")): no máximo ${cap:-1} tarefa por vez, prioridade de fundo, só com o MBP saudável" ;;
      esac
      if [ "$reach" = 1 ]; then
        live=$(tasks_count_live "$(printf '%s\n' "$health")")
        echo "Rodando agora no MBP: $live tarefa(s)"
        tasks_text "$health"
      fi
      echo "Nó Linux de testes: $(node_state_text)"
      echo "Hoje: $(today_counts)"
      if [ $hrc -eq 0 ]; then echo "MBP saudável:"; elif [ $hrc -eq 99 ]; then echo "MBP pausado (rc=99); leituras do preflight:"; else echo "MBP SEM SAÚDE (rc=$hrc) — execuções caem para local:"; fi
      printf '%s\n' "$health" | grep -v '^task=' | sed 's/^/  /'
      echo "últimas execuções ($LOG):"
      if [ -n "$recent" ]; then printf '%s\n' "$recent" | jq -r '"  \(.ts) \(.repo)/\(.mode) slot=\(.slot) rc=\(.rc) \(.secs)s" + (if .presence then " presença=\(.presence)" else "" end) + (if .host then " host=\(.host)" else "" end) + (if .demoted == 1 then " REBAIXADA-NO-MEIO" else "" end) + (if .reason then " motivo=\(.reason)" else "" end)' 2>/dev/null || printf '%s\n' "$recent"
      else echo "  (nenhuma)"; fi
      echo "últimas 72 h: $(recent_counts)"
    fi ;;
  counts) recent_counts ;;
  today) today_counts ;;
  -h|--help|help) sed -n '2,/^[^#]/{/^#/p;}' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "uso: $0 on|off|pause|resume [--local-only]|install-mbp|node on|off|status|status [--json]|counts|today" >&2; exit 2 ;;
esac
