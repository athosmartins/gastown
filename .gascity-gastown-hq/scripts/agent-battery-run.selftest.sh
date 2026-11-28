#!/usr/bin/env bash
# Selftest de agent-battery-run.py (ga-hyp55ss.1, fatia 2). Repositório git e `claude` de mentira; nada toca a cidade, a rede ou o claude real.
# Casos: caminho feliz (fail→pass, config sob teste, env limpo, worktree removido), agente que não conserta / trapaceia no selftest,
# descartes contados (passa na base, reprova no fix, selftest ausente/symlink), caminhos com cara de injeção de shell (recusados e contados,
# NADA executa), freio de tokens (PULADO, rc 6, ledger entre rodadas), saída do agente ilegível (cobra a reserva, nunca zero), timeout,
# infra repetida, ledger podre (rc 5), claude ausente (rc 8), rodada concorrente (rc 7), acervo adulterado/ausente/vazio, papéis, e (seção 16)
# o módulo em processo: defaults e prazos, funções puras nos limites, laço do main() com o run_task trocado por um roteiro.
# Sai 0 = tudo passou.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/agent-battery-run.py"
W="$(mktemp -d "${TMPDIR:-/tmp}/abr-selftest.XXXXXX")"
HOLD=""
trap '[ -n "$HOLD" ] && kill "$HOLD" 2>/dev/null; rm -rf "$W"' EXIT
FAILS=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (esperado '$3', veio '$2')"; fi; }
unset GC_CITY_PATH
mkdir -p "$W/tmp"
export TMPDIR="$W/tmp"

P=.city
R="$W/repo"
mkdir -p "$R/$P/scripts" "$R/$P/agents/dog-remote" "$R/$P/agents/gate-reviewer" "$R/.claude"
git -C "$R" init -q -b main
git -C "$R" config user.email t@t
git -C "$R" config user.name t
git -C "$R" config commit.gpgsign false
echo 'echo broken' >"$R/$P/scripts/aaa.sh"
echo 'echo fixed' >"$R/$P/scripts/bbb.sh"
echo 'echo broken' >"$R/$P/scripts/ccc.sh"
echo 'echo broken' >"$R/$P/scripts/lnk.sh"
echo VELHO >"$R/CLAUDE.md"
echo VELHO-CIDADE >"$R/$P/CLAUDE.md"
echo '{"v":"velha"}' >"$R/.claude/settings.json"
echo "PROMPT DOG v1" >"$R/$P/agents/dog-remote/prompt.template.md"
echo "PROMPT REVIEWER v1" >"$R/$P/agents/gate-reviewer/prompt.template.md"
git -C "$R" add -A && git -C "$R" commit -qm "chore: base"
BASE="$(git -C "$R" rev-parse HEAD)"
selftest() { printf '#!/usr/bin/env bash\n[ "$(bash "$(dirname "$0")/%s.sh")" = fixed ]\n' "$1" >"$R/$P/scripts/$1.selftest.sh"; }

selftest aaa && echo 'echo fixed' >"$R/$P/scripts/aaa.sh"
git -C "$R" add -A && git -C "$R" commit -qm "fix(ga-aaa): conserta"
A_SHA="$(git -C "$R" rev-parse HEAD)"
selftest bbb # bbb.sh já está certo na base: o selftest passa antes do fix
git -C "$R" add -A && git -C "$R" commit -qm "fix(ga-bbb): teste que nunca reprovou"
B_SHA="$(git -C "$R" rev-parse HEAD)"
selftest ccc # ccc.sh continua quebrado: o selftest reprova até no fix
git -C "$R" add -A && git -C "$R" commit -qm "fix(ga-ccc): fix que não conserta"
C_SHA="$(git -C "$R" rev-parse HEAD)"
ln -s aaa.selftest.sh "$R/$P/scripts/lnk.selftest.sh" # o selftest do fix é um symlink: nunca copiado
echo 'echo fixed' >"$R/$P/scripts/lnk.sh"
git -C "$R" add -A && git -C "$R" commit -qm "fix(ga-lnk): selftest é symlink"
L_SHA="$(git -C "$R" rev-parse HEAD)"
printf '#!/usr/bin/env bash\nexit 1\n' >"$R/$P/scripts/ddd.sh" && chmod +x "$R/$P/scripts/ddd.sh" # ddd: o selftest EXECUTA ddd.sh como último comando
printf '#!/usr/bin/env bash\n"$(dirname "$0")/ddd.sh"\n' >"$R/$P/scripts/ddd.selftest.sh"
git -C "$R" add -A && git -C "$R" commit -qm "chore: ddd quebrado"
D_BASE="$(git -C "$R" rev-parse HEAD)"
printf '#!/usr/bin/env bash\nexit 0\n' >"$R/$P/scripts/ddd.sh"
git -C "$R" add -A && git -C "$R" commit -qm "fix(ga-ddd): conserta"
D_SHA="$(git -C "$R" rev-parse HEAD)"
# a configuração sob teste (HEAD = main) difere da que a base tinha; CFG_C muda SÓ o .claude/ (a perna do overlay que nada mais afirma)
CFG1="$(git -C "$R" rev-parse HEAD)"
echo '{"v":"nova"}' >"$R/.claude/settings.json"
git -C "$R" add -A && git -C "$R" commit -qm "chore: só .claude"
CFG_C="$(git -C "$R" rev-parse HEAD)"
echo NOVO >"$R/CLAUDE.md"
echo NOVO-CIDADE >"$R/$P/CLAUDE.md"
echo "PROMPT DOG v2" >"$R/$P/agents/dog-remote/prompt.template.md"
git -C "$R" add -A && git -C "$R" commit -qm "chore: config nova"

mkline() { # id base fix role test prod [comando]
  python3 -I -c 'import json,sys
a = sys.argv[1:]
print(json.dumps({"task_id": a[0], "bead": a[0], "title": "t " + a[0], "description": "Corrigir " + a[0] + ": o script deve imprimir fixed",
  "issue_type": "bug", "role": a[3], "base_sha": a[1], "fix_sha": a[2], "commits": [], "prod_files": [a[5]], "test_files": [a[4]],
  "success": {"kind": "selftest-fail-to-pass", "commands": [a[6] if len(a) > 6 else "bash " + a[4]]}}))' "$@"
}
mkcorpus() { # $1 = arquivo; as linhas vêm do stdin; grava o .meta.json com o sha256 certo
  cat >"$1"
  python3 -I -c 'import hashlib,json,sys; json.dump({"sha256": hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest()}, open(sys.argv[1] + ".meta.json", "w"))' "$1"
}
aaa() { mkline "$1" "$BASE" "$A_SHA" "${2:-dog}" scripts/aaa.selftest.sh scripts/aaa.sh; }

# claude de mentira. Modo em $FAKE_MODE; deixa em $FAKE_LOG: count, prompt-N, argv-N, env-N, cwd-N, cfg-N (config vista), role-N (prompt de papel)
FAKE="$W/fake-claude"
cat >"$FAKE" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/fake-state"  # o executor só repassa PATH/credencial ao agente: FAKE_LOG e FAKE_MODE vêm deste arquivo, não do ambiente
L="$FAKE_LOG"; mkdir -p "$L"
n=$(( $(cat "$L/count" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$L/count"
cat >"$L/prompt-$n.txt"
printf '%s\n' "$@" >"$L/argv-$n.txt"
env >"$L/env-$n.txt"
pwd >"$L/cwd-$n.txt"
cat ../CLAUDE.md ./CLAUDE.md ../.claude/settings.json >"$L/cfg-$n.txt" 2>/dev/null
prev=""; for x in "$@"; do [ "$prev" = "--append-system-prompt-file" ] && cat "$x" >"$L/role-$n.txt"; prev="$x"; done
fix() { local tf; tf="$(grep -o 'scripts/[A-Za-z0-9_-]*\.selftest\.sh' "$L/prompt-$n.txt" | head -1)"; echo 'echo fixed' >"${tf%.selftest.sh}.sh"; }
U='"usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":270,"cache_read_input_tokens":5000}'
case "${FAKE_MODE:-ok}" in
  ok) fix; echo "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"total_cost_usd\":0.01,$U}" ;;
  nofix) echo "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,$U}" ;;
  cheat) tf="$(grep -o 'scripts/[A-Za-z0-9_-]*\.selftest\.sh' "$L/prompt-$n.txt" | head -1)"; echo 'exit 0' >"$tf"
         echo "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,$U}" ;;
  nousage) fix; echo '{"type":"result","subtype":"success","is_error":false}' ;;
  garbage) echo "isto não é json" ;;
  empty) : ;;
  iserr) echo "{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true,$U}" ;;
  maxturns) echo "{\"type\":\"result\",\"subtype\":\"error_max_turns\",\"is_error\":true,$U}" ;;
  rmprod) tf="$(grep -o 'scripts/[A-Za-z0-9_-]*\.selftest\.sh' "$L/prompt-$n.txt" | head -1)"; rm -f "${tf%.selftest.sh}.sh"
          echo "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,$U}" ;;
  dirtrap) tf="$(grep -o 'scripts/[A-Za-z0-9_-]*\.selftest\.sh' "$L/prompt-$n.txt" | head -1)"; rm -f "$tf"; mkdir "$tf"  # a restauração do selftest vai dar OSError
          echo "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,$U}" ;;
  hang) exec sleep 30 ;;
