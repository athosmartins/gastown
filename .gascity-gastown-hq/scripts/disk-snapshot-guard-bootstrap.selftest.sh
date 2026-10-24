#!/bin/bash
# disk-snapshot-guard-bootstrap.selftest.sh — ga-xpswpd.2 (pai ga-xpswpd)
#
# Contents
#   O que prova · ga-sgt7ls (achados não bloqueantes do gate) · Como é hermético · Saída
#
# O QUE PROVA: o bloco do topo do disk-snapshot-guard.sh, quando roda como ROOT e a cópia do root ainda não está confirmada,
#   executa UMA vez o instalador (--no-reload) com o hash fixado neste commit, e depois não faz mais nada. E o contrário, que
#   dá dentes ao teste: instalador adulterado, ausente ou symlink = NADA instalado e o guard segue (rc 0); sem root = nada, e um
#   $EUID importado do ambiente não muda o que roda (o uid vem de `id -u`); na rodada 1 o launchctl falso NUNCA recebe
#   bootout/bootstrap (a rodada não é morta no meio e o job não fica descarregado); a segunda rodada e a rodada da própria
#   cópia do root não chamam o instalador. Mutantes: o mesmo núcleo contra cópias do guard com uma proteção desligada, mais um
#   mutante NULO (nada muda) que tem de SOBREVIVER: sem esse controle limpo, "mutante morto" não prova nada.
#
# ga-sgt7ls (achados não bloqueantes do gate do ga-xpswpd.2), cada um com caso e mutante próprios:
#   (1) o bootstrap roda por ÚLTIMO: com o disco baixo a linha do thin (tmutil) vem ANTES da linha do bootstrap no log, e com o df ilegível o
#       guard ainda bootstrapa; (2) o instalador tem limite de tempo: um instalador pendurado (que até ignora TERM) é morto, não prende o guard
#       e não sobra processo; (3) backoff: instalador que falha NÃO roda de novo a cada rodada (20 min, 40, 80… teto 6 h), pin novo ou sucesso
#       limpam, e registro forjado (gravável por outros, lixo, pin alheio, futuro além do teto) é ignorado; (4) o plist tem de apontar para
#       ESTE arquivo (ilegível ou outro alvo = nada instalado); (5) com o log sem gravar (ENOSPC, pasta sumida) a linha vai para o stderr.
#
# COMO É HERMÉTICO: sem sudo, sem launchd, sem /usr/local nem /Library reais. Uma "raiz falsa" (DSG_ROOT_PFX) faz o papel de
#   "/", o uid de quem roda faz o papel do root (DSG_ROOT_UID, DSG_OWNER) e launchctl e PlistBuddy são stubs de bash. Os ganchos só
#   valem SEM root, por isso este selftest RECUSA rodar como root. Depois do bloco de bootstrap o guard segue para o rabo REAL
#   (df → tmutil → sleep 3 → sudo notify): com PATH na frente, o df é um stub SAUDÁVEL (o guard sai sem agir) e tmutil, sudo e
#   sleep são ALARMES que gravam a chamada e reprovam o teste; um caso de controle com disco baixo prova que os alarmes disparam.
#   O TMP é canonicalizado (pwd -P): o mktemp -d do macOS devolve /var/folders/… e o guard compara com /private/var/….
#
# SAÍDA: "Results: N passed, M failed"; exit 0 só com M = 0.

set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GUARD="${GUARD_UNDER_TEST:-$HERE/disk-snapshot-guard.sh}"
INSTALLER="${INSTALLER_UNDER_TEST:-$HERE/install-disk-snapshot-guard-root.sh}"
LABEL="com.gascity.disk-snapshot-guard"
WANT_ARG1="/usr/local/libexec/gascity/disk-snapshot-guard.sh"
PASS=0
FAIL=0
QUIET="${QUIET:-0}"

ok()  { PASS=$((PASS+1)); if [ "$QUIET" != "1" ]; then printf '  ok: %s\n' "$1"; fi; }
bad() { FAIL=$((FAIL+1)); if [ "$QUIET" != "1" ]; then printf '  BAD: %s\n     %s\n' "$1" "${2:-}"; fi; }

if [ "$(id -u)" = "0" ]; then
  echo "BAD: não rode este selftest como root: como root os ganchos DSG_* são ignorados e o guard mexeria em /usr/local e /Library de verdade"
  exit 2
fi
for f in "$GUARD" "$INSTALLER"; do
  [ -f "$f" ] || { echo "BAD: não achei $f"; echo "Results: 0 passed, 1 failed"; exit 1; }
done

TMP="$(mktemp -d)" || { echo "BAD: mktemp falhou"; exit 2; }
trap 'rm -rf "$TMP"' EXIT
# vazio/falhou → sem o caminho FÍSICO não sigo (exit 2): o guard compara `pwd -P` com prog_dir, e um TMP lógico (/var → /private/var) faria a
# "cópia do root" nunca casar consigo mesma e rodar o instalador (blocker 1 do gate); nunca prossigo com um TMP que não confirmei.
TMP="$(cd "$TMP" && pwd -P)" || { echo "BAD: não consegui canonicalizar o TMP"; exit 2; }
MY_UID="$(id -u)"
MY_OWNER="$(id -un):$(id -gn)"
STUBS="$TMP/stubs"
mkdir -p "$STUBS"

cat > "$STUBS/PlistBuddy" <<'STUB'
#!/bin/bash
# PlistBuddy falso: Print :chave / Set :chave valor sobre um arquivo de linhas chave=valor
[ "${1:-}" = "-c" ] || exit 2
cmd="${2:-}"; f="${3:-}"
[ -f "$f" ] || { echo "File Doesn't Exist: $f" >&2; exit 1; }
case "$cmd" in
  ("Print :"*)
    key="${cmd#Print :}"
    awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print; found = 1; exit } END { exit !found }' "$f" || exit 1 ;;
  ("Set :"*)
    rest="${cmd#Set :}"; key="${rest%% *}"; val="${rest#* }"
    awk -F= -v k="$key" -v v="$val" '$1 == k { print k "=" v; found = 1; next } { print } END { exit !found }' "$f" > "$f.stub.$$" \
      || { rm -f "$f.stub.$$"; exit 1; }
    cat "$f.stub.$$" > "$f"; rm -f "$f.stub.$$" ;;
  (*) exit 2 ;;
