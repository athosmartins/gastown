#!/bin/bash
# hetzner-scrape-round.selftest.sh — selftest hermético de scripts/hetzner-scrape-round.sh (ga-mqs133).
#
# Contents
#   O que é real e o que é falso · Casos
#
# REAL: o próprio script, o rsync do sistema com o filtro de verdade (por isso o que é enviado/retido é conferido de fato), hetzner-pii-scan.py e o awk de elegibilidade/classificação.
# FALSO: o "nó" é uma pasta temporária (HOME do ssh falso) com um python de mentira no lugar do venv; ssh falso que executa o comando local; setsid/timeout/df/curl de mentira no PATH do nó (o macOS não tem
#   setsid nem timeout). Nada toca a rede, o servidor, ~/.property-scrapers nem o HOME de verdade. A medição REAL (curl do mini e do nó) é do prod test, com o nó vivo.
# SAÍDA: termina com a linha `N/N ok` e `SELFTEST OK` (é o que o run_suite do prod test exige); qualquer falha sai 1 com a lista.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
SCRIPT=$HERE/hetzner-scrape-round.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/hsr-selftest.XXXXXX") || exit 2
cleanup() { sleep 0.3; [ -n "$T" ] && [ -d "$T" ] && { find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null; }; }
trap cleanup EXIT
N=0; FAILS=0; FAILED=""
ok()  { N=$((N + 1)); }
bad() { N=$((N + 1)); FAILS=$((FAILS + 1)); FAILED="$FAILED
  - $1"; }
check() { # check <descrição> <condição em sh via eval>; na falha mostra o rc e o fim da última saída
  if eval "$2"; then ok; else bad "$1 [rc=$RC; saída: $(printf '%s' "$OUT" | tail -n 4 | cut -c1-240 | tr '\n' '|')]"; fi
}
has() { printf '%s' "$OUT" | grep -q -E -- "$1"; }

# ---------- o mundo falso ----------
CITY=$T/city; PS=$T/ps; CODE=$PS/runtime/main; SHARED=$PS/shared; NODEHOME=$T/nodehome; ELIG=$T/eligible.txt
mkdir -p "$T/home" "$T/tmp" "$CITY/.gc" "$CODE/lib" "$CODE/config" "$CODE/scrapers/alpha/__pycache__" "$CODE/scrapers/beta" "$CODE/shared/data" "$SHARED/config" "$SHARED/data/alpha/old" "$T/minibin" "$T/nodebin"
mkdir -p "$NODEHOME/gt-remote/scrape/env/venv/bin" "$NODEHOME/gt-remote/scrape/env/browsers/chromium_headless_shell-1" "$NODEHOME/gt-remote/scrape/runs"
: > "$CITY/.gc/hetzner-node.on"
echo "x = 1" > "$CODE/lib/util.py"; echo "# cfg" > "$CODE/config/__init__.py"; echo '{"bairros":[]}' > "$CODE/config/scope.json"
echo '[{"slug":"t1","active":true,"base_url":"https://t1.example"},{"slug":"t2","active":false,"base_url":"https://t2.example"}]' > "$CODE/config/imoview_tenants.json"
echo '{"seen":["x"]}' > "$CODE/config/seen_properties.json"; echo 'print(1)' > "$CODE/scrapers/alpha/scraper.py"; echo 'print(2)' > "$CODE/scrapers/beta/scraper.py"
echo 'SECRET=hunter2' > "$CODE/.env"; echo '{"token":"t"}' > "$CODE/scrapers/alpha/token.json"; echo 'a,b' > "$CODE/scrapers/alpha/leads.csv"; : > "$CODE/scrapers/alpha/__pycache__/x.pyc"
echo 'dump' > "$CODE/shared/data/prod.json"
# nomes que nenhuma regra conhece: só o `- *` final os impede de sair (o que a lista não nomeia, não viaja)
echo '[{"nome":"x"}]' > "$CODE/clientes_export.json"; echo '[]' > "$CODE/lib/dump_leads.json"; echo 'anotacao' > "$CODE/scrapers/alpha/notas.txt"
cat > "$CODE/runner.py" <<'EOF'
SCRAPERS = {
    "a": {"connectivity_host": "site-a.example"},
    "b": {"connectivity_host": "site-b.example"},
    "c": {"connectivity_host": "site-c.example"},
    "d": {"connectivity_host": "site-d.example"},
    "e": {"connectivity_host": "site-e.example"},
}
EOF
echo '{"seen":["old"]}' > "$SHARED/config/seen_alpha.json"; echo '{"c":1}' > "$SHARED/config/alpha_listing_cache.json"; echo '{"seen":["beta"]}' > "$SHARED/config/seen_beta.json"
# estado que casa o padrão de inclusão mas NÃO pode ir: nome de segredo/sessão, e o estado de OUTRO raspador cujo nome começa por `alpha_`
mkdir -p "$CODE/scrapers/alpha_x"; echo 'print(3)' > "$CODE/scrapers/alpha_x/scraper.py"
echo '{"seen":["tok"]}' > "$SHARED/config/seen_alpha_token.json"; echo '{"c":2}' > "$SHARED/config/alpha_session_cache.json"
echo '{"seen":["ax"]}' > "$SHARED/config/seen_alpha_x.json"; echo '{"c":3}' > "$SHARED/config/alpha_x_listing_cache.json"
echo '{"user":"u","pass":"p"}' > "$SHARED/config/credentials.json"; echo 'old' > "$SHARED/data/alpha/old/f.json"
cat > "$ELIG" <<'EOF'
# lista de teste
alpha                 # permitido
beta                  # permitido, mas bloqueado abaixo
!beta                 # motivo do bloqueio da beta
delta                 # permitido
!delta:t9             # só o tenant t9 bloqueado
EOF
printf 'alpha\r\n' > "$T/eligible.crlf"

cat > "$T/fakessh" <<'EOF'
#!/bin/bash
# ssh falso: ignora as opções, descarta o host e executa o comando LOCAL com HOME=<nó falso>; o stdin passa direto. Registra cada chamada.
echo "$*" >> "$FAKE_ROOT/ssh.calls"
[ -z "${FAKE_SSH_DOWN:-}" ] || exit 255
while [ $# -gt 0 ]; do case $1 in -o) shift 2;; -*) shift;; *) break;; esac; done
shift   # o host
cmd="$*"
if [ -n "${FAKE_SSH_DROP_POLL:-}" ]; then case $cmd in "cat gt-remote/scrape/runs/"*) exit 255;; esac; fi
cd "$FAKE_NODEHOME" || exit 255
exec env HOME="$FAKE_NODEHOME" PATH="$FAKE_ROOT/nodebin:$PATH" bash -c "$cmd"
EOF
cat > "$T/nodebin/setsid" <<'EOF'
#!/bin/bash
exec "$@"
EOF
cat > "$T/nodebin/timeout" <<'EOF'
#!/bin/bash
[ -z "${FAKE_TIMEOUT:-}" ] || exit 124
shift; exec "$@"
EOF
cat > "$T/nodebin/df" <<'EOF'
#!/bin/bash
echo "Filesystem 1M-blocks Used Available Capacity Mounted on"
echo "fake 100000 1 ${FAKE_FREE_MB:-50000} 1% /"
EOF
cat > "$T/nodebin/nproc" <<'EOF'
#!/bin/bash
echo 16
EOF
# curl falso (mini e nó): lê "url código tamanho marca" do mapa do lado; URL fora do mapa = 200 sem marca
for side in mini node; do
  d=$T/${side}bin; [ "$side" = node ] || d=$T/minibin
  cat > "$d/curl" <<EOF
#!/bin/bash
out=""; url=""
while [ \$# -gt 0 ]; do case \$1 in -o) out=\$2; shift 2;; -w|-m|-A|-H) shift 2;; -*) shift;; *) url=\$1; shift;; esac; done
line=\$(grep -F -m1 "\$url " "$T/curl.$side" 2>/dev/null)
set -- \$line
code=\${2:-200}; size=\${3:-100}; mk=\${4:--}
[ "\$mk" = - ] || printf '%s\n' "\$mk" | tr '_' ' ' > "\$out"
echo "\$code \$size"
EOF
  chmod 755 "$d/curl"
done
cat > "$NODEHOME/gt-remote/scrape/env/venv/bin/python" <<'EOF'
#!/bin/bash
# python falso: registra a árvore enviada, grava um resultado e um seen novo, sai com FAKE_SCRAPER_RC
scr=$2; shift 2
sc=$(basename "$(dirname "$scr")")
printf '%s\n' "$*" > "$HOME/args-last.txt"
( cd rig/main && find . -type f | sort ) > "$HOME/seen-tree.txt"
( cd shared/config 2>/dev/null && find . -type f | sort ) > "$HOME/seen-state.txt"
mkdir -p "shared/data/$sc/2026-01-01_00h00m00s" shared/config
[ -n "${FAKE_SCRAPER_EMPTY:-}" ] || echo '{"id":1}' > "shared/data/$sc/2026-01-01_00h00m00s/a.json"
echo '{"seen":["new"]}' > "shared/config/seen_$sc.json"
echo "RESULT: 1 scraped"
[ -z "${FAKE_SCRAPER_HANG:-}" ] || sleep 4
exit "${FAKE_SCRAPER_RC:-0}"
EOF
echo "/x/lib" > "$NODEHOME/gt-remote/scrape/env/libpath.txt"
chmod 755 "$T/fakessh" "$T/nodebin/"* "$NODEHOME/gt-remote/scrape/env/venv/bin/python"

# hermético de verdade: nada do ambiente de quem chamou (HETZNER_*, FAKE_*) pode mudar o que o script lê — o prod test e o gate rodam isto com o ambiente deles
for v in $(env | sed -n 's/^\(HETZNER_[A-Za-z0-9_]*\)=.*/\1/p; s/^\(FAKE_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
export HOME=$T/home FAKE_ROOT=$T FAKE_NODEHOME=$NODEHOME
export HETZNER_SCRAPE_CITY=$CITY HETZNER_SCRAPE_PS_HOME=$PS HETZNER_SSH_BIN=$T/fakessh HETZNER_SCRAPE_ELIGIBLE=$ELIG
export HETZNER_SCRAPE_POLL_S=0 HETZNER_SCRAPE_POLL_FAILS=3 HETZNER_SCRAPE_MIN_DISK_MB=3072
export PATH="$T/minibin:$PATH"
unset FAKE_SSH_DOWN FAKE_SSH_DROP_POLL FAKE_TIMEOUT FAKE_FREE_MB FAKE_SCRAPER_RC HETZNER_SCRAPE_STAGE HETZNER_NODE_HOST
: > "$T/ssh.calls"

OUT=""; RC=0
hsr() { # hsr [VAR=val ...] -- args...  : roda o script sob /bin/bash (3.2 no macOS); saída + stderr em $OUT, rc em $RC
  local envs=(); while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done; [ "${1:-}" = -- ] && shift
  OUT=$(env TMPDIR="$T/tmp" "${envs[@]+"${envs[@]}"}" /bin/bash "$SCRIPT" "$@" 2>&1); RC=$?
}
ncalls() { wc -l < "$T/ssh.calls" | tr -d ' '; }
tree_sum() { (cd "$1" && find . -type f | sort | while read -r f; do printf '%s ' "$f"; cksum < "$f"; done) | cksum; }

# ---------- 1. o arquivo ----------
check "o script existe, parseia sob /bin/bash (3.2) e tem permissão de execução" '[ -x "$SCRIPT" ] && /bin/bash -n "$SCRIPT"'
check "o selftest parseia sob /bin/bash" '/bin/bash -n "$0"'
REAL_ELIG=$HERE/hetzner-scrape-eligible.txt
check "a lista de elegíveis real existe e tem ao menos um permitido e um bloqueado" '[ -r "$REAL_ELIG" ] && grep -q -E "^[a-z]" "$REAL_ELIG" && grep -q -E "^!" "$REAL_ELIG"'
check "na lista real, zap_vivareal e chavesnamao (403 medido do nó) estão bloqueados e não permitidos" \
  '! grep -E "^(zap_vivareal|chavesnamao|netimoveis)[[:space:]]*(#|$)" "$REAL_ELIG" | grep -q . && grep -q -E "^!zap_vivareal" "$REAL_ELIG" && grep -q -E "^!chavesnamao" "$REAL_ELIG"'

# ---------- 2. elegibilidade ----------
hsr -- eligible alpha;                check "eligible: raspador permitido -> ALLOW, rc 0" '[ $RC -eq 0 ] && [ "$OUT" = ALLOW ]'
hsr -- eligible beta;                 check "eligible: a linha !beta VENCE a permissão e mostra o motivo, rc 97" '[ $RC -eq 97 ] && has "^BLOCK motivo do bloqueio da beta$"'
hsr -- eligible gamma;                check "eligible: raspador que não está na lista -> NONE, rc 97 (não medi ≠ libera)" '[ $RC -eq 97 ] && [ "$OUT" = NONE ]'
hsr -- eligible delta t1;             check "eligible: !delta:t9 não bloqueia o tenant t1" '[ $RC -eq 0 ] && [ "$OUT" = ALLOW ]'
hsr -- eligible delta t9;             check "eligible: !delta:t9 bloqueia o tenant t9" '[ $RC -eq 97 ] && has "^BLOCK"'
hsr -- eligible 'a;b';                check "eligible: nome com metacaractere é recusado, rc 97" '[ $RC -eq 97 ] && has "inválido"'
hsr -- eligible;                      check "eligible sem argumento: rc 97" '[ $RC -eq 97 ]'
hsr HETZNER_SCRAPE_ELIGIBLE="$T/nao-existe" -- eligible alpha; check "eligible: lista ilegível -> UNREADABLE, rc 97 (falha fechada)" '[ $RC -eq 97 ] && has "UNREADABLE"'
hsr HETZNER_SCRAPE_ELIGIBLE="$T/eligible.crlf" -- eligible alpha; check "eligible: lista com CRLF ainda permite" '[ $RC -eq 0 ]'

# ---------- 3. check ----------
hsr -- check;                         check "check: nó pronto -> rc 0, node_env=ok" '[ $RC -eq 0 ] && has "^node_env=ok$" && has "^flag=on$" && has "^eligible_entries=3$"'
rm -f "$CITY/.gc/hetzner-node.on"; C0=$(ncalls)
hsr -- check;                         check "check: sem a bandeira -> rc 99, sem tocar o ssh" '[ $RC -eq 99 ] && [ "$(ncalls)" = "$C0" ]'
: > "$CITY/.gc/hetzner-node.on"
hsr FAKE_SSH_DOWN=1 -- check;         check "check: ssh fora -> rc 98" '[ $RC -eq 98 ]'
hsr FAKE_FREE_MB=100 -- check;        check "check: disco do nó abaixo do mínimo -> rc 98" '[ $RC -eq 98 ] && has "disco"'
mv "$NODEHOME/gt-remote/scrape/env/libpath.txt" "$T/libpath.keep"
hsr -- check;                         check "check: ambiente sem libpath -> rc 98 e manda rodar bootstrap" '[ $RC -eq 98 ] && has "node_env=missing" && has "bootstrap"'
mv "$T/libpath.keep" "$NODEHOME/gt-remote/scrape/env/libpath.txt"

# ---------- 4. run: recusas (nenhuma toca o nó) ----------
C0=$(ncalls)
hsr -- run 'A;b';                     check "run: nome inválido -> 97, sem ssh" '[ $RC -eq 97 ] && [ "$(ncalls)" = "$C0" ]'
hsr -- run beta;                      check "run: raspador bloqueado -> 97 com o motivo, sem ssh" '[ $RC -eq 97 ] && has "BLOQUEADO" && has "motivo do bloqueio da beta" && [ "$(ncalls)" = "$C0" ]'
hsr -- run gamma;                     check "run: raspador fora da lista -> 97, sem ssh" '[ $RC -eq 97 ] && has "não está em" && [ "$(ncalls)" = "$C0" ]'
hsr -- run alpha --tenant 'x y';      check "run: tenant com espaço -> 97" '[ $RC -eq 97 ]'
hsr -- run alpha --limit abc;         check "run: --limit não numérico -> 97" '[ $RC -eq 97 ]'
hsr -- run alpha --timeout 0;         check "run: --timeout 0 -> 97" '[ $RC -eq 97 ]'
hsr -- run alpha --bogus;             check "run: argumento desconhecido -> 97" '[ $RC -eq 97 ] && has "desconhecido"'
B0=$(tree_sum "$SHARED")
hsr -- run alpha --stage "$SHARED/data/stage-aqui"; check "run: staging dentro de shared/ (produção) -> 97 e nada criado lá" '[ $RC -eq 97 ] && has "produção" && [ ! -e "$SHARED/data/stage-aqui" ] && [ "$(ncalls)" = "$C0" ]'
mkdir -p "$T/linkdest"; ln -s "$SHARED" "$T/linkdest/lk"
hsr -- run alpha --stage "$T/linkdest/lk/data";   check "run: staging via symlink para shared/ também é recusado" '[ $RC -eq 97 ]'
rm -f "$CITY/.gc/hetzner-node.on"
hsr -- run alpha;                     check "run: sem a bandeira -> 99" '[ $RC -eq 99 ]'
: > "$CITY/.gc/hetzner-node.on"
hsr FAKE_SSH_DOWN=1 -- run alpha;     check "run: ssh fora -> 98 (rode local)" '[ $RC -eq 98 ]'
hsr FAKE_FREE_MB=10 -- run alpha;     check "run: disco baixo -> 98" '[ $RC -eq 98 ]'

# ---------- 5. run: caminho feliz ----------
hsr -- run alpha --tenant t1 --limit 5 --stage "$T/stage" -- --finalidade venda
check "run: rc 0 e imprime stage/files/secs" '[ $RC -eq 0 ] && has "^stage=.*/stage/alpha-t1-" && has "^files=1$" && has "^secs="'
STG=$(ls -d "$T"/stage/alpha-t1-* 2>/dev/null | head -n 1)
check "run: o resultado voltou (dados, seen atualizado, log do raspador)" '[ -f "$STG/shared/data/alpha/2026-01-01_00h00m00s/a.json" ] && grep -q new "$STG/shared/config/seen_alpha.json" && grep -q "RESULT: 1 scraped" "$STG/scraper.log"'
check "run: o log jsonl registra 'ok' (com arquivos) e o stderr diz quantos arquivos de estado foram ao nó" 'grep -q "\"why\":\"ok\"" "$CITY/.gc/logs/hetzner-scrape.jsonl" && has "estado \\(seen/caches\\) enviado ao nó: [1-9]"'
check "run: argumentos do raspador = --tenant --limit + os de depois do --" '[ "$(cat "$NODEHOME/args-last.txt")" = "--tenant t1 --limit 5 --finalidade venda" ]'
check "run: o que foi ao nó é só código do raspador pedido (sem .env, token, csv, pyc, outro raspador, shared/ do rig, nem arquivo de nome desconhecido)" \
  'grep -q "./scrapers/alpha/scraper.py" "$NODEHOME/seen-tree.txt" && grep -q "./lib/util.py" "$NODEHOME/seen-tree.txt" && grep -q "./config/scope.json" "$NODEHOME/seen-tree.txt" && grep -q "./config/imoview_tenants.json" "$NODEHOME/seen-tree.txt" \
   && ! grep -q -E "\.env|token|leads\.csv|pyc|beta|shared|seen_properties|clientes_export|dump_leads|notas|runner" "$NODEHOME/seen-tree.txt"'
check "run: do estado só foram seen_<raspador> e o cache dele (nem seen de outro, nem credenciais)" \
  'grep -q "seen_alpha.json" "$NODEHOME/seen-state.txt" && grep -q "alpha_listing_cache.json" "$NODEHOME/seen-state.txt" && ! grep -q -E "beta|credentials" "$NODEHOME/seen-state.txt"'
check "run: do estado NÃO foram nem nome de segredo/sessão (token, session) nem o estado do raspador irmão alpha_x, mesmo casando o padrão alpha_*" \
  '[ -s "$NODEHOME/seen-state.txt" ] && ! grep -q -E "token|session|alpha_x" "$NODEHOME/seen-state.txt"'
check "run: a produção (shared/) ficou byte a byte igual" '[ "$(tree_sum "$SHARED")" = "$B0" ]'
check "run: a pasta da rodada no nó foi apagada" '[ -z "$(ls -A "$NODEHOME/gt-remote/scrape/runs")" ]'
check "run: uma linha no log jsonl com rc 0 e o raspador" 'tail -n 1 "$CITY/.gc/logs/hetzner-scrape.jsonl" | grep -q "\"scraper\":\"alpha\".*\"rc\":0"'
hsr -- run alpha --stage "$T/stage2"; check "run sem --tenant/--limit também funciona (args vazios)" '[ $RC -eq 0 ]'

# ---------- 6. run: código de saída do raspador ----------
hsr FAKE_SCRAPER_RC=3 -- run alpha --stage "$T/stage3"
check "run: rc do raspador (3) é propagado e o resultado ainda volta" '[ $RC -eq 3 ] && ls "$T"/stage3/alpha-*/shared/data/alpha/*/a.json >/dev/null 2>&1'
hsr FAKE_SCRAPER_RC=99 -- run alpha --stage "$T/stage4"
check "run: rc 99 do raspador NUNCA vira 'rode local': sai 95 e o valor cru vai em scraper_rc_raw" '[ $RC -eq 95 ] && has "^scraper_rc_raw=99$"'
hsr FAKE_TIMEOUT=1 -- run alpha --stage "$T/stage5"
check "run: estouro do --timeout (124) sai 95, não 124" '[ $RC -eq 95 ] && has "^scraper_rc_raw=124$"'

# ---------- 7. run: conteúdo reprovado e queda do ssh ----------
i=1; : > "$CODE/lib/leads.py"; while [ $i -le 25 ]; do printf '"(31) 9%04d-%04d"\n' $((1000 + i * 37)) $((2000 + i * 53)) >> "$CODE/lib/leads.py"; i=$((i + 1)); done
C0=$(ncalls)
hsr -- run alpha --stage "$T/stage6"
check "run: lista de telefones no código que iria ao nó -> 98, o nó NÃO é usado (só o ssh do preflight; nenhum mkdir/rsync)" '[ $RC -eq 98 ] && has "telefones/CPFs" && [ -z "$(ls -A "$NODEHOME/gt-remote/scrape/runs")" ] && [ "$(( $(ncalls) - C0 ))" = 1 ]'
find "$CODE/lib/leads.py" -delete
cp "$SHARED/config/seen_alpha.json" "$T/seen_alpha.bak"
i=1; : > "$SHARED/config/seen_alpha.json"; while [ $i -le 25 ]; do printf '"(31) 9%04d-%04d"\n' $((1000 + i * 37)) $((2000 + i * 53)) >> "$SHARED/config/seen_alpha.json"; i=$((i + 1)); done
C0=$(ncalls)
hsr -- run alpha --stage "$T/stage6b"
check "run: lista de telefones no ESTADO (seen/caches) que iria ao nó -> 98, o nó NÃO é usado (mesma falha fechada do código)" '[ $RC -eq 98 ] && has "arquivo de estado com lista de telefones/CPFs" && [ -z "$(ls -A "$NODEHOME/gt-remote/scrape/runs")" ] && [ "$(( $(ncalls) - C0 ))" = 1 ]'
cp "$T/seen_alpha.bak" "$SHARED/config/seen_alpha.json"
# sem NENHUM arquivo de estado do raspador (os outros que casam o padrão são de segredo/irmão e ficam de fora) e sem nenhum resultado: o terceiro estado tem de aparecer, não virar um "ok" mudo
mv "$SHARED/config/seen_alpha.json" "$T/seen_alpha.mv"; mv "$SHARED/config/alpha_listing_cache.json" "$T/alpha_cache.mv"
: > "$CITY/.gc/logs/hetzner-scrape.jsonl"
hsr FAKE_SCRAPER_EMPTY=1 -- run alpha --stage "$T/stage9"
check "run: sem estado -> AVISO de que o raspador começa sem seen (e nenhum estado foi enviado)" '[ $RC -eq 0 ] && has "AVISO: nenhum arquivo de estado" && ! has "estado \\(seen/caches\\) enviado ao nó"'
check "run: rc 0 com zero arquivos devolvidos -> files=0 e o log diz ok-sem-arquivos (não 'ok')" 'has "^files=0$" && grep -q "\"why\":\"ok-sem-arquivos\"" "$CITY/.gc/logs/hetzner-scrape.jsonl" && ! grep -q "\"why\":\"ok\"" "$CITY/.gc/logs/hetzner-scrape.jsonl"'
mv "$T/seen_alpha.mv" "$SHARED/config/seen_alpha.json"; mv "$T/alpha_cache.mv" "$SHARED/config/alpha_listing_cache.json"
hsr FAKE_SSH_DROP_POLL=1 -- run alpha --stage "$T/stage7"
check "run: ssh que cai nas consultas -> desiste com 98 e deixa a pasta no nó" '[ $RC -eq 98 ] && has "desisto" && [ -n "$(ls -A "$NODEHOME/gt-remote/scrape/runs")" ]'
sleep 1; find "$NODEHOME/gt-remote/scrape/runs" -mindepth 1 -delete 2>/dev/null
hsr FAKE_SCRAPER_HANG=1 HETZNER_SCRAPE_GRACE_S=0 -- run alpha --timeout 1 --stage "$T/stage8"
check "run: processo que não escreve o rc dentro de --timeout + folga -> desiste com 98 (não consulta para sempre)" '[ $RC -eq 98 ] && has "passou do prazo"'
sleep 5; find "$NODEHOME/gt-remote/scrape/runs" -mindepth 1 -delete 2>/dev/null

# ---------- 8. probe ----------
printf '%s\n' "https://site-a.example/ 200 100 -" "https://t1.example/ 200 100 captcha" "https://site-b.example/ 200 100 -" "https://site-c.example/ 200 100 captcha" "https://site-d.example/ 403 100 -" "https://site-e.example/ 000 0 -" > "$T/curl.mini"
printf '%s\n' "https://site-a.example/ 403 100 Just_a_moment" "https://t1.example/ 200 100 captcha" "https://site-b.example/ 200 100 Just_a_moment" "https://site-c.example/ 200 100 -" "https://site-d.example/ 403 100 -" "https://site-e.example/ 200 100 -" > "$T/curl.node"
hsr -- probe --out "$T/probe.out"
check "probe: 200 no mini e 403 desafio no nó -> SO-O-NO-BLOQUEIA" '[ $RC -eq 0 ] && has "SO-O-NO-BLOQUEIA.*site-a.example"'
check "probe: a palavra captcha dos DOIS lados num 200 é IGUAL-OK (widget de formulário não é bloqueio)" 'has "IGUAL-OK.*t1.example"'
check "probe: desafio de verdade num 200 só do nó -> SO-O-NO-BLOQUEIA" 'has "SO-O-NO-BLOQUEIA.*site-b.example"'
check "probe: marca diferente num 200 e sem desafio duro -> DIFERE-VERIFICAR (um humano olha)" 'has "DIFERE-VERIFICAR.*site-c.example"'
check "probe: 403 dos dois lados -> IGUAL-FALHA; mini falha e nó responde -> SO-O-MINI-FALHA" 'has "IGUAL-FALHA.*site-d.example" && has "SO-O-MINI-FALHA.*site-e.example"'
check "probe: tenant inativo não é medido; --out grava a tabela; jsonl ganha a linha do probe" '! has "t2.example" && grep -q "site-a.example" "$T/probe.out" && grep -q "\"scraper\":\"probe\"" "$CITY/.gc/logs/hetzner-scrape.jsonl"'
hsr FAKE_SSH_DOWN=1 -- probe;         check "probe: nó fora -> rc 98" '[ $RC -eq 98 ]'
rm -f "$CITY/.gc/hetzner-node.on"
hsr -- probe;                         check "probe: sem a bandeira -> rc 99" '[ $RC -eq 99 ]'
: > "$CITY/.gc/hetzner-node.on"

# ---------- 9. uso ----------
hsr --;                               check "sem subcomando: mostra o uso e sai 97" '[ $RC -eq 97 ]'
hsr -- bogus;                         check "subcomando desconhecido: 97" '[ $RC -eq 97 ]'

check "nenhum subcomando (run, probe, eligible, uso) deixou pasta temporária para trás em TMPDIR" '[ -z "$(ls -A "$T/tmp")" ]'

echo "$N casos, $FAILS falha(s)"
if [ "$FAILS" -ne 0 ]; then echo "FALHAS:$FAILED"; echo "$((N - FAILS))/$N ok"; exit 1; fi
echo "$N/$N ok"; echo "SELFTEST OK"
