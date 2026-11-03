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

echo "── 10. os ramos que as seções acima não pisam (ga-eedg7fw, hq-mutants): argumento, raízes pelo rig list, stderr do scanner, fingerprint, --seed, no-news, notify ──"
# O `run` acima sempre fixa SILENT_IGN_ROOTS=/tmp, então a descoberta das raízes (HQ + `gc rig list`) nunca rodava. Aqui o `gc` é de mentira (PATH) e o scanner grava
# com que --path foi chamado. EQUIVALENTE, sem caso (hq-mutants L121): `printf … | grep -E ':(C1|C2|C3):' >> "$tmp_raw" || true` com `||`→`&&` — o script roda com
# `set -uo pipefail`, SEM -e, e o rc dessa linha não é lido em lugar nenhum.
# EQUIVALENT ed339600c1: `printf ... | grep -E ... >> "$tmp_raw" || true` com `||` -> `&&`: o script roda com `set -uo pipefail`, SEM -e, e o rc dessa linha nao e lido em lugar nenhum
mkdir -p "$TD/stubs" "$TD/stubs-nosha" "$TD/hq" "$TD/rigA"
cat > "$TD/stubs/gc" <<'GCEOF'
#!/bin/sh
# gc rig list --json de mentira: com $GC_STUB_MODE_FILE = ok devolve $GC_STUB_RIGS; qualquer outro modo = não respondeu (sem saída, rc 0)
[ "$(cat "$GC_STUB_MODE_FILE" 2>/dev/null)" = ok ] && cat "$GC_STUB_RIGS"
exit 0
GCEOF
printf '#!/bin/sh\nexit 1\n' > "$TD/stubs-nosha/shasum"
printf '#!/bin/sh\n: > "$N10_MARK"\nexit 0\n' > "$TD/notify_mark.sh"
chmod +x "$TD/stubs/gc" "$TD/stubs-nosha/shasum" "$TD/notify_mark.sh"
runx() { local rc; env SILENT_IGN_SCAN="$TD/scan.sh" SILENT_IGN_BASELINE="$TD/base.tsv" SILENT_IGN_NOTIFY="${MOCK_NOTIFY:-/usr/bin/true}" \
  GC_CITY_PATH="${HQDIR:-$TD/hq}" GC_STUB_MODE_FILE="$TD/gc.mode" GC_STUB_RIGS="$TD/rigs.json" SCAN_CALLS="$TD/scan.calls" N10_MARK="$TD/n10_called" \
  PATH="${EXTRA_PATH:+$EXTRA_PATH:}$TD/stubs:$PATH" timeout 90 bash "$WATCH" "$@" >"$TD/out.txt" 2>&1; rc=$?; echo "$rc"; }
# scanner que só registra os argumentos e não acha nada; a fingerprint dele já fica estampada (como o mk_scan)
mk_scan_rec() { printf '#!/bin/bash\necho "$*" >> "${SCAN_CALLS:-/dev/null}"\nexit 0\n' > "$TD/scan.sh"; chmod +x "$TD/scan.sh"
  shasum -a 256 "$TD/scan.sh" | awk '{print $1}' > "$TD/base.tsv.scanner-fp"; }
run_in_n10() { env N10_MARK="$TD/n10_called" SILENT_IGN_SCAN="$TD/scan.sh" SILENT_IGN_ROOTS=/tmp SILENT_IGN_BASELINE="$TD/base.tsv" SILENT_IGN_NOTIFY="$1" timeout 90 bash "$WATCH" "${@:2}" >"$TD/out.txt" 2>&1; echo $?; }

# 10a. argumento desconhecido
printf 'x.sh\tC2\tc\t%s\n' "$NOW" > "$TD/base.tsv"; mk_scan "x.sh:1:C2:c"
rc=$(run --bogus)
[ "$rc" = "2" ] && grep -q 'unknown arg: --bogus' "$TD/out.txt" \
  && ok "argumento desconhecido -> exit 2 e diz qual" || bad "--bogus: rc=$rc ($(head -1 "$TD/out.txt"))"

if ! command -v jq >/dev/null 2>&1; then
  echo "  skip 10b-10d (sem jq nesta máquina: o watch lê o rig list com jq, o teste seria vacuamente verde)"
else
# 10b. a raiz principal (HQ) tem de existir
echo ok > "$TD/gc.mode"; printf '{"rigs":[]}' > "$TD/rigs.json"; mk_scan_rec; : > "$TD/scan.calls"
rc=$(HQDIR="$TD/nao-existe-hq" runx)
[ "$rc" = "3" ] && grep -q 'não é um diretório' "$TD/out.txt" && [ ! -s "$TD/scan.calls" ] \
  && ok "HQ que não é diretório -> exit 3, diz por quê, e o scanner nem roda" || bad "HQ inexistente: rc=$rc scan.calls=$(wc -l < "$TD/scan.calls" | tr -d ' ') ($(head -1 "$TD/out.txt"))"
