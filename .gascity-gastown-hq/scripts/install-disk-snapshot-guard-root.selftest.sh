#!/bin/bash
# install-disk-snapshot-guard-root.selftest.sh — ga-xpswpd.1 (pai ga-xpswpd, achado do ga-j86sid)
#
# Contents
#   O que prova · Como é hermético · Mutantes · Saída
#
# O QUE PROVA: depois do instalador (install-disk-snapshot-guard-root.sh) o que o ROOT executa está fora do alcance do
#   usuário athos — a cópia e cada pasta até ela são do root, sem symlink, sem escrita de grupo/outros — e o plist aponta para
#   essa cópia, não para o repo. E o contrário, que é o que dá dentes ao teste: o instalador RECUSA (sem alterar nada) quando
#   o caminho que o root executaria é gravável por outro, e a conferência (--check) REPROVA quando a cópia ou uma pasta virou
#   gravável, quando o plist ou o launchd ainda apontam para o repo, ou quando não dá para ler o que o launchd carregou.
#
# COMO É HERMÉTICO: sem sudo, sem launchd, sem /usr/local nem /Library reais. Uma "raiz falsa" numa pasta temporária
#   (DSG_ROOT_PFX) faz o papel de "/", o uid de quem roda faz o papel do root (DSG_ROOT_UID, DSG_OWNER) e launchctl e
#   PlistBuddy são stubs de bash (DSG_LAUNCHCTL, DSG_PLISTBUDDY). O instalador só aceita esses ganchos
#   sem root; por isso este selftest RECUSA rodar como root (como root o instalador mexeria nos caminhos de verdade).
#   O que foi instalado é conferido por um oráculo próprio (ls -ldn, cmp, leitura do plist falso), não pelo --check do instalador
#   (seria circular); o --check entra só como ALVO dos casos de adulteração, onde é ele que tem de reprovar.
#
# MUTANTES: o mesmo núcleo de casos roda contra cópias do instalador com UMA proteção desligada por vez; cada mutante tem de
#   ser pego (algum caso reprova). Um mutante que sobrevive quer dizer que o núcleo não enxerga aquela proteção.
#
# SAÍDA: "Results: N passed, M failed"; exit 0 só com M = 0. Roda em ~35 s (a maior parte são os mutantes), só com as
#   ferramentas padrão do macOS e do Linux (bash 3.2 do mini inclusive). Sem o instalador ao lado ele sai 1 na hora.

set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
INSTALLER="${INSTALLER_UNDER_TEST:-$HERE/install-disk-snapshot-guard-root.sh}"
LABEL="com.gascity.disk-snapshot-guard"
WANT_ARG1="/usr/local/libexec/gascity/disk-snapshot-guard.sh"
PASS=0
FAIL=0
QUIET=0

ok()  { PASS=$((PASS+1)); if [ "$QUIET" != "1" ]; then printf '  ok: %s\n' "$1"; fi; }
bad() { FAIL=$((FAIL+1)); if [ "$QUIET" != "1" ]; then printf '  BAD: %s\n     %s\n' "$1" "${2:-}"; fi; }

if [ "$(id -u)" = "0" ]; then
  echo "BAD: não rode este selftest como root: como root o instalador ignora os ganchos DSG_* e mexeria em /usr/local e /Library de verdade"
  exit 2
fi
if [ ! -f "$INSTALLER" ]; then
  echo "BAD: não achei o instalador em $INSTALLER"
  echo "Results: 0 passed, 1 failed"
  exit 1
fi

TMP="$(mktemp -d)" || { echo "BAD: mktemp falhou"; exit 2; }
trap 'rm -rf "$TMP"' EXIT
MY_UID="$(id -u)"
MY_OWNER="$(id -un):$(id -gn)"
STUBS="$TMP/stubs"
mkdir -p "$STUBS"

