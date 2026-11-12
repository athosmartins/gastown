#!/usr/bin/env bash
# hetzner-dados.selftest.sh — hermético: wrapper, canal do mini, varredura, entrypoint de prova e prova do runner rodam em cópias com os caminhos trocados e ip/nft/setpriv/findmnt/ps/sudo como stubs (ga-qg1dw5z.1).
#
# ## Contents
#   Casos · Mutantes · O que este teste NÃO prova
#
# CASOS: gt-dados-run (quem chama, nome fora da lista/ilegível/substring, entrypoint que não é de root, staging que não é tmpfs, swap ligada/ilegível, lock ocupado, montagem do netns, setpriv/env -i, o dado some e o
#   resultado fica, falha do entrypoint, apagar que falha → 99, TERM) · gt-dados-ingest (verbos, nome, tmpfs, put/replace/link simbólico/tar quebrado, get presente/ausente, clean, status) · gt-dados-sweep (LIMPO, PULADO,
#   processo velho morto, ps que falha, stage fora do tmpfs, sobra, lock do wrapper tomado (com e sem processo de dados), lock 0600, prazo do find estourado, entrada que sumiu, erro de leitura) · synth (quem roda, saída de rede aberta) · prove (ok, vazamento, não instalado, grupo, sudo, fora-da-lista, build sem prova).
# MUTANTES: cada guarda é removida numa cópia e algum caso TEM de reprovar (caso que passa no mutante não pega o bug).
# O QUE NÃO PROVA: que o kernel isola, que o sshd aceita a chave, que o sudo recusa. Isso é o `hetzner-dados-prove.sh` no nó, depois da instalação por root (runbook hetzner-dados.md).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/hzdados-selftest.XXXXXX")
trap 'chmod -R u+rwx "$T" 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
S="$T/stage"; LOG="$T/log"; OUT="$T/out"; ERR="$T/err"; ME=$(id -un)
mkdir -p "$T/stubs" "$T/app/bin" "$T/etc-netns"
cat > "$T/stubs/ip" <<'EOF'
#!/usr/bin/env bash
echo "ip $*" >> "$LOG"
case "$*" in
  "netns add "*) [ "${FAIL_STEP:-}" = netns-add ] && exit 1 ;;
  "-n "*" link set lo up") [ "${FAIL_STEP:-}" = lo ] && exit 1 ;;
  "-n "*" link add gtn0 "*) [ "${FAIL_STEP:-}" = gtn0 ] && exit 1 ;;
  "netns pids "*) cat "$T/pids" 2>/dev/null; exit 0 ;;
  "netns exec "*) shift 3; exec "$@" ;;
esac
exit 0
EOF
cat > "$T/stubs/nft" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-f -") cat > "$T/rules"; [ "${FAIL_STEP:-}" = nft ] && exit 1; exit 0 ;;
  "list chain inet gtn out") [ "${FAIL_STEP:-}" = nft-regra ] || echo "chain out { counter name egress reject }" ;;
  "list counter inet gtn egress") case "${CNT_MODE:-3}" in garbage) echo boom ;; *) echo "counter egress { packets ${CNT_MODE:-3} bytes 180 }" ;; esac ;;
esac
EOF
cat > "$T/stubs/setpriv" <<'EOF'
#!/usr/bin/env bash
echo "setpriv $*" >> "$LOG"; echo "IN=$(find "$STAGE_T/in" -type f | wc -l | tr -d ' ')" >> "$LOG"
if [ "${LINK_IN:-}" = 1 ]; then find "$STAGE_T/in" -mindepth 1 -delete; rmdir "$STAGE_T/in"; ln -s "$T/victim" "$STAGE_T/in"; fi
if [ "${SLOW:-}" = 1 ]; then sleep 20 & sp=$!; trap 'echo got-term >> "$LOG"; kill $sp 2>/dev/null; exit 143' TERM; echo started >> "$LOG"; wait $sp; fi
exit "${CMD_RC:-0}"
EOF
printf '#!/usr/bin/env bash\necho "timeout $*" >> "$LOG"; [ -z "${TIMEOUT_RC:-}" ] || exit "$TIMEOUT_RC"; shift 3; exec "$@"\n' > "$T/stubs/timeout"
cat > "$T/stubs/find" <<'EOF'
#!/usr/bin/env bash
# repassa ao find de verdade; FIND_NOISE simula o que o /tmp vivo do nó faz: entrada que sumiu no meio da leitura (rc 1) ou erro de verdade
/usr/bin/find "$@"; rc=$?
case "${FIND_NOISE:-}" in
  enoent) echo "find: '/tmp/x': No such file or directory" >&2; exit 1 ;;
  eacces) echo "find: '/tmp/y': Permission denied" >&2; exit 1 ;;
  masked) echo "find: '/tmp/No such file or directory/z': Permission denied" >&2; exit 1 ;;
  countfail) case " $* " in *" -delete "* | *" -print "* | *" -exec "*) ;; *) echo "find: '$1/x': Permission denied" >&2; exit 1 ;; esac ;;
