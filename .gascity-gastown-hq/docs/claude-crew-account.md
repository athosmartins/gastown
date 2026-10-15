# claude-crew-account — conta Claude do Mayor e das crews, ao vivo (ga-qdtmq2)

## Contents

• O que faz (a cada 60 s, sob flock) · A tela do limite e o Escape (ga-ci3uao) · Garantias · Liga/desliga · Riscos abertos (não medidos)

Fase 2 da ga-xoe5ao. O pool headless (ga-8hcnvb.1, `claude-pool-account.py`) decide a conta; este script **segue** a decisão
para quem usa Remote Control (Mayor + crews), reescrevendo o item DEFAULT do Keychain `Claude Code-credentials`.
Decisão do Athos (06/10): ao vivo, sem reiniciar — mesmo link de RC, conversa intacta.

## O que faz (a cada 60 s, sob flock)
1. Pergunta ao endpoint de perfil quem segura o item default (não confia em memória nem em `~/.claude.json`).
2. **Sync-back** (3 resultados: salvou / nada a salvar / **não conseguiu ou não soube dizer**): copia o login do default de volta
   ao item próprio da conta que o segura (nunca por cima de login mais novo). No 3º resultado o default **NÃO é sobrescrito**
   (ele pode guardar a única cópia válida do refresh token rotacionado) e sai alerta nomeado `sync-back:<conta>`. Exceção: se o
   login que sai não é login completo, não há o que salvar e a troca segue. Só a parte `claudeAiOauth` se move: o resto do blob
   (`mcpOAuth` etc.) fica onde está, nos dois sentidos.
3. **Follow:** se a decisão aponta outra conta, grava o login COMPLETO dela no default (via `security -i`, hex no stdin).
   Sem login completo (escopo `user:sessions:claude_code` + refresh token): não escreve, alerta nomeando o login que falta.
   Default sem login completo (RC quebrado): alerta SEMPRE (mesmo com dono conhecido) e cura com a conta do pool; se ela não
   tem login, tenta as outras com saldo e o alerta diz qual login falta e por quê. Default **ausente** (`security` exit 44):
   alerta `default-missing` (1 push por janela) e NADA é criado/curado (sem dono conhecido). Default **ilegível** (keychain
   travado, JSON sem `claudeAiOauth`): só o WARN no log — não é página, pode ser transitório.
4. **Dono da fonte:** o perfil só responde por token vivo, e toda cópia guardada tem o access token vencido há 22–41 h.
   Então, em produção, o perfil quase nunca consegue dizer de quem é a fonte ANTES de trocar. Decisão (fail-open, explícita):
   a troca segue, mas fica **dita e contada**: log `source owner unverified`, `unverified_switches` no estado, identidade
   guardada como `switch-unverified` (vale só até o TTL de 6 h e é re-perguntada ao perfil a cada rodada). Quando o CLI
   renova o token e o perfil responde: dono certo → log `owner verified`; dono errado → alerta `owner-mismatch` + a fonte
   entra em quarentena (`bad_sources`, pela impressão do refresh token) e nunca mais é escrita até o login ser refeito.
   Se o perfil nunca responder em 15 min: log `still unverified` (sem push: sem sessão viva ninguém renova o token).
5. **Verify:** toda sessão que tinha bridge de Remote Control ainda a tem 60 s depois. Quem não pôde ser verificado diz que
   não foi (pasta de sessões ilegível, janela de 15 min perdida, zero bridges): nunca imprime "todas no ar". São TRÊS
   veredictos, não dois: *no ar*, *perdeu* (push `lost Remote Control`) e *não verificada* — sessão rodando cujo arquivo
   em `~/.claude/sessions` existe mas não pôde ser lido (ou há um arquivo ilegível que não dá para ligar a um pid): o log
   diz `NOT verified` com o pid, o estado guarda `rc_unjudged.unverified`, e NÃO sai push de "perdeu" (não sabemos).
   Uma 2ª troca antes de a checagem da 1ª ser julgada não a descarta: os pids da 1ª são carregados (união) e tudo é julgado
   60 s depois da ÚLTIMA troca (log `still pending ... carried`); se a 1ª troca estava cega (pasta ilegível), a checagem
   segue cega e diz isso. O push `lost Remote Control` que não foi entregue (`notify` fora do ar) é refeito após 5 min
   (`rc_lost.push_pending`) até sair uma vez — e não se repete. Sessão que
   terminou sozinha entre a troca e a checagem não conta como bridge no ar: o log diz "X de N ... Y terminaram sozinhas" (ou
   "nenhuma sobrou para verificar"). Pid reaproveitado pelo SO não conta como bridge viva (compara `procStart` da sessão com
   `TZ=UTC ps -o lstart=`).