esac
EOF
chmod +x "$FAKE"

N=0
newcase() { N=$((N + 1)); ST="$W/st$N"; mkdir -p "$ST"; export FAKE_LOG="$W/log$N" FAKE_MODE="${1:-ok}"; printf 'FAKE_LOG=%q\nFAKE_MODE=%q\n' "$FAKE_LOG" "$FAKE_MODE" >"$W/fake-state"; OUT="$W/out$N.jsonl"; }
run() { python3 -I "$TOOL" --repo "$R" --prefix "$P" --state-dir "$ST" --claude "$FAKE" --config-ref main --day 2026-01-01 \
  --token-cap 10000000 --task-reserve-tokens 400 --agent-timeout 30 --selftest-timeout 30 --out "$OUT" "$@" >"$W/stdout" 2>"$W/stderr"; }
rec() { # arquivo task campo → valor (texto puro; true/false/null/número em JSON)
  python3 -I -c 'import json,sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    if r["task"] == sys.argv[2]:
        v = r.get(sys.argv[3], "<sem-campo>")
        print(v if isinstance(v, str) else json.dumps(v)); break
else:
    print("<sem-linha>")' "$@"
}
summ() { python3 -I -c 'import json,sys,functools; print(json.dumps(functools.reduce(lambda a,k:a[k], sys.argv[2].split("."), json.load(open(sys.argv[1])))))' "$OUT.summary.json" "$1"; }
ledger() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["tokens"])' "$ST/spend-2026-01-01.json"; }
calls() { cat "$FAKE_LOG/count" 2>/dev/null || echo 0; }
nlines() { wc -l <"$1" | tr -d ' '; }

# 1) caminho feliz
newcase ok
aaa ga-aaa | mkcorpus "$ST/tasks.jsonl"
export GC_SECRET_X=1 MY_API_TOKEN=2 ANTHROPIC_API_KEY=k3 SSH_AUTH_SOCK=/tmp/sock-x DATABASE_URL=pg://u:p@h/d AWS_SESSION=s1
run --tasks "$ST/tasks.jsonl" --out "" 2>/dev/null
RC=$?
unset GC_SECRET_X MY_API_TOKEN SSH_AUTH_SOCK DATABASE_URL AWS_SESSION
RUNS=("$ST"/runs/run-*.jsonl)
OUT="${RUNS[0]}"
check "feliz: rc 0" "$RC" 0
check "feliz: estado medida e ok true" "$(rec "$OUT" ga-aaa estado)/$(rec "$OUT" ga-aaa ok)" "medida/true"
check "feliz: tokens = entrada+saída+cache_creation (cache_read fora)" "$(rec "$OUT" ga-aaa tokens)" 300
check "feliz: papel dog" "$(rec "$OUT" ga-aaa papel)" dog
check "feliz: config_sha com 64 hex" "$(rec "$OUT" ga-aaa config_sha | grep -cE '^[0-9a-f]{64}$')" 1
check "feliz: linha tem task/papel/config_sha/ok/tokens/motivo" "$(python3 -I -c 'import json,sys; print(set(json.loads(open(sys.argv[1]).readline())) >= {"task","papel","config_sha","ok","tokens","motivo"})' "$OUT")" True
check "feliz: claude chamado 1 vez" "$(calls)" 1
check "feliz: prompt leva o enunciado da bead" "$(grep -c 'Corrigir ga-aaa' "$FAKE_LOG/prompt-1.txt")" 1
check "feliz: prompt cita o selftest" "$(grep -c 'scripts/aaa.selftest.sh' "$FAKE_LOG/prompt-1.txt")" 1
check "feliz: argv traz prompt de papel, teto USD, sem sessão e só a config do projeto" \
  "$(grep -c -x -e '--append-system-prompt-file' -e '--max-budget-usd' -e '--no-session-persistence' -e '--setting-sources' -e project "$FAKE_LOG/argv-1.txt")" 5
check "feliz: prompt de papel é o do --config-ref (v2)" "$(cat "$FAKE_LOG/role-1.txt")" "PROMPT DOG v2"
check "feliz: config vista é a nova (CLAUDE.md, <prefixo>/CLAUDE.md e .claude/settings.json), não a velha da base" \
  "$(grep -c NOVO "$FAKE_LOG/cfg-1.txt")/$(grep -c VELHO "$FAKE_LOG/cfg-1.txt")/$(grep -c '"v":"nova"' "$FAKE_LOG/cfg-1.txt")/$(grep -c '"v":"velha"' "$FAKE_LOG/cfg-1.txt")" "2/0/1/0"
check "feliz: duracao_s numérica na linha que chamou o agente" "$(rec "$OUT" ga-aaa duracao_s | grep -cE '^[0-9]+(\.[0-9]+)?$')" 1
check "feliz: env do agente tem a credencial do claude" "$(grep -c '^ANTHROPIC_API_KEY=k3$' "$FAKE_LOG/env-1.txt")" 1
check "feliz: env do agente sem GC_*/TOKEN" "$(grep -c -e '^GC_SECRET_X=' -e '^MY_API_TOKEN=' "$FAKE_LOG/env-1.txt")" 0
check "feliz: env do agente por lista de permitidos (sem SSH_AUTH_SOCK/DATABASE_URL/AWS_*, nomes que a lista de proibidos não pegava)" "$(grep -c -e '^SSH_AUTH_SOCK=' -e '^DATABASE_URL=' -e '^AWS_SESSION=' "$FAKE_LOG/env-1.txt")" 0
check "feliz: com credencial em env, HOME e TMPDIR são o diretório descartável (não o HOME do operador)" "$(grep -c -e "^HOME=$HOME\$" "$FAKE_LOG/env-1.txt")/$(grep -c '^HOME=.*/battery-[^/]*/home$' "$FAKE_LOG/env-1.txt")/$(grep -c '^TMPDIR=.*/battery-[^/]*/home$' "$FAKE_LOG/env-1.txt")" "0/1/1"
# só a linha DEPOIS de --allowedTools: o argv inteiro leva o caminho do prompt de papel sob o TMPDIR, que pode conter "git" (o scratchpad, o layout do nó)
check "feliz: o agente só pode rodar o próprio selftest (nada de bash scripts/*, cat, git)" "$(grep -A1 -x -e '--allowedTools' "$FAKE_LOG/argv-1.txt" | tail -1)" 'Bash(bash scripts/aaa.selftest.sh:*)'
check "feliz: ledger 300" "$(ledger)" 300
check "feliz: nenhum worktree sobrando" "$(git -C "$R" worktree list | wc -l | tr -d ' ')" 1
check "feliz: sem .partial" "$(ls "$ST/runs" | grep -c partial)" 0
check "feliz: sem scratch sobrando" "$(ls "$W/tmp" | wc -l | tr -d ' ')" 0
check "feliz: taxa do papel dog = 1.0" "$(summ por_papel.dog.taxa)" 1.0
check "feliz: repo intacto" "$(git -C "$R" status --porcelain | wc -l | tr -d ' ')" 0

# 1b) sem credencial em env: sem --agent-real-home nada roda (rc 8, claude não é chamado); com ele, HOME é o real e o resto segue por lista de permitidos
newcase ok
aaa ga-aaa | mkcorpus "$ST/tasks.jsonl"
( unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN; run --tasks "$ST/tasks.jsonl" )
check "sem credencial e sem --agent-real-home: rc 8, claude não chamado" "$?/$(calls)" "8/0"
( unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN; export SSH_AUTH_SOCK=/tmp/sock-x; run --tasks "$ST/tasks.jsonl" --agent-real-home )
check "--agent-real-home: rc 0" "$?" 0
check "--agent-real-home: HOME é o real, sem SSH_AUTH_SOCK nem credencial" "$(grep -c -e "^HOME=$HOME\$" "$FAKE_LOG/env-1.txt")/$(grep -c -e '^SSH_AUTH_SOCK=' -e '^ANTHROPIC_API_KEY=' "$FAKE_LOG/env-1.txt")" "1/0"

