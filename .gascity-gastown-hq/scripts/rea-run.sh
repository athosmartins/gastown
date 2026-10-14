#!/usr/bin/env bash
# rea-run.sh — roda um comando PESADO de REA (rea, jadx, ghidra...) sem derrubar a máquina: MBP primeiro; no mini só com
#   trava de 1 execução, folga de disco/swap e scratch apagado no fim.
#
# Contents
#   Por quê · Uso · Códigos de saída · Como funciona · Limites conhecidos · O que NÃO faz
#
# POR QUÊ (programa REA, épico ga-oe7o1p; ga-szz40p): REA abre Chrome/Ghidra/JVM e o mini vive no limite (11/10: swap alto,
#   disco crítico). As regras do programa — 10 GB livres, swap até 6 GB, nenhum outro `rea` ao mesmo tempo, capturas em scratch
#   apagado no fim — ficam aqui em código, em vez de depender de cada sessão lembrar.
#
# USO
#   rea-run.sh [--local] [--wait-s N] [--push P]... [--pull REL:LOCAL]... [--env K=V]... -- <comando> [args]
#        (sem --local: tenta o MBP via `mbp-run.sh --exec` e só cai para o mini nos códigos 96..99 dele; --push copia P para
#         ./in/ do scratch, --pull traz REL do scratch para LOCAL antes da limpeza, --env exporta K=V ao comando. Para
#         redirecionar saída use `-- sh -c 'rea ... > out.json'`.)
#   rea-run.sh --check          # mostra disco, swap e outro `rea` e sai (0 pode rodar · 92 sem folga · 93 não consegui ler)
#
#   --local é OBRIGATÓRIO quando o comando fala com algo do mini (o Chrome descartável em 127.0.0.1:$PORT do recon web da
#   skill rea-scraper-first): no MBP esse endereço não existe. APK, Electron, nativo e Ghidra são o caso do MBP.
#
# CÓDIGOS DE SAÍDA — o código do comando é propagado; os abaixo são do próprio wrapper (a mensagem `rea-run:` no stderr e o
#   campo "reason" do log dizem qual foi). O código do comando passa COMO VEIO: se ele mesmo sair com 91..94 ou 96..99, colide
#   com os do wrapper (no MBP, um comando que saia 96..99 pode ser lido como "rode local" e rodar de novo no mini). O "reason" do
#   log desambigua: "-" = o comando rodou e saiu com esse código; qualquer outro valor = o wrapper.
#   0..90   código do comando (MBP ou mini)
#   91      esperou o orçamento (--wait-s, padrão 1800 s) e a trava ou outro `rea` continuou ocupando (se a trava era órfã mas
#           o mutex de remoção não abriu, a mensagem diz — ver "Limites conhecidos")
#   92      RECUSADO: sem folga — disco livre < 10 GB ou swap usado > 6144 MB (ou, em --check, outro `rea` rodando)
#   93      não consegui olhar ou preparar: df/sysctl/pgrep ilegível, trava ou scratch não criáveis, configuração inválida,
#           ou o comando saiu 0 mas um --pull pedido falhou (o resultado não chegou; no MBP o mbp-run sai 0 e só avisa, então
#           o wrapper confere o destino). É o terceiro estado: "não sei" NUNCA vira "pode rodar", e "não veio" nunca vira rc 0.
#           (Se o comando já saiu != 0, esse rc é mantido e o log marca pull-falhou.) Número de configuração só vale decimal
#           sem sinal, sem zero à esquerda, até 12 dígitos (08/010 seriam lidos como octal pela aritmética do bash).
#   94      uso errado (sem comando, opção desconhecida, --pull com caminho absoluto ou `..`, --push que não existe ou dois
#           --push com o mesmo nome)
#   124     o comando passou de REA_RUN_TIMEOUT_S (padrão 3600 s) e foi encerrado
#   128+n   o wrapper recebeu o sinal n; o comando e seus filhos foram encerrados e o scratch apagado
#
# COMO FUNCIONA
#   MBP: `mbp-run.sh --exec ... -- cmd` (chave, saúde do MBP, slot e limpeza do scratch remoto são dele). rc 96..99 → mini.
#        ATENÇÃO: o rc 98 também sai quando o ssh cai NO MEIO da execução; nesse caso o comando pode já ter rodado (em parte)
#        no MBP e roda de novo no mini. Use só comando de leitura/recon (idempotente), que é o caso do REA.
#        --pull no MBP: o destino é conferido por identidade (inode+ctime+tamanho; mtime não serve, o rsync -a copia o do
#        MBP) e "não mudou" vira 93/pull-falhou. Limite: pull de arquivo byte-idêntico que o rsync pulou lê como "não chegou" —
#        apague o destino antigo antes de pedir de novo.
#   mini: (1) checa disco/swap já de cara (não vale esperar a trava para ser recusado depois) → (2) pega a trava
#        (mkdir atômico em $CITY/.gc/run/rea-run.lock; dono = pid + hora de início do processo, gravado por `ln`, que é
#        criação EXCLUSIVA e nunca sobrescreve o dono de outro; dono PROVADAMENTE morto ou com outro início (pid
#        reaproveitado) é reaped, sob mutex — ver "Remoção da trava"; dono que não se consegue ler/provar NÃO é reaped — ver
#        "Três estados") e espera até --wait-s → (3) espera não haver outro `rea` rodando (rodado por fora do
#        wrapper; só processo `node .../bin/rea` conta, não o texto "bin/rea" no argumento de outro processo) → (4) checa disco/swap DE NOVO, já sob a trava → (5) apaga scratch órfão de execução que morreu →
#        (6) cria scratch 0700 fora de qualquer repo → (7) roda o comando com cwd = scratch, nice 10, timeout e
#        $REA_RUN_SCRATCH → (8) --pull → (9) apaga o scratch (também em erro, timeout, INT/TERM/HUP) e solta a trava.
#   Remoção da trava (reap de órfã e release do dono; ga-szz40p gate-fix 2, cobre ga-qm9q1b): "esta trava é velha" e "então movo
#        o caminho" eram dois passos sobre um NOME — entre eles outro processo podia remover a MESMA trava velha e criar uma nova,
#        VIVA, no mesmo caminho, e o `mv` levava a viva (dois comandos pesados ao mesmo tempo). Agora toda remoção roda sob um
#        mutex do kernel (`lockf` num fd aberto em $CITY/.gc/run/rea-run.lock.reap; o kernel o solta sozinho se quem o segura
#        morrer, SIGKILL inclusive — não há "trava da trava" que também precise de reap) e o veredito é REFEITO DENTRO do mutex:
#        só remove se a trava que está no caminho AGORA ainda é órfã. O release do dono entra no mesmo mutex e só apaga a
#        trava se o dono gravado nela ainda é este pid. O julgamento de fora do mutex é só palpite, para não pegá-lo à toa.
#        Sem `lockf`, sem poder abrir o arquivo do mutex ou com ele ocupado além de REA_RUN_REAP_WAIT_S (5 s): NÃO remove — é o
#        estado inerte; a espera segue até --wait-s e acaba em 91, com o motivo na mensagem.
#   Identidade do dono (ga-szz40p gate-fix 4): o dono grava a hora de início do processo (`ps -o lstart=`) e quem chega compara a
#        STRING. Ela muda com o TZ e o locale de quem chama o ps (o mesmo pid dá "Tue Oct 13 06:24:05 2026", "Tue Oct 13 09:24:05
#        2026" sob TZ=UTC e "ter 13 out 06:24:05 2026" sob LC_ALL=pt_BR.UTF-8): um 2º chamador de env diferente lia "início
#        diferente" = pid reaproveitado, removia a trava de um dono VIVO e rodava um 2º comando pesado ao mesmo tempo. O proc_start
#        fixa LC_ALL=C TZ=UTC, então gravar e ler sempre concordam, seja qual for o env de cada um. Mesma família, mesma correção: o
#        `sysctl vm.swapusage` também é lido com LC_ALL=C (sob pt_BR ele imprime "3015,31M" e o parser o recusava: 93 com a máquina
#        saudável). Varredura da classe: não há outra string comparada entre processos neste script; `df -Pk`, `stat` (mtime da trava),
#        `date +%s`, o estado/ppid do `ps` e o awk só leem inteiros, que o env não muda; o único resíduo é cosmético (a casa decimal
#        de machine_msg, só na mensagem).
#   Três estados (ga-szz40p gate-fix 5): "tenho", "não tenho" e "não consegui descobrir" não podem virar a mesma coisa. Havia duas
#        quedas do 3º no 2º: (a) `lock_state` lia o dono com `sed 2>/dev/null` — arquivo que EXISTE mas não abre (chmod 000, falta de
#        fd) saía vazio, igual a "sem dono", e a IDADE da pasta o declarava órfão: a trava de um dono VIVO era removida e rodava um 2º
#        comando pesado; (b) `alive` dava "morto" para qualquer `ps` sem saída — o `ps` que falhou apagava o scratch de uma execução
#        viva (varredura) e fazia o `stop_tree` declarar "nada a matar", soltando a trava com a árvore ainda rodando. Agora:
#        * trava com arquivo `owner` (ou symlink com esse nome) cujo pid/início não saem ambos válidos, ou pasta sem permissão de
#          busca = `unknown`: inerte — espera, e acaba em 91 com `pid ?` na mensagem. A idade só julga a trava SEM arquivo de dono;
#        * `alive` devolve 0 vivo, 1 morto, 2 não sei. Só vale "morto" o `ps` que respondeu zumbi ou o "No such process" do
#          `kill -0` (o "Operation not permitted" de outro usuário é VIVO); `lock_state` usa a mesma prova depois que o ps não
#          deu a hora de início. Quem lê 2 não apaga, não reapa e não dá a árvore por morta (o `stop_tree` espera, manda KILL e avisa).
#        Para sair de uma trava `unknown` que ninguém mais segura: confira que não há `rea-run.sh` vivo e remova a pasta à mão
#        (`rm -r $CITY/.gc/run/rea-run.lock`); o wrapper não a remove por conta própria, de propósito.
#   Scratch órfão: o nome carrega o pid de quem o criou (run.<pid>.XXXXXX; marcador de timeout tmo.<pid>, fora da trava). O passo 5
#        só apaga o de pid MORTO: pid vivo, nome sem pid e symlink ficam. Não depende de a trava ter dado exclusividade.
#   Log: $CITY/.gc/logs/rea-run.jsonl — um evento por execução (ran), recusa/espera esgotada (refused), desvio para o mini
#        (fallback) ou execução cortada por sinal (signal), só o NOME do comando e o nº de argumentos (argumentos podem carregar
#        URL/segredo). Uso errado (94), configuração inválida (93) e --check NÃO gravam log: só o stderr.
#
# LIMITES CONHECIDOS (o que sobra depois da correção — janelas estreitas, não fechadas):
#   - Dono gravado e LEGÍVEL com início diferente do processo vivo, ou processo morto: a remoção é exata (veredito e `mv` sob o mesmo
#     mutex, e só quem está sob o mutex remove ou solta). "Dono vivo nunca é removido" vale enquanto o dono se LÊ e o ps/kill
#     respondem; dono que existe e não se lê, ou liveness sem prova, é `unknown` (inerte, 91) — o custo é uma trava presa até alguém
#     a remover à mão, nunca um 2º comando pesado. Não há janela entre julgar e agir para uma trava com dono lido.
#   - `ps` ilegível: o watchdog de timeout só age sobre quem provou ser filho direto (ppid lido); sem o ppid ele sai SEM matar e AVISA
#     (`não consegui ler o ppid`): o comando segue além do timeout até terminar (a trava continua presa por ele: lado seguro). A varredura do `self_chain` com ps
#     falho vê menos ancestrais e conta mais "outro rea" (espera/91), nunca menos. `pgrep -P` que falha deixa de listar os
#     filhos de um pid: o `stop_tree` avisa (`não consegui listar os filhos`) e pode não alcançar os descendentes dele.
#   - Trava SEM dono (quem fez o mkdir parou/morreu antes de gravar): só é julgada órfã pela idade (REA_RUN_LOCK_ORPHAN_S, 30 s).
#     O criador que só volta a andar depois disso encontra a trava removida: se ninguém a refez, sai 93 "trava-sem-dono" (recusa
#     espúria, nada roda); se outro a refez, a gravação por `ln` falha e ele espera como os demais — nunca toma nem apaga a trava
#     do outro. Resta uma janela de microssegundos: o criador parado >30 s que falha a gravação faz `rmdir` fora do mutex, e
#     um reaper que julgou essa mesma trava vazia como órfã logo antes pode levar a trava nova que outro criou no mesmo caminho.
#   - Mutex de remoção ocupado por mais de REA_RUN_REAP_WAIT_S (quem o segura está parado, p.ex. SIGSTOP) ou `lockf` ausente:
#     ninguém remove órfã e as execuções esperam até 91. O release do dono também desiste (avisa) e a trava fica para a próxima
#     execução remover (dono morto).
#   - O release cai num caminho já trocado por outro dono (a trava dele foi removida e refeita): não apaga, avisa.
#   - Troca de versão: o dono gravado por uma versão ANTERIOR a esta (hora no TZ/locale de quem a gravou) lido por esta (UTC/C) parece
#     pid reaproveitado. Vale só para a execução que estiver viva no instante do deploy; depois dela, todo dono é gravado no formato fixo.
#   - pid reaproveitado: o scratch de um pid morto cujo número hoje é de outro processo fica até aquele processo sair (sobra lixo,
#     nunca perda). SIGKILL entre o `mv` da trava velha e o `find -delete` deixa `rea-run.lock.stale.<pid>` ao lado (lixo inerte).
#
# O QUE NÃO FAZ: não classifica o que é "pesado" (quem chama decide); não repassa o stdin ao comando que roda no mini (ele roda com stdin=/dev/null);
#   não mata Chrome que o comando deixou vivo fora da árvore dele; SIGKILL no wrapper não limpa — o scratch órfão (de pid morto) é apagado na próxima execução (passo 5) e a trava
#   morta é reaped pela próxima execução, sob o mutex.
set -o pipefail
set -u