esac
exit $rc
EOF
printf '#!/usr/bin/env bash\ncase "$*" in *OPTIONS*) echo "${FS:-tmpfs} rw,nosuid,nodev,noexec,relatime" ;; *) echo "${FS:-tmpfs}" ;; esac\n' > "$T/stubs/findmnt"
printf '#!/usr/bin/env bash\n[ "${NOMNT:-}" = 1 ] && exit 1; exit 0\n' > "$T/stubs/mountpoint"
printf '#!/usr/bin/env bash\ncase "$*" in "-u dados") echo "${DUID:-1234}" ;; "-g dados") echo "${DGID:-1234}" ;; "-un") echo "${ID_UN:-dados}" ;; "-nG") echo "${ID_G:-runner}" ;; *) exec /usr/bin/id "$@" ;; esac\n' > "$T/stubs/id"
printf '#!/usr/bin/env bash\n[ "${PS_FAIL:-}" = 1 ] && exit 1; if [ -n "${PS_SECOND:-}" ] && [ -e "$T/ps.n" ]; then printf "%%s\\n" "$PS_SECOND"; else : > "$T/ps.n"; cat "$T/ps"; fi\n' > "$T/stubs/ps"
cat > "$T/stubs/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >> "$LOG"
case "$*" in
  "-n -u dados true") [ "${SUDO_AS_DADOS:-}" = 1 ] && exit 0; echo "sudo: a password is required" >&2; exit 1 ;;
  "-n /usr/local/sbin/gt-dados-run __fora-da-lista__") [ "${SUDO_LIST_LEAK:-}" = 1 ] && { echo "GTD-RUN: ok ns=x"; exit 0; }; echo "sudo: a password is required" >&2; exit 1 ;;
  "-n /usr/local/sbin/gt-dados-run synth") printf '%b\n' "${SYNTH_OUT:-synth: ok files=5\nGTD-EGRESS: attempts=3\nGTD-WIPE: ok}"; exit "${SYNTH_RC:-0}" ;;
esac
EOF
printf '#!/usr/bin/env bash\ncase "$2" in /home/dados|/srv/gtdados/in) case "${LS_MODE:-denied}" in denied) echo "ls: cannot open directory $2: Permission denied" >&2; exit 2 ;; missing) echo "ls: cannot access $2: No such file or directory" >&2; exit 2 ;; leak) echo secret; exit 0 ;; esac ;; esac\nexit 0\n' > "$T/stubs/ls"
printf '#!/usr/bin/env bash\necho "chown $*" >> "$LOG"; [ "${FAIL_STEP:-}" = chown ] && exit 1; exit 0\n' > "$T/stubs/chown"
chmod +x "$T/stubs/"*
export LOG T STAGE_T="$S" GTD_TEST_ETC="$T/etc-netns" GTD_TEST_OWNER="$ME"
mkcopy() { # <origem> <destino> [sed extra]
  sed -e "s#^PATH=/usr/sbin:/usr/bin:/sbin:/bin\$#PATH=$T/stubs:/usr/bin:/bin#" -e "s#^PATH=/usr/bin:/bin\$#PATH=$T/stubs:/usr/bin:/bin#" -e "s#STAGE=/srv/gtdados#STAGE=$S#" -e "s#LIST=/etc/gt-dados/entrypoints#LIST=$T/list#" \
      -e "s#APP=/opt/gt-dados/app/bin#APP=$T/app/bin#" -e "s#LOCK=/run/gt-dados-run.lock#LOCK=$T/lock#" -e "s#SWAPS=/proc/swaps#SWAPS=$T/swaps#" -e 's#/etc/netns#${GTD_TEST_ETC}#g' -e 's#-user root#-user ${GTD_TEST_OWNER}#g' \
      -e "s#DU=dados; STAGE=$S; DHOME=/home/dados; LOG=/var/log/gt-dados-sweep.log#DU=$ME; STAGE=$S; DHOME=$T/dhome; LOG=$T/sweep.log#" -e "s#for d in /tmp /var/tmp /dev/shm#for d in $T/tmp1 $T/tmp2#" -e "s#LOCKWAIT=10#LOCKWAIT=1#" -e "s#TOPONLY=/tmp#TOPONLY=$T/tmp1#" \
      -e "s#^RUN=/usr/local/sbin/gt-dados-run#RUN=/usr/local/sbin/gt-dados-run#" ${3:+-e "$3"} "$1" > "$2"; chmod +x "$2"; }
for p in run ingest sweep synth prove; do mkcopy "$HERE/hetzner-dados-$p.sh" "$T/$p.sh"; done
n=0; fails=0; BAD=0; QUIET=0
ck() { local l=$1; shift; [ "$QUIET" = 1 ] || n=$((n+1)); if "$@"; then [ "$QUIET" = 1 ] || echo "ok   $l"; else [ "$QUIET" = 1 ] || { echo "FAIL $l"; fails=$((fails+1)); }; BAD=1; fi; }
rcis() { [ "$RC" = "$1" ]; }; order() { local prev=0 p pat; for pat in "$@"; do p=$(grep -n -E -- "$pat" "$LOG" | head -n 1 | cut -d: -f1); [ -n "$p" ] && [ "$p" -gt "$prev" ] || return 1; prev=$p; done; }; has() { grep -q -E -- "$2" "$1"; }; hasnt() { ! grep -q -E -- "$2" "$1"; }
ck "as cópias testadas só trocam caminhos, PATH e usuário (nada de lógica)" test "$(for p in run ingest sweep synth prove; do diff "$HERE/hetzner-dados-$p.sh" "$T/$p.sh"; done | grep '^<' | grep -v -c -e 'PATH=' -e 'STAGE=' -e '/etc/netns' -e '-user root' -e 'for d in /tmp' -e '^< DU=dados; STAGE')" = 0
fresh() { find "$T" -maxdepth 1 \( -name stage -o -name dhome -o -name tmp1 -o -name tmp2 \) -exec chmod -R u+rwx {} + 2>/dev/null; find "$S" "$T/dhome" "$T/tmp1" "$T/tmp2" -mindepth 0 -delete 2>/dev/null
  mkdir -p "$S/in" "$S/out" "$T/dhome" "$T/tmp1" "$T/tmp2"; : > "$LOG"; echo "${PIDS:-}" > "$T/pids"; : > "$T/rules"; printf 'Filename Type Size Used Priority\n' > "$T/swaps"; echo synth > "$T/list"; printf '#!/bin/sh\n' > "$T/app/bin/synth"; chmod 755 "$T/app/bin/synth"; chmod 755 "$T/app/bin" "$T/app"; }
