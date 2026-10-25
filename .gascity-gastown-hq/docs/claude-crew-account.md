# claude-crew-account — conta Claude do Mayor e das crews, ao vivo (ga-qdtmq2)

## Contents

• O que faz (a cada 60 s, sob flock) · A tela do limite e o Escape (ga-ci3uao) · A mensagem de limite sem o modal e o último degrau (ga-yqzedv) · Garantias · Liga/desliga · Riscos abertos (não medidos)

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
mensagem, o modal não existe e o Escape não ajuda — esse caso é o da seção seguinte (ga-yqzedv). O aceite ao vivo (esgotar uma conta de verdade e ver Mayor + crews responderem sozinhos) continua
pendente e precisa do OK do Athos.

## A mensagem de limite sem o modal e o último degrau (ga-yqzedv)
**O que aconteceu:** de 07/10 a 25/10 o Escape automático NUNCA disparou (0 linhas de `limit_watch` / `no Escape sent` em 19 mil linhas de log,
com `crew-unstick-on` armado desde 14/10). A vigia só entrava com o MODAL, mas nos 3 casos reais de crew a tela era outra: o 429 **encerra o
turno** e deixa "You've hit your weekly limit · resets ..." como a ÚLTIMA saída, acima da caixa do prompt, sessão ociosa, sem modal — nada a
apertar. Essa tela era "não sei" para sempre (podia ser linha velha do scrollback): sem push, sem vigia, sem tecla. Caso de 25/10: oracle-wa
ficou 10 min assim (troca 15:40Z → saiu só quando a varredura fechou a sessão às 15:49Z).

**Atual × velha, sem chute.** A pergunta "a mensagem é de agora ou é velha?" se responde pela tela, não por palpite. Na tela de layout medido
(claude 2.1.310: transcript, régua `────`, caixa `❯ ...`, régua, statusline) a sessão entra em `banner_watch` (no estado) se a mensagem é uma das
3 últimas linhas do transcript, **começando** a linha (frase do agente que cita a mensagem não conta) — ou seja, ela é a última saída. A
**impressão** da tela (transcript + caixa do prompt, SEM a statusline, que muda sozinha: contexto %, workers, relógio) é guardada:
- mudou entre duas leituras → a sessão está **andando** (ou alguém digitando): o relógio recomeça, nunca é "parada";
- igual por `STALL_S` = 10 min → **parada**: UM push nomeado `rc-limit-stalled` (nomes das sessões, "10 min", e se o reset automático está
  ligado ou desligado e como armar). O push NÃO afirma que a sessão "não pegou o login novo": a tela sozinha não separa "ficou presa no 429 depois
  da troca" de "está ociosa nessa mensagem desde antes" — só diz o que se viu (ociosa no 429, ninguém vai dar um turno a ela). A distinção
  que importa para o degrau destrutivo é feita pelo transcript, abaixo;
- a mensagem some / vem trabalho depois dela → sai da vigia, sem push; o modal abre → vai para a `limit_watch` (Escape);
- sessão que terminou, pane que não é mais dela, tmux mudo → "não sei", mantida, nada afirmado; a vigia cai em 1 h (`BANNER_WATCH_S`), o push fica.
O veredito do VERIFY continua `NOT VERIFIED` (uma leitura só não separa atual de velha); o que muda é que agora há vigia que separa.
**Nenhuma tecla vai para essa tela** (não há modal para responder). Layout que este script não mediu (a caixa `╭─╮ │ > │` antiga, por exemplo)
continua "não sei" e sem vigia.

