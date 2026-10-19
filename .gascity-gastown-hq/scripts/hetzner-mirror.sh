#!/bin/bash
# hetzner-mirror.sh — o espelho git do servidor Hetzner (ga-2hd02v.1.3, fatia 4). Roda no MINI. Doc: docs/runbooks/hetzner-git-mirror.md
#
# ## Contents
#   Subcomandos · Códigos de saída
#
# O servidor NÃO tem credencial do GitHub: fala só com um espelho bare por rig daqui ($MH/repos/<rig>.git), por ssh (sshd próprio só-chave em loopback; a chave só roda `serve`). O filtro de dados (sparse:oid) =
#   Seção 1 de hetzner-rsync-filter.wa.txt + .beads/ data/ logs/ + os CAMINHOS que a varredura de CONTEÚDO sinalizou; o upload-pack só serve com o filtro vigente E a varredura cobrindo as pontas. Push do servidor:
#   só crew/ worker/ + prefixos do rig, nunca main/tag/apagar/reescrever/dado; `publish` empurra ao origin sem force. Leitura que falha ⇒ recusa (estado inerte), nunca "limpo". Limites e resíduos: ver o runbook.
#   O origin pode mudar uma branch por baixo (o gate reescreve): o hook pergunta a ponta VIVA ao origin (ls-remote) e recusa/avisa o push que o publish não entregaria; o sync alinha a ponta já entregue à do origin (ga-jgxgn6).
#
# SUBCOMANDOS: init <rig> <origin-url> [--seed GITDIR] [--prefix P/]... | sync [rig] | publish [rig] | status [rig] | sparse [rig] | authorize <pubkey> | hostkey | sshd start|stop|status|run | tunnel start|stop|status|run <host-ssh>
#   (uso interno: serve · hook pre-receive|post-receive · pack-hook · spec-out <rig>)
# CÓDIGOS: 0 ok · 1 pendente/falha visível · 2 uso · 3 recusado por não poder conferir (fail-closed) · 75 espelho em atualização (tente de novo) · 126 serve recusou
set -u
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")
CITY=${GC_CITY_PATH:-$(cd "$(dirname "$SELF")/.." && pwd -P)}
MH=${HETZNER_MIRROR_HOME:-$CITY/.gc/hetzner-mirror}
FILTER=${HETZNER_MIRROR_FILTER:-$(dirname "$SELF")/hetzner-rsync-filter.wa.txt}
SCAN=${HETZNER_MIRROR_SCAN:-$(dirname "$SELF")/hetzner-mirror-scan.py}
PORT=${HETZNER_MIRROR_PORT:-2293}
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export GIT_AUTHOR_NAME=gt-mirror GIT_AUTHOR_EMAIL=gt-mirror@localhost GIT_COMMITTER_NAME=gt-mirror GIT_COMMITTER_EMAIL=gt-mirror@localhost
GIT=$(command -v git) || { echo "hetzner-mirror: git não encontrado" >&2; exit 3; }
RIG_RE='^[a-z][a-z0-9_-]{0,40}$'
DATA_DIRS=".beads/ data/ logs/"   # pastas que o filtro do rsync nega na Seção 3 por serem dado por natureza (inclui o backup de bead: regra do Athos)

die() { local rc=$1; shift; echo "hetzner-mirror: $*" >&2; exit "$rc"; }
iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
repo_of() { printf '%s/repos/%s.git' "$MH" "$1"; }
state_of() { printf '%s/state/%s' "$MH" "$1"; }
rigs_of() {   # sem argumento: todos os espelhos; com argumento: ele, ou erro (chame como `x=$(rigs_of ..) || exit`: die dentro de $(...) só sai do subshell)
  local r; if [ -n "${1:-}" ]; then [[ "$1" =~ $RIG_RE ]] && [ -d "$(repo_of "$1")" ] || die 2 "espelho desconhecido: $1"; echo "$1"
  else for r in "$MH"/repos/*.git; do [ -d "$r" ] && basename "$r" .git; done; fi; }
lock_age() { local m; m=$(stat -f %m "$1" 2>/dev/null); case $m in ''|*[!0-9]*) m=$(stat -c %Y "$1" 2>/dev/null);; esac; case $m in ''|*[!0-9]*) return 1;; esac; echo $(( $(date +%s) - m )); }   # segundos desde o mkdir/pid (macOS: -f %m; GNU: -c %Y)
lock_alive() { local c; kill -0 "$1" 2>/dev/null || return 1; c=$(ps -o command= -p "$1" 2>/dev/null); [ -z "$c" ] || grep -qF -- "${SELF##*/}" <<< "$c"; }   # pid vivo E é este script (pid reaproveitado por outro programa não segura a trava); ps mudo = não sei = vivo
# lock_take <dir> <espera-s>: 0 peguei · 1 dono vivo dentro do prazo (concorrente normal) · 2 dono vivo há mais de HETZNER_MIRROR_LOCK_MAX s (parado?) · 3 erro MEU (disco, permissão, pid que não grava)
lock_take() { local d=$1 n=$2 p a; while ! mkdir "$d" 2>/dev/null; do [ -d "$d" ] || return 3; p=$(cat "$d/pid" 2>/dev/null); a=$(lock_age "$d") || return 3
  if { [ -z "$p" ] && [ "$a" -gt 30 ]; } || { [ -n "$p" ] && ! lock_alive "$p"; }; then rm -rf "$d" 2>/dev/null; [ ! -e "$d" ] || return 3; continue; fi   # sem pid há >30 s = o dono morreu entre o mkdir e a gravação
  [ -n "$p" ] && [ "$a" -gt "${HETZNER_MIRROR_LOCK_MAX:-3600}" ] && return 2; [ "$n" -le 0 ] && return 1; n=$((n-1)); sleep 1; done
  echo $$ > "$d/pid" 2>/dev/null || { rmdir "$d" 2>/dev/null; return 3; }; }
