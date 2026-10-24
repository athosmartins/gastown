#!/bin/bash
# wa-suite.sh — item `work` do lastro do nó Hetzner (ga-2hd02v.8): a suíte INTEIRA do WhatsApp Automation contra o origin/main do espelho do NÓ, dentro do isolamento de rede provado, e resume.
# Roda NO nó, sob o governo (hetzner-ballast.py). É a bateria noturna (hetzner-nightly-tests.sh) repetida a cada merge no main, com os mesmos argumentos do pytest e as mesmas regras de leitura.
#
# Contents
#   O que faz · O root no meio · Veredito · Três estados · Gravação do estado · Pausa e fome de CPU · Limites
#
# O QUE FAZ: (1) `hetzner-remote-git.sh pull whatsapp_automation` (falhou = segue com o clone que há e diz pull=falhou: código velho não é código errado) (2) ponta do main = a da última rodada que o item
#   deu por feita → "sem-novidade" (só com o pull que respondeu; com o pull falho é `pull-falhou`, exit 3: a ponta velha não prova que não há novidade) (3) canário de rede (`gt-iso-run --canary`) ANTES de baixar qualquer coisa (4) `wt-add` numa árvore só dele (ballast-wa; a árvore e a branch worker/ballast-wa saem
#   no fim e no TERM) (5) `gt-iso-run -- venv-wa/bin/python -m pytest tests/ -n $BALLAST_CORES -p gtn_stable_ids ...` (6) uma linha `BALLAST-SUMMARY: {json}`.
# O ROOT NO MEIO: o pytest roda sob `sudo -n gt-netns-run` (root, para cortar a rede). Medido no nó em 24/10, com o lançamento do próprio governo: o sudo NÃO abre sessão nova, então a sessão do item (a que o
#   governo varre) contém tudo; nice 19, SCHED_IDLE e oom_score_adj 1000 atravessam o sudo; a CARGA (pytest e workers) roda com o uid do `runner`, então o governo a pausa, retoma e mata com os sinais de sempre.
#   O único processo que o `runner` não sinaliza é o bash do helper, parado em `wait`: sai sozinho quando o filho sai e leva junto o que sobrou no netns. Nada aqui pede sudoers novo.
# VEREDITO (`result` no resumo): completo · sem-novidade · isolamento-inerte (canário `inerte`: o helper de root faltou ou não respondeu; NADA rodou) · vazamento (canário `nao-isolado`: a sonda SAIU pela
#   rede; nada rodou e o item se tranca com $BH/wa-suite.leak até um humano apagar o arquivo — o registro tem `noflag:wa-suite.leak`) · sem-prova-de-isolamento (a suíte rodou mas faltou a linha de prova: o
#   resultado é descartado) · pytest-abortou (rc fora de 0/1) · sem-resumo · total-implausivel (< WA_SUITE_MIN_TOTAL) · sem-main · wt-add-falhou · arvore-sem-testes · preparo-ausente · gravacao-falhou ·
#   resumo-falhou · saida-ilegivel (a saída do pytest não abriu) · pull-falhou (o pull falhou e a ponta é a da última rodada: não sei se há novidade) · arvore-velha (o wt-rm não tirou a árvore da rodada que morreu). Teste que reprova é DADO, não falha do item (rc 0). "Novas falhas" = reprovadas que não estavam na última rodada COMPLETA com lista confiável.
# TRÊS ESTADOS: a lista de ids vem do plugin gtn_stable_ids (`GTN-FAIL:` por id e `GTN-FAILED: n= reports=`), conferida como na bateria noturna (uma linha GTN-FAILED, JSON em toda GTN-FAIL, n = ids lidos,
#   reports = falhas + erros do resumo do pytest). Lista ausente/parcial/ilegível, linha de base ilegível ou rodada suspeita (abaixo) = compare "indisponivel": o resumo diz por quê, a linha de base NÃO anda,
#   e nunca sai "0 novas" por falta de leitura. Sem linha de base (1ª rodada) = compare "primeira": as falhas do nó viram a base (há falhas que são do ambiente do nó; o sinal é "novas" a partir da 2ª).
# GRAVAÇÃO DO ESTADO (lista de reprovadas e ponta): só depois da rodada COMPLETAR, em dois tempos, como o hq-selftests: tudo vai para .tmp, o resumo sai, os arquivos são trocados e a ponta POR ÚLTIMO (é ela
#   que dá a rodada por feita). Falhou ao gravar → exit 3 com resumo `gravacao-falhou`, nada trocado, a próxima rodada refaz. A ponta anda numa rodada COMPLETA mesmo com a lista não confiável (repetir 3 h
#   de suíte na mesma ponta não consertaria um plugin quebrado); a LISTA só anda quando confiável.
# PAUSA E FOME DE CPU: SIGSTOP (RAM baixa) congela também o relógio de prazo dos testes (pytest-timeout é tempo de parede): o teste em curso estoura ao retomar e vira falha "nova" que não é. Um laço dentro
#   do item (membro da mesma sessão, então também congela) mede o salto do relógio entre dois sleeps; salto >= 60 s = `frozen_s` e a comparação fica indisponível (laço morto = relógio desconhecido, a mesma resposta). Por isso o prazo por teste é 900 s (WA_SUITE_TEST_TIMEOUT),
#   o triplo da noturna: em nice 19 + SCHED_IDLE, uma sessão do dia pode tirar a CPU do lastro por minutos (inferido, não medido).
# LIMITES: roda como `runner`, sem rede de saída garantida e sem dado de lead (a árvore vem do espelho filtrado, o mesmo filtro do worker do nó); teste que se solta da sessão (setsid) escapa do governo, mas
#   o helper mata o netns inteiro quando o pytest sai; o prazo do registro (`timeout`) mata o item com a rodada incompleta (sem resumo de suíte: o governo registra `prazo`).
set -u
BH=${BALLAST_HOME:?BALLAST_HOME}; RD=${BALLAST_RUN_DIR:?BALLAST_RUN_DIR}; CORES=${BALLAST_CORES:-2}
case "$CORES" in ''|*[!0-9]*|0) CORES=2 ;; esac
RG=${BALLAST_REMOTE_GIT:-$HOME/gt-remote/bin/hetzner-remote-git.sh}
GR=${GT_REMOTE_GIT:-$HOME/gt-remote/git}; RIG=${BALLAST_WA_RIG:-whatsapp_automation}
ISO=${BALLAST_ISO_RUN:-$HOME/gt-remote/bin/gt-iso-run}
PYV=${BALLAST_WA_PYTHON:-$HOME/gt-remote/venv-wa/bin/python}
PLUG=${BALLAST_WA_PLUGIN:-$HOME/gt-remote/bin/gtn_stable_ids.py}
PERTEST=${WA_SUITE_TEST_TIMEOUT:-900}; case "$PERTEST" in ''|*[!0-9]*|0) PERTEST=900 ;; esac
MIN_TOTAL=${WA_SUITE_MIN_TOTAL:-1000}; case "$MIN_TOTAL" in ''|*[!0-9]*|0) MIN_TOTAL=1000 ;; esac
WATCHS=${WA_SUITE_WATCH_S:-5}; case "$WATCHS" in ''|*[!0-9]*|0) WATCHS=5 ;; esac   # intervalo do laço de relógio (o selftest o encurta)
LAST="$BH/wa-suite.last"; PREV="$BH/wa-suite.failed"; LEAK="$BH/wa-suite.leak"
export PATH="$HOME/.local/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 GIT_AUTHOR_NAME=gt GIT_AUTHOR_EMAIL=gt@no GIT_COMMITTER_NAME=gt GIT_COMMITTER_EMAIL=gt@no
bead=""; PYPID=""; WATCH=""; t0=$(date +%s)
say() { echo "wa-suite: $*" >&2; }
summary() {  # summary RESULTADO [chave=valor …] — a linha BALLAST-SUMMARY dos desfechos que não rodaram a suíte
  python3 -I -c 'import sys, json
d = {"result": sys.argv[1]}
for kv in sys.argv[2:]:
    k, _, v = kv.partition("=")
    d[k] = v if k in ("main", "pull", "iso") else (int(v) if v.isdigit() else v)
print("BALLAST-SUMMARY: " + json.dumps(d))' "$@"
}
# O wt-add cria a branch worker/<nome> no clone do nó e o wt-rm só tira a ÁRVORE: nome fixo, a branch velha sai ANTES do wt-add (senão ele a reusaria, na ponta velha) e de novo no fim (como o hq-selftests).
branch_rm() { git -C "$GR/$RIG/repo.git" branch -D "worker/$bead" > /dev/null 2>&1; }
stop_watch() { [ -z "$WATCH" ] || { pkill -P "$WATCH" 2> /dev/null; kill "$WATCH" 2> /dev/null; }; WATCH=""; }   # o filho (sleep) primeiro: o laço morto não deixa um `sleep 5` órfão
cleanup() { stop_watch; cd "$BH" 2> /dev/null || cd /; [ -z "$bead" ] || { "$RG" wt-rm "$RIG" "$bead" > /dev/null 2>&1; branch_rm; }; }
trap cleanup EXIT
# TERM/INT (o governo, o prazo ou o stop): repassa ao pytest e espera até 10 s ele sair (o governo manda TERM a cada membro da sessão e o KILL vem 20 s depois), depois sai 143 → cleanup
on_term() {
  [ -z "$PYPID" ] || kill -TERM "$PYPID" 2> /dev/null
  # vazio (TERM antes do pytest nascer: pull, canário, wt-add) → nada a esperar, sai já; falhou (o pytest já morreu) → sai já; vivo → espera
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -n "$PYPID" ] && kill -0 "$PYPID" 2> /dev/null || break; sleep 1; done
  exit 143
}
trap on_term TERM INT

