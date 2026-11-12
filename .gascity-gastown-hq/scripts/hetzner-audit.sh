#!/usr/bin/env bash
# hetzner-audit.sh — auditoria REPETÍVEL do que o servidor Hetzner guarda (ga-2hd02v.1.5.2, fatia 6b; travas e orçamento: ga-qg1dw5z.3). Roda no MINI e só LÊ o servidor por ssh (o único arquivo que cria lá é um `mktemp` que sai no `trap`).
#
# Contents
#   O que audita · Três estados · Orçamento e escopo · Saída e códigos · Como repetir · Limites
#
# O QUE AUDITA (cada verificação diz LIMPO | ACHADO | NAO-CONSEGUI):
#   processo          nenhum `claude auth login` esquecido (o de 15/10, pid 370419, ficou com a credencial já gravada).
#   credenciais       as ÚNICAS credenciais são as 3 de CRED_ALLOW (login do claude, atalho ssh→mini, chave do espelho git — a 3ª nasceu na fatia 4 e a bead só
#                     citava 2) e as contas do rodízio do claude de CRED_ALLOW_GLOB (~/.claude-accounts/<conta>/.credentials.json, uma por conta), todas com modo 600 e dono do usuário; qualquer outro arquivo com chave privada ou token (por CONTEÚDO, não por nome) ou loja
#                     de credencial conhecida (.netrc, .git-credentials, .aws...) é achado.
#   github-e-espelho  `hetzner-remote-git.sh scan` NO servidor (o que já existia: credencial do GitHub no host + dado negado no espelho git). Não é refeito aqui; o ACHADO mostra, por rig,
#                     historico · remotos_fora_do_espelho · arvore (a contagem do scan fica de fora). Os `.pyc` de worktree que a lista de negação do sparse-checkout pega são ruído do scan, não daqui.
#   dados             o node_audit da semeadura (mbp-run.sh --host linux --audit-node): NOME · GRANDE · JWT · CONTEÚDO (telefones/CPFs) no topo do home (só os arquivos soltos, maxdepth 1)
#                     e em cada diretório de topo e filho de gt-remote/ EXCETO os de SKIP_NOTE (a linha LIMPO diz o que ficou de fora). Os padrões do find vivem SÓ lá; aqui só se escolhe ONDE olhar
#                     e se separam os achados que são FERRAMENTA (DADOS_ACEITOS: só o (pasta, caminho, tipo) que a lista nomeia; CONTEUDO nunca; nunca numa lista cortada em 20).
#   backup-de-bead    .dolt só se for repositório (noms/ ou repo_state.json: a pasta do CLI em ~ não conta), .dolt-backup, issues.jsonl, beads*.jsonl, qualquer .jsonl dentro de um jsonl-archive/ (peças por dia, ga-e4cbc5s), e .beads com algo além de lock.
#   usuario-dados     (trava 1, ga-qg1dw5z.1) o usuário `dados` existe, o home dele é 0700 e dele, ele não está no grupo do runner nem o runner no dele, e o runner NÃO lê o home.
#   root-sem-login    (trava 2, ga-qg1dw5z.2) o sshd_config (com os Include) diz PermitRootLogin no: a 1ª ocorrência fora de Match vale; um Match que libere o root é achado.
#   ufw / fail2ban    (trava 2) ufw com ENABLED=yes no arquivo E a unidade ativa (o unit do ufw roda e sai: "active" sozinho não prova firewall); fail2ban instalado, ativo e com a jail sshd.
#                     Lê ARQUIVO e `systemctl is-active`, não o estado vivo: regras vivas do ufw e `fail2ban-client` exigem root, que este usuário não tem.
#
# TRÊS ESTADOS: achei / li tudo e não achei / não consegui ler (ssh caiu, comando ausente, pasta ilegível, saída que não reconheço, ORÇAMENTO que estourou). O último NUNCA vira LIMPO.
# ORÇAMENTO E ESCOPO (ga-qg1dw5z.3): em 11/11 esta auditoria estourou 280 s SEM saída no nó carregado (= "não sei"). Medido no nó: o script de credenciais, sozinho, não fechava em 280 s (um
#   grep de token em 390 mil arquivos dos worktrees do repo, 156 acertos de EXEMPLO), o node_audit de ~/.claude (7 GB de transcritos, 331 arquivos > 4 MB) passava de 250 s e o do espelho
#   levava 126 s; `nice`/`ionice` não mudam nada ali (o escalonador de IO é `none` e o lastro roda em SCHED_IDLE) e a leitura a frio é o que custa. Agora: (1) as fases rodam EM PARALELO
#   (listagem, credenciais, travas, scan do espelho e K grupos de pastas do node_audit, K = HETZNER_AUDIT_JOBS, padrão 4); (2) cada fase tem prazo — o do orçamento (HETZNER_AUDIT_BUDGET,
#   padrão 540 s) — imposto no nó por `timeout` e aqui por um corte que mata a árvore de processos: a fase que estoura vira NAO-CONSEGUI ("orçamento") e NÃO derruba as outras; (3) o escopo
#   deixa de fora o que é controlado por outro mecanismo ou não cabe num dia (SKIP_NOTE e CRED_NOTE dizem o quê, na própria linha LIMPO). A rodada SEMPRE termina com um RESULTADO.
# SAÍDA (stdout): uma linha `AUDITORIA <estado> <verificação>: <detalhe>` por verificação (+ `AUDITORIA DETALHE dados: ...` por achado), sem valor de segredo nem de dado (só caminho e contagem; URL usuário:senha@ e token conhecido saem mascarados, redact),
#   `AUDITORIA RESULTADO <estado> (...) em <host> <hora> duracao=Ns orcamento=Ns`. CÓDIGOS: 0 tudo limpo · 1 algum ACHADO (vale mesmo que outra verificação tenha caído) · 3 nenhum achado mas algo não foi lido · 2 uso.
# COMO REPETIR: bash scripts/hetzner-audit.sh   (HETZNER_NODE_HOST e MBP_SSH como no mbp-run.sh). Selftest: scripts/hetzner-audit.selftest.sh. Todo dia, com alarme: hetzner-audit-daily.sh.
# LIMITES: o que mora em .git/repo.git, venv*/env/site-packages/node_modules, ~/.cache, ~/.local/share/claude e tests/, fixtures/, *.selftest.*, test_* não é lido por CONTEÚDO
#   (compactado, de terceiros, ou token falso por desenho; o espelho git tem o `scan` próprio e a varredura de conteúdo por commit no mini). Transcritos e histórico de sessão (~/.claude/projects,
#   file-history, sessions; ~/.cc-safety-net/logs; o history.jsonl de prompts e o usage-analytics.jsonl, em ~/.claude, são GRANDE aceito) ficam FORA: se um agente vir dado pessoal ele aparece ali, mas a leitura
#   inteira não cabe num dia e o critério "arquivo > 4 MB = não li" os acusaria para sempre — o certo é uma janela deslizante com varredura em streaming (não feito). Chave sem cabeçalho PEM/OPENSSH e token de formato novo passam pela busca de conteúdo. Esta auditoria
#   olha ARQUIVOS do sshd/ufw/fail2ban, não o estado vivo deles.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SSH_BIN=${MBP_SSH:-ssh}; HOST=${HETZNER_NODE_HOST:-hetzner-teste}; MBP_RUN=${HETZNER_AUDIT_MBP_RUN:-$HERE/mbp-run.sh}
BUDGET=${HETZNER_AUDIT_BUDGET:-540}; JOBS=${HETZNER_AUDIT_JOBS:-4}
case "$BUDGET" in ''|*[!0-9]*) BUDGET=540 ;; esac; [ "$BUDGET" -ge 1 ] || BUDGET=540
case "$JOBS" in ''|*[!0-9]*) JOBS=4 ;; esac; [ "$JOBS" -ge 1 ] || JOBS=4
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
# caminhos relativos ao home do servidor : o que são. Fora desta lista, credencial é achado.
CRED_ALLOW=(".claude/.credentials.json:login do claude" ".ssh/mini_shim_ed25519:atalho ssh→mini" "gt-remote/keys/gt_mirror:chave do espelho git (fatia 4)")
# padrões (glob relativo ao home): o rodízio de contas do claude guarda um login por conta em ~/.claude-accounts/<conta>/.credentials.json (600, dono do usuário; criado em 20/10, medido no nó em 12/11); as contas entram e saem, então não há lista fixa
CRED_ALLOW_GLOB=(".claude-accounts/*/.credentials.json:login do claude de uma conta do rodízio")
SKIP_TOP=" .cache .local .duckdb .ssh .npm .cc-safety-net gt-remote "      # topo do home que NÃO é auditado por pasta: caches (o .duckdb tem verificação própria), .ssh (credenciais), .npm (cache de pacotes públicos), .cc-safety-net (logs de sessão) e gt-remote (por filho, abaixo)
SKIP_GT=" bin bundle bundle-out git keys mirror "     # filhos de gt-remote sem dado: ferramentas, bundle, espelho git e seus worktrees (varredura de conteúdo por commit no mini + `scan`), chaves (credenciais); venv-* é pulado no laço do audit_dados
GT_PRUNE="prune=venv:env:.git:__pycache__"
CLAUDE_PRUNE="prune=plugins:downloads:cache:security/agent-sdk-venv:projects:file-history:sessions"      # transcritos (7 GB, 331 arquivos > 4 MB), histórico de sessão e o registro de sessão (sessions/<pid>.<hash>.key: 142 bytes de JSON com ids, um por sessão viva, nome terminado em .key): ver LIMITES
SKIP_NOTE=".cache .local .duckdb .ssh .npm .cc-safety-net (topo), .claude/{projects,file-history,sessions} e gt-remote/{bin,bundle,bundle-out,git,keys,mirror,venv-*}"   # o que SKIP_TOP/SKIP_GT/CLAUDE_PRUNE deixam de fora: a linha LIMPO do dados o repete, para o "limpo" não parecer maior do que é
CRED_NOTE="a busca por CONTEÚDO não olha (PR e PT do remote_cred): .cache, .local/share/claude, .duckdb, .claude/{projects,file-history,plugins,downloads,security}, gt-remote/{git,mirror,*/env}, venv*, node_modules, site-packages, .git, repo.git, __pycache__, tests/, fixtures/, *.selftest.*, test_*"
# achados do node_audit que são FERRAMENTA e não dado: pasta|glob relativo à pasta|tipos|por quê. Só o tipo que a linha lista; CONTEUDO nunca (lista de telefones/CPFs é dado); o JWT só num caminho exato de arquivo
# que a própria ferramenta assina. Cada linha foi conferida no nó em 12/11 (forma e tamanho, sem ler valor).
DADOS_ACEITOS=(
  ".config|go/telemetry/local/upload.token|NOME|token de amostragem da telemetria do toolchain Go (arquivo de 0 bytes)"
  ".pki|nssdb/cert9.db|NOME|banco de certificados NSS que o Chromium cria sozinho (SQLite de 28 KB)"
  ".pki|nssdb/key4.db|NOME|idem, chaves do perfil NSS (SQLite de 36 KB, sem certificado de cliente)"
  "hqgc|bin/dolt|GRANDE|o binário do Dolt (ELF de 119 MB): programa, não dado"
  ".whatsapp-automation|logs/*.log|NOME|logs de teste do WA no nó: o conteúdo é lido pelo JWT e pelo scanner de telefones/CPFs na mesma rodada"
  ".gastown|logs/*.log|NOME|logs das ferramentas da cidade no nó: idem"
  "gt-remote/tools|*.gz|NOME|man e tarballs das ferramentas compiladas no nó (byacc, bash 3.2.57)"
  "gt-remote/ballast|wa-mutants.state.json|GRANDE|estado do motor de lastro (JSON de mutantes, 7 MB)"
  ".claude|history.jsonl|GRANDE|histórico de prompts do claude (187 MB, 2391 registros em 12/11): mesma classe dos transcritos fora do escopo, a leitura por conteúdo não cabe num dia (ver LIMITES)"
  ".claude|usage-analytics.jsonl|GRANDE|telemetria de uso escrita pelo hook log-token-usage.sh (16 MB de linhas de contagem)"
  ".claude|policy-limits.json.signature.json|JWT|JWS que o próprio claude assina e guarda (typ cc-signed-cache+jws, certificados públicos em x5c, claims de política): não é credencial de portador"
)
n_bad=0; n_cant=0; n_ok=0
# O relatório vira arquivo e, pelo wrapper diário, um push EXTERNO (ntfy). O scan do espelho imprime os remotos do git CRUS (`remotos_fora_do_espelho=[https://usuario:token@...]`) e o pgrep imprime a linha de comando:
# usuário:senha@ de URL e token conhecido saem mascarados aqui, em toda linha de veredito (a cópia do wrapper, hetzner-audit-daily.sh, mascara o corpo do push de novo).
redact() { sed -E -e 's#(://)[^/[:space:]]*@#\1***@#g' -e 's#(sk-ant-|gh[pousr]_|github_pat_|xox[abprs]-)[A-Za-z0-9_-]{8,}#\1***#g' -e 's#AKIA[0-9A-Z]{16}#AKIA***#g' -e 's#-----BEGIN [A-Z ]*PRIVATE KEY-----#***#g' -e 's#eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}[A-Za-z0-9_.-]*#***#g'; }
emit() { # estado verificação detalhe
  case "$1" in ACHADO) n_bad=$((n_bad+1)) ;; NAO-CONSEGUI) n_cant=$((n_cant+1)) ;; *) n_ok=$((n_ok+1)) ;; esac
  printf 'AUDITORIA %s %s: %s\n' "$1" "$2" "$3" | redact
}

