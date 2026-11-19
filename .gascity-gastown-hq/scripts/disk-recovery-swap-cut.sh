#!/bin/bash
# disk-recovery-swap-cut.sh (ga-yh41v0e, P0) — degrau de SWAP da escada de recuperação de disco do mini: corta memória quando o swap CRESCE, ANTES de o disco cair.
#
# ## Contents
#   Por que existe · O que faz · Ordem do corte · Nunca · Três estados · Pausa do Pilot · Retomada · Contrato com o maestro · Variáveis (teste) · Teste
#
# POR QUE EXISTE  16/11, a escada de disco (D2/D3/D3.5/D4) só reage ao DISCO e as 12 fatias da missão ga-1p1i5jr não bastaram duas vezes. 14:35: o swap saltou de 2,8 para 6 GB em ~5 min, o disco foi a 1 GB e o kernel
#   entrou em pânico (watchdogd sem resposta por 94 s). 19:20: o disco caiu de 7,7 para 4,9 GB (abaixo do piso de 5120 MB do Pilot) e o Mayor cortou logs à mão. Quem enche o disco nesses casos é o SWAP (ele mora no mesmo
#   volume do Dolt), e não havia degrau que cortasse memória: quando o disco chega a 5 GB a escada ainda espera 15–60 min (D2 900 s, D3 1800 s, D4 3600 s). Este degrau age pelo CRESCIMENTO do swap, com o disco ainda alto.
# O QUE FAZ       Toda rodada do maestro (120 s), ANTES dos degraus de disco e SEM olhar o livre: lê o swap em uso (sysctl vm.swapusage) e o histórico do amostrador de RAM (.gc/ram-owner-samples.jsonl, 1 registro/5 min).
#   Dispara se o swap cresceu >= SWC_GROW_MB (1536) na janela de GROW_WINDOW_S (300 s; base = o registro cuja idade é a mais próxima de 300 s, entre 150 s e 630 s: o amostrador roda a cada 300 s; o swap de agora é o do sysctl) OU se o swap em uso passou de ABS_MB (5120). Sem gatilho: rc 10, nada é lido além disso.
#   Com gatilho: colhe UMA amostra nova do amostrador (ram-owner-sampler.py, escreve no mesmo arquivo; o launchd dele roda a cada 300 s e a amostra de 2 min de idade que o degrau exige não existiria na maior parte do tempo),
#   lê quem são os maiores donos de RAM nela e corta NESTA ordem, parando no teto MAX_CUT (3) por rodada:
#     1) sessões de POOL/REVIEWER OCIOSAS (suspende com `gc session suspend`: o runtime para, a sessão e a conversa ficam; `gc session wake` volta);
#     2) PAUSA o spawn novo do Pilot (arquivo .gc/swap-spawn-pause com validade; o Pilot lê no começo da varredura, no mesmo ponto da pausa por pressão de RAM, e não despacha nada novo enquanto valer).
#   Depois de cortar espera SETTLE_S, lê o swap de novo e LOGA quem foi cortado e quanto de swap voltou (pode ser 0 ou negativo: o macOS devolve o swap devagar; o log diz o número lido, nunca "voltou" por suposição).
# ORDEM DO CORTE  (menos crítico primeiro) sessão de pool/reviewer ociosa, a de maior PEGADA primeiro (o MEM do `top`, que já inclui o comprimido e o RSS esconde; só quando o amostrador não leu o top vale o RSS, e o log diz qual base valeu); depois a pausa do spawn. O degrau NÃO sobe para nada mais crítico: se o swap segue subindo e não sobra candidato, sai 11 e o
#   maestro chama um humano (notify -p 4 + mail ao Mayor, no máximo 1 por hora) com a lista dos maiores donos de RAM e o que cada um é.
#   Candidata = TODAS: (a) dona de pegada (MEM do top; RSS se o top não foi lido) >= MIN_RSS_MB (em MB) na amostra nova, de tipo `session` (nunca daemon, nunca Dolt); (b) template na lista fixa POOL_TEMPLATES (wa-worker ps-worker gate-reviewer refino-gate-reviewer context-check-reviewer, as variantes -remote e as 2 kimi-worker-remote / kimi-worker-wa-remote, por nome exato; o roster real as tem);
#   (c) nenhum nome dela casa com a deny-list; (d) estado `active` e NÃO anexada (anexada = o Athos está olhando); (e) zero bead in_progress atribuído a ela, sob QUALQUER dos nomes que o roster dá (id, session_name, name, alias,
#   agent_name, template) no store do rig E no HQ (mesma regra do idle-crew-suspender: a bead de um worker pode estar sob o session_name); (f) a transcrição dela parada há >= IDLE_MIN (15) min
#   (~/.claude/projects/<slug do work_dir>/<session_key>.jsonl; sem a transcrição = não sei = não corta). Qualquer leitura que falha deixa a sessão quieta (o contrário de "ociosa").
# NUNCA           Dolt · daemon de WhatsApp (qualquer dono do tipo `daemon`: passe em andamento ou não, este degrau não os toca) · sessão de crew (*-wa *-ma *-ps *-lx, oracle*) · witness, mayor, deacon, control-dispatcher, boot ·
#   dogs (gastown.dog*, dog-remote*: quem roda a recuperação) · sessão anexada · sessão com bead in_progress · sessão com transcrição recente. Nenhum kill em processo de terceiro (só o TERM/KILL do cronômetro sobre o PRÓPRIO filho que estourou o prazo; sem `kill -9`, sem `pkill -f`, nada que toque Appium): só `gc session suspend` (o reconciler pode recusar se há trabalho em voo).
#   Os crews já têm o idle-crew-suspender (autorização do Athos de 14/11) e o crew-capacity-containment (EMERGENCY); este degrau não duplica nenhum dos dois.
# TRÊS ESTADOS    tem / não-tem / não-consegui-saber. AMOSTRADOR SEM LEITURA = arquivo ausente, ilegível, sem registro válido, parado há mais de SAMPLER_DEAD_S (900 s = 3 intervalos), ou sem amostra nova de <= SAMPLE_MAX_AGE_S (120 s)
#   depois de colher uma, ou com `sessions_lookup_failed` (os donos de sessão viram rótulo genérico) ou roster `gc session list` ilegível: o degrau NÃO corta às cegas, NÃO pausa o Pilot, sai 30 e o maestro avisa o Mayor
#   (notify -p 4 + mail, 1 por hora) e SEGUE a escada de disco. `vm.swapusage` ilegível não é 0: o degrau cai no swap da última amostra e diz isso; sem nenhum dos dois = 30. Relógio ilegível = 30.
#   SUSPEND NÃO CONFIRMADO é o terceiro estado do próprio corte: no caminho gerenciado `gc session suspend` só põe o hold e cutuca o reconciler, então rc 0 com a sessão ainda `active` (ou `?`/`gone`) 3 s depois pode ser atraso OU
#   falta de efeito. Não é FALHOU (nada de rc 20 nem "sem efeito"), não é CORTOU: entra no registro marcado `u`, conta à parte, e UMA releitura depois do SETTLE_S resolve (dormindo → CORTOU; ainda não → fica `u` e a linha diz).
#   FALHOU só com rc != 0 E a sessão ainda ativa. Imediatamente antes do suspend o estado, o `attached` e a transcrição são relidos (o Athos pode ter anexado durante as leituras de bd).
#   ARQUIVO DE ESTADO ilegível (existe e não leio), com valor inválido ou com linha que não entendo = "não sei", NÃO "sem estado": a nota `[ESTADO ...]` sai no log do GATILHO e na linha de stdout, e o arquivo antigo nunca é sobrescrito
#   às cegas: antes de gravar o novo ele é guardado como <estado>.ilegivel.<epoch> (rename, funciona sem ler; é onde fica o registro das sessões suspensas que a retomada, fatia 3, precisa); se nem o rename der, NÃO grava e diz (rc 20).
# PAUSA DO PILOT  .gc/swap-spawn-pause: 4 linhas `PAUSE` · epoch da gravação · epoch da validade · motivo. A validade é o freio: se este degrau morrer, a pausa vence sozinha em PAUSE_TTL_S (900 s) e o Pilot volta a despachar
#   (pausa vencida, ilegível ou com validade absurda — mais de 1 h à frente — NÃO pausa: fail-open VISÍVEL no log do Pilot, nunca um Pilot parado por um arquivo que ninguém renova). Enquanto o gatilho vale, cada rodada renova
#   (só quando restam menos de metade da validade). Gravada num temporário, trocada com mv e LIDA DE VOLTA (tentado ≠ gravado).
# RETOMADA        `--resume` (o maestro chama toda rodada, depois do --run): com o swap calmo (<= ABS_MB - HYST_MB e crescimento < GROW_MB/2, os dois LIDOS, e sem gatilho) por PAUSE_CALM_S (300 s) apaga a pausa; por CALM_S (900 s) religa (`gc session wake`)
#   as sessões que ESTE degrau suspendeu (registro em .gc/disk-recovery-swap-cut.state, inclusive as marcadas `u`: religar quem não dormiu é inerte), no máximo MAX_WAKE (2) por rodada. Só religa o que ele mesmo suspendeu. Leitura que falha
#   (amostrador cego/parado, estado ilegível ou com valor inválido) = não religa, não apaga a pausa (ela vence sozinha), não grava o estado: rc 30, nunca "calmo" por suposição. Perdeu o calmo (swap subiu) = zera a contagem.
# CONTRATO        `--run` (real) · `--dry-run` (lê tudo, diz o que faria; não colhe amostra nova, não suspende, não grava pausa, estado nem log) · `--resume`. stdout = UMA linha ASCII (o maestro filtra para imprimíveis) e NADA
#   antes dela; o detalhe vai para $LOG. Saída 0 = agiu (suspendeu, pediu suspend ainda sem confirmação e/ou pausou) · 10 = nada a fazer (sem gatilho, carência, pausa vigente) · 11 = gatilho ativo e NÃO há candidata permitida (pausa posta/mantida; precisa de humano) ·
#   20 = falhou (suspend com rc != 0 e a sessão ainda ativa, pausa que não gravou, wake que falhou, pausa que não apagou) · 30 = não consegui ler (não cortei, não pausei) · 2 = uso. Falha e sucesso na mesma rodada = 20 (a linha diz os dois).
#   Carência: depois de uma rodada que CORTOU (ou pediu suspend ainda sem confirmação), COOLDOWN_S (300 s = a janela) sem cortar de novo, a não ser que o swap tenha voltado a subir >= GROW_MB/2 desde o corte (a base do crescimento ainda enxerga o salto de ANTES do corte).
#   Rodada em que TODO suspend falhou (rc 20, nada mudou) NÃO arma a carência nem grava estado: a rodada seguinte tenta suspender de novo.
# VARIÁVEIS (teste) DR_CITY · DR_OFF_FILE · DR_NOW_FILE · DR_SWAP_MB_FILE (os do maestro) · DR_GC_BIN · DR_SWC_LOG · DR_SWC_LOCK · DR_SWC_STATE · DR_SWC_PAUSE_FILE · DR_SWC_SAMPLES (o JSONL) · DR_SWC_SAMPLER_CMD (no lugar de
#   `python3 ram-owner-sampler.py`) · DR_SWC_SESSIONS_FILE (JSON no lugar de `gc session list --json`) · DR_SWC_BD_BIN · DR_SWC_PROJECTS_DIR · DR_SWC_<NOME> numérico: GROW_MB GROW_WINDOW_S GROW_SLACK_S ABS_MB HYST_MB
#   SAMPLE_MAX_AGE_S SAMPLER_DEAD_S IDLE_MIN MAX_CUT MAX_WAKE MIN_RSS_MB SETTLE_S VERIFY_S COOLDOWN_S PAUSE_TTL_S PAUSE_CALM_S CALM_S CMD_S SAMPLER_S BUDGET_S LOG_MAX_KB (lixo cai no padrão e é dito no log).
# TESTE           bash scripts/disk-recovery-swap-cut.selftest.sh   (hermético: swap, amostrador, roster, bd, gc, relógio simulados; nada real é suspenso)
set -uo pipefail