pull=ok
timeout 300 "$RG" pull "$RIG" > /dev/null 2>&1 || pull=falhou
# vazio/falhou (sem a ref origin/main) → sem-main e exit 3; nunca "sem novidade"
main=$(git -C "$GR/$RIG/repo.git" rev-parse -q --verify refs/remotes/origin/main 2> /dev/null) || main=""
[ -n "$main" ] || { say "o clone não tem origin/main"; summary sem-main pull=$pull; exit 3; }
# vazio (nunca houve rodada completa) → roda; falhou/ilegível (arquivo que não abre) → roda também: pior caso é repetir uma rodada, nunca pular uma
if [ "$main" = "$(cat "$LAST" 2> /dev/null)" ]; then
  # o pull que falhou deixa a ponta velha: "sem novidade" só vale com o pull que respondeu; um pull que falha para sempre não pode parecer uma fila parada
  [ "$pull" = ok ] || { say "o pull falhou e a ponta é a da última rodada: não sei se há novidade"; summary pull-falhou main="${main:0:9}" pull=$pull; exit 3; }
  summary sem-novidade main="${main:0:9}" pull=$pull; exit 0
fi
# o registro já exige estes (requires:), mas o item confere de novo: a falta de um deles é "não rodou", nunca "rodou sem"
for need in "$ISO" "$PYV"; do
  [ -x "$need" ] || { say "falta $need"; summary preparo-ausente main="${main:0:9}" pull=$pull falta="$(basename "$need")"; exit 3; }
