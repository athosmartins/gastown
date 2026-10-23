#!/bin/bash
# jsonl-hourly-offsite.sh (ga-c0939v) — sobe, a cada hora, o dump JSONL do jsonl-export.sh ao S3, com manifest e verificação.
#
# POR QUÊ: todos os backups do city eram diários (S3 04:00, DoltHub 03:30, restic 04:47) = RPO 24 h. O jsonl-export.sh já arquiva o dump de todos os bancos
#   (medido em 14-16/10: um run a cada 27 min, mediana; máx 189) num repo git LOCAL; o espelho que existia (dolt-s3-backup.sh, `aws s3 sync --delete`) roda uma vez
#   por noite e copia a árvore no meio de uma escrita. Meta do Athos (15/10): perder no máximo 1 h de beads. Este script é a metade "upload"; a metade "dá para
#   restaurar" é o jsonl-hourly-restore.sh — SEM a prova de restore, um objeto no S3 não conta como RPO.
#
# O QUE SOBE (medido em 16/10: ~430 MB de árvore, ~75 MB gzip, build ~4 min com nice 15; tudo bem abaixo do limite de 5 GB do put-object)
#   jsonl-hourly/snap/<AAAAMMDDTHHMMSSZ>-<sha12 do HEAD>.tar.gz           <db>/<tabela>.jsonl de TODOS os bancos
#   jsonl-hourly/snap/<AAAAMMDDTHHMMSSZ>-<sha12>.manifest.json             contagens lidas DO ARTEFATO, sha256 por tabela, data_as_of
#   jsonl-hourly/latest.json                                               ponteiro para o último snapshot que passou em TUDO; escrito por último
#   A fonte é `git archive <sha do HEAD>`, não a árvore de trabalho: o HEAD é o único estado que o exporter garantiu completo (o gate de export curto roda antes
#   do commit). Ficam de fora os `<db>.jsonl` da raiz (cópias exatas de <db>/issues.jsonl) e as sobras `*.tmp.*` de export abortado já commitadas.
#   Bancos que casam JHO_IGNORE_DBS (padrão `bench_*,fixdepkeys_*`; "" desliga) também ficam de fora e o manifest os nomeia em `ignored_dbs`; obrigatório que case => broken.
#
# GARANTIAS (e o que cada uma NÃO garante)
#   - integridade do upload: put-object leva o sha256 calculado aqui (--checksum-sha256); o S3 recusa o objeto se os bytes
#     que chegaram não batem, e o head-object tem que devolver o mesmo tamanho E o mesmo sha256. Sem isso, o snapshot não vira "latest".
#   - legibilidade: as contagens do manifest vêm de LER o .tar.gz final tabela por tabela (o caminho que o restore percorre). Tabela ilegível, banco (não
#     ignorado) sem alguma das 6 tabelas ou banco obrigatório ausente => "broken": NADA sobe (75 MB/h de snapshot inutilizável é custo e ocuparia o piso da
#     retenção), latest.json NÃO anda, os problemas vão para o log e o run sai 1. Um banco REAL quebrado também veta (fail-closed): o acoplamento é o preço de
#     nunca anunciar como "latest" um snapshot que não restaura.
#   - queda brusca (ga-l6v576): legível não é completo — um export cortado é um documento bem formado (18/10: hq/comments com 10.112 linhas contra 35.132 do dia
#     17, manifest "ok"). O manifest é comparado com o do snapshot que latest.json aponta: tabela com >= 100 linhas no anterior que perdeu mais de 20% (e, se for
#     filha, sem queda de `issues` no mesmo banco que a explique) => "suspect": trata-se como broken (nada sobe, latest.json não anda, conta para o alerta) e o log
#     nomeia banco, tabela e os dois números. Queda de verdade (purga): UM run com JHO_ACCEPT_DROP=1 sobe o snapshot, o manifest guarda o que foi aceito e o
#     seguinte já compara com ele. Limiares: JHO_SUSPECT_DROP_PCT (20) e JHO_SUSPECT_MIN_ROWS (100). Sem anterior (1º run) o manifest diz baseline `none`; com latest.json
#     ou manifest anterior que o S3 não devolveu diz `unavailable` e o log avisa "sem régua" — o snapshot sobe mesmo assim (travar o upload por uma checagem secundária
#     pararia o RPO). NÃO garante: a defesa primária é o gate de contagem por tabela do jsonl-export.sh; uma purga real que coincida com um corte de filhos fica escondida.
#   - tabela que ficou para trás (ga-l6v576): o exporter lê as tabelas suplementares (comments, labels, ...) em páginas e só aceita a tabela se a leitura fechar; se não fecha,
#     mantém a versão do snapshot anterior e escreve ` partial=banco(tabela)` no assunto do commit. É um snapshot LEGÍVEL e sem queda — o manifest diz ok — com uma tabela velha dentro.
#     Este script lê esse `partial=` do HEAD, grava no manifest (`partial` {note, tables}) e em latest.json, e CONTA execuções seguidas com tabela atrasada (`consecutive_partial`
#     no estado): JHO_ALERT_AFTER (2) seguidas => `notify` forçado, no máx. 1 a cada JHO_ALERT_EVERY_S, com contagem e alerta próprios (não gasta o limite do alerta de falha).
#     Um HEAD limpo zera. NÃO veta o upload: as outras tabelas e os issues verificados continuam subindo (vetar pararia o RPO de tudo por causa de uma tabela).
#   - cadência (ga-c0939v.7): o order roda a cada 30 min, não a cada 1 h. Todo order `cooldown` da cidade dispara com SOBRA sobre o intervalo (mediana ~6 min, p90 ~18 min, cauda de
#     40-80 min: despacho do controller sob load 60; 706 intervalos de 8 orders). Com `1h`, 93% dos 124 gaps entre publicações do latest.json (16-23/10) passaram de 60 min, mediana 1h10.
#     Com 30 min, 3,7% dos disparos passam de 60 min; o resto é parada do controller, e quem cobre é o alarme `--age-check`. RPO real = idade do dado no HEAD que o exporter comitou +
#     tempo até a próxima publicação; `data_as_of` é quando o dado MUDOU (cidade ociosa o envelhece). Medir de novo: jsonl_hourly_cadence.py (docs/runbooks/jsonl-hourly-offsite.md).
#   - disco (ga-c0939v.7): o piso é proporcional ao pacote (need_free_mb: 2x o último pacote + 256 MB de folga, mínimo 512 MB), não 1024 MB fixos. O fixo barrou o upload com 797 MB e 867 MB
#     livres (2 runs em 7 dias, 2 h+ sem snapshot cada) para escrever um arquivo de ~175 MB. Abaixo do piso: rc 2 (conta, e o alarme de idade cobre). NÃO cobre o exporter: com o disco baixo ele se
#     espaça de propósito (ga-j2f5v5), e aí o `latest.json` continua em dia enquanto o `data_as_of` envelhece.
#
# ESTADOS (três, e o neutro é inerte): rc 0 = snapshot novo verificado, ou HEAD igual ao último verificado, objeto ainda no S3 e exporter vivo (só atualiza `checked_at`) ·
#   rc 1 = falhou, ficou "broken" ou "suspect" (queda brusca) ou FONTE PARADA: o exporter não reescreve os bancos obrigatórios (mtime de <db>/issues.jsonl) há mais de JHO_STALE_SOURCE_S (6 h), ou escreve e não
#   comita (árvore adiante de um HEAD com mais de 6 h), ou isso não foi lido => conta para o alerta e, num run de HEAD igual, não bate o ponto (`checked_at` fica, o --status vira STALE); HEAD novo
#   ainda sobe e move latest.json (um `checked_at` novo, uma vez), sem zerar a contagem. HEAD velho com a árvore igual NÃO é fonte parada: o exporter só comita quando o dado muda (7 intervalos > 6 h em 12 dias, até 10 h 22, com ele rodando) ·
#   rc 2 = não deu para avaliar (sem aws/git/python3/jq, archive ilegível, pouco disco, estado ou lock sem como criar/gravar): nada foi tentado e conta como run sem snapshot ·
#   rc 3 = uso. Outro run em andamento (pid vivo no lock) => rc 0 em silêncio.
#   (--age-check tem os próprios códigos, abaixo: 0 em dia · 1 atrasado ou ausente · 2 sem leitura.)
#
# RETENÇÃO (só no prefixo jsonl-hourly/snap/, só no formato exato de chave; depois do snapshot novo verificado):
#   últimas JHO_KEEP_RECENT_H (48) horas + o 1º snapshot de cada dia UTC até JHO_KEEP_DAILY_DAYS (14) + os JHO_KEEP_FLOOR (6) mais novos + o apontado por
#   latest.json. Apagar em bucket versionado cria delete marker; as versões antigas saem pela regra de 30 dias que já existe.
#
# ALERTA: JHO_ALERT_AFTER (2) execuções seguidas sem snapshot novo verificado (fail, unknown, ou run morto: `attempt_open` no estado, contado pelo run seguinte) =>
#   `notify` com NOTIFY_FORCE_PUSH=1 NOTIFY_STRICT_EXIT=1 (sem o force o roteador manda esta fonte ao digest mudo: rc 0, nada no telefone). Só rc 0 conta como entregue:
#   grava last_alert_epoch (no máx. 1 a cada JHO_ALERT_EVERY_S, 6 h) e loga "alerta enviado"; senão loga AVISO e o run seguinte tenta de novo.
#   Sem como gravar o estado, avisa sem esperar o 2º run e, sem registro do último aviso, a cada run: nunca mudo.
# MODO --status: lê latest.json do S3: há quanto tempo o script bateu o ponto (OK <= 75 min, o mesmo limite do --age-check => o exporter escrevia naquela hora) e quando o dado mudou (rc 0 OK, 1 STALE, 2 sem leitura ou futuro).
# MODO --age-check (ga-c0939v.7): alarme de idade, só leitura, em order próprio de 10 min (o run que atrasa não pode ser quem avisa). head-object do latest.json no S3 -> LastModified (relógio do S3, não um
#   campo que este script escreve) -> idade. TRÊS estados, e só o primeiro é "em dia":
#   rc 0 EM DIA (idade <= JHO_AGE_ALERT_S, 75 min) · rc 1 ATRASADO (acima) ou AUSENTE (404: nenhum snapshot verificado está publicado) => notify forçado na hora, no máx. 1 a cada JHO_ALERT_EVERY_S (6 h);
#   recuperou e atrasou de novo => avisa de novo na hora · rc 2 SEM LEITURA (aws/jq/python3 ausente, S3 mudo, 403, LastModified ausente, ilegível, sem fuso ou no futuro) => NUNCA "em dia": conta, e avisa na
#   JHO_AGE_UNREADABLE_AFTER-ésima (2) seguida, para uma falha de rede isolada não acordar ninguém. Estado próprio (jsonl-hourly-offsite-age-state.json), sem lock, nada escrito no S3 nem no estado do upload.
#   NÃO vê o controller parado (o order roda nele). A perna launchd que não depende dele está pronta e NÃO instalada: docs/runbooks/jsonl-hourly-offsite-age.plist.example, bead ga-c0939v.8.
#
# COSTURAS DE TESTE: JHO_LIB=1 só define funções; JHO_ARCHIVE, JHO_STATE_DIR, JHO_LOG, JHO_AWS, JHO_NOTIFY, JHO_NOW (epoch), JHO_FREE_MB (espaço livre, em MB) apontam para fixtures.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${JHO_PY:-$HERE/jsonl_hourly.py}"
CITY="${GC_CITY_PATH:-${GC_CITY:-/Users/athos/gt/.gascity-gastown-hq}}"
RUNTIME="${GC_CITY_RUNTIME_DIR:-$CITY/.gc/runtime}"
ARCHIVE="${JHO_ARCHIVE:-$RUNTIME/packs/maintenance/jsonl-archive}"
STATE_DIR="${JHO_STATE_DIR:-$RUNTIME/packs/town-deltas}"
STATE_FILE="$STATE_DIR/jsonl-hourly-offsite-state.json"
LOCKDIR="$STATE_DIR/jsonl-hourly-offsite.lock.d"
WORKROOT="$STATE_DIR/jsonl-hourly-work"
LOG="${JHO_LOG:-$CITY/.gc/logs/jsonl-hourly-offsite.log}"
BUCKET="${JHO_BUCKET:-urblink-dolt-backups}"
PREFIX="${JHO_S3_PREFIX:-jsonl-hourly}"
AWS="${JHO_AWS:-$(command -v aws || echo /opt/homebrew/bin/aws)}"
NOTIFY="${JHO_NOTIFY:-/Users/athos/.local/bin/notify}"
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
S3_TIMEOUT="${JHO_S3_TIMEOUT:-1200}"
BUILD_TIMEOUT="${JHO_BUILD_TIMEOUT:-900}"
MIN_FREE_MB="${JHO_MIN_FREE_MB:-}"                    # vazio = proporcional ao pacote (need_free_mb); um número explícito vence
MIN_FREE_FLOOR_MB="${JHO_MIN_FREE_FLOOR_MB:-512}"
MIN_FREE_SLACK_MB="${JHO_MIN_FREE_SLACK_MB:-256}"     # folga para o resto do volume (o Dolt da cidade vive nele)
ARTIFACT_GUESS_MB="${JHO_ARTIFACT_GUESS_MB:-200}"     # tamanho presumido do pacote quando o último não é legível (medido em 23/10: ~175 MB)
LOCK_STALE_MIN="${JHO_LOCK_STALE_MIN:-120}"
KEEP_RECENT_H="${JHO_KEEP_RECENT_H:-48}"
KEEP_DAILY_DAYS="${JHO_KEEP_DAILY_DAYS:-14}"
KEEP_FLOOR="${JHO_KEEP_FLOOR:-6}"
ALERT_AFTER="${JHO_ALERT_AFTER:-2}"
ALERT_EVERY_S="${JHO_ALERT_EVERY_S:-21600}"
REQUIRED_DBS="${JHO_REQUIRED_DBS:-hq,whatsapp_automation}"
# bancos de teste/benchmark que o jsonl-export arquiva (bench_hq_copy tem config/metadata com 0 bytes; fixdepkeys_* são de teste): NÃO entram no
# artefato e não vetam o snapshot. `-` e não `:-`: JHO_IGNORE_DBS="" (vazio) desliga de propósito. Um obrigatório que case com o padrão => broken.
IGNORE_DBS="${JHO_IGNORE_DBS-bench_*,fixdepkeys_*}"
AGE_ALERT_S="${JHO_AGE_ALERT_S:-4500}"                          # 75 min (ga-c0939v.7): latest.json mais velho que isso no S3 => ATRASADO
AGE_UNREADABLE_AFTER="${JHO_AGE_UNREADABLE_AFTER:-2}"           # verificações seguidas sem leitura até avisar
AGE_S3_TIMEOUT="${JHO_AGE_S3_TIMEOUT:-60}"                      # o alarme é um head-object: não espera 20 min por um S3 mudo
AGE_STATE_FILE="$STATE_DIR/jsonl-hourly-offsite-age-state.json"
MAIN_STATE_FILE="$STATE_FILE"                                   # o estado do upload: o alarme só o LÊ (contexto do aviso)
STATUS_MAX_CHECK_AGE_S="${JHO_STATUS_MAX_CHECK_AGE_S:-$AGE_ALERT_S}"   # o mesmo limite do alarme (antes 2h30, quando o order era horário)
STALE_SOURCE_S="${JHO_STALE_SOURCE_S:-21600}"                  # exporter sem reescrever os bancos obrigatórios há mais de 6 h => fonte parada (medido: runs a cada 27 min, máx 189)
# ga-tyaozh: sem isso o aws-cli embrulha o corpo num AwsChunkedWrapper que não rebobina e aborta o retry (mesma razão do dolt-s3-backup.sh)
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required

