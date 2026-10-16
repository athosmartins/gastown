#!/bin/bash
# jsonl-hourly-restore.selftest.sh (ga-c0939v) — testa o jsonl-hourly-restore.sh com um `bd` de mentira.
#
# Contents
#   Por quê · O que prova · O que NÃO prova · Uso
#
# POR QUÊ: o restore só tinha sido rodado de verdade no deacon (sem status customizado). No gastown real (16/10) ele reprovou:
#   o dump traz `status.custom = staged_ready,staged_warnings,done,pinned,deferred`; o bd de hoje já traz `pinned` e `deferred` de fábrica e
#   RECUSA O VALOR INTEIRO por causa deles; `done` nunca era registrado e o import reprovava na 251ª issue com "invalid status: done", e a
#   linha RESULT mostrava só o contador de progresso do bd, não o erro. Este teste reproduz isso sem Dolt e sem rede.
#
# O QUE PROVA (o `bd` de mentira recusa config e import com as MESMAS mensagens do bd real, medidas em 16/10):
#   1. dump sem config customizada: rc 0 e o diretório de trabalho some
#   2. status.custom com itens embutidos no meio (`pinned`, `deferred`, também na forma `pinned:frozen`): o config é repetido sem eles, os
#      itens que não colidem ficam (`done`), o import passa (rc 0) e o log diz o que saiu
#   3. status.custom só com itens embutidos: nada a configurar, rc 0, dito no log
#   4. types.custom sem colisão: UMA chamada, valor inteiro (o caminho comum não mudou)
#   5. config recusado por outro motivo: AVISO, o import segue e reprova (rc 1) — falha fechada, nunca "ok" por ter ignorado o erro
#   6. a linha RESULT de import reprovado traz o `.error` do bd (qual issue, qual status), não o contador de progresso
#   7. status desconhecido sem nenhuma config: rc 1
#   8. limpeza que não consegue apagar o diretório: tenta de novo, avisa, e o rc continua sendo o do restore
#   9. comentários de conteúdo idêntico (ids diferentes) que o import funde em um (gastown real: 443 escritos, 429 voltaram): rc 0,
#      a fusão aparece no relatório e na linha RESULT (dup_comments=1) — antes isso reprovava como "comments=429/443"
#  10. o bd que perde TODOS os comentários da issue (inclusive os dois gêmeos) reprova (rc 1): a fusão não é desculpa para perda
# O QUE NÃO PROVA: o bd real nem o Dolt (isso é a rodada de verdade, docs/runbooks/jsonl-hourly-offsite.md); o bd de mentira só valida
#   status e config. Contas de reconcile têm a suíte do jsonl_hourly.selftest.py.
#
# USO: bash jsonl-hourly-restore.selftest.sh        (JHR_SCRIPT=outra-cópia.sh testa essa cópia; usado pela campanha de mutantes)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESTORE="${JHR_SCRIPT:-$HERE/jsonl-hourly-restore.sh}"
[ -f "$RESTORE" ] || { echo "não achei $RESTORE" >&2; exit 2; }
for t in python3 jq; do command -v "$t" >/dev/null 2>&1 || { echo "falta $t" >&2; exit 2; }; done
command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || { echo "falta timeout (GNU)" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/jhr-selftest.XXXXXX")" || exit 2
case "$T" in */jhr-selftest.*) ;; *) echo "mktemp estranho: $T" >&2; exit 2 ;; esac
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/tmp" "$T/real-bin"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
no() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
check() { # descrição, esperado, obtido
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (obtido '$3', esperado '$2')"; fi
}
has() { # descrição, texto, agulha
  case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (não achei '$3' em: $(printf '%s' "$2" | tail -c 300 | tr '\n' ' '))" ;; esac
}
hasnt() {
  case "$2" in *"$3"*) no "$1 (achei '$3')" ;; *) ok "$1" ;; esac
}

