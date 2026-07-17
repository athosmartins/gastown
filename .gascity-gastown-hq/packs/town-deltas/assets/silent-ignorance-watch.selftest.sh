#!/usr/bin/env bash
# silent-ignorance-watch.selftest.sh — prova o MONITOR da Ignorância Silenciosa.
#
# POR QUE ESTE ARQUIVO EXISTE (ga-vkjs, attempt 1/3):
#   o revisor do gate (run ga-wisp-3ip2my) achou, LENDO, um bug que um teste teria
#   pego: o baseline era regravado carimbando $now em TODO achado, então um NOVO em
#   qualquer rig zerava o first-seen dos outros ~290 → nenhum completava ESCALATE_DAYS
#   → a re-escalação NUNCA disparava. Ou seja: o monitor reintroduzia o wa-k288h
#   ("avisa 1x e cala pra sempre") na própria linha que declarava preveni-lo.
#   O scanner tinha selftest; o monitor não. Este arquivo fecha essa assimetria.
#
# REGRA QUE ESTE ARQUIVO ENCARNA (regra (b) do thies, ga-p5q3): todo check cuja
#   VACUIDADE é load-bearing precisa ser FALSIFICADO. Por isso cada teste de "grita"
#   vem com um CONTROLE que prova que ele NÃO grita quando não deve — senão "sempre
#   grita" passaria por "detecta".
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="$HERE/silent-ignorance-watch.sh"
PASS=0; FAIL=0
ok()  { echo "  ok $*";   PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }

TD=$(mktemp -d); trap 'rm -rf "$TD"' EXIT
NOW=$(date +%s); D10=$(( NOW - 10*86400 )); D3=$(( NOW - 3*86400 ))

# scanner falso: 2 achados que já estão no baseline + 1 novo
mk_scan() { cat > "$TD/scan.sh" <<EOF
#!/bin/bash
$(for f in "$@"; do echo "echo \"$f\""; done)
EOF
chmod +x "$TD/scan.sh"; }

# roda o watch isolado; ecoa rc
run() { local rc; env SILENT_IGN_SCAN="$TD/scan.sh" SILENT_IGN_ROOTS=/tmp \
  SILENT_IGN_BASELINE="$TD/base.tsv" SILENT_IGN_NOTIFY="${MOCK_NOTIFY:-/usr/bin/true}" \
  timeout 90 bash "$WATCH" "$@" >"$TD/out.txt" 2>&1; rc=$?; echo "$rc"; }
epoch_of() { grep -F "$1" "$TD/base.tsv" 2>/dev/null | cut -f4; }

echo "── 1. o relógio é POR ACHADO: um NOVO alheio NÃO pode zerar o first-seen dos outros ──"
printf 'velho.sh\tC2\tcod_velho\t%s\nmedio.sh\tC2\tcod_medio\t%s\n' "$D10" "$D3" > "$TD/base.tsv"
mk_scan "velho.sh:1:C2:cod_velho" "medio.sh:2:C2:cod_medio" "novo.sh:9:C2:cod_novo"
run --notify >/dev/null
[ "$(epoch_of cod_medio)" = "$D3" ] \
  && ok "achado que segue aberto PRESERVA o first-seen (o bug do ga-wisp-3ip2my)" \
  || bad "first-seen do cod_medio foi RESETADO: era $D3, virou $(epoch_of cod_medio) — wa-k288h de volta"
[ "$(epoch_of cod_novo)" -ge "$NOW" ] 2>/dev/null \
  && ok "achado NOVO nasce com o epoch de agora" \
  || bad "cod_novo não recebeu epoch de agora: $(epoch_of cod_novo)"
[ "$(epoch_of cod_velho)" -ge "$NOW" ] 2>/dev/null \
  && ok "re-escalado reinicia o relógio (re-escala a cada ESCALATE_DAYS, não toda rodada)" \
  || bad "cod_velho não reiniciou: $(epoch_of cod_velho)"

echo "── 2. o relógio ANDA: rodadas repetidas não impedem o achado de amadurecer ──"
before=$(epoch_of cod_medio); run --notify >/dev/null; run --notify >/dev/null
[ "$(epoch_of cod_medio)" = "$before" ] \
  && ok "2 rodadas extras não mexeram no first-seen — ele vai atingir ESCALATE_DAYS" \
  || bad "first-seen andou entre rodadas: $before -> $(epoch_of cod_medio)"

echo "── 3. re-escalação DISPARA no >= ESCALATE_DAYS (e o controle: não dispara antes) ──"
printf 'velho.sh\tC2\tcod_velho\t%s\n' "$D10" > "$TD/base.tsv"
mk_scan "velho.sh:1:C2:cod_velho"
run >/dev/null; grep -q "1 re-escalado" "$TD/out.txt" \
  && ok "achado de 10d (>=7) é re-escalado" || bad "10d NÃO re-escalou: $(cat "$TD/out.txt" | head -1)"
printf 'medio.sh\tC2\tcod_medio\t%s\n' "$D3" > "$TD/base.tsv"
mk_scan "medio.sh:2:C2:cod_medio"
run >/dev/null; grep -q "0 re-escalado" "$TD/out.txt" \
  && ok "CONTROLE: achado de 3d (<7) NÃO re-escala — a régua não grita sempre" \
  || bad "3d re-escalou indevidamente: $(head -1 "$TD/out.txt")"

