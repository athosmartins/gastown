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

# ── T15 a leitura da lista de ids falha (cat-file --batch-check sai com erro e não diz nada): "não li" reprova e faz rollback; nunca vira "0 ausentes" ──
newfix; printf '#!/bin/sh\ncase "$*" in *"cat-file --batch-check"*) exit 1 ;; esac\nexec git "$@"\n' > "$F/failids"; chmod +x "$F/failids"
objs "$F/w" > "$F/before"
swap JDS_GIT="$F/failids"
check "T15 cat-file dos ids falhou: rc 30 (rollback feito)" "$RC" 30
untouched && ok "T15 rollback: P de volta, nenhum pack novo, sem staging/hold" || bad "T15 rollback restaurou o estado"
objs "$F/w" > "$F/after"; cmp -s "$F/before" "$F/after" && ok "T15 conjunto de objetos igual ao de antes" || bad "T15 conjunto de objetos igual ao de antes"
grep -q "ids-nao-li" "$F/out.txt" && ok "T15 motivo: ids-nao-li" || bad "T15 motivo: ids-nao-li"
grep -q "0 ausentes" "$F/out.txt" && bad "T15 NÃO pode dizer '0 ausentes'" || ok "T15 não diz '0 ausentes'"

# ── T16 NEED_MB ausente no manifesto: segue (a cópia não muda o repo; o vigia de df protege), mas DIZ que não checou ──
newfix; sed -i.bak '/^NEED_MB=/d' "$F/art/manifest.env"
swap; check "T16 sem NEED_MB: rc 0" "$RC" 0
grep -q "AVISO: NEED_MB ausente" "$F/out.txt" && ok "T16 avisa que não pré-checou o espaço" || bad "T16 avisa que não pré-checou o espaço"

# ── T17 o fsck com P escondido reprova (rc != 0, ou rc 0 mas dizendo "missing"): rollback, P de volta ──
newfix; printf '#!/bin/sh\ncase "$*" in *fsck*) echo "missing blob 0123456789abcdef0123456789abcdef01234567"; exit 2 ;; esac\nexec git "$@"\n' > "$F/failfsck"; chmod +x "$F/failfsck"
swap JDS_GIT="$F/failfsck"
check "T17 fsck rc 2: rc 30 (rollback feito)" "$RC" 30
untouched && ok "T17 rollback: P de volta, nenhum pack novo, sem staging/hold" || bad "T17 rollback restaurou o estado"
grep -q "fsck(rc=2)" "$F/out.txt" && ok "T17 motivo: fsck(rc=2)" || bad "T17 motivo: fsck(rc=2)"
newfix; printf '#!/bin/sh\ncase "$*" in *fsck*) echo "missing blob 0123456789abcdef0123456789abcdef01234567"; exit 0 ;; esac\nexec git "$@"\n' > "$F/saysmissing"; chmod +x "$F/saysmissing"
swap JDS_GIT="$F/saysmissing"
check "T17b fsck rc 0 mas diz 'missing': rc 30 (rollback feito)" "$RC" 30
untouched && ok "T17b rollback: P de volta" || bad "T17b rollback: P de volta"