now_epoch() { echo "${JHO_NOW:-$(date +%s)}"; }
iso_now()   { python3 -I -c 'import datetime,sys;print(datetime.datetime.fromtimestamp(int(sys.argv[1]),datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$(now_epoch)"; }
stamp_now() { python3 -I -c 'import datetime,sys;print(datetime.datetime.fromtimestamp(int(sys.argv[1]),datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ"))' "$(now_epoch)"; }
log() { mkdir -p "$(dirname "$LOG")" 2>/dev/null; echo "[$(iso_now)] $*" >> "$LOG" 2>/dev/null; echo "[$(iso_now)] $*" >&2; }

# ── funções puras / de estado (testáveis em modo biblioteca) ──────────────────────────────
# O sha256 em base64 que o S3 espera em --checksum-sha256, a partir do hex.
sha256_b64() { python3 -I -c 'import base64,sys;print(base64.b64encode(bytes.fromhex(sys.argv[1])).decode())' "$1"; }

# true (0) só quando os dois números existem, são inteiros e iguais — nada de "ambos vazios = iguais".
sizes_match() {
  case "${1:-}${2:-}" in ""|*[!0-9]*) return 1 ;; esac
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ "$1" = "$2" ]
}

state_get() { # jq-path default
  local v
  if [ -f "$STATE_FILE" ] && v="$(jq -r "$1 // empty" "$STATE_FILE" 2>/dev/null)" && [ -n "$v" ]; then echo "$v"; else echo "${2:-}"; fi
}
state_write() { # json
  mkdir -p "$STATE_DIR" || return 1
  local tmp
  tmp="$(mktemp "$STATE_FILE.tmp.XXXXXX")" || return 1
  if printf '%s\n' "$1" | jq -e . > "$tmp" 2>/dev/null; then mv -f "$tmp" "$STATE_FILE"; else rm -f "$tmp"; return 1; fi
}
state_update() { # jq-filter args...  (aplica o filtro ao estado atual, ou a {} se não houver)
  local cur="{}" f="$1"; shift
  [ -f "$STATE_FILE" ] && jq -e . "$STATE_FILE" >/dev/null 2>&1 && cur="$(cat "$STATE_FILE")"
  state_write "$(printf '%s' "$cur" | jq -c "$@" "$f")"
}

