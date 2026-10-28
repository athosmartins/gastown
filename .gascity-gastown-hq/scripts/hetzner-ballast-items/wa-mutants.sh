#!/bin/bash
# wa-mutants.sh — item `work` do lastro do nó Hetzner (ga-tmfmvxi): varre MUTANTES do código do WhatsApp Automation (lib/, daemons/) no origin/main do espelho do NÓ e resume o que SOBREVIVEU (linha do código que nenhum teste da
# família pega). Roda NO nó, sob o governo (hetzner-ballast.py). É o hq-mutants.sh com o pytest do WA no lugar dos selftests de shell: o trabalho é do wrapper scripts/hq-mutate-wa.py (que carrega o motor hq-mutate.py) dentro
# da jaula scripts/hq-sandbox-run.py, os TRÊS tirados do origin/main do rig do hq no nó (git show, sem árvore). A árvore que se muta é a do WA, a MESMA que o wa-suite usa (o espelho filtrado: nenhum dado de lead).
#
# Contents
#   O que faz · Veredito · Três estados · Limites
#
# O QUE FAZ: (1) `hetzner-remote-git.sh pull` dos DOIS rigs (falhou = segue com o clone que há e diz pull=falhou / hqpull=falhou) (2) se o motor já deu o par (main do WA : main do hq) por SEM novidade, há menos de 6 h, sai com
#   "sem-novidade" sem criar árvore (3) `git show` dos três arquivos do motor, do main do hq, para $BALLAST_RUN_DIR/engine/ (4) `wt-add` do WA numa árvore só dele (ballast-wam, e a branch worker/ballast-wam: as duas saem no fim e também no TERM;
#   o nome difere do ballast-wa do wa-suite, que pode rodar ao lado) (5) `hq-mutate-wa.py sweep --python venv-wa/bin/python` com o estado em $BALLAST_HOME/wa-mutants.state.json (o rodízio continua de onde parou: a rodada que acaba no
#   prazo sai `parcial` e a seguinte pega o resto) (6) resumo numa linha `BALLAST-SUMMARY: {json}`: a linha do motor (contagens e NOMES de arquivo/linha dos sobreviventes confirmados, no máximo 15) mais main, hq, pull, hqpull, slots e engine_rc.
#   Quem lê o sobrevivente é o hetzner-ballast-newfail.py (`--fonte wa-mutants`: UM bead rolante, sem rota).
# VEREDITO: o rc do motor passa adiante (0 rodou: completo, parcial, sem-novidade ou sem-cobertura (nada examinado: só ilegível/vermelho/pulado; não grava o marcador) · 97 sem jaula: o kernel não provou o Landlock, nada rodou · 143 interrompido).
#   Mutante que sobrevive é dado, não falha do item. Alvo cuja família já reprova SEM mutante dentro da jaula (precisa de rede, do config/ real, de /Users…) sai como base-vermelha e volta em 2 dias: é o ambiente, não o código.
# TRÊS ESTADOS: sem origin/main num dos rigs (sem-main), sem um dos três arquivos do motor no main do hq (sem-motor: o main ainda não os tem), sem o python do venv do WA (preparo-ausente), árvore do WA sem tests/ ou sem lib/ e daemons/
#   (arvore-sem-testes), wt-add que falha, o motor que morre sem imprimir o resumo (motor-sem-resumo), o estado que o motor não lê (estado-ilegivel, do motor: nunca é zerado) → exit 3 e nada de "sem novidade" gravado. O marcador de ocioso só é
#   escrito quando o motor DISSE sem-novidade com rc 0; ilegível/ausente/velho → roda a rodada (pior caso é repetir uma, nunca pular uma).
# LIMITES: roda no nó como `runner`; o motor só escreve no --work ($BALLAST_RUN_DIR/work) e no estado; cada mutante roda numa cópia da árvore do WA (~150 MB, sem .git, crew/ e node_modules/) na jaula (escrita só no slot e no máximo 512 MB
#   por arquivo, TCP cortado, provada pelo pai antes de qualquer mutante); alvo que cita sudo, tmux, pkill, os.kill… fica FORA (denylist do motor e do wrapper, contada em `skipped`), e o que tem mais de 12 testes na família também.
#   O registro exige `noflag:wa-suite.leak`: vazamento medido pelo wa-suite tranca TODO código do WA no nó. Nenhum dado sai do nó além deste resumo.
set -u
BH=${BALLAST_HOME:?BALLAST_HOME}; RD=${BALLAST_RUN_DIR:?BALLAST_RUN_DIR}; CORES=${BALLAST_CORES:-2}
case "$CORES" in ''|*[!0-9]*|0) CORES=2 ;; esac
SLOTS=${WA_MUTANTS_SLOTS:-$CORES}   # 1 mutante por núcleo reservado: o pytest do WA é CPU de verdade (importa o app inteiro), não fork e espera como o selftest de shell do hq-mutants
case "$SLOTS" in ''|*[!0-9]*|0) SLOTS=$CORES ;; esac
[ "$SLOTS" -le 16 ] || SLOTS=16
BUDGET=${WA_MUTANTS_BUDGET_S:-1800}   # o prazo da linha do registro tem de passar disto em >= 1000 s: um mutante em voo leva até 900 s + 30 (o motor só olha o relógio entre mutantes)
case "$BUDGET" in ''|*[!0-9]*) BUDGET=1800 ;; esac
[ "$BUDGET" -ge 60 ] || BUDGET=60
RG=${BALLAST_REMOTE_GIT:-$HOME/gt-remote/bin/hetzner-remote-git.sh}
GR=${GT_REMOTE_GIT:-$HOME/gt-remote/git}; RIG=${BALLAST_WA_RIG:-whatsapp_automation}; HQRIG=${BALLAST_HQ_RIG:-gascity}
PYV=${BALLAST_WA_PYTHON:-$HOME/gt-remote/venv-wa/bin/python}
STATE="$BH/wa-mutants.state.json"; IDLE="$BH/wa-mutants.idle"; ENGDIR="$RD/engine"
export PATH="$HOME/.local/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 GIT_AUTHOR_NAME=gt GIT_AUTHOR_EMAIL=gt@no GIT_COMMITTER_NAME=gt GIT_COMMITTER_EMAIL=gt@no
bead=""; ep=""
say() { echo "wa-mutants: $*" >&2; }
summary() {  # summary RESULTADO [chave=valor …] — a linha BALLAST-SUMMARY dos desfechos que não chegaram a rodar o motor
  python3 -I -c 'import sys, json
d = {"result": sys.argv[1]}
for kv in sys.argv[2:]:
    k, _, v = kv.partition("=")
    d[k] = v if k in ("main", "hq", "pull", "hqpull") else (int(v) if v.isdigit() else v)
print("BALLAST-SUMMARY: " + json.dumps(d))' "$@"
}
# o wt-rm só tira a ÁRVORE, não a branch worker/<nome>: nome fixo, a velha sai ANTES do wt-add (senão ele a reusaria, na ponta velha) e de novo no fim (a mesma conta do hq-mutants)
branch_rm() { git -C "$GR/$RIG/repo.git" branch -D "worker/$bead" > /dev/null 2>&1; }
cleanup() { [ -z "$bead" ] || { "$RG" wt-rm "$RIG" "$bead" > /dev/null 2>&1; branch_rm; }; }
trap cleanup EXIT
# o TERM do governo vai ao GRUPO inteiro (o motor também o recebe); este trap só espera o motor acabar de matar os mutantes ANTES de a árvore sair, e pára o motor se o TERM veio só para cá
trap '[ -z "$ep" ] || { kill -TERM "$ep" 2>/dev/null; wait "$ep" 2>/dev/null; }; exit 143' TERM INT

