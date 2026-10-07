# claude-crew-account — conta Claude do Mayor e das crews, ao vivo (ga-qdtmq2)

Fase 2 da ga-xoe5ao. O pool headless (ga-8hcnvb.1, `claude-pool-account.py`) decide a conta; este script **segue** a decisão
para quem usa Remote Control (Mayor + crews), reescrevendo o item DEFAULT do Keychain `Claude Code-credentials`.
Decisão do Athos (06/10): ao vivo, sem reiniciar — mesmo link de RC, conversa intacta.

## O que faz (a cada 60 s, sob flock)
1. Pergunta ao endpoint de perfil quem segura o item default (não confia em memória nem em `~/.claude.json`).
2. **Sync-back:** copia o blob do default de volta ao item próprio da conta que o segura (nunca por cima de login mais novo).
3. **Follow:** se a decisão aponta outra conta, grava o login COMPLETO dela no default (via `security -i`, hex no stdin).
   Sem login completo (escopo `user:sessions:claude_code` + refresh token): não escreve, alerta nomeando o login que falta.
4. **Verify:** toda sessão que tinha bridge de Remote Control ainda a tem 60 s depois.

## Garantias
- Nunca chama `claude`; custo de crédito zero (só o perfil, grátis). Nunca escreve no item hasheado do pool.
- Token nunca em argv, ambiente, log, estado ou notificação.
- `--dry-run`: só stderr; não escreve, não notifica, não toca o log real.
- A decisão do pool NÃO tem gate de idade: `updated` só muda quando o pool troca de conta (não é heartbeat).

## Liga/desliga
- Kill switch: `touch /Users/athos/gt/.gascity-gastown-hq/.gc/no-crew-account` (ou `GC_CREW_ACCOUNT=0`).
- Ativação (humana, separada do merge): copiar `packs/town-deltas/assets/claude-crew-account.plist` para
  `~/Library/LaunchAgents` e `launchctl load`. Aceite ao vivo (trocar e voltar) só com OK do Athos.

## Riscos abertos (não medidos)
- Credencial própria de 13 h do bridge: o refresh após a troca pode ser recusado e o RC cair (só se prova esperando 13 h).
- O servidor tolera o refresh token antigo após a rotação?
- `gc` reinicia crew com `--resume`? (não verificado)
- O perfil (`oauthAccount`) pode ficar na conta antiga enquanto o token é da nova.
- A conta terrenos não tem login completo guardado: precisa de re-login humano (ga-xknkke); NÃO logar sozinho.
- 2ª etapa (reinício em momento ocioso se o RC cair) fora de escopo.

Testes: `scripts/test_claude_crew_account.py` (25 testes, shim de `security`, servidor de perfil em loopback).
