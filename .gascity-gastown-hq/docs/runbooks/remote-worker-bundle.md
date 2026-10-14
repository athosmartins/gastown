# Bundle de settings/hooks do worker remoto (Hetzner) · runbook

## Contents

• O que esta fatia é — e o que não é · Como rodar (build / verify)
• Vereditos por hook (medidos no mini de verdade) · O que foi medido, o que foi inferido, o que não foi testado
• O 1º uso real recusou as skills · Pontos em aberto para as próximas fatias · Limites do builder

Bead ga-2hd02v (feature; desenho escolhido no estudo ga-ukxa3k). **Esta é a fatia 1: o spike do bundle de settings/hooks**, porque o plano manda começar por ele. Só ela foi feita: o Mayor segurou o resto em 2026-10-14T01:42Z, comentário no ga-2hd02v ("P0→P2 … só a 1ª fatia de cada", decisão do Athos por AskUserQuestion). As fatias seguintes estão no bead de continuação (`pilot:no-auto-dispatch`), não aqui.

**Esta fatia não instala nada no servidor e não escreve nele.** Ela produz um diretório no mini, `OUT/`, com tudo que uma sessão remota carregaria no lugar de `~/.claude`, `<cidade>/.gc/settings.json` e `<papel>/.claude`. Levar o `OUT/` ao servidor é trabalho do atalho/provider (fatia seguinte).

## Como rodar

```bash
S=$GC_CITY_PATH/scripts
python3 -I $S/remote-bundle-build.py build --city $GC_CITY_PATH --claude-home ~/.claude \
  --role dog --role-dir $GC_CITY_PATH/.gc/agents/dogs/gastown.dog-1 \
  --remote-root /home/runner/gt-remote/bundle --remote-home /home/runner --out OUT [--skills]
python3 -I $S/remote-bundle-build.py verify OUT      # re-hasheia e confere com manifest.json
bash $S/remote-bundle-build.selftest.sh              # hermético (fixtures em mktemp), 49 casos
```

Saída: `home/.claude/{settings.json,hooks/*}`, `city/settings.json`, `role/<papel>/.claude/{settings.json,skills/*}` e `manifest.json` (veredito por hook, `shim_needs`, chaves descartadas, sha256 de cada arquivo, `bundle_hash` sem data/hora). Códigos: 0 ok · 2 uso · 3 recusado · 4 `verify` achou diferença ou não leu o manifest.

**Quem decide o que entra é a tabela `POLICY` no topo do script** (hook × veredito × motivo). Hook que não está nela **não é enviado: o build recusa** e diz qual. Um hook novo no mini quebra o build de propósito, até alguém classificá-lo.

## Vereditos por hook

Rodado contra o mini em 14/10 ~00h (MEDIDO; `bundle_hash` muda quando qualquer settings/hook mudar — não é valor de referência):

| origem | hook | veredito | por quê |
|---|---|---|---|
| user | `enforce-multiple-choice-question.sh` (Stop) | keep | bash+jq, falha aberta; a regra 1 vale em qualquer host |
| user | `enforce-mail-mcq-on-send.sh` (PreToolUse Bash) | keep | jq+python3, falha aberta |
| user | `filter-{bash,test,scraper}-output.sh` | keep | só jq/grep; poupam tokens da cota compartilhada |
| user | `log-token-usage.sh` | keep | grava só no `~/.claude` do servidor; baixo valor, custo zero |
| user | `ntfy-prompt-submit`, `ntfy-on-stop` | drop | tópico ntfy privado + CLI `notify`; o servidor não guarda segredo |
| user | `gt tap guard cross-clone-block` | drop | binário `gt` e layout de clones do mini — **buraco, ver abaixo** |
| user | `fuse-avoidance.sh` (2 entradas) | drop | CloudStorage/Mobile Documents não existem no Linux |
| city | `gc handoff`, `gc prime`, `gc nudge drain`, `gc mail check` | shim | ficam **verbatim**; no servidor `gc` é o atalho ssh→mini |
| city, role | `home-scan-guard` | drop | guarda do TCC do macOS |
| role | `cut-output-shadow` (2 eventos) | drop | experimento em sombra, log local do mini |

Chaves de settings fora da lista de portáveis saem e ficam registradas em `manifest.json → dropped_keys` (no user: `model`, `statusLine`, `enabledPlugins`, `remoteControlAtStartup`, `skillOverrides`, `effortLevel`…). `settings.local.json` **nunca** é lido. Regras de permissão com `launchctl`/`osascript`/`/Users/`/`/Library/`/`/private/` saem **e são contadas** em `manifest.json → dropped_rules` (no mini hoje: `user.allow: 2`) — só a contagem, o texto da regra não vai para o bundle; se a regra estiver em `deny` ou `ask` o build **recusa**, porque tirar uma trava sem saber o que ela guardava não é inerte; `additionalDirectories`, `claudeMdExcludes` e `env` têm os caminhos do mini reescritos (cidade → `<remote-root>/city`, `~/gt` → `<remote-root>/work`, home → `--remote-home`).

## Medido, inferido, não testado

