# prod-clone-checkout-watch — quem mexeu no clone vivo do WA (ga-eei1o4)

## Contents
- O que é e por que existe
- Ler o log (responder "quem?")
- Instalar, conferir, remover
- Quando o alarme chega
- Limites (o que isto NÃO faz)

## O que é e por que existe
`/Users/athos/gt/whatsapp_automation` é de onde rodam todos os daemons do WA. Em 24/10 04:07:22-04:07:41 um revisor do
gate fez `git checkout --detach <sha não mergeado>` nele e voltou 19 s depois; o reflog mostra mais 8 idas-e-voltas
desde 08/10 que ninguém sabe atribuir, porque o reflog não grava identidade. `wa-root-main-guard` (a cada 114 s) só lê o
NOME do branch: com o clone destacado de propósito, "destacado em origin/main" e "destacado em código sem revisão" saem
na mesma linha (mais de 10 mil vezes desde 20/07).

`scripts/prod-clone-checkout-watch.sh` é um hook `post-checkout` do clone vivo. A cada checkout nele grava uma linha com
o estado do HEAD novo contra `origin/main` e QUEM fez; se o HEAD ficou fora de `origin/main` (ou não deu para saber),
manda um `gc mail send mayor`. Nunca restaura nada e sempre sai 0 (o status do hook vira o status do `git checkout`).

## Ler o log (responder "quem?")
`.gc/logs/prod-clone-checkout.log`, uma linha por checkout, campos separados por TAB:
`result=CHECKOUT kind=branch|files state=on-main|off-main|unknown prev=… old=<sha9> new=<sha9> alarm=none|requested|suppressed(<10min)
session=… agent=… alias=… actor=… user=… chain=[pid] git … <- [pid] …`

- `state=off-main`: o HEAD novo NÃO está no histórico de `origin/main` (código sem revisão no ar).
- `state=unknown`: não consegui saber (origin/main ou o sha não resolvem, ou o `merge-base` falhou). Nunca é tratado como saudável.
- `session=` é o `GC_SESSION_NAME` do shell que rodou o git (o hook herda o ambiente); `chain=` são até 8 processos
  ancestrais, com a linha de comando do próprio git. Sessão de Claude → o transcrito está em `~/.claude/projects/<projeto>/<session>.jsonl`.
- `result=ALARM-FAILED`: o mail não saiu (a linha do checkout continua lá). `result=DISABLED`: kill switch (`PROD_CLONE_WATCH=off`).
- `kind=files` é `git checkout -- arquivo`: registrado, nunca alarma.

## Instalar, conferir, remover
```bash
A="$GC_CITY_PATH/scripts/prod-clone-checkout-watch-activate.sh"
bash "$A"            # instala o symlink em <hooks>/post-checkout (idempotente)
bash "$A" --check    # exit 0 só se ACTIVE
bash "$A" --remove   # só remove o que é nosso
```
Estados: `ACTIVE` (symlink para o script da checkout PRINCIPAL e ele existe e é executável) · `INERT` (symlink existe, o
alvo não — instalar antes do merge cai aqui de propósito e vira ACTIVE quando o arquivo chegar; MERGED ≠ LIVE, confira com
`--check`) · `FOREIGN` (já há outro `post-checkout`: não é tocado, exit 3) · `ABSENT`.
O script recusa caminho dentro de `.gc-worktrees/` (o link morreria com o worktree).

## Quando o alarme chega
1. Leia a linha do log: quem (`session=`/`chain=`), de onde (`old=`) para onde (`new=`).
2. Se o clone ainda está fora de `origin/main`: `git -C /Users/athos/gt/whatsapp_automation checkout --detach <old>`
   (único checkout permitido ali) e confira `git rev-parse HEAD`.
3. Cheque se algum daemon (re)iniciou entre o `new` e a volta: só então houve código sem revisão carregado. As mtimes dos
   arquivos regravados também alimentam o `swallowed-daemon-deploy-guard` com um "stale" falso.
4. Autor é revisor do gate? A regra está em `agents/gate-reviewer/prompt.template.md`, seção "Read-Only Enforcement".

## Limites (o que isto NÃO faz)
- Detecta depois do fato; não impede. O git não tem hook pré-checkout, e abortar de um hook `reference-transaction` deixa a
  árvore trocada com o HEAD no lugar antigo (testado: `HEAD=master`, arquivo do outro branch, índice `M`) — pior que o problema.
- `git -c core.hooksPath=… checkout` não dispara o hook (o `wa-root-main-guard` faz isso de propósito ao restaurar).
- `origin/main` do clone é o último fetch: um commit recém-mergeado, ainda não buscado, aparece como `off-main` (falso
  alarme, de custo baixo; o reflog mostra o updater avançando `origin/main` várias vezes por dia).
- Só vê checkout/switch no clone vivo. O hook roda também nos worktrees do clone (o `core.hooksPath` é compartilhado), mas
  sai logo: só o toplevel exato conta.
- Prevenção para sessões de Claude (guarda PreToolUse) fica para depois de o log mostrar quem faz isto de fato: das 9
  idas-e-voltas só 1 tem autoria provada.
