#!/usr/bin/env bash
# Selftest de agent-battery-night.py (ga-hyp55ss.3, fatia 3). ssh, executor, e-mail e cofre de mentira; nada toca a cidade, o nó, a rede nem o claude.
# O ssh de mentira EXECUTA o comando remoto (bash -c) contra um repositório git local cujo origin/main guarda o executor de mentira: o que se prova é a
# ordem — corpo do comando remoto, token só pela entrada padrão, veredito por papel, relatório, jsonl, e-mail, gatilho de merge —, não o claude real.
# Sai 0 = tudo passou.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="${ABN_UNDER_TEST:-$HERE/agent-battery-night.py}"
W="$(mktemp -d "${TMPDIR:-/tmp}/abn-selftest.XXXXXX")"
trap 'rm -rf "$W"' EXIT
FAILS=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (esperado '$3', veio '$2')"; fi; }
unset GC_CITY_PATH
export FAKE_LOG="$W/log" CITY="$W/city" NS="$W/nodestate" P=.city TOKEN=sk-ant-oat01-FAKETOKEN0123456789abcdefXYZ
JSONL="$CITY/.gc/logs/agent-battery.jsonl"
DAY="$(date -u +%Y-%m-%d)"

# nó de mentira: o executor lê do origin/main, como o comando remoto de verdade (git show), e responde pelo modo do papel em $FAKE_LOG/mode-<papel>
mkdir -p "$W/node/$P/scripts" "$W/bin"
cat >"$W/node/$P/scripts/agent-battery-run.py" <<'EOF'
import hashlib, json, os, sys
a = sys.argv[1:]
arg = lambda k: a[a.index(k) + 1] if k in a else ""
role, L, dry = arg("--as-role"), os.environ["FAKE_LOG"], "--dry-run" in a
with open("%s/exec-%s.log" % (L, role), "a") as f:
    f.write(json.dumps({"argv": a, "token": os.environ.get("CLAUDE_CODE_OAUTH_TOKEN"), "path": os.environ.get("PATH", "")}) + "\n")
rd = lambda k, d: open("%s/%s" % (L, k)).read().strip() if os.path.exists("%s/%s" % (L, k)) else d
mode, cfg = rd("mode-" + role, "ok"), rd("cfg-" + role, rd("cfg", "v1"))
plan = {"tarefas": 12, "tasks_sha256": "b" * 64, "config_ref_sha": "a" * 40, "config_sha": {role: hashlib.sha256((role + cfg).encode()).hexdigest()}, "teto_noite": int(arg("--token-cap"))}
if dry:
    if os.path.exists(L + "/dry-garbage") or os.path.exists(L + "/dry-garbage-" + role):
        print("lixo"); sys.exit(0)
    if os.path.exists(L + "/dry-badsha-" + role):
        plan["config_sha"][role] = "xyz"
    print(json.dumps(plan)); sys.exit(3 if os.path.exists(L + "/dry-rc3-" + role) else 0)
if mode == "noclaude":
    print("agent-battery-run: claude ausente (claude): nada roda", file=sys.stderr); sys.exit(8)
if mode == "leak":
    print("agent-battery-run: falhou com %s e com sk-ant-oat01-OUTRACHAVE0123456789abcdefg" % os.environ["CLAUDE_CODE_OAUTH_TOKEN"], file=sys.stderr); sys.exit(2)
if mode == "notasks":
    print("agent-battery-run: nenhuma tarefa utilizável em x", file=sys.stderr); sys.exit(3)
if mode == "locked":
    print("agent-battery-run: outra rodada em andamento; nada feito", file=sys.stderr); sys.exit(7)
if mode == "nocfg":
    print(json.dumps({"por_papel": {}})); sys.exit(0)
if mode == "banner":
    print("banner que o shell do nó imprimiu antes")
if mode == "garbage":
    print("isto não é json"); sys.exit(0)
if mode == "weird":
    print(json.dumps(dict(plan, por_estado=["x"], tokens_noite_antes="a", por_papel={role: {"medidas": "8", "ok": 6, "taxa": "x"}}))); sys.exit(0)
if mode == "slow":
    import time; time.sleep(30)
