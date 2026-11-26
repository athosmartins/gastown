#!/usr/bin/env bash
# mini64.selftest.sh — espera.sh, carregar-camada.sh, mini64-lib.sh e camadas.tsv (ga-ke5w2ie.2).
#
# Tudo roda com um HOME de mentira (pasta temporária com plists de mentira) e um launchctl FALSO que recusa caminho fora desse HOME. Dois cães de
# guarda: um `launchctl` no PATH que anota e falha (se um script o chamasse sem passar por $MINI64_LAUNCHCTL o teste ficava vermelho; o cenário S31
# prova que ele está vivo) e a prova estática de que nenhum script apaga nada nem usa o launchctl fora de "$LAUNCHCTL". O HOME real nunca é passado.
#
# Cenários:
#   S1-S3   estática: sintaxe, sem rm/unlink/-delete/mv -f, launchctl só por "$LAUNCHCTL"
#   S4-S8   tabela: válida; tabela ruim recusada (rc 2); TODO plist (ou template) do repo tem linha PRÓPRIA (apagar uma linha reprova); pinos da tabela real;
#           S8b todo job da política wait-for-dolt e S8c o túnel/sender do post-check (lidos dos arquivos deles) têm linha própria
#   S9-S19  espera.sh: status, prévia, a chave --confirmo mini-novo, ligar, de novo, cópia nova, symlink, job já carregado, terceiro estado, desligar,
#           inconsistente, fora da tabela, ligar que não consegue mover (plists-soltos: nunca carga-completa, desligar recusa)
#   S20-S30 carregar-camada.sh: camada inválida, uso, sem marcador, ordem, camada posterior solta, prévia, --confirmo, idempotência, falha de
#           bootstrap, "carregado?" sem resposta, conflito, camada vazia
#   S31-S32 cão de guarda vivo e nada tocado no HOME real
# Exit 0 sse todo cenário se comporta como esperado.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CITY="${MINI64_CITY_ROOT:-$(cd "$HERE/../.." && pwd)}"   # o override é da bateria de mutantes: a cópia mutante está fora do repo
ESP="$HERE/espera.sh"; CAR="$HERE/carregar-camada.sh"; LIB="$HERE/mini64-lib.sh"; REAL="$HERE/camadas.tsv"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok: %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  BAD: %s\n     %s\n' "$1" "${2:-}"; }
for f in "$ESP" "$CAR" "$LIB" "$REAL"; do [ -f "$f" ] || { echo "FATAL: falta $f" >&2; exit 1; }; done   # script ausente é falha, nunca "pulado"
REAL_HOME="${HOME:-}"; real_snap() { ls -ld "$REAL_HOME/.mini64-espera" "$REAL_HOME/Library/LaunchAgents.mini64-espera" 2>&1; }; REAL0="$(real_snap)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/mini64-selftest.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/trip" "$TMP/stub" "$TMP/mvstub"; : > "$TMP/trip.log"
cat > "$TMP/mvstub/mv" <<'EOF'
#!/bin/sh
b=${1##*/}
if [ -n "${MV_FALHA:-}" ] && printf '%s\n' "$b" | grep -Eq -- "$MV_FALHA"; then echo "mv de mentira: recusado: $1" >&2; exit 1; fi
exec /bin/mv "$@"
EOF
chmod +x "$TMP/mvstub/mv"
cat > "$TMP/trip/launchctl" <<'EOF'
#!/bin/sh
echo "cão de guarda: $*" >> "$TRIP_LOG"; exit 99
EOF
cat > "$TMP/stub/launchctl" <<'EOF'
#!/bin/sh
[ -z "${STUB_SLURP:-}" ] || cat > /dev/null
echo "$*" >> "$STUB_LOG"
case "$1" in
  print) l=${2##*/}; grep -qx "$l" "$STUB_ESTADO" && exit 0; exit "${STUB_PRINT_RC:-113}" ;;
  bootstrap) case "$3" in "$STUB_AGENTS"/*) ;; *) echo "stub: caminho fora do HOME falso: $3" >&2; exit 98 ;; esac
    [ -f "$3" ] || exit 97
    l=$(basename "$3" .plist); [ "${STUB_FALHA:-}" = "$l" ] && exit 5
    echo "$l" >> "$STUB_ESTADO"; exit 0 ;;
  list) [ -n "${STUB_LIST_RC:-}" ] && exit "$STUB_LIST_RC"; printf 'PID\tStatus\tLabel\n'; while read -r l; do printf -- '-\t0\t%s\n' "$l"; done < "$STUB_ESTADO"; exit 0 ;;
esac
exit 96
EOF
chmod +x "$TMP/trip/launchctl" "$TMP/stub/launchctl"
# tabela de mentira: camadas 0..5 como a real, um plist por camada (dois na 1) e a família com.cidade (padrão 5)
FIX="$TMP/fixture.tsv"
{ printf '@camada\t%s\t%s\t%s\n' 0 dolt - 1 motor - 2 backups antigo-aposentado 3 paineis - 4 cloudflared conector-unico 5 envios antigo-aposentado
  printf '@familia\t%s\t%s\n' com.cidade 5
  printf '%s\t%s\tfixture\n' com.cidade.a0 0 com.cidade.a1 1 com.cidade.b1 1 com.cidade.a2 2 com.cidade.a3 3 com.cidade.a4 4; } > "$FIX"
awk -F'\t' -v OFS='\t' '$1 == "@familia" { $2 = "com.outra" } { print }' "$FIX" > "$TMP/outra-familia.tsv"   # a tabela deixa de conhecer com.cidade
LBL="com.cidade.a0 com.cidade.a1 com.cidade.b1 com.cidade.a2 com.cidade.a3 com.cidade.a4 com.cidade.z5 org.terceiro.x"

TSV="$FIX"; PRC=""; FALHA=""; LRC=""; MVF=""   # MVF = o mv de mentira recusa o que casa com este ERE (nome do arquivo de origem)
# mk_world <nome> <labels...>: HOME de mentira com um LaunchAgents cheio de plists de mentira (+ um .bak, que o launchd nem lê)
mk_world() {
  W="$TMP/$1"; shift; H="$W/home"; AG="$H/Library/LaunchAgents"; ESPD="$H/Library/LaunchAgents.mini64-espera"
  mkdir -p "$AG"; : > "$W/estado"; : > "$W/log"; : > "$AG/com.cidade.velho.plist.bak"
  local l; for l in "$@"; do printf '<plist>%s</plist>\n' "$l" > "$AG/$l.plist"; done
}
# run <e|c> <args...>: um comando com o HOME e o launchctl de mentira; sets RC e OUT (stdout+stderr)
run() {
  local s="$1"; shift; if [ "$s" = e ]; then s="$ESP"; else s="$CAR"; fi
  OUT="$(env HOME="$H" PATH="$TMP/mvstub:$TMP/trip:$PATH" TRIP_LOG="$TMP/trip.log" MINI64_LAUNCHCTL="$TMP/stub/launchctl" M64_TSV="$TSV" STUB_ESTADO="$W/estado" \
    STUB_LOG="$W/log" STUB_AGENTS="$AG" STUB_PRINT_RC="$PRC" STUB_FALHA="$FALHA" STUB_LIST_RC="$LRC" MV_FALHA="$MVF" bash "$s" "$@" 2>&1)"; RC=$?
}
# expect <rc> <regex|-> <desc>: o rc e (se não for "-") um trecho da saída, com as quebras de linha viradas em espaço
expect() {
  if [ "$RC" != "$1" ]; then bad "$3: rc=$RC, queria $1" "$OUT"
  elif [ "$2" != "-" ] && ! printf '%s' "$OUT" | tr '\n' ' ' | grep -Eq -- "$2"; then bad "$3: a saída não casa /$2/" "$OUT"
  else ok "$3"; fi
}
says() { if printf '%s' "$OUT" | tr '\n' ' ' | grep -Eq -- "$1"; then ok "$2"; else bad "$2: a saída não casa /$1/" "$OUT"; fi; }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d" "${OUT:-}"; fi; }
not() { ! "$@"; }
has() { [ -e "$1" ] || [ -L "$1" ]; }
all_in() { local d="$1" l; shift; for l in "$@"; do [ -f "$d/$l.plist" ] || return 1; done; }
none_in() { local d="$1" l; shift; for l in "$@"; do has "$d/$l.plist" && return 1; done; return 0; }
snap() { (cd "$W" && find home \( -type f -o -type l \) | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done); }
nboot() { awk '/^bootstrap/ { n++ } END { print n + 0 }' "$W/log"; }
nlog() { wc -l < "$W/log" | tr -d ' '; }
ntrip() { wc -l < "$TMP/trip.log" | tr -d ' '; }
# carrega <N>: a camada N com a confirmação que a tabela pede para ela · carrega_tudo: as seis na ordem
carrega() { local c=; case "$1" in (2|5) c=antigo-aposentado;; (4) c=conector-unico;; esac; run c "$1" --aplicar ${c:+--confirmo $c}; }
carrega_tudo() { local n; for n in 0 1 2 3 4 5; do carrega "$n"; done; }
C0="com.cidade"

echo "== estática"
for f in "$ESP" "$CAR" "$LIB"; do chk "S1 bash -n $(basename "$f")" bash -n "$f"; done
bad_v="$(grep -nwE 'rm|rmdir|unlink|shred' "$LIB" "$ESP" "$CAR"; grep -n -- '-delete' "$LIB" "$ESP" "$CAR"; grep -nE 'mv +-[a-zA-Z]*f' "$LIB" "$ESP" "$CAR")"
OUT="$bad_v"; chk "S2 nenhum script apaga ou sobrescreve à força (rm, unlink, -delete, mv -f)" test -z "$bad_v"
bad_l="$(grep -vE '^[[:space:]]*#' "$LIB" "$ESP" "$CAR" | grep 'launchctl' | grep -v 'LAUNCHCTL=')"
OUT="$bad_l"; chk "S3 o launchctl só é chamado por \"\$LAUNCHCTL\"" test -z "$bad_l"

echo "== tabela"
libf() { local t="$1"; shift; ( HOME=/x; . "$LIB"; M64_TSV="$t"; "$@" ); }
tab() { libf "$1" m64_tabela_ok >/dev/null 2>&1; }
chk "S4 a tabela real é válida" tab "$REAL"
chk "S4 ...e define as camadas 0 a 5" test "$(libf "$REAL" m64_camadas)" = 0,1,2,3,4,5
Tb="$(printf '\t')"; head="$(grep -E '^@(camada|familia)' "$REAL" | head -n 8)"
mk_tab() { printf '%s\n' "$2" > "$TMP/t-$1.tsv"; }
mk_tab minima "$head
a.b${Tb}1${Tb}x"; chk "S5 tabela mínima válida é aceita (o controle das recusas abaixo)" tab "$TMP/t-minima.tsv"
mk_tab vazia ""; mk_tab so-comentario "# nada"; mk_tab sem-linhas "$head"
mk_tab prefixo-repetido "$head
a.b${Tb}1${Tb}x
a.b${Tb}2${Tb}x"
mk_tab camada-indefinida "$head
a.b${Tb}9${Tb}x"; mk_tab dois-campos "$head
a.b${Tb}1"; mk_tab caractere-ruim "$head
a b${Tb}1${Tb}x"; mk_tab motivo-vazio "$head
a.b${Tb}1${Tb}"
for t in vazia so-comentario sem-linhas prefixo-repetido camada-indefinida dois-campos caractere-ruim motivo-vazio nao-existe; do chk "S5 tabela ruim recusada: $t" not tab "$TMP/t-$t.tsv"; done
# os labels de TODO plist vivo do repo e de todo template de plist (o Label de dentro do arquivo: o instalador renomeia, o arquivo não leva o prefixo)
files="$(git -C "$CITY" ls-files -- '*.plist' '*.plist.template' 2>/dev/null | grep -v '^docs/launchd-archive/')"
labels="$(while IFS= read -r p; do [ -n "$p" ] && awk '/<key>Label<\/key>/ { w = 1 } w && /<string>/ { s = $0; sub(/.*<string>/, "", s); sub(/<\/string>.*/, "", s); print s; exit }' "$CITY/$p"; done <<<"$files")"
sem_linha() { printf '%s\n' "$labels" | libf "$1" m64_classificar | awk -F'\t' '$3 != "explicito" { print $1 " (" $3 ")" }'; }
nf="$(printf '%s\n' "$files" | awk 'NF { n++ } END { print n + 0 }')"; nl="$(printf '%s\n' "$labels" | awk 'NF { n++ } END { print n + 0 }')"
chk "S6 achou plists no repo ($nf) e leu um Label de cada um ($nl)" test "$nf" -ge 50 -a "$nf" = "$nl"
OUT="$(sem_linha "$REAL")"; chk "S6 todo plist vivo do repo tem linha PRÓPRIA na tabela" test -z "$OUT"
grep -v '^com.gascity.pilot' "$REAL" > "$TMP/sem-pilot.tsv"; OUT="$(sem_linha "$TMP/sem-pilot.tsv")"
chk "S7 apagar a linha do pilot reprova a cobertura (o teste tem dente)" test -n "$OUT"
PINT=""   # tabela dos pinos (vazio = a real); os controles com dente apontam para uma tabela sem a linha
pin() { OUT="$(libf "${PINT:-$REAL}" m64_classificar <<<"$1")"; printf '%s\n' "$OUT" | awk -F'\t' -v c="$2" -v o="$3" '$2 == c && $3 == o { f = 1 } END { exit !f }'; }   # OUT = o que a lib classificou (o detalhe do BAD)
chk "S8 dolt-server é a camada 0" pin com.gastown.dolt-server 0 explicito
chk "S8 dolt-s3-backup é a 2 (o prefixo mais longo vence com.gascity.dolt-, da 1)" pin com.gascity.dolt-s3-backup 2 explicito
chk "S8 o reconciliador de DNS do cloudflared é a 4" pin com.gascity.cloudflared-dns-reconcile 4 explicito
chk "S8 painel do WA é a 3" pin com.whatsapp.demand-dashboard 3 explicito
chk "S8 job novo do WA cai na camada 5 pela família" pin com.whatsapp.job-que-ainda-nao-existe 5 padrao
chk "S8 plist de terceiro é de fora da cidade" pin com.apple.foo - fora
chk "S8 o túnel urblink-ops é a camada 4, com linha própria (o label está no post-check; antes caía na 5 pela família)" pin br.urblink.cloudflared.urblink-ops 4 explicito
chk "S8 ...e outro br.urblink (ETL) continua na 5 pela família" pin br.urblink.processo 5 padrao
chk "S8 backup do mini (restic) é a 2, não a 5 da família com.athos" pin com.athos.mini-restic-backup 2 explicito
chk "S8 job do HQ que só a política wait-for-dolt cita é a 1" pin com.gascity.wisp-table-reaper 1 explicito
chk "S8 city-night-window (desligado no antigo) tem linha própria, na 5" pin com.gascity.city-night-window 5 explicito
# a política wait-for-dolt lista os jobs do HQ e o post-check noturno confere o túnel e o sender: as duas listas são versionadas, lidas daqui e nunca copiadas
# vazio → o piso de 50 labels (ou um label lido vazio) reprova; falhou/ilegível → também reprova: o teste nunca passa por não ter o que olhar
POL="$CITY/scripts/wait-for-dolt.policy.tsv"; PC="$CITY/scripts/nightly-reboot-postcheck.sh"
pl="$(awk -F'\t' '!/^[[:space:]]*(#|$)/ && NF >= 3 { print $1 }' "$POL" 2>/dev/null)"; np="$(printf '%s\n' "$pl" | awk 'NF { n++ } END { print n + 0 }')"
pol_sem_linha() { printf '%s\n' "$pl" | libf "$1" m64_classificar | awk -F'\t' 'NF && $3 != "explicito" { print $1 " (" $3 ")" }'; }
nx="$(printf '%s\n' "$pl" | libf "$REAL" m64_classificar | awk -F'\t' '$3 == "explicito" { n++ } END { print n + 0 }')"; OUT="$(pol_sem_linha "$REAL")"
chk "S8b todo job da política wait-for-dolt ($np) tem linha PRÓPRIA na tabela" test "$np" -ge 50 -a -z "$OUT" -a "$nx" = "$np"
grep -v '^com.gascity.wisp-' "$REAL" > "$TMP/sem-wisp.tsv"; OUT="$(pol_sem_linha "$TMP/sem-wisp.tsv")"
chk "S8b apagar a linha wisp- reprova a cobertura da política (o teste tem dente)" test -n "$OUT"
pc_label() { awk -v n="$1" 'index($0, n "=\"${") == 1 { s = $0; sub(/^[^:]*:-/, "", s); sub(/}".*$/, "", s); print s; exit }' "$PC" 2>/dev/null; }
tun="$(pc_label TUNNEL_LABEL)"; snd="$(pc_label SENDER_LABEL)"; OUT="túnel='$tun' sender='$snd'"
chk "S8c o post-check noturno confere um túnel e um sender (labels lidos do script)" test -n "$tun" -a -n "$snd"
chk "S8c o túnel que o post-check confere está na camada 4, com linha PRÓPRIA" pin "$tun" 4 explicito
chk "S8c o sender que o post-check confere é da camada 5 (envios)" test "$(printf '%s\n' "$snd" | libf "$REAL" m64_classificar | cut -f2)" = 5
grep -v '^br.urblink.cloudflared.urblink-ops' "$REAL" > "$TMP/sem-tunel.tsv"; PINT="$TMP/sem-tunel.tsv"
chk "S8c sem a linha do túnel o pino reprova (o teste tem dente)" not pin "$tun" 4 explicito; PINT=""
# m64_nao_carregados direto: 2 itens com um launchctl que engole a entrada (o </dev/null protege o laço) e a última linha SEM LF (o laço não a perde)
: > "$TMP/estado-vazio"
nao_carr() { ( HOME=/x; . "$LIB"; M64_UID=1; LAUNCHCTL="$TMP/stub/launchctl"; export STUB_ESTADO="$TMP/estado-vazio" STUB_LOG="$TMP/stub.log" STUB_SLURP="${1:-}"; m64_nao_carregados ); }
OUT="$(printf 'com.cidade.a1\t1\tpadrao\ncom.cidade.zz\t5\tpadrao\n' | nao_carr 1)"; chk "S8d o laço de m64_nao_carregados não é engolido por um launchctl que lê a entrada (2 de 2)" test "$OUT" = "$(printf 'com.cidade.a1\ncom.cidade.zz')"
OUT="$(printf 'com.cidade.a1\t1\tpadrao\ncom.cidade.zz\t5\tpadrao' | nao_carr)"; chk "S8d ...e lê a última linha mesmo sem LF final" test "$OUT" = "$(printf 'com.cidade.a1\ncom.cidade.zz')"
OUT="$(printf 'org.terceiro.x\t-\tfora\n' | nao_carr)"; chk "S8d ...e ignora o que é de fora da cidade" test -z "$OUT"

