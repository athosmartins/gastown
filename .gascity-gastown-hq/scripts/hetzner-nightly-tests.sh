#!/usr/bin/env bash
# hetzner-nightly-tests.sh — a suíte INTEIRA do WA no nó Linux (Hetzner), toda madrugada, em LOTES por arquivo, sem rede de saída e sem segredo, com relatório ao Mayor (ga-9p6pte, ga-84gkpab).
#
# ## Contents
#   Por quê · Lotes · Pistas · Veredito · Como roda · O que NÃO faz · Ambiente
#
# POR QUÊ: em 04/10 um teste de branch antiga mandou um e-mail de verdade. Rodar a suíte inteira toda noite só é aceitável com a saída de rede PROVADA
#   cortada (canário do hetzner-iso-run.sh + helper de root hetzner-netns-run.sh) e ambiente limpo. Sem essa prova nada roda.
# LOTES (ga-84gkpab): um pytest só com 14 workers sobre a árvore inteira (4614 arquivos, ~76 mil testes em origin/main de 15/11) cresce sem platô — cada worker nasce com ~2 GB (coleta tudo) e a soma passou
#   dos 31 GB do nó: o OOM do kernel matou o job com rc=137 aos ~1700 s em 13, 14 e 15/11. Agora: os arquivos test_*.py/*_test.py de tests/ (menos o que o pytest.ini manda ignorar) são
#   agrupados em ordem de caminho em lotes de ~HZN_BATCH_DEFS `def test_` (o nº de lotes sai da árvore, nunca fixo) e CADA lote é um `mbp-run.sh` + um pytest NOVO (a memória zera). Quem limita a
#   memória é o `gt-iso-run` no nó (hetzner-iso-run.sh): lê o MemAvailable na hora, deriva os workers (nunca um número fixo), roda o pytest dentro de
#   `systemd-run --user --scope -p MemoryMax=<teto> -p MemorySwapMax=0` e fica INERTE se não leu ou não provou o teto. O orçamento de tempo é do script inteiro: o MENOR entre HZN_TIMEOUT_S (contado do início) e o relógio HZN_STOP_UTC, menos a margem (ga-z6bc623): lote que
#   não começou por falta de orçamento, que estourou o prazo dele, que morreu (rc 137 = teto/OOM, worker caído) ou ficou inerte é "NÃO RODOU" e aparece assim — nunca como verde. Sem todos os
#   lotes rodados não há COMPLETO, não há total da suíte e a linha de base não anda; os lotes que rodaram ainda são comparados com a última noite COMPLETA, só nos arquivos deles, e o relatório diz
#   "comparação PARCIAL" (compare=parcial no jsonl) com o orçamento da noite e o ritmo medido.
# PISTAS (ga-282sl1d): até HZN_LANES (2) lotes rodam AO MESMO TEMPO. Medido em 22-24/11: o tempo do lote quase não depende dos workers (5 workers: 998 s; 14 workers: 1631 s) e cada lote gasta 30-450 s em overhead fixo
#   (rsync do espelho, canário, partida do pytest); a noite de 24/11 projetava ~14000 s de 11 lotes para uma janela de ~13200 s. Cada pista é um `gt-iso-run --lanes N` próprio (HETZNER_ISO_LANES do mbp-run): quem
#   impede que as pistas somem mais memória do que o nó tem é o registro de pistas do gt-iso-run (memória das outras, piso de memória e de CPU/PSI para a pista EXTRA; ver hetzner-iso-run.sh). Pista extra sem espaço
#   agora (rc 95) ESPERA HZN_LANE_WAIT_S e tenta de novo, sem gastar tentativa nem virar "NÃO RODOU"; pista extra que não consegue rodar por causa do nó (sem slot, ssh, canário, bandeira) devolve o lote à fila e
#   sai: a pista 1 (a de sempre) o pega, então a falha de uma pista extra não faz perder lote que a noite sem pistas teria rodado. Os lotes são tirados da fila em ordem; o resultado de cada um vai para $SCR/res.<n> e a leitura (soma, tabela,
#   comparação, relatório) acontece DEPOIS, na ordem dos lotes: nada do que o relatório diz mudou. Vazamento medido ou lote sem prova em QUALQUER pista para a fila e derruba as outras pistas. HZN_LANES=1 = o laço sequencial de antes.
# VEREDITO (última linha do stdout `VEREDITO: <x>`; uma linha jsonl por noite em $CITY/.gc/logs/hetzner-nightly.jsonl; um e-mail ao Mayor, salvo PULADO)
#   COMPLETO  TODOS os lotes rodaram DENTRO do isolamento provado e o resumo do pytest de cada um foi lido: total (somado), falhas, novas falhas contra a última noite COMPLETA, duração.
#             Teste que falha é dado do relatório, não falha do job (exit 0).
#   INERTE    o isolamento não foi provado (helper de root não instalado, canário `inerte`, wrapper ausente) ou o nó não deixou provar o teto de memória / ler o MemAvailable no 1º lote:
#             NADA rodou. Exit 0, e-mail diz o que falta.
#   FALHOU    o que impede de dizer o que aconteceu: nó fora, sync/guard recusado, lote que NÃO RODOU (orçamento, prazo do lote, rc 137, pytest abortado, worker caído, sem resumo, sem a
#             linha de prova do isolamento), total implausível, e `nao-isolado` do canário: a sonda SAIU pela rede, um vazamento MEDIDO (o assunto diz VAZAMENTO). Exit 1.
#   PULADO    por escolha, com evidência: bandeira do nó desligada (rc 99 do mbp-run no 1º lote) ou outra rodada em andamento. Sem e-mail, exit 0; a linha do jsonl sai mesmo assim (uma por noite).
# IDS REPROVADOS (a comparação com a noite anterior): vêm do PLUGIN gtn_stable_ids.py (`GTN-FAIL: <id em JSON>` por id e `GTN-FAILED: n=.. reports=..`), nunca da linha humana
#   `FAILED <id> - <msg>`: um id de parametrize pode ter " - " (`[ADE V - Setor 4]`) e o corte no primeiro " - " juntava irmãos numa linha só. Por LOTE o script confere a quantidade de linhas
#   com `n` e `reports` com o resumo do pytest do lote; qualquer divergência ou ausência em qualquer lote = comparação INDISPONÍVEL e a linha de base não anda (nunca "0 novas").
# COMO RODA: gc order (packs/town-deltas/orders/hetzner-nightly-tests.toml, 02:00 local = 05:00 UTC). `git archive origin/main` do WA (nada de WIP de agente, nada de untracked) para um scratch,
#   e por lote `HETZNER_ISOLATE=1 mbp-run.sh --host linux --repo wa -- <arquivos> -n auto -p gtn_stable_ids ...` (o filtro, o node_guard, o slot e a supervisão são os do gate, sem cópia;
#   `-n auto` só limita por cima: o `gt-iso-run` cobra do nó o número real de workers). O scratch é apagado.
# O QUE NÃO FAZ: não cai no MBP nem no mini (--host linux, sem cadeia); não decide se uma falha é regressão (só diz quais são novas); não instala o helper de root; não mexe no que roda no nó
#   além do próprio pytest (os diretórios velhos de /dev/shm do nó são de outro agente).
# AMBIENTE (selftest e rodada manual): MBP_CITY, HZN_RUN (mbp-run.sh), HZN_WA_REPO, HZN_MAIL_CMD (padrão `gc mail send mayor`), HZN_TIMEOUT_S (13500: o prazo do script todo, contado do início), HZN_STOP_UTC (08:45: hora UTC em que a rodada acaba, antes do reseed do nó das 08:55Z; vazio desliga; HZN_NOW_S só para o selftest), HZN_MIN_TOTAL (1000),
#   HZN_NODE_HOST (hetzner-teste; é também o que o mbp-run recebe como HETZNER_NODE_HOST: instalar e rodar no MESMO nó), HZN_SSH (ssh), HZN_NO_FETCH=1 (não buscar o origin),
#   HZN_KEEP_DAYS (14; a linha de base last-complete.* não entra na limpeza), HZN_BATCH_DEFS (8000: `def test_` por lote), HZN_BATCH_TIMEOUT_S (2400: prazo de UM lote),
#   HZN_MIN_BATCH_S (180: com menos orçamento que isto o lote nem começa), HZN_FINAL_MARGIN_S (300: o que fica para o relatório), HZN_BATCH_TRIES (2) e HZN_RETRY_S (90) para o que é transitório
#   (teto/MemAvailable inerte, sem slot, ssh/rsync caído), HZN_LANES (2: lotes ao mesmo tempo, 1 a 8; 1 = sequencial) e HZN_LANE_WAIT_S (120: espera da pista extra quando o nó não tem espaço para ela agora).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CITY=${MBP_CITY:-${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}}
RUN=${HZN_RUN:-$HERE/mbp-run.sh}
WA=${HZN_WA_REPO:-/Users/athos/gt/whatsapp_automation}
MAIL=${HZN_MAIL_CMD:-gc mail send mayor}
TIMEOUT_S=${HZN_TIMEOUT_S:-13500}
COMM=${HZN_COMM:-comm}   # só o selftest troca (para injetar a falha da comparação parcial)
STOP_UTC=${HZN_STOP_UTC-08:45}   # hora UTC (HH:MM) em que a rodada TEM de acabar (o reseed do nó é 08:55Z); vazio = só o prazo TIMEOUT_S vale
MIN_TOTAL=${HZN_MIN_TOTAL:-1000}
NODE=${HZN_NODE_HOST:-${HETZNER_NODE_HOST:-hetzner-teste}}
SSH=${HZN_SSH:-ssh}
LOGDIR="$CITY/.gc/logs/hetzner-nightly"
JSONL="$CITY/.gc/logs/hetzner-nightly.jsonl"
LOCK="$CITY/.gc/hetzner-nightly.lock"
PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH
DAY=$(date +%Y-%m-%d)
T0=$(date +%s)
say() { printf '%s hetzner-nightly: %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*"; }
SCR=""; OUT="$LOGDIR/$DAY.out"; REPORT="$LOGDIR/$DAY.md"
LANE_PIDS=""
cleanup() { [ -z "$LANE_PIDS" ] || kill_lanes 2>/dev/null; [ -z "$SCR" ] || find "$SCR" -mindepth 1 -delete 2>/dev/null; [ -z "$SCR" ] || rmdir "$SCR" 2>/dev/null; [ ! -f "$LOCK/pid" ] || [ "$(cat "$LOCK/pid" 2>/dev/null)" != "$$" ] || { rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null; }; return 0; }
trap cleanup EXIT
trap 'exit 143' TERM INT HUP   # o kill da ordem (prazo) também passa pelo cleanup: as pistas e o scratch não ficam para trás
mkdir -p "$LOGDIR" 2>/dev/null || { say "FALHOU — não consegui criar $LOGDIR"; exit 1; }

LANES=1; NWAITS=0   # as pistas da rodada (validadas mais abaixo; até lá, 1) e quantas vezes uma pista esperou o nó ter espaço
SHA="?"; ISO_LINE=""; EGRESS="?"; MAILRC=0; FETCHST="?"; CMPST="-"; STALE_NOTE=""; DEPLOY=""; NB=0; NRAN=0; NSKIP=0; NMAC=0; NHELD=0; NHF=0; NHP=0; ESCSUM=0; ESCUNK=0
jline() { # veredito motivo — a linha do jsonl desta noite (também a das noites PULADAS por lock: uma por noite)
  local escj=null   # escudo: nenhum lote rodou ou a linha GTN-ESCUDO de algum lote veio ilegível → null (não afirmo 0 sem ter lido)
  [ "$ESCUNK" = 0 ] && [ "$NRAN" -gt 0 ] && escj=$ESCSUM
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg v "$1" --arg why "$2" --arg sha "$SHA" --arg iso "$ISO_LINE" --arg egress "$EGRESS" --arg fetch "$FETCHST" --arg cmp "$CMPST" \
     --argjson wall "$(( $(date +%s) - T0 ))" --argjson mailrc "$MAILRC" --argjson nb "$NB" --argjson nr "$NRAN" --argjson ns "$NSKIP" --argjson nm "$NMAC" --argjson nh "$NHELD" --argjson esc "$escj" --argjson lanes "$LANES" --argjson waits "$NWAITS" \
     '{ts:$ts,verdict:$v,reason:$why,sha:$sha,isolation:$iso,egress_attempts:$egress,fetch:$fetch,compare:$cmp,wall_s:$wall,mail_failed:$mailrc,batches:$nb,batches_ran:$nr,batches_skipped:$ns,mac_only_excluded:$nm,node_held_excluded:$nh,escudo_reports:$esc,lanes:$lanes,lane_waits:$waits}' >> "$JSONL" 2>/dev/null \
     || say "WARN: não gravei $JSONL"
}
finish() { # veredito motivo [exit] — grava o relatório, o jsonl, manda o e-mail (salvo PULADO) e sai
  local v=$1 why=$2 rcx=${3:-0} subj
  [ -s "$REPORT" ] || printf '# Hetzner nightly %s — %s\n\n%s\n' "$DAY" "$v" "$why" > "$REPORT"
  subj="[hetzner-nightly] $DAY $v: $why"
  if [ "$v" != PULADO ]; then
    # vazio/falhou (o comando de e-mail não existe ou recusou) → o relatório fica no disco, o jsonl diz mail=falhou e o exit vira 1: ninguém acha que o Mayor foi avisado
    # shellcheck disable=SC2086
    $MAIL -s "$subj" -m "$(cat "$REPORT")" >/dev/null 2>&1 || { MAILRC=1; say "WARN: e-mail ao Mayor falhou (relatório em $REPORT)"; [ "$rcx" -ne 0 ] || rcx=1; }
  fi
  jline "$v" "$why"
  # a linha de base (last-complete.*) fica: apagada depois de 14 dias sem noite COMPLETA, a próxima diria "primeira rodada" sem ser verdade
  find "$LOGDIR" -type f ! -name 'last-complete.*' -mtime +"${HZN_KEEP_DAYS:-14}" -delete 2>/dev/null
  say "$subj"; say "VEREDITO: $v"; exit "$rcx"
}

# lock: vazio (sem pasta) → toma; pid vivo E lock recente → PULADO (com a linha do jsonl); pid morto, ilegível ou lock mais velho que prazo + margem → dono morreu no meio (ou o pid foi
# reaproveitado depois de uma queda), toma de novo: uma noite perdida muda é pior que um lock velho. Um dono legítimo morre pelo prazo (TIMEOUT_S), então "mais velho que isso" nunca é rodada em andamento.
# falhou/ilegível (a idade do lock não pôde ser lida) → conta como recente: fica PULADO, mas PULADO deixa linha no jsonl toda noite, não silêncio.
LOCK_STALE_MIN=$(( (TIMEOUT_S + 1800) / 60 ))
if ! mkdir "$LOCK" 2>/dev/null; then
  op=$(cat "$LOCK/pid" 2>/dev/null)
  case "$op" in ''|*[!0-9]*) op="" ;; esac
  old=""; [ -z "$(find "$LOCK" -maxdepth 0 -mmin +"$LOCK_STALE_MIN" 2>/dev/null)" ] || old=" e lock com mais de ${LOCK_STALE_MIN} min"
  if [ -n "$op" ] && [ -z "$old" ] && kill -0 "$op" 2>/dev/null; then
    jline PULADO "outra rodada em andamento (pid $op)"; say "PULADO — outra rodada em andamento (pid $op)"; say "VEREDITO: PULADO"; exit 0
  fi
  say "WARN: lock sem dono vivo (pid '${op:-ilegível}'$old): tomando"
