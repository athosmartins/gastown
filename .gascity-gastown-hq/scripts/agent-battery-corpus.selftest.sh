#!/usr/bin/env bash
# Selftest de agent-battery-corpus.py (ga-hyp55ss, fatia 1). Repositório git e `bd` de mentira; nada toca a cidade nem a rede.
# O `bd` de mentira tem a forma REAL (array de 1 dict; bead fechada sem assignee, com gc.session_name), medida em beads de verdade.
# Casos: acervo certo (+ meta + sha, o mesmo sob locale ASCII); os 11 motivos de exclusão contados, com o dado pessoal por forma e um
# controle negativo (sha, timestamp, porta ficam); as falhas de leitura que têm de dar o estado INERTE (git ilegível, bd
# mudo/ausente/vazio/podre, poucas tarefas, uso errado: nada escrito, acervo antigo intacto); e a PUBLICAÇÃO do par: saída que não
# existe, meta que não troca depois do acervo (o par anterior volta, sem .tmp), falha dupla (PAR TORTO), trava de instância única.
# E o que o passe de mutantes mostrou que faltava (ga-3w7866s): cada limite de tamanho NO teto, uso e padrões da linha de comando, quantas
# leituras do `bd`, o resumo/meta/JSONL em UTF-8 cru, os prazos dos subprocessos e o instante em que a espera pela trava acaba.
# Sai 0 = tudo passou.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/agent-battery-corpus.py"
W="$(mktemp -d "${TMPDIR:-/tmp}/abc-selftest.XXXXXX")"
trap 'rm -rf "$W"' EXIT
# TMPDIR com barra final (o do macOS) deixa "//" no caminho e o script só imprime caminhos normalizados; se o cd falhar, fica o caminho de antes
WN="$(cd "$W" && pwd)" && W="$WN"
FAILS=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (esperado '$3', veio '$2')"; fi; }

P=.city
R="$W/repo"
mkdir -p "$R/$P/scripts" "$R/$P/agents"
git -C "$R" init -q -b main
git -C "$R" config user.email t@t
git -C "$R" config user.name t
echo base >"$R/$P/scripts/base.sh"
git -C "$R" add -A && git -C "$R" commit -qm "chore: base"

# commit <assunto> <arquivo:conteudo>...
commit() {
  local subj="$1" spec f
  shift
  for spec in "$@"; do
    f="${spec%%:*}"
    mkdir -p "$R/$(dirname "$f")"
    printf '%b\n' "${spec#*:}" >"$R/$f"
  done
  git -C "$R" add -A && git -C "$R" commit -qm "$subj"
}
DESC="O script falha quando o disco enche e devolve zero; deve devolver erro. Criterio: o selftest reprova antes e passa depois."

commit "fix(ga-aaa): contar certo" "$P/scripts/aaa.sh:echo aaa" "$P/scripts/aaa.selftest.sh:echo t"
AAA_SHA="$(git -C "$R" rev-parse HEAD)"
commit "fix(ga-bbb): sem teste" "$P/scripts/bbb.sh:echo bbb"
commit "fix(ga-ccc): mexe em agents" "$P/scripts/ccc.sh:echo c" "$P/scripts/ccc.selftest.sh:echo t" "$P/agents/x.toml:a=1"
commit "fix(ga-ddd): enunciado com telefone" "$P/scripts/ddd.sh:echo d" "$P/scripts/ddd.selftest.sh:echo t"
commit "fix(ga-eee): parte 1" "$P/scripts/eee.sh:echo 1" "$P/scripts/eee.selftest.sh:echo t"
commit "chore: mexe no arquivo da eee" "$P/scripts/eee.sh:echo 2"
commit "fix(ga-eee): parte 2" "$P/scripts/eee.sh:echo 3"
commit "fix(ga-ggg): ainda aberta" "$P/scripts/ggg.sh:echo g" "$P/scripts/ggg.selftest.sh:echo t"
commit "fix(ga-hhh): enunciado com email" "$P/scripts/hhh.sh:echo h" "$P/scripts/hhh.selftest.sh:echo t"
big="$(for i in $(seq 1 320); do printf 'echo %s\\n' "$i"; done)"
commit "fix(ga-iii): gigante" "$P/scripts/iii.sh:$big" "$P/scripts/iii.selftest.sh:echo t"
commit "feat: sem bead no assunto" "$P/scripts/zzz.sh:echo z"
# renomeação (o git escreve scripts/{a => b}), revert nas duas formas (a do git e a do convencional), binário e enunciado curto
commit "chore: base da rrr" "$P/scripts/rrr-old.sh:echo um\necho dois\necho tres"
git -C "$R" mv "$P/scripts/rrr-old.sh" "$P/scripts/rrr-new.sh"
commit "fix(ga-rrr): renomeia o script" "$P/scripts/rrr.selftest.sh:echo t"
commit "fix(ga-qqq): entrega que sera revertida" "$P/scripts/qqq.sh:echo q" "$P/scripts/qqq.selftest.sh:echo t"
commit 'Revert "fix(ga-qqq): entrega que sera revertida"' "$P/scripts/qqq.sh:echo desfeito"
commit "fix(ga-kkk): outra entrega" "$P/scripts/kkk.sh:echo k" "$P/scripts/kkk.selftest.sh:echo t"
commit "revert(ga-kkk): desfaz" "$P/scripts/kkk.sh:echo desfeito"
commit "fix(ga-bin): traz um binario" "$P/scripts/bin.sh:echo b" "$P/scripts/bin.selftest.sh:echo t" "$P/scripts/blob.dat:a\\0b"
commit "fix(ga-sss): enunciado curto" "$P/scripts/sss.sh:echo s" "$P/scripts/sss.selftest.sh:echo t"
# dado pessoal por forma: pa-pd = o que o filtro antigo deixava passar; ok = números que NÃO são dado pessoal e têm de ficar no acervo
for b in pa pb pc; do commit "fix(ga-$b): entrega $b" "$P/scripts/$b.sh:echo $b" "$P/scripts/$b.selftest.sh:echo t"; done
commit "fix(ga-ok): entrega única" "$P/scripts/ok.sh:echo ok" "$P/scripts/ok.selftest.sh:echo t"  # acento: o locale de quem roda não pode mudar o acervo
commit "fix(ga-pd): ligar 31987654321 para conferir" "$P/scripts/pd.sh:echo pd" "$P/scripts/pd.selftest.sh:echo t"
# o que o passe de mutantes mostrou que nenhuma bead exercitava: entrega de 2 commits (base = pai do 1º, fix = o último), cada limite de
# tamanho sozinho (5 commits, 7 arquivos de produção, 4 selftests), só selftest sem produção e dado pessoal só no título
commit "fix(ga-mmm): parte 1" "$P/scripts/mmm.sh:echo 1" "$P/scripts/mmm.selftest.sh:echo t"
commit "fix(ga-mmm): parte 2" "$P/scripts/mmm.sh:echo 2"
MMM2_SHA="$(git -C "$R" rev-parse HEAD)"
MMM1_SHA="$(git -C "$R" rev-parse HEAD^)"
MMM_BASE="$(git -C "$R" rev-parse HEAD^^)"
commit "fix(ga-c5): parte 1" "$P/scripts/c5-1.sh:echo 1" "$P/scripts/c5.selftest.sh:echo t"
for i in 2 3 4 5; do commit "fix(ga-c5): parte $i" "$P/scripts/c5-$i.sh:echo $i"; done
args=("$P/scripts/p7.selftest.sh:echo t")
for i in 1 2 3 4 5 6 7; do args+=("$P/scripts/p7-$i.sh:echo $i"); done
commit "fix(ga-p7): sete arquivos de producao" "${args[@]}"
args=("$P/scripts/t4.sh:echo t")
for i in 1 2 3 4; do args+=("$P/scripts/t4-$i.selftest.sh:echo t"); done
commit "fix(ga-t4): quatro selftests" "${args[@]}"
commit "fix(ga-sp): so o selftest" "$P/scripts/sp.selftest.sh:echo t"
commit "fix(ga-pt): entrega pt" "$P/scripts/pt.sh:echo pt" "$P/scripts/pt.selftest.sh:echo t"