seed() { mkdir -p "$S/in/proj" "$S/out/proj"; echo "CPF 000" > "$S/in/proj/dado.txt"; echo "resultado" > "$S/out/proj/r.txt"; }
go() { local s=$1; shift; fresh; [ -z "${SEED-1}" ] || seed; env SUDO_UID="${SUDO_UID-1000}" ${GTD_X:+bash -x} "$s" "$@" > "$OUT" 2> "$ERR"; RC=$?; [ -z "${GTD_DEBUG:-}" ] || { echo "--- go $*: rc=$RC"; cat "$ERR"; }; }
SP='^setpriv '
case_run() { local s=$1
  SUDO_UID= go "$s" synth; ck "run: sem SUDO_UID → 64" rcis 64; SUDO_UID=0 go "$s" synth; ck "run: root puro → 64" rcis 64; go "$s"; ck "run: sem entrypoint → 64" rcis 64; go "$s" synth extra; ck "run: 2 argumentos → 64" rcis 64
  for nm in ../x -x .x A 'a b'; do go "$s" "$nm"; ck "run: nome '$nm' → 64" rcis 64; done
  fresh; echo synth2 > "$T/list"; SUDO_UID=1000 "$s" synth > "$OUT" 2> "$ERR"; RC=$?; ck "run: 'synth' não casa a linha 'synth2' da lista → 64" rcis 64
  fresh; rm -f "$T/list"; SUDO_UID=1000 "$s" synth > "$OUT" 2> "$ERR"; RC=$?; ck "run: lista ilegível → recusa (64), não 'livre'" rcis 64; ck "run: lista ilegível: nada montou" hasnt "$LOG" 'netns add'
  GTD_TEST_OWNER=nobody go "$s" synth; ck "run: entrypoint que não é de root → 98" rcis 98; ck "run: ...e não roda" hasnt "$LOG" "$SP"
  fresh; chmod 775 "$T/app/bin/synth"; SUDO_UID=1000 "$s" synth > "$OUT" 2> "$ERR"; RC=$?; ck "run: entrypoint gravável pelo grupo → 98" rcis 98
  FS=ext4 go "$s" synth; ck "run: staging em ext4 → 98 stage-nao-e-tmpfs" rcis 98; ck "run: ...com o motivo" has "$ERR" 'recusado:stage-nao-e-tmpfs'; ck "run: ...e o dado seguiu intacto" test -f "$S/in/proj/dado.txt"
  NOMNT=1 go "$s" synth; ck "run: tmpfs sem montagem própria → 98" rcis 98
  fresh; printf 'h\n/dev/sda2 partition 1 0 -2\n' > "$T/swaps"; SUDO_UID=1000 "$s" synth > "$OUT" 2> "$ERR"; RC=$?; ck "run: swap ligada → 98" rcis 98; ck "run: ...swap-ligada-ou-ilegivel" has "$ERR" 'swap-ligada'
  fresh; rm -f "$T/swaps"; SUDO_UID=1000 "$s" synth > "$OUT" 2> "$ERR"; RC=$?; ck "run: /proc/swaps ilegível → 98 (não 'sem swap')" rcis 98
  fresh; seed; ( exec 8> "$T/lock"; flock -n 8; sleep 3 ) & local hp=$!; sleep 0.5; SUDO_UID=1000 "$s" synth > "$OUT" 2> "$ERR"; RC=$?; wait $hp 2>/dev/null; ck "run: outra rodada em andamento → 98 ocupado" rcis 98; ck "run: ...e o dado dela não foi tocado" test -f "$S/in/proj/dado.txt"
  CMD_RC=7 go "$s" synth; ck "run ok: rc do entrypoint (7)" rcis 7; ck "run ok: avisa o netns" has "$ERR" '^GTD-RUN: ok ns=gtd[0-9]+ entrypoint=synth'; ck "run ok: contador" has "$ERR" '^GTD-EGRESS: attempts=3$'; ck "run ok: GTD-WIPE ok" has "$ERR" '^GTD-WIPE: ok$'
  ck "run ok: setpriv com uid/gid de dados, sem grupos, sem capacidades, no-new-privs" has "$LOG" '^setpriv --reuid=1234 --regid=1234 --clear-groups --no-new-privs --inh-caps=-all --bounding-set=-all -- /usr/bin/env -i HOME=/home/dados PATH=[^ ]+ LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 GT_DADOS_STAGE='
  ck "run ok: prazo de 2 h (timeout)" has "$LOG" '^timeout -k 10 7200 '; ck "run ok: o dado EXISTIA durante o build (IN=1)" has "$LOG" '^IN=1$'
  ck "run ok: o dado sumiu depois" test -z "$(find "$S/in" -mindepth 1)"; ck "run ok: o resultado em out/ ficou para o mini" test -f "$S/out/proj/r.txt"
  ck "run ok: ordem netns, lo, gtn0, rota, setpriv, limpeza" order '^ip netns add gtd' 'link set lo up' 'link add gtn0 type dummy' 'route add default via 192\.0\.2\.1' "$SP" '^ip netns del gtd'
  sleep 100 & local sp=$!; PIDS=$sp go "$s" synth; sleep 0.2; ck "run: processo que sobrou no netns é morto antes de apagar o dado" bash -c "! kill -0 $sp 2>/dev/null"; kill -9 $sp 2>/dev/null
  ck "run ok: regra do nft (drop, lo aceito, o resto rejeitado com contador)" bash -c "grep -c 'policy drop' '$T/rules' | grep -q 2 && grep -q 'oifname \"lo\" accept' '$T/rules' && grep -q 'counter name egress reject' '$T/rules'"
  CMD_RC=5 go "$s" synth; ck "run: entrypoint que falha (5): rc 5 e o dado sumiu mesmo assim" rcis 5; ck "run: ...in/ vazio" test -z "$(find "$S/in" -mindepth 1)"
  CNT_MODE=garbage go "$s" synth; ck "run: contador ilegível → '?', nunca 0" has "$ERR" '^GTD-EGRESS: attempts=\?$'
  for st in netns-add lo gtn0 nft nft-regra; do FAIL_STEP=$st go "$s" synth; ck "run: falha em $st → 98, entrypoint NÃO roda, dado intacto" bash -c "[ $RC = 98 ] && ! grep -q '$SP' '$LOG' && [ -f '$S/in/proj/dado.txt' ]"; done
  if [ "$(id -u)" != 0 ]; then fresh; seed; mkdir -p "$S/in/proj/trava"; echo x > "$S/in/proj/trava/f"; chmod 555 "$S/in/proj/trava"; SUDO_UID=1000 "$s" synth > "$OUT" 2> "$ERR"; RC=$?
    ck "run: apagar in/ falha → 99 mesmo com entrypoint ok" rcis 99; ck "run: ...GTD-WIPE falhou" has "$ERR" '^GTD-WIPE: falhou'; chmod -R u+rwx "$S"; fi
  fresh; find "$S/in" -delete 2>/dev/null; SUDO_UID=1000 "$s" synth > "$OUT" 2> "$ERR"; RC=$?; ck "run: in/ recriado quando faltava (mkdir + chown -h, nunca install -d)" test -d "$S/in"; ck "run: ...com chown -h (não segue link) para dados:dados" has "$LOG" '^chown -h dados:dados .*/in$'
  fresh; find "$S/in" "$S/out" -delete 2>/dev/null; FAIL_STEP=chown SUDO_UID=1000 "$s" synth > "$OUT" 2> "$ERR"; RC=$?; ck "run: chown falhou → 98 stage-dirs e o entrypoint NÃO roda" bash -c "[ $RC = 98 ] && grep -q 'recusado:stage-dirs' '$ERR' && ! grep -q '$SP' '$LOG'"; }
