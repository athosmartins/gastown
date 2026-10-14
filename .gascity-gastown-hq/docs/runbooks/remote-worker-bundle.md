# Bundle de settings/hooks do worker remoto (Hetzner) · runbook

## Contents

• O que esta fatia é — e o que não é · Como rodar (build / verify)
• Vereditos por hook (medidos no mini de verdade) · O que foi medido, o que foi inferido, o que foi contrariado por medição, o que não foi testado
• O 1º uso real recusou as skills · Pontos em aberto para as próximas fatias · Limites do builder

Bead ga-2hd02v (feature; desenho escolhido no estudo ga-ukxa3k). **Esta é a fatia 1: o spike do bundle de settings/hooks**, porque o plano manda começar por ele. Só ela foi feita: o Mayor segurou o resto em 2026-10-14T01:42Z, comentário no ga-2hd02v ("P0→P2 … só a 1ª fatia de cada", decisão do Athos por AskUserQuestion). As fatias seguintes estão no bead de continuação (`pilot:no-auto-dispatch`), não aqui.

**Esta fatia não instala nada no servidor e não escreve nele.** Ela produz um diretório no mini, `OUT/`, com tudo que uma sessão remota carregaria no lugar de `~/.claude`, `<cidade>/.gc/settings.json` e `<papel>/.claude`. Levar o `OUT/` ao servidor é trabalho do atalho/provider (fatia seguinte).

## Como rodar

```bash
S=$GC_CITY_PATH/scripts
python3 -I $S/remote-bundle-build.py build --city $GC_CITY_PATH --claude-home ~/.claude \
  --role dog --role-dir $GC_CITY_PATH/.gc/agents/dogs/gastown.dog-1 \
  --remote-root /home/runner/gt-remote/bundle --remote-home /home/runner --out OUT [--skills]
python3 -I $S/remote-bundle-build.py verify OUT      # re-hasheia os arquivos, o bit de execução e o bundle_hash e confere com manifest.json
bash $S/remote-bundle-build.selftest.sh              # hermético (fixtures em mktemp), 98 casos; leva de 2 a 7 min conforme a carga da máquina (medido com load 55–66)
```

Saída: `home/.claude/{settings.json,hooks/*}`, `city/settings.json`, `role/<papel>/.claude/{settings.json,skills/*}` e `manifest.json` (veredito por hook, `shim_needs`, chaves descartadas, sha256 de cada arquivo, `bundle_hash` sem data/hora). Códigos: 0 ok · 2 uso · 3 recusado · 4 `verify` achou diferença ou não leu o manifest, uma pasta ou um arquivo de `OUT`.

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

## Medido, inferido, contrariado por medição, não testado