# 2) agente que não conserta / 3) agente que trapaceia editando o selftest
for m in nofix cheat; do
  newcase $m
  aaa ga-aaa | mkcorpus "$ST/tasks.jsonl"
  run --tasks "$ST/tasks.jsonl"
  check "$m: rc 0" "$?" 0
  check "$m: medida, ok false" "$(rec "$OUT" ga-aaa estado)/$(rec "$OUT" ga-aaa ok)/$(rec "$OUT" ga-aaa motivo)" "medida/false/selftest_reprova_apos_agente"
  check "$m: tokens cobrados mesmo reprovando" "$(ledger)" 300
done

# 4) descartes contados: passa na base, reprova no fix, selftest é symlink
newcase ok
{ mkline ga-bbb "$(git -C "$R" rev-parse "$B_SHA^")" "$B_SHA" dog scripts/bbb.selftest.sh scripts/bbb.sh
  mkline ga-ccc "$(git -C "$R" rev-parse "$C_SHA^")" "$C_SHA" dog scripts/ccc.selftest.sh scripts/ccc.sh
  mkline ga-lnk "$(git -C "$R" rev-parse "$L_SHA^")" "$L_SHA" dog scripts/lnk.selftest.sh scripts/lnk.sh
  mkline ga-nob "$(printf '%040d' 0)" "$A_SHA" dog scripts/aaa.selftest.sh scripts/aaa.sh; } | mkcorpus "$ST/tasks.jsonl"  # sha bem formado que o repo não tem
run --tasks "$ST/tasks.jsonl"
check "descartes: rc 0" "$?" 0
check "descartes: passa na base" "$(rec "$OUT" ga-bbb estado)/$(rec "$OUT" ga-bbb motivo)" "descartada/selftest_passa_na_base"
check "descartes: reprova no fix" "$(rec "$OUT" ga-ccc motivo)" selftest_reprova_no_fix
check "descartes: symlink não vale como selftest" "$(rec "$OUT" ga-lnk motivo)" selftest_ausente_no_fix
check "descartes: base que o git não tem = o git respondeu erro (fato da tarefa), nunca a base 'passou'" "$(rec "$OUT" ga-nob estado)/$(rec "$OUT" ga-nob motivo)" "descartada/checkout_base_falhou"
check "descartes: contados no resumo" "$(summ por_estado.descartada)" 4
check "descartes: motivo contado" "$(summ descartes.selftest_passa_na_base)" 1
check "descartes: agente nunca chamado" "$(calls)" 0
check "descartes: ok null (não entra na taxa)" "$(rec "$OUT" ga-bbb ok)" null

# 5) caminhos/campos com cara de injeção: recusados, contados, NADA executa
newcase ok
{ mkline ga-i1 "$BASE" "$A_SHA" dog "scripts/\$(touch $W/PWNED).selftest.sh" scripts/aaa.sh
  mkline ga-i2 "$BASE" "$A_SHA" dog "scripts/x;touch $W/PWNED.selftest.sh" scripts/aaa.sh
  mkline ga-i3 "$BASE" "$A_SHA" dog "../escape.selftest.sh" scripts/aaa.sh
  mkline ga-i4 "$BASE" "$A_SHA" dog "scripts/a b.selftest.sh" scripts/aaa.sh
  mkline ga-i5 "$BASE" "$A_SHA" dog "/etc/x.selftest.sh" scripts/aaa.sh
  mkline ga-i6 "$BASE" "$A_SHA" dog "-x.selftest.sh" scripts/aaa.sh
  mkline ga-i7 "$BASE" "$A_SHA" dog scripts/aaa.selftest.sh "scripts/a;b.sh"
  mkline ga-i8 "$BASE" "$A_SHA" dog scripts/aaa.selftest.sh scripts/aaa.sh "bash scripts/aaa.selftest.sh; touch $W/PWNED"
  mkline ga-i9 "HEAD; touch $W/PWNED" "$A_SHA" dog scripts/aaa.selftest.sh scripts/aaa.sh
  mkline "ga-ia;touch" "$BASE" "$A_SHA" dog scripts/aaa.selftest.sh scripts/aaa.sh
  mkline ga-ie "$BASE" "$A_SHA" dog "scripts/x;touch-PWNED.selftest.sh" scripts/aaa.sh
  mkline ga-if "$BASE" "$A_SHA" dog "scripts/\$(id).selftest.sh" scripts/aaa.sh
  mkline ga-ig "$BASE" "$A_SHA" dog 'scripts/`id`.selftest.sh' scripts/aaa.sh
  mkline ga-ib "$BASE" "$A_SHA" dog "scripts/dir//x.selftest.sh" scripts/aaa.sh
  mkline ga-ic "$BASE" "$A_SHA" dog "scripts/./x.selftest.sh" scripts/aaa.sh
  mkline ga-n1 "$BASE" "$A_SHA" dog $'scripts/aaa.selftest.sh\n' scripts/aaa.sh
  mkline ga-n2 "$BASE"$'\n' "$A_SHA" dog scripts/aaa.selftest.sh scripts/aaa.sh
  mkline $'ga-n3\n' "$BASE" "$A_SHA" dog scripts/aaa.selftest.sh scripts/aaa.sh
  python3 -I -c 'import json,sys; b,a=sys.argv[1:]; print(json.dumps({"task_id":"ga-id","role":["dog"],"base_sha":b,"fix_sha":a,"title":"t","description":"d","prod_files":["scripts/aaa.sh"],"test_files":"scripts/aaa.selftest.sh"}))' "$BASE" "$A_SHA"
  echo '"uma-string"'; } | mkcorpus "$ST/tasks.jsonl"
run --tasks "$ST/tasks.jsonl"
check "injeção: rc 0" "$?" 0
check "injeção: i1 \$(...) recusado" "$(rec "$OUT" ga-i1 motivo)" "argumento_invalido:test_files"
check "injeção: i2 ';' recusado" "$(rec "$OUT" ga-i2 motivo)" "argumento_invalido:test_files"
check "injeção: i3 '..' recusado" "$(rec "$OUT" ga-i3 motivo)" "argumento_invalido:test_files"
check "injeção: i4 espaço recusado" "$(rec "$OUT" ga-i4 motivo)" "argumento_invalido:test_files"
check "injeção: i5 absoluto recusado" "$(rec "$OUT" ga-i5 motivo)" "argumento_invalido:test_files"
check "injeção: i6 começa com '-' recusado" "$(rec "$OUT" ga-i6 motivo)" "argumento_invalido:test_files"
check "injeção: i7 prod_files ruim recusado" "$(rec "$OUT" ga-i7 motivo)" "argumento_invalido:prod_files"
check "injeção: i9 sha com ';' recusado" "$(rec "$OUT" ga-i9 motivo)" "argumento_invalido:base_sha"
check "injeção: task_id com ';' recusado" "$(rec "$OUT" "ga-ia;touch" motivo)" "argumento_invalido:task_id"
check "injeção: '//' e '/./' recusados" "$(rec "$OUT" ga-ib motivo)/$(rec "$OUT" ga-ic motivo)" "argumento_invalido:test_files/argumento_invalido:test_files"
check "injeção: role lista / test_files string recusados sem derrubar" "$(rec "$OUT" ga-id estado)" descartada
check "injeção: i8 (success.commands com ';') NÃO é usado: roda só o argv e fica sem erro" "$(rec "$OUT" ga-i8 estado)/$(rec "$OUT" ga-i8 ok)" "medida/true"
check "injeção: nada foi executado (PWNED não existe)" "$([ -e "$W/PWNED" ] && echo existe || echo nao)" nao
check "injeção: i-e/i-f/i-g (;, $(), crase, sem barra dupla) recusados" "$(rec "$OUT" ga-ie motivo)/$(rec "$OUT" ga-if motivo)/$(rec "$OUT" ga-ig motivo)" "argumento_invalido:test_files/argumento_invalido:test_files/argumento_invalido:test_files"
check "injeção: '\\n' final (o \$ da regex aceitava) recusado no caminho, no sha e no task_id" \
  "$(rec "$OUT" ga-n1 motivo)/$(rec "$OUT" ga-n2 motivo)/$(rec "$OUT" $'ga-n3\n' motivo)" "argumento_invalido:test_files/argumento_invalido:base_sha/argumento_invalido:task_id"
check "injeção: 19 refugos contados (inclui a linha que não é objeto)" "$(summ por_estado.descartada)" 19
check "injeção: só o i8 chegou no agente" "$(calls)" 1

