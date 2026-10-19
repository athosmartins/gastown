#!/bin/bash
# hetzner-mirror.selftest.sh — hermético: tudo em mktemp, sshd próprio em loopback numa porta aleatória, "GitHub" = um bare local, "servidor" = outro HOME. Não toca ~/.ssh, os espelhos
# reais, o GitHub nem a rede. Cobre hetzner-mirror.sh + hetzner-mirror-scan.py + hetzner-remote-git.sh (ga-2hd02v.1.3).
# Leva de 2 a 10 min conforme a carga. HMST_FAKE=1 troca o ssh por chamada direta ao `serve` (pula só os casos do sshd real); HMST_KEEP=1 guarda o tmp. O veredito que vale é a rodada SEM HMST_FAKE.
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P); M=$HERE/hetzner-mirror.sh; R=$HERE/hetzner-remote-git.sh; SC=$HERE/hetzner-mirror-scan.py
T=$(mktemp -d "${TMPDIR:-/tmp}/hmst.XXXXXX"); T=$(cd "$T" && pwd -P); chmod 700 "$T"; N=0; F=0   # pwd -P: o mini grava o caminho RESOLVIDO (macOS: /var → /private/var); sem isto o caso 'authorize: troca de linha' reprova com o TMPDIR padrão
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_TERMINAL_PROMPT=0
export HETZNER_MIRROR_HOME=$T/mh HETZNER_MIRROR_ALLOW_WORKTREE=1 HETZNER_MIRROR_STRICTMODES=no GT_REMOTE_NOMUX=1 GT_REMOTE_GIT=$T/srv/git HETZNER_MIRROR_PUBLISH_WAIT=5
export HETZNER_MIRROR_PORT; HETZNER_MIRROR_PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
SRV_HOME=$T/srvhome; mkdir -p "$SRV_HOME/.ssh" "$T/srv"; FAKE=${HMST_FAKE:-}
ok() { N=$((N+1)); echo "ok   $N - $1"; }
bad() { N=$((N+1)); F=$((F+1)); echo "FAIL $N - $1"; [ -z "${2:-}" ] || echo "     $2" | head -n 6; return 0; }   # sempre 0: `A && bad .. || ok ..` contava o caso duas vezes quando bad vinha sem evidência
cleanup() { "$M" sshd stop > /dev/null 2>&1; [ -n "${HMST_KEEP:-}" ] && echo "(mantido: $T)" || rm -rf "$T"; }; trap cleanup EXIT
rc_is() { local want=$1 desc=$2; shift 2; OUT=$("$@" 2>&1); local got=$?; [ "$got" = "$want" ] && ok "$desc" || bad "$desc (rc=$got, queria $want)" "$OUT"; }
has() { printf '%s' "$OUT" | grep -qF -- "$1" && ok "$2" || bad "$2 (faltou: $1)" "$OUT"; }
hasnt() { printf '%s' "$OUT" | grep -qF -- "$1" && bad "$2 (apareceu: $1)" "$OUT" || ok "$2"; }
srv() { env -u GH_TOKEN -u GITHUB_TOKEN HOME=$SRV_HOME "$R" "$@"; }
wait_for() { local i=0; while [ $i -lt "$1" ]; do eval "$2" && return 0; sleep 1; i=$((i+1)); done; return 1; }
gx() { git -C "$1" "${@:2}"; }
phones() { local i; for i in $(seq 1 "$1"); do printf '+55 31 9%04d-%04d\n' $((1000 + i * 37)) $((2000 + i * 91)); done; }
if [ -n "$FAKE" ]; then   # o "ssh" do servidor chama o `serve` do mini direto: mesmas regras de comando forçado, sem sshd
  cat > "$T/fakessh" <<EOF
#!/bin/sh
for last; do :; done
exec env SSH_ORIGINAL_COMMAND="\$last" HETZNER_MIRROR_HOME=$T/mh "$M" serve
EOF
  chmod 755 "$T/fakessh"; export GT_REMOTE_SSH=$T/fakessh GIT_SSH_VARIANT=ssh   # o git adivinha a variante pelo NOME do comando; sem isto vira 'simple' e recusa -p
fi

# ── fixture: "GitHub" com dado de todo tipo no histórico; um clone de trabalho (seed) com branch local que NÃO pode vazar ─────────────────────────────────────────────────────────
O=$T/origin.git; W=$T/work; git init -q --bare "$O"; git clone -q "$O" "$W" 2>/dev/null
( cd "$W" && mkdir -p lib docs/notes auth src scripts .beads/backup data && echo 'print(1)' > lib/a.py && echo 'DATA-MARK leads' > docs/leads.csv && echo 'DATA-MARK sql' > lib/g.db && echo 'DATA-MARK env' > .env && echo 'DATA-MARK auth' > auth/k.py && echo ok > src/token_helper.py && printf '\211PNG\r\n\032\n\0DATA-MARK png\n' > docs/shot.png \
  && echo '{"a":"DATA-MARK bead"}' > .beads/backup/b.jsonl && echo 'DATA-MARK data' > data/x.txt && { phones 30; echo 'DATA-MARK ab'; } > docs/notes/ab_results.json && { echo '# DATA-MARK gen'; echo 'NUMS = ['; phones 25 | sed 's/.*/  "&",/'; echo ']'; } > scripts/gen.py \
  && phones 5 > docs/notes/small.json && echo '# readme' > docs/README.md && echo 'same-bytes-dupe' > docs/dupe.txt && echo 'same-bytes-dupe' > .beads/backup/dupe.txt \
  && git add -A && git commit -qm c1 && git rm -q docs/leads.csv && echo 'print(2)' >> lib/a.py && git commit -qam c2 \
  && git mv docs/notes/ab_results.json docs/notes/renamed_results.json && git commit -qm c3-rename && git branch -M main && git push -q origin main 2>&1 | tail -n 1
  git checkout -q -b feat/x && echo x > lib/x.py && git add -A && git commit -qm fx && git push -q origin feat/x 2>&1 | tail -n 1; git checkout -q main
  git checkout -q -b crew/local-unpublished && echo y > lib/y.py && git add -A && git commit -qm local && git checkout -q main )
LOCAL_ONLY=$(gx "$W" rev-parse crew/local-unpublished)

# ── A. o filtro de dados ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
rc_is 0 "sparse: o filtro real vira lista (/* + regras)" "$M" sparse; has '!*.csv' "sparse: a regra do csv está lá"; [ "$(printf '%s\n' "$OUT" | head -n 1)" = '/*' ] && ok "sparse: começa por /*" || bad "sparse: primeira linha"
[ "$(printf '%s\n' "$OUT" | grep -c '^!')" -ge 50 ] && ok "sparse: ≥50 regras da Seção 1" || bad "sparse: poucas regras"
has '!.beads/' "sparse: .beads/ (backup de bead) é negado"; has '!data/' "sparse: data/ é negado"; has '!logs/' "sparse: logs/ é negado"
mkfilter() { local out=$1; shift; sed "$@" "$HERE/hetzner-rsync-filter.wa.txt" > "$out"; }
mkfilter "$T/f-nosec2" -e '/^# SEÇÃO 2/,$d'; HETZNER_MIRROR_FILTER=$T/f-nosec2 rc_is 3 "sparse: sem a Seção 2 (truncado) → recusa" "$M" sparse
mkfilter "$T/f-plus" -e 's/^- \.env$/+ .env/'; HETZNER_MIRROR_FILTER=$T/f-plus rc_is 3 "sparse: regra '+' na Seção 1 → recusa" "$M" sparse
mkfilter "$T/f-nocsv" -e '/^- \*\.csv$/d'; HETZNER_MIRROR_FILTER=$T/f-nocsv rc_is 3 "sparse: filtro sem *.csv → recusa" "$M" sparse; has '*.csv' "sparse: diz qual regra faltou"
mkfilter "$T/f-trail" -e 's/^- \*\.pem$/- *.pem /'; HETZNER_MIRROR_FILTER=$T/f-trail rc_is 3 "sparse: regra com espaço no fim → recusa" "$M" sparse
mkfilter "$T/f-slash" -e 's/^- \*\.pem$/- sub\/x.pem/'; HETZNER_MIRROR_FILTER=$T/f-slash rc_is 3 "sparse: regra com barra no MEIO (o rsync casa no fim do caminho, o filtro daqui só na raiz) → recusa" "$M" sparse
HETZNER_MIRROR_FILTER=$T/nao-existe rc_is 3 "sparse: filtro ausente → recusa" "$M" sparse
awk '/^# SEÇÃO 1/{print; n=0; next} /^# SEÇÃO 2/{print; s=1} !s&&/^- /{n++; if(n>8)next} {print}' "$HERE/hetzner-rsync-filter.wa.txt" > "$T/f-few"; HETZNER_MIRROR_FILTER=$T/f-few rc_is 3 "sparse: poucas regras (<20) → recusa" "$M" sparse