# bd de mentira: o comportamento vai escrito dentro dele, porque o restore o chama com `env -i` (nenhuma variável do teste chega lá)
mk_bd() { # rejeita_config_por_outro_motivo(0|1)  comentarios(keep|merge|drop: o que o export devolve dos comentários)
  cat > "$T/bin/bd" <<EOF
#!/bin/bash
LOGF="$T/bd-calls.log"; REJECT_OTHER=$1; COMMENTS=${2:-keep}
BUILTIN=" open in_progress blocked deferred closed pinned hooked "
cmd="\${1:-}"; shift || true
echo "\$cmd:\${DOLT_DISABLE_EVENT_FLUSH:-unset}" >> "$T/bd-env.log"
case "\$cmd" in
  init) mkdir -p .beads; exit 0 ;;
  config)
    [ "\${1:-}" = set ] || exit 0
    key="\$2"; val="\$3"
    echo "config set \$key \$val" >> "\$LOGF"
    if [ "\$REJECT_OTHER" = 1 ]; then echo "Error: setting config: boom" >&2; exit 1; fi
    if [ "\$key" = status.custom ]; then
      IFS=,
      for it in \$val; do
        n="\${it%%:*}"
        case "\$BUILTIN" in *" \$n "*)
          echo "Error: setting config: validation failed: invalid status.custom value: custom status \"\$n\" collides with built-in status" >&2; exit 1 ;; esac
      done
      unset IFS
    fi
    mkdir -p .beads; echo "\$val" > ".beads/\$key"; echo "Set \$key = \$val"; exit 0 ;;
  import)
    f=""; for a in "\$@"; do case "\$a" in --*) ;; *) f="\$a" ;; esac; done
    custom=",\$(sed 's/:[a-z]*//g' .beads/status.custom 2>/dev/null),"
    total=\$(wc -l < "\$f" | tr -d ' ')
    while IFS= read -r line; do
      st=\$(printf '%s' "\$line" | jq -r '.status // empty'); id=\$(printf '%s' "\$line" | jq -r '.id // empty')
      [ -n "\$st" ] || continue
      case "\$BUILTIN" in *" \$st "*) continue ;; esac
      case "\$custom" in *",\$st,"*) continue ;; esac
      printf '{"error":"import failed: import chunk 2/11 failed, 250 issues already committed: validation failed for issue %s: invalid status: %s","schema_version":1}\n' "\$id" "\$st"
      echo "bd import: 250/\$total issues committed" >&2
      exit 1
    done < "\$f"
    cp "\$f" .beads/imported.jsonl; echo '{"ok":true}'; exit 0 ;;
  export)
    case "\$COMMENTS" in
      merge) jq -c 'if .comments then .comments |= unique_by([.author, .text, .created_at]) else . end' .beads/imported.jsonl ;;
      drop) jq -c 'del(.comments)' .beads/imported.jsonl ;;
      *) cat .beads/imported.jsonl ;;
    esac
    exit 0 ;;
esac
exit 0
EOF
  chmod +x "$T/bin/bd"
}

mk_dump() { # dir, statuses (separados por vírgula), status.custom ("" = sem), types.custom ("" = sem)
  python3 -I - "$1" "$2" "$3" "$4" <<'PYEOF'
import json, os, sys
d, statuses, scust, tcust = sys.argv[1:5]
base = os.path.join(d, "gt")
os.makedirs(base, exist_ok=True)
def put(name, rows):
    open(os.path.join(base, name + ".jsonl"), "w").write(json.dumps({"rows": rows}) if rows else "{}")
issues = []
for n, st in enumerate(statuses.split(","), 1):
    issues.append({"id": "gt-%d" % n, "title": "t%d" % n, "description": "", "status": st, "priority": "2", "issue_type": "task",
                   "created_at": "2026-10-01 00:00:00", "updated_at": "2026-10-01 00:00:00"})
cfg = [{"key": "issue_prefix", "value": "gt"}]
if scust: cfg.append({"key": "status.custom", "value": scust})
if tcust: cfg.append({"key": "types.custom", "value": tcust})
put("issues", issues); put("config", cfg)
for t in ("comments", "dependencies", "labels", "metadata"): put(t, [])
PYEOF
}

# roda o restore sobre um dump; guarda stdout/stderr/rc em $T/out, $T/err, $T/rc
# --min-free-mb 1: a guarda de disco do restore (3 GB) olharia o disco do host, e o teste não pode depender dele
run() { # dump  [PATH extra na frente]
  : > "$T/bd-calls.log"; : > "$T/bd-env.log"
  ( PATH="${2:+$2:}$PATH" TMPDIR="$T/tmp" JHR_BD="$T/bin/bd" "$RESTORE" --db gt --dump "$1" --min-free-mb 1 > "$T/out" 2> "$T/err" ); echo $? > "$T/rc"
}
rc() { cat "$T/rc"; }
leftover() { find "$T/tmp" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' '; }
calls() { grep -c "config set $1 " "$T/bd-calls.log" 2>/dev/null || true; }