CITY=${REA_RUN_CITY:-${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}}
MBP_RUN=${REA_RUN_MBP_RUN:-$CITY/scripts/mbp-run.sh}
LOG="$CITY/.gc/logs/rea-run.jsonl"
LOCK_DIR=${REA_RUN_LOCK_DIR:-$CITY/.gc/run/rea-run.lock}
REAP_LOCK="$LOCK_DIR.reap"   # arquivo do mutex de remoção da trava (lockf no fd 8; o kernel solta se o dono morrer)
SCRATCH_ROOT=${REA_RUN_SCRATCH_ROOT:-${TMPDIR:-/tmp}/rea-run-$(id -u)}
SCRATCH_ROOT=${SCRATCH_ROOT//\/\//\/}
DF_BIN=${REA_RUN_DF:-df}
DF_PATH=${REA_RUN_DF_PATH:-/System/Volumes/Data}
SYSCTL_BIN=${REA_RUN_SYSCTL:-sysctl}
PGREP_BIN=${REA_RUN_PGREP:-pgrep}
# "outro rea" = processo node cujo script é .../bin/rea (ou scripts/rea.mjs). Ancorado no início da linha de comando: o texto
# "bin/rea " dentro do argumento de outro processo (um `claude -p` com esta regra no prompt, um `sh -c echo`) NÃO conta, senão
# a trava de "nenhum outro rea" ficaria presa para sempre. O `pgrep -fl 'bin/rea '` solto do programa casa esses falsos e
# perde `node bin/rea` sem argumentos.
PGREP_PATTERN=${REA_RUN_PGREP_PATTERN:-'^[^ ]*node( --[^ ]+)* [^ ]*(/bin/rea|/scripts/rea\.mjs)( |$)'}
MIN_FREE_GB=${REA_RUN_MIN_FREE_GB:-10}
MAX_SWAP_MB=${REA_RUN_MAX_SWAP_MB:-6144}
WAIT_S=${REA_RUN_WAIT_S:-1800}
RUN_TIMEOUT=${REA_RUN_TIMEOUT_S:-3600}
POLL_S=${REA_RUN_POLL_S:-1}
KILL_GRACE_S=${REA_RUN_KILL_GRACE_S:-3}
LOCK_ORPHAN_S=${REA_RUN_LOCK_ORPHAN_S:-30}   # trava sem arquivo de dono mais velha que isto: quem a criou morreu entre o mkdir e a escrita
REAP_WAIT_S=${REA_RUN_REAP_WAIT_S:-5}   # espera máxima pelo mutex de remoção da trava (quem o segura o faz por milissegundos)
LOCKF_BIN=${REA_RUN_LOCKF:-lockf}
PS_BIN=${REA_RUN_PS:-ps}   # proc_start, alive e o ppid do watchdog passam por aqui: costura de teste (o selftest alarga a janela "julguei velha" → "ajo")
NICE=${REA_RUN_NICE:-10}
umask 077

exec 3>&2   # o stderr de verdade: o `wait` do comando roda com o fd 2 em /dev/null (cala o "Terminated" do bash) e engolia os avisos do handler de sinal
say() { printf 'rea-run: %s\n' "$*" >&3; }
usage() { sed -n '2,/^[^#]/{/^#/p;}' "$0" | sed 's/^# \{0,1\}//' >&2; }
# inteiro decimal sem sinal, até 12 dígitos. Vazio, texto, "1.5", sinal e ZERO À ESQUERDA NÃO são número: `[ 08 -ge 0 ]` passa, mas a
# aritmética do bash lê 08 como octal (erro) e 010 como 8 — o disco "sem folga" virava "com folga". 12 dígitos é o teto para a
# conta GB→KB (x 1048576) caber em int64. Na dúvida, "não é número" = o estado inerte (93, não roda).
isnum() { [ "${#1}" -le 12 ] && case "$1" in ''|*[!0-9]*|0?*) return 1 ;; esac; }   # gate:isnum

