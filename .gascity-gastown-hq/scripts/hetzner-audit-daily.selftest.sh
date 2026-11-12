#!/usr/bin/env bash
# hetzner-audit-daily.selftest.sh — hermético: a auditoria e o notify são FALSOS (scripts no $T/fake); o wrapper é o de verdade, com a cidade num mktemp. Nada toca a rede, o servidor nem o notify real.
#
# Contents
#   Casos · Controle negativo
#
# CASOS (ga-qg1dw5z.3): auditoria LIMPA → nenhum alarme, relatório guardado, linha de heartbeat · ACHADO (rc 1) e NAO-CONSEGUI (rc 3) → UM alarme com o veredito no título, o RESULTADO e as linhas
#   que não são LIMPO no corpo · auditoria QUEBRADA (rc estranho, rc 0/1/3 sem linha RESULTADO, ou RESULTADO que não bate com o rc) → alarme "QUEBRADA", nunca silêncio · notify que falha → rc 4 (o relatório fica) e exit 10/11
#   do notify (guardado para as 7h / mesmo título há pouco) não são erro mas ficam escritos no log, 12 (teto de pushes) é falha · desligado por variável ou por arquivo · trava: dono vivo → nada, dono morto → segue · auditoria ausente ·
#   relatório comprido é cortado · relatórios com mais de 30 dias saem.
# CONTROLE NEGATIVO: sem alarmar NAO-CONSEGUI, sem conferir o RESULTADO com o rc, sem o rc do notify, sem a trava: o caso correspondente tem de enxergar a diferença.
# HETZNER_AUDIT_DAILY_UNDER_TEST=<arquivo> roda o selftest contra uma cópia alterada (mutante).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WRAP=${HETZNER_AUDIT_DAILY_UNDER_TEST:-$HERE/hetzner-audit-daily.sh}
T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/hzaudit-daily-selftest.XXXXXX")" && pwd -P)
trap 'chmod -R u+rwX "$T" 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
FAKE=$T/fake; CITY=$T/city; OUT=$CITY/.gc/hetzner-audit; mkdir -p "$FAKE" "$CITY/.gc"; export T
fails=0; n=0
ok() { n=$((n+1)); if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }

