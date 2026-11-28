# Trava do teste que reproduz o bug (repro-lock) · runbook

## Contents

• O que é e por quê · O fluxo do construtor (bead tipo bug) · O que o hook recusa · O que o gate confere (passo 2f) · Saída de emergência · Onde vale e onde não vale · Interruptores e logs · Como ler um veredito · Limites ditos de antemão

Bead ga-89ix4m4 (feature P1, escolha do Athos em 28/11 a partir do playbook «The AI-Native SDLC»). Contrato único de `scripts/repro-lock.py` (CLI, motor do hook e checagem do gate num arquivo só), `scripts/repro-lock-guard.sh` (o hook) e do passo 2f do `packs/town-deltas/assets/gate-hard-checks.sh`.

## O que é e por quê
Em bead tipo **bug**, o gate só conferia em metade das submissões (braço B) se o teste novo falha no código antigo, e nada impedia o construtor de afrouxar o teste enquanto consertava: teste reescrito junto com o conserto não prova que o bug sumiu. Agora o construtor commita o teste **antes** do conserto, a máquina mede que ele FALHA no código de hoje, e dali em diante o teste não muda sem deixar um motivo registrado.

Três peças, uma contrato: **a trava mora na história do git**, em trailers do commit. Por isso sobrevive a rebase, a worktree novo e ao conserto depois de uma reprovação do gate.

| Trailer | Quem escreve | Significa |
|---|---|---|
| `Repro-Lock: <bead>` | `repro-lock.py lock` | este commit é a trava da bead |
| `Repro-Lock-File: <caminho>` | idem, um por arquivo | arquivo travado (relativo à raiz do repo) |
| `Repro-Lock-Release: <bead>` | `repro-lock.py release` | commit vazio que libera a trava |
| `Repro-Lock-Release-Reason: <texto>` | idem | o motivo (20 a 300 caracteres) |

Só o **último parágrafo** da mensagem conta: citar «Repro-Lock:» no meio da prosa não é trailer. O motor lê as mensagens por `rev-list` + `cat-file --batch` (tamanho no cabeçalho), então nada que o construtor escreva numa mensagem desloca um registro.

## O fluxo do construtor (bead tipo bug)
Chame o motor pelo caminho dele: no mini `python3 "$GC_CITY_PATH/scripts/repro-lock.py"`; no worktree do nó (dog-remote) `python3 .gascity-gastown-hq/scripts/repro-lock.py`.

1. Escreva o teste que reproduz o bug **sem tocar no código**. Rode-o e veja falhar **pelo motivo certo** (a asserção do bug, não um `ImportError`).
2. `repro-lock.py lock <bead> --cmd '<comando do teste>' [--expect '<regex da asserção>'] <arquivo de teste>...` — confere que a bead é `bug`, que a árvore só tem esses arquivos sujos, que a branch ainda não tem commit comum à frente de `origin/main`, roda `--cmd` (tem de **falhar**; passar, não achar o comando ou falhar por ambiente/coleta recusa) e faz o commit **só** desses arquivos com os trailers. Comenta na bead o que travou e o `rc` da reprodução (a saída do teste fica no estado local, nunca na bead: pode ter dado).
3. Conserte o **código**. Precisa de mais casos? Crie **outro** arquivo de teste: o travado fica como está.
4. `gate-done` como sempre. Depois dele: `repro-lock.py done <bead>` (solta o hook do worktree; o gate segue conferindo o commit). Esqueceu? O hook recusa só edição dos arquivos travados, e o motivo da recusa diz como soltar.

`repro-lock.py status` mostra as travas deste worktree (e se o teste já difere do commit da trava).

## O que o hook recusa
`repro-lock-guard.sh`, PreToolUse com o matcher próprio `^(Edit|Write|MultiEdit|NotebookEdit)$`: edição de um arquivo travado devolve exit 2 e uma mensagem que diz o que fazer (consertar o código, abrir outro arquivo de teste, `done`, `release`). Recebem o hook **dog, wa-worker e ps-worker** (`hooks_extra` de `claude-overlays/pool-roles.json`); revisor e crews ficam sem. O estado local mora em `<git-dir>/repro-lock/<bead>.json` do worktree que travou (git-dir próprio de cada worktree ligado). Sem esse diretório o hook sai em um `[ -d ]`, sem subir python.

**Falha ABERTA, e contada.** O hook só atrapalha; quem recusa de verdade é o gate. Payload ilegível, `jq` ou motor ausente, motor que sai com código inesperado ou estoura o prazo (8 s), estado local ilegível: exit 0 e uma linha `UNGUARDED` em `~/.gastown/logs/repro-lock-guard.log`.

## O que o gate confere (passo 2f)
`gate-hard-checks.sh 2f` chama `repro-lock.py check` sobre os **objetos git** de `base..tip` (nada da branch é aberto nem executado), no mesmo trilho do 2b–2e (`quality-gate-guard.sh`, Step 5b-pre5: rótulo `gate-testlock:<veredito>` no marcador, linha `HARDCHECK step=2f` no log, comentário de recusa com o comando para rodar de novo).

