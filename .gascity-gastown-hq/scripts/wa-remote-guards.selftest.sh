#!/usr/bin/env bash
# wa-remote-guards.selftest.sh — prova hermética de scripts/wa-remote-guards.py (ga-2hd02v.3.11): G12, G6, G7 e G7b do pre-push do WA, rodados NO MINI sobre os OBJETOS de um sha que o nó empurrou.
#
# Contents
#   Fixture · Casos (1-24) · Mutantes · Contrato com os guards REAIS do WA
#
# FIXTURE  Um "rig WA" falso em tmp: origin bare + clone cujo refs/remotes/origin/main carrega os guards de CONFIANÇA, que são os de scripts/wa-remote-guards.fixture/ (a mesma interface dos reais, em ~25 linhas cada).
#          Cada sha de teste é um commit solto sobre origin/main, montado por mk() — o que o nó empurraria.
# CASOS    Cada guard bloqueia o que tem de bloquear; "não consegui saber" (git que falha, guard que levanta exceção, forma outra, árvore ilegível) NUNCA vira passou; o código que roda é o de origin/main e NUNCA o do sha
#          (um sha que sobrescreve os 6 arquivos de confiança com versões hostis não deixa rastro e continua bloqueado); só o que os guards leem é exportado (dado de lead não é copiado).
# MUTANTES Cada guarda apagada do executável tem de reprovar o caso que a prova ("teste que só passa não prova nada").
# CONTRATO Se o rig WA existe nesta máquina, os mesmos casos centrais rodam com os guards REAIS (lidos de origin/main do rig, sem tocar nele): é o que denuncia deriva de interface. Sem o rig: SKIP dito em voz alta.
#
# Uso: bash scripts/wa-remote-guards.selftest.sh   (FAILFAST=1 para no 1º caso que reprova; WA_REAL_RIG=<pasta> aponta o rig)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
EXE_SRC="${EXE_UNDER_TEST:-$HERE/wa-remote-guards.py}"
FIX="$HERE/wa-remote-guards.fixture"
T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/wrg-selftest.XXXXXX")" && pwd -P)
trap 'chmod -R u+rwX "$T" 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
n=0; fails=0
ok() { n=$((n+1)); if [ "$1" = 0 ]; then echo "ok   $2"; return; fi; echo "FAIL $2"; fails=$((fails+1)); [ -s "$T/err" ] && echo "     (stderr: $(head -c 300 "$T/err" | tr '\n' ' '))"; [ -s "$T/out" ] && echo "     (stdout: $(head -c 500 "$T/out" | tr '\n' '|'))"
  [ -n "${FAILFAST:-}" ] && { echo "FAILFAST: parei no caso $n"; exit 1; }; return 0; }
has() { grep -qF -- "$2" "$1" 2>/dev/null; }
PY=$(command -v python3); GITBIN=$(command -v git)
PATH_RUN="$(dirname "$GITBIN"):/usr/bin:/bin"
mkdir -p "$T/home" "$T/tmp" "$T/shim"
EXE="$T/exe.py"; cp -p "$EXE_SRC" "$EXE"

