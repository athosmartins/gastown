# Ferramentas de REA no nó Hetzner · runbook

## Contents
• O que é e por que existe · Comandos · O `--exec` no nó: o que entra e o que fica no MBP · Procedência dos hashes · Estado vivo e o que foi MEDIDO · Como atualizar · Como desfazer · O que NÃO foi feito · Limites

Bead ga-kfxzpt (item 7 da lista do Athos de 13/10; reativada pelo Mayor em 31/10 para pôr trabalho útil no nó: só leitura de anúncios públicos, skill `rea-scraper-first`). Segue o desenho do Chromium (`hetzner-chromium.md`) e do Node (`hetzner-nodejs.md`): nível de usuário, sem sudo, pin com sha256 que vem do mini, marcador gravado por último.

## O que é e por que existe
O REA/APK pesado ia só ao MBP (`rea-run.sh` → `mbp-run.sh --exec`). Agora o `rea-run.sh` sem `--local` passa `--node-first` e a cadeia é nó Linux → MBP → mini (os mesmos códigos 96..99 do pytest). Para o nó rodar `jadx` e `apktool` ele precisa das ferramentas, que este install põe em `~/.local/share/rea-tools` (o nó é aarch64, Ubuntu 24.04):
- **JDK 21 do Temurin, completo.** O REA exige JDK ≥ 17 com o módulo `jdk.compiler` em `JAVA_HOME` ABSOLUTO (um JRE não serve: `rea` recusa com `runtime_missing`). 346 MB extraídos.
- **jadx 1.5.6** (wrapper `bin/jadx`: `java -cp jadx.jar jadx.cli.JadxCLI`, heap 4 GB; `JADX_HEAP_MB` troca) e **apktool 3.0.3** (wrapper `bin/apktool`, heap 2 GB; `APKTOOL_HEAP_MB`). O heap é limitado de propósito: o padrão do jadx é 70% da RAM e tomaria o nó das outras sessões.
- **O jar `jadx-headless-mcp-0.7.1-all.jar`**, que é o motor de Android do `rea-agents` 6.4.0 (ele "não baixa nem instala" o jar, só lê `REA_JADX_MCP_JAR`). A versão e o sha256 são os que o próprio REA fixa em `dist/android/JadxRelease.js`.

## Comandos
Rodam no **mini**; o nó é alcançado por ssh (`HETZNER_NODE_HOST`, padrão `hetzner-teste`).
```bash
bash scripts/hetzner-rea-tools.sh check     # só lê (e roda java, jadx --version, apktool --version). rc 0 igual ao pin · 1 ausente/quebrado/diferente · 2 não consegui saber · 3 nó que o pin não cobre
bash scripts/hetzner-rea-tools.sh install   # idempotente: igual ao pin = não baixa nada. rc 4 recusado · 5 download falhou · 64 uso errado. Termina com a MESMA conferência do check
bash scripts/hetzner-rea-tools.selftest.sh  # hermético, ~40 s: ssh/curl/uname são stubs, o script remoto roda de verdade num HOME temporário com um JDK falso; 33 mutantes
```
O `install` baixa os 4 artefatos para uma pasta temporária, confere o sha256 de CADA UM contra o pin antes de abrir qualquer coisa, exige `Temurin-<versão>` e `jdk.compiler` no JDK, tira só o jar de dentro do zip do jadx (`python3 zipfile`, um membro) e confere o sha256 dele, exige no jar do REA as 5 classes que o REA confere, move cada um para a pasta da própria versão, religa os links (`jdk`, `jadx.jar`, `apktool.jar`, `jadx-headless-mcp.jar`), roda `jadx --version` e `apktool --version` e **só então** grava `ready`. O marcador cai no começo: uma recusa no meio deixa o nó sem ele e o `--exec` volta ao MBP.