# ---------------------------------------------------------------------------------------------------------------------------------------------------------------
# Orçamento: cada fase roda em 2º plano com um corte que mata a ÁRVORE (o ssh e o que ele abriu) quando o prazo acaba; o rc 124 é "estourou".
kill_tree() { # kill_tree <pid> [sinal]
  local c; for c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$c" "${2:-TERM}"; done
  kill -"${2:-TERM}" "$1" 2>/dev/null
}
run_bounded() { # run_bounded <prazo s> <saída> <erro> <arquivo do rc> comando...   (o rc 124 fica no arquivo se o prazo acabou)
  local lim=$1 o=$2 e=$3 rf=$4 p rc; shift 4
  rm -f "$rf.timeout"
  "$@" > "$o" 2> "$e" & p=$!
  # o corte confere a cada segundo se o trabalho ainda vive: sem um filho `sleep <prazo>` que nasça órfão (e dure 538 s) quando o trabalho acaba em milissegundos; no prazo marca, TERM na árvore, KILL 2 s depois
  ( t=0; while kill -0 "$p" 2>/dev/null; do
      if [ "$t" -ge "$lim" ]; then : > "$rf.timeout"; kill_tree "$p" TERM; sleep 2; kill_tree "$p" KILL; break; fi
      sleep 1; t=$((t+1))
    done ) > /dev/null 2>&1 &
  wait "$p"; rc=$?
  if [ -e "$rf.timeout" ]; then echo 124 > "$rf"; else echo "$rc" > "$rf"; fi
}
T0=$SECONDS
left() { echo $(( BUDGET - (SECONDS - T0) - 2 )); }      # 2 s de folga para montar o relatório
lim_of() { local l; l=$(left); [ "$l" -ge 1 ] || l=1; if [ "$1" -lt "$l" ]; then echo "$1"; else echo "$l"; fi; }   # lim_of <teto>: o menor entre o teto e o que sobra
W=$(mktemp -d "${TMPDIR:-/tmp}/hzaudit.XXXXXX") || { echo "AUDITORIA: não consegui criar a pasta de trabalho" >&2; exit 2; }
trap 'rm -rf "$W"' EXIT
ssh_script() { # ssh_script <arquivo do script> <prazo no nó> <fase> [args...]: o bash remoto lê o script do arquivo e o `timeout` do nó o mata no prazo
  local f=$1 tmo=$2; shift 2
  "$SSH_BIN" "${SSH_OPTS[@]}" "$HOST" timeout "$tmo" bash -s -- "$@" < "$f"
}
start() { # start <nome> <prazo> comando...   (em 2º plano: $W/<nome>.out .err .rc)
  local nome=$1 lim=$2; shift 2
  run_bounded "$lim" "$W/$nome.out" "$W/$nome.err" "$W/$nome.rc" "$@" &
}
rc_of() { cat "$W/$1.rc" 2>/dev/null || echo 125; }
cant_of() { # cant_of <nome> <o que não li>: o texto de NAO-CONSEGUI para uma fase que não terminou
  if [ "$(rc_of "$1")" = 124 ]; then echo "estourou o orçamento de ${BUDGET}s (carga do nó? leitura a frio?): não li $2"
  else echo "ssh a $HOST caiu ou o script remoto não terminou (rc=$(rc_of "$1")): não li $2"; fi
}

