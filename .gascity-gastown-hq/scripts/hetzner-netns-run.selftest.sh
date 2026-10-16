#!/usr/bin/env bash
# hetzner-netns-run.selftest.sh — hermético: ip, nft, setpriv e getent são stubs; nada cria netns nem regra de verdade (ga-9p6pte).
#
# ## Contents
#   Casos · Controles negativos · O que este teste NÃO prova
#
# CASOS: quem chama (sem SUDO_UID, uid 0, sem comando → 64) · montagem na ordem certa (netns, lo, gtn0, rota, nft, setpriv, limpeza) e a regra (policy drop, lo aceito, TUDO
#   o mais rejeitado COM contador) · o comando sai sem capacidades, com o uid do chamador e ambiente limpo, e o rc dele é o do helper · cada passo da montagem que falha →
#   98 + `setup-falhou:<passo>` e o comando NÃO roda · contador do nft (N / 0 / ilegível `?`, nunca 0 por engano) · TERM chega ao comando e a limpeza roda · TERM DURANTE a montagem cancela (o comando não roda) · processo que sobrou no netns é morto.
# CONTROLES NEGATIVOS: mutantes H1-H15 têm de ser REPROVADOS pelo caso correspondente (o caso falha no mutante).
# O QUE NÃO PROVA: que o kernel isola com estas regras. Isso só o canário prova, no nó, com o helper instalado por root (hetzner-iso-run.sh --canary).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ORIG="$HERE/hetzner-netns-run.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/hzn-netns-selftest.XXXXXX")
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
mkdir -p "$T/stubs"; LOG="$T/log"; NFT_RULES="$T/rules"; OUT="$T/out"; ERR="$T/err"; PIDS_FILE="$T/pids"
cat > "$T/stubs/ip" <<'EOF'
#!/usr/bin/env bash
echo "ip $*" >> "$LOG"
case "$*" in
  "netns add "*) [ "${FAIL_STEP:-}" = netns-add ] && exit 1; [ "${SLOW_SETUP:-}" = 1 ] && { echo setup-started >> "$LOG"; sleep 1; } ;;
  "-n "*" link set lo up") [ "${FAIL_STEP:-}" = lo ] && exit 1 ;;
  "-n "*" link add gtn0 "*) [ "${FAIL_STEP:-}" = gtn0 ] && exit 1 ;;
  "netns pids "*) cat "$PIDS_FILE" 2>/dev/null; exit 0 ;;
  "netns exec "*) shift 3; exec "$@" ;;
esac
exit 0
EOF
cat > "$T/stubs/nft" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-f -") cat > "$NFT_RULES"; [ "${FAIL_STEP:-}" = nft ] && exit 1; exit 0 ;;
  "list chain inet gtn out") [ "${FAIL_STEP:-}" = nft-regra ] || echo "chain out { counter name egress reject }" ;;
  "list counter inet gtn egress") case "${CNT_MODE:-3}" in garbage) echo "boom" ;; fail) exit 1 ;; *) echo "counter egress { packets ${CNT_MODE:-3} bytes 180 }" ;; esac ;;