fi
echo $$ > "$LOCK/pid" 2>/dev/null || finish FALHOU "não consegui gravar o dono do lock em $LOCK" 1
touch "$LOCK" 2>/dev/null   # reescrever o pid não muda o mtime da pasta: sem isto um lock tomado de um velho continuaria "velho" para a rodada seguinte
: > "$REPORT"   # o relatório de hoje começa vazio: um relatório de rodada anterior do mesmo dia nunca vira o e-mail desta

# o que vai ao nó: origin/main do WA, só o versionado. falhou o fetch → segue com o origin/main que o clone já tem (o sha vai no relatório); sem origin/main legível → FALHOU
# o relatório e o jsonl dizem quando o fetch falhou (a árvore pode estar velha) ou foi pulado; "ok" só quando o fetch rodou e voltou 0
if [ "${HZN_NO_FETCH:-0}" = 1 ]; then FETCHST=pulado
elif timeout 120 git -C "$WA" fetch -q origin main 2>/dev/null; then FETCHST=ok
else FETCHST=falhou; STALE_NOTE="git fetch origin main FALHOU: a árvore testada é o origin/main que o clone já tinha e pode estar desatualizada"; say "WARN: $STALE_NOTE"
fi
# vazio/falhou (rev-parse não devolve sha) → FALHOU, nada é enviado
SHA=$(git -C "$WA" rev-parse --verify -q origin/main 2>/dev/null | cut -c1-9); [ -n "$SHA" ] || finish FALHOU "origin/main do WA ilegível em $WA" 1
mkdir -p "$CITY/.gc/run" 2>/dev/null; SCR=$(mktemp -d "$CITY/.gc/run/hetzner-nightly.XXXXXX") || finish FALHOU "não criei o scratch em $CITY/.gc/run" 1
mkdir "$SCR/whatsapp_automation" && git -C "$WA" archive origin/main | tar -x -C "$SCR/whatsapp_automation" || finish FALHOU "git archive origin/main falhou" 1

# o wrapper do canário e o plugin de ids vão ao nó a cada noite (o helper de root é do root; estes dois são nossos e ficam iguais aos do repo). Falhou o ssh/cat → o nó não foi alcançado.
# Vão do $HERE (a árvore de trabalho, compartilhada): uma edição não commitada de outra sessão iria junto. Por isso o relatório diz o sha de cada um e se está commitado
# (vazio → não existe; falhou/ilegível o git → "estado git ilegível", nunca "commitado").
prov() { # arquivo → "sha256:<12> (commitado|NÃO COMMITADO ...|estado git ilegível)"
  local f=$1 h st
  h=$(shasum -a 256 "$f" 2>/dev/null | cut -c1-12); [ -n "$h" ] || h="?"
  if ! git -C "$HERE" ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then st="estado git ilegível ou arquivo fora do git"
  elif git -C "$HERE" diff --quiet HEAD -- "$f" 2>/dev/null; then st=commitado
  else case $? in 1) st="NÃO COMMITADO: a edição local foi ao nó" ;; *) st="estado git ilegível" ;; esac; fi
  printf 'sha256:%s (%s)' "$h" "$st"
}
for f in hetzner-iso-run.sh:gt-iso-run gtn_stable_ids.py:gtn_stable_ids.py; do
  DEPLOY="$DEPLOY${DEPLOY:+; }${f#*:} $(prov "$HERE/${f%%:*}")"
  if ! $SSH -o BatchMode=yes -o ConnectTimeout=20 "$NODE" "mkdir -p ~/gt-remote/bin && cat > ~/gt-remote/bin/.${f#*:}.new && chmod 755 ~/gt-remote/bin/.${f#*:}.new && mv -f ~/gt-remote/bin/.${f#*:}.new ~/gt-remote/bin/${f#*:}" < "$HERE/${f%%:*}" 2>/dev/null; then
    finish FALHOU "não consegui instalar ${f#*:} em $NODE (nó inalcançável?)" 1
  fi