esac
STUB
cat > "$STUBS/launchctl" <<'STUB'
#!/bin/bash
# launchctl falso: o "job carregado" é $FAKE_LCTL_STATE/loaded.args; toda chamada fica em calls.log
S="${FAKE_LCTL_STATE:?}"
echo "$*" >> "$S/calls.log"
case "${1:-}" in
  (bootout) [ -f "$S/loaded.args" ] || exit 3; rm -f "$S/loaded.args" ;;
  (bootstrap) [ -f "$S/loaded.args" ] && exit 5
    awk -F= '$1 ~ /^ProgramArguments:[0-9]+$/ { sub(/^[^=]*=/, ""); print }' "${3:-}" > "$S/loaded.args" ;;
  (print)
    [ -f "$S/loaded.args" ] || exit 113
    echo "system/com.gascity.disk-snapshot-guard = {"; echo "	arguments = {"
    sed 's/^/		/' "$S/loaded.args"; echo "	}"; echo "}" ;;
  (*) exit 64 ;;
esac
STUB
chmod 0755 "$STUBS/PlistBuddy" "$STUBS/launchctl"

# Hermético de verdade (blocker 3 do gate). df SAUDÁVEL: o 4º campo (Available, em KB) é o que o guard lê, e FAKE_DF_KB baixa o disco só no caso de controle.
VIOL="$TMP/violations.log"; : > "$VIOL"
export FAKE_VIOLATIONS="$VIOL"
cat > "$STUBS/df" <<'STUB'
#!/bin/bash
# FAKE_DF_EMPTY=1 → df que não consegue ler (sem saída, rc 1): o guard cai no ramo "unknown state"
[ -z "${FAKE_DF_EMPTY:-}" ] || exit 1
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/fake 976490576 1000 ${FAKE_DF_KB:-900000000} 1% /System/Volumes/Data"
STUB
# tmutil, sudo e sleep são ALARMES: se o guard chegar neles, a chamada fica gravada em $FAKE_VIOLATIONS (nunca executam nada de verdade)
for n in tmutil sudo sleep; do
  printf '#!/bin/bash\necho "%s $*" >> "${FAKE_VIOLATIONS:?}"\nexit 0\n' "$n" > "$STUBS/$n"
done
chmod 0755 "$STUBS/df" "$STUBS/tmutil" "$STUBS/sudo" "$STUBS/sleep"
PATH="$STUBS:$PATH"; export PATH   # vale para TODA invocação do guard (a função de bootstrap fixa o próprio PATH, o instalador não vê os stubs)

sha_of() {
  local out=""
  # vazio → rc 1 sem imprimir; falhou/ilegível → rc 1 também: o caso que precisa do hash reprova, nunca aprova
  if [ -x /usr/bin/shasum ]; then out=$(/usr/bin/shasum -a 256 "$1" 2>/dev/null) || return 1
  else out=$(/usr/bin/sha256sum "$1" 2>/dev/null) || return 1
  fi
  printf '%s' "${out%% *}"
}
mode_of() { local l=""; l=$(ls -ldn "$1" 2>/dev/null) || return 1; set -- $l; printf '%s' "${1:0:10}"; }
uid_of()  { local l=""; l=$(ls -ldn "$1" 2>/dev/null) || return 1; set -- $l; printf '%s' "$3"; }
calls() { if [ -f "$ST/calls.log" ]; then wc -l < "$ST/calls.log" | tr -d ' '; else echo 0; fi; }
# vazio/sem arquivo → 0 chamadas ao instalador falso (o caso que conta chamadas reprova se o arquivo não existir quando devia)
n_inst() { if [ -f "$W/inst.calls" ]; then wc -l < "$W/inst.calls" | tr -d ' '; else echo 0; fi; }
# vazio/sem log → 0 linhas (o caso que compara "log não ganhou linha" compara com o 0 que ele mesmo mediu antes)
log_lines() { if [ -f "$W/guard.log" ]; then wc -l < "$W/guard.log" | tr -d ' '; else echo 0; fi; }

expect_rc()  { if [ "$RC" = "$1" ]; then ok "$2 (rc=$1)"; else bad "$2: rc=$RC, esperado $1" "$(printf '%s' "$OUT" | tail -n 5)"; fi; }
expect_out() { case "$OUT" in (*"$1"*) ok "$2" ;; (*) bad "$2: a saída não tem '$1'" "$(printf '%s' "$OUT" | tail -n 5)" ;; esac; }
expect_no_out() { case "$OUT" in (*"$1"*) bad "$2: a saída tem '$1'" "$(printf '%s' "$OUT" | tail -n 5)" ;; (*) ok "$2" ;; esac; }
expect_log() { if grep -q -F "$1" "$W/guard.log" 2>/dev/null; then ok "$2"; else bad "$2: o log não tem '$1'" "$(tail -n 4 "$W/guard.log" 2>/dev/null)"; fi; }

# --- mundo falso: raiz falsa, repo com o guard sob teste + o instalador, plist apontando para o repo ----------------------
new_world() {
  W=$(mktemp -d "$TMP/w.XXXXXX") || { echo "BAD: mktemp falhou"; exit 2; }
  ROOT="$W/root"; REPO="$W/repo"; ST="$W/lctl"
  PROG_D="$ROOT/usr/local/libexec/gascity"; PROG="$PROG_D/disk-snapshot-guard.sh"; MARK="$PROG_D/.disk-snapshot-guard.bootstrap-ok"
  PL="$ROOT/Library/LaunchDaemons/$LABEL.plist"
  STATE="$ROOT/var/db/com.gascity.disk-snapshot-guard.bootstrap-backoff"
  mkdir -p "$ROOT/usr/local" "$ROOT/Library/LaunchDaemons" "$ROOT/var/tmp" "$ROOT/var/db" "$REPO/scripts" "$ST"
  chmod 0755 "$W" "$ROOT" "$ROOT/usr" "$ROOT/usr/local" "$ROOT/Library" "$ROOT/Library/LaunchDaemons" "$ROOT/var" "$ROOT/var/tmp" "$ROOT/var/db"
  cp "$INSTALLER" "$REPO/scripts/install-disk-snapshot-guard-root.sh"
  # o guard sob teste leva o hash do instalador DESTE mundo (o hash do commit é conferido à parte, no caso estático)
  sed "s/^DSG_INSTALLER_SHA256=.*/DSG_INSTALLER_SHA256=\"$(sha_of "$INSTALLER")\"/" "$GUARD" > "$REPO/scripts/disk-snapshot-guard.sh"
  chmod 0755 "$REPO/scripts/disk-snapshot-guard.sh"
  printf 'Label=%s\nProgramArguments:0=/bin/bash\nProgramArguments:1=%s\nStartInterval=600\n' \
    "$LABEL" "$REPO/scripts/disk-snapshot-guard.sh" > "$PL"
  chmod 0644 "$PL"
  printf '/bin/bash\n%s\n' "$REPO/scripts/disk-snapshot-guard.sh" > "$ST/loaded.args"
}