echo "── 4. 'não consegui olhar' NUNCA vira 'não achei' (exit 3) — com controle ──"
printf 'x.sh\tC2\tc\t%s\n' "$NOW" > "$TD/base.tsv"
mk_scan "x.sh:1:C2:c"
rc=$(env SILENT_IGN_SCAN=/tmp/inexistente_$$.sh SILENT_IGN_ROOTS=/tmp \
     SILENT_IGN_BASELINE="$TD/base.tsv" timeout 60 bash "$WATCH" >/dev/null 2>&1; echo $?)
[ "$rc" = "3" ] && ok "scanner quebrado -> exit 3 (não 'zero achados')" || bad "scanner quebrado deu rc=$rc, esperado 3"
rc=$(env SILENT_IGN_SCAN="$TD/scan.sh" SILENT_IGN_ROOTS=/tmp \
     SILENT_IGN_BASELINE=/tmp/baseline_inexistente_$$.tsv timeout 60 bash "$WATCH" >/dev/null 2>&1; echo $?)
[ "$rc" = "3" ] && ok "baseline ilegível -> exit 3 (não 'nada novo')" || bad "baseline ausente deu rc=$rc, esperado 3"
rc=$(run)
[ "$rc" = "0" ] && ok "CONTROLE: varredura sadia -> exit 0 (o exit 3 não dispara sempre)" \
                || bad "varredura sadia deu rc=$rc, esperado 0"

echo "── 5. entrega falha => baseline INTACTO (lição wa-4fmxd: aviso perdido não pode ser consumido) ──"
printf 'velho.sh\tC2\tcod_velho\t%s\n' "$D10" > "$TD/base.tsv"
mk_scan "velho.sh:1:C2:cod_velho" "novo.sh:9:C2:cod_novo"
antes=$(cat "$TD/base.tsv")
MOCK_NOTIFY=/usr/bin/false run --notify >/dev/null
[ "$(cat "$TD/base.tsv")" = "$antes" ] \
  && ok "notify falhou -> baseline intacto (a próxima rodada re-tenta o alerta)" \
  || bad "notify falhou mas o baseline foi gravado — o alerta foi CONSUMIDO por uma entrega que não houve"

echo "── 6. dry-run não toca no baseline (senão o smoke-test manual silencia a rodada agendada) ──"
antes=$(cat "$TD/base.tsv")
run >/dev/null
[ "$(cat "$TD/base.tsv")" = "$antes" ] \
  && ok "dry-run (sem --notify) deixou o baseline intacto" \
  || bad "dry-run mexeu no baseline — silenciaria o alerta real (wa-8fzuk/wa-4fmxd)"

echo "── 7. rc=1 do scanner (o ERRO INTERNO documentado dele) tem que GRITAR ──"
# O revisor do gate pegou: meus testes de exit-3 cobriam rc=127 (binário ausente) e
# baseline ilegível — NUNCA o rc=1, que é o único erro que o scanner REALMENTE emite
# ("0 on a completed scan; 1 only on an internal error"). O `-gt 1` deixava passar e o
# erro virava "0 achados". O controle (rc=0) prova que não estou só gritando sempre.
cat > "$TD/scan_rc1.sh" <<'EOS'
#!/bin/bash
exit 1
EOS
cat > "$TD/scan_rc0.sh" <<'EOS'
#!/bin/bash
exit 0
EOS
chmod +x "$TD/scan_rc1.sh" "$TD/scan_rc0.sh"
printf 'x.sh\tC2\tc\t%s\n' "$NOW" > "$TD/base.tsv"
rc=$(env SILENT_IGN_SCAN="$TD/scan_rc1.sh" SILENT_IGN_ROOTS=/tmp \
     SILENT_IGN_BASELINE="$TD/base.tsv" timeout 60 bash "$WATCH" >/dev/null 2>&1; echo $?)
[ "$rc" = "3" ] && ok "scanner rc=1 (erro interno) -> exit 3, não 'zero achados'" \
                || bad "scanner rc=1 deu rc=$rc, esperado 3 — o erro virou silêncio"
rc=$(env SILENT_IGN_SCAN="$TD/scan_rc0.sh" SILENT_IGN_ROOTS=/tmp \
     SILENT_IGN_BASELINE="$TD/base.tsv" timeout 60 bash "$WATCH" >/dev/null 2>&1; echo $?)
[ "$rc" = "0" ] && ok "CONTROLE: scanner rc=0 sem achados -> exit 0 (0 e 1 são distinguidos)" \
                || bad "scanner rc=0 deu rc=$rc, esperado 0"

echo "── 8. HQ inexistente (GC_CITY_PATH errado) grita em vez de varrer o vazio ──"
rc=$(env GC_CITY_PATH=/hq/que/nao/existe SILENT_IGN_SCAN="$TD/scan_rc0.sh" \
     SILENT_IGN_BASELINE="$TD/base.tsv" timeout 60 bash "$WATCH" >/dev/null 2>&1; echo $?)
[ "$rc" = "3" ] && ok "HQ não-diretório -> exit 3 (a raiz principal não entra sem -d)" \
                || bad "HQ inexistente deu rc=$rc, esperado 3"

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && { echo "  RESULT: PASS"; exit 0; } || { echo "  RESULT: FAIL"; exit 1; }
