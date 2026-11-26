# Mini 64: go/no-go da noite do corte (`go-nogo.sh`) · runbook

## Contents

• Estado em uma linha · Como rodar · O que fazer em cada veredito (GO · NO-GO · INCERTO) · O horário-limite 04:30
• Cada checagem · Arquivos de dados · Ensaio no mini atual · Medido, inferido, não testado · Limites conhecidos

Bead ga-ke5w2ie.3, fatia 3 do épico ga-ke5w2ie (migração da cidade para o Mac mini M5 Pro 64 GB / 1 TB). A execução real da noite D0 é do Mayor; esta fatia entrega só o comando que diz SIM ou NÃO, o teste dele e este texto.

## Estado em uma linha

`scripts/mini64/go-nogo.sh` está pronto e testado com comandos de mentira (bash 5 e um GNU bash 3.2.57 compilado a partir do fonte), **mas nunca rodou no mini de verdade** (o nó que o escreveu não tem Dolt, launchd, adb nem cloudflared) e **faltam dois dados antes da noite**: os 8 seriais em `scripts/mini64/celulares.tsv` (vazio de propósito: sem eles a linha `adb` fica INCERTO e o veredito nunca chega a GO) e a conferência dos painéis de `scripts/mini64/paineis.tsv` (ver "Arquivos de dados").

## Como rodar

```bash
cd ~/gt/.gascity-gastown-hq
bash scripts/mini64/go-nogo.sh                       # antes de liberar os envios do WhatsApp (espera LIGADA, o padrão)
bash scripts/mini64/go-nogo.sh --espera desligada    # depois do go: marcador removido e o envio rodando
echo $?                                              # 0 GO · 1 NO-GO · 2 INCERTO · 64 uso errado
```

A saída é uma linha por checagem e, na última, o veredito (o cabeçalho e a linha `PRAZO` vêm antes):

```
[OK]      dolt-porta               porta viva 52756 (lida do processo dolt, nunca de arquivo)
[NO-GO]   painel-map-viewer        HTTP 500 em http://127.0.0.1:8099/ (aceito: 200 401 403)
[INCERTO] adb                      lista vazia: nenhum serial em scripts/mini64/celulares.tsv (...)
VEREDITO: NO-GO — 1 falha(s), 1 incerto(s), 18 ok
```

O script **só lê**: não carrega, não para, não grava e não envia nada. A única coisa que ele pode provocar é o `adb devices` subir o servidor do adb, se ele ainda não estiver de pé. Cada checagem tem prazo de no máximo 20 s (`GONOGO_TIMEOUT` só pode baixar esse teto) e o script termina sozinho mesmo com tudo pendurado.

## O que fazer em cada veredito

**GO (exit 0).** Todas as checagens deram OK e nenhuma ficou sem resposta. Siga a fatia .6 (WhatsApp no ar até 07:00). Depois de ligar os envios, rode `--espera desligada` para conferir que o 64 está de pé com o marcador removido e o sender rodando.

**NO-GO (exit 1).** Ao menos uma falha **confirmada** (a resposta existe e é ruim). Leia as linhas `[NO-GO]`; cada uma diz o que viu. Não libere envio nenhum. Se o conserto cabe antes do horário-limite, conserte (consertar é de outra fatia, não deste script) e rode de novo. Se não cabe, é rollback para o mini antigo, pelo procedimento da fatia .4 (o servidor antigo só fica "desligado sem volta acidental" até o go): o rollback real só existe até o 1º envio ou escrita no 64.

**INCERTO (exit 2).** Nenhuma falha confirmada, mas pelo menos uma leitura não respondeu (comando ausente do PATH, estouro dos 20 s, saída que o script não reconhece, lista de dados vazia). **Não é GO.** Para cada linha `[INCERTO]`: (1) rode à mão o comando da tabela abaixo e olhe o resultado; (2) conserte o que impediu a leitura (por exemplo o `adb` fora do PATH, ou o `imparavel-check` lento) e rode de novo; (3) só se uma leitura continuar impossível por um motivo conhecido **e** a leitura manual mostrar o estado certo, o Mayor decide seguir, registrando a leitura manual na bead ga-ke5w2ie.6. O script nunca vira GO sozinho.

