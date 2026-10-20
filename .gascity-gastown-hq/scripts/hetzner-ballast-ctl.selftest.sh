#!/usr/bin/env bash
# hetzner-ballast-ctl.selftest.sh — hermético (ga-2hd02v.5): o "nó" é uma pasta (HOME de mentira) e o ssh é um stub que roda o comando remoto com `sh -c` nesse HOME; o crontab também é de mentira.
# Nada fala com host nenhum e nada toca em ~/gt-remote nem na crontab de verdade.
#
# Contents
#   Casos · Variáveis
#
# CASOS
#   instalar (g_install): sem a bandeira do nó = rc 99 · árvore com mudança não commitada nos arquivos do lastro = rc 3 (sobe o que está no git, não o que está na mesa) · copia governo, itens e registro
#     e CONFERE o sha256 do que chegou · crontab: UMA linha marcada (instalar duas vezes não duplica), as linhas dos outros ficam · NÃO liga o lastro (a chave `on` é um passo à parte) · arquivo que
#     chega diferente = rc 3 e a crontab não muda · ssh fora = rc 98 sem efeito algum · desinstalar tira só a linha marcada e para o que roda.
#   ligar e medir (g_ctl): on/off criam e apagam a chave (off também para) · burn on/off · status mostra o estado e acusa PARADO quando o cron está instalado e o último tick é velho · pull traz só os
#     campos da lista branca, de uma linha por rodada, sem duplicar na 2ª vez, e ssh fora deixa o arquivo como estava.
# VARIÁVEIS: HBC_UNDER_TEST (script a testar) · HBC_NO_MUTANTS=1 · HBC_ONLY=<grupo> (install ctl)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
P="${HBC_UNDER_TEST:-$HERE/hetzner-ballast.sh}"
PY="${HBC_PY:-/usr/bin/python3}"
T=$(cd "$(mktemp -d /tmp/hbc.XXXXXX)" && pwd -P)
cleanup() { chmod -R u+rwX "$T" 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null; }
trap cleanup EXIT
fails=0; n=0
ok() { n=$((n+1)); if [ "$1" = 0 ]; then [ -n "${HBC_MUTANT:-}" ] || echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); [ -z "${HBC_MUTANT:-}" ] || { echo "RESULT $fails/$n"; exit 1; }; fi; }
check() { if [ "$2" = "$3" ]; then ok 0 "$1"; else ok 1 "$1 (esperado '$2', veio '$3')"; fi; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# ── fixtures ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
N=0
newenv() {  # repo de brinquedo com os arquivos do lastro commitados, o "nó" (HOME de mentira), a cidade (.gc) e os stubs
  N=$((N+1)); R="$T/repo$N"; NODE="$T/node$N"; BIN="$T/bin$N"; mkdir -p "$R/scripts/hetzner-ballast-items" "$R/.gc" "$NODE/gt-remote/bin" "$BIN"
  cp "$HERE/hetzner-ballast.sh" "$R/scripts/" 2>/dev/null; [ -z "${HBC_UNDER_TEST:-}" ] || cp "$HBC_UNDER_TEST" "$R/scripts/hetzner-ballast.sh"
  printf '#!/usr/bin/env python3\nimport sys\nprint("governo de mentira", sys.argv[1:])\n' > "$R/scripts/hetzner-ballast.py"
  printf '#!/bin/bash\necho item hq\n' > "$R/scripts/hetzner-ballast-items/hq-selftests.sh"; printf '#!/bin/bash\necho item queima\n' > "$R/scripts/hetzner-ballast-items/queima.sh"
  printf '# registro\nhq-selftests\twork\tauto\t4096\t10800\t600\t-\thq-selftests.sh\n' > "$R/scripts/hetzner-ballast.items.txt"
  git -C "$R" init -q && git -C "$R" add -A && git -C "$R" commit -q -m base
  : > "$R/.gc/hetzner-node.on"; : > "$T/crontab$N"; rm -f "$T/ssh.fail" "$T/ssh.corrupt"
  # crontab de mentira: lê/grava $T/crontab<N>
  printf '#!/bin/sh\ncase "$1" in -l) cat "%s" 2>/dev/null; [ -s "%s" ] || { echo "no crontab for runner" >&2; exit 1; } ;; -) cat > "%s" ;; *) cat "$1" > "%s" ;; esac\n' "$T/crontab$N" "$T/crontab$N" "$T/crontab$N" "$T/crontab$N" > "$BIN/crontab"; chmod +x "$BIN/crontab"
  # ssh de mentira: roda o comando remoto com sh -c no HOME do "nó"; HBC_SSH_CORRUPT estraga o que o `cat >` grava
  cat > "$BIN/ssh" <<EOF
#!/bin/sh
[ -f "$T/ssh.fail" ] && { echo "ssh: connect to host stub port 22: Connection timed out" >&2; exit 255; }
echo "\$*" >> "$T/ssh.calls"
while [ "\${1#-}" != "\$1" ]; do case "\$1" in -o) shift 2;; *) shift;; esac; done
shift   # o host
case "\$*" in *"cat >"*) if [ -f "$T/ssh.corrupt" ]; then sed '1s/^/X/' | HOME="$NODE" PATH="$BIN:\$PATH" sh -c "\$*"; exit \$?; fi;; esac
HOME="$NODE" PATH="$BIN:\$PATH" sh -c "\$*"
EOF
  chmod +x "$BIN/ssh"; : > "$T/ssh.calls"
}
ctl() {  # ctl ARGS… → $OUT (stdout+stderr), $RC
  OUT=$(cd "$R" && env PATH="$BIN:$PATH" HB_SSH="$BIN/ssh" HETZNER_NODE_HOST=stub GC_CITY_PATH="$R" bash "$R/scripts/hetzner-ballast.sh" "$@" 2>&1); RC=$?
}
cron_lines() { cat "$T/crontab$N" 2>/dev/null | grep -c 'gt-ballast'; }

