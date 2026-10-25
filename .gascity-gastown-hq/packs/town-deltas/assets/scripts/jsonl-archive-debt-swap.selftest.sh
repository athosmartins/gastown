#!/bin/bash
# jsonl-archive-debt-swap.selftest.sh (ga-36r6xq) — repositórios sintéticos de KBs; nada toca o arquivo real.
# Cada cenário parte de um clone novo de uma base: um pack P com versões de wa/comments.jsonl (os objetos S) e de hq/comments.jsonl; artefatos P' (P sem S) e N (S re-deltificado).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SWAP="$HERE/jsonl-archive-debt-swap.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/jds-selftest.XXXXXX")" || exit 2
trap 'cd /; case "$T" in /tmp/jds-selftest.*|/private/tmp/*/jds-selftest.*|/var/folders/*/jds-selftest.*) find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null ;; esac' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (esperava '$3', veio '$2')"; fi; }
sh_() { git --git-dir="$1/.git" "${@:2}"; }

# ── base: repo com P, artefatos ──
BASE="$T/base"; mkdir -p "$BASE/w" "$BASE/art"
git init -q "$BASE/w" && git -C "$BASE/w" config gc.auto 0
python3 -I - "$BASE/w" <<'EOF'
import os, random, subprocess, sys
r = sys.argv[1]; random.seed(3)
def row(t, i): return f'{{"{t}":{i},"x":"{"".join(random.choice("abcdefgh ") for _ in range(60))}"}}\n'
hq = [row("hq", i) for i in range(4000)]; wa = [hq[random.randrange(4000)] for _ in range(1500)] + [row("wa", i) for i in range(1500)]
os.makedirs(r + "/hq"); os.makedirs(r + "/wa")
for v in range(4):
    hq += [row("hq", 5000 + v * 10 + j) for j in range(10)]; wa += [row("wa", 7000 + v * 10 + j) for j in range(10)]
    open(r + "/hq/comments.jsonl", "w").writelines(hq); open(r + "/wa/comments.jsonl", "w").writelines(wa)
    subprocess.run(["git", "-C", r, "add", "-A"], check=True); subprocess.run(["git", "-C", r, "commit", "-q", "-m", f"v{v}"], check=True)
