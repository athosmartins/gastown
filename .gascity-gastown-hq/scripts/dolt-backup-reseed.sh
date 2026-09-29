#!/bin/bash
# dolt-backup-reseed.sh (ga-ydrg9) — re-semeia o backup de UM banco Dolt.
#
# ═══ POR QUE ISTO EXISTE ═══
#
# `dolt backup sync` é INCREMENTAL/APPEND-ONLY. Quando a origem é compactada
# (history squash via `gc dolt compact`), o backup NÃO reflete o squash: o blob
# pré-compactação vira lixo permanente no instante da compactação, e nada o
# remove. A idade dele é irrelevante -- o que importa é que ficou ÓRFÃO.
#
# MEDIDO 21/08 no hq: dos 17 arquivos do backup, UM tinha 10,61GB (datado de
# 17/08, dois dias ANTES da compactação de 19/08) e os outros 16 somavam ~1,4GB.
# 88% do desperdício era esse único órfão. Retenção por IDADE só o removeria
# meses depois, por acidente -- não é o remédio certo para esta doença.
#
# ⚠️ DOUTRINA ANTERIOR ERRADA, corrigida aqui: estava registrado nesta cidade
# que o .dolt-backup "encolhe sozinho quando a origem encolher". Não encolhe.
# Foi essa crença que deixou 12GB de backup para 5,2GB de dados vivos.
#
# ═══ O MECANISMO: RE-SEED, NUNCA PODA NO LUGAR ═══
#
# Não podamos arquivo individual do backup -- o Dolt RECUSA fsck/gc direto num
# diretório de backup (precisa de repo embrulhado em .dolt), e mexer à mão num
# formato que não se entende é como se perde backup.
#
# Em vez disso: backup NOVO em local novo -> VERIFICA que restaura -> troca.
# Isso resolve o catch-22 que travou a investigação anterior: o espaço exigido
# passa a ser o tamanho dos DADOS ATUAIS, não o do BACKUP acumulado.
#
# PROVADO EM TESTE REAL antes de virar script (lexbh, 21/08 09:41):
#   backup novo   = 1 arquivo  / 1.1M
#   backup antigo = 28 arquivos / 1.2M
#   restaurado    = 33 beads == 33 beads no vivo  (dado conferido, não só arquivo)
#
# ═══ REGRA INEGOCIÁVEL ═══
# Nada é apagado antes de o backup novo ter sido RESTAURADO e o DADO conferido
# contra a origem — SALVO no modo de baixo disco abaixo, onde a prova muda de
# forma (S3, não restore local) porque não há disco para as duas provas.
#
# ═══ MODO DE BAIXO DISCO (ga-i99qsp) ═══
#
# O fluxo normal acima precisa de ~250% do tamanho vivo livre: NEW_DIR (backup
# novo, ~1x) + VERIFY_DIR (restauração de verificação, ~1x) coexistindo com o
# BACKUP_DIR antigo, que fica intocado até a troca final. Isso é ótimo quando
# há disco de sobra, mas para o hq (13-14G de staging bloated, disco com só
# 7-8G livres) essa margem NUNCA existe -- e o próprio staging bloated (que o
# mecanismo existe para encolher) é a maior causa do disco estar apertado.
# Catch-22: falta espaço para o mecanismo que devolveria o espaço.
#
# Quando a margem normal não cabe mas uma única cópia nova cabe
# (RESEED_LOW_DISK_MARGIN_PCT, default 120%), o modo de baixo disco entra:
# constrói o backup novo com o antigo ainda no lugar (igual ao fluxo normal);
# só quando o disco livre APÓS construir o novo não bastar para a verificação
# (a segunda cópia), libera o antigo MAIS CEDO que o normal -- mas nunca sem
# antes provar, via S3, que a cópia local prestes a ser apagada já está
# espelhada lá E que a cópia do S3 RESTAURA (ga-gsnee8: a prova anterior era só
# "o OBJETO manifest existe" + razão de tamanho, que não diz nada sobre
# restaurar -- ver "PROVA DE S3 DO MODO DE BAIXO DISCO" abaixo).
# Se a prova falhar: NADA é apagado (fail-closed). Se passar e algo DEPOIS
# falhar (restore, contagem, promoção): o banco fica temporariamente SEM
# backup local -- log e saída marcam isso explicitamente ("SEM BACKUP LOCAL")
# para o chamador (dolt-s3-backup.sh) alarmar alto, porque essa janela é
# exatamente o que o desenho normal evita e só é aceita aqui por não haver
# alternativa com o disco que existe. RESEED_ALLOW_LOW_DISK=0 desliga tudo
# isto e volta ao comportamento antigo (só recusa).
#
# ═══ MODO ULTRA DE BAIXO DISCO (ga-74tts6) ═══
#
# O modo acima ainda exige ~120% do vivo livre PARA CONSTRUIR a cópia nova com
# o antigo no lugar -- para o hq real (7,7G vivo) isso são ~9,2GB, e o
# incidente que abriu esta bead teve o disco em CRITICAL (~4-6GB livres):
# nem o modo de baixo disco cabia, e ele voltava a recusar às 04:00 também.
# Mesmo catch-22 de ga-i99qsp, com o limiar menor.
#
# Quando nem uma cópia nova cabe com o antigo no lugar (Preflight 2), mas
# LIBERAR o antigo abriria espaço suficiente, a ordem se inverte por completo:
# prova via S3 -> libera o antigo -> só ENTÃO constrói a cópia nova -> verifica
# -> promove. A MESMA prova do modo de baixo disco normal (nunca uma prova mais
# fraca só porque a situação é mais urgente); se falhar, nada é apagado. Se a
# liberação nem bastaria, o script recusa -- apagar o antigo sem conseguir
# reconstruir o novo não ajudaria em nada.
#
# ⚠️ "BASTARIA" É UMA CONTA DE DUAS CÓPIAS, NÃO DE UMA (ga-gsnee8). Este bloco
# dizia "livre + antigo >= 120% do vivo" -- o espaço de UMA cópia nova. Mas o
# mecanismo constrói NEW_DIR (~1x vivo) e, ANTES de promover, restaura NEW_DIR
# em VERIFY_DIR (~1x vivo, sob /tmp, no MESMO volume): as duas coexistem. Com
# livre ~3GB o hq passava no limiar de 120% e o disco estourava no meio da
# restauração -- com o antigo JÁ apagado (mesma classe do outage de ga-odtd3f).
# A conta correta é cópia nova (120%) + cópia da restauração
# (RESEED_RESTORE_COPY_PCT, default 100%) = 220% do vivo.
#
# ═══ PROVA DE S3 DO MODO DE BAIXO DISCO (ga-gsnee8) ═══
#
# Os dois pontos que apagam o antigo mais cedo (Passo 0.5 e Passo 1.5) só
# apagam com a prova de dolt-backup-s3-proof.sh (_s3proof_repair_then_prove):
#   1. o backup LOCAL a apagar é um backup fechado (toda tabela que o seu
#      manifest nomeia existe);
#   2. o backup do S3 é fechado (toda tabela que o manifest DO S3 nomeia existe
#      no bucket) -- ou seja, RESTAURA;
#   3. o S3 já tem cada arquivo do local (mesmo tamanho, não mais antigo).
# Se não provar, a lib tenta REPARAR (espelha o local para o S3, tabelas antes
# do manifest, aditivo) e prova de novo; se ainda não provar, NADA é apagado.
#
# A prova anterior era "head-object do manifest" + razão de tamanho contra o
# fingerprint (_meta/latest.json). Nenhuma das duas diz que a cópia restaura.
# MEDIDO 2026-09-25 no hq: o manifest existia (4089 B) e nomeava uma tabela
# que NÃO estava no bucket, com 31 arquivos (2,69GB) nunca enviados -- cópia
# irrestaurável que a prova fraca chamaria de boa. Só NÃO autorizou apagar o
# único staging completo porque o hq tinha sumido do fingerprint naquela
# semana (size_ok=0): um acidente, não uma guarda.
#
# ═══ PUBLICAÇÃO DO FINGERPRINT APÓS TROCA (ga-6xo4r0) ═══
#
# dolt-backup-residue-reclaim.sh só libera um .old residue depois que o
# fingerprint publicado em S3 (_meta/latest.json) prova, via generation
# check, que o backup ATUAL (o que substituiu esse .old) foi sincronizado ao
# S3 DEPOIS da troca. Até esta bead, o ÚNICO publicador desse fingerprint
# era dolt-s3-backup.sh, uma vez por dia (04:00) — o que é ótimo para uma
# troca feita DENTRO desse mesmo run diário, mas deixa um buraco de até 24h
# para uma troca feita por um chamador AD HOC fora desse horário
# (dolt-disk-floor-guard.sh, ao detectar disco CRITICAL): o .old fica
# perfeitamente saudável e verificado localmente, mas invisível ao
# residue-reclaim até o próximo 04:00 — medido ao vivo 2026-09-21,
# whatsapp_automation.old foi reaproveitado 4x num único dia, cada vez
# empurrando sua elegibilidade mais um dia adiante (ver ga-6xo4r0).
#
# Todo swap bem-sucedido abaixo (modo normal OU modo de baixo disco) agora
# chama _publish_after_swap -> _publish_db_fingerprint: sincroniza o backup
# recém-promovido para S3 e MESCLA uma entrada com timestamp PRÓPRIO deste
# db em _meta/latest.json, sem tocar nas entradas dos outros dbs (nunca
# sobrescreve o arquivo inteiro — ver o comentário de _publish_db_fingerprint
# para o porquê). dolt-backup-residue-reclaim.sh's _parse_fingerprint_to_file
# prefere esse timestamp por-db ao timestamp compartilhado do topo do
# arquivo quando presente, com fallback total para o comportamento antigo
# quando ausente (100% retrocompatível). Best-effort e nunca fatal: uma
# falha aqui não desfaz a troca local já verificada, só atrasa a prova
# off-box (mesma janela de até 24h de antes, não uma regressão). Escape
# hatch: RESEED_PUBLISH_FINGERPRINT=0.
set -uo pipefail

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dolt-offline-backup-sync.sh"
# Do residue-reclaim vêm AWS/BUCKET/AWS_TIMEOUT_SECS/PY (usados pela publicação
# do fingerprint abaixo e pela lib de prova S3). LIB mode só define
# funções/variáveis, não varre nem apaga nada.
# shellcheck disable=SC1091
DOLT_BACKUP_RESIDUE_RECLAIM_LIB=1 . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dolt-backup-residue-reclaim.sh"
# ga-gsnee8: a prova de que o S3 RESTAURA (fecho do manifest local + S3 + espelho
# idêntico) mora numa lib só, compartilhada com dolt-s3-backup.sh e
# dolt-gc-maintenance.sh (ga-btnq6h). Executa-se a lib; não se reimplementa.
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dolt-backup-s3-proof.sh"