done

# ── constantes: inteiro ou nada (vazio/ilegível → FALHOU, nunca um padrão escolhido por mim às cegas) ─────────────────────────────────────────────────────────────────────────────────────
BATCH_DEFS=${HZN_BATCH_DEFS:-8000}; BATCH_T=${HZN_BATCH_TIMEOUT_S:-2400}; MIN_BATCH=${HZN_MIN_BATCH_S:-180}; MARGIN=${HZN_FINAL_MARGIN_S:-300}
TRIES=${HZN_BATCH_TRIES:-2}; RETRY_S=${HZN_RETRY_S:-90}; ARGS_MAX=${HZN_BATCH_ARGS_MAX:-60000}; LANES_REQ=${HZN_LANES:-2}; LANE_WAIT=${HZN_LANE_WAIT_S:-120}
for v in TIMEOUT_S MIN_TOTAL BATCH_DEFS BATCH_T MIN_BATCH MARGIN TRIES RETRY_S ARGS_MAX LANES_REQ LANE_WAIT; do
  x=${!v}; case "$x" in ''|*[!0-9]*) finish FALHOU "constante inválida: $v='$x' (precisa ser inteiro >= 0); nada rodou" 1 ;; esac
done
for v in BATCH_DEFS BATCH_T TRIES ARGS_MAX LANES_REQ; do x=${!v}; [ "$x" -ge 1 ] || finish FALHOU "constante inválida: $v=$x (precisa ser >= 1); nada rodou" 1; done
[ "$LANES_REQ" -le 8 ] || finish FALHOU "constante inválida: HZN_LANES=$LANES_REQ (precisa ser de 1 a 8); nada rodou" 1
LANES=$LANES_REQ; ISOLANES=""; [ "$LANES" -le 1 ] || ISOLANES=$LANES   # o mbp-run só recebe HETZNER_ISO_LANES com 2 ou mais: com 1 pista a chamada é a de sempre
# vazio é VÁLIDO (desliga o limite do relógio); preenchido e fora de HH:MM → FALHOU (um relógio que eu não entendi não vira "sem limite" calado: a rodada passaria do reseed do nó)
case "$STOP_UTC" in ''|[01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;; *) finish FALHOU "constante inválida: HZN_STOP_UTC='$STOP_UTC' (precisa ser HH:MM em UTC, ou vazio); nada rodou" 1 ;; esac

# ── os lotes ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# Lista: os test_*.py / *_test.py de tests/ DA ÁRVORE QUE VAI AO NÓ (o git archive acima), em ordem de caminho (LC_ALL=C), menos as pastas que o pytest.ini manda ignorar (norecursedirs: os
# padrões do pytest + crew + archive). A poda é nossa porque o pytest só aplica norecursedirs ao DESCER numa pasta: arquivo passado pelo nome é coletado de qualquer jeito. Mesmo escopo da noite
# única de antes (`tests/`); lib/predictive_dialer, processo_lookup/tests e experiments/code_mode/tests do testpaths nunca estiveram nesta bateria.
# vazio (nenhum arquivo) / falhou (find, pesagem) / nome fora de [A-Za-z0-9_./-] (não passa seguro na linha de comando do ssh) → FALHOU: lote que cala sobre arquivo que não pôde rodar é verde falso.
TREE="$SCR/whatsapp_automation"; FILES="$SCR/files.lst"; WGT="$SCR/weights.lst"
[ -d "$TREE/tests" ] || finish FALHOU "a árvore de origin/main@$SHA não tem tests/: nada a rodar" 1
( cd "$TREE" && find tests -type d \( -name '.*' -o -name crew -o -name archive -o -name '*.egg' -o -name _darcs -o -name build -o -name CVS -o -name dist -o -name node_modules -o -name venv -o -name '{arch}' \) -prune \
    -o -type f \( -name 'test_*.py' -o -name '*_test.py' \) -print ) 2>/dev/null | LC_ALL=C sort > "$FILES"
[ -s "$FILES" ] || finish FALHOU "nenhum arquivo test_*.py/*_test.py em tests/ de origin/main@$SHA: nada a rodar" 1
# MAC-ONLY: o mbp-run manda a bateria INTEIRA para fora do nó (rc 98, "mac-only") se UM alvo casar com scripts/hetzner-mac-only.txt (+ a lista aprendida da sombra); `tests/` inteiro, como era antes dos lotes,
# nunca casava. Por regra do nó esses arquivos não rodam no Linux (launchd, osascript, /Users…): ficam FORA da rodada, contados e listados no relatório, e rodam no MBP/mini. Mesma regra de leitura do
# mbp-run: glob por linha, `#` comenta, `case` sobre o caminho relativo; lista que não abre = FALHOU (sem ela não se sabe o que tem de ficar no Mac).
MACLIST=${HETZNER_MAC_ONLY_LIST:-$HERE/hetzner-mac-only.txt}; MACLEARN="$CITY/.gc/hetzner-mac-only.learned"; MACX="$LOGDIR/$DAY.mac-only.lst"
{ [ -f "$MACLIST" ] && [ -r "$MACLIST" ]; } || finish FALHOU "a lista mac-only ($MACLIST) não abre: sem ela não se sabe o que tem de ficar no Mac; nada rodou" 1
if [ -e "$MACLEARN" ]; then { [ -f "$MACLEARN" ] && [ -r "$MACLEARN" ]; } || finish FALHOU "a lista mac-only aprendida ($MACLEARN) existe e não abre; nada rodou" 1; fi
GLOBS=(); while IFS= read -r g || [ -n "$g" ]; do
  g=${g#"${g%%[![:space:]]*}"}; g=${g%"${g##*[![:space:]]}"}
  case "$g" in ''|'#'*) continue ;; esac
  GLOBS[${#GLOBS[@]}]=$g
done < <(cat "$MACLIST" "$MACLEARN" 2>/dev/null)
: > "$MACX"
if [ "${#GLOBS[@]}" -gt 0 ]; then
  : > "$SCR/files.keep"
  while IFS= read -r f; do
    hit=0
    for g in "${GLOBS[@]}"; do
      # shellcheck disable=SC2254
      case "$f" in $g) hit=1; break ;; esac
    done
    if [ "$hit" = 1 ]; then printf '%s\n' "$f" >> "$MACX"; else printf '%s\n' "$f" >> "$SCR/files.keep"; fi
  done < "$FILES"
  mv -f "$SCR/files.keep" "$FILES"
fi
NMAC=$(wc -l < "$MACX" | tr -d ' ')
# RETIDOS NO MINI: o mbp-run não manda ao nó (a) o que o filtro do rsync barra por NOME/pasta e (b) o arquivo com LISTA de telefones/CPFs (node_guard: hetzner-pii-scan.py). Alvo que não chega ao nó
# faz o pytest abortar o LOTE INTEIRO (rc 4, ou rc 5 "no tests ran" sob xdist, sem dizer qual arquivo): 16 arquivos de tests/ em 15/11, e a noite teria 10 lotes "não rodou" por causa deles. Mesma conta
# do node_guard (o mesmo filtro, o mesmo scanner, a mesma árvore): a lista que o rsync enviaria menos o que a varredura retém. Fica FORA da rodada, contado e listado no relatório (rodam no mini).
# FALHA FECHADA como no mbp-run: filtro que não abre, rsync -n sem resposta, lista vazia ou varredura que não terminou (rc != 0) = FALHOU, nada rodou; "não sei o que o nó recebe" não é "recebe tudo".
NFILTER=${HETZNER_RSYNC_FILTER:-$HERE/hetzner-rsync-filter.wa.txt}; PIISCAN=${HZN_PII_SCAN:-$HERE/hetzner-pii-scan.py}; HELDX="$LOGDIR/$DAY.retidos.lst"; RSYNC_BIN=${MBP_RSYNC:-rsync}
{ [ -f "$NFILTER" ] && [ -r "$NFILTER" ]; } || finish FALHOU "o filtro do rsync do nó ($NFILTER) não abre: sem ele não se sabe o que o nó recebe; nada rodou" 1
[ -f "$PIISCAN" ] || finish FALHOU "o scanner de PII ($PIISCAN) não existe: sem ele não se sabe o que o nó recebe; nada rodou" 1
mkdir "$SCR/pf.dst" 2>/dev/null || finish FALHOU "não criei $SCR/pf.dst" 1
"$RSYNC_BIN" -a -n --out-format='%n' --filter=". $NFILTER" "$TREE"/ "$SCR/pf.dst"/ 2>/dev/null | grep -v '/$' > "$SCR/pf.sent"
{ [ "${PIPESTATUS[0]}" -eq 0 ] && [ -s "$SCR/pf.sent" ]; } || finish FALHOU "o rsync -n do filtro do nó ($NFILTER) não listou o que seria enviado: não sei o que o nó recebe; nada rodou" 1
python3 -I "$PIISCAN" "$TREE" --rules "$SCR/pf.rules" < "$SCR/pf.sent" > "$SCR/pf.held" 2>/dev/null || finish FALHOU "a varredura de telefones/CPFs ($PIISCAN) não terminou (rc != 0): não sei o que o nó recebe; nada rodou" 1
cut -f3- "$SCR/pf.held" > "$SCR/pf.hp"
: > "$SCR/pf.nosend"; : > "$SCR/pf.heldt"
LC_ALL=C grep -vxF -f "$SCR/pf.sent" "$FILES" > "$SCR/pf.nosend"; [ $? -le 1 ] || finish FALHOU "não comparei a lista de testes com o que o nó recebe: nada rodou" 1
if [ -s "$SCR/pf.hp" ]; then LC_ALL=C grep -xF -f "$SCR/pf.hp" "$FILES" > "$SCR/pf.heldt"; [ $? -le 1 ] || finish FALHOU "não comparei a lista de testes com os arquivos retidos pela varredura: nada rodou" 1; fi
NHF=$(wc -l < "$SCR/pf.nosend" | tr -d ' '); NHP=$(wc -l < "$SCR/pf.heldt" | tr -d ' ')
cat "$SCR/pf.nosend" "$SCR/pf.heldt" | LC_ALL=C sort -u > "$HELDX"
NHELD=$(wc -l < "$HELDX" | tr -d ' ')
if [ "$NHELD" -gt 0 ]; then LC_ALL=C grep -vxF -f "$HELDX" "$FILES" > "$SCR/files.keep"; [ $? -le 1 ] || finish FALHOU "não tirei da lista os $NHELD arquivos que o nó não recebe: nada rodou" 1; mv -f "$SCR/files.keep" "$FILES"; fi
NFILES=$(wc -l < "$FILES" | tr -d ' ')
[ "$NFILES" -ge 1 ] || finish FALHOU "todos os arquivos de tests/ de origin/main@$SHA ficam no mini (mac-only $NMAC, não enviados ao nó $NHELD): nada a rodar no nó" 1
BADNAME=$(LC_ALL=C grep -cvE '^[A-Za-z0-9_./-]+$' "$FILES"); [ "${BADNAME:-0}" -eq 0 ] || finish FALHOU "$BADNAME arquivo(s) de teste com nome fora de [A-Za-z0-9_./-] (primeiro: $(LC_ALL=C grep -vE '^[A-Za-z0-9_./-]+$' "$FILES" | head -n 1)): não passam seguros na linha de comando; nada rodou" 1
# o peso do arquivo é o nº de `def test_` (mínimo 1): barato, estável e na ordem certa de grandeza do tempo/memória; o nº de lotes SAI da árvore, nunca é fixo
( cd "$TREE" && tr '\n' '\0' < "$FILES" | xargs -0 grep -c -H -E '^[[:space:]]*(async[[:space:]]+)?def[[:space:]]+test_' ) > "$WGT" 2>/dev/null
[ "$(wc -l < "$WGT" | tr -d ' ')" -eq "$NFILES" ] || finish FALHOU "não consegui pesar os $NFILES arquivos de teste ($(wc -l < "$WGT" | tr -d ' ') linhas lidas): nada rodou" 1
LC_ALL=C awk -F: -v max="$BATCH_DEFS" -v amax="$ARGS_MAX" -v dir="$SCR" '
  { f=$1; d=$2+0; w=(d<1?1:d)
    if (cnt>0 && (acc+w>max || bytes+length(f)+1>amax)) { meta[b]=cnt" "defs; b++; acc=0; bytes=0; cnt=0; defs=0 }
    if (b==0) b=1
    print f > (dir "/batch." b); acc+=w; bytes+=length(f)+1; cnt++; defs+=d }
  END { if (cnt>0) meta[b]=cnt" "defs; for (i=1;i<=b;i++) print i, meta[i] > (dir "/batch.meta"); }' "$WGT"
# vazio → batch.meta sem linha = nada a rodar, FALHOU; falhou/ilegível (arquivo ausente, wc quebrado) → o mesmo FALHOU, e NB fica 0: o jline passa $NB ao jq (--argjson), lixo ali derrubava a linha do jsonl da noite
NBX=$(wc -l < "$SCR/batch.meta" 2>/dev/null | tr -d ' ')
case "$NBX" in ''|0|*[!0-9]*) finish FALHOU "não montei os lotes ($NFILES arquivos pesados): nada rodou" 1 ;; esac
NB=$NBX
NDEFS=$(awk '{s+=$3} END{print s+0}' "$SCR/batch.meta")

