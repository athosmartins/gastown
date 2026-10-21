#!/usr/bin/env bash
# hetzner-ballast-ctl.selftest.sh — hermético (ga-2hd02v.5): o "nó" é uma pasta (HOME de mentira) e o ssh é um stub que roda o comando remoto com `sh -c` nesse HOME; o crontab também é de mentira.
# Nada fala com host nenhum e nada toca em ~/gt-remote nem na crontab de verdade.
#
# Contents
#   Casos · Variáveis
#
# CASOS
#   instalar (g_install): sem a bandeira do nó = rc 99 · árvore com mudança não commitada nos arquivos do lastro = rc 3 (sobe o que está no git, não o que está na mesa; vale também para arquivo ignorado
#     ou assume-unchanged, que o git status não vê) · copia governo, itens e registro e CONFERE o sha256 do que chegou (dois sha vazios não são "iguais") · crontab: UMA linha marcada (instalar duas vezes
#     não duplica), as linhas dos outros ficam, e crontab que NÃO consegui ler (ou grep que falha) = rc 3 sem escrever nada · NÃO liga o lastro · arquivo que chega diferente = rc 3 e a crontab não muda
#     · ssh fora = rc 98 sem efeito algum · desinstalar tira só a linha marcada e para o que roda — e só diz "parado" se o stop respondeu rc 0 (stop rc 3 / governo ausente = rc 3, ssh que cai no stop =
#     rc 98) · argumento a mais ou que não existe = rc 2 · todo ssh leva ServerAliveInterval/CountMax.
#   ligar e medir (g_ctl): on/off criam e apagam a chave (off também para, com a mesma regra do stop) · on sem nada instalado avisa · burn on/off · status mostra o estado e separa "não tem" de "não consegui
#     ler" (crontab, installed.json, ticks, status do governo, processos: rc 3 e a mensagem diz que não leu) · PARADO = cron instalado e último tick velho, ou nenhum tick desde um install velho · pull traz só
#     os campos da lista branca, de uma linha por rodada, sem duplicar na 2ª vez; ssh fora deixa o arquivo como estava; results.jsonl ausente = "ainda não tem" (rc 0), vazio = 0 novas, ilegível = rc 3.
#   controle negativo: ~40 mutantes do script, um por correção do gate; cada um tem que reprovar a bateria.
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
  # governo de mentira: ~/gov.fail.<cmd> no "nó" faz o <cmd> sair 3 (como o do_stop que não leu os processos); status devolve o JSON de verdade (items, registry_errors, running)
  cat > "$R/scripts/hetzner-ballast.py" <<'PYG'
#!/usr/bin/env python3
import json, os, sys
cmd = sys.argv[1] if len(sys.argv) > 1 else ""
if os.path.exists(os.path.expanduser("~/gov.fail." + cmd)):
    print("governo de mentira: %s falhou de propósito" % cmd, file=sys.stderr)
    sys.exit(3)
if cmd == "status":
    run = None if os.path.exists(os.path.expanduser("~/gov.running.null")) else []   # ~/gov.running.null: o governo não leu os processos (running null)
    print(json.dumps({"items": [{"name": "hq-selftests", "role": "work", "cores": 4, "eligible": True, "why": ""}], "registry_errors": [], "running": run}))
elif cmd == "stop":
    print(json.dumps({"stopped": []}))
else:
    print("governo de mentira", sys.argv[1:])
PYG
  printf '#!/bin/bash\necho item hq\n' > "$R/scripts/hetzner-ballast-items/hq-selftests.sh"; printf '#!/bin/bash\necho item queima\n' > "$R/scripts/hetzner-ballast-items/queima.sh"
  printf '# registro\nhq-selftests\twork\tauto\t4096\t10800\t600\t-\thq-selftests.sh\n' > "$R/scripts/hetzner-ballast.items.txt"
  git -C "$R" init -q && git -C "$R" add -A && git -C "$R" commit -q -m base
  : > "$R/.gc/hetzner-node.on"; : > "$T/crontab$N"; rm -f "$T/ssh.fail" "$T/ssh.fail.stop" "$T/ssh.fail.status" "$T/ssh.corrupt"
  # crontab de mentira: lê/grava $T/crontab<N>. Sem crontab (arquivo vazio) o -l diz "no crontab for runner" (rc 1, o vazio de verdade); com $T/crontab<N>.readfail o -l falha de outro jeito
  # (spool ilegível, rc 1) e a gravação continua funcionando — é o caso em que regravar a partir do que "leu" apagaria as linhas dos outros
  cat > "$BIN/crontab" <<EOF
