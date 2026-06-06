{{ define "town-deltas" }}
### Town Deltas (ADITIVO — não substitui operational-awareness nativo)

Estes são acréscimos específicos desta town. A doutrina base (3307 sagrado,
protocolo Dolt-frágil, nudge-first, mail lifecycle, não-adotar-identidade) já
vem do fragment NATIVO `operational-awareness` — NÃO duplicar aqui.

**Secrets — Bitwarden é source of truth.** Tokens (MOTHERDUCK_TOKEN, whapi,
pipedrive, hex, etc.) vêm do vault via `secret <item-name>` (~/.local/bin/secret).
Nunca hardcode. Falha: `~/.gastown/scripts/secrets-bootstrap.sh --ensure`.

**Notifications — `notify` CLI** (~/.local/bin/notify) p/ ops longas (>30s):
`notify 'Work complete: <desc>'` | `notify -t 'Title' -p 4 'High priority'`.
Topic privado ntfy. NÃO enviar notificações de crédito.

**whatsapp_automation é um rig Gas City** (como os outros): beads + orquestração
no HQ (:52756). Workers spawnam ON-DEMAND (modelo contido — sem agentes always-on;
mayor human-attached, workers só via sling/route). Os daemons de DOMÍNIO do WA
(:8095/:8097, sync MotherDuck, collectors/touchpoints) são independentes do plano
de beads — NÃO se tocam na orquestração. (A doutrina antiga "WA fica no 3307 +
mail-bridge, nunca spawnar worker no WA" está OBSOLETA — o Overseer decidiu a
migração COMPLETA de todos os rigs pro Gas City.)

**Mockups / web-UI para aprovação do Athos — OBRIGATÓRIO: S3 presigned URL.**
NUNCA entregue mockup como PNG, localhost URL ou servidor local/tunnel (o tunnel
cloudflared já deu 404 nele). O Athos DECIDE VENDO no celular.
Fluxo obrigatório:
1. `aws s3 cp <arquivo.html> s3://whatsapp-viewer-549710416969/mockups/<nome>.html --content-type "text/html; charset=utf-8"`
2. `aws s3 presign s3://whatsapp-viewer-549710416969/mockups/<nome>.html --expires-in 604800`
3. Envie ao Athos o URL presigned (abre direto no celular, sem VPN, sem server local).

**Filesystem de rede / CloudStorage pode PENDURAR a sessão (ga-khuz1).** NUNCA
rode `ls`/`find`/`stat`/`cat`/`grep` direto contra paths do Google Drive ou
iCloud (`~/Library/CloudStorage/...`) nem qualquer mount FUSE/rede sem limite de
tempo. Esse I/O pode travar em sleep ininterruptível e PENDURAR a sessão
indefinidamente — o timeout nativo do Bash NÃO mata de forma confiável um
processo preso num mount FUSE. Vale para o loop principal E para subagentes
(Explore/Task): foi um `ls` de subagente num path CloudStorage que pendurou a
crew thies-wa por 15min. Se PRECISAR tocar num path desses: (1) prefira a fonte
canônica do dado (DB/API) a varrer a árvore do Drive; (2) envolva SEMPRE em
`timeout` (ex.: `timeout 15 ls ...`); (3) verifique antes que o mount responde.
Rede de segurança: o `crew-hang-detector` detecta sessões de crew com heartbeat
congelado e dispara o shutdown-dance (kill+restart com devido processo).
{{ end }}
