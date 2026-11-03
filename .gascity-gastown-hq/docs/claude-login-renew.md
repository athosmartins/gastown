# claude-login-renew — relogin das contas Claude no mini (ga-xoe5ao.5, fatias 1 e 2 de 3)

## Contents

• O que a fatia 1 faz · O que NUNCA faz · Inviável por automação (fatia 2) · Quem julga
• Prova ao vivo e o que não foi medido · A outra fatia

## O que a fatia 1 faz
`python3 packs/town-deltas/assets/scripts/claude-login-renew.py --account <email> --force` renova **agora** o login Claude de UMA conta que tem config dir
(`~/.gastown/claude-accounts/<dir>`). Sai 0 se renovou, 2 se não (a linha impressa e o log `.gc/logs/claude-login-renew.log` dizem por quê, inclusive se outra rodada segura o lock), 64 se faltar `--account` ou `--force`.
1. Foto do item da conta (se não der para ler, **não tenta**: o que não se fotografa não se devolve).
2. `claude auth login --email <e>` com `CLAUDE_CONFIG_DIR` = o dir da conta, sob um **shim** de `open`/`xdg-open` que só grava a URL OAuth num arquivo privado — o navegador do Athos não abre.
3. A URL vai ao **driver** pelo **stdin** (nunca argv, log ou stdout): o mesmo arquivo, subcomando `drive`, num python com Playwright (`/opt/homebrew/bin/python3`), ligado ao Chrome CDP da
   `federated-site-login` (perfil `~/.chrome-cdp`, `127.0.0.1:9222`). Ele passa o Google com a **sessão que o perfil já tem** (seletor de conta; o TOTP de `gmail-totp <email>` quando o Google pede código) e clica **Authorize**.
4. O CLI grava o item novo; a crew job (`claude-crew-account`) o acha no minuto seguinte e confere com o VERIFY na próxima troca.

## O que NUNCA faz
Contornar o anti-bot da Anthropic não é nosso (ga-yyltfk, 04/10: o "Authorize" parou num quebra-cabeça de arrastar a silhueta). O driver **para** e devolve o veredito; nada é repetido:
`puzzle` (verificação humana) · `no_google_session` (o perfil do CDP não tem sessão dessa conta Google) · `needs_password` (o job **nunca** digita senha) · `needs_device` (toque no celular / chave) ·
`wrong_account` (o navegador está logado em outra conta). A linha impressa traz o comando à mão (`claude auth login --email <e>`); o que acontece com a conta é a próxima seção.

## Inviável por automação (fatia 2)
O estado fica em `/Users/athos/shared/data/claude_login_renew.json` (`CLAUDE_RENEW_STATE` muda o caminho; escrita atômica; arquivo ilegível ou de forma errada vira estado vazio **dito no log**: marcas e tentativas se perdem).
- **Parede** (`puzzle`, `no_google_session`, `needs_password`, `needs_device`, `wrong_account`): a conta ganha `infeasible` (veredito, passo, `left` = segundos até o fim do melhor refresh token). O Athos recebe **UM** push
  (`notify -p 4`, contrato estrito do `claude-crew-account`: entregue = saída 0, 10 ou 11) com o passo exato e sem senha. Se o notify não entrega, a rodada **sem argumentos** reenvia a cada 5 min; entregue, nunca mais.
  A mesma parede de novo não repete o push; uma parede **diferente** é um passo novo e manda outro.
- `no_google_session` e `needs_password` se consertam **no navegador**: a marca ganha `recheck_at` (+24 h, sem novo push). Quem lê `recheck_at` e `next_at` é o gatilho da fatia 3; aqui eles só são gravados.
- **Falha transitória** (CLI sem URL, sem login novo, driver sem veredito, `claude` que não roda…): `tries` +1 e `next_at` = +6 h; a 3ª seguida vira a marca `failed_3_times`, com o mesmo push. Tentativa que **não lançou nada** (`skipped`: item ilegível) não conta.
- **Login à mão solta a marca**: o melhor login da conta com +1 dia de vida do que na marca (ou, se a marca não achou login nenhum, qualquer login com fim registrado) tira `infeasible` e `tries`. Item que não dá para ler **não** solta.
- `claude-login-renew.py` **sem argumentos** não lança nada: solta marcas e reenvia pushes pendentes (é o que a fatia 3 põe no launchd). Um `flock` (`.gc/claude-login-renew.lock`) impede duas rodadas juntas.

## Quem julga
O **Keychain**, não o driver: o item precisa ter um login **novo e completo** (escopo `user:sessions:claude_code` + refresh token) cujo perfil diga que é da conta `<e>`. Login não completo ou de outra
conta é **devolvido como estava** (ou apagado, se não havia). Um login completo da conta certa feito à mão enquanto o job parava numa parede é mantido, não revertido. A prova impressa e logada são só
impressões sha256[:8] e datas (`refresh <antes> -> <depois>, ends <data>`), nunca o token.

## Prova ao vivo e o que não foi medido
Medido em 02/11 no mini (só impressões e datas): nenhuma conta com dir vence em ~04/11 (a premissa da bead estava velha): a mais próxima é athosb85, fim do refresh em 15/11; athoscrypto, terrenos e
throw.away.amb têm 25–29 dias. O Chrome de automação só tem sessão Google de `athoscrypto@` e `athosmartins@`: para athosb85, throw.away.amb e terrenos o relogin só passa depois de o Athos entrar nelas
**uma vez** nesse Chrome. A conta que segura o default (athoscrypto) não foi forçada: um login novo dela poderia custar ao default o refresh token (não medido).
**NÃO medido:** o caminho de sucesso ao vivo (tela Authorize; se o quebra-cabeça aparece no perfil confiável; se o Google pede TOTP ou toque num re-login) — está no selftest (navegador e TOTP simulados),
não ao vivo; se um login novo revoga os refresh tokens antigos da mesma conta; quanto dura a sessão Google do perfil CDP.

## A outra fatia
Fatia 3 (`ga-xoe5ao.5.3`): previsão T-7 dias e outage como gatilhos (lendo `next_at`/`recheck_at`), uma conta por rodada, `flock` contra a crew job, plist launchd, chave de desligar. Estado ilegível **não** pode liberar
tentativa automática lá. Até a 3 o job **não roda sozinho** e não há plist: só a linha de comando acima e a rodada sem argumentos.
