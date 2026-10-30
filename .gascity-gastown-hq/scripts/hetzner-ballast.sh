#!/bin/bash
# hetzner-ballast.sh — o lado do MINI do lastro do nó Hetzner (ga-2hd02v.5). Roda no mini; o governo (hetzner-ballast.py) roda NO nó. Runbook: docs/runbooks/hetzner-ballast.md (fatia 5/5 da ga-2hd02v.5)
#
# Contents
#   Subcomandos · Códigos de saída · O que sobe e o que NUNCA sobe · Leitura que falha
#
# SUBCOMANDOS
#   install [--allow-dirty]  sobe o governo, os itens e o registro (sha256 conferido ANTES de trocar qualquer arquivo) e põe UMA linha marcada na crontab do `runner` (a cada minuto). NÃO liga o lastro.
#   uninstall                tira a linha marcada da crontab e para o que roda (stop). Os arquivos e os resultados ficam no nó.
#   on | off                 cria / apaga a chave `on` no nó (off também para o que roda). Sem `on` o governo só mede e não começa nada. `on` RECUSA (rc 3) se o governo do nó não confirma o teto de sistema pronto (ga-kgnjkt8).
#   burn on | off            liga / desliga o item `queima` (CPU pura quando não há trabalho útil; nasce DESLIGADO).
#   status                   o que roda, a chave, a crontab, a linha `teto:` (pronto / NÃO PRONTO / governo antigo sem teto) e a idade do último tick (PARADO = cron instalado e último tick com mais de 5 min, ou nenhum tick 5 min depois do install).
#   pull                     traz results.jsonl do nó para <cidade>/.gc/hetzner-ballast/results.jsonl: só a lista branca de campos, valores curtos, sem duplicar a rodada.
# CÓDIGOS DE SAÍDA: 0 ok · 2 uso · 3 recusado ou NÃO consegui (árvore suja, arquivo que chegou diferente, git ilegível, crontab ilegível, stop que não parou, results.jsonl ilegível, status com leitura que falhou)
#   · 98 ssh fora (não conectou, ou caiu antes de eu ler o resultado de um stop ou da crontab: o que não deu para ler não vale como feito) · 99 nó desligado (falta .gc/hetzner-node.on)
# O QUE SOBE: só código e config do próprio lastro (o governo, o registro, os itens e o plugin gtn_stable_ids.py do pytest), do que está COMMITADO (o que sobe é, byte a byte, o blob do HEAD; com --allow-dirty o instalado.json diz dirty:true). Nenhum dado, segredo ou credencial.
#   O que volta: resumos (contagens e nomes de arquivo de código), nunca log inteiro. A troca de arquivos do install (fase 2) não é atômica entre eles: falha no meio = rc 3 e geração mista no nó — rode install de novo.
# LEITURA QUE FALHA: toda leitura tem três respostas — tem · não tem · não consegui saber — e a terceira nunca vira "vazio", "não instalado", "sem itens" nem "parado": o comando diz que não leu e sai com rc ≠ 0.
#   Quem escreve a partir de uma leitura (crontab) não escreve se não leu; "off" e "uninstall" só dizem que o que rodava foi parado se o stop do governo respondeu rc 0.
set -u
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
CITY=${GC_CITY_PATH:-$(cd "$SELF/.." && pwd -P)}
NODE=${HETZNER_NODE_HOST:-hetzner-teste}
SSH=${HB_SSH:-ssh}
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
OUTDIR="$CITY/.gc/hetzner-ballast"
MARK="# gt-ballast"
GOV=hetzner-ballast.py; REG=hetzner-ballast.items.txt; ITEMS_DIR=hetzner-ballast-items; PLUG=gtn_stable_ids.py
USO="uso: hetzner-ballast.sh install [--allow-dirty] | uninstall | on | off | burn on|off | status | pull"
say() { echo "hetzner-ballast: $*"; }
die() { local rc=$1; shift; echo "hetzner-ballast: $*" >&2; exit "$rc"; }
rsh() { "$SSH" "${SSH_OPTS[@]}" "$NODE" "$@"; }   # um comando remoto; rc 255 = ssh não conectou
sha_local() { if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
SHA_REMOTE='if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d" " -f1'
need_node_flag() { [ -e "$CITY/.gc/hetzner-node.on" ] || die 99 "o nó está desligado (falta $CITY/.gc/hetzner-node.on): nada foi feito"; }
# remoto (sh): lê a crontab do runner UMA vez (um só `crontab -l`, stderr junto) e deixa em $T a que fica (sem a linha marcada). rc 0 = o texto é a crontab; rc ≠ 0 com "no crontab for <user>" = não há crontab
# (vazio de verdade); qualquer outro erro do `crontab -l` = NÃO sei → sai 4 SEM escrever nada, porque regravar a partir de uma leitura que falhou apagaria as linhas dos outros. grep com erro (rc ≥ 2) ou mktemp que falha → 3.
CRON_READ='M=$(crontab -l 2>&1); cr=$?
if [ "$cr" -eq 0 ]; then CUR=$M; else case "$M" in *"no crontab for"*) CUR= ;; *) echo "crontab -l falhou (rc=$cr): $M" >&2; exit 4 ;; esac; fi
T=$(mktemp) || exit 3
if [ -n "$CUR" ]; then printf "%s\n" "$CUR" | grep -v "'"$MARK"'" > "$T"; g=$?; [ "$g" -le 1 ] || { rm -f "$T"; exit 3; }; else : > "$T"; fi'

