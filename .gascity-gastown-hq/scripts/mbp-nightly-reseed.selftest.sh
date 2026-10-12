#!/usr/bin/env bash
# mbp-nightly-reseed.selftest.sh — hermético: mbp-run.sh e notify são stubs; nada toca o MBP, o notify real nem o live.
#
# Contents
#   Casos · Controles negativos
#
# CASOS: chave desligada(PULADO) · OK nos dois repos · wa falha e ps ainda roda(FALHOU+notify) · ps falha e wa ok · prazo
#   estourado · dreno vivo(PULADO) / vencido / ilegível · lock de dono vivo(PULADO) / de dono morto(toma) / liberado ao fim ·
#   notify ausente avisa · lista de repos vazia não é OK · última linha é o veredito e o jsonl bate com ela.
#   TERCEIRO ESTADO (ga-wuwuk7, gate-fix): o que não dá para olhar, criar, remover, gravar ou medir é FALHOU, nunca PULADO:
#   .gc sem permissão e sem lock · lock velho de dono morto que não sai (pasta de cima ou o próprio lock sem permissão) · lock
#   velho de pid vivo que não sai · $LOCK que é arquivo · mkdir que cria o lock mas o pid não grava · chave que não se
#   consegue olhar · mtime do lock no futuro · lock tomado e reocupado em seguida. PULADO continua valendo com evidência
#   positiva: dono vivo (inclusive de outro usuário, EPERM), com a pasta de cima sem permissão, ou lock sem pid recém-criado.
# CONTROLES NEGATIVOS: mutantes do script que os casos têm de reprovar: sem a trava da chave, sem o notify, rc ignorado (M1-M3)
#   e a volta de cada PULADO antigo no lugar do FALHOU (M4-M9: sem lock, lock que não sai, pid não gravado, chave ilegível,
#   EPERM lido como morto, idade no futuro lida como recente). Os casos de permissão exigem usuário não-root (chmod não barra root).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/mbp-nightly-reseed.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/mbp-reseed-selftest.XXXXXX")
trap 'chmod -R u+rwx "$T" 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
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
reset() { chmod 755 "$T/city/.gc" 2>/dev/null; chmod -R u+rwx "$LOCK" 2>/dev/null; [ -f "$LOCK" ] && rm -f "$LOCK"; rm -f "$LOCK/pid"
          : > "$STUB_CALLS"; : > "$STUB_NOTIFY_LOG"; : > "$JSONL"; rm -f "$T/drain.level"; rmdir "$LOCK" 2>/dev/null
          unset STUB_SLEEP STUB_RC_WA STUB_RC_PS STUB_NOTIFY_RC MBP_RESEED_TIMEOUT_S MBP_RESEED_REPOS; date > "$FLAG"; }
run() { "${1:-$SUT}" >"$T/out" 2>"$T/err"; echo $?; }
expect() { n=$((n+1)); if [ "$2" = "$3" ]; then echo "ok   $1 (rc=$3)"; else echo "FAIL $1: esperado rc=$2, veio $3"; fails=$((fails+1)); fi; }
has()   { n=$((n+1)); if grep -q -E "$3" "$2"; then echo "ok   $1"; else echo "FAIL $1: '$3' ausente em $2"; fails=$((fails+1)); fi; }
hasnt() { n=$((n+1)); if grep -q -E "$3" "$2"; then echo "FAIL $1: '$3' presente em $2"; fails=$((fails+1)); else echo "ok   $1"; fi; }
lastout() { n=$((n+1)); l=$(tail -n 1 "$T/out" | sed 's/^[^ ]* mbp-nightly-reseed: //'); if [ "$l" = "VEREDITO: $1" ]; then echo "ok   última linha = VEREDITO: $1"; else echo "FAIL última linha: '$l' != 'VEREDITO: $1'"; fails=$((fails+1)); fi; }
lastline() { lastout "$1"
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

# 10 terceiro estado do lock e da chave (ga-wuwuk7, gate-fix): "não consegui" nunca é "tem outro rodando" nem "desligado".
# falhou_case <rótulo> <regex da causa no notify> [semlog]  (rc em $rc): FALHOU, 1 notify que nomeia a causa, nada semeado, nunca PULADO
falhou_case() {
  expect "$1 -> FALHOU" 1 "$rc"; if [ -n "${3:-}" ]; then lastout FALHOU; else lastline FALHOU; fi
  hasnt "$1: não semeia" "$STUB_CALLS" '.'; hasnt "$1: não vira PULADO" "$T/out" 'PULADO'; has "$1: notify nomeia a causa" "$STUB_NOTIFY_LOG" "$2"
  n=$((n+1)); c=$(wc -l < "$STUB_NOTIFY_LOG" | tr -d ' '); if [ "$c" = 1 ]; then echo "ok   $1: exatamente 1 notify"; else echo "FAIL $1: $c linhas de notify"; fails=$((fails+1)); fi; }
# cenários (também reusados pelos mutantes M4-M9)
sc_lock_is_file()     { reset; echo x > "$LOCK"; }
sc_no_lock_ro()       { reset; chmod 555 "$T/city/.gc"; }
sc_stale_ro_parent()  { reset; mkdir "$LOCK"; echo 999999 > "$LOCK/pid"; chmod 555 "$T/city/.gc"; }
sc_stale_ro_lock()    { reset; mkdir "$LOCK"; echo 999999 > "$LOCK/pid"; chmod 555 "$LOCK"; }
sc_key_unreadable()   { reset; chmod 000 "$T/city/.gc"; }
sc_eperm_owner()      { reset; mkdir "$LOCK"; echo 1 > "$LOCK/pid"; }
sc_future_lock()      { reset; mkdir "$LOCK"; touch -t "$(date -v+1d +%Y%m%d%H%M)" "$LOCK"; }
# mkdir de mentira (PATH na frente): o de verdade cria o lock; depois trava a pasta (pid não grava) ou recria o lock velho a cada vez
mkdir -p "$T/shadow-pid" "$T/shadow-contend"
cat > "$T/shadow-pid/mkdir" <<'EOF'
#!/bin/bash
/bin/mkdir "$@" || exit $?
for a in "$@"; do case "$a" in *.lock) chmod 555 "$a" ;; esac; done
EOF
cat > "$T/shadow-contend/mkdir" <<'EOF'
#!/bin/bash
for a in "$@"; do case "$a" in *.lock) /bin/mkdir "$a" 2>/dev/null; echo 999999 > "$a/pid"; echo "mkdir: $a: File exists" >&2; exit 1 ;; esac; done
exec /bin/mkdir "$@"
EOF
chmod +x "$T/shadow-pid/mkdir" "$T/shadow-contend/mkdir"