EOF
git -C "$BASE/w" repack -q -a -d -f --window=10 --depth=50
P="$(basename "$(ls "$BASE"/w/.git/objects/pack/*.pack)" .pack)"
# S = as 4 versões do wa/comments.jsonl
git -C "$BASE/w" rev-list --objects --all | awk '$2=="wa/comments.jsonl" {print $1}' | sort -u > "$BASE/S.ids"
[ "$(wc -l < "$BASE/S.ids" | tr -d ' ')" = 4 ] || { echo "base: esperava 4 versões do WA"; exit 2; }
CK="$(tail -c 40 "$BASE/w/.git/objects/pack/$P.idx" | head -c 20 | od -An -tx1 | tr -d ' \n')"
make_art() {  # make_art <dir> [omitir-um-id-do-P'] — constrói N e P' num clone; 2º argumento = um id que P' deixa de ter (cenário "objeto sumiu")
  local d="$1" omit="${2:-}" c="$1.build"
  mkdir -p "$d"; cp -R "$BASE/w" "$c"
  git -C "$c" pack-objects -q "$d/new" < "$BASE/S.ids" > "$d/new.hash"
  cp "$d"/new-*.pack "$d"/new-*.idx "$c/.git/objects/pack/"; [ -e "$d"/new-*.rev ] && cp "$d"/new-*.rev "$c/.git/objects/pack/"
  NP="$(basename "$(ls "$d"/new-*.pack)" .pack)"
  if [ -n "$omit" ]; then
    git -C "$c" show-index < "$c/.git/objects/pack/$P.idx" | awk '{print $2}' | sort > "$d/p.ids"
    sort "$BASE/S.ids" > "$d/s.sorted"; comm -23 "$d/p.ids" "$d/s.sorted" | grep -v "^$omit\$" | git -C "$c" pack-objects -q "$d/pprime" > "$d/pprime.hash"
  else
    printf '%s.pack\n^%s.pack\n' "$P" "$NP" | git -C "$c" pack-objects --stdin-packs -q "$d/pprime" > "$d/pprime.hash"
  fi
  PP="$(basename "$(ls "$d"/pprime-*.pack)" .pack)"
  cp "$BASE/S.ids" "$d/ids.txt"
  ( cd "$d" && shasum -a 256 *.pack *.idx *.rev ids.txt > manifest.sha256 2>/dev/null )
  { echo "OLD_PACK=$P"; echo "OLD_CHECKSUM=$CK"; echo "NEW_PACKS=\"$PP $NP\""; echo "IDS=ids.txt"; echo "NEED_MB=1"; } > "$d/manifest.env"
  find "$c" -mindepth 1 -delete; rmdir "$c"
}
make_art "$BASE/art"
# um objeto que vive em P e NÃO em S (para o cenário "objeto sumiu")
OMIT="$(git -C "$BASE/w" rev-list --objects --all | awk '$2=="hq/comments.jsonl" {print $1}' | head -1)"
make_art "$BASE/art-omit" "$OMIT"

n=0
newfix() {  # newfix → imprime o diretório do cenário (repo + artefatos próprios), com ambiente padrão em $F
  n=$((n + 1)); F="$T/f$n"; mkdir -p "$F"; cp -R "$BASE/w" "$F/w"; cp -R "$BASE/art" "$F/art"; mkdir -p "$F/state"
}
swap() {  # swap [env VAR=val ...] -- args extras
  ( export JDS_REPO="$F/w" JAC_LOCK="$F/lock" JDS_STATE_DIR="$F/state" JDS_FREE_MB_CMD='echo 9000' JDS_BOOT_EPOCH=2000 JDS_WATCH_S=0.2 JDS_MIN_START_MB=5500 JDS_FLOOR_MB=3400
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do export "$1"; shift; done; [ "${1:-}" = "--" ] && shift
    bash "$SWAP" --src "${SRC_OVERRIDE:-$F/art}" --auth-epoch 1000 "$@" > "$F/out.txt" 2>&1 )
  RC=$?
}
objs() { sh_ "$1" cat-file --batch-all-objects --batch-check='%(objectname)' | sort; }
packs() { ls "$1/.git/objects/pack" | grep -c '\.pack$'; }
untouched() {  # o repo ficou como antes: P presente com idx, nenhum pack novo, sem staging, sem hold
  [ -s "$F/w/.git/objects/pack/$P.idx" ] && [ -s "$F/w/.git/objects/pack/$P.pack" ] && [ "$(packs "$F/w")" = 1 ] && [ -z "$(ls "$F/w/.git" | grep swap-stage)" ] && [ -z "$(ls "$F/w/.git/objects/pack" | grep swap-hold)" ]
}

# ── T1 sucesso ──
newfix; objs "$F/w" > "$F/before"; CB="$(sh_ "$F/w" rev-list --all --count)"
swap
check "T1 sucesso: rc 0" "$RC" 0
[ ! -e "$F/w/.git/objects/pack/$P.pack" ] && ok "T1 P apagado" || bad "T1 P apagado"
check "T1 sobraram P' e N como pack-*" "$(ls "$F/w/.git/objects/pack" | grep -c '^pack-.*\.pack$')" 2
objs "$F/w" > "$F/after"; cmp -s "$F/before" "$F/after" && ok "T1 mesmo conjunto de objetos" || bad "T1 mesmo conjunto de objetos"
check "T1 mesmos commits" "$(sh_ "$F/w" rev-list --all --count)" "$CB"
sh_ "$F/w" fsck --full --no-dangling >/dev/null 2>&1 && ok "T1 git fsck --full ok" || bad "T1 git fsck --full ok"
[ ! -e "$F/lock" ] && ok "T1 lock liberado" || bad "T1 lock liberado"
grep -q "RESULT_DEBT_SWAP status=ok" "$F/out.txt" && ok "T1 linha RESULT" || bad "T1 linha RESULT"
# T12 reexecução depois de trocado
swap; check "T12 já trocado: rc 27" "$RC" 27

# ── T2/T3 df ──
newfix; swap JDS_FREE_MB_CMD='echo 5000'; check "T2 df baixo: rc 20" "$RC" 20; untouched && ok "T2 repo intacto" || bad "T2 repo intacto"
newfix; swap JDS_FREE_MB_CMD='true'; check "T3 df ilegível: rc 20 (ilegível não é 'tem espaço')" "$RC" 20; untouched && ok "T3 repo intacto" || bad "T3 repo intacto"
newfix; swap JDS_FREE_MB_CMD='echo 5499'; check "T2b df 5499 < 5500: rc 20" "$RC" 20
newfix; swap JDS_FREE_MB_CMD='echo 4000' JDS_MIN_START_MB=1 JDS_FLOOR_MB=3999 JDS_X=1; : # NEED_MB=1: 4000-1 >= 3999 passa
check "T2c df-NEED >= piso passa: rc 0" "$RC" 0
newfix; swap JDS_FREE_MB_CMD='echo 4000' JDS_MIN_START_MB=1 JDS_FLOOR_MB=4000; check "T2d df-NEED < piso: rc 20" "$RC" 20; untouched && ok "T2d repo intacto" || bad "T2d repo intacto"

# ── T4 reboot ──
newfix; swap JDS_BOOT_EPOCH=1000; check "T4 boot == autorização: rc 20" "$RC" 20; untouched && ok "T4 repo intacto" || bad "T4 repo intacto"
newfix; swap JDS_BOOT_EPOCH=abc; check "T4b boot ilegível (não numérico): rc 20" "$RC" 20
# T4c/T4d: o parser REAL do kern.boottime (sem JDS_BOOT_EPOCH), com um sysctl de mentira no formato verdadeiro "{ sec = S, usec = U } <data>".
# Em 24/10 o sed pegava o "sec = " de dentro de "usec = " e devolvia os microssegundos (boot=501464): a troca nunca começava. Os dois sentidos têm de ser pegos:
#   T4c sec > autorização, usec < autorização → tem de PASSAR (o parser velho lia o usec e dava rc 20)
#   T4d sec < autorização, usec > autorização → tem de RECUSAR (o parser velho lia o usec e deixava passar um mini que NÃO reiniciou depois da autorização)
newfix; mkdir -p "$F/bin"; printf '#!/bin/sh\necho "{ sec = 3000, usec = 500 } Sat Oct 24 22:40:43 2026"\n' > "$F/bin/sysctl"; chmod +x "$F/bin/sysctl"
swap JDS_BOOT_EPOCH= "PATH=$F/bin:$PATH"; check "T4c boot real sec=3000 usec=500 (> autorização 1000): rc 0" "$RC" 0
newfix; mkdir -p "$F/bin"; printf '#!/bin/sh\necho "{ sec = 900, usec = 999999 } Sat Oct 24 22:40:43 2026"\n' > "$F/bin/sysctl"; chmod +x "$F/bin/sysctl"
swap JDS_BOOT_EPOCH= "PATH=$F/bin:$PATH"; check "T4d boot real sec=900 usec=999999 (< autorização 1000): rc 20" "$RC" 20; untouched && ok "T4d repo intacto" || bad "T4d repo intacto"
# T4e: o parser real com sysctl mudo (nada) e com formato que não casa → vazio → rc 20 (ilegível nunca passa por "reiniciou")
newfix; mkdir -p "$F/bin"; printf '#!/bin/sh\nexit 1\n' > "$F/bin/sysctl"; chmod +x "$F/bin/sysctl"
swap JDS_BOOT_EPOCH= "PATH=$F/bin:$PATH"; check "T4e sysctl falhou/mudo: rc 20" "$RC" 20; untouched && ok "T4e repo intacto" || bad "T4e repo intacto"
newfix; mkdir -p "$F/bin"; printf '#!/bin/sh\necho "usec = 99999999 sec = 99999999"\n' > "$F/bin/sysctl"; chmod +x "$F/bin/sysctl"
swap JDS_BOOT_EPOCH= "PATH=$F/bin:$PATH"; check "T4e formato que não casa (sem '{ sec ='): rc 20" "$RC" 20; untouched && ok "T4e' repo intacto" || bad "T4e' repo intacto"

# ── T5 lock em uso ──
newfix; sleep 30 & SP=$!; mkdir "$F/lock"; echo "$SP" > "$F/lock/pid"
swap; check "T5 lock com dono vivo: rc 21" "$RC" 21; untouched && ok "T5 repo intacto" || bad "T5 repo intacto"; kill "$SP" 2>/dev/null; wait "$SP" 2>/dev/null
[ -d "$F/lock" ] && ok "T5 lock do outro NÃO foi removido" || bad "T5 lock do outro NÃO foi removido"
# lock obsoleto (dono morto, mais velho que 1 min) é reivindicado
newfix; mkdir "$F/lock"; echo 99999 > "$F/lock/pid"; touch -t 202001010000 "$F/lock"
swap; check "T5b lock obsoleto reivindicado: rc 0" "$RC" 0
# dono morto mas recente (< 1 min) = em uso (dúvida = em uso)
newfix; mkdir "$F/lock"; echo 99999 > "$F/lock/pid"
swap; check "T5c lock recente de dono morto: rc 21" "$RC" 21

# ── T6 outro repacker no repo ──
newfix; mkdir -p "$F/fakebin"; printf '#!/bin/sh\nsleep 30\n' > "$F/fakebin/git"; chmod +x "$F/fakebin/git"
( cd "$F/w" && exec "$F/fakebin/git" repack ) & RP=$!; sleep 1
swap; check "T6 repack rodando no repo: rc 22" "$RC" 22; untouched && ok "T6 repo intacto" || bad "T6 repo intacto"; kill "$RP" 2>/dev/null; wait "$RP" 2>/dev/null
[ ! -d "$F/lock" ] && ok "T6 lock liberado" || bad "T6 lock liberado"

# ── T7 identidade do P ──
newfix; sed -i.bak 's/^OLD_CHECKSUM=.*/OLD_CHECKSUM=0000000000000000000000000000000000000000/' "$F/art/manifest.env"
swap; check "T7 checksum de P difere: rc 23" "$RC" 23; untouched && ok "T7 repo intacto" || bad "T7 repo intacto"

# ── T8 cópia corrompida ──
newfix; f="$(ls "$F"/art/pprime-*.pack)"; chmod u+w "$f"; printf 'X' | dd of="$f" bs=1 seek=100 conv=notrunc 2>/dev/null
swap; check "T8 sha256 não confere: rc 24" "$RC" 24; untouched && ok "T8 repo intacto" || bad "T8 repo intacto"

# ── T9 objeto some do P' (manifesto correto, conteúdo errado): a verificação COM P ESCONDIDO pega e faz rollback ──
newfix; find "$F/art" -mindepth 1 -delete; rmdir "$F/art"; cp -R "$BASE/art-omit" "$F/art"
objs "$F/w" > "$F/before"
swap
check "T9 objeto faltando: rc 30 (rollback feito)" "$RC" 30
untouched && ok "T9 rollback: P de volta, nenhum pack novo, sem staging/hold" || bad "T9 rollback restaurou o estado"
objs "$F/w" > "$F/after"; cmp -s "$F/before" "$F/after" && ok "T9 conjunto de objetos igual ao de antes" || bad "T9 conjunto de objetos igual ao de antes"
sh_ "$F/w" fsck --full --no-dangling >/dev/null 2>&1 && ok "T9 fsck --full ok depois do rollback" || bad "T9 fsck --full ok depois do rollback"
grep -q "objetos-sumiram" "$F/out.txt" && ok "T9 motivo: objetos-sumiram" || bad "T9 motivo: objetos-sumiram"

# ── T10 hold sobrando / recover ──
newfix; mv "$F/w/.git/objects/pack/$P.idx" "$F/w/.git/objects/pack/$P.idx.swap-hold"
swap; check "T10 hold de troca interrompida: rc 20" "$RC" 20
swap -- --recover; check "T10b --recover: rc 0" "$RC" 0
[ -s "$F/w/.git/objects/pack/$P.idx" ] && [ ! -e "$F/w/.git/objects/pack/$P.idx.swap-hold" ] && ok "T10b .idx devolvido" || bad "T10b .idx devolvido"
swap -- --recover; check "T10c --recover sem hold: rc 50" "$RC" 50

# ── T11 multi-pack-index ──
newfix; : > "$F/w/.git/objects/pack/multi-pack-index"
swap; check "T11 multi-pack-index: rc 26" "$RC" 26

# ── T13 vigia de df durante a cópia ──
newfix; printf '#!/bin/sh\nsleep 3\nexec rsync "$@"\n' > "$F/slowrsync"; chmod +x "$F/slowrsync"
echo 0 > "$F/cnt"; printf '#!/bin/sh\nn=$(cat "%s"); echo $((n+1)) > "%s"; if [ "$n" -lt 3 ]; then echo 9000; else echo 3000; fi\n' "$F/cnt" "$F/cnt" > "$F/freecmd"; chmod +x "$F/freecmd"
swap JDS_RSYNC="$F/slowrsync" JDS_FREE_MB_CMD="$F/freecmd"
check "T13 vigia de df: rc 25" "$RC" 25; untouched && ok "T13 repo intacto, staging removido" || bad "T13 repo intacto, staging removido"

# ── T14 sinal com o .idx escondido: rollback ──
newfix; printf '#!/bin/sh\ncase "$*" in *fsck*) sleep 8;; esac\nexec git "$@"\n' > "$F/slowgit"; chmod +x "$F/slowgit"
( export JDS_REPO="$F/w" JAC_LOCK="$F/lock" JDS_STATE_DIR="$F/state" JDS_FREE_MB_CMD='echo 9000' JDS_BOOT_EPOCH=2000 JDS_GIT="$F/slowgit"; exec bash "$SWAP" --src "$F/art" --auth-epoch 1000 > "$F/out.txt" 2>&1 ) & SP=$!
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do ls "$F/w/.git/objects/pack" 2>/dev/null | grep -q 'swap-hold' && break; sleep 0.5; done
sleep 1; kill -TERM "$SP" 2>/dev/null; wait "$SP" 2>/dev/null; RC=$?
check "T14 SIGTERM com P escondido: rc 143" "$RC" 143
untouched && ok "T14 rollback no sinal: estado de antes" || bad "T14 rollback no sinal: estado de antes"

echo "---"; echo "passou $PASS, falhou $FAIL"
[ "$FAIL" -eq 0 ]
