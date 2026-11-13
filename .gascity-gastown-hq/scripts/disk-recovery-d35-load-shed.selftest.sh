#!/usr/bin/env bash
# disk-recovery-d35-load-shed.selftest.sh — testa o degrau D3.5 (corte de carga) da escada de disco (ga-1p1i5jr.8) SEM tocar na máquina.
#
# ## Contents
#   Simulado · Seções · Como rodar
#
# SIMULADO  launchctl (estado em arquivos: carregado com pid, desabilitado; cada chamada anotada; falha/estouro por modo, por verbo e por label), df, relógio (D35_NOW) e a pasta da cidade. Nada real é parado.
# SEÇÕES    uso · limiar · o corte (ordem, N, nunca fora da allowlist) · ritmo · deny-list · allowlist do repo · falhas e terceiro estado · trava · retomada (30 min >= 6 GB, pid novo, só o que EU parei)
# COMO RODAR  bash scripts/disk-recovery-d35-load-shed.selftest.sh   ·   outro executável: D35_ST_SUT=<arquivo>   ·   D35_ST_BASH=<bash 3.2> roda o degrau num bash de outra versão   ·   D35_ST_FAILFAST=1 sai no 1º FAIL (mutantes)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${D35_ST_SUT:-$HERE/disk-recovery-d35-load-shed.sh}"
SHIPPED="$HERE/disk-recovery-d35-allowlist.tsv"
[ -f "$SUT" ] || { echo "FATAL: degrau não encontrado em $SUT"; exit 1; }
for _v in $(compgen -e | grep '^D35_'); do case "$_v" in D35_ST_SUT|D35_ST_FAILFAST|D35_ST_BASH) ;; *) unset "$_v" ;; esac; done
W="$(mktemp -d "${TMPDIR:-/tmp}/d35-selftest.XXXXXX")" || { echo "FATAL: mktemp"; exit 1; }
case "$W" in */d35-selftest.??????) ;; *) echo "FATAL: diretório de trabalho estranho: $W"; exit 1 ;; esac
trap 'chmod -R u+rwx "$W" 2>/dev/null; rm -rf "$W"' EXIT
mkdir -p "$W/bin"
PASS=0; FAIL=0; OUT=""; RC=0; NOW=1000000
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
nope() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; [ -n "$OUT" ] && printf '%s\n' "$OUT" | sed 's/^/        | /' | tail -n 8; [ "${D35_ST_FAILFAST:-0}" = 1 ] && { echo "(FAILFAST) $PASS ok, $FAIL FAIL"; exit 1; }; return 0; }
eq()    { if [ "$1" = "$2" ]; then ok "$3"; else nope "$3 (obtido '$1', esperado '$2')"; fi; }
has()   { case "$1" in *"$2"*) ok "$3" ;; *) nope "$3 (faltou: $2)" ;; esac; }
hasnt() { case "$1" in *"$2"*) nope "$3 (não devia ter: $2)" ;; *) ok "$3" ;; esac; }
section() { printf '\n== %s\n' "$1"; }

# launchctl de mentira. $LC/loaded/<label> = pid (arquivo vazio = job agendado, sem pid); $LC/disabled/<label>; $LC/mode/<verbo>.fail|.hang|.fail.<label>; bootout soma $LC/step ao livre
cat > "$W/bin/launchctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$LC/calls"
v=$1; shift; t=${1:-}; l=${t##*/}
[ "$v" = bootstrap ] && l=$(basename "$2" .plist)
[ -e "$LC/mode/$v.hang" ] && sleep 30
{ [ -e "$LC/mode/$v.fail" ] || [ -e "$LC/mode/$v.fail.$l" ]; } && { echo "launchctl: boom" >&2; exit 1; }
case "$v" in
  print) [ -e "$LC/printfail.$l" ] && { echo "launchd mudo" >&2; exit 1; }
         [ -f "$LC/loaded/$l" ] || { echo "Could not find service" >&2; exit 113; }
         printf '%s = {\n\tstate = running\n\tpid = %s\n}\n' "$t" "$(cat "$LC/loaded/$l")" ;;
  print-disabled) [ -e "$LC/mode/pd.garbage" ] && { echo "lixo"; exit 0; }
         echo "disabled services = {"; printf '\t"com.apple.outro" => enabled\n'
         for f in "$LC"/disabled/*; do [ -e "$f" ] && printf '\t"%s" => disabled\n' "${f##*/}"; done; echo "}" ;;
  disable) touch "$LC/disabled/$l" ;;
  enable) rm -f "$LC/disabled/$l" ;;
  bootout) [ -e "$LC/mode/bootout.noop" ] && exit 0; [ -e "$LC/mode/bootout.slow" ] && { ( sleep 1; rm -f "$LC/loaded/$l" ) >/dev/null 2>&1 & exit 0; }
         rm -f "$LC/loaded/$l"; echo $(( $(cat "$FREE_FILE") + $(cat "$LC/step") )) > "$FREE_FILE"; [ -e "$LC/mode/bootout.rmfree" ] && rm -f "$FREE_FILE"; [ -e "$LC/mode/print.after" ] && touch "$LC/printfail.$l" ;;
  bootstrap) [ -e "$LC/disabled/$l" ] && { echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; }
         [ -e "$LC/mode/bootstrap.nopid" ] && { : > "$LC/loaded/$l"; exit 0; }
         c=$(cat "$LC/counter"); echo $((c + 1)) > "$LC/counter"; echo "$c" > "$LC/loaded/$l" ;;
