# Provider gc-session-ssh · runbook

## Contents

• O que esta fatia é — e o que não é · Como ligar (config, city.toml, janela do engine) · Operações
• Teto do host e o MBP · Quando o ssh não responde · Medido, inferido, não testado · Pontos em aberto · Limites

Bead ga-2hd02v.1.1 (fatia 2 do ga-2hd02v, desenho do estudo ga-ukxa3k, aprovada por Athos em 14/10 18:42). **Entrega duas peças:** (1) `scripts/gc-session-ssh`, o provider no protocolo `exec:` do engine, que abre as sessões de pool num host remoto por ssh com a mesma interface das locais; (2) um patch do engine, `docs/pending-engine-window/ga-2hd02v-hybrid-remote-exec.patch`, que deixa o provider híbrido usar esse script como lado remoto. **O patch NÃO está aplicado**: nada foi compilado, trocado nem reiniciado em produção. Sem o patch o script já funciona sozinho (`GC_SESSION=exec:<cidade>/scripts/gc-session-ssh` serve um teste isolado), mas só o patch deixa a cidade rodar sessões locais e remotas juntas.

**Esta fatia não instala nada no servidor.** O provider só usa o que lá já existe (`tmux`, `sh`, `base64`, `awk`, `ps`, `mktemp`). `claude` e `node` no servidor são da fatia .1.4; os shims `bd`/`gc`/`gate-done`, da .1.2; o espelho git e os worktrees remotos, da .1.3; endurecimento, da .1.5. Nenhum dado de lead/cliente, backup de bead ou credencial de GitHub vai para o servidor: o provider manda só o comando, o ambiente `GC_*` e o prompt de partida do agente.

## Como ligar

**1. Config do host** — `<cidade>/.gc/session-ssh.json` (ou `$GC_SSH_CONFIG`). Não existe padrão para o teto: sem `cap` o provider não abre sessão.

```json
{"default_host": "hetzner",
 "hosts": {
  "hetzner": {"ssh": "hetzner-teste", "cap": 4,
              "remote_root": "/home/runner/gt-remote/bundle", "remote_home": "/home/runner"}}}
```

| chave | obrigatória | para quê |
|---|---|---|
| `ssh` | sim | alias/destino do ssh (o mesmo `hetzner-teste` do `mbp-run.sh`; chave e usuário vêm do `~/.ssh/config`) |
| `cap` | sim, inteiro ≥ 1 | teto de sessões **deste host**, contado só no tmux do provider |
| `remote_root` | sim | o `--remote-root` que o `remote-bundle-build.py` usou; as sessões rodam sob `<remote_root>/city` e `<remote_root>/work` |
| `remote_home` | sim | o `--remote-home` do mesmo build |
| `socket` | não (`gc-remote`) | nome do socket do tmux no host (`tmux -L`): só as sessões deste provider existem nele |
| `mini_home` | não (`~`) | home do mini, para reescrever `~/…` em `remote_home` |
| `connect_timeout`, `timeout`, `start_timeout` | não (10, 25, 60 s) | prazos; o `start` leva `start_timeout` |
| `env_allow` | não | nomes de variável com cara de segredo que PODEM ir (ver abaixo) |
| `ssh_opts` | não | opções extras do ssh (`["-p","2222"]`) |

O host vem de `$GC_SSH_HOST` ou de `default_host`. Estado no mini: `$GC_EXEC_STATE_DIR` ou `<cidade>/.gc/runtime/session-ssh/<host>/` (`session-ssh.log`, `lock`, `meta/`).

**2. Ver o que um `start` faria, sem conectar:**

```bash
gc-session-ssh --dry-run start dog-1 < start.json     # ou GC_SSH_DRYRUN=1
```

Imprime o JSON com `command`, `work_dir`, `env`, `env_dropped`, `ignored`, o lançador, o `tmux new-session` e o `ssh` que seriam usados.

**3. Ligar no engine (só depois da janela do engine que aplica o patch).** No `city.toml`:

```toml
[session]
provider     = "hybrid"
remote_match = "-remote-"                                  # sessão cujo nome contém isto vai para o host
remote_exec  = "/Users/athos/gt/.gascity-gastown-hq/scripts/gc-session-ssh"
```