**MEDIDO**
* Servidor `hetzner-teste` (1 sonda ssh, só leitura): Linux aarch64, `tmux git jq python3 rsync curl` presentes, **`claude` e `node` ausentes**, 280 GB livres.
* No mini, nas 10 linhas de `ps` com claude de 14/10 ~00h, o `gc` sobe o claude com `--settings <cidade>/.gc/settings.json` (10 de 10), `--dangerously-skip-permissions` (10 de 10), `--model opus|sonnet` (10 de 10), `--remote-control` (5) e, nessas 5, um segundo `--settings {"remoteControlAtStartup":false}`. O provider `gc-session-ssh` tem que repetir esses argumentos, senão o bundle muda de sentido.
* `city/settings.json` (a que o `--settings` aponta) traz `deny: Bash(sudo:*), Bash(rm -rf:*)`; o `~/.claude/settings.json` traz `ask` para as mesmas duas regras. O build leva as duas camadas.
* Os hooks do `gc` (`PreCompact`/`SessionStart`/`UserPromptSubmit`) vêm de `<cidade>/.gc/settings.json`; o `settings.json` do papel só tem hooks `drop`. O builder cobre as 3 camadas (user, cidade, papel).
* Selftest: o builder do rascunho anterior (sem as correções desta fatia) reprova 13 dos 49 casos (manifest ilegível ×3, mensagem de gravação, forma inesperada do settings ×2, symlink de diretório em skill ×2, regra descartada contada, regra de `deny` com caminho de macOS ×2, script que só contém o nome de um `keep` ×2); o caso "troca de OUT que falha deixa o anterior intacto" passa nos dois — é guarda de comportamento que já existia, não prova correção. Dois builds seguidos da config real do mini saem byte a byte iguais.
* Reprovação do gate (ga-m1effd, 1ª tentativa): o selftest cresceu de 49 para 84 casos e o builder do commit `efea627b9` reprova 23 dos 84, medido (shim com newline / CR / `$(...)` ou crase no PATH / PATH diferente do que o gc injeta / variável que não é `GC_*` / subcomando que só começa igual / veredito de um token e execução de outro / grupo de hooks sem a chave `hooks` / `shim_needs` normalizado ×1; telefone BR sem `+55` ×4; reescrita de caminho sem fronteira; raiz de OUT 0700; `verify` sem olhar o `bundle_hash` ×3; `--skills` com diretório vazio; skill que é pasta sem arquivo). Os outros 61 passam nos dois, inclusive o caso de `verify` com `exec` de tipo errado, que guarda código novo desta correção e não reprova no antigo. Com a correção, 84 de 84; o build da config real do mini sai byte a byte igual ao de antes (mesmo `bundle_hash`, 9 arquivos, 4 `shim_needs`) — a correção só recusa mais entrada ruim, não muda o que a config real produz.
* Reprovação do gate (2ª tentativa, gate_run ga-mi59c0, sobre `e804c006b`): `Bundle.skills()` percorria cada skill com `os.walk` sem `onerror`, então uma subpasta que não lista (`chmod 000`) contribuía com zero arquivos, o build dizia "ok" e o `verify` concordava com o próprio manifest incompleto — o "entrada ilegível → exit 3, nada escrito" prometido valia só para arquivo, não para pasta. Corrigido com `onerror` que recusa dizendo skill e pasta. Varredura da classe no diff inteiro achou o mesmo buraco no `verify` (`rglob` engolia pasta ilegível de `OUT`; arquivo ilegível estourava traceback com código 1; symlink de diretório e symlink quebrado em `OUT` eram invisíveis) e o mesmo formato no próprio selftest (`grep …; [ $? != 0 ]` passava quando o grep dava erro 2). O selftest foi de 84 para 98 casos (as recusas de shim agora também afirmam a mensagem). O builder de `e804c006b` reprova 5 dos 98, medido, e os 93 restantes passam nos dois; com a correção, 98 de 98. Cada guarda nova foi apagada à parte (mutante) e o caso dela reprovou: sem `onerror` em `skills()` 2 casos, sem `onerror` no `verify` 1, sem o `islink` 1, sem o `except OSError` 1. O build da config real do mini continua com o mesmo `bundle_hash` (`0d204dbbebe6`), 9 arquivos e 4 `shim_needs`, dois builds byte a byte iguais, `verify` 0; `--skills` na config real segue recusado pelos valores em formato de CPF/CNPJ (decisão humana, ver abaixo).

**INFERIDO** (não rodado no Linux)
* Cada prompt dispara 2 hooks `gc` (`nudge drain`, `mail check`) → 2 idas ao mini por prompt; com ~0,7 s por chamada do estudo ga-ukxa3k, ≈1,4 s de latência por prompt. Ordem de grandeza, não medição.