# ---- log ---------------------------------------------------------------------------------------------------------
CMD_NAME="-"; NARGS=0; T_START=$(date +%s); M_FREE_KB=""; M_SWAP_MB=""; M_REASON=""
nulljson() { if isnum "$1"; then printf '%s' "$1"; else printf 'null'; fi; }   # ilegível grava null, nunca 0
log_event() { # evento modo rc motivo
  local freegb="null"
  isnum "$M_FREE_KB" && freegb=$(( M_FREE_KB / 1048576 ))
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  printf '{"ts":"%s","event":"%s","mode":"%s","rc":%s,"secs":%s,"reason":"%s","cmd":"%s","nargs":%s,"free_gb":%s,"swap_mb":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$(( $(date +%s) - T_START ))" "$4" "$CMD_NAME" "$NARGS" "$freegb" "$(nulljson "$M_SWAP_MB")" \
    >> "$LOG" 2>/dev/null || say "AVISO: evento '$1' NÃO gravado em $LOG"
}
die() { # rc motivo mensagem — motivo é um token [a-z:_-] (vai para o log)
  say "$3"; log_event refused "${MODE:-local}" "$1" "$2"; exit "$1"
}

# ---- argumentos --------------------------------------------------------------------------------------------------
force_local=0; mode=run; MODE=local
pushes=(); pulls=(); envs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --wait-s|--push|--pull|--env) [ $# -ge 2 ] || { say "$1 precisa de um valor"; usage; exit 94; } ;;   # gate:opt-sem-valor
  esac
  case "$1" in
    --local) force_local=1; shift ;;
    --check) mode=check; shift ;;
    --wait-s) WAIT_S="${2:-}"; shift 2 ;;
    --push) pushes+=("${2:-}"); shift 2 ;;
    --pull) pulls+=("${2:-}"); shift 2 ;;
    --env) envs+=("${2:-}"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) say "opção desconhecida: $1"; usage; exit 94 ;;
    *) break ;;
  esac
