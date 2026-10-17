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
#  Disco (ga-c0939v.4; o store do bd real cresce 38-57× o import e o volume é o do Dolt da cidade; df e import são de mentira):
#  11. disco que enche DURANTE o import: a vigia mata o import, apaga o diretório, rc 2 "sem veredito" (nunca FAIL nem OK)
#  12. a mesma vigia não mata um restore saudável (disco folgado, import de 3 s)
#  13. df que para de responder durante o import: sem como garantir o piso, interrompe como se estivesse abaixo (rc 2)
#  14. o próprio bd recusando por "no space left": rc 2, não "o dump não reproduz" (rc 1)
#  15. a guarda de antes do import usa o fator medido (60×) e arredonda o import para cima; --disk-factor menor deixa tentar
#  16. TERM no restore com o import rodando: o import morre junto e o diretório some (job em segundo plano ignora Ctrl-C)
#  17. --disk-factor/--disk-floor-mb/--min-free-mb vazios ou inválidos: rc 3, nunca seguem com o default
#  18. (helper de mentira via JHR_PY) saída do helper que não dá para ler não vira veredito: extract.json ilegível => rc 2 (antes `bad` vazio = "as
#      tabelas conferem"); manifest sem `files` => rc 2; conversor que morre com traceback (sem `.error`) => rc 2, não "o dump não converteu";
#      o `.error` do conversor com DumpError continua FAIL (rc 1), com OSError do host (ENOSPC, EACCES...) é rc 2; --report-out que não grava avisa (rc do restore)
#  19. bd import morto por sinal (SIGKILL/OOM, rc 137) sem dizer o motivo: rc 2 "sem veredito", não FAIL (o FAIL de import exige `.error`)
#  20. --dump com caminho relativo (o link no diretório de trabalho apontaria para dentro dele): rc 0; 20b. --manifest com --dump avisa que é ignorado
#  Reprovação do gate ga-15eiut (17/10; cada item abaixo reprova contra o script anterior, 27 asserções):
#  21. opção com valor como ÚLTIMO argumento (ou seguida de outra opção) é rc 3 em segundos, não laço infinito (rc 124); `--from-s3` sem valor é `latest`;
#      latest.json com chave fora do padrão é dado ruim do bucket (rc 2), não uso errado (rc 3)
#  22. a vigia e o TERM do restore matam o bd que IGNORA o TERM: o KILL vai ao grupo do `timeout`, o import não fica órfão
#  23. bd morto por sinal com `.error` parcial (rc 137): rc 2 (a cláusula rc>=128; provada por mutante: sem ela o teste cai)
#  24. bd recusando por memória/descritores/lock/permissão/E-S/disco só leitura/quota ou motivo desconhecido (rc 1 com `.error`): rc 2; só "validation failed" é FAIL
#  25. export que não é JSON: rc 2, sem erro de jq · 26. prefixo do store: hífen preservado, outro caractere vira `_`, sem `_` de sobra no fim
#  Reprovação do gate ga-7345xi (17/10, 3ª): 27. zero à esquerda é decimal (--disk-factor 08 / 010) e número de 10 dígitos é uso errado (rc 3)
#  28. --report-out leva a identidade do run (banco, origem, hora) e o relatório velho é apagado se o run não chega lá · o RESULT traz manifest_checked
#  Cada item de 11 a 16 foi provado reprovando (campanha de mutantes, 16/10): vigia desligada, FLOOR_HIT ignorado, fator 3×, ENOSPC
#  sem tratamento, cleanup sem matar o import, import arredondado para baixo => cada um derruba pelo menos um teste, e só os dele.
#  O 18 também (17/10): cada uma das quatro guardas removida derruba só os testes dela.
# O QUE NÃO PROVA: o bd real nem o Dolt (isso é a rodada de verdade, docs/runbooks/jsonl-hourly-offsite.md); o bd de mentira só valida
#   status e config. Contas de reconcile têm a suíte do jsonl_hourly_restore.selftest.py.
#
# USO: bash jsonl-hourly-restore.selftest.sh        (JHR_SCRIPT=outra-cópia.sh testa essa cópia; usado pela campanha de mutantes)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESTORE="${JHR_SCRIPT:-$HERE/jsonl-hourly-restore.sh}"
[ -f "$RESTORE" ] || { echo "não achei $RESTORE" >&2; exit 2; }
RESTORE="$(cd "$(dirname "$RESTORE")" && pwd)/$(basename "$RESTORE")"   # o teste 20 muda de diretório
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
mk_bd() { # rejeita_config_por_outro_motivo(0|1)  comentarios(keep|merge|drop|garbage: o que o export devolve dos comentários)
  cat > "$T/bin/bd" <<EOF
#!/bin/bash
LOGF="$T/bd-calls.log"; REJECT_OTHER=$1; COMMENTS=${2:-keep}
BUILTIN=" open in_progress blocked deferred closed pinned hooked "
cmd="\${1:-}"; shift || true
echo "\$cmd:\${DOLT_DISABLE_EVENT_FLUSH:-unset}" >> "$T/bd-env.log"
case "\$cmd" in
  init) mkdir -p .beads; echo "\$*" >> "$T/bd-init.log"; exit 0 ;;
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
    # modo do import lido em tempo de execução (o restore chama o bd com env -i): fill = o disco enche e o import fica pendurado,
    # breakdf = o df passa a falhar, hang = pendurado sem mexer no disco, slow = 3 s, enospc = o próprio bd recusa por falta de espaço,
    # killed = o bd leva SIGKILL (OOM) no meio, sem JSON em stdout: só o contador de progresso em stderr, killederr = idem mas COM um .error parcial,
    # stubborn = enche o disco e IGNORA o TERM (só o KILL pára), envfail = recusa com a mensagem de $T/import-msg (rc 1, como diria de um dump ruim)
    case "\$(cat "$T/import-mode" 2>/dev/null)" in
      fill) echo \$\$ > "$T/bd-import.pid"; echo 100 > "$T/free-mb"; exec sleep 40 ;;
      breakdf) echo \$\$ > "$T/bd-import.pid"; : > "$T/df-broken"; exec sleep 40 ;;
      hang) echo \$\$ > "$T/bd-import.pid"; exec sleep 40 ;;
      slow) sleep 3 ;;
      enospc) printf '{"error":"import failed: write /s/.beads/journal.idx: no space left on device","schema_version":1}\n'; echo "bd import: 250/9 issues committed" >&2; exit 1 ;;
      killed) echo "bd import: 250/9 issues committed" >&2; kill -9 \$\$ ;;
      killederr) printf '{"error":"import failed: boom","schema_version":1}\n'; echo "bd import: 250/9 issues committed" >&2; kill -9 \$\$ ;;
      stubborn) echo \$\$ > "$T/bd-import.pid"; echo 100 > "$T/free-mb"; trap '' TERM; while [ \$SECONDS -lt 60 ]; do sleep 1; done; exit 0 ;;
      envfail) printf '{"error":"%s","schema_version":1}\n' "\$(cat "$T/import-msg")"; exit 1 ;;
    esac
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
      garbage) echo 'isto não é json' ;;
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
  # --disk-floor-mb 0: a vigia de disco (piso de 2 GB) olharia o disco do host; os testes de 1 a 10 não podem depender dele
  ( PATH="${2:+$2:}$PATH" TMPDIR="$T/tmp" JHR_BD="$T/bin/bd" "$RESTORE" --db gt --dump "$1" --min-free-mb 1 --disk-floor-mb 0 > "$T/out" 2> "$T/err" ); echo $? > "$T/rc"
}
# df de mentira: o "disco livre" é o número em $T/free-mb (e some se $T/df-broken existir); modo do import em $T/import-mode
mk_df() {
  cat > "$T/bin/df" <<EOF
#!/bin/bash
[ -e "$T/df-broken" ] && exit 1
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "fake 0 0 \$(( \$(cat "$T/free-mb") * 1024 )) 0% /"
EOF
  chmod +x "$T/bin/df"
}
run_df() { # dump  mb_livres_no_início  modo_do_import  [opções extras do restore]
  local d="$1" free="$2" mode="$3"; shift 3
  : > "$T/bd-calls.log"; : > "$T/bd-env.log"; rm -f "$T/df-broken" "$T/bd-import.pid"; echo "$free" > "$T/free-mb"; echo "$mode" > "$T/import-mode"
  SECONDS=0
  ( TMPDIR="$T/tmp" JHR_BD="$T/bin/bd" JHR_DF="$T/bin/df" JHR_WATCH_INTERVAL=1 "$RESTORE" --db gt --dump "$d" --min-free-mb 1 "$@" > "$T/out" 2> "$T/err" ); echo $? > "$T/rc"
  ELAPSED=$SECONDS
}
gone() { # o pid do import de mentira morreu? (1 = sim, 0 = ainda vivo, ? = nunca nasceu)
  [ -s "$T/bd-import.pid" ] || { echo "?"; return; }
  # zumbi (Z) = morto, só falta o pai/launchd colher: `kill -0` o dá por vivo e, com a máquina carregada, reprovava um import que o KILL do grupo matou
  case "$(ps -o stat= -p "$(cat "$T/bd-import.pid")" 2>/dev/null | tr -d ' ')" in ""|Z*) echo 1 ;; *) echo 0 ;; esac
}
rc() { cat "$T/rc"; }
leftover() { find "$T/tmp" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' '; }
calls() { grep -c "config set $1 " "$T/bd-calls.log" 2>/dev/null || true; }

