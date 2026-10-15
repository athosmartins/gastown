# Espelho git do servidor Hetzner · runbook

## Contents

• O que é — e o que não é · Peças e onde moram · Como funciona (o caminho do dado e do código)
• Instalação (mini, servidor, e a troca para o caminho mergeado) · Operação: status, o que fazer quando algo falha
• O que foi MEDIDO · O que foi INFERIDO · O que NÃO foi testado · Limites e resíduos (leia antes de confiar) · Como desfazer

Bead ga-2hd02v.1.3 (fatia 4 do épico ga-2hd02v.1, desenho do estudo ga-ukxa3k, decisões do Mayor em 14/10 e do Athos: servidor SEM credencial do GitHub, nenhum dado de lead/cliente nem backup de bead fora do mini).

## O que é — e o que não é

O servidor alugado trabalha num clone próprio de cada rig e **devolve o trabalho ao origin pelo espelho do mini**. Ele nunca fala com o GitHub. Gate, merge e push continuam no mini.

```
servidor (runner)                                mini (athos)
 clone parcial  ──ssh -p 2293──▶ túnel reverso ──▶ sshd próprio, só chave, 127.0.0.1:2293
 worktree/bead   (chave dedicada)                    └─ comando forçado: hetzner-mirror.sh serve
                                                        ├─ git-upload-pack  (só com o filtro de dados vigente + varredura em dia)
                                                        ├─ git-receive-pack (pre-receive: só crew/ worker/ + prefixo do rig)
                                                        └─ gt-mirror-spec   (devolve o filtro vigente)
                                                     espelho bare por rig ◀── sync (fetch + varredura de conteúdo) ◀── GitHub
                                                        └─ publish ──▶ GitHub (push sem force, só das branches aceitas)
```

Não é: um segundo `bd`/`gc` no servidor (isso é a fatia 3, ga-2hd02v.1.2); login do claude (fatia 5); o substituto do `cross-clone-block` (fatia 6). **Nenhuma sessão real roda no servidor até a fatia 6**; a prova abaixo usa um commit descartável numa branch de teste.

## Peças e onde moram

| peça | onde | o que faz |
|---|---|---|
| `scripts/hetzner-mirror.sh` | mini | `init` `sync` `publish` `status` `authorize` `sshd` `tunnel`; internos: `serve` `hook` `pack-hook` `spec-out` |
| `scripts/hetzner-mirror-scan.py` | mini | varre o CONTEÚDO de cada (blob, caminho) que um commit novo introduz; regra = a de `hetzner-pii-scan.py` (≥20 telefones ou ≥3 CPFs), importada de lá |
| `scripts/hetzner-remote-git.sh` | servidor (`~/gt-remote/bin/`) | `bootstrap` `pull` `wt-add` `wt-rm` `status` `scan` |
| `packs/town-deltas/assets/hetzner-mirror-{sshd,tunnel,sync}.plist` | mini (launchd) | mantêm o sshd e o túnel de pé e rodam `sync` a cada 5 min |
| `scripts/hetzner-mirror.selftest.sh` | — | hermético, 227 casos, sshd real; `HMST_FAKE=1` troca o ssh por chamada direta (só para desenvolver) |
| `<cidade>/.gc/hetzner-mirror/` | mini | estado: `repos/<rig>.git`, `state/<rig>/{deny-extra,seen.tsv,scanned-tips}`, `authorized_keys`, `host_key`, logs |
| `~/gt-remote/{bin,git,keys}` | servidor | só estas três pastas são desta fatia; o resto de `~/gt-remote` é do ga-zri39b e das outras fatias |

## Como funciona