done

for v in MIN_FREE_GB MAX_SWAP_MB WAIT_S RUN_TIMEOUT KILL_GRACE_S LOCK_ORPHAN_S REAP_WAIT_S NICE; do
  isnum "${!v}" || { say "configuração inválida: $v='${!v}' não é inteiro decimal >= 0 (sem zero à esquerda, até 12 dígitos)"; exit 93; }
done
printf '%s' "$POLL_S" | grep -Eq '^[0-9]+(\.[0-9]+)?$' && [ "$(printf '%s' "$POLL_S" | tr -d '0.')" != "" ] \
  || { say "configuração inválida: REA_RUN_POLL_S='$POLL_S' (número > 0)"; exit 93; }
[ "$RUN_TIMEOUT" -ge 1 ] || { say "configuração inválida: REA_RUN_TIMEOUT_S=0 mataria o comando na hora (use >= 1)"; exit 93; }

# ---- leitura da máquina ------------------------------------------------------------------------------------------
# 0 = há folga · 92 = recusa (M_REASON diz o quê) · 93 = não consegui ler (M_REASON = ilegivel:*)
machine_check() {
  local out kb n need_kb
  M_FREE_KB=""; M_SWAP_MB=""; M_REASON=""
  out=$("$DF_BIN" -Pk "$DF_PATH" 2>/dev/null) || { M_REASON="ilegivel:disco"; return 93; }
  kb=$(printf '%s\n' "$out" | awk 'NR==2{print $4}')
  isnum "$kb" || { M_REASON="ilegivel:disco"; return 93; }                                    # gate:ilegivel-disco
  M_FREE_KB=$kb
  out=$(LC_ALL=C "$SYSCTL_BIN" -n vm.swapusage 2>/dev/null) || { M_REASON="ilegivel:swap"; return 93; }   # gate:sysctl-env — sob pt_BR/de_DE ele imprime "3015,31M"
  n=$(printf '%s' "$out" | awk '{ for (i = 1; i < NF; i++) if ($i == "used" && $(i+1) == "=") v = $(i+2)
        if (v ~ /^[0-9]+(\.[0-9]+)?[KMG]$/) { u = substr(v, length(v)); x = substr(v, 1, length(v) - 1) + 0
          if (u == "G") x *= 1024; else if (u == "K") x /= 1024; printf "%d", x } }')
  isnum "$n" || { M_REASON="ilegivel:swap"; return 93; }                                      # gate:ilegivel-swap
  M_SWAP_MB=$n
  need_kb=$(( MIN_FREE_GB * 1048576 ))
  [ "$M_FREE_KB" -lt "$need_kb" ] && M_REASON="disco-baixo"                                    # gate:disk
  [ "$M_SWAP_MB" -gt "$MAX_SWAP_MB" ] && M_REASON="${M_REASON:+$M_REASON+}swap-alto"          # gate:swap
  [ -z "$M_REASON" ] && return 0
  return 92
}
machine_msg() { printf 'disco livre %s GB (mínimo %s) · swap usado %s MB (máximo %s)' \
  "$(if isnum "$M_FREE_KB"; then awk -v k="$M_FREE_KB" 'BEGIN{printf "%.1f", k/1048576}'; else printf '?'; fi)" "$MIN_FREE_GB" \
  "${M_SWAP_MB:-?}" "$MAX_SWAP_MB"; }

self_chain() { # este processo e seus ancestrais: a linha de comando deles pode conter 'bin/rea ' sem ser outro rea
  local p=$$ out="" i=0
  while isnum "$p" && [ "$p" -gt 1 ] && [ $i -lt 64 ]; do out="$out $p"; p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' '); i=$(( i + 1 )); done
  printf '%s' "$out"
}
OTHERS=""
others_check() { # 0 = nenhum outro rea · 1 = há outro (OTHERS) · 2 = não consegui olhar
  local out rc p chain
  OTHERS=""
  out=$("$PGREP_BIN" -f "$PGREP_PATTERN" 2>/dev/null); rc=$?
  case $rc in 0) ;; 1) return 0 ;; *) return 2 ;; esac                                         # gate:ilegivel-pgrep
  [ -n "$out" ] || return 2   # rc 0 diz "achei", saída vazia diz "não achei": incoerente = não sei
  chain=" $(self_chain) "                                                                      # gate:self-chain
  for p in $out; do
    isnum "$p" || return 2
    case "$chain" in *" $p "*) ;; *) OTHERS="$OTHERS $p" ;; esac
  done
  [ -z "$OTHERS" ] && return 0
  return 1
}

if [ "$mode" = check ]; then
  machine_check; mrc=$?
  others_check; orc=$?
  printf 'rea-run: %s · outro rea: %s\n' "$(machine_msg)" "$( [ $orc -eq 0 ] && echo nenhum || { [ $orc -eq 1 ] && echo "sim (pid$OTHERS)" || echo 'ilegível'; } )"
  [ $mrc -eq 93 ] && { say "não consegui ler: $M_REASON"; exit 93; }
  [ $orc -eq 2 ] && { say "não consegui ler: pgrep"; exit 93; }
  [ $mrc -ne 0 ] && { say "RECUSADO: $M_REASON"; exit 92; }
  [ $orc -eq 1 ] && { say "RECUSADO: outro rea rodando"; exit 92; }
  exit 0
fi

