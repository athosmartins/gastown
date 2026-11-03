# claude-login-renew — relogin das contas Claude no mini (ga-xoe5ao.5, fatia 1 de 3)

## Contents

• O que esta fatia faz · O que NUNCA faz · Quem julga
• Prova ao vivo e o que não foi medido · As outras fatias

## O que esta fatia faz
`python3 packs/town-deltas/assets/scripts/claude-login-renew.py --account <email> --force` renova **agora** o login Claude de UMA conta que tem config dir
(`~/.gastown/claude-accounts/<dir>`). Sai 0 se renovou, 2 se não (a linha impressa e o log `.gc/logs/claude-login-renew.log` dizem por quê), 64 se faltar `--account` ou `--force`.
1. Foto do item da conta (se não der para ler, **não tenta**: o que não se fotografa não se devolve).
2. `claude auth login --email <e>` com `CLAUDE_CONFIG_DIR` = o dir da conta, sob um **shim** de `open`/`xdg-open` que só grava a URL OAuth num arquivo privado — o navegador do Athos não abre.
3. A URL vai ao **driver** pelo **stdin** (nunca argv, log ou stdout): o mesmo arquivo, subcomando `drive`, num python com Playwright (`/opt/homebrew/bin/python3`), ligado ao Chrome CDP da
   `federated-site-login` (perfil `~/.chrome-cdp`, `127.0.0.1:9222`). Ele passa o Google com a **sessão que o perfil já tem** (seletor de conta; o TOTP de `gmail-totp <email>` quando o Google pede código) e clica **Authorize**.
4. O CLI grava o item novo; a crew job (`claude-crew-account`) o acha no minuto seguinte e confere com o VERIFY na próxima troca.

## O que NUNCA faz
Contornar o anti-bot da Anthropic não é nosso (ga-yyltfk, 04/10: o "Authorize" parou num quebra-cabeça de arrastar a silhueta). O driver **para** e devolve o veredito; nada é repetido:
`puzzle` (verificação humana) · `no_google_session` (o perfil do CDP não tem sessão dessa conta Google) · `needs_password` (o job **nunca** digita senha) · `needs_device` (toque no celular / chave) ·
`wrong_account` (o navegador está logado em outra conta). A linha impressa traz o comando à mão (`claude auth login --email <e>`). Marcar a conta "inviável por automação" e mandar o push é a fatia 2.

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

## As outras fatias
Fatia 2 (`ga-xoe5ao.5.2`): estado em `claude_login_renew.json`, a marca "inviável por automação" + UM push com o passo exato, retry de falha transitória, recheck em 24 h. Fatia 3 (`ga-xoe5ao.5.3`):
previsão T-7 dias e outage como gatilhos, uma conta por rodada, flock, plist launchd, chave de desligar. Até a 3 o job **não roda sozinho** e não há plist: só a linha de comando acima.