echo "-- 1. dump sem config customizada"
mk_bd 0; mk_dump "$T/d1" "open,closed,in_progress" "" ""
run "$T/d1"
check "rc 0" 0 "$(rc)"; has "RESULT: OK" "$(cat "$T/out")" "RESULT: OK"
check "o diretório de trabalho some" 0 "$(leftover)"
has "o resumo diz que --dump não conferiu manifest" "$(cat "$T/out")" "manifest_checked=false"
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
check "rc 0" 0 "$(rc)"; has "a última chamada tira pinned:frozen e mantém as categorias dos outros" "$(tail -1 "$T/bd-calls.log")" "config set status.custom staged_ready:wip,done:done"
hasnt "sem pinned" "$(tail -1 "$T/bd-calls.log")" "pinned"

echo "-- 3. status.custom só com itens embutidos"
mk_bd 0; mk_dump "$T/d3" "open,pinned,deferred" "pinned,deferred" ""
run "$T/d3"
check "rc 0" 0 "$(rc)"; has "o log diz que não há o que configurar" "$(cat "$T/err")" "todos os itens (pinned,deferred) colidem"
hasnt "nenhuma recusa vira reprovação do restore" "$(cat "$T/out")" "FAIL"

echo "-- 4. types.custom sem colisão: o caminho comum não muda"
mk_bd 0; mk_dump "$T/d4" "open,closed" "" "molecule,convoy,gate"
run "$T/d4"
check "rc 0" 0 "$(rc)"; check "UMA chamada de types.custom" 1 "$(calls types.custom)"
has "com o valor inteiro" "$(cat "$T/bd-calls.log")" "config set types.custom molecule,convoy,gate"
hasnt "e nenhum AVISO de colisão" "$(cat "$T/err")" "colide"

