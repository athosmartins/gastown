#!/usr/bin/env bash
# mbp-presence.sh — "o Athos está usando o MacBook Pro agora?" (ga-77c1qg, épico ga-sokx7u).
#
# Contents
#   Por quê · Regra · Saída · Como é usado · Segurança
#
# POR QUÊ (Athos 12/10, verbatim): "usar o MBP não é indiscriminado. O Mini é dedicado como servidor e construtor / gas city e
#   o MBP é o que uso pra trabalhar. a) quando MBP estiver idle, queremos usar 100% de sua capacidade [...] sempre que o MBP for
#   travado, a gente detecta como idle e joga uma carga alta pra ele; b) quando eu estiver exigindo muito do MBP, nosso framework
#   não pode de forma alguma sobrecarregá-lo mais ainda; c) manualmente eu devo poder habilitar / cancelar o uso do MBP [...] e
#   deve ficar claro se está sendo usado ou não, e como."
#
# REGRA — só EVIDÊNCIA POSITIVA de "Athos fora" libera carga alta; qualquer dúvida é "em uso" (o lado que protege o Athos):
#   livre   tela BLOQUEADA (CGSSessionScreenIsLocked da sessão do console), OU sem teclado/mouse há >= PRESENCE_AWAY_S (600 s,
#           HIDIdleTime) E nenhum app segurando a tela acesa (chamada de vídeo/vídeo/apresentação seguram a assertion
#           PreventUserIdleDisplaySleep: sem tecla há 10 min numa reunião NÃO é "fora").
#   uso     todo o resto: input recente, tela acesa por app, ou leitura que falhou (ioreg/plutil/pmset ausente, vazio, ilegível).
#   Leitura ilegível NUNCA vira "livre": são três estados (sei que sim / sei que não / não consegui saber) e o terceiro cai em "uso".
#   pausa   arquivo ~/gt-remote/PAUSE no MBP (o Athos liga com `gascity-mbp pausar`, ou o painel/mini grava): pausado é um
#           estado à parte, informado em `paused=`; quem decide o que fazer com ele é o mbp-run.sh.
#
# SAÍDA (pares k=v, um por linha; ver presence_probe)
#   presence=livre|uso   presence_why=bloqueada|ocioso | input_recente|tela_em_uso|ilegivel:tela|ilegivel:ociosidade|ilegivel:presenca|forcado
#   locked=1|0|<vazio>   idle_s=<n>|<vazio>   display_hold=1|0|<vazio>   paused=1|0   pause_info=<quem e desde quando>
#
# COMO É USADO: é INCLUÍDO (cat) no começo de cada script enviado ao MBP por ssh (preflight e execução) e roda LÁ, em bash 3.2
#   com as ferramentas da Apple; também é instalado em ~/gt-remote/bin/ (mbp-offload.sh install-mbp) para o `gascity-mbp`.
#   Executado direto (`bash mbp-presence.sh`), imprime o veredito. Incluído, só define funções e variáveis PRESENCE_*.
#
# SEGURANÇA: o único jeito de forçar um modo é PRESENCE_FORCE_USO=1 (só PIORA: vira "uso"); não existe forçar "livre". Não escreve
#   nada, não toca em tela/teclado/dado do usuário; lê ioreg, plutil e pmset, e nada além.

PRESENCE_AWAY_S=${PRESENCE_AWAY_S:-600}
case "$PRESENCE_AWAY_S" in ''|*[!0-9]*) PRESENCE_AWAY_S=600 ;; esac
PRESENCE_PAUSE_FILE=${PRESENCE_PAUSE_FILE:-$HOME/gt-remote/PAUSE}

presence_isnum() { [ "$1" -ge 0 ] 2>/dev/null; }

# locked: 1 bloqueada · 0 desbloqueada (a sessão do console foi lida e não traz a marca de bloqueio) · vazio = não consegui saber.
# A marca só existe na sessão enquanto bloqueada; sessão do console ausente (tela de login, ioreg vazio, plutil falhando) é VAZIO,
# nunca "0" — não dá para afirmar "desbloqueada" sem ter lido a sessão.
presence_locked() {
  local xml n i on lk
  xml=$(ioreg -n Root -d1 -a 2>/dev/null) || { echo; return; }
  [ -n "$xml" ] || { echo; return; }
  n=$(printf '%s' "$xml" | plutil -extract IOConsoleUsers raw -o - - 2>/dev/null)
  presence_isnum "$n" || { echo; return; }
  i=0
  while [ "$i" -lt "$n" ]; do
    on=$(printf '%s' "$xml" | plutil -extract "IOConsoleUsers.$i.kCGSSessionOnConsoleKey" raw -o - - 2>/dev/null)
    if [ "$on" = true ]; then
      lk=$(printf '%s' "$xml" | plutil -extract "IOConsoleUsers.$i.CGSSessionScreenIsLocked" raw -o - - 2>/dev/null)
      if [ "$lk" = true ]; then echo 1; else echo 0; fi
      return
    fi
    i=$((i + 1))
  done
  echo
}