cat > "$FAKE/audit.sh" <<'EOF'
#!/bin/bash
echo x >> "$T/audit-calls"
[ -n "${FAKE_AUDIT_OUT:-}" ] && cat "$FAKE_AUDIT_OUT"
exit "${FAKE_AUDIT_RC:-0}"
EOF
cat > "$FAKE/notify" <<'EOF'
#!/bin/bash
{ echo "CALL strict=${NOTIFY_STRICT_EXIT:-} force=${NOTIFY_FORCE_PUSH:-}"; for a in "$@"; do printf 'ARG %s\n' "${a%%$'\n'*}"; done; } >> "$T/notify.log"
printf '%s' "$2" > "$T/notify.title"; printf '%s' "${!#}" > "$T/notify.last"      # o título (-t <título>) e o corpo inteiro (o último argumento, com as quebras de linha)
exit "${FAKE_NOTIFY_RC:-0}"
EOF
chmod +x "$FAKE"/*

LIMPO='AUDITORIA LIMPO processo: nenhum login
AUDITORIA LIMPO credenciais: só as conhecidas
AUDITORIA RESULTADO LIMPO (achados=0 nao-consegui=0 limpos=9) em urblink-teste-1 2026-11-12T05:41:00Z duracao=80s orcamento=540s'
ACHADO='AUDITORIA LIMPO processo: nenhum login
AUDITORIA ACHADO usuario-dados: o usuário '"'"'dados'"'"' não existe (trava 1 não aplicada)
AUDITORIA ACHADO fail2ban: fail2ban não instalado
AUDITORIA NAO-CONSEGUI ufw: ufw.conf ilegível
AUDITORIA DETALHE dados: gt-remote/traco-bim: NOME x
AUDITORIA RESULTADO ACHADO (achados=2 nao-consegui=1 limpos=6) em urblink-teste-1 2026-11-12T05:41:00Z duracao=95s orcamento=540s'
NAO='AUDITORIA LIMPO processo: nenhum login
AUDITORIA NAO-CONSEGUI dados: estourou o orçamento de 540s
AUDITORIA RESULTADO NAO-CONSEGUI (achados=0 nao-consegui=1 limpos=8) em urblink-teste-1 2026-11-12T05:41:00Z duracao=541s orcamento=540s'

mk() { chmod -R u+rwX "$CITY" 2>/dev/null; find "$CITY" -mindepth 1 -delete 2>/dev/null; mkdir -p "$CITY/.gc"; rm -f "$T"/audit-calls "$T"/notify.log "$T"/notify.title "$T"/notify.last "$T"/rep.txt; }
rep() { printf '%s\n' "$1" > "$T/rep.txt"; }
run() {  # run — o wrapper sob o ambiente atual; stdout em $out, rc em $rc
  out=$(HETZNER_AUDIT_SCRIPT="${AUDIT_PATH:-$FAKE/audit.sh}" HETZNER_AUDIT_NOTIFY="${NOTIFY_PATH:-$FAKE/notify}" GC_CITY_PATH="$CITY" FAKE_AUDIT_OUT="$T/rep.txt" PATH="$FAKE:$PATH" "$WRAP" 2>"$T/err"); rc=$?
}
calls() { [ -f "$T/notify.log" ] && grep -c '^CALL' "$T/notify.log" || echo 0; }
arg() { grep '^ARG ' "$T/notify.log" 2>/dev/null | sed 's/^ARG //'; }       # a 1ª linha de cada argumento de todas as chamadas, um por linha
title() { cat "$T/notify.title" 2>/dev/null; }; body() { cat "$T/notify.last" 2>/dev/null; }
audits() { [ -f "$T/audit-calls" ] && wc -l < "$T/audit-calls" | tr -d ' ' || echo 0; }

# --- limpo: nada de alarme, relatório guardado, heartbeat ---
mk; rep "$LIMPO"; FAKE_AUDIT_RC=0 run; [ "$rc" = 0 ] && [ "$(calls)" = 0 ] && [ "$(audits)" = 1 ]; ok $? "auditoria LIMPA: rc 0, a auditoria rodou uma vez, NENHUM alarme"
grep -q 'AUDITORIA RESULTADO LIMPO' "$OUT/last.txt"; ok $? "  o relatório ficou em last.txt"
ls "$OUT"/20??-??-??.txt >/dev/null 2>&1; ok $? "  e numa cópia datada"
printf '%s\n' "$out" | grep -qE '^AUDITORIA-DIARIA [0-9TZ:-]+ rc=0 AUDITORIA RESULTADO LIMPO'; ok $? "  a linha de heartbeat (a que o DPW lê) diz o rc e o RESULTADO"

# --- achado: UM alarme, veredito no título, só o que não é limpo no corpo ---
mk; rep "$ACHADO"; FAKE_AUDIT_RC=1 run; [ "$rc" = 0 ] && [ "$(calls)" = 1 ]; ok $? "ACHADO (rc 1): UM alarme e o wrapper sai 0 (o alarme foi entregue)"
[ "$(title)" = 'Auditoria Hetzner: ACHADO' ]; ok $? "  o veredito vai no TÍTULO (o notify descarta o mesmo título em 30 min)"
grep -q '^CALL strict=1 force=1$' "$T/notify.log"; ok $? "  pede ao notify o rc estrito e o push forçado (NOTIFY_STRICT_EXIT=1, NOTIFY_FORCE_PUSH=1: sem o 2º um -p 4 cai no resumo mudo)"
grep -q '^ARG -p$' "$T/notify.log" && grep -q '^ARG 4$' "$T/notify.log"; ok $? "  prioridade 4"
b=$(body); case "$b" in *"RESULTADO ACHADO (achados=2"*"ACHADO usuario-dados"*"ACHADO fail2ban"*"NAO-CONSEGUI ufw"*"$OUT/last.txt"*) true ;; *) false ;; esac; ok $? "  o corpo tem o RESULTADO, os ACHADO/NAO-CONSEGUI e o caminho do relatório"
case "$b" in *"LIMPO processo"*|*"DETALHE"*) false ;; *) true ;; esac; ok $? "  e NÃO os LIMPO nem o DETALHE (cabe num push)"
mk; rep "$NAO"; FAKE_AUDIT_RC=3 run; [ "$rc" = 0 ] && [ "$(calls)" = 1 ]; ok $? "NAO-CONSEGUI (rc 3): alarma também (não consegui NUNCA é silêncio)"; [ "$(title)" = 'Auditoria Hetzner: NAO-CONSEGUI' ]; ok $? "  título NAO-CONSEGUI"

# --- segredo no relatório: o push sai para um serviço EXTERNO, então URL com usuário:senha@ e token não podem ir no corpo ---
SEC=$(printf '%s%s' 'S3cr3t' 'Passw0rd'); TKG=$(printf '%s%s' 'ghp_' 'abcdefghijklmnopqrstuvwxyz0123456789')
LEAK="AUDITORIA ACHADO github-e-espelho: VIOLAÇÃO remotos=[https://x-access-token:$SEC@github.com/x/y $TKG]
AUDITORIA RESULTADO ACHADO (achados=1 nao-consegui=0 limpos=8) em urblink-teste-1 2026-11-12T05:41:00Z duracao=90s orcamento=540s"
mk; rep "$LEAK"; FAKE_AUDIT_RC=1 run; b=$(body); case "$b" in *"$SEC"*|*"${TKG#ghp_}"*) false ;; *) true ;; esac; ok $? "URL com usuário:senha@ e token ghp_ no relatório: NENHUM dos dois chega ao corpo do push"
case "$b" in *'://***@github.com/x/y'*'ghp_***'*) true ;; *) false ;; esac; ok $? "  o corpo mostra o mascaramento (***), não some a linha"

# --- quebrada: nunca silêncio ---
mk; rep "algo que não é um relatório"; FAKE_AUDIT_RC=7 run; [ "$(calls)" = 1 ]; ok $? "auditoria que sai com rc estranho (7): alarme"; [ "$(title)" = 'Auditoria Hetzner: QUEBRADA (rc=7)' ]; ok $? "  título QUEBRADA (rc=7)"
case "$(body)" in *"$OUT/last.err"*) true ;; *) false ;; esac; ok $? "  e o corpo aponta o stderr da auditoria (last.err), onde está o motivo"
mk; rep "AUDITORIA LIMPO processo: x"; FAKE_AUDIT_RC=0 run; [ "$(calls)" = 1 ]; ok $? "rc 0 sem linha RESULTADO: o relatório foi cortado no meio — alarme, não LIMPO"; title | grep -q 'QUEBRADA'; ok $? "  QUEBRADA"
mk; rep ""; FAKE_AUDIT_RC=1 run; [ "$(calls)" = 1 ]; ok $? "relatório vazio com rc 1: alarme"
mk; rep "$ACHADO"; FAKE_AUDIT_RC=0 run; [ "$(calls)" = 1 ]; ok $? "rc 0 mas o RESULTADO diz ACHADO: auditoria incoerente, alarme (nunca silêncio)"; title | grep -q 'QUEBRADA (rc=0)'; ok $? "  QUEBRADA (rc=0)"
mk; rep "$LIMPO"; FAKE_AUDIT_RC=1 run; [ "$(calls)" = 1 ]; ok $? "rc 1 mas o RESULTADO diz LIMPO: auditoria incoerente, alarme"; title | grep -q 'QUEBRADA (rc=1)'; ok $? "  QUEBRADA (rc=1)"

# --- notify que falha ---
mk; rep "$ACHADO"; FAKE_AUDIT_RC=1 FAKE_NOTIFY_RC=7 run; [ "$rc" = 4 ]; ok $? "notify que falha (7): o wrapper sai 4"; grep -q 'AUDITORIA RESULTADO ACHADO' "$OUT/last.txt"; ok $? "  e o relatório está guardado mesmo assim"
for c in 10 11; do mk; rep "$ACHADO"; FAKE_AUDIT_RC=1 FAKE_NOTIFY_RC=$c run; [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q "o notify saiu $c "; ok $? "notify saiu $c (guardado p/ as 7h / mesmo título há pouco): rc 0 (não é erro) e o log diz que o push pode não ter chegado"; done
mk; rep "$ACHADO"; FAKE_AUDIT_RC=1 FAKE_NOTIFY_RC=12 run; [ "$rc" = 4 ]; ok $? "notify saiu 12 (teto de pushes): NÃO entregue, rc 4"
mk; rep "$ACHADO"; FAKE_AUDIT_RC=1 NOTIFY_PATH=/nao/existe run; [ "$rc" = 4 ]; ok $? "notify ausente: rc 4"

# --- desligado ---
mk; rep "$ACHADO"; GC_HETZNER_AUDIT=0 FAKE_AUDIT_RC=1 run; [ "$rc" = 0 ] && [ "$(audits)" = 0 ] && [ "$(calls)" = 0 ]; ok $? "GC_HETZNER_AUDIT=0: nada roda, nada alarma"; printf '%s\n' "$out" | grep -q 'desligado'; ok $? "  e diz que está desligado"
mk; rep "$ACHADO"; : > "$CITY/.gc/no-hetzner-audit"; FAKE_AUDIT_RC=1 run; [ "$rc" = 0 ] && [ "$(audits)" = 0 ] && [ "$(calls)" = 0 ]; ok $? "arquivo .gc/no-hetzner-audit: idem"
mk; rep "$LIMPO"; GC_HETZNER_AUDIT=1 FAKE_AUDIT_RC=0 run; [ "$(audits)" = 1 ]; ok $? "só o valor 0 desliga"

# --- trava ---
mk; rep "$LIMPO"; mkdir -p "$OUT/lock"; sleep 30 & live=$!; echo "$live" > "$OUT/lock/pid"; FAKE_AUDIT_RC=0 run; kill "$live" 2>/dev/null; [ "$(audits)" = 0 ] && [ "$rc" = 0 ]; ok $? "trava com dono VIVO: nada roda"
mk; rep "$LIMPO"; mkdir -p "$OUT/lock"; echo 999999 > "$OUT/lock/pid"; FAKE_AUDIT_RC=0 run; [ "$(audits)" = 1 ]; ok $? "trava com dono MORTO: assume e roda"; [ ! -e "$OUT/lock" ]; ok $? "  e solta a trava no fim"

# --- auditoria ausente ---
mk; AUDIT_PATH=/nao/existe run; [ "$(calls)" = 1 ]; ok $? "auditoria ausente: alarme (QUEBRADA), nunca silêncio"; title | grep -q 'QUEBRADA (rc=127)'; ok $? "  rc=127"

# --- corpo comprido e retenção ---
mk; { for i in $(seq 1 30); do echo "AUDITORIA ACHADO dados: achado numero $i $(printf 'x%.0s' $(seq 1 300))"; done; echo "AUDITORIA RESULTADO ACHADO (achados=30 nao-consegui=0 limpos=0) em h t duracao=1s orcamento=540s"; } > "$T/rep.txt"; FAKE_AUDIT_RC=1 run
b=$(body); [ "${#b}" -le 2200 ]; ok $? "30 achados de 300+ colunas: o corpo do push é cortado (${#b} caracteres)"; case "$b" in *"mais 22"*) true ;; *) false ;; esac; ok $? "  e diz quantos ficaram de fora"
mk; rep "$LIMPO"; mkdir -p "$OUT"; : > "$OUT/2020-01-01.txt"; touch -t 202001010000 "$OUT/2020-01-01.txt"; : > "$OUT/2026-11-10.txt"; FAKE_AUDIT_RC=0 run; [ ! -e "$OUT/2020-01-01.txt" ] && [ -e "$OUT/2026-11-10.txt" ]; ok $? "relatório com mais de 30 dias sai, o recente fica"

# --- fiação: o plist aponta para ESTE wrapper, 1x por dia, fora de :00/:30, sem RunAtLoad, com o PATH em que o notify mora ---
PL=$HERE/../packs/town-deltas/assets/com.gascity.hetzner-audit.plist
chk=$(python3 -I - "$PL" "$WRAP" <<'PY'
import plistlib, sys, os
d = plistlib.load(open(sys.argv[1], "rb"))
bad = []
if d.get("Label") != "com.gascity.hetzner-audit": bad.append("label")
a = d.get("ProgramArguments") or []
if not a or os.path.basename(a[-1]) != os.path.basename(sys.argv[2]) or os.path.basename(os.path.dirname(a[-1])) != "scripts": bad.append("script")
c = d.get("StartCalendarInterval") or {}
if not isinstance(c.get("Hour"), int) or c.get("Minute") in (None, 0, 30): bad.append("horario")
if d.get("RunAtLoad"): bad.append("RunAtLoad")
if d.get("Nice") != 19: bad.append("nice")
if "KeepAlive" in d: bad.append("KeepAlive")
e = d.get("EnvironmentVariables") or {}
if ".local/bin" not in e.get("PATH", ""): bad.append("PATH sem .local/bin (o notify mora la)")
if not str(d.get("StandardOutPath", "")).endswith("/.gc/logs/hetzner-audit.out"): bad.append("StandardOutPath")
if not e.get("GC_CITY_PATH") or not e.get("HOME"): bad.append("GC_CITY_PATH/HOME")
print("ok" if not bad else "BAD " + ",".join(bad))
PY
)
[ "$chk" = ok ]; ok $? "o plist com.gascity.hetzner-audit aponta para o wrapper, 1x por dia fora de :00/:30, sem RunAtLoad/KeepAlive, nice 19 e PATH com .local/bin ($chk)"

# --- controle negativo ---
mutant() {  # mutant NOME SED-EXPR — grava o mutante em $T/mut.sh e confere que o sed mudou algo
  sed "$2" "$WRAP" > "$T/mut.sh"; ! cmp -s "$WRAP" "$T/mut.sh"; ok $? "  o mutante '$1' difere do script (o sed não é um no-op)"; chmod +x "$T/mut.sh"
}
WRAP_REAL=$WRAP
mutant "NAO-CONSEGUI não alarma" 's/\*) verdict=QUEBRADA ;;/*) verdict=QUEBRADA ;; esac; case $rc in 3) exit 0 ;;/'; WRAP=$T/mut.sh
mk; rep "$NAO"; FAKE_AUDIT_RC=3 run; WRAP=$WRAP_REAL; [ "$(calls)" = 0 ]; ok $? "controle negativo: sem alarmar o rc 3, o NAO-CONSEGUI passaria calado (o caso do rc 3 vê a diferença)"
mutant "notify falho ignorado" 's/\*) say "ERRO: o notify saiu/*) :; say "ERRO: o notify saiu/;s/exit 4 ;; esac/true ;; esac/'; WRAP=$T/mut.sh
mk; rep "$ACHADO"; FAKE_AUDIT_RC=1 FAKE_NOTIFY_RC=7 run; WRAP=$WRAP_REAL; [ "$rc" = 0 ]; ok $? "controle negativo: sem o rc do notify, um alarme perdido viraria sucesso"
mutant "RESULTADO sem conferir com o rc" 's/\[ "\$rs" = "\$verdict" \] || verdict=QUEBRADA/true/'; WRAP=$T/mut.sh
mk; rep "AUDITORIA LIMPO processo: x"; FAKE_AUDIT_RC=0 run; c1=$(calls); mk; rep "$ACHADO"; FAKE_AUDIT_RC=0 run; c2=$(calls); WRAP=$WRAP_REAL; [ "$c1$c2" = 00 ]; ok $? "controle negativo: sem conferir o RESULTADO com o rc, um relatório cortado (sem RESULTADO) ou incoerente (rc 0 e ACHADO) passaria como LIMPO"
mutant "push sem mascarar" 's/ | redact); nbad=/); nbad=/'; WRAP=$T/mut.sh
mk; rep "$LEAK"; FAKE_AUDIT_RC=1 run; WRAP=$WRAP_REAL; b=$(body); case "$b" in *"$SEC"*) true ;; *) false ;; esac; ok $? "controle negativo: sem o mascaramento, a senha do URL iria no push (o caso do vazamento vê a diferença)"

echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
