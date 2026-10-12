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
#           alguém precisa saber, mesmo que a causa seja o MBP dormindo.
#   PULADO  nada foi tentado, por escolha: chave desligada (falta $CITY/.gc/mbp-offload.on), dreno do reboot vivo, ou outro
#           reseed em andamento. Sem notify, exit 0. PULADO nunca é dito para o que falhou. Dreno com "até" implausível e lock
#           com mais de 2 prazos de idade não pulam: avisam (WARN) e seguem, para que um arquivo podre não vire noite perdida muda.
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

# ---- PULADO por escolha ------------------------------------------------------------------------------------------
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

# instância única: dois rsync --delete na mesma base se pisam. Dono morto = lock velho, toma. Lock mais velho que
# LOCK_VELHO_MIN é velho mesmo com o pid vivo (o pid pode ter sido reaproveitado por outro processo; uma rodada dura no
# máximo ~2 x TIMEOUT_S): sem esse teto, um lock órfão pularia toda noite em silêncio.
LOCK_VELHO_MIN=$(( (2 * TIMEOUT_S) / 60 + 30 ))
mkdir -p "$(dirname "$LOCK")" 2>/dev/null
if ! mkdir "$LOCK" 2>/dev/null; then
  owner=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +"$LOCK_VELHO_MIN" 2>/dev/null)" ]; then
    say "WARN: lock $LOCK com mais de ${LOCK_VELHO_MIN} min (dono pid ${owner:-?}) — tratando como velho e tomando"
  elif { [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; } || { [ -z "$owner" ] && [ -z "$(find "$LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ]; }; then
    skip "outro reseed em andamento (pid ${owner:-?})"
  fi
  rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || skip "não consegui tomar o lock $LOCK"
fi
echo $$ > "$LOCK/pid"
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

if [ -n "$failed" ]; then
  record FALHOU "$failed" "$summary"
  msg="Reseed noturno do MBP FALHOU:${failed}. A base/site-packages do MBP pode estar velha. Veredito e log: $LOG. Rodar à mão: scripts/mbp-run.sh --seed <wa|ps>."
  if [ -x "$NOTIFY" ]; then "$NOTIFY" -t "MBP reseed noturno FALHOU" -p 4 "$msg" >/dev/null 2>&1 || say "WARN: notify saiu com erro — a falha acima NÃO chegou ao Athos"
  else say "WARN: $NOTIFY ausente — a falha acima NÃO chegou ao Athos"; fi
  say "VEREDITO: FALHOU"; exit 1
fi
record OK "" "$summary"
say "VEREDITO: OK"
exit 0
