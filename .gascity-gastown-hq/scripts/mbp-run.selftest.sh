#!/usr/bin/env bash
# mbp-run.selftest.sh — hermético: ssh/rsync são stubs no PATH; nada toca o MBP nem o live.
#
# Contents
#   Casos · Preflight de saúde (ga-9e2rjh) · Presença do Athos (ga-77c1qg) · Controle negativo
#
# CASOS: off(99) · inalcançável(98) · RAM baixa(98) · bateria baixa(98) · slots cheios(96) ·
#   slot de dono morto é reaped · rc do remoto propagado e logado · ssh 255 no meio(98) · nota de shared/data ·
#   slot liberado ao fim · exec: push/pull + limpeza do scratch · uso errado(97) · base ausente(97).
# PREFLIGHT DE SAÚDE (ga-9e2rjh): o stub do ssh EXECUTA o script remoto de verdade (sob bash 3.2 quando existe /bin/bash,
#   como no MBP) com vm_stat/sysctl/pmset/memory_pressure falsos — o que se testa é o parsing real, não uma saída enlatada.
#   swap ALTO mas parado passa (o defeito: 5.248 MB recusou com 3,8 GB de RAM livre) · teto absoluto do swap · swap que
#   CRESCE recusa (fronteira 128/129) · swap encolhendo passa · pressão 2/4 recusa · pressão/swap/RAM ILEGÍVEL recusa com
#   motivo próprio ("ilegivel:*"), nunca igual a "baixo" (inclui pmset ilegível: não vira "bateria") · "1.50G" lido como 1536 · page size vem do cabeçalho do vm_stat ·
#   cada recusa vira UMA linha no log com motivo e números · --check/--seed não logam recusa · a contagem de 72 h do
#   mbp-offload.sh (counts): sem log / vazio / por motivo / fora da janela, e linha ilegível AVISADA (nunca omitida).
#   MBP_OFFLOAD_UNDER_TEST=<script> roda os casos da contagem contra outro mbp-offload.sh.
# CONTROLE NEGATIVO: cada porta do preflight é removida do script (sed no marcador "# gate:<nome>") e o mutante TEM que
#   deixar de reproduzir o (rc, motivo) do script real — prova que o teste enxerga o defeito, inclusive "ilegível virou baixo".
# PRESENÇA DO ATHOS (ga-77c1qg): a biblioteca mbp-presence.sh roda de verdade (ioreg/plutil/pmset falsos, plist no formato REAL do
#   ioreg): bloqueada vence input recente · 599 s não é fora e 600 s é · app segurando a tela segura o "fora" · cada leitura que falha
#   cai em "uso", nunca em "livre" · só dá para forçar PIORAR (nunca forçar "livre"). mbp-run: teto de slots por modo (núcleos, RAM,
#   1 em uso, total e não só números baixos), pausa (local e no MBP) rc 99 antes da saúde, seed em fundo, e a execução SUPERVISIONADA
#   rodando de verdade sob bash com python/taskpolicy/renice falsos: prioridade na largada, rebaixamento no meio da execução quando o
#   Athos volta ou pausa, sem atrasar o fim da execução nem deixar processo para trás. mbp-offload: modos do status, tarefas órfãs,
#   JSON, total do dia (sob cada jq), pause/resume. gascity-mbp (mbp-controle.sh). MBP_SELFTEST_ONLY=presenca|chave roda só essa parte;
#   HOST (ga-bmmxka; MBP_SELFTEST_ONLY=host roda só esta parte): sem MBP_HOST o ssh vai ao nome do Tailscale, nunca ao .local; a LAN só com a porta 22 dela respondendo
#   e a do Tailscale muda; nada respondeu = Tailscale; MBP_HOST do chamador vale como está e nunca é sondado (a sonda é um stub: nada toca a rede).
#   MBP_SELFTEST_SKIP=presenca pula a presença (a suíte antiga, sozinha, cabe nos 900 s do prod test do ga-9e2rjh).
# NÓ LINUX (ga-zri39b; MBP_SELFTEST_ONLY=node roda só esta parte): a cadeia nó -> MBP -> local com os códigos 96..99 (nó fora, sem RAM, base/venv ausentes, slots cheios,
#   ssh que cai no meio) e a bandeira própria do nó (independe do mbp-offload.on e da pausa do Athos) · o preflight do nó roda DE VERDADE contra um /proc falso
#   (MemAvailable, SwapTotal/SwapFree e crescimento, PSI → níveis 1/2/4, disco, núcleos; ilegível ≠ baixo) · SEGURANÇA: o rsync REAL com os argumentos do mbp-run, contra uma árvore
#   com .duckdb/.db/.csv/.env/segredo/data/shared/logs e nomes de credencial (.pdpj_token.txt, .netrc, token.txt, secrets.json, *.keystore, formato desconhecido .zip) plantados
#   (dentro e fora de tests/) — nada chega, e o código de nome parecido (pdpj_token.py, test_pdpj_token_*.py) chega; o que uma semeadura antiga deixou é apagado; controles negativos
#   (sem --filter, filtro com a ordem errada sem a conferência, filtro só-denylist sem a conferência, a lista por EXTENSÃO da 1ª correção, sem o node_guard) VAZAM e são pegos ·
#   NOME NEUTRO (docs/**/ab_results/*.json, scripts/*estado.json, state.json...) com telefone/CPF dentro não chega; config listada por caminho chega · CONTEÚDO: node_guard retém, mesmo em nome e
#   pasta liberados, o arquivo com LISTA de telefones (>=20) ou CPFs (>=3), deixa passar 3 números e cauda sintética, e SEM a varredura (hetzner-pii-scan.py) o nó NÃO é usado · arquivo que a varredura não lê, ou caminho retido com barra invertida que a regra `- /caminho` não segura (conferido por um 2º rsync -n), também: o nó NÃO é usado ·
#   filtro ausente, vazio, fora de ordem, sem o `- *` final, sem uma regra-âncora, com `+` que inclua tudo (`+ /**`...), `!` ou `.` = o nó NÃO é usado.
#   FATIA 2: lista mac-only (glob, node id, caminho absoluto, comentário/CRLF, aprendida; ausente ou ilegível = o nó NÃO é usado) · xdist (limiar, núcleos/baterias, o -n
#   do chamador vence, xdist ausente/ilegível) · sombra (igual, diverge por rc e por arquivo, MBP fora, MBP lento, janela de 24 h, abortada; rc de ambiente 124/137/127/97 de qualquer lado, ou saída de um lado que não abre = `skipped`, nada aprendido; a mensagem só diz "marcado" do que foi gravado).
#   FATIA 4: semeadura (MBP_SELFTEST_ONLY=semeadura roda só esta parte): o node_guard também vale na semeadura (lista de telefones fica no mini; sem o scanner = não semeia), freeze do venv sem pacote do macOS, hash que decide reinstalar, uv que falha,
#   dry-run (o comando remoto roda de verdade: o uv que falha dá 98, o `| tail` não engole o status), e a auditoria do destino: NOME (token incluso), arquivo > 4 MB, JWT e CONTEÚDO (lista de telefones/CPFs) = ALARME rc 98
#   (e manda desligar o nó); auditoria que não consegue olhar = 98, nunca 'limpo'; auditoria que ACHOU e caiu antes de terminar = ALARME, não 'não consegui olhar'; hash que não se calculou (shasum falha, ou lixo)
#   = 97, no nó e no caminho do MBP, nunca "já batem" (controle negativo: o mutante sem hash_valid volta ao defeito).
# MBP_RUN_UNDER_TEST=<script> roda a mesma bateria contra outro mbp-run.sh (ex.: o antigo, para ver os testes novos falharem).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="${MBP_RUN_UNDER_TEST:-$HERE/mbp-run.sh}"
T=$(mktemp -d "${TMPDIR:-/tmp}/mbp-selftest.XXXXXX")
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
mkdir -p "$T/bin" "$T/fake" "$T/city/.gc/logs" "$T/wt/tests"
: > "$T/wt/tests/test_x.py"

# stub ssh: lê o script do stdin, decide pelo marcador "# MBP:<NOME>" e pelo STUB_* do ambiente.
# PREFLIGHT executa o script recebido (stdin) com as ferramentas falsas de $FAKE na frente do PATH; STUB_PF_RAW injeta a
# saída crua no lugar (para testar só o lado local: campo vazio, número com lixo...).
cat > "$T/bin/ssh" <<'EOF'
#!/usr/bin/env bash
args="$*"
[ -z "${STUB_ARGS_LOG:-}" ] || echo "$args" >> "$STUB_ARGS_LOG"   # ga-bmmxka: qual host o mbp-run escolheu
# qual host é o destino: o nó Linux (hetzner-teste) ou o MBP. Cada caso liga a falha que quer por host (STUB_*_NODE / STUB_*_MBP).
case "$args" in *hetzner-teste*) host=hetzner ;; *) host=mbp ;; esac
if [ "${STUB_UNREACHABLE:-0}" = 1 ]; then exit 255; fi
if [ "$host" = hetzner ] && [ "${STUB_UNREACHABLE_NODE:-0}" = 1 ]; then exit 255; fi
if [ "$host" = mbp ] && [ "${STUB_UNREACHABLE_MBP:-0}" = 1 ]; then exit 255; fi
case "$args" in *"bash -s"*) s=$(cat); name=$(printf '%s' "$s" | sed -n '1s/^# MBP://p') ;; *) name="DIRECT"; s="" ;; esac
echo "$name" >> "$STUB_LOG"
echo "HOSTCALL:$host:$name" >> "$STUB_LOG"
[ "$name" = DIRECT ] || printf '%s\n' "$s" > "$(dirname "$STUB_LOG")/last-script-$name-$host.sh"
# HOME falso: a biblioteca de presença e a listagem de tarefas leem $HOME/gt-remote (PAUSE, slots/) no "MBP"
rexec() { printf '%s\n' "$s" | HOME="$STUB_HOME" PATH="$FAKE:$PATH" STUB_REAL_SLEEP="${1:-0}" "$STUB_REMOTE_BASH" -s -- ${2:-}; }
# /proc falso do nó Linux, gerado a cada chamada a partir de STUB_N_* (raiz em $STUB_PROCDIR, passada ao script remoto como 2º argumento)
mkproc() {
  local d="$STUB_PROCDIR"; mkdir -p "$d/pressure"
  if [ -n "${STUB_N_MEMINFO_RAW:-}" ]; then printf '%b\n' "$STUB_N_MEMINFO_RAW" > "$d/meminfo"
  else printf 'MemTotal:       32000000 kB\nMemFree:        1000000 kB\nMemAvailable:   %s kB\nSwapTotal:      %s kB\nSwapFree:       %s kB\n' \
    "$(( ${STUB_N_AVAIL_MB:-24000} * 1024 ))" "$(( ${STUB_N_SWAPTOTAL_MB:-0} * 1024 ))" "$(( ${STUB_N_SWAPFREE_MB:-0} * 1024 ))" > "$d/meminfo"; fi
  if [ "${STUB_N_PSI_MISSING:-0}" = 1 ]; then rm -f "$d/pressure/memory"
  elif [ -n "${STUB_N_PSI_RAW:-}" ]; then printf '%b\n' "$STUB_N_PSI_RAW" > "$d/pressure/memory"
  else printf 'some avg10=%s avg60=0.00 avg300=0.00 total=1\nfull avg10=%s avg60=0.00 avg300=0.00 total=1\n' "${STUB_N_PSI_SOME:-0.00}" "${STUB_N_PSI_FULL:-0.00}" > "$d/pressure/memory"; fi
  echo "0.50 0.40 0.30 1/200 12345" > "$d/loadavg"
}
case "$name" in
  PREFLIGHT)
    if [ "$host" = hetzner ]; then
      if [ -n "${STUB_PF_RAW_NODE:-}" ]; then printf '%b\n' "$STUB_PF_RAW_NODE"; else
        rm -f "$STUB_SWAPCNT"; sample=""
        case "$args" in *"bash -s -- "*) sample=${args##*bash -s -- } ;; esac
        mkproc; rexec 0 "$sample $STUB_PROCDIR"
      fi
    elif [ -n "${STUB_PF_RAW:-}" ]; then printf '%b\n' "$STUB_PF_RAW"; else
      rm -f "$STUB_SWAPCNT"; sample=""
      case "$args" in *"bash -s -- "*) sample=${args##*bash -s -- } ;; esac
      rexec 0 "$sample"
    fi ;;
  AUDIT) if [ "${STUB_AUDIT_BROKEN:-0}" = 1 ]; then echo AUDIT_ERR; exit 3
         elif [ "${STUB_AUDIT_BROKEN:-0}" = 2 ]; then echo "AUDIT_BAD NOME .env"; echo AUDIT_ERR; exit 3   # achou um vazamento e CAIU antes de terminar (o find real imprime o que acha na hora, antes do erro)
         else
           # STUB_AUDIT_UNREADABLE=<arquivo> / STUB_AUDIT_UNREADABLE_DIR=<pasta> (relativos ao HOME falso): o destino ganha, antes da auditoria REAL, um arquivo/pasta que o usuário não consegue ler (chmod 000) — o scanner devolve
           # rc 3 para o arquivo e o find reclama (stderr) da pasta. É o "achei E não consegui terminar" de verdade, sem enlatar a saída da auditoria.
           if [ -n "${STUB_AUDIT_UNREADABLE:-}" ]; then mkdir -p "$(dirname "$STUB_HOME/$STUB_AUDIT_UNREADABLE")"; echo x > "$STUB_HOME/$STUB_AUDIT_UNREADABLE"; chmod 000 "$STUB_HOME/$STUB_AUDIT_UNREADABLE"; fi
           if [ -n "${STUB_AUDIT_UNREADABLE_DIR:-}" ]; then mkdir -p "$STUB_HOME/$STUB_AUDIT_UNREADABLE_DIR"; chmod 000 "$STUB_HOME/$STUB_AUDIT_UNREADABLE_DIR"; fi
           rexec 0 "${args##*bash -s -- }"
         fi ;;
  SLOT_ACQUIRE)
    if [ "${STUB_SLOTS:-free}" = exec ]; then rexec 0; exit $?
    elif [ "${STUB_SLOTS:-free}" = full ]; then
      echo "BUSY 1 otherhost:11:$(date +%s) 0"; echo "BUSY 2 otherhost:12:$(date +%s) 0"; echo "BUSY 3 otherhost:13:$(date +%s) 0"; echo FULL; exit 3
    elif [ "${STUB_SLOTS:-free}" = dead ] && [ ! -f "$STUB_REAPED" ]; then
      h=$(hostname -s); echo "BUSY 1 $h:999999:$(date +%s) 0"; echo "BUSY 2 otherhost:12:$(date +%s) 0"; echo "BUSY 3 otherhost:13:$(date +%s) 0"; echo FULL; exit 3
    else echo "SLOT=1"; fi ;;
  SLOT_REAP) if [ "${STUB_SLOTS:-free}" = exec ]; then rexec 0; exit $?; else touch "$STUB_REAPED"; fi ;;
  SLOT_RELEASE) if [ "${STUB_SLOTS:-free}" = exec ]; then rexec 0; exit $?; fi ;;
  MIRROR)
    if [ "$host" = hetzner ] && [ "${STUB_NOBASE_NODE:-0}" = 1 ]; then echo NOBASE; exit 97
    elif [ "$host" = hetzner ] && [ "${STUB_NOVENV_NODE:-0}" = 1 ]; then echo NOVENV; exit 97
    elif [ "${STUB_NOBASE:-0}" = 1 ]; then echo NOBASE; exit 97; else echo MIRROR_OK; fi ;;
  RUN|EXEC)
    printf '%s\n' "$s" > "$(dirname "$STUB_LOG")/last-script-$name.sh"
    # STUB_RUNMODE=exec: executa o script recebido de verdade (sleep REAL: o vigia precisa esperar), com python/taskpolicy/renice falsos
    if [ "${STUB_RUNMODE:-canned}" = exec ]; then rexec 1; exit $?
    elif [ "$name" = RUN ]; then
      rc_v=${STUB_RUN_RC:-0}; out_v=""; slp=0
      if [ "$host" = hetzner ]; then rc_v=${STUB_RUN_RC_NODE:-$rc_v}; out_v=${STUB_RUN_OUT_NODE:-}; slp=${STUB_RUN_SLEEP_NODE:-0}
      else rc_v=${STUB_RUN_RC_MBP:-$rc_v}; out_v=${STUB_RUN_OUT_MBP:-}; slp=${STUB_RUN_SLEEP_MBP:-0}; fi
      [ "$rc_v" = 255 ] && exit 255
      # STUB_UNREADABLE_NODE_OUT / STUB_UNREADABLE_MBP_OUT=1: deixa ILEGÍVEL o arquivo temporário da saída do lado (simula disco que falhou / saída perdida). chmod 000 e não rm: se o `tee` ainda não tivesse
      # aberto o arquivo, ele o RECRIARIA e o caso viraria corrida; com chmod o resultado é o mesmo nas duas ordens.
      if [ "$host" = hetzner ] && [ "${STUB_UNREADABLE_NODE_OUT:-0}" = 1 ]; then chmod 000 "$MBP_CITY"/.gc/run/mbp-run.* 2>/dev/null; fi
      if [ "$host" = mbp ] && [ "${STUB_UNREADABLE_MBP_OUT:-0}" = 1 ]; then chmod 000 "$MBP_CITY"/.gc/run/mbp-shadow.* 2>/dev/null; fi
      # STUB_NODE_WAIT_FOR=<arquivo>: o nó só devolve depois que esse arquivo existe (sincroniza com a sombra, sem depender de relógio); STUB_SLEEP_MARK=<prefixo>: o lado de MBP marca
      # <prefixo>.start antes de dormir e <prefixo>.end SÓ se o sono terminar (um sono interrompido por kill não marca)
      if [ "$host" = hetzner ] && [ -n "${STUB_NODE_WAIT_FOR:-}" ]; then w=0; while [ ! -e "$STUB_NODE_WAIT_FOR" ] && [ "$w" -lt 240 ]; do /bin/sleep 0.5; w=$((w + 1)); done; fi
      if [ "$slp" != 0 ]; then
        [ -z "${STUB_SLEEP_MARK:-}" ] || [ "$host" = hetzner ] || : > "$STUB_SLEEP_MARK.start"
        if /bin/sleep "$slp"; then [ -z "${STUB_SLEEP_MARK:-}" ] || [ "$host" = hetzner ] || : > "$STUB_SLEEP_MARK.end"; fi
      fi
      if [ -n "$out_v" ]; then printf '%b\n' "$out_v"; else echo "${STUB_RUN_OUT:-stub-run-ok}"; fi
      exit "$rc_v"
    else echo "stub-exec-ok"; exit "${STUB_RUN_RC:-0}"; fi ;;
  DIRECT)
    echo "DIRECT:$args" >> "$STUB_LOG"
    case "$args" in *"cat > gt-remote/freeze-"*) cat > "$(dirname "$STUB_LOG")/freeze-sent.txt" ;; esac
    if [ -n "${STUB_DIRECT_FAIL_ON:-}" ]; then case "$args" in *"$STUB_DIRECT_FAIL_ON"*) exit 1 ;; esac; fi
    # STUB_DIRECT_EXEC_ON=<padrão>: o comando remoto que casa o padrão roda DE VERDADE (bash -c, HOME falso, o uv/shasum falsos do PATH) e o stub devolve o status DELE. É assim que se vê o status que o
    # comando monta (um `| tail` que engole o do uv), e não o que um stub finge: o FAIL_ON acima falha o ssh inteiro e nunca exercita o comando.
    if [ -n "${STUB_DIRECT_EXEC_ON:-}" ]; then case "$args" in *"$STUB_DIRECT_EXEC_ON"*) (cd "$STUB_HOME" && HOME="$STUB_HOME" bash -c "${!#}"); exit $? ;; esac; fi
    [ -z "${STUB_DIRECT_OUT:-}" ] || echo "$STUB_DIRECT_OUT"; exit "${STUB_DIRECT_RC:-0}" ;;
esac
exit 0
EOF
cat > "$T/bin/rsync" <<'EOF'
#!/usr/bin/env bash
echo "RSYNC:$*" >> "$STUB_LOG"
case "$*" in *--out-format*) exec "$REAL_RSYNC" "$@" ;; esac   # a lista do node_guard (-n --out-format) roda DE VERDADE sobre a árvore local: o guard falha fechado, um stub mudo desligaria o nó em todo teste
# o rsync real (openrsync) procura `rsync` no PATH para subir o processo servidor local: ESTE stub. O filho `--server` vai direto ao binário de verdade.
case "$*" in --server*) exec "$REAL_RSYNC" "$@" ;; esac
case "$*" in *gt-remote/bin*) [ "${STUB_RSYNC_FAIL_BIN:-0}" = 1 ] && exit 1 ;; esac   # só a cópia de ferramentas para ~/gt-remote/bin
# STUB_RSYNC_REAL=1: roda o rsync DE VERDADE com os argumentos que o mbp-run montou (filtro incluso), com o destino remoto trocado por uma pasta do "nó"
# ($STUB_HOME/<caminho>) e o -e/ssh descartado. É assim que o teste de vazamento vê o que o filtro realmente deixa sair.
if [ "${STUB_RSYNC_REAL:-0}" = 1 ]; then
  case "${!#}" in hetzner-teste:*) ;; *) exit "${STUB_RSYNC_RC:-0}" ;; esac   # o lado do MBP continua enlatado (ele recebe a árvore maior por desenho)
  a=(); skip=0
  for x in "$@"; do
    if [ $skip -eq 1 ]; then skip=0; continue; fi
    [ "$x" = -e ] && { skip=1; continue; }
    a+=("$x")
  done
  last=$(( ${#a[@]} - 1 )); dest="${a[$last]}"
  case "$dest" in *:*) dest="$STUB_HOME/${dest#*:}" ;; esac
  a[$last]="$dest"; mkdir -p "$dest"
  "$REAL_RSYNC" "${a[@]}"; exit $?
fi
exit "${STUB_RSYNC_RC:-0}"
EOF

# ferramentas falsas do MBP (só o preflight as enxerga). Padrão saudável: 8000 MB livres, swap 1000 MB parado, pressão 1.
cat > "$T/fake/vm_stat" <<'EOF'
#!/usr/bin/env bash
[ "${STUB_VM_FAIL:-0}" = 1 ] && exit 1
ps=${STUB_PAGE_SIZE:-16384}
total=$(( ${STUB_AVAIL_MB:-8000} * 1048576 / ps ))
f=$(( total / 2 )); i=$(( total / 4 )); s=$(( total - f - i ))
out="Mach Virtual Memory Statistics: (page size of $ps bytes)
Pages free:                               $f.
Pages active:                             123456.
Pages inactive:                           $i.
Pages speculative:                        $s.
Pages throttled:                          0.
Pages wired down:                         54321.
Pages purgeable:                          100.
Pages occupied by compressor:             ${STUB_COMP_PAGES:-337212}.
Swapouts:                                 1."
if [ -n "${STUB_VM_DROP:-}" ]; then printf '%s\n' "$out" | grep -v "$STUB_VM_DROP"; else printf '%s\n' "$out"; fi
EOF
# sysctl: vm.swapusage devolve STUB_SWAP_MB na 1ª leitura e STUB_SWAP2_MB (padrão = o mesmo) nas seguintes; *_RAW devolve texto cru
cat > "$T/fake/sysctl" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -n ] && shift
case "${1:-}" in
  vm.swapusage)
    n=$(cat "$STUB_SWAPCNT" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$STUB_SWAPCNT"
    if [ "$n" -le 1 ]; then raw="${STUB_SWAP_RAW:-}"; mb="${STUB_SWAP_MB:-1000}"
    else raw="${STUB_SWAP2_RAW:-${STUB_SWAP_RAW:-}}"; mb="${STUB_SWAP2_MB:-${STUB_SWAP_MB:-1000}}"; fi
    if [ -n "$raw" ]; then printf '%s\n' "$raw"; else echo "total = 8192.00M  used = ${mb}.00M  free = 1.00M  (encrypted)"; fi ;;
  kern.memorystatus_vm_pressure_level) [ "${STUB_PRESSURE_FAIL:-0}" = 1 ] && exit 1; echo "${STUB_PRESSURE:-1}" ;;
  vm.loadavg) echo "{ 1.00 1.10 1.20 }" ;;
  hw.ncpu) [ "${STUB_NCPU_FAIL:-0}" = 1 ] && exit 1; echo "${STUB_NCPU:-12}" ;;
  *) exit 1 ;;
esac
EOF
cat > "$T/fake/memory_pressure" <<'EOF'
#!/usr/bin/env bash
[ "${STUB_MP_FAIL:-0}" = 1 ] && exit 1
echo "The system has 17179869184 (1048576 pages with a page size of 16384)."
echo "System-wide memory free percentage: ${STUB_MP_PCT:-54}%"
EOF
cat > "$T/fake/pmset" <<'EOF'
#!/usr/bin/env bash
case "$*" in *assertions*)
  [ "${STUB_ASSERT_FAIL:-0}" = 1 ] && exit 1
  [ -n "${STUB_ASSERT_RAW:-}" ] && { printf '%s\n' "$STUB_ASSERT_RAW"; exit 0; }
  printf 'Assertion status system-wide:\n   BackgroundTask                 0\n   PreventUserIdleDisplaySleep    %s\n   PreventSystemSleep             0\n' "${STUB_HOLD:-0}"
  exit 0 ;;
esac
[ "${STUB_PMSET_FAIL:-0}" = 1 ] && exit 1
[ -n "${STUB_PMSET_RAW:-}" ] && { printf '%s\n' "$STUB_PMSET_RAW"; exit 0; }
if [ "${STUB_POWER:-ac}" = ac ]; then src="AC Power"; else src="Battery Power"; fi
printf "Now drawing from '%s'\n -InternalBattery-0 (id=1)\t%s%%; discharging; 3:00 remaining present: true\n" "$src" "${STUB_BATT:-90}"
EOF
cat > "$T/fake/sleep" <<'EOF'
#!/usr/bin/env bash
if [ "${STUB_REAL_SLEEP:-0}" = 1 ]; then exec /bin/sleep "$@"; fi
echo "SLEEP:$*" >> "$STUB_LOG"
# nó Linux: entre as duas leituras do swap o "SwapFree" muda (STUB_N_SWAPFREE2_MB), para testar o crescimento
if [ -n "${STUB_PROCDIR:-}" ] && [ -n "${STUB_N_SWAPFREE2_MB:-}" ] && [ -f "$STUB_PROCDIR/meminfo" ]; then
  sed -i.bak "s/^SwapFree:.*/SwapFree:       $(( STUB_N_SWAPFREE2_MB * 1024 )) kB/" "$STUB_PROCDIR/meminfo"; rm -f "$STUB_PROCDIR/meminfo.bak"
fi
EOF
# ferramentas falsas do NÓ LINUX (só o preflight dele as enxerga): nproc/getconf (núcleos), df (disco livre)
cat > "$T/fake/nproc" <<'EOF'
#!/usr/bin/env bash
[ "${STUB_N_NPROC_FAIL:-0}" = 1 ] && exit 1
echo "${STUB_N_NPROC:-16}"
EOF
cat > "$T/fake/getconf" <<'EOF'
#!/usr/bin/env bash
[ "${STUB_N_NPROC_FAIL:-0}" = 1 ] && exit 1
exec /usr/bin/getconf "$@"
EOF
cat > "$T/fake/df" <<'EOF'
#!/usr/bin/env bash
[ "${STUB_N_DISK_FAIL:-0}" = 1 ] && exit 1
[ -n "${STUB_N_DISK_RAW:-}" ] && { printf '%b\n' "$STUB_N_DISK_RAW"; exit 0; }
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/x 300000000 8000000 %s 3%% /\n' "$(( ${STUB_N_DISK_MB:-280000} * 1024 ))"
EOF
# ioreg falso, no formato REAL (medido no MBP em 12/10: dict raiz com IOConsoleUsers[ {CGSSessionScreenIsLocked, kCGSSessionOnConsoleKey, ...} ];
# a marca de bloqueio só existe com a tela bloqueada). Estado: env STUB_LOCKED/STUB_IDLE_S, ou o arquivo STUB_STATE_FILE (muda no meio da execução).
#   STUB_LOCKED: 1 bloqueada · 0 sem a marca · false marca=false · two (2 sessões, a do console bloqueada) · notconsole (nenhuma no console)
#                none (sem IOConsoleUsers) · garbage (não é plist) · fail (ioreg sai 1)
#   STUB_IDLE_S: segundos (ex. "30" ou "30,9000" = duas entradas) · none (nenhuma entrada) · fail (ioreg sai 1) · qualquer texto = entrada ilegível
cat > "$T/fake/ioreg" <<'EOF'
#!/usr/bin/env bash
lk=${STUB_LOCKED:-1}; idle=${STUB_IDLE_S:-5000}
if [ -n "${STUB_STATE_FILE:-}" ] && [ -f "$STUB_STATE_FILE" ]; then . "$STUB_STATE_FILE"; lk=${locked:-$lk}; idle=${idle_s:-$idle}; fi
sess() { # locked(true|false|absent) onconsole(true|false)
  printf '\t\t<dict>\n'
  [ "$1" = absent ] || printf '\t\t\t<key>CGSSessionScreenIsLocked</key>\n\t\t\t<%s/>\n' "$1"
  printf '\t\t\t<key>kCGSSessionIDKey</key>\n\t\t\t<integer>257</integer>\n\t\t\t<key>kCGSSessionOnConsoleKey</key>\n\t\t\t<%s/>\n\t\t\t<key>kCGSSessionUserNameKey</key>\n\t\t\t<string>user</string>\n\t\t</dict>\n' "$2"
}
case "$*" in
  *"-n Root"*)
    case "$lk" in
      fail) exit 1 ;;
      garbage) echo "this is not a plist"; exit 0 ;;
    esac
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n'
    [ "$lk" = 1 ] && printf '\t<key>IOConsoleLocked</key>\n\t<true/>\n'
    if [ "$lk" != none ]; then
      printf '\t<key>IOConsoleUsers</key>\n\t<array>\n'
      case "$lk" in
        1) sess true true ;;
        0) sess absent true ;;
        false) sess false true ;;
        two) sess false false; sess true true ;;
        notconsole) sess true false ;;
      esac
      printf '\t</array>\n'
    fi
    printf '\t<key>IOKitBuildVersion</key>\n\t<string>Darwin Kernel</string>\n</dict>\n</plist>\n' ;;
  *"-c IOHIDSystem"*)
    case "$idle" in
      fail) exit 1 ;;
      none) exit 0 ;;
    esac
    printf '%s\n' "$idle" | tr ',' '\n' | while read -r v; do
      case "$v" in ''|*[!0-9]*) printf '      | |   "HIDIdleTime" = %s\n' "$v" ;; *) printf '      | |   "HIDIdleTime" = %s000000000\n' "$v" ;; esac
    done ;;
esac
EOF
# taskpolicy falso: `taskpolicy -b cmd...` registra e executa cmd; `taskpolicy -b -p PID` só registra. renice falso só registra.
cat > "$T/fake/taskpolicy" <<'EOF'
#!/usr/bin/env bash
echo "TP:$*" >> "$STUB_LOG"
[ "${2:-}" = -p ] && exit 0   # `taskpolicy -b -p PID`: só registra (o `-p` do pytest, mais adiante na linha, NÃO conta)
shift   # -b
exec "$@"
EOF
# nice falso: registra o `-n N` pedido e executa o comando SEM aplicar (a árvore de processos da máquina de teste já pode estar em nice 10,
# e nice 20 é o teto: o valor real não distinguiria os modos)
cat > "$T/fake/nice" <<'EOF'
#!/usr/bin/env bash
echo "NICE:$1 $2" >> "$STUB_LOG"
shift 2
exec "$@"
EOF
cat > "$T/fake/renice" <<'EOF'
#!/usr/bin/env bash
echo "RENICE:$*" >> "$STUB_LOG"
EOF
# python falso do venv do MBP (só roda quando STUB_RUNMODE=exec): registra o nice com que nasceu e os slots que viu, dorme, sai com STUB_RUN_RC
mkdir -p "$T/home/gt-remote/venv/bin" "$T/home/gt-remote/exec" "$T/home/gt-remote/slots"
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13; do mkdir -p "$T/home/gt-remote/mirror/wa-$i" "$T/home/gt-remote/exec/$i"; done
cat > "$T/home/gt-remote/venv/bin/python" <<'EOF'
#!/usr/bin/env bash
echo "PY args=$*" >> "$STUB_LOG"
cat "$HOME"/gt-remote/slots/*/info >> "$STUB_SEEN" 2>/dev/null
# gatilhos de virada RELATIVOS ao início do trabalho (um temporizador do teste correria contra o preflight e o rsync, que numa máquina carregada demoram)
if [ -n "${STUB_FLIP_STATE:-}" ]; then ( /bin/sleep 1.5; printf '%b' "$STUB_FLIP_STATE" > "$STUB_STATE_FILE" ) </dev/null >/dev/null 2>&1 & fi
if [ -n "${STUB_FLIP_PAUSE:-}" ]; then ( /bin/sleep 1.5; echo "origem=mbp desde=agora" > "$HOME/gt-remote/PAUSE" ) </dev/null >/dev/null 2>&1 & fi
/bin/sleep "${STUB_RUN_SLEEP:-0}"
# espera (limitada: N voltas de 0,5 s) o vigia rebaixar a árvore, em vez de dormir um tempo fixo: numa máquina com load 90 cada ioreg/ps do vigia
# leva segundos, e um sleep fixo faria o teste medir a carga da máquina, não o rebaixamento
if [ -n "${STUB_WAIT_RENICE:-}" ]; then i=0; while [ "$i" -lt "$STUB_WAIT_RENICE" ] && ! grep -q '^RENICE:' "$STUB_LOG"; do /bin/sleep 0.5; i=$((i+1)); done; fi
echo "5 passed in 0.1s"
exit "${STUB_RUN_RC:-0}"
EOF
chmod +x "$T/bin/ssh" "$T/bin/rsync" "$T/fake/"* "$T/home/gt-remote/venv/bin/python"

# nó Linux: venv com xdist, pastas do "nó" no HOME falso, lista mac-only hermética e sombra DESLIGADA por padrão (os casos do nó a ligam)
mkdir -p "$T/home/gt-remote/venv-wa/lib/python3.14/site-packages/pytest_xdist-3.8.0.dist-info" "$T/home/gt-remote/venv-wa/bin" "$T/home/gt-remote/wa-base"
: > "$T/mac-only.txt"
REAL_RSYNC=$(PATH=/usr/bin:/bin:/opt/homebrew/bin command -v rsync)
export REAL_RSYNC HETZNER_MAC_ONLY_LIST="$T/mac-only.txt" HETZNER_SHADOW_PCT=0 STUB_PROCDIR="$T/proc"
unset MBP_MAX_SWAP_MB MBP_MAX_SWAP_GROWTH_MB MBP_SWAP_SAMPLE_S MBP_MAX_PRESSURE_LEVEL MBP_MIN_AVAIL_MB MBP_MIN_BATT MBP_MAX_SLOTS MBP_SLOT_MAX_AGE_S MBP_RUN_TIMEOUT_S MBP_HOST
export PATH="$T/bin:$PATH" MBP_CITY="$T/city" MBP_SSH="$T/bin/ssh" MBP_RSYNC="$T/bin/rsync"
# ga-bmmxka: sem MBP_HOST o mbp-run.sh sonda a porta 22 do MBP; aqui a sonda é um stub (HOSTPROBE_UP = hosts que "respondem"; por padrão só o
# Tailscale), então nenhum caso depende de DNS, de nc nem do MBP de verdade.
cat > "$T/bin/hostprobe" <<'EOF'
#!/bin/sh
[ -z "${HOSTPROBE_LOG:-}" ] || echo "$1 $2" >> "$HOSTPROBE_LOG"
case " ${HOSTPROBE_UP-athoss-macbook-pro} " in *" $1 "*) exit 0 ;; esac
exit 1
EOF
chmod +x "$T/bin/hostprobe"; export MBP_HOST_PROBE="$T/bin/hostprobe"
export STUB_LOG="$T/stub.log" STUB_REAPED="$T/reaped" STUB_SWAPCNT="$T/swapcnt" FAKE="$T/fake" STUB_HOME="$T/home" STUB_SEEN="$T/seen-info" STUB_STATE_FILE="$T/presence.state"
if [ -x /bin/bash ]; then export STUB_REMOTE_BASH=/bin/bash; else export STUB_REMOTE_BASH=bash; fi
FLAG="$T/city/.gc/mbp-offload.on"
FLAG_PAUSE="$T/city/.gc/mbp-offload.pause"
J="$T/city/.gc/logs/mbp-run.jsonl"
fails=0; n=0
reset() { : > "$STUB_LOG"; rm -f "$STUB_REAPED" "$J" "$STUB_STATE_FILE" "$STUB_SEEN" "$FLAG_PAUSE" "$T/home/gt-remote/PAUSE"; mkdir -p "$T/home/gt-remote/slots"; find "$T/home/gt-remote/slots" -mindepth 1 -delete 2>/dev/null
  unset STUB_LOCKED STUB_IDLE_S STUB_HOLD STUB_ASSERT_FAIL STUB_ASSERT_RAW STUB_NCPU STUB_NCPU_FAIL STUB_RSYNC_FAIL_BIN STUB_WAIT_RENICE STUB_RUNMODE STUB_RUN_SLEEP STUB_FLIP_STATE STUB_FLIP_PAUSE STUB_DIRECT_OUT STUB_DIRECT_RC STUB_REAL_SLEEP MBP_FORCE_PRESENCE MBP_MAX_SLOTS MBP_USE_SLOTS MBP_SLOT_MEM_MB MBP_AWAY_IDLE_S MBP_WATCH_S PRESENCE_FORCE_USO PRESENCE_AWAY_S
  rm -f "$T/city/.gc/hetzner-node.on" "$T/city/.gc/hetzner-mac-only.learned" "$T/city/.gc/logs/hetzner-shadow.jsonl" "$T"/last-script-*-hetzner.sh "$T"/last-script-*-mbp.sh "$T/freeze-sent.txt"
  unset STUB_UNREACHABLE_NODE STUB_UNREACHABLE_MBP STUB_PF_RAW_NODE STUB_NOBASE_NODE STUB_NOVENV_NODE STUB_RUN_RC_NODE STUB_RUN_RC_MBP STUB_RUN_OUT_NODE STUB_RUN_OUT_MBP STUB_RUN_SLEEP_NODE STUB_RUN_SLEEP_MBP \
    STUB_N_MEMINFO_RAW STUB_N_AVAIL_MB STUB_N_SWAPTOTAL_MB STUB_N_SWAPFREE_MB STUB_N_SWAPFREE2_MB STUB_N_PSI_MISSING STUB_N_PSI_RAW STUB_N_PSI_SOME STUB_N_PSI_FULL STUB_N_NPROC STUB_N_NPROC_FAIL STUB_N_DISK_MB STUB_N_DISK_FAIL STUB_N_DISK_RAW \
    STUB_RSYNC_REAL STUB_DIRECT_FAIL_ON STUB_DIRECT_EXEC_ON STUB_UV_FAIL_DRYRUN STUB_UV_FREEZE_EXTRA STUB_AUDIT_BROKEN STUB_AUDIT_UNREADABLE STUB_AUDIT_UNREADABLE_DIR HETZNER_XDIST_OFF HETZNER_XDIST_MIN_TESTS HETZNER_RSYNC_FILTER HETZNER_SEED_ROOT HETZNER_SEED_VENV HETZNER_SEED_DRYRUN HETZNER_MAX_SLOTS HETZNER_SHADOW_WAIT_S HETZNER_SHADOW_WINDOW_S HETZNER_MIN_DISK_MB HETZNER_FREEZE_SKIP HETZNER_NODE_HOST MBP_RUN_SHADOW
  unset STUB_UNREACHABLE STUB_AVAIL_MB STUB_SWAP_MB STUB_SWAP2_MB STUB_SWAP_RAW STUB_SWAP2_RAW STUB_PRESSURE STUB_PRESSURE_FAIL STUB_VM_FAIL STUB_VM_DROP STUB_PAGE_SIZE STUB_COMP_PAGES STUB_MP_FAIL STUB_MP_PCT STUB_PF_RAW STUB_POWER STUB_BATT STUB_PMSET_FAIL STUB_PMSET_RAW STUB_SLOTS STUB_NOBASE STUB_RUN_RC STUB_RUN_OUT STUB_RSYNC_RC; }
expect() { # nome rc_esperado rc_real [grep-no-log padrão]
  n=$((n+1))
  if [ "$2" = "$3" ]; then echo "ok   $1 (rc=$3)"; else echo "FAIL $1: esperado rc=$2, veio $3"; fails=$((fails+1)); fi
}
eq() { # nome esperado real
  n=$((n+1)); if [ "$2" = "$3" ]; then echo "ok   $1 ($3)"; else echo "FAIL $1: esperado '$2', veio '$3'"; fails=$((fails+1)); fi
}
has() { # nome arquivo padrão
  n=$((n+1)); if grep -q -E -e "$3" "$2"; then echo "ok   $1"; else echo "FAIL $1: '$3' ausente em $2"; fails=$((fails+1)); fi
}
hasnt() {
  n=$((n+1)); if grep -q -E -e "$3" "$2"; then echo "FAIL $1: '$3' presente em $2"; fails=$((fails+1)); else echo "ok   $1"; fi
}
run() { "$RUN" --repo wa --dir "$T/wt" "$@" >"$T/out" 2>"$T/err"; echo $?; }
chk() { "$RUN" --check >"$T/out" 2>"$T/err"; echo $?; }
# outcome <script>: "rc:motivo" de uma execução; o motivo vem da última linha de recusa do log ("-" se não houve recusa)
outcome() {
  local s="$1" rc r
  rm -f "$J"
  "$s" --repo wa --dir "$T/wt" -- tests/test_x.py >/dev/null 2>&1; rc=$?
  r=$(grep '"mode":"preflight"' "$J" 2>/dev/null | tail -1 | sed -n 's/.*"reason":"\([^"]*\)".*/\1/p')
  echo "$rc:${r:--}"
}

