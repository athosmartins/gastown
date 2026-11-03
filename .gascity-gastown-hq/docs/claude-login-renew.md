# claude-login-renew — relogin automático das contas Claude no mini (ga-xoe5ao.5)

## Contents

• Quando age (a cada 15 min, sob flock, UMA conta por rodada) · O que é uma tentativa
• O que NUNCA faz · Quem julga · Estado, logs · Liga/desliga e ativação
• Prova ao vivo e o que não foi medido

## Quando age (a cada 15 min, sob flock, UMA conta por rodada)
- **Previsão:** o melhor login guardado de uma conta que tem config dir (`~/.gastown/claude-accounts/<dir>`) termina em ≤ 7 dias (ou já terminou).
  A conta que **segura o default** fica de fora enquanto o default for login completo: o CLI rotaciona esse login e um login novo da mesma conta
  poderia custar ao default o refresh token (não medido) — a cópia guardada dela pode envelhecer.
- **Outage:** a crew job tem um episódio `no_login` aberto há ≥ 10 min **e** nenhuma conta com config dir tem login guardado usável (login que a
  crew job chamou de `burned` não conta). O pick do pool primeiro. Se alguma conta tem login que a crew job cura sozinha, este job não entra.
- Ordem: previsão (fim mais próximo primeiro), depois outage. Conta sem config dir (ex.: só o item `athosmartins`) nunca é tentada — não há onde logar.

## O que é uma tentativa
1. Foto do item da conta (se não der para ler, **não tenta**: o que não se fotografa não se devolve).
2. `claude auth login --email <e>` com `CLAUDE_CONFIG_DIR` = o dir da conta, sob um **shim** de `open`/`xdg-open` que só grava a URL OAuth num arquivo
   privado — o navegador do Athos não abre.
3. A URL vai ao **driver** pelo **stdin** (nunca argv, log, estado ou push): o mesmo arquivo, subcomando `drive`, num python com Playwright
   (`/opt/homebrew/bin/python3`), ligado ao Chrome CDP da `federated-site-login` (perfil `~/.chrome-cdp`, `127.0.0.1:9222`).
   Ele passa o Google com a **sessão que o perfil já tem** (seletor de conta; o TOTP de `gmail-totp <email>` quando o Google pede código) e clica **Authorize**.
4. O CLI grava o item novo; a crew job o acha no minuto seguinte e confere com o VERIFY na próxima troca.

## O que NUNCA faz
Contornar o anti-bot da Anthropic não é nosso (ga-yyltfk, 04/10: o "Authorize" parou num quebra-cabeça de arrastar a silhueta). O driver **para** e devolve:

| veredito | quando | passo humano |
|---|---|---|
| `puzzle` | verificação humana no Authorize | `claude auth login --email <e>` no mini, à mão |
| `no_google_session` | o perfil do CDP não tem sessão dessa conta Google | entrar uma vez nessa conta no Chrome do CDP |
| `needs_password` | o Google pediu senha | o job **nunca** digita senha |
| `needs_device` | o Google pediu toque no celular / chave | aprovar no aparelho |
| `wrong_account` | o navegador está logado em outra conta | trocar a sessão |

Qualquer um deles é **final** (sem retry: cada tentativa pode tocar o celular do Athos): a conta ganha a marca "inviável por automação" no estado e o
Athos recebe **UM** push com a conta e o passo exato (reenviado a cada 5 min até ser entregue, nunca repetido depois). Um login feito à mão depois
(+1 dia de vida) tira a marca. Falhas transitórias (CLI/driver estourou o tempo, sem veredito, login não completo) repetem a cada 6 h, 3 vezes; a 3ª
vira a mesma marca (`failed_3_times`) e o mesmo push único. Nenhuma linha de terminal com senha.

