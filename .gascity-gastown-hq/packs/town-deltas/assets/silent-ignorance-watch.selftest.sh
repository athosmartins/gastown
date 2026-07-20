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
#
# SEÇÃO 9 (ga-8yxwm): prova a fingerprint do scanner — muda o hash do instrumento
#   e o watcher tem que re-seedar em silêncio em vez de alertar "N novos" falsos
#   (o incidente real: 21:35, 11770 "novos" bogus por o scanner ter mudado de
#   escopo entre o baseline e o run).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="$HERE/silent-ignorance-watch.sh"
PASS=0; FAIL=0
ok()  { echo "  ok $*";   PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }

TD=$(mktemp -d); trap 'rm -rf "$TD"' EXIT
NOW=$(date +%s); D10=$(( NOW - 10*86400 )); D3=$(( NOW - 3*86400 ))

# scanner falso: 2 achados que já estão no baseline + 1 novo
# Stampa a fingerprint (mesmo comando que o watch usa) JUNTO — todas as seções 1-8
# testam o relógio/re-escalação/erro-vs-vazio, não o mecanismo de fingerprint do
# ga-8yxwm; sem isto, CADA mk_scan (conteúdo novo -> hash novo) pareceria "o scanner
# mudou" pro watch e disparava a re-seed silenciosa nova, mascarando o que essas
# seções realmente querem provar. A seção 9 testa o fingerprint e cuida da sua
# própria fingerprint explicitamente (não usa este auto-stamp).
mk_scan() { cat > "$TD/scan.sh" <<EOF
#!/bin/bash
$(for f in "$@"; do echo "echo \"$f\""; done)
EOF
chmod +x "$TD/scan.sh"
shasum -a 256 "$TD/scan.sh" | awk '{print $1}' > "$TD/base.tsv.scanner-fp"; }

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
# ga-8yxwm (achado do gate, run ga-wisp-qgyum7): sem isto, base.tsv.scanner-fp ainda
# carrega o hash do scan.sh da seção 5 (mk_scan não roda aqui — scan_rc0.sh é outro
# arquivo). O CONTROLE abaixo bateria no ramo NOVO "instrumento mudou" (linha ~200 do
# watch, ga-8yxwm) em vez do ramo "0 achados" que ele existe pra provar — os dois dão
# exit 0, então `[ "$rc" = "0" ]` passava por acidente: false green, o controle não
# testava mais o que seu próprio texto afirma ("0 e 1 são distinguidos"). Mesmo padrão
# do mk_scan(): carimba a fingerprint do instrumento ATUAL antes de usá-lo.
shasum -a 256 "$TD/scan_rc0.sh" | awk '{print $1}' > "$TD/base.tsv.scanner-fp"
rc=$(env SILENT_IGN_SCAN="$TD/scan_rc0.sh" SILENT_IGN_ROOTS=/tmp \
     SILENT_IGN_BASELINE="$TD/base.tsv" timeout 60 bash "$WATCH" >/dev/null 2>&1; echo $?)
[ "$rc" = "0" ] && ok "CONTROLE: scanner rc=0 sem achados -> exit 0 (0 e 1 são distinguidos)" \
                || bad "scanner rc=0 deu rc=$rc, esperado 0"

echo "── 8. HQ inexistente (GC_CITY_PATH errado) grita em vez de varrer o vazio ──"
rc=$(env GC_CITY_PATH=/hq/que/nao/existe SILENT_IGN_SCAN="$TD/scan_rc0.sh" \
     SILENT_IGN_BASELINE="$TD/base.tsv" timeout 60 bash "$WATCH" >/dev/null 2>&1; echo $?)
[ "$rc" = "3" ] && ok "HQ não-diretório -> exit 3 (a raiz principal não entra sem -d)" \
                || bad "HQ inexistente deu rc=$rc, esperado 3"

echo "── 9. fingerprint do SCANNER muda -> re-seeda em silêncio, NÃO alerta 'N novos' falsos (ga-8yxwm) ──"
# cenário real do bug: o scanner mudou de versão (ga-vkjs/ga-ypl5l) entre duas
# rodadas agendadas. Baseline do scanner velho vs scan do scanner novo diverge em
# quase tudo -> 100% artefato de FERRAMENTA, zero dívida nova de verdade.
#
# Mock dedicado: ao contrário de mk_scan (achados embutidos NO PRÓPRIO scanner),
# aqui "o instrumento" (scan9.sh, versionado por write_scan9_version) e "o que ele
# acha ao rodar" (scan9-data.txt, via mk_scan9) são arquivos SEPARADOS — como no
# sistema real, onde error-empty-conflation-scan.sh não muda de hash só porque o
# código-alvo que ele varre ganhou uma linha nova. É o que permite testar "mesmo
# instrumento, achado novo" (9a/9d) sem também mexer na fingerprint.
mk_scan9() { printf '%s\n' "$@" > "$TD/scan9-data.txt"; }
write_scan9_version() { cat > "$TD/scan9.sh" <<EOS
#!/bin/bash
# versão: $1
cat "$TD/scan9-data.txt"
EOS
chmod +x "$TD/scan9.sh"; }
rm -f "$TD/notify_called"
cat > "$TD/mock_notify.sh" <<EOS
#!/bin/bash
echo called >> "$TD/notify_called"
exit 0
EOS
chmod +x "$TD/mock_notify.sh"
run9() { env SILENT_IGN_SCAN="$TD/scan9.sh" SILENT_IGN_ROOTS=/tmp SILENT_IGN_BASELINE="$TD/base.tsv" \
  SILENT_IGN_NOTIFY="$TD/mock_notify.sh" timeout 90 bash "$WATCH" "$@" >"$TD/out.txt" 2>&1; echo $?; }