esac
STUB
cat > "$W/bin/df" <<'STUB'
#!/bin/bash
case "${STUB_DF_MODE:-ok}" in
  ok)      printf 'Filesystem 1048576-blocks Used Available Capacity Mounted on\n/dev/disk3s5 228000 200000 2222 98%% /System/Volumes/Data\n' ;;
  root)    printf 'Filesystem 1048576-blocks Used Available Capacity Mounted on\n/dev/disk3s1s1 228000 16000 190000 8%% /\n' ;;
  garbage) printf 'Filesystem 1048576-blocks Used Available Capacity Mounted on\n/dev/disk3s5 228000 200000 abc 98%% /System/Volumes/Data\n' ;;
  fail)    echo "df: boom" >&2; exit 1 ;;
  empty)   : ;;
esac
STUB
printf '#!/bin/bash\n[ "${STUB_DATE_FAIL:-}" = 1 ] && exit 1\nexec /bin/date "$@"\n' > "$W/bin/date"
chmod 755 "$W/bin/launchctl" "$W/bin/df" "$W/bin/date"

N=0; LABELS="a b c d e"
mk() {  # [labels]: UM mundo novo por caso (pasta nova), labels carregados (pid 1000+i, plist presente), livre 2500; allowlist vazia (allow acrescenta)
  N=$((N+1)); C="$W/c$N"; LC="$C/lc"; ST="$C/city/.gc/disk-recovery-d35.state"; HI="$C/city/.gc/disk-recovery-d35.high"
  mkdir -p "$LC/loaded" "$LC/disabled" "$LC/mode" "$C/plists" "$C/city/.gc" "$C/home"
  echo 5000 > "$LC/counter"; echo 0 > "$LC/step"; : > "$LC/calls"; echo 2500 > "$C/free"; ALLOW="$C/allow.tsv"; : > "$ALLOW"
  local i=0 l; for l in "$@"; do echo $((1000+i)) > "$LC/loaded/$l"; : > "$C/plists/$l.plist"; i=$((i+1)); done
}
allow() { local r; for r in "$@"; do printf '%s\n' "$r" | tr '|' '\t' >> "$ALLOW"; done; }   # label|porta|nome|risco
std() { mk com.t.a com.t.b com.t.c com.t.d com.t.e com.t.sender com.t.unlisted; allow 'com.t.a|9001|Alfa|baixo' 'com.t.b|9002|Beta|baixo' 'com.t.c|9003|Gama|-' 'com.t.d|9004|Delta|-' 'com.t.e|9005|Epsilon|medio'; }
r() {  # modo [VAR=valor ...] → OUT RC (stdout+stderr juntos: o contrato é UMA linha)
  local m=${1:-}; [ $# -eq 0 ] || shift
  OUT=$(env -i PATH="$W/bin:/usr/bin:/bin" HOME="$C/home" TMPDIR="$W" LC="$LC" FREE_FILE="$C/free" D35_CITY="$C/city" D35_ALLOWLIST="$ALLOW" D35_PLIST_DIR="$C/plists" \
    D35_LAUNCHCTL_BIN="$W/bin/launchctl" D35_FREE_MB_FILE="$C/free" D35_NOW="$NOW" D35_UID=501 D35_SETTLE_S=0 D35_STOP_WAIT_S=1 D35_WATCH_S=1 D35_LC_TIMEOUT_S=3 "$@" ${D35_ST_BASH:-bash} "$SUT" "$m" 2>&1 </dev/null); RC=$?
}
mut()  { local n; n=$(grep -c -E '^(disable|enable|bootout|bootstrap) ' "$LC/calls"); echo "${n:-0}"; }   # chamadas que MUDAM o launchd
muts() { grep -E '^(disable|enable|bootout|bootstrap) ' "$LC/calls" | tr '\n' ';'; }
lastev() { awk -F'\t' -v l="$1" '$3 == l { e = $2 } END { print e }' "$ST" 2>/dev/null; }

section "uso, interruptor, dry-run, limiar"
std; r --bogus; eq "$RC" 2 "modo inválido sai 2"; r; eq "$RC" 2 "sem modo sai 2"
touch "$C/city/.gc/disk-recovery.off"; r --run; eq "$RC" 10 "interruptor ligado: sai 10"; eq "$(mut)" 0 "interruptor ligado: nada tocado"
std; r --dry-run; eq "$RC" 0 "dry-run com candidatos sai 0"; has "$OUT" "pararia 3" "dry-run diz o que faria (3 por rodada)"; eq "$(mut)" 0 "dry-run não muda o launchd"
[ -e "$ST" ] && nope "dry-run não grava registro" || ok "dry-run não grava registro"
std; echo 3072 > "$C/free"; r --run; eq "$RC" 10 "livre = 3072 (limite): não corta"; eq "$(mut)" 0 "livre >= limite: nada tocado"
echo 3071 > "$C/free"; r --run; eq "$RC" 0 "livre = 3071: corta"

section "o corte: ordem do arquivo, N por rodada, nunca fora da allowlist, aviso com a lista"
std; r --run; eq "$RC" 0 "corte sai 0"; has "$OUT" "parei 3" "parou 3 (padrão)"; has "$OUT" "Alfa [com.t.a]" "a lista traz o nome e o label"; has "$OUT" "Gama [com.t.c]" "a lista traz o 3º"
eq "$(muts)" "disable gui/501/com.t.a;bootout gui/501/com.t.a;disable gui/501/com.t.b;bootout gui/501/com.t.b;disable gui/501/com.t.c;bootout gui/501/com.t.c;" "disable ANTES do bootout, na ordem do arquivo, só os 3 primeiros"
eq "$(grep -c -E 'sender|unlisted|com.t.d|com.t.e' "$LC/calls")" 0 "label fora da allowlist (e os que não chegaram) nunca é nem consultado"
eq "$(lastev com.t.a)" STOPPED "registro: STOPPED"; eq "$(grep -c STOPPING "$ST")" 3 "registro: STOPPING gravado antes de cada um"
eq "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" 1 "stdout é UMA linha"
std; echo 600 > "$LC/step"; r --run; has "$OUT" "parei 1" "livre voltou a >= 3072 depois do 1º: para"; has "$OUT" "2500 -> 3100" "a linha diz livre antes -> depois"; eq "$(mut)" 2 "só o 1º foi tocado"
std; r --run D35_MAX_PER_RUN=1; has "$OUT" "parei 1" "D35_MAX_PER_RUN manda no N"
std; r --run D35_BUDGET_S=0; has "$OUT" "parei 1" "orçamento de tempo esgotado: faz ao menos 1 e para"

section "ritmo: espera o efeito do corte; depois o próximo lote; depois lista esgotada (rc 11)"
std; r --run; NOW=1000599 r --run; eq "$RC" 12 "599 s depois do corte: espera (12, o código que diz 'ainda corto')"; has "$OUT" "esperando o efeito" "a linha diz que espera"; eq "$(mut)" 6 "esperar não toca em nada"
NOW=1000600 r --run; eq "$RC" 0 "600 s depois: corta o próximo lote"; has "$OUT" "parei 2" "os 2 que faltavam"; has "$OUT" "Epsilon [com.t.e]" "o último da lista"
NOW=1001300 r --run; eq "$RC" 11 "nada mais a parar com o disco baixo: lista esgotada (11)"; has "$OUT" "lista esgotada" "a linha diz esgotada"; eq "$(mut)" 10 "esgotada não toca em nada"
std; r --run; NOW=999000 r --run; eq "$RC" 0 "carimbo do corte no FUTURO (relógio voltou) não cala o degrau"

section "quem NÃO é meu: já desabilitado, não carregado, sem plist, ilegível no launchd"
std; touch "$LC/disabled/com.t.a"; rm -f "$LC/loaded/com.t.b" "$C/plists/com.t.c.plist"; r --run
has "$OUT" "parei 2" "pulou os 3 e parou d, e"; has "$OUT" "Delta [com.t.d]" "d parado"; eq "$(muts | grep -c 'com.t.[abc]')" 0 "desabilitado/não carregado/sem plist: nem disable nem bootout"
eq "$(lastev com.t.a)" "" "o já desligado por decisão alheia nunca entra no registro"
std; touch "$LC/mode/print.fail.com.t.a"; r --run; has "$OUT" "parei 3" "label cujo print falha é pulado, não vira 'parado' nem trava o resto"; eq "$(lastev com.t.a)" "" "print ilegível: nada gravado"
std; touch "$LC/mode/print.fail"; r --run; eq "$RC" 30 "print falhando em TODOS: não li (30), nunca 'lista esgotada'"; eq "$(mut)" 0 "e nada é tocado"
mk com.t.a; allow 'com.t.a|9001|Alfa|baixo'; touch "$LC/mode/print.hang"; r --run D35_LC_TIMEOUT_S=1; eq "$RC" 30 "print que pendura: estoura o prazo e é 'não li' (30), não 'carregado'"; eq "$(mut)" 0 "e nada é tocado"
std; touch "$LC/mode/bootout.rmfree"; r --run; has "$OUT" "parei 1:" "re-medição do disco ilegível depois de agir: a ação conta"; has "$OUT" "re-medição do disco falhou" "e a linha diz"; eq "$(mut)" 2 "mas não corta mais às cegas"
std; touch "$LC/mode/print.after"; r --run D35_BUDGET_S=0; eq "$RC" 20 "bootout aplicado mas o print seguinte falha: 20, sem afirmar nada"; has "$OUT" "INCONSISTENTE" "a linha diz INCONSISTENTE"
eq "$(lastev com.t.a)" STOPPING "registro: continua STOPPING (pendente), não STOP_FAILED"; hasnt "$(muts)" "enable" "e NÃO desfaz às cegas (nenhum enable)"
rm -f "$LC/printfail.com.t.a"; : > "$LC/calls"; echo 7000 > "$C/free"; for t in 1001000 1001300 1001600 1001900 1002200 1002500 1002800; do NOW=$t r --resume; done
eq "$RC" 0 "a retomada religa o que ficou pendente (já descarregado: enable + bootstrap)"; eq "$(muts)" "enable gui/501/com.t.a;bootstrap gui/501 $C/plists/com.t.a.plist;" "enable ANTES do bootstrap"
std; touch "$LC/mode/bootout.slow"; r --run D35_STOP_WAIT_S=5 D35_MAX_PER_RUN=1; has "$OUT" "parei 1:" "bootout que demora a descarregar: espera a prova (D35_STOP_WAIT_S)"
std; r --run D35_NOW= D35_DATE_BIN="$W/bin/date" STUB_DATE_FAIL=1; eq "$RC" 30 "relógio ilegível: 30"; eq "$(mut)" 0 "e nada é tocado"

section "deny-list: porta e fragmento do label VENCEM a allowlist (cada fragmento e cada porta, 1 a 1)"
mk com.t.ok; allow 'com.t.ok|9001|Ok|baixo'
for f in sender inbound discador dialer voicebot phoneproxy tunnel classification demand-dashboard map-viewer frota admin-dashboard daemon-dashboard dolt supervisor gascity gastown; do
  : > "$C/plists/com.t.x-$f.plist"; echo 77 > "$LC/loaded/com.t.x-$f"; allow "com.t.x-$f|9100|Negado $f|baixo"; done
for p in 8086 8095 8099 8203 8090 8097 5599 5600 8088; do : > "$C/plists/com.t.p$p.plist"; echo 77 > "$LC/loaded/com.t.p$p"; allow "com.t.p$p|$p|Porta $p|baixo"; done
: > "$C/plists/com.t.x-UPPER-Sender.plist"; echo 77 > "$LC/loaded/com.t.x-UPPER-Sender"; allow "com.t.x-UPPER-Sender|9100|Maiúscula|baixo"
r --run D35_MAX_PER_RUN=99; eq "$RC" 0 "corte com 27 linhas negadas no meio sai 0"; has "$OUT" "parei 1: Ok [com.t.ok]" "só o Ok foi parado"; eq "$(grep -c -E 'x-|com.t.p' "$LC/calls")" 0 "nenhuma linha negada (17 fragmentos, 9 portas) foi consultada ou tocada"; has "$OUT" "27 negada" "a linha diz quantas descartou (a deny-list não distingue maiúsculas)"
mk com.t.ok com.t.cinco com.t.curta com.t.nota "com.t.bad label"; allow 'com.t.ok|9001|Ok|baixo' 'com.t.cinco|9004|X|baixo|extra' 'com.t.curta|9003' 'com.t.nota|99x|X|baixo' 'com.t.bad label|9002|X|baixo'
r --run D35_MAX_PER_RUN=99; has "$OUT" "parei 1:" "linha malformada (label com espaço, porta não numérica, colunas a mais ou a menos) é descartada, o resto segue"; has "$OUT" "4 negada" "e a linha diz quantas"

section "a allowlist que vai no repo"
rows=$(awk -F'\t' '!/^#/ && NF > 0' "$SHIPPED" | wc -l | tr -d ' ')
eq "$(awk -F'\t' '!/^#/ && NF > 0 && NF != 4' "$SHIPPED" | wc -l | tr -d ' ')" 0 "toda linha tem 4 colunas"; eq "$(awk -F'\t' '!/^#/ && NF > 0 { print $1 }' "$SHIPPED" | sort | uniq -d | wc -l | tr -d ' ')" 0 "sem label repetido"
eq "$(awk -F'\t' '!/^#/ && NF > 0 { r = ($4 == "baixo") ? 1 : ($4 == "-") ? 2 : ($4 == "medio") ? 3 : 9; if (r < m || r == 9) bad++; m = r } END { print bad + 0 }' "$SHIPPED")" 0 "ordem de risco: baixo, depois -, depois medio (e nenhum risco desconhecido)"
mk $(awk -F'\t' '!/^#/ && NF > 0 { print $1 }' "$SHIPPED"); ALLOW="$SHIPPED"; r --dry-run D35_MAX_PER_RUN=999; has "$OUT" "pararia $rows:" "o descarte da deny-list não pega nenhuma das $rows linhas do repo"; hasnt "$OUT" "negada" "nenhuma linha do repo é negada"
TABLE=""; for t in "${GC_CITY_PATH:-/nao}" "$HERE/.." /Users/athos/gt/.gascity-gastown-hq; do [ -f "$t/.gc/agents/mayor/proc-review/action-table.tsv" ] && { TABLE="$t/.gc/agents/mayor/proc-review/action-table.tsv"; break; }; done
if [ -n "$TABLE" ]; then
  bad=$(awk -F'\t' 'NR == FNR { if (FNR == 1) for (i = 1; i <= NF; i++) { if ($i == "label") lc = i; if ($i == "emergency_off") ec = i } else if (lc && ec) off[$lc] = $ec; next }
    !/^#/ && NF > 0 && off[$1] != "sim" { print $1 }' "$TABLE" "$SHIPPED" | tr '\n' ' ')
  eq "$bad" "" "deriva: todo label da allowlist é emergency_off=sim na action-table do Mayor"
else echo "SKIP - deriva da action-table: a tabela do Mayor não existe nesta máquina"; fi

section "falhas do launchctl: desfaz ou diz INCONSISTENTE; uma linha ruim não trava as outras"
std; touch "$LC/mode/disable.fail.com.t.a"; r --run; eq "$RC" 20 "disable que falha: sai 20"; has "$OUT" "parei 3" "mas não trava: parou b, c, d"; has "$OUT" "FALHOU 1" "a linha diz a falha"; eq "$(lastev com.t.a)" STOP_FAILED "registro: STOP_FAILED"
rm -f "$LC/mode/disable.fail.com.t.a"; : > "$LC/calls"; NOW=1000700 r --run; NOW=1003599 r --run; hasnt "$(muts)" "com.t.a" "a que falhou fica de fora por 1 h (3599 s ainda não)"; NOW=1003600 r --run; has "$(muts)" "disable gui/501/com.t.a" "passada 1 h (3600 s), tenta de novo"
std; printf '9999999\tSTOP_FAILED\tcom.t.a\t1000\t2500\tx\n' > "$ST"; r --run; has "$(muts)" "disable gui/501/com.t.a" "carimbo de falha no FUTURO (relógio voltou) não segura o label"
std; touch "$LC/mode/bootout.noop"; r --run D35_BUDGET_S=0; eq "$RC" 20 "bootout que não tirou do launchd: sai 20"; has "$(muts)" "enable gui/501/com.t.a" "desfaz o disable (enable)"; eq "$(lastev com.t.a)" STOP_FAILED "registro: STOP_FAILED, não STOPPED"
[ -e "$LC/disabled/com.t.a" ] && nope "depois do desfazer o label não fica desabilitado" || ok "depois do desfazer o label não fica desabilitado"
std; touch "$LC/mode/bootout.noop" "$LC/mode/enable.fail"; r --run D35_BUDGET_S=0; eq "$RC" 20 "bootout E desfazer falham: sai 20"; has "$OUT" "INCONSISTENTE" "a linha diz INCONSISTENTE"; eq "$(lastev com.t.a)" STOPPING "registro: fica pendente (STOPPING) para o --resume"
std; touch "$LC/mode/disable.fail"; r --run; eq "$RC" 20 "disable falhando em tudo: 20, nenhum bootout"; hasnt "$(muts)" "bootout" "sem disable provado não há bootout"
std; touch "$LC/mode/pd.garbage"; r --run; eq "$RC" 30 "print-disabled com lixo: não li (30)"; eq "$(mut)" 0 "e nada é tocado"
std; touch "$LC/mode/print-disabled.fail"; r --run; eq "$RC" 30 "print-disabled falhando: 30"; eq "$(mut)" 0 "e nada é tocado"
std; touch "$LC/mode/print-disabled.hang"; r --run D35_LC_TIMEOUT_S=1; eq "$RC" 30 "launchctl que pendura: estoura o prazo e é 30"; eq "$(mut)" 0 "e nada é tocado"

section "terceiro estado: disco, allowlist e registro ilegíveis NUNCA viram 'tem bastante' nem 'esgotada'"
for m in garbage empty; do std; if [ $m = garbage ]; then echo abc > "$C/free"; else : > "$C/free"; fi; r --run; eq "$RC" 30 "livre $m: 30"; eq "$(mut)" 0 "livre $m: nada tocado"; done
std; rm -f "$C/free"; r --run; eq "$RC" 30 "arquivo do livre ausente: 30"
std; for m in fail garbage empty root; do r --run D35_FREE_MB_FILE= D35_DF_BIN="$W/bin/df" STUB_DF_MODE=$m; eq "$RC" 30 "df $m: 30"; done
r --run D35_FREE_MB_FILE= D35_DF_BIN="$W/bin/df"; eq "$RC" 0 "df do volume Data lido: corta"; has "$OUT" "livre 2222" "a linha traz o que o df leu"
std; : > "$ALLOW"; r --run; eq "$RC" 30 "allowlist vazia: 30"; r --run D35_ALLOWLIST="$C/nao-existe.tsv"; eq "$RC" 30 "allowlist ausente: 30"; mkdir "$C/dir.tsv"; r --run D35_ALLOWLIST="$C/dir.tsv"; eq "$RC" 30 "allowlist que é pasta: 30"
std; mkdir -p "$ST"; r --run; eq "$RC" 30 "registro que é pasta: 30"; eq "$(mut)" 0 "e nada é tocado"
std; : > "$C/arquivo"; r --run D35_STATE="$C/arquivo/state"; eq "$RC" 20 "registro que não grava: 20"; eq "$(mut)" 0 "sem gravar o registro ANTES, não para"
std; r --run; printf 'lixo sem tabs\n1000\tSTOPPED\n' >> "$ST"; NOW=1000700 r --run; eq "$RC" 0 "linha de registro ruim/cortada é ruído: o resto segue"

section "trava de instância única: dono conferido pela LINHA DE COMANDO, não só pelo pid"
printf '#!/bin/bash\nsleep 30\n' > "$W/disk-recovery-d35-holder.sh"; chmod 755 "$W/disk-recovery-d35-holder.sh"
std; "$W/disk-recovery-d35-holder.sh" & HP=$!; mkdir -p "$C/city/.gc/disk-recovery-d35.lock.d"; echo "$HP" > "$C/city/.gc/disk-recovery-d35.lock.d/pid"; r --run; eq "$RC" 10 "dono vivo e é um D3.5: outra instância (10)"; eq "$(mut)" 0 "e nada é tocado"
sleep 30 & SP=$!; echo "$SP" > "$C/city/.gc/disk-recovery-d35.lock.d/pid"; r --run; eq "$RC" 0 "pid vivo que NÃO é D3.5 (reaproveitado): trava velha, segue"; kill "$HP" "$SP" 2>/dev/null
sleep 30 & SP=$!; std; mkdir -p "$C/city/.gc/disk-recovery-d35.lock.d"; echo "$SP" > "$C/city/.gc/disk-recovery-d35.lock.d/pid"; r --run D35_PS_BIN=/bin/false; eq "$RC" 30 "dono vivo e o ps falha: não sei (30), não 'ninguém'"; kill "$SP" 2>/dev/null
std; mkdir -p "$C/city/.gc/disk-recovery-d35.lock.d"; echo 2147480 > "$C/city/.gc/disk-recovery-d35.lock.d/pid"; r --run; eq "$RC" 0 "dono morto: trava velha, segue"
std; mkdir -p "$C/city/.gc/disk-recovery-d35.lock.d"; r --run; eq "$RC" 30 "trava sem dono legível: não sei (30), não 'outra instância'"; eq "$(mut)" 0 "e nada é tocado"
std; r --run; if [ -d "$C/city/.gc/disk-recovery-d35.lock.d" ]; then nope "a trava é solta no fim"; else ok "a trava é solta no fim"; fi

section "retomada: só com >= 6 GB por 30 min, só o que EU parei, mais recente primeiro, pid novo PROVADO"
wk() { local t; for ((t = $1; t <= $2; t += $3)); do NOW=$t r --resume; done; }   # uma rodada do maestro a cada $3 s (a lacuna que zera o relógio é > 600 s)
std; r --run D35_MAX_PER_RUN=2; echo 7000 > "$C/free"
r --resume D35_STATE="$C/nada"; eq "$RC" 10 "sem registro: nada a retomar (10)"
echo 5000 > "$C/free"; NOW=1000900 r --resume; eq "$RC" 10 "livre < 6144: não retoma"; has "$OUT" "não retomo" "a linha diz"
echo 6144 > "$C/free"; wk 1001000 1002500 300; eq "$RC" 10 "6144 por 1500 s: ainda espera"; has "$OUT" "espero" "a linha diz que espera"
NOW=1002799 r --resume; eq "$RC" 10 "1799 s: espera"; eq "$(mut)" 4 "esperar não toca no launchd"
NOW=1002800 r --resume; eq "$RC" 0 "1800 s: retoma"; has "$OUT" "religou [com.t.b]" "o mais recente primeiro (b antes de a)"; has "$OUT" "pid 1001 -> 5000" "prova de pid novo na linha"
eq "$(muts | sed 's/.*bootout gui\/501\/com.t.b;//')" "enable gui/501/com.t.b;bootstrap gui/501 $C/plists/com.t.b.plist;" "enable ANTES do bootstrap (label desabilitado não sobe)"
eq "$(lastev com.t.b)" RESUMED "registro: RESUMED"; NOW=1002900 r --resume; has "$OUT" "religou [com.t.a]" "na chamada seguinte, o a"; NOW=1003000 r --resume; eq "$RC" 10 "tudo religado: nada a retomar"; has "$OUT" "nada a retomar" "a linha diz"
std; r --run D35_MAX_PER_RUN=1; echo 7000 > "$C/free"; echo "9999999 9999999" > "$HI"; NOW=1002800 r --resume; eq "$(cat "$HI")" "1002800 1002800" "relógio da retomada com carimbo no FUTURO recomeça agora"
std; r --run D35_MAX_PER_RUN=1; echo 7000 > "$C/free"; echo lixo > "$HI"; NOW=1002800 r --resume; eq "$(cat "$HI")" "1002800 1002800" "relógio da retomada ilegível recomeça agora"
std; r --run D35_MAX_PER_RUN=1; echo 7000 > "$C/free"; NOW=1001000 r --resume; NOW=1002800 r --resume; eq "$RC" 10 "lacuna > 600 s entre duas leituras zera o relógio: 1800 s de calendário não bastam"
std; r --run D35_MAX_PER_RUN=1; echo 7000 > "$C/free"; wk 1000300 1000900 300; echo 5000 > "$C/free"; NOW=1001200 r --resume; echo 7000 > "$C/free"
wk 1001500 1003000 300; NOW=1003299 r --resume; eq "$RC" 10 "queda abaixo de 6144 zera a contagem (não conta os 900 s de antes)"; NOW=1003300 r --resume; eq "$RC" 0 "1800 s depois da volta: retoma"
std; touch "$LC/disabled/com.t.a"; r --run D35_MAX_PER_RUN=1; echo 7000 > "$C/free"; for t in 1001000 1001300 1001600 1001900 1002200 1002500 1002800; do NOW=$t r --resume; done
eq "$(grep -c 'com.t.a' "$LC/calls" | tr -d ' ')" 0 "o que o Athos já deixou desligado: nunca consultado, parado nem religado"
std; r --run D35_MAX_PER_RUN=1; echo 7000 > "$C/free"; rm -f "$LC/disabled/com.t.a"; echo 4242 > "$LC/loaded/com.t.a"; : > "$LC/calls"; for t in 1001000 1001300 1001600 1001900 1002200 1002500 1002800; do NOW=$t r --resume; done
eq "$(muts)" "" "já religado por outro: nenhum enable/bootstrap"; eq "$(lastev com.t.a)" ABANDONED "registro: ABANDONED"

section "retomada: a prova é o pid NOVO; falha fica pendente e repete; terceiro estado"
rs() { echo 7000 > "$C/free"; for t in 1001000 1001300 1001600 1001900 1002200 1002500 1002800; do NOW=$t r --resume "$@"; done; }
std; r --run D35_MAX_PER_RUN=1; touch "$LC/mode/bootstrap.fail"; rs; eq "$RC" 20 "bootstrap que falha: 20"; has "$OUT" "FALHOU" "a linha diz"; eq "$(lastev com.t.a)" RESUME_FAILED "registro: RESUME_FAILED (continua pendente)"
rm -f "$LC/mode/bootstrap.fail"; NOW=1003100 r --resume; eq "$RC" 0 "consertado o launchd, a próxima chamada religa"
std; r --run D35_MAX_PER_RUN=1; touch "$LC/mode/bootstrap.nopid"; rs; eq "$RC" 20 "carregou mas sem pid novo (tinha pid): 20"; has "$OUT" "sem pid novo" "a linha diz"
std; echo "" > "$LC/loaded/com.t.a"; r --run D35_MAX_PER_RUN=1; touch "$LC/mode/bootstrap.nopid"; rs; eq "$RC" 0 "job agendado (sem pid ao parar): a prova é estar carregado"
std; r --run D35_MAX_PER_RUN=1; rm -f "$C/plists/com.t.a.plist"; rs; eq "$RC" 20 "plist sumiu: 20, sem enable às cegas"; eq "$(mut)" 2 "nenhuma chamada que muda o launchd depois do corte"
std; touch "$LC/mode/bootout.noop" "$LC/mode/enable.fail"; r --run D35_BUDGET_S=0; rm -f "$LC/mode/enable.fail"; : > "$LC/calls"; rs
eq "$RC" 0 "corte pela metade (carregado e desabilitado): a retomada só RE-HABILITA"; has "$OUT" "re-habilitado" "a linha diz"; eq "$(muts)" "enable gui/501/com.t.a;" "só o enable (nada de bootstrap em quem já está carregado)"
eq "$(lastev com.t.a)" RESUMED "registro: RESUMED"; [ -e "$LC/disabled/com.t.a" ] && nope "o disable foi desfeito" || ok "o disable foi desfeito"
std; touch "$LC/mode/bootout.noop" "$LC/mode/enable.fail"; r --run D35_BUDGET_S=0; rs; eq "$RC" 20 "corte pela metade e o enable falha: 20, continua pendente"; eq "$(lastev com.t.a)" RESUME_FAILED "registro: RESUME_FAILED"
std; r --run D35_MAX_PER_RUN=1; touch "$LC/mode/print-disabled.fail"; rs; eq "$RC" 30 "print-disabled ilegível na retomada: 30"
std; r --run D35_MAX_PER_RUN=1; rs D35_FREE_MB_FILE="$C/nao-existe"; eq "$RC" 30 "livre ilegível: não retoma (30)"
std; r --run D35_MAX_PER_RUN=1; touch "$LC/mode/print.fail"; rs; eq "$RC" 30 "estado do label ilegível no launchd: não retoma (30)"
std; r --run D35_MAX_PER_RUN=1; mkdir -p "$C/city/.gc/hi"; rs D35_HIGH="$C/city/.gc/hi"; eq "$RC" 30 "relógio da retomada que não grava: 30 (não retoma sem contar)"
std; r --run D35_MAX_PER_RUN=1; rm -f "$ST"; mkdir "$ST"; rs; eq "$RC" 30 "registro ilegível na retomada: 30"

section "integração com o maestro REAL (o aceite da bead): D4 no teto + disco < 3 GB -> corta N da allowlist e avisa a lista; humano só depois de esgotar; disco volta -> religa com pid novo"
LAD="$HERE/disk-recovery-ladder.sh"; [ -f "$LAD" ] || { echo "FATAL: maestro não encontrado em $LAD"; exit 1; }
mkdir -p "$W/ms"; printf '#!/bin/bash\nexit 10\n' > "$W/ms/idle"; printf '#!/bin/bash\n[ "${1:-}" = --resume ] && exit 10\necho "D4 (stub): reiniciou"\nexit 0\n' > "$W/ms/d4"; printf '#!/bin/bash\nexit 0\n' > "$W/ms/gc"
printf '#!/bin/bash\necho "$*" >> "$MS_LOG"\nexit 0\n' > "$W/ms/notify"; chmod 755 "$W/ms/"*
std; MSL="$C/notify.log"; : > "$MSL"; echo 0 > "$C/swap"
lt() {  # uma rodada do maestro (launchd) na hora $1, com o D3.5 de verdade; o D4 é um stub que "reinicia" (rc 0)
  echo "$1" > "$C/now"
  env -i PATH="$W/bin:/usr/bin:/bin" HOME="$C/home" TMPDIR="$W" MS_LOG="$MSL" LC="$LC" FREE_FILE="$C/free" DR_CITY="$C/city" DR_STATE="$C/city/.gc/disk-recovery.state" DR_LOG="$C/city/.gc/logs/disk-recovery.log" \
    DR_FREE_MB_FILE="$C/free" DR_SWAP_MB_FILE="$C/swap" DR_NOW_FILE="$C/now" DR_D2_CMD="$W/ms/idle" DR_D3_CMD="$W/ms/idle" DR_D4_CMD="$W/ms/d4" DR_D35_CMD="$SUT" DR_NOTIFY_BIN="$W/ms/notify" DR_GC_BIN="$W/ms/gc" DR_SETTLE_S=0 \
    D35_CITY="$C/city" D35_ALLOWLIST="$ALLOW" D35_PLIST_DIR="$C/plists" D35_LAUNCHCTL_BIN="$W/bin/launchctl" D35_FREE_MB_FILE="$C/free" D35_NOW="$1" D35_UID=501 D35_SETTLE_S=0 D35_STOP_WAIT_S=1 D35_WATCH_S=1 D35_LC_TIMEOUT_S=3 \
    ${D35_ST_BASH:-bash} "$LAD" --run > "$C/maestro.out" 2>&1; RC=$?
}
for ((t = NOW; t <= NOW + 2400; t += 300)); do lt "$t"; done
eq "$(mut)" 0 "antes de 2700 s com o disco < 3 GB o D3.5 não corta nada"
lt $((NOW + 2700)); has "$(cat "$MSL")" "Disco: D3.5 cortou carga" "2700 s: o maestro chama o D3.5 e avisa"; has "$(cat "$MSL")" "Alfa [com.t.a], Beta [com.t.b], Gama [com.t.c]" "o aviso traz a LISTA do que parou"
eq "$(muts)" "disable gui/501/com.t.a;bootout gui/501/com.t.a;disable gui/501/com.t.b;bootout gui/501/com.t.b;disable gui/501/com.t.c;bootout gui/501/com.t.c;" "pararam só os 3 primeiros da allowlist, disable antes do bootout"
for ((t = NOW + 3000; t <= NOW + 6300; t += 300)); do lt "$t"; done
eq "$(grep -c 'degrau D4: rc=0' "$C/city/.gc/logs/disk-recovery.log"),$(grep -c -E 'sender|unlisted' "$LC/calls")" "1,0" "o D4 reiniciou UMA vez (rc 0; o teto de 6 h o segura); nada fora da allowlist foi consultado"
eq "$(ls "$LC/loaded" | grep -c 'com.t.[abcde]$')" 0 "esgotada a lista, os 5 estão parados"
has "$(cat "$MSL")" "preciso de um humano" "lista esgotada com o disco < 3 GB e o D4 no teto: o 'precisa de um humano' SAI"
eq "$(awk '/Disco: D3.5 cortou carga/ { c = NR } /preciso de um humano/ { if (!h) h = NR } END { print (c && h && h > c) ? "depois" : "antes:" c "/" h }' "$MSL")" "depois" "…e só DEPOIS do último corte"
echo 7000 > "$C/free"; for ((t = NOW + 6600; t <= NOW + 9600; t += 300)); do lt "$t"; done
eq "$(grep -c 'D3.5 religou um serviço' "$MSL")" 5 "disco >= 6 GB por 30 min: os 5 religados, um por rodada"
has "$(grep 'D3.5 religou um serviço' "$MSL" | head -n 1)" "[com.t.e]" "o último parado volta primeiro"; has "$(grep 'D3.5 religou um serviço' "$MSL" | head -n 1)" "pid 1004 -> 5000" "e a prova é o pid NOVO"
eq "$(ls "$LC/disabled" | wc -l | tr -d ' '),$(ls "$LC/loaded" | grep -c 'com.t.[abcde]$')" "0,5" "nada fica desabilitado e os 5 voltam a estar carregados"

echo; echo "RESULT: $PASS ok, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