## Quem julga
O **Keychain**, não o driver: o item precisa ter um login **novo e completo** (escopo `user:sessions:claude_code` + refresh token) cujo perfil diga que é
da conta `<e>`. Login não completo ou de outra conta é **devolvido como estava** (ou apagado, se não havia); se foi de outra conta, a marca `wrong_account`
e um push. Sucesso grava no estado `renewed{svc,at,reason,before{afp,rfp,rexp},after{…}}` — só impressões sha256[:8] e datas, nunca o token.

## Estado, logs
`/Users/athos/shared/data/claude_login_renew.json` (`CLAUDE_RENEW_STATE`): `accounts[email]` com `renewed`, `tries`, `next_at`, `last{verdict,step,at}`,
`infeasible{verdict,step,at,left,pushed,next_push}`. Log: `.gc/logs/claude-login-renew.log`. Lock: `.gc/claude-login-renew.lock`.
Arquivo ausente = primeira rodada, sem aviso. Arquivo **ilegível ou de forma errada** (JSON quebrado, sem permissão, `accounts` que não é um mapa de
registros — por exemplo depois de uma edição à mão) vira estado vazio **com uma linha `WARN ... unreadable` no log**: as marcas e as tentativas se perdem
(um quebra-cabeça pode ser encontrado mais uma vez, com mais um push), mas o job não trava a cada rodada.

## Liga/desliga e ativação
- Kill switch sem recarregar: `touch /Users/athos/gt/.gascity-gastown-hq/.gc/no-login-renew` (ou `GC_LOGIN_RENEW=0`).
- `python3 claude-login-renew.py --dry-run` diz o que FARIA (stderr; sem Keychain, sem navegador, sem push).
- `--account <email> --force` renova aquela conta agora, qualquer que seja a previsão e a marca (é a prova ao vivo).
- **Ativação é passo humano (merged ≠ live):** copiar o plist para `~/Library/LaunchAgents` e `launchctl load`, depois de o script estar na `main`.
- Sementes de teste: `CLAUDE_RENEW_STATE`, `CLAUDE_RENEW_CLAUDE`, `CLAUDE_RENEW_DRIVER` (json), `CLAUDE_RENEW_DRIVER_PY`, `CLAUDE_RENEW_CDP`, e todas as `CLAUDE_CREW_*`.

## Prova ao vivo e o que não foi medido
Medido em 02/11 no mini (só impressões sha256[:8] e datas; nunca o token):
- Nenhuma conta com dir vence em ~04/11 (a premissa da bead estava velha): a mais próxima é athosb85, fim do refresh em 15/11 (entra na previsão em 08/11); athoscrypto, terrenos e throw.away.amb têm 25–29 dias.
- `--dry-run` no Keychain real, sob `/usr/bin/python3` 3.9: a conta que segura o default fica de fora; nada devido; nada gravado.
- `--account athosb85@gmail.com --force`, tudo real (CLI, Chrome CDP, estado, `notify`): em 27 s o driver chegou ao seletor de contas do Google, a conta não está entre as sessões
  do perfil → `no_google_session`; o item do athosb85 ficou intacto (mesmas impressões e mesma data), nenhuma aba nem processo restou, UM push.
- O Chrome de automação (`~/.chrome-cdp`) só tem sessão Google de `athoscrypto@` e `athosmartins@`. **Para athosb85, throw.away.amb e terrenos o relogin só é automático depois de o
  Athos entrar nelas UMA vez nesse Chrome** (senha e 2 fatores dele); o job confere de novo em até 24 h (`recheck_at`) e então renova sozinho, sem novo push.

**NÃO medido:** o caminho de sucesso ao vivo (tela Authorize, se o quebra-cabeça da ga-yyltfk aparece no perfil confiável, se o Google pede TOTP ou toque num re-login); as únicas contas com
sessão Google no CDP são a que segura o default e o backup sem dir, e um login novo delas pode custar o refresh token ao default (não medido), então não foi forçado. Está coberto no selftest
(navegador e TOTP simulados), não ao vivo. Também não medido: se um login novo revoga os refresh tokens antigos da mesma conta; quanto tempo dura a sessão Google do perfil CDP.
