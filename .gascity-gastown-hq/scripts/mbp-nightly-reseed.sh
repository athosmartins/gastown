#!/usr/bin/env bash
# mbp-nightly-reseed.sh — reseed noturno da árvore-base e do site-packages do MBP, com veredito (ga-wuwuk7, épico ga-sokx7u).
#
# Contents
#   Por quê · Veredito · Quando roda · O que NÃO faz · Ambiente
#
# POR QUÊ: a árvore-base (~/gt-remote/whatsapp_automation, property_scrapers) e o site-packages do MBP envelhecem em
#   relação ao mini; teste que roda lá sobre base velha passa ou falha por motivo que o mini não tem. `mbp-run.sh --seed`
#   já faz o trabalho (rsync --delete da base; site-packages só recopia quando o hash dos dist-info muda). Este wrapper
#   só põe um veredito em volta, para rodar sem ninguém olhando.
#
# VEREDITO (última linha do stdout: `VEREDITO: <x>`; uma linha jsonl por execução em $CITY/.gc/logs/mbp-nightly-reseed.jsonl)
#   OK      os dois repos (wa e ps) semearam com rc 0 (o texto do mbp-run diz se o site-packages já batia ou foi recopiado)
#   FALHOU  algum repo saiu com rc != 0 ou estourou o prazo -> UM notify (prio 4) nomeando o repo, o rc e o que o rc quer dizer;
#           o outro repo roda mesmo assim; exit 1. rc 98 (MBP indisponível/sem saúde) conta como FALHOU: a base envelheceu e
#           alguém precisa saber, mesmo que a causa seja o MBP dormindo. Também é FALHOU, sem semear nada, o que impede de
#           SABER se pode rodar: não conseguir olhar a chave ($CITY/.gc inacessível), criar/tomar/remover o lock ou gravar
#           o dono dele, ou medir um lock sem pid.
#   PULADO  nada foi tentado, por escolha, com evidência positiva: chave desligada (falta $CITY/.gc/mbp-offload.on com
#           $CITY/.gc acessível), dreno do reboot vivo, ou outro reseed em andamento (lock com pid vivo, ou lock sem pid criado
#           há menos de LOCK_FRESCO_S). Sem notify, exit 0. PULADO nunca é dito para o que falhou ou para o que não se
#           pôde ler. Dreno com "até" implausível e lock com mais de 2 prazos de idade não pulam: avisam (WARN) e seguem,
#           para que um arquivo podre não vire noite perdida muda.
#
# QUANDO RODA: launchd (scripts/com.gascity.mbp-nightly-reseed.plist), 05:50. Depois do que pesa o mini entre 04:47 e 05:37
#   (restic backup/check/restore-test), antes do lotes-rebuild das 06:30; longe do reboot noturno (LaunchDaemon 23:00, dreno
#   23:00-00:30). O guard de dreno existe para rodada manual feita dentro dessa janela.
#
# O QUE NÃO FAZ: não decide saúde do MBP (isso é o preflight do mbp-run.sh), não mexe na chave, não toca em slot nem em
#   espelho de teste em andamento (reseed com teste rodando no MBP e hash novo pode atrapalhar o teste; às 05:50 não há).
#
# AMBIENTE (para o selftest e para rodada manual): MBP_CITY, MBP_RESEED_RUN (mbp-run.sh), MBP_RESEED_NOTIFY,
#   MBP_RESEED_DRAIN_FILE, MBP_RESEED_TIMEOUT_S (por repo, padrão 1800), MBP_RESEED_REPOS (padrão "wa ps").
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CITY=${MBP_CITY:-${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}}   # mesma derivação do mbp-run.sh: a chave que ele lê é a que checamos
RUN=${MBP_RESEED_RUN:-$HERE/mbp-run.sh}
NOTIFY=${MBP_RESEED_NOTIFY:-$HOME/.local/bin/notify}
DRAIN_FILE=${MBP_RESEED_DRAIN_FILE:-$HOME/.gastown/run/city-drain.level}
TIMEOUT_S=${MBP_RESEED_TIMEOUT_S:-1800}
REPOS=${MBP_RESEED_REPOS:-"wa ps"}
FLAG="$CITY/.gc/mbp-offload.on"
LOG="$CITY/.gc/logs/mbp-nightly-reseed.jsonl"
LOCK="$CITY/.gc/mbp-nightly-reseed.lock"
TO=$(command -v timeout || command -v gtimeout || true)