D=$(cd "$(dirname "$0")" && pwd)
CITY="${DR_CITY:-${GC_CITY_PATH:-$(cd "$D/.." && pwd)}}"
GCDIR="$CITY/.gc"
OFF="${DR_OFF_FILE:-$GCDIR/disk-recovery.off}"
LOG="${DR_SWC_LOG:-$GCDIR/logs/disk-recovery-swap-cut.log}"
LOCK="${DR_SWC_LOCK:-$GCDIR/disk-recovery-swap-cut.lock}"
STATE="${DR_SWC_STATE:-$GCDIR/disk-recovery-swap-cut.state}"
PAUSE="${DR_SWC_PAUSE_FILE:-$GCDIR/swap-spawn-pause}"
SAMPLES="${DR_SWC_SAMPLES:-$GCDIR/ram-owner-samples.jsonl}"
SAMPLER_CMD="${DR_SWC_SAMPLER_CMD:-python3 $D/ram-owner-sampler.py}"
GCBIN="${DR_GC_BIN:-${GC_BIN:-gc}}"
BDBIN="${DR_SWC_BD_BIN:-bd}"
PROJECTS="${DR_SWC_PROJECTS_DIR:-$HOME/.claude/projects}"
# lista fixa, não configurável por ambiente: o que este degrau pode suspender não pode ser alargado por uma variável
POOL_TEMPLATES="wa-worker wa-worker-remote wa-worker-remote-mbp ps-worker ps-worker-remote gate-reviewer gate-reviewer-remote refino-gate-reviewer context-check-reviewer kimi-worker-remote kimi-worker-wa-remote"
DENY_GLOBS="*-wa *-ma *-ps *-lx oracle* *witness* *mayor* *deacon* control-dispatcher* boot* gastown.dog* dog-remote* *dolt* *whatsapp* *daemon*"

MODE=""
T_START=$(date +%s 2>/dev/null || echo 0)
CFG_WARN=""
RB_OUT=""
US=$(printf '\037')

cfg() {  # $1=nome $2=padrão [$3=mínimo] → define $1 com DR_SWC_$1 (só dígitos, até 9, >= mínimo); vazio → padrão; lixo ou abaixo do mínimo → padrão E registra em CFG_WARN (limiar que não leio não vira "sem limite")
  local v
  eval "v=\${DR_SWC_$1:-}"
  case "$v" in
    '') v=$2 ;;
    *[!0-9]*) CFG_WARN="$CFG_WARN DR_SWC_$1='$v'->$2"; v=$2 ;;
    *) { [ "${#v}" -le 9 ] && [ "$v" -ge "${3:-0}" ]; } || { CFG_WARN="$CFG_WARN DR_SWC_$1='$v'->$2"; v=$2; } ;;
  esac
  eval "$1=\$v"
}
cfg GROW_MB 1536 1; cfg GROW_WINDOW_S 300 60; cfg GROW_SLACK_S 330; cfg ABS_MB 5120 1; cfg HYST_MB 1024
cfg SAMPLE_MAX_AGE_S 120 1; cfg SAMPLER_DEAD_S 900 1; cfg IDLE_MIN 15 1; cfg MAX_CUT 3 1; cfg MAX_WAKE 2 1; cfg MIN_RSS_MB 50
cfg SETTLE_S 20; cfg VERIFY_S 3; cfg COOLDOWN_S 300; cfg PAUSE_TTL_S 900 60; cfg PAUSE_CALM_S 300; cfg CALM_S 900
cfg CMD_S 30 1; cfg SAMPLER_S 60 1; cfg BUDGET_S 90 1; cfg LOG_MAX_KB 1024 1

isnum() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 12 ]; }
# orçamento: o maestro (120 s por rodada) espera este degrau; um bd/gc travado (Dolt sob thrash) não pode segurar a escada de disco. Relógio REAL (date), não o NOW de teste
over_budget() { local t; t=$(date +%s 2>/dev/null) || return 1; isnum "$t" && isnum "$T_START" && [ $((t - T_START)) -ge "$BUDGET_S" ]; }
# log: detalhe (pode ter acento). Em dry-run vai para stderr com prefixo, nunca para o arquivo.
log() {
  if [ "$MODE" = dry ]; then printf '[dry-run] %s\n' "$*" >&2; return 0; fi
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null || true
}
say() { local l; l=$(printf '%s' "$*" | LC_ALL=C tr -cd '[:print:]' | cut -c1-300); printf '%s\n' "$l"; }   # a ÚNICA linha de stdout, com UM \n; imprimíveis ASCII
usage() { echo "uso: $0 --run | --dry-run | --resume" >&2; exit 2; }

