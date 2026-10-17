#!/usr/bin/env bash
# hetzner-audit.sh — auditoria REPETÍVEL do que o servidor Hetzner guarda (ga-2hd02v.1.5.2, fatia 6b). Roda no MINI, só LÊ o servidor por ssh e não escreve nada lá.
#
# Contents
#   O que audita · Três estados · Saída e códigos · Como repetir · Limites
#
# O QUE AUDITA (cada verificação diz LIMPO | ACHADO | NAO-CONSEGUI):
#   processo          nenhum `claude auth login` esquecido (o de 15/10, pid 370419, ficou com a credencial já gravada).
#   credenciais       as ÚNICAS credenciais são as 3 de CRED_ALLOW (login do claude, atalho ssh→mini, chave do espelho git — a 3ª nasceu na fatia 4 e a bead só
#                     citava 2), com modo 600 e dono do usuário; qualquer outro arquivo com chave privada ou token (por CONTEÚDO, não por nome) ou loja
#                     de credencial conhecida (.netrc, .git-credentials, .aws...) é achado.
#   github-e-espelho  `hetzner-remote-git.sh scan` NO servidor (o que já existia: credencial do GitHub no host + dado negado no espelho git). Não é refeito aqui.
#   dados             o node_audit da semeadura (mbp-run.sh --host linux --audit-node): NOME · GRANDE · JWT · CONTEÚDO (telefones/CPFs) no topo do home (só os arquivos soltos, maxdepth 1)
#                     e em cada diretório de topo e filho de gt-remote/ EXCETO os de SKIP_NOTE (a linha LIMPO diz o que ficou de fora). Os padrões do find vivem SÓ lá; aqui só se escolhe ONDE olhar. Diretório novo = auditado.
#   backup-de-bead    .dolt, .dolt-backup, issues.jsonl, beads*.jsonl, e .beads com algo além de lock.
#
# TRÊS ESTADOS: achei / li tudo e não achei / não consegui ler (ssh caiu, comando ausente, pasta ilegível, saída que não reconheço). O último NUNCA vira LIMPO.
# SAÍDA (stdout): uma linha `AUDITORIA <estado> <verificação>: <detalhe>` por verificação (+ `AUDITORIA DETALHE dados: ...` por achado), sem valor de segredo nem de dado (só caminho e contagem), e
#   `AUDITORIA RESULTADO <estado> (...)`. CÓDIGOS: 0 tudo limpo · 1 algum ACHADO (vale mesmo que outra verificação tenha caído) · 3 nenhum achado mas algo não foi lido · 2 uso.
# COMO REPETIR: bash scripts/hetzner-audit.sh   (HETZNER_NODE_HOST e MBP_SSH como no mbp-run.sh). Selftest: scripts/hetzner-audit.selftest.sh.
# LIMITES: o que mora em .git/repo.git, venv*/env/site-packages/node_modules, ~/.cache, ~/.local/share/claude e tests/, fixtures/, *.selftest.*, test_* não é lido por CONTEÚDO
#   (compactado, de terceiros, ou token falso por desenho; o espelho git tem o `scan` próprio). Chave sem cabeçalho PEM/OPENSSH e token de formato novo passam pela busca de conteúdo. Esta auditoria não apaga nada: remover o achado é decisão de quem manda no servidor.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SSH_BIN=${MBP_SSH:-ssh}; HOST=${HETZNER_NODE_HOST:-hetzner-teste}; MBP_RUN=${HETZNER_AUDIT_MBP_RUN:-$HERE/mbp-run.sh}
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
# caminhos relativos ao home do servidor : o que são. Fora desta lista, credencial é achado.
CRED_ALLOW=(".claude/.credentials.json:login do claude" ".ssh/mini_shim_ed25519:atalho ssh→mini" "gt-remote/keys/gt_mirror:chave do espelho git (fatia 4)")
SKIP_TOP=" .cache .local .duckdb .ssh gt-remote "          # topo do home que NÃO é auditado por pasta: caches de ferramenta (o .duckdb tem verificação própria), .ssh (credenciais) e gt-remote (por filho)
SKIP_GT=" bin bundle bundle-out git keys venv-wa "         # filhos de gt-remote sem dado: ferramentas, bundle, espelho (scan), chaves (credenciais), venv
GT_PRUNE="prune=venv:env:.git:__pycache__"
SKIP_NOTE=".cache .local .duckdb .ssh (topo) e gt-remote/{bin,bundle,bundle-out,git,keys,venv-wa}"   # o que SKIP_TOP/SKIP_GT deixam de fora: a linha LIMPO do dados o repete, para o "limpo" não parecer maior que a cobertura
n_bad=0; n_cant=0; n_ok=0
emit() { # estado verificação detalhe
  case "$1" in ACHADO) n_bad=$((n_bad+1)) ;; NAO-CONSEGUI) n_cant=$((n_cant+1)) ;; *) n_ok=$((n_ok+1)) ;; esac
  printf 'AUDITORIA %s %s: %s\n' "$1" "$2" "$3"
}