pull=ok; hqpull=ok
timeout 300 "$RG" pull "$RIG" > /dev/null 2>&1 || pull=falhou
timeout 300 "$RG" pull "$HQRIG" > /dev/null 2>&1 || hqpull=falhou
# vazio/falhou (sem a ref origin/main) → sem-main e exit 3; nunca "sem novidade"
main=$(git -C "$GR/$RIG/repo.git" rev-parse -q --verify refs/remotes/origin/main 2> /dev/null) || main=""
[ -n "$main" ] || { say "o clone do $RIG não tem origin/main"; summary sem-main pull=$pull hqpull=$hqpull; exit 3; }
hqmain=$(git -C "$GR/$HQRIG/repo.git" rev-parse -q --verify refs/remotes/origin/main 2> /dev/null) || hqmain=""
[ -n "$hqmain" ] || { say "o clone do $HQRIG não tem origin/main"; summary sem-main main="${main:0:9}" pull=$pull hqpull=$hqpull; exit 3; }
KEY="$main:$hqmain"
# marcador = o PAR de pontas que o motor deu por sem-novidade, de menos de 6 h (um alvo pulado por base-vermelha volta a rodar passados 2 dias; sem este prazo ele só voltaria com um commit novo; o motor novo no hq também reabre); vazio/ilegível → roda
if [ "$KEY" = "$(cat "$IDLE" 2> /dev/null)" ] && [ -n "$(find "$IDLE" -mmin -360 2> /dev/null)" ]; then summary sem-novidade main="${main:0:9}" hq="${hqmain:0:9}" pull=$pull hqpull=$hqpull; exit 0; fi

# o registro já exige o python (requires:), mas o item confere de novo: a falta dele é "não rodou", nunca "rodou sem"
[ -x "$PYV" ] || { say "falta $PYV"; summary preparo-ausente main="${main:0:9}" hq="${hqmain:0:9}" pull=$pull hqpull=$hqpull falta="$(basename "$PYV")"; exit 3; }
# os três arquivos do motor, da ponta lida do main do hq (git show: nada de árvore para limpar; $BALLAST_RUN_DIR é novo a cada rodada). vazio (o main ainda não os tem) / falhou (o show não leu) → sem-motor, exit 3
mkdir -p "$ENGDIR" || { say "não criei $ENGDIR"; summary sem-work main="${main:0:9}" hq="${hqmain:0:9}" pull=$pull hqpull=$hqpull; exit 3; }
for f in hq-mutate.py hq-mutate-wa.py hq-sandbox-run.py; do
  if ! git -C "$GR/$HQRIG/repo.git" show "$hqmain:.gascity-gastown-hq/scripts/$f" > "$ENGDIR/$f" 2> /dev/null || [ ! -s "$ENGDIR/$f" ]; then
    say "o main do $HQRIG não tem $f"; summary sem-motor main="${main:0:9}" hq="${hqmain:0:9}" pull=$pull hqpull=$hqpull falta="$f"; exit 3
  fi
