# Espelho git do servidor Hetzner · runbook

## Contents
• O que é · Peças · Como funciona · Instalação · Operação
• O que foi MEDIDO · O que foi INFERIDO · O que NÃO foi testado · Limites e resíduos · Como desfazer

Bead ga-2hd02v.1.3 (fatia 4 do ga-2hd02v.1; desenho do ga-ukxa3k). Regras do Athos: servidor SEM credencial do GitHub; nenhum dado de lead/cliente nem backup de bead fora do mini.

## O que é
O servidor trabalha num clone próprio de cada rig e **devolve o trabalho ao origin pelo espelho do mini**; nunca fala com o GitHub. Gate, merge e push seguem no mini. Nenhuma sessão real roda no servidor até a fatia 6 (ga-2hd02v.1.5).

```
servidor (runner) ──ssh -p 2293──▶ túnel reverso ──▶ sshd próprio do mini, só chave, 127.0.0.1:2293
 clone parcial + worktree/bead                        └─ comando forçado `hetzner-mirror.sh serve`: git-upload-pack | git-receive-pack | gt-mirror-spec
                                      espelho bare por rig ◀─ sync (fetch + varredura de conteúdo) ◀─ GitHub
                                      └─ publish ─▶ GitHub (sem force, só branches aceitas)
```

## Peças
| peça | onde | faz |
|---|---|---|
| `scripts/hetzner-mirror.sh` | mini | `init sync publish status authorize sshd tunnel`; internos `serve hook pack-hook spec-out` |
| `scripts/hetzner-mirror-scan.py` | mini | varre o CONTEÚDO de cada (blob, caminho) que um commit novo introduz; régua importada de `hetzner-pii-scan.py` (≥20 telefones ou ≥3 CPFs) |
| `scripts/hetzner-remote-git.sh` | servidor, `~/gt-remote/bin/` | `bootstrap pull wt-add wt-rm status scan` |
| `packs/town-deltas/assets/hetzner-mirror-{sshd,tunnel,sync}.plist` | mini (launchd) | sshd e túnel de pé; `sync` a cada 5 min |
| `scripts/hetzner-mirror.selftest.sh` | — | hermético, 232 casos, 0 falhas, sshd real (`HMST_FAKE=1` troca o ssh por chamada direta, só para desenvolver) |
| `<cidade>/.gc/hetzner-mirror/` · `~/gt-remote/{bin,git,keys}` | mini · servidor | estado (`repos/`, `state/<rig>/`, `authorized_keys`); só estas 3 pastas do servidor são desta fatia (o resto é do ga-zri39b) |

## Como funciona
**Filtro de dados = nome + pasta + CONTEÚDO.** Só por nome não basta: varredura de todo o histórico do WA achou 65 caminhos com listas de telefone/CPF e a Seção 1 do filtro de rsync pega 4; os outros 61 (43 ainda no HEAD) iriam ao servidor (`data/tracked_contacts.json` com 5.462 telefones, backup `.db` com 3.473, 14 `ab_results/*.json`, `.beads/backup/*`). O filtro do espelho é a Seção 1 + `.beads/ data/ logs/` + os caminhos que a varredura sinalizou (todas as versões do caminho, e o mesmo blob com outro nome).

**Código → servidor.** `sync` busca o origin, varre o conteúdo novo e só então grava o filtro novo e a marca de cobertura das pontas. O `upload-pack` só serve com `--filter=sparse:oid=<filtro vigente>` E cobertura em dia; o servidor pergunta o filtro por `gt-mirror-spec` (rc 75 enquanto varre). Sem `GIT_PROTOCOL` (o sshd não aceita env) o git fala v0: **fetch por oid de blob omitido é recusado**, inclusive o lazy fetch.

**Trabalho → origin.** O worker empurra `worker/<bead>` (ou `crew/`, ou `fix/` `feat/` nos rigs que usam). `pre-receive` recusa main/master, tag, apagar, reescrever, prefixo fora da lista e commit que toque caminho de dado. `post-receive` publica em segundo plano, sem force, pela URL (pelo remoto nomeado o git mexeria em `refs/remotes/origin`, que a cobertura precisa estável). Origin fora: o espelho guarda, `status` mostra `PENDENTE` + erro, o próximo `sync` publica.

**Worktree.** `wt-add <rig> <bead> [base]` faz `pull`, cria `wt/<bead>` (branch `worker/<bead>`) com sparse-checkout do mesmo filtro e grava em `worktrees.jsonl` `main`, `main_age_min`, `lag_min` (idade da última varredura boa do espelho) e `pull` (`ok`|`erro`: com o espelho em atualização o worktree sai do que havia e **diz**). Todo `pull` grava `lag_min` em `pulls.jsonl`.