**MEDIDO**
* Servidor `hetzner-teste` (1 sonda ssh, só leitura): Linux aarch64, `tmux git jq python3 rsync curl` presentes, **`claude` e `node` ausentes**, 280 GB livres.
* No mini, nas 10 linhas de `ps` com claude de 14/10 ~00h, o `gc` sobe o claude com `--settings <cidade>/.gc/settings.json` (10 de 10), `--dangerously-skip-permissions` (10 de 10), `--model opus|sonnet` (10 de 10), `--remote-control` (5) e, nessas 5, um segundo `--settings {"remoteControlAtStartup":false}`. O provider `gc-session-ssh` tem que repetir esses argumentos, senão o bundle muda de sentido.
* `city/settings.json` (a que o `--settings` aponta) traz `deny: Bash(sudo:*), Bash(rm -rf:*)`; o `~/.claude/settings.json` traz `ask` para as mesmas duas regras. O build leva as duas camadas.
* Os hooks do `gc` (`PreCompact`/`SessionStart`/`UserPromptSubmit`) vêm de `<cidade>/.gc/settings.json`; o `settings.json` do papel só tem hooks `drop`. O builder cobre as 3 camadas (user, cidade, papel).
* Selftest: o builder do rascunho anterior (sem as correções desta fatia) reprova 13 dos 49 casos (manifest ilegível ×3, mensagem de gravação, forma inesperada do settings ×2, symlink de diretório em skill ×2, regra descartada contada, regra de `deny` com caminho de macOS ×2, script que só contém o nome de um `keep` ×2); o caso "troca de OUT que falha deixa o anterior intacto" passa nos dois — é guarda de comportamento que já existia, não prova correção. Dois builds seguidos da config real do mini saem byte a byte iguais.

**INFERIDO** (não rodado no Linux)
* Com `--dangerously-skip-permissions` as regras `ask` não travam a sessão sem humano; `deny` continua valendo. Era a dúvida sobre `rm -rf` no servidor (não existe `safe-clean` lá).
* Cada prompt dispara 2 hooks `gc` (`nudge drain`, `mail check`) → 2 idas ao mini por prompt; com ~0,7 s por chamada do estudo ga-ukxa3k, ≈1,4 s de latência por prompt. Ordem de grandeza, não medição.

**NÃO TESTADO**
* Instalar o claude no servidor e logar: o login é OAuth interativo, passo humano do Athos (mesma assinatura — decisão do Athos por AskUserQuestion, citada no comentário do Mayor no ga-ukxa3k de 2026-10-13 21:58, como registrado lá). Se o claude precisa do `node` ausente: não sei.
* Plugins (`enabledPlugins`: github, beads, superpowers, security-guidance, playwright, frontend-design) saem do bundle; instalá-los no servidor não foi tentado.
* Que o claude do servidor aceite o `OUT/` como veio. Nenhum arquivo foi levado para lá.
* O aviso "bundle novo gravado; não consegui apagar OUT.old" (rmtree falhando depois da troca) e a volta do bundle anterior quando a troca falha no meio: escritos, sem caso no selftest — não há como provocar a falha a partir do shell.

## O 1º uso real recusou as skills

`build --skills` contra as 18 skills do dog **saiu 3** (guarda funcionando): o texto de 3 skills tem 5 valores no formato de CPF/CNPJ (`censec-inventario-extrajudicial` 1, `cnd-municipal-pbh` 3, `cnd-trabalhista-cndt` 1). Nenhum é zero/dígito repetido/`123456789…`, então não parecem placeholders. Não sei se são fixtures, CNPJs públicos ou dado de cliente — e "não sei" não vira "pode enviar". **Não afrouxei o regex.** Os dígitos não foram impressos em lugar nenhum desta sessão. Antes de enviar skills: um humano olha esses 5 valores e (a) o texto da skill é limpo, ou (b) o valor entra numa lista de exceção por arquivo+hash. O build sem `--skills` não é afetado. (Um dos arquivos, o `SKILL.md` do censec, não é versionado no git.)

## Pontos em aberto para as próximas fatias

1. **A allowlist do atalho do desenho não cobre o bundle.** O ga-ukxa3k lista `bd show/list/update/comment/close`, `gc mail`, `gc session nudge`, `gate-done`. Os hooks precisam ainda de `gc prime --hook`, `gc handoff --auto`, `gc nudge drain --inject` e `gc mail check --inject` (o `manifest.json → shim_needs` lista as strings exatas). Ou a allowlist cresce 3 itens (`prime`, `handoff`, `nudge drain`; `mail check` já cabe em `gc mail`) ou esses hooks saem do servidor.
2. O `gc` injetado faz `export PATH="$HOME/go/bin:$HOME/.local/bin:$PATH"`: o atalho tem que morar em `/home/runner/.local/bin` ou `/home/runner/go/bin`.
3. `gt tap guard cross-clone-block` foi cortado e **não tem substituto no servidor**: lá nada impede uma sessão de editar o clone de outra. Precisa de equivalente antes de worker autônomo (bead próprio na continuação).
4. `statusLine` e as chaves de modelo/plugin ficaram de fora de propósito; decidir no provider qual `--model` cada papel recebe.
5. `--skills`: decisão sobre os 5 valores acima.
6. Nada de dado de lead/cliente nem backup de bead sai do mini (regra do Athos). O bundle é código + settings; o builder recusa arquivo de dado, binário, segredo, CPF/CNPJ/telefone e qualquer `/Users/` sobrando.

## Limites do builder

* A guarda de segredo/PII **reconhece formatos conhecidos** (chave `sk-`, tokens GitHub/Slack/AWS, chave privada, tópico ntfy, CPF, CNPJ, telefone BR). Formato que ela não conhece passa; ausência de vazamento não está provada, só a dos formatos listados.
* Casamento do hook com a `POLICY` é por trecho do comando: um comando que contenha um token `drop` em qualquer ponto é descartado (sentido seguro: nada é enviado); um que contenha um token `keep` precisa ser exatamente `~/.claude/hooks/<o script do token>` (um nome que só *contém* o token, como `my-filter-bash-output.sh`, recusa), e um `shim` precisa ser `gc <subcomando>` puro, senão recusa.
* Script `keep` é copiado inteiro, comentários inclusos; `/Users/` em comentário recusa o build.
* Não valida o JSON contra o schema do claude, só garante que o que saiu veio de chaves da lista.
