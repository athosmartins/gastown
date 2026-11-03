#!/bin/bash
# hq-selftests.sh — item `work` do lastro do nó Hetzner (ga-2hd02v.5): roda os *.selftest.sh do hq contra o origin/main do espelho do NÓ e resume. Roda NO nó, sob o governo (hetzner-ballast.py).
#
# Contents
#   O que faz · Veredito · Três estados · Gravação do estado · Limites
#
# O QUE FAZ: (1) `hetzner-remote-git.sh pull` (falhou = segue com o clone que há e diz pull=falhou: código velho não é código errado) (2) se a ponta do main é a da última rodada COMPLETA, sai com
#   "sem-novidade" (3) `wt-add` numa árvore só dele (ballast-hq, e a branch worker/ballast-hq: as duas saem no fim e também no TERM) (4) lista os *.selftest.sh, tira os da lista só-macOS que vem NA ÁRVORE
#   (scripts/hetzner-mac-only.hq.txt, a mesma do mbp-run.sh) (5) roda em paralelo ($BALLAST_CORES), cada um com prazo e no grupo de processos próprio (o que ainda estiver vivo nele 1 s depois do fim sai com KILL e vai para leaked/leak_names do resumo; ps que não abre = leaked null, nada morto), os mais lentos da rodada anterior primeiro (6) quem reprovou roda UMA vez
#   de novo, com menos paralelismo (CPU disputada reprova por prazo de teste; passou na 2ª = flaky, não reprovada) (7) resumo numa linha `BALLAST-SUMMARY: {json}`: contagens e NOMES de selftest.
# VEREDITO (por selftest, rc do `bash <x>.selftest.sh`): 0 passou · 97 ambiente (o espelho do nó não tem o que o teste quer: o mbp-run.sh chama de AMBIENTE) · 124/137 prazo (CPU disputada ou teste
#   preso: inconclusivo, NÃO conta como reprovado) · outro = reprovou. "Novas falhas" = reprovadas que não estavam na última rodada COMPLETA. Teste que reprova é dado, não falha do item.
# TRÊS ESTADOS: sem origin/main (sem-main), árvore sem scripts/ ou lista só-macOS ausente/ilegível/sem nenhum padrão (mac-only-ilegivel), wt-add que falha, rodada que não produziu o resultado de
#   todos os testes agendados (incompleto) → exit 3, nada gravado. Lista só-macOS ilegível NUNCA vira "rode tudo": os testes de macOS reprovariam por ambiente e o sinal viraria ruído.
# GRAVAÇÃO DO ESTADO (ponta, lista de reprovadas, durações): só depois de a rodada COMPLETAR, em dois tempos — (1) tudo vai para arquivos .tmp (disco cheio, pasta sem escrita ou um alvo que é pasta falham
#   AQUI, antes de qualquer troca); (2) o resumo sai; (3) os arquivos são trocados, a lista de reprovadas depois das durações e a ponta POR ÚLTIMO (é ela que dá a rodada por feita). Falhou em (1): exit 3 com o
#   resumo `gravacao-falhou`, nada trocado. O passo do resumo que morre sem imprimir: exit 3 com o resumo `resumo-falhou`. Nos dois a rodada NÃO conta como feita (a ponta é o último arquivo gravado) e a
#   próxima refaz e diz de novo as falhas novas: repetir um aviso é o lado seguro; nunca rc 0 sem resumo. Caso raro, só depois de todos os .tmp gravados: uma TROCA que falha (exit 3, sem o resumo de erro): o
#   resumo `completo` já saiu uma vez e a ponta, por ser a última, fica sem gravar — a rodada refaz, mas as falhas novas dessa rodada podem já estar na linha de base.
# ESCOPO DA REDE DOS ÓRFÃOS: pega quem fica no GRUPO do selftest (`set -m` dá o grupo; o que o selftest solta com setsid/nohup/`set -m` próprio vai para OUTRO grupo e não é visto). Esses continuam contando na sessão do item
#   e o teto de RSS do governo (hetzner-ballast.py) segue sendo a última barreira: o sintoma de um vazamento fora do grupo é why=rss de novo, e a sonda hetzner-ballast-hq-selftests-mem-probe.py mostra de quem é.
# LIMITES: roda no nó como `runner`, sem rede de saída garantida (os selftests do hq são herméticos com stubs; é o mesmo ambiente do gate via mbp-run.sh --repo hq); a lista só-macOS APRENDIDA pela
#   sombra mora no mini e não chega aqui (alguns reprovados por ambiente podem aparecer); nenhum dado sai do nó além deste resumo (nomes de arquivo de código e contagens).
set -u
BH=${BALLAST_HOME:?BALLAST_HOME}; RD=${BALLAST_RUN_DIR:?BALLAST_RUN_DIR}; CORES=${BALLAST_CORES:-2}
case "$CORES" in ''|*[!0-9]*|0) CORES=2 ;; esac
RG=${BALLAST_REMOTE_GIT:-$HOME/gt-remote/bin/hetzner-remote-git.sh}
GR=${GT_REMOTE_GIT:-$HOME/gt-remote/git}; RIG=${BALLAST_HQ_RIG:-gascity}
PER=${HQ_SELFTEST_TIMEOUT:-1200}
LAST="$BH/hq-selftests.last"; PREV="$BH/hq-selftests.failed"; DUR="$BH/hq-selftests.durations"
export PATH="$HOME/.local/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 GIT_AUTHOR_NAME=gt GIT_AUTHOR_EMAIL=gt@no GIT_COMMITTER_NAME=gt GIT_COMMITTER_EMAIL=gt@no
bead=""; t0=$(date +%s)
say() { echo "hq-selftests: $*" >&2; }
summary() {  # summary RESULTADO [chave=valor …] — a linha BALLAST-SUMMARY dos desfechos que não rodaram a bateria
  python3 -I -c 'import sys, json
d = {"result": sys.argv[1]}
for kv in sys.argv[2:]:
    k, _, v = kv.partition("=")
    d[k] = v if k in ("main", "pull") else (int(v) if v.isdigit() else v)
print("BALLAST-SUMMARY: " + json.dumps(d))' "$@"
}
# O wt-add cria a branch worker/<nome> no clone do nó e o wt-rm só tira a ÁRVORE (não a branch): com um nome por ponta, o clone ganharia uma branch por merge no main e o `status`/`publish` do espelho
# varreria todas. Por isso o nome é fixo, a branch velha sai ANTES do wt-add (senão ele a reusaria, na ponta velha, e a rodada testaria código de outro dia) e sai de novo no fim.
branch_rm() { git -C "$GR/$RIG/repo.git" branch -D "worker/$bead" > /dev/null 2>&1; }
cleanup() { [ -z "$bead" ] || { "$RG" wt-rm "$RIG" "$bead" > /dev/null 2>&1; branch_rm; }; }
trap cleanup EXIT
trap 'exit 143' TERM INT