## A tela do limite e o Escape (ga-ci3uao)
**O que aconteceu (14/10, ga-ci3uao):** a troca rodou 16:09Z e o VERIFY registrou "all 5 Remote Control bridges are still up" — verdade, e
irrelevante: a ponte do RC não diz em QUAL conta a sessão está. Mayor, oracle, peter e thies seguiram 10–12 min na tela de limite da conta
antiga (a pergunta "What do you want to do? / 1. Stop and wait for limit to reset ... Enter to confirm · Esc to cancel") até o Athos trocar
à mão. Reprodução exata do relato: com o script ANTERIOR, uma sessão nessa tela dá só `all 1 Remote Control bridges are still up`
(teste `test_a_session_on_the_limit_screen_fails_the_verify_and_the_push_names_it`, que reprova no HEAD anterior).

**O que o VERIFY faz agora (leitura apenas):** para cada sessão com ponte no ar, lê a tela do pane (`tmux -L gascity display-message` +
`capture-pane`, pelo campo `tmux` do arquivo da sessão) e só confia no pane se o processo da sessão estiver DENTRO dele (id de pane
reaproveitado = tela de outra sessão). Três respostas, nunca duas:
- **limite**: o modal é a ÚLTIMA coisa na tela (pergunta, opção 1, rodapé, nessa ordem). Citação do modal no transcript, diálogo de
  permissão (mesmo rodapé, outra pergunta) e o modal já fechado (saída depois dele) NÃO casam.
- **limpa**: pane lido e sem o modal.
- **não sei**: sem pane do tmux da cidade (ex.: sessão aberta em terminal comum — hoje o "Revit"), tmux/ps mudos, pane que não é mais da
  sessão, ou a mensagem "You've hit your … limit" na tela SEM o modal (pode ser linha velha do scrollback: não prova nada).

Veredito único no log (e em `verify_last` no estado): `VERIFY ok` (todas lidas, nenhuma no limite, nenhuma ponte em dúvida) · `VERIFY FAILED`
(alguma no limite: push `rc-limit-stuck` que NOMEIA a sessão, e ela entra em `limit_watch` por 15 min) · `VERIFY NOT VERIFIED` (qualquer outra
coisa — só log, sem push). "Não sei" nunca vira "ok". Efeito prático: enquanto houver uma sessão RC fora do tmux da cidade, TODA troca fecha
como `NOT VERIFIED`; isso é o estado honesto, não um defeito.

**O Escape (passo 5) — DESLIGADO por padrão.** Armar: `touch /Users/athos/gt/.gascity-gastown-hq/.gc/crew-unstick-on` (ou `GC_CREW_UNSTICK=1`);
`GC_CREW_UNSTICK=0` desarma mesmo com o arquivo. É a mesma exceção do pool (docs/claude-pool-account.md, "The Escape exception") estendida a
Mayor e crews, o que **reverte a linha "Mayor and crew sessions on the modal are never pressed"** daquele doc — por isso nasce desligada:
ligar é decisão de produto do Athos/Mayor, não de quem escreveu o código. Armada, manda UMA tecla (Escape) por sessão, só se TODOS valem:
```
 a sessão estava no ar na troca (nascida depois da troca tem limite PRÓPRIO: nunca é apertada)   · a tela do limite foi vista em duas rodadas,
 com >= 30 s entre elas (achada numa rodada não é apertada na mesma)   · >= 45 s desde a troca (o claude relê o item em ~30 s)
 · a decisão do pool ainda é a conta da troca e ela NÃO está esgotada (Escape numa conta rejeitada só cai no próximo 429)
 · o item default é legível, login completo, e o dono é essa conta   · o arquivo da sessão tem a hora de início (prova que é o mesmo processo)
 · imediatamente antes da tecla: o mesmo processo no pane e o modal ainda a última coisa na tela   · máx. 2 por sessão, >= 60 s entre elas,
 6 por rodada. A tentativa é contada ANTES da tecla. Depois de 2 sem efeito: push `rc-limit-unstick-failed` (apertar à mão / reiniciar).
```
Qualquer leitura que não consegue dizer é "não": não aperta e não esquece. `--dry-run` olha e diz "would send", nunca aperta nem avisa.
Um erro dentro dessa checagem não derruba a troca: é capturado e logado (`the screen check failed` / `the limit-screen watch failed`).

**NÃO medido, e o que isso limita:** a causa de FUNDO de a sessão não reler o login após a troca (bead ga-ci3uao, hipóteses a/b/c). Lendo o
binário 2.1.300 (`strings`, sem rodar nada): o `Keychain` tem cache de 30 s; achei releitura da credencial no tratamento de 401, na renovação
do access token, no "sibling-login watch" (só com aviso de login na tela) e na atualização de políticas; NÃO achei releitura ligada a um 429
de limite semanal. Não rastreei todos os chamadores (`hae`/`lve` limpam o cache e relêem; não vi quem os chama por requisição), então isto é
indício de leitura de código, NÃO medição ao vivo, e não descarta a hipótese (c) (sessão parada no modal, que o pool mediu em 2.1.291).
Consequência: o Escape cura o caso em que a sessão está parada no MODAL; se a sessão estiver com o token antigo em memória e a tela só com a
mensagem, o modal não existe, o VERIFY diz `NOT VERIFIED` e o Escape não ajuda — aí só reiniciar a sessão (fora do escopo: derrubaria o link
de RC que a Fase 2 existe para preservar). O aceite ao vivo (esgotar uma conta de verdade e ver Mayor + crews responderem sozinhos) continua
pendente e precisa do OK do Athos.