# ── B. a varredura de conteúdo, direto no helper (repositório de brinquedo) ───────────────────────────────────────────────────────────────────────────────────────────────────
SR0=$T/scan0; git init -q --bare "$SR0.git"; git clone -q "$SR0.git" "$SR0" 2>/dev/null; ST0=$T/scan0-state
( cd "$SR0" && phones 30 > leads.txt && echo code > ok.py && phones 3 > few.txt && git add -A && git commit -qm a && git branch -M main && git push -q origin main 2>&1 | tail -n 1 )
git -C "$SR0.git" update-ref refs/remotes/origin/main "$(git -C "$SR0.git" rev-parse main)"
rc_is 0 "scan: 1ª rodada" python3 -I "$SC" "$SR0.git" "$ST0"; has '1 sinalizado' "scan: achou o arquivo com 30 telefones"
[ "$(cat "$ST0/deny-extra")" = '!/leads.txt' ] && ok "scan: nega só o caminho sinalizado (few.txt com 3 telefones e ok.py passam)" || bad "scan: deny-extra" "$(cat "$ST0/deny-extra")"
head -n 1 "$ST0/seen.tsv" | grep -q '^#ruler=' && ok "scan: seen.tsv começa com a versão da régua" || bad "scan: seen.tsv sem versão da régua" "$(head -n 1 "$ST0/seen.tsv")"
awk -F'\t' '/^#/ { next } length($1) != 40 { bad = 1 } END { exit bad }' "$ST0/seen.tsv" && ok "scan: seen.tsv guarda oids INTEIROS (40), não abreviados" || bad "scan: seen.tsv com oid abreviado" "$(head -n 3 "$ST0/seen.tsv")"
rc_is 0 "scan: repetir não relê nada" python3 -I "$SC" "$SR0.git" "$ST0"; has '0 blob(s) novos' "scan: 2ª rodada sem blob novo"
( cd "$SR0" && git mv leads.txt moved.txt && git commit -qm mv && git push -q origin main 2>&1 | tail -n 1 ); git -C "$SR0.git" update-ref refs/remotes/origin/main "$(git -C "$SR0.git" rev-parse main)"
rc_is 0 "scan: rodada com renomeação" python3 -I "$SC" "$SR0.git" "$ST0"; grep -qxF '!/moved.txt' "$ST0/deny-extra" && grep -qxF '!/leads.txt' "$ST0/deny-extra" && ok "scan: o MESMO blob com outro nome também é negado (renomear não escapa)" || bad "scan: renomeação" "$(cat "$ST0/deny-extra")"
( cd "$SR0" && printf 'a b\n' > 'sp ace.txt' && phones 30 > 'we[ir]d*.txt' && git add -A && git commit -qm w && git push -q origin main 2>&1 | tail -n 1 ); git -C "$SR0.git" update-ref refs/remotes/origin/main "$(git -C "$SR0.git" rev-parse main)"
rc_is 0 "scan: caminho com curinga" python3 -I "$SC" "$SR0.git" "$ST0"; grep -qxF '!/we\[ir\]d\*.txt' "$ST0/deny-extra" && ok "scan: curingas do nome saem escapados no filtro" || bad "scan: escape" "$(cat "$ST0/deny-extra")"
TIPS_BEFORE=$(cat "$ST0/scanned-tips")
( cd "$SR0" && phones 30 > $'bad\nname.txt' && git add -A && git commit -qm nl && git push -q origin main 2>&1 | tail -n 1 ); git -C "$SR0.git" update-ref refs/remotes/origin/main "$(git -C "$SR0.git" rev-parse main)"
rc_is 3 "scan: caminho sinalizado que o filtro não consegue negar (quebra de linha) → recusa" python3 -I "$SC" "$SR0.git" "$ST0"; has 'NÃO consegui varrer' "scan: diz que não varreu"
[ "$(cat "$ST0/scanned-tips")" = "$TIPS_BEFORE" ] && ok "scan: falha NÃO avança a cobertura (scanned-tips intacto)" || bad "scan: scanned-tips avançou numa falha"
rc_is 2 "scan: uso errado" python3 -I "$SC" "$SR0.git"
SR1=$T/scan1; git init -q --bare "$SR1.git"; git clone -q "$SR1.git" "$SR1" 2>/dev/null; ST1=$T/scan1-state   # troca de TIPO (git status T): symlink → arquivo regular com 30 telefones
( cd "$SR1" && ln -s alvo leads.txt && git add -A && git commit -qm sym && rm leads.txt && phones 30 > leads.txt && git add -A && git commit -qm typechange && git branch -M main && git push -q origin main 2>&1 | tail -n 1 ); git -C "$SR1.git" update-ref refs/remotes/origin/main "$(git -C "$SR1.git" rev-parse main)"
rc_is 0 "scan: arquivo que entra por TROCA DE TIPO (symlink → arquivo) é lido" python3 -I "$SC" "$SR1.git" "$ST1"; has '1 sinalizado' "scan: achou os 30 telefones que entraram pela troca de tipo"
[ "$(cat "$ST1/deny-extra")" = '!/leads.txt' ] && ok "scan: o caminho da troca de tipo é negado" || bad "scan: troca de tipo ficou fora do deny-extra" "$(cat "$ST1/deny-extra")"
( cd "$SR1" && phones 30 > $'u\342\200\250v.txt' && git add -A && git commit -qm u2028 && git push -q origin main 2>&1 | tail -n 1 ); git -C "$SR1.git" update-ref refs/remotes/origin/main "$(git -C "$SR1.git" rev-parse main)"; python3 -I "$SC" "$SR1.git" "$ST1" > /dev/null; DE1=$(cat "$ST1/deny-extra"); python3 -I "$SC" "$SR1.git" "$ST1" > /dev/null   # U+2028 passa pelo guarda de caminho; o git lê o filtro só por \n
[ "$(cat "$ST1/deny-extra")" = "$DE1" ] && grep -qxF $'!/u\342\200\250v.txt' "$ST1/deny-extra" && ok "scan: nome com U+2028 sobrevive à releitura do deny-extra (1 regra, não 2 quebradas)" || bad "scan: U+2028 partiu o deny-extra" "$(cat "$ST1/deny-extra")"
mv "$ST1/deny-extra" "$T/de1.bak"; rc_is 3 "scan: seen.tsv tem blob sinalizado mas o deny-extra sumiu → recusa (estado sumido não é 'nada negado')" python3 -I "$SC" "$SR1.git" "$ST1"; [ ! -s "$ST1/deny-extra" ] && ok "scan: não regravou um deny-extra vazio" || bad "scan: regravou o deny-extra"; mv "$T/de1.bak" "$ST1/deny-extra"
# conteúdo que o varredor NÃO sabe ler (UTF-16, zip, imagem, PDF, latin-1) é "não sei"; não saber é sinalizado (estado inerte), nunca "limpo". Nomes neutros de propósito: só o CONTEÚDO pode pegá-los
SR2=$T/scan2; ST2=$T/scan2-state; git init -q --bare "$SR2.git"; git clone -q "$SR2.git" "$SR2" 2>/dev/null
( cd "$SR2" && mkdir -p assets && phones 30 | iconv -f UTF-8 -t UTF-16 > u16.txt && phones 30 | iconv -f UTF-8 -t UTF-16LE > u16le.txt && phones 30 | python3 -I -c 'import sys,zipfile;z=zipfile.ZipFile("neutral.zip","w",zipfile.ZIP_DEFLATED);z.writestr("p.txt",sys.stdin.read());z.close()' \
  && printf '\211PNG\r\n\032\n\0neutral' > assets/shot.png && { printf '%%PDF-1.4\n'; phones 3; } > doc.pdf && printf 'caf\351\n' > latin1.txt && printf 'a\303\247\303\243o\n' > readme.txt && { printf '\357\273\277'; phones 3; } > bom.txt \
  && git add -A && git commit -qm opaque && git branch -M main && git push -q origin main 2>&1 | tail -n 1 ); git -C "$SR2.git" update-ref refs/remotes/origin/main "$(git -C "$SR2.git" rev-parse main)"
rc_is 0 "scan: conteúdo ilegível → rodada completa" python3 -I "$SC" "$SR2.git" "$ST2"; has '6 sinalizado' "scan: 6 blobs sinalizados (UTF-16 com e sem BOM, zip, PNG, PDF, latin-1)"
for f in u16.txt u16le.txt neutral.zip assets/shot.png doc.pdf latin1.txt; do grep -qxF "!/$f" "$ST2/deny-extra" && ok "scan: $f (o varredor não sabe ler) é negado" || bad "scan: $f ilegível passou como limpo" "$(cat "$ST2/deny-extra")"; done
for f in readme.txt bom.txt; do grep -qxF "!/$f" "$ST2/deny-extra" && bad "scan: texto UTF-8 legível ($f) negado à toa" || ok "scan: texto UTF-8 legível ($f: acento, BOM, 3 telefones) NÃO é negado"; done
grep -v '^#' "$ST2/seen.tsv" | awk -F'\t' '{ print $1 "\t0" }' > "$T/seen-old"; mv "$T/seen-old" "$ST2/seen.tsv"; : > "$ST2/deny-extra"   # o estado que a régua ANTERIOR deixou: sem versão, tudo "limpo"
rc_is 0 "scan: seen.tsv de outra régua (sem a versão atual) não vale: lê tudo de novo" python3 -I "$SC" "$SR2.git" "$ST2"; has '6 sinalizado' "scan: releu e achou os 6"; grep -qxF '!/assets/shot.png' "$ST2/deny-extra" && ok "scan: o deny-extra voltou com o PNG" || bad "scan: régua nova não releu" "$(cat "$ST2/deny-extra")"
# a cobertura que o ESPELHO guarda (gtmirror.scannedtips) cai quando o estado do varredor não vale: senão o espelho seguiria servindo, com o filtro velho, durante a releitura inteira
git -C "$SR2.git" config gtmirror.scannedtips old-stamp; grep -v '^#' "$ST2/seen.tsv" > "$T/seen-nohdr"; mv "$T/seen-nohdr" "$ST2/seen.tsv"
rc_is 0 "scan: estado sem versão → relê" python3 -I "$SC" "$SR2.git" "$ST2"; git -C "$SR2.git" config gtmirror.scannedtips > /dev/null && bad "scan: o selo de cobertura antigo sobreviveu ao estado inválido" || ok "scan: estado inválido derruba o selo de cobertura do espelho (fica inerte até a varredura nova)"
git -C "$SR2.git" config gtmirror.scannedtips keep-stamp; rc_is 0 "scan: estado válido: repetir" python3 -I "$SC" "$SR2.git" "$ST2"; [ "$(git -C "$SR2.git" config gtmirror.scannedtips)" = keep-stamp ] && ok "scan: estado válido NÃO mexe no selo" || bad "scan: mexeu no selo com estado válido"; git -C "$SR2.git" config --unset gtmirror.scannedtips
# a varredura da história inteira pode passar do corte do sync (carga alta): cada rodada deixa o que já leu (seen.tsv, a cada HETZNER_MIRROR_SCAN_CKPT s) e a seguinte continua dali, em vez de recomeçar do zero para sempre.
# Fila por oid: a.txt (limpo) < caminho-que-o-filtro-não-nega < shot.png (PNG). O corte cai no meio, com o PNG por ler; o estado é o da régua ANTIGA, com scanned-tips velho (o que a produção tem hoje)
SR3=$T/scan3; ST3=$T/scan3-state; git init -q --bare "$SR3.git"; git clone -q "$SR3.git" "$SR3" 2>/dev/null; k=0
while :; do k=$((k+1)); oa=$(printf 'code%s\n' $k | git hash-object --stdin); op=$({ phones 30; echo "v$k"; } | git hash-object --stdin); og=$(printf '\211PNG\r\n\032\n\0neutral%s' $k | git hash-object --stdin)
  [ "$(printf '%s\n' "$oa" "$op" "$og" | LC_ALL=C sort | tr '\n' ' ')" = "$oa $op $og " ] && break; done
