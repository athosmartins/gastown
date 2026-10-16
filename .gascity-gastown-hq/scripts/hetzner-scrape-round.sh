#!/usr/bin/env bash
# hetzner-scrape-round.sh — roda UMA rodada de um raspador de imóveis (property_scrapers) no nó Linux (Hetzner, IP alemão) e traz o resultado de volta ao mini, em STAGING.
#
# Contents
#   Por quê · Uso · Códigos de saída · O que vai, o que volta · Segurança · Limites
#
# POR QUÊ (ga-mqs133; Athos 15/10: o servidor Hetzner trabalha "full force o dia inteiro"): a rodada diária dos raspadores (launchd 00:01) soma ~8 h de relógio no mini, que vive com load 40-60.
#   MEDIDO de lá em 16/10 (docs/runbooks/hetzner-scrape-round.md): a maioria dos sites responde igual do IP alemão e do mini; uns poucos (Cloudflare) dão 403 só do nó. Este script roda o que responde
#   (scripts/hetzner-scrape-eligible.txt) e NUNCA o que bloqueia.
#
# USO
#   hetzner-scrape-round.sh check                         # o nó está pronto? (bandeira, ssh, ambiente, disco). Imprime chave=valor.
#   hetzner-scrape-round.sh eligible <raspador> [tenant]  # está na lista? rc 0 sim · 97 não / bloqueado de propósito (o motivo vai no stdout)
#   hetzner-scrape-round.sh bootstrap                     # prepara o ambiente do nó (venv + playwright + chromium + libs de sistema, SEM sudo). Idempotente.
#   hetzner-scrape-round.sh run <raspador> [--tenant T] [--limit N] [--timeout S] [--stage DIR] [-- args do raspador...]
#   hetzner-scrape-round.sh probe [--out ARQ]             # re-mede mini x nó nos endereços do runner.py e dos tenants (ga-mqs133 passo 1); use quando o servidor ou o IP mudar
#
# CÓDIGOS DE SAÍDA — 96..99 significam "rode local": quem chama NUNCA trata isso como falha do raspador (mesma convenção do mbp-run.sh).
#   0..95  código do raspador (propagado; rc >= 96 do raspador, inclusive 124 = estourou o --timeout, vira 95 e o valor cru vai na linha `scraper_rc_raw=`)
#   97  uso errado, nome inválido, raspador fora da lista ou BLOQUEADO, código do rig ausente, staging dentro de shared/ (jamais grava na produção)
#   98  nó indisponível ou sem condição: ssh não responde, ambiente não preparado (rode bootstrap), disco < HETZNER_SCRAPE_MIN_DISK_MB, conteúdo reprovado pela varredura, ssh caiu no meio
#   99  desligado: falta $CITY/.gc/hetzner-node.on (a mesma bandeira do nó de testes; apagar = desligar)
#
# O QUE VAI, O QUE VOLTA
#   VAI    só o código do raspador pedido: lib/*.py, config/__init__.py, scope.json e os *_tenants.json, scrapers/<raspador>/*.py — por CAMINHO, nunca por extensão solta — mais, de shared/config, o seen_<raspador>*.json
#          (ids de anúncios públicos) e os caches <raspador>_*cache*.json. Cada rodada tem a pasta própria no nó (~/gt-remote/scrape/runs/<id>), apagada ao fim.
#   VOLTA  shared/data/<raspador>/<timestamp>/ e os seen/caches atualizados, para $STAGE/<id>/shared/ + scraper.log. NADA é escrito em ~/.property-scrapers/shared (a produção): quem promove o
#          staging é a fatia seguinte (a integração no runner.py), com trava contra a rodada local do mesmo raspador.
# SEGURANÇA: o servidor é alugado e a fronteira de dados é a mesma do mbp-run.sh. Segredo, .env, token, banco, parquet, venv e shared/data da produção NÃO viajam (as regras de nome vêm antes de qualquer
#   `+`, e `- *` fecha). O CONTEÚDO do que vai (código E seen/caches) é varrido por hetzner-pii-scan.py (lista de telefones/CPFs = o nó NÃO é usado, rc 98). Nenhuma credencial vai no comando; o nó não tem a do GitHub nem a do mini.
# LIMITES: o raspador roda DESACOPLADO no nó (nohup; o ssh só consulta), então uma queda de rede de segundos não mata uma rodada de horas; passados HETZNER_SCRAPE_POLL_FAILS consultas seguidas sem resposta
#   o script desiste com rc 98 e deixa a pasta da rodada no nó (o reaper do próximo preflight apaga as de > 1 dia). Não roda raspador com credencial (blow, leilões com login) nem o que o IP alemão não alcança.
set -o pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
CITY=${HETZNER_SCRAPE_CITY:-${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}}
NODE_HOST=${HETZNER_NODE_HOST:-hetzner-teste}
NODE_FLAG=$CITY/.gc/hetzner-node.on
PS_HOME=${HETZNER_SCRAPE_PS_HOME:-$HOME/.property-scrapers}
PS_CODE=${HETZNER_SCRAPE_CODE:-$PS_HOME/runtime/main}          # o que o launchd diário roda de verdade (NÃO o crew/thies: divergiu do implantado)
PS_SHARED=${HETZNER_SCRAPE_SHARED:-$PS_HOME/shared}
STAGE_ROOT=${HETZNER_SCRAPE_STAGE:-$CITY/.gc/hetzner-scrape/stage}
ELIGIBLE=${HETZNER_SCRAPE_ELIGIBLE:-$HERE/hetzner-scrape-eligible.txt}
PII_SCAN=${HETZNER_PII_SCAN:-$HERE/hetzner-pii-scan.py}
LOG=${HETZNER_SCRAPE_LOG:-$CITY/.gc/logs/hetzner-scrape.jsonl}
SSH_BIN=${HETZNER_SSH_BIN:-ssh}; RSYNC_BIN=${HETZNER_RSYNC_BIN:-rsync}
PW_VERSION=${HETZNER_SCRAPE_PW_VERSION:-1.60.0}                 # a MESMA versão do playwright do mini (-> o mesmo chromium 1223)
RBASE=gt-remote/scrape                                          # relativo ao HOME do nó
num_or() { case ${1:-} in ''|*[!0-9]*) echo "$2";; *) echo "$1";; esac; }
MIN_DISK_MB=$(num_or "${HETZNER_SCRAPE_MIN_DISK_MB:-3072}" 3072)
POLL_S=$(num_or "${HETZNER_SCRAPE_POLL_S:-20}" 20)
POLL_FAILS=$(num_or "${HETZNER_SCRAPE_POLL_FAILS:-15}" 15)
DEF_TIMEOUT=$(num_or "${HETZNER_SCRAPE_TIMEOUT:-7200}" 7200)
GRACE_S=$(num_or "${HETZNER_SCRAPE_GRACE_S:-900}" 900)             # folga além do --timeout antes de dar a rodada por perdida (sem rc escrito)
mkdir -p "$HOME/.ssh/cm" 2>/dev/null; chmod 700 "$HOME/.ssh/cm" 2>/dev/null
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o ControlMaster=auto -o ControlPath=$HOME/.ssh/cm/%C -o ControlPersist=600"
NAME_RE='^[a-z][a-z0-9_]{0,40}$'; TENANT_RE='^[a-z0-9][a-z0-9_-]{0,40}$'