n = {"few": 2, "brake0": 0, "brakefew": 2, "zero": 0}.get(mode, 8)
rc = {"brake": 6, "brake0": 6, "brakefew": 6, "infra": 8}.get(mode, 0)
freio = {"brake": "teto_de_tokens", "brake0": "teto_de_tokens", "brakefew": "teto_de_tokens", "infra": "infra_repetida"}.get(mode)
bad = mode == "weirdtaxa"  # números certos, tipos errados só em taxa, por_estado e no sha do acervo
if bad:
    plan["tasks_sha256"] = "não-é-hex"
print(json.dumps(dict(plan, por_estado=["x"] if bad else {"medida": n, "descartada": 3}, descartes={"selftest_passa_na_base": 3}, freio=freio, tokens_noite_antes=100000,
                      tokens_noite_depois=100000 + n * 50000, por_papel={role: {"medidas": n, "ok": min(n, 6), "taxa": "x" if bad else round(min(n, 6) / n, 4)}} if n else {})))
sys.exit(rc)
EOF
git -C "$W/node" init -q -b main && git -C "$W/node" -c user.email=t@t -c user.name=t add -A && git -C "$W/node" -c user.email=t@t -c user.name=t commit -qm base
git -C "$W/node" update-ref refs/remotes/origin/main HEAD
cat >"$W/fake-ssh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_LOG/ssh-argv"
[ -e "$FAKE_LOG/ssh-down" ] && { echo "ssh: connect to host fake: Connection refused" >&2; exit 255; }
while [ "${1:-}" = -o ]; do shift 2; done
shift # o host
[ -e "$FAKE_LOG/ssh-down-run" ] && case "$1" in *"read -r CLAUDE"*) echo "ssh: Connection reset by fake" >&2; exit 255 ;; esac
exec bash -c "$1"
EOF
printf '#!/usr/bin/env bash\n[ -e "$FAKE_LOG/mail-fail" ] && exit 1\nprintf "%%s\\n" "$2" >>"$FAKE_LOG/mail-subj"; printf "%%s\\n" "$4" >"$FAKE_LOG/mail-body"\n' >"$W/fake-mail"
printf '#!/usr/bin/env bash\n[ -e "$FAKE_LOG/token-fail" ] && exit 1\n[ -e "$FAKE_LOG/token-short" ] && { echo curto; exit 0; }\n[ -e "$FAKE_LOG/token-failprint" ] && { echo "$TOKEN"; exit 1; }\necho "$*" >>"$FAKE_LOG/token-args"; echo "$TOKEN"\n' >"$W/fake-token"
chmod +x "$W/fake-ssh" "$W/fake-mail" "$W/fake-token"
# o comando remoto usa `timeout` (Linux do nó); o mini (macOS) não o tem: um shim com a mesma forma (-k N DURAÇÃO cmd, 124 no prazo) entra no PATH. ABN_FAKE_TIMEOUT=1 força o shim.
if [ -n "${ABN_FAKE_TIMEOUT:-}" ] || ! command -v timeout >/dev/null 2>&1; then
  printf '#!/usr/bin/env python3\nimport subprocess, sys\na = sys.argv[1:]\na = a[2:] if a[0] == "-k" else a\ntry:\n    sys.exit(subprocess.run(a[1:], timeout=float(a[0])).returncode)\nexcept subprocess.TimeoutExpired:\n    sys.exit(124)\n' >"$W/bin/timeout"
  chmod +x "$W/bin/timeout"; export PATH="$W/bin:$PATH"
