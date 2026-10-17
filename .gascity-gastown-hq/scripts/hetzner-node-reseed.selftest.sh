#!/usr/bin/env bash
# hetzner-node-reseed.selftest.sh — hermético: mbp-run.sh e notify são stubs; a cidade é temporária. (ga-zri39b)
#
# Contents
#   Casos · Controle negativo
#
# CASOS: bandeira do nó ausente = OFF, calado e sem rodar nada · bandeira ligada roda `mbp-run.sh --host linux --seed wa` com a cidade certa, mesmo com a chave do MBP DESLIGADA
#   (o nó é independente) · rc 0 = OK sem notify · rc 98/97/124 = FALHOU com UM notify prio 4 que diz o rc e o que ele quer dizer · saída com "ALARME: dado ou segredo no destino"
#   = ALARME com notify prio 5 · mbp-run.sh ausente é falha (rc 1, FALHOU com linha no jsonl e notify prio 4), não sucesso calado · notify ausente é AVISADO, o veredito não muda · estouro de prazo (se há `timeout`).
# CONTROLE NEGATIVO: o mutante sem o reconhecimento do ALARME vira FALHOU (prio 4) e o caso do alarme o pega.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$HERE/../packs/town-deltas/assets/scripts/hetzner-node-reseed-order.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/hnr-selftest.XXXXXX")
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
mkdir -p "$T/city/.gc/logs" "$T/bin"
C="$T/city"; FLAG="$C/.gc/hetzner-node.on"; LOG="$C/.gc/logs/hetzner-node-reseed.jsonl"; STUB_LOG="$T/stub.log"
fails=0; n=0
ok()  { n=$((n+1)); echo "ok   $1"; }
bad() { n=$((n+1)); echo "FAIL $1"; fails=$((fails+1)); }
eq()  { [ "$2" = "$3" ] && ok "$1 ($3)" || bad "$1: esperado '$2', veio '$3'"; }
has() { grep -q -E -e "$3" "$2" 2>/dev/null && ok "$1" || bad "$1: '$3' ausente em $2"; }
hasnt() { grep -q -E -e "$3" "$2" 2>/dev/null && bad "$1: '$3' presente em $2" || ok "$1"; }