# 6) freio de tokens
newcase ok
{ aaa ga-b1; aaa ga-b2; aaa ga-b3; aaa ga-b4; } | mkcorpus "$ST/tasks.jsonl"
run --tasks "$ST/tasks.jsonl" --token-cap 800 --task-reserve-tokens 400
check "freio: rc 6" "$?" 6
check "freio: 2 medidas e 2 puladas" "$(summ por_estado.medida)/$(summ por_estado.pulada)" "2/2"
check "freio: motivo teto_de_tokens" "$(rec "$OUT" ga-b3 motivo)/$(rec "$OUT" ga-b4 estado)" "teto_de_tokens/pulada"
check "freio: agente chamado só 2 vezes" "$(calls)" 2
check "freio: gasto 600 <= teto" "$(ledger)" 600
check "freio: resumo diz o freio" "$(summ freio)" '"teto_de_tokens"'
check "freio: saída parcial completa (4 linhas)" "$(nlines "$OUT")" 4
OUT="$W/out${N}b.jsonl"
run --tasks "$ST/tasks.jsonl" --token-cap 800 --task-reserve-tokens 400
check "freio: 2ª rodada do mesmo dia soma o ledger e já para (rc 6)" "$?/$(calls)/$(ledger)" "6/2/600"
OUT="$W/out${N}c.jsonl"
run --tasks "$ST/tasks.jsonl" --token-cap 800 --task-reserve-tokens 400 --day 2026-01-02
check "freio: outro dia = ledger novo, volta a rodar" "$(calls)" 4

# 7) saída do agente ilegível/sem uso: cobra a reserva, nunca zero; infra não entra na taxa
for m in garbage empty nousage; do
  newcase $m
  aaa ga-aaa | mkcorpus "$ST/tasks.jsonl"
  run --tasks "$ST/tasks.jsonl"
  check "$m: ledger cobra a reserva (400)" "$(ledger)" 400
done
newcase garbage
aaa ga-aaa | mkcorpus "$ST/tasks.jsonl"
run --tasks "$ST/tasks.jsonl"
check "ilegível: estado infra, ok null" "$(rec "$OUT" ga-aaa estado)/$(rec "$OUT" ga-aaa ok)/$(rec "$OUT" ga-aaa motivo)" "infra/null/saida_do_agente_ilegivel"
newcase nousage
aaa ga-aaa | mkcorpus "$ST/tasks.jsonl"
run --tasks "$ST/tasks.jsonl"
check "sem uso: medida ok true com tokens null" "$(rec "$OUT" ga-aaa ok)/$(rec "$OUT" ga-aaa tokens)/$(rec "$OUT" ga-aaa tokens_cobrados)" "true/null/400"

# 8) erro do agente x max_turns x timeout
newcase iserr
aaa ga-aaa | mkcorpus "$ST/tasks.jsonl"
run --tasks "$ST/tasks.jsonl"
check "is_error: infra com motivo e tokens" "$(rec "$OUT" ga-aaa estado)/$(rec "$OUT" ga-aaa motivo)/$(rec "$OUT" ga-aaa tokens)" "infra/agente_erro:error_during_execution/300"
newcase maxturns
aaa ga-aaa | mkcorpus "$ST/tasks.jsonl"
run --tasks "$ST/tasks.jsonl"
check "max_turns: falha medida (não é infra)" "$(rec "$OUT" ga-aaa estado)/$(rec "$OUT" ga-aaa ok)/$(rec "$OUT" ga-aaa motivo)" "medida/false/error_max_turns"
newcase hang
aaa ga-aaa | mkcorpus "$ST/tasks.jsonl"
run --tasks "$ST/tasks.jsonl" --agent-timeout 1
check "timeout: falha medida, tokens desconhecidos cobram a reserva" \
  "$(rec "$OUT" ga-aaa estado)/$(rec "$OUT" ga-aaa ok)/$(rec "$OUT" ga-aaa motivo)/$(rec "$OUT" ga-aaa tokens)/$(ledger)" "medida/false/agente_timeout/null/400"
check "timeout: duracao_s gravada (separa pane da API de prompt que gira)" "$(rec "$OUT" ga-aaa duracao_s | grep -cE '^[0-9]+(\.[0-9]+)?$')" 1
check "timeout: nenhum worktree sobrando" "$(git -C "$R" worktree list | wc -l | tr -d ' ')" 1

# 8b) o claude NÃO INICIA (shebang quebrado: o shutil.which da largada aceita o arquivo): infra, nunca timeout medida; sem reserva; conta no freio de infra
newcase ok
printf '#!/nonexistent/interp\n' >"$W/broken-claude" && chmod +x "$W/broken-claude"
{ aaa ga-n1; aaa ga-n2; aaa ga-n3; aaa ga-n4; } | mkcorpus "$ST/tasks.jsonl"
run --tasks "$ST/tasks.jsonl" --claude "$W/broken-claude"
RC=$?
check "não iniciou: infra/agente_nao_iniciou, ok null, tokens_cobrados ausente" "$(rec "$OUT" ga-n1 estado)/$(rec "$OUT" ga-n1 motivo)/$(rec "$OUT" ga-n1 ok)/$(rec "$OUT" ga-n1 tokens_cobrados)" "infra/agente_nao_iniciou/null/<sem-campo>"
check "não iniciou: ledger sem gasto, rc 8 no 3º, o resto pulado" "$RC/$([ -e "$ST/spend-2026-01-01.json" ] && echo gravou || echo nada)/$(summ por_estado)" '8/nada/{"infra": 3, "pulada": 1}'

# 8c) OSError depois do agente (a restauração do selftest esbarra num diretório): a TAREFA vira infra, a rodada segue, a reserva é cobrada
newcase dirtrap
{ aaa ga-o1; aaa ga-o2; } | mkcorpus "$ST/tasks.jsonl"
run --tasks "$ST/tasks.jsonl"
RC=$?
check "erro de E/S na tarefa: rc 0, 2 linhas infra/erro_de_io, ledger 800, sem worktree" \
  "$RC/$(nlines "$OUT")/$(rec "$OUT" ga-o1 estado)/$(rec "$OUT" ga-o1 motivo | cut -c1-10)/$(ledger)/$(git -C "$R" worktree list | wc -l | tr -d ' ')" "0/2/infra/erro_de_io/800/1"

# 8d) o agente apaga o que o selftest executa (127 DEPOIS do agente): falha medida, não infra que sumiria da taxa
newcase rmprod
mkline ga-ddd "$D_BASE" "$D_SHA" dog scripts/ddd.selftest.sh scripts/ddd.sh | mkcorpus "$ST/tasks.jsonl"
run --tasks "$ST/tasks.jsonl"
check "127 após o agente: medida, ok false" "$(rec "$OUT" ga-ddd estado)/$(rec "$OUT" ga-ddd ok)/$(rec "$OUT" ga-ddd motivo)" "medida/false/selftest_reprova_apos_agente"

# 8e) só uma MEDIDA zera a sequência de infra: descartada no meio não "prova" que o agente voltou
newcase garbage
{ aaa ga-e1; mkline ga-d1 "$BASE" "$A_SHA" dog "scripts/a b.selftest.sh" scripts/aaa.sh; aaa ga-e2
  mkline ga-d2 "$BASE" "$A_SHA" dog "scripts/a b.selftest.sh" scripts/aaa.sh; aaa ga-e3; aaa ga-e4; } | mkcorpus "$ST/tasks.jsonl"
run --tasks "$ST/tasks.jsonl" --infra-stop 3
check "infra com descartes no meio: rc 8 na 3ª infra, 3 chamadas, a 4ª pulada" "$?/$(calls)/$(rec "$OUT" ga-e4 motivo)" "8/3/infra_repetida"

# 8f) o rc de run_capped/suite_state/git_fail: não-iniciou ≠ timeout ≠ erro do git (carrega o módulo pelo caminho)
UNIT="$(python3 -I -c 'import importlib.machinery as m, importlib.util as u, sys
spec = u.spec_from_loader("abr", m.SourceFileLoader("abr", sys.argv[1])); abr = u.module_from_spec(spec); spec.loader.exec_module(abr)
c = abr.Ctx(); c.config_sha = {}
gf = lambda rc: (lambda r: r["estado"] + "/" + r["motivo"])(abr.git_fail(c, {"task_id": "ga-x"}, "dog", rc, "checkout_fix_falhou"))
print(abr.run_capped([sys.argv[2]], None, {}, 5)[0] == abr.NOT_STARTED, abr.run_capped(["sleep", "30"], None, {"PATH": "/bin:/usr/bin"}, 1)[0] is None,
      abr.suite_state([abr.NOT_STARTED, 0]), abr.suite_state([abr.NOT_STARTED, 1]), abr.suite_state([127], True), abr.suite_state([127]),
      gf(abr.NOT_STARTED), gf(None), gf(128))' "$TOOL" "$W/broken-claude" 2>&1)"
check "run_capped/suite_state/git_fail distinguem não-iniciou, timeout e erro" "$UNIT" \
  "True True indeterminado fail fail indeterminado infra/git_nao_iniciou infra/git_estourou_prazo descartada/checkout_fix_falhou"

