#!/usr/bin/env bash
# hetzner-audit-daily.sh — roda a auditoria do nó Hetzner TODO DIA (launchd, com.gascity.hetzner-audit) e ALARMA (notify) em ACHADO ou NAO-CONSEGUI (ga-qg1dw5z.3).
#
# Contents
#   O que faz · Códigos · Desligar · Limites
#
# O QUE FAZ: roda hetzner-audit.sh (que sempre termina com um RESULTADO, no máximo no orçamento dele), guarda o relatório em <cidade>/.gc/hetzner-audit/last.txt e numa cópia datada
#   (AAAA-MM-DD.txt, 30 dias), escreve UMA linha `AUDITORIA-DIARIA <hora> rc=N <RESULTADO>` no stdout (é o que o log .gc/logs/hetzner-audit.out mostra) e, se o veredito não é LIMPO, manda UM
#   push (`notify -p 4`, com NOTIFY_STRICT_EXIT=1 e NOTIFY_FORCE_PUSH=1) com o veredito no TÍTULO, o RESULTADO e as linhas ACHADO/NAO-CONSEGUI (até 8) no corpo, com URL usuário:senha@ e token MASCARADOS
#   (o push vai a um serviço externo; o scan do espelho imprime os remotos do git crus). Auditoria que sai com rc estranho, sem a linha RESULTADO (cortada no meio) ou com um
#   RESULTADO que não bate com o rc (rc 0 e "ACHADO", rc 1 e "LIMPO"), é QUEBRADA e alarma também: silêncio nunca vale como "limpo". Enquanto as travas 1 e 2 (usuário `dados`, SSH fechado) não estiverem aplicadas no nó o veredito é ACHADO: o alarme diário é isso.
# CÓDIGOS: 0 rodou (limpo, ou o alarme foi entregue: o notify saiu 0, 10 = guardado para as 7h, ou 11 = mesmo título há pouco; 10 e 11 ficam escritos no log) · 2 não consegui preparar a pasta/trava · 4 o alarme NÃO foi entregue
#   (notify ausente, falhou ou saiu 12 = teto de pushes): o relatório está em last.txt e a rodada de amanhã tenta de novo.
# DESLIGAR: GC_HETZNER_AUDIT=0 no ambiente ou o arquivo <cidade>/.gc/no-hetzner-audit (só o valor 0 desliga). Sem recarregar nada.
# LIMITES: uma rodada por vez (trava em .gc/hetzner-audit/lock com o pid do dono). Não repara nada, não lê o servidor sozinho: tudo é do hetzner-audit.sh. Selftest: hetzner-audit-daily.selftest.sh.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CITY=${GC_CITY_PATH:-$(cd "$HERE/.." && pwd)}
AUDIT=${HETZNER_AUDIT_SCRIPT:-$HERE/hetzner-audit.sh}
OUT=${HETZNER_AUDIT_DIR:-$CITY/.gc/hetzner-audit}
NOTIFY=${HETZNER_AUDIT_NOTIFY:-$(command -v notify 2>/dev/null || echo "$HOME/.local/bin/notify")}
KEEP_DAYS=30
say() { printf 'AUDITORIA-DIARIA %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

if [ "${GC_HETZNER_AUDIT:-}" = 0 ] || [ -e "$CITY/.gc/no-hetzner-audit" ]; then say "desligado (GC_HETZNER_AUDIT=0 ou $CITY/.gc/no-hetzner-audit): nada feito"; exit 0; fi
mkdir -p "$OUT" 2>/dev/null || { say "ERRO: não consegui criar $OUT"; exit 2; }
# uma rodada por vez: o mkdir é atômico e o pid dentro diz se o dono ainda vive (dono morto = trava velha, assume)
LOCK=$OUT/lock
if ! mkdir "$LOCK" 2>/dev/null; then
  owner=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then say "outra rodada (pid $owner) segura a trava: nada feito"; exit 0; fi
  rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || { say "ERRO: não consegui pegar a trava $LOCK"; exit 2; }
fi
echo $$ > "$LOCK/pid"; trap 'rm -rf "$LOCK"' EXIT

# vazio (a auditoria não existe) → rc 127, vira QUEBRADA; falhou (qualquer rc fora de 0/1/3, ou sem a linha RESULTADO) → QUEBRADA: nunca "limpo"
if [ -f "$AUDIT" ]; then bash "$AUDIT" > "$OUT/last.txt.tmp" 2> "$OUT/last.err"; rc=$?; else : > "$OUT/last.txt.tmp"; rc=127; fi
mv -f "$OUT/last.txt.tmp" "$OUT/last.txt"; cp "$OUT/last.txt" "$OUT/$(date -u +%Y-%m-%d).txt"
find "$OUT" -maxdepth 1 -name '20??-??-??.txt' -mtime +"$KEEP_DAYS" -delete 2>/dev/null
res=$(grep -m 1 '^AUDITORIA RESULTADO ' "$OUT/last.txt")
say "rc=$rc ${res:-sem linha RESULTADO}"
case $rc in 0) verdict=LIMPO ;; 1) verdict=ACHADO ;; 3) verdict=NAO-CONSEGUI ;; *) verdict=QUEBRADA ;; esac
# o estado que o RESULTADO diz tem de bater com o rc (rc 0 + "ACHADO", ou rc 1 + "LIMPO", é auditoria incoerente: QUEBRADA); sem a linha RESULTADO o estado vem vazio e também não bate
rs=$(printf '%s\n' "$res" | awk '{print $3}'); [ "$rs" = "$verdict" ] || verdict=QUEBRADA
[ "$verdict" = LIMPO ] && exit 0