## O `--exec` no nó: o que entra e o que fica no MBP
Sem `--node-first` o `--exec` é só do MBP, como sempre: o laboratório do Dolt (`dolt-restore-lab-mbp.sh`, que empurra backup do Dolt e um binário do macOS), o build de Go (`--go`, variáveis de CGO do macOS) e a conferência do jsonl offsite também usam `--exec`, e nada disso pode ir ao servidor alugado. Com `--node-first` (só o `rea-run.sh` o passa) o nó entra se TODAS as portas abrem; a que não abre manda a execução ao MBP e deixa uma linha no `mbp-run.jsonl` (`host":"hetzner"`, com o motivo):
| Porta | Fecha quando | Motivo no log |
|---|---|---|
| bandeira | falta `$CITY/.gc/hetzner-node.on` (é o interruptor: segue calado) | — |
| saúde | as do preflight do nó (RAM, PSI, swap, disco, slots) | `ram`, `pressao`, `disco`, `slots`... |
| ferramentas | o preflight diz `rea_tools=none` (nunca instalado) ou vazio (marcador ilegível, sem `TOOLS=`, ou java/jadx/apktool faltando) | `sem-ferramentas` · `ilegivel:rea_tools` |
| comando | cita `rea`, `ghidra`, `analyzeHeadless`, `adb`, `hopper`, `ida`... e a lista do nó não tem (heurística de ECONOMIA: evita empurrar o arquivo em vão) | `sem-ferramenta:<nome>` |
| `--push` | não é UM arquivo comum (diretório, link, ausente), o caminho começa com `-` (o rsync o leria como opção), não tem extensão de pacote de app (`apk apks xapk apkm aab dex jar aar so dylib asar exe dll ipa`) ou passa de 1024 MB (`HETZNER_EXEC_PUSH_MAX_MB`): a FORMA | `push-recusado` |
| `--push` (conteúdo) | `scripts/hetzner-push-scan.py` (ga-jq08gyi; o `--exec` não passa pelo `node_guard` do pytest): o começo do arquivo não é do tipo que a extensão diz (magic bytes: um `.apk` de texto não passa), ou o arquivo ou algum MEMBRO de zip (recursivo: `.apks`/`xapk` são zip de zips; gzip, bzip2 e xz também) tem >=20 telefones ou >=3 CPFs, os limiares do `hetzner-pii-scan.py` | `push-conteudo` |
| `--push` (não deu para ler) | zip corrompido ou cifrado, zip que o `zipfile` do Python recusa (o jar sombreado do REA, com entradas sobrepostas, é assim: medido no Python 3.12.3 do servidor; a guarda é do `zipfile` e muda com a versão do Python), 7z/rar/zstd/lz4 dentro do pacote, teto de leitura (membro 256 MB, total 4096 MB, 4 níveis de contêiner), `python3` ou o script ausente. É o terceiro estado: nunca vale como "limpo" | `push-ilegivel` |
| `--env` (nome de segredo) | o NOME tem TOKEN, SECRET, KEY, PASS, AUTH, COOKIE, CRED ou SESSION (o valor nunca é impresso); vale POR CIMA da allowlist, inclusive para `REA_*` | `env-recusado` |
| `--env` (allowlist) | o nome não é `JADX_HEAP_MB`, `APKTOOL_HEAP_MB` nem começa com `REA_` (mesma caixa; nome inválido nunca vale). Antes só havia a denylist por nome, e `PDPJ_JWT`, `*_BEARER` ou um DSN com senha embutida passavam | `env-fora-da-lista` |
| `--env` (valor) e comando | o VALOR de um `--env` da allowlist, ou qualquer palavra do comando, tem cara de credencial: JWT (`eyJ…`), `sk-…`, `Bearer …`, chave privada, token do GitHub/Slack/AWS/Google, URL com `usuário:senha@`. Heurística de FORMA, no Python do `hetzner-push-scan.py --creds` (o mesmo no mini e no selftest; a regex não é de grep, cujo dialeto muda entre o macOS e o Linux): no `--env` quem barra o segredo sem forma conhecida é a allowlist; no comando ela é a única barreira | `env-valor-credencial` · `argv-credencial` |
| `--env` (valor) e comando (não deu para olhar) | o varredor deu erro, o `python3` ou o script faltam: "não consegui olhar" não é "achei" nem "limpo"; só o rc 0 dele deixa passar | `credencial-ilegivel` |
O que corre no nó: `PATH` com `rea-tools/bin` na frente, `JAVA_HOME=~/.local/share/rea-tools/jdk` e `REA_JADX_MCP_JAR` (se o jar existe). `rc 126/127` do nó (o shell não achou ou não executou o comando) **não é veredito**: o scratch sai (mesmo com `--keep`) e o MBP roda. O scratch do nó (`~/gt-remote/exec/<slot>`) nasce vazio e é apagado ao fim. Só comando de leitura/recon: a queda do ssh no meio refaz tudo no host seguinte (já era a regra do `rea-run.sh`).

