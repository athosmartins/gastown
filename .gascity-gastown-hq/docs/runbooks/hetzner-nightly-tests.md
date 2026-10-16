# Bateria noturna do WhatsApp no nó Hetzner (ga-9p6pte)

## Contents

• O que roda e quando · **Instalação (precisa de root, uma vez)** · Veredito e relatório · Ids reprovados e a comparação · Vazamento medido · Limites honestos · Operação (desligar, rodar à mão, conferir)

## O que roda e quando
Todo dia às 02:00 local (`0 5 * * *`: o cron dos orders é em UTC) o order `hetzner-nightly-tests` (`packs/town-deltas/orders/`) chama `scripts/hetzner-nightly-tests.sh`:
`git archive origin/main` do WA → scratch → `mbp-run.sh --host linux` com `HETZNER_ISOLATE=1` (mesmo filtro de dados, `node_guard`, slot e supervisão do gate) → `pytest tests/ -n 14` **dentro do netns sem rede** → relatório ao Mayor.
Só roda no nó (`hetzner-teste`, aarch64, 16 núcleos): nunca cai no MBP nem no mini.

Por que o isolamento é obrigatório: em 04/10 um teste de branch antiga mandou um e-mail de verdade. O `runner` não tem root, o AppArmor barra userns sem privilégio e `systemd-run --user -p PrivateNetwork=yes` volta rc 0 **sem isolar** (medido). Só root consegue cortar a saída; por isso existe o helper abaixo.

## Instalação (precisa de root, uma vez)
Sem isto a bateria **não roda** (veredito INERTE toda noite). Como root no nó, com o repo em `$WA`:
```bash
install -m 0755 -o root -g root $WA/.gascity-gastown-hq/scripts/hetzner-netns-run.sh /usr/local/sbin/gt-netns-run
echo 'runner ALL=(root) NOPASSWD: /usr/local/sbin/gt-netns-run' > /etc/sudoers.d/gt-netns-run
chmod 0440 /etc/sudoers.d/gt-netns-run && visudo -cf /etc/sudoers.d/gt-netns-run
```
Prova (do mini; o `gt-iso-run` chega ao nó na primeira rodada do order, `gc order run hetzner-nightly-tests`, que sem o helper termina INERTE):
```bash
ssh hetzner-teste '~/gt-remote/bin/gt-iso-run --canary'     # tem de imprimir: GTN-ISO: isolado (sonda barrou N tentativas)
```
O canário só diz `isolado` se a sonda (TCP 1.1.1.1:53, 8.8.8.8:443, 9.9.9.9:443, UDP/DNS, interfaces além de `lo`/`gtn0`, variável com cara de segredo) não achou saída **e** o contador do nft é ≥ 1 (contador zerado = a regra não está no caminho = inerte). A evidência é o contador, não log: fora do netns inicial o kernel não loga.

## Veredito e relatório
Uma linha por noite em `$CITY/.gc/logs/hetzner-nightly.jsonl`; relatório completo em `$CITY/.gc/logs/hetzner-nightly/<dia>.md` (guardado 14 dias); e-mail ao Mayor, salvo PULADO.

| Veredito | Significa | Exit |
|---|---|---|
| COMPLETO | rodou isolado; total, falhas, **novas falhas** e duração lidos do resumo do pytest | 0 (teste que falha é dado, não falha do job) |
| INERTE | isolamento não provado (helper não instalado, canário `inerte`): **nada rodou** | 0 |
| FALHOU | nó fora, sync recusado, passou de 2 h, pytest abortado, resumo ilegível/total implausível, rodou sem a linha de prova, ou **vazamento medido** (canário `nao-isolado`, ver abaixo) | 1 |
| PULADO | bandeira do nó desligada ou outra rodada em andamento (a noite PULADA deixa a linha no jsonl, sem e-mail) | 0 |

"Novas falhas" = as que não estavam na última noite **COMPLETO** (INERTE/FALHOU não avançam a referência). Primeira noite: "primeira rodada", sem comparação.
O relatório também diz o que foi instalado no nó (`gt-iso-run` e `gtn_stable_ids.py`, com sha256 e se estão commitados: eles vão da árvore de trabalho, então uma edição não commitada iria junto, e aparece como `NÃO COMMITADO`) e, quando o `git fetch` falhou, que a árvore testada pode estar desatualizada. O jsonl traz `fetch` (`ok`/`falhou`/`pulado`) e `compare` (`ok`/`indisponivel`).

## Ids reprovados e a comparação
Os ids que falharam vêm do **plugin** `scripts/gtn_stable_ids.py`, que os imprime no fim da sessão (só no controlador do xdist): uma linha `GTN-FAIL: <id em JSON>` por id e `GTN-FAILED: n=<ids> reports=<falhas+erros>`. Não vêm da linha `FAILED <id> - <mensagem>` do resumo: o id de um parametrize pode ter ` - ` dentro (`[ADE V - Setor 4]`) e cortar no primeiro ` - ` juntava irmãos numa linha só, sem nenhum sinal. (Reproduzido com o pytest 9 + xdist de verdade. Varredura estática do revisor do gate nos testes do WA: 24 pontos de parametrize com ` - `, 5 deles com irmãos que colidiriam.)
O script confere o que leu: o número de linhas `GTN-FAIL` tem de ser `n`, `reports` tem de ser as falhas + erros do resumo do pytest, a linha `GTN-FAILED` tem de aparecer **uma** vez e toda `GTN-FAIL` tem de ser JSON. Qualquer divergência, ou a ausência da linha, vira **comparação INDISPONÍVEL**: o relatório diz o porquê, a linha de base **não anda** e nunca sai "0 novas". "Zero falhas" só vale com `n=0 reports=0` e o resumo também dizendo zero.
A linha de base é `$CITY/.gc/logs/hetzner-nightly/last-complete.failed` (um id em JSON por linha, `jq -r . last-complete.failed` para ler) com `last-complete.meta`; a limpeza de 14 dias **não** apaga esses dois. Uma linha de base em outro formato dá "comparação indisponível" (e é substituída pela de hoje, se a de hoje for confiável).

