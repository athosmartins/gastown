## Contents
- O que muda
- Validação
- Aplicar (janela do motor)
- Trade-off e botão

Item 4 da ga-esorlre.3: na retomada (`--resume`) o motor reenviava o prompt de partida inteiro (~89k chars, ~20k tokens por sessão) como nudge, duplicando a primeira mensagem da conversa que acabou de voltar.

## O que muda
`cmd/gc/session_lifecycle_parallel.go`, `restartPromptNudge`: quando a partida é uma retomada (`!firstStart && !forceFresh && hasResumeKey`), o nudge leva um aviso curto (`resumeNotice`) no lugar do prompt. `GC_STARTUP_PROMPT_DELIVERED=1` continua marcado (o prompt está na conversa retomada, `gc prime` não o imprime de novo). `GC_RESUME_FULL_PROMPT=1` no ambiente do supervisor volta ao comportamento antigo. Partida fresca não muda.

## Validação
- Base: engine `athosmartins/gascity` `origin/main` 8f1be0e2b3 (janela de 23/10). `git apply --check` passa nela, e `--reverse` na árvore já corrigida.
- No MBP (`mbp-run.sh --exec --go`, 12/11): `go vet ./cmd/gc/` limpo e `go test ./cmd/gc -run 'TestRestartPromptNudge|TestPrepareStartCandidate_Resume|TestAppendInitialMessage|TestPrepareStartCandidate_NoneMode'` PASS (3 testes novos: nudge curto sem o prompt, env restaura o antigo, `prepareStartCandidate` de sessão retomada com `--resume`, `PromptSuffix` vazio, nudge sem o prompt e env de entregue = 1). Os testes novos citam símbolos que a base não tem e afirmam que o prompt NÃO está no nudge, que a base inclui: reprovam nela.
- NÃO rodado: o pacote `cmd/gc` inteiro (só os testes acima); nenhum teste existente fixa o conteúdo do nudge de retomada, mas a suíte `phase2_*` confere o env de entregue, que o patch preserva.

## Aplicar (janela do motor)
Mayor-coordenado: `git apply` na árvore do motor, build, swap e bounce, pela doutrina. Este worker NÃO fez build nem swap.

## Trade-off e botão
Uma sessão retomada não recebe a doutrina nova se o prompt mudou desde a partida original: o aviso manda rodar `gc prime`. Se isso incomodar, `GC_RESUME_FULL_PROMPT=1` no supervisor.