# run_guard [VAR=valor ...]: uma rodada do guard como o "root" do teste
run_guard() {
  OUT=$(env DSG_ROOT_PFX="$ROOT" DSG_ROOT_UID="$MY_UID" DSG_OWNER="$MY_OWNER" DSG_LAUNCHCTL="$STUBS/launchctl" \
    DSG_PLISTBUDDY="$STUBS/PlistBuddy" DSG_RETRY_SLEEP=0 DSG_LOG="$W/guard.log" FAKE_LCTL_STATE="$ST" FAKE_INST_CALLS="$W/inst.calls" "$@" \
    /bin/bash "$REPO/scripts/disk-snapshot-guard.sh" 2>&1); RC=$?
}

# pin_installer: refixa no guard DESTE mundo o hash do instalador que está no repo do mundo
pin_installer() {
  sed -i.bak "s/^DSG_INSTALLER_SHA256=.*/DSG_INSTALLER_SHA256=\"$(sha_of "$REPO/scripts/install-disk-snapshot-guard-root.sh")\"/" "$REPO/scripts/disk-snapshot-guard.sh" \
    && rm -f "$REPO/scripts/disk-snapshot-guard.sh.bak"
}
# fake_installer <corpo>: troca o instalador do repo do mundo por um stub (cada chamada fica em $W/inst.calls) e refixa o hash no guard do mundo
fake_installer() {
  printf '#!/bin/bash\necho call >> "${FAKE_INST_CALLS:?}"\n%s\n' "$1" > "$REPO/scripts/install-disk-snapshot-guard-root.sh"
  pin_installer
}
# real_installer: devolve o instalador de verdade ao repo do mundo (e o hash dele ao guard)
real_installer() { cp "$INSTALLER" "$REPO/scripts/install-disk-snapshot-guard-root.sh"; pin_installer; }
# pin16: os 16 primeiros hexadecimais do hash fixado no guard do mundo (o prefixo que o registro de backoff guarda)
pin16() { sed -n 's/^DSG_INSTALLER_SHA256="\([0-9a-f]\{16\}\).*/\1/p' "$REPO/scripts/disk-snapshot-guard.sh" | head -n 1; }
# state_field <n>: o campo n do registro de backoff (vazio se o arquivo não existe)
state_field() { if [ -f "$STATE" ]; then awk -v n="$1" 'NR == 1 { print $n }' "$STATE"; fi; }

