## Contents

* Estado e o que falta
* Para que serve · Uso
* Os três estados e os códigos de saída
* Janela de boot (por que o wrapper é transparente fora dela)
* Como foi verificado · Limites · Entrega

# wait-for-dolt (ga-sh8t23.2)

## Estado e o que falta

**Entregue no repositório e testado; NÃO está vivo.** Nenhum plist foi alterado e nenhum job foi recarregado. O wrapper só passa a valer quando um plist o puser na frente do comando e o job for recarregado (ou no próximo boot). Quem escolhe os jobs, mostra o antes/depois e aplica com backup é a fatia seguinte (ga-sh8t23.4, `wait-for-dolt-plan.py`); a ativação no launchd vivo é um passo separado, com canário. O que o wrapper assume dos plists: o caminho dele tem de ser o VIVO (`$GC_CITY_PATH/scripts/wait-for-dolt.sh`), não o de um worktree.

## Para que serve

Fatia 2 da ga-sh8t23 (revisão de arquitetura 15/10). No boot, ~227 plists com `RunAtLoad` sobem juntos (medido em 16/10) e o postcheck espera até 20 min por um "startup escalonado" que ninguém garante. Os jobs que leem o Dolt (bd/gc/dolt) concorrem com o servidor que ainda está subindo, e uma leitura que volta vazia ou falha porque o servidor não subiu é lida pelo job como "não tem" (erro e vazio dão o mesmo valor). O wrapper espera a sonda do `dolt-pid-lib.sh` (`dolt_server_pid`: executável `dolt` E socket LISTEN, nunca porta escrita em doc) e então faz `exec` do comando.

## Uso

```bash
wait-for-dolt.sh [--timeout SEG] [--boot-window SEG] -- COMANDO [ARGS...]
# no plist:  ProgramArguments = [ "$GC_CITY_PATH/scripts/wait-for-dolt.sh", "--timeout", "300", "--boot-window", "900", "--", "/bin/bash", "…/job.sh" ]
```

* `--timeout` 0-3600 (padrão 300; env `WAIT_FOR_DOLT_TIMEOUT`; a flag vence a env). Valor ilegível → padrão 300 e uma linha `AVISO` (ausente usa o padrão em silêncio).
* `--boot-window` 0-86400 (padrão 0 = sempre espera; env `WAIT_FOR_DOLT_BOOT_WINDOW`). Valor ilegível → 0 e `AVISO`.
* `WAIT_FOR_DOLT_POLL` (padrão 5 s, aceita decimal) e `WAIT_FOR_DOLT_LIB` existem para os testes.
* O log vai para o stderr, com o label do job (`XPC_SERVICE_NAME`): o launchd o leva ao `StandardErrorPath` do plist.

## Os três estados e os códigos de saída

| Estado | O que faz | rc |
|---|---|---|
| Dolt pronto | `exec` do comando (sem subshell: o rc dele é o rc do job). Silencioso se já estava pronto; se esperou, uma linha com o tempo | o do comando |
| Dolt não veio no prazo | NÃO roda; uma linha com o prazo e o tempo esperado | 75 |
| Sonda sem condição de saber (lib ilegível, sem `dolt_server_pid`, falta `ps`/`lsof`/`pgrep`) | NÃO roda, mesma saída inerte | 76 |
| Uso errado | nada roda | 64 |

A sonda que volta vazia, com erro ou com lixo que não é PID conta como "ainda não" e segue esperando até o prazo: nunca como pronto. Se o próprio comando devolver 64/75/76, é a linha de log que distingue.

## Janela de boot (por que o wrapper é transparente fora dela)

O wrapper fica no `ProgramArguments` de TODA execução do job, não só da do `RunAtLoad`. Sem limite, um alarme com `StartInterval` viraria mudo toda vez que o Dolt caísse no meio do dia (justo quando ele deveria falar), e cada tick pagaria um `lsof`. Com `--boot-window N`, passados N segundos do boot (`sysctl kern.boottime`) o wrapper faz `exec` direto, sem sondar e sem log: comportamento idêntico ao de hoje. Uptime que não consigo ler → trata como boot (espera o Dolt) e avisa; nunca como "já passou". `RunAtLoad` disparado por um `launchctl bootstrap` no meio do dia também cai fora da janela: o problema que isto resolve é a debandada do boot.

## Como foi verificado

* `bash scripts/wait-for-dolt.selftest.sh`: 19 casos + 9 mutantes, hermético (a lib de verdade, `ps`/`lsof`/`pgrep`/`sysctl` de mentira, um `sleep` como "dolt"), rodando no `/bin/bash` 3.2.57 do macOS. Cada guarda tem a marca `GUARD:` no script; a suíte adultera cada uma (sed numa cópia) e o caso que a cobre TEM de reprovar. Contra o HEAD anterior (script inexistente) a suíte reprova.
* Contra o Dolt VIVO (16/10): `wait-for-dolt.sh --timeout 20 -- /bin/echo ok` → rc 0 em 0,5 s, pela sonda e pela lib reais.

## Limites

* "Pronto" é o que a sonda diz (processo `dolt` com socket LISTEN), não "respondeu uma consulta".
* A espera pode passar do prazo por um intervalo de sondagem mais uma sondagem; sem `timeout` do coreutils no PATH do launchd não dá para limitar o `lsof`.
* Se o arquivo do wrapper sumir, todo job embrulhado deixa de subir. A fatia .4 traz o detector (o plano acusa "plist embrulhado com wrapper ausente") e o `--apply` recusa apontar para um wrapper que não executa.

## Entrega

`scripts/wait-for-dolt.sh` (108 linhas, 65 de código), `scripts/wait-for-dolt.selftest.sh`, este runbook. Branch `feat/ga-sh8t23.2-wait-for-dolt`. A entrega inteira da .2 (wrapper + plano medido + política + apply/revert) passou do teto do gate E11 (800 de produção, 1000 no total, selftest e runbook contam no total), por isso o plano foi para a ga-sh8t23.4.