say() { printf '%s mbp-nightly-reseed: %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*"; }
T0=$(date +%s)

record() { # verdict reason [repo=verdict:rc ...]  -> uma linha jsonl; falha de escrita nunca muda o veredito
  local v=$1 reason=$2; shift 2
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg v "$v" --arg reason "$reason" --argjson secs "$(( $(date +%s) - T0 ))" \
     --arg repos "$*" '{ts:$ts,verdict:$v,reason:$reason,secs:$secs,repos:$repos}' >> "$LOG" 2>/dev/null || say "WARN: não consegui gravar $LOG"
}

skip() { # motivo
  say "PULADO — $1"; record PULADO "$1"; say "VEREDITO: PULADO"; exit 0
}

falhou() { # detalhe [resumo]  -> jsonl + UM notify (prio 4) + exit 1; o único caminho de FALHOU, do laço de repos ou de antes dele
  local detail=${1# } msg
  say "FALHOU — $detail"
  record FALHOU "$detail" "${2:-}"
  msg="Reseed noturno do MBP FALHOU: ${detail}. A base/site-packages do MBP pode estar velha. Veredito e log: $LOG. Rodar à mão: scripts/mbp-run.sh --seed <wa|ps>."
  if [ -x "$NOTIFY" ]; then "$NOTIFY" -t "MBP reseed noturno FALHOU" -p 4 "$msg" >/dev/null 2>&1 || say "WARN: notify saiu com erro — a falha acima NÃO chegou ao Athos"
  else say "WARN: $NOTIFY ausente — a falha acima NÃO chegou ao Athos"; fi
  say "VEREDITO: FALHOU"; exit 1
}

# ---- PULADO por escolha ------------------------------------------------------------------------------------------
# Chave ausente é escolha, mas só se deu para olhar: sem poder entrar em $CITY/.gc não se sabe se a chave está ligada, e
# "não sei" não pode virar "desligada" (noite sem reseed, em silêncio, para sempre).
[ -f "$FLAG" ] || { [ -d "$CITY/.gc" ] && [ -x "$CITY/.gc" ]; } || falhou "não consegui olhar a chave $FLAG ($CITY/.gc ausente ou sem permissão de acesso)"
[ -f "$FLAG" ] || skip "offload desligado (falta $FLAG)"

# dreno do reboot: arquivo de 4 linhas DRAIN|escrito|boot|até (nightly-reboot.sh). Vivo = linha 4 no futuro.
# Ausente ou vencido = livre. Presente e ilegível = não dá para saber: segue (o dano de semear durante o dreno é pequeno,
# e uma trava silenciosa para sempre seria pior), mas diz. Idem "até" além de DRAIN_PLAUSIVEL_S (o dreno dura ~90 min):
# um valor corrompido no futuro pularia toda noite em silêncio.
DRAIN_PLAUSIVEL_S=21600
if [ -e "$DRAIN_FILE" ]; then
  until_ts=$(sed -n 4p "$DRAIN_FILE" 2>/dev/null)
  case "$until_ts" in
    ''|*[!0-9]*) say "WARN: sinal de dreno $DRAIN_FILE ilegível — seguindo" ;;
    *) now=$(date +%s)
       if [ "$until_ts" -le "$now" ]; then :
       elif [ $(( until_ts - now )) -gt "$DRAIN_PLAUSIVEL_S" ]; then say "WARN: sinal de dreno $DRAIN_FILE vai até $(date -r "$until_ts" +%Y-%m-%dT%H:%M), além do plausível (${DRAIN_PLAUSIVEL_S}s) — seguindo"
       else skip "dreno do reboot vivo (até $(date -r "$until_ts" +%H:%M))"; fi ;;
  esac
fi

# instância única: dois rsync --delete na mesma base se pisam. Só se pula com evidência POSITIVA de outro reseed vivo (lock
# com pid vivo, ou lock sem pid criado há menos de LOCK_FRESCO_S: o dono acabou de criar e ainda não gravou o pid). O mkdir
# falhar não é essa evidência: "já existe" é só um dos motivos (permissão, disco cheio e FS só-leitura também falham e não
# deixam lock nenhum), então depois da falha olha-se se o lock existe. Dono morto = lock velho, toma. Lock mais velho que
# LOCK_VELHO_MIN é velho mesmo com o pid vivo (o pid pode ter sido reaproveitado por outro processo; uma rodada dura no
# máximo ~2 x TIMEOUT_S): sem esse teto, um lock órfão pularia toda noite em silêncio. O que não dá para criar, remover,
# gravar, medir ou saber se o dono vive é FALHOU, nunca PULADO.
LOCK_VELHO_MIN=$(( (2 * TIMEOUT_S) / 60 + 30 ))
LOCK_FRESCO_S=60

lock_age() { # segundos desde a última modificação do lock; rc 1 = não deu para medir (nunca um número inventado)
  local m a; m=$(stat -f %m "$LOCK" 2>/dev/null) || return 1
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  a=$(( $(date +%s) - m ))
  [ "$a" -ge 0 ] || return 1   # mtime no futuro (relógio voltou): idade que não existe não vale como "recente"
  echo "$a"
}

pid_vivo() { # pid -> rc 0 vivo, 1 morto, 2 não deu para saber. kill -0 falha tanto por "não existe" quanto por "não é seu": só o primeiro é morto
  local e; e=$(kill -0 "$1" 2>&1) && return 0
  case "$e" in
    *"No such process"*) return 1 ;;
    *"not permitted"*) return 0 ;;
  esac
  return 2
}