# o stop do governo no nó, com a saída prefixada. Devolve o rc de lá: 0 parou · 3 o governo não leu os processos e NÃO matou nada · 255 o ssh caiu (não sei) · outro = o stop nem rodou (governo ausente, sem python3).
stop_remote() {
  local out rc
  out=$(rsh 'python3 -I "$HOME/gt-remote/bin/hetzner-ballast.py" stop' 2>&1); rc=$?
  [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/  stop: /'
  return "$rc"
}
# "parado" só com rc 0: qualquer outro resultado termina com rc ≠ 0 e SEM dizer que parou ($1 = o que já foi feito de fato antes do stop)
stop_or_die() {
  local rc
  stop_remote; rc=$?
  [ "$rc" -ne 0 ] || return 0
  [ "$rc" -ne 255 ] || die 98 "$1, mas o ssh caiu antes de eu ler o resultado do stop: NÃO sei se o que roda parou — confira no nó"
  die 3 "$1, mas NÃO consegui parar o que roda (stop rc=$rc): confira no nó (ps, ~/gt-remote/ballast)"
}

# O governo do nó é a trava de verdade (sem teto pronto nenhum item começa); aqui o `on` só não deixa ligar às cegas. Volta 0 = pode ligar (teto pronto, ou governo ainda não instalado: nada roda até o install).
# Recusa (rc 3) com o motivo se o teto não está pronto, se o governo é antigo (o status não traz `ceiling`) ou se NÃO consegui ler a resposta: falta de leitura nunca vira "pronto". ssh que cai = rc 98.
need_ceiling_ready() {
  local raw rc v
  raw=$(rsh 'g="$HOME/gt-remote/bin/hetzner-ballast.py"; if [ -e "$g" ]; then python3 -I "$g" status 2> /dev/null; echo "status_rc=$?"; else echo "status_rc=absent"; fi'); rc=$?
  [ "$rc" -ne 255 ] || die 98 "ssh não conectou ($NODE): não liguei o lastro"
  [ "$rc" -eq 0 ] || die 3 "não consegui perguntar ao governo do nó se o teto está pronto (rc=$rc): não liguei o lastro"
  # vazio/falhou (sem a linha status_rc, status que saiu ≠ 0, resposta que não é um objeto JSON) → ilegivel; sem `ceiling` (ou sem `ready`) → antigo; governo ausente → absent
  v=$(printf '%s\n' "$raw" | python3 -I -c '
import json, sys
ls = sys.stdin.read().splitlines()
rl = [l for l in ls if l.startswith("status_rc=")]
if not rl:
    print("ilegivel")
elif rl[-1] == "status_rc=absent":
    print("absent")
elif rl[-1] != "status_rc=0":
    print("ilegivel")
else:
    try:
        d = json.loads("\n".join(l for l in ls if not l.startswith("status_rc=")))
    except ValueError:
        d = None
    c = d.get("ceiling") if isinstance(d, dict) else None
    if not isinstance(d, dict):
        print("ilegivel")
    elif not isinstance(c, dict) or "ready" not in c:
        print("antigo")
    elif c.get("ready") is True:
        print("pronto")
    else:
        print("nao:" + str(c.get("why", ""))[:300])
')
  case "$v" in
    pronto|absent) return 0 ;;
    antigo) die 3 "o governo instalado no nó não conhece teto (o status dele não traz 'ceiling'): rode 'hetzner-ballast.sh install' com o commit do teto antes de ligar. Não pus a chave on agora (se ela já existia de um on anterior, continua: 'off' a apaga)." ;;
    nao:*) die 3 "o teto NÃO está pronto no nó e sem ele nenhum item começa: ${v#nao:}. Remédio, se faltar o linger: 'loginctl enable-linger runner' (root, uma vez, no nó; uma sessão aberta NÃO basta, o cron não tem sessão); depois repita o on. Não pus a chave on agora (se ela já existia de um on anterior, continua: o governo não começa item sem teto, e 'off' a apaga)." ;;
    *) die 3 "não consegui ler a resposta do governo do nó sobre o teto: não liguei o lastro (falta de leitura NÃO é 'pronto'). Não pus a chave on agora (se ela já existia de um on anterior, continua: 'off' a apaga)." ;;
  esac
}