echo "-- 5. config recusado por outro motivo: o import segue e reprova (falha fechada)"
mk_bd 1; mk_dump "$T/d5" "open,done" "done" ""
run "$T/d5"
check "rc 1" 1 "$(rc)"; has "AVISO de config não aplicada" "$(cat "$T/err")" "config status.custom não aplicada"
check "UMA tentativa só (não é colisão, não repete)" 1 "$(calls status.custom)"

echo "-- 6. a linha RESULT de import reprovado traz o erro do bd"
has "RESULT: FAIL" "$(cat "$T/out")" "RESULT: FAIL db=gt motivo=bd import rc=1"
has "qual issue e qual status" "$(cat "$T/out")" "validation failed for issue gt-2: invalid status: done"
hasnt "e não só o contador de progresso" "$(cat "$T/out")" "issues committed"

echo "-- 7. status desconhecido sem nenhuma config"
mk_bd 0; mk_dump "$T/d7" "open,weird" "" ""
run "$T/d7"
check "rc 1" 1 "$(rc)"; has "o erro cita o status" "$(cat "$T/out")" "invalid status: weird"

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
check "rc 0" 0 "$(rc)"; check "o diretório sumiu na segunda tentativa" 0 "$(leftover)"
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
check "rc 0 (fusão de gêmeos é exclusão por desenho, não perda)" 0 "$(rc)"; has "RESULT: OK" "$(cat "$T/out")" "RESULT: OK"
has "comments restaurado/esperado 2/2" "$(cat "$T/out")" "comments=2/2"
has "a linha RESULT conta a fusão" "$(cat "$T/out")" "dup_comments=1"
has "o relatório mostra a exclusão" "$(cat "$T/out")" "comentários-idênticos-fundidos=1"

echo "-- 9b. o mesmo dump com um bd que NÃO funde"
mk_bd 0 keep; mk_twins "$T/d9b"
run "$T/d9b"
check "rc 0" 0 "$(rc)"; has "dup_comments=0" "$(cat "$T/out")" "dup_comments=0"

echo "-- 10. bd que perde os comentários"
mk_bd 0 drop; mk_twins "$T/d10"
run "$T/d10"
check "rc 1" 1 "$(rc)"; has "RESULT: FAIL" "$(cat "$T/out")" "RESULT: FAIL"
has "o problema diz que comentários não voltaram" "$(cat "$T/out")" "comments do dump não voltaram"

