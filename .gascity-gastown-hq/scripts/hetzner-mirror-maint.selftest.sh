#!/bin/bash
# hetzner-mirror-maint.selftest.sh — hermético: tudo em mktemp, sem sshd, sem rede, sem tocar nos espelhos reais. Cobre `hetzner-mirror.sh maint` (ga-pepqfkk).
#
# ## Contents
#   Fixture · Receita (nunca -a) · Poda (o velho sai, o novo e o filtro ficam) · Portões · Trava · Prazo e teto de swap · Dry-run · Atraso · Sem ref · Auto-gc fixado
#
# Os portões (disco, load, swap) respondem por comando (HETZNER_MIRROR_MAINT_{FREE,LOAD,SWAP}_CMD) e o git é um shim que registra os argumentos (HETZNER_MIRROR_GIT), para provar a RECEITA e,
# com HMT_SLEEP, um repack lento (prazo e teto de swap). Leva ~30 s. HMT_M=<script> testa outra cópia do script (mutantes); HMT_KEEP=1 guarda o tmp.
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P); M=${HMT_M:-$HERE/hetzner-mirror.sh}
T=$(mktemp -d "${TMPDIR:-/tmp}/hmt.XXXXXX"); T=$(cd "$T" && pwd -P); chmod 700 "$T"; N=0; F=0; HMT_EXPECT=77
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_TERMINAL_PROMPT=0
export HETZNER_MIRROR_HOME=$T/mh HETZNER_MIRROR_ALLOW_WORKTREE=1 HETZNER_MIRROR_FILTER=$HERE/hetzner-rsync-filter.wa.txt HETZNER_MIRROR_SCAN=$HERE/hetzner-mirror-scan.py   # caminhos absolutos: um mutante (HMT_M) mora noutra pasta
export HETZNER_MIRROR_MAINT_FREE_CMD='echo 99999' HETZNER_MIRROR_MAINT_LOAD_CMD='echo 1' HETZNER_MIRROR_MAINT_SWAP_CMD='echo 100' HETZNER_MIRROR_MAINT_POLL=1   # "tudo livre"
ok() { N=$((N+1)); echo "ok   $N - $1"; }
bad() { N=$((N+1)); F=$((F+1)); echo "FAIL $N - $1"; [ -z "${2:-}" ] || echo "     $2" | head -n 8; return 0; }   # sempre 0: `A && bad .. || ok ..` contaria o caso duas vezes
cleanup() { [ -z "${FAKE_OWNER:-}" ] || kill "$FAKE_OWNER" 2>/dev/null; [ -n "${HMT_KEEP:-}" ] && echo "(mantido: $T)" || rm -rf "$T"; }; trap cleanup EXIT
rc_is() { local want=$1 desc=$2; shift 2; OUT=$("$@" 2>&1); local got=$?; [ "$got" = "$want" ] && ok "$desc" || bad "$desc (rc=$got, queria $want)" "$OUT"; }
has() { printf '%s' "$OUT" | grep -qF -- "$1" && ok "$2" || bad "$2 (faltou: $1)" "$OUT"; }
hasnt() { printf '%s' "$OUT" | grep -qF -- "$1" && bad "$2 (apareceu: $1)" "$OUT" || ok "$2"; }
loose() { git -C "$1" count-objects -v 2>/dev/null | awk '/^count:/ { print $2 }'; }
present() { git -C "$1" cat-file -e "$2" 2>/dev/null; }
cfg() { git -C "$1" config --get "$2" 2>/dev/null; }
mk_unreach() { local oid p; oid=$(printf 'unreach-%s-%s\n' "$2" "$RANDOM$RANDOM$RANDOM" | git -C "$1" hash-object -w --stdin); p="$1/objects/${oid:0:2}/${oid:2}"; [ "$3" != old ] || touch -t 202001010000 "$p"; echo "$oid"; }   # old = 3 semanas+ de idade
pgrep_sleep() { pgrep -f 'sleep 3[12]$' > /dev/null 2>&1; }

