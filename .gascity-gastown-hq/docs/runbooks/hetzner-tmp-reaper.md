# Reaper do /tmp do nó Hetzner (hetzner-tmp-reaper) · runbook

## Contents

• Estado · O que apaga e o que nunca apaga · Os 3 estados · Instalar (Mayor, depois do merge) · Operar · Alarme de disco e inodes · Quem vaza (para consertar na fonte) · A conta das 24 h · Medido, inferido, não testado

Bead ga-d4iob2s (P1). Em 16/11 22:40 o nó estava com 6,5 GB livres de 301 GB e inodes a 95 %, e o noturno do Traço BIM pulou (ga-z4zvx4q): `/tmp` tinha 653.892 entradas de teste e o único limpador era a linha de cron do `wa_test_*`. O lastro roda `hq-selftests`, `wa-suite` (~100 mil testes), `hq-mutants` e `wa-mutants` em laço, então cada teste que não limpa vaza uma vez por rodada e por mutante.

## Estado
**Mergeado ≠ vivo.** O código entra no repo; a cópia em `~/gt-remote/bin/` e a linha de cron do `runner` são passos do Mayor (abaixo). Sem o cron nada roda e nada é apagado. O limpador único do Mayor (`~/tmp-reap-20261116.sh`, 7 padrões de nome) e a linha hourly do `wa_test_*` seguem valendo até o reaper provar 48 h estável.

## O que apaga e o que nunca apaga
`scripts/hetzner-tmp-reaper.py`, a cada 10 min, como `runner` (recusa root). **Por idade e dono, nunca por lista de nomes** (às 01:56Z de 17/11 os 7 padrões do limpador do Mayor casavam 59 mil das 393 mil entradas, 15 %; das 367 mil com mais de 6 h, 315 mil ficavam de fora: `chip_features_testes_*` sozinho eram ~44 mil).
- **Unidade** = cada entrada de 1º nível de `/tmp` e, dentro de `claude-<uid>` (os scratchpads das sessões), cada projeto. O contêiner está sempre fresco (sessão viva): sem descer nele, a maior fatia de inodes (estimada em 4 a 13 milhões) nunca seria limpa.
- **Apaga** a unidade cuja ÁRVORE INTEIRA tem `max(mtime, ctime)` há mais de N horas (padrão 6, `--max-age-hours` ou `TMP_REAPER_MAX_AGE_H`). A árvore, não a pasta: a pasta do tmux fica quieta por dias com os agentes vivos dentro. O ctime conta porque `tar -x` e `chmod` deixam mtime velho em coisa nova.
- **Nunca toca:** o que não é do usuário que roda (o `dados` da trava 1 e o root: `alheio`); exceções de fábrica (`tmux-*`, `.X11-unix` e irmãs, `hsperfdata_*`, `systemd-private-*`) mais as linhas de `~/gt-remote/tmp-reaper/keep.txt` (um padrão de nome por linha, `#` comenta); o que processo vivo usa (cwd, exe, fd e argv, e **socket unix ligado** em `/proc/net/unix`: o socket do tmux dos agentes e o do ssh-agent); o que mudou entre o julgamento e o apagar (dispositivo, inode, mtime e ctime do topo conferidos de novo); unidade com uma **montagem** dentro (outro dispositivo, ou ponto de `/proc/mounts`: o bind do MESMO disco passa pelo `st_dev` e apagar por ele apagaria o original). Link simbólico: apaga o link, nunca segue.
- Teto de tempo por rodada (`--max-seconds`, 540): a limpeza do atraso vira `PARCIAL` e a rodada seguinte continua. Um 2º processo com o lock tomado sai `PULADO`.

## Os 3 estados
O que decide apagar e não respondeu **não vira "nada a limpar"**: df (statvfs), `/proc`, a varredura da raiz, o `keep.txt` (linha fora do alfabeto de nome é incerteza, não "ignoro a linha") e uma raiz que não é um `/tmp` (sticky e gravável por todos) dão `NAO-CONSEGUI` com o motivo no status, rc 2 e nada apagado. Falhar em gravar status ou log DEPOIS de apagar também é `NAO-CONSEGUI/escrever`, nunca `LIMPO`. Entrada que sumiu no meio da varredura não é erro.