mk_big_dump() { # dir, MB de descrição numa issue (para o import ficar com tamanho de verdade)
  mk_dump "$1" "open,closed" "" ""
  python3 -I - "$1/gt/issues.jsonl" "$2" <<'PYEOF'
import json, sys
p, mb = sys.argv[1], int(sys.argv[2])
rows = json.load(open(p))["rows"]
rows[0]["description"] = "x" * (mb * 1048576)
open(p, "w").write(json.dumps({"rows": rows}))
PYEOF
}

# Seção 11 em diante (ga-c0939v.4): medido em 16/10 no bd real, o store cresce 38-57× o import (whatsapp_automation: 78 MB -> 2933 MB) e o
# volume é o do Dolt da cidade. Aqui o disco e o import são de mentira: ninguém enche disco de verdade.
echo "-- 11. o disco enche DURANTE o import: a vigia interrompe, rc 2, sem veredito"
mk_bd 0; mk_df; mk_dump "$T/d11" "open,closed" "" ""
run_df "$T/d11" 100000 fill --disk-floor-mb 2048
check "rc 2 (sem veredito)" 2 "$(rc)"; has "RESULT: UNKNOWN com o motivo" "$(cat "$T/out")" "RESULT: UNKNOWN db=gt motivo=disco abaixo do piso durante o import"
has "diz quanto sobrou e qual era o piso" "$(cat "$T/out")" "100 MB livres < 2048"
has "diz que nada foi provado" "$(cat "$T/out")" "nada foi provado"
hasnt "e nunca vira FAIL nem OK" "$(cat "$T/out")" "RESULT: FAIL"
check "o bd import foi morto" 1 "$(gone)"
check "o diretório de trabalho some" 0 "$(leftover)"
if [ "$ELAPSED" -lt 20 ]; then ok "interrompe em segundos, sem esperar os 40 s do import (levou ${ELAPSED}s)"; else no "interrompeu devagar demais: ${ELAPSED}s"; fi

echo "-- 12. disco folgado e import lento: a vigia não mata um restore saudável"
mk_bd 0; mk_dump "$T/d12" "open,closed" "" ""
run_df "$T/d12" 100000 slow --disk-floor-mb 2048
check "rc 0" 0 "$(rc)"; has "RESULT: OK" "$(cat "$T/out")" "RESULT: OK"

echo "-- 13. o df para de responder durante o import: sem como garantir o piso, interrompe (inerte)"
mk_bd 0; mk_dump "$T/d13" "open,closed" "" ""
run_df "$T/d13" 100000 breakdf --disk-floor-mb 2048
check "rc 2" 2 "$(rc)"; has "RESULT: UNKNOWN" "$(cat "$T/out")" "RESULT: UNKNOWN db=gt motivo=disco abaixo do piso durante o import: ? MB livres"
check "o bd import foi morto" 1 "$(gone)"
check "o diretório de trabalho some" 0 "$(leftover)"

echo "-- 14. o próprio bd recusa por falta de espaço: sem veredito, não 'o dump não reproduz'"
mk_bd 0; mk_dump "$T/d14" "open,closed" "" ""
run_df "$T/d14" 100000 enospc --disk-floor-mb 0
check "rc 2" 2 "$(rc)"; has "RESULT: UNKNOWN" "$(cat "$T/out")" "RESULT: UNKNOWN db=gt motivo=bd import sem espaço em disco"
hasnt "e não FAIL" "$(cat "$T/out")" "RESULT: FAIL"

echo "-- 15. a guarda de antes do import usa o fator medido (60×), não 3×"
mk_bd 0; mk_big_dump "$T/d15" 20
run_df "$T/d15" 1000 normal --disk-floor-mb 0
check "20 MB de import com 1000 MB livres: rc 2" 2 "$(rc)"
has "pouco disco para importar" "$(cat "$T/out")" "pouco disco para importar"
has "o motivo cita o fator" "$(cat "$T/out")" "60× o import"
check "e o bd nem foi chamado" 0 "$(wc -l < "$T/bd-env.log" | tr -d ' ')"
run_df "$T/d15" 1000 normal --disk-floor-mb 0 --disk-factor 10
check "com --disk-factor 10 o mesmo dump segue (rc 0)" 0 "$(rc)"
mk_dump "$T/d15b" "open,closed" "" ""
run_df "$T/d15b" 560 normal --disk-floor-mb 0
check "import de menos de 1 MB conta como 1 MB (60 + 512 > 560): rc 2, não '0 MB, não precisa de disco'" 2 "$(rc)"