now() {  # epoch; vazio/ilegível → rc 1 (sem hora não decido nada)
  local t
  if [ -n "${DR_NOW_FILE:-}" ]; then t=$(cat "$DR_NOW_FILE" 2>/dev/null) || return 1; else t=$(date +%s 2>/dev/null) || return 1; fi
  isnum "$t" || return 1
  printf '%s' "$t"
}
read_swap_mb() {  # MB de swap EM USO. vazio → rc 1; falhou/ilegível/unidade que não é M nem G → rc 1 (não sei ≠ 0 MB). LC_ALL=C e vírgula aceita: o sysctl do launchd do mini (pt_BR) imprime "3015,31M"
  local out v
  if [ -n "${DR_SWAP_MB_FILE:-}" ]; then
    v=$(cat "$DR_SWAP_MB_FILE" 2>/dev/null) || return 1
  else
    out=$(LC_ALL=C sysctl -n vm.swapusage 2>/dev/null) || return 1
    v=$(printf '%s\n' "$out" | awk '{for (i = 1; i <= NF; i++) if ($i == "used") { x = $(i + 2); u = substr(x, length(x)); n = substr(x, 1, length(x) - 1)
          if (n ~ /^[0-9]+([.,][0-9]+)?$/ && (u == "M" || u == "G")) { sub(",", ".", n); if (u == "G") n = n * 1024; printf "%d", n; exit } } }')
  fi
  isnum "$v" && [ "${#v}" -le 9 ] || return 1
  printf '%s' "$v"
}

bounded() {  # $1=segundos, resto=comando. stdout em $RB_OUT e stderr em $RB_OUT.err (separados: um aviso do bd/gc com rc 0 não pode invalidar o JSON que se lê). rc do comando; 124 = estourou (TERM e depois KILL, filhos primeiro); 125 = não consegui lançar. Sem `timeout` (o PATH do launchd não o garante)
  local secs=$1 pid ticks=0 limit
  shift
  RB_OUT=$(mktemp "${TMPDIR:-/tmp}/swap-cut.XXXXXX" 2>/dev/null) || { RB_OUT=""; return 125; }
  limit=$((secs * 5))
  "$@" > "$RB_OUT" 2> "$RB_OUT.err" < /dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$limit" ]; then
      pkill -TERM -P "$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null
      sleep 2
      pkill -KILL -P "$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.2; ticks=$((ticks + 1))
  done
  wait "$pid"
}
rb_clean() { [ -n "$RB_OUT" ] && rm -f "$RB_OUT" "$RB_OUT.err" 2>/dev/null; RB_OUT=""; return 0; }

# ── o lado Python: lê o fim do JSONL do amostrador (o arquivo chega a 16 MB: só o último MB) ───────────────────────────────────────────────────────────
read -r -d '' PY <<'PYEOF'
import fnmatch, json, os, re, sys

def tail_records(path, maxbytes=1048576):
    size = os.stat(path).st_size
    with open(path, "rb") as f:
        start = max(0, size - maxbytes)
        f.seek(start)
        data = f.read()
    lines = data.split(b"\n")
    if start > 0:
        lines = lines[1:]  # a 1ª linha do trecho pode estar cortada ao meio
    out = []
    for ln in lines:
        ln = ln.strip()
        if not ln:
            continue
        try:
            d = json.loads(ln)
        except Exception:
            continue  # linha corrompida é descartada, nunca vira registro
        if isinstance(d, dict):
            out.append(d)
    return out

def isnum(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool)

def clean(s):
    return re.sub(r"[^A-Za-z0-9_.@:+/ -]", "?", str(s))[:80]

def valid_swap(recs, now):
    v = []
    for d in recs:
        ts, sw = d.get("ts"), d.get("swap_used_mb")
        if not isnum(ts) or not isnum(sw) or sw < 0:
            continue
        if ts > now + 120:
            continue  # registro do futuro: relógio da amostra errado, não conta
        v.append((int(ts), float(sw)))
    v.sort()
    return v

def cmd_hist(a):
    path, now, window, slack, live = a[0], int(a[1]), int(a[2]), int(a[3]), a[4] == "1"
    try:
        recs = tail_records(path)
    except FileNotFoundError:
        print("err|ausente"); return
    except Exception:
        print("err|ilegivel"); return
    v = valid_swap(recs, now)
    if not v:
        print("err|sem-registro-valido"); return
    new = v[-1]
    # base do crescimento = o registro de idade mais próxima de `window`, entre window/2 e window+slack (o amostrador roda a cada 300 s: com a janela de 300 s só a folga garante um registro).
    # O swap de agora é o do sysctl; sem ele (live=0) o registro mais novo não pode ser base de si mesmo (crescimento 0 fingido)
    pool = [x for x in v if window // 2 <= now - x[0] <= window + slack and (live or x[0] < new[0])]
    base = min(pool, key=lambda x: (abs((now - x[0]) - window), x[0])) if pool else None
    print("ok|%d|%d|%s|%s|%d" % (new[0], round(new[1]), base[0] if base else "", round(base[1]) if base else "", len(v)))

def cmd_owners(a):
    path, now, roster, pools, denies, min_rss_mb = a[0], int(a[1]), a[2], a[3].split(), a[4].split(), int(a[5])
    try:
        recs = tail_records(path)
    except Exception:
        print("err|amostra-ilegivel"); return
    best = None
    for d in recs:
        if isnum(d.get("ts")) and d["ts"] <= now + 120 and isinstance(d.get("by_owner"), dict) and isinstance(d.get("owner_kind"), dict):
            if best is None or d["ts"] >= best["ts"]:
                best = d
    if best is None:
        print("err|amostra-sem-donos"); return
    if best.get("sessions_lookup_failed") is not False:
        print("err|donos-sem-atribuicao"); return  # True (o `gc session list` do amostrador falhou) ou ausente: os rótulos de sessão não são confiáveis
    try:
        with open(roster) as f:
            r = json.load(f)
        sessions = r.get("sessions") if isinstance(r, dict) else r
        assert isinstance(sessions, list)
    except Exception:
        print("err|roster-ilegivel"); return
    idx = {}
    for s in sessions:
        if isinstance(s, dict):
            for k in ("name", "alias"):
                if s.get(k):
                    idx.setdefault(s[k], s)
    # a pegada: o MEM do top por dono (inclui o comprimido, que o RSS esconde), quando o amostrador o leu; sem ele (ausente, null, lixo) o RSS de sempre, e a base vai na saida. O CMPRS vem ao lado, nunca somado
    rows, cmprs = [], {}
    tm = best.get("top_mem")
    for e in tm if isinstance(tm, list) else []:
        if isinstance(e, list) and len(e) == 3 and isinstance(e[0], str) and isnum(e[1]) and isnum(e[2]):
            rows.append((e[1], e[0])); cmprs[e[0]] = e[2]
    basis = "mem" if rows else "rss"
    if not rows:
        rows = [(kb, owner) for owner, kb in best["by_owner"].items() if isnum(kb)]
    rows.sort(key=lambda x: (-x[0], x[1]))
    def verdict(owner):
        kind = best["owner_kind"].get(owner, "?")
        if kind == "dolt":
            return "nunca:dolt", None
        if kind != "session":
            return "nunca:%s" % ("daemon" if kind == "daemon" else "tipo-desconhecido"), None
        s = idx.get(owner)
        if s is None:
            return "nunca:sessao-fora-do-roster", None
        names = [s.get(k) or "" for k in ("template", "name", "alias", "agent_name", "session_name")]
        if s.get("template") not in pools:
            return "nunca:nao-e-pool", None
        for n in names:
            for g in denies:
                if n and fnmatch.fnmatchcase(n, g):
                    return "nunca:deny-list", None
        if s.get("closed") is True or s.get("state") != "active":
            return "fora:%s" % clean(s.get("state") or "?"), None
        if s.get("attached") is not False:
            return "fora:anexada-ou-desconhecido", None
        return "candidata", s
    print("ts|%d" % int(best["ts"]))
    print("basis|%s" % basis)
    shown = 0
    for kb, owner in rows:
        v, s = verdict(owner)
        if shown < 6:
            print("TOP|%d|%s|%s|%s" % (kb // 1024, clean(owner), v, cmprs[owner] // 1024 if owner in cmprs else "-")); shown += 1
        if s is not None and kb // 1024 >= min_rss_mb:
            f = lambda k: re.sub(r"[\x00-\x1f\x7f]", " ", str(s.get(k) or ""))
            print("\x1f".join(["CAND", str(kb // 1024), f("id"), f("name"), f("alias"), f("template"), f("session_name"), f("agent_name"), f("work_dir"), f("session_key")]))

cmds = {"hist": cmd_hist, "owners": cmd_owners}
cmds[sys.argv[1]](sys.argv[2:])
PYEOF

py() { python3 -I -c "$PY" "$@" 2>/dev/null; }

# ── estado: chave=valor, escrito inteiro e trocado com mv. Chaves: last_cut_ts last_after_swap calm_since + 1 linha `s=<id>|<nome>|<template>|<rss>|<ts>[|u]` por sessão suspensa por MIM (`u` = pedi o suspend e o estado não confirmou; a retomada religa as duas, religar quem não dormiu é inerte) ──────────────────────────────
LAST_CUT_TS=0; LAST_AFTER_SWAP=0; CALM_SINCE=0; REG=""; STATE_NOTE=""; STATE_BAD=0
load_state() {  # vazio (arquivo ausente) → zerado, sem aviso e sem STATE_BAD; falhou/ilegível/valor inválido/linha que não entendo → usa o que entendeu, STATE_BAD=1 e STATE_NOTE (NÃO é "sem estado": o registro de sessões suspensas pode ter se perdido). STATE_NOTE sai no log do GATILHO e na linha; save_state guarda o arquivo antigo antes de gravar por cima
  local line k v content
  LAST_CUT_TS=0; LAST_AFTER_SWAP=0; CALM_SINCE=0; REG=""; STATE_NOTE=""; STATE_BAD=0
  [ -e "$STATE" ] || return 0
  # vazio (arquivo sem bytes) → nenhuma linha → zerado; falhou (sem permissão, é um diretório, erro de leitura) → rc != 0 → ilegível, que é "não sei" e não "sem estado"
  content=$(cat "$STATE" 2>/dev/null) || { STATE_BAD=1; STATE_NOTE=" [ESTADO ILEGIVEL: registro de suspensas pode ter se perdido]"; return 0; }
  while IFS= read -r line; do
    case "$line" in
      v=1|'') ;;
      last_cut_ts=*|last_after_swap=*|calm_since=*)
        k=${line%%=*}; v=${line#*=}
        if isnum "$v"; then case "$k" in last_cut_ts) LAST_CUT_TS=$v ;; last_after_swap) LAST_AFTER_SWAP=$v ;; calm_since) CALM_SINCE=$v ;; esac
        else STATE_BAD=1; STATE_NOTE="${STATE_NOTE:- [ESTADO com valor invalido em $k]}"; fi ;;
      s=*) REG="$REG${line#s=}
" ;;
      *) STATE_BAD=1; STATE_NOTE="${STATE_NOTE:- [ESTADO com linha que nao entendo]}" ;;
    esac
  done <<EOF
$content
EOF
  return 0
}
reg_put() {  # $1=id $2=nome $3=template $4=rss $5=marca (vazio ou u): põe a sessão no registro, trocando a linha dela se já estava (uma sessão que segue ativa é candidata de novo na rodada seguinte)
  local l new=""
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    case "$l" in "$1|"*) ;; *) new="$new$l
" ;; esac
  done <<EOF