echo "== espera.sh"
mk_world w1 $LBL; run e status
expect 0 '^espera: desligada' "S9 status de um HOME virgem: desligada"
says 'org.terceiro.x' "S9 ...e lista o que a espera não move"
b="$(snap)"; run e ligar
expect 0 'PRÉVIA, nada mudou.*--aplicar' "S10 ligar sem --aplicar é só prévia"
chk "S10 ...e não mudou nada (nem marcador nem launchctl)" test "$b" = "$(snap)" -a "$(nlog)" = 0 -a ! -e "$H/.mini64-espera"
says 'esta máquina é .*--aplicar --confirmo mini-novo' "S10 ...e a prévia diz em que máquina está e traz o comando com a chave"
# a chave contra rodar o ligar no mini em produção (único lugar onde estes comandos rodam hoje): --aplicar sem --confirmo mini-novo é recusado e não toca em nada
run e ligar --aplicar; expect 1 'RECUSADO.*--confirmo mini-novo' "S10 ligar --aplicar sem a chave: recusado (rc 1)"
run e ligar --aplicar --confirmo mini-velho; expect 1 'RECUSADO.*--confirmo mini-novo' "S10 ...e com a chave errada também"
chk "S10 ...nada mudou: sem marcador, nenhum plist movido, launchctl intocado" test "$b" = "$(snap)" -a "$(nlog)" = 0 -a ! -e "$H/.mini64-espera"
run e desligar --confirmo mini-novo; expect 1 'uso:' "S10 --confirmo só existe no ligar (desligar: uso)"
run e status --confirmo mini-novo; expect 1 'uso:' "S10 ...e o status também recusa"
run e ligar --aplicar --confirmo; expect 1 'uso:' "S10 --confirmo sem valor: uso"
run e ligar --aplicar --confirmo mini-novo
expect 0 '7 plists movidos' "S11 ligar --aplicar"
chk "S11 a cidade foi para a espera" all_in "$ESPD" $C0.a0 $C0.a1 $C0.b1 $C0.a2 $C0.a3 $C0.a4 $C0.z5
chk "S11 ...e saiu de LaunchAgents, que ficou só com o de terceiro e o .bak" none_in "$AG" $C0.a0 $C0.a1 $C0.b1 $C0.a2 $C0.a3 $C0.a4 $C0.z5
chk "S11 ...o de terceiro e o .bak não foram tocados" test -f "$AG/org.terceiro.x.plist" -a -f "$AG/$C0.velho.plist.bak"
chk "S11 o marcador existe e o launchctl só foi consultado (list)" test -f "$H/.mini64-espera" -a "$(grep -vc '^list$' "$W/log")" = 0
run e status; expect 0 '^espera: ligada' "S11 status: ligada"
b="$(ls "$AG" "$ESPD")"; run e ligar --aplicar --confirmo mini-novo
expect 0 '0 plists movidos' "S12 ligar de novo não quebra nem mexe em nada"
chk "S12 ...as pastas ficam iguais" test "$b" = "$(ls "$AG" "$ESPD")"
printf 'VERSAO NOVA\n' > "$AG/$C0.a1.plist"; run e ligar --aplicar --confirmo mini-novo
expect 0 '1 plists movidos' "S13 cópia nova de um plist já parado"
chk "S13 ...a nova é a vigente" grep -q 'VERSAO NOVA' "$ESPD/$C0.a1.plist"
chk "S13 ...e a antiga ficou como .anterior (nada foi apagado)" test "$(ls "$ESPD"/$C0.a1.plist.anterior-* 2>/dev/null | wc -l | tr -d ' ')" = 1 -a -n "$(grep -l "<plist>$C0.a1" "$ESPD"/$C0.a1.plist.anterior-*)"
mk_world w11 $LBL; ln -s /nonexistent/destino "$AG/$C0.elo.plist"; run e ligar --aplicar --confirmo mini-novo
expect 0 '8 plists movidos' "S13 plist que é symlink (e quebrado) também é movido"
chk "S13 ...continua symlink na espera e não sobrou nada em LaunchAgents" test -L "$ESPD/$C0.elo.plist" -a ! -L "$AG/$C0.elo.plist"
mk_world w2 $LBL; echo $C0.a1 > "$W/estado"; run e ligar --aplicar --confirmo mini-novo
expect 3 'JÁ ESTÃO CARREGADOS.*com.cidade.a1' "S14 job parado que já estava carregado: aviso e rc 3"
chk "S14 ...e os plists foram movidos mesmo assim" test -f "$ESPD/$C0.a1.plist" -a -f "$H/.mini64-espera"
mk_world w3 $LBL; LRC=1; run e ligar --aplicar --confirmo mini-novo; LRC=""
expect 3 'não consegui conferir' "S14 não conseguir listar o que está carregado também é rc 3 (nunca \"nenhum carregado\")"
mk_world w4 $LBL; rm -rf "$AG"; : > "$AG"; run e status
expect 2 'nao-sei' "S15 LaunchAgents ilegível: status diz nao-sei"
chk "S15 ...e nunca diz desligada" not grep -q 'espera: desligada' <<<"$OUT"
run e ligar --aplicar --confirmo mini-novo; expect 2 '-' "S15 ligar com LaunchAgents ilegível: rc 2"
chk "S15 ...e não grava marcador" not has "$H/.mini64-espera"
mk_world w5 $LBL; mkdir "$H/.mini64-espera"; run e status
expect 2 'nao-sei' "S15 marcador que existe e não é arquivo: nao-sei"
run c 0 --aplicar; expect 2 '-' "S15 ...e o carregar-camada também sai 2"
mk_world w6 $LBL; : > "$ESPD"; run e status
expect 2 'nao-sei' "S15 espera/ que não é pasta: nao-sei"
run e ligar --aplicar --confirmo mini-novo; expect 2 '-' "S15 ...e ligar recusa (rc 2) sem mover nada"
chk "S15 ...a cidade continua onde estava" test -f "$AG/$C0.a0.plist" -a ! -e "$H/.mini64-espera"
OUT="$(env HOME=/ M64_TSV="$FIX" bash "$ESP" status 2>&1)"; RC=$?; expect 2 'HOME.*espera: nao-sei' "S15 HOME='/' é recusado e o status diz nao-sei"
OUT="$(env -u HOME M64_TSV="$FIX" bash "$ESP" status 2>&1)"; RC=$?; expect 2 'HOME' "S15 HOME ausente é recusado"
TSV="$TMP/nao-existe.tsv"; run e status; expect 2 'tabela ilegível' "S15 tabela ilegível: rc 2"; TSV="$FIX"
mk_world w8 $LBL; run e ligar --aplicar --confirmo mini-novo; run e desligar --aplicar
expect 1 'recusado.*\[camada 0: 1\]' "S16 desligar com plists parados é recusado e diz quais camadas faltam"
chk "S16 ...e o marcador continua" test -f "$H/.mini64-espera"
carrega_tudo; run e status; expect 0 '^espera: carga-completa' "S16 depois das seis camadas: carga-completa"
run e desligar; expect 0 'PRÉVIA' "S16 desligar sem --aplicar é prévia"
chk "S16 ...e o marcador continua" test -f "$H/.mini64-espera"
run e desligar --aplicar; expect 0 'encerrada' "S16 desligar --aplicar"
chk "S16 o marcador virou .encerrada-* (não foi apagado)" test ! -e "$H/.mini64-espera" -a -n "$(ls "$H"/.mini64-espera.encerrada-* 2>/dev/null)"
run e status; expect 0 '^espera: desligada' "S16 status: desligada"
run e desligar --aplicar; expect 0 'já está desligada' "S16 desligar de novo: já desligada, rc 0"
mk_world w9 $LBL; run e ligar --aplicar --confirmo mini-novo; mv "$H/.mini64-espera" "$W/guardado"; run e status
expect 0 '^espera: inconsistente' "S17 plists parados sem marcador: inconsistente"
run e desligar --aplicar; expect 1 'recusado' "S17 ...e desligar recusa"
mk_world w10 $LBL; run e ligar --aplicar --confirmo mini-novo; TSV="$TMP/outra-familia.tsv"; run e status
expect 0 'fora da tabela.*com.cidade.z5' "S18 plist parado que a tabela não conhece: listado como fora da tabela"
for n in 0 1 2 3; do carrega "$n"; done >/dev/null; carrega 4 >/dev/null; carrega 5
expect 0 'nenhum plist desta camada' "S18 camada 5: o plist fora da tabela nunca é carregado"
chk "S18 ...e continua na espera" test -f "$ESPD/$C0.z5.plist"
run e desligar --aplicar; expect 1 'recusado' "S18 ...e desligar recusa enquanto ele estiver lá"; TSV="$FIX"
# S19: um ligar que não conseguiu mover (marcador + plists soltos) não pode parecer uma carga: só os arquivos não distinguem, o launchctl diz o que está carregado
mk_world w12 $LBL; MVF='\.plist$'; run e ligar --aplicar --confirmo mini-novo; MVF=""
expect 3 'não consegui mover.*0 plists movidos para .*7 falhas' "S19 ligar com o mv recusando tudo: rc 3, 0 movidos"
run e status; expect 0 '^espera: plists-soltos.*SOLTOS.*com.cidade.a0' "S19 nada movido e nada carregado: plists-soltos (antes: carga-completa)"
chk "S19 ...e nunca carga-completa nem em-carga" not grep -Eq 'espera: (carga-completa|em-carga)' <<<"$OUT"
run e desligar --aplicar; expect 1 'recusado.*7 plists.*soltos' "S19 desligar recusa: os 7 plists carregariam no próximo login"
chk "S19 ...e o marcador continua (não virou .encerrada)" test -f "$H/.mini64-espera" -a -z "$(ls "$H"/.mini64-espera.encerrada-* 2>/dev/null)"
run e ligar --aplicar --confirmo mini-novo; expect 0 '7 plists movidos' "S19 rodar ligar de novo (o que o status manda) termina o serviço"
run e status; expect 0 '^espera: ligada' "S19 ...e o status vira ligada"
mk_world w13 $LBL; MVF='^com\.cidade\.(a1|a3)\.plist$'; run e ligar --aplicar --confirmo mini-novo; MVF=""
run e status; expect 0 '^espera: plists-soltos.*com.cidade.a1.*com.cidade.a3' "S19 parte movida (5 de 7): plists-soltos, não em-carga"
mk_world w14 $LBL; MVF='\.plist$'; run e ligar --aplicar --confirmo mini-novo; MVF=""; PRC=77; run e status
expect 2 '^espera: nao-sei.*launchd' "S19 launchctl sem resposta: o status diz nao-sei (nunca carga-completa)"
run e desligar --aplicar; PRC=""; expect 2 'launchd' "S19 ...e desligar sai 2 sem encerrar"
chk "S19 ...com o marcador no lugar" test -f "$H/.mini64-espera"