# ga-6xo4r0 / ga-tyaozh: aws-cli/botocore defaults to wrapping every S3
# PutObject/UploadPart body in botocore.httpchecksum.AwsChunkedWrapper (a
# chunked-transfer trailing checksum). On a dropped connection, botocore's
# retry tries to rewind that wrapper; when the rewind raises, botocore
# surfaces UnseekableStreamError ("stream is not seekable") and ABANDONS the
# retry instead of completing it — this hit hq's daily backup for real on
# 2026-09-21 and cascaded into a city-wide disk-pressure outage (see
# dolt-s3-backup.sh's own identical export for the full incident writeup).
# dolt-s3-backup.sh already exports this for its OWN uploads, and a child
# process (this script, invoked via its RESEED_SCRIPT call) inherits it —
# but this script's OTHER caller, dolt-disk-floor-guard.sh's ad hoc CRITICAL
# trigger, does NOT set it. Since ga-6xo4r0 gives THIS script its own S3
# upload call sites (_publish_db_fingerprint's sync + fingerprint cp, below)
# that did not exist when ga-tyaozh's fix was written, this script must
# export it independently rather than rely on inheriting it from one caller
# only — exported unconditionally (harmless no-op re-export when already
# inherited from dolt-s3-backup.sh) so every caller is covered.
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required

DB="${1:-}"
CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
BACKUP_ROOT="${GC_BACKUP_ARTIFACT_DIR:-$CITY/.dolt-backup}"
LOG="${RESEED_LOG:-$CITY/.gc/logs/dolt-backup-reseed.log}"
# ⚠️ MARGEM — a conta que eu ERREI na primeira versão (pego pelo gate, ga-kawer3).
# Eu dimensionei para UMA cópia extra ("o novo enquanto o antigo existe") e o
# mecanismo cria DUAS ao mesmo tempo. O pico real de consumo NOVO é:
#     NEW_DIR (backup novo, ~1x vivo)
#   + VERIFY_DIR (restauração de verificação, ~1x vivo)   <-- eu tinha esquecido
#   = ~2x o tamanho vivo
# e as duas coexistem ANTES da troca (o BACKUP_DIR original ainda está lá, mas
# esse não é consumo novo). VERIFY_DIR fica sob /tmp, no MESMO volume de dados
# que o preflight mede — não é espaço "de outro lugar".
# Medido no hq: vivo 4.167MB -> minha checagem antiga exigia 6.251MB, pico real
# 8.335MB. Passaria no preflight e estouraria durante a restauração — que é
# exatamente a falha que este script existe para evitar (ga-vs55, 14/07).
# 250% = 2x do pico + 0,5x de folga para a cidade continuar escrevendo durante
# a operação (ela nunca para).
DISK_MARGIN_PCT="${RESEED_DISK_MARGIN_PCT:-250}"
# ga-i99qsp: margem MÍNIMA para tentar o modo de baixo disco — só precisa
# caber UMA cópia nova (o antigo ainda está no lugar enquanto ela é
# construída), não duas. 120% = 1x vivo + 0,2x de folga para escrita
# concorrente durante a construção (mais apertado que os 0,5x do fluxo
# normal porque o modo de baixo disco é, por definição, para quando 0,5x de
# folga não cabe no disco que existe). Abaixo disto o script se recusa —
# nunca finge que uma cópia cabe em menos que o próprio tamanho vivo.
LOW_DISK_MARGIN_PCT="${RESEED_LOW_DISK_MARGIN_PCT:-120}"
# Escape hatch: 0 desliga o modo de baixo disco inteiro e volta ao
# comportamento antigo (recusa quando a margem normal não cabe, ponto final).
RESEED_ALLOW_LOW_DISK="${RESEED_ALLOW_LOW_DISK:-1}"
# ga-6xo4r0: bound on the post-swap "aws s3 sync" _publish_db_fingerprint
# runs so residue-reclaim can see THIS swap's proof without waiting for
# dolt-s3-backup.sh's next once-a-day run — up to 24h away for a db an ad
# hoc, disk-pressure-triggered reseed touched outside that schedule (see
# this file's own header link for the full gap this closes). Matches
# dolt-s3-backup.sh's own S3_TIMEOUT (1200s) for the same per-db off-box
# mirror step.
RESEED_S3_SYNC_TIMEOUT_SECS="${RESEED_S3_SYNC_TIMEOUT_SECS:-1200}"
# Escape hatch: 0 skips the post-swap S3 sync + fingerprint refresh
# entirely, reverting to the pre-ga-6xo4r0 behavior (swap only; residue-
# reclaim only sees this db's proof at the next dolt-s3-backup.sh run) —
# same shape as RESEED_ALLOW_LOW_DISK above, for an operator to disable
# without a code change if this step ever misbehaves in prod. Never affects
# the swap itself, which has already succeeded and been verified by the
# time this step runs either way.
RESEED_PUBLISH_FINGERPRINT="${RESEED_PUBLISH_FINGERPRINT:-1}"
# ga-gsnee8: tamanho da cópia da RESTAURAÇÃO DE VERIFICAÇÃO (VERIFY_DIR), em %
# do vivo. É a segunda cópia que coexiste com NEW_DIR antes da troca (ver o
# cabeçalho, "BASTARIA É UMA CONTA DE DUAS CÓPIAS"). 100 = a restauração ocupa
# ~1x o vivo. Só entra na conta do modo ULTRA (Preflight 2).
RESTORE_COPY_PCT="${RESEED_RESTORE_COPY_PCT:-100}"
# ga-gsnee8: a prova de S3 do modo de baixo disco pode REPARAR o S3 (espelhar o
# local para lá) antes de passar. Isso roda dentro do orçamento (~1800s) dos
# chamadores (dolt-s3-backup.sh, dolt-compact-routine.sh, disk-floor-guard) --
# e no Passo 1.5 roda com NEW_DIR já construído, então um timeout no meio
# humano limpar). Por isso: UMA rodada de reparo, upload limitado a 600s e
# chamadas só-leitura (manifest, listagem, dry-run) a 120s -- os defaults da lib
# são 2 rodadas x 1500s e 300s. Com o S3 fora do ar o pior caso da prova vira
# ~120s + ~600s, não ~300s + ~900s. Uma prova que não fecha nesse orçamento
# recusa e NADA é apagado; e o upload é aditivo (`s3 sync` pula o que já
# chegou), então cada execução avança de onde a anterior parou -- um orçamento
# curto só custa mais uma rodada, nunca correção.
S3PROOF_UP_TIMEOUT="${RESEED_S3PROOF_UP_TIMEOUT_SECS:-600}"
S3PROOF_TIMEOUT="${RESEED_S3PROOF_TIMEOUT_SECS:-120}"
S3PROOF_REPAIR_ROUNDS="${RESEED_S3PROOF_REPAIR_ROUNDS:-1}"
S3PROOF_LOG="${S3PROOF_LOG:-$LOG}"
DOLT_BIN="${DOLT_BIN:-dolt}"
GC_BIN="${GC_BIN:-gc}"
# ga-o3nqy2: wiring for the shared server-free sync (dolt-offline-backup-sync.sh).
# Read only by that sourced file's functions, not visibly within this one —
# the static analyzer can't see across the dynamic source path below.
# shellcheck disable=SC2034
OFFLINE_SYNC_DOLT_CFG="$CITY/.gc/runtime/packs/dolt/dolt-config.yaml"
# shellcheck disable=SC2034
OFFLINE_SYNC_DOLT_BIN="$DOLT_BIN"
# shellcheck disable=SC2034
OFFLINE_SYNC_LOG="$LOG"
# shellcheck disable=SC2034
OFFLINE_SYNC_TIMEOUT=1800                 # same budget the old server-mediated sync step used

mkdir -p "$(dirname "$LOG")" 2>/dev/null
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [reseed] $*" | tee -a "$LOG"; }
die() { log "ABORTADO: $*"; exit 1; }

# _s3_current_backup_verified <db> <local_dir> — ga-i99qsp / ga-gsnee8: prova de
# que o S3 tem uma cópia que RESTAURA e que já contém tudo o que há em
# <local_dir>, ANTES de apagá-lo no modo de baixo disco. Quem chama nunca apaga
# sem um "true" explícito daqui.
#
# ga-gsnee8: delega à lib dolt-backup-s3-proof.sh (_s3proof_repair_then_prove:
# fecho do manifest local + fecho do manifest do S3 + espelho idêntico; se não
# provar, repara espelhando o local e prova de novo). A prova anterior daqui era
# `head-object` do manifest + razão de tamanho contra _meta/latest.json --
# "o OBJETO manifest existe" e "o tamanho é parecido", nenhuma das duas
# dizendo que a cópia restaura. O fingerprint deixou de ser consultado: a
# identidade agora é provada por arquivo (nome + tamanho), não por uma razão.
#
# Fail-closed por construção: a lib devolve 0 SÓ quando a propriedade foi
# positivamente estabelecida, e 1 tanto para "é falso" quanto para "não consegui
# saber" (aws fora do ar, listagem vazia, arquivo ilegível) -- nunca 0 na dúvida
# (ga-p5q3). As linhas "closure"/"mirror check" que a lib loga (via log() acima)
# dizem QUAL parte falhou.
_s3_current_backup_verified() {
  local db="$1" local_dir="$2"
  if _s3proof_repair_then_prove "$local_dir" "$db"; then
    log "prova do S3 OK (modo de baixo disco) para '$db': o backup local é fechado, o S3 restaura (fecho do manifest) e já tem cada arquivo local"
    return 0
  fi
  log "prova S3 (modo de baixo disco) para '$db' NÃO estabelecida: fecho do manifest ou espelho idêntico não provado, mesmo após o reparo (ver as linhas 'closure'/'mirror' acima) — nada será apagado com base nisto"
  return 1
}