## Vazamento medido
`GTN-ISO: nao-isolado ...` no canário = a sonda **saiu** pela rede (ou achou interface/segredo). Não é "falta instalar o helper" (isso é `inerte`): o isolamento existe e **não segura**. A noite termina FALHOU, exit 1, assunto "VAZAMENTO MEDIDO", e a suíte não rodou. Antes de reativar: rode `ssh hetzner-teste '~/gt-remote/bin/gt-iso-run --canary'` à mão e leia o que a sonda achou na linha `GTN-ISO: nao-isolado ...`: `tcp:<ip>:<porta>` ou `udp:<ip>:<porta>` (conectou), `dns` (resolveu nome), `if:<interfaces>` (há interface além de `lo`/`gtn0`) ou `env:<variáveis>` (variável com cara de segredo). Confira também se o `/usr/local/sbin/gt-netns-run` instalado é o do repo (`diff` com `scripts/hetzner-netns-run.sh`). Não reative a bateria antes de entender o que vazou.

## Limites honestos
- **"Sem rede" é um network namespace, só isso.** Soquetes unix do sistema de arquivos (spool de um MTA local, D-Bus, `docker.sock`) não são cobertos nem pelo netns nem pela sonda do canário: um teste que escreva num deles ainda alcança o serviço do nó que o expõe. Não conferi quais desses existem no nó; o canário não tem sonda para eles.
- O helper de root **nunca rodou num kernel real**: o selftest usa stubs. A prova de que ele isola é o canário no nó, depois da instalação. Os critérios "zero conexões de saída" e "1ª rodada completa registrada" só se confirmam na primeira noite COMPLETO.
- A suíte tem ~18 erros de coleta de base (`--continue-on-collection-errors`) e falhas que só existem no macOS (launchd etc.). A linha de base já os inclui; o sinal útil é "novas vs a noite anterior", não o total absoluto.
- Sem o helper instalado, o e-mail INERTE chega toda noite; para calar, desligue o order ou a bandeira do nó (abaixo).
- O lock da rodada (`$CITY/.gc/hetzner-nightly.lock`) vale enquanto o pid está vivo **e** o lock tem menos que prazo + 30 min; mais velho que isso é um pid reaproveitado depois de uma queda e é tomado (com aviso no log). Um dono legítimo morre pelo prazo de 2 h, então não confunde com rodada em andamento.
- Não há piso relativo ao total da última noite COMPLETA: o piso é fixo (`HZN_MIN_TOTAL`, 1000), muito abaixo dos ~68 mil testes esperados; uma rodada que execute só uma fração da suíte e passe do piso ainda é COMPLETO. O sinal para isso é o total no relatório.
- Prazo 2 h e 14 workers são alvo, não medida: a duração real vem da primeira rodada. O `WA_PYTEST_MAX_WORKERS=14` é necessário porque o conftest do WA limita a 2 workers por padrão.
- Determinismo da coleta (xdist aborta com "Different tests were collected" se os workers discordam): ids com horário/época e a ordem de parâmetros por hashseed causavam isso. O plugin `scripts/gtn_stable_ids.py` normaliza os ids (e imprime os ids reprovados, seção acima) e `PYTHONHASHSEED=0` fixa a ordem: duas coletas completas (68.479 testes) deram diff vazio. Não provado: a comparação entre workers numa rodada real.

## Operação
```bash
gc order show hetzner-nightly-tests                       # Source tem de ser .../packs/town-deltas/orders/...
tail -3 $CITY/.gc/logs/hetzner-nightly.jsonl              # um veredito por noite
gc order run hetzner-nightly-tests                        # rodar agora (precisa do helper instalado, senão INERTE)
# desligar: acrescente "hetzner-nightly-tests" à lista `skip` de `[orders]` no city.toml (ou apague a bandeira $CITY/.gc/hetzner-node.on: a noite vira PULADO, sem e-mail)
bash scripts/hetzner-nightly-tests.selftest.sh && bash scripts/hetzner-iso-run.selftest.sh && bash scripts/hetzner-netns-run.selftest.sh
# o único que roda o pytest + xdist DE VERDADE (precisa de um python com os dois: GTN_PYTHON; sem ele sai 3, "NÃO RODOU", nunca 0):
bash scripts/gtn_stable_ids.selftest.sh
```
Referências: `docs/runbooks/mbp-offload.md` (seção do nó Linux, filtro de dados, `node_guard`), `scripts/hetzner-netns-run.sh` (o que o comando enxerga dentro do netns).