core() {
  # 1. rodada 1: instala
  new_world; run_guard
  expect_rc 0 "rodada 1: o guard termina bem"
  expect_out "RESULTADO: instalado e confirmado" "rodada 1: o instalador confirmou"
  if [ -f "$PROG" ] && cmp -s "$PROG" "$REPO/scripts/disk-snapshot-guard.sh"; then ok "rodada 1: a cópia do root é igual ao guard do repo"; else bad "rodada 1: a cópia do root não existe ou difere"; fi
  [ "$(uid_of "$PROG")" = "$MY_UID" ] && [ "$(mode_of "$PROG")" = "-rwxr-xr-x" ] && ok "rodada 1: cópia do root, 0755" || bad "rodada 1: dono/modo da cópia: $(uid_of "$PROG") $(mode_of "$PROG")"
  if grep -q "^ProgramArguments:1=$WANT_ARG1\$" "$PL"; then ok "rodada 1: o plist aponta para a cópia do root"; else bad "rodada 1: o plist ainda aponta para outro caminho" "$(cat "$PL")"; fi
  [ -f "$MARK" ] && [ "$(uid_of "$MARK")" = "$MY_UID" ] && ok "rodada 1: marcador do root gravado" || bad "rodada 1: sem marcador do root"
  if grep -q -E '^(bootout|bootstrap)' "$ST/calls.log" 2>/dev/null; then bad "rodada 1: o launchctl recebeu bootout/bootstrap (mata a rodada / descarrega o job)" "$(cat "$ST/calls.log")"; else ok "rodada 1: nenhum bootout/bootstrap (a rodada não é morta no meio)"; fi
  if [ "$(cat "$ST/loaded.args")" = "$(printf '/bin/bash\n%s' "$REPO/scripts/disk-snapshot-guard.sh")" ]; then ok "rodada 1: o job carregado segue carregado (definição velha até o próximo carregamento)"; else bad "rodada 1: o job carregado mudou ou sumiu"; fi
  expect_out "RECARGA PENDENTE" "rodada 1: a saída diz que a recarga está pendente"
  expect_log "instalador rc=0" "rodada 1: o log registra o rc do instalador"
  expect_log "RECARGA PENDENTE" "rodada 1: o log registra que a recarga está pendente (confirmado no disco não é o job já rodando a cópia)"
  expect_log "instalado e confirmado no disco" "rodada 1: o log não diz que o root já executa a cópia"
  if [ -z "$(ls -A "$ROOT/var/tmp")" ]; then ok "rodada 1: a pasta privada de trabalho foi removida"; else bad "rodada 1: sobrou lixo em /var/tmp" "$(ls -A "$ROOT/var/tmp")"; fi

  # 2. rodada 2: idempotente — o instalador nem é chamado
  cp "$PL" "$W/plist.before"; n=$(calls); nl=$(log_lines)
  run_guard
  expect_rc 0 "rodada 2: o guard termina bem"
  expect_no_out "instalador do disk-snapshot-guard" "rodada 2: o instalador não roda de novo"
  if [ "$(calls)" = "$n" ] && cmp -s "$PL" "$W/plist.before"; then ok "rodada 2: nenhuma chamada ao launchd e o plist não mudou"; else bad "rodada 2: mexeu em algo"; fi
  # silêncio total: sem linha nova no log e sem registro de backoff (o plist já aponta para a cópia do root, então se o bloco passasse do marcador ele reclamaria do alvo e entraria em backoff)
  if [ "$(log_lines)" = "$nl" ] && [ ! -e "$STATE" ]; then ok "rodada 2: silenciosa (nenhuma linha no log, nenhum registro de backoff)"; else bad "rodada 2: o bloco não parou no marcador" "$(tail -n 3 "$W/guard.log" 2>/dev/null)"; fi

  # 3. a própria cópia do root, mesmo sem marcador, nunca roda o instalador do repo
  #    O plist aponta para a cópia do root (como depois da rodada 1 de verdade): sem isso o alvo do plist (caso 15) já barraria o instalador e esta proteção nunca seria exercida.
  rm -f "$MARK"; n=$(calls); cp "$REPO/scripts/install-disk-snapshot-guard-root.sh" "$PROG_D/"
  sed -i.bak "s#^ProgramArguments:1=.*#ProgramArguments:1=$PROG#" "$PL" && rm -f "$PL.bak"
  OUT=$(env DSG_ROOT_PFX="$ROOT" DSG_ROOT_UID="$MY_UID" DSG_OWNER="$MY_OWNER" DSG_LAUNCHCTL="$STUBS/launchctl" DSG_PLISTBUDDY="$STUBS/PlistBuddy" \
    DSG_LOG="$W/guard.log" FAKE_LCTL_STATE="$ST" /bin/bash "$PROG" 2>&1); RC=$?
  expect_rc 0 "cópia do root: o guard termina bem"
  expect_no_out "instalador do disk-snapshot-guard" "cópia do root: não executa instalador nenhum"

  # 4. instalador adulterado (1 byte a mais): nada instalado, o guard segue
  new_world; printf '# x\n' >> "$REPO/scripts/install-disk-snapshot-guard-root.sh"; cp "$PL" "$W/plist.before"
  run_guard
  expect_rc 0 "instalador adulterado: o guard segue (rc 0)"
  if [ ! -e "$PROG" ] && [ ! -e "$MARK" ] && cmp -s "$PL" "$W/plist.before" && [ "$(calls)" = "0" ]; then ok "instalador adulterado: nada instalado (sem cópia, sem marcador, plist e launchd intactos)"; else bad "instalador adulterado: algo foi instalado"; fi
  expect_log "difere do fixado" "instalador adulterado: o log diz que o hash difere"

  # 5. instalador ausente / symlink
  new_world; rm -f "$REPO/scripts/install-disk-snapshot-guard-root.sh"; run_guard
  expect_rc 0 "instalador ausente: o guard segue (rc 0)"
  [ ! -e "$PROG" ] && [ ! -e "$MARK" ] && ok "instalador ausente: nada instalado" || bad "instalador ausente: algo foi instalado"
  new_world; mv "$REPO/scripts/install-disk-snapshot-guard-root.sh" "$W/real-installer.sh"; ln -s "$W/real-installer.sh" "$REPO/scripts/install-disk-snapshot-guard-root.sh"; run_guard
  expect_rc 0 "instalador symlink: o guard segue (rc 0)"
  [ ! -e "$PROG" ] && [ ! -e "$MARK" ] && ok "instalador symlink: recusado, nada instalado" || bad "instalador symlink: instalou"

  # 6. instalador de verdade que falha (a pasta /usr/local ficou gravável por outros → ele recusa com ERRO:): sem marcador, guard rc 0, o motivo no log.
  #    (Plist sumido não serve mais: o guard confere o alvo do plist ANTES de chamar o instalador, caso 15.)
  new_world; mkdir -p "$PROG_D"; chmod 0755 "$ROOT/usr/local/libexec" "$PROG_D"; chmod 0777 "$ROOT/usr/local"; run_guard
  expect_rc 0 "instalador falha: o guard segue (rc 0)"
  [ ! -e "$MARK" ] && ok "instalador falha: sem marcador (a próxima rodada tenta de novo)" || bad "instalador falha: gravou marcador"
  expect_log "ERRO:" "instalador falha: o log guarda o motivo (a linha ERRO: do instalador), não só o rc"

  # 7. sem root: nada. E $EUID importado do ambiente não vira root.
  new_world
  OUT=$(env DSG_ROOT_PFX="$ROOT" DSG_LAUNCHCTL="$STUBS/launchctl" DSG_PLISTBUDDY="$STUBS/PlistBuddy" DSG_LOG="$W/guard.log" FAKE_LCTL_STATE="$ST" \
    EUID=0 /bin/bash "$REPO/scripts/disk-snapshot-guard.sh" 2>&1); RC=$?
  expect_rc 0 "sem root (EUID=0 importado): o guard segue"
  [ ! -e "$PROG" ] && [ ! -e "$MARK" ] && [ "$(calls)" = "0" ] && ok "sem root (EUID=0 importado): nada instalado" || bad "sem root (EUID=0 importado): instalou"

  # 8. marcador que o root não confia (gravável por outros): o bloco não o aceita e confere de novo
  new_world; mkdir -p "$PROG_D"; chmod 0755 "$PROG_D"; : > "$MARK"; chmod 0666 "$MARK"
  run_guard
  expect_out "instalador do disk-snapshot-guard" "marcador gravável por outros: não vale, o instalador roda"

  # 9. $EUID importado não muda o que roda: com os ganchos o uid vem de `id -u`, e a rodada instala igual
  new_world; run_guard EUID=0
  expect_out "RESULTADO: instalado e confirmado" "EUID=0 no ambiente: o uid vem de id -u, a rodada instala igual"

  # 9b. o umask do ambiente não decide a confiança do marcador: com umask 000 (ou 002, o padrão de muita conta Linux) um marcador criado com `>` nasce 0666/0664, o
  #     bloco o recusa (escrita de grupo/outros) e o instalador rodaria de novo a cada rodada. O modo é explícito (0644), então a rodada 2 não reinstala.
  new_world; OLD_UMASK=$(umask); umask 000; run_guard; umask "$OLD_UMASK"
  expect_out "RESULTADO: instalado e confirmado" "umask 000: a rodada 1 instala"
  if [ "$(mode_of "$MARK")" = "-rw-r--r--" ]; then ok "umask 000: o marcador nasce -rw-r--r-- (modo explícito, não herdado do umask)"; else bad "umask 000: modo do marcador: $(mode_of "$MARK")"; fi
  run_guard
  expect_no_out "instalador do disk-snapshot-guard" "umask 000: a rodada 2 não roda o instalador de novo"

  # 10. controle dos alarmes: com o disco BAIXO o guard chega ao rabo real e cada alarme dispara. Sem isto, "nenhuma violação" nos outros casos não provaria que os stubs
  #     enxergam o rabo. A violação vai para um arquivo à parte e não suja a checagem de hermeticidade do núcleo.
  new_world; run_guard FAKE_DF_KB=2000000 FAKE_VIOLATIONS="$W/violations.low"
  expect_rc 0 "controle do disco baixo: o guard termina bem"
  for a in tmutil sleep sudo; do
    if grep -q "^$a " "$W/violations.low" 2>/dev/null; then ok "controle do disco baixo: o alarme '$a' disparou (os stubs enxergam o rabo do guard)"; else bad "controle do disco baixo: o alarme '$a' NÃO disparou" "$(cat "$W/violations.low" 2>/dev/null)"; fi
  done

  # 11. ga-sgt7ls (a): o bootstrap roda POR ÚLTIMO. Com o disco baixo o thin vem primeiro: a linha do tmutil fica ANTES da linha do bootstrap no log
  #     (e o log de teste cobre as linhas do thin: sem isso o teste escreveria no log verdadeiro da cidade).
  new_world; run_guard FAKE_DF_KB=2000000 FAKE_VIOLATIONS="$W/violations.low"
  expect_rc 0 "ordem (disco baixo): o guard termina bem"
  expect_out "RESULTADO: instalado e confirmado" "ordem (disco baixo): o bootstrap roda (depois do thin)"
  # vazio → o número fica vazio e o caso reprova: sem as duas linhas no log de teste não provo a ordem
  L_THIN=$(grep -n -F 'tmutil rc=' "$W/guard.log" 2>/dev/null | head -n 1 | cut -d: -f1)
  L_BOOT=$(grep -n -F 'bootstrap root:' "$W/guard.log" 2>/dev/null | head -n 1 | cut -d: -f1)
  if [ -n "$L_THIN" ] && [ -n "$L_BOOT" ] && [ "$L_THIN" -lt "$L_BOOT" ]; then ok "ordem (disco baixo): a linha do thin (log:$L_THIN) vem antes da do bootstrap (log:$L_BOOT)"; else bad "ordem (disco baixo): thin='$L_THIN' bootstrap='$L_BOOT'" "$(cat "$W/guard.log" 2>/dev/null)"; fi

  # 12. ga-sgt7ls (a): df ilegível → o guard sai pelo ramo "unknown state" (rc 0) e o bootstrap ainda roda
  new_world; run_guard FAKE_DF_EMPTY=1
  expect_rc 0 "df ilegível: o guard termina bem"
  expect_log "nao consegui ler df" "df ilegível: foi o ramo unknown state que rodou"
  expect_out "RESULTADO: instalado e confirmado" "df ilegível: o bootstrap roda mesmo assim"

  # 13. ga-sgt7ls (limite de tempo): instalador falso que pendura 30 s (finito: sem limite o teste não trava); limite do teste = 1 s
  new_world; fake_installer 'n=0; while [ "$n" -lt 30 ]; do /bin/sleep 1; n=$((n + 1)); done'
  t0=$SECONDS; run_guard DSG_INSTALL_TIMEOUT=1; el=$((SECONDS - t0))
  expect_rc 0 "instalador pendurado: o guard termina (rc 0)"
  if [ "$el" -lt 20 ]; then ok "instalador pendurado: o guard voltou em ${el}s (limite 1 s, o instalador penduraria 30 s)"; else bad "instalador pendurado: o guard demorou ${el}s (limite 1 s)"; fi
  expect_log "estourou 1s e foi morto" "instalador pendurado: o log diz que estourou o limite"
  [ ! -e "$MARK" ] && [ ! -e "$PROG" ] && ok "instalador pendurado: sem marcador e sem cópia" || bad "instalador pendurado: algo foi instalado"
  # vazio → nenhum processo do instalador sobrou (o esperado); o ps lista só o que tem a pasta privada deste mundo na linha de comando
  vivo=$(ps -ax -o command= 2>/dev/null | grep -F "$ROOT/var/tmp/dsg-bootstrap" | grep -v grep || true)
  if [ -z "$vivo" ]; then ok "instalador pendurado: nenhum processo do instalador sobrou"; else bad "instalador pendurado: sobrou processo" "$vivo"; fi
  if [ -z "$(ls -A "$ROOT/var/tmp")" ]; then ok "instalador pendurado: a pasta privada foi removida"; else bad "instalador pendurado: sobrou lixo em /var/tmp" "$(ls -A "$ROOT/var/tmp")"; fi
  [ -f "$STATE" ] && ok "instalador pendurado: o estouro conta como falha (registro de backoff gravado)" || bad "instalador pendurado: sem registro de backoff"

  # 14. ga-sgt7ls (backoff): instalador falso que sempre falha. O relógio do teste é o DSG_NOW (só vale sem root).
  new_world; fake_installer 'echo "ERRO: falha de teste"; exit 1'; P16=$(pin16)
  run_guard DSG_NOW=1000000
  expect_rc 0 "backoff, rodada 1: o guard segue (rc 0)"
  if [ "$(n_inst)" = "1" ]; then ok "backoff, rodada 1: o instalador rodou uma vez"; else bad "backoff, rodada 1: chamadas ao instalador=$(n_inst)"; fi
  if [ "$(state_field 1)" = "$P16" ] && [ "$(state_field 2)" = "1" ] && [ "$(state_field 3)" = "1001200" ]; then ok "backoff, rodada 1: registro = pin, 1 falha, próxima tentativa em +1200 s"; else bad "backoff, rodada 1: registro" "$(cat "$STATE" 2>/dev/null)"; fi
  if [ "$(mode_of "$STATE")" = "-rw-r--r--" ] && [ "$(uid_of "$STATE")" = "$MY_UID" ]; then ok "backoff: o registro é do root, 0644"; else bad "backoff: dono/modo do registro: $(uid_of "$STATE") $(mode_of "$STATE")"; fi
  expect_log "falha nº 1 seguida" "backoff, rodada 1: o log diz que entrou em backoff"
  n=$(log_lines); run_guard DSG_NOW=1000600
  if [ "$(n_inst)" = "1" ] && [ "$(log_lines)" = "$n" ]; then ok "backoff, dentro da espera: o instalador não roda e o log não ganha linha"; else bad "backoff, dentro da espera: chamadas=$(n_inst) linhas do log $n → $(log_lines)"; fi
  run_guard DSG_NOW=1001200
  if [ "$(n_inst)" = "2" ] && [ "$(state_field 2)" = "2" ] && [ "$(state_field 3)" = "1003600" ]; then ok "backoff, fim da espera: tenta de novo e a espera dobra (+2400 s)"; else bad "backoff, fim da espera: chamadas=$(n_inst)" "$(cat "$STATE" 2>/dev/null)"; fi
  run_guard DSG_NOW=1003599
  if [ "$(n_inst)" = "2" ]; then ok "backoff: um segundo antes do fim da espera ainda não tenta"; else bad "backoff: tentou cedo (chamadas=$(n_inst))"; fi
  run_guard DSG_NOW=1003600
  if [ "$(n_inst)" = "3" ] && [ "$(state_field 2)" = "3" ] && [ "$(state_field 3)" = "1008400" ]; then ok "backoff: 3ª falha, espera de +4800 s"; else bad "backoff: 3ª falha" "$(cat "$STATE" 2>/dev/null)"; fi
  # teto: a 6ª falha seguida espera 21600 s, não 38400
  printf '%s 5 %s\n' "$P16" 2000000 > "$STATE"; chmod 0644 "$STATE"
  run_guard DSG_NOW=2000000
  if [ "$(state_field 2)" = "6" ] && [ "$(state_field 3)" = "2021600" ]; then ok "backoff: a espera tem teto de 21600 s"; else bad "backoff: teto" "$(cat "$STATE" 2>/dev/null)"; fi
  # pin novo: o instalador de verdade (outro hash) tenta JÁ, mesmo dentro da espera do pin velho; o sucesso apaga o registro
  real_installer; run_guard DSG_NOW=2000001
  expect_out "RESULTADO: instalado e confirmado" "backoff, pin novo: tenta já, mesmo dentro da espera do pin velho"
  if [ ! -e "$STATE" ] && [ -f "$MARK" ]; then ok "backoff, sucesso: o registro foi apagado e o marcador gravado"; else bad "backoff, sucesso: registro/marcador" "$(ls -A "$ROOT/var/db")"; fi
  # mesmo pin: dentro da espera não instala; no fim da espera instala e apaga o registro
  new_world; P16=$(pin16); printf '%s 3 %s\n' "$P16" 1000000 > "$STATE"; chmod 0644 "$STATE"
  run_guard DSG_NOW=999999
  if [ ! -e "$MARK" ] && [ ! -e "$PROG" ]; then ok "backoff, mesmo pin: dentro da espera nada é instalado"; else bad "backoff, mesmo pin: instalou dentro da espera"; fi
  run_guard DSG_NOW=1000000
  expect_out "RESULTADO: instalado e confirmado" "backoff, mesmo pin: no fim da espera o instalador roda"
  if [ ! -e "$STATE" ]; then ok "backoff, mesmo pin: o sucesso apaga o registro"; else bad "backoff, mesmo pin: o registro sobrou" "$(cat "$STATE")"; fi
  # registro que o root não pode confiar (ou que não é nosso) é IGNORADO: o instalador tenta
  for variant in gravavel lixo futuro outro-pin ilegivel; do
    new_world; fake_installer 'echo "ERRO: falha de teste"; exit 1'; P16=$(pin16)
    case "$variant" in
      (gravavel)  printf '%s 1 %s\n' "$P16" 1001000 > "$STATE"; chmod 0666 "$STATE" ;;
      (lixo)      printf 'isto nao e um registro\n' > "$STATE"; chmod 0644 "$STATE" ;;
      (futuro)    printf '%s 1 %s\n' "$P16" 99999999999 > "$STATE"; chmod 0644 "$STATE" ;;
      (outro-pin) printf '0123456789abcdef 1 %s\n' 1001000 > "$STATE"; chmod 0644 "$STATE" ;;
      # registro válido que ADIARIA a tentativa (retry em 1001000, agora 1000000), mas do root e sem leitura (modo 0000): o read falha → sem registro → tenta já
      (ilegivel)  printf '%s 1 %s\n' "$P16" 1001000 > "$STATE"; chmod 0000 "$STATE" ;;
    esac
    run_guard DSG_NOW=1000000
    if [ "$(n_inst)" = "1" ]; then ok "backoff: registro '$variant' é ignorado e o instalador tenta"; else bad "backoff: registro '$variant' adiou a tentativa (chamadas=$(n_inst))"; fi
  done

  # 15. ga-sgt7ls (item b): o plist tem de apontar para ESTE arquivo; outro alvo ou plist ilegível = nada instalado
  new_world; sed -i.bak "s#^ProgramArguments:1=.*#ProgramArguments:1=/outro/lugar/disk-snapshot-guard.sh#" "$PL" && rm -f "$PL.bak"; cp "$PL" "$W/plist.before"
  run_guard
  expect_rc 0 "plist com outro alvo: o guard segue (rc 0)"
  if [ ! -e "$PROG" ] && [ ! -e "$MARK" ] && [ "$(calls)" = "0" ] && cmp -s "$PL" "$W/plist.before"; then ok "plist com outro alvo: nada instalado (sem cópia, sem marcador, plist e launchd intactos)"; else bad "plist com outro alvo: algo foi instalado"; fi
  expect_log "não aponta para este arquivo" "plist com outro alvo: o log diz por quê"
  [ -f "$STATE" ] && ok "plist com outro alvo: conta como falha (backoff)" || bad "plist com outro alvo: sem registro de backoff"
  new_world; rm -f "$PL"; run_guard
  expect_rc 0 "plist ilegível: o guard segue (rc 0)"
  if [ ! -e "$PROG" ] && [ ! -e "$MARK" ]; then ok "plist ilegível: nada instalado"; else bad "plist ilegível: algo foi instalado"; fi
  expect_log "não aponta para este arquivo" "plist ilegível: o log diz por quê"

  # 16. ga-sgt7ls (item c): com o log sem gravar (pasta sumida), a linha do bootstrap vai para o stderr em vez de sumir
  new_world; rm -f "$PL"; run_guard DSG_LOG="$W/sem-pasta/guard.log"
  expect_rc 0 "log sem gravar: o guard segue (rc 0)"
  expect_out "disk-snapshot-guard: bootstrap root: SKIP" "log sem gravar: a linha SKIP foi para o stderr"
  expect_no_out "No such file" "log sem gravar: nenhum ruído de redirecionamento solto"
}