Falha confirmada e incerto na mesma rodada dão NO-GO: a falha decide.

## O horário-limite 04:30

Risco 5 do épico: sem prazo de go/no-go o rollback fica tarde demais, porque ele só existe até o 1º envio no 64, e o WhatsApp só pode ficar fora até as 07:00 (decisão do Athos no grill de 25/11). Regra: **sem GO às 04:30, vale NO-GO.** Um INCERTO que ainda está de pé às 04:30 conta como NO-GO.

A terceira linha da saída (depois do cabeçalho) diz quanto falta (`PRAZO 04:30: faltam 18 min`) ou que passou (`PASSOU há 15 min`). É informação, não uma checagem: se o `date` não responder, a linha diz "hora ilegível" e nenhum minuto é inventado. Entre 04:30 e meio-dia ela conta como "passou"; fora disso, como o tempo até o próximo 04:30. `GONOGO_PRAZO=HH:MM` muda o horário (valor inválido volta ao 04:30 e a linha avisa).

## Cada checagem

| linha | o que lê | NO-GO quando | INCERTO quando | à mão |
|---|---|---|---|---|
| `dolt-porta` | `dolt_server_live_port` (`scripts/dolt-pid-lib.sh`): processo `dolt` vivo com porta em LISTEN | nunca (a lib não separa "Dolt fora" de "não consegui ver") | sem processo ou porta, `lsof`/`pgrep` ausentes, estouro | `gc dolt status` |
| `bd-hq`, `bd-wa` | `bd -C <store> list -n 1 --json` | nunca | rc ≠ 0, resposta que não é lista JSON, 10 s ou mais, estouro | `bd -C <store> list -n 1` |
| `supervisor` | `launchctl list com.gascity.supervisor` | não carregado, ou carregado sem PID | `launchctl` ausente ou com erro | o mesmo comando |
| `pilot`, `gate` | `launchctl list` de `com.gascity.pilot` e `com.gascity.quality-gate-dispatcher` (jobs de intervalo: basta estar carregado) | não carregado | idem | o mesmo comando |
| `gc` | `gc session list` | nunca | rc ≠ 0, estouro | o mesmo comando |
| `imparavel` | `python3 scripts/imparavel-check.py`: a linha `VEREDITO:` e o rc | NÃO IMPARÁVEL (rc 1 **e** a linha) | quebrou sem a linha (também sai rc 1), rc que não bate com a linha, INCERTO dele, mais de 20 s | rodar o script e ler o relatório inteiro |
| `painel-<nome>` | `curl` em `127.0.0.1:<porta><caminho>` de cada linha de `paineis.tsv` | HTTP fora de 200/401/403 (inclusive 302); conexão recusada | sem resposta no prazo, `curl` ausente, código ilegível | `curl -i http://127.0.0.1:<porta><caminho>` |
| `adb` | `adb devices` contra `celulares.tsv` | serial que não aparece ou não está em `device` (`unauthorized`, `offline`) | lista vazia, `adb` ausente ou com erro, saída sem o cabeçalho | `adb devices -l` |
| `cloudflared-job` | `launchctl list br.urblink.cloudflared.urblink-ops` | não carregado ou sem PID | `launchctl` ausente ou com erro | o mesmo comando |
| `cloudflared-conectores` | `cloudflared tunnel info <id>` (o id vem de `~/.cloudflared/urblink-ops.yml`) | 2 ou mais conectores (o antigo ainda vivo) | 0 conectores lidos, formato que não reconheço, config ou cert ausentes | `cloudflared tunnel info <id>` |
| `disco` | `df -Pm /System/Volumes/Data` (nunca `df /`, que lê o volume de sistema selado) | livre abaixo de 100 GB | resposta ilegível ou de outro volume | `df -h /System/Volumes/Data` |
| `swap` | `sysctl vm.swapusage` (com `LC_ALL=C`; vírgula decimal também aceita) | mais de 2048 MB em uso | ilegível ou unidade que não é M nem G | `sysctl vm.swapusage` |
| `espera` | o marcador `~/.mini64-espera` da fatia .2 | estado diferente do esperado (`--espera`) | a pasta dele não abre | `ls -la ~/.mini64-espera` |
| `envio` | `launchctl list com.whatsapp.central-sender` | espera ligada e o sender carregado (pode estar enviando); espera desligada e o sender fora ou sem PID | `launchctl` ausente ou com erro | o mesmo comando |

