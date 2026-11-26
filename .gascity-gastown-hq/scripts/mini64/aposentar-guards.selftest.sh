#!/usr/bin/env bash
# aposentar-guards.selftest.sh — o marcador ~/.servidor-aposentado faz os scripts que gravam no S3 recusarem (ga-ke5w2ie.4, Mini64 fatia 4). `launchctl disable` (aposentar-servidor.sh) impede o JOB
# de voltar; o marcador impede o SCRIPT de subir quando alguem o roda a mao, um order do engine o dispara ou um plist volta por engano. Quatro pontos gravam no S3 neste repo: dolt-s3-backup.sh
# (aws s3 sync --delete), a lib dolt-backup-s3-proof.sh (_s3proof_mirror_up, que o dolt-gc-maintenance.sh tambem usa), dolt-backup-reseed.sh (_publish_db_fingerprint: sync --delete) e
# jsonl-hourly-offsite.sh (modo run: put/delete-object). Os modos so de leitura (--status, --age-check, --table-age) NAO recusam. NADA toca o S3, o Dolt ou o HOME reais: mundo falso, aws/dolt/notify
# stubs que so registram a chamada. G1-G4 um ponto cada (com marcador: recusa sem criar nem chamar nada; sem: segue) · G5 os tres estados do marcador · G6 tripwires (inclui o isolamento dos selftests).
set -uo pipefail; export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; CITY="$(cd "$HERE/../.." && pwd)"
S3BACKUP="${APOSENTAR_GUARD_S3BACKUP:-$CITY/scripts/dolt-s3-backup.sh}"; PROOFLIB="${APOSENTAR_GUARD_PROOFLIB:-$CITY/scripts/dolt-backup-s3-proof.sh}"   # os overrides sao da bateria de mutantes
RESEED="${APOSENTAR_GUARD_RESEED:-$CITY/scripts/dolt-backup-reseed.sh}"; OFFSITE="${APOSENTAR_GUARD_OFFSITE:-$CITY/packs/town-deltas/assets/scripts/jsonl-hourly-offsite.sh}"
PROOF_ST="${APOSENTAR_GUARD_PROOF_SELFTEST:-$CITY/scripts/dolt-backup-s3-proof.selftest.sh}"
PASS=0; FAIL=0; ok() { PASS=$((PASS+1)); printf '  ok: %s\n' "$1"; }; bad() { FAIL=$((FAIL+1)); printf '  BAD: %s\n     %s\n' "$1" "${2:-}"; }
TMP="$(mktemp -d)"; trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
gw() {   # <nome>: mundo falso com HOME proprio; aws/dolt/notify stubs que so registram a chamada em $G/<nome>.log
  G="$TMP/$1"; mkdir -p "$G/home" "$G/bin" "$G/city" "$G/tmp" "$G/state" "$G/arch"; M="$G/home/.servidor-aposentado"
  for t in aws dolt notify; do printf '#!/bin/bash\necho "$*" >> "%s/%s.log"\nexit 0\n' "$G" "$t" > "$G/bin/$t"; chmod +x "$G/bin/$t"; done
}
chk() { local d="$1" want="$2" a w=""; shift 2; [ "$RC" = "$want" ] || w="rc=$RC (queria $want)"
  for a in "$@"; do case "$a" in +*) case "$OUT$ERR" in *"${a#+}"*) ;; *) w="$w; falta «${a#+}»" ;; esac ;; -*) case "$OUT$ERR" in *"${a#-}"*) w="$w; sobrou «${a#-}»" ;; esac ;; esac; done
  if [ -z "$w" ]; then ok "$d"; else bad "$d: $w" "$(printf '%s' "$OUT$ERR" | head -c 300)"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "veio: $2 | queria: $3"; fi; }