# ── a rodada ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# O orçamento é do SCRIPT: DEADLINE = T0 + TIMEOUT_S − margem do relatório. Cada lote recebe min(o que resta, HZN_BATCH_TIMEOUT_S); com menos que HZN_MIN_BATCH_S ele nem começa.
# Estado de um lote (B_ST): ran | nao-rodou | retry-cap | retry-mbp | inerte-iso | vazamento | sem-prova | pulado | sem-espaco — só `ran` entra na soma; o resto é "NÃO RODOU" no relatório
# (sem-espaco nunca chega ao relatório: a pista espera e tenta de novo dentro do orçamento).
rm -f "$LOGDIR/$DAY".b*.out 2>/dev/null; : > "$OUT"
TABLE="$SCR/table.md"; : > "$TABLE"; : > "$SCR/ids.all"
# O fim do orçamento é o MENOR de dois: T0 + TIMEOUT_S (prazo) e a próxima ocorrência de STOP_UTC (relógio). A noite de 24/11 perdeu os lotes 10 e 11 porque o prazo era contado só de T0 e a suíte cresceu para 11 lotes:
# o que limita de verdade é a JANELA (a ordem começa 05:00Z, o reseed do nó é 08:55Z), não um número de lotes. Segundos do dia em UTC saem de `epoch % 86400` (sem `date -d`/`-j`: igual no mini e no nó).
# HZN_NOW_S existe só para o selftest fixar "agora" nessa conta (T0 e o relógio da rodada continuam os reais).
BUDGET_END=$(( T0 + TIMEOUT_S )); BUDGET_BY="prazo HZN_TIMEOUT_S=${TIMEOUT_S}s"
if [ -n "$STOP_UTC" ]; then
  NOW0=${HZN_NOW_S:-$T0}; case "$NOW0" in ''|*[!0-9]*) finish FALHOU "HZN_NOW_S='$NOW0' não é um epoch inteiro; nada rodou" 1 ;; esac
  CLK_DELTA=$(( ( 10#${STOP_UTC%:*} * 3600 + 10#${STOP_UTC#*:} * 60 - NOW0 % 86400 + 86400 ) % 86400 )); [ "$CLK_DELTA" -gt 0 ] || CLK_DELTA=86400
  if [ $(( T0 + CLK_DELTA )) -lt "$BUDGET_END" ]; then BUDGET_END=$(( T0 + CLK_DELTA )); BUDGET_BY="relógio ${STOP_UTC} UTC"; fi
fi
DEADLINE=$(( BUDGET_END - MARGIN ))
NRAN=0; NSKIP=0; RANSEC=0; RANDEFS=0; RANFILES_BAD=0; : > "$SCR/ran.files"; SKIPLIST=""; TP=0; TF=0; TE=0; TS=0; TXF=0; TXP=0; LISTOK=1; LISTWHY=""; PYSECS=0; PYUNK=0; EGSUM=0; EGUNK=0; EGSEEN=0; FIRSTCAP=""
say "rodando a suíte do WA @$SHA em $NODE: $NFILES arquivos ($NMAC mac-only e $NHELD não enviados ao nó ficaram de fora), $NDEFS def test_, $NB lotes de ~$BATCH_DEFS (orçamento $(( DEADLINE - $(date +%s) ))s para os lotes, limite: $BUDGET_BY)"

tail1() { grep . "$1" 2>/dev/null | tail -n 1 | cut -c1-200; }
cnt() { printf '%s' "$SUM" | sed -n -E "s/.*[^0-9]([0-9]+) $1.*/\1/p;s/^([0-9]+) $1.*/\1/p" | head -n 1; }
classify() { # saída-do-lote rc → B_ST B_WHY B_ISO B_CAP B_SUM (vazio/ilegível em qualquer leitura → nunca `ran`)
  local f=$1 rc=$2 t1 mk
  B_ISO=$(sed -n 's/^GTN-ISO: //p' "$f" 2>/dev/null | head -n 1)   # só uma linha que COMEÇA com "isolado" vale como prova de isolamento
  B_CAP=$(sed -n 's/^GTN-CAP: //p' "$f" 2>/dev/null | head -n 1)   # só `MemoryMax=… MemorySwapMax=0 …` vale como prova do teto de memória
  B_SUM=""; B_ST=nao-rodou; B_WHY=""; t1=$(tail1 "$f")
  case "$rc" in
    95) B_ST=sem-espaco; B_WHY="o nó não tem espaço (memória/CPU) para uma pista EXTRA agora: GTN-CAP: ${B_CAP:-vazio}"; return ;;   # rc 95 do gt-iso-run: o comando NÃO rodou; NÃO é falha do lote nem gasta tentativa
    99) B_ST=pulado; B_WHY="nó Linux desligado (falta $CITY/.gc/hetzner-node.on)"; return ;;
    96|97|98)
      case "$B_ISO" in
        nao-isolado*) B_ST=vazamento; B_WHY="o canário SAIU pela rede: GTN-ISO: $B_ISO"; return ;;
        inerte*) B_ST=inerte-iso; B_WHY="isolamento de rede NÃO provado: GTN-ISO: $B_ISO"; return ;;
      esac
      case "$B_CAP" in
        inerte*) B_ST=retry-cap; B_WHY="teto de memória NÃO provado no nó: GTN-CAP: $B_CAP" ;;
        *) B_ST=retry-mbp; B_WHY="o mbp-run não rodou a suíte (rc=$rc): $t1" ;;
      esac
      return ;;
    124) B_WHY="estourou o prazo do lote (${bt}s)"; return ;;
    0|1) ;;
    *) if [ "$rc" -ge 128 ]; then B_WHY="o pytest foi MORTO (rc=$rc; com o teto de memória é o OOM do cgroup: o lote é pesado demais para o MemAvailable de hoje): $t1"
       else B_WHY="o pytest abortou (rc=$rc): $t1"; fi
       return ;;
  esac
  case "$B_ISO" in isolado*) ;; *) B_ST=sem-prova; B_WHY="ATENÇÃO: o lote terminou SEM a linha de prova do isolamento (GTN-ISO: '${B_ISO:-vazio}'); resultado descartado, confira o hook HETZNER_ISOLATE do mbp-run.sh"; return ;; esac
  case "$B_CAP" in MemoryMax=*MemorySwapMax=0*) ;; *) B_ST=sem-prova; B_WHY="ATENÇÃO: o lote terminou SEM a linha de prova do teto de memória (GTN-CAP: '${B_CAP:-vazio}'); resultado descartado, confira se o gt-iso-run instalado no nó é o do repo"; return ;; esac
  mk=$(grep -E -m 1 "worker '[^']*' crashed|maximum crashed workers reached|^node down:|Not properly terminated" "$f" 2>/dev/null | cut -c1-160)
  if [ -n "$mk" ]; then B_WHY="worker do xdist caiu (com o teto de memória, em geral o OOM do cgroup; o resultado do lote não é confiável): $mk"; return; fi
  B_SUM=$(grep -E '^(=+ )?([0-9]+ [a-z]+.*|no tests ran) in [0-9.]+s' "$f" 2>/dev/null | tail -n 1)
  if [ -z "$B_SUM" ]; then B_WHY="sem linha de resumo do pytest (rc=$rc): $t1"; return; fi
  B_ST=ran
}
agg_batch() { # nn → soma os números do lote e confere a lista de ids dele (vazio → 0, o pytest omite o que é zero; inconsistente → LISTOK=0)
  local f=$1 nn=$2 nids nsent sl sn sr w="" py
  SUM=$B_SUM
  PASSED=$(cnt passed); FAILED=$(cnt failed); ERRORS=$(cnt 'errors?'); SKIPPED=$(cnt skipped); XF=$(cnt xfailed); XP=$(cnt xpassed)
  PASSED=${PASSED:-0}; FAILED=${FAILED:-0}; ERRORS=${ERRORS:-0}; SKIPPED=${SKIPPED:-0}; XF=${XF:-0}; XP=${XP:-0}
  TP=$(( TP + PASSED )); TF=$(( TF + FAILED )); TE=$(( TE + ERRORS )); TS=$(( TS + SKIPPED )); TXF=$(( TXF + XF )); TXP=$(( TXP + XP ))
  py=$(printf '%s' "$SUM" | sed -n -E 's/.* in ([0-9]+)\.[0-9]+s.*/\1/p')
  if [ -n "$py" ]; then PYSECS=$(( PYSECS + py )); else PYUNK=1; fi
  # ids do PLUGIN (gtn_stable_ids.py): `GTN-FAIL: <id em JSON>` por id e uma `GTN-FAILED: n=<ids> reports=<falhas+erros>`; nunca da linha humana `FAILED <id> - <msg>` (o id pode ter " - ")
  LC_ALL=C sed -n 's/^GTN-FAIL: //p' "$f" 2>/dev/null | LC_ALL=C sort -u > "$SCR/ids.b"
  nids=$(wc -l < "$SCR/ids.b" | tr -d ' ')
  nsent=$(LC_ALL=C grep -c '^GTN-FAILED: ' "$f" 2>/dev/null); nsent=${nsent:-0}
  sl=$(LC_ALL=C sed -n 's/^GTN-FAILED: //p' "$f" 2>/dev/null | head -n 1)
  sn=$(printf '%s' "$sl" | sed -n -E 's/^n=([0-9]+) reports=([0-9]+)$/\1/p'); sr=$(printf '%s' "$sl" | sed -n -E 's/^n=([0-9]+) reports=([0-9]+)$/\2/p')
  if [ "$nsent" -eq 0 ]; then w="o pytest não imprimiu a linha GTN-FAILED (o plugin gtn_stable_ids não rodou ou falhou ao montar a lista)"
  elif [ "$nsent" -gt 1 ]; then w="a linha GTN-FAILED aparece $nsent vezes"
  elif [ -z "$sn" ] || [ -z "$sr" ]; then w="a linha GTN-FAILED está ilegível ($sl)"
  elif ! jq -en '[inputs | type == "string"] | all' "$SCR/ids.b" >/dev/null 2>&1; then w="há linha GTN-FAIL que não é um id em JSON"
  elif [ "$nids" -ne "$sn" ]; then w="o plugin diz $sn ids e $nids foram lidos (lista parcial)"
  elif [ "$sr" -ne $(( FAILED + ERRORS )) ]; then w="o plugin contou $sr falhas/erros e o resumo do pytest diz $((FAILED + ERRORS))"; fi
  if [ -n "$w" ]; then LISTOK=0; [ -n "$LISTWHY" ] || LISTWHY="lote $nn: $w"; fi
  cat "$SCR/ids.b" >> "$SCR/ids.all"
}
emit_table() {
  echo "| lote | arquivos | def test_ | workers | s | situação | detalhe |"; echo "|---|---|---|---|---|---|---|"; cat "$TABLE"
}