**Por que o filtro não é só por nome.** O filtro de rsync do nó de testes (`hetzner-rsync-filter.wa.txt`) é uma lista de PERMISSÃO: nome desconhecido não sai. Git não faz isso por extensão sem esconder os docs dos workers, então o espelho usa a Seção 1 (lista de NEGAÇÃO por nome) **mais** pastas que o rsync já trata como dado (`.beads/` `data/` `logs/`) **mais** os caminhos que a varredura de conteúdo sinalizou. MEDIDO no WA em 14/10 (varredura de todo o histórico, 38.030 blobs): 1.632 versões de blob têm ≥20 telefones ou ≥3 CPFs, em **65 caminhos**; a Seção 1 sozinha pegava **4** — os outros 61 (43 deles ainda no HEAD) teriam ido ao servidor: `data/tracked_contacts.json` (5.462 telefones), `data/conversation_history.db.backup-*` (3.473), `scripts/*_estado.json` (CPFs), `docs/auto_response/ab_results/*.json`, `.beads/backup/*`.

**O caminho do código ao servidor.** `sync` busca o origin, roda a varredura nos commits novos e só então grava (nesta ordem) o filtro novo e a marca de cobertura das pontas. O `upload-pack` do espelho só serve se (a) o pedido traz `--filter=sparse:oid=<filtro vigente>` e (b) a marca de cobertura bate com as pontas de agora; senão recusa. O servidor pergunta o filtro vigente por `gt-mirror-spec` (sai 75 enquanto a varredura não cobre as pontas) e busca com esse oid, nunca outro. O sshd não aceita variável de ambiente, então o git fala protocolo v0: **fetch por oid de um blob omitido é recusado** (`unadvertised object`), inclusive o lazy fetch do clone parcial.

**O caminho do trabalho ao origin.** O worker empurra `worker/<bead>` (ou `crew/`, e os prefixos do rig: `fix/` `feat/`) ao espelho. O `pre-receive` recusa `main`/`master`, tag, apagar, reescrever histórico, branch fora dos prefixos e commit que toque caminho de dado (as mesmas regras do filtro, inclusive os caminhos da varredura). O `post-receive` dispara `publish` em segundo plano; `publish` empurra ao origin **sem force**, pela URL (empurrar pelo remoto nomeado faria o git mexer em `refs/remotes/origin`, que a varredura precisa estável). Mini ou GitHub fora: o espelho guarda a branch, `status` mostra `PENDENTE` e o último erro, e o próximo `sync` publica.

**Worktree por bead.** `wt-add <rig> <bead> [base]` atualiza o clone (`pull`), cria `…/wt/<bead>` com a branch `worker/<bead>` e usa os mesmos padrões do filtro (sparse-checkout): o dado omitido não aparece na árvore. Grava em `~/gt-remote/git/worktrees.jsonl` uma linha com `main`, `main_age_min` (idade do commit do main), `lag_min` (idade da última varredura boa do espelho) e `pull` (`ok`|`erro`: se o espelho estava em atualização o worktree sai do que havia e **diz** que o pull falhou). `wt-rm` remove e informa o espaço liberado.

## Instalação

Pré-requisito: o servidor `hetzner-teste` acessível por ssh do mini (ga-zri39b). **Coordene com o dono do ga-zri39b antes**: só se criam `~/gt-remote/{bin,git,keys}`; não se mexe em sshd, firewall nem crontab do servidor.

Rode os comandos do **caminho mergeado** (`$GC_CITY_PATH/scripts/`); `init` e `authorize` recusam rodar de dentro de `.gc-worktrees` (o hook e o comando forçado carregam o caminho do script, e worktree some). Antes do merge, a prova usou uma cópia estável em `<cidade>/.gc/hetzner-mirror/bin/` (ver "Troca para o caminho mergeado").

