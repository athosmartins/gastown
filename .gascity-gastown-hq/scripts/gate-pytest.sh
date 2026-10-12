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
#   repo que não é wa/ps (ex.: gascity; o repo vem do git-common-dir, nunca do NOME do diretório do worktree) · alvo que lê shared/data
#   (assinatura em linha de código; arquivo que não dá para ler fica aqui) ou casa a lista gate-pytest.force-local (lista ausente ou
#   ilegível = nada vai ao MBP, com AVISO: `lista-force-local-ilegivel`) · flag que depende do disco daqui (--junitxml, --basetemp,
#   --cov-report, --rootdir...) ou do plugin de cache (--lf --ff --nf --sw --cache-clear --cache-show --lfnf...) · caminho fora do worktree.
#   O comando daqui é `python3 -m pytest <args do revisor>` e nada além (sem -p no:cacheprovider: o plugin de cache tem de existir para as opções acima).
#
# EM QUE RESULTADO O REVISOR PODE ACREDITAR: só em verde do MBP. O MBP não tem shared/data, nem .env, nem o python3 do mini, então
#   um vermelho (ou um teste pulado) lá pode ser do AMBIENTE e não do código — dois estados que o veredito não pode confundir.
#   • rc 0 e nada pulado  → vale o MBP. É a ÚNICA forma de o MBP valer sem rodar nada aqui (o caso parcial abaixo aceita só os irmãos que não pularam), e tem um limite: um teste que lê dado por um caminho que o wrapper
#       não enxerga (constante numa lib, fixture; só `shared/data` literal no arquivo manda o alvo ficar aqui) pode passar VAZIO no MBP. O wrapper
#       não tem como saber, então DIZ: a saída traz a linha `nota: verde do MBP aceito...` (fail-open visível); o remédio é a lista force-local.
#   • rc 0 com testes pulados → os ALVOS que pularam rodam aqui de novo e o rc DAQUI vale (um skip por dado ausente não pode virar "passou"). Se só ALGUNS alvos
#       pularam, os que NÃO pularam não rodaram aqui: o verde deles foi aceito como veio do MBP, e a mesma nota sai, dizendo `SÓ para os alvos que não pularam`.
#       De quem é cada skip só se sabe pelo caminho impresso numa linha `SKIPPED [n] caminho:linha:` e ele só vale se for um alvo pedido: skip
#       vindo de um helper (pytest.skip() dentro de um módulo de apoio sai com o caminho DO HELPER), linha que não leio ou resumo que diz mais
#       pulados do que as linhas listam → não sei de quem é → TODOS os alvos rodam aqui (`skips-fora-dos-alvos` / `skips-nao-contados`).
#       Um -r próprio do revisor ou um --no-summary que apague o relato dos pulados, sem linha-resumo para conferir (-qq), também manda TODOS
#       os alvos para cá (`skips-ilegiveis`): sem relato não há como saber que nada pulou.
#       Se o alvo que pulou é um módulo inteiro pulado na coleta (pytest.importorskip no topo), rodá-lo sozinho não coleta nada e devolve 5: é esse 5 que vale,
#       mesmo com os irmãos verdes no MBP (direção conservadora: nunca um falso verde, mas não é "exatamente o comando de hoje", que daria 0).
#   • saída do MBP que NÃO se sabe ler → não sei o que ele disse, e nada dele vale: o comando inteiro roda aqui. Vale para: o `tee` que a grava falhou (disco cheio;
#       `mbp-saida-nao-gravada`), a saída veio vazia (`mbp-saida-vazia`), um grep que a lê deu erro (`mbp-saida-ilegivel`) e, sem -qq, faltou a linha-resumo "N passed in Xs"
#       que o pytest SEMPRE imprime (`saida-sem-resumo`: saída cortada ou lida pela metade). Só sob -qq, o modo normal em que a linha-resumo some, a falta dela é esperada;
#       outros jeitos de apagá-la (medidos no 9.0.3: `-q --no-summary`, `-p no:terminal`) não são lidos como -qq e caem em `saida-sem-resumo` (roda aqui).
#       Regra geral: "não consegui gravar/ler" nunca dá o mesmo resultado que "li e nada pulou".
#   • rc 1 (falhou)       → SÓ os node ids que falharam rodam aqui primeiro:
#       reprovam aqui também → vale esse rc 1 (a linha final diz `local-confirmou`);
#       PASSAM aqui isolados → isso NÃO prova que o vermelho era do ambiente (um -x/--maxfail parou o MBP no 1º vermelho e o resto nunca
#         rodou; falha de ordem ou flake; arquivo que pulou nessa mesma execução) → o comando inteiro roda aqui e o rc DELE vale (a linha
#         final diz `isolado-passou;inteiro-rc=N`). Só um vermelho que some também no comando inteiro daqui termina em rc 0.
#   • rc 1 sem ids legíveis, mais de 50 reprovados, ids que não se reconhecem aqui (rc 4/5) ou id de arquivo que não é alvo pedido
#       (`ids-fora-dos-alvos`) → o comando inteiro roda aqui.
#   • qualquer outro rc, ou MBP caiu no meio → o comando inteiro roda aqui.
#   • DIVISÃO: o que não pode ir ao MBP (lê shared/data em linha de código, está na lista force-local) roda aqui, SEPARADO, e o que
#     pode vai ao MBP; os dois rc se combinam (o pior vale; 5 só se nenhuma parte coletou teste).
#   A última linha impressa diz onde rodou e quanto levou: `gate-pytest: ran=mbp|local|mbp+local rc=N secs=N ...`.
#
# CÓDIGOS DE SAÍDA: o rc que VALE — o do pytest (de 0 a 5) ou, se o processo daqui morre ou falta o python3, o do shell (137 por sinal, 126/127).
#   Nunca 96..99: esses são do mbp-run e aqui viram "rodou aqui". 4 = uso errado.
#
# CHAVES E LOG: `touch $CITY/.gc/gate-pytest.off` desliga SÓ este caminho (o mbp-offload.on continua valendo para os workers);
#   apague para religar. Cada execução acrescenta uma linha em $CITY/.gc/logs/gate-pytest.jsonl (ts, sessão, repo, ran, motivo,
#   segundos no MBP/aqui, rc) — é o insumo do antes×depois por sessão de revisor. Se a linha não puder ser gravada, a saída traz um
#   AVISO (o rc do revisor não muda): uma execução fora do log é dita, não some da contagem em silêncio.
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
usage() { sed -n '2,/^set -o pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }   # até a linha anterior ao código: o cabeçalho pode crescer

dir="$PWD"; repo=""
while [ $# -gt 0 ]; do
  case "$1" in
    # sem valor (a opção é o ÚLTIMO argumento) o `shift 2` falha e não anda: o laço girava até o teto de 600 s do revisor. Uso errado = 4.
    --dir)  [ $# -ge 2 ] || { say "uso: --dir precisa de um valor"; exit 4; }; dir="$2"; shift 2 ;;
    --repo) [ $# -ge 2 ] || { say "uso: --repo precisa de um valor"; exit 4; }; repo="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
dir_arg="$dir"   # a mensagem abaixo cita o que o revisor passou: `dir=$(...)` falhando deixa dir VAZIO antes do `||` ler
dir=$(cd "$dir_arg" 2>/dev/null && pwd -P) || { say "uso: --dir '${dir_arg}' não é um diretório"; exit 4; }
[ $# -gt 0 ] || { say "faltam os argumentos do pytest (use -- tests/test_x.py)"; exit 4; }

# ---- separa FLAGS de ALVOS --------------------------------------------------------------------------------------------
# Flag que consome o argumento seguinte; qualquer coisa que não reconheço como alvo ou valor de flag vira "alvo ilegível" e o
# comando roda aqui (o caminho de hoje) — nunca um palpite sobre o que o revisor quis dizer.
takes_value() {
  case "$1" in
    -k|-m|-p|-c|-o|-n|-W|-r|--maxfail|--timeout|--rootdir|--tb|--durations|--durations-min|--deselect|--ignore|--ignore-glob|--confcutdir|--import-mode|--basetemp|--junitxml|--junit-xml|--capture|--color|--override-ini|--log-level|--log-file|--log-cli-level|--dist|--tx|--numprocesses|--maxprocesses|--cov|--cov-report|--html|--report-log|--resultlog|--assert|--show-capture|--timeout-method|--max-worker-restart|--randomly-seed|--reruns|--reruns-delay|--lfnf|--last-failed-no-failures) return 0 ;;
  esac
  return 1
}
local_only_flag() {   # depende do disco/estado DESTA máquina, ou é interativa
  # O plugin de cache inteiro (pytest 9.0.3: --lf --ff --nf --sw --sw-skip --sw-reset --cache-clear --cache-show --lfnf e os nomes longos) lê/escreve o .pytest_cache
  # do worktree DESTA máquina; no MBP o mbp-run.sh roda com o plugin desligado e o pytest recusa essas opções (rc 4).
  case "$1" in
    --junitxml|--junitxml=*|--junit-xml|--junit-xml=*|--basetemp|--basetemp=*|--resultlog|--resultlog=*|--html|--html=*|--report-log|--report-log=*|--cov-report|--cov-report=*|--log-file|--log-file=*|--rootdir|--rootdir=*|-c|--confcutdir|--confcutdir=*|--pyargs|--lf|--last-failed|--ff|--failed-first|--nf|--new-first|--sw|--stepwise|--sw-skip|--stepwise-skip|--sw-reset|--stepwise-reset|--cache-clear|--cache-show|--cache-show=*|--lfnf|--lfnf=*|--last-failed-no-failures|--last-failed-no-failures=*|--pdb|--trace|--pastebin|--pastebin=*) return 0 ;;
  esac
  return 1
}

user_r() {   # o revisor mexeu no que o pytest REPORTA (vence ou apaga o -rfEs que eu ponho primeiro)?
  # O -r também vem DENTRO de um grupo de flags curtas (-qqxrf = -q -q -x -r f): o argparse o lê, então eu também. Lê-se o grupo letra a letra
  # até a 1ª opção que consome o resto como valor (-k, -m, -p, -c, -o, -n, -W): em -xkr o r é parte do valor do -k, não um -r.
  # --no-summary (medido no pytest 9.0.3) tira as linhas SKIPPED e, com -qq, a linha-resumo também: o skip fica invisível. O pytest não aceita
  # abreviação de opção longa (--no-summ dá rc 4), então a igualdade basta.
  local f i c
  for f in ${flags[@]+"${flags[@]}"}; do
    case "$f" in --no-summary) return 0 ;; --*) continue ;; -?*) ;; *) continue ;; esac
    i=1
    while [ $i -lt ${#f} ]; do
      c=${f:$i:1}
      case "$c" in r) return 0 ;; k|m|p|c|o|n|W) break ;; esac
      i=$((i+1))
    done
  done
  return 1
}