G() { git -c user.name=t -c user.email=t@t.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
ORIGIN="$T/origin.git"; W="$T/w"; RIG="$T/rig"; TRACE="$T/trace"
git init -q --bare -b main "$ORIGIN"; git clone -q "$ORIGIN" "$W" 2>/dev/null
cp -R "$FIX/." "$W/"; mkdir -p "$W/launchd"; printf 'x = 1\n' > "$W/lib/x.py"; printf '#!/bin/sh\n# ACTION_PREFIX_OK\n' > "$W/scripts/notify"
G -C "$W" add -A >/dev/null && G -C "$W" commit -qm base && G -C "$W" push -q origin HEAD:main 2>/dev/null
git clone -q "$ORIGIN" "$RIG" 2>/dev/null
MAIN=$(git -C "$RIG" rev-parse refs/remotes/origin/main)
mk() {  # mk MSG 'edições da árvore (rodam em $RIG)' ['edições só do índice, depois do add -A'] → SHA: commit SOLTO sobre origin/main (nenhum branch o segura), como o que o nó empurra
  G -C "$RIG" checkout -q --detach refs/remotes/origin/main && ( cd "$RIG" && eval "$2" ) && G -C "$RIG" add -A >/dev/null && ( cd "$RIG" && eval "${3:-:}" ) && G -C "$RIG" commit -qm "$1" && SHA=$(git -C "$RIG" rev-parse HEAD)
  local r=$?; G -C "$RIG" checkout -q --detach refs/remotes/origin/main; G -C "$RIG" clean -fdxq; return $r
}
paid_files() {  # paid_files [LABEL] [CAMINHO-DO-PLIST]: um daemon AGENDADO (StartInterval) cujo script contém o marcador de chamada paga
  mkdir -p scripts launchd; printf 'API = "PAID_API"\n' > scripts/paid.py
  cat > "${2:-launchd/com.fixture.paid.plist}" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>${1:-com.fixture.paid}</string><key>ProgramArguments</key><array><string>/usr/bin/python3</string><string>scripts/paid.py</string></array><key>StartInterval</key><integer>3600</integer></dict></plist>
PL
}
hostile() {  # os 6 arquivos de confiança SOBRESCRITOS no sha: rastro em tempo de import e veredito sempre "limpo". Se qualquer um rodar, $TRACE nasce
  local f
  for f in lib/launchd_paid_guard.py lib/mds_consumer_registry.py scripts/check_mds_registry_guard.py scripts/check_ntfy_bypass_guard.py scripts/check_notify_action_prefix_guard.py; do
    printf 'open(r"%s", "a").write("hostil rodou: %s\\n")\n' "$TRACE" "$f" > "$f"
  done
  printf 'subprocess = None\nREPO_ROOT = _REPO_ROOT = _REGISTRY_DIR = None\ndef all_repo_plists(): return []\ndef scan_plist(p): return {}\ndef unapproved_scheduled_paid_daemons(p=None): return []\ndef registered_script_paths(): return set()\n' | tee -a lib/launchd_paid_guard.py lib/mds_consumer_registry.py >/dev/null
  printf 'subprocess = None\n_REPO_ROOT = None\ndef check(r, skipped=None): return []\n' | tee -a scripts/check_mds_registry_guard.py scripts/check_ntfy_bypass_guard.py >/dev/null
  printf 'def check(src): return []\n' >> scripts/check_notify_action_prefix_guard.py
}
CASEINS=0; touch "$T/CaseProbe"; [ -e "$T/caseprobe" ] && CASEINS=1   # APFS padrão do mini não distingue maiúscula; o nó (Linux) distingue

# ── os shas de teste (cada um é o que um nó poderia empurrar) ─────────────────────────────────────────────────────────────────────────────────────
mk "limpo" 'printf "v = 1\n" > lib/y.py'; S_CLEAN=$SHA
mk "paid" 'paid_files'; S_PAID=$SHA
mk "paid+aprovado" 'paid_files; printf "\"\"\"r\"\"\"\nAPPROVED_SCHEDULED_PAID_DAEMONS = {\"com.fixture.approved\": {}, \"com.fixture.paid\": {}}\n" > lib/approved_scheduled_paid_daemons.py'; S_PAID_OK=$SHA
reg_code() {  # registro que RODARIA código (rastro + del): lido por ast ele é recusado, nunca executado
  cat > lib/approved_scheduled_paid_daemons.py <<RG
APPROVED_SCHEDULED_PAID_DAEMONS = {"com.fixture.paid": {}}
open(r"$TRACE", "a").write("registro executado\\n")
del APPROVED_SCHEDULED_PAID_DAEMONS["com.fixture.paid"]
RG
}
mk "registro-com-codigo" 'paid_files; reg_code'; S_REG_CODE=$SHA
mk "plist-quebrado" 'mkdir -p launchd; printf "<plist><dict>\n" > launchd/com.fixture.quebrado.plist'; S_BADPLIST=$SHA
mk "mds" 'printf "import x  # mega_data_set\ndf.to_csv(\"o.csv\")\n" > scripts/derivado.py'; S_MDS=$SHA
mk "mds+fragmento" 'printf "import x  # mega_data_set\ndf.to_csv(\"o.csv\")\n" > scripts/derivado.py; mkdir -p lib/mds_consumers.d; printf "{\"scripts\": [\"scripts/derivado.py\"]}\n" > lib/mds_consumers.d/derivado.json'; S_MDS_OK=$SHA
mk "ntfy" 'printf "URL = \"https://ntfy.sh/topico\"\n" > scripts/postador.py'; S_NTFY=$SHA
mk "notify-ruim" 'printf "#!/bin/sh\necho sem o prefixo\n" > scripts/notify'; S_NOTIFY_BAD=$SHA
mk "sem-notify" 'rm scripts/notify'; S_NO_NOTIFY=$SHA
mk "tudo-hostil" 'paid_files; printf "import x  # mega_data_set\ndf.to_csv(\"o.csv\")\n" > scripts/derivado.py; printf "URL = \"https://ntfy.sh/topico\"\n" > scripts/postador.py; printf "#!/bin/sh\necho sem o prefixo\n" > scripts/notify; hostile'; S_TAMPER=$SHA
mk "symlink" 'ln -s /etc/passwd lib/evil.py'; S_LINK=$SHA
mk "grande" 'head -c 8388609 /dev/zero | tr "\0" "a" > lib/big.py'; S_BIG=$SHA
mk "dados" 'mkdir -p data; printf "cpf,111.111.111-11\n" > data/clientes.csv; printf "{\"lead\": \"segredo\"}\n" > data/leads.json; printf "v = 2\n" > lib/z.py'; S_DATA=$SHA
mk "esc" 'paid_files com.fixture.esc "launchd/com.x$(printf "\033")[2Jpaid.plist"'; S_ESC=$SHA
BLOB=$(git -C "$RIG" rev-parse "$MAIN:lib/x.py")
# refs de confiança alternativas (o `--trusted-ref`): guard que levanta exceção, forma outra, comando git que o atalho não prevê, árvore vazia
mk "g6-levanta" 'printf "def check(git_range, skipped=None):\n    raise RuntimeError(\"boom\")\n_REPO_ROOT = None\nsubprocess = None\n" > scripts/check_mds_registry_guard.py'; git -C "$RIG" update-ref refs/remotes/origin/bad-g6 "$SHA"
mk "g12-sem-scan" 'sed -i.bak "s/def scan_plist/def scan_plist_renomeada/" lib/launchd_paid_guard.py; rm lib/launchd_paid_guard.py.bak'; git -C "$RIG" update-ref refs/remotes/origin/shape "$SHA"
mk "g7-comando-novo" 'sed -i.bak "s/\"diff\", \"--name-only\"/\"log\", \"--name-only\"/" scripts/check_ntfy_bypass_guard.py; rm scripts/check_ntfy_bypass_guard.py.bak'; git -C "$RIG" update-ref refs/remotes/origin/cmd "$SHA"
git -C "$RIG" update-ref refs/remotes/origin/empty "$(G -C "$RIG" commit-tree "$(git -C "$RIG" hash-object -t tree /dev/null)" -m vazio)"
cat > "$T/shim/git" <<EOF
#!/bin/sh
case " \$* " in *" diff "*) echo "shim: git diff falhou (128)" >&2; exit 128;; esac
exec "$GITBIN" "\$@"
EOF
chmod +x "$T/shim/git"

