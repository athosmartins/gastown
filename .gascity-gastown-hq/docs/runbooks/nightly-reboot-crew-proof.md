## Contents
- O que é
- Instalar (passo do Mayor), conferir e desligar
- Ler o resultado
- Fora desta entrega

## O que é
Missão ga-esorlre.12, camada 3 (ga-esorlre.15). Às 00:10, depois do reboot das 23:40, prova que cada crew nomeada que tinha bead em andamento no boot fez um **commit** no clone dela ou **comentou** numa dessas beads (autor = a crew; `automation`, `order:…`, Mayor e Pilot não valem). Sem prova, ou sem conseguir olhar, o celular do Athos vibra (push `-p 4` forçado; às 00:10 o silêncio do `notify` o segura até 07:00) e o **Mayor recebe um mail** (`gc mail send mayor`, mesma lista; chega como `human` e a linha `[origem: nightly-reboot-crew-proof.py]` no fim diz de onde veio): o canal imediato da madrugada (ga-esorlre.16). Camadas 1-2 (ga-esorlre.13/.14) evitam a crew parada; esta **mede o resultado** e não depende de nada de que as crews dependem. Contrato completo (janela, prazo, estados, `notify`): cabeçalho de `scripts/nightly-reboot-crew-proof.py`.

## Instalar (passo do Mayor), conferir e desligar
Mergeado não é vivo: até carregar o plist o `daemon-presence-watchdog` acusa PRESENCE-DRIFT, de propósito.
1. A seco, a qualquer hora (não espera o prazo, não envia nem grava nada): `/usr/bin/python3 -I $GC_CITY_PATH/scripts/nightly-reboot-crew-proof.py --dry-run`.
2. `cp $GC_CITY_PATH/scripts/com.gascity.nightly-reboot-crew-proof.plist ~/Library/LaunchAgents/` e `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gascity.nightly-reboot-crew-proof.plist` (usuário, sem sudo).
3. Desligar sem tirar o plist (o PRESENCE-DRIFT não acusa): `touch $GC_CITY_PATH/.gc/nightly-reboot-crew-proof.off`.

## Ler o resultado
Linhas `crew-proof:` em `.gc/logs/nightly-reboot.log` (o mesmo do postcheck): por crew `OK: commit|comentário em <bead>`, `FALTA` (leu tudo e não há prova) ou `NAO-SEI` (alguma leitura falhou); depois `RESULT:`. Boa noite = só uma linha de rotina no resumo do celular ("crews retomaram", com as crews sem bead que não foram cobradas; sem mail): a falta dela, sem alarme, é o plist não carregado. `WARN: notify push p4 falhou (rc=10)` seguido de `gc mail send mayor: enviado` = o push ficou segurado até 07:00 e o Mayor foi avisado na hora (o normal às 00:10). `ALERTA NÃO ENTREGUE` no log/stderr = nem o push (2 tentativas) nem o mail ao Mayor (3) saíram. **Aceite da missão**: no próximo reboot, peter-wa e oracle-wa com bead em andamento aparecem como `OK` antes de 00:10.

## Fora desta entrega
O **Mayor** não é crew nomeada (a ponte dele é a rodada das 00:03); crew sem bead em andamento no boot (nada a retomar); bead que a crew pegou depois do boot; bead de uma crew no store de outro rig (só o do rig dela e o do HQ são lidos).
