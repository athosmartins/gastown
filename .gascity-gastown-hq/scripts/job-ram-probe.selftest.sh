#!/usr/bin/env bash
# job-ram-probe.selftest.sh — hermético: a amostra vem de arquivos (--fixture-dir) e o resumo de uma noite fabricada; o sistema de verdade só entra no teste de fumaça.
#
# Contents
#   Casos · Controle negativo (mutantes) · Variáveis
#
# CASOS: soma da árvore (raiz + filhos, cada pid uma vez; ciclo termina) · nome do processo de maior RSS · job parado (PID "-") fora · OS TRÊS ESTADOS: ps vazio = ps_ok:false e total null (não 0),
#   launchctl só com cabeçalho / ausente / com byte não-UTF-8 = lc_ok:false e SEM jobs (não "nenhum job rodando"), job que o launchctl lista e o ps (lido antes) ainda não tem não vira 0 MB, swap/% livre não lidos = null ·
#   resumo: job da janela × persistente, pico e hora, simultaneidade, saltos de swap com quem cresceu nos 60 s antes (e "sem atribuição" quando a janela tem amostra sem ps/launchctl), amostras
#   falhas e linhas ilegíveis CONTADAS, arquivo vazio/ausente/não-UTF-8 = exit 3 · BURACOS: duas noites a 22,5 h uma da outra NÃO viram salto de swap nem queda de disco (a reprodução do reviewer), buraco dentro
#   dos 60 s antes de um salto = sem atribuição, buraco contado e dito, --max-gap, arquivo repetido não zera o limite, data nos horários de arquivo de vários dias, --top e o aviso de truncamento ·
#   --ticks 0 / --duration 0 / --duration com --until = exit 2, janela sem nenhuma amostra = exit 3 · plano de horário (antes, dentro, depois, atravessando a meia-noite) · teto de tamanho (exit 5) · piso de disco (exit 6,
#   no início e no meio) · instância única (exit 4) · uso errado (exit 2) · fumaça no sistema real.
# CONTROLE NEGATIVO: cada guarda é removida do script (sed numa cópia) e a suíte TEM que passar a falhar.
# VARIÁVEIS: JRP_UNDER_TEST (script a testar) · JRP_NO_MUTANTS=1
set -u
export TZ=UTC
HERE="$(cd "$(dirname "$0")" && pwd)"
P="${JRP_UNDER_TEST:-$HERE/job-ram-probe.py}"
T=$(cd "$(mktemp -d /tmp/jrp.XXXXXX)" && pwd -P)
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
command -v timeout >/dev/null || { echo "precisa de 'timeout' no PATH"; exit 2; }
fails=0; n=0
ok() { n=$((n+1)); if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); [ -n "${JRP_MUTANT:-}" ] && { echo "RESULT $fails/$n"; exit 1; }; fi; }  # mutante: o 1º caso vermelho já o mata
jrp() { timeout 30 python3 -I "$P" "$@"; }
tb=$'\t'

# ---- fixture de amostras: 9 instantes (0..8) ----
FX="$T/fx"; mkdir -p "$FX"
PS_OK='1 0 1000 /sbin/launchd /sbin/launchd
100 1 2000 /bin/bash /bin/bash /x/scripts/jobA.sh
101 100 90000 /opt/homebrew/bin/python3 /opt/homebrew/bin/python3 /x/scripts/build_big.py --apply
102 101 5000 /usr/bin/aws aws s3 sync a b
200 1 3000 /bin/bash /bin/bash /x/scripts/jobB.sh
300 1 400 /usr/bin/other other'
LC_OK="PID${tb}Status${tb}Label
100${tb}0${tb}com.test.jobA
200${tb}0${tb}com.test.jobB
-${tb}0${tb}com.test.stopped"
for i in 0 2 3 4 5 6 7 8; do printf '%s\n' "$PS_OK" > "$FX/$i.ps"; printf '%s\n' "$LC_OK" > "$FX/$i.launchctl"; printf '512.5 45 7000\n' > "$FX/$i.mem"; done
# 1: ciclo 100 -> 101 -> 102 -> 100 (o ppid da raiz aponta para o neto)
printf '100 102 1000 /bin/bash /bin/bash /x/scripts/jobA.sh\n101 100 2000 /usr/bin/x x one\n102 101 3000 /usr/bin/y y two\n' > "$FX/1.ps"
printf '%s\n' "$LC_OK" > "$FX/1.launchctl"; printf '512.5 45 7000\n' > "$FX/1.mem"
: > "$FX/2.ps"                                                              # 2: ps vazio
printf 'PID%sStatus%sLabel\n' "$tb" "$tb" > "$FX/3.launchctl"               # 3: launchctl só com o cabeçalho
rm -f "$FX/4.launchctl"                                                     # 4: launchctl ausente
printf '%s\n999%s0%scom.test.gone\n' "$LC_OK" "$tb" "$tb" > "$FX/5.launchctl"  # 5: um job que o launchctl lista e o ps (lido antes) ainda não tinha
printf -- '- - -\n' > "$FX/6.mem"; rm -f "$FX/7.mem"                        # 6: não li swap, % livre nem disco; 7: arquivo ausente
printf '512.5 45\n' > "$FX/2.mem"                                           # 2: arquivo no formato antigo (sem o campo de disco)
printf 'PID%sStatus%sLabel\n-%s0%scom.test.\xff\xfe\n' "$tb" "$tb" "$tb" "$tb" > "$FX/8.launchctl"  # 8: byte que não é UTF-8

