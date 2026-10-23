#!/bin/bash
# disk-snapshot-guard-bootstrap.selftest.sh — ga-xpswpd.2 (pai ga-xpswpd)
#
# Contents
#   O que prova · Como é hermético · Saída
#
# O QUE PROVA: o bloco do topo do disk-snapshot-guard.sh, quando roda como ROOT e a cópia do root ainda não está confirmada,
#   executa UMA vez o instalador (--no-reload) com o hash fixado neste commit, e depois não faz mais nada. E o contrário, que
#   dá dentes ao teste: instalador adulterado, ausente ou symlink = NADA instalado e o guard segue (rc 0); sem root = nada, e um
#   $EUID importado do ambiente não muda o que roda (o uid vem de `id -u`); na rodada 1 o launchctl falso NUNCA recebe
#   bootout/bootstrap (a rodada não é morta no meio e o job não fica descarregado); a segunda rodada e a rodada da própria
#   cópia do root não chamam o instalador. Mutantes (8): o mesmo núcleo contra cópias do guard com uma proteção desligada, mais um
#   mutante NULO (nada muda) que tem de SOBREVIVER: sem esse controle limpo, "mutante morto" não prova nada.
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
  mkdir -p "$ROOT/usr/local" "$ROOT/Library/LaunchDaemons" "$ROOT/var/tmp" "$REPO/scripts" "$ST"
  chmod 0755 "$W" "$ROOT" "$ROOT/usr" "$ROOT/usr/local" "$ROOT/Library" "$ROOT/Library/LaunchDaemons" "$ROOT/var" "$ROOT/var/tmp"
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
    DSG_PLISTBUDDY="$STUBS/PlistBuddy" DSG_RETRY_SLEEP=0 DSG_LOG="$W/guard.log" FAKE_LCTL_STATE="$ST" "$@" \
    /bin/bash "$REPO/scripts/disk-snapshot-guard.sh" 2>&1); RC=$?
}

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
  if [ -z "$(ls -A "$ROOT/var/tmp")" ]; then ok "rodada 1: a pasta privada de trabalho foi removida"; else bad "rodada 1: sobrou lixo em /var/tmp" "$(ls -A "$ROOT/var/tmp")"; fi

  # 2. rodada 2: idempotente — o instalador nem é chamado
  cp "$PL" "$W/plist.before"; n=$(calls)
  run_guard
  expect_rc 0 "rodada 2: o guard termina bem"
  expect_no_out "instalador do disk-snapshot-guard" "rodada 2: o instalador não roda de novo"
  if [ "$(calls)" = "$n" ] && cmp -s "$PL" "$W/plist.before"; then ok "rodada 2: nenhuma chamada ao launchd e o plist não mudou"; else bad "rodada 2: mexeu em algo"; fi

  # 3. a própria cópia do root, mesmo sem marcador, nunca roda o instalador do repo
  rm -f "$MARK"; n=$(calls); cp "$REPO/scripts/install-disk-snapshot-guard-root.sh" "$PROG_D/"
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

  # 6. instalador que falha (plist sumiu → rc ≠ 0): sem marcador, guard rc 0
  new_world; rm -f "$PL"; mkdir -p "$PROG_D"; chmod 0755 "$ROOT/usr/local/libexec" "$PROG_D"; run_guard
  expect_rc 0 "instalador falha: o guard segue (rc 0)"
  [ ! -e "$MARK" ] && ok "instalador falha: sem marcador (a próxima rodada tenta de novo)" || bad "instalador falha: gravou marcador"

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

  # 10. controle dos alarmes: com o disco BAIXO o guard chega ao rabo real e cada alarme dispara. Sem isto, "nenhuma violação" nos outros casos não provaria que os stubs
  #     enxergam o rabo. A violação vai para um arquivo à parte e não suja a checagem de hermeticidade do núcleo.
  new_world; run_guard FAKE_DF_KB=2000000 FAKE_VIOLATIONS="$W/violations.low"
  expect_rc 0 "controle do disco baixo: o guard termina bem"
  for a in tmutil sleep sudo; do
    if grep -q "^$a " "$W/violations.low" 2>/dev/null; then ok "controle do disco baixo: o alarme '$a' disparou (os stubs enxergam o rabo do guard)"; else bad "controle do disco baixo: o alarme '$a' NÃO disparou" "$(cat "$W/violations.low" 2>/dev/null)"; fi
  done
}