## Instalação
Coordene com o dono do ga-zri39b (servidor compartilhado). Rode do **caminho mergeado** `$GC_CITY_PATH/scripts/`: `init`/`authorize` recusam `.gc-worktrees` (hook e comando forçado carregam o caminho do script).

```bash
export HETZNER_MIRROR_HOME=$GC_CITY_PATH/.gc/hetzner-mirror; B=$GC_CITY_PATH/scripts/hetzner-mirror.sh
$B init whatsapp_automation https://github.com/athosmartins/whatsapp-automation.git --seed ~/gt/whatsapp_automation/.git --prefix fix/ --prefix feat/
$B init gascity https://github.com/athosmartins/gastown.git --seed ~/gt/.git --prefix fix/ --prefix feat/
$B sync                      # 1º sync varre o histórico inteiro (ver MEDIDO); o servidor só é atendido depois
ssh hetzner-teste 'umask 077; mkdir -p ~/gt-remote/{bin,git,keys}; ssh-keygen -q -t ed25519 -N "" -C gt-mirror -f ~/gt-remote/keys/gt_mirror'   # a privada nunca sai de lá
ssh hetzner-teste 'cat ~/gt-remote/keys/gt_mirror.pub' > $HETZNER_MIRROR_HOME/server-key.pub
scp -q $GC_CITY_PATH/scripts/hetzner-remote-git.sh hetzner-teste:gt-remote/bin/ && ssh hetzner-teste 'chmod 755 ~/gt-remote/bin/hetzner-remote-git.sh'
$B authorize $HETZNER_MIRROR_HOME/server-key.pub; $B sshd start; $B hostkey > $HETZNER_MIRROR_HOME/server-known_hosts
scp -q $HETZNER_MIRROR_HOME/server-known_hosts hetzner-teste:gt-remote/keys/gt_known_hosts; $B tunnel start hetzner-teste
ssh hetzner-teste 'K=~/gt-remote/keys; R=~/gt-remote/bin/hetzner-remote-git.sh
  for r in whatsapp_automation gascity; do $R bootstrap $r ssh://athos@127.0.0.1:2293/$r.git $K/gt_mirror $K/gt_known_hosts fix/ feat/; done; $R scan'
```

**Durável.** `start` só guarda um pid. Pare-os (`$B sshd stop; $B tunnel stop hetzner-teste`) e carregue os plists: `for n in hetzner-mirror-{sshd,tunnel,sync}; do cp $GC_CITY_PATH/packs/town-deltas/assets/$n.plist ~/Library/LaunchAgents/com.gascity.$n.plist; launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gascity.$n.plist; done`. O `sync` tem trava por rig (rodada em curso é pulada, não empilhada).

**Troca para o caminho mergeado.** Antes do merge a prova rodou de uma cópia estável em `<cidade>/.gc/hetzner-mirror/bin/` (é o que hoje os hooks e a chave apontam). Depois: `$B init <rig> <url> [--prefix …]` (reescreve os hooks) e `$B authorize …/server-key.pub` (diz `comando forçado atualizado`); só então apague `bin/`.

## Operação
`$B status` (rc 0 só com tudo em dia): por rig `pronto` (cobertura nas pontas atuais), idade do último fetch+varredura bons, caminhos negados por conteúdo, filtro `igual`/`DIFERENTE`, branches `pendentes ao origin`, últimos erros. No servidor: `hetzner-remote-git.sh status` (`publicada`/`PENDENTE`/`sem trabalho novo`).

| sintoma | o que fazer |
|---|---|
| `pronto=NÃO` por mais de uns minutos | `$B sync <rig>`; erro em `lastfetcherror`; log em `<cidade>/.gc/logs/hetzner-mirror-sync-launchd.err`. O servidor segue com o que já baixou |
| `pull` do servidor: `em atualização` (75) | normal durante `sync`; `wt-add` sai do que havia e grava `"pull":"erro"` |
| `scan` do servidor: `VIOLAÇÃO` | filtro mudou depois do download, ou algo plantado: refaça o clone em diretório novo, não conserte à mão |
| `scan` rc 2 | não consegui varrer (clone ilegível, lista ausente, nome de arquivo com quebra de linha); nunca é "limpo" |
| `sync`: `caminho sinalizado que o filtro não consegue negar` | arquivo com lista de telefone/CPF e nome com quebra de linha/espaço no fim: o espelho para de servir (de propósito); renomeie/remova no origin |
| `serve.log` com recusas | alguém tentou outro comando com a chave; revogue apagando a linha de `authorized_keys` |