`GC_HYBRID_REMOTE_MATCH` e `GC_HYBRID_REMOTE_EXEC` valem mais que o `city.toml`. Sem `remote_exec` o híbrido segue como antes (lado remoto = K8s). **Mudar `[session] provider` é uma decisão separada desta fatia** (a cidade hoje usa o tmux padrão): o Mayor liga quando a .1.2–.1.4 estiverem prontas, porque sem `claude` no servidor uma sessão remota abre e cai.

## Operações

Cada operação é **um ssh** (ControlMaster em `~/.ssh/cm`, o mesmo do `mbp-run.sh`), com o script de shell indo pela entrada padrão. A resposta vem entre `@@GC-BEGIN@@`/`@@GC-END@@`: ruído de `.bashrc` não vira dado e resposta cortada é erro.

| operação | o que faz no host |
|---|---|
| `start` | **numa só execução**, sob `flock` no mini: confere que a sessão não existe, confere o teto, cria o diretório, grava o lançador, `tmux new-session -d`, espera 1 s e confirma que a sessão ficou de pé (senão devolve o motivo: `comando não encontrado`, `saiu com N`) |
| `stop` | mata a árvore de processos do painel, `kill-session`, apaga lançador e meta; idempotente |
| `interrupt` | `Ctrl-C` na sessão |
| `is-running`, `process-alive`, `get-last-activity` | `true`/`false`; `process-alive` procura os nomes na árvore do painel; atividade em RFC3339 |
| `nudge` | texto por `load-buffer`/`paste-buffer -p` + Enter (qualquer tamanho, aspas e quebras de linha) |
| `send-keys`, `peek`, `clear-scrollback` | como no tmux local |
| `list-running <prefixo>` | nomes das sessões do provider. **ssh fora = erro (exit 1), nunca lista vazia**: o engine trata erro como lista parcial e não decide nada com base num “vazio” falso |
| `set-meta`, `get-meta`, `remove-meta` | ficam **no mini** (`<estado>/meta`); nada de meta vai para o servidor |
| `attach` | `ssh -t … tmux attach` |
| `check-image`, `copy-to`, `watch-startup`, `run-live` e qualquer operação desconhecida | **exit 2 (“não suportado”)**, sem abrir ssh, sem ler a entrada, sem tocar em sessão |

### O comando do `start` é o mesmo do local

O provider repassa o `command` que o engine montou (`--settings <cidade>/.gc/settings.json`, `--dangerously-skip-permissions`, `--model`, `--remote-control` quando pedido, e o `--settings {"remoteControlAtStartup":false}` das sessões headless), só reescrevendo caminhos do mini com **as mesmas regras do `remote-bundle-build.py`** (mesma fronteira de palavra): `<cidade>` → `<remote_root>/city`, `~/gt` → `<remote_root>/work`, home → `remote_home`, e `<cidade>/.gc/settings.json` → `<remote_root>/city/settings.json`, onde o bundle o instala. Se sobra `/Users/` no comando, no diretório de trabalho ou no ambiente depois da reescrita, o `start` **recusa** (uma sessão assim cairia no primeiro uso).

O **prompt de partida** também vai (campos `prompt_suffix` e `prompt_flag` do JSON do `start`, que o patch do engine acrescenta; o provider exec original não os levava, então uma sessão rodada por script ia começar sem o prompt do papel). Prompts de dezenas de KB com aspas, `$(…)` e crase chegam íntegros e nada deles é executado: o lançador temporário recebe o texto como um único argumento e se apaga ao rodar.

**Ambiente.** Só `GC_*`, `TERM`, `LANG`, `LC_*`, `TZ`. O que tem cara de segredo (`TOKEN`, `SECRET`, `PASSWORD`, `KEY`…) **não vai**, a menos que o nome esteja em `env_allow`; o `start` registra no log os nomes descartados (nunca os valores). Em particular, `GC_INSTANCE_TOKEN` não é enviado por padrão: é decisão da fatia .1.2 (shims) se o servidor precisa dele.

**O que o `start` NÃO faz** (cada item é de outra fatia ou é recusa de propósito; o que for pedido e ignorado aparece em `ignored` no dry-run e no log): `pre_start`, `session_setup*`, `session_live`, `pack_overlay_dirs`/`overlay_dir`, `copy_files` e `nudge` do JSON do start (o provider exec do engine também não entrega este último: quem entrega é o `Nudge` depois do `start`).

