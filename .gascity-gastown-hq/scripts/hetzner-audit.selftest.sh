#!/usr/bin/env bash
# hetzner-audit.selftest.sh — hermético: o "servidor" é uma pasta (mktemp) e o ssh falso roda o comando DE VERDADE nela (HOME apontando para lá, HZ_ETC para o /etc dele), então o find/grep/stat/awk do
# script remoto EXECUTAM no teste. O mbp-run.sh (node_audit) é falso aqui — o node_audit de verdade tem o selftest dele no mbp-run.selftest.sh. Nada toca a rede nem o servidor real.
#
# Contents
#   Casos · Controle negativo
#
# CASOS: servidor limpo → 0 e nove LIMPO · credencial fora da lista (chave privada / token, por CONTEÚDO) · a mesma chave em tests/ ou *.selftest.* NÃO conta (falso por desenho) · loja
#   conhecida (.netrc) · modo 644 · uma das 3 ausente (não é achado) · pasta ilegível = NAO-CONSEGUI · bead: .dolt-backup, .beads só com lock (limpo) e com conteúdo · processo de login
#   (achado / pgrep que falha) · ssh fora = TUDO NAO-CONSEGUI (nenhum LIMPO) e 3 · ssh que cai só no script remoto · scan do GitHub 0/1/2/ausente · dados: achado com DETALHE, não consegui,
#   leu menos pastas do que pediu, mbp-run ausente, achado sem detalhe · .duckdb só com extensões é aceito, com mais coisa não · diretório de topo novo é auditado, .ssh/.cache/chaves não ·
#   achado + não consegui → 1 · (ga-qg1dw5z.3) usuário dados (trava 1): ausente / modo / dono / legível pelo runner / grupos / leitura que falha · root sem login (trava 2): primeira ocorrência
#   vale, Include, Match, "=", maiúsculas, arquivo ausente · ufw e fail2ban (trava 2) · orçamento: fase que trava NÃO derruba as outras, termina no prazo e mata o remoto · pastas em paralelo, uma
#   só vez cada · escopo (mirror, .npm, .cc-safety-net, .claude/projects fora) · limite de tempo no nó para o node_audit · lista de aceitos (só NOME/GRANDE, nunca CONTEUDO, nunca lista cortada).
# CONTROLE NEGATIVO: sem a conferência de modo, sem a lista, sem o "não terminou", sem o "ERR leitura", sem a 1ª-ocorrência, sem o corte do orçamento, sem a trava de lista cortada: o caso
#   correspondente tem de enxergar a diferença.
# HETZNER_AUDIT_UNDER_TEST=<arquivo> roda o selftest contra uma cópia alterada (mutante).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
AUD=${HETZNER_AUDIT_UNDER_TEST:-$HERE/hetzner-audit.sh}
T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/hzaudit-selftest.XXXXXX")" && pwd -P)
trap 'chmod -R u+rwX "$T" 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
SRV=$T/srv; FAKE=$T/fake; export SRV FAKE; mkdir -p "$FAKE"
export HZ_ETC="$SRV/etc"          # o /etc do servidor falso: o script remoto lê daqui (no servidor de verdade a variável não existe e vale /etc)
fails=0; n=0
ok() { n=$((n+1)); if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
# tokens e chaves montados em pedaços: o fonte deste teste não contém nenhum que um scanner reconheça
TOK_CLAUDE=$(printf '%s%s' 'sk-ant-' 'oat01-abcdefghijklmnopqrstuvwxyz0123456789ABCDEF'); TOK_GH=$(printf '%s%s' 'ghp_' 'abcdefghijklmnopqrstuvwxyz0123456789')
pem() { printf '%s PRIVATE KEY-----\nAAAA\n' '-----BEGIN OPENSSH'; }

cat > "$FAKE/ssh" <<'EOF'
#!/bin/bash
[ "${FAKE_SSH_DOWN:-0}" = 1 ] && exit 255
while [ "${1:-}" = -o ]; do shift 2; done; shift   # opções e host
printf '%s\n' "$*" >> "$T/ssh-log"
case "$*" in *"${FAKE_SSH_FAIL_ON:-@@nunca@@}"*) exit 255 ;; esac
case "$*" in *"${FAKE_SSH_SLOW_ON:-@@nunca@@}"*) echo $$ >> "$T/slow-pids"; exec sleep 120 ;; esac     # fase que trava: o exec deixa o pid do ssh sendo o do sleep (o corte o encontra)
HOME="$SRV" PATH="$FAKE:$PATH" exec bash -c "$*"
EOF
cat > "$FAKE/timeout" <<'EOF'
#!/bin/bash
shift; exec "$@"      # o limite do nó não é a coisa testada aqui (o argv que chegou ao ssh é, no caso do limite de tempo)
EOF
cat > "$FAKE/stat" <<'EOF'
#!/bin/bash
# o home do usuário dados pertence a OUTRO usuário no servidor de verdade: aqui quem diz o dono/modo/grupo é FAKE_DADOS_STAT ("700 dados dados" | "err")
if [ "$1" = -c ] && [ "$2" = '%a %U %G' ] && [ "$3" = "$SRV/home/dados" ]; then [ "${FAKE_DADOS_STAT:-700 dados dados}" = err ] && { echo "stat: boom" >&2; exit 1; }; echo "${FAKE_DADOS_STAT:-700 dados dados}"; exit 0; fi
if [ "$1" = -c ]; then if /usr/bin/stat -c %a / >/dev/null 2>&1; then exec /usr/bin/stat "$@"; fi; exec /usr/bin/stat -f '%Lp %Su' "$3"; fi
exec /usr/bin/stat "$@"
EOF
cat > "$FAKE/ls" <<'EOF'
#!/bin/bash
# o runner NÃO lê o home do dados no servidor de verdade; aqui o mesmo usuário é dono dele, então a negação vem de FAKE_DADOS_LS (denied | ok)
for a in "$@"; do if [ "$a" = "$SRV/home/dados" ]; then [ "${FAKE_DADOS_LS:-denied}" = ok ] && exit 0; echo "ls: cannot open directory '$a': Permission denied" >&2; exit 2; fi; done
exec /bin/ls "$@"
EOF
cat > "$FAKE/getent" <<'EOF'
#!/bin/bash
[ "$1" = passwd ] && [ "$2" = dados ] || exec /usr/bin/getent "$@"
case "${FAKE_DADOS:-ok}" in ok) echo "dados:x:1001:1001::$SRV/home/dados:/bin/bash"; exit 0 ;; absent) exit 2 ;; *) echo "getent: boom" >&2; exit 1 ;; esac
EOF
cat > "$FAKE/id" <<'EOF'
#!/bin/bash
[ "${FAKE_ID_FAIL:-0}" = 1 ] && { echo "id: boom" >&2; exit 1; }
if [ "$1" = -nG ] && [ "${2:-}" = dados ]; then echo "${FAKE_DADOS_GROUPS:-dados}"; exit 0; fi
if [ "$1" = -nG ] && [ $# = 1 ]; then echo "${FAKE_RUNNER_GROUPS:-runner}"; exit 0; fi
exec /usr/bin/id "$@"
EOF
cat > "$FAKE/systemctl" <<'EOF'
#!/bin/bash
# is-active <unidade>: FAKE_SVC_UFW / FAKE_SVC_F2B = active | inactive | err
[ "$1" = is-active ] || exit 2
case "$2" in ufw) v=${FAKE_SVC_UFW:-active} ;; fail2ban) v=${FAKE_SVC_F2B:-active} ;; *) v=err ;; esac
case "$v" in active) echo active; exit 0 ;; inactive) echo inactive; exit 3 ;; *) echo "systemctl: boom" >&2; exit 1 ;; esac
EOF
cat > "$FAKE/dpkg-query" <<'EOF'
#!/bin/bash
# FAKE_F2B_PKG = yes | no | err   (o pacote fail2ban)
case "${FAKE_F2B_PKG:-yes}" in yes) echo "ii "; exit 0 ;; no) echo "dpkg-query: no packages found matching fail2ban" >&2; exit 1 ;; *) echo "dpkg-query: boom" >&2; exit 2 ;; esac
EOF
cat > "$FAKE/pgrep" <<'EOF'
#!/bin/bash
[ "${1:-}" = -P ] && exec /usr/bin/pgrep "$@"      # o corte do orçamento acha os filhos por `pgrep -P`: este falso só substitui o `pgrep -af` do script remoto (sem isto o sleep do ssh travado ficava órfão)
case "${FAKE_PGREP:-none}" in found) echo "370419 claude auth login"; exit 0 ;; err) echo "pgrep: boom" >&2; exit 2 ;; *) exit 1 ;; esac
EOF
cat > "$FAKE/mbp-run" <<'EOF'
#!/bin/bash
# falso: um AUDIT-NODE por --audit-node. Cada invocação grava os argumentos em $T/node-args.<pid> (o script chama várias em paralelo).
# FAKE_NODE = clean | found | cant | short | duck | nodetail | tool | toolconteudo | toolcut | sshprobe ; FAKE_NODE_DIR = a pasta que recebe o estado/achado (padrão ".")
# FAKE_NODE_SLOW_DIR = uma pasta que faz esta invocação travar (o corte do orçamento a mata)
printf '%s\n' "$@" > "$T/node-args.$$"; shift   # --host
dirs=(); while [ $# -gt 0 ]; do [ "$1" = --audit-node ] && dirs+=("${2%%::*}"); shift; done
if [ "${FAKE_NODE:-clean}" = sshprobe ]; then "${MBP_SSH:-ssh}" -o BatchMode=yes fake bash -s -- probe < /dev/null; fi
if [ -n "${FAKE_NODE_SLOW_DIR:-}" ]; then for d in "${dirs[@]}"; do [ "$d" = "$FAKE_NODE_SLOW_DIR" ] && { echo $$ >> "$T/slow-pids"; exec sleep 120; }; done; fi
case "${FAKE_NODE:-clean}" in short) printf 'AUDIT-NODE LIMPO %s\n' "${dirs[0]}"; exit 0 ;; esac
tgt=${FAKE_NODE_DIR:-.}; rc=0
for d in "${dirs[@]}"; do st=LIMPO
  if [ "$d" = "$tgt" ]; then case "${FAKE_NODE:-clean}" in found|duck|nodetail|tool|toolconteudo|toolcut) st=ACHADO ;; cant) st=NAO-CONSEGUI ;; esac; fi
  [ "$st" != LIMPO ] && rc=98
  if [ "$d" = "$tgt" ]; then
    case "${FAKE_NODE:-clean}" in
      found) printf 'mbp-run: ALARME: dado ou segredo no destino (nó Linux:%s) — x\n  NOME .voicebot-cost.db\n  NOME shared\n' "$d" >&2 ;;
      duck) printf 'mbp-run: ALARME: dado ou segredo no destino (nó Linux:%s) — x\n  NOME .duckdb\n' "$d" >&2 ;;
      tool) printf 'mbp-run: ALARME: dado ou segredo no destino (nó Linux:%s) — x\n  NOME go/telemetry/local/upload.token\n' "$d" >&2 ;;
      toolconteudo) printf 'mbp-run: ALARME: dado ou segredo no destino (nó Linux:%s) — x\n  NOME go/telemetry/local/upload.token\n  CONTEUDO 25\t0\tgo/telemetry/local/upload.token\n' "$d" >&2 ;;
      toolcut) printf 'mbp-run: ALARME: dado ou segredo no destino (nó Linux:%s) — x\n' "$d" >&2; for i in $(seq 1 20); do printf '  NOME logs/x%s.log\n' "$i" >&2; done ;;   # 20 linhas que DADOS_ACEITOS aceitaria uma a uma (.whatsapp-automation|logs/*.log): só o corte em 20 as segura
    esac
  fi
  printf 'AUDIT-NODE %s %s\n' "$st" "$d"