core
# vazio (log sem linhas) → o guard parou no bloco de bootstrap em todos os casos; qualquer linha → chegou ao rabo real (tmutil/sudo/sleep) e o teste reprova
if [ ! -s "$VIOL" ]; then ok "hermético: em todos os casos o guard parou antes do rabo real (nenhuma chamada a tmutil/sudo/sleep)"; else bad "hermético: o guard chegou ao rabo real" "$(head -n 5 "$VIOL")"; fi

# --- mutantes: o mesmo núcleo contra cópias do guard com UMA proteção desligada por vez; cada um tem de ser pego -------------
# core_fails <guard>: roda o núcleo sob esse guard na MESMA subshell dos mutantes e imprime o nº de falhas, ou "?" se o núcleo nem terminou
core_fails() {
  local n=""
  n=$( ( GUARD="$1"; QUIET=1; PASS=0; FAIL=0; core >/dev/null 2>&1; echo "$FAIL" ) 2>/dev/null ) || n="?"
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
mutate() { # <nome> <texto antigo> <texto novo>: o antigo tem de aparecer em exatamente 1 linha do guard
  local name="$1" out="$TMP/mut-$1.sh" f=""
  mutant_file "$GUARD" "$out" "$2" "$3" || { bad "mutante $name: o texto antigo não aparece em exatamente 1 linha"; return 0; }
  if [ "$NULL_FAILS" != "0" ]; then bad "mutante $name: sem baseline limpo (o controle nulo reprovou), 'morto' não prova nada"; return 0; fi
  f="$(core_fails "$out")"
  case "$f" in (0) bad "mutante $name SOBREVIVEU" ;; ('?') bad "mutante $name: o núcleo não terminou (inconclusivo, não é morte)" ;; (*) ok "mutante $name morto" ;; esac
}
mutate sem-hash-fixo 'elif [ "$inst_sha" != "$DSG_INSTALLER_SHA256" ]; then' 'elif false; then'
mutate reload-mata-a-rodada '--no-reload --expect-sha256 "$guard_sha"' '--expect-sha256 "$guard_sha"'
mutate segunda-rodada-reinstala 'if dsg_root_only "$prog_dir" d "$root_uid" && [ -f "$marker" ] && dsg_root_only "$marker" - "$root_uid"; then return 0; fi' 'if false; then return 0; fi'
mutate uid-do-ambiente 'me=$(/usr/bin/id -u 2>/dev/null) || return 0' 'me="$EUID"'
mutate copia-do-root-roda-o-instalador '[ "$self_dir" = "$prog_dir" ] && return 0' 'false'
mutate instalador-symlink 'if [ -L "${self_dir}/${inst}" ] || [ ! -f "${self_dir}/${inst}" ]; then' 'if [ ! -f "${self_dir}/${inst}" ]; then'
mutate marcador-sempre 'if [ "$rc" = "0" ] && printf' 'if true || printf'
mutate marcador-gravavel-por-outros '[ "${mode:5:1}" != "w" ] && [ "${mode:8:1}" != "w" ]' 'true'

# --- caso estático: o hash fixado no commit é o do instalador deste commit (travessia: editar o instalador exige atualizar o hash) ---
PINNED=$(sed -n 's/^DSG_INSTALLER_SHA256="\([0-9a-f]*\)".*/\1/p' "$GUARD" | head -n 1)
if [ -n "$PINNED" ] && [ "$PINNED" = "$(sha_of "$INSTALLER")" ]; then ok "estático: DSG_INSTALLER_SHA256 do guard == sha256 do instalador"; else bad "estático: DSG_INSTALLER_SHA256 ($PINNED) difere do sha256 do instalador ($(sha_of "$INSTALLER"))"; fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
