# Hetzner: vigia do IP público do mini contra o firewall da nuvem · runbook

## Contents
• O que é · O que acontece quando o IP troca · Instalar (Mayor, depois do merge) · Quando o aviso chega · Estados e avisos · Provar · Medido, inferido, não testado

Bead ga-1h1b7vq. O firewall da nuvem `so-ssh-do-mini` (projeto teste-urblink, id 11795835) libera ENTRADA só para o IP público do mini (`179.197.107.78` em 17/11). Internet residencial costuma ter IP dinâmico: se o provedor trocar o IP, o túnel, o espelho git, os dogs remotos e os revisores remotos param todos ao mesmo tempo, e o sintoma parece "o nó caiu". `scripts/hetzner-fw-ip-watch.py` lê o IP a cada 10 min e avisa o Mayor quando ele deixa de ser o liberado.

## O que é

Uma rodada = duas leituras (`curl -4` a `api.ipify.org` e a `ifconfig.me/ip`) comparadas com o IP liberado, gravado em `.gc/hetzner-fw-ip.state.json`. Só lê e avisa; **não muda o firewall** (não existe o item `hcloud` no cofre, ver "Não feito" abaixo). Exit 0 sempre que a rodada fechou (inclui "não sei" e "outra instância rodando"), 1 crash, 3 não gravou.

## O que acontece quando o IP troca

Cada leitura tem três estados e "não consegui" nunca vira "mudou" nem "igual":

| leitura | estado | efeito |
|---|---|---|
| as 2 fontes dão o mesmo IPv4 público = liberado | `igual` | zera o episódio; nada a avisar |
| as 2 fontes dão o mesmo IPv4 público ≠ liberado | `diferente` | mail ao Mayor na hora; repete a cada 3 h enquanto durar; IP novo avisa na hora |
| uma fonte falha/trava, resposta que não é IP, IP privado/loopback/IPv6, ou as fontes discordam | `nao-sei` | não toca no IP visto, não avisa troca; conta a falha |
| 3 `nao-sei` seguidos (30 min) | cego | 1 mail "vigia cego" (cooldown 6 h); uma leitura boa zera a contagem |

O mail que falha não gasta o cooldown: a rodada seguinte tenta de novo.

## Instalar (Mayor, depois do merge)

Mergeado ≠ vivo: sem o plist carregado o vigia não roda. Os passos abaixo não foram feitos pela bead (o plist vive em `~/Library/LaunchAgents`, fora do repo):

```bash
cp "$GC_CITY_PATH/scripts/com.gascity.hetzner-fw-ip-watch.plist" ~/Library/LaunchAgents/
launchctl bootout gui/$(id -u)/com.gascity.hetzner-fw-ip-watch 2>/dev/null
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gascity.hetzner-fw-ip-watch.plist
launchctl print gui/$(id -u)/com.gascity.hetzner-fw-ip-watch | grep -E 'state|runs|last exit'
python3 "$GC_CITY_PATH/scripts/hetzner-fw-ip-watch.py" --dry-run   # 1ª rodada à mão: não grava nem manda mail
```

Registrar o batimento na mesma mudança (senão o job morre sem ninguém ver): em `scripts/daemon-presence-watchdog.sh`, a linha `com.gascity.hetzner-fw-ip-watch|$HQ/.gc/logs/hetzner-fw-ip-watch.out|1800` no mapa de batimento (3 ciclos de 600 s; o `.out` ganha UMA linha por rodada que fecha; lock ocupado e erro vão só para o `.err`) e, se quiser que a falta dele acenda CRITICAL, o nome em `DPW_CRITICAL`. A linha `isento` em `scripts/wait-for-dolt.policy.tsv` já vem neste commit; até o plist ser carregado, `wait-for-dolt-plan.py` lista `política cita job sem plist RunAtLoad vivo: com.gascity.hetzner-fw-ip-watch` entre as divergências (medido 17/11: 8 divergências, 7 já existiam sem esta linha) e a divergência some na instalação. Desligar: `launchctl bootout gui/$(id -u)/com.gascity.hetzner-fw-ip-watch`.

## Quando o aviso chega

1. Entrar em https://console.hetzner.cloud (login no item `hetzner` do cofre: `secret hetzner`).
2. Projeto teste-urblink → Firewalls → `so-ssh-do-mini` → regra de entrada: trocar o IP antigo por `<IP novo>/32` → Aplicar.
3. Provar com uma conexão NOVA: `ssh hetzner-teste true`.
4. `python3 "$GC_CITY_PATH/scripts/hetzner-fw-ip-watch.py" --ack` grava o IP atual (as 2 fontes têm de concordar; ou `--ack <IP>`) como liberado e encerra o episódio. Sem o `--ack` o vigia segue achando que o IP é "diferente" e repete o aviso a cada 3 h.

`--ack` recusa IP que não é IPv4 público e não adivinha: sem leitura e sem IP no argumento, sai com rc 3 e não grava nada.

## Estados e avisos

Configuração por ambiente (no plist): `HETZNER_FW_IP_ALLOWED` (semente do IP liberado, só vale na 1ª rodada ou com o estado corrompido; depois manda o `--ack`) · `HETZNER_FW_IP_SOURCES` (≥ 2 URLs) · `HETZNER_FW_IP_BLIND_AFTER` (3) · `HETZNER_FW_IP_COOLDOWN_S` (10800) · `HETZNER_FW_IP_BLIND_COOLDOWN_S` (21600) · `HETZNER_FW_IP_CURL_TIMEOUT_S` (10) · `HETZNER_FW_IP_ALARM=0` (só mede). Estado corrompido: a cópia fica em `<arquivo>.corrupt-<epoch>` e o vigia recomeça da semente (caso comum: um aviso a mais; se o IP voltar justo ao da semente com o firewall em outro, ele lê "igual" até o próximo `--ack`). O vigia não consulta o firewall: "liberado" é a semente ou o último `--ack`.

## Provar

```bash
bash scripts/hetzner-fw-ip-watch.selftest.sh          # suíte + controle negativo (12 mutantes)
HFW_NO_MUTANTS=1 bash scripts/hetzner-fw-ip-watch.selftest.sh
```

Hermético: `curl` e `gc` são stubs. Cobre igual, diferente (mail, cooldown e a borda dele, IP novo, mail que falha), não-sei (fonte cai, discorda, não é IP, privado, loopback, IPv6, vazio, enorme, trava), cegueira, episódio, `--ack`, `--dry-run`, estado corrompido, instância única, aviso desligado, configuração inválida e o plist.

## Medido, inferido, não testado

**Medido (17/11):** o item `hetzner` existe no cofre e o `hcloud` não (`secret hcloud` sai com rc 4); o selftest acima.
**Inferido:** o IP `179.197.107.78` e o firewall 11795835 vêm do texto da bead, não de uma leitura do console; `curl -4` às duas fontes sob o launchd usa o `PATH` do plist.
**NÃO testado:** uma rodada pelo launchd de verdade (só depois da instalação), um `gc mail send mayor` real a partir do vigia (o selftest usa um stub), as duas fontes reais (o selftest não fala com a rede).
**Não feito:** a atualização da regra pela API da Hetzner (`PUT /v1/firewalls/11795835/actions/set_rules`), opcional na bead, só existe se houver o item `hcloud` no cofre; hoje não há. Com o token isto vira uma fatia própria, com chave `.on` e prova de que o ssh volta (o firewall da nuvem não tem desfazer automático, ver `hetzner-ssh-lockdown.md`).
