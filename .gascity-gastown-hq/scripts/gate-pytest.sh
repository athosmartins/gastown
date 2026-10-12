#!/usr/bin/env bash
# gate-pytest.sh — testes dirigidos do REVISOR do gate: no MacBook Pro quando ele está saudável, aqui quando não (ga-xm1jfl).
#
# Contents
#   Por quê · Uso · O que decide onde roda · Em que resultado o revisor pode acreditar · Códigos de saída · Chaves e log
#
# POR QUÊ: ~9,6 de 20,5 min de cada sessão de revisor vão em rodar/esperar teste num mini com load 40-60 (ga-bk5j8u). Os
#   mesmos testes levam ~30x menos no MBP (docs/runbooks/mbp-offload.md). O revisor roda `python3 -m pytest` num worktree
#   próprio, no scratchpad; este wrapper entra no lugar desse comando, sem mudar o que ele testa nem como lê o resultado.
#
# USO (do worktree do revisor; --dir é o padrão PWD):
#   gate-pytest.sh [--dir <worktree>] [--repo wa|ps] -- <arquivos de teste> [flags do pytest]
#   ex.: gate-pytest.sh -- tests/test_x.py tests/test_y.py::test_z -x -q
# Sempre ARQUIVOS (ou node ids) de teste: diretório, ou nenhum arquivo, roda aqui como hoje — nunca a suíte inteira no MBP.
#
# O QUE DECIDE ONDE RODA (qualquer motivo para NÃO usar o MBP cai em "rodar aqui", exatamente o comando de hoje):
#   chave .gc/gate-pytest.off · offload desligado (mbp-run rc 99) · MBP sem saúde (98) · configuração (97) · slots cheios (96) ·
#   repo que não é wa/ps (ex.: gascity) · alvo que lê shared/data (assinatura no arquivo) ou casa a lista gate-pytest.force-local ·
#   flag que depende do disco daqui (--junitxml, --basetemp, --lf, --cov-report, --rootdir...) · caminho fora do worktree.
#
# EM QUE RESULTADO O REVISOR PODE ACREDITAR: só em verde do MBP. O MBP não tem shared/data, nem .env, nem o python3 do mini, então
#   um vermelho (ou um teste pulado) lá pode ser do AMBIENTE e não do código — dois estados que o veredito não pode confundir.
#   • rc 0 e nada pulado  → vale o MBP.
#   • rc 0 com testes pulados → os ARQUIVOS que pularam rodam aqui de novo (um skip por dado ausente não pode virar "passou").
#   • rc 1 (falhou)       → SÓ os node ids que falharam rodam aqui de novo; o resultado de lá é o que vale (e é dito).
#   • rc 1 sem ids legíveis, mais de 50 reprovados, ou ids que não se reconhecem aqui (rc 4/5) → o comando inteiro roda aqui.
#   • qualquer outro rc, ou MBP caiu no meio → o comando inteiro roda aqui.
#   • DIVISÃO: o que não pode ir ao MBP (lê shared/data em linha de código, está na lista force-local) roda aqui, SEPARADO, e o que
#     pode vai ao MBP; os dois rc se combinam (o pior vale; 5 só se nenhuma parte coletou teste).
#   A última linha impressa diz onde rodou e quanto levou: `gate-pytest: ran=mbp|local|mbp+local rc=N secs=N ...`.
#
# CÓDIGOS DE SAÍDA: o rc do pytest que VALE (0..5). Nunca 96..99: esses são do mbp-run e aqui viram "rodou aqui". 4 = uso errado.
#
# CHAVES E LOG: `touch $CITY/.gc/gate-pytest.off` desliga SÓ este caminho (o mbp-offload.on continua valendo para os workers);
#   apague para religar. Cada execução acrescenta uma linha em $CITY/.gc/logs/gate-pytest.jsonl (ts, sessão, repo, ran, motivo,
#   segundos no MBP/aqui, rc) — é o insumo do antes×depois por sessão de revisor.
#   Ajustes por ambiente: GATE_PYTEST_MBP_TIMEOUT_S (420), GATE_PYTEST_PY (python3), GATE_PYTEST_FORCE_LOCAL_LIST,
#   GATE_PYTEST_MBP_RUN, GATE_PYTEST_CITY.
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CITY=${GATE_PYTEST_CITY:-${GC_CITY_PATH:-${GC_CITY:-/Users/athos/gt/.gascity-gastown-hq}}}
MBP_RUN=${GATE_PYTEST_MBP_RUN:-$HERE/mbp-run.sh}
PY=${GATE_PYTEST_PY:-python3}
OFF_FILE="$CITY/.gc/gate-pytest.off"
FORCE_LOCAL_LIST=${GATE_PYTEST_FORCE_LOCAL_LIST:-$HERE/gate-pytest.force-local}
LOG="$CITY/.gc/logs/gate-pytest.jsonl"
export MBP_RUN_TIMEOUT_S="${GATE_PYTEST_MBP_TIMEOUT_S:-${MBP_RUN_TIMEOUT_S:-420}}"