## Procedência dos hashes
A prova não é a mesma para os quatro (detalhe e fingerprints no cabeçalho de `hetzner-rea-tools.pin`): JDK = assinatura GPG do Adoptium conferida + arquivo .sha256.txt + digest do GitHub, os três iguais; apktool = jar do Maven Central com a assinatura PGP conferida (é o único caminho: o jar do release do GitHub é outro arquivo); jar do REA = o sha256 que o rea-agents 6.4.0 fixa == digest do GitHub; jadx = digest do GitHub + as 808 entradas dos jars ASSINADOS `jadx-core` e `jadx-cli` do Maven Central idênticas às do jar do zip (as bibliotecas de terceiros dentro dele não foram comparadas).

## Estado vivo e o que foi MEDIDO
Instalado em 31/10/2026 17:42Z, neste nó, pelo próprio `install` (rodado no nó por um ssh de teste local; o `install` do mini depois do merge é no-op): 9 s, 483 MB em `~/.local/share/rea-tools`, `check` rc 0, segundo `install` 1,5 s sem baixar nada. Conferido direto no nó, não só pela saída do script: `java -version` = Temurin-21.0.9+10, `jdk.compiler@21.0.9`, os 3 sha256 dos jars iguais ao pin, wrappers executáveis.
- **jadx e apktool num APK real** (F-Droid `com.simplemobiletools.flashlight` 5.10.1, 10 MB, baixado por https): jadx 26-35 s, 4908 fontes .java, pico de 1,4 GB de RSS com `-Xmx1g` e 1,9 GB com `-Xmx2g` (sai com rc 3: o jadx conta classes que não decompilou, é o normal); apktool 5,8 s.
- **Pela cadeia de verdade** (`mbp-run.sh --exec --node-first --push app.apk --pull out:… -- sh -c 'jadx …; apktool d …'`, o nó = esta máquina por um ssh local): preflight, slot 2 (o 1 era do mini), push, job, pull, scratch com 0 entradas ao fim, slot solto, linha `host:hetzner mode:exec rc:0 secs:30`. As quatro portas também foram vistas ao vivo: `.json`, `rea`, comando que não existe (127) e `API_TOKEN` voltam ao MBP.
- **REA ponta a ponta, fora do nó** (rea-agents 6.4.0 instalado numa pasta de teste, com este JDK, este jar e este apktool): `inspect-apktool-client` viu o apktool 3.0.3 e `inspect-android-package` devolveu pacote, versão, SDKs, permissões, 4909 classes e 1951 recursos em ~10 s.

## Como atualizar
Receita no cabeçalho do pin: baixar o artefato novo, repetir a conferência de procedência, trocar as linhas daquele artefato de uma vez (jadx: as DUAS), `bash scripts/hetzner-rea-tools.selftest.sh`, depois `install`. O JDK é identificado pela **versão**, como o Node: trocar só o hash do pin sem trocar a versão NÃO reinstala. O jar do REA só muda junto com o pin do REA (`rea-versao-fixa-e-patch.md`).

## Como desfazer
Tudo mora em `~/.local/share/rea-tools` (e o cache do apktool em `~/.local/share/apktool`); nada fora disso foi tocado. Desligar na hora, sem apagar nada: `ssh hetzner-teste 'rm -f ~/.local/share/rea-tools/ready'` (o preflight passa a dizer `rea_tools=none` e o `--exec` volta ao MBP). Voltar a uma versão que continua na pasta: religar os links. Liberar os 483 MB: apagar a pasta depois de desligar.