$REG
EOF
  REG="$new$1|$2|$3|$4|$NOW${5:+|$5}
"
}
save_state() {  # rc 0 gravou; rc 1 não gravou (o chamador diz). Estado que existe e que não li inteiro (STATE_BAD) é "não sei": o arquivo antigo é GUARDADO (rename, que funciona sem ler) antes de qualquer gravação; se nem isso der, NÃO grava e diz
  local tmp="$STATE.tmp.$$" l kept
  mkdir -p "$(dirname "$STATE")" 2>/dev/null
  # vazio (o arquivo sumiu desde a leitura: nada a guardar) → segue e grava; falhou o rename → rc 1 sem tocar no arquivo antigo
  if [ "$STATE_BAD" = 1 ] && [ -e "$STATE" ]; then
    kept="$STATE.ilegivel.$NOW"; [ -e "$kept" ] && kept="$kept.$$"
    if mv "$STATE" "$kept" 2>/dev/null; then
      STATE_BAD=0; STATE_NOTE="$STATE_NOTE [estado antigo guardado em ${kept##*/}]"
      log "ESTADO: o arquivo de estado nao foi lido inteiro; guardei o original em $kept antes de gravar o novo (o registro de sessoes suspensas, se havia, esta la)"
    else
      case "$STATE_NOTE" in *"NAO gravei o estado"*) ;; *) STATE_NOTE="$STATE_NOTE [NAO gravei o estado: nao consegui guardar o antigo]" ;; esac   # uma vez só: cada sessão cortada tenta gravar de novo
      log "FALHOU: o arquivo de estado $STATE nao foi lido inteiro e nao consegui guarda-lo (rename para $kept falhou): NAO gravei por cima"
      return 1
    fi
  fi
  {
    printf 'v=1\nlast_cut_ts=%s\nlast_after_swap=%s\ncalm_since=%s\n' "$LAST_CUT_TS" "$LAST_AFTER_SWAP" "$CALM_SINCE"
    printf '%s' "$REG" | while IFS= read -r l; do [ -n "$l" ] && printf 's=%s\n' "$l"; done
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$STATE" 2>/dev/null && return 0
  rm -f "$tmp" 2>/dev/null
  return 1
}

# ── trava de instância única (mkdir) ──────────────────────────────────────────────────────────────────────────────────────────────────────────
LOCK_HELD=0
acquire_lock() {  # rc 0 peguei · rc 1 outra instância VIVA tem a trava (calado, caso normal) · rc 2 não consegui tomar nem verificar (terceiro estado)
  local p c
  mkdir -p "$GCDIR" 2>/dev/null
  if mkdir "$LOCK" 2>/dev/null; then echo $$ > "$LOCK/pid" 2>/dev/null; LOCK_HELD=1; return 0; fi
  [ -d "$LOCK" ] || return 2
  p=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
    c=$(ps -p "$p" -o command= 2>/dev/null)
    case "$c" in ''|*disk-recovery-swap-cut*) return 1 ;; esac   # vazio (ps sem saída) → dúvida → a outra instância é a dona
  elif [ -z "$p" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin -10 2>/dev/null)" ]; then
    return 1   # trava recém-criada, pid ainda não gravado: é de alguém
  fi
  rm -f "$LOCK/pid" 2>/dev/null; rmdir "$LOCK" 2>/dev/null
  if mkdir "$LOCK" 2>/dev/null; then echo $$ > "$LOCK/pid" 2>/dev/null; LOCK_HELD=1; return 0; fi
  return 2
}
release_lock() { if [ "$LOCK_HELD" = 1 ]; then rm -f "$LOCK/pid" 2>/dev/null; rmdir "$LOCK" 2>/dev/null; LOCK_HELD=0; fi; return 0; }

rotate_log() {  # log acima de LOG_MAX_KB vira .1 (um só backup). tamanho ilegível → não gira
  local kb
  [ -f "$LOG" ] || return 0
  kb=$(du -k "$LOG" 2>/dev/null | awk '{print $1}')
  isnum "$kb" || return 0
  [ "$kb" -gt "$LOG_MAX_KB" ] && mv -f "$LOG" "$LOG.1" 2>/dev/null
  return 0
}

# ── a pausa do spawn do Pilot ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────
pause_expiry() {  # validade (epoch) da pausa que está no arquivo; vazio → rc 1 (sem pausa, ou ilegível: nunca "pausada")
  local l1 l3
  [ -r "$PAUSE" ] || return 1
  l1=$(sed -n 1p "$PAUSE" 2>/dev/null); l3=$(sed -n 3p "$PAUSE" 2>/dev/null)
  [ "$l1" = PAUSE ] && isnum "$l3" || return 1
  printf '%s' "$l3"
}
write_pause() {  # $1=agora $2=motivo. Grava, troca e LÊ DE VOLTA. rc 0 confirmado; rc 1 não
  local t=$1 why=$2 tmp="$PAUSE.tmp.$$" exp back
  exp=$((t + PAUSE_TTL_S))
  mkdir -p "$(dirname "$PAUSE")" 2>/dev/null
  printf 'PAUSE\n%s\n%s\n%s\n' "$t" "$exp" "$why" > "$tmp" 2>/dev/null && mv -f "$tmp" "$PAUSE" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  back=$(pause_expiry) || return 1
  [ "$back" = "$exp" ]
}

hhmm() { date -r "$1" '+%H:%M' 2>/dev/null || date -d "@$1" '+%H:%M' 2>/dev/null || printf '%s' "$1"; }

