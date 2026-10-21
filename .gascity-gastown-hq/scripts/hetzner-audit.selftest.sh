#!/usr/bin/env bash
# hetzner-audit.selftest.sh — hermético: o "servidor" é uma pasta (mktemp) e o ssh falso roda o comando DE VERDADE nela (HOME apontando para lá), então o find/grep/stat do
# script remoto EXECUTAM no teste. O mbp-run.sh (node_audit) é falso aqui — o node_audit de verdade tem o selftest dele no mbp-run.selftest.sh. Nada toca a rede nem o servidor real.
#
# Contents
#   Casos · Controle negativo
#
# CASOS: servidor limpo → 0 e cinco LIMPO · credencial fora da lista (chave privada / token, por CONTEÚDO) · a mesma chave em tests/ ou *.selftest.* NÃO conta (falso por desenho) · loja
#   conhecida (.netrc) · modo 644 · uma das 3 ausente (não é achado) · pasta ilegível = NAO-CONSEGUI · bead: .dolt-backup, .beads só com lock (limpo) e com conteúdo · processo de login
#   (achado / pgrep que falha) · ssh fora = TUDO NAO-CONSEGUI (nenhum LIMPO) e 3 · ssh que cai só no script remoto · scan do GitHub 0/1/2/ausente · dados: achado com DETALHE, não consegui,
#   leu menos pastas do que pediu, mbp-run ausente, achado sem detalhe · .duckdb só com extensões é aceito, com mais coisa não · diretório de topo novo é auditado, .ssh/.cache/chaves não ·
#   achado + não consegui → 1.
# CONTROLE NEGATIVO: sem a conferência de modo, sem a lista, sem o "não terminou", sem o "ERR leitura": o caso correspondente tem de enxergar a diferença.
# HETZNER_AUDIT_UNDER_TEST=<arquivo> roda o selftest contra uma cópia alterada (mutante).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
AUD=${HETZNER_AUDIT_UNDER_TEST:-$HERE/hetzner-audit.sh}
T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/hzaudit-selftest.XXXXXX")" && pwd -P)
trap 'chmod -R u+rwX "$T" 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
SRV=$T/srv; FAKE=$T/fake; export SRV FAKE; mkdir -p "$FAKE"
fails=0; n=0
ok() { n=$((n+1)); if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
# tokens e chaves montados em pedaços: o fonte deste teste não contém nenhum que um scanner reconheça
TOK_CLAUDE=$(printf '%s%s' 'sk-ant-' 'oat01-abcdefghijklmnopqrstuvwxyz0123456789ABCDEF'); TOK_GH=$(printf '%s%s' 'ghp_' 'abcdefghijklmnopqrstuvwxyz0123456789')
pem() { printf '%s PRIVATE KEY-----\nAAAA\n' '-----BEGIN OPENSSH'; }

cat > "$FAKE/ssh" <<'EOF'
#!/bin/bash
[ "${FAKE_SSH_DOWN:-0}" = 1 ] && exit 255
while [ "${1:-}" = -o ]; do shift 2; done; shift   # opções e host
case "$*" in *"${FAKE_SSH_FAIL_ON:-@@nunca@@}"*) exit 255 ;; esac
HOME="$SRV" PATH="$FAKE:$PATH" exec bash -c "$*"
EOF
cat > "$FAKE/stat" <<'EOF'
#!/bin/bash
if [ "$1" = -c ]; then if /usr/bin/stat -c %a / >/dev/null 2>&1; then exec /usr/bin/stat "$@"; fi; exec /usr/bin/stat -f '%Lp %Su' "$3"; fi
exec /usr/bin/stat "$@"
EOF
cat > "$FAKE/pgrep" <<'EOF'
#!/bin/bash
case "${FAKE_PGREP:-none}" in found) echo "370419 claude auth login"; exit 0 ;; err) echo "pgrep: boom" >&2; exit 2 ;; *) exit 1 ;; esac
EOF
cat > "$FAKE/mbp-run" <<'EOF'
#!/bin/bash
# falso: um AUDIT-NODE por --audit-node; FAKE_NODE = clean | found | cant | short | duck | nodetail
printf '%s\n' "$@" > "$T/node-args"; shift   # --host
case "${FAKE_NODE:-clean}" in short) printf 'AUDIT-NODE LIMPO .\n'; exit 0 ;; esac
first=1; rc=0
while [ $# -gt 0 ]; do [ "$1" = --audit-node ] && { d="${2%%::*}"; st=LIMPO
  if [ $first = 1 ]; then case "$FAKE_NODE" in found|duck|nodetail) st=ACHADO ;; cant) st=NAO-CONSEGUI ;; esac; fi
  if [ $first = 1 ] && [ "$st" != LIMPO ]; then rc=98; fi
  if [ $first = 1 ] && [ "$FAKE_NODE" = found ]; then printf 'mbp-run: ALARME: dado ou segredo no destino (nó Linux:%s) — x\n  NOME .voicebot-cost.db\n  NOME shared\n' "$d" >&2; fi
  if [ $first = 1 ] && [ "$FAKE_NODE" = duck ]; then printf 'mbp-run: ALARME: dado ou segredo no destino (nó Linux:%s) — x\n  NOME .duckdb\n' "$d" >&2; fi
  printf 'AUDIT-NODE %s %s\n' "$st" "$d"; first=0; shift; }; shift; done