# O script remoto só LÊ. Poda: caches e código de terceiros (ver LIMITES). `[c]laude` não casa com a própria linha de comando.
remote_lista() { cat <<'EOF'
set -u -f
cd "$HOME" || { echo "ERR home"; exit 3; }
E=$(mktemp) || { echo "ERR mktemp"; exit 3; }; trap 'rm -f "$E"' EXIT
echo "HOST $(id -un)@$(hostname)"
ls -A1 . 2>>"$E" | while read -r d; do [ -d "$d" ] && echo "TOPDIR $d"; done
[ -d gt-remote ] && ls -A1 gt-remote 2>>"$E" | while read -r d; do [ -d "gt-remote/$d" ] && echo "GTDIR $d"; done
[ -s "$E" ] && echo "ERR leitura"
echo DONE
EOF
}
remote_cred() { cat <<'EOF'
set -u -f
[ "${1:-}" = cred ] && shift
cd "$HOME" || { echo "ERR home"; exit 3; }
E=$(mktemp) || { echo "ERR mktemp"; exit 3; }; trap 'rm -f "$E"' EXIT
echo "HOST $(id -un)@$(hostname)"
PR=(-path ./.cache -o -path ./.local/share/claude -o -path ./.duckdb -o -path ./.claude/plugins -o -path ./.claude/downloads -o -path ./.claude/projects -o -path ./.claude/file-history -o -path ./.claude/security -o -path ./gt-remote/git -o -path ./gt-remote/mirror -o -name node_modules -o -name site-packages -o -name 'venv*' -o -name .venv -o -path './gt-remote/*/env' -o -name .git -o -name repo.git -o -name __pycache__)
P=$(pgrep -af '[c]laude.* auth login' 2>>"$E"); rc=$?
case $rc in 0) printf '%s\n' "$P" | cut -c1-100 | sed 's/^/PROC /' ;; 1) ;; *) echo "ERR processo" ;; esac
PT=(-path '*/tests/*' -o -path '*/fixtures/*' -o -name '*.selftest.*' -o -name 'test_*')   # token falso de teste, por desenho (medido: 10 de 10 achados da 1ª rodada eram isso)
# vazio → nenhuma linha CRED_HIT; falhou/ilegível → stderr do find/grep em $E e o ERR leitura abaixo (nunca "limpo")
find . \( "${PR[@]}" -o "${PT[@]}" \) -prune -o -type f -size -2049k -exec grep -lIE -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' -e 'sk-ant-[A-Za-z0-9_-]{20,}' -e 'gh[pousr]_[A-Za-z0-9]{30,}' \
  -e 'github_pat_[A-Za-z0-9_]{30,}' -e 'xox[abprs]-[A-Za-z0-9-]{10,}' -e 'AKIA[0-9A-Z]{16}' {} + 2>>"$E" | sed 's#^\./##; s/^/CRED_HIT /'