# ---- PRESENÇA DO ATHOS (ga-77c1qg) ---------------------------------------------------------------------------------
# A biblioteca e o runner rodam DE VERDADE (sob /bin/bash 3.2 quando existe, como no MBP) com ioreg/pmset/taskpolicy/renice/python falsos;
# o plist do ioreg falso tem o formato REAL medido no MBP. Nada toca o MBP verdadeiro.
LIB="$HERE/mbp-presence.sh"
LIBX=""   # biblioteca sob teste (os controles negativos apontam para uma mutante)
libp() { HOME="$T/home" PATH="$FAKE:$PATH" "$STUB_REMOTE_BASH" -c 'PRESENCE_LIB_ONLY=1; . "$1"; presence_probe' _ "${LIBX:-$LIB}" 2>/dev/null; }
pv() { libp | sed -n "s/^$1=//p"; }
verdict() { local o; o=$(libp); printf '%s/%s' "$(printf '%s\n' "$o" | sed -n 's/^presence=//p')" "$(printf '%s\n' "$o" | sed -n 's/^presence_why=//p')"; }
mkslot() { mkdir -p "$T/home/gt-remote/slots/$1"; printf '%s\n' "${2:-otherhost:1:$(date +%s)}" > "$T/home/gt-remote/slots/$1/owner"; }
slot_names() { ls -1 "$T/home/gt-remote/slots" | sort -n | tr '\n' ' '; }
capof() { "${1:-$RUN}" --check 2>/dev/null | sed -n 's/^slot_cap=//p'; }
runx() { local s="$1"; shift; "$s" --repo wa --dir "$T/wt" -- "$@" >"$T/out" 2>"$T/err"; echo $?; }
runs() { MBP_WATCH_S="${MBP_WATCH_S:-1}" run "$@"; }   # execução supervisionada com o vigia a cada 1 s (reset limpa MBP_WATCH_S)
PF_OK='avail_mb=8000\nswap_mb=5000\nswap_delta_mb=0\npressure=1\npower=ac\nbatt=90'

presenca_cases() {
echo "--- presença do Athos (ga-77c1qg)"
reset
# --- a regra, na biblioteca ---
eq "bloqueada → livre" "livre/bloqueada" "$(STUB_LOCKED=1 STUB_IDLE_S=5 verdict)"
eq "desbloqueada + teclado há 30 s → uso" "uso/input_recente" "$(STUB_LOCKED=0 STUB_IDLE_S=30 verdict)"
eq "599 s sem input (fronteira) → uso" "uso/input_recente" "$(STUB_LOCKED=0 STUB_IDLE_S=599 verdict)"
eq "600 s sem input (fronteira) → livre" "livre/ocioso" "$(STUB_LOCKED=0 STUB_IDLE_S=600 verdict)"
eq "marca de bloqueio =false → desbloqueada" "uso/input_recente" "$(STUB_LOCKED=false STUB_IDLE_S=30 verdict)"
eq "limiar configurável (PRESENCE_AWAY_S=60): 61 s → livre" "livre/ocioso" "$(PRESENCE_AWAY_S=60 STUB_LOCKED=0 STUB_IDLE_S=61 verdict)"
eq "limiar inválido volta a 600" "uso/input_recente" "$(PRESENCE_AWAY_S=abc STUB_LOCKED=0 STUB_IDLE_S=599 verdict)"
eq "sem input há 5000 s mas app segura a tela (reunião) → uso" "uso/tela_em_uso" "$(STUB_LOCKED=0 STUB_IDLE_S=5000 STUB_HOLD=1 verdict)"
eq "app segurando a tela NÃO atrapalha a tela bloqueada" "livre/bloqueada" "$(STUB_LOCKED=1 STUB_HOLD=1 verdict)"
eq "pmset assertions falhou → ilegível, uso" "uso/ilegivel:tela" "$(STUB_LOCKED=0 STUB_IDLE_S=5000 STUB_ASSERT_FAIL=1 verdict)"
eq "pmset assertions sem a linha → ilegível, uso" "uso/ilegivel:tela" "$(STUB_LOCKED=0 STUB_IDLE_S=5000 STUB_ASSERT_RAW='nothing here' verdict)"
# --- leitura que falha NUNCA vira livre ---
eq "ociosidade ilegível (ioreg HID falhou) → uso" "uso/ilegivel:ociosidade" "$(STUB_LOCKED=0 STUB_IDLE_S=fail verdict)"
eq "nenhuma entrada HIDIdleTime → uso" "uso/ilegivel:ociosidade" "$(STUB_LOCKED=0 STUB_IDLE_S=none verdict)"
eq "entrada HID com lixo → ilegível, uso" "uso/ilegivel:ociosidade" "$(STUB_LOCKED=0 STUB_IDLE_S=abc verdict)"
eq "duas entradas HID: vale a de input mais recente" "uso/input_recente" "$(STUB_LOCKED=0 STUB_IDLE_S=30,9000 verdict)"
eq "duas entradas HID, uma com lixo → ilegível" "uso/ilegivel:ociosidade" "$(STUB_LOCKED=0 STUB_IDLE_S=abc,9000 verdict)"
eq "bloqueio ilegível (ioreg falhou) + 5000 s sem input → livre (a evidência positiva é só do input)" "livre/ocioso" "$(STUB_LOCKED=fail STUB_IDLE_S=5000 verdict)"
eq "bloqueio ilegível + input há 10 s → uso" "uso/input_recente" "$(STUB_LOCKED=fail STUB_IDLE_S=10 verdict)"
eq "bloqueio E ociosidade ilegíveis → uso" "uso/ilegivel:presenca" "$(STUB_LOCKED=fail STUB_IDLE_S=fail verdict)"
eq "saída que não é plist = bloqueio ilegível" "uso/ilegivel:presenca" "$(STUB_LOCKED=garbage STUB_IDLE_S=none verdict)"
eq "sem IOConsoleUsers (tela de login) não é 'desbloqueada'" "uso/ilegivel:presenca" "$(STUB_LOCKED=none STUB_IDLE_S=none verdict)"
eq "nenhuma sessão no console não é 'desbloqueada'" "uso/ilegivel:presenca" "$(STUB_LOCKED=notconsole STUB_IDLE_S=none verdict)"
eq "duas sessões: vale a do console (bloqueada)" "livre/bloqueada" "$(STUB_LOCKED=two STUB_IDLE_S=5 verdict)"
eq "bloqueada lida do plist real: locked=1" 1 "$(STUB_LOCKED=1 pv locked)"
eq "sem a marca (sessão do console lida): locked=0" 0 "$(STUB_LOCKED=0 pv locked)"
eq "ociosidade lida em segundos (ns / 1e9)" 4321 "$(STUB_IDLE_S=4321 pv idle_s)"
# --- só dá para PIORAR ---
eq "PRESENCE_FORCE_USO=1 vence a tela bloqueada" "uso/forcado" "$(PRESENCE_FORCE_USO=1 STUB_LOCKED=1 verdict)"
eq "não existe forçar livre (variáveis de 'forçar livre' são ignoradas)" "uso/input_recente" "$(PRESENCE_FORCE_LIVRE=1 PRESENCE_FORCE=livre STUB_LOCKED=0 STUB_IDLE_S=30 verdict)"
# --- pausa ---
reset; eq "sem arquivo de pausa: paused=0" 0 "$(pv paused)"
echo "origem=mbp desde=ontem|x" > "$T/home/gt-remote/PAUSE"
eq "com o arquivo: paused=1" 1 "$(pv paused)"; eq "pause_info: numa linha e sem '|'" "origem=mbp desde=ontemx" "$(pv pause_info)"
# --- caminhos de entrada da biblioteca ---
reset
eq "executada direto imprime o veredito" "presence=livre" "$(HOME="$T/home" PATH="$FAKE:$PATH" STUB_LOCKED=1 "$STUB_REMOTE_BASH" "$LIB" 2>/dev/null | sed -n 1p)"
eq "colada num 'bash -s' (como vai ao MBP) NÃO imprime nada" "" "$(HOME="$T/home" PATH="$FAKE:$PATH" STUB_LOCKED=1 "$STUB_REMOTE_BASH" -s < "$LIB" 2>/dev/null)"

# --- mbp-run: teto de slots por modo ---
reset; eq "livre, 12 núcleos, RAM sobrando: teto 12" 12 "$(STUB_AVAIL_MB=30000 capof)"
eq "livre, 8 núcleos: teto 8" 8 "$(STUB_AVAIL_MB=30000 STUB_NCPU=8 capof)"
eq "núcleos ilegíveis: teto de reserva 3 (não inventa)" 3 "$(STUB_AVAIL_MB=30000 STUB_NCPU_FAIL=1 capof)"
eq "MBP_MAX_SLOTS=5 troca o teto de núcleos" 5 "$(MBP_MAX_SLOTS=5 STUB_AVAIL_MB=30000 capof)"
eq "MBP_MAX_SLOTS inválido é ignorado" 12 "$(MBP_MAX_SLOTS=abc STUB_AVAIL_MB=30000 capof)"
eq "RAM decide: 3840 MB disponíveis (3072 + 1 fatia) → 2" 2 "$(STUB_AVAIL_MB=3840 capof)"
eq "RAM decide: 3839 MB (falta 1 MB para a 2ª fatia) → 1" 1 "$(STUB_AVAIL_MB=3839 capof)"
eq "RAM no mínimo (3072) → 1" 1 "$(STUB_AVAIL_MB=3072 capof)"
eq "fatia de RAM configurável (MBP_SLOT_MEM_MB=100)" 10 "$(MBP_SLOT_MEM_MB=100 STUB_AVAIL_MB=4000 capof)"
eq "desbloqueado, teclado há 30 s (em uso): teto 1" 1 "$(STUB_LOCKED=0 STUB_IDLE_S=30 STUB_AVAIL_MB=30000 capof)"
eq "em uso: MBP_USE_SLOTS=2 sobe o teto" 2 "$(MBP_USE_SLOTS=2 STUB_LOCKED=0 STUB_IDLE_S=30 capof)"
eq "em uso: MBP_USE_SLOTS=0 (inválido) volta a 1" 1 "$(MBP_USE_SLOTS=0 STUB_LOCKED=0 STUB_IDLE_S=30 capof)"
eq "MBP_FORCE_PRESENCE=uso vence a tela bloqueada" 1 "$(MBP_FORCE_PRESENCE=uso STUB_AVAIL_MB=30000 capof)"
eq "MBP_FORCE_PRESENCE=livre é ignorado (só existe forçar uso)" 1 "$(MBP_FORCE_PRESENCE=livre STUB_LOCKED=0 STUB_IDLE_S=30 STUB_AVAIL_MB=30000 capof)"
eq "saída do MBP sem campo de presença = em uso (teto 1)" 1 "$(STUB_PF_RAW="$PF_OK" capof)"
eq "presença com valor fora de {livre,uso} = em uso" 1 "$(STUB_PF_RAW="$PF_OK\npresence=talvez\nncpu=12\npaused=0" capof)"
reset; STUB_AVAIL_MB=30000 chk >/dev/null
has "--check mostra a presença" "$T/out" '^presence=livre$'; has "--check mostra o porquê" "$T/out" '^presence_why=bloqueada$'
has "--check mostra paused" "$T/out" '^paused=0$'; has "--check mostra paused_local" "$T/out" '^paused_local=0$'
has "--check mostra os núcleos" "$T/out" '^ncpu=12$'

# --- a presença NÃO recusa por si; a saúde continua valendo; a pausa vem antes ---
reset; rc=$(STUB_LOCKED=0 STUB_IDLE_S=30 run -- tests/test_x.py); expect "em uso + MBP saudável: roda (rc 0)" 0 "$rc"
has "log: em uso, não rebaixada" "$J" '"presence":"uso","demoted":0'
reset; rc=$(run -- tests/test_x.py); expect "livre + MBP saudável: roda" 0 "$rc"; has "log: livre" "$J" '"presence":"livre","demoted":0'
reset; eq "em uso + RAM baixa: a saúde ainda recusa" "98:ram" "$(STUB_LOCKED=0 STUB_IDLE_S=30 STUB_AVAIL_MB=1000 outcome "$RUN")"; has "recusa registra a presença" "$J" '"presence":"uso"'
echo "origem=mbp desde=hoje" > "$T/home/gt-remote/PAUSE"
eq "pausa no MBP: rc 99 com motivo próprio" "99:pausado_mbp" "$(outcome "$RUN")"; has "pausa no log com rc 99" "$J" '"rc":99,.*"reason":"pausado_mbp"'
rc=$(run -- tests/test_x.py); expect "pausa no MBP: rc 99" 99 "$rc"; has "mensagem diz quem pausou" "$T/err" 'pausado pelo Athos \(origem=mbp'
reset; echo "origem=mbp desde=hoje" > "$T/home/gt-remote/PAUSE"
eq "pausa vem antes da saúde (RAM baixa + pausa = pausa)" "99:pausado_mbp" "$(STUB_AVAIL_MB=1000 outcome "$RUN")"
reset; echo "origem=mbp desde=hoje" > "$T/home/gt-remote/PAUSE"; rc=$(chk); expect "--check com a pausa no MBP: rc 99" 99 "$rc"; has "--check mostra paused=1" "$T/out" '^paused=1$'
reset; echo "origem=painel desde=hoje" > "$FLAG_PAUSE"; rc=$(run -- tests/test_x.py); expect "pausa local: rc 99" 99 "$rc"
hasnt "pausa local não chama ssh" "$STUB_LOG" 'PREFLIGHT'; has "mensagem da pausa local" "$T/err" 'pausado pelo Athos \(origem=painel'
reset; echo "origem=painel desde=hoje" > "$FLAG_PAUSE"; rc=$("$RUN" --seed wa >"$T/out" 2>"$T/err"; echo $?); expect "--seed com pausa local: rc 99" 99 "$rc"
hasnt "--seed pausado não chama ssh" "$STUB_LOG" 'PREFLIGHT'
reset; echo "origem=mbp desde=hoje" > "$T/home/gt-remote/PAUSE"; rc=$("$RUN" --seed wa >"$T/out" 2>"$T/err"; echo $?); expect "--seed com pausa no MBP: rc 99" 99 "$rc"
reset; "$RUN" --seed wa >"$T/out" 2>"$T/err"; hasnt "--seed LIVRE: receptor do rsync em prioridade normal" "$STUB_LOG" 'rsync-path'
reset; STUB_LOCKED=0 STUB_IDLE_S=30 "$RUN" --seed wa >"$T/out" 2>"$T/err"; has "--seed EM USO: receptor do rsync em fundo" "$STUB_LOG" 'RSYNC:.*--rsync-path=taskpolicy -b rsync'

# --- slots: teto TOTAL por modo (o script de slot roda de verdade, sob a pasta falsa do MBP) ---
reset; for i in 1 2 3 4 5; do mkslot $i; done
rc=$(STUB_SLOTS=exec STUB_AVAIL_MB=30000 run -- tests/test_x.py); expect "livre com 5 slots ocupados e teto 12: roda" 0 "$rc"
has "pegou o slot 6" "$J" '"slot":"6"'; eq "slots 1..5 intactos e o 6 liberado" "1 2 3 4 5 " "$(slot_names)"
reset; for i in $(seq 1 12); do mkslot $i; done
rc=$(STUB_SLOTS=exec STUB_AVAIL_MB=30000 run -- tests/test_x.py); expect "livre com os 12 slots ocupados: 96" 96 "$rc"; has "mensagem diz o teto e o modo" "$T/err" 'teto 12, modo livre'
reset; mkslot 1
eq "livre limitado pela RAM (teto 2), slot 1 ocupado: pega o 2" "0:-" "$(STUB_SLOTS=exec STUB_AVAIL_MB=3900 outcome "$RUN")"; has "no slot 2" "$J" '"slot":"2"'
reset; mkslot 1; mkslot 2
rc=$(STUB_SLOTS=exec STUB_AVAIL_MB=3900 run -- tests/test_x.py); expect "livre limitado pela RAM (teto 2), 2 ocupados: 96" 96 "$rc"
reset; mkslot 2; mkslot 3
rc=$(STUB_SLOTS=exec STUB_LOCKED=0 STUB_IDLE_S=30 run -- tests/test_x.py); expect "EM USO com os slots 2 e 3 ocupados: 96 (o teto é do TOTAL, não dos números baixos)" 96 "$rc"
eq "o slot 1 que ele chegou a tomar foi devolvido; os alheios intactos" "2 3 " "$(slot_names)"; has "mensagem: teto 1, modo uso" "$T/err" 'teto 1, modo uso'
reset; rc=$(STUB_SLOTS=exec STUB_LOCKED=0 STUB_IDLE_S=30 run -- tests/test_x.py); expect "EM USO sem nada ocupado: roda" 0 "$rc"; has "no slot 1" "$J" '"slot":"1"'
reset; mkslot 1 "$(hostname -s):999999:$(date +%s)"
rc=$(STUB_SLOTS=exec STUB_LOCKED=0 STUB_IDLE_S=30 run -- tests/test_x.py); expect "EM USO com slot de dono morto: recolhe e roda" 0 "$rc"; has "avisa do slot morto" "$T/err" 'slot 1 morto'
reset; mkslot 1 "otherhost:1:$(( $(date +%s) - 20000 ))"
rc=$(STUB_SLOTS=exec STUB_LOCKED=0 STUB_IDLE_S=30 run -- tests/test_x.py); expect "EM USO com slot velho (> 4 h) de outro host: recolhe e roda" 0 "$rc"

# --- execução supervisionada: roda de verdade sob bash, com python/taskpolicy/renice falsos ---
reset; rc=$(STUB_RUNMODE=exec STUB_SLOTS=exec runs -- tests/test_x.py -q); expect "supervisionada, livre: roda" 0 "$rc"
has "livre: o python nasce com nice -n 10" "$STUB_LOG" '^NICE:-n 10$'; hasnt "livre: sem taskpolicy na largada" "$STUB_LOG" '^TP:'
has "a saída do python chega ao chamador" "$T/out" '5 passed'; hasnt "livre sem mudança: sem aviso de rebaixamento" "$T/out" 'mbp-run:demoted'
has "livre: log presence=livre demoted=0" "$J" '"presence":"livre","demoted":0'
has "o slot descreve a tarefa (repo, modo, arquivo, presença)" "$STUB_SEEN" '^repo=wa mode=pytest what=test_x\.py presence=livre$'
reset; rc=$(STUB_RUNMODE=exec STUB_RUN_RC=7 runs -- tests/test_x.py); expect "supervisionada: rc do pytest propaga" 7 "$rc"; has "log com rc 7" "$J" '"rc":7'
reset; rc=$(STUB_RUNMODE=exec STUB_LOCKED=0 STUB_IDLE_S=30 runs -- tests/test_x.py); expect "supervisionada, em uso: roda" 0 "$rc"
has "em uso: o python nasce com nice -n 19" "$STUB_LOG" '^NICE:-n 19$'; has "em uso: sob taskpolicy -b" "$STUB_LOG" 'TP:-b nice -n 19 '
has "em uso: log presence=uso" "$J" '"presence":"uso","demoted":0'
reset; rc=$(MBP_FORCE_PRESENCE=uso STUB_RUNMODE=exec runs -- tests/test_x.py); expect "forçado a uso com a tela bloqueada: roda" 0 "$rc"; has "forçado: nice -n 19" "$STUB_LOG" '^NICE:-n 19$'
# o Athos volta NO MEIO da execução (teclado): o vigia rebaixa a árvore
reset; rc=$(STUB_RUNMODE=exec STUB_WAIT_RENICE=60 STUB_FLIP_STATE='locked=0\nidle_s=2\n' runs -- tests/test_x.py)
expect "volta no meio: a execução termina normalmente" 0 "$rc"
has "avisa que o Athos voltou, com o motivo" "$T/out" '^\[mbp-run:demoted\] o Athos voltou ao MBP \(input_recente\)'
has "renice 19 na árvore" "$STUB_LOG" '^RENICE:-n 19 -p [0-9]+'; has "taskpolicy -b -p na árvore" "$STUB_LOG" '^TP:-b -p [0-9]+'
has "log: rebaixada no meio" "$J" '"presence":"livre","demoted":1'
# o Athos aciona a pausa NO MEIO da execução
reset; rc=$(STUB_RUNMODE=exec STUB_WAIT_RENICE=60 STUB_FLIP_PAUSE=1 runs -- tests/test_x.py)
expect "pausa no meio: termina normalmente" 0 "$rc"; has "avisa que ele pausou" "$T/out" '^\[mbp-run:demoted\] o Athos pausou o Gas City'; has "log: rebaixada" "$J" '"demoted":1'
# largou EM USO (já nasceu em fundo): o vigia continua cobrindo filhos novos, mas não anuncia "voltou" nem marca demoted
reset; rc=$(STUB_RUNMODE=exec STUB_RUN_SLEEP=3 STUB_LOCKED=0 STUB_IDLE_S=30 runs -- tests/test_x.py); expect "largou em uso: termina" 0 "$rc"
hasnt "largou em uso: sem aviso de 'voltou'" "$T/out" 'mbp-run:demoted'; has "largou em uso: demoted=0 no log" "$J" '"presence":"uso","demoted":0'
# ele não volta: ninguém é rebaixado
reset; rc=$(STUB_RUNMODE=exec STUB_RUN_SLEEP=3 runs -- tests/test_x.py); expect "sem mudança durante a execução: roda" 0 "$rc"
hasnt "sem mudança: nenhum renice" "$STUB_LOG" '^RENICE:'; hasnt "sem mudança: nenhum taskpolicy -p" "$STUB_LOG" '^TP:'
# o fim da execução NÃO espera o intervalo do vigia, e nada fica para trás
reset; SECONDS=0; rc=$(MBP_WATCH_S=37 STUB_RUNMODE=exec STUB_RUN_SLEEP=1 runs -- tests/test_x.py -k gc-leftover-token); el=$SECONDS
expect "intervalo longo do vigia: termina" 0 "$rc"; n=$((n+1)); if [ "$el" -lt 20 ]; then echo "ok   o fim da execução não espera o vigia (${el}s, intervalo 37 s)"; else echo "FAIL a execução esperou o vigia (${el}s)"; fails=$((fails+1)); fi
n=$((n+1)); if pgrep -f 'sleep 37' >/dev/null 2>&1 || pgrep -f gc-leftover-token >/dev/null 2>&1; then echo "FAIL ficou processo para trás (vigia ou python)"; fails=$((fails+1)); else echo "ok   nenhum processo para trás (vigia nem python)"; fi
# TERM/HUP no script remoto (ssh que cai): a árvore do trabalho morre, rc 143
reset; STUB_RUNMODE=exec runs -- tests/test_x.py -k gc-term-token >/dev/null
SCRIPT="$(dirname "$STUB_LOG")/last-script-RUN.sh"
n=$((n+1)); if [ -s "$SCRIPT" ]; then echo "ok   o stub guardou o script RUN enviado ao MBP"; else echo "FAIL script RUN não guardado"; fails=$((fails+1)); fi
HOME="$T/home" PATH="$FAKE:$PATH" STUB_REAL_SLEEP=1 STUB_RUN_SLEEP=25 "$STUB_REMOTE_BASH" -s < "$SCRIPT" >/dev/null 2>&1 &
RP=$!; sleep 3; kill -TERM "$RP" 2>/dev/null; wait "$RP" 2>/dev/null; trc=$?
eq "TERM no script remoto: rc 143" 143 "$trc"; sleep 1
n=$((n+1)); if pgrep -f gc-term-token >/dev/null 2>&1; then echo "FAIL o python sobreviveu ao TERM"; fails=$((fails+1)); pkill -f gc-term-token 2>/dev/null; else echo "ok   TERM mata a árvore do trabalho"; fi
# exec (REA/APK): mesmo caminho supervisionado, --env continua valendo
reset; printf '#!/usr/bin/env bash\necho "FOO=$FOO"\n' > "$T/bin/fakecmd"; chmod +x "$T/bin/fakecmd"
STUB_RUNMODE=exec STUB_LOCKED=0 STUB_IDLE_S=30 "$RUN" --exec --env FOO=bar -- "$T/bin/fakecmd" >"$T/out" 2>"$T/err"; expect "exec em uso" 0 "$?"
has "exec: --env chega ao comando" "$T/out" 'FOO=bar'; has "exec em uso: nice -n 19" "$STUB_LOG" '^NICE:-n 19$'; has "exec em uso: sob taskpolicy -b" "$STUB_LOG" 'TP:-b nice -n 19 '
reset; STUB_RUNMODE=exec "$RUN" --exec -- "$T/bin/fakecmd" >"$T/out" 2>"$T/err"; has "exec livre: nice -n 10" "$STUB_LOG" '^NICE:-n 10$'
# --go (ga-edkfip): as 3 variáveis de CGO do build de Go no MBP chegam ao comando sem o chamador copiá-las; um --env do chamador com o
# mesmo nome VENCE; --go sozinho implica --exec; com outro modo é uso errado (97) e nada roda
printf '#!/usr/bin/env bash\necho "CPP=$CGO_CPPFLAGS"\necho "LD=$CGO_LDFLAGS"\necho "CXX=$CGO_CXXFLAGS"\necho "FOO=$FOO"\n' > "$T/bin/gocmd"; chmod +x "$T/bin/gocmd"
reset; STUB_RUNMODE=exec "$RUN" --exec --go -- "$T/bin/gocmd" >"$T/out" 2>"$T/err"; expect "exec --go" 0 "$?"
has "--go: CGO_CPPFLAGS aponta o include do icu4c" "$T/out" '^CPP=-I/opt/homebrew/opt/icu4c/include$'
has "--go: CGO_LDFLAGS aponta a lib do icu4c" "$T/out" '^LD=-L/opt/homebrew/opt/icu4c/lib$'
has "--go: CGO_CXXFLAGS chega como UM valor com espaço (-isystem <SDK>/c++/v1)" "$T/out" '^CXX=-isystem /Library/Developer/CommandLineTools/SDKs/MacOSX\.sdk/usr/include/c\+\+/v1$'
reset; STUB_RUNMODE=exec "$RUN" --go -- "$T/bin/gocmd" >"$T/out" 2>"$T/err"; expect "--go sozinho implica --exec" 0 "$?"; has "--go sozinho: as variáveis chegaram" "$T/out" '^LD=-L/opt/homebrew/opt/icu4c/lib$'
reset; STUB_RUNMODE=exec "$RUN" --exec --go --env CGO_LDFLAGS=-L/outro --env FOO=bar -- "$T/bin/gocmd" >"$T/out" 2>"$T/err"; expect "--go com --env do chamador" 0 "$?"
has "--env do chamador com o mesmo nome VENCE o do --go" "$T/out" '^LD=-L/outro$'; has "--go mantém as outras duas" "$T/out" '^CPP=-I/opt/homebrew/opt/icu4c/include$'; has "--env de outro nome continua valendo" "$T/out" '^FOO=bar$'
reset; STUB_RUNMODE=exec "$RUN" --exec -- "$T/bin/gocmd" >"$T/out" 2>"$T/err"; hasnt "sem --go as variáveis de CGO NÃO aparecem" "$T/out" '^(CPP|LD|CXX)=.'
reset; "$RUN" --go --check >"$T/out" 2>"$T/err"; expect "--go com --check: 97 (uso errado)" 97 "$?"; has "--go com --check: a mensagem diz o porquê" "$T/err" '\-\-go só vale com \-\-exec'
reset; "$RUN" --go --seed wa >"$T/out" 2>"$T/err"; expect "--go com --seed: 97" 97 "$?"; hasnt "--go com --seed: nada foi falado com o MBP" "$STUB_LOG" 'SEED|RSYNC|HOSTCALL'
reset; "$RUN" --host linux --exec --go -- "$T/bin/gocmd" >"$T/out" 2>"$T/err"; expect "--host linux --exec --go: 97 (o nó não roda --exec)" 97 "$?"
# erro de configuração dentro do MBP: sem o espelho, rc 97
reset; find "$T/home/gt-remote/mirror/wa-1" -delete; rc=$(STUB_RUNMODE=exec runs -- tests/test_x.py); expect "espelho ausente: rc 97 (como antes)" 97 "$rc"; mkdir -p "$T/home/gt-remote/mirror/wa-1"

reset
}