esac
EOF
cat > "$T/stubs/setpriv" <<'EOF'
#!/usr/bin/env bash
echo "setpriv $*" >> "$LOG"; cat "$GTN_TEST_ETC"/*/resolv.conf >> "$LOG" 2>/dev/null
if [ "${SLOW:-}" = 1 ]; then sleep 20 & sp=$!; trap 'echo got-term >> "$LOG"; kill $sp 2>/dev/null; exit 143' TERM; echo started >> "$LOG"; wait $sp; fi
exit "${CMD_RC:-0}"
EOF
printf '#!/usr/bin/env bash\n[ "${FAIL_STEP:-}" = passwd ] && exit 2\necho "runner:x:1000:1000::/home/runner:/bin/bash"\n' > "$T/stubs/getent"
chmod +x "$T/stubs/"*
export LOG NFT_RULES PIDS_FILE
# o script de root reseta o PATH e escreve em /etc/netns: a cópia testada troca SÓ essas linhas (conferido abaixo contra o original)
grep -q '^PATH=/usr/sbin:/usr/bin:/sbin:/bin$' "$ORIG" || { echo "FAIL o original não tem a linha PATH esperada"; exit 1; }
sed "s#^PATH=/usr/sbin:/usr/bin:/sbin:/bin\$#PATH=$T/stubs:/usr/bin:/bin#; s#/etc/netns#\${GTN_TEST_ETC}#g" "$ORIG" > "$T/H.sh"; chmod +x "$T/H.sh"
n=0; fails=0; BAD=0; QUIET=0
ck() { local l=$1; shift; [ "$QUIET" = 1 ] || n=$((n+1)); if "$@"; then [ "$QUIET" = 1 ] || echo "ok   $l"; else [ "$QUIET" = 1 ] || { echo "FAIL $l"; fails=$((fails+1)); }; BAD=1; fi; }
ck "a cópia testada difere do original só no PATH e no /etc/netns" test "$(diff "$ORIG" "$T/H.sh" | grep '^<' | grep -v -c -e '^< PATH=' -e '/etc/netns')" = 0
rcis() { [ "$RC" = "$1" ]; }
has() { grep -q -E -- "$2" "$1"; }
hasnt() { ! grep -q -E -- "$2" "$1"; }
order() { local prev=0 p pat; for pat in "$@"; do p=$(grep -n -E -- "$pat" "$LOG" | head -n 1 | cut -d: -f1); [ -n "$p" ] && [ "$p" -gt "$prev" ] || return 1; prev=$p; done; }
go() { local s=$1; shift; : > "$LOG"; : > "$NFT_RULES"; : > "$PIDS_FILE"; export GTN_TEST_ETC="${GTN_TEST_ETC:-$T/etc-netns}"; mkdir -p "$GTN_TEST_ETC" 2>/dev/null
       env SUDO_UID="${SUDO_UID-1000}" SUDO_GID="${SUDO_GID-1000}" "$s" "$@" > "$OUT" 2> "$ERR"; RC=$?; }
dead() { case "$(ps -p "$1" -o state= 2>/dev/null | tr -d ' ')" in ''|Z*) return 0 ;; *) return 1 ;; esac; }
SP='^setpriv '

case_ok() { CMD_RC=7 go "$1" -- python -m pytest tests/
  ck "rc do comando é o do helper" rcis 7; ck "avisa que montou o isolamento" has "$ERR" '^GTN-ISO: ok ns=gtn[0-9]+ uid=1000'; ck "diz o contador" has "$ERR" '^GTN-EGRESS: attempts=3$'
  ck "ordem: netns, lo, gtn0, rota, nft, regra lida, setpriv, limpeza" order '^ip netns add gtn' 'link set lo up' 'link add gtn0 type dummy' 'route add default via 192\.0\.2\.1' 'nft -f -' 'nft list chain inet gtn out' "$SP" '^ip netns del gtn'
  ck "regra: policy drop na saída e na entrada" test "$(grep -c 'policy drop' "$NFT_RULES")" = 2; ck "regra: lo aceito" has "$NFT_RULES" 'oifname "lo" accept'; ck "regra: o resto rejeitado COM contador" has "$NFT_RULES" 'counter name egress reject'
  ck "resolv.conf do netns aponta para 192.0.2.1" has "$LOG" '^nameserver 192\.0\.2\.1$'
  ck "setpriv: uid/gid do chamador, sem capacidades, ambiente limpo, comando" has "$LOG" "^setpriv --reuid=1000 --regid=1000 --init-groups --no-new-privs --inh-caps=-all --bounding-set=-all -- /usr/bin/env -i HOME=/home/runner PATH=[^ ]+ LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/\$"
  ck "limpeza: o /etc/netns do run sumiu" test -z "$(ls -A "$GTN_TEST_ETC")"; }
case_caller() { SUDO_UID= go "$1" -- true; ck "sem SUDO_UID: rc 64" rcis 64; ck "sem SUDO_UID: nada foi montado nem rodou" test ! -s "$LOG"
  SUDO_UID=0 go "$1" -- true; ck "SUDO_UID=0 (root puro): rc 64" rcis 64; ck "SUDO_UID=0: o comando NÃO roda" hasnt "$LOG" "$SP"
  SUDO_GID=0 go "$1" -- true; ck "SUDO_GID=0: rc 64" rcis 64; go "$1"; ck "sem comando: rc 64" rcis 64; }
case_setup() { local st
  for st in netns-add lo gtn0 resolv nft nft-regra passwd; do
    if [ $st = resolv ]; then : > "$T/blockfile"; GTN_TEST_ETC="$T/blockfile/x" FAIL_STEP=$st go "$1" -- true; else FAIL_STEP=$st go "$1" -- true; fi
    ck "falha em $st: rc 98 e o passo no stderr" rcis 98; ck "falha em $st: setup-falhou:$st" has "$ERR" "^GTN-ISO: setup-falhou:$st\$"; ck "falha em $st: o comando NÃO roda" hasnt "$LOG" "$SP"; ck "falha em $st: limpou o netns" has "$LOG" '^ip netns del gtn'
  done; unset GTN_TEST_ETC; }
case_counter() { CNT_MODE=garbage go "$1" -- true; ck "contador ilegível: ? (não 0)" has "$ERR" '^GTN-EGRESS: attempts=\?$'; CNT_MODE=fail go "$1" -- true; ck "contador que falha ao ler: ?" has "$ERR" '^GTN-EGRESS: attempts=\?$'
  CNT_MODE=0 go "$1" -- true; ck "contador 0 lido: 0" has "$ERR" '^GTN-EGRESS: attempts=0$'; CNT_MODE=41 go "$1" -- true; ck "contador 41 lido: 41" has "$ERR" '^GTN-EGRESS: attempts=41$'; }
case_signal() { : > "$LOG"; env SLOW=1 SUDO_UID=1000 SUDO_GID=1000 GTN_TEST_ETC="$T/etc-netns" "$1" -- sleep 20 > "$OUT" 2> "$ERR" & local hp=$! i=0
  while ! grep -q '^started$' "$LOG" 2>/dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done; kill -TERM "$hp" 2>/dev/null; wait "$hp"; RC=$?
  ck "TERM no helper chega ao comando" has "$LOG" '^got-term$'; ck "TERM: o helper sai com erro" test "$RC" != 0; ck "TERM: a limpeza roda" has "$LOG" '^ip netns del gtn'; }
case_cancel() { : > "$LOG"; env SLOW_SETUP=1 SUDO_UID=1000 SUDO_GID=1000 GTN_TEST_ETC="$T/etc-netns" "$1" -- sleep 20 > "$OUT" 2> "$ERR" & local hp=$! i=0
  while ! grep -q '^setup-started$' "$LOG" 2>/dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done; kill -TERM "$hp" 2>/dev/null; wait "$hp"; RC=$?
  ck "TERM durante a montagem: o comando NÃO roda" hasnt "$LOG" "$SP"; ck "TERM durante a montagem: sai com erro" test "$RC" != 0; ck "TERM durante a montagem: diz que cancelou" has "$ERR" '^GTN-ISO: setup-falhou:cancelado$'
  ck "TERM durante a montagem: a limpeza roda" has "$LOG" '^ip netns del gtn'; }
case_leftover() { sleep 60 & local sp=$!; disown "$sp" 2>/dev/null; echo "$sp" > "$PIDS_FILE"; : > "$LOG"; env SUDO_UID=1000 SUDO_GID=1000 GTN_TEST_ETC="$T/etc-netns" "$1" -- true > "$OUT" 2> "$ERR"; RC=$?; sleep 0.3
  ck "sobrou processo no netns: é morto na limpeza" dead "$sp"; kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null; }

for c in ok caller setup counter signal cancel leftover; do "case_$c" "$T/H.sh"; done

M=0
mutant() { # nome expr-sed caso
  local f="$T/m-$1.sh"; sed "$2" "$T/H.sh" > "$f"; chmod +x "$f"; n=$((n+1)); M=$((M+1))
  if cmp -s "$T/H.sh" "$f"; then echo "FAIL $1: o sed não casou (mutante igual ao original)"; fails=$((fails+1)); return; fi
  bash -n "$f" 2>/dev/null || { echo "FAIL $1: mutante com erro de sintaxe (a prova seria vazia)"; fails=$((fails+1)); return; }
  BAD=0; QUIET=1; "case_$3" "$f"; QUIET=0
  if [ "$BAD" = 1 ]; then echo "ok   $1 (o caso '$3' reprova o mutante)"; else echo "FAIL $1: o caso '$3' NÃO reprovou o mutante"; fails=$((fails+1)); fi; }
mutant H1-regra-nao-conferida "s/grep -q 'reject' || fail nft-regra/grep -q 'reject'/" setup
mutant H2-falha-nao-aborta 's/cleanup; exit 98; }/cleanup; }/' setup
mutant H3-contador-ilegivel-vira-0 's/attempts=\${n:-?}/attempts=${n:-0}/' counter
mutant H4-com-novos-privilegios 's/ --no-new-privs//' ok
mutant H5-capacidades-herdaveis 's/ --inh-caps=-all//' ok
mutant H6-capacidades-no-bounding 's/ --bounding-set=-all//' ok
mutant H7-ambiente-nao-limpo 's#/usr/bin/env -i HOME#/usr/bin/env HOME#' ok
mutant H8-policy-accept 's/policy drop; oifname "lo" accept; counter name egress reject/policy accept; oifname "lo" accept; counter name egress reject/' ok
mutant H9-rejeita-sem-contador 's/counter name egress reject/reject/' ok
mutant H10-sem-trap-de-sinal "s/^trap 'CANCEL=1; .*\$/true/" signal
mutant H11-sobra-no-netns-nao-morta 's/^  ip netns pids .*$/  true/' leftover
mutant H12-sem-checar-quem-chamou 's/^\[ \$# -gt 0 \] && \[ "\${SUDO_UID.*$/true/' caller
mutant H13-roda-como-root 's/--reuid="\$SUDO_UID"/--reuid=0/' ok
mutant H14-dns-fora-da-regra 's/nameserver 192.0.2.1/nameserver 1.1.1.1/' ok
mutant H15-cancelamento-na-montagem-engolido 's/^\[ -z "\$CANCEL" \] || fail cancelado$/true/' cancel
echo "---"; echo "$((n-fails))/$n ok ($M mutantes)"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