# bd de mentira: lê $FAKE_BD_DIR/<id>.json; FAKE_BD_MODE = mudo (rc 1) | podre (JSON quebrado) | vazio (rc 0, nada) | listavazia ([]) |
# semtitulo | semstatus (JSON sem o campo) | rcruim (JSON bom, rc 1) | alterna (a 1ª leitura falha, a 2ª responde, a 3ª falha...) |
# primeira (só a 1ª falha). FAKE_BD_LOG=<arquivo> ganha uma linha por chamada.
BDDIR="$W/beads-json"
mkdir -p "$BDDIR"
mk() { # id status descrição [dict]; T= troca o título, SESS= a sessão que construiu. Forma REAL (medida 28/11): `bd show --json` = ARRAY
  # de 1 dict; a bead fechada perde o assignee e quase sempre o gc.routed_to, e guarda gc.session_name. `dict` = a forma sem array (o ramo aceito).
  local j
  j="$(printf '{"id":"%s","title":"%s","status":"%s","description":"%s","issue_type":"bug","metadata":{"gc.session_name":"%s"}}' "$1" "${T:-t $1}" "$2" "$3" "${SESS:-dog-remote-gawisp1abc}")"
  if [ "${4:-}" = dict ]; then printf '%s' "$j"; else printf '[%s]' "$j"; fi >"$BDDIR/$1.json"
}
for b in aaa bbb ccc eee iii rrr; do mk "ga-$b" closed "$DESC"; done
mk ga-mmm closed "$(printf 'a%.0s' $(seq 1 40))"  # 40 caracteres: o mínimo, que ainda vale
mk ga-sss closed "$(printf 'a%.0s' $(seq 1 39))"  # 39 caracteres: um a menos que o mínimo de 40
T="ligar 31987654321 hoje" mk ga-pt closed "$DESC"  # o telefone está só no TÍTULO
mk ga-pa closed "Cliente 12345678901 reclamou do saldo do lote inteiro do disco e quer o estorno"
mk ga-pb closed "Ligar para 31 98765-4321 e conferir o saldo do lote inteiro do disco hoje cedo"
mk ga-pc closed "O contato 31987654321 nao recebeu a mensagem do lote inteiro do disco ontem"
mk ga-pd closed "$DESC"  # o telefone está só no ASSUNTO do commit
SESS=wa-worker-gax9 mk ga-ok closed "Falha em 2026-11-28T15:30:08Z no commit 4d758b4bdc9467f45817740e9a49b4db16cb64ed e no sha 1234567890abcdef1234567890abcdef12345678; daemons :8095/:8097, disco 5646 MB, 123456789 itens, linhas L1000-1010 e a bead ga-hyp55ss.1; números não são dado pessoal"$'\377'  # byte inválido em UTF-8: vira U+FFFD, não derruba a leitura
mk ga-ddd closed "Ligar para (31) 98765-4321 e conferir o saldo do lote inteiro do disco" dict
mk ga-hhh closed "Escrever para fulano@exemplo.com.br e conferir o saldo do lote inteiro do disco"
mk ga-ggg open "$DESC"
cat >"$W/bd" <<'EOF'
#!/usr/bin/env bash
[ -n "${FAKE_BD_LOG:-}" ] && echo "$*" >>"$FAKE_BD_LOG"   # uma linha por chamada: o teste conta as leituras
[ "$1" = show ] || exit 2
case "${FAKE_BD_MODE:-}" in
  primeira) n="$(cat "$FAKE_BD_DIR/.n" 2>/dev/null || echo 0)"; echo $((n + 1)) >"$FAKE_BD_DIR/.n"; [ "$n" -eq 0 ] && exit 1 ;;  # só a 1ª falha
  mudo) exit 1 ;;
  podre) echo '{"title": '; exit 0 ;;
  vazio) exit 0 ;;
  listavazia) echo '[]'; exit 0 ;;
  semtitulo) echo '[{"id":"x","status":"closed","description":"sem titulo"}]'; exit 0 ;;
  semstatus) echo '[{"id":"x","title":"t","description":"sem status"}]'; exit 0 ;;
  rcruim) cat "$FAKE_BD_DIR/$2.json" 2>/dev/null; exit 1 ;;   # JSON bom e rc 1: um bd que falhou não vale, nem pelo que imprimiu
  alterna) n="$(cat "$FAKE_BD_DIR/.n" 2>/dev/null || echo 0)"; echo $((n + 1)) >"$FAKE_BD_DIR/.n"; [ $((n % 2)) -eq 0 ] && exit 1 ;;  # 1ª falha, 2ª responde...
esac
f="$FAKE_BD_DIR/$2.json"
[ -f "$f" ] || exit 1
cat "$f"
EOF
chmod +x "$W/bd"
export FAKE_BD_DIR="$BDDIR"
unset GC_CITY_PATH FAKE_BD_MODE

run() { python3 -I "$TOOL" --repo "$R" --prefix "$P" --ref main --bd "$W/bd" --days 3650 "$@"; }
field() { python3 -I -c 'import json,sys,functools; print(functools.reduce(lambda a,k:a[k], sys.argv[1].split("."), json.load(sys.stdin)))' "$1"; }
ids() { python3 -I -c 'import json,sys; print(",".join(sorted(json.loads(l)["task_id"] for l in open(sys.argv[1]))))' "$1"; }