rmtmp() { local d; for d in "$@"; do [ -n "$d" ] && [ -d "$d" ] && { find "$d" -mindepth 1 -delete 2>/dev/null; rmdir "$d" 2>/dev/null; }; done; return 0; }   # pasta temporária NOSSA, por caminho exato
say() { echo "hetzner-scrape-round: $*" >&2; }
die() { local rc=$1; shift; say "$*"; exit "$rc"; }
iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
rssh() { "$SSH_BIN" $SSH_OPTS "$NODE_HOST" "$@"; }
# rscript <args...>: o script remoto vem no stdin; os argumentos chegam como $1.. (escapados com %q: nada do que vem de fora é interpretado pelo shell do nó)
rscript() { local q; q=$(printf '%q ' "$@"); "$SSH_BIN" $SSH_OPTS "$NODE_HOST" "bash -s -- $q"; }
jlog() { # jlog <raspador> <tenant> <rc> <secs> <arquivos> <porquê> <stage>
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  printf '{"ts":"%s","host":"hetzner","scraper":"%s","tenant":"%s","rc":%s,"secs":%s,"files":%s,"why":"%s","stage":"%s"}\n' "$(iso)" "$1" "$2" "$3" "$4" "$5" "$6" "$7" >> "$LOG" 2>/dev/null
}

