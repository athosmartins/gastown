## Contents

* Estado e o que falta
* Como rodar o plano · Regras de decisão
* Retrato medido em 16/10/2026 (os 21 jobs a embrulhar, os isentos, os não medidos)
* Achados
* Ativação em canário (passo separado) · Reverter
* Limites · Entrega

# Lista medida dos jobs que esperam o Dolt (ga-sh8t23.4)

## Estado e o que falta

**Entregue no repositório e testado; NÃO está vivo.** Nenhum plist foi alterado e nenhum job recarregado: o plano só lê. Falta (1) mergear o wrapper (ga-sh8t23.2) e esta fatia, (2) resolver a duplicata de label abaixo e (3) a ativação em canário, que é de quem coordena a cidade. Enquanto isso o boot continua como hoje. O wrapper está descrito em `docs/runbooks/wait-for-dolt.md`.

## Como rodar o plano · Regras de decisão

```bash
python3 -I $GC_CITY_PATH/scripts/wait-for-dolt-plan.py            # plano (só leitura): medição, política, antes/depois, divergências; exit 1 se houver divergência
python3 -I $GC_CITY_PATH/scripts/wait-for-dolt-plan.py --apply --only com.gascity.wisp-table-reaper   # canário; sem --only aplica os `wrap` todos
python3 -I $GC_CITY_PATH/scripts/wait-for-dolt-plan.py --revert [--only LABEL]
```

Lê `~/Library/LaunchAgents` (o que roda, não o repositório). Nunca chama `launchctl`. Selftest: `python3 -I scripts/wait-for-dolt-plan.selftest.py` (20 cenários + 37 mutantes). Decisões em `scripts/wait-for-dolt.policy.tsv` (`label<TAB>decisão<TAB>motivo`); o plano as confere contra a medição a cada execução e vira divergência (exit 1, `--apply` recusa) quando: job fora da política; `wrap` sem chamada medida, em KeepAlive ou sem `StartInterval`/`StartCalendarInterval` (estourado o prazo, o job só tentaria de novo no próximo boot); `isento`/`nao-medido` já embrulhado; `nao-medido` que mede LÊ; plist que não consegui ler (pode ser o gêmeo de um label `wrap` ou um job já embrulhado, e não sei qual).