# 1) caminho feliz: servem ga-aaa, ga-mmm, ga-rrr e ga-ok; cada uma das outras cai por um motivo, e o motivo é contado
OUT="$W/out/tasks.jsonl"
S="$(run --out "$OUT" --n 10 --min 1 2>"$W/err")"
check "acervo certo: rc 0" "$?" 0
check "acervo certo: ga-aaa, a de 2 commits ga-mmm, a renomeada ga-rrr e ga-ok (números que não são dado pessoal)" "$(ids "$OUT")" "ga-aaa,ga-mmm,ga-ok,ga-rrr"
check "contagem: selecionadas" "$(printf '%s' "$S" | field selecionadas)" 4
check "contagem: revert (as duas formas)" "$(printf '%s' "$S" | field excluidas.revert)" 2
check "contagem: binário" "$(printf '%s' "$S" | field excluidas.binario)" 1
check "contagem: sem enunciado" "$(printf '%s' "$S" | field excluidas.sem_enunciado)" 1
cat >"$W/chk_rename.py" <<'PY'
import json, re, sys
t = [x for x in map(json.loads, open(sys.argv[1])) if x["task_id"] == "ga-rrr"][0]
limpo = all(re.match(r"^[A-Za-z0-9._/-]+$", p) for p in t["prod_files"] + t["test_files"])
print("ok" if limpo and "scripts/rrr-new.sh" in t["prod_files"] else t["prod_files"])
PY
check "renomeação: caminhos sem chaves nem espaço (o executor recusa a tarefa inteira) e o novo na lista" "$(python3 -I "$W/chk_rename.py" "$OUT")" ok
check "contagem: sem selftest ou sem produção (uma de cada)" "$(printf '%s' "$S" | field excluidas.sem_selftest_ou_sem_producao)" 2
check "contagem: fora da allowlist" "$(printf '%s' "$S" | field excluidas.fora_da_allowlist)" 1
check "contagem: intercalada" "$(printf '%s' "$S" | field excluidas.intercalada)" 1
check "contagem: grande demais (linhas, commits, arquivos de produção e selftests, cada limite sozinho)" "$(printf '%s' "$S" | field excluidas.grande_demais)" 4
check "contagem: dado pessoal (telefone, e-mail, CPF e telefone sem pontuação, no assunto do commit e no título)" "$(printf '%s' "$S" | field excluidas.dado_pessoal)" 7
check "contagem: bead não fechada" "$(printf '%s' "$S" | field excluidas.bead_nao_fechada)" 1
check "contagem: sem bead no assunto (o Revert do git já conta na bead dele)" "$(printf '%s' "$S" | field excluidas.sem_bead_no_assunto)" 4
# a tarefa INTEIRA (dict igual ao esperado: campo errado ou sobrando aparece pelo nome), o papel vindo do gc.session_name, e a de 2 commits
cat >"$W/chk_task.py" <<'PY'
import json, sys
t = [x for x in map(json.loads, open(sys.argv[1])) if x["task_id"] == "ga-aaa"][0]
sha, base, desc = sys.argv[2:5]
want = {"task_id": "ga-aaa", "bead": "ga-aaa", "title": "t ga-aaa", "description": desc, "issue_type": "bug", "role": "dog",
        "base_sha": base, "fix_sha": sha, "commits": [{"sha": sha, "subject": "fix(ga-aaa): contar certo"}],
        "prod_files": ["scripts/aaa.sh"], "test_files": ["scripts/aaa.selftest.sh"],
        "success": {"kind": "selftest-fail-to-pass", "commands": ["bash scripts/aaa.selftest.sh"]}}
print("ok" if t == want else sorted(k for k in set(t) | set(want) if t.get(k) != want.get(k)))
PY
check "tarefa ga-aaa: todos os campos (fix = commit da entrega, base = o pai dele, critério = o selftest)" "$(python3 -I "$W/chk_task.py" "$OUT" "$AAA_SHA" "$(git -C "$R" rev-parse "$AAA_SHA^")" "$DESC")" ok
cat >"$W/chk_mmm.py" <<'PY'
import json, sys
t = [x for x in map(json.loads, open(sys.argv[1])) if x["task_id"] == "ga-mmm"][0]
p1, p2, base = sys.argv[2:5]
ok = (t["base_sha"] == base and t["fix_sha"] == p2 and [c["sha"] for c in t["commits"]] == [p1, p2]
      and t["prod_files"] == ["scripts/mmm.sh"] and t["test_files"] == ["scripts/mmm.selftest.sh"])
print("ok" if ok else {k: t[k] for k in ("base_sha", "fix_sha", "commits")})
PY
check "tarefa de 2 commits: base = pai do 1º, fix = o último, commits do mais antigo ao mais novo" "$(python3 -I "$W/chk_mmm.py" "$OUT" "$MMM1_SHA" "$MMM2_SHA" "$MMM_BASE")" ok
cat >"$W/chk_ordem.py" <<'PY'
import hashlib, json, sys
ids = [json.loads(l)["task_id"] for l in open(sys.argv[1])]
print("ok" if ids == sorted(ids, key=lambda b: hashlib.sha256(("battery-v1" + b).encode()).hexdigest()) else ids)
PY
check "seleção: as linhas seguem a ordem do sha256(sal + bead)" "$(python3 -I "$W/chk_ordem.py" "$OUT")" ok
check "resumo: por_papel (3 dog-remote e 1 wa-worker, vindos de gc.session_name)" "$(printf '%s' "$S" | field por_papel.dog),$(printf '%s' "$S" | field por_papel.wa-worker)" "3,1"
check "meta: parâmetros gravados" "$(python3 -I -c 'import json,sys; p=json.load(open(sys.argv[1]+".meta.json"))["params"]; print(p["n"], p["min"], p["salt"], p["prefix"])' "$OUT")" "10 1 battery-v1 .city"
check "meta: gerado_em é um instante UTC" "$(python3 -I -c 'import json,re,sys; print(bool(re.match(r"^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", json.load(open(sys.argv[1]+".meta.json"))["gerado_em"])))' "$OUT")" True
check "meta: sha256 = do arquivo" "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]+".meta.json"))["sha256"])' "$OUT")" "$(shasum -a 256 "$OUT" | cut -d' ' -f1)"
check "meta: head = a ponta lida" "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]+".meta.json"))["head"])' "$OUT")" "$(git -C "$R" rev-parse main)"
H1="$(shasum -a 256 "$OUT" | cut -d' ' -f1)"
run --out "$OUT" --n 10 --min 1 >/dev/null 2>&1
check "determinismo: 2ª rodada, mesmo sha" "$(shasum -a 256 "$OUT" | cut -d' ' -f1)" "$H1"
check "sem lixo .tmp ao lado do acervo" "$(ls -A "$W/out" | grep -c '^\.tmp-corpus-')" 0
# o acervo não depende do locale de quem roda (cron com LANG=C x terminal em UTF-8). Sem `-I`: ele ignoraria estas variáveis; a cópia
# do script vai sozinha numa pasta para nenhum .py vizinho entrar no import.
mkdir -p "$W/loc"
cp "$TOOL" "$W/loc/corpus.py"
env LC_ALL=C PYTHONCOERCECLOCALE=0 PYTHONUTF8=0 python3 -B "$W/loc/corpus.py" --repo "$R" --prefix "$P" --ref main --bd "$W/bd" \
  --days 3650 --n 10 --min 1 --out "$W/loc/tasks.jsonl" >/dev/null 2>"$W/err-loc"