`espera` e `envio` juntas respondem "ainda dá para voltar?": o marcador diz o que foi pedido e o sender diz o que o launchd de fato carregou.

## Arquivos de dados

`scripts/mini64/paineis.tsv` (nome, porta, caminho, separados por TAB; `#` comenta). Cada linha entregue tem fonte no repositório: demand-dashboard `:8095` (`/api/outreach/config`), map-viewer `:8099`, ficha360 `:8207`, clientes-dashboard `:8104` e admin-dashboard `:8097` (`/api/mockups`). **Conferir no mini atual antes da noite** (modo leitura, ver abaixo): ficha360 e clientes-dashboard só têm a porta e o `/` como fonte, e um `/` que responda 302 vira NO-GO (troque por uma rota que responda 200/401/403 direto). As portas 8086, 8203, 8090, 8088, 5599 e 5600 aparecem no repositório sem nome nem caminho de saúde confirmados: estão comentadas no arquivo e **não são conferidas** até alguém preencher.

`scripts/mini64/celulares.tsv` (serial, apelido, separados por TAB). Vazio. Com os celulares ligados por USB e autorizados, `adb devices -l` mostra os seriais; uma linha por aparelho em estado `device`, com apelido (`cel-1`...), **nunca número de telefone**. O selftest recusa um arquivo que pareça ter telefone.

## Ensaio no mini atual

A bead permite rodar no mini atual em modo leitura. Os padrões de disco e swap são os do 64 (1 TB, 64 GB), então no mini de 256 GB eles dariam NO-GO por construção; ajuste por variável. No mini atual o marcador não existe e o sender roda, que é o estado `--espera desligada`:

```bash
GONOGO_DISCO_MIN_MB=4096 GONOGO_SWAP_MAX_MB=8192 bash scripts/mini64/go-nogo.sh --espera desligada
```

Esperado no mini atual: `adb` INCERTO enquanto `celulares.tsv` estiver vazio; o resto OK. Um item `[NO-GO]` ou `[INCERTO]` aqui é o que a bead pede para descobrir ANTES da noite.

Outras variáveis (todas opcionais): `GC_CITY_PATH`, `GONOGO_BD_STORES` (`"hq=<caminho> wa=<caminho>"`; para conferir mais bancos, acrescente pares), `GONOGO_IMPARAVEL`, `GONOGO_PAINEIS`, `GONOGO_CELULARES`, `GONOGO_BD_SLOW_S` (10), `GONOGO_HTTP_OK` (`"200 401 403"`), `GONOGO_VOLUME`, `GONOGO_ESPERA_MARCADOR`, `GONOGO_LABEL_SUPERVISOR`, `GONOGO_LABEL_PILOT`, `GONOGO_LABEL_GATE`, `GONOGO_LABEL_TUNEL`, `GONOGO_LABEL_SENDER`, `CLOUDFLARED_CONFIG`, `GONOGO_EXTRA_PATH` (diretórios acrescentados ao FIM do PATH, para ssh e launchd; o padrão inclui `/opt/homebrew/bin`).

## Medido, inferido, não testado

