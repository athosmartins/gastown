# claude-login-renew — relogin das contas Claude no mini (ga-xoe5ao.5, fatias 1 a 3 de 3)

## Contents

• O que a fatia 1 faz · O que NUNCA faz · Inviável por automação (fatia 2) · A rodada agendada (fatia 3)
• Ativar e desligar · Quem julga · Prova ao vivo e o que não foi medido

## O que a fatia 1 faz
`python3 packs/town-deltas/assets/scripts/claude-login-renew.py --account <email> --force` renova **agora** o login Claude de UMA conta que tem config dir
(`~/.gastown/claude-accounts/<dir>`). Sai 0 se renovou, 2 se não (a linha impressa e o log `.gc/logs/claude-login-renew.log` dizem por quê, inclusive se outra rodada segura o lock, se o job está desligado ou se o estado da crew job não pôde ser lido), 64 se faltar `--account` ou `--force`.
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
O estado fica em `/Users/athos/shared/data/claude_login_renew.json` (`CLAUDE_RENEW_STATE` muda o caminho; escrita atômica; arquivo ilegível ou de forma errada vira estado vazio **dito no log**: marcas e tentativas se perdem — por isso a rodada agendada, que não pode perdê-las, **não lança nada** enquanto ele estiver ilegível).
- **Parede** (`puzzle`, `no_google_session`, `needs_password`, `needs_device`, `wrong_account`): a conta ganha `infeasible` (veredito, passo, `left` = segundos até o fim do melhor refresh token). O Athos recebe **UM** push
  (`notify -p 4`, contrato estrito do `claude-crew-account`: entregue = saída 0, 10 ou 11) com o veredito no título, o passo exato, a data em que o login da conta acaba (quando se sabe) e sem senha. Se o notify não entrega, a rodada agendada reenvia a cada 5 min; entregue, nunca mais.
  A mesma parede de novo não repete o push; uma parede **diferente** é um passo novo e manda outro.
- `no_google_session` e `needs_password` se consertam **no navegador**: a marca ganha `recheck_at` (+24 h, sem novo push) e a conta volta a ser tentada depois dele.
- **Falha transitória** (CLI sem URL, sem login novo, driver sem veredito, `claude` que não roda…): `tries` +1 e `next_at` = +6 h; a 3ª seguida vira a marca `failed_3_times`, com o mesmo push. Tentativa que **não lançou nada** (`skipped`: um item da conta não pôde ser lido) não conta.
- **Login à mão solta a marca**: o melhor login da conta com +1 dia de vida do que na marca (ou, se a marca não achou login nenhum, qualquer login com fim registrado) tira `infeasible` e `tries`. Item que não dá para ler, ou marca sem `left`, **não** solta.

## A rodada agendada (fatia 3)
`claude-login-renew.py` **sem argumentos** é o que o launchd chama a cada 15 min (plist `com.gascity.claude-login-renew`, `StartInterval` 900, `RunAtLoad` falso). Um `flock` (`.gc/claude-login-renew.lock`) impede duas rodadas juntas. Cada rodada:
1. Desligado (próxima seção)? Diz no log e sai 0 sem tocar em nada.
2. Estado do job ilegível, ou estado da `claude-crew-account` ausente/corrompido/ilegível? **Não julga login nenhum e não lança nada** (sem as marcas o job bateria na mesma parede e empurraria de novo; sem o estado da crew job não se sabe quem segura o default). Quando o ilegível é o estado da crew job, ainda reenvia os pushes pendentes; nos dois casos **sai 1** e o log diz qual dos dois.
3. Solta as marcas de quem logou à mão (fatia 2) e escolhe **no máximo UMA conta** — a primeira da fila:
   - **Previsão (T-7 dias)**: conta com config dir cujo **melhor** login guardado (o maior fim de refresh token entre o item do dir, o item reserva e, só para a conta que segura o default, o item default) acaba em ≤ 7 dias. O fim mais próximo vai primeiro. Fim não registrado em lugar nenhum = desconhecido, não previsão.
   - **Outage**: a crew job tem um episódio `no_login` aberto há ≥ 10 min (sem `ending`) **e** nenhuma conta tem login guardado completo que a crew job não tenha dado por morto — **todas** as contas da crew job entram nessa conta, também a que não tem config dir (o item reserva do athosmartins conta como login; ela só não é *tentada*, porque o relogin precisa de dir). A conta que o pool escolheu (`pool_decision.json`) vai primeiro, as outras por e-mail. Se algum item de qualquer conta não pôde ser lido, não se sabe que não há login: o outage não dispara, e o log diz (WARN).
   - A previsão vai antes do outage. A conta que **segura o default** fica de fora enquanto o item default é um login completo (a rotação da crew job a mantém); se o default não é completo, ela entra como qualquer outra.
   - Fica de fora: conta com marca `infeasible` (menos as de `recheck_at` vencido), conta com `next_at` no futuro, conta com item ilegível (dito no log como WARN). Marca que não é um objeto, ou `recheck_at` / `next_at` num formato que não dá para ler: a conta fica **intocada** e o log diz (WARN a cada rodada, até alguém consertar o estado).