( cd "$SR3" && printf 'code%s\n' $k > a.txt && printf '\211PNG\r\n\032\n\0neutral%s' $k > shot.png && git add -A && git commit -qm c1 && git branch -M main && git push -q origin main 2>&1 | tail -n 1 ); C1=$(git -C "$SR3.git" rev-parse main); git -C "$SR3.git" update-ref refs/remotes/origin/main "$C1"
rc_is 0 "scan: histórico de 2 blobs (a.txt, shot.png) → rodada completa" python3 -I "$SC" "$SR3.git" "$ST3"
grep -v '^#' "$ST3/seen.tsv" | awk -F'\t' '{ print $1 "\t0" }' > "$T/seen-old3"; mv "$T/seen-old3" "$ST3/seen.tsv"; : > "$ST3/deny-extra"   # a régua anterior: sem versão, tudo "limpo"; o scanned-tips dela continua lá
( cd "$SR3" && { phones 30; echo "v$k"; } > $'bad\nname.txt' && git add -A && git commit -qm nl && git push -q origin main 2>&1 | tail -n 1 ); git -C "$SR3.git" update-ref refs/remotes/origin/main "$(git -C "$SR3.git" rev-parse main)"
HETZNER_MIRROR_SCAN_CKPT=0 rc_is 3 "scan: rodada que para no meio da fila (caminho que o filtro não nega) → rc 3" python3 -I "$SC" "$SR3.git" "$ST3"
{ [ "$(grep -vc '^#' "$ST3/seen.tsv")" = 1 ] && head -n 1 "$ST3/seen.tsv" | grep -q '^#ruler='; } && ok "scan: o que foi lido antes de parar ficou gravado (1 blob, régua nova)" || bad "scan: parar no meio jogou o progresso fora" "$(cat "$ST3/seen.tsv")"
[ ! -e "$ST3/scanned-tips" ] && ok "scan: estado de régua antiga derruba também o scanned-tips do varredor (senão o ^velho esconderia a história não relida)" || bad "scan: scanned-tips da régua antiga sobreviveu" "$(cat "$ST3/scanned-tips")"
: > "$ST3/seen.tsv.new.4242"; git -C "$SR3.git" update-ref refs/remotes/origin/main "$C1"
rc_is 0 "scan: sem o caminho que travava, a rodada seguinte continua dali" python3 -I "$SC" "$SR3.git" "$ST3"; has '1 blob(s) novos' "scan: leu só o que faltava (1 blob), não recomeçou do zero"
grep -qxF '!/shot.png' "$ST3/deny-extra" && ok "scan: o PNG que ficou por ler no corte é negado (a régua nova valeu para a história inteira)" || bad "scan: PNG por ler escapou" "$(cat "$ST3/deny-extra")"
[ ! -e "$ST3/seen.tsv.new.4242" ] && ok "scan: temporário que um corte deixou no estado é recolhido" || bad "scan: temporário de corte ficou no estado"

# ── C. init ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
HETZNER_MIRROR_FILTER=$T/f-nocsv rc_is 3 "init: filtro ruim → recusa" "$M" init wa "$O"; [ ! -e "$T/mh/repos/wa.git" ] && ok "init: filtro ruim não cria nada" || bad "init: criou espelho com filtro ruim"
rc_is 2 "init: sem url → uso" "$M" init wa; rc_is 2 "init: nome de rig inválido" "$M" init "../x" "$O"; rc_is 2 "init: prefixo inválido" "$M" init wa "$O" --prefix main
HETZNER_MIRROR_SCAN=$T/nao-existe.py rc_is 3 "init: sem o helper de varredura → recusa" "$M" init wa "$O"
mkdir -p "$T/x/.gc-worktrees"; cp "$M" "$HERE/hetzner-rsync-filter.wa.txt" "$SC" "$HERE/hetzner-pii-scan.py" "$T/x/.gc-worktrees/"; env -u HETZNER_MIRROR_ALLOW_WORKTREE "$T/x/.gc-worktrees/hetzner-mirror.sh" init wa "$O" > /dev/null 2>&1; [ $? = 3 ] && ok "init: rodado de dentro de worktree → recusa" || bad "init: aceitou worktree"
rc_is 0 "init com seed" "$M" init wa "$O" --seed "$W/.git" --prefix feat/; MR=$T/mh/repos/wa.git
[ -z "$(gx "$MR" for-each-ref refs/heads refs/tags)" ] && ok "init: nenhuma ref do seed (a branch local não vira candidata a publicação)" || bad "init: refs do seed ficaram" "$(gx "$MR" for-each-ref)"
gx "$MR" cat-file -e "$LOCAL_ONLY" 2>/dev/null && ok "init: os objetos do seed ficam (não baixa tudo de novo)" || bad "init: seed sem objetos"
[ "$(gx "$MR" config --get-all gtmirror.prefix | tr '\n' ' ')" = "crew/ worker/ feat/ " ] && ok "init: prefixos = crew/ worker/ + o extra" || bad "init: prefixos" "$(gx "$MR" config --get-all gtmirror.prefix)"
[ -x "$MR/hooks/pre-receive" ] && [ -x "$MR/hooks/post-receive" ] && ok "init: hooks instalados" || bad "init: hooks"
rc_is 0 "init: de novo é idempotente" "$M" init wa "$O" --seed "$W/.git" --prefix feat/
rc_is 1 "status: antes do 1º sync → NÃO pronto" "$M" status wa; has 'pronto=NÃO' "status: diz que não está pronto"
SSH_ORIGINAL_COMMAND="gt-mirror-spec 'wa'" "$M" serve > /dev/null 2>&1; [ $? = 75 ] && ok "serve: gt-mirror-spec antes da varredura → 75 (em atualização)" || bad "serve: spec serviu sem varredura"
[ -z "$(gx "$MR" config gtmirror.sparseoid)" ] && ok "init: nenhum filtro gravado ainda" || bad "init: filtro gravado sem varredura"

