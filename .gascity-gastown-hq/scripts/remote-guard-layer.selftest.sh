#!/usr/bin/env bash
# remote-guard-layer.selftest.sh — o claude REAL honra o guarda que vem só no `--settings` do bundle (camada da SESSÃO, ga-w7qwl1.2.7)?
#
# Contents
#   O que prova · O que NÃO prova · Como roda · Variáveis
#
# O QUE PROVA (claude de verdade, API Anthropic de MENTIRA em 127.0.0.1 que sempre pede UMA ferramenta; tudo num HOME/CLAUDE_CONFIG_DIR de mktemp — nada lê ou escreve o ~/.claude de ninguém):
#   1. um PreToolUse que vem SÓ do `--settings` bloqueia Write e Bash (com --dangerously-skip-permissions, como no pool); o controle sem hook EXECUTA a mesma ferramenta;
#   2. o bundle que o remote-bundle-build.py gera com `--guard-layer session` (guarda REAL, settings REAL) é o que bloqueia: escrita em zdot/ do bundle e `git -C <clone alheio> commit`;
#      e uma escrita comum (fora da camada, fora do território) PASSA — o guarda não bloqueia tudo;
#   3. um `disableAllHooks: true` no config pessoal (CLAUDE_CONFIG_DIR = o ~/.claude do dono) ou na pasta do projeto desliga, CALADO, o hook do `--settings`; só o
#      `disableAllHooks: false` ESCRITO no próprio arquivo do `--settings` vence os dois — por isso o selfcheck da camada o exige. Os controles negativos (o mesmo settings
#      SEM o false) provam que o teste enxerga a diferença;
#   4. com vários --settings só o ÚLTIMO vale: o do bundle por último (a forma do comando do pool) bloqueia; na ordem inversa não — por isso o provider confere o último;
#   5. python3 ausente ou quebrado na PATH da sessão → o hook sai 2 e a ferramenta é BLOQUEADA, até a escrita inocente (falha fechada); com python3 ela passa.
# O QUE NÃO PROVA: o claude do MBP (versão e Keychain não medidos — o teste imprime a versão que rodou; refaça a cada atualização do claude e no MBP, `mbp-proof`); que o guarda
#   pegue toda forma de escrita (isso é o remote-clone-guard.selftest.sh); Bash que escreve dentro do bundle (o guarda é trava contra engano, não sandbox).
# COMO RODA: sem o claude na PATH (nem em CLAUDE_BIN, nem em ~/.local/bin) o teste diz SKIP em voz alta e sai 0 — isso NÃO vale como prova. Cada caso é uma rodada do claude (~10 s).
# VARIÁVEIS: CLAUDE_BIN (o binário) · REMOTE_BUILDER (builder a testar) · RGL_CASE_TIMEOUT (segundos por rodada, 120)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILDER="${REMOTE_BUILDER:-$HERE/remote-bundle-build.py}"
GUARD="$HERE/remote-clone-guard.py"
CLAUDE="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || true)}"
[ -x "$CLAUDE" ] || CLAUDE="$HOME/.local/bin/claude"
if [ ! -x "$CLAUDE" ]; then
  echo "SKIP claude ausente neste nó (CLAUDE_BIN, PATH e ~/.local/bin): a camada da sessão NÃO foi provada contra o claude de verdade"
  exit 0