#!/bin/sh
case "\$1" in
  -l) [ -e "$T/crontab$N.readfail" ] && { echo "crontab: error reading spool: Input/output error" >&2; exit 1; }
      cat "$T/crontab$N" 2>/dev/null; [ -s "$T/crontab$N" ] || { echo "no crontab for runner" >&2; exit 1; } ;;
  -) cat > "$T/crontab$N" ;;
  *) cat "\$1" > "$T/crontab$N" ;;
esac
EOF
  chmod +x "$BIN/crontab"
  # ssh de mentira: roda o comando remoto com sh -c no HOME do "nó"; ssh.corrupt estraga o que o `cat >` grava; ssh.fail.stop derruba (255) só a chamada do stop do governo; ssh.fail.status faz o comando de status sair 7 sem rodar (falha do lado de lá, ≠ 255)
  cat > "$BIN/ssh" <<EOF
#!/bin/sh
[ -f "$T/ssh.fail" ] && { echo "ssh: connect to host stub port 22: Connection timed out" >&2; exit 255; }
[ -f "$T/ssh.fail.stop" ] && case "\$*" in *'ballast.py" stop'*) echo "ssh: Connection reset by peer" >&2; exit 255;; esac
[ -f "$T/ssh.fail.status" ] && case "\$*" in *'rd tick'*) echo "sh: erro de sintaxe de mentira" >&2; exit 7;; esac
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
nlines() { wc -l < "$1" | tr -d ' '; }
sha() { if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
ago() { "$PY" -I -c 'import sys, time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - int(sys.argv[1]))))' "$1"; }   # ISO UTC de N segundos atrás

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
  check "install: instalado.json guarda o commit (HEAD), o sha256 do governo que o nó conferiu e dirty false" "$(git -C "$R" rev-parse HEAD) $(sha "$R/scripts/hetzner-ballast.py") False" "$("$PY" -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print(d["head"], d["files"]["hetzner-ballast.py"], d["dirty"])' "$NODE/gt-remote/ballast/installed.json")"
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

  # ── ga-2hd02v.5.4, gate 1: o que NÃO consegui ler ou conferir não vale "vazio" nem "igual" ──
  newenv; printf '30 4 * * * /usr/bin/algo-do-outro\n' > "$T/crontab$N"; cp "$T/crontab$N" "$T/crontab$N.antes"; : > "$T/crontab$N.readfail"; ctl install
  check "install: crontab que NÃO consegui ler (erro ≠ 'no crontab') → rc 3, crontab intocada (a linha do outro não some) e diz que não leu" "3 0 1" "$RC $(diff -q "$T/crontab$N" "$T/crontab$N.antes" > /dev/null 2>&1; echo $?) $(printf '%s' "$OUT" | grep -c 'LER a crontab')"
  newenv; ctl install; printf '30 4 * * * /usr/bin/algo-do-outro\n' >> "$T/crontab$N"; cp "$T/crontab$N" "$T/crontab$N.antes"; : > "$T/crontab$N.readfail"; : > "$T/ssh.calls"; ctl uninstall
  check "uninstall: crontab que NÃO consegui ler → rc 3, crontab intocada e o stop NÃO roda (nada de meia-desinstalação)" "3 0 0" "$RC $(diff -q "$T/crontab$N" "$T/crontab$N.antes" > /dev/null 2>&1; echo $?) $(grep -c 'hetzner-ballast.py" stop' "$T/ssh.calls")"
  newenv; ctl install; : > "$NODE/gov.fail.stop"; ctl uninstall
  check "uninstall: o governo NÃO conseguiu parar (rc 3) → rc 3, a linha da crontab saiu, avisa e NUNCA diz que o que rodava foi parado" "3 0 1 0" "$RC $(cron_lines) $(printf '%s' "$OUT" | grep -c 'NÃO consegui parar') $(printf '%s' "$OUT" | grep -c 'foi parado')"
  newenv; ctl install; rm -f "$NODE/gt-remote/bin/hetzner-ballast.py"; ctl uninstall
  check "uninstall: sem o governo no nó (o stop nem abre) → rc 3 e não diz que parou" "3 0" "$RC $(printf '%s' "$OUT" | grep -c 'foi parado')"
  newenv; ctl install; touch "$T/ssh.fail.stop"; ctl uninstall
  check "uninstall: o ssh cai só no stop → rc 98 (não sei se parou) e não diz que parou" "98 0" "$RC $(printf '%s' "$OUT" | grep -c 'foi parado')"
  newenv; echo '# mexido' >> "$R/scripts/hetzner-ballast.py"; git -C "$R" update-index --assume-unchanged scripts/hetzner-ballast.py; ctl install
  check "install: arquivo editado e marcado assume-unchanged (o git status não vê) → rc 3, nada enviado (sobe o que está no HEAD)" "3 0" "$RC $(nlines "$T/ssh.calls")"
  newenv; echo '# mexido' >> "$R/scripts/hetzner-ballast.py"; git -C "$R" update-index --assume-unchanged scripts/hetzner-ballast.py; ctl install --allow-dirty
  check "install --allow-dirty: o arquivo que o git status não vê sobe (o que está na mesa) e o instalado.json diz dirty:true" "0 1 1" "$RC $(grep -c '# mexido' "$NODE/gt-remote/bin/hetzner-ballast.py" 2>/dev/null) $(grep -c '"dirty": true' "$NODE/gt-remote/ballast/installed.json" 2>/dev/null)"
  newenv; printf '#!/bin/sh\nexit 1\n' > "$BIN/sha256sum"; cp "$BIN/sha256sum" "$BIN/shasum"; chmod +x "$BIN/sha256sum" "$BIN/shasum"; ctl install
  check "install: nenhuma ferramenta de sha256 funciona (os dois lados vazios) → rc 3, nada trocado, crontab sem a linha" "3 0 0" "$RC $([ -e "$NODE/gt-remote/bin/hetzner-ballast.py" ] && echo 1 || echo 0) $(cron_lines)"
  newenv; ctl install --allow-dirt; r1=$RC; ctl install --allow-dirty x; r2=$RC; ctl uninstall x; r3=$RC
  check "install/uninstall: argumento que não existe ou a mais → rc 2, nada enviado" "2 2 2 0" "$r1 $r2 $r3 $(nlines "$T/ssh.calls")"
  newenv; printf '30 4 * * * /usr/bin/algo-do-outro\n' > "$T/crontab$N"; cp "$T/crontab$N" "$T/crontab$N.antes"; printf '#!/bin/sh\nexit 2\n' > "$BIN/grep"; chmod +x "$BIN/grep"; ctl install; rm -f "$BIN/grep"
  check "install: o grep que filtra a crontab FALHA (rc 2, não 'sem linha') → rc 3 e a crontab fica intocada (não regrava a partir de leitura quebrada)" "3 0" "$RC $(diff -q "$T/crontab$N" "$T/crontab$N.antes" > /dev/null 2>&1; echo $?)"
  newenv; ctl install   # o comando remoto tem várias linhas: conto só as que abrem uma chamada (começam com -o BatchMode)
  check "ssh: toda chamada leva ServerAliveInterval=15 e ServerAliveCountMax=3 (conexão que morre no meio não pendura o comando)" "1" "$(a=$(grep -c '^-o BatchMode' "$T/ssh.calls"); b=$(grep -c '^-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 stub ' "$T/ssh.calls"); [ "$a" -gt 0 ] && [ "$a" = "$b" ] && echo 1 || echo "0 ($b de $a)")"
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

  # ── ga-2hd02v.5.4, gate 1: o que NÃO consegui parar / ler não vale "parado" nem "vazio" ──
  newenv; ctl install; ctl on; : > "$NODE/gov.fail.stop"; ctl off
  check "off: o governo NÃO conseguiu parar → rc 3, diz que a chave saiu mas o processo não parou, e NUNCA diz 'foi parado'" "3 0 1 0" "$RC $([ -e "$NODE/gt-remote/ballast/on" ] && echo 1 || echo 0) $(printf '%s' "$OUT" | grep -c 'NÃO consegui parar') $(printf '%s' "$OUT" | grep -c 'foi parado')"
  newenv; ctl install; ctl on; touch "$T/ssh.fail.stop"; ctl off
  check "off: o ssh cai só no stop → rc 98 (não sei se parou), nunca 'foi parado'" "98 0" "$RC $(printf '%s' "$OUT" | grep -c 'foi parado')"
  newenv; ctl on
  check "on: nada instalado no nó → liga a chave mas AVISA que nada roda até o install" "0 1" "$RC $(printf '%s' "$OUT" | grep -c 'nada instalado')"
  newenv; ctl install; ctl on
  check "on: com o lastro instalado → sem aviso" "0 0" "$RC $(printf '%s' "$OUT" | grep -c 'nada instalado')"
  newenv; ctl status x; r1=$RC; ctl on x; r2=$RC; ctl off x; r3=$RC; ctl pull x; r4=$RC; ctl burn on x; r5=$RC; ctl burn; r6=$RC
  check "on/off/status/pull/burn com argumento a mais → rc 2, nada enviado" "2 2 2 2 2 2 0" "$r1 $r2 $r3 $r4 $r5 $r6 $(nlines "$T/ssh.calls")"

  newenv; ctl install; touch "$T/crontab$N.readfail"; ctl status
  check "status: crontab que NÃO consegui ler → diz isso (e não 'não instalado'), rc 3" "3 1 0" "$RC $(printf '%s' "$OUT" | grep -c 'NÃO CONSEGUI LER a crontab') $(printf '%s' "$OUT" | grep -c 'cron: não instalado')"
  printf '{"t": %s}\n' "$(( $(date +%s) - 3000 ))" > "$NODE/gt-remote/ballast/ticks.jsonl"; ctl status
  check "status: tick de 50 min e crontab ilegível → 'não sei se está PARADO' (nunca afirma PARADO nem o apaga)" "1 0" "$(printf '%s' "$OUT" | grep -c 'não sei se está PARADO') $(printf '%s' "$OUT" | grep -c '^PARADO')"
  newenv; ctl install; printf '#!/bin/sh\nexit 2\n' > "$BIN/grep"; chmod +x "$BIN/grep"; ctl status
  check "status: o grep que procura a linha marcada FALHA (rc 2, ≠ 'não achou') → 'NÃO CONSEGUI LER a crontab', rc 3, nunca 'não instalado'" "3 1 0" "$RC $(printf '%s' "$OUT" | grep -c 'NÃO CONSEGUI LER a crontab') $(printf '%s' "$OUT" | grep -c 'cron: não instalado')"
  newenv; ctl install; rm -rf "$NODE/gt-remote/ballast"; : > "$NODE/gt-remote/ballast"; ctl status
  check "status: ~/gt-remote/ballast não é uma pasta que eu consiga ler (governo e crontab ok) → 'não sei o estado', rc 3, sem PARADO" "3 1 0 0" "$RC $(printf '%s' "$OUT" | grep -c 'AUSENTE ou ilegível') $(printf '%s' "$OUT" | grep -c 'status do governo: FALHOU') $(printf '%s' "$OUT" | grep -c 'PARADO')"
  newenv; ctl install; touch "$T/ssh.fail.status"; ctl status
  check "status: o comando de leitura no nó morre (rc 7, ≠ 255) → 'não sei o estado', rc 3 (nada de relatório com tudo 'ausente')" "3 1 0" "$RC $(printf '%s' "$OUT" | grep -c 'o comando de status no nó falhou') $(printf '%s' "$OUT" | grep -c 'NÃO CONSEGUI LER a crontab')"
  newenv; ctl install; : > "$NODE/gov.running.null"; ctl status
  check "status: o governo não conseguiu ler os processos (running null) → diz isso, rc 3 (nunca 'nada rodando')" "3 1" "$RC $(printf '%s' "$OUT" | grep -c 'NÃO conseguiu ler os processos')"
  newenv; ctl install; : > "$NODE/gov.fail.status"; ctl status
  check "status: o status do governo FALHOU → diz FALHOU (não vira 'sem itens'), rc 3" "3 1 0" "$RC $(printf '%s' "$OUT" | grep -c 'status do governo: FALHOU') $(printf '%s' "$OUT" | grep -c '  item ')"
  newenv; ctl install; ctl status
  check "status: governo ok, recém-instalado e sem tick ainda → lista o item, sem PARADO, rc 0" "0 1 0" "$RC $(printf '%s' "$OUT" | grep -c '  item hq-selftests') $(printf '%s' "$OUT" | grep -c 'PARADO')"
  newenv; ctl install; printf '{"head": "abc", "dirty": false, "at": "%s", "files": {}}\n' "$(ago 259200)" > "$NODE/gt-remote/ballast/installed.json"; ctl status
  check "status: cron instalado há 3 dias e NENHUM tick registrado → PARADO (a falha mais provável de um install novo)" "1" "$(printf '%s' "$OUT" | grep -c '^PARADO')"
  newenv; ctl install; printf 'lixo{' > "$NODE/gt-remote/ballast/installed.json"; ctl status
  check "status: installed.json que não é JSON → ILEGÍVEL (não 'sem installed.json'), rc 3" "3 1 0" "$RC $(printf '%s' "$OUT" | grep -c 'installed.json ILEGÍVEL') $(printf '%s' "$OUT" | grep -c 'sem installed.json')"
  newenv; ctl install; rm -f "$NODE/gt-remote/ballast/installed.json"; ctl status
  check "status: governo ok, sem installed.json e sem tick → '(sem installed.json)', sem PARADO (não sei desde quando), rc 0" "0 1 0" "$RC $(printf '%s' "$OUT" | grep -c 'sem installed.json') $(printf '%s' "$OUT" | grep -c 'PARADO')"
  newenv; ctl status
  check "status: nada instalado no nó (sem pasta, sem governo) → pasta AUSENTE + governo FALHOU, rc 3 (nunca 'sem itens' com rc 0)" "3 1 1" "$RC $(printf '%s' "$OUT" | grep -c 'AUSENTE') $(printf '%s' "$OUT" | grep -c 'status do governo: FALHOU')"
  newenv; ctl install; printf '{"t": 12' > "$NODE/gt-remote/ballast/ticks.jsonl"; ctl status
  check "status: última linha do ticks.jsonl truncada → 'último tick: ILEGÍVEL' (não 'nenhum registrado'), rc 3" "3 1 0" "$RC $(printf '%s' "$OUT" | grep -c 'último tick: ILEGÍVEL') $(printf '%s' "$OUT" | grep -c 'nenhum registrado')"

  newenv; ctl install; ctl pull; OUTF="$R/.gc/hetzner-ballast/results.jsonl"
  check "pull: o nó ainda não tem results.jsonl (pasta legível) → rc 0, diz isso e não cria o arquivo local" "0 1 0" "$RC $(printf '%s' "$OUT" | grep -c 'ainda não tem results.jsonl') $([ -e "$OUTF" ] && echo 1 || echo 0)"
  : > "$NODE/gt-remote/ballast/results.jsonl"; ctl pull
  check "pull: results.jsonl existe e está vazio → rc 0, 0 novas" "0 1" "$RC $(printf '%s' "$OUT" | grep -c '0 novas')"
  rm -f "$NODE/gt-remote/ballast/results.jsonl"; mkdir "$NODE/gt-remote/ballast/results.jsonl"; mkdir -p "$R/.gc/hetzner-ballast"; printf '{"run": "antes"}\n' > "$OUTF"; ctl pull
  check "pull: results.jsonl que NÃO consegui ler (≠ ausente) → rc 3, diz que não leu e o arquivo local fica como estava" "3 1 1" "$RC $(printf '%s' "$OUT" | grep -c 'NÃO consegui LER results.jsonl') $(nlines "$OUTF")"
}