exit $rc
EOF
chmod +x "$FAKE"/*

mk() {  # servidor limpo: as 3 credenciais conhecidas (600), diretórios do tipo certo, scan falso que sai 0
  chmod -R u+rwX "$SRV" 2>/dev/null; find "$SRV" -mindepth 1 -delete 2>/dev/null
  mkdir -p "$SRV/.claude" "$SRV/.ssh" "$SRV/gt-remote/keys" "$SRV/gt-remote/bin" "$SRV/gt-remote/wa-base" "$SRV/gt-remote/hq-base" "$SRV/gt-remote/git" "$SRV/gt-remote/venv-wa" "$SRV/gt-remote/venv-ps" "$SRV/.cache"
  echo "$TOK_CLAUDE" > "$SRV/.claude/.credentials.json"; pem > "$SRV/.ssh/mini_shim_ed25519"; pem > "$SRV/gt-remote/keys/gt_mirror"
  chmod 600 "$SRV/.claude/.credentials.json" "$SRV/.ssh/mini_shim_ed25519" "$SRV/gt-remote/keys/gt_mirror"; echo "x = 1" > "$SRV/gt-remote/wa-base/app.py"
  printf '#!/bin/bash\necho "scan fake: ${FAKE_SCAN_MSG:-limpo}"; exit "${FAKE_SCAN_RC:-0}"\n' > "$SRV/gt-remote/bin/hetzner-remote-git.sh"; chmod +x "$SRV/gt-remote/bin/hetzner-remote-git.sh"
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

mk; run; is processo LIMPO "servidor limpo: processo"; is credenciais LIMPO "  credenciais"; is backup-de-bead LIMPO "  backup-de-bead"; is github-e-espelho LIMPO "  github-e-espelho"; is dados LIMPO "  dados"
dets dados "NÃO auditados por dados: .cache .local .duckdb .ssh (topo) e gt-remote/{bin,bundle,bundle-out,git,keys,venv-*}"
rcis 0; printf '%s\n' "$out" | grep -q '^AUDITORIA RESULTADO LIMPO (achados=0 nao-consegui=0 limpos=5)'; ok $? "  RESULTADO LIMPO (0/0/5)"
dets credenciais ".claude/.credentials.json .ssh/mini_shim_ed25519 gt-remote/keys/gt_mirror"

# --- credenciais: por CONTEÚDO, não por nome ---
mk; pem > "$SRV/gt-remote/wa-base/deploy.txt"; run; is credenciais ACHADO "chave privada num arquivo qualquer (nome inocente)"; dets credenciais "hit-fora-da-lista:gt-remote/wa-base/deploy.txt"; rcis 1
mk; echo "$TOK_GH" > "$SRV/notas"; run; is credenciais ACHADO "token do GitHub num arquivo do home"; dets credenciais "hit-fora-da-lista:notas"
mk; mkdir -p "$SRV/gt-remote/wa-base/tests/fixtures"; pem > "$SRV/gt-remote/wa-base/tests/fixtures/k.txt"; echo "$TOK_GH" > "$SRV/gt-remote/hq-base/a.selftest.sh"; echo "$TOK_GH" > "$SRV/gt-remote/hq-base/test_x.py"
run; is credenciais LIMPO "a mesma chave/token em tests/, *.selftest.* e test_* NÃO conta (sintéticos por desenho)"
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

# --- processo ---
mk; FAKE_PGREP=found run; is processo ACHADO "claude auth login esquecido"; dets processo "370419"; rcis 1
mk; FAKE_PGREP=err run; is processo NAO-CONSEGUI "pgrep que falha: não consegui"; rcis 3

# --- ssh ---
mk; FAKE_SSH_DOWN=1 run; allbut processo credenciais backup-de-bead github-e-espelho dados; [ $? != 0 ]; ok $? "ssh fora: NENHUM LIMPO"
for c in processo credenciais backup-de-bead github-e-espelho dados; do is $c NAO-CONSEGUI "  $c = NAO-CONSEGUI"; done; rcis 3
mk; FAKE_SSH_FAIL_ON="bash -s" run; is credenciais NAO-CONSEGUI "ssh cai só no script remoto: não consegui"; is dados NAO-CONSEGUI "  dados também"; is github-e-espelho LIMPO "  o scan (outra chamada) segue limpo"; rcis 3

# --- github e espelho: o scan que o servidor já tem ---
mk; FAKE_SCAN_RC=1 FAKE_SCAN_MSG="VIOLAÇÃO remotos=[https://github.com/x]" run; is github-e-espelho ACHADO "scan com violação (rc 1)"; dets github-e-espelho "VIOLA"; rcis 1
mk; FAKE_SCAN_RC=2 run; is github-e-espelho NAO-CONSEGUI "scan que não conseguiu varrer (rc 2)"; rcis 3
mk; rm "$SRV/gt-remote/bin/hetzner-remote-git.sh"; run; is github-e-espelho NAO-CONSEGUI "scan ausente no servidor: não consegui"

# --- dados (node_audit): onde olhar, e os três estados vindos dele ---
mk; FAKE_NODE=found run; is dados ACHADO "node_audit achou"; dets dados "2 achados em: ."; printf '%s\n' "$out" | grep -qF 'AUDITORIA DETALHE dados: .: NOME shared'; ok $? "  um DETALHE por achado"; rcis 1
mk; FAKE_NODE=cant run; is dados NAO-CONSEGUI "node_audit não conseguiu"; rcis 3
mk; FAKE_NODE=short run; is dados NAO-CONSEGUI "node_audit leu menos pastas do que o pedido"; dets dados "leu 1 de"
mk; RUN_MBP=/nao/existe run; is dados NAO-CONSEGUI "mbp-run ausente"
mk; FAKE_NODE=nodetail run; is dados ACHADO "pasta ACHADO sem detalhe legível continua achado"; dets dados "1 achados em: ."
mk; mkdir -p "$SRV/.duckdb/ext"; : > "$SRV/.duckdb/ext/a.duckdb_extension"; : > "$SRV/.duckdb/ext/a.duckdb_extension.info"; FAKE_NODE=duck run; is dados LIMPO ".duckdb só com extensões: aceito (conferido na rodada)"
mk; mkdir -p "$SRV/.duckdb/ext"; : > "$SRV/.duckdb/ext/a.duckdb_extension"; : > "$SRV/.duckdb/dados.db"; FAKE_NODE=duck run; is dados ACHADO ".duckdb com um .db dentro: a exceção NÃO vale"
mk; mkdir -p "$SRV/novidade" "$SRV/.config"; run; grep -qxF 'novidade' "$T/node-args"; ok $? "diretório de topo novo é auditado"
grep -qxF '.config' "$T/node-args" && grep -qxF '.::maxdepth=1' "$T/node-args" && grep -qxF 'gt-remote/wa-base::prune=venv:env:.git:__pycache__' "$T/node-args"; ok $? "  .config, o topo (maxdepth=1) e cada filho de gt-remote entram"
! grep -q -e '^\.ssh$' -e '^\.cache$' -e 'gt-remote/keys' -e 'gt-remote/venv-wa' -e 'gt-remote/venv-ps' -e 'gt-remote/git' -e 'gt-remote/bin' "$T/node-args"; ok $? "  .ssh, .cache, chaves, venv, espelho e bin NÃO entram"
mk; mkdir -p "$SRV/.claude"; run; grep -qxF '.claude::prune=plugins:downloads:cache:security/agent-sdk-venv' "$T/node-args"; ok $? "  .claude entra com a poda de plugins/venv"

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

echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
