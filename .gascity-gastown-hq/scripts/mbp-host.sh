#!/usr/bin/env bash
# mbp-host.sh — "qual nome uso para falar com o MBP?" (ga-bmmxka).
#
# Contents
#   Por quê · Regra · Saída · Como é usado · Segurança
#
# POR QUÊ: o padrão dos scripts era athos@athoss-macbook-pro.local (mDNS). Com a tela do MBP travada a rota mDNS/LAN cai
#   (o MBP continua ligado e acordado) e o nome do Tailscale responde. Resultado: o offload via mbp-run.sh e a restauração do
#   lab viam "MBP inalcançável" com o MBP de pé. O Athos remendou o ~/.ssh/config do mini à mão (arquivo fora do repo); este
#   arquivo põe o mesmo conserto no código. (Diagnóstico corrigido pelo Mayor: NÃO era sleep, então caffeinate não entra.)
#
# REGRA — o Tailscale é o padrão; a LAN só entra com EVIDÊNCIA POSITIVA e só quando o Tailscale não respondeu:
#   1. porta 22 do nome do Tailscale responde        -> athos@athoss-macbook-pro
#   2. senão, porta 22 do nome .local responde       -> athos@athoss-macbook-pro.local
#   3. senão (nenhum respondeu, sonda ilegível, nc ausente) -> o nome do Tailscale (o padrão inerte: quem chamou falha ali
#      com a mensagem de sempre, "inalcançável", e não num nome que nunca foi visto de pé).
#   Três estados por sonda: respondeu / não respondeu / não consegui saber. Só "respondeu" muda a escolha; os outros dois
#   caem no Tailscale. As duas sondas largam juntas (a do .local não atrasa o caso comum) e cada uma tem relógio de parede de
#   MBP_HOST_PROBE_S (2 s): um MBP desligado custa no máximo ~2 s a mais, e o mDNS pendurado não segura ninguém.
#
# SAÍDA: `mbp_default_host` imprime UMA linha, user@host, sempre não vazia. Executado direto (`bash mbp-host.sh`) imprime o
#   mesmo. Incluído (source), só define funções e MBP_TS_HOST / MBP_LAN_HOST.
#
# COMO É USADO: mbp-run.sh e dolt-restore-lab-mbp.sh incluem este arquivo e fazem `${MBP_HOST:-$(mbp_default_host)}`: MBP_HOST
#   definido por quem chama NUNCA é sondado nem trocado. mbp-proof.py roda `bash mbp-host.sh` quando MBP_PROOF_SSH não está definido, mas só em `e2e` e `install --apply`
#   (os que conectam); `plan` e `install` sem --apply não sondam e mostram o nome do Tailscale.
#   Selftests: MBP_HOST_PROBE=<comando> troca a sonda (recebe HOST PORTA; rc 0 = respondeu) e nada toca a rede.
#
# SEGURANÇA: só abre e fecha uma conexão TCP na porta 22 (nc -z); não autentica, não envia nada, não escreve arquivo. Compatível
#   com o bash 3.2 do macOS.

MBP_TS_HOST=${MBP_TS_HOST:-athos@athoss-macbook-pro}
MBP_LAN_HOST=${MBP_LAN_HOST:-athos@athoss-macbook-pro.local}

# 0 = a porta 22 respondeu (evidência positiva); qualquer outra coisa = sem evidência.
# Relógio de parede em bash puro (nc -z não tem timeout portátil no macOS e o mDNS pode demorar bem mais que 2 s).
# Segundos ausentes ou fora de inteiro >= 1 voltam ao padrão (2).
_mbp_host_up() { # $1 = user@host
  local h=${1#*@} s=${MBP_HOST_PROBE_S:-2} pid wd rc
  case "$s" in ''|*[!0-9]*) s=2 ;; esac
  [ "$s" -ge 1 ] || s=2
  [ -n "$h" ] || return 1
  if [ -n "${MBP_HOST_PROBE:-}" ]; then "$MBP_HOST_PROBE" "$h" 22 </dev/null >/dev/null 2>&1; return $?; fi
  command -v nc >/dev/null 2>&1 || return 1
  nc -z "$h" 22 </dev/null >/dev/null 2>&1 & pid=$!
  ( sleep "$s"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 & wd=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  return $rc
}

mbp_default_host() {
  local lan_pid
  # vazio/falhou/ilegível → Tailscale (o padrão inerte); só "respondeu" na LAN, com o Tailscale mudo, escolhe a LAN.
  # A sonda da LAN largada à toa (Tailscale respondeu) termina sozinha em <= MBP_HOST_PROBE_S: o relógio dela é o dela, e a
  # saída vai para /dev/null, então nem um $(…) nem o pipe do chamador esperam por ela.
  _mbp_host_up "$MBP_LAN_HOST" >/dev/null 2>&1 & lan_pid=$!
  if _mbp_host_up "$MBP_TS_HOST"; then printf '%s\n' "$MBP_TS_HOST"; return 0; fi
  if wait "$lan_pid" 2>/dev/null; then printf '%s\n' "$MBP_LAN_HOST"; return 0; fi
  printf '%s\n' "$MBP_TS_HOST"
}

# Executado direto: imprime o veredito. Incluído: só as definições acima.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then mbp_default_host; fi