# ── T18 ids.txt é a ÚNICA evidência de conteúdo: vazia, adulterada, ausente ou fora do manifesto reprova NO PASSO 1 (nada muda). Nunca vira "verificado" por falta de lista ──
resum() { ( cd "$F/art" && shasum -a 256 *.pack *.idx *.rev ids.txt > manifest.sha256 2>/dev/null ); }
newfix; : > "$F/art/ids.txt"; resum
swap; check "T18a ids.txt vazio (manifesto refeito p/ bater): rc 24" "$RC" 24; untouched && ok "T18a repo intacto" || bad "T18a repo intacto"
grep -q "ids.txt vazio" "$F/out.txt" && ok "T18a motivo: ids.txt vazio" || bad "T18a motivo: ids.txt vazio"
newfix; echo "0123456789abcdef0123456789abcdef01234567" >> "$F/art/ids.txt"   # manifesto NÃO refeito: o arquivo mudou depois de assinado
swap; check "T18b ids.txt adulterado depois do manifesto: rc 24" "$RC" 24; untouched && ok "T18b repo intacto" || bad "T18b repo intacto"
grep -q "sha256 do ids.txt" "$F/out.txt" && ok "T18b motivo: sha256 do ids.txt" || bad "T18b motivo: sha256 do ids.txt"
newfix; grep -v ' ids.txt$' "$F/art/manifest.sha256" > "$F/art/m2"; mv "$F/art/m2" "$F/art/manifest.sha256"
check "T18c (preparo) manifesto sem a linha do ids.txt" "$(grep -c 'ids.txt' "$F/art/manifest.sha256")" 0
swap; check "T18c ids.txt fora do manifesto: rc 24" "$RC" 24; untouched && ok "T18c repo intacto" || bad "T18c repo intacto"
grep -q "não cobre ids.txt" "$F/out.txt" && ok "T18c motivo: manifesto não cobre ids.txt" || bad "T18c motivo: manifesto não cobre ids.txt"
newfix; rm -f "$F/art/ids.txt"
swap; check "T18d ids.txt ausente na origem: rc 24" "$RC" 24; untouched && ok "T18d repo intacto" || bad "T18d repo intacto"

# ── T19 ids.txt muda DEPOIS do passo 1 (cópia/disco): o passo 9 reconfere o sha256 e REPROVA com rollback — não pula a conferência de conteúdo ──
newfix; printf '#!/bin/sh\nrsync "$@"; rc=$?\ncase "$*" in *manifest.env*) ;; *) for f in "%s"/*/manifest/ids.txt; do : > "$f"; done ;; esac\nexit $rc\n' "$F/state" > "$F/truncids"; chmod +x "$F/truncids"
swap JDS_RSYNC="$F/truncids"
check "T19 ids.txt esvaziado depois do passo 1: rc 30 (rollback feito)" "$RC" 30
untouched && ok "T19 rollback: P de volta, nenhum pack novo, sem staging/hold" || bad "T19 rollback restaurou o estado"
grep -q "ids-mudou" "$F/out.txt" && ok "T19 motivo: ids-mudou" || bad "T19 motivo: ids-mudou"

# ── T20 nenhuma variável de ambiente pula a amostra: JDS_SKIP_FSCK_SAMPLE=1 não muda nada, as 3 leituras acontecem ──
newfix; swap JDS_SKIP_FSCK_SAMPLE=1
check "T20 com JDS_SKIP_FSCK_SAMPLE=1: rc 0" "$RC" 0
check "T20 a amostra (1º, meio, último) foi lida mesmo assim" "$(grep -c '\] amostra [0-9]' "$F/out.txt")" 3

# ── T21 SIGTERM durante a CÓPIA: o rsync em segundo plano morre com o script e o staging NÃO volta (um rsync solto recriaria swap-stage.<pid morto> sem vigia de df) ──
newfix; printf '#!/bin/sh\ncase "$*" in *manifest.env*) exec rsync "$@" ;; esac\necho $$ > "%s"\nsleep 3\nexec rsync "$@"\n' "$F/rsyncpid" > "$F/pidrsync"; chmod +x "$F/pidrsync"
( export JDS_REPO="$F/w" JAC_LOCK="$F/lock" JDS_STATE_DIR="$F/state" JDS_FREE_MB_CMD='echo 9000' JDS_BOOT_EPOCH=2000 JDS_WATCH_S=0.2 JDS_RSYNC="$F/pidrsync"; exec bash "$SWAP" --src "$F/art" --auth-epoch 1000 > "$F/out.txt" 2>&1 ) & SP=$!
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do [ -s "$F/rsyncpid" ] && break; sleep 0.25; done
[ -s "$F/rsyncpid" ] && ok "T21 (preparo) a cópia começou" || bad "T21 (preparo) a cópia começou"
kill -TERM "$SP" 2>/dev/null; wait "$SP" 2>/dev/null; RC=$?
check "T21 SIGTERM durante a cópia: rc 143" "$RC" 143
kill -0 "$(cat "$F/rsyncpid" 2>/dev/null)" 2>/dev/null && bad "T21 o processo da cópia segue vivo" || ok "T21 o processo da cópia morreu junto"
sleep 4   # o shim acordaria em 3 s e o rsync recriaria o staging se estivesse solto
untouched && ok "T21 sem swap-stage depois que o rsync solto teria acordado; repo intacto" || bad "T21 sem swap-stage; repo intacto"
[ ! -d "$F/lock" ] && ok "T21 lock liberado" || bad "T21 lock liberado"