## Teto do host e o MBP

O teto é **por host e contado à parte do teto do mini**: a contagem é `tmux -L <socket> list-sessions` do próprio host, no mesmo script que cria a sessão, sob `flock`. O teto N aceita N sessões e recusa a N+1 com `host H está no teto: N de N sessões` (exit 1); “já existe” sai como `session X already exists`, que o engine converte em `ErrSessionExists`. O teto do mini não muda.

**O MBP (ga-w7qwl1) reaproveita o provider** sem código novo: outra entrada em `hosts` (outro `ssh`, outro `cap`, outro `remote_root`) e outra instância do provider com `GC_SSH_HOST=mbp`. Cada host tem o seu estado em `<estado>/<host>/` e a sua contagem.

## Quando o ssh não responde

Medido nas duas formas (porta fechada, e script com `ssh` falso que não responde): o `start` **não abre sessão**, sai com exit 1 e a mensagem diz o host e o motivo (`ssh para o host H (alvo) falhou: … Connection refused` ou `não respondeu em Ns por ssh`); a linha vai também para `<estado>/<host>/session-ssh.log`. Nada fica pela metade (nem sessão, nem lançador). `list-running`, `is-running` e `stop` também saem com erro em vez de fingir que a lista está vazia, que a sessão caiu ou que parou. O mini e o Pilot não são afetados: cada chamada é um processo curto que só depende do próprio ssh e do prazo (`timeout`).

## Medido, inferido, não testado

**MEDIDO**
* Servidor `hetzner-teste` (14/10, ssh de verdade): Linux 6.8.0-138, `tmux 3.4`, `base64 awk ps sh mktemp` presentes; `claude` e `node` seguem ausentes (fatia .1.4).
* O provider rodado de verdade contra o `hetzner-teste` com um socket de tmux de teste, `cap` 1 e um `cat` como “agente”: `start` (1,8 s no total, 1 s dele é a espera de confirmação), `list-running`, `is-running`, `nudge` (o texto apareceu no `peek`), `peek`, `send-keys`, `interrupt` (o `Ctrl-C` encerrou o `cat`; num `sh` com `trap INT` apareceu `GOT-INT`), `process-alive` verdadeiro e falso, `get-last-activity` em RFC3339, o 2º `start` recusado pelo teto, o mesmo nome recusado como `already exists`, `stop` e lista vazia depois. O ControlMaster com `ControlPersist` não travou o `capture_output`. Terminado o teste, o diretório de teste do servidor foi removido e o socket do tmux também; nada ficou lá.
* ssh que falha (porta fechada em `127.0.0.1`): `start` e `list-running` saem 1 com o motivo, e o log registra.
* `scripts/gc-session-ssh.selftest.sh` (hermético: ssh falso que roda no próprio mini, tmux num `TMUX_TMPDIR` de teste, nunca o tmux de verdade): 93 casos, também sob o Python 3.9 do sistema. Controle negativo: 9 mutantes (teto, nome exato da sessão, alvo de painel `=nome:`, guarda de `/Users/`, filtro de ambiente, exit 2 das desconhecidas, marcador de fim, exit 255 do ssh, `flock`) — cada guarda removida faz o grupo que a cobre falhar —, e um stub que só sai 0 reprova quase tudo.
* **Patch do engine** (`docs/pending-engine-window/ga-2hd02v-hybrid-remote-exec.patch`, base `08d7ef788`): `git apply --check` passa num checkout limpo da base e na árvore-fonte `_src-hookfix` (somente leitura); 34 linhas de código de produção (`cmd/gc/providers.go`, `internal/config/config.go`, `internal/runtime/exec/json.go`), o resto são testes e docs. Testes novos, **reprovados no HEAD anterior**: no HEAD sem o patch eles nem compilam (`RemoteExec` não existe) e `TestMarshalStartConfig_promptFields` falha (`prompt_suffix = <nil>`); com SÓ o campo da config acrescentado (sem a lógica) os dois testes do híbrido falham por comportamento, com `hybrid: k8s backend: building K8s config: invalid configuration` — ou seja, sem a lógica o lado remoto continua sendo K8s. Com o patch, passam: `TestNewHybridProvider_RemoteExec*` (2), `TestMarshalStartConfig_promptFields`, `TestParseSessionRemoteExec`, e os pacotes `internal/runtime/exec` e `internal/runtime/hybrid` inteiros (`go test`, num worktree de rascunho; nada de `go build` de produção). Numa rodada do pacote `exec` com a máquina em load ~110, dois testes antigos de `watch-startup` estouraram o prazo; sozinhos passam (0,8 s e 1,4 s) e o pacote inteiro passa com o load em ~70.
* O `genschema` do engine regenerou também campos que o schema commitado já não tinha (`session_spawn_stagger`, `auto_gc_enabled`, `requires_attached_session`, e o `cli.md`/`pack-schema`); o patch leva **só** `remote_exec` nos arquivos gerados, para não misturar outra mudança.
* Achados do selftest corrigidos no próprio provider: `list-running` imprimia uma linha em branco quando não havia sessões; alvos de painel do tmux precisam de `=nome:` (com `=nome` o `capture-pane` e o `send-keys` dizem `can't find pane`).
* Um ambiente com `GC_INSTANCE_TOKEN` herdado vazava para as sessões de teste pelo tmux do “servidor” (que no teste é a própria máquina); o selftest passou a limpar o `GC_*` herdado.