# FORCE_PUSH: sem ele o roteador do notify manda esta fonte (fora da allowlist) para o digest mudo: rc 0 e nada no telefone. STRICT_EXIT: rc != 0 = não saiu. Devolve o rc.
notify_fail() { NOTIFY_FORCE_PUSH=1 NOTIFY_STRICT_EXIT=1 "$NOTIFY" -t "Jsonl hourly offsite" -p 4 "🚨 $*" >/dev/null 2>&1; }

# Conta mais uma execução sem snapshot novo e decide se avisa. $1 = motivo curto. Fecha a tentativa (attempt_open).
register_not_ok() {
  local reason="$1" n last now arc
  now="$(now_epoch)"
  n="$(state_get '.consecutive_not_ok' 0)"; n=$((n + 1))
  last="$(state_get '.last_alert_epoch' 0)"
  # contador que não grava não vira "1 seguida, sem alerta": sem como contar, avisa já
  state_update '.consecutive_not_ok = $n | .last_not_ok_reason = $r | .last_not_ok_at = $t | .attempt_open = false' --argjson n "$n" --arg r "$reason" --arg t "$(iso_now)" || { log "AVISO: não gravei o estado; sem contador, aviso já"; n=$ALERT_AFTER; }
  if [ "$n" -ge "$ALERT_AFTER" ] && [ $((now - last)) -ge "$ALERT_EVERY_S" ]; then
    notify_fail "$n execuções seguidas sem snapshot horário novo no S3 ($reason). Último bom: $(state_get '.last_success_at' nunca)"; arc=$?
    if [ $arc -eq 0 ]; then   # só rc 0 é entregue: gasta o limite de 6 h e diz "enviado"
      state_update '.last_alert_epoch = $e' --argjson e "$now" || log "AVISO: alerta saiu mas last_alert_epoch não gravou (repete no próximo run)"
      log "alerta enviado (consecutive_not_ok=$n)"
    else
      log "AVISO: alerta NÃO entregue (rc=$arc); o próximo run tenta de novo"
    fi
  fi
}

# Conta uma execução COM tabela atrasada (ou zera, se o HEAD veio limpo) e decide se avisa. $1 = nota `partial=` do HEAD ("" = limpo). Roda em todo run que termina com o
# snapshot (novo ou o mesmo, já no S3) válido — o `partial` é propriedade do HEAD, e um HEAD parado com a tabela atrasada continua atrasando a cada hora que passa.
register_partial() {
  local note="$1" n last now arc
  now="$(now_epoch)"
  if [ -z "$note" ]; then
    state_update '.consecutive_partial = 0 | .last_partial_note = ""' || log "AVISO: estado não gravado (o contador de tabela atrasada pode ficar sem zerar)"
    return 0
  fi
  n="$(state_get '.consecutive_partial' 0)"; n=$((n + 1))
  last="$(state_get '.last_partial_alert_epoch' 0)"
  log "AVISO: o HEAD $SHA12 carrega tabela atrasada ($note): $n execução(ões) seguida(s)"
  # contador que não grava não vira "1 seguida, sem alerta": sem como contar, avisa já (mesma regra do register_not_ok)
  state_update '.consecutive_partial = $n | .last_partial_note = $p' --argjson n "$n" --arg p "$note" || { log "AVISO: não gravei o estado; sem contador de tabela atrasada, aviso já"; n=$ALERT_AFTER; }
  if [ "$n" -ge "$ALERT_AFTER" ] && [ $((now - last)) -ge "$ALERT_EVERY_S" ]; then
    notify_fail "$n execuções seguidas com tabela atrasada no snapshot horário ($note): o exporter não conseguiu ler a tabela inteira e manteve a versão anterior. O snapshot sobe, mas essa tabela não está sendo salva a cada hora."; arc=$?
    if [ $arc -eq 0 ]; then
      state_update '.last_partial_alert_epoch = $e' --argjson e "$now" || log "AVISO: alerta saiu mas last_partial_alert_epoch não gravou (repete no próximo run)"
      log "alerta de tabela atrasada enviado (consecutive_partial=$n)"
    else
      log "AVISO: alerta de tabela atrasada NÃO entregue (rc=$arc); o próximo run tenta de novo"
    fi
  fi
}