- **Medido** (nó Hetzner, 26/11): `bash scripts/mini64/go-nogo.selftest.sh` com comandos de mentira num PATH isolado. Cobre tudo ok → GO, uma falha em cada checagem → NO-GO, comando ausente em cada ferramenta, estouro de prazo em todas as chamadas, leitura vazia ou ilegível, a precedência, a porta do Dolt (do processo, nunca de arquivo, nem do `GC_DOLT_PORT_OVERRIDE`), as fronteiras de disco e swap, o horário-limite, o teto de 20 s e o somente-leitura (o log de chamadas e o texto do script). Roda também com o script sob um GNU bash 3.2.57 compilado a partir do fonte (não é o `/bin/bash` com patches da Apple). O resultado final e a bateria de mutantes estão no comentário da bead.
- **Inferido do código do repositório, não executado no mini**: o formato de `launchctl list <label>` (de `nightly-reboot-postcheck.sh`), de `df -Pm` e `sysctl vm.swapusage` (de `disk-recovery-ladder.sh`), as linhas `VEREDITO:` e os exit 0/1/2 do `imparavel-check.py`, e o ponto de montagem `/System/Volumes/Data`.
- **Não testado**: o texto real de `cloudflared tunnel info` (o script espera uma linha `ID:` e uma linha por conector começando pelo UUID dele; se o formato for outro, a linha sai INCERTO "formato não reconhecido" ou "0 conectores lidos", nunca GO); o tempo real do `imparavel-check.py` (se passar de 20 s a linha sai INCERTO); `bd list` nos dois bancos e `gc session list` no 64; qualquer coisa contra o mini de verdade.

## Limites conhecidos

1. **`dolt-porta` nunca dá NO-GO.** A lib não distingue "Dolt fora" de "não consegui ver o processo"; um Dolt fora aparece como INCERTO aí e como INCERTO nas duas linhas `bd-*`. É INCERTO de propósito: confundir os dois é o erro que a regra de terceiro estado proíbe.
2. **O teto de 20 s por checagem é duro** (critério da bead). Se o `imparavel-check.py` demorar mais no 64 carregado, a linha sai INCERTO e vale a leitura manual do veredito dele.
3. **Só confere o que a bead lista.** Não olha Wi-Fi ou chave do servidor antigo (fatia .4), backup S3, camadas ainda não carregadas, nem o IP LAN reservado.
4. Os labels do launchd (supervisor, pilot, dispatcher do gate, túnel, sender) vêm de `daemon-presence-watchdog.sh` e `nightly-reboot-postcheck.sh`. Se o 64 usar outros, ajuste as variáveis `GONOGO_LABEL_*`. O `launchctl list` só enxerga os agentes do usuário na sessão dele: rode do Terminal do mini ou do tmux das sessões da cidade, não de um ssh sem sessão gráfica (lá um job carregado pode aparecer como "não está carregado"). Comando fora do PATH (por exemplo o `adb`) sai INCERTO "ausente no PATH": aponte a pasta dele em `GONOGO_EXTRA_PATH`.
5. O script lê o marcador direto (`~/.mini64-espera`, o caminho que `mini64-lib.sh` da fatia .2 grava; conferido no código dela, branch `fix/ga-ke5w2ie.2-espera-camadas`). Marcador que existe mas não é arquivo legível dá INCERTO, como o `nao-sei` dela. `espera.sh status` (a mesma fatia, depois do merge) dá o estado completo (`ligada`, `em-carga`, `carga-completa`...); os daemons não leem o marcador, a barreira real é o plist ausente, e é por isso que `envio` olha o launchd.
6. O túnel: `br.urblink.cloudflared.urblink-ops` vem de `nightly-reboot-postcheck.sh`, onde roda toda noite. O `camadas.tsv` da fatia .2 diz que o label real não está em nenhum repo e deixa esse plist na família `br.urblink` (camada 5): se ficar assim, o túnel só sobe com os envios e `cloudflared-job` dá NO-GO no go/no-go. Precisa de uma linha dele na camada 4.