# loose_realpath <caminho>: caminho absoluto com symlinks resolvidos mesmo que o final ainda não exista (sobe até o 1º ancestral que existe)
loose_realpath() {
  local p=$1 rest=""
  case $p in /*) ;; *) p=$PWD/$p;; esac
  while [ ! -d "$p" ]; do rest="/$(basename "$p")$rest"; p=$(dirname "$p"); done
  printf '%s%s\n' "$(cd "$p" && pwd -P)" "$rest"
}

# eligibility <raspador> [tenant]: imprime ALLOW | BLOCK <motivo> | NONE | UNREADABLE. rc 0 = pode rodar. A linha `!nome` (ou `!nome:tenant`) bloqueia e VENCE a permissão.
eligibility() {
  local sc=$1 tn=${2:-} v rc
  [ -r "$ELIGIBLE" ] || { echo UNREADABLE; return 3; }
  v=$(awk -v sc="$sc" -v tn="$tn" '
    { line=$0; gsub(/\r/,"",line); why=""; i=index(line,"#"); if (i) { why=substr(line,i+1); line=substr(line,1,i-1) }
      gsub(/^[ \t]+/,"",line); gsub(/[ \t]+$/,"",line); gsub(/^[ \t]+/,"",why); gsub(/[ \t]+$/,"",why)
      if (line=="") next
      neg=0; if (substr(line,1,1)=="!") { neg=1; line=substr(line,2) }
      n=split(line,p,":"); name=p[1]; ten=(n>1 ? p[2] : "")
      if (name!=sc) next
      if (ten!="" && ten!=tn) next
      if (neg) { blocked=1; bwhy=why } else allowed=1 }
    END { if (blocked) { print "BLOCK " bwhy; exit 1 } if (allowed) { print "ALLOW"; exit 0 } print "NONE"; exit 2 }' "$ELIGIBLE"); rc=$?
  echo "$v"; return $rc
}

# node_state: preflight do nó (1 ssh). Preenche NODE_ENV (ok|missing), NODE_FREE_MB, NODE_NCPU, NODE_LOAD. rc 99 bandeira · 98 ssh/estado ilegível
NODE_ENV=""; NODE_FREE_MB=""; NODE_NCPU=""; NODE_LOAD=""
node_state() {
  local out
  [ -e "$NODE_FLAG" ] || return 99
  out=$(rscript <<'REMOTE'
d=$HOME/gt-remote/scrape/env
if [ -x "$d/venv/bin/python" ] && [ -s "$d/libpath.txt" ] && ls -d "$d"/browsers/chromium_headless_shell-* >/dev/null 2>&1; then echo ENV=ok; else echo ENV=missing; fi
echo FREE_MB=$(df -Pm "$HOME" | awk 'NR==2{print $4}')
echo NCPU=$(nproc 2>/dev/null)
echo LOAD=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)
echo STATE_DONE
REMOTE
  ) || return 98
  case $out in *STATE_DONE*) ;; *) return 98;; esac
  NODE_ENV=$(printf '%s\n' "$out" | sed -n 's/^ENV=//p' | head -n 1); NODE_FREE_MB=$(printf '%s\n' "$out" | sed -n 's/^FREE_MB=//p' | head -n 1)
  NODE_NCPU=$(printf '%s\n' "$out" | sed -n 's/^NCPU=//p' | head -n 1); NODE_LOAD=$(printf '%s\n' "$out" | sed -n 's/^LOAD=//p' | head -n 1)
  [ -n "$NODE_ENV" ] && [ "$(num_or "$NODE_FREE_MB" x)" != x ] || return 98
  return 0
}
why_of() { case $1 in 99) echo "desligado (falta $NODE_FLAG)";; 98) echo "o nó $NODE_HOST não respondeu ao ssh (ou devolveu estado ilegível)";; *) echo "rc $1";; esac; }

cmd_check() {
  local rc=0 el=0
  node_state; rc=$?
  echo "flag=$([ -e "$NODE_FLAG" ] && echo on || echo off)"
  echo "node_host=$NODE_HOST"
  [ -r "$ELIGIBLE" ] && el=$(awk '{sub(/#.*/,"")} /^[ \t]*[^ \t!]/{n++} END{print n+0}' "$ELIGIBLE")
  echo "eligible_entries=$el"
  echo "code_dir=$([ -d "$PS_CODE/scrapers" ] && echo ok || echo ausente)"
  [ "$rc" -eq 0 ] && { echo "node_env=$NODE_ENV"; echo "node_free_mb=$NODE_FREE_MB"; echo "node_ncpu=$NODE_NCPU"; echo "node_load=$NODE_LOAD"; }
  [ "$rc" -eq 0 ] || { say "$(why_of "$rc")"; return "$rc"; }
  [ "$NODE_ENV" = ok ] || { say "ambiente do nó não preparado: rode \`$(basename "$0") bootstrap\`"; return 98; }
  [ "$NODE_FREE_MB" -ge "$MIN_DISK_MB" ] || { say "disco do nó baixo: ${NODE_FREE_MB} MB livres < $MIN_DISK_MB"; return 98; }
  return 0
}

