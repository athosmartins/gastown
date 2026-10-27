#!/bin/bash
# hq-mutants.sh — item `work` do lastro do nó Hetzner (ga-2hd02v.5.6): varre MUTANTES dos *.selftest.sh do hq no origin/main do espelho do NÓ e resume o que SOBREVIVEU (selftest que não nota uma quebra
# do código que ele cobre). Roda NO nó, sob o governo (hetzner-ballast.py). O trabalho é do motor scripts/hq-mutate.py (5.6.2) dentro da jaula scripts/hq-sandbox-run.py (5.6.1), os DOIS da própria árvore testada.
#
# Contents
#   O que faz · Veredito · Três estados · Limites
#
# O QUE FAZ: (1) `hetzner-remote-git.sh pull` (falhou = segue com o clone que há e diz pull=falhou) (2) se o motor já deu o main atual por SEM novidade, há menos de 6 h, sai com "sem-novidade" sem criar árvore
#   (3) `wt-add` numa árvore só dele (ballast-hqm, e a branch worker/ballast-hqm: as duas saem no fim e também no TERM; o nome difere do ballast-hq do hq-selftests, que pode rodar ao lado) (4) roda
#   `hq-mutate.py sweep` com o estado em $BALLAST_HOME/hq-mutants.state.json (o rodízio continua de onde parou: a rodada que acaba no prazo sai `parcial` e a seguinte pega o resto) (5) resumo numa linha
#   `BALLAST-SUMMARY: {json}`: a linha do motor (contagens e NOMES de arquivo/linha dos sobreviventes confirmados, no máximo 15) mais main, pull, slots e engine_rc. Quem lê o sobrevivente é o 5.6.4 (um bead).
# VEREDITO: o rc do motor passa adiante (0 rodou: completo, parcial, sem-novidade ou sem-cobertura (nada examinado: só ilegível/perdido/vermelho; não grava o marcador) · 97 sem jaula: o kernel não provou o Landlock, nada rodou · 143 interrompido). Mutante que sobrevive é dado, não falha do item.
# TRÊS ESTADOS: sem origin/main (sem-main), árvore sem scripts/ (arvore-sem-scripts), sem o motor ou a jaula na árvore (sem-motor: o main ainda não os tem), wt-add que falha, o motor que morre sem imprimir o
#   resumo (motor-sem-resumo), o estado que o motor não lê (estado-ilegivel, do motor: nunca é zerado) → exit 3 e nada de "sem novidade" gravado. O marcador de ocioso só é escrito quando o motor DISSE
#   sem-novidade com rc 0; ilegível/ausente/velho → roda a rodada (pior caso é repetir uma, nunca pular uma).
# LIMITES: roda no nó como `runner`; o motor só escreve no --work ($BALLAST_RUN_DIR/work) e no estado; cada mutante roda numa cópia da árvore (~63 MB) na jaula (escrita só no slot e no máximo 512 MB por arquivo, TCP cortado, provada pelo
#   pai antes de qualquer mutante); selftest que cita gc/bd/dolt de verdade, sudo, tmux, launchctl, pkill… fica FORA (denylist do motor, contada em `skipped`). Nenhum dado sai do nó além deste resumo.
set -u
BH=${BALLAST_HOME:?BALLAST_HOME}; RD=${BALLAST_RUN_DIR:?BALLAST_RUN_DIR}; CORES=${BALLAST_CORES:-2}
case "$CORES" in ''|*[!0-9]*|0) CORES=2 ;; esac
SLOTS=${HQ_MUTANTS_SLOTS:-$((CORES * 2))}   # 2 mutantes por núcleo reservado: o selftest de shell vive de fork e espera e mede ~0,43 núcleo real por núcleo reservado (ga-2hd02v.5.6, 27/10)
case "$SLOTS" in ''|*[!0-9]*|0) SLOTS=$((CORES * 2)) ;; esac
[ "$SLOTS" -le 16 ] || SLOTS=16
BUDGET=${HQ_MUTANTS_BUDGET_S:-1800}   # o prazo da linha do registro tem de passar disto em >= 1000 s: um mutante em voo leva até 900 s + 30 (o motor só olha o relógio entre mutantes)
case "$BUDGET" in ''|*[!0-9]*) BUDGET=1800 ;; esac
[ "$BUDGET" -ge 60 ] || BUDGET=60
RG=${BALLAST_REMOTE_GIT:-$HOME/gt-remote/bin/hetzner-remote-git.sh}
GR=${GT_REMOTE_GIT:-$HOME/gt-remote/git}; RIG=${BALLAST_HQ_RIG:-gascity}
STATE="$BH/hq-mutants.state.json"; IDLE="$BH/hq-mutants.idle"
export PATH="$HOME/.local/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 GIT_AUTHOR_NAME=gt GIT_AUTHOR_EMAIL=gt@no GIT_COMMITTER_NAME=gt GIT_COMMITTER_EMAIL=gt@no
bead=""; ep=""
say() { echo "hq-mutants: $*" >&2; }
summary() {  # summary RESULTADO [chave=valor …] — a linha BALLAST-SUMMARY dos desfechos que não chegaram a rodar o motor
  python3 -I -c 'import sys, json
d = {"result": sys.argv[1]}
for kv in sys.argv[2:]:
    k, _, v = kv.partition("=")
    d[k] = v if k in ("main", "pull") else (int(v) if v.isdigit() else v)
print("BALLAST-SUMMARY: " + json.dumps(d))' "$@"
}
# o wt-rm só tira a ÁRVORE, não a branch worker/<nome>: nome fixo, a velha sai ANTES do wt-add (senão ele a reusaria, na ponta velha) e de novo no fim (a mesma conta do hq-selftests.sh)
branch_rm() { git -C "$GR/$RIG/repo.git" branch -D "worker/$bead" > /dev/null 2>&1; }
cleanup() { [ -z "$bead" ] || { "$RG" wt-rm "$RIG" "$bead" > /dev/null 2>&1; branch_rm; }; }
trap cleanup EXIT
# o TERM do governo vai ao GRUPO inteiro (o motor também o recebe); este trap só espera o motor acabar de matar os mutantes ANTES de a árvore sair, e pára o motor se o TERM veio só para cá
trap '[ -z "$ep" ] || { kill -TERM "$ep" 2>/dev/null; wait "$ep" 2>/dev/null; }; exit 143' TERM INT