check "locale ASCII sem coerção: rc 0" "$?" 0
check "locale ASCII sem coerção: mesmo acervo (mesmo sha)" "$(shasum -a 256 "$W/loc/tasks.jsonl" 2>/dev/null | cut -d' ' -f1)" "$H1"

# 2) --dry-run não grava
D="$W/dry/tasks.jsonl"
run --out "$D" --n 10 --min 1 --dry-run >/dev/null 2>&1
check "dry-run: rc 0" "$?" 0
check "dry-run: nada gravado" "$([ -e "$D" ] && echo existe || echo nao)" nao

# 3) estados inertes: nada escrito e o acervo antigo fica como estava
inerte() { # nome rc_esperado env... -- args...
  local name="$1" want="$2" out
  shift 2
  out="$W/inerte-$name/tasks.jsonl"
  mkdir -p "$(dirname "$out")"
  echo OLD >"$out"
  env "$@" >/dev/null 2>"$W/err-$name"
  local rc=$?
  check "$name: rc" "$rc" "$want"
  check "$name: acervo antigo intacto" "$(cat "$out")" OLD
  check "$name: meta não criado" "$([ -e "$out.meta.json" ] && echo existe || echo nao)" nao
}
inerte bd-mudo 5 FAKE_BD_MODE=mudo python3 -I "$TOOL" --repo "$R" --prefix "$P" --ref main --bd "$W/bd" --days 3650 --n 10 --min 1 --out "$W/inerte-bd-mudo/tasks.jsonl"
inerte bd-podre 5 FAKE_BD_MODE=podre python3 -I "$TOOL" --repo "$R" --prefix "$P" --ref main --bd "$W/bd" --days 3650 --n 10 --min 1 --out "$W/inerte-bd-podre/tasks.jsonl"
inerte bd-vazio 5 FAKE_BD_MODE=vazio python3 -I "$TOOL" --repo "$R" --prefix "$P" --ref main --bd "$W/bd" --days 3650 --n 10 --min 1 --out "$W/inerte-bd-vazio/tasks.jsonl"
inerte bd-ausente 5 X=1 python3 -I "$TOOL" --repo "$R" --prefix "$P" --ref main --bd "$W/nao-existe" --days 3650 --n 10 --min 1 --out "$W/inerte-bd-ausente/tasks.jsonl"
inerte ref-ruim 2 X=1 python3 -I "$TOOL" --repo "$R" --prefix "$P" --ref nao-existe --bd "$W/bd" --days 3650 --n 10 --min 1 --out "$W/inerte-ref-ruim/tasks.jsonl"
inerte repo-ruim 2 X=1 python3 -I "$TOOL" --repo "$W/nao-e-repo" --prefix "$P" --ref main --bd "$W/bd" --days 3650 --n 10 --min 1 --out "$W/inerte-repo-ruim/tasks.jsonl"
inerte poucas 3 X=1 python3 -I "$TOOL" --repo "$R" --prefix "$P" --ref main --bd "$W/bd" --days 3650 --n 10 --min 5 --out "$W/inerte-poucas/tasks.jsonl"
inerte pasta-vazia 3 X=1 python3 -I "$TOOL" --repo "$R" --prefix pasta-sem-commit --ref main --bd "$W/bd" --days 3650 --n 10 --min 1 --out "$W/inerte-pasta-vazia/tasks.jsonl"
inerte uso-errado 2 X=1 python3 -I "$TOOL" --repo "$R" --prefix "$P" --ref main --bd "$W/bd" --n 3 --min 9 --out "$W/inerte-uso-errado/tasks.jsonl"
# a ponta ilegível aborta ANTES do log (a mensagem diz qual leitura falhou); `--show-cdup` dá rc 0 e saída vazia
check "ref ruim: aborta na ponta (git rev-parse), antes do log" "$(grep -c 'git rev-parse' "$W/err-ref-ruim")" 1
inerte ponta-vazia 2 X=1 python3 -I "$TOOL" --repo "$R" --prefix "$P" --ref=--show-cdup --bd "$W/bd" --days 3650 --n 10 --min 1 --out "$W/inerte-ponta-vazia/tasks.jsonl"
check "ponta vazia (rc 0, sem sha): aborta na ponta, não no log" "$(grep -c 'git rev-parse' "$W/err-ponta-vazia")" 1
# o log falhando com a ponta boa (pasta fora do repositório) é rc 2, não "nenhum commit" (rc 3)
inerte log-falha 2 X=1 python3 -I "$TOOL" --repo "$R" --prefix ../fora --ref main --bd "$W/bd" --days 3650 --n 10 --min 1 --out "$W/inerte-log-falha/tasks.jsonl"
# um bd que responde, mas não com uma bead (lista vazia, sem título, sem status) ou que falhou (rc 1) apesar do JSON bom, não vale: rc 5
for modo in listavazia semtitulo semstatus rcruim; do
  inerte "bd-$modo" 5 FAKE_BD_MODE=$modo python3 -I "$TOOL" --repo "$R" --prefix "$P" --ref main --bd "$W/bd" --days 3650 --n 10 --min 1 --out "$W/inerte-bd-$modo/tasks.jsonl"
done
# exatamente a METADE das leituras sem resposta já é rc 5 ("metade ou mais"): com --n 2 --oversample 1 são 2 leituras, a 1ª falha e a 2ª responde
rm -f "$BDDIR/.n"
inerte bd-metade 5 FAKE_BD_MODE=alterna python3 -I "$TOOL" --repo "$R" --prefix "$P" --ref main --bd "$W/bd" --days 3650 --n 2 --min 1 --oversample 1 --out "$W/inerte-bd-metade/tasks.jsonl"
rm -f "$BDDIR/.n"