# Quanto disco livre o run exige: 2x o último pacote (o tar.gz + uma cópia de folga) + MIN_FREE_SLACK_MB, nunca menos que MIN_FREE_FLOOR_MB. JHO_MIN_FREE_MB explícito vence.
# vazio → palpite (ARTIFACT_GUESS_MB); falhou/ilegível → palpite também (state_get devolve o default nos dois): sem tamanho legível, texto, 0 ou ausente nunca vira "não precisa de nada".
need_free_mb() {
  local b mb need
  if [ -n "$MIN_FREE_MB" ]; then echo "$MIN_FREE_MB"; return 0; fi
  b="$(state_get '.last_success_bytes' '')"
  case "$b" in ""|*[!0-9]*) mb="$ARTIFACT_GUESS_MB" ;; *) mb=$(( (b + 1048575) / 1048576 )); [ "$mb" -ge 1 ] || mb="$ARTIFACT_GUESS_MB" ;; esac
  need=$(( 2 * mb + MIN_FREE_SLACK_MB ))
  [ "$need" -ge "$MIN_FREE_FLOOR_MB" ] || need="$MIN_FREE_FLOOR_MB"
  echo "$need"
}

# Idade, em segundos, de um LastModified (ISO-8601 com fuso, do aws-cli v2, ou RFC 1123, do v1) no instante $2 (epoch). Sai 1 e não escreve nada se não for uma data COM fuso:
# sem fuso não dá para saber a hora, e sem hora não há idade.
lm_age_s() { # lastmodified now_epoch
  python3 -I -c '
import datetime, email.utils, sys
s, now = sys.argv[1], int(sys.argv[2])
try:
    d = datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
except ValueError:
    try:
        d = email.utils.parsedate_to_datetime(s)
    except (TypeError, ValueError):
        sys.exit(1)
if d.tzinfo is None:
    sys.exit(1)
print(now - int(d.timestamp()))' "$1" "$2" 2>/dev/null
}

# Mesmo contrato do notify_fail (push forçado, saída estrita, só rc 0 é entregue), com título próprio: aqui o aviso é "o S3 está velho", não "um run falhou".
notify_age() { NOTIFY_FORCE_PUSH=1 NOTIFY_STRICT_EXIT=1 "$NOTIFY" -t "Jsonl offsite: S3 atrasado" -p 4 "🚨 $*" >/dev/null 2>&1; }

# Aviso do alarme, no máx. 1 a cada ALERT_EVERY_S. Só rc 0 conta como entregue: grava last_alert_epoch; senão AVISO e o run seguinte tenta de novo.
# Sem como ler/gravar o estado do alarme o limite não existe e o aviso sai a cada run: nunca mudo.
age_alert() { # texto
  local now last arc
  now="$(now_epoch)"; last="$(state_get '.last_alert_epoch' 0)"
  [ $((now - last)) -ge "$ALERT_EVERY_S" ] || return 0
  notify_age "$*"; arc=$?
  if [ $arc -eq 0 ]; then
    state_update '.last_alert_epoch = $e' --argjson e "$now" || log "IDADE: AVISO: alerta saiu mas last_alert_epoch não gravou (repete no próximo run)"
    log "IDADE: alerta enviado"
  else
    log "IDADE: AVISO: alerta NÃO entregue (rc=$arc); o próximo run tenta de novo"
  fi
}

# Não consegui medir a idade (ferramenta ausente, S3 mudo, 403, LastModified ausente/ilegível/no futuro): NÃO é "em dia". Conta; avisa na AGE_UNREADABLE_AFTER-ésima seguida.
age_unreadable() { # motivo
  local reason="$1" n
  n="$(state_get '.consecutive_unreadable' 0)"; n=$((n + 1))
  state_update '.consecutive_unreadable = $n | .last_check_at = $t | .last_state = "unreadable" | .last_reason = $r' --argjson n "$n" --arg t "$(iso_now)" --arg r "$reason" \
    || { log "IDADE: AVISO: não gravei o estado do alarme; sem contador, aviso já"; n=$AGE_UNREADABLE_AFTER; }
  log "IDADE: SEM LEITURA ($n seguida(s)): $reason"
  echo "AGE: UNKNOWN $reason"
  if [ "$n" -ge "$AGE_UNREADABLE_AFTER" ]; then
    age_alert "não consegui medir a idade do latest.json no S3 ($n verificações seguidas sem leitura): $reason. Sem leitura não é 'em dia': o upload horário pode estar parado sem ninguém ver."
  fi
  exit 2
}

# Contexto SÓ para o texto do aviso: o que o upload sabe de si (estado dele, lido e nunca escrito). Motivo só quando há falhas seguidas: com 0 ele é o da última falha de dias atrás.
# vazio → sem contexto; falhou/ilegível → sem contexto: o aviso sai igual, ele não depende disto.
age_context() {
  local ok n why
  ok="$(jq -r '.last_success_at // empty' "$MAIN_STATE_FILE" 2>/dev/null)"; n="$(jq -r '.consecutive_not_ok // empty' "$MAIN_STATE_FILE" 2>/dev/null)"
  case "$n" in ""|*[!0-9]*) n="" ;; esac
  why=""; if [ -n "$n" ] && [ "$n" -gt 0 ]; then why="$(jq -r '.last_not_ok_reason // empty' "$MAIN_STATE_FILE" 2>/dev/null)"; fi
  [ -n "$ok$n" ] || return 0
  printf ' Estado do upload: último ok %s; %s run(s) seguido(s) sem snapshot novo%s.' "${ok:-?}" "${n:-?}" "${why:+ (último motivo: $why)}"
}

s3key_artifact() { echo "$PREFIX/snap/$1.tar.gz"; }       # $1 = stem <stamp>-<sha12>
s3key_manifest() { echo "$PREFIX/snap/$1.manifest.json"; }
s3key_latest()   { echo "$PREFIX/latest.json"; }

# aws s3api com timeout; stdout = JSON da resposta, rc = rc do aws.
s3api() { "$TIMEOUT_BIN" "$S3_TIMEOUT" "$AWS" s3api "$@"; }

# head-object -> JSON em stdout; rc 0 existe, 1 não existe (404), 2 erro de outra natureza (não sei).
s3_head() { # key
  local out rc
  out="$(s3api head-object --bucket "$BUCKET" --key "$1" --checksum-mode ENABLED --output json 2>&1)"; rc=$?
  if [ $rc -eq 0 ]; then printf '%s' "$out"; return 0; fi
  case "$out" in *"Not Found"*|*"(404)"*|*NoSuchKey*) return 1 ;; esac   # "404" solto casaria com qualquer erro que o cite (id de request, 403...)
  printf '%s' "$out" >&2; return 2
}

# put-object de um arquivo com sha256 conferido pelo S3. $1=key $2=arquivo $3=sha256 hex $4=content-type
s3_put_verified() {
  local key="$1" file="$2" sha="$3" ctype="${4:-application/octet-stream}" b64 bytes head len cs
  b64="$(sha256_b64 "$sha")" || return 1
  bytes="$(wc -c < "$file" | tr -d ' ')"
  s3api put-object --bucket "$BUCKET" --key "$key" --body "$file" --content-type "$ctype" \
        --checksum-algorithm SHA256 --checksum-sha256 "$b64" --output json >/dev/null 2>>"$LOG" || { log "put-object de $key falhou"; return 1; }
  head="$(s3_head "$key")" || { log "head-object de $key falhou depois do put"; return 1; }
  len="$(printf '%s' "$head" | jq -r '.ContentLength // empty')"
  cs="$(printf '%s' "$head" | jq -r '.ChecksumSHA256 // empty')"
  sizes_match "$len" "$bytes" || { log "$key: tamanho no S3 ($len) != local ($bytes)"; return 1; }
  [ -n "$cs" ] && [ "$cs" = "$b64" ] || { log "$key: sha256 no S3 ('$cs') != local ('$b64')"; return 1; }
  return 0
}

if [ "${JHO_LIB:-0}" = "1" ]; then return 0 2>/dev/null || exit 0; fi