# _should_release_manifestless_primary <has_local_manifest:0|1> <s3_manifest_ok:0|1>
#   <old_mtime> <run_epoch> <s3_closure_ok:0|1> <fp_status> → 0 (true) ONLY when
#   ALL hold: the local primary has NO manifest (ga-qh8gkw rule #2 — this path
#   NEVER touches a primary that already has one, whatever the other inputs
#   say), the S3 manifest object for the db exists (a real head-object, not an
#   inference), and dolt-backup-s3-proof.sh's S3-ALONE closure proof
#   (_s3proof_s3_closure_ok) succeeded — i.e. S3 restores on its own, with NO
#   dependency on a local manifest that does not exist (unlike
#   _s3_current_backup_verified above, which requires _s3proof_local_closure_ok
#   first and is therefore structurally unusable here — see ga-qh8gkw / the
#   dog-3 diagnosis on ga-9626dq this closes).
#
# The remaining check — freshness — branches on <fp_status> (the state word
# _fingerprint_db_state prints: "ok", "failed", "absent", "unrecognized",
# "unreadable", or the caller's own "unfetched"):
#   - fp_status = "ok" (or empty, for callers written before this parameter
#     existed — ga-qh8gkw's original 5-arg shape): the S3 fingerprint's run
#     must be STRICTLY newer than the primary's own mtime (the same
#     "generation" reasoning dolt-backup-residue-reclaim.sh's
#     _should_release_residue already uses: proof the fingerprint describes a
#     state captured after whatever process last wrote here, not before).
#   - fp_status = "failed" (ga-qaa1k7 — Mayor's decision, 28/09, on ga-qh8gkw):
#     the freshness comparison is SKIPPED. A writer marking its OWN daily run
#     "failed" (e.g. disk pressure) has no run_epoch to compare — but that
#     tells us nothing about the S3 copy dolt-backup-s3-proof.sh just proved,
#     live, closes on its own. A manifest-less primary already carries ZERO
#     backup value; freeing it on a live S3-only proof never makes anything
#     LESS recoverable than it already was, so a merely-failed writer run is
#     not a reason to keep it. (Rule #2 above still applies unconditionally —
#     has_manifest must be 0 — so this never touches a primary that would
#     otherwise be spared for having its own valid manifest.)
#   - any OTHER fp_status (absent/unrecognized/unreadable/unfetched): falls
#     through to the same freshness check as "ok" — with no run_epoch to
#     compare, that check fails closed exactly as it did before this fp_status
#     parameter existed.
#
# Any empty/non-numeric/unset input fails CLOSED (ga-p5q3 family): "I could
# not tell" must never produce the same action as "it is fine".
_should_release_manifestless_primary() {
  local has_manifest="${1-}" s3_manifest_ok="${2-}" old_mtime="${3-}" run_epoch="${4-}" s3_closure_ok="${5-}" fp_status="${6-}"
  [ "$has_manifest" = "0" ] || return 1
  [ "$s3_manifest_ok" = "1" ] || return 1
  [ "$s3_closure_ok" = "1" ] || return 1
  [ "$fp_status" = "failed" ] && return 0
  case "$old_mtime" in ''|*[!0-9]*) return 1 ;; esac
  case "$run_epoch" in ''|*[!0-9]*) return 1 ;; esac
  [ "$run_epoch" -gt "$old_mtime" ] || return 1
  return 0
}

# _publish_db_fingerprint <db> <local_dir> <issues> — ga-6xo4r0: syncs
# <local_dir> (the JUST-PROMOTED, already restore-verified backup for <db>)
# to S3, then MERGES a fresh, per-db-timestamped entry for <db> into
# s3://$BUCKET/_meta/latest.json — leaving every OTHER db's entry (including
# its own run_utc) untouched. This is what lets an ad hoc reseed (triggered
# by dolt-disk-floor-guard.sh at CRITICAL, outside dolt-s3-backup.sh's once-
# a-day 04:00 schedule) prove S3 freshness for JUST the db it touched,
# instead of leaving a perfectly healthy .old residue stuck until the next
# scheduled run (up to 24h) — see this file's own header link for the full
# mechanism this closes.
#
# ═══ WHY MERGE, NEVER OVERWRITE ═══
# The published file's databases.<db> entries are the ONLY proof residue-
# reclaim has for EVERY db in the city, not just this one. Overwriting the
# whole file with a doc that only describes <db> would ERASE every other
# db's proof and stall their reclaim until the next daily run — a real (if
# self-healing) availability regression this function must never cause. So:
# fetch the CURRENT doc first, and if that fetch fails for ANY reason
# (network, auth, doesn't parse as a JSON object) — ABORT, publish nothing,
# return 1. Leaving THIS db's own gap open one more cycle (self-healing:
# retried on the next successful reseed, ad hoc or daily) is always safer
# than clobbering everyone else's proof to close it sooner.
#
# <issues> is informational only (never read back by
# _parse_fingerprint_to_file's run_epoch/size_bytes extraction, same as the
# existing "head" field) — best-effort, never blocks the publish.
#
# Returns 0 (synced + published) or 1 (sync, fetch, parse, or upload
# failed) — ALWAYS non-fatal to the caller (_publish_after_swap below): the
# local swap/promotion this runs after has ALREADY succeeded and been
# verified (restored + row-count-checked). A failure here only means the
# OFF-BOX proof is delayed, never that the LOCAL backup itself is in doubt.
_publish_db_fingerprint() {
  local db="$1" local_dir="$2" issues="$3"

  if ! timeout "$RESEED_S3_SYNC_TIMEOUT_SECS" "$AWS" s3 sync "$local_dir/" "s3://$BUCKET/$db/" --delete --only-show-errors; then
    log "publish-fingerprint: ${db} — aws s3 sync FAILED; not publishing a fingerprint that would claim S3 content it doesn't have"
    return 1
  fi

  local fp_file merged_file
  fp_file="$(mktemp "${TMPDIR:-/tmp}/dolt-publish-fp.XXXXXX" 2>/dev/null)" || { log "publish-fingerprint: ${db} — could not create temp file for fetch"; return 1; }
  merged_file="$(mktemp "${TMPDIR:-/tmp}/dolt-publish-merged.XXXXXX" 2>/dev/null)" || { rm -f "$fp_file"; log "publish-fingerprint: ${db} — could not create temp file for merge"; return 1; }

  if ! timeout "$AWS_TIMEOUT_SECS" "$AWS" s3 cp "s3://$BUCKET/_meta/latest.json" "$fp_file" >/dev/null 2>&1; then
    log "publish-fingerprint: ${db} — could not fetch current _meta/latest.json; ABORTING publish (never clobber other dbs' proof with a partial doc)"
    rm -f "$fp_file" "$merged_file"
    return 1
  fi

  local backup_size_human
  backup_size_human="$(du -sh "$local_dir" 2>/dev/null | awk '{print $1}')"
  [ -n "$backup_size_human" ] || backup_size_human="0B"
  local run_utc; run_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if ! "$PY" - "$fp_file" "$db" "$run_utc" "$backup_size_human" "$issues" > "$merged_file" 2>/dev/null <<'PY'
import sys, json

fp_path, db, run_utc, backup_size, issues = sys.argv[1:6]
try:
    with open(fp_path) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError("top-level JSON is not an object")
except Exception:
    sys.exit(1)

if not isinstance(data.get("databases"), dict):
    data["databases"] = {}

try:
    issues_n = int(issues)
except Exception:
    issues_n = -1

# Merge: replace ONLY this db's entry. Every sibling key in "databases",
# and every other top-level key (including the shared "run_utc"), passes
# through untouched.
data["databases"][db] = {"issues": issues_n, "backup_size": backup_size, "run_utc": run_utc}
json.dump(data, sys.stdout, indent=2)
PY
  then
    log "publish-fingerprint: ${db} — fetched _meta/latest.json did not parse as a JSON object; ABORTING publish (never clobber)"
    rm -f "$fp_file" "$merged_file"
    return 1
  fi
  rm -f "$fp_file"

  if ! timeout "$AWS_TIMEOUT_SECS" "$AWS" s3 cp "$merged_file" "s3://$BUCKET/_meta/latest.json" --only-show-errors >/dev/null 2>&1; then
    log "publish-fingerprint: ${db} — upload of merged _meta/latest.json FAILED"
    rm -f "$merged_file"
    return 1
  fi
  rm -f "$merged_file"
  log "publish-fingerprint: ${db} — OK (run_utc=${run_utc} size=${backup_size_human}), merged into _meta/latest.json without touching other dbs' entries"
  return 0
}

# _publish_after_swap <db> <backup_dir> <issues> — ga-6xo4r0: thin wrapper
# _run_reseed calls from EVERY successful swap/promotion branch below
# (normal mode AND low-disk mode alike — reseed itself has no way to know
# whether dolt-s3-backup.sh's daily cron or dolt-disk-floor-guard.sh's ad
# hoc CRITICAL trigger called it, and running this unconditionally is
# correct/safe either way). See _publish_db_fingerprint above for the
# actual mechanism and its own safety reasoning.
#
# Escape hatch: RESEED_PUBLISH_FINGERPRINT=0 skips this step entirely.
#
# Best-effort and NEVER fatal: logs the outcome either way, never touches
# the caller's exit code — the swap this runs after already succeeded.
_publish_after_swap() {
  local db="$1" backup_dir="$2" issues="$3"
  if [ "$RESEED_PUBLISH_FINGERPRINT" != "1" ]; then
    log "S3 fingerprint refresh SKIPPED for '$db' (RESEED_PUBLISH_FINGERPRINT=0)"
    return 0
  fi
  if _publish_db_fingerprint "$db" "$backup_dir" "$issues"; then
    log "S3 fingerprint refresh OK for '$db' — residue-reclaim can see this swap once its settle window clears"
  else
    log "S3 fingerprint refresh FAILED for '$db' (non-fatal — local backup already verified and promoted; this db's .old stays spared until a future reseed or daily run succeeds at publishing)"
  fi
}