4. Lança a tentativa da fatia 1/2 nessa conta, grava o estado e manda os pushes pendentes (um por marca).

Saídas da rodada agendada: **0** rodou (inclui «nada a fazer», desligado e lock ocupado); **1** não deu para julgar ou gravar (estado do job ou da crew job ilegível, estado que não grava, lock que não abre, rodada que quebrou — o log diz qual); 64 argumentos que não são uma rodada.

`--dry-run` (sozinho ou com `--account <e> --force`) diz no **stderr** o que faria — a conta, o gatilho e as que ficam na fila; com `--force` numa conta cujo item não se lê, diz «would be SKIPPED» (a tentativa real sairia 2 sem lançar nada) — sem lançar nada, sem gravar estado, sem push e sem arquivo de log.

**Sem lock compartilhado com a crew job.** A crew job escreve o item default e, no «sync-back», o item guardado da conta que **segura** o default (só quando o default é um login completo e nunca por cima de um login guardado mais novo). A previsão deixa de fora exatamente essa conta e o outage só vale com o default sem login completo (o sync-back então não escreve nada); este job só escreve o item do dir da conta que está tentando. Segurar o lock da crew job durante a tentativa (até ~6 min) pararia a troca de conta do pool nesse tempo, e isso não foi aceito sem o Athos. A janela que sobra: a conta tentada passar a segurar o default **e** ser trocada de volta durante a tentativa; aí o «devolver como estava» de uma tentativa que falhou poderia pisar num sync-back. Não medido.

## Ativar e desligar
**Ativar é um passo humano** (merged ≠ live). O plist está em `packs/town-deltas/assets/pending-activation/claude-login-renew.plist` **de propósito**: o deploy (`skill-integrity-install.sh`) instala sozinho todo `com.gascity.*` novo que achar direto em `assets/`, e este job abre um navegador e reescreve itens do Keychain. Depois de ler um `--dry-run` do que ele faria:
`cp packs/town-deltas/assets/pending-activation/claude-login-renew.plist ~/Library/LaunchAgents/com.gascity.claude-login-renew.plist && launchctl load ~/Library/LaunchAgents/com.gascity.claude-login-renew.plist`
O label é próprio — **não** é `com.gascity.claude-account-relog` (o swap por quota, ga-jf689).

**Chave de desligar**, sem recarregar nada: `touch <city>/.gc/no-login-renew` (apague para religar) ou `GC_LOGIN_RENEW=0` no ambiente; só o valor `0` desliga. Sem `GC_CITY_PATH` o arquivo não pode ser olhado: o log diz (WARN) e só `GC_LOGIN_RENEW=0` desliga. Vale para a rodada agendada (sai 0, dito no log) e para a forçada (sai 2, dito na linha).

## Quem julga
O **Keychain**, não o driver: o item precisa ter um login **novo e completo** (escopo `user:sessions:claude_code` + refresh token) cujo perfil diga que é da conta `<e>`. Login não completo ou de outra
conta é **devolvido como estava** (ou apagado, se não havia). Um login completo da conta certa feito à mão enquanto o job parava numa parede é mantido, não revertido. A prova impressa e logada são só
impressões sha256[:8] e datas (`refresh <antes> -> <depois>, ends <data>`), nunca o token.

## Prova ao vivo e o que não foi medido
Medido em 02/11 no mini (só impressões e datas): nenhuma conta com dir vence em ~04/11 (a premissa da bead estava velha): a mais próxima é athosb85, fim do refresh em 15/11; athoscrypto, terrenos e
throw.away.amb têm 25–29 dias. O Chrome de automação só tem sessão Google de `athoscrypto@` e `athosmartins@`: para athosb85, throw.away.amb e terrenos o relogin só passa depois de o Athos entrar nelas
**uma vez** nesse Chrome. A conta que segura o default (athoscrypto) não foi forçada: um login novo dela poderia custar ao default o refresh token (não medido).
**NÃO medido:**
- o caminho de sucesso ao vivo (tela Authorize; se o quebra-cabeça aparece no perfil confiável; se o Google pede TOTP ou toque num re-login) — está no selftest (navegador e TOTP simulados), não ao vivo;
- se um login novo revoga os refresh tokens antigos da mesma conta (se revoga, e a crew job acabou de copiar o login velho para o default, o default cai até a crew job curá-lo com o novo); quanto dura a sessão Google do perfil CDP;
- o job **rodando sob o launchd**: o plist foi lido (`plistlib`, lint de comentário), mas nunca carregado; o PATH do launchd achar `claude`, `gmail-totp` e `notify`, e o intervalo de 15 min, ficam por ver na ativação;
- o push chegando no celular do Athos (o notify é simulado nos testes);
- a janela do sync-back descrita acima.
