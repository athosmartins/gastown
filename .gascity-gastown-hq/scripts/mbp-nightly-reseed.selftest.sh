#!/usr/bin/env bash
# mbp-nightly-reseed.selftest.sh — hermético: mbp-run.sh e notify são stubs; nada toca o MBP, o notify real nem o live.
#
# Contents
#   Casos · Controles negativos
#
# CASOS: chave desligada(PULADO) · OK nos dois repos · wa falha e ps ainda roda(FALHOU+notify) · ps falha e wa ok · prazo
#   estourado · dreno vivo(PULADO) / vencido / ilegível · lock de dono vivo(PULADO) / de dono morto(toma) / liberado ao fim ·
#   notify ausente avisa · lista de repos vazia não é OK · última linha é o veredito e o jsonl bate com ela.
# CONTROLES NEGATIVOS: três mutantes do script (sem a trava da chave, sem o notify, rc ignorado) que os casos têm de reprovar.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/mbp-nightly-reseed.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/mbp-reseed-selftest.XXXXXX")
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
mkdir -p "$T/city/.gc/logs"

# stub do mbp-run.sh: registra o repo e devolve o rc pedido (STUB_RC_<REPO>), opcionalmente dormindo (STUB_SLEEP)
cat > "$T/run-stub.sh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "--seed" ] || { echo "stub: uso inesperado: $*" >&2; exit 97; }
echo "$2" >> "$STUB_CALLS"
[ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
var="STUB_RC_$(printf '%s' "$2" | tr a-z A-Z)"; rc="${!var:-0}"
if [ "$rc" = 0 ]; then echo "mbp-run: site-packages do MBP já bate (hash abc123def456)"; else echo "mbp-run: stub falhou ($2)"; fi
exit "$rc"
EOF
cat > "$T/notify-stub.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_NOTIFY_LOG"
exit "${STUB_NOTIFY_RC:-0}"
EOF
chmod +x "$T/run-stub.sh" "$T/notify-stub.sh"

export MBP_CITY="$T/city" MBP_RESEED_RUN="$T/run-stub.sh" MBP_RESEED_NOTIFY="$T/notify-stub.sh" MBP_RESEED_DRAIN_FILE="$T/drain.level"
export STUB_CALLS="$T/calls" STUB_NOTIFY_LOG="$T/notify.log"
FLAG="$T/city/.gc/mbp-offload.on"; JSONL="$T/city/.gc/logs/mbp-nightly-reseed.jsonl"; LOCK="$T/city/.gc/mbp-nightly-reseed.lock"
unset MBP_RESEED_TIMEOUT_S MBP_RESEED_REPOS STUB_SLEEP STUB_RC_WA STUB_RC_PS STUB_NOTIFY_RC
fails=0; n=0
reset() { : > "$STUB_CALLS"; : > "$STUB_NOTIFY_LOG"; : > "$JSONL"; rm -f "$T/drain.level"; rmdir "$LOCK" 2>/dev/null
          unset STUB_SLEEP STUB_RC_WA STUB_RC_PS STUB_NOTIFY_RC MBP_RESEED_TIMEOUT_S MBP_RESEED_REPOS; date > "$FLAG"; }
run() { "${1:-$SUT}" >"$T/out" 2>"$T/err"; echo $?; }
expect() { n=$((n+1)); if [ "$2" = "$3" ]; then echo "ok   $1 (rc=$3)"; else echo "FAIL $1: esperado rc=$2, veio $3"; fails=$((fails+1)); fi; }
has()   { n=$((n+1)); if grep -q -E "$3" "$2"; then echo "ok   $1"; else echo "FAIL $1: '$3' ausente em $2"; fails=$((fails+1)); fi; }
hasnt() { n=$((n+1)); if grep -q -E "$3" "$2"; then echo "FAIL $1: '$3' presente em $2"; fails=$((fails+1)); else echo "ok   $1"; fi; }
lastline() { n=$((n+1)); l=$(tail -n 1 "$T/out" | sed 's/^[^ ]* mbp-nightly-reseed: //'); if [ "$l" = "VEREDITO: $1" ]; then echo "ok   última linha = VEREDITO: $1"; else echo "FAIL última linha: '$l' != 'VEREDITO: $1'"; fails=$((fails+1)); fi
             v=$(tail -n 1 "$JSONL" | jq -r .verdict 2>/dev/null); n=$((n+1)); if [ "$v" = "$1" ]; then echo "ok   jsonl verdict = $1"; else echo "FAIL jsonl verdict '$v' != '$1'"; fails=$((fails+1)); fi; }

# 1 chave desligada -> PULADO, não chama nada, não avisa
reset; rm -f "$FLAG"; rc=$(run); expect "chave desligada" 0 "$rc"; lastline PULADO; hasnt "não semeia" "$STUB_CALLS" '.'; hasnt "não avisa" "$STUB_NOTIFY_LOG" '.'
has "diz o motivo" "$T/out" 'offload desligado'
# 2 OK nos dois repos
reset; rc=$(run); expect "ok wa+ps" 0 "$rc"; lastline OK; has "semeou wa" "$STUB_CALLS" '^wa$'; has "semeou ps" "$STUB_CALLS" '^ps$'; hasnt "não avisa quando ok" "$STUB_NOTIFY_LOG" '.'
has "mostra o texto do mbp-run" "$T/out" 'wa OK .*já bate'
# 3 wa falha (98) e ps ainda roda; UM notify com repo e rc
reset; rc=$(STUB_RC_WA=98 run); expect "wa 98" 1 "$rc"; lastline FALHOU; has "ps rodou mesmo assim" "$STUB_CALLS" '^ps$'
has "notify com título" "$STUB_NOTIFY_LOG" '^-t MBP reseed noturno FALHOU -p 4 '; has "notify cita wa e rc" "$STUB_NOTIFY_LOG" 'wa\(rc=98'; hasnt "notify não cita ps" "$STUB_NOTIFY_LOG" 'ps\(rc'
n=$((n+1)); c=$(wc -l < "$STUB_NOTIFY_LOG" | tr -d ' '); if [ "$c" = 1 ]; then echo "ok   exatamente 1 notify"; else echo "FAIL notify: $c linhas"; fails=$((fails+1)); fi
has "diz o que 98 quer dizer" "$STUB_NOTIFY_LOG" 'MBP indispon'
# 4 ps falha (97), wa ok
reset; rc=$(STUB_RC_PS=97 run); expect "ps 97" 1 "$rc"; lastline FALHOU; has "notify cita ps" "$STUB_NOTIFY_LOG" 'ps\(rc=97'; hasnt "notify não cita wa" "$STUB_NOTIFY_LOG" 'wa\(rc'
has "wa registrado OK no jsonl" "$JSONL" 'wa=OK:0'
# 5 prazo estourado
reset; rc=$(STUB_SLEEP=5 MBP_RESEED_TIMEOUT_S=1 MBP_RESEED_REPOS=wa run); expect "prazo" 1 "$rc"; lastline FALHOU; has "notify fala do prazo" "$STUB_NOTIFY_LOG" 'prazo'
# 6 dreno
reset; printf 'DRAIN\n%s\n123\n%s\n' "$(date +%s)" "$(( $(date +%s) + 3600 ))" > "$T/drain.level"; rc=$(run); expect "dreno vivo" 0 "$rc"; lastline PULADO
hasnt "dreno vivo não semeia" "$STUB_CALLS" '.'; has "diz dreno" "$T/out" 'dreno do reboot'
reset; printf 'DRAIN\n%s\n123\n%s\n' "$(date +%s)" "$(( $(date +%s) - 60 ))" > "$T/drain.level"; rc=$(run); expect "dreno vencido" 0 "$rc"; lastline OK
reset; printf 'lixo\n' > "$T/drain.level"; rc=$(run); expect "dreno ilegível segue" 0 "$rc"; lastline OK; has "avisa ilegível" "$T/out" 'WARN: sinal de dreno .* ilegível'
reset; printf 'DRAIN\n%s\n123\n%s\n' "$(date +%s)" "$(( $(date +%s) + 172800 ))" > "$T/drain.level"; rc=$(run); expect "dreno com até implausível segue" 0 "$rc"; lastline OK
has "avisa implausível" "$T/out" 'WARN: sinal de dreno .* além do plausível'; has "semeou mesmo assim" "$STUB_CALLS" '^wa$'
# 7 lock
reset; sleep 30 & holder=$!; mkdir "$LOCK"; echo "$holder" > "$LOCK/pid"; rc=$(run); expect "lock de dono vivo" 0 "$rc"; lastline PULADO
hasnt "dono vivo: não semeia" "$STUB_CALLS" '.'; has "diz que há outro" "$T/out" 'outro reseed em andamento'; kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
n=$((n+1)); if [ -d "$LOCK" ]; then echo "ok   lock do outro não foi apagado"; else echo "FAIL lock do outro sumiu"; fails=$((fails+1)); fi
rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null
# lock com pid vivo mas velho demais (pid reaproveitado): toma e avisa, não pula
reset; sleep 30 & holder=$!; mkdir "$LOCK"; echo "$holder" > "$LOCK/pid"; touch -t "$(date -v-1d +%Y%m%d%H%M)" "$LOCK"
rc=$(run); expect "lock velho com pid vivo" 0 "$rc"; lastline OK; has "avisa lock velho" "$T/out" 'WARN: lock .* com mais de [0-9]+ min'; has "semeou" "$STUB_CALLS" '^wa$'
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null
reset; mkdir "$LOCK"; echo 999999 > "$LOCK/pid"; rc=$(run); expect "lock de dono morto" 0 "$rc"; lastline OK; has "tomou e semeou" "$STUB_CALLS" '^wa$'
n=$((n+1)); if [ ! -d "$LOCK" ]; then echo "ok   lock liberado ao fim"; else echo "FAIL lock ficou"; fails=$((fails+1)); fi
reset; STUB_RC_WA=98 run >/dev/null; n=$((n+1)); if [ ! -d "$LOCK" ]; then echo "ok   lock liberado também na falha"; else echo "FAIL lock ficou após falha"; fails=$((fails+1)); fi
# 8 notify quebrado/ausente não esconde a falha
reset; rc=$(STUB_RC_WA=98 STUB_NOTIFY_RC=1 run); expect "notify com erro" 1 "$rc"; lastline FALHOU; has "avisa que não chegou" "$T/out" 'WARN: notify saiu com erro'
reset; rc=$(STUB_RC_WA=98 MBP_RESEED_NOTIFY="$T/nao-existe" run); expect "notify ausente" 1 "$rc"; has "avisa ausente" "$T/out" 'WARN: .*ausente'
# 9 lista sem repo nenhum (só espaço; variável vazia cai no padrão "wa ps" por causa do :-)
reset; rc=$(MBP_RESEED_REPOS=" " run); expect "sem repos" 1 "$rc"; lastline FALHOU; has "notify diz que nada foi semeado" "$STUB_NOTIFY_LOG" 'nenhum repo'

# ---- controles negativos: cada mutante tem de ser REPROVADO pelo caso correspondente ---------------------------------------
mutant() { # arquivo sed-expr
  sed "$2" "$SUT" > "$1"; chmod +x "$1"; cmp -s "$SUT" "$1" && { echo "FAIL mutante $1 igual ao original (sed não casou)"; fails=$((fails+1)); n=$((n+1)); return 1; }; return 0; }
# M1: sem a trava da chave, "desligado" deixaria de ser PULADO
reset; rm -f "$FLAG"; if mutant "$T/m1.sh" 's/^\[ -f "\$FLAG" \] || skip.*$/true/'; then
  rc=$(run "$T/m1.sh"); n=$((n+1)); if [ -s "$STUB_CALLS" ]; then echo "ok   M1 (sem trava da chave semeia com a chave off)"; else echo "FAIL M1: mutante ainda não semeou"; fails=$((fails+1)); fi; fi
# M2: sem o notify, a falha ficaria muda
reset; if mutant "$T/m2.sh" 's/"\$NOTIFY" -t /true -t /'; then
  rc=$(STUB_RC_WA=98 run "$T/m2.sh"); n=$((n+1)); if [ ! -s "$STUB_NOTIFY_LOG" ]; then echo "ok   M2 (sem a chamada do notify o log fica vazio)"; else echo "FAIL M2: mutante ainda avisou"; fails=$((fails+1)); fi; fi
# M3: rc ignorado, falha viraria OK
reset; if mutant "$T/m3.sh" 's/if \[ "\$rc" -eq 0 \]; then/if true; then/'; then
  rc=$(STUB_RC_WA=98 run "$T/m3.sh"); n=$((n+1)); if [ "$rc" = 0 ] && tail -n 1 "$T/out" | grep -q 'VEREDITO: OK'; then echo "ok   M3 (rc ignorado vira OK — os casos 3/4 pegam)"; else echo "FAIL M3: mutante não virou OK (rc=$rc)"; fails=$((fails+1)); fi; fi

echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