# ═════════════════════════════ execução ═════════════════════════════════════════════════
MODE="run"
case "${1:-}" in
  --status) MODE="status" ;;
  --age-check) MODE="age"; STATE_FILE="$AGE_STATE_FILE"; S3_TIMEOUT="$AGE_S3_TIMEOUT" ;;   # estado e timeout próprios; o do upload (MAIN_STATE_FILE) só é lido
  "") ;;
  -h|--help) sed -n '2,/^set -uo/{/^set -uo/!p;}' "${BASH_SOURCE[0]}"; exit 0 ;;
  *) echo "uso: jsonl-hourly-offsite.sh [--status | --age-check]" >&2; exit 3 ;;
esac

unknown() { # rc 2, sem veredito. Em run conta como run sem snapshot (antes só stderr: PATH sem /opt/homebrew/bin falhava toda hora, mudo); em --age-check conta como verificação sem leitura; em --status só diz
  if [ "$MODE" = run ]; then log "UNKNOWN: $*"; register_not_ok "unknown: $*"; echo "RESULT: unknown $*"
  elif [ "$MODE" = age ]; then age_unreadable "$*"
  else echo "UNKNOWN: $*" >&2; fi
  exit 2
}
NEED_TOOLS="jq git python3"; [ "$MODE" != age ] || NEED_TOOLS="jq python3"   # o alarme só lê o S3: não usa git nem o helper
[ -n "$TIMEOUT_BIN" ] || unknown "timeout (GNU) ausente"
for t in $NEED_TOOLS; do command -v "$t" >/dev/null 2>&1 || unknown "$t ausente"; done
[ -x "$AWS" ] || command -v "$AWS" >/dev/null 2>&1 || unknown "aws ausente ($AWS)"
[ "$MODE" = age ] || [ -f "$PY" ] || unknown "helper ausente: $PY"

# ── --status ─────────────────────────────────────────────────────────────────────────────
if [ "$MODE" = status ]; then
  tmp="$(mktemp "${TMPDIR:-/tmp}/jho-status.XXXXXX")" || exit 2
  trap 'rm -f "$tmp"' EXIT
  if ! s3api get-object --bucket "$BUCKET" --key "$(s3key_latest)" "$tmp" >/dev/null 2>&1; then
    echo "STATUS: UNKNOWN não li $(s3key_latest) no S3"; exit 2
  fi
  checked="$(jq -r '.checked_at // empty' "$tmp")"; asof="$(jq -r '.data_as_of // empty' "$tmp")"
  [ -n "$checked" ] && [ -n "$asof" ] || { echo "STATUS: UNKNOWN latest.json sem checked_at/data_as_of"; exit 2; }
  ages="$(python3 -I -c '
import datetime,sys
def ep(s): return int(datetime.datetime.strptime(s,"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp())
now=int(sys.argv[3]); print(now-ep(sys.argv[1]), now-ep(sys.argv[2]))' "$checked" "$asof" "$(now_epoch)")" || { echo "STATUS: UNKNOWN datas ilegíveis"; exit 2; }
  check_age="${ages% *}"; asof_age="${ages#* }"
  [ "$check_age" -ge 0 ] || { echo "STATUS: UNKNOWN checked_at no futuro (${check_age}s)"; exit 2; }   # idade negativa não é "recente"
  if [ "$check_age" -le "$STATUS_MAX_CHECK_AGE_S" ]; then verdict=OK; rc=0; else verdict=STALE; rc=1; fi
  # third-state-waiver: o veredito (OK/STALE) já saiu das datas acima; esta leitura só monta o texto da linha (vazio = latest.json sem `partial`, que é o normal)
  echo "STATUS: $verdict checked_at=$checked (há ${check_age}s) data_as_of=$asof (há ${asof_age}s) snapshot=$(jq -r '.snapshot_key' "$tmp")$(jq -r 'if (.partial // "") != "" then " partial=" + .partial else "" end' "$tmp" 2>/dev/null)"
  exit $rc
fi

# ── --age-check (ga-c0939v.7) ─────────────────────────────────────────────────────────────────────────
if [ "$MODE" = age ]; then
  now="$(now_epoch)"
  herr="$(mktemp "${TMPDIR:-/tmp}/jho-age.XXXXXX")" || unknown "mktemp falhou"
  trap 'rm -f "$herr"' EXIT
  # head-object do latest.json: 0 existe · 1 não existe (404) · 2 não sei (403, rede, timeout).
  # vazio → 404: o objeto não existe, nenhum snapshot verificado está publicado: AUSENTE, rc 1, avisa já; falhou/ilegível (rc 2) → SEM LEITURA, nunca "em dia"
  hjson="$(s3_head "$(s3key_latest)" 2>"$herr")"; hrc=$?
  if [ $hrc -eq 1 ]; then
    ctx="$(age_context)"
    state_update '.consecutive_unreadable = 0 | .last_check_at = $t | .last_state = "missing"' --arg t "$(iso_now)" || log "IDADE: AVISO: estado do alarme não gravado (sem relógio de aviso, o aviso sai a cada run)"
    log "IDADE: AUSENTE: $(s3key_latest) não existe em s3://$BUCKET$ctx"
    echo "AGE: MISSING $(s3key_latest) não existe em s3://$BUCKET"
    age_alert "o latest.json do upload horário NÃO EXISTE no S3 (s3://$BUCKET/$(s3key_latest)): nenhum snapshot verificado está publicado.$ctx"
    exit 1
  elif [ $hrc -ne 0 ]; then
    unknown "S3 não respondeu ao head-object de $(s3key_latest): $(tail -c 200 "$herr" | tr '\n' ' ')"
  fi
  # vazio → o head-object veio sem LastModified: SEM LEITURA; falhou/ilegível (jq, data sem fuso, lixo) → SEM LEITURA também
  lm="$(printf '%s' "$hjson" | jq -r '.LastModified // empty' 2>/dev/null)"
  [ -n "$lm" ] || unknown "head-object de $(s3key_latest) sem LastModified"
  age="$(lm_age_s "$lm" "$now")" || unknown "LastModified ilegível ou sem fuso horário: '$lm'"
  [[ "$age" =~ ^-?[0-9]+$ ]] || unknown "idade ilegível ('$age') para o LastModified '$lm'"
  # relógio daqui ou do S3 fora de hora: idade negativa grande não é "recente" (até 5 min de diferença é tolerada e vale idade 0)
  if [ "$age" -lt -300 ]; then unknown "LastModified $lm está ${age#-}s no futuro: relógio daqui ou do S3 fora de hora"; fi
  [ "$age" -ge 0 ] || age=0
  prev="$(state_get '.last_state' '')"
  if [ "$age" -le "$AGE_ALERT_S" ]; then
    state_update '.consecutive_unreadable = 0 | .last_alert_epoch = 0 | .last_check_at = $t | .last_state = "ok" | .last_age_s = $a' --arg t "$(iso_now)" --argjson a "$age" || log "IDADE: AVISO: estado do alarme não gravado"
    case "$prev" in late|missing|unreadable) log "IDADE: voltou ao normal (latest.json com ${age}s; antes: $prev)" ;; esac
    echo "AGE: OK age=${age}s limit=${AGE_ALERT_S}s last_modified=$lm"
    exit 0
  fi
  ctx="$(age_context)"
  state_update '.consecutive_unreadable = 0 | .last_check_at = $t | .last_state = "late" | .last_age_s = $a' --arg t "$(iso_now)" --argjson a "$age" || log "IDADE: AVISO: estado do alarme não gravado (sem relógio de aviso, o aviso sai a cada run)"
  log "IDADE: ATRASADO: latest.json com ${age}s (limite ${AGE_ALERT_S}s, LastModified $lm)$ctx"
  echo "AGE: LATE age=${age}s limit=${AGE_ALERT_S}s last_modified=$lm"
  age_alert "latest.json no S3 tem $((age / 60)) min (limite $((AGE_ALERT_S / 60)) min): o upload horário do JSONL não renovou o objeto desde $lm.$ctx"
  exit 1
fi

# ── lock (mkdir atômico; dono = pid; reclama se o dono morreu ou passou de LOCK_STALE_MIN) ─────────────
mkdir -p "$STATE_DIR" || unknown "não criei $STATE_DIR"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  [ -d "$LOCKDIR" ] || unknown "não consegui criar o lock $LOCKDIR"   # mkdir falhou e não há lock (sem permissão, disco cheio, FS só-leitura): não é "outro run", é "não sei"; rc 0 pararia upload e alerta em silêncio
  holder="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
  # sem pid ainda NÃO é dono morto: o outro run fez o mkdir e ainda não gravou o pid. Só reclama depois de 1 min.
  if [ -z "$holder" ] && [ -z "$(find "$LOCKDIR" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
    log "lock sem pid e com menos de 1 min: outro run está começando; saindo"; exit 0
  fi
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null && [ -z "$(find "$LOCKDIR" -maxdepth 0 -mmin +"$LOCK_STALE_MIN" 2>/dev/null)" ]; then
    log "outro run em andamento (pid $holder); saindo"; exit 0
  fi
  log "lock de pid '$holder' morto ou com mais de ${LOCK_STALE_MIN} min: reclamando"
  case "$LOCKDIR" in */jsonl-hourly-offsite.lock.d) rm -rf "$LOCKDIR" ;; esac
  mkdir "$LOCKDIR" 2>/dev/null || {   # "outro run pegou antes" só com um pid VIVO e diferente do dono morto; pid vazio/ilegível ou lock que não saiu (rm -rf falhou) → não sei, conta
    h2="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"; [ -n "$h2" ] && [ "$h2" != "$holder" ] && kill -0 "$h2" 2>/dev/null && { log "outro run reclamou o lock antes (pid $h2); saindo"; exit 0; }
    unknown "não consegui pegar o lock $LOCKDIR"; }
fi
echo $$ > "$LOCKDIR/pid"
WD="$WORKROOT/run.$$"
cleanup() {
  case "$LOCKDIR" in */jsonl-hourly-offsite.lock.d) rm -rf "$LOCKDIR" ;; esac
  case "$WD" in "$WORKROOT"/run.*) rm -rf "$WD" ;; esac
}
trap cleanup EXIT
# sobras de runs mortos (só o nosso padrão, só com mais de 3 h)
if [ -d "$WORKROOT" ]; then find "$WORKROOT" -maxdepth 1 -name 'run.*' -type d -mmin +180 -exec rm -rf {} + 2>/dev/null; fi
mkdir -p "$WD"