# ── bead in_progress e transcrição (mesmas regras do idle-crew-suspender; duplicadas de propósito: cada degrau é independente) ───────────────────────────────────────────────────────────────────────
inprogress_state() {  # $1=identidade $2=store → "0" (nenhuma) | "N" | "?" (bd falhou/estourou/respondeu algo que não é lista). Só "0" deixa a sessão ser candidata
  local ident=$1 store=$2 out n
  [ -n "$ident" ] && [ -n "$store" ] || { printf '?'; return 0; }
  bounded "$CMD_S" "$BDBIN" -C "$store" list --status in_progress --assignee "$ident" --json --limit 0 || { rb_clean; printf '?'; return 0; }
  out=$(cat "$RB_OUT" 2>/dev/null); rb_clean
  n=$(printf '%s' "$out" | python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("?"); sys.exit(0)
print(len(d) if isinstance(d, list) else "?")
' 2>/dev/null)
  case "$n" in ''|*[!0-9]*) printf '?' ;; *) printf '%s' "$n" ;; esac
}
transcript_idle_min() {  # $1=work_dir $2=session_key → minutos inteiros desde a última escrita da transcrição DELA. rc 2 = não sei (sem arquivo, sem época): a sessão NÃO é ociosa
  local wd=$1 key=$2 slug f m t
  [ -n "$wd" ] && [ -n "$key" ] || return 2
  slug=$(printf '%s' "$wd" | sed 's#[^A-Za-z0-9]#-#g')
  f="$PROJECTS/$slug/$key.jsonl"
  [ -f "$f" ] || return 2
  m=$(stat -f %m "$f" 2>/dev/null) || m=$(stat -c %Y "$f" 2>/dev/null) || return 2
  isnum "$m" || return 2
  t=$NOW
  [ "$t" -ge "$m" ] || { printf '0'; return 0; }
  printf '%s' $(( (t - m) / 60 ))
}
rig_of() {  # work_dir de crew/worker → raiz do rig; senão vazio (só o HQ)
  case "$1" in */crew/*) printf '%s' "${1%/crew/*}" ;; *) printf '' ;; esac
}
read -r -d '' PYS <<'PYEOF'
import json, os, sys
try:
    rows = json.load(sys.stdin)["sessions"]
except Exception:
    print("?|?"); sys.exit(0)
for s in rows:
    if isinstance(s, dict) and s.get("id") == os.environ["ID"]:
        print("%s|%s" % (s.get("state") or "?", {True: "true", False: "false"}.get(s.get("attached"), "?"))); sys.exit(0)
print("gone|-")
PYEOF
session_probe() {  # $1=id → "estado|anexada" (anexada true/false/?; estado "gone" = o id não está na lista; "?|?" = não consegui ler: nunca "ativa e solta")
  local st
  if [ -n "${DR_SWC_SESSIONS_FILE:-}" ]; then st=$(ID="$1" python3 -I -c "$PYS" 2>/dev/null < "$DR_SWC_SESSIONS_FILE")
  else
    bounded "$CMD_S" "$GCBIN" session list --json --state all || { rb_clean; printf '?|?'; return 0; }
    st=$(ID="$1" python3 -I -c "$PYS" 2>/dev/null < "$RB_OUT"); rb_clean
  fi
  printf '%s' "${st:-?|?}"
}
session_state() { local p; p=$(session_probe "$1"); printf '%s' "${p%%|*}"; }   # $1=id → estado atual, "gone" ou "?"

# ── leitura comum: swap agora + histórico do amostrador. Preenche SW_NOW SW_REF SW_NOTE NEW_TS NEW_SWAP BASE_TS BASE_SWAP GROWTH BLIND ────────────────────────────────────────────────────────────────
SW_NOW=""; SW_REF=""; SW_NOTE=""; NEW_TS=""; NEW_SWAP=""; BASE_TS=""; BASE_SWAP=""; GROWTH=""; GROWTH_NOTE=""; BLIND=""
read_history() {
  local h age
  SW_NOW=""; SW_REF=""; SW_NOTE=""; NEW_TS=""; NEW_SWAP=""; BASE_TS=""; BASE_SWAP=""; GROWTH=""; GROWTH_NOTE=""; BLIND=""
  # vazio/falhou/ilegível do vm.swapusage → "" (cai na amostra e diz); NUNCA 0
  SW_NOW=$(read_swap_mb) || SW_NOW=""
  h=$(py hist "$SAMPLES" "$NOW" "$GROW_WINDOW_S" "$GROW_SLACK_S" "$([ -n "$SW_NOW" ] && echo 1 || echo 0)") || h="err|python"
  case "$h" in
    ok\|*) IFS='|' read -r _ NEW_TS NEW_SWAP BASE_TS BASE_SWAP _ <<EOF
$h
EOF
      ;;
    *) BLIND="amostrador sem leitura (${h#err|}: $SAMPLES)"; return 1 ;;
  esac
  isnum "$NEW_TS" && isnum "$NEW_SWAP" || { BLIND="amostrador sem leitura (registro ilegivel)"; return 1; }
  age=$((NOW - NEW_TS)); [ "$age" -ge 0 ] || age=0
  if [ "$age" -gt "$SAMPLER_DEAD_S" ]; then BLIND="amostrador parado: ultima amostra ha ${age}s (limite ${SAMPLER_DEAD_S}s)"; return 1; fi
  if [ -n "$SW_NOW" ]; then SW_REF=$SW_NOW; else SW_REF=$NEW_SWAP; SW_NOTE=" [vm.swapusage ilegivel: usei o swap da amostra de ${age}s]"; fi
  if isnum "$BASE_TS" && isnum "$BASE_SWAP" && [ $((NOW - BASE_TS)) -ge $((GROW_WINDOW_S / 2)) ]; then
    GROWTH=$((SW_REF - BASE_SWAP))
  else
    GROWTH_NOTE=" [historico curto: sem base para o crescimento]"   # sem base não há crescimento NEM "crescimento zero": só o nível absoluto decide
  fi
  return 0
}
triggered() {  # rc 0 se algum gatilho vale. Preenche WHY_TRIG
  WHY_TRIG=""
  if [ "$SW_REF" -gt "$ABS_MB" ]; then WHY_TRIG="swap ${SW_REF}MB > ${ABS_MB}MB"; fi
  if [ -n "$GROWTH" ] && [ "$GROWTH" -ge "$GROW_MB" ]; then WHY_TRIG="${WHY_TRIG:+$WHY_TRIG e }+${GROWTH}MB em ${GROW_WINDOW_S}s"; fi
  [ -n "$WHY_TRIG" ]
}

# ── --run ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
do_run() {
  local sw_txt out_tmp roster_tmp cut_n=0 fail_n=0 save_fail=0 fail_txt="" unc_n=0 unk_n=0 unc_list="" unk_txt="" unc_txt="" pr idle2 still skipped="" cutlist="" tops="" cand_n=0 pause_msg="" pause_ok=-1 exp rem sw_after back rcs st
  local id name alias template session_name agent_name wd skey rss idle ident store tried blocked nl src
  nl=$'\n'

  read_history || { log "SEM LEITURA: $BLIND — nao corto, nao pauso"; say "SEM LEITURA: $BLIND; nao cortei nada"; return 30; }
  sw_txt="swap ${SW_REF}MB${GROWTH:+ (${GROWTH}MB em ${GROW_WINDOW_S}s)}"
  triggered || { log "sem gatilho: $sw_txt$GROWTH_NOTE$SW_NOTE"; say "sem gatilho: $sw_txt$GROWTH_NOTE (limites: +${GROW_MB}MB/${GROW_WINDOW_S}s, ${ABS_MB}MB)"; return 10; }
  # vazio (sem arquivo de estado) → STATE_NOTE vazio, nada a dizer; ilegível/valor inválido/linha desconhecida → STATE_NOTE diz, no log do gatilho e em TODA linha de saída abaixo (o "sem gatilho" acima não lê nem grava o estado)
  load_state
  log "GATILHO: $WHY_TRIG ($sw_txt)$GROWTH_NOTE$SW_NOTE$STATE_NOTE"
  # o gatilho encerra o "calmo" da retomada: zera a contagem (calm_since). Estado ilegível (STATE_BAD) não é regravado só por isso. Se a gravação falhar, a retomada ainda exige que a contagem tenha começado depois do último corte
  if [ "$MODE" = run ] && [ "$STATE_BAD" = 0 ] && [ "$CALM_SINCE" != 0 ]; then CALM_SINCE=0; save_state || log "WARN: nao consegui zerar a contagem de calma em $STATE"; fi

  # carência: acabei de cortar e o swap não voltou a subir desde então → a base de crescimento ainda enxerga o salto de antes do corte; só mantém a pausa
  if [ "$LAST_CUT_TS" -gt 0 ] && [ $((NOW - LAST_CUT_TS)) -lt "$COOLDOWN_S" ] && [ "$SW_REF" -lt $((LAST_AFTER_SWAP + GROW_MB / 2)) ]; then
    if [ "$MODE" = run ]; then keep_pause "carencia: $WHY_TRIG"; fi
    log "carencia: cortei ha $((NOW - LAST_CUT_TS))s (swap depois do corte ${LAST_AFTER_SWAP}MB, agora ${SW_REF}MB)$PAUSE_NOTE"
    say "em carencia ($((NOW - LAST_CUT_TS))s < ${COOLDOWN_S}s desde o corte)$STATE_NOTE: $sw_txt$PAUSE_NOTE"
    return ${PAUSE_RC:-10}
  fi

  # amostra nova: o degrau exige dono de RAM de <= SAMPLE_MAX_AGE_S; o launchd do amostrador roda a cada 300 s, então a colho agora (dry-run não colhe: lê o que tem)
  if [ "$MODE" = run ]; then
    bounded "$SAMPLER_S" env RAM_OWNER_OUT="$SAMPLES" $SAMPLER_CMD; rcs=$?
    [ "$rcs" = 0 ] || log "amostra nova: o amostrador saiu rc=$rcs: $(cat "$RB_OUT.err" "$RB_OUT" 2>/dev/null | head -c 200 | tr '\n' ' ')"
    rb_clean
    read_history || { log "SEM LEITURA depois da amostra nova: $BLIND — nao corto, nao pauso"; say "SEM LEITURA: $BLIND; nao cortei nada"; return 30; }
    if [ $((NOW - NEW_TS)) -gt "$SAMPLE_MAX_AGE_S" ]; then
      log "SEM LEITURA: a amostra mais nova tem $((NOW - NEW_TS))s (> ${SAMPLE_MAX_AGE_S}s) mesmo depois de colher uma (amostrador rc=$rcs) — nao corto, nao pauso"
      say "SEM LEITURA: amostra de $((NOW - NEW_TS))s (> ${SAMPLE_MAX_AGE_S}s) e o amostrador nao produziu outra (rc=$rcs); nao cortei nada"
      return 30
    fi
  fi

  roster_tmp=$(mktemp "${TMPDIR:-/tmp}/swap-cut-roster.XXXXXX" 2>/dev/null) || { log "SEM LEITURA: mktemp falhou"; say "SEM LEITURA: nao consegui criar arquivo temporario; nao cortei nada"; return 30; }
  if [ -n "${DR_SWC_SESSIONS_FILE:-}" ]; then cp "$DR_SWC_SESSIONS_FILE" "$roster_tmp" 2>/dev/null || : > "$roster_tmp"
  else
    bounded "$CMD_S" "$GCBIN" session list --json; rcs=$?
    if [ "$rcs" = 0 ]; then cp "$RB_OUT" "$roster_tmp" 2>/dev/null; else : > "$roster_tmp"; fi
    rb_clean
  fi
  out_tmp=$(py owners "$SAMPLES" "$NOW" "$roster_tmp" "$POOL_TEMPLATES" "$DENY_GLOBS" "$MIN_RSS_MB") || out_tmp="err|python"
  rm -f "$roster_tmp" 2>/dev/null
  case "$out_tmp" in
    err\|*) log "SEM LEITURA dos donos de RAM: ${out_tmp#err|} — nao corto, nao pauso"; say "SEM LEITURA dos donos de RAM (${out_tmp#err|}); nao cortei nada"; return 30 ;;
  esac
  tops=$(printf '%s\n' "$out_tmp" | awk -F'|' '$1=="TOP" {printf "%s%s %sMB (%s%s)", (n++ ? ", " : ""), $3, $2, $4, ($5 != "-" ? ", comprimido " $5 "MB" : "")}')
  log "maiores donos de RAM: $tops"
  if printf '%s\n' "$out_tmp" | grep -q '^basis|mem$'; then log "ordem do corte por MEM (o top: pegada que ja inclui o comprimido)"; else log "ordem do corte por RSS: o amostrador nao leu o top nesta amostra (top_mem ausente ou ilegivel)"; fi

  # candidatas, em ordem de RSS desc (o Python já ordenou)
  while IFS="$US" read -r _tag rss id name alias template session_name agent_name wd skey; do
    [ "$_tag" = CAND ] || continue
    cand_n=$((cand_n + 1))
    if over_budget; then skipped="$skipped $name:orcamento"; unk_n=$((unk_n + 1)); log "MANTEM $name ($template, ${rss}MB): orcamento de ${BUDGET_S}s esgotado (bd/gc lentos): nao verifiquei"; continue; fi
    if [ $((cut_n + unc_n)) -ge "$MAX_CUT" ]; then skipped="$skipped $name:teto-por-rodada"; log "MANTEM $name ($template, ${rss}MB): teto de $MAX_CUT por rodada"; continue; fi
    idle=$(transcript_idle_min "$wd" "$skey") || { skipped="$skipped $name:transcricao-desconhecida"; unk_n=$((unk_n + 1)); log "MANTEM $name ($template, ${rss}MB): transcricao desconhecida"; continue; }
    if [ "$idle" -lt "$IDLE_MIN" ]; then skipped="$skipped $name:transcricao-recente(${idle}min)"; log "MANTEM $name ($template, ${rss}MB): transcricao parada ha ${idle}min (< ${IDLE_MIN})"; continue; fi
    blocked=""; tried="$nl"
    for ident in "$alias" "$session_name" "$id" "$name" "$agent_name" "$template"; do
      [ -n "$ident" ] || continue
      case "$tried" in *"$nl$ident$nl"*) continue ;; esac
      tried="$tried$ident$nl"
      for store in "$(rig_of "$wd")" "$CITY"; do
        [ -n "$store" ] || continue
        over_budget && { blocked="orcamento de ${BUDGET_S}s esgotado antes de ler o bd"; break 2; }
        st=$(inprogress_state "$ident" "$store")
        if [ "$st" != 0 ]; then blocked="in_progress=$st como=$ident store=${store##*/}"; break 2; fi
      done
    done
    if [ -n "$blocked" ]; then
      case "$blocked" in in_progress=\?*|orcamento*) unk_n=$((unk_n + 1)) ;; esac
      skipped="$skipped $name:bead($blocked)"; log "MANTEM $name ($template, ${rss}MB): $blocked"; continue
    fi
    if [ "$MODE" = dry ]; then cutlist="$cutlist${cutlist:+, }$name ${rss}MB"; cut_n=$((cut_n + 1)); log "CORTARIA $name ($template, ${rss}MB, transcricao parada ha ${idle}min)"; continue; fi
    # as leituras de bd acima levam até ${BUDGET_S}s: o Athos pode ter anexado, a sessão pode ter voltado a escrever ou mudado de estado. Releio estado, anexada e transcrição AGORA; o que não consigo ler (ou o orçamento esgotado) mantém
    # vazio → "?|?" (mantém); falhou/ilegível/orçamento esgotado → "?|?" (mantém): só "active|false" deixa suspender
    if over_budget; then pr="?|?"; else pr=$(session_probe "$id"); fi
    # vazio → rc 2 → idle2=0 (mantém); falhou/ilegível → o mesmo: sem a transcrição não sei, e não saber é "escreveu agora"
    idle2=$(transcript_idle_min "$wd" "$skey") || idle2=0
    if [ "$pr" != "active|false" ] || [ "$idle2" -lt "$IDLE_MIN" ]; then
      case "$pr" in *\?*) unk_n=$((unk_n + 1)) ;; esac
      skipped="$skipped $name:mudou-antes-do-suspend"; log "MANTEM $name ($template, ${rss}MB): logo antes do suspend leu estado|anexada='$pr' e transcricao parada ha ${idle2}min (precisa de active|false e >= ${IDLE_MIN}min)"; continue
    fi
    bounded "$CMD_S" "$GCBIN" session suspend "$id"; src=$?; rb_clean
    sleep "$VERIFY_S"
    st=$(session_state "$id")
    # no caminho gerenciado o `gc session suspend` só põe o hold e cutuca o reconciler: o rc e o estado de 3 s depois não distinguem ATRASO de FALTA DE EFEITO. Três desfechos, como o idle-crew-suspender:
    # dormindo (qualquer outro estado) = CORTOU · rc != 0 e a sessão ainda ativa = FALHOU (nada mudou) · o resto (rc 0 e ainda ativa, ou estado `?`/`gone`) = NAO CONFIRMADO (entra no registro marcado `u`; uma releitura depois do settle resolve)
    case "$st" in
      active|start-pending|creating) [ "$src" = 0 ] && st="$st:unc" || st="$st:fail" ;;
      "?"|gone) st="$st:unc" ;;
    esac
    case "$st" in
      *:fail)
        fail_n=$((fail_n + 1)); skipped="$skipped $name:suspend-sem-efeito"; log "FALHOU $name ($template, ${rss}MB): gc session suspend rc=$src e a sessao segue '${st%:fail}'" ;;
      *:unc)
        unc_n=$((unc_n + 1)); unc_list="$unc_list$id|$name|$template|$rss