cat > "$T/bin/mbp-run.sh" <<'STUB'
#!/usr/bin/env bash
echo "RUN:$* MBP_CITY=${MBP_CITY:-}" >> "$STUB_LOG"
[ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
[ -n "${STUB_OUT:-}" ] && printf '%b\n' "$STUB_OUT"
exit "${STUB_RC:-0}"
STUB
cat > "$T/bin/notify" <<'STUB'
#!/usr/bin/env bash
echo "NOTIFY:$*" >> "$STUB_LOG"
exit "${STUB_NOTIFY_RC:-0}"
STUB
chmod +x "$T/bin/"*
export STUB_LOG GC_CITY_PATH="$C" HETZNER_RESEED_RUN="$T/bin/mbp-run.sh" HETZNER_RESEED_NOTIFY="$T/bin/notify"
reset() { : > "$STUB_LOG"; rm -f "$FLAG" "$LOG"; unset STUB_RC STUB_OUT STUB_SLEEP STUB_NOTIFY_RC HETZNER_RESEED_TIMEOUT_S; }
w() { bash "${1:-$W}" >"$T/out" 2>"$T/err"; echo $?; }

reset; rc=$(w); eq "bandeira ausente: rc 0" 0 "$rc"; has "…veredito OFF" "$T/out" 'VERDICT: OFF'; hasnt "…não roda o seed" "$STUB_LOG" 'RUN:'; hasnt "…não notifica" "$STUB_LOG" 'NOTIFY:'; has "…grava a linha OFF" "$LOG" '"verdict":"OFF"'
reset; touch "$FLAG"; rc=$(w); eq "bandeira ligada, seed rc 0: rc 0" 0 "$rc"; has "…veredito OK" "$T/out" 'VERDICT: OK'
has "…roda --host linux --seed wa" "$STUB_LOG" 'RUN:--host linux --seed wa'; has "…com a cidade certa" "$STUB_LOG" "MBP_CITY=$C"; hasnt "…sem notify" "$STUB_LOG" 'NOTIFY:'; has "…grava OK" "$LOG" '"verdict":"OK","rc":0'
reset; touch "$FLAG"; [ ! -e "$C/.gc/mbp-offload.on" ] && ok "(a chave do MBP está desligada neste teste)"; rc=$(w); has "o nó se atualiza com a chave do MBP DESLIGADA (independente)" "$STUB_LOG" 'RUN:--host linux --seed wa'
reset; touch "$FLAG"; echo "origem=painel desde=hoje" > "$C/.gc/mbp-offload.pause"; rc=$(w); has "…e com o MBP PAUSADO pelo Athos" "$STUB_LOG" 'RUN:--host linux --seed wa'; eq "…rc 0" 0 "$rc"; rm -f "$C/.gc/mbp-offload.pause"
reset; touch "$FLAG"; rc=$(STUB_RC=98 STUB_OUT='mbp-run: nó Linux inalcançável' w); eq "seed rc 98: rc 1" 1 "$rc"; has "…FALHOU" "$T/out" 'VERDICT: FALHOU'; has "…UM notify prio 4" "$STUB_LOG" 'NOTIFY:.*-p 4 .*FAILED \(rc=98'; eq "…um só notify" 1 "$(grep -c NOTIFY: "$STUB_LOG")"; has "…diz o que o rc quer dizer" "$STUB_LOG" 'node unreachable/unhealthy'; has "…grava FALHOU com a saída" "$LOG" '"verdict":"FALHOU","rc":98,"detail":"[^"]*inalcançável'
reset; touch "$FLAG"; rc=$(STUB_RC=97 w); has "seed rc 97: o aviso fala de configuração" "$STUB_LOG" 'configuration'
reset; touch "$FLAG"; rc=$(STUB_RC=124 w); has "seed rc 124: o aviso fala de prazo" "$STUB_LOG" 'timed out'
reset; touch "$FLAG"; rc=$(STUB_RC=98 STUB_OUT='mbp-run: ALARME: dado ou segredo no destino (nó Linux:gt-remote/wa-base) — o filtro deixou passar:\n  ./.env' w); eq "ALARME: rc 1" 1 "$rc"; has "…veredito ALARME" "$T/out" 'VERDICT: ALARME'; has "…notify prio 5 (o requisito de segurança da bead)" "$STUB_LOG" 'NOTIFY:.*-p 5 .*ALARME'; hasnt "…e não o de prio 4" "$STUB_LOG" '-p 4'; has "…grava ALARME" "$LOG" '"verdict":"ALARME"'
reset; touch "$FLAG"; rc=$(STUB_RC=98 STUB_NOTIFY_RC=1 w); eq "notify que falha: o veredito continua FALHOU (rc 1)" 1 "$rc"; has "…e a falha do notify é DITA" "$T/out" 'WARN: notify failed'
reset; touch "$FLAG"; rc=$(STUB_RC=98 HETZNER_RESEED_NOTIFY="$T/nao-existe" w); eq "notify ausente: rc 1" 1 "$rc"; has "…e avisa" "$T/out" 'notify not found'
reset; touch "$FLAG"; rc=$(HETZNER_RESEED_RUN="$T/nao-existe.sh" w); eq "mbp-run.sh ausente: rc 1 (não é sucesso calado)" 1 "$rc"; has "…diz qual" "$T/err" 'mbp-run.sh not found'; hasnt "…e não finge OK" "$T/out" 'VERDICT: OK'
has "…veredito FALHOU (não só stderr)" "$T/out" 'VERDICT: FALHOU'; has "…grava a linha FALHOU com o motivo" "$LOG" '"verdict":"FALHOU","rc":1,"detail":"mbp-run.sh not found'; has "…e UM notify prio 4" "$STUB_LOG" 'NOTIFY:.*-p 4 .*mbp-run\.sh not found'; eq "…um só notify" 1 "$(grep -c NOTIFY: "$STUB_LOG")"
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  reset; touch "$FLAG"; rc=$(STUB_SLEEP=6 HETZNER_RESEED_TIMEOUT_S=1 w); eq "estouro do prazo (1 s contra um seed de 6 s): FALHOU" 1 "$rc"; has "…com o rc 124" "$STUB_LOG" 'rc=124'
else echo "SKIP estouro de prazo: sem timeout/gtimeout neste host (esse caminho NÃO foi exercitado)"; fi
# o ALARME não desliga o nó (a bandeira segue ligada e as baterias seguem clonando espelhos da base marcada): o notify de prio 5 manda o Mayor desligar
reset; touch "$FLAG"; STUB_RC=98 STUB_OUT='mbp-run: ALARME: dado ou segredo no destino (nó Linux:gt-remote/wa-base) — o filtro deixou passar:\n  ./.env' w >/dev/null
has "ALARME: o notify manda desligar o nó (mbp-offload.sh node off)" "$STUB_LOG" 'NOTIFY:.*-p 5 .*mbp-offload\.sh node off'
# sem timeout/gtimeout no PATH (o do launchd é curto): o seed roda do mesmo jeito, mas o teto de prazo perdido é DITO, não calado
mkdir -p "$T/nobin"; for c in bash env date mkdir dirname jq tail tr cut grep cat; do p=$(command -v "$c") && ln -sf "$p" "$T/nobin/$c"; done
BASH_BIN=$(command -v bash)
reset; touch "$FLAG"; PATH="$T/nobin" "$BASH_BIN" "$W" >"$T/out" 2>"$T/err"; rc=$?; eq "sem timeout no PATH: o seed roda e o veredito é OK" 0 "$rc"; has "…o seed rodou" "$STUB_LOG" 'RUN:--host linux --seed wa'
has "…e DIZ que o teto de prazo se perdeu" "$T/out" 'WARN: no timeout/gtimeout in PATH'; has "…e que só vale o prazo da order" "$T/out" "order's own timeout"
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  reset; touch "$FLAG"; rc=$(w); hasnt "com timeout no PATH: nenhum aviso de teto perdido" "$T/out" 'no timeout/gtimeout'
fi

# controle negativo: sem o reconhecimento do ALARME o caso do alarme degrada para FALHOU (prio 4)
sed "s/grep -q 'ALARME: dado ou segredo no destino'/grep -q 'XXXX-nunca-casa'/" "$W" > "$T/mut.sh"; chmod +x "$T/mut.sh"
n=$((n+1)); if cmp -s "$W" "$T/mut.sh"; then echo "FAIL controle: o sed não mudou nada"; fails=$((fails+1)); else
  reset; touch "$FLAG"; STUB_RC=98 STUB_OUT='ALARME: dado ou segredo no destino' w "$T/mut.sh" >/dev/null
  if grep -q 'NOTIFY:.*-p 5' "$STUB_LOG"; then echo "FAIL controle: o mutante ainda dá prio 5"; fails=$((fails+1)); else echo "ok   controle: sem o reconhecimento, o alarme vira prio 4 (e o caso do ALARME pega)"; fi; fi
# controle negativo 2: sem o aviso o teto perdido volta a ser calado e o caso do WARN o pega
sed 's/else say "WARN: no timeout\/gtimeout in PATH[^;]*; out=/else out=/' "$W" > "$T/mut2.sh"
n=$((n+1)); if cmp -s "$W" "$T/mut2.sh"; then echo "FAIL controle: o sed do aviso não mudou nada"; fails=$((fails+1)); else
  reset; touch "$FLAG"; PATH="$T/nobin" "$BASH_BIN" "$T/mut2.sh" >"$T/out" 2>"$T/err"
  if grep -q 'no timeout/gtimeout' "$T/out"; then echo "FAIL controle: o mutante ainda avisa"; fails=$((fails+1)); else echo "ok   controle: sem o aviso o teto perdido fica calado (e o caso do WARN pega)"; fi; fi
echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