# Um lote são DUAS funções: run_one_batch (roda, com as tentativas, e grava o resultado em $SCR/res.<n>; só escreve em arquivo e na saída, então roda igual dentro de uma pista) e post_one_batch (lê o resultado
# e faz o que o laço sequencial fazia depois: tabela, soma, os casos que encerram a noite). Com 1 pista é o laço de sempre, lote a lote; com N pistas (ga-282sl1d, ver PISTAS no cabeçalho) até N lotes rodam ao mesmo
# tempo e a leitura vem DEPOIS, na ordem dos lotes, então soma, tabela, comparação e relatório são os mesmos.
run_one_batch() { # n → o resultado vai para $SCR/res.<n>
  local i=$1 meta l left t1 RC
  nn=$(printf '%02d' "$i")
  BOUT="$LOGDIR/$DAY.b$nn.out"; : > "$BOUT"; BSEC=0; tries=0; bt=0; LASTWHY=""
  meta=$(awk -v b="$i" '$1==b{print $2" "$3}' "$SCR/batch.meta"); nf=${meta%% *}; nd=${meta##* }
  BF=(); while IFS= read -r l; do BF[${#BF[@]}]=$l; done < "$SCR/batch.$i"
  B_ST=nao-rodou; B_WHY=""; B_ISO=""; B_CAP=""; B_SUM=""
  while :; do
    tries=$((tries+1))
    left=$(( DEADLINE - $(date +%s) ))
    if [ "$left" -lt "$MIN_BATCH" ]; then
      B_ST=nao-rodou; B_WHY="orçamento esgotado: restam ${left}s (< ${MIN_BATCH}s) e o lote não começou${LASTWHY:+ (antes: $LASTWHY)}"; break
    fi
    bt=$BATCH_T; [ "$left" -ge "$bt" ] || bt=$left
    say "lote $nn/$NB: $nf arquivos, $nd def test_, prazo ${bt}s (restam ${left}s do orçamento)${LASTWHY:+; tentativa $tries}"
    t1=$(date +%s)
    HETZNER_ISOLATE=1 HETZNER_ISO_LANES="$ISOLANES" HETZNER_NODE_HOST="$NODE" MBP_RUN_TIMEOUT_S="$bt" "$RUN" --host linux --repo wa --dir "$TREE" -- "${BF[@]}" -n auto -p gtn_stable_ids --timeout=300 -q -rfE --tb=line --continue-on-collection-errors > "$BOUT" 2>&1
    RC=$?
    BSEC=$(( $(date +%s) - t1 ))
    classify "$BOUT" "$RC"
    case "$B_ST" in
      sem-espaco) # gt-iso-run rc 95: o nó não tem espaço para esta pista AGORA. Não é falha, não gasta tentativa e não conta no retry: espera a outra pista soltar memória e tenta de novo (o `left < MIN_BATCH` do topo fecha a conta)
        LASTWHY=$B_WHY; tries=$((tries-1)); echo "$nn" >> "$SCR/waits"; say "lote $nn: $B_WHY; espera ${LANE_WAIT}s"; sleep "$LANE_WAIT"; continue ;;
      retry-*) # transitório (teto/MemAvailable inerte, sem slot, ssh/rsync caído): tenta de novo se ainda couber no orçamento
        if [ "$tries" -lt "$TRIES" ] && [ $(( DEADLINE - $(date +%s) )) -gt $(( RETRY_S + MIN_BATCH )) ]; then LASTWHY=$B_WHY; say "lote $nn: $B_WHY; nova tentativa em ${RETRY_S}s"; sleep "$RETRY_S"; continue; fi
        B_WHY="$B_WHY (após $tries tentativa(s))"; break ;;
      *) break ;;
    esac
  done
  # gravação atômica; %q deixa cada valor ser relido por `.` sem perder aspas, acento nem quebra de linha
  { printf 'B_ST=%q B_WHY=%q B_ISO=%q B_CAP=%q B_SUM=%q BSEC=%q tries=%q bt=%q nf=%q nd=%q\n' "$B_ST" "$B_WHY" "$B_ISO" "$B_CAP" "$B_SUM" "$BSEC" "$tries" "$bt" "$nf" "$nd"; } > "$SCR/res.$i.tmp" && mv -f "$SCR/res.$i.tmp" "$SCR/res.$i"
}
load_batch() { # n → B_ST... do resultado gravado; sem resultado (a pista foi derrubada antes de o lote terminar, ou ele nunca saiu da fila) → NÃO RODOU com o motivo, nunca um lote "vazio" que passaria por verde
  local i=$1 meta
  nn=$(printf '%02d' "$i"); BOUT="$LOGDIR/$DAY.b$nn.out"
  meta=$(awk -v b="$i" '$1==b{print $2" "$3}' "$SCR/batch.meta"); nf=${meta%% *}; nd=${meta##* }
  B_ST=nao-rodou; B_WHY=""; B_ISO=""; B_CAP=""; B_SUM=""; BSEC=0; tries=0; bt=0
  if [ -s "$SCR/res.$i" ] && . "$SCR/res.$i" 2>/dev/null; then :
  else B_ST=nao-rodou; B_ISO=""; B_CAP=""; B_SUM=""; BSEC=0; tries=0
    if [ -d "$SCR/claim.$i" ]; then B_WHY="a rodada parou antes de o lote terminar (outra pista achou vazamento/lote sem prova, ou o orçamento acabou)"; else B_WHY="o lote não chegou a começar (a rodada parou antes: outra pista achou vazamento/lote sem prova)"; fi
    : > "$BOUT" 2>/dev/null
  fi
}
post_one_batch() { # n → lê o resultado do lote n e o soma
  local i=$1
  load_batch "$i"
  if [ "$B_ST" = pulado ]; then   # bandeira do nó desligada: no 1º lote é PULADO (nada rodou, sem e-mail); no meio da rodada o lote simplesmente NÃO RODOU
    [ "$i" -ne 1 ] || finish PULADO "nó Linux desligado (falta $CITY/.gc/hetzner-node.on)" 0
    B_ST=nao-rodou; B_WHY="o nó foi desligado no meio da rodada: $B_WHY"
  fi
  { echo "=== lote $nn: $nf arquivos, $nd def test_, ${BSEC}s, $B_ST ==="; cat "$BOUT"; echo; } >> "$OUT"
  WK=$(printf '%s' "$B_CAP" | sed -n -E 's/.*workers=([0-9]+).*/\1/p'); WK=${WK:-?}
  [ -n "$FIRSTCAP" ] || FIRSTCAP=$B_CAP
  [ -n "${ISO_LINE:-}" ] || ISO_LINE=$B_ISO
  # o contador do nft de cada lote que o imprimiu soma no total; lote que RODOU sem ler o contador torna o total "?" (não afirmo zero sem ter lido)
  eg=$(sed -n 's/^GTN-EGRESS: attempts=//p' "$BOUT" 2>/dev/null | tail -n 1)
  case "$eg" in ''|*[!0-9]*) [ "$B_ST" != ran ] || EGUNK=1 ;; *) EGSUM=$(( EGSUM + eg )); EGSEEN=1 ;; esac
  if [ "$EGUNK" = 0 ] && [ "$EGSEEN" = 1 ]; then EGRESS=$EGSUM; else EGRESS="?"; fi
  # escudo do relatório (gtn_stable_ids): o plugin só imprime `GTN-ESCUDO: n=<n>` com n > 0, então a linha AUSENTE num lote que rodou é 0; linha presente e ilegível → "?" (não afirmo zero)
  es=$(sed -n 's/^GTN-ESCUDO: n=//p' "$BOUT" 2>/dev/null | tail -n 1)
  case "$es" in '') ;; *[!0-9]*) ESCUNK=1 ;; *) ESCSUM=$(( ESCSUM + es )) ;; esac
  case "$B_ST" in ran) ROW_S="rodou" ;; *) ROW_S="NÃO RODOU" ;; esac
  printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$nn" "$nf" "$nd" "$WK" "$BSEC" "$ROW_S" "$(printf '%s' "${B_WHY:--}" | tr '|\n' '/ ')" >> "$TABLE"
  WALL=$(( $(date +%s) - T0 ))
  case "$B_ST" in
    vazamento)
      { echo "# Hetzner nightly $DAY — FALHOU: VAZAMENTO DE REDE MEDIDO (lote $nn de $NB; os lotes seguintes NÃO rodaram)"; echo
        echo "A sonda do canário SAIU pela rede (ou achou interface/segredo): \`GTN-ISO: $B_ISO\`"
        echo "Não é \"falta instalar\": o isolamento existe e NÃO segura. Não reative a bateria antes de entender o que vazou (runbook, seção Vazamento medido)."
        echo; echo "origin/main @$SHA"; echo; emit_table; } > "$REPORT"
      finish FALHOU "VAZAMENTO MEDIDO: o canário saiu pela rede ($B_ISO) no lote $nn; a suíte não terminou" 1 ;;
    sem-prova)
      { echo "# Hetzner nightly $DAY — FALHOU: lote $nn sem prova (os lotes seguintes NÃO rodaram)"; echo; echo "$B_WHY"; echo; echo "origin/main @$SHA"; echo; emit_table; } > "$REPORT"
      finish FALHOU "$B_WHY" 1 ;;
    inerte-iso)
      if [ "$i" -eq 1 ]; then
        { echo "# Hetzner nightly $DAY — INERTE (nada rodou)"; echo; echo "Isolamento de rede NÃO provado: \`GTN-ISO: $B_ISO\`"; echo "Sem essa prova a suíte não roda (04/10: um teste mandou e-mail de verdade)."; echo "Instalar o helper de root: docs/runbooks/hetzner-nightly-tests.md, seção Instalação."; echo; echo "origin/main @$SHA"; [ -z "$STALE_NOTE" ] || echo "ATENÇÃO: $STALE_NOTE"; } > "$REPORT"
        finish INERTE "isolamento não provado ($B_ISO)" 0
      fi
      B_ST=nao-rodou ;;
    retry-cap)
      if [ "$i" -eq 1 ]; then
        { echo "# Hetzner nightly $DAY — INERTE (nada rodou)"; echo; echo "Teto de memória NÃO provado no nó: \`GTN-CAP: $B_CAP\` (${tries} tentativa(s))"
          echo "Sem ler o MemAvailable e sem provar o \`systemd-run --user --scope -p MemoryMax=…\` a suíte não roda: foi a falta desse teto que deu o OOM (rc=137) de 13, 14 e 15/11 (ga-84gkpab)."
          echo "Ver docs/runbooks/hetzner-nightly-tests.md, seção Teto de memória."; echo; echo "origin/main @$SHA"; [ -z "$STALE_NOTE" ] || echo "ATENÇÃO: $STALE_NOTE"; } > "$REPORT"
        finish INERTE "teto de memória não provado no nó (GTN-CAP: $B_CAP)" 0
      fi
      B_ST=nao-rodou ;;
    retry-mbp)
      [ "$i" -ne 1 ] || finish FALHOU "$B_WHY" 1
      B_ST=nao-rodou ;;
  esac
  if [ "$B_ST" = ran ]; then NRAN=$(( NRAN + 1 )); RANSEC=$(( RANSEC + BSEC )); RANDEFS=$(( RANDEFS + ${nd:-0} ))
    # vazio (lote sem arquivo) não existe: o awk só abre lote com arquivo; falhou/ilegível (a lista do lote sumiu) → RANFILES_BAD, e a comparação parcial fica INDISPONÍVEL: sem a lista não sei quais ids da baseline comparar
    cat "$SCR/batch.$i" >> "$SCR/ran.files" 2>/dev/null || RANFILES_BAD=1
    agg_batch "$BOUT" "$nn"
  else NSKIP=$(( NSKIP + 1 )); SKIPLIST="$SKIPLIST${SKIPLIST:+, }$nn"; say "lote $nn NÃO RODOU: $B_WHY"; fi
}
claim_next() { # → o menor lote ainda sem dono (mkdir é atômico: duas pistas nunca pegam o mesmo); sem lote → rc 1
  local j=0
  while [ "$j" -lt "$NB" ]; do j=$((j+1)); mkdir "$SCR/claim.$j" 2>/dev/null && { echo "$j"; return 0; }; done
  return 1
}
lane_loop() { # índice da pista (0 = a primeira, a que nunca devolve lote): tira lotes da fila, roda e olha o resultado. Só lê/escreve arquivos: roda em subshell
  local ln=$1 k
  while [ ! -e "$SCR/stop" ]; do
    k=$(claim_next) || break
    run_one_batch "$k"
    case "$B_ST" in
      vazamento|sem-prova) : > "$SCR/stop"; break ;;   # vazamento medido ou lote sem prova: a noite acaba aqui, em qualquer pista (os lotes seguintes não rodam)
      pulado|inerte-iso|retry-cap|retry-mbp)
        # o lote 1 nesses estados decide a noite inteira (INERTE/PULADO/FALHOU): para a fila, o resto seria trabalho jogado fora
        [ "$k" -ne 1 ] || { : > "$SCR/stop"; break; }
        # pista EXTRA (ln > 0) que não conseguiu rodar por causa do nó (sem slot, ssh, canário, bandeira): devolve o lote e sai; a pista 0 o pega. Assim a falha de uma pista extra não faz perder lote que a noite sem pistas teria rodado
        if [ "$ln" -gt 0 ]; then find "$SCR/res.$k" -delete 2>/dev/null; rmdir "$SCR/claim.$k" 2>/dev/null; say "pista $((ln+1)): lote $k devolvido à fila ($B_ST: $B_WHY); a pista 1 o pega"; break; fi ;;
    esac
  done
}
kill_tree() { local p=$1 c; for c in $(pgrep -P "$p" 2>/dev/null); do kill_tree "$c"; done; kill "$p" 2>/dev/null; return 0; }
kill_lanes() { local p; for p in $LANE_PIDS; do kill_tree "$p"; done; return 0; }