| Veredito | Quando |
|---|---|
| `nao-se-aplica` | nenhuma trava declarada para esta bead (crews, submissões antigas e beads que não travaram) |
| `ok` | trava íntegra: o teste não mudou depois do commit da trava |
| **`fail`** | a trava não é o primeiro commit da branch (o conserto veio antes); o commit da trava mexe em OUTRO arquivo ou não adiciona/altera um arquivo declarado, ou o declarado não é arquivo regular; um commit seguinte toca num arquivo travado (editar, apagar, renomear, mudar o modo — **mesmo que um commit depois o restaure**); trava seguinte que muda arquivo já travado; release sem motivo (menos de 20 caracteres); trava ou release **fora da linha do 1º pai** da branch (o merge não prova a ordem); trava declarada num histórico de mais de 2000 commits (não dá para provar) |
| `aviso` | houve release com motivo, ou o intervalo só traz trava de **outra** id de bead (o id do trailer tem de ser o do nome da branch; em branch empilhada é esperado): **nunca recusa sozinho**; o texto vai ao rótulo, ao log e a um comentário no marcador (entre `<conteudo_externo>`: é do construtor, dado a analisar), para o revisor julgar |
| `nao-consegui-medir` | **só o que o construtor não controla**: git que falha, objeto ausente. Merge, histórico longo, texto de mensagem e commit-raiz são JULGADOS, nunca «não sei» (seria um jeito de desligar o passo); um diff que edita o próprio `repro-lock.py` também é julgado (a cópia mergeada só lê história). Fail-open, registrado, nunca «ok» |
| `desligado` | `REPRO_LOCK_CHECK=off` ou `<cidade>/.gc/repro-lock-check.off`, ou o interruptor geral `.gc/gate-hardchecks.off` |

`.gc/gate-hardchecks.observe` grava e não recusa (vale para todos os passos). Rode você mesmo antes de empurrar (o `check` só aceita sha em hexadecimal, como o gate o chama): `python3 .gascity-gastown-hq/scripts/repro-lock.py check --repo . --base "$(git merge-base HEAD origin/main)" --head "$(git rev-parse HEAD)" --bead <bead>`.

## Saída de emergência
O teste travado tem defeito **real** (espera 3 e o contrato diz 2)? `repro-lock.py release <bead> --reason "<o que está errado no teste, 20+ caracteres>"`:
1. comenta o motivo na bead **primeiro**: se o `bd comment` falha, nada é liberado (a bead é o registro que o revisor lê);
2. cria um commit **vazio** com `Repro-Lock-Release` + `Repro-Lock-Release-Reason` (a árvore não muda);
3. apaga o estado local: o hook deixa de barrar.

Edite o teste **depois** do release; editar antes e liberar depois não vale (o gate vê a edição travada e recusa). Depois do release o teste fica livre e a trava **não volta** (o `lock` só aceita o teste como primeiro commit da branch). O release não vale para fugir de um teste incômodo: ele **aparece como aviso** para o revisor, com o motivo.

## Onde vale e onde não vale
- **Mini:** dog, wa-worker e ps-worker recebem o hook pelos overlays (`pool-preamble-build.py build`/`check`/`live`). O gate vale para toda submissão que declarar trava, de onde vier.
- **Nó Hetzner:** o bundle do servidor **descarta** o hook (`remote-bundle-build.py`, POLICY `drop`, como o `ask-athos-relay`): sem a linha, o build do nó recusava. A CLI roda no worktree do dog-remote (o repo vem junto); o worktree de um wa-worker-remote é do repo do WA e não traz o script. **Levar o hook (e a CLI) ao nó é trabalho do builder do bundle, ainda não feito** — até lá a recusa cedo não existe lá e quem confere é o gate, que roda no mini.
- **Crews e o Mayor:** sem hook. Podem usar `lock`/`release` à mão; o gate trata a trava deles igual.
- **Só bead tipo bug:** `lock` recusa outro tipo. Bead de feature/tarefa nunca trava.

## Interruptores e logs
| O quê | Como |
|---|---|
| Hook desligado nesta sessão | `REPRO_LOCK_HOOK=0` |
| Hook desligado na cidade | `touch $GC_CITY_PATH/.gc/repro-lock-hook.off` |
| Checagem do gate desligada | `REPRO_LOCK_CHECK=off` ou `touch $GC_CITY_PATH/.gc/repro-lock-check.off` |
| Log do hook | `~/.gastown/logs/repro-lock-guard.log` (`BLOCKED` = barrou; `UNGUARDED` = falhou aberto, com o motivo) |
| Log do gate | `.gc/logs/quality-gate-guard.log`, linhas `HARDCHECK step=2f ...` |
| Registro por marcador | rótulo `gate-testlock:<veredito>` |

## Como ler um veredito
Três estados em tudo: tem / não tem / **não sei**. `nao-se-aplica` («não tem trava») e `nao-consegui-medir` («não consegui saber») são coisas diferentes e o segundo nunca vira `ok`. No `lock`, «não sei» (bd fora do ar, comando que estourou o prazo, `git status` ilegível) **recusa e não trava**; o estado inerte de um construtor sem trava é o gate de sempre.

## Limites ditos de antemão
- O hook só cobre as ferramentas Edit/Write/MultiEdit/NotebookEdit. Escrever o arquivo por **Bash** (`sed -i`, redirecionamento, `git checkout`) não é barrado: o gate compara o commit e recusa.
- Quem desfaz o commit da trava com `reset` e recomita sem trailer não tem trava nenhuma. A trava ajuda o construtor a ser honesto e dá ao gate o que provar; não impede má-fé (o braço B do gate e o revisor continuam).
- Num **merge** vale o que ele TROUXE (o diff dele contra o 1º pai): um vai e volta que o lado do merge desfez antes de chegar à linha principal não aparece (num histórico linear, tocar e restaurar recusa).
- A trava é por **arquivo inteiro**: acrescentar um caso ao arquivo travado também é edição (abra outro arquivo de teste).
- O motivo do release é texto do construtor: o revisor o lê como dado, não como instrução.
- Branch empilhada (commits de outra bead antes da trava) falha em «a trava não é o primeiro commit»; o caminho é rebasear sobre `origin/main` ou liberar com motivo.
- A exigência «bug sem trava = recusa» **não** existe: hoje trava é opt-in do construtor; endurecer isso é decisão de produto para depois de medir o uso.