# ---- A CHAVE MANUAL, O STATUS E O CONTROLE DENTRO DO MBP (ga-77c1qg.2) --------------------------------------------------
CONTROLE="$HERE/mbp-controle.sh"
OFFL="${MBP_OFFLOAD_UNDER_TEST:-$HERE/mbp-offload.sh}"
tdy() { PATH="${JQPIN:+$JQPIN:}$PATH" MBP_CITY="$T/city" bash "$OFFL" today 2>&1; }
t_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
t_ayer=$(date -u -v-30H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '30 hours ago' +%Y-%m-%dT%H:%M:%SZ)
r_line() { printf '{"ts":"%s","repo":"wa","mode":"pytest","slot":"1","rc":0,"secs":%s,"nargs":2%s}\n' "$1" "$2" "$3"; }
chave_cases() {
echo "--- chave manual, status e gascity-mbp (ga-77c1qg.2)"
reset
# --- chave de pausa do lado do MBP e instalação das ferramentas ---
reset; STUB_DIRECT_OUT=REMOVED "$RUN" --remote-pause off >"$T/out" 2>"$T/err"; expect "--remote-pause off: removida" 0 "$?"
reset; STUB_DIRECT_OUT=ABSENT "$RUN" --remote-pause off >"$T/out" 2>"$T/err"; expect "--remote-pause off: já não havia" 0 "$?"
reset; "$RUN" --remote-pause off >"$T/out" 2>"$T/err"; expect "--remote-pause off sem resposta do MBP: NÃO diz que saiu (98)" 98 "$?"
reset; STUB_DIRECT_OUT=STILL "$RUN" --remote-pause off >"$T/out" 2>"$T/err"; expect "--remote-pause off: o arquivo continuou lá (98)" 98 "$?"
reset; STUB_UNREACHABLE=1 "$RUN" --remote-pause off >"$T/out" 2>"$T/err"; expect "--remote-pause off com MBP inalcançável (98)" 98 "$?"
reset; "$RUN" --remote-pause on >"$T/out" 2>"$T/err"; expect "--remote-pause on" 0 "$?"; has "grava origem e data no MBP" "$STUB_LOG" "DIRECT:.*gt-remote/PAUSE"
reset; STUB_DIRECT_RC=1 "$RUN" --remote-pause on >"$T/out" 2>"$T/err"; expect "--remote-pause on que falha (98)" 98 "$?"
reset; "$RUN" --remote-pause talvez >"$T/out" 2>"$T/err"; expect "--remote-pause com argumento inválido (97)" 97 "$?"
reset; "$RUN" --install-tools >"$T/out" 2>"$T/err"; expect "--install-tools" 0 "$?"
has "instala a biblioteca" "$STUB_LOG" 'RSYNC:.*mbp-presence\.sh.*gt-remote/bin/mbp-presence\.sh'; has "instala o gascity-mbp" "$STUB_LOG" 'RSYNC:.*mbp-controle\.sh.*gt-remote/bin/gascity-mbp'
has "dá permissão de execução" "$STUB_LOG" 'DIRECT:.*chmod 755 gt-remote/bin/mbp-presence\.sh gt-remote/bin/gascity-mbp'
# o seed (reseed noturno) atualiza as ferramentas do MBP no fim e NUNCA falha por causa delas
if ls -d /Users/athos/gt/whatsapp_automation/venv/lib/python3.*/site-packages >/dev/null 2>&1; then
  reset; "$RUN" --seed wa >"$T/out" 2>"$T/err"; expect "--seed completo" 0 "$?"; has "o seed termina atualizando o gascity-mbp" "$STUB_LOG" 'RSYNC:.*mbp-controle\.sh.*gt-remote/bin/gascity-mbp'
  reset; STUB_RSYNC_FAIL_BIN=1 "$RUN" --seed wa >"$T/out" 2>"$T/err"; expect "--seed com a atualização das ferramentas falhando: a semeadura não falha" 0 "$?"; has "avisa que não atualizou" "$T/err" 'AVISO: não atualizei ~/gt-remote/bin'
else echo "SKIP --seed completo: venv local do WA ausente neste host (esse caminho NÃO foi exercitado)"; fi

# --- mbp-offload: modos do status, tarefas órfãs, JSON, pause/resume ---
cat > "$T/bin/fake-check" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--check" ]; then printf '%b\n' "${STUB_CHECK_OUT:-}"; exit "${STUB_CHECK_RC:-0}"; fi
echo "fake-run: $*" >> "$STUB_LOG"; exit "${STUB_REMOTE_RC:-0}"
EOF
chmod +x "$T/bin/fake-check"
CK_LIVRE='avail_mb=8000\npressure=1\nncpu=12\npresence=livre\npresence_why=bloqueada\nlocked=1\nidle_s=8114\ndisplay_hold=0\npaused=0\npause_info=\nswap_mb=5000\nswap_delta_mb=0\noffload_flag=on\npaused_local=0\npause_local_info=\nslot_cap=12'
st() { MBP_OFFLOAD_RUN="$T/bin/fake-check" MBP_CITY="$T/city" bash "$OFFL" status "$@" 2>&1; }
reset; rm -f "$FLAG"; STUB_CHECK_OUT="$CK_LIVRE"; export STUB_CHECK_OUT
has "status: sem a bandeira = DESLIGADO" <(st) '^Modo: DESLIGADO'
date > "$FLAG"
has "status: LIVRE com o porquê e o teto" <(st) '^Modo: LIVRE — Athos fora \(tela bloqueada\): até 12 tarefas ao mesmo tempo'
export STUB_CHECK_OUT='avail_mb=8000\npresence=uso\npresence_why=input_recente\nidle_s=42\npaused=0\nslot_cap=1'
has "status: EM USO, o porquê e 1 tarefa" <(st) '^Modo: EM USO — tratado como "Athos no MBP" \(teclado/mouse há 42 s\): no máximo 1 tarefa por vez, prioridade de fundo'
export STUB_CHECK_OUT='presence=uso\npresence_why=tela_em_uso\nidle_s=5000\npaused=0\nslot_cap=1'
has "status: tela segurada por app é dito" <(st) 'um app segura a tela acesa'
export STUB_CHECK_OUT='presence=uso\npresence_why=ilegivel:presenca\nidle_s=\npaused=0\nslot_cap=1'
has "status: presença ilegível é dita, não escondida" <(st) 'não consegui ler a presença \(presenca\): por segurança conta como em uso'
export STUB_CHECK_OUT='presence=livre\npresence_why=bloqueada\npaused=1\npause_info=origem=mbp desde=hoje\nslot_cap=12'
has "status: pausa no MBP = PAUSADO com a origem" <(st) '^Modo: PAUSADO \(origem=mbp desde=hoje\)'
export STUB_CHECK_OUT='presence=livre\npresence_why=bloqueada\npaused=0\nslot_cap=12\npause_local_info=origem=painel desde=ontem'; echo "origem=painel desde=ontem" > "$FLAG_PAUSE"
has "status: pausa local = PAUSADO com a origem" <(st) '^Modo: PAUSADO \(origem=painel desde=ontem\)'; rm -f "$FLAG_PAUSE"
export STUB_CHECK_OUT='avail_mb=\nxx=1'; STUB_CHECK_RC=98
has "status: MBP que não respondeu = INDEFINIDO, não 'livre' nem 'em uso'" <(st) '^Modo: INDEFINIDO — MBP inalcançável'
hasnt "status: inalcançável não inventa tarefas" <(st) 'Rodando agora'; unset STUB_CHECK_RC
# tarefas: viva (dono = este processo) e órfã (pid morto, mesmo host)
HN=$(hostname -s)
export STUB_CHECK_OUT="presence=livre\npresence_why=bloqueada\npaused=0\nslot_cap=12\ntask=1|$HN:$$:$(date +%s)|repo=wa mode=pytest what=test_x.py presence=livre|0\ntask=2|$HN:999999:$(( $(date +%s) - 120 ))|repo=wa mode=pytest what=test_y.py presence=livre|0\ntask=3|otherhost:7:$(date +%s)|repo=ps mode=exec what=rea presence=uso|0"
st > "$T/out"
has "status: conta só as tarefas vivas (2 de 3)" "$T/out" '^Rodando agora no MBP: 2 tarefa\(s\)'; has "status: tarefa viva descrita" "$T/out" 'slot 1: repo=wa mode=pytest what=test_x\.py'
has "status: slot de dono morto aparece como ÓRFÃO, não como rodando" "$T/out" 'slot 2: .*test_y\.py.*\[ÓRFÃO'
hasnt "status: a viva não é chamada de órfã" <(grep 'slot 1:' "$T/out") 'ÓRFÃO'
# controle negativo: sem a regra do dono morto, o slot órfão contaria como tarefa rodando (3 em vez de 2)
mutoff() { sed -e "$1" "$OFFL" > "$T/mutoff.sh"; chmod +x "$T/mutoff.sh"; cmp -s "$OFFL" "$T/mutoff.sh" && { n=$((n+1)); echo "FAIL controle $2: o sed não mudou nada"; fails=$((fails+1)); return 1; }; return 0; }
if mutoff 's/! kill -0 "\$p" 2>\/dev\/null; then continue; fi/false; then continue; fi/' orfa; then
  MBP_OFFLOAD_RUN="$T/bin/fake-check" MBP_CITY="$T/city" bash "$T/mutoff.sh" status > "$T/outm" 2>&1; n=$((n+1))
  if grep -q '^Rodando agora no MBP: 3 tarefa' "$T/outm"; then echo "ok   controle órfã: sem a regra o slot morto conta como rodando (3)"; else echo "FAIL controle órfã: o mutante ainda conta 2"; fails=$((fails+1)); fi; fi
# JSON
j=$(st --json); n=$((n+1)); if printf '%s' "$j" | jq -e . >/dev/null 2>&1; then echo "ok   status --json é JSON válido"; else echo "FAIL status --json não é JSON: $j"; fails=$((fails+1)); fi
eq "json: modo" livre "$(printf '%s' "$j" | jq -r .mode)"; eq "json: teto" 12 "$(printf '%s' "$j" | jq -r .slot_cap)"; eq "json: 3 tarefas listadas" 3 "$(printf '%s' "$j" | jq -r '.tasks | length')"
eq "json: chaves antigas continuam (offload, healthy, health, recent)" "true" "$(printf '%s' "$j" | jq -r 'has("offload") and has("healthy") and has("health") and has("recent")')"
eq "json: tarefas não vazam para dentro de health" "false" "$(printf '%s' "$j" | jq -r '.health | has("task")')"
eq "json: pausa local/MBP separadas" "false/false" "$(printf '%s' "$j" | jq -r '"\(.paused.local)/\(.paused.mbp)"')"
export STUB_CHECK_OUT='presence=uso\npresence_why=input_recente\nidle_s=42\npaused=0\nslot_cap=1'; j=$(st --json)
eq "json em uso: modo, ociosidade e porquê" "em_uso/42/input_recente" "$(printf '%s' "$j" | jq -r '"\(.mode)/\(.idle_s)/\(.mode_why)"')"
mkdir -p "$(dirname "$J")"; { r_line "$t_now" 4 ',"presence":"livre"'; printf '{"ts":"%s","repo":"wa","mode":"pytest","slot":"1","rc":0,"secs":4,"nargs":2,"presen' "$t_now"; echo; } > "$J"
j=$(st --json); n=$((n+1)); if printf '%s' "$j" | jq -e . >/dev/null 2>&1; then echo "ok   status --json continua JSON válido com linha truncada no log"; else echo "FAIL JSON quebrou com linha truncada no log"; fails=$((fails+1)); fi
unset STUB_CHECK_OUT
# nó Linux (ga-zri39b): bandeira própria, independente da chave do MBP
NF="$T/city/.gc/hetzner-node.on"
reset; MBP_CITY="$T/city" bash "$OFFL" node status >"$T/out" 2>&1; has "node status: desligado diz como ligar" "$T/out" '^DESLIGADO \(liga: mbp-offload\.sh node on\)'
MBP_CITY="$T/city" bash "$OFFL" node on >"$T/out" 2>&1; expect "node on" 0 "$?"; n=$((n+1)); if [ -f "$NF" ]; then echo "ok   node on cria a bandeira"; else echo "FAIL node on não criou a bandeira"; fails=$((fails+1)); fi
has "node on: o conteúdo é a hora (a sombra de 24 h conta daí)" "$NF" '^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:]+Z$'; has "node on: diz o que fica de reserva" "$T/out" 'LIGADO .*MBP.*mini'
MBP_CITY="$T/city" bash "$OFFL" node status >"$T/out" 2>&1; has "node status: ligado desde <hora>" "$T/out" '^LIGADO desde 20[0-9][0-9]-'
STUB_CHECK_OUT="$CK_LIVRE"; export STUB_CHECK_OUT; st > "$T/out"; has "status do MBP mostra a linha do nó" "$T/out" '^Nó Linux de testes: LIGADO desde 20'
j=$(st --json); eq "status --json: node.flag" on "$(printf '%s' "$j" | jq -r .node.flag)"; has "status --json: node.since é uma data" <(printf '%s' "$j" | jq -r .node.since) '^20[0-9][0-9]-'
eq "status --json: as chaves antigas continuam (aditivo)" "true" "$(printf '%s' "$j" | jq -r 'has("offload") and has("mode") and has("tasks") and has("today") and has("recent")')"
# a janela de 24 h da sombra (mbp-run.sh shadow_window_open) conta pelo MTIME da bandeira, não pelo conteúdo: `touch` a reabre (runbook). O "desde" do
# status tem de dizer a hora que VALE — pelo conteúdo, depois de um touch o status seguia mostrando a hora antiga do `node on`
TZ=UTC touch -t 202610150930.00 "$NF"
MBP_CITY="$T/city" bash "$OFFL" node status >"$T/out" 2>&1; has "node status depois de um touch: 'desde' é a hora do ARQUIVO (a que a sombra usa), não o conteúdo antigo" "$T/out" '^LIGADO desde 2026-10-15T09:30:00Z '
j=$(st --json); eq "status --json depois de um touch: node.since é a hora do arquivo" "2026-10-15T09:30:00Z" "$(printf '%s' "$j" | jq -r .node.since)"
# `node on` com a bandeira JÁ ligada não regrava: regravar muda o mtime e a sombra de 24 h recomeça sem ninguém ter pedido
before=$(stat -f %m "$NF" 2>/dev/null || stat -c %Y "$NF"); body_before=$(cat "$NF")
MBP_CITY="$T/city" bash "$OFFL" node on >"$T/out" 2>&1; expect "node on com a bandeira já ligada: rc 0" 0 "$?"
eq "node on repetido NÃO muda o mtime da bandeira (a sombra não reabre)" "$before" "$(stat -f %m "$NF" 2>/dev/null || stat -c %Y "$NF")"; eq "…nem o conteúdo" "$body_before" "$(cat "$NF")"
has "node on repetido: diz que já estava ligado, desde quando, e como reabrir de propósito" "$T/out" 'já LIGADO desde 2026-10-15T09:30:00Z .*NÃO foi regravada.*touch '
# node.since no --json: desligado = null; ligado e mtime ilegível = "unreadable" (os dois eram "" e só o node.flag distinguia)
mkdir -p "$T/nostat"; printf '#!/bin/sh\nexit 1\n' > "$T/nostat/stat"; chmod +x "$T/nostat/stat"
j=$(PATH="$T/nostat:$PATH" st --json); eq "status --json, bandeira ligada e mtime ilegível: node.since = \"unreadable\" (não \"\")" "unreadable" "$(printf '%s' "$j" | jq -r .node.since)"
eq "…e node.flag segue on" "on" "$(printf '%s' "$j" | jq -r .node.flag)"
mv "$NF" "$NF.bak"; j=$(st --json); eq "status --json, bandeira desligada: node.since = null" "null" "$(printf '%s' "$j" | jq -c .node.since)"; eq "…e node.flag = off" "off" "$(printf '%s' "$j" | jq -r .node.flag)"; mv "$NF.bak" "$NF"
unset STUB_CHECK_OUT
MBP_OFFLOAD_RUN="$T/bin/fake-check" MBP_CITY="$T/city" bash "$OFFL" off >"$T/out" 2>&1; n=$((n+1)); if [ -f "$NF" ]; then echo "ok   mbp-offload.sh off NÃO desliga o nó (bandeira independente)"; else echo "FAIL o off do MBP apagou a bandeira do nó"; fails=$((fails+1)); fi
MBP_OFFLOAD_RUN="$T/bin/fake-check" MBP_CITY="$T/city" bash "$OFFL" pause >"$T/out" 2>&1; n=$((n+1)); if [ -f "$NF" ]; then echo "ok   mbp-offload.sh pause NÃO desliga o nó"; else echo "FAIL a pausa do MBP apagou a bandeira do nó"; fails=$((fails+1)); fi
rm -f "$FLAG_PAUSE"; date > "$FLAG"
MBP_CITY="$T/city" bash "$OFFL" node off >"$T/out" 2>&1; expect "node off" 0 "$?"; n=$((n+1)); if [ ! -e "$NF" ]; then echo "ok   node off apaga a bandeira"; else echo "FAIL node off não apagou"; fails=$((fails+1)); fi
MBP_CITY="$T/city" bash "$OFFL" node off >"$T/out" 2>&1; expect "node off de novo (já desligado) é idempotente" 0 "$?"
MBP_CITY="$T/city" bash "$OFFL" node bogus >"$T/out" 2>&1; expect "node com argumento inválido: rc 2" 2 "$?"
# pause / resume
reset; unset STUB_REMOTE_RC
MBP_OFFLOAD_RUN="$T/bin/fake-check" MBP_CITY="$T/city" bash "$OFFL" pause >"$T/out" 2>&1; expect "pause" 0 "$?"
n=$((n+1)); if [ -s "$FLAG_PAUSE" ]; then echo "ok   pause grava o arquivo local ($(head -n 1 "$FLAG_PAUSE"))"; else echo "FAIL pause não gravou o arquivo"; fails=$((fails+1)); fi
has "pause empurra a pausa para o MBP" "$STUB_LOG" 'fake-run: --remote-pause on'; hasnt "pause com MBP ok: sem aviso" "$T/out" 'AVISO'
MBP_OFFLOAD_RUN="$T/bin/fake-check" MBP_CITY="$T/city" bash "$OFFL" resume >"$T/out" 2>&1; expect "resume" 0 "$?"
n=$((n+1)); if [ ! -e "$FLAG_PAUSE" ]; then echo "ok   resume remove o arquivo local"; else echo "FAIL resume não removeu"; fails=$((fails+1)); fi
has "resume tira a pausa do MBP" "$STUB_LOG" 'fake-run: --remote-pause off'
reset; STUB_REMOTE_RC=98 MBP_OFFLOAD_RUN="$T/bin/fake-check" MBP_CITY="$T/city" bash "$OFFL" pause >"$T/out" 2>&1; expect "pause com MBP inalcançável: pausa daqui vale" 0 "$?"
has "pause avisa que o MBP não recebeu" "$T/out" 'AVISO: o MBP não recebeu a pausa'; n=$((n+1)); if [ -s "$FLAG_PAUSE" ]; then echo "ok   a pausa local ficou"; else echo "FAIL pausa local perdida"; fails=$((fails+1)); fi
STUB_REMOTE_RC=98 MBP_OFFLOAD_RUN="$T/bin/fake-check" MBP_CITY="$T/city" bash "$OFFL" resume >"$T/out" 2>&1; expect "resume sem confirmar o MBP: NÃO libera (rc 1)" 1 "$?"
n=$((n+1)); if [ -s "$FLAG_PAUSE" ]; then echo "ok   a pausa local continua (estado inerte)"; else echo "FAIL resume apagou a pausa sem confirmar o MBP"; fails=$((fails+1)); fi
has "resume explica o que fazer" "$T/out" 'resume --local-only'
# controle negativo: sem confirmar que a pausa do MBP saiu, o resume apagaria a daqui (e o MBP seguiria pausado sem ninguém ver)
if mutoff 's/elif "\$RUN" --remote-pause off >\/dev\/null 2>&1; then rm -f "\$PAUSE"/elif true; then rm -f "$PAUSE"/' resume; then
  STUB_REMOTE_RC=98 MBP_OFFLOAD_RUN="$T/bin/fake-check" MBP_CITY="$T/city" bash "$T/mutoff.sh" resume >/dev/null 2>&1; n=$((n+1))
  if [ ! -e "$FLAG_PAUSE" ]; then echo "ok   controle resume: sem a confirmação do MBP a pausa daqui seria apagada"; else echo "FAIL controle resume: o mutante manteve a pausa"; fails=$((fails+1)); fi
  echo "origem=painel desde=hoje" > "$FLAG_PAUSE"; fi
: > "$STUB_LOG"; STUB_REMOTE_RC=98 MBP_OFFLOAD_RUN="$T/bin/fake-check" MBP_CITY="$T/city" bash "$OFFL" resume --local-only >"$T/out" 2>&1; expect "resume --local-only" 0 "$?"
n=$((n+1)); if [ ! -e "$FLAG_PAUSE" ]; then echo "ok   --local-only remove só a daqui"; else echo "FAIL --local-only não removeu"; fails=$((fails+1)); fi
hasnt "--local-only não tenta o MBP" "$STUB_LOG" 'fake-run: --remote-pause off'
MBP_OFFLOAD_RUN="$T/bin/fake-check" MBP_CITY="$T/city" bash "$OFFL" install-mbp >/dev/null 2>&1; has "install-mbp chama o mbp-run" "$STUB_LOG" 'fake-run: --install-tools'
MBP_OFFLOAD_RUN="$T/bin/fake-check" MBP_CITY="$T/city" bash "$OFFL" bogus >/dev/null 2>&1; expect "comando desconhecido: rc 2" 2 "$?"

# --- gascity-mbp (mbp-controle.sh), o controle de dentro do MBP ---
ctl() { HOME="$T/home" GASCITY_MBP_HOME="$T/home/gt-remote" PATH="$FAKE:$PATH" "$STUB_REMOTE_BASH" "$CONTROLE" "$@" 2>&1; }
reset; ctl status > "$T/out"; has "gascity-mbp status: LIVRE" "$T/out" '^Gas City: LIVRE — você está fora \(tela bloqueada\)'
STUB_LOCKED=0 STUB_IDLE_S=30 ctl status > "$T/out"; has "gascity-mbp status: EM USO" "$T/out" '^Gas City: EM USO — tratado como "você está no MBP" \(teclado/mouse há 30 s\)'
ctl pausar > "$T/out"; has "pausar avisa o efeito" "$T/out" 'PAUSADO neste MBP'; has "pausar grava origem=mbp" "$T/home/gt-remote/PAUSE" '^origem=mbp desde='
ctl status > "$T/out"; has "status depois de pausar: PAUSADO" "$T/out" '^Gas City: PAUSADO \(origem=mbp'
eq "o mbp-run enxerga a pausa feita pelo gascity-mbp" "99:pausado_mbp" "$(outcome "$RUN")"
ctl liberar > "$T/out"; has "liberar avisa" "$T/out" 'LIBERADO'; n=$((n+1)); if [ ! -e "$T/home/gt-remote/PAUSE" ]; then echo "ok   liberar apaga o arquivo"; else echo "FAIL liberar não apagou"; fails=$((fails+1)); fi
reset; mkslot 1 "otherhost:1:$(date +%s)"; printf 'repo=wa mode=pytest what=test_x.py presence=livre\n' > "$T/home/gt-remote/slots/1/info"; mkslot 2 "otherhost:2:$(( $(date +%s) - 20000 ))"
ctl status > "$T/out"; has "status: conta 1 tarefa (a velha é órfã)" "$T/out" '^Tarefas do Gas City rodando aqui: 1$'; has "status: órfã identificada" "$T/out" 'slot 2: .*provável órfão'
ctl menubar > "$T/out"; eq "menubar livre: título" "🟢 Gas City: 1" "$(sed -n 1p "$T/out")"; has "menubar tem a ação de pausar" "$T/out" '^Pausar até eu liberar \| bash=.* param1=pausar '
STUB_LOCKED=0 STUB_IDLE_S=30 ctl menubar > "$T/out"; eq "menubar em uso: título" "🟠 Gas City: 1" "$(sed -n 1p "$T/out")"
echo "origem=mbp desde=x" > "$T/home/gt-remote/PAUSE"; ctl menubar > "$T/out"; eq "menubar pausado: título" "⏸ Gas City: pausado" "$(sed -n 1p "$T/out")"
reset; GASCITY_MBP_LIB=/nonexistent ctl status > "$T/out"; rc=$?; has "sem a biblioteca: diz o que fazer" "$T/out" 'install-mbp'
ctl bogus >/dev/null; expect "gascity-mbp comando desconhecido: rc 2" 2 "$?"

# --- total do dia (sob cada jq conhecido) ---
today_cases() { local L="$1"
reset; eq "hoje[$L]: sem log" "sem log ainda" "$(tdy)"
reset; mkdir -p "$(dirname "$J")"; : > "$J"; eq "hoje[$L]: log vazio é 0, não ilegível" "0 execuções, 0 min no MBP (livre: 0, em uso: 0)" "$(tdy)"
reset; mkdir -p "$(dirname "$J")"; { r_line "$t_now" 4 ',"presence":"livre","demoted":0'; r_line "$t_now" 60 ',"presence":"uso","demoted":1'; r_line "$t_now" 30 ''
  r_line "$t_ayer" 600 ',"presence":"livre"'; printf '{"ts":"%s","repo":"-","mode":"preflight","slot":"-","rc":98,"secs":0,"nargs":0,"reason":"ram"}\n' "$t_now"; } > "$J"
eq "hoje[$L]: separa livre/em uso/sem presença; ontem e recusa ficam fora" "3 execuções, 1 min no MBP (livre: 1, em uso: 1, sem presença registrada: 1)" "$(tdy)"
reset; mkdir -p "$(dirname "$J")"; { r_line "$t_now" 120 ',"presence":"livre","demoted":0,"host":"hetzner"'; r_line "$t_now" 60 ',"presence":"uso","demoted":0'; r_line "$t_now" 30 ',"presence":"livre","host":"hetzner"'; } > "$J"
eq "hoje[$L]: o nó Linux fica FORA dos minutos do MBP e vem à parte" "1 execuções, 1 min no MBP (livre: 0, em uso: 1) + 2 no nó Linux (2 min)" "$(tdy)"
reset; mkdir -p "$(dirname "$J")"; { r_line "$t_now" 120 ',"presence":"livre","host":"hetzner"'; } > "$J"
eq "hoje[$L]: só execuções do nó: 0 no MBP, sem inventar presença" "0 execuções, 0 min no MBP (livre: 0, em uso: 0) + 1 no nó Linux (2 min)" "$(tdy)"
reset; mkdir -p "$(dirname "$J")"; { r_line "$t_now" 4 ',"presence":"livre","host":"mbp"'; } > "$J"
eq "hoje[$L]: host=mbp explícito conta como MBP, sem a parte do nó" "1 execuções, 0 min no MBP (livre: 1, em uso: 0)" "$(tdy)"
reset; mkdir -p "$(dirname "$J")"; { r_line "$t_now" 4 ',"presence":"livre"'; printf '{"ts":"%s","repo":"wa","mode":"pyt' "$t_now"; echo; } > "$J"
eq "hoje[$L]: linha truncada é avisada" "1 execuções, 0 min no MBP (livre: 1, em uso: 0); 1 linha(s) ilegível(is) no log (não contadas)" "$(tdy)"
reset; mkdir -p "$(dirname "$J")"; { r_line "$t_now" 4 ',"presence":"livre"'; printf '{"ts":"ontem","repo":"wa","mode":"pytest","secs":1}\n'; echo null; } > "$J"
eq "hoje[$L]: ts ilegível e linha que não é objeto são avisados" "1 execuções, 0 min no MBP (livre: 1, em uso: 0); 2 linha(s) ilegível(is) no log (não contadas)" "$(tdy)"
# só hetzner|mbp (ou sem o campo = mbp) são hosts conhecidos: "hetzner2" não pode virar minuto do MBP só porque "não é hetzner"
reset; mkdir -p "$(dirname "$J")"; { r_line "$t_now" 4 ',"presence":"livre"'; r_line "$t_now" 60 ',"presence":"livre","host":"hetzner2"'; } > "$J"
eq "hoje[$L]: host que não é hetzner nem mbp é avisado, não vira minuto do MBP" "1 execuções, 0 min no MBP (livre: 1, em uso: 0); 1 linha(s) ilegível(is) no log (não contadas)" "$(tdy)"
reset; mkdir -p "$(dirname "$J")"; { r_line "$t_now" 4 ',"presence":"livre"'; r_line "$t_ayer" 60 ',"presence":"livre","host":"hetzner2"'; } > "$J"
eq "hoje[$L]: host desconhecido de ONTEM fica fora (a janela é a de hoje)" "1 execuções, 0 min no MBP (livre: 1, em uso: 0)" "$(tdy)"
# secs que não é número (texto, null, ausente) não soma: a linha é AVISADA — sem isso "N execuções" teria mais linhas que os minutos somados e o total pareceria completo
reset; mkdir -p "$(dirname "$J")"; { r_line "$t_now" 120 ',"presence":"livre"'; r_line "$t_now" '"x"' ',"presence":"livre"'; r_line "$t_now" null ',"presence":"livre"'; } > "$J"
eq "hoje[$L]: secs não numérico (texto, null) é avisado e não entra na conta" "1 execuções, 2 min no MBP (livre: 1, em uso: 0); 2 linha(s) ilegível(is) no log (não contadas)" "$(tdy)"
reset; mkdir -p "$(dirname "$J")"; { r_line "$t_now" 120 ',"presence":"livre","host":"hetzner"'; r_line "$t_now" '"x"' ',"presence":"livre","host":"hetzner"'; } > "$J"
eq "hoje[$L]: o mesmo no nó Linux: avisado, e o '+ N no nó' não conta a linha sem tempo" "0 execuções, 0 min no MBP (livre: 0, em uso: 0) + 1 no nó Linux (2 min); 1 linha(s) ilegível(is) no log (não contadas)" "$(tdy)"
}
JQPIN=""; today_cases "jq do PATH"
for cand in /usr/bin/jq /opt/homebrew/bin/jq; do
  if [ -x "$cand" ]; then d="$T/jqpin$(printf '%s' "$cand" | tr '/' '_')"; mkdir -p "$d"; ln -sf "$cand" "$d/jq"; JQPIN="$d"; today_cases "$cand $("$cand" --version 2>&1)"
  else echo "SKIP total do dia sob $cand: não existe neste host (esse jq NÃO foi exercitado)"; fi
done
JQPIN=""
reset; mkdir -p "$(dirname "$J")" "$T/nojq"; r_line "$t_now" 4 '' > "$J"; ln -sf "$(command -v date)" "$T/nojq/date"; ln -sf "$(command -v dirname)" "$T/nojq/dirname"
eq "hoje: jq ausente é 'ilegível', nunca '0 execuções'" "ilegível" "$(PATH="$T/nojq" MBP_CITY="$T/city" /bin/bash "$OFFL" today 2>&1)"
reset
}

# ---- controles negativos da presença -------------------------------------------------------------------------------
# Cada mutante tira UMA regra e TEM que deixar de reproduzir o resultado do script real no cenário que a regra guarda.
mut_compare() { # rótulo esperado cenário(função) arquivo-original sed-expr destino-da-mutante
  local label="$1" want="$2" scen="$3" src="$4" expr="$5" dst="$6" real mut
  sed -e "$expr" "$src" > "$dst"; chmod +x "$dst"
  cmp -s "$src" "$dst" && { n=$((n+1)); echo "FAIL controle $label: o sed não mudou nada (marcador sumiu?)"; fails=$((fails+1)); return 0; }
  real=$($scen real); mut=$($scen mut)
  eq "controle $label: o script real dá '$want'" "$want" "$real"
  n=$((n+1)); if [ "$mut" != "$want" ]; then echo "ok   controle $label: a mutante sem a regra não reproduz ($mut)"; else echo "FAIL controle $label: a mutante ainda reproduz '$want'"; fails=$((fails+1)); fi
}
neg_presenca() {
  echo "--- controles negativos (presença)"
  cp "$LIB" "$T/lib.real"; cp "$LIB" "$T/mbp-presence.sh"; cp "$CONTROLE" "$T/mbp-controle.sh"
  # biblioteca: cenários que chamam a lib mutante
  sc_lib() { reset; if [ "$1" = mut ]; then LIBX="$T/lib.mut"; else LIBX=""; fi; "$2"; LIBX=""; }
  s1() { STUB_LOCKED=0 STUB_IDLE_S=5000 STUB_ASSERT_FAIL=1 verdict; }
  s2() { STUB_LOCKED=0 STUB_IDLE_S=600 verdict; }
  s3() { STUB_LOCKED=0 STUB_IDLE_S=5000 STUB_HOLD=1 verdict; }
  s4() { STUB_LOCKED=1 STUB_IDLE_S=5 verdict; }
  s5() { STUB_LOCKED=notconsole STUB_IDLE_S=fail verdict; }
  s6() { STUB_LOCKED=0 STUB_IDLE_S=fail verdict; }
  s7() { PRESENCE_FORCE_USO=1 STUB_LOCKED=1 verdict; }
  c1() { sc_lib "$1" s1; }; c2() { sc_lib "$1" s2; }; c3() { sc_lib "$1" s3; }; c4() { sc_lib "$1" s4; }; c5() { sc_lib "$1" s5; }; c6() { sc_lib "$1" s6; }; c7() { sc_lib "$1" s7; }
  mut_compare "lib: tela ilegível virou livre" "uso/ilegivel:tela" c1 "$LIB" 's/else PR_WHY=ilegivel:tela; fi/else PR_MODE=livre; PR_WHY=ilegivel:tela; fi/' "$T/lib.mut"
  mut_compare "lib: fronteira de 600 s (-lt virou -le)" "livre/ocioso" c2 "$LIB" 's/-lt "\$PRESENCE_AWAY_S"/-le "$PRESENCE_AWAY_S"/' "$T/lib.mut"
  mut_compare "lib: app segurando a tela é ignorado" "uso/tela_em_uso" c3 "$LIB" 's/elif \[ "\$PR_HOLD" = 0 \]; then/elif true; then/' "$T/lib.mut"
  mut_compare "lib: bloqueada deixa de valer" "livre/bloqueada" c4 "$LIB" 's/elif \[ "\$PR_LOCKED" = 1 \]; then PR_MODE=livre/elif false; then PR_MODE=livre/' "$T/lib.mut"
  mut_compare "lib: bloqueio ilegível lido como desbloqueado" "uso/ilegivel:presenca" c5 "$LIB" 's/^  echo$/  echo 0/' "$T/lib.mut"
  mut_compare "lib: ociosidade ilegível lida como 'muito tempo'" "uso/ilegivel:ociosidade" c6 "$LIB" 's/^  \[ -n "\$raw" \] || { echo; return; }/  [ -n "$raw" ] || { echo 99999; return; }/' "$T/lib.mut"
  mut_compare "lib: PRESENCE_FORCE_USO deixa de valer" "uso/forcado" c7 "$LIB" 's/if \[ "\${PRESENCE_FORCE_USO:-0}" = 1 \]; then/if false; then/' "$T/lib.mut"
  # mbp-run: a mutante mora em $T (junto da cópia da biblioteca)
  sm_occ() { reset; mkslot 2; mkslot 3; local s=$RUN; [ "$1" = mut ] && s="$T/mut.sh"; STUB_SLOTS=exec STUB_LOCKED=0 STUB_IDLE_S=30 outcome "$s"; }
  sm_cap_unknown() { reset; local s=$RUN; [ "$1" = mut ] && s="$T/mut.sh"; STUB_PF_RAW="$PF_OK" capof "$s"; }
  sm_pause_remote() { reset; echo "origem=mbp desde=hoje" > "$T/home/gt-remote/PAUSE"; local s=$RUN; [ "$1" = mut ] && s="$T/mut.sh"; outcome "$s"; }
  sm_pause_local() { reset; echo "origem=painel desde=hoje" > "$FLAG_PAUSE"; local s=$RUN; [ "$1" = mut ] && s="$T/mut.sh"; outcome "$s"; }
  sm_cap_uso() { reset; local s=$RUN; [ "$1" = mut ] && s="$T/mut.sh"; STUB_LOCKED=0 STUB_IDLE_S=30 STUB_AVAIL_MB=30000 capof "$s"; }
  sm_seed_bg() { reset; local s=$RUN; [ "$1" = mut ] && s="$T/mut.sh"; STUB_LOCKED=0 STUB_IDLE_S=30 "$s" --seed wa >/dev/null 2>&1; grep -c 'rsync-path' "$STUB_LOG"; }   # 2 = os dois rsync da semeadura (árvore-base e site-packages)
  sm_demote() { reset; local s=$RUN; [ "$1" = mut ] && s="$T/mut.sh"
    STUB_RUNMODE=exec STUB_WAIT_RENICE=16 MBP_WATCH_S=1 STUB_FLIP_STATE='locked=0\nidle_s=2\n' runx "$s" tests/test_x.py >/dev/null; grep -c '^RENICE:' "$STUB_LOG" | sed 's/^[1-9][0-9]*$/demoted/'; }
  sm_start_bg() { reset; local s=$RUN; [ "$1" = mut ] && s="$T/mut.sh"; STUB_RUNMODE=exec STUB_LOCKED=0 STUB_IDLE_S=30 runx "$s" tests/test_x.py >/dev/null; sed -n 's/^NICE:-n \([0-9]*\)$/nice\1/p' "$STUB_LOG" | head -n 1; }
  sm_cap_mem() { reset; local s=$RUN; [ "$1" = mut ] && s="$T/mut.sh"; STUB_AVAIL_MB=3840 capof "$s"; }
  mut_compare "run: teto total (checagem de ocupação depois do mkdir)" "96:-" sm_occ "$RUN" 's/-le \$cap \]; then echo "SLOT=\\\$n"/-le 999 ]; then echo "SLOT=\\$n"/' "$T/mut.sh"
  mut_compare "run: presença desconhecida virou livre" 1 sm_cap_unknown "$RUN" 's/\*) PRES=uso; PRES_WHY=\${PRES_WHY:-ilegivel:presenca} ;; esac/*) PRES=livre ;; esac/' "$T/mut.sh"
  mut_compare "run: pausa no MBP deixa de valer" "99:pausado_mbp" sm_pause_remote "$RUN" 's/\[ "\$(pf_get paused)" = 1 \]/[ "$(pf_get pausedX)" = 1 ]/' "$T/mut.sh"
  mut_compare "run: pausa local deixa de valer" "99:-" sm_pause_local "$RUN" '/pausado pelo Athos (\$(head -n 1/s/.*/true/' "$T/mut.sh"
  mut_compare "run: teto do modo EM USO" 1 sm_cap_uso "$RUN" 's/  else echo "\$USE_SLOTS"; fi/  else echo 12; fi/' "$T/mut.sh"
  mut_compare "run: seed em uso deixa de usar prioridade de fundo" 2 sm_seed_bg "$RUN" 's/\[ "\$PRES" = livre \] || RSYNC_PATH_OPT=(--rsync-path="taskpolicy -b rsync")/true/' "$T/mut.sh"
  mut_compare "run: vigia deixa de rebaixar" demoted sm_demote "$RUN" 's/    if ! mbp_calm; then$/    if false; then/' "$T/mut.sh"
  mut_compare "run: largada em uso deixa de ser em fundo" nice19 sm_start_bg "$RUN" 's/  if ! mbp_calm; then MBP_STARTED_CALM=0;/  if false; then MBP_STARTED_CALM=0;/' "$T/mut.sh"
  mut_compare "run: teto pela RAM" 2 sm_cap_mem "$RUN" 's/\[ "\$mem" -ge "\$cpu" \] || cpu=\$mem/true/' "$T/mut.sh"
}

# ---- O NÓ LINUX (ga-zri39b) ------------------------------------------------------------------------------------------------------
# O ssh stub reconhece o host pelo argumento (hetzner-teste = nó, o resto = MBP) e grava HOSTCALL:<host>:<NOME> no log; o preflight do nó roda DE VERDADE contra um /proc falso
# ($STUB_PROCDIR, gerado a partir de STUB_N_*); o rsync pode rodar de verdade (STUB_RSYNC_REAL=1) para o teste de vazamento. Nada toca o servidor nem o live.
NODEFLAG="$T/city/.gc/hetzner-node.on"; LEARNED="$T/city/.gc/hetzner-mac-only.learned"; SHLOG="$T/city/.gc/logs/hetzner-shadow.jsonl"; MACONLY="$T/mac-only.txt"
XDIST_DIR="$T/home/gt-remote/venv-wa/lib/python3.14/site-packages/pytest_xdist-3.8.0.dist-info"
xdist_on()  { mkdir -p "$XDIST_DIR"; mkdir -p "$T/home/gt-remote/venv-wa/lib/python3.14/site-packages"; }
xdist_off() { rmdir "$XDIST_DIR" 2>/dev/null; mkdir -p "$T/home/gt-remote/venv-wa/lib/python3.14/site-packages"; }
xdist_gone() { rmdir "$XDIST_DIR" 2>/dev/null; rmdir "$T/home/gt-remote/venv-wa/lib/python3.14/site-packages" "$T/home/gt-remote/venv-wa/lib/python3.14" "$T/home/gt-remote/venv-wa/lib" 2>/dev/null; }
nrun() { "$RUN" --host linux --repo wa --dir "$T/wt" -- "$@" >"$T/out" 2>"$T/err"; echo $?; }       # só o nó (sem cadeia)
pfv() { "$RUN" --host linux --check 2>/dev/null | sed -n "s/^$1=//p"; }
# "rc:motivo" de uma execução SÓ no nó (a última recusa do log); a bandeira do nó tem de estar ligada
outcome_n() { local rc r; rm -f "$J"; "$RUN" --host linux --repo wa --dir "$T/wt" -- tests/test_x.py >/dev/null 2>&1; rc=$?
  r=$(grep '"mode":"preflight"' "$J" 2>/dev/null | tail -1 | sed -n 's/.*"reason":"\([^"]*\)".*/\1/p'); echo "$rc:${r:--}"; }
lastscript() { cat "$T/last-script-$1-$2.sh" 2>/dev/null; }     # conteúdo do script remoto que o mbp-run mandou: NOME host
lsf() { echo "$T/last-script-$1-$2.sh"; }                          # o CAMINHO desse script (has/hasnt leem arquivo)
ok() { n=$((n+1)); echo "ok   $1"; }
bad() { n=$((n+1)); echo "FAIL $1"; fails=$((fails+1)); }
LEAKS="x.duckdb lib/leak.duckdb tests/fixtures/y.duckdb tests/y.db .env lib/.env.pdpj contacts_auth/client_secret.json data/a.txt viewer/data/b.py shared/logs/a.out logs/l.txt lib/x.csv tests/z.csv lib/k.pem lib/t.parquet lib/b.gz lib/c.pkl .gc/state"
# a classe que o gate achou (14/10): credencial com nome que nenhuma denylist conhecia + formato/pasta que nenhuma lista previa
# a classe da 2ª revisão (14/10): arquivo de NOME NEUTRO com dado de cliente dentro, em pasta que a lista por extensão deixava sair; e o que TEM que chegar (config por caminho + código)
NEUTRAL="docs/auto_response/ab_results/cycle1_new_rules_200.json scripts/campanhas_aprovar_enriquecer_estado.json docs/pix_verdicts/pix_verdicts.json analysis/numero_certo/results/baseline.json scripts/peter/mrv_bh/socios_cache.json state.json config.json hex_cells/fixtures/status.json daemons/static/map_viewer/piloto3d.json docs/relatorio.md docs/page.html processo_lookup/consulta.html lib/export.sql scripts/export.sql assets/warming_docs/pool.json lib/README.md lib/export.html"
OKCFG="lib/changelog.d/a.json lib/silence.yml daemons/deploy_deps.json daemons/restart_policy.yaml daemons/anuncios/changelog.d/app/c.json templates/auto_responses/a.json templates/pregao.html daemons/templates/d.html migrations/0001.sql launchd/l.plist deploy/d.plist daemons/launchd/dl.plist scripts/s.plist pytest.ini requirements.txt CLAUDE.md AGENTS.md docs/superpowers/runbooks/job-agendado-veredito-alerta.md viewer/app.js viewer/x.mjs lib/x.ts lib/style.css"
# o CONTEÚDO que o node_guard olha: LISTA de telefones/CPFs fica no mini mesmo em nome e pasta liberados (HELDF); 3 números, ou 32 de cauda sintética, passam (PASSF)
HELDF="lib/leads_list.py lib/changelog.d/dump.json tests/fixtures/cpfs.json"; PASSF="lib/few.py lib/synthetic.py"
LEAKS="$LEAKS processo_lookup/.pdpj_token.txt .netrc lib/.pgpass token.txt lib/api_token lib/access_token.json service_account.json secrets.json lib/app.keystore lib/token.pickle lib/GOOGLE_TOKEN.json lib/Secrets.YAML tests/fixtures/token.json tests/fixtures/.token tests/fixtures/secrets.yaml lib/dump.zip lib/leads.ndjson lib/notes.txt lib/shot.png run.log .runtime/s.json witness/s.json docs/mrv_artifacts/mrv_decisores.json lib.bak-1/a.py .gc-worktrees/wa-x/lib/a.py .worktrees/wa-y/lib/a.py"