START="$(now_epoch)"
# run que começou e nunca registrou desfecho (morto pelo timeout do order, kill, reboot) deixou attempt_open: conta agora como run sem snapshot
# vazio → false (não há run morto); falhou/ilegível → false também: sem prova de run morto, o inerte é não contar (o AVISO de estado não gravado já grita)
if [ "$(state_get '.attempt_open' false)" = true ]; then log "run anterior não terminou (timeout do order, kill ou reboot): conta como run sem snapshot"; register_not_ok "run anterior não terminou"; fi
state_update '.last_attempt_at = $t | .attempt_open = true' --arg t "$(iso_now)" || log "AVISO: não gravei o estado"

# ── pré-voo: tudo aqui é rc 2 (sem veredito), nada foi tentado ───────────────────────────────
git -C "$ARCHIVE" rev-parse --git-dir >/dev/null 2>&1 || unknown "archive não é um repo git: $ARCHIVE"
SHA="$(git -C "$ARCHIVE" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" || unknown "archive sem HEAD"
HEAD_EPOCH="$(git -C "$ARCHIVE" log -1 --format=%ct "$SHA" 2>/dev/null)"
case "$HEAD_EPOCH" in ""|*[!0-9]*) unknown "não li a data do HEAD $SHA" ;; esac
# o assunto do commit do exporter termina em ` partial=banco(tabela),...` quando alguma tabela ficou com a versão anterior (ga-l6v576). vazio → sem `partial=` (HEAD limpo);
# falhou → não sei, e não sei não é limpo: rc 2, nada foi tentado (como a data do HEAD logo acima, que sai do mesmo commit)
HEAD_SUBJ="$(git -C "$ARCHIVE" log -1 --format=%s "$SHA" 2>/dev/null)" || unknown "não li o assunto do HEAD $SHA"
PARTIAL_NOTE=""
case "$HEAD_SUBJ" in *" partial="*) PARTIAL_NOTE="${HEAD_SUBJ##* partial=}"; PARTIAL_NOTE="${PARTIAL_NOTE%% *}" ;; esac
# vazio → o df não respondeu; falhou/ilegível → idem: sem número não há veredito (rc 2), nunca "tem espaço". JHO_FREE_MB é só para os testes.
FREE="${JHO_FREE_MB:-$(df -Pk "$STATE_DIR" | awk 'NR==2 {print int($4/1024)}')}"
case "$FREE" in ""|*[!0-9]*) unknown "não li o espaço livre em $STATE_DIR (leitura: '${FREE:-vazia}')" ;; esac
NEED_MB="$(need_free_mb)"
if [ -n "$MIN_FREE_MB" ]; then NEED_WHY="JHO_MIN_FREE_MB"; else NEED_WHY="2x o último pacote + ${MIN_FREE_SLACK_MB} MB de folga, mínimo ${MIN_FREE_FLOOR_MB} MB"; fi
[ "$FREE" -ge "$NEED_MB" ] || unknown "pouco disco em $STATE_DIR (${FREE} MB livres < ${NEED_MB} MB: $NEED_WHY)"

SHA12="${SHA:0:12}"
STAMP="$(stamp_now)"
STEM="$STAMP-$SHA12"
HEAD_AGE=$(( $(now_epoch) - HEAD_EPOCH ))
# HEAD velho NÃO é exporter parado: ele só comita quando o dado muda (números no cabeçalho). Vivo = reescreveu os bancos obrigatórios (mtime de <db>/issues.jsonl; vale o mais velho). vazio/ilegível/ausente → não sei, e não sei não é vivo; falhou → idem.
SRC_WHY=""; SRC_EPOCH="$(python3 -I -c 'import os,sys;print(min(int(os.stat(os.path.join(sys.argv[1],d,"issues.jsonl")).st_mtime) for d in sys.argv[2].split(",")))' "$ARCHIVE" "$REQUIRED_DBS" 2>/dev/null)"
case "$SRC_EPOCH" in
  ""|*[!0-9]*) SRC_WHY="não li quando o exporter escreveu os bancos obrigatórios ($REQUIRED_DBS)" ;;
  *) SRC_AGE=$(( $(now_epoch) - SRC_EPOCH )); [ "$SRC_AGE" -le "$STALE_SOURCE_S" ] || SRC_WHY="o exporter não reescreve os bancos obrigatórios há ${SRC_AGE}s (> ${STALE_SOURCE_S}s; HEAD de há ${HEAD_AGE}s)" ;;