# ── execução: RC, $T/out, $T/err. Ambiente do zero; --repo/--sha vêm de $RIG/$SHA ────────────────────────────────────────────────────────────────────
runx() {  # runx [VAR=valor ...] [-- arg...]
  envs=(); while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done; [ $# -gt 0 ] && shift
  ( cd "$T" && env -i HOME="$T/home" PATH="$PATH_RUN" TMPDIR="$T/tmp" LANG=en_US.UTF-8 ${envs[@]+"${envs[@]}"} "$PY" -I -B "$EXE" --repo "$RIG" --sha "$SHA" "$@" ) > "$T/out" 2> "$T/err"; RC=$?
}
res() { grep -qE "^wa-remote-guards: RESULT=$1 sha=[0-9a-f]{40} trusted=[0-9a-f]{40}$" "$T/out"; }   # a linha-certificado COMPLETA (sha e confiança em 40 hex)
gl() { grep -qE "^wa-remote-guards: $1 $2 \(" "$T/out"; }   # gl G12 PASS: a linha do guard com o veredito
one_result() { [ "$(grep -c 'RESULT=' "$T/out")" = 1 ]; }
no_trace() { [ ! -e "$TRACE" ]; }
no_leftover() { [ -z "$(ls "$T/tmp" 2>/dev/null)" ]; }   # nada de wa-remote-guards-* sobrando no TMPDIR

# ══ casos: cada um devolve 0 quando o comportamento BOM aparece (os mutantes reusam as mesmas funções) ═════════════════════════════════════════════════
case_clean() { SHA=$S_CLEAN; runx; [ "$RC" = 0 ] && res PASS && gl G12 PASS && gl G6 PASS && gl G7 PASS && gl G7b PASS && one_result && no_leftover && grep -q "sha=$S_CLEAN trusted=$MAIN" "$T/out"; }
case_order() { SHA=$S_CLEAN; runx; [ "$(grep -oE '^wa-remote-guards: G[0-9a-z]+ ' "$T/out" | tr -d '\n')" = "wa-remote-guards: G12 wa-remote-guards: G6 wa-remote-guards: G7 wa-remote-guards: G7b " ]; }
case_g12_blocks() { SHA=$S_PAID; runx; [ "$RC" = 1 ] && res BLOCKED && gl G12 BLOCKED && has "$T/out" "BLOQUEADO Label=com.fixture.paid" && has "$T/out" "Conserto:" && ! has "$T/out" "RESULT=PASS" && one_result && no_leftover; }
case_g12_approved_in_sha() { SHA=$S_PAID_OK; runx; [ "$RC" = 0 ] && res PASS && gl G12 PASS; }
case_g12_registry_code() { SHA=$S_REG_CODE; rm -f "$TRACE"; runx; [ "$RC" = 2 ] && res UNKNOWN && gl G12 UNKNOWN && has "$T/out" "tem código além de uma atribuição literal" && no_trace && no_leftover; }
case_g12_unreadable_plist() { SHA=$S_BADPLIST; runx; [ "$RC" = 2 ] && res UNKNOWN && gl G12 UNKNOWN && has "$T/out" "plist alterado neste sha que o scanner não conseguiu ler (launchd/com.fixture.quebrado.plist; 1 no total)"; }
case_g6_blocks() { SHA=$S_MDS; runx; [ "$RC" = 1 ] && res BLOCKED && gl G6 BLOCKED && has "$T/out" "BLOQUEADO scripts/derivado.py"; }
case_g6_fragment() { SHA=$S_MDS_OK; runx; [ "$RC" = 0 ] && res PASS && gl G6 PASS; }
case_g7_blocks() { SHA=$S_NTFY; runx; [ "$RC" = 1 ] && res BLOCKED && gl G7 BLOCKED && has "$T/out" "BLOQUEADO scripts/postador.py"; }
case_g7b_blocks() { SHA=$S_NOTIFY_BAD; runx; [ "$RC" = 1 ] && res BLOCKED && gl G7b BLOCKED; }
case_g7b_absent() { SHA=$S_NO_NOTIFY; runx; [ "$RC" = 0 ] && res PASS && has "$T/out" "inaplicável"; }
case_g12_trusted_src() { SHA=$S_TAMPER; rm -f "$TRACE"; runx FIXTURE_TRACE="$TRACE"; gl G12 BLOCKED && no_trace; }
case_g6_trusted_src() { SHA=$S_TAMPER; rm -f "$TRACE"; runx FIXTURE_TRACE="$TRACE"; gl G6 BLOCKED && no_trace; }
case_g7_trusted_src() { SHA=$S_TAMPER; rm -f "$TRACE"; runx FIXTURE_TRACE="$TRACE"; gl G7 BLOCKED && no_trace; }
case_g7b_trusted_src() { SHA=$S_TAMPER; rm -f "$TRACE"; runx FIXTURE_TRACE="$TRACE"; gl G7b BLOCKED && no_trace; }
case_tamper_all() { SHA=$S_TAMPER; rm -f "$TRACE"; runx FIXTURE_TRACE="$TRACE"; [ "$RC" = 1 ] && res BLOCKED && gl G12 BLOCKED && gl G6 BLOCKED && gl G7 BLOCKED && gl G7b BLOCKED && no_trace; }
case_symlink() { SHA=$S_LINK; runx; [ "$RC" = 2 ] && res_unknown_any && has "$T/out" "symlink em 'lib/evil.py'" && ! has "$T/out" "RESULT=PASS"; }
case_big() { SHA=$S_BIG; runx; [ "$RC" = 2 ] && res_unknown_any && has "$T/out" "lib/big.py" && has "$T/out" "não leio o que não consigo ler inteiro"; }
case_export_only_wanted() { SHA=$S_DATA; runx -- --scratch "$T/sc-data"; [ "$RC" = 0 ] && [ -f "$T/sc-data/tree/lib/z.py" ] && [ -z "$(find "$T/sc-data/tree" -name '*.csv' -o -name '*.json' ! -path '*/mds_consumers.d/*')" ] && [ ! -e "$T/sc-data/tree/data" ]; }
case_export_modes() { SHA=$S_DATA; runx -- --scratch "$T/sc-modes"; [ "$RC" = 0 ] && [ -z "$(find "$T/sc-modes/tree" \( -type f ! -perm 0600 \) -o \( -type d ! -perm 0700 \))" ]; }
case_trusted_missing() { SHA=$S_CLEAN; runx -- --trusted-ref refs/remotes/origin/nao-existe; [ "$RC" = 2 ] && res_unknown_any; }
res_unknown_any() { grep -qE "^wa-remote-guards: RESULT=UNKNOWN " "$T/out" && ! has "$T/out" "RESULT=PASS"; }
case_bad_shas() { local s k=0; for s in "$BLOB" "${S_CLEAN:0:12}" "$(echo "$S_CLEAN" | tr a-f A-F)" HEAD "" "${S_CLEAN:0:39}" 0000000000000000000000000000000000000000; do SHA=$s; runx; { [ "$RC" = 2 ] && ! has "$T/out" "RESULT=PASS"; } || k=1; done; [ "$k" = 0 ]; }
case_git_diff_fails() { SHA=$S_CLEAN; runx PATH="$T/shim:$PATH_RUN"; [ "$RC" = 2 ] && res UNKNOWN && gl G6 UNKNOWN && gl G7 UNKNOWN && gl G12 PASS && gl G7b PASS && ! has "$T/out" "RESULT=PASS"; }
case_guard_raises() { SHA=$S_CLEAN; runx -- --trusted-ref refs/remotes/origin/bad-g6; [ "$RC" = 2 ] && res UNKNOWN && gl G6 UNKNOWN && has "$T/out" "G6 levantou RuntimeError"; }
case_shape_changed() { SHA=$S_CLEAN; runx -- --trusted-ref refs/remotes/origin/shape; [ "$RC" = 2 ] && gl G12 UNKNOWN && has "$T/out" "mudou de forma (falta scan_plist"; }
case_unforeseen_cmd() { SHA=$S_CLEAN; runx -- --trusted-ref refs/remotes/origin/cmd; [ "$RC" = 2 ] && gl G7 UNKNOWN && has "$T/out" "o guard pediu um comando que o atalho não prevê"; }
case_empty_trusted() { SHA=$S_CLEAN; runx -- --trusted-ref refs/remotes/origin/empty; [ "$RC" = 2 ] && res UNKNOWN && gl G12 UNKNOWN && gl G6 UNKNOWN && gl G7 UNKNOWN && gl G7b UNKNOWN; }
case_control_chars() { SHA=$S_ESC; runx; [ "$RC" = 1 ] && gl G12 BLOCKED && ! LC_ALL=C grep -q "$(printf '\033')" "$T/out" "$T/err" && has "$T/out" "com.x?[2Jpaid.plist"; }
case_skip_env_ignored() { SHA=$S_PAID; runx GT_SKIP_LAUNCHD_PAID_GUARD=1 GT_SKIP_MDS_REGISTRY_CHECK=1 GT_SKIP_NTFY_GUARD=1 GT_SKIP_ALL=1; [ "$RC" = 1 ] && gl G12 BLOCKED; }
case_case_collision() { [ "$CASEINS" = 0 ] && return 0; SHA=$S_CASE; runx; [ "$RC" = 2 ] && has "$T/out" "colisão de nome ou disco" && ! has "$T/out" "RESULT=PASS"; }
case_local_branch_decoy() { SHA=$S_CLEAN; git -C "$RIG" update-ref refs/heads/origin/main "$S_TAMPER"; runx; local r=$RC; git -C "$RIG" update-ref -d refs/heads/origin/main; [ "$r" = 0 ] && grep -q "sha=$S_CLEAN trusted=$MAIN" "$T/out"; }
case_own_tmp_removed() { SHA=$S_PAID; runx; r1=$RC; SHA=$S_LINK; runx; [ "$r1" = 1 ] && [ "$RC" = 2 ] && no_leftover; }
case_scratch_kept_and_not_reused() { SHA=$S_CLEAN; runx -- --scratch "$T/sc-keep"; r1=$RC; k=0; [ -d "$T/sc-keep/tree" ] || k=1; runx -- --scratch "$T/sc-keep"; [ "$r1" = 0 ] && [ "$k" = 0 ] && [ "$RC" = 2 ] && has "$T/out" "sobra de outra execução"; }
case_usage() { SHA=$S_CLEAN; ( cd "$T" && env -i PATH="$PATH_RUN" "$PY" -I -B "$EXE" ) >"$T/out" 2>"$T/err"; r1=$?; ( cd "$T" && env -i PATH="$PATH_RUN" "$PY" -I -B "$EXE" --repo "$RIG" ) >"$T/out" 2>"$T/err"; r2=$?; ( cd "$T" && env -i PATH="$PATH_RUN" "$PY" -I -B "$EXE" --repo "$T/nao-e-repo" --sha "$S_CLEAN" ) >"$T/out" 2>"$T/err"; r3=$?
  [ "$r1" = 2 ] && [ "$r2" = 2 ] && [ "$r3" = 2 ] && res_unknown_any; }
mk "colide" '' 'h1=$(printf a | git hash-object -w --stdin); h2=$(printf b | git hash-object -w --stdin); git update-index --add --cacheinfo 100644,$h1,lib/Dup.py; git update-index --add --cacheinfo 100644,$h2,lib/dup.py'; S_CASE=$SHA

ck() { case_$1; ok $? "$2"; }
ck clean "limpo: rc 0, os 4 guards PASS, certificado RESULT=PASS com o sha e a confiança (40 hex), uma só linha RESULT, TMPDIR limpo"
ck order "a ordem do Mayor: G12 (dinheiro), G6, G7, G7b"
ck g12_blocks "G12: daemon agendado com chamada paga e sem aprovação → rc 1, BLOQUEADO com Label, e o conserto"
ck g12_approved_in_sha "G12: a aprovação no registro DO SHA (a mudança revisada pelo gate É a aprovação) → passa"
ck g12_registry_code "G12: registro com código além da atribuição literal → NÃO SEI (rc 2) e o código do registro NÃO foi executado"
ck g12_unreadable_plist "G12: plist que ESTE sha acrescenta e o scanner não lê → NÃO SEI (o hook diria passou; a fonte é o nó)"
ck g6_blocks "G6: escritor de derivado do MDS sem fragmento → rc 1"
ck g6_fragment "G6: com o fragmento lib/mds_consumers.d/<nome>.json no mesmo sha → passa"
ck g7_blocks "G7: post direto ao ntfy.sh → rc 1"
ck g7b_blocks "G7b: scripts/notify sem o prefixo de ação → rc 1"
ck g7b_absent "G7b: sem scripts/notify na árvore é inaplicável (o hook também pula), e diz isso"
ck tamper_all "um sha que SOBRESCREVE os arquivos de confiança com versões hostis: rc 1, os 4 guards seguem bloqueando e NENHUM rastro (código do nó não rodou)"
ck symlink "symlink em caminho que os guards leem → NÃO SEI (rc 2), nunca passou"
ck big "arquivo acima do limite → NÃO SEI (rc 2): não leio o que não consigo ler inteiro"
ck export_only_wanted "exportação: só o que os guards leem (dado de lead em data/*.csv|json não é copiado)"
ck export_modes "exportação: arquivos 0600 e pastas 0700"
ck trusted_missing "ref de confiança inexistente → rc 2, nunca passou"
ck bad_shas "sha inválido (blob, curto, maiúsculo, HEAD, vazio, 39 hex, zeros) → rc 2 e nunca PASS"
ck git_diff_fails "git diff que FALHA dentro de G6/G7 → NÃO SEI nos dois (o guard real devolveria lista vazia = passou); G12 e G7b seguem"
ck guard_raises "guard de confiança que levanta exceção → NÃO SEI (o main() dele daria 'fail OPEN' = passou)"
ck shape_changed "guard de confiança que mudou de forma → NÃO SEI com o que falta, e manda atualizar junto"
ck unforeseen_cmd "guard que pede um comando git que o atalho não prevê → NÃO SEI"
ck empty_trusted "árvore de confiança sem os guards → NÃO SEI em todos"
ck control_chars "nome de arquivo com ESC no sha: o relatório não leva caractere de controle"
ck skip_env_ignored "GT_SKIP_* no ambiente NÃO é honrado (um bypass não é decisão da sessão remota)"
if [ "$CASEINS" = 1 ]; then ck case_collision "dois caminhos que só diferem na caixa (macOS) → NÃO SEI, não se sobrescrevem em silêncio"; else echo "skip colisão de caixa: este disco distingue maiúscula (o mini não)"; fi
ck local_branch_decoy "um branch LOCAL chamado origin/main não vira a confiança (o default é refs/remotes/origin/main por nome completo)"
ck own_tmp_removed "sem --scratch: a pasta temporária própria é removida, inclusive quando BLOQUEIA ou NÃO SEI"
ck scratch_kept_and_not_reused "com --scratch: a pasta fica para quem a criou recolher, e uma sobra de outra execução é recusada"
ck usage "uso errado, --sha ausente e repo que não é repo → rc 2"

# ══ mutantes ════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
mutant() {  # mutant NOME CASO 'trecho' 'troca' ['trecho2' 'troca2']  — cada trecho existe UMA vez; o caso devolve 0 se o comportamento BOM aparece, então ≠ 0 = morto
  declare -F "case_$2" >/dev/null || { echo "FAIL mutante $1: o caso 'case_$2' não está definido"; fails=$((fails+1)); n=$((n+1)); return; }
  cp -p "$EXE_SRC" "$T/mut.py"
  "$PY" -I - "$T/mut.py" "$3" "$4" ${5+"$5"} ${6+"$6"} <<'EOF' || { echo "FAIL mutante $1: o trecho não existe mais no executável"; fails=$((fails+1)); n=$((n+1)); return; }
import sys
p, *pairs = sys.argv[1:]; s = open(p).read()
for a, b in zip(pairs[0::2], pairs[1::2]):
    assert s.count(a) == 1, "trecho ausente ou repetido"; s = s.replace(a, b)
open(p, "w").write(s)
EOF
  EXE="$T/mut.py"; rm -f "$TRACE"
  if "case_$2" >/dev/null 2>&1; then ok 1 "mutante $1 SOBREVIVEU (o caso não pegou)"; else ok 0 "mutante $1 morto"; fi
  EXE="$T/exe.py"
}
mutant facade-git-que-falha-vira-lista-vazia git_diff_fails 'out = git(self.repo, "-c", "core.quotepath=false", "diff", "--no-ext-diff", "--no-textconv", *a[2:])' $'try:\n                out = git(self.repo, "-c", "core.quotepath=false", "diff", "--no-ext-diff", "--no-textconv", *a[2:])\n            except Unknown:\n                out = b""'
mutant g6-excecao-vira-passou guard_raises 'raise Unknown(f"G6 levantou {type(e).__name__}: {safe(e)[:120]}")' 'return "PASS", "", []'
mutant nao-sei-nao-reprova git_diff_fails 'result = "BLOCKED" if "BLOCKED" in verdicts else "UNKNOWN" if "UNKNOWN" in verdicts else "PASS"' 'result = "BLOCKED" if "BLOCKED" in verdicts else "PASS"'
mutant bloqueado-nao-reprova g12_blocks 'result = "BLOCKED" if "BLOCKED" in verdicts else "UNKNOWN"' 'result = "UNKNOWN"'
mutant g12-codigo-do-sha tamper_all 'mod = load_trusted(c.repo, c.tsha, "g12", c.scratch)' 'mod = load_trusted(c.repo, c.sha, "g12", c.scratch)'
mutant g6-codigo-do-sha g6_trusted_src 'mod = load_trusted(c.repo, c.tsha, "g6", c.scratch)' 'mod = load_trusted(c.repo, c.sha, "g6", c.scratch)'
mutant g7-codigo-do-sha g7_trusted_src 'mod = load_trusted(c.repo, c.tsha, "g7", c.scratch)' 'mod = load_trusted(c.repo, c.sha, "g7", c.scratch)'
mutant g7b-codigo-do-sha g7b_trusted_src 'mod = load_trusted(c.repo, c.tsha, "g7b", c.scratch)' 'mod = load_trusted(c.repo, c.sha, "g7b", c.scratch)'
mutant g12-aprovacao-ignorada g12_approved_in_sha 'labels = registry_labels(reg.read_text(encoding="utf-8"))' 'labels = set()'
mutant registro-com-codigo-aceito g12_registry_code 'raise Unknown(f"{REGISTRY_PATH} tem código além de uma atribuição literal de {REGISTRY_NAME} (linha {node.lineno}): não avalio sem executar")' 'raise Unknown(f"{REGISTRY_PATH}: {node.lineno}")'
mutant plist-ilegivel-vira-aviso g12_unreadable_plist 'if unread:' 'if False:'
mutant exporta-tudo export_only_wanted 'return path.endswith((".py", ".sh", ".plist")) or path == NOTIFY_PATH or (path.startswith(MDS_DIR) and path.endswith(".json"))' 'return True'
mutant relatorio-com-controle control_chars '"?", str(s))[:300]' '"?", "")[:300] + str(s)[:300]'
mutant symlink-vira-modo symlink 'raise Unknown(f"symlink em {safe(e.path)!r}: seguir o link leria fora da árvore, e não seguir esconderia o alvo")' 'raise Unknown(f"modo 120000 em {safe(e.path)!r}")'
mutant arquivo-grande-sem-limite big 'if e.size > MAX_BLOB:' 'if False:'
mutant ref-de-confianca-ambigua local_branch_decoy 'TRUSTED_REF = "refs/remotes/origin/main"' 'TRUSTED_REF = "origin/main"'
mutant comando-nao-previsto-vira-vazio unforeseen_cmd $'raise Unknown(f"o guard pediu um comando que o atalho não prevê: {safe(\' \'.join(a))[:100]}")' 'return subprocess.CompletedProcess(a, 0, "" if kw.get("text") else b"", "" if kw.get("text") else b"")'
mutant forma-outra-nao-denunciada shape_changed $'raise Unknown(f"{mod.__name__} mudou de forma (falta {\', \'.join(missing)}): atualize wa-remote-guards.py junto com o guard")' 'raise Unknown(f"{mod.__name__}: {missing}")'
mutant scratch-reaproveitado scratch_kept_and_not_reused 'root.mkdir(parents=True, exist_ok=False, mode=0o700)' 'root.mkdir(parents=True, exist_ok=True, mode=0o700)'
mutant tmp-proprio-nao-removido own_tmp_removed '            shutil.rmtree(scratch, ignore_errors=True)' '            pass'
mutant certificado-sem-confianca clean 'say(f"RESULT={result} sha={sha} trusted={tsha}")' 'say(f"RESULT={result} sha={sha}")'
mutant garantia-de-ordem order 'GUARDS = (("G12", guard_g12), ("G6", guard_g6), ("G7", guard_g7), ("G7b", guard_g7b))' 'GUARDS = (("G6", guard_g6), ("G12", guard_g12), ("G7", guard_g7), ("G7b", guard_g7b))'
mutant uso-errado-vira-ok usage 'return 2 if e.code else 0' 'return 0'
if [ "$CASEINS" = 1 ]; then mutant colisao-de-nome-sobrescreve case_collision 'os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW' 'os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW'; else echo "skip mutante da colisão de caixa: este disco distingue maiúscula"; fi

# ══ contrato com os guards REAIS (lidos de origin/main do rig WA; o rig não é tocado) ═══════════════════════════════════════════════════════════════
WA_REAL="${WA_REAL_RIG:-/Users/athos/gt/whatsapp_automation}"; WR=refs/remotes/origin/main
if git -C "$WA_REAL" rev-parse --verify -q "$WR^{commit}" >/dev/null 2>&1; then
  RW="$T/rw"; RO="$T/ro.git"; RR="$T/rr"
  git init -q --bare -b main "$RO"; git clone -q "$RO" "$RW" 2>/dev/null; k=0
  for f in lib/launchd_paid_guard.py lib/mds_consumer_registry.py lib/approved_scheduled_paid_daemons.py scripts/check_mds_registry_guard.py scripts/check_ntfy_bypass_guard.py scripts/check_notify_action_prefix_guard.py scripts/notify; do
    mkdir -p "$RW/$(dirname "$f")"; git -C "$WA_REAL" show "$WR:$f" > "$RW/$f" 2>/dev/null || { echo "FAIL contrato: o rig não tem $f em origin/main"; k=1; }
  done
  for f in $(git -C "$WA_REAL" ls-tree -r --name-only "$WR" -- lib/mds_consumers.d | grep -E '\.json$'); do mkdir -p "$RW/$(dirname "$f")"; git -C "$WA_REAL" show "$WR:$f" > "$RW/$f"; done
  G -C "$RW" add -A >/dev/null && G -C "$RW" commit -qm real-guards && G -C "$RW" push -q origin HEAD:main 2>/dev/null; git clone -q "$RO" "$RR" 2>/dev/null
  RIG_SAVED=$RIG; RIG=$RR; MAIN=$(git -C "$RR" rev-parse refs/remotes/origin/main)
  mkr() { G -C "$RR" checkout -q --detach refs/remotes/origin/main && ( cd "$RR" && eval "$2" ) && G -C "$RR" add -A >/dev/null && G -C "$RR" commit -qm "$1" && SHA=$(git -C "$RR" rev-parse HEAD); local r=$?; G -C "$RR" checkout -q --detach refs/remotes/origin/main; G -C "$RR" clean -fdxq; return $r; }
  real_paid() { mkdir -p scripts launchd; printf 'from lib.x import ProcobClient\nProcobClient().consulta()\n' > scripts/paid_real.py
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>Label</key><string>com.fixture.realpaid</string><key>ProgramArguments</key><array><string>/usr/bin/python3</string><string>scripts/paid_real.py</string></array><key>StartInterval</key><integer>3600</integer></dict></plist>\n' > launchd/com.fixture.realpaid.plist; }
  mkr "real-limpo" 'printf "v = 1\n" > lib/y.py'; R_CLEAN=$SHA
  mkr "real-g12" 'real_paid'; R_G12=$SHA
  mkr "real-g6" 'printf "df = con.execute(\"select * from ops.mega_data_set\")\ndf.to_csv(\"o.csv\")\n" > scripts/derivado_real.py'; R_G6=$SHA
  mkr "real-g7" 'mkdir -p services/enrichment; printf "import requests\nrequests.post(\"https://ntfy.sh/topico\", data=\"x\")\n" > services/enrichment/novo_real.py'; R_G7=$SHA
  [ "$k" = 0 ]; ok $? "contrato: os 7 arquivos de confiança existem em origin/main do rig WA ($WA_REAL)"
  SHA=$R_CLEAN; runx; [ "$RC" = 0 ] && res PASS && gl G12 PASS && gl G6 PASS && gl G7 PASS && gl G7b PASS; ok $? "contrato (guards REAIS): sha limpo → os 4 passam (se isto quebra, a interface de um guard do WA mudou: atualize wa-remote-guards.py junto)"
  SHA=$R_G12; runx; [ "$RC" = 1 ] && gl G12 BLOCKED && has "$T/out" "Label=com.fixture.realpaid"; ok $? "contrato (G12 REAL): daemon agendado que chama ProcobClient sem aprovação → BLOQUEADO"
  SHA=$R_G6; runx; [ "$RC" = 1 ] && gl G6 BLOCKED && has "$T/out" "scripts/derivado_real.py"; ok $? "contrato (G6 REAL): escritor de derivado do MDS sem fragmento → BLOQUEADO"
  SHA=$R_G7; runx; [ "$RC" = 1 ] && gl G7 BLOCKED && has "$T/out" "services/enrichment/novo_real.py"; ok $? "contrato (G7 REAL): post direto ao ntfy.sh em services/enrichment → BLOQUEADO"
  SHA=$R_CLEAN; runx PATH="$T/shim:$PATH_RUN"; [ "$RC" = 2 ] && gl G6 UNKNOWN && gl G7 UNKNOWN; ok $? "contrato (G6/G7 REAIS): git diff que falha → NÃO SEI (os reais devolveriam lista vazia = passou)"
  RIG=$RIG_SAVED; MAIN=$(git -C "$RIG" rev-parse refs/remotes/origin/main)
else
  echo "SKIP contrato com os guards reais: $WA_REAL não tem refs/remotes/origin/main (máquina sem o rig WA, como o nó). Rode no mini."
fi

echo
echo "$((n - fails))/$n ok, $fails falhas"
[ "$fails" = 0 ]