lock_why() { case $1 in 1) echo "outro $2 em curso";; 2) echo "a trava de $2 está parada: o dono (pid $(cat "$3/pid" 2>/dev/null)) vive há mais de ${HETZNER_MIRROR_LOCK_MAX:-3600}s; mate-o ou apague $3";; *) echo "não consegui pegar a trava de $2 ($3): erro de disco/permissão aqui, não de outro $2";; esac; }
proc_is() { local c; kill -0 "$1" 2>/dev/null && c=$(ps -o command= -p "$1" 2>/dev/null) && grep -qF -- "$2" <<< "$c"; }   # pid vivo E é o NOSSO processo (pid reaproveitado depois de reboot não vale como "rodando"); ps mudo = não sei = "parado", o lado visível
tmo() { if command -v timeout >/dev/null; then timeout "$@"; else shift; "$@"; fi; }   # fetch/push sem limite penduram o lock; sem `timeout` na máquina, roda sem
bg_run() { local log=$1; shift; ( trap '' HUP; exec "$@" ) >> "$log" 2>&1 < /dev/null & }   # sem nohup: o do macOS falha sem tty ("can't detach from console"), que é o caso do hook sob o sshd

# ── o filtro de dados: Seção 1 de hetzner-rsync-filter.wa.txt + pastas de dado + caminhos da varredura de conteúdo → lista sparse (/* e depois !regra). rc 3 = não dá para confiar nela ───────
sparse_spec() {   # sparse_spec [rig]
  local rig=${1:-} out c d x
  [ -r "$FILTER" ] || { echo "hetzner-mirror: filtro de dados ilegível ($FILTER): não gero o filtro do espelho" >&2; return 3; }
  out=$(awk '/^# SE.+O 1/{s=1;a=1;next} /^# SE.+O 2/{if(s)e=1;s=0;next}
    s&&/^[+-] /{ if(/^\+/||/^- [!#]/||/[[:space:]]$/||/^[+-] .*\/./)b=1; else{print "!" substr($0,3);n++}; next }   # barra só no fim (pasta): o rsync casa regra com barra no meio pelo caminho todo, o git pela raiz
    s&&!/^#/&&!/^[[:space:]]*$/{b=1}
    END{ if(!a||!e||b||n<20)exit 3 }' "$FILTER") || { echo "hetzner-mirror: Seção 1 do filtro ausente, truncada ou com regra que não sei traduzir: recuso" >&2; return 3; }
  for c in '*.csv' '*.db' '*.parquet' '.env' '*.duckdb*'; do   # a Seção 1 sem estes é um filtro cortado/adulterado, não um filtro menor
    grep -qxF -- "!$c" <<< "$out" || { echo "hetzner-mirror: o filtro perdeu a regra $c: recuso" >&2; return 3; }; done
  x=""; if [ -n "$rig" ] && [ -e "$(state_of "$rig")/deny-extra" ]; then x=$(cat "$(state_of "$rig")/deny-extra") || { echo "hetzner-mirror: deny-extra de $rig ilegível: recuso" >&2; return 3; }; fi
  echo '/*'; printf '%s\n' "$out"; for d in $DATA_DIRS; do echo "!$d"; done; [ -z "$x" ] || printf '%s\n' "$x"
}
# stdin: caminhos separados por NUL → stdout: os que as regras de dado negam (NUL). rc 3 = não consegui conferir (NÃO ler como "nenhum")
deny_match() {   # deny_match [rig]
  local t rc=3; t=$(mktemp -d "${TMPDIR:-/tmp}/hm.XXXXXX") || return 3
  # num hook o git exporta GIT_DIR=. (e quarentena de objetos): sem limpar, o `git init`/`check-ignore` abaixo agiriam no ESPELHO, não no diretório temporário
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_PREFIX
  if sparse_spec "${1:-}" > "$t/spec" && sed -e '1d' -e 's/^!//' "$t/spec" > "$t/deny" && [ -s "$t/deny" ] && "$GIT" init -q "$t/r" 2>/dev/null; then
    "$GIT" -C "$t/r" -c core.excludesFile="$t/deny" check-ignore --no-index -z --stdin; case $? in 0|1) rc=0 ;; esac
  fi
  rm -rf "$t"; return $rc
}
tips_hash() { "$GIT" -C "$1" for-each-ref --format='%(objectname) %(refname)' refs/remotes/origin | "$GIT" hash-object --stdin; }   # as pontas que vieram do origin (só o fetch as move)
mirror_ready() {   # 0 só se o filtro existe E a varredura de conteúdo cobre exatamente as pontas de agora; qualquer dúvida = não
  local r=$1 o s t; o=$("$GIT" -C "$r" config --get gtmirror.sparseoid) && s=$("$GIT" -C "$r" config --get gtmirror.scannedtips) && t=$(tips_hash "$r") && [ -n "$o" ] && [ -n "$s" ] && [ "$s" = "$t" ]
}

# ── init: cria/atualiza o espelho bare de um rig ────────────────────────────────────────────────────────────────────────────────────────────────────────────────
cmd_init() {
  [ $# -ge 2 ] || die 2 "uso: init <rig> <origin-url> [--seed GITDIR] [--prefix P/]..."
  local rig=$1 url=$2 seed="" pfx="crew/ worker/" r p; shift 2
  while [ $# -gt 0 ]; do case "$1" in --seed) seed=${2:-}; shift 2;; --prefix) [[ "${2:-}" =~ ^[a-z][a-z0-9_-]*/$ ]] || die 2 "prefixo inválido: ${2:-}"; pfx="$pfx $2"; shift 2;; *) die 2 "init: argumento desconhecido: $1";; esac; done
  [[ "$rig" =~ $RIG_RE ]] || die 2 "nome de rig inválido: $rig"
  case "$SELF" in */.gc-worktrees/*) [ "${HETZNER_MIRROR_ALLOW_WORKTREE:-}" = 1 ] || die 3 "rode do caminho mergeado (\$GC_CITY_PATH/scripts): este script vira o hook e o comando da chave, e worktree some";; esac
  sparse_spec > /dev/null || exit 3; [ -r "$SCAN" ] || die 3 "varredura de conteúdo ausente ($SCAN)"
  r=$(repo_of "$rig"); mkdir -p "$MH/repos" "$(state_of "$rig")" && chmod 700 "$MH" || die 3 "não consegui criar $MH"
  if [ ! -d "$r" ]; then
    if [ -n "$seed" ]; then "$GIT" clone -q --bare --local "$seed" "$r.new.$$" 2>/dev/null || die 3 "seed ilegível: $seed"   # hardlink: não copia 400 MB
      "$GIT" -C "$r.new.$$" for-each-ref --format='delete %(refname)' | "$GIT" -C "$r.new.$$" update-ref --stdin || die 3 "não limpei as refs do seed"   # só os OBJETOS do seed ficam
    else "$GIT" init -q --bare "$r.new.$$" || die 3 "git init falhou"; fi
    mv "$r.new.$$" "$r" || die 3 "não consegui publicar $r"
  fi
  c() { "$GIT" -C "$r" config "$@"; }
  c remote.origin.url "$url"; c --replace-all remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'; c remote.origin.tagopt --no-tags
  c receive.denyDeletes true; c receive.denyNonFastForwards true; c receive.fsckObjects true
  c --unset-all gtmirror.prefix 2>/dev/null; for p in $pfx; do c --add gtmirror.prefix "$p"; done
  "$GIT" -C "$r" symbolic-ref HEAD refs/remotes/origin/main
  for p in pre-receive post-receive; do printf '#!/bin/sh\nHETZNER_MIRROR_HOME=%q exec %q hook %s "$@"\n' "$MH" "$SELF" "$p" > "$r/hooks/$p"; chmod 755 "$r/hooks/$p"; done
  echo "init $rig: ok ($r) prefixos=[$pfx]; o servidor só é atendido depois do 1º \`sync $rig\` (varre o histórico inteiro: demora)"
}

# ── publish / sync / status ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# o pendente se deriva das refs (nenhum estado guardado que possa mentir): a branch está publicada se o origin a tem no mesmo sha (refs/remotes/origin/<b>, trazido pelo fetch)
# ou se NÓS a empurramos nesse sha (refs/gt/published/<b>: não toca refs/remotes/origin, que a varredura de conteúdo precisa estável; por isso o push vai pela URL, não pelo
# remoto nomeado, cujo push o git acompanharia atualizando refs/remotes/origin/<b> sozinho).
branch_pending() { local r=$1 b=$2 s o p; s=$("$GIT" -C "$r" rev-parse -q --verify "refs/heads/$b") || return 0
  o=$("$GIT" -C "$r" rev-parse -q --verify "refs/remotes/origin/$b" 2>/dev/null || true); p=$("$GIT" -C "$r" rev-parse -q --verify "refs/gt/published/$b" 2>/dev/null || true)
  [ "$s" != "$o" ] && [ "$s" != "$p" ]; }
# origin_vs <repo> <branch> <sha>: o `publish` (sem force) entregaria <sha> em <branch>? Pergunta ao origin AGORA (ls-remote), não à última cópia do fetch: foi a cópia velha que escondeu a reescrita do gate (ga-jgxgn6).
#   0 sim (o origin não tem a branch, ou a ponta dele é ancestral de <sha>) · 1 NÃO: imprime a ponta do origin (que <sha> não contém) · 2 não consegui conferir (origin mudo, prazo, resposta ilegível): nada impresso
# vazio → o ls-remote deu certo e não trouxe a linha da branch = o origin não a tem (0); falhou/prazo/linha que não é sha/merge-base com erro → 2, nunca 0 nem 1: dúvida é "não sei" e quem chama decide
origin_vs() { local r=$1 b=$2 s=$3 url out t
  url=$("$GIT" -C "$r" config --get remote.origin.url) || return 2
  out=$(GIT_TERMINAL_PROMPT=0 tmo "${HETZNER_MIRROR_LSREMOTE_WAIT:-15}" "$GIT" -C "$r" ls-remote "$url" "refs/heads/$b" 2>/dev/null) || return 2
  t=$(awk -v ref="refs/heads/$b" '$2 == ref { print $1 }' <<< "$out"); [ -n "$t" ] || return 0
  [[ "$t" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || return 2
  "$GIT" -C "$r" cat-file -e "$t^{commit}" 2>/dev/null || { echo "$t"; return 1; }   # a história inteira de <sha> está aqui (o receive-pack confere a conectividade antes de qualquer hook): ponta que o espelho não tem NÃO é ancestral dele
  "$GIT" -C "$r" merge-base --is-ancestor "$t" "$s" 2>/dev/null; case $? in 0) return 0;; 1) echo "$t"; return 1;; *) return 2;; esac; }
# sync em segundo plano a partir de um hook. Limpa o ambiente de hook (GIT_DIR=. e, no pre-receive, a QUARENTENA de objetos): sem isso o fetch gravaria no diretório de quarentena, que o git apaga ao fim do push
kick_sync() { bg_run "$MH/publish.log" env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_QUARANTINE_PATH -u GIT_PREFIX HETZNER_MIRROR_HOME="$MH" "$SELF" sync "$1"; }
# as branches aceitas (prefixo) que o espelho já entregou ao origin (nada pendente), uma por linha "<sha> <branch>": só elas podem ser alinhadas à ponta do origin; a com trabalho pendente é do dog e ninguém a mexe
delivered_branches() { local r=$1 b p pfx; pfx=$("$GIT" -C "$r" config --get-all gtmirror.prefix) || return 0   # sem prefixos: nenhuma branch é minha para alinhar
  for b in $("$GIT" -C "$r" for-each-ref --format='%(refname:strip=2)' refs/heads/); do for p in $pfx; do case "$b" in "$p"?*) branch_pending "$r" "$b" || echo "$("$GIT" -C "$r" rev-parse "refs/heads/$b") $b"; break;; esac; done; done; }
# o origin reescreveu (ou avançou) uma branch já entregue: refs/heads/<b> passa a ser a ponta dele, para o push do dog, feito sobre ela, ser fast-forward (sem isto o pre-receive o recusa como reescrita da ponta velha). stdin = a saída de
# delivered_branches de ANTES do fetch. Só DEPOIS da varredura (a ponta adotada é uma que ela cobriu); CAS contra o sha daquela lista: um push que chegou no meio vence, e o próximo sync reavalia
adopt_origin_tips() { local r=$1 b s o
  while read -r s b; do   # linha sem branch, ou sem origin/<b> (o origin apagou a branch, ou a leitura falhou) → não alinho: o estado de antes é o inerte
    [ -n "$b" ] && o=$("$GIT" -C "$r" rev-parse -q --verify "refs/remotes/origin/$b") || continue; [ "$s" != "$o" ] || continue
    if "$GIT" -C "$r" update-ref -m "sync: o origin mudou $b" "refs/heads/$b" "$o" "$s"; then echo "sync: $b alinhada à ponta do origin (${s:0:7} → ${o:0:7})"
    else echo "sync: não alinhei $b à ponta do origin (${o:0:7}): a ref mudou durante o sync; o próximo sync refaz" >&2; fi
  done; }
cmd_publish() {   # empurra ao origin, SEM force, cada branch aceita ainda pendente
  local rigs rig r b s pfx p ok rc=0 prc err url lk why ot; rigs=$(rigs_of "${1:-}") || exit $?
  for rig in $rigs; do r=$(repo_of "$rig"); prc=0; url=$("$GIT" -C "$r" config --get remote.origin.url) || { echo "publish $rig: sem url do origin" >&2; rc=1; continue; }
    lock_take "$r/gtm-publish.lock" "${HETZNER_MIRROR_PUBLISH_WAIT:-60}"; lk=$?
    [ $lk = 0 ] || { echo "publish $rig: $(lock_why $lk publish "$r/gtm-publish.lock")$([ $lk != 1 ] || echo " (o próximo sweep refaz)")" >&2; rc=1; continue; }
    if pfx=$("$GIT" -C "$r" config --get-all gtmirror.prefix); then
      for b in $("$GIT" -C "$r" for-each-ref --format='%(refname:strip=2)' refs/heads/); do
        ok=0; for p in $pfx; do case "$b" in "$p"?*) ok=1;; esac; done; [ $ok = 1 ] || continue
        branch_pending "$r" "$b" || continue; s=$("$GIT" -C "$r" rev-parse "refs/heads/$b")
        if err=$(GIT_TERMINAL_PROMPT=0 tmo 300 "$GIT" -C "$r" push -q "$url" "$s:refs/heads/$b" 2>&1); then
          "$GIT" -C "$r" update-ref "refs/gt/published/$b" "$s"; echo "publish $rig: $b → origin ok"
        else prc=1; why=$(printf '%s' "$err" | tail -n 2 | tr '\n' ' ')
          # a causa que o dog consegue agir: o origin tem uma ponta que a do espelho não contém (o gate reescreveu a branch). rc 0/2 (o origin não explica, ou não consegui perguntar): fica o texto do git
          ot=$(origin_vs "$r" "$b" "$s"); [ $? != 1 ] || why="o origin tem $ot em $b, que ${s:0:7} (a ponta do espelho) não contém: sem force não entra. Rebase sobre origin/$b (o próximo sync do espelho o traz); se o espelho recusar o novo push por reescrita, use outro nome de branch"
          echo "publish $rig: $b NÃO chegou ao origin: $why" >&2
          "$GIT" -C "$r" config gtmirror.lastpublisherror "$(iso) $b: $why"; fi
      done
    else echo "publish $rig: sem prefixos configurados: não publico nada" >&2; prc=1; fi
    [ $prc = 0 ] && "$GIT" -C "$r" config --unset gtmirror.lastpublisherror 2>/dev/null
    rm -rf "$r/gtm-publish.lock"; rc=$((rc | prc))
  done; return $rc
}
serve_note() { mirror_ready "$1" && echo "as pontas não mudaram desde a última varredura boa: o espelho segue servindo" || echo "o espelho NÃO serve até uma rodada boa (a varredura não cobre as pontas atuais)"; }
cmd_scan_rig() {   # varre o conteúdo novo; só depois de TUDO gravado o filtro novo e o carimbo de cobertura entram (nessa ordem). rc 1 = a cobertura NÃO avançou (as pontas novas, se houver, ficam sem serviço; as velhas seguem servidas)
  local rig=$1 r spec oid out rc tm=${HETZNER_MIRROR_SCAN_TIMEOUT:-1800}; r=$(repo_of "$rig")
  out=$(tmo "$tm" python3 -I "$SCAN" "$r" "$(state_of "$rig")" 2>&1) || { rc=$?; [ $rc != 124 ] || out="$out (cortada: passou de ${tm}s; a leitura de blobs grava a cada ${HETZNER_MIRROR_SCAN_CKPT:-30}s e a próxima rodada continua do último ponto gravado)"; echo "sync $rig: $out" >&2; echo "sync $rig: varredura de conteúdo falhou: $(serve_note "$r")" >&2; return 1; }; echo "sync $rig: $out"
  spec=$(sparse_spec "$rig") || { echo "sync $rig: filtro ilegível depois da varredura: $(serve_note "$r")" >&2; return 1; }
  oid=$(printf '%s\n' "$spec" | "$GIT" -C "$r" hash-object -w --stdin) && "$GIT" -C "$r" config gtmirror.sparseoid "$oid" && "$GIT" -C "$r" config gtmirror.scannedtips "$(tips_hash "$r")" \
    || { echo "sync $rig: não gravei o filtro/cobertura: $(serve_note "$r")" >&2; return 1; }
}
cmd_sync() {
  local rigs rig r rc=0 err m lk dlv; rigs=$(rigs_of "${1:-}") || exit $?
  [ -n "$rigs" ] || { echo "sync: nenhum espelho (rode init)"; return 0; }
  for rig in $rigs; do r=$(repo_of "$rig"); lock_take "$r/gtm-fetch.lock" 0; lk=$?
    if [ $lk = 0 ]; then
      dlv=$(delivered_branches "$r")   # ANTES do fetch: "entregue" é o que o espelho tinha em dia com o origin até agora (vazio = nenhuma, ou não consegui listar: nada será alinhado)
      if err=$(GIT_TERMINAL_PROMPT=0 tmo 900 "$GIT" -C "$r" fetch -q --prune --no-tags origin 2>&1); then
        if cmd_scan_rig "$rig"; then
          adopt_origin_tips "$r" <<< "$dlv"
          m=$("$GIT" -C "$r" rev-parse -q --verify refs/remotes/origin/main 2>/dev/null || echo desconhecido)
          # carimbo: commit de árvore vazia cuja DATA é a do último fetch+varredura bons; o servidor o busca com o resto (refs/gt/*) e lê a data, sem canal à parte
          if "$GIT" -C "$r" update-ref refs/gt/synced "$("$GIT" -C "$r" commit-tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904 -m "origin/main=$m $(iso)")"; then
            echo "sync $rig: ok origin/main=${m:0:7}"; "$GIT" -C "$r" config --unset gtmirror.lastfetcherror 2>/dev/null
          else rc=1; echo "sync $rig: varredura ok mas não gravei o carimbo" >&2; fi
        else rc=1; "$GIT" -C "$r" config gtmirror.lastfetcherror "$(iso) varredura de conteúdo falhou"; fi
      else rc=1; echo "sync $rig: origin inacessível: $(printf '%s' "$err" | tail -n 1)" >&2; "$GIT" -C "$r" config gtmirror.lastfetcherror "$(iso) $(printf '%s' "$err" | tail -n 1)"; fi
      rm -rf "$r/gtm-fetch.lock"
    elif [ $lk = 1 ]; then echo "sync $rig: $(lock_why 1 sync)"   # concorrente normal: rc 0. Parada (2) e erro meu (3) NÃO são isso: rc 1 e erro registrado, para o status mostrar
    else rc=1; err=$(lock_why $lk sync "$r/gtm-fetch.lock"); echo "sync $rig: $err" >&2; "$GIT" -C "$r" config gtmirror.lastfetcherror "$(iso) $err" 2>/dev/null; fi
    cmd_publish "$rig" || rc=1
  done; return $rc
}
cmd_status() {
  local rigs rig r rc=0 t pend b pfx p spec rdy e n age mx=${HETZNER_MIRROR_STALE_MIN:-60}; rigs=$(rigs_of "${1:-}") || exit $?   # rc 0 só com tudo em dia: pronto, filtro igual, sem erro, nada pendente, último sync bom de menos de $mx min
  [ -n "$rigs" ] || { echo "status: nenhum espelho (rode init)"; return 1; }
  for rig in $rigs; do r=$(repo_of "$rig"); pend=""
    t=$("$GIT" -C "$r" log -1 --format=%ct refs/gt/synced 2>/dev/null); pfx=$("$GIT" -C "$r" config --get-all gtmirror.prefix) || pfx=""
    for b in $("$GIT" -C "$r" for-each-ref --format='%(refname:strip=2)' refs/heads/); do for p in $pfx; do case "$b" in "$p"?*) branch_pending "$r" "$b" && pend="$pend $b";; esac; done; done
    spec=igual; [ "$(sparse_spec "$rig" 2>/dev/null | "$GIT" hash-object --stdin)" = "$("$GIT" -C "$r" config gtmirror.sparseoid)" ] || { spec="DIFERENTE-ou-ilegível(rode sync)"; rc=1; }
    age=desconhecido; [ -z "$t" ] || { age="$(( ($(date +%s) - t) / 60 )) min"; [ "${age% min}" -le "$mx" ] || { age="$age (VELHO: passou de $mx min)"; rc=1; }; }
    mirror_ready "$r" && rdy=sim || { rdy="NÃO (varredura não cobre as pontas: o servidor não é atendido)"; rc=1; }
    if [ -e "$(state_of "$rig")/deny-extra" ]; then n=$(grep -c . "$(state_of "$rig")/deny-extra" 2>/dev/null); [ $? -le 1 ] || { n="ILEGÍVEL"; rc=1; }; else n="0 (nenhuma varredura ainda)"; fi
    echo "$rig: pronto=$rdy · último fetch+varredura bons há $age · caminhos negados por conteúdo=$n · prefixos=[$(echo $pfx)] · filtro=$spec · pendentes ao origin=[${pend# }]"
    for e in lastfetcherror lastpublisherror; do [ -n "$("$GIT" -C "$r" config gtmirror.$e)" ] && { echo "  $e: $("$GIT" -C "$r" config gtmirror.$e)"; rc=1; }; done
    [ -z "$pend" ] && [ -n "$t" ] || rc=1
  done; return $rc
}

# ── o que o servidor toca: serve (comando forçado da chave), hooks do espelho e o gancho do pack ───────────────────────────────────────────────────────────────────
cmd_serve() {
  local c=${SSH_ORIGINAL_COMMAND-} rig repo re="^(git-upload-pack|git-receive-pack|gt-mirror-spec) '/?([a-z][a-z0-9_-]{0,40})(\\.git)?'\$"
  if [[ "$c" =~ $re ]] && rig=${BASH_REMATCH[2]} && repo=$(repo_of "$rig") && [ -d "$repo" ] && [ ! -L "$repo" ]; then
    unset GIT_PROTOCOL; export HETZNER_MIRROR_HOME="$MH"   # o sshd não aceita env; o unset é o cinto: sem protocolo v2, fetch por oid de blob omitido é recusado
    case "${BASH_REMATCH[1]}" in
      git-upload-pack) exec "$GIT" -c uploadpack.allowFilter=true -c "uploadpack.packObjectsHook=$SELF pack-hook" upload-pack --strict --timeout=900 "$repo" ;;
      gt-mirror-spec) exec "$SELF" spec-out "$rig" ;;
      *) exec "$GIT" receive-pack "$repo" ;;
    esac
  fi
  printf '%s recusado: %s\n' "$(iso)" "$(printf '%.120s' "$c" | tr -c '[:print:]' '?')" >> "$MH/serve.log" 2>/dev/null
  echo "espelho: recusado — esta chave só roda git-upload-pack/git-receive-pack/gt-mirror-spec nos espelhos (nada foi executado)" >&2; exit 126
}
cmd_spec_out() {   # o filtro vigente, para o servidor saber com qual oid pedir. Só sai se a varredura cobre as pontas de agora
  local r; r=$(repo_of "${1:-}"); [ -d "$r" ] || die 2 "espelho desconhecido: ${1:-}"
  mirror_ready "$r" || { echo "espelho: em atualização — a varredura de dado ainda não cobre as pontas atuais (tente de novo em alguns minutos)" >&2; exit 75; }
  "$GIT" -C "$r" cat-file blob "$("$GIT" -C "$r" config --get gtmirror.sparseoid)" || die 3 "filtro gravado ilegível"
}
cmd_pack_hook() {   # o upload-pack roda o pack-objects por aqui; só passa o pedido que traz o filtro de dados VIGENTE deste espelho e só com a varredura em dia
  local want a oid; oid=$("$GIT" config --get gtmirror.sparseoid) || oid=""; want="--filter=sparse:oid=$oid"
  if [ "${1:-}" = git ] && [ "${2:-}" = pack-objects ] && [ -n "$oid" ] && mirror_ready .; then for a in "$@"; do [ "$a" = "$want" ] && exec "$@"; done; fi
  echo "espelho: pedido recusado — sem o filtro de dados vigente deste espelho, ou a varredura de dado não cobre as pontas atuais (o servidor não recebe blob de dado/segredo)" >&2; exit 1
}
cmd_hook() {
  local old new ref pfx p ok bad=0 t rig rr ot orc b div=0 kick=0; pfx=$("$GIT" config --get-all gtmirror.prefix) || pfx=""; rr=$(pwd -P); rig=$(basename "$rr" .git)
  case "${1:-}" in
    post-receive)   # o push JÁ foi aceito; aqui só se AVISA, no stderr do push do dog (ga-jgxgn6): o publish roda em segundo plano e, sozinho, o dog nunca saberia que a branch dele não vai ao origin
      while read -r old new ref; do case "$ref" in refs/heads/?*) b=${ref#refs/heads/}
        ot=$(origin_vs "$rr" "$b" "$new"); case $? in
          1) div=1; echo "espelho: AVISO — $ref foi recebido, mas o origin tem $ot em $b, que o seu push NÃO contém: a publicação (sem force) será RECUSADA e nada chega ao origin. Rebase sobre origin/$b (o espelho está trazendo essa ponta agora: git fetch origin em ~2 min, e confira git rev-parse origin/$b = $ot) e empurre de novo; se o espelho recusar o novo push por reescrita, use outro nome de branch" >&2 ;;
          2) echo "espelho: AVISO — não consegui conferir agora se o origin mudou $b (origin mudo ou lento): o push foi aceito, mas se o origin tem uma ponta que o seu push não contém a publicação será recusada. hetzner-mirror.sh status (no mini) e git fetch origin (aqui) mostram" >&2 ;;
        esac ;; esac; done
      if [ $div = 1 ]; then echo "espelho: recebido, mas NÃO será publicado (ver AVISO acima)"; kick_sync "$rig"   # o sync traz a ponta nova do origin e tenta o publish ao fim (que falha e grava o motivo em lastpublisherror)
      else echo "espelho: recebido; a publicação no origin segue em segundo plano (hetzner-mirror.sh status mostra o que ficar pendente)"
        bg_run "$MH/publish.log" env HETZNER_MIRROR_HOME="$MH" "$SELF" publish "$rig"; fi
      exit 0 ;;
    pre-receive) ;;
    *) die 2 "hook: ${1:-}" ;;
  esac
  [ -n "$pfx" ] || { echo "espelho: recusado — sem prefixos aceitos configurados (init não rodou?)" >&2; exit 1; }
  t=$(mktemp -d "${TMPDIR:-/tmp}/hm.XXXXXX") || { echo "espelho: recusado — sem diretório temporário para conferir o push" >&2; exit 1; }
  while read -r old new ref; do
    ok=0; for p in $pfx; do case "$ref" in "refs/heads/$p"?*) ok=1;; esac; done
    if [[ "$new" =~ ^0+$ ]]; then echo "espelho: recusado — apagar branch ($ref) não é aceito" >&2; bad=1; continue; fi
    case "$ref" in refs/heads/main|refs/heads/master) echo "espelho: recusado — $ref nunca recebe push do servidor" >&2; bad=1; continue;; refs/tags/*) echo "espelho: recusado — tag ($ref) não é aceita" >&2; bad=1; continue;; esac
    if [ $ok != 1 ] || ! "$GIT" check-ref-format "$ref"; then echo "espelho: recusado — $ref fora dos prefixos aceitos [$(echo $pfx)]" >&2; bad=1; continue; fi
    [ "$("$GIT" cat-file -t "$new" 2>/dev/null)" = commit ] || { echo "espelho: recusado — $ref não aponta para um commit legível" >&2; bad=1; continue; }
    if ! [[ "$old" =~ ^0+$ ]] && ! "$GIT" merge-base --is-ancestor "$old" "$new" 2>/dev/null; then echo "espelho: recusado — $ref reescreve histórico já entregue: a ponta do espelho é $old e o seu push não a contém. Se o gate reescreveu a branch no origin: git fetch origin, confira origin/${ref#refs/heads/} e refaça o conserto sobre ela (o espelho alinha a ponta a cada sync); senão use outro nome de branch" >&2; bad=1; continue; fi
    # o origin já tem uma ponta desta branch que este push não contém (o gate reescreveu, ou alguém empurrou por cima)? O publish, sem force, nunca a entregaria: recuso AGORA, com a ponta do origin na mensagem (ga-jgxgn6), em vez de aceitar um push que ninguém publica
    # vazio → o origin não tem a branch: aceito · não consegui ler o origin (rc 2) → aceito, que é o estado de antes; o post-receive diz que não conferiu
    ot=$(origin_vs "$rr" "${ref#refs/heads/}" "$new"); orc=$?
    if [ $orc = 1 ]; then echo "espelho: recusado — $ref: o origin tem $ot, que o seu push NÃO contém, e a publicação (sem force) seria recusada. Rebase sobre origin/${ref#refs/heads/}: o espelho está trazendo essa ponta agora (git fetch origin em ~2 min; confira git rev-parse origin/${ref#refs/heads/} = $ot) e empurre de novo" >&2; kick=1; bad=1; continue; fi
    # dado no commit: os caminhos tocados pelos commits NOVOS passam pelas mesmas regras do filtro; --diff-filter=d (minúsculo = tudo MENOS D, o único status sem blob novo: A, M, T…). Cada etapa vai a arquivo para o rc de cada uma ser lido (NUL não cabe em variável)
    # --cc: sem ele o git não lista NADA de um commit de merge, e um arquivo de dado que entra só no próprio merge passava; -m listaria também o que veio do outro lado e já estava no histórico (recusaria merge legítimo)
    if ! "$GIT" log --format= --name-only -z --no-renames --diff-filter=d --cc "$new" --not --all > "$t/paths" 2>/dev/null; then echo "espelho: recusado — não consegui ler os arquivos de $ref" >&2; bad=1; continue; fi
    if ! tr -s '\0' < "$t/paths" | deny_match "$rig" > "$t/hits"; then echo "espelho: recusado — não consegui conferir arquivos de dado em $ref" >&2; bad=1; continue; fi
    if [ -s "$t/hits" ]; then echo "espelho: recusado — $ref traz arquivo de dado/segredo (filtro do servidor): $(tr '\0' ' ' < "$t/hits" | cut -c1-300)" >&2; bad=1; fi
  done
  [ $kick = 0 ] || kick_sync "$rig"; rm -rf "$t"; exit $bad
}

# ── a chave, o sshd só-chave e o túnel reverso ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────
cmd_authorize() {   # authorize <arquivo.pub>: UMA chave ed25519 pura; grava a linha com restrict + comando forçado + só de loopback
  local f=${1:-} line key want re='^ssh-ed25519 (AAAA[0-9A-Za-z+/]+={0,2})( [A-Za-z0-9_.@-]+)?$'
  [ -r "$f" ] || die 2 "uso: authorize <arquivo.pub>"; [ "$(grep -c . "$f")" = 1 ] || die 3 "o arquivo precisa ter UMA chave, e só uma"
  line=$(grep . "$f"); [[ "$line" =~ $re ]] || die 3 "só aceito uma chave ssh-ed25519 pura (sem opções, sem comentário estranho)"; key=${BASH_REMATCH[1]}
  case "$SELF$MH" in *[\"\'\ \\]*) die 3 "caminho com aspas ou espaço no comando forçado: recuso";; */.gc-worktrees/*) [ "${HETZNER_MIRROR_ALLOW_WORKTREE:-}" = 1 ] || die 3 "rode do caminho mergeado";; esac
  mkdir -p "$MH" && chmod 700 "$MH"; touch "$MH/authorized_keys" && chmod 600 "$MH/authorized_keys" || die 3 "não consegui gravar authorized_keys"
  want=$(printf 'restrict,from="127.0.0.1,::1",command="HETZNER_MIRROR_HOME=%s %s serve" ssh-ed25519 %s gt-mirror' "$MH" "$SELF" "$key")
  if grep -qF -- "$key" "$MH/authorized_keys"; then   # a chave já está: se o comando forçado aponta para OUTRO script (cópia de antes do merge), troca a linha; senão não mexe
    grep -qxF -- "$want" "$MH/authorized_keys" && { echo "authorize: a chave já está lá"; return 0; }
    grep -vF -- "$key" "$MH/authorized_keys" > "$MH/authorized_keys.new.$$"; [ $? -le 1 ] || { rm -f "$MH/authorized_keys.new.$$"; die 3 "não consegui ler authorized_keys: não troco a linha"; }   # rc 1 = sobrou zero linhas (ok); rc 2 = erro de leitura
    printf '%s\n' "$want" >> "$MH/authorized_keys.new.$$" && chmod 600 "$MH/authorized_keys.new.$$" && mv "$MH/authorized_keys.new.$$" "$MH/authorized_keys" && echo "authorize: comando forçado atualizado" || die 3 "não consegui trocar a linha"
    return 0
  fi
  printf '%s\n' "$want" >> "$MH/authorized_keys" && echo "authorize: ok"
}
sshd_conf() {
  mkdir -p "$MH" && chmod 700 "$MH"; [ -f "$MH/host_key" ] || ssh-keygen -q -t ed25519 -N '' -f "$MH/host_key" || return 3
  cat > "$MH/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $MH/host_key
PidFile $MH/sshd.pid
AuthorizedKeysFile $MH/authorized_keys
AllowUsers $(id -un)
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
PermitRootLogin no
PermitTTY no
PermitUserEnvironment no
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
StrictModes ${HETZNER_MIRROR_STRICTMODES:-yes}
MaxAuthTries 2
LoginGraceTime 20
ClientAliveInterval 30
LogLevel VERBOSE
EOF
}
cmd_sshd() {
  local p; sshd_conf || die 3 "não consegui montar o sshd_config"; p=$(cat "$MH/sshd.pid" 2>/dev/null)
  case "${1:-}" in
    run) exec /usr/sbin/sshd -D -e -f "$MH/sshd_config" ;;
    start) /usr/sbin/sshd -t -f "$MH/sshd_config" || die 3 "sshd_config recusado"; /usr/sbin/sshd -f "$MH/sshd_config" -E "$MH/sshd.log" && sleep 1 && cmd_sshd status ;;
    stop) if [ -n "$p" ] && proc_is "$p" "$MH/sshd_config"; then kill "$p" && echo "sshd do espelho: parado"; else echo "sshd do espelho: não estava rodando"; fi ;;
    status) if [ -n "$p" ] && proc_is "$p" "$MH/sshd_config"; then echo "sshd do espelho: rodando (pid $p, 127.0.0.1:$PORT)"; else echo "sshd do espelho: parado"; return 1; fi ;;
    *) die 2 "uso: sshd start|stop|status|run" ;;
  esac
}
cmd_tunnel() {   # túnel reverso: a porta do sshd do espelho aparece no loopback do SERVIDOR. start/stop/status guardam um pid; para durar, use `run` num launchd com KeepAlive
  local a=${1:-} h=${2:-} pf p; [[ "$h" =~ ^[A-Za-z0-9_.-]+$ ]] || die 2 "uso: tunnel start|stop|status|run <host-ssh>"
  local cmd=(ssh -N -R "127.0.0.1:$PORT:127.0.0.1:$PORT" -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o BatchMode=yes "$h")
  pf="$MH/tunnel-$h.pid"; p=$(cat "$pf" 2>/dev/null)
  case "$a" in
    run) exec "${cmd[@]}" ;;
    start) if [ -n "$p" ] && proc_is "$p" "${cmd[*]}"; then echo "túnel $h: já rodando (pid $p)"; else mkdir -p "$MH"; bg_run "$MH/tunnel-$h.log" "${cmd[@]}"; echo $! > "$pf"; sleep 3; cmd_tunnel status "$h"; fi ;;
    stop) if [ -n "$p" ] && proc_is "$p" "${cmd[*]}"; then kill "$p" && echo "túnel $h: parado"; else echo "túnel $h: não estava rodando"; fi; rm -f "$pf" ;;
    status) if [ -n "$p" ] && proc_is "$p" "${cmd[*]}"; then echo "túnel $h: rodando (pid $p)"; else echo "túnel $h: parado"; return 1; fi ;;
    *) die 2 "uso: tunnel start|stop|status|run <host-ssh>" ;;
  esac
}

case "${1:-}" in
  init) shift; cmd_init "$@" ;; sync) cmd_sync "${2:-}" ;; publish) cmd_publish "${2:-}" ;; status) cmd_status "${2:-}" ;;
  sparse) sparse_spec "${2:-}" ;; authorize) cmd_authorize "${2:-}" ;; hostkey) sshd_conf && echo "[127.0.0.1]:$PORT $(cut -d' ' -f1,2 "$MH/host_key.pub")" ;;
  sshd) cmd_sshd "${2:-}" ;; tunnel) cmd_tunnel "${2:-}" "${3:-}" ;; serve) cmd_serve ;; hook) shift; cmd_hook "$@" ;; pack-hook) shift; cmd_pack_hook "$@" ;; spec-out) cmd_spec_out "${2:-}" ;;
  *) die 2 "uso: $(sed -n 's/^# SUBCOMANDOS: //p' "$SELF" | head -n 1)" ;;
esac