echo "-- 16. abortar o restore (TERM) com o import rodando mata o import e apaga o diretório"
mk_bd 0; mk_dump "$T/d16" "open,closed" "" ""
rm -f "$T/bd-import.pid"; echo hang > "$T/import-mode"
TMPDIR="$T/tmp" JHR_BD="$T/bin/bd" "$RESTORE" --db gt --dump "$T/d16" --min-free-mb 1 --disk-floor-mb 0 > "$T/out" 2> "$T/err" &
RP=$!
for _ in $(seq 1 100); do [ -s "$T/bd-import.pid" ] && break; sleep 0.2; done
kill -TERM "$RP" 2>/dev/null; wait "$RP"; echo $? > "$T/rc"
check "o restore sai com 143" 143 "$(rc)"
check "o bd import morreu junto" 1 "$(gone)"
check "o diretório de trabalho some" 0 "$(leftover)"
echo normal > "$T/import-mode"

echo "-- 17. opções numéricas vazias ou inválidas: uso errado (rc 3), nunca seguem com o default"
for opt in --disk-factor --disk-floor-mb --min-free-mb; do
  ( TMPDIR="$T/tmp" JHR_BD="$T/bin/bd" "$RESTORE" --db gt --dump "$T/d11" "$opt" "" > "$T/out" 2> "$T/err" ); check "$opt vazio: rc 3" 3 "$?"
done
( TMPDIR="$T/tmp" JHR_BD="$T/bin/bd" "$RESTORE" --db gt --dump "$T/d11" --disk-floor-mb 10x > "$T/out" 2> "$T/err" ); check "--disk-floor-mb 10x: rc 3" 3 "$?"

# Seção 18 (ga-c0939v.4, autoauditoria do "não sei"): saída ilegível do helper não vira veredito. Helper de mentira via JHR_PY.
cat > "$T/stub.py" <<'STUBEOF'
import os, sys
cmd = sys.argv[1]
if cmd == "extract":
    if os.environ["STUB_EXTRACT"] == "garbage":
        print("{isto não é json")
    else:
        print('{"files": [{"path": "gt/issues.jsonl", "bytes": 1, "sha256": "x"}], "missing": []}')
    sys.exit(0)
if os.environ["STUB_CONVERT"] == "crash":
    sys.stderr.write("Traceback (most recent call last):\nZeroDivisionError: boom\n")
    sys.exit(1)
if os.environ["STUB_CONVERT"] == "oserror":
    print('{"error": "OSError: [Errno 28] No space left on device"}')
    sys.exit(1)
print('{"error": "DumpError: tabela quebrada"}')
sys.exit(1)
STUBEOF
printf 'artefato' > "$T/art.tgz"
ART_SHA="$(python3 -I -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$T/art.tgz")"
printf '{"schema":1,"databases":{"gt":{}},"files":[{"path":"gt/issues.jsonl","bytes":1,"sha256":"x"}],"artifact":{"sha256":"%s","bytes":8}}' "$ART_SHA" > "$T/man-ok.json"
printf '{"schema":1,"databases":{"gt":{}},"artifact":{"sha256":"%s","bytes":8}}' "$ART_SHA" > "$T/man-nofiles.json"
run_stub() { # extract(garbage|ok)  convert(crash|error|oserror)  manifest — modo artefato, helper de mentira
  ( TMPDIR="$T/tmp" JHR_BD="$T/bin/bd" JHR_PY="$T/stub.py" STUB_EXTRACT="$1" STUB_CONVERT="$2" "$RESTORE" --db gt --artifact "$T/art.tgz" --manifest "$3" \
      --min-free-mb 1 --disk-floor-mb 0 > "$T/out" 2> "$T/err" ); echo $? > "$T/rc"
}
echo "-- 18. o que o helper devolve e não dá para ler não vira veredito"
mk_bd 0
run_stub garbage error "$T/man-ok.json"
check "extract.json ilegível: rc 2 (nem 'confere' nem FAIL)" 2 "$(rc)"
has "e diz por quê" "$(cat "$T/out")" "RESULT: UNKNOWN db=gt motivo=extract.json ilegível"
run_stub ok error "$T/man-nofiles.json"
check "manifest sem 'files': rc 2 (não 'tabela diferente do registrado')" 2 "$(rc)"
has "manifest ilegível ou de outro schema" "$(cat "$T/out")" "manifest ilegível ou de outro schema"
run_stub ok crash "$T/man-ok.json"
check "o conversor morre com traceback (sem '.error'): rc 2, não 'o dump não converteu'" 2 "$(rc)"
has "o motivo traz o fim do traceback" "$(cat "$T/out")" "o conversor saiu rc=1 sem dizer o motivo: Traceback"
hasnt "e não é FAIL" "$(cat "$T/out")" "RESULT: FAIL"
echo "-- 18b. mas o dump que o helper DIZ estar quebrado continua sendo FAIL (rc 1)"
run_stub ok error "$T/man-ok.json"
check "'.error' do conversor: rc 1" 1 "$(rc)"
has "RESULT: FAIL com o motivo do helper" "$(cat "$T/out")" "RESULT: FAIL db=gt motivo=dump não converteu: {\"error\": \"DumpError: tabela quebrada\"}"
echo "-- 18d. OSError do host (ENOSPC, EIO, EACCES, EMFILE) vem em '.error' do conversor como o erro do dump: não julga o dump, rc 2"
run_stub ok oserror "$T/man-ok.json"
check "ENOSPC no conversor: rc 2" 2 "$(rc)"; hasnt "e não FAIL" "$(cat "$T/out")" "RESULT: FAIL"
has "UNKNOWN com o errno" "$(cat "$T/out")" "RESULT: UNKNOWN db=gt motivo=o conversor esbarrou no ambiente (rc=1), não no dump: OSError: [Errno 28] No space left on device"
if [ "$(id -u)" != 0 ]; then   # root lê qualquer arquivo: sem EACCES para provar
  mk_dump "$T/d18d" "open,closed" "" ""; chmod 000 "$T/d18d/gt/issues.jsonl"; run "$T/d18d"; chmod 600 "$T/d18d/gt/issues.jsonl"; check "helper de verdade, tabela sem leitura (EACCES): rc 2" 2 "$(rc)"