# 8g) o ledger é relido DEPOIS do lock: outra rodada que grava entre a 1ª leitura e o flock não pode ser sobrescrita
newcase ok
aaa ga-aaa | mkcorpus "$ST/tasks.jsonl"
python3 -I -c 'import importlib.machinery as m, importlib.util as u, sys, fcntl
spec = u.spec_from_loader("abr", m.SourceFileLoader("abr", sys.argv[1])); abr = u.module_from_spec(spec); spec.loader.exec_module(abr)
real, LED = fcntl.flock, sys.argv[2]
def racy(f, op):  # outra rodada termina exatamente aqui e grava 900 no ledger
    open(LED, "w").write("{\"date\": \"2026-01-01\", \"tokens\": 900}\n")
    return real(f, op)
abr.fcntl = type("F", (), {"flock": staticmethod(racy), "LOCK_EX": fcntl.LOCK_EX, "LOCK_NB": fcntl.LOCK_NB})
sys.argv = ["abr"] + sys.argv[3:]
sys.exit(abr.main())' "$TOOL" "$ST/spend-2026-01-01.json" --repo "$R" --prefix "$P" --state-dir "$ST" --claude "$FAKE" --config-ref main --day 2026-01-01 \
  --token-cap 1000 --task-reserve-tokens 400 --out "$OUT" --tasks "$ST/tasks.jsonl" >"$W/stdout" 2>"$W/stderr"
check "ledger relido com o lock: o gasto da outra rodada (900) vale, a rodada para (rc 6) sem sobrescrever" "$?/$(calls)/$(ledger)" "6/0/900"

# 9) infra repetida para a rodada
newcase garbage
{ aaa ga-c1; aaa ga-c2; aaa ga-c3; aaa ga-c4; aaa ga-c5; } | mkcorpus "$ST/tasks.jsonl"
run --tasks "$ST/tasks.jsonl" --infra-stop 3
check "infra repetida: rc 8, 3 chamadas, resto pulado" "$?/$(calls)/$(rec "$OUT" ga-c4 motivo)/$(summ por_estado.pulada)" "8/3/infra_repetida/2"

# 10) ledger ilegível: rc 5 e nada roda; ledger válido pré-existente é somado
for body in '{nao e json' '{"tokens":"x"}' '{"tokens":-5}' ''; do
  newcase ok
  aaa ga-aaa | mkcorpus "$ST/tasks.jsonl"
  printf '%s' "$body" >"$ST/spend-2026-01-01.json"
  run --tasks "$ST/tasks.jsonl"
  check "ledger '$body': rc 5, nada roda, sem saída" "$?/$(calls)/$([ -e "$OUT" ] && echo saiu || echo nada)" "5/0/nada"
done
newcase ok
aaa ga-aaa | mkcorpus "$ST/tasks.jsonl"
echo '{"tokens":50}' >"$ST/spend-2026-01-01.json"
run --tasks "$ST/tasks.jsonl"
check "ledger válido é somado" "$(ledger)" 350

# 11) claude ausente (rc 8) · verify-only não precisa dele · dry-run não grava nada
newcase ok
aaa ga-aaa | mkcorpus "$ST/tasks.jsonl"
run --tasks "$ST/tasks.jsonl" --claude "$W/nao-existe"
check "claude ausente: rc 8, nada gravado" "$?/$([ -e "$OUT" ] && echo saiu || echo nada)" "8/nada"
{ mkline ga-aaa "$BASE" "$A_SHA" dog scripts/aaa.selftest.sh scripts/aaa.sh
  mkline ga-bbb "$(git -C "$R" rev-parse "$B_SHA^")" "$B_SHA" dog scripts/bbb.selftest.sh scripts/bbb.sh; } | mkcorpus "$ST/tasks.jsonl"
run --tasks "$ST/tasks.jsonl" --claude "$W/nao-existe" --verify-only
check "verify-only: rc 0 sem claude" "$?" 0
check "verify-only: verificada / descartada" "$(rec "$OUT" ga-aaa estado)/$(rec "$OUT" ga-bbb estado)" "verificada/descartada"
check "verify-only: não grava ledger" "$([ -e "$ST/spend-2026-01-01.json" ] && echo gravou || echo nao)" nao
OUT="$W/out${N}d.jsonl"
run --tasks "$ST/tasks.jsonl" --dry-run
check "dry-run: rc 0, imprime plano, não grava" "$?/$(grep -c '"tarefas": 2' "$W/stdout")/$([ -e "$OUT" ] && echo saiu || echo nada)" "0/1/nada"

# 12) rodada concorrente
newcase ok
aaa ga-aaa | mkcorpus "$ST/tasks.jsonl"
python3 -I -c 'import fcntl,sys,time; f=open(sys.argv[1],"w"); fcntl.flock(f, fcntl.LOCK_EX); print("preso", flush=True); time.sleep(60)' "$ST/run.lock" >"$W/hold.out" &
HOLD=$!
for _ in $(seq 1 50); do grep -q preso "$W/hold.out" 2>/dev/null && break; sleep 0.1; done
run --tasks "$ST/tasks.jsonl"
check "lock ocupado: rc 7, nada roda" "$?/$(calls)" "7/0"
kill "$HOLD" 2>/dev/null; HOLD=""

# 13) acervo: adulterado, ausente, vazio, linha podre, --only/--limit
newcase ok
aaa ga-aaa | mkcorpus "$ST/tasks.jsonl"
echo '{"task_id":"ga-zzz"}' >>"$ST/tasks.jsonl"
run --tasks "$ST/tasks.jsonl"
check "acervo adulterado (sha ≠ meta): rc 2" "$?/$(calls)" "2/0"
run --tasks "$ST/nao-existe.jsonl"
check "acervo ausente: rc 2" "$?" 2
: | mkcorpus "$ST/vazio.jsonl"
run --tasks "$ST/vazio.jsonl"
check "acervo vazio: rc 3" "$?" 3
echo 'isso não é json' >"$ST/podre.jsonl"
aaa ga-aaa >>"$ST/podre.jsonl"
aaa ga-aab >>"$ST/podre.jsonl"
run --tasks "$ST/podre.jsonl" --only ga-aaa
check "linha podre contada, --only filtra" "$?/$(summ linhas_ilegiveis)/$(nlines "$OUT")" "0/1/1"
OUT="$W/out${N}l.jsonl"
run --tasks "$ST/podre.jsonl" --limit 1
check "--limit 1 roda uma só" "$(nlines "$OUT")" 1
newcase ok
aaa ga-u1 | python3 -I -c 'import sys; sys.stdout.buffer.write(sys.stdin.buffer.read().decode().replace("Corrigir", "Corrigir \u2028 \u2029 \u0085").encode())' | mkcorpus "$ST/tasks.jsonl"
run --tasks "$ST/tasks.jsonl"
check "U+2028/2029/0085 crus (o produtor grava ensure_ascii=False): 1 tarefa inteira, 0 ilegíveis" "$(summ linhas_ilegiveis)/$(summ tarefas)/$(rec "$OUT" ga-u1 estado)" "0/1/medida"

# 14) papéis: sem prompt → pulada; --as-role troca o prompt; config_sha muda com a configuração e com o papel
newcase ok
{ aaa ga-r1 outro; aaa ga-r2 wa-worker; aaa ga-r3 dog; } | mkcorpus "$ST/tasks.jsonl"
run --tasks "$ST/tasks.jsonl"
check "papel sem prompt: pulada, sem chamar o agente" "$(rec "$OUT" ga-r1 motivo)/$(rec "$OUT" ga-r2 motivo)/$(calls)" "papel_sem_prompt/papel_sem_prompt/1"
newcase ok
aaa ga-aaa | mkcorpus "$ST/tasks.jsonl"
run --tasks "$ST/tasks.jsonl" --as-role reviewer
check "--as-role reviewer: papel e prompt do reviewer" "$(rec "$OUT" ga-aaa papel)/$(cat "$FAKE_LOG/role-1.txt")" "reviewer/PROMPT REVIEWER v1"
cfgsha() { local r="$1"; shift; run --tasks "$ST/tasks.jsonl" --dry-run "$@"; python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["config_sha"][sys.argv[2]])' "$W/stdout" "$r"; }
S_NEW="$(cfgsha dog)"
S_NEW2="$(cfgsha dog)"
S_OLD="$(cfgsha dog --config-ref "$CFG1")"
S_REV="$(cfgsha reviewer --as-role reviewer)"
check "config_sha determinístico na mesma configuração" "$([ -n "$S_NEW" ] && [ "$S_NEW" = "$S_NEW2" ] && echo igual || echo diferente)" igual
check "config_sha muda quando a configuração muda" "$([ -n "$S_OLD" ] && [ "$S_OLD" != "$S_NEW" ] && echo muda || echo igual)" muda
S_C="$(cfgsha dog --config-ref "$CFG_C")"
check "config_sha muda quando SÓ o .claude/ muda (a perna do overlay que os outros 3 arquivos escondiam)" "$([ -n "$S_C" ] && [ "$S_C" != "$S_OLD" ] && echo muda || echo igual)" muda
check "config_sha muda de papel para papel" "$([ -n "$S_REV" ] && [ "$S_REV" != "$S_NEW" ] && echo muda || echo igual)" muda
# só o prompt do dog muda (um commit que sai de main logo depois): o CLAUDE.md e o .claude/ iguais não escondem mais a perna do blob do prompt
MAIN0="$(git -C "$R" rev-parse HEAD)"; echo "PROMPT DOG v3" >"$R/$P/agents/dog-remote/prompt.template.md"
git -C "$R" commit -qam "chore: só o prompt do dog" && PV3="$(git -C "$R" rev-parse HEAD)"; git -C "$R" reset -q --hard "$MAIN0"
S_P="$(cfgsha dog --config-ref "${PV3:-nao-existe}")"
check "config_sha muda quando SÓ o prompt do papel muda" "$([ -n "$S_P" ] && [ "$S_P" != "$S_NEW" ] && echo muda || echo igual)" muda