# revisão do gate 12/11: o build (dados) troca in/ ou out/ por link para um diretório de FORA; root não pode dar chown/chmod nele (dados → root por /usr/local/sbin)
vmode() { stat -c %a "$T/victim" 2> /dev/null || stat -f %Lp "$T/victim"; }
lnk() { local nm=$1 kind=$2; fresh; seed; find "$T/victim" -mindepth 0 -delete 2>/dev/null; mkdir -p "$T/victim"; chmod 755 "$T/victim"; echo keep > "$T/victim/sentinela"; find "$S/$nm" -delete 2>/dev/null
  case $kind in link) ln -s "$T/victim" "$S/$nm" ;; solto) ln -s "$T/nao-existe" "$S/$nm" ;; arquivo) echo x > "$S/$nm" ;; esac; }
case_link() { local s=$1 nm kind
  for nm in in out; do for kind in link solto arquivo; do lnk "$nm" "$kind"; SUDO_UID=1000 "$s" synth > "$OUT" 2> "$ERR"; RC=$?
    ck "run: $nm/ é $kind → 98 stage-dirs, o entrypoint NÃO roda" bash -c "[ $RC = 98 ] && grep -q 'recusado:stage-dirs' '$ERR' && ! grep -q '$SP' '$LOG'"
    ck "run: $nm/ é $kind → nenhum chown/chmod/mkdir de root" hasnt "$LOG" '^chown '
    [ "$kind" != link ] || ck "run: $nm/ link → o diretório de fora ficou intacto (modo 755, sentinela, dono)" bash -c "[ \"$(vmode)\" = 755 ] && [ -f '$T/victim/sentinela' ]"; done; done
  # o build troca in/ por link DURANTE a rodada: apagar não pode virar "ok" (find não entra em link dado como ponto de partida)
  fresh; seed; find "$T/victim" -mindepth 0 -delete 2>/dev/null; mkdir -p "$T/victim"; chmod 755 "$T/victim"; echo keep > "$T/victim/sentinela"; LINK_IN=1 SUDO_UID=1000 "$s" synth > "$OUT" 2> "$ERR"; RC=$?
  ck "run: in/ virou link durante o build → 99 GTD-WIPE falhou (nunca ok)" bash -c "[ $RC = 99 ] && grep -q '^GTD-WIPE: falhou' '$ERR' && ! grep -q '^GTD-WIPE: ok' '$ERR'"; ck "run: ...e o alvo do link não foi tocado" bash -c "[ -f '$T/victim/sentinela' ] && [ \"$(vmode)\" = 755 ]"; }
case_lock() { local s=$1; fresh; seed; chmod 644 "$T/lock" 2> /dev/null; SUDO_UID=1000 "$s" synth > "$OUT" 2> "$ERR"; RC=$?; ck "run: lock vira 0600 (era 0644) e o build roda" bash -c "[ $RC = 0 ] && [ -n \"\$(find '$T/lock' -perm 600)\" ]"
  fresh; seed; rm -f "$T/lock"; SUDO_UID=1000 "$s" synth > "$OUT" 2> "$ERR"; RC=$?; ck "run: lock criado do zero nasce 0600" bash -c "[ $RC = 0 ] && [ -n \"\$(find '$T/lock' -perm 600)\" ]"; }
case_signal() { local s=$1; fresh; seed; : > "$LOG"; env SLOW=1 SUDO_UID=1000 "$s" synth > "$OUT" 2> "$ERR" & local hp=$! i=0
  while ! grep -q '^started$' "$LOG" 2>/dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done; kill -TERM "$hp" 2>/dev/null; wait "$hp"; RC=$?
  [ -z "${GTD_DEBUG:-}" ] || { cat "$ERR" "$LOG"; }
  ck "run: TERM chega ao entrypoint" has "$LOG" '^got-term$'; ck "run: TERM: o dado some" test -z "$(find "$S/in" -mindepth 1)"; ck "run: TERM: o netns foi desfeito" has "$LOG" '^ip netns del gtd'; }