# killcase: instalador que IGNORA o TERM (e o filho dele também) tem de ser morto com KILL; roda uma vez e tem o próprio mutante (custa ~4 s, por isso fora do núcleo)
killcase() {
  new_world; fake_installer 'trap "" TERM; n=0; while [ "$n" -lt 30 ]; do /bin/sleep 1; n=$((n + 1)); done'
  t0=$SECONDS; run_guard DSG_INSTALL_TIMEOUT=1; el=$((SECONDS - t0))
  expect_rc 0 "instalador que ignora TERM: o guard termina (rc 0)"
  if [ "$el" -lt 20 ]; then ok "instalador que ignora TERM: o guard voltou em ${el}s"; else bad "instalador que ignora TERM: o guard demorou ${el}s"; fi
  vivo=$(ps -ax -o command= 2>/dev/null | grep -F "$ROOT/var/tmp/dsg-bootstrap" | grep -v grep || true)
  if [ -z "$vivo" ]; then ok "instalador que ignora TERM: morto com KILL (nenhum processo sobrou)"; else bad "instalador que ignora TERM: sobrou processo" "$vivo"; fi
}

core
killcase
# vazio (log sem linhas) → o guard parou no bloco de bootstrap em todos os casos; qualquer linha → chegou ao rabo real (tmutil/sudo/sleep) e o teste reprova
if [ ! -s "$VIOL" ]; then ok "hermético: em todos os casos o guard parou antes do rabo real (nenhuma chamada a tmutil/sudo/sleep)"; else bad "hermético: o guard chegou ao rabo real" "$(head -n 5 "$VIOL")"; fi