## O que NÃO foi feito
- **O `rea` em si não está no nó.** Foi medido que ele roda aqui (`npm install --ignore-scripts`: 144 pacotes, 97 MB, 8 s; `rea 6.4.0`), mas dos comandos do `rea --help` muitos pedem Hopper, IDA, JEB, Ghidra, LLDB ou macOS que só o MBP tem. Mandar `rea` ao nó pede uma política de quais subcomandos (ex.: `*-android-*`, `analyze-javascript-application`), que é decisão do Mayor; hoje um comando que cita `rea` vai direto ao MBP.
- Ghidra: não instalado e não medido neste nó. `apktool b` (reconstruir): sem aapt2 para aarch64, só `apktool d`.
- O recon web (Chrome em `127.0.0.1:$PORT`) segue `--local` no mini: o endereço não existe no nó.
- O `check` pelo mini (ssh de verdade) e o ramo de fallback ao MBP de verdade não foram exercitados; a cadeia foi provada com o nó e um MBP desligado.

## Limites
- **O job roda como o usuário do nó**, que guarda as credenciais do nó (login do claude, chave do espelho git, atalho ssh ao mini), e o jadx/apktool leem APK de terceiros: não há sandbox além do usuário. O isolamento de rede da bateria noturna (`HETZNER_ISOLATE`/`gt-iso-run`) NÃO foi ligado ao `--exec`. Ainda assim o nó é um lugar menos sensível que o MBP ou o mini para abrir binário alheio.
- Duas instalações ao mesmo tempo não são serializadas e um `install` durante um `--exec` troca arquivos que o job pode estar usando: um `install` por vez, fora de execução.
- O ssh que cai no meio de um `--exec` não deixa apagar o scratch: as capturas ficam no nó até o próximo uso do mesmo slot (ele é esvaziado ao começar). `hetzner-audit.sh` audita `~/gt-remote/exec/<slot>` como as outras pastas: uma auditoria DURANTE uma execução acusa o APK empurrado como `GRANDE` (alarme falso).
- A lista de nomes de ferramenta do `--exec` (`NODE_EXEC_KNOWN`), a de extensões (`NODE_EXEC_EXT`) e a allowlist de `--env` (`NODE_EXEC_ENV_OK` + o prefixo `REA_`) são fixas em `mbp-run.sh`: ferramenta nova do nó pede o nome em `TOOLS=` do marcador e na lista; extensão nova pede o tipo em `hetzner-push-scan.py` (o selftest quebra se faltar); `--env` novo pede o nome na allowlist, senão a execução fica no MBP.
- **A varredura de CONTEÚDO do `--push` (ga-jq08gyi) é heurística de forma**, a mesma do `hetzner-pii-scan.py`: não vê dado sem forma de telefone/CPF (nome, e-mail, CNPJ, endereço), lista abaixo de 20 telefones / 3 CPFs, nem lista em base64, UTF-16 ou compressão sem cabeçalho (brotli). É um retrato: arquivo editado entre a leitura e o rsync não é revarrido. Custo medido em 31/10 (carga ~20): ~12 MB/s de bytes VARRIDOS (o arquivo cru mais cada membro descomprimido, em geral 2 a 4 vezes o tamanho do arquivo), com memória plana: jadx.jar de 74 MB e 34 mil membros = 252 MB varridos em 20 s e 88 MB de RSS; apktool.jar de 21 MB = 84 MB em 7 s. O pior caso é o teto de 4096 MB varridos, uns 6 min (extrapolado, não medido). Roda no mini ANTES de pegar o slot, então não segura vaga no nó.
- O que o varredor não consegue ler fica no MBP, e isso inclui pacotes legítimos (o `jadx-headless-mcp-0.7.1-all.jar`, medido): é o preço do terceiro estado inerte, e o MBP é o destino de sempre.
