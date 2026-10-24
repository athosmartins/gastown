#!/bin/bash
# install-disk-snapshot-guard-root.sh — ga-xpswpd.1 (pai ga-xpswpd, achado do ga-j86sid)
#
# Contents
#   O problema · O que faz · Uso · Saídas · Regras deste instalador · O que não cobre · Ganchos de teste
#
# O PROBLEMA: o LaunchDaemon com.gascity.disk-snapshot-guard roda como ROOT a cada 10 min e executa
#   /bin/bash /Users/athos/gt/.gascity-gastown-hq/scripts/disk-snapshot-guard.sh — um arquivo do usuário athos, numa pasta
#   do athos. Qualquer processo do athos (sessão de agente, daemon, dependência comprometida) reescreve o que o root
#   executa na próxima rodada. O script hoje é benigno (um `tmutil thinlocalsnapshots`): o defeito é QUEM pode mudá-lo.
#
# O QUE FAZ (precisa de root; a sessão de pool nunca roda sudo, quem roda é o Athos, uma vez):
#   1. confere a cadeia /, /usr, /usr/local, /usr/local/libexec, /usr/local/libexec/gascity: cada degrau do root, sem
#      symlink, sem escrita de grupo/outros. Cria só os que faltam (root:wheel 0755); NUNCA altera um que já existe;
#   2. copia o disk-snapshot-guard.sh que está ao lado deste instalador para /usr/local/libexec/gascity (root:wheel 0755),
#      por arquivo temporário PRIVADO (0700) na pasta do root, confere a CÓPIA (bytes e o sha256 do --expect-sha256) e só então
#      abre para 0755 e faz o rename;
#   3. troca só ProgramArguments[1] do /Library/LaunchDaemons/com.gascity.disk-snapshot-guard.plist para a cópia (as outras
#      chaves ficam como estão), guardando o plist original ao lado da cópia; o plist volta a root:wheel 0644;
#   4. launchctl bootout + bootstrap; se o bootstrap falhar, devolve o plist original e recarrega;
#   5. confere tudo outra vez: dono/modo de cada degrau, o plist e o que o launchd de fato carregou (`launchctl print`).
#
# USO (no mini, depois do merge; quem passa o comando ao Athos é o Mayor)
#   /bin/bash scripts/install-disk-snapshot-guard-root.sh --check                      # sem sudo: só lê e diz o que está errado
#   sudo /bin/bash scripts/install-disk-snapshot-guard-root.sh --expect-sha256 <hex>   # instala (uma vez)
#   sudo /bin/bash scripts/install-disk-snapshot-guard-root.sh --check                 # confere depois, com o launchd
#   --no-reload: instala no disco (cópia + plist) SEM bootout/bootstrap. É o modo do próprio guard (ga-xpswpd.2): o job que
#   roda este instalador não pode ser descarregado no meio da rodada. O job carregado segue com a definição antiga até o
#   launchd carregar o plist de novo (reboot, ou um bootout+bootstrap); a conferência diz "pend" e o RESULTADO "RECARGA PENDENTE".
#   "pend" só vale quando o que o launchd carregou é a definição de antes (bash + <algum caminho>/disk-snapshot-guard.sh); qualquer
#   outra coisa carregada é "?" (rc 3), porque não dá para dizer quando a cópia do root passa a valer. --no-reload SÓ existe para
#   instalar: com --check é uso errado (rc 2, nada muda), senão "o launchd ainda roda a definição velha" viraria "seguro".
#   --expect-sha256 <hex>: OBRIGATÓRIO para instalar (sem ele: uso errado, rc 2, nada muda). É o `shasum -a 256
#   scripts/disk-snapshot-guard.sh` do arquivo revisado: o root lê esse arquivo de uma pasta do athos e só instala o que tem este
#   hash. A cópia nasce 0700 (só do root) e só vira 0755 depois de o hash dela conferir, para que um arquivo trocado no meio do
#   caminho (por exemplo um symlink para algo do root) nunca fique legível por outro. Com --check é opcional e compara a cópia instalada.
#
# SAÍDAS: 0 instalado/seguro e confirmado · 1 recusou ou falhou (a mensagem diz se algo mudou ou foi revertido) ·
#   2 uso errado, nada mudou · 3 NÃO deu para confirmar, ou o estado ficou incerto: confira à mão com o que foi impresso.
#
# REGRAS DESTE INSTALADOR (ele roda como root, a partir de uma pasta do athos):
#   - PATH fixo logo abaixo: o sudo mantém o PATH do athos, e um `install` ou `launchctl` em ~/.local/bin rodaria como root.
#   - Não faz `source` de nada e não chama outro arquivo do repo. O único arquivo do usuário que ele LÊ é o
#     disk-snapshot-guard.sh a copiar, e a cópia só é conferida (e o plist só é tocado) depois de estar em pasta do root.
#   - Os ganchos de teste (DSG_*) só valem SEM root: como root nenhum DSG_* muda o que roda (o uid vem de `id -u`, não do $EUID).
#   - Sob dúvida (dono, modo, symlink, saída do launchctl ilegível) o estado que fica é o inerte: recusa e não mexe.
#
# NÃO COBRE (de propósito):
#   - O log do guard continua em ${CITY}/.gc/logs, pasta do athos: o root faz `>>` num caminho que o athos controla. O pai
#     (ga-xpswpd, item 3) aceitou isso; fica como achado à parte, não é consertado aqui.
#   - Editar scripts/disk-snapshot-guard.sh no repo NÃO muda mais o que o root roda: reinstale com este script.
#   - ACLs (`ls -le`) não são lidas, só o tipo, o dono e os bits de modo. Grupo com escrita conta como "gravável".
#   - Este arquivo também mora no repo até o sudo: o --expect-sha256 trava o que o root COPIA, não este instalador. Quem
#     passa o comando deve passar também o `shasum -a 256` deste arquivo, para o Athos conferir antes de rodar.
#   - O ambiente do root: o `sudo` simples o limpa; com `sudo -E` (ou env_keep) BASH_ENV e funções exportadas rodariam como root
#     antes de qualquer checagem deste arquivo. Use `sudo` simples, como em USO.
#
# GANCHOS DE TESTE (só sem root; o selftest usa todos): DSG_ROOT_PFX (prefixo de "/"), DSG_ROOT_UID (uid que conta como
#   root), DSG_OWNER (user:group no lugar de root:wheel), DSG_LAUNCHCTL, DSG_PLISTBUDDY (binários falsos),
#   DSG_RETRY_SLEEP (segundos entre as tentativas de bootstrap).