"; reg_put "$id" "$name" "$template" "$rss" u
        log "NAO CONFIRMADO $name ($template, ${rss}MB): gc session suspend rc=$src, estado '${st%:unc}' ${VERIFY_S}s depois (hold posto, o reconciler pode estar atrasado); registrado como nao confirmado, releio depois de ${SETTLE_S}s" ;;
      *)
        cut_n=$((cut_n + 1)); cutlist="$cutlist${cutlist:+, }$name ${rss}MB"; reg_put "$id" "$name" "$template" "$rss" ""
        log "CORTOU $name ($template, ${rss}MB, transcricao parada ha ${idle}min): gc session suspend rc=$src, estado depois: $st" ;;
    esac
    # o registro vai para o disco AGORA, antes do settle: um kill do maestro (ou um pânico como o de 16/11) na janela do settle não pode perder o que já foi posto para dormir
    case "$st" in *:fail) ;; *) LAST_CUT_TS=$NOW; LAST_AFTER_SWAP=$SW_REF; save_state || log "WARN: nao consegui gravar $STATE depois de suspender $name" ;; esac
  done <<EOF
$out_tmp
EOF

  # 2) a pausa do spawn novo do Pilot: com gatilho ela vale mesmo sem candidata (é o freio que não gasta nada e impede o Pilot de repor o que acabei de cortar)
  if [ "$MODE" = run ]; then
    keep_pause "$WHY_TRIG"
    pause_ok=$PAUSE_OK
  fi

  sw_after=""
  # a carência (LAST_CUT_TS) só arma depois de uma rodada que CORTOU ou pediu suspend ainda sem confirmação (cut_n+unc_n > 0). Rodada em que TODO suspend falhou (cut_n=0, unc_n=0, fail_n>0) não mudou nada:
  # não arma a carência, não grava estado, e a rodada seguinte tenta suspender de novo (o rc 20 e a linha FALHOU seguem sendo ditos abaixo). Cortar de verdade em uma sessão e falhar em outra arma, porque houve corte
  if [ "$MODE" = run ] && [ $((cut_n + unc_n)) -gt 0 ]; then
    LAST_CUT_TS=$NOW
    sleep "$SETTLE_S"
    if [ "$unc_n" -gt 0 ]; then   # UMA releitura dos não confirmados, agora que o reconciler teve o SETTLE_S: dormindo → CORTOU; ainda não → continua `u` e a linha diz
      still=0
      while IFS='|' read -r id name template rss; do
        [ -n "$id" ] || continue
        # vazio → "gone" (segue não confirmado); falhou/ilegível → "?" (segue não confirmado): nunca vira CORTOU sem ler um estado de sessão parada
        st=$(session_state "$id")
        case "$st" in
          active|start-pending|creating|"?"|gone) still=$((still + 1)); log "NAO CONFIRMADO apos ${SETTLE_S}s: $name segue '$st' (suspend pedido, hold posto, no registro como u)" ;;
          *) cut_n=$((cut_n + 1)); cutlist="$cutlist${cutlist:+, }$name ${rss}MB"; reg_put "$id" "$name" "$template" "$rss" ""; log "CONFIRMADO $name: estado '$st' depois de ${SETTLE_S}s" ;;
        esac
      done <<EOF
