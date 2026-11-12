#!/usr/bin/env bash
# prod-tests/gascity/story-ga-qg1dw5z.2.sh — prod test para ga-qg1dw5z.2: o instalador do SSH fechado do nó Hetzner (admin com chave própria, fail2ban, ufw, root sem login).
# O que esta fatia ENTREGA é o script versionado + selftest + runbook; aplicar no nó é um passo de root com prova de 2ª sessão (o Athos entra com a chave privada dele, que nenhum agente lê) e fica
# no runbook. Por isso o teste confere a INÉRCIA (o script entregue não faz nada sozinho: sem argumento e sem root ele recusa, e o corte do root só existe DEPOIS da prova de login) e só então roda a
# bateria de casos contra a árvore viva.
#
# Chamado por run.sh depois do deploy (STORY_ID=ga-qg1dw5z.2). Sai 0 se passar. Hermético: não fala com o nó, não cria usuário, não mexe em ufw/sshd (a bateria usa stubs num PATH isolado). Não roda os
# mutantes (são a evidência do gate): só a bateria de casos.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
LOCK="$CITY/scripts/hetzner-ssh-lockdown.sh"
ST="$CITY/scripts/hetzner-ssh-lockdown.selftest.sh"
RUNBOOK="$CITY/docs/runbooks/hetzner-ssh-lockdown.md"

log()  { echo "[prod-test:gascity ga-qg1dw5z.2] $*"; }
fail() { echo "[prod-test:gascity ga-qg1dw5z.2] FAIL: $*" >&2; exit 1; }

for f in "$LOCK" "$ST" "$RUNBOOK"; do [[ -f "$f" ]] || fail "arquivo implantado ausente: $f"; done
for f in "$LOCK" "$ST"; do bash -n "$f" 2>/dev/null || fail "erro de sintaxe em $f"; done
log "arquivos presentes, sintaxe ok"

# ── INÉRCIA: o que foi entregue não age sozinho
out=$(bash "$LOCK" 2>&1); rc=$?
[[ "$rc" == 2 ]] || fail "sem argumento o script devia sair 2 (saiu $rc): $out"
if [[ "$(id -u)" == 0 ]]; then
  log "rodando como root: pulo as recusas por não-root (o selftest cobre; aqui um passo de verdade mudaria a máquina)"
else
  for sub in "admin --user prod-test-nao-existe --pubkey-file /nao/existe" "fail2ban --ignoreip 192.0.2.1" "ufw --ssh-from any" "rootcut" "confirm ufw" "undo ufw"; do
    # shellcheck disable=SC2086
    out=$(bash "$LOCK" $sub 2>&1); rc=$?
    [[ "$rc" == 2 ]] || fail "'$sub' devia ser recusado (2) sem root, mas saiu $rc: $out"
  done
  log "o script recusa sem argumento e recusa cada passo que muda o nó quando não é root ✓"
fi

# o corte do root só existe DEPOIS da prova do login do admin; o ufw só liga DEPOIS da rede de segurança armada
ln_proof=$(grep -n 'nope "sem prova: nenhum login do admin' "$LOCK" | tail -1 | cut -d: -f1)
ln_cut=$(grep -n 'PermitRootLogin no\\n' "$LOCK" | tail -1 | cut -d: -f1)
[[ -n "$ln_proof" && -n "$ln_cut" ]] || fail "não achei a prova de login ($ln_proof) ou a escrita do PermitRootLogin ($ln_cut) no script"
[[ "$ln_proof" -lt "$ln_cut" ]] || fail "o PermitRootLogin no (linha $ln_cut) é escrito ANTES da prova do login do admin (linha $ln_proof)"
ln_net=$(grep -n 'die rede-nao-armada$' "$LOCK" | tail -1 | cut -d: -f1)
ln_en=$(grep -n 'ufw --force enable' "$LOCK" | tail -1 | cut -d: -f1)
[[ -n "$ln_net" && -n "$ln_en" && "$ln_net" -lt "$ln_en" ]] || fail "o ufw --force enable (linha ${ln_en:-?}) não vem depois da rede de segurança armada (linha ${ln_net:-?})"
n=$(grep -c 'PermitRootLogin no' "$LOCK")
[[ "$n" -ge 1 ]] || fail "o script não escreve PermitRootLogin no"
n=$(grep -c -E '(^|[^A-Za-z-])rm -[a-z]*r[a-z]*f?[[:space:]]' "$LOCK")
[[ "$n" == 0 ]] || fail "o script tem remoção recursiva ($n ocorrência(s))"
log "ordem: prova de login antes do corte do root; rede de segurança antes do enable; sem remoção recursiva ✓"

# ── O runbook diz como instalar, a ordem, a prova e como desfazer
for key in '## Contents' 'ga-qg1dw5z.2' 'gt-ssh-lockdown rootcut' 'confirm rootcut' 'undo rootcut' 'ssh root@' 'fail2ban-client status sshd' 'ufw status' 'hcloud' 'console da Hetzner' 'ANTES do `rootcut`' '10 min'; do
  grep -q -F -- "$key" "$RUNBOOK" || fail "runbook não descreve '$key'"
done
log "runbook ✓"

# ── A bateria de casos (sem os mutantes) contra a árvore viva
out=$(timeout 300 bash "$ST" --sem-mutantes 2>&1) || { printf '%s\n' "$out" | tail -30 >&2; fail "o selftest falhou (ou estourou o prazo) contra a árvore viva"; }
line=$(printf '%s\n' "$out" | grep -E '^[0-9]+/[0-9]+ ok \(0 mutantes\)$' | tail -1)
[[ -n "$line" ]] || fail "selftest sem a linha de resultado:
$(printf '%s\n' "$out" | tail -8)"
nums=$(printf '%s' "$line" | grep -oE '[0-9]+')
# shellcheck disable=SC2086
set -- $nums
[[ "$1" == "$2" ]] || fail "selftest reportou '$line' (ok != total)"
[[ "$1" -ge 350 ]] || fail "selftest reportou '$line' (esperado pelo menos 350 casos)"
# vazio → sem a linha final: falha; o teste é um case sobre a variável (sem `writer | grep -q`, que sob pipefail devolve "sem match" por SIGPIPE)
case "$out" in *$'\n'"SELFTEST OK") ;; *) fail "selftest sem o SELFTEST OK final" ;; esac
log "bateria do instalador: $line ✓"

log "PASS"
exit 0