fi
mk_dump "$T/d18e" "open,closed" "" ""; rm "$T/d18e/gt/issues.jsonl"; run "$T/d18e"
check "tabela AUSENTE no dump (DumpError, é o dump): continua FAIL, rc 1" 1 "$(rc)"
echo "-- 18c. --report-out que não grava: o veredito sai, o aviso também"
mk_bd 0; mk_dump "$T/d18" "open,closed" "" ""
( TMPDIR="$T/tmp" JHR_BD="$T/bin/bd" "$RESTORE" --db gt --dump "$T/d18" --min-free-mb 1 --disk-floor-mb 0 --report-out "$T/nao-existe/r.json" > "$T/out" 2> "$T/err" ); echo $? > "$T/rc"
check "rc 0 (o veredito é do restore, não do relatório)" 0 "$(rc)"; has "AVISO de relatório não gravado" "$(cat "$T/err")" "AVISO: não gravei o relatório em $T/nao-existe/r.json"

# Reprovação do gate ga-hwjqvp (17/10): o import que morre sem dizer o motivo e o --dump relativo
echo "-- 19. bd import que morre sem dizer o motivo (SIGKILL/OOM, rc 137): sem veredito, não 'o dump não reproduz'"
mk_bd 0; mk_dump "$T/d19" "open,closed" "" ""
run_df "$T/d19" 100000 killed --disk-floor-mb 0
check "rc 2" 2 "$(rc)"; has "RESULT: UNKNOWN com o rc" "$(cat "$T/out")" "RESULT: UNKNOWN db=gt motivo=bd import morreu sem dizer o motivo (rc=137)"
has "e o fim do stderr do bd" "$(cat "$T/out")" "250/9 issues committed"
hasnt "e não FAIL" "$(cat "$T/out")" "RESULT: FAIL"
check "o diretório de trabalho some" 0 "$(leftover)"
echo "-- 20. --dump com caminho relativo (o link no diretório de trabalho resolveria contra o próprio diretório de trabalho)"
mk_bd 0; mk_dump "$T/d20" "open,closed" "" ""
echo normal > "$T/import-mode"   # run() não mexe no modo do import: sem isto sobraria o `killed` do 19
( cd "$T" && run d20 )
check "rc 0" 0 "$(rc)"; has "RESULT: OK" "$(cat "$T/out")" "RESULT: OK"
echo "-- 20b. --manifest junto com --dump: ignorado, e o log diz"
( TMPDIR="$T/tmp" JHR_BD="$T/bin/bd" "$RESTORE" --db gt --dump "$T/d20" --manifest "$T/nao-existe.json" --min-free-mb 1 --disk-floor-mb 0 > "$T/out" 2> "$T/err" ); echo $? > "$T/rc"
check "rc 0" 0 "$(rc)"; has "AVISO de manifest ignorado" "$(cat "$T/err")" "AVISO: --manifest é ignorado com --dump"

