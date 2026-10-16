#!/usr/bin/env bash
# nightly-grid.selftest.sh — hermético: plists falsos numa pasta de mktemp e a saída do `launchctl list` injetada; não lê o launchd de verdade.
#
# Contents
#   Fixture · Casos · Controle negativo (mutantes) · Variáveis
#
# CASOS: colisão por label distinto (o mesmo job em 5 dias da semana é UM) · curinga (sem Hour = toda hora, sem Minute = todo minuto, fora das colisões) · condicional
#   marcado · janela (00:00 e 07:59 dentro, 08:00 fora; --from/--to) · StartInterval por faixa · RunAtLoad/KeepAlive · os TRÊS ESTADOS: plist ilegível listado com o
#   motivo, calendário que não conheço listado (e sem entrada solta na grade), plist não carregado fora das colisões, `launchctl` que falha / vem vazio = "desconhecido"
#   (nunca "nada carregado"), pasta ilegível = exit 3 sem grade, filtro que não casa nada diz isso · uso errado = exit 2 · SOMENTE LEITURA (a pasta não muda).
# CONTROLE NEGATIVO: cada guarda é removida do script (sed numa cópia) e a suíte TEM que passar a falhar.
# VARIÁVEIS: NG_UNDER_TEST (script a testar) · NG_NO_MUTANTS=1
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
P="${NG_UNDER_TEST:-$HERE/nightly-grid.py}"
T=$(cd "$(mktemp -d /tmp/ng.XXXXXX)" && pwd -P)
trap 'chmod -R u+rwX "$T" 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
D="$T/la"; L="$T/loaded.txt"; mkdir -p "$D"
fails=0; n=0
ok() { n=$((n+1)); if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }

# plutil de mentira (hermético): só "converte" o plist cujo nome termina em lenient.plist; para o resto sai 1, como o plutil de verdade faria com lixo
printf '#!/bin/sh\ncase "$5" in *lenient.plist) cat "%s/lenient.xml" ;; *) exit 1 ;; esac\n' "$T" > "$T/plutil-stub"; chmod +x "$T/plutil-stub"; export NG_PLUTIL="$T/plutil-stub"
python3 - "$D" "$L" "$T" <<'EOF'
import plistlib, sys, os
d, loaded, tmp = sys.argv[1], sys.argv[2], sys.argv[3]
def w(label, **kw):
    kw["Label"] = label
    plistlib.dump(kw, open(os.path.join(d, label + ".plist"), "wb"))
cal = lambda **k: {"StartCalendarInterval": k}
for x in "abc": w(f"com.gascity.d0400{x}", **cal(Hour=4, Minute=0))
w("com.gascity.hourly15", **cal(Minute=15))
w("com.gascity.everymin", **cal(Hour=4))
w("com.gascity.weekdays", StartCalendarInterval=[{"Weekday": k, "Hour": 4, "Minute": 0} for k in range(1, 6)])
w("com.gascity.sun7", **cal(Weekday=7, Hour=5, Minute=0))
w("com.gascity.interval", StartInterval=300)
w("com.gascity.boot", RunAtLoad=True, KeepAlive={"SuccessfulExit": False})
w("com.gascity.notloaded", **cal(Hour=4, Minute=0))
open(os.path.join(d, "com.gascity.garbage.plist"), "wb").write(b"\x00\x01 isto nao e plist")
w("com.gascity.oddstr", RunAtLoad=True, StartCalendarInterval="tue")
w("com.gascity.badmin", **cal(Hour=4, Minute=99))
w("com.gascity.partial", StartCalendarInterval=[{"Hour": 3, "Minute": 0}, {"Hour": 3, "Minute": 99}])
w("com.gascity.t0000", **cal(Hour=0, Minute=0))
w("com.gascity.t0759", **cal(Hour=7, Minute=59))
w("com.gascity.t0800", **cal(Hour=8, Minute=0))
w("com.apple.sys", **cal(Hour=4, Minute=0))
# XML que o expat do Python recusa (`--` dentro de comentário) e o launchd/plutil aceita: foi o que escondeu 2 jobs vivos da grade na primeira versão
open(os.path.join(d, "com.gascity.lenient.plist"), "w").write("<?xml version=\"1.0\"?><plist version=\"1.0\"><!-- usa --dry-run --><dict><key>Label</key><string>com.gascity.lenient</string></dict></plist>")
open(os.path.join(tmp, "lenient.xml"), "wb").write(plistlib.dumps({"Label": "com.gascity.lenient", "StartCalendarInterval": {"Hour": 2, "Minute": 20}}))
labels = [f[:-6] for f in sorted(os.listdir(d)) if f.endswith(".plist") and "garbage" not in f and "notloaded" not in f]
open(loaded, "w").write("PID\tStatus\tLabel\n" + "".join(f"-\t0\t{l}\n" for l in labels) + "123\t0\tcom.other.thing\n")
EOF
before=$(cd "$D" && find . -type f -exec shasum {} + | sort | shasum)