user_qq() {   # o revisor pediu -qq (ou mais)? É o modo normal em que o pytest não imprime a linha-resumo "N passed in Xs" (medido no 9.0.3: -q imprime, -qq não; há outros jeitos de apagá-la,
  # `-q --no-summary` e `-p no:terminal`, que aqui NÃO contam como -qq: sem resumo e sem -qq a saída é lida como ilegível e o comando roda aqui).
  # Mesma leitura de grupo de flags curtas do user_r (-xqq = -x -q -q); o r também consome o resto do grupo como valor (-rfEs). Conta misturada com -v (-qqv) não se
  # lê com segurança: vira "não", e a falta do resumo vale como saída ilegível (o inerte: roda aqui).
  local f i c nq=0 nv=0
  for f in ${flags[@]+"${flags[@]}"}; do
    case "$f" in --quiet) nq=$((nq+1)); continue ;; --verbose) nv=$((nv+1)); continue ;; --*) continue ;; -?*) ;; *) continue ;; esac
    i=1
    while [ $i -lt ${#f} ]; do
      c=${f:$i:1}
      case "$c" in q) nq=$((nq+1)) ;; v) nv=$((nv+1)) ;; k|m|p|c|o|n|W|r) break ;; esac
      i=$((i+1))
    done
  done
  [ $nq -ge 2 ] && [ $nv -eq 0 ]
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
  # vazio / falhou (git não responde, o dir não é um repo) → repo desconhecido → cai em "repo-sem-espelho-no-mbp" e roda aqui. Só o caminho do REPO (git-common-dir)
  # conta, nunca o nome do diretório do worktree: um worktree do gascity cujo caminho cita whatsapp_automation iria por rsync para o espelho do WA.
  gc_dir=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  case "$gc_dir" in
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