tarof() { ( cd "$1" && tar -c . ); }
case_ingest() { local s=$1 src="$T/src"; find "$src" -mindepth 0 -delete 2>/dev/null; mkdir -p "$src/sub"; echo "lote 1" > "$src/sub/a.txt"; echo b > "$src/b.txt"
  ing() { local cmd=$1; shift; fresh; [ -z "${SEED-1}" ] || seed; SSH_ORIGINAL_COMMAND="$cmd" "$s" "$@" > "$OUT" 2> "$ERR" < "${IN:-/dev/null}"; RC=$?; }
  for c in "rm -rf /" "" "put" "put ../x" "put A" "put a b" "get" "get a/b" "clean ../x" "status x" "bash"; do SEED= ing "$c"; ck "ingest: '$c' → 64" rcis 64; done
  tarof "$src" > "$T/in.tar"; IN="$T/in.tar" SEED= ing "put proj"; ck "ingest put: rc 0" rcis 0; ck "ingest put: arquivos em in/proj" test -f "$S/in/proj/sub/a.txt"; ck "ingest put: conta" has "$OUT" 'put proj ok files=2'
  FS=ext4 IN="$T/in.tar" SEED= ing "put proj"; ck "ingest put: staging fora do tmpfs → 98 e NADA gravado" bash -c "[ $RC = 98 ] && [ -z \"\$(find '$S/in' -mindepth 1)\" ]"
  IN="$T/in.tar" ing "put proj"; ck "ingest put: substitui o que havia (dado.txt antigo some)" test ! -e "$S/in/proj/dado.txt"
  ln -s /etc/passwd "$src/elo"; tarof "$src" > "$T/link.tar"; IN="$T/link.tar" SEED= ing "put proj"; ck "ingest put: link simbólico no tar → 65, e NADA ficou" bash -c "[ $RC = 65 ] && [ ! -e '$S/in/proj' ]"; rm -f "$src/elo"
  echo "isto não é um tar" > "$T/bad.tar"; IN="$T/bad.tar" SEED= ing "put proj"; ck "ingest put: tar quebrado → rc≠0 e NADA ficou" bash -c "[ $RC != 0 ] && [ ! -e '$S/in/proj' ]"
  ing "get proj"; ck "ingest get: devolve o tar do resultado" bash -c "tar -t < '$OUT' | grep -q r.txt"; SEED= ing "get nada"; ck "ingest get: ausente → 66 e stdout vazio (não um tar vazio)" bash -c "[ $RC = 66 ] && [ ! -s '$OUT' ]"
  ing "clean proj"; ck "ingest clean <nome>: apaga in e out desse nome" test ! -e "$S/in/proj" -a ! -e "$S/out/proj"; mkdir -p "$S/in/outro"; seed; ing "clean"; ck "ingest clean (tudo): in/ e out/ somem" test ! -e "$S/in/proj" -a ! -e "$S/out/proj"
  ing "status"; ck "ingest status: conta in/out" has "$OUT" 'tmpfs=sim in=1 out=1'
  FIND_NOISE=eacces ing "status"; ck "ingest status: find que falha → '?' e rc 74 (nunca 0 itens)" bash -c "[ $RC = 74 ] && grep -q 'in=? out=?' '$OUT'"; SEED= ing "status"; ck "ingest status: nada em in/ e out/ → 0 e 0 (diferente de '?')" has "$OUT" 'in=0 out=0'
  # o tar do remetente que morre antes de listar nada deixa um arquivo VÁLIDO e vazio (só blocos de zeros): `tar -x` sai 0 sem extrair nada (um stream de 0 byte já sai 2 sozinho, caso do "tar quebrado")
  head -c 10240 /dev/zero > "$T/empty.tar"; IN="$T/empty.tar" SEED= ing "put proj"; ck "ingest put: arquivo tar válido e vazio (o tar do remetente morreu) → 67, nada ficou, nunca 'ok files=0'" bash -c "[ $RC = 67 ] && [ ! -e '$S/in/proj' ] && ! grep -q 'ok files' '$OUT'"
  if [ "$(id -u)" != 0 ]; then fresh; seed; chmod 555 "$S/in/proj"; SSH_ORIGINAL_COMMAND="clean proj" "$s" > "$OUT" 2> "$ERR"; RC=$?; ck "ingest clean: não consegui apagar → 99 (nunca 'ok')" rcis 99; chmod -R u+rwx "$S"
    fresh; seed; chmod 555 "$S/in/proj"; SSH_ORIGINAL_COMMAND="clean" "$s" > "$OUT" 2> "$ERR"; RC=$?; ck "ingest clean (tudo): in/ resistiu → 99, mas out/ foi apagado mesmo assim (não para no 1º que sobrou)" bash -c "[ $RC = 99 ] && [ ! -e '$S/out' ]"; chmod -R u+rwx "$S"; fi; }
