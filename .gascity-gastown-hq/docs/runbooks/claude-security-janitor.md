# Faxineiro do plugin security-guidance (claude-security-janitor) · runbook

## Contents

• O que é · O que apaga e o que nunca apaga · Instalar (Mayor, depois do merge) · Provar · Medido, inferido, não testado

Bead ga-j4r9o8 (achado do Mayor, 19/10). **Mergeado ≠ vivo: nada aqui está instalado** — o `.plist` só passa a valer depois do `launchctl bootstrap` abaixo.

## O que é
`scripts/claude-security-janitor.py`, a cada ~1 h pelo launchd do mini (`com.gascity.claude-security-janitor.plist`, `StartInterval` 3593). Duas partes independentes; uma que falha não pula a outra:
- **Arquivos de estado:** apaga `~/.claude/security/security_warnings_state_*` terminados em `.json`, `.lock` ou `.tmp` (os três formatos que o plugin cria) com mtime > 3 dias. O próprio plugin só apaga com > 30 dias (`session_state.py`, `cleanup_old_state_files`), o que dá ~10 mil arquivos e ~55 MB/dia.
- **Resíduo de pip:** apaga `pip-{unpack,metadata,install,ephem-wheel-cache,build-tracker}-*` no temp do usuário (`getconf DARWIN_USER_TEMP_DIR`) com mais de 2 h **e** nenhum pip vivo. É o resto do laço de reinstalação do venv do hook (381 pastas / 797 MB em 19/10).

A checagem de que o python do hook ainda tem `claude_agent_sdk` (com alarme por `notify`), da mesma bead, vem numa fatia seguinte, empilhada nesta.

## O que apaga e o que nunca apaga
Toda leitura tem três saídas — tem / não tem / não consegui saber — e "não consegui saber" cai sempre no estado inerte:
- **Diretório que não lista** (ou que morre no meio da listagem): não apaga nada, a parte termina INCOMPLETA (saída 1). Diretório que não existe = "absent" (nada a limpar, saída 0).
- **`ps` que falha ou volta vazio:** mantém todas as pastas de pip. Um pip vivo também mantém todas, mas isso **não** é erro (tenta de novo na próxima rodada). "Pip vivo" é só linha de comando que **começa** como `pip`, `<python> … -m pip|ensurepip` ou `<python> … ensure_agent_sdk.py`: um agente cujo argv apenas cita "pip install" não congela a limpeza, e `pipedrive_*` nunca casa.
- **Nunca toca:** symlink, nome parecido (`…json.bak`, `xsecurity_warnings_state_…`), diretório com nome de arquivo de estado, `log.txt`, `agent-sdk-venv/`, `agent-sdk-venv.cooldown`, `.sdk_bootstrap_spawned`, `review_model.json`. Arquivo cujo mtime ou inode mudou entre a listagem e o `unlink` (sessão acabou de escrever) fica.
- **Depois do `rmtree`** olha o caminho de novo: sumiu = apagado; ainda lá = PARCIAL; outro erro = NÃO VERIFICADO (os dois últimos fecham a parte INCOMPLETA).
- **Sentinela de produção** (mesma ideia do `claude_home_trim.py`): o `~/.claude/security` real e o temp real só sofrem dry-run sem `CLAUDE_SECURITY_JANITOR_PROD=1`. O plist liga; um teste ou rodada à mão que esquece de apontar para fixture não apaga arquivo real.
- Uma instância por vez (`flock`); quem perde sai com 0.

## Instalar (Mayor, depois do merge)
```bash
cd /Users/athos/gt/.gascity-gastown-hq
python3 scripts/claude-security-janitor.py --dry-run        # 1 rodada de verdade; nada apagado, nada enviado
launchctl bootout gui/$(id -u)/com.gascity.claude-security-janitor 2>/dev/null
cp scripts/com.gascity.claude-security-janitor.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gascity.claude-security-janitor.plist
launchctl kickstart gui/$(id -u)/com.gascity.claude-security-janitor   # 1ª rodada real agora
tail -5 .gc/logs/claude-security-janitor.out
launchctl print gui/$(id -u)/com.gascity.claude-security-janitor | grep -E 'state|runs|last exit'
```
Desligar: `CLAUDE_SECURITY_JANITOR_ENABLED=0` no plist (ou `launchctl bootout`). O `claude-security-janitor.py --dry-run` à mão é sempre seguro.

Opcional (não feito aqui): registrar no `daemon-presence-watchdog.sh` uma linha de heartbeat `com.gascity.claude-security-janitor|$HQ/.gc/logs/claude-security-janitor.out|10800` (3× o ritmo) — a rodada escreve no `.out` toda vez. Fica de fora porque a falha deste job não derruba nada (os guardas de disco FG e DPM seguem de pé) e o arquivo compartilhado tem selftest próprio.

## Provar
```bash
bash scripts/claude-security-janitor.selftest.sh                 # 94 checagens, ~15 s
CSJ_MUTANTS=1 bash scripts/claude-security-janitor.selftest.sh   # + 9 mutantes; todos têm de FALHAR a bateria
```
Fixture inteira em diretório descartável (HOME, `~/.claude/security`, temp e trava falsos; `ps` é stub): nada chega à cidade nem ao `~/.claude` de verdade. O bloco em Python injeta o que um subprocesso não alcança (arquivo reescrito entre listar e apagar, `unlink` que falha, listagem que morre no meio, `rmtree` que deixa a pasta, olhada posterior que falha). Cada mutante é uma cópia com uma regra quebrada de propósito (idade invertida, `ps` que falhou lido como "sem pip", diretório ilegível lido como vazio, regex de pip sem âncora, symlink seguido, sentinela removida, …) e só conta como morto se a bateria imprimir qual checagem o pegou.

## Medido, inferido, não testado
- **Medido (19/10, ~14:40, load 44):** `--dry-run` nos diretórios reais: 3.118 arquivos de estado (41,0 MB) com > 3 dias, 6.925 mais novos; 55 pastas `pip-*`, todas de 14:10–14:19 (nenhuma depois da correção do Mayor: o laço parou), então ficam elegíveis só ~16:10–16:19; rodada de 5,6 s de relógio, 0,12 s de CPU (medida com a versão completa, que já trazia a checagem do SDK da fatia seguinte). Selftest: 94 checagens / 9 mutantes mortos, 15 s local.
- **Inferido do código do hook, não observado ao vivo:** os formatos de linha de comando do pip no `ps` (as linhas do selftest vêm de `ensure_agent_sdk.py` e do `venv`, não de uma captura real); que apagar o estado de uma sessão viva parada há > 3 dias é inofensivo (`load_state` trata arquivo ausente como estado vazio; o pior caso é um aviso já mostrado aparecer de novo uma vez).
- **Não testado:** carga real pelo launchd; a rodada real que apaga os ~3 mil arquivos (só o dry-run foi feito nos diretórios reais); `getconf DARWIN_USER_TEMP_DIR` fora do macOS (sem resposta, o script usa `$TMPDIR` e o trata como o temp real: dry-run sem `CLAUDE_SECURITY_JANITOR_PROD=1`, que o plist liga).