# 15) uso errado
newcase ok
aaa ga-aaa | mkcorpus "$ST/tasks.jsonl"
run --tasks "$ST/tasks.jsonl" --token-cap 0
check "teto 0: rc 2" "$?" 2
run --tasks "$ST/tasks.jsonl" --config-ref nao-existe-ref
check "config-ref que não resolve: rc 2" "$?" 2
run --tasks "$ST/tasks.jsonl" --as-role papel-inventado
check "--as-role desconhecido: rc 2" "$?" 2
run --tasks "$ST/tasks.jsonl" --repo "$R/$P"
check "--repo que não é a raiz do git: rc 2" "$?" 2

# 16) em processo (ga-mdne1az, lastro hq-mutants): o que o ponta a ponta não alcança, com o módulo carregado pelo caminho. (a) UMA rodada de verdade sem
#     flag de teto nem de prazo, com um relógio de mentira e o run_capped/subprocess.run anotando o que recebem e repassando ao de verdade: os DEFAULTS e a
#     duração; (b) as funções puras nos limites;
#     (c) o laço do main() com run_task trocado por um roteiro (ledger, freio, resumo, OSError antes/depois do agente), sem git nem agente por tarefa.
# EQUIVALENT fcd4a8dbd7: `text=True` -> `False` no Popen do run_capped: o `errors="replace"` da mesma chamada já liga o modo texto do subprocess (Popen: text_mode = encoding or errors or text or universal_newlines), então rc, stdout, stderr e os tipos saem iguais; medido em 12 comandos reais (stdin com acento e CRLF, bytes inválidos, 200 KB, prazo estourado, binário que não existe) em python 3.12.3 e 3.9.25: 0 divergências, com um controle (sem text nem errors) que diverge em 10
newcase garbage
aaa ga-aaa | mkcorpus "$ST/tasks.jsonl"
mkdir -p "$W/unit" && printf '#!/nonexistent/interp\n' >"$W/unit/broken-claude" && chmod +x "$W/unit/broken-claude"
PYU='
import contextlib, importlib.machinery as m, importlib.util as u, io, json, os, shutil, subprocess, sys, tempfile, time
sys.dont_write_bytecode = True
TOOL, REPO, PFX, WD, FAKE, STATE, TASKS, BROKEN = sys.argv[1:9]
spec = u.spec_from_loader("abr", m.SourceFileLoader("abr", TOOL)); abr = u.module_from_spec(spec); spec.loader.exec_module(abr)
os.environ["ANTHROPIC_API_KEY"] = "k"
ENV0, BAD = dict(os.environ), [0]
def reset():
    os.environ.clear(); os.environ.update(ENV0)
def chk(name, got, want):
    try:
        g = got() if callable(got) else got
    except BaseException as e:
        g = "raised " + type(e).__name__
    BAD[0] += g != want
    print(("ok   " if g == want else "FAIL ") + name + ("" if g == want else " (esperado %r, veio %r)" % (want, g)))
# vazio -> "" e a checagem que o espera reprova; falhou/ilegivel -> a excecao vira "raised X" no chk, nunca um valor que uma checagem aceite
def txt(p):
    with open(p, encoding="utf-8") as f:
        return f.read()
def recs(p):
    return [json.loads(l) for l in txt(p).splitlines()]
def main_rc(argv):
    so, se, old = io.StringIO(), io.StringIO(), sys.argv
    sys.argv = ["abr"] + argv
    try:
        with contextlib.redirect_stdout(so), contextlib.redirect_stderr(se):
            try:
                rc = abr.main()
            except SystemExit as e:
                rc = e.code
    finally:
        sys.argv = old
    return rc, so.getvalue(), se.getvalue()
def safe(argv):
    try:
        return main_rc(argv)
    except BaseException as e:
        return ("raised " + type(e).__name__, "", "")
def task(i, role):
    return {"task_id": "ga-s%d" % i, "role": role, "base_sha": "a" * 40, "fix_sha": "b" * 40, "title": "t", "description": "d", "test_files": ["scripts/x.selftest.sh"], "prod_files": ["scripts/x.sh"]}
def wr(p, t):
    with open(p, "w") as f:
        f.write(t)

# (a) os defaults: uma rodada real (agente que devolve lixo = infra, reserva cobrada), relogio de 100.0 a 101.26, tudo que roda passa por um espiao
class Clk:
    def __init__(self):
        self.v = iter([100.0, 101.26])
    def monotonic(self):
        return next(self.v)
    def __getattr__(self, n):
        return getattr(time, n)
class SP:
    def __getattr__(self, n):
        return getattr(subprocess, n)
    def run(self, *a, **k):
        BLOB.append(k.get("timeout"))
        return subprocess.run(*a, **k)
CALLS, BLOB, ARGV, real_rc, real_sp = [], [], [], abr.run_capped, abr.subprocess
def spy(argv, cwd, env, timeout, stdin_text=None):
    CALLS.append((os.path.basename(argv[0]), timeout)); ARGV.append(argv)
    return real_rc(argv, cwd, env, timeout, stdin_text)
OUTA = os.path.join(WD, "runA.jsonl")
abr.time, abr.subprocess, abr.run_capped = Clk(), SP(), spy
try:
    RA = safe(["--repo", REPO, "--prefix", PFX, "--state-dir", STATE, "--claude", FAKE, "--config-ref", "main", "--day", "2026-01-01", "--out", OUTA, "--tasks", TASKS])
finally:
    abr.time, abr.subprocess, abr.run_capped = time, real_sp, real_rc
chk("defaults: rc 0, duracao 1.3 (1 casa), reserva de 400000 cobrada, teto de 2000000 no resumo", lambda: (RA[0], recs(OUTA)[0]["duracao_s"], recs(OUTA)[0]["tokens_cobrados"], json.loads(txt(OUTA + ".summary.json"))["teto_noite"]), (0, 1.3, 400000, 2000000))
chk("defaults de prazo: git 300 s, selftest 600 s, agente 900 s, git cat-file 120 s", lambda: [sorted(set(t for n, t in CALLS if n == x)) for x in ("git", "bash", os.path.basename(FAKE))] + [sorted(set(BLOB))], [[300], [600], [900], [120]])
BASE = json.loads(txt(TASKS).splitlines()[0])["base_sha"]
GITA = [a[3:] for a in ARGV if a[:2] == ["git", "-C"]]
chk("o checkout da base e seguido de git clean -fdxq (a chamada e a ordem; o que o selftest do fix deixou nao pode valer na base)", lambda: GITA[GITA.index(["checkout", "-q", "-f", "--detach", BASE]) + 1], ["clean", "-fdxq"])

# (b) funcoes puras nos limites
chk("suite_state: 126 e nao-sei (nunca reprovou) e, depois do agente, falha", lambda: [abr.suite_state([126]), abr.suite_state([126], True)], ["indeterminado", "fail"])
RES = {"type": "result", "k": 1}
chk("parse_claude: lista = o ultimo result; o que nao e result nao vale", lambda: abr.parse_claude(json.dumps([RES, {"type": "assistant"}])), RES)
chk("parse_claude: sem result (dict, lista, numero, texto, vazio) = None, nunca erro", lambda: [abr.parse_claude(x) for x in (json.dumps({"type": "assistant"}), "[]", json.dumps([{"type": "assistant"}]), json.dumps([1, "x"]), "7", "\"s\"", "")], [None] * 7)
def usage(**k):
    return {"usage": dict({"input_tokens": 1, "output_tokens": 2, "cache_creation_input_tokens": 4, "cache_read_input_tokens": 8}, **k)}