if [ -n "${HBC_MUTANT:-}" ]; then g_install; g_ctl; echo "RESULT $fails/$n"; [ "$fails" = 0 ]; exit $?; fi
if [ -n "${HBC_ONLY:-}" ]; then "g_$HBC_ONLY"; echo "── $((n - fails))/$n ok (só g_$HBC_ONLY)"; [ "$fails" = 0 ]; exit $?; fi
g_install; g_ctl

[ -n "${HBC_NO_MUTANTS:-}" ] || {
  echo "── controle negativo: cada mutante tem que reprovar a bateria ──"
  cat > "$T/mutants.txt" <<'MUT'
nó desligado não impede instalar@@[ -e "$CITY/.gc/hetzner-node.on" ] || die 99@@true || die 99
árvore suja sobe sem --allow-dirty@@[ "$allow" = 1 ] && dirty=true ||@@dirty=true ||
git ilegível não impede instalar (dirty=true também pula a 2ª camada, o blob do HEAD, que sozinha já recusaria)@@    rc=*) die 3 "não consegui ler o estado do git@@    rc=*) dirty=true; true "não consegui ler o estado do git
o sha256 que chegou não é conferido@@    [ "$got" = "$want" ] || {@@    true || {
o sha256 local que não saiu é aceito (dois vazios 'iguais')@@[ -n "$want" ] || die 3 "não consegui calcular@@true || die 3 "não consegui calcular
o arquivo editado fora do git (assume-unchanged) sobe como se fosse o HEAD@@[ -n "$a" ] && [ "$a" = "$b" ] && continue@@continue
--allow-dirty não libera o arquivo que o git status não vê (e some o dirty:true)@@[ "$allow" = 1 ] && { dirty=true; continue; }@@true
a linha antiga da crontab não sai (duplica)@@grep -v "'"$MARK"'" > "$T"; g=$?@@cat > "$T"; g=$?
crontab ilegível é tratada como vazia (apaga as linhas dos outros)@@*) echo "crontab -l falhou (rc=$cr): $M" >&2; exit 4 ;; esac@@*) CUR= ;; esac
o grep da crontab que falha (rc 2) é tratado como 'sem linha'@@[ "$g" -le 1 ] || { rm -f "$T"; exit 3; }@@true
install ignora o rc 4 (crontab ilegível) e diz que instalou@@    4) die 3 "não consegui LER a crontab do nó: não mexi nela (os arquivos@@    4) true ;; 9) die 3 "não consegui LER a crontab do nó: não mexi nela (os arquivos
desinstalar não para o que roda@@  stop_or_die "a linha da crontab saiu"@@  true
desligar não manda o stop@@if [ "$1" = on ] && [ "$2" = off ]; then stop_or_die@@if false; then stop_or_die
o stop que falhou (rc ≠ 0, ≠ 255) vira 'parado'@@  die 3 "$1, mas NÃO consegui parar@@  return 0 # "$1, mas NÃO consegui parar
o stop com ssh que caiu (255) não vira 98@@[ "$rc" -ne 255 ] || die 98 "$1, mas o ssh caiu@@true || die 98 "$1, mas o ssh caiu
o rc do stop se perde na função (rc sempre 0)@@  return "$rc"@@  return 0
uninstall com crontab ilegível mexe nela mesmo assim@@    4) die 3 "não consegui LER a crontab do nó: não mexi nela e NÃO parei@@    4) true ;; 9) die 3 "não consegui LER a crontab do nó: não mexi nela e NÃO parei
ssh fora no pull não vira 98@@    255) die 98 "ssh não conectou ($NODE): results.jsonl local fica como estava" ;;@@    255) true ;;
pull com results.jsonl ilegível vira 'ausente' (0 novas, rc 0)@@fi; exit 11'@@fi; exit 10'
pull sem results.jsonl no nó cai no caminho do vazio@@    10) say "pull: o nó ainda não tem results.jsonl (nenhuma rodada terminou): 0 novas"; return 0 ;;@@    10) true ;;
o pull duplica a rodada que já veio@@    if d["run"] in seen:
        continue@@    if False:
        continue