# 4) bead ilegível em minoria: segue, e CONTA (nunca some em silêncio)
rm "$BDDIR/ga-hhh.json"
S="$(run --out "$W/minoria/tasks.jsonl" --n 10 --min 1 2>/dev/null)"
check "minoria ilegível: rc 0" "$?" 0
check "minoria ilegível: contada" "$(printf '%s' "$S" | field excluidas.bead_ilegivel)" 1
check "minoria ilegível: as outras continuam" "$(ids "$W/minoria/tasks.jsonl")" "ga-aaa,ga-mmm,ga-ok,ga-rrr"

# 5) saída sem como gravar: rc 4 (um ARQUIVO no lugar da pasta)
echo x >"$W/arquivo"
run --out "$W/arquivo/tasks.jsonl" --n 10 --min 1 >/dev/null 2>"$W/err-saida"
check "saída impossível: rc 4" "$?" 4
check "saída impossível: o arquivo no lugar da pasta segue intacto" "$(cat "$W/arquivo")" x

# 6) meio-caminho (o buraco que o gate mediu): o meta não pode ser trocado (pasta no lugar do arquivo) DEPOIS de o acervo novo estar
#    pronto. rc 4 e o par anterior fica como estava, sem .tmp-corpus-* esquecido.
MEIO="$W/meio/tasks.jsonl"
mkdir -p "$MEIO.meta.json"
echo OLD >"$MEIO"
run --out "$MEIO" --n 10 --min 1 >/dev/null 2>"$W/err-meio"
check "meio-caminho: rc 4" "$?" 4
check "meio-caminho: acervo antigo intacto" "$(cat "$MEIO")" OLD
check "meio-caminho: meta continua como estava (pasta)" "$([ -d "$MEIO.meta.json" ] && echo pasta || echo outro)" pasta
check "meio-caminho: sem .tmp-corpus-*" "$(ls -A "$W/meio" | grep -c '^\.tmp-corpus-')" 0
check "meio-caminho: a mensagem diz que o par anterior continua" "$(grep -c 'o par anterior continua' "$W/err-meio")" 1
# o mesmo meio-caminho SEM acervo anterior: o acervo novo já trocado tem de sumir de novo (nunca fica acervo novo sem meta)
SEM="$W/meio-sem-antigo/tasks.jsonl"
mkdir -p "$SEM.meta.json"
run --out "$SEM" --n 10 --min 1 >/dev/null 2>&1
check "meio-caminho sem acervo anterior: rc 4" "$?" 4
check "meio-caminho sem acervo anterior: nenhum acervo novo fica sem meta" "$([ -e "$SEM" ] && echo existe || echo nao)" nao