## Instalar (Mayor, depois do merge)
```bash
mkdir -p ~/gt-remote/tmp-reaper
~/gt-remote/bin/hetzner-remote-git.sh pull gascity     # renova o espelho (o merge só chega a ele em ~5 min)
git -C ~/gt-remote/git/gascity/repo.git show origin/main:.gascity-gastown-hq/scripts/hetzner-tmp-reaper.py > ~/gt-remote/bin/hetzner-tmp-reaper.py.new \
  && chmod 755 ~/gt-remote/bin/hetzner-tmp-reaper.py.new && mv ~/gt-remote/bin/hetzner-tmp-reaper.py.new ~/gt-remote/bin/hetzner-tmp-reaper.py   # troca atômica
python3 -I ~/gt-remote/bin/hetzner-tmp-reaper.py --dry-run     # só lê (leva minutos: o teto é 540 s); confira kept (tmux e ssh-agent em excecao/em-uso) e reapable
( crontab -l | grep -v '# gt-tmp-reaper'; echo '*/10 * * * * flock -n /home/runner/gt-remote/tmp-reaper/cron.lock nice -n 19 ionice -c2 -n7 /usr/bin/python3 -I /home/runner/gt-remote/bin/hetzner-tmp-reaper.py > /dev/null 2> /home/runner/gt-remote/tmp-reaper/cron.err # gt-tmp-reaper (ga-d4iob2s)' ) | crontab -
```
`ionice -c2 -n7` (e não `-c3`): a classe ociosa pode não receber disco nenhum com o lastro ocupando o nó. O `cron.err` é sobrescrito a cada rodada (só guarda a última). **Rollback:** `crontab -l | grep -v '# gt-tmp-reaper' | crontab -` (nada mais a desfazer). Atualizar a cópia: repetir o `git show` (a troca é atômica; o cron nunca lê meia versão).

## Operar
- `~/gt-remote/tmp-reaper/status.json` = a última rodada (`result`, `reaped`, `kept` por motivo, `disk_pct`, `inode_pct`, `alerta`, e **`top`: os prefixos que mais vazaram**); `reaper.log` = uma linha por rodada, teto de 1 MB (vira `reaper.log.1`); um crash (rc 70) deixa `CRASH <erro>` nele, porque o `cron.err` é zerado a cada disparo.
- `result`: `LIMPO` · `PARCIAL` (acabou o tempo; normal nas primeiras rodadas com o atraso) · `ERROS` (uma unidade não apagou; nome em `falhou`) · `PULADO` · `NAO-CONSEGUI` (veja `motivo`).
- Segurar uma pasta: uma linha em `keep.txt`. À mão: `--dry-run` (não grava nada) e `--max-age-hours`.

## Alarme de disco e inodes
O vigia de ocupação do mini (`hetzner-occupancy-watch.py`, a cada 15 min) lê `df -P /` na MESMA ssh da CPU e avisa o Mayor por `gc mail send` quando o **disco passa de 90 %** ou os **inodes de 80 %** (limites estritos; `HETZNER_OCC_DF_DISK_PCT`, `HETZNER_OCC_DF_INODE_PCT`; cooldown de 6 h, `HETZNER_OCC_DF_COOLDOWN_S`). Mesma chave `hetzner-occupancy-alarm.on` dos outros avisos, mail que falha não gasta o cooldown, e o mail traz a última linha do `reaper.log` do nó (ou diz "sem registro"). Seção ausente ou linha que não confere: `disco.lido` false no JSONL, sem aviso e nunca "folgado". Vale na 1ª rodada do launchd depois que a árvore principal do mini tiver o script (o plist não mudou). Com o nó como está hoje (98 % e 92 %) o 1º mail sai logo.

## Quem vaza (para consertar na fonte)
O `top` do status e o log dizem quem mais vaza hoje; o mapa de 17/11 (linhas lidas em `origin/main` do espelho do nó; deslocam com o tempo):

| prefixo em /tmp | nasce em | conserto |
|---|---|---|
| `wo-selftest.*` | HQ `work-order.selftest.sh`: o trap só apagava via `safe-clean`, que não existe no nó | **feito nesta entrega** |
| 14 outros selftests do HQ | `git grep -l safe-clean -- '*.selftest.sh'` (mesmo cleanup condicionado ao `safe-clean`) | mesmo conserto |
| `chip_features_testes_*`, `pdpj_token_pytest_*` | WA `tests/conftest.py:309` (por chamada) e `:25` (no import: 1 por processo pytest, worker e mutante) | `tmp_path_factory` ou `TemporaryDirectory` com finalizador |
| `rota-vazia-test-*`, `ec_poller_*`, `ec_review_*` | WA `tests/test_painel_visibilidade.py:9112`, `test_email_companion_poller.py:42`, `test_email_companion_review.py:45` | `tmp_path` |
| `ec_stmt_*` | WA `lib/email_companion/poller.py:461` (código de produção) | apagar a pasta ao fim do uso |
| `wa_devlock_*_test_*` | WA `tests/test_central_sender_*.py` (módulo) | fixture de módulo com finalizador |
| `wa-leitor-*`, `wa-aprovador-*`, `wa-parear-*` | WA `tests/wa_leitor_athos/{servico,aprovacao,pareamento}.test.mjs` (`fs.mkdtempSync` sem `rmSync`) | `t.after(() => fs.rmSync(dir, { recursive: true, force: true }))` |
| `playwright_chromiumdev_profile-*`, `playwright-artifacts-*` | pastas **vazias**: lançamento que falha antes de o Chromium escrever (e2e sem browser no jail) | checar o executável antes de lançar |