# reads_shared_data <arquivo>: 0 = cita shared/data em linha de CÓDIGO · 1 = não cita · 2 = não consegui saber (o chamador deixa o alvo AQUI).
# Sem pipe de propósito: `grep -v ... | grep -q` sob `set -o pipefail` morre de SIGPIPE — o `grep -q` sai no 1º acerto enquanto o `grep -v` ainda escreve, o
# pipeline devolve 141, o `if` dá falso e "não consegui saber" lia-se como "não cita" (medido: arquivo > 64 KB com a assinatura na linha 1, 0 de 40 achados no
# macOS; 17% dos testes do WA que citam shared/data só eram achados às vezes). Aqui o grep termina sozinho e o rc dele diz o que houve: 0/1 = leu (1 = nenhuma linha
# de código sobrou), >= 2 = erro. O -a lê como texto: com um byte NUL o grep do macOS responde "Binary file matches" no lugar das linhas (medido).
# Linha de COMENTÁRIO não conta: medido no WA, um arquivo que só CITA shared/data num comentário passa em 1,2 s no MBP e levava ~20 s aqui.
reads_shared_data() {
  local body rc
  body=$(grep -a -v -E '^[[:space:]]*#' "$1" 2>/dev/null); rc=$?
  [ $rc -le 1 ] || return 2
  case "$body" in *shared/data*) return 0 ;; esac
  return 1
}