set -uo pipefail
umask 022
export LC_ALL=C
IFS=$' \t\n'
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

LABEL="com.gascity.disk-snapshot-guard"
GUARD_NAME="disk-snapshot-guard.sh"
SHELL_BIN="/bin/bash"
PROG_DIR="/usr/local/libexec/gascity"
PROG_PATH="$PROG_DIR/$GUARD_NAME"
PLIST_PATH="/Library/LaunchDaemons/$LABEL.plist"
BOOT_TRIES=5

ROOT_PFX=""
ROOT_UID=0
ROOT_OWNER="root:wheel"
LAUNCHCTL="/bin/launchctl"
PLISTBUDDY="/usr/libexec/PlistBuddy"
RETRY_SLEEP=2
# o uid vem de `id -u`, nunca de $EUID: o bash aceita EUID importado do ambiente (medido nos bash 5.2 e 3.2.57) e um `sudo -E`
# ligaria os ganchos como root. vazio → MY_UID vazio: nenhum gancho vale e a checagem de root lá embaixo recusa;
# falhou/ilegível → idem (sem uid confirmado o estado é o inerte)
MY_UID=$(/usr/bin/id -u 2>/dev/null) || MY_UID=""
case "$MY_UID" in (*[!0-9]*) MY_UID="" ;; esac
if [ -n "$MY_UID" ] && [ "$MY_UID" != "0" ]; then
  ROOT_PFX="${DSG_ROOT_PFX:-}"
  ROOT_UID="${DSG_ROOT_UID:-0}"
  ROOT_OWNER="${DSG_OWNER:-root:wheel}"
  LAUNCHCTL="${DSG_LAUNCHCTL:-$LAUNCHCTL}"
  PLISTBUDDY="${DSG_PLISTBUDDY:-$PLISTBUDDY}"
  RETRY_SLEEP="${DSG_RETRY_SLEEP:-$RETRY_SLEEP}"
fi
OWN_U="${ROOT_OWNER%%:*}"
OWN_G="${ROOT_OWNER##*:}"
PROG_DIR_REAL="${ROOT_PFX}${PROG_DIR}"
PROG_FILE_REAL="${ROOT_PFX}${PROG_PATH}"
PLIST_REAL="${ROOT_PFX}${PLIST_PATH}"

MODE="install"
PIN=""
NO_RELOAD=0
PEND_RELOAD=0
WHY=""
M_MODE=""
M_UID=""
PL_ARG0=""
PL_ARG1=""
LD_ARGS=""
LD_RAW=""
F_BAD=0
F_UNK=0
TMP_FILES=()

