#!/usr/bin/env bash
# engine-binary-backup-guard.selftest.sh (ga-ta2w6r)
#
# Roda o guard REAL (nao uma reimplementacao) contra um repo "engine" descartavel
# com origin -> repo bare local, binarios de mentira que imprimem o stamp de
# verdade, e um notify de mentira que so registra chamadas. Git roda de verdade:
# MISSING/OK/ORPHAN/UNKNOWN saem de refs reais. Cobre o ciclo de vida do alarme
# (dispara, dedupa, cala quando o backup aparece), o escopo das branches, a
# carencia, a sequencia de UNKNOWN, a armadilha do stamp do bd, a recusa sem
# flock, e -- estaticamente -- que o guard e DETECTION-ONLY.
# Exit 0 iff toda assercao vale.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ENGINE_BINARY_BACKUP_GUARD_UNDER_TEST: so pro teste de MUTACAO.
GUARD="${ENGINE_BINARY_BACKUP_GUARD_UNDER_TEST:-$SELF_DIR/../engine-binary-backup-guard.sh}"
# shellcheck source=engine-backup-fixture.sh
. "$SELF_DIR/engine-backup-fixture.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fx_init "$WORK"
E="$FX_ENGINE"
CITY="$WORK/city"
mkdir -p "$CITY/.beads" "$WORK/bin" "$WORK/wt"
NOTIFY_LOG="$WORK/notify.log"
fx_fake_notify "$WORK/fake-notify" "$NOTIFY_LOG"
: > "$NOTIFY_LOG"

short() { printf '%.9s' "$1"; }
notify_count() { wc -l < "$NOTIFY_LOG" | tr -d ' '; }
reset_state() { rm -f "$WORK/seen.json"; : > "$NOTIFY_LOG"; }

# git de mentira SO NO PATH do guard: registra cada subcomando que o guard de fato
# executa e delega ao git real. A secao 16 prova o detection-only pelo que rodou.
REAL_GIT=$(command -v git)
mkdir -p "$WORK/gitshim"
cat > "$WORK/gitshim/git" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/git-shim.log"
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$WORK/gitshim/git"
: > "$WORK/git-shim.log"

GRACE=3600
GUARD_BASH=bash
SPEC=""
# run_guard [args...] -> OUT (stdout+stderr) e RC
run_guard() {
    OUT=$(PATH="$WORK/gitshim:$PATH" GC_CITY_PATH="$CITY" \
        ENGINE_BACKUP_GUARD_ARTIFACTS="$SPEC" \
        ENGINE_WINDOW_GUARD_SRC_TREE="$E" \
        ENGINE_BACKUP_GUARD_SEEN_FILE="$WORK/seen.json" \
        ENGINE_BACKUP_GUARD_LOCK="$WORK/guard.lock" \
        ENGINE_BACKUP_GUARD_BRANCH_GRACE_S="$GRACE" \
        ENGINE_BACKUP_GUARD_UNKNOWN_STREAK=3 \
        NOTIFY_BIN="$WORK/fake-notify" EB_RETRY_SLEEP_S=0 \
        "$GUARD_BASH" "$GUARD" "$@" 2>&1)
    RC=$?
}
# jq sobre a saida --json:  jf <filtro>
jf() { printf '%s' "$OUT" | jq -r "$1" 2>/dev/null; }

echo "── 1. sintaxe (bash 3.2 e o do PATH) ──"
for B in /bin/bash "$(command -v bash)"; do
    if "$B" -n "$GUARD"; then ok "bash -n OK em $B"; else bad "bash -n FALHOU em $B"; fi
done