calls() { local n=0 f; for f in aws dolt notify; do [ -e "$G/$f.log" ] && n=$((n+1)); done; echo "$n"; }   # quantos stubs foram chamados
# E: ambiente limpo (env -i) com HOME falso; X3 vazio ou outra atribuicao remove/troca o HOME; X1 = uma atribuicao extra
E() { env -i ${X3-HOME="$G/home"} TMPDIR="$G/tmp" PATH="$G/bin:/usr/bin:/bin" ${X1:+"$X1"} "$@"; }
run_s3backup() { OUT="$(E DOLT_S3_BACKUP_CITY="$G/city" DOLT_S3_BACKUP_NOTIFY="$G/bin/notify" timeout 60 /bin/bash "$S3BACKUP" 2>"$G/err")"; RC=$?; ERR="$(cat "$G/err")"; }
run_offsite() { OUT="$(E JHO_STATE_DIR="$G/state" JHO_LOG="$G/jho.log" JHO_AWS="$G/bin/aws" JHO_ARCHIVE="$G/arch" timeout 60 /bin/bash "$OFFSITE" "$@" 2>"$G/err")"; RC=$?; ERR="$(cat "$G/err")"; }
run_fn() {   # <arquivo> <codigo>: a lib e o reseed sao FUNCOES: sourced num subshell limpo, depois chamada
  OUT="$(cd "$G" && E RESEED_LOG="$G/reseed.log" DOLT_BACKUP_RESEED_LIB=1 bash -c ". $1; export AWS=$G/bin/aws BUCKET=bkt S3PROOF_LOG=$G/s3proof.log S3PROOF_UP_TIMEOUT=5; mkdir -p d; echo m > d/manifest; $2" 2>"$G/err")"
  RC=$?; ERR="$(cat "$G/err" "$G/reseed.log" "$G/s3proof.log" 2>/dev/null)"; }
MSG="servidor-aposentado: "; AP="este servidor esta APOSENTADO"

echo "── G1: dolt-s3-backup.sh · G2: _s3proof_mirror_up · G3: _publish_db_fingerprint ──"
gw g1a; echo x > "$M"; run_s3backup; chk "G1 com marcador: rc 69, nomeia o marcador" 69 "+$MSG$AP (marcador $M"
eq "G1 com marcador: nenhum stub chamado e NADA criado na cidade (a recusa vem antes do mkdir, do lock e do log)" "$(calls):$(ls -A "$G/city" | wc -l | tr -d ' ')" "0:0"
gw g1b; run_s3backup; chk "G1 sem marcador: segue (nesta cidade falsa para na porta do Dolt, rc 0)" 0 "-$MSG"; [ -s "$G/city/.gc/logs/dolt-s3-backup.log" ] || bad "G1 sem marcador: nao passou do check (sem log da cidade)"
gw g2a; echo x > "$M"; run_fn "$PROOFLIB" "_s3proof_mirror_up d db1"; chk "G2 com marcador: a funcao recusa (rc 1) e nenhum aws e chamado" 1 "+$AP"; eq "G2 stubs chamados" "$(calls)" 0
gw g2b; run_fn "$PROOFLIB" "_s3proof_mirror_up d db1"; chk "G2 sem marcador: sobe" 0; eq "G2 sem marcador: sync das tabelas e depois cp do manifest" "$(cut -d' ' -f1-2 "$G/aws.log" | tr '\n' '|')" "s3 sync|s3 cp|"
gw g3a; echo x > "$M"; run_fn "$RESEED" "_publish_db_fingerprint db2 d 7"; chk "G3 com marcador: recusa (rc 1, nao fatal: o reseed local segue) e NENHUM aws" 1 "+$AP"; eq "G3 stubs chamados" "$(calls)" 0
gw g3b; run_fn "$RESEED" "_publish_db_fingerprint db2 d 7"; case "$(head -1 "$G/aws.log" 2>/dev/null)" in "s3 sync "*" --delete "*) ok "G3 sem marcador: o aws s3 sync --delete E a 1a chamada (e ele que o marcador barra)" ;; *) bad "G3 sem marcador: 1a chamada inesperada" "$(head -2 "$G/aws.log" 2>/dev/null)" ;; esac