# ── D. sync / varredura que falha / origin fora ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
printf 'import sys\nsys.stderr.write("varredor de teste: falha de propósito\\n")\nsys.exit(3)\n' > "$T/failscan.py"
HETZNER_MIRROR_SCAN=$T/failscan.py rc_is 1 "sync: varredura que falha → rc 1" "$M" sync wa; has 'NÃO' "sync: avisa que o espelho não serve"
rc_is 1 "status: varredura falhou → não pronto" "$M" status wa; has 'pronto=NÃO' "status: não pronto"; has lastfetcherror "status: mostra o erro"
SSH_ORIGINAL_COMMAND="gt-mirror-spec 'wa'" "$M" serve > /dev/null 2>&1; [ $? = 75 ] && ok "serve: varredura falhou → spec recusado (75)" || bad "serve: spec serviu com varredura falha"
MAIN=$(gx "$O" rev-parse main)
rc_is 0 "sync: ok (varre o histórico)" "$M" sync wa; has 'sinalizado' "sync: relata a varredura"; [ "$(gx "$MR" rev-parse refs/remotes/origin/main)" = "$MAIN" ] && ok "sync: refs/remotes/origin/main = main do origin" || bad "sync: main"
[ -n "$(gx "$MR" log -1 --format=%ct refs/gt/synced)" ] && ok "sync: carimbo refs/gt/synced gravado" || bad "sync: sem carimbo"
[ -z "$(gx "$MR" for-each-ref refs/heads)" ] && ok "sync: o espelho não ganha refs/heads (branch do origin fica em refs/remotes)" || bad "sync: refs/heads apareceu"
rc_is 0 "status: sincronizado e pronto" "$M" status wa; has 'pronto=sim' "status: pronto=sim"
DX=$T/mh/state/wa/deny-extra; grep -qxF '!/docs/notes/ab_results.json' "$DX" && grep -qxF '!/docs/notes/renamed_results.json' "$DX" && grep -qxF '!/scripts/gen.py' "$DX" && ok "varredura: nega nome neutro (.json), o MESMO blob renomeado e código com lista (.py)" || bad "varredura: deny-extra" "$(cat "$DX")"
grep -qxF '!/docs/shot.png' "$DX" && ok "varredura: PNG de nome neutro (conteúdo que o varredor não lê) é negado" || bad "varredura: PNG de nome neutro passou" "$(cat "$DX")"
! grep -q 'small.json' "$DX" && ! grep -q 'a.py' "$DX" && ok "varredura: arquivo com 5 telefones e código comum NÃO são negados" || bad "varredura: negou demais" "$(cat "$DX")"
rc_is 0 "sparse <rig>: o filtro do rig inclui os caminhos da varredura" "$M" sparse wa; has '!/scripts/gen.py' "sparse <rig>: tem gen.py"
chmod 000 "$DX"; rc_is 1 "status: deny-extra ilegível → rc 1 e diz ILEGÍVEL (não '0 negados')" "$M" status wa; has 'ILEGÍVEL' "status: mostra ILEGÍVEL"; rc_is 3 "sparse <rig>: deny-extra ilegível → recusa" "$M" sparse wa; chmod 644 "$DX"
rc_is 2 "sync: rig desconhecido → uso" "$M" sync nao-existe
STAMP1=$(gx "$MR" rev-parse refs/gt/synced); mv "$O" "$O.off"
rc_is 1 "sync: origin fora → rc 1" "$M" sync wa; has 'inacessível' "sync: erro visível"; [ "$(gx "$MR" rev-parse refs/gt/synced)" = "$STAMP1" ] && ok "sync: origin fora NÃO renova o carimbo" || bad "sync: carimbo renovado sem fetch"
rc_is 1 "status: origin fora → rc 1 com o erro" "$M" status wa; has lastfetcherror "status: mostra o erro de fetch"
SSH_ORIGINAL_COMMAND="gt-mirror-spec 'wa'" "$M" serve > /dev/null 2>&1; [ $? = 0 ] && ok "serve: origin fora mas pontas já varridas → o spec continua servindo (o servidor não depende do origin)" || bad "serve: spec caiu com o origin fora"
mv "$O.off" "$O"; sleep 1; rc_is 0 "sync: origin de volta → ok" "$M" sync wa; rc_is 0 "status: erro some depois do fetch bom" "$M" status wa
# a trava do sync: de quem é, e o que "outro sync em curso" quer dizer (antes: pid-less nunca recolhida, pid reaproveitado segurava, e um sync PARADO saía rc 0 igual a um concorrente normal)
LK=$MR/gtm-fetch.lock; LKP=$MR/gtm-publish.lock
mkdir "$LK"; rc_is 0 "trava: sem pid e NOVA (o dono pode estar gravando o pid agora) é respeitada" "$M" sync wa; has 'outro sync em curso' "trava: diz que há outro sync"; rmdir "$LK"
mkdir "$LK"; touch -t 202001010000 "$LK"; rc_is 0 "trava: sem pid e VELHA (o dono morreu entre o mkdir e a gravação) é recolhida e o sync roda" "$M" sync wa; has 'sync wa: ok' "trava: o sync rodou"; [ ! -e "$LK" ] && ok "trava: não ficou nada" || { bad "trava: ficou"; rm -rf "$LK"; }
sleep 300 & SLP=$!; mkdir "$LK"; echo "$SLP" > "$LK/pid"; rc_is 0 "trava: pid VIVO mas de outro programa (pid reaproveitado) não segura a trava" "$M" sync wa; has 'sync wa: ok' "trava: o sync rodou apesar do pid vivo"; kill "$SLP" 2> /dev/null; rm -rf "$LK"
bash -c 'exec -a hetzner-mirror.sh sleep 300' & HOLD=$!; mkdir "$LK"; echo "$HOLD" > "$LK/pid"; sleep 1
rc_is 0 "trava: dono vivo e legítimo, há pouco tempo → 'outro sync em curso', rc 0" "$M" sync wa; has 'outro sync em curso' "trava: sync concorrente normal"
touch -t 202001010000 "$LK"; rc_is 1 "trava: o MESMO dono há muito tempo (travado?) → rc 1, não o rc 0 de um sync concorrente normal" "$M" sync wa; has 'parada' "trava: diz que passou do esperado"; hasnt 'outro sync em curso' "trava: não finge ser concorrente normal"
rc_is 1 "status: trava parada deixa o erro registrado" "$M" status wa; has lastfetcherror "status: mostra o erro da trava"; kill "$HOLD" 2> /dev/null; rm -rf "$LK"; rc_is 0 "sync: sem a trava, volta ao normal e limpa o erro" "$M" sync wa; rc_is 0 "status: limpo" "$M" status wa
rc_is 1 "trava: o pid não grava (umask) → publish rc 1" bash -c 'umask 0577; exec "$0" publish wa' "$M"; has 'não consegui pegar a trava' "trava: diz que o erro é meu"; hasnt 'outro publish em curso' "trava: não acusa 'outro publish' quando o erro é meu"
[ ! -e "$LKP" ] && ok "trava: o pid que não grava não deixa trava órfã" || { bad "trava: ficou trava sem pid"; chmod 700 "$LKP"; rm -rf "$LKP"; }
if [ "$(id -u)" != 0 ]; then chmod 555 "$MR"; rc_is 1 "trava: não consigo criar a trava (espelho sem escrita) → rc 1" "$M" sync wa; hasnt 'outro sync em curso' "trava: erro de disco não é 'outro sync em curso'"; chmod 755 "$MR"; fi
printf 'import time\ntime.sleep(60)\n' > "$T/hangscan.py"; T0=$SECONDS
HETZNER_MIRROR_SCAN=$T/hangscan.py HETZNER_MIRROR_SCAN_TIMEOUT=3 rc_is 1 "sync: varredura que PENDURA é cortada no limite → rc 1" "$M" sync wa; [ $((SECONDS - T0)) -lt 30 ] && ok "sync: o corte veio em segundos, não em 60" || bad "sync: esperou $((SECONDS - T0)) s pela varredura"
rc_is 0 "sync: depois do corte volta ao normal" "$M" sync wa; rc_is 0 "status: limpo depois do corte" "$M" status wa
# status: rc 0 só com tudo em dia (antes: rc 0 com o último sync bom de 30 dias atrás e com o filtro DIFERENTE do gravado)
STAMP_OK=$(gx "$MR" rev-parse refs/gt/synced); gx "$MR" update-ref refs/gt/synced "$(GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' gx "$MR" commit-tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904 -m old)"
rc_is 1 "status: último sync bom velho demais → rc 1, não 'em dia'" "$M" status wa; has 'VELHO' "status: diz VELHO"; gx "$MR" update-ref refs/gt/synced "$STAMP_OK"; rc_is 0 "status: com o carimbo de volta, rc 0" "$M" status wa
mkfilter "$T/f-nopem" -e '/^- \*\.pem$/d'; HETZNER_MIRROR_FILTER=$T/f-nopem rc_is 1 "status: filtro vigente ≠ o gravado → rc 1" "$M" status wa; has 'DIFERENTE' "status: diz DIFERENTE"
# pid reaproveitado (reboot) não é "rodando": sshd status e tunnel start/status conferem o PROCESSO, não só o pid
sleep 300 & RP=$!; mkdir -p "$T/mh-reuse"; echo "$RP" > "$T/mh-reuse/sshd.pid"
HETZNER_MIRROR_HOME=$T/mh-reuse rc_is 1 "sshd status: pid vivo de OUTRO programa não é 'rodando'" "$M" sshd status; has 'parado' "sshd status: diz parado"
echo "$RP" > "$T/mh/tunnel-reuse.invalid.pid"; rc_is 1 "tunnel status: pid vivo de outro programa → parado, rc 1" "$M" tunnel status reuse.invalid; has 'parado' "tunnel status: diz parado"
echo "$RP" > "$T/mh/tunnel-reuse.invalid.pid"; rc_is 1 "tunnel start: pid reaproveitado não impede de subir (o host não existe: sobe e cai)" "$M" tunnel start reuse.invalid; hasnt 'já rodando' "tunnel start: não diz 'já rodando' por causa do pid de outro programa"; kill "$RP" 2> /dev/null; rm -f "$T/mh/tunnel-reuse.invalid.pid"
# o limiar do varredor do espelho é o do hetzner-pii-scan.py (o main dele, nph/ncp): um muda sem o outro e este caso quebra
grep -q '^PH_MIN, CP_MIN = 20, 3 ' "$SC" && grep -q 'nph, ncp = None, None, 20, 3$' "$HERE/hetzner-pii-scan.py" && ok "limiares: 20 telefones / 3 CPFs iguais nos dois varredores" || bad "limiares: os dois varredores divergem" "$(grep -n 'PH_MIN, CP_MIN =' "$SC"; grep -n 'nph, ncp =' "$HERE/hetzner-pii-scan.py")"
# temporário com nome FIXO (.new) em caminho que pode rodar em dobro: dois processos escreveriam no mesmo arquivo
grep -nE '[A-Za-z_]\.new"' "$M" "$R" "$SC" > "$T/fixednew"; [ ! -s "$T/fixednew" ] && ok "temporários: nenhum nome fixo '.new' (todos levam o pid)" || bad "temporários: nome fixo" "$(cat "$T/fixednew")"
ls "$ST2" | grep -q '\.new' && bad "scan: sobrou temporário no estado" "$(ls "$ST2")" || ok "scan: nenhum temporário sobrando no estado"

# ── E. serve: o que a chave consegue rodar ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
serve() { SSH_ORIGINAL_COMMAND="$1" "$M" serve < /dev/null; }
for c in "" "bash" "sh -c id" "git-upload-pack '/nao-existe.git'" "git-upload-pack '/../etc'" "git-upload-pack '/wa.git' extra" "git-upload-pack '/wa.git'; touch $T/PWNED" "git-upload-pack '$T/mh/repos/wa.git'" \
         "git-receive-pack '/wa.git' && touch $T/PWNED" "git-upload-pack '/wa.git'"$'\n'"touch $T/PWNED" "git-upload-pack /wa.git" "git-upload-archive '/wa.git'" "git-upload-pack '/WA.git'" \
         "gt-mirror-spec" "gt-mirror-spec 'wa' x" "gt-mirror-spec 'wa'; touch $T/PWNED" "gt-mirror-spec '../wa'" "gt-mirror-spec \$(touch $T/PWNED)" "spec-out wa" "sync wa" "gt-mirror-spec '/etc/passwd'"; do
  OUT=$(serve "$c" 2>&1); got=$?; [ "$got" = 126 ] && ok "serve: recusa [$(printf '%.40s' "$c" | tr '\n' '|')]" || bad "serve: aceitou [$c] (rc=$got)" "$OUT"; done
[ ! -e "$T/PWNED" ] && ok "serve: nenhum comando injetado rodou" || bad "serve: injeção executou"
OUT=$(serve "git-upload-pack '/wa.git'" 2>&1 | head -c 400); has 'refs/remotes/origin/main' "serve: upload-pack de espelho conhecido anuncia as refs"
OUT=$(serve "git-upload-pack 'wa'" 2>&1 | head -c 100); [ -n "$OUT" ] && ok "serve: forma 'wa' (sem barra/.git) também aceita" || bad "serve: forma curta"
OUT=$(serve "gt-mirror-spec 'wa'" 2>&1); [ "$(printf '%s\n' "$OUT" | head -n 1)" = '/*' ] && ok "serve: gt-mirror-spec devolve o filtro vigente" || bad "serve: gt-mirror-spec" "$OUT"
[ "$(printf '%s\n' "$OUT" | git hash-object --stdin)" = "$(gx "$MR" config gtmirror.sparseoid)" ] && ok "serve: o filtro entregue tem o oid gravado no espelho" || bad "serve: oid do filtro entregue difere"
[ -s "$T/mh/serve.log" ] && ok "serve: recusas ficam em serve.log" || bad "serve: sem serve.log"