for f in "$@"; do
  case "$f" in
    # glob: vazio (padrão sem nenhum arquivo) → "nenhuma conta", sem linha CRED_MISSING nem achado; falhou (stat) → ERR stat, que o avaliador lê como NAO-CONSEGUI; cada arquivo que casa é conferido (modo e dono) como os fixos
    glob:*) set +f; for g in ${f#glob:}; do [ -e "$g" ] || continue; m=$(stat -c '%a %U' "$g" 2>>"$E") && echo "CRED_STAT $m $g" || echo "ERR stat $g"; done; set -f ;;
    *) if [ -e "$f" ]; then m=$(stat -c '%a %U' "$f" 2>>"$E") && echo "CRED_STAT $m $f" || echo "ERR stat $f"; else echo "CRED_MISSING $f"; fi ;;
  esac
done
for f in .netrc .pgpass .npmrc .git-credentials .config/git/credentials .config/gh .aws .docker/config.json .config/gcloud .kube .gnupg .config/rclone .ssh/id_rsa .ssh/id_ed25519 .ssh/id_ecdsa .ssh/id_dsa; do
  [ -e "$f" ] && echo "CRED_NAME $f"
done
find . \( "${PR[@]}" \) -prune -o \( -name .dolt-backup -o -name dolt-backup -o -name '?*.dolt' -o -name issues.jsonl -o -name 'beads*.jsonl' -o \( -name '*.jsonl' -path '*/jsonl-archive/*' \) \) -print 2>>"$E" | sed 's#^\./##; s/^/BEAD /'
find . \( "${PR[@]}" \) -prune -o -type d -name .beads -print 2>>"$E" | while read -r d; do
  [ -n "$(find "$d" -type f ! -name '*.lock' -print 2>>"$E" | head -n 1)" ] && echo "BEAD ${d#./} (com conteúdo além de lock)"
done
# .dolt só é banco de bead se tem o repositório (noms/ ou repo_state.json); a pasta que o CLI do dolt cria em ~ (config_global.json, version_check.txt, eventsData/) não é (medido no nó em 12/11: 24 KB)
# vazio (sem .dolt, ou só config) → nenhuma linha BEAD; falhou (pasta que não abro: não sei se é repositório) → ERR leitura, nunca "só config"
find . \( "${PR[@]}" \) -prune -o -type d -name .dolt -print 2>>"$E" | while read -r d; do
  if [ ! -r "$d" ] || [ ! -x "$d" ]; then echo "ERR leitura"; elif [ -e "$d/noms" ] || [ -e "$d/repo_state.json" ]; then echo "BEAD ${d#./} (repositório Dolt: noms/ ou repo_state.json)"; fi