echo "── 2. invariantes ESTATICOS: o guard nao chama nada que builda, troca ou empurra ──"
# So o que grep consegue provar sem confundir prosa com comando: o guard nao
# CHAMA eb_push_branch (que existe na lib), nem build/swap/apagar. (O texto do
# alerta cita "git push" como instrucao ao humano -- por isso os verbos de git sao
# provados ao vivo na secao 16, pelo que o guard REALMENTE executa, e nao por grep.)
MUT=$(grep -nE 'eb_push_branch|rm -rf|kickstart|make build|launchctl|codesign|ln -s' "$GUARD" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
if [ -z "$MUT" ]; then ok "nenhuma linha de codigo do guard builda, troca binario, apaga ou empurra"; else bad "linha proibida no guard: $MUT"; fi

echo "── setup: engine com uma branch de janela NAO empurrada, ha 2h, num worktree engine-window-* ──"
git -C "$E" worktree add -q "$WORK/wt/engine-window-t1" -b consolidated/engine-window-T1 main
NOW=$(date +%s)
fx_commit "$WORK/wt/engine-window-t1" "t1-a" $((NOW - 7300)) >/dev/null
T1_TIP=$(fx_commit "$WORK/wt/engine-window-t1" "t1-b" $((NOW - 7200)))
MAIN_TIP=$(git -C "$E" rev-parse main)
SPEC="gc|gc|$WORK/bin/gc-live|$E"

echo "── 3. o INCIDENTE: o gc vivo deriva de um commit que nenhum remoto contem ──"
fx_fake_gc "$WORK/bin/gc-live" "$(short "$T1_TIP")-dirty"
GRACE=999999   # isola o sinal do binario (a branch ainda esta 'na carencia')
reset_state; run_guard --json
assert_eq "gc: estado MISSING" "MISSING" "$(jf '.rows[]|select(.kind=="artifact" and .name=="gc")|.state')"
assert_eq "  1 alarme ativo" "1" "$(jf '.alarms')"
assert_eq "  lido pelo stamp do BINARIO (o commit e o main.commit, sem -dirty)" "$(short "$T1_TIP")" "$(jf '.rows[]|select(.kind=="artifact")|.commit')"
assert_eq "  exatamente 1 notify" "1" "$(notify_count)"
assert_has "  de prioridade 4 (alta)" "$(cat "$NOTIFY_LOG")" "-p 4"
assert_has "  com o titulo que diz o problema" "$(cat "$NOTIFY_LOG")" "Engine SEM backup: gc"
assert_has "  e a instrucao de conserto (git push origin <branch>)" "$(cat "$NOTIFY_LOG")" "push origin consolidated/engine-window-T1"
assert_eq "  exit 0 (detection-only nunca reprova o order)" "0" "$RC"

echo "── 4. dedupe: o alarme continua ATIVO no relatorio mas nao re-notifica dentro do cooldown ──"
run_guard --json
assert_eq "segunda execucao: ainda 1 alarme ativo" "1" "$(jf '.alarms')"
assert_eq "  mas notify continua em 1 (cooldown de 24h)" "1" "$(notify_count)"

echo "── 5. a branch da janela sozinha (o indicador antecipado), com o binario OK ──"
fx_fake_gc "$WORK/bin/gc-live" "$(short "$MAIN_TIP")"
GRACE=3600
reset_state; run_guard --json
assert_eq "binario vivo OK (commit empurrado)" "OK" "$(jf '.rows[]|select(.kind=="artifact")|.state')"
assert_eq "branch T1 (2h sem push, > carencia de 1h) -> MISSING" "MISSING" "$(jf '.rows[]|select(.name=="consolidated/engine-window-T1")|.state')"
assert_eq "  com alarme" "true" "$(jf '.rows[]|select(.name=="consolidated/engine-window-T1")|.alarm')"
assert_eq "  1 alarme no total" "1" "$(jf '.alarms')"
assert_has "  notify da branch" "$(cat "$NOTIFY_LOG")" "Branch da janela SEM backup"
GRACE=999999
reset_state; run_guard --json
assert_eq "dentro da carencia (branch 'consolidando'): MISSING mas SEM alarme" "false" "$(jf '.rows[]|select(.name=="consolidated/engine-window-T1")|.alarm')"
assert_has "  e o detalhe diz que e a carencia" "$(jf '.rows[]|select(.name=="consolidated/engine-window-T1")|.detail')" "carencia"
assert_eq "  0 notify" "0" "$(notify_count)"

echo "── 6. o backup aparece -> o alarme se resolve sozinho ──"
GRACE=3600
git -C "$E" push -q origin consolidated/engine-window-T1
fx_fake_gc "$WORK/bin/gc-live" "$(short "$T1_TIP")-dirty"
reset_state; run_guard --json
assert_eq "gc derivado do commit agora empurrado -> OK" "OK" "$(jf '.rows[]|select(.kind=="artifact")|.state')"
assert_eq "  branch T1 -> OK" "OK" "$(jf '.rows[]|select(.name=="consolidated/engine-window-T1")|.state')"
assert_eq "  0 alarmes" "0" "$(jf '.alarms')"
assert_eq "  0 notify" "0" "$(notify_count)"

echo "── 7. branch ANTIGA nao empurrada e fora do escopo: informativa, NAO alarma (o caso da 0823) ──"
git -C "$E" checkout -q -b consolidated/engine-window-OLD main
fx_commit "$E" "velha" $((NOW - 2592000)) >/dev/null
git -C "$E" checkout -q main
reset_state; run_guard --json
assert_eq "OLD aparece no relatorio como MISSING" "MISSING" "$(jf '.rows[]|select(.name=="consolidated/engine-window-OLD")|.state')"
assert_eq "  escopo 'fora'" "fora" "$(jf '.rows[]|select(.name=="consolidated/engine-window-OLD")|.scope')"
assert_eq "  sem alarme" "false" "$(jf '.rows[]|select(.name=="consolidated/engine-window-OLD")|.alarm')"
assert_eq "  total 0 alarmes, 0 notify (alarmar nela pra sempre ensinaria a ignorar o guard)" "0:0" "$(jf '.alarms'):$(notify_count)"
assert_eq "  a mais nova (T1) NAO e classificada como 'fora'" "worktree-da-janela" "$(jf '.rows[]|select(.name=="consolidated/engine-window-T1")|.scope')"

echo "── 8. rede fora: UNKNOWN so alarma apos 3 execucoes SEGUIDAS ──"
git -C "$E" checkout -q -b scratch main
C_UNK=$(fx_commit "$E" "commit-so-local-do-cenario-unknown")
git -C "$E" checkout -q main
fx_fake_gc "$WORK/bin/gc-live" "$(short "$C_UNK")"
git -C "$E" remote set-url origin "$WORK/nao-existe.git"
reset_state
run_guard --json
assert_eq "1a execucao: UNKNOWN (NAO MISSING: sem fetch fresco nao acusa)" "UNKNOWN" "$(jf '.rows[]|select(.kind=="artifact")|.state')"
assert_eq "  sem alarme ainda" "0:0" "$(jf '.alarms'):$(notify_count)"
run_guard --json
assert_eq "2a execucao: ainda sem alarme" "0:0" "$(jf '.alarms'):$(notify_count)"
run_guard --json
assert_eq "3a execucao seguida: alarme" "1" "$(jf '.alarms')"
assert_eq "  1 notify" "1" "$(notify_count)"
assert_has "  prioridade 3 (nao 4: e incerteza, nao prova)" "$(cat "$NOTIFY_LOG")" "-p 3"
assert_has "  titulo diz que nao consegue VERIFICAR" "$(cat "$NOTIFY_LOG")" "Nao consigo verificar"
git -C "$E" remote set-url origin "$FX_REMOTE"
run_guard --json
assert_eq "rede volta: o commit e so-local -> vira MISSING de verdade" "MISSING" "$(jf '.rows[]|select(.kind=="artifact")|.state')"
git -C "$E" push -q origin scratch
run_guard --json
assert_eq "empurrado -> OK e o contador de UNKNOWN zera" "OK" "$(jf '.rows[]|select(.kind=="artifact")|.state')"
git -C "$E" remote set-url origin "$WORK/nao-existe.git"
reset_state
fx_fake_gc "$WORK/bin/gc-live" "$(short "$C_UNK")"
run_guard --json; run_guard --json
assert_eq "apos OK o contador recomecou: 2 UNKNOWNs seguidos nao alarmam" "0:0" "$(jf '.alarms'):$(notify_count)"
git -C "$E" remote set-url origin "$FX_REMOTE"

echo "── 9. ORPHAN e UNSTAMPED alarmam na hora ──"
reset_state
fx_fake_gc "$WORK/bin/gc-live" "deadbeef1"
run_guard --json
assert_eq "commit que nao existe no repo-fonte -> ORPHAN" "ORPHAN" "$(jf '.rows[]|select(.kind=="artifact")|.state')"
assert_eq "  alarme na hora, prioridade 4" "1:1" "$(jf '.alarms'):$(notify_count)"
assert_has "  p4" "$(cat "$NOTIFY_LOG")" "-p 4"
reset_state
fx_fake_gc_unstamped "$WORK/bin/gc-live"
run_guard --json
assert_eq "binario sem stamp -> UNSTAMPED" "UNSTAMPED" "$(jf '.rows[]|select(.kind=="artifact")|.state')"
assert_eq "  alarme na hora" "1:1" "$(jf '.alarms'):$(notify_count)"

echo "── 10. o bd: o stamp confiavel e .build, NAO .commit (que descreve o repo errado) ──"
reset_state
fx_fake_gc "$WORK/bin/gc-live" "$(short "$MAIN_TIP")"
WRONG_REPO_COMMIT="7a95fc7329e64e4f62b1469ed761a2cf40eb1f7e"
fx_fake_bd "$WORK/bin/bd-live" "$(short "$MAIN_TIP")" "$WRONG_REPO_COMMIT"
SPEC="gc|gc|$WORK/bin/gc-live|$E
bd|bd|$WORK/bin/bd-live|$E"
run_guard --json
assert_eq "bd com .build empurrado e .commit de outro repo -> OK (nao ORPHAN por causa do .commit)" "OK" "$(jf '.rows[]|select(.name=="bd")|.state')"
fx_fake_bd "$WORK/bin/bd-live" "$(short "$C_UNK")" "$(short "$MAIN_TIP")"
git -C "$E" push -q origin ":scratch" 2>/dev/null   # apaga o backup do C_UNK no remoto
run_guard --json
assert_eq "bd cujo .build e so-local (mesmo com .commit 'empurrado') -> MISSING" "MISSING" "$(jf '.rows[]|select(.name=="bd")|.state')"
SPEC="gc|gc|$WORK/bin/gc-live|$E"

echo "── 11. relatorio humano ──"
reset_state
run_guard
assert_has "cabecalho" "$OUT" "BACKUP DO QUE RODA"
assert_has "veredito com contagem e duracao medida" "$OUT" "VEREDITO:"
assert_has "lista as branches com escopo" "$OUT" "consolidated/engine-window-OLD"

echo "── 12. recusa SEM flock (nao pode virar no-op calado como o idioma do guard irmao) ──"
mkdir -p "$WORK/pathnoflock"
ln -sf "$(command -v jq)" "$WORK/pathnoflock/jq"
ln -sf "$(command -v dirname)" "$WORK/pathnoflock/dirname"
OUTNF=$(PATH="$WORK/pathnoflock" GC_CITY_PATH="$CITY" "$(command -v bash)" "$GUARD" 2>&1); RCNF=$?
assert_eq "sem flock no PATH -> exit 2 (alto), nao exit 0 calado" "2" "$RCNF"
assert_has "  a mensagem nomeia o flock" "$OUTNF" "flock"

echo "── 13. lock de instancia unica: com outra instancia rodando, sai limpo sem trabalhar ──"
( exec 9>"$WORK/guard.lock"; flock -n 9 && sleep 6 ) &
LOCK_PID=$!
sleep 1
run_guard
assert_eq "outra instancia segurando o lock -> exit 0" "0" "$RC"
assert_has "  diz que ja tem instancia rodando" "$OUT" "outra instancia ja rodando"
wait "$LOCK_PID" 2>/dev/null || true

echo "── 14. o mesmo cenario do incidente sob bash 3.2 (o /bin/bash do macOS) ──"
reset_state
fx_fake_gc "$WORK/bin/gc-live" "$(short "$C_UNK")"   # C_UNK ja nao esta em remoto (branch scratch apagada acima)
GUARD_BASH=/bin/bash; GRACE=999999
run_guard --json
assert_eq "MISSING detectado tambem no bash 3.2" "MISSING" "$(jf '.rows[]|select(.kind=="artifact")|.state')"
assert_eq "  e o notify sai" "1" "$(notify_count)"
GUARD_BASH=bash

echo "── 15. estado corrompido nao derruba o guard ──"
printf 'isto nao e json {{{' > "$WORK/seen.json"
run_guard --json
assert_eq "seen.json corrompido -> recomeca do zero, exit 0" "0" "$RC"
assert_eq "  e ainda produz JSON valido" "true" "$(printf '%s' "$OUT" | jq -e '.rows|length>0' >/dev/null 2>&1 && echo true || echo false)"

echo "── 16. invariante COMPORTAMENTAL: todo git que o guard executou, em TODOS os cenarios acima ──"
# Verbo = primeiro argumento que nao e opcao (pulando '-C <dir>' e '-c <k=v>'); para
# 'worktree' o subcomando tambem conta (so 'list' e leitura).
USED=$(awk '{ i=1; while (i<=NF) { if ($i=="-C" || $i=="-c") { i+=2; continue } if ($i ~ /^-/) { i++; continue } v=$i; if (v=="worktree") v=v " " $(i+1); print v; break } }' "$WORK/git-shim.log" | sort -u)
NOT_ALLOWED=$(printf '%s\n' "$USED" | grep -vE '^(rev-parse|cat-file|for-each-ref|fetch|remote|worktree list)$' | grep -v '^$' || true)
assert_eq "so verbos de LEITURA + fetch (nada de push/checkout/reset/tag/branch/worktree add|remove...)" "" "$NOT_ALLOWED"
assert_has "  e o fetch de fato aconteceu (o guard nao e um leitor de refs velhos)" "$USED" "fetch"
assert_has "  verbos vistos: $(printf '%s' "$USED" | tr '\n' ' ')" "$USED" "for-each-ref"

fx_finish