fi
sha() { python3 -I -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$1"; }

reset() { # estado limpo: nó ligado, acervo presente, nada gravado
  rm -rf "$FAKE_LOG" "$CITY" "$NS"; mkdir -p "$FAKE_LOG" "$CITY/.gc/agent-battery"
  touch "$CITY/.gc/hetzner-node.on"
  printf '{"task_id":"ga-x","title":"Correção com acento: ação"}\n' >"$CITY/.gc/agent-battery/tasks.jsonl"
  echo '{"sha256":"x"}' >"$CITY/.gc/agent-battery/tasks.jsonl.meta.json"
}
drive() { # modo [args...] — stdout do driver em $W/out; devolve o exit
  local m=$1; shift
  python3 -I "$TOOL" --mode "$m" --city "$CITY" --ssh "$W/fake-ssh" --mail "$W/fake-mail" --token-cmd "$W/fake-token" --prefix "$P" \
    --node-repo "$W/node" --node-state "$NS" --run-timeout-s 30 --night-cap 1100000 --merge-cap 900000 "$@" >"$W/out" 2>&1
  RC=$?
}
jl() { tail -n 1 "$JSONL" | jq -r "$1"; }
verdict() { tail -n 1 "$W/out"; }
mode() { printf '%s' "$2" >"$FAKE_LOG/mode-$1"; } # papel modo
rep() { cat "$CITY/.gc/logs/agent-battery/$DAY.md"; }

reset; rm "$CITY/.gc/hetzner-node.on"
drive night; check "nó desligado: exit 0" "$RC" 0
check "nó desligado: PULADO" "$(verdict)" "VEREDITO: PULADO"
check "nó desligado: nada foi ao nó" "$(ls "$FAKE_LOG")" ""
check "nó desligado: a noite deixa uma linha no jsonl" "$(wc -l <"$JSONL" | tr -d ' ') $(jl .verdict)" "1 PULADO"

reset; rm "$CITY/.gc/agent-battery/tasks.jsonl.meta.json"
drive night; check "sem acervo: exit 0 (INERTE não é falha)" "$RC" 0
check "sem acervo: INERTE" "$(verdict)" "VEREDITO: INERTE"
check "sem acervo: o e-mail diz o que falta" "$(grep -c 'INERTE.*acervo' "$FAKE_LOG/mail-subj")" 1
check "sem acervo: nenhum executor rodou" "$(ls "$FAKE_LOG" | grep -c '^exec-')" 0

reset; touch "$FAKE_LOG/token-fail"
drive night; check "sem credencial: exit 0" "$RC" 0
check "sem credencial: INERTE" "$(verdict)" "VEREDITO: INERTE"
check "sem credencial: nenhum executor rodou" "$(ls "$FAKE_LOG" | grep -c '^exec-')" 0

reset
drive night; check "noite boa: exit 0" "$RC" 0
check "noite boa: COMPLETO" "$(verdict)" "VEREDITO: COMPLETO"
check "noite boa: taxa e config_sha por papel no jsonl" "$(jl '[.papeis.dog.medidas, .papeis.dog.ok, .papeis.dog.taxa, (.papeis["wa-worker"].config_sha | length), .papeis.reviewer.cat] | join(" ")')" "8 6 0.75 64 ok"
check "noite boa: relatório do dia com os 3 papéis" "$(grep -c -E '^\| (dog|wa-worker|reviewer) ' "$CITY/.gc/logs/agent-battery/$DAY.md")" 3
check "noite boa: um e-mail ao Mayor" "$(grep -c "^\[agent-battery\] $DAY COMPLETO" "$FAKE_LOG/mail-subj")" 1
check "noite boa: o token chegou ao executor" "$(jq -r .token "$FAKE_LOG/exec-dog.log")" "$TOKEN"
check "controle do varredor: ele acha o token onde ele está" "$(grep -rlF "$TOKEN" "$FAKE_LOG/exec-dog.log" | wc -l | tr -d ' ')" 1
check "noite boa: o token nunca foi argv, relatório, jsonl, e-mail nem saída" "$(grep -rlF "$TOKEN" "$FAKE_LOG/ssh-argv" "$CITY/.gc/logs" "$FAKE_LOG/mail-body" "$W/out" | wc -l | tr -d ' ')" 0
check "noite boa: o contrato com o executor (flags, estado de noite por papel, teto da noite)" "$(jq -r '.argv | join(" ")' "$FAKE_LOG/exec-reviewer.log")" "--repo $W/node --prefix $P --config-ref origin/main --state-dir $NS/night/reviewer --tasks $NS/tasks.jsonl --as-role reviewer --token-cap 1100000"
check "noite boa: o sha do acervo medido vai ao jsonl (a fatia 4 só compara noites do MESMO acervo) e role_prompt fica vazio" "$(jl .papeis.dog.acervo) [$(jl .role_prompt)]" "$(printf 'b%.0s' $(seq 64)) []"
check "noite boa: acervo e .meta.json no nó idênticos (acento incluso)" "$(cmp "$CITY/.gc/agent-battery/tasks.jsonl" "$NS/tasks.jsonl" && cmp "$CITY/.gc/agent-battery/tasks.jsonl.meta.json" "$NS/tasks.jsonl.meta.json" && echo igual)" igual
check "noite boa: a linha do dog traz config_sha, medidas, ok e taxa" "$(rep | grep -c -E '^\| dog \| [0-9a-f]{12} \| 8 \| 6 \| 75% \| medida ×8, descartada ×3 \| 400000 \| - \|')" 1
check "noite boa: o nó acha o claude (~/.local/bin entra no PATH do executor)" "$(jq -r .path "$FAKE_LOG/exec-dog.log" | cut -d: -f1)" "$HOME/.local/bin"
check "noite boa: o relatório diz o commit medido e avisa amostra pequena" "$(rep | grep -c '@aaaaaaaaaaaa') $(rep | grep -c 'amostra pequena')" "1 1"

reset; drive night --role-prompt dog=scripts/ruim.md; check "--role-prompt vai ao executor, no fim do argv (sem ele o argv é o do contrato acima)" "$(jq -r '.argv | join(" ")' "$FAKE_LOG/exec-dog.log")" "--repo $W/node --prefix $P --config-ref origin/main --state-dir $NS/night/dog --tasks $NS/tasks.jsonl --as-role dog --token-cap 1100000 --role-prompt dog=scripts/ruim.md"
check "--role-prompt fica registrado no jsonl (a fatia 4 não mistura essa medida com a base)" "$(jl .role_prompt)" "dog=scripts/ruim.md"
reset; drive night --limit 3; check "--limit vai ao executor" "$(jq -r '.argv | .[index("--limit")+1]' "$FAKE_LOG/exec-dog.log")" 3

reset; echo '{"current":"conta@exemplo.com"}' >"$W/pool.json" # a receita do runbook: a chave da conta atual do pool, como o gc-session-ssh a acha (secret + current)
drive night --token-cmd "sh -c '$W/fake-token claude-oauth-token-\$(jq -r .current $W/pool.json)'"
check "token pela receita do runbook (sh -c, jq e o item da conta atual): COMPLETO com o item certo" "$(verdict) $(cat "$FAKE_LOG/token-args" | head -n 1)" "VEREDITO: COMPLETO claude-oauth-token-conta@exemplo.com"

reset; mode reviewer few
drive night; check "amostra pequena: exit 1" "$RC" 1
check "amostra pequena: FALHOU" "$(verdict)" "VEREDITO: FALHOU"
check "amostra pequena: o motivo nomeia o papel e o tamanho" "$(jl .reason | grep -c 'reviewer.*2 medidas')" 1
check "amostra pequena: o motivo traz os descartes (a causa de 'poucas medidas')" "$(jl .reason | grep -c 'estados descartada ×3, medida ×2; descartes selftest_passa_na_base ×3')" 1
check "amostra pequena: só o reviewer falhou" "$(jl '[.papeis[] | .cat] | sort | join(" ")')" "falhou ok ok"
check "amostra pequena: o Mayor foi avisado" "$(grep -c FALHOU "$FAKE_LOG/mail-subj")" 1

reset; for r in dog wa-worker reviewer; do mode $r brake; done
drive night; check "freio com amostra suficiente: exit 0" "$RC" 0
check "freio com amostra suficiente: COMPLETO e o freio aparece" "$(verdict) $(rep | grep -c teto_de_tokens)" "VEREDITO: COMPLETO 3"
reset; mode dog brake0
drive night; check "freio sem nenhuma medida (noite): FALHOU" "$(verdict) $RC" "VEREDITO: FALHOU 1"
check "freio sem nenhuma medida: o motivo diz o teto" "$(jl .reason | grep -c 'dog.*teto_de_tokens')" 1

reset; for r in dog wa-worker reviewer; do mode $r noclaude; done
drive night; check "claude ausente em todos: INERTE, exit 0" "$(verdict) $RC" "VEREDITO: INERTE 0"
check "claude ausente: o motivo é o do executor" "$(jl .reason | grep -c 'claude ausente')" 1
reset; mode dog noclaude
drive night; check "claude ausente só num papel: FALHOU (não é falta de instalação)" "$(verdict) $RC" "VEREDITO: FALHOU 1"
reset; mode dog infra
drive night; check "infra repetida (rc 8 com resumo): FALHOU" "$(verdict)" "VEREDITO: FALHOU"
reset; for r in dog wa-worker reviewer; do mode $r locked; done
drive night; check "executor já rodando em todos: PULADO, exit 0" "$(verdict) $RC" "VEREDITO: PULADO 0"

reset; mode dog garbage
drive night; check "resumo ilegível: FALHOU" "$(verdict)" "VEREDITO: FALHOU"
check "resumo ilegível: o motivo diz isso, e a linha do papel mostra '-' (não None)" "$(jl .papeis.dog.motivo | grep -c 'sem resumo legível') $(rep | grep -c -E '^\| dog \| \? \| - \| - \| - \| - \| - \| - \|')" "1 1"
check "resumo ilegível: a taxa é null, nunca 0" "$(jl '.papeis.dog | [.cat, .taxa, .medidas] | map(tostring) | join(" ")')" "falhou null null"
check "resumo ilegível: o papel traz a chave acervo (null): o formato do jsonl é o mesmo medido ou não" "$(jl '.papeis.dog | has("acervo")')" true
reset; mode dog weird
drive night; check "resumo com tipos errados: FALHOU com relatório, o driver não cai" "$(verdict) $RC $(jl .papeis.dog.motivo | grep -c "forma inesperada")" "VEREDITO: FALHOU 1 1"
reset; drive night --token-cmd "'sem fechar"; check "erro inesperado do driver: FALHOU com veredito, relatório e e-mail" "$(verdict) $RC $(jl .reason | grep -c 'erro inesperado') $(grep -c FALHOU "$FAKE_LOG/mail-subj")" "VEREDITO: FALHOU 1 1 1"
reset; touch "$FAKE_LOG/ssh-down"
drive night; check "nó inalcançável: FALHOU, exit 1" "$(verdict) $RC" "VEREDITO: FALHOU 1"
check "nó inalcançável: o motivo é o envio do acervo" "$(jl .reason | grep -c 'enviar o acervo')" 1
reset; mode dog leak
drive night; check "executor que imprime o token: FALHOU" "$(verdict)" "VEREDITO: FALHOU"
check "executor que imprime chaves: o relatório as esconde (a do token e uma que o driver não conhece)" "$(grep -q 'falhou com \*\*\* e com sk-ant-\*\*\*' "$CITY/.gc/logs/agent-battery/$DAY.md" && echo sim) $(grep -rlE "FAKETOKEN|OUTRACHAVE" "$CITY/.gc/logs" "$FAKE_LOG/mail-body" "$FAKE_LOG/mail-subj" "$W/out" | wc -l | tr -d ' ')" "sim 0"
reset; mode dog slow
drive night --run-timeout-s 2; check "executor que passa do prazo: FALHOU" "$(verdict)" "VEREDITO: FALHOU"
check "executor que passa do prazo: o motivo diz o prazo" "$(jl .reason | grep -c 'prazo')" 1
reset; touch "$FAKE_LOG/mail-fail"
drive night; check "e-mail que falha: exit 1 mesmo com COMPLETO" "$(verdict) $RC" "VEREDITO: COMPLETO 1"
check "e-mail que falha: o jsonl diz" "$(jl .mail_failed)" 1
reset; drive night --roles dog,nao-existe; check "papel desconhecido: exit 2 e nada roda" "$RC $(ls "$FAKE_LOG" | wc -l | tr -d ' ')" "2 0"

LAST="$CITY/.gc/agent-battery/merge-last.json"
cfg() { printf '%s' "$2" >"$FAKE_LOG/cfg-$1"; } # papel versão: a configuração do papel no nó muda
nrun() { grep -c '"token": "sk' "$FAKE_LOG/exec-$1.log" 2>/dev/null; true; } # quantas vezes o executor rodou DE VERDADE (com token); a sondagem não leva token

reset; drive merge; check "merge, 1ª sondagem: PULADO silencioso" "$(verdict) $RC $(ls "$CITY/.gc/logs" 2>/dev/null | wc -l | tr -d ' ') $(ls "$FAKE_LOG" | grep -c mail)" "VEREDITO: PULADO 0 0 0"
check "merge, 1ª sondagem: grava a linha de base dos 3 papéis, sem medir" "$(jq -r 'keys | join(" ")' "$LAST") $(nrun dog)" "dog reviewer wa-worker 0"
drive merge; check "merge, nada mudou: PULADO silencioso, ninguém roda" "$(verdict) $(nrun dog)$(nrun reviewer)" "VEREDITO: PULADO 00"
cfg dog v2; drive merge; check "merge, só o dog mudou: COMPLETO, exit 0" "$(verdict) $RC" "VEREDITO: COMPLETO 0"
check "merge, só o dog mudou: só ele rodou, no estado de merge e com o teto de merge" "$(nrun dog)$(nrun reviewer)$(nrun wa-worker) $(jq -r '.argv | [.[index("--state-dir")+1], .[index("--token-cap")+1]] | join(" ")' <(tail -n 1 "$FAKE_LOG/exec-dog.log"))" "100 $NS/merge/dog 900000"
check "merge, COMPLETO: jsonl só com o dog, sem e-mail" "$(jl '.mode + " " + (.papeis | keys | join(","))') $(ls "$FAKE_LOG" | grep -c mail)" "merge dog 0"
check "merge, COMPLETO: o relatório de merge tem nome próprio, o da noite não nasce" "$(ls "$CITY/.gc/logs/agent-battery" | grep -c -- "^$DAY-merge-") $(ls "$CITY/.gc/logs/agent-battery" | grep -c "^$DAY.md")" "1 0"
check "merge: a configuração medida vira a última" "$(jq -r .dog "$LAST")" "$(jq -r .papeis.dog.config_sha <(tail -n 1 "$JSONL"))"
drive merge; check "merge, mesma configuração de novo: ninguém roda" "$(nrun dog)" 1

reset; drive merge; cfg dog v2; mode dog few
drive merge; check "merge, falhou: FALHOU, exit 1, e-mail" "$(verdict) $RC $(grep -c FALHOU "$FAKE_LOG/mail-subj")" "VEREDITO: FALHOU 1 1"
drive merge; check "merge, a mesma mudança não é repetida (sem tempestade de e-mail)" "$(nrun dog) $(wc -l <"$FAKE_LOG/mail-subj" | tr -d ' ')" "1 1"
reset; drive merge; cfg dog v2; touch "$FAKE_LOG/ssh-down"; rm -f "$JSONL"
drive merge; check "merge, nó fora na sondagem: silêncio, exit 0, base intacta" "$RC $(ls "$FAKE_LOG" | grep -c mail) $(ls "$CITY/.gc/logs" 2>/dev/null | wc -l | tr -d ' ') $(jq -r .dog "$LAST" | wc -c | tr -d ' ')" "0 0 0 65"
reset; drive merge; cfg dog v2; touch "$FAKE_LOG/token-fail"
drive merge; check "merge, sem credencial: INERTE silencioso" "$(verdict) $RC $(ls "$CITY/.gc/logs" 2>/dev/null | wc -l | tr -d ' ')" "VEREDITO: INERTE 0 0"
reset; drive merge; printf v2 >"$FAKE_LOG/cfg"; mode dog brake0
drive merge; check "merge, papel no teto do dia: ele fica de fora e o resto decide" "$(verdict) $(jl .papeis.dog.cat) $(jl .papeis.reviewer.cat)" "VEREDITO: COMPLETO pulado ok"
check "merge, papel no teto do dia: a mudança dele NÃO vira medida (tenta de novo quando o teto voltar)" "$(jq -r .dog "$LAST") $(jq -r .reviewer "$LAST" | cut -c1-8)" "$(sha dogv1) $(sha reviewerv2 | cut -c1-8)"
reset; drive night; drive merge; check "a noite grava a configuração medida: merge logo depois não repete" "$(verdict) $(nrun dog)" "VEREDITO: PULADO 1"

reset; python3 -I -c 'import fcntl,sys,time; f = open(sys.argv[1], "w"); fcntl.flock(f, 2); open(sys.argv[2], "w").close(); time.sleep(60)' "$CITY/.gc/agent-battery/night.lock" "$W/held" & HOLD=$!
for _ in $(seq 50); do [ -e "$W/held" ] && break; sleep 0.1; done
drive night; check "rodada da noite já em andamento: PULADO, com linha no jsonl, sem e-mail" "$(verdict) $RC $(jl .verdict) $(ls "$FAKE_LOG" | grep -c mail)" "VEREDITO: PULADO 0 PULADO 0"
drive merge; check "o lock da noite não segura o merge (um lock por modo)" "$(verdict)" "VEREDITO: PULADO"
check "o lock da noite não segura o merge: a sondagem rodou" "$(nrun dog) $(ls "$FAKE_LOG" | grep -c exec-)" "0 3"
kill "$HOLD" 2>/dev/null

reset; mkdir -p "$CITY/.gc/logs/agent-battery"; touch "$CITY/.gc/logs/agent-battery/velho.md" "$CITY/.gc/logs/agent-battery/outro.txt" "$CITY/.gc/logs/agent-battery/recente.md"
python3 -I -c 'import os,sys,time; [os.utime(sys.argv[1] + "/" + n, (time.time() - d * 86400,) * 2) for n, d in (("velho.md", 30), ("outro.txt", 30), ("recente.md", 10))]' "$CITY/.gc/logs/agent-battery"
drive night; check "retenção: relatório com mais de 14 dias sai; o recente, o de hoje e o que não é .md ficam" "$(ls "$CITY/.gc/logs/agent-battery" | tr '\n' ' ')" "$DAY.md outro.txt recente.md "

reset; drive night --min-medidas 8; check "fronteira: exatamente o mínimo é COMPLETO" "$(verdict)" "VEREDITO: COMPLETO"
reset; drive night --min-medidas 9; check "fronteira: um abaixo do mínimo é FALHOU" "$(verdict)" "VEREDITO: FALHOU"
reset; ABN_MIN_MEDIDAS=9 drive night; check "a opção também vem de ABN_<NOME>" "$(verdict)" "VEREDITO: FALHOU"
reset; drive night --min-medidas 0; check "número não positivo: exit 2" "$RC" 2
reset; drive night --config-ref origin/outro; check "o executor roda do main; a configuração sob teste vai em --config-ref" "$(verdict) $(jq -r '.argv | .[index("--config-ref")+1]' "$FAKE_LOG/exec-dog.log")" "VEREDITO: COMPLETO origin/outro"
reset; drive night --node-state "$W/estado do nó"; check "caminho com espaço no nó: COMPLETO e o acervo foi para lá" "$(verdict) $(LC_ALL=C ls "$W/estado do nó" | tr '\n' ' ')" "VEREDITO: COMPLETO tasks.jsonl tasks.jsonl.meta.json "

reset; for r in dog wa-worker reviewer; do mode $r notasks; done
drive night; check "acervo sem tarefa utilizável (rc 3) em todos: INERTE, exit 0" "$(verdict) $RC" "VEREDITO: INERTE 0"
reset; touch "$FAKE_LOG/ssh-down-run"
drive night; check "ssh cai na hora de rodar (o acervo já tinha ido): FALHOU, nó inalcançável" "$(verdict) $(jl .reason | grep -c inalcançável)" "VEREDITO: FALHOU 1"
reset; drive night --prefix .errado; check "executor que não está no origin/main do nó (rc 96): FALHOU" "$(verdict) $(jl .reason | grep -c 'executor ausente')" "VEREDITO: FALHOU 1"
reset; ( export TMPDIR=/nao/existe; drive night ); check "mktemp que falha no nó (rc 97): FALHOU" "$(verdict) $(jl .reason | grep -c mktemp)" "VEREDITO: FALHOU 1"
reset; touch "$FAKE_LOG/token-short"; drive night; check "chave com cara errada: INERTE e nenhum executor" "$(verdict) $(ls "$FAKE_LOG" | grep -c '^exec-')" "VEREDITO: INERTE 0"
reset; mode dog leak; TOKEN=chave-comum-0123456789abcdefghij drive night
check "chave fora do formato sk-ant: só o token conhecido a esconde (controle: o executor a imprimiu)" "$(grep -q 'falhou com \*\*\* e com' "$CITY/.gc/logs/agent-battery/$DAY.md" && echo sim) $(grep -rl 'chave-comum' "$CITY/.gc/logs" "$FAKE_LOG/mail-body" "$FAKE_LOG/mail-subj" "$W/out" | wc -l | tr -d ' ')" "sim 0"
reset; rm "$CITY/.gc/hetzner-node.on"; ln -s hetzner-node.on "$CITY/.gc/hetzner-node.on"
drive night; check "bandeira que não dá para ler (laço de links): FALHOU, nunca 'desligado'" "$(verdict) $(jl .reason | grep -c bandeira)" "VEREDITO: FALHOU 1"
if [ "$(id -u)" != 0 ]; then
  reset; chmod 000 "$CITY/.gc/agent-battery/tasks.jsonl"; drive night
  check "acervo que existe e não lê: FALHOU, nunca 'sem acervo'" "$(verdict) $(jl .reason | grep -c 'não consegui ler')" "VEREDITO: FALHOU 1"
fi

reset; drive merge; cfg dog v2; touch "$FAKE_LOG/dry-garbage"
drive merge; check "merge, sondagem ilegível: PULADO silencioso, ninguém roda, e o motivo é a sondagem" "$(verdict) $(nrun dog) $(grep -c sondar "$W/out")" "VEREDITO: PULADO 0 1"
reset; drive merge; cfg dog v2; cfg reviewer v2; touch "$FAKE_LOG/dry-garbage-reviewer"
drive merge; check "merge, papel mudo na sondagem: não sei ≠ mudou, só o outro roda" "$(nrun dog) $(nrun reviewer)" "1 0"
reset; drive merge; echo '[1]' >"$LAST"; cfg dog v2
drive merge; check "merge-last.json torto: regrava a base dos 3 papéis e não mede" "$(verdict) $(nrun dog) $(jq -r 'keys | length' "$LAST")" "VEREDITO: PULADO 0 3"
reset; drive merge; cfg dog v2; mode dog garbage
drive merge; drive merge; check "merge, falha sem resumo: a mudança é tentada uma vez só" "$(nrun dog) $(grep -c FALHOU "$FAKE_LOG/mail-subj")" "1 1"
reset; drive merge; cfg dog v2; mode dog brakefew
drive merge; check "merge, teto com amostra pequena (não zero): FALHOU, não PULADO" "$(verdict)" "VEREDITO: FALHOU"

reset; drive merge; cfg dog v2; drive merge --token-cmd "'sem fechar"
check "merge, erro inesperado do driver: exit 1 e SEM e-mail (uma sondagem a cada 20 min não pode inundar)" "$RC $(ls "$FAKE_LOG" | grep -c mail)" "1 0"
reset; drive night --ssh /nao/existe/ssh; check "ssh que nem existe: FALHOU, nada de erro cru" "$(verdict) $(jl .reason | grep -c 'enviar o acervo')" "VEREDITO: FALHOU 1"
reset; drive night --limit -1; check "--limit negativo: exit 2" "$RC" 2
reset; drive night --roles ,; check "lista de papéis vazia: exit 2" "$RC" 2
reset; touch "$FAKE_LOG/token-failprint"; drive night; check "chave que o comando imprime mas sai com erro: INERTE (rc conta)" "$(verdict) $(ls "$FAKE_LOG" | grep -c '^exec-')" "VEREDITO: INERTE 0"
reset; rm -rf "$CITY/.gc/agent-battery"; drive night; check "cidade sem a pasta de estado: INERTE (sem acervo), nunca erro" "$(verdict) $RC" "VEREDITO: INERTE 0"
reset; mode dog nocfg; drive night; check "resumo JSON sem config_sha: ilegível, FALHOU" "$(verdict) $(jl .papeis.dog.motivo | grep -c 'sem resumo legível')" "VEREDITO: FALHOU 1"
reset; mode dog banner; drive night; check "linha de ruído ANTES do resumo: vale a última linha" "$(verdict) $(jl .papeis.dog.medidas)" "VEREDITO: COMPLETO 8"
reset; mode dog weirdtaxa; drive night; check "taxa e estados de tipo errado: COMPLETO, no jsonl taxa e por_estado viram null (a fatia 4 lê tipo estável) e o relatório sai" "$(verdict) $(jl '.papeis.dog | [.taxa, .por_estado] | map(tostring) | join(" ")') $(rep | grep -c -E '^\| dog \| [0-9a-f]{12} \| 8 \| 6 \| - \| - \|')" "VEREDITO: COMPLETO null null 1"
check "sha do acervo que não é hex: o jsonl grava null, nunca o texto estranho" "$(jl .papeis.dog.acervo)" null
reset; drive merge; cfg dog v2; mode dog zero; drive merge; check "merge, zero medidas SEM freio: FALHOU (só o freio de tokens é PULADO)" "$(verdict)" "VEREDITO: FALHOU"
reset; drive merge; cfg dog v2; cfg reviewer v2; touch "$FAKE_LOG/dry-badsha-reviewer" "$FAKE_LOG/dry-rc3-wa-worker"; cfg wa-worker v2
drive merge; check "merge, sondagem com sha torto ou rc ≠ 0: o papel fica de fora" "$(nrun dog) $(nrun reviewer) $(nrun wa-worker)" "1 0 0"

[ "$FAILS" -eq 0 ] && echo "TUDO OK" || echo "$FAILS falha(s)"
[ "$FAILS" -eq 0 ]