# ── fixture: um "origin", um shim de git e espelhos criados pelo próprio `init` ────────────────────────────────────────────────────────────────────────────────────────
REAL_GIT=$(command -v git); LOG=$T/git.log; : > "$LOG"; SWAPF=$T/swap; echo 100 > "$SWAPF"
cat > "$T/gitshim" <<'EOF'
#!/bin/sh
echo "$*" >> "$HMT_LOG"
case " $* " in *" repack "*)
  [ -z "${HMT_TMPFILE:-}" ] || : > "$2/objects/pack/tmp_pack_HMT"
  [ -z "${HMT_SWAPFILE:-}" ] || echo 3000 > "$HMT_SWAPFILE"
  if [ -n "${HMT_SLEEP:-}" ]; then sleep "$HMT_SLEEP" & wait; fi;; esac
exec "$HMT_REAL_GIT" "$@"
EOF
chmod 755 "$T/gitshim"; export HMT_LOG=$LOG HMT_REAL_GIT=$REAL_GIT HETZNER_MIRROR_GIT=$T/gitshim
O=$T/origin.git; W=$T/work; git init -q --bare "$O"; git clone -q "$O" "$W" 2>/dev/null
( cd "$W" && for i in 1 2 3; do echo "v$i" > "f$i.txt"; git add -A; git commit -qm "c$i"; done; git branch -M main; git push -q origin main 2>&1 | tail -n 1 )
mkrig() { "$M" init "$1" "$O" > /dev/null 2>&1; git -C "$T/mh/repos/$1.git" fetch -q origin 2>/dev/null; }   # init + 1º fetch (objetos SOLTOS: poucos para virar pack)
mkrig wa; R=$T/mh/repos/wa.git
( cd "$W" && for i in 4 5 6; do echo "v$i" > "f$i.txt"; git add -A; git commit -qm "c$i"; done; git push -q origin main 2>&1 | tail -n 1 ); git -C "$R" fetch -q origin 2>/dev/null
[ -d "$R" ] && [ "$(loose "$R")" -ge 10 ] && ok "fixture: espelho wa com $(loose "$R") objetos soltos alcançáveis" || bad "fixture: espelho wa sem soltos suficientes ($(loose "$R"))"

# ── init já nasce com o auto-gc desligado ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
[ "$(cfg "$R" gc.auto)" = 0 ] && [ "$(cfg "$R" maintenance.auto)" = false ] && [ "$(cfg "$R" receive.autogc)" = false ] && ok "init: gc.auto=0, maintenance.auto=false, receive.autogc=false" || bad "init não fixou o auto-gc desligado"

# ── o estado de produção: trava órfã + inalcançáveis velhos e novos + o blob do filtro (inalcançável por desenho, só o config guarda o oid) ─────────────────────────────
: > "$R/objects/maintenance.lock"
OLD1=$(mk_unreach "$R" a old); OLD2=$(mk_unreach "$R" b old); OLD3=$(mk_unreach "$R" c old); NEW1=$(mk_unreach "$R" d new); NEW2=$(mk_unreach "$R" e new); NEW3=$(mk_unreach "$R" f new)
FILT=$(mk_unreach "$R" filtro old); git -C "$R" config gtmirror.sparseoid "$FILT"
git -C "$R" config --unset gc.auto; git -C "$R" config --unset maintenance.auto; git -C "$R" config --unset receive.autogc   # o espelho ANTIGO (criado antes desta mudança) não tem o pino
BEFORE=$(loose "$R")

# ── dry-run: conta, não escreve ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
rc_is 0 "dry-run: rc 0" "$M" maint --dry-run wa
has "DRY-RUN" "dry-run: diz que é dry-run"; has "(3 inalcançáveis velhos)" "dry-run: conta os 3 velhos (o blob do filtro NÃO entra: vai de <head>)"
[ "$(loose "$R")" = "$BEFORE" ] && present "$R" "$OLD1" && [ -z "$(cfg "$R" gtmirror.maintokat)" ] && [ -z "$(cfg "$R" gc.auto)" ] && ok "dry-run: nada mudou (objetos, carimbo e config intactos)" || bad "dry-run mexeu no espelho"