cmd_bootstrap() {
  local rc=0
  [ -e "$NODE_FLAG" ] || die 99 "$(why_of 99)"
  say "preparando o ambiente do nó (venv, playwright==$PW_VERSION, chromium, libs de sistema sem sudo) — alguns minutos na 1ª vez"
  rscript "$PW_VERSION" <<'REMOTE' || rc=$?
set -e
pw=$1; d=$HOME/gt-remote/scrape/env; mkdir -p "$d/debs" "$d/root" "$d/browsers" "$HOME/gt-remote/scrape/runs"; cd "$d"
uv=$(command -v uv || echo "$HOME/.local/bin/uv"); [ -x "$uv" ] || { echo "BOOTSTRAP_FAIL sem uv no nó"; exit 3; }
[ -x venv/bin/python ] || "$uv" venv --python 3.12 venv >/dev/null
"$uv" pip install --python venv/bin/python -q "requests>=2.28" "beautifulsoup4>=4.11" "pytz>=2023.3" "playwright==$pw"
# o aviso "Host system is missing dependencies ... sudo playwright install-deps" é esperado (sem sudo): as libs vêm dos .deb extraídos abaixo; o que decide é o lançamento do chromium no fim
ls -d browsers/chromium_headless_shell-* >/dev/null 2>&1 || PLAYWRIGHT_BROWSERS_PATH=$d/browsers venv/bin/python -m playwright install chromium >pw-install.log 2>&1 || { tail -n 15 pw-install.log; echo "BOOTSTRAP_FAIL playwright install"; exit 3; }
# libs de sistema que o chromium pede, SEM root: .deb baixado (apt-get download) e extraído numa pasta nossa; o LD_LIBRARY_PATH aponta para lá
if [ ! -s libpath.txt ]; then
  ( cd debs && apt-get download libnspr4 libnss3 libatk1.0-0t64 libxcomposite1 libxdamage1 libxext6 libxfixes3 libxrandr2 libgbm1 libasound2t64 libatspi2.0-0t64 libxrender1 libxi6 >/dev/null 2>&1 ) || true
  for f in debs/*.deb; do [ -f "$f" ] && dpkg -x "$f" root; done
  find "$d/root" -name '*.so*' -printf '%h\n' | sort -u | paste -sd: - > libpath.txt
fi
sh_bin=$(find browsers -type f \( -name headless_shell -o -name chrome-headless-shell \) | head -n 1)   # o nome muda entre versões do playwright
[ -n "$sh_bin" ] || { echo "BOOTSTRAP_FAIL o chromium headless não foi instalado em $d/browsers"; exit 3; }
miss=$(LD_LIBRARY_PATH=$(cat libpath.txt) ldd "$sh_bin" 2>&1 | grep -E 'not found' || true)
[ -z "$miss" ] || { echo "BOOTSTRAP_FAIL libs faltando para $sh_bin:"; echo "$miss"; exit 3; }
LD_LIBRARY_PATH=$(cat libpath.txt) PLAYWRIGHT_BROWSERS_PATH=$d/browsers venv/bin/python - <<'PY'
from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    b = p.chromium.launch(headless=True); pg = b.new_page(); pg.set_content("<p>ok</p>"); assert pg.inner_text("p") == "ok"; b.close()
print("CHROMIUM_OK")
PY
echo BOOTSTRAP_OK
REMOTE
  [ "$rc" -eq 0 ] || die 98 "bootstrap falhou no nó (rc $rc)"
  say "ambiente do nó pronto"
}

# exclusões por NOME, primeiras em qualquer filtro que mande algo ao nó (código E estado): credencial/segredo/dados de cliente não viajam mesmo que uma regra `+` mais abaixo case com eles
name_exclusions() {
  printf '%s\n' '- .env' '- .env.*' '- *.pem' '- *.key' '- *.p12' '- *.pfx' '- *.pkl' '- *.pickle' '- *.db' '- *.sqlite*' '- *.duckdb*' '- *.parquet' '- *.csv' '- *.xlsx' '- *.gz' '- *.zip' \
      '- *token*' '- *secret*' '- *credential*' '- *password*' '- client_secret*' '- service_account*' '- .netrc' '- .npmrc' '- .pgpass' '- *cookie*' '- *session*' '- __pycache__/' '- *.pyc' '- .git/' '- venv/' '- .venv/' '- shared/' '- logs/'
}
# filtro do rsync do CÓDIGO: as exclusões por nome primeiro; depois só o que o raspador precisa, por caminho; `- *` fecha
write_code_filter() { # write_code_filter <arquivo> <raspador>
  local f=$1 sc=$2 t
  {
    name_exclusions
    printf '%s\n' '+ /lib/' '+ /lib/*.py' '- /lib/**' '+ /config/' '+ /config/__init__.py' '+ /config/scope.json'
    for t in "$PS_CODE"/config/*_tenants.json; do [ -f "$t" ] && printf '+ /config/%s\n' "$(basename "$t")"; done
    printf '%s\n' '- /config/**' '+ /scrapers/' "+ /scrapers/$sc/" "+ /scrapers/$sc/*.py" '- /scrapers/**' '- *'
  } > "$f"
}
# filtro do estado (seen/caches): só estes nomes, sob shared/config
# `<raspador>_*` não pode casar o estado de OUTRO raspador (ex.: loft e loft_x): para cada pasta de raspador cujo nome começa por `<raspador>_`, o estado dela é excluído antes das inclusões
write_state_filter() { # write_state_filter <arquivo> <raspador>
  local f=$1 sc=$2 d o
  {
    name_exclusions
    for d in "$PS_CODE"/scrapers/"$sc"_*/; do
      [ -d "$d" ] || continue
      o=$(basename "$d"); printf '%s\n' "- /seen_${o}.json" "- /seen_${o}_*.json" "- /${o}_*cache*.json"
    done
    printf '%s\n' "+ /seen_$sc.json" "+ /seen_${sc}_*.json" "+ /${sc}_*cache*.json" '- *'
  } > "$f"
}