# Host do MBP (ga-bmmxka): sem MBP_HOST o padrão é o nome do Tailscale (a rota .local cai com a tela do MBP travada); a LAN só entra com a porta 22
# dela respondendo e a do Tailscale muda; MBP_HOST do chamador vale como está e nunca é sondado. O stub do ssh grava os argumentos (STUB_ARGS_LOG).
host_cases() {
echo "--- host do MBP: Tailscale por padrão, LAN só com evidência (ga-bmmxka)"
local al="$T/ssh-args" pl="$T/hostprobe.log" rc TSRE LANRE
TSRE=' athos@athoss-macbook-pro( |$)'; LANRE=' athos@athoss-macbook-pro\.local( |$)'
hostrun() { reset; : > "$al"; : > "$pl"; env "$@" STUB_ARGS_LOG="$al" HOSTPROBE_LOG="$pl" "$RUN" --remote-pause on >"$T/out" 2>"$T/err"; echo $?; }
rc=$(hostrun HOSTPROBE_UP="athoss-macbook-pro athoss-macbook-pro.local"); expect "padrão, os dois respondem" 0 "$rc"
has "…o ssh vai ao nome do Tailscale" "$al" "$TSRE"; hasnt "…e não ao .local" "$al" 'macbook-pro\.local'
has "…e a sonda perguntou pela porta 22 do Tailscale" "$pl" '^athoss-macbook-pro 22$'
rc=$(hostrun HOSTPROBE_UP="athoss-macbook-pro.local"); expect "só a LAN responde" 0 "$rc"
has "…o ssh vai à LAN (evidência positiva)" "$al" "$LANRE"; hasnt "…e não ao Tailscale" "$al" "$TSRE"
rc=$(hostrun HOSTPROBE_UP=""); expect "nenhum responde" 0 "$rc"
has "…volta ao Tailscale (o padrão inerte, nunca a LAN)" "$al" "$TSRE"; hasnt "…e não ao .local" "$al" 'macbook-pro\.local'
rc=$(hostrun HOSTPROBE_UP="athoss-macbook-pro.local" MBP_HOST=fake@mbp); expect "MBP_HOST do chamador" 0 "$rc"
has "…vale como está" "$al" ' fake@mbp( |$)'; hasnt "…sem trocar por nenhum dos dois" "$al" 'athoss-macbook-pro'
n=$((n+1)); if [ ! -s "$pl" ]; then echo "ok   …e nunca é sondado"; else echo "FAIL MBP_HOST do chamador foi sondado: $(cat "$pl")"; fails=$((fails+1)); fi
# um modo de pytest (passa por use_host) agrega ao mesmo host
reset; : > "$al"; date > "$FLAG"; rc=$(STUB_ARGS_LOG="$al" run -- tests/test_x.py); expect "pytest no MBP com o padrão" 0 "$rc"
has "…fala com o nome do Tailscale" "$al" "$TSRE"; hasnt "…e não com o .local" "$al" 'macbook-pro\.local'
# a sonda é preguiçosa: só quem vai falar com o MBP paga os ~2 s dela
reset; xdist_on; date > "$FLAG"; date > "$NODEFLAG"; : > "$pl"; rc=$(HOSTPROBE_LOG="$pl" run -- tests/test_x.py); expect "pytest que roda no nó" 0 "$rc"
n=$((n+1)); if [ ! -s "$pl" ]; then echo "ok   …não sonda o MBP (ele nem entra)"; else echo "FAIL rodou no nó e sondou o MBP: $(cat "$pl")"; fails=$((fails+1)); fi
reset; rm -f "$FLAG" "$NODEFLAG"; : > "$pl"; rc=$(HOSTPROBE_LOG="$pl" run -- tests/test_x.py); expect "offload desligado" 99 "$rc"
n=$((n+1)); if [ ! -s "$pl" ]; then echo "ok   …não sonda o MBP (a bandeira barra antes)"; else echo "FAIL offload desligado e sondou o MBP: $(cat "$pl")"; fails=$((fails+1)); fi
}
node_cases() {
echo "--- nó Linux de testes (ga-zri39b)"
local rc out f
reset; xdist_on; date > "$FLAG"

# ===== a cadeia nó -> MBP -> local =====
reset; rc=$(run -- tests/test_x.py); expect "nó desligado (sem a bandeira): roda no MBP como sempre" 0 "$rc"
hasnt "nó desligado: nenhuma chamada ao nó" "$STUB_LOG" 'HOSTCALL:hetzner'; has "nó desligado: o log marca host=mbp" "$J" '"host":"mbp"'; hasnt "nó desligado: o log não cita hetzner" "$J" 'hetzner'
reset; date > "$NODEFLAG"; rc=$(run -- tests/test_x.py); expect "nó ligado e saudável: roda" 0 "$rc"
has "roda no nó: log host=hetzner" "$J" '"mode":"pytest".*"host":"hetzner"'; hasnt "…e não toca o MBP" "$STUB_LOG" 'HOSTCALL:mbp'; has "diz onde rodou" "$T/err" 'rodou em hetzner \(nó Linux\)'
has "o preflight do nó tem presença livre no slot" "$J" '"presence":"livre"'
reset; date > "$NODEFLAG"; rc=$(STUB_RUN_RC_NODE=3 run -- tests/test_x.py); expect "o rc do pytest no nó é propagado (3)" 3 "$rc"; has "…e logado" "$J" '"rc":3.*"host":"hetzner"'; hasnt "…sem tentar o MBP" "$STUB_LOG" 'HOSTCALL:mbp'
reset; date > "$NODEFLAG"; rc=$(STUB_UNREACHABLE_NODE=1 run -- tests/test_x.py); expect "nó inalcançável: cai no MBP e roda" 0 "$rc"
has "nó inalcançável: recusa do nó no log, com motivo e host" "$J" '"mode":"preflight".*"reason":"inalcancavel".*"host":"hetzner"'; has "…e a execução é do MBP" "$J" '"mode":"pytest".*"host":"mbp"'
has "avisa que tentou o MBP" "$T/err" 'o nó Linux não rodou \(rc=98\) — tentando o MBP'; has "mensagem fala do nó, não do MBP" "$T/err" 'nó Linux inalcançável'
reset; date > "$NODEFLAG"; rc=$(STUB_N_AVAIL_MB=1000 run -- tests/test_x.py); expect "nó sem RAM: cai no MBP" 0 "$rc"; has "motivo ram no host hetzner" "$J" '"reason":"ram".*"host":"hetzner"'; has "mensagem fala do nó" "$T/err" 'nó Linux sem RAM livre'
reset; date > "$NODEFLAG"; rc=$(STUB_UNREACHABLE=1 run -- tests/test_x.py); expect "nó E MBP fora: 98 (quem chamou roda local)" 98 "$rc"
reset; date > "$NODEFLAG"; rm -f "$FLAG"; rc=$(run -- tests/test_x.py); expect "MBP desligado mas nó ligado: roda no nó" 0 "$rc"; has "…host=hetzner" "$J" '"host":"hetzner"'
reset; date > "$NODEFLAG"; rm -f "$FLAG"; rc=$(STUB_UNREACHABLE_NODE=1 run -- tests/test_x.py); expect "nó fora e MBP desligado: 99" 99 "$rc"
date > "$FLAG"
reset; date > "$NODEFLAG"; echo "origem=painel desde=hoje" > "$FLAG_PAUSE"; rc=$(run -- tests/test_x.py); expect "pausa do Athos (é do notebook dele) NÃO vale para o nó" 0 "$rc"; has "…roda no nó" "$J" '"host":"hetzner"'
reset; date > "$NODEFLAG"; echo "origem=painel desde=hoje" > "$FLAG_PAUSE"; rc=$(STUB_UNREACHABLE_NODE=1 run -- tests/test_x.py); expect "nó fora e MBP pausado: 99" 99 "$rc"
reset; date > "$NODEFLAG"; rc=$("$RUN" --repo ps --dir "$T/wt" -- tests/test_x.py >/dev/null 2>&1; echo $?); expect "repo ps: o nó só tem o wa, roda no MBP" 0 "$rc"
hasnt "ps: nenhuma chamada ao nó" "$STUB_LOG" 'HOSTCALL:hetzner'; hasnt "ps: não grava recusa do nó (não é recusa)" "$J" '"host":"hetzner"'
reset; date > "$NODEFLAG"; printf '#!/usr/bin/env bash\necho x\n' > "$T/bin/fakecmd"; chmod +x "$T/bin/fakecmd"; "$RUN" --exec -- "$T/bin/fakecmd" >"$T/out" 2>"$T/err"; expect "--exec com o nó ligado: segue no MBP" 0 "$?"; hasnt "--exec nunca vai ao nó" "$STUB_LOG" 'HOSTCALL:hetzner'
reset; date > "$NODEFLAG"; "$RUN" --host linux --exec -- "$T/bin/fakecmd" >"$T/out" 2>"$T/err"; expect "--host linux --exec: 97" 97 "$?"
reset; "$RUN" --host foo --repo wa --dir "$T/wt" -- tests/test_x.py >"$T/out" 2>"$T/err"; expect "--host inválido: 97" 97 "$?"
reset; rc=$(nrun tests/test_x.py); expect "--host linux com a bandeira do nó desligada: 99" 99 "$rc"; hasnt "…sem chamar ninguém" "$STUB_LOG" 'HOSTCALL'
reset; date > "$NODEFLAG"; rc=$(STUB_UNREACHABLE_NODE=1 nrun tests/test_x.py); expect "--host linux com o nó fora: 98, SEM cair no MBP" 98 "$rc"; hasnt "…o MBP não é chamado" "$STUB_LOG" 'HOSTCALL:mbp'
reset; date > "$NODEFLAG"; rc=$("$RUN" --host linux --repo ps --dir "$T/wt" -- tests/test_x.py >/dev/null 2>"$T/err"; echo $?); expect "--host linux com repo ps: 98" 98 "$rc"; has "…e diz por quê (o nó só roda wa e hq)" "$T/err" 'só roda os repos wa e hq'
for hm in "--remote-pause on" "--install-tools"; do reset; date > "$NODEFLAG"; rc=$("$RUN" --host linux $hm >/dev/null 2>"$T/err"; echo $?); expect "--host linux $hm: 97 (é do MBP)" 97 "$rc"; hasnt "…nada vai ao nó nem ao MBP" "$STUB_LOG" 'HOSTCALL'; done
reset; date > "$NODEFLAG"; rc=$(STUB_NOBASE_NODE=1 run -- tests/test_x.py); expect "base ausente no nó: cai no MBP" 0 "$rc"; has "motivo sem-base no host hetzner" "$J" '"reason":"sem-base".*"host":"hetzner"'; has "manda rodar a semeadura do nó (--host linux --seed wa)" "$T/err" 'rode: mbp-run\.sh --host linux --seed wa'; hasnt "…e não manda esperar uma fatia futura" "$T/err" 'fatia 4'
reset; date > "$NODEFLAG"; rc=$(STUB_NOVENV_NODE=1 run -- tests/test_x.py); expect "venv ausente no nó: cai no MBP" 0 "$rc"; has "motivo sem-venv" "$J" '"reason":"sem-venv".*"host":"hetzner"'; has "…e também manda rodar a semeadura" "$T/err" 'rode: mbp-run\.sh --host linux --seed wa'
reset; date > "$NODEFLAG"; rc=$(STUB_RUN_RC_NODE=255 run -- tests/test_x.py); expect "ssh cai NO MEIO da execução no nó: cai no MBP e roda" 0 "$rc"; has "…a queda é logada com host=hetzner rc=255" "$J" '"rc":255.*"host":"hetzner"'; has "…e o MBP rodou" "$J" '"rc":0.*"host":"mbp"'
reset; date > "$NODEFLAG"; for i in 1 2 3 4 5 6; do mkslot $i; done; rc=$(STUB_SLOTS=exec run -- tests/test_x.py); expect "slots do nó cheios (teto 6): cai no MBP" 0 "$rc"; has "motivo slots no host hetzner" "$J" '"reason":"slots".*"host":"hetzner"'
reset; date > "$NODEFLAG"; capn=$(HETZNER_MAX_SLOTS=2 "$RUN" --host linux --check 2>/dev/null | sed -n 's/^slot_cap=//p'); eq "teto de slots do nó configurável (HETZNER_MAX_SLOTS=2)" 2 "$capn"
eq "teto de slots do nó: padrão 6 (a RAM de 24 GB não limita)" 6 "$(pfv slot_cap)"
eq "teto de slots do nó limitado pela RAM de agora (3840 MB → 2)" 2 "$(STUB_N_AVAIL_MB=3840 pfv slot_cap)"
eq "…e por um mínimo de 1" 1 "$(STUB_N_AVAIL_MB=3072 pfv slot_cap)"

# ===== preflight do nó, lido de /proc =====
reset; rc=$("$RUN" --host linux --check >"$T/out" 2>"$T/err"; echo $?); expect "--host linux --check saudável" 0 "$rc"
has "check: avail_mb vem do MemAvailable" "$T/out" '^avail_mb=24000$'; has "check: pressão PSI normal = 1" "$T/out" '^pressure=1$'; has "check: presença sempre livre" "$T/out" '^presence=livre$'
has "check: o porquê é 'dedicada'" "$T/out" '^presence_why=dedicada$'; has "check: nunca pausado" "$T/out" '^paused=0$'; has "check: sem bateria (power=ac)" "$T/out" '^power=ac$'
has "check: núcleos" "$T/out" '^ncpu=16$'; has "check: disco livre" "$T/out" '^disk_mb=280000$'; has "check: xdist presente" "$T/out" '^xdist=1$'
has "check: swap 0 é leitura válida (sem swap)" "$T/out" '^swap_mb=0$'; has "check: delta do swap 0" "$T/out" '^swap_delta_mb=0$'
has "check: a bandeira do nó" "$T/out" '^node_flag=off$'; has "check: filtro conferido" "$T/out" '^node_filter_ok=1$'; has "check: lista mac-only lida (1 = nenhum alvo)" "$T/out" '^node_mac_only_rc=1$'; has "check: sem bandeira, sem janela" "$T/out" '^node_shadow_window_open=-$'
date > "$NODEFLAG"; "$RUN" --host linux --check >"$T/out" 2>/dev/null; has "check com a bandeira: janela da sombra aberta" "$T/out" '^node_shadow_window_open=1$'; rm -f "$NODEFLAG"
eq "PSI some=9.99 full=0.99 → 1" 1 "$(STUB_N_PSI_SOME=9.99 STUB_N_PSI_FULL=0.99 pfv pressure)"
eq "PSI some=10.00 → 2 (fronteira)" 2 "$(STUB_N_PSI_SOME=10.00 pfv pressure)"
eq "PSI full=1.00 → 2 (fronteira)" 2 "$(STUB_N_PSI_FULL=1.00 pfv pressure)"
eq "PSI some=39.99 → 2" 2 "$(STUB_N_PSI_SOME=39.99 pfv pressure)"
eq "PSI some=40.00 → 4 (crítico)" 4 "$(STUB_N_PSI_SOME=40.00 pfv pressure)"
eq "PSI full=10.00 → 4" 4 "$(STUB_N_PSI_FULL=10.00 pfv pressure)"
eq "PSI ilegível (lixo) → pressure vazio, NUNCA 1" "" "$(STUB_N_PSI_RAW='garbage' pfv pressure)"
eq "PSI sem a linha 'full' → vazio" "" "$(STUB_N_PSI_RAW='some avg10=0.00 avg60=0.00 avg300=0.00 total=1' pfv pressure)"
eq "PSI avg10 com formato estranho → vazio" "" "$(STUB_N_PSI_RAW='some avg10=abc\nfull avg10=0.00' pfv pressure)"
eq "PSI ausente (kernel sem PSI) → vazio" "" "$(STUB_N_PSI_MISSING=1 pfv pressure)"
date > "$NODEFLAG"
eq "pressão 2 recusa (mesmo critério do MBP)" "98:pressao" "$(STUB_N_PSI_SOME=12 outcome_n)"; eq "pressão 4 recusa" "98:pressao" "$(STUB_N_PSI_SOME=45 outcome_n)"
eq "pressão ilegível recusa com motivo próprio" "98:ilegivel:pressure" "$(STUB_N_PSI_RAW=garbage outcome_n)"; eq "PSI ausente recusa com motivo próprio" "98:ilegivel:pressure" "$(STUB_N_PSI_MISSING=1 outcome_n)"
eq "MemAvailable ausente → vazio, recusa 'ilegivel:avail'" "98:ilegivel:avail" "$(STUB_N_MEMINFO_RAW='MemTotal:       32000000 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB' outcome_n)"
eq "MemAvailable em unidade que não é kB → ilegível" "98:ilegivel:avail" "$(STUB_N_MEMINFO_RAW='MemAvailable: 24000 MB\nSwapTotal: 0 kB\nSwapFree: 0 kB' outcome_n)"
eq "RAM baixa recusa" "98:ram" "$(STUB_N_AVAIL_MB=2000 outcome_n)"
eq "sem as linhas de swap → delta ilegível (não 0)" "98:ilegivel:swap_delta" "$(STUB_N_MEMINFO_RAW='MemAvailable: 24576000 kB' outcome_n)"
eq "SwapFree maior que SwapTotal → ilegível" "98:ilegivel:swap_delta" "$(STUB_N_MEMINFO_RAW='MemAvailable: 24576000 kB\nSwapTotal: 1000 kB\nSwapFree: 2000 kB' outcome_n)"
eq "swap CRESCENDO 500 MB entre as leituras recusa" "98:swap_cresce" "$(STUB_N_SWAPTOTAL_MB=8000 STUB_N_SWAPFREE_MB=7000 STUB_N_SWAPFREE2_MB=6500 outcome_n)"
eq "swap crescendo 128 MB (fronteira) passa" "0:-" "$(STUB_N_SWAPTOTAL_MB=8000 STUB_N_SWAPFREE_MB=7000 STUB_N_SWAPFREE2_MB=6872 outcome_n)"
eq "swap alto mas PARADO passa" "0:-" "$(STUB_N_SWAPTOTAL_MB=8000 STUB_N_SWAPFREE_MB=1000 STUB_N_SWAPFREE2_MB=1000 outcome_n)"
eq "swap usado no teto (8192 MB) recusa" "98:swap_teto" "$(STUB_N_SWAPTOTAL_MB=9000 STUB_N_SWAPFREE_MB=500 STUB_N_SWAPFREE2_MB=500 outcome_n)"
eq "disco livre baixo (1000 MB) recusa" "98:disco" "$(STUB_N_DISK_MB=1000 outcome_n)"; eq "disco no mínimo (2048) passa" "0:-" "$(STUB_N_DISK_MB=2048 outcome_n)"
eq "disco ilegível recusa com motivo próprio" "98:ilegivel:disk" "$(STUB_N_DISK_FAIL=1 outcome_n)"; eq "df com formato estranho → ilegível" "98:ilegivel:disk" "$(STUB_N_DISK_RAW='nada' outcome_n)"
eq "núcleos ilegíveis: ncpu vazio (e a bateria ainda roda)" "" "$(STUB_N_NPROC_FAIL=1 pfv ncpu)"; eq "…rodando" "0:-" "$(STUB_N_NPROC_FAIL=1 outcome_n)"
eq "xdist ausente no venv do nó: xdist=0" 0 "$(xdist_off; pfv xdist)"; eq "venv ilegível: xdist vazio (≠ 0)" "" "$(xdist_gone; pfv xdist)"; xdist_on
eq "xdist presente: xdist=1" 1 "$(pfv xdist)"
rm -f "$NODEFLAG"

# ===== segurança: o filtro =====
reset; date > "$NODEFLAG"; rc=$(run -- tests/test_x.py); has "filtro de verdade (o do repositório) vale: roda no nó" "$J" '"host":"hetzner"'
printf '%s\n' '+ /tests/***' '- .env' '- client_secret*.json' '- *.duckdb*' '- *.db' '- *.csv' '- *.parquet' '- *.gz' > "$T/unsafe-filter"
reset; date > "$NODEFLAG"; rc=$(HETZNER_RSYNC_FILTER="$T/unsafe-filter" run -- tests/test_x.py); expect "filtro com + /tests/*** ANTES das regras de dado: o nó NÃO é usado, cai no MBP" 0 "$rc"
hasnt "…nenhum rsync ao nó" "$STUB_LOG" 'RSYNC:.*hetzner-teste'; hasnt "…nenhuma chamada ao nó" "$STUB_LOG" 'HOSTCALL:hetzner'; has "…motivo no log" "$J" '"reason":"filtro-invalido".*"host":"hetzner"'; has "…mensagem diz o que o filter_sane confere" "$T/err" 'forma conferida pelo filter_sane'
reset; date > "$NODEFLAG"; rc=$(HETZNER_RSYNC_FILTER="$T/nao-existe" run -- tests/test_x.py); expect "filtro ausente: o nó NÃO é usado" 0 "$rc"; has "…motivo filtro-invalido" "$J" '"reason":"filtro-invalido"'; hasnt "…nenhuma chamada ao nó" "$STUB_LOG" 'HOSTCALL:hetzner'
: > "$T/empty-filter"; reset; date > "$NODEFLAG"; rc=$(HETZNER_RSYNC_FILTER="$T/empty-filter" run -- tests/test_x.py); has "filtro vazio: o nó NÃO é usado" "$J" '"reason":"filtro-invalido"'
grep -v -F -x -e '- *.parquet' "$HERE/hetzner-rsync-filter.wa.txt" > "$T/missing-rule-filter"; reset; date > "$NODEFLAG"; rc=$(HETZNER_RSYNC_FILTER="$T/missing-rule-filter" run -- tests/test_x.py); has "filtro SEM uma das regras de dado (parquet): o nó NÃO é usado" "$J" '"reason":"filtro-invalido"'
grep -v -F -x -e '+ /tests/***' "$HERE/hetzner-rsync-filter.wa.txt" > "$T/notests-filter"; reset; date > "$NODEFLAG"; rc=$(HETZNER_RSYNC_FILTER="$T/notests-filter" run -- tests/test_x.py); has "filtro sem a regra de tests/: o nó NÃO é usado" "$J" '"reason":"filtro-invalido"'
for mut in '- *' '- .netrc' '- .*[Tt][Oo][Kk][Ee][Nn]*' '- *[Tt][Oo][Kk][Ee][Nn]*.[jyti]*' '- *.pickle'; do   # tira UMA regra-âncora de classe, ou o `- *` final
  grep -v -F -x -e "$mut" "$HERE/hetzner-rsync-filter.wa.txt" > "$T/mut-filter"; reset; date > "$NODEFLAG"; rc=$(HETZNER_RSYNC_FILTER="$T/mut-filter" run -- tests/test_x.py); has "filtro SEM '$mut': o nó NÃO é usado" "$J" '"reason":"filtro-invalido"'; done
for pos in first last; do { [ $pos = first ] && echo '+ *.py'; cat "$HERE/hetzner-rsync-filter.wa.txt"; [ $pos = last ] && echo '+ *.py'; } > "$T/plus-filter"
  reset; date > "$NODEFLAG"; rc=$(HETZNER_RSYNC_FILTER="$T/plus-filter" run -- tests/test_x.py); has "filtro com '+ *.py' $pos (antes das regras de segredo / no lugar do '- *' final): o nó NÃO é usado" "$J" '"reason":"filtro-invalido"'; done
# os 4 últimos (ga-q9vyyn): `+` de nome-curinga SEM ponto abre a pasta para todo nome sem extensão. (Sem comentário na linha do for: o corpo vem na MESMA linha, depois do `do`.)
for ins in '+ /**' '+ **/**' '+ /*' '+ **' '!' '. /dev/null' '+ /scripts/*' '+ /scripts/**' '+ /scripts/rec*' '+ /scripts/rec?ll'; do { sed '$d' "$HERE/hetzner-rsync-filter.wa.txt"; echo "$ins"; echo '- *'; } > "$T/catch-filter"
  reset; date > "$NODEFLAG"; rc=$(HETZNER_RSYNC_FILTER="$T/catch-filter" run -- tests/test_x.py); has "filtro com '$ins' antes do '- *' final: o nó NÃO é usado" "$J" '"reason":"filtro-invalido"'; hasnt "…nenhum rsync ao nó" "$STUB_LOG" 'RSYNC:.*hetzner-teste'; done
# ga-q9vyyn, controle positivo: a regra nova NÃO recusa o que é permitido. A base é o filtro do wa, que já traz extensão em pasta (`+ /lib/**.json`) e pasta (`+ */`); soma-se caminho EXATO (`+ /scripts/recall`)
{ sed '$d' "$HERE/hetzner-rsync-filter.wa.txt"; echo '+ /scripts/recall'; echo '+ /scripts/pytest-shim/bin/pytest'; echo '- *'; } > "$T/exact-filter"
reset; date > "$NODEFLAG"; rc=$(HETZNER_RSYNC_FILTER="$T/exact-filter" run -- tests/test_x.py); has "filtro com caminho EXATO (+ /scripts/recall) antes do '- *' final: o nó É usado" "$J" '"host":"hetzner"'; hasnt "…e não é recusado pelo filter_sane" "$J" '"reason":"filtro-invalido"'
# o rsync do nó usa o filtro, com --delete-excluded, e o ssh reaproveita a conexão
reset; date > "$NODEFLAG"; run -- tests/test_x.py >/dev/null; has "rsync do nó: --filter com o arquivo do repositório" "$STUB_LOG" 'RSYNC:.*--filter=\. .*hetzner-rsync-filter\.wa\.txt'; has "rsync do nó: --delete-excluded" "$STUB_LOG" 'RSYNC:.*--delete --delete-excluded'
has "rsync do nó: destino é o espelho do slot" "$STUB_LOG" 'RSYNC:.* hetzner-teste:gt-remote/mirror/wa-1/'; hasnt "rsync do nó: NÃO usa a lista de exclusões do MBP" "$STUB_LOG" 'RSYNC:.*hetzner-teste.*--exclude'
has "ssh do nó: conexão reaproveitada (ControlPersist=600)" "$STUB_LOG" 'RSYNC:.*ControlPersist=600.*hetzner-teste'; has "ssh do nó: ControlMaster=auto" "$STUB_LOG" 'RSYNC:.*ControlMaster=auto.*hetzner-teste'
reset; run -- tests/test_x.py >/dev/null; hasnt "rsync do MBP: SEM --delete-excluded (como sempre)" "$STUB_LOG" 'RSYNC:.*--delete-excluded'; has "rsync do MBP: ControlPersist=60 (não mudou)" "$STUB_LOG" 'RSYNC:.*ControlPersist=60 '
reset; date > "$NODEFLAG"; HETZNER_SSH_PERSIST_S=90 run -- tests/test_x.py >/dev/null; has "persistência do ssh do nó configurável" "$STUB_LOG" 'RSYNC:.*ControlPersist=90.*hetzner-teste'
# espelho: cópia do Linux x clone APFS do macOS
reset; date > "$NODEFLAG"; run -- tests/test_x.py >/dev/null; has "espelho do nó: cp -a --reflink=auto" "$(lsf MIRROR hetzner)" 'cp -a --reflink=auto'; hasnt "espelho do nó: sem o clone APFS" "$(lsf MIRROR hetzner)" 'cp -cR'
has "espelho do nó: confere o venv antes" "$(lsf MIRROR hetzner)" 'gt-remote/venv-wa/bin/python'; has "espelho do nó: base wa-base" "$(lsf MIRROR hetzner)" 'gt-remote/wa-base'
reset; run -- tests/test_x.py >/dev/null; has "espelho do MBP: clone APFS (cp -cR), como sempre" "$(lsf MIRROR mbp)" 'cp -cR'; hasnt "espelho do MBP: sem --reflink" "$(lsf MIRROR mbp)" 'reflink'
reset; date > "$NODEFLAG"; run -- tests/test_x.py >/dev/null; has "job do nó: PATH com ~/.local/bin (uv)" "$(lsf RUN hetzner)" 'export PATH="\$HOME/.local/bin:\$PATH"'; has "job do nó: o python é o venv-wa" "$(lsf RUN hetzner)" 'gt-remote/venv-wa/bin/python'
has "job do nó: nice (o taskpolicy do macOS não existe lá)" "$(lsf RUN hetzner)" 'nice -n'; hasnt "job do nó: sem a biblioteca de presença do macOS (ioreg)" "$(lsf RUN hetzner)" 'ioreg'
has "job do nó: presença dedicada/livre" "$(lsf RUN hetzner)" 'PR_WHY=dedicada'
hasnt "job do nó: sem o node@22 do Homebrew (no Linux ele não existe; o node do nó vem do hetzner-nodejs.sh)" "$(lsf RUN hetzner)" 'node@22'
has "job do nó: cria logs/ no espelho (o filtro deixa logs/ no mini; teste que abre logs/x.log dava FileNotFoundError, vermelho falso)" "$(lsf RUN hetzner)" 'return 97; mkdir -p logs'
has "job do nó: NODE_PATH aponta para o jsdom do nó (ga-yoyyj1)" "$(lsf RUN hetzner)" 'NODE_PATH="\$HOME/.local/share/cdp-drive/node_modules"'
reset; run -- tests/test_x.py >/dev/null; has "job do MBP: PATH do Homebrew (como sempre)" "$(lsf RUN mbp)" '/opt/homebrew/bin'; has "job do MBP: a biblioteca de presença" "$(lsf RUN mbp)" 'ioreg'; hasnt "job do MBP: sem o NODE_PATH do nó (ga-yoyyj1)" "$(lsf RUN mbp)" 'NODE_PATH'
# ga-00unl0: o `node` padrão do Homebrew do mini (25.x) não abre (falta libsimdjson.33.dylib) e o `shutil.which("node")` dos testes o achava primeiro: 19 vermelhos falsos do ps em 3 dias; o node@22 abre
has "job do MBP: o node@22 do Homebrew vem ANTES do node padrão (o 25 não abre: libsimdjson)" "$(lsf RUN mbp)" 'export PATH=/opt/homebrew/opt/node@22/bin:/opt/homebrew/bin:'
has "job do MBP: o /opt/homebrew/bin segue no PATH (git, python, uv… como sempre)" "$(lsf RUN mbp)" 'node@22/bin:/opt/homebrew/bin:\$PATH'
has "job do MBP: cria logs/ no espelho (rsync não leva /logs; teste que abre logs/x.log dava FileNotFoundError)" "$(lsf RUN mbp)" 'return 97; mkdir -p logs'

# opção que pede valor, na última posição: o laço de argumentos avança (antes `shift 2` falhava e girava para sempre)
for opt in --host --repo --dir; do timeout 10 "$RUN" $opt >/dev/null 2>&1; rc=$?; if [ $rc -ne 124 ]; then ok "$opt como ÚLTIMO argumento termina (rc=$rc), não gira"; else bad "$opt como último argumento girou até o timeout"; fi; done
reset; date > "$NODEFLAG"; run -- tests/test_x.py >/dev/null
if awk '/echo NOVENV/ { v = NR } /echo MIRROR_OK/ { m = NR } END { exit !(v && m && v < m) }' "$(lsf MIRROR hetzner)"; then ok "espelho do nó: o venv é conferido ANTES de aceitar um espelho que já existe"; else bad "espelho do nó: o venv só é conferido quando o espelho ainda não existe"; fi

# ===== SEGURANÇA, de verdade: o rsync REAL com os argumentos do mbp-run, contra uma árvore com dado e segredo plantados =====
WTD="$T/wtd"; mkdir -p "$WTD/tests/fixtures" "$WTD/tests/data" "$WTD/lib" "$WTD/contacts_auth" "$WTD/processo_lookup" "$WTD/data" "$WTD/viewer/data" "$WTD/shared/logs" "$WTD/logs" "$WTD/.gc"
: > "$WTD/tests/test_x.py"; echo ok > "$WTD/tests/ok.json"; echo ok > "$WTD/tests/data/fixture.json"; echo ok > "$WTD/tests/fixtures/win.jsonl"; echo code > "$WTD/lib/a.py"; echo code > "$WTD/contacts_auth/server.py"
echo code > "$WTD/processo_lookup/pdpj_token.py"; echo code > "$WTD/tests/test_pdpj_token_refresh.py"; echo ok > "$WTD/lib/rules.yaml"   # código/config de nome parecido com credencial: TEM que chegar
for lk in $LEAKS; do mkdir -p "$WTD/$(dirname "$lk")"; echo secret > "$WTD/$lk"; done
for lk in $NEUTRAL; do mkdir -p "$WTD/$(dirname "$lk")"; echo '[{"phone": "+5531987654321", "cpf": "123.456.789-09"}]' > "$WTD/$lk"; done
for lk in $OKCFG; do mkdir -p "$WTD/$(dirname "$lk")"; echo ok > "$WTD/$lk"; done
phones() { awk -v n="$1" 'BEGIN { for (i = 1; i <= n; i++) printf "\"+55319%08d\",\n", (i * 7654321) % 100000000 }'; }
phones 25 > "$WTD/lib/leads_list.py"; phones 25 > "$WTD/lib/changelog.d/dump.json"; phones 3 > "$WTD/lib/few.py"
awk 'BEGIN { for (i = 1; i <= 4; i++) printf "\"%03d.456.789-%02d\",\n", i, i }' > "$WTD/tests/fixtures/cpfs.json"
awk 'BEGIN { for (i = 0; i < 32; i++) printf "\"+55319999%d%d%d%d%d\",\n", int(i/16)%2, int(i/8)%2, int(i/4)%2, int(i/2)%2, i%2 }' > "$WTD/lib/synthetic.py"
DEST="$T/home/gt-remote/mirror/wa-1"
leakcheck() { # imprime os arquivos plantados que chegaram ao destino (vazio = nada vazou)
  local lk got=""; for lk in $LEAKS $NEUTRAL $HELDF; do [ -e "$DEST/$lk" ] && got="$got $lk"; done; printf '%s' "${got# }"; }
reset; date > "$NODEFLAG"; find "$DEST" -mindepth 1 -delete 2>/dev/null; mkdir -p "$DEST/processo_lookup" "$DEST/shared/logs.backup"; echo old > "$DEST/processo_lookup/.env.pdpj"; echo old > "$DEST/shared/logs.backup/x.out"
STUB_RSYNC_REAL=1 "$RUN" --repo wa --dir "$WTD" -- tests/test_x.py >"$T/out" 2>"$T/err"; rc=$?; expect "rsync real: a bateria roda no nó" 0 "$rc"; has "…no nó" "$J" '"host":"hetzner"'
eq "NADA de dado ou segredo plantado chegou ao nó, nem arquivo de nome neutro, nem lista de telefones/CPFs (a lista abaixo tem de ser vazia)" "" "$(leakcheck)"
has "o node_guard avisa quantos reteve" "$T/err" 'NOTE: 3 arquivo\(s\) com lista de telefones/CPFs ficam no mini e NÃO vão ao nó Linux'; hasnt "…e o aviso nunca traz o VALOR" "$T/err" '5531[0-9]{8}'
for okf in lib/a.py tests/test_x.py tests/ok.json tests/data/fixture.json tests/fixtures/win.jsonl contacts_auth/server.py processo_lookup/pdpj_token.py tests/test_pdpj_token_refresh.py lib/rules.yaml $OKCFG $PASSF; do n=$((n+1)); if [ -f "$DEST/$okf" ]; then echo "ok   chegou (é código/config listado/abaixo do limite): $okf"; else echo "FAIL não chegou: $okf"; fails=$((fails+1)); fi; done
n=$((n+1)); if [ ! -e "$DEST/processo_lookup/.env.pdpj" ] && [ ! -e "$DEST/shared/logs.backup/x.out" ]; then echo "ok   --delete-excluded limpa o que uma semeadura antiga deixou (.env.pdpj e shared/logs.backup/x.out)"; else echo "FAIL o destino manteve segredo/log antigo"; fails=$((fails+1)); fi
MUT="$T/mutdir"; mkdir -p "$MUT"; for mf in mbp-presence.sh mbp-controle.sh hetzner-rsync-filter.wa.txt hetzner-pii-scan.py hetzner-mac-only.txt hetzner-rsync-filter.hq.txt hetzner-mac-only.hq.txt; do ln -sf "$HERE/$mf" "$MUT/$mf"; done   # o pii-scan TEM de estar aqui: sem ele o node_guard do mutante falha fechado e nada vaza, e o controle diria que o teste não enxerga o defeito; a lista mac-only idem (ilegível = o nó não é usado)
# HETZNER_ISOLATE=1 (ga-9p6pte, a bateria noturna): o pytest do nó só roda dentro do wrapper de isolamento; fora do nó ou sem o wrapper → 97 e NADA roda.
# iso_obs R: roda o mbp-run R (o real ou um mutante) nos 4 cenários e deixa as observações em ISO_OBS (uma palavra por observação que se confirmou).
iso_obs() { local R=$1 rc s; ISO_OBS=""
  reset; date > "$NODEFLAG"; "$R" --host linux --repo wa --dir "$T/wt" -- tests/test_x.py >/dev/null 2>&1; s=$(lastscript RUN hetzner)
  case "$s" in *gt-iso-run*) ;; *) ISO_OBS="$ISO_OBS sem-iso:limpo";; esac                                   # sem HETZNER_ISOLATE o script não cita o wrapper
  reset; date > "$NODEFLAG"; HETZNER_ISOLATE=1 "$R" --host linux --repo wa --dir "$T/wt" -- tests/test_x.py >/dev/null 2>&1; s=$(lastscript RUN hetzner)
  case "$s" in *'nice -n "$MBP_NICE" "$HOME/gt-remote/bin/gt-iso-run" -- "$HOME/gt-remote/venv-wa/bin/python" -m pytest'*) ISO_OBS="$ISO_OBS com-iso:embrulha";; esac
  case "$s" in *'[ -x "$HOME/gt-remote/bin/gt-iso-run" ] || { echo "GTN-ISO: inerte wrapper-ausente'*'exit 97; }'*) ISO_OBS="$ISO_OBS com-iso:guard";; esac
  reset; date > "$NODEFLAG"; HETZNER_ISOLATE=1 "$R" --host mbp --repo wa --dir "$T/wt" -- tests/test_x.py >/dev/null 2>"$T/err"; rc=$?
  [ "$rc" = 97 ] && [ ! -e "$(lsf RUN mbp)" ] && grep -q 'só vale no nó Linux' "$T/err" && ISO_OBS="$ISO_OBS fora-do-no:97-sem-rodar"
  reset; date > "$NODEFLAG"; HETZNER_ISOLATE=1 STUB_RUNMODE=exec "$R" --host linux --repo wa --dir "$T/wt" -- tests/test_x.py >"$T/out" 2>&1; rc=$?   # o HOME falso não tem ~/gt-remote/bin/gt-iso-run
  [ "$rc" = 97 ] && grep -q 'GTN-ISO: inerte wrapper-ausente' "$T/out" && ISO_OBS="$ISO_OBS sem-wrapper:97"; }
