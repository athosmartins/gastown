#!/bin/bash
# hetzner-remote-git.sh — o lado SERVIDOR do espelho git (ga-2hd02v.1.3, fatia 4). Roda no Hetzner como `runner`, instalado em ~/gt-remote/bin/. Doc: docs/runbooks/hetzner-git-mirror.md
#
# ## Contents
#   Subcomandos · Códigos de saída
#
# Por rig, um clone BARE parcial (~/gt-remote/git/<rig>/repo.git) cujo ÚNICO remoto é o espelho do mini, e um worktree por bead (…/wt/<bead>). O filtro de dados vem do ESPELHO a cada pull; nenhum remoto aponta para o GitHub.
# SUBCOMANDOS: bootstrap <rig> <url-do-espelho> <chave> <known_hosts> [prefixo/]... | pull <rig> | wt-add <rig> <bead> [base] | wt-rm <rig> <bead> | status [rig] | scan [rig...]
# CÓDIGOS: 0 ok · 1 violação (scan) / pull falhou · 2 uso ou NÃO consegui varrer (nunca "limpo") · 3 recusado por não poder conferir
set -u
GR=${GT_REMOTE_GIT:-$HOME/gt-remote/git}
RE_RIG='^[a-z][a-z0-9_-]{0,40}$'; RE_BEAD='^[a-z0-9][a-z0-9._-]{0,60}$'; RE_PATH='^[A-Za-z0-9_./-]+$'
die() { local rc=$1; shift; echo "hetzner-remote-git: $*" >&2; exit "$rc"; }
g() { git -C "$GR/$RIG/repo.git" "$@"; }
rig_of() { RIG=${1:-}; [[ "$RIG" =~ $RE_RIG ]] && [ -d "$GR/$RIG/repo.git" ] || die 2 "clone desconhecido: $RIG (rode bootstrap)"; }
now() { date +%s; }