pull=ok
timeout 300 "$RG" pull "$RIG" > /dev/null 2>&1 || pull=falhou
# vazio/falhou (sem a ref origin/main) → sem-main e exit 3; nunca "sem novidade"
main=$(git -C "$GR/$RIG/repo.git" rev-parse -q --verify refs/remotes/origin/main 2> /dev/null) || main=""
[ -n "$main" ] || { say "o clone não tem origin/main"; summary sem-main pull=$pull; exit 3; }
# vazio (nunca houve rodada completa) → roda; falhou/ilegível (arquivo que não abre) → roda também: pior caso é repetir uma rodada, nunca pular uma
if [ "$main" = "$(cat "$LAST" 2> /dev/null)" ]; then summary sem-novidade main="${main:0:9}" pull=$pull; exit 0; fi

bead="ballast-hq"
[ ! -e "$GR/$RIG/wt/$bead" ] || "$RG" wt-rm "$RIG" "$bead" > /dev/null 2>&1   # sobra de uma rodada que morreu sem limpar
branch_rm
if ! timeout 900 "$RG" wt-add "$RIG" "$bead" main > "$RD/wt-add.out" 2>&1; then
  say "wt-add falhou: $(tail -n 1 "$RD/wt-add.out")"; summary wt-add-falhou main="${main:0:9}" pull=$pull; exit 3
fi
WT="$GR/$RIG/wt/$bead"; TREE="$WT/.gascity-gastown-hq"
[ -d "$TREE/scripts" ] || { say "a árvore não tem scripts/"; summary arvore-sem-scripts main="${main:0:9}" pull=$pull; exit 3; }
# vazio/falhou (sem HEAD legível) → usa a ponta lida antes (a mesma, salvo corrida entre o pull e o wt-add)
tested=$(git -C "$WT" rev-parse HEAD 2> /dev/null) || tested=$main
pats=$(grep -vE '^[[:space:]]*(#|$)' "$TREE/scripts/hetzner-mac-only.hq.txt" 2> /dev/null) || pats=""
[ -n "$pats" ] || { say "lista só-macOS ausente, ilegível ou sem padrão: não rodo (os testes de macOS viram ruído)"; summary mac-only-ilegivel main="${main:0:9}" pull=$pull; exit 3; }