# --- mutantes: o mesmo núcleo contra cópias do guard com UMA proteção desligada por vez; cada um tem de ser pego -------------
# core_fails <guard> [função]: roda o núcleo (ou a função dada) sob esse guard na MESMA subshell dos mutantes e imprime o nº de falhas, ou "?" se nem terminou
core_fails() {
  local n=""
  n=$( ( GUARD="$1"; QUIET=1; PASS=0; FAIL=0; "${2:-core}" >/dev/null 2>&1; echo "$FAIL" ) 2>/dev/null ) || n="?"
  case "$n" in (''|*[!0-9]*) n="?" ;; esac
  printf '%s' "$n"
}
# mutant_file <guard> <saída> <texto antigo> <texto novo>: rc 0 só se o antigo aparece em exatamente 1 linha
mutant_file() {
  awk -v old="$3" -v new="$4" '
    { i = index($0, old); if (i > 0) { c++; $0 = substr($0, 1, i-1) new substr($0, i+length(old)) } print }
    END { exit (c == 1 ? 0 : 3) }' "$1" > "$2"
}
# CONTROLE (blocker 2 do gate): um mutante NULO (texto novo == antigo) passa pelo MESMO awk, arquivo e subshell e tem de SOBREVIVER com o guard idêntico. Se ele reprovar,
# o baseline está sujo e toda "morte" abaixo seria vazia (um baseline que reprova mata qualquer mutante); falhou/não terminou ("?") conta como sujo.
NULL_FILE="$TMP/mut-nulo.sh"; NULL_FAILS="?"
if mutant_file "$GUARD" "$NULL_FILE" 'set -uo pipefail' 'set -uo pipefail' && cmp -s "$GUARD" "$NULL_FILE"; then NULL_FAILS="$(core_fails "$NULL_FILE")"; fi
if [ "$NULL_FAILS" = "0" ]; then ok "controle: o mutante NULO (nada muda) sobrevive e o núcleo passa limpo pela subshell dos mutantes"; else bad "controle: o mutante NULO não sobreviveu limpo (falhas=$NULL_FAILS): nenhuma morte de mutante abaixo vale"; fi
# Os mutantes rodam em paralelo (MUTANT_JOBS, padrão 4): cada um tem o próprio mundo em $TMP/w.* e escreve o resultado em $MUT_DIR/<nome>.res; o relatório sai em ordem no fim.
# O nº de rodando = lançados − .res existentes (nunca `jobs` dentro de $(...), que roda em subshell). `sleep` aqui é o /bin/sleep: o `sleep` do PATH é o alarme.
MUTANT_JOBS="${MUTANT_JOBS:-4}"; MUT_DIR="$TMP/mut-res"; mkdir -p "$MUT_DIR"; MUT_NAMES=""; MUT_LAUNCHED=0
mut_running() { local done_n=0; done_n=$(ls "$MUT_DIR" 2>/dev/null | grep -c '\.res$'); echo $((MUT_LAUNCHED - done_n)); }
mutate_with() { # <função do núcleo> <nome> <texto antigo> <texto novo>: o antigo tem de aparecer em exatamente 1 linha do guard
  local fn="$1" name="$2" out="$TMP/mut-$2.sh"
  mutant_file "$GUARD" "$out" "$3" "$4" || { bad "mutante $name: o texto antigo não aparece em exatamente 1 linha"; return 0; }
  if [ "$NULL_FAILS" != "0" ]; then bad "mutante $name: sem baseline limpo (o controle nulo reprovou), 'morto' não prova nada"; return 0; fi
  while [ "$(mut_running)" -ge "$MUTANT_JOBS" ]; do /bin/sleep 0.5; done
  ( f="$(core_fails "$out" "$fn")"; printf '%s' "$f" > "$MUT_DIR/$name.tmp"; mv "$MUT_DIR/$name.tmp" "$MUT_DIR/$name.res" ) &
  MUT_LAUNCHED=$((MUT_LAUNCHED + 1)); MUT_NAMES="$MUT_NAMES $name"
}
mutate() { mutate_with core "$@"; }
mutants_report() {
  local name="" f=""
  wait
  for name in $MUT_NAMES; do
    # vazio/ausente → "?" (inconclusivo, reprova): o resultado do mutante não chegou
    f=$(cat "$MUT_DIR/$name.res" 2>/dev/null) || f="?"
    case "$f" in (0) bad "mutante $name SOBREVIVEU" ;; (''|'?') bad "mutante $name: o núcleo não terminou (inconclusivo, não é morte)" ;; (*) ok "mutante $name morto" ;; esac
  done
}
mutate sem-hash-fixo 'elif [ "$inst_sha" != "$DSG_INSTALLER_SHA256" ]; then' 'elif false; then'
mutate reload-mata-a-rodada '--no-reload --expect-sha256 "$guard_sha"' '--expect-sha256 "$guard_sha"'
mutate segunda-rodada-reinstala 'if dsg_root_only "$prog_dir" d "$DSG_RUID" && [ -f "$marker" ] && dsg_root_only "$marker" - "$DSG_RUID"; then return 0; fi' 'if false; then return 0; fi'
mutate uid-do-ambiente 'DSG_ME=$(/usr/bin/id -u 2>/dev/null) || DSG_ME=""' 'DSG_ME="$EUID"'
mutate copia-do-root-roda-o-instalador '[ "$self_dir" = "$prog_dir" ] && return 0' 'false'
mutate instalador-symlink 'if [ -L "${self_dir}/${inst}" ] || [ ! -f "${self_dir}/${inst}" ]; then' 'if [ ! -f "${self_dir}/${inst}" ]; then'
mutate marcador-sempre 'if [ "$rc" = "0" ] && printf' 'if true || printf'
mutate marcador-gravavel-por-outros '[ "${mode:5:1}" != "w" ] && [ "${mode:8:1}" != "w" ]' 'true'
mutate marcador-herda-o-umask '&& chmod 0644 "${marker}.new.$$" 2>/dev/null' '&& true'
mutate log-sem-recarga-nem-erro "local keep='^(RESULTADO|RECARGA PENDENTE|ERRO):'" "local keep='^RESULTADO:'"
# ga-sgt7ls
mutate bootstrap-antes-do-thin 'AVAIL_KB=$(df -k' 'dsg_bootstrap_root; AVAIL_KB=$(df -k'
mutate df-ilegivel-sai-sem-bootstrap 'log "SKIP: nao consegui ler df de /System/Volumes/Data — unknown state, nao age."' 'log "SKIP: nao consegui ler df de /System/Volumes/Data — unknown state, nao age."; exit 0'
mutate sem-limite-de-tempo '[ $((SECONDS - t0)) -ge "$secs" ]' 'false'
mutate_with killcase sem-kill 'pkill -KILL -P "$pid"; kill -KILL "$pid"; /bin/sleep 0.5' 'true'
mutate sem-backoff '[ "$now" -lt "$retry_at" ] && return 0' 'false'
mutate backoff-nao-dobra 'delay=$((delay * 2))' 'delay=$((delay * 1))'
mutate backoff-sem-teto '[ "$delay" -le "$DSG_BACKOFF_MAX_S" ] || delay="$DSG_BACKOFF_MAX_S"' 'true'
mutate registro-de-outros-vale 'dsg_root_only "$1" - "$3" || return 1' 'true'
mutate registro-no-futuro-vale '[ "$at" -le $(( $2 + DSG_BACKOFF_MAX_S )) ] || return 1' 'true'
mutate pin-novo-nao-retenta '[ "$f1" = "$4" ] && [ -z "$f4" ] || return 1' '[ -z "$f4" ] || return 1'
mutate sucesso-nao-limpa-o-registro 'rm -f "$state" 2>/dev/null' 'true'
mutate plist-alvo-nao-conferido 'if [ -z "$target" ] || {' 'if false && {'
# (o awk -v interpreta \n do texto: o texto antigo pára antes do \n e o novo comenta o resto da linha)
mutate nota-so-no-log "|| printf 'disk-snapshot-guard: %s" '|| true #'
mutants_report