run() { python3 -I "$P" --dir "$D" --loaded-file "$L" "$@" >"$T/o" 2>"$T/e"; RC=$?; }
chk() {  # chk 'expr em python sobre r (o JSON)' descrição [args…]. O eval abaixo só avalia as expressões escritas NESTE arquivo de teste (nenhuma entrada externa chega nele).
  local expr="$1" desc="$2"; shift 2
  run --json "$@"; python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if (eval(sys.argv[2])) else 1)' "$T/o" "$expr" 2>"$T/pe"; ok $? "$desc"
}
run_all() {
  chk 'sorted(r["collisions"]["04:00"]) == ["com.gascity.d0400a", "com.gascity.d0400b", "com.gascity.d0400c", "com.gascity.weekdays [seg,ter,qua,qui,sex]"]' "04:00: 3 diários + o job de 5 dias contam como 4 jobs, não 8 entradas" --match gascity
  chk '"com.gascity.notloaded" not in str(r["grid"]) and r["not_loaded"] == ["com.gascity.notloaded"]' "plist não carregado fica fora da grade e listado à parte" --match gascity
  chk '"com.apple.sys" not in str(r)' "filtro padrão (nome do arquivo) deixa o plist da apple de fora"
  chk '"com.apple.sys" in str(r["grid"]["04:00"])' "--match . traz de volta o que o filtro tirou" --match .
  chk 'sum(1 for v in r["grid"].values() if any(x.startswith("com.gascity.hourly15") for x in v)) == 8 and "00:15" in r["grid"] and "07:15" in r["grid"]' "sem Hour = toda hora: 8 inícios na janela" --match gascity
  chk '"com.gascity.everymin" in r["every_minute"] and "com.gascity.everymin" not in str(r["grid"])' "sem Minute = todo minuto: listado à parte, fora das colisões" --match gascity
  chk 'r["grid"]["05:00"] == ["com.gascity.sun7 [dom]"]' "Weekday 7 = domingo, marcado como condicional" --match gascity
  chk '"00:00" in r["grid"] and "07:59" in r["grid"] and "08:00" not in r["grid"]' "janela: 00:00 e 07:59 dentro, 08:00 fora" --match gascity
  chk 'list(r["grid"]) == ["04:00", "04:15"] and r["window"] == ["03:50", "04:20"]' "--from/--to recortam a janela (04:00 e o 04:15 do job de toda hora)" --match gascity --from 03:50 --to 04:20
  chk 'r["periodic"] == {"<= 5 min": 1}' "StartInterval 300 cai na faixa <= 5 min" --match gascity
  chk 'r["boot"] == ["com.gascity.boot", "com.gascity.oddstr"] and r["counts"]["keepalive"] == 1' "RunAtLoad e KeepAlive contados (inclusive o job de calendário estranho)" --match gascity
  chk '"com.gascity.lenient" in r["grid"]["02:20"] and r["counts"]["lidos_via_plutil"] == 1 and "lenient" not in str(r["unreadable"])' "XML que o Python recusa mas o launchd aceita é lido via plutil e entra na grade" --match gascity
  NG_PLUTIL=/bin/false python3 -I "$P" --dir "$D" --loaded-file "$L" --match gascity --json >"$T/o" 2>/dev/null; python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if "02:20" not in r["grid"] and r["counts"]["ilegiveis"]==2 and r["counts"]["lidos_via_plutil"]==0 else 1)' "$T/o"; ok $? "se o plutil também falha, o plist vai para ilegíveis (visível), não some"
  chk '[u["file"] for u in r["unreadable"]] == ["com.gascity.garbage.plist"] and r["counts"]["ilegiveis"] == 1 and r["unreadable"][0]["why"]' "plist ilegível aparece com o motivo, e conta" --match gascity
  chk 'r["odd"] == ["com.gascity.badmin", "com.gascity.oddstr", "com.gascity.partial"] and r["counts"]["formato_desconhecido"] == 3' "calendário que não conheço: listado e contado" --match gascity
  chk '"03:00" not in r["grid"]' "job que falha na 2ª entrada não deixa a 1ª solta na grade" --match gascity
  chk 'r["counts"]["plists"] == 18 and r["loaded"] == "conhecido"' "o resumo conta TODOS os plists do filtro (ilegível incluso)" --match gascity
  chk 'list(r["collisions"]) == ["04:00"]' "--min-collision 4 deixa só o minuto com 4 jobs" --match gascity --min-collision 4
  run --match gascity --boot; grep -q "com.gascity.boot" "$T/o" && grep -q "## Minutos com 3 ou mais inícios" "$T/o" && grep -q "com.gascity.garbage.plist" "$T/o"; ok $? "saída em texto: colisões, ilegíveis e --boot lista o conjunto do boot"
  # os três estados do launchctl
  NG_LAUNCHCTL=/bin/false python3 -I "$P" --dir "$D" --match gascity --json >"$T/o" 2>/dev/null; python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if r["loaded"]=="desconhecido" and "com.gascity.notloaded" in str(r["grid"]["04:00"]) and r["counts"]["nao_carregados"]==0 else 1)' "$T/o"; ok $? "launchctl que falha = desconhecido: TODOS entram na grade (inclusive o não carregado)"
  NG_LAUNCHCTL=/bin/false python3 -I "$P" --dir "$D" --match gascity >"$T/o" 2>/dev/null; grep -q "AVISO: não consegui ler" "$T/o"; ok $? "launchctl desconhecido é dito no relatório (AVISO)"
  printf 'PID\tStatus\tLabel\n' > "$T/empty.txt"; python3 -I "$P" --dir "$D" --match gascity --json --loaded-file "$T/empty.txt" >"$T/o" 2>/dev/null; python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if r["loaded"]=="desconhecido" and r["counts"]["nao_carregados"]==0 else 1)' "$T/o"; ok $? "launchctl list sem nenhuma linha de job é suspeito: desconhecido, não 'nada carregado'"
  printf -- '-\t0\tcom.gascity.d0400a\n' > "$T/nohdr.txt"; python3 -I "$P" --dir "$D" --match gascity --json --loaded-file "$T/nohdr.txt" >"$T/o" 2>/dev/null; python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if r["loaded"]=="conhecido" and r["grid"]["04:00"]==["com.gascity.d0400a"] else 1)' "$T/o"; ok $? "sem cabeçalho no arquivo, a primeira linha é um job e não se perde"
  # entradas que não dá para ler
  python3 -I "$P" --dir "$T/nao-existe" --match gascity --loaded-file "$L" >"$T/o" 2>"$T/e"; RC=$?; [ "$RC" = 3 ] && [ ! -s "$T/o" ] && grep -q "sem grade" "$T/e"; ok $? "pasta ilegível: exit 3, nada na saída (não sei ≠ grade vazia) (rc=$RC)"
  python3 -I "$P" --dir "$D" --match gascity --loaded-file "$T/nao-existe.txt" >"$T/o" 2>"$T/e"; RC=$?; [ "$RC" = 3 ]; ok $? "--loaded-file ilegível: exit 3 (rc=$RC)"
  python3 -I "$P" --dir "$D" --match 'zzz-nada' --loaded-file "$L" >"$T/o" 2>/dev/null; RC=$?; [ "$RC" = 0 ] && grep -q "Nenhum plist casa com o filtro" "$T/o"; ok $? "filtro que não casa nada diz isso, sem fingir grade vazia (rc=$RC)"
  python3 -I "$P" --dir "$D" --match '(' --loaded-file "$L" >"$T/o" 2>"$T/e"; RC=$?; [ "$RC" = 3 ]; ok $? "regex inválida em --match: exit 3 (rc=$RC)"
  run --min-collision 0; [ "$RC" = 2 ]; ok $? "--min-collision 0: uso errado, exit 2 (rc=$RC)"
  run --from 08:00 --to 07:00; [ "$RC" = 2 ]; ok $? "--from depois de --to: exit 2 (rc=$RC)"
  run --from 25:00; [ "$RC" = 2 ]; ok $? "hora inválida: exit 2 (rc=$RC)"
  after=$(cd "$D" && find . -type f -exec shasum {} + | sort | shasum); [ "$before" = "$after" ]; ok $? "somente leitura: a pasta de plists ficou idêntica"
}

