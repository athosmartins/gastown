#!/usr/bin/env bash
# hetzner-ballast-signal-proof.selftest.sh — hermético (ga-2hd02v.8): o script de prova de sinais do lastro (scripts/hetzner-ballast-signal-proof.py) contra um `gt-iso-run` de BRINQUEDO.
# Sem rede, sem root, sem nó. O que NÃO cabe aqui: a cadeia sudo real e o bash root do helper — essa parte só se prova no nó (docs/runbooks/hetzner-ballast.md, "Medido"); aqui
# se prova o que o script FAZ com o que mede: os três desfechos (provado · não provado · não consegui medir), e que ele só toca na PRÓPRIA sessão.
#
# Contents
#   Casos · Controle negativo · Variáveis
#
# CASOS
#   todo host: sintaxe · sem gt-iso-run → rc 2 NAO-MEDI (nunca provado) · sem /proc (macOS) → rc 2.
#   Linux (precisa de nice, chrt e timeout, como o governo): `gt-iso-run` que não roda nada → rc 1 NAO-PROVADO · `gt-iso-run` que tira o sleep da sessão do item (como um sudo com pty faria) → rc 1 e o sleep
#     de fora CONTINUA VIVO (o incidente de 24/10: a limpeza antiga matava todo `sleep` do nó) · `gt-iso-run` na mesma sessão e sem helper root → rc 1 sem PROOF_ALLOW_NO_HELPER, rc 3 PARCIAL com ele
#     (nunca 0), e nos dois a sessão esvazia depois do SIGKILL e do TERM+CONT.
# CONTROLE NEGATIVO: cada mutante (um trecho do script trocado) TEM que reprovar a bateria. O mutante "limpeza que alcança fora da sessão" é limitado aos pids do próprio teste (arquivo de pids): um
#   mutante que mata por NOME de comando mataria `sleep` alheio no host que roda o teste, que é o incidente que este arquivo existe para impedir.
# VARIÁVEIS: HSP_UNDER_TEST (script a testar) · HSP_PY (padrão /usr/bin/python3) · HSP_NO_MUTANTS=1 · HSP_MUTANT (interno)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${HSP_UNDER_TEST:-$HERE/hetzner-ballast-signal-proof.py}"
PY="${HSP_PY:-/usr/bin/python3}"
T=$(cd "$(mktemp -d /tmp/hsp.XXXXXX)" && pwd -P)
PIDS="$T/outside.pids"; : > "$PIDS"
# reap — mata SÓ os pids que o próprio teste deixou de propósito fora da sessão (arquivo de pids); nunca por nome de comando
reap() { local p; for p in $(cat "$PIDS" 2> /dev/null); do kill -KILL "$p" 2> /dev/null; done; : > "$PIDS"; }
cleanup() { reap; rm -rf "$T"; }
trap cleanup EXIT
trap 'exit 143' TERM INT HUP
fails=0; n=0
ok() {  # no modo mutante, a primeira falha encerra (só interessa se a bateria reprova)
  n=$((n+1))
  if [ "$1" = 0 ]; then [ -n "${HSP_MUTANT:-}" ] || echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); [ -z "${HSP_MUTANT:-}" ] || { echo "RESULT $fails/$n"; exit 1; }; fi
}
check() { if [ "$2" = "$3" ]; then ok 0 "$1"; else ok 1 "$1 (esperado '$2', veio '$3')"; fi; }

# run_proof VAR=valor… → $OUT (stdout+stderr), $RC. O limite de espera do sleep é curto (2 s): nada aqui depende do nó.
run_proof() { OUT=$(env HSP_PIDS="$PIDS" HSP_PY="$PY" PROOF_APPEAR_S=2 "$@" "$PY" -I "$SCRIPT" 2>&1); RC=$?; }
cnt() { printf '%s\n' "$OUT" | grep -c -- "$1"; }
alive_outside() {  # quantos dos pids deixados fora da sessão ainda vivem
  local p c=0; for p in $(cat "$PIDS" 2> /dev/null); do kill -0 "$p" 2> /dev/null && c=$((c+1)); done; echo "$c"
}