find "$TREE" -name '*.selftest.sh' -not -path '*/.git/*' 2> /dev/null | sed "s|^$TREE/||" | sort > "$RD/all.txt"
: > "$RD/todo.txt"; skipped=0
while IFS= read -r rel; do
  skip=0
  while IFS= read -r pat; do
    pat=${pat#"${pat%%[![:space:]]*}"}; pat=${pat%"${pat##*[![:space:]]}"}   # aparada nas pontas, como o mbp-run.sh (mac_only_match): um espaço sobrando não pode deixar o teste de macOS rodar
    [ -n "$pat" ] || continue
    case "$rel" in $pat) skip=1; break ;; esac
  done <<< "$pats"
  if [ "$skip" = 1 ]; then skipped=$((skipped + 1)); else echo "$rel" >> "$RD/todo.txt"; fi
done < "$RD/all.txt"
total=$(wc -l < "$RD/todo.txt" | tr -d ' ')
[ "$total" -gt 0 ] || { say "nenhum selftest para rodar"; summary sem-testes main="${main:0:9}" pull=$pull; exit 3; }

# os mais lentos da rodada anterior primeiro (empacota melhor os núcleos); sem histórico, a ordem do find
python3 -I - "$RD/todo.txt" "$DUR" > "$RD/order.txt" << 'PY'
import sys
todo = [l.rstrip("\n") for l in open(sys.argv[1]) if l.strip()]
dur = {}
try:
    for l in open(sys.argv[2]):
        k, _, v = l.rstrip("\n").partition("\t")
        if v.isdigit():
            dur[k] = int(v)
except OSError:
    pass
for r in sorted(todo, key=lambda r: -dur.get(r, 10 ** 9)):
    print(r)
PY
cat > "$RD/run-one.sh" << 'EOS'
#!/bin/bash
# $1 = selftest (relativo à árvore); $2 = arquivo de resultados. Só guarda o log de quem não passou.
rel=$1; out=$2; name=$(printf '%s' "$rel" | tr '/' '_'); s=$(date +%s)
mkdir -p "$RD/out"
# `set -m`: o selftest roda no GRUPO DE PROCESSOS próprio (líder = $tp), seja qual for o `timeout` (o GNU faz setpgid sozinho; o de brinquedo e o do macOS não). Ao acabar, quem sobrou vivo nesse grupo
# (órfão com ppid 1 que um selftest deixa para trás) continuaria contando na SESSÃO do item até o fim da rodada: em 03/11 o hetzner-ballast-items.selftest.sh deixava ~3060 `sleep 300/900` assim, somavam
# 3863 MB de RSS (257 MB de PSS) e o governo matava a rodada com why=rss (ga-2hd02v.5.8). Aqui eles saem com KILL e o selftest que os deixou entra em leaks.tsv.
# members PGID → quantos processos vivem no grupo (0 = grupo vazio: nada a matar). vazio → 0; falhou/ilegível (ps com rc != 0, saída vazia — há sempre ao menos o próprio ps —, ou sem nenhuma linha numérica) →
# rc 1 e NADA impresso: o status do ps se perde num `ps | awk | wc -l` (o wc imprime número sempre), por isso a saída vai para uma variável antes de ser contada. "Não consegui ler" nunca vira 0.
members() { local o n; o=$(ps -axo pgid= 2> /dev/null) || return 1; [ -n "$o" ] || return 1
  n=$(printf '%s\n' "$o" | awk -v g="$1" '$1 ~ /^[0-9]+$/ {t++} $1 == g {n++} END {if (t > 0) print n + 0}') || return 1
  case "$n" in ''|*[!0-9]*) return 1 ;; esac; echo "$n"; }