# O script remoto só LÊ. Poda: caches e código de terceiros (ver LIMITES). `[c]laude` não casa com a própria linha de comando.
remote_a() { cat <<'EOF'
set -u -f
cd "$HOME" || { echo "ERR home"; exit 3; }
E=$(mktemp) || { echo "ERR mktemp"; exit 3; }; trap 'rm -f "$E"' EXIT
echo "HOST $(id -un)@$(hostname)"
PR=(-path ./.cache -o -path ./.local/share/claude -o -path ./.duckdb -o -path ./.claude/plugins -o -path ./.claude/downloads -o -name node_modules -o -name site-packages -o -name 'venv*' -o -name .venv -o -path './gt-remote/*/env' -o -name .git -o -name repo.git -o -name __pycache__)
P=$(pgrep -af '[c]laude.* auth login' 2>>"$E"); rc=$?
case $rc in 0) printf '%s\n' "$P" | cut -c1-100 | sed 's/^/PROC /' ;; 1) ;; *) echo "ERR processo" ;; esac
PT=(-path '*/tests/*' -o -path '*/fixtures/*' -o -name '*.selftest.*' -o -name 'test_*')   # token falso de teste, por desenho (medido: 10 de 10 achados da 1ª rodada eram isso)
# vazio → nenhuma linha CRED_HIT; falhou/ilegível → stderr do find/grep em $E e o ERR leitura abaixo (nunca "limpo")
find . \( "${PR[@]}" -o "${PT[@]}" \) -prune -o -type f -size -2049k -exec grep -lIE -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' -e 'sk-ant-[A-Za-z0-9_-]{20,}' -e 'gh[pousr]_[A-Za-z0-9]{30,}' \
  -e 'github_pat_[A-Za-z0-9_]{30,}' -e 'xox[abprs]-[A-Za-z0-9-]{10,}' -e 'AKIA[0-9A-Z]{16}' {} + 2>>"$E" | sed 's#^\./##; s/^/CRED_HIT /'
for f in "$@"; do
  if [ -e "$f" ]; then m=$(stat -c '%a %U' "$f" 2>>"$E") && echo "CRED_STAT $m $f" || echo "ERR stat $f"; else echo "CRED_MISSING $f"; fi
done
for f in .netrc .pgpass .npmrc .git-credentials .config/git/credentials .config/gh .aws .docker/config.json .config/gcloud .kube .gnupg .config/rclone .ssh/id_rsa .ssh/id_ed25519 .ssh/id_ecdsa .ssh/id_dsa; do
  [ -e "$f" ] && echo "CRED_NAME $f"
done
find . \( "${PR[@]}" \) -prune -o \( -name .dolt -o -name .dolt-backup -o -name dolt-backup -o -name '*.dolt' -o -name issues.jsonl -o -name 'beads*.jsonl' \) -print 2>>"$E" | sed 's#^\./##; s/^/BEAD /'
find . \( "${PR[@]}" \) -prune -o -type d -name .beads -print 2>>"$E" | while read -r d; do
  [ -n "$(find "$d" -type f ! -name '*.lock' -print 2>>"$E" | head -n 1)" ] && echo "BEAD ${d#./} (com conteúdo além de lock)"