fi
T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/rgl.XXXXXX")" && pwd -P)
SRV=""
cleanup() { [ -n "$SRV" ] && kill "$SRV" 2>/dev/null; chmod -R u+rwX "$T" 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null; }
trap cleanup EXIT
fails=0; n=0
ok() { n=$((n+1)); if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
TMO="${RGL_CASE_TIMEOUT:-120}"
echo "claude: $("$CLAUDE" --version 2>&1 | head -1) ($CLAUDE)"

# ---- a API de mentira: toda requisição de mensagem recebe UM tool_use do plano ($T/plan.json) enquanto não há tool_result; depois, texto e fim ----
cat > "$T/fakeapi.py" <<'PY'
import http.server, json, sys
PORTFILE, LOG, PLAN = sys.argv[1:4]
def ev(t, d): return ("event: %s\ndata: %s\n\n" % (t, json.dumps(d))).encode()
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, ctype, out):
        self.send_response(code); self.send_header("content-type", ctype); self.send_header("content-length", str(len(out))); self.end_headers(); self.wfile.write(out)
    def do_GET(self): self.reply(200, "application/json", b'{"data": []}')
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length") or 0))
        try: j = json.loads(body)
        except Exception: j = {}
        with open(LOG, "a") as f: f.write(json.dumps({"path": self.path, "body": j}) + "\n")
        if "/v1/messages" not in self.path or "count_tokens" in self.path:
            return self.reply(200, "application/json", b'{"input_tokens": 10}')
        msgs = j.get("messages", [])
        done = any(isinstance(m.get("content"), list) and any(b.get("type") == "tool_result" for b in m["content"]) for m in msgs)
        tools = [t.get("name") for t in j.get("tools", [])]
        plan = json.load(open(PLAN))
        out = ev("message_start", {"type": "message_start", "message": {"id": "msg_1", "type": "message", "role": "assistant", "model": j.get("model", "m"), "content": [], "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 1, "output_tokens": 1}}})
        if plan["name"] in tools and not done:
            out += ev("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "tool_use", "id": "toolu_1", "name": plan["name"], "input": {}}})
            out += ev("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": json.dumps(plan["input"])}})
            out += ev("content_block_stop", {"type": "content_block_stop", "index": 0})
            out += ev("message_delta", {"type": "message_delta", "delta": {"stop_reason": "tool_use", "stop_sequence": None}, "usage": {"output_tokens": 5}})
        else:
            out += ev("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
            out += ev("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "FIM"}})
            out += ev("content_block_stop", {"type": "content_block_stop", "index": 0})
            out += ev("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 2}})
        out += ev("message_stop", {"type": "message_stop"})
        self.reply(200, "text/event-stream", out)
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(PORTFILE, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
: > "$T/api.log"; echo '{"name": "none", "input": {}}' > "$T/plan.json"
python3 -I "$T/fakeapi.py" "$T/port" "$T/api.log" "$T/plan.json" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do [ -s "$T/port" ] && break; sleep 0.2; done
PORT=$(cat "$T/port" 2>/dev/null)
[ -n "$PORT" ]; ok $? "a API de mentira subiu em 127.0.0.1:${PORT:-?}"
[ -n "$PORT" ] || { echo "== 0/$n ok =="; exit 1; }

# ---- o mundo de mentira: HOME, o "~/.claude pessoal" (CLAUDE_CONFIG_DIR), a pasta de trabalho, um clone alheio no território e o bundle REAL da camada da sessão ----
export HOME="$T/home"; unset CLAUDE_PROJECT_DIR RCG_ROOT
PERS="$T/personal"; WD="$T/wd"; LR="$T/bundle"; TERR="$HOME/gt-remote/git"; OTH="$TERR/r/wt/other"
mkdir -p "$HOME" "$PERS" "$WD" "$OTH" "$T/fx/gt/.gascity-gastown-hq/.gc/agents/dog/.claude" "$T/fx/home/.claude"; : > "$OTH/.git"
for f in "$T/fx/gt/.gascity-gastown-hq/.gc/settings.json" "$T/fx/gt/.gascity-gastown-hq/.gc/agents/dog/.claude/settings.json" "$T/fx/home/.claude/settings.json"; do echo '{}' > "$f"; done
python3 -I "$BUILDER" build --city "$T/fx/gt/.gascity-gastown-hq" --claude-home "$T/fx/home/.claude" --mini-home "$T/fx/home" --role dog --role-dir "$T/fx/gt/.gascity-gastown-hq/.gc/agents/dog" \
  --remote-root "$LR" --remote-home "$LR/home" --clone-guard "$GUARD" --guard-layer session --out "$LR" >"$T/build.out" 2>"$T/build.err"
ok $? "o builder gera o bundle da camada da sessão (--guard-layer session) com o guarda REAL"; [ -s "$LR/city/settings.json" ] || { cat "$T/build.err" >&2; exit 1; }
BS="$LR/city/settings.json"                                    # o settings do bundle: guarda em Bash + Edit|Write|MultiEdit|NotebookEdit, disableAllHooks:false
jq 'del(.disableAllHooks)' "$BS" > "$T/s_nofalse.json"          # o MESMO settings sem o false escrito
echo '{}' > "$T/s_empty.json"
GOODPATH="$(dirname "$(command -v python3)"):/usr/bin:/bin"
mkdir -p "$T/nopy" "$T/badpy"; for bn in sh cat env dirname; do ln -sf "$(command -v $bn)" "$T/nopy/$bn"; ln -sf "$(command -v $bn)" "$T/badpy/$bn"; done
printf '#!/bin/sh\nexit 1\n' > "$T/badpy/python3"; chmod +x "$T/badpy/python3"

plan() { printf '%s' "$1" > "$T/plan.json"; }
plan_write() { plan "$(jq -cn --arg p "$1" '{name: "Write", input: {file_path: $p, content: "x"}}')"; }
plan_bash() { plan "$(jq -cn --arg c "$1" '{name: "Bash", input: {command: $c, description: "x"}}')"; }
WPROT="$LR/zdot/probe.txt"; WOK="$WD/ok.txt"                    # dentro da camada protegida (zdot/ do bundle) × trabalho comum
clean() { find "$LR/zdot" "$WD/ok.txt" "$WD/bash_ran" -delete 2>/dev/null; rm -f "$WD/.claude/settings.json"; rmdir "$WD/.claude" 2>/dev/null; echo '{}' > "$PERS/settings.json"; : > "$T/api.log"; }
with_timeout() {  # with_timeout SEGUNDOS CMD… — 124 se estourou
  local s=$1; shift; "$@" & local p=$! i=0
  while kill -0 "$p" 2>/dev/null; do sleep 1; i=$((i+1)); if [ "$i" -ge "$s" ]; then kill "$p" 2>/dev/null; sleep 1; kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null; return 124; fi; done
  wait "$p"
}
runcl() {  # runcl [opções do claude…] — uma rodada do claude -p no WD; a API de mentira pede a ferramenta do plano; stdout/err em $T/cl.out
  # a PATH da sessão (CLPATH) vai SÓ para o claude, via env: o with_timeout (sleep, kill) segue na PATH do teste, senão o caso do python3 ausente morreria no timeout
  ( cd "$WD" && with_timeout "$TMO" env PATH="${CLPATH:-$GOODPATH}" ANTHROPIC_API_KEY=sk-ant-fake ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT" CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 CLAUDE_CONFIG_DIR="$PERS" \
      "$CLAUDE" -p "faça" --model haiku --dangerously-skip-permissions "$@" ) </dev/null >"$T/cl.out" 2>&1
  CLRC=$?
}
tool_errored() { jq -e -s '[.[] | .body.messages? // [] | .[] | .content? | arrays | .[] | select(.type == "tool_result" and .is_error == true)] | length > 0' "$T/api.log" >/dev/null 2>&1; }  # a ferramenta voltou como erro para o "modelo"
hook_blocked() { grep -qF 'HOOK BLOCK: remote-clone-guard' "$T/api.log"; }  # o texto da recusa do guarda chegou ao "modelo"
asked_twice() { [ "$(grep -c '"/v1/messages' "$T/api.log" 2>/dev/null)" -ge 2 ]; }  # a conversa andou até o resultado da ferramenta (a rodada não morreu antes)
# WRITE_BLOCKED ARQ: o Write foi pedido, o arquivo NÃO existe e a ferramenta voltou como erro · WRITE_RAN ARQ: o arquivo existe
verdict() {  # verdict blocked|ran ARQUIVO DESCRIÇÃO — a rodada tem que ter chegado ao resultado da ferramenta; senão o caso reprova por não ter provado nada
  local want=$1 f=$2 d=$3 got
  if ! asked_twice; then ok 1 "$d (a rodada do claude não chegou ao resultado da ferramenta: rc=$CLRC, saída: $(head -c 200 "$T/cl.out" | tr '\n' ' '))"; return; fi
  if [ -e "$f" ]; then got=ran; elif tool_errored; then got=blocked; else got="nem rodou nem erro"; fi
  [ "$got" = "$want" ]; ok $? "$d [$got]"
}

# ================= 1. o claude honra o PreToolUse que vem só do --settings (e o controle sem hook executa) =================
clean; plan_write "$WPROT"; runcl --settings "$T/s_empty.json"; verdict ran "$WPROT" "controle: sem nenhum hook a escrita na camada do bundle EXECUTA (a API de mentira dirige uma ferramenta de verdade)"
clean; plan_write "$WPROT"; runcl --settings "$BS"; verdict blocked "$WPROT" "settings do bundle: Write em <raiz>/zdot/ (a camada protegida) é BLOQUEADO"; hook_blocked; ok $? "...e o motivo que chegou ao modelo é a recusa do remote-clone-guard"
clean; plan_write "$WOK"; runcl --settings "$BS"; verdict ran "$WOK" "settings do bundle: Write numa pasta de trabalho comum PASSA (o guarda não bloqueia tudo)"
clean; plan_bash "git -C $OTH commit -m x"; runcl --settings "$BS"; asked_twice && hook_blocked; ok $? "settings do bundle: Bash \`git -C <clone alheio> commit\` é BLOQUEADO pelo guarda"
clean; plan_bash "echo oi > $WD/bash_ran"; runcl --settings "$BS"; asked_twice && [ -e "$WD/bash_ran" ]; ok $? "settings do bundle: Bash comum PASSA e executa (o guarda não bloqueia tudo)"

# ================= 2. disableAllHooks pessoal ou do projeto: só o false ESCRITO no --settings vence =================
echo '{"disableAllHooks": true}' > "$PERS/settings.json"
plan_write "$WPROT"; : > "$T/api.log"; find "$LR/zdot" -delete 2>/dev/null; runcl --settings "$BS"; verdict blocked "$WPROT" "config PESSOAL com disableAllHooks:true + settings do bundle (false escrito): o hook segue valendo → BLOQUEADO"
clean; echo '{"disableAllHooks": true}' > "$PERS/settings.json"; plan_write "$WPROT"; runcl --settings "$T/s_nofalse.json"; verdict ran "$WPROT" "controle negativo: o MESMO settings SEM o false escrito → o disableAllHooks pessoal desliga o hook CALADO e a escrita executa"
clean; mkdir -p "$WD/.claude"; echo '{"disableAllHooks": true}' > "$WD/.claude/settings.json"; plan_write "$WPROT"; runcl --settings "$BS"; verdict blocked "$WPROT" "pasta do PROJETO com disableAllHooks:true + settings do bundle (false escrito): BLOQUEADO"
clean; mkdir -p "$WD/.claude"; echo '{"disableAllHooks": true}' > "$WD/.claude/settings.json"; plan_write "$WPROT"; runcl --settings "$T/s_nofalse.json"; verdict ran "$WPROT" "controle negativo: o MESMO settings sem o false + projeto com disableAllHooks:true → o hook é desligado calado, a escrita executa"

# ================= 3. vários --settings: só o ÚLTIMO vale (o provider confere o último) =================
clean; plan_write "$WPROT"; runcl --settings '{"env": {"X": "1"}}' --settings "$BS"; verdict blocked "$WPROT" "a forma do pool (--settings inline e depois o do bundle): o do bundle é o último → BLOQUEADO"
clean; plan_write "$WPROT"; runcl --settings "$BS" --settings '{"env": {"X": "1"}}'; verdict ran "$WPROT" "ordem inversa (o do bundle e depois outro): só o último conta → o guarda NÃO vale e a escrita executa (por isso o provider exige o do bundle por último)"

# ================= 4. python3 faltando ou quebrado na PATH da sessão: o hook falha FECHADO =================
clean; plan_write "$WOK"; CLPATH="$GOODPATH" runcl --settings "$BS"; verdict ran "$WOK" "(controle) com python3 na PATH a escrita comum passa"
clean; plan_write "$WOK"; CLPATH="$T/nopy" runcl --settings "$BS"; verdict blocked "$WOK" "python3 AUSENTE da PATH da sessão: até a escrita comum é BLOQUEADA (falha fechada: \`python3 … || exit 2\`)"
clean; plan_write "$WOK"; CLPATH="$T/badpy" runcl --settings "$BS"; verdict blocked "$WOK" "python3 QUEBRADO (sai 1) na PATH da sessão: a escrita comum é BLOQUEADA (falha fechada)"

echo "== $((n-fails))/$n ok =="
[ "$fails" = 0 ]