* **Escopo**: label `com.gascity.*` ou `com.gastown.*`, `RunAtLoad`, programa fora da árvore de outro rig (esses viram bead no rig dele).
* **Medição** (evidência `arquivo:linha`): LÊ = o programa CHAMA `bd`/`gc`/`dolt` (posição de comando ou `subprocess`); mensagem de log, `jq`, comentário e texto entre aspas não contam. TALVEZ = só menção solta; NÃO ACHEI = programa lido, sem menção; ILEGÍVEL = não consegui ler (inclui o script executado direto ou citado no `-c` que não existe: nunca vira NÃO ACHEI). Posição de comando = início de linha, depois de ``; & | ( ` $( ! {``, das palavras de controle (`if elif else while until then do`) e de prefixos (`timeout` com `-k D`/`-s S`/`--kill-after`, `env`, `command`, `exec`, `nice`, `VAR=valor`). A linha de log (`echo`/`printf`/`log`) perde só o seu segmento: `echo ok; gc …` e `echo "$(gc …)"` contam. Quando o argv0 é um interpretador, o script do argv1 é lido.
* **Leitura corrigida (gate 2/3)**: a 1ª versão do leitor só aceitava `timeout N` sem opções e descartava a linha inteira que começasse por log, então dava como "sem chamada" 3 jobs que CHAMAM: `worktree-reaper` (`timeout -k G T gc … session list`, `.sh:498`), `git-maintenance-runner` (`if gc events rotate`, `.sh:49`) e `lifecycle-correctness-auditor` (`"$_bd"`/`"$_gc"`, alias de variável). Os três saíram de `nao-medido`: `worktree-reaper` e `lifecycle-correctness-auditor` viraram `wrap`, `git-maintenance-runner` `isento`. Cada forma tem fixture e mutante no selftest que falham no leitor antigo.
* **`wrap`**: o job só AVALIA dado de bead/sessão (varre, zela, reapa, mede fila). Sem Dolt não há o que avaliar, e uma leitura vazia ou com erro no boot é o risco que o wrapper tira.
* **`isento`**: (a) KeepAlive: o launchd relança sozinho, e o wrapper trocaria o respawn por uma espera de até o prazo; (b) ciclo de vida ou observador do Dolt (precisa rodar com o Dolt fora); (c) alarme/monitor de recurso com ato útil que não precisa do Dolt. **Na dúvida: isento** (= comportamento de hoje).
* **`nao-medido`**: nenhuma chamada a `bd`/`gc`/`dolt` achada no programa. Não segue script chamado por script.

## Retrato medido em 16/10/2026

455 plists, 248 com `RunAtLoad`, **74 no escopo HQ** (174 fora: outro rig ou outro label). Medido: LÊ=49 · TALVEZ=6 · NÃO ACHEI=18 · ILEGÍVEL=1. Política: **wrap=21** jobs (22 linhas na medição: um job está em 2 arquivos), **isento=31** (15 KeepAlive/ciclo de vida, 5 observadores do Dolt, 11 alarmes/monitores), **nao-medido=21**. Todos os 21 a embrulhar disparam por `StartInterval` (`I`), nenhum é KeepAlive. A leitura corrigida moveu 3 jobs (acima); o `git-lock-hygiene` segue `nao-medido`: o `gc rig list` dele está em outro script, que não é seguido.

| Job (com.gascity.) | Disparo | Chamada medida | Linhas de chamada |
|---|---|---|---|
| adhoc-session-reaper | I | `adhoc-session-reaper.sh:637` | 5 |
| crew-liveness-probe | I | `crew-liveness-probe.sh:149` | 9 |
| engine-refusal-strip-watchdog | I | `engine-refusal-strip-watchdog.sh:287` | 8 |
| funnel-flow-healer | I | `funnel-flow-healer.sh:112` | 3 |
| gate-focus-mode | I | `gate-focus-mode.sh:61` | 1 |
| gate-marker-missing-status-watchdog | I | `gate-marker-missing-status-watchdog.sh:156` | 3 |
| gate-merge-survival-sweep | I | `gate-merge-survival-sweep.sh:363` | 10 |
| gate-needs-human-divergence-sweep | I | `gate-needs-human-divergence-sweep.sh:224` | 8 |
| gate-orphaned-label-watchdog | I | `gate-orphaned-label-watchdog.sh:399` | 7 |
| gate-pilot-soak-monitor | I | `gate-pilot-soak-monitor.sh:160` | 2 |
| gate-reviewer-orphan-clear | I | `gate-reviewer-orphan-clear.sh:130` | 3 |
| gate-throughput-stall-watchdog | I | `gate-throughput-stall-watchdog.sh:373` | 8 |
| lifecycle-coherence-janitor ⚠ em 2 arquivos | I | `lifecycle-coherence-janitor.sh:144` | 30 |
| lifecycle-correctness-auditor | I | `lifecycle-correctness-auditor.sh:101` | 4 |
| merged-bead-janitor | I | `merged-bead-janitor.sh:917` | 29 |
| pilot-missing-route-watchdog | I | `pilot-missing-route-watchdog.sh:434` | 8 |
| reclaim-cap-escalation-sweep | I | `reclaim_cap_escalation_sweep.py:134` | 4 |
| suavez-first-watch | I | `suavez-first-watch.sh:19` | 2 |
| wisp-reaper | I | `wisp-reaper.sh:239` | 6 |
| wisp-table-reaper | I | `wisp-table-reaper.sh:64` | 1 |
| worktree-reaper | I | `worktree-reaper.sh:498` | 2 |

Antes/depois de cada um: rode o plano; ele imprime `antes` e `depois` do `ProgramArguments`. Exemplo (`wisp-reaper`): `["/bin/bash", "…/scripts/wisp-reaper.sh"]` vira `["…/scripts/wait-for-dolt.sh", "--timeout", "300", "--boot-window", "900", "--", "/bin/bash", "…/scripts/wisp-reaper.sh"]`; as demais chaves e a ordem delas não mudam.

Ensaio (feito com a leitura anterior, 19 jobs, numa CÓPIA dos plists vivos; nada vivo foi tocado): `--apply` reescreveu os 19, `plutil -lint` real aprovou 19/19, `--revert` devolveu 19/19 idênticos (dados e ordem das chaves); com a duplicata presente o `--apply` recusou sem escrever nada. NÃO repeti o ensaio com os 21 de hoje: o selftest cobre apply/revert em fixture, e os 2 jobs novos têm o mesmo formato de `ProgramArguments` (`["/bin/bash", script]`). Repita na ativação.

## Achados

* **Label em 2 arquivos (bloqueia o `--apply`)**: `com.gascity.lifecycle-coherence-janitor.plist` (24/06) e `lifecycle-coherence-janitor.plist` (22/06, nome sem prefixo) têm o MESMO Label. O launchd carrega um por label e não sei qual. Veja de qual veio com `launchctl print gui/$(id -u)/com.gascity.lifecycle-coherence-janitor` e arquive o outro (como no ga-j86sid).
* **Só 17 dos 115 plists com label HQ têm cópia no repositório** (11 iguais, 6 já diferem do vivo); 98 existem só em `~/Library/LaunchAgents`. O `--apply` altera o VIVO; o backup (`$GC_CITY_PATH/.gc/backups/wait-for-dolt-<data>/`) e a política são o registro.
* A reescrita do plist (plistlib) não preserva comentários XML; o backup guarda o original byte a byte.

## Ativação em canário (passo separado) · Reverter

1. Pré: `test -x $GC_CITY_PATH/scripts/wait-for-dolt.sh` e o plano com exit 0 (duplicata resolvida).
2. Canário: `--apply --only com.gascity.wisp-table-reaper`; recarregar: `launchctl bootout gui/$(id -u)/com.gascity.wisp-table-reaper; launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gascity.wisp-table-reaper.plist`; conferir `launchctl print gui/$(id -u)/com.gascity.wisp-table-reaper | grep -A9 arguments` (o wrapper vem primeiro) e que o log do job volta a andar com exit 0. Fora da janela de boot o wrapper é transparente: não deve haver linha `wait-for-dolt`.
3. Lote: `--apply` e recarregar um a um (a lista sai no `apply:`), com intervalo.
4. Prova no próximo boot noturno: `grep -h 'wait-for-dolt\[' <StandardErrorPath dos jobs>`: esperado `aguardando o Dolt` e `Dolt pronto … após Ns`; qualquer `NÃO ficou pronto` (rc 75) quer dizer Dolt que não subiu em 300 s no boot, achado por si só.
5. Reverter: `--revert` (ou `--only LABEL`) e recarregar do mesmo jeito.

## Limites · Entrega

* A política é julgamento revisado, não verdade medida; o plano só garante que ela bate com o que está vivo. Script que chama script não é seguido (por isso o `git-lock-hygiene`, que só enumera rigs por outro script, fica `nao-medido`). O alias de variável só é reconhecido pelo NOME (termina em `bd`/`gc`/`dolt`, ex.: `"$_gc"`, `$GC_BIN`); alias com outro nome não é visto, e a variável usada como argumento de função não conta como comando.
* O launchd só aceita o plist novo de fato no recarregamento; `plutil -lint` não prova isso.
* Se o wrapper sumir depois de aplicado, os jobs embrulhados não sobem: o plano acusa (divergência) pelo argv0 que está no PLIST, qualquer que seja o `--wrapper` da execução. "Embrulhado" é argv0 = `--wrapper` ou um `wait-for-dolt.sh` de qualquer caminho: outro caminho vira divergência (não se embrulha por cima; `--revert` tira). O `--apply` recusa wrapper que não executa ou sem o `dolt-pid-lib.sh` (com `dolt_server_pid`) ao lado.
* Plist que não consegui ler (ou de forma estranha: topo que não é dict, `Label` que não é texto) aparece com o motivo e é DIVERGÊNCIA: o plano sai 1 e o `--apply` recusa, porque ele pode ser o gêmeo de um label `wrap`. `--revert` lista o plist que não conseguiu ler (`NÃO LI`) e sai 1: não sei se está embrulhado. `--backup-dir` reaproveitado nunca sobrescreve o backup do original (falha daquele plist: use pasta nova para o revert). Falha ao escrever/criar backup é erro do plist, sem traceback, com o original intocado.
* Entrega: `scripts/wait-for-dolt-plan.py`, `scripts/wait-for-dolt-plan.selftest.py`, `scripts/wait-for-dolt.policy.tsv`, este runbook. Branch `feat/ga-sh8t23.4-wait-for-dolt-plan`.