# ── portões: pulada (rc 0) ou recusada (rc 1), e nunca um passo rodou ─────────────────────────────────────────────────────────────────────────────────────────────────
: > "$LOG"
rc_is 0 "load alto: pulada, rc 0" env HETZNER_MIRROR_MAINT_LOAD_CMD='echo 99' "$M" maint --force wa; has "pulada — load 99" "load alto: diz o motivo"
rc_is 0 "disco baixo: pulada, rc 0" env HETZNER_MIRROR_MAINT_FREE_CMD='echo 100' "$M" maint --force wa; has "pulada — disco livre 100 MB" "disco baixo: diz o motivo"
rc_is 0 "disco 1 MB abaixo do piso (3072): pulada" env HETZNER_MIRROR_MAINT_FREE_CMD='echo 3071' "$M" maint --force wa; has "pulada — disco livre 3071 MB" "disco no limite: diz o motivo"
rc_is 1 "disco ilegível: RECUSADA, rc 1" env HETZNER_MIRROR_MAINT_FREE_CMD='echo nao-sei' "$M" maint --force wa; has "RECUSADA" "disco ilegível: diz RECUSADA"
rc_is 1 "load ilegível: RECUSADA, rc 1" env HETZNER_MIRROR_MAINT_LOAD_CMD='echo ?' "$M" maint --force wa
rc_is 1 "disco que o comando FALHA: RECUSADA, rc 1" env HETZNER_MIRROR_MAINT_FREE_CMD='exit 3' "$M" maint --force wa
rc_is 1 "validade de poda perigosa (now): RECUSADA" env HETZNER_MIRROR_MAINT_EXPIRE=now "$M" maint --force wa; has "validade de poda perigosa" "validade now: diz por quê"
rc_is 2 "espelho desconhecido: rc 2" "$M" maint nao-existe
if grep -qE ' (repack|prune|prune-packed) ' "$LOG"; then bad "algum passo rodou apesar dos portões" "$(grep -E ' (repack|prune|prune-packed) ' "$LOG" | head -n 3)"; else ok "nenhum passo (prune-packed/repack/prune) rodou com portão fechado"; fi
[ "$(loose "$R")" = "$BEFORE" ] && present "$R" "$OLD1" && ok "portões fechados: espelho intacto" || bad "portão fechado mexeu no espelho"
# a porta de load: o mini vive em 47-64 (medido em 30/10), então o padrão é 80, e não os 40 da bead (que nunca abririam). Só leitura (--dry-run): o LOG acima já provou que portão fechado não roda passo
rc_is 0 "load 79 (< 80, o regime normal do mini é 47-64): passa o portão" env HETZNER_MIRROR_MAINT_LOAD_CMD='echo 79' "$M" maint --dry-run wa; has "DRY-RUN" "load 79: chegou ao dry-run"
rc_is 0 "load 80: pulada (a porta é < 80)" env HETZNER_MIRROR_MAINT_LOAD_CMD='echo 80' "$M" maint --dry-run wa; has "pulada — load 80 ≥ 80" "load 80: diz o motivo"