# segundos sem teclado/mouse (HIDIdleTime vem em nanossegundos). Várias entradas: vale a de input mais recente (a menor).
# Qualquer entrada ilegível, ou nenhuma, → vazio (não "0", não "muito tempo").
presence_idle_s() {
  local raw v min="" bad=0
  raw=$(ioreg -c IOHIDSystem 2>/dev/null | awk '/"HIDIdleTime"/ { print $NF }')
  [ -n "$raw" ] || { echo; return; }
  for v in $raw; do
    presence_isnum "$v" || { bad=1; break; }
    if [ -z "$min" ] || [ "$v" -lt "$min" ]; then min=$v; fi
  done
  [ "$bad" = 0 ] && [ -n "$min" ] || { echo; return; }
  echo $(( min / 1000000000 ))
}

# 1 = algum app segura a tela acesa (assertion PreventUserIdleDisplaySleep > 0), 0 = nenhum, vazio = não consegui saber
presence_display_hold() {
  local a n
  a=$(pmset -g assertions 2>/dev/null) || { echo; return; }
  n=$(printf '%s\n' "$a" | awk '$1 == "PreventUserIdleDisplaySleep" { print $2; exit }')
  presence_isnum "$n" || { echo; return; }
  if [ "$n" -gt 0 ]; then echo 1; else echo 0; fi
}

presence_paused() { if [ -e "$PRESENCE_PAUSE_FILE" ]; then echo 1; else echo 0; fi; }

# Preenche PR_MODE (livre|uso), PR_WHY, PR_LOCKED, PR_IDLE, PR_HOLD, PR_PAUSED. Não imprime.
presence_eval() {
  PR_LOCKED=$(presence_locked); PR_IDLE=$(presence_idle_s); PR_HOLD=$(presence_display_hold); PR_PAUSED=$(presence_paused)
  PR_MODE=uso; PR_WHY=""
  if [ "${PRESENCE_FORCE_USO:-0}" = 1 ]; then PR_WHY=forcado
  elif [ "$PR_LOCKED" = 1 ]; then PR_MODE=livre; PR_WHY=bloqueada
  elif presence_isnum "$PR_IDLE"; then
    if [ "$PR_IDLE" -lt "$PRESENCE_AWAY_S" ]; then PR_WHY=input_recente
    elif [ "$PR_HOLD" = 0 ]; then PR_MODE=livre; PR_WHY=ocioso
    elif [ "$PR_HOLD" = 1 ]; then PR_WHY=tela_em_uso
    else PR_WHY=ilegivel:tela; fi
  elif [ -z "$PR_LOCKED" ]; then PR_WHY=ilegivel:presenca
  else PR_WHY=ilegivel:ociosidade; fi
}

# primeira linha do arquivo de pausa (quem pausou e desde quando), numa linha só e sem '|'; vazio se não há pausa
presence_pause_info() {
  [ -e "$PRESENCE_PAUSE_FILE" ] || return 0
  head -n 1 "$PRESENCE_PAUSE_FILE" 2>/dev/null | tr -d '|\r' | cut -c1-100
}

presence_probe() {
  presence_eval
  echo "presence=$PR_MODE"; echo "presence_why=$PR_WHY"
  echo "locked=$PR_LOCKED"; echo "idle_s=$PR_IDLE"; echo "display_hold=$PR_HOLD"; echo "paused=$PR_PAUSED"
  echo "pause_info=$(presence_pause_info)"
}

# executado direto (`bash mbp-presence.sh`): imprime o veredito. Incluído por `source` ou colado num script que vai a `bash -s`
# (BASH_SOURCE vazio), não imprime nada: o script que inclui decide quando chamar presence_probe/presence_eval.
if [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]}" = "$0" ] && [ -z "${PRESENCE_LIB_ONLY:-}" ]; then presence_probe; fi
