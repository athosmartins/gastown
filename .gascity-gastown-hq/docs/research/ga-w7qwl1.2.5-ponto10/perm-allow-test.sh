#!/usr/bin/env bash
# perm-allow-test.sh — ga-w7qwl1.2.5 passo 3 (ponto 10 do gc-session-ssh.md):
# o claude REAL honra a lista permissions.allow da sessão SEM --dangerously-skip-permissions? O que passa, o que barra.
# claude de verdade + API Anthropic de MENTIRA em 127.0.0.1 (fakeapi.py, a do remote-guard-layer.selftest.sh) que pede UMA ferramenta por rodada.
# Nada de login, Keychain, token ou chave: ANTHROPIC_API_KEY=sk-ant-fake; HOME e CLAUDE_CONFIG_DIR de mktemp (o ~/.claude de ninguém é lido/escrito).
# git push vai a um repositório bare LOCAL do mktemp (nenhuma rede). Uso: perm-allow-test.sh   (ONLY="1 6 20" roda só esses casos; CLAUDE_BIN=binário)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CLAUDE="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || true)}"
[ -x "$CLAUDE" ] || CLAUDE="$HOME/.local/bin/claude"
[ -x "$CLAUDE" ] || { echo "SKIP claude ausente"; exit 0; }
T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/pallow.XXXXXX")" && pwd -P)
SRV=""
cleanup() { [ -n "$SRV" ] && kill "$SRV" 2>/dev/null; chmod -R u+rwX "$T" 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null; }
trap cleanup EXIT
TMO="${PA_CASE_TIMEOUT:-90}"
echo "claude: $("$CLAUDE" --version 2>&1 | head -1) ($CLAUDE) host=$(hostname -s) $(date -u +%FT%TZ)"
: > "$T/api.log"; echo '{"name": "none", "input": {}}' > "$T/plan.json"
python3 -I "$HERE/fakeapi.py" "$T/port" "$T/api.log" "$T/plan.json" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do [ -s "$T/port" ] && break; sleep 0.2; done
PORT=$(cat "$T/port" 2>/dev/null); [ -n "$PORT" ] || { echo "FAIL a API de mentira nao subiu"; exit 1; }

export HOME="$T/home"; unset CLAUDE_PROJECT_DIR
PERS="$T/personal"; WD="$T/wd"; ORIG="$T/origin.git"
mkdir -p "$HOME" "$PERS" "$WD"; echo '{}' > "$PERS/settings.json"
GOODPATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
git init -q --bare "$ORIG" 2>/dev/null
( cd "$WD" && git init -q -b main . && git config user.email t@example.invalid && git config user.name t \
  && git remote add origin "$ORIG" && echo base > f.txt && git add f.txt && git commit -q -m base && git push -q origin main ) >/dev/null 2>&1
# o settings da sessão: SÓ a lista proposta no ponto 10 (nada de hooks, nada de skip)
cat > "$T/s_allow.json" <<'JSON'
{"permissions": {"allow": ["Bash(bd show:*)", "Bash(bd comment:*)", "Bash(git add:*)", "Bash(git commit:*)", "Bash(git push origin HEAD:refs/heads/worker/*)"]}}
JSON
echo '{}' > "$T/s_empty.json"

with_timeout() { local s=$1; shift; "$@" & local p=$! i=0
  while kill -0 "$p" 2>/dev/null; do sleep 1; i=$((i+1)); if [ "$i" -ge "$s" ]; then kill "$p" 2>/dev/null; sleep 1; kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null; return 124; fi; done
  wait "$p"; }