g_install() {
  newenv; rm -f "$R/.gc/hetzner-node.on"; ctl install
  check "install: sem a bandeira do nó (.gc/hetzner-node.on) → rc 99, nada enviado" "99 0" "$RC $(wc -l < "$T/ssh.calls" | tr -d ' ')"
  newenv; echo '# mexido' >> "$R/scripts/hetzner-ballast.py"; ctl install
  check "install: arquivo do lastro com mudança NÃO commitada → rc 3 (sobe o que está no git), nada enviado" "3 0" "$RC $(wc -l < "$T/ssh.calls" | tr -d ' ')"
  newenv; rm -rf "$R/.git"; ctl install
  check "install: git ilegível (fora de um repo) → rc 3, nada enviado (não sei se está commitado: nunca 'limpo')" "3 0" "$RC $(wc -l < "$T/ssh.calls" | tr -d ' ')"
  newenv; echo '# mexido' >> "$R/scripts/hetzner-ballast.py"; ctl install --allow-dirty
  check "install: --allow-dirty libera e o instalado.json diz que subiu SUJO" "0 1" "$RC $(grep -c '"dirty": true' "$NODE/gt-remote/ballast/installed.json" 2>/dev/null)"

  newenv; ctl install
  check "install: rc 0" "0" "$RC"
  check "install: governo no nó em ~/gt-remote/bin/hetzner-ballast.py, executável" "1" "$([ -x "$NODE/gt-remote/bin/hetzner-ballast.py" ] && echo 1 || echo 0)"
  check "install: itens em ~/gt-remote/ballast/items/ (hq-selftests.sh e queima.sh) e o registro em items.tsv" "1 1 1" "$([ -x "$NODE/gt-remote/ballast/items/hq-selftests.sh" ] && echo 1 || echo 0) $([ -x "$NODE/gt-remote/ballast/items/queima.sh" ] && echo 1 || echo 0) $([ -s "$NODE/gt-remote/ballast/items.tsv" ] && echo 1 || echo 0)"
  check "install: o conteúdo que chegou é o do git (diff vazio)" "0" "$(diff -q "$R/scripts/hetzner-ballast.py" "$NODE/gt-remote/bin/hetzner-ballast.py" > /dev/null 2>&1; echo $?)"
  check "install: instalado.json guarda o commit e os sha256 (dirty false)" "1 1" "$(grep -c '"dirty": false' "$NODE/gt-remote/ballast/installed.json") $(grep -c 'hetzner-ballast.py' "$NODE/gt-remote/ballast/installed.json")"
  check "install: UMA linha marcada na crontab, a cada minuto, com flock e sem saída no stdout" "1 1 1" "$(cron_lines) $(grep -c '^\* \* \* \* \* ' "$T/crontab$N") $(grep -c 'flock -n' "$T/crontab$N")"
  check "install: NÃO liga o lastro (a chave on é um passo à parte)" "0" "$([ -e "$NODE/gt-remote/ballast/on" ] && echo 1 || echo 0)"
  ctl install; check "install: de novo não duplica a linha da crontab" "1" "$(cron_lines)"

  newenv; printf '30 4 * * * /usr/bin/algo-do-outro\n' > "$T/crontab$N"; ctl install
  check "install: as linhas de OUTROS na crontab ficam" "1 1" "$(grep -c 'algo-do-outro' "$T/crontab$N") $(cron_lines)"
  ctl uninstall; check "uninstall: tira só a linha marcada (a do outro fica) e rc 0" "0 1 0" "$RC $(grep -c 'algo-do-outro' "$T/crontab$N") $(cron_lines)"
  check "uninstall: chama o stop do governo (para o que roda)" "1" "$(grep -c 'hetzner-ballast.py" stop' "$T/ssh.calls")"
  check "uninstall: os arquivos (e os resultados) ficam no nó" "1" "$([ -x "$NODE/gt-remote/bin/hetzner-ballast.py" ] && echo 1 || echo 0)"

  newenv; touch "$T/ssh.corrupt"; ctl install
  check "install: arquivo que chega diferente do enviado → rc 3 e a crontab NÃO muda" "3 0" "$RC $(cron_lines)"
  newenv; touch "$T/ssh.fail"; ctl install
  check "install: ssh fora → rc 98, nada na crontab" "98 0" "$RC $(cron_lines)"
}