iso_obs "$RUN"
for o in sem-iso:limpo com-iso:embrulha com-iso:guard fora-do-no:97-sem-rodar sem-wrapper:97; do
  case " $ISO_OBS " in *" $o "*) ok "HETZNER_ISOLATE ($o)";; *) bad "HETZNER_ISOLATE ($o) — observado:$ISO_OBS";; esac; done
# controles negativos: cada defeito do gancho tem de sumir da observação que o guarda (senão o caso não enxerga o defeito)
iso_mut() { local nome=$1 expr=$2 perde=$3 f="$MUT/iso-mut-$1.sh"; sed "$expr" "$RUN" > "$f"; chmod +x "$f"
  if cmp -s "$RUN" "$f"; then bad "controle $nome: o sed não mudou nada"; return; fi
  iso_obs "$f"; case " $ISO_OBS " in *" $perde "*) bad "controle $nome: '$perde' continua observado — o caso não enxerga o defeito";; *) ok "controle $nome: o defeito faz '$perde' sumir";; esac; }
iso_mut sem-embrulho  's/ \${ISO}"\\$HOME\/gt-remote\/\$rv/ "\\$HOME\/gt-remote\/$rv/' com-iso:embrulha
iso_mut sem-guard     's/^  \[ -z "\$ISO" \] || pathline=.*$/  :/' com-iso:guard
iso_mut iso-no-mbp    's/^    \[ "\$HOSTKIND" = linux \] || { say "HETZNER_ISOLATE=1.*$/    :/' fora-do-no:97-sem-rodar
iso_mut iso-sempre    's/^  if \[ "\${HETZNER_ISOLATE:-0}" = 1 \]; then$/  if true; then/' sem-iso:limpo
# controle negativo 1: sem o --filter, o vazamento aparece — prova que o teste enxerga o defeito
sed 's/--filter=". \$NODE_FILTER" //' "$RUN" > "$MUT/mut-nofilter.sh"; chmod +x "$MUT/mut-nofilter.sh"
n=$((n+1)); if cmp -s "$RUN" "$MUT/mut-nofilter.sh"; then echo "FAIL controle: o sed não mudou nada"; fails=$((fails+1)); else
  reset; date > "$NODEFLAG"; find "$DEST" -mindepth 1 -delete 2>/dev/null; STUB_RSYNC_REAL=1 "$MUT/mut-nofilter.sh" --repo wa --dir "$WTD" -- tests/test_x.py >/dev/null 2>&1
  lk=$(leakcheck); n=$((n+1)); if [ -n "$lk" ]; then echo "ok   controle: o mutante sem o filtro VAZA ($(printf '%s' "$lk" | wc -w | tr -d ' ') arquivos plantados chegaram)"; else echo "FAIL controle: o mutante sem filtro não vazou — o teste não enxerga o defeito"; fails=$((fails+1)); fi; fi
# controle negativo 2: filtro com a ordem errada + a conferência de ordem removida → um *.duckdb DENTRO de tests/ chega
sed 's/^  filter_sane || { NODE_WHY="filtro-invalido".*$/  true/' "$RUN" > "$MUT/mut-nosane.sh"; chmod +x "$MUT/mut-nosane.sh"
n=$((n+1)); if cmp -s "$RUN" "$MUT/mut-nosane.sh"; then echo "FAIL controle: o sed da conferência não mudou nada"; fails=$((fails+1)); else
  reset; date > "$NODEFLAG"; find "$DEST" -mindepth 1 -delete 2>/dev/null; HETZNER_RSYNC_FILTER="$T/unsafe-filter" STUB_RSYNC_REAL=1 "$MUT/mut-nosane.sh" --repo wa --dir "$WTD" -- tests/test_x.py >/dev/null 2>&1
  n=$((n+1)); if [ -e "$DEST/tests/fixtures/y.duckdb" ]; then echo "ok   controle: sem a conferência de ordem, o filtro do rascunho deixa passar tests/fixtures/y.duckdb"; else echo "FAIL controle: o filtro inseguro não vazou nada — o teste não enxerga o defeito"; fails=$((fails+1)); fi; fi
reset; date > "$NODEFLAG"; find "$DEST" -mindepth 1 -delete 2>/dev/null; HETZNER_RSYNC_FILTER="$T/unsafe-filter" STUB_RSYNC_REAL=1 "$RUN" --repo wa --dir "$WTD" -- tests/test_x.py >/dev/null 2>&1
n=$((n+1)); if [ ! -e "$DEST/tests/fixtures/y.duckdb" ]; then echo "ok   o script real, com o filtro inseguro, não envia nada (a conferência de ordem barra)"; else echo "FAIL o script real enviou dado com o filtro inseguro"; fails=$((fails+1)); fi
# controle negativo 3: o filtro só-denylist (a forma que o gate reprovou em 14/10) sem a conferência deixa sair credencial de nome desconhecido; com a conferência, nada sai
printf '%s\n' '- .env' '- client_secret*.json' '- *.duckdb*' '- *.db' '- *.csv' '- *.parquet' '- *.gz' '- *.pem' '- *.pkl' '+ /tests/***' '- data/' '- /shared/' '- .gc' > "$T/denylist-filter"
reset; date > "$NODEFLAG"; find "$DEST" -mindepth 1 -delete 2>/dev/null; HETZNER_RSYNC_FILTER="$T/denylist-filter" STUB_RSYNC_REAL=1 "$MUT/mut-nosane.sh" --repo wa --dir "$WTD" -- tests/test_x.py >/dev/null 2>&1
n=$((n+1)); if [ -e "$DEST/processo_lookup/.pdpj_token.txt" ] && [ -e "$DEST/.netrc" ] && [ -e "$DEST/lib/dump.zip" ]; then echo "ok   controle: o filtro só-denylist, sem a conferência, deixa sair .pdpj_token.txt, .netrc e dump.zip (o teste enxerga a classe)"; else echo "FAIL controle: o filtro só-denylist não vazou — o teste não enxerga a classe"; fails=$((fails+1)); fi
reset; date > "$NODEFLAG"; find "$DEST" -mindepth 1 -delete 2>/dev/null; HETZNER_RSYNC_FILTER="$T/denylist-filter" STUB_RSYNC_REAL=1 "$RUN" --repo wa --dir "$WTD" -- tests/test_x.py >/dev/null 2>&1
n=$((n+1)); if [ ! -e "$DEST/processo_lookup/.pdpj_token.txt" ] && [ ! -e "$DEST/.netrc" ]; then echo "ok   o script real, com o filtro só-denylist, não envia nada (o filter_sane recusa: falta o '- *' final e as âncoras)"; else echo "FAIL o script real enviou credencial com o filtro só-denylist"; fails=$((fails+1)); fi
# controle negativo 4: a lista por EXTENSÃO (a 1ª correção, que o gate reprovou) deixa sair arquivo de nome neutro com dado dentro; a seção 3b atual, não
{ sed '/^# 3b/,$d' "$HERE/hetzner-rsync-filter.wa.txt"; printf '%s\n' '+ *.json' '+ *.md' '+ *.html' '+ *.yaml' '+ *.yml' '+ *.sql' '+ *.plist' '+ *.ini' '- *'; } > "$T/ext-filter"
reset; date > "$NODEFLAG"; find "$DEST" -mindepth 1 -delete 2>/dev/null; HETZNER_RSYNC_FILTER="$T/ext-filter" STUB_RSYNC_REAL=1 "$RUN" --repo wa --dir "$WTD" -- tests/test_x.py >/dev/null 2>&1
n=$((n+1)); if [ -e "$DEST/docs/auto_response/ab_results/cycle1_new_rules_200.json" ] && [ -e "$DEST/scripts/campanhas_aprovar_enriquecer_estado.json" ] && [ -e "$DEST/state.json" ]; then echo "ok   controle: a lista por extensão deixa sair ab_results/*.json, *_estado.json e state.json (o teste enxerga a classe)"; else echo "FAIL controle: a lista por extensão não vazou — o teste não enxerga a classe"; fails=$((fails+1)); fi
# controle negativo 5: sem o node_guard, a LISTA de telefones/CPFs em nome e pasta liberados chega
sed 's/^  if \[ "\$HOSTKIND" = linux \]; then node_guard .*$/  HELD=\/dev\/null/' "$RUN" > "$MUT/mut-noguard.sh"; chmod +x "$MUT/mut-noguard.sh"
n=$((n+1)); if cmp -s "$RUN" "$MUT/mut-noguard.sh"; then echo "FAIL controle: o sed do node_guard não mudou nada"; fails=$((fails+1)); else
  reset; date > "$NODEFLAG"; find "$DEST" -mindepth 1 -delete 2>/dev/null; STUB_RSYNC_REAL=1 "$MUT/mut-noguard.sh" --repo wa --dir "$WTD" -- tests/test_x.py >/dev/null 2>&1
  n=$((n+1)); if [ -e "$DEST/lib/leads_list.py" ] && [ -e "$DEST/lib/changelog.d/dump.json" ] && [ -e "$DEST/tests/fixtures/cpfs.json" ]; then echo "ok   controle: sem o node_guard a lista de telefones/CPFs chega (o teste enxerga o conteúdo)"; else echo "FAIL controle: sem o node_guard nada vazou — o teste não enxerga o conteúdo"; fails=$((fails+1)); fi; fi
# controle 6: a varredura que não roda (hetzner-pii-scan.py ausente) NÃO é "nada retido": o nó não é usado, cai no MBP
NOSCAN="$T/noscandir"; mkdir -p "$NOSCAN"; for mf in mbp-presence.sh mbp-controle.sh hetzner-rsync-filter.wa.txt; do ln -sf "$HERE/$mf" "$NOSCAN/$mf"; done   # SEM o hetzner-pii-scan.py, de propósito (o $MUT o tem)
cp "$RUN" "$NOSCAN/mut-noscan.sh"; chmod +x "$NOSCAN/mut-noscan.sh"
n=$((n+1)); if [ ! -e "$NOSCAN/hetzner-pii-scan.py" ] && [ -e "$MUT/hetzner-pii-scan.py" ]; then echo "ok   premissa dos controles: o scanner está no diretório dos mutantes e NÃO no diretório do controle 6"; else echo "FAIL premissa dos controles: o scanner tem de estar em \$MUT e ausente em \$NOSCAN"; fails=$((fails+1)); fi
reset; date > "$NODEFLAG"; find "$DEST" -mindepth 1 -delete 2>/dev/null; STUB_RSYNC_REAL=1 "$NOSCAN/mut-noscan.sh" --repo wa --dir "$WTD" -- tests/test_x.py >"$T/out" 2>"$T/err"; rc=$?
expect "varredura de conteúdo que não roda: o nó NÃO é usado e a cadeia cai no MBP" 0 "$rc"; has "…motivo varredura-falhou no host hetzner" "$J" '"reason":"varredura-falhou".*"host":"hetzner"'; hasnt "…nenhum rsync ao nó" "$STUB_LOG" 'RSYNC:.*hetzner-teste'; has "…e a mensagem diz o que faltou" "$T/err" 'não consegui varrer o conteúdo'
n=$((n+1)); if [ ! -e "$DEST/lib/a.py" ]; then echo "ok   …e nada foi enviado ao nó"; else echo "FAIL a varredura falhou mas o nó recebeu arquivos"; fails=$((fails+1)); fi
# controle 7 (revisão de segurança do commit, 14/10): (a) caminho retido que a REGRA não segura — barra invertida no nome: `- /lib/bs\\x.py` não casa no rsync e o arquivo sairia sem varredura; (b) arquivo que o rsync não
# consegue ler (chmod 000): o próprio `rsync -n` da lista sai com rc 23 e o nó não é usado; (c) quebra de linha DENTRO do nome: a lista sai (rc 0) mas parte o nome em dois pedaços que o scanner não abre — rc 3 do scanner.
# Nos três o nó NÃO é usado (varredura-falhou) e nada chega; sem a conferência do 2º rsync -n o (a) VAZA (mutante).
WTB="$T/wtb"; mkdir -p "$WTB/tests" "$WTB/lib"; : > "$WTB/tests/test_x.py"; echo code > "$WTB/lib/a.py"; phones 25 > "$WTB/lib/bs\\x.py"
reset; date > "$NODEFLAG"; find "$DEST" -mindepth 1 -delete 2>/dev/null; STUB_RSYNC_REAL=1 "$RUN" --repo wa --dir "$WTB" -- tests/test_x.py >"$T/out" 2>"$T/err"; rc=$?
expect "caminho retido com barra invertida (a regra não o segura): o nó NÃO é usado e a cadeia cai no MBP" 0 "$rc"; has "…motivo varredura-falhou no host hetzner" "$J" '"reason":"varredura-falhou".*"host":"hetzner"'
n=$((n+1)); if [ ! -e "$DEST/lib/a.py" ] && [ ! -e "$DEST/lib/bs\\x.py" ]; then echo "ok   …e nada foi enviado ao nó (nem o arquivo retido)"; else echo "FAIL o nó recebeu arquivos apesar de a regra de retenção não segurar um caminho"; fails=$((fails+1)); fi
sed 's/^    grep -qxF -f "\$SENT.hp" "\$SENT.v"; \[ \$? -eq 1 \] || return 1$/    true/' "$RUN" > "$MUT/mut-noverify.sh"; chmod +x "$MUT/mut-noverify.sh"
n=$((n+1)); if cmp -s "$RUN" "$MUT/mut-noverify.sh"; then echo "FAIL controle: o sed da conferência da regra não mudou nada"; fails=$((fails+1)); else
  reset; date > "$NODEFLAG"; find "$DEST" -mindepth 1 -delete 2>/dev/null; STUB_RSYNC_REAL=1 "$MUT/mut-noverify.sh" --repo wa --dir "$WTB" -- tests/test_x.py >/dev/null 2>&1
  n=$((n+1)); if [ -e "$DEST/lib/bs\\x.py" ]; then echo "ok   controle: sem a conferência do 2º rsync -n, o arquivo com barra invertida (retido, 25 telefones) CHEGA ao nó (o teste enxerga o defeito)"; else echo "FAIL controle: sem a conferência o arquivo com barra invertida não chegou — o teste não enxerga o defeito"; fails=$((fails+1)); fi; fi
WTU="$T/wtu"; mkdir -p "$WTU/tests" "$WTU/lib"; : > "$WTU/tests/test_x.py"; echo code > "$WTU/lib/a.py"; echo code > "$WTU/lib/locked.py"; chmod 000 "$WTU/lib/locked.py"
reset; date > "$NODEFLAG"; find "$DEST" -mindepth 1 -delete 2>/dev/null; STUB_RSYNC_REAL=1 "$RUN" --repo wa --dir "$WTU" -- tests/test_x.py >"$T/out" 2>"$T/err"; rc=$?; chmod 600 "$WTU/lib/locked.py"
expect "arquivo que o rsync não consegue ler: o nó NÃO é usado e a cadeia cai no MBP" 0 "$rc"; has "…motivo varredura-falhou no host hetzner" "$J" '"reason":"varredura-falhou".*"host":"hetzner"'
n=$((n+1)); if [ ! -e "$DEST/lib/a.py" ]; then echo "ok   …e nada foi enviado ao nó (lista que falha não é 'nada retido')"; else echo "FAIL o rsync não leu um arquivo mas o nó recebeu arquivos"; fails=$((fails+1)); fi
# o scanner sozinho: um caminho da lista que não abre = rc 3 (varredura incompleta, e a linha -1 -1 + a regra continuam saindo); tudo lido = rc 0
printf 'lib/a.py\nlib/nao-existe.py\n' | python3 -I "$HERE/hetzner-pii-scan.py" "$WTB" --rules "$T/scan.rules" > "$T/scan.out"; expect "scanner: caminho da lista que não abre → rc 3 (varredura incompleta)" 3 "$?"
eq "scanner: o ilegível sai como linha -1 -1 com o caminho (retido, sem valor)" "$(printf -- '-1\t-1\tlib/nao-existe.py')" "$(cat "$T/scan.out")"
eq "scanner: …e a regra de retenção sai" "- /lib/nao-existe.py" "$(cat "$T/scan.rules")"
printf 'lib/a.py\n' | python3 -I "$HERE/hetzner-pii-scan.py" "$WTB" > /dev/null; expect "scanner: tudo lido → rc 0" 0 "$?"
WTN="$T/wtn"; mkdir -p "$WTN/tests" "$WTN/lib"; : > "$WTN/tests/test_x.py"; echo code > "$WTN/lib/a.py"; phones 25 > "$WTN/lib/nl"$'\n'"x.py"
reset; date > "$NODEFLAG"; find "$DEST" -mindepth 1 -delete 2>/dev/null; STUB_RSYNC_REAL=1 "$RUN" --repo wa --dir "$WTN" -- tests/test_x.py >"$T/out" 2>"$T/err"; rc=$?
expect "quebra de linha no nome do arquivo: o scanner não o abre (rc 3) e o nó NÃO é usado, cai no MBP" 0 "$rc"; has "…motivo varredura-falhou no host hetzner" "$J" '"reason":"varredura-falhou".*"host":"hetzner"'
n=$((n+1)); if [ ! -e "$DEST/lib/a.py" ] && [ -z "$(find "$DEST/lib" -name 'nl*' 2>/dev/null)" ]; then echo "ok   …e nada foi enviado ao nó (nem o arquivo de nome partido)"; else echo "FAIL o nó recebeu arquivos apesar de um nome que a lista parte em dois"; fails=$((fails+1)); fi
find "$DEST" -mindepth 1 -delete 2>/dev/null

# ===== lista mac-only =====
reset; date > "$NODEFLAG"; printf '%s\n' 'tests/test_x.py' > "$MACONLY"; rc=$(run -- tests/test_x.py); expect "alvo na lista mac-only: roda no MBP" 0 "$rc"
hasnt "…o nó não é chamado" "$STUB_LOG" 'HOSTCALL:hetzner'; has "…o motivo vai ao log" "$J" '"reason":"mac-only".*"host":"hetzner"'; has "…a mensagem diz qual arquivo" "$T/err" 'tests/test_x.py está na lista mac-only'; has "…e roda no MBP" "$J" '"mode":"pytest".*"host":"mbp"'
reset; date > "$NODEFLAG"; printf '# comentário\n\n  tests/test_x.py  \r\n' > "$MACONLY"; run -- tests/test_x.py >/dev/null; has "lista com comentário, linha vazia, espaços e CRLF ainda casa" "$J" '"reason":"mac-only"'
reset; date > "$NODEFLAG"; printf 'tests/mac/*\n' > "$MACONLY"; run -- tests/mac/test_a.py -q >/dev/null; has "glob (tests/mac/*) casa" "$J" '"reason":"mac-only"'
reset; date > "$NODEFLAG"; printf 'tests/test_x.py\n' > "$MACONLY"; run -- tests/test_x.py::test_a -q >/dev/null; has "node id (arquivo::teste) casa pelo arquivo" "$J" '"reason":"mac-only"'
reset; date > "$NODEFLAG"; printf 'tests/test_x.py\n' > "$MACONLY"; run -- "$T/wt/tests/test_x.py" >/dev/null; has "caminho absoluto dentro do worktree casa" "$J" '"reason":"mac-only"'
reset; date > "$NODEFLAG"; printf 'tests/test_b.py\n' > "$MACONLY"; run -- tests/test_a.py tests/test_b.py tests/test_c.py >/dev/null; has "UM alvo mac-only manda a bateria INTEIRA ao MBP" "$J" '"reason":"mac-only"'; hasnt "…nada vai ao nó" "$STUB_LOG" 'HOSTCALL:hetzner'
reset; date > "$NODEFLAG"; printf 'tests/test_other.py\n' > "$MACONLY"; run -- tests/test_x.py >/dev/null; has "alvo fora da lista: vai ao nó" "$J" '"host":"hetzner"'; hasnt "…sem recusa" "$J" 'mac-only'
reset; date > "$NODEFLAG"; : > "$MACONLY"; printf 'tests/test_x.py\n' > "$LEARNED"; rc=$(run -- tests/test_x.py); expect "lista APRENDIDA pela sombra também vale" 0 "$rc"; has "…vai ao MBP" "$J" '"reason":"mac-only"'
reset; date > "$NODEFLAG"; : > "$MACONLY"; printf 'tests/test_x.py\n' > "$LEARNED"; chmod 000 "$LEARNED"; run -- tests/test_x.py >/dev/null; has "lista aprendida existe mas não abre: o nó NÃO é usado" "$J" '"reason":"mac-only-ilegivel"'; hasnt "…nenhuma chamada ao nó" "$STUB_LOG" 'HOSTCALL:hetzner'; chmod 644 "$LEARNED"
reset; date > "$NODEFLAG"; chmod 000 "$MACONLY"; run -- tests/test_x.py >/dev/null; has "lista estática ilegível (sem permissão): o nó NÃO é usado" "$J" '"reason":"mac-only-ilegivel"'; hasnt "…nenhuma chamada ao nó" "$STUB_LOG" 'HOSTCALL:hetzner'; chmod 644 "$MACONLY"
reset; date > "$NODEFLAG"; rc=$(HETZNER_MAC_ONLY_LIST="$T/nao-existe.txt" run -- tests/test_x.py); expect "lista estática AUSENTE: o nó NÃO é usado, cai no MBP" 0 "$rc"; has "…motivo" "$J" '"reason":"mac-only-ilegivel"'
reset; date > "$NODEFLAG"; : > "$MACONLY"; rc=$(run -- tests/test_x.py); has "lista vazia é válida (nenhum glob casa): vai ao nó" "$J" '"host":"hetzner"'
# ga-00unl0: a lista REAL (não a de teste): o ratchet de timeout lê os plists do launchd do mini; no nó dava vermelho falso a cada gate com um plist novo
reset; date > "$NODEFLAG"; HETZNER_MAC_ONLY_LIST="$HERE/hetzner-mac-only.txt" run -- tests/test_launchd_timeout_ratchet.py >/dev/null; has "lista REAL: test_launchd_timeout_ratchet.py é mac-only (vai ao MBP, não ao nó)" "$J" '"reason":"mac-only"'; hasnt "…nada vai ao nó" "$STUB_LOG" 'HOSTCALL:hetzner'
reset; date > "$NODEFLAG"; HETZNER_MAC_ONLY_LIST="$HERE/hetzner-mac-only.txt" run -- tests/test_x.py >/dev/null; has "lista REAL: um teste comum segue indo ao nó (a entrada nova não é um coringa)" "$J" '"host":"hetzner"'
reset; : > "$MACONLY"; mc=$("$RUN" --host linux --check 2>/dev/null | sed -n 's/^node_mac_only_rc=//p'); eq "--check: lista vazia = rc 1 (nenhum alvo)" 1 "$mc"; chmod 000 "$MACONLY"; mc=$("$RUN" --host linux --check 2>/dev/null | sed -n 's/^node_mac_only_rc=//p'); eq "--check: lista ilegível = rc 2" 2 "$mc"; chmod 644 "$MACONLY"

# ===== paralelismo (xdist) =====
printf 'def test_%d(): pass\n' $(seq 1 50) > "$T/wt/tests/test_big.py"
reset; date > "$NODEFLAG"; run -- tests/test_big.py -q >/dev/null; has "bateria grande (50 testes): injeta -n 16 (16 núcleos, 1 bateria)" "$(lsf RUN hetzner)" 'pytest -p no:cacheprovider -n 16 tests/test_big\.py -q'; has "…e avisa" "$T/err" 'xdist: 16 workers'
reset; date > "$NODEFLAG"; run -- tests/test_x.py -q >/dev/null; hasnt "bateria pequena (arquivo vazio): sem -n" "$(lsf RUN hetzner)" 'cacheprovider -n '
reset; date > "$NODEFLAG"; run -- tests/test_big.py -n 3 >/dev/null; hasnt "o -n do chamador vence: nenhum -n injetado na frente" "$(lsf RUN hetzner)" 'cacheprovider -n '; has "…e fica o dele" "$(lsf RUN hetzner)" 'cacheprovider tests/test_big\.py -n 3'
for fl in "-p no:xdist" "--pdb" "--collect-only" "--co" "--dist=loadfile" "-d" "--lf"; do reset; date > "$NODEFLAG"; run -- tests/test_big.py $fl >/dev/null; hasnt "chamador com '$fl': xdist não é injetado" "$(lsf RUN hetzner)" ' -n 16'; done
reset; date > "$NODEFLAG"; xdist_off; run -- tests/test_big.py >/dev/null; hasnt "xdist ausente no nó: sem -n" "$(lsf RUN hetzner)" ' -n 16'; xdist_gone; reset; date > "$NODEFLAG"; run -- tests/test_big.py >/dev/null; hasnt "venv ilegível (xdist vazio): sem -n (o inerte)" "$(lsf RUN hetzner)" ' -n 16'; xdist_on
reset; date > "$NODEFLAG"; HETZNER_XDIST_OFF=1 run -- tests/test_big.py >/dev/null; hasnt "HETZNER_XDIST_OFF=1: sem -n" "$(lsf RUN hetzner)" ' -n 16'
reset; date > "$NODEFLAG"; HETZNER_XDIST_MIN_TESTS=100 run -- tests/test_big.py >/dev/null; hasnt "limiar HETZNER_XDIST_MIN_TESTS=100: 50 testes não bastam" "$(lsf RUN hetzner)" ' -n 16'
reset; date > "$NODEFLAG"; HETZNER_XDIST_MIN_TESTS=1 run -- tests/test_x.py::test_a >/dev/null; has "node id explícito conta como 1 teste (limiar 1 → injeta)" "$(lsf RUN hetzner)" ' -n 16 '
reset; date > "$NODEFLAG"; run -- tests >/dev/null; has "diretório como alvo: conta os testes dos arquivos (50) → injeta" "$(lsf RUN hetzner)" ' -n 16 '
reset; date > "$NODEFLAG"; STUB_N_NPROC_FAIL=1 run -- tests/test_big.py >/dev/null; hasnt "núcleos ilegíveis: sem -n (não inventa um número)" "$(lsf RUN hetzner)" 'cacheprovider -n '
reset; date > "$NODEFLAG"; STUB_N_NPROC=8 run -- tests/test_big.py >/dev/null; has "8 núcleos: -n 8" "$(lsf RUN hetzner)" ' -n 8 '
reset; date > "$NODEFLAG"; for i in 1 2 3; do mkslot $i; done; STUB_SLOTS=exec run -- tests/test_big.py >/dev/null; has "com 3 baterias já em curso (a minha é a 4ª): núcleos / 4 = -n 4" "$(lsf RUN hetzner)" ' -n 4 '
reset; date > "$NODEFLAG"; for i in 1 2 3 4 5; do mkslot $i; done; STUB_SLOTS=exec run -- tests/test_big.py >/dev/null; has "6ª bateria: 16 / 6 = 2 workers (nunca menos que 2)" "$(lsf RUN hetzner)" ' -n 2 '
reset; date > "$NODEFLAG"; run -- tests/test_big.py >/dev/null; has "o log registra os argumentos ORIGINAIS (nargs=1: só o arquivo, sem o -n injetado)" "$J" '"nargs":1'
reset; run -- tests/test_big.py >/dev/null; hasnt "MBP: nunca injeta -n" "$(lsf RUN mbp)" ' -n 16'

# ===== a sombra =====
shadow_env() { reset; date > "$NODEFLAG"; export HETZNER_SHADOW_PCT=100 STUB_RUN_OUT_NODE='NODE-OUT' STUB_RUN_OUT_MBP='MBP-ONLY-MARKER'; }
shadow_end() { export HETZNER_SHADOW_PCT=0; unset STUB_RUN_OUT_NODE STUB_RUN_OUT_MBP; }
shadow_env; rc=$(run -- tests/test_x.py); expect "sombra 100%, resultados iguais: quem chamou recebe o do nó" 0 "$rc"
has "sombra: o MBP também rodou (em paralelo)" "$STUB_LOG" 'HOSTCALL:mbp:RUN'; has "sombra: veredito 'same' no log da sombra" "$SHLOG" '"verdict":"same","a_host":"hetzner","a_rc":0,"b_host":"mbp","b_rc":0'
has "sombra: o lado de MBP é marcado shadow:1 no log de execuções" "$J" '"host":"mbp".*"shadow":1'; grep '"host":"hetzner"' "$J" > "$T/hz.log"; hasnt "sombra: a linha do nó NÃO é marcada" "$T/hz.log" 'shadow'
hasnt "sombra: a saída do MBP NÃO chega a quem chamou" "$T/out" 'MBP-ONLY-MARKER'; has "sombra: a saída do nó chega" "$T/out" 'NODE-OUT'; [ ! -e "$LEARNED" ] && ok "sombra igual: nada é aprendido" || bad "sombra igual aprendeu algo"
[ "$(grep -c 'HOSTCALL:mbp:RUN' "$STUB_LOG")" = 1 ] && ok "a sombra roda UMA vez no MBP (o filho não faz outra sombra)" || bad "a sombra rodou mais de uma vez no MBP"
n=$((n+1)); if ls "$T/city/.gc/run/" 2>/dev/null | grep -q 'mbp-shadow'; then echo "FAIL sobrou arquivo temporário da sombra"; fails=$((fails+1)); else echo "ok   a sombra apaga o próprio arquivo temporário"; fi
shadow_env; rc=$(STUB_RUN_RC_NODE=0 STUB_RUN_RC_MBP=1 run -- tests/test_x.py); expect "sombra diverge (nó 0, MBP 1): o chamador recebe o rc do NÓ" 0 "$rc"
has "divergência: veredito no log" "$SHLOG" '"verdict":"diverge","a_host":"hetzner","a_rc":0,"b_host":"mbp","b_rc":1,"files":"tests/test_x.py"'; has "divergência: o arquivo entra na lista aprendida" "$LEARNED" '^tests/test_x\.py$'; has "divergência: avisa" "$T/err" 'sombra: DIVERGÊNCIA \(nó rc=0, MBP rc=1\)'
shadow_end; : > "$STUB_LOG"; rm -f "$J"; rc=$(run -- tests/test_x.py); has "a divergência aprendida vale na rodada seguinte (sombra desligada): vai ao MBP" "$J" '"reason":"mac-only"'
shadow_env; STUB_RUN_RC_NODE=1 STUB_RUN_RC_MBP=1 STUB_RUN_OUT_NODE='FAILED tests/a.py::t - x' STUB_RUN_OUT_MBP='FAILED tests/a.py::t - x' run -- tests/a.py tests/b.py >/dev/null
has "mesmo rc e mesmos arquivos reprovados: 'same'" "$SHLOG" '"verdict":"same"'
shadow_env; STUB_RUN_RC_NODE=1 STUB_RUN_RC_MBP=1 STUB_RUN_OUT_NODE='FAILED tests/a.py::t - x' STUB_RUN_OUT_MBP='FAILED tests/a.py::t - x\nFAILED tests/b.py::u - y' run -- tests/a.py tests/b.py >/dev/null
has "mesmo rc (1) mas reprovam arquivos diferentes: diverge" "$SHLOG" '"verdict":"diverge"'; has "só o arquivo que difere é marcado (b.py)" "$LEARNED" '^tests/b\.py$'; hasnt "…e o que reprova dos dois lados (a.py) não" "$LEARNED" 'a\.py'
shadow_env; STUB_RUN_RC_NODE=0 STUB_RUN_RC_MBP=1 run -- tests/a.py tests/b.py::t >/dev/null
has "rc difere sem nenhum arquivo legível: TODOS os alvos .py viram mac-only (mais no Mac, nunca menos)" "$LEARNED" '^tests/a\.py$'; has "…inclusive o de node id (pelo arquivo)" "$LEARNED" '^tests/b\.py$'
shadow_env; rc=$(STUB_RUN_RC_NODE=1 STUB_RUN_RC_MBP=0 run -- tests/test_x.py); expect "nó 1, MBP 0: o chamador recebe o 1 do nó" 1 "$rc"; has "…e é divergência" "$SHLOG" '"verdict":"diverge","a_host":"hetzner","a_rc":1,"b_host":"mbp","b_rc":0'
shadow_env; rc=$(STUB_UNREACHABLE_MBP=1 run -- tests/test_x.py); expect "MBP fora na sombra: o chamador não sente" 0 "$rc"; has "veredito 'skipped' com o rc do MBP" "$SHLOG" '"verdict":"skipped","a_host":"hetzner","a_rc":0,"b_host":"mbp","b_rc":98'; [ ! -e "$LEARNED" ] && ok "MBP indisponível: nada é aprendido" || bad "aprendeu sem comparar"
shadow_env; rm -f "$FLAG"; rc=$(run -- tests/test_x.py); expect "MBP desligado: a sombra não roda e o nó responde" 0 "$rc"; has "veredito 'skipped' (rc 99)" "$SHLOG" '"verdict":"skipped".*"b_rc":99'; date > "$FLAG"
# o teto de espera tem de DERRUBAR a sombra: o trap `exit 130` do filho só roda quando o comando em primeiro plano dele (o ssh ao MBP) termina, então um kill só no PID deixava o wait segurando quem chamou até o MBP acabar.
# Sem relógio (carga do mini varia de 6 s a 26 s no mesmo caso): o nó só devolve depois que a sombra começou a dormir no MBP (60 s), e se confere que o sono NÃO chegou ao fim quando quem chamou voltou.
rm -f "$T/slow.start" "$T/slow.end"
shadow_env; rc=$(HETZNER_SHADOW_WAIT_S=1 STUB_SLEEP_MARK="$T/slow" STUB_NODE_WAIT_FOR="$T/slow.start" STUB_RUN_SLEEP_MBP=60 run -- tests/test_x.py); late=0; [ -e "$T/slow.end" ] && late=1
expect "MBP lento (dormindo 60 s): quem chamou recebe o rc do nó" 0 "$rc"; has "veredito 'timeout'" "$SHLOG" '"verdict":"timeout"'
[ -e "$T/slow.start" ] && ok "a sombra já dormia no MBP quando o teto (1 s) estourou (o caso não é vazio)" || bad "a sombra nem chegou a dormir no MBP"
[ "$late" = 0 ] && ok "o teto derruba a sombra: quem chamou volta ANTES de o MBP lento acordar" || bad "quem chamou ficou preso até o MBP lento acordar (a sombra não foi derrubada)"
[ ! -e "$LEARNED" ] && ok "timeout: nada é aprendido" || bad "timeout aprendeu"
shadow_env; touch -t 202001010000 "$NODEFLAG"; run -- tests/test_x.py >/dev/null; hasnt "bandeira com mais de 24 h: janela fechada, sem sombra" "$STUB_LOG" 'HOSTCALL:mbp'
shadow_env; touch -t 202001010000 "$NODEFLAG"; HETZNER_SHADOW_WINDOW_S=999999999 run -- tests/test_x.py >/dev/null; has "janela configurável (HETZNER_SHADOW_WINDOW_S) reabre a sombra" "$STUB_LOG" 'HOSTCALL:mbp:RUN'
shadow_env; export HETZNER_SHADOW_PCT=0; run -- tests/test_x.py >/dev/null; hasnt "HETZNER_SHADOW_PCT=0: sem sombra" "$STUB_LOG" 'HOSTCALL:mbp'
shadow_env; STUB_UNREACHABLE_NODE=1 run -- tests/test_x.py >/dev/null; [ "$(grep -c 'HOSTCALL:mbp:RUN' "$STUB_LOG")" = 1 ] && ok "nó fora (a bateria foi ao MBP): não há o que comparar, sem sombra" || bad "sombra com o nó fora"
[ ! -e "$SHLOG" ] && ok "…e nenhum veredito é gravado" || bad "veredito gravado sem sombra"
shadow_env; rc=$(STUB_RUN_RC_NODE=255 run -- tests/test_x.py); expect "nó cai no meio com a sombra rodando: a bateria vai ao MBP e a sombra é abortada" 0 "$rc"; [ ! -e "$SHLOG" ] && ok "…sem veredito da sombra" || bad "veredito de uma sombra abortada"
# rc de AMBIENTE não é veredito de teste. O nó que estoura o tempo (124), é morto por sinal (137) ou não acha o comando (127) com o MBP verde — e o MBP que faz o mesmo com o nó verde — NÃO podem virar
# "mac-only": a lista aprendida nunca expira, então um timeout passageiro prenderia a bateria inteira no Mac (o rc de infraestrutura entrava como se fosse reprovação de teste).
for nrc in 124 137 127; do
  shadow_env; rc=$(STUB_RUN_RC_NODE=$nrc STUB_RUN_RC_MBP=0 run -- tests/test_x.py); expect "nó com rc de ambiente $nrc (MBP 0): quem chamou recebe o rc do nó" "$nrc" "$rc"
  has "nó rc=$nrc: veredito 'skipped' com o rc do nó" "$SHLOG" "\"verdict\":\"skipped\",\"a_host\":\"hetzner\",\"a_rc\":$nrc,\"b_host\":\"mbp\",\"b_rc\":null"; hasnt "nó rc=$nrc: nenhum 'diverge'" "$SHLOG" '"verdict":"diverge"'
  [ ! -e "$LEARNED" ] && ok "nó rc=$nrc: nada é aprendido" || bad "nó rc=$nrc (ambiente) ensinou mac-only: $(tr '\n' ' ' < "$LEARNED")"
  has "nó rc=$nrc: avisa que não há veredito" "$T/err" "sombra: o nó terminou com rc=$nrc"
done
shadow_env; rc=$(STUB_RUN_RC_NODE=97 STUB_RUN_RC_MBP=0 run -- tests/test_x.py); expect "nó rc=97 (o cd do job falhou): cai no MBP e roda" 0 "$rc"
has "nó rc=97: veredito 'skipped'" "$SHLOG" '"verdict":"skipped","a_host":"hetzner","a_rc":97'; [ ! -e "$LEARNED" ] && ok "nó rc=97: nada é aprendido" || bad "nó rc=97 (wrapper) ensinou mac-only"
for brc in 124 137; do
  shadow_env; rc=$(STUB_RUN_RC_NODE=0 STUB_RUN_RC_MBP=$brc run -- tests/test_x.py); expect "MBP com rc de ambiente $brc (nó 0): o chamador não sente" 0 "$rc"
  has "MBP rc=$brc: veredito 'skipped' com o rc do MBP" "$SHLOG" "\"verdict\":\"skipped\",\"a_host\":\"hetzner\",\"a_rc\":0,\"b_host\":\"mbp\",\"b_rc\":$brc"
  [ ! -e "$LEARNED" ] && ok "MBP rc=$brc: nada é aprendido" || bad "MBP rc=$brc (ambiente) ensinou mac-only: $(tr '\n' ' ' < "$LEARNED")"