Todos usam `tempfile`, `os.tmpdir()` ou `mktemp "${TMPDIR:-/tmp}/..."`, ou seja, honram `TMPDIR`. Os do WA pedem bead de WA (outro rig).

## A conta das 24 h
Aceite da bead: 24 h depois de ligado, `/tmp` com menos de 20 mil entradas e inodes < 60 %. Medir: `ls -f /tmp | wc -l` e `df -i /` (nunca `find /tmp` inteiro, nem `cd /tmp` antes de Python: `/tmp` com milhões de entradas faz o `import json` levar 10 s). Conta: o `/tmp` real tinha 35 mil entradas com menos de 12 h (~2,9 mil por hora, e uma rajada de 8 mil `wa_test_*` de uma só sessão); com 6 h o patamar é ~18 mil sem a rajada e ~26 mil com ela, na margem do aceite. Se passar de 20 mil, baixar para `--max-age-hours 3` na linha do cron (patamar ~17 mil) enquanto os vazamentos da tabela não são consertados. Inodes < 60 % depende de `claude-<uid>` ser limpo (4 a 13 milhões de inodes, medido por amostra de 60 projetos).

## Medido, inferido, não testado
- **Medido (17/11, só leitura):** a composição de `/tmp` (393 mil entradas de 1º nível, 393.072 do `runner` e 9 do `root`), a taxa de criação por hora, 2.687 de 2.758 projetos de `claude-<uid>` parados há mais de 6 h, o socket do tmux (`/tmp/tmux-1000/gc-remote`) e o do ssh-agent ligados e quietos, e um `--dry-run` real: 7 min, parou no teto de 420 s com 188 mil unidades julgadas, 174 mil apagáveis, 13,9 mil recentes e os de uso e de exceção como mantidos. Julgar rende ~450 unidades por segundo com `nice 19` e o nó a load 13; apagar, num teste sintético de 31 mil inodes com cache quente, ~21 mil inodes por segundo (um teto: o disco frio do nó será mais lento): as primeiras rodadas serão `PARCIAL`.
- **Testado** (`hetzner-tmp-reaper.selftest.sh`, hermético, `/proc` e relógio de mentira, 97 asserções, 28 mutantes do reaper e o controle de vida que prova que as mortes valem): idade pela árvore, ctime, dono, exceções, em-uso por cwd, fd, argv e socket, contêiner, link não seguido (também dentro da árvore), os 3 estados, teto de tempo, lock, log com teto, falha ao gravar status, identidade `mudou`, `ERROS`. `/proc` real (cwd de processo vivo e socket ligado) no caso 12; vigia: grupo `disco`, 23 casos e 5 mutantes (a suíte inteira 926/926 e o controle negativo 197/197).
- **Não testado:** o apagar de uma unidade com conteúdo de OUTRO dono dentro da árvore (só por mock: `ERROS`); uma montagem real (o teste usa um `/proc/mounts` de mentira); uma escrita funda numa unidade parada há mais de N h durante os segundos entre julgar e apagar (a reconferência olha só o topo); o alarme contra o launchd e o `gc mail` reais do mini (só os stubs do selftest); o efeito das 24 h (é o aceite); uma sessão que fique mais de N h sem escrever NADA no scratchpad perde o scratchpad (aceito: sessão de pool encerra em 15 min ocioso). **Limites conhecidos:** processo que não deixa ler o próprio `/proc/<pid>` (de outro dono, ou não-dumpable como os renderers do Chromium) não protege nada, e quem protege é a idade da árvore; a unidade em voo quando o tempo acaba tem o mtime mexido pela própria deleção e fica "recente" por N h (as outras saem inteiras).
- **O que falta:** beads de WA para a tabela acima; tirar a linha do `wa_test_*` do cron quando o reaper estiver estável; e, se o `top` mostrar que os selftests do HQ seguem vazando, um `TMPDIR` privado por selftest no `run-one.sh` do `hq-selftests` (não entrou aqui: muda o ambiente do lastro; o reaper e o censo já cobrem).