g_ctl() {
  newenv; ctl install; ctl on
  check "on: cria a chave on no nó" "0 1" "$RC $([ -e "$NODE/gt-remote/ballast/on" ] && echo 1 || echo 0)"
  ctl off; check "off: apaga a chave e manda o stop" "0 0 1" "$RC $([ -e "$NODE/gt-remote/ballast/on" ] && echo 1 || echo 0) $(grep -c 'hetzner-ballast.py" stop' "$T/ssh.calls")"
  ctl burn on; check "burn on: cria burn.on" "1" "$([ -e "$NODE/gt-remote/ballast/burn.on" ] && echo 1 || echo 0)"
  ctl burn off; check "burn off: apaga burn.on" "0" "$([ -e "$NODE/gt-remote/ballast/burn.on" ] && echo 1 || echo 0)"
  ctl burn; check "burn sem on/off → uso errado, rc 2" "2" "$RC"
  ctl bogus; check "subcomando desconhecido → rc 2" "2" "$RC"

  newenv; ctl install; mkdir -p "$NODE/gt-remote/ballast"; printf '{"t": %s}\n' "$(( $(date +%s) - 3000 ))" > "$NODE/gt-remote/ballast/ticks.jsonl"; ctl status
  check "status: cron instalado e o último tick tem 50 min → PARADO" "1" "$(printf '%s' "$OUT" | grep -c 'PARADO')"
  printf '{"t": %s}\n' "$(date +%s)" > "$NODE/gt-remote/ballast/ticks.jsonl"; ctl status
  check "status: tick recente → sem PARADO e mostra o cron" "0 1" "$(printf '%s' "$OUT" | grep -c 'PARADO') $(printf '%s' "$OUT" | grep -c 'cron: instalado')"
  newenv; ctl status; check "status: cron NÃO instalado → diz isso" "1" "$(printf '%s' "$OUT" | grep -c 'cron: não instalado')"
  newenv; touch "$T/ssh.fail"; ctl status; check "status: ssh fora → rc 98" "98" "$RC"

  newenv; ctl install; mkdir -p "$NODE/gt-remote/ballast"
  { printf '{"ts":"x","item":"hq-selftests","run":"hq-selftests-1","role":"work","cores":8,"start":1,"secs":9,"rc":0,"why":"ok","summary":{"total":5,"names":["a","b"],"longo":"%s"},"summary_why":"","segredo":"nao-pode"}\n' "$(printf 'x%.0s' $(seq 1 300))"
    printf 'isto não é json\n'
    printf '{"ts":"y","item":"hq-selftests","run":"hq-selftests-2","rc":3,"why":"rc-3","summary":null,"summary_why":"ausente"}\n'; } > "$NODE/gt-remote/ballast/results.jsonl"
  ctl pull; OUTF="$R/.gc/hetzner-ballast/results.jsonl"
  check "pull: rc 0 e duas linhas válidas (a que não é JSON é descartada e avisada)" "0 2 1" "$RC $(wc -l < "$OUTF" | tr -d ' ') $(printf '%s\n' "$OUT" | grep -c 'linha descartada')"
  check "pull: campo fora da lista branca (segredo) não vem" "0" "$(grep -c 'nao-pode' "$OUTF")"
  check "pull: string longa do resumo (300) é cortada em 160 e a lista curta fica" "1 160" "$(grep -c '"names": \["a", "b"\]' "$OUTF") $("$PY" -I -c 'import json,sys; print(len(json.loads(open(sys.argv[1]).readline())["summary"]["longo"]))' "$OUTF")"
  ctl pull; check "pull: de novo não duplica (mesma rodada)" "2" "$(wc -l < "$OUTF" | tr -d ' ')"
  touch "$T/ssh.fail"; ctl pull; check "pull: ssh fora → rc 98 e o arquivo fica como estava" "98 2" "$RC $(wc -l < "$OUTF" | tr -d ' ')"
}