# ── a rodada de verdade: receita, poda e carimbo ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────
: > "$LOG"
rc_is 0 "maint --force: rc 0" "$M" maint --force wa
has "ANTES soltos=$BEFORE" "log ANTES com a contagem de soltos"; has "DEPOIS soltos=" "log DEPOIS"; has "pico_swap=+0 MB" "log do pico de swap"; has "wa: ok (" "rodada boa"
[ "$(cfg "$R" gc.auto)" = 0 ] && [ "$(cfg "$R" maintenance.auto)" = false ] && [ "$(cfg "$R" receive.autogc)" = false ] && ok "maint refixa o auto-gc desligado no espelho antigo (já na 1ª rodada, mesmo com portão fechado)" || bad "maint não refixou o auto-gc"
REPACK=$(grep ' repack ' "$LOG" | head -n 1)
[[ " $REPACK " == *" -d "* && " $REPACK " == *" -l "* ]] && ok "receita: repack -d -l" || bad "receita: faltou repack -d -l" "$REPACK"   # cada flag casa sozinha: " -d -l " dividiria o espaço entre elas
if printf '%s' " $REPACK " | grep -qE ' (-a|-A|-ad|-Ad|--cruft|--geometric[^ ]*|-b|--write-midx) '; then bad "receita: repack com -a/--cruft/--geometric (pode estourar o swap)" "$REPACK"; else ok "receita: NUNCA -a, --cruft nem --geometric"; fi
case "$REPACK" in *pack.threads=1*pack.windowMemory=64m*) ok "receita: 1 thread e janela de 64m";; *) bad "receita: faltou pack.threads=1/pack.windowMemory=64m" "$REPACK";; esac
grep -q ' prune-packed ' "$LOG" && grep -qE ' prune --expire=2.weeks.ago( |$)' "$LOG" && ok "receita: prune-packed e prune --expire=2.weeks.ago" || bad "receita: faltou prune-packed ou prune --expire" "$(cat "$LOG" | head -n 12)"
if present "$R" "$OLD1" || present "$R" "$OLD2" || present "$R" "$OLD3"; then bad "poda: inalcançável com mais de 2 semanas sobrou"; else ok "poda: os 3 inalcançáveis VELHOS saíram"; fi
present "$R" "$NEW1" && present "$R" "$NEW2" && present "$R" "$NEW3" && ok "poda: os 3 inalcançáveis NOVOS (< 2 semanas) ficaram" || bad "poda: apagou inalcançável com menos de 2 semanas"
present "$R" "$FILT" && ok "poda: o blob do filtro (velho, só no config) ficou" || bad "poda: apagou o blob do filtro"
# rev-list --objects --all é o teste duro (todo objeto alcançável tem de existir). O fsck só entra por palavra de dano real: o init aponta o HEAD do espelho para refs/remotes/origin/main (de propósito) e um git novo acusa
# badHeadTarget por isso (um git mais velho, o do nó Linux, diz "HEAD points to something strange") — não é do maint, e como o id da mensagem nem existe nos mais velhos ele é filtrado do TEXTO em vez de silenciado com -c.
FS=$(git -C "$R" rev-list --objects --all 2>&1 > /dev/null); RLRC=$?
FS="$FS$(git -C "$R" fsck --connectivity-only 2>&1 | grep -E 'missing|broken|corrupt|error|fatal' | grep -v -E 'badHeadTarget|HEAD points to')"
[ $RLRC = 0 ] && [ -z "$FS" ] && ok "o grafo alcançável segue inteiro (rev-list --objects --all e fsck --connectivity-only)" || bad "grafo quebrado depois da rodada" "$FS"
[ "$(loose "$R")" = 4 ] && ok "soltos: só sobraram os 3 novos + o filtro (4), tudo alcançável virou pack" || bad "soltos depois: $(loose "$R"), esperava 4"
[ -f "$R/objects/maintenance.lock" ] && ok "a trava órfã segue lá (a maint NÃO depende dela, e não a apaga)" || bad "a maint apagou a trava órfã"
[[ "$(cfg "$R" gtmirror.maintokat)" =~ ^[0-9]+$ ]] && [ -z "$(cfg "$R" gtmirror.lastmainterror)" ] && ok "carimbo gtmirror.maintokat gravado, sem erro" || bad "carimbo ausente ou erro gravado"
[ ! -e "$R/gtm-fetch.lock" ] && [ ! -e "$R/gtm-maint.mark" ] && ok "a trava do sync foi solta e a marca da rodada removida" || bad "trava do sync ou marca da rodada ficou"