# ── T22 o rollback NÃO pode dizer "feito" quando o .idx de P não voltou (hold sumiu): P' e N ficam (são a única cópia legível), rc 31, log ALTO ──
newfix; printf '#!/bin/sh\ncase "$*" in *fsck*) rm -f "%s"/.git/objects/pack/*.idx.swap-hold; echo "error: simulado"; exit 2 ;; esac\nexec git "$@"\n' "$F/w" > "$F/losthold"; chmod +x "$F/losthold"
objs "$F/w" > "$F/before"
swap JDS_GIT="$F/losthold"
check "T22 rollback sem o .idx de P: rc 31 (NÃO 30)" "$RC" 31
grep -q "ROLLBACK FALHOU" "$F/out.txt" && ok "T22 log: ROLLBACK FALHOU" || bad "T22 log: ROLLBACK FALHOU"
grep -q "status=ROLLBACK-FALHOU" "$F/out.txt" && ok "T22 RESULT: ROLLBACK-FALHOU" || bad "T22 RESULT: ROLLBACK-FALHOU"
grep -q "ROLLBACK: feito" "$F/out.txt" && bad "T22 NÃO pode dizer 'ROLLBACK: feito'" || ok "T22 não diz 'ROLLBACK: feito'"
check "T22 P' e N seguem instalados (3 .pack: P sem .idx + P' + N)" "$(ls "$F/w/.git/objects/pack" | grep -c '\.pack$')" 3
objs "$F/w" > "$F/after"; cmp -s "$F/before" "$F/after" && ok "T22 todos os objetos seguem legíveis (via P' e N)" || bad "T22 todos os objetos seguem legíveis"

# ── T23 `comm` que FALHA não vira "sumiram 0": reprova com rollback (objetos e alcançáveis, cada um) ──
newfix; mkdir -p "$F/bin"; printf '#!/bin/sh\nexit 2\n' > "$F/bin/comm"; chmod +x "$F/bin/comm"
swap "PATH=$F/bin:$PATH"
check "T23a comm falha (objetos): rc 30 (rollback feito)" "$RC" 30; untouched && ok "T23a rollback: P de volta" || bad "T23a rollback: P de volta"
grep -q "comm-objetos-falhou" "$F/out.txt" && ok "T23a motivo: comm-objetos-falhou" || bad "T23a motivo: comm-objetos-falhou"
grep -q "sumiram 0" "$F/out.txt" && bad "T23a NÃO pode dizer 'sumiram 0'" || ok "T23a não diz 'sumiram 0'"
newfix; mkdir -p "$F/bin"; echo 0 > "$F/cn"; REALCOMM="$(command -v comm)"
printf '#!/bin/sh\nn=$(cat "%s"); echo $((n+1)) > "%s"\nif [ "$n" -ge 1 ]; then exit 2; fi\nexec "%s" "$@"\n' "$F/cn" "$F/cn" "$REALCOMM" > "$F/bin/comm"; chmod +x "$F/bin/comm"
swap "PATH=$F/bin:$PATH"
check "T23b comm falha (alcançáveis, 2ª chamada): rc 30 (rollback feito)" "$RC" 30; untouched && ok "T23b rollback: P de volta" || bad "T23b rollback: P de volta"
grep -q "comm-alcancaveis-falhou" "$F/out.txt" && ok "T23b motivo: comm-alcancaveis-falhou" || bad "T23b motivo: comm-alcancaveis-falhou"