```bash
export HETZNER_MIRROR_HOME=$GC_CITY_PATH/.gc/hetzner-mirror; B=$GC_CITY_PATH/scripts/hetzner-mirror.sh
# 1. espelhos (1ª leva: WA e HQ). --seed reaproveita os objetos do clone local (hardlink): o 1º fetch vira incremental
$B init whatsapp_automation https://github.com/athosmartins/whatsapp-automation.git --seed ~/gt/whatsapp_automation/.git --prefix fix/ --prefix feat/
$B init gascity             https://github.com/athosmartins/gastown.git            --seed ~/gt/.git                       --prefix fix/ --prefix feat/
# 2. 1º sync = varre o histórico INTEIRO (demora; ver MEDIDO). Rode em segundo plano; o servidor só é atendido depois
$B sync whatsapp_automation; $B sync gascity
# 3. servidor: pastas, chave própria (a privada NUNCA sai de lá), script
ssh hetzner-teste 'umask 077; mkdir -p ~/gt-remote/{bin,git,keys}; ssh-keygen -q -t ed25519 -N "" -C gt-mirror -f ~/gt-remote/keys/gt_mirror'
ssh hetzner-teste 'cat ~/gt-remote/keys/gt_mirror.pub' > $HETZNER_MIRROR_HOME/server-key.pub
scp -q $GC_CITY_PATH/scripts/hetzner-remote-git.sh hetzner-teste:gt-remote/bin/ && ssh hetzner-teste 'chmod 755 ~/gt-remote/bin/hetzner-remote-git.sh'
# 4. mini: autoriza a chave (UMA linha, restrict + from loopback + comando forçado), sobe o sshd só-chave e o túnel reverso
$B authorize $HETZNER_MIRROR_HOME/server-key.pub; $B sshd start; $B hostkey > $HETZNER_MIRROR_HOME/server-known_hosts
scp -q $HETZNER_MIRROR_HOME/server-known_hosts hetzner-teste:gt-remote/keys/gt_known_hosts; $B tunnel start hetzner-teste
# 5. servidor: um clone por rig (o filtro vem do espelho)
ssh hetzner-teste 'K=~/gt-remote/keys; R=~/gt-remote/bin/hetzner-remote-git.sh
  $R bootstrap whatsapp_automation ssh://athos@127.0.0.1:2293/whatsapp_automation.git $K/gt_mirror $K/gt_known_hosts fix/ feat/
  $R bootstrap gascity ssh://athos@127.0.0.1:2293/gascity.git $K/gt_mirror $K/gt_known_hosts fix/ feat/'
# 6. prova: varredura do servidor (zero dado, zero credencial do GitHub)
ssh hetzner-teste '~/gt-remote/bin/hetzner-remote-git.sh scan'
```

**Durável (launchd).** `start` de `sshd`/`tunnel` só guarda um pid; para sobreviver a reboot e a queda, carregue os três plists (o caminho do script está dentro deles):

```bash
for n in hetzner-mirror-sshd hetzner-mirror-tunnel hetzner-mirror-sync; do
  cp $GC_CITY_PATH/packs/town-deltas/assets/$n.plist ~/Library/LaunchAgents/com.gascity.$n.plist
  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gascity.$n.plist; done
```
Antes disso pare os de pid (`$B sshd stop; $B tunnel stop hetzner-teste`), senão a porta 2293 já está ocupada. O plist do `sync` repete a cada 300 s e o script tem trava por rig (outra rodada em curso é pulada, não empilhada); a 1ª rodada, longa, segura a trava e as seguintes dizem "outro sync em curso".

**Troca para o caminho mergeado.** Depois do merge: `B=$GC_CITY_PATH/scripts/hetzner-mirror.sh; $B init <rig> <url> [--prefix …]` (reescreve os hooks para o caminho novo; idempotente) e `$B authorize $HETZNER_MIRROR_HOME/server-key.pub` (troca o comando forçado da chave de "cópia estável" para "caminho mergeado"; diz `comando forçado atualizado`). Só então apague `<cidade>/.gc/hetzner-mirror/bin/`.

## Operação

`$B status` (rc 0 só com tudo em dia): por rig diz `pronto` (a varredura cobre as pontas atuais), idade do último fetch+varredura bons, quantos caminhos foram negados por conteúdo, o filtro (`igual` ou `DIFERENTE`), as branches `pendentes ao origin` e o último erro de fetch/publicação. No servidor: `hetzner-remote-git.sh status` (idade do origin que o clone tem, branches `publicada`/`PENDENTE`/`sem trabalho novo`).