# ── frequência: depois de uma rodada boa, o tique seguinte não faz nada (e diz) ──────────────────────────────────────────────────────────────────────────────────────
: > "$LOG"
rc_is 0 "tique seguinte: rc 0" "$M" maint wa; has "em dia (última rodada boa há): wa(0h)" "tique seguinte: em dia"; hasnt "ANTES" "tique seguinte: não rodou"
grep -qE ' (repack|prune|prune-packed) ' "$LOG" && bad "tique em dia chamou passo" || ok "tique em dia: nenhum passo"
rc_is 0 "--force repete e é idempotente (nada solto a empacotar)" "$M" maint --force wa; has "wa: ok (" "idempotente: segue ok"

# ── trava do sync: dono vivo ⇒ pulada, rc 0 ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
( exec -a hetzner-mirror.sh sleep 40 ) & FAKE_OWNER=$!
mkdir "$R/gtm-fetch.lock" && echo "$FAKE_OWNER" > "$R/gtm-fetch.lock/pid"
: > "$LOG"
rc_is 0 "sync em curso (trava com dono vivo): pulada, rc 0" "$M" maint --force wa; has "pulada — outro sync/maint em curso" "trava: diz o motivo"
grep -qE ' (repack|prune|prune-packed) ' "$LOG" && bad "rodou com a trava do sync tomada" || ok "trava tomada: nenhum passo"
[ -d "$R/gtm-fetch.lock" ] && ok "a trava do OUTRO dono não foi solta pela maint" || bad "a maint soltou a trava de outro"
kill "$FAKE_OWNER" 2>/dev/null; wait "$FAKE_OWNER" 2>/dev/null; FAKE_OWNER=""; rm -rf "$R/gtm-fetch.lock"

# ── prazo: repack lento é CORTADO, sem órfão, sem carimbo ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
OKAT=$(cfg "$R" gtmirror.maintokat)
: > "$R/objects/pack/tmp_pack_OLDONE"; touch -t 202001010000 "$R/objects/pack/tmp_pack_OLDONE"   # um tmp que JÁ existia antes da rodada: não é do passo morto, não pode ser apagado
rc_is 1 "repack além do prazo: rc 1" env HMT_SLEEP=31 HMT_TMPFILE=1 HETZNER_MIRROR_MAINT_TIMEOUT=2 "$M" maint --force wa; has "CORTADO" "prazo: diz CORTADO"
sleep 1; pgrep_sleep && { bad "prazo: sobrou o filho do repack (sleep) rodando"; pkill -f 'sleep 3[12]$' 2>/dev/null; } || ok "prazo: o filho do repack também foi morto (sem órfão)"
[ ! -e "$R/objects/pack/tmp_pack_HMT" ] && ok "prazo: o tmp_pack que o passo morto deixou foi apagado (o git não o apaga no sinal)" || bad "prazo: tmp_pack do passo morto ficou em objects/pack"
[ -e "$R/objects/pack/tmp_pack_OLDONE" ] && ok "prazo: o tmp_pack que já existia antes da rodada NÃO foi tocado" || bad "prazo: apagou tmp_pack que não era do passo morto"
[ ! -e "$R/gtm-maint.mark" ] && ok "prazo: a marca da rodada foi removida" || bad "prazo: a marca gtm-maint.mark ficou"
[ "$(cfg "$R" gtmirror.maintokat)" = "$OKAT" ] && [ -n "$(cfg "$R" gtmirror.lastmainterror)" ] && ok "prazo: carimbo NÃO avançou e o erro ficou gravado" || bad "prazo: carimbo avançou ou erro não gravado"
[ ! -e "$R/gtm-fetch.lock" ] && ok "prazo: a trava do sync foi solta" || bad "prazo: trava ficou"