# --- stubs: plist falso = linhas "chave=valor" ---------------------------------------------------------------------
cat > "$STUBS/PlistBuddy" <<'STUB'
#!/bin/bash
# PlistBuddy falso: Print :chave / Set :chave valor sobre um arquivo de linhas chave=valor
[ "${1:-}" = "-c" ] || exit 2
cmd="${2:-}"; f="${3:-}"
[ -f "$f" ] || { echo "File Doesn't Exist, Will Create: $f" >&2; exit 1; }
case "$cmd" in
  ("Print :"*)
    key="${cmd#Print :}"
    awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print; found = 1; exit } END { exit !found }' "$f" \
      || { echo "Print: Entry, \":$key\", Does Not Exist" >&2; exit 1; } ;;
  ("Set :"*)
    rest="${cmd#Set :}"; key="${rest%% *}"; val="${rest#* }"
    awk -F= -v k="$key" -v v="$val" '$1 == k { print k "=" v; found = 1; next } { print } END { exit !found }' "$f" > "$f.stub.$$" \
      || { rm -f "$f.stub.$$"; echo "Set: Entry, \":$key\", Does Not Exist" >&2; exit 1; }
    cat "$f.stub.$$" > "$f"; rm -f "$f.stub.$$" ;;
  (*) exit 2 ;;
esac
STUB
cat > "$STUBS/launchctl" <<'STUB'
#!/bin/bash
# launchctl falso: o "job carregado" é o arquivo $FAKE_LCTL_STATE/loaded.args (um argumento por linha)
S="${FAKE_LCTL_STATE:?}"
label="com.gascity.disk-snapshot-guard"
echo "$*" >> "$S/calls.log"
case "${1:-}" in
  (bootout)
    [ -f "$S/loaded.args" ] || { echo "Boot-out failed: 3: No such process" >&2; exit 3; }
    rm -f "$S/loaded.args" ;;
  (bootstrap)
    plist="${3:-}"
    if [ -n "${FAKE_BOOT_FAIL:-}" ]; then echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; fi
    if [ -n "${FAKE_BOOT_REJECT:-}" ] && grep -q -F "$FAKE_BOOT_REJECT" "$plist"; then
      echo "Bootstrap failed: 5: Input/output error" >&2; exit 5
    fi
    if [ -f "$S/loaded.args" ]; then echo "Bootstrap failed: 5: already loaded" >&2; exit 5; fi
    awk -F= '$1 ~ /^ProgramArguments:[0-9]+$/ { sub(/^[^=]*=/, ""); print }' "$plist" > "$S/loaded.args" ;;
  (print)
    [ -f "$S/loaded.args" ] || { echo "Could not find service \"$label\" in domain for system" >&2; exit 113; }
    if [ -n "${FAKE_PRINT_GARBAGE:-}" ]; then echo "algo que não é a saída do launchctl"; exit 0; fi
    echo "system/$label = {"
    echo "	active count = 0"
    echo "	arguments = {"
    sed 's/^/		/' "$S/loaded.args"
    echo "	}"
    echo "	runs = 1"
    echo "}" ;;
  (*) exit 64 ;;
esac
STUB
chmod 0755 "$STUBS/PlistBuddy" "$STUBS/launchctl"