echo "-- 1. dump sem config customizada"
mk_bd 0; mk_dump "$T/d1" "open,closed,in_progress" "" ""
run "$T/d1"
check "rc 0" 0 "$(rc)"; has "RESULT: OK" "$(cat "$T/out")" "RESULT: OK"
check "o diretório de trabalho some" 0 "$(leftover)"
check "nenhuma chamada de config" 0 "$(wc -l < "$T/bd-calls.log" | tr -d ' ')"
check "o bd rodou (init, import, export)" 3 "$(wc -l < "$T/bd-env.log" | tr -d ' ')"
check "toda chamada do bd com DOLT_DISABLE_EVENT_FLUSH=1" 0 "$(grep -vc ':1$' "$T/bd-env.log" || true)"

echo "-- 2. status.custom com itens embutidos no meio (o caso do gastown real)"
mk_bd 0; mk_dump "$T/d2" "open,done,staged_ready,pinned,closed,deferred" "staged_ready,staged_warnings,done,pinned,deferred" ""
run "$T/d2"
check "rc 0 (done passa a valer)" 0 "$(rc)"; has "RESULT: OK" "$(cat "$T/out")" "RESULT: OK"
check "3 chamadas de config (inteira, sem pinned, sem pinned/deferred)" 3 "$(calls status.custom)"
has "a última chamada leva só o que não colide" "$(tail -1 "$T/bd-calls.log")" "config set status.custom staged_ready,staged_warnings,done"
hasnt "e nem pinned nem deferred" "$(tail -1 "$T/bd-calls.log")" "pinned"
has "o log diz o que saiu" "$(cat "$T/err")" "pinned,deferred colide(m) com nome embutido"
has "e o que foi aplicado" "$(cat "$T/err")" "aplicado: staged_ready,staged_warnings,done"

echo "-- 2b. mesma coisa com categoria (nome:categoria)"
mk_bd 0; mk_dump "$T/d2b" "open,done,pinned" "staged_ready:wip,done:done,pinned:frozen" ""
run "$T/d2b"
check "rc 0" 0 "$(rc)"
has "a última chamada tira pinned:frozen e mantém as categorias dos outros" "$(tail -1 "$T/bd-calls.log")" "config set status.custom staged_ready:wip,done:done"
hasnt "sem pinned" "$(tail -1 "$T/bd-calls.log")" "pinned"

echo "-- 3. status.custom só com itens embutidos"
mk_bd 0; mk_dump "$T/d3" "open,pinned,deferred" "pinned,deferred" ""
run "$T/d3"
check "rc 0" 0 "$(rc)"
has "o log diz que não há o que configurar" "$(cat "$T/err")" "todos os itens (pinned,deferred) colidem"
hasnt "nenhuma recusa vira reprovação do restore" "$(cat "$T/out")" "FAIL"

echo "-- 4. types.custom sem colisão: o caminho comum não muda"
mk_bd 0; mk_dump "$T/d4" "open,closed" "" "molecule,convoy,gate"
run "$T/d4"
check "rc 0" 0 "$(rc)"
check "UMA chamada de types.custom" 1 "$(calls types.custom)"
has "com o valor inteiro" "$(cat "$T/bd-calls.log")" "config set types.custom molecule,convoy,gate"
hasnt "e nenhum AVISO de colisão" "$(cat "$T/err")" "colide"

echo "-- 5. config recusado por outro motivo: o import segue e reprova (falha fechada)"
mk_bd 1; mk_dump "$T/d5" "open,done" "done" ""
run "$T/d5"
check "rc 1" 1 "$(rc)"
has "AVISO de config não aplicada" "$(cat "$T/err")" "config status.custom não aplicada"
check "UMA tentativa só (não é colisão, não repete)" 1 "$(calls status.custom)"

echo "-- 6. a linha RESULT de import reprovado traz o erro do bd"
has "RESULT: FAIL" "$(cat "$T/out")" "RESULT: FAIL db=gt motivo=bd import rc=1"
has "qual issue e qual status" "$(cat "$T/out")" "validation failed for issue gt-2: invalid status: done"
hasnt "e não só o contador de progresso" "$(cat "$T/out")" "issues committed"