**CONTRARIADO POR MEDIÇÃO** (a versão anterior deste runbook afirmava o oposto, como inferência)
* ~~Com `--dangerously-skip-permissions` as regras `ask` não travam a sessão sem humano.~~ A doutrina da cidade, medida em 15–16/08 (ga-gkap9p), diz que uma regra `ask` explícita **sobrepõe** o bypass: 4 travas de pool de 54 a 97 min em `Bash(rm -rf:*)`, sem ninguém para apertar a tecla. O bundle leva `ask: Bash(rm -rf:*), Bash(sudo:*)` na camada `home` e **não há `safe-clean` no servidor**. A camada `city` também tem `deny` nas duas mesmas regras, e `deny` é avaliado antes de `ask` — então o `deny` pode estar escondendo o problema (o comando seria negado, não travaria). "Pode": isso **não foi testado no Linux**. Antes de o provider construir em cima, testar no servidor: (a) `rm -rf` de um scratch com só o `ask` (sem o `deny` do city) e (b) com os dois.

**NÃO TESTADO**
* Instalar o claude no servidor e logar: o login é OAuth interativo, passo humano do Athos (mesma assinatura — decisão do Athos por AskUserQuestion, citada no comentário do Mayor no ga-ukxa3k de 2026-10-13 21:58, como registrado lá). Se o claude precisa do `node` ausente: não sei.
* Plugins (`enabledPlugins`: github, beads, superpowers, security-guidance, playwright, frontend-design) saem do bundle; instalá-los no servidor não foi tentado.
* Que o claude do servidor aceite o `OUT/` como veio. Nenhum arquivo foi levado para lá.
* O comportamento do `ask` vs `deny` com `--dangerously-skip-permissions` no claude do servidor (ver CONTRARIADO POR MEDIÇÃO acima).
* O aviso "bundle novo gravado; não consegui apagar OUT.old" (rmtree falhando depois da troca) e a volta do bundle anterior quando a troca falha no meio: escritos, sem caso no selftest — não há como provocar a falha a partir do shell.

## O 1º uso real recusou as skills

`build --skills` contra as 18 skills do dog **saiu 3** (guarda funcionando): o texto de 3 skills tem 5 valores no formato de CPF/CNPJ (`censec-inventario-extrajudicial` 1, `cnd-municipal-pbh` 3, `cnd-trabalhista-cndt` 1). Nenhum é zero/dígito repetido/`123456789…`, então não parecem placeholders. Não sei se são fixtures, CNPJs públicos ou dado de cliente — e "não sei" não vira "pode enviar". **Não afrouxei o regex.** Os dígitos não foram impressos em lugar nenhum desta sessão. Antes de enviar skills: um humano olha esses 5 valores e (a) o texto da skill é limpo, ou (b) o valor entra numa lista de exceção por arquivo+hash. O build sem `--skills` não é afetado. (Um dos arquivos, o `SKILL.md` do censec, não é versionado no git.)

## Pontos em aberto para as próximas fatias

1. **A allowlist do atalho do desenho não cobre o bundle.** O ga-ukxa3k lista `bd show/list/update/comment/close`, `gc mail`, `gc session nudge`, `gate-done`. Os hooks precisam ainda de `gc prime --hook`, `gc handoff --auto`, `gc nudge drain --inject` e `gc mail check --inject` (o `manifest.json → shim_needs` lista as strings exatas). Ou a allowlist cresce 3 itens (`prime`, `handoff`, `nudge drain`; `mail check` já cabe em `gc mail`) ou esses hooks saem do servidor.
2. O `gc` injetado faz `export PATH="$HOME/go/bin:$HOME/.local/bin:$PATH"`: o atalho tem que morar em `/home/runner/.local/bin` ou `/home/runner/go/bin`.
3. `gt tap guard cross-clone-block` foi cortado e **não tem substituto no servidor**: lá nada impede uma sessão de editar o clone de outra. Precisa de equivalente antes de worker autônomo (bead próprio na continuação).
4. `statusLine` e as chaves de modelo/plugin ficaram de fora de propósito; decidir no provider qual `--model` cada papel recebe.
5. `--skills`: decisão sobre os 5 valores acima.
6. Nada de dado de lead/cliente nem backup de bead sai do mini (regra do Athos). O bundle é código + settings; o builder recusa arquivo de dado, binário, segredo, CPF/CNPJ/telefone (formatos em "Limites") e qualquer `/Users/` sobrando.
7. **`ask` do `~/.claude` sem humano no servidor** (ver CONTRARIADO POR MEDIÇÃO): testar no Linux se o `deny` do city cobre, ou tirar o `ask` da camada `home` do servidor, ou levar um `safe-clean` — antes da fatia do provider.