if [ "$LANES" -le 1 ]; then
  k=0; while [ "$k" -lt "$NB" ]; do k=$((k+1)); run_one_batch "$k"; post_one_batch "$k"; done
else
  say "pistas: até $LANES lotes ao mesmo tempo (HZN_LANES=$LANES; pista extra sem espaço no nó espera ${LANE_WAIT}s)"
  LANE_T0=$(date +%s); LANE_PIDS=""; ln=0
  # a pista k começa k/10 s depois da 0: a 0 sempre tira o lote 1 da fila (o lote 1 decide a noite no INERTE/PULADO/FALHOU de sempre) e as extras pegam os seguintes
  while [ "$ln" -lt "$LANES" ]; do ( export HZN_LANE_NO=$ln; sleep "0.$ln"; lane_loop "$ln" ) & LANE_PIDS="$LANE_PIDS $!"; ln=$((ln+1)); done
  while :; do
    alive=0; for p in $LANE_PIDS; do ! kill -0 "$p" 2>/dev/null || alive=1; done
    [ "$alive" = 1 ] || break
    if [ -e "$SCR/stop" ]; then say "uma pista pediu parada (vazamento, lote sem prova ou nó inerte no lote 1): derrubando as outras"; kill_lanes; break; fi
    # as pistas só começam lote até DEADLINE e cada lote tem prazo ≤ o que resta: quem passar do fim do orçamento (BUDGET_END, que inclui a margem do relatório) está preso e cai
    if [ "$(date +%s)" -gt "$BUDGET_END" ]; then say "WARN: pista passou do fim do orçamento; derrubando"; kill_lanes; break; fi
    sleep 0.3
  done
  wait 2>/dev/null; LANE_SPAN=$(( $(date +%s) - LANE_T0 ))
  NWAITS=$(wc -l < "$SCR/waits" 2>/dev/null | tr -d ' '); case "$NWAITS" in ''|*[!0-9]*) NWAITS=0 ;; esac
  # lote que uma pista devolveu à fila DEPOIS de a outra ter visto a fila vazia não tem resultado nem dono: roda aqui, sozinho (a parada por vazamento/sem prova não passa por isto)
  if [ ! -e "$SCR/stop" ]; then k=0; while [ "$k" -lt "$NB" ]; do k=$((k+1)); [ -s "$SCR/res.$k" ] || { say "lote $k ficou sem resultado depois das pistas: rodando sozinho"; run_one_batch "$k"; }; done; fi
  k=0; while [ "$k" -lt "$NB" ]; do k=$((k+1)); post_one_batch "$k"; done