# ---- noite fabricada: 100 amostras de 5 s a partir de 04:00:00 (UTC) ----
python3 -I - "$T/night.jsonl" "$T/night-a.jsonl" "$T/night-b.jsonl" "$T/gap-a.jsonl" "$T/gap-b.jsonl" "$T/hole.jsonl" <<'EOF'
import json, sys
out, oa, ob, ga, gb, ho = sys.argv[1:7]
base = 1704081600  # 2024-01-01 04:00:00 UTC
recs = []
for i in range(100):
    jobs = {"com.test.daemon": [51200, 1, "daemon_proc", 51200]}
    if 10 <= i <= 19: jobs["com.test.spe"] = [921600 if i == 14 else 307200, 3, "build_spe", 300000]
    if 12 <= i <= 14: jobs["com.test.small"] = [20480, 1, "small_proc", 20480]
    if 14 <= i <= 16: jobs["com.test.other"] = [409600, 1, "other_proc", 409600]
    swap = 1000.0 if i < 13 else (1100.0 if i == 13 else (1500.0 if i < 72 else 2000.0))
    disk = 8000 if i < 10 else (6800 if i < 40 else (5000 if i < 70 else 4000))  # quedas em 10 (spe rodando), 40 (nenhum job da janela), 70 (amostra sem launchctl)
    r = {"ts": base + 5 * i, "ps_ok": True, "lc_ok": True, "swap_used_mb": swap, "free_pct": 50, "disk_free_mb": disk, "total_rss_kb": 8000000, "jobs": jobs, "dt_ms": 700 if i == 3 else 200}
    if i == 50: r.update(ps_ok=False, total_rss_kb=None, jobs={})
    if i == 70: r.update(lc_ok=False, jobs={})
    recs.append(r)
lines = [json.dumps(r) for r in recs]
open(out, "w").write("\n".join(lines[:30] + ["isto nao e json", ""] + lines[30:]) + "\n")
open(oa, "w").write("\n".join(lines[:50]) + "\n"); open(ob, "w").write("\n".join(lines[50:]) + "\n")
# buracos. gap-a/gap-b: duas noites de 10 amostras, a 2ª começa 22,5 h depois da 1ª; swap 1000 -> 1300 e disco 8000 -> 6000 só aparecem ENTRE as noites, e o job 'innocent' fica constante em 200 MB na noite 2.
# hole: 30 amostras de 5 s com um buraco de 50 s (i = 20..28 faltam); o salto de swap (i = 29 -> 30) é entre amostras vizinhas, mas a base de 60 s antes cruza o buraco, e 'grower' só existe depois dele.
mk = lambda ts, swap, disk, jobs: {"ts": ts, "ps_ok": True, "lc_ok": True, "swap_used_mb": swap, "free_pct": 50, "disk_free_mb": disk, "total_rss_kb": 8000000, "jobs": jobs, "dt_ms": 200}
wr = lambda path, rs: open(path, "w").write("".join(json.dumps(r) + "\n" for r in rs))
wr(ga, [mk(base + 5 * i, 1000.0, 8000, {}) for i in range(10)])
wr(gb, [mk(base + 81000 + 5 * i, 1300.0, 6000, {"com.test.innocent": [204800, 1, "innocent_proc", 204800]}) for i in range(10)])
wr(ho, [mk(base + 5 * i, 1000.0 if i < 30 else 1500.0, 8000, {"com.test.grower": [512000, 1, "grower_proc", 512000]} if i >= 29 else {}) for i in range(40) if not 20 <= i <= 28])
EOF

rec() {  # rec ARQ N EXPR DESCRIÇÃO — a N-ésima linha (a partir de 0) do JSONL vira `r`; EXPR tem que ser verdadeira. O eval roda SÓ a asserção escrita neste arquivo, nunca dado externo
  python3 -I - "$1" "$2" "$3" <<'EOF'
import json, sys
r = json.loads(open(sys.argv[1]).read().splitlines()[int(sys.argv[2])])
sys.exit(0 if eval(sys.argv[3]) else 1)
EOF
  ok $? "$4"
}