done
[ -f "$PLUG" ] || { say "falta o plugin $PLUG (hetzner-ballast.sh install o leva)"; summary preparo-ausente main="${main:0:9}" pull=$pull falta=gtn_stable_ids.py; exit 3; }

# canário ANTES de baixar a árvore. `isolado` segue; `nao-isolado` é vazamento MEDIDO (tranca o item); qualquer outra coisa (`inerte`, vazio, ilegível) é "nada rodou"
# vazio (nenhuma linha GTN-ISO) → trata como inerte; falhou/ilegível (o canário caiu) → também inerte: o lado que NÃO roda a suíte
canary=$("$ISO" --canary 2> /dev/null | grep '^GTN-ISO: ' | head -n 1 | cut -c1-200)
case "$canary" in
  "GTN-ISO: isolado"*) ;;
  "GTN-ISO: nao-isolado"*) lock=ok; { : > "$LEAK"; } 2> /dev/null || lock=falhou   # falhou (não gravou a trava) → o resumo diz trava=falhou: o item NÃO ficou trancado
                           say "VAZAMENTO MEDIDO: $canary — trava: $lock ($LEAK)"; summary vazamento main="${main:0:9}" pull=$pull iso="${canary#GTN-ISO: }" trava=$lock; exit 3 ;;
  *) say "isolamento não provado (${canary:-sem linha GTN-ISO})"; summary isolamento-inerte main="${main:0:9}" pull=$pull iso="${canary#GTN-ISO: }"; exit 3 ;;