echo "── G4: jsonl-hourly-offsite.sh ──"
gw g4a; echo x > "$M"; run_offsite; chk "G4 modo run com marcador: rc 69" 69 "+$AP"
eq "G4 modo run com marcador: nenhum stub chamado; nao criou estado, log nem lock" "$(calls):$(find "$G/state" "$G/arch" -mindepth 1 2>/dev/null | wc -l | tr -d ' '):$([ -e "$G/jho.log" ] && echo log || echo sem)" "0:0:sem"
for modo in --status --age-check --table-age; do
  gw g4m; echo x > "$M"; run_offsite "$modo"; r=limpo; case "$OUT$ERR" in *$MSG*) r=msg ;; esac   # nunca um case DENTRO de $( ): o guarda de bash 3.2 do gate rejeita
  eq "G4 $modo com marcador NAO e recusado (so leitura: o reserva continua vendo o S3)" "$([ "$RC" = 69 ] && echo 69 || echo ok):$r" "ok:limpo"
done
gw g4b; run_offsite; chk "G4 modo run sem marcador: segue ate a checagem do archive (rc 2: o archive falso nao e um repo git)" 2 "-$MSG"

echo "── G5: os tres estados do marcador (presente / ausente / nao sei) ──"
st() { gw "$1"; eval "$2"; run_s3backup; chk "G5 $3" "$4"; X1=""; }   # st <nome> <preparo> <descricao> <rc esperado>
st g5a 'ln -s "$G/nao-existe" "$M"' "marcador que e link QUEBRADO conta como presente" 69
X3="HOME=" st g5b ':' "HOME vazio: nao sei onde fica o marcador -> recusa (inerte), nunca 'ausente'" 69
X3="NADA=1" st g5c ':' "sem HOME no ambiente: idem" 69
if [ "$(id -u)" != 0 ]; then st g5d 'mkdir -p "$G/sa"; chmod 000 "$G/sa"; X1="SERVIDOR_APOSENTADO_FILE=$G/sa/m"' "pasta do marcador sem acesso: nao sei se existe -> recusa" 69; chmod 700 "$G/sa"; fi
st g5e 'printf x > "$G/outro"; X1="SERVIDOR_APOSENTADO_FILE=$G/outro"' "SERVIDOR_APOSENTADO_FILE aponta outro lugar e o marcador la existe: recusa (o override vale)" 69
st g5f 'echo x > "$M"; X1="SERVIDOR_APOSENTADO_FILE=$G/home/nao-existe"' "override aponta um arquivo AUSENTE (e o HOME tem marcador): segue (e assim que os selftests se isolam)" 0

echo "── G6: tripwires ──"
for f in "$S3BACKUP" "$PROOFLIB" "$RESEED" "$OFFSITE"; do eq "G6 $(basename "$f") leva o bloco (1x) e le SERVIDOR_APOSENTADO_FILE" "$(grep -c 'servidor-aposentado (ga-ke5w2ie.4)' "$f"):$(grep -c 'SERVIDOR_APOSENTADO_FILE' "$f" | sed 's/^[1-9].*/ok/')" "1:ok"; done
for f in "$PROOF_ST" "$CITY/scripts/dolt-backup-reseed.selftest.sh" "$CITY/packs/town-deltas/assets/scripts/jsonl-hourly-offsite.selftest.sh"; do grep -q 'SERVIDOR_APOSENTADO_FILE' "$f" && ok "G6 $(basename "$f") isola o marcador (senao quebraria no mini ja aposentado)" || bad "G6 $(basename "$f") NAO isola SERVIDOR_APOSENTADO_FILE"; done
gw g6d; echo x > "$M"; DYN="$(cd "$(dirname "$PROOF_ST")" && env HOME="$G/home" bash "./$(basename "$PROOF_ST")" 2>&1 | tail -1)"
case "$DYN" in *FAIL=0*) ok "G6 dolt-backup-s3-proof.selftest.sh passa num HOME que TEM o marcador ($DYN)" ;; *) bad "G6 dolt-backup-s3-proof.selftest.sh quebra com o marcador no HOME" "$DYN" ;; esac

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
