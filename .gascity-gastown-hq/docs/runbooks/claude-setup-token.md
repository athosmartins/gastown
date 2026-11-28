# Contas Claude — token de 1 ano no pool, login completo só onde precisa (ga-xy0916u)

## Contents

• A regra · Quem roda em qual credencial · O que o Athos faz (e quando) · Gerar o token de uma conta
• Guardar o token (Mayor ou o próprio Athos) · Como saber a validade · Os avisos
• Renovar um login completo · Reverter

## A regra

Decisão do Athos em 28/11 (ga-xoe5ao.6): **token de 1 ano + login completo só onde precisa.**

| Credencial | Escopo | Vida | Quem usa |
|---|---|---|---|
| **Login completo** (`claude auth login`) | `user:sessions:claude_code` + refresh token | ~30 dias; **renovação à mão** | Mayor e as crews com Remote Control (`claude-rc*`) |
| **Token de 1 ano** (`claude setup-token`) | `user:inference` | ~1 ano; sem refresh | todo o pool: cães, `wa-worker`, `ps-worker`, revisores, refino, boot, deacon (`claude-headless`) |

Remote Control **só** funciona com login completo. O pool só faz inferência, então o token basta. Um token no item padrão do Keychain
("Claude Code-credentials") **derruba o Remote Control** — por isso o pool usa o item dele (`Claude Code-credentials-50adeaf1`) e o Mayor/crews seguem o item padrão com login completo.

Ninguém contorna a verificação do claude.ai no navegador: o relogin automático por navegador **foi desligado** (a rodada agendada só avisa). Quem renova um login completo é o Athos, à mão.

## Quem roda em qual credencial

`python3 packs/town-deltas/assets/scripts/claude-credential-map.py roles` lista cada agente da config resolvida (`gc config show`) agrupado pela credencial; `check` sai 3 e nomeia os papéis vivos sem provider.
`roles` e `check` pedem **Python 3.11+** (tomllib). Se o `python3` do terminal for mais antigo (o do sistema no macOS é o 3.9), o script sai 1 e diz isso: use o do Homebrew (`/opt/homebrew/bin/python3`, o mesmo do driver do relogin). `tokens` e `--status` rodam no 3.9.

- **Login completo:** o Mayor e as crews nomeadas (provider `claude-rc` / `claude-rc-*`).
- **Token de 1 ano:** provider `claude-headless` (cães, `wa-worker`, `ps-worker`, revisores, refino…). O daemon do pool (`claude-pool-account.py`) escolhe a conta e grava o token dela no item do pool; `claude-lowprio.sh` aponta essas sessões para ele.
- **Login padrão (sem provider):** `polecat`/`refinery`/`witness` dos rigs. Rodam com o mesmo login do Mayor e **ninguém decidiu** movê-los para o token: `claude-credential-map.py check` os lista (pendência aberta na bead ga-xy0916u).
- **Sem Claude:** agentes com `command`/`start_command` e outros fornecedores.

## O que o Athos faz (e quando)

1. **Hoje:** nada, se `claude-login-renew.py --status` mostra o `setup-token` de cada conta com mais de 21 dias. Os tokens das 4 contas do job foram guardados em 30/09 (`--status` de 28/11: terminam em 30/09/2027, ≈306 dias; a vida de 365 dias **não foi medida**). O cofre pode ter mais tokens que as 4 contas do job (o doc do pool fala em 5): só `claude-credential-map.py tokens` os lista todos.
2. **Quando o aviso «Login Claude vence em ate N dia(s)» chegar:** renovar o login completo dessa conta à mão — seção "Renovar um login completo" (~2 min).
3. **Só se um token morrer** (aviso «Token Claude vence…/ja venceu», ou o pool marcar a conta inválida): gerar outro — seção seguinte.

## Gerar o token de uma conta

Uma vez por conta (4 contas do job: athosmartins, athoscrypto, terrenos, throw.away.amb). No terminal do Mac mini, **logado na conta certa**:

```
claude setup-token
```

Ele abre o navegador (o claude.ai pede a verificação — **é você quem faz**, ninguém automatiza), depois imprime um token `sk-ant-oat01-…`. **Copie e não cole em chat, bead, e-mail ou arquivo.** O token só vai para o cofre (próxima seção).

## Guardar o token (Mayor ou o próprio Athos)

Logo depois de gerar, no mesmo terminal, com o script que já existe no rig whatsapp_automation:

```
python3 /Users/athos/gt/whatsapp_automation/scripts/claude_conta_cadastrar_chave.py <email-da-conta>
```

Ele pede a chave num prompt **sem eco** (nunca por argumento nem arquivo), testa com uma chamada mínima e só então grava no Bitwarden como `claude-oauth-token-<email>` (nota segura). Ele **não confere de qual conta a chave é**: gere-a logado na conta certa.
Depois do cadastro o daemon do pool a usa no próximo ciclo (60 s), sem reinício. O token nunca vai para arquivo, log ou argv.

Opcional: um campo `gerado_em` (data ISO) no item melhora o aviso; sem ele a validade conta da `revisionDate` (o dia em que o token foi guardado). O script de cadastro (outro repositório) ainda não o escreve.

## Como saber a validade

```
python3 packs/town-deltas/assets/scripts/claude-login-renew.py --status
python3 packs/town-deltas/assets/scripts/claude-credential-map.py tokens
```

`--status` imprime, por conta, o fim do login completo e o fim do token, com `- WARN` quando já entrou na faixa de aviso. Só datas e dias: **nunca o token**. Sai 1 se o estado da crew job, o cofre ou um item de login de alguma conta não puderam ser lidos (e diz qual); um item ilegível dá «full login unknown», nunca o número da metade legível.
A linha `scheduled run:` do log (`.gc/logs/claude-login-renew.log`) repete a validade a cada 15 min.
O aviso e o `--status` cobrem as contas **do job** (as 4 acima). `claude-credential-map.py tokens` lista todo item `claude-oauth-token-*` do cofre: o de uma conta fora do job aparece só ali e **não tem aviso**.

## Os avisos

A rodada agendada (`com.gascity.claude-login-renew`, a cada 15 min) manda **um** push por conta, tipo e faixa; faixa mais apertada é um push novo; a mesma faixa nunca repete depois de entregue (um push não entregue é reenviado a cada 5 min).

| Tipo | Faixas | Título |
|---|---|---|
| Login completo | 7 / 3 / 1 dia(s) e já vencido | «Login Claude vence em ate N dia(s): <email>» |
| Token de 1 ano | 21 / 7 / 1 dia(s) e já vencido | «Token Claude vence em ate N dia(s): <email>» |

O primeiro aviso de um login vem com **7 dias** de antecedência (a regra é ≥ 3). Um vencimento desconhecido (token sem data, cofre fora do ar) **não avisa e não é dado como "ok"**: a linha do log diz `token vault unreachable/unreadable`, `token empty`, `token undated` ou `token none`.

## Renovar um login completo

No terminal do Mac mini (o aviso traz o comando exato):

```
CLAUDE_CONFIG_DIR=~/.gastown/claude-accounts/<dir-da-conta> claude auth login --email <email>
```

Faça a verificação no navegador. A `claude-crew-account` acha o login novo no minuto seguinte; ao renovar, o aviso daquela conta é esquecido (o próximo vencimento avisa de novo).

## Reverter

- **Voltar o relogin por navegador** (não recomendado; o claude.ai responde ao automático com verificação humana): `GC_LOGIN_RENEW_BROWSER=1` no ambiente do job.
- **Desligar o job inteiro:** `touch <city>/.gc/no-login-renew` (ou `GC_LOGIN_RENEW=0`).