esac
# Escrever não é comitar: com a árvore do archive ADIANTE do HEAD e o HEAD velho o exporter escreve e não comita (16/10: runs mortos em ~5 min, 16 arquivos sujos, HEAD parado há 7 h 30).
# Árvore = HEAD é ocioso, ok. git diff: 0 igual · 1 adiante · outro (falhou) → não sei, e não sei não é vivo.
if [ -z "$SRC_WHY" ] && [ "$HEAD_AGE" -gt "$STALE_SOURCE_S" ]; then
  IFS=, read -r -a DBV <<< "$REQUIRED_DBS"; git -C "$ARCHIVE" diff --quiet HEAD -- "${DBV[@]}" 2>/dev/null
  case $? in 0) ;; 1) SRC_WHY="o exporter escreve mas não comita: a árvore do archive está adiante do HEAD, que tem ${HEAD_AGE}s (> ${STALE_SOURCE_S}s)" ;; *) SRC_WHY="não consegui comparar a árvore do archive com o HEAD" ;; esac
fi
[ -z "$SRC_WHY" ] || log "AVISO: fonte parada: $SRC_WHY"
fail() { log "FALHOU: $*"; register_not_ok "$*"; echo "RESULT: fail $*"; exit 1; }

# ── HEAD igual ao último verificado e o objeto ainda existe: só bate o ponto ───────────────────────
LAST_SHA="$(state_get '.last_success_sha' '')"; LAST_KEY="$(state_get '.last_success_key' '')"
if [ "$LAST_SHA" = "$SHA" ] && [ -n "$LAST_KEY" ]; then
  s3_head "$LAST_KEY" >/dev/null; hrc=$?
  if [ $hrc -eq 0 ]; then
    [ -z "$SRC_WHY" ] || fail "fonte parada: $SRC_WHY"   # bater o ponto diria "verificado agora"; sem checked_at novo o --status vira STALE sozinho
    LAST_STEM="$(basename "${LAST_KEY%.tar.gz}")"
    cur="$(mktemp "$WD/latest.XXXXXX")"
    # vazio/sem snapshot_key/de outro snapshot → não bate o ponto, vai para o snapshot novo; falhou/ilegível → idem (nunca reescreve um latest.json que não é o nosso)
    if s3api get-object --bucket "$BUCKET" --key "$(s3key_latest)" "$cur" >/dev/null 2>&1 && jq -e --arg k "$LAST_KEY" '.snapshot_key == $k' "$cur" >/dev/null 2>&1; then
      jq --arg t "$(iso_now)" '.checked_at = $t' "$cur" > "$WD/latest.new" 2>/dev/null \
        && LSHA="$(python3 -I -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$WD/latest.new")" \
        && s3_put_verified "$(s3key_latest)" "$WD/latest.new" "$LSHA" application/json \
        && { state_update '.consecutive_not_ok = 0 | .attempt_open = false | .last_check_at = $t' --arg t "$(iso_now)" || log "AVISO: estado não gravado (o contador de falhas pode ficar sem zerar)"
             register_partial "$PARTIAL_NOTE"
             log "HEAD $SHA12 já está no S3 ($LAST_STEM): ponto batido"; echo "RESULT: ok unchanged key=$LAST_KEY head_age_s=$HEAD_AGE"; exit 0; }
      log "não consegui reescrever latest.json; sigo para um snapshot novo"
    else
      log "latest.json não lido, ilegível ou de outro snapshot; sigo para um snapshot novo"
    fi
  elif [ $hrc -eq 2 ]; then
    unknown "S3 não respondeu ao head-object de $LAST_KEY"
  else
    log "último snapshot ($LAST_KEY) sumiu do S3: subindo de novo"
  fi
fi

# ── build: git archive do HEAD -> tar.gz filtrado ──────────────────────────────────────────────────
log "snapshot $STEM (HEAD $SHA12, dado de há ${HEAD_AGE}s)"
set -o pipefail
( git -C "$ARCHIVE" archive --format=tar "$SHA" | nice -n 15 "$TIMEOUT_BIN" "$BUILD_TIMEOUT" python3 -I "$PY" build --out "$WD/snap.tar.gz" --files-out "$WD/files.json" --ignore-db "$IGNORE_DBS" ) > "$WD/build.out" 2> "$WD/build.err" \
  || fail "build do artefato falhou: $(tail -c 300 "$WD/build.err" "$WD/build.out" 2>/dev/null | tr '\n' ' ')"
nice -n 15 "$TIMEOUT_BIN" "$BUILD_TIMEOUT" python3 -I "$PY" inspect "$WD/snap.tar.gz" > "$WD/inspect.json" 2> "$WD/inspect.err"
irc=$?
[ -s "$WD/inspect.json" ] || fail "inspect não produziu saída (rc=$irc): $(tail -c 300 "$WD/inspect.err" | tr '\n' ' ')"
ART="$(s3key_artifact "$STEM")"
# ── régua (ga-l6v576): o manifest do último snapshot que passou em tudo = latest.json -> manifest_key ─────────────────────────────────────
# Três estados, e nenhum vira "sem queda" em silêncio: sem latest.json no S3 (404) = 1º run, `none`; latest.json que existe e não consegui ler, ou o
# manifest que ele aponta, = `unavailable` (o manifest guarda o motivo e o log avisa); lido = `compared`. Sem régua o snapshot sobe igual: um
# comparador que travasse o upload pararia o RPO de 1 h por causa de uma checagem secundária (a primária é o gate de contagem do jsonl-export.sh).
BASE_WHY=""
s3_head "$(s3key_latest)" >/dev/null 2>&1; lrc=$?
if [ $lrc -eq 1 ]; then :   # latest.json não existe: 1º run, régua none (s3_head: 0 existe, 1 não existe, 2 não deu para saber)
elif [ $lrc -ne 0 ]; then BASE_WHY="S3 não respondeu ao head-object de latest.json (rc $lrc)"
else
  if ! s3api get-object --bucket "$BUCKET" --key "$(s3key_latest)" "$WD/prev.latest.json" >/dev/null 2>&1; then BASE_WHY="latest.json existe e o S3 não o devolveu"
  else
    PREV_MKEY="$(jq -r '.manifest_key // empty' "$WD/prev.latest.json" 2>/dev/null)"
    if [ -z "$PREV_MKEY" ]; then BASE_WHY="latest.json sem manifest_key legível"   # jq falhou ou a chave não existe: os dois dão régua indisponível, nunca "sem anterior"
    elif ! s3api get-object --bucket "$BUCKET" --key "$PREV_MKEY" "$WD/prev.manifest.json" >/dev/null 2>&1; then BASE_WHY="o S3 não devolveu o manifest anterior ($PREV_MKEY)"
    fi
  fi
fi
BASE_FLAG=""; BASE_VAL=""
if [ -n "$BASE_WHY" ]; then BASE_FLAG=--baseline-unavailable; BASE_VAL="$BASE_WHY"; log "AVISO: sem régua: $BASE_WHY; a queda brusca de tabela NÃO foi checada neste snapshot"
elif [ $lrc -eq 0 ]; then BASE_FLAG=--previous; BASE_VAL="$WD/prev.manifest.json"   # o S3 o devolveu: vazio ou ilegível o python diz `unavailable`, nunca `none`
fi
ACCEPT_FLAG=""; [ "${JHO_ACCEPT_DROP:-0}" = 1 ] && { ACCEPT_FLAG=--accept-drop; log "JHO_ACCEPT_DROP=1: queda brusca aceita por quem opera, só neste run"; }
python3 -I "$PY" manifest --inspect "$WD/inspect.json" --built "$WD/files.json" --captured-epoch "$(now_epoch)" --head-epoch "$HEAD_EPOCH" \
  --head-sha "$SHA" --key "$ART" --require "$REQUIRED_DBS" ${BASE_FLAG:+"$BASE_FLAG" "$BASE_VAL"} ${ACCEPT_FLAG:+"$ACCEPT_FLAG"} ${PARTIAL_NOTE:+--partial "$PARTIAL_NOTE"} \
  ${JHO_SUSPECT_DROP_PCT:+--suspect-drop-pct "$JHO_SUSPECT_DROP_PCT"} ${JHO_SUSPECT_MIN_ROWS:+--suspect-min-rows "$JHO_SUSPECT_MIN_ROWS"} \
  > "$WD/manifest.json" 2> "$WD/manifest.err"
