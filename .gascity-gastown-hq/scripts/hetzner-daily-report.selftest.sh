#!/usr/bin/env bash
# hetzner-daily-report.selftest.sh — hermético: hcloud/secret/gc são stubs; o log é sintético; nada toca a API da Hetzner nem o mail de verdade. (ga-zri39b)
#
# Contents
#   Casos · Controle negativo
#
# CASOS: sem log / log ilegível / zero execuções são três respostas diferentes · contagem por host (linha antiga sem "host" = mbp) · o lado de MBP da sombra
#   não entra na conta · janela de horas · linha truncada AVISADA · recusas por host e motivo · tempo médio/mediana/máximo · sombra (iguais, divergências, arquivos) ·
#   lista aprendida · custo: preço/hora × horas na janela, servidor mais velho que a janela, e CADA falha (sem hcloud, sem token, hcloud falhou, resposta que não é
#   JSON, lista vazia, sem preço) vira "indisponível (motivo)" e nunca "€0" · --json · --mail (ok e falha) · o wrapper do order (liga/desliga/ocioso/log ilegível).
# CONTROLE NEGATIVO: o mutante que conta o lado de sombra como execução do MBP e o que lê custo indisponível como zero TÊM de reprovar nos casos acima.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPORT="${HETZNER_REPORT_UNDER_TEST:-$HERE/hetzner-daily-report.sh}"
WRAP="$HERE/../packs/town-deltas/assets/scripts/hetzner-daily-report-order.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/hdr-selftest.XXXXXX")
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
mkdir -p "$T/bin" "$T/city/.gc/logs"
C="$T/city"; LOG="$C/.gc/logs/mbp-run.jsonl"; SLOG="$C/.gc/logs/hetzner-shadow.jsonl"; FLAG="$C/.gc/hetzner-node.on"; LEARN="$C/.gc/hetzner-mac-only.learned"
fails=0; n=0
ok()  { n=$((n+1)); echo "ok   $1"; }
bad() { n=$((n+1)); echo "FAIL $1"; fails=$((fails+1)); }
check() { if [ "$2" = 1 ]; then ok "$1"; else bad "$1"; fi; }
has() { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1: '$2' ausente em: $(printf '%s' "$3" | head -c 300)"; }
hasnt() { [[ "$3" == *"$2"* ]] && bad "$1: '$2' presente" || ok "$1"; }
eq() { [ "$2" = "$3" ] && ok "$1 ($3)" || bad "$1: esperado '$2', veio '$3'"; }

# stubs. gc registra o mail; secret/hcloud obedecem ao STUB_*
cat > "$T/bin/gc" <<'EOF'
#!/usr/bin/env bash
echo "GC:$*" >> "$STUB_LOG"
[ "${STUB_GC_RC:-0}" = 0 ] || exit "$STUB_GC_RC"
EOF
cat > "$T/bin/secret" <<'EOF'
#!/usr/bin/env bash
echo "SECRET:$*" >> "$STUB_LOG"
[ "${STUB_SECRET_FAIL:-0}" = 1 ] && exit 4
printf 'tok-fake'
EOF
cat > "$T/bin/hcloud" <<'EOF'
#!/usr/bin/env bash
echo "HCLOUD:$* TOKEN=${HCLOUD_TOKEN:+set}" >> "$STUB_LOG"
[ "${STUB_HCLOUD_RC:-0}" = 0 ] || exit "$STUB_HCLOUD_RC"
[ -n "${STUB_HCLOUD_OUT:-}" ] && { printf '%s' "$STUB_HCLOUD_OUT"; exit 0; }
now=$(date +%s); created=$(( now - ${STUB_AGE_H:-6} * 3600 ))
c=$(date -u -r "$created" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$created" +%Y-%m-%dT%H:%M:%SZ)
printf '[{"name":"urblink-teste-1","status":"running","created":"%s","location":{"name":"fsn1"},"outgoing_traffic":2000000000,"included_traffic":21990000000000,"server_type":{"name":"cax41","prices":[{"location":"fsn1","price_hourly":{"gross":"%s"}}]}}]' "$c" "${STUB_PRICE:-0.1}"
EOF
chmod +x "$T/bin/"*
export STUB_LOG="$T/stub.log"
# PATH sem o hcloud de verdade (/opt/homebrew/bin) — jq vem de /usr/bin
SAFEPATH="/usr/bin:/bin:/usr/sbin:/sbin"
run() { HETZNER_REPORT_CITY="$C" PATH="$T/bin:$SAFEPATH" "$REPORT" "$@" 2>"$T/err"; }
run_nostub() { HETZNER_REPORT_CITY="$C" PATH="$SAFEPATH" "$REPORT" "$@" 2>"$T/err"; }
reset() { : > "$STUB_LOG"; rm -f "$LOG" "$SLOG" "$FLAG" "$LEARN"; unset STUB_HCLOUD_RC STUB_HCLOUD_OUT STUB_AGE_H STUB_PRICE STUB_GC_RC STUB_SECRET_FAIL HCLOUD_TOKEN; }
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ago() { date -u -v-"$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$1 ago" +%Y-%m-%dT%H:%M:%SZ; }
t_old=$(ago 3d); t_2h=$(ago 2H 2>/dev/null || ago "2 hours")
L() { printf '{"ts":"%s","repo":"wa","mode":"pytest","slot":"1","rc":%s,"secs":%s,"nargs":2,"presence":"livre","demoted":0%s}\n' "$1" "$2" "$3" "$4"; }
R() { printf '{"ts":"%s","repo":"-","mode":"preflight","slot":"-","rc":98,"secs":0,"nargs":0,"reason":"%s","presence":"-"%s}\n' "$1" "$2" "$3"; }

echo "--- estados do log"
reset; out=$(run --no-cost); rc=$?; eq "sem log: rc 0" 0 "$rc"; has "sem log: 'sem log ainda', não zero" "Baterias: sem log ainda" "$out"
reset; : > "$LOG"; out=$(run --no-cost); has "log vazio: zero execuções (não 'sem log')" "hetzner=0" "$out"; hasnt "log vazio não diz 'sem log ainda'" "Baterias: sem log ainda" "$out"
reset; L "$now" 0 5 ',"host":"hetzner"' > "$LOG"; chmod 000 "$LOG"; out=$(run --no-cost); has "log sem permissão: 'ilegível', nunca zero" "log ilegível" "$out"; hasnt "log ilegível não vira 'hetzner=0'" "hetzner=0" "$out"; chmod 644 "$LOG"

echo "--- contagem"
reset
{ L "$now" 0 20 ',"host":"hetzner"'; L "$now" 1 40 ',"host":"hetzner"'; L "$now" 0 60 ''; L "$now" 0 70 ',"host":"mbp","shadow":1'
  R "$now" inalcancavel ',"host":"hetzner"'; R "$now" mac-only ',"host":"hetzner"'; R "$now" ram ''; L "$t_old" 0 999 ',"host":"hetzner"'; printf '{"ts":"%s","repo":"wa","mode":"pyt' "$now"; echo; } > "$LOG"
out=$(run --no-cost)
has "hetzner=2 (rc0=1 rc1=1)" "hetzner=2 (rc0=1 rc1=1 outro=0)" "$out"
has "linha antiga SEM host conta como mbp (mbp=1)" "mbp=1 (rc0=1 rc1=0 outro=0)" "$out"
has "o lado de MBP da sombra fica fora da conta e é dito" "lado de MBP da sombra, fora da conta: 1" "$out"
has "tempo médio/mediana/máximo do nó" "hetzner média 30 s · mediana 40 s · máx 40 s" "$out"
hasnt "a execução de 3 dias atrás (999 s) fica fora da janela de 24 h" "999" "$out"
has "recusas do nó por motivo" "nó: inalcancavel=1 mac-only=1" "$out"
has "recusas do MBP por motivo (linha sem host = mbp)" "MBP: ram=1" "$out"
has "linha truncada é AVISADA, não omitida" "1 linha(s) ilegível(is) no log (não contadas)" "$out"
out=$(run --no-cost --hours 100); has "janela maior (100 h) inclui a de 3 dias" "hetzner=3" "$out"
out=$(run --no-cost --hours abc); rc=$?; eq "--hours inválido: rc 2" 2 "$rc"
out=$(run --no-cost --hours 0); rc=$?; eq "--hours 0: rc 2" 2 "$rc"
out=$(run --no-cost --bogus); rc=$?; eq "opção desconhecida: rc 2" 2 "$rc"

echo "--- sombra e lista aprendida"
reset; L "$now" 0 5 ',"host":"hetzner"' > "$LOG"
out=$(run --no-cost); has "sem log da sombra: dito" "Sombra: sem log ainda" "$out"
{ printf '{"ts":"%s","repo":"wa","verdict":"same","a_host":"hetzner","a_rc":0,"b_host":"mbp","b_rc":0,"files":"","learned":0}\n' "$now"
  printf '{"ts":"%s","repo":"wa","verdict":"same","a_host":"hetzner","a_rc":0,"b_host":"mbp","b_rc":0,"files":"","learned":0}\n' "$now"
  printf '{"ts":"%s","repo":"wa","verdict":"diverge","a_host":"hetzner","a_rc":0,"b_host":"mbp","b_rc":1,"files":"tests/test_x.py,tests/test_y.py","learned":2}\n' "$now"
  printf '{"ts":"%s","repo":"wa","verdict":"timeout","a_host":"hetzner","a_rc":0,"b_host":"mbp","b_rc":null,"files":"","learned":0}\n' "$now"
  printf '{"ts":"%s","repo":"wa","verdict":"diverge","a_host":"hetzner","a_rc":0,"b_host":"mbp","b_rc":1,"files":"tests/test_x.py","learned":1}\n' "$t_old"
  printf '{"ts":"%s","repo":"wa","verd' "$now"; echo; } > "$SLOG"
printf '# 2026 sombra: rc nó=0 mbp=1\ntests/test_x.py\ntests/test_y.py\n\ntests/test_x.py\n' > "$LEARN"
out=$(run --no-cost)
has "sombra: contagens (a divergência velha fica fora)" "Sombra: igual=2 divergiu=1 não-rodou=0 estourou-o-tempo=1" "$out"
has "sombra: arquivos que viraram mac-only" "viraram mac-only: tests/test_x.py, tests/test_y.py" "$out"
has "sombra: linha truncada avisada" "1 linha(s) ilegível(is) no log da sombra" "$out"
has "lista aprendida: 2 arquivos únicos (comentário, vazio e repetido não contam)" "Lista mac-only aprendida: 2 arquivo(s)" "$out"
rm -f "$LEARN"; out=$(run --no-cost); has "sem lista aprendida: dito (não '0 arquivos')" "Lista mac-only aprendida: sem arquivo" "$out"

echo "--- custo"
reset; L "$now" 0 5 ',"host":"hetzner"' > "$LOG"
out=$(HCLOUD_TOKEN=abc run); has "custo: preço/hora × 6 h de vida = €0.6 na janela" "Custo estimado na janela: €0.6" "$out"
has "custo: acumulado desde a criação" "acumulado desde a criação: €0.6" "$out"; has "custo: o servidor e o tipo" "urblink-teste-1 (cax41, fsn1, running) a €0.1/h" "$out"
has "custo: tráfego de saída em GB" "tráfego de saída 2 GB de 21990 GB" "$out"
has "token do ambiente chegou ao hcloud (e o filtro por rótulo foi pedido)" "HCLOUD:server list -l projeto=ga-27oza3 -o json TOKEN=set" "$(cat "$STUB_LOG")"
hasnt "com HCLOUD_TOKEN no ambiente o cofre não é consultado" "SECRET:" "$(cat "$STUB_LOG")"
reset; L "$now" 0 5 ',"host":"hetzner"' > "$LOG"; out=$(STUB_AGE_H=72 run); has "servidor mais velho que a janela: só 24 h na janela (€2.4)" "Custo estimado na janela: €2.4" "$out"; has "…e o acumulado cobre as 72 h (€7.2)" "acumulado desde a criação: €7.2" "$out"
reset; L "$now" 0 5 ',"host":"hetzner"' > "$LOG"; out=$(run); has "sem HCLOUD_TOKEN o token vem do cofre" "SECRET:Hetzner --field notes" "$(cat "$STUB_LOG")"; has "…e o custo sai" "Custo estimado na janela" "$out"
reset; L "$now" 0 5 ',"host":"hetzner"' > "$LOG"
out=$(run_nostub); has "sem hcloud: indisponível" "Custo: indisponível (hcloud ausente)" "$out"; hasnt "sem hcloud NÃO diz €0" "€0" "$out"
out=$(STUB_SECRET_FAIL=1 run); has "sem token: indisponível com o motivo" "Custo: indisponível (sem token" "$out"; hasnt "sem token NÃO diz €0" "€0" "$out"
out=$(HCLOUD_TOKEN=abc STUB_HCLOUD_RC=1 run); has "hcloud falhou: indisponível com o rc" "indisponível (hcloud falhou (rc=1))" "$out"; hasnt "hcloud falhou NÃO diz €0" "€0" "$out"
out=$(HCLOUD_TOKEN=abc STUB_HCLOUD_OUT='oops not json' run); has "resposta que não é JSON: indisponível" "indisponível (resposta da API ilegível)" "$out"
out=$(HCLOUD_TOKEN=abc STUB_HCLOUD_OUT='[]' run); has "lista vazia: indisponível (não €0)" "nenhum servidor com o rótulo projeto=ga-27oza3" "$out"
out=$(HCLOUD_TOKEN=abc STUB_HCLOUD_OUT='{"error":"x"}' run); has "resposta que não é lista: indisponível" "resposta da API não é uma lista" "$out"
out=$(HCLOUD_TOKEN=abc STUB_HCLOUD_OUT='[{"name":"s","status":"running","created":"2026-10-13T10:00:00Z","location":{"name":"fsn1"},"server_type":{"name":"x","prices":[]}}]' run); has "sem preço do tipo: indisponível" "sem preço/hora no tipo ou local" "$out"; hasnt "sem preço NÃO diz €0" "€0" "$out"

echo "--- --json e --mail"
reset; L "$now" 0 5 ',"host":"hetzner"' > "$LOG"
j=$(run --no-cost --json); check "--json é JSON válido" "$(printf '%s' "$j" | jq -e . >/dev/null 2>&1 && echo 1 || echo 0)"
eq "--json: hetzner.n" 1 "$(printf '%s' "$j" | jq -r '.runs.hetzner.n')"; eq "--json: custo indisponível é estado, não número" "indisponivel" "$(printf '%s' "$j" | jq -r '.cost.state')"
j=$(HCLOUD_TOKEN=abc run --json); eq "--json: custo ok" "ok" "$(printf '%s' "$j" | jq -r '.cost.state')"
out=$(run --no-cost --mail); rc=$?; eq "--mail: rc 0" 0 "$rc"; has "--mail: manda ao Mayor com assunto datado" "GC:mail send mayor -s Nó Linux de testes: relatório diário ($(date -u +%Y-%m-%d))" "$(cat "$STUB_LOG")"
: > "$STUB_LOG"; out=$(STUB_GC_RC=1 run --no-cost --mail); rc=$?; eq "--mail que falha: rc 5 (não finge que enviou)" 5 "$rc"; has "--mail que falha: ALERTA" "ALERTA: NÃO consegui enviar" "$(cat "$T/err")"

echo "--- wrapper do order"
wrap() { GC_CITY_PATH="$C" HETZNER_REPORT_SCRIPT="$REPORT" PATH="$T/bin:$SAFEPATH" bash "$WRAP" 2>"$T/err"; echo "rc=$?"; }
reset; touch "$FLAG"; : > "$STUB_LOG"; out=$(wrap); has "bandeira ligada: manda o relatório" "GC:mail send mayor" "$(cat "$STUB_LOG")"; has "bandeira ligada: rc 0" "rc=0" "$out"
reset; : > "$STUB_LOG"; L "$now" 0 5 ',"host":"hetzner"' > "$LOG"; out=$(wrap); has "bandeira desligada mas o nó trabalhou nas últimas 24 h: manda o último relatório" "GC:mail send mayor" "$(cat "$STUB_LOG")"
reset; : > "$STUB_LOG"; L "$now" 0 5 ',"host":"mbp"' > "$LOG"; out=$(wrap); hasnt "desligado e ocioso: NÃO manda" "GC:mail" "$(cat "$STUB_LOG")"; has "desligado e ocioso: diz por quê e sai 0" "nothing to report" "$out"; has "…rc 0" "rc=0" "$out"
reset; : > "$STUB_LOG"; out=$(wrap); has "desligado e sem log nenhum: manda (não sei se o nó trabalhou)" "GC:mail send mayor" "$(cat "$STUB_LOG")"
reset; : > "$STUB_LOG"; L "$now" 0 5 ',"host":"mbp"' > "$LOG"; chmod 000 "$LOG"; out=$(wrap); has "desligado e log ilegível: manda (o inerte é avisar)" "GC:mail send mayor" "$(cat "$STUB_LOG")"; chmod 644 "$LOG"
reset; out=$(GC_CITY_PATH="$C" HETZNER_REPORT_SCRIPT="$T/nao-existe.sh" PATH="$T/bin:$SAFEPATH" bash "$WRAP" 2>&1; echo "rc=$?"); has "relatório ausente é FALHA (rc 1), não sucesso calado" "rc=1" "$out"; has "…e diz qual" "report script not found" "$out"

echo "--- controle negativo"
sed 's/ and \.shadow != 1//' "$REPORT" > "$T/mut1.sh"; chmod +x "$T/mut1.sh"
reset; { L "$now" 0 20 ',"host":"hetzner"'; L "$now" 0 70 ',"host":"mbp","shadow":1'; } > "$LOG"
real=$(HETZNER_REPORT_CITY="$C" PATH="$T/bin:$SAFEPATH" "$REPORT" --no-cost --json 2>/dev/null | jq -r '.runs.mbp.n'); mut=$(HETZNER_REPORT_CITY="$C" PATH="$T/bin:$SAFEPATH" "$T/mut1.sh" --no-cost --json 2>/dev/null | jq -r '.runs.mbp.n')
eq "controle: o script real não conta a sombra como execução do MBP" 0 "$real"; check "controle: o mutante (sem o filtro da sombra) conta 1 e é pego (veio '$mut')" "$([ "$mut" = 1 ] && echo 1 || echo 0)"
sed 's/"state":"indisponivel","why":"hcloud ausente"/"state":"ok","servers":[],"window_eur":0,"total_eur":0/' "$REPORT" > "$T/mut2.sh"; chmod +x "$T/mut2.sh"
reset; L "$now" 0 5 ',"host":"hetzner"' > "$LOG"
real=$(HETZNER_REPORT_CITY="$C" PATH="$SAFEPATH" "$REPORT" 2>/dev/null | grep -c 'Custo: indisponível'); mut=$(HETZNER_REPORT_CITY="$C" PATH="$SAFEPATH" "$T/mut2.sh" 2>/dev/null | grep -c 'Custo: indisponível')
eq "controle: o script real diz 'indisponível' sem hcloud" 1 "$real"; check "controle: o mutante (indisponível lido como zero) deixa de dizer e é pego (veio $mut)" "$([ "$mut" = 0 ] && echo 1 || echo 0)"

echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