# _release_manifestless_primary <db> — ga-qh8gkw: Mayor's decision (28/09),
# answering ga-9626dq's dog-3 diagnosis. hq's PRIMARY (.dolt-backup/hq) has NO
# manifest and provides ZERO backup value, but neither existing mechanism can
# free it: dolt-backup-residue-reclaim.sh only ever globs "$BACKUP_ROOT"/*.old
# (a bare primary is never a match), and this file's own low-disk mode
# (_s3_current_backup_verified, above) delegates to
# _s3proof_repair_then_prove, which requires _s3proof_local_closure_ok FIRST —
# a valid LOCAL manifest — structurally impossible for a dir that has none.
#
# This is a narrower, STANDALONE justification: when the S3 copy alone
# proves restorable (_s3proof_s3_closure_ok — no local manifest needed) AND
# the S3 fingerprint is newer than the primary itself (the same "generation"
# proof dolt-backup-residue-reclaim.sh already uses for .old residue, reused
# here via its own already-sourced _parse_fingerprint_to_file /
# _fingerprint_db_state), the primary is definitively worthless and can be
# freed on its own — no fresh build, no swap, nothing else touched. Unlike
# the low-disk modes above, this does NOT run as part of a reseed cycle: it
# is invoked ad hoc (`dolt-backup-reseed.sh --release-manifestless-primary
# <db>`), specifically for the case where a full reseed cannot even start
# (e.g. <db>.new already sits there as residue from an interrupted run —
# Preflight 3 would refuse immediately).
#
# ga-qaa1k7 (continuation, Mayor's decision on ga-qh8gkw, 28/09): a
# fingerprint that is merely "failed" (the daily writer refused, e.g. for
# disk pressure — hq's own real case) has no run_epoch to compare, so the
# freshness check above could never pass — yet the live S3-only closure
# proof this function runs is a stronger, independent check that does not
# depend on the writer at all. See _should_release_manifestless_primary's
# own header for the exact fp_status branch this adds.
#
# ga-qh8gkw rule #2 (NEVER on a valid primary, NEVER on .new): the very first
# check below is the local manifest — a primary WITH one is left alone,
# unconditionally, regardless of what S3 says. This function only ever
# targets the bare "$BACKUP_ROOT/$db" path — never "$db.new" — by construction
# (it is not part of this function's own glob/argument surface at all).
#
# Every branch here RETURNS (never die()/exit) — this is deliberately safe to
# call from a sourcing test harness (DOLT_BACKUP_RESEED_LIB=1) without killing
# it, unlike _run_reseed.
_release_manifestless_primary() {
  local db="$1"
  if [ -z "$db" ]; then
    log "release-manifestless-primary: uso: $0 --release-manifestless-primary <nome-do-banco>"
    return 1
  fi
  local primary_dir="$BACKUP_ROOT/$db"
  local old_dir="$primary_dir.old"

  if [ ! -d "$primary_dir" ]; then
    log "release-manifestless-primary '$db': nada a liberar — não existe cópia primária em $primary_dir"
    return 0
  fi
  if [ -s "$primary_dir/manifest" ]; then
    log "release-manifestless-primary '$db': RECUSANDO — a primária TEM manifest válido (backup saudável); este caminho só existe para uma primária SEM manifesto"
    return 0
  fi
  if [ -e "$old_dir" ]; then
    log "release-manifestless-primary '$db': RECUSANDO — já existe $old_dir de um ciclo anterior; libere-o primeiro (dolt-backup-residue-reclaim.sh)"
    return 0
  fi

  local old_mtime; old_mtime="$(stat -f %m "$primary_dir" 2>/dev/null)"
  if [ -z "$old_mtime" ]; then
    log "release-manifestless-primary '$db': RECUSANDO — não consegui ler o mtime de $primary_dir"
    return 0
  fi

  local fp_file parsed_file
  fp_file="$(mktemp "${TMPDIR:-/tmp}/dolt-primary-release-fp.XXXXXX" 2>/dev/null)" || { log "release-manifestless-primary '$db': RECUSANDO — não consegui criar arquivo temporário para o fingerprint"; return 0; }
  parsed_file="$(mktemp "${TMPDIR:-/tmp}/dolt-primary-release-parsed.XXXXXX" 2>/dev/null)" || { rm -f "$fp_file"; log "release-manifestless-primary '$db': RECUSANDO — não consegui criar arquivo temporário para o parse"; return 0; }

  local fp_state; fp_state="$(printf 'unfetched\t')"
  if timeout "$AWS_TIMEOUT_SECS" "$AWS" s3 cp "s3://$BUCKET/_meta/latest.json" "$fp_file" >/dev/null 2>&1; then
    _parse_fingerprint_to_file "$fp_file" "$db" "$parsed_file"
    fp_state="$(_fingerprint_db_state "$fp_file" "$db")"
  fi
  local run_epoch="" size_bytes="" head=""
  if [ -s "$parsed_file" ]; then
    IFS="$(printf '\t')" read -r run_epoch size_bytes head < "$parsed_file"
  fi
  rm -f "$fp_file" "$parsed_file" 2>/dev/null

  local manifest_ok=0
  if timeout "$AWS_TIMEOUT_SECS" "$AWS" s3api head-object --bucket "$BUCKET" --key "$db/manifest" >/dev/null 2>&1; then
    manifest_ok=1
  fi

  local closure_ok=0
  if _s3proof_s3_closure_ok "$db"; then
    closure_ok=1
  fi

  local fp_status="${fp_state%%$'\t'*}"

  if _should_release_manifestless_primary 0 "$manifest_ok" "$old_mtime" "${run_epoch:-}" "$closure_ok" "$fp_status"; then
    local freed_size; freed_size="$(du -sh "$primary_dir" 2>/dev/null | awk '{print $1}')"
    if [ "$fp_status" = "failed" ]; then
      log "release-manifestless-primary '$db': PROVA S3-ONLY OK (fingerprint marcado 'failed', last_ok=${fp_state#*$'\t'} — sem run_epoch para comparar frescor; ga-qaa1k7: dispensado quando a closure AO VIVO já prova sozinha) — manifest do S3 presente (head-object OK), S3 fecha sozinho (_s3proof_s3_closure_ok, sem depender de manifest local) — liberando a primária sem manifesto ($primary_dir, ~${freed_size:-?})"
    else
      log "release-manifestless-primary '$db': PROVA S3-ONLY OK — manifest do S3 presente (head-object OK), fingerprint mais novo que a cópia local (run_epoch=${run_epoch} > mtime=${old_mtime}), S3 fecha sozinho (_s3proof_s3_closure_ok, sem depender de manifest local) — liberando a primária sem manifesto ($primary_dir, ~${freed_size:-?})"
    fi
    if [ "${RESEED_RELEASE_MANIFESTLESS_PRIMARY_DRY_RUN:-0}" = "1" ]; then
      log "release-manifestless-primary '$db': DRY-RUN — nada apagado (RESEED_RELEASE_MANIFESTLESS_PRIMARY_DRY_RUN=1)"
      return 0
    fi
    case "$primary_dir" in
      "$BACKUP_ROOT"/*)
        case "$(basename "$primary_dir")" in
          *.old|*.new)
            log "release-manifestless-primary '$db': RECUSANDO rm -rf — '$primary_dir' tem forma .old/.new (guarda de segurança; este caminho só apaga a primária BARE)"
            return 0
            ;;
        esac
        if rm -rf "$primary_dir"; then
          log "release-manifestless-primary '$db': LIBERADA (~${freed_size:-?}) — '$db' fica SEM BACKUP LOCAL até um reseed completo ou a promoção de $db.new logo abaixo"
        else
          log "release-manifestless-primary '$db': FALHA no rm -rf de $primary_dir"
          return 1
        fi
        ;;
      *)
        log "release-manifestless-primary '$db': RECUSANDO rm -rf — '$primary_dir' está fora de \$BACKUP_ROOT (guarda de segurança)"
        return 0
        ;;
    esac
  else
    log "release-manifestless-primary '$db': SPARED — prova S3-only não estabelecida (manifest_ok=$manifest_ok run_epoch=${run_epoch:-none} old_mtime=$old_mtime closure_ok=$closure_ok fingerprint_state=${fp_status:-none}) — nada foi apagado"
    return 0
  fi

  _maybe_promote_new_after_primary_release "$db"
}

# _maybe_promote_new_after_primary_release <db> — ga-qh8gkw step 3: after
# _release_manifestless_primary actually frees a manifest-less primary, check
# whether a "$db.new" residue is sitting there ready to take its place, and
# whether disk NOW covers a REAL restore+row-count verification — the exact
# same proof Passo 2 of _run_reseed demands before ANY promotion (a manifest
# only proves the build finished, never that it restores; dolt-backup-swap-
# repair.sh deliberately defers this same verification to this file rather
# than reimplement it — see that script's own header). If the margin is not
# there, this leaves $db.new EXACTLY as it was and logs why: S3 remains the
# only network until a future run has the room to try. It never invents a
# weaker proof just because disk is tight — same "fail toward inert" stance
# as the release above.
_maybe_promote_new_after_primary_release() {
  local db="$1"
  local primary_dir="$BACKUP_ROOT/$db"
  local new_dir="$primary_dir.new"
  local old_dir="$primary_dir.old"

  if [ ! -d "$new_dir" ]; then
    log "release-manifestless-primary '$db': nada para promover — $new_dir não existe"
    return 0
  fi
  if [ ! -s "$new_dir/manifest" ]; then
    log "release-manifestless-primary '$db': $new_dir existe mas SEM manifest — não é promovível por este caminho"
    return 0
  fi
  if [ -e "$old_dir" ]; then
    log "release-manifestless-primary '$db': não promovendo $new_dir — $old_dir existe (não deveria neste ponto); investigue"
    return 0
  fi
  if [ -e "$primary_dir" ]; then
    log "release-manifestless-primary '$db': não promovendo $new_dir — $primary_dir já existe de novo (concorrência?); investigue"
    return 0
  fi

  local live_kb; live_kb="$(du -sk "$CITY/.beads/dolt/$db" 2>/dev/null | awk '{print $1}')"
  if [ -z "$live_kb" ]; then
    log "release-manifestless-primary '$db': não consegui medir o tamanho vivo de '$db' — deixando $new_dir no lugar; S3 é a rede até então. Registrado e parando."
    return 0
  fi
  local free_kb; free_kb="$(df -k /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $4}')"
  if [ -z "$free_kb" ]; then
    log "release-manifestless-primary '$db': não consegui medir o disco livre — deixando $new_dir no lugar; S3 é a rede até então. Registrado e parando."
    return 0
  fi
  local need_kb=$(( live_kb * LOW_DISK_MARGIN_PCT / 100 ))
  if [ "$free_kb" -lt "$need_kb" ]; then
    log "release-manifestless-primary '$db': deixando $new_dir no lugar — margem insuficiente para verificar (livre $((free_kb/1024))MB, preciso ~$((need_kb/1024))MB = ${LOW_DISK_MARGIN_PCT}% do vivo); S3 é a rede até haver disco. Registrado e parando."
    return 0
  fi

  log "release-manifestless-primary '$db': livre $((free_kb/1024))MB cobre a verificação (~$((need_kb/1024))MB) — restaurando $new_dir para conferir antes de promover."
  local live_count
  live_count=$(timeout 60 "$GC_BIN" dolt sql -q "SELECT COUNT(*) FROM \`$db\`.issues" 2>/dev/null \
               | grep -oE '^\| *[0-9]+' | grep -oE '[0-9]+' | head -1)
  if [ -z "$live_count" ]; then
    log "release-manifestless-primary '$db': não consegui ler a contagem viva de '$db' — deixando $new_dir no lugar sem promover (sem baseline não há verificação possível)"
    return 0
  fi

  local verify_dir; verify_dir=$(mktemp -d "/tmp/reseed-primary-release-verify-$db.XXXXXX" 2>/dev/null) || { log "release-manifestless-primary '$db': não consegui criar diretório de verificação — deixando $new_dir no lugar"; return 0; }
  local restored_count=""
  if ( cd "$verify_dir" && timeout 1800 "$DOLT_BIN" backup restore "file://$new_dir" "${db}_verify" >/dev/null 2>&1 ); then
    restored_count=$(cd "$verify_dir/${db}_verify" 2>/dev/null && timeout 120 "$DOLT_BIN" sql -q "SELECT COUNT(*) FROM issues" 2>/dev/null \
                     | grep -oE '^\| *[0-9]+' | grep -oE '[0-9]+' | head -1)
  fi
  rm -rf "$verify_dir" 2>/dev/null

  if [ -z "$restored_count" ]; then
    log "release-manifestless-primary '$db': $new_dir NÃO restaura (ou não consegui ler o dado restaurado) — mantendo $new_dir intacto, NÃO promovendo. '$db' fica SEM BACKUP LOCAL até um reseed completo; o S3 (verificado acima) é o único fallback nesta janela."
    notify_fail "release-manifestless-primary: '$db' está SEM BACKUP LOCAL — a primária inválida foi liberada com prova do S3, mas $new_dir não restaura. Ver $LOG."
    return 0
  fi
  if [ "$restored_count" -lt "$live_count" ]; then
    log "release-manifestless-primary '$db': $new_dir restaura mas com MENOS dado que a origem ($restored_count < $live_count) — mantendo $new_dir intacto, NÃO promovendo. '$db' fica SEM BACKUP LOCAL até um reseed completo; o S3 é o único fallback nesta janela."
    notify_fail "release-manifestless-primary: '$db' está SEM BACKUP LOCAL — $new_dir restaura com menos dado que a origem ($restored_count < $live_count). Ver $LOG."
    return 0
  fi

  if mv "$new_dir" "$primary_dir"; then
    local new_size; new_size=$(du -sh "$primary_dir" 2>/dev/null | awk '{print $1}')
    log "release-manifestless-primary '$db': $new_dir VERIFICADO (restaurado=$restored_count vs vivo=$live_count) e PROMOVIDO para $primary_dir (~${new_size:-?}) — '$db' tem backup local válido de novo."
    _publish_after_swap "$db" "$primary_dir" "$restored_count"
  else
    log "release-manifestless-primary '$db': $new_dir VERIFICADO mas o mv para $primary_dir FALHOU — '$db' está SEM BACKUP LOCAL agora. Investigue imediatamente; $new_dir (verificado) pode estar parcialmente movido."
    notify_fail "release-manifestless-primary: '$db' está SEM BACKUP LOCAL — $new_dir foi verificado mas o mv para $primary_dir falhou. Ver $LOG."
  fi
}

# ═══ ga-bo08jp: LIBERAR UM <db>.new VELHO, ÓRFÃO DE UMA PRIMÁRIA VÁLIDA ═══
#
# Caso medido 29/09: .dolt-backup/hq.new (8,7 GB, de 27/09) — um reseed que nunca
# terminou, cuja verificação de restauração estourou 30 min DUAS vezes (nunca
# provada) — sobrevivia ao lado de uma primária .dolt-backup/hq JÁ boa (manifest,
# 9,4 GB, sincronizada às 05:58) e de um S3 em dia. Nenhuma ferramenta o
# liberava: dolt-backup-residue-reclaim.sh só varre *.old; _release_manifestless_
# primary só age sobre uma primária SEM manifest (e recusa a que TEM); e o Preflight 3
# de _run_reseed morre com "$db.new já existe" — ou seja, o resíduo também
# TRAVA todo reseed futuro do banco, e o disco que ele ocupa (~2x o banco é o que
# o dolt_gc do hq precisa) é justamente o que falta.
#
# Um .new só vale algo enquanto é a única cópia mais nova que existe. Aqui ele
# está provadamente superado: é mais velho que a primária e que a prova do S3, e
# os DOIS (primária + S3) fecham sozinhos. Apagá-lo nunca deixa nada menos
# recuperável do que já estava.
#
# Só apaga com TODAS as provas abaixo; qualquer uma ausente, ilegível ou
# indeterminada → NADA é apagado (três estados: provado / refutado / não sei —
# só o primeiro autoriza; ga-p5q3). Standalone e ad hoc, como o irmão acima:
#   dolt-backup-reseed.sh --release-stale-new <db>
#   1. primária: existe, não é symlink, TEM manifest e fecha localmente
#      (_s3proof_local_closure_ok — toda tabela que o manifest nomeia existe);
#   2. S3: head-object do manifest E fecho do S3 sozinho (_s3proof_s3_closure_ok);
#   3. frescor: o fingerprint do db é status ok, mais novo que o .new e com no
#      máximo RESEED_RELEASE_STALE_NEW_FP_MAX_AGE_SECS (36h) — "failed" NÃO vale
#      aqui (diferente da primária sem manifest: lá a primária já não valia nada);
#   4. idade: o item mais novo DENTRO do .new é estritamente mais velho que o
#      item mais novo da primária (um .new sendo escrito agora, ou mais novo que
#      a primária, nunca é apagado);
#   5. nada em curso: sem o lock do backup noturno e sem processo de
#      backup/restore/reseed (nem nada com o caminho do .new); ps ilegível conta
#      como "em curso" — o próprio processo e seus ancestrais não contam.
# Read-only no S3 (nunca sobe, nunca apaga lá). Só remove "$BACKUP_ROOT/<db>.new".
# Prova de efeito: du antes/depois e df antes/depois na linha de log.
# RESEED_RELEASE_STALE_NEW_DRY_RUN=1 prova e loga, sem apagar.

# _should_release_stale_new <new_mtime> <primary_mtime> <run_epoch> <now>
#   <fp_max_age_secs> <primary_ok> <s3_manifest_ok> <s3_closure_ok> <idle> → 0
# (true) SÓ quando todas as provas acima valem. Pura: toda entrada vem do chamador.
# Entrada vazia/não numérica, ou flag diferente do literal "1", falha FECHADO.
_should_release_stale_new() {
  local new_mtime="${1-}" primary_mtime="${2-}" run_epoch="${3-}" now="${4-}" max_age="${5-}"
  local primary_ok="${6-}" s3_manifest_ok="${7-}" s3_closure_ok="${8-}" idle="${9-}"
  local v
  for v in "$new_mtime" "$primary_mtime" "$run_epoch" "$now" "$max_age"; do
    case "$v" in ''|*[!0-9]*) return 1 ;; esac
  done
  [ "$new_mtime" -lt "$primary_mtime" ] || return 1
  [ "$new_mtime" -lt "$run_epoch" ] || return 1
  # Um relógio que discorda (fingerprint "do futuro") não vira frescor.
  [ "$now" -ge "$run_epoch" ] || return 1
  [ $(( 10#$now - 10#$run_epoch )) -le "$max_age" ] || return 1
  [ "$primary_ok" = "1" ] || return 1
  [ "$s3_manifest_ok" = "1" ] || return 1
  [ "$s3_closure_ok" = "1" ] || return 1
  [ "$idle" = "1" ] || return 1
  return 0
}

# _newest_mtime <dir> — epoch do item MAIS NOVO dentro de <dir> (o próprio
# diretório incluído). Imprime nada se não conseguiu medir tudo: ausência de
# medida nunca vira "0" (= "muito antigo", que autorizaria apagar).
_newest_mtime() {
  local raw out
  raw="$(find "$1" -exec stat -f %m {} + 2>/dev/null)" || return 0
  out="$(printf '%s\n' "$raw" | sort -n | tail -n 1)"
  case "$out" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$out"
}

# _stale_new_idle_state <new_dir> — imprime "idle", "busy<TAB>motivo" ou
# "unknown<TAB>motivo". Só "idle" autoriza; o lock do backup noturno, um
# processo de backup/restore/reseed, qualquer processo com o caminho do .new na
# linha de comando, ou um ps que não respondeu, contam como NÃO idle. Este
# processo e seus ancestrais (o shell que o lançou cita o script na própria
# linha de comando) não são "outra execução".
_stale_new_idle_state() {
  local new_dir="$1"
  local lockdir="${RESEED_S3_BACKUP_LOCKDIR:-$CITY/.gc/logs/.dolt-s3-backup.lock.d}"
  local ps_bin="${RESEED_PS_BIN:-ps}"
  local busy_re='dolt-s3-backup[.]sh|dolt-backup-reseed[.]sh|dolt-restore-verify|dolt-offline-backup-sync|dolt-backup-swap-repair|dolt .*backup (restore|sync)'
  if [ -e "$lockdir" ]; then
    printf 'busy\tlock do backup noturno presente (%s)\n' "$lockdir"
    return 0
  fi
  local snap
  if ! snap="$("$ps_bin" -ww -axo pid=,ppid=,command= 2>/dev/null)"; then
    printf 'unknown\tps falhou\n'
    return 0
  fi
  if [ -z "$snap" ]; then
    printf 'unknown\tps não listou nenhum processo\n'
    return 0
  fi
  local hit
  hit="$(printf '%s\n' "$snap" | awk -v me="$$" -v me2="${BASHPID:-$$}" -v path="$new_dir" -v re="$busy_re" '
    { pid = $1; ppid = $2; c = $0
      sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, "", c)
      par[pid] = ppid; cmd[pid] = c; order[++n] = pid }
    END {
      p = me;  for (i = 0; i < 64 && p != "" && p != 0; i++) { skip[p] = 1; p = par[p] }
      p = me2; for (i = 0; i < 64 && p != "" && p != 0; i++) { skip[p] = 1; p = par[p] }
      for (k = 1; k <= n; k++) {
        q = order[k]
        if (q in skip) continue
        # descendente deste processo (o bash forka um subshell por $(...) e o ps o lista
        # com a MESMA linha de comando do script): também não é "outra execução".
        mine = 0; p = par[q]
        for (i = 0; i < 64 && p != "" && p != 0; i++) { if (p == me || p == me2) { mine = 1; break }; p = par[p] }
        if (mine) continue
        if (index(cmd[q], path) > 0 || cmd[q] ~ re) { print q " " substr(cmd[q], 1, 160); exit }
      }
    }')"
  if [ -n "$hit" ]; then
    printf 'busy\tprocesso em curso: %s\n' "$hit"
    return 0
  fi
  printf 'idle\t\n'
}

# _release_stale_new <db> — ver o cabeçalho acima. Toda ramificação RETORNA
# (nunca die/exit): seguro de chamar de um harness que faz source do script.
# Retorno: 0 = liberou, poupou (prova não estabelecida), dry-run ou nada a
# fazer; 1 = uso inválido ou o apagamento falhou.
_release_stale_new() {
  local db="${1-}"
  if [ -z "$db" ]; then
    log "release-stale-new: uso: $0 --release-stale-new <nome-do-banco>"
    return 1
  fi
  case "$db" in
    *[!A-Za-z0-9_]*)
      log "release-stale-new: RECUSANDO nome de banco '$db' — só [A-Za-z0-9_] (o nome vira parte de um caminho que será apagado)"
      return 1
      ;;
  esac
  case "${BACKUP_ROOT:-}" in
    ''|/)
      log "release-stale-new '$db': RECUSANDO — BACKUP_ROOT vazio ou '/'"
      return 1
      ;;
  esac
  local primary_dir="$BACKUP_ROOT/$db"
  local new_dir="$BACKUP_ROOT/$db.new"

  if [ -L "$new_dir" ]; then
    log "release-stale-new '$db': RECUSANDO — $new_dir é um symlink; este caminho nunca segue nem remove link"
    return 0
  fi
  if [ ! -e "$new_dir" ]; then
    log "release-stale-new '$db': nada a liberar — não existe $new_dir"
    return 0
  fi
  if [ ! -d "$new_dir" ]; then
    log "release-stale-new '$db': RECUSANDO — $new_dir não é um diretório"
    return 0
  fi

  # 4. idade (medida antes das provas caras, mas decidida só no gate abaixo)
  local new_mtime primary_mtime=""
  new_mtime="$(_newest_mtime "$new_dir")"
  [ -d "$primary_dir" ] && primary_mtime="$(_newest_mtime "$primary_dir")"

  # 1. primária: TEM manifest e fecha localmente
  local primary_ok=0
  if [ -d "$primary_dir" ] && [ ! -L "$primary_dir" ] && _s3proof_local_closure_ok "$primary_dir"; then
    primary_ok=1
  fi

  # 3. frescor do S3 (fingerprint)
  local fp_file parsed_file
  fp_file="$(mktemp "${TMPDIR:-/tmp}/dolt-stale-new-fp.XXXXXX" 2>/dev/null)" || { log "release-stale-new '$db': SPARED — não consegui criar arquivo temporário para o fingerprint; nada foi apagado"; return 0; }
  parsed_file="$(mktemp "${TMPDIR:-/tmp}/dolt-stale-new-parsed.XXXXXX" 2>/dev/null)" || { rm -f "$fp_file"; log "release-stale-new '$db': SPARED — não consegui criar arquivo temporário para o parse; nada foi apagado"; return 0; }
  local fp_state; fp_state="$(printf 'unfetched\t')"
  if timeout "$AWS_TIMEOUT_SECS" "$AWS" s3 cp "s3://$BUCKET/_meta/latest.json" "$fp_file" >/dev/null 2>&1; then
    _parse_fingerprint_to_file "$fp_file" "$db" "$parsed_file"
    fp_state="$(_fingerprint_db_state "$fp_file" "$db")"
  fi
  local run_epoch=""
  if [ -s "$parsed_file" ]; then
    IFS="$(printf '\t')" read -r run_epoch _ _ < "$parsed_file"   # só o run_epoch decide aqui (tamanho/head não)
  fi
  rm -f "$fp_file" "$parsed_file" 2>/dev/null
  local fp_kind="" fp_detail=""
  IFS="$(printf '\t')" read -r fp_kind fp_detail <<< "$fp_state"

  # 2. S3: manifest presente E fecha sozinho
  local manifest_ok=0
  if timeout "$AWS_TIMEOUT_SECS" "$AWS" s3api head-object --bucket "$BUCKET" --key "$db/manifest" >/dev/null 2>&1; then
    manifest_ok=1
  fi
  local closure_ok=0
  if _s3proof_s3_closure_ok "$db"; then
    closure_ok=1
  fi

  # 5. nada em curso
  local idle_state idle_kind idle_detail idle=0
  idle_state="$(_stale_new_idle_state "$new_dir")"
  IFS="$(printf '\t')" read -r idle_kind idle_detail <<< "$idle_state"
  [ "$idle_kind" = "idle" ] && idle=1

  local now max_age
  now=$(date +%s)
  max_age="${RESEED_RELEASE_STALE_NEW_FP_MAX_AGE_SECS:-129600}"

  if _should_release_stale_new "${new_mtime:-}" "${primary_mtime:-}" "${run_epoch:-}" "$now" "$max_age" \
       "$primary_ok" "$manifest_ok" "$closure_ok" "$idle"; then
    local before_kb df_before after_kb df_after freed_mb=""
    before_kb="$(du -sk "$new_dir" 2>/dev/null | awk '{print $1}')"
    df_before="$(df -k /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $4}')"
    case "$before_kb" in ''|*[!0-9]*) : ;; *) freed_mb=$(( before_kb / 1024 )) ;; esac
    log "release-stale-new '$db': PROVA OK — primária $primary_dir TEM manifest e fecha localmente (item mais novo=${primary_mtime}); S3 fecha sozinho (_s3proof_s3_closure_ok) e o manifest existe (head-object OK para ${db}/manifest); fingerprint status ok, run_epoch=${run_epoch} (idade $(( 10#$now - 10#$run_epoch ))s <= ${max_age}s) mais novo que $new_dir (item mais novo=${new_mtime}); $new_dir é mais velho que a primária; nenhum backup/restore/reseed em curso — ${db}.new (~${freed_mb:-?}MB) está superado"
    if [ "${RESEED_RELEASE_STALE_NEW_DRY_RUN:-0}" = "1" ]; then
      log "release-stale-new '$db': DRY-RUN — nada apagado (RESEED_RELEASE_STALE_NEW_DRY_RUN=1); liberaria ~${freed_mb:-?}MB"
      return 0
    fi
    case "$new_dir" in
      "$BACKUP_ROOT"/*.new)
        if [ "$(basename "$new_dir")" != "$db.new" ]; then
          log "release-stale-new '$db': RECUSANDO — '$new_dir' não tem a forma <db>.new esperada (guarda de segurança)"
          return 0
        fi
        # Verifica o EFEITO (o diretório sumiu), não só o retorno do rm.
        if rm -rf "$new_dir" 2>>"$LOG" && [ ! -e "$new_dir" ]; then
          after_kb=0
          df_after="$(df -k /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $4}')"
          log "release-stale-new '$db': LIBERADA — $new_dir removida: du antes=${before_kb:-?}KB depois=${after_kb}KB (liberou ~${freed_mb:-?}MB); df livre antes=${df_before:-?}KB depois=${df_after:-?}KB (prova: ver a linha PROVA OK acima)"
        else
          log "release-stale-new '$db': FALHA ao remover $new_dir (pode estar parcialmente removido; a primária e o S3 não foram tocados) — investigue"
          notify_fail "release-stale-new: falha ao remover ${new_dir} — ver $LOG"
          return 1
        fi
        ;;
      *)
        log "release-stale-new '$db': RECUSANDO — '$new_dir' fora de \$BACKUP_ROOT/*.new (guarda de segurança)"
        return 0
        ;;
    esac
  else
    log "release-stale-new '$db': SPARED — prova não estabelecida, nada foi apagado (primary_ok=${primary_ok} s3_manifest_ok=${manifest_ok} s3_closure_ok=${closure_ok} idle=${idle} [${idle_kind:-?}${idle_detail:+: $idle_detail}] new_mtime=${new_mtime:-none} primary_mtime=${primary_mtime:-none} run_epoch=${run_epoch:-none} now=${now} max_age=${max_age}s fingerprint_state=${fp_kind:-unknown}${fp_detail:+ ($fp_detail)})"
  fi
  return 0
}

# _run_reseed <db> — todo o mecanismo (preflights, construção, verificação,
# troca), extraído para função só para caber num LIB mode testável
# (DOLT_BACKUP_RESEED_LIB=1) sem mudar nenhum comportamento do fluxo normal.
# Assim como o script linear que isto substitui, termina o processo via
# die()/exit — não devolve controle ao chamador em caso de erro.
_run_reseed() {
  local DB="$1"
  [ -n "$DB" ] || die "uso: $0 <nome-do-banco>"

  local BACKUP_DIR="$BACKUP_ROOT/$DB"
  local NEW_DIR="$BACKUP_DIR.new"
  local OLD_DIR="$BACKUP_DIR.old"

  log "=== re-seed de '$DB' ==="

  # ── Preflight 1: o banco existe e responde? ─────────────────────────────────
  # Terceiro estado: falha de QUERY e "banco vazio" não podem virar o mesmo valor.
  # Se não conseguimos ler a origem, não temos com o que comparar depois -- e um
  # re-seed sem verificação possível é pior que nenhum re-seed.
  local LIVE_COUNT
  LIVE_COUNT=$(timeout 60 "$GC_BIN" dolt sql -q "SELECT COUNT(*) FROM \`$DB\`.issues" 2>/dev/null \
               | grep -oE '^\| *[0-9]+' | grep -oE '[0-9]+' | head -1)
  if [ -z "$LIVE_COUNT" ]; then
    die "não consegui ler a contagem de issues do banco vivo '$DB'. Sem baseline não há verificação possível, e sem verificação não se troca backup."
  fi
  log "origem viva: $LIVE_COUNT issues (baseline de verificação)"

  # ── Preflight 2: espaço em disco ────────────────────────────────────────────
  local LIVE_KB NEED_KB FREE_KB
  LIVE_KB=$(du -sk "$CITY/.beads/dolt/$DB" 2>/dev/null | awk '{print $1}')
  [ -n "$LIVE_KB" ] || die "não consegui medir o tamanho vivo de '$DB'"
  NEED_KB=$(( LIVE_KB * DISK_MARGIN_PCT / 100 ))
  # Volume de DADOS. ⚠️ `df /` MENTE no macOS (reporta o volume de SISTEMA, selado
  # e de tamanho fixo) -- já quase fez um P0 vivo ser fechado nesta cidade.
  FREE_KB=$(df -k /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $4}')
  [ -n "$FREE_KB" ] || die "não consegui medir o disco livre"
  log "espaço: preciso ~$((NEED_KB/1024))MB (fluxo normal, ${DISK_MARGIN_PCT}%), livre $((FREE_KB/1024))MB"

  local LOW_DISK_MODE=0
  local FREE_OLD_FIRST=0
  if [ "$FREE_KB" -lt "$NEED_KB" ]; then
    if [ "$RESEED_ALLOW_LOW_DISK" != "1" ]; then
      die "disco insuficiente. NÃO iniciando: um sync que enche o disco no meio é exatamente como se corrompe o Dolt (precedente: ga-vs55, 14/07). (modo de baixo disco desabilitado via RESEED_ALLOW_LOW_DISK=0)"
    fi
    local LOW_NEED_KB=$(( LIVE_KB * LOW_DISK_MARGIN_PCT / 100 ))
    LOW_DISK_MODE=1
    if [ "$FREE_KB" -lt "$LOW_NEED_KB" ]; then
      # ga-74tts6: o hq real bateu exatamente aqui — livre (~4-6GB) nem cobre
      # os ~120% (~9,2GB) que este modo de baixo disco pede para construir a
      # cópia nova COM o antigo ainda no lugar. A recusa direta (comportamento
      # antigo) faz o mecanismo de alívio recusar exatamente quando ele é mais
      # necessário -- o mesmo catch-22 que abriu esta bead. Antes de desistir,
      # verifica se LIBERAR o antigo (com a MESMA prova do S3 que o Passo 1.5
      # abaixo já usa) abriria espaço suficiente -- só então vale a pena pagar
      # o preço de inverter a ordem (apagar antes de construir).
      local OLD_DIR_KB=0
      if [ -d "$BACKUP_DIR" ]; then
        OLD_DIR_KB=$(du -sk "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
        case "$OLD_DIR_KB" in ''|*[!0-9]*) OLD_DIR_KB=0 ;; esac
      fi
      local PROJECTED_KB=$(( FREE_KB + OLD_DIR_KB ))
      # ga-gsnee8: depois de liberar o antigo o disco tem de comportar DUAS
      # cópias ao mesmo tempo -- NEW_DIR (a cópia nova, com a folga de
      # LOW_DISK_MARGIN_PCT) e VERIFY_DIR (a restauração de verificação, que
      # coexiste com NEW_DIR até o dado ser lido) --, não só a primeira. Contar
      # só a nova deixava o modo apagar o antigo e depois estourar o disco no
      # meio da restauração.
      local RESTORE_NEED_KB=$(( LIVE_KB * RESTORE_COPY_PCT / 100 ))
      local ULTRA_NEED_KB=$(( LOW_NEED_KB + RESTORE_NEED_KB ))
      if [ "$PROJECTED_KB" -lt "$ULTRA_NEED_KB" ]; then
        die "disco insuficiente até liberando o backup antigo (livre $((FREE_KB/1024))MB + antigo $((OLD_DIR_KB/1024))MB = $((PROJECTED_KB/1024))MB, preciso ~$((ULTRA_NEED_KB/1024))MB = cópia nova ~$((LOW_NEED_KB/1024))MB + cópia da restauração de verificação ~$((RESTORE_NEED_KB/1024))MB, que coexistem antes da troca). NÃO iniciando: um sync que enche o disco no meio é exatamente como se corrompe o Dolt (precedente: ga-vs55, 14/07)."
      fi
      FREE_OLD_FIRST=1
      log "livre $((FREE_KB/1024))MB não cobre nem uma cópia nova (~$((LOW_NEED_KB/1024))MB) com o antigo ainda no lugar -- mas liberando o antigo (~$((OLD_DIR_KB/1024))MB, com prova do S3) chegaria a ~$((PROJECTED_KB/1024))MB, o suficiente para a cópia nova MAIS a restauração de verificação (~$((ULTRA_NEED_KB/1024))MB). Vou provar e liberar ANTES de escrever qualquer coisa nova (ordem invertida do modo de baixo disco normal abaixo)."
    else
      log "modo de baixo disco ativado para '$DB': livre $((FREE_KB/1024))MB cobre uma cópia nova (~$((LOW_NEED_KB/1024))MB) mas não as duas do fluxo normal (~$((NEED_KB/1024))MB) -- vou liberar o backup antigo, com prova do S3, SE precisar do espaço dele para a verificação."
    fi
  fi

  # ── Preflight 3: estado limpo ────────────────────────────────────────────────
  [ -e "$NEW_DIR" ] && die "$NEW_DIR já existe — resíduo de uma execução anterior. Investigue antes; não vou sobrescrever backup."
  [ -e "$OLD_DIR" ] && die "$OLD_DIR já existe — resíduo de uma execução anterior. Investigue antes."

  local OLD_FREED_EARLY=0

  # ── Passo 0.5 (só quando nem uma cópia nova cabe com o antigo no lugar,
  # ga-74tts6): liberar o antigo AGORA, com prova do S3, ANTES de escrever
  # qualquer coisa nova. Ordem invertida do modo de baixo disco normal (Passo
  # 1.5 abaixo, que só libera DEPOIS de construir o novo, e só se precisar) --
  # aqui não há escolha: o Preflight 2 já confirmou que o antigo TEM que sair
  # do caminho antes de haver espaço para o novo. Mesma prova de duas partes
  # (_s3_current_backup_verified), fail-closed por construção: se falhar, nada
  # é apagado.
  if [ "$FREE_OLD_FIRST" = "1" ]; then
    if ! _s3_current_backup_verified "$DB" "$BACKUP_DIR"; then
      die "modo ULTRA de baixo disco: prova do S3 FALHOU para '$DB' (o S3 não restaura -- fecho do manifest --, ou não tem cada arquivo local, mesmo após o reparo) -- NADA foi apagado. O backup antigo segue intacto em $BACKUP_DIR."
    fi
    local OLD_FREED_SIZE; OLD_FREED_SIZE="$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')"
    log "modo ULTRA de baixo disco: prova do S3 OK para '$DB' -- liberando o antigo ($BACKUP_DIR, ~${OLD_FREED_SIZE:-?}) ANTES de construir, porque não há espaço para os dois coexistirem."
    if ! rm -rf "$BACKUP_DIR"; then
      die "modo ULTRA de baixo disco: rm -rf do backup antigo falhou -- NADA foi trocado, mas investigue $BACKUP_DIR manualmente (pode estar parcialmente removido)."
    fi
    OLD_FREED_EARLY=1
    log "modo ULTRA de baixo disco: antigo liberado (~${OLD_FREED_SIZE:-?}). ATENÇÃO: '$DB' fica SEM BACKUP LOCAL até a verificação abaixo terminar -- o S3 (verificado agora) é o único fallback nesta janela."
  fi

  # ── Passo 1: backup novo, em local novo ─────────────────────────────────────
  # ga-o3nqy2: server-free (dolt-offline-backup-sync.sh) — sem isso, o mesmo
  # CALL DOLT_BACKUP via servidor que falha no hq desde 11/09 (corte de conexão
  # em 30s, listener.read_timeout_millis) falharia aqui igual, e para hq
  # (6,8GB+) um sync completo estoura esse timeout com folga.
  mkdir -p "$NEW_DIR" || die "não consegui criar $NEW_DIR"
  log "sincronizando via caminho offline (sem servidor, sem timeout de conexão)..."
  _offline_backup_sync "$DB" "$NEW_DIR" \
    || { rm -rf "$NEW_DIR"; die "sync offline falhou. Nada foi trocado; o backup antigo segue intacto."; }

  local NEW_FILES OLD_FILES
  NEW_FILES=$(find "$NEW_DIR" -name "*.darc" 2>/dev/null | wc -l | tr -d ' ')
  OLD_FILES=$(find "$BACKUP_DIR" -name "*.darc" 2>/dev/null | wc -l | tr -d ' ')
  log "backup novo: $NEW_FILES arquivo(s) | antigo: $OLD_FILES arquivo(s)"

  # ── Passo 1.5 (só no modo de baixo disco NORMAL): liberar o antigo SE ───────
  # precisar do espaço dele para caber a verificação (a segunda cópia).
  # Deferido até aqui de propósito -- o mais tarde possível -- para maximizar a
  # chance de NUNCA precisar tocar no antigo (se o uso real veio menor que a
  # estimativa conservadora do Preflight 2, por exemplo) e minimizar a janela
  # sem backup local quando precisar mesmo. Pulado quando o Passo 0.5 já
  # liberou o antigo (OLD_FREED_EARLY=1, modo ULTRA) -- $BACKUP_DIR já não
  # existe nesse caso, e tentar provar/apagar de novo aqui destruiria a prova
  # (du de um diretório inexistente não é "incoerente", é vazio).
  if [ "$LOW_DISK_MODE" = "1" ] && [ "$OLD_FREED_EARLY" != "1" ]; then
    local FREE_KB_NOW VERIFY_NEED_KB
    FREE_KB_NOW=$(df -k /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $4}')
    VERIFY_NEED_KB=$(( LIVE_KB * LOW_DISK_MARGIN_PCT / 100 ))
    if [ -z "$FREE_KB_NOW" ] || [ "$FREE_KB_NOW" -lt "$VERIFY_NEED_KB" ]; then
      log "modo de baixo disco: livre agora $((${FREE_KB_NOW:-0}/1024))MB não cobre a verificação (~$((VERIFY_NEED_KB/1024))MB) -- avaliando liberar o backup antigo ($BACKUP_DIR) antes de continuar."
      # ga-gsnee8: só vale apagar o antigo se apagá-lo REALMENTE abre o espaço
      # que a restauração precisa (mesma classe do modo ULTRA: uma exclusão
      # autorizada sem provar que ela cumpre o propósito). Se livre + antigo
      # ainda não cobre a verificação, apagar deixaria o banco sem backup local
      # E o restore estouraria o disco do mesmo jeito. `df` ilegível conta como
      # 0 livre: é o lado pessimista de uma conta cujo "passou" AUTORIZA uma
      # exclusão -- na dúvida não se apaga.
      local OLD_KB_NOW
      OLD_KB_NOW=$(du -sk "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
      case "$OLD_KB_NOW" in ''|*[!0-9]*) OLD_KB_NOW=0 ;; esac
      if [ $(( ${FREE_KB_NOW:-0} + OLD_KB_NOW )) -lt "$VERIFY_NEED_KB" ]; then
        rm -rf "$NEW_DIR"
        die "disco insuficiente para a verificação mesmo liberando o backup antigo (livre agora $((${FREE_KB_NOW:-0}/1024))MB + antigo $((OLD_KB_NOW/1024))MB = $(( (${FREE_KB_NOW:-0} + OLD_KB_NOW)/1024 ))MB, preciso ~$((VERIFY_NEED_KB/1024))MB para a restauração de verificação). NADA foi apagado: o backup antigo segue intacto em $BACKUP_DIR; o novo (não verificado) foi descartado."
      fi
      if ! _s3_current_backup_verified "$DB" "$BACKUP_DIR"; then
        rm -rf "$NEW_DIR"
        die "modo de baixo disco: prova do S3 FALHOU para '$DB' (o S3 não restaura -- fecho do manifest --, ou não tem cada arquivo local, mesmo após o reparo) -- NADA foi apagado. O backup antigo segue intacto em $BACKUP_DIR; o novo (não verificado) foi descartado."
      fi
      local OLD_FREED_SIZE; OLD_FREED_SIZE="$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')"
      log "modo de baixo disco: prova do S3 OK para '$DB' -- liberando o antigo ($BACKUP_DIR, ~${OLD_FREED_SIZE:-?}) ANTES da verificação, para caber o restore."
      if ! rm -rf "$BACKUP_DIR"; then
        rm -rf "$NEW_DIR"
        die "modo de baixo disco: rm -rf do backup antigo falhou -- NADA foi trocado, mas investigue $BACKUP_DIR manualmente (pode estar parcialmente removido)."
      fi
      OLD_FREED_EARLY=1
      log "modo de baixo disco: antigo liberado (~${OLD_FREED_SIZE:-?}). ATENÇÃO: '$DB' fica SEM BACKUP LOCAL até a verificação abaixo terminar -- o S3 (verificado agora) é o único fallback nesta janela."
    else
      log "modo de baixo disco: livre agora $((FREE_KB_NOW/1024))MB já cobre a verificação (~$((VERIFY_NEED_KB/1024))MB) -- mantendo o antigo intacto por enquanto, mesma prudência do fluxo normal."
    fi
  fi

  # ── Passo 2: VERIFICAR restaurando e conferindo o DADO ──────────────────────
  # Este passo é o motivo do script existir. Sem ele estaríamos trocando um backup
  # provado por um desconhecido -- exatamente o risco que a regra proíbe.
  local VERIFY_DIR
  VERIFY_DIR=$(mktemp -d "/tmp/reseed-verify-$DB.XXXXXX") || die "não consegui criar diretório de verificação"
  cleanup_verify_dir() { rm -rf "$VERIFY_DIR" 2>/dev/null; }
  trap cleanup_verify_dir EXIT

  log "restaurando o backup novo para conferência..."
  if ! ( cd "$VERIFY_DIR" && timeout 1800 "$DOLT_BIN" backup restore "file://$NEW_DIR" "${DB}_verify" >/dev/null 2>&1 ); then
    rm -rf "$NEW_DIR"
    if [ "$OLD_FREED_EARLY" = "1" ]; then
      die "SEM BACKUP LOCAL: modo de baixo disco já tinha liberado o antigo (com prova do S3), e o backup novo NÃO RESTAURA. '$DB' está sem backup local agora -- o S3 verificado antes da liberação é o único fallback. Investigue imediatamente."
    fi
    die "o backup novo NÃO RESTAURA. Nada foi trocado; o antigo segue intacto. Isto é o mecanismo funcionando: descobrimos ANTES de apagar."
  fi

  local RESTORED_COUNT
  RESTORED_COUNT=$(cd "$VERIFY_DIR/${DB}_verify" 2>/dev/null && timeout 120 "$DOLT_BIN" sql -q "SELECT COUNT(*) FROM issues" 2>/dev/null \
                   | grep -oE '^\| *[0-9]+' | grep -oE '[0-9]+' | head -1)
  if [ -z "$RESTORED_COUNT" ]; then
    rm -rf "$NEW_DIR"
    if [ "$OLD_FREED_EARLY" = "1" ]; then
      die "SEM BACKUP LOCAL: modo de baixo disco já tinha liberado o antigo (com prova do S3), e não consegui LER o dado restaurado do novo. '$DB' está sem backup local agora -- o S3 verificado antes da liberação é o único fallback. Investigue imediatamente."
    fi
    die "restaurou mas NÃO consegui LER o dado restaurado. 'Não sei' não é 'está ok' — nada foi trocado."
  fi

  # Libera a cópia de verificação ASSIM QUE o dado foi lido. Não reduz o PICO
  # (que acontece durante a restauração), mas encurta a janela em que ele
  # persiste — antes ficava ocupado até o fim do script, atravessando a troca.
  rm -rf "$VERIFY_DIR" 2>/dev/null

  log "conferência: restaurado=$RESTORED_COUNT vs vivo=$LIVE_COUNT"
  # A origem pode ter crescido durante o sync (a cidade escreve o tempo todo), por
  # isso >= e não ==. Menos que o baseline significaria PERDA, e aí abortamos.
  if [ "$RESTORED_COUNT" -lt "$LIVE_COUNT" ]; then
    rm -rf "$NEW_DIR"
    if [ "$OLD_FREED_EARLY" = "1" ]; then
      die "SEM BACKUP LOCAL: modo de baixo disco já tinha liberado o antigo (com prova do S3), e o novo tem MENOS dado que a origem ($RESTORED_COUNT < $LIVE_COUNT). '$DB' está sem backup local agora -- o S3 verificado antes da liberação é o único fallback. Investigue imediatamente."
    fi
    die "o backup novo tem MENOS dado que a origem ($RESTORED_COUNT < $LIVE_COUNT). Nada foi trocado."
  fi

  # ── Passo 3: trocar (só agora, com prova na mão) ────────────────────────────
  log "verificação OK. Trocando."

  if [ "$OLD_FREED_EARLY" = "1" ]; then
    # O antigo já foi liberado (com prova do S3) lá no Passo 1.5 -- não há
    # ".old" para criar, só promover o novo já verificado direto ao lugar.
    if ! mv "$NEW_DIR" "$BACKUP_DIR"; then
      die "SEM BACKUP LOCAL: modo de baixo disco já tinha liberado o antigo, e promover o novo (verificado) TAMBÉM falhou. '$DB' está SEM BACKUP LOCAL agora. $NEW_DIR (verificado, mv falhou no meio) pode estar parcialmente movido; investigue AGORA -- o S3 é o único fallback."
    fi
    local NEW_SIZE; NEW_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
    log "trocado (modo de baixo disco — sem período de .old, antigo já liberado com prova do S3). novo=$NEW_SIZE ($NEW_FILES arquivos)"
    _publish_after_swap "$DB" "$BACKUP_DIR" "$RESTORED_COUNT"
    log "=== re-seed de '$DB' concluído com sucesso (modo de baixo disco) ==="
    exit 0
  fi

  mv "$BACKUP_DIR" "$OLD_DIR" || die "falhou ao mover o backup antigo; nada trocado"
  if ! mv "$NEW_DIR" "$BACKUP_DIR"; then
    # gate-fix 2 (ga-kawer3): o rollback abaixo não pode se autodeclarar
    # bem-sucedido sem checar o próprio resultado -- é a REGRA INEGOCIÁVEL do
    # topo do arquivo (nunca declarar êxito sem verificar) aplicada ao próprio
    # caminho de recuperação. "mv foi chamado" e "o antigo está de volta" são
    # perguntas diferentes; só a segunda autoriza dizer "RESTAURADO".
    if mv "$OLD_DIR" "$BACKUP_DIR"; then
      die "falhou ao promover o backup novo — rollback confirmado, antigo RESTAURADO em $BACKUP_DIR. O novo (verificado, mas não promovido) segue intacto em $NEW_DIR para investigação; não foi apagado."
    else
      die "FALHA DUPLA -- o cenário mais grave que este script pode produzir: falhou ao promover o novo E o rollback do antigo TAMBÉM falhou. $BACKUP_DIR pode estar ausente ou vazio agora. NÃO toque em nada: o antigo (bom) pode ainda estar em $OLD_DIR e o novo (verificado) em $NEW_DIR, mas qual sobreviveu não está confirmado. Investigue manualmente antes de qualquer ação."
    fi
  fi

  # Reaponta o remote canônico (o caminho não mudou, mas o conteúdo sim).
  local OLD_SIZE NEW_SIZE
  OLD_SIZE=$(du -sh "$OLD_DIR" 2>/dev/null | awk '{print $1}')
  NEW_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
  log "trocado. antigo=$OLD_SIZE ($OLD_FILES arquivos) -> novo=$NEW_SIZE ($NEW_FILES arquivos)"

  # ⚠️ NÃO apagamos o antigo automaticamente. Ele fica em .old para um humano
  # (ou para dolt-backup-residue-reclaim.sh, com prova do S3) remover depois.
  # Apagar backup é irreversível, e a economia de disco não vale o risco de um
  # automatismo errar em silêncio. O ganho já está garantido: o novo está no
  # lugar e verificado.
  log "antigo preservado em $OLD_DIR — remova à mão quando estiver confortável, ou deixe o residue-reclaim liberar quando o S3 confirmar."
  _publish_after_swap "$DB" "$BACKUP_DIR" "$RESTORED_COUNT"
  log "=== re-seed de '$DB' concluído com sucesso ==="
  exit 0
}

# Library mode: `DOLT_BACKUP_RESEED_LIB=1 source dolt-backup-reseed.sh` defines
# the functions above (including _run_reseed and _s3_current_backup_verified)
# without executing anything — no live dolt/aws call, nothing deleted. Used by
# dolt-backup-reseed.selftest.sh.
if [ "${DOLT_BACKUP_RESEED_LIB:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

# ga-qh8gkw: standalone mode — free a manifest-less PRIMARY on S3-only proof
# (see _release_manifestless_primary's own header). Never runs as part of the
# normal `dolt-backup-reseed.sh <db>` invocation below; must be asked for
# explicitly.
if [ "$DB" = "--release-manifestless-primary" ]; then
  _release_manifestless_primary "${2:-}"
  exit $?
fi

# ga-bo08jp: standalone mode — free a stale "<db>.new" left beside a valid
# primary and a fresh, proven S3 copy (see _release_stale_new's own header).
# Like the mode above, never part of the normal invocation; must be asked for.
if [ "$DB" = "--release-stale-new" ]; then
  _release_stale_new "${2:-}"
  exit $?
fi

_run_reseed "$DB"