[ $# -gt 0 ] || { say "faltou o comando (use -- <comando>)"; usage; exit 94; }
CMD_NAME=$(printf '%s' "$(basename -- "$1")" | tr -c 'A-Za-z0-9._-' '_'); NARGS=$(( $# - 1 ))
seen_push=$'\n'
for p in "${pushes[@]+"${pushes[@]}"}"; do
  [ -n "$p" ] && [ -e "$p" ] || { say "--push '$p' não existe"; exit 94; }
  b=$(basename -- "$p")
  case "$seen_push" in *$'\n'"$b"$'\n'*) say "--push '$p': outro --push já usa o nome '$b' (um sobrescreveria o outro em ./in/)"; exit 94 ;; esac   # gate:push-dup
  seen_push="$seen_push$b"$'\n'
done
for pl in "${pulls[@]+"${pulls[@]}"}"; do
  rel=${pl%%:*}; dest=${pl#*:}
  [ "$rel" != "$pl" ] && [ -n "$rel" ] && [ -n "$dest" ] || { say "--pull '$pl' precisa ser REL:LOCAL"; exit 94; }
  case "$rel" in /*|..|../*|*/..|*/../*) say "--pull '$rel': use caminho relativo ao scratch, sem '..'"; exit 94 ;; esac
done
for kv in "${envs[@]+"${envs[@]}"}"; do
  case "$kv" in [A-Za-z_]*=*) ;; *) say "--env '$kv' precisa ser K=V"; exit 94 ;; esac
  case "${kv%%=*}" in *[!A-Za-z0-9_]*) say "--env '$kv': nome inválido"; exit 94 ;; esac
done

# ---- caminho 1: MBP ------------------------------------------------------------------------------------------------
# O mbp-run só AVISA ("pull de X falhou") quando o rsync do pull falha e sai com o rc do comando (0): o rc dele não diz se o
# resultado chegou. Então conferimos o destino: assinatura (inode ctime tamanho) antes e depois. NÃO é mtime: o `rsync -a`
# copia o mtime do MBP, e relógio atrasado de lá faria pull bom parecer velho. Arquivo trocado por rename muda inode+ctime;
# diretório com entrada trocada muda ctime. "ilegivel" = existe mas não consegui ler: sem prova de que chegou.
pull_sig() { # "absent" | "ilegivel" | "inode ctime tamanho"
  local s
  if { s=$(stat -c '%i %.9Z %s' -- "$1" 2>/dev/null) || s=$(stat -f '%i %Fc %z' -- "$1" 2>/dev/null); } \
     && printf '%s' "$s" | grep -Eq '^[0-9]+ [0-9.]+ [0-9]+$'; then printf '%s' "$s"
  elif [ -e "$1" ] || [ -L "$1" ]; then printf 'ilegivel'
  else printf 'absent'; fi
}
pull_arrived() { # antes depois — 0 = o destino mudou desde antes do mbp-run
  case "$2" in absent|ilegivel) return 1 ;; esac
  [ "$1" != ilegivel ] && [ "$1" != "$2" ]
}

if [ $force_local -eq 0 ] && [ ! -x "$MBP_RUN" ]; then
  say "mbp-run.sh ausente ou sem permissão de execução ($MBP_RUN) — rodando no mini"; log_event fallback mbp 0 "mbp-run-ausente"
fi
if [ $force_local -eq 0 ] && [ -x "$MBP_RUN" ]; then
  margs=(--exec)
  for p in "${pushes[@]+"${pushes[@]}"}"; do margs+=(--push "$p"); done
  pull_before=()
  for pl in "${pulls[@]+"${pulls[@]}"}"; do margs+=(--pull "$pl"); pull_before+=("$(pull_sig "${pl#*:}")"); done
  for kv in "${envs[@]+"${envs[@]}"}"; do margs+=(--env "$kv"); done
  "$MBP_RUN" "${margs[@]}" -- "$@"; rc=$?
  case $rc in
    96|97|98|99) say "MBP indisponível (mbp-run rc=$rc) — rodando no mini$([ $rc -eq 98 ] && printf ' (rc 98 também sai com o ssh caindo no meio: o comando pode já ter rodado, em parte, no MBP)')"
                 log_event fallback mbp "$rc" "mbp-rc-$rc" ;;   # gate:fallback
    *) MODE=mbp; pull_missing=""; i=0
       for pl in "${pulls[@]+"${pulls[@]}"}"; do
         rel=${pl%%:*}; dest=${pl#*:}
         pull_arrived "${pull_before[$i]}" "$(pull_sig "$dest")" \
           || { say "pull de '$rel' falhou — não há prova de que o resultado chegou em '$dest' (destino ausente, igual ao de antes ou ilegível)"; pull_missing="$pull_missing $rel"; }
         i=$(( i + 1 ))
       done
       if [ -n "$pull_missing" ]; then log_event ran mbp "$rc" "pull-falhou"; [ "$rc" -eq 0 ] && rc=93; exit $rc; fi   # gate:pull-mbp
       log_event ran mbp "$rc" "-"; exit $rc ;;
  esac
fi
MODE=local

# ---- caminho 2: mini -----------------------------------------------------------------------------------------------
DEADLINE=$(( $(date +%s) + WAIT_S ))
LOCK_HELD=0; SCR=""; CHILD=""; WD=""; SIGRC=""; TMO=""

# alive PID → 0 = vivo · 1 = morto (inclusive zumbi) · 2 = não sei. "O ps não devolveu nada" NÃO é "morreu": é o mesmo vazio de um ps que
# falhou (fork, EMFILE, sandbox). Só vale como "morto" a prova do kernel — o "No such process" do kill -0; responder, ou negar por permissão
# (pid de outro usuário), é vivo. Quem decide ler 2 como "não consegui provar que morreu" e ficar do lado inerte (não apaga, não dá por morto).
# Custo, com o ps cego: um filho que já morreu e ainda não foi colhido (zumbi) responde ao `kill -0`, então o stop_tree espera a graça inteira.
alive() {
  local s kerr
  s=$("$PS_BIN" -o state= -p "$1" 2>/dev/null)
  if [ -n "$s" ]; then [ "${s#Z}" = "$s" ] && return 0; return 1; fi
  kerr=$(LC_ALL=C kill -0 "$1" 2>&1) && return 0                                          # gate:alive-kill0
  case "$kerr" in
    *"No such process"*) return 1 ;;
    *"not permitted"*) return 0 ;;                                                        # gate:alive-eperm
    *) return 2 ;;                                                                        # gate:alive-unknown
  esac
}
tree_pids() { # o pid e, recursivamente, os filhos. `pgrep -P` sai 1 sem filhos e >1 quando FALHOU: lista incompleta, e avisa (roda em $(...): só o stderr chega)
  local c kids rc
  printf '%s\n' "$1"
  kids=$(pgrep -P "$1" 2>/dev/null); rc=$?
  [ $rc -gt 1 ] && say "AVISO: não consegui listar os filhos do pid $1 (pgrep -P falhou, rc $rc) — os descendentes dele podem seguir vivos"   # gate:tree-pgrep
  for c in $kids; do tree_pids "$c"; done
}
stop_tree() { # TERM na árvore, espera KILL_GRACE_S, KILL no que sobrou — só dá a árvore por morta com a PROVA de que morreu
  local pids p i a unsure=""
  pids=$(tree_pids "$1")
  for p in $pids; do kill -TERM "$p" 2>/dev/null; done
  i=0; while [ $i -lt $(( KILL_GRACE_S * 5 )) ]; do
    local any=0; for p in $pids; do alive "$p"; [ $? -ne 1 ] && any=1; done                # gate:stop-proof
    [ $any -eq 0 ] && return 0
    sleep 0.2; i=$(( i + 1 ))
  done
  for p in $pids; do
    alive "$p"; a=$?
    [ $a -eq 1 ] && continue
    kill -KILL "$p" 2>/dev/null
    [ $a -eq 2 ] && unsure="$unsure $p"
  done
  [ -z "$unsure" ] || say "AVISO: não consegui provar que o(s) pid$unsure morreu(ram) (o estado do processo não se lê) — mandei KILL assim mesmo"
  return 0
}

rm_scratch() { # só remove diretório run.* DENTRO da raiz de scratch, e nunca por symlink
  local d=$1 real root
  [ -e "$d" ] || [ -L "$d" ] || return 0
  [ ! -L "$d" ] || { say "AVISO: $d é symlink — NÃO removido"; return 1; }
  root=$(cd "$SCRATCH_ROOT" 2>/dev/null && pwd -P) || { say "AVISO: raiz $SCRATCH_ROOT ilegível — $d NÃO removido"; return 1; }
  real=$(cd "$d" 2>/dev/null && pwd -P) || { say "AVISO: $d ilegível — NÃO removido"; return 1; }
  case "$real" in "$root"/run.*) ;; *) say "AVISO: $real fora de $root/run.* — NÃO removido"; return 1 ;; esac
  chmod -R u+w "$real" 2>/dev/null
  find "$real" -depth -delete 2>/dev/null                                                       # gate:cleanup
  if [ -e "$real" ]; then say "AVISO: scratch $real NÃO foi apagado por inteiro"; return 1; fi
  return 0
}

owner_field() { sed -n "${1}p" "$LOCK_DIR/owner" 2>/dev/null; }
# A hora de início é o que identifica o dono entre PROCESSOS: quem grava e quem lê precisam ver a MESMA string. `ps lstart` muda com o TZ e o
# locale de quem o chama ("Tue Oct 13 06:24:05 2026" / "... 09:24:05 ..." sob TZ=UTC / "ter 13 out 06:24:05 2026" sob pt_BR); por isso o env é fixo aqui.
proc_start() { LC_ALL=C TZ=UTC "$PS_BIN" -o lstart= -p "$1" 2>/dev/null | sed 's/  */ /g;s/^ //;s/ $//'; }   # gate:proc-start-env
# Remoção da trava — reap de órfã e release do dono — roda SEMPRE sob um mutex do kernel e re-julga DENTRO dele. "Esta trava é velha" e
# "então movo $LOCK_DIR" são dois passos sobre um NOME: entre eles outro processo pode ter removido a MESMA trava velha e criado uma nova,
# VIVA, no mesmo caminho, e o `mv` levaria a viva (dois comandos pesados ao mesmo tempo). O mutex é `lockf` num fd aberto em $REAP_LOCK:
# o kernel o solta sozinho se quem o segura morrer (sem "trava da trava" que também precisasse de reap). O veredito de fora do mutex é só
# palpite, para não pegá-lo à toa. Sem lockf, sem o arquivo ou com o mutex ocupado além de REAP_WAIT_S: NÃO remove (é o estado inerte).
reap_mutex_enter() { # 0 = tenho o mutex (fd 8 aberto) · 1 = não consegui (fd 8 fechado)
  { exec 8>>"$REAP_LOCK"; } 2>/dev/null || return 1
  if "$LOCKF_BIN" -s -t "$REAP_WAIT_S" 8 2>/dev/null; then return 0; fi                          # gate:reap-mutex
  exec 8>&-; return 1
}
reap_mutex_leave() { exec 8>&-; }
REAP_NOTE=""
reap_stale() { # 0 = removi a trava órfã · 1 = não removi (viva, já refeita por outro, ou sem o mutex)
  local tmp="$LOCK_DIR.stale.$$" rc=1
  reap_mutex_enter || { REAP_NOTE=" (órfã, mas o mutex de reap não abriu em ${REAP_WAIT_S}s — não removo às cegas)"; return 1; }
  REAP_NOTE=""
  if [ "$(lock_state)" = stale ]; then                                                           # gate:reap-rejudge
    if mv "$LOCK_DIR" "$tmp" 2>/dev/null; then
      find "$tmp" -mindepth 1 -delete 2>/dev/null; rmdir "$tmp" 2>/dev/null; rc=0
    fi
  fi
  reap_mutex_leave
  return $rc
}
release_lock() {
  [ $LOCK_HELD -eq 1 ] || return 0
  LOCK_HELD=0
  # Sem o mutex a trava FICA: este processo vai sair, o dono morto a torna órfã e a próxima execução a remove.
  reap_mutex_enter || { say "AVISO: sem o mutex de reap — a trava $LOCK_DIR fica para a próxima execução remover (dono morto)"; return 0; }
  if [ "$(owner_field 1)" = "$$" ]; then                                                         # gate:release-owner
    find "$LOCK_DIR" -mindepth 1 -delete 2>/dev/null; rmdir "$LOCK_DIR" 2>/dev/null || say "AVISO: trava $LOCK_DIR NÃO foi solta"
  else
    say "AVISO: a trava já não é minha — não solto"
  fi
  reap_mutex_leave
}
cleanup() {
  [ -n "$CHILD" ] && stop_tree "$CHILD"
  [ -n "$WD" ] && stop_tree "$WD"
  CHILD=""; WD=""
  if [ -n "$SCR" ]; then rm_scratch "$SCR" || log_event cleanup-failed local 0 "scratch-nao-apagado"; SCR=""; fi
  if [ -n "$TMO" ]; then rm -f -- "$TMO"; TMO=""; fi
  release_lock
}
on_signal() { # nome número — mensagem no stderr de verdade (fd 3) e UM evento no log: a execução cortada por sinal também deixa rastro
  say "recebi SIG$1 — encerrando o comando e limpando"; SIGRC=$(( 128 + $2 ))
  log_event signal "$MODE" "$SIGRC" "sinal-$(printf '%s' "$1" | tr 'A-Z' 'a-z')"                    # gate:sinal-log
  exit "$SIGRC"
}
trap cleanup EXIT   # gate:exit-trap — roda também quando o bash morre por sinal; os 3 traps abaixo só dão a mensagem e o rc 128+n
trap 'on_signal INT 2' INT
trap 'on_signal TERM 15' TERM
trap 'on_signal HUP 1' HUP

# "Não há dono" e "há um dono que não consegui ler" são coisas DIFERENTES, e só a primeira autoriza julgar a trava pela idade (quem fez o mkdir
# morreu antes de gravar). A segunda — o arquivo do dono existe (ou é um symlink com esse nome) mas o `sed` falhou (permissão, EMFILE, fork), ou o
# conteúdo não é um dono, ou a pasta da trava não tem permissão de busca (aí nem `-e owner` enxerga o arquivo) — é "não sei": a trava é tratada
# como de dono vivo. O dono é gravado por `ln` de um arquivo completo, então um dono ilegível nunca é uma gravação pela metade. Só testes de
# arquivo do próprio bash: nenhum fork que possa falhar e virar "sem dono".
owner_unreadable() { # 0 = pode haver um dono que não li · 1 = não há arquivo de dono
  [ -x "$LOCK_DIR" ] || return 0                                                          # gate:lock-searchable
  [ -e "$LOCK_DIR/owner" ] || [ -L "$LOCK_DIR/owner" ]                                    # gate:owner-symlink
}
owner_pid() { local p; p=$(owner_field 1); if isnum "$p"; then printf '%s' "$p"; else printf '?'; fi; }   # "?" quando o dono não se lê
lock_state() { # stale | live | unknown  — quem segura a trava agora
  local pid started cur age kerr
  pid=$(owner_field 1); started=$(owner_field 3)
  if ! isnum "$pid" || [ -z "$started" ]; then
    if owner_unreadable; then echo unknown; return; fi                                    # gate:owner-unreadable
    age=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0) ))
    [ "$age" -gt "$LOCK_ORPHAN_S" ] 2>/dev/null && [ "$age" -lt 1000000000 ] && { echo stale; return; }
    echo unknown; return
  fi
  cur=$(proc_start "$pid")
  if [ -n "$cur" ]; then [ "$cur" = "$started" ] && echo live || echo stale; return; fi   # gate:lock-live — outro início = pid reaproveitado
  # O ps não devolveu a hora de início: o processo não existe OU o ps falhou (os dois dão o mesmo vazio). Só o "No such process" do kill prova
  # que morreu; responder, ou negar por permissão, é vivo; qualquer outra falha do kill é "não sei" (inerte).
  kerr=$(LC_ALL=C kill -0 "$pid" 2>&1) && { echo live; return; }                          # gate:lock-kill0
  case "$kerr" in
    *"No such process"*) echo stale ;;
    *"not permitted"*) echo live ;;                                                       # gate:lock-eperm
    *) echo unknown ;;                                                                    # gate:lock-unknown
  esac
}
claim_owner() { # $1 = hora de início deste processo. Grava o dono SÓ se a trava ainda não tem um: `ln` é criação exclusiva e atômica
  local tmp="$LOCK_DIR/owner.tmp.$$" rc   # (o `mv` sobrescreveria o dono de outro — o que acontece com quem ficou parado entre o mkdir e aqui)
  { printf '%s\n%s\n%s\n' "$$" "$(date +%s)" "$1" > "$tmp" && ln "$tmp" "$LOCK_DIR/owner"; } 2>/dev/null; rc=$?   # gate:owner-claim
  rm -f "$tmp" 2>/dev/null
  return $rc
}
acquire_lock() {
  local last_msg=0 st now me_start vanished=0
  me_start=$(proc_start $$)   # sem a hora de início não há como provar que o dono segue vivo: a trava seria reaped com a gente dentro
  [ -n "$me_start" ] || die 93 "ilegivel:ps" "não consegui ler a hora de início deste processo (ps) — não pego a trava às cegas"
  mkdir -p "$(dirname "$LOCK_DIR")" 2>/dev/null || die 93 "trava-nao-criavel" "não consigo criar $(dirname "$LOCK_DIR")"
  while :; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then                                                      # gate:lock
      claim_owner "$me_start" && { LOCK_HELD=1; return 0; }
      # Não gravei o dono. Se já há um dono nesta trava, perdi: a minha foi removida enquanto eu estava parado e outro a refez.
      # Não apago nada que não seja meu: espero como os demais. Sem dono nenhum, a falha é real (disco cheio, permissão): rmdir
      # (nunca recursivo — só leva um diretório vazio) e recusa.
      [ -e "$LOCK_DIR/owner" ] && continue                                                      # gate:owner-lost
      rmdir "$LOCK_DIR" 2>/dev/null
      die 93 "trava-sem-dono" "não consegui gravar o dono da trava em $LOCK_DIR"
    fi
    if [ ! -d "$LOCK_DIR" ]; then   # o mkdir falhou porque existia e sumiu logo depois (dono soltou): tenta de novo, não é erro
      vanished=$(( vanished + 1 ))
      [ "$vanished" -gt 20 ] && die 93 "trava-nao-criavel" "não consigo criar a trava $LOCK_DIR"   # gate:lock-vanish
      continue
    fi
    st=$(lock_state)
    if [ "$st" = stale ] && reap_stale; then
      say "trava órfã removida (dono morto ou pid reaproveitado)"; continue
    fi
    now=$(date +%s)
    [ "$now" -ge "$DEADLINE" ] && die 91 "trava-ocupada" "esperei ${WAIT_S}s e a trava segue com pid $(owner_pid)${REAP_NOTE} — tente depois"
    if [ $(( now - last_msg )) -ge 60 ]; then say "aguardando a trava (dono pid $(owner_pid), desde $(owner_field 2))${REAP_NOTE}"; last_msg=$now; fi
    sleep "$POLL_S"
  done
}
wait_others() {
  local last_msg=0 now orc
  while :; do
    others_check; orc=$?
    [ $orc -eq 0 ] && return 0
    [ $orc -eq 2 ] && die 93 "ilegivel:pgrep" "não consegui olhar se há outro rea (pgrep falhou)"
    now=$(date +%s)
    [ "$now" -ge "$DEADLINE" ] && die 91 "outro-rea" "esperei ${WAIT_S}s e há outro rea rodando (pid$OTHERS) — tente depois"
    if [ $(( now - last_msg )) -ge 60 ]; then say "aguardando outro rea terminar (pid$OTHERS)"; last_msg=$now; fi
    sleep "$POLL_S"
  done
}
refuse_machine() { # $1 = rc de machine_check
  if [ "$1" -eq 93 ]; then die 93 "$M_REASON" "não consegui ler a máquina ($M_REASON) — não rodo às cegas"; fi
  die 92 "$M_REASON" "RECUSADO ($M_REASON): $(machine_msg) — libere espaço/swap e tente de novo"
}