say() { printf 'gate-pytest: %s\n' "$*"; }
usage() { sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; }

dir="$PWD"; repo=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) dir="${2:-}"; shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
dir=$(cd "$dir" 2>/dev/null && pwd -P) || { say "uso: --dir '${dir}' não é um diretório"; exit 4; }
[ $# -gt 0 ] || { say "faltam os argumentos do pytest (use -- tests/test_x.py)"; exit 4; }

# ---- separa FLAGS de ALVOS --------------------------------------------------------------------------------------------
# Flag que consome o argumento seguinte; qualquer coisa que não reconheço como alvo ou valor de flag vira "alvo ilegível" e o
# comando roda aqui (o caminho de hoje) — nunca um palpite sobre o que o revisor quis dizer.
takes_value() {
  case "$1" in
    -k|-m|-p|-c|-o|-n|-W|-r|--maxfail|--timeout|--rootdir|--tb|--durations|--durations-min|--deselect|--ignore|--ignore-glob|--confcutdir|--import-mode|--basetemp|--junitxml|--junit-xml|--capture|--color|--override-ini|--log-level|--log-file|--log-cli-level|--dist|--tx|--numprocesses|--maxprocesses|--cov|--cov-report|--html|--report-log|--resultlog|--assert|--show-capture|--timeout-method|--max-worker-restart|--randomly-seed|--reruns|--reruns-delay) return 0 ;;
  esac
  return 1
}
local_only_flag() {   # depende do disco/estado DESTA máquina, ou é interativa
  case "$1" in
    --junitxml|--junitxml=*|--junit-xml|--junit-xml=*|--basetemp|--basetemp=*|--resultlog|--resultlog=*|--html|--html=*|--report-log|--report-log=*|--cov-report|--cov-report=*|--log-file|--log-file=*|--rootdir|--rootdir=*|-c|--confcutdir|--confcutdir=*|--pyargs|--lf|--last-failed|--ff|--failed-first|--nf|--new-first|--sw|--stepwise|--cache-clear|--cache-show|--pdb|--trace|--pastebin|--pastebin=*) return 0 ;;
  esac
  return 1
}

user_r() {   # o revisor trouxe o próprio -r (vence o -rfEs que eu ponho primeiro)?
  local f
  for f in ${flags[@]+"${flags[@]}"}; do case "$f" in -r|-r?*) return 0 ;; esac; done
  return 1
}