# Reprovação do gate ga-15eiut (17/10): opção com valor como ÚLTIMO argumento girava para sempre (`shift 2` sem deslocar); a vigia matava só o `timeout`
echo "-- 21. opção com valor sem o valor (última, ou seguida de outra opção): rc 3 em segundos, nunca laço infinito"
mk_bd 0; mk_dump "$T/d21" "open,closed" "" ""
for opt in --db --artifact --manifest --dump --work --report-out --min-free-mb --import-timeout --prefix --disk-factor --disk-floor-mb; do
  ( TMPDIR="$T/tmp" JHR_BD="$T/bin/bd" timeout 10 "$RESTORE" --db gt --keep "$opt" > "$T/out" 2> "$T/err" ); check "$opt como último argumento: rc 3" 3 "$?"
done
( TMPDIR="$T/tmp" JHR_BD="$T/bin/bd" timeout 10 "$RESTORE" --db gt --dump "$T/d21" --prefix --keep --min-free-mb 1 --disk-floor-mb 0 > "$T/out" 2> "$T/err" )
check "--prefix --keep: o valor não é a próxima opção (rc 3, não prefixo '--keep')" 3 "$?"
mkdir -p "$T/aws-bin"; printf '#!/bin/bash\necho "{\\"snapshot_key\\":\\"outro/x.tar.gz\\"}" > "${@: -1}"\n' > "$T/aws-bin/aws"; chmod +x "$T/aws-bin/aws"
for pos in "--from-s3" "--from-s3 --min-free-mb 1 --disk-floor-mb 0"; do   # --from-s3 sem valor = latest, no fim ou no meio
  ( TMPDIR="$T/tmp" JHR_BD="$T/bin/bd" JHO_AWS="$T/aws-bin/aws" timeout 10 "$RESTORE" --db gt $pos > "$T/out" 2> "$T/err" )
  check "$pos sem valor: rc 2 (latest.json com chave estranha é dado ruim do bucket, não uso errado)" 2 "$?"
done
has "e o motivo cita a chave" "$(cat "$T/out")" "latest.json aponta para uma chave fora de jsonl-hourly/snap/*.tar.gz: outro/x.tar.gz"

echo "-- 22. a vigia interrompe um bd que IGNORA o TERM: o KILL vai ao grupo inteiro, o import não fica órfão"
mk_bd 0; mk_df; mk_dump "$T/d22" "open,closed" "" ""
JHR_TERM_GRACE=2 run_df "$T/d22" 100000 stubborn --disk-floor-mb 2048
check "rc 2 (sem veredito)" 2 "$(rc)"; check "o bd import morreu de verdade (não só o timeout)" 1 "$(gone)"
if [ "$ELAPSED" -lt 20 ]; then ok "e logo depois da tolerância, sem esperar os 60 s do bd (${ELAPSED}s)"; else no "demorou ${ELAPSED}s"; fi
echo "-- 22b. TERM no restore com o bd ignorando o TERM: o import morre junto"
mk_dump "$T/d22b" "open,closed" "" ""
rm -f "$T/bd-import.pid"; echo stubborn > "$T/import-mode"
TMPDIR="$T/tmp" JHR_BD="$T/bin/bd" "$RESTORE" --db gt --dump "$T/d22b" --min-free-mb 1 --disk-floor-mb 0 > "$T/out" 2> "$T/err" &
RP=$!
for _ in $(seq 1 100); do [ -s "$T/bd-import.pid" ] && break; sleep 0.2; done
kill -TERM "$RP" 2>/dev/null; wait "$RP"; echo $? > "$T/rc"
check "rc 143" 143 "$(rc)"; check "o bd import morreu junto" 1 "$(gone)"
echo normal > "$T/import-mode"

echo "-- 23. bd import morto por sinal COM .error parcial (rc 137): sem veredito, o bd não julgou o dump"
mk_bd 0; mk_dump "$T/d23" "open,closed" "" ""
run_df "$T/d23" 100000 killederr --disk-floor-mb 0
check "rc 2" 2 "$(rc)"; has "RESULT: UNKNOWN (rc=137)" "$(cat "$T/out")" "RESULT: UNKNOWN db=gt motivo=bd import morreu sem dizer o motivo (rc=137)"

