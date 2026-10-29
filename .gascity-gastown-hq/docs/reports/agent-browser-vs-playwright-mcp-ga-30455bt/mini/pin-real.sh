#!/bin/bash
# pin-real.sh <porta-cdp> <rotulo>  -- UMA sessao agent-browser --pin-tab, UMA aba leve (data:), fecha a aba no fim.
# Prova: (1) a aba do pin e NOVA (nao sequestra aba de ninguem), (2) as abas que ja existiam seguem com a mesma URL e titulo,
# (3) depois do tab close a contagem volta. So le /json/list e fala com a propria aba.
PORT=$1; LABEL=$2; E=$3
AB=$E/bin-ab/agent-browser; SES="pin-ga-g7zyxc3-$$-$(date +%s)"
ab(){ env -i HOME=$E/home-ab PATH=/usr/bin:/bin AGENT_BROWSER_SOCKET_DIR=/tmp/abe "$AB" --session "$SES" --cdp "$PORT" "$@" 2>&1; }
lst(){ curl -s --max-time 5 "http://127.0.0.1:$PORT/json/list" | jq -r '[.[]|select(.type=="page")|(.id[0:8]+" "+(.title[0:40])+" | "+(.url|split("?")[0]|split("#")[0]|.[0:70]))]|sort|.[]'; }
echo "[$LABEL] antes:"; lst > /tmp/abe/pin-before-$$.txt; cat /tmp/abe/pin-before-$$.txt | sed 's/^/   /'; N0=$(wc -l < /tmp/abe/pin-before-$$.txt | tr -d ' ')
echo "[$LABEL] open (pin):"; ab --pin-tab open 'data:text/html,<title>pin-probe-ga-g7zyxc3</title><p>probe' | head -2 | sed 's/^/   /'
echo "[$LABEL] get title -> $(ab get title)"
echo "[$LABEL] durante:"; lst > /tmp/abe/pin-during-$$.txt; N1=$(wc -l < /tmp/abe/pin-during-$$.txt | tr -d ' ')
diff /tmp/abe/pin-before-$$.txt /tmp/abe/pin-during-$$.txt | grep -E '^[<>]' | sed 's/^/   /'
echo "[$LABEL] paginas: antes=$N0 durante=$N1"
echo "[$LABEL] tab close -> $(ab tab close | head -1)"
ab close >/dev/null 2>&1; sleep 1
lst > /tmp/abe/pin-after-$$.txt; N2=$(wc -l < /tmp/abe/pin-after-$$.txt | tr -d ' ')
if diff -q /tmp/abe/pin-before-$$.txt /tmp/abe/pin-after-$$.txt >/dev/null; then echo "[$LABEL] depois: IDENTICO ao antes ($N2 paginas, mesmas URLs e titulos)"; else echo "[$LABEL] depois: DIFERENTE do antes"; diff /tmp/abe/pin-before-$$.txt /tmp/abe/pin-after-$$.txt | sed 's/^/   /'; fi
curl -s --max-time 5 "http://127.0.0.1:$PORT/json/version" | jq -r '"[\(env.LABEL // "?")] chrome vivo: \(.Browser)"' 2>/dev/null