flags=(); targets=(); LOCAL_REASON=""
want_value=0
for a in "$@"; do
  if [ $want_value -eq 1 ]; then flags+=("$a"); want_value=0; continue; fi
  case "$a" in
    -*)
      flags+=("$a")
      if local_only_flag "$a" && [ -z "$LOCAL_REASON" ]; then LOCAL_REASON="flag-local:${a%%=*}"; fi
      case "$a" in *=*) ;; *) takes_value "$a" && want_value=1 ;; esac
      ;;
    *)
      p="${a%%::*}"; suffix=""; case "$a" in *::*) suffix="::${a#*::}" ;; esac
      case "$p" in /*) cand="$p" ;; *) cand="$dir/$p" ;; esac
      if [ -d "$cand" ]; then
        [ -n "$LOCAL_REASON" ] || LOCAL_REASON="alvo-diretorio"
        targets+=("$a")
      elif [ -f "$cand" ] && [ "${p%.py}" != "$p" ]; then
        absdir=$(cd "$(dirname "$cand")" 2>/dev/null && pwd -P); abs="$absdir/$(basename "$cand")"
        case "$abs" in
          "$dir"/*) targets+=("${abs#$dir/}$suffix") ;;
          *) [ -n "$LOCAL_REASON" ] || LOCAL_REASON="alvo-fora-do-worktree"; targets+=("$a") ;;
        esac
      else
        [ -n "$LOCAL_REASON" ] || LOCAL_REASON="alvo-ilegivel"
        targets+=("$a")
      fi
      ;;
  esac
done
[ ${#targets[@]} -gt 0 ] || { [ -n "$LOCAL_REASON" ] || LOCAL_REASON="sem-alvo-arquivo"; }

# ---- repo: o MBP só tem espelho de wa e ps ----------------------------------------------------------------------------
if [ -z "$repo" ]; then
  # vazio / falhou (git não responde, o dir não é um repo) → repo desconhecido → cai em "repo-sem-espelho-no-mbp" e roda aqui.
  gc_dir=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  case "$gc_dir$dir" in
    *whatsapp_automation*) repo=wa ;;
    *property_scrapers*|*property-scrapers*) repo=ps ;;
  esac
fi
case "$repo" in wa|ps) ;; *) [ -n "$LOCAL_REASON" ] || LOCAL_REASON="repo-sem-espelho-no-mbp" ;; esac

[ -n "$LOCAL_REASON" ] || { [ -f "$OFF_FILE" ] && LOCAL_REASON="chave-gate-pytest-off"; }

# ---- alvos que não valem o MBP: lista editável + quem lê shared/data -----------------------------------------------------
# Decidido ALVO a ALVO: um arquivo que fica aqui não arrasta os outros (reviewers rodam 3-5 arquivos de uma vez, e ~7% dos arquivos
# de teste do WA citam shared/data — mandar tudo para cá por causa de um jogaria fora o ganho em ~1 de cada 4 execuções).
mbp_targets=(); local_targets=(); LOCAL_NOTES=""; SPLIT=0
if [ -z "$LOCAL_REASON" ]; then
  for t in "${targets[@]}"; do
    f="${t%%::*}"; why=""
    # Ler a lista: vazio (arquivo sem linhas) → nenhum glob casa; falhou/ilegível (não abre) → a lista não vale e o alvo segue o
    #   caminho normal (ela só poupa uma ida e volta; o vermelho/pulado do MBP é conferido aqui de qualquer jeito).
    if [ -r "$FORCE_LOCAL_LIST" ]; then
      while IFS= read -r g; do
        case "$g" in ''|'#'*) continue ;; esac
        # shellcheck disable=SC2254
        case "$f" in $g) why="lista-local:$g"; break ;; esac
      done < "$FORCE_LOCAL_LIST"
    fi
    # Ler o arquivo de teste: vazio (sem a assinatura) → não lê shared/data; falhou/ilegível (não abro o arquivo) → fica AQUI
    #   (o inerte), nunca vai para o MBP no escuro. Linha de COMENTÁRIO não conta: medido no WA, um arquivo que só CITA shared/data
    #   num comentário passa em 1,2 s no MBP e levava ~20 s aqui. Quem lê dado de verdade pode passar VAZIO no MBP (sem o banco, o
    #   resultado vazio satisfaz a asserção) — é essa a classe que o MBP não pode julgar sozinho.
    if [ -z "$why" ]; then
      if [ ! -r "$dir/$f" ]; then why="alvo-ilegivel:$f"
      elif grep -v -E '^[[:space:]]*#' "$dir/$f" 2>/dev/null | grep -q 'shared/data'; then why="le-shared-data:$f"; fi
    fi
    if [ -n "$why" ]; then local_targets+=("$t"); LOCAL_NOTES="${LOCAL_NOTES}${LOCAL_NOTES:+;}$why"; else mbp_targets+=("$t"); fi
  done
  if [ ${#mbp_targets[@]} -eq 0 ]; then LOCAL_REASON="todos-ficam-aqui($LOCAL_NOTES)"
  elif [ ${#local_targets[@]} -gt 0 ]; then SPLIT=1
  fi
fi

# ---- execução ---------------------------------------------------------------------------------------------------------
T_START=$(date +%s); MBP_SECS=0; LOCAL_SECS=0; RAN=local; RC=0; DETAIL=""
# sem arquivo temporário não dá para ler a saída do MBP (vermelho/pulado): então não vai ao MBP — roda aqui, como hoje.
OUT=$(mktemp "${TMPDIR:-/tmp}/gate-pytest.XXXXXX") || { OUT=""; [ -n "$LOCAL_REASON" ] || LOCAL_REASON="mktemp-falhou"; }
trap '[ -n "$OUT" ] && rm -f "$OUT"' EXIT

run_local() {   # <args do pytest...>: roda como o revisor rodava, no worktree dele, com o python3 dele
  local t0 rc
  t0=$(date +%s)
  ( cd "$dir" && exec "$PY" -m pytest -p no:cacheprovider "$@" )
  rc=$?
  LOCAL_SECS=$(( LOCAL_SECS + $(date +%s) - t0 ))
  return $rc
}
merge_rc() {    # dois rc do pytest → o que vale: qualquer coisa fora de 0/1/5 (2 interrompido, 3 interno, 4 uso, 137 morto por sinal...) é o pior;
                # depois 1 (falhou); 5 (nada coletado) só vale se AS DUAS partes não coletaram nada — um -k que não casa numa das partes
                # é normal e não apaga o que a outra rodou; e 0.
  local r
  for r in "$1" "$2"; do case "$r" in 0|1|5) ;; *) echo "$r"; return ;; esac; done
  for r in "$1" "$2"; do [ "$r" = 1 ] && { echo 1; return; }; done
  if [ "$1" = 5 ] && [ "$2" = 5 ]; then echo 5; return; fi
  echo 0
}
# o comando inteiro "aqui" da parte que ia ao MBP: sem divisão é EXATAMENTE o que o revisor escreveu
run_local_mbp_part() { if [ $SPLIT -eq 1 ]; then run_local ${flags[@]+"${flags[@]}"} "${mbp_targets[@]}"; else run_local "$@"; fi; }

if [ -n "$LOCAL_REASON" ]; then
  run_local "$@"; RC=$?
  DETAIL="$LOCAL_REASON"
else
  t0=$(date +%s)
  "$MBP_RUN" --repo "$repo" --dir "$dir" -- -rfEs ${flags[@]+"${flags[@]}"} "${mbp_targets[@]}" 2>&1 | tee "$OUT"
  MBP_RC=${PIPESTATUS[0]}
  MBP_SECS=$(( $(date +%s) - t0 ))
  case "$MBP_RC" in
    96|97|98|99)
      DETAIL="mbp-rc=$MBP_RC: $(grep '^mbp-run:' "$OUT" | tail -1 | cut -c1-160)"
      say "o MBP não rodou (rc=$MBP_RC) — rodando aqui"
      run_local_mbp_part "$@"; RC=$?
      ;;
    0)
      RAN=mbp; RC=0
      # Pular não é passar: um teste que pulou por falta de dado do MBP (shared/data, .env) é "não sei", não "passou".
      # Ler: linhas "SKIPPED [n] arq:linha:" (o -rs que eu mesmo ponho primeiro) e a linha-resumo do pytest.
      #   vazio (nenhuma das duas) → nada pulou, SE o meu -rs valeu; falhou/ilegível (o revisor trouxe o próprio -r, que
      #   vence o meu, e não há resumo) → não sei se pulou: o comando inteiro roda aqui.
      summary=$(grep -E ' in [0-9.]+s' "$OUT" | tail -1)
      sk_lines=$(grep -c '^SKIPPED \[' "$OUT")
      sk_sum=$(printf '%s' "$summary" | grep -oE '[0-9]+ skipped' | head -1 | awk '{print $1}')
      sk_targets=(); sk_note=""
      if [ "${sk_lines:-0}" -gt 0 ] || { [ -n "$sk_sum" ] && [ "$sk_sum" != 0 ]; }; then
        sk_note="skips-no-mbp:${sk_sum:-$sk_lines}"
        say "${sk_sum:-$sk_lines} teste(s) pularam no MBP (podem ter pulado por falta de dado de lá) — os arquivos que pularam rodam aqui"
        skfiles=$(sed -n 's/^SKIPPED \[[0-9]*\] \([^:][^:]*\):[0-9][0-9]*:.*/\1/p' "$OUT" | sort -u)
        if [ -n "$skfiles" ]; then
          while IFS= read -r sf; do [ -n "$sf" ] && [ -f "$dir/$sf" ] && sk_targets+=("$sf"); done <<EOF