esac

bead="ballast-wa"
[ ! -e "$GR/$RIG/wt/$bead" ] || "$RG" wt-rm "$RIG" "$bead" > /dev/null 2>&1   # sobra de uma rodada que morreu sem limpar
# vazio (a pasta saiu) → segue; falhou (o wt-rm não a tirou) → o wt-add diria "já existe" e a rodada testaria a árvore de outro dia: não rodo
[ ! -e "$GR/$RIG/wt/$bead" ] || { say "a árvore velha não saiu ($GR/$RIG/wt/$bead)"; summary arvore-velha main="${main:0:9}" pull=$pull; exit 3; }
branch_rm
if ! timeout 900 "$RG" wt-add "$RIG" "$bead" main > "$RD/wt-add.out" 2>&1; then
  say "wt-add falhou: $(tail -n 1 "$RD/wt-add.out")"; summary wt-add-falhou main="${main:0:9}" pull=$pull; exit 3
fi
WT="$GR/$RIG/wt/$bead"
[ -d "$WT/tests" ] || { say "a árvore não tem tests/"; summary arvore-sem-testes main="${main:0:9}" pull=$pull; exit 3; }
# vazio/falhou (sem HEAD legível) → usa a ponta lida antes (a mesma, salvo corrida entre o pull e o wt-add)
tested=$(git -C "$WT" rev-parse HEAD 2> /dev/null) || tested=$main

cd "$WT" || { say "não entrei em $WT"; summary arvore-sem-testes main="${main:0:9}" pull=$pull; exit 3; }
mkdir -p logs
# GTN_WORKERS: o gt-iso-run o põe em WA_PYTEST_MAX_WORKERS (sem ele o conftest do WA limita o xdist a 2 workers). Os argumentos são os da noturna; -p no:cacheprovider como no mbp-run.
GTN_WORKERS="$CORES" "$ISO" -- "$PYV" -m pytest -p no:cacheprovider tests/ -n "$CORES" -p gtn_stable_ids --timeout="$PERTEST" -q -rfE --tb=line --continue-on-collection-errors \
  > "$RD/pytest.out" 2>&1 < /dev/null &
PYPID=$!
# salto do relógio: dois `sleep` seguidos (5 s) que distam muito mais que isso = a sessão ficou congelada (SIGSTOP) ou sem CPU. Grava o MAIOR salto, em segundos além do intervalo esperado.
( prev=$(date +%s); max=0
  while sleep "$WATCHS"; do
    now=$(date +%s); gap=$(( now - prev - WATCHS )); prev=$now
    [ "$gap" -le "$max" ] || { max=$gap; echo "$max" > "$RD/frozen.tmp" && mv -f "$RD/frozen.tmp" "$RD/frozen"; }
  done ) > /dev/null 2>&1 &
WATCH=$!
wait "$PYPID"; prc=$?
# vazio (laço vivo e sem salto: o arquivo nem existe) → sem salto; falhou (laço morto: ninguém vigiou o relógio) → NÃO sei se a sessão congelou: frozen=-1 e a comparação fica indisponível (ausente leria como "sem salto")
kill -0 "$WATCH" 2> /dev/null || echo -1 > "$RD/frozen"
stop_watch; PYPID=""

python3 -I - "$RD/pytest.out" "$prc" "$PREV" "$LAST" "$RD/frozen" "${tested:0:9}" "$tested" "$pull" "$(( $(date +%s) - t0 ))" "$CORES" "$MIN_TOTAL" "$LEAK" << 'PY'
import json, os, re, sys
out_p, prc, prev_p, last_p, frozen_p, short, full, pull, secs_total, workers, min_total, leak_p = sys.argv[1:13]
prc, min_total = int(prc), int(min_total)
d = {"result": None, "main": short, "pull": pull, "workers": int(workers), "rc": prc, "secs_total": int(secs_total)}