## Garantias
- Nunca chama `claude`; custo de crédito zero (só o perfil, grátis). Nunca escreve no item hasheado do pool.
- Token nunca em argv, ambiente, log, estado ou notificação.
- `--dry-run`: só stderr; não escreve, não notifica, não toca o log real; se perder o flock, diz isso.
- Alerta só conta como "avisado" se o `notify` saiu com 0; se falhou, tenta de novo em 5 min (não em 6 h).
- Saída: 0 = rodou (ou outra rodada tinha o lock); **1** = crash (com alerta `crash`, dedup 6 h) ou lock que não abre.
- Linha do `security -i` > 4000 bytes é recusada (medido 07/10: o `security -i` corta a linha em 4096 e executa o resto como 2º comando).
- Estado corrompido/ilegível: log WARN + `state_reset` no estado (arquivo ausente = 1ª rodada, normal).
- Fonte que não pôde ser lida ("não sei") encerra a busca daquela conta: não cai para uma cópia velha da reserva.
- Se a conta que o POOL quer é a que não pôde ser lida, as crews **ficam onde estão** — mesmo com a conta atual esgotada
  (nada de fallback em cima de leitura que falhou) — e sai o alerta `unreadable:<conta>` (re-tentado a cada rodada; o texto
  não manda ninguém "refazer login", porque o login pode existir). Candidato de fallback ilegível é pulado (vale o próximo
  com login completo), mas o alerta `stuck` o nomeia em vez de dizer que ninguém tem login.
- A decisão do pool NÃO tem gate de idade: `updated` só muda quando o pool troca de conta (não é heartbeat).

## Liga/desliga
- Kill switch: `touch /Users/athos/gt/.gascity-gastown-hq/.gc/no-crew-account` (ou `GC_CREW_ACCOUNT=0`).
- Escape nas sessões presas no limite (ga-ci3uao): `touch /Users/athos/gt/.gascity-gastown-hq/.gc/crew-unstick-on` arma; apagar o arquivo (ou `GC_CREW_UNSTICK=0`) desarma. Nasce desarmado.
- Ativação (humana, separada do merge): copiar `packs/town-deltas/assets/claude-crew-account.plist` para
  `~/Library/LaunchAgents` e `launchctl load`. Aceite ao vivo (trocar e voltar) só com OK do Athos.

## Riscos abertos (não medidos)
- Credencial própria de 13 h do bridge: o refresh após a troca pode ser recusado e o RC cair. **A verificação de +60 s NÃO prova
  isso** (só mostra que o bridge sobreviveu ao 1º minuto): só se prova esperando 13 h com uma sessão real, no aceite ao vivo.
- Dono da fonte não é provado antes da troca (ver item 4): uma fonte trocada de dono é detectada ~1–2 min depois, não evitada;
  as crews ficam na conta errada (a do dono real) até alguém refazer o login. Não há restauração automática para a conta
  anterior: seria uma 2ª escrita no default também sem prova.
- Se o blob do default tiver `mcpOAuth` grande (> ~1,9 KB no total), a troca é recusada pelo limite de linha do `security -i`
  (alerta `write-failed`): não há como escrever sem passar o segredo por argv.
- Blobs sem `refreshTokenExpiresAt` em UM lado ou nos DOIS: não dá para dizer qual login é o mais novo (a expiração do access
  token NÃO serve: a cópia guardada sempre parece mais velha que o default vivo), então não se sobrescreve e sai o alerta
  `sync-back:<conta>` — a troca fica recusada até alguém olhar. Se o campo faltar nos dados reais de produção, isto vai
  aparecer como alerta recorrente (fail-closed), não como perda de login. Exceção: a cópia guardada que não é login
  completo (setup-token, sem o escopo de sessões ou sem access token, login a < 1 dia de vencer) não serve às crews de
  qualquer jeito e é substituída pelo login completo do default, sem comparar datas.
- O servidor tolera o refresh token antigo após a rotação?
- `gc` reinicia crew com `--resume`? (não verificado)
- O perfil (`oauthAccount`) pode ficar na conta antiga enquanto o token é da nova.
- A conta terrenos não tem login completo guardado: precisa de re-login humano (ga-xknkke); NÃO logar sozinho.
- 2ª etapa (reinício em momento ocioso se o RC cair) fora de escopo.

Testes: `scripts/test_claude_crew_account.py` (140 testes, shim de `security`, servidor de perfil em loopback, `tmux` falso que registra cada argv e cada tecla). O harness é
selado: todo teste roda com `CLAUDE_CREW_NOTIFY`, `CLAUDE_CREW_SECURITY` e `GC_CITY_PATH` fixados em stubs/tmp e `PATH`
sem o `notify` real; no fim da sessão afirma que o log/estado/lock reais não mudaram e que nenhum sentinela foi executado;
e o script roda de verdade sob `env -i`, com `python3` do pytest e com `/usr/bin/python3` (3.9, o do plist).