cmd_install() {
  local allow=0 f rel dst files=() dirty head want got rc p mode a b now sums=""
  [ "${1:-}" = "--allow-dirty" ] && allow=1
  need_node_flag
  [ -r "$SELF/$GOV" ] && [ -r "$SELF/$REG" ] && [ -d "$SELF/$ITEMS_DIR" ] && [ -r "$SELF/$PLUG" ] || die 3 "faltam arquivos do lastro em $SELF ($GOV, $REG, $ITEMS_DIR/, $PLUG)"
  # nome local → destino remoto. O registro vira items.tsv; os itens vão para items/. O plugin do pytest (item wa-suite, ga-2hd02v.8) vai para ~/gt-remote/bin/: o gt-iso-run fixa PYTHONPATH lá
  # (a bateria noturna põe o mesmo arquivo no mesmo lugar). Mesmas conferências dos outros: sha256 no nó, blob do HEAD, árvore limpa.
  local pairs=("$GOV|\$HOME/gt-remote/bin/hetzner-ballast.py|755" "$REG|\$HOME/gt-remote/ballast/items.tsv|644" "$PLUG|\$HOME/gt-remote/bin/gtn_stable_ids.py|644")
  for f in "$SELF/$ITEMS_DIR"/*.sh; do [ -f "$f" ] && pairs+=("$ITEMS_DIR/$(basename "$f")|\$HOME/gt-remote/ballast/items/$(basename "$f")|755"); done
  # vazio (nada mudado) → limpo; falhou/ilegível (sem git ou fora de um repo) → NÃO sei: recuso, nunca "limpo"
  dirty=$(git -C "$SELF" status --porcelain --untracked-files=all -- "$GOV" "$REG" "$ITEMS_DIR" "$PLUG" 2> /dev/null; echo "rc=$?")
  case "$dirty" in
    "rc=0") dirty=false ;;
    rc=*) die 3 "não consegui ler o estado do git em $SELF: não subo o que não sei se está commitado" ;;
    *) [ "$allow" = 1 ] && dirty=true || die 3 "mudança NÃO commitada nos arquivos do lastro (sobe o que está no git, não o que está na mesa); commite ou use --allow-dirty:
$(printf '%s' "$dirty" | grep -v '^rc=')" ;;
  esac
  # o `status` acima não enxerga arquivo ignorado nem o marcado assume-unchanged/skip-worktree: o que sobe tem que ser, byte a byte, o blob do HEAD.
  # igual → segue; diferente, fora do HEAD ou git que falhou → recuso (com --allow-dirty sobe e o instalado.json diz dirty:true); os dois vazios NÃO são "iguais" (o -n impede)
  if [ "$dirty" = false ]; then
    for p in "${pairs[@]}"; do
      rel=${p%%|*}
      a=$(git -C "$SELF" hash-object -- "$SELF/$rel" 2> /dev/null); b=$(git -C "$SELF" rev-parse "HEAD:./$rel" 2> /dev/null)
      [ -n "$a" ] && [ "$a" = "$b" ] && continue
      [ "$allow" = 1 ] && { dirty=true; continue; }
      die 3 "o arquivo $rel não é o que está no HEAD (ignorado, assume-unchanged, fora do git ou git ilegível): sobe o que está no git; commite ou use --allow-dirty"
    done
  fi
  head=$(git -C "$SELF" rev-parse HEAD 2> /dev/null) || head=desconhecido
  # fase 1: sobe tudo como .new e confere o sha256 — qualquer diferença aborta SEM trocar nenhum arquivo nem a crontab
  for p in "${pairs[@]}"; do
    rel=${p%%|*}; dst=${p#*|}; dst=${dst%|*}; mode=${p##*|}
    # sha256 local que não saiu → NÃO sei conferir: não envio (dois vazios — o local e o que o nó devolveria — passariam como "iguais")
    want=$(sha_local "$SELF/$rel"); [ -n "$want" ] || die 3 "não consegui calcular o sha256 de $rel aqui: não envio o que não sei conferir (nada foi trocado)"
    got=$(rsh "umask 022; mkdir -p \"\$(dirname \"$dst\")\" && cat > \"$dst.new\" && chmod $mode \"$dst.new\" && set -- \"$dst.new\" && $SHA_REMOTE" < "$SELF/$rel" 2> /dev/null); rc=$?
    [ "$rc" -ne 255 ] || die 98 "ssh não conectou ($NODE): nada foi instalado"
    [ "$got" = "$want" ] || { die 3 "o arquivo $rel chegou diferente (esperado $want, veio '${got:-nada}'): nada foi trocado"; }
    sums="$sums\"$rel\": \"$want\", "   # o installed.json guarda este sha, o que o nó conferiu: nunca um 2º cálculo que poderia sair vazio
  done
  # fase 2: troca
  for p in "${pairs[@]}"; do dst=${p#*|}; dst=${dst%|*}; rsh "mv -f \"$dst.new\" \"$dst\"" || die 3 "não consegui trocar $dst"; done
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"head": "%s", "dirty": %s, "at": "%s", "files": {%s}}\n' "$head" "$dirty" "$now" "${sums%, }" | rsh 'cat > "$HOME/gt-remote/ballast/installed.json"' || die 3 "não gravei installed.json"
  # crontab: tira a linha marcada de antes, acrescenta UMA; as dos outros ficam. cron.err tem teto no próprio governo. Crontab que não consegui ler (rc 4 de lá) → não escrevo nada
  rsh "$CRON_READ"'
H=$HOME; echo "* * * * * flock -n $H/gt-remote/ballast/cron.lock /usr/bin/python3 -I $H/gt-remote/bin/hetzner-ballast.py tick > /dev/null 2>> $H/gt-remote/ballast/cron.err '"$MARK"'" >> "$T"; crontab "$T"; rc=$?; rm -f "$T"; exit $rc'; rc=$?
  case "$rc" in
    0) ;;
    255) die 98 "ssh caiu na hora da crontab ($NODE): os arquivos do lastro já foram trocados, a crontab pode não ter mudado — confira e rode install de novo" ;;
    4) die 3 "não consegui LER a crontab do nó: não mexi nela (os arquivos do lastro já foram trocados; resolva a leitura e rode install de novo)" ;;
    *) die 3 "não consegui instalar a linha da crontab" ;;
  esac
  say "instalado em $NODE (commit ${head:0:9}, dirty=$dirty): governo, ${#pairs[@]} arquivos e a crontab. O lastro está DESLIGADO: 'hetzner-ballast.sh on' para ligar."
  say "O TETO por item exige o gerenciador de usuário do systemd no nó SEM sessão aberta (o cron não tem sessão; sem isso nenhum item começa): rode 'loginctl enable-linger runner' no nó, como root, uma vez. 'hetzner-ballast.sh status' diz se o teto está pronto e o 'on' recusa sem ele."
}

cmd_uninstall() {
  local rc
  # crontab que não consegui ler (rc 4 de lá) → não escrevo e NÃO paro nada: meia-desinstalação deixaria o cron ressuscitando o que o stop matou
  rsh "$CRON_READ"'
crontab "$T"; rc=$?; rm -f "$T"; exit $rc'; rc=$?
  case "$rc" in
    0) ;;
    255) die 98 "ssh não conectou ($NODE)" ;;
    4) die 3 "não consegui LER a crontab do nó: não mexi nela e NÃO parei o que roda" ;;
    *) die 3 "não consegui tirar a linha da crontab" ;;
  esac
  stop_or_die "a linha da crontab saiu"
  say "desinstalado: a linha da crontab saiu e o que rodava foi parado; arquivos e resultados ficam em ~/gt-remote/ballast no nó"
}

cmd_flag() {  # cmd_flag NOME on|off
  local rc out=""
  # `on`: o 2º comando diz se há algo instalado (installed.json). Sem installed.json → só AVISA (a chave fica posta); ssh/rsh que falhou → rc 98/3 antes de qualquer aviso
  if [ "$2" = on ]; then
    [ "$1" != on ] || need_ceiling_ready
    out=$(rsh "mkdir -p \"\$HOME/gt-remote/ballast\" && : > \"\$HOME/gt-remote/ballast/$1\" && { [ -e \"\$HOME/gt-remote/ballast/installed.json\" ] && echo instalado=1 || echo instalado=0; }"); rc=$?
  else
    rsh "rm -f \"\$HOME/gt-remote/ballast/$1\""; rc=$?
  fi
  [ "$rc" -ne 255 ] || die 98 "ssh não conectou ($NODE)"
  [ "$rc" -eq 0 ] || die 3 "não consegui mexer na chave $1"
  if [ "$1" = on ] && [ "$2" = off ]; then stop_or_die "a chave on foi apagada"; say "chave on → off (o que rodava foi parado)"; return 0; fi
  [ "$out" != "instalado=0" ] || echo "hetzner-ballast: AVISO: nada instalado no nó (sem installed.json): a chave $1 está posta, mas nada roda até o 'install'" >&2
  say "chave $1 → $2"
}

cmd_status() {
  local raw rc
  # cada leitura do nó traz o seu estado em <nome>_rc: 0 = leu · absent = não existe · outro = falhou. cron=? e dir=0 idem: ausente, vazio e "não consegui ler" nunca são a mesma resposta
  raw=$(rsh 'B="$HOME/gt-remote/ballast"; echo "now=$(date +%s)"
    C=$(crontab -l 2>&1); cr=$?
    if [ "$cr" -ne 0 ]; then case "$C" in *"no crontab for"*) cr=0; C= ;; esac; fi
    if [ "$cr" -ne 0 ]; then echo "cron=?"; else printf "%s\n" "$C" | grep -q "'"$MARK"'"; g=$?; if [ "$g" -eq 0 ]; then echo cron=1; elif [ "$g" -eq 1 ]; then echo cron=0; else echo "cron=?"; fi; fi
    [ -d "$B" ] && [ -x "$B" ] && echo dir=1 || echo dir=0
    [ -e "$B/on" ] && echo on=1 || echo on=0; [ -e "$B/burn.on" ] && echo burn=1 || echo burn=0
    rd() { if [ ! -e "$2" ]; then echo "$1_rc=absent"; return 0; fi; v=$($3 "$2" 2> /dev/null); r=$?; echo "$1_rc=$r"; echo "$1=$v"; }
    rd tick "$B/ticks.jsonl" "tail -n 1"; rd installed "$B/installed.json" cat
    s=$(python3 -I "$HOME/gt-remote/bin/hetzner-ballast.py" status 2> /dev/null); echo "status_rc=$?"; echo "status=$s"'); rc=$?
  [ "$rc" -ne 255 ] || die 98 "ssh não conectou ($NODE)"
  [ "$rc" -eq 0 ] || die 3 "o comando de status no nó falhou (rc=$rc): não sei o estado"
  printf '%s\n' "$raw" | python3 -I -c '
import calendar, json, sys, time
kv = {}
for l in sys.stdin.read().splitlines():
    k, _, v = l.partition("=")
    kv.setdefault(k, v)
bad = 0   # leitura que falhou: vira o rc do status (3), nunca um resultado vazio
def js(s):
    try:
        return json.loads(s)
    except ValueError:
        return None
cron = kv.get("cron")
if cron in ("0", "1"):
    print("cron: " + ("instalado" if cron == "1" else "não instalado"))
else:
    bad = 1
    print("cron: NÃO CONSEGUI LER a crontab do nó (não sei se o lastro está instalado)")
print("chave on: %s · burn: %s" % ("LIGADO" if kv.get("on") == "1" else "desligado", "ligado" if kv.get("burn") == "1" else "desligado"))
if kv.get("dir") != "1":
    bad = 1   # ausente e ilegível não se distinguem daqui: não sei, nunca "sem nada"
    print("pasta ~/gt-remote/ballast: AUSENTE ou ilegível no nó (o lastro não foi instalado, ou não consegui entrar nela): não sei o estado dele")
ist = kv.get("installed_rc")
inst = js(kv.get("installed", "")) if ist == "0" else None
if ist == "absent":
    print("instalado: (sem installed.json)")
elif isinstance(inst, dict):
    print("instalado: commit %s dirty=%s em %s" % (str(inst.get("head"))[:9], inst.get("dirty"), inst.get("at")))
else:
    bad = 1
    print("instalado: installed.json ILEGÍVEL (leitura rc=%s, ou o conteúdo não é JSON): não sei o que está instalado" % ist)
tst = kv.get("tick_rc")
traw = kv.get("tick", "")
tick = js(traw) if tst == "0" and traw.strip() else None
now = int(kv["now"]) if kv.get("now", "").isdigit() else None
age, why = None, ""
if tst == "absent" or (tst == "0" and not traw.strip()):
    print("último tick: (nenhum registrado)")
    try:   # sem tick, a idade é a do install; sem installed.json válido (ou sem a hora do nó) não sei há quanto tempo: não afirmo PARADO
        age = now - calendar.timegm(time.strptime(inst["at"], "%Y-%m-%dT%H:%M:%SZ"))
        why = "nenhum tick foi registrado desde o install, há %ds" % age
    except (TypeError, ValueError, KeyError):
        age = None
elif isinstance(tick, dict) and isinstance(tick.get("t"), int) and now is not None:
    age = now - tick["t"]
    why = "o último tick tem mais de 5 min"
    # a nota é o que o tick DISSE de si (sem-teto, teto-ilegivel:<rodada>, nao-comecou:<item>...): o status por ssh responde pelo contexto dele, só a nota mostra o que o cron enfrentou.
    # ausente ou vazia = o tick não teve nota (governo antigo, ou nada a dizer); presente mas não texto = ILEGÍVEL, nunca "sem nota"
    note = tick.get("note")
    nt = "" if note is None or note == "" else (" NOTA=%s" % note if isinstance(note, str) else " NOTA=ILEGÍVEL")
    print("último tick: há %ds (%s) rodando=%s livre=%s%% ram=%sMB%s" % (age, tick.get("mode"), tick.get("running"), tick.get("free_pct"), tick.get("mem_avail_mb"), nt))
else:
    bad = 1
    print("último tick: ILEGÍVEL (leitura rc=%s, ou a última linha não é um tick — truncada?): não sei se o cron está rodando" % tst)
if age is not None and age > 300:
    if cron == "1":
        print("PARADO: o cron está instalado e %s — olhe ~/gt-remote/ballast/cron.err no nó" % why)
    elif cron != "0":
        print("ATENÇÃO: %s e NÃO consegui ler a crontab: não sei se está PARADO" % why)
sr = kv.get("status_rc")
st = js(kv.get("status", "")) if sr == "0" else None
if isinstance(st, dict) and isinstance(st.get("items"), list):
    for it in st["items"]:
        print("  item %-14s %-6s núcleos=%-4s %s" % (it.get("name"), it.get("role"), it.get("cores"), "elegível" if it.get("eligible") else "inerte: " + str(it.get("why"))))
    for e in st.get("registry_errors") or []:
        print("  ERRO NO REGISTRO: " + str(e))
    c = st.get("ceiling")   # teto de sistema por item (ga-kgnjkt8): pronto / NÃO pronto (estado, não leitura que falhou) / governo antigo sem a chave (nunca "pronto")
    if isinstance(c, dict) and c.get("ready") is True:
        print("teto: pronto (%s, %s tarefas por item, memória = rss_mb x %s)" % (c.get("mode"), c.get("tasks_max"), c.get("mem_factor")))
    elif isinstance(c, dict):
        print("teto: NÃO PRONTO — nenhum item começa: %s" % c.get("why"))
    else:
        print("teto: o governo instalado no nó NÃO tem teto (rode install com o commit do teto)")
    if "running" in st and st["running"] is None:
        bad = 1
        print("  rodando: o governo NÃO conseguiu ler os processos")
else:
    bad = 1
    print("status do governo: FALHOU (rc=%s, ou resposta que não é o JSON esperado): a lista de itens e os erros do registro NÃO estão disponíveis — isto NÃO quer dizer sem itens" % sr)
sys.exit(3 if bad else 0)
'
}

cmd_pull() {
  local raw rc
  # vazio (results.jsonl existe e está vazio) → 0 novas; ausente (pasta legível, sem o arquivo) → rc 10, "ainda não tem"; falhou/ilegível (cat falhou, pasta ilegível, ssh que caiu) → recuso e o local fica como estava
  raw=$(rsh 'B="$HOME/gt-remote/ballast"; F="$B/results.jsonl"; if cat "$F" 2> /dev/null; then exit 0; fi; if [ -d "$B" ] && [ -x "$B" ] && [ ! -e "$F" ]; then exit 10; fi; exit 11'); rc=$?
  case "$rc" in
    0) ;;
    10) say "pull: o nó ainda não tem results.jsonl (nenhuma rodada terminou): 0 novas"; return 0 ;;
    255) die 98 "ssh não conectou ($NODE): results.jsonl local fica como estava" ;;
    *) die 3 "NÃO consegui LER results.jsonl no nó (rc=$rc): o local fica como estava; isto NÃO quer dizer que não haja resultados" ;;
  esac
  mkdir -p "$OUTDIR" || die 3 "não criei $OUTDIR"
  printf '%s\n' "$raw" | python3 -I -c '
import json, os, sys
out = sys.argv[1]
KEEP = ("ts", "item", "run", "role", "cores", "start", "secs", "rc", "why", "summary", "summary_why", "ceiling")
CEIL = ("tasks_peak", "tasks_hit", "mem_peak_mb", "oom_kill")   # os picos do teto: só estes quatro, inteiros ou null (não sei)
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
    row = {k: (clean(d[k]) if k == "summary" else scal(d[k])) for k in KEEP if k in d and k != "ceiling"}
    if isinstance(d.get("ceiling"), dict):
        row["ceiling"] = {k: (d["ceiling"][k] if isinstance(d["ceiling"].get(k), int) and not isinstance(d["ceiling"].get(k), bool) else None) for k in CEIL}
    elif "ceiling" in d:
        row["ceiling"] = None
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
  install)   { [ $# -eq 1 ] || { [ $# -eq 2 ] && [ "$2" = "--allow-dirty" ]; }; } || die 2 "$USO"; shift; cmd_install "$@" ;;
  uninstall) [ $# -eq 1 ] || die 2 "$USO"; cmd_uninstall ;;
  on)        [ $# -eq 1 ] || die 2 "$USO"; need_node_flag; cmd_flag on on ;;
  off)       [ $# -eq 1 ] || die 2 "$USO"; cmd_flag on off ;;
  burn)      [ $# -eq 2 ] && case "$2" in on|off) true ;; *) false ;; esac || die 2 "uso: hetzner-ballast.sh burn on|off"; cmd_flag burn.on "$2" ;;
  status)    [ $# -eq 1 ] || die 2 "$USO"; cmd_status ;;
  pull)      [ $# -eq 1 ] || die 2 "$USO"; cmd_pull ;;
  *)         die 2 "$USO" ;;
esac