# A lista force-local é O remédio do verde vazio (runbook): ausente, ilegível ou diretório NÃO é "lista vazia". Sem ela não dá para saber o que deveria ficar aqui,
# então nada vai ao MBP (o inerte) e a falta é DITA. Uma lista que abre e não tem linhas é válida: nenhum glob casa.
FORCE_LIST_OK=0; { [ -f "$FORCE_LOCAL_LIST" ] && [ -r "$FORCE_LOCAL_LIST" ]; } && FORCE_LIST_OK=1
if [ -z "$LOCAL_REASON" ] && [ $FORCE_LIST_OK -eq 0 ]; then
  LOCAL_REASON="lista-force-local-ilegivel"
  say "AVISO: não consegui ler a lista force-local ($FORCE_LOCAL_LIST) — sem ela não sei que arquivos têm de ficar aqui, então nada vai ao MBP (rodando tudo aqui, como hoje)"
fi
if [ -z "$LOCAL_REASON" ]; then
  for t in "${targets[@]}"; do
    f="${t%%::*}"; why=""
    # Ler a lista: a última linha sem newline ainda conta (`|| [ -n "$g" ]`), e CRLF ou espaço em volta são aparados antes de comparar
    #   (uma lista mal salva não pode virar letra morta em silêncio).
    while IFS= read -r g || [ -n "$g" ]; do
      g=${g#"${g%%[![:space:]]*}"}; g=${g%"${g##*[![:space:]]}"}
      case "$g" in ''|'#'*) continue ;; esac
      # shellcheck disable=SC2254
      case "$f" in $g) why="lista-local:$g"; break ;; esac
    done < "$FORCE_LOCAL_LIST"
    # Ler o arquivo de teste: tem/não-tem/não-consegui-saber. Não consegui (não abro o arquivo, ou o grep deu erro) → fica AQUI (o inerte), nunca vai para o MBP
    #   no escuro. Quem lê dado de verdade pode passar VAZIO no MBP (sem o banco, o resultado vazio satisfaz a asserção) — é essa a classe que o MBP não pode julgar sozinho.
    if [ -z "$why" ]; then
      if [ ! -r "$dir/$f" ]; then why="alvo-ilegivel:$f"
      else
        reads_shared_data "$dir/$f"; rd=$?
        case $rd in 0) why="le-shared-data:$f" ;; 1) ;; *) why="alvo-ilegivel:$f" ;; esac
      fi
    fi
    if [ -n "$why" ]; then local_targets+=("$t"); LOCAL_NOTES="${LOCAL_NOTES}${LOCAL_NOTES:+;}$why"; else mbp_targets+=("$t"); fi
  done
  if [ ${#mbp_targets[@]} -eq 0 ]; then LOCAL_REASON="todos-ficam-aqui($LOCAL_NOTES)"
  elif [ ${#local_targets[@]} -gt 0 ]; then SPLIT=1
  fi
fi

# ---- execução ---------------------------------------------------------------------------------------------------------
T_START=$(date +%s); MBP_SECS=0; LOCAL_SECS=0; RAN=local; RC=0; DETAIL=""; GREEN_MBP=0; GREEN_PARTIAL=0
# sem arquivo temporário não dá para ler a saída do MBP (vermelho/pulado): então não vai ao MBP — roda aqui, como hoje.
OUT=$(mktemp "${TMPDIR:-/tmp}/gate-pytest.XXXXXX") || { OUT=""; [ -n "$LOCAL_REASON" ] || LOCAL_REASON="mktemp-falhou"; }
trap '[ -n "$OUT" ] && rm -f "$OUT"' EXIT

run_local() {   # <args do pytest...>: roda como o revisor rodava, no worktree dele, com o python3 dele
  # EXATAMENTE `python3 -m pytest <args>`, sem opção minha: o `-p no:cacheprovider` que o mbp-run.sh põe no MBP NÃO vem para cá. Com o plugin de cache desligado o pytest
  # recusa --lf/--ff/--nf/--sw/--cache-clear... (rc 4, "unrecognized arguments", medido no 9.0.3) e quebra quem usa `config.cache` — e essas opções
  # rodam AQUI justamente por dependerem do cache daqui. O que roda aqui tem de ser o comando de hoje, nada além.
  local t0 rc
  t0=$(date +%s)
  ( cd "$dir" && exec "$PY" -m pytest "$@" )
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
is_target_file() {   # <caminho que o pytest imprimiu>: é o ARQUIVO de um dos alvos que mandei ao MBP?
  # O que o pytest imprime em SKIPPED/FAILED/ERROR é de onde o evento saiu, não o teste que o pediu: um pytest.skip() dentro de um módulo de apoio
  # sai com o caminho do HELPER. Rodar "o arquivo que pulou" quando ele não é alvo não coleta nada (rc 5) ou roda outra coisa, e o teste que pulou
  # nunca roda aqui. Só o que eu pedi, por igualdade, vale como dono; o resto é "não sei de quem é" e o comando inteiro roda aqui.
  local t
  for t in ${mbp_targets[@]+"${mbp_targets[@]}"}; do [ "${t%%::*}" = "$1" ] && return 0; done
  return 1
}
# o comando inteiro "aqui" da parte que ia ao MBP: sem divisão é EXATAMENTE o que o revisor escreveu
run_local_mbp_part() { if [ $SPLIT -eq 1 ]; then run_local ${flags[@]+"${flags[@]}"} "${mbp_targets[@]}"; else run_local "$@"; fi; }

if [ -n "$LOCAL_REASON" ]; then
  run_local "$@"; RC=$?
  DETAIL="$LOCAL_REASON"
else
  t0=$(date +%s)
  "$MBP_RUN" --repo "$repo" --dir "$dir" -- -rfEs ${flags[@]+"${flags[@]}"} "${mbp_targets[@]}" 2>&1 | tee "$OUT"
  PST=("${PIPESTATUS[@]}")   # numa instrução só: qualquer comando entre o pipeline e esta linha apaga o PIPESTATUS
  MBP_RC=${PST[0]}
  MBP_SECS=$(( $(date +%s) - t0 ))
  # O que o `tee` gravou em $OUT é a ÚNICA fonte de "o que pulou / o que reprovou" lá. Se o tee falhou (disco cheio, quota, arquivo apagado), $OUT está vazio ou cortado, e
  # ler um registro cortado como se estivesse inteiro dá o mesmo resultado de "li e nada pulou": verde aceito sem conferir. Não sei o que o MBP disse → o inerte (rodar aqui).
  # O status do tee que não se consegue ler (PST[1] ausente) também é "não sei". 96..99 ficam de fora: o MBP nem rodou, e o comando daqui já é o de hoje.
  DISPATCH=$MBP_RC
  if [ "${PST[1]:-x}" != 0 ]; then
    case "$MBP_RC" in 96|97|98|99) ;; *) DISPATCH=saida-nao-gravada ;; esac
  fi
  case "$DISPATCH" in
    saida-nao-gravada)
      DETAIL="mbp-saida-nao-gravada;tee-rc=${PST[1]:-?};mbp-rc=$MBP_RC"
      say "não consegui gravar a saída do MBP (tee rc=${PST[1]:-?}; disco cheio?) — sem ela não sei o que pulou nem o que reprovou lá; o comando inteiro roda aqui"
      RAN=mbp+local; run_local_mbp_part "$@"; RC=$?
      ;;
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
      #   vence o meu, ou --no-summary, que o apaga, e não há resumo) → não sei se pulou: o comando inteiro roda aqui.
      #   Três estados, não dois: LI e há/não há pulados · NÃO CONSEGUI LER. O segundo nunca pode dar o resultado do primeiro "não há": cada leitura abaixo tem o rc
      #   do grep olhado (0/1 = leu, >= 2 = erro; `grep -c` que falha não imprime nada e ${x:-0} o leria como zero; `| tail` esconderia o rc do grep).
      rec_bad=""; summary=""; sk_lines=0
      if [ ! -s "$OUT" ]; then rec_bad="mbp-saida-vazia"   # rc 0 sem uma linha sequer: o pytest sempre imprime algo, então a saída se perdeu
      else
        summary=$(grep -E ' in [0-9.]+s' "$OUT"); g_sum=$?
        sk_lines=$(grep -c '^SKIPPED \[' "$OUT"); g_cnt=$?
        if [ $g_sum -gt 1 ] || [ $g_cnt -gt 1 ]; then rec_bad="mbp-saida-ilegivel"
        else
          case "$sk_lines" in ''|*[!0-9]*) rec_bad="mbp-saida-ilegivel" ;; esac
          summary=$(printf '%s\n' "$summary" | tail -1)
        fi
      fi
      sk_sum=$(printf '%s' "$summary" | grep -oE '[0-9]+ skipped' | head -1 | awk '{print $1}')
      sk_targets=(); sk_note=""
      if [ -n "$rec_bad" ]; then
        sk_note="$rec_bad"
        say "não consegui ler a saída do MBP ($rec_bad) — sem ela não sei se algo pulou; o comando inteiro roda aqui"
      elif [ -z "$summary" ] && ! user_qq; then
        # Fora do -qq o pytest SEMPRE imprime "N passed in Xs": a falta dela é saída cortada ou lida pela metade, e uma lista SKIPPED parcial deixaria os irmãos do skip perdido
        # passarem como verdes. Sem a linha-resumo também não há contagem para conferir as linhas SKIPPED.
        sk_note="saida-sem-resumo"
        say "o MBP não imprimiu a linha-resumo do pytest (só some com -qq) — saída cortada ou ilegível, não sei se algo pulou; o comando inteiro roda aqui"
      elif [ "${sk_lines:-0}" -gt 0 ] || { [ -n "$sk_sum" ] && [ "$sk_sum" != 0 ]; }; then
        # De quem é cada skip? Só o caminho de um ALVO PEDIDO é dono (is_target_file). Se UM skip não casa — pytest.skip() num helper, linha
        # SKIPPED que não leio, resumo que diz mais pulados do que as linhas listam —, "rodar os arquivos que
        # pularam" deixaria aquele teste sem rodar aqui e o rc daqui valeria como se ele tivesse rodado. Então TODOS os alvos rodam aqui.
        SK_RE='^SKIPPED \[([0-9]+)\] ([^: ]+)(:[0-9]+)?:( |$)'; SK_N_RE='^SKIPPED \[([0-9]+)\] '   # regex em variável: o bash 3.2 do dispatcher a lê igual
        sk_listed=0; sk_bad=""; skfiles=" "
        while IFS= read -r ln; do
          case "$ln" in 'SKIPPED ['*) ;; *) continue ;; esac
          if [[ "$ln" =~ $SK_RE ]]; then
            skn=${BASH_REMATCH[1]}; skp=${BASH_REMATCH[2]}
            sk_listed=$((sk_listed + skn))
            if is_target_file "$skp"; then skfiles="$skfiles$skp "; else sk_bad="skips-fora-dos-alvos"; fi
          else
            sk_bad="skips-fora-dos-alvos"
            if [[ "$ln" =~ $SK_N_RE ]]; then skn=${BASH_REMATCH[1]}; sk_listed=$((sk_listed + skn)); fi
          fi
        done < "$OUT"
        [ -n "$sk_bad" ] || { [ "${sk_sum:-0}" -le "$sk_listed" ] || sk_bad="skips-nao-contados"; }
        sk_note="${sk_bad:-skips-no-mbp}:${sk_sum:-$sk_listed}"
        if [ -n "$sk_bad" ]; then
          say "${sk_sum:-$sk_listed} teste(s) pularam no MBP e não sei de qual dos alvos cada um é (${sk_bad#skips-}) — todos os alvos rodam aqui"
        else
          say "${sk_sum:-$sk_listed} teste(s) pularam no MBP (podem ter pulado por falta de dado de lá) — os alvos que pularam rodam aqui"
          # o alvo como o revisor escreveu (node id inclusive): o arquivo inteiro traria testes que ele nem pediu
          for t in "${mbp_targets[@]}"; do
            case "$skfiles" in *" ${t%%::*} "*) sk_targets+=("$t") ;; esac
          done
        fi
      elif [ -z "$summary" ] && user_r; then
        sk_note="skips-ilegiveis"
        say "o MBP não imprimiu o resumo e o -r / --no-summary do revisor esconde os pulados — não sei se algo pulou; o comando inteiro roda aqui"
      fi
      if [ -n "$sk_note" ]; then
        [ ${#sk_targets[@]} -gt 0 ] || sk_targets=("${mbp_targets[@]}")
        RAN=mbp+local; DETAIL="$sk_note"
        # Só ALGUNS alvos pularam (sk_targets é subconjunto estrito): os irmãos que não pularam NÃO rodaram aqui, o verde deles foi aceito como veio do MBP, e a nota
        # de verde vazio (no fim) vale para eles. Sem isso, a falta da nota lia-se como "conferido" justo na forma mais comum (o MBP sem dado faz alguns arquivos pularem).
        if [ ${#sk_targets[@]} -lt ${#mbp_targets[@]} ]; then GREEN_MBP=1; GREEN_PARTIAL=1; fi
        run_local ${flags[@]+"${flags[@]}"} "${sk_targets[@]}"; RC=$?
      else
        GREEN_MBP=1   # verde aceito como veio do MBP: nada foi conferido aqui (a nota de verde vazio, no fim)
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
      # Todo id tem de ser de um ALVO PEDIDO (is_target_file, a mesma regra dos skips): um id de outro arquivo (conftest/plugin que coleta mais
      # coisa, ou uma linha que leio errado) rodado isolado aqui e "passando" não diz nada sobre o que o revisor pediu → o comando inteiro aqui.
      ids_fora=0
      while IFS= read -r id; do
        [ -n "$id" ] || continue
        is_target_file "${id%%::*}" || ids_fora=1
      done <<EOF
$ids
EOF
      if [ "$nids" -gt 50 ]; then
        say "$nids testes reprovaram no MBP — confirmar um a um não compensa; o comando inteiro roda aqui"
        DETAIL="mbp-vermelho:$nids;muitos"; run_local_mbp_part "$@"; RC=$?
      elif [ "$nids" -gt 0 ] && [ $ids_fora -eq 1 ]; then
        say "o MBP reprovou teste(s) que não são de nenhum dos alvos pedidos — não sei o que confirmar isolado; o comando inteiro roda aqui"
        DETAIL="mbp-vermelho:$nids;ids-fora-dos-alvos"; run_local_mbp_part "$@"; RC=$?
      elif [ "$nids" -gt 0 ]; then
        say "o MBP reprovou $nids teste(s) — vermelho do MBP pode ser do ambiente de lá; os node ids que falharam rodam aqui primeiro"
        while IFS= read -r id; do [ -n "$id" ] && conf+=("$id"); done <<EOF
$ids
EOF
        run_local ${flags[@]+"${flags[@]}"} "${conf[@]}"; RC=$?
        case "$RC" in
          4|5) say "os node ids do MBP não se reconhecem aqui (rc=$RC) — o comando inteiro roda aqui"
               DETAIL="mbp-vermelho:$nids;ids-ilegiveis"; run_local_mbp_part "$@"; RC=$? ;;
          # Passar isolado aqui NÃO prova que o vermelho era do ambiente, e não dá para saber qual destas foi:
          #   • -x/--maxfail: o MBP parou no 1º vermelho, então o que vinha depois nunca rodou em lugar nenhum;
          #   • falha que depende de ordem, ou flake: passa sozinha e reprova na execução inteira;
          #   • teste PULADO nesta mesma execução: o vermelho e o pulado andam juntos (faltam dado e .env), e o arquivo que pulou nunca rodou aqui.
          #   "Não sei" não vira verde: o comando inteiro roda aqui (o que o revisor rodava antes do wrapper) e o rc DELE é o que vale.
          0) say "AVISO: $nids teste(s) reprovaram no MBP e passaram aqui isolados — isso não prova que o vermelho é do ambiente (um -x/--maxfail parou o MBP no 1º vermelho; falha de ordem; teste pulado) — o comando inteiro roda aqui, e o resultado dele é o que vale"
             run_local_mbp_part "$@"; RC=$?
             DETAIL="mbp-vermelho:$nids;isolado-passou;inteiro-rc=$RC" ;;
          1) DETAIL="mbp-vermelho:$nids;local-confirmou" ;;
          # 2 interrompido, 3 erro interno, 137 morto por sinal...: o rc vale (não é verde), mas o aqui NÃO confirmou o vermelho
          *) DETAIL="mbp-vermelho:$nids;local-rc=$RC" ;;
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
# Verde do MBP aceito como veio: o MBP não tem shared/data nem .env, e um teste que lê dado por um caminho que eu não enxergo (constante numa lib,
# fixture; só a assinatura `shared/data` no arquivo manda o alvo ficar aqui) pode ter passado VAZIO lá. Eu não sei qual é, então DIGO: fail-open
# visível. Só quando um verde do MBP foi mesmo aceito (nada reconferido aqui, ao menos para um alvo) e o veredito final é verde; vem ANTES da linha final (o revisor copia a última).
if [ $GREEN_MBP -eq 1 ] && [ "$RC" = 0 ]; then
  ESCOPO="."; [ $GREEN_PARTIAL -eq 1 ] && ESCOPO=" SÓ para os alvos que não pularam (os que pularam rodaram aqui)."
  say "nota: verde do MBP aceito como veio${ESCOPO} O MBP não tem shared/data nem .env: um teste que lê dado por um caminho que o wrapper não vê (constante numa lib, fixture) pode ter passado VAZIO lá — se o código testado lê dado, trate este verde como não verificado e rode esses arquivos aqui com python3 -m pytest direto"
fi
# O log é o insumo do antes×depois: uma linha que não foi gravada some da contagem. O rc do revisor não depende dele (nunca falha por
# causa do log), mas a falta é DITA na saída, não engolida — quem lê "execuções: N" sabe que pode faltar uma.
LOG_LINE=$(printf '{"ts":"%s","session":"%s","repo":"%s","ran":"%s","rc":%s,"secs":%s,"mbp_secs":%s,"local_secs":%s,"detail":"%s","ntargets":%s}' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${GC_SESSION_NAME:-}" "${repo:--}" "$RAN" "$RC" "$SECS" "$MBP_SECS" "$LOCAL_SECS" \
  "$(printf '%s' "$DETAIL" | tr -d '"\\' | tr '\n' ' ' | cut -c1-200)" "${#targets[@]}")
{ mkdir -p "$(dirname "$LOG")" && printf '%s\n' "$LOG_LINE" >> "$LOG"; } 2>/dev/null \
  || say "AVISO: não consegui gravar $LOG — esta execução não entra no antes×depois (o resultado abaixo não muda)"
say "ran=$RAN rc=$RC secs=$SECS mbp_secs=$MBP_SECS local_secs=$LOCAL_SECS motivo=${DETAIL:--}"
exit $RC