set -m; ( cd "$TREE" && exec timeout -k 10 "$PER" bash "$rel" ) > "$RD/out/$name.log" 2>&1 < /dev/null & tp=$!; set +m
wait "$tp"; rc=$?
# 1 s de graça: o que ainda está acabando (um `cmd &` que termina em milissegundos) não é vazamento; o órfão que fica por minutos continua lá na segunda leitura.
# ps ilegível em qualquer das duas leituras (unread=1) → NÃO mata (não sei quem está no grupo: estado inerte) e grava `rel TAB ?` em leaks.tsv, que o resumo publica como leaked null; nunca `left=0`.
unread=0; left=0
left=$(members "$tp") || { left=0; unread=1; }
if [ "$unread" = 0 ] && [ "$left" -gt 0 ]; then sleep 1; left=$(members "$tp") || { left=0; unread=1; }; fi
if [ "$unread" = 1 ]; then row="?"; elif [ "$left" -gt 0 ]; then row=$left; kill -KILL -- "-$tp" 2> /dev/null; else row=""; fi
# a anotação que não grava (pasta no lugar do arquivo, disco cheio) faz o selftest ficar SEM resultado: a rodada sai incompleta (exit 3), nunca completa com leaked 0 por um vazamento que sumiu do registro
[ -z "$row" ] || printf '%s\t%s\n' "$rel" "$row" >> "$RD/leaks.tsv" || exit 0
printf '%s\t%s\t%s\n' "$rel" "$rc" "$(( $(date +%s) - s ))" >> "$out"
[ "$rc" -ne 0 ] || rm -f "$RD/out/$name.log"
exit 0
EOS
export TREE RD PER
load0=$(cut -d' ' -f1 /proc/loadavg 2> /dev/null || echo 0)
: > "$RD/results.tsv"
tr '\n' '\0' < "$RD/order.txt" | xargs -0 -r -P "$CORES" -I{} bash "$RD/run-one.sh" {} "$RD/results.tsv"
done1=$(wc -l < "$RD/results.tsv" | tr -d ' ')
if [ "$done1" != "$total" ]; then say "incompleto: $done1 de $total resultados"; summary incompleto main="${tested:0:9}" pull=$pull total="$total" feitos="$done1"; exit 3; fi

# quem reprovou (rc fora de 0/97/124/137) roda UMA vez de novo, com metade do paralelismo
awk -F'\t' '$2 != 0 && $2 != 97 && $2 != 124 && $2 != 137 {print $1}' "$RD/results.tsv" > "$RD/retry.txt"
: > "$RD/results2.tsv"
retry_cores=$(( (CORES + 1) / 2 ))
tr '\n' '\0' < "$RD/retry.txt" | xargs -0 -r -P "$retry_cores" -I{} bash "$RD/run-one.sh" {} "$RD/results2.tsv"

python3 -I - "$RD/results.tsv" "$RD/results2.tsv" "$PREV" "$DUR" "$LAST" "${tested:0:9}" "$tested" "$pull" "$skipped" "$(( $(date +%s) - t0 ))" "$(cut -d' ' -f1 /proc/loadavg 2> /dev/null || echo 0)" "$load0" "$RD/leaks.tsv" << 'PY'
import json, os, sys
res1, res2, prev_p, dur_p, last_p, short, full, pull, skipped, secs, load1, load0, leaks_p = sys.argv[1:14]

def rd(p):
    out = {}
    for l in open(p):
        a = l.rstrip("\n").split("\t")
        if len(a) == 3 and a[1].lstrip("-").isdigit():
            out[a[0]] = (int(a[1]), int(a[2]) if a[2].isdigit() else 0)
    return out

r1, r2 = rd(res1), rd(res2)
kind = {"pass": [], "ambiente": [], "timeout": [], "fail": [], "flaky": []}
for rel, (rc, _s) in sorted(r1.items()):
    if rc == 0:
        kind["pass"].append(rel)
    elif rc == 97:
        kind["ambiente"].append(rel)
    elif rc in (124, 137):
        kind["timeout"].append(rel)
    elif rel in r2 and r2[rel][0] == 0:
        kind["flaky"].append(rel)
    else:
        kind["fail"].append(rel)
# quem deixou processo vivo no grupo ao acabar (leaks.tsv: selftest TAB quantos; um selftest repetido na 2ª tentativa conta UMA vez). vazio (arquivo ausente: ninguém deixou) → 0 e []; falhou/ilegível
# (existe e não abre, ou tem a linha `selftest TAB ?` do ps que não leu, ou uma linha que não entendo) → None: "não consegui ler" nunca vira "ninguém vazou". Os nomes saem de qualquer jeito: `selftest:N` (N que
# vazaram) e `selftest:?` (não sei quantos)
leaked, leak_names = 0, []
try:
    _lk, _uq = {}, set()
    for _l in open(leaks_p, encoding="utf-8"):
        if not _l.strip():
            continue
        _a = _l.rstrip("\n").split("\t")
        if len(_a) == 2 and _a[1].isdigit():
            _lk[_a[0]] = max(_lk.get(_a[0], 0), int(_a[1]))
        else:
            _uq.add(_a[0])
    leaked = None if _uq else len(_lk)
    leak_names = (["%s:%d" % (k, v) for k, v in sorted(_lk.items(), key=lambda kv: -kv[1])] + ["%s:?" % k for k in sorted(_uq)])[:8]
