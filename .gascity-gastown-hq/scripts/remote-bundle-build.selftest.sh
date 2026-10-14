#!/usr/bin/env bash
# remote-bundle-build.selftest.sh — hermético: cidade, ~/.claude e papel são fixtures em mktemp; nada lê o mini de verdade.
#
# Contents
#   Casos · Controle negativo
#
# CASOS: caminhos reescritos e nenhum /Users/ no bundle · hook keep presente e executável, drop ausente, shim VERBATIM ·
#   shim_needs lista os 4 subcomandos do gc · chave fora da lista e regra de permissão de macOS saem (e ficam no manifest) ·
#   settings.local.json nunca entra · RECUSA (exit 3, e nenhum OUT nem .tmp sobra): hook fora da tabela, shim com `&& curl`,
#   hook que não é `command`, script keep ausente / com osascript / com segredo / com caminho do mini, settings ilegível,
#   skill com .duckdb / CPF / symlink que sai da cidade / symlink de diretório por dentro · skills são desreferenciadas
#   (arquivo comum, não link) · mesma entrada → mesmo hash, byte mudado → hash outro · verify (0 limpo; 4 se mudou, faltou
#   ou sobrou arquivo, ou se o manifest não dá para ler ou tem entrada sem sha256) · settings com JSON válido de forma
#   inesperada (hooks como lista) recusa dizendo "formato inesperado" · regra de permissão de macOS: em allow sai e fica CONTADA
#   no manifest, em deny/ask recusa · script cujo nome só CONTÉM o de um keep recusa · OUT não gravável: a mensagem diz "não consegui gravar", não culpa
#   a entrada; troca de OUT que falha (guarda de comportamento que já existia) deixa o bundle anterior intacto.
# CONTROLE NEGATIVO: a tabela POLICY perde a linha de um hook (sed) e o mesmo build TEM que passar a recusar.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
B="${BUNDLE_BUILD_UNDER_TEST:-$HERE/remote-bundle-build.py}"
T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/bundle-selftest.XXXXXX")" && pwd -P)
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
fails=0; n=0
ok() { n=$((n+1)); if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
has() { grep -qF -- "$2" "$1" 2>/dev/null; }
NOTIFY='export PATH=\"$HOME/go/bin:$HOME/.local/bin:$PATH\" && '

fixture() {  # fixture DIR — cidade + ~/.claude + papel "dog" com os mesmos tipos de hook do mini
  local d=$1 c=$1/gt/.gascity-gastown-hq h=$1/home/.claude
  mkdir -p "$c/.gc/agents/dog/.claude" "$c/skills/ok-skill" "$h/hooks" "$d/gt/.claude"
  printf '#!/usr/bin/env bash\ncat >/dev/null; jq -n "{}"\n' > "$h/hooks/filter-bash-output.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$h/hooks/ntfy-on-stop.sh"; chmod +x "$h"/hooks/*.sh
  cat > "$h/settings.json" <<EOF
{"statusLine": {"command": "$h/statusline.sh"}, "model": "opus",
 "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "~/.claude/hooks/ntfy-on-stop.sh"}]}],
           "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "~/.claude/hooks/filter-bash-output.sh"}]}]},
 "permissions": {"allow": ["Bash(git:*)", "Bash(launchctl:*)"], "additionalDirectories": ["$d/gt"]}}
EOF
  cat > "$c/.gc/settings.json" <<EOF
{"env": {"A": "1"}, "permissions": {"deny": ["Bash(sudo:*)"]},
 "hooks": {"PreCompact": [{"matcher": "", "hooks": [{"type": "command", "command": "${NOTIFY}gc handoff --auto \"context cycle\""}]}],
           "SessionStart": [{"matcher": "startup", "hooks": [{"type": "command", "command": "${NOTIFY}GC_MANAGED_SESSION_HOOK=1 GC_HOOK_EVENT_NAME=SessionStart gc prime --hook --hook-format codex"}]}],
           "UserPromptSubmit": [{"matcher": "", "hooks": [{"type": "command", "command": "${NOTIFY}gc nudge drain --inject"}, {"type": "command", "command": "${NOTIFY}gc mail check --inject"}]}],
           "PreToolUse": [{"matcher": "^Bash\$", "hooks": [{"type": "command", "command": "$c/scripts/home-scan-guard.sh"}]}]}}
EOF
  cat > "$c/.gc/agents/dog/.claude/settings.json" <<EOF
{"claudeMdExcludes": ["$d/gt/CLAUDE.md"], "autoMemoryEnabled": false, "enabledPlugins": {"x": true},
 "hooks": {"PostToolUse": [{"matcher": "^Bash\$", "hooks": [{"type": "command", "command": "$c/scripts/cut-output-shadow.sh"}]}]}}
EOF
  echo 'SENTINEL_LOCAL_PERMS_9f3a' > "$h/settings.local.json"; cp "$h/settings.local.json" "$d/gt/.claude/settings.local.json"
  echo 'SENTINEL_LOCAL_PERMS_9f3a' > "$c/.gc/agents/dog/.claude/settings.local.json"
  echo '# skill' > "$c/skills/ok-skill/SKILL.md"
  mkdir -p "$c/.gc/agents/dog/.claude/skills"; ln -s "$c/skills/ok-skill" "$c/.gc/agents/dog/.claude/skills/ok-skill"
}
build() {  # build DIR OUT [extra...] — rc do builder; stderr em $T/err
  local d=$1 o=$2; shift 2
  python3 -I "$B" build --city "$d/gt/.gascity-gastown-hq" --claude-home "$d/home/.claude" --mini-home "$d/home" --role dog \
    --role-dir "$d/gt/.gascity-gastown-hq/.gc/agents/dog" --remote-root /home/runner/rr --remote-home /home/runner --out "$o" "$@" 2>"$T/err" >"$T/outp"
}
refuses() {  # refuses NOME DIR [extra...] — exit 3, mensagem, e nada deixado para trás
  local name=$1 d=$2; shift 2; wipe "$d/out"; build "$d" "$d/out" "$@"; local rc=$?
  [ $rc = 3 ] && [ ! -e "$d/out" ] && [ -z "$(ls -d "$d"/out.tmp.* 2>/dev/null)" ] && grep -q RECUSADO "$T/err"
  ok $? "$name → exit 3, mensagem e nada escrito (rc=$rc)"
}
wipe() { [ -e "$1" ] && find "$1" -delete 2>/dev/null; return 0; }
fresh() { wipe "$T/f"; fixture "$T/f"; }
hash_of() { jq -r .bundle_hash "$1/manifest.json"; }

fresh; build "$T/f" "$T/f/out"; rc=$?
ok $rc "build limpo sai 0"; [ $rc = 0 ] || cat "$T/err" >&2
O=$T/f/out
grep -rqF "/Users/" "$O"; [ $? != 0 ]; ok $? "nenhum /Users/ no bundle"
grep -rqF "$T" "$O"; [ $? != 0 ]; ok $? "nenhum caminho da fixture (=do mini) no bundle"
has "$O/home/.claude/settings.json" '"/home/runner/rr/work"'; ok $? "additionalDirectories reescrito para o work do servidor"
has "$O/role/dog/.claude/settings.json" '/home/runner/rr/work/CLAUDE.md'; ok $? "claudeMdExcludes reescrito"
[ -x "$O/home/.claude/hooks/filter-bash-output.sh" ]; ok $? "hook keep presente e executável"
[ ! -e "$O/home/.claude/hooks/ntfy-on-stop.sh" ] && ! grep -rqi ntfy "$O/home" "$O/city"; ok $? "hook drop (ntfy) ausente do bundle e das settings"
! grep -q 'home-scan-guard\|cut-output-shadow' "$O/city/settings.json" "$O/role/dog/.claude/settings.json"; ok $? "hooks drop do city e do papel saíram"
has "$O/city/settings.json" 'export PATH=\"$HOME/go/bin:$HOME/.local/bin:$PATH\" && gc handoff --auto \"context cycle\"'; ok $? "shim fica VERBATIM (handoff, com o export do PATH)"
has "$O/city/settings.json" 'GC_MANAGED_SESSION_HOOK=1 GC_HOOK_EVENT_NAME=SessionStart gc prime --hook --hook-format codex'; ok $? "shim fica VERBATIM (prime, com as variáveis)"
[ "$(jq -c .shim_needs "$O/manifest.json")" = '["handoff --auto \"context cycle\"","mail check --inject","nudge drain --inject","prime --hook --hook-format codex"]' ]; ok $? "shim_needs lista os 4 subcomandos do gc"
jq -e '(.dropped_keys.user|index("statusLine")) != null and (.dropped_keys["role:dog"]|index("enabledPlugins")) != null' "$O/manifest.json" >/dev/null; ok $? "chaves fora da lista ficam no manifest (dropped_keys)"
! grep -q 'statusLine\|launchctl' "$O/home/.claude/settings.json" && has "$O/home/.claude/settings.json" 'Bash(git:*)'; ok $? "chave e regra de permissão de macOS saem; a portável fica"
grep -rq SENTINEL_LOCAL_PERMS_9f3a "$O"; [ $? != 0 ]; ok $? "settings.local.json nunca entra no bundle"
jq -e '.dropped_rules == {"user.allow": 1}' "$O/manifest.json" >/dev/null; ok $? "regra de permissão de macOS descartada fica CONTADA no manifest (dropped_rules), sem o texto dela"
python3 -I "$B" verify "$O"; ok $? "verify do bundle intacto sai 0"
H1=$(hash_of "$O")

build "$T/f" "$T/f/out2"; diff -r "$O" "$T/f/out2" >/dev/null; ok $? "mesma entrada → bundle idêntico (hash $H1 e bytes)"
echo '# v2' >> "$T/f/home/.claude/hooks/filter-bash-output.sh"; build "$T/f" "$T/f/out3"
[ "$(hash_of "$T/f/out3")" != "$H1" ]; ok $? "byte mudado → bundle_hash muda"
build "$T/f" "$T/f/out" ; [ "$(hash_of "$O")" != "$H1" ]; ok $? "rebuild sobre OUT existente troca o conteúdo por inteiro"

fresh; build "$T/f" "$T/f/out"; echo x >> "$T/f/out/home/.claude/hooks/filter-bash-output.sh"
python3 -I "$B" verify "$T/f/out" 2>/dev/null; [ $? = 4 ]; ok $? "verify acusa arquivo alterado (4)"
fresh; build "$T/f" "$T/f/out"; rm "$T/f/out/city/settings.json"; python3 -I "$B" verify "$T/f/out" 2>/dev/null; [ $? = 4 ]; ok $? "verify acusa arquivo faltando (4)"
fresh; build "$T/f" "$T/f/out"; echo x > "$T/f/out/extra.sh"; python3 -I "$B" verify "$T/f/out" 2>/dev/null; [ $? = 4 ]; ok $? "verify acusa arquivo sobrando (4)"
fresh; build "$T/f" "$T/f/out"; rm "$T/f/out/manifest.json"; python3 -I "$B" verify "$T/f/out" 2>"$T/err"; rc=$?
[ $rc = 4 ] && has "$T/err" "ilegível"; ok $? "verify sem manifest.json não diz 'limpo': sai 4 com mensagem (rc=$rc)"
fresh; build "$T/f" "$T/f/out"; echo '{"files": 7}' > "$T/f/out/manifest.json"; python3 -I "$B" verify "$T/f/out" 2>/dev/null; [ $? = 4 ]; ok $? "verify com manifest.json sem 'files' válido sai 4"
fresh; build "$T/f" "$T/f/out"; jq '.files |= with_entries(.value |= del(.sha256))' "$T/f/out/manifest.json" > "$T/m.json" && cp "$T/m.json" "$T/f/out/manifest.json"
python3 -I "$B" verify "$T/f/out" 2>/dev/null; [ $? = 4 ]; ok $? "verify com entrada de manifest sem sha256 sai 4 (não estoura traceback)"

# --- gravar OUT: o que falha aqui é a saída, e a mensagem não pode culpar a entrada ---
fresh; : > "$T/f/umarquivo"; build "$T/f" "$T/f/umarquivo/out"; rc=$?
[ $rc = 3 ] && has "$T/err" "não consegui gravar" && ! has "$T/err" "entrada ilegível"; ok $? "OUT não gravável → exit 3 dizendo 'não consegui gravar', não 'entrada ilegível' (rc=$rc)"
fresh; build "$T/f" "$T/f/out"; H0=$(hash_of "$T/f/out"); mkdir -p "$T/f/out.old"; : > "$T/f/out.old/ocupado"
echo '# v2' >> "$T/f/home/.claude/hooks/filter-bash-output.sh"; build "$T/f" "$T/f/out"; rc=$?
[ $rc = 3 ] && [ "$(hash_of "$T/f/out")" = "$H0" ] && [ -z "$(ls -d "$T"/f/out.tmp.* 2>/dev/null)" ]; ok $? "troca de OUT que falha deixa o bundle anterior intacto e sem .tmp (rc=$rc)"

# --- recusas (fail-closed): cada uma parte de uma fixture limpa e muda UMA coisa ---
fresh; sed -i.bak 's#~/.claude/hooks/ntfy-on-stop.sh#~/.claude/hooks/novo-hook-que-ninguem-classificou.sh#' "$T/f/home/.claude/settings.json"
refuses "hook fora da tabela" "$T/f"
has "$T/err" novo-hook-que-ninguem-classificou; ok $? "  a mensagem diz QUAL hook"
fresh; sed -i.bak 's#gc nudge drain --inject#gc nudge drain --inject \&\& curl http://x.invalid/p#' "$T/f/gt/.gascity-gastown-hq/.gc/settings.json"
refuses "shim que ganhou \`&& curl\`" "$T/f"
fresh; sed -i.bak 's#"type": "command", "command": "~/.claude/hooks/filter-bash-output.sh"#"type": "prompt", "command": "~/.claude/hooks/filter-bash-output.sh"#' "$T/f/home/.claude/settings.json"
refuses "hook que não é command" "$T/f"
fresh; rm "$T/f/home/.claude/hooks/filter-bash-output.sh"
refuses "script keep ausente (ausente ≠ descartado)" "$T/f"
fresh; printf 'osascript -e "beep"\n' >> "$T/f/home/.claude/hooks/filter-bash-output.sh"
refuses "script keep com osascript" "$T/f"
fresh; printf 'T=%s\n' "sk-ant-$(printf 'A%.0s' $(seq 1 30))" >> "$T/f/home/.claude/hooks/filter-bash-output.sh"
refuses "segredo plantado em script keep" "$T/f"
fresh; printf 'cd %s\n' "/Users/fulano/gt" >> "$T/f/home/.claude/hooks/filter-bash-output.sh"
refuses "caminho do mini dentro de script keep" "$T/f"
fresh; rm "$T/f/gt/.gascity-gastown-hq/.gc/settings.json"
refuses "settings do city ilegível/ausente" "$T/f"
fresh; printf '{"hooks": ["isto-nao-e-um-dict"]}\n' > "$T/f/gt/.gascity-gastown-hq/.gc/settings.json"
refuses "settings com JSON válido mas forma inesperada (hooks como lista)" "$T/f"
has "$T/err" "formato inesperado"; ok $? "  a mensagem diz 'formato inesperado', não 'entrada ilegível'"
fresh; sed -i.bak 's|"Bash(sudo:\*)"|"Bash(sudo:*)", "Read(/Users/fulano/.ssh/**)"|' "$T/f/gt/.gascity-gastown-hq/.gc/settings.json"
refuses "regra de deny com caminho de macOS (tirar trava não é inerte)" "$T/f"
has "$T/err" "permissions.deny"; ok $? "  a mensagem diz QUAL lista"
fresh; cp "$T/f/home/.claude/hooks/filter-bash-output.sh" "$T/f/home/.claude/hooks/my-filter-bash-output.sh"
sed -i.bak 's#~/.claude/hooks/filter-bash-output.sh#~/.claude/hooks/my-filter-bash-output.sh#' "$T/f/home/.claude/settings.json"
refuses "script que só CONTÉM o nome de um keep (my-filter-bash-output.sh; o arquivo existe)" "$T/f"
has "$T/err" "my-filter-bash-output.sh"; ok $? "  a mensagem diz QUAL script"

# --- skills (--skills) ---
fresh; build "$T/f" "$T/f/out" --skills; rc=$?
[ $rc = 0 ] && [ -f "$T/f/out/role/dog/.claude/skills/ok-skill/SKILL.md" ] && [ ! -L "$T/f/out/role/dog/.claude/skills/ok-skill" ]; ok $? "skill é desreferenciada (arquivo comum, não link)"
fresh; : > "$T/f/gt/.gascity-gastown-hq/skills/ok-skill/leads.duckdb"
refuses "skill com .duckdb" "$T/f" --skills
fresh; printf 'cliente %s\n' "$(printf '%s.%s.%s-%s' 111 222 333 44)" > "$T/f/gt/.gascity-gastown-hq/skills/ok-skill/notas.md"
refuses "skill com CPF" "$T/f" --skills
fresh; mkdir -p "$T/f/fora"; ln -sfn "$T/f/fora" "$T/f/gt/.gascity-gastown-hq/.gc/agents/dog/.claude/skills/ok-skill"
refuses "skill que é symlink para fora da cidade" "$T/f" --skills
fresh; mkdir -p "$T/f/fora"; ln -s "$T/f/fora" "$T/f/gt/.gascity-gastown-hq/skills/ok-skill/dados"
refuses "skill com symlink de DIRETÓRIO por dentro (antes era pulado em silêncio)" "$T/f" --skills
has "$T/err" "symlink interno dados"; ok $? "  a mensagem diz QUAL symlink"

# --- controle negativo: sem a linha da tabela de um hook, o builder tem que recusar o mesmo build ---
fresh; sed '/"filter-bash-output.sh", "keep"/d' "$B" > "$T/mutant.py"
python3 -I "$T/mutant.py" build --city "$T/f/gt/.gascity-gastown-hq" --claude-home "$T/f/home/.claude" --mini-home "$T/f/home" --role dog \
  --role-dir "$T/f/gt/.gascity-gastown-hq/.gc/agents/dog" --remote-root /home/runner/rr --remote-home /home/runner --out "$T/f/mut" 2>/dev/null
[ $? = 3 ]; ok $? "controle negativo: sem a linha de filter-bash-output.sh na POLICY o build é recusado"

echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