echo "-- 7. status desconhecido sem nenhuma config"
mk_bd 0; mk_dump "$T/d7" "open,weird" "" ""
run "$T/d7"
check "rc 1" 1 "$(rc)"
has "o erro cita o status" "$(cat "$T/out")" "invalid status: weird"

echo "-- 8. limpeza que não consegue apagar"
# rm de mentira só para o diretório de trabalho do restore em si (…/jsonl-hourly-restore.XXXXXX, sem subcaminho); qualquer outro rm é o de verdade
REAL_RM="$(command -v rm)"
cat > "$T/real-bin/rm" <<EOF
#!/bin/bash
for a in "\$@"; do case "\$a" in */jsonl-hourly-restore.??????) echo "rm: \$a: Directory not empty" >&2; exit 1 ;; esac; done
exec "$REAL_RM" "\$@"
EOF
chmod +x "$T/real-bin/rm"
mk_bd 0; mk_dump "$T/d8" "open,closed" "" ""
run "$T/d8" "$T/real-bin"
check "o rc continua sendo o do restore (0)" 0 "$(rc)"
has "RESULT: OK" "$(cat "$T/out")" "RESULT: OK"
has "avisa que não apagou" "$(cat "$T/err")" "não consegui apagar"
check "sobrou o diretório (e o aviso diz qual)" 1 "$(leftover)"
for d in "$T"/tmp/jsonl-hourly-restore.*; do [ -d "$d" ] && "$REAL_RM" -rf "$d"; done

echo "-- 8b. limpeza que falha só na primeira vez: a segunda tentativa apaga"
rm -f "$T/rm-count"
cat > "$T/real-bin/rm" <<EOF
#!/bin/bash
for a in "\$@"; do case "\$a" in */jsonl-hourly-restore.??????)
  if [ ! -e "$T/rm-count" ]; then : > "$T/rm-count"; echo "rm: \$a: Directory not empty" >&2; exit 1; fi ;; esac; done
exec "$REAL_RM" "\$@"
EOF
mk_bd 0; mk_dump "$T/d8b" "open,closed" "" ""
run "$T/d8b" "$T/real-bin"
check "rc 0" 0 "$(rc)"
check "o diretório sumiu na segunda tentativa" 0 "$(leftover)"
hasnt "e não há aviso" "$(cat "$T/err")" "não consegui apagar"

mk_twins() { # dir: duas issues; a gt-1 tem dois comentários idênticos (ids diferentes) e um diferente
  mk_dump "$1" "open,closed" "" ""
  python3 -I - "$1/gt/comments.jsonl" <<'PYEOF'
import json, sys
t = {"issue_id": "gt-1", "author": "x", "text": "igual", "created_at": "2026-10-01 01:00:00"}
rows = [dict(t, id="c1"), dict(t, id="c2"), {"id": "c3", "issue_id": "gt-1", "author": "y", "text": "outro", "created_at": "2026-10-01 02:00:00"}]
open(sys.argv[1], "w").write(json.dumps({"rows": rows}))
PYEOF
}

echo "-- 9. comentários idênticos que o import funde"
mk_bd 0 merge; mk_twins "$T/d9"
run "$T/d9"
check "rc 0 (fusão de gêmeos é exclusão por desenho, não perda)" 0 "$(rc)"
has "RESULT: OK" "$(cat "$T/out")" "RESULT: OK"
has "comments restaurado/esperado 2/2" "$(cat "$T/out")" "comments=2/2"
has "a linha RESULT conta a fusão" "$(cat "$T/out")" "dup_comments=1"
has "o relatório mostra a exclusão" "$(cat "$T/out")" "comentários-idênticos-fundidos=1"

echo "-- 9b. o mesmo dump com um bd que NÃO funde"
mk_bd 0 keep; mk_twins "$T/d9b"
run "$T/d9b"
check "rc 0" 0 "$(rc)"
has "dup_comments=0" "$(cat "$T/out")" "dup_comments=0"

echo "-- 10. bd que perde os comentários"
mk_bd 0 drop; mk_twins "$T/d10"
run "$T/d10"
check "rc 1" 1 "$(rc)"
has "RESULT: FAIL" "$(cat "$T/out")" "RESULT: FAIL"
has "o problema diz que comentários não voltaram" "$(cat "$T/out")" "comments do dump não voltaram"

echo
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