except FileNotFoundError:
    pass
except (OSError, UnicodeDecodeError):
    leaked = None
# vazio (sem a lista anterior) → primeira; falhou/ilegível (não abre) → indisponivel, a linha de base NÃO anda sem comparação confiável
compare, prev = "primeira", set()
if os.path.exists(prev_p):
    try:
        prev = set(l.rstrip("\n") for l in open(prev_p, encoding="utf-8") if l.strip())
        compare = "ok"
    except (OSError, UnicodeDecodeError):
        compare = "indisponivel"
new = sorted(set(kind["fail"]) - prev) if compare == "ok" else []
# 60 nomes no máximo (25 reprovadas + 15 novas + 10 flaky + 10 prazo). Medido em 21/10 com os 60 selftests de nome mais longo do hq: 5495 caracteres no pior caso (os tetos antigos 40/20/20/20 davam 8728). O `pull` do
# hetzner-ballast.sh troca o resumo INTEIRO por null/"grande-demais" acima de 8000, e isso levaria as contagens junto; as contagens (fail, flaky, …) seguem exatas, só a lista de nomes é cortada
d = {"result": "completo", "main": short, "pull": pull, "total": len(r1), "pass": len(kind["pass"]), "fail": len(kind["fail"]), "flaky": len(kind["flaky"]),
     "ambiente": len(kind["ambiente"]), "timeout": len(kind["timeout"]), "skipped_mac": int(skipped), "compare": compare, "new_fail_n": len(new), "new_fail": new[:15],
     "fail_names": kind["fail"][:25], "flaky_names": kind["flaky"][:10], "timeout_names": kind["timeout"][:10], "secs": int(secs), "secs_tests": sum(s for _, s in r1.values()), "load1_start": load0, "load1_end": load1, "leaked": leaked, "leak_names": leak_names}
def stage(path, text):
    # falhou (OSError) → levanta: nada foi trocado ainda e o chamador sai com 3; um alvo que é PASTA falha aqui, não só na troca (que viria depois do resumo)
    if os.path.isdir(path):
        raise IsADirectoryError("%s é uma pasta" % path)
    with open(path + ".tmp", "w", encoding="utf-8") as f:
        f.write(text)
    return (path + ".tmp", path)
staged, err = [], ""
try:
    staged.append(stage(dur_p, "".join("%s\t%d\n" % (k, s) for k, (_rc, s) in sorted(r1.items()))))
    if compare != "indisponivel":
        staged.append(stage(prev_p, "".join(n + "\n" for n in kind["fail"])))
    staged.append(stage(last_p, full + "\n"))   # a ponta é a última da fila: é ela que dá a rodada por feita
except OSError as e:
    err = "%s: %s" % (type(e).__name__, e)
    for _p in (dur_p, prev_p, last_p):
        try:
            os.remove(_p + ".tmp")
        except OSError:
            pass   # sobra de .tmp é inofensiva: o próximo stage() o reescreve
if err:
    d["result"], d["erro"] = "gravacao-falhou", err[:160]
print("BALLAST-SUMMARY: " + json.dumps(d), flush=True)
if err:
    print("hq-selftests: não gravei o estado (%s): nada foi trocado" % err, file=sys.stderr)
    sys.exit(3)
try:
    for tmp, dst in staged:
        os.replace(tmp, dst)
except OSError as e:
    print("hq-selftests: a troca do estado falhou (%s): a ponta é a última, a rodada não conta como feita" % e, file=sys.stderr)
    sys.exit(3)
PY
prc=$?
[ "$prc" -ne 0 ] || exit 0
# rc 3: o passo já imprimiu o resumo (gravacao-falhou) e disse o motivo; outro rc: o interpretador morreu antes de imprimir e este é o ÚNICO resumo da rodada
[ "$prc" -eq 3 ] || summary resumo-falhou main="${tested:0:9}" pull="$pull" python_rc="$prc"
say "o resumo ou a gravação do estado falhou (rc $prc): a rodada NÃO conta como feita (a ponta é o último arquivo gravado) e a próxima refaz"
exit 3