done
[ -d .duckdb ] && { [ -z "$(find .duckdb -type f ! -name '*.duckdb_extension' ! -name '*.info' -print 2>>"$E" | head -n 1)" ] && echo "DUCKDB_EXT_ONLY 1"; }
[ -s "$E" ] && echo "ERR leitura"
echo DONE
EOF
}
# travas 1 e 2: só LÊ arquivos do /etc e roda id/getent/stat/systemctl/dpkg-query (nada exige root). HZ_ETC troca o /etc: só o selftest o faz (no servidor a variável não existe).
remote_travas() { cat <<'EOF'
set -u -f
export LC_ALL=C
ETC=${HZ_ETC:-/etc}
E=$(mktemp) || { echo "ERR mktemp"; exit 3; }; trap 'rm -f "$E" "$E.x"' EXIT
# vazio (getent rc 2 = não há o usuário) → "absent" (a trava não está aplicada); falhou (qualquer outro rc) → "error": nunca "absent"
PW=$(getent passwd dados 2>>"$E"); rc=$?
if [ $rc = 2 ]; then echo "T_DADOS_USER absent"
elif [ $rc != 0 ]; then echo "T_DADOS_USER error"
else
  echo "T_DADOS_USER present"
  H=$(printf '%s\n' "$PW" | cut -d: -f6)
  if [ -d "$H" ]; then
    M=$(stat -c '%a %U %G' "$H" 2>>"$E") && echo "T_DADOS_HOME $M" || echo "T_DADOS_HOME error"
    # o runner lê o home do dados? "Permission denied" é o esperado; qualquer outro erro é "não sei"
    if ls -A "$H" >/dev/null 2>"$E.x"; then echo "T_DADOS_LS yes"; elif grep -q 'Permission denied' "$E.x"; then echo "T_DADOS_LS no"; else echo "T_DADOS_LS error"; fi
  elif [ -e "$H" ]; then echo "T_DADOS_HOME error"
  else echo "T_DADOS_HOME missing"; fi
  G=$(id -nG dados 2>>"$E") && echo "T_DADOS_GROUPS $G" || echo "T_DADOS_GROUPS error"
fi
R=$(id -nG 2>>"$E") && echo "T_RUNNER_GROUPS $R" || echo "T_RUNNER_GROUPS error"
# PermitRootLogin: a 1ª ocorrência FORA de Match vale (OpenSSH: o 1º valor obtido); o Include entra na posição dele; um Match que diga outra coisa que no é achado
ROOTV=""; SSHD_ERR=0
sshd_scan() { # sshd_scan <arquivo> <profundidade> <já dentro de Match: 0|1>
  local f=$1 d=$2 inm=$3 line k v pat g
  [ "$d" -le 5 ] || { SSHD_ERR=1; return; }
  [ -r "$f" ] || { SSHD_ERR=1; return; }
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}; line=${line//=/ }
    set -- $line
    [ $# -ge 1 ] || continue
    k=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    case "$k" in
      include) shift
        for pat in "$@"; do
          case "$pat" in /etc/*) pat="$ETC/${pat#/etc/}" ;; /*) ;; *) pat="$ETC/ssh/$pat" ;; esac
          set +f; for g in $pat; do [ -e "$g" ] && sshd_scan "$g" $((d+1)) "$inm"; done; set -f
        done ;;
      match) inm=1 ;;
      permitrootlogin) v=$(printf '%s' "${2:-}" | tr 'A-Z' 'a-z'); if [ "$inm" = 1 ]; then echo "T_SSHD_MATCH $v"; else [ -n "$ROOTV" ] || ROOTV=$v; fi ;;
    esac
  done < "$f"
}
if [ -e "$ETC/ssh/sshd_config" ]; then sshd_scan "$ETC/ssh/sshd_config" 0 0 2>>"$E"; [ "$SSHD_ERR" = 0 ] && echo "T_SSHD_ROOT ${ROOTV:-none}" || echo "T_SSHD_ROOT error"
else echo "T_SSHD_ROOT error"; fi
svc() { # svc <unidade>: active | inactive | error (o texto do systemctl; qualquer outra coisa, ou systemctl que falha, é "error")
  local o; o=$(systemctl is-active "$1" 2>>"$E")
  case "$o" in active) echo active ;; inactive|failed|activating|deactivating|unknown) echo inactive ;; *) echo error ;; esac
}
# ufw: ENABLED no arquivo (o unit roda e sai: "active" sozinho não prova firewall)
UC="$ETC/ufw/ufw.conf"
if [ ! -e "$UC" ]; then echo "T_UFW_ENABLED missing"
elif [ ! -r "$UC" ]; then echo "T_UFW_ENABLED error"
else v=$(sed -n 's/^[[:space:]]*ENABLED=//p' "$UC" 2>>"$E" | tail -n 1 | tr -d "\"' " | tr 'A-Z' 'a-z'); echo "T_UFW_ENABLED ${v:-unset}"; fi
echo "T_UFW_ACTIVE $(svc ufw)"
# fail2ban: pacote, unidade, e a jail sshd na ordem de leitura do fail2ban (jail.conf, jail.d/*.conf, jail.local, jail.d/*.local: o último valor vale)
P=$(dpkg-query -W -f='${db:Status-Abbrev}\n' fail2ban 2>"$E.x"); rc=$?
if [ $rc = 0 ]; then case "$P" in ii*) echo "T_F2B_PKG yes" ;; *) echo "T_F2B_PKG no" ;; esac
elif grep -q 'no packages found' "$E.x"; then echo "T_F2B_PKG no"
else echo "T_F2B_PKG error"; fi
echo "T_F2B_ACTIVE $(svc fail2ban)"
JE=unset; JERR=0
set +f
for f in "$ETC/fail2ban/jail.conf" "$ETC"/fail2ban/jail.d/*.conf "$ETC/fail2ban/jail.local" "$ETC"/fail2ban/jail.d/*.local; do
  [ -e "$f" ] || continue
  [ -r "$f" ] || { JERR=1; continue; }
  v=$(awk '/^[[:space:]]*\[/ { s=$0; gsub(/[][[:space:]]/, "", s); insshd = (s == "sshd"); next } insshd && /^[[:space:]]*enabled[[:space:]]*=/ { x=$0; sub(/^[^=]*=[[:space:]]*/, "", x); sub(/[[:space:]]*[;#].*$/, "", x); print tolower(x) }' "$f" 2>>"$E" | tail -n 1)
  [ -n "$v" ] && JE=$v
done
set -f
[ "$JERR" = 1 ] && echo "T_F2B_JAIL error" || echo "T_F2B_JAIL $JE"
[ -s "$E" ] && echo "T_ERR leitura"
echo T_DONE
EOF
}

# ---------------------------------------------------------------------------------------------------------------------------------------------------------------
# 1) as fases rápidas e as pesadas começam JUNTAS (a listagem é o que o node_audit espera, então fica no caminho crítico: prazo curto)
remote_lista > "$W/lista.sh"; remote_cred > "$W/cred.sh"; remote_travas > "$W/travas.sh"
start lista "$(lim_of 60)" ssh_script "$W/lista.sh" "$(lim_of 60)" lista; p_lista=$!
cred_args=("${CRED_ALLOW[@]%%:*}"); for p in "${CRED_ALLOW_GLOB[@]}"; do cred_args+=("glob:${p%%:*}"); done
start cred "$(lim_of "$BUDGET")" ssh_script "$W/cred.sh" "$(lim_of "$BUDGET")" cred "${cred_args[@]}"
start travas "$(lim_of 120)" ssh_script "$W/travas.sh" "$(lim_of 120)" travas
start git "$(lim_of "$BUDGET")" "$SSH_BIN" "${SSH_OPTS[@]}" "$HOST" "timeout $(lim_of "$BUDGET") \"\$HOME/gt-remote/bin/hetzner-remote-git.sh\" scan"
wait "$p_lista"

# 2) com a listagem, as pastas do node_audit vão a K grupos (rodízio), cada um uma invocação do mbp-run; o ssh que o mbp-run usa ganha o `timeout` do nó
L=$(cat "$W/lista.out" 2>/dev/null)
case "$L" in *$'\nDONE'|DONE) l_done=1 ;; *) l_done=0 ;; esac
lines_of() { printf '%s\n' "$1" | sed -n "s/^$2 //p"; }
n_dirs=0; njobs=$JOBS
if [ "$l_done" = 1 ]; then
  { echo ".::maxdepth=1"
    for d in $(lines_of "$L" TOPDIR); do case "$SKIP_TOP" in *" $d "*) continue ;; esac
      case "$d" in .claude) echo ".claude::$CLAUDE_PRUNE" ;; *) echo "$d" ;; esac; done
    for d in $(lines_of "$L" GTDIR); do case "$SKIP_GT" in *" $d "*) continue ;; esac; case "$d" in venv-*) continue ;; esac; echo "gt-remote/$d::$GT_PRUNE"; done
  } > "$W/specs"
  n_dirs=$(grep -c . "$W/specs"); [ "$njobs" -le "$n_dirs" ] || njobs=$n_dirs
  g=0; while [ "$g" -lt "$njobs" ]; do : > "$W/g$g.specs"; g=$((g+1)); done
  i=0; while IFS= read -r s; do printf '%s\n' "$s" >> "$W/g$((i % njobs)).specs"; i=$((i+1)); done < "$W/specs"
  cat > "$W/ssh-node" <<EOF
