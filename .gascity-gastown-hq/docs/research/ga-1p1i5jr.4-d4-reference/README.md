## Contents

- O que é isto · O que a fatia 3/3 (ga-1p1i5jr.4.2) deve fazer

# Material de referência da fatia 3/3 do D4 (ga-1p1i5jr.4.2)

## O que é isto

Branch de trabalho (não passa pelo gate; não mergear). Guarda o que NÃO coube nas duas primeiras submissões do D4 (teto do gate: 1000 linhas no total):

- `selftest.full.sh` — o selftest COMPLETO da primeira versão do D4 (528 linhas). Já passou 339/341 (as 2 falhas eram de uma afirmação errada sobre o -wal/-shm, corrigida na fatia 1/3). **Atenção, ele é da versão ANTERIOR do D4**: usa `attempt_ts` no estado (hoje a espera de 30 min usa `defer_until`), `lock_nopid`/`lock_new` (a lógica de mtime da trava saiu) e o registro `disk-recovery-d4-reboot-*.txt` (saiu). Adapte, não copie.
- `runbook-disco-d4-reinicio-guardado.md` — runbook para o operador (como ver o que ele decidiu, desligar, as guardas, o que não foi provado). Revise as frases sobre `attempt_ts`/registro de reinício antes de publicar.

## O que a fatia 3/3 deve fazer

Depois que ga-1p1i5jr.4 (o D4) e ga-1p1i5jr.4.1 (o leitor de ligações) estiverem mergeadas, uma submissão só de TESTE + DOC (sem mudar o D4), em branch nova a partir de origin/main, acrescentando ao `disk-recovery-d4-guarded-reboot.selftest.sh`:

1. **Integração com o leitor REAL** (a fatia 2/3 usa um stub): dry-run feliz com bancos WAL de mentira (o `mkfix` do `disk-recovery-d4-calls-in-flight.selftest.sh`), bloqueio com `dialing` recente, `unknown` com banco ausente.
2. Pré-checagem extra: FileVault em cifragem, fdesetup com texto novo, `defaults` com erro estranho, autoLoginUser vazio, launchctl com rc diferente de 113, usuário do console ilegível, osascript ausente sem stub, pré-checagem também no dry-run.
3. Estado: versão desconhecida (`v=2`), lista com elemento vazio, número gigante, estado que é um diretório, chave desconhecida ignorada; `boottime` ilegível; `cap_old` (2 reinícios com mais de 24 h podem de novo).
4. Números ruins no ambiente (`DR4_MB=abc` cai no padrão e o log diz), sentinela do scraper DUPLICADA no noturno.
5. O runbook em `docs/runbooks/` (já com `## Contents`).

Rode a bateria de mutantes de novo contra o D4 mergeado (a lista e o harness estão descritos nos comentários da bead ga-1p1i5jr.4) e confira o tamanho: a submissão tem de ficar abaixo de 1000 linhas.