# --- oráculo próprio (não usa o --check do instalador) -------------------------------------------------------------
# perms_of: vazio → rc 1 sem imprimir (o chamador reprova); falhou/ilegível → rc 1 também, nunca "seguro"
perms_of() {
  local l=""
  l=$(ls -ldn "$1" 2>/dev/null) || return 1
  [ -n "$l" ] || return 1
  set -- $l
  printf '%s' "${1:0:10}"
}
# uid_of: vazio → rc 1 sem imprimir; falhou/ilegível → rc 1 também
uid_of() {
  local l=""
  l=$(ls -ldn "$1" 2>/dev/null) || return 1
  [ -n "$l" ] || return 1
  set -- $l
  [ $# -ge 3 ] || return 1
  printf '%s' "$3"
}
# plist_val <arquivo> <chave>: vazio → imprime nada (o chamador compara com um valor não vazio e reprova); falhou/ilegível → idem
plist_val() {
  awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$1" 2>/dev/null
}
# sha_of: vazio → rc 1 sem imprimir; falhou/ilegível → rc 1 também (o caso que precisa do hash é PULADO e dito, nunca aprovado)
sha_of() {
  local out=""
  if [ -x /usr/bin/shasum ]; then out=$(/usr/bin/shasum -a 256 "$1" 2>/dev/null) || return 1
  elif [ -x /usr/bin/sha256sum ]; then out=$(/usr/bin/sha256sum "$1" 2>/dev/null) || return 1
  else return 1
  fi
  out="${out%% *}"
  [ "${#out}" = "64" ] || return 1
  printf '%s' "$out"
}

expect_rc() { # <esperado> <rótulo>
  if [ "$RC" = "$1" ]; then ok "$2 (rc=$1)"; else bad "$2: rc=$RC, esperado $1" "$(printf '%s' "$OUT" | tail -n 6)"; fi
}
expect_out() { # <texto fixo> <rótulo>
  case "$OUT" in
    (*"$1"*) ok "$2" ;;
    (*) bad "$2: a saída não tem '$1'" "$(printf '%s' "$OUT" | tail -n 6)" ;;
  esac
}
expect_no_out() { # <texto fixo> <rótulo>
  case "$OUT" in
    (*"$1"*) bad "$2: a saída tem '$1'" "$(printf '%s' "$OUT" | tail -n 6)" ;;
    (*) ok "$2" ;;
  esac
}
# assert_root_only <caminho> <d|-> <rótulo>: tipo certo, não é symlink, dono = o "root" do teste, sem escrita de grupo/outros
assert_root_only() {
  local p="$1" t="$2" lbl="$3" perm="" u=""
  if [ -L "$p" ]; then bad "$lbl: $p é um symlink"; return 0; fi
  perm=$(perms_of "$p") || { bad "$lbl: não consegui ler o modo de $p"; return 0; }
  u=$(uid_of "$p") || { bad "$lbl: não consegui ler o dono de $p"; return 0; }
  if [ "${perm:0:1}" != "$t" ]; then bad "$lbl: tipo '${perm:0:1}' em $p"; return 0; fi
  if [ "$u" != "$MY_UID" ]; then bad "$lbl: dono $u em $p (esperado $MY_UID)"; return 0; fi
  if [ "${perm:5:1}" = "w" ] || [ "${perm:8:1}" = "w" ]; then bad "$lbl: $p é gravável por grupo/outros ($perm)"; return 0; fi
  ok "$lbl: $p é do 'root', $perm, sem escrita de grupo/outros"
}

# --- mundo falso ---------------------------------------------------------------------------------------------------
new_world() {
  W=$(mktemp -d "$TMP/w.XXXXXX") || { echo "BAD: mktemp falhou"; exit 2; }
  ROOT="$W/root"; REPO="$W/repo"; ST="$W/lctl"; ATK="$W/attacker"
  PROG_D="$ROOT/usr/local/libexec/gascity"; PROG="$PROG_D/disk-snapshot-guard.sh"
  PL="$ROOT/Library/LaunchDaemons/$LABEL.plist"
  mkdir -p "$ROOT/usr/local" "$ROOT/Library/LaunchDaemons" "$REPO/scripts" "$ST" "$ATK"
  chmod 0755 "$W" "$ROOT" "$ROOT/usr" "$ROOT/usr/local" "$ROOT/Library" "$ROOT/Library/LaunchDaemons"
  cp "$INSTALLER" "$REPO/scripts/install-disk-snapshot-guard-root.sh"
  printf '#!/bin/bash\n# guard falso do selftest\nexit 0\n' > "$REPO/scripts/disk-snapshot-guard.sh"
  chmod 0755 "$REPO/scripts/disk-snapshot-guard.sh"
  printf 'Label=%s\nProgramArguments:0=/bin/bash\nProgramArguments:1=%s\nStartInterval=600\n' \
    "$LABEL" "$REPO/scripts/disk-snapshot-guard.sh" > "$PL"
  chmod 0644 "$PL"
  printf '/bin/bash\n%s\n' "$REPO/scripts/disk-snapshot-guard.sh" > "$ST/loaded.args"
  cp "$PL" "$W/plist.before"
  cp "$ST/loaded.args" "$W/loaded.before"
  cp "$REPO/scripts/disk-snapshot-guard.sh" "$W/guard.before"
}
# run_inst [args do instalador]: T_UID (uid que conta como root) e EXTRA_ENV (VAR=valor sem espaço) vêm do caso
run_inst() {
  local pin="" auto="1"
  # instalar exige --expect-sha256: junto automaticamente o hash da fonte de AGORA, salvo --check, hash explícito ou NO_PIN=1
  case " $* " in
    (*" --check "*|*" --expect-sha256 "*) auto="0" ;;
  esac
  if [ "${NO_PIN:-0}" = "1" ]; then auto="0"; fi
  if [ "$auto" = "1" ]; then
    # vazio/falhou → hash de zeros: o instalador recusa por hash e o caso reprova, nunca instala "sem hash"
    pin=$(sha_of "$REPO/scripts/disk-snapshot-guard.sh") || pin="0000000000000000000000000000000000000000000000000000000000000000"
    set -- "$@" --expect-sha256 "$pin"
  fi
  # vazio → OUT vazio e o caso reprova ao comparar rc/texto; falhou/ilegível → RC guarda o código real do instalador
  OUT=$(env DSG_ROOT_PFX="$ROOT" DSG_ROOT_UID="${T_UID:-$MY_UID}" DSG_OWNER="$MY_OWNER" \
        DSG_LAUNCHCTL="$STUBS/launchctl" DSG_PLISTBUDDY="$STUBS/PlistBuddy" \
        DSG_RETRY_SLEEP=0 FAKE_LCTL_STATE="$ST" ${EXTRA_ENV:-} \
        /bin/bash "$REPO/scripts/install-disk-snapshot-guard-root.sh" "$@" 2>&1)
  RC=$?
}
lctl_mutated() { [ -f "$ST/calls.log" ] && grep -q -E '^(bootout|bootstrap) ' "$ST/calls.log"; }
install_good() {
  new_world
  run_inst
  if [ "$RC" != "0" ]; then bad "pré-condição: a instalação limpa falhou (rc=$RC)" "$(printf '%s' "$OUT" | tail -n 6)"; fi
}
# assert_untouched <rótulo>: plist e job iguais ao início, nenhum bootout/bootstrap, nada criado na árvore do root
assert_untouched() {
  local found=""
  if cmp -s "$PL" "$W/plist.before"; then ok "$1: o plist ficou byte a byte igual"; else bad "$1: o plist mudou"; fi
  if cmp -s "$ST/loaded.args" "$W/loaded.before"; then ok "$1: o job carregado ficou igual"; else bad "$1: o job carregado mudou"; fi
  if lctl_mutated; then bad "$1: o launchctl recebeu bootout/bootstrap"; else ok "$1: nenhum bootout/bootstrap"; fi
  # vazio → nada criado (o esperado); falhou/ilegível → find ≠ 0 conta como "não conferi" e reprova
  found=$(find "$ROOT/usr" -name '*disk-snapshot-guard*' 2>/dev/null) || { bad "$1: find falhou, não conferi a árvore do root"; return 0; }
  if [ -z "$found" ]; then ok "$1: nada foi criado em usr/"; else bad "$1: criou algo em usr/: $found"; fi
}

# --- casos ---------------------------------------------------------------------------------------------------------
c_happy() {
  echo "== instalação limpa"
  new_world; run_inst
  expect_rc 0 "instala numa raiz limpa"
  expect_out "RESULTADO: instalado e confirmado" "o instalador diz que confirmou"
  assert_root_only "$ROOT/usr/local/libexec" d "pasta libexec"
  assert_root_only "$PROG_D" d "pasta gascity"
  assert_root_only "$PROG" - "cópia do guard"
  assert_root_only "$PL" - "plist"
  if [ "$(perms_of "$PROG")" = "-rwxr-xr-x" ]; then ok "a cópia é 0755"; else bad "a cópia não é -rwxr-xr-x: $(perms_of "$PROG")"; fi
  if cmp -s "$REPO/scripts/disk-snapshot-guard.sh" "$PROG"; then ok "a cópia é idêntica à fonte"; else bad "a cópia difere da fonte"; fi
  if [ "$(plist_val "$PL" ProgramArguments:1)" = "$WANT_ARG1" ]; then ok "o plist manda o root executar $WANT_ARG1"; else bad "ProgramArguments[1] = $(plist_val "$PL" ProgramArguments:1)"; fi
  if [ "$(plist_val "$PL" ProgramArguments:0)" = "/bin/bash" ] && [ "$(plist_val "$PL" StartInterval)" = "600" ] \
     && [ "$(plist_val "$PL" Label)" = "$LABEL" ]; then ok "as outras chaves do plist ficaram como estavam"; else bad "o plist perdeu Label/ProgramArguments[0]/StartInterval"; fi
  if [ "$(cat "$ST/loaded.args")" = "$(printf '/bin/bash\n%s' "$WANT_ARG1")" ]; then ok "o launchd (falso) carregou a cópia"; else bad "o job carregado é: $(tr '\n' ' ' < "$ST/loaded.args")"; fi
  if cmp -s "$REPO/scripts/disk-snapshot-guard.sh" "$W/guard.before"; then ok "o guard do repo não foi tocado"; else bad "o guard do repo mudou"; fi
  # vazio → nenhum backup (reprova); falhou/ilegível → ls ≠ 0 também reprova
  BK=$(ls "$PROG_D"/"$LABEL".plist.orig-* 2>/dev/null | head -n 1) || BK=""
  if [ -n "$BK" ] && cmp -s "$BK" "$W/plist.before"; then ok "o plist original ficou guardado ao lado da cópia"; else bad "sem backup fiel do plist original (BK='$BK')"; fi
  # vazio/falhou → sem a listagem não provo a ausência de temporários: reprova, nunca vira "sem sobras"
  if LIST=$(ls -A "$PROG_D" 2>/dev/null) && [ -n "$LIST" ] && ! printf '%s\n' "$LIST" | grep -q '^\.'; then ok "nenhum temporário ficou na pasta do root"
  else bad "sem listagem da pasta do root ($PROG_D) ou ficaram temporários nela: $LIST"; fi
  if [ "$(sed -n '1p;2p' "$ST/calls.log" | cut -d' ' -f1 | tr '\n' ' ')" = "bootout bootstrap " ]; then ok "bootout vem antes de bootstrap"; else bad "ordem do launchctl: $(cut -d' ' -f1 "$ST/calls.log" | tr '\n' ' ')"; fi
  run_inst --check
  expect_rc 0 "--check depois de instalar"
  expect_out "RESULTADO: seguro" "--check diz seguro"
}
c_idempotent() {
  echo "== segunda instalação"
  install_good; run_inst
  expect_rc 0 "reinstalar não quebra"
  expect_out "já aponta para" "o plist já apontava: nada a trocar"
  assert_root_only "$PROG" - "cópia depois da 2ª instalação"
}
c_check_before() {
  echo "== --check antes de instalar"
  new_world; run_inst --check
  expect_rc 1 "--check reprova o estado de hoje"
  expect_out "FALHA" "--check marca FALHA"
  expect_out "o plist manda o root executar $REPO/scripts/disk-snapshot-guard.sh" "--check diz que o plist ainda aponta para o repo"
  expect_out "o launchd carregou outra definição" "--check diz que o launchd carregou o repo"
  assert_untouched "--check antes"
}
c_not_root() {
  echo "== sem root"
  new_world; T_UID=0 run_inst
  expect_rc 2 "sem root o instalador não instala"
  expect_out "rode como root" "e diz como"
  assert_untouched "sem root"
}
c_libexec_loose() {
  echo "== libexec já existe e é 0777"
  new_world; mkdir -p "$ROOT/usr/local/libexec"; chmod 0777 "$ROOT/usr/local/libexec"; run_inst
  expect_rc 1 "recusa quando libexec já existe e é gravável por todos"
  expect_out "gravável por grupo/outros" "e diz o motivo"
  if [ -e "$ROOT/usr/local/libexec/gascity" ]; then bad "criou gascity dentro de uma pasta insegura"; else ok "não criou nada dentro da pasta insegura"; fi
  assert_untouched "libexec 0777"
}
c_libexec_symlink() {
  echo "== libexec é um symlink para pasta do athos"
  new_world; ln -s "$ATK" "$ROOT/usr/local/libexec"; run_inst
  expect_rc 1 "recusa quando libexec é symlink"
  expect_out "symlink" "e diz que é symlink"
  if [ -z "$(ls -A "$ATK")" ]; then ok "a pasta do atacante continua vazia"; else bad "o instalador escreveu na pasta do atacante: $(ls -A "$ATK")"; fi
  assert_untouched "libexec symlink"
}
c_dest_symlink() {
  echo "== o destino da cópia é um symlink"
  new_world; mkdir -p "$PROG_D"; chmod 0755 "$ROOT/usr/local/libexec" "$PROG_D"
  echo evil > "$ATK/evil.sh"; ln -s "$ATK/evil.sh" "$PROG"; run_inst
  expect_rc 0 "instala por cima de um symlink no destino"
  if [ -L "$PROG" ]; then bad "o destino continua um symlink"; else ok "o destino virou arquivo comum"; fi
  if [ "$(cat "$ATK/evil.sh")" = "evil" ]; then ok "o alvo do symlink não foi sobrescrito"; else bad "o alvo do symlink foi escrito: $(cat "$ATK/evil.sh")"; fi
  assert_root_only "$PROG" - "cópia no lugar do symlink"
}
c_plist_other_target() {
  echo "== o plist aponta para outro script"
  new_world
  sed 's|^ProgramArguments:1=.*|ProgramArguments:1=/tmp/outro.sh|' "$PL" > "$PL.n" && cat "$PL.n" > "$PL" && rm -f "$PL.n"
  cp "$PL" "$W/plist.before"
  run_inst
  expect_rc 1 "recusa plist que não aponta para o disk-snapshot-guard.sh"
  assert_untouched "plist de outro script"
}
c_plist_third_arg() {
  echo "== o plist tem um 3º argumento"
  new_world; echo 'ProgramArguments:2=--x' >> "$PL"; cp "$PL" "$W/plist.before"; run_inst
  expect_rc 1 "recusa plist com formato desconhecido"
  expect_out "3º item" "e diz o motivo"
  assert_untouched "plist com 3º argumento"
}
c_src_symlink() {
  echo "== a fonte é um symlink"
  new_world; echo '#!/bin/bash' > "$ATK/g.sh"; rm -f "$REPO/scripts/disk-snapshot-guard.sh"; ln -s "$ATK/g.sh" "$REPO/scripts/disk-snapshot-guard.sh"; run_inst
  expect_rc 1 "recusa fonte symlink"
  assert_untouched "fonte symlink"
}
c_pin() {
  echo "== --expect-sha256"
  new_world; run_inst --expect-sha256 0000000000000000000000000000000000000000000000000000000000000000
  expect_rc 1 "recusa hash que não bate"
  expect_out "difere do --expect-sha256" "e diz o motivo"
  assert_untouched "hash errado"
  new_world; run_inst --expect-sha256 abc
  expect_rc 2 "hash com tamanho errado é uso errado"
  assert_untouched "hash curto"
  if H=$(sha_of "$REPO/scripts/disk-snapshot-guard.sh"); then
    run_inst --expect-sha256 "$H"
    run_inst --check --expect-sha256 "$H"
    expect_rc 0 "--check com o hash certo"
    run_inst --check --expect-sha256 0000000000000000000000000000000000000000000000000000000000000000
    expect_rc 1 "--check reprova a cópia com hash que não bate"
  else
    echo "  (pulado: sem shasum/sha256sum neste sistema — os casos com o hash certo não foram medidos)"
  fi
}
c_pin_required() {
  echo "== instalar sem --expect-sha256"
  new_world; NO_PIN=1 run_inst
  expect_rc 2 "sem o hash o instalador não instala (o root lê um arquivo de pasta do athos)"
  expect_out "instalar exige --expect-sha256" "e diz que o hash é obrigatório"
  assert_untouched "sem hash"
}
c_staging_private() {
  echo "== a cópia nasce privada e só abre depois do hash"
  # vazio → o número fica vazio e o caso reprova; falhou/ilegível → idem: sem a linha não provo a ordem
  L_STAGE=$(grep -n -F 'stage_copy "$SRC" "$tmp_copy" 0700' "$INSTALLER" | head -n 1 | cut -d: -f1)
  L_SHA=$(grep -n -F '[ "$copy_sha" = "$PIN" ]' "$INSTALLER" | head -n 1 | cut -d: -f1)
  L_OPEN=$(grep -n -F 'chmod 0755 "$tmp_copy"' "$INSTALLER" | head -n 1 | cut -d: -f1)
  if [ -n "$L_STAGE" ] && [ -n "$L_SHA" ] && [ -n "$L_OPEN" ] && [ "$L_STAGE" -lt "$L_SHA" ] && [ "$L_SHA" -lt "$L_OPEN" ]; then
    ok "ordem no instalador: copia 0700 (linha $L_STAGE) → confere o hash (linha $L_SHA) → abre para 0755 (linha $L_OPEN)"
  else
    bad "a cópia não nasce 0700 / não abre só depois do hash (stage='$L_STAGE' hash='$L_SHA' abre='$L_OPEN')"
  fi
}
c_boot_reject() {
  echo "== o launchd recusa o plist novo"
  new_world; EXTRA_ENV="FAKE_BOOT_REJECT=$WANT_ARG1" run_inst
  expect_rc 1 "devolve o plist original quando o bootstrap recusa o novo"
  expect_out "Voltei ao plist original" "e diz que voltou"
  if cmp -s "$PL" "$W/plist.before"; then ok "o plist voltou byte a byte"; else bad "o plist não voltou ao original"; fi
  if cmp -s "$ST/loaded.args" "$W/loaded.before"; then ok "o job está carregado como antes"; else bad "o job carregado: $(tr '\n' ' ' < "$ST/loaded.args" 2>/dev/null)"; fi
}
c_boot_fail() {
  echo "== o launchd não carrega nada"
  new_world; EXTRA_ENV="FAKE_BOOT_FAIL=1" run_inst
  expect_rc 3 "estado incerto vira rc 3, nunca sucesso"
  expect_out "DESCARREGADO" "e avisa que o guard pode estar descarregado"
}
c_tamper_copy() {
  echo "== --check: cópia ficou gravável"
  install_good; chmod 0666 "$PROG"; run_inst --check
  expect_rc 1 "--check reprova cópia 0666"
  expect_out "gravável por grupo/outros" "e diz o motivo"
}
c_tamper_dir() {
  echo "== --check: pasta do root ficou gravável"
  install_good; chmod 0777 "$PROG_D"; run_inst --check
  expect_rc 1 "--check reprova pasta gascity 0777"
  expect_out "gravável por grupo/outros" "e diz o motivo"
}
c_owned_by_other() {
  echo "== --check: dono que não é o root"
  install_good; T_UID=$((MY_UID+1)) run_inst --check
  expect_rc 1 "--check reprova o que não é do root"
  expect_out "não do root" "e diz que o dono não é o root"
}
c_plist_to_repo() {
  echo "== --check: o plist voltou a apontar para o repo"
  install_good
  sed "s|^ProgramArguments:1=.*|ProgramArguments:1=$REPO/scripts/disk-snapshot-guard.sh|" "$PL" > "$PL.n" && cat "$PL.n" > "$PL" && rm -f "$PL.n"
  run_inst --check
  expect_rc 1 "--check reprova plist que aponta para o repo"
  expect_out "o plist manda o root executar $REPO/scripts/disk-snapshot-guard.sh" "e cita o caminho do repo"
}
c_launchd_stale() {
  echo "== --check: o launchd ainda tem a definição do repo"
  install_good; printf '/bin/bash\n%s\n' "$REPO/scripts/disk-snapshot-guard.sh" > "$ST/loaded.args"; run_inst --check
  expect_rc 1 "--check reprova job carregado com o repo"
  expect_out "o launchd carregou outra definição" "e diz que o launchd está com outra definição"
}
c_launchd_unreadable() {
  echo "== --check: não dá para ler o launchd (terceiro estado)"
  install_good; rm -f "$ST/loaded.args"; run_inst --check
  expect_rc 3 "launchctl print falhando vira rc 3, não 0"
  expect_no_out "RESULTADO: seguro" "e não diz seguro"
  install_good; EXTRA_ENV="FAKE_PRINT_GARBAGE=1" run_inst --check
  expect_rc 3 "saída sem bloco arguments vira rc 3, não 0"
}

suite_core() {
  c_happy
  c_pin_required
  c_staging_private
  c_not_root
  c_libexec_loose
  c_libexec_symlink
  c_boot_reject
  c_tamper_copy
  c_tamper_dir
  c_owned_by_other
  c_plist_to_repo
  c_launchd_stale
}
suite_extra() {
  c_idempotent
  c_check_before
  c_dest_symlink
  c_plist_other_target
  c_plist_third_arg
  c_src_symlink
  c_pin
  c_boot_fail
  c_launchd_unreadable
}

# --- mutantes: UMA troca literal por vez, no instalador copiado ---------------------------------------------------
# replace_once <entrada> <saída> <velho> <novo>: rc 1 se <velho> não ocorre exatamente uma vez (o mutante não valeria nada)
replace_once() {
  awk -v old="$3" -v new="$4" '
    { buf = buf $0 "\n" }
    END {
      n = 0; s = buf
      while ((i = index(s, old)) > 0) { n++; s = substr(s, i + length(old)) }
      if (n != 1) exit 3
      i = index(buf, old)
      printf "%s%s%s", substr(buf, 1, i - 1), new, substr(buf, i + length(old))
    }' "$1" > "$2"
}
mutant() { # <nome> <velho> <novo>
  local name="$1" old="$2" new="$3" mfile="$TMP/mutant.$$.sh" n=""
  if ! replace_once "$INSTALLER" "$mfile" "$old" "$new"; then
    bad "mutante $name: o trecho '$old' não ocorre exatamente uma vez no instalador (o selftest ficou velho)"
    return 0
  fi
  # vazio → o subshell não imprimiu o contador e o mutante conta como NÃO pego; falhou/ilegível → idem
  n=$( (INSTALLER="$mfile"; QUIET=1; FAIL=0; suite_core >/dev/null 2>&1; echo "$FAIL") 2>/dev/null | tail -n 1)
  case "$n" in
    (''|*[!0-9]*) bad "mutante $name: não consegui contar as reprovações ('$n')" ;;
    (0) bad "mutante $name SOBREVIVEU: nenhum caso do núcleo viu a proteção desligada" ;;
    (*) ok "mutante $name morto ($n reprovações)" ;;
  esac
}

if [ "${DSG_NO_MUTANTS:-0}" != "1" ]; then SKIP_MUT=0; else SKIP_MUT=1; fi

suite_core
suite_extra

if [ "$SKIP_MUT" = "0" ]; then
  echo "== mutantes"
  mutant "copia-0777" 'chmod 0755 "$tmp_copy"' 'chmod 0777 "$tmp_copy"'
  mutant "copia-nasce-aberta" 'stage_copy "$SRC" "$tmp_copy" 0700' 'stage_copy "$SRC" "$tmp_copy" 0755'
  mutant "hash-opcional" 'if [ "$MODE" = "install" ] && [ -z "$PIN" ]; then' 'if false; then'
  mutant "plist-nao-editado" '(*/"$GUARD_NAME") needs_edit=1 ;;' '(*/"$GUARD_NAME") needs_edit=0 ;;'
  mutant "escrita-de-grupo-ignorada" '[ "${1:5:1}" = "w" ] || [ "${1:8:1}" = "w" ]' 'false'
  mutant "sem-volta-do-plist" 'if restore_original; then' 'if false; then'
  mutant "launchd-nao-conferido" 'if [ "$LD_ARGS" = "$want_args" ]; then' 'if true; then'
  mutant "sem-checagem-de-root" 'if [ "$EUID" != "$ROOT_UID" ]; then' 'if false; then'
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
