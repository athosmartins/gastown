#!/usr/bin/env bash
# hetzner-daily-report.sh — relatório diário do nó Linux de testes (Hetzner): baterias por host, tempo, sombra, recusas/fallbacks e custo (ga-zri39b).
#
# Contents
#   Por quê · Uso · O que o relatório diz · Estados que não se confundem
#
# POR QUÊ (Athos 13/10): 100% dos testes passam a ir ao servidor alugado, "com acompanhamento de performance e custo". Este script lê o que o mbp-run.sh já
#   grava ($CITY/.gc/logs/mbp-run.jsonl: host, secs, rc; $CITY/.gc/logs/hetzner-shadow.jsonl: a sombra) e pergunta o custo à API da Hetzner (hcloud).
# USO
#   hetzner-daily-report.sh [--hours N] [--json] [--mail] [--no-cost]
#     --hours N  janela (24 por padrão) · --json  o mesmo em JSON · --mail  manda o texto ao Mayor (`gc mail send mayor`; 1x/dia pelo order
#     hetzner-daily-report) · --no-cost  não chama a API (selftest, ou sem rede). O token vem de HCLOUD_TOKEN ou do cofre (`secret Hetzner --field notes`).
#     Variáveis: HETZNER_SERVER_LABEL (padrão projeto=ga-27oza3: os servidores contados), HETZNER_REPORT_CITY.
# O QUE O RELATÓRIO DIZ
#   • baterias por host (hetzner | mbp) com rc 0 / rc 1 / outro, tempo médio, mediana (com quantidade par, a média dos dois do meio) e máximo — o lado de MBP da sombra (execuções E recusas) NÃO entra, é contado à parte;
#   • recusas e fallbacks por host e motivo (inalcancavel, ram, slots, mac-only, filtro-invalido, rsync-falhou...): é a medida de "o servidor segurou?";
#   • a sombra: mesmo rc / divergência / não rodou / estourou o tempo, e os arquivos que viraram mac-only;
#   • o custo: preço/hora do tipo no local do servidor × horas de vida dentro da janela (estimativa; a fatura é por hora cheia), horas desde a criação e tráfego
#     (tráfego que a API não deu — ausente, null, não numérico — sai "indisponível", nunca "0 GB").
# ESTADOS QUE NÃO SE CONFUNDEM: sem log ainda · log ilegível · zero execuções · custo "indisponível (motivo)" — nunca "0" no lugar de "não consegui saber".
#   Linha do log que não dá para ler vem AVISADA ("N linha(s) ilegível(is)"), não omitida — vale também para a que é JSON com ts mas que o relatório não sabe classificar
#   (sem mode, host que não é hetzner|mbp [sem o campo = mbp], rc/secs que não são número, recusa sem motivo, marcador de sombra ou veredito desconhecido). Lista mac-only aprendida que não abre diz "sem arquivo … ou ilegível", nunca "0 arquivo(s)".
#   Texto que não se formou (jq falhou) sai rc 4 com ALERTA e, com --mail, NADA é enviado: relatório truncado não passa por completo.
#   --hours é decimal mesmo com zero à esquerda (010 = 10 h, não o octal 8; o bash leria 08/09 como erro de base), de 1 a 99999; hora ou janela que não se formam: rc 4 com ALERTA, nunca um cabeçalho em 1970.
set -o pipefail
CITY=${HETZNER_REPORT_CITY:-${GC_CITY_PATH:-${GC_CITY:-/Users/athos/gt/.gascity-gastown-hq}}}
LOG="$CITY/.gc/logs/mbp-run.jsonl"
SHADOW_LOG="$CITY/.gc/logs/hetzner-shadow.jsonl"
LEARNED="$CITY/.gc/hetzner-mac-only.learned"
LABEL=${HETZNER_SERVER_LABEL:-projeto=ga-27oza3}
HERE="$(cd "$(dirname "$0")" && pwd)"