sw() { fresh; rm -f "$T/ps.n"; seed; mkdir -p "$S/in/x"; echo d > "$T/dhome/cache"; echo t > "$T/tmp1/$ME-file"; mkdir -p "$T/tmp1/$ME-dir/sub"; echo n > "$T/tmp1/$ME-dir/sub/f"; echo v > "$T/tmp2/$ME-file"; printf '%s\n' "${PS_ROWS:-}" > "$T/ps"; "$1" > "$OUT" 2> "$ERR"; RC=$?; }
case_sweep() { local s=$1 row_new="$ME 60 99999"
  PS_ROWS="root 100 1" sw "$s"; ck "sweep: sem build vivo → LIMPO rc 0" rcis 0; ck "sweep: linha LIMPO no stdout e no log" bash -c "grep -q 'gt-dados-sweep: LIMPO removed=' '$OUT' && grep -q 'gt-dados-sweep: LIMPO' '$T/sweep.log'"
  ck "sweep: staging, home e tmp do dados sumiram" bash -c "[ -z \"\$(find '$S' '$T/dhome' '$T/tmp1' '$T/tmp2' -mindepth 1)\" ]"
  PS_ROWS="$row_new" sw "$s"; ck "sweep: build vivo (60 s) → PULADO, rc 0" bash -c "[ $RC = 0 ] && grep -q 'PULADO dados-vivo=1' '$OUT'"; ck "sweep: ...e NADA foi apagado" test -f "$S/in/proj/dado.txt"
  sleep 100 & local OLD_PID=$!; PS_ROWS="$ME 20000 $OLD_PID" sw "$s"; sleep 0.2; ck "sweep: processo de dados com ≥3 h é morto e a varredura segue" bash -c "! kill -0 $OLD_PID 2>/dev/null && grep -q 'LIMPO removed=.* killed=1' '$OUT'"; kill -9 $OLD_PID 2>/dev/null
  PS_FAIL=1 PS_ROWS="root 1 1" sw "$s"; ck "sweep: ps falhou → NAO-CONSEGUI rc 2, nada apagado" bash -c "[ $RC = 2 ] && grep -q 'NAO-CONSEGUI ps-falhou' '$OUT' && [ -f '$S/in/proj/dado.txt' ]"
  FS=ext4 PS_ROWS="root 1 1" sw "$s"; ck "sweep: staging fora do tmpfs → NAO-CONSEGUI rc 2 (e conta o que há)" bash -c "[ $RC = 2 ] && grep -q 'NAO-CONSEGUI stage-nao-e-tmpfs itens=[1-9]' '$OUT' && [ -f '$S/in/proj/dado.txt' ]"
  if [ "$(id -u)" != 0 ]; then fresh; seed; chmod 555 "$S/in/proj"; echo "root 1 1" > "$T/ps"; "$s" > "$OUT" 2> "$ERR"; RC=$?; ck "sweep: o que não consegue apagar → NAO-CONSEGUI sobrou, rc 2 (nunca LIMPO)" bash -c "[ $RC = 2 ] && grep -q 'NAO-CONSEGUI sobrou' '$OUT' && ! grep -q LIMPO '$OUT'"; chmod -R u+rwx "$S"; fi
  # lock do wrapper tomado (o selftest o segura por 3 s; a varredura espera LOCKWAIT=1). Com processo de dados na 2ª leitura do ps → PULADO, nada apagado; SEM ele → NAO-CONSEGUI (lock preso por outra coisa), nada apagado
  fresh; rm -f "$T/ps.n"; seed; echo t > "$T/tmp1/$ME-file"; echo "root 1 1" > "$T/ps"; flock "$T/lock" sleep 3 & local HOLD=$!; sleep 0.3; PS_SECOND="$ME 5 4242" "$s" > "$OUT" 2> "$ERR"; RC=$?; wait "$HOLD" 2> /dev/null
  ck "sweep: lock do wrapper tomado + processo de dados na 2ª leitura → PULADO build-vivo, rc 0, NADA apagado" bash -c "[ $RC = 0 ] && grep -q 'PULADO build-vivo lock=ocupado dados=1' '$OUT' && [ -f '$S/in/proj/dado.txt' ] && [ -f '$T/tmp1/$ME-file' ]"
  fresh; rm -f "$T/ps.n"; seed; echo "root 1 1" > "$T/ps"; flock "$T/lock" sleep 3 & HOLD=$!; sleep 0.3; "$s" > "$OUT" 2> "$ERR"; RC=$?; wait "$HOLD" 2> /dev/null
  ck "sweep: lock tomado SEM processo de dados → NAO-CONSEGUI lock-tomado-sem-build, rc 2, nunca PULADO/LIMPO, nada apagado" bash -c "[ $RC = 2 ] && grep -q 'NAO-CONSEGUI lock-tomado-sem-build' '$OUT' && ! grep -q -e PULADO -e LIMPO '$OUT' && [ -f '$S/in/proj/dado.txt' ]"
  # lock só de root: o modo 0600 é imposto mesmo num arquivo que já existia 0644 (um usuário local o travaria)
  chmod 644 "$T/lock"; PS_ROWS="root 1 1" sw "$s"; ck "sweep: lock nasce/vira 0600 (era 0644)" bash -c "[ -n \"\$(find '$T/lock' -perm 600)\" ]"
  TIMEOUT_RC=124 PS_ROWS="root 1 1" sw "$s"; ck "sweep: prazo do find estourado → NAO-CONSEGUI leitura-falhou, rc 2, nunca LIMPO, nada apagado" bash -c "[ $RC = 2 ] && grep -q 'NAO-CONSEGUI leitura-falhou' '$OUT' && ! grep -q LIMPO '$OUT' && [ -f '$S/in/proj/dado.txt' ]"
  FIND_NOISE=enoent PS_ROWS="root 1 1" sw "$s"; ck "sweep: find com 'No such file or directory' (entrada sumiu no meio) → ainda LIMPO rc 0" bash -c "[ $RC = 0 ] && grep -q 'gt-dados-sweep: LIMPO' '$OUT'"
  FIND_NOISE=eacces PS_ROWS="root 1 1" sw "$s"; ck "sweep: find com 'Permission denied' → NAO-CONSEGUI leitura-falhou, rc 2, nunca LIMPO" bash -c "[ $RC = 2 ] && grep -q 'NAO-CONSEGUI leitura-falhou' '$OUT' && ! grep -q LIMPO '$OUT'"
  FIND_NOISE=masked PS_ROWS="root 1 1" sw "$s"; ck "sweep: erro de OUTRO tipo num caminho que contém 'No such file or directory' não é entrada que sumiu → NAO-CONSEGUI rc 2, nunca LIMPO" bash -c "[ $RC = 2 ] && grep -q 'NAO-CONSEGUI leitura-falhou' '$OUT' && ! grep -q LIMPO '$OUT'"
  FIND_NOISE=countfail PS_ROWS="root 1 1" sw "$s"; ck "sweep: contagem ilegível mas o resto confere → LIMPO rc 0 com 'contagem=incompleta' no fim (nunca um removed=0 que pareça 'nada havia')" bash -c "[ $RC = 0 ] && grep -q 'LIMPO removed=.* killed=0 contagem=incompleta\$' '$OUT'"; PS_ROWS="root 1 1" sw "$s"; ck "sweep: contagem legível → a linha NÃO leva 'contagem=incompleta'" hasnt "$OUT" 'contagem=incompleta'; }
