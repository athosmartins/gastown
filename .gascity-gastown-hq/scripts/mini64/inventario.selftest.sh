#!/usr/bin/env bash
# inventario.selftest.sh — regressão do scripts/mini64/inventario.sh (ga-ke5w2ie.1).
#
# O script roda no mini (macOS) e só lê. Aqui ele roda num MUNDO FALSO: HOME falso, cidade falsa, MINI64_ROOT falso e um PATH que
# só tem stubs dos comandos do macOS + as ferramentas genéricas por link. Cada stub anota o argv em calls.log e responde o que o
# cenário pôs em fx/. Roda no mini e no nó Linux (só bash/sed/awk e ssh-keygen/shasum/perl); termina em ~1 min.
#   R1 mundo feliz: fatos de cada seção; nenhum segredo plantado (chave privada, token, env de plist, argv do bw) vaza; doc passa no
#      doc-rules-lint; nada escrito fora de docs/runbooks/mini64; só chamadas de LEITURA (allowlist); $HOME não é varrido (canários chmod 000)
#   R2 mundo que falha: sonda ausente / rc≠0 / formato fora vira «não apurado», nunca «nenhum», 0, «habilitado» nem «ausente»
#   R3 mundo que responde vazio: o mesmo script diz «nenhum»/0/«ausente» quando MEDIU (controle positivo de R2)
#   R4 saída hostil (crase, ESC, token, VAR=segredo) é limpa ou suprimida e o doc segue válido
#   R5 sonda pendurada: prazo por sonda e orçamento total; sai 0 em segundos   R6 pasta sem escrita: sai 1 e o doc antigo fica; HOME vazio: sai 2
#   R7 duas rodadas: sem sobra .inventario-work   R8 estático: bash -n (3.2 se MINI64_B32), sem recurso de bash 4, sem comando que varre pasta protegida
#   R9 uma falha só: o R2 quebra tudo junto e uma seção que falha por outro caminho esconde o «ok» indevido; aqui cada mundo tem 1-3 falhas em seções
#      DISJUNTAS e o Resumo tem de apontar exatamente essas (e nenhuma no mundo feliz). O mundo mora em /tmp: um TMPDIR longo casaria o SECRET_RE
#   R10 plists: argumento do 4º em diante («timeout -k 20 840 /bin/bash w.sh»), valor multilinha, nome com LF, plist binário (argumento ilegível = não
#      apurado, nunca «nenhum»); bw serve com «--port=N» e sem valor
#   R11 harness: o calls.log (gravado pelos wrappers) não mistura as linhas de 2 etapas concorrentes de um pipeline (antes: «chamada fora da allowlist» ao acaso)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${MINI64_INVENTARIO:-$HERE/inventario.sh}"   # o override é da bateria de mutantes: aponta uma cópia mutante
TBASH="${MINI64_TEST_BASH:-$(type -P bash)}"         # o bash que roda o script (ex.: um 3.2.57)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  BAD: %s\n     %s\n' "$1" "${2:-}"; }
if [ ! -f "$SCRIPT" ]; then bad "o script sob teste existe" "$SCRIPT"; echo "== $PASS ok, $FAIL BAD"; exit 1; fi
TMP="$(TMPDIR=/tmp mktemp -d)"; trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
ROOTUSER=0; [ "$(id -u)" = 0 ] && ROOTUSER=1
NA='não apurado\*\*: '   # o doc escreve **não apurado**: motivo

fx()    { printf '%b\n' "$2" >"$FX/$1.out"; }   # fx <stub.chave> <texto>: stdout do stub (chave = argv saneado, ex.: scutil.get_HostName)
fxrc()  { printf '%s\n' "$2" >"$FX/$1.rc"; }
fxerr() { printf '%s\n' "$2" >"$FX/$1.err"; }
sect()  { awk -v n="$1" 'index($0, "## " n ". ") == 1 { f = 1; next } /^## / { f = 0 } f' "$DOC"; }
has()   { local s; s=$(sect "$1"); if grep -qE -e "$2" <<<"$s"; then ok "$3"; else bad "$3" "seção $1 sem /$2/"; fi; }
hasnt() { local s; s=$(sect "$1"); if grep -qE -e "$2" <<<"$s"; then bad "$3" "seção $1 tem /$2/"; else ok "$3"; fi; }
docs()  { if grep -qE -e "$1" "$DOC"; then ok "$2"; else bad "$2" "doc sem /$1/"; fi; }
docnot() { if grep -qE -e "$1" "$DOC"; then bad "$2" "doc tem /$1/"; else ok "$2"; fi; }
nok()   { awk -F'|' '/^\| [0-9]+\. / && $3 !~ /^ ok $/ { split($2, a, "."); gsub(/ /, "", a[1]); printf "%s ", a[1] }' "$DOC"; }   # nº das seções do Resumo que NÃO estão «ok»
sf()    { local g; g=$(nok); [ "$g" = "$1" ] && ok "$2 (não ok: [${1% }])" || bad "$2" "seções não ok: esperado [$1] veio [$g]"; }   # sf "<nºs esperados, com espaço no fim>" <descrição>