#!/bin/bash
# o mbp-run monta "ssh <opções> <host> bash -s -- ...": aqui entra o limite de tempo NO NÓ (o remoto se mata no prazo, não fica órfão se este lado for cortado)
args=(); while [ \$# -gt 0 ]; do [ "\$1" = bash ] && break; args+=("\$1"); shift; done
exec "$SSH_BIN" "\${args[@]}" timeout "$(lim_of "$BUDGET")" "\$@"
EOF
  chmod +x "$W/ssh-node"
  run_group() { # run_group <arquivo de pastas>: uma invocação do mbp-run com uma pasta por linha
    local a=() s
    while IFS= read -r s; do a+=(--audit-node "$s"); done < "$1"
    env MBP_SSH="$W/ssh-node" "$MBP_RUN" --host linux "${a[@]}"
  }
  g=0; while [ "$g" -lt "$njobs" ]; do start "g$g" "$(lim_of "$BUDGET")" run_group "$W/g$g.specs"; g=$((g+1)); done
fi
wait

# ---------------------------------------------------------------------------------------------------------------------------------------------------------------
# 3) avaliar: cada verificação sai de saídas já prontas
A=$(cat "$W/cred.out" 2>/dev/null)
case "$A" in *$'\nDONE'|DONE) a_done=1 ;; *) a_done=0 ;; esac    # só o script que chegou ao fim leu tudo; ssh que caiu no meio deixa a saída sem DONE
user=$(printf '%s\n' "$A" | sed -n 's/^HOST \([^@]*\)@.*/\1/p' | head -n 1); hostname=$(printf '%s\n' "$A" | sed -n 's/^HOST [^@]*@//p' | head -n 1)
lines() { printf '%s\n' "$A" | sed -n "s/^$1 //p"; }
cant_a=$(cant_of cred "")
[ "$a_done" = 1 ] && [ -n "$user" ] || { a_done=0; }
err_for() { printf '%s\n' "$A" | grep -q "^ERR $1" ; }

# processo
if [ "$a_done" = 0 ]; then emit NAO-CONSEGUI processo "$(cant_of cred "o processo")"
elif err_for processo; then emit NAO-CONSEGUI processo "pgrep falhou ou não existe no servidor"
elif [ -n "$(lines PROC)" ]; then emit ACHADO processo "$(lines PROC | tr '\n' '|')"
else emit LIMPO processo "nenhum \`claude auth login\` em execução"; fi

# credenciais
if [ "$a_done" = 0 ]; then emit NAO-CONSEGUI credenciais "$(cant_of cred "as credenciais")"
else
  bad=""; allowed=" "; known=""; statted=" $(lines CRED_STAT | awk '{print $3}' | tr '\n' ' ')"
  for pair in "${CRED_ALLOW[@]}"; do allowed="$allowed${pair%%:*} "; done
  for h in $(lines CRED_HIT); do
    ok=0; case "$allowed" in *" $h "*) ok=1 ;; esac
    # glob: só vale o arquivo que o servidor expandiu e conferiu (CRED_STAT): o `*` de um `case` atravessa "/", o do servidor não (…/a1/sub/.credentials.json casaria aqui sem nunca ter o modo e o dono vistos)
    for gp in "${CRED_ALLOW_GLOB[@]}"; do case "$h" in ${gp%%:*}) case "$statted" in *" $h "*) ok=1 ;; esac ;; esac; done
    [ "$ok" = 1 ] || bad="$bad hit-fora-da-lista:$h"
  done
  for f in $(lines CRED_NAME); do bad="$bad loja-conhecida:$f"; done
  while read -r mode owner path; do
    [ -n "$path" ] || continue
    if [ "$mode" = 600 ] && [ "$owner" = "$user" ]; then known="$known $path"; else bad="$bad permissao:$path($mode,$owner)"; fi
  done < <(lines CRED_STAT)
  missing=$(lines CRED_MISSING | tr '\n' ' ')
  if [ -n "$bad" ]; then emit ACHADO credenciais "${bad# }"
  elif err_for stat || err_for leitura; then emit NAO-CONSEGUI credenciais "stat ou leitura de pasta falhou no servidor"
  else emit LIMPO credenciais "só as conhecidas, modo 600 e dono $user:${known}${missing:+ · ausentes (não é achado): $missing} · $CRED_NOTE"; fi
fi

# backup-de-bead
if [ "$a_done" = 0 ]; then emit NAO-CONSEGUI backup-de-bead "$(cant_of cred "os backups de bead")"
elif [ -n "$(lines BEAD)" ]; then emit ACHADO backup-de-bead "$(lines BEAD | tr '\n' '|')"
elif err_for leitura; then emit NAO-CONSEGUI backup-de-bead "find falhou no servidor"
else emit LIMPO backup-de-bead "nenhum .dolt/.dolt-backup/issues.jsonl/beads*.jsonl e .beads só com lock"; fi