**INFERIDO** (do código do engine, sem rodar o engine novo)
* Depois do `start`, o engine tenta `watch-startup` (exit 2 → cai no `peek`/`send-keys`) para dispensar diálogos de partida do claude: o `peek` e o `send-keys` deste provider cobrem isso, mas **não foi visto um claude real passar por aí no servidor**.
* No híbrido, o erro de `list-running` do lado remoto entra como lista parcial (`MergeBackendListResults`): por isso o exit 1 e não a lista vazia.

**NÃO TESTADO**
* Qualquer sessão com `claude` de verdade no servidor (não há `claude` lá).
* O patch do engine rodando numa cidade viva, e um `claude` de verdade chegando ao servidor por um `gc` com o patch aplicado (só `go test` dos pacotes em worktree de rascunho, com um script de mentira no lugar do provider).
* Linux diferente do `hetzner-teste` (tmux < 3.4, shell de login diferente do bash).
* Carga: mais de uma dezena de operações simultâneas contra o mesmo host.

## Pontos em aberto

1. **Wrapper do claude.** O `command` das sessões headless começa por `<cidade>/packs/town-deltas/assets/scripts/claude-ctxcap-ab.sh` (cadeia ctxcap → lowprio → claude). Reescrito, ele aponta para `<remote_root>/city/packs/...`, que **não existe no servidor** até a .1.3 (ou uma decisão de usar `claude` direto lá). O `start` não deixa passar em branco: o lançador confere a 1ª palavra do comando e a sessão cai com `comando não encontrado: …`.
2. **`GC_INSTANCE_TOKEN`** não vai por padrão (acima): a .1.2 decide.
3. **`nudge` dentro do `start`** não é entregue (nem pelo provider exec do engine).
4. **`nudge` não espera o agente ficar ocioso**: cola e dá Enter. O Nudge “wait-idle” do engine continua sendo quem decide o momento.
5. **Um soluço do ssh** faz `is-running` sair 1, e o engine lê esse erro como `false` (lido no código do `exec.go`, não observado). O `list-running` parcial evita que uma queda vire “sessão sumiu” em massa, mas é possível — INFERIDO, não medido — que o reconciliador trate uma sessão que um soluço mostrou parada como caída. Se aparecer, o remédio é um prazo/tentativa maior no `is-running` do provider, não uma mudança no engine.
6. `ask: Bash(rm -rf:*)` e os scripts `keep` do bundle seguem sem teste em Linux (ponto herdado do runbook da fatia 1).

## Limites

* Produção: **nada foi aplicado ao engine**. O patch está só em `docs/pending-engine-window/` e o Mayor agenda a janela (aplicar com `git apply`, `go build`, trocar o binário, reiniciar o supervisor — nesta ordem e só lá).
* Código de produção: o provider tem 466 linhas e o patch do engine 34 (o resto do patch são testes e docs): ~500, abaixo das 800 do gate E11.
* Um ssh por operação: para dezenas de sessões o custo é o do ControlMaster (reaproveitado), não de uma conexão nova por chamada.