# ── F. authorize ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
ssh-keygen -q -t ed25519 -N '' -f "$SRV_HOME/.ssh/gt_mirror"; ssh-keygen -q -t rsa -b 2048 -N '' -f "$T/rsa"; K=$(cut -d' ' -f1,2 "$SRV_HOME/.ssh/gt_mirror.pub")
rc_is 3 "authorize: RSA → recusa" "$M" authorize "$T/rsa.pub"; printf 'command="id" %s\n' "$K" > "$T/opt.pub"; rc_is 3 "authorize: chave com opções na frente → recusa" "$M" authorize "$T/opt.pub"
printf '%s\n%s\n' "$K" "$K" > "$T/two.pub"; rc_is 3 "authorize: duas chaves → recusa" "$M" authorize "$T/two.pub"; printf '%s x y\n' "$K" > "$T/cm.pub"; rc_is 3 "authorize: comentário com espaço → recusa" "$M" authorize "$T/cm.pub"
: > "$T/empty.pub"; rc_is 3 "authorize: arquivo vazio → recusa" "$M" authorize "$T/empty.pub"; [ ! -s "$T/mh/authorized_keys" ] && ok "authorize: recusas não gravam nada" || bad "authorize: gravou numa recusa"
rc_is 0 "authorize: chave ed25519 pura" "$M" authorize "$SRV_HOME/.ssh/gt_mirror.pub"; rc_is 0 "authorize: repetir é idempotente" "$M" authorize "$SRV_HOME/.ssh/gt_mirror.pub"
[ "$(grep -c . "$T/mh/authorized_keys")" = 1 ] && grep -q '^restrict,from="127.0.0.1,::1",command="HETZNER_MIRROR_HOME=[^"]* [^"]* serve" ssh-ed25519 ' "$T/mh/authorized_keys" && ok "authorize: UMA linha com restrict + from loopback + comando forçado" || bad "authorize: formato" "$(cat "$T/mh/authorized_keys")"
[ "$(stat -f %Lp "$T/mh/authorized_keys" 2>/dev/null || stat -c %a "$T/mh/authorized_keys")" = 600 ] && ok "authorize: authorized_keys 0600" || bad "authorize: permissão"
mkdir -p "$T/bin2"; cp "$M" "$HERE/hetzner-rsync-filter.wa.txt" "$SC" "$HERE/hetzner-pii-scan.py" "$T/bin2/"; rc_is 0 "authorize: de OUTRO caminho troca o comando forçado" "$T/bin2/hetzner-mirror.sh" authorize "$SRV_HOME/.ssh/gt_mirror.pub"; has 'atualizado' "authorize: diz que atualizou"
[ "$(grep -c . "$T/mh/authorized_keys")" = 1 ] && grep -q "$T/bin2/hetzner-mirror.sh serve" "$T/mh/authorized_keys" && ok "authorize: continua UMA linha e ela aponta para o novo script" || bad "authorize: troca de linha" "$(cat "$T/mh/authorized_keys")"
rc_is 0 "authorize: volta ao script original" "$M" authorize "$SRV_HOME/.ssh/gt_mirror.pub"; grep -q "$M serve" "$T/mh/authorized_keys" && [ "$(stat -f %Lp "$T/mh/authorized_keys" 2>/dev/null || stat -c %a "$T/mh/authorized_keys")" = 600 ] && ok "authorize: de volta, 0600" || bad "authorize: restauração"