# linux_ok — os casos de Linux só rodam onde o governo rodaria: /proc, nice, chrt e timeout no PATH, e sem ser root. Diz o motivo do skip em $WHY. A bateria e o laço de mutantes usam a MESMA função.
linux_ok() {
  WHY=""
  [ -d /proc/self ] || { WHY="sem /proc neste host"; return 1; }
  local c; for c in nice chrt timeout; do command -v "$c" > /dev/null 2>&1 || { WHY="falta $c no PATH (o governo também precisa dele)"; return 1; }; done
  [ "$(id -u)" != 0 ] || { WHY="rodando como root: o sleep de brinquedo seria root e o script, com razão, reprovaria"; return 1; }
  return 0
}

mkiso() {  # mkiso NOME CORPO — um gt-iso-run de brinquedo: recebe `-- cmd…`; o corpo roda depois de tirar o `--`
  printf '#!/bin/sh\n[ "$1" = -- ] && shift\n%s\n' "$2" > "$T/$1"; chmod +x "$T/$1"
}

battery() {
  "$PY" -I -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$SCRIPT" 2> /dev/null; check "sintaxe do script" "0" "$?"
  run_proof PROOF_ISO="$T/nao-existe"
  check "sem gt-iso-run → rc 2 e 'PROVA: NAO-MEDI' (não consegui medir nunca vira provado)" "2 1 0" "$RC $(cnt '^PROVA: NAO-MEDI: falta ') $(cnt '^PROVA: PROVADO')"
  if [ ! -d /proc/self ]; then
    mkiso iso.noop 'exit 0'
    run_proof PROOF_ISO="$T/iso.noop"
    check "sem /proc (este host não é Linux) → rc 2 'não consegui ler o /proc'" "2 1" "$RC $(cnt 'NAO-MEDI: não consegui ler o /proc')"
    echo "skip casos de Linux (sem /proc neste host): rode no nó com scripts/mbp-run.sh --repo hq"
    return 0
  fi
  linux_ok || { echo "skip casos de Linux ($WHY)"; return 0; }

  # o gt-iso-run não roda nada: o sleep nunca aparece
  mkiso iso.noop 'exit 0'
  run_proof PROOF_ISO="$T/iso.noop"
  check "o sleep nunca aparece na sessão → rc 1 NAO-PROVADO (2 problemas, um por rodada), sem 'FORA da sessão'" "1 1 2 0" "$RC $(cnt '^PROVA: NAO-PROVADO') $(cnt '^PROBLEMA: .*o sleep não está na sessão') $(cnt 'FORA da sessão')"

  # o comando sai da sessão do item (sudo com pty): a prova não pode dar certo NEM tocar no que está fora
  : > "$PIDS"
  mkiso iso.newsid 'echo $$ >> "$HSP_PIDS"
exec "$HSP_PY" -I -c "import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])" "$@"'
  run_proof PROOF_ISO="$T/iso.newsid"
  check "sleep FORA da sessão do item → rc 1 NAO-PROVADO e o script diz que viu 1 sleep fora em cada rodada" "1 1 2" "$RC $(cnt '^PROVA: NAO-PROVADO') $(cnt 'FORA da sessão (não toquei)')"
  check "e os 2 sleeps de fora (pids do teste) seguem VIVOS: a prova só toca na própria sessão (incidente de 24/10)" "2" "$(alive_outside)"
  reap

  # mesma sessão, sem helper root: o resto da cadeia (SIGSTOP, SIGKILL, TERM+CONT) roda de verdade
  mkiso iso.same 'exec "$@"'
  run_proof PROOF_ISO="$T/iso.same"
  check "sem o bash root do helper e sem a variável → rc 1 NAO-PROVADO (2 problemas) — falta de helper nunca é prova" "1 1 2" "$RC $(cnt '^PROVA: NAO-PROVADO') $(cnt '^PROBLEMA: .*não achei o bash root do helper')"
  check "mesmo assim o SIGSTOP parou tudo e as duas sessões esvaziaram (nenhum problema de 'NÃO esvaziou' ou de 'SIGSTOP não parou')" "0 0" "$(cnt 'NÃO esvaziou') $(cnt 'SIGSTOP não parou')"
  run_proof PROOF_ISO="$T/iso.same" PROOF_ALLOW_NO_HELPER=1
  check "com PROOF_ALLOW_NO_HELPER=1 → rc 3 PARCIAL, nunca 0, e nenhum PROVADO nem PROBLEMA" "3 1 0 0" "$RC $(cnt '^PROVA: PARCIAL') $(cnt '^PROVA: PROVADO') $(cnt '^PROBLEMA')"
  check "as duas rodadas terminaram com a sessão vazia (SIGKILL com o grupo parado; TERM+CONT)" "2" "$(cnt '^  (sessão vazia)')"
}