case_synth() { local s=$1 PATH="$T/stubs:$PATH"; fresh; mkdir -p "$S/in" "$S/out"
  ID_UN=runner GT_DADOS_STAGE="$S" "$s" > "$OUT" 2> "$ERR"; RC=$?; ck "synth: fora do usuário dados → 2" rcis 2; GT_DADOS_STAGE= "$s" > "$OUT" 2> "$ERR"; RC=$?; ck "synth: sem GT_DADOS_STAGE → 2" rcis 2
  python3 - "$T/port" <<'PY' &
import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(5); open(sys.argv[1], "w").write(str(s.getsockname()[1])); time.sleep(6)
PY
  local lp=$! i=0; while [ ! -s "$T/port" ] && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done
  GTD_SYNTH_PROBE="127.0.0.1/$(cat "$T/port")" GT_DADOS_STAGE="$S" "$s" > "$OUT" 2> "$ERR"; RC=$?; ck "synth: saída de rede aberta → 3 (isolamento inexistente)" rcis 3; kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
  GTD_SYNTH_PROBE="127.0.0.1/1" GT_DADOS_STAGE="$S" "$s" > "$OUT" 2> "$ERR"; RC=$?; ck "synth: saída fechada → ok rc 0" rcis 0; ck "synth: resultado em out/" test -s "$S/out/synth/result.sha256"; ck "synth: dado sintético em in/ (5 arquivos)" test "$(find "$S/in/synth" -type f | wc -l | tr -d ' ')" = 5; ck "synth: 'ok files=' é a contagem do que existe" has "$OUT" '^synth: ok files=5$'
  if [ "$(id -u)" != 0 ]; then fresh; mkdir -p "$S/in/synth"; chmod 555 "$S/in/synth"; GTD_SYNTH_PROBE="127.0.0.1/1" GT_DADOS_STAGE="$S" "$s" > "$OUT" 2> "$ERR"; RC=$?; ck "synth: in/synth não gravável → 2 FALHOU (nunca 'ok files=5' constante)" bash -c "[ $RC = 2 ] && ! grep -q 'synth: ok' '$OUT'"; chmod -R u+rwx "$S"; fi; }
pv() { : > "$LOG"; "$1" > "$OUT" 2> "$ERR"; RC=$?; }
case_prove() { local s=$1
  pv "$s"; ck "prove: tudo ok → rc 0" rcis 0; ck "prove: 6 itens + o resultado, todos ok" test "$(grep -c '^GTD-PROVE: .* ok$' "$OUT")" = 7
  LS_MODE=leak pv "$s"; ck "prove: o runner LEU o home → FALHOU rc 1" bash -c "[ $RC = 1 ] && grep -q 'home-negado FALHOU' '$OUT'"
  LS_MODE=missing pv "$s"; ck "prove: diretório não existe → nao-consegui rc 2 (nunca ok)" bash -c "[ $RC = 2 ] && grep -q 'home-negado nao-consegui' '$OUT'"
  ID_G="runner dados" pv "$s"; ck "prove: runner no grupo dados → FALHOU" has "$OUT" 'sem-grupo-dados FALHOU'; SUDO_AS_DADOS=1 pv "$s"; ck "prove: sudo -u dados funcionou → FALHOU" has "$OUT" 'sudo-como-dados-recusado FALHOU'
  SUDO_LIST_LEAK=1 pv "$s"; ck "prove: entrypoint fora da lista rodou → FALHOU" has "$OUT" 'fora-da-lista-recusado FALHOU'; SYNTH_OUT="synth: ok" pv "$s"; ck "prove: build sem GTD-WIPE ok → FALHOU" has "$OUT" 'build-sintetico FALHOU'
  SYNTH_RC=3 pv "$s"; ck "prove: build com rc≠0 → FALHOU" has "$OUT" 'build-sintetico FALHOU'
  SYNTH_OUT='synth: ok files=5\nGTD-EGRESS: attempts=0\nGTD-WIPE: ok' pv "$s"; ck "prove: attempts=0 (a sonda não chegou ao netns) → FALHOU rc 1, nunca ok" bash -c "[ $RC = 1 ] && grep -q 'build-sintetico FALHOU (attempts=0' '$OUT'"
  SYNTH_OUT='synth: ok files=5\nGTD-EGRESS: attempts=1\nGTD-WIPE: ok' pv "$s"; ck "prove: attempts=1 → ok" has "$OUT" 'build-sintetico ok'
  SYNTH_OUT='synth: ok files=5\nGTD-EGRESS: attempts=?\nGTD-WIPE: ok' pv "$s"; ck "prove: attempts=? (contador ilegível) → FALHOU" has "$OUT" 'build-sintetico FALHOU'; }