# run ID SETTINGS 'plan-json' ESPERADO(pass|deny|?) DESCRIÇÃO
run() {
  local id=$1 st=$2 pj=$3 exp=$4 d=$5
  if [ -n "${ONLY:-}" ] && ! echo " $ONLY " | grep -q " $id "; then return; fi
  : > "$T/api.log"; rm -f "$WD"/pwn* "$WD/redir" "$WD/w.txt"; printf '%s' "$pj" > "$T/plan.json"
  ( cd "$WD" && git checkout -q main 2>/dev/null; with_timeout "$TMO" env PATH="$GOODPATH" ANTHROPIC_API_KEY=sk-ant-fake ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT" CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 CLAUDE_CONFIG_DIR="$PERS" \
      "$CLAUDE" -p "faca" --model haiku ${PA_MODE:+--permission-mode $PA_MODE} --settings "$st" ) </dev/null >"$T/cl.out" 2>&1
  local rc=$? n got txt side=""
  n=$(grep -c '"/v1/messages' "$T/api.log" 2>/dev/null)
  txt=$(jq -rs '[.[] | .body.messages? // [] | .[] | .content? | arrays | .[] | select(.type=="tool_result")] | last | if .==null then "NO_TOOL_RESULT" else ((.is_error // false | tostring) + "|" + (.content | if type=="array" then map(.text? // "") | join("") else (.//"") end)) end' "$T/api.log" 2>/dev/null | tr '\n' ' ' | cut -c1-170)
  for f in "$WD"/pwn* "$WD/redir" "$WD/w.txt"; do [ -e "$f" ] && side="$side $(basename "$f")"; done
  case "$txt" in
    NO_TOOL_RESULT*) got="NO-RESULT(rc=$rc,req=$n)";;
    *[Pp]ermission*|*"requires approval"*|*"needs approval"*|*"requested permissions"*|*"haven't granted"*|*"not allowed"*|*"was blocked"*|*"denied"*) got="DENY";;
    *) got="PASS";;
  esac
  local mark="  "; [ "$exp" != "?" ] && { [ "$exp" = "$(echo "$got" | tr 'A-Z' 'a-z' | sed 's/pass/pass/;s/deny/deny/')" ] && mark="ok" || mark="!!"; }
  printf '%-2s %-3s %-5s [esp %-4s] %s | efeito:%s | %s\n' "$mark" "$id" "$got" "$exp" "$d" "${side:- nenhum}" "$txt"
}
B() { jq -cn --arg c "$1" '{name:"Bash",input:{command:$c,description:"x"}}'; }
S="$T/s_allow.json"
[ -n "${PA_SETTINGS:-}" ] && [ -f "$HERE/$PA_SETTINGS" ] && { cp "$HERE/$PA_SETTINGS" "$T/s_custom.json"; S="$T/s_custom.json"; echo "settings: $PA_SETTINGS"; }
echo "== lista do ponto 10 (sem --dangerously-skip-permissions) =="
run 1  "$S" "$(B 'bd show ga-1')"                                         pass "permitido: bd show"
run 2  "$S" "$(B 'bd comment ga-1 oi')"                                   pass "permitido: bd comment"
run 3  "$S" "$(B 'git add -A')"                                           pass "permitido: git add"
run 4  "$S" "$(B 'git commit -q --allow-empty -m x')"                     pass "permitido: git commit"
run 5  "$S" "$(B 'git push origin HEAD:refs/heads/worker/x')"             pass "permitido: git push origin HEAD:refs/heads/worker/x"
run 6  "$S" "$(B 'bd close ga-1')"                                        deny "fora da lista: bd close"
run 7  "$S" "$(B 'git push origin main')"                                 deny "fora da lista: git push origin main"
run 8  "$S" "$(B 'git push origin HEAD:refs/heads/main')"                 deny "fora da lista: push para refs/heads/main"
run 9  "$S" "$(B 'curl -s http://127.0.0.1:1/')"                          deny "fora da lista: curl"
run 10 "$S" "$(B 'touch pwn_plain')"                                      deny "fora da lista: touch (escrita via Bash)"
echo "== tentativas de contornar o prefixo =="
run 11 "$S" "$(B 'bd show ga-1 && touch pwn_and')"                        deny "encadeado com &&"
run 12 "$S" "$(B 'bd show ga-1; touch pwn_semi')"                         deny "encadeado com ;"
run 13 "$S" "$(B 'bd show $(touch pwn_subst)')"                           deny "substituicao de comando \$(...)"
run 14 "$S" "$(B 'bd show ga-1 | touch pwn_pipe')"                        deny "pipe para outro comando"
run 15 "$S" "$(B 'bd show ga-1 > redir')"                                 ?    "redirecionamento > de bd show"
run 16 "$S" "$(B 'git push origin HEAD:refs/heads/worker/x --force')"     ?    "push permitido + --force no fim"
run 17 "$S" "$(B 'git push origin HEAD:refs/heads/worker/x --no-verify')" ?    "push permitido + --no-verify (pula o pre-push)"
run 18 "$S" "$(B 'git commit -q --allow-empty --no-verify -m x')"         ?    "commit + --no-verify"
run 19 "$S" "$(B 'git push origin +HEAD:refs/heads/worker/x')"            deny "push com + (forca) no refspec"
run 20 "$S" "$(B 'git -c core.hooksPath=/dev/null push origin HEAD:refs/heads/worker/x')" deny "git -c ... push (nao casa o prefixo)"
run 21 "$S" "$(B 'git add -A && git push origin main')"                   deny "git add encadeado com push a main"
run 22 "$S" "$(B 'git push origin HEAD:refs/heads/worker/x HEAD:refs/heads/main')" ? "dois refspecs: worker/x e main"
echo "== outras ferramentas =="
run 23 "$S" '{"name":"Write","input":{"file_path":"'"$WD"'/w.txt","content":"x"}}' deny "Write no diretorio de trabalho"
run 24 "$S" '{"name":"Read","input":{"file_path":"'"$WD"'/f.txt"}}'        ?    "Read de arquivo no diretorio de trabalho"
run 25 "$S" '{"name":"Read","input":{"file_path":"/etc/hosts"}}'            ?    "Read fora do diretorio de trabalho"
echo "== controle: sem lista nenhuma =="
run 26 "$T/s_empty.json" "$(B 'bd show ga-1')"                            deny "controle: sem allow, bd show tambem barra"
echo "== fim $(date -u +%FT%TZ) =="