| sintoma | causa provável | o que fazer |
|---|---|---|
| `pronto=NÃO` por mais de uns minutos | a varredura falhou ou o `sync` não rodou | `$B sync <rig>`; erro em `lastfetcherror`; log do launchd em `<cidade>/.gc/logs/hetzner-mirror-sync-launchd.err`. O servidor continua só com o que já baixou |
| `pull` do servidor: `em atualização` (rc 75) | normal durante um `sync` | esperar; `wt-add` cria o worktree do que havia e grava `"pull":"erro"` |
| `scan` do servidor: `VIOLAÇÃO historico=[…]` | o filtro mudou depois de o servidor baixar, ou algo foi plantado | refazer o clone num diretório novo (`bootstrap` com outro `GT_REMOTE_GIT`), não consertar à mão |
| `scan`: rc 2 | não consegui varrer (clone ilegível, lista de dados ausente) | nunca é "limpo": conserte e rode de novo |
| `publish` falha | GitHub fora, credencial do mini, branch protegida | `status` mostra a branch e o erro; nada se perde, o próximo `sync` tenta de novo |
| `sync` diz `caminho sinalizado que o filtro não consegue negar` | arquivo com lista de telefone/CPF cujo nome tem quebra de linha ou espaço no fim | o espelho para de servir (de propósito); renomeie/remova o arquivo no origin ou trate com o Mayor |
| `serve.log` com recusas | alguém tentou outro comando com a chave | `<cidade>/.gc/hetzner-mirror/serve.log`; a chave pode ser revogada apagando a linha de `authorized_keys` |

## O que foi MEDIDO

Tudo abaixo foi rodado de verdade em 14/10 (mini com load 105–120, servidor `hetzner-teste`, RTT ~200 ms, mirror/túnel/sshd reais). Onde diz "hermético" foi o selftest, não produção.

**Tempo e tamanho (WA = 946 branches no origin; HQ = 1.673)**

| o quê | WA | HQ |
|---|---|---|
| 1º `sync` (fetch incremental pelo seed + varredura de TODO o histórico) | 268 s · 35.667 pares blob/caminho · 1.237 versões sinalizadas · **64 caminhos negados por conteúdo** | 232 s · 26.238 pares · **0 sinalizados** |
| `bootstrap` no servidor (clone parcial pelo túnel) | 178 s | 124 s |
| clone no servidor | 129 MB (pack 123 MiB; no mini o pack do seed tem 433 MiB) | 64 MB |
| `sync` incremental sem commit novo | 11 s (os dois rigs em sequência ≈ 22 s; `StartInterval` 300 s tem folga) | — |
| `wt-add` (inclui o `pull`) | 7 s · 7.691 arquivos rastreados, 7.624 na árvore (67 omitidos pelo filtro), 153 MB | — |
| `wt-rm` | libera 156.044 KB | — |
| commit descartável do servidor → espelho → origin | `git push` do servidor 15 s (3 s de ssh novo + hooks); a branch apareceu no GitHub ~5 s depois; **27 s do `wt-add` até o origin**, sem ação humana | — |

**A prova de entrega.** Branch `worker/hetzner-mirror-proof-20261014` (commit vazio) empurrada do servidor, publicada pelo `post-receive`, vista com `git ls-remote origin`, depois apagada do origin, do espelho e do servidor. O registro de `worktrees.jsonl` dela: `{"main":"297744f","main_age_min":113,"lag_min":9,"pull":"ok"}` — a idade do `main` usado e o atraso do clone em relação ao origin ficam gravados a cada worktree novo.

**O que o servidor tem e não tem (live, `hetzner-remote-git.sh scan`).** `limpo` nos dois clones: WA 33.469 blobs presentes, HQ 23.547; zero blob cujo caminho seja só de dado; remotos = só o espelho; nenhum `.git-credentials`/`.netrc`/`gh`/token/chave ssh do GitHub no host. `lib/action_log.py` (código) está lá; `tests/test_phone_etl.py` (sinalizado por conteúdo) dá `Server does not allow request for unadvertised object` — o blob nunca chega, nem por lazy fetch.