def done(result, code, **kw):
    d["result"] = result
    d.update(kw)
    print("BALLAST-SUMMARY: " + json.dumps(d), flush=True)
    sys.exit(code)

# vazio (saída vazia) → cai nos desfechos abaixo (sem prova, sem resumo); falhou/ilegível (não abre) → saida-ilegivel, nada é inventado
try:
    with open(out_p, "r", encoding="utf-8", errors="replace") as f:
        text = f.read()
except OSError as e:
    done("saida-ilegivel", 3, erro=str(e)[:120])
lines = text.splitlines()
# vazio (nenhuma linha GTN-ISO) → "" e a rodada não tem prova; a PRIMEIRA linha é a do canário do gt-iso-run, a que vale (a do helper vem depois: `ok ns=...`)
iso = next((l[len("GTN-ISO: "):] for l in lines if l.startswith("GTN-ISO: ")), "")
d["iso"] = iso.split(" (")[0][:40]
if iso.startswith("nao-isolado"):
    try:
        open(leak_p, "w").close()
        lock = "ok"
    except OSError:
        lock = "falhou"   # não gravou a trava: o resumo diz, o item NÃO ficou trancado
    done("vazamento", 3, iso=iso[:160], trava=lock)
if prc == 97 and not iso.startswith("isolado"):
    done("isolamento-inerte", 3, iso=iso[:160])
ok_line = any(l.startswith("GTN-ISO: ok ns=") for l in lines)
eg = next((l[len("GTN-EGRESS: attempts="):] for l in reversed(lines) if l.startswith("GTN-EGRESS: attempts=")), "")
d["egress"] = eg if eg.isdigit() else "?"
if not (iso.startswith("isolado") and ok_line and eg != ""):
    done("sem-prova-de-isolamento", 3, iso=iso[:160])
if prc not in (0, 1):
    done("pytest-abortou", 3, tail=" | ".join(l for l in lines if l.strip())[-160:])
sm = next((l for l in reversed(lines) if re.match(r"^(=+ )?([0-9]+ [a-z]+.*|no tests ran) in [0-9.]+s", l)), None)
if sm is None:
    done("sem-resumo", 3, tail=" | ".join(l for l in lines if l.strip())[-160:])
def cnt(word):
    m = re.search(r"(\d+) " + word + r"\b", sm)
    return int(m.group(1)) if m else 0   # vazio (a categoria não aparece) → 0: o pytest omite o que é zero
passed, failed, errors, skipped, xf, xp = cnt("passed"), cnt("failed"), cnt("errors?"), cnt("skipped"), cnt("xfailed"), cnt("xpassed")
total = passed + failed + errors + skipped + xf + xp
m = re.search(r" in ([0-9]+)\.[0-9]+s", sm)
d.update(total=total, passed=passed, failed=failed, errors=errors, skipped=skipped, secs=int(m.group(1)) if m else None)
if total < min_total:
    done("total-implausivel", 3, resumo=sm[:120])

sent = [l[len("GTN-FAILED: "):] for l in lines if l.startswith("GTN-FAILED: ")]
fl = sorted({l[len("GTN-FAIL: "):] for l in lines if l.startswith("GTN-FAIL: ")})
listok, why, ids = False, "", []
if not sent:
    why = "o pytest não imprimiu a linha GTN-FAILED (o plugin não rodou ou falhou ao montar a lista)"
elif len(sent) > 1:
    why = "a linha GTN-FAILED aparece %d vezes" % len(sent)
else:
    mm = re.fullmatch(r"n=(\d+) reports=(\d+)", sent[0])
    if not mm:
        why = "a linha GTN-FAILED está ilegível"
    else:
        try:
            ids = sorted({json.loads(x) for x in fl})
            if not all(isinstance(x, str) for x in ids):
                raise ValueError("id que não é texto")
        except (ValueError, TypeError):
            ids, why = [], "há linha GTN-FAIL que não é um id em JSON"
        else:
            if len(ids) != int(mm.group(1)):
                why = "o plugin diz %s ids e %d foram lidos (lista parcial)" % (mm.group(1), len(ids))
            elif int(mm.group(2)) != failed + errors:
                why = "o plugin contou %s falhas/erros e o resumo do pytest diz %d" % (mm.group(2), failed + errors)
            else:
                listok = True
