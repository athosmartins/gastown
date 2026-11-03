#!/usr/bin/env bash
# hetzner-ballast-hq-selftests-mem-probe.selftest.sh — hermético (ga-2hd02v.5.8): a sonda de memória do hq-selftests (scripts/hetzner-ballast-hq-selftests-mem-probe.py) contra um HOME de brinquedo.
# Sem rede, sem root, sem nó de verdade. A rodada de VERDADE (os 375 selftests do hq no nó, medindo RSS/PSS) só se prova no nó; aqui se prova (1) a trava: árvore que não nasce → rc 3, nada roda;
# (2) a medição num brinquedo de dois selftests: um que segura ~60 MB e um que deixa um processo vivo na sessão depois de acabar. Precisa de /proc (Linux): fora dele sai 97 (AMBIENTE), nunca 0.
#
# Contents
#   Casos · Variáveis
#
# CASOS: sintaxe · wt-add rc 1 → rc 3 e nenhum selftest lançado · wt-add rc 0 sem árvore → rc 3 (vale o efeito, não o rc) · lista vazia → rc 3 · rodada de brinquedo (rc 0): os dois selftests aparecem em
#        peaks.json com o rc deles · o que segura 60 MB tem pico de RSS >= 50 e PSS <= RSS · o que deixa o `sleep` tem leak_n >= 1 depois de acabar (o órfão conta, como no governo) · a soma do item
#        no samples.jsonl passa de 50 MB · o piso de MemAvailable acima do que há aborta com `abortado-ram` (rc 0, nada além do aborto) · HQP_MIN_AVAIL_MB=0 / vazio / texto NÃO desligam o piso (voltam ao padrão 8000). · trava de instância única: com a trava na mão de outro processo → rc 3 sem chamar o espelho; solta → roda.
# VARIÁVEIS: HMQ_UNDER_TEST (script a testar) · HMQ_PY (padrão /usr/bin/python3)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${HMQ_UNDER_TEST:-$HERE/hetzner-ballast-hq-selftests-mem-probe.py}"
PY="${HMQ_PY:-/usr/bin/python3}"
fails=0; n=0
check() { n=$((n+1)); if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (esperado '$2', veio '$3')"; fails=$((fails+1)); fi; }

"$PY" -I -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$SCRIPT" 2> /dev/null; check "sintaxe do script" "0" "$?"
if [ ! -r /proc/self/statm ] || [ ! -r /proc/meminfo ]; then
  echo "AMBIENTE: sem /proc (não é Linux): a sonda lê /proc; os casos de execução NÃO rodaram"; echo "── $((n - fails))/$n ok (parcial)"; [ "$fails" -eq 0 ] && exit 97 || exit 1
fi

T=$(cd "$(mktemp -d /tmp/hmq.XXXXXX)" && pwd -P)
cleanup() { find "$T" -mindepth 1 -delete 2> /dev/null; rmdir "$T" 2> /dev/null; }
trap cleanup EXIT

# home N CORPO_DO_WT_ADD — HOME de brinquedo: o hetzner-remote-git.sh de brinquedo faz `pull` e `wt-rm` (apaga a árvore) sem erro, e `wt-add` roda CORPO ($WT = a árvore pedida); grava uma marca
# em $T/rg.<N>.<verbo> a cada chamada. O ballast/items.tsv de brinquedo dá a régua (hq-selftests, rss_mb 4096).
home() {
  local H="$T/home.$1"; mkdir -p "$H/gt-remote/bin" "$H/gt-remote/ballast" "$H/gt-remote/git/gascity"
  printf 'hq-selftests\twork\t4\t4096\t10800\t180\t-\thq-selftests.sh\n' > "$H/gt-remote/ballast/items.tsv"
  cat > "$H/gt-remote/bin/hetzner-remote-git.sh" << EOS
#!/bin/sh
touch "$T/rg.$1.\$1"
WT="$H/gt-remote/git/gascity/wt/\$3"
case "\$1" in
  wt-add)
$2
  ;;
  wt-rm) rm -rf "\$WT" ;;
esac
exit 0
EOS
  chmod +x "$H/gt-remote/bin/hetzner-remote-git.sh"
}
# run N LISTA_OU_- [ENV…] — roda a sonda no HOME N com a lista (arquivo) e 2 trabalhadores, limite 60 s; devolve o rc em $RC e a saída em $OUT
run() { local N=$1 L=$2; shift 2
  OUT=$(env HOME="$T/home.$N" GT_REMOTE_GIT="$T/home.$N/gt-remote/git" HQP_INTERVAL_S=1 HQP_MIN_AVAIL_MB=1 "$@" "$PY" -I "$SCRIPT" "$T/out.$N" "$L" 2 60 2>&1); RC=$?; }
