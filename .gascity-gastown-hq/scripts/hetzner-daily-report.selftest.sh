#!/usr/bin/env bash
# hetzner-daily-report.selftest.sh — hermético: hcloud/secret/gc são stubs; o log é sintético; nada toca a API da Hetzner nem o mail de verdade. (ga-zri39b)
#
# Contents
#   Casos · Controle negativo
#
# CASOS: sem log / log ilegível / zero execuções são três respostas diferentes · contagem por host (linha antiga sem "host" = mbp) · o lado de MBP da sombra
#   (execuções E recusas) não entra na conta · janela de horas (--hours com zero à esquerda é decimal: 08, 010, 012; teto de 5 dígitos) · linha truncada AVISADA, e também a que é JSON mas não dá para classificar (sem mode, host que não é
#   hetzner/mbp, rc/secs que não são número, recusa sem motivo, marcador de sombra ou veredito desconhecido) · --hours sem valor · recusas por host e motivo ·
#   tempo médio/mediana (par: média dos dois do meio)/máximo · sombra (iguais, divergências, arquivos) ·
#   lista aprendida (ausente, ilegível e só-comentário são três respostas) · texto que não se forma (rc 4, nenhum mail) · custo: preço/hora × horas na janela, servidor mais velho que a janela, e CADA falha (sem hcloud, sem token, hcloud falhou, resposta que não é
#   JSON, lista vazia, sem preço) vira "indisponível (motivo)" e nunca "€0" · tráfego ausente/null/não numérico vira "indisponível", nunca "0 GB" · `created` com +00:00, fração ou
#   outro fuso é o mesmo instante · --json · --mail (ok e falha) · o wrapper do order (liga/desliga/ocioso/log ilegível/linha que o relatório avisa como ilegível).
# HDR_SELFTEST_JQDIR=<dir com um jq> roda o relatório sob outro jq (o do order é o do Homebrew; sem isso é o /usr/bin).
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
# jq: só o formatador de texto do relatório chama `jq -r` como 1º argumento; STUB_JQ_FAIL_TEXT=1 derruba esse e o resto passa ao jq de verdade
cat > "$T/bin/jq" <<'EOF'
#!/usr/bin/env bash
[ "${STUB_JQ_FAIL_TEXT:-0}" = 1 ] && [ "${1:-}" = "-r" ] && { echo "stub jq: falha injetada" >&2; exit 5; }
exec "$(PATH="$STUB_REAL_PATH" command -v jq)" "$@"
EOF
chmod +x "$T/bin/"*
export STUB_LOG="$T/stub.log"
# PATH sem o hcloud de verdade (/opt/homebrew/bin) — jq vem de /usr/bin (HDR_SELFTEST_JQDIR=<dir com um jq> o troca: o order roda com o jq do Homebrew, outra versão)
SAFEPATH="${HDR_SELFTEST_JQDIR:+$HDR_SELFTEST_JQDIR:}/usr/bin:/bin:/usr/sbin:/sbin"; export STUB_REAL_PATH="$SAFEPATH"
run() { HETZNER_REPORT_CITY="$C" PATH="$T/bin:$SAFEPATH" "$REPORT" "$@" 2>"$T/err"; }
run_nostub() { HETZNER_REPORT_CITY="$C" PATH="$SAFEPATH" "$REPORT" "$@" 2>"$T/err"; }
reset() { : > "$STUB_LOG"; rm -f "$LOG" "$SLOG" "$FLAG" "$LEARN"; unset STUB_HCLOUD_RC STUB_HCLOUD_OUT STUB_AGE_H STUB_PRICE STUB_GC_RC STUB_SECRET_FAIL STUB_JQ_FAIL_TEXT HCLOUD_TOKEN; }
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
has "tempo médio/mediana/máximo do nó (20 s e 40 s: a mediana de dois é a média dos dois, 30 — não o de cima)" "hetzner média 30 s · mediana 30 s · máx 40 s" "$out"
hasnt "a execução de 3 dias atrás (999 s) fica fora da janela de 24 h" "999" "$out"
has "recusas do nó por motivo" "nó: inalcancavel=1 mac-only=1" "$out"
has "recusas do MBP por motivo (linha sem host = mbp)" "MBP: ram=1" "$out"
has "linha truncada é AVISADA, não omitida" "1 linha(s) ilegível(is) no log (não contadas)" "$out"
out=$(run --no-cost --hours 100); has "janela maior (100 h) inclui a de 3 dias" "hetzner=3" "$out"
out=$(run --no-cost --hours abc); rc=$?; eq "--hours inválido: rc 2" 2 "$rc"
out=$(run --no-cost --hours 0); rc=$?; eq "--hours 0: rc 2" 2 "$rc"
out=$(run --no-cost --bogus); rc=$?; eq "opção desconhecida: rc 2" 2 "$rc"
# --hours como ÚLTIMO argumento travava num laço infinito (o `shift 2` falha sem consumir nada): por isso o caso roda com teto de 5 s (124 = travou)
run_capped() {
  local pid i; HETZNER_REPORT_CITY="$C" PATH="$T/bin:$SAFEPATH" "$REPORT" "$@" >"$T/capped.out" 2>"$T/err" & pid=$!
  for i in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; { wait "$pid"; } 2>/dev/null; return 124; fi
  wait "$pid"
}
run_capped --no-cost --hours; rc=$?; eq "--hours sem valor (último argumento): rc 2, não trava" 2 "$rc"; has "…e diz o que faltou" "--hours precisa de um valor" "$(cat "$T/err")"