# ── T24..T26 cada conferência do passo 9 PRECISA conseguir reprovar sozinha (mutantes: neutralizar uma e o teste correspondente tem de cair) ──
# T24 alcançáveis: o 2º `rev-list --objects --all` (depois) perde uma linha; os objetos em si estão todos lá
newfix; echo 0 > "$F/rl"
printf '#!/bin/sh\ncase "$*" in *"rev-list --objects --all"*) n=$(cat "%s"); echo $((n+1)) > "%s"; if [ "$n" -ge 1 ]; then git "$@" | tail -n +2; exit 0; fi ;; esac\nexec git "$@"\n' "$F/rl" "$F/rl" > "$F/dropreach"; chmod +x "$F/dropreach"
swap JDS_GIT="$F/dropreach"
check "T24 alcançáveis perdem 1: rc 30 (rollback feito)" "$RC" 30; untouched && ok "T24 rollback: P de volta" || bad "T24 rollback: P de volta"
grep -q "alcancaveis-sumiram(1)" "$F/out.txt" && ok "T24 motivo: alcancaveis-sumiram(1)" || bad "T24 motivo: alcancaveis-sumiram(1)"
# T25 commits: o 2º `rev-list --all --count` devolve um a menos
newfix; echo 0 > "$F/rc2"
printf '#!/bin/sh\ncase "$*" in *"rev-list --all --count"*) n=$(cat "%s"); echo $((n+1)) > "%s"; if [ "$n" -ge 1 ]; then c=$(git "$@"); echo $((c-1)); exit 0; fi ;; esac\nexec git "$@"\n' "$F/rc2" "$F/rc2" > "$F/dropcommit"; chmod +x "$F/dropcommit"
swap JDS_GIT="$F/dropcommit"
check "T25 commits caem 1: rc 30 (rollback feito)" "$RC" 30; untouched && ok "T25 rollback: P de volta" || bad "T25 rollback: P de volta"
grep -q "commits(" "$F/out.txt" && ok "T25 motivo: commits(...)" || bad "T25 motivo: commits(...)"
# T26 amostra: `cat-file blob` devolve só 5 bytes (o tamanho declarado é o verdadeiro)
newfix; printf '#!/bin/sh\ncase "$*" in *"cat-file blob"*) git "$@" | head -c 5; exit 0 ;; esac\nexec git "$@"\n' > "$F/shortblob"; chmod +x "$F/shortblob"
swap JDS_GIT="$F/shortblob"
check "T26 amostra lida pela metade: rc 30 (rollback feito)" "$RC" 30; untouched && ok "T26 rollback: P de volta" || bad "T26 rollback: P de volta"
grep -q "amostra(" "$F/out.txt" && ok "T26 motivo: amostra(...)" || bad "T26 motivo: amostra(...)"
# T26b amostra: `cat-file blob` entrega TODOS os bytes e sai com erro (rc 1) — só o rc pega (o tamanho bate)
newfix; printf '#!/bin/sh\ncase "$*" in *"cat-file blob"*) git "$@"; exit 1 ;; esac\nexec git "$@"\n' > "$F/blobrc"; chmod +x "$F/blobrc"
swap JDS_GIT="$F/blobrc"
check "T26b amostra lida inteira mas com rc 1: rc 30 (rollback feito)" "$RC" 30; untouched && ok "T26b rollback: P de volta" || bad "T26b rollback: P de volta"
grep -q "amostra(.*rc=1)" "$F/out.txt" && ok "T26b motivo: amostra(...rc=1)" || bad "T26b motivo: amostra(...rc=1)"
# T27 ids.txt (assinado no manifesto) com um id que não existe no repo: ids-ausentes(1)
newfix; echo "0123456789abcdef0123456789abcdef01234567" >> "$F/art/ids.txt"; resum
swap; check "T27 id da lista ausente do repo: rc 30 (rollback feito)" "$RC" 30; untouched && ok "T27 rollback: P de volta" || bad "T27 rollback: P de volta"
grep -q "ids-ausentes(1)" "$F/out.txt" && ok "T27 motivo: ids-ausentes(1)" || bad "T27 motivo: ids-ausentes(1)"