o pull traz campo fora da lista branca@@    row = {k: (clean(d[k]) if k == "summary" else scal(d[k])) for k in KEEP if k in d}@@    row = dict(d)
o pull não corta string longa@@        return v[:160]@@        return v
status não acusa PARADO@@    if cron == "1":
        print("PARADO:@@    if False:
        print("PARADO:
status não acusa PARADO quando nunca houve tick (usa o install)@@        age = now - calendar.timegm(time.strptime(inst["at"], "%Y-%m-%dT%H:%M:%SZ"))@@        age = 0 * (now - calendar.timegm(time.strptime(inst["at"], "%Y-%m-%dT%H:%M:%SZ")))
status com crontab ilegível diz 'não instalado'@@then echo "cron=?"; else printf@@then echo "cron=0"; else printf
status com grep da crontab que falha diz 'não instalado'@@elif [ "$g" -eq 1 ]; then echo cron=0; else echo "cron=?"; fi@@else echo cron=0; fi
status com crontab ilegível não vira rc 3@@    bad = 1
    print("cron: NÃO CONSEGUI LER@@    print("cron: NÃO CONSEGUI LER
status com crontab ilegível e tick velho não avisa@@    elif cron != "0":@@    elif False:
status com installed.json ilegível não vira rc 3@@    bad = 1
    print("instalado: installed.json ILEGÍVEL@@    print("instalado: installed.json ILEGÍVEL
status com tick ilegível não vira rc 3@@    bad = 1
    print("último tick: ILEGÍVEL@@    print("último tick: ILEGÍVEL
status com a pasta do lastro ausente/ilegível não vira rc 3@@    bad = 1   # ausente e ilegível não se distinguem daqui: não sei, nunca "sem nada"@@    pass   # ausente e ilegível não se distinguem daqui: não sei, nunca "sem nada"
status do governo que falhou não vira rc 3@@    bad = 1
    print("status do governo: FALHOU@@    print("status do governo: FALHOU
status ignora o rc do ssh que caiu no meio@@[ "$rc" -eq 0 ] || die 3 "o comando de status no nó falhou@@true || die 3 "o comando de status no nó falhou
status ignora o governo que não leu os processos@@    if "running" in st and st["running"] is None:
        bad = 1@@    if "running" in st and st["running"] is None:
        bad = 0
ssh fora no install não vira 98@@    [ "$rc" -ne 255 ] || die 98 "ssh não conectou ($NODE): nada foi instalado"@@    true
o ssh não leva ServerAlive (conexão que morre no meio pendura)@@ -o ServerAliveInterval=15 -o ServerAliveCountMax=3)@@)
ligar sem nada instalado não avisa@@[ "$out" != "instalado=0" ] ||@@true ||
install aceita argumento que não existe@@  install)   { [ $# -eq 1 ] || { [ $# -eq 2 ] && [ "$2" = "--allow-dirty" ]; }; } || die 2 "$USO"; shift@@  install)   shift
uninstall aceita argumento a mais@@  uninstall) [ $# -eq 1 ] || die 2 "$USO"; cmd_uninstall@@  uninstall) cmd_uninstall
off aceita argumento a mais@@  off)       [ $# -eq 1 ] || die 2 "$USO"; cmd_flag on off@@  off)       cmd_flag on off
burn aceita argumento fora de on|off@@  burn)      [ $# -eq 2 ] && case "$2" in on|off) true ;; *) false ;; esac || die 2@@  burn)      true || die 2
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