echo "--- --hours com zero à esquerda é decimal (o bash lê 010 como OCTAL = 8, e 08/09 como erro de base)"
agoh() { ago "${1}H" 2>/dev/null || ago "$1 hours"; }
reset; { L "$(agoh 1)" 0 11 ',"host":"hetzner"'; L "$(agoh 9)" 0 22 ',"host":"hetzner"'; L "$(agoh 11)" 0 33 ',"host":"hetzner"'; } > "$LOG"
for h in 08 09 010 012; do
  d=$((10#$h)); j=$(run --no-cost --json --hours "$h"); rc=$?
  eq "--hours $h: rc 0" 0 "$rc"; hasnt "--hours $h: nada de erro de base no stderr" "too great" "$(cat "$T/err")"
  eq "--hours $h: o rótulo e a janela de fato concordam ($d h = $((d * 3600)) s)" "$d $((d * 3600))" "$(printf '%s' "$j" | jq -r '"\(.window_h) \((.until | fromdateiso8601) - (.since | fromdateiso8601))"' 2>/dev/null)"
done
out=$(run --no-cost --hours 08); has "--hours 08: a janela de 8 h pega só a bateria de 1 h atrás" "hetzner=1 (" "$out"; has "…e o cabeçalho diz 8 h" "últimas 8 h" "$out"; hasnt "…e o log legível não vira 'log ilegível'" "log ilegível" "$out"
out=$(run --no-cost --hours 010); has "--hours 010: janela de 10 h pega a de 9 h atrás (em octal seria 8 h e daria 1)" "hetzner=2 (" "$out"
out=$(run --no-cost --hours 012); has "--hours 012: janela de 12 h pega as 3 (em octal seria 10 h e daria 2)" "hetzner=3 (" "$out"
j=$(run --no-cost --json --hours 0000000000000000024); rc=$?; eq "zeros demais à esquerda não estouram nada: rc 0" 0 "$rc"; eq "…e valem 24 h de verdade (86400 s; em octal seriam 20 h)" "24 86400" "$(printf '%s' "$j" | jq -r '"\(.window_h) \((.until | fromdateiso8601) - (.since | fromdateiso8601))"' 2>/dev/null)"
out=$(run --no-cost --hours 000); rc=$?; eq "--hours 000: rc 2 (o piso é 1 h)" 2 "$rc"
out=$(run --no-cost --hours 99999999999999999999); rc=$?; eq "--hours com 20 dígitos: rc 2 (estouraria a conta de segundos)" 2 "$rc"; has "…e diz o teto" "precisa ser <= 99999" "$(cat "$T/err")"
out=$(run --no-cost --hours 99999); rc=$?; eq "--hours 99999 (o teto) segue valendo" 0 "$rc"

echo "--- mediana"
reset; { L "$now" 0 10 ',"host":"hetzner"'; L "$now" 0 20 ',"host":"hetzner"'; L "$now" 0 30 ',"host":"hetzner"'; L "$now" 0 100 ',"host":"hetzner"'; } > "$LOG"
out=$(run --no-cost); has "mediana de quantidade PAR: média dos dois do meio (10 20 30 100 → 25), não o de cima (30)" "mediana 25 s" "$out"
reset; { L "$now" 0 15 ',"host":"hetzner"'; L "$now" 0 10 ',"host":"hetzner"'; } > "$LOG"
out=$(run --no-cost); has "mediana de dois valores é a média deles (12.5), não o maior (15)" "mediana 12.5 s" "$out"
reset; { L "$now" 0 50 ',"host":"hetzner"'; L "$now" 0 10 ',"host":"hetzner"'; L "$now" 0 20 ',"host":"hetzner"'; } > "$LOG"
out=$(run --no-cost); has "mediana de quantidade ÍMPAR continua sendo o do meio (10 20 50 → 20)" "mediana 20 s" "$out"

echo "--- linha que não dá para classificar é AVISADA, nunca se comporta como linha que não existe"
BADMSG="linha(s) ilegível(is) no log (não contadas)"
reset; { L "$now" 0 5 ',"host":"hetzner"'; printf '{"ts":"%s","repo":"wa","slot":"1","rc":0,"secs":3,"host":"hetzner"}\n' "$now"; } > "$LOG"
out=$(run --no-cost); has "ts válido mas SEM 'mode': avisada" "⚠️ 1 $BADMSG" "$out"; has "…e não vira execução (hetzner=1)" "hetzner=1 (rc0=1" "$out"
reset; { L "$now" 0 5 ',"host":"hetzner"'; printf '{"ts":"%s","repo":"-","mode":"preflight","slot":"-","rc":98,"secs":0,"host":"hetzner"}\n' "$now"; } > "$LOG"
out=$(run --no-cost); has "recusa SEM motivo em texto: avisada (não vira 'nenhuma' calada)" "⚠️ 1 $BADMSG" "$out"
reset; { L "$now" 0 5 ',"host":"hetzner"'; L "$now" 0 7 ',"host":"hetzner2"'; } > "$LOG"
out=$(run --no-cost); has "host que não é hetzner nem mbp: avisado" "⚠️ 1 $BADMSG" "$out"; has "…e não entra na conta do nó (hetzner=1)" "hetzner=1 (rc0=1" "$out"; hasnt "…nem na do MBP" "mbp=1" "$out"
reset; { L "$now" 0 5 ',"host":"hetzner"'; R "$now" ram ',"host":"hetzner2"'; } > "$LOG"
out=$(run --no-cost); has "recusa com host desconhecido: avisada" "⚠️ 1 $BADMSG" "$out"; has "…e não entra nas recusas do MBP" "MBP: nenhuma" "$out"
reset; { L "$now" 0 5 ',"host":"hetzner"'; L "$now" null 5 ',"host":"hetzner"'; L "$now" '"0"' 5 ',"host":"hetzner"'; } > "$LOG"
out=$(run --no-cost); has "rc que não é número (null, \"0\"): avisado, não vira 'outro'" "⚠️ 2 $BADMSG" "$out"; has "…e a conta do nó fica só com a linha legível" "hetzner=1 (rc0=1 rc1=0 outro=0)" "$out"
reset; { L "$now" 0 5 ',"host":"hetzner"'; L "$now" 0 '"x"' ',"host":"hetzner"'; } > "$LOG"
out=$(run --no-cost); has "secs que não é número: avisado (a média não é de menos linhas que o 'n')" "⚠️ 1 $BADMSG" "$out"; has "…e a conta do nó fica só com a linha legível" "hetzner=1 (rc0=1" "$out"
reset; { L "$now" 0 5 ',"host":"hetzner"'; L "$now" 0 70 ',"host":"mbp","shadow":"sim"'; } > "$LOG"
out=$(run --no-cost); has "marcador 'shadow' que não é 1: avisado, não vira execução do MBP" "⚠️ 1 $BADMSG" "$out"; has "…e o MBP fica em 0" "mbp=0" "$out"
j=$(run --no-cost --json); eq "--json: runs.bad conta a linha com marcador de sombra ilegível" 1 "$(printf '%s' "$j" | jq -r '.runs.bad')"

echo "--- recusa do lado de MBP da sombra fica fora das recusas do MBP"
reset; { L "$now" 0 20 ',"host":"hetzner"'; R "$now" ram ',"host":"mbp","shadow":1'; R "$now" ram ',"host":"mbp"'; } > "$LOG"
out=$(run --no-cost); j=$(run --no-cost --json)
has "só a recusa SEM sombra é do MBP (ram=1, não ram=2)" "MBP: ram=1" "$out"; has "…e a do lado de sombra é dita à parte, com as execuções" "fora da conta: 0 execução(ões), 1 recusa(s)" "$out"
eq "--json: runs.shadow_mbp_refused" 1 "$(printf '%s' "$j" | jq -r '.runs.shadow_mbp_refused')"; eq "--json: recusa da sombra não entra em refusals.mbp" '{"ram":1}' "$(printf '%s' "$j" | jq -c '.runs.refusals.mbp')"
reset; { L "$now" 0 70 ',"host":"mbp","shadow":1'; } > "$LOG"
out=$(run --no-cost); has "execução do lado de sombra segue dita (e diz que não houve recusa)" "fora da conta: 1 execução(ões), 0 recusa(s)" "$out"

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
printf 'tests/test_x.py\n' > "$LEARN"; chmod 000 "$LEARN"; out=$(run --no-cost); j=$(run --no-cost --json); chmod 644 "$LEARN"
has "lista aprendida que não abre: 'sem arquivo … ou ilegível'" "Lista mac-only aprendida: sem arquivo" "$out"; hasnt "lista aprendida ilegível NÃO vira '0 arquivo(s)'" "0 arquivo(s)" "$out"
eq "lista aprendida ilegível: --json traz null, não 0" "null" "$(printf '%s' "$j" | jq -c '.mac_only_learned')"
printf '# só comentário\n\n' > "$LEARN"; out=$(run --no-cost); has "lista só com comentário: 0 arquivo(s) de verdade" "Lista mac-only aprendida: 0 arquivo(s)" "$out"
# veredito que não é um dos quatro conhecidos não é "igual" nem "divergiu": é linha que o relatório não sabe classificar, e vem avisada
reset; L "$now" 0 5 ',"host":"hetzner"' > "$LOG"
{ printf '{"ts":"%s","repo":"wa","verdict":"same","a_host":"hetzner","a_rc":0,"b_host":"mbp","b_rc":0,"files":"","learned":0}\n' "$now"
  printf '{"ts":"%s","repo":"wa","verdict":"Same","a_host":"hetzner","a_rc":0,"b_host":"mbp","b_rc":0,"files":"","learned":0}\n' "$now"
  printf '{"ts":"%s","repo":"wa","verdict":"equal","a_host":"hetzner","a_rc":0,"b_host":"mbp","b_rc":0,"files":"","learned":0}\n' "$now"; } > "$SLOG"
out=$(run --no-cost); has "sombra: veredito fora de same/diverge/skipped/timeout é avisado" "⚠️ 2 linha(s) ilegível(is) no log da sombra (não contadas)" "$out"; has "…e só o veredito legível conta" "Sombra: igual=1 divergiu=0 não-rodou=0 estourou-o-tempo=0" "$out"

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
# tráfego ausente/null/que não é número é "não consegui saber", nunca "0 GB de 0 GB incluídos" (o jq engolia o null em 0 com `// 0`)
srv() { printf '[{"name":"s1","status":"running","created":"%s","location":{"name":"fsn1"}%s,"server_type":{"name":"cax41","prices":[{"location":"fsn1","price_hourly":{"gross":"0.1"}}]}}]' "${2:-$(agoh 6)}" "$1"; }
for tr in ',"outgoing_traffic":null,"included_traffic":null' '' ',"outgoing_traffic":"abc","included_traffic":"x"' ',"outgoing_traffic":null,"included_traffic":21990000000000'; do
  out=$(HCLOUD_TOKEN=abc STUB_HCLOUD_OUT="$(srv "$tr")" run); j=$(HCLOUD_TOKEN=abc STUB_HCLOUD_OUT="$(srv "$tr")" run --json)
  has "tráfego de saída [${tr:-ausente}]: indisponível" "tráfego de saída: indisponível" "$out"; hasnt "…e NÃO diz 0 GB" "0 GB" "$out"; has "…o custo em si segue (€0.6: o preço não depende do tráfego)" "Custo estimado na janela: €0.6" "$out"
  eq "…--json: out_gb é null, não 0" "null" "$(printf '%s' "$j" | jq -c '.cost.servers[0].out_gb')"
done
out=$(HCLOUD_TOKEN=abc STUB_HCLOUD_OUT="$(srv ',"outgoing_traffic":2000000000,"included_traffic":null')" run); j=$(HCLOUD_TOKEN=abc STUB_HCLOUD_OUT="$(srv ',"outgoing_traffic":2000000000,"included_traffic":null')" run --json)
has "saída conhecida e franquia desconhecida: diz as duas coisas" "tráfego de saída 2 GB (franquia incluída: indisponível)" "$out"; hasnt "…e a franquia NÃO vira '0 GB incluídos'" "de 0 GB" "$out"; eq "…--json: included_gb é null" "null" "$(printf '%s' "$j" | jq -c '.cost.servers[0].included_gb')"
out=$(HCLOUD_TOKEN=abc STUB_HCLOUD_OUT="$(srv ',"outgoing_traffic":0,"included_traffic":21990000000000')" run); has "zero DE VERDADE segue sendo zero (servidor novo, nada saiu)" "tráfego de saída 0 GB de 21990 GB incluídos" "$out"
# 'created' como a API da Hetzner o escreve (+00:00), com fração de segundo ou com outro fuso: é o MESMO instante, não "resposta ilegível"
c6=$(agoh 6); c6z=${c6%Z}
isoat() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }; e6=$(( $(date +%s) - 6 * 3600 ))
# +08:00 e +09:00 também: "08"/"09" no fuso é a mesma armadilha do octal do --hours
for cr in "${c6z}+00:00" "${c6z}.123456789Z" "$(agoh 4 | sed 's/Z$/+02:00/')" "$(agoh 9 | sed 's/Z$/-03:00/')" "$(isoat $((e6 + 8 * 3600)) | sed 's/Z$/+08:00/')" "$(isoat $((e6 + 9 * 3600)) | sed 's/Z$/+0900/')"; do
  out=$(HCLOUD_TOKEN=abc STUB_HCLOUD_OUT="$(srv ',"outgoing_traffic":2000000000,"included_traffic":21990000000000' "$cr")" run); has "created '$cr' = 6 h atrás: custo €0.6" "Custo estimado na janela: €0.6" "$out"
done
out=$(HCLOUD_TOKEN=abc STUB_HCLOUD_OUT="$(srv '' ontem)" run); has "created que não é data: indisponível (resposta ilegível), nunca €0" "indisponível (resposta da API ilegível)" "$out"; hasnt "…nem €0" "€0" "$out"

echo "--- --json e --mail"
reset; L "$now" 0 5 ',"host":"hetzner"' > "$LOG"
j=$(run --no-cost --json); check "--json é JSON válido" "$(printf '%s' "$j" | jq -e . >/dev/null 2>&1 && echo 1 || echo 0)"
eq "--json: hetzner.n" 1 "$(printf '%s' "$j" | jq -r '.runs.hetzner.n')"; eq "--json: custo indisponível é estado, não número" "indisponivel" "$(printf '%s' "$j" | jq -r '.cost.state')"
j=$(HCLOUD_TOKEN=abc run --json); eq "--json: custo ok" "ok" "$(printf '%s' "$j" | jq -r '.cost.state')"
out=$(run --no-cost --mail); rc=$?; eq "--mail: rc 0" 0 "$rc"; has "--mail: manda ao Mayor com assunto datado" "GC:mail send mayor -s Nó Linux de testes: relatório diário ($(date -u +%Y-%m-%d))" "$(cat "$STUB_LOG")"
: > "$STUB_LOG"; out=$(STUB_GC_RC=1 run --no-cost --mail); rc=$?; eq "--mail que falha: rc 5 (não finge que enviou)" 5 "$rc"; has "--mail que falha: ALERTA" "ALERTA: NÃO consegui enviar" "$(cat "$T/err")"
out=$(STUB_JQ_FAIL_TEXT=1 run --no-cost); rc=$?; eq "texto que não se formou (jq falhou): rc 4" 4 "$rc"; has "…com ALERTA" "não consegui formatar o texto do relatório" "$(cat "$T/err")"
: > "$STUB_LOG"; out=$(STUB_JQ_FAIL_TEXT=1 run --no-cost --mail); rc=$?; eq "--mail com texto que não se formou: rc 4" 4 "$rc"; hasnt "…e nenhum mail sai" "GC:mail" "$(cat "$STUB_LOG")"
# --json --mail: a tela não passa pelo formatador, então quem pega é o corpo do mail (vazio/truncado não é enviado nem contado como enviado)
: > "$STUB_LOG"; out=$(STUB_JQ_FAIL_TEXT=1 run --no-cost --json --mail); rc=$?; eq "--json --mail com corpo que não se formou: rc 4" 4 "$rc"; hasnt "…e nenhum mail sai" "GC:mail" "$(cat "$STUB_LOG")"; has "…e diz que NADA foi enviado" "NADA foi enviado ao Mayor" "$(cat "$T/err")"; hasnt "…e não diz 'enviado' como se tivesse ido" "relatório enviado ao Mayor" "$(cat "$T/err")"

echo "--- wrapper do order"
wrap() { GC_CITY_PATH="$C" HETZNER_REPORT_SCRIPT="$REPORT" PATH="$T/bin:$SAFEPATH" bash "$WRAP" 2>"$T/err"; echo "rc=$?"; }
reset; touch "$FLAG"; : > "$STUB_LOG"; out=$(wrap); has "bandeira ligada: manda o relatório" "GC:mail send mayor" "$(cat "$STUB_LOG")"; has "bandeira ligada: rc 0" "rc=0" "$out"
reset; : > "$STUB_LOG"; L "$now" 0 5 ',"host":"hetzner"' > "$LOG"; out=$(wrap); has "bandeira desligada mas o nó trabalhou nas últimas 24 h: manda o último relatório" "GC:mail send mayor" "$(cat "$STUB_LOG")"
reset; : > "$STUB_LOG"; L "$now" 0 5 ',"host":"mbp"' > "$LOG"; out=$(wrap); hasnt "desligado e ocioso: NÃO manda" "GC:mail" "$(cat "$STUB_LOG")"; has "desligado e ocioso: diz por quê e sai 0" "nothing to report" "$out"; has "…rc 0" "rc=0" "$out"
reset; : > "$STUB_LOG"; out=$(wrap); has "desligado e sem log nenhum: manda (não sei se o nó trabalhou)" "GC:mail send mayor" "$(cat "$STUB_LOG")"
reset; : > "$STUB_LOG"; L "$now" 0 5 ',"host":"mbp"' > "$LOG"; chmod 000 "$LOG"; out=$(wrap); has "desligado e log ilegível: manda (o inerte é avisar)" "GC:mail send mayor" "$(cat "$STUB_LOG")"; chmod 644 "$LOG"
reset; out=$(GC_CITY_PATH="$C" HETZNER_REPORT_SCRIPT="$T/nao-existe.sh" PATH="$T/bin:$SAFEPATH" bash "$WRAP" 2>&1; echo "rc=$?"); has "relatório ausente é FALHA (rc 1), não sucesso calado" "rc=1" "$out"; has "…e diz qual" "report script not found" "$out"
# linha que o relatório AVISA como ilegível pode ter sido uma bateria do nó: o wrapper não pode decidir "ocioso" por cima do aviso do próprio relatório
reset; : > "$STUB_LOG"; { L "$now" 0 5 ',"host":"mbp"'; printf '{"ts":"%s","repo":"wa","slot":"1","rc":0,"secs":3,"host":"hetzner"}\n' "$now"; printf '{"ts":"%s","repo":"wa","mode":"pyt' "$now"; echo; } > "$LOG"
rep=$(run --no-cost); out=$(wrap)
has "(o relatório diz 'hetzner=0' e avisa 2 linhas ilegíveis)" "⚠️ 2 linha(s) ilegível(is)" "$rep"; has "desligado, nó 'sem execuções' mas com linha ilegível: manda (o inerte é avisar)" "GC:mail send mayor" "$(cat "$STUB_LOG")"; hasnt "…e não diz 'nothing to report'" "nothing to report" "$out"
reset; : > "$STUB_LOG"; { L "$now" 0 5 ',"host":"mbp"'; printf '{"ts":"%s","repo":"wa","mode":"pyt' "$now"; echo; } > "$LOG"; out=$(wrap)
has "desligado, só uma linha truncada (sem ts) e o resto ocioso: manda" "GC:mail send mayor" "$(cat "$STUB_LOG")"
reset; : > "$STUB_LOG"; { L "$now" 0 5 ',"host":"mbp"'; L "$now" 0 7 ',"host":"mbp"'; } > "$LOG"; out=$(wrap)
hasnt "controle: log inteiro legível e ocioso continua calado" "GC:mail" "$(cat "$STUB_LOG")"; has "…com rc 0" "rc=0" "$out"

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