# ── T28 `mv` que falha durante a instalação / ao esconder P: rollback pelo on_exit (nada de pack órfão que faria a próxima execução abortar 24 'já existe') ──
newfix; mkdir -p "$F/bin"
printf '#!/bin/sh\nfor a; do last="$a"; done\ncase "$last" in */%s.idx) ;; */objects/pack/pack-*.idx) echo "mv: simulado" >&2; exit 1 ;; esac\nexec /bin/mv "$@"\n' "$P" > "$F/bin/mv"; chmod +x "$F/bin/mv"
swap "PATH=$F/bin:$PATH"
check "T28a mv do .idx do P' falha (depois do .pack e do .rev): rc 24" "$RC" 24
untouched && ok "T28a rollback tirou o .pack/.rev órfãos; P de volta" || bad "T28a rollback tirou o .pack/.rev órfãos"
newfix; mkdir -p "$F/bin"; printf '#!/bin/sh\nfor a; do last="$a"; done\ncase "$last" in *.swap-hold) echo "mv: simulado" >&2; exit 1 ;; esac\nexec /bin/mv "$@"\n' > "$F/bin/mv"; chmod +x "$F/bin/mv"
swap "PATH=$F/bin:$PATH"
check "T28b mv que esconde o .idx de P falha: rc 30 (rollback feito)" "$RC" 30
untouched && ok "T28b rollback: P' e N removidos, P visível" || bad "T28b rollback: P' e N removidos, P visível"

# ── T29 --recover também remove o staging de uma execução morta sem sinal tratável (SIGKILL) — e só de PID morto ──
newfix; sleep 0 & DP=$!; wait "$DP" 2>/dev/null
mkdir "$F/w/.git/swap-stage.$DP"; : > "$F/w/.git/swap-stage.$DP/new.pack"; mv "$F/w/.git/objects/pack/$P.idx" "$F/w/.git/objects/pack/$P.idx.swap-hold"
swap -- --recover; check "T29a --recover (hold + staging de PID morto): rc 0" "$RC" 0
[ -s "$F/w/.git/objects/pack/$P.idx" ] && [ ! -e "$F/w/.git/objects/pack/$P.idx.swap-hold" ] && ok "T29a .idx devolvido" || bad "T29a .idx devolvido"
[ ! -e "$F/w/.git/swap-stage.$DP" ] && ok "T29a staging de PID morto removido" || bad "T29a staging de PID morto removido"
swap -- --recover; check "T29b de novo, sem nada: rc 50" "$RC" 50
newfix; sleep 30 & LP=$!; mkdir "$F/w/.git/swap-stage.$LP"; echo x > "$F/w/.git/swap-stage.$LP/new.pack"
swap -- --recover; check "T29c staging de PID VIVO: nada a recuperar, rc 50" "$RC" 50
[ -s "$F/w/.git/swap-stage.$LP/new.pack" ] && ok "T29c staging de PID vivo NÃO foi tocado" || bad "T29c staging de PID vivo NÃO foi tocado"
kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
newfix; mkdir "$F/w/.git/swap-stage.abc"
swap -- --recover; check "T29d staging com nome sem PID legível: não toco, rc 50" "$RC" 50
[ -d "$F/w/.git/swap-stage.abc" ] && ok "T29d staging sem PID legível NÃO foi tocado" || bad "T29d staging sem PID legível NÃO foi tocado"

echo "---"; echo "passou $PASS, falhou $FAIL"
[ "$FAIL" -eq 0 ]