say()  { printf '%s\n' "$*"; }
die()  { local rc="$1"; shift; printf 'ERRO: %s\n' "$*" >&2; exit "$rc"; }
f_ok()   { printf '  ok     %s\n' "$*"; }
f_bad()  { F_BAD=$((F_BAD+1)); printf '  FALHA  %s\n' "$*"; }
f_unk()  { F_UNK=$((F_UNK+1)); printf '  ?      %s\n' "$*"; }

cleanup() {
  local f
  for f in ${TMP_FILES[@]+"${TMP_FILES[@]}"}; do rm -f "$f" 2>/dev/null; done
}
trap cleanup EXIT

usage() {
  say "uso: sudo /bin/bash $0 --expect-sha256 <64 hex> [--no-reload]  (instala; o hash é obrigatório)"
  say "     /bin/bash $0 --check [--expect-sha256 <64 hex>]  (só lê e confere; sem root o launchd não é lido; não combina com --no-reload)"
}

# meta_of <caminho> → M_MODE (os 10 caracteres de `ls -l`) e M_UID numérico; rc 1 se não deu para ler.
meta_of() {
  local line="" mode="" links="" uid="" rest=""
  # vazio → rc 1, sem dono/modo não afirmo nada; falhou/ilegível → rc 1 também: quem chama RECUSA, nunca trata como seguro
  line=$(ls -ldn "$1" 2>/dev/null) || return 1
  [ -n "$line" ] || return 1
  read -r mode links uid rest <<< "$line"
  M_MODE="${mode:0:10}"
  M_UID="$uid"
  case "$M_MODE" in
    ([-dl][-rwxsStT][-rwxsStT][-rwxsStT][-rwxsStT][-rwxsStT][-rwxsStT][-rwxsStT][-rwxsStT][-rwxsStT]) ;;
    (*) return 1 ;;
  esac
  case "$M_UID" in
    (''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

# mode_loose <10 caracteres> → rc 0 se grupo ou outros podem gravar.
mode_loose() {
  [ "${1:5:1}" = "w" ] || [ "${1:8:1}" = "w" ]
}

# safe_node <caminho> <tipo: d|-> → rc 0 se é do root, não é symlink e grupo/outros não gravam; senão WHY e rc 1.
safe_node() {
  local p="$1" want="$2"
  WHY=""
  if [ -L "$p" ]; then WHY="$p é um symlink"; return 1; fi
  meta_of "$p" || { WHY="não consegui ler dono/modo de $p"; return 1; }
  if [ "${M_MODE:0:1}" != "$want" ]; then WHY="$p não é do tipo esperado ($M_MODE)"; return 1; fi
  if [ "$M_UID" != "$ROOT_UID" ]; then WHY="$p é do uid $M_UID, não do root ($ROOT_UID)"; return 1; fi
  if mode_loose "$M_MODE"; then WHY="$p é gravável por grupo/outros ($M_MODE)"; return 1; fi
  return 0
}

# walk_chain <dir de runtime> <cria: 0|1> → confere "/" e cada degrau até o dir; rc 0 se todos são do root e fechados.
# Com cria=1 cria SÓ o degrau que não existe (root:wheel 0755), e só debaixo de um degrau que acabou de ser conferido.
walk_chain() {
  local want="$1" create="$2" rest="" cur="" comp=""
  rest="${want#/}"
  cur="$ROOT_PFX"
  [ -n "$cur" ] || cur="/"
  while :; do
    if [ -e "$cur" ] || [ -L "$cur" ]; then
      safe_node "$cur" d || return 1
    elif [ "$create" = "1" ]; then
      install -d -o "$OWN_U" -g "$OWN_G" -m 0755 "$cur" 2>/dev/null || { WHY="não consegui criar $cur"; return 1; }
      safe_node "$cur" d || return 1
    else
      WHY="$cur não existe"
      return 1
    fi
    [ -n "$rest" ] || return 0
    comp="${rest%%/*}"
    if [ "$comp" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    cur="${cur%/}/$comp"
  done
}

# sha256_of <arquivo> → imprime os 64 hexadecimais; rc 1 sem imprimir nada se não deu.
sha256_of() {
  local out=""
  # vazio → rc 1; falhou/ilegível → rc 1 também: sem hash o --expect-sha256 recusa, nunca "hash vazio == hash esperado"
  if [ -x /usr/bin/shasum ]; then
    out=$(/usr/bin/shasum -a 256 "$1" 2>/dev/null) || return 1
  elif [ -x /usr/bin/sha256sum ]; then
    out=$(/usr/bin/sha256sum "$1" 2>/dev/null) || return 1
  else
    return 1
  fi
  out="${out%% *}"
  case "$out" in
    (''|*[!0-9a-f]*) return 1 ;;
  esac
  [ "${#out}" = "64" ] || return 1
  printf '%s\n' "$out"
}

# read_plist_layout <plist> → rc 0 com PL_ARG0/PL_ARG1; rc 1 com WHY se não é o formato conhecido
# (Label certo, ProgramArguments = [/bin/bash, <script>], sem terceiro item).
read_plist_layout() {
  local f="$1" lab="" a2=""
  PL_ARG0=""; PL_ARG1=""
  [ -f "$f" ] || { WHY="$f não existe"; return 1; }
  # vazio → Label diferente do esperado, recusa; falhou/ilegível → recusa: não edito plist que não sei ler
  lab=$("$PLISTBUDDY" -c "Print :Label" "$f" 2>/dev/null) || { WHY="não consegui ler :Label de $f"; return 1; }
  [ "$lab" = "$LABEL" ] || { WHY="o plist tem Label '$lab', esperado '$LABEL'"; return 1; }
  # vazio → recusa abaixo; falhou/ilegível → recusa: o formato é desconhecido
  PL_ARG0=$("$PLISTBUDDY" -c "Print :ProgramArguments:0" "$f" 2>/dev/null) || { WHY="não consegui ler ProgramArguments[0] de $f"; return 1; }
  PL_ARG1=$("$PLISTBUDDY" -c "Print :ProgramArguments:1" "$f" 2>/dev/null) || { WHY="não consegui ler ProgramArguments[1] de $f"; return 1; }
  [ "$PL_ARG0" = "$SHELL_BIN" ] || { WHY="ProgramArguments[0] é '$PL_ARG0', esperado '$SHELL_BIN'"; return 1; }
  [ -n "$PL_ARG1" ] || { WHY="ProgramArguments[1] está vazio em $f"; return 1; }
  # o terceiro item tem de NÃO existir (falhar aqui é o esperado: [0] e [1] acabaram de ler do mesmo arquivo)
  if a2=$("$PLISTBUDDY" -c "Print :ProgramArguments:2" "$f" 2>/dev/null); then
    WHY="ProgramArguments tem um 3º item ('$a2'): formato que este instalador não conhece"
    return 1
  fi
  return 0
}

# launchd_args → LD_ARGS = os argumentos que o launchd carregou, um por linha.
# rc 0 leu · 1 o launchctl falhou (serviço não carregado, ou sem root para ler) · 2 a saída não tem o bloco "arguments".
launchd_args() {
  local out=""
  LD_ARGS=""; LD_RAW=""
  # vazio → rc 2, não sei o que está carregado; falhou/ilegível → rc 1; nenhum dos dois vira "está certo"
  out=$("$LAUNCHCTL" print "system/$LABEL" 2>&1) || { LD_RAW="$out"; return 1; }
  LD_RAW="$out"
  LD_ARGS=$(printf '%s\n' "$out" | awk '
    { line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line) }
    inargs == 0 && done == 0 && line == "arguments = {" { inargs = 1; seen = 1; next }
    inargs == 1 && line == "}" { inargs = 0; done = 1; next }
    inargs == 1 { print line }
    END { if (!seen) exit 3 }
  ') || return 2
  return 0
}

# old_guard_loaded → rc 0 só se o launchd carregou EXATAMENTE "bash <caminho>/disk-snapshot-guard.sh" (a definição de antes desta
# instalação, que aponta para o guard do repo). vazio/ilegível/outra forma → rc 1: quem chama NÃO trata como pendência esperada.
old_guard_loaded() {
  local a0="" a1="" extra=""
  # vazio → a0 vazio e o teste abaixo dá rc 1; falhou/ilegível → idem: sem as duas linhas inteiras não afirmo que é a definição velha
  { IFS= read -r a0; IFS= read -r a1; IFS= read -r extra; } <<< "$LD_ARGS" || true
  [ "$a0" = "$SHELL_BIN" ] && [ -n "$a1" ] && [ -z "$extra" ] || return 1
  case "$a1" in
    (*/"$GUARD_NAME") return 0 ;;
  esac
  return 1
}

# audit_state — confere o estado instalado, só lendo. Imprime uma linha por achado; F_BAD/F_UNK contam.
# rc 0 tudo certo · 1 algum achado FALHA · 3 nenhuma falha, mas algo não deu para ler.
audit_state() {
  local want_args="" sha="" rc=0
  F_BAD=0; F_UNK=0
  want_args="$SHELL_BIN"$'\n'"$PROG_PATH"

  say "-- o que o root executa: $PROG_PATH"
  if walk_chain "$PROG_DIR" 0; then
    f_ok "cadeia de pastas até $PROG_DIR: do root, sem symlink, sem escrita de grupo/outros"
  else
    f_bad "$WHY"
  fi
  if [ -e "$PROG_FILE_REAL" ] || [ -L "$PROG_FILE_REAL" ]; then
    if safe_node "$PROG_FILE_REAL" -; then
      if [ -s "$PROG_FILE_REAL" ]; then f_ok "$PROG_PATH: arquivo do root, $M_MODE, não vazio"; else f_bad "$PROG_PATH está vazio"; fi
    else
      f_bad "$WHY"
    fi
  else
    f_bad "$PROG_PATH não existe"
  fi
  if [ -n "$PIN" ]; then
    # vazio → n/a (PIN não vazio aqui); falhou/ilegível → FALHA: sem hash não provo que é o revisado
    if sha=$(sha256_of "$PROG_FILE_REAL"); then
      if [ "$sha" = "$PIN" ]; then f_ok "sha256 da cópia instalada confere com o --expect-sha256"; else f_bad "sha256 da cópia instalada ($sha) difere do --expect-sha256 ($PIN)"; fi
    else
      f_bad "não consegui calcular o sha256 de $PROG_PATH para comparar com o --expect-sha256"
    fi
  fi

  say "-- o que manda o root executar: $PLIST_PATH"
  if safe_node "$PLIST_REAL" -; then
    f_ok "plist do root, $M_MODE"
  else
    f_bad "$WHY"
  fi
  if walk_chain "${PLIST_PATH%/*}" 0; then
    f_ok "cadeia de pastas até ${PLIST_PATH%/*}: do root, sem symlink, sem escrita de grupo/outros"
  else
    f_bad "$WHY"
  fi
  if read_plist_layout "$PLIST_REAL"; then
    if [ "$PL_ARG1" = "$PROG_PATH" ]; then
      f_ok "ProgramArguments = $PL_ARG0 $PL_ARG1"
    else
      f_bad "o plist manda o root executar $PL_ARG1 (esperado $PROG_PATH)"
    fi
  else
    f_bad "$WHY"
  fi

  say "-- o que o launchd carregou (launchctl print system/$LABEL)"
  launchd_args; rc=$?
  case "$rc" in
    (0)
      if [ "$LD_ARGS" = "$want_args" ]; then
        f_ok "argumentos carregados: $SHELL_BIN $PROG_PATH"
      elif [ "$NO_RELOAD" = "1" ] && old_guard_loaded; then
        # --no-reload (só existe ao instalar): o job que roda este instalador não pode ser descarregado no meio da rodada; a
        # definição velha segue carregada e a nova vale no próximo carregamento (reboot ou bootout+bootstrap). Pendência, não falha.
        PEND_RELOAD=1
        printf '  pend   o launchd ainda tem a definição antiga carregada (argumentos: %s)\n' "$(printf '%s' "$LD_ARGS" | tr '\n' ' ')"
      elif [ "$NO_RELOAD" = "1" ]; then
        # carregado não é a nova NEM a anterior do guard: "pend" esconderia isso. Não sei quando a cópia do root passa a valer.
        f_unk "o launchd carregou algo que não é nem a definição nova nem a anterior do guard (argumentos: $(printf '%s' "$LD_ARGS" | tr '\n' ' ')): confira com launchctl print"
      else
        f_bad "o launchd carregou outra definição (argumentos: $(printf '%s' "$LD_ARGS" | tr '\n' ' ')): recarregue com bootout + bootstrap"
      fi ;;
    (1) f_unk "launchctl print falhou (serviço não carregado, ou rode com sudo para ler o domínio system)" ;;
    (*) f_unk "launchctl print respondeu sem o bloco 'arguments': não sei o que está carregado" ;;
  esac

  if [ "$F_BAD" -gt 0 ]; then return 1; fi
  if [ "$F_UNK" -gt 0 ]; then return 3; fi
  return 0
}

# stage_copy <origem> <temporário na pasta do root> <modo> — cópia com dono e modo do root, conferida byte a byte.
stage_copy() {
  local src="$1" tmp="$2" mode="$3"
  install -m "$mode" -o "$OWN_U" -g "$OWN_G" "$src" "$tmp" 2>/dev/null || return 1
  cmp -s "$src" "$tmp" || return 1
}

# reload_job — bootout (o rc só é registrado: serviço já descarregado também sai ≠ 0) e bootstrap com tentativas.
reload_job() {
  local i=1 rc=0
  "$LAUNCHCTL" bootout "system/$LABEL" >/dev/null 2>&1; rc=$?
  say "  launchctl bootout system/$LABEL → rc=$rc"
  while [ "$i" -le "$BOOT_TRIES" ]; do
    if "$LAUNCHCTL" bootstrap system "$PLIST_REAL" >/dev/null 2>&1; then
      say "  launchctl bootstrap system $PLIST_PATH → ok (tentativa $i)"
      return 0
    fi
    say "  launchctl bootstrap system $PLIST_PATH → falhou (tentativa $i de $BOOT_TRIES)"
    sleep "$RETRY_SLEEP"
    i=$((i+1))
  done
  return 1
}

# restore_original — devolve o plist guardado em $BACKUP; rc 0 só se o que ficou no lugar é idêntico ao backup.
restore_original() {
  local tmp="$PROG_DIR_REAL/.$LABEL.plist.restore.$$"
  TMP_FILES+=("$tmp")
  stage_copy "$BACKUP" "$tmp" 0644 || return 1
  mv -f "$tmp" "$PLIST_REAL" 2>/dev/null || return 1
  cmp -s "$BACKUP" "$PLIST_REAL"
}

do_install() {
  local c="" src_sha="" copy_sha="" stamp="" tmp_copy="" tmp_plist="" old_arg1="" needs_edit=1 rc=0 undo=""
  BACKUP=""

  say "== instalador do disk-snapshot-guard (root) =="
  for c in install cmp awk ls cp mv rm chmod chown sed tr date sleep dirname; do
    command -v "$c" >/dev/null 2>&1 || die 1 "falta o comando '$c' no PATH fixo ($PATH): nada foi alterado"
  done
  [ -x "$LAUNCHCTL" ] || die 1 "não achei $LAUNCHCTL: nada foi alterado"
  [ -x "$PLISTBUDDY" ] || die 1 "não achei $PLISTBUDDY: nada foi alterado"

  # --- 1. só leitura: a fonte, o plist e as pastas do plist ---
  [ -L "$SRC" ] && die 1 "$SRC é um symlink: o root não copia o que um symlink do repo aponta. Nada foi alterado"
  [ -f "$SRC" ] || die 1 "não achei $SRC ao lado do instalador. Nada foi alterado"
  [ -s "$SRC" ] || die 1 "$SRC está vazio. Nada foi alterado"
  # vazio → n/a; falhou/ilegível → recusa: sem o hash da fonte não confirmo que é o arquivo revisado (aqui o --expect-sha256 é obrigatório)
  src_sha=$(sha256_of "$SRC") || die 1 "não consegui calcular o sha256 de $SRC para conferir o --expect-sha256. Nada foi alterado"
  say "  fonte: $SRC (sha256 $src_sha)"
  [ "$src_sha" = "$PIN" ] || die 1 "o sha256 de $SRC ($src_sha) difere do --expect-sha256 ($PIN): o arquivo do repo mudou depois da revisão. Nada foi alterado"

  safe_node "$PLIST_REAL" - || die 1 "$WHY: o plist tem de ser do root. Nada foi alterado"
  read_plist_layout "$PLIST_REAL" || die 1 "$WHY. Nada foi alterado"
  case "$PL_ARG1" in
    ("$PROG_PATH") needs_edit=0 ;;
    (*/"$GUARD_NAME") needs_edit=1 ;;
    (*) die 1 "ProgramArguments[1] aponta para '$PL_ARG1', que não é o $GUARD_NAME: não mexo. Nada foi alterado" ;;
  esac
  walk_chain "${PLIST_PATH%/*}" 0 || die 1 "$WHY: a pasta do plist tem de ser do root. Nada foi alterado"

  # --- 2. a pasta do root (único passo que cria algo, e só o que falta) ---
  walk_chain "$PROG_DIR" 1 || die 1 "$WHY. Para corrigir uma pasta que já existia, rode você mesmo: sudo chown root:wheel <pasta> && sudo chmod 755 <pasta>. O root não executa nada novo"

  # --- 3. a cópia: temporário na pasta do root, conferido, rename ---
  tmp_copy="$PROG_DIR_REAL/.$GUARD_NAME.new.$$"
  TMP_FILES+=("$tmp_copy")
  # a cópia nasce 0700 (só do root) e só vira 0755 depois de o sha256 dela conferir: se o arquivo do athos for trocado no meio
  # do caminho por um symlink para algo do root, o que o root leu não fica legível por outro e o hash recusa
  stage_copy "$SRC" "$tmp_copy" 0700 || die 1 "não consegui copiar $SRC para $PROG_DIR (ou a fonte mudou durante a cópia). O root não executa nada novo"
  if [ -n "$PIN" ]; then
    # vazio → n/a; falhou/ilegível → recusa: a cópia é a prova, e sem hash dela não há prova
    copy_sha=$(sha256_of "$tmp_copy") || die 1 "não consegui calcular o sha256 da cópia para conferir o --expect-sha256. O root não executa nada novo"
    [ "$copy_sha" = "$PIN" ] || die 1 "o sha256 da cópia ($copy_sha) difere do --expect-sha256 ($PIN). O root não executa nada novo"
  fi
  safe_node "$tmp_copy" - || die 1 "$WHY. O root não executa nada novo"
  chmod 0755 "$tmp_copy" || die 1 "não consegui dar 0755 à cópia em $PROG_DIR. O root não executa nada novo"
  if [ -d "$PROG_FILE_REAL" ] && [ ! -L "$PROG_FILE_REAL" ]; then
    die 1 "$PROG_PATH é um diretório: não substituo. O root não executa nada novo"
  fi
  # o mv sobre um symlink de arquivo trocaria o alvo; troca-se o próprio nome (a pasta é do root, ninguém mais põe link ali)
  if [ -L "$PROG_FILE_REAL" ]; then rm -f "$PROG_FILE_REAL" || die 1 "não consegui remover o symlink $PROG_PATH. O root não executa nada novo"; fi
  mv -f "$tmp_copy" "$PROG_FILE_REAL" || die 1 "não consegui colocar a cópia em $PROG_PATH. O plist não foi alterado"
  safe_node "$PROG_FILE_REAL" - || die 3 "$WHY (depois do rename): confira à mão $PROG_PATH"
  say "  copiado: $PROG_PATH"

  # --- 4. o plist: backup, edição num temporário, releitura, rename ---
  if [ "$needs_edit" = "1" ]; then
    old_arg1="$PL_ARG1"
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    BACKUP="$PROG_DIR_REAL/$LABEL.plist.orig-$stamp-$$"
    stage_copy "$PLIST_REAL" "$BACKUP" 0644 || die 1 "não consegui guardar o plist original em $BACKUP. O plist não foi alterado"
    tmp_plist="$PROG_DIR_REAL/.$LABEL.plist.new.$$"
    TMP_FILES+=("$tmp_plist")
    stage_copy "$PLIST_REAL" "$tmp_plist" 0644 || die 1 "não consegui preparar a cópia de trabalho do plist. O plist não foi alterado"
    "$PLISTBUDDY" -c "Set :ProgramArguments:1 $PROG_PATH" "$tmp_plist" >/dev/null 2>&1 || die 1 "PlistBuddy não conseguiu trocar ProgramArguments[1]. O plist não foi alterado"
    read_plist_layout "$tmp_plist" || die 1 "$WHY (depois da edição). O plist não foi alterado"
    [ "$PL_ARG1" = "$PROG_PATH" ] || die 1 "depois da edição ProgramArguments[1] é '$PL_ARG1'. O plist não foi alterado"
    chown "$ROOT_OWNER" "$tmp_plist" && chmod 0644 "$tmp_plist" || die 1 "não consegui devolver o plist editado a $ROOT_OWNER 0644. O plist não foi alterado"
    mv -f "$tmp_plist" "$PLIST_REAL" || die 3 "o rename do plist falhou: confira $PLIST_PATH (o original está em $BACKUP)"
    say "  plist: ProgramArguments[1] $old_arg1 → $PROG_PATH (original guardado em $BACKUP)"
  else
    say "  plist: já aponta para $PROG_PATH, nada a trocar"
  fi

  # --- 5. recarrega; se não carregar, volta ao plist anterior ---
  if [ "$NO_RELOAD" = "1" ]; then
    say "  launchctl: sem bootout/bootstrap (--no-reload): o plist novo vale no próximo carregamento do job"
  elif ! reload_job; then
    if [ -z "$BACKUP" ]; then
      die 3 "o launchd não carregou o job e não houve edição para desfazer: o guard pode estar DESCARREGADO. Rode: sudo launchctl bootstrap system $PLIST_PATH"
    fi
    say "  o bootstrap não passou depois de $BOOT_TRIES tentativas: devolvo o plist original"
    if restore_original; then
      if reload_job; then
        die 1 "o launchd não aceitou o plist novo. Voltei ao plist original e o job está carregado como antes (o root segue executando o arquivo do repo). Veja a saída acima"
      fi
      die 3 "o launchd não aceitou o plist novo; devolvi o plist original mas o job não recarregou: o guard pode estar DESCARREGADO. Rode: sudo launchctl bootstrap system $PLIST_PATH"
    fi
    die 3 "o launchd não aceitou o plist novo e não consegui devolver o original: o guard pode estar DESCARREGADO. Original em $BACKUP; para voltar: sudo cp $BACKUP $PLIST_PATH && sudo launchctl bootstrap system $PLIST_PATH"
  fi

  # --- 6. confere de novo, do zero ---
  say "== conferência =="
  audit_state; rc=$?
  if [ -n "$BACKUP" ]; then
    undo="para desfazer: sudo launchctl bootout system/$LABEL; sudo cp $BACKUP $PLIST_PATH; sudo launchctl bootstrap system $PLIST_PATH"
  fi
  case "$rc" in
    (0) if [ "$PEND_RELOAD" = "1" ]; then
          say "RESULTADO: instalado e confirmado no disco. O root só passa a executar $PROG_PATH quando o launchd carregar o plist de novo."
        else
          say "RESULTADO: instalado e confirmado. O root agora executa $PROG_PATH."
        fi ;;
    (1) say "RESULTADO: instalado, mas a conferência achou FALHA (acima)." ;;
    (*) say "RESULTADO: instalado, mas algo não deu para confirmar (acima): confira com --check." ;;
  esac
  if [ "$PEND_RELOAD" = "1" ]; then say "RECARGA PENDENTE: o job carregado segue com a definição antiga até o próximo carregamento do launchd (reboot, ou bootout + bootstrap)."; fi
  if [ -n "$undo" ]; then say "$undo"; fi
  return "$rc"
}

# --- argumentos ---
while [ $# -gt 0 ]; do
  case "$1" in
    (--check) MODE="check"; shift ;;
    (--no-reload) NO_RELOAD=1; shift ;;
    (--expect-sha256)
      [ $# -ge 2 ] || die 2 "--expect-sha256 pede o hash (64 hexadecimais)"
      PIN="$2"; shift 2 ;;
    (-h|--help) usage; exit 0 ;;
    (*) usage >&2; die 2 "argumento desconhecido: $1" ;;
  esac
done
if [ -n "$PIN" ]; then
  PIN=$(printf '%s' "$PIN" | tr 'A-F' 'a-f')
  case "$PIN" in
    (*[!0-9a-f]*) die 2 "--expect-sha256 só aceita hexadecimais" ;;
  esac
  [ "${#PIN}" = "64" ] || die 2 "--expect-sha256 pede 64 hexadecimais (sha256), recebi ${#PIN}"
fi
# --no-reload só existe para instalar: com --check o "pend" transformaria "o launchd ainda roda a definição velha" (FALHA) em "seguro"
if [ "$MODE" = "check" ] && [ "$NO_RELOAD" = "1" ]; then
  usage >&2
  die 2 "--no-reload só vale ao instalar: com --check ele esconderia que o launchd ainda roda a definição velha. Nada foi alterado"
fi
# vazio → instalar sem hash é recusado (o root copia um arquivo de pasta do athos: sem hash não há prova do que entra); falhou → n/a, é teste de string
if [ "$MODE" = "install" ] && [ -z "$PIN" ]; then
  usage >&2
  die 2 "instalar exige --expect-sha256 <64 hex> (o shasum -a 256 do $GUARD_NAME revisado): o root lê esse arquivo de uma pasta do athos e só instala o que tem esse hash. Nada foi alterado"
fi

# vazio → sem a pasta do instalador não há fonte para copiar, recusa; falhou/ilegível → idem
SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || die 1 "não consegui resolver a pasta do instalador"
SRC="$SRC_DIR/$GUARD_NAME"

if [ "$MODE" = "check" ]; then
  [ -x "$PLISTBUDDY" ] || die 1 "não achei $PLISTBUDDY: não consigo ler o plist"
  say "== auditoria do disk-snapshot-guard (somente leitura) =="
  audit_state; rc=$?
  case "$rc" in
    (0) say "RESULTADO: seguro. O root executa $PROG_PATH, que ninguém além do root grava." ;;
    (1) say "RESULTADO: NÃO seguro ou NÃO instalado (FALHA acima)." ;;
    (*) say "RESULTADO: sem falha, mas algo não deu para confirmar (? acima)." ;;
  esac
  exit "$rc"
fi

if [ "$MY_UID" != "$ROOT_UID" ]; then
  die 2 "rode como root: sudo /bin/bash $0 ... (sem root o instalador não escreve em $PROG_DIR nem em ${PLIST_PATH%/*}). Nada foi alterado"
fi
do_install
exit $?