echo "== carregar-camada.sh"
mk_world c1 $LBL; run e ligar --aplicar --confirmo mini-novo; b="$(snap)"; n0="$(nlog)"
for n in x 1x -1 1234 7 ""; do run c "$n" --aplicar; expect 1 'uso:|camada inválida|não existe na tabela' "S20 camada '$n' é recusada"; done
chk "S20 ...sem mexer em nada nem chamar o launchctl" test "$b" = "$(snap)" -a "$(nlog)" = "$n0"
run c; expect 1 'uso:' "S21 sem argumento: uso"
run c 1 2; expect 1 'uso:' "S21 dois números: uso"
run c 1 --foo; expect 1 'uso:' "S21 flag desconhecida: uso"
run c 1 --confirmo; expect 1 'uso:' "S21 --confirmo sem valor: uso"
mk_world c2 $LBL; run c 0 --aplicar
expect 1 'espera não está ligada' "S22 sem marcador não há o que devolver"
chk "S22 ...e nada foi movido" test -f "$AG/$C0.a0.plist" -a "$(nlog)" = 0
run e ligar --aplicar --confirmo mini-novo; run c 1 --aplicar
expect 1 'camada anterior.*\[camada 0: 1\]' "S23 camada 1 antes da 0 é recusada (a ordem é a regra)"
chk "S23 ...nada voltou e nada foi carregado" test -f "$ESPD/$C0.a1.plist" -a "$(nboot)" = 0
run c 0 --aplicar; expect 0 '1 carregados' "S23 camada 0 --aplicar"
chk "S23 o plist voltou e o bootstrap usou o caminho de dentro do HOME de mentira" grep -q "^bootstrap gui/[0-9]* $AG/$C0.a0.plist$" "$W/log"
run e status; expect 0 '^espera: em-carga' "S23 camada 0 de pé: em-carga (o que voltou está carregado, o resto espera)"
cp "$ESPD/$C0.a3.plist" "$AG/$C0.a3.plist"; run c 1 --aplicar
expect 1 'posterior.*ligar --aplicar' "S24 plist de camada posterior solto em LaunchAgents: recusa e manda rodar ligar"
mv "$AG/$C0.a3.plist" "$W/a3.fora"; b="$(snap)"; n0="$(nboot)"; run c 1
expect 0 'PRÉVIA, nada muda' "S25 prévia da camada 1"
chk "S25 ...não moveu nada nem chamou o bootstrap" test "$b" = "$(snap)" -a "$(nboot)" = "$n0"
run c 1 --aplicar; expect 0 '2 carregados' "S25 camada 1 --aplicar (a1 e b1)"
run c 2; expect 1 'exige --confirmo antigo-aposentado' "S26 a prévia da camada 2 também diz que exige --confirmo"
run c 2 --aplicar; expect 1 'exige --confirmo antigo-aposentado' "S26 camada 2 sem --confirmo"
run c 2 --aplicar --confirmo outra-coisa; expect 1 'exige --confirmo antigo-aposentado' "S26 camada 2 com a chave errada"
chk "S26 ...nada voltou" test -f "$ESPD/$C0.a2.plist"
run c 2 --aplicar --confirmo antigo-aposentado; expect 0 '1 carregados' "S26 camada 2 com a chave certa"
n0="$(nboot)"; run c 2 --aplicar --confirmo antigo-aposentado
expect 0 '1 já carregados.*0 falhas' "S27 rodar a camada de novo: já carregado, nada a fazer"
chk "S27 ...e nenhum bootstrap novo" test "$(nboot)" = "$n0"
mk_world c3 $LBL; run e ligar --aplicar --confirmo mini-novo; carrega 0 >/dev/null; FALHA=$C0.a1; run c 1 --aplicar; FALHA=""
expect 3 'FALHA com.cidade.a1.*bootstrap recusado' "S28 bootstrap que falha: rc 3 e diz qual"
chk "S28 ...o plist ficou em LaunchAgents e o irmão carregou" test -f "$AG/$C0.a1.plist" -a "$(grep -c $C0.b1 "$W/estado")" = 1 -a "$(grep -c $C0.a1 "$W/estado")" = 0
run e status; expect 0 '^espera: plists-soltos.*com.cidade.a1' "S28 ...e o status mostra o plist que ficou solto e não carregou"
run c 1 --aplicar; expect 0 '1 carregados, 1 já carregados' "S28 rodar de novo carrega só o que faltava"
mk_world c4 $LBL; run e ligar --aplicar --confirmo mini-novo; carrega 0 >/dev/null; PRC=77; n0="$(nboot)"; run c 1 --aplicar; PRC=""
expect 3 'não sei se já está carregado' "S29 \"carregado?\" sem resposta: rc 3"
chk "S29 ...e não carregou nada às cegas" test "$(nboot)" = "$n0"
mk_world c5 $LBL; run e ligar --aplicar --confirmo mini-novo; carrega 0 >/dev/null; printf 'OUTRA\n' > "$AG/$C0.a1.plist"; cp "$ESPD/$C0.a1.plist" "$W/a1.espera"
run c 1 --aplicar; expect 3 'existe na espera E em LaunchAgents' "S30 o mesmo plist nos dois lados: rc 3"
chk "S30 ...o de LaunchAgents não foi sobrescrito" grep -q OUTRA "$AG/$C0.a1.plist"
chk "S30 ...o da espera também não" cmp -s "$ESPD/$C0.a1.plist" "$W/a1.espera"
mk_world c6 $C0.a0 $C0.a1 $C0.a2 $C0.a3; run e ligar --aplicar --confirmo mini-novo; for n in 0 1 2 3; do carrega "$n"; done >/dev/null; carrega 4
expect 0 'nenhum plist desta camada' "S30 camada sem plist nesta máquina: rc 0 e avisa"
run e status; expect 0 '^espera: carga-completa' "S30 ...e a carga está completa"

echo "== cão de guarda"
mk_world g1 $LBL; run e ligar --aplicar --confirmo mini-novo; carrega 0 >/dev/null; n0="$(ntrip)"
OUT="$(env HOME="$H" PATH="$TMP/trip:$PATH" TRIP_LOG="$TMP/trip.log" M64_TSV="$FIX" bash "$CAR" 0 2>&1)"; RC=$?
expect 3 'não sei se já está carregado' "S31 sem \$MINI64_LAUNCHCTL o script cairia no launchctl do PATH: o cão de guarda o pega e o script trata como \"não sei\""
chk "S31 ...e o cão de guarda anotou exatamente essa chamada (ele está vivo)" test "$(ntrip)" = "$((n0 + 1))"
chk "S31 nenhuma outra execução do selftest chegou ao launchctl do PATH" test "$(ntrip)" = 1
chk "S32 nada foi criado no HOME real" test "$REAL0" = "$(real_snap)"
echo "== $PASS ok, $FAIL BAD"
[ "$FAIL" -eq 0 ]