title="Auditoria Hetzner: $verdict"; [ "$verdict" = QUEBRADA ] && title="Auditoria Hetzner: QUEBRADA (rc=$rc)"
# O push sai para um serviço EXTERNO (ntfy). A auditoria já mascara o que imprime (hetzner-audit.sh, redact), mas este é o limite de saída e não confia no que um relatório futuro traga: mascara de novo, ANTES do corte
# em 200 colunas (cortar primeiro deixaria o começo de um token partido ao meio passar pelo padrão).
redact() { sed -E -e 's#(://)[^/[:space:]]*@#\1***@#g' -e 's#(sk-ant-|gh[pousr]_|github_pat_|xox[abprs]-)[A-Za-z0-9_-]{8,}#\1***#g' -e 's#AKIA[0-9A-Z]{16}#AKIA***#g' -e 's#-----BEGIN [A-Z ]*PRIVATE KEY-----#***#g' -e 's#eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}[A-Za-z0-9_.-]*#***#g'; }
bad=$(grep -E '^AUDITORIA (ACHADO|NAO-CONSEGUI) ' "$OUT/last.txt" | redact); nbad=$(printf '%s\n' "$bad" | grep -c .)
body=$( { printf '%s\n' "${res:-sem linha RESULTADO (rc=$rc)}"; printf '%s\n' "$bad" | head -n 8 | cut -c1-200
          [ "$nbad" -gt 8 ] && printf '... e mais %s\n' "$((nbad - 8))"; printf 'Relatório: %s (stderr da auditoria: %s)\n' "$OUT/last.txt" "$OUT/last.err"; } )
# FORCE_PUSH: sem ele o notify escolhe push-vs-resumo pela redação do texto e um -p 4 pode cair no resumo horário mudo (ga-ff6t9); STRICT_EXIT faz o rc dizer o que saiu
NOTIFY_STRICT_EXIT=1 NOTIFY_FORCE_PUSH=1 "$NOTIFY" -t "$title" -p 4 "$body" > /dev/null 2>&1; nrc=$?
case $nrc in 0) ;; 10|11) say "o notify saiu $nrc (10 = guardado até as 7h, 11 = mesmo título há pouco): não é erro, mas o push pode ainda não ter chegado" ;; *) say "ERRO: o notify saiu $nrc: o alarme NÃO foi entregue (o relatório está em $OUT/last.txt)"; exit 4 ;; esac
exit 0