**O último degrau: `gc session reset` — DESLIGADO por padrão, a conversa NÃO é preservada.** Medição pedida pelo bead (a conversa sobrevive ao reset?):
**não sobrevive.** Evidência: o `--help` do gc ("restart ... with fresh provider conversation state") e o caso oracle-wa de 25/10 — sessão
recriada pelo gc voltou com `session_key` novo e transcript novo, começando do zero (c7df7649 às 15:52Z; o anterior, 75201ece, terminou 15:40Z).
O primeiro registro de conversa do c7df7649 é o prompt de partida (15:52:53Z), sem nenhum trecho da conversa antiga; o "continuou o trabalho com ctx 20%"
veio da bead e do prime, não da conversa. `generation=2` / `continuation_epoch=1` em ga-mbl3wp são os contadores da bead NOVA (criada 15:49:37Z) e
não provam preservação (e não medi se o reset mexe neles: nenhum `gc session reset` rodou nela). Do reset, o `--help` diz que ficam a identidade,
o alias, o mail e o trabalho na fila; o que se perde é a conversa com o provider.
**O que NÃO foi medido:** rodei o `gc session reset` ao vivo? Não — derrubaria uma conversa de verdade; a evidência é o texto do gc e a
recriação do oracle (que não foi por `reset`). Por isso o degrau nasce desarmado e com chave PRÓPRIA (autorização não é herdada: armar o Escape
não arma o reset): `touch /Users/athos/gt/.gascity-gastown-hq/.gc/crew-reset-on` (ou `GC_CREW_RESET=1`; `GC_CREW_RESET=0` desarma mesmo com o arquivo).
Armado, roda `gc --city <cidade> session reset <id>` em UMA sessão por rodada, uma vez por sessão na vida, quando ela está parada há 10 min
(banner: impressão da tela igual; modal: Escapes esgotados e 10 min desde que foi achada) e TODOS valem:
```
 a mesma lista de contas do Escape (decisão do pool ainda é a conta da troca, não esgotada, default legível e do dono certo, >= 45 s da troca)
 · o arquivo da sessão tem hora de início e AGORA relata o mesmo pane de antes (senão "another pane")
 · [mensagem] o arquivo da sessão diz `status: idle` e o PRÓPRIO transcript da sessão (~/.claude/projects/<cwd>/<sessionId>.jsonl, últimos 256 KB) termina no
   erro `rate_limit` (assistant, isApiErrorMessage) — qualquer registro de conversa depois dele, arquivo ausente ou linha ilegível = "não confirma" —
   E o erro tem data IGUAL OU POSTERIOR à da troca (sem data = não). Sessão parada numa mensagem de ANTES da troca não está errada: o próximo turno
   dela lê o login novo, e o reset só perderia a conversa. (No caso real de 25/10 o erro veio 32 s DEPOIS da troca: 15:40:18Z troca, 15:40:50Z erro.)
 · uma leitura nova da tela, imediatamente antes: ainda a mesma impressão (banner) / ainda o modal (modal)
 · `gc session list --json` tem EXATAMENTE uma sessão com `session_name` igual ao tmux da sessão (zero ou duas = não reseta)
```
Contado ANTES de rodar. Se o gc recusa: push `rc-limit-reset-failed`, sem repetir. Se roda: push `rc-limit-reset` dizendo que a conversa NÃO foi preservada.
`--dry-run` diz "would run gc session reset for <nome> (<pid>)" e não chama o gc. **Cuidado:** o Mayor também é uma sessão RC — com o reset armado, um
Mayor parado 10 min nessa tela é resetado como qualquer crew. Alternativa não destrutiva (um nudge para a sessão ociosa, que poderia disparar um turno
novo) existe mas **não foi medida**, por isso não foi implementada.

**Fixture e o que falta provar:** o teste usa o chrome REAL do claude 2.1.310 (medido em panes vivos) e o TEXTO real da mensagem (do registro
`rate_limit` do transcript), mas não havia nenhum pane nesse estado para capturar: o glifo na frente da mensagem não é medido (o casamento aceita
qualquer prefixo não-alfanumérico). Se o claude real desenhar outra coisa, a consequência é "não sei" (sem vigia), nunca "parada" por engano.
Rodando o arquivo de testes novo contra o script do HEAD anterior (`cb6afb9d9`): 45 reprovam e 145 passam (os antigos, mais os novos que só afirmam que nada acontece: layout não medido, mensagem velha com trabalho depois, só o Escape armado).

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
- `gc session reset` na sessão parada (ga-yqzedv): `touch /Users/athos/gt/.gascity-gastown-hq/.gc/crew-reset-on` arma; apagar o arquivo (ou `GC_CREW_RESET=0`) desarma. Nasce desarmado e **perde a conversa**. Chave própria: armar o Escape não arma o reset.
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
- (ga-yqzedv) O glifo que o claude real põe na frente da mensagem de limite não foi medido (nenhum pane nesse estado existia); o caminho do
  `gc session reset` só rodou contra um `gc` falso nos testes, nunca ao vivo; se o layout do claude mudar, as telas viram "não sei" (sem vigia).

Testes: `scripts/test_claude_crew_account.py` (190 testes, shim de `security`, servidor de perfil em loopback, `tmux` falso que registra cada argv e cada tecla, `gc` falso que registra cada chamada). O harness é
selado: todo teste roda com `CLAUDE_CREW_NOTIFY`, `CLAUDE_CREW_SECURITY` e `GC_CITY_PATH` fixados em stubs/tmp e `PATH`
sem o `notify` real; no fim da sessão afirma que o log/estado/lock reais não mudaram e que nenhum sentinela foi executado;
e o script roda de verdade sob `env -i`, com `python3` do pytest e com `/usr/bin/python3` (3.9, o do plist).