# github-e-espelho: o scan que o servidor já tem (rc 0 limpo · 1 violação · 2/3 não consegui varrer)
# A linha de VIOLAÇÃO do scan traz a contagem na frente e as listas (no máximo 5 entradas cada) atrás, na ordem historico · arvore · remotos_fora_do_espelho: um corte cego em 300 colunas deixava os remotos do git (o campo de
# maior risco) sempre de fora. Aqui sai "<rig>: historico=[…] remotos_fora_do_espelho=[…] arvore=[…]" (a árvore, que é a que mais ruído leva, por último); a linha de outra forma (a das credenciais do host) passa como está.
scan_line() { awk 'function fld(s, k,   i, r) { i = index(s, k "=["); if (!i) return ""; r = substr(s, i); return substr(r, 1, index(r, "]")) }
  { h = fld($0, "historico"); if (h == "") { print; next }; print substr($0, 1, index($0, ": ") - 1) ": " h " " fld($0, "remotos_fora_do_espelho") " " fld($0, "arvore") }'; }
G=$(cat "$W/git.out" 2>/dev/null); g_rc=$(rc_of git)
case $g_rc in
  0) emit LIMPO github-e-espelho "$(printf '%s\n' "$G" | tail -n 2 | tr '\n' '|')" ;;
  1) emit ACHADO github-e-espelho "$(printf '%s\n' "$G" | grep 'VIOLA' | scan_line | cut -c1-400 | tr '\n' '|')" ;;
  124) emit NAO-CONSEGUI github-e-espelho "estourou o orçamento de ${BUDGET}s: não varri" ;;
  *) emit NAO-CONSEGUI github-e-espelho "scan saiu $g_rc (255 = ssh): $(printf '%s\n' "$G" | tail -n 1 | cut -c1-200)" ;;
esac

# aceito <pasta> <tipo> <caminho>: 0 se uma linha de DADOS_ACEITOS cobre o achado (pasta, caminho E tipo); CONTEUDO nunca é aceito
aceito() {
  local e d g t
  [ "$2" != CONTEUDO ] || return 1
  for e in "${DADOS_ACEITOS[@]}"; do
    IFS='|' read -r d g t _ <<< "$e"
    [ "$d" = "$1" ] || continue
    case "$t" in *"$2"*) ;; *) continue ;; esac
    case "$3" in $g) return 0 ;; esac
  done
  return 1
}
# dados: onde olhar sai da listagem do servidor; o QUE procurar é do node_audit
eval_dados() {
  [ "$l_done" = 1 ] || { emit NAO-CONSEGUI dados "$(cant_of lista "as pastas a auditar")"; return; }
  local N="" ERRF_TXT="" g=0 n_rc=0 r states found kept cut_keys acc=0 cortadas="" ln dir rest typ path late="" d have
  while [ "$g" -lt "$njobs" ]; do
    N="$N$(cat "$W/g$g.out" 2>/dev/null)"$'\n'; ERRF_TXT="$ERRF_TXT$(cat "$W/g$g.err" 2>/dev/null)"$'\n'
    r=$(rc_of "g$g"); [ "$r" = 124 ] && late="$late g$g"; [ "$r" -le "$n_rc" ] 2>/dev/null || n_rc=$r
    g=$((g+1))
  done
  N=$(printf '%s' "$N" | sed '/^$/d')
  states=$(printf '%s\n' "$N" | grep -c '^AUDIT-NODE ')
  # os achados saem no stderr do node_audit, sob o cabeçalho "(nó Linux:<pasta>)"; a linha de 2 espaços é "<TIPO> <caminho>" (só nome)
  found=$(printf '%s\n' "$ERRF_TXT" | awk '/ALARME: dado ou segredo no destino \(nó Linux:/ { d=$0; sub(/.*nó Linux:/, "", d); sub(/\).*/, "", d); next } /^  [A-Z]+ / { sub(/^  /, ""); print d ": " $0 }')
  while read -r _ st dir; do   # pasta ACHADO sem nenhuma linha de detalhe legível: o achado não some por isso (antes da exceção do .duckdb, que só tira linha que EXPLICA)
    [ "$st" = ACHADO ] && ! printf '%s\n' "$found" | awk -v d="$dir: " 'index($0, d) == 1 { f = 1 } END { exit !f }' \
      && found="$found"$'\n'"$dir: (achado sem detalhe legível: veja o stderr do mbp-run.sh --audit-node)"
  done <<< "$N"
  found=$(printf '%s\n' "$found" | sed '/^$/d')
  if [ -n "$(lines DUCKDB_EXT_ONLY)" ]; then found=$(printf '%s\n' "$found" | grep -v -x '\.: NOME \.duckdb'); fi   # cache de extensões do DuckDB: só *.duckdb_extension/.info, conferido NESTA rodada
  # lista de aceitos: o node_audit mostra no máximo 20 linhas por tipo; (pasta, tipo) com 20 pode ter mais atrás, e o que está atrás pode ser o achado de verdade: nada dessa pasta é aceito
  cut_keys=$(printf '%s\n' "$found" | sed -n 's/^\([^:]*\): \([A-Z]*\) .*/\1|\2/p' | sort | uniq -c | awk '$1 >= 20 {print $2}')
  kept=""
  while IFS= read -r ln; do
    [ -n "$ln" ] || continue
    dir=${ln%%: *}; rest=${ln#*: }; typ=${rest%% *}; path=${rest#* }
    if printf '%s\n' "$cut_keys" | grep -qxF "$dir|$typ"; then
      case "$cortadas" in *" $dir "*) ;; *) cortadas="$cortadas $dir " ;; esac
    elif aceito "$dir" "$typ" "$path"; then acc=$((acc+1)); continue; fi
    kept="$kept$ln"$'\n'
  done <<< "$found"
  found=$(printf '%s\n' "$kept" | sed '/^$/d')
  if [ -n "$found" ]; then
    emit ACHADO dados "$(printf '%s\n' "$found" | grep -c .) achados em: $(printf '%s\n' "$found" | sed 's/: .*//' | sort -u | tr '\n' ' ')${cortadas:+· lista cortada em 20 por tipo (nada aceito em:$cortadas)}${acc:+ · aceitos: $acc}"
    printf '%s\n' "$found" | sed 's/^/AUDITORIA DETALHE dados: /'   # um por linha: lista longa não cabe numa só
  elif [ "$states" != "$n_dirs" ] || printf '%s\n' "$N" | grep -q '^AUDIT-NODE NAO-CONSEGUI'; then
    have=" $(printf '%s\n' "$N" | sed -n 's/^AUDIT-NODE [A-Z-]* //p' | tr '\n' ' ')"; d=""
    while IFS= read -r s; do case "$have" in *" ${s%%::*} "*) ;; *) d="$d ${s%%::*}" ;; esac; done < "$W/specs"
    emit NAO-CONSEGUI dados "node_audit leu $states de $n_dirs pastas (rc=$n_rc)${late:+ · estourou o orçamento de ${BUDGET}s nos grupos:$late}${d:+ · sem veredito:${d:0:200}}"
  else emit LIMPO dados "$n_dirs pastas pelo node_audit (topo do home com maxdepth=1 + cada diretório de topo e filho de gt-remote), em $njobs grupos${acc:+ · aceitos: $acc (ferramenta conhecida, DADOS_ACEITOS)}. NÃO auditados por dados: $SKIP_NOTE"; fi
}
eval_dados

