# claude-crew-account — conta Claude do Mayor e das crews, ao vivo (ga-qdtmq2)

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
5. **Verify — fatia 2 (ga-llvuo4), AINDA NÃO está neste código.** A conferência de que toda sessão com bridge de Remote
   Control continua com ela 60 s depois da troca vem na fatia seguinte (o gate recusou a ga-qdtmq2 inteira por tamanho, E11:
   896 > 800 linhas de produção; esta fatia tem 772). Enquanto ela não entrar, este script **não percebe** se uma troca derrubou
   o Remote Control de alguma sessão — e o aceite ao vivo (trocar e voltar com uma crew real) depende dela.

## Garantias
- Nunca chama `claude`; custo de crédito zero (só o perfil, grátis). Nunca escreve no item hasheado do pool.
- Token nunca em argv, ambiente, log, estado ou notificação.
- `--dry-run`: só stderr; não escreve, não notifica, não toca o log real; se perder o flock, diz isso.
- Alerta só conta como "avisado" se o `notify` saiu com 0; se falhou, tenta de novo em 5 min (não em 6 h).
- Saída: 0 = rodou (ou outra rodada tinha o lock); **1** = crash (com alerta `crash`, dedup 6 h) ou lock que não abre.
- Linha do `security -i` > 4000 bytes é recusada (medido 07/10: o `security -i` corta a linha em 4096 e executa o resto como 2º comando).
- Estado corrompido/ilegível: log WARN + `state_reset` no estado (arquivo ausente = 1ª rodada, normal).
- Fonte que não pôde ser lida ("não sei") encerra a busca daquela conta: não cai para uma cópia velha da reserva.
- A decisão do pool NÃO tem gate de idade: `updated` só muda quando o pool troca de conta (não é heartbeat).

## Liga/desliga
- Kill switch: `touch /Users/athos/gt/.gascity-gastown-hq/.gc/no-crew-account` (ou `GC_CREW_ACCOUNT=0`).
- Ativação (humana, separada do merge): copiar `packs/town-deltas/assets/claude-crew-account.plist` para
  `~/Library/LaunchAgents` e `launchctl load`. Aceite ao vivo (trocar e voltar) só com OK do Athos.

## Riscos abertos (não medidos)
- Credencial própria de 13 h do bridge: o refresh após a troca pode ser recusado e o RC cair. Esta fatia não verifica bridge
  nenhum; e a verificação de +60 s da fatia 2 **NÃO prova isso** (só mostra que o bridge sobreviveu ao 1º minuto): só se
  prova esperando 13 h com uma sessão real, no aceite ao vivo.
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

Testes: `scripts/test_claude_crew_account.py` (56 testes, shim de `security`, servidor de perfil em loopback). O harness é
selado: todo teste roda com `CLAUDE_CREW_NOTIFY`, `CLAUDE_CREW_SECURITY` e `GC_CITY_PATH` fixados em stubs/tmp e `PATH`
sem o `notify` real; no fim da sessão afirma que o log/estado/lock reais não mudaram e que nenhum sentinela foi executado;
e o script roda de verdade sob `env -i`, com `python3` do pytest e com `/usr/bin/python3` (3.9, o do plist).