# vazio (sem o arquivo: o salto nunca passou de 0) → 0; falhou/ilegível (existe e não é inteiro) → desconhecido, conta como suspeita
frozen = 0
if os.path.exists(frozen_p):
    try:
        with open(frozen_p, "r", encoding="ascii") as f:
            frozen = int(f.read().strip())
    except (OSError, ValueError):
        frozen = -1
d["frozen_s"] = frozen if frozen >= 0 else None
d["timeout_n"] = sum(1 for l in lines if re.match(r"^(FAILED|ERROR) ", l) and re.search(r"Timeout \(?>[0-9.]+s", l))
d["crash_n"] = sum(1 for l in lines if re.search(r"worker '[^']*' crashed", l))

compare, new, fixed = "indisponivel", [], 0
if not listok:
    pass
elif frozen < 0 or frozen >= 60:
    why = "a sessão ficou %s s parada/sem CPU (pausa por RAM ou fome de CPU): teste em curso pode ter estourado o prazo de parede" % ("?" if frozen < 0 else frozen)
elif not os.path.exists(prev_p):
    compare = "primeira"
else:
    # vazio (arquivo vazio) → a última rodada completa não teve falha, toda falha de hoje é nova; falhou/ilegível (não abre ou linha que não é JSON) → indisponível, NUNCA "0 novas"
    try:
        with open(prev_p, "r", encoding="utf-8") as f:
            rows = [json.loads(l) for l in f if l.strip()]
        if not all(isinstance(x, str) for x in rows):   # antes do set(): lista ou objeto JSON não é hashable (TypeError) e derrubaria o passo
            raise ValueError("linha que não é texto")
        prev = set(rows)
        new = sorted(set(ids) - prev)
        fixed = len(prev - set(ids))
        compare = "ok"
    except (OSError, ValueError, UnicodeDecodeError):
        why = "a linha de base %s não pôde ser lida como lista de ids em JSON" % os.path.basename(prev_p)
d["compare"] = compare
d["fail_n"] = len(ids) if listok else None
d["new_fail_n"] = len(new) if compare == "ok" else None
d["new_fail"] = [x[:150] for x in new[:15]]
d["fixed_n"] = fixed if compare == "ok" else None
if compare == "indisponivel":
    d["why"] = why[:150]

def stage(path, text):
    # falhou (OSError) → levanta: nada foi trocado ainda e o chamador sai com 3; um alvo que é PASTA falha aqui, não só na troca (que viria depois do resumo)
    if os.path.isdir(path):
        raise IsADirectoryError("%s é uma pasta" % path)
    with open(path + ".tmp", "w", encoding="utf-8") as f:
        f.write(text)
    return (path + ".tmp", path)
staged, err = [], ""
try:
    if compare in ("ok", "primeira"):
        staged.append(stage(prev_p, "".join(json.dumps(x, ensure_ascii=True) + "\n" for x in ids)))
    staged.append(stage(last_p, full + "\n"))   # a ponta é a última da fila: é ela que dá a rodada por feita
except OSError as e:
    err = "%s: %s" % (type(e).__name__, e)
    for _p in (prev_p, last_p):
        try:
            os.remove(_p + ".tmp")
        except OSError:
            pass   # sobra de .tmp é inofensiva: o próximo stage() o reescreve
if err:
    done("gravacao-falhou", 3, erro=err[:160])
d["result"] = "completo"
print("BALLAST-SUMMARY: " + json.dumps(d), flush=True)
try:
    for tmp, dst in staged:
        os.replace(tmp, dst)
except OSError as e:
    print("wa-suite: a troca do estado falhou (%s): a ponta é a última, a rodada não conta como feita" % e, file=sys.stderr)
    sys.exit(3)
PY
prc=$?
[ "$prc" -ne 0 ] || exit 0
# rc 3: o passo já imprimiu o resumo (um dos desfechos acima) e disse o motivo; outro rc: o interpretador morreu antes de imprimir e este é o ÚNICO resumo da rodada
[ "$prc" -eq 3 ] || summary resumo-falhou main="${tested:0:9}" pull="$pull" python_rc="$prc"
say "a rodada não gerou um resultado gravado (rc $prc): a próxima refaz"
exit 3