# $LOCK existe mas é arquivo: mkdir não cria e não há dono para esperar (funciona até como root)
sc_lock_is_file; rc=$(run); falhou_case "lock é arquivo" 'não consegui criar o lock.*File exists'; rm -f "$LOCK"
# lock tomado e reocupado por um lock velho a cada tentativa: desiste, nomeando a disputa (funciona até como root)
reset; rc=$(PATH="$T/shadow-contend:$PATH" run); falhou_case "lock reocupado" 'disputado'
# mtime do lock no futuro (relógio voltou): idade que não existe não é "recém-criado"
sc_future_lock; rc=$(run); falhou_case "lock sem pid com mtime no futuro" 'não consegui avaliar o lock'
# o que continua PULADO/seguindo, com evidência positiva: lock sem pid recém-criado pula; sem pid e velho toma; pid ilegível e velho toma
reset; mkdir "$LOCK"; rc=$(run); expect "lock sem pid recém-criado" 0 "$rc"; lastline PULADO; has "diz que está começando" "$T/out" 'outro reseed começando'; hasnt "não semeia" "$STUB_CALLS" '.'
reset; mkdir "$LOCK"; touch -t "$(date -v-10M +%Y%m%d%H%M)" "$LOCK"; rc=$(run); expect "lock sem pid velho de minutos" 0 "$rc"; lastline OK; has "tomou e semeou" "$STUB_CALLS" '^wa$'
reset; mkdir "$LOCK"; echo "lixo" > "$LOCK/pid"; touch -t "$(date -v-10M +%Y%m%d%H%M)" "$LOCK"; rc=$(run); expect "pid ilegível e velho" 0 "$rc"; lastline OK; has "avisa o pid ilegível" "$T/out" "WARN: pid do lock .* ilegível"

if [ "$(id -u)" -eq 0 ]; then
  n=$((n+1)); fails=$((fails+1)); echo "FAIL casos de permissão: rodando como root (chmod não barra root) — rodar como usuário comum"
else
  # A: sem lock e a pasta de cima sem permissão -> o mkdir falha por permissão, não por "já existe"
  sc_no_lock_ro; rc=$(run); falhou_case "sem lock, .gc sem permissão" 'não consegui criar o lock.*Permission denied'
  # B: lock velho de dono morto que não dá para remover (pasta de cima sem permissão; ou o próprio lock sem permissão)
  sc_stale_ro_parent; rc=$(run); falhou_case "lock velho, .gc sem permissão" 'não consegui remover o lock velho'
  sc_stale_ro_lock; rc=$(run); falhou_case "lock velho, sem permissão no lock" 'não consegui remover o lock velho'
  # B': lock com pid vivo e mais de LOCK_VELHO_MIN (toma por velho) que não dá para remover
  reset; sleep 30 & holder=$!; mkdir "$LOCK"; echo "$holder" > "$LOCK/pid"; touch -t "$(date -v-1d +%Y%m%d%H%M)" "$LOCK"; chmod 555 "$T/city/.gc"
  rc=$(run); falhou_case "lock velho de pid vivo, .gc sem permissão" 'não consegui remover o lock velho'; kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  # C: o mkdir cria o lock mas o pid não grava (lock sem dono gravado deixaria uma segunda rodada pisar nesta)
  reset; rc=$(PATH="$T/shadow-pid:$PATH" run); falhou_case "pid do dono não grava" 'não consegui gravar o pid'
  n=$((n+1)); if [ ! -d "$LOCK" ]; then echo "ok   pid não grava: o lock não fica órfão"; else echo "FAIL pid não grava: lock ficou"; fails=$((fails+1)); fi
  # D: não dá para olhar a chave ($CITY/.gc sem acesso) -> não é "desligada"; o jsonl também fica fora de alcance
  sc_key_unreadable; rc=$(run); falhou_case "chave que não se consegue olhar" 'não consegui olhar a chave' semlog
  has "avisa que o log não gravou" "$T/out" 'WARN: não consegui gravar'
  # evidência positiva vence a falta de permissão: dono vivo continua PULADO com a pasta de cima sem permissão; EPERM (pid de outro usuário) é vivo
  reset; sleep 30 & holder=$!; mkdir "$LOCK"; echo "$holder" > "$LOCK/pid"; chmod 555 "$T/city/.gc"; rc=$(run); expect "dono vivo, .gc sem permissão" 0 "$rc"; lastout PULADO
  hasnt "não semeia" "$STUB_CALLS" '.'; kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  sc_eperm_owner; rc=$(run); expect "dono de outro usuário (kill -0 dá EPERM)" 0 "$rc"; lastline PULADO; has "diz o pid" "$T/out" 'em andamento \(pid 1\)'; hasnt "não semeia" "$STUB_CALLS" '.'