# 7) casos que pedem trocar uma função por uma falha de mentira: o módulo é carregado por caminho, o snippet (stdin) vê `m`.
pyt() { # $1.. = argumentos do snippet (sys.argv[2:])
  python3 -I -B -c 'import importlib.util, sys
s = importlib.util.spec_from_file_location("sob_teste", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
exec(sys.stdin.read())' "$TOOL" "$@"
}
# 7a) falha dupla: o meta não troca E o acervo antigo não volta → rc 4, a mensagem diz PAR TORTO e nomeia o arquivo onde o antigo
#     ficou guardado (agora o único lugar em que ele existe).
DUPLA="$W/dupla"
mkdir -p "$DUPLA"
echo OLD >"$DUPLA/tasks.jsonl"
pyt "$DUPLA" >"$W/out-dupla" 2>"$W/err-dupla" <<'PY'
import os
real, dsts = os.replace, []
def replace(src, dst):
    dsts.append(os.path.basename(dst))
    if len(dsts) >= 2:   # a 1ª troca (o acervo) passa; a do meta e o desfazer falham
        raise OSError("de mentira")
    real(src, dst)
os.replace = replace
try:
    m.publish(os.path.join(sys.argv[2], "tasks.jsonl"), b"NOVO\n", b"{}\n")
except SystemExit as e:
    print("rc=%s" % e.code)
print("ordem=" + ",".join(dsts))
PY
check "falha dupla: rc 4" "$(grep '^rc=' "$W/out-dupla")" rc=4
check "troca: o acervo primeiro, o meta por último (o selo), e o desfazer volta ao acervo" "$(grep '^ordem=' "$W/out-dupla")" "ordem=tasks.jsonl,tasks.jsonl.meta.json,tasks.jsonl"
check "falha dupla: a mensagem diz PAR TORTO" "$(grep -c 'PAR TORTO' "$W/err-dupla")" 1
GUARDADO="$(grep -l '^OLD$' "$DUPLA"/.tmp-corpus-* 2>/dev/null)"
check "falha dupla: o acervo antigo segue guardado" "$(printf '%s' "$GUARDADO" | grep -c .)" 1
check "falha dupla: a mensagem nomeia onde ele está" "$([ -n "$GUARDADO" ] && grep -c -F -- "$GUARDADO" "$W/err-dupla" || echo 0)" 1

# 7b) trava de instância única (<acervo>.lock): ocupada além da espera → rc 4 e nada trocado; liberada DENTRO da espera → grava.
TRAVA="$W/trava"
mkdir -p "$TRAVA"
echo OLD >"$TRAVA/tasks.jsonl"
pyt "$TRAVA" >"$W/out-trava" 2>"$W/err-trava" <<'PY'
import fcntl, os, threading
out = os.path.join(sys.argv[2], "tasks.jsonl")
fd = os.open(out + ".lock", os.O_CREAT | os.O_RDWR)
fcntl.flock(fd, fcntl.LOCK_EX)
m.LOCK_WAIT_S = 0.4
try:
    m.publish(out, b"NOVO\n", b"{}\n")
except SystemExit as e:
    print("ocupada: rc=%s" % e.code)
print("ocupada: acervo=%s tmp=%d" % (open(out).read().strip(), len([f for f in os.listdir(sys.argv[2]) if f.startswith(".tmp-corpus-")])))
threading.Timer(0.3, lambda: fcntl.flock(fd, fcntl.LOCK_UN)).start()
m.LOCK_WAIT_S = 5
m.publish(out, b"NOVO\n", b"{}\n")
print("liberada: acervo=%s meta=%s" % (open(out).read().strip(), os.path.exists(out + ".meta.json")))
m.publish(out, b"TERCEIRO\n", b"{}\n")   # a trava foi solta ao fim do publish anterior: o 2º, no mesmo processo, não espera
print("de novo: acervo=%s" % open(out).read().strip())
PY
check "trava ocupada: rc 4" "$(grep -c '^ocupada: rc=4$' "$W/out-trava")" 1
check "trava ocupada: nada trocado, sem .tmp" "$(grep '^ocupada: acervo' "$W/out-trava")" "ocupada: acervo=OLD tmp=0"
check "trava ocupada: a mensagem diz que outra rodada grava" "$(grep -c 'outra rodada' "$W/err-trava")" 1
check "trava liberada dentro da espera: grava o par" "$(grep '^liberada' "$W/out-trava")" "liberada: acervo=NOVO meta=True"
check "trava: um 2º publish no mesmo processo não fica preso na trava do 1º" "$(grep '^de novo' "$W/out-trava")" "de novo: acervo=TERCEIRO"

# 7c) papel de quem construiu, com as formas medidas: bead FECHADA guarda gc.session_name (dog-…, dog-remote-…, oracle-wa-…);
#     a bead aberta ainda traz assignee/gc.routed_to. Sem fonte → sem-papel; fonte que não é pool → outro (nunca o mesmo valor).
pyt >"$W/out-papel" <<'PY'
sess = lambda s: {"metadata": {"gc.session_name": s}}
casos = [
    (sess("dog-gan6yf03s"), "dog"), (sess("dog-remote-gawisp6t6t71"), "dog"), (sess("oracle-wa-gawispgux5v0"), "outro"),
    (sess("wa-worker-ga1abc"), "wa-worker"), (sess("ps-worker-ga9xyz"), "ps-worker"), (sess("hotdog-x"), "outro"),
    (sess("dogfood-x"), "outro"),
    ({"assignee": "gastown.dog"}, "dog"), ({"metadata": {"gc.routed_to": "gastown.dog"}}, "dog"),
    ({"metadata": {"gc.session_name": "oracle-wa-x", "gc.routed_to": "gastown.dog"}}, "outro"),
    ({"assignee": None, "metadata": {}}, "sem-papel"), ({}, "sem-papel"), ({"metadata": "texto"}, "sem-papel"),
    ({"assignee": 7}, "sem-papel"), ({"assignee": "  "}, "sem-papel"),
]
print([(i, m.role_of(b), w) for i, (b, w) in enumerate(casos) if m.role_of(b) != w] or "ok")
PY
check "papel: tabela das formas reais" "$(cat "$W/out-papel")" ok

# 7d) o filtro de dado pessoal por forma, no limite de cada alternativa e com o que NÃO é dado pessoal (sha, timestamp, porta, faixa)
pyt >"$W/out-pii" <<'PY'
pos = ["12345678901", "1234567890", "0123456789", "1234567890123", "5531987654321", "31987654321.", "31 98765 4321", "(31)98765-4321", "+55 (31) 98765-4321",
       "tel 98765-4321", "3333-4444", "123.456.789-01", "a.b@exemplo.com.br", "5531987654321@s.whatsapp.net", "tel:31987654321,"]
neg = ["123456789", "12345678901234", "4d758b4bdc9467f45817740e9a49b4db16cb64ed", "1234567890abcdef", "abc1234567890", "x1234-5678y",
       "2026-11-28T15:30:08Z", ":8095/:8097 e 52756", "ga-hyp55ss.1", "5646 MB", "127.0.0.1", "R$ 1.234,56", "546-550", "1.1.0"]
print([t for t in pos if not m.PII_RE.search(t)] + ["falso positivo: " + t for t in neg if m.PII_RE.search(t)] or "ok")
PY
check "dado pessoal: formas que pegam e o que não é dado pessoal" "$(cat "$W/out-pii")" ok

# 7e) a ponta é resolvida UMA vez e o `git log` lê esse sha (não o nome da ref): se a main andar entre as duas leituras, o meta não
#     pode dizer uma ponta que não foi lida. Cada chamada guarda o prazo no fim do comando: git rev-parse 30 s, git log 180 s, bd show 60 s.
pyt "$R" "$P" >"$W/out-ponta" <<'PY'
calls, real = [], m.run
m.run = lambda cmd, timeout: (calls.append(cmd + [timeout]), real(cmd, timeout))[1]
head, commits = m.read_history(sys.argv[2], "main", sys.argv[3], 3650)
log = [c for c in calls if "log" in c][0]
print("log lê o sha da ponta" if log[4] == head and head != "main" else "log lê %s" % log[4])
m.run = lambda cmd, timeout: (calls.append(cmd + [timeout]), (0, "[]"))[1]
m.read_bead(["bd"], "ga-x")
print("prazos: rev-parse %s, log %s, bd %s" % ([c for c in calls if "rev-parse" in c][0][-1], log[-1], calls[-1][-1]))
PY
check "ponta: o git log lê o sha resolvido, não o nome da ref" "$(head -1 "$W/out-ponta")" "log lê o sha da ponta"
check "prazos: git rev-parse 30 s, git log 180 s, bd show 60 s" "$(tail -1 "$W/out-ponta")" "prazos: rev-parse 30, log 180, bd 60"

# 7f) limites de tamanho NO teto passam (um a mais cai: as beads c5, p7, t4 e iii da seção 1 e o caso de 301 linhas); `-` em UM lado do
#     numstat já é binário (sem passar por int()); um .md em scripts/ e um .txt em docs/ não são produção; o commit do meio da própria
#     bead, ou de outra bead que mexe em outros arquivos, não é "intercalada"
pyt >"$W/out-classify" <<'PY'
def C(*files, s="fix(ga-x): y"):
    return {"sha": "s", "parent": "p", "subject": s, "files": [(a, d, ".c/" + f) for a, d, f in files]}
T, S = ("1", "0", "scripts/t.selftest.sh"), ("1", "0", "scripts/x.sh")
many = lambda n, pre, suf: [("1", "0", "scripts/%s%d%s" % (pre, i, suf)) for i in range(n)]
casos = [
    ("4 commits", [C(T, S), C(S), C(S), C(S)], None),
    ("6 arquivos de produção", [C(T, *many(6, "p", ".sh"))], None),
    ("3 selftests", [C(S, *many(3, "t", ".selftest.sh"))], None),
    ("300 linhas", [C(T, ("150", "150", "scripts/x.sh"))], None),
    ("301 linhas", [C(T, ("150", "151", "scripts/x.sh"))], "grande_demais"),
    ("binário só no add", [C(T, ("-", "3", "scripts/x.sh"))], "binario"),
    ("binário só no del", [C(T, ("3", "-", "scripts/x.sh"))], "binario"),
    ("só .md em scripts/", [C(T, ("1", "0", "scripts/LEIAME.md"))], "sem_selftest_ou_sem_producao"),
    ("só .txt em docs/", [C(T, ("1", "0", "docs/nota.txt"))], "sem_selftest_ou_sem_producao"),
    ("commit do meio é da bead", [C(T, S), C(S), C(S)], None),
    ("outra bead no meio, outros arquivos", [C(T, S), C(("1", "0", "scripts/outro.sh"), s="fix(ga-y): z"), C(S)], None),
]
got = [(n, m.classify("ga-x", [i for i, c in enumerate(cs) if "ga-x" in c["subject"]], cs, ".c"), w) for n, cs, w in casos]
print([g for g in got if g[1] != g[2]] or "ok")
PY
check "classify: cada limite no teto passa, binário em um lado só, .md e .txt em docs/ não são produção, intercalada só com os mesmos arquivos" "$(cat "$W/out-classify")" ok

# 7g) o que o `git log` devolve: numstat solta (antes de qualquer cabeçalho) é ignorada, add e del cada um no seu campo, o 1º pai,
#     do mais antigo ao mais novo
pyt >"$W/out-log" <<'PY'
raw = "9\t9\tscripts/solta.sh\n@@c1\x1fp1 p2\x1fum\n5\t2\tscripts/a.sh\n-\t-\tscripts/b.bin\n\n@@c2\x1fp3\x1fdois\n3\t0\tscripts/c.sh\n"
m.run = lambda cmd, timeout: (0, raw)
want = [{"sha": "c2", "parent": "p3", "subject": "dois", "files": [("3", "0", "scripts/c.sh")]},
        {"sha": "c1", "parent": "p1", "subject": "um", "files": [("5", "2", "scripts/a.sh"), ("-", "-", "scripts/b.bin")]}]
got = m.read_log("r", "ref", "pfx", 7)
print("ok" if got == want else got)
PY
check "git log: numstat solta ignorada, add e del cada um no seu campo, 1º pai, do mais antigo ao mais novo" "$(cat "$W/out-log")" ok

# 7h) a espera pela trava termina NO prazo, não um tique depois (relógio de mentira: a 2ª leitura marca exatamente o fim); a espera
#     padrão é a de 30 s do cabeçalho
RELOGIO="$W/relogio"
mkdir -p "$RELOGIO"
pyt "$RELOGIO" >"$W/out-relogio" 2>&1 <<'PY'
import fcntl, os
out = os.path.join(sys.argv[2], "tasks.jsonl")
print("espera=%s" % m.LOCK_WAIT_S)
fd = os.open(out + ".lock", os.O_CREAT | os.O_RDWR)
fcntl.flock(fd, fcntl.LOCK_EX)
class Relogio:   # 1ª leitura = o início; 2ª = o início + a espera (o prazo exato); depois, bem além
    def __init__(s): s.l, s.dormiu = [100.0, 100.0 + m.LOCK_WAIT_S, 9999.0], []
    def monotonic(s): return s.l.pop(0)
    def sleep(s, x): s.dormiu.append(x)
m.time = r = Relogio()
try:
    m.take_lock(out + ".lock")
except SystemExit as e:
    print("rc=%s dormiu=%s" % (e.code, r.dormiu))
PY
check "trava: a espera padrão é a de 30 s do cabeçalho" "$(grep '^espera=' "$W/out-relogio")" espera=30
check "trava: com o relógio no prazo exato a espera acaba (rc 4) sem dormir mais" "$(grep '^rc=' "$W/out-relogio")" "rc=4 dormiu=[]"

# 8) --bd com espaço no caminho (entre aspas) e com aspas desbalanceadas (uso errado: rc 2, nada lido)
mkdir -p "$W/com espaco"
cp "$W/bd" "$W/com espaco/bd"
S="$(run --bd "'$W/com espaco/bd'" --out "$W/espaco/tasks.jsonl" --n 10 --min 1 --dry-run 2>/dev/null)"
check "--bd com espaço entre aspas: rc 0" "$?" 0
check "--bd com espaço entre aspas: leu as beads" "$(printf '%s' "$S" | field selecionadas)" 4
run --bd "'aberta" --out "$W/espaco/tasks.jsonl" --dry-run >/dev/null 2>&1
check "--bd com aspas desbalanceadas: rc 2" "$?" 2

# 9) o que o passe de mutantes (ga-3w7866s) mostrou que nenhum caso fixava
# 9a) uso: --help existe; sem --out e sem GC_CITY_PATH só o --dry-run passa (numa pasta vazia: um --out vazio gravaria ao lado do cwd);
#     n, min e days NO limite (1) valem; --min, --days e --oversample inválidos, um de cada vez (`a.n < 1` é redundante: ver a declaração
#     de equivalência no fim); os padrões que a mensagem do rc 3 e o meta mostram
mkdir -p "$W/semout"
( cd "$W/semout" && python3 -I "$TOOL" --help >"$W/out-help" 2>/dev/null )
check "--help: rc 0 e o uso no stdout" "$?,$(grep -c '^usage:' "$W/out-help")" "0,1"
( cd "$W/semout" && python3 -I "$TOOL" --repo "$R" --prefix "$P" --ref main --bd "$W/bd" --days 3650 >/dev/null 2>"$W/err-semout" )
check "sem --out e sem GC_CITY_PATH: rc 2 e a mensagem diz isso" "$?,$(grep -c 'sem --out' "$W/err-semout")" "2,1"
( cd "$W/semout" && python3 -I "$TOOL" --repo "$R" --prefix "$P" --ref main --bd "$W/bd" --days 3650 --n 10 --min 1 --dry-run >/dev/null 2>&1 )
check "sem --out mas com --dry-run: rc 0 (nada a gravar)" "$?" 0
S="$(run --out "$W/lim/tasks.jsonl" --n 1 --min 1 --days 1 --dry-run 2>/dev/null)"
check "n, min e days = 1 (o limite de cada um, com min == n): rc 0 e 1 tarefa" "$?,$(printf '%s' "$S" | field selecionadas)" "0,1"
for arg in "--min 0" "--days 0" "--oversample 0"; do
  tag="${arg#--}"
  tag="${tag// /-}"
  inerte "uso-$tag" 2 X=1 python3 -I "$TOOL" --repo "$R" --prefix "$P" --ref main --bd "$W/bd" --days 3650 --n 5 --min 1 $arg --out "$W/inerte-uso-$tag/tasks.jsonl"
done
inerte min-padrao 3 X=1 python3 -I "$TOOL" --repo "$R" --prefix "$P" --ref main --bd "$W/bd" --days 3650 --out "$W/inerte-min-padrao/tasks.jsonl"
check "--min padrão 20: a mensagem do rc 3 diz o mínimo" "$(grep -c 'mínimo 20' "$W/err-min-padrao")" 1
python3 -I "$TOOL" --repo "$R" --prefix "$P" --ref main --bd "$W/bd" --min 1 --out "$W/padrao/tasks.jsonl" >/dev/null 2>&1
check "--days e --n padrão: 60 e 40 no meta" "$(python3 -I -c 'import json,sys; p=json.load(open(sys.argv[1]+".meta.json"))["params"]; print(p["days"], p["n"])' "$W/padrao/tasks.jsonl")" "60 40"
# 9b) quantas leituras do bd: sem resposta nenhuma lê n x oversample (padrão 3: --n 2 lê 6, nem 5, nem 7, nem todas as elegíveis); para
#     em n tarefas; 1 leitura sem resposta de 3 (menos da metade) segue e conta
rm -f "$BDDIR/.calls" "$BDDIR/.n"
S="$(FAKE_BD_MODE=mudo FAKE_BD_LOG="$BDDIR/.calls" run --out "$W/leituras/tasks.jsonl" --n 2 --min 1 2>/dev/null)"
check "bd mudo, --n 2: 6 chamadas ao bd e leituras_de_bead 6" "$(grep -c . "$BDDIR/.calls"),$(printf '%s' "$S" | field leituras_de_bead)" "6,6"
S="$(run --out "$W/leituras/n2.jsonl" --n 2 --min 1 --oversample 100 --dry-run 2>/dev/null)"
check "--n 2 com leituras de sobra: para em 2 tarefas (há 4 boas)" "$(printf '%s' "$S" | field selecionadas)" 2
S="$(FAKE_BD_MODE=primeira run --out "$W/leituras/terco.jsonl" --n 3 --oversample 1 --min 1 --dry-run 2>/dev/null)"
rc=$?
rm -f "$BDDIR/.n"
check "1 leitura sem resposta de 3 (menos da metade): não é rc 5" "$([ "$rc" -ne 5 ] && echo ok || echo "rc=$rc")" ok
check "1 leitura sem resposta de 3: contada" "$(printf '%s' "$S" | field excluidas.bead_ilegivel)" 1
S="$(run --out "$W/leituras/min4.jsonl" --n 10 --min 4 --dry-run 2>/dev/null)"
check "tarefas == --min (4 de 4): rc 0" "$?" 0
# 9c) o resumo (stdout e meta) e o JSONL saem em UTF-8 cru, não \uXXXX (a única fonte de texto não ASCII no resumo é o nome da ref); o
#     meta tem recuo 1 e o JSONL as chaves em ordem alfabética
git -C "$R" branch "ação" main
U="$W/utf8"
mkdir -p "$U"
u8() { # rc_esperado env args...: com --ref "ação", o resumo do stdout traz o texto cru
  local want="$1" e="$2" o rc
  shift 2
  o="$(env "$e" python3 -I "$TOOL" --repo "$R" --prefix "$P" --ref "ação" --bd "$W/bd" --days 3650 "$@" 2>/dev/null)"
  rc=$?
  check "resumo com ref não ASCII (rc $want): rc" "$rc" "$want"
  check "resumo com ref não ASCII (rc $want): UTF-8 cru" "$(printf '%s' "$o" | grep -c '"ref": "ação"')" 1
}
u8 5 FAKE_BD_MODE=mudo --out "$U/a.jsonl" --n 2 --min 1
u8 3 X=1 --out "$U/b.jsonl" --n 10 --min 9
u8 0 X=1 --out "$U/c.jsonl" --n 10 --min 1 --dry-run
u8 0 X=1 --out "$U/d.jsonl" --n 10 --min 1
check "meta: recuo 1 e UTF-8 cru" "$(sed -n 2p "$U/d.jsonl.meta.json")" ' "ref": "ação",'
check "JSONL: chaves em ordem alfabética (a 1ª é base_sha)" "$(head -c 14 "$U/d.jsonl")" '{"base_sha": "'
check "JSONL: UTF-8 cru (o byte inválido do enunciado da ga-ok sai como U+FFFD em 3 bytes)" "$(LC_ALL=C grep -c "$(printf '\357\277\275')" "$U/d.jsonl")" 1
# 9d) com GC_CITY_PATH o bd padrão leva `-C <cidade>`; um --bd explícito segue como está (o bd de mentira de fakebin só anota o argv e falha)
mkdir -p "$W/fakebin"
printf '#!/bin/sh\necho "$*" >>"%s"\nexit 1\n' "$W/bd-argv" >"$W/fakebin/bd"
chmod +x "$W/fakebin/bd"
env GC_CITY_PATH="$W/cidade" PATH="$W/fakebin:$PATH" python3 -I "$TOOL" --repo "$R" --prefix "$P" --ref main --days 3650 --n 1 --oversample 1 --min 1 --dry-run >/dev/null 2>&1
check "GC_CITY_PATH + bd padrão: o bd recebe -C <cidade> antes do show" "$(head -1 "$W/bd-argv" | cut -d' ' -f1-3)" "-C $W/cidade show"
S="$(env GC_CITY_PATH="$W/cidade" PATH="$W/fakebin:$PATH" python3 -I "$TOOL" --repo "$R" --prefix "$P" --ref main --bd "$W/bd" --days 3650 --n 10 --min 1 --dry-run 2>/dev/null)"
check "GC_CITY_PATH + --bd explícito: o explícito é o usado (não vira bd -C)" "$(printf '%s' "$S" | field selecionadas)" 4
# 9e) mutantes que o motor troca e que NENHUM caso pode distinguir, cada um comparado com o original lado a lado (um controle que muda o resultado divergiu)
# EQUIVALENT 858c5b62e2: range(idxs[0] + 0, ...) só acrescenta o j = idxs[0], que está em `own`, e o teste `j not in own` o descarta como antes (20000 históricos aleatórios no classify, 0 divergências)
# EQUIVALENT 815e947d02: group(0) == group(1) em todo casamento do ROLE_RE: as bordas são lookarounds (largura zero) e o único grupo é o casamento inteiro (20000 beads aleatórias no role_of, 0 divergências)
# EQUIVALENT 9e55fee9fa: `a.n < 1` -> `a.n < 0`: o único n que muda é 0, e com n = 0 qualquer --min cai em `a.min < 1` ou em `a.min > a.n` (min >= 1 > 0): as mesmas entradas são rejeitadas (grade n, min, days, oversample de -2 a 4 no main: 2401 entradas, 0 divergências)

echo
if [ "$FAILS" -eq 0 ]; then echo "agent-battery-corpus.selftest: tudo passou"; exit 0; fi
echo "agent-battery-corpus.selftest: $FAILS falha(s)"
exit 1