done
# controle positivo: a exceção é SÓ para rc de ambiente — rc 2 (pytest interrompido) é veredito de teste e continua aprendendo
shadow_env; rc=$(STUB_RUN_RC_NODE=2 STUB_RUN_RC_MBP=0 run -- tests/test_x.py); expect "nó rc=2 (pytest interrompido) é veredito de teste: o chamador recebe o 2" 2 "$rc"
has "…e é divergência" "$SHLOG" '"verdict":"diverge","a_host":"hetzner","a_rc":2'; has "…e o arquivo é aprendido" "$LEARNED" '^tests/test_x\.py$'
# saída ILEGÍVEL não é "nenhum arquivo reprovou": failed_files devolve vazio nos dois casos, e comparar esse vazio com os arquivos reprovados do outro lado ensinaria mac-only a partir de um problema local.
# O MBP reprova tests/test_x.py; se a saída do NÓ (ou a do MBP) não abre, é "não sei", não divergência. (Como root o chmod não bloqueia a leitura: o caso é pulado e NÃO contado.)
if [ "$(id -u)" = 0 ]; then echo "skip saída ilegível da sombra (root: o chmod não bloqueia a leitura; caso não executado, não contado)"
else
  for side in NODE MBP; do
    shadow_env; rc=$(env STUB_UNREADABLE_${side}_OUT=1 STUB_RUN_RC_NODE=0 STUB_RUN_RC_MBP=1 STUB_RUN_OUT_NODE='ok' STUB_RUN_OUT_MBP='FAILED tests/test_x.py::t - x' "$RUN" --repo wa --dir "$T/wt" -- tests/test_x.py >"$T/out" 2>"$T/err"; echo $?)
    expect "saída do $side ilegível: o chamador recebe o rc do nó" 0 "$rc"
    has "saída do $side ilegível: veredito 'skipped' (não 'diverge')" "$SHLOG" '"verdict":"skipped","a_host":"hetzner","a_rc":0,"b_host":"mbp","b_rc":1'; hasnt "saída do $side ilegível: nenhum 'diverge'" "$SHLOG" '"verdict":"diverge"'
    [ ! -e "$LEARNED" ] && ok "saída do $side ilegível: nada é aprendido" || bad "saída ilegível ($side) ensinou mac-only: $(tr '\n' ' ' < "$LEARNED")"
    has "saída do $side ilegível: avisa que não leu" "$T/err" 'sombra: a saída de um dos lados não pôde ser lida'
  done
fi
# a mensagem só diz "marcado" do que foi GRAVADO ($learned), não do que se pretendia gravar
shadow_env; STUB_RUN_RC_NODE=0 STUB_RUN_RC_MBP=1 run -- tests >/dev/null
has "divergência sem alvo .py (diretório): o log diz learned:0" "$SHLOG" '"verdict":"diverge".*"learned":0'; [ ! -e "$LEARNED" ] && ok "…e nada é gravado na lista aprendida" || bad "gravou na lista aprendida sem alvo .py"
has "…e a mensagem diz que nada foi marcado" "$T/err" 'DIVERGÊNCIA \(nó rc=0, MBP rc=1\) — nada marcado como mac-only'; hasnt "…em vez de afirmar 'marcado como mac-only:'" "$T/err" 'marcado como mac-only: '
if [ "$(id -u)" = 0 ]; then echo "skip gravação recusada da lista aprendida (root: o chmod não bloqueia a escrita; caso não executado, não contado)"
else
  shadow_env; printf '# lista aprendida (somente leitura)\n' > "$LEARNED"; chmod 444 "$LEARNED"
  STUB_RUN_RC_NODE=0 STUB_RUN_RC_MBP=1 run -- tests/test_x.py >/dev/null; chmod 644 "$LEARNED"
  has "lista aprendida recusa a gravação: o AVISO sai" "$T/err" 'AVISO: não consegui gravar'; has "…e o log diz learned:0" "$SHLOG" '"verdict":"diverge".*"learned":0'
  has "…e a mensagem diz que NADA foi marcado" "$T/err" 'DIVERGÊNCIA \(nó rc=0, MBP rc=1\) — NADA foi marcado como mac-only'; hasnt "…nem afirma 'marcado como mac-only:' logo depois do AVISO" "$T/err" 'marcado como mac-only: '
fi
shadow_end
node_seed_cases
node_hq_cases
}

# ===== a semeadura do nó (MBP_SELFTEST_ONLY=semeadura roda só esta parte) =====
node_seed_cases() {
local rc
MUT="${MUT:-$T/mutdir}"; mkdir -p "$MUT"; for mf in mbp-presence.sh mbp-controle.sh hetzner-rsync-filter.wa.txt hetzner-pii-scan.py hetzner-mac-only.txt; do ln -sf "$HERE/$mf" "$MUT/$mf"; done
NOSCAN="${NOSCAN:-$T/noscandir}"; mkdir -p "$NOSCAN"; for mf in mbp-presence.sh mbp-controle.sh hetzner-rsync-filter.wa.txt; do ln -sf "$HERE/$mf" "$NOSCAN/$mf"; done   # SEM o hetzner-pii-scan.py, de propósito
phones() { awk -v n="$1" 'BEGIN { for (i = 1; i <= n; i++) printf "\"+55319%08d\",\n", (i * 7654321) % 100000000 }'; }
reset; date > "$NODEFLAG"
SEEDROOT="$T/seedroot"; mkdir -p "$SEEDROOT/tests" "$SEEDROOT/lib" "$SEEDROOT/data" "$SEEDROOT/shared/logs"; echo code > "$SEEDROOT/lib/a.py"; : > "$SEEDROOT/tests/test_x.py"; echo s > "$SEEDROOT/.env"; echo s > "$SEEDROOT/x.duckdb"; echo d > "$SEEDROOT/data/a.txt"; echo o > "$SEEDROOT/shared/logs/a.out"
# o que a 13/10 levou ao nó e o que o node_guard/filtro têm de segurar: token por NOME, LISTA de telefones (25) e a de 3 números que passa, e .gc-worktrees (a convenção do Gas City)
mkdir -p "$SEEDROOT/processo_lookup" "$SEEDROOT/.gc-worktrees/wa-x/lib"; echo s > "$SEEDROOT/processo_lookup/.pdpj_token.txt"; echo code > "$SEEDROOT/.gc-worktrees/wa-x/lib/a.py"
phones 25 > "$SEEDROOT/lib/leads_list.py"; phones 3 > "$SEEDROOT/lib/few.py"
SEEDVENV="$T/seedvenv"; mkdir -p "$SEEDVENV/bin"; printf '#!/usr/bin/env bash\ncase "$*" in *sys.version_info*) echo 3.14 ;; *"pip freeze"*) echo "pytest==9.0.2"; echo "pyobjc-core==1;" ;; esac\n' > "$SEEDVENV/bin/python"; chmod +x "$SEEDVENV/bin/python"
cat > "$T/bin/uv" <<'EOF'
#!/usr/bin/env bash
echo "UV:$*" >> "$STUB_LOG"
# STUB_UV_FAIL_DRYRUN=1: o resolvedor não fecha com o freeze (o motivo de existir do --dry-run)
case "$*" in *--dry-run*) if [ "${STUB_UV_FAIL_DRYRUN:-0}" = 1 ]; then echo "error: No solution found when resolving dependencies"; exit 2; fi; echo "Would install 1 package" ;; esac
if [ "$1 $2" = "pip freeze" ]; then printf 'requests==2.0.0\npyobjc-core==10.0\nPyObjC-framework-Cocoa==10.0\nappnope==0.1\n-e git+https://x/y#egg=y\nfoo @ file:///x\npytest==9.0.2\n\n# comentario\n'; [ -z "${STUB_UV_FREEZE_EXTRA:-}" ] || printf '%s\n' "$STUB_UV_FREEZE_EXTRA"; fi
EOF
chmod +x "$T/bin/uv"
WANT_HASH=$(printf 'pytest==9.0.2\nrequests==2.0.0\n' | shasum | awk '{print $1}')
seed() { HETZNER_SEED_ROOT="$SEEDROOT" HETZNER_SEED_VENV="$SEEDVENV" "$RUN" --host linux --seed wa >"$T/out" 2>"$T/err"; echo $?; }
BASEDEST="$T/home/gt-remote/wa-base"
reset; find "$BASEDEST" -mindepth 1 -delete 2>/dev/null; mkdir -p "$BASEDEST/processo_lookup"; echo old > "$BASEDEST/processo_lookup/.env.pdpj"
rc=$(STUB_RSYNC_REAL=1 STUB_DIRECT_OUT=nada seed); expect "seed do nó: roda (hash do remoto difere → instala)" 0 "$rc"
n=$((n+1)); if [ ! -e "$BASEDEST/.env" ] && [ ! -e "$BASEDEST/x.duckdb" ] && [ ! -e "$BASEDEST/data/a.txt" ] && [ ! -e "$BASEDEST/shared/logs/a.out" ] && [ ! -e "$BASEDEST/processo_lookup/.env.pdpj" ]; then echo "ok   seed: nada de dado/segredo na base (e o .env.pdpj antigo foi removido por --delete-excluded)"; else echo "FAIL seed: a base ficou com dado ou segredo"; fails=$((fails+1)); fi
n=$((n+1)); if [ -f "$BASEDEST/lib/a.py" ] && [ -f "$BASEDEST/tests/test_x.py" ]; then echo "ok   seed: o código chegou"; else echo "FAIL seed: o código não chegou"; fails=$((fails+1)); fi
if [ ! -e "$BASEDEST/lib/leads_list.py" ] && [ -f "$BASEDEST/lib/few.py" ]; then ok "seed: a LISTA de 25 telefones fica no mini (node_guard) e o arquivo com 3 números chega"; else bad "seed: a lista de telefones chegou à base (ou o node_guard barrou demais): leads_list=$([ -e "$BASEDEST/lib/leads_list.py" ] && echo chegou || echo ficou) few=$([ -f "$BASEDEST/lib/few.py" ] && echo chegou || echo ficou)"; fi
has "seed: avisa o que ficou no mini (sem os valores)" "$T/err" 'ficam no mini e NÃO vão ao'; hasnt "seed: o aviso não traz telefone" "$T/err" '55319'
if [ ! -e "$BASEDEST/.gc-worktrees" ] && [ ! -e "$BASEDEST/processo_lookup/.pdpj_token.txt" ]; then ok "seed: .gc-worktrees e o token por nome não chegaram"; else bad "seed: .gc-worktrees ou .pdpj_token.txt chegou à base"; fi
has "seed: auditoria rodou no destino" "$STUB_LOG" 'HOSTCALL:hetzner:AUDIT'; has "seed: freeze filtrado enviado (pytest)" "$T/freeze-sent.txt" '^pytest==9\.0\.2$'; has "seed: freeze filtrado enviado (requests)" "$T/freeze-sent.txt" '^requests==2\.0\.0$'
n=$((n+1)); if grep -q -i -E 'pyobjc|appnope|git\+|file://|^#' "$T/freeze-sent.txt" 2>/dev/null; then echo "FAIL seed: o freeze enviado ainda tem pacote do macOS / instalação local"; fails=$((fails+1)); else echo "ok   seed: sem pyobjc/appnope/-e/@ file:// no freeze"; fi
has "seed: instala com uv no venv do nó" "$STUB_LOG" 'DIRECT:.*uv pip install --python gt-remote/venv-wa/bin/python -r gt-remote/freeze-wa.txt'; has "seed: grava o hash do freeze só depois de instalar" "$STUB_LOG" "DIRECT:.*uv pip install.*; echo $WANT_HASH > gt-remote/venv-wa/.freeze-hash"
: > "$STUB_LOG"; rc=$(STUB_RSYNC_REAL=1 STUB_DIRECT_OUT="$WANT_HASH" seed); expect "seed com o hash igual: nada a instalar" 0 "$rc"; hasnt "…sem uv pip install" "$STUB_LOG" 'uv pip install'; has "…diz que já bate" "$T/err" 'dependências do nó Linux já batem'
: > "$STUB_LOG"; rc=$(STUB_RSYNC_REAL=1 STUB_DIRECT_OUT=nada STUB_DIRECT_FAIL_ON='uv pip install' seed); expect "uv que falha: rc 98" 98 "$rc"; has "…diz que o hash NÃO foi gravado" "$T/err" 'o hash NÃO foi gravado'
: > "$STUB_LOG"; rc=$(HETZNER_SEED_DRYRUN=1 STUB_RSYNC_REAL=1 STUB_DIRECT_OUT=nada seed); expect "dry-run" 0 "$rc"; has "dry-run: usa --dry-run" "$STUB_LOG" 'uv pip install --dry-run'; hasnt "dry-run: NÃO grava o hash" "$STUB_LOG" '> gt-remote/venv-wa/\.freeze-hash'
# hash que NÃO se calculou não é hash que bate (gate de 16/10): o shasum que falha deixa "" e o .freeze-hash que faltou no nó também é "" — "" = "" dizia "já batem" e o venv do nó parava de se atualizar sem aviso
SHAFAIL="$T/shafail"; mkdir -p "$SHAFAIL"; printf '#!/bin/sh\nexit 1\n' > "$SHAFAIL/shasum"; chmod +x "$SHAFAIL/shasum"
SHAJUNK="$T/shajunk"; mkdir -p "$SHAJUNK"; printf '#!/bin/sh\ncat >/dev/null\necho "shasum: lixo"\n' > "$SHAJUNK/shasum"; chmod +x "$SHAJUNK/shasum"
: > "$STUB_LOG"; rc=$(PATH="$SHAFAIL:$PATH" STUB_RSYNC_REAL=1 seed); expect "hash do freeze que não se calculou (shasum falha) e .freeze-hash ausente no nó: 97" 97 "$rc"
hasnt "…não diz 'já batem'" "$T/err" 'já batem'; has "…diz que não conseguiu calcular o hash" "$T/err" 'não consegui calcular o hash do freeze'; hasnt "…e não instala nada" "$STUB_LOG" 'uv pip install --python'
: > "$STUB_LOG"; rc=$(PATH="$SHAJUNK:$PATH" STUB_RSYNC_REAL=1 seed); expect "shasum que imprime lixo (não é sha1 hex): 97" 97 "$rc"; hasnt "…e o lixo não vira .freeze-hash" "$STUB_LOG" '> gt-remote/venv-wa/\.freeze-hash'
# controle negativo: o mutante em que hash_valid aceita tudo volta ao defeito (rc 0, "já batem") — o caso acima o pega
sed 's/^hash_valid() { .*$/hash_valid() { return 0; }/' "$RUN" > "$MUT/mut-hashvalid.sh"; chmod +x "$MUT/mut-hashvalid.sh"
n=$((n+1)); if cmp -s "$RUN" "$MUT/mut-hashvalid.sh"; then echo "FAIL premissa: o mutante do hash_valid é igual ao script (o sed não casou)"; fails=$((fails+1)); else echo "ok   premissa: o mutante do hash_valid difere do script"; fi
: > "$STUB_LOG"; PATH="$SHAFAIL:$PATH" HETZNER_SEED_ROOT="$SEEDROOT" HETZNER_SEED_VENV="$SEEDVENV" STUB_RSYNC_REAL=1 "$MUT/mut-hashvalid.sh" --host linux --seed wa >"$T/out" 2>"$T/err"; rc=$?
n=$((n+1)); if [ "$rc" = 97 ]; then echo "FAIL controle: sem o hash_valid o seed ainda dá 97 (o caso do hash não pega nada)"; fails=$((fails+1)); else echo "ok   controle: sem o hash_valid o seed volta ao defeito (rc $rc) e o caso do hash o pega"; fi
# o mesmo hash no caminho do MBP (semeadura sem --host linux): .sp-hash ausente + shasum falhando = "" = "" = "site-packages já bate"
if ls -d /Users/athos/gt/whatsapp_automation/venv/lib/python3.*/site-packages >/dev/null 2>&1; then
  : > "$STUB_LOG"; PATH="$SHAFAIL:$PATH" "$RUN" --seed wa >"$T/out" 2>"$T/err"; expect "MBP --seed: hash dos pacotes que não se calculou (shasum falha) e .sp-hash ausente: 97" 97 "$?"
  hasnt "…não diz que o site-packages já bate" "$T/err" 'já bate'; has "…diz que não conseguiu calcular o hash" "$T/err" 'não consegui calcular o hash dos pacotes'; hasnt "…e não grava o .sp-hash" "$STUB_LOG" '> gt-remote/venv-wa/\.sp-hash'
else echo "SKIP MBP --seed com hash que falha: venv local do WA ausente neste host (esse caminho NÃO foi exercitado)"; fi
# dry-run: o comando remoto roda DE VERDADE (STUB_DIRECT_EXEC_ON) — o `| tail -40` devolvia o status do tail e um uv que falhou saía 0. A mensagem também não promete "nada é alterado": a base já foi semeada
: > "$STUB_LOG"; rc=$(HETZNER_SEED_DRYRUN=1 STUB_RSYNC_REAL=1 STUB_DIRECT_OUT=nada STUB_DIRECT_EXEC_ON='--dry-run' seed); expect "dry-run com o uv rodando de verdade: rc 0" 0 "$rc"
has "…o uv rodou com --dry-run" "$STUB_LOG" 'UV:pip install --dry-run'; has "…e mostra o que ele instalaria" "$T/out" 'Would install 1 package'
has "…diz que a base JÁ foi semeada e o freeze enviado" "$T/err" 'a base foi semeada e o freeze enviado'; hasnt "…e não diz 'nada é alterado'" "$T/err" 'nada é alterado'
: > "$STUB_LOG"; rc=$(HETZNER_SEED_DRYRUN=1 STUB_RSYNC_REAL=1 STUB_DIRECT_OUT=nada STUB_DIRECT_EXEC_ON='--dry-run' STUB_UV_FAIL_DRYRUN=1 seed); expect "dry-run com o uv falhando (erro de resolução): rc 98, o tail não esconde o status" 98 "$rc"
has "…diz que o dry-run falhou" "$T/err" 'dry-run falhou'; has "…e ainda mostra o erro do uv" "$T/out" 'No solution found'
HETZNER_SEED_ROOT="$SEEDROOT" HETZNER_SEED_VENV="$SEEDVENV" HETZNER_RSYNC_FILTER="$T/unsafe-filter" "$RUN" --host linux --seed wa >"$T/out" 2>"$T/err"; expect "seed com filtro inseguro: 97 (não semeia)" 97 "$?"
# ---- ps no nó (ga-2hd02v.4.8): SÓ o venv. A árvore de runtime do PS (data/, logs/, shared/, .env, lista de telefones) NÃO vai por rsync: o código do PS chega pelo espelho git. O freeze vai para
# freeze-ps.txt e o venv é o venv-ps, nunca o do wa. Os arquivos *_unico* da árvore falsa são a prova de vazamento: se algum aparecer no nó (qualquer pasta), o seed levou árvore.
PSROOT="$T/psroot"; mkdir -p "$PSROOT/data" "$PSROOT/logs" "$PSROOT/lib" "$PSROOT/shared"; echo s > "$PSROOT/.env"; echo d > "$PSROOT/data/ps_leads_unico.csv"; echo c > "$PSROOT/lib/ps_codigo_unico.py"; phones 25 > "$PSROOT/lib/ps_lista_unico.py"
ps_leak() { find "$T/home" -name 'ps_*_unico*' 2>/dev/null | wc -l | tr -d ' '; }
ps_clean() { find "$T/home/gt-remote" -name 'ps_*_unico*' -delete 2>/dev/null; find "$T/home/gt-remote/wa-base" -mindepth 1 -delete 2>/dev/null; rm -f "$T/freeze-sent.txt"; : > "$STUB_LOG"; }
pseed() { HETZNER_SEED_ROOT="$PSROOT" HETZNER_SEED_VENV="$SEEDVENV" "$RUN" --host linux --seed ps >"$T/out" 2>"$T/err"; echo $?; }
ps_clean; rc=$(STUB_RSYNC_REAL=1 STUB_DIRECT_OUT=nada pseed); expect "seed ps no nó: roda (hash do remoto difere → instala)" 0 "$rc"
has "ps: instala com uv no venv-ps do nó, com o freeze-ps" "$STUB_LOG" 'DIRECT:.*uv pip install --python gt-remote/venv-ps/bin/python -r gt-remote/freeze-ps\.txt'
has "ps: grava o hash do freeze só depois de instalar, no venv-ps" "$STUB_LOG" "DIRECT:.*uv pip install.*; echo $WANT_HASH > gt-remote/venv-ps/\.freeze-hash"
hasnt "ps: não toca no venv-wa nem no freeze-wa" "$STUB_LOG" 'venv-wa|freeze-wa'
has "ps: freeze filtrado enviado (pytest)" "$T/freeze-sent.txt" '^pytest==9\.0\.2$'; has "ps: freeze filtrado enviado (requests)" "$T/freeze-sent.txt" '^requests==2\.0\.0$'
n=$((n+1)); if grep -q -i -E 'pyobjc|appnope|git\+|file://|^#' "$T/freeze-sent.txt" 2>/dev/null; then echo "FAIL ps: o freeze enviado ainda tem pacote do macOS / instalação local"; fails=$((fails+1)); else echo "ok   ps: sem pyobjc/appnope/-e/@ file:// no freeze"; fi
hasnt "ps: nenhum rsync (a árvore do PS não vai ao nó)" "$STUB_LOG" 'RSYNC:'; hasnt "ps: sem auditoria de base (não há base)" "$STUB_LOG" 'HOSTCALL:hetzner:AUDIT'
eq "ps: nenhum arquivo da árvore do PS apareceu no nó (dado, segredo, lista de telefones, código)" "0" "$(ps_leak)"
[ ! -e "$T/home/gt-remote/ps-base" ] && ok "ps: não existe base do PS no nó" || bad "ps: criou uma base do PS no nó"
ps_clean; rc=$(STUB_RSYNC_REAL=1 STUB_DIRECT_OUT="$WANT_HASH" pseed); expect "ps com o hash igual: nada a instalar" 0 "$rc"; hasnt "…sem uv pip install" "$STUB_LOG" 'uv pip install'; has "…diz que já bate" "$T/err" 'dependências do nó Linux já batem'
ps_clean; rc=$(STUB_RSYNC_REAL=1 STUB_DIRECT_OUT=nada STUB_DIRECT_FAIL_ON='uv pip install' pseed); expect "ps: uv que falha: rc 98" 98 "$rc"; has "…diz que o hash NÃO foi gravado" "$T/err" 'o hash NÃO foi gravado'
ps_clean; rc=$(HETZNER_SEED_DRYRUN=1 STUB_RSYNC_REAL=1 STUB_DIRECT_OUT=nada pseed); expect "ps dry-run" 0 "$rc"; has "ps dry-run: resolve contra o venv-ps com --dry-run" "$STUB_LOG" 'uv pip install --dry-run --python gt-remote/venv-ps/bin/python -r gt-remote/freeze-ps\.txt'
has "ps dry-run: cria o venv-ps vazio se faltava (sem interpretador o uv não resolve)" "$STUB_LOG" 'test -x gt-remote/venv-ps/bin/python \|\| uv venv --python 3\.14 gt-remote/venv-ps'; hasnt "ps dry-run: NÃO grava o hash" "$STUB_LOG" '> gt-remote/venv-ps/\.freeze-hash'
has "ps dry-run: a mensagem não promete base semeada" "$T/err" 'DRY-RUN: o freeze foi enviado'; hasnt "ps dry-run: sem 'a base foi semeada'" "$T/err" 'a base foi semeada'
ps_clean; rc=$(HETZNER_SEED_ROOT="$PSROOT" HETZNER_SEED_VENV="$T/nao-existe-venv" STUB_RSYNC_REAL=1 STUB_DIRECT_OUT=nada "$RUN" --host linux --seed ps >"$T/out" 2>"$T/err"; echo $?); expect "ps com o venv local ausente: 97" 97 "$rc"; has "…diz qual python faltou" "$T/err" 'python local do venv ausente'; hasnt "…e não instala nada" "$STUB_LOG" 'uv pip install'
# freeze com linha que não é pin simples (URL com credencial): 97 e NADA enviado ao nó (nem freeze, nem uv). Vale para o ps e para o wa (a guarda é do trecho de dependências, comum aos dois)
PS_URLTOK='private-pkg @ git+https://ghp_FAKEtoken123@github.com/x/private-pkg.git'
ps_clean; rc=$(STUB_UV_FREEZE_EXTRA="$PS_URLTOK" STUB_RSYNC_REAL=1 STUB_DIRECT_OUT=nada pseed); expect "ps com URL+credencial no freeze: 97" 97 "$rc"; has "…diz que não é pin simples" "$T/err" 'não é pin simples'
hasnt "…e o freeze NÃO foi enviado ao nó" "$STUB_LOG" 'cat > gt-remote/freeze-'; [ ! -e "$T/freeze-sent.txt" ] && ok "…nem a credencial chegou a um arquivo do nó" || bad "…o freeze com a credencial chegou ao nó"; hasnt "…e o uv não rodou" "$STUB_LOG" 'uv pip install'
ps_clean; rc=$(STUB_UV_FREEZE_EXTRA="$PS_URLTOK" STUB_RSYNC_REAL=1 STUB_DIRECT_OUT=nada seed); expect "wa com URL+credencial no freeze: 97 (a guarda vale para os dois repos)" 97 "$rc"; hasnt "…e o freeze NÃO foi enviado" "$STUB_LOG" 'cat > gt-remote/freeze-'
ps_clean; rc=$(STUB_UV_FREEZE_EXTRA='pkg @ https://example.com/p.whl' STUB_RSYNC_REAL=1 STUB_DIRECT_OUT=nada pseed); expect "ps com '@ https://' (sem credencial) também é recusado: forma que não é pin simples" 97 "$rc"
PS_LOWRAM='avail_mb=1000\nswap_mb=0\nswap_delta_mb=0\npressure=1\npower=ac\nbatt='   # preflight do nó recusa por RAM e o ssh segue vivo (STUB_UNREACHABLE_NODE mataria o ssh também, e o mutante sem preflight não teria como escrever)
ps_clean; rc=$(STUB_PF_RAW_NODE="$PS_LOWRAM" STUB_RSYNC_REAL=1 STUB_DIRECT_OUT=nada pseed); expect "ps com o nó sem RAM no preflight: 98" 98 "$rc"
hasnt "…e nada foi escrito no nó (sem mkdir, sem freeze, sem uv)" "$STUB_LOG" 'DIRECT:'
ps_clean; rc=$(STUB_UNREACHABLE_NODE=1 STUB_RSYNC_REAL=1 STUB_DIRECT_OUT=nada pseed); n=$((n+1)); if [ "$rc" -ge 96 ] && [ "$rc" -le 99 ]; then echo "ok   ps com o nó fora: recusa (rc $rc)"; else echo "FAIL ps com o nó fora: esperado 96..99, veio $rc"; fails=$((fails+1)); fi
# controles negativos: cada defeito que o caso acima existe para pegar, injetado no script, TEM de aparecer
ps_mut() { # nome sed-expr  (devolve o caminho do mutante; recusa mutante igual ao script)
  sed "$2" "$RUN" > "$MUT/mut-$1.sh"; chmod +x "$MUT/mut-$1.sh"
  n=$((n+1)); if cmp -s "$RUN" "$MUT/mut-$1.sh"; then echo "FAIL premissa: o mutante $1 é igual ao script (o sed não casou)"; fails=$((fails+1)); else echo "ok   premissa: o mutante $1 difere do script"; fi
}
ps_run_mut() { HETZNER_SEED_ROOT="$PSROOT" HETZNER_SEED_VENV="$SEEDVENV" STUB_RSYNC_REAL=1 STUB_DIRECT_OUT=nada "$MUT/mut-$1.sh" --host linux --seed ps >"$T/out" 2>"$T/err"; echo $?; }
ps_mut psvenvwa 's/rv=venv-ps;/rv=venv-wa;/'
ps_clean; rc=$(ps_run_mut psvenvwa); n=$((n+1)); if grep -q 'venv-wa' "$STUB_LOG"; then echo "ok   controle: com o venv do wa no lugar do venv-ps o caso o pega (o log mostra venv-wa)"; else echo "FAIL controle: o mutante que instala o PS no venv-wa passou despercebido"; fails=$((fails+1)); fi
ps_mut psfzwa 's/fz="freeze-\$seed_repo\.txt"/fz="freeze-wa.txt"/'
ps_clean; rc=$(ps_run_mut psfzwa); n=$((n+1)); if grep -q 'freeze-wa' "$STUB_LOG"; then echo "ok   controle: com o freeze do wa no lugar do freeze-ps o caso o pega (o log mostra freeze-wa)"; else echo "FAIL controle: o mutante que sobrescreve o freeze-wa passou despercebido"; fails=$((fails+1)); fi
ps_mut psbase 's/^  if \[ "\$seed_repo" = wa \]; then$/  if true; then/'
ps_clean; rc=$(ps_run_mut psbase); n=$((n+1)); if [ "$(ps_leak)" != 0 ] || grep -q 'RSYNC:' "$STUB_LOG"; then echo "ok   controle: se o ps seguisse o caminho da base do wa, a árvore do PS chegaria ao nó e o caso o pega (rsync no log / arquivo no nó)"; else echo "FAIL controle: o mutante que semeia a árvore do PS passou despercebido"; fails=$((fails+1)); fi
ps_mut pspreflight '/# ps: só o venv\. preflight/{n;s/preflight || return \$?/true/;}'
ps_clean; rc=$(STUB_PF_RAW_NODE="$PS_LOWRAM" ps_run_mut pspreflight); n=$((n+1)); if grep -q 'DIRECT:' "$STUB_LOG"; then echo "ok   controle: sem o preflight o ps escreve no nó sem RAM e o caso o pega (DIRECT no log)"; else echo "FAIL controle: o mutante sem preflight no ps passou despercebido"; fails=$((fails+1)); fi
ps_mut psnoplain 's/\[ -n "\$plain" \] && \[ "\$plain" = "\$total" \] || /true || /'
ps_clean; rc=$(STUB_UV_FREEZE_EXTRA="$PS_URLTOK" ps_run_mut psnoplain); n=$((n+1)); if grep -q 'ghp_FAKEtoken123' "$T/freeze-sent.txt" 2>/dev/null; then echo "ok   controle: sem a guarda a credencial vai ao freeze do nó e o caso a pega (freeze-sent traz o token)"; else echo "FAIL controle: o mutante sem a guarda de pin simples passou despercebido"; fails=$((fails+1)); fi
ps_clean
HETZNER_SEED_ROOT="$T/nao-existe" HETZNER_SEED_VENV="$SEEDVENV" "$RUN" --host linux --seed wa >"$T/out" 2>"$T/err"; expect "árvore local ausente: 97" 97 "$?"
printf '#!/usr/bin/env bash\ncase "$*" in *sys.version_info*) echo 3.14 ;; esac\nexit 1\n' > "$SEEDVENV/bin/python"
mkdir -p "$T/emptyhome"; : > "$STUB_LOG"; HOME="$T/emptyhome" PATH="/usr/bin:/bin:/usr/sbin:/sbin" HETZNER_SEED_ROOT="$SEEDROOT" HETZNER_SEED_VENV="$SEEDVENV" STUB_RSYNC_REAL=1 MBP_SSH="$T/bin/ssh" MBP_RSYNC="$T/bin/rsync" "$RUN" --host linux --seed wa >"$T/out" 2>"$T/err"; rc=$?
printf '#!/usr/bin/env bash\ncase "$*" in *sys.version_info*) echo 3.14 ;; *"pip freeze"*) echo "pytest==9.0.2" ;; esac\n' > "$SEEDVENV/bin/python"
expect "sem uv e sem pip no venv local: 97 (não lê 'sem dependências')" 97 "$rc"; has "…diz que não conseguiu ler as dependências" "$T/err" 'não consegui ler as dependências do venv local'
# auditoria: um vazamento no destino é ALARME. O mutante sem filtro deixa o .env chegar e a auditoria o pega.
sed 's/--filter=". \$NODE_FILTER" //' "$RUN" > "$MUT/mut-nofilter2.sh"; chmod +x "$MUT/mut-nofilter2.sh"
find "$BASEDEST" -mindepth 1 -delete 2>/dev/null; HETZNER_SEED_ROOT="$SEEDROOT" HETZNER_SEED_VENV="$SEEDVENV" STUB_RSYNC_REAL=1 STUB_DIRECT_OUT=nada "$MUT/mut-nofilter2.sh" --host linux --seed wa >"$T/out" 2>"$T/err"; expect "auditoria: com o filtro removido a semeadura é recusada (98)" 98 "$?"
has "auditoria: ALARME e os caminhos" "$T/err" 'ALARME: dado ou segredo no destino'; has "…cita o .env que vazou" "$T/err" '\.env'; has "…cita o duckdb que vazou" "$T/err" 'x\.duckdb'; hasnt "…e não chega a instalar nada" "$STUB_LOG" 'uv pip install --python'
has "…cita o token que vazou (a lista de nomes da auditoria tem token, a antiga não tinha)" "$T/err" 'pdpj_token'
has "…manda DESLIGAR o nó (o ALARME não desliga sozinho: a bandeira segue ligada)" "$T/err" 'mbp-offload\.sh node off'; hasnt "…e esta auditoria terminou (sem o aviso de auditoria incompleta)" "$T/err" 'NÃO terminou'
# CONTEÚDO: o mutante tira o HELD SÓ do rsync da semeadura (a linha com "$root"/; o node_guard e a verificação dele ficam intactos) e deixa a LISTA de telefones chegar ao destino; só a auditoria de conteúdo (o scanner rodando no servidor) a pega
sed '/"\$root"\//s/--filter=". \$HELD" //' "$RUN" > "$MUT/mut-noheld.sh"; chmod +x "$MUT/mut-noheld.sh"
n=$((n+1)); if cmp -s "$RUN" "$MUT/mut-noheld.sh"; then echo "FAIL premissa: o mutante sem o HELD é igual ao script (o sed não casou)"; fails=$((fails+1)); else echo "ok   premissa: o mutante sem o HELD difere do script"; fi
find "$BASEDEST" -mindepth 1 -delete 2>/dev/null; : > "$STUB_LOG"; HETZNER_SEED_ROOT="$SEEDROOT" HETZNER_SEED_VENV="$SEEDVENV" STUB_RSYNC_REAL=1 STUB_DIRECT_OUT=nada "$MUT/mut-noheld.sh" --host linux --seed wa >"$T/out" 2>"$T/err"; expect "auditoria de CONTEÚDO: sem o HELD a lista de telefones chega e a semeadura é recusada (98)" 98 "$?"
has "…ALARME cita CONTEUDO, as contagens e o caminho" "$T/err" 'CONTEUDO [0-9]+[[:space:]]+0[[:space:]]+lib/leads_list\.py'; hasnt "…nunca o valor do telefone" "$T/err" '55319'; hasnt "…e não instala nada" "$STUB_LOG" 'uv pip install --python'
# JWT num .json de caminho liberado (lib/changelog.d): o filtro e o scanner de lista deixam passar, a auditoria não. Um JWT só já é segredo.
SEEDROOT2="$T/seedroot2"; cp -R "$SEEDROOT" "$SEEDROOT2"; mkdir -p "$SEEDROOT2/lib/changelog.d"; printf '{"t": "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJlLXRleHQ"}\n' > "$SEEDROOT2/lib/changelog.d/jwt.json"
find "$BASEDEST" -mindepth 1 -delete 2>/dev/null; : > "$STUB_LOG"; HETZNER_SEED_ROOT="$SEEDROOT2" HETZNER_SEED_VENV="$SEEDVENV" STUB_RSYNC_REAL=1 STUB_DIRECT_OUT=nada "$RUN" --host linux --seed wa >"$T/out" 2>"$T/err"; expect "auditoria de JWT: um JWT num .json liberado → 98" 98 "$?"
has "…ALARME cita JWT e o caminho" "$T/err" 'JWT lib/changelog\.d/jwt\.json'; hasnt "…nunca o valor do token" "$T/err" 'eyJhbGci'; hasnt "…e não instala nada" "$STUB_LOG" 'uv pip install --python'
# arquivo > 4 MB num caminho liberado: o scanner o lê inteiro e não vê nada; o tamanho é o que o denuncia
SEEDROOT3="$T/seedroot3"; cp -R "$SEEDROOT" "$SEEDROOT3"; dd if=/dev/zero of="$SEEDROOT3/lib/big.py" bs=1048576 count=5 2>/dev/null
find "$BASEDEST" -mindepth 1 -delete 2>/dev/null; : > "$STUB_LOG"; HETZNER_SEED_ROOT="$SEEDROOT3" HETZNER_SEED_VENV="$SEEDVENV" STUB_RSYNC_REAL=1 STUB_DIRECT_OUT=nada "$RUN" --host linux --seed wa >"$T/out" 2>"$T/err"; expect "auditoria de tamanho: arquivo > 4 MB → 98" 98 "$?"
has "…ALARME cita GRANDE e o caminho" "$T/err" 'GRANDE lib/big\.py'
# a auditoria que NÃO consegue olhar (ssh caiu no meio / python ausente no nó) não é "nada achado"
find "$BASEDEST" -mindepth 1 -delete 2>/dev/null; : > "$STUB_LOG"; rc=$(STUB_RSYNC_REAL=1 STUB_DIRECT_OUT=nada STUB_AUDIT_BROKEN=1 seed); expect "auditoria que não consegue olhar: 98" 98 "$rc"
has "…diz que não conseguiu auditar" "$T/err" 'não consegui auditar'; hasnt "…e não instala nada" "$STUB_LOG" 'uv pip install --python'; hasnt "…e sem nada achado não é ALARME (prio 4, não 5)" "$T/err" 'ALARME'
# achou um vazamento E a auditoria caiu antes de terminar: vale o que achou. É ALARME (prio 5) com o aviso de que não terminou — não "não consegui auditar" (prio 4), que jogaria o achado fora
find "$BASEDEST" -mindepth 1 -delete 2>/dev/null; : > "$STUB_LOG"; rc=$(STUB_RSYNC_REAL=1 STUB_DIRECT_OUT=nada STUB_AUDIT_BROKEN=2 seed); expect "auditoria que ACHOU e caiu antes de terminar: 98" 98 "$rc"
has "…é ALARME, não 'não consegui auditar'" "$T/err" 'ALARME: dado ou segredo no destino'; hasnt "…e não degrada para o aviso de prio menor" "$T/err" 'não consegui auditar'; has "…cita o que achou antes de cair" "$T/err" 'NOME \.env'
has "…avisa que a auditoria NÃO terminou" "$T/err" 'NÃO terminou'; has "…manda desligar o nó" "$T/err" 'mbp-offload\.sh node off'; hasnt "…e não instala nada" "$STUB_LOG" 'uv pip install --python'
# gate-fix 2 (ga-n653mm): achou a LISTA de telefones (CONTEUDO) E a auditoria não conseguiu ler um arquivo/pasta. A auditoria aqui é a REAL (o script remoto + o hetzner-pii-scan.py, sem enlatar a saída):
# o scanner devolve rc 3 para o arquivo ilegível e o find reclama no stderr da pasta ilegível — as duas saídas viravam AUDIT_ERR ANTES de imprimir o que o scanner já tinha achado, e a lista de leads no servidor saía como
# "não consegui auditar" (prio 4, sem ALARME e sem a instrução de desligar o nó). O mutante noheld deixa a lista chegar ao destino; STUB_AUDIT_UNREADABLE* põe o ilegível lá dentro, antes da auditoria.
UNR_FILE=gt-remote/wa-base/lib/ilegivel.py; UNR_DIR=gt-remote/wa-base/pasta-ilegivel
clean_dest() { chmod 755 "$STUB_HOME/$UNR_DIR" 2>/dev/null; chmod 644 "$STUB_HOME/$UNR_FILE" 2>/dev/null; find "$BASEDEST" -mindepth 1 -delete 2>/dev/null; : > "$STUB_LOG"; }
alarm_found_and_unfinished() { # $1 = rótulo do caso
  has "$1: é ALARME (achou), não 'não consegui auditar'" "$T/err" 'ALARME: dado ou segredo no destino'; hasnt "$1: e não degrada para o aviso de prio menor" "$T/err" 'não consegui auditar'
  has "$1: avisa que a auditoria NÃO terminou" "$T/err" 'NÃO terminou'; has "$1: manda desligar o nó" "$T/err" 'mbp-offload\.sh node off'; hasnt "$1: e não instala nada" "$STUB_LOG" 'uv pip install --python'
}
clean_dest; HETZNER_SEED_ROOT="$SEEDROOT" HETZNER_SEED_VENV="$SEEDVENV" STUB_RSYNC_REAL=1 STUB_DIRECT_OUT=nada STUB_AUDIT_UNREADABLE="$UNR_FILE" "$MUT/mut-noheld.sh" --host linux --seed wa >"$T/out" 2>"$T/err"; expect "auditoria REAL: lista achada + arquivo ilegível (rc 3 do scanner) → 98" 98 "$?"
if [ -e "$BASEDEST/lib/ilegivel.py" ] && [ ! -r "$BASEDEST/lib/ilegivel.py" ]; then ok "premissa: o arquivo ilegível existe no destino e este usuário não o lê"; else bad "premissa: o arquivo do destino não ficou ilegível (rodando como root? o caso abaixo não prova nada)"; fi
alarm_found_and_unfinished "lista + arquivo ilegível"; has "…cita CONTEUDO, as contagens e o caminho da lista" "$T/err" 'CONTEUDO [0-9]+[[:space:]]+0[[:space:]]+lib/leads_list\.py'; hasnt "…nunca o valor do telefone" "$T/err" '55319'
hasnt "…e o arquivo que NÃO se leu não vira achado (-1/-1 é 'não sei', não AUDIT_BAD)" "$T/err" 'ilegivel\.py'
clean_dest; HETZNER_SEED_ROOT="$SEEDROOT" HETZNER_SEED_VENV="$SEEDVENV" STUB_RSYNC_REAL=1 STUB_DIRECT_OUT=nada STUB_AUDIT_UNREADABLE_DIR="$UNR_DIR" "$MUT/mut-noheld.sh" --host linux --seed wa >"$T/out" 2>"$T/err"; expect "auditoria REAL: lista achada + pasta ilegível (stderr do find, scanner rc 0) → 98" 98 "$?"
if [ -d "$BASEDEST/pasta-ilegivel" ] && [ ! -r "$BASEDEST/pasta-ilegivel" ]; then ok "premissa: a pasta ilegível existe no destino e este usuário não a lê"; else bad "premissa: a pasta do destino não ficou ilegível (rodando como root?)"; fi
alarm_found_and_unfinished "lista + pasta ilegível"; has "…cita CONTEUDO, as contagens e o caminho da lista" "$T/err" 'CONTEUDO [0-9]+[[:space:]]+0[[:space:]]+lib/leads_list\.py'
# o irmão que já imprimia na hora (NOME): continua valendo com a auditoria real caindo depois
clean_dest; HETZNER_SEED_ROOT="$SEEDROOT" HETZNER_SEED_VENV="$SEEDVENV" STUB_RSYNC_REAL=1 STUB_DIRECT_OUT=nada STUB_AUDIT_UNREADABLE="$UNR_FILE" "$MUT/mut-nofilter2.sh" --host linux --seed wa >"$T/out" 2>"$T/err"; expect "auditoria REAL: segredo por NOME achado + arquivo ilegível → 98" 98 "$?"
alarm_found_and_unfinished "NOME + arquivo ilegível"; has "…cita o .env que vazou" "$T/err" 'NOME \.env'
# controle: sem nada achado, o ilegível continua sendo "não sei" (98, prio 4) — o -1/-1 não pode virar ALARME
clean_dest; HETZNER_SEED_ROOT="$SEEDROOT" HETZNER_SEED_VENV="$SEEDVENV" STUB_RSYNC_REAL=1 STUB_DIRECT_OUT=nada STUB_AUDIT_UNREADABLE="$UNR_FILE" "$RUN" --host linux --seed wa >"$T/out" 2>"$T/err"; expect "auditoria REAL: nada achado + arquivo ilegível → 98" 98 "$?"
has "…é 'não consegui auditar'" "$T/err" 'não consegui auditar'; hasnt "…e sem achado não é ALARME (prio 4, não 5)" "$T/err" 'ALARME'; hasnt "…e não instala nada" "$STUB_LOG" 'uv pip install --python'
# mutante (controle negativo): a ordem ANTIGA — o CONTEUDO só sai depois dos dois AUDIT_ERR — joga a lista achada fora; o caso "lista + arquivo ilegível" acima tem de ver o defeito
OLDPRINT='head -20 "$E.p" | sed '"'"'s/^/AUDIT_BAD CONTEUDO /'"'"
awk -v pr="$OLDPRINT" 'index($0, "grep -E \047^[0-9]+[[:space:]]\047 \"$E.p\"") == 1 { next } { print } $0 == "[ -s \"$E\" ] && { echo AUDIT_ERR; exit 3; }" { print pr }' "$MUT/mut-noheld.sh" > "$MUT/mut-oldorder.sh"; chmod +x "$MUT/mut-oldorder.sh"
n=$((n+1)); if cmp -s "$MUT/mut-noheld.sh" "$MUT/mut-oldorder.sh"; then echo "FAIL premissa: o mutante da ordem antiga é igual ao noheld (o awk não casou)"; fails=$((fails+1)); else echo "ok   premissa: o mutante da ordem antiga difere do script"; fi
clean_dest; HETZNER_SEED_ROOT="$SEEDROOT" HETZNER_SEED_VENV="$SEEDVENV" STUB_RSYNC_REAL=1 STUB_DIRECT_OUT=nada STUB_AUDIT_UNREADABLE="$UNR_FILE" "$MUT/mut-oldorder.sh" --host linux --seed wa >"$T/out" 2>"$T/err"; expect "controle (ordem antiga): lista + arquivo ilegível ainda recusa (98)" 98 "$?"
has "controle (ordem antiga): o defeito aparece — o achado vira 'não consegui auditar'" "$T/err" 'não consegui auditar'; hasnt "controle (ordem antiga): e não há ALARME" "$T/err" 'ALARME'
clean_dest; HETZNER_SEED_ROOT="$SEEDROOT" HETZNER_SEED_VENV="$SEEDVENV" STUB_RSYNC_REAL=1 STUB_DIRECT_OUT=nada STUB_AUDIT_UNREADABLE_DIR="$UNR_DIR" "$MUT/mut-oldorder.sh" --host linux --seed wa >"$T/out" 2>"$T/err"
has "controle (ordem antiga): a pasta ilegível também esconde o achado" "$T/err" 'não consegui auditar'; hasnt "controle (ordem antiga): e não há ALARME (pasta)" "$T/err" 'ALARME'
clean_dest
# o node_guard da semeadura falha FECHADO: sem o scanner (hetzner-pii-scan.py) NADA é copiado — não é "nada retido"
cp "$RUN" "$NOSCAN/mut-noscan-seed.sh"; chmod +x "$NOSCAN/mut-noscan-seed.sh"
find "$BASEDEST" -mindepth 1 -delete 2>/dev/null; : > "$STUB_LOG"; HETZNER_SEED_ROOT="$SEEDROOT" HETZNER_SEED_VENV="$SEEDVENV" STUB_RSYNC_REAL=1 STUB_DIRECT_OUT=nada "$NOSCAN/mut-noscan-seed.sh" --host linux --seed wa >"$T/out" 2>"$T/err"; expect "seed sem o hetzner-pii-scan.py: 98 (não semeia)" 98 "$?"
has "…diz que não varreu o conteúdo" "$T/err" 'não consegui varrer o conteúdo'
n=$((n+1)); if [ -z "$(find "$BASEDEST" -type f 2>/dev/null | head -1)" ]; then echo "ok   …e nenhum arquivo foi copiado para a base"; else echo "FAIL …a base recebeu arquivos mesmo sem a varredura"; fails=$((fails+1)); fi
find "$BASEDEST" -mindepth 1 -delete 2>/dev/null
reset

