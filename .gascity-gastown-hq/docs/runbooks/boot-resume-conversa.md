## Contents
- Por que a conversa se perdia no reboot
- O que o `--final` faz agora (armar o boot)
- Depois do boot: veredito, aviso e desarme
- Instalar e ativar (ordem, e o passo do Mayor)
- Como conferir num reboot real
- Quando recusa, e os botões
- Fora desta entrega

Missão ga-esorlre (.3): crews nomeadas e Mayor voltam do reboot NA MESMA conversa que o Athos usava, sem prime duplicado.

## Por que a conversa se perdia no reboot
Medido no reboot das 23:40 de 12/11: toda crew e o Mayor subiram com `--session-id <id novo>` + o prime inteiro (os ids vivos de antes, do `live-conversation-capture.log`, não voltaram).

Causa, no código do motor (`internal/session/lifecycle_projection.go` `shouldResetContinuation`, `cmd/gc/session_reconcile.go` `healState`):
- no boot a bead da sessão está `active`, não há runtime (o tmux morreu) e não há `sleep_reason` deliberado → o motor chama isso de morte inesperada, zera `session_key` e `started_config_hash` e põe `continuation_reset_pending=true` → próxima partida é fresca (`--session-id`).
- as linhas "reset stalled for thies…" que o supervisor loga em todo boot são esse mesmo caminho (a marca velha `reset_committed_at` só o torna visível).
- o `gc stop` do próprio motor evita isso gravando `sleep_reason=city-stop` (está na lista de razões deliberadas): a chave fica e a partida seguinte faz `--resume <session_key>`.
- o Mayor tem ainda `wake_mode = "fresh"` (pack gastown): todo wake é fresco, com ou sem o item acima.
- `session_key` da bead não é a conversa do Athos (ele troca com `/resume` dentro da crew); a viva está em `~/.claude/sessions/<pid>.json` e a captura da .2 a grava em `session.live_conversation_id`.

## O que o `--final` faz agora (armar o boot)
`scripts/live-conversation-capture.py --final` (já chamado pelo D4 e pelo noturno, 30 s, sem barrar o reboot). Depois de gravar o id vivo, para cada alvo, num único `bd update` lido de volta:
- `session_key = <id vivo>`, `sleep_reason = city-stop`, `session.resume_armed_id/_at`, e a marca velha `reset_committed_at` some (se não há reset pendente).
- alvos em paralelo (6 threads); o roster vem do `bd query` primeiro (~5 s) e cai no `gc session list` (que levou 22-60 s com load 77).
- o claude de dentro do pane que o próprio claude do pane abriu (um `claude -p` de script) não conta: vale o mais externo.

## Depois do boot: veredito, aviso e desarme
Rodadas normais (120 s), alvo vivo:
- armado, `last_woke_at` depois do armar, mesmo id → `session.resume_result=ok` (+ `_at`), log `RESUMED`.
- armado, outro id → `resume_result=fresh` e UM nudge à sessão: "a conversa anterior era <id>, `claude --resume <id>` abre o histórico; releia sua bead". Reinício sem armar (guarda recusou, queda) que cai noutro id recebe o mesmo nudge. Nudge que falha repete até 3 vezes.
- armado e sem reinício em 15 min (`LCC_DISARM_AFTER_S`) → o reboot não veio: `sleep_reason=city-stop` sai (só se for o nosso).
- trocar de conversa com `/resume` dentro da crew não é reinício: sem nudge.

## Instalar e ativar (ordem, e o passo do Mayor)
1. Depois do merge: `/usr/bin/python3 scripts/live-conversation-capture.py --final --dry-run` — lista, por alvo, `WOULD arm` ou `NOT ARMED <motivo>`; não grava nada.
2. **Mayor**: o pack manda `wake_mode = "fresh"` e a recusa `wake_mode=fresh` aparece no dry-run. Para o Mayor voltar na mesma conversa, no `city.toml`, em `[[patches.agent]]` de `gastown.mayor`, acrescentar `wake_mode = "resume"`. Atenção: `wake_mode` entra na impressão digital da config (`buildFingerprintExtra`), então a mudança dispara UM config-drift na sessão viva do Mayor — faça-a numa janela de reinício planejado (ou logo antes de um reboot), não no meio do dia.
3. O que o D4 e o noturno já chamam não muda; só a linha de resumo ganhou ` armou=N recusou=N`.

## Como conferir num reboot real
- antes: `.gc/logs/live-conversation-capture.log` tem `ARMED <bead> (<sessão>)` por alvo (e `NOT ARMED` com o motivo dos outros).
- depois: `RESUMED <bead>` por alvo, e `bd show <bead-da-sessão>` com `session.resume_result=ok`.
- prova independente: `~/.claude/sessions/<pid>.json` `sessionId` de cada pane == `session.live_conversation_id` capturado antes (é o aceite da .5). Teste no CLI instalado (12/11): `claude --resume <id>` mantém o mesmo sessionId e o mesmo `<id>.jsonl`.

## Quando recusa, e os botões
Recusa = fica o padrão do motor (partida fresca) e o motivo vai ao log: `wake_mode=fresh` · reset/restart pendente · em quarentena · outro `sleep_reason` · transcript ilegível ou sem registro de uso · contexto acima de `LCC_MAX_RESUME_TOKENS` (700000; a janela do modelo é >= 1M e há crew de 300-577k, o 300k sugerido de início recusaria a maioria).
- Chamada de ferramenta em voo (transcript termina num `tool_use`) NÃO recusa: medido em 12/11, `claude --resume` de um transcript cortado logo após um `tool_use` responde normalmente (descarta a chamada órfã). `LCC_REFUSE_DANGLING=1` volta a recusar.
- `LCC_ARM=0` ou `touch .gc/live-conversation-capture.off`: volta a só capturar (o `.off` desliga tudo). `LCC_DISARM_AFTER_S`, `LCC_ARM_WORKERS` ajustam o resto.
- Sessão morta por warrant/hang: o motor a reinicia fresca (a conversa viva dali é outra); um pane travado agora é pego pelo contexto/uso.

## Fora desta entrega
- Prime duplicado na retomada (item 4): é do motor (`restartPromptNudge`, `cmd/gc/session_lifecycle_parallel.go`): patch em `docs/pending-engine-window/ga-esorlre.3-resume-short-notice.patch` (+ README); sem ele a retomada funciona, só reenvia o prompt (~20k tokens por sessão).
- Queda/pane morto sem reboot planejado: o motor segue com o padrão (fresco); só os dois reboots armam.