mrc=$?
[ -s "$WD/manifest.json" ] || fail "manifest não gerado: $(tail -c 300 "$WD/manifest.err" | tr '\n' ' ')"
VERDICT="$(jq -r '.verdict' "$WD/manifest.json")"
ART_SHA="$(jq -r '.artifact.sha256' "$WD/manifest.json")"; ART_BYTES="$(jq -r '.artifact.bytes' "$WD/manifest.json")"
sizes_match "$ART_BYTES" "$(wc -c < "$WD/snap.tar.gz" | tr -d ' ')" || fail "bytes do manifest != bytes do arquivo"
# broken não sobe NADA: ~75 MB por hora de um snapshot declarado inutilizável não é "cópia a mais", é custo e ruído, e ocuparia o piso da
# retenção no lugar de um bom. Os problemas inteiros vão para o log (o alerta leva o começo); a próxima hora tenta de novo com o HEAD seguinte.
if [ "$VERDICT" != ok ] || [ $mrc -ne 0 ]; then
  jq -r '.problems[]' "$WD/manifest.json" 2>/dev/null | while IFS= read -r pb; do log "problema: $pb"; done
  jq -r '.suspect[]?' "$WD/manifest.json" 2>/dev/null | while IFS= read -r sp; do log "suspeito: $sp"; done
  # suspect = legível, mas uma tabela caiu contra o anterior sem explicação (em 18/10 o hq/comments saiu com 71% a menos e o manifest dizia ok): é o mesmo
  # veto do broken — NADA sobe, latest.json fica no último bom, conta para o alerta. Se a queda é de verdade (purga), quem opera roda UMA vez com JHO_ACCEPT_DROP=1.
  if [ "$VERDICT" = suspect ]; then
    # third-state-waiver: o veredito suspect já foi decidido por jq -r .verdict acima; esta leitura só monta o texto do log (vazio no pior caso)
    fail "snapshot $STEM suspect ($(jq -r '.suspect | join("; ")' "$WD/manifest.json" | head -c 400)); NADA subiu, latest.json não andou; queda de verdade (purga)? rode uma vez com JHO_ACCEPT_DROP=1"
  fi
  fail "snapshot $STEM broken ($(jq -r '.problems | join("; ")' "$WD/manifest.json" | head -c 400)); NADA subiu, latest.json não andou"
fi

# ── upload: artefato, manifest e, só depois, latest.json ──────────────────────────────────────────────
s3_put_verified "$ART" "$WD/snap.tar.gz" "$ART_SHA" application/gzip || fail "upload do artefato não verificou"
MAN_SHA="$(python3 -I -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$WD/manifest.json")"
s3_put_verified "$(s3key_manifest "$STEM")" "$WD/manifest.json" "$MAN_SHA" application/json || fail "upload do manifest não verificou"
jq -n --arg key "$ART" --arg mkey "$(s3key_manifest "$STEM")" --arg sha "$ART_SHA" --argjson bytes "$ART_BYTES" \
      --arg asof "$(jq -r '.data_as_of' "$WD/manifest.json")" --arg cap "$(jq -r '.captured_at' "$WD/manifest.json")" \
      --arg head "$SHA" --arg chk "$(iso_now)" --argjson db "$(jq -c '.databases | map_values(.issues)' "$WD/manifest.json")" --arg partial "$PARTIAL_NOTE" \
      '{schema:1, snapshot_key:$key, manifest_key:$mkey, sha256:$sha, bytes:$bytes, data_as_of:$asof, captured_at:$cap, checked_at:$chk, source_head:$head, issues_per_db:$db}
       + (if $partial == "" then {} else {partial:$partial} end)' > "$WD/latest.json" \
  || fail "não montei latest.json (jq falhou): nada foi publicado como ponteiro"
LSHA="$(python3 -I -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$WD/latest.json")"
s3_put_verified "$(s3key_latest)" "$WD/latest.json" "$LSHA" application/json || fail "upload de latest.json não verificou"

ZERO='.consecutive_not_ok = 0 | '; [ -z "$SRC_WHY" ] || ZERO=""   # fonte parada: o upload valeu, mas a contagem de não-ok não zera
state_update "$ZERO"'.attempt_open = false | .last_success_at = $t | .last_success_sha = $s | .last_success_key = $k | .last_success_bytes = $b | .last_success_data_as_of = $a' \
  --arg t "$(iso_now)" --arg s "$SHA" --arg k "$ART" --argjson b "$ART_BYTES" --arg a "$(jq -r '.data_as_of' "$WD/manifest.json")" || log "AVISO: estado não gravado"
register_partial "$PARTIAL_NOTE"
DUR=$(( $(now_epoch) - START ))
# third-state-waiver: o snapshot já subiu e latest.json já andou; esta linha só monta o texto do log, e o estado (régua) vem do manifest já validado acima
log "OK $STEM: $ART_BYTES bytes, $(jq -r '[.databases | to_entries[] | .value.issues] | add' "$WD/manifest.json") issues em $(jq -r '.databases | length' "$WD/manifest.json") bancos (ignorados: $(jq -r '.ignored_dbs | join(",") | if . == "" then "nenhum" else . end' "$WD/manifest.json")), régua: $(jq -r '.baseline.state' "$WD/manifest.json"), ${DUR}s"

# ── retenção (falha aqui é aviso: o snapshot novo já está seguro) ────────────────────────────────────
# listagem que falhou OU veio ilegível => pula (nunca vira "0 chaves"); helper que falhou => pula, e não lê o delete.txt parcial dele.
if listing="$(s3api list-objects-v2 --bucket "$BUCKET" --prefix "$PREFIX/snap/" --output json 2>>"$LOG")" \
   && printf '%s' "$listing" | jq -r '.Contents[]?.Key' > "$WD/keys.txt" 2>/dev/null; then
  if python3 -I "$PY" retention --prefix "$PREFIX" --now "$(now_epoch)" --keep-recent-h "$KEEP_RECENT_H" --keep-daily-days "$KEEP_DAILY_DAYS" \
       --floor "$KEEP_FLOOR" --protect "$ART" < "$WD/keys.txt" > "$WD/delete.txt" 2>>"$LOG"; then
    ndel=0
    while IFS= read -r k; do
      [ -n "$k" ] || continue
      if s3api delete-object --bucket "$BUCKET" --key "$k" >/dev/null 2>>"$LOG"; then ndel=$((ndel + 1)); else log "AVISO: não apaguei $k"; fi
    done < "$WD/delete.txt"
    log "retenção: $(wc -l < "$WD/keys.txt" | tr -d ' ') chaves, $ndel apagadas"
  else
    log "AVISO: retenção pulada (o helper falhou; nada apagado)"
  fi
else
  log "AVISO: retenção pulada (list-objects-v2 falhou ou veio ilegível)"
fi
[ -z "$SRC_WHY" ] || fail "fonte parada: $SRC_WHY (snapshot novo subiu: key=$ART)"
echo "RESULT: ok new key=$ART bytes=$ART_BYTES head_age_s=$HEAD_AGE dur_s=$DUR"
exit 0