fi
reset

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

# M4-M9: o PULADO antigo no lugar do FALHOU (ou o erro de leitura de volta a "morto"/"recente") tem de aparecer nos cenários dos casos acima
mutant_pulou() { # rótulo (rc em $rc): o mutante diz PULADO onde o script diz FALHOU
  n=$((n+1)); if [ "$rc" = 0 ] && tail -n 1 "$T/out" | grep -q 'VEREDITO: PULADO'; then echo "ok   $1"; else echo "FAIL $1: mutante não virou PULADO (rc=$rc)"; fails=$((fails+1)); fi; }
if [ "$(id -u)" -ne 0 ]; then
  # M4: mkdir que falha sem deixar lock voltaria a ser "outro reseed em andamento"
  sc_no_lock_ro; if mutant "$T/m4.sh" 's/^\(    \[ "\$sem_lock" -ge 2 \] && \)falhou .*$/\1skip "outro reseed em andamento (pid ?)"/'; then
    rc=$(run "$T/m4.sh"); mutant_pulou "M4 (sem lock + mkdir falho volta a PULADO — o caso 'sem lock, .gc sem permissão' pega)"; fi
  # M5: lock velho que não sai voltaria a ser "não consegui tomar o lock" = PULADO
  sc_stale_ro_lock; if mutant "$T/m5.sh" 's/|| falhou "não consegui remover o lock velho.*$/|| skip "não consegui tomar o lock $LOCK"/'; then
    rc=$(run "$T/m5.sh"); mutant_pulou "M5 (lock velho que não sai volta a PULADO — os casos de lock velho pegam)"; fi
  # M6: pid não gravado sem checar -> semeia sem dono gravado
  reset; if mutant "$T/m6.sh" 's/^if ! { echo \$\$ > "\$LOCK\/pid"; } 2>\/dev\/null; then/if false; then/'; then
    rc=$(PATH="$T/shadow-pid:$PATH" run "$T/m6.sh"); n=$((n+1)); if [ "$rc" = 0 ] && [ -s "$STUB_CALLS" ]; then echo "ok   M6 (pid sem checar semeia sem dono gravado — o caso 'pid do dono não grava' pega)"; else echo "FAIL M6: mutante não semeou (rc=$rc)"; fails=$((fails+1)); fi; fi
  # M7: chave que não se consegue olhar voltaria a ser "offload desligado"
  sc_key_unreadable; if mutant "$T/m7.sh" 's/^\(\[ -f "\$FLAG" \] || { \[ -d "\$CITY\/\.gc" \] && \[ -x "\$CITY\/\.gc" \]; } || \)falhou .*$/\1skip "offload desligado (falta $FLAG)"/'; then
    rc=$(run "$T/m7.sh"); mutant_pulou "M7 (chave ilegível volta a PULADO — o caso 'chave que não se consegue olhar' pega)"; fi
  # M8: EPERM lido como morto -> toma o lock de um dono vivo de outro usuário
  sc_eperm_owner; if mutant "$T/m8.sh" 's/\*"not permitted"\*) return 0 ;;/*"not permitted"*) return 1 ;;/'; then
    rc=$(run "$T/m8.sh"); n=$((n+1)); if [ "$rc" = 0 ] && [ -s "$STUB_CALLS" ]; then echo "ok   M8 (EPERM lido como morto toma o lock do outro — o caso 'dono de outro usuário' pega)"; else echo "FAIL M8: mutante não tomou o lock (rc=$rc)"; fails=$((fails+1)); fi; fi
fi
# M9: mtime no futuro lido como "recém-criado" (idade negativa)
sc_future_lock; if mutant "$T/m9.sh" 's/^  \[ "\$a" -ge 0 \] || return 1.*$/  true/'; then
  rc=$(run "$T/m9.sh"); mutant_pulou "M9 (idade negativa lida como recente volta a PULADO — o caso 'mtime no futuro' pega)"; fi
reset

echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