if [ -n "${NG_MUTANT:-}" ]; then run_all; echo "RESULT $fails/$n"; exit $((fails > 0)); fi
run_all
echo "== $((n-fails))/$n ok =="

[ -n "${NG_NO_MUTANTS:-}" ] || {
  echo "-- controle negativo: cada guarda removida TEM que fazer a suíte falhar"
  mutant() {  # mutant DESCRIÇÃO SED-EXPR
    local m="$T/mut.$RANDOM"; mkdir -p "$m"; sed -e "$2" "$P" > "$m/nightly-grid.py"
    if cmp -s "$P" "$m/nightly-grid.py"; then ok 1 "mutante '$1': o sed não mudou nada (o teste do mutante está errado)"; return; fi
    local r; r=$(NG_MUTANT=1 NG_UNDER_TEST="$m/nightly-grid.py" bash "$0" 2>&1 | tail -1)
    case "$r" in "RESULT 0/"*) ok 1 "mutante '$1' NÃO foi pego ($r)";; "RESULT "*) ok 0 "mutante '$1' pego ($r)";; *) ok 1 "mutante '$1': execução sem resultado ($r)";; esac
  }
  mutant "sem Minute deixa de ser curinga" 's/^    if minute is None:$/    if False:/'
  mutant "plist não carregado entra nas colisões" 's/        if loaded is not None and j\["label"\] not in loaded:/        if False:/'
  mutant "sem o plutil, o plist que o launchd aceita vira ilegível" 's/            if r.returncode == 0:/            if False:/'
  mutant "plist ilegível some" 's/^            bad.append(.*$/            pass/'
  mutant "launchctl vazio vira 'nada carregado'" 's/    return labels or None/    return labels/'
  mutant "job diário deixa de ser diário (vira condição)" 's/None if cur is None or not cond else cur | {cond}/(cur or set()) | {cond or str(len(cur or ()))}/'
  mutant "janela com o fim exclusivo (07:59 cai fora)" 's/if lo <= h \* 60 + minute <= hi\]/if lo <= h * 60 + minute < hi]/'
  mutant "entrada solta de um job que falha na 2ª" 's/\[starts(e, lo, hi) for e in j\["cal"\]\]/[starts(e, lo, hi) for e in j["cal"][:1]]/'
  mutant "calendário estranho tira o job do boot" 's/    live = \[j for j in jobs if j\["label"\] not in off\]/    live = [j for j in jobs if j["label"] not in off and j["label"] not in odd]/'
  mutant "a primeira linha do arquivo sempre é cabeçalho" 's/    if lines and lines\[0\].startswith("PID"):/    if True:/'
  mutant "o filtro de nome não filtra" 's/re.search(match, n)/True/'
  mutant "pasta ilegível não sai 3" 's/    except (OSError, re.error) as e:/    except re.error as e:/'
  mutant "colisão exige MAIS que N (e não N ou mais)" 's/if len(v) >= n}/if len(v) > n}/'
  mutant "Weekday 7 não é domingo" 's/DAYS\[v % 7\] if key == "Weekday"/DAYS[v % 6] if key == "Weekday"/'
  echo "== final: $((n-fails))/$n ok =="
}
[ "$fails" = 0 ]