fi
WALL=$(( $(date +%s) - T0 ))
TOTAL=$(( TP + TF + TE + TS + TXF + TXP ))
# pistas (só com HZN_LANES >= 2): quantos lotes andaram ao mesmo tempo, em média (soma dos segundos dos lotes ÷ relógio das pistas) e quantas vezes uma pista esperou o nó ter espaço. vazio/zero → "?", nunca um número inventado
LANETXT=""
if [ "$LANES" -gt 1 ]; then
  AVGPAR=$(awk -v a="${RANSEC:-0}" -v b="${LANE_SPAN:-0}" 'BEGIN { if (b+0 > 0) printf "%.1f", a/b; else print "?" }')
  LANETXT="pistas: $LANES configuradas, média de $AVGPAR lotes ao mesmo tempo (${RANSEC}s de lote em ${LANE_SPAN:-?}s de relógio); a pista extra esperou o nó ter espaço $NWAITS vez(es)"
fi
PASSED=$TP; FAILED=$TF; ERRORS=$TE; SKIPPED=$TS; XF=$TXF; XP=$TXP
DUR="?"; [ "$PYUNK" = 0 ] || PYSECS=""; [ -z "$PYSECS" ] || DUR="$(( PYSECS / 3600 ))h$(( (PYSECS % 3600) / 60 ))min"
EGLINE="$EGRESS tentativa(s) de saída barradas pelo nft"
case "$EGRESS" in 0) EGLINE="0 tentativas de saída (contador do nft lido em todos os lotes que rodaram)" ;; '?') EGLINE="contador do nft ILEGÍVEL em algum lote — não afirmo zero tentativas" ;; esac
CUR="$LOGDIR/$DAY.failed"; LC_ALL=C sort -u "$SCR/ids.all" > "$CUR"

# algum lote não rodou → FALHOU: sem total confiável e sem avançar a linha de base. A comparação, porém, não se perde com os lotes que faltaram: os lotes que RODARAM são comparados com a última noite COMPLETA, mas só
# nos arquivos deles (a baseline filtrada pelos arquivos dos lotes que rodaram), e o relatório diz que é PARCIAL (ga-z6bc623: a noite de 24/11 rodou 9 de 11 lotes e saiu sem nenhuma comparação).
# vazio (nenhum lote rodou / não há noite completa anterior) → "-", sem comparação; falhou/ilegível (lista de ids não confiável, baseline que não abre ou sem o mesmo nº de linhas na filtragem) → INDISPONÍVEL,
# nunca "0 novas": INDISPONÍVEL deixa a baseline como estava, e a parcial NUNCA a avança (só a noite COMPLETA avança).
if [ "$NSKIP" -gt 0 ]; then
  NIDS=$(wc -l < "$CUR" | tr -d ' '); PREV="$LOGDIR/last-complete.failed"; PMETA="$LOGDIR/last-complete.meta"; NEW="$LOGDIR/$DAY.new"; : > "$NEW"
  PCMP="comparação parcial: não feita (nenhum lote rodou)"; NEWTXT="sem comparação"
  if [ "$NRAN" -eq 0 ]; then CMPST=-
  elif [ "$LISTOK" = 0 ]; then PCMP="comparação parcial INDISPONÍVEL: $LISTWHY (a linha de base não foi tocada)"; CMPST=indisponivel
  elif [ "$RANFILES_BAD" = 1 ]; then PCMP="comparação parcial INDISPONÍVEL: a lista de arquivos de um lote que rodou não pôde ser lida (a linha de base não foi tocada)"; CMPST=indisponivel
  elif [ ! -e "$PREV" ]; then PCMP="comparação parcial: não há noite completa anterior para comparar (as $NIDS falhas dos lotes que rodaram estão em $CUR)"; CMPST=-
  elif [ -r "$PREV" ] && jq -en '[inputs | type == "string"] | all' "$PREV" >/dev/null 2>&1 \
       && jq -r --rawfile rf "$SCR/ran.files" '($rf | split("\n") | map(select(length > 0) | {(.): true}) | add // {}) as $m | ($m[(split("::")[0])] // false)' "$PREV" > "$SCR/prev.flags" 2>/dev/null \
       && [ "$(wc -l < "$SCR/prev.flags" | tr -d ' ')" = "$(wc -l < "$PREV" | tr -d ' ')" ] \
       && paste -d '|' "$SCR/prev.flags" "$PREV" | LC_ALL=C awk '/^true[|]/ { sub(/^true[|]/, ""); print }' | LC_ALL=C sort -u > "$SCR/prev.partial" 2>/dev/null; then
    # id de $CUR cujo arquivo não está entre os que rodaram (não deveria existir) não casa com a baseline filtrada e entra como NOVO: erra para o lado de avisar.
    # vazio (comm sem saída) = "0 novas" é um resultado VÁLIDO; falhou (comm com rc != 0, ou a contagem de corrigidas ilegível) NÃO é "0 novas": cai em INDISPONÍVEL e $NEW volta a vazio.
    if LC_ALL=C $COMM -13 "$SCR/prev.partial" "$CUR" > "$NEW" 2>/dev/null && FIXED=$(LC_ALL=C $COMM -23 "$SCR/prev.partial" "$CUR" | wc -l | tr -d ' ') && [ -n "$FIXED" ]; then
      NEWTXT="$(wc -l < "$NEW" | tr -d ' ') falhas novas nos arquivos que rodaram"; CMPST=parcial
      PCMP="comparação PARCIAL contra a última noite completa ($(cat "$PMETA" 2>/dev/null || echo 'data ilegível')), só dos $(sort -u "$SCR/ran.files" | wc -l | tr -d ' ') arquivos dos $NRAN lotes que rodaram: $(wc -l < "$NEW" | tr -d ' ') falhas NOVAS, $FIXED corrigidas (os arquivos dos lotes que não rodaram NÃO foram comparados)"
    else : > "$NEW"; PCMP="comparação parcial INDISPONÍVEL: o comando de comparação ($COMM) falhou (as falhas dos lotes que rodaram estão em $CUR)"; CMPST=indisponivel; fi
  else PCMP="comparação parcial INDISPONÍVEL: $PREV existe e não pôde ser lido ou filtrado como lista de ids em JSON (as falhas dos lotes que rodaram estão em $CUR)"; CMPST=indisponivel; fi
  # orçamento e ritmo: segundos por `def test_` dos lotes que rodaram × todos os `def test_` da árvore, contra o orçamento da noite (vazio/zero → ritmo desconhecido: não afirmo que cabia nem que não)
  BUDGETTXT="orçamento da noite: $(( BUDGET_END - T0 ))s ($(( BUDGET_END - T0 - MARGIN ))s para os lotes, o resto é a margem do relatório); limite: $BUDGET_BY"
  PACE="ritmo desconhecido (nenhum lote rodou até o fim)"
  if [ "$NRAN" -gt 0 ] && [ "$RANDEFS" -gt 0 ]; then PACE="ritmo medido ${RANSEC}s para $RANDEFS def test_ (~$(( RANSEC * NDEFS / RANDEFS ))s para os $NDEFS da árvore)"; fi
  [ "$LANES" -le 1 ] || PACE="$PACE; $LANETXT"
  { echo "# Hetzner nightly $DAY — FALHOU: $NSKIP de $NB lotes NÃO RODARAM"; echo
    echo "- origin/main @$SHA, nó $NODE, $NFILES arquivos de tests/ ($NDEFS def test_) em $NB lotes de ~$BATCH_DEFS"
    [ "$NMAC" -eq 0 ] || echo "- fora da rodada por regra do nó: $NMAC arquivos mac-only (lista em $MACX; rodam no MBP/mini)"
    [ "$NHELD" -eq 0 ] || echo "- fora da rodada porque o nó não os recebe: $NHELD arquivos ($NHF barrados pelo filtro do rsync, $NHP com lista de telefones/CPFs; lista em $HELDX; rodam no mini)"
    [ -z "$STALE_NOTE" ] || echo "- ATENÇÃO: $STALE_NOTE"
    echo "- instalado no nó: $DEPLOY"
    echo "- lotes que NÃO rodaram: $SKIPLIST (motivo na tabela). Sem eles a suíte NÃO foi completa: não há veredito verde, não há total da suíte e a linha de base não foi tocada"
    echo "- $PCMP"
    echo "- $BUDGETTXT"
    echo "- $PACE"
    echo "- só dos $NRAN lotes que rodaram (parcial, NÃO é o total da suíte): $TOTAL testes ($PASSED passaram, $FAILED falharam, $ERRORS erros, $SKIPPED pulados, $XF xfail, $XP xpass); relógio total ${WALL} s"
    echo "- isolamento: \`GTN-ISO: ${ISO_LINE:-vazio}\`; teto: \`GTN-CAP: ${FIRSTCAP:-vazio}\`; $EGLINE"
    if [ -s "$NEW" ]; then echo; echo "Falhas novas nos arquivos que rodaram (até 30 de $(wc -l < "$NEW" | tr -d ' ')):"; head -n 30 "$NEW" | jq -r . | sed 's/^/  - /'; fi
    echo; emit_table; echo
    echo "Saída por lote: $LOGDIR/$DAY.bNN.out; junta: $OUT; ids reprovados dos lotes que rodaram (um JSON por linha; \`jq -r .\` para ler): $CUR"; } > "$REPORT"
  finish FALHOU "$NSKIP de $NB lotes NÃO RODARAM ($SKIPLIST); parcial dos $NRAN que rodaram: $TOTAL testes, $FAILED falhas, $ERRORS erros ($NEWTXT)" 1
