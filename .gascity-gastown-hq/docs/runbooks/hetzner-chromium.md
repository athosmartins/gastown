# Chromium do Playwright no nó Hetzner · runbook

## Contents
• O que é e por que existe · Comandos · Como a fiação funciona · Estado vivo e o que foi MEDIDO
• Como atualizar a versão · Como desfazer · O que NÃO foi testado · Limites

Bead ga-aptlug (achado de ga-00unl0). A bead perguntava: instalar com apt/sudo, declarar os dois arquivos "só no mini", ou aceitar o pulo. Decisão (dog-remote-3, comentário de 22/10/2026 06:12Z): **instalar, mas em nível de usuário e sem sudo**, o mesmo desenho do Node (ga-2hd02v.4) e do bootstrap do scrape (`hetzner-scrape-round.sh`). A premissa da bead de que isso "não dá para fazer só em nível de usuário" não se confirmou.

## O que é e por que existe
Dois arquivos de teste do WA (`tests/test_terrenos_construtoras_e2e_wa_gnvcqe.py`, `tests/test_pessoas_admin_e2e_wa_jkr1bh_6.py`) abrem um Chromium pelo Playwright. No nó eles davam **49 pulos** ("Chromium do Playwright não instalado nesta máquina"): o gate-pytest rodava de novo no mini o alvo que pulou, mas gastava o mini carregado com 49 e2e de navegador a cada bateria que citava esses arquivos.

O navegador vai para `~/gt-remote/pw-chromium/env/browsers` (o `playwright install chromium-headless-shell` do próprio venv-wa, Playwright 1.58.0, Chromium build 1208, linux-arm64). As 13 bibliotecas de sistema que ele pede e o nó não tem vêm de `.deb` baixados com `apt-get download` (não precisa de root) e extraídos com `dpkg -x` em `env/root`; o `libpath.txt` guarda os diretórios para o `LD_LIBRARY_PATH`. O nó é aarch64 (Ubuntu 24.04); o script recusa (rc 3) outro SO ou arquitetura.

## Comandos
Rodam no **mini**; o nó é alcançado por ssh (`HETZNER_NODE_HOST`, padrão `hetzner-teste`; `MBP_SSH` troca o ssh).

```bash
bash scripts/hetzner-chromium.sh check     # só lê (e abre o navegador de verdade, 1 s, numa página local). rc 0 igual ao pin · 1 ausente/quebrado/diferente · 2 não consegui saber · 3 nó que o pin não cobre
bash scripts/hetzner-chromium.sh install   # idempotente: já igual ao pin = não baixa nada. rc 4 recusado · 5 download falhou · 64 uso errado. Termina com a MESMA conferência do check
bash scripts/hetzner-chromium.selftest.sh  # hermético (~20 s): ssh/uname/apt-get/dpkg/ldd/python do venv-wa são stubs, o script remoto roda de verdade num HOME temporário; 29 mutantes
```

O `install`, nesta ordem: **tira o marcador `ready`** · instala o headless shell · confere o sha256 dele contra o `scripts/hetzner-chromium.pin` ANTES de executá-lo · baixa e extrai os `.deb` (limpando os de uma instalação anterior) · exige `ldd` com 0 bibliotecas faltando · **abre o navegador de verdade** · só então grava o marcador. Qualquer recusa no meio deixa o nó SEM marcador.

## Como a fiação funciona
O marcador `~/gt-remote/pw-chromium/env/ready` é a **única** coisa que liga o Chromium aos testes. O `mbp-run.sh`, no job de pytest do nó (não no MBP, não no selftest do hq), exporta `PLAYWRIGHT_BROWSERS_PATH` e `LD_LIBRARY_PATH` **juntas** se, e só se, o marcador existe e não é vazio, `browsers/` existe e o `libpath.txt` lê e não é vazio. Qualquer porta falha = nada é exportado e os e2e pulam como antes.

Por quê: medido, com o navegador presente e SEM as bibliotecas o launch falha com `Target page, context or browser has been closed`, que **não** casa a cláusula de skip dos testes (ela só pega `Executable doesn't exist`). Meia instalação troca PULADO por VERMELHO, então ela nunca pode ligar. Por isso a ordem de entrega não importa: o merge do `mbp-run.sh` e o `install` podem vir em qualquer ordem, e enquanto um dos dois faltar tudo continua pulando.

O `LD_LIBRARY_PATH` do job fica **depois** do libpath (o que já existia continua valendo). As bibliotecas extraídas têm precedência sobre as do sistema; hoje nenhum soname delas existe no ld cache do nó, então só acrescentam.