lag_fields() {   # a idade da fotografia do origin que este clone tem = agora − data do carimbo refs/gt/synced que o espelho publicou; sem carimbo é "null", nunca 0
  local m t mt; m=$(g rev-parse -q --verify refs/remotes/origin/main 2>/dev/null); t=$(g log -1 --format=%ct refs/gt/synced 2>/dev/null); mt=""
  [ -n "$m" ] && mt=$(g log -1 --format=%ct "$m" 2>/dev/null)
  LAG_MAIN=${m:0:7}; LAG_MIN=null; MAIN_AGE=null
  [ -n "$t" ] && LAG_MIN=$(( ($(now) - t) / 60 )); [ -n "$mt" ] && MAIN_AGE=$(( ($(now) - mt) / 60 )); return 0
}
cmd_pull() {   # 1) pergunta ao espelho o filtro VIGENTE (gt-mirror-spec; sai com 75 enquanto a varredura de dado não cobre as pontas) 2) confere que é um filtro 3) busca COM esse oid, nunca com outro
  local ef spec oid old url pre; rig_of "${1:-}"; PULL=erro; ef=$(mktemp) || die 3 "sem tmp"; url=$(g config gtremote.mirrorurl) && pre=$(g config gtremote.ssh) || die 3 "clone sem url/ssh do espelho"
  [[ "$url" =~ ^ssh://([A-Za-z0-9_.-]+)@([A-Za-z0-9_.-]+):([0-9]+)/([a-z][a-z0-9_-]*)\.git$ ]] || die 3 "url do espelho ilegível: $url"
  # shellcheck disable=SC2086  # $pre é a linha de opções do ssh; chave e known_hosts só têm [A-Za-z0-9_./-] (conferido no bootstrap)
  if spec=$(timeout 120 $pre -p "${BASH_REMATCH[3]}" "${BASH_REMATCH[1]}@${BASH_REMATCH[2]}" "gt-mirror-spec '${BASH_REMATCH[4]}'" 2> "$ef") \
     && [ "$(printf '%s\n' "$spec" | head -n 1)" = '/*' ] && [ "$(printf '%s\n' "$spec" | grep -c '^!')" -ge 20 ] && oid=$(printf '%s\n' "$spec" | git hash-object --stdin); then
    old=$(g config gtremote.sparseoid || true)
    printf '%s\n' "$spec" > "$GR/$RIG/sparse.new" && printf '%s\n' "$spec" | sed -e '1d' -e 's/^!//' > "$GR/$RIG/deny.new" && mv "$GR/$RIG/sparse.new" "$GR/$RIG/sparse" && mv "$GR/$RIG/deny.new" "$GR/$RIG/deny" \
      && g config gtremote.sparseoid "$oid" && g config remote.origin.partialclonefilter "sparse:oid=$oid" || die 3 "não gravei o filtro recebido"
    [ -z "$old" ] || [ "$old" = "$oid" ] || echo "pull rig=$RIG AVISO: o filtro do espelho mudou ($old → $oid); rode scan: dado já baixado antes da mudança não some sozinho"
    if GIT_TERMINAL_PROMPT=0 timeout 1800 git -C "$GR/$RIG/repo.git" fetch -q --prune "--filter=sparse:oid=$oid" origin 2> "$ef"; then PULL=ok; rm -f "$GR/$RIG/last-pull-error"; fi
  fi
  [ $PULL = ok ] || { grep -q . "$ef" || echo "o espelho não devolveu um filtro de dados válido (resposta vazia ou sem regras)" > "$ef"; echo "$(now) $(grep . "$ef" | tail -n 1 | tr -d '"')" > "$GR/$RIG/last-pull-error"; }; rm -f "$ef"
  lag_fields; echo "pull rig=$RIG resultado=$PULL main=$LAG_MAIN lag_min=$LAG_MIN$([ $PULL = erro ] && echo " erro=\"$(cut -d' ' -f2- "$GR/$RIG/last-pull-error")\"")"
  # o atraso fica REGISTRADO a cada pull (não só no wt-add): lag_min = idade da última varredura boa do espelho; null = o clone não tem carimbo (nunca vira 0)
  printf '{"ts":"%s","rig":"%s","pull":"%s","main":"%s","lag_min":%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RIG" "$PULL" "$LAG_MAIN" "$LAG_MIN" >> "$GR/pulls.jsonl" 2>/dev/null || echo "pull rig=$RIG AVISO: não consegui gravar $GR/pulls.jsonl"
  [ $PULL = ok ]
}
cmd_bootstrap() {
  [ $# -ge 4 ] || die 2 "uso: bootstrap <rig> <url> <chave> <known_hosts> [prefixo/]..."
  local rig=$1 url=$2 key=$3 kh=$4 p mux="-o ControlMaster=auto -o ControlPersist=120 -o ControlPath=$GR/.cm-%C" sshc; shift 4
  [[ "$rig" =~ $RE_RIG ]] && [[ "$key" =~ $RE_PATH ]] && [[ "$kh" =~ $RE_PATH ]] || die 2 "rig, chave ou known_hosts com caractere que recuso"
  [[ "$url" =~ ^ssh://[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+:[0-9]+/[a-z][a-z0-9_-]*\.git$ ]] || die 2 "url do espelho deve ser ssh://usuario@host:porta/<rig>.git"
  [ -r "$key" ] && [ -r "$kh" ] || die 3 "chave ou known_hosts ilegível"
  [ -n "${GT_REMOTE_NOMUX:-}" ] && mux="-o ControlMaster=no"
  mkdir -p "$GR/$rig/wt" || die 3 "não criei $GR/$rig"; RIG=$rig
  [ -d "$GR/$rig/repo.git" ] || git init -q --bare "$GR/$rig/repo.git" || die 3 "git init falhou"
  sshc="${GT_REMOTE_SSH:-ssh} -F /dev/null -i $key -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$kh -o ConnectTimeout=20 $mux"   # RTT 200 ms: 3 s por conexão nova, medido
  g config core.repositoryformatversion 1; g config extensions.partialClone origin; g config protocol.version 0; g config gtremote.mirrorurl "$url"; g config gtremote.ssh "$sshc"; g config core.sshCommand "$sshc"
  g config remote.origin.url "$url"; g config --replace-all remote.origin.fetch '+refs/remotes/origin/*:refs/remotes/origin/*'; g config --add remote.origin.fetch '+refs/gt/*:refs/gt/*'
  g config remote.origin.tagopt --no-tags; g config remote.origin.promisor true
  g config --unset-all remote.origin.push 2>/dev/null; for p in crew/ worker/ "$@"; do g config --add remote.origin.push "refs/heads/$p*:refs/heads/$p*"; done
  echo "bootstrap rig=$rig url=$url"; cmd_pull "$rig"
}
cmd_wt_add() {   # worktree por bead; ANTES atualiza o clone e GRAVA a idade do main usado (e se o pull falhou, grava que falhou: o worktree sai do que havia)
  rig_of "${1:-}"; [ -s "$GR/$RIG/sparse" ] || die 3 "clone sem filtro de dados (nenhum pull deu certo ainda): não crio worktree"; local bead=${2:-} base=${3:-main} path pull=ok line; [[ "$bead" =~ $RE_BEAD ]] || die 2 "bead inválida: $bead"
  [[ "$base" =~ $RE_BEAD ]] || die 2 "base inválida: $base"; path="$GR/$RIG/wt/$bead"
  [ -e "$path" ] && { echo "wt-add: $path já existe"; return 0; }
  cmd_pull "$RIG" > /dev/null 2>&1 || pull=erro
  g rev-parse -q --verify "refs/remotes/origin/$base" > /dev/null || die 3 "o clone não tem origin/$base (pull=$pull): não invento base"
  if g rev-parse -q --verify "refs/heads/worker/$bead" > /dev/null; then g worktree add -q --no-checkout "$path" "worker/$bead" || die 3 "worktree add falhou"
  else g worktree add -q --no-checkout -b "worker/$bead" "$path" "refs/remotes/origin/$base" || die 3 "worktree add falhou"; fi
  # sparse no worktree = os mesmos padrões do filtro; sem isto o checkout pediria ao espelho um blob de dado que ele recusa
  git -C "$path" sparse-checkout set --no-cone --stdin < "$GR/$RIG/sparse" && git -C "$path" checkout -q -f HEAD || die 3 "checkout esparso falhou em $path"
  lag_fields; line=$(printf '{"ts":"%s","rig":"%s","bead":"%s","branch":"worker/%s","base":"%s","main":"%s","main_age_min":%s,"lag_min":%s,"pull":"%s"}' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RIG" "$bead" "$bead" "$base" "$LAG_MAIN" "$MAIN_AGE" "$LAG_MIN" "$pull")
  echo "$line" >> "$GR/worktrees.jsonl"; echo "$line"
}
cmd_wt_rm() {
  rig_of "${1:-}"; local bead=${2:-} path kb; [[ "$bead" =~ $RE_BEAD ]] || die 2 "bead inválida: $bead"; path="$GR/$RIG/wt/$bead"; [ -d "$path" ] || die 2 "sem worktree $bead"
  kb=$(du -sk "$path" | cut -f1); g worktree remove --force "$path" && g worktree prune && [ ! -e "$path" ] && echo "wt-rm: $bead removido, liberou ${kb} KB" || die 3 "não removi $path"
}
cmd_status() {
  local rigs r b o s; rigs=${1:-$(ls "$GR" 2>/dev/null | while read -r r; do [ -d "$GR/$r/repo.git" ] && echo "$r"; done)}; [ -n "$rigs" ] || die 2 "nenhum clone"
  for r in $rigs; do rig_of "$r"; lag_fields; echo "$RIG: main=$LAG_MAIN idade_do_origin_min=$LAG_MIN idade_do_commit_main_min=$MAIN_AGE último_pull_com_erro=[$(cut -d' ' -f2- "$GR/$RIG/last-pull-error" 2>/dev/null)]"
    for b in $(g for-each-ref --format='%(refname:strip=2)' refs/heads/crew refs/heads/worker); do s=$(g rev-parse "refs/heads/$b"); o=$(g rev-parse -q --verify "refs/remotes/origin/$b" 2>/dev/null || true); p=$(g rev-parse -q --verify "refs/gt/published/$b" 2>/dev/null || true)
      if [ "$s" = "$o" ] || [ "$s" = "$p" ]; then echo "  $b: publicada no origin"
      elif g merge-base --is-ancestor "$s" refs/remotes/origin/main 2>/dev/null; then echo "  $b: sem trabalho novo (já está no main)"
      else echo "  $b: PENDENTE (empurre ao espelho ou aguarde o mini publicar)"; fi; done; done
}

# ── scan: dado/segredo e credencial do GitHub neste host. 0 limpo · 1 violação · 2 não consegui varrer (nunca "limpo") ───────────────────────────────────────────────────────
denied() {   # stdin: caminhos (um por linha) → stdout: os que o filtro nega, SEM aspas; rc 2 se não consegui avaliar. -z dos dois lados: sem ele o git imprime " \\ tab escapados e o cruzamento com os pares não reconhece o caminho
  local t rc=2 st; t=$(mktemp -d) || return 2
  if git init -q "$t/r" 2>/dev/null; then tr '\n' '\0' | git -C "$t/r" -c core.excludesFile="$GR/$RIG/deny" check-ignore --no-index -z --stdin | tr '\0' '\n'; st=${PIPESTATUS[1]}; case $st in 0|1) rc=0 ;; esac; fi
  rm -rf "$t"; return $rc
}
cmd_scan() {
  local rigs r rc=0 t u n; rigs=${*:-$(ls "$GR" 2>/dev/null | while read -r r; do [ -d "$GR/$r/repo.git" ] && echo "$r"; done)}; [ -n "$rigs" ] || { echo "scan: nenhum clone para varrer"; return 2; }
  t=$(mktemp -d) || return 2
  for r in $rigs; do rig_of "$r"
    [ -s "$GR/$RIG/deny" ] || { echo "scan $RIG: sem a lista de dados ($GR/$RIG/deny): NÃO consegui varrer"; rc=2; continue; }
    # violação = um blob PRESENTE aqui sob um caminho que o filtro nega. Pares (blob, caminho) de TODA a história via `log --raw` (só árvores: não busca nada no espelho) e blobs fisicamente
    # presentes via --batch-all-objects (também não busca). `rev-list --objects` não serve: nomeia cada objeto UMA vez (o mesmo conteúdo sob outro caminho esconde o primeiro) e lista árvores.
    if ! g log --all -m -z --raw --no-renames --no-abbrev --format= --diff-filter=AMC > "$t/raw" 2>/dev/null; then echo "scan $RIG: git log falhou: NÃO consegui varrer o histórico"; rc=2; continue; fi
    # o parse abaixo é por linha (NUL→\n): um nome com \n pode forjar um registro ":…" e esconder um arquivo negado sob outro nome. Em saída legítima de `log -z --raw --format=` não existe \n (0 em 4 clones reais): qualquer \n = recuso
    [ "$(tr -cd '\n' < "$t/raw" | wc -c | tr -d ' ')" = 0 ] || { echo "scan $RIG: há nome de arquivo com quebra de linha no histórico (o parse por linha não é seguro): NÃO consegui varrer"; rc=2; continue; }
    tr '\0' '\n' < "$t/raw" | awk 'want { if (mode != "160000") print oid "\t" $0; want = 0; next } /^:/ { split($0, f, " "); mode = f[2]; oid = f[4]; want = 1; next } length($0) { stray = 1 } END { if (want || stray) exit 3 }' > "$t/pairs.raw" \
      && sort -u "$t/pairs.raw" > "$t/pairs" || { echo "scan $RIG: saída do git log ilegível (ou caminho com quebra de linha): NÃO consegui varrer o histórico"; rc=2; continue; }
    if ! g cat-file --batch-all-objects --batch-check='%(objectname) %(objecttype)' > "$t/all" 2>/dev/null; then echo "scan $RIG: cat-file falhou: NÃO consegui listar os objetos"; rc=2; continue; fi
    awk '$2 == "blob" { print $1 }' "$t/all" | sort -u > "$t/present"
    awk 'index($0, "\t") { print substr($0, index($0, "\t") + 1) }' "$t/pairs" | sort -u | denied > "$t/denied-paths" || { echo "scan $RIG: não consegui avaliar os nomes do histórico"; rc=2; continue; }
    awk 'NR == FNR { i = index($0, "\t"); if (i) k[substr($0, i + 1)] = 1; next } !($0 in k) { bad = 1 } END { exit bad }' "$t/pairs" "$t/denied-paths" \
      || { echo "scan $RIG: o filtro devolveu um caminho que não está nos pares (aspas/escape?): NÃO consegui varrer"; rc=2; continue; }
    # violação = blob presente cujos caminhos são TODOS negados. Se algum caminho permitido carrega os mesmos bytes (fórmula copiada em outra pasta, arquivo vazio), a presença se explica e é contada à parte:
    # o filtro age por caminho, e bytes idênticos sob um nome permitido são permitidos. (Resíduo declarado no runbook: um segredo copiado para um caminho comum passa.)
    awk -v ex="$t/expl" 'FILENAME == ARGV[1] { present[$1] = 1; next } FILENAME == ARGV[2] { dp[$0] = 1; next }
      { i = index($0, "\t"); if (!i) next; o = substr($0, 1, i - 1); p = substr($0, i + 1); if (!(o in present)) next; if (p in dp) { if (!(o in fd)) fd[o] = p } else al[o] = 1 }
      END { for (o in fd) if (o in al) n++; else print fd[o]; print n + 0 > ex }' "$t/present" "$t/denied-paths" "$t/pairs" | sort -u > "$t/hit-obj" || { echo "scan $RIG: não consegui cruzar blobs e caminhos"; rc=2; continue; }
    ( cd "$GR/$RIG" && find . -type f -not -path './repo.git/*' -print0 ) > "$t/files0" 2>/dev/null && tr '\0' '\n' < "$t/files0" > "$t/files" && [ "$(tr -cd '\0' < "$t/files0" | wc -c | tr -d ' ')" = "$(wc -l < "$t/files" | tr -d ' ')" ] \
      || { echo "scan $RIG: find falhou ou há nome de arquivo com quebra de linha: NÃO consegui varrer a árvore"; rc=2; continue; }
    sed -e 's|^\./||' "$t/files" | grep -v -e '^sparse$' -e '^deny$' -e '^last-pull-error$' -e '/\.git$' | denied > "$t/hit-tree" || { echo "scan $RIG: não consegui avaliar a árvore"; rc=2; continue; }
    u=$(g config --get-regexp '^remote\..*\.url$' | awk '{print $2}' | grep -v -x -F "$(g config gtremote.mirrorurl)"; true)
    n="$(wc -l < "$t/pairs" | tr -d ' ') pares blob/caminho, $(wc -l < "$t/present" | tr -d ' ') blobs presentes ($(cat "$t/expl" 2>/dev/null || echo ?) deles com os mesmos bytes sob caminho permitido), $(wc -l < "$t/files" | tr -d ' ') arquivos"
    if [ -s "$t/hit-obj" ] || [ -s "$t/hit-tree" ] || [ -n "$u" ] || g config --get-regexp '^remote\..*\.url$' | grep -qi github; then
      echo "scan $RIG: VIOLAÇÃO ($n) historico=[$(head -n 5 "$t/hit-obj" | tr '\n' ' ')] arvore=[$(head -n 5 "$t/hit-tree" | tr '\n' ' ')] remotos_fora_do_espelho=[$u]"; [ $rc = 0 ] && rc=1
    else echo "scan $RIG: limpo ($n conferidos)"; fi
  done
  # credencial do GitHub no host: arquivo, helper, chave ssh que não é a do espelho, token no ambiente
  u=""; for r in .git-credentials .netrc .config/gh .config/git/credentials; do [ -e "$HOME/$r" ] && u="$u ~/$r"; done
  ls "$HOME"/.ssh/id_* > /dev/null 2>&1 && u="$u ~/.ssh/id_*"; grep -qsi github "$HOME/.ssh/known_hosts" "$HOME/.ssh/config" && u="$u ~/.ssh(github)"
  git config --system --get-regexp '^credential\.' > /dev/null 2>&1 && u="$u git-config-system(credential)"; git config --global --get-regexp '^credential\.' > /dev/null 2>&1 && u="$u git-config-global(credential)"
  grep -qsE '(GH|GITHUB)_TOKEN' "$HOME/.profile" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshenv" "$HOME/.pam_environment" /etc/environment && u="$u arquivo-de-shell(token)"
  [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ] && u="$u env(token)"
  if [ -n "$u" ]; then echo "scan credenciais: VIOLAÇÃO:$u"; [ $rc = 0 ] && rc=1; else echo "scan credenciais: limpo"; fi
  rm -rf "$t"; return $rc
}

case "${1:-}" in
  bootstrap) shift; cmd_bootstrap "$@" ;; pull) cmd_pull "${2:-}" ;; wt-add) cmd_wt_add "${2:-}" "${3:-}" "${4:-}" ;; wt-rm) cmd_wt_rm "${2:-}" "${3:-}" ;;
  status) cmd_status "${2:-}" ;; scan) shift; cmd_scan "$@" ;; *) die 2 "uso: $(sed -n 's/^# SUBCOMANDOS: //p' "$0" | head -n 1)" ;;
esac
