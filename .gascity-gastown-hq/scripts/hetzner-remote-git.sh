#!/bin/bash
# hetzner-remote-git.sh — o lado SERVIDOR do espelho git (ga-2hd02v.1.3, fatia 4). Roda no Hetzner como `runner`, instalado em ~/gt-remote/bin/. Doc: docs/runbooks/hetzner-git-mirror.md
#
# ## Contents
#   Subcomandos · Pull com ponta ausente (reparo / contorno) · gc do clone · Códigos de saída
#
# Por rig, um clone BARE parcial (~/gt-remote/git/<rig>/repo.git) cujo ÚNICO remoto é o espelho do mini, e um worktree por bead (…/wt/<bead>). O filtro de dados vem do ESPELHO a cada pull; nenhum remoto aponta para o GitHub.
# PULL COM PONTA AUSENTE (ga-yo1n1zg, ga-eivvcus): uma ref anunciada pelo espelho cuja ponta não está no clone derruba o fetch inteiro. 1º o REPARO (repair_stale): se a ref tem aqui o MESMO valor que o espelho anuncia (obsoleta), o git nunca pede o objeto; busco a ponta por refspec avulso e repito o fetch, com o mesmo filtro. 2º o CONTORNO (fetch_origin): repito sem as refs que continuam sem ponta. main e refs/gt/synced sem ponta, e mais de PULL_MAX_FORA refs, FALHAM alto. O espelho segue recusando todo pedido sem filtro; nada disso o afrouxa.
# GC DO CLONE (gc_safe, gravado a cada pull): gc.cruftPacks=false e repack.writeBitmaps=false. Medido numa cópia: com os padrões do git 2.43 o gc morre e perde um commit local; sem eles fecha. Detalhe e números: docs/runbooks/hetzner-git-mirror.md.
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
PULL_MAX_FORA=20   # teto de refs que um pull aceita deixar de fora (ponta ausente no clone); acima disso o dano é grande demais para contornar e o pull FALHA, alto
broken_refs() {   # $1 = dir de trabalho. As refs que o espelho anuncia, dentro do que o fetch busca, com a ponta AUSENTE neste clone: UMA só derruba o fetch inteiro em "did not send all necessary objects" (ga-yo1n1zg). Grava "<ref> <oid>" por linha em $1/bad. rc 0 = achei e posso contornar · rc 1 = NÃO contorno (RETRY_NOTE diz por quê)
  local t=$1 pats n; RETRY_NOTE=""
  # vazio → o clone não tem refspec de fetch: não sei o que o fetch busca, não contorno · falhou/ilegível → idem
  pats=$(g config --get-all remote.origin.fetch | sed -e '/^\^/d' -e 's/^+//' -e 's/:.*$//'); set -f; set -- $pats; set +f   # set -f: os padrões têm * e não podem virar glob de arquivo
  [ $# -gt 0 ] || { RETRY_NOTE="o clone não tem refspec de fetch (remote.origin.fetch vazio ou ilegível)"; return 1; }
  # vazio → o espelho não anunciou ref nenhuma: não sei o que falta, não contorno · falhou → idem (o stderr do fetch segue guardado)
  if GIT_TERMINAL_PROMPT=0 LC_ALL=C timeout 120 git -C "$GR/$RIG/repo.git" ls-remote origin "$@" > "$t/ls" 2> /dev/null && [ -s "$t/ls" ]; then :; else RETRY_NOTE="não consegui listar as refs do espelho"; return 1; fi
  # vazio → "clone sem objeto nenhum" é impossível com refs, e tomaria TODA ponta por ausente (excluiria tudo): não contorno · falhou → idem. cat-file -e por ponta custa 16 s no nó e --batch-check MORRE no 1º ausente; a lista inteira custa 0,05 s
  if g cat-file --batch-all-objects --batch-check='%(objectname)' > "$t/obj" 2> /dev/null && LC_ALL=C sort -u "$t/obj" > "$t/present" && [ -s "$t/present" ]; then :; else RETRY_NOTE="não consegui listar os objetos do clone"; return 1; fi
  awk -F'\t' '{ print $1 }' "$t/ls" | LC_ALL=C sort -u > "$t/tips"; LC_ALL=C comm -23 "$t/tips" "$t/present" > "$t/miss"
  awk -F'\t' 'NR == FNR { m[$1] = 1; next } ($1 in m) { print $2 " " $1 }' "$t/miss" "$t/ls" | LC_ALL=C sort > "$t/bad"   # miss vazio → bad vazio (o 2º arquivo é lido como se fosse o 1º)
  n=$(wc -l < "$t/bad" | tr -d ' '); [ "$n" -gt 0 ] || { RETRY_NOTE="nenhuma ponta anunciada falta neste clone: a causa não é ref sem objeto"; return 1; }
  grep -q -E '^refs/(remotes/origin/main|gt/synced) ' "$t/bad" && { RETRY_NOTE="a ponta de refs/remotes/origin/main ou de refs/gt/synced falta neste clone: não é ref lateral, não contorno"; return 1; }
  [ "$n" -le "$PULL_MAX_FORA" ] || { RETRY_NOTE="$n refs com ponta ausente (teto $PULL_MAX_FORA): dano grande demais para contornar"; return 1; }
}
repair_stale() {   # $1 = dir de trabalho (com o $1/bad de broken_refs) · $2 = oid do filtro · $3 = arquivo do stderr. rc 0 = o fetch passou (REPAIRED = <ref> <oid> por linha) · 1 = nenhuma ref obsoleta · 2 = tentou e não resolveu (o chamador refaz o levantamento: as pontas podem ter chegado)
  # Ref OBSOLETA = anunciada com a ponta ausente E com o MESMO valor aqui: o git a trata como "up to date" e nunca pede o objeto (sem `want`, o pack não o traz e a checagem de conectividade morre em "did not send all necessary objects"). Medido numa cópia do clone do nó (ga-eivvcus): o pull ficou parado desde 05/11 por isso, com main e refs/gt/synced entre as tentativas.
  # O reparo busca a ponta por refspec avulso, SEM par local (aí o git pede), com o MESMO filtro, e repete o fetch do pull. Nada é apagado e nada é afrouxado: filtro, varredura e a recusa do espelho valem como sempre; se a ponta não vem, main/synced seguem recusados (broken_refs).
  local t=$1 oid=$2 ef=$3 r o i=0 n cur; REPAIRED=""; : > "$t/stale"
  [ -s "$t/bad" ] || return 1   # sem levantamento (broken_refs não chegou a gravar o bad) → nada a reparar
  # rev-parse não abre o objeto (só lê a ref): num clone parcial, abri-lo dispararia um fetch preguiçoso
  while read -r r o; do cur=$(g rev-parse -q --verify "$r" 2> /dev/null) && [ "$cur" = "$o" ] && echo "$r $o" >> "$t/stale"; done < "$t/bad"
  [ -s "$t/stale" ] || return 1
  set --; while read -r r o; do i=$((i+1)); set -- "$@" "+$r:refs/gt/repair/$i"; done < <(LC_ALL=C sort -u -k2,2 "$t/stale")   # uma ref por ponta: duas refs na mesma ponta pedem o objeto uma vez só
  n=$i; echo "--- reparo: refs obsoletas, buscando a ponta delas ($(awk '{ printf "%s%s", s, $1; s = " " }' "$t/stale")) ---" >> "$ef"
  GIT_TERMINAL_PROMPT=0 LC_ALL=C timeout 1800 git -C "$GR/$RIG/repo.git" fetch -q "--filter=sparse:oid=$oid" origin "$@" 2>> "$ef"
  for i in $(seq 1 "$n"); do g update-ref -d "refs/gt/repair/$i" 2> /dev/null; done   # a ref avulsa só carrega o objeto; não fica nada dela (e o --prune do fetch seguinte também a varreria)
  if GIT_TERMINAL_PROMPT=0 LC_ALL=C timeout 1800 git -C "$GR/$RIG/repo.git" fetch -q --prune "--filter=sparse:oid=$oid" origin 2>> "$ef"; then REPAIRED=$(cat "$t/stale"); return 0; fi   # o rc do fetch inteiro decide, nunca o do avulso
  return 2
}
fetch_origin() {   # o fetch do pull. $1 = oid do filtro · $2 = arquivo que junta o stderr de TODAS as tentativas. rc 0 = passou (REPAIRED ≠ vazio: passou DEPOIS de rebuscar refs obsoletas · SKIPPED ≠ vazio: passou SEM essas refs) · rc 1 = falhou (RETRY_NOTE = por que não houve segunda tentativa, se não houve)
  local oid=$1 ef=$2 t r ok; SKIPPED=""; REPAIRED=""; RETRY_NOTE=""
  GIT_TERMINAL_PROMPT=0 LC_ALL=C timeout 1800 git -C "$GR/$RIG/repo.git" fetch -q --prune "--filter=sparse:oid=$oid" origin 2> "$ef" && return 0
  grep -q 'did not send all necessary objects' "$ef" || return 1   # outra falha (rede, filtro recusado, espelho em atualização): não há segunda tentativa
  t=$(mktemp -d) || { RETRY_NOTE="sem tmp"; return 1; }
  # 1º o reparo (ref obsoleta, inclusive main e refs/gt/synced: a recusa deles abaixo só vale para a ponta que o reparo NÃO trouxe); se o fetch ainda falha, refaço o levantamento e sigo o caminho de antes
  broken_refs "$t"; ok=$?
  repair_stale "$t" "$oid" "$ef"; case $? in 0) rm -rf "$t"; return 0 ;; 2) broken_refs "$t"; ok=$? ;; esac
  [ $ok = 0 ] || { rm -rf "$t"; return 1; }
  # -c remote.origin.fetch=^<ref> SOMA-SE aos refspecs da config (os positivos seguem valendo, medido) e não deixa nada gravado se o processo morrer; o MESMO --filter vai junto (o oid vigente, nunca outro)
  set --; while read -r r _; do set -- "$@" -c "remote.origin.fetch=^$r"; done < "$t/bad"
  echo "--- tentativa 2: sem as refs de ponta ausente ($(awk '{ printf "%s%s", s, $1; s = " " }' "$t/bad")) ---" >> "$ef"
  if GIT_TERMINAL_PROMPT=0 LC_ALL=C timeout 1800 git -C "$GR/$RIG/repo.git" "$@" fetch -q --prune "--filter=sparse:oid=$oid" origin 2>> "$ef"; then SKIPPED=$(cat "$t/bad"); rm -rf "$t"; return 0; fi   # o rc decide: um fetch que PASSA ainda escreve "Could not read" no stderr
  rm -rf "$t"; return 1
}
skipped_view() {   # as refs que o último pull deixou de fora, em uma linha. arquivo ausente → vazio (nenhuma) · existe e ilegível → "?" (não sei), nunca vazio
  local f="$GR/$RIG/last-pull-skipped"
  if [ -r "$f" ]; then awk '{ printf "%s%s(%s)", s, $1, substr($2, 1, 7); s = " " }' "$f"; elif [ -e "$f" ]; then printf '?'; fi
}
gc_safe() {   # o gc padrão do git 2.43 num clone PARCIAL, medido numa cópia do clone do nó (ga-eivvcus): com cruft (gc.cruftPacks, o padrão) o gc morreu num fetch preguiçoso que o espelho recusa e o commit criado aqui (só num pack local, pai de um commit vindo do espelho) SUMIU do clone;
  # sem cruft e sem bitmap o MESMO clone fechou o gc (rc 0) e o commit seguiu lá. Por que o cruft o perde é inferência (`repack --exclude-promisor-objects` toma esse commit por objeto do promisor). O bitmap não fecha neste clone parcial (o gc.log diário desde 22/10: "Packfile doesn't have full closure"; na cópia, cruft desligado + bitmap ligado deu "failed to write bitmap index" e deixou os packs como estavam). Idempotente.
  g config gc.cruftPacks false && g config repack.writeBitmaps false
}
cmd_pull() {   # 1) pergunta ao espelho o filtro VIGENTE (gt-mirror-spec; sai com 75 enquanto a varredura de dado não cobre as pontas) 2) confere que é um filtro 3) busca COM esse oid, nunca com outro 4) se o fetch morre em "did not send all necessary objects" por ref de ponta ausente, repete UMA vez sem essas refs (fetch_origin)
  local ef spec oid old url pre sum; rig_of "${1:-}"; PULL=erro; rm -f "$GR/$RIG/last-pull-skipped"; ef=$(mktemp) || die 3 "sem tmp"; url=$(g config gtremote.mirrorurl) && pre=$(g config gtremote.ssh) || die 3 "clone sem url/ssh do espelho"
  gc_safe || echo "pull rig=$RIG AVISO: não gravei gc.cruftPacks=false e repack.writeBitmaps=false no clone: o gc automático dele pode perder commit local e falhar todo dia"
  [[ "$url" =~ ^ssh://([A-Za-z0-9_.-]+)@([A-Za-z0-9_.-]+):([0-9]+)/([a-z][a-z0-9_-]*)\.git$ ]] || die 3 "url do espelho ilegível: $url"
  # shellcheck disable=SC2086  # $pre é a linha de opções do ssh; chave e known_hosts só têm [A-Za-z0-9_./-] (conferido no bootstrap)
  if spec=$(timeout 120 $pre -p "${BASH_REMATCH[3]}" "${BASH_REMATCH[1]}@${BASH_REMATCH[2]}" "gt-mirror-spec '${BASH_REMATCH[4]}'" 2> "$ef") \
     && [ "$(printf '%s\n' "$spec" | head -n 1)" = '/*' ] && [ "$(printf '%s\n' "$spec" | grep -c '^!')" -ge 20 ] && oid=$(printf '%s\n' "$spec" | git hash-object --stdin); then
    old=$(g config gtremote.sparseoid || true)
    printf '%s\n' "$spec" > "$GR/$RIG/sparse.new.$$" && printf '%s\n' "$spec" | sed -e '1d' -e 's/^!//' > "$GR/$RIG/deny.new.$$" && mv "$GR/$RIG/sparse.new.$$" "$GR/$RIG/sparse" && mv "$GR/$RIG/deny.new.$$" "$GR/$RIG/deny" \
      && g config gtremote.sparseoid "$oid" && g config remote.origin.partialclonefilter "sparse:oid=$oid" || die 3 "não gravei o filtro recebido"
    [ -z "$old" ] || [ "$old" = "$oid" ] || echo "pull rig=$RIG AVISO: o filtro do espelho mudou ($old → $oid); rode scan: dado já baixado antes da mudança não some sozinho"
    if fetch_origin "$oid" "$ef"; then PULL=ok; rm -f "$GR/$RIG/last-pull-error"
      [ -z "$REPAIRED" ] || echo "pull rig=$RIG REPARO: $(printf '%s\n' "$REPAIRED" | wc -l | tr -d ' ') ref(s) estavam obsoletas (anunciadas com a ponta ausente neste clone, que o git dava por 'up to date') e a ponta delas foi buscada com o filtro vigente: $(printf '%s\n' "$REPAIRED" | awk '{ printf "%s%s", s, $1; s = " " }')"
      if [ -n "$SKIPPED" ]; then   # passou, mas SEM refs: o main foi buscado (nunca fica de fora) e o clone segue com buraco. Tem de ficar visível (stdout, status), nunca parecer um pull limpo
        printf '%s\n' "$SKIPPED" > "$GR/$RIG/last-pull-skipped" || echo "pull rig=$RIG AVISO: não consegui gravar $GR/$RIG/last-pull-skipped"
        echo "pull rig=$RIG AVISO: $(printf '%s\n' "$SKIPPED" | wc -l | tr -d ' ') ref(s) ficaram FORA deste pull (ponta ausente neste clone): $(printf '%s\n' "$SKIPPED" | awk '{ printf "%s%s", s, $1; s = " " }'); o main foi buscado, mas o clone precisa de reparo (git fetch --refetch --filter=sparse:oid=<oid>, docs/runbooks/hetzner-git-mirror.md)"
      fi
    fi
  fi
  # o last-pull-error é o resumo de sempre na 1ª linha (<epoch> <última linha do git>, + o porquê de não ter havido retry) e, abaixo, o stderr INTEIRO de todas as tentativas (até 200 linhas; o que passar disso é contado, não calado)
  # o resumo ignora o aviso do gc automático: com um gc.log velho no clone, TODO fetch termina repetindo o conteúdo dele ("fatal: failed to run repack"), e esse eco virava a 1ª linha e escondia a causa do pull (ga-eivvcus)
  [ $PULL = ok ] || { grep -q . "$ef" || echo "o espelho não devolveu um filtro de dados válido (resposta vazia ou sem regras)" > "$ef"
    sum=$(awk '/^warning: The last gc run reported the following/ { exit } NF { l = $0 } END { print l }' "$ef"); [ -n "$sum" ] || sum=$(grep . "$ef" | tail -n 1)
    { echo "$(now) $(printf '%s' "$sum" | tr -d '"')${RETRY_NOTE:+ (retry não feito: $RETRY_NOTE)}"; sed -n '1,200p' "$ef"; [ "$(wc -l < "$ef")" -le 200 ] || echo "(… $(( $(wc -l < "$ef") - 200 )) linhas omitidas)"; } > "$GR/$RIG/last-pull-error"; }; rm -f "$ef"
  lag_fields; echo "pull rig=$RIG resultado=$PULL main=$LAG_MAIN lag_min=$LAG_MIN$([ $PULL = erro ] && echo " erro=\"$(head -n 1 "$GR/$RIG/last-pull-error" | cut -d' ' -f2-)\"")"
  # o atraso fica REGISTRADO a cada pull (não só no wt-add): lag_min = idade da última varredura boa do espelho; null = o clone não tem carimbo (nunca vira 0)
  printf '{"ts":"%s","rig":"%s","pull":"%s","main":"%s","lag_min":%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RIG" "$PULL" "$LAG_MAIN" "$LAG_MIN" >> "$GR/pulls.jsonl" 2>/dev/null || echo "pull rig=$RIG AVISO: não consegui gravar $GR/pulls.jsonl"
  [ $PULL = ok ]
}
cmd_bootstrap() {
  [ $# -ge 4 ] || die 2 "uso: bootstrap <rig> <url> <chave> <known_hosts> [prefixo/]..."
  local rig=$1 url=$2 key=$3 kh=$4 p mux="-o ControlMaster=auto -o ControlPersist=120 -o ControlPath=$GR/.cm-%C" sshc; shift 4
  [[ "$rig" =~ $RE_RIG ]] && [[ "$key" =~ $RE_PATH ]] && [[ "$kh" =~ $RE_PATH ]] || die 2 "rig, chave ou known_hosts com caractere que recuso"
  [[ "$url" =~ ^ssh://[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+:[0-9]+/[a-z][a-z0-9_-]*\.git$ ]] || die 2 "url do espelho deve ser ssh://usuario@host:porta/<rig>.git"
  [ -r "$key" ] && [ -r "$kh" ] || die 3 "chave ou known_hosts ilegível"; for p in "$@"; do [[ "$p" =~ ^[a-z][a-z0-9_-]*/$ ]] || die 2 "prefixo inválido: $p (como no init do espelho: letras minúsculas, dígitos, _ e -, terminando em /)"; done
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
  if [ -e "$path" ]; then git -C "$path" ls-files 2>/dev/null | head -n 1 | grep -q . || die 3 "worktree incompleto em $path (o checkout anterior não terminou): rode wt-rm $RIG $bead e tente de novo"; echo "wt-add: $path já existe"; return 0; fi
  cmd_pull "$RIG" > /dev/null || pull=erro   # só o stdout calado: o die 3 do pull (que encerra o script) precisa dizer o motivo
  g rev-parse -q --verify "refs/remotes/origin/$base" > /dev/null || die 3 "o clone não tem origin/$base (pull=$pull): não invento base"
  if g rev-parse -q --verify "refs/heads/worker/$bead" > /dev/null; then g worktree add -q --no-checkout "$path" "worker/$bead" || die 3 "worktree add falhou"
  else g worktree add -q --no-checkout -b "worker/$bead" "$path" "refs/remotes/origin/$base" || die 3 "worktree add falhou"; fi
  # sparse no worktree = os mesmos padrões do filtro; sem isto o checkout pediria ao espelho um blob de dado que ele recusa
  git -C "$path" sparse-checkout set --no-cone --stdin < "$GR/$RIG/sparse" && git -C "$path" checkout -q -f HEAD || die 3 "checkout esparso falhou em $path"
  # schema-dbs-v1: bancos só-schema (ga-kzwlkhh; wa-schema-dbs.py os instala em $GR/schema-dbs/<rig>) entram no worktree NOVO no mesmo caminho relativo (shared/ é ignorado pelo git no WA). vazio (nada instalado) → worktree como sempre;
  # falhou (cp) → o worktree segue SEM o banco (o teste fica vermelho e a bead volta ao mini) e o AVISO vai ao stderr; nunca aborta o wt-add
  if [ -d "$GR/schema-dbs/$RIG/shared" ]; then cp -R "$GR/schema-dbs/$RIG/shared" "$path/" 2>/dev/null || echo "wt-add: AVISO: não copiei a loja de schema-dbs para $path (o worktree segue sem os bancos só-schema)" >&2; fi
  lag_fields; line=$(printf '{"ts":"%s","rig":"%s","bead":"%s","branch":"worker/%s","base":"%s","main":"%s","main_age_min":%s,"lag_min":%s,"pull":"%s"}' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RIG" "$bead" "$bead" "$base" "$LAG_MAIN" "$MAIN_AGE" "$LAG_MIN" "$pull")
  echo "$line" >> "$GR/worktrees.jsonl"; echo "$line"
}
cmd_wt_rm() {
  rig_of "${1:-}"; local bead=${2:-} path kb; [[ "$bead" =~ $RE_BEAD ]] || die 2 "bead inválida: $bead"; path="$GR/$RIG/wt/$bead"; [ -d "$path" ] || die 2 "sem worktree $bead"
  kb=$(du -sk "$path" | cut -f1); g worktree remove --force "$path" && g worktree prune && [ ! -e "$path" ] && echo "wt-rm: $bead removido, liberou ${kb} KB" || die 3 "não removi $path"
}
cmd_status() {
  local rigs r b o s p pre; rigs=${1:-$(ls "$GR" 2>/dev/null | while read -r r; do [ -d "$GR/$r/repo.git" ] && echo "$r"; done)}; [ -n "$rigs" ] || die 2 "nenhum clone"
  for r in $rigs; do rig_of "$r"; lag_fields; echo "$RIG: main=$LAG_MAIN idade_do_origin_min=$LAG_MIN idade_do_commit_main_min=$MAIN_AGE último_pull_com_erro=[$(head -n 1 "$GR/$RIG/last-pull-error" 2>/dev/null | cut -d' ' -f2-)] refs_fora_do_pull=[$(skipped_view)]"
    # os prefixos são os que o bootstrap deu a ESTE clone (crew/ worker/ + os do rig, em remote.origin.push): listar só crew/ e worker/ escondia branch pendente de outro prefixo
    pre=$(g config --get-all remote.origin.push | sed -n 's|^refs/heads/\(.*\)\*:refs/heads/.*|refs/heads/\1|p'); [ -n "$pre" ] || pre="refs/heads/crew/ refs/heads/worker/"
    # shellcheck disable=SC2086  # $pre: prefixos de ref sem espaço (o bootstrap só aceita [a-z0-9_-]/)
    for b in $(g for-each-ref --format='%(refname:strip=2)' $pre); do s=$(g rev-parse "refs/heads/$b"); o=$(g rev-parse -q --verify "refs/remotes/origin/$b" 2>/dev/null || true); p=$(g rev-parse -q --verify "refs/gt/published/$b" 2>/dev/null || true)
      if [ "$s" = "$o" ] || [ "$s" = "$p" ]; then echo "  $b: publicada no origin"
      elif g merge-base --is-ancestor "$s" refs/remotes/origin/main 2>/dev/null; then echo "  $b: sem trabalho novo (já está no main)"
      # pendente que o origin NÃO vai aceitar (ga-jgxgn6): o origin/<b> que este clone tem (o do último pull) e a ponta daqui divergem, cada uma com commit que a outra não tem (o gate reescreveu a branch). "Aguarde o mini publicar" seria mentira
      # vazio → sem origin/<b> neste clone: nada a dizer, cai no texto de pendente · merge-base com erro (rc ≠ 1) → idem: só o rc 1 dos DOIS lados é divergência
      elif [ -n "$o" ] && { g merge-base --is-ancestor "$o" "$s" 2>/dev/null; [ $? = 1 ]; } && { g merge-base --is-ancestor "$s" "$o" 2>/dev/null; [ $? = 1 ]; }; then echo "  $b: PENDENTE e DIVERGE de origin/$b (${o:0:7}): o mini não vai publicar; refaça o trabalho sobre origin/$b (rode pull) e empurre com OUTRO nome se o espelho recusar por reescrita"
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
    # violação = um blob PRESENTE aqui sob um caminho que o filtro nega. Pares (blob, caminho) de TODA a história via `log --raw`, todo status menos D (--diff-filter=d: A, M, T…; só árvores, não busca nada no espelho) e blobs fisicamente
    # presentes via --batch-all-objects (também não busca). `rev-list --objects` não serve: nomeia cada objeto UMA vez (o mesmo conteúdo sob outro caminho esconde o primeiro) e lista árvores.
    if ! g log --all -m -z --raw --no-renames --no-abbrev --format= --diff-filter=d > "$t/raw" 2>/dev/null; then echo "scan $RIG: git log falhou: NÃO consegui varrer o histórico"; rc=2; continue; fi
    # o parse abaixo é por linha (NUL→\n): um nome com \n pode forjar um registro ":…" e esconder um arquivo negado sob outro nome. Em saída legítima de `log -z --raw --format=` não existe \n (0 em 4 clones reais): qualquer \n = recuso
    [ "$(tr -cd '\n' < "$t/raw" && echo x)" = x ] || { echo "scan $RIG: há nome de arquivo com quebra de linha no histórico (o parse por linha não é seguro): NÃO consegui varrer"; rc=2; continue; }
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
    # schema-dbs-v1: o caminho EXATO <wt>/<rel> de um banco só-schema do MANIFEST instalado (e os -wal/-shm/-journal dele) não é achado; qualquer outro .db segue sendo. vazio (sem MANIFEST, ou linha que não é caminho de banco: nunca vira regex) → nada liberado; falhou (grep rc > 1) → a lista fica como estava
    if [ -s "$GR/schema-dbs/$RIG/MANIFEST" ] && rx=$(grep -E '^shared/data/[A-Za-z0-9_./-]+\.(db|sqlite3?)$' "$GR/schema-dbs/$RIG/MANIFEST" | sed -e 's/\./\\./g' | paste -sd'|' -) && [ -n "$rx" ]; then
      grep -v -E "^wt/[^/]+/($rx)(-wal|-shm|-journal)?\$" "$t/hit-tree" > "$t/hit-tree.ok"; [ $? -le 1 ] && mv "$t/hit-tree.ok" "$t/hit-tree"
    fi
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