$unc_list
EOF
      unc_n=$still
    fi
    sw_after=$(read_swap_mb) || sw_after=""
    isnum "$sw_after" && LAST_AFTER_SWAP=$sw_after || LAST_AFTER_SWAP=$SW_REF
    # falhou a gravação → save_fail (rc 20), contado à parte: não é "suspend com rc != 0", e a linha não pode dizer que foi
    save_state || { log "WARN: nao consegui gravar $STATE: o registro das sessoes suspensas fica so no log"; save_fail=1; }
  fi

  # a linha. "mantida por leitura impossivel" != "mantida porque estava ocupada": a linha diz quantas foram por não conseguir ler (bd/gc/transcricao/orcamento)
  [ "$unk_n" -gt 0 ] && unk_txt="; $unk_n delas mantida(s) por leitura impossivel (bd/gc/transcricao/orcamento), nao por estarem ocupadas"
  if [ "$MODE" = dry ]; then
    if [ "$cut_n" -gt 0 ]; then say "(dry-run) $WHY_TRIG$STATE_NOTE: cortaria $cut_n sessao(oes) ociosa(s): $cutlist; pausaria o spawn do Pilot por ${PAUSE_TTL_S}s"; return 10; fi
    say "(dry-run) $WHY_TRIG$STATE_NOTE: sem candidata permitida ($cand_n candidata(s) no roster, todas mantidas:$skipped$unk_txt); pausaria o spawn do Pilot por ${PAUSE_TTL_S}s; maiores donos: $tops"; return 10
  fi
  rem=""
  if [ "$pause_ok" = 1 ]; then rem="; pausou o spawn novo do Pilot ate $(hhmm "$PAUSE_UNTIL")"; elif [ "$pause_ok" = 0 ]; then rem="; NAO gravou a pausa do spawn do Pilot"; fi
  if [ $((cut_n + unc_n)) -gt 0 ]; then
    if [ -n "$sw_after" ]; then rem="$rem; swap ${SW_REF}->${sw_after}MB (voltou $((SW_REF - sw_after))MB)"; else rem="$rem; swap depois do corte ilegivel"; fi
  fi
  [ "$unc_n" -gt 0 ] && unc_txt="; $unc_n suspend(s) pedido(s) SEM confirmacao de estado apos ${SETTLE_S}s (hold posto; no registro como nao confirmados)"
  # a linha diz O QUE falhou: suspend (rc != 0 e a sessão ativa), registro que não gravou, pausa que não gravou. Falha só da pausa não diz "0 suspend(s) com rc != 0"
  if [ "$fail_n" -gt 0 ] || [ "$save_fail" = 1 ] || [ "$pause_ok" = 0 ]; then
    [ "$fail_n" -gt 0 ] && fail_txt=", $fail_n suspend(s) com rc != 0 e a sessao ainda ativa"
    [ "$save_fail" = 1 ] && fail_txt="$fail_txt, NAO gravei o registro das sessoes suspensas"
    say "FALHOU em parte: $WHY_TRIG$STATE_NOTE: cortou $cut_n${cutlist:+ ($cutlist)}$fail_txt$unc_txt$rem"
    return 20
  fi
  if [ "$cut_n" -gt 0 ] || [ "$unc_n" -gt 0 ]; then say "$WHY_TRIG$STATE_NOTE: cortou $cut_n sessao(oes) ociosa(s)${cutlist:+: $cutlist}$unc_txt$rem"; return 0; fi
  # gatilho ativo e ninguém para cortar
  log "SEM CANDIDATA: $cand_n candidata(s) no roster, todas mantidas:$skipped"
  say "$WHY_TRIG$STATE_NOTE e NAO ha sessao de pool ociosa para cortar ($cand_n candidata(s) mantida(s))$unk_txt; maiores donos: $tops$rem"
  return 11
}

# keep_pause <motivo>: grava ou renova a pausa quando restam menos de metade da validade. Preenche PAUSE_OK (1 gravou/vigente · 0 não gravou), PAUSE_NOTE e PAUSE_RC (0 gravou/renovou · 10 vigente · 20 falhou)
PAUSE_OK=-1; PAUSE_NOTE=""; PAUSE_RC=10; PAUSE_UNTIL=0
keep_pause() {
  local exp rem
  PAUSE_NOTE=""; PAUSE_RC=10; PAUSE_OK=1
  exp=$(pause_expiry) || exp=""
  # vigente = restam >= metade da validade E <= 3600 s: o Pilot ignora validade mais longe que isso (PILOT_SWAP_PAUSE_MAX_AHEAD_S, fail-open), então um arquivo assim não pausa nada e é regravado
  if isnum "$exp" && [ $((exp - NOW)) -ge $((PAUSE_TTL_S / 2)) ] && [ $((exp - NOW)) -le 3600 ]; then PAUSE_UNTIL=$exp; PAUSE_NOTE="; pausa do Pilot vigente ate $(hhmm "$exp")"; return 0; fi
  if write_pause "$NOW" "$1"; then
    PAUSE_UNTIL=$((NOW + PAUSE_TTL_S)); PAUSE_NOTE="; pausa do spawn do Pilot renovada ate $(hhmm $PAUSE_UNTIL)"; PAUSE_RC=0
    log "PAUSA do spawn do Pilot ate $(hhmm $((NOW + PAUSE_TTL_S))) ($PAUSE): $1"
  else
    PAUSE_OK=0; PAUSE_RC=20; PAUSE_NOTE="; NAO gravei a pausa do spawn do Pilot ($PAUSE)"
    log "FALHOU: nao consegui gravar/ler de volta a pausa $PAUSE"
  fi
  return 0
}