lock_err=$(mkdir -p "$(dirname "$LOCK")" 2>&1) || falhou "não consegui criar $(dirname "$LOCK"): ${lock_err:-sem mensagem}"
sem_lock=0; tomadas=0
while ! lock_err=$(mkdir "$LOCK" 2>&1); do
  if [ ! -d "$LOCK" ]; then
    # Sem lock depois do mkdir falhar: não há outro reseed para esperar. Uma segunda tentativa cobre o dono que soltou o lock
    # entre o nosso mkdir e este teste; falhando de novo, o mkdir tem um motivo que não é "já existe".
    sem_lock=$((sem_lock + 1))
    [ "$sem_lock" -ge 2 ] && falhou "não consegui criar o lock $LOCK: ${lock_err:-sem mensagem}"
    continue
  fi
  tomadas=$((tomadas + 1))
  [ "$tomadas" -gt 3 ] && falhou "lock $LOCK disputado: tomado e reocupado ${tomadas} vezes seguidas"
  owner=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$owner" ] && ! [[ $owner =~ ^[1-9][0-9]{0,6}$ ]]; then
    say "WARN: pid do lock $LOCK ilegível ('$owner') — tratando como lock sem dono"; owner=""
  fi
  age=$(lock_age) || age=""
  alive=1; [ -z "$owner" ] || { pid_vivo "$owner"; alive=$?; }
  if [ -n "$age" ] && [ "$age" -gt $(( LOCK_VELHO_MIN * 60 )) ]; then
    say "WARN: lock $LOCK com mais de ${LOCK_VELHO_MIN} min (dono pid ${owner:-?}) — tratando como velho e tomando"
  elif [ "$alive" -eq 0 ]; then
    skip "outro reseed em andamento (pid $owner)"
  elif [ "$alive" -eq 2 ]; then
    falhou "não consegui saber se o dono do lock $LOCK (pid $owner) está vivo"
  elif [ -z "$owner" ] && [ -z "$age" ]; then
    falhou "não consegui avaliar o lock $LOCK (sem pid legível e sem idade): não dá para saber se há outro reseed"
  elif [ -z "$owner" ] && [ "$age" -le "$LOCK_FRESCO_S" ]; then
    skip "outro reseed começando (lock $LOCK sem pid há ${age}s)"
  fi
  # dono morto, ou lock velho, ou sem dono há mais de LOCK_FRESCO_S: tira e deixa o mkdir do laço tomar de novo
  rm -f "$LOCK/pid" 2>/dev/null
  lock_err=$(rmdir "$LOCK" 2>&1) || [ ! -d "$LOCK" ] || falhou "não consegui remover o lock velho $LOCK (dono pid ${owner:-?}): ${lock_err:-sem mensagem}"
done
if ! { echo $$ > "$LOCK/pid"; } 2>/dev/null; then   # lock sem dono gravado deixaria uma segunda rodada pisar nesta
  rm -f "$LOCK/pid" 2>/dev/null; rmdir "$LOCK" 2>/dev/null
  falhou "peguei o lock $LOCK mas não consegui gravar o pid do dono"
fi
trap 'rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null' EXIT
trap 'exit 143' TERM INT HUP

[ -n "$TO" ] || say "WARN: sem timeout/gtimeout no PATH — semeando sem prazo (ssh/rsync têm keepalive próprio)"

# ---- semeia cada repo; um repo falhar não impede o outro ----------------------------------------------------------
meaning() { # rc
  case "$1" in
    97) echo "configuração (uso errado, base ausente ou site-packages local não achado)" ;;
    98) echo "MBP indisponível/sem saúde (ssh, RAM, swap, bateria) ou ssh/rsync caiu no meio" ;;
    124|137) echo "estourou o prazo de ${TIMEOUT_S}s" ;;
    *) echo "rc inesperado" ;;
  esac
}

failed=""; summary=""; nok=0
for repo in $REPOS; do
  out=$(mktemp "${TMPDIR:-/tmp}/mbp-reseed.XXXXXX") || { failed="$failed $repo(sem tmp)"; summary="$summary $repo=FALHOU:-"; continue; }
  s0=$(date +%s)
  if [ -n "$TO" ]; then "$TO" -k 30 "$TIMEOUT_S" "$RUN" --seed "$repo" >"$out" 2>&1; rc=$?
  else "$RUN" --seed "$repo" >"$out" 2>&1; rc=$?; fi
  last=$(grep -v '^[[:space:]]*$' "$out" | tail -n 1)
  secs=$(( $(date +%s) - s0 ))
  if [ "$rc" -eq 0 ]; then
    say "$repo OK (${secs}s) — ${last:-sem saída}"; nok=$((nok+1)); summary="$summary $repo=OK:0"
  else
    say "$repo FALHOU rc=$rc (${secs}s) — $(meaning "$rc"): ${last:-sem saída}"
    failed="$failed $repo(rc=$rc: $(meaning "$rc"))"; summary="$summary $repo=FALHOU:$rc"
  fi
  rm -f "$out"
done
summary=${summary# }
[ "$nok" -gt 0 ] || [ -n "$failed" ] || failed=" nenhum repo para semear (MBP_RESEED_REPOS vazio)"   # nada semeado não é OK

[ -z "$failed" ] || falhou "$failed" "$summary"
record OK "" "$summary"
say "VEREDITO: OK"
exit 0