# --- caso estático: o log de teste (DSG_LOG) só vale DEPOIS de confirmado que este processo faz o papel de root. Uma rodada manual sem root com um DSG_LOG solto
#     não pode redirecionar o log do guard; isso não dá para ver rodando (o rabo real do guard escreveria no log verdadeiro da cidade), então a ordem é conferida no texto.
# vazio → os números ficam vazios e o caso reprova; falhou/ilegível → idem: sem as linhas não provo a ordem
L_ROOTCHK=$(grep -n -F '[ "$DSG_ME" = "$DSG_RUID" ] || return 0' "$GUARD" | head -n 1 | cut -d: -f1)
L_LOGHOOK=$(grep -n -F 'LOG="${DSG_LOG:-$LOG}"' "$GUARD" | head -n 1 | cut -d: -f1)
N_LOGHOOK=$(grep -c -F 'LOG="${DSG_LOG:-$LOG}"' "$GUARD")
if [ -n "$L_ROOTCHK" ] && [ -n "$L_LOGHOOK" ] && [ "$N_LOGHOOK" = "1" ] && [ "$L_ROOTCHK" -lt "$L_LOGHOOK" ]; then ok "estático: DSG_LOG só é lido depois da checagem de root (linha $L_ROOTCHK → $L_LOGHOOK)"; else bad "estático: DSG_LOG é lido antes de confirmar o papel de root (root='$L_ROOTCHK' log='$L_LOGHOOK' ocorrências='$N_LOGHOOK')"; fi

# --- caso estático: o hash fixado no commit é o do instalador deste commit (travessia: editar o instalador exige atualizar o hash) ---
PINNED=$(sed -n 's/^DSG_INSTALLER_SHA256="\([0-9a-f]*\)".*/\1/p' "$GUARD" | head -n 1)
if [ -n "$PINNED" ] && [ "$PINNED" = "$(sha_of "$INSTALLER")" ]; then ok "estático: DSG_INSTALLER_SHA256 do guard == sha256 do instalador"; else bad "estático: DSG_INSTALLER_SHA256 ($PINNED) difere do sha256 do instalador ($(sha_of "$INSTALLER"))"; fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