done
[ -d .duckdb ] && { [ -z "$(find .duckdb -type f ! -name '*.duckdb_extension' ! -name '*.info' -print 2>>"$E" | head -n 1)" ] && echo "DUCKDB_EXT_ONLY 1"; }
ls -A1 . 2>>"$E" | while read -r d; do [ -d "$d" ] && echo "TOPDIR $d"; done
[ -d gt-remote ] && ls -A1 gt-remote 2>>"$E" | while read -r d; do [ -d "gt-remote/$d" ] && echo "GTDIR $d"; done
[ -s "$E" ] && echo "ERR leitura"
echo DONE
EOF
}

# ---------------------------------------------------------------------------------------------------------------------------------------------------------------
A=$("$SSH_BIN" "${SSH_OPTS[@]}" "$HOST" bash -s -- "${CRED_ALLOW[@]%%:*}" < <(remote_a) 2>/dev/null); a_rc=$?
case "$A" in *$'\nDONE'|DONE) a_done=1 ;; *) a_done=0 ;; esac    # só o script que chegou ao fim leu tudo; ssh que caiu no meio deixa a saída sem DONE
user=$(printf '%s\n' "$A" | sed -n 's/^HOST \([^@]*\)@.*/\1/p' | head -n 1); hostname=$(printf '%s\n' "$A" | sed -n 's/^HOST [^@]*@//p' | head -n 1)
lines() { printf '%s\n' "$A" | sed -n "s/^$1 //p"; }
cant_a="ssh a $HOST caiu ou o script remoto não terminou (rc=$a_rc): não li"
[ "$a_done" = 1 ] && [ -n "$user" ] || { a_done=0; }
err_for() { printf '%s\n' "$A" | grep -q "^ERR $1" ; }

# processo
if [ "$a_done" = 0 ]; then emit NAO-CONSEGUI processo "$cant_a"
elif err_for processo; then emit NAO-CONSEGUI processo "pgrep falhou ou não existe no servidor"
elif [ -n "$(lines PROC)" ]; then emit ACHADO processo "$(lines PROC | tr '\n' '|')"
else emit LIMPO processo "nenhum \`claude auth login\` em execução"; fi

# credenciais
if [ "$a_done" = 0 ]; then emit NAO-CONSEGUI credenciais "$cant_a"
else
  bad=""; allowed=" "; known=""
  for pair in "${CRED_ALLOW[@]}"; do allowed="$allowed${pair%%:*} "; done
  for h in $(lines CRED_HIT); do case "$allowed" in *" $h "*) ;; *) bad="$bad hit-fora-da-lista:$h" ;; esac; done
  for f in $(lines CRED_NAME); do bad="$bad loja-conhecida:$f"; done
  while read -r mode owner path; do
    [ -n "$path" ] || continue
    if [ "$mode" = 600 ] && [ "$owner" = "$user" ]; then known="$known $path"; else bad="$bad permissao:$path($mode,$owner)"; fi
  done < <(lines CRED_STAT)
  missing=$(lines CRED_MISSING | tr '\n' ' ')
  if [ -n "$bad" ]; then emit ACHADO credenciais "${bad# }"
  elif err_for stat || err_for leitura; then emit NAO-CONSEGUI credenciais "stat ou leitura de pasta falhou no servidor"
  else emit LIMPO credenciais "só as conhecidas, modo 600 e dono $user:${known}${missing:+ · ausentes (não é achado): $missing}"; fi
fi

# backup-de-bead
if [ "$a_done" = 0 ]; then emit NAO-CONSEGUI backup-de-bead "$cant_a"
elif [ -n "$(lines BEAD)" ]; then emit ACHADO backup-de-bead "$(lines BEAD | tr '\n' '|')"
elif err_for leitura; then emit NAO-CONSEGUI backup-de-bead "find falhou no servidor"
else emit LIMPO backup-de-bead "nenhum .dolt/.dolt-backup/issues.jsonl/beads*.jsonl e .beads só com lock"; fi

# github-e-espelho: o scan que o servidor já tem (rc 0 limpo · 1 violação · 2/3 não consegui varrer)
G=$("$SSH_BIN" "${SSH_OPTS[@]}" "$HOST" '"$HOME/gt-remote/bin/hetzner-remote-git.sh" scan' 2>/dev/null); g_rc=$?
case $g_rc in
  0) emit LIMPO github-e-espelho "$(printf '%s\n' "$G" | tail -n 2 | tr '\n' '|')" ;;
  1) emit ACHADO github-e-espelho "$(printf '%s\n' "$G" | grep 'VIOLA' | cut -c1-300 | tr '\n' '|')" ;;
  *) emit NAO-CONSEGUI github-e-espelho "scan saiu $g_rc (255 = ssh): $(printf '%s\n' "$G" | tail -n 1 | cut -c1-200)" ;;