cmd_probe() {
  local out="" tmp rc=0 urls nodef minif
  while [ $# -gt 0 ]; do case $1 in --out) out=${2:-}; shift 2;; *) die 97 "probe: argumento desconhecido: $1";; esac; done
  [ -d "$PS_CODE" ] || die 97 "código do rig ausente: $PS_CODE"
  [ -e "$NODE_FLAG" ] || die 99 "$(why_of 99)"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/hsr-probe.XXXXXX") || die 98 "sem diretório temporário"; urls=$tmp/urls; minif=$tmp/mini; nodef=$tmp/node
  # endereços: o host de conectividade de cada raspador no runner.py + o base_url de cada tenant ativo + os endpoints de API que os raspadores chamam
  { grep -o -E '"connectivity_host": *"[^"]+"' "$PS_CODE/runner.py" 2>/dev/null | sed -E 's/.*"([^"]+)"$/https:\/\/\1\//'
    python3 -I - "$PS_CODE/config" <<'PY'
import glob, json, sys
for f in sorted(glob.glob(sys.argv[1] + "/*_tenants.json")):
    try:
        for t in json.load(open(f)):
            if t.get("active", True) and t.get("base_url"):
                print(t["base_url"].rstrip("/") + "/")
    except Exception:
        pass
PY
    printf '%s\n' 'https://apigw.prod.quintoandar.com.br/house-listing-search/v2/search/coordinates' 'https://landscape-api.loft.com.br/listing/v3/search' 'https://glue-api.zapimoveis.com.br/v2/listings' \
      'https://www.netimoveis.com/pesquisa' 'https://www.chavesnamao.com.br/imoveis-a-venda/mg-belo-horizonte/'
  } | sort -u > "$urls"
  [ -s "$urls" ] || { rmtmp "$tmp"; die 97 "nenhum endereço para medir (runner.py/tenants ilegíveis em $PS_CODE)"; }
  say "medindo $(wc -l < "$urls" | tr -d ' ') endereços do mini e do nó (curl com UA de navegador, sem cookie)"
  probe_loop < "$urls" > "$minif" &
  local mpid=$!
  { declare -f probe_loop; echo 'probe_loop <<"HSR_URLS_EOF"'; cat "$urls"; echo HSR_URLS_EOF; } | rssh bash -s > "$nodef" 2>/dev/null || rc=$?
  wait "$mpid"
  if [ "$rc" -ne 0 ] || [ ! -s "$nodef" ]; then rmtmp "$tmp"; die 98 "o nó não respondeu à medição (rc $rc)"; fi
  # bloqueio = o nó NÃO recebe 2xx onde o mini recebe, ou recebe uma página de desafio de verdade (just a moment, attention required...) que o mini não recebe. A palavra solta `captcha` num 200
  # (widget de formulário) não é bloqueio: só conta se a marca for a mesma nos dois lados (IGUAL-OK) ou, se diferir, vira DIFERE-VERIFICAR para um humano olhar
  awk -v OFS='\t' 'NR==FNR { mc[$4]=$1; mk[$4]=tolower($3); next }
    { u=$4; c1=mc[u]; m1=mk[u]; c2=$1; m2=tolower($3); ok1=(c1 ~ /^2/); ok2=(c2 ~ /^2/)
      hard2=(m2 ~ /^(just_a_moment|attention_required|access_denied|px-captcha|pardon_our_interruption|request_blocked)$/)
      if (ok1 && ok2) cls = (m1==m2) ? "IGUAL-OK" : (hard2 ? "SO-O-NO-BLOQUEIA" : "DIFERE-VERIFICAR")
      else if (ok1) cls = "SO-O-NO-BLOQUEIA"
      else if (ok2) cls = "SO-O-MINI-FALHA"
      else cls = (c1==c2) ? "IGUAL-FALHA" : "DIFERE-FALHA"
      print cls, "mini=" c1 "/" m1, "nó=" c2 "/" m2, u }' "$minif" "$nodef" | sort > "$tmp/table"
  cat "$tmp/table"
  echo "--- $(awk -F'\t' '{c[$1]++} END{for (k in c) printf "%s=%d ", k, c[k]; print ""}' "$tmp/table")"
  [ -z "$out" ] || cp "$tmp/table" "$out"
  jlog probe "" 0 0 "$(wc -l < "$tmp/table" | tr -d ' ')" "$(awk -F'\t' '$1=="SO-O-NO-BLOQUEIA"{n++} END{print n+0}' "$tmp/table")-bloqueados" ""
  rmtmp "$tmp"
}
# probe_loop: lê endereços no stdin; imprime "<http> <bytes> <marca> <url>" (marca = banner de bloqueio no corpo, ou `-`). Roda igual no mini e no nó (é copiada por declare -f).
probe_loop() {
  local UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36' u o meta mk
  while read -r u; do
    [ -n "$u" ] || continue
    o=$(mktemp)
    meta=$(curl -s -L -m 25 -A "$UA" -H 'Accept-Language: pt-BR,pt;q=0.9' -o "$o" -w '%{http_code} %{size_download}' "$u" 2>/dev/null)
    [ -n "$meta" ] || meta="000 0"   # curl ausente ou sem saída = falha de conexão (visível na tabela), nunca uma linha com os campos deslocados
    mk=$(grep -a -o -i -E 'just a moment|captcha|access denied|attention required|px-captcha|pardon our interruption|request blocked' "$o" | head -n 1 | tr ' ' '_')
    echo "$meta ${mk:--} $u"
    rm -f "$o"
  done
}

cmd_run() {
  local sc="" tn="" limit="" to=$DEF_TIMEOUT stage_base=$STAGE_ROOT extra=() v rc=0 id t0 stage rdir remote_rel pii_list held n state_f code_f dry_d
  sc=${1:-}; [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do
    case $1 in
      --tenant) tn=${2:-}; shift 2;; --limit) limit=${2:-}; shift 2;; --timeout) to=${2:-}; shift 2;; --stage) stage_base=${2:-}; shift 2;;
      --) shift; extra=("$@"); break;;
      *) die 97 "run: argumento desconhecido: $1 (argumentos do raspador vão depois de --)";;
    esac
  done
  [[ "$sc" =~ $NAME_RE ]] || die 97 "run: nome de raspador inválido: '${sc}'"
  [ -z "$tn" ] || [[ "$tn" =~ $TENANT_RE ]] || die 97 "run: tenant inválido: '$tn'"
  [ -z "$limit" ] || [ "$(num_or "$limit" x)" != x ] || die 97 "run: --limit não é número: '$limit'"
  [ "$(num_or "$to" x)" != x ] && [ "$to" -ge 1 ] || die 97 "run: --timeout inválido: '$to'"
  v=$(eligibility "$sc" "$tn"); rc=$?
  case $rc in 0) ;; 1) die 97 "'$sc' está BLOQUEADO para o nó: ${v#BLOCK } — rode local";; 2) die 97 "'$sc' não está em $(basename "$ELIGIBLE") (só roda no nó o que foi medido): rode local";; *) die 97 "lista de elegíveis ilegível ($ELIGIBLE): rode local";; esac
  [ -d "$PS_CODE/scrapers/$sc" ] || die 97 "código do raspador ausente: $PS_CODE/scrapers/$sc"
  # o staging é resolvido (symlinks inclusive) ANTES de ser criado: recusar depois de um mkdir -p já teria escrito dentro da produção
  case $stage_base in ..|*/..|*/../*) die 97 "o staging ($stage_base) não pode ter '..' no caminho";; esac
  stage_base=$(loose_realpath "$stage_base"); local ps_real; ps_real=$(loose_realpath "$PS_SHARED")
  case "$stage_base/" in "$ps_real"/*) die 97 "o staging ($stage_base) não pode ficar dentro de $PS_SHARED (a produção): esta fatia nunca grava lá";; esac
  mkdir -p "$stage_base" 2>/dev/null || die 97 "não criei o staging $stage_base"
  node_state; rc=$?
  [ "$rc" -eq 0 ] || { say "$(why_of "$rc") — rode local"; exit "$rc"; }
  [ "$NODE_ENV" = ok ] || die 98 "ambiente do nó não preparado — rode \`$(basename "$0") bootstrap\` (ou rode local)"
  [ "$NODE_FREE_MB" -ge "$MIN_DISK_MB" ] || die 98 "disco do nó baixo: ${NODE_FREE_MB} MB livres < $MIN_DISK_MB — rode local"

  id="$sc${tn:+-$tn}-$(date -u +%Y%m%dT%H%M%SZ)-$$"; stage="$stage_base/$id"; remote_rel="$RBASE/runs/$id"
  mkdir -p "$stage/shared" || die 97 "não criei $stage"
  code_f=$(mktemp "${TMPDIR:-/tmp}/hsr-code.XXXXXX"); state_f=$(mktemp "${TMPDIR:-/tmp}/hsr-state.XXXXXX"); pii_list=$(mktemp "${TMPDIR:-/tmp}/hsr-list.XXXXXX")
  dry_d=$(mktemp -d "${TMPDIR:-/tmp}/hsr-dry.XXXXXX")
  trap 'rm -f "$code_f" "$state_f" "$pii_list" "$pii_list.out" "$pii_list.state"; rmtmp "$dry_d"' EXIT
  write_code_filter "$code_f" "$sc"; write_state_filter "$state_f" "$sc"

  # varredura de CONTEÚDO do que o filtro deixaria sair (falha fechada: erro da varredura ≠ "nada retido")
  "$RSYNC_BIN" -a -n --out-format='%n' --filter=". $code_f" "$PS_CODE"/ "$dry_d"/ 2>/dev/null | grep -v '/$' > "$pii_list"
  [ "${PIPESTATUS[0]}" -eq 0 ] && [ -s "$pii_list" ] || die 98 "não consegui listar o que iria ao nó (rsync -n falhou) — o nó NÃO é usado"
  python3 -I "$PII_SCAN" "$PS_CODE" < "$pii_list" > "$pii_list.out" 2>/dev/null || die 98 "a varredura de conteúdo (hetzner-pii-scan.py) não terminou — o nó NÃO é usado"
  if [ -s "$pii_list.out" ]; then held=$(cut -f3 "$pii_list.out" | head -n 3 | tr '\n' ' '); die 98 "arquivo com lista de telefones/CPFs entre os que iriam ao nó ($held…) — o nó NÃO é usado"; fi
  # o mesmo para o estado (seen/caches): mesma lista pelo filtro, mesma varredura, mesma falha fechada
  "$RSYNC_BIN" -a -n --out-format='%n' --filter=". $state_f" "$PS_SHARED"/config/ "$dry_d"/ 2>/dev/null | grep -v '/$' > "$pii_list.state"
  [ "${PIPESTATUS[0]}" -eq 0 ] || die 98 "não consegui listar o estado (seen/caches) que iria ao nó (rsync -n falhou) — o nó NÃO é usado"
  if [ -s "$pii_list.state" ]; then
    python3 -I "$PII_SCAN" "$PS_SHARED/config" < "$pii_list.state" > "$pii_list.out" 2>/dev/null || die 98 "a varredura de conteúdo do estado (hetzner-pii-scan.py) não terminou — o nó NÃO é usado"
    if [ -s "$pii_list.out" ]; then held=$(cut -f3 "$pii_list.out" | head -n 3 | tr '\n' ' '); die 98 "arquivo de estado com lista de telefones/CPFs entre os que iriam ao nó ($held…) — o nó NÃO é usado"; fi
  fi

  t0=$(date +%s)
  rssh "mkdir -p $remote_rel/rig/main $remote_rel/shared/config $remote_rel/shared/data" || die 98 "ssh caiu ao preparar a pasta da rodada"
  "$RSYNC_BIN" -a --delete --delete-excluded --filter=". $code_f" -e "$SSH_BIN $SSH_OPTS" "$PS_CODE"/ "$NODE_HOST:$remote_rel/rig/main/" >/dev/null 2>&1 || die 98 "rsync do código ao nó falhou"
  if [ -s "$pii_list.state" ]; then
    say "estado (seen/caches) enviado ao nó: $(wc -l < "$pii_list.state" | tr -d ' ') arquivo(s)"
    "$RSYNC_BIN" -a --filter=". $state_f" -e "$SSH_BIN $SSH_OPTS" "$PS_SHARED"/config/ "$NODE_HOST:$remote_rel/shared/config/" >/dev/null 2>&1 || die 98 "rsync do estado (seen/caches) ao nó falhou"
  else
    say "AVISO: nenhum arquivo de estado (seen/caches) de '$sc' em $PS_SHARED/config — o raspador começa SEM seen (tudo conta como novo)"
  fi

  # o raspador roda DESACOPLADO (setsid nohup): queda do ssh não o mata. Escreve rc em <rodada>/rc e o texto em <rodada>/scraper.log
  local sargs=(); [ -z "$tn" ] || sargs+=(--tenant "$tn"); [ -z "$limit" ] || sargs+=(--limit "$limit"); [ ${#extra[@]} -eq 0 ] || sargs+=("${extra[@]}")
  rscript "$remote_rel" "$sc" "$to" "${sargs[@]+"${sargs[@]}"}" <<'REMOTE' || die 98 "ssh caiu ao disparar o raspador no nó"
run=$HOME/$1; sc=$2; to=$3; shift 3; d=$HOME/gt-remote/scrape/env
cat > "$run/go.sh" <<'GO'
cd "$(dirname "$0")" || exit 97
d=$HOME/gt-remote/scrape/env
export LD_LIBRARY_PATH=$(cat "$d/libpath.txt") PLAYWRIGHT_BROWSERS_PATH=$d/browsers PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
sc=$1; to=$2; shift 2
nice -n 5 timeout "$to" "$d/venv/bin/python" -u "rig/main/scrapers/$sc/scraper.py" "$@" > scraper.log 2>&1
echo $? > rc.tmp && mv rc.tmp rc
GO
( setsid nohup bash "$run/go.sh" "$sc" "$to" "$@" >/dev/null 2>&1 < /dev/null & )
REMOTE
  say "rodada $id disparada no nó (timeout ${to}s); consulta a cada ${POLL_S}s"
  local fails=0 raw="" r deadline=$(( $(date +%s) + to + GRACE_S ))
  while :; do
    [ "$(date +%s)" -le "$deadline" ] || { say "a rodada $id passou do prazo (--timeout ${to}s + ${GRACE_S}s) sem escrever o rc: o processo sumiu no nó? desisto (a pasta fica em $NODE_HOST:$remote_rel; o reaper a apaga em 1 dia)"; jlog "$sc" "$tn" 98 $(( $(date +%s) - t0 )) 0 "sem-rc-no-prazo" "$stage"; exit 98; }
    r=$(rssh "cat $remote_rel/rc 2>/dev/null; echo END" 2>/dev/null)
    case $r in
      *END) fails=0; raw=$(printf '%s' "$r" | head -n 1); case $raw in END) raw="";; esac; [ -z "$raw" ] || break;;
      *) fails=$((fails + 1)); if [ "$fails" -ge "$POLL_FAILS" ]; then say "o nó não respondeu a $fails consultas seguidas: desisto (a rodada $id fica em $NODE_HOST:$remote_rel; o reaper a apaga em 1 dia)"; jlog "$sc" "$tn" 98 $(( $(date +%s) - t0 )) 0 "ssh-caiu" "$stage"; exit 98; fi;;
    esac
    sleep "$POLL_S"
  done
  case $raw in ''|*[!0-9]*) raw=97;; esac

  "$RSYNC_BIN" -a --max-size=500m -e "$SSH_BIN $SSH_OPTS" --include='/shared/' --include='/shared/data/***' --include='/shared/config/' --include='/shared/config/seen_*' --include='/shared/config/*cache*' --include='/scraper.log' --exclude='*' "$NODE_HOST:$remote_rel/" "$stage/" >/dev/null 2>&1 || { say "AVISO: o resultado não voltou inteiro (rsync de volta falhou); a rodada fica em $NODE_HOST:$remote_rel"; jlog "$sc" "$tn" 98 $(( $(date +%s) - t0 )) 0 "volta-falhou" "$stage"; exit 98; }
  n=$(find "$stage/shared/data" -type f 2>/dev/null | wc -l | tr -d ' ')
  # limpeza: só a pasta DESTA rodada (id montado por nós a partir de nome validado), nunca um caminho vindo de fora
  rssh "case $remote_rel in $RBASE/runs/?*) find $remote_rel -mindepth 1 -delete; rmdir $remote_rel;; esac" >/dev/null 2>&1 || say "AVISO: a pasta da rodada no nó não foi apagada ($remote_rel)"
  # reaper: pastas de rodadas de mais de 1 dia (queda de rede que deixou a pasta para trás)
  rssh "find $RBASE/runs -mindepth 1 -maxdepth 1 -type d -mtime +1 -exec sh -c 'find \"\$1\" -mindepth 1 -delete; rmdir \"\$1\"' _ {} \;" >/dev/null 2>&1
  echo "stage=$stage"; echo "files=$n"; echo "secs=$(( $(date +%s) - t0 ))"
  if [ "$raw" -ge 96 ]; then echo "scraper_rc_raw=$raw"; jlog "$sc" "$tn" 95 $(( $(date +%s) - t0 )) "$n" "rc-cru-$raw" "$stage"; exit 95; fi
  jlog "$sc" "$tn" "$raw" $(( $(date +%s) - t0 )) "$n" "$([ "$n" -ge 1 ] && echo ok || echo ok-sem-arquivos)" "$stage"
  exit "$raw"
}

cmd=${1:-}; [ $# -gt 0 ] && shift
case $cmd in
  check) cmd_check;;
  eligible) [ -n "${1:-}" ] || die 97 "eligible: faltou o raspador"; [[ "$1" =~ $NAME_RE ]] || die 97 "nome inválido: $1"; v=$(eligibility "$1" "${2:-}"); rc=$?; echo "$v"; [ "$rc" -eq 0 ] || exit 97;;
  bootstrap) cmd_bootstrap;;
  run) cmd_run "$@";;
  probe) cmd_probe "$@";;
  *) sed -n '2,24p' "$0" >&2; exit 97;;
esac