done

bead="ballast-wam"
[ ! -e "$GR/$RIG/wt/$bead" ] || "$RG" wt-rm "$RIG" "$bead" > /dev/null 2>&1   # sobra de uma rodada que morreu sem limpar
branch_rm
if ! timeout 900 "$RG" wt-add "$RIG" "$bead" main > "$RD/wt-add.out" 2>&1; then
  say "wt-add falhou: $(tail -n 1 "$RD/wt-add.out")"; summary wt-add-falhou main="${main:0:9}" hq="${hqmain:0:9}" pull=$pull hqpull=$hqpull; exit 3
fi
TREE="$GR/$RIG/wt/$bead"
{ [ -d "$TREE/tests" ] && { [ -d "$TREE/lib" ] || [ -d "$TREE/daemons" ]; }; } || { say "a árvore do WA não tem tests/ e lib/ ou daemons/"; summary arvore-sem-testes main="${main:0:9}" hq="${hqmain:0:9}" pull=$pull hqpull=$hqpull; exit 3; }
# vazio/falhou (sem HEAD legível) → usa a ponta lida antes (a mesma, salvo corrida entre o pull e o wt-add)
tested=$(git -C "$TREE" rev-parse HEAD 2> /dev/null) || tested=$main
mkdir -p "$RD/work" || { say "não criei $RD/work"; summary sem-work main="${tested:0:9}" hq="${hqmain:0:9}" pull=$pull hqpull=$hqpull; exit 3; }

t0=$(date +%s)
python3 -I "$ENGDIR/hq-mutate-wa.py" sweep --tree "$TREE" --state "$STATE" --work "$RD/work" --jail "$ENGDIR/hq-sandbox-run.py" --python "$PYV" --slots "$SLOTS" --budget-s "$BUDGET" > "$RD/engine.out" 2> "$RD/engine.err" < /dev/null &
ep=$!
wait "$ep"; erc=$?; ep=""

# a ÚLTIMA linha JSON do motor com "result" vira o resumo (o motor já a limita a 6000 caracteres; o puxador do governo troca por null o que passa de ~8000). Sem ela o item NÃO fica mudo: motor-sem-resumo, exit 3.
python3 -I - "$RD/engine.out" "$RD/engine.err" "$erc" "${tested:0:9}" "${hqmain:0:9}" "$pull" "$hqpull" "$SLOTS" "$BUDGET" "$IDLE" "$KEY" "$(( $(date +%s) - t0 ))" << 'PY'
import json, os, sys
out_p, err_p, erc, short, hqshort, pull, hqpull, slots, budget, idle_p, key, secs = sys.argv[1:13]
erc = int(erc)
rec = None
try:
    for line in reversed(open(out_p, encoding="utf-8", errors="replace").read().splitlines()):
        try:
            v = json.loads(line)
        except ValueError:
            continue
        if isinstance(v, dict) and "result" in v:
            rec = v
            break
except OSError:
    pass
if rec is None:
    tail = ""
    try:
        tail = open(err_p, encoding="utf-8", errors="replace").read().strip().splitlines()[-1][:160]
    except (OSError, IndexError):
        pass
    rec = {"result": "motor-sem-resumo", "stderr": tail}
    rc = 3
else:
    rc = erc if erc in (0, 97, 143) else 3
rec.update(main=short, hq=hqshort, pull=pull, hqpull=hqpull, slots=int(slots), budget_s=int(budget), engine_rc=erc, secs_item=int(secs))
if rec["result"] == "sem-novidade" and erc == 0:
    # tmp + troca; falhar aqui só repete uma rodada na seguinte, mas fica dito no resumo
    try:
        with open(idle_p + ".tmp", "w", encoding="utf-8") as f:
            f.write(key + "\n")
        os.replace(idle_p + ".tmp", idle_p)
    except OSError as e:
        rec["idle"] = "nao-gravado:" + type(e).__name__
print("BALLAST-SUMMARY: " + json.dumps(rec), flush=True)
sys.exit(rc)
PY
prc=$?
# rc 1 não é do motor nem do passo acima (que só sai com 0/97/143/3): o interpretador morreu antes de imprimir e este é o ÚNICO resumo da rodada
if [ "$prc" -eq 1 ]; then summary resumo-falhou main="${tested:0:9}" hq="${hqmain:0:9}" pull="$pull" hqpull="$hqpull" python_rc="$prc" engine_rc="$erc"; say "o passo do resumo morreu (rc $prc)"; exit 3; fi
exit "$prc"
