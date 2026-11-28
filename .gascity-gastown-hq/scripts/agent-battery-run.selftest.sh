#!/usr/bin/env bash
# Selftest de agent-battery-run.py (ga-hyp55ss.1, fatia 2). Repositório git e `claude` de mentira; nada toca a cidade, a rede ou o claude real.
# Casos: caminho feliz (fail→pass, config sob teste, env limpo, worktree removido), agente que não conserta / trapaceia no selftest,
# descartes contados (passa na base, reprova no fix, selftest ausente/symlink), caminhos com cara de injeção de shell (recusados e contados,
# NADA executa), freio de tokens (PULADO, rc 6, ledger entre rodadas), saída do agente ilegível (cobra a reserva, nunca zero), timeout,
# infra repetida, ledger podre (rc 5), claude ausente (rc 8), rodada concorrente (rc 7), acervo adulterado/ausente/vazio, papéis.
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
# a configuração sob teste (HEAD = main) difere da que a base tinha
CFG1="$(git -C "$R" rev-parse HEAD)"
echo NOVO >"$R/CLAUDE.md"
echo NOVO-CIDADE >"$R/$P/CLAUDE.md"
echo '{"v":"nova"}' >"$R/.claude/settings.json"
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
check "feliz: config vista é a nova, não a velha da base" "$(grep -c NOVO "$FAKE_LOG/cfg-1.txt")/$(grep -c VELHO "$FAKE_LOG/cfg-1.txt")" "2/0"
check "feliz: env do agente tem a credencial do claude" "$(grep -c '^ANTHROPIC_API_KEY=k3$' "$FAKE_LOG/env-1.txt")" 1
check "feliz: env do agente sem GC_*/TOKEN" "$(grep -c -e '^GC_SECRET_X=' -e '^MY_API_TOKEN=' "$FAKE_LOG/env-1.txt")" 0
check "feliz: env do agente por lista de permitidos (sem SSH_AUTH_SOCK/DATABASE_URL/AWS_*, nomes que a lista de proibidos não pegava)" "$(grep -c -e '^SSH_AUTH_SOCK=' -e '^DATABASE_URL=' -e '^AWS_SESSION=' "$FAKE_LOG/env-1.txt")" 0
check "feliz: com credencial em env, HOME e TMPDIR são o diretório descartável (não o HOME do operador)" "$(grep -c -e "^HOME=$HOME\$" "$FAKE_LOG/env-1.txt")/$(grep -c '^HOME=.*/battery-[^/]*/home$' "$FAKE_LOG/env-1.txt")/$(grep -c '^TMPDIR=.*/battery-[^/]*/home$' "$FAKE_LOG/env-1.txt")" "0/1/1"
check "feliz: o agente só pode rodar o próprio selftest (nada de bash scripts/*, cat, git)" "$(grep -c -F -x 'Bash(bash scripts/aaa.selftest.sh:*)' "$FAKE_LOG/argv-1.txt")/$(grep -c -e 'scripts/\*' -e 'cat' -e 'git' -e 'python3' "$FAKE_LOG/argv-1.txt" | tr -d ' ')" "1/0"
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
  mkline ga-lnk "$(git -C "$R" rev-parse "$L_SHA^")" "$L_SHA" dog scripts/lnk.selftest.sh scripts/lnk.sh; } | mkcorpus "$ST/tasks.jsonl"
run --tasks "$ST/tasks.jsonl"
check "descartes: rc 0" "$?" 0
check "descartes: passa na base" "$(rec "$OUT" ga-bbb estado)/$(rec "$OUT" ga-bbb motivo)" "descartada/selftest_passa_na_base"
check "descartes: reprova no fix" "$(rec "$OUT" ga-ccc motivo)" selftest_reprova_no_fix
check "descartes: symlink não vale como selftest" "$(rec "$OUT" ga-lnk motivo)" selftest_ausente_no_fix
check "descartes: contados no resumo" "$(summ por_estado.descartada)" 3
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
check "injeção: 16 refugos contados (inclui a linha que não é objeto)" "$(summ por_estado.descartada)" 16
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
check "timeout: nenhum worktree sobrando" "$(git -C "$R" worktree list | wc -l | tr -d ' ')" 1

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
check "config_sha muda de papel para papel" "$([ -n "$S_REV" ] && [ "$S_REV" != "$S_NEW" ] && echo muda || echo igual)" muda

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

echo
if [ "$FAILS" -eq 0 ]; then echo "tudo passou"; exit 0; fi
echo "$FAILS falha(s)"
exit 1