if [ -n "${HSP_MUTANT:-}" ]; then battery; echo "RESULT $fails/$n"; [ "$fails" = 0 ]; exit $?; fi
battery

[ -n "${HSP_NO_MUTANTS:-}" ] || {
  echo "── controle negativo: cada mutante tem que reprovar a bateria ──"
  # DESCRIÇÃO@@ANTES@@DEPOIS — troca EXATAMENTE uma ocorrência numa cópia do script. "[linux]" = só é pego onde a bateria roda os casos de Linux.
  cat > "$T/mutants.txt" <<'MUT'
[linux]a limpeza alcança processos fora da sessão (limitado aos pids do teste; por NOME mataria sleep alheio)@@        left = members(leader)
        if left:
            send(leader, [r["pid"] for r in left], signal.SIGKILL)@@        left = members(leader) + [r for r in table() if str(r["pid"]) in open(os.environ["HSP_PIDS"]).read().split()]
        if left:
            send(leader, [r["pid"] for r in left], signal.SIGKILL)
[linux]sleep que não aparece na sessão deixa de ser tratado (cai no índice [0])@@        if not until(lambda: bool(sleeper_of(leader, dur)), APPEAR_S):@@        if False:
falta do gt-iso-run sai 0@@        say("PROVA: NAO-MEDI: falta %s" % ISO)
        return 2@@        say("PROVA: NAO-MEDI: falta %s" % ISO)
        return 0
[linux]o veredito PARCIAL sai 0@@",".join(partial))
        return 3@@",".join(partial))
        return 0
MUT
  "$PY" -I - "$SCRIPT" "$T/mutants.txt" "$T" > "$T/mutants.idx" <<'PYEOF'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
entries, cur = [], None
for line in open(sys.argv[2], encoding="utf-8").read().split("\n"):
    if cur is None or (cur.count("@@") >= 2 and re.match(r"^[^@\s][^@]*@@", line)):
        if cur is not None:
            entries.append(cur)
        cur = line
    else:
        cur += "\n" + line
if cur:
    entries.append(cur)
for i, e in enumerate(entries, 1):
    parts = e.split("@@")
    if len(parts) != 3 or src.count(parts[1]) != 1:
        print("%d\tBAD\t%s" % (i, parts[0][:90])); continue
    mut = src.replace(parts[1], parts[2].rstrip("\n"))
    try:
        compile(mut, "mutante", "exec")   # mutante que nem compila "reprova" pelo motivo errado
    except SyntaxError:
        print("%d\tBAD\t%s (não compila)" % (i, parts[0][:90])); continue
    open("%s/mut%d.py" % (sys.argv[3], i), "w", encoding="utf-8").write(mut)
    print("%d\tOK\t%s" % (i, parts[0]))
PYEOF
  linux_ok && linux=1 || linux=0
  while IFS="$(printf '\t')" read -r idx st desc; do
    if [ "$st" != OK ]; then ok 1 "mutante '$desc': a âncora não casa exatamente 1 vez (o script mudou?)"; continue; fi
    case "$desc" in "[linux]"*) [ "$linux" = 1 ] || { echo "skip mutante '$desc' (a bateria deste host não roda os casos de Linux: $WHY)"; continue; } ;; esac
    r=$(HSP_MUTANT=1 HSP_UNDER_TEST="$T/mut$idx.py" bash "$0" 2>&1 | tail -n 1)
    reap
    case "$r" in "RESULT 0/"*) ok 1 "mutante '$desc' NÃO foi pego ($r)" ;; "RESULT "*) ok 0 "mutante '$desc' pego ($r)" ;; *) ok 1 "mutante '$desc': sem resultado ($r)" ;; esac
  done < "$T/mutants.idx"
}
echo "── $((n - fails))/$n ok"
[ "$fails" = 0 ]
