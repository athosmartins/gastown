#!/usr/bin/env bash
# session-host-scoreboard.selftest.sh — hermético: a "cidade" é uma pasta de fixtures com um events.jsonl do engine e os events.jsonl do
# provider por host; nada fala com host nenhum. Fuso fixo (America/Sao_Paulo) para as fronteiras da noite (20:00 → 08:00) serem as mesmas
# em qualquer máquina.
#
# Contents
#   Casos · Controle negativo (mutantes) · Variáveis
#
# CASOS: noite que atravessa a meia-noite (23:10 e 03:00 são a MESMA noite) · fronteiras 07:59/08:00 e 19:59/20:00 · papel pelo nome
#   (refino-gate-reviewer é revisor, não "outros"; wa-worker-remote-mbp NÃO conta no mini) · fração de segundos com 5 dígitos (o engine
#   grava assim e o Python 3.9 não lê) · linha ilegível é contada e avisada, não omitida · host remoto: started conta, refused vira
#   recusa por motivo, stopped é ignorado · --noites limita · --json é JSON · log que não abre = exit 1, não "zero" · sem dados.
#   Cobertura (g_rot): o engine RODA o events.jsonl — o vivo começa com events.rotated no meio da noite e o resto está no .gz anterior
#   (ligado pelo seq): com o .gz a noite é completa; sem ele, ou com o seq sem par, a noite é PARCIAL e a anterior SEM FONTE (null, não
#   0), com aviso · .gz corrompido = exit 1 · host remoto cujo log começa no meio da noite = parcial · toda noite pedida sai · em curso.
# CONTROLE NEGATIVO: parser de data sem a normalização, revisor do refino fora da lista de revisores, a noite começando às 19, a noite acabando às 9, o mini
#   contando sessões `-remote-`, e `refused` contado como início — cada um é aplicado numa cópia e o teste TEM que falhar.
# VARIÁVEIS: SB_UNDER_TEST (script a testar) · SB_PY (interpretador; padrão /usr/bin/python3) · SB_NO_MUTANTS=1
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
P="${SB_UNDER_TEST:-$HERE/session-host-scoreboard.py}"
export TZ=America/Sao_Paulo
T=$(cd "$(mktemp -d /tmp/sb.XXXXXX)" && pwd -P)
cleanup() { chmod -R u+rwX "$T" 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null; }
trap cleanup EXIT
fails=0; n=0
ok() { n=$((n+1)); if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
NOW="2026-10-15T09:30:00-03:00"

mkcity() {  # mkcity DIR
  local c="$1"; mkdir -p "$c/.gc/runtime/session-ssh/mbp" "$c/.gc/runtime/session-ssh/hetzner"
  w() { printf '{"seq":1,"type":"%s","ts":"%s","actor":"gc","subject":"%s"}\n' "$1" "$2" "$3"; }
  {
    w session.woke 2026-10-14T23:10:00.379098-03:00 wa-worker-adhoc-1          # noite 14, construtor
    w session.woke 2026-10-15T03:00:00.64447-03:00  gastown.dog-2              # nome REAL do motor (pack.): construtor; 5 dígitos de fração; noite 14 (depois da meia-noite)
    w session.woke 2026-10-15T07:59:59-03:00        gate-reviewer-adhoc-x      # noite 14, último segundo
    w session.woke 2026-10-15T01:00:00-03:00        refino-gate-reviewer-adhoc-y   # revisor, não "outros"
    w session.woke 2026-10-15T08:00:00-03:00        wa-worker-adhoc-dia        # de dia: fora
    w session.woke 2026-10-14T12:00:00-03:00        wa-worker-adhoc-meio       # de dia: fora
    w session.woke 2026-10-14T19:59:59-03:00        wa-worker-adhoc-antes      # 19:59: fora
    w session.woke 2026-10-14T20:00:00-03:00        ps-worker-adhoc-2          # 20:00: noite 14, construtor
    w session.woke 2026-10-14T23:00:00-03:00        wa-worker-remote-mbp-1     # remoto: NÃO conta no mini
    w session.woke 2026-10-13T22:00:00-03:00        auto-refiner-adhoc-z       # noite 13, outros
    w bead.updated  2026-10-15T01:30:00-03:00       wa-worker-adhoc-9          # outro tipo de evento: ignorado
    echo 'notjson garbage mas diz "session.woke"'                              # ilegível (JSON corrompido: a leitura falha e a linha é pulada)
  } > "$c/.gc/events.jsonl"
  e() { printf '{"ts":"%s","host":"%s","session":"%s","event":"%s"%s}\n' "$1" "$2" "$3" "$4" "${5:+,\"reason\":\"$5\"}"; }
  {
    e 2026-10-15T02:00:00Z mbp wa-worker-remote-mbp-1 started         # 23:00 -03 do dia 14: noite 14
    e 2026-10-15T04:00:00Z mbp wa-worker-remote-mbp-2 started         # 01:00 -03: noite 14
    e 2026-10-15T05:00:00Z mbp wa-worker-remote-mbp-3 refused "Athos está no MBP"
    e 2026-10-15T05:05:00Z mbp wa-worker-remote-mbp-3 refused "Athos está no MBP"
    e 2026-10-15T05:10:00Z mbp wa-worker-remote-mbp-4 refused "teto do host"
    e 2026-10-15T06:00:00Z mbp wa-worker-remote-mbp-1 stopped         # ignorado
    e 2026-10-15T06:30:00Z mbp gate-reviewer-remote-mbp-1 started     # revisor
  } > "$c/.gc/runtime/session-ssh/mbp/events.jsonl"
  e 2026-10-15T03:00:00Z hetzner dog-remote-hetzner-1 started > "$c/.gc/runtime/session-ssh/hetzner/events.jsonl"
}
C="$T/city"; mkcity "$C"
PY="${SB_PY:-/usr/bin/python3}"  # o Python 3.9 do sistema por padrão: é o mais velho que o script promete (o fromisoformat dele é o exigente)
run() { "$PY" -I "$P" --city "$C" --agora "$NOW" "$@" >"$T/out" 2>"$T/err"; RC=$?; }
has() { grep -qF -- "$2" "$1" 2>/dev/null; }
# num NOITE HOST CAMPO → valor do --json
num() { jq -r --arg n "$1" --arg h "$2" --arg c "$3" '.noites[] | select(.noite==$n) | .hosts[$h][$c] // "ausente"' "$T/out" 2>/dev/null; }

g_main() {
  run --json; ok $RC "placar: --json roda (rc=$RC $(head -c 150 "$T/err"))"
  jq -e . "$T/out" >/dev/null 2>&1; ok $? "placar: a saída de --json é JSON"
  [ "$(num 2026-10-14 mini construtor)" = 3 ]; ok $? "placar: mini, noite 14: construtores = wa-worker 23:10 + dog 03:00 (5 dígitos de fração) + ps-worker 20:00 = 3 (deu $(num 2026-10-14 mini construtor))"
  [ "$(num 2026-10-14 mini revisor)" = 2 ]; ok $? "placar: mini, noite 14: revisores = gate-reviewer 07:59:59 + refino-gate-reviewer = 2 (deu $(num 2026-10-14 mini revisor))"
  [ "$(num 2026-10-14 mini outros)" = 0 ]; ok $? "placar: refino-gate-reviewer não vira 'outros'"
  [ "$(num 2026-10-13 mini outros)" = 1 ]; ok $? "placar: noite 13 separada; auto-refiner é 'outros'"
  jq -e '[.noites[].hosts.mini.construtor] | add == 3' "$T/out" >/dev/null; ok $? "placar: 08:00, 12:00 e 19:59:59 (de dia) não entram; 20:00 entra (só os 3 da noite 14)"
  [ "$(num 2026-10-14 mbp construtor)" = 2 ] && [ "$(num 2026-10-14 mbp revisor)" = 1 ]; ok $? "placar: MBP vem do events.jsonl do provider (started): 2 construtores e 1 revisor na noite 14"
  [ "$(jq -r '.noites[] | select(.noite=="2026-10-14") | .hosts.mbp.recusas["Athos está no MBP"]' "$T/out")" = 2 ] && [ "$(jq -r '.noites[] | select(.noite=="2026-10-14") | .hosts.mbp.recusas["teto do host"]' "$T/out")" = 1 ]; ok $? "placar: recusas do MBP por motivo (Athos no MBP = 2, teto = 1), e NÃO contam como construção"
  [ "$(num 2026-10-14 hetzner construtor)" = 1 ]; ok $? "placar: cada pasta de host do provider vira uma coluna (hetzner)"
  [ "$(jq -r '.noites[] | select(.noite=="2026-10-14") | .hosts.mini.construtor' "$T/out")" = 3 ]; ok $? "placar: a sessão wa-worker-remote-mbp-1 que o engine acordou NÃO conta como construção do mini"
  [ "$(jq -r .linhas_ilegiveis "$T/out")" = 1 ]; ok $? "placar: a linha ilegível é contada (1), não omitida"
  run; ok $RC "placar: texto roda"; has "$T/out" 'noite de 2026-10-14' && has "$T/out" 'mbp' && has "$T/out" 'recusas: Athos está no MBP=2'; ok $? "placar: o texto mostra a noite, o host e as recusas"
  has "$T/err" 'AVISO: 1 linha'; ok $? "placar: o aviso de linha ilegível sai no stderr do texto"
  run --json --noites 1; [ "$(jq '.noites | length' "$T/out")" = 1 ] && [ "$(jq -r '.noites[0].noite' "$T/out")" = 2026-10-14 ]; ok $? "placar: --noites 1 traz só a mais recente"
  run --noites 0; [ $RC = 2 ]; ok $? "placar: --noites 0 é uso errado (exit 2)"
  "$PY" -I "$P" --city "$C" --agora "2026-10-15T09:30:00" >/dev/null 2>"$T/err"; [ $? = 2 ] && has "$T/err" fuso; ok $? "placar: --agora sem fuso é recusado (a noite depende do fuso)"
  mkdir -p "$T/vazia/.gc"; "$PY" -I "$P" --city "$T/vazia" --agora "$NOW" >"$T/out" 2>&1; [ $? = 0 ] && has "$T/out" 'mini       sem fonte' && has "$T/out" 'não existe' && ! has "$T/out" construtores; ok $? "placar: cidade sem logs → exit 0, o mini sai 'sem fonte' (não 0) e o aviso diz que o log do engine não existe"
  if [ "$(id -u)" != 0 ]; then
    chmod 000 "$C/.gc/runtime/session-ssh/mbp/events.jsonl"; run --json; [ $RC = 1 ] && has "$T/err" 'não consegui ler'; ok $? "placar: log do host que não abre → exit 1 (não vira 'zero construções') (rc=$RC)"
    chmod 644 "$C/.gc/runtime/session-ssh/mbp/events.jsonl"
  fi
  python3 -I "$P" --city "$C" --agora "$NOW" --json >"$T/out" 2>/dev/null; [ "$(num 2026-10-14 mini construtor)" = 3 ]; ok $? "placar: também sob o python3 do PATH ($(python3 --version 2>&1))"
}

g_rot() {  # o events.jsonl do engine rodado no meio da noite 14; o .gz anterior tem a noite 13 e o começo da 14
  local R="$T/rot"; mkdir -p "$R/.gc/runtime/session-ssh/mbp" "$R/.gc/runtime/session-ssh/vazio"
  w() { printf '{"seq":%s,"type":"%s","ts":"%s","actor":"gc","subject":"%s"}\n' "$1" "$2" "$3" "$4"; }
  { w 1 bead.created 2026-10-13T10:00:00-03:00 x; w 2 session.woke 2026-10-13T22:00:00-03:00 gastown.dog-1
    w 3 session.woke 2026-10-15T01:00:00-03:00 gate-reviewer-adhoc-a; } | gzip > "$R/.gc/events.jsonl.archive-20261015T050000Z-seq-1-100.gz"
  { printf '{"seq":101,"type":"events.rotated","ts":"2026-10-15T02:00:00-03:00","actor":"events","message":"rotated"}\n'
    w 102 session.woke 2026-10-15T03:00:00-03:00 wa-worker-adhoc-b; } > "$R/.gc/events.jsonl"
  printf '{"ts":"2026-10-15T02:00:00Z","host":"mbp","session":"wa-worker-remote-mbp-1","event":"started"}\n' > "$R/.gc/runtime/session-ssh/mbp/events.jsonl"
  rr() { "$PY" -I "$P" --city "$R" --agora "$NOW" "$@" >"$T/out" 2>"$T/err"; RC=$?; }
  cv() { jq -r --arg n "$1" --arg h "$2" '.noites[] | select(.noite==$n) | .hosts[$h].cobertura' "$T/out" 2>/dev/null; }
  rr --json; ok $RC "rot: roda (rc=$RC $(head -c 150 "$T/err"))"
  [ "$(num 2026-10-14 mini construtor)/$(num 2026-10-14 mini revisor)" = 1/1 ] && [ "$(cv 2026-10-14 mini)" = completa ]; ok $? "rot: noite 14 soma o .gz (revisor 01:00) e o vivo (construtor 03:00), completa (deu $(num 2026-10-14 mini construtor)/$(num 2026-10-14 mini revisor) $(cv 2026-10-14 mini))"
  [ "$(num 2026-10-13 mini construtor)" = 1 ] && [ "$(jq -r '.cobertura_desde.mini' "$T/out")" = início ]; ok $? "rot: noite 13 vem só do .gz; o .gz começa no seq 1 → cobertura desde o início"
  [ "$(jq '[.avisos[] | select(startswith("mini:"))] | length' "$T/out")" = 0 ]; ok $? "rot: com a corrente inteira, nenhum aviso sobre o mini"
  [ "$(cv 2026-10-14 mbp)" = parcial ] && [ "$(cv 2026-10-13 mbp)" = sem-fonte ] && [ "$(num 2026-10-13 mbp construtor)" = ausente ]; ok $? "rot: host cujo log começa às 23:00 da noite 14 → 14 parcial, 13 sem fonte (null, não 0)"
  [ "$(cv 2026-10-14 vazio)" = sem-fonte ] && has "$T/out" 'vazio: o log do host não existe'; ok $? "rot: pasta de host sem log → sem fonte, com aviso"
  [ "$(jq '.noites | length' "$T/out")" = 7 ] && [ "$(cv 2026-10-09 mini)" = completa ] && [ "$(num 2026-10-09 mini construtor)" = 0 ]; ok $? "rot: as 7 noites saem, e uma noite coberta sem sessão é 0 (não falta)"
  mv "$R/.gc/events.jsonl.archive-20261015T050000Z-seq-1-100.gz" "$T/arch.gz"
  rr --json; [ "$(cv 2026-10-14 mini)" = parcial ] && [ "$(num 2026-10-14 mini revisor)" = 0 ] && [ "$(cv 2026-10-13 mini)" = sem-fonte ] && [ "$(num 2026-10-13 mini construtor)" = ausente ] && has "$T/out" 'só cobrem a partir de 2026-10-15T02:00'
  ok $? "rot: sem o .gz → noite 14 PARCIAL, 13 SEM FONTE, e o aviso diz desde quando (não 'não houve sessão') ($(cv 2026-10-14 mini)/$(cv 2026-10-13 mini))"
  rr; has "$T/out" 'PARCIAL (log desde 2026-10-15T02:00' && has "$T/out" 'mini       sem fonte'; ok $? "rot: o texto mostra PARCIAL e 'sem fonte'"
  cp "$T/arch.gz" "$R/.gc/events.jsonl.archive-20261015T050000Z-seq-1-99.gz"
  rr --json; [ "$(cv 2026-10-14 mini)" = parcial ]; ok $? "rot: .gz cujo seq não encosta no do vivo (buraco) não conta como cobertura"
  rm -f "$R/.gc/events.jsonl.archive-20261015T050000Z-seq-1-99.gz"; head -c 40 "$T/arch.gz" > "$R/.gc/events.jsonl.archive-20261015T050000Z-seq-1-100.gz"
  rr --json; [ $RC = 1 ] && has "$T/err" 'não consegui ler'; ok $? "rot: .gz corrompido → exit 1, não 'o log acabou ali' (rc=$RC)"
  cp "$T/arch.gz" "$R/.gc/events.jsonl.archive-20261015T050000Z-seq-1-100.gz"
  rr --json --agora 2026-10-15T03:30:00-03:00 --noites 2; [ "$(jq -r '.noites[0].noite, .noites[0].em_curso, .noites[1].em_curso' "$T/out" | tr '\n' ' ')" = "2026-10-14 true false " ]; ok $? "rot: às 03:30 a noite 14 está em curso, a 13 não"
}

if [ -n "${SB_MUTANT:-}" ]; then g_main; g_rot; echo "RESULT $fails/$n"; exit $((fails > 0)); fi
g_main
g_rot
echo "== $((n-fails))/$n ok =="

[ -n "${SB_NO_MUTANTS:-}" ] || {
  echo "-- controle negativo: cada guarda removida TEM que reprovar o grupo"
  mutant() {  # mutant DESCRIÇÃO SED-EXPR
    local m="$T/mut.$RANDOM"; mkdir -p "$m"; sed -e "$2" "$P" > "$m/sb.py"; chmod +x "$m/sb.py"
    if cmp -s "$P" "$m/sb.py"; then ok 1 "mutante '$1': o sed não mudou nada"; return; fi
    local r; r=$(SB_MUTANT=1 SB_UNDER_TEST="$m/sb.py" bash "$0" 2>&1 | tail -1)
    case "$r" in "RESULT 0/"*) ok 1 "mutante '$1' NÃO foi pego ($r)";; "RESULT "*) ok 0 "mutante '$1' pego ($r)";; *) ok 1 "mutante '$1': sem resultado ($r)";; esac
  }
  mutant "fração de segundos sem normalizar" "s/{(m.group(2) or '')\[:6\].ljust(6, '0')}/{m.group(2) or '0'}/"
  mutant "refino-gate-reviewer fora da lista de revisores" 's/REVIEWERS = ("gate-reviewer", "refino-gate-reviewer", "context-check-reviewer")/REVIEWERS = ("gate-reviewer", "context-check-reviewer")/'
  mutant "noite começando às 19" 's/NIGHT_FROM, NIGHT_TO = 20, 8/NIGHT_FROM, NIGHT_TO = 19, 8/'
  mutant "noite acabando às 9" 's/NIGHT_FROM, NIGHT_TO = 20, 8/NIGHT_FROM, NIGHT_TO = 20, 9/'
  mutant "mini conta sessão -remote-" 's/ or "-remote-" in name//'
  mutant "recusa contada como início" 's/if kind == "started":/if kind in ("started", "refused"):/'
  mutant "log do engine ausente vira zero em silêncio" 's/^                return None$/                return GENESIS/'
  mutant "não segue o .gz anterior" 's/prev = by_last.get(seq - 1) if type(seq) is int else None/prev = None/'
  mutant "noite sem fonte vira completa/parcial" 's/if cover is None or cover >= ne:/if False:/'
  mutant "noite parcial vira completa" 's/return "completa" if cover <= ns else "parcial"/return "completa"/'
  mutant "seq 1 não é o início" 's/if type(seq) is int and seq == 1:/if False:/'
  mutant ".gz truncado vira fim de arquivo" 's/except (EOFError, zlib.error) as e:/except ZeroDivisionError as e:/'
  mutant "log do host remoto sempre cobre" 's/covers\[h\] = head_ts(head)/covers[h] = GENESIS/'
  mutant "log ilegível vira zero" 's/except OSError as e:/except ZeroDivisionError as e:/'
  echo "== final: $((n-fails))/$n ok =="
}
[ "$fails" = 0 ]