**O sshd do espelho (live, do servidor).** Pelo túnel: shell → recusado com mensagem, comando qualquer → recusado, `gt-mirror-spec` antes da varredura → rc 75, métodos oferecidos = só `publickey`. O túnel abre **uma** porta em `127.0.0.1` do servidor (2293), nada mais.

**O que filtrar só por nome deixaria passar.** Varredura de conteúdo de todo o histórico do WA: 65 caminhos com ≥20 telefones/≥3 CPFs; a Seção 1 do filtro de rsync pega 4. Os 61 restantes incluem `data/tracked_contacts.json` (5.462 telefones), `data/conversation_history.db.backup-20260205-*` (3.473), 14 `docs/auto_response/ab_results/*.json`, `scripts/campanhas_aprovar_enriquecer_estado.json` (CPFs) e `.beads/backup/*`. É por isso que o espelho varre conteúdo.

**O custo disso: 21 arquivos de CÓDIGO do WA não chegam ao servidor** (a varredura os sinaliza por terem telefone/CPF dentro): 18 testes (`tests/test_phone_etl.py`, `test_ficha360_data.py`, `test_getzip_pipeline.py`, `test_obito_demandas.py`, `test_genealogy_tree.py`, …), `daemons/clientes_seed.py`, `scripts/draft_comparison_server.py`, `scripts/generate_draft_experiments.py`. Os dois scripts são os mesmos que o cabeçalho do filtro de rsync cita. A lista exata está em `<cidade>/.gc/hetzner-mirror/state/whatsapp_automation/deny-extra`. Um worker no servidor que importe esses módulos vai falhar; a saída é trocar os números reais por sintéticos nas fixtures (a régua ignora número cujos 8 últimos dígitos têm ≤3 algarismos diferentes) — trabalho do WA, não desta fatia.

**Selftest hermético (227 casos, 0 falhas, sshd real).** Cobre (cada pull também grava `pulls.jsonl` com `lag_min`): filtro (6 formas de filtro ruim ⇒ recusa), varredura (renomear não escapa, curinga no nome, quebra de linha ⇒ recusa sem avançar a cobertura, oids inteiros), `serve` (21 comandos recusados, nenhuma injeção executa), authorize (RSA, opções, duas chaves, comentário ⇒ recusa; troca de caminho), sshd (shell, comando, `-W`, senha), clone sem filtro / filtro `blob:none` / filtro mais fraco que o vigente ⇒ recusados, fetch por oid do blob de dado ⇒ `unadvertised`, janela entre fetch e varredura ⇒ o servidor não baixa, push de main/tag/apagar/reescrever/prefixo/`.csv`/pasta/`.beads/`/caminho da varredura ⇒ recusados no `pre-receive`, nome parecido com segredo mas código ⇒ passa, origin fora ⇒ branch pendente e visível ⇒ chega quando volta, publicar não derruba a cobertura.

**Os testes mordem (mutação).** Cinco cópias do código, cada uma com UMA guarda quebrada, rodadas no selftest: `upload-pack` sem checar a cobertura ⇒ 5 testes falham; varredura sem limiar ⇒ 18; `pre-receive` sem recusar dado ⇒ 14; `upload-pack` aceitando qualquer filtro ⇒ 3; `scan` do servidor sem `--no-abbrev` ⇒ 6. Dois bugs reais apareceram só porque os testes foram escritos para falhar: `git log --raw` ABREVIA o oid (a chave do `seen.tsv` e o cruzamento de presença estavam errados) e o `nohup` do macOS falha sem tty (o `post-receive` nunca publicava sob o sshd).

## O que foi INFERIDO

• Que o sshd principal do mini oferece senha (`publickey,password,keyboard-interactive`, medido com `ssh -o PreferredAuthentications=none -v`) é o motivo do sshd próprio; que um túnel até a porta 22 do mini exporia a senha do usuário a um servidor alugado é inferência de risco, não ataque testado.
• Que o `sparse:oid` com o filtro vindo do espelho vale para qualquer rig futuro: só foi exercido em WA e HQ.