hours=24; as_json=0; do_mail=0; do_cost=1
while [ $# -gt 0 ]; do
  case "$1" in
    --hours) [ $# -ge 2 ] || { echo "hetzner-daily-report: --hours precisa de um valor (inteiro >= 1)" >&2; exit 2; }; hours="$2"; shift 2 ;;
    --json) as_json=1; shift ;;
    --mail) do_mail=1; shift ;;
    --no-cost) do_cost=0; shift ;;
    -h|--help) sed -n '2,/^set -o pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "uso: $0 [--hours N] [--json] [--mail] [--no-cost]" >&2; exit 2 ;;
  esac
done
case "$hours" in ''|*[!0-9]*) echo "hetzner-daily-report: --hours precisa de um inteiro (veio '$hours')" >&2; exit 2 ;; esac
# só dígitos NÃO basta: "010" na conta de baixo é octal (8) e "08" é erro de base (since vazio → cabeçalho em 1970 e log "ilegível" com rc 0).
# Tira os zeros à esquerda (só zeros → vazio → 0 → recusado abaixo), limita o tamanho (a conta de segundos não pode estourar) e só então vira número.
digits=${hours#"${hours%%[!0]*}"}
[ ${#digits} -le 5 ] || { echo "hetzner-daily-report: --hours precisa ser <= 99999 (veio '$hours')" >&2; exit 2; }
hours=$(( 10#${digits:-0} ))
[ "$hours" -ge 1 ] || { echo "hetzner-daily-report: --hours precisa ser >= 1" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "hetzner-daily-report: jq ausente — sem ele não leio o log" >&2; exit 3; }

# hora lida → janela; `date` que falhou/veio vazia é ALERTA e rc 4 (sem hora a janela não existe), nunca a conta rodando com since vazio
now=$(date +%s)
case "$now" in ''|*[!0-9]*) echo "hetzner-daily-report: ALERTA: não consegui ler a hora (date +%s veio '$now') — sem ela não há janela" >&2; exit 4 ;; esac
since=$(( now - hours * 3600 ))
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; }
since_iso=$(iso "$since"); now_iso=$(iso "$now")
[ -n "$since_iso" ] && [ -n "$now_iso" ] || { echo "hetzner-daily-report: ALERTA: não consegui escrever a janela como data (since='$since_iso' until='$now_iso')" >&2; exit 4; }

# ---- execuções e recusas (mbp-run.jsonl) -------------------------------------------------------------------------------------------
# Três estados: log ausente → "sem log ainda" · jq/leitura falhou → "ilegivel" · lido → o objeto. Linha ilegível conta em `bad` (e vem avisada).
runs_json='"sem log ainda"'
if [ -f "$LOG" ]; then
  runs_json=$(jq -Rs --argjson since "$since" '
    def stat($xs): ($xs | length) as $n
      | if $n == 0 then {n: 0}
        else ([$xs[] | (.secs | numbers)]) as $s
          | {n: $n, rc0: ([$xs[] | select(.rc == 0)] | length), rc1: ([$xs[] | select(.rc == 1)] | length),
             other: ([$xs[] | select(.rc != 0 and .rc != 1)] | length),
             mean_s: (if ($s | length) > 0 then ((($s | add) / ($s | length)) | floor) else null end),
             median_s: (if ($s | length) > 0 then ($s | sort | length as $m | if $m % 2 == 1 then .[($m - 1) / 2] else ((.[$m / 2 - 1] + .[$m / 2]) / 2) end) else null end),
             max_s: (if ($s | length) > 0 then ($s | max) else null end)} end;
    # uma linha SEM "host" é de antes do campo existir (= mbp); com "host", só hetzner|mbp são conhecidos
    def host: if has("host") then .host else "mbp" end;
    # linha com ts válido que o relatório sabe CLASSIFICAR; a que não sabe vai para `bad` (avisada), nunca se comporta como linha que não existe
    def readable:
      (.mode | type) == "string" and (host | . == "hetzner" or . == "mbp") and ((has("shadow") | not) or .shadow == 1)
      and (if .mode == "preflight" then (.reason | type) == "string" else (.rc | type) == "number" and (.secs | type) == "number" end);
    [split("\n")[] | select(length > 0) | (try fromjson catch null)
      | if type == "object" and ((try (.ts | fromdateiso8601) catch null) | type) == "number" then {l: ., t: (.ts | fromdateiso8601)} else {bad: 1} end] as $e
    | [$e[] | select(.l and .t >= $since) | .l] as $w
    | [$w[] | select(readable)] as $ok
    | ((([$e[] | select(.bad)] | length) + (($w | length) - ($ok | length)))) as $bad
    | ([$ok[] | select(.mode != "preflight" and .shadow != 1)]) as $runs
    | ([$ok[] | select(.mode != "preflight" and .shadow == 1)] | length) as $sh
    | ([$ok[] | select(.mode == "preflight" and .shadow != 1)]) as $ref
    | ([$ok[] | select(.mode == "preflight" and .shadow == 1)] | length) as $shref
    | {bad: $bad, shadow_mbp_side: $sh, shadow_mbp_refused: $shref,
       hetzner: stat([$runs[] | select(host == "hetzner")]),
       mbp: stat([$runs[] | select(host == "mbp")]),
       refusals: {hetzner: ([$ref[] | select(host == "hetzner")] | group_by(.reason) | map({key: .[0].reason, value: length}) | from_entries),
                  mbp: ([$ref[] | select(host == "mbp")] | group_by(.reason) | map({key: .[0].reason, value: length}) | from_entries)}}
  ' "$LOG" 2>/dev/null) || runs_json='"ilegivel"'
  [ -n "$runs_json" ] || runs_json='"ilegivel"'
fi

# ---- sombra (hetzner-shadow.jsonl) ------------------------------------------------------------------------------------------------
shadow_json='"sem log ainda"'
if [ -f "$SHADOW_LOG" ]; then
  shadow_json=$(jq -Rs --argjson since "$since" '
    [split("\n")[] | select(length > 0) | (try fromjson catch null)
      | if type == "object" and ((try (.ts | fromdateiso8601) catch null) | type) == "number" and (.verdict | IN("same", "diverge", "skipped", "timeout")) then {l: ., t: (.ts | fromdateiso8601)} else {bad: 1} end] as $e
    | ([$e[] | select(.bad)] | length) as $bad
    | [$e[] | select(.l and .t >= $since) | .l] as $w
    | {bad: $bad, same: ([$w[] | select(.verdict == "same")] | length), diverge: ([$w[] | select(.verdict == "diverge")] | length),
       skipped: ([$w[] | select(.verdict == "skipped")] | length), timeout: ([$w[] | select(.verdict == "timeout")] | length),
       files: ([$w[] | select(.verdict == "diverge") | (.files // "") | split(",")[] | select(length > 0)] | unique)}
  ' "$SHADOW_LOG" 2>/dev/null) || shadow_json='"ilegivel"'
  [ -n "$shadow_json" ] || shadow_json='"ilegivel"'
fi

# grep -v: rc 0 = há linhas úteis, rc 1 = nenhuma (arquivo vazio ou só comentário: 0 de verdade), rc ≥ 2 = não consegui ler → null, nunca "0" (o `grep -c .` do fim sempre imprime um número, então não distingue sozinho)
learned_n=null
if [ -f "$LEARNED" ]; then
  learned_body=$(grep -v -E '^[[:space:]]*(#|$)' "$LEARNED" 2>/dev/null); learned_rc=$?
  if [ $learned_rc -le 1 ]; then learned_n=$(printf '%s\n' "$learned_body" | sort -u | grep -c .); case "$learned_n" in ''|*[!0-9]*) learned_n=null ;; esac; fi
fi

# ---- custo (API da Hetzner) -------------------------------------------------------------------------------------------------------
# indisponível (motivo) é um estado de primeira classe: sem hcloud, sem token, sem rede, resposta que não é JSON ou sem servidor com o rótulo → NUNCA "0".
cost_json='{"state":"indisponivel","why":"desligado (--no-cost)"}'
if [ $do_cost -eq 1 ]; then
  cost_json='{"state":"indisponivel","why":"hcloud ausente"}'
  if command -v hcloud >/dev/null 2>&1; then
    tok=${HCLOUD_TOKEN:-}
    [ -n "$tok" ] || tok=$(secret Hetzner --field notes 2>/dev/null)
    if [ -z "$tok" ]; then cost_json='{"state":"indisponivel","why":"sem token (HCLOUD_TOKEN ou cofre: secret Hetzner --field notes)"}'
    else
      # `timeout` é do Homebrew: um PATH mínimo (order, launchd) não tem. Sem ele a chamada roda sem teto próprio (o order declara o dele); o 127 de "comando ausente" nunca é custo.
      TMO=""; command -v timeout >/dev/null 2>&1 && TMO="timeout 30"
      raw=$(HCLOUD_TOKEN="$tok" $TMO hcloud server list -l "$LABEL" -o json 2>/dev/null); rc=$?
      if [ $rc -ne 0 ] || [ -z "$raw" ]; then cost_json=$(jq -n --arg why "hcloud falhou (rc=$rc)" '{state: "indisponivel", why: $why}')
      else
        # `created` da API vem com "+00:00" ou fração de segundo conforme o cliente: o mesmo instante, não "resposta ilegível" (que é o que o fromdateiso8601 puro dá).
        # Tráfego: número → GB; ausente/null/outra coisa → null (o texto diz "indisponível"; `// 0` o transformava em "0 GB de 0 GB incluídos").
        cost_json=$(printf '%s' "$raw" | jq --argjson now "$now" --argjson since "$since" --arg label "$LABEL" '
          def epoch: sub("\\.[0-9]+"; "") | ((capture("^(?<b>.*)(?<sg>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2})$")) // null) as $o
            | if $o then (($o.b + "Z") | fromdateiso8601) - (($o.sg + "1" | tonumber) * (($o.h | tonumber) * 3600 + ($o.m | tonumber) * 60)) else fromdateiso8601 end;
          def gb: if type == "number" then . / 1000000000 else null end;
          if type != "array" then {state: "indisponivel", why: "resposta da API não é uma lista"}
          elif length == 0 then {state: "indisponivel", why: ("nenhum servidor com o rótulo " + $label)}
          else
            [ .[] | (.created | epoch) as $c
              | ((.location.name // "") as $loc | [(.server_type.prices // [])[] | select(.location == $loc) | (.price_hourly.gross | tonumber)] | .[0]) as $p
              | {name: .name, type: .server_type.name, location: .location.name, status: .status, hourly_eur: $p,
                 up_h_total: (($now - $c) / 3600), up_h_window: (($now - ([$c, $since] | max)) / 3600),
                 out_gb: (.outgoing_traffic | gb), included_gb: (.included_traffic | gb)} ] as $s
            | if ([$s[] | select(.hourly_eur == null)] | length) > 0 then {state: "indisponivel", why: "sem preço/hora no tipo ou local do servidor"}
              else {state: "ok", servers: $s,
                    window_eur: ([$s[] | .hourly_eur * .up_h_window] | add), total_eur: ([$s[] | .hourly_eur * .up_h_total] | add)} end
          end' 2>/dev/null) || cost_json='{"state":"indisponivel","why":"resposta da API ilegível"}'
        [ -n "$cost_json" ] || cost_json='{"state":"indisponivel","why":"resposta da API ilegível"}'
      fi
    fi
  fi
fi

# ---- monta ------------------------------------------------------------------------------------------------------------------------
report_json=$(jq -n --argjson hours "$hours" --arg since "$since_iso" --arg until "$now_iso" --argjson runs "$runs_json" --argjson shadow "$shadow_json" \
  --argjson cost "$cost_json" --argjson learned "$learned_n" \
  '{window_h: $hours, since: $since, until: $until, runs: $runs, shadow: $shadow, mac_only_learned: $learned, cost: $cost}') || { echo "hetzner-daily-report: não consegui montar o relatório" >&2; exit 4; }

text_report() {
  printf '%s' "$report_json" | jq -r '
    def hline($k; $h): if $h.n == 0 then "\($k)=0" else "\($k)=\($h.n) (rc0=\($h.rc0) rc1=\($h.rc1) outro=\($h.other))" end;
    def tline($k; $h): if $h.n == 0 then empty else "\($k) média \($h.mean_s // "?") s · mediana \($h.median_s // "?") s · máx \($h.max_s // "?") s" end;
    def rline($r): if ($r | length) == 0 then "nenhuma" else ($r | to_entries | map("\(.key)=\(.value)") | join(" ")) end;
    # tráfego que a API não deu (null) é "indisponível": só um número de verdade vira "N GB" (0 GB é um zero que a API informou)
    def traf: if .out_gb == null then "tráfego de saída: indisponível"
      else "tráfego de saída \(.out_gb * 100 | floor / 100) GB" + (if .included_gb == null then " (franquia incluída: indisponível)" else " de \(.included_gb | floor) GB incluídos" end) end;
    "Nó Linux de testes — últimas \(.window_h) h (\(.since) → \(.until))",
    (if (.runs | type) == "string" then
        "Baterias: \(if .runs == "ilegivel" then "log ilegível — não consegui contar" else "sem log ainda" end)"
     else
        "Baterias por host: \(hline("hetzner"; .runs.hetzner))  \(hline("mbp"; .runs.mbp))" + (if .runs.shadow_mbp_side + .runs.shadow_mbp_refused > 0 then "  [lado de MBP da sombra, fora da conta: \(.runs.shadow_mbp_side) execução(ões), \(.runs.shadow_mbp_refused) recusa(s)]" else "" end),
        ([tline("hetzner"; .runs.hetzner), tline("mbp"; .runs.mbp)] | if length == 0 then "Tempo por bateria: sem execuções" else "Tempo por bateria: " + join(" | ") end),
        "Recusas/fallbacks — nó: \(rline(.runs.refusals.hetzner)) | MBP: \(rline(.runs.refusals.mbp))"
        + (if .runs.bad > 0 then "\n⚠️ \(.runs.bad) linha(s) ilegível(is) no log (não contadas)" else "" end)
     end),
    (if (.shadow | type) == "string" then
        "Sombra: \(if .shadow == "ilegivel" then "log ilegível — não consegui contar" else "sem log ainda (a janela de 24 h da sombra ainda não rodou, ou o nó nunca foi ligado)" end)"
     else
        "Sombra: igual=\(.shadow.same) divergiu=\(.shadow.diverge) não-rodou=\(.shadow.skipped) estourou-o-tempo=\(.shadow.timeout)"
        + (if (.shadow.files | length) > 0 then " — viraram mac-only: \(.shadow.files | join(", "))" else "" end)
        + (if .shadow.bad > 0 then "\n⚠️ \(.shadow.bad) linha(s) ilegível(is) no log da sombra (não contadas)" else "" end)
     end),
    "Lista mac-only aprendida: \(if .mac_only_learned == null then "sem arquivo (nenhuma divergência até agora) ou ilegível" else "\(.mac_only_learned) arquivo(s)" end)",
    (if .cost.state == "ok" then
        (.cost.servers[] | "Custo: \(.name) (\(.type), \(.location), \(.status)) a €\(.hourly_eur * 10000 | round / 10000)/h — vivo há \(.up_h_total * 10 | floor / 10) h; \(traf)"),
        "Custo estimado na janela: €\(.cost.window_eur * 100 | round / 100) · acumulado desde a criação: €\(.cost.total_eur * 100 | round / 100) (preço/hora × horas de vida; a fatura é por hora cheia)"
     else "Custo: indisponível (\(.cost.why)) — NÃO é zero, é \"não consegui saber\"" end)'
}

# texto que não se formou (jq falhou no meio) é ALERTA e rc 4, nunca um relatório truncado dado por completo, nem mail vazio contado como enviado
if [ $as_json -eq 1 ]; then printf '%s\n' "$report_json"
else text_report || { echo "hetzner-daily-report: ALERTA: não consegui formatar o texto do relatório (jq falhou)" >&2; exit 4; }; fi

if [ $do_mail -eq 1 ]; then
  body=$(text_report) && [ -n "$body" ] || { echo "hetzner-daily-report: ALERTA: não consegui formatar o texto do relatório — NADA foi enviado ao Mayor" >&2; exit 4; }
  if gc mail send mayor -s "Nó Linux de testes: relatório diário ($(date -u +%Y-%m-%d))" -m "$body" >/dev/null 2>&1; then echo "hetzner-daily-report: relatório enviado ao Mayor" >&2
  else echo "hetzner-daily-report: ALERTA: NÃO consegui enviar o relatório ao Mayor (gc mail send falhou)" >&2; exit 5; fi
fi
exit 0