# travas 1 e 2
T=$(cat "$W/travas.out" 2>/dev/null)
case "$T" in *$'\nT_DONE'|T_DONE) t_done=1 ;; *) t_done=0 ;; esac
tl() { printf '%s\n' "$T" | sed -n "s/^$1 //p" | head -n 1; }
cant_t=$(cant_of travas "")
if [ "$t_done" = 0 ]; then
  for c in usuario-dados root-sem-login ufw fail2ban; do emit NAO-CONSEGUI "$c" "$(cant_of travas "esta trava")"; done
else
  # usuario-dados (trava 1)
  du=$(tl T_DADOS_USER); dh=$(tl T_DADOS_HOME); dl=$(tl T_DADOS_LS); dg=$(tl T_DADOS_GROUPS); rg=$(tl T_RUNNER_GROUPS)
  if [ "$du" = absent ]; then emit ACHADO usuario-dados "o usuário 'dados' não existe (trava 1 não aplicada: o dado pessoal ainda não tem usuário próprio)"
  elif [ "$du" != present ] || [ "$dh" = error ] || [ "$dl" = error ] || [ "$dg" = error ] || [ "$rg" = error ] || [ -z "$dh" ]; then emit NAO-CONSEGUI usuario-dados "getent/stat/id/ls do usuário dados falhou no servidor: não li"
  else
    bad=""
    if [ "$dh" = missing ]; then bad="$bad home-ausente"
    else
      set -- $dh
      [ "${1:-}" = 700 ] || bad="$bad modo ${1:-?} (esperado 700)"
      [ "${2:-}" = dados ] || bad="$bad dono ${2:-?} (esperado dados)"
      [ "$dl" = no ] || bad="$bad home legível pelo runner"
    fi
    case " $dg " in *" runner "*) bad="$bad dados está no grupo do runner" ;; esac
    case " $rg " in *" dados "*) bad="$bad o runner está no grupo do dados" ;; esac
    if [ -n "$bad" ]; then emit ACHADO usuario-dados "${bad# }"
    else emit LIMPO usuario-dados "usuário dados: home 700 e dele, ilegível ao runner, fora do grupo do runner (e o runner fora do dele)"; fi
  fi
  # root-sem-login (trava 2): o valor efetivo e qualquer Match
  rv=$(tl T_SSHD_ROOT); matches=$(printf '%s\n' "$T" | sed -n 's/^T_SSHD_MATCH //p' | tr '\n' ' ')
  mbad=""; for m in $matches; do [ "$m" = no ] || mbad="$mbad $m"; done
  if [ "$rv" = error ] || [ -z "$rv" ]; then emit NAO-CONSEGUI root-sem-login "sshd_config (ou um Include) não pôde ser lido: não li"
  elif [ "$rv" != no ]; then emit ACHADO root-sem-login "PermitRootLogin ${rv/none/ausente (vale o padrão do OpenSSH, prohibit-password: o root entra por chave)}"
  elif [ -n "$mbad" ]; then emit ACHADO root-sem-login "PermitRootLogin no, mas um Match libera o root:$mbad"
  else emit LIMPO root-sem-login "PermitRootLogin no (a 1ª ocorrência fora de Match, com os Include; ${matches:+Match que repetem no: $matches}lido do ARQUIVO, não do sshd vivo)"; fi
  # ufw (trava 2)
  ue=$(tl T_UFW_ENABLED); ua=$(tl T_UFW_ACTIVE)
  if [ "$ue" = error ] || [ "$ua" = error ] || [ -z "$ue" ]; then emit NAO-CONSEGUI ufw "ufw.conf ou systemctl não pôde ser lido: não li"
  elif [ "$ue" = missing ]; then emit ACHADO ufw "sem /etc/ufw/ufw.conf: o ufw não está instalado"
  elif [ "$ue" != yes ]; then emit ACHADO ufw "ENABLED=$ue em ufw.conf (a unidade pode estar \"active\" e o firewall desligado)"
  elif [ "$ua" != active ]; then emit ACHADO ufw "ENABLED=yes, mas a unidade ufw está inativa"
  else emit LIMPO ufw "ENABLED=yes e a unidade ativa (as regras vivas exigem root: não lidas)"; fi
  # fail2ban (trava 2)
  fp=$(tl T_F2B_PKG); fa=$(tl T_F2B_ACTIVE); fj=$(tl T_F2B_JAIL)
  if [ "$fp" = error ] || [ "$fa" = error ] || [ "$fj" = error ] || [ -z "$fp" ]; then emit NAO-CONSEGUI fail2ban "dpkg-query/systemctl/jail.* não pôde ser lido: não li"
  elif [ "$fp" != yes ]; then emit ACHADO fail2ban "fail2ban não instalado"
  elif [ "$fa" != active ]; then emit ACHADO fail2ban "fail2ban instalado, mas a unidade está inativa"
  elif [ "$fj" != true ]; then emit ACHADO fail2ban "ativo, mas sem a jail sshd habilitada (enabled=$fj)"
  else emit LIMPO fail2ban "instalado, ativo e com a jail sshd (lida dos arquivos; o estado vivo exige root)"; fi
fi

if [ "$n_bad" -gt 0 ]; then res=ACHADO; rc=1; elif [ "$n_cant" -gt 0 ]; then res=NAO-CONSEGUI; rc=3; else res=LIMPO; rc=0; fi
printf 'AUDITORIA RESULTADO %s (achados=%s nao-consegui=%s limpos=%s) em %s %s duracao=%ss orcamento=%ss\n' "$res" "$n_bad" "$n_cant" "$n_ok" "${hostname:-$HOST}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$((SECONDS - T0))" "$BUDGET"
exit $rc