## O que NÃO foi testado

• **Os plists carregados no launchd e sobrevivendo a reboot.** Foram só `plutil -lint`: o caminho do script dentro deles é o mergeado, que ainda não existe. Hoje o sshd e o túnel rodam como processos de pid (`start`) e o `sync` só roda quando alguém chama. **Enquanto os plists não forem carregados, o clone do servidor envelhece e uma branch empurrada pelo servidor só chega ao origin se o `post-receive` conseguir publicar na hora.** Isso é a bead de ativação pós-merge.
• **Origin/GitHub fora na produção.** Só no selftest. Em produção não derrubei o origin do WA de propósito.
• **A recuperação do túnel depois de queda** (`KeepAlive` + `ThrottleInterval 30` do plist; `ServerAliveInterval 15` no ssh) — nunca derrubei o túnel.
• **Branch empurrada para o `gascity` (HQ).** A prova de entrega foi só no WA (repo privado); o origin do HQ é o gastown público e não quis criar branch lá. O clone e o `scan` do HQ foram rodados.
• **`property_scrapers`, `lexbh`, `marketing`:** nenhum espelho criado (1ª leva é WA e HQ). `data/` e `logs/` entram como pasta negada para QUALQUER rig; um rig com código em `data/` precisaria de exceção.
• **Blob maior que 50 MB** (vale como sinalizado) e **`sync` concorrente com um push do servidor** em produção: só no selftest, em escala de brinquedo.
• **`authorize` com `authorized_keys` ilegível:** o ramo existe (recusa em vez de gravar uma linha só), mas o próprio `authorize` faz `chmod 600` antes de ler, então o selftest não consegue provocá-lo; não tem teste.
• **Sessão real do claude no servidor:** nenhuma (fatia 6). Também não medi se um worker acha ruim faltarem os 21 arquivos.

## Limites e resíduos (leia antes de confiar)

• **A varredura de conteúdo é heurística de forma**: telefone BR e CPF, ≥20 / ≥3 distintos. Não vê nome, e-mail, CNPJ, endereço nem lista pequena. Um arquivo de dado de nome neutro e pouco conteúdo passa. O mesmo resíduo vale para o filtro de rsync.
• **Os NOMES dos arquivos omitidos aparecem nas árvores** do clone (o git não filtra árvores); o conteúdo não. `.gitignore`-style por nome também tem falso positivo (ex. `*.db-*` pega `com.whatsapp.db-sync.plist`; `*token*.toml` pega `token-ledger-harvest.toml` no HQ).
• **Mudar o filtro ou a varredura não remove o que o servidor JÁ baixou.** Um caminho que ganha sinalização depois (versão nova com lista, versões antigas pequenas já baixadas) fica no clone até alguém refazê-lo; `scan` acusa por nome.
• **Merge**: dado que chegue ao servidor só por um commit de merge o `pre-receive` não vê (olha os commits comuns); na ida (mirror→servidor) a varredura vê todo par (blob, caminho) de merge (`-m`).
• **Mini fora = o push espera.** Consequência aceita no desenho. O servidor continua lendo o que o espelho já tem.
• O túnel reverso e o sshd do espelho dependem de o mini estar de pé e do launchd carregado; sem os plists, `start` não sobrevive a reboot.

## Como desfazer

`$B tunnel stop hetzner-teste; $B sshd stop`; `launchctl bootout gui/$(id -u)/com.gascity.hetzner-mirror-{sshd,tunnel,sync}` e apagar os três plists de `~/Library/LaunchAgents`; apagar a linha de `<cidade>/.gc/hetzner-mirror/authorized_keys` revoga a chave. No servidor: `rm -r ~/gt-remote/git ~/gt-remote/keys ~/gt-remote/bin/hetzner-remote-git.sh` (só as peças desta fatia). Os espelhos em `<cidade>/.gc/hetzner-mirror/repos/` são derivados do origin: podem ser recriados com `init`.
