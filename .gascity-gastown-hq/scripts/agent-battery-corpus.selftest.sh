#!/usr/bin/env bash
# Selftest de agent-battery-corpus.py (ga-hyp55ss, fatia 1). Repositório git e `bd` de mentira; nada toca a cidade nem a rede.
# Casos: acervo certo (+ meta + sha), cada motivo de exclusão contado, e as falhas de leitura que têm de dar o estado INERTE
# (git ilegível, bd mudo/ausente/vazio/com JSON podre, saída sem como gravar, poucas tarefas): nada escrito, acervo antigo intacto.
# Sai 0 = tudo passou.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/agent-battery-corpus.py"
W="$(mktemp -d "${TMPDIR:-/tmp}/abc-selftest.XXXXXX")"
trap 'rm -rf "$W"' EXIT
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

# bd de mentira: lê $FAKE_BD_DIR/<id>.json; FAKE_BD_MODE = mudo (rc 1) | podre (JSON quebrado) | vazio (rc 0, nada)
BDDIR="$W/beads-json"
mkdir -p "$BDDIR"
mk() { printf '{"id":"%s","title":"t %s","status":"%s","description":"%s","issue_type":"bug","assignee":"gastown.dog"}' "$1" "$1" "$2" "$3" >"$BDDIR/$1.json"; }
for b in aaa bbb ccc eee iii; do mk "ga-$b" closed "$DESC"; done
mk ga-ddd closed "Ligar para (31) 98765-4321 e conferir o saldo do lote inteiro do disco"
mk ga-hhh closed "Escrever para fulano@exemplo.com.br e conferir o saldo do lote inteiro do disco"
mk ga-ggg open "$DESC"
cat >"$W/bd" <<'EOF'
#!/usr/bin/env bash
[ "$1" = show ] || exit 2
case "${FAKE_BD_MODE:-}" in
  mudo) exit 1 ;;
  podre) echo '{"title": '; exit 0 ;;
  vazio) exit 0 ;;
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

# 1) caminho feliz: só ga-aaa serve
OUT="$W/out/tasks.jsonl"
S="$(run --out "$OUT" --n 10 --min 1 2>"$W/err")"
check "acervo certo: rc 0" "$?" 0
check "acervo certo: só ga-aaa" "$(ids "$OUT")" "ga-aaa"
check "contagem: selecionadas" "$(printf '%s' "$S" | field selecionadas)" 1
check "contagem: sem selftest" "$(printf '%s' "$S" | field excluidas.sem_selftest_ou_sem_producao)" 1
check "contagem: fora da allowlist" "$(printf '%s' "$S" | field excluidas.fora_da_allowlist)" 1
check "contagem: intercalada" "$(printf '%s' "$S" | field excluidas.intercalada)" 1
check "contagem: grande demais" "$(printf '%s' "$S" | field excluidas.grande_demais)" 1
check "contagem: dado pessoal (telefone + e-mail)" "$(printf '%s' "$S" | field excluidas.dado_pessoal)" 2
check "contagem: bead não fechada" "$(printf '%s' "$S" | field excluidas.bead_nao_fechada)" 1
check "contagem: sem bead no assunto" "$(printf '%s' "$S" | field excluidas.sem_bead_no_assunto)" 3
check "tarefa: fix_sha = commit da entrega" "$(python3 -I -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["fix_sha"])' "$OUT")" "$AAA_SHA"
check "tarefa: base_sha = pai do commit" "$(python3 -I -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["base_sha"])' "$OUT")" "$(git -C "$R" rev-parse "$AAA_SHA^")"
check "tarefa: critério é o selftest" "$(python3 -I -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["success"]["commands"][0])' "$OUT")" "bash scripts/aaa.selftest.sh"
check "meta: sha256 = do arquivo" "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]+".meta.json"))["sha256"])' "$OUT")" "$(shasum -a 256 "$OUT" | cut -d' ' -f1)"
H1="$(shasum -a 256 "$OUT" | cut -d' ' -f1)"
run --out "$OUT" --n 10 --min 1 >/dev/null 2>&1
check "determinismo: 2ª rodada, mesmo sha" "$(shasum -a 256 "$OUT" | cut -d' ' -f1)" "$H1"
check "sem lixo .tmp ao lado do acervo" "$(ls -A "$W/out" | grep -c '^\.tmp-corpus-')" 0

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

# 4) bead ilegível em minoria: segue, e CONTA (nunca some em silêncio)
rm "$BDDIR/ga-hhh.json"
S="$(run --out "$W/minoria/tasks.jsonl" --n 10 --min 1 2>/dev/null)"
check "minoria ilegível: rc 0" "$?" 0
check "minoria ilegível: contada" "$(printf '%s' "$S" | field excluidas.bead_ilegivel)" 1
check "minoria ilegível: ga-aaa continua" "$(ids "$W/minoria/tasks.jsonl")" "ga-aaa"

# 5) saída sem como gravar: rc 4 (um ARQUIVO no lugar da pasta)
echo x >"$W/arquivo"
run --out "$W/arquivo/tasks.jsonl" --n 10 --min 1 >/dev/null 2>"$W/err-saida"
check "saída impossível: rc 4" "$?" 4

echo
if [ "$FAILS" -eq 0 ]; then echo "agent-battery-corpus.selftest: tudo passou"; exit 0; fi
echo "agent-battery-corpus.selftest: $FAILS falha(s)"
exit 1