# ── G. o transporte: sshd próprio (real) ou o `serve` direto (HMST_FAKE) ───────────────────────────────────────────────────────────────────────────────────────────────────
PORT=$HETZNER_MIRROR_PORT; U=$(id -un); URL="ssh://$U@127.0.0.1:$PORT/wa.git"; KEY=$SRV_HOME/.ssh/gt_mirror; KH=$SRV_HOME/.ssh/gt_known_hosts
if [ -z "$FAKE" ]; then
  rc_is 0 "sshd: sobe só-chave em loopback" "$M" sshd start; "$M" hostkey > "$KH"
  SSHO="-F /dev/null -p $PORT -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KH -o ConnectTimeout=15"; GS="ssh $SSHO"
  OUT=$(ssh $SSHO "$U@127.0.0.1" 2>&1 < /dev/null); [ $? != 0 ] && ok "ssh: tentar shell é recusado" || bad "ssh: shell aberto"; has 'recusado' "ssh: o wrapper explica, sem executar"
  OUT=$(ssh $SSHO "$U@127.0.0.1" 'ls /' 2>&1 < /dev/null); [ $? != 0 ] && ok "ssh: comando qualquer é recusado" || bad "ssh: comando rodou"; hasnt 'Applications' "ssh: 'ls /' não listou nada"
  OUT=$(ssh $SSHO -W 127.0.0.1:22 "$U@127.0.0.1" 2>&1 < /dev/null); [ $? != 0 ] && ok "ssh: forward (-W) é recusado" || bad "ssh: forward aberto"
  OUT=$(ssh -F /dev/null -p "$PORT" -o PubkeyAuthentication=no -o PreferredAuthentications=none -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KH" -v "$U@127.0.0.1" true 2>&1 < /dev/null)
  printf '%s' "$OUT" | grep -qE 'Authentications that can continue: publickey[[:space:]]*$' && ok "ssh: só publickey é oferecido (sem senha, sem keyboard-interactive)" || bad "ssh: métodos oferecidos" "$(printf '%s' "$OUT" | grep 'can continue')"
else GS=$T/fakessh; : > "$KH"; fi
rc_is 2 "bootstrap: prefixo inválido (maiúscula/espaço) é recusado, como no init do espelho" srv bootstrap wa "$URL" "$KEY" "$KH" "Bad Prefix/"; has "prefixo inválido" "bootstrap: diz qual prefixo"
rc_is 0 "bootstrap: clone parcial pelo espelho" srv bootstrap wa "$URL" "$KEY" "$KH" feat/; has 'resultado=ok' "bootstrap: o pull inicial deu certo"
SR=$T/srv/git/wa/repo.git
gx "$SR" rev-parse -q --verify refs/remotes/origin/main > /dev/null && ok "clone: tem origin/main" || bad "clone: sem origin/main"
[ "$(gx "$SR" config --get-regexp '^remote\..*\.url$' | awk '{print $2}')" = "$URL" ] && ok "clone: o ÚNICO remoto é o espelho" || bad "clone: remotos" "$(gx "$SR" config --get-regexp '^remote\..*\.url$')"
gx "$SR" config --get-regexp 'remote.origin.push' | grep -q 'worker' && ok "clone: push só dos prefixos aceitos" || bad "clone: refspec de push"
[ "$(gx "$SR" config gtremote.sparseoid)" = "$(gx "$MR" config gtmirror.sparseoid)" ] && ok "clone: usa o filtro vigente do espelho" || bad "clone: filtro diferente do espelho"
# o espelho (mini) TEM todo tipo de dado no histórico; o clone do servidor não
marked() { gx "$1" cat-file --batch-all-objects --batch-check='%(objectname) %(objecttype)' | awk '$2=="blob"{print $1}' | while read -r o; do gx "$1" cat-file blob "$o" 2>/dev/null | grep -q 'DATA-MARK' && echo "$o"; done | wc -l | tr -d ' '; }
MIRROR_HITS=$(marked "$MR"); CLONE_HITS=$(marked "$SR")   # conteúdo, não nome: cada arquivo de dado do fixture traz DATA-MARK; os inofensivos (código, small.json, README) não
[ "$MIRROR_HITS" -ge 8 ] && ok "fixture: o espelho do mini tem $MIRROR_HITS blobs com dado no histórico" || bad "fixture: o espelho não tem o dado que devia ter ($MIRROR_HITS)"
[ "$CLONE_HITS" = 0 ] && ok "clone: ZERO blob de dado no servidor (nome da Seção 1, pasta de dado, conteúdo com lista, e o blob renomeado)" || bad "clone: $CLONE_HITS blobs de dado" "$(gx "$SR" cat-file --batch-all-objects --batch-check)"
for f in lib/a.py src/token_helper.py docs/notes/small.json docs/README.md; do gx "$SR" cat-file -e "refs/remotes/origin/main:$f" 2>/dev/null && gx "$SR" cat-file -p "refs/remotes/origin/main:$f" > /dev/null 2>&1 && ok "clone: tem $f (código/dado inofensivo chega)" || bad "clone: faltou $f"; done
gx "$SR" rev-parse -q --verify refs/gt/synced > /dev/null && ok "clone: recebeu o carimbo refs/gt/synced" || bad "clone: sem carimbo"
rc_is 0 "scan: clone limpo" srv scan wa; has 'limpo' "scan: diz limpo com contagem"
has 'mesmos bytes sob caminho permitido' "scan: conta os blobs que um caminho permitido explica"; has '(1 deles' "scan: o duplicado do fixture (.beads/backup/dupe.txt = docs/dupe.txt) é explicado, não violação"
# pedidos que o espelho tem de recusar
mkdir -p "$T/probe"; BLOB=$(gx "$MR" rev-parse "refs/remotes/origin/main~2:docs/leads.csv"); gx "$MR" cat-file -e "$BLOB" 2>/dev/null && [ -n "$BLOB" ] && ok "fixture: o blob de dado existe no espelho do mini (o teste de recusa abaixo não é vazio)" || bad "fixture: blob de dado inexistente: $BLOB"
OUT=$(GIT_SSH_COMMAND="$GS" git clone -q --bare "$URL" "$T/probe/nofilter" 2>&1); [ ! -d "$T/probe/nofilter" ] && ok "espelho: clone SEM filtro é recusado" || bad "espelho: clone sem filtro passou" "$OUT"
OUT=$(GIT_SSH_COMMAND="$GS" git clone -q --bare --filter=blob:none "$URL" "$T/probe/blobnone" 2>&1); [ ! -d "$T/probe/blobnone" ] && ok "espelho: clone com OUTRO filtro (blob:none) é recusado" || bad "espelho: outro filtro passou"
WEAK=$("$M" sparse | sed -n '1,/^!\*\.csv$/p' | git -C "$MR" hash-object -w --stdin)   # um filtro MAIS FRACO (sem os caminhos da varredura): não pode ser aceito
OUT=$(GIT_SSH_COMMAND="$GS" git clone -q --bare --filter="sparse:oid=$WEAK" "$URL" "$T/probe/weak" 2>&1); [ ! -d "$T/probe/weak" ] && ok "espelho: clone com filtro mais fraco que o vigente é recusado" || bad "espelho: filtro fraco passou"
OUT=$(GIT_SSH_COMMAND="$GS" git -C "$SR" fetch -q --no-tags origin "$BLOB" 2>&1); gx "$SR" cat-file --batch-all-objects --batch-check | grep -q "$BLOB" && bad "espelho: blob de dado vazou por fetch de oid" "$OUT" || ok "espelho: fetch por oid do blob de dado não entrega nada"
has 'unadvertised' "espelho: o motivo é 'oid não anunciado' (protocolo v0)"
# varredura do servidor precisa PEGAR o que planto
PL=$(printf 'leads' | git -C "$SR" hash-object -w --stdin); TR=$(printf '100644 blob %s\tleads.csv\n' "$PL" | git -C "$SR" mktree); CM=$(git -C "$SR" commit-tree "$TR" -m plant); git -C "$SR" update-ref refs/heads/worker/plant "$CM"
rc_is 1 "scan: dado plantado no histórico → VIOLAÇÃO" srv scan wa; has 'leads.csv' "scan: diz o caminho"; git -C "$SR" update-ref -d refs/heads/worker/plant; rc_is 0 "scan: sem a planta volta a limpo" srv scan wa
PL2=$(printf 'x' | git -C "$SR" hash-object -w --stdin); TR2=$(printf '100644 blob %s\tmy leads.csv\n' "$PL2" | git -C "$SR" mktree); git -C "$SR" update-ref refs/heads/worker/plant2 "$(git -C "$SR" commit-tree "$TR2" -m p2)"
rc_is 1 "scan: dado com ESPAÇO no nome também é pego" srv scan wa; has 'my leads.csv' "scan: mostra o nome inteiro"; git -C "$SR" update-ref -d refs/heads/worker/plant2
PL3=$(printf 'x' | git -C "$SR" hash-object -w --stdin); TR3=$(printf '100644 blob %s\tab_results.json\n' "$PL3" | git -C "$SR" mktree); TR4=$(printf '040000 tree %s\tnotes\n' "$TR3" | git -C "$SR" mktree); TR5=$(printf '040000 tree %s\tdocs\n' "$TR4" | git -C "$SR" mktree)
git -C "$SR" update-ref refs/heads/worker/plant3 "$(git -C "$SR" commit-tree "$TR5" -m p3)"; rc_is 1 "scan: caminho negado pela VARREDURA DE CONTEÚDO também é pego no servidor" srv scan wa; has 'ab_results.json' "scan: mostra o caminho"; git -C "$SR" update-ref -d refs/heads/worker/plant3
for nm in 'dq"x.csv' 'bs\x.csv' $'tab\tx.csv'; do PLQ=$(printf 'x' | git -C "$SR" hash-object -w --stdin); git -C "$SR" update-ref refs/heads/worker/plantq "$(git -C "$SR" commit-tree "$(printf '100644 blob %s\t%s\0' "$PLQ" "$nm" | git -C "$SR" mktree -z)" -m q)"
  OUT=$(srv scan wa 2>&1); [ $? = 1 ] && ok "scan: nome com caractere que o git escapa [$(printf '%s' "$nm" | tr '\t' T)] e que o filtro nega → VIOLAÇÃO (não vira 'caminho permitido')" || bad "scan: nome escapado passou [$nm]" "$OUT"; git -C "$SR" update-ref -d refs/heads/worker/plantq; done
PLN=$(printf 'x' | git -C "$SR" hash-object -w --stdin); git -C "$SR" update-ref refs/heads/worker/plantn "$(git -C "$SR" commit-tree "$(printf '100644 blob %s\tnl\nx.csv\0' "$PLN" | git -C "$SR" mktree -z)" -m n)"
rc_is 2 "scan: nome com quebra de linha → rc 2 (não consegui varrer; nunca 'limpo')" srv scan wa; git -C "$SR" update-ref -d refs/heads/worker/plantn
PLF=$(printf 'x' | git -C "$SR" hash-object -w --stdin); git -C "$SR" update-ref refs/heads/worker/plantf "$(git -C "$SR" commit-tree "$(printf '100644 blob %s\tx\n:000000 100644 0000000000000000000000000000000000000000 1111111111111111111111111111111111111111 A\ny.csv\0' "$PLF" | git -C "$SR" mktree -z)" -m f)"
rc_is 2 "scan: nome que FORJA um registro raw (esconderia y.csv sob o nome 'x') → rc 2, nunca 'limpo'" srv scan wa; git -C "$SR" update-ref -d refs/heads/worker/plantf; rc_is 0 "scan: sem as plantas volta a limpo" srv scan wa
# troca de TIPO (git status T): a base é um symlink x.csv cujo blob ('alvo') um caminho permitido (ok.txt) explica; o commit seguinte troca x.csv por arquivo regular de dado
TOK=$(printf alvo | git -C "$SR" hash-object -w --stdin); TBS=$(git -C "$SR" commit-tree "$(printf '120000 blob %s\tx.csv\n100644 blob %s\tok.txt\n' "$TOK" "$TOK" | git -C "$SR" mktree)" -m s); git -C "$SR" update-ref refs/heads/worker/planttc "$(git -C "$SR" commit-tree "$(printf '100644 blob %s\tx.csv\n' "$(printf dado | git -C "$SR" hash-object -w --stdin)" | git -C "$SR" mktree)" -p "$TBS" -m t)"
rc_is 1 "scan: dado que entra por TROCA DE TIPO (symlink → arquivo) é VIOLAÇÃO, não 'limpo'" srv scan wa; has 'x.csv' "scan: diz o caminho"; git -C "$SR" update-ref -d refs/heads/worker/planttc
git -C "$SR" config remote.gh.url https://github.com/x/y.git; rc_is 1 "scan: remoto do GitHub → VIOLAÇÃO" srv scan wa; git -C "$SR" config --unset remote.gh.url
touch "$SRV_HOME/.git-credentials"; rc_is 1 "scan: .git-credentials no host → VIOLAÇÃO" srv scan wa; rm -f "$SRV_HOME/.git-credentials"
echo 'export GITHUB_TOKEN=x' > "$SRV_HOME/.profile"; rc_is 1 "scan: token do GitHub no .profile → VIOLAÇÃO" srv scan wa; rm -f "$SRV_HOME/.profile"
OUT=$(GITHUB_TOKEN=x HOME=$SRV_HOME "$R" scan wa 2>&1); [ $? = 1 ] && ok "scan: token do GitHub no ambiente → VIOLAÇÃO" || bad "scan: ambiente com token passou" "$OUT"
chmod 000 "$SR"; rc_is 2 "scan: não consegui ler o clone → rc 2 (nunca 'limpo')" srv scan wa; chmod 755 "$SR"
mv "$T/srv/git/wa/deny" "$T/deny.bak"; rc_is 2 "scan: sem a lista de dados → rc 2" srv scan wa; mv "$T/deny.bak" "$T/srv/git/wa/deny"
rc_is 2 "scan: clone desconhecido → rc 2" srv scan nao-existe

# ── H. conteúdo NOVO no origin: varrido antes de o servidor poder ver ─────────────────────────────────────────────────────────────────────────────────────────────────────
( cd "$W" && git checkout -q main && { phones 25; echo 'DATA-MARK new'; } > docs/new_dump.txt && echo 'print(9)' > lib/new_code.py && git add -A && git commit -qm c4-new && git push -q origin main 2>&1 | tail -n 1 )
git -C "$MR" fetch -q --prune --no-tags origin   # só o fetch: a varredura ainda não cobre as pontas novas
mirror_state=$("$M" status wa 2>&1); printf '%s' "$mirror_state" | grep -q 'pronto=NÃO' && ok "janela: fetch sem varredura → o espelho deixa de estar pronto" || bad "janela: continuou pronto" "$mirror_state"
OUT=$(GIT_SSH_COMMAND="$GS" git -C "$SR" fetch -q --no-tags "--filter=sparse:oid=$(gx "$SR" config gtremote.sparseoid)" origin 2>&1); gx "$SR" cat-file --batch-all-objects --batch-check | grep -q "$(gx "$MR" rev-parse refs/remotes/origin/main)" && bad "janela: o servidor baixou commit ainda não varrido" "$OUT" || ok "janela: upload-pack recusa pedido enquanto a varredura não cobre as pontas"
rc_is 1 "pull do servidor com o espelho em atualização → erro VISÍVEL (não finge que atualizou)" srv pull wa; has 'resultado=erro' "pull: resultado=erro"; has 'em atualização' "pull: diz o motivo (75 do espelho)"
rc_is 0 "worktree com o espelho em atualização sai do que havia (pull=erro registrado)" srv wt-add wa ga-old; has '"pull":"erro"' "wt-add: grava pull=erro no registro"; rc_is 0 "wt-rm do worktree de teste" srv wt-rm wa ga-old
rc_is 0 "sync: varre o novo e libera" "$M" sync wa; has '1 sinalizado' "sync incremental: só o blob novo foi lido e sinalizado"; grep -qxF '!/docs/new_dump.txt' "$DX" && ok "varredura incremental: new_dump.txt negado" || bad "varredura incremental" "$(cat "$DX")"
rc_is 0 "pull do servidor depois" srv pull wa; has 'resultado=ok' "pull: ok"
tail -n 1 "$T/srv/git/pulls.jsonl" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d["rig"]=="wa" and d["pull"]=="ok" and isinstance(d["lag_min"],int) and len(d["main"])==7' && ok "pull: o atraso fica registrado em pulls.jsonl (lag_min inteiro)" || bad "pull: pulls.jsonl" "$(tail -n 2 "$T/srv/git/pulls.jsonl")"
grep -q '"pull":"erro"' "$T/srv/git/pulls.jsonl" && ok "pull: o pull que falhou também ficou registrado (pull=erro)" || bad "pull: pull com erro não registrado" """$(cat "$T/srv/git/pulls.jsonl")"
gx "$SR" cat-file -p refs/remotes/origin/main:lib/new_code.py > /dev/null 2>&1 && ok "incremental: o código novo chegou" || bad "incremental: código novo não chegou"
[ "$(marked "$SR")" = 0 ] && ok "incremental: o dump com 25 telefones NÃO chegou ao servidor (zero blob de dado)" || bad "incremental: dado novo chegou ao servidor"
rc_is 0 "scan do servidor continua limpo" srv scan wa

# ── I. worktree por bead, push, publicação ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
rc_is 2 "wt-add: bead inválida" srv wt-add wa '../x'; rc_is 3 "wt-add: base inexistente → recusa" srv wt-add wa ga-t1 nao-existe
rc_is 0 "wt-add: cria o worktree" srv wt-add wa ga-t1; WT=$T/srv/git/wa/wt/ga-t1; LINE=$(tail -n 1 "$T/srv/git/worktrees.jsonl")
[ -f "$WT/lib/a.py" ] && ok "wt-add: o código está na árvore" || bad "wt-add: sem lib/a.py"
[ ! -e "$WT/lib/g.db" ] && [ ! -e "$WT/.env" ] && [ ! -e "$WT/auth" ] && [ ! -e "$WT/scripts/gen.py" ] && [ ! -e "$WT/docs/new_dump.txt" ] && ok "wt-add: arquivo de dado/segredo (inclusive o sinalizado por conteúdo) NÃO está na árvore" || bad "wt-add: dado na árvore" "$(ls -A "$WT" "$WT/scripts" "$WT/docs")"
printf '%s' "$LINE" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d["bead"]=="ga-t1" and d["rig"]=="wa" and d["branch"]=="worker/ga-t1" and isinstance(d["lag_min"],int) and isinstance(d["main_age_min"],int) and d["pull"]=="ok" and len(d["main"])==7' && ok "wt-add: grava a idade do main usado (JSON: lag_min, main_age_min, pull)" || bad "wt-add: linha de log" "$LINE"
U0=$(gx "$SR" config gtremote.mirrorurl); gx "$SR" config gtremote.mirrorurl lixo; rc_is 3 "wt-add: pull que MORRE (die 3) sai com o motivo, não calado" srv wt-add wa ga-badurl; has 'url do espelho ilegível' "wt-add: diz por que o pull morreu"; gx "$SR" config gtremote.mirrorurl "$U0"
gx "$SR" worktree add -q --no-checkout -b worker/ga-half "$T/srv/git/wa/wt/ga-half" refs/remotes/origin/main; rc_is 3 "wt-add: worktree deixado pela metade (sem checkout) NÃO vira 'já existe'" srv wt-add wa ga-half; gx "$SR" worktree remove --force "$T/srv/git/wa/wt/ga-half"; gx "$SR" branch -q -D worker/ga-half
rc_is 0 "wt-add: repetir não derruba nem recria" srv wt-add wa ga-t1; has 'já existe' "wt-add: diz que já existe"; rc_is 0 "scan: com worktree continua limpo" srv scan wa
( cd "$WT" && echo 'print(3)' >> lib/a.py && git add lib/a.py && git commit -qm work && git push -q origin worker/ga-t1 2>&1 | tail -n 3 ); [ "$(gx "$MR" rev-parse refs/heads/worker/ga-t1)" = "$(gx "$WT" rev-parse HEAD)" ] && ok "push: a branch chegou ao espelho" || bad "push: não chegou ao espelho"
wait_for 40 "[ \"\$(git -C '$O' rev-parse -q --verify refs/heads/worker/ga-t1)\" = \"\$(git -C '$WT' rev-parse HEAD)\" ]" && ok "publish: a branch chegou ao origin sozinha (post-receive em segundo plano, sem nohup)" || bad "publish: não chegou ao origin" "$(tail -n 5 "$T/mh/publish.log" 2>/dev/null)"
rc_is 0 "status: nada pendente e continua PRONTO depois do push do servidor (publicar não derruba a varredura)" "$M" status wa; has 'pronto=sim' "status: pronto=sim"
SSH_ORIGINAL_COMMAND="gt-mirror-spec 'wa'" "$M" serve > /dev/null 2>&1; [ $? = 0 ] && ok "serve: o spec segue servindo depois do push" || bad "serve: spec caiu depois do push"
rc_is 0 "sync: com a branch do servidor já no origin não republica" "$M" sync wa; hasnt 'worker/ga-t1 → origin' "sync: nada a publicar de novo"

# ── J. o que o espelho recusa no push ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
push() { ( cd "$WT" && git push "$@" 2>&1 ); }
OUT=$(push origin HEAD:refs/heads/main); has 'nunca recebe push' "push: main recusada"; [ "$(gx "$O" rev-parse main)" = "$(gx "$MR" rev-parse refs/remotes/origin/main)" ] && ok "push: main do origin intacta" || bad "push: main mudou"
( cd "$WT" && git tag t1 ); OUT=$(push origin refs/tags/t1); has 'tag' "push: tag recusada"
OUT=$(push origin :worker/ga-t1); has 'apagar branch' "push: apagar recusado"; gx "$MR" rev-parse -q --verify refs/heads/worker/ga-t1 > /dev/null && ok "push: a branch continua no espelho" || bad "push: branch apagada"
OUT=$(push origin HEAD:refs/heads/hotfix/x); has 'fora dos prefixos' "push: prefixo fora da lista recusado"
GOOD=$(gx "$MR" rev-parse refs/heads/worker/ga-t1)
( cd "$WT" && git reset -q --hard HEAD~1 && echo other >> lib/a.py && git commit -qam rewrite ); OUT=$(push -f origin worker/ga-t1); has 'reescreve histórico' "push: force-push que reescreve é recusado"
( cd "$WT" && git reset -q --hard "$GOOD" && echo 'a,b' > data.csv && git add --sparse -f data.csv && git commit -qm csv ); OUT=$(push origin worker/ga-t1); has 'arquivo de dado/segredo' "push: commit com .csv recusado"; has 'data.csv' "push: diz qual arquivo"
( cd "$WT" && git reset -q --hard "$GOOD" && mkdir -p auth && echo k > auth/k2.py && git add --sparse -f auth/k2.py && git commit -qm auth ); OUT=$(push origin worker/ga-t1); has 'auth/k2.py' "push: regra de PASTA (auth/) também vale"
( cd "$WT" && git reset -q --hard "$GOOD" && mkdir -p .beads/backup && echo '{}' > .beads/backup/x.jsonl && git add --sparse -f .beads/backup/x.jsonl && git commit -qm bead ); OUT=$(push origin worker/ga-t1); has '.beads/backup/x.jsonl' "push: backup de bead (.beads/) recusado"
( cd "$WT" && git reset -q --hard "$GOOD" && git checkout -q -b side && echo s > lib/side.py && git add lib/side.py && git commit -qm side && git checkout -q worker/ga-t1 && echo m >> lib/a.py && git commit -qam mainline && git merge --no-commit --no-ff -q side > /dev/null && echo 'x,y' > evil.csv && git add --sparse -f evil.csv && git commit -qm merge-evil ); OUT=$(push origin HEAD:refs/heads/worker/ga-merge); has 'evil.csv' "push: MERGE que traz arquivo de dado só no próprio merge é recusado (git log sem --cc não listava nada do merge)"; gx "$MR" update-ref -d refs/heads/worker/ga-merge 2> /dev/null; ( cd "$WT" && git reset -q --hard "$GOOD"; git branch -q -D side )
# troca de TIPO (git status T): a base é um symlink data.csv que o espelho já tem (veio do origin; planto em refs/remotes) e o commit novo o troca por arquivo regular
TB=$(gx "$WT" commit-tree "$(printf '120000 blob %s\tdata.csv\n' "$(printf alvo | gx "$WT" hash-object -w --stdin)" | gx "$WT" mktree)" -m sym); TN=$(gx "$WT" commit-tree "$(printf '100644 blob %s\tdata.csv\n' "$(printf 'a,b\n' | gx "$WT" hash-object -w --stdin)" | gx "$WT" mktree)" -p "$TB" -m typechange)
gx "$WT" update-ref refs/tmp/plant-sym "$TB"; gx "$MR" fetch -q "$WT" refs/tmp/plant-sym:refs/remotes/origin/plant-sym; OUT=$(push origin "$TN:refs/heads/worker/ga-typechg"); has 'arquivo de dado/segredo' "push: data.csv que entra por TROCA DE TIPO (symlink → arquivo) é recusado"; has 'data.csv' "push: diz qual arquivo"
! gx "$MR" rev-parse -q --verify refs/heads/worker/ga-typechg > /dev/null && ok "push: a troca de tipo não entrou no espelho" || bad "push: a troca de tipo entrou no espelho"; gx "$MR" update-ref -d refs/remotes/origin/plant-sym; gx "$WT" update-ref -d refs/tmp/plant-sym
GB=$(echo 'print(0)' | gx "$SR" hash-object -w --stdin); GT1=$(printf '100644 blob %s\tgen.py\n' "$GB" | gx "$SR" mktree); GT2=$(printf '040000 tree %s\tscripts\n' "$GT1" | gx "$SR" mktree); GC=$(gx "$SR" commit-tree "$GT2" -m gen)
OUT=$(cd "$WT" && git push origin "$GC:refs/heads/worker/orphan-gen" 2>&1); has 'scripts/gen.py' "push: arquivo NOVO num caminho negado pela VARREDURA DE CONTEÚDO é recusado"; ! gx "$MR" rev-parse -q --verify refs/heads/worker/orphan-gen > /dev/null && ok "push: o commit órfão não entrou no espelho" || bad "push: órfão entrou"
( cd "$WT" && git reset -q --hard "$GOOD"; echo tk > src/token_helper2.py && git add src/token_helper2.py && git commit -qm ok-token-name ); OUT=$(push origin worker/ga-t1); hasnt 'recusado' "push: nome parecido com segredo mas CÓDIGO (token_helper2.py) passa"
! gx "$O" rev-parse -q --verify refs/heads/hotfix/x > /dev/null && ! gx "$O" rev-parse -q --verify refs/tags/t1 > /dev/null && ok "origin: nada recusado chegou lá" || bad "origin: recebeu coisa recusada"

# ── K. mini fora: o push espera e fica visível; volta e chega ──────────────────────────────────────────────────────────────────────────────────────────────────────────
sleep 3; mv "$O" "$O.off"; ( cd "$WT" && git reset -q --hard HEAD && echo late > lib/late.py && git add -A && git commit -qm late ); LATE=$(gx "$WT" rev-parse HEAD)
OUT=$(push origin worker/ga-t1); [ "$(gx "$MR" rev-parse refs/heads/worker/ga-t1)" = "$LATE" ] && ok "origin fora: o espelho aceita o push mesmo assim" || bad "origin fora: espelho não aceitou" "$OUT"
wait_for 30 "[ -n \"\$(git -C '$MR' config gtmirror.lastpublisherror)\" ]" && ok "origin fora: o erro de publicação fica registrado" || bad "origin fora: sem erro registrado" "$(tail -n 3 "$T/mh/publish.log")"
rc_is 1 "status: pendente é rc 1" "$M" status wa; has 'worker/ga-t1' "status: lista a branch pendente"; has lastpublisherror "status: mostra o erro"; has 'pronto=sim' "status: pendência de publicação não derruba o 'pronto'"
OUT=$(srv status wa); has PENDENTE "servidor status: a branch aparece PENDENTE"
FZ=$(gx "$SR" commit-tree "$(gx "$SR" rev-parse 'refs/remotes/origin/main^{tree}')" -p refs/remotes/origin/main -m fz); gx "$SR" update-ref refs/heads/feat/zz "$FZ"
OUT=$(srv status wa); has 'feat/zz: PENDENTE' "servidor status: branch de prefixo do rig (feat/) também é listada, não só crew/ e worker/"; gx "$SR" update-ref -d refs/heads/feat/zz
mv "$O.off" "$O"; rc_is 0 "origin de volta: sync publica" "$M" sync wa; [ "$(gx "$O" rev-parse refs/heads/worker/ga-t1)" = "$LATE" ] && ok "origin de volta: a branch chegou, sem perder nada" || bad "origin de volta: não chegou"
rc_is 0 "status: limpo depois de publicar" "$M" status wa; rc_is 0 "pull: servidor puxa" srv pull wa; OUT=$(srv status wa); has 'worker/ga-t1: publicada no origin' "servidor status: agora publicada"; has 'sem trabalho novo' "servidor status: branch sem commit novo não é pendente"

# ── M. o origin reescreveu a branch (o gate rebaseia): o dog que conserta sobre a ponta velha é AVISADO, nada é publicado em silêncio, e o espelho traz a ponta nova (ga-jgxgn6) ───────────────
# o caso de 19/10 (ga-2hd02v.1.12): o gate rebaseou fix/... no origin; o dog consertou sobre a ponta velha e empurrou; o espelho não publicou (não é fast-forward) e não avisou ninguém
gate_rewrite() { local br=$1 tag=$2; ( cd "$W" && git fetch -q origin "refs/heads/$br" && git checkout -q -B "gate-$tag" FETCH_HEAD~1 && echo "gate $tag" > "lib/gate-$tag.py" && git add "lib/gate-$tag.py" && git commit -qm "gate rebase $tag" && git push -q -f origin "gate-$tag:refs/heads/$br"; git checkout -q main ) > /dev/null 2>&1; gx "$O" rev-parse "refs/heads/$br"; }   # o "gate": reescreve a branch no origin (mesmo pai, commit novo) e imprime a ponta nova
REW=$(gate_rewrite worker/ga-t1 a); [ -n "$REW" ] && [ "$REW" != "$LATE" ] && ! gx "$O" merge-base --is-ancestor "$LATE" "$REW" && ok "gate: o origin tem a branch REESCRITA (a ponta que o dog tem não é ancestral dela)" || bad "fixture: a reescrita do gate não saiu como devia" "$REW"
( cd "$WT" && echo stale-fix >> lib/a.py && git commit -qam "fix on the old tip" ); STALE=$(gx "$WT" rev-parse HEAD)
OUT=$(push origin worker/ga-t1); has 'o origin tem' "reescrita: o push feito sobre a ponta velha é RECUSADO na hora (não é aceito em silêncio)"; has "$REW" "reescrita: a mensagem traz o sha que o origin tem (o que o gate revisou)"; has 'Rebase sobre origin/worker/ga-t1' "reescrita: diz o que fazer"
[ "$(gx "$MR" rev-parse refs/heads/worker/ga-t1)" != "$STALE" ] && ok "reescrita: o espelho NÃO guardou o push condenado (não nasce ponta morta; a ponta é a de antes ou a do gate, se o sync da recusa já rodou)" || bad "reescrita: o espelho guardou o push" "$(gx "$MR" rev-parse refs/heads/worker/ga-t1)"
[ "$(gx "$O" rev-parse refs/heads/worker/ga-t1)" = "$REW" ] && ok "reescrita: o origin segue com a ponta do gate (nada foi publicado por cima)" || bad "reescrita: o origin mudou" "$(gx "$O" rev-parse refs/heads/worker/ga-t1)"
wait_for 90 "[ \"\$(git -C '$MR' rev-parse -q --verify refs/heads/worker/ga-t1)\" = '$REW' ]" && ok "reescrita: o espelho trouxe a ponta do gate e alinhou a branch (sync em segundo plano, disparado pela recusa)" || bad "reescrita: o espelho não alinhou a branch à ponta do gate" "$(tail -n 5 "$T/mh/publish.log")"
rc_is 0 "reescrita: o servidor puxa" srv pull wa; has 'resultado=ok' "reescrita: pull ok"
[ "$(gx "$SR" rev-parse -q --verify refs/remotes/origin/worker/ga-t1)" = "$REW" ] && ok "reescrita: o servidor vê origin/worker/ga-t1 = o sha que o gate revisou" || bad "reescrita: o servidor não vê a ponta do gate" "$(gx "$SR" rev-parse -q --verify refs/remotes/origin/worker/ga-t1)"
( cd "$WT" && git reset -q --hard refs/remotes/origin/worker/ga-t1 && echo fix >> lib/a.py && git commit -qam "fix on the gate tip" ); FIX=$(gx "$WT" rev-parse HEAD)
OUT=$(push origin worker/ga-t1); hasnt 'recusado' "reescrita: o conserto feito sobre a ponta do gate entra (fast-forward)"; hasnt 'AVISO' "reescrita: e sem aviso nenhum"
wait_for 60 "[ \"\$(git -C '$O' rev-parse refs/heads/worker/ga-t1)\" = '$FIX' ]" && ok "reescrita: o conserto chegou ao origin sobre a ponta do gate" || bad "reescrita: o conserto não chegou ao origin" "$(tail -n 5 "$T/mh/publish.log")"
# o post-receive sozinho (o origin pode mudar ENTRE o pre e o post: chamada direta, com a ponta velha como "push aceito"): avisa no stderr do push e não finge que publica
N0=$(grep -c 'sync wa: ok' "$T/mh/publish.log")
OUT=$( cd "$MR" && printf '%s %s %s\n' "$FIX" "$LATE" refs/heads/worker/ga-t1 | GIT_DIR=. "$MR/hooks/post-receive" 2>&1 ); RCP=$?
[ $RCP = 0 ] && ok "post-receive: com a ponta do origin fora do push, sai 0 (o push já foi aceito)" || bad "post-receive: rc=$RCP" "$OUT"; has 'AVISO' "post-receive: AVISA que a publicação será recusada"; has "o origin tem $FIX" "post-receive: diz o sha que o origin tem"; has 'NÃO será publicado' "post-receive: não finge que a publicação segue em segundo plano"; hasnt 'segue em segundo plano' "post-receive: sem a frase tranquilizadora"
wait_for 90 "[ \$(grep -c 'sync wa: ok' '$T/mh/publish.log') -gt $N0 ]" && ok "post-receive: o aviso dispara o sync que traz a ponta do origin" || bad "post-receive: o sync não rodou" "$(tail -n 5 "$T/mh/publish.log")"
# o caso de verdade, ponta a ponta: o origin está mudo na hora do push (o hook não consegue perguntar e aceita), o gate reescreve depois, e o publish recusado tem de ser DITO (log, status), nunca calado
sleep 2; mv "$O" "$O.off"; ( cd "$WT" && echo late2 >> lib/a.py && git commit -qam "fix while origin is mute" ); DEAD=$(gx "$WT" rev-parse HEAD)
OUT=$(push origin worker/ga-t1); has 'não consegui conferir' "origin mudo: o push é aceito e o hook diz que NÃO conferiu ('não sei' não vira 'ok')"; [ "$(gx "$MR" rev-parse refs/heads/worker/ga-t1)" = "$DEAD" ] && ok "origin mudo: o espelho aceitou o push (o estado de antes)" || bad "origin mudo: o espelho não aceitou" "$OUT"
wait_for 30 "[ -n \"\$(git -C '$MR' config gtmirror.lastpublisherror)\" ]" && ok "origin mudo: a publicação falha e o erro fica registrado" || bad "origin mudo: sem erro registrado" "$(tail -n 3 "$T/mh/publish.log")"
mv "$O.off" "$O"; REW2=$(gate_rewrite worker/ga-t1 b); [ -n "$REW2" ] && [ "$REW2" != "$FIX" ] && ! gx "$O" merge-base --is-ancestor "$FIX" "$REW2" && ok "gate: reescreveu de novo enquanto o dog consertava sobre a ponta velha" || bad "fixture: 2ª reescrita" "$REW2"
rc_is 1 "publish recusado por não ser fast-forward: sync sai com rc 1 (visível)" "$M" sync wa; has "o origin tem $REW2" "publish recusado: o motivo diz o sha que o origin tem, não só 'rejected'"; has 'Rebase sobre origin/worker/ga-t1' "publish recusado: diz o que fazer"
[ "$(gx "$O" rev-parse refs/heads/worker/ga-t1)" = "$REW2" ] && ok "publish recusado: nada foi publicado em silêncio (o origin segue com a ponta do gate)" || bad "publish recusado: o origin mudou" "$(gx "$O" rev-parse refs/heads/worker/ga-t1)"
rc_is 1 "status: a branch condenada é pendente (rc 1)" "$M" status wa; has 'worker/ga-t1' "status: lista a branch"; has "o origin tem $REW2" "status: lastpublisherror traz o motivo e o sha do origin"
# a saída para quem caiu nisso: refazer sobre a ponta do origin e empurrar com OUTRO nome (a mesma ainda guarda a ponta morta); a recusa diz isso
rc_is 0 "o servidor puxa a ponta do gate" srv pull wa; OUT=$(srv status wa); has 'worker/ga-t1: PENDENTE e DIVERGE de origin/worker/ga-t1' "servidor status: diz que o branch DIVERGE do origin (não só PENDENTE)"
( cd "$WT" && git reset -q --hard refs/remotes/origin/worker/ga-t1 && echo v2 >> lib/a.py && git commit -qam v2 )
OUT=$(push origin worker/ga-t1); has 'non-fast-forward' "ponta morta: o refeito com o mesmo nome é recusado já no cliente (o espelho guarda a ponta velha)"
OUT=$(push -f origin worker/ga-t1); has 'reescreve histórico' "ponta morta: com force o espelho recusa a reescrita"; has 'git fetch origin' "ponta morta: a recusa manda trazer o origin e refazer sobre ele"
OUT=$(push origin HEAD:refs/heads/worker/ga-t1-v2); hasnt 'recusado' "ponta morta: com outro nome o refeito entra"
wait_for 60 "[ \"\$(git -C '$O' rev-parse -q --verify refs/heads/worker/ga-t1-v2)\" = \"\$(git -C '$WT' rev-parse HEAD)\" ]" && ok "ponta morta: o refeito chegou ao origin" || bad "ponta morta: o refeito não chegou ao origin" "$(tail -n 5 "$T/mh/publish.log")"
( cd "$WT" && git reset -q --hard "$REW2" )

# ── L. remover worktree libera espaço; tudo limpo no fim ───────────────────────────────────────────────────────────────────────────────────────────────────────────────
rc_is 0 "wt-rm: remove o worktree" srv wt-rm wa ga-t1; has 'liberou' "wt-rm: informa o espaço liberado"; [ ! -e "$WT" ] && ok "wt-rm: o diretório sumiu" || bad "wt-rm: diretório ficou"
rc_is 2 "wt-rm: de novo → erro (não finge que removeu)" srv wt-rm wa ga-t1; rc_is 0 "scan final: limpo" srv scan wa

echo; echo "selftest: $N casos, $F falha(s)$([ -n "$FAKE" ] && echo " (modo HMST_FAKE: o sshd real NÃO foi testado)")"; [ "$F" = 0 ]