if [ -n "${HBC_MUTANT:-}" ]; then g_install; g_ctl; echo "RESULT $fails/$n"; [ "$fails" = 0 ]; exit $?; fi
if [ -n "${HBC_ONLY:-}" ]; then "g_$HBC_ONLY"; echo "── $((n - fails))/$n ok (só g_$HBC_ONLY)"; [ "$fails" = 0 ]; exit $?; fi
g_install; g_ctl

[ -n "${HBC_NO_MUTANTS:-}" ] || {
  echo "── controle negativo: cada mutante tem que reprovar a bateria ──"
  cat > "$T/mutants.txt" <<'MUT'
nó desligado não impede instalar@@[ -e "$CITY/.gc/hetzner-node.on" ] || die 99@@true || die 99
árvore suja sobe sem --allow-dirty@@[ "$allow" = 1 ] && dirty=true ||@@dirty=true ||
git ilegível é tratado como limpo@@    rc=*) die 3 "não consegui ler o estado do git@@    rc=*) dirty=false; true "não consegui ler o estado do git
o sha256 que chegou não é conferido@@    [ "$got" = "$want" ] || {@@    true || {
a linha antiga da crontab não sai (duplica)@@grep -v "'"$MARK"'" > "$T"; echo "* * * * * flock@@cat > "$T"; echo "* * * * * flock
desinstalar não para o que roda@@  stop_remote | sed 's/^/  stop: /'
  say "desinstalado@@  say "desinstalado
desligar não manda o stop@@if [ "$1" = on ] && [ "$2" = off ]; then stop_remote@@if false; then stop_remote
ssh fora no pull não vira 98@@  [ "$rc" -ne 255 ] || die 98 "ssh não conectou ($NODE): results.jsonl local fica como estava"@@  true
o pull duplica a rodada que já veio@@    if d["run"] in seen:
        continue@@    if False:
        continue
o pull traz campo fora da lista branca@@    row = {k: (clean(d[k]) if k == "summary" else scal(d[k])) for k in KEEP if k in d}@@    row = dict(d)
o pull não corta string longa@@        return v[:160]@@        return v
status não acusa PARADO@@    if kv.get("cron") == "1" and age > 300:@@    if False:
ssh fora no install não vira 98@@    [ "$rc" -ne 255 ] || die 98 "ssh não conectou ($NODE): nada foi instalado"@@    true
MUT
  "$PY" -I - "$P" "$T/mutants.txt" "$T" > "$T/mutants.idx" <<'PYEOF'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
entries, cur = [], None
for line in open(sys.argv[2], encoding="utf-8").read().split("\n"):
    if cur is None or (cur.count("@@") >= 2 and re.match(r"^[^@\s][^@]*@@", line)):
        if cur is not None:
            entries.append(cur)
        cur = line
    else:
        cur += "\n" + line
if cur:
    entries.append(cur)
for i, e in enumerate(entries, 1):
    parts = e.split("@@")
    if len(parts) != 3 or src.count(parts[1]) != 1:
        print("%d\tBAD\t%s" % (i, parts[0])); continue
    open("%s/mut%d.sh" % (sys.argv[3], i), "w", encoding="utf-8").write(src.replace(parts[1], parts[2]))
    print("%d\tOK\t%s" % (i, parts[0]))
PYEOF
  JOBS=${HBC_JOBS:-4}
  while IFS="$(printf '\t')" read -r idx st desc; do
    if [ "$st" != OK ]; then ok 1 "mutante '$desc': a âncora não casa exatamente 1 vez (o script mudou?)"; continue; fi
    while [ "$(jobs -r | wc -l | tr -d ' ')" -ge "$JOBS" ]; do sleep 0.3; done
    ( HBC_MUTANT=1 HBC_UNDER_TEST="$T/mut$idx.sh" bash "$0" 2>&1 | tail -1 > "$T/mres.$idx" ) &
  done < "$T/mutants.idx"
  wait
  while IFS="$(printf '\t')" read -r idx st desc; do
    [ "$st" = OK ] || continue
    r=$(cat "$T/mres.$idx" 2>/dev/null)
    case "$r" in "RESULT 0/"*) ok 1 "mutante '$desc' NÃO foi pego ($r)";; "RESULT "*) ok 0 "mutante '$desc' pego ($r)";; *) ok 1 "mutante '$desc': sem resultado ($r)";; esac
  done < "$T/mutants.idx"
}
echo "── $((n - fails))/$n ok"
[ "$fails" = 0 ]