## O que foi MEDIDO
Ao vivo em 14/10 (mini com load 105–120, servidor a ~200 ms; log completo no comentário do ga-2hd02v.1.3). **1º `sync`: WA 268 s (35.667 pares, 64 caminhos negados por conteúdo), HQ 232 s (0 negados); `sync` incremental 11 s; `bootstrap` WA 178 s / 129 MB, HQ 124 s / 64 MB; `wt-add` 7 s (153 MB, 7.624 dos 7.691 arquivos); `scan` do servidor `limpo` nos dois.** Entrega: commit descartável de `worker/…` do servidor ao origin do WA em 27 s do `wt-add`, sem ação humana (`main_age_min=113`, `lag_min=9` gravados). Fronteira: `lib/action_log.py` está no servidor; `tests/test_phone_etl.py` dá `unadvertised object`; pelo túnel só `publickey` e um comando recusado de cada vez.
**O custo: 21 arquivos de CÓDIGO do WA não chegam ao servidor** (têm telefone/CPF dentro): 18 testes (`test_phone_etl`, `test_ficha360_data`, `test_getzip_pipeline`, `test_obito_demandas`, …), `daemons/clientes_seed.py`, `scripts/draft_comparison_server.py`, `scripts/generate_draft_experiments.py` (os dois últimos são os do cabeçalho do filtro de rsync). Lista exata: `state/whatsapp_automation/deny-extra`. Um worker que importe esses módulos falha; a saída é trocar números reais por sintéticos nas fixtures (a régua ignora número cujos 8 últimos dígitos têm ≤3 algarismos diferentes) — trabalho do WA.
**Os testes mordem.** Cópias com UMA guarda quebrada reprovam o teste da guarda (cobertura, limiar de conteúdo, `pre-receive`, filtro do `upload-pack`, `--no-abbrev`, `check-ignore -z`). Bugs reais que só apareceram porque os testes foram escritos para falhar: `git log --raw` ABREVIA o oid; o `nohup` do macOS falha sem tty (o `post-receive` nunca publicava sob o sshd); sem `-z` o `check-ignore` devolve o caminho escapado e o `scan` tratava um arquivo negado com `"`/`\`/tab no nome como permitido.

## O que foi INFERIDO
• O sshd principal do mini oferece `publickey,password,keyboard-interactive` (medido com `ssh -o PreferredAuthentications=none -v`); que um túnel até a porta 22 exporia a senha do usuário a um servidor alugado é inferência de risco, não ataque testado.
• Que o filtro vindo do espelho vale para outros rigs: só foi exercido em WA e HQ.

## O que NÃO foi testado
• **Plists carregados no launchd e sobrevivendo a reboot** (só `plutil -lint`; o caminho dentro deles é o mergeado). Hoje sshd e túnel são processos de pid e o `sync` só roda quando chamado: **até carregar os plists o clone do servidor envelhece**. A entrega (`story-delivery`) já exige o plist carregado.
• Origin/GitHub fora **em produção** (só no selftest); recuperação do túnel após queda; branch empurrada no `gascity` (público: só clone e `scan` ao vivo); `property_scrapers`/`lexbh`/`marketing` (sem espelho; `data/` e `logs/` valem como pasta negada em QUALQUER rig); blob >50 MB; `sync` concorrente com push em produção.
• `authorize` com `authorized_keys` ilegível: o ramo recusa, mas o `authorize` faz `chmod 600` antes de ler e o selftest não o provoca.
• Sessão real do claude no servidor (fatia 6) e se um worker sente falta dos 21 arquivos.

## Limites e resíduos
• A varredura é heurística de forma (telefone BR e CPF, ≥20/≥3): não vê nome, e-mail, CNPJ, endereço nem lista pequena. O mesmo vale para o rsync.
• Os NOMES dos arquivos omitidos aparecem nas árvores; falso positivo por nome existe (`*.db-*` pega `com.whatsapp.db-sync.plist`; `*token*.toml` pega `token-ledger-harvest.toml`).
• Bytes idênticos sob um caminho permitido chegam (fórmula copiada, arquivo vazio); o `scan` conta e não acusa. Um segredo copiado para um nome comum passaria.
• Mudar filtro ou varredura não remove o que o servidor JÁ baixou. Dado que chegue ao servidor só por commit de merge: a ida vê (`-m`), o `pre-receive` na volta não. Mini fora = o push espera.

## Como desfazer
`$B tunnel stop hetzner-teste; $B sshd stop`; `launchctl bootout gui/$(id -u)/com.gascity.hetzner-mirror-{sshd,tunnel,sync}` e apagar os plists de `~/Library/LaunchAgents`; apagar a linha de `authorized_keys` revoga a chave. Servidor: `rm -r ~/gt-remote/git ~/gt-remote/keys ~/gt-remote/bin/hetzner-remote-git.sh`. Os espelhos em `repos/` se recriam com `init`.