chk("tokens_of: entrada + saida + cache_creation, o cache_read a parte; zero e valido", lambda: [abr.tokens_of(usage()), abr.tokens_of(usage(input_tokens=0, output_tokens=0, cache_creation_input_tokens=0, cache_read_input_tokens=0))], [(7, 8), (0, 0)])
chk("tokens_of: negativo, bool, texto, float, faltando, usage que nao e dict = desconhecido", lambda: [abr.tokens_of(x) for x in (usage(input_tokens=-1), usage(output_tokens=True), usage(cache_read_input_tokens="8"), usage(input_tokens=1.5), {"usage": {"input_tokens": 1}}, {"usage": 3}, {})], [(None, None)] * 7)
def led(t):
    p = os.path.join(WD, "led.json")
    with open(p, "w") as f:
        f.write(t)
    return abr.read_ledger(p)
chk("read_ledger: tokens 0 e um ledger valido (nao ilegivel)", lambda: [led("{\"tokens\": 0}"), led("{\"tokens\": 7}")], [0, 7])
def home_of(real, **ev):
    reset()
    for k in ("ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"):
        os.environ.pop(k, None)
    os.environ["HOME"] = "/real"
    os.environ.update(ev)
    return abr.agent_env("/scr", real)["HOME"]
chk("agent_env: o HOME real so com --agent-real-home, sem credencial e com HOME; senao o descartavel", lambda: [home_of(False), home_of(True), home_of(True, ANTHROPIC_API_KEY="k"), home_of(True, CLAUDE_CODE_OAUTH_TOKEN="t"), home_of(True, HOME="")], ["/scr", "/real", "/scr", "/scr", "/scr"])
reset()
WT, FORA = os.path.join(WD, "wt"), os.path.join(WD, "fora")
os.makedirs(WT); os.makedirs(FORA); os.symlink(FORA, os.path.join(WT, "lnk"))
chk("write_into: diretorio que e symlink para fora do checkout = recusa e nao escreve", lambda: (abr.write_into(WT, "lnk/x", b"d", "100644"), os.path.exists(os.path.join(FORA, "x"))), (False, False))
chk("write_into: dentro do checkout cria o diretorio, escreve e poe o modo", lambda: (abr.write_into(WT, "a/b.sh", b"d", "100755"), oct(os.stat(os.path.join(WT, "a", "b.sh")).st_mode & 0o777)), (True, "0o755"))
chk("tree_files: (nome, sha do blob, modo); executavel = 100755; symlink fica de fora", lambda: [(os.path.basename(n), len(s), md) for n, s, md in abr.tree_files(REPO, "main", [PFX + "/scripts/aaa.sh", PFX + "/scripts/ddd.sh", PFX + "/scripts/lnk.selftest.sh"])], [("aaa.sh", 40, "100644"), ("ddd.sh", 40, "100755")])
chk("put_files: blob que o git nao tem = False; lista vazia = True", lambda: [abr.put_files(REPO, WT, [("x/y", "0" * 40, "100644")]), abr.put_files(REPO, WT, [])], [False, True])
T1 = task(1, "dog")
chk("validate: lista vazia, nao-lista e enunciado que nao e texto = recusado (nunca erro); a tarefa boa passa", lambda: [abr.validate(dict(T1, test_files=[])), abr.validate(dict(T1, prod_files=5)), abr.validate(dict(T1, description=3)), abr.validate(dict(T1, title=None)), abr.validate(T1)], ["argumento_invalido:test_files", "argumento_invalido:prod_files", "argumento_invalido:enunciado", "argumento_invalido:enunciado", None])
EX = os.path.join(WD, "ex"); os.makedirs(EX)
wr(os.path.join(EX, "n127.selftest.sh"), "exit 127\n"); wr(os.path.join(EX, "ok.selftest.sh"), "exit 0\n")
chk("run_tests: selftest que sai 127 = nao sei (indeterminado), depois do agente = falha; 0 = pass", lambda: [abr.run_tests(EX, ["n127.selftest.sh"], 20), abr.run_tests(EX, ["n127.selftest.sh"], 20, True), abr.run_tests(EX, ["ok.selftest.sh"], 20)], ["indeterminado", "fail", "pass"])
PYP = "import os, resource; print(resource.getrlimit(resource.RLIMIT_FSIZE), os.getsid(0) == os.getpid(), os.getpgid(0) == os.getpid())"
chk("run_capped: o filho nasce com RLIMIT_FSIZE de 512 MiB e como lider de sessao (o killpg do prazo o alcanca)", lambda: abr.run_capped([sys.executable, "-I", "-c", PYP], None, {"PATH": os.environ["PATH"]}, 20), (0, "(536870912, 536870912) True True\n", ""))
real_rm = shutil.rmtree
def rm_strict(p, ignore_errors=False, *a, **k):
    if not ignore_errors:
        raise OSError("nao consegui apagar")
    return real_rm(p, ignore_errors=True)
shutil.rmtree = rm_strict   # dai em diante uma limpeza que nao passe ignore_errors=True levanta: o rc e a mensagem da rodada nao podem depender dela

# (c) o laco do main() com run_task de mentira: cada tarefa e um passo do roteiro
K = [0]
def go(script, *more, roles=("dog",), pre=None, env=None):
    reset()
    os.environ.update(env or {})
    K[0] += 1
    sd = os.path.join(WD, "s%d" % K[0]); os.makedirs(sd)
    tf, out = os.path.join(sd, "tasks.jsonl"), os.path.join(sd, "out.jsonl")
    with open(tf, "w") as f:
        for i, r in enumerate(roles):
            f.write(json.dumps(task(i + 1, r)) + "\n")
    if pre:
        pre(out)
    real = abr.run_task
    abr.run_task = lambda c, t, role: script[t["task_id"]](c, t, role)
    try:
        r = safe(["--repo", REPO, "--prefix", PFX, "--state-dir", sd, "--claude", FAKE, "--config-ref", "main", "--day", "2026-01-01", "--out", out, "--tasks", tf] + list(more))
    finally:
        abr.run_task = real
    return {"rc": r[0], "so": r[1], "se": r[2], "out": out, "sd": sd}
def rec(estado, motivo="", ok=None, paid=0, ran=False):
    def step(c, t, role):
        if ran:
            c.agent_ran = True
        return abr.rec_of(c, t, role, estado, motivo, ok=ok, tokens_cobrados=paid)
    return step
def boom(ran=False):
    def step(c, t, role):
        if ran:
            c.agent_ran = True
        raise OSError("disco cheio")
    return step
def summ(r):
    return json.loads(txt(r["out"] + ".summary.json"))
def spent(r):
    return json.loads(txt(os.path.join(r["sd"], "spend-2026-01-01.json")))["tokens"]
D3 = ("dog",) * 3
r = go({"ga-s1": rec("medida", ok=True, paid=100, ran=True), "ga-s2": rec("medida", "selftest_reprova_apos_agente", ok=False, paid=100, ran=True), "ga-s3": rec("medida", "selftest_reprova_apos_agente", ok=False, paid=100, ran=True)}, "--token-cap", "300", "--task-reserve-tokens", "100", roles=D3)
chk("laco: gasto + reserva == teto ainda roda; gasto == teto nao excede; sem freio", lambda: (r["rc"], summ(r)["freio"], summ(r)["por_estado"], spent(r), summ(r)["teto_excedido"]), (0, None, {"medida": 3}, 300, False))
chk("resumo: so a medida que passou soma no ok; taxa com 4 casas", lambda: summ(r)["por_papel"], {"dog": {"medidas": 3, "ok": 1, "taxa": 0.3333}})
chk("resumo gravado com indent 1", lambda: txt(r["out"] + ".summary.json").split("\n")[1].startswith(" \"tarefas\""), True)
r = go({"ga-s1": rec("medida", ok=True, paid=300, ran=True), "ga-s2": boom(), "ga-s3": boom(True)}, "--task-reserve-tokens", "50", roles=D3)
chk("OSError: antes do agente nao cobra (a flag zera a cada tarefa), depois do agente cobra a reserva", lambda: ([(x["estado"], x["motivo"][:10], x["tokens_cobrados"]) for x in recs(r["out"])[1:]], spent(r)), ([("infra", "erro_de_io", 0), ("infra", "erro_de_io", 50)], 350))
# um claude que nao inicia + um OSError que escapa do finally da tarefa (o git que remove o worktree): a reserva NAO e cobrada, a flag voltou a False
real_git = abr.git
def git_boom(repo, *a, **k):
    r = real_git(repo, *a, **k)
    if a[:2] == ("worktree", "remove"):
        raise OSError("pipe quebrado")
    return r
SDB = os.path.join(WD, "sb"); os.makedirs(SDB)
abr.git = git_boom
try:
    RB = safe(["--repo", REPO, "--prefix", PFX, "--state-dir", SDB, "--claude", BROKEN, "--config-ref", "main", "--day", "2026-01-01", "--out", os.path.join(SDB, "out.jsonl"), "--tasks", TASKS, "--task-reserve-tokens", "50"])
finally:
    abr.git = real_git