run_all() {
  # --- a amostra ---
  jrp --fixture-dir "$FX" --ticks 9 --interval 1 --out "$T/o.jsonl" >/dev/null 2>"$T/e"; RC=$?; [ "$RC" = 0 ] && [ "$(wc -l < "$T/o.jsonl" | tr -d " ")" = 9 ]; ok $? "9 amostras gravadas, uma linha cada (rc=$RC)"
  rec "$T/o.jsonl" 0 'r["jobs"]["com.test.jobA"] == [97000, 3, "build_big", 90000] and r["jobs"]["com.test.jobB"] == [3000, 1, "jobB", 3000]' "RSS do job = raiz + filhos (2000+90000+5000); processo de maior RSS é o python do script, com o nome do sampler"
  rec "$T/o.jsonl" 0 '"com.test.stopped" not in r["jobs"] and r["total_rss_kb"] == 101400 and r["swap_used_mb"] == 512.5 and r["free_pct"] == 45 and r["ps_ok"] is True and r["lc_ok"] is True' "job parado (PID '-') fica fora; total, swap e % livre lidos"
  rec "$T/o.jsonl" 1 'r["jobs"]["com.test.jobA"][:2] == [6000, 3]' "ciclo na árvore: termina e cada pid conta UMA vez (1000+2000+3000)"
  rec "$T/o.jsonl" 2 'r["ps_ok"] is False and r["total_rss_kb"] is None and r["jobs"] == {} and r["lc_ok"] is True' "ps vazio: ps_ok false, total null (NÃO 0) e nenhum job"
  rec "$T/o.jsonl" 3 'r["lc_ok"] is False and r["jobs"] == {} and r["total_rss_kb"] == 101400 and r["ps_ok"] is True' "launchctl só com cabeçalho: lc_ok false e SEM jobs (não 'nenhum job rodando'); o total fica"
  rec "$T/o.jsonl" 4 'r["lc_ok"] is False and r["jobs"] == {}' "launchctl ausente: lc_ok false"
  rec "$T/o.jsonl" 5 '"com.test.gone" not in r["jobs"] and "com.test.jobA" in r["jobs"]' "job que o launchctl lista e o ps (lido antes) ainda não tinha não vira 0 MB nem derruba os outros"
  rec "$T/o.jsonl" 6 'r["swap_used_mb"] is None and r["free_pct"] is None and r["disk_free_mb"] is None and r["jobs"]' "swap, % livre e disco não lidos ('- - -'): null (NÃO 0), e o resto da amostra segue"
  rec "$T/o.jsonl" 0 'r["disk_free_mb"] == 7000' "disco livre lido (3º campo do arquivo de memória)"
  rec "$T/o.jsonl" 2 'r["disk_free_mb"] is None and r["swap_used_mb"] == 512.5' "arquivo de memória no formato antigo (2 campos): disco null, o resto lido"
  rec "$T/o.jsonl" 7 'r["swap_used_mb"] is None and r["free_pct"] is None and r["disk_free_mb"] is None' "arquivo de memória ausente: null nos três"
  rec "$T/o.jsonl" 8 'r["lc_ok"] is False and r["jobs"] == {}' "launchctl com byte que não é UTF-8: lc_ok false, sem traceback"
  ! grep -q Traceback "$T/e"; ok $? "nenhuma das falhas acima gerou traceback"
  rec "$T/o.jsonl" 0 'isinstance(r["dt_ms"], int)' "o custo da amostra vai gravado (dt_ms)"

  # --- o resumo ---
  jrp --summary "$T/night.jsonl" > "$T/s" 2>"$T/e"; RC=$?; [ "$RC" = 0 ]; ok $? "resumo da noite fabricada sai com 0 (rc=$RC)"
  grep -q '^# job-ram-probe: 98 amostras com atribuição de 100 (04:00:00-04:08:15) · passo mediano 5 s · custo da amostra: mediana 200 ms, máx 700 ms' "$T/s"; ok $? "cabeçalho: 98 de 100 com atribuição, passo e custo da amostra"
  grep -q '^AVISO: 1 amostras sem ps, 1 sem launchctl .* 1 linhas ilegíveis' "$T/s"; ok $? "amostra sem ps, sem launchctl e linha ilegível são CONTADAS e ditas"
  grep -q '^| com.test.spe | 900 | 04:01:10 | build_spe | 04:00:50..04:01:35 | 10 |$' "$T/s"; ok $? "job da janela: pico (900 MB), hora do pico, processo, de..até e nº de amostras"
  [ "$(grep -n '^| com.test.spe |' "$T/s" | cut -d: -f1)" -lt "$(grep -n '^| com.test.other |' "$T/s" | cut -d: -f1)" ] && [ "$(grep -n '^| com.test.other |' "$T/s" | cut -d: -f1)" -lt "$(grep -n '^| com.test.small |' "$T/s" | cut -d: -f1)" ]; ok $? "tabela ordenada por pico (900, 400, 20 MB)"
  ! grep -q '^| com.test.daemon |' "$T/s" && grep -q '^\* com.test.daemon: 50 MB' "$T/s"; ok $? "o daemon (visto em >= 90 % das amostras) vai para 'Persistentes', não para os jobs da janela"
  grep -q '^\* maior soma de uma amostra: 1320 MB às 04:01:10 (2 jobs de pico: com.test.other, com.test.spe)' "$T/s" && grep -q '^\* amostras com 2 ou mais jobs de pico ao mesmo tempo: 3 de 98' "$T/s"; ok $? "simultaneidade: maior soma, quem estava de pico junto e quantas amostras tiveram 2 ou mais"
  grep -q '^\* swap usado: 1000..2000 MB (0 amostras sem leitura)' "$T/s" && grep -q '^\* saltos de swap >= 200 MB entre amostras seguidas: 2' "$T/s"; ok $? "swap: faixa e 2 saltos (o de +100 MB não conta)"
  grep -q '04:01:10  1100 -> 1500 MB (+400, em 5 s)  nos 60 s antes: com.test.spe +900 MB (novo) \[build_spe\]; com.test.other +400 MB (novo) \[other_proc\]$' "$T/s"; ok $? "salto de swap: quem cresceu nos 60 s antes, do que mais para o que menos, 'novo' quando não existia"
  ! grep -q 'com.test.small +' "$T/s"; ok $? "quem cresceu menos que 50 MB não entra na lista de suspeitos"
  grep -q '^\* livre: 4000..8000 MB (0 amostras sem leitura)' "$T/s" && grep -q '^\* quedas >= 300 MB entre amostras seguidas: 3' "$T/s"; ok $? "disco: faixa e 3 quedas"
  grep -q '04:00:50  8000 -> 6800 MB (-1200, em 5 s)  jobs da janela rodando (maiores por RSS; presença, NÃO escrita em disco medida): com.test.spe (300 MB)$' "$T/s"; ok $? "queda de disco com o job da janela que estava rodando (o daemon persistente não entra)"
  grep -q '04:03:20  6800 -> 5000 MB (-1800, em 5 s)  jobs da janela rodando (maiores por RSS; presença, NÃO escrita em disco medida): nenhum job da janela rodando$' "$T/s"; ok $? "queda de disco sem job da janela rodando diz isso"
  grep -q '04:05:50  5000 -> 4000 MB (-1000, em 5 s)  jobs da janela rodando (maiores por RSS; presença, NÃO escrita em disco medida): sem atribuição' "$T/s"; ok $? "queda de disco numa amostra sem launchctl: 'sem atribuição', não 'nenhum job rodando'"
  grep -q '04:06:00  1500 -> 2000 MB (+500, em 5 s)  nos 60 s antes: sem atribuição' "$T/s"; ok $? "salto com amostra sem launchctl na janela de 60 s: 'sem atribuição', não 'ninguém cresceu'"
  jrp --summary "$T/night-a.jsonl" "$T/night-b.jsonl" > "$T/s2" 2>/dev/null; grep -q '^| com.test.spe | 900 | 04:01:10 | build_spe |' "$T/s2" && grep -q 'swap usado: 1000..2000 MB' "$T/s2"; ok $? "dois arquivos entram juntos, ordenados por hora"
  # buracos: a noite 1 acaba em 04:00:45 e a noite 2 começa 22,5 h depois (80955 s)
  jrp --summary "$T/gap-a.jsonl" "$T/gap-b.jsonl" > "$T/g" 2>"$T/e"; RC=$?
  [ "$RC" = 0 ] && grep -q '^AVISO: 1 buraco(s) entre amostras seguidas (passo > 15 s), somando 22 h 29 min; o maior: 22 h 29 min, de 01/01 04:00:45 a 02/01 02:30:00\.' "$T/g"; ok $? "duas noites a 22,5 h: o buraco é contado e dito, com o tamanho e as datas (rc=$RC)"
  grep -q '^\* saltos de swap >= 200 MB entre amostras seguidas: 0 (+ 1 par(es) de leituras a mais de 15 s um do outro, NÃO avaliados; variação >= 200 MB em 1: sei que mudou, não quando)$' "$T/g"; ok $? "swap 1000 -> 1300 ENTRE as noites não é um salto: 0 saltos, e o par não avaliado é contado (não some)"
  grep -q '^\* quedas >= 300 MB entre amostras seguidas: 0 (+ 1 par(es) de leituras a mais de 15 s um do outro, NÃO avaliados; variação >= 300 MB em 1: sei que mudou, não quando)$' "$T/g"; ok $? "disco 8000 -> 6000 ENTRE as noites não é uma queda: 0 quedas, par não avaliado contado"
  ! grep -q '^  - ' "$T/g"; ok $? "nenhum evento inventado nem culpado nomeado ('innocent' não aparece como causa de salto algum)"
  grep -q '^| com.test.innocent | 200 | 02/01 02:30:00 | innocent_proc | 02/01 02:30:00\.\.02/01 02:30:45 | 10 |$' "$T/g" && grep -q '^# job-ram-probe: 20 amostras com atribuição de 20 (01/01 04:00:00-02/01 02:30:45)' "$T/g"; ok $? "arquivo de mais de um dia: os horários levam a data (cabeçalho, 'às' e 'visto')"
  jrp --summary "$T/gap-a.jsonl" "$T/gap-b.jsonl" --max-gap 100000 > "$T/g2" 2>/dev/null; grep -q '^\* saltos de swap >= 200 MB entre amostras seguidas: 1$' "$T/g2" && grep -q '+300, em 80955 s' "$T/g2" && ! grep -q '^AVISO: [0-9]* buraco' "$T/g2"; ok $? "--max-gap grande o bastante: o par vira evento e não há aviso de buraco (a opção manda)"
  jrp --summary "$T/hole.jsonl" > "$T/h" 2>/dev/null; grep -q '^AVISO: 1 buraco(s) entre amostras seguidas (passo > 15 s), somando 50 s; o maior: 50 s, de 04:01:35 a 04:02:25\.' "$T/h" && grep -q '^\* saltos de swap >= 200 MB entre amostras seguidas: 1 (+ 1 par(es) de leituras a mais de 15 s um do outro, NÃO avaliados; variação >= 200 MB em 0:' "$T/h"; ok $? "buraco de 50 s: dito; o salto entre amostras vizinhas continua sendo salto, e o par que cruza o buraco é contado (sem variação)"
  grep -q '^  - 04:02:30  1000 -> 1500 MB (+500, em 5 s)  nos 60 s antes: sem atribuição (sem amostra de base 60 s antes, buraco na janela' "$T/h" && ! grep -q 'com.test.grower +' "$T/h"; ok $? "base de 60 s antes cruza o buraco: 'sem atribuição', não o 'grower' que só existe depois dele"
  jrp --summary "$T/night.jsonl" "$T/night.jsonl" > "$T/d" 2>/dev/null; ! grep -q '^AVISO: [0-9]* buraco' "$T/d" && grep -q 'passo mediano 5 s' "$T/d" && grep -q 'saltos de swap >= 200 MB entre amostras seguidas: 2$' "$T/d"; ok $? "o mesmo arquivo duas vezes (passos de 0 s) não zera o limite: sem buracos, passo mediano 5 s, os mesmos 2 saltos"
  # a tabela de jobs e o corte --top
  ! grep -q 'mostrando' "$T/s"; ok $? "tabela inteira (3 jobs <= 40): nenhum aviso de corte"
  jrp --summary "$T/night.jsonl" --top 2 > "$T/t" 2>/dev/null; grep -q '^(mostrando 2 de 3 labels, os de maior pico; o menor mostrado tem 400 MB\. Label que não está aqui NÃO é label que não apareceu' "$T/t" && ! grep -q '^| com.test.small |' "$T/t"; ok $? "--top 2: a tabela corta e DIZ 'mostrando 2 de 3' (label ausente não é label que não apareceu)"
  jrp --summary "$T/night.jsonl" --top 0 > "$T/t0" 2>/dev/null; grep -q '^| com.test.small |' "$T/t0" && ! grep -q 'mostrando' "$T/t0"; ok $? "--top 0 mostra todos os jobs, sem aviso de corte"
  jrp --summary "$T/night.jsonl" --max-gap 0 >/dev/null 2>"$T/e"; RC=$?; [ "$RC" = 2 ]; ok $? "--max-gap 0: exit 2 (rc=$RC)"
  jrp --summary "$T/night.jsonl" --top -1 >/dev/null 2>"$T/e"; RC=$?; [ "$RC" = 2 ]; ok $? "--top -1: exit 2 (rc=$RC)"
  # os três estados do resumo
  : > "$T/vazio.jsonl"; jrp --summary "$T/vazio.jsonl" >"$T/o" 2>"$T/e"; RC=$?; [ "$RC" = 3 ] && [ ! -s "$T/o" ] && ! grep -q Traceback "$T/e"; ok $? "arquivo vazio: exit 3 sem relatório (não sei ≠ nada rodou) (rc=$RC)"
  printf 'lixo\n{"a":1}\n[1]\n' > "$T/lixo.jsonl"; jrp --summary "$T/lixo.jsonl" >"$T/o" 2>"$T/e"; RC=$?; [ "$RC" = 3 ] && grep -q '3 linhas ilegíveis' "$T/e"; ok $? "só linhas que não são amostra: exit 3 e diz quantas (rc=$RC)"
  jrp --summary "$T/nao-existe.jsonl" >"$T/o" 2>"$T/e"; RC=$?; [ "$RC" = 3 ] && ! grep -q Traceback "$T/e"; ok $? "arquivo ausente: exit 3 (rc=$RC)"
  printf '{"ts":1,"jobs":{}}\n\xff\xfe\n' > "$T/utf.jsonl"; jrp --summary "$T/utf.jsonl" >"$T/o" 2>"$T/e"; RC=$?; [ "$RC" = 3 ] && ! grep -q Traceback "$T/e"; ok $? "arquivo com byte que não é UTF-8: exit 3, sem traceback (rc=$RC)"
  python3 -I - "$T/semps.jsonl" <<'EOF'
import json, sys
open(sys.argv[1], "w").write("".join(json.dumps({"ts": 1704081600 + 5 * i, "ps_ok": False, "lc_ok": True, "swap_used_mb": 100.0, "free_pct": 50, "total_rss_kb": None, "jobs": {}, "dt_ms": 10}) + "\n" for i in range(4)))
EOF
  jrp --summary "$T/semps.jsonl" >"$T/o" 2>/dev/null; RC=$?; [ "$RC" = 0 ] && grep -q 'nenhuma amostra com ps E launchctl válidos' "$T/o" && ! grep -q 'nenhum job não persistente' "$T/o" && grep -q '^AVISO: 4 amostras sem ps' "$T/o" && grep -q 'livre: sem nenhuma leitura (arquivo sem o campo' "$T/o"; ok $? "todas as amostras sem ps: o relatório diz que não sabe, não afirma 'nenhum job apareceu'; arquivo sem campo de disco diz 'sem nenhuma leitura' (rc=$RC)"

  # --- o plano de horário (TZ=UTC; agora = 2024-01-01 hh:mm) ---
  python3 -I - "$P" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("jrp", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
D = 1704067200  # 2024-01-01 00:00 UTC
at = lambda h, mi=0, day=0: D + day * 86400 + h * 3600 + mi * 60
bad = []
def chk(name, got, want):
    if got != want: bad.append(f"{name}: {got} != {want}")
chk("antes da janela", m.plan(at(3), 230, 300), (at(3, 50), at(5)))
chk("dentro da janela começa agora", m.plan(at(4, 10), 230, 300), (at(4, 10), at(5)))
chk("depois da janela: amanhã", m.plan(at(5, 30), 230, 300), (at(3, 50, 1), at(5, 0, 1)))
chk("atravessa a meia-noite, dentro", m.plan(at(23, 40), 23 * 60 + 30, 60), (at(23, 40), at(1, 0, 1)))
chk("atravessa a meia-noite, fora", m.plan(at(2), 23 * 60 + 30, 60), (at(23, 30), at(1, 0, 1)))
chk("sem --start começa agora", m.plan(at(3), None, 300), (at(3), at(5)))
chk("00:00 vale como hora (não é 'sem --start')", m.plan(at(23), 0, 60), (at(0, 0, 1), at(1, 0, 1)))
for b in bad: print("FALHA:", b)
sys.exit(1 if bad else 0)
EOF
  ok $? "plano de horário: antes, dentro, depois e atravessando a meia-noite"

  # --- segurança de disco e de instância ---
  jrp --fixture-dir "$FX" --ticks 9 --interval 1 --max-mb 0.0001 --out "$T/cap.jsonl" >/dev/null 2>"$T/e"; RC=$?; [ "$RC" = 5 ] && [ "$(wc -l < "$T/cap.jsonl" | tr -d " ")" = 1 ] && grep -q 'passou de' "$T/e"; ok $? "arquivo passou do teto: para com exit 5 depois de 1 amostra (rc=$RC)"
  jrp --fixture-dir "$FX" --ticks 9 --interval 1 --min-free-gb 100000000 --out "$T/piso.jsonl" >/dev/null 2>"$T/e"; RC=$?; [ "$RC" = 6 ] && [ ! -s "$T/piso.jsonl" ]; ok $? "disco abaixo do piso no início: exit 6 e NADA gravado (rc=$RC)"
  python3 -I - "$P" "$FX" "$T/meio.jsonl" <<'EOF'
import argparse, collections, importlib.util, sys
spec = importlib.util.spec_from_file_location("jrp", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
U = collections.namedtuple("U", "total used free"); calls = [0]
def fake(path):
    calls[0] += 1
    return U(10**12, 0, 10**12 if calls[0] == 1 else 0)  # a 1ª conferência (início) passa; as seguintes, não
m.shutil.disk_usage = fake
a = argparse.Namespace(out=sys.argv[3], min_free_gb=1.0, start=None, until=None, duration=None, ticks=30, interval=1.0, max_mb=40.0, check_every=2, fixture_dir=sys.argv[2], skip_free_gb=0.0)
rc = m.record(a); n = len(open(sys.argv[3]).read().splitlines())
sys.exit(0 if (rc, n) == (6, 2) else 1)
EOF
  ok $? "disco que cai DEPOIS do início: para com exit 6 na conferência seguinte (2 amostras de 30)"
  # --- disco baixo: não amostra, ESCREVE "pulado" e segue (ga-sh8t23.6) ---
  jrp --fixture-dir "$FX" --duration 2.5 --interval 1 --skip-free-gb 100000000 --out "$T/skip.jsonl" >/dev/null 2>"$T/e"; RC=$?
  python3 -I - "$T/skip.jsonl" <<'EOF'
import json, sys
rs = [json.loads(l) for l in open(sys.argv[1])]
sys.exit(0 if len(rs) >= 2 and all(r.get("pulado") == "disco" and isinstance(r.get("ts"), int) and isinstance(r.get("disk_free_mb"), int) and "jobs" not in r for r in rs) else 1)
EOF
  [ $? = 0 ] && [ "$RC" = 3 ] && grep -q 'amostra(s) puladas por disco livre abaixo de' "$T/e"; ok $? "disco abaixo do piso de amostragem: só linhas 'pulado: disco', nenhuma amostra, exit 3 (nada tirado não é sucesso) e diz quantas (rc=$RC)"
  jrp --fixture-dir "$FX" --ticks 3 --interval 1 --skip-free-gb 0.000001 --out "$T/noskip.jsonl" >/dev/null 2>"$T/e"; RC=$?
  [ "$RC" = 0 ] && [ "$(wc -l < "$T/noskip.jsonl" | tr -d " ")" = 3 ] && ! grep -q pulado "$T/noskip.jsonl"; ok $? "disco acima do piso de amostragem: 3 amostras e nenhuma linha 'pulado' (rc=$RC)"
  python3 -I - "$P" "$FX" "$T/volta.jsonl" <<'EOF'
import argparse, collections, importlib.util, json, sys
spec = importlib.util.spec_from_file_location("jrp", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
U = collections.namedtuple("U", "total used free"); calls = [0]
def fake(path):
    calls[0] += 1  # 1: conferência do início · 2: tick 1 (disco baixo) · 3: tick 2 (leitura FALHA) · 4 em diante: disco de volta
    if calls[0] == 3: raise OSError("statvfs falhou")
    return U(10**12, 0, 10**9 if calls[0] == 2 else 10**12)
m.shutil.disk_usage = fake
a = argparse.Namespace(out=sys.argv[3], min_free_gb=0.0, start=None, until=None, duration=None, ticks=2, interval=1.0, max_mb=40.0, check_every=99, fixture_dir=sys.argv[2], skip_free_gb=3.0)
rc = m.record(a); rs = [json.loads(l) for l in open(sys.argv[3])]
kinds = ["pulado" if "pulado" in r else "amostra" for r in rs]
sys.exit(0 if rc == 0 and kinds == ["pulado", "pulado", "amostra", "amostra"] and rs[1]["disk_free_mb"] is None and rs[0]["disk_free_mb"] == 953 and rs[0]["piso_mb"] == 3072 else 1)
EOF
  ok $? "pula com disco baixo E com disco ilegível (disk_free_mb null, não 0), e volta a amostrar quando o disco volta (2 puladas, 2 amostras, exit 0)"
  jrp --ticks 1 --skip-free-gb -1 --out "$T/x3.jsonl" >/dev/null 2>&1; RC=$?; [ "$RC" = 2 ] && [ ! -e "$T/x3.jsonl" ]; ok $? "--skip-free-gb negativo: exit 2 e nenhum arquivo (rc=$RC)"
  jrp --ticks 1 --skip-free-gb nan --out "$T/x4.jsonl" >/dev/null 2>&1; RC=$?; [ "$RC" = 2 ] && [ ! -e "$T/x4.jsonl" ]; ok $? "--skip-free-gb nan: exit 2 (nan nunca pularia: o piso ficaria desligado em silêncio) (rc=$RC)"
  jrp --ticks 1 --skip-free-gb inf --out "$T/x5.jsonl" >/dev/null 2>"$T/e"; RC=$?; [ "$RC" = 2 ] && [ ! -e "$T/x5.jsonl" ] && ! grep -q Traceback "$T/e"; ok $? "--skip-free-gb inf: exit 2 sem traceback (antes passava no teste de uso e estourava em int() no 1º pulo) (rc=$RC)"
  # resumo: a linha "pulado" é contada e dita; não é amostra nem linha ilegível
  { cat "$T/night.jsonl"; printf '{"ts":1704081620,"pulado":"disco","disk_free_mb":2100,"piso_mb":3072}\n{"ts":1704081625,"pulado":"disco","disk_free_mb":2050,"piso_mb":3072}\n{"ts":1704081630,"pulado":"disco","disk_free_mb":null,"piso_mb":3072}\n'; } > "$T/pulos.jsonl"
  jrp --summary "$T/night.jsonl" > "$T/p0" 2>/dev/null; jrp --summary "$T/pulos.jsonl" > "$T/p" 2>"$T/e"; RC=$?  # a noite fabricada já traz 1 linha ilegível de propósito: as 3 'pulado' não podem somar a ela
  [ "$RC" = 0 ] && sed -n 3p "$T/p" | grep -q '^AVISO: 3 amostra(s) NÃO tiradas por falta de disco livre (de 04:00:20 a 04:00:30)' && grep -q ', 1 linhas ilegíveis:' "$T/p" && [ "$(sed -n 1,2p "$T/p0")" = "$(sed -n 1,2p "$T/p")" ]; ok $? "resumo com 3 linhas 'pulado': dito com o intervalo; cabeçalho e contagem de ilegíveis iguais aos do arquivo sem elas (as 3 não são amostra nem lixo) (rc=$RC)"
  printf '{"ts":1704081620,"pulado":"disco","disk_free_mb":2100,"piso_mb":3072}\n' > "$T/so-pulos.jsonl"; jrp --summary "$T/so-pulos.jsonl" >"$T/o" 2>"$T/e"; RC=$?
  [ "$RC" = 3 ] && [ ! -s "$T/o" ] && grep -q '1 puladas por disco' "$T/e"; ok $? "arquivo só com linhas 'pulado': exit 3 sem relatório, e diz que foram puladas (não sei ≠ nada rodou) (rc=$RC)"
  (jrp --duration 20 --interval 1 --out "$T/lock.jsonl" >/dev/null 2>&1 &) ; sleep 3
  jrp --ticks 1 --interval 1 --out "$T/lock.jsonl" >/dev/null 2>"$T/e"; RC=$?; [ "$RC" = 4 ] && grep -q 'outra instância' "$T/e"; ok $? "segunda instância no mesmo arquivo: exit 4 (rc=$RC)"
  pkill -f "job-ram-probe.py --duration 20 --interval 1 --out $T/lock.jsonl" 2>/dev/null; sleep 1
  # --- uso errado ---
  jrp --interval 1 >/dev/null 2>&1; RC=$?; [ "$RC" = 2 ]; ok $? "sem --until/--duration/--ticks nem --summary: exit 2 (rc=$RC)"
  jrp --ticks 1 --interval 0.5 --out "$T/x.jsonl" >/dev/null 2>&1; RC=$?; [ "$RC" = 2 ]; ok $? "--interval abaixo de 1 s: exit 2 (rc=$RC)"
  jrp --ticks 1 --start 25:00 --out "$T/x.jsonl" >/dev/null 2>&1; RC=$?; [ "$RC" = 2 ]; ok $? "hora inválida: exit 2 (rc=$RC)"
  jrp --ticks 1 --check-every 0 --out "$T/x.jsonl" >/dev/null 2>&1; RC=$?; [ "$RC" = 2 ]; ok $? "--check-every 0: exit 2 (rc=$RC)"
  jrp --ticks 0 --out "$T/x0.jsonl" >/dev/null 2>"$T/e"; RC=$?; [ "$RC" = 2 ] && [ ! -e "$T/x0.jsonl" ]; ok $? "--ticks 0: exit 2 e NENHUM arquivo criado (antes saía 0 em silêncio com o arquivo vazio) (rc=$RC)"
  jrp --duration 0 --out "$T/x1.jsonl" >/dev/null 2>&1; RC=$?; [ "$RC" = 2 ] && [ ! -e "$T/x1.jsonl" ]; ok $? "--duration 0: exit 2 e nenhum arquivo (rc=$RC)"
  jrp --duration 5 --until 05:00 --out "$T/x2.jsonl" >/dev/null 2>&1; RC=$?; [ "$RC" = 2 ] && [ ! -e "$T/x2.jsonl" ]; ok $? "--duration junto de --until: exit 2 (antes um calava o outro) (rc=$RC)"
  python3 -I - "$P" "$FX" "$T/nada.jsonl" "$T/nada.err" <<'EOF'
import argparse, contextlib, importlib.util, sys
spec = importlib.util.spec_from_file_location("jrp", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
a = argparse.Namespace(out=sys.argv[3], min_free_gb=1.0, start=None, until=None, duration=0.0, ticks=None, interval=1.0, max_mb=40.0, check_every=12, fixture_dir=sys.argv[2], skip_free_gb=0.0)
with open(sys.argv[4], "w") as err, contextlib.redirect_stderr(err):
    rc = m.record(a)
sys.exit(0 if (rc, open(sys.argv[3]).read()) == (3, "") and "nenhuma amostra gravada" in open(sys.argv[4]).read() else 1)
EOF
  ok $? "janela que acaba antes da 1ª amostra: exit 3 e a mensagem, não 0 com o arquivo vazio"
  # --- caminho ao vivo com sysctl que falha e memory_pressure lento (ps e launchctl são os de verdade): só ele cobre a leitura real de swap e o custo medido ---
  mkdir -p "$T/stubbin"; printf '#!/bin/sh\nexit 1\n' > "$T/stubbin/sysctl"; printf '#!/bin/sh\nsleep 0.4\n' > "$T/stubbin/memory_pressure"; chmod +x "$T/stubbin/sysctl" "$T/stubbin/memory_pressure"
  PATH="$T/stubbin:$PATH" jrp --ticks 1 --interval 1 --out "$T/stub.jsonl" >/dev/null 2>&1
  rec "$T/stub.jsonl" 0 'r["swap_used_mb"] is None and r["free_pct"] is None and r["ps_ok"] is True and r["dt_ms"] >= 350 and isinstance(r["disk_free_mb"], int) and r["disk_free_mb"] > 0' "ao vivo: sysctl que falha = swap null (NÃO 0), % livre sem resposta = null, o disco livre é lido de verdade e o custo da amostra é medido (dt_ms >= 350 com um memory_pressure de 0,4 s)"
  # --- fumaça no sistema real (fora dos mutantes: lenta e depende do launchd) ---
  if [ -z "${JRP_MUTANT:-}" ]; then
    jrp --ticks 2 --interval 1 --out "$T/live.jsonl" >/dev/null 2>"$T/e"; RC=$?
    python3 -I - "$T/live.jsonl" <<'EOF'
import json, sys
rs = [json.loads(l) for l in open(sys.argv[1])]
sys.exit(0 if len(rs) == 2 and all(r["ps_ok"] and r["lc_ok"] and r["total_rss_kb"] > 0 and r["jobs"] and r["dt_ms"] < 20000 for r in rs) else 1)
EOF
    ok $? "fumaça no sistema real: 2 amostras com ps e launchctl lidos e jobs atribuídos (rc=$RC)"
  fi
}

if [ -n "${JRP_MUTANT:-}" ]; then run_all; echo "RESULT $fails/$n"; exit $((fails > 0)); fi
run_all
echo "== $((n-fails))/$n ok =="

[ -n "${JRP_NO_MUTANTS:-}" ] || {
  echo "-- controle negativo: cada guarda removida TEM que fazer a suíte falhar"
  mutant() {  # mutant DESCRIÇÃO SED-EXPR
    local m="$T/mut.$RANDOM"; mkdir -p "$m"; cp "$HERE/ram_owner_lib.py" "$m/"; sed -e "$2" "$P" > "$m/job-ram-probe.py"
    if cmp -s "$P" "$m/job-ram-probe.py"; then ok 1 "mutante '$1': o sed não mudou nada (o teste do mutante está errado)"; return; fi
    local r; r=$(JRP_MUTANT=1 JRP_UNDER_TEST="$m/job-ram-probe.py" bash "$0" 2>&1 | tail -1)
    case "$r" in "RESULT 0/"*) ok 1 "mutante '$1' NÃO foi pego ($r)";; "RESULT "*) ok 0 "mutante '$1' pego ($r)";; *) ok 1 "mutante '$1': execução sem resultado ($r)";; esac
  }
  mutant "launchctl sem job nenhum vira 'nenhum job rodando'" 's/    return pids if rows else None/    return pids/'
  mutant "ps vazio vira ps_ok true" 's/    ps_ok = bool(tbl) .*$/    ps_ok = True/'
  mutant "job que o launchctl lista e o ps (lido antes) ainda não tem vira 0 MB" 's/        if root not in tbl: .*$/        if False:/'
  mutant "ciclo na árvore não termina" 's/            if pid in seen or pid not in tbl: .*$/            if pid not in tbl:/'
  mutant "launchctl com byte não-UTF-8 vira traceback" 's/    except (OSError, ValueError, subprocess.SubprocessError):/    except (OSError, subprocess.SubprocessError):/'
  mutant "linha ilegível some sem ser contada" 's/                    bad += 1 .*$/                    pass/'
  mutant "arquivo vazio vira relatório" 's/        if not recs: .*$/        if False:/'
  mutant "salto sem amostra na janela vira 'ninguém cresceu'" 's/    if j < 0 or any(not (r.get("ps_ok") and r.get("lc_ok")) for r in win): .*$/    if False:/'
  mutant "daemon deixa de ser persistente" 's/^PERSISTENT = 0.9 .*$/PERSISTENT = 1.5/'
  mutant "qualquer crescimento é suspeito" 's/^GROW_KB = .*$/GROW_KB = 1/'
  mutant "dentro da janela espera o dia seguinte" 's/    if end is not None and start > end: .*$/    if False:/'
  mutant "teto de tamanho não para" 's/            if f.tell() > a.max_mb \* 1024 \* 1024: .*$/            if False:/'
  mutant "piso de disco no meio não para" 's/            if n % a.check_every == 0 and shutil.disk_usage(outdir).free < floor: .*$/            if False:/'
  mutant "piso de disco no início não recusa" 's/^    if shutil.disk_usage(outdir).free < floor:$/    if False:/'
  mutant "segunda instância grava junto" 's/        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)/        pass/'
  mutant "00:00 vira 'sem --start'" 's/    start = next_at(start_hm, now) if start_hm is not None else now/    start = next_at(start_hm, now) if start_hm else now/'
  mutant "campo não lido ('-') vira 0" 's/        num = lambda x, kind: None if x == "-" else kind(x)/        num = lambda x, kind: 0 if x == "-" else kind(x)/'
  mutant "queda de disco numa amostra sem launchctl vira 'nenhum job rodando'" 's/ if not (b.get("ps_ok") and b.get("lc_ok")) else (/ if False else (/'
  mutant "swap não lido vira 0" 's/swap, free, disk = lib.swap_usage()\[0\], /swap, free, disk = lib.swap_usage()[0] or 0, /'
  mutant "custo da amostra não é gravado" 's/    rec\["dt_ms"\] = int((time.time() - t0) \* 1000)/    rec["dt_ms"] = 0/'
  mutant "par separado por um buraco vira salto de swap / queda de disco" 's/        if b\["ts"\] - a\["ts"\] > limit:  # \[guard:gap-moves\]/        if False:/'
  mutant "base de 60 s antes velha (buraco na janela) vira atribuição" 's/    if any(y\["ts"\] - x\["ts"\] > limit for x, y in zip(win, win\[1:\])): .*$/    if False:/'
  mutant "buraco não é contado nem dito" 's/^    if holes:$/    if False:/'
  mutant "passo de 0 s (arquivo repetido) entra na mediana e zera o limite" 's/ for a, b in zip(recs, recs\[1:\]) if b\["ts"\] > a\["ts"\]\]/ for a, b in zip(recs, recs[1:])]/'
  mutant "tabela cortada em --top sem dizer" 's/^    if len(shown) < len(rows):  # \[guard:top\]/    if False:/'
  mutant "--ticks 0 / --duration 0 / --duration com --until passam" 's/^            or (a.ticks is not None and a.ticks < 1) or (a.duration is not None and (a.duration <= 0 or a.until is not None))):/            ):/'
  mutant "disco baixo não pula (amostra assim mesmo)" 's/^            if skip_floor and (free_mb is None or free_mb \* 1048576 < skip_floor): .*$/            if False:/'
  mutant "disco ilegível vira 'tem espaço'" 's/free_mb is None or free_mb \* 1048576 < skip_floor/free_mb is not None and free_mb * 1048576 < skip_floor/'
  mutant "linha 'pulado' conta como linha ilegível" 's/^                    if isinstance(r, dict) and isinstance(r.get("ts"), int) and r.get("pulado") == "disco": .*$/                    if False:/'
  mutant "resumo não diz as amostras puladas" 's/^    if skipped:  # \[guard:skipped\]$/    if False:/'
  mutant "probe não diz quantas amostras pulou" 's/^    if skipped:$/    if False:/'
  mutant "piso de amostragem nan/inf passa" 's/ or not 0 <= a.skip_free_gb < 1e9 or / or a.skip_free_gb < 0 or /'
  mutant "janela sem nenhuma amostra sai com 0" 's/^    if n == 0:  # a janela acabou .*$/    if False:/'
  echo "== mutantes: $((n-fails))/$n ok no total =="
}
[ "$fails" = 0 ]