# ── teto de swap: o swap sobe durante o repack ⇒ PARADO ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
echo 100 > "$SWAPF"
rc_is 1 "swap sobe 2900 MB durante o repack: rc 1" env HMT_SLEEP=32 HMT_TMPFILE=1 HMT_SWAPFILE="$SWAPF" HETZNER_MIRROR_MAINT_SWAP_CMD="cat $SWAPF" "$M" maint --force wa; has "PARADO — o swap subiu 1536 MB" "swap: diz PARADO"
sleep 1; pgrep_sleep && { bad "swap: sobrou o filho do repack"; pkill -f 'sleep 3[12]$' 2>/dev/null; } || ok "swap: o filho do repack também foi morto"
[ ! -e "$R/objects/pack/tmp_pack_HMT" ] && ok "swap: o tmp_pack do passo parado foi apagado" || bad "swap: tmp_pack do passo parado ficou"
echo 100 > "$SWAPF"
rc_is 0 "swap ilegível: a rodada segue CEGA (leitura que não fiz não mata o passo)" env HETZNER_MIRROR_MAINT_SWAP_CMD='echo ?' "$M" maint --force wa; has "swap=? MB" "swap ilegível: o log diz ?"; has "pico_swap=+? MB" "swap ilegível: o pico é ?, não 0"

# ── atraso: portão fechado por muito tempo ⇒ rc 1 (o launchd mostra) ────────────────────────────────────────────────────────────────────────────────────────────────
git -C "$R" config gtmirror.maintokat "$(( $(date +%s) - 100 * 3600 ))"
rc_is 1 "100 h sem rodada boa e o load não deixa: ATRASADA, rc 1" env HETZNER_MIRROR_MAINT_LOAD_CMD='echo 99' "$M" maint wa; has "ATRASADA — sem rodada boa há 100 h" "atraso: diz há quanto"
git -C "$R" config gtmirror.maintokat "$(( $(date +%s) - 3 * 3600 ))"
rc_is 0 "3 h sem rodada e o load não deixa: só pulada (ainda dentro do ciclo, nem é devida)" env HETZNER_MIRROR_MAINT_LOAD_CMD='echo 99' "$M" maint wa

# ── espelho sem ref do origin (1º fetch não veio): nada é "inalcançável" de verdade ⇒ o prune fica de fora ─────────────────────────────────────────────────────────
"$M" init nr "$O" > /dev/null 2>&1; NR=$T/mh/repos/nr.git; ONR=$(mk_unreach "$NR" x old); : > "$LOG"
head -c 3145728 /dev/urandom | git -C "$NR" hash-object -w --stdin > /dev/null   # ~3 MB solto: o portão de disco é piso (3072) + o tamanho dos soltos, não só o piso
rc_is 0 "disco = piso + 1 MB com 3 MB de soltos: pulada (o pack novo pode ter o tamanho deles)" env HETZNER_MIRROR_MAINT_FREE_CMD='echo 3073' "$M" maint --force nr; has "pulada — disco livre 3073 MB < 307" "soltos entram na conta do disco"
rc_is 0 "sem ref do origin: rc 0" "$M" maint --force nr; has "não tem ref do origin" "sem ref: avisa que o prune ficou de fora"
present "$NR" "$ONR" && ok "sem ref: o objeto 'inalcançável' velho NÃO foi apagado (sem ref, tudo parece inalcançável)" || bad "sem ref: apagou objeto de um espelho sem refs"
grep -q ' prune --expire' "$LOG" && bad "sem ref: o prune rodou" || ok "sem ref: nenhum prune"

# um caso que deixa de rodar sem acusar (uma linha comentada por engano, um `&&` que engole o resto) não pode passar por verde: o total é conferido
[ "$N" = "$HMT_EXPECT" ] || bad "casos rodados: $N, esperava $HMT_EXPECT (algum caso sumiu, ou foi acrescentado sem atualizar HMT_EXPECT)"
echo; echo "hetzner-mirror-maint selftest: $((N-F))/$N ok"; [ "$F" = 0 ] && exit 0 || { echo "FAIL=$F"; exit 1; }