## Estado vivo e o que foi MEDIDO
Medido no nó em 22/10/2026 (Ubuntu 24.04 aarch64, usuário `runner` sem grupo de admin, 259 GB livres), por duas sessões do dog-remote-3 na ga-aptlug:
- **Antes**: os dois arquivos juntos = 49 pulados em 2,85 s, rc 0. O `ldd` do headless shell: 12 bibliotecas não encontradas.
- **Navegador**: `headless_shell` de 287 892 096 bytes, sha256 `3d7ae069d9c2e7f049998f6871be2381fb6967f7a06c26ea0b346321e3dc496f`, Chrome Headless Shell 145.0.7632.6. Dois downloads independentes deram o mesmo hash (o Playwright não publica hash: é confiança no primeiro uso, confirmada duas vezes).
- **Com as 13 bibliotecas** (a lista do pin; nestas duas rodadas elas vieram do bootstrap do scrape, que usa a mesma lista, e não do `install` novo): `ldd` 0 faltando; o navegador abre em 0,9 s; os 49 testes passam em série em 81,1 s e com xdist em 46,3 s (o teto do nó limita `-n 4` a 2 workers). Com as bibliotecas que o `install` novo extraiu: ver a instalação viva abaixo. Com um conjunto maior (41 pacotes) também deu 49 passed, em 80,6 s: as 13 bastam.
- **Instalação viva** (`install` rodado no próprio nó por ssh falso): 15 s, rc 0, todos os passos (`marcador-removido`, `sha256-ok`, `extraiu 13 .deb`, `ldd-sem-faltando`, `navegador-abriu`, `marcador-gravado`); 336 MB em `~/gt-remote/pw-chromium`; o `~/.cache/ms-playwright` (destino padrão do Playwright) não foi criado.
- **Bloco da fiação extraído do job que o `mbp-run.sh` gera** e rodado no nó: as duas variáveis apontam para `env/browsers` e para os dois diretórios de `env/root/usr/lib/aarch64-linux-gnu`; os 49 testes passam em 53,4 s (xdist, 2 workers), rc 0.
- **Três arquivos e2e que JÁ estão em `hetzner-mac-only.txt`** (map_viewer esc/atalhos, segurar carrinho, pregao_sort_panel), rodados no nó com o navegador desta instalação e as bibliotecas do bootstrap do scrape (não as do pin): 47 passaram em 85 s. Não foram tirados da lista (outra decisão, e não se sabe se entraram nela por falta de navegador); fica como achado para quem mexer na lista.
- **A auditoria de dados do nó** (`hetzner-audit.sh`) olha cada filho de `~/gt-remote` e poda `./env` no topo dele (`GT_PRUNE`, linhas 31 e 122): o `pw-chromium/env` cai nessa poda, o mesmo caminho do `scrape/env`. **Lido do código, não medido** (rode `hetzner-audit.sh` depois do primeiro `install` do mini).

## Como atualizar a versão
Receita no cabeçalho de `scripts/hetzner-chromium.pin`: subir o Playwright do venv-wa (o build do navegador muda junto), rodar o `install` uma vez com o hash antigo e ver a recusa `sha256 do navegador não confere`, conferir o hash do arquivo novo em **dois** downloads, trocar as duas primeiras linhas do pin de uma vez, rodar o selftest e o `install`. Biblioteca nova que o `ldd` acuse entra em `DEB_PACKAGES`.

## Como desfazer
Tudo mora em `~/gt-remote/pw-chromium` do usuário `runner` no nó. **Desligar** (os 49 e2e voltam a pular, nada mais muda): `ssh hetzner-teste 'rm -f ~/gt-remote/pw-chromium/env/ready'`. Liberar os 336 MB: depois de desligar, `ssh hetzner-teste 'rm -rf ~/gt-remote/pw-chromium'`. O `mbp-run.sh` não precisa ser revertido: sem o marcador o bloco não exporta nada.

## O que NÃO foi testado
- **Quantas baterias reais citam esses dois arquivos**: o `gate-pytest.jsonl` mora no mini; os números de ganho acima são de rodada isolada, não de produção.
- **Os outros 8 arquivos com a cláusula de skip e os 121 `test_*.py` que chamam `chromium.launch` sem ela**: não foram rodados. Os 121 não têm a cláusula e nenhum está em `hetzner-mac-only.txt`: sem navegador eles dariam vermelho no nó se citados; com o navegador ligado passam a poder rodar, o que também não foi medido. É uma classe aberta que esta bead não fecha.
- **`HETZNER_ISOLATE=1`** (`gt-iso-run`, ambiente limpo): o bloco entra no job, mas o isolamento não foi rodado aqui. O esperado é as duas variáveis sumirem juntas (os e2e pulam como antes), nunca uma só. Quem ligar o isolamento e quiser o navegador precisa passar as duas variáveis pelo `gt-iso-run`.
- **O `install` disparado do mini** (ssh de verdade): o rodado foi no próprio nó com um ssh que só executa o comando local. O segundo `install` do mini deve sair `ok` sem baixar nada.
- **`sudo`**: nada neste desenho o usa; a sessão negou a chamada que o continha e não houve tentativa de contornar.

## Limites
- Duas instalações ao mesmo tempo não são serializadas (não há lock) e um `install` durante uma bateria troca arquivos que um Chromium em curso pode estar usando: rode um `install` por vez, fora de bateria. Como o marcador cai no começo, as baterias que começarem no meio dele pulam.
- As bibliotecas extraídas entram no `LD_LIBRARY_PATH` com precedência sobre as do sistema. Se um dia uma delas passar a existir no ld cache do nó, refaça o `install` e confira.
- O Playwright não publica hash do navegador: o pin vale "este binário é o que o CLI oficial baixou no dia da medição", não "este binário é autêntico por assinatura".