# GTD_CASES="run signal ..." roda só esses casos (depuração) e pula os mutantes
for c in ${GTD_CASES:-run link ingest sweep synth prove signal lock}; do x=${c/signal/run}; x=${x/link/run}; case_$c "$T/${x/lock/run}.sh"; done
[ -z "${GTD_CASES:-}" ] || { echo "---"; echo "casos: $n, reprovados: $fails (só GTD_CASES=$GTD_CASES)"; [ "$fails" -eq 0 ]; exit; }
# MUTANTES: cada um tira UMA guarda de uma cópia; o caso da guarda tem de reprovar
mut() { local name=$1 script=$2 expr=$3 fn=$4 mc="$T/mut-$1.sh"; mkcopy "$HERE/hetzner-dados-$script.sh" "$mc" "$expr"; cmp -s "$mc" "$T/$script.sh" && { echo "FAIL mutante $name não alterou nada"; fails=$((fails+1)); return; }
  QUIET=1; BAD=0; "$fn" "$mc" > /dev/null 2>&1; QUIET=0; n=$((n+1)); if [ "$BAD" = 1 ]; then echo "ok   mutante $name reprovado"; else echo "FAIL mutante $name SOBREVIVEU"; fails=$((fails+1)); fi; }
mut M1-run-sem-lista run 's#|| usage fora-da-lista##' case_run
mut M2-run-sem-tmpfs run 's#|| fail stage-nao-e-tmpfs##' case_run
mut M3-run-sem-swap run 's#\[ "\$SW" = 1 \] || fail swap-ligada-ou-ilegivel#true#' case_run
mut M4-run-sem-apagar run 's#^if wipe_in; then#if true; then#' case_run
mut M5-run-sem-99 run 's#exit 99; fi#true; fi#' case_run
mut M6-run-sem-no-new-privs run 's# --no-new-privs##' case_run
mut M7-run-sem-env-i run 's#/usr/bin/env -i #/usr/bin/env #' case_run
mut M8-run-sem-dono-root run 's#-type f -user \${GTD_TEST_OWNER} ! -perm -020 ! -perm -002 -perm -100#-type f#' case_run
mut M9-run-sem-matar-o-netns run 's#xargs -r kill -9#cat > /dev/null#' case_run
mut M10-ingest-sem-link ingest 's#\[ -z "\$l" \] ||#true ||#' case_ingest
mut M11-ingest-gone-mente ingest 's#then rc=1; fi#then rc=0; fi#' case_ingest
mut M31-ingest-gone-para-no-1o ingest 's#then rc=1; fi#then return 1; fi#' case_ingest
mut M32-ingest-put-vazio-vira-ok ingest 's#\[ "\${nf:-0}" -gt 0 \] ||#true ||#' case_ingest
mut M33-ingest-status-falha-vira-0 ingest "s#|| { echo '?'; return 0; }#|| { echo 0; return 0; }#" case_ingest
mut M12-ingest-sem-tmpfs ingest 's#|| no stage-nao-e-tmpfs 98##' case_ingest
mut M13-ingest-get-vazio ingest 's#|| no resultado-ausente 66##' case_ingest
mut M14-sweep-ignora-vivo sweep 's#if \[ "\$LIVE" -gt 0 \]#if false#' case_sweep
mut M15-sweep-ps-vazio sweep 's#|| cant ps-falhou##' case_sweep
mut M16-sweep-sobra-vira-limpo sweep 's#\[ -z "\$left" \] || cant "sobrou:\$left"#true#' case_sweep
mut M17-sweep-sem-tmpfs sweep 's#cant "stage-nao-e-tmpfs#log "ignorado stage-nao-e-tmpfs#' case_sweep
mut M21-sweep-sem-lock sweep 's#flock -w "\$LOCKWAIT" -E 75 8; r=\$?#r=0#' case_sweep
mut M22-sweep-prazo-vira-limpo sweep 's#\[ "\$rc" -ge 124 \] || ! \[ -s "\$ef" \] || ##' case_sweep
mut M23-sweep-entrada-que-sumiu-reprova sweep 's#grep -v -e "\$GONE_RE" "\$ef" | grep -q \.#grep -q . "\$ef"#' case_sweep
mut M24-sweep-erro-de-leitura-ignorado sweep 's#grep -v -e "\$GONE_RE" "\$ef" | grep -q \.#false#' case_sweep
mut M34-sweep-gone-por-substring sweep 's#grep -v -e "\$GONE_RE" "\$ef"#grep -v -F -e "No such file or directory" "\$ef"#' case_sweep
mut M35-sweep-contagem-ilegivel-vira-zero sweep 's#else NQ=1; fi#else NQ=0; fi#' case_sweep
mut M25-sweep-lock-sem-build-vira-pulado sweep 's#\[ "\$L2" -gt 0 \] || cant "lock-tomado-sem-build"#true#' case_sweep
mut M26-run-lock-sem-chmod run 's#&& chmod 0600 "\$LOCK" 2> /dev/null || fail lock-modo#|| fail lock-modo#' case_lock
mut M27-sweep-lock-sem-chmod sweep 's#&& chmod 0600 "\$LOCK" 2> /dev/null || cant lock-modo#|| cant lock-modo#' case_sweep
mut M36-run-sem-guarda-de-link run 's#\[ -n "\$(find "\$STAGE/\$d" -maxdepth 0 -type d 2> /dev/null)" \] || fail stage-dirs#true#' case_link
mut M37-run-chown-segue-link run 's#chown -h #chown #' case_run
mut M38-run-wipe-segue-link run 's#{ \[ -d "\$STAGE/in" \] && \[ ! -L "\$STAGE/in" \]; } || return 1; ##' case_link
mut M40-synth-conta-constante synth 's#\[ "\$n" = 5 \] ||#true ||#' case_synth
mut M41-prove-attempts-zero-ok prove 's#attempts=\[1-9\]\[0-9\]\*#attempts=[0-9]+#' case_prove
mut M18-synth-rede-aberta synth 's#exit 3; fi#true; fi#' case_synth
mut M19-prove-ls-vazio prove 's#\*"No such file"\*) item "\$1" nao-consegui#*"No such file"*) item "$1" ok#' case_prove
mut M20-prove-sudo-dados prove 's#|| item sudo-como-dados-recusado FALHOU "o runner virou dados"#|| true#' case_prove
echo "---"; echo "casos: $n, reprovados: $fails"; [ "$fails" -eq 0 ]