## Limites do builder

* A guarda de segredo/PII **reconhece formatos conhecidos** (chave `sk-`, tokens GitHub/Slack/AWS, chave privada, tópico ntfy, CPF, CNPJ, telefone BR). Formato que ela não conhece passa; ausência de vazamento não está provada, só a dos formatos listados.
* **Telefone BR** é reconhecido em: `+55 31 99999-1234`, `(31) 99999-1234`, `31 99999-1234`, celular colado de 11 dígitos (`31999991234`) e com 55 na frente (`5531999991234`); fixo (`31 3333-4444`) só com separador antes dos 4 últimos dígitos. **Não é reconhecido:** fixo de 10 dígitos colados (`3133334444`) — colide com timestamp de 10 dígitos (`17xxxxxxxx`) e a guarda recusaria fixture legítima; número com letra ou dígito colado antes/depois (dentro de hex, hash, id). O falso positivo conhecido é o inverso: texto formatado como telefone que não é (recusa o build; sentido seguro).
* Casamento do hook com a `POLICY` é por trecho do comando: um comando que contenha um token `drop` em qualquer ponto é descartado (sentido seguro: nada é enviado); um que contenha um token `keep` precisa ser exatamente `~/.claude/hooks/<o script do token>` (um nome que só *contém* o token, como `my-filter-bash-output.sh`, recusa), e um `shim` precisa ser, **inteiro e sem normalização** (a string que é decidida é a que é enviada), `[export PATH="$HOME/go/bin:$HOME/.local/bin:$PATH" && ][GC_*=valor ]gc <handoff|prime|nudge drain|mail check>[ args]`: `args` sem caractere de controle (newline e CR são o 2º comando) nem `; & | ` $ ( ) < >`; o PATH é o literal que o gc injeta, não "qualquer coisa entre aspas"; variável de ambiente só `GC_*`; o subcomando executado tem que ser o do token que decidiu o veredito (`gc prime --hook gc handoff` recusa); `shim_needs` guarda o subcomando e os argumentos exatamente como são enviados (dois espaços ficam dois espaços). Qualquer desvio recusa.
* `verify` detecta arquivo mudado/faltando/sobrando (inclui symlink de diretório e symlink quebrado dentro de `OUT`, que contam como sobra), bit de execução perdido, pasta ou arquivo de `OUT` que não consegue ler (sai 4 dizendo qual; "não consegui ler" nunca vira "limpo") e `bundle_hash` ausente ou diferente do recalculado a partir de `manifest.files` (arquivo + `manifest.files` editados juntos denunciam-se pelo hash velho). Ele **não prova origem**: quem recalcular também o `bundle_hash` passa — é guarda contra deriva e erro, não contra adversário.
* A reescrita de caminho tem fronteira dos dois lados (`~/gt` não vira `work` dentro de `gt-backup` nem `gt2`, e `/xx/Users/...` não é o caminho do mini); o que não casar com nenhuma regra fica como estava e a guarda de `/Users/` sobrando recusa. `--skills` pedido com a pasta de skills vazia recusa (a linha final do build conta as skills entregues), e subpasta ilegível dentro de uma skill (`chmod 000`) também recusa, dizendo skill e pasta: o `os.walk` engole o erro de listagem por padrão, a pasta contribuiria com zero arquivos e o build diria "ok" com a skill incompleta.
* Script `keep` é copiado inteiro, comentários inclusos; `/Users/` em comentário recusa o build.
* Não valida o JSON contra o schema do claude, só garante que o que saiu veio de chaves da lista.