machine_check; mrc=$?; [ $mrc -eq 0 ] || refuse_machine $mrc
acquire_lock
wait_others
machine_check; mrc=$?; [ $mrc -eq 0 ] || refuse_machine $mrc

mkdir -p "$SCRATCH_ROOT" 2>/dev/null && chmod 700 "$SCRATCH_ROOT" 2>/dev/null || die 93 "scratch-nao-criavel" "não consigo criar $SCRATCH_ROOT"
# Órfão = o nome carrega o pid de quem o criou (run.<pid>.XXXXXX, tmo.<pid>) e esse pid MORREU. A trava garante que só uma execução
# está aqui, mas o apagamento não depende disso: scratch de execução viva nunca é apagado, nem se duas execuções se atropelarem.
# Nome sem pid ("não sei de quem é") também fica: apagar sem saber é o lado irreversível. Custo: um pid reaproveitado por outro
# processo mantém o scratch do morto até aquele processo sair — sobra lixo, nunca perda.
for old in "$SCRATCH_ROOT"/run.* "$SCRATCH_ROOT"/tmo.*; do
  [ -e "$old" ] || [ -L "$old" ] || continue
  base=${old##*/}; opid=${base#*.}; opid=${opid%%.*}
  isnum "$opid" || { say "AVISO: $old não traz o pid de quem o criou — não apago"; continue; }
  alive "$opid"; ar=$?                                                                            # 1 = prova de que morreu; 0 e 2 (não sei) NÃO apagam
  if [ $ar -ne 1 ]; then                                                                          # gate:orphan-live
    [ $ar -eq 2 ] && say "AVISO: não consegui ler se o pid $opid vive — não apago $old"
    continue
  fi
  case "$base" in
    tmo.*) rm -f -- "$old" ;;
    *) say "scratch órfão $old — apagando"; rm_scratch "$old" || log_event cleanup-failed local 0 "orfao-nao-apagado" ;;
  esac
