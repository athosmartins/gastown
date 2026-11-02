#!/usr/bin/env bash
# Selftest for cloudflared-dns-reconcile.sh — proves ERROR paths notify (ga-4zpf), not just log.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
J="$SELF_DIR/cloudflared-dns-reconcile.sh"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

# vazio/falhou → sai: nunca segue com TMP vazio (os caminhos "$TMP/..." cairiam na raiz)
TMP="$(mktemp -d)" || { echo "FATAL: mktemp falhou"; exit 1; }
[ -d "$TMP" ] || { echo "FATAL: mktemp nao criou $TMP"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
NOTIFY_LOG="$TMP/notify.log"
cat > "$TMP/notify" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$NOTIFY_LOG"
EOF
chmod +x "$TMP/notify"

echo "── Scenario 1: cloudflared binary missing ──"
: > "$NOTIFY_LOG"
CLOUDFLARED="$TMP/nonexistent-cloudflared" \
  CLOUDFLARED_CONFIG="$TMP/nonexistent-config.yml" \
  CLOUDFLARE_CERT="$TMP/nonexistent-cert.pem" \
  LOG_FILE="$TMP/run1.log" \
  CLOUDFLARED_NOTIFY="$TMP/notify" \
  bash "$J" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok "1: exits nonzero when cloudflared binary is missing" || bad "1: expected nonzero exit, got $rc"
grep -qi 'cloudflared' "$NOTIFY_LOG" 2>/dev/null && ok "1: notify_fail fired for missing cloudflared binary (ga-4zpf)" || bad "1: missing-binary FATAL did NOT notify — silent failure (ga-4zpf regression)"

echo ""
echo "── Scenario 2: config file missing (cloudflared binary present) ──"
: > "$NOTIFY_LOG"
FAKE_CLOUDFLARED="$TMP/fake-cloudflared"
cat > "$FAKE_CLOUDFLARED" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_CLOUDFLARED"
CLOUDFLARED="$FAKE_CLOUDFLARED" \
  CLOUDFLARED_CONFIG="$TMP/nonexistent-config.yml" \
  CLOUDFLARE_CERT="$TMP/nonexistent-cert.pem" \
  LOG_FILE="$TMP/run2.log" \
  CLOUDFLARED_NOTIFY="$TMP/notify" \
  bash "$J" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok "2: exits nonzero when config is missing" || bad "2: expected nonzero exit, got $rc"
grep -qi 'config' "$NOTIFY_LOG" 2>/dev/null && ok "2: notify_fail fired for missing config (ga-4zpf)" || bad "2: missing-config FATAL did NOT notify — silent failure (ga-4zpf regression)"

echo ""
echo "── Cenarios 3+: o script inteiro contra curl, python3 e cloudflared de mentira (lastro hq-mutants, ga-qec2rdl) ──"
# Ate aqui so os dois FATAL do preflight rodavam. Agora o resto: cert ausente, tunnel id, sem hostnames,
# credenciais, o que fazer quando nada falta, criar so o que falta, a rota que falha e o fallback quando a
# API nao responde. O python3 de mentira so atende o trecho que le o cert.pem do mini (caminho fixo dentro
# do script); o resto vai para o python3 de verdade. Os stubs nascem por printf, sem here-document (o bash
# 3.2.57 do no grava o temporario do here-document em /tmp sem olhar TMPDIR e a jaula nega).
# EQUIVALENTES (lastro e95f59f16c L47 e 90615c79ab L56): `notify_fail ... || true` -> `&& true` e o
# `return 0` de log() -> `return 1` so mudam o STATUS dessas duas funcoes, e nenhum chamador o le (o
# script nao tem set -e e sai por exit explicito ou pelo `[[ $failed -eq 0 ]]` final).
REAL_PY="$(command -v python3)"
[ -x "$REAL_PY" ] || { echo "FATAL: sem python3 no PATH"; exit 1; }
BIN="$TMP/bin"; mkdir "$BIN" || exit 1
printf '%s\n' '#!/bin/bash' 'echo "$*" >> "$STUB_DIR/curl.args"' '[ "${CURL_RC:-0}" = "0" ] || exit "$CURL_RC"' \
  '[ -f "$STUB_DIR/curl.out" ] && cat "$STUB_DIR/curl.out"; exit 0' > "$BIN/curl"
printf '%s\n' '#!/bin/bash' 'case "$2" in' \
  '  *"ARGO TUNNEL TOKEN"*) if [ -n "${CREDS_FAIL:-}" ]; then echo "ERROR: cert de mentira ilegivel"; exit 1; fi; printf "tok-test\nzone-test\n"; exit 0 ;;' \
  'esac' 'exec "$REAL_PY" "$@"' > "$BIN/python3"
printf '%s\n' '#!/bin/bash' 'echo "$*" >> "$STUB_DIR/cf.calls"' 'for h in "$@"; do :; done' \
  'if grep -qxF "$h" "$STUB_DIR/cf.fail" 2>/dev/null; then echo "boom: $h"; exit 1; fi' \
  'if grep -qxF "$h" "$STUB_DIR/cf.already" 2>/dev/null; then echo "$h already configured"; exit 0; fi' \
  'echo "Added CNAME $h"' > "$TMP/cloudflared"
chmod +x "$BIN/curl" "$BIN/python3" "$TMP/cloudflared"
: > "$TMP/cert.pem"

cfg() { # <hostname...> — ingress com tunnel: tid-123 e um servico final sem hostname
  printf '%s\n' 'tunnel: tid-123' 'ingress:' > "$TMP/cfg.yml"
  local h; for h in "$@"; do printf '%s\n' "  - hostname: $h" '    service: http://localhost:1' >> "$TMP/cfg.yml"; done
  printf '%s\n' '  - service: http_status:404' >> "$TMP/cfg.yml"
}
newcase() { : > "$TMP/cf.fail"; : > "$TMP/cf.already"; printf '%s' "$1" > "$TMP/curl.out"; }   # <corpo que o curl devolve>
runcf() { # [VAR=valor ...] — o script inteiro; deixa $RC, a saida em $TMP/stdout e o log dele em $TMP/run.log
  : > "$NOTIFY_LOG"; : > "$TMP/run.log"; : > "$TMP/curl.args"; : > "$TMP/cf.calls"
  env CLOUDFLARED="$TMP/cloudflared" CLOUDFLARED_CONFIG="$TMP/cfg.yml" CLOUDFLARE_CERT="$TMP/cert.pem" \
    LOG_FILE="$TMP/run.log" CLOUDFLARED_NOTIFY="$TMP/notify" STUB_DIR="$TMP" REAL_PY="$REAL_PY" \
    PATH="$BIN:$PATH" "$@" bash "$J" > "$TMP/stdout" 2>&1 < /dev/null
  RC=$?
}
inrun() { grep -F -- "$1" "$TMP/run.log" >/dev/null 2>&1; }       # arquivo ausente/ilegivel = nao achou = reprova
innot() { grep -F -- "$1" "$NOTIFY_LOG" >/dev/null 2>&1; }
# arquivo ausente: o wc nao imprime numero e a comparacao com o esperado reprova, nunca conta 0
ncalls() { wc -l < "$TMP/cf.calls" | tr -d ' '; }
nocurl() { [ -f "$TMP/curl.args" ] && [ ! -s "$TMP/curl.args" ]; }   # existe e esta vazio: a API nao foi tocada
J_ALL='{"success": true, "result": [{"name": "a.test.example", "content": "tid-123.cfargotunnel.com"}, {"name": "b.test.example", "content": "tid-123.cfargotunnel.com"}]}'
J_BOUT='{"success": true, "result": [{"name": "a.test.example", "content": "tid-123.cfargotunnel.com"}, {"name": "b.test.example", "content": "other.cfargotunnel.com"}]}'

cfg a.test.example b.test.example; newcase "$J_ALL"; runcf CLOUDFLARE_CERT="$TMP/sem-cert.pem"
[ "$RC" = "1" ] && inrun "ERROR: cert not found" && innot "cert nao encontrado" && nocurl && [ "$(ncalls)" = "0" ] \
  && ok "3: cert ausente sai 1, registra, notifica e nao toca na API" || bad "3: cert ausente: rc=$RC stdout='$(cat "$TMP/stdout")'"

printf '%s\n' 'ingress:' '  - hostname: a.test.example' > "$TMP/cfg.yml"; newcase "$J_ALL"; runcf
[ "$RC" = "1" ] && inrun "could not parse tunnel id" && innot "tunnel id" && nocurl \
  && ok "4: config sem 'tunnel:' sai 1, registra e notifica" || bad "4: sem tunnel id: rc=$RC"

printf '%s\n' 'tunnel: tid-123' 'ingress:' '  - service: http_status:404' > "$TMP/cfg.yml"; newcase "$J_ALL"; runcf
[ "$RC" = "0" ] && inrun "WARN: no hostnames found" && [ ! -s "$NOTIFY_LOG" ] && nocurl && [ "$(ncalls)" = "0" ] \
  && ok "5: ingress sem hostname sai 0 com aviso, sem notificar e sem API" || bad "5: sem hostnames: rc=$RC"

cfg a.test.example b.test.example; newcase "$J_ALL"; runcf CREDS_FAIL=1
[ "$RC" = "1" ] && inrun "failed to extract Cloudflare credentials: ERROR: cert de mentira ilegivel" && innot "credenciais" && nocurl \
  && ok "6: credenciais ilegiveis saem 1, registram o motivo e notificam" || bad "6: credenciais: rc=$RC"

cfg a.test.example b.test.example; newcase "$J_ALL"; runcf
[ "$RC" = "0" ] && inrun "yaml_hosts=2 cloudflare_configured=2" && inrun "all 2 hosts already configured in Cloudflare" \
  && [ "$(ncalls)" = "0" ] && [ ! -s "$NOTIFY_LOG" ] && [ ! -s "$TMP/stdout" ] \
  && grep -F -- "Authorization: Bearer tok-test" "$TMP/curl.args" >/dev/null && grep -F -- "zones/zone-test/dns_records?type=CNAME&per_page=500" "$TMP/curl.args" >/dev/null \
  && ok "7: nada falta: sai 0 sem criar rota nem notificar, o token e a zona vao ao curl, e sem terminal o log nao vai a stdout" \
  || bad "7: nada falta: rc=$RC stdout='$(cat "$TMP/stdout")'"

cfg a.test.example b.test.example; newcase "$J_BOUT"; runcf
[ "$RC" = "0" ] && inrun "found 1 missing host(s)" && inrun "CREATED b.test.example" && inrun "created=1 already_ok=1 failed=0" \
  && [ "$(ncalls)" = "1" ] && grep -F -- "route dns tid-123 b.test.example" "$TMP/cf.calls" >/dev/null \
  && grep -F -- "--config $TMP/cfg.yml" "$TMP/cf.calls" >/dev/null && [ ! -s "$NOTIFY_LOG" ] \
  && ok "8: um host aponta para outro tunel: so ele e criado, sai 0, sem notificar" || bad "8: um faltando: rc=$RC calls=$(cat "$TMP/cf.calls")"

cfg a.test.example b.test.example; newcase '{"success": true, "result": []}'; printf '%s\n' b.test.example > "$TMP/cf.fail"; runcf
[ "$RC" = "1" ] && [ "$(ncalls)" = "2" ] && inrun "CREATED a.test.example" && inrun "FAIL  b.test.example :: boom: b.test.example" \
  && inrun "created=1 already_ok=0 failed=1" && innot "1/2 host(s) faltantes falharam" \
  && ok "9: dois faltando e um falha: o outro e criado, sai 1 e notifica 1/2" || bad "9: uma rota falha: rc=$RC calls=$(cat "$TMP/cf.calls")"

cfg a.test.example b.test.example; newcase "$J_ALL"; runcf CURL_RC=22
[ "$RC" = "0" ] && inrun "WARN: Cloudflare API request failed (curl exit=22)" && inrun "FALLBACK: calling cloudflared route dns for all 2 hosts" \
  && [ "$(ncalls)" = "2" ] && inrun "CREATED a.test.example" && inrun "created=2 already_ok=0 failed=0" && [ ! -s "$NOTIFY_LOG" ] \
  && ok "10: curl falha: cai no fallback, tenta os 2 hosts, sai 0 e nao notifica" || bad "10: fallback por curl: rc=$RC calls=$(cat "$TMP/cf.calls")"

cfg a.test.example b.test.example c.test.example; newcase '{"success": false, "errors": [{"code": 9109}]}'
printf '%s\n' a.test.example > "$TMP/cf.already"; printf '%s\n' b.test.example > "$TMP/cf.fail"; runcf
[ "$RC" = "1" ] && inrun "WARN: Cloudflare API returned success=false" && [ "$(ncalls)" = "3" ] && inrun "FAIL  b.test.example" \
  && ! inrun "CREATED a.test.example" && inrun "CREATED c.test.example" && inrun "created=1 already_ok=1 failed=1" \
  && innot "(fallback): 1/3 host(s) falharam" \
  && ok "11: success=false: fallback conta criada, ja configurada e falha, sai 1 e notifica 1/3" || bad "11: fallback success=false: rc=$RC calls=$(cat "$TMP/cf.calls")"

cfg a.test.example b.test.example; newcase '<html>oops</html>'; runcf
[ "$RC" = "0" ] && inrun "WARN: Cloudflare API returned success=false" && [ "$(ncalls)" = "2" ] \
  && ok "12: corpo que nao e JSON conta como API falha (fallback), nao como 'nada a fazer'" || bad "12: corpo ilegivel: rc=$RC calls=$(cat "$TMP/cf.calls")"

echo ""
echo "cloudflared-dns-reconcile selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