jq_() { "$PY" -I -c 'import json, sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d[k]
print(d)' "$@" 2> /dev/null; }

# 1. wt-add rc 1 (não cria árvore): rc 3, nenhum selftest lançado
home 1 'exit 1'; : > "$T/list.txt"; run 1 "$T/list.txt"
check "wt-add rc 1 → rc 3" "3" "$RC"
check "wt-add rc 1: nenhum log de selftest foi criado" "0" "$(find "$T/out.1/tests" -type f 2> /dev/null | wc -l | tr -d ' ')"
# 2. wt-add rc 0 mas sem a árvore (scripts/ ausente): rc 3
home 2 'true'; run 2 "$T/list.txt"
check "wt-add rc 0 sem árvore (scripts/ ausente) → rc 3 (vale o efeito, não o rc)" "3" "$RC"
# 3. árvore pronta, lista vazia: rc 3, nada roda
home 3 'mkdir -p "$WT/.gascity-gastown-hq/scripts"'; run 3 "$T/list.txt"
check "árvore pronta e lista vazia → rc 3" "3" "$RC"

# 4. rodada de brinquedo: segura60 aloca ~60 MB e espera; orfao deixa um `sleep` na sessão e sai; ok sai na hora
BODY='mkdir -p "$WT/.gascity-gastown-hq/scripts"
cat > "$WT/.gascity-gastown-hq/scripts/segura60.selftest.sh" << "EOT"
python3 -I -c "b = bytearray(60 * 1024 * 1024); b[::4096] = b\"x\" * len(b[::4096]); import time; time.sleep(6)"
EOT
cat > "$WT/.gascity-gastown-hq/scripts/orfao.selftest.sh" << "EOT"
sleep 8 > /dev/null 2>&1 &
exit 0
EOT
cat > "$WT/.gascity-gastown-hq/scripts/ok.selftest.sh" << "EOT"
exit 0
EOT'
home 4 "$BODY"
printf '%s\n' scripts/segura60.selftest.sh scripts/orfao.selftest.sh scripts/ok.selftest.sh > "$T/list4.txt"
run 4 "$T/list4.txt"
check "rodada de brinquedo: rc 0 ('$(printf '%s' "$OUT" | tail -1 | cut -c1-120)')" "0" "$RC"
P="$T/out.4/peaks.json"
check "peaks.json lista os 3 selftests" "3" "$("$PY" -I -c 'import json, sys; print(len(json.load(open(sys.argv[1]))["done"]))' "$P" 2> /dev/null)"
check "segura60: rc 0" "0" "$(jq_ "$P" done.segura60.rc)"
check "segura60: pico de RSS >= 50 MB" "1" "$([ "$(jq_ "$P" done.segura60.peak_rss_mb)" -ge 50 ] 2> /dev/null && echo 1 || echo 0)"
check "segura60: PSS <= RSS (a soma de PSS nunca passa a de RSS)" "1" "$([ "$(jq_ "$P" done.segura60.peak_pss_mb)" -le "$(jq_ "$P" done.segura60.peak_rss_mb)" ] 2> /dev/null && echo 1 || echo 0)"
check "segura60 não deixou nada vivo (leak_n 0)" "0" "$(jq_ "$P" done.segura60.leak_n)"
check "orfao: o selftest saiu com rc 0" "0" "$(jq_ "$P" done.orfao.rc)"
check "orfao: o sleep que ficou na sessão foi visto depois do fim (leak_n >= 1)" "1" "$([ "$(jq_ "$P" done.orfao.leak_n)" -ge 1 ] 2> /dev/null && echo 1 || echo 0)"
check "orfao: o órfão viveu alguns segundos depois do líder (leak_secs >= 2) e o registro não foi zerado quando a sessão esvaziou" "1" "$([ "$(jq_ "$P" done.orfao.leak_secs)" -ge 2 ] 2> /dev/null && echo 1 || echo 0)"
check "a soma do item no samples.jsonl passou de 50 MB" "1" "$("$PY" -I -c 'import json, sys
print(1 if max(json.loads(l)["item_rss_mb"] for l in open(sys.argv[1])) >= 50 else 0)' "$T/out.4/samples.jsonl" 2> /dev/null)"
check "o pico do item bate com o maior ponto do samples.jsonl" "1" "$("$PY" -I -c 'import json, sys
pk = json.load(open(sys.argv[1]))["item_peak"]["rss_mb"]
mx = max(json.loads(l)["item_rss_mb"] for l in open(sys.argv[2]))
print(1 if pk == mx else 0)' "$P" "$T/out.4/samples.jsonl" 2> /dev/null)"
check "a árvore da sonda foi removida no fim (wt-rm chamado)" "1" "$([ -e "$T/rg.4.wt-rm" ] && echo 1 || echo 0)"

# 5. piso de MemAvailable acima do que há: aborta no 1º tick, sem lançar além dos que cabem no 1º laço; HQP_MIN_AVAIL_MB=0 volta ao padrão (não desliga o piso)
home 5 "$BODY"
run 5 "$T/list4.txt" HQP_MIN_AVAIL_MB=99999999
check "piso de MemAvailable alto demais → aborta com 'abortado-ram'" "1" "$(printf '%s' "$OUT" | grep -c 'fim: abortado-ram')"
# 7. instância única: com a trava na mão de OUTRO processo a sonda sai com rc 3 e NÃO chama o espelho (a árvore da outra, se houvesse, ficaria como está)
home 7 "$BODY"; mkdir -p "$T/home.7/gt-remote/measure"
"$PY" -I -c 'import fcntl, sys, time
f = open(sys.argv[1], "w"); fcntl.flock(f, fcntl.LOCK_EX); time.sleep(12)' "$T/home.7/gt-remote/measure/hqprobe.lock" &
HOLD=$!; sleep 1
run 7 "$T/list4.txt"
check "outra sonda segura a trava → rc 3" "3" "$RC"
check "outra sonda segura a trava: a mensagem diz que há outra sonda" "1" "$(printf '%s' "$OUT" | grep -c 'outra sonda')"
check "outra sonda segura a trava: o espelho NÃO foi chamado (nem wt-rm, nem wt-add)" "0" "$(ls "$T"/rg.7.* 2> /dev/null | wc -l | tr -d ' ')"
kill "$HOLD" 2> /dev/null; wait "$HOLD" 2> /dev/null
# trava solta de novo (o dono morreu): a sonda roda
home 8 "$BODY"; run 8 "$T/list4.txt"
check "trava livre (o dono anterior morreu) → a sonda roda (rc 0)" "0" "$RC"

# ── leituras que FALHAM (E12): cada uma tem de cair no estado INERTE (não sei / nada roda / não mata), nunca no mesmo valor de "vazio" ou de "achei". O módulo é importável (main só roda como script).
PRELUDE='import importlib.util, os, sys
from unittest import mock
sp = importlib.util.spec_from_file_location("hqp", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)'
pyx() { "$PY" -I -c "$PRELUDE"$'\n'"$1" "$SCRIPT" 2> /dev/null | tail -n 1; }
check "/proc/meminfo ilegível (open falha com OSError) → MemAvailable None, nunca um número (None aborta a rodada)" "None" "$(pyx 'with mock.patch("builtins.open", side_effect=OSError("EACCES")): print(m.mem_avail_mb())')"
check "/proc/meminfo sem a linha MemAvailable → None" "None" "$(pyx 'with mock.patch("builtins.open", mock.mock_open(read_data="MemTotal: 1 kB\n")): print(m.mem_avail_mb())')"
check "items.tsv que não existe (/nonexistent) → a régua cai em 4096, não quebra" "4096" "$(pyx 'm.BH = "/nonexistent/ballast"; print(m.cap_mb())')"
check "items.tsv sem a linha hq-selftests → 4096" "4096" "$(pyx 'import tempfile; d = tempfile.mkdtemp(); open(d + "/items.tsv", "w").write("queima\tfiller\tauto\t512\t3600\t0\t-\tq.sh\n"); m.BH = d; print(m.cap_mb())')"
check "smaps_rollup de um pid que não existe → None (o processo conta na soma de RSS, fica em sem_pss)" "None" "$(pyx 'print(m.rollup(2 ** 22 + 12345))')"
check "smaps_rollup que nega (PermissionError) → None" "None" "$(pyx 'with mock.patch("builtins.open", side_effect=PermissionError("EACCES")): print(m.rollup(os.getpid()))')"
check "os.listdir(/proc) que falha (OSError) → a leitura SOBE como erro (a rodada aborta), nunca devolve 'ninguém roda'" "OSError" "$(pyx 'with mock.patch("os.listdir", side_effect=OSError("EIO")):
    try: m.scan_sessions([1]); print("sem-erro")
    except OSError: print("OSError")')"
check "controle: sem falha injetada a sessão do próprio processo tem membros" "True" "$(pyx 'sid = os.getsid(0); print(len(m.scan_sessions([sid])[sid]) >= 1)')"
for suf in /stat /statm /cmdline; do
  check "leitura de /proc/<pid>$suf que falha (FileNotFoundError, o processo sumiu) → o membro é pulado, a sessão sai vazia, sem erro" "True" "$(pyx "sid = os.getsid(0); real = open
def fake(p, *a, **k):
    if str(p).endswith('$suf'): raise FileNotFoundError(p)
    return real(p, *a, **k)
with mock.patch('builtins.open', side_effect=fake): print(m.scan_sessions([sid]) == {sid: []})")"
done

# a lista de selftests e os arquivos que a montam: falhou/ilegível → rc 3, nada roda E a árvore sai (wt-rm); vazio → rc 3 "nada para rodar"; presente → roda
NOMAC='printf "# só-macOS\nscripts/mac.selftest.sh\n" > "$WT/.gascity-gastown-hq/scripts/hetzner-mac-only.hq.txt"'
TREE_A='mkdir -p "$WT/.gascity-gastown-hq/scripts"'
SELF_TESTS='printf "exit 0\n" > "$WT/.gascity-gastown-hq/scripts/ok1.selftest.sh"; printf "exit 0\n" > "$WT/.gascity-gastown-hq/scripts/ok2.selftest.sh"; printf "exit 1\n" > "$WT/.gascity-gastown-hq/scripts/mac.selftest.sh"'
home 9 "$TREE_A"; run 9 "$T/nonexistent-list.txt"
check "lista de selftests que não existe (/nonexistent) → rc 3, nada roda e a árvore sai (wt-rm)" "3 1" "$RC $([ -e "$T/rg.9.wt-rm" ] && echo 1 || echo 0)"
home 10 "$TREE_A"; run 10 -
check "sem lista e sem a lista só-macOS na árvore → rc 3 (não rodo: os testes de macOS virariam ruído) e a árvore sai" "3 1" "$RC $([ -e "$T/rg.10.wt-rm" ] && echo 1 || echo 0)"
home 11 "$TREE_A; printf '# só comentário\n' > \"\$WT/.gascity-gastown-hq/scripts/hetzner-mac-only.hq.txt\""; run 11 -
check "lista só-macOS sem nenhum padrão → rc 3 e a árvore sai" "3 1" "$RC $([ -e "$T/rg.11.wt-rm" ] && echo 1 || echo 0)"
home 12 "$TREE_A; $NOMAC"; run 12 -
check "lista só-macOS ok mas a árvore não tem nenhum selftest → rc 3 ('nada para rodar')" "3 1" "$RC $(printf '%s' "$OUT" | grep -c 'nada para rodar')"
home 13 "$TREE_A; $NOMAC; $SELF_TESTS"; run 13 -
check "sem lista e sem hq-selftests.durations: roda os da árvore menos o só-macOS (2 selftests, rc 0)" "0 2" "$RC $("$PY" -I -c 'import json, sys; print(len(json.load(open(sys.argv[1]))["done"]))' "$T/out.13/peaks.json" 2> /dev/null)"
home 14 "$TREE_A; $NOMAC; $SELF_TESTS"; mkdir -p "$T/home.14/gt-remote/ballast/hq-selftests.durations"; run 14 -
check "hq-selftests.durations que não abre (é uma pasta, IsADirectoryError) → segue com a ordem do find: 2 selftests, rc 0" "0 2" "$RC $("$PY" -I -c 'import json, sys; print(len(json.load(open(sys.argv[1]))["done"]))' "$T/out.14/peaks.json" 2> /dev/null)"

# o parser das variáveis, direto: "0", vazio e texto caem no padrão (0 desligaria o piso); inteiro >= 1 vale. O módulo é importável (main só roda como script)
env_val() { HQP_MIN_AVAIL_MB="$1" "$PY" -I -c 'import importlib.util, sys
sp = importlib.util.spec_from_file_location("hqp", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m); print(m.MIN_AVAIL_MB)' "$SCRIPT" 2> /dev/null; }
check "HQP_MIN_AVAIL_MB=0 NÃO desliga o piso (volta ao padrão 8000)" "8000" "$(env_val 0)"
check "HQP_MIN_AVAIL_MB vazio → padrão 8000" "8000" "$(env_val '')"
check "HQP_MIN_AVAIL_MB=abc → padrão 8000" "8000" "$(env_val abc)"
check "HQP_MIN_AVAIL_MB=1234 → 1234" "1234" "$(env_val 1234)"
echo "── $((n - fails))/$n ok"
[ "$fails" -eq 0 ]
