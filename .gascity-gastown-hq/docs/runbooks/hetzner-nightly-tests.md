# Bateria noturna do WhatsApp no nó Hetzner (ga-9p6pte)

## Contents

• O que roda e quando · **Instalação (precisa de root, uma vez)** · Veredito e relatório · Limites honestos · Operação (desligar, rodar à mão, conferir)

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
| INERTE | isolamento não provado (helper não instalado, canário inerte/não-isolado): **nada rodou** | 0 |
| FALHOU | nó fora, sync recusado, passou de 2 h, pytest abortado, resumo ilegível/total implausível, ou rodou sem a linha de prova | 1 |
| PULADO | bandeira do nó desligada ou outra rodada em andamento | 0 |

"Novas falhas" = as que não estavam na última noite **COMPLETO** (INERTE/FALHOU não avançam a referência). Primeira noite: "primeira rodada", sem comparação.

## Limites honestos
- O helper de root **nunca rodou num kernel real**: o selftest usa stubs. A prova de que ele isola é o canário no nó, depois da instalação. Os critérios "zero conexões de saída" e "1ª rodada completa registrada" só se confirmam na primeira noite COMPLETO.
- A suíte tem ~18 erros de coleta de base (`--continue-on-collection-errors`) e falhas que só existem no macOS (launchd etc.). A linha de base já os inclui; o sinal útil é "novas vs a noite anterior", não o total absoluto.
- Sem o helper instalado, o e-mail INERTE chega toda noite; para calar, desligue o order ou a bandeira do nó (abaixo).
- Prazo 2 h e 14 workers são alvo, não medida: a duração real vem da primeira rodada. O `WA_PYTEST_MAX_WORKERS=14` é necessário porque o conftest do WA limita a 2 workers por padrão.
- Determinismo da coleta (xdist aborta com "Different tests were collected" se os workers discordam): ids com horário/época e a ordem de parâmetros por hashseed causavam isso. O plugin `scripts/gtn_stable_ids.py` normaliza os ids e `PYTHONHASHSEED=0` fixa a ordem: duas coletas completas (68.479 testes) deram diff vazio. Não provado: a comparação entre workers numa rodada real.

## Operação
```bash
gc order show hetzner-nightly-tests                       # Source tem de ser .../packs/town-deltas/orders/...
tail -3 $CITY/.gc/logs/hetzner-nightly.jsonl              # um veredito por noite
gc order run hetzner-nightly-tests                        # rodar agora (precisa do helper instalado, senão INERTE)
# desligar: acrescente "hetzner-nightly-tests" à lista `skip` de `[orders]` no city.toml (ou apague a bandeira $CITY/.gc/hetzner-node.on: a noite vira PULADO, sem e-mail)
bash scripts/hetzner-nightly-tests.selftest.sh && bash scripts/hetzner-iso-run.selftest.sh && bash scripts/hetzner-netns-run.selftest.sh
```
Referências: `docs/runbooks/mbp-offload.md` (seção do nó Linux, filtro de dados, `node_guard`), `scripts/hetzner-netns-run.sh` (o que o comando enxerga dentro do netns).