fi
case "$ISO_LINE" in isolado*) ;; *) finish FALHOU "ATENÇÃO: nenhum lote trouxe a linha de prova do isolamento (GTN-ISO: '${ISO_LINE:-vazio}'); resultado descartado" 1 ;; esac
[ "$TOTAL" -ge "$MIN_TOTAL" ] || finish FALHOU "total implausível ($TOTAL testes < $MIN_TOTAL em $NB lotes)" 1

# comparação com a última noite COMPLETA. vazio (arquivo existe e está vazio) → toda falha de hoje é nova; ausente → 1ª rodada; falhou/ilegível (existe e não abre/ordena, lista inconsistente) → "comparação
# INDISPONÍVEL", NUNCA "0 novas", e a linha de base fica como estava.
NIDS=$(wc -l < "$CUR" | tr -d ' ')
PREV="$LOGDIR/last-complete.failed"; PMETA="$LOGDIR/last-complete.meta"
CMP="primeira rodada completa: não há noite anterior para comparar; as $NIDS falhas de hoje viram a linha de base"
NEW="$LOGDIR/$DAY.new"; : > "$NEW"; NEWTXT="sem comparação"
if [ "$LISTOK" = 0 ]; then CMP="comparação INDISPONÍVEL: $LISTWHY (a linha de base não foi tocada)"; CMPST=indisponivel
elif [ -e "$PREV" ]; then
  # a baseline tem de ser uma lista de ids em JSON (uma baseline de outro formato não vira "tudo novo": vira comparação indisponível)
  if [ -r "$PREV" ] && jq -en '[inputs | type == "string"] | all' "$PREV" >/dev/null 2>&1 && LC_ALL=C sort -u "$PREV" > "$SCR/prev.sorted" 2>/dev/null; then
    LC_ALL=C comm -13 "$SCR/prev.sorted" "$CUR" > "$NEW"; FIXED=$(LC_ALL=C comm -23 "$SCR/prev.sorted" "$CUR" | wc -l | tr -d ' ')
    NEWTXT="$(wc -l < "$NEW" | tr -d ' ') novas"; CMPST=ok
    CMP="contra a última noite completa ($(cat "$PMETA" 2>/dev/null || echo 'data ilegível')): $(wc -l < "$NEW" | tr -d ' ') falhas NOVAS, $FIXED corrigidas"
  else CMP="comparação INDISPONÍVEL: $PREV existe e não pôde ser lido como lista de ids em JSON (as falhas de hoje estão em $CUR)"; CMPST=indisponivel; fi
else NEWTXT="primeira rodada"; CMPST=ok
fi
GOAL="ATINGIDA"; [ "$WALL" -lt "$TIMEOUT_S" ] || GOAL="ESTOURADA"
ESCTXT="$ESCSUM relatório(s) refeito(s) sem o hook da suíte que quebrou (o teste continua reprovando; linha GTN-ESCUDO nas saídas dos lotes)"
[ "$ESCSUM" -gt 0 ] || ESCTXT="0 (nenhum hook da suíte quebrou ao montar o relatório)"
[ "$ESCUNK" = 0 ] || ESCTXT="contagem ILEGÍVEL em algum lote (linha GTN-ESCUDO que não é um número) — não afirmo zero"
{
  echo "# Hetzner nightly $DAY — COMPLETO"; echo
  echo "- origin/main @$SHA, nó $NODE, $NFILES arquivos de tests/ ($NDEFS def test_) em $NB lotes (\`pytest <arquivos do lote> -n auto\`, workers e teto de memória derivados do MemAvailable do nó a cada lote)"
  [ "$NMAC" -eq 0 ] || echo "- fora da rodada por regra do nó: $NMAC arquivos mac-only (scripts/hetzner-mac-only.txt; lista em $MACX; rodam no MBP/mini, esta bateria NÃO os cobre)"
  [ "$NHELD" -eq 0 ] || echo "- fora da rodada porque o nó não os recebe: $NHELD arquivos ($NHF barrados pelo filtro do rsync, $NHP com lista de telefones/CPFs; lista em $HELDX; rodam no mini, esta bateria NÃO os cobre)"
  [ -z "$STALE_NOTE" ] || echo "- ATENÇÃO: $STALE_NOTE"
  echo "- instalado no nó: $DEPLOY"
  echo "- total: $TOTAL ($PASSED passaram, $FAILED falharam, $ERRORS erros, $SKIPPED pulados, $XF xfail, $XP xpass); $NRAN de $NB lotes rodaram"
  echo "- duração: pytest somado ${DUR} (${PYSECS:-?} s), relógio total ${WALL} s; meta de $(( TIMEOUT_S / 60 )) min: $GOAL"
  [ -z "$LANETXT" ] || echo "- $LANETXT"
  echo "- $CMP"
  echo "- isolamento: \`GTN-ISO: $ISO_LINE\`; teto (lote 01): \`GTN-CAP: $FIRSTCAP\`; $EGLINE"
  echo "- escudo do relatório (plugin gtn_stable_ids): $ESCTXT"
  if [ -s "$NEW" ]; then echo; echo "Falhas novas (até 30 de $(wc -l < "$NEW" | tr -d ' ')):"; head -n 30 "$NEW" | jq -r . | sed 's/^/  - /'; fi
  echo; emit_table
  if [ "$LISTOK" = 1 ]; then echo; echo "Saída por lote: $LOGDIR/$DAY.bNN.out; junta: $OUT; ids reprovados (um JSON por linha; \`jq -r .\` para ler): $CUR"
  else echo; echo "Saída por lote: $LOGDIR/$DAY.bNN.out; junta: $OUT; lista de ids NÃO confiável (parcial ou ausente), não use para comparar: $CUR"; fi
} > "$REPORT"
# a linha de base só avança numa noite COMPLETA (gravação atômica; nunca com a de uma noite inerte, que falhou ou em que algum lote não rodou)
if [ "$LISTOK" = 1 ]; then cp "$CUR" "$PREV.new" && mv -f "$PREV.new" "$PREV" && echo "$DAY @$SHA" > "$PMETA" || say "WARN: não avancei a linha de base ($PREV)"
else say "WARN: lista de falhas ilegível; a linha de base ($PREV) ficou como estava"; fi
finish COMPLETO "$TOTAL testes em $NB lotes, $FAILED falhas, $ERRORS erros ($NEWTXT), pytest ${DUR}" 0