printf 'a.sh\tC2\tcod_a\t%s\nb.sh\tC2\tcod_b\t%s\n' "$D10" "$D3" > "$TD/base.tsv"
write_scan9_version A
shasum -a 256 "$TD/scan9.sh" | awk '{print $1}' > "$TD/base.tsv.scanner-fp"

# 9a CONTROLE: MESMO scanner (versão A, fingerprint já combina), achado novo real
# -> ALERTA de verdade. Prova que o mecanismo novo não deixa o watcher mudo em
# geral — só quando o instrumento realmente muda.
mk_scan9 "a.sh:1:C2:cod_a" "b.sh:2:C2:cod_b" "c.sh:3:C2:cod_c_real"
rc=$(run9 --notify)
[ "$rc" = "0" ] && [ -f "$TD/notify_called" ] \
  && ok "CONTROLE: fingerprint IGUAL + achado novo real -> alerta dispara (mecanismo não fica mudo à toa)" \
  || bad "CONTROLE falhou: rc=$rc notify_called=$([ -f "$TD/notify_called" ] && echo sim || echo não) — $(head -1 "$TD/out.txt")"

# 9b: scanner MUDA pra versão B (hash diferente). Achados novos TODOS diferentes
# dos do baseline — o "11770 novos" bogus do incidente real. Tem que re-seedar em
# silêncio, NUNCA alertar.
rm -f "$TD/notify_called"
old_fp=$(cat "$TD/base.tsv.scanner-fp")
mk_scan9 "x.sh:1:C2:cod_x" "y.sh:2:C2:cod_y" "z.sh:3:C2:cod_z"
write_scan9_version B
new_fp=$(shasum -a 256 "$TD/scan9.sh" | awk '{print $1}')
[ "$old_fp" != "$new_fp" ] \
  && ok "setup 9b são: versão B do scanner tem hash diferente da A (o teste prova algo)" \
  || bad "setup do teste 9b quebrado: hash do scanner não mudou — o teste não provaria nada"
rc=$(run9 --notify)
[ "$rc" = "0" ] \
  && ok "scanner mudou -> exit 0 (não é erro, é re-seed silenciosa)" \
  || bad "scanner mudou deu rc=$rc, esperado 0"
[ ! -f "$TD/notify_called" ] \
  && ok "scanner mudou -> notify NUNCA chamado (o falso alarme de 'N novos' não dispara)" \
  || bad "scanner mudou disparou notify — é o falso-alarme exato do ga-8yxwm (11770 'novos' bogus)"
grep -qi "re-baseline" "$TD/out.txt" \
  && ok "log explica a re-seed por mudança de scanner (auditável, não silêncio total)" \
  || bad "nenhuma linha de log menciona a re-seed: $(cat "$TD/out.txt")"
[ "$(epoch_of cod_x)" -ge "$NOW" ] 2>/dev/null \
  && ok "achado do scanner novo entra no baseline (absorvido como dívida existente)" \
  || bad "cod_x não foi absorvido no baseline após a re-seed: $(epoch_of cod_x)"
[ "$(cat "$TD/base.tsv.scanner-fp")" = "$new_fp" ] \
  && ok "fingerprint do baseline avançou pro novo instrumento" \
  || bad "fingerprint não foi atualizada após a re-seed"

# 9c CONTROLE: dry-run (sem --notify) com scanner mudado (versão C) NÃO pode mutar
# nada — mesma regra que já vale pro resto do arquivo (wa-4fmxd/wa-8fzuk): um
# smoke-test manual não pode consumir a re-seed que a rodada agendada real faria.
rm -f "$TD/notify_called"
mk_scan9 "p.sh:1:C2:cod_p" "q.sh:2:C2:cod_q"
write_scan9_version C
antes_base=$(cat "$TD/base.tsv"); antes_fp=$(cat "$TD/base.tsv.scanner-fp")
rc=$(run9)
[ "$rc" = "0" ] && [ ! -f "$TD/notify_called" ] \
  && ok "dry-run com scanner mudado -> exit 0, sem alertar" \
  || bad "dry-run com scanner mudado: rc=$rc notify=$([ -f "$TD/notify_called" ] && echo sim || echo não)"
[ "$(cat "$TD/base.tsv")" = "$antes_base" ] && [ "$(cat "$TD/base.tsv.scanner-fp")" = "$antes_fp" ] \
  && ok "dry-run com scanner mudado NÃO tocou baseline nem fingerprint (a rodada --notify real ainda vai re-seedar)" \
  || bad "dry-run mutou estado durável — smoke-test manual consumiria a re-seed real (wa-4fmxd/wa-8fzuk de novo)"

# 9d: volta pra versão B (a mesma já estampada em base.tsv.scanner-fp — a versão C
# do 9c nunca foi persistida) + 1 achado genuinamente novo -> volta a alertar
# normalmente. Prova que a re-seed absorve UMA diferença de instrumento e não
# deixa o mecanismo mudo pra sempre.
rm -f "$TD/notify_called"
mk_scan9 "x.sh:1:C2:cod_x" "y.sh:2:C2:cod_y" "z.sh:3:C2:cod_z" "novo_de_verdade.sh:4:C2:cod_novo_de_verdade"
write_scan9_version B
rc=$(run9 --notify)
[ -f "$TD/notify_called" ] \
  && ok "instrumento estável de novo + achado real -> volta a alertar (não fica mudo depois da re-seed)" \
  || bad "após estabilizar, achado novo de verdade NÃO alertou — mecanismo ficou mudo permanentemente: $(cat "$TD/out.txt")"

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && { echo "  RESULT: PASS"; exit 0; } || { echo "  RESULT: FAIL"; exit 1; }