done
exit $rc
EOF
chmod +x "$FAKE"/*

mk() {  # servidor limpo: as 3 credenciais conhecidas (600), diretórios do tipo certo, scan falso que sai 0, e as travas 1 e 2 no lugar
  chmod -R u+rwX "$SRV" 2>/dev/null; find "$SRV" -mindepth 1 -delete 2>/dev/null
  mkdir -p "$SRV/.claude" "$SRV/.ssh" "$SRV/gt-remote/keys" "$SRV/gt-remote/bin" "$SRV/gt-remote/wa-base" "$SRV/gt-remote/hq-base" "$SRV/gt-remote/git" "$SRV/gt-remote/venv-wa" "$SRV/gt-remote/venv-ps" "$SRV/.cache"
  echo "$TOK_CLAUDE" > "$SRV/.claude/.credentials.json"; pem > "$SRV/.ssh/mini_shim_ed25519"; pem > "$SRV/gt-remote/keys/gt_mirror"
  chmod 600 "$SRV/.claude/.credentials.json" "$SRV/.ssh/mini_shim_ed25519" "$SRV/gt-remote/keys/gt_mirror"; echo "x = 1" > "$SRV/gt-remote/wa-base/app.py"
  printf '#!/bin/bash\necho "scan fake: ${FAKE_SCAN_MSG:-limpo}"; exit "${FAKE_SCAN_RC:-0}"\n' > "$SRV/gt-remote/bin/hetzner-remote-git.sh"; chmod +x "$SRV/gt-remote/bin/hetzner-remote-git.sh"
  mkdir -p "$SRV/etc/ssh/sshd_config.d" "$SRV/etc/ufw" "$SRV/etc/fail2ban/jail.d" "$SRV/home/dados"; chmod 700 "$SRV/home/dados"
  printf 'Include /etc/ssh/sshd_config.d/*.conf\nPasswordAuthentication no\nPermitRootLogin no\n' > "$SRV/etc/ssh/sshd_config"
  printf '# ufw.conf\nENABLED=yes\nLOGLEVEL=low\n' > "$SRV/etc/ufw/ufw.conf"
  printf '[sshd]\nenabled = true\n' > "$SRV/etc/fail2ban/jail.d/defaults-debian.conf"
  rm -f "$T"/node-args.* "$T/ssh-log" "$T/slow-pids" 2>/dev/null
}
run() {  # run — a auditoria sob o ambiente atual; stdout em $out, rc em $rc
  out=$(MBP_SSH="$FAKE/ssh" HETZNER_NODE_HOST=fake HETZNER_AUDIT_MBP_RUN="${RUN_MBP:-$FAKE/mbp-run}" PATH="$FAKE:$PATH" T="$T" "$AUD" 2>"$T/err"); rc=$?
}
st() { printf '%s\n' "$out" | grep -E "^AUDITORIA (LIMPO|ACHADO|NAO-CONSEGUI) $1:" | awk '{print $2}'; }   # estado da verificação $1 (DETALHE não é estado)
det() { printf '%s\n' "$out" | grep -E "^AUDITORIA (LIMPO|ACHADO|NAO-CONSEGUI|DETALHE) $1:"; }
is() { [ "$(st "$1")" = "$2" ]; ok $? "$3"; }                                      # is VERIFICAÇÃO ESTADO descrição
dets() { det "$1" | grep -qF -- "$2"; ok $? "  o detalhe de $1 diz '$2'"; }
rcis() { [ "$rc" = "$1" ]; ok $? "  saída $1 (rc=$rc)"; }
allbut() { local c; for c in "$@"; do [ "$(st "$c")" = LIMPO ] || return 1; done; }
ALL9="processo credenciais backup-de-bead github-e-espelho dados usuario-dados root-sem-login ufw fail2ban"
nodeargs() { cat "$T"/node-args.* 2>/dev/null; }          # os argumentos de TODAS as invocações do mbp-run desta rodada

mk; run; is processo LIMPO "servidor limpo: processo"; is credenciais LIMPO "  credenciais"; is backup-de-bead LIMPO "  backup-de-bead"; is github-e-espelho LIMPO "  github-e-espelho"; is dados LIMPO "  dados"
is usuario-dados LIMPO "  usuario-dados (trava 1)"; is root-sem-login LIMPO "  root-sem-login (trava 2)"; is ufw LIMPO "  ufw (trava 2)"; is fail2ban LIMPO "  fail2ban (trava 2)"
dets dados "NÃO auditados por dados: .cache .local .duckdb .ssh .npm .cc-safety-net (topo), .claude/{projects,file-history} e gt-remote/{bin,bundle,bundle-out,git,keys,mirror,venv-*}"
rcis 0; printf '%s\n' "$out" | grep -q '^AUDITORIA RESULTADO LIMPO (achados=0 nao-consegui=0 limpos=9)'; ok $? "  RESULTADO LIMPO (0/0/9)"
printf '%s\n' "$out" | grep -qE '^AUDITORIA RESULTADO .* duracao=[0-9]+s orcamento=540s$'; ok $? "  o RESULTADO diz a duração e o orçamento"
dets credenciais ".claude/.credentials.json .ssh/mini_shim_ed25519 gt-remote/keys/gt_mirror"
# precondição: o script sob teste emite as 9 verificações. Um script ANTIGO (a árvore base) falha AQUI, em ~1 s, em vez de arrastar os ~100 casos seguintes até o corte de 30 s do guard de base do gate
for c in $ALL9; do [ -n "$(st $c)" ] || { echo "FAIL o script sob teste não emite a verificação '$c' (script antigo?): abortando"; echo "SELFTEST FALHOU (precondição)"; exit 1; }; done

# --- credenciais: por CONTEÚDO, não por nome ---
mk; pem > "$SRV/gt-remote/wa-base/deploy.txt"; run; is credenciais ACHADO "chave privada num arquivo qualquer (nome inocente)"; dets credenciais "hit-fora-da-lista:gt-remote/wa-base/deploy.txt"; rcis 1
mk; echo "$TOK_GH" > "$SRV/notas"; run; is credenciais ACHADO "token do GitHub num arquivo do home"; dets credenciais "hit-fora-da-lista:notas"
mk; mkdir -p "$SRV/gt-remote/wa-base/tests/fixtures"; pem > "$SRV/gt-remote/wa-base/tests/fixtures/k.txt"; echo "$TOK_GH" > "$SRV/gt-remote/hq-base/a.selftest.sh"; echo "$TOK_GH" > "$SRV/gt-remote/hq-base/test_x.py"
run; is credenciais LIMPO "a mesma chave/token em tests/, *.selftest.* e test_* NÃO conta (sintéticos por desenho)"
mk; mkdir -p "$SRV/gt-remote/git/gascity/wt/s1" "$SRV/gt-remote/mirror/x" "$SRV/.claude/projects/p" "$SRV/.claude/file-history/h"; echo "$TOK_CLAUDE" > "$SRV/gt-remote/git/gascity/wt/s1/doc.md"; echo "$TOK_CLAUDE" > "$SRV/gt-remote/mirror/x/a"
echo "$TOK_CLAUDE" > "$SRV/.claude/projects/p/t.jsonl"; echo "$TOK_CLAUDE" > "$SRV/.claude/file-history/h/v1"
run; is credenciais LIMPO "token em worktree/espelho git e em transcrito/histórico de sessão: fora da busca por conteúdo (medido: 156 acertos de exemplo, e a busca não fechava em 280 s)"
dets credenciais "a busca por CONTEÚDO não olha: gt-remote/{git,mirror,venv-*}, .claude/{projects,file-history,plugins,downloads}, .cache, .local/share/claude"
mk; touch "$SRV/.netrc"; run; is credenciais ACHADO "loja conhecida (.netrc)"; dets credenciais "loja-conhecida:.netrc"
mk; chmod 644 "$SRV/.claude/.credentials.json"; run; is credenciais ACHADO "credencial com modo 644"; dets credenciais "permissao:.claude/.credentials.json(644"
mk; rm "$SRV/gt-remote/keys/gt_mirror"; run; is credenciais LIMPO "uma das 3 ausente: não é achado"; dets credenciais "ausentes (não é achado): gt-remote/keys/gt_mirror"
mk; mkdir "$SRV/gt-remote/wa-base/fechada"; echo x > "$SRV/gt-remote/wa-base/fechada/a"
if chmod 000 "$SRV/gt-remote/wa-base/fechada" && [ ! -r "$SRV/gt-remote/wa-base/fechada" ]; then run; is credenciais NAO-CONSEGUI "pasta ilegível: não consegui (nunca LIMPO)"; is backup-de-bead NAO-CONSEGUI "  idem backup-de-bead"; rcis 3; chmod 755 "$SRV/gt-remote/wa-base/fechada"
else echo "SKIP  pasta ilegível: este usuário lê tudo (root)"; fi

# --- backup de bead ---
mk; mkdir "$SRV/.dolt-backup"; run; is backup-de-bead ACHADO ".dolt-backup"; dets backup-de-bead ".dolt-backup"
mk; mkdir -p "$SRV/.beads/eventsData"; : > "$SRV/.beads/eventsData/eventkit.lock"; run; is backup-de-bead LIMPO ".beads só com lock (como está hoje no servidor)"
mk; mkdir -p "$SRV/.beads/dolt"; echo x > "$SRV/.beads/dolt/manifest"; run; is backup-de-bead ACHADO ".beads com conteúdo além de lock"; dets backup-de-bead ".beads (com conteúdo além de lock)"
mk; : > "$SRV/issues.jsonl"; run; is backup-de-bead ACHADO "issues.jsonl"
mk; mkdir -p "$SRV/x/jsonl-archive/hq/issues"; : > "$SRV/x/jsonl-archive/hq/issues/2026-11-01.jsonl"; run; is backup-de-bead ACHADO "2026-11-01.jsonl"   # ga-e4cbc5s: a day piece of the archive

# --- processo ---
mk; FAKE_PGREP=found run; is processo ACHADO "claude auth login esquecido"; dets processo "370419"; rcis 1
mk; FAKE_PGREP=err run; is processo NAO-CONSEGUI "pgrep que falha: não consegui"; rcis 3

# --- ssh ---
mk; FAKE_SSH_DOWN=1 run; allbut $ALL9; [ $? != 0 ]; ok $? "ssh fora: NENHUM LIMPO"
for c in $ALL9; do is $c NAO-CONSEGUI "  $c = NAO-CONSEGUI"; done; rcis 3
mk; FAKE_SSH_FAIL_ON="bash -s" run; is credenciais NAO-CONSEGUI "ssh cai só nos scripts remotos: não consegui"; is dados NAO-CONSEGUI "  dados também"; is usuario-dados NAO-CONSEGUI "  e as quatro travas"
is root-sem-login NAO-CONSEGUI "  root-sem-login"; is ufw NAO-CONSEGUI "  ufw"; is fail2ban NAO-CONSEGUI "  fail2ban"; is github-e-espelho LIMPO "  o scan (outra chamada) segue limpo"; rcis 3

# --- github e espelho: o scan que o servidor já tem ---
mk; FAKE_SCAN_RC=1 FAKE_SCAN_MSG="VIOLAÇÃO remotos=[https://github.com/x]" run; is github-e-espelho ACHADO "scan com violação (rc 1)"; dets github-e-espelho "VIOLA"; rcis 1
mk; FAKE_SCAN_RC=2 run; is github-e-espelho NAO-CONSEGUI "scan que não conseguiu varrer (rc 2)"; rcis 3
mk; rm "$SRV/gt-remote/bin/hetzner-remote-git.sh"; run; is github-e-espelho NAO-CONSEGUI "scan ausente no servidor: não consegui"
# o scan imprime os remotos do git CRUS e o relatório vai a um push externo (revisão de segurança de 12/11): usuário:senha@ de URL e token saem mascarados
SEC=$(printf '%s%s' 'S3cr3t' 'Passw0rd')
mk; FAKE_SCAN_RC=1 FAKE_SCAN_MSG="VIOLAÇÃO remotos_fora_do_espelho=[https://x-access-token:$SEC@github.com/x/y $TOK_GH]" run; is github-e-espelho ACHADO "scan com URL usuário:senha@ e token no texto: segue ACHADO"
! det github-e-espelho | grep -qF -e "$SEC" -e "${TOK_GH#ghp_}"; ok $? "  nem a senha do URL nem o token aparecem no relatório"; dets github-e-espelho "://***@github.com/x/y"; dets github-e-espelho "ghp_***"

# --- dados (node_audit): onde olhar, e os três estados vindos dele ---
mk; FAKE_NODE=found run; is dados ACHADO "node_audit achou"; dets dados "2 achados em: ."; printf '%s\n' "$out" | grep -qF 'AUDITORIA DETALHE dados: .: NOME shared'; ok $? "  um DETALHE por achado"; rcis 1
mk; FAKE_NODE=cant run; is dados NAO-CONSEGUI "node_audit não conseguiu"; rcis 3
mk; FAKE_NODE=short run; is dados NAO-CONSEGUI "node_audit leu menos pastas do que o pedido"; dets dados "leu "
mk; RUN_MBP=/nao/existe run; is dados NAO-CONSEGUI "mbp-run ausente"
mk; FAKE_NODE=nodetail run; is dados ACHADO "pasta ACHADO sem detalhe legível continua achado"; dets dados "1 achados em: ."
mk; mkdir -p "$SRV/.duckdb/ext"; : > "$SRV/.duckdb/ext/a.duckdb_extension"; : > "$SRV/.duckdb/ext/a.duckdb_extension.info"; FAKE_NODE=duck run; is dados LIMPO ".duckdb só com extensões: aceito (conferido na rodada)"
mk; mkdir -p "$SRV/.duckdb/ext"; : > "$SRV/.duckdb/ext/a.duckdb_extension"; : > "$SRV/.duckdb/dados.db"; FAKE_NODE=duck run; is dados ACHADO ".duckdb com um .db dentro: a exceção NÃO vale"
mk; mkdir -p "$SRV/novidade" "$SRV/.config"; run; nodeargs | grep -qxF 'novidade'; ok $? "diretório de topo novo é auditado"
nodeargs | grep -qxF '.config' && nodeargs | grep -qxF '.::maxdepth=1' && nodeargs | grep -qxF 'gt-remote/wa-base::prune=venv:env:.git:__pycache__'; ok $? "  .config, o topo (maxdepth=1) e cada filho de gt-remote entram"
! nodeargs | grep -q -e '^\.ssh$' -e '^\.cache$' -e 'gt-remote/keys' -e 'gt-remote/venv-wa' -e 'gt-remote/venv-ps' -e 'gt-remote/git' -e 'gt-remote/bin'; ok $? "  .ssh, .cache, chaves, venv, espelho git e bin NÃO entram"
mk; mkdir -p "$SRV/.claude" "$SRV/gt-remote/mirror" "$SRV/.npm" "$SRV/.cc-safety-net" "$SRV/gt-remote/tools"; run
! nodeargs | grep -q -e 'gt-remote/mirror' -e '^\.npm$' -e '^\.cc-safety-net$'; ok $? "  escopo (ga-qg1dw5z.3): mirror (varredura própria por commit no mini), .npm (cache público) e .cc-safety-net (logs de sessão) NÃO entram"
nodeargs | grep -qxF 'gt-remote/tools::prune=venv:env:.git:__pycache__'; ok $? "  gt-remote/tools (ferramentas de build) entra"
nodeargs | grep -qxF '.claude::prune=plugins:downloads:cache:security/agent-sdk-venv:projects:file-history'; ok $? "  .claude entra com a poda de plugins/venv e dos transcritos (projects, file-history: 7 GB, 331 arquivos > 4 MB)"

# --- paralelismo: K invocações do mbp-run, cada pasta UMA vez ---
mk; mkdir -p "$SRV/a1" "$SRV/a2" "$SRV/a3" "$SRV/a4" "$SRV/a5" "$SRV/a6"; HETZNER_AUDIT_JOBS=3 run; is dados LIMPO "pastas em paralelo: dados segue LIMPO"
[ "$(ls "$T"/node-args.* 2>/dev/null | wc -l | tr -d ' ')" = 3 ]; ok $? "  HETZNER_AUDIT_JOBS=3 → 3 invocações do mbp-run"
nodeargs | grep -vE '^(-|linux$)' | sort > "$T/union"; nodeargs | grep -vE '^(-|linux$)' | sort -u > "$T/union-u"; cmp -s "$T/union" "$T/union-u"; ok $? "  nenhuma pasta auditada duas vezes"
for d in a1 a2 a3 a4 a5 a6 .claude gt-remote/wa-base gt-remote/hq-base; do nodeargs | grep -qE "^$d(::|\$)" || { echo "     faltou: $d"; false; }; done; ok $? "  e nenhuma ficou de fora"
mk; mkdir -p "$SRV/a1"; HETZNER_AUDIT_JOBS=abc run; is dados LIMPO "HETZNER_AUDIT_JOBS inválido: usa o padrão, não quebra"
mk; mkdir -p "$SRV/a1" "$SRV/a2"; FAKE_NODE=found FAKE_NODE_DIR=a2 HETZNER_AUDIT_JOBS=4 run; is dados ACHADO "o achado numa pasta de OUTRO grupo aparece"; dets dados "2 achados em: a2"

# --- limite de tempo no nó para o node_audit (o mbp-run chama o ssh pelo MBP_SSH que a auditoria passa) ---
mk; FAKE_NODE=sshprobe run; grep -qE '^timeout [0-9]+ bash -s -- probe$' "$T/ssh-log"; ok $? "o ssh do node_audit recebe \"timeout N bash -s --\": o remoto se mata no prazo, não fica órfão"

# --- orçamento: fase que trava não derruba as outras, termina no prazo e mata o remoto ---
mk; rm -f "$T/slow-pids"; t0=$(date +%s); FAKE_SSH_SLOW_ON="bash -s -- travas" HETZNER_AUDIT_BUDGET=4 run; el=$(( $(date +%s) - t0 ))
[ "$el" -le 20 ]; ok $? "fase das travas trava: a auditoria TERMINA no prazo (${el}s com orçamento 4s)"
for c in usuario-dados root-sem-login ufw fail2ban; do is $c NAO-CONSEGUI "  $c = NAO-CONSEGUI (não leu)"; done; dets usuario-dados "orçamento"
for c in processo credenciais backup-de-bead github-e-espelho dados; do is $c LIMPO "  $c segue LIMPO: a fase lenta não derruba as outras"; done; rcis 3
dead=1; for p in $(cat "$T/slow-pids" 2>/dev/null); do kill -0 "$p" 2>/dev/null && dead=0; done; [ -s "$T/slow-pids" ] && [ "$dead" = 1 ]; ok $? "  o ssh que travou foi MORTO (sem processo órfão)"
printf '%s\n' "$out" | grep -qE '^AUDITORIA RESULTADO NAO-CONSEGUI .* orcamento=4s$'; ok $? "  o RESULTADO diz o orçamento"
mk; rm -f "$T/slow-pids"; mkdir -p "$SRV/b1" "$SRV/b2" "$SRV/b3"; FAKE_NODE_SLOW_DIR=b2 HETZNER_AUDIT_JOBS=2 HETZNER_AUDIT_BUDGET=4 run
is dados NAO-CONSEGUI "grupo do node_audit que trava: dados NAO-CONSEGUI (nunca LIMPO)"; dets dados "orçamento"; is processo LIMPO "  e o resto segue"; is usuario-dados LIMPO "  inclusive as travas"
mk; rm -f "$T/slow-pids"; mkdir -p "$SRV/b1" "$SRV/b2" "$SRV/b3"; FAKE_NODE=found FAKE_NODE_DIR=. FAKE_NODE_SLOW_DIR=b2 HETZNER_AUDIT_JOBS=2 HETZNER_AUDIT_BUDGET=4 run
is dados ACHADO "achado de um grupo + outro grupo que estourou: achar vale mais que não terminar"; rcis 1
mk; HETZNER_AUDIT_BUDGET=abc run; printf '%s\n' "$out" | grep -qE 'orcamento=540s$'; ok $? "orçamento inválido: usa o padrão de 540 s"

# --- trava 1: usuário dados (home 0700, dono dados, fora do grupo do runner, ilegível ao runner) ---
mk; FAKE_DADOS=absent run; is usuario-dados ACHADO "usuário dados ausente: a trava 1 não está aplicada"; dets usuario-dados "não existe"; rcis 1
mk; FAKE_DADOS_STAT="755 dados dados" run; is usuario-dados ACHADO "home com modo 755"; dets usuario-dados "modo 755"
mk; FAKE_DADOS_STAT="700 runner runner" run; is usuario-dados ACHADO "home que pertence ao runner (não ao dados)"; dets usuario-dados "dono runner"
mk; FAKE_DADOS_LS=ok run; is usuario-dados ACHADO "o runner LÊ o home do dados"; dets usuario-dados "legível pelo runner"
mk; FAKE_DADOS_GROUPS="dados runner" run; is usuario-dados ACHADO "dados dentro do grupo do runner"; dets usuario-dados "grupo do runner"
mk; FAKE_RUNNER_GROUPS="runner dados" run; is usuario-dados ACHADO "runner dentro do grupo do dados"
mk; FAKE_DADOS=err run; is usuario-dados NAO-CONSEGUI "getent que falha: não consegui (nunca \"ausente\")"; rcis 3
mk; FAKE_DADOS_STAT=err run; is usuario-dados NAO-CONSEGUI "stat do home que falha: não consegui"
mk; FAKE_ID_FAIL=1 run; is usuario-dados NAO-CONSEGUI "id que falha: não consegui"
mk; rmdir "$SRV/home/dados"; run; is usuario-dados ACHADO "home do dados ausente"; dets usuario-dados "home"

# --- trava 2: root sem login direto (a 1ª ocorrência fora de Match vale; Include na posição; Match que libera é achado) ---
mk; printf 'PasswordAuthentication no\n' > "$SRV/etc/ssh/sshd_config"; run; is root-sem-login ACHADO "sem PermitRootLogin: vale o padrão do OpenSSH (prohibit-password: root entra por chave)"; dets root-sem-login "padrão"
for v in yes prohibit-password without-password forced-commands-only; do mk; printf 'PermitRootLogin %s\n' "$v" > "$SRV/etc/ssh/sshd_config"; run; is root-sem-login ACHADO "PermitRootLogin $v"; done
mk; printf 'PermitRootLogin no\nPermitRootLogin yes\n' > "$SRV/etc/ssh/sshd_config"; run; is root-sem-login LIMPO "no e depois yes: a 1ª ocorrência vale"
mk; printf 'PermitRootLogin yes\nPermitRootLogin no\n' > "$SRV/etc/ssh/sshd_config"; run; is root-sem-login ACHADO "yes e depois no: a 1ª ocorrência vale (yes)"
mk; printf 'permitrootlogin NO\n' > "$SRV/etc/ssh/sshd_config"; run; is root-sem-login LIMPO "palavra e valor sem diferenciar maiúscula"
mk; printf 'PermitRootLogin=no\n' > "$SRV/etc/ssh/sshd_config"; run; is root-sem-login LIMPO "PermitRootLogin=no (com =)"
mk; printf 'Include /etc/ssh/sshd_config.d/*.conf\n' > "$SRV/etc/ssh/sshd_config"; printf 'PermitRootLogin no\n' > "$SRV/etc/ssh/sshd_config.d/50-x.conf"; run; is root-sem-login LIMPO "valor vindo de um Include (sshd_config.d)"
mk; printf 'Include /etc/ssh/sshd_config.d/*.conf\nPermitRootLogin no\n' > "$SRV/etc/ssh/sshd_config"; printf 'PermitRootLogin yes\n' > "$SRV/etc/ssh/sshd_config.d/50-x.conf"; run; is root-sem-login ACHADO "o Include vem ANTES: o yes dele é o que vale"
mk; printf 'PermitRootLogin no\nMatch Address 10.0.0.0/8\n  PermitRootLogin yes\n' > "$SRV/etc/ssh/sshd_config"; run; is root-sem-login ACHADO "Match que libera o root"; dets root-sem-login "Match"
mk; printf 'PermitRootLogin no\nMatch User ninguem\n  PermitRootLogin no\n' > "$SRV/etc/ssh/sshd_config"; run; is root-sem-login LIMPO "Match que também diz no: segue limpo"
mk; printf '# PermitRootLogin yes\nPermitRootLogin no # sem login\n' > "$SRV/etc/ssh/sshd_config"; run; is root-sem-login LIMPO "comentário (linha e fim de linha) não conta"
mk; rm "$SRV/etc/ssh/sshd_config"; run; is root-sem-login NAO-CONSEGUI "sshd_config ausente: não consegui"; rcis 3

# --- trava 2: ufw (ENABLED=yes no arquivo E a unidade ativa: o unit do ufw roda e sai, "active" sozinho não prova firewall) e fail2ban (pacote, serviço, jail sshd) ---
mk; printf 'ENABLED=no\n' > "$SRV/etc/ufw/ufw.conf"; run; is ufw ACHADO "ENABLED=no mesmo com a unidade ativa (o caso medido no nó)"; dets ufw "ENABLED=no"
mk; FAKE_SVC_UFW=inactive run; is ufw ACHADO "unidade inativa"; dets ufw "inativ"
mk; rm "$SRV/etc/ufw/ufw.conf"; run; is ufw ACHADO "sem ufw.conf: ufw não instalado"
mk; FAKE_SVC_UFW=err run; is ufw NAO-CONSEGUI "systemctl que falha: não consegui"
mk; chmod 000 "$SRV/etc/ufw/ufw.conf"; if [ ! -r "$SRV/etc/ufw/ufw.conf" ]; then run; is ufw NAO-CONSEGUI "ufw.conf ilegível: não consegui"; chmod 644 "$SRV/etc/ufw/ufw.conf"; else echo "SKIP  ufw.conf ilegível: root"; fi
mk; FAKE_F2B_PKG=no run; is fail2ban ACHADO "fail2ban não instalado (o caso medido no nó)"; dets fail2ban "não instalado"
mk; FAKE_SVC_F2B=inactive run; is fail2ban ACHADO "fail2ban instalado e inativo"
mk; rm "$SRV/etc/fail2ban/jail.d/defaults-debian.conf"; run; is fail2ban ACHADO "sem a jail sshd habilitada"; dets fail2ban "jail sshd"
mk; printf '[sshd]\nenabled = false\n' > "$SRV/etc/fail2ban/jail.d/defaults-debian.conf"; run; is fail2ban ACHADO "jail sshd com enabled=false"
mk; rm "$SRV/etc/fail2ban/jail.d/defaults-debian.conf"; printf '[sshd]\nenabled = true\n' > "$SRV/etc/fail2ban/jail.local"; run; is fail2ban LIMPO "jail sshd habilitada no jail.local"
mk; printf '[sshd]\nenabled = true\n' > "$SRV/etc/fail2ban/jail.local"; printf '[sshd]\nenabled = false\n' > "$SRV/etc/fail2ban/jail.d/defaults-debian.conf"; run; is fail2ban LIMPO "jail.local vence jail.d/*.conf (a ordem do fail2ban)"
mk; FAKE_F2B_PKG=err run; is fail2ban NAO-CONSEGUI "dpkg-query que falha: não consegui"

# --- lista de aceitos: só NOME e GRANDE, nunca CONTEUDO, nunca lista cortada em 20 ---
mk; mkdir -p "$SRV/.config"; FAKE_NODE=tool FAKE_NODE_DIR=.config run; is dados LIMPO "achado de NOME numa ferramenta conhecida (token de telemetria do Go): aceito"; dets dados "aceitos: 1"
mk; mkdir -p "$SRV/.config"; FAKE_NODE=toolconteudo FAKE_NODE_DIR=.config run; is dados ACHADO "o mesmo caminho com um CONTEUDO (lista de telefones) NÃO é aceito"; dets dados "CONTEUDO"
mk; mkdir -p "$SRV/.whatsapp-automation"; FAKE_NODE=toolcut FAKE_NODE_DIR=.whatsapp-automation run; is dados ACHADO "lista cortada em 20 por tipo (20 logs que a lista aceitaria um a um): nada da pasta é aceito, pode haver mais atrás"; dets dados "cortada"
mk; FAKE_NODE=found run; is dados ACHADO "shared e .voicebot-cost.db NÃO são aceitos: a volta deles é o achado"

# --- achado e não-consegui juntos: achar vale mais ---
mk; chmod 644 "$SRV/.claude/.credentials.json"; FAKE_PGREP=err run; is credenciais ACHADO "achado numa verificação"; is processo NAO-CONSEGUI "  não consegui noutra"; rcis 1

# --- controle negativo: um mutante por guarda, e o caso que a cobre tem de ver a diferença ---
mutant() {  # mutant NOME SED-EXPR — grava o mutante em $T/mut.sh (com a guarda estragada) e confere que o sed mudou algo
  sed "$2" "$AUD" > "$T/mut.sh"; ! cmp -s "$AUD" "$T/mut.sh"; ok $? "  o mutante '$1' difere do script (o sed não é um no-op)"; chmod +x "$T/mut.sh"
}
AUD_REAL=$AUD
mutant "sem conferir modo/dono" 's/\[ "\$mode" = 600 \] && \[ "\$owner" = "\$user" \]/true/'; AUD=$T/mut.sh
mk; chmod 644 "$SRV/.claude/.credentials.json"; run; AUD=$AUD_REAL; is credenciais LIMPO "controle negativo: sem a conferência de modo, 644 passaria (o caso do modo 644 vê a diferença)"
mutant "lista aceita tudo" 's/\*) bad="\$bad hit-fora-da-lista:\$h"/*) :/'; AUD=$T/mut.sh
mk; pem > "$SRV/gt-remote/wa-base/deploy.txt"; run; AUD=$AUD_REAL; is credenciais LIMPO "controle negativo: sem a lista, a chave fora dela passaria"
mutant "ssh fora vira limpo" 's/^\[ "\$a_done" = 1 \] && \[ -n "\$user" \] || { a_done=0; }/a_done=1/'; AUD=$T/mut.sh
mk; FAKE_SSH_DOWN=1 run; AUD=$AUD_REAL; is processo LIMPO "controle negativo: sem o \"não terminou\", ssh fora viraria LIMPO"
mutant "leitura falha ignorada" 's/err_for stat || err_for leitura/false/'; AUD=$T/mut.sh
mk; mkdir "$SRV/gt-remote/wa-base/fechada"; echo x > "$SRV/gt-remote/wa-base/fechada/a"
if chmod 000 "$SRV/gt-remote/wa-base/fechada" && [ ! -r "$SRV/gt-remote/wa-base/fechada" ]; then run; AUD=$AUD_REAL; is credenciais LIMPO "controle negativo: sem o ERR leitura, a pasta ilegível viraria LIMPO"; chmod 755 "$SRV/gt-remote/wa-base/fechada"; else AUD=$AUD_REAL; echo "SKIP  controle da pasta ilegível: root"; fi

# controle negativo das guardas da .3: cada mutante estraga UMA guarda e o caso correspondente tem de ver a diferença
mutant "dados sem conferir o grupo" 's/\*" runner "\*) bad="\$bad dados está/*" nunca-runner "*) bad="$bad dados está/'; AUD=$T/mut.sh
mk; FAKE_DADOS_GROUPS="dados runner" run; AUD=$AUD_REAL; is usuario-dados LIMPO "controle negativo: sem a conferência do grupo, dados dentro do grupo do runner passaria"
mutant "ultima ocorrencia do PermitRootLogin vale" 's/\[ -n "\$ROOTV" \] || ROOTV=\$v/ROOTV=$v/'; AUD=$T/mut.sh
mk; printf 'PermitRootLogin no\nPermitRootLogin yes\n' > "$SRV/etc/ssh/sshd_config"; run; AUD=$AUD_REAL; is root-sem-login ACHADO "controle negativo: com a ÚLTIMA ocorrência valendo, no-depois-yes viraria achado (o caso da 1ª ocorrência vê a diferença)"
mutant "ufw sem olhar o ENABLED" 's/elif \[ "\$ue" != yes \]; then emit ACHADO ufw/elif false; then emit ACHADO ufw/'; AUD=$T/mut.sh
mk; printf 'ENABLED=no\n' > "$SRV/etc/ufw/ufw.conf"; run; AUD=$AUD_REAL; is ufw LIMPO "controle negativo: sem o ENABLED, a unidade \"active\" faria o ufw desligado passar"
mutant "fail2ban sem olhar a jail" 's/elif \[ "\$fj" != true \]; then emit ACHADO fail2ban/elif false; then emit ACHADO fail2ban/'; AUD=$T/mut.sh
mk; rm "$SRV/etc/fail2ban/jail.d/defaults-debian.conf"; run; AUD=$AUD_REAL; is fail2ban LIMPO "controle negativo: sem a jail, fail2ban instalado e ativo mas sem vigiar o sshd passaria"
mutant "lista cortada em 20 aceita" 's/if printf .%s\\n. "\$cut_keys" | grep -qxF "\$dir|\$typ"; then/if false; then/'; AUD=$T/mut.sh
mk; mkdir -p "$SRV/.whatsapp-automation"; FAKE_NODE=toolcut FAKE_NODE_DIR=.whatsapp-automation run; AUD=$AUD_REAL; is dados LIMPO "controle negativo: sem a trava de lista cortada, o achado escondido atrás dos 20 passaria"
mutant "relatório sem mascarar" 's/ | redact$//'; AUD=$T/mut.sh
mk; FAKE_SCAN_RC=1 FAKE_SCAN_MSG="VIOLAÇÃO remotos_fora_do_espelho=[https://x-access-token:$SEC@github.com/x/y]" run; AUD=$AUD_REAL; det github-e-espelho | grep -qF "$SEC"; ok $? "controle negativo: sem o mascaramento, a senha do URL apareceria no relatório (o caso do scan vê a diferença)"

echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