chk("OSError depois de um agente que nao iniciou nao cobra a reserva", lambda: (RB[0], [(x["estado"], x["motivo"][:10], x["tokens_cobrados"]) for x in recs(os.path.join(SDB, "out.jsonl"))]), (0, [("infra", "erro_de_io", 0)]))
real_aw = abr.atomic_write
def aw(path, text):
    if os.path.basename(path).startswith("spend-"):
        raise OSError("sem espaco")
    return real_aw(path, text)
abr.atomic_write = aw
try:
    r = go({"ga-s1": rec("medida", ok=True, paid=300, ran=True), "ga-s2": rec("medida", ok=True, paid=300, ran=True)}, roles=("dog", "dog"))
finally:
    abr.atomic_write = real_aw
chk("ledger que nao grava: rc 4, freio ledger_sem_gravar, a 2a tarefa e pulada", lambda: (r["rc"], [(x["estado"], x["motivo"]) for x in recs(r["out"])]), (4, [("medida", ""), ("pulada", "ledger_sem_gravar")]))
r = go({}, pre=lambda out: os.makedirs(out + ".partial"))
chk("saida parcial que nao abre: rc 4", lambda: (r["rc"], "gravar" in r["se"]), (4, True))
r = go({"ga-s1": rec("medida", ok=True, paid=1, ran=True)}, pre=lambda out: os.makedirs(out + ".summary.json"))
chk("resumo que nao grava: rc 4", lambda: (r["rc"], "resumo" in r["se"]), (4, True))
real_mk = os.makedirs
def mk(p, *a, **k):
    if str(p).endswith("/home"):
        raise OSError("sem espaco")
    return real_mk(p, *a, **k)
os.makedirs = mk
try:
    r = go({})
finally:
    os.makedirs = real_mk
chk("HOME descartavel que nao nasce: rc 4 e o scratch nao sobra", lambda: (r["rc"], [x for x in os.listdir(os.environ["TMPDIR"]) if x.startswith("battery-")]), (4, []))
SEEN = {}
def cap(c, t, role):
    SEEN["scratch"] = c.scratch
    return abr.rec_of(c, t, role, "descartada", "x")
TD = os.path.join(WD, "tmpd"); os.makedirs(TD); tempfile.tempdir = TD
try:
    go({"ga-s1": cap}, env={"TMPDIR": ""})
finally:
    tempfile.tempdir = None
chk("TMPDIR vazio: o scratch nasce no diretorio temporario do tempfile, nunca no diretorio corrente (o mkdtemp com dir vazio do 3.12 ja devolve caminho absoluto)", lambda: os.path.normpath(os.path.dirname(SEEN["scratch"])), os.path.normpath(TD))
r = go({"ga-s1": rec("descartada", "n\xe3o_serve")})
raw = txt(r["out"])
chk("registro, resumo e saida em UTF-8 cru; chaves do registro em ordem (config_sha primeiro)", lambda: ("n\xe3o_serve" in raw, raw.startswith("{\"config_sha\""), "n\xe3o_serve" in txt(r["out"] + ".summary.json"), "n\xe3o_serve" in r["so"]), (True, True, True, True))
r = go({}, "--dry-run", roles=("dog", "p\xe1pel"))
chk("dry-run: so o papel sem prompt entra em papeis_sem_prompt; o plano sai em UTF-8 cru", lambda: (json.loads(r["so"])["papeis_sem_prompt"], "p\xe1pel" in r["so"]), (["p\xe1pel"], True))
def rcs(*more, roles=("dog",)):
    r = go({}, "--dry-run", *more, roles=roles)
    return r["rc"], r["se"]
for flag, val in (("--token-cap", "0"), ("--task-reserve-tokens", "0"), ("--task-budget-usd", "0"), ("--agent-timeout", "0"), ("--selftest-timeout", "0"), ("--limit", "-1"), ("--infra-stop", "0")):
    chk("uso errado: %s %s -> rc 2" % (flag, val), lambda: rcs(flag, val)[0], 2)
chk("orcamento de 0.5 USD e valido", lambda: rcs("--task-budget-usd", "0.5")[0], 0)
chk("--role-prompt valido da prompt a um papel que nao tinha", lambda: json.loads(go({}, "--dry-run", "--role-prompt", "wa-worker=agents/dog-remote/prompt.template.md", roles=("dog", "wa-worker"))["so"])["papeis_sem_prompt"], [])
for bad in ("Bad=agents/x.md", "dog=../x.md", "dog"):
    chk("--role-prompt %s -> rc 2" % bad, lambda: rcs("--role-prompt", bad)[0], 2)
chk("--day fora do formato -> rc 2", lambda: rcs("--day", "2026-1-1")[0], 2)
r = go({}, "--dry-run", pre=lambda out: wr(os.path.join(os.path.dirname(out), "tasks.jsonl.meta.json"), "{nao json"))
chk(".meta.json ilegivel: rc 2 pela mensagem do .meta.json", lambda: (r["rc"], "ileg" in r["se"]), (2, True))
chk("sem --state-dir e sem GC_CITY_PATH: rc 2", lambda: rcs("--state-dir", "")[0], 2)
chk("limites validos: 1 e aceito em teto, reserva, prazos e --infra-stop", lambda: [rcs(f, "1")[0] for f in ("--token-cap", "--task-reserve-tokens", "--agent-timeout", "--selftest-timeout", "--infra-stop")], [0] * 5)
r = go({}, "--dry-run", "--role-prompt", "wa-worker=scripts/aaa.sh", "--role-prompt", "ps-worker=scripts/bbb.sh", roles=("wa-worker", "ps-worker"))
chk("config_sha: o NOME do prompt entra no hash (o mesmo blob em dois caminhos = hashes diferentes)", lambda: (lambda c: [len(c["wa-worker"]), c["wa-worker"] != c["ps-worker"]])(json.loads(r["so"])["config_sha"]), [64, True])
reads, real_rl = iter([0, None]), abr.read_ledger
abr.read_ledger = lambda p: next(reads)
try:
    r = go({"ga-s1": rec("medida", ok=True, paid=1, ran=True)})
finally:
    abr.read_ledger = real_rl
chk("ledger ilegivel so na releitura com o lock: rc 5 e nada roda", lambda: (r["rc"], os.path.exists(r["out"])), (5, False))
r = go({"ga-s1": rec("infra", "x"), "ga-s2": rec("infra", "x"), "ga-s3": rec("medida", ok=True, paid=1, ran=True), "ga-s4": rec("infra", "x"), "ga-s5": rec("infra", "x")}, "--infra-stop", "3", roles=("dog",) * 5)
chk("so uma MEDIDA zera a sequencia de infra (infra, infra, medida, infra, infra nao para a rodada)", lambda: (r["rc"], summ(r)["freio"], summ(r)["por_estado"]), (0, None, {"infra": 4, "medida": 1}))
real_blob = abr.blob
abr.blob = lambda repo, sha: None
try:
    r = go({})
finally:
    abr.blob = real_blob
chk("prompt do papel que o git nao le: rc 2 pela mensagem do prompt", lambda: (r["rc"], "prompt do papel" in r["se"]), (2, True))
for label, ans in (("saida 0 que nao e sha", (0, "lixo")), ("rc 1 com saida de sha", (1, "a" * 40 + "\n"))):
    abr.git = lambda repo, *a, _ans=ans, **k: _ans if a[:2] == ("rev-parse", "--verify") else real_git(repo, *a, **k)
    try:
        r = go({}, "--dry-run")
    finally:
        abr.git = real_git
    chk("--config-ref que nao resolve (%s): rc 2 pela mensagem do --config-ref" % label, lambda: (r["rc"], "n\xe3o resolve" in r["se"]), (2, True))
real_tf = abr.tree_files
for k, frag in ((1, "ls-tree falhou em"), (2, "no prompt do papel")):
    n = [0]
    def tfk(*a, _k=k, _n=n):
        _n[0] += 1
        return None if _n[0] == _k else real_tf(*a)
    abr.tree_files = tfk
    try:
        r = go({}, "--dry-run")
    finally:
        abr.tree_files = real_tf
    chk("git ls-tree falhou (chamada %d): rc 2 com a mensagem certa" % k, lambda: (r["rc"], frag in r["se"]), (2, True))
shutil.rmtree = real_rm
print("DONE %d" % BAD[0])
'
UOUT="$(python3 -I -B -c "$PYU" "$TOOL" "$R" "$P" "$W/unit" "$FAKE" "$ST" "$ST/tasks.jsonl" "$W/unit/broken-claude" 2>&1)"
printf '%s\n' "$UOUT" | grep -v '^DONE'
check "em processo: o bloco foi até o fim e nenhuma checagem falhou" "$(printf '%s\n' "$UOUT" | sed -n 's/^DONE //p')" 0

echo
if [ "$FAILS" -eq 0 ]; then echo "tudo passou"; exit 0; fi
echo "$FAILS falha(s)"
exit 1
