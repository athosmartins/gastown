# Mini 64: runbooks da migração · índice

Runbooks da migração da cidade para o Mac mini M5 Pro 64 GB / 1 TB (programa ga-ke5w2ie, chega na semana de 30/11): UM arquivo por fatia, nomeado `NN-nome.md`, todos com `## Contents`. Este índice é da fatia .1 e cada fatia nova acrescenta aqui a sua linha. Os scripts moram em `scripts/mini64/`. Nada disto roda contra a produção do mini 16 além de leitura; a execução real é na noite D0, pelo Mayor.

## Contents

• Arquivos · Como gerar o inventário · Como ler o inventário · Fatias do programa

## Arquivos

| arquivo | o que é | fatia |
|---|---|---|
| `README.md` | este índice | .1 |
| `01-inventario.md` | o que o Assistente de Migração NÃO leva sozinho (TCC, CLT/python, driver WCH.CN, ssh, LaunchAgents/Daemons, Keychain, contas Claude, Drive...) e o checklist «o que refazer à mão no mini novo». **Gerado** pelo script abaixo, no mini atual; só existe aqui depois da primeira rodada lá | .1 |
| `.gitignore` | ignora `.inventario-work.*/`, a pasta de trabalho que sobra se o gerador for morto à força (o corpo ali ainda não passou pela varredura de segredo) | .1 |
| `../../../scripts/mini64/inventario.sh` | o gerador: SÓ LEITURA, sai 0 em menos de 2 min, escreve apenas `01-inventario.md` | .1 |
| `../../../scripts/mini64/inventario.selftest.sh` | o teste do gerador (HOME, cidade e PATH falsos; segredos plantados; matriz de falhas) | .1 |

## Como gerar o inventário

No mini atual, na pasta da cidade (`~/gt/.gascity-gastown-hq`): `bash scripts/mini64/inventario.sh`. Depois revise o `01-inventario.md` e comite.

- Rode no Terminal do usuário (sessão Aqua). Dentro do tmux do gc o launchd costuma ser a sessão Background, onde Keychain e TCC respondem diferente; o doc registra a sessão na seção 1 para quem ler saber qual foi.
- Não usa sudo, rede nem `-w`/`-g` no `security`; o doc é varrido por padrões de segredo antes de gravar (o cabeçalho conta quantas linhas foram suprimidas). Mesmo assim ele traz nomes, e-mails das contas Claude, IP e MAC da máquina e os comentários do `authorized_keys`: identificam, não são segredo; leia o doc antes de comitar.
- Rode de novo em D-3 (pré-carga) e na noite D0, antes do corte: o `git diff` do doc mostra o que mudou.
- Quem completa o que ficou «não apurado» por falta de Acesso Total ao Disco ou de sudo é o Athos, no Terminal dele.

## Como ler o inventário

«não apurado» = a sonda não conseguiu responder (comando ausente, rc diferente de zero, prazo estourado, formato inesperado, arquivo ilegível) e a linha diz por quê. «nenhum» ou 0 = o comando respondeu e a resposta era vazia. As duas coisas nunca se misturam: um «não apurado» não prova que o item não existe. «Nenhum python sem caminho» e «nenhum bw serve» dos plists valem só para os argumentos dos plists de `~/Library/LaunchAgents` que o script leu (plist binário vira «não apurado»; dos plists de `/Library` só o nome é listado).

## Fatias do programa

| fatia | tema | bead |
|---|---|---|
| .1 | inventário de dependências de máquina (esta pasta) | ga-ke5w2ie.1 |
| .2 | chave de espera de migração + ordem de carga em camadas | ga-ke5w2ie.2 |
| .3 | verificação de go/no-go + prazo 04:30 | ga-ke5w2ie.3 |
| .4 | desligar o servidor antigo sem volta acidental | ga-ke5w2ie.4 |
| .5 | pré-carga diurna D-3 | ga-ke5w2ie.5 |
| .6 | noite de corte D0 | ga-ke5w2ie.6 |
| .7 | limites para 64 GB/1 TB em D+1 | ga-ke5w2ie.7 |
| .8 | papel do mini 16 no setup | ga-ke5w2ie.8 |
| .9 | Hetzner: casa nova para cada job | ga-ke5w2ie.9 |
| .10 | S3: parquets RFB para o disco local | ga-ke5w2ie.10 |
| .11 | restore de prova do backup S3 | ga-ke5w2ie.11 |
| .13 | sair do MotherDuck | ga-ke5w2ie.13 |
| .14 | mídias das conversas | ga-ke5w2ie.14 |
| .15 | quantos números ligam pelo sistema (peter) | ga-ke5w2ie.15 |