pull=ok
timeout 300 "$RG" pull "$RIG" > /dev/null 2>&1 || pull=falhou
# vazio/falhou (sem a ref origin/main) → sem-main e exit 3; nunca "sem novidade"
main=$(git -C "$GR/$RIG/repo.git" rev-parse -q --verify refs/remotes/origin/main 2> /dev/null) || main=""
[ -n "$main" ] || { say "o clone não tem origin/main"; summary sem-main pull=$pull; exit 3; }
# marcador = a ponta que o motor deu por sem-novidade, de menos de 6 h (um alvo pulado por base-vermelha volta a rodar passados 2 dias; sem este prazo ele só voltaria com um commit novo); vazio/ilegível → roda
if [ "$main" = "$(cat "$IDLE" 2> /dev/null)" ] && [ -n "$(find "$IDLE" -mmin -360 2> /dev/null)" ]; then summary sem-novidade main="${main:0:9}" pull=$pull; exit 0; fi

bead="ballast-hqm"
[ ! -e "$GR/$RIG/wt/$bead" ] || "$RG" wt-rm "$RIG" "$bead" > /dev/null 2>&1   # sobra de uma rodada que morreu sem limpar
branch_rm
if ! timeout 900 "$RG" wt-add "$RIG" "$bead" main > "$RD/wt-add.out" 2>&1; then
  say "wt-add falhou: $(tail -n 1 "$RD/wt-add.out")"; summary wt-add-falhou main="${main:0:9}" pull=$pull; exit 3
fi
WT="$GR/$RIG/wt/$bead"; TREE="$WT/.gascity-gastown-hq"
[ -d "$TREE/scripts" ] || { say "a árvore não tem scripts/"; summary arvore-sem-scripts main="${main:0:9}" pull=$pull; exit 3; }
ENG="$TREE/scripts/hq-mutate.py"; JAIL="$TREE/scripts/hq-sandbox-run.py"
[ -f "$ENG" ] && [ -f "$JAIL" ] || { say "o main não tem o motor ou a jaula (hq-mutate.py, hq-sandbox-run.py)"; summary sem-motor main="${main:0:9}" pull=$pull; exit 3; }
# vazio/falhou (sem HEAD legível) → usa a ponta lida antes (a mesma, salvo corrida entre o pull e o wt-add)
tested=$(git -C "$WT" rev-parse HEAD 2> /dev/null) || tested=$main
mkdir -p "$RD/work" || { say "não criei $RD/work"; summary sem-work main="${tested:0:9}" pull=$pull; exit 3; }

t0=$(date +%s)
python3 -I "$ENG" sweep --tree "$TREE" --state "$STATE" --work "$RD/work" --jail "$JAIL" --slots "$SLOTS" --budget-s "$BUDGET" > "$RD/engine.out" 2> "$RD/engine.err" < /dev/null &
ep=$!
wait "$ep"; erc=$?; ep=""

# a ÚLTIMA linha JSON do motor com "result" vira o resumo (o motor já a limita a 6000 caracteres; o puxador do governo troca por null o que passa de ~8000). Sem ela o item NÃO fica mudo: motor-sem-resumo, exit 3.
python3 -I - "$RD/engine.out" "$RD/engine.err" "$erc" "${tested:0:9}" "$pull" "$SLOTS" "$BUDGET" "$IDLE" "$tested" "$(( $(date +%s) - t0 ))" << 'PY'
import json, os, sys
out_p, err_p, erc, short, pull, slots, budget, idle_p, full, secs = sys.argv[1:11]
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
rec.update(main=short, pull=pull, slots=int(slots), budget_s=int(budget), engine_rc=erc, secs_item=int(secs))
if rec["result"] == "sem-novidade" and erc == 0:
    # tmp + troca; falhar aqui só repete uma rodada na seguinte, mas fica dito no resumo
    try:
        with open(idle_p + ".tmp", "w", encoding="utf-8") as f:
            f.write(full + "\n")
        os.replace(idle_p + ".tmp", idle_p)
    except OSError as e:
        rec["idle"] = "nao-gravado:" + type(e).__name__
print("BALLAST-SUMMARY: " + json.dumps(rec), flush=True)
sys.exit(rc)
PY
prc=$?
# rc 1 não é do motor nem do passo acima (que só sai com 0/97/143/3): o interpretador morreu antes de imprimir e este é o ÚNICO resumo da rodada
if [ "$prc" -eq 1 ]; then summary resumo-falhou main="${tested:0:9}" pull="$pull" python_rc="$prc" engine_rc="$erc"; say "o passo do resumo morreu (rc $prc)"; exit 3; fi
exit "$prc"