$skfiles
EOF
        fi
      elif [ -z "$summary" ] && user_r; then
        sk_note="skips-ilegiveis"
        say "o MBP não imprimiu o resumo e o -r do revisor esconde os pulados — não sei se algo pulou; o comando inteiro roda aqui"
      fi
      if [ -n "$sk_note" ]; then
        [ ${#sk_targets[@]} -gt 0 ] || sk_targets=("${mbp_targets[@]}")
        RAN=mbp+local; DETAIL="$sk_note"
        run_local ${flags[@]+"${flags[@]}"} "${sk_targets[@]}"; RC=$?
      fi
      ;;
    1)
      # Quais reprovaram: linhas "FAILED|ERROR <node id> - msg".
      #   vazio (nenhuma linha) → "não sei quais" (rc 1 diz que algo falhou), NUNCA "nada falhou": o comando inteiro roda aqui;
      #   falhou/ilegível (node id que não resolve aqui, ou lista longa demais) → idem, o comando inteiro roda aqui.
      ids=$(sed -n -E 's/^(FAILED|ERROR) (.*)$/\2/p' "$OUT" | sed 's/ - .*$//' | sort -u)
      nids=$(printf '%s' "$ids" | grep -c . )
      RAN=mbp+local
      conf=()
      if [ "$nids" -gt 50 ]; then
        say "$nids testes reprovaram no MBP — confirmar um a um não compensa; o comando inteiro roda aqui"
        DETAIL="mbp-vermelho:$nids;muitos"; run_local_mbp_part "$@"; RC=$?
      elif [ "$nids" -gt 0 ]; then
        say "o MBP reprovou $nids teste(s) — vermelho do MBP pode ser do ambiente de lá; os node ids que falharam rodam aqui, e o resultado daqui é o que vale"
        while IFS= read -r id; do [ -n "$id" ] && conf+=("$id"); done <<EOF
$ids
EOF
        run_local ${flags[@]+"${flags[@]}"} "${conf[@]}"; RC=$?
        case "$RC" in
          4|5) say "os node ids do MBP não se reconhecem aqui (rc=$RC) — o comando inteiro roda aqui"
               DETAIL="mbp-vermelho:$nids;ids-ilegiveis"; run_local_mbp_part "$@"; RC=$? ;;
          0) DETAIL="mbp-vermelho:$nids;local-NAO-confirmou"
             say "AVISO: $nids teste(s) reprovaram no MBP e PASSARAM aqui — vale o daqui (rc=0); a diferença é de ambiente" ;;
          *) DETAIL="mbp-vermelho:$nids;local-confirmou" ;;
        esac
      else
        say "o MBP reprovou mas não consegui ler quais testes — o comando inteiro roda aqui"
        DETAIL="mbp-vermelho;sem-ids"; run_local_mbp_part "$@"; RC=$?
      fi
      ;;
    *)
      DETAIL="mbp-rc=$MBP_RC"
      say "o MBP devolveu rc=$MBP_RC (não é verde nem vermelho de teste) — o comando inteiro roda aqui"
      RAN=mbp+local; run_local_mbp_part "$@"; RC=$?
      ;;
  esac
  if [ $SPLIT -eq 1 ]; then
    say "ficam aqui (não vão ao MBP): $LOCAL_NOTES"
    [ "$RAN" = mbp ] && RAN=mbp+local
    run_local ${flags[@]+"${flags[@]}"} "${local_targets[@]}"; LRC=$?
    RC=$(merge_rc "$RC" "$LRC")
    DETAIL="${DETAIL:+$DETAIL;}split:$LOCAL_NOTES"
  fi
fi
SECS=$(( $(date +%s) - T_START ))
mkdir -p "$(dirname "$LOG")" 2>/dev/null
printf '{"ts":"%s","session":"%s","repo":"%s","ran":"%s","rc":%s,"secs":%s,"mbp_secs":%s,"local_secs":%s,"detail":"%s","ntargets":%s}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${GC_SESSION_NAME:-}" "${repo:--}" "$RAN" "$RC" "$SECS" "$MBP_SECS" "$LOCAL_SECS" \
  "$(printf '%s' "$DETAIL" | tr -d '"\\' | tr '\n' ' ' | cut -c1-200)" "${#targets[@]}" >> "$LOG" 2>/dev/null || true
say "ran=$RAN rc=$RC secs=$SECS mbp_secs=$MBP_SECS local_secs=$LOCAL_SECS motivo=${DETAIL:--}"
exit $RC