# ===== --audit-node (ga-2hd02v.1.5.2): o node_audit da semeadura, pasta a pasta, com o veredito de cada uma no stdout (a auditoria RODA de verdade no HOME falso) =====
echo "--- --audit-node (ga-2hd02v.1.5.2)"
# o arquivo tem de CARREGAR sob o /bin/bash do sistema (3.2 no macOS): um `case` dentro de $( <<'EOF' ) quebrava o parser dele e o mbp-run.sh INTEIRO deixava de rodar (achado pelo caso "sem uv e sem pip", que usa o PATH mínimo)
/bin/bash -n "$RUN" 2>"$T/err"; expect "mbp-run.sh carrega sob /bin/bash -n (3.2 no macOS)" 0 "$?"
AN="$T/home"; mkdir -p "$AN/an-limpa/src" "$AN/an-achada" "$AN/an-venv/venv/lib" "$AN/an-topo/sub"
echo code > "$AN/an-limpa/src/a.py"; : > "$AN/an-achada/leak.db"; : > "$AN/an-venv/venv/lib/cacert.pem"; echo x > "$AN/an-venv/ok.py"; : > "$AN/an-topo/.env"; : > "$AN/an-topo/sub/x.db"
an() { "$RUN" --host linux "$@" >"$T/out" 2>"$T/err"; echo $?; }
reset; rc=$(an --audit-node an-limpa); expect "audit-node: pasta limpa" 0 "$rc"; has "…e o stdout diz LIMPO" "$T/out" '^AUDIT-NODE LIMPO an-limpa$'
rc=$(an --audit-node an-achada); expect "audit-node: pasta com .db é ACHADO" 98 "$rc"; has "…ACHADO no stdout" "$T/out" '^AUDIT-NODE ACHADO an-achada$'; has "…e o caminho no stderr" "$T/err" 'NOME leak\.db'
rc=$(STUB_AUDIT_BROKEN=1 an --audit-node an-limpa); expect "audit-node: auditoria que não consegue olhar" 98 "$rc"; has "…diz NAO-CONSEGUI (nem LIMPO, nem ACHADO)" "$T/out" '^AUDIT-NODE NAO-CONSEGUI an-limpa$'
rc=$(an --audit-node an-limpa --audit-node an-achada); expect "audit-node: duas pastas, uma achada → 98" 98 "$rc"; has "…a limpa continua LIMPO" "$T/out" '^AUDIT-NODE LIMPO an-limpa$'; has "…e a outra ACHADO" "$T/out" '^AUDIT-NODE ACHADO an-achada$'
rc=$(an --audit-node an-ausente); expect "audit-node: pasta que não existe é NAO-CONSEGUI, nunca LIMPO" 98 "$rc"; has "…no stdout" "$T/out" '^AUDIT-NODE NAO-CONSEGUI an-ausente$'
rc=$(an --audit-node an-venv); expect "audit-node: sem poda o cacert.pem de um venv é achado" 98 "$rc"; has "…cita o .pem" "$T/err" 'NOME venv/lib/cacert\.pem'
rc=$(an --audit-node 'an-venv::prune=venv'); expect "audit-node: prune=venv tira o venv e o resto segue limpo" 0 "$rc"
rc=$(an --audit-node 'an-topo::maxdepth=1'); expect "audit-node: maxdepth=1 vê o .env do topo" 98 "$rc"; has "…cita o .env" "$T/err" 'NOME \.env'; hasnt "…mas não desce até sub/x.db" "$T/err" 'x\.db'
rc=$(an --audit-node an-topo); expect "audit-node: sem maxdepth vê também o sub/x.db" 98 "$rc"; has "…cita o x.db" "$T/err" 'x\.db'
reset   # zera o log do stub: a checagem logo depois do laço só vale se NENHUMA auditoria rodou desde aqui
for bad in 'an-limpa::-delete' 'an-limpa::prune=../x' 'an-limpa::maxdepth=99' 'an-limpa::prune=a b' '../x' '/etc' 'an limpa' ''; do
  rc=$(an --audit-node "$bad"); expect "audit-node: argumento '$bad' é recusado (uso, 97) e nada roda" 97 "$rc"
done
n=$((n+1)); if ! grep -q 'HOSTCALL:hetzner:AUDIT' "$STUB_LOG"; then echo "ok   …e nenhuma auditoria chegou ao servidor"; else echo "FAIL …uma auditoria rodou com argumento inválido"; fails=$((fails+1)); fi
rc=$("$RUN" --audit-node an-limpa >"$T/out" 2>"$T/err"; echo $?); expect "audit-node: sem --host linux (o MBP) é recusado" 97 "$rc"; has "…pelo motivo certo (a mensagem do modo, não a flag desconhecida)" "$T/err" "audit-node é do nó Linux"
# a semeadura (node_audit SEM o 2º argumento) segue coberta pelos casos de auditoria acima: o script real roda sem o 3º argumento e esses casos continuam passando
reset; rc=$(an --audit-node an-limpa); has "audit-node: o script de auditoria chegou ao nó" "$STUB_LOG" 'HOSTCALL:hetzner:AUDIT'
}

node_hq_cases() {  # ga-kz76o7: o repo hq no nó (chamada pela node_cases, depois da semeadura do wa)
# ===== repo hq (ga-kz76o7): os selftests bash da fábrica no nó — sem venv, filtro e lista mac-only próprios, sombra no MINI, nunca no MBP =====
echo "--- repo hq no nó (ga-kz76o7)"
WTH="$T/wt-hq"; mkdir -p "$WTH/scripts" "$WTH/packs/town-deltas/assets" "$T/home/gt-remote/mirror/hq-1" "$T/home/gt-remote/hq-base"
printf '#!/usr/bin/env bash\nexit "${HQ_FAKE_RC:-0}"\n' > "$WTH/scripts/x.selftest.sh"; : > "$WTH/scripts/nightly-reboot.selftest.sh"; : > "$WTH/scripts/not_a_test.sh"
HQLEARNED="$T/city/.gc/hetzner-mac-only.hq.learned"; HQSEEDED="$T/city/.gc/hetzner-node.hq.seeded"
hreset() { reset; rm -f "$HQLEARNED" "$HQSEEDED"; }
hrun() { "$RUN" --repo hq --dir "$WTH" "$@" >"$T/out" 2>"$T/err"; echo $?; }
hreset; date > "$NODEFLAG"; rc=$(hrun -- scripts/x.selftest.sh); expect "hq: selftest roda no nó" 0 "$rc"
has "hq: log repo=hq mode=selftest host=hetzner" "$J" '"repo":"hq","mode":"selftest".*"host":"hetzner"'; hasnt "hq: o MBP nunca é chamado" "$STUB_LOG" 'HOSTCALL:mbp'; has "hq: diz onde rodou" "$T/err" 'rodou em hetzner \(nó Linux\)'
has "hq: o job é bash <selftest>, não pytest" "$(lsf RUN hetzner)" 'nice -n "\$MBP_NICE" bash scripts/x.selftest.sh'; hasnt "hq: sem -m pytest" "$(lsf RUN hetzner)" '\-m pytest'; hasnt "hq: sem xdist (-n N)" "$(lsf RUN hetzner)" 'bash -n [0-9]'
has "hq: identidade git fixa (selftest que cria repositório temporário)" "$(lsf RUN hetzner)" 'GIT_COMMITTER_EMAIL=gt@no'
has "hq: o espelho parte de hq-base" "$(lsf MIRROR hetzner)" 'gt-remote/hq-base'; hasnt "hq: o MIRROR não exige venv" "$(lsf MIRROR hetzner)" 'NOVENV'
has "hq: o rsync usa o filtro do hq" "$STUB_LOG" 'hetzner-rsync-filter\.hq\.txt'; hasnt "hq: …e não o do wa" "$STUB_LOG" 'hetzner-rsync-filter\.wa\.txt'
hreset; date > "$NODEFLAG"; rc=$(STUB_RUN_RC_NODE=1 hrun -- scripts/x.selftest.sh); expect "hq: rc do selftest propagado (1)" 1 "$rc"; has "…e logado" "$J" '"rc":1.*"host":"hetzner"'
# ga-q9vyyn — AMBIENTE: o selftest reprova porque o ESPELHO do nó não tem um arquivo que o worktree tem (gc-session-ssh: o filtro só levava extensão; 143 de 182 casos com rc 127 no nó, verde no mini).
# O hq não existe no MBP, então a saída é 97 ("rode local") + a linha AMBIENTE, nunca o rc da bateria. Só vale para caminho DENTRO do espelho que EXISTE no worktree: se falta nos dois, é o teste
# exercitando o erro (ou um defeito de verdade) e o rc continua sendo veredito. A saída do nó é a canned do stub (STUB_RUN_OUT_NODE); o slot do espelho é o 1.
MIR='/home/runner/gt-remote/mirror/hq-1'; mkdir -p "$WTH/scripts/pytest-shim/bin"
printf '#!/usr/bin/env bash\n' > "$WTH/scripts/gc-session-ssh"; chmod +x "$WTH/scripts/gc-session-ssh"; printf '#!/usr/bin/env bash\n' > "$WTH/scripts/pytest-shim/pytest-shim.sh"; ln -sf ../pytest-shim.sh "$WTH/scripts/pytest-shim/bin/pytest"   # como no repo: o symlink aponta para um alvo que existe. Symlink PENDENTE não serve aqui: o hetzner-pii-scan.py devolve rc 3, o node_guard falha fechado e TODO caso hq seguinte vira 97 (medido 17/10)
hreset; date > "$NODEFLAG"; rc=$(STUB_RUN_RC_NODE=1 STUB_RUN_OUT_NODE="env: '$MIR/scripts/gc-session-ssh': No such file or directory (rc 127)" hrun -- scripts/x.selftest.sh); expect "hq ambiente: reprova por arquivo FALTANDO no espelho (existe no worktree) → 97, não o rc 1" 97 "$rc"
has "…diz AMBIENTE e o arquivo que faltou" "$T/err" 'AMBIENTE: .*scripts/gc-session-ssh'; has "…diz que o rc da bateria NÃO é veredito" "$T/err" 'rc=1 desta bateria NÃO é veredito'; has "…e manda rodar local" "$T/err" 'rode local'
has "…log: a execução leva rc 97 (não o rc 1 do nó)" "$J" '"repo":"hq","mode":"selftest".*"rc":97,.*"host":"hetzner"'; hasnt "…log: nenhuma execução com rc 1 como veredito" "$J" '"mode":"selftest".*"rc":1,'
has "…log: recusa ambiente-espelho (entra em mbp-offload.sh counts)" "$J" '"reason":"ambiente-espelho".*"host":"hetzner"'; hasnt "…o MBP não é chamado" "$STUB_LOG" 'HOSTCALL:mbp'
hreset; date > "$NODEFLAG"; rc=$(STUB_RUN_RC_NODE=1 STUB_RUN_OUT_NODE="Traceback (most recent call last):\nFileNotFoundError: [Errno 2] No such file or directory: '$MIR/scripts/gc-session-ssh'" hrun -- scripts/x.selftest.sh); expect "hq ambiente: a forma do python (frase, depois o caminho entre aspas) também → 97" 97 "$rc"
hreset; date > "$NODEFLAG"; rc=$(STUB_RUN_RC_NODE=1 STUB_RUN_OUT_NODE="bash: $MIR/scripts/pytest-shim/bin/pytest: No such file or directory" hrun -- scripts/x.selftest.sh); expect "hq ambiente: symlink (pytest-shim/bin/pytest) que falta no espelho e existe no worktree → 97" 97 "$rc"
hreset; date > "$NODEFLAG"; rc=$(STUB_RUN_RC_NODE=1 STUB_RUN_OUT_NODE="env: '$MIR/scripts/gc-session-ssh': No such file or directory\nenv: '$MIR/scripts/gc-session-ssh': No such file or directory\nbash: $MIR/scripts/pytest-shim/bin/pytest: No such file or directory\nbash: $MIR/scripts/nao-existe-no-worktree: No such file or directory" hrun -- scripts/x.selftest.sh); expect "hq ambiente: vários casos → 97" 97 "$rc"
has "…conta ARQUIVOS distintos que existem no worktree (2; o repetido e o que também falta no worktree não entram)" "$T/err" 'não tem 2 arquivo\(s\)'
# …e o que NÃO é ambiente continua sendo veredito do teste
hreset; date > "$NODEFLAG"; rc=$(STUB_RUN_RC_NODE=1 STUB_RUN_OUT_NODE="bash: $MIR/scripts/nao-existe-no-worktree: No such file or directory" hrun -- scripts/x.selftest.sh); expect "hq: arquivo que falta no espelho E no worktree é o teste exercitando o erro: o rc 1 segue como veredito" 1 "$rc"; hasnt "…sem AMBIENTE" "$T/err" 'AMBIENTE'; hasnt "…sem recusa ambiente-espelho" "$J" 'ambiente-espelho'
hreset; date > "$NODEFLAG"; rc=$(STUB_RUN_RC_NODE=1 STUB_RUN_OUT_NODE="env: '/home/runner/outro/scripts/gc-session-ssh': No such file or directory" hrun -- scripts/x.selftest.sh); expect "hq: caminho FORA do espelho (mesmo nome que existe no worktree) não é ambiente → rc 1" 1 "$rc"
hreset; date > "$NODEFLAG"; rc=$(STUB_RUN_RC_NODE=1 STUB_RUN_OUT_NODE="env: '/home/runner/gt-remote/mirror/hq-11/scripts/gc-session-ssh': No such file or directory" hrun -- scripts/x.selftest.sh); expect "hq: espelho de OUTRO slot (hq-11 não é hq-1) não é o nosso → rc 1" 1 "$rc"
hreset; date > "$NODEFLAG"; rc=$(STUB_RUN_RC_NODE=0 STUB_RUN_OUT_NODE="env: '$MIR/scripts/gc-session-ssh': No such file or directory" hrun -- scripts/x.selftest.sh); expect "hq: bateria que PASSOU (rc 0) não é reclassificada, mesmo com a frase na saída" 0 "$rc"
hreset; date > "$NODEFLAG"; rc=$(STUB_RUN_RC_NODE=137 STUB_RUN_OUT_NODE="env: '$MIR/scripts/gc-session-ssh': No such file or directory" hrun -- scripts/x.selftest.sh); expect "hq: morta por sinal (137) já não é veredito e não é reclassificada: sai o 137" 137 "$rc"
hreset; date > "$NODEFLAG"; rc=$(STUB_RUN_RC_NODE=1 STUB_RUN_OUT_NODE="FAIL x: esperado 1, veio 2" hrun -- scripts/x.selftest.sh); expect "hq: reprovação comum, sem a frase na saída → rc 1 (veredito)" 1 "$rc"
# saída do nó que NÃO abre = "não sei": o rc fica como veredito e sai um AVISO (nunca reclassifica em silêncio). Como root o chmod não bloqueia a leitura: caso pulado e NÃO contado.
if [ "$(id -u)" = 0 ]; then echo "skip hq ambiente com saída ilegível (root: o chmod não bloqueia a leitura; caso não executado, não contado)"
else hreset; date > "$NODEFLAG"; rc=$(STUB_UNREADABLE_NODE_OUT=1 STUB_RUN_RC_NODE=1 STUB_RUN_OUT_NODE="env: '$MIR/scripts/gc-session-ssh': No such file or directory" hrun -- scripts/x.selftest.sh); expect "hq ambiente: saída do nó ilegível → o rc 1 fica como veredito" 1 "$rc"; has "…e avisa que não deu para conferir" "$T/err" 'AVISO: não consegui conferir a saída do nó'; hasnt "…sem AMBIENTE" "$T/err" 'AMBIENTE'; fi
# o sed que extrai os caminhos FALHA (estado "não sei", distinto de "nenhum arquivo faltando"): rc 1 fica e sai o AVISO, em silêncio não. Sed falso: só com STUB_SED_FAIL=1 e só para o script do mirror_gap (o único que cita gt-remote/mirror/); senão é o sed de verdade.
REAL_SED=$(PATH=/usr/bin:/bin command -v sed); printf '#!/usr/bin/env bash\nif [ "${STUB_SED_FAIL:-0}" = 1 ]; then case "$*" in *gt-remote/mirror/*) exit 1 ;; esac; fi\nexec %s "$@"\n' "$REAL_SED" > "$T/bin/sed"; chmod +x "$T/bin/sed"
hreset; date > "$NODEFLAG"; rc=$(STUB_SED_FAIL=1 STUB_RUN_RC_NODE=1 STUB_RUN_OUT_NODE="env: '$MIR/scripts/gc-session-ssh': No such file or directory" hrun -- scripts/x.selftest.sh); expect "hq ambiente: o sed que extrai os caminhos FALHA → 'não sei': o rc 1 fica como veredito" 1 "$rc"; has "…e avisa que não deu para conferir (não vira 'nenhum arquivo faltando' em silêncio)" "$T/err" 'AVISO: não consegui conferir a saída do nó'; hasnt "…sem AMBIENTE" "$T/err" 'AMBIENTE'
hreset; date > "$NODEFLAG"; rc=$(STUB_RUN_RC_NODE=1 STUB_RUN_OUT_NODE="env: '$MIR/scripts/gc-session-ssh': No such file or directory" hrun -- scripts/x.selftest.sh); expect "hq ambiente: controle do sed falso — sem STUB_SED_FAIL o mesmo caso volta a dar 97 (o sed falso só falha quando mandado)" 97 "$rc"
rm -f "$T/bin/sed"   # o sed falso só vale para os dois casos acima
# a sombra NÃO aprende com isso: sem este caso, o nó rc=1 contra o mini rc=0 viraria "diverge" e a lista aprendida prenderia a bateria no Mac para sempre (foi o que aconteceu com o gc-session-ssh, 17/10)
hreset; date > "$NODEFLAG"; date > "$HQSEEDED"; rc=$(HETZNER_SHADOW_PCT=100 HETZNER_SHADOW_WAIT_S=20 STUB_RUN_RC_NODE=1 STUB_RUN_OUT_NODE="env: '$MIR/scripts/gc-session-ssh': No such file or directory" hrun -- scripts/x.selftest.sh); expect "hq ambiente + sombra: 97" 97 "$rc"
has "…a sombra termina 'skipped' (nó 97 não é veredito)" "$SHLOG" '"repo":"hq","verdict":"skipped","a_host":"hetzner","a_rc":97'; hasnt "…nenhum 'diverge'" "$SHLOG" '"verdict":"diverge"'; [ ! -e "$HQLEARNED" ] && ok "…e NADA entra na lista aprendida do hq" || bad "…a lista aprendida do hq ganhou conteúdo: $(cat "$HQLEARNED")"
hreset; rc=$(hrun -- scripts/x.selftest.sh); expect "hq com o nó desligado: 97 (o hq não existe no MBP; quem chamou roda local)" 97 "$rc"; hasnt "…sem chamar ninguém" "$STUB_LOG" 'HOSTCALL'; has "…e diz" "$T/err" 'o hq não existe no MBP — rode local'
hreset; date > "$NODEFLAG"; rc=$(STUB_UNREACHABLE_NODE=1 hrun -- scripts/x.selftest.sh); expect "hq com o nó fora: 97, sem tentar o MBP" 97 "$rc"; hasnt "…o MBP não é chamado" "$STUB_LOG" 'HOSTCALL:mbp'; has "…recusa do nó logada" "$J" '"reason":"inalcancavel".*"host":"hetzner"'
hreset; date > "$NODEFLAG"; rc=$(HETZNER_MAC_ONLY_LIST="$HERE/hetzner-mac-only.hq.txt" hrun -- scripts/nightly-reboot.selftest.sh); expect "hq: alvo na lista mac-only REAL do hq (nightly-reboot): 97, não vai ao nó" 97 "$rc"
has "…recusa mac-only logada" "$J" '"reason":"mac-only".*"host":"hetzner"'; hasnt "…nada rodou no nó" "$STUB_LOG" 'HOSTCALL:hetzner:RUN'
hreset; date > "$NODEFLAG"; rc=$(HETZNER_MAC_ONLY_LIST="$HERE/hetzner-mac-only.hq.txt" hrun -- scripts/x.selftest.sh); expect "hq: alvo fora da lista real: roda no nó" 0 "$rc"
# a superfície do nó é estreita: só UM *.selftest.sh, relativo, existente, num worktree que é o hq
for bad_args in "tests/test_x.py" "scripts/not_a_test.sh" "/etc/x.selftest.sh" "scripts/../x.selftest.sh" "scripts/missing.selftest.sh" ""; do
  hreset; date > "$NODEFLAG"; rc=$(hrun -- $bad_args); expect "hq: alvo inválido '$bad_args' → 97 sem rodar" 97 "$rc"; hasnt "…nada chamado para '$bad_args'" "$STUB_LOG" 'HOSTCALL'
done
hreset; date > "$NODEFLAG"; rc=$("$RUN" --repo hq --dir "$T/wt" -- scripts/x.selftest.sh >/dev/null 2>"$T/err"; echo $?); expect "hq: --dir que não é o hq (sem packs/ e scripts/): 97" 97 "$rc"
hreset; date > "$NODEFLAG"; rc=$("$RUN" --dir "$T/wt-hq-auto/.gascity-gastown-hq" -- scripts/x.selftest.sh >/dev/null 2>&1; echo $?); eq "hq: deduzido do caminho .gascity-gastown-hq (97 = deduziu hq e barrou o --dir inexistente, não 'não deduzi')" 97 "$rc"
hreset; date > "$NODEFLAG"; "$RUN" --dir "$T/nowhere" -- scripts/x.selftest.sh >/dev/null 2>"$T/err"; has "…repo que não se deduz diz wa|ps|hq" "$T/err" 'use --repo wa\|ps\|hq'
# filtro REAL do hq passa na conferência de forma; lista mac-only real abre
hreset; eq "hq: o filtro real passa no filter_sane" 1 "$(HETZNER_RSYNC_FILTER="$HERE/hetzner-rsync-filter.hq.txt" pfv node_filter_ok)"
hreset; eq "hq: a lista mac-only real abre (1 = nenhum alvo nos args vazios)" 1 "$(HETZNER_MAC_ONLY_LIST="$HERE/hetzner-mac-only.hq.txt" pfv node_mac_only_rc)"
# sombra do hq: o outro lado é o MINI (bash local), não o MBP; divergência aprende o próprio selftest na lista aprendida DO HQ; a janela conta da semeadura
hreset; date > "$NODEFLAG"; date > "$HQSEEDED"; rc=$(HETZNER_SHADOW_PCT=100 HETZNER_SHADOW_WAIT_S=20 hrun -- scripts/x.selftest.sh); expect "hq sombra: nó 0 e mini 0 → same" 0 "$rc"
has "hq sombra: b_host=mini" "$SHLOG" '"repo":"hq","verdict":"same","a_host":"hetzner","a_rc":0,"b_host":"mini","b_rc":0'; hasnt "hq sombra: o MBP não entra" "$STUB_LOG" 'HOSTCALL:mbp'
hreset; date > "$NODEFLAG"; date > "$HQSEEDED"; rc=$(HETZNER_SHADOW_PCT=100 HETZNER_SHADOW_WAIT_S=20 STUB_RUN_RC_NODE=1 hrun -- scripts/x.selftest.sh); expect "hq sombra: nó 1 e mini 0 → diverge (quem chamou recebe o do nó)" 1 "$rc"
has "hq sombra: veredito diverge, learned:1" "$SHLOG" '"repo":"hq","verdict":"diverge","a_host":"hetzner","a_rc":1,"b_host":"mini","b_rc":0.*"learned":1'
[ -f "$HQLEARNED" ] && has "hq sombra: aprende o selftest na lista DO HQ" "$HQLEARNED" '^scripts/x\.selftest\.sh$' || bad "hq sombra: lista aprendida do hq não foi criada"
[ ! -e "$LEARNED" ] && ok "hq sombra: a lista aprendida do wa fica intacta" || bad "hq sombra: escreveu na lista aprendida do wa"
rc=$(hrun -- scripts/x.selftest.sh); expect "hq: depois de aprendido, o alvo não vai mais ao nó (97, roda local)" 97 "$rc"; has "…motivo mac-only" "$J" '"reason":"mac-only"'
hreset; date > "$NODEFLAG"; touch -t 202501010000 "$HQSEEDED"; rc=$(HETZNER_SHADOW_PCT=100 STUB_RUN_RC_NODE=1 hrun -- scripts/x.selftest.sh); expect "hq: semeadura velha = janela fechada, sem sombra" 1 "$rc"; [ ! -e "$SHLOG" ] && ok "…nenhum veredito de sombra" || bad "…sombra rodou com a janela fechada"
# --seed hq: só no nó, pelo filtro real + varredura; cria a base e (re)abre a janela da sombra do hq; .gc nunca sai
hreset; mkdir -p "$T/city/packs" "$T/city/scripts"; printf '#!/usr/bin/env bash\nexit 0\n' > "$T/city/scripts/s.selftest.sh"; echo '{"x":1}' > "$T/city/.gc/logs/mbp-run.jsonl"; echo secret > "$T/city/scripts/.env"
rc=$(STUB_RSYNC_REAL=1 "$RUN" --host linux --seed hq >"$T/out" 2>"$T/err"; echo $?); expect "--host linux --seed hq: semeia" 0 "$rc"
[ -f "$T/home/gt-remote/hq-base/scripts/s.selftest.sh" ] && ok "seed hq: o selftest chegou à base" || bad "seed hq: a base não recebeu scripts/s.selftest.sh"
[ ! -e "$T/home/gt-remote/hq-base/.gc" ] && [ ! -e "$T/home/gt-remote/hq-base/scripts/.env" ] && ok "seed hq: .gc e .env NÃO chegam" || bad "seed hq: .gc ou .env chegaram à base"
[ -f "$HQSEEDED" ] && ok "seed hq: carimbo da semeadura (janela da sombra do hq)" || bad "seed hq: sem carimbo"
rm -rf "$T/city/packs" "$T/city/scripts"; rm -f "$T/city/.gc/logs/mbp-run.jsonl"
# o ps ganhou semente no nó (ga-2hd02v.4.8, casos na seção da semeadura: só o venv): o que continua 97 é repo que o nó não conhece
hreset; rc=$("$RUN" --host linux --seed zz >/dev/null 2>"$T/err"; echo $?); expect "--host linux --seed <repo desconhecido>: 97 (só wa, ps e hq têm semente no nó)" 97 "$rc"; has "…diz" "$T/err" 'uso: --seed wa\|ps\|hq'
hreset; rc=$("$RUN" --seed hq >/dev/null 2>"$T/err"; echo $?); expect "--seed hq sem --host linux: 97" 97 "$rc"; has "…diz" "$T/err" 'use --host linux --seed hq'
# SEGURANÇA, de verdade: rsync REAL com o filtro do hq contra uma árvore de hq com dado e segredo plantados
WTHD="$T/wthd"; mkdir -p "$WTHD/scripts/testdata" "$WTHD/packs/town-deltas/assets/scripts" "$WTHD/docs/runbooks" "$WTHD/docs/reports/x" "$WTHD/docs/research" "$WTHD/agents/dog" "$WTHD/.beads/dolt/hq/.dolt/noms" "$WTHD/.gc/logs" "$WTHD/.gc/runtime/jsonl-archive" "$WTHD/.dolt-backup" "$WTHD/backup" "$WTHD/whatsapp_automation/lib" "$WTHD/gascity/cmd" "$WTHD/docs/pending-engine-window/a.harness"
HQOK="scripts/a.selftest.sh scripts/b.py scripts/hetzner-mac-only.hq.txt scripts/testdata/fixture.json packs/town-deltas/assets/c.sh packs/town-deltas/assets/scripts/d.py packs/town-deltas/assets/e.template.md docs/runbooks/r.md agents/dog/agent.toml pack.toml CLAUDE.md docs/pending-engine-window/p.patch scripts/pytest-shim/pytest-shim.sh scripts/gc-session-ssh scripts/recall scripts/pytest-shim/bin/pytest scripts/pytest-shim/bin/python scripts/pytest-shim/bin/python3"   # os 5 últimos (ga-q9vyyn): executável SEM extensão, por caminho exato (Seção 4)
HQLEAK=".beads/dolt/hq/.dolt/noms/manifest .gc/logs/mbp-run.jsonl .gc/runtime/jsonl-archive/hq.jsonl .gc/state .dolt-backup/hq.tar backup/b.sql.gz city.toml whatsapp_automation/lib/a.py gascity/cmd/main.go scripts/x.db scripts/.env scripts/token.txt scripts/dump.csv scripts/run.log scripts/out.jsonl docs/runbooks/reboot-20261016-pre.txt docs/reports/x/cost.json docs/research/leads.md docs/pending-engine-window/a.harness/sim.txt scripts/shot.png packs/town-deltas/assets/credentials.json scripts/id_rsa scripts/recall2 scripts/sub/recall scripts/gc-session-ssh.bak scripts/pytest-shim/bin/other scripts/pytest-shim/python docs/recall packs/town-deltas/assets/scripts/recall scripts/random-noext recall"   # os 9 últimos (ga-q9vyyn): parecidos com a Seção 4 e NÃO listados nela — prefixo, mesmo nome em outra pasta, extensão desconhecida, nome sem extensão qualquer, raiz
for f in $HQOK; do mkdir -p "$WTHD/$(dirname "$f")"; echo ok > "$WTHD/$f"; done; for f in $HQLEAK; do mkdir -p "$WTHD/$(dirname "$f")"; echo secret > "$WTHD/$f"; done
# como no repositório de verdade: gc-session-ssh é executável e pytest-shim/bin/{pytest,python,python3} são SYMLINKS para ../pytest-shim.sh (o rsync -a tem de levá-los como symlink, com o bit de execução)
chmod +x "$WTHD/scripts/gc-session-ssh" "$WTHD/scripts/recall"; for f in pytest python python3; do rm -f "$WTHD/scripts/pytest-shim/bin/$f"; ln -s ../pytest-shim.sh "$WTHD/scripts/pytest-shim/bin/$f"; done
HDEST="$T/home/gt-remote/mirror/hq-1"; hreset; date > "$NODEFLAG"; find "$HDEST" -mindepth 1 -delete 2>/dev/null; mkdir -p "$HDEST/.gc"; echo old > "$HDEST/.gc/old.jsonl"
STUB_RSYNC_REAL=1 "$RUN" --repo hq --dir "$WTHD" -- scripts/a.selftest.sh >"$T/out" 2>"$T/err"; rc=$?; expect "hq rsync real: a bateria roda no nó" 0 "$rc"
got=""; for f in $HQLEAK; do [ -e "$HDEST/$f" ] && got="$got $f"; done; eq "hq: NADA de dado/segredo/pasta de runtime plantado chegou ao nó (lista vazia)" "" "${got# }"
for f in $HQOK; do n=$((n+1)); if [ -f "$HDEST/$f" ]; then echo "ok   hq chegou (código/doc/config): $f"; else echo "FAIL hq não chegou: $f"; fails=$((fails+1)); fi; done
[ ! -e "$HDEST/.gc/old.jsonl" ] && ok "hq: --delete-excluded limpa o que uma cópia antiga deixou (.gc/old.jsonl)" || bad "hq: o destino manteve .gc/old.jsonl"
[ -x "$HDEST/scripts/gc-session-ssh" ] && [ -x "$HDEST/scripts/recall" ] && ok "hq: os executáveis sem extensão chegam EXECUTÁVEIS" || bad "hq: gc-session-ssh/recall chegaram sem o bit de execução"
[ -L "$HDEST/scripts/pytest-shim/bin/pytest" ] && [ "$(readlink "$HDEST/scripts/pytest-shim/bin/pytest")" = ../pytest-shim.sh ] && [ -f "$HDEST/scripts/pytest-shim/bin/pytest" ] && ok "hq: pytest-shim/bin/pytest chega como SYMLINK para ../pytest-shim.sh, e o alvo existe no espelho" || bad "hq: pytest-shim/bin/pytest não chegou como symlink com alvo"
# controle (ga-q9vyyn): o filtro SEM a Seção 4 — o que valia antes do conserto — NÃO leva o executável sem extensão. Prova que a chegada acima vem da Seção 4 e não de outra regra do filtro.
grep -v -F -x -e '+ /scripts/gc-session-ssh' -e '+ /scripts/recall' -e '+ /scripts/pytest-shim/bin/pytest' -e '+ /scripts/pytest-shim/bin/python' -e '+ /scripts/pytest-shim/bin/python3' "$HERE/hetzner-rsync-filter.hq.txt" > "$T/hq-filter-sem-secao4"
hreset; date > "$NODEFLAG"; find "$HDEST" -mindepth 1 -delete 2>/dev/null; HETZNER_RSYNC_FILTER="$T/hq-filter-sem-secao4" STUB_RSYNC_REAL=1 "$RUN" --repo hq --dir "$WTHD" -- scripts/a.selftest.sh >/dev/null 2>&1
got=""; for f in scripts/gc-session-ssh scripts/recall scripts/pytest-shim/bin/pytest scripts/pytest-shim/bin/python scripts/pytest-shim/bin/python3; do [ -e "$HDEST/$f" ] || [ -L "$HDEST/$f" ] || got="$got $f"; done; n=$((n+1)); if [ "$(printf '%s' "$got" | wc -w | tr -d ' ')" = 5 ]; then echo "ok   controle hq: SEM a Seção 4 os 5 executáveis sem extensão ficam no mini (o defeito do ga-q9vyyn)"; else echo "FAIL controle hq: sem a Seção 4 deviam faltar 5, faltaram:$got"; fails=$((fails+1)); fi
# controle negativo: sem o filtro, a árvore vaza (o teste enxerga o defeito)
hreset; date > "$NODEFLAG"; find "$HDEST" -mindepth 1 -delete 2>/dev/null; STUB_RSYNC_REAL=1 "$MUT/mut-nofilter.sh" --repo hq --dir "$WTHD" -- scripts/a.selftest.sh >/dev/null 2>&1
got=""; for f in $HQLEAK; do [ -e "$HDEST/$f" ] && got="$got $f"; done; n=$((n+1)); if [ -n "$got" ]; then echo "ok   controle hq: o mutante sem filtro VAZA ($(printf '%s' "$got" | wc -w | tr -d ' ') plantados)"; else echo "FAIL controle hq: o mutante sem filtro não vazou — o teste não enxerga o defeito"; fails=$((fails+1)); fi
# DETECTOR (ga-q9vyyn): todo arquivo RASTREADO sem extensão nas pastas que o filtro do hq libera tem de passar pelo filtro REAL — senão o próximo executável sem extensão repete o gc-session-ssh (a bateria
# dele reprova no nó por falta de arquivo, e o chamador lê FAIL falso). A lista vem de `git ls-files`, não de uma cópia mantida à mão. Dispensa explícita abaixo, com o motivo; a dispensa também é conferida
# (se o arquivo dispensado passar a sair, ela está velha e o teste reprova). git que falha é FALHA ALTA, nunca "nenhum arquivo": um teste que passa vazio não prova nada.
HQROOT=$(cd "$HERE/.." && pwd)
HQ_NOEXT_WITHHELD="scripts/rea-patches/PIN"   # versão fixada do REA, não executável; é lida por rea-patch.sh, e o único selftest que a exercita (rea-patch.selftest.sh) está na lista mac-only, então nunca vai ao nó
if tracked=$(git -C "$HQROOT" -c core.quotepath=false ls-files -- scripts packs docs agents formulas orders commands skills config 2>"$T/git-ls.err"); then
  noext=$(printf '%s\n' "$tracked" | awk -F/ 'NF && $NF !~ /\./')
  DTREE="$T/drift-tree"; DDEST="$T/drift-dest"; mkdir -p "$DTREE" "$DDEST"
  while IFS= read -r f; do [ -n "$f" ] || continue; mkdir -p "$DTREE/$(dirname "$f")"; : > "$DTREE/$f"; done <<<"$noext"
  hq_noext_missing() { # <filtro>: imprime, separados por espaço, os rastreados sem extensão (fora da dispensa) que ESSE filtro não deixa passar; "RSYNC-FALHOU" se o rsync não rodou
    local flt="$1" f sent
    sent=$("$T/bin/rsync" -a -n --out-format='%n' --filter=". $flt" "$DTREE"/ "$DDEST"/ 2>/dev/null) || { printf 'RSYNC-FALHOU'; return 0; }
    while IFS= read -r f; do [ -n "$f" ] || continue; case " $HQ_NOEXT_WITHHELD " in *" $f "*) continue ;; esac; printf '%s\n' "$sent" | grep -qxF -- "$f" || printf '%s ' "$f"; done <<<"$noext"
  }
  nn=$(printf '%s\n' "$noext" | grep -c .)
  [ "$nn" -ge 5 ] && ok "detector hq: git ls-files enxerga $nn arquivos sem extensão (>= 5, os executáveis conhecidos; lista vazia não prova nada)" || bad "detector hq: git ls-files devolveu só $nn arquivos sem extensão — o detector estaria passando vazio"
  eq "detector hq: nenhum arquivo rastreado sem extensão fica de fora do filtro REAL (faltando → ponha '+ /caminho' na Seção 4 de hetzner-rsync-filter.hq.txt, ou dispense em HQ_NOEXT_WITHHELD com o motivo)" "" "$(hq_noext_missing "$HERE/hetzner-rsync-filter.hq.txt" | sed 's/ $//')"
  # controle: com o filtro SEM a Seção 4 o detector TEM de acusar os 5 executáveis — é o que prova que ele enxerga o defeito
  eq "controle do detector: sem a Seção 4 ele acusa os 5 executáveis" 5 "$(hq_noext_missing "$T/hq-filter-sem-secao4" | wc -w | tr -d ' ')"
  for f in $HQ_NOEXT_WITHHELD; do
    if "$T/bin/rsync" -a -n --out-format='%n' --filter=". $HERE/hetzner-rsync-filter.hq.txt" "$DTREE"/ "$DDEST"/ 2>/dev/null | grep -qxF -- "$f"; then bad "detector hq: '$f' está dispensado mas o filtro agora o leva — tire-o de HQ_NOEXT_WITHHELD"; else ok "detector hq: a dispensa '$f' continua verdadeira (o filtro não o leva)"; fi
  done
