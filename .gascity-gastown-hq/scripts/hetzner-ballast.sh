#!/bin/bash
# hetzner-ballast.sh — o lado do MINI do lastro do nó Hetzner (ga-2hd02v.5). Roda no mini; o governo (hetzner-ballast.py) roda NO nó. Runbook: docs/runbooks/hetzner-ballast.md
#
# Contents
#   Subcomandos · Códigos de saída · O que sobe e o que NUNCA sobe
#
# SUBCOMANDOS
#   install [--allow-dirty]  sobe o governo, os itens e o registro (sha256 conferido ANTES de trocar qualquer arquivo) e põe UMA linha marcada na crontab do `runner` (a cada minuto). NÃO liga o lastro.
#   uninstall                tira a linha marcada da crontab e para o que roda (stop). Os arquivos e os resultados ficam no nó.
#   on | off                 cria / apaga a chave `on` no nó (off também para o que roda). Sem `on` o governo só mede e não começa nada.
#   burn on | off            liga / desliga o item `queima` (CPU pura quando não há trabalho útil; nasce DESLIGADO).
#   status                   o que roda, a chave, a crontab e a idade do último tick (PARADO = cron instalado e último tick com mais de 5 min).
#   pull                     traz results.jsonl do nó para <cidade>/.gc/hetzner-ballast/results.jsonl: só a lista branca de campos, valores curtos, sem duplicar a rodada.
# CÓDIGOS DE SAÍDA: 0 ok · 2 uso · 3 recusado por não poder conferir (árvore suja, arquivo que chegou diferente, git ilegível) · 98 ssh fora (nada mudou) · 99 nó desligado (falta .gc/hetzner-node.on)
# O QUE SOBE: só código e config do próprio lastro, do que está COMMITADO (com --allow-dirty o instalado.json diz dirty:true). Nenhum dado, segredo ou credencial. O que volta: resumos (contagens e nomes de
#   arquivo de código), nunca log inteiro.
set -u
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
CITY=${GC_CITY_PATH:-$(cd "$SELF/.." && pwd -P)}
NODE=${HETZNER_NODE_HOST:-hetzner-teste}
SSH=${HB_SSH:-ssh}
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
OUTDIR="$CITY/.gc/hetzner-ballast"
MARK="# gt-ballast"
GOV=hetzner-ballast.py; REG=hetzner-ballast.items.txt; ITEMS_DIR=hetzner-ballast-items
say() { echo "hetzner-ballast: $*"; }
die() { local rc=$1; shift; echo "hetzner-ballast: $*" >&2; exit "$rc"; }
rsh() { "$SSH" "${SSH_OPTS[@]}" "$NODE" "$@"; }   # um comando remoto; rc 255 = ssh não conectou
sha_local() { if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
SHA_REMOTE='if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d" " -f1'
need_node_flag() { [ -e "$CITY/.gc/hetzner-node.on" ] || die 99 "o nó está desligado (falta $CITY/.gc/hetzner-node.on): nada foi feito"; }
stop_remote() { rsh 'python3 -I "$HOME/gt-remote/bin/hetzner-ballast.py" stop' 2>&1; }

cmd_install() {
  local allow=0 f rel dst files=() dirty head want got rc
  [ "${1:-}" = "--allow-dirty" ] && allow=1
  need_node_flag
  [ -r "$SELF/$GOV" ] && [ -r "$SELF/$REG" ] && [ -d "$SELF/$ITEMS_DIR" ] || die 3 "faltam arquivos do lastro em $SELF ($GOV, $REG, $ITEMS_DIR/)"
  # vazio (nada mudado) → limpo; falhou/ilegível (sem git ou fora de um repo) → NÃO sei: recuso, nunca "limpo"
  dirty=$(git -C "$SELF" status --porcelain --untracked-files=all -- "$GOV" "$REG" "$ITEMS_DIR" 2> /dev/null; echo "rc=$?")
  case "$dirty" in
    "rc=0") dirty=false ;;
    rc=*) die 3 "não consegui ler o estado do git em $SELF: não subo o que não sei se está commitado" ;;
    *) [ "$allow" = 1 ] && dirty=true || die 3 "mudança NÃO commitada nos arquivos do lastro (sobe o que está no git, não o que está na mesa); commite ou use --allow-dirty:
$(printf '%s' "$dirty" | grep -v '^rc=')" ;;
  esac
  head=$(git -C "$SELF" rev-parse HEAD 2> /dev/null) || head=desconhecido
  # nome local → destino remoto. O registro vira items.tsv; os itens vão para items/
  local pairs=("$GOV|\$HOME/gt-remote/bin/hetzner-ballast.py|755" "$REG|\$HOME/gt-remote/ballast/items.tsv|644")
  for f in "$SELF/$ITEMS_DIR"/*.sh; do [ -f "$f" ] && pairs+=("$ITEMS_DIR/$(basename "$f")|\$HOME/gt-remote/ballast/items/$(basename "$f")|755"); done
  # fase 1: sobe tudo como .new e confere o sha256 — qualquer diferença aborta SEM trocar nenhum arquivo nem a crontab
  local p
  for p in "${pairs[@]}"; do
    rel=${p%%|*}; dst=${p#*|}; dst=${dst%|*}; local mode=${p##*|}
    want=$(sha_local "$SELF/$rel")
    got=$(rsh "umask 022; mkdir -p \"\$(dirname \"$dst\")\" && cat > \"$dst.new\" && chmod $mode \"$dst.new\" && set -- \"$dst.new\" && $SHA_REMOTE" < "$SELF/$rel" 2> /dev/null); rc=$?
    [ "$rc" -ne 255 ] || die 98 "ssh não conectou ($NODE): nada foi instalado"
    [ "$got" = "$want" ] || { die 3 "o arquivo $rel chegou diferente (esperado $want, veio '${got:-nada}'): nada foi trocado"; }
  done
  # fase 2: troca
  for p in "${pairs[@]}"; do dst=${p#*|}; dst=${dst%|*}; rsh "mv -f \"$dst.new\" \"$dst\"" || die 3 "não consegui trocar $dst"; done
  local sums="" now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  for p in "${pairs[@]}"; do rel=${p%%|*}; sums="$sums\"$rel\": \"$(sha_local "$SELF/$rel")\", "; done
  printf '{"head": "%s", "dirty": %s, "at": "%s", "files": {%s}}\n' "$head" "$dirty" "$now" "${sums%, }" | rsh 'cat > "$HOME/gt-remote/ballast/installed.json"' || die 3 "não gravei installed.json"
  # crontab: tira a linha marcada de antes, acrescenta UMA; as dos outros ficam. cron.err tem teto no próprio governo.
  rsh 'H=$HOME; T=$(mktemp); crontab -l 2> /dev/null | grep -v "'"$MARK"'" > "$T"; echo "* * * * * flock -n $H/gt-remote/ballast/cron.lock /usr/bin/python3 -I $H/gt-remote/bin/hetzner-ballast.py tick > /dev/null 2>> $H/gt-remote/ballast/cron.err '"$MARK"'" >> "$T"; crontab "$T"; rc=$?; rm -f "$T"; exit $rc' || die 3 "não consegui instalar a linha da crontab"
  say "instalado em $NODE (commit ${head:0:9}, dirty=$dirty): governo, ${#pairs[@]} arquivos e a crontab. O lastro está DESLIGADO: 'hetzner-ballast.sh on' para ligar."
}

cmd_uninstall() {
  rsh 'T=$(mktemp); crontab -l 2> /dev/null | grep -v "'"$MARK"'" > "$T"; crontab "$T"; rc=$?; rm -f "$T"; exit $rc' ; local rc=$?
  [ "$rc" -ne 255 ] || die 98 "ssh não conectou ($NODE)"
  [ "$rc" -eq 0 ] || die 3 "não consegui tirar a linha da crontab"
  stop_remote | sed 's/^/  stop: /'
  say "desinstalado: a linha da crontab saiu e o que rodava foi parado; arquivos e resultados ficam em ~/gt-remote/ballast no nó"
}

cmd_flag() {  # cmd_flag NOME on|off
  local rc
  if [ "$2" = on ]; then rsh "mkdir -p \"\$HOME/gt-remote/ballast\" && : > \"\$HOME/gt-remote/ballast/$1\""; else rsh "rm -f \"\$HOME/gt-remote/ballast/$1\""; fi; rc=$?
  [ "$rc" -ne 255 ] || die 98 "ssh não conectou ($NODE)"
  [ "$rc" -eq 0 ] || die 3 "não consegui mexer na chave $1"
  if [ "$1" = on ] && [ "$2" = off ]; then stop_remote | sed 's/^/  stop: /'; fi
  say "chave $1 → $2"
}

cmd_status() {
  local raw rc
  raw=$(rsh 'B="$HOME/gt-remote/ballast"; echo "now=$(date +%s)"; crontab -l 2> /dev/null | grep -q "'"$MARK"'" && echo cron=1 || echo cron=0; [ -e "$B/on" ] && echo on=1 || echo on=0; [ -e "$B/burn.on" ] && echo burn=1 || echo burn=0
    echo "tick=$(tail -n 1 "$B/ticks.jsonl" 2> /dev/null)"; echo "installed=$(cat "$B/installed.json" 2> /dev/null)"; echo "status=$(python3 -I "$HOME/gt-remote/bin/hetzner-ballast.py" status 2> /dev/null)"') ; rc=$?
  [ "$rc" -ne 255 ] || die 98 "ssh não conectou ($NODE)"
  printf '%s\n' "$raw" | python3 -I -c '
import json, sys
kv = {}
for l in sys.stdin.read().splitlines():
    k, _, v = l.partition("=")
    kv.setdefault(k, v)
def js(s):
    try:
        return json.loads(s)
    except ValueError:
        return None
print("cron: " + ("instalado" if kv.get("cron") == "1" else "não instalado"))
print("chave on: %s · burn: %s" % ("LIGADO" if kv.get("on") == "1" else "desligado", "ligado" if kv.get("burn") == "1" else "desligado"))
inst = js(kv.get("installed", ""))
print("instalado: " + (("commit %s dirty=%s em %s" % (str(inst.get("head"))[:9], inst.get("dirty"), inst.get("at"))) if isinstance(inst, dict) else "(sem installed.json)"))
tick = js(kv.get("tick", ""))
now = int(kv["now"]) if kv.get("now", "").isdigit() else None
if isinstance(tick, dict) and isinstance(tick.get("t"), int) and now is not None:
    age = now - tick["t"]
    print("último tick: há %ds (%s) rodando=%s livre=%s%% ram=%sMB" % (age, tick.get("mode"), tick.get("running"), tick.get("free_pct"), tick.get("mem_avail_mb")))
    if kv.get("cron") == "1" and age > 300:
        print("PARADO: o cron está instalado e o último tick tem mais de 5 min — olhe ~/gt-remote/ballast/cron.err no nó")
else:
    print("último tick: (nenhum registrado)")
st = js(kv.get("status", ""))
if isinstance(st, dict):
    for it in st.get("items", []):
        print("  item %-14s %-6s núcleos=%-4s %s" % (it.get("name"), it.get("role"), it.get("cores"), "elegível" if it.get("eligible") else "inerte: " + str(it.get("why"))))
    for e in st.get("registry_errors", []):
        print("  ERRO NO REGISTRO: " + str(e))
'
}

cmd_pull() {
  local raw rc
  raw=$(rsh 'cat "$HOME/gt-remote/ballast/results.jsonl" 2> /dev/null'); rc=$?
  [ "$rc" -ne 255 ] || die 98 "ssh não conectou ($NODE): results.jsonl local fica como estava"
  mkdir -p "$OUTDIR" || die 3 "não criei $OUTDIR"
  printf '%s\n' "$raw" | python3 -I -c '
import json, os, sys
out = sys.argv[1]
KEEP = ("ts", "item", "run", "role", "cores", "start", "secs", "rc", "why", "summary", "summary_why")
def scal(v):
    if isinstance(v, str):
        return v[:160]
    return v if isinstance(v, (int, float, bool)) or v is None else None
def clean(sm):
    if not isinstance(sm, dict):
        return None
    o = {}
    for k, v in sm.items():
        if isinstance(v, list):
            o[str(k)[:60]] = [scal(x) for x in v[:40] if scal(x) is not None]
        elif isinstance(v, dict):
            o[str(k)[:60]] = {str(a)[:60]: scal(b) for a, b in list(v.items())[:40] if scal(b) is not None}
        else:
            o[str(k)[:60]] = scal(v)
    return o
seen = set()
if os.path.exists(out):
    for l in open(out, encoding="utf-8"):
        try:
            seen.add(json.loads(l).get("run"))
        except ValueError:
            pass
new = drop = 0
lines = []
for l in sys.stdin.read().splitlines():
    if not l.strip():
        continue
    try:
        d = json.loads(l)
    except ValueError:
        drop += 1
        print("hetzner-ballast: linha descartada (não é JSON): %s" % l[:60], file=sys.stderr)
        continue
    if not isinstance(d, dict) or not isinstance(d.get("run"), str):
        drop += 1
        print("hetzner-ballast: linha descartada (sem run): %s" % l[:60], file=sys.stderr)
        continue
    if d["run"] in seen:
        continue
    row = {k: (clean(d[k]) if k == "summary" else scal(d[k])) for k in KEEP if k in d}
    s = json.dumps(row)
    if len(s) > 8000:
        row["summary"] = None
        row["summary_why"] = "grande-demais"
        s = json.dumps(row)
    lines.append(s)
    seen.add(d["run"])
    new += 1
if lines:
    with open(out, "a", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
print("hetzner-ballast: pull: %d novas, %d descartadas (descartada = linha que não é um resultado válido)" % (new, drop))
' "$OUTDIR/results.jsonl" 2>&1
}

case "${1:-}" in
  install)   shift; cmd_install "$@" ;;
  uninstall) cmd_uninstall ;;
  on)        need_node_flag; cmd_flag on on ;;
  off)       cmd_flag on off ;;
  burn)      case "${2:-}" in on|off) cmd_flag burn.on "$2" ;; *) die 2 "uso: hetzner-ballast.sh burn on|off" ;; esac ;;
  status)    cmd_status ;;
  pull)      cmd_pull ;;
  *)         die 2 "uso: hetzner-ballast.sh install [--allow-dirty] | uninstall | on | off | burn on|off | status | pull" ;;
esac