done
SCR=$(mktemp -d "$SCRATCH_ROOT/run.$$.XXXXXX") || die 93 "scratch-nao-criavel" "mktemp falhou em $SCRATCH_ROOT"
# marcador de timeout fora do cwd do comando e FORA da trava: o watchdog escreve aqui, só este processo lê
TMO="$SCRATCH_ROOT/tmo.$$"; : > "$TMO" || die 93 "scratch-nao-criavel" "não consegui criar o marcador de timeout $TMO"   # gate:timeout-private
if [ ${#pushes[@]} -gt 0 ]; then
  mkdir "$SCR/in" || die 93 "scratch-nao-criavel" "não consegui criar $SCR/in"
  for p in "${pushes[@]}"; do cp -R -- "$p" "$SCR/in/" || die 93 "push-falhou" "push de $p falhou"; done
fi

( cd "$SCR" && export REA_RUN_SCRATCH="$SCR" REA_RUN_MODE=local && exec env ${envs[@]+"${envs[@]}"} nice -n "$NICE" "$@" ) &
CHILD=$!
( left=$RUN_TIMEOUT
  while [ "$left" -gt 0 ]; do
    step=$(( left < 30 ? left : 30 )); sleep "$step"
    kill -0 "$$" 2>/dev/null || exit 0   # o wrapper morreu (SIGKILL): ninguém limpa, e o pid de CHILD pode já ser de outro processo
    left=$(( left - step ))
  done
  alive "$CHILD"; [ $? -eq 1 ] && exit 0                                                            # CHILD já saiu (zumbi inclusive); "não sei" segue para a prova do ppid
  wppid=$("$PS_BIN" -o ppid= -p "$CHILD" 2>/dev/null | tr -d ' ')
  if [ -z "$wppid" ]; then                                                                          # gate:timeout-ppid
    alive "$CHILD"; [ $? -eq 1 ] && exit 0                                                          # saiu entre uma leitura e outra
    say "AVISO: não consegui ler o ppid do pid $CHILD (ps) — não provo que é o comando e NÃO o corto pelo timeout de ${RUN_TIMEOUT}s; ele segue até terminar"
    exit 0
  fi
  [ "$wppid" = "$$" ] || exit 0                                                                     # lido e é de outro: o pid foi reaproveitado
  echo 1 > "$TMO"; stop_tree "$CHILD" ) &                                                        # gate:timeout
WD=$!
RC=0
{ wait "$CHILD"; RC=$?; } 2>/dev/null
CHILD=""
stop_tree "$WD"; { wait "$WD"; } 2>/dev/null; WD=""
if [ -s "$TMO" ]; then RC=124; say "timeout de ${RUN_TIMEOUT}s — comando encerrado"; fi

PULL_FAILED=""
for pl in "${pulls[@]+"${pulls[@]}"}"; do
  rel=${pl%%:*}; dest=${pl#*:}
  cp -R -- "$SCR/$rel" "$dest" 2>/dev/null || { say "pull de '$rel' falhou — o resultado NÃO chegou em '$dest'"; PULL_FAILED="$PULL_FAILED $rel"; }
done

if [ -n "$PULL_FAILED" ]; then
  log_event ran local "$RC" "pull-falhou"
  [ "$RC" -eq 0 ] && RC=93   # o comando saiu 0 mas o que o chamador pediu de volta não veio: rc 0 diria que veio
  exit $RC
fi
log_event ran local "$RC" "-"
exit $RC