esac

# dados: onde olhar sai da listagem do servidor; o QUE procurar é do node_audit
audit_dados() {
  [ "$a_done" = 1 ] || { emit NAO-CONSEGUI dados "$cant_a"; return; }
  local args=(--audit-node '.::maxdepth=1') n_dirs=1 d N n_rc states found ERRF
  for d in $(lines TOPDIR); do case "$SKIP_TOP" in *" $d "*) continue ;; esac
    case "$d" in .claude) args+=(--audit-node ".claude::prune=plugins:downloads:cache:security/agent-sdk-venv") ;; *) args+=(--audit-node "$d") ;; esac; n_dirs=$((n_dirs+1)); done
  for d in $(lines GTDIR); do case "$SKIP_GT" in *" $d "*) continue ;; esac; args+=(--audit-node "gt-remote/$d::$GT_PRUNE"); n_dirs=$((n_dirs+1)); done
  ERRF=$(mktemp) || { emit NAO-CONSEGUI dados "mktemp falhou no mini: não sei ler os achados"; return; }
  N=$("$MBP_RUN" --host linux "${args[@]}" 2>"$ERRF"); n_rc=$?
  states=$(printf '%s\n' "$N" | grep -c '^AUDIT-NODE ')
  # os achados saem no stderr do node_audit, sob o cabeçalho "(nó Linux:<pasta>)"; a linha de 2 espaços é "<TIPO> <caminho>" (só nome)
  found=$(awk '/ALARME: dado ou segredo no destino \(nó Linux:/ { d=$0; sub(/.*nó Linux:/, "", d); sub(/\).*/, "", d); next } /^  [A-Z]+ / { sub(/^  /, ""); print d ": " $0 }' "$ERRF"); rm -f "$ERRF"
  while read -r _ st dir; do   # pasta ACHADO sem nenhuma linha de detalhe legível: o achado não some por isso (antes da exceção do .duckdb, que só tira linha que EXPLICA)
    [ "$st" = ACHADO ] && ! printf '%s\n' "$found" | awk -v d="$dir: " 'index($0, d) == 1 { f = 1 } END { exit !f }' \
      && found="$found"$'\n'"$dir: (achado sem detalhe legível: veja o stderr do mbp-run.sh --audit-node)"
  done <<< "$N"
  found=$(printf '%s\n' "$found" | sed '/^$/d')
  if [ -n "$(lines DUCKDB_EXT_ONLY)" ]; then found=$(printf '%s\n' "$found" | grep -v -x '\.: NOME \.duckdb'); fi   # cache de extensões do DuckDB: só *.duckdb_extension/.info, conferido NESTA rodada
  if [ -n "$found" ]; then
    emit ACHADO dados "$(printf '%s\n' "$found" | grep -c .) achados em: $(printf '%s\n' "$found" | sed 's/: .*//' | sort -u | tr '\n' ' ')"
    printf '%s\n' "$found" | sed 's/^/AUDITORIA DETALHE dados: /'   # um por linha: lista longa não cabe numa só
  elif [ "$states" != "$n_dirs" ] || printf '%s\n' "$N" | grep -q '^AUDIT-NODE NAO-CONSEGUI'; then emit NAO-CONSEGUI dados "node_audit leu $states de $n_dirs pastas (rc=$n_rc)"
  else emit LIMPO dados "$n_dirs pastas pelo node_audit (topo do home com maxdepth=1 + cada diretório de topo e filho de gt-remote). NÃO auditados por dados: $SKIP_NOTE"; fi
}
audit_dados

if [ "$n_bad" -gt 0 ]; then res=ACHADO; rc=1; elif [ "$n_cant" -gt 0 ]; then res=NAO-CONSEGUI; rc=3; else res=LIMPO; rc=0; fi
printf 'AUDITORIA RESULTADO %s (achados=%s nao-consegui=%s limpos=%s) em %s %s\n' "$res" "$n_bad" "$n_cant" "$n_ok" "${hostname:-$HOST}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
exit $rc