# ── --resume ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
do_resume() {
  local calm=0 waked=0 failed=0 left="" id name tpl rss ts mk rcw wl="" has_reg=0 has_pause=0 age pst
  # vazio (sem arquivo de estado) → nada registrado, segue; falhou/ilegível/valor inválido/linha que não entendo → rc 30: o registro das suspensas pode estar lá e eu não o leio. Não religo, não apago a pausa (vence sozinha), NÃO gravo
  load_state
  if [ "$STATE_BAD" = 1 ]; then
    log "RETOMADA: estado nao lido inteiro$STATE_NOTE — nao religo, nao apago a pausa (a validade dela vence sozinha), nao gravo"
    say "SEM LEITURA na retomada:$STATE_NOTE; nao religuei nada"; return 30
  fi
  [ -n "$REG" ] && has_reg=1
  # vazio (sem arquivo) → sem pausa; ilegível ou vencida → também conta, para limpar (o Pilot já a ignora, apagar é inerte)
  [ -e "$PAUSE" ] && has_pause=1
  if [ "$has_reg" = 0 ] && [ "$has_pause" = 0 ]; then
    if [ "$CALM_SINCE" != 0 ]; then CALM_SINCE=0; save_state || log "WARN: nao consegui gravar $STATE"; fi
    say "nada a retomar"; return 10
  fi
  read_history || { log "RETOMADA: $BLIND — nao religo, nao apago a pausa (a validade dela vence sozinha)"; say "SEM LEITURA na retomada: $BLIND; nao religuei nada"; return 30; }
  # calmo = os DOIS lidos: nível baixo E crescimento conhecido e pequeno, e nenhum gatilho. Crescimento sem base (histórico curto) não é "calmo"
  if [ "$SW_REF" -le $((ABS_MB - HYST_MB)) ] && [ -n "$GROWTH" ] && [ "$GROWTH" -lt $((GROW_MB / 2)) ] && ! triggered; then calm=1; fi
  if [ "$calm" = 0 ]; then
    if [ "$CALM_SINCE" != 0 ]; then
      CALM_SINCE=0
      save_state || { log "FALHOU: nao consegui zerar a contagem de calma em $STATE (swap ${SW_REF}MB nao esta calmo)"; say "FALHOU na retomada: swap ${SW_REF}MB nao esta calmo e nao consegui zerar a contagem de calma; mantenho pausa e sessoes suspensas"; return 20; }
    fi
    say "swap ${SW_REF}MB${GROWTH:+ (${GROWTH}MB em ${GROW_WINDOW_S}s)} ainda nao esta calmo: mantenho pausa e sessoes suspensas"; return 10
  fi
  # a contagem só vale se começou DEPOIS do último corte (o corte encerra o calmo anterior): uma contagem velha que sobrou (zeragem que não gravou) recomeça agora
  if [ "$CALM_SINCE" = 0 ] || [ "$CALM_SINCE" -gt "$NOW" ] || [ "$CALM_SINCE" -lt "$LAST_CUT_TS" ]; then
    CALM_SINCE=$NOW
    save_state || { log "FALHOU: nao consegui gravar o inicio da contagem de calma em $STATE"; say "FALHOU na retomada: swap calmo (${SW_REF}MB) mas nao consegui gravar o inicio da contagem; nao religo nada"; return 20; }
  fi
  age=$((NOW - CALM_SINCE))
  if [ "$has_pause" = 1 ] && [ "$age" -ge "$PAUSE_CALM_S" ]; then
    if rm -f "$PAUSE" 2>/dev/null && [ ! -e "$PAUSE" ]; then log "RETOMADA: pausa do spawn do Pilot apagada (calmo ha ${age}s, swap ${SW_REF}MB)"; has_pause=0; wl="pausa do spawn do Pilot apagada"
    else log "FALHOU: nao consegui apagar $PAUSE"; failed=$((failed + 1)); fi
  fi
  if [ "$has_reg" = 1 ] && [ "$age" -ge "$CALM_S" ]; then
    # `mk` = marca `u` (suspend pedido e nunca confirmado): religa igual, religar quem não dormiu é inerte, e a marca volta no registro se o wake falhar
    while IFS='|' read -r id name tpl rss ts mk; do
      [ -n "$id" ] || continue
      if [ "$waked" -ge "$MAX_WAKE" ] || over_budget; then left="$left$id|$name|$tpl|$rss|$ts${mk:+|$mk}
"; continue; fi
      # só a leitura POSITIVA tira do registro: "gone" (o id não está mais na lista) ou já ativa (alguém religou). "?" (não li) → tenta o wake, que é a direção que devolve a sessão
      pst=$(session_state "$id")
      case "$pst" in
        gone) log "RETOMADA: $name ($tpl) nao esta mais no roster; tirei do registro sem religar"; wl="${wl}${wl:+; }$name ja nao existe (tirada do registro)"; continue ;;
        active|start-pending|creating) log "RETOMADA: $name ($tpl) ja esta '$pst' (alguem a religou); tirei do registro"; wl="${wl}${wl:+; }$name ja estava ativa (tirada do registro)"; continue ;;
      esac
      bounded "$CMD_S" "$GCBIN" session wake "$id"; rcw=$?; rb_clean
      if [ "$rcw" = 0 ]; then
        waked=$((waked + 1)); wl="${wl}${wl:+; }religou $name"; log "RELIGOU $name ($tpl) [suspensa por mim em $ts, ${rss}MB${mk:+, marca $mk}]: gc session wake rc=0"
      else
        failed=$((failed + 1)); left="$left$id|$name|$tpl|$rss|$ts${mk:+|$mk}
"; log "FALHOU ao religar $name ($tpl): gc session wake rc=$rcw"
      fi
    done <<EOF
$REG
EOF
    REG=$left
    save_state || { log "WARN: nao consegui gravar $STATE: as religadas seguem no registro (a proxima rodada as tira, sao ativas)"; failed=$((failed + 1)); }
  fi
  if [ "$failed" -gt 0 ]; then say "FALHOU na retomada: ${wl:-nada feito}; $failed passo(s) sem efeito"; return 20; fi
  if [ -n "$wl" ]; then say "swap calmo ha ${age}s (${SW_REF}MB): $wl"; return 0; fi
  say "swap calmo ha ${age}s (${SW_REF}MB): aguardando ${CALM_S}s para religar"; return 10
}

main() {
  case "${1:-}" in --run) MODE=run ;; --dry-run) MODE=dry ;; --resume) MODE=resume ;; *) usage ;; esac
  [ "$#" -eq 1 ] || usage
  [ -z "$CFG_WARN" ] || log "WARN: variavel de configuracao invalida, usei o padrao:$CFG_WARN"
  # interruptor do maestro: existe → desligado (sai 10 sem ler nem agir), também quando alguém chama este degrau à mão
  if [ -e "$OFF" ]; then say "interruptor ligado ($OFF): nao leio, nao ajo"; exit 10; fi
  NOW=$(now) || { say "SEM LEITURA: relogio ilegivel; nao decido nada"; exit 30; }
  if [ "$MODE" != dry ]; then
    mkdir -p "$GCDIR" "$(dirname "$LOG")" 2>/dev/null; rotate_log
    acquire_lock; local lrc=$?
    case "$lrc" in
      0) ;;
      1) say "outra instancia em execucao ($LOCK)"; exit 10 ;;
      *) log "SEM LEITURA: nao consegui tomar nem verificar a trava $LOCK"; say "SEM LEITURA: trava $LOCK nao tomada nem verificada; nao cortei nada"; exit 30 ;;
    esac
    trap release_lock EXIT
  fi
  case "$MODE" in
    resume) do_resume; exit $? ;;
    *) do_run; exit $? ;;
  esac
}

main "$@"