else bad "detector hq: git ls-files falhou em $HQROOT ($(head -c 200 "$T/git-ls.err" 2>/dev/null)) — sem a lista não há como conferir o filtro"; fi
hreset
}

if [ -n "${MBP_SELFTEST_ONLY:-}" ]; then
  date > "$FLAG"
  case "$MBP_SELFTEST_ONLY" in
    presenca) presenca_cases; neg_presenca ;;
    chave) chave_cases ;;
    node) node_cases ;;
    host) host_cases ;;
    semeadura) xdist_on; node_seed_cases ;;
    *) echo "MBP_SELFTEST_ONLY desconhecido: $MBP_SELFTEST_ONLY" >&2; exit 2 ;;
  esac
  echo "---"; echo "$((n-fails))/$n ok"
  [ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
  exit 0
fi

# 1 off
reset; rm -f "$FLAG"; rc=$(run -- tests/test_x.py); expect "off" 99 "$rc"; hasnt "off não chama ssh" "$STUB_LOG" 'PREFLIGHT'
date > "$FLAG"
# 2 inalcançável
reset; rc=$(STUB_UNREACHABLE=1 run -- tests/test_x.py); expect "inalcançável" 98 "$rc"
has "inalcançável vai ao log com motivo" "$J" '"reason":"inalcancavel".*"avail_mb":null'
# 3 RAM baixa
reset; rc=$(STUB_AVAIL_MB=1000 run -- tests/test_x.py); expect "RAM baixa" 98 "$rc"; has "msg RAM" "$T/err" 'sem RAM'
hasnt "RAM baixa não pega slot" "$STUB_LOG" 'SLOT_ACQUIRE'
has "RAM baixa vai ao log com motivo e número" "$J" '"reason":"ram".*"avail_mb":1000'
hasnt "recusa gravada no log não emite AVISO" "$T/err" 'AVISO'
# 3b a recusa que NÃO coube no log (aqui o caminho do log é um diretório) é AVISADA: a contagem de 72 h é a medida de aceitação,
#    e sem o aviso "recusas: nenhuma" mentiria — o rc segue 98 (o chamador roda local do mesmo jeito)
reset; mkdir -p "$J"; rc=$(STUB_AVAIL_MB=1000 run -- tests/test_x.py); expect "recusa com log não gravável: rc segue 98" 98 "$rc"
has "recusa que não coube no log é avisada com o motivo" "$T/err" "AVISO: recusa 'ram' NÃO gravada"; rmdir "$J"
# 5 bateria baixa sem tomada
reset; rc=$(STUB_POWER=battery STUB_BATT=30 run -- tests/test_x.py); expect "bateria baixa" 98 "$rc"; has "bateria vai ao log" "$J" '"reason":"bateria"'
# 5b bateria ok sem tomada passa
reset; rc=$(STUB_POWER=battery STUB_BATT=80 run -- tests/test_x.py); expect "bateria 80% sem tomada passa" 0 "$rc"
reset; eq "bateria 40% (limite) recusa" "98:bateria" "$(STUB_POWER=battery STUB_BATT=40 outcome "$RUN")"
reset; eq "bateria 41% passa" "0:-" "$(STUB_POWER=battery STUB_BATT=41 outcome "$RUN")"
# 5c ILEGÍVEL ≠ bateria baixa: pmset falhou / formato inesperado → "ilegivel:power" (antes virava "battery" e o log dizia "bateria");
#    na bateria sem a carga legível → "ilegivel:batt"; na tomada a carga ilegível não decide
reset; eq "pmset falhou" "98:ilegivel:power" "$(STUB_PMSET_FAIL=1 outcome "$RUN")"; has "fonte ilegível não vira 'bateria' no log" "$J" '"reason":"ilegivel:power"'
reset; eq "pmset: formato inesperado" "98:ilegivel:power" "$(STUB_PMSET_RAW='something else' outcome "$RUN")"
reset; eq "na bateria sem a carga legível" "98:ilegivel:batt" "$(STUB_PMSET_RAW="Now drawing from 'Battery Power'" outcome "$RUN")"
reset; eq "na tomada a carga ilegível não decide" "0:-" "$(STUB_PMSET_RAW="Now drawing from 'AC Power'" outcome "$RUN")"
# 6 slots cheios
reset; rc=$(STUB_SLOTS=full run -- tests/test_x.py); expect "slots cheios" 96 "$rc"; hasnt "cheios não roda" "$STUB_LOG" '^RUN$'
# 7 slot de dono morto é reaped e roda
reset; rc=$(STUB_SLOTS=dead run -- tests/test_x.py); expect "dono morto reaped" 0 "$rc"; has "chamou SLOT_REAP" "$STUB_LOG" 'SLOT_REAP'
# 8 propaga rc e loga
reset; rc=$(STUB_RUN_RC=7 run -- tests/test_x.py -q); expect "rc remoto propagado" 7 "$rc"
has "jsonl tem rc 7" "$J" '"rc":7'
# 9 libera slot ao fim
has "SLOT_RELEASE ao fim" "$STUB_LOG" 'SLOT_RELEASE'
# 10 ssh 255 no meio
reset; rc=$(STUB_RUN_RC=255 run -- tests/test_x.py); expect "ssh caiu no meio" 98 "$rc"; has "libera mesmo assim" "$STUB_LOG" 'SLOT_RELEASE'
# 11 nota de shared/data
reset; rc=$(STUB_RUN_RC=1 STUB_RUN_OUT="FileNotFoundError: shared/data/x.db" run -- tests/test_x.py); expect "falha com shared/data" 1 "$rc"; has "nota shared/data" "$T/err" 'NOTE: shared/data'
# 12 sucesso: rsync do worktree com exclusões e sem --delete-excluded
reset; rc=$(run -- tests/test_x.py); expect "sucesso" 0 "$rc"; has "rsync exclui .git" "$STUB_LOG" 'RSYNC:.*--exclude \.git'; hasnt "não apaga excluídos" "$STUB_LOG" 'delete-excluded'
has "stdout do remoto chega" "$T/out" 'stub-run-ok'
hasnt "execução saudável não loga recusa" "$J" '"mode":"preflight"'
# 13 uso errado
reset; rc=$("$RUN" --repo wa --dir "$T/wt" >"$T/out" 2>"$T/err"; echo $?); expect "sem args do pytest" 97 "$rc"
rc=$("$RUN" --repo xx --dir "$T/wt" -- a >"$T/out" 2>"$T/err"; echo $?); expect "repo inválido" 97 "$rc"
# 14 base ausente
reset; rc=$(STUB_NOBASE=1 run -- tests/test_x.py); expect "base ausente" 97 "$rc"; has "manda rodar --seed" "$T/err" '\-\-seed'; has "libera slot em 97" "$STUB_LOG" 'SLOT_RELEASE'
# 15 exec: push + pull + limpeza do scratch
reset; echo data > "$T/in.bin"; "$RUN" --exec --push "$T/in.bin" --pull "out.json:$T/" -- rea --version >"$T/out" 2>"$T/err"; rc=$?; expect "exec ok" 0 "$rc"
has "exec empurra" "$STUB_LOG" 'RSYNC:.*in\.bin'; has "exec puxa" "$STUB_LOG" 'RSYNC:.*out\.json'; has "exec limpa scratch" "$STUB_LOG" 'DIRECT:.*find .* -mindepth 1 -delete'
reset; STUB_RUN_RC=3 "$RUN" --exec -- false >"$T/out" 2>"$T/err"; r=$?; expect "exec propaga rc" 3 "$r"
# 16 --keep não limpa
reset; "$RUN" --exec --keep -- true >"$T/out" 2>"$T/err"; hasnt "--keep preserva scratch" "$STUB_LOG" 'DIRECT:.*-delete'

# ---- preflight de saúde (ga-9e2rjh) -------------------------------------------------------------------------------
# 17 o DEFEITO: swap alto mas PARADO não recusa (medido em 11/10: 5.248 MB recusou com 3,8 GB de RAM disponível)
reset; rc=$(STUB_SWAP_MB=5248 STUB_AVAIL_MB=3900 run -- tests/test_x.py); expect "swap 5248 MB parado com 3,9 GB livres PASSA" 0 "$rc"
hasnt "e não registra recusa" "$J" '"mode":"preflight"'
reset; rc=$(STUB_SWAP_MB=7900 run -- tests/test_x.py); expect "swap 7900 MB parado passa (abaixo do teto)" 0 "$rc"
# 18 teto absoluto do swap (padrão 8192, configurável)
reset; eq "swap 9000 MB (acima do teto) recusa" "98:swap_teto" "$(STUB_SWAP_MB=9000 outcome "$RUN")"; has "teto no log com o número" "$J" '"swap_mb":9000'
reset; eq "teto é configurável (MBP_MAX_SWAP_MB=4000)" "98:swap_teto" "$(MBP_MAX_SWAP_MB=4000 STUB_SWAP_MB=6000 outcome "$RUN")"
# 19 swap CRESCENDO recusa (o MBP está trocando memória agora); fronteira 128 passa, 129 recusa; encolher passa
reset; eq "swap 5000→5400 recusa" "98:swap_cresce" "$(STUB_SWAP_MB=5000 STUB_SWAP2_MB=5400 outcome "$RUN")"
has "crescimento no log" "$J" '"swap_delta_mb":400'
reset; STUB_SWAP_MB=5000 STUB_SWAP2_MB=5400 run -- tests/test_x.py >/dev/null; has "msg: swap cresceu 400 MB em 2s" "$T/err" 'swap cresceu 400 MB em 2s'
reset; eq "swap +128 MB (limite) passa" "0:-" "$(STUB_SWAP_MB=5000 STUB_SWAP2_MB=5128 outcome "$RUN")"
reset; eq "swap +129 MB recusa" "98:swap_cresce" "$(STUB_SWAP_MB=5000 STUB_SWAP2_MB=5129 outcome "$RUN")"
reset; eq "swap encolhendo (delta negativo) passa" "0:-" "$(STUB_SWAP_MB=5000 STUB_SWAP2_MB=4000 outcome "$RUN")"
reset; eq "crescimento é configurável (MBP_MAX_SWAP_GROWTH_MB=500)" "0:-" "$(MBP_MAX_SWAP_GROWTH_MB=500 STUB_SWAP_MB=5000 STUB_SWAP2_MB=5400 outcome "$RUN")"
# 20 janela da amostra: padrão 2 s, configurável, inválido volta ao padrão
reset; run -- tests/test_x.py >/dev/null; has "janela padrão 2 s" "$STUB_LOG" '^SLEEP:2$'
reset; MBP_SWAP_SAMPLE_S=5 run -- tests/test_x.py >/dev/null; has "janela configurável (5 s)" "$STUB_LOG" '^SLEEP:5$'
reset; MBP_SWAP_SAMPLE_S=abc run -- tests/test_x.py >/dev/null; has "janela inválida volta a 2 s" "$STUB_LOG" '^SLEEP:2$'
# 21 pressão de memória do kernel: 1 normal passa; 2 aviso e 4 crítico recusam; limite configurável
reset; eq "pressão 1 (normal) passa" "0:-" "$(STUB_PRESSURE=1 outcome "$RUN")"
reset; eq "pressão 2 (aviso) recusa" "98:pressao" "$(STUB_PRESSURE=2 outcome "$RUN")"; has "pressão no log" "$J" '"pressure":2'
reset; eq "pressão 4 (crítico) recusa" "98:pressao" "$(STUB_PRESSURE=4 outcome "$RUN")"
reset; eq "pressão 2 passa com MBP_MAX_PRESSURE_LEVEL=2" "0:-" "$(MBP_MAX_PRESSURE_LEVEL=2 STUB_PRESSURE=2 outcome "$RUN")"
reset; eq "pressão 4 recusa mesmo com MBP_MAX_PRESSURE_LEVEL=2" "98:pressao" "$(MBP_MAX_PRESSURE_LEVEL=2 STUB_PRESSURE=4 outcome "$RUN")"
# 22 ILEGÍVEL ≠ baixo: sysctl falhou, texto, valor fora de {1,2,4} → recusa com motivo próprio e null no log (nunca "1"/"0")
reset; eq "pressão: sysctl falhou" "98:ilegivel:pressure" "$(STUB_PRESSURE_FAIL=1 outcome "$RUN")"; has "pressão ilegível vai como null" "$J" '"pressure":null'
reset; eq "pressão: texto" "98:ilegivel:pressure" "$(STUB_PRESSURE=abc outcome "$RUN")"
reset; eq "pressão: valor fora de {1,2,4}" "98:ilegivel:pressure" "$(STUB_PRESSURE=3 outcome "$RUN")"
reset; eq "swap: lixo na 1ª e 2ª leitura" "98:ilegivel:swap_delta" "$(STUB_SWAP_RAW='vm.swapusage: unknown oid' outcome "$RUN")"; has "swap ilegível vai como null" "$J" '"swap_mb":null.*"swap_delta_mb":null'
reset; eq "swap: só a 2ª leitura ilegível" "98:ilegivel:swap_delta" "$(STUB_SWAP_MB=5000 STUB_SWAP2_RAW=garbage outcome "$RUN")"
reset; eq "swap: unidade desconhecida (K) não vira 0" "98:ilegivel:swap_delta" "$(STUB_SWAP_RAW='total = 8192.00K  used = 12.00K  free = 1.00K' outcome "$RUN")"
reset; eq "RAM: linha 'Pages speculative' sumiu" "98:ilegivel:avail" "$(STUB_VM_DROP='Pages speculative' outcome "$RUN")"; has "RAM ilegível vai como null" "$J" '"avail_mb":null'
reset; eq "RAM: cabeçalho do page size sumiu" "98:ilegivel:avail" "$(STUB_VM_DROP='page size' outcome "$RUN")"
reset; eq "RAM: vm_stat falhou" "98:ilegivel:avail" "$(STUB_VM_FAIL=1 outcome "$RUN")"
# lado local isolado (saída crua do remoto): campo vazio nunca é lido como número
OK_PF='avail_mb=8000\nswap_mb=5000\nswap_delta_mb=0\npressure=1\npower=ac\nbatt=90'
reset; eq "saída crua saudável passa" "0:-" "$(STUB_PF_RAW="$OK_PF" outcome "$RUN")"
reset; eq "crua: swap_delta vazio" "98:ilegivel:swap_delta" "$(STUB_PF_RAW='avail_mb=8000\nswap_mb=5000\nswap_delta_mb=\npressure=1\npower=ac\nbatt=90' outcome "$RUN")"
reset; eq "crua: swap_mb vazio com delta ok" "98:ilegivel:swap" "$(STUB_PF_RAW='avail_mb=8000\nswap_mb=\nswap_delta_mb=0\npressure=1\npower=ac\nbatt=90' outcome "$RUN")"
reset; eq "crua: avail_mb vazio" "98:ilegivel:avail" "$(STUB_PF_RAW='avail_mb=\nswap_mb=5000\nswap_delta_mb=0\npressure=1\npower=ac\nbatt=90' outcome "$RUN")"
reset; eq "crua: pressure ausente" "98:ilegivel:pressure" "$(STUB_PF_RAW='avail_mb=8000\nswap_mb=5000\nswap_delta_mb=0\npower=ac\nbatt=90' outcome "$RUN")"
# 23 informativos nunca decidem: memory_pressure falhar não recusa; o compressor alto de repouso também não
reset; rc=$(STUB_MP_FAIL=1 run -- tests/test_x.py); expect "memory_pressure falhou: só informativo, não recusa" 0 "$rc"
reset; rc=$(STUB_COMP_PAGES=900000 run -- tests/test_x.py); expect "compressor enorme: só informativo, não recusa" 0 "$rc"
# 24 --check mostra os números lidos (e nunca grava recusa; --seed idem)
reset; rc=$(chk); expect "--check saudável" 0 "$rc"
has "check: avail_mb" "$T/out" '^avail_mb=8000$'; has "check: swap_mb" "$T/out" '^swap_mb=1000$'; has "check: swap_delta_mb" "$T/out" '^swap_delta_mb=0$'
has "check: pressure" "$T/out" '^pressure=1$'; has "check: mem_free_pct" "$T/out" '^mem_free_pct=54$'; has "check: compressed_mb" "$T/out" '^compressed_mb=5268$'
reset; rc=$(STUB_PAGE_SIZE=4096 chk); expect "--check com page size 4096" 0 "$rc"; has "avail usa o page size do cabeçalho" "$T/out" '^avail_mb=8000$'
reset; rc=$(STUB_SWAP_RAW='total = 8192.00M  used = 1.50G  free = 6.50G  (encrypted)' chk); expect "--check com swap em G" 0 "$rc"; has "'1.50G' lido como 1536 MB" "$T/out" '^swap_mb=1536$'
reset; rc=$(STUB_AVAIL_MB=1000 chk); expect "--check recusa por RAM" 98 "$rc"; n=$((n+1)); if [ ! -e "$J" ]; then echo "ok   --check não grava recusa no log"; else echo "FAIL --check gravou no log"; fails=$((fails+1)); fi
reset; rc=$(STUB_AVAIL_MB=1000 "$RUN" --seed wa >"$T/out" 2>"$T/err"; echo $?); expect "--seed recusa por RAM" 98 "$rc"
n=$((n+1)); if [ ! -e "$J" ]; then echo "ok   --seed não grava recusa no log"; else echo "FAIL --seed gravou no log"; fails=$((fails+1)); fi

# 25 a contagem de 72 h do mbp-offload.sh (é por ela que se mede "recusa indevida"): três estados que não se confundem, e linha
#    ilegível AVISADA, nunca omitida — senão uma recusa truncada deixava "recusas: nenhuma" mentir
OFFLOAD="${MBP_OFFLOAD_UNDER_TEST:-$HERE/mbp-offload.sh}"
# A MESMA jq NÃO lê igual em toda parte (ga-9e2rjh, gate-fix 1): "A + B as $x | ..." é "(A+B) as $x" no jq 1.8.1 (homebrew) e
# "A + (B as $x | ...)" no 1.7.1-apple do /usr/bin — o que o launchd, de PATH mínimo, resolve. Os casos abaixo rodam portanto UMA
# VEZ por jq conhecido, cada um FIXADO por caminho absoluto na frente do PATH (JQPIN), além do jq que o PATH do ambiente der.
# Um jq que não existe neste host é AVISADO ("SKIP"), nunca contado como ok: cobertura que sumiu tem de aparecer.
JQPIN=""
cnt() { PATH="${JQPIN:+$JQPIN:}$PATH" bash "$OFFLOAD" counts 2>&1; }
t_now=$(date -u +%Y-%m-%dT%H:%M:%SZ); t_old=$(date -u -v-5d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '5 days ago' +%Y-%m-%dT%H:%M:%SZ)
l_run() { printf '{"ts":"%s","repo":"wa","mode":"pytest","slot":"1","rc":0,"secs":4,"nargs":2}\n' "$t_now"; }
l_ref() { printf '{"ts":"%s","repo":"-","mode":"preflight","slot":"-","rc":98,"secs":0,"nargs":0,"reason":"%s"}\n' "${2:-$t_now}" "$1"; }
counts_cases() { # rótulo do jq sob teste (vai no nome de cada caso)
local L="$1"
reset; eq "contagem[$L]: sem log" "sem log ainda" "$(cnt)"
reset; mkdir -p "$(dirname "$J")"; : > "$J"; eq "contagem[$L]: log vazio é 0, não ilegível" "0 execuções; recusas: nenhuma" "$(cnt)"
reset; mkdir -p "$(dirname "$J")"; { l_run; l_run; l_ref ram; l_ref ram; l_ref swap_cresce; l_ref ram "$t_old"; } > "$J"
eq "contagem[$L]: por motivo, e recusa de 5 dias atrás fica fora" "2 execuções; recusas: ram=2 swap_cresce=1" "$(cnt)"
reset; mkdir -p "$(dirname "$J")"; l_run > "$J"; eq "contagem[$L]: lido e sem recusa" "1 execuções; recusas: nenhuma" "$(cnt)"
reset; mkdir -p "$(dirname "$J")"; { l_run; l_ref ram; printf '{"ts":"%s","repo":"-","mode":"preflight","slot":"-","rc":98,"secs":0,"nargs":0,"reason":"ram","host":"hetzner"}\n{"ts":"%s","repo":"-","mode":"preflight","slot":"-","rc":98,"secs":0,"nargs":0,"reason":"ram","host":"hetzner"}\n{"ts":"%s","repo":"-","mode":"preflight","slot":"-","rc":98,"secs":0,"nargs":0,"reason":"inalcancavel","host":"hetzner"}\n' "$t_now" "$t_now" "$t_now"; } > "$J"
eq "contagem[$L]: recusa do nó leva o prefixo hetzner: (linha sem host = MBP)" "1 execuções; recusas: hetzner:inalcancavel=1 hetzner:ram=2 ram=1" "$(cnt)"
reset; mkdir -p "$(dirname "$J")"; { l_run; l_ref ram; printf '{"ts":"%s","repo":"-","mode":"pref' "$t_now"; echo; } > "$J"
eq "contagem[$L]: linha de recusa truncada é avisada e o resto conta" "1 execuções; recusas: ram=1; 1 linha(s) ilegível(is) no log (não contadas)" "$(cnt)"
reset; mkdir -p "$(dirname "$J")"; { l_run; printf '{"ts":"%s","mode":"preflight","rc":98}\n' "$t_now"; } > "$J"
eq "contagem[$L]: recusa sem motivo não vira 'nenhuma' em silêncio" "1 execuções; recusas: nenhuma; 1 linha(s) ilegível(is) no log (não contadas)" "$(cnt)"
reset; mkdir -p "$(dirname "$J")"; { l_run; printf '{"ts":"ontem","mode":"preflight","rc":98,"reason":"ram"}\n'; } > "$J"
eq "contagem[$L]: ts que não vira data é avisado" "1 execuções; recusas: nenhuma; 1 linha(s) ilegível(is) no log (não contadas)" "$(cnt)"
reset; mkdir -p "$(dirname "$J")"; { l_run; echo null; echo 42; } > "$J"
eq "contagem[$L]: linha que não é objeto é avisada" "1 execuções; recusas: nenhuma; 2 linha(s) ilegível(is) no log (não contadas)" "$(cnt)"
reset; mkdir -p "$(dirname "$J")"; { l_run; printf '{"ts":"%s","repo":"x"}\n' "$t_now"; printf '{"ts":"%s","mode":7}\n' "$t_now"; } > "$J"
eq "contagem[$L]: linha com ts mas sem 'mode' em texto é avisada, não vira execução" "1 execuções; recusas: nenhuma; 2 linha(s) ilegível(is) no log (não contadas)" "$(cnt)"
# só hetzner|mbp (ou sem o campo = mbp) são hosts conhecidos: o resto é linha que não dá para classificar, avisada, não uma execução/recusa "do MBP"
reset; mkdir -p "$(dirname "$J")"; { l_run; printf '{"ts":"%s","repo":"wa","mode":"pytest","slot":"1","rc":0,"secs":4,"nargs":2,"host":"hetzner2"}\n' "$t_now"; } > "$J"
eq "contagem[$L]: execução com host desconhecido é avisada, não vira execução" "1 execuções; recusas: nenhuma; 1 linha(s) ilegível(is) no log (não contadas)" "$(cnt)"
reset; mkdir -p "$(dirname "$J")"; { l_run; printf '{"ts":"%s","repo":"-","mode":"preflight","slot":"-","rc":98,"secs":0,"nargs":0,"reason":"ram","host":"hetzner2"}\n' "$t_now"; } > "$J"
eq "contagem[$L]: recusa com host desconhecido é avisada, não vira recusa do MBP" "1 execuções; recusas: nenhuma; 1 linha(s) ilegível(is) no log (não contadas)" "$(cnt)"
reset; mkdir -p "$(dirname "$J")"; { l_run; printf '{"ts":"%s","repo":"wa","mode":"pytest","slot":"1","rc":0,"secs":4,"nargs":2,"host":"hetzner2"}\n' "$t_old"; } > "$J"
eq "contagem[$L]: host desconhecido de 5 dias atrás fica fora da janela de 72 h" "1 execuções; recusas: nenhuma" "$(cnt)"
}
JQPIN=""; counts_cases "jq do PATH"
for cand in /usr/bin/jq /opt/homebrew/bin/jq; do
  if [ -x "$cand" ]; then
    d="$T/jqpin$(printf '%s' "$cand" | tr '/' '_')"; mkdir -p "$d"; ln -sf "$cand" "$d/jq"
    JQPIN="$d"; counts_cases "$cand $("$cand" --version 2>&1)"
  else
    echo "SKIP contagem sob $cand: não existe neste host (esse jq NÃO foi exercitado)"
  fi
done
JQPIN=""
reset; mkdir -p "$(dirname "$J")"; l_run > "$J"; chmod 000 "$J"; eq "contagem: log sem permissão de leitura é 'ilegível', nunca 'nenhuma'" "ilegível" "$(cnt)"; chmod 644 "$J"
reset; mkdir -p "$(dirname "$J")" "$T/nojq"; l_run > "$J"; ln -sf "$(command -v date)" "$T/nojq/date"; ln -sf "$(command -v dirname)" "$T/nojq/dirname"
eq "contagem: jq ausente é 'ilegível', nunca 'nenhuma'" "ilegível" "$(PATH="$T/nojq" /bin/bash "$OFFLOAD" counts 2>&1)"

# controle negativo: sem a checagem de flag o caso "off" PASSARIA a rodar — prova que o teste 1 enxerga o defeito
reset; rm -f "$FLAG"; neg=$(sed 's/^[[:space:]]*\[ -f "\$FLAG" \] || {.*$/true/' "$RUN" > "$T/mut.sh"; chmod +x "$T/mut.sh"; "$T/mut.sh" --repo wa --dir "$T/wt" -- tests/test_x.py >/dev/null 2>&1; echo $?)
n=$((n+1)); if [ "$neg" != 99 ]; then echo "ok   controle negativo (mutante sem a trava não sai 99: rc=$neg)"; else echo "FAIL controle negativo: o mutante ainda saiu 99"; fails=$((fails+1)); fi
date > "$FLAG"

# controles negativos das portas do preflight: remove UMA porta (a linha marcada "# gate:<nome>") e exige que o mutante deixe de
# reproduzir o (rc, motivo) do script real no cenário que a porta guarda. Nas portas "ilegivel-*" o mutante ainda recusa (a
# comparação do número com vazio falha), mas com o motivo errado ("pressao", "swap_cresce"...): é exatamente o "ilegível virou
# baixo" que o log não pode contar como "baixo".
mutant() { # marcador esperado VAR=valor...  (o cenário que a porta guarda, como pares VAR=valor)
  local m="$1" want="$2" cnt real mut kv; shift 2
  cnt=$(grep -c "# gate:$m\$" "$RUN")
  eq "controle $m: uma única linha marcada '# gate:$m'" 1 "$cnt"; [ "$cnt" = 1 ] || return 0
  sed "/# gate:$m\$/s/.*/true/" "$RUN" > "$T/mut.sh"; chmod +x "$T/mut.sh"
  reset; real=$( for kv in "$@"; do export "$kv"; done; outcome "$RUN" )
  reset; mut=$( for kv in "$@"; do export "$kv"; done; outcome "$T/mut.sh" )
  eq "controle $m: o script real dá '$want'" "$want" "$real"
  n=$((n+1)); if [ "$mut" != "$want" ]; then echo "ok   controle $m: o mutante sem a porta não reproduz ($mut)"; else echo "FAIL controle $m: o mutante ainda reproduz '$want'"; fails=$((fails+1)); fi
}
mutant ram            98:ram                  STUB_AVAIL_MB=1000
mutant ilegivel-avail 98:ilegivel:avail       STUB_VM_DROP='Pages speculative'
mutant ilegivel-pressao 98:ilegivel:pressure  STUB_PRESSURE_FAIL=1
mutant pressao        98:pressao              STUB_PRESSURE=2
mutant ilegivel-delta 98:ilegivel:swap_delta  STUB_SWAP_RAW=garbage
mutant cresce         98:swap_cresce          STUB_SWAP_MB=5000 STUB_SWAP2_MB=5400
mutant ilegivel-swap  98:ilegivel:swap        "STUB_PF_RAW=avail_mb=8000\nswap_mb=\nswap_delta_mb=0\npressure=1\npower=ac\nbatt=90"
mutant teto           98:swap_teto            STUB_SWAP_MB=9000
mutant ilegivel-power 98:ilegivel:power       STUB_PMSET_FAIL=1
mutant ilegivel-batt  98:ilegivel:batt        "STUB_PMSET_RAW=Now drawing from 'Battery Power'"

# MBP_SELFTEST_SKIP=presenca: pula a presença (o prod test antigo ga-9e2rjh tem o orçamento de 900 s da suíte antiga; a presença tem o seu em story-ga-77c1qg.*)
if [ "${MBP_SELFTEST_SKIP:-}" != presenca ]; then
  presenca_cases; neg_presenca
  chave_cases
fi
host_cases
node_cases
echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