rc=$(runx)
[ "$rc" = "0" ] && [ "$(cat "$TD/scan.calls")" = "--path $TD/hq --quiet" ] \
  && ok "CONTROLE: HQ existente + nenhum rig -> exit 0 e varre só o HQ" || bad "HQ ok: rc=$rc scan.calls='$(cat "$TD/scan.calls")'"

# 10c. o rig list que não responde NÃO é 'zero rigs'
echo empty > "$TD/gc.mode"; : > "$TD/scan.calls"
rc=$(runx)
[ "$rc" = "3" ] && grep -q "'gc rig list' não respondeu" "$TD/out.txt" && [ ! -s "$TD/scan.calls" ] \
  && ok "gc rig list sem resposta -> exit 3 (não 'zero rigs'), e nada é varrido" || bad "rig list vazio: rc=$rc ($(head -1 "$TD/out.txt"))"

# 10d. as raízes: HQ primeiro, rig que existe entra, rig que não existe em disco é AVISADO e fica de fora, o HQ repetido no rig list não duplica
echo ok > "$TD/gc.mode"; : > "$TD/scan.calls"
printf '{"rigs":[{"path":"%s"},{"path":"%s"},{"path":"%s"}]}' "$TD/rigA" "$TD/nao-existe-rig" "$TD/hq" > "$TD/rigs.json"
rc=$(runx)
[ "$rc" = "0" ] && [ "$(cat "$TD/scan.calls")" = "--path $TD/hq --quiet
--path $TD/rigA --quiet" ] \
  && ok "varre HQ e o rig que existe, nessa ordem, cada um UMA vez" || bad "raízes varridas: rc=$rc scan.calls='$(tr '\n' '|' < "$TD/scan.calls")'"
grep -q "aviso: rig '$TD/nao-existe-rig' está no rig list mas NÃO existe em disco" "$TD/out.txt" \
  && ok "rig do rig list que não existe em disco: AVISA (varredura incompleta) e não o varre" || bad "sem o aviso do rig inexistente: $(cat "$TD/out.txt")"
fi

# 10e. o stderr do scanner que falhou vai para o operador (a causa não morre em /dev/null); sem stderr, nenhuma linha 'scanner:'
printf '#!/bin/bash\necho "boom: reason" >&2\nexit 1\n' > "$TD/scan.sh"
rc=$(run)
[ "$rc" = "3" ] && grep -q "scanner falhou em '/tmp' (rc=1)" "$TD/out.txt" && grep -q '^    scanner: boom: reason$' "$TD/out.txt" \
  && ok "scanner falhou com stderr -> exit 3 e a causa aparece ('    scanner: boom: reason')" || bad "stderr do scanner: rc=$rc ($(cat "$TD/out.txt"))"
printf '#!/bin/bash\nexit 1\n' > "$TD/scan.sh"
rc=$(run)
[ "$rc" = "3" ] && grep -q "scanner falhou em '/tmp' (rc=1)" "$TD/out.txt" && ! grep -q '^    scanner:' "$TD/out.txt" \
  && ok "CONTROLE: scanner falhou SEM stderr -> exit 3 e nenhuma linha 'scanner:' inventada" || bad "scanner mudo: rc=$rc ($(cat "$TD/out.txt"))"

# 10f. não consegui calcular a fingerprint do instrumento: exit 3, nunca 'é o mesmo'
printf 'x.sh\tC2\tc\t%s\n' "$NOW" > "$TD/base.tsv"; mk_scan "x.sh:1:C2:c"
rc=$(env SILENT_IGN_SCAN="$TD/scan.sh" SILENT_IGN_ROOTS=/tmp SILENT_IGN_BASELINE="$TD/base.tsv" PATH="$TD/stubs-nosha:$PATH" timeout 90 bash "$WATCH" >"$TD/out.txt" 2>&1; echo $?)
[ "$rc" = "3" ] && grep -q 'não consegui calcular a fingerprint do scanner' "$TD/out.txt" \
  && ok "shasum sem resposta -> exit 3 (não afirma que o baseline é comparável)" || bad "fingerprint falhou: rc=$rc ($(cat "$TD/out.txt"))"

# 10g. --seed: semeia, estampa a fingerprint, não alerta, exit 0
rm -f "$TD/base.tsv" "$TD/base.tsv.scanner-fp"; mk_scan "a.sh:1:C2:ca" "b.sh:2:C2:cb"; rm -f "$TD/base.tsv.scanner-fp"
rc=$(run --seed)
[ "$rc" = "0" ] && grep -q 'baseline semeado com 2 achado(s)' "$TD/out.txt" && [ "$(wc -l < "$TD/base.tsv" | tr -d ' ')" = "2" ] \
  && [ "$(cat "$TD/base.tsv.scanner-fp")" = "$(shasum -a 256 "$TD/scan.sh" | awk '{print $1}')" ] \
  && ok "--seed: exit 0, baseline com os 2 achados e a fingerprint do scanner estampada" || bad "--seed: rc=$rc baseline=$(wc -l < "$TD/base.tsv" 2>/dev/null) ($(head -1 "$TD/out.txt"))"

# 10h. dry-run com achado NOVO: exit 0, lista o novo, diz que o baseline ficou INTACTO e não o toca
printf 'x.sh\tC2\tc\t%s\n' "$NOW" > "$TD/base.tsv"; mk_scan "x.sh:1:C2:c" "novo.sh:2:C2:cn"; before=$(cat "$TD/base.tsv")
rc=$(run)
[ "$rc" = "0" ] && grep -q '1 NOVO(s)' "$TD/out.txt" && grep -q 'dry-run: baseline INTACTO' "$TD/out.txt" && [ "$(cat "$TD/base.tsv")" = "$before" ] \
  && ok "dry-run com 1 NOVO: exit 0, avisa que o baseline está INTACTO e não o muda" || bad "dry-run com novo: rc=$rc ($(cat "$TD/out.txt"))"

# 10i. NADA novo e nada re-escalado: exit 0 logo depois do resumo — sem a mensagem de dry-run e, com --notify, SEM chamar o notify
printf 'x.sh\tC2\tc\t%s\n' "$NOW" > "$TD/base.tsv"; mk_scan "x.sh:1:C2:c"
rc=$(run)
[ "$rc" = "0" ] && grep -q '0 NOVO(s) | 0 re-escalado(s)' "$TD/out.txt" && ! grep -q 'dry-run' "$TD/out.txt" \
  && ok "sem novidade: exit 0 só com o resumo (a mensagem de dry-run é de quando HÁ novidade)" || bad "sem novidade: rc=$rc ($(cat "$TD/out.txt"))"
rm -f "$TD/n10_called"
rc=$(run_in_n10 "$TD/notify_mark.sh" --notify)
[ "$rc" = "0" ] && [ ! -f "$TD/n10_called" ] \
  && ok "sem novidade + --notify: exit 0 e o notify NÃO é chamado (não alerta à toa)" || bad "sem novidade + --notify: rc=$rc notify=$([ -f "$TD/n10_called" ] && echo chamado || echo não)"

# 10j/k. o alerta que não foi ENTREGUE não consome o achado: notify ausente ou que falha -> exit 3 e o baseline fica como estava (a próxima rodada re-tenta)
printf 'x.sh\tC2\tc\t%s\n' "$NOW" > "$TD/base.tsv"; mk_scan "x.sh:1:C2:c" "novo.sh:2:C2:cn"; before=$(cat "$TD/base.tsv")
rc=$(run_in_n10 /nao/existe/notify --notify)
[ "$rc" = "3" ] && grep -q 'notify não encontrado' "$TD/out.txt" && [ "$(cat "$TD/base.tsv")" = "$before" ] \
  && ok "notify ausente -> exit 3, diz que o baseline ficou INTACTO e não o muda" || bad "notify ausente: rc=$rc ($(cat "$TD/out.txt"))"
rc=$(run_in_n10 /usr/bin/false --notify)
[ "$rc" = "3" ] && grep -q 'notify falhou' "$TD/out.txt" && [ "$(cat "$TD/base.tsv")" = "$before" ] \
  && ok "notify que falha -> exit 3 e o baseline fica INTACTO (a próxima rodada re-tenta)" || bad "notify que falha: rc=$rc ($(cat "$TD/out.txt"))"
rc=$(run_in_n10 /usr/bin/true --notify)
[ "$rc" = "0" ] && grep -q 'alertado e baseline atualizado' "$TD/out.txt" && grep -q 'cn' "$TD/base.tsv" \
  && ok "CONTROLE: notify que entrega -> exit 0 e o NOVO entra no baseline (o exit 3 acima é condicional)" || bad "notify ok: rc=$rc ($(cat "$TD/out.txt"))"

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && { echo "  RESULT: PASS"; exit 0; } || { echo "  RESULT: FAIL"; exit 1; }