echo "-- 24. o bd recusa por falta de memória/descritores/lock do ambiente: sem veredito, não 'o dump não reproduz'"
mk_bd 0; mk_dump "$T/d24" "open,closed" "" ""
for m in "fork/exec: Cannot allocate memory" "open /s/x: too many open files" "open /s/x: permission denied" "write /s/x: input/output error" "read-only file system" "disk quota exceeded" "Error 1105: database is locked"; do
  printf '%s' "$m" > "$T/import-msg"; run_df "$T/d24" 100000 envfail --disk-floor-mb 0
  check "rc 2: $m" 2 "$(rc)"
done
has "RESULT: UNKNOWN com o motivo do bd" "$(cat "$T/out")" "RESULT: UNKNOWN db=gt motivo=bd import sem recurso do ambiente: Error 1105: database is locked"
printf '%s' "motivo que ninguém viu" > "$T/import-msg"; run_df "$T/d24" 100000 envfail --disk-floor-mb 0
check "motivo fora da lista (só 'validation failed' é FAIL): rc 2" 2 "$(rc)"
has "e diz que não é a validação" "$(cat "$T/out")" "recusou por um motivo que não é a validação do dump (rc=1): motivo que ninguém viu"

echo "-- 25. export que não é JSON: o reconcile não chega às contas => rc 2, não 'RESULT: FAIL ... dup_comments=null'"
mk_bd 0 garbage; mk_dump "$T/d25" "open,closed" "" ""
echo normal > "$T/import-mode"; run "$T/d25"
check "rc 2" 2 "$(rc)"; has "RESULT: UNKNOWN com o problema" "$(cat "$T/out")" "RESULT: UNKNOWN db=gt motivo=reconcile não chegou às contas: entrada da prova ilegível"
hasnt "sem erro de jq" "$(cat "$T/err")" "jq:"

echo "-- 26. prefixo do store: hífen é preservado (o bd aceita), outro caractere vira _ sem um _ de sobra no fim"
mk_bd 0; mk_dump "$T/d26" "open,closed" "" ""
for pf in "lex-bh:lex-bh" "lex bh:lex_bh"; do
  : > "$T/bd-init.log"; ( TMPDIR="$T/tmp" JHR_BD="$T/bin/bd" "$RESTORE" --db gt --dump "$T/d26" --prefix "${pf%%:*}" --min-free-mb 1 --disk-floor-mb 0 > "$T/out" 2> "$T/err" )
  check "--prefix '${pf%%:*}' => init -p ${pf##*:}" "-p ${pf##*:} --non-interactive" "$(tail -1 "$T/bd-init.log")"
done

echo "-- 27. zero à esquerda é decimal (08 não é octal inválido, 010 não vale 8); número de 10 dígitos é uso errado"
mk_bd 0; mk_big_dump "$T/d27" 20
run_df "$T/d27" 1000 normal --disk-floor-mb 0 --disk-factor 08
check "--disk-factor 08: rc 0" 0 "$(rc)"; run_df "$T/d27" 690 normal --disk-floor-mb 0 --disk-factor 010
check "--disk-factor 010 vale 10 (20×10+512 > 690): rc 2" 2 "$(rc)"; has "e a conta mostra 10×" "$(cat "$T/out")" "MB (10× o import"
run_df "$T/d27" 1000 normal --disk-floor-mb 0 --disk-factor 1234567890; check "--disk-factor com 10 dígitos: rc 3" 3 "$(rc)"

echo "-- 28. --report-out leva a identidade do run, e o relatório velho não sobrevive a um run que não chegou lá"
mk_bd 0; mk_dump "$T/d28" "open,closed" "" ""; echo velho > "$T/r28.json"
( TMPDIR="$T/tmp" JHR_BD="$T/bin/bd" "$RESTORE" --db gt --dump "$T/d28" --min-free-mb 1 --disk-floor-mb 0 --report-out "$T/r28.json" > "$T/out" 2> "$T/err" ); echo $? > "$T/rc"
check "rc 0" 0 "$(rc)"; check "o relatório diz banco e origem do run" "gt true" "$(jq -r '"\(.run.db) \(.run.source | endswith("/d28"))"' "$T/r28.json" 2>&1)"
mk_dump "$T/d28b" "open,closed" "" ""; rm "$T/d28b/gt/issues.jsonl"
( TMPDIR="$T/tmp" JHR_BD="$T/bin/bd" "$RESTORE" --db gt --dump "$T/d28b" --min-free-mb 1 --disk-floor-mb 0 --report-out "$T/r28.json" > "$T/out" 2> "$T/err" ); echo $? > "$T/rc"
check "run reprovado antes do relatório: rc 1" 1 "$(rc)"; check "e o relatório do run anterior sumiu" nao "$([ -e "$T/r28.json" ] && echo sim || echo nao)"

echo
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