mkworld() {   # mkworld <nome>: mundo novo e feliz em $TMP/<nome>
  W="$TMP/$1"; H="$W/home"; R="$W/root"; C="$W/city"; B="$W/bin"; G="$W/gen"; FX="$W/fx"; CALLS="$W/calls.log"; DOC="$C/docs/runbooks/mini64/01-inventario.md"
  mkdir -p "$H/.ssh" "$H/Library/LaunchAgents" "$H/.gastown/claude-accounts/acct1" "$H/.gastown/claude-pool-cred" "$H/.claude" "$H/.local/bin" "$H/gt/rig1/lib" \
    "$H/Desktop" "$H/Documents" "$H/Library/CloudStorage/GoogleDrive-canary@example.test" "$R/Library/LaunchDaemons" "$R/Library/LaunchAgents" "$R/etc/sudoers.d" "$R/etc/ssh" \
    "$R/dev" "$R/usr/sbin" "$R/usr/bin" "$R/opt/homebrew/bin" "$R/Library/Developer/CommandLineTools/usr/bin" "$R/System/Applications/Utilities/Terminal.app" "$R/Applications/Google Drive.app" \
    "$C/scripts/mini64" "$C/packs" "$W/wrappers" "$B" "$G" "$FX"
  : >"$CALLS"; cp "$SCRIPT" "$C/scripts/mini64/inventario.sh"
  for t in awk sed sort uniq cut tr head wc mkdir mv rm date basename dirname xargs shasum ssh-keygen perl id mktemp cat sleep; do p=$(type -P "$t") && ln -s "$p" "$G/$t"; done
  for t in ls grep; do printf '#!/bin/sh\nl="${0##*/}"; for a in "$@"; do l="$l $a"; done; printf "%%s\\n" "$l" >>"$CALLS"\nexec %s "$@"\n' "$(type -P "$t")" >"$G/$t"; chmod +x "$G/$t"; done   # a linha inteira num ÚNICO printf: pedaços separados se misturam quando 2 etapas de um pipeline (grep | … | grep) gravam juntas (R11)
  cat >"$W/stub.sh" <<'EOF'
#!/bin/sh
n=${0##*/}; k=""; best="$n"
l="$n"; for a in "$@"; do l="$l $a"; done; printf '%s\n' "$l" >>"$CALLS"
for a in "$@"; do
  t=$(printf '%s' "$a" | tr -c 'A-Za-z0-9' '_' | sed 's/^_*//; s/_*$//'); k="${k:+${k}_}$t"
  if [ -e "$FX/$n.$k.out" ] || [ -e "$FX/$n.$k.rc" ]; then best="$n.$k"; fi
done
[ -f "$FX/$best.sleep" ] && sleep "$(cat "$FX/$best.sleep")"
[ -f "$FX/$best.out" ] && cat "$FX/$best.out"
[ -f "$FX/$best.err" ] && cat "$FX/$best.err" >&2
[ -f "$FX/$best.rc" ] && exit "$(cat "$FX/$best.rc")"
exit 0
EOF
  for n in launchctl hostname scutil sw_vers sysctl uname df networksetup ipconfig pkgutil xcode-select python3 node adb dolt gc bd claude tmux bw defaults sqlite3 systemextensionsctl kextstat system_profiler pgrep security lsof brew pluginkit ps pmset systemsetup; do cp "$W/stub.sh" "$B/$n"; done
  for pth in "$R/opt/homebrew/bin/python3.11" "$R/Library/Developer/CommandLineTools/usr/bin/python3" "$R/usr/bin/python3"; do cp "$W/stub.sh" "$pth"; done
  chmod +x "$B"/* "$R/opt/homebrew/bin/python3.11" "$R/Library/Developer/CommandLineTools/usr/bin/python3" "$R/usr/bin/python3"; : >"$R/usr/sbin/sshd"; chmod +x "$R/usr/sbin/sshd"
  : >"$R/dev/cu.wchusbserial1410"; : >"$R/Library/LaunchDaemons/com.gascity.root.plist"; : >"$R/Library/LaunchDaemons/br.urblink.d.plist"; : >"$R/Library/LaunchDaemons/com.apple.thing.plist"; : >"$R/etc/sudoers.d/gascity-nopasswd"
  # ssh de verdade (ssh-keygen real): chave privada plantada + públicas de duas máquinas + chave de host
  ssh-keygen -q -t ed25519 -N '' -C 'athos@mbp' -f "$W/k1" >/dev/null 2>&1; ssh-keygen -q -t ed25519 -N '' -C 'node@hetzner' -f "$W/k2" >/dev/null 2>&1; ssh-keygen -q -t ed25519 -N '' -C 'root@mini' -f "$W/hk" >/dev/null 2>&1
  cp "$W/k1" "$H/.ssh/id_ed25519"; cp "$W/k1.pub" "$H/.ssh/id_ed25519.pub"; cat "$W/k1.pub" "$W/k2.pub" >"$H/.ssh/authorized_keys"; cp "$W/hk.pub" "$R/etc/ssh/ssh_host_ed25519_key.pub"
  printf 'hetzner.example %s\n' "$(cut -d' ' -f1,2 "$W/k2.pub")" >"$H/.ssh/known_hosts"
  printf 'Host hetzner\n  HostName 203.0.113.9\n  User athos\n  IdentityFile ~/.ssh/id_ed25519\n  ProxyCommand sh -c PROXYSECRETWORD\n' >"$H/.ssh/config"
  # plists: estilo uma linha (com env secreto), duas linhas (python direto), Disabled=true, bw serve por bash -c, outros prefixos (o binário vive no R10: ele torna as seções 3 e 14 não apuradas)
  LA="$H/Library/LaunchAgents"
  printf '<?xml version="1.0"?><plist version="1.0"><dict><key>Label</key><string>com.whatsapp.a</string><key>ProgramArguments</key><array><string>/bin/bash</string><string>%s/wrappers/w1.sh</string></array><key>EnvironmentVariables</key><dict><key>MOTHERDUCK_TOKEN</key><string>PLANTEDPLISTENVSECRET1234567890</string></dict></dict></plist>\n' "$W" >"$LA/com.whatsapp.a.plist"
  cat >"$LA/com.whatsapp.b.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.whatsapp.b</string>
	<key>ProgramArguments</key>
	<array>
		<string>$R/opt/homebrew/bin/python3.11</string>
		<string>/Users/test/x.py</string>
	</array>
</dict>
</plist>
EOF
  printf '<plist><dict><key>Label</key><string>com.gascity.c</string><key>Disabled</key><true/><key>ProgramArguments</key><array><string>python3</string><string>x.py</string></array></dict></plist>\n' >"$LA/com.gascity.c.plist"
  printf '<plist><dict><key>Label</key><string>com.gascity.d</string><key>ProgramArguments</key><array><string>/bin/bash</string><string>-c</string><string>bw serve --port 8087</string></array></dict></plist>\n' >"$LA/com.gascity.d.plist"
  for l in com.urblink.e br.urblink.f com.athos.g org.other.h; do printf '<plist><dict><key>Label</key><string>%s</string><key>ProgramArguments</key><array><string>/bin/echo</string></array></dict></plist>\n' "$l" >"$LA/$l.plist"; done
  printf '#!/bin/bash\nexec /Users/test/venv/bin/python3 foo.py\nbw serve --port 8087\n' >"$W/wrappers/w1.sh"
  # nomes de item citados pelo código; perfis Claude com token plantado; canários nas pastas protegidas
  printf 'security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1\nsecurity find-generic-password -s "Pool-Item-Absent" >/dev/null\nsecurity find-generic-password -s "Device-Only-Item" >/dev/null\nTOK=$(secret whapi-token)\nsecret pipedrive-api | head -n1\nx=~/Library/CloudStorage/GoogleDrive-athos@example.test/My\\ Drive\n' >"$C/scripts/keys.sh"
  cat >>"$C/scripts/keys.sh" <<'FRAG'
security find-generic-password -s "{svc}" 2>&1
grep -E 'security find-generic-password -s "([^"]+)"' x
security find-generic-password -s "{item_service()}" 2>&1
FRAG
  printf '{"numStartups":3,"oauthAccount":{"emailAddress":"athosmartins@example.test","accessToken":"sk-ant-oat01-PLANTEDTOKEN0123456789abcdef"}}\n' >"$H/.claude.json"
  printf '{"oauthAccount":{"emailAddress":"athosmartins+1@example.test"}}\n' >"$H/.gastown/claude-accounts/acct1/.claude.json"; printf '{"accessToken":"PLANTEDCREDSFILE9876543210"}\n' >"$H/.gastown/claude-accounts/acct1/.credentials.json"
  for d in Desktop Documents Library/CloudStorage; do printf 'SECRET-CANARY\n' >"$H/$d/SECRET-CANARY.txt"; chmod 000 "$H/$d"; done
  H8=$(printf '%s' "$H/.gastown/claude-accounts/acct1" | shasum -a 256 | cut -c1-8)
  # respostas dos stubs
  fx launchctl.managername Aqua; fx hostname mini-teste.local; fx scutil.get_ComputerName 'Mini de Teste'; fx scutil.get_LocalHostName Mini-de-Teste; fxrc scutil.get_HostName 1; fxerr scutil.get_HostName 'HostName: not set'
  fx sw_vers 'ProductName:\tmacOS\nProductVersion:\t14.5\nBuildVersion:\t23F79'; fx sysctl 'Mac14,3\nApple M2\n17179869184'; fx uname arm64
  fx df 'Filesystem Size Used Avail Capacity Mounted on\n/dev/disk3s5 228Gi 100Gi 50Gi 67% /System/Volumes/Data'
  fx networksetup.listallhardwareports 'Hardware Port: Ethernet\nDevice: en0\nEthernet Address: aa:bb:cc:dd:ee:01\n\nHardware Port: Wi-Fi\nDevice: en1\nEthernet Address: aa:bb:cc:dd:ee:02'
  fx networksetup.listallnetworkservices 'An asterisk (*) denotes that a network service is disabled.\nEthernet\n*Wi-Fi'; fx networksetup.getinfo 'DHCP Configuration\nIP address: 192.168.0.77\nRouter: 192.168.0.1'
  fx ipconfig.getifaddr_en0 192.168.0.77; fxrc ipconfig.getifaddr 1
  fx python3 'Python 3.9.6'; fx python3.11 'Python 3.11.9'; fx node v20.11.0; fx adb.version 'Android Debug Bridge version 1.0.41'; fx dolt 'dolt version 1.40.0'; fx gc 'gc 0.9.1'; fx bd 'bd version 1.1.0'; fx claude '2.1.302 (Claude Code)'; fx tmux 'tmux 3.4'; fx bw 2024.10.0
  fx defaults 2.14; fx pkgutil 'package-id: com.apple.pkg.CLTools_Executables\nversion: 16.2.0.0.1.1733547573'; fx xcode-select /Library/Developer/CommandLineTools
  fx sqlite3 'kTCCServiceSystemPolicyAllFiles|/opt/homebrew/bin/python3.11|2\nkTCCServiceSystemPolicyAllFiles|com.apple.Terminal|2\nkTCCServiceMicrophone|us.zoom.xos|2'
  fx systemextensionsctl '1 extension(s)\n--- com.apple.system_extension.driver_extension\nenabled\tactive\tteamID\tbundleID (version)\tname\t[state]\n*\t*\tTEAM123456\tcn.wch.CH34xVCPDriver (1.0/1)\tCH34xVCPDriver\t[activated enabled]'
  fx kextstat 'Index Refs Address Size Wired Name (Version)\n    1    0 0x0 0x0 0x0 com.apple.driver.AppleFoo (1.0)'
  cat >"$FX/system_profiler.out" <<'EOF'
USB:

    USB 3.1 Bus:

      Host Controller Driver: AppleT8112USBXHCI

        USB2.0 Hub:

          Product ID: 0x0610
          Vendor ID: 0x05e3  (Genesys Logic, Inc.)
          Serial Number: 000000000626
          Location ID: 0x01100000 / 2

            USB Serial:

              Product ID: 0x7523
              Vendor ID: 0x1a86  (QinHeng Electronics)
              Serial Number: WCH0001

        SM-A135M:

          Product ID: 0x6860
          Vendor ID: 0x04e8  (Samsung Electronics Co., Ltd.)
          Serial Number: R58N00AAAA1234
EOF
  fxrc pgrep.x_Google_Drive 1; fx adb.devices_l 'List of devices attached\nR58N00AAAA1234 device usb:1-1 product:x model:SM_A135M device:a13 transport_id:1\nR58N00BBBB5678 device usb:1-2 product:y model:SM_A035M device:a03 transport_id:2'
  fx lsof 'p100\ncpython3\nf5\nn*:8095\np200\ncnode\nf9\nn127.0.0.1:8087'; fx brew.leaves 'jq\nnode'; fx brew.list_cask 'wch-ch34x-usb-serial-driver'
  fx pluginkit '    com.google.drivefs.fpext(1.0)\n    com.apple.CloudDocs.iCloudDriveFileProvider(1.0)'
  fx ps 'bw serve --port 8087 --hostname 127.0.0.1 --session SECRETSESSIONKEYabcdef123456\n/usr/bin/python3 foo.py'
  fx pmset.g_custom 'AC Power:\n sleep 0\n displaysleep 10\n autorestart 1\n womp 1'; fx pmset.g_sched 'Repeating power events:\n  wakepoweron at 6:00AM every day'; fx systemsetup 'Remote Login: On'
  fx security.list_keychains_d_user '    "/Users/t/Library/Keychains/login.keychain-db"'; fxrc security.find_generic_password 44; fxerr security.find_generic_password 'The specified item could not be found in the keychain.'
  for it in Claude_Code_credentials Device_Only_Item "Claude_Code_credentials_$H8"; do fxrc "security.find_generic_password_s_$it" 0; fxerr "security.find_generic_password_s_$it" ''; done
  fx security.find_generic_password_s_Claude_Code_credentials 'keychain: "login.keychain-db"\n    "pdmn"<blob>="ck"'; fx security.find_generic_password_s_Device_Only_Item '    "pdmn"<blob>="cku"'
  fx launchctl.print_disabled 'disabled services = {\n\t"com.gascity.d" => disabled\n\t"com.whatsapp.b" => enabled\n}'; fx launchctl.list 'PID\tStatus\tLabel\n123\t0\tcom.whatsapp.a\n-\t0\tcom.gascity.c'
}
runinv() {   # runinv [VAR=valor ...]: roda o script no mundo atual. RC, OUT (stdout), ERR (stderr), ELAPSED
  local t0=$SECONDS
  OUT=$(env -i PATH="$B:$G" HOME="$H" MINI64_ROOT="$R" MINI64_EXTRA_PATH= CALLS="$CALLS" FX="$FX" "$@" "$TBASH" "$C/scripts/mini64/inventario.sh" 2>"$W/err"); RC=$?; ERR=$(cat "$W/err"); ELAPSED=$((SECONDS - t0))
}
snap() { ( cd "$W" && find home city root fx -type f 2>/dev/null | sort | while IFS= read -r f; do cksum "$f"; done ); }

echo "== R1 mundo feliz"
mkworld r1; snap >"$W/before.txt"; : >"$CALLS"; runinv
[ "$RC" = 0 ] && ok "sai 0" || bad "sai 0" "rc=$RC err=$ERR"
[ -f "$DOC" ] && ok "gera docs/runbooks/mini64/01-inventario.md" || bad "gera o doc" "sem $DOC"
[ "$ELAPSED" -lt 120 ] && ok "roda em menos de 2 min (${ELAPSED}s)" || bad "tempo" "${ELAPSED}s"
has 1 'ComputerName: .Mini de Teste.' "1: ComputerName"; has 1 'HostName: \(não definido\)' "1: HostName «not set» é resposta, não falha"; has 1 'IPv4 de en0: .192\.168\.0\.77.' "1: IP de en0"
has 1 'aa:bb:cc:dd:ee:01' "1: MAC para a reserva DHCP"; has 1 'en1: sem IPv4' "1: interface sem IP é resposta"; has 1 'macOS.*14\.5' "1: sw_vers"
has 2 'python3 → .*Python 3\.9\.6' "2: python3 com versão"; has 2 'claude → .*2\.1\.302' "2: claude com versão"; has 2 'iTerm\.app: não instalado' "2: iTerm ausente é dito"
has 2 'Acesso Total ao Disco · /opt/homebrew/bin/python3\.11' "2: FDA do python3.11"; has 2 'Acesso Total ao Disco · com\.apple\.Terminal' "2: FDA do Terminal"; has 2 '2 da cidade, 1 de outros apps' "2: conta o que é da cidade e o que não é"; hasnt 2 'zoom' "2: app fora da lista não é listado"
has 3 'Command Line Tools: .16\.2\.0\.0\.1\.1733547573.' "3: versão das CLT"; has 3 'python3\.11. · Python 3\.11\.9 · 1 plist' "3: python citado direto pelo plist"; has 3 '/usr/bin/python3' "3: /usr/bin/python3 consultado com CLT"; has 3 'venv/bin/python3' "3: python dentro de wrapper"; has 3 '1 lidos, 1 citados e ausentes' "3: o wrapper do plist foi lido e o x.py que outro plist cita, ausente, foi contado"
has 4 'cn\.wch\.CH34xVCPDriver' "4: extensão da WCH"; has 4 'kexts: nenhum da WCH' "4: kextstat sem WCH medido"; has 4 'cu\.wchusbserial1410' "4: porta serial"
has 5 '0x1a86 \| produto 0x7523 \| serial …0001' "5: placa WCH no USB, serial mascarado nos 4 últimos como o do adb"; has 5 'SM-A135M \| vendor 0x04e8 \| produto 0x6860 \| serial …1234' "5: celular no USB, serial mascarado"; hasnt 5 'R58N00AAAA1234|WCH0001|000000000626' "5: nenhum serial USB inteiro no doc"
has 5 '…1234 · device · SM_A135M' "5: celular com serial mascarado"; has 5 'A03 visível no adb: 1' "5: A03 visível é contado"
has 6 'id_ed25519\.pub: 256 SHA256:' "6: impressão da chave pública"; has 6 'athos@mbp' "6: authorized_keys diz a máquina"; has 6 'hetzner\.example' "6: known_hosts lista o host"; has 6 'ssh_host_ed25519_key\.pub: 256 SHA256:' "6: chave de host"; has 6 'HostName 203\.0\.113\.9' "6: ssh config"; hasnt 6 'ProxyCommand|PROXYSECRETWORD' "6: ProxyCommand não é copiado"
has 7 '\| com\.whatsapp \* \| 2 \| 0 \| 1 \| 0 \|' "7: com.whatsapp 2 plists, 0 desabilitado, 1 carregado"; has 7 '\| com\.gascity \* \| 2 \| 1 \| 1 \| 1 \|' "7: com.gascity: desabilitado, carregado e Disabled somam"; has 7 '\| org\.other \| 1 \|' "7: prefixo de fora sem estrela"; has 7 '8 plists lidos \(0 em formato binário' "7: um plist por arquivo, nenhum binário"; has 7 'com\.gascity\.d' "7: lista de desabilitados"
has 8 '3 plist\(s\), 2 com prefixo da cidade' "8: LaunchDaemons"; has 8 'gascity-nopasswd' "8: nome do sudoers.d"; has 9 'jq' "9: brew leaves"; has 9 'wch-ch34x' "9: brew cask"
has 10 '8095 · python3' "10: porta e processo"; has 10 '8087 · node' "10: outra porta"
has 11 'Claude Code-credentials. · presente · ThisDeviceOnly: não \(ck\)' "11: item presente, classe ck"; has 11 'Device-Only-Item. · presente · ThisDeviceOnly: SIM' "11: ThisDeviceOnly SIM"; has 11 'Pool-Item-Absent. · ausente' "11: item ausente"; has 11 'whapi-token' "11: nome passado ao secret"; has 11 'pipedrive-api' "11: segundo nome do secret"
has 12 'athosmartins@example\.test · sem \.credentials\.json' "12: conta padrão"; has 12 "athosmartins\+1@example\.test · \.credentials\.json existe · .Claude Code-credentials-$H8. · presente" "12: conta de pasta própria, item derivado do caminho"; has 12 'claude-pool-cred. · sem \.claude\.json' "12: pasta do pool sem perfil"
has 13 'GoogleDrive-athos@example\.test' "13: nome de montagem lido do código"; has 13 'não está rodando' "13: Drive parado"; hasnt 13 'canary' "13: ~/Library/CloudStorage não foi aberto"
has 14 'bw serve --port 8087 --hostname 127\.0\.0\.1' "14: bw serve em execução (só porta e hostname)"; has 14 'com\.gascity\.d' "14: plist com bw serve"; has 14 'w1\.sh' "14: wrapper com bw serve"; has 15 'sleep 0' "15: pmset -g custom"
docs 'sudo pmset -c autorestart 1' "checklist: comandos do pmset do mini atual"; docs 'Nome do computador = «Mini de Teste»' "checklist: nome"; docs '192\.168\.0\.77 \(MAC atual aa:bb:cc:dd:ee:01\)' "checklist: IP e MAC"; docs '«Python 3\.9\.6»' "checklist: python das CLT"
docs '^## Resumo' "tem Resumo"; docs '0 linha\(s\) com cara de segredo' "relata zero supressões no mundo limpo"; sf "" "R1/Resumo: no mundo feliz nenhuma seção é parcial"
[ "${OUT#*inventario: 15 seções,}" != "$OUT" ] && ok "o eco final conta as 15 seções numeradas (não o Resumo nem o Checklist)" || bad "contagem de seções do eco" "$OUT"
hasnt 11 '[{]svc[}]|[(][[]\^|item_service' "11: nome montado por variável ({svc}, ([^…, item_service()) não vira item do Keychain"
FIRST=$(grep -n '^## ' "$DOC" | head -n 1 | cut -d: -f2); [ "$FIRST" = "## Contents" ] && ok "## Contents é a primeira seção" || bad "## Contents primeiro" "$FIRST"
if [ -f "$HERE/../doc-rules-lint.py" ] && command -v python3 >/dev/null 2>&1; then lo=$(python3 -I "$HERE/../doc-rules-lint.py" --check --root "$(dirname "$DOC")" 01-inventario.md 2>&1); lrc=$?; [ "$lrc" = 0 ] && ok "doc passa no doc-rules-lint" || bad "doc-rules-lint" "rc=$lrc $lo"; fi
# nenhum segredo plantado, nem na saída do script
for sec in "$(sed -n '2p' "$W/k1")" "$(sed -n '3p' "$W/k1")" PLANTEDPLISTENVSECRET1234567890 PLANTEDTOKEN0123456789abcdef PLANTEDCREDSFILE9876543210 SECRETSESSIONKEYabcdef123456 PROXYSECRETWORD SECRET-CANARY; do
  if grep -qF -e "$sec" "$DOC" || [ "${OUT#*"$sec"}" != "$OUT" ] || [ "${ERR#*"$sec"}" != "$ERR" ]; then bad "segredo plantado não vaza" "achei: ${sec:0:24}"; else ok "não vaza: ${sec:0:24}…"; fi
done
docnot '-----BEGIN|sk-ant-|ghp_|AKIA[0-9A-Z]{16}|xox[abp]-|eyJ[A-Za-z0-9_-]{15,}[.]|[0-9a-f]{40}|Bearer ' "grep de padrões de token e chave privada no doc = 0"
snap >"$W/after.txt"; DIFF=$(diff "$W/before.txt" "$W/after.txt" | grep '^[<>]'); NDIFF=$(printf '%s\n' "$DIFF" | grep -c .)
{ [ "$NDIFF" = 1 ] && printf '%s' "$DIFF" | grep -q '^> .* city/docs/runbooks/mini64/01-inventario\.md$'; } && ok "só o doc foi escrito (nada fora de docs/runbooks/mini64)" || bad "escopo de escrita" "$DIFF"
[ "$(ls -A "$C/docs/runbooks/mini64")" = "01-inventario.md" ] && ok "pasta de trabalho .inventario-work removida" || bad "sobra na pasta" "$(ls -A "$C/docs/runbooks/mini64")"
ALLOW='^((ls|grep) .+|launchctl (managername|list|print-disabled .+)|security (list-keychains -d user|find-generic-password -s .+)|brew (leaves|list --cask)|networksetup (-listallhardwareports|-listallnetworkservices|-getinfo .+)|sqlite3 -readonly -separator \| .+ select [^;]+;|pmset -g (custom|sched)|defaults read .+|systemsetup -getremotelogin|adb (devices -l|version)|hostname|scutil --get [A-Za-z]+|sw_vers|sysctl -n .+|uname -m|df -h .+|ipconfig getifaddr en[0-9]|pkgutil --pkg-info=.+|xcode-select -p|systemextensionsctl list|kextstat|system_profiler SPUSBDataType|pgrep -x .+|lsof [+]c 0 -nP -iTCP -sTCP:LISTEN -Fcn|pluginkit -mA -p .+|ps -axo command=|(bw|claude|node|dolt|gc|bd|tmux|python3[.0-9]*) (--version|version|-V))$'
OFF=$(grep -vE -e "$ALLOW" "$CALLS" | head -n 3); [ -z "$OFF" ] && ok "só chamadas de leitura da allowlist ($(grep -c . "$CALLS") chamadas)" || bad "chamada fora da allowlist" "$OFF"
MUT=$(grep -E '(^| )(sudo|kill|rm) |launchctl (bootout|bootstrap|load|unload|enable|disable|kickstart)|defaults (write|delete)|brew (install|update|upgrade|uninstall)|security .*( -w| -g| -D|dump-keychain| delete-| add-)' "$CALLS" | head -n 3); [ -z "$MUT" ] && ok "nenhuma chamada que muda estado, nem -w/-g no security" || bad "chamada que muda estado" "$MUT"
SWEEP=$(grep -E "$H( |/?$)|Desktop|Documents|Downloads|CloudStorage|Mobile Documents|( |=)/Volumes( |/|$)" "$CALLS" | head -n 3); [ -z "$SWEEP" ] && ok "nenhum argumento aponta o \$HOME inteiro nem pasta protegida" || bad "varredura do HOME" "$SWEEP"
printf '%s' "$ERR" | grep -qi 'permission denied' && bad "stderr sem «permission denied» (os canários chmod 000 não foram tocados)" "$ERR" || ok "stderr sem «permission denied»"

echo "== R2 mundo que falha"
mkworld r2; rm -f "$FX"/*; for n in "$B"/*; do b=${n##*/}; fxrc "$b" 3; fxerr "$b" boom; done; rm -f "$B/brew" "$B/pluginkit" "$R/usr/bin/python3"; printf '#!/bin/sh\nexit 3\n' >"$B/pmset"; : >"$CALLS"
# rc 1 que NÃO é a resposta «vazio/not set/no receipt/sem IPv4»; kextstat responde vazio; print-disabled responde lixo
for b in lsof scutil.get_HostName pkgutil ipconfig; do fxrc "$b" 1; fxerr "$b" boom; done; fxrc kextstat 0; fxrc pgrep.x_adb 1; fx launchctl.print_disabled 'lixo que nao e do launchctl'; fxrc launchctl.print_disabled 0
[ "$ROOTUSER" = 0 ] && { chmod 000 "$H/.ssh/config" "$H/.claude.json"; }
runinv
[ "$RC" = 0 ] && ok "R2: sai 0 mesmo com tudo falhando" || bad "R2 rc" "rc=$RC $ERR"
has 1 'scutil --get ComputerName: scutil falhou' "R2/1: scutil rc≠0 é não apurado"; has 1 "${NA}scutil --get HostName: scutil falhou .rc=1: boom" "R2/1: rc 1 com erro que não é «not set» é não apurado"; hasnt 1 'não definido' "R2/1: nada vira «não definido»"
has 1 "${NA}ipconfig getifaddr en0" "R2/1: ipconfig rc 1 com erro é não apurado"; hasnt 1 'sem IPv4' "R2/1: erro não vira «sem IPv4»"; hasnt 1 'IP de LAN: nenhuma interface' "R2/1: nem «nenhuma interface tem IPv4»"; has 1 'não apurado.*networksetup' "R2/1: networksetup"
has 2 'não apurado.*TCC\.db.*[Ss]em Acesso Total ao Disco' "R2/2: TCC.db ilegível"; hasnt 2 '[0-9]+ da cidade,' "R2/2: sem leitura não há contagem «0 da cidade»"; has 2 'python3 → .* · versão não apurada' "R2/2: versão que falhou mantém o caminho"
has 3 "${NA}Command Line Tools" "R2/3: CLT"; hasnt 3 'não instalados' "R2/3: pkgutil rc 1 com erro não vira «CLT não instaladas»"; has 4 "${NA}systemextensionsctl list" "R2/4: systemextensionsctl"; has 4 "${NA}kextstat: respondeu vazio" "R2/4: kextstat vazio não vale como «nenhum kext»"; hasnt 4 'nenhum da WCH|nenhuma da WCH' "R2/4: falha não vira «nenhum da WCH»"
has 5 'não apurado.*system_profiler' "R2/5: system_profiler"; has 5 "${NA}celulares: o servidor adb não está rodando" "R2/5: adb parado não vira «0 celulares»"; hasnt 5 'celulares no adb' "R2/5: sem adb não há contagem de celulares"
has 7 '\| com\.whatsapp \* \| 2 \| \? \| \? \|' "R2/7: sem launchctl as colunas são «?», não 0"; has 7 'não apurado.*print-disabled.*formato inesperado' "R2/7: print-disabled fora do formato"; hasnt 7 'desabilitados pelo launchctl' "R2/7: sem lista de desabilitados inventada"
has 8 'não apurado.*print-disabled system' "R2/8: domínio system"; has 9 'brew leaves: brew ausente nesta máquina' "R2/9: brew ausente (command not found) é dito"; has 10 "${NA}lsof: lsof falhou" "R2/10: lsof"; hasnt 10 'nenhum listener' "R2/10: falha não vira «nenhum listener»"
has 11 "${NA}Keychain" "R2/11: Keychain da sessão"; has 11 'Claude Code-credentials. · não apurado \(keychain desta sessão' "R2/11: item sem resposta é não apurado"; hasnt 11 ' · ausente| · presente' "R2/11: nem «ausente» nem «presente» sem resposta"
has 12 "${NA}claude" "R2/12: claude --version"; has 12 'não apurado \(keychain desta sessão' "R2/12: itens das contas"; has 13 'não apurado.*pgrep' "R2/13: processo do Drive"; has 13 "${NA}extensões File Provider: pluginkit ausente nesta máquina" "R2/13: pluginkit ausente é dito"; has 14 "${NA}processos" "R2/14: ps"; has 15 "${NA}pmset" "R2/15: pmset"
docs 'não apurado: o pmset -g custom falhou' "R2/checklist: pmset que falhou não vira comando"; docnot 'sudo pmset' "R2/checklist: nenhum comando pmset inventado"
[ "$(grep -c '^| [0-9]*\. .* | ok |$' "$DOC")" = 0 ] && ok "R2/Resumo: nenhuma seção «ok»" || bad "R2/Resumo" "$(grep '^| [0-9]*\. .* | ok |$' "$DOC")"
if [ "$ROOTUSER" = 0 ]; then
  has 6 "${NA}~/\.ssh/config ausente ou sem leitura" "R2/6: ssh config ilegível"; has 12 'NÃO APURADO' "R2/12: .claude.json ilegível"
  chmod 000 "$H/Library/LaunchAgents"; runinv; has 7 'não apurado.*Library/LaunchAgents ausente ou sem leitura' "R2/7: pasta de plists sem leitura"; hasnt 7 'nenhum \*\.plist' "R2/7: pasta ilegível não vira «nenhum plist»"; has 3 'SEM caminho.*não apurado \(nem todos os plists foram lidos' "R2/3: plists ilegíveis não viram «nenhum python sem caminho»"; chmod 755 "$H/Library/LaunchAgents"
  chmod 000 "$W/wrappers/w1.sh"; runinv; has 3 "${NA}wrappers dos plists: grep falhou" "R2/3: wrapper ilegível deixa a lista de python parcial, não «nenhum»"; chmod 644 "$W/wrappers/w1.sh"
fi

echo "== R2b Keychain destravado mas o item responde rc 36; kextstat ausente; print-disabled com rc≠0"
fx security.list_keychains_d_user '    "/Users/t/Library/Keychains/login.keychain-db"'; fxrc security.list_keychains_d_user 0; fxrc security.find_generic_password 36; fxerr security.find_generic_password 'User interaction is not allowed.'
rm -f "$B/kextstat"; fxrc launchctl.print_disabled 3; fx launchctl.print_disabled ''
for b in systemextensionsctl system_profiler networksetup.listallhardwareports launchctl.list lsof pkgutil; do fxrc "$b" 0; fx "$b" 'lixo que nao e do comando'; done; fxrc ps 0; fx ps ''; runinv
has 4 "${NA}systemextensionsctl list: formato inesperado" "R2b/4: resposta fora do formato é não apurado (systemextensionsctl)"; has 5 "${NA}system_profiler SPUSBDataType: formato inesperado" "R2b/5: system_profiler fora do formato"
has 10 'sem nenhuma linha de porta \(formato inesperado\)' "R2b/10: lsof fora do formato não vira «nenhum listener»"; has 1 "${NA}networksetup -listallhardwareports: formato inesperado" "R2b/1: networksetup fora do formato"; has 7 "${NA}launchctl list: formato inesperado" "R2b/7: launchctl list fora do formato"
has 4 "${NA}kextstat: kextstat ausente nesta máquina" "R2b/4: kextstat ausente (command not found) é «não apurado», o exemplo da aceitação"; hasnt 4 'nenhum da WCH|nenhum kext' "R2b/4: kextstat ausente não vira «nenhum»"
has 7 "${NA}launchctl print-disabled gui/[0-9]+: launchctl falhou" "R2b/7: print-disabled com rc≠0 é não apurado"; has 7 '\| com\.whatsapp \* \| 2 \| \? \| \? \|' "R2b/7: colunas «?», não 0 desabilitados"
has 11 'Claude Code-credentials. · não apurado \(security falhou \(rc=36' "R2b/11: item que responde rc 36 é não apurado"; hasnt 11 ' · ausente| · presente' "R2b/11: rc 36 não vira «ausente»"
has 3 "${NA}Command Line Tools: pkgutil respondeu sem a linha «version:»" "R2b/3: pkgutil rc 0 sem «version:» é não apurado (formato inesperado)"; hasnt 3 'Command Line Tools: ``' "R2b/3: nem valor vazio"; has 14 "${NA}processos: ps respondeu vazio" "R2b/14: ps rc 0 sem nenhuma linha é não apurado"; hasnt 14 'nenhum «bw serve» rodando' "R2b/14: nem «nenhum bw serve»"

echo "== R3 mundo que responde vazio (controle positivo)"
mkworld r3; rm -f "$R/Library/LaunchDaemons"/* "$R/etc/sudoers.d"/* "$R/dev"/*; : >"$CALLS"
fx kextstat 'Index Refs Address Size Wired Name (Version)'; fx systemextensionsctl '0 extension(s)'; fx sqlite3 'kTCCServiceMicrophone|us.zoom.xos|2'; fxrc lsof 1; fx lsof ''
fx adb.devices_l 'List of devices attached'; fx brew.leaves ''; fx launchctl.print_disabled 'disabled services = {\n}'; fx launchctl.list 'PID\tStatus\tLabel'; fx ps '/usr/bin/python3 foo.py'
fxrc pkgutil 1; fx pkgutil ''; fxerr pkgutil "No receipt for 'com.apple.pkg.CLTools_Executables' found at '/'."; fx pluginkit '    com.apple.CloudDocs.iCloudDriveFileProvider(1.0)'
rm -f "$C/scripts/keys.sh" "$H/Library/LaunchAgents/com.whatsapp.a.plist" "$H/Library/LaunchAgents/com.gascity.d.plist" "$H/Library/LaunchAgents/com.athos.g.plist" "$W/wrappers/w1.sh" "$H/.gastown/claude-accounts/acct1"/.claude.json "$H/.gastown/claude-accounts/acct1"/.credentials.json; rmdir "$H/.gastown/claude-pool-cred" "$H/.gastown/claude-accounts/acct1"
printf '<plist><dict><key>Label</key><string>org.other.p3</string><key>ProgramArguments</key><array><string>%s/usr/bin/python3</string><string>x.py</string></array></dict></plist>\n' "$R" >"$H/Library/LaunchAgents/org.other.p3.plist"
runinv
[ "$RC" = 0 ] && ok "R3: sai 0" || bad "R3 rc" "rc=$RC $ERR"
has 2 '0 da cidade, 1 de outros apps' "R3/2: base aberta e sem concessão da cidade = 0 medido"; has 3 'Command Line Tools: não instalados' "R3/3: «No receipt» é resposta"
has 4 'nenhuma da WCH entre as listadas \(apurado\)' "R3/4: extensões sem WCH, medido"; has 4 'kexts: nenhum da WCH entre os carregados \(apurado\)' "R3/4: kexts sem WCH, medido"; has 4 'portas seriais.*nenhuma' "R3/4: sem /dev/cu.*"; hasnt 4 'não apurado' "R3/4: nada não apurado quando tudo respondeu"
has 5 'celulares no adb \(0.*: nenhum' "R3/5: adb sem celular = nenhum"; has 5 'A03 visível no adb: 0' "R3/5: A03 zero"; has 8 '/Library/LaunchDaemons: 0 plist' "R3/8: LaunchDaemons vazio"; has 8 'sudoers\.d.*nenhum \(o comando respondeu vazio\)' "R3/8: sudoers.d vazio"
has 9 'brew leaves: nenhum \(o comando respondeu vazio\)' "R3/9: brew sem leaves"; hasnt 9 'não apurado' "R3/9: sem falha"; has 10 'nenhum listener TCP visível' "R3/10: lsof rc 1 vazio"; hasnt 10 'não apurado' "R3/10: sem falha"
has 7 '\| com\.gascity \* \| 1 \| 0 \| 0 \| 1 \|' "R3/7: com override vazio, 0 desabilitado é medido (não «?»)"; has 11 'nenhum' "R3/11: sem nomes citados no código"; has 13 'não está rodando' "R3/13: Drive parado"
has 14 'nenhum «bw serve» rodando agora' "R3/14: sem bw serve"; has 7 '\| com\.athos \* \| 0 \| 0 \| 0 \| 0 \|' "R3/7: prefixo da cidade sem plist sai com 0 medido (não some)"; has 12 'claude-pool-cred.: pasta não existe \(apurado\)' "R3/12: pasta padrão ausente é dita"; has 12 'nenhuma conta de pasta própria' "R3/12: pasta de contas que existe e está vazia é «nenhuma conta»"
has 3 '/root/usr/bin/python3.: não executado' "R3/3: /usr/bin/python3 citado por um plist NÃO roda sem CLT (o shim abriria o instalador)"; hasnt 3 '/root/usr/bin/python3. · Python' "R3/3: nenhuma versão do shim no doc"
has 11 'Keychain citados no código: nenhum nas [0-9]+ raízes lidas \([0-9]+ candidatas não existem' "R3/11: o «nenhum» dos itens do Keychain diz quantas raízes candidatas não existem"
has 11 'passados ao secret: nenhum nas [0-9]+ raízes lidas \([0-9]+ candidatas não existem' "R3/11: o «nenhum» dos nomes do secret diz o mesmo"; has 1 'HostName: \(não definido\)' "R3/1: HostName"

echo "== R4 saída hostil"
mkworld r4; fx hostname 'evil`id`\033[31mred'; fx brew.leaves 'good\nMOTHERDUCK_TOKEN=abcd1234efgh5678ijkl\nghp_0123456789abcdefghijABCDEFGHIJ0123456789\nlongo-'"$(printf 'x%.0s' $(seq 1 300))"; printf '<plist><dict><key>Label</key><string>com.gascity.m</string><key>ProgramArguments</key><array><string>/Users/x/missing-wrapper.sh</string></array></dict></plist>\n' >"$H/Library/LaunchAgents/com.gascity.m.plist"; runinv
has 3 '1 lidos, 2 citados e ausentes' "R4/3: um segundo wrapper citado e ausente soma"
[ "$RC" = 0 ] && ok "R4: sai 0" || bad "R4 rc" "rc=$RC $ERR"
docnot 'abcd1234efgh5678ijkl|ghp_0123' "R4: token na saída de um comando é suprimido"; docs '\[suprimido\]' "R4: marca [suprimido]"; docs '[1-9][0-9]* linha\(s\) com cara de segredo' "R4: o cabeçalho conta as supressões"
[ "$(tr -cd '\033' <"$DOC" | wc -c | tr -d ' ')" = 0 ] && ok "R4: sem ESC no doc" || bad "R4 ESC" "o doc tem ESC"
[ "$(( $(grep -c '^```$' "$DOC") % 2 ))" = 0 ] && ok "R4: cercas de código balanceadas (crase da máquina não rompe)" || bad "R4 cercas" "$(grep -c '^```$' "$DOC")"
[ "$(awk '/^## Checklist/ { exit } length > 300 && !/^Gerado por/' "$DOC" | wc -l | tr -d ' ')" = 0 ] && ok "R4: nenhuma linha de dado (fora do checklist) passa de 300 caracteres" || bad "R4 linha longa" "há linha > 300"
if [ -f "$HERE/../doc-rules-lint.py" ] && command -v python3 >/dev/null 2>&1; then python3 -I "$HERE/../doc-rules-lint.py" --check --root "$(dirname "$DOC")" 01-inventario.md >/dev/null 2>&1 && ok "R4: doc segue válido no doc-rules-lint" || bad "R4 lint" "doc-rules-lint reprovou"; fi

echo "== R5 sonda pendurada"
mkworld r5; for s in system_profiler pkgutil lsof brew.leaves brew.list_cask pmset.g_custom pmset.g_sched; do printf '30\n' >"$FX/$s.sleep"; done   # a chave do .sleep é a MAIS LONGA que existe no fx (brew.leaves, não brew): 7 chamadas penduradas × 3 s = 21 s, bem acima do orçamento de 15 s
runinv MINI64_PROBE_S=3 MINI64_BUDGET_S=15
[ "$RC" = 0 ] && ok "R5: sai 0" || bad "R5 rc" "rc=$RC $ERR"
[ "$ELAPSED" -le 28 ] && ok "R5: o orçamento corta a espera (${ELAPSED}s, com sondas de 30 s penduradas)" || bad "R5 tempo" "${ELAPSED}s"
has 5 'system_profiler estourou o prazo' "R5/5: sonda estourada é dita"; docs 'orçamento de 15s esgotado' "R5: acabou o orçamento e o doc diz"

echo "== R6 pasta sem escrita / HOME vazio"
mkworld r6; runinv; cksum "$DOC" >"$W/doc.ck"
if [ "$ROOTUSER" = 0 ]; then
  chmod 555 "$C/docs/runbooks/mini64"; runinv; chmod 755 "$C/docs/runbooks/mini64"
  [ "$RC" = 1 ] && ok "R6: pasta sem escrita sai 1" || bad "R6 rc" "rc=$RC"; printf '%s' "$ERR" | grep -q 'não consegui criar a pasta de trabalho' && ok "R6: diz o motivo" || bad "R6 msg" "$ERR"
  [ "$(cksum "$DOC")" = "$(cat "$W/doc.ck")" ] && ok "R6: o doc anterior fica intacto" || bad "R6 doc anterior" "mudou"
fi
runinv HOME=; [ "$RC" = 2 ] && ok "R6: HOME vazio sai 2" || bad "R6 HOME" "rc=$RC"

echo "== R7 duas rodadas"
mkworld r7; runinv; runinv
[ "$(ls -A "$C/docs/runbooks/mini64")" = "01-inventario.md" ] && ok "R7: sem sobra entre rodadas" || bad "R7 sobra" "$(ls -A "$C/docs/runbooks/mini64")"; [ "$(grep -c '^## Contents' "$DOC")" = 1 ] && ok "R7: o doc é substituído, não acrescentado" || bad "R7 doc" "Contents repetido"

echo "== R8 estático"
"$TBASH" -n "$SCRIPT" 2>/dev/null && ok "bash -n limpo ($("$TBASH" --version | head -n 1 | cut -c1-40))" || bad "bash -n" "$("$TBASH" -n "$SCRIPT" 2>&1 | head -n 2)"
if [ -n "${MINI64_B32:-}" ]; then o=$("$MINI64_B32" -n "$SCRIPT" 2>&1); r=$?; { [ "$r" = 0 ] && [ -z "$o" ]; } && ok "bash 3.2 -n limpo (rc 0 e sem saída, como o guard do gate)" || bad "bash 3.2 -n" "rc=$r $o"
  printf '%s\n' 'x=$(case $1 in a) echo A;; *) echo Z;; esac)' >"$TMP/ctl.sh"; "$MINI64_B32" -n "$TMP/ctl.sh" >/dev/null 2>&1 && bad "controle positivo do 3.2" "a forma ruim passou" || ok "controle positivo do 3.2: a forma ruim é rc≠0"; fi
CODE=$(grep -vE '^[[:space:]]*#' "$SCRIPT")
B4=$(grep -nE '(declare|typeset) +-A|mapfile|readarray|[$][{][A-Za-z_]+(\^\^|,,)[}]|&>>|[|]&|=~|coproc|printf +-v|local +-n' <<<"$CODE" | head -n 3); [ -z "$B4" ] && ok "sem recurso de bash 4 (array associativo, mapfile, =~, \${x^^})" || bad "recurso de bash 4" "$B4"
SW=$(grep -nE '(ls|find|du|stat|cat|grep|tar|rsync|cp|mv|cd|tree)[^#|;]*(Desktop|Documents|Downloads|Pictures|Movies|Music|CloudStorage|Mobile Documents|/Volumes)|"[$]H"/[*]|[$]HOME/[*]|(ls|find|du|tree|ncdu|grep -r)[^#|;]*"?[$](H|HOME)"?( |$)' <<<"$CODE" | head -n 3); [ -z "$SW" ] && ok "nenhum comando varre o \$HOME nem pasta protegida" || bad "varredura de pasta protegida no código" "$SW"
echo "== R9 uma falha só (cada mundo: falhas em seções disjuntas; o Resumo aponta exatamente elas)"
mkworld f1; fxrc security.list_keychains_d_user 3; fxerr security.list_keychains_d_user boom; runinv
sf "11 12 " "R9/1 só o list-keychains falha: as contas Claude também ficam parciais"; has 12 'Claude Code-credentials. · não apurado \(keychain desta sessão' "R9/1: a linha da conta diz não apurado"
mkworld f2; ln -s "$W/nao-existe" "$H/Library/LaunchAgents/aaa.plist"; ln -s "$W/nao-existe" "$H/.ssh/aaa.pub"; runinv
sf "3 6 7 14 " "R9/2 symlink quebrado na frente dos plists e das .pub é leitura parcial"; has 6 "${NA}aaa\.pub" "R9/2: a .pub quebrada é não apurada, não pulada em silêncio"; hasnt 7 'nenhum \*\.plist' "R9/2: não vira «nenhum *.plist»"; hasnt 3 'SEM caminho.*: nenhum' "R9/2: nem «nenhum python sem caminho»"; hasnt 14 'argumentos: nenhum' "R9/2: nem «nenhum bw serve» nos plists"
if [ "$ROOTUSER" = 0 ]; then mkworld f3; chmod 000 "$H/Library/LaunchAgents/com.gascity.d.plist"; runinv
  sf "3 7 14 " "R9/3 plist ilegível (o do bw serve) deixa a leitura parcial nas 3 seções"; has 14 'argumentos: não apurado' "R9/3: o «bw serve» dos plists é não apurado"; hasnt 14 'argumentos: nenhum' "R9/3: não vira «nenhum»"
  chmod 644 "$H/Library/LaunchAgents/com.gascity.d.plist"; chmod 444 "$H/Library/LaunchAgents"; runinv; chmod 755 "$H/Library/LaunchAgents"
  sf "3 7 14 " "R9/3b pasta de plists só com r--: os nomes casam e nenhum abre, é leitura parcial"; hasnt 7 'nenhum \*\.plist' "R9/3b: não vira «nenhum *.plist»"; fi
mkworld f4; fx adb.devices_l 'List of devices attached\nR58N00AAAA1234 device usb:1-1 product:x model:SM_A135M device:a13 transport_id:1\nR58N00CCCC9999 unauthorized usb:1-3 transport_id:3'
fx networksetup.getinfo 'nada que o script reconheça'; runinv MINI64_SCAN_ROOTS=/nao/existe
sf "1 5 11 13 " "R9/4 adb sem modelo, getinfo fora do formato e nenhuma raiz de código"; has 5 'A03 visível no adb: 0 \(\+1 com modelo ilegível' "R9/4: o 0 de A03 diz que um aparelho não tem modelo legível"
has 1 "${NA}networksetup -getinfo .*formato inesperado" "R9/4: getinfo sem linha reconhecível é não apurado"; has 13 "${NA}pontos de montagem" "R9/4: sem varredura de nomes o Drive não diz «nenhum»"; hasnt 13 'nenhum encontrado' "R9/4: nem «nenhum encontrado»"
mkworld f5; fx security.find_generic_password_s_Device_Only_Item '    "acct"<blob>="x"'; fxrc ipconfig.getifaddr_en0 1; fx ipconfig.getifaddr_en0 ''; exp="1 11 "; if [ "$ROOTUSER" = 0 ]; then chmod 000 "$H/.gastown/claude-accounts"; exp="1 11 12 "; fi; runinv; chmod 755 "$H/.gastown/claude-accounts"
sf "$exp" "R9/5 sem IPv4 em en0..en3, item sem classe de acesso (e, fora do root, pasta de contas ilegível)"; has 1 "${NA}IP de LAN: nenhuma interface" "R9/5: nenhuma interface com IPv4 é não apurado"; docs 'reserva DHCP de \? \(MAC atual \?\)' "R9/5: o item 2 do checklist mostra «?», não um IP inventado"; docs 'ssh-keygen -R <IP do mini>' "R9/5: o marcador «<IP do mini>» não vira «?»"; has 11 'Device-Only-Item. · presente · classe de acesso não apurada' "R9/5: item presente sem pdmn não vira «ThisDeviceOnly: não»"
[ "$ROOTUSER" = 0 ] && has 12 "${NA}.*claude-accounts" "R9/5: a pasta de contas ilegível é não apurada, não «sem contas»"
mkworld f6; ln -s /nao/existe "$R/dev/cu.a-quebrado"; LA="$H/Library/LaunchAgents"; rm -f "$LA/com.athos.g.plist" "$LA/com.urblink.e.plist" "$LA/br.urblink.f.plist" "$W/wrappers/w1.sh"
for i in a b c d e f g h i j k l; do printf '<plist><dict><key>Label</key><string>px%s.y.z</string><key>ProgramArguments</key><array><string>/opt/px/%s/bin/python</string></array></dict></plist>\n' "$i" "$i" >"$LA/px$i.plist"; done
for i in $(seq 1 27); do printf 'security find-generic-password -s "Item-%s"\n' "$i" >>"$C/scripts/keys.sh"; done
fxrc ipconfig.getifaddr_en0 1; fx ipconfig.getifaddr_en0 ''; fx ipconfig.getifaddr_en1 192.168.0.88; fx scutil.get_ComputerName "Athos's Mac mini"; fxrc scutil.get_LocalHostName 1; fxerr scutil.get_LocalHostName 'LocalHostName: not set'
fx lsof 'p100\ncpython3\nf5\nn*:8095\np200\ncnode\nf9\nn127.0.0.1:8095'; fx networksetup.listallnetworkservices 'An asterisk (*) denotes that a network service is disabled.\nEthernet\nWi-Fi\nBridge\nThunderbolt\nUSB LAN\nVPN'; runinv
sf "" "R9/6 mundo sem falha: tudo que tem resposta fica «ok»"; docs '192\.168\.0\.88 \(MAC atual aa:bb:cc:dd:ee:02\)' "R9/6: o MAC do checklist é o da interface que deu o IP (en1), não o do en0"
docs "Nome do computador = «Athos's Mac mini»" "R9/6: o apóstrofo do nome do computador sobrevive"; docs 'ssh-keygen -R <nome do mini>\.local' "R9/6: o marcador «<nome do mini>» não vira «?»"
has 10 '8095 · node' "R9/6: duas listeners na mesma porta: node"; has 10 '8095 · python3' "R9/6: duas listeners na mesma porta: python3"; has 1 '\(\+2 serviços' "R9/6: serviço de rede além dos 4 consultados é contado"
has 3 '0 lidos, 2 citados e ausentes' "R9/6: wrapper citado e ausente é dito mesmo sem nenhum lido"; has 7 '\(\+3 prefixos omitidos;' "R9/6: o corte da tabela de plists é dito"; has 7 '\| com\.athos \* \| 0 ' "R9/6: prefixo da cidade com 0 plist não é o que o corte derruba"
has 4 'cu\.a-quebrado' "R9/6: o link quebrado em /dev/cu.* casa o glob e entra na lista"; hasnt 4 'nenhuma \(o /dev' "R9/6: nem «nenhuma»"; has 11 '\(\+5 nomes omitidos;' "R9/6: o corte dos 25 nomes do Keychain é dito"; has 3 '\(\+3 caminhos de python' "R9/6: o corte dos 10 pythons citados pelos plists é dito"
mkworld f7; rm -f "$B/python3"; fxrc pkgutil 1; fx pkgutil ''; fxerr pkgutil "No receipt for 'com.apple.pkg.CLTools_Executables' found at '/'."
fx networksetup.listallhardwareports 'Hardware Port: Ethernet\nDevice: en0\nEthernet Address: aa:bb:cc:dd:ee:01\n\nHardware Port: Wi-Fi\nDevice: en1\n\nHardware Port: Thunderbolt\nDevice: en2\nEthernet Address: aa:bb:cc:dd:ee:03'
fxrc ipconfig.getifaddr_en0 1; fx ipconfig.getifaddr_en0 ''; fx ipconfig.getifaddr_en1 192.168.0.88; runinv MINI64_EXTRA_PATH=":$R/usr/bin"
sf "1 2 " "R9/7 sem CLT o python3 do PATH é o shim do sistema (versão não pedida); o en1 que deu o IP não tem MAC na lista"; has 1 "${NA}MAC de en1" "R9/7: a interface sem linha de MAC é não apurada"; docnot 'MAC atual aa:bb:cc:dd:ee:03' "R9/7: nem herda o MAC da porta seguinte"; has 2 'python3 → .*versão não executada' "R9/7: a linha diz que não executou"; hasnt 2 'python3 → .* · Python' "R9/7: nenhuma versão do shim no doc"
mkworld f8; rm -f "$H/Library/LaunchAgents"/* "$B/python3"; runinv MINI64_EXTRA_PATH=":$R/usr/bin"
sf "" "R9/8 pasta de plists que existe e está vazia, CLT confirmadas: nenhuma seção parcial"; has 7 'nenhum \*\.plist' "R9/8: «nenhum *.plist» quando MEDIU"; has 3 'SEM caminho.*: nenhum' "R9/8: nenhum python sem caminho"
has 14 'argumentos: nenhum' "R9/8: nenhum bw serve nos plists"; has 2 'python3 → .*usr/bin/python3. · Python 3\.9\.6' "R9/8: com CLT confirmadas o python3 de /usr/bin é executado"
mkworld f9; rm -f "$H/Library/LaunchAgents"/*; printf '<plist><dict><key>Label</key><string>com.gascity.estrela</string><key>ProgramArguments</key><array><string>/bin/echo</string></array></dict></plist>\n' >"$H/Library/LaunchAgents/*.plist"; runinv
sf "" "R9/9 uma pasta com um único arquivo chamado «*.plist»: o glob devolve o próprio padrão e o arquivo existe"; has 7 '1 plists lidos' "R9/9: o arquivo é lido, a pasta não é «vazia»"; hasnt 7 'nenhum \*\.plist' "R9/9: não vira «nenhum *.plist»"
echo "== R10 plists: argumentos do 4º em diante, valor multilinha, binário; bw serve com «=» e sem valor"
plist() { printf '<plist><dict><key>Label</key><string>%s</string><key>ProgramArguments</key><array>' "$1"; shift; for a in "$@"; do printf '<string>%s</string>' "$a"; done; printf '</array></dict></plist>\n'; }   # plist <Label> <arg>...
mkworld g1; LA="$H/Library/LaunchAgents"; rm -f "$LA"/*; printf '#!/bin/bash\nexec /Users/test/venv2/bin/python3 foo.py\nbw serve --port 8088\n' >"$W/wrappers/w2.sh"
plist com.gascity.t1 /opt/homebrew/bin/timeout -k 20 840 /bin/bash "$(printf '\n\t  ')$W/wrappers/w2.sh" >"$LA/com.gascity.t1.plist"; plist com.gascity.t2 /bin/bash -l -c 'bw serve --port 8087' >"$LA/com.gascity.t2.plist"
plist com.gascity.t3 /opt/homebrew/bin/timeout -k 20 /opt/px/bin/python3 z.py >"$LA/com.gascity.t3.plist"; plist com.gascity.t4 /opt/homebrew/bin/timeout -k 20 840 python3 y.py >"$LA/com.gascity.t4.plist"
plist com.gascity.t5 /bin/bash -c "$(printf 'cd /tmp\n\techo um\nbw serve --port 8090')" >"$LA/com.gascity.t5.plist"; plist com.gascity.t6 /bin/echo >"$LA/com.gascity.t6"$'\n'"x.plist"; runinv
sf "" "R10/1 plists com argumentos além do 3º, valor multilinha e nome de arquivo com LF: nada fica parcial"
has 3 'venv2/bin/python3' "R10/1: python dentro do wrapper que vem atrás de «timeout -k 20 840 /bin/bash» (6º argumento)"; has 3 '1 lidos, 0 citados e ausentes' "R10/1: o wrapper do 6º argumento foi lido"; has 3 'opt/px/bin/python3' "R10/1: python absoluto no 4º argumento"; has 3 'SEM caminho.*: 1 python3;' "R10/1: python sem caminho no 5º argumento"
has 14 'argumentos: com\.gascity\.t2 com\.gascity\.t5' "R10/1: «bw serve» no 4º argumento e dentro de um valor multilinha"; has 14 'w2\.sh' "R10/1: o wrapper do 6º argumento que sobe «bw serve»"; has 3 'plists de ~/Library/LaunchAgents' "R10/1: a seção 3 diz que só lê os plists do usuário"; has 14 'plists de ~/Library/LaunchAgents \(não os de /Library\)' "R10/1: a seção 14 também"
has 7 '6 plists lidos' "R10/1: conta ARQUIVOS (o valor multilinha e o nome com LF não viram linhas a mais)"; has 7 '\| com\.gascity \* \| 6 \|' "R10/1: os 6 plists no prefixo"
pfx=$(sect 7 | awk -F'|' '/^\| / && !/^\| prefixo / { c = $2; gsub(/^ +| +$/, "", c); sub(/ [*]$/, "", c); print c }' | sort | tr '\n' ,); [ "$pfx" = "br.urblink,com.athos,com.gascity,com.urblink,com.whatsapp," ] && ok "R10/1: a tabela só tem os prefixos reais (a continuação do valor multilinha não vira linha-fantasma)" || bad "R10/1 linha-fantasma na tabela" "$pfx"
mkworld g2; rm -f "$H/Library/LaunchAgents/com.gascity.c.plist" "$H/Library/LaunchAgents/com.gascity.d.plist"; runinv
sf "" "R10/2 controle: sem plist binário e sem python sem caminho nem bw serve nos argumentos, tudo lido"; has 3 'SEM caminho.*: nenhum' "R10/2 controle: «nenhum python sem caminho» quando MEDIU"; has 14 'argumentos: nenhum' "R10/2 controle: «nenhum bw serve» nos plists quando MEDIU"
printf 'bplist00\000\001\002 binario' >"$H/Library/LaunchAgents/com.whatsapp.bin.plist"; runinv
sf "3 14 " "R10/2 plist binário: o awk não lê os argumentos dele, então as seções 3 e 14 ficam parciais"; has 3 "${NA}1 plist\(s\) em formato binário" "R10/2: a seção 3 diz o motivo"; hasnt 3 'SEM caminho.*: nenhum' "R10/2: «nenhum python sem caminho» não vale com binário"; hasnt 14 'argumentos: nenhum' "R10/2: nem «nenhum bw serve» nos plists"; has 7 '7 plists lidos \(1 em formato binário' "R10/2: o binário continua contado na seção 7"
mkworld g3; fx ps '/opt/homebrew/bin/bw serve --port=9999 --hostname=0.0.0.0 --session SECRETSESSIONKEYabcdef123456\nbw serve --hostname\nbw serve --port --hostname 127.0.0.1\nbw serve --port='; runinv
sf "14 " "R10/3 bw serve com «=», sem valor ou com outra opção no lugar do valor: não apurado, nunca «(padrão)»"; has 14 'bw serve --port 9999 --hostname 0\.0\.0\.0' "R10/3: a forma «--port=N --hostname=H» é lida"; has 14 'bw serve --port \(padrão\) --hostname não apurado' "R10/3: --hostname sem valor"
has 14 'bw serve --port não apurado --hostname 127\.0\.0\.1' "R10/3: --port seguido de outra opção"; has 14 'bw serve --port não apurado --hostname \(padrão\)' "R10/3: --port= vazio"; has 14 "${NA}bw serve" "R10/3: o Resumo conta a linha ilegível"; docnot 'SECRETSESSIONKEYabcdef123456' "R10/3: o --session não vaza"
echo "== R11 harness: o calls.log sobrevive a 2 wrappers concorrentes (etapas de um pipeline do script)"
: >"$CALLS"; for i in $(seq 1 150); do echo x | CALLS="$CALLS" "$G/grep" -E aa | CALLS="$CALLS" "$G/grep" -vE bb >/dev/null; done
BADL=$(grep -vE '^grep -(E aa|vE bb)$' "$CALLS" | head -n 2); NL=$(grep -c . "$CALLS")   # controle de vivacidade: 300 linhas = os wrappers gravaram mesmo (sem CALLS o log fica vazio e o teste passaria vazio)
{ [ -z "$BADL" ] && [ "$NL" = 300 ]; } && ok "R11: 150 pipelines com 2 grep concorrentes: 300 linhas, todas inteiras no calls.log (sem isso a allowlist reprova por acaso)" || bad "R11 calls.log com linhas misturadas («grepgrep -vE -E …») ou vazio" "linhas=$NL (esperado 300) $BADL"
echo "== $PASS ok, $FAIL BAD"; [ "$FAIL" = 0 ]
