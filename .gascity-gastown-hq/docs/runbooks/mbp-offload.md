# MBP como nó de capacidade (offload de testes e REA/APK)

## Contents
- Por quê e resultado medido · Como ligar e desligar · Como usar · Códigos de saída · O que mora no MBP · Manutenção · Limites conhecidos

## Por quê e resultado medido (11/10/2026)
O mini vive com load 40-60, swap alto e o Dolt único; o MacBook Pro (16 GB, 12 CPUs, ~130 GB livres) estava ocioso.

| Medida | Mini (carregado) | MBP via `mbp-run.sh` |
|---|---|---|
| 231 testes de lot_groups (11 arquivos) | 340 s de relógio (213 s só de testes, `nice 15`) | 11 s de relógio (4,5 s de testes) |
| 20 testes do property_scrapers | 6,4 s | 5,7 s (sem ganho: teste leve) |
| REA `analyze-javascript-application` do Bitwarden (asar de 50 MB) | falhou 2× (timeout do helper Swift e `provider_timeout` sob load 50) | rc 0 em 75 s, evidência de 12,8 MB |

O ganho vem de rodar o que é pesado (testes grandes, REA/Ghidra/Java, APK) fora do mini. O que NÃO sai do mini: Dolt, fila do Pilot, polling do `gc`/`bd`, daemons de produção.

## Como ligar e desligar
A chave é o arquivo-bandeira `$CITY/.gc/mbp-offload.on` (CITY=`/Users/athos/gt/.gascity-gastown-hq`).
```bash
scripts/mbp-offload.sh on        # liga
scripts/mbp-offload.sh off       # desliga: mbp-run.sh sai 99 e todo mundo roda local
scripts/mbp-offload.sh status    # estado, saúde do MBP e últimas 5 execuções
scripts/mbp-offload.sh status --json   # insumo do botão do painel (bead própria, mockup antes)
```
Sem daemon nem launchd. O botão do painel só chama este script.

## Como usar
```bash
# testes dirigidos (NUNCA a suíte inteira) — repo wa ou ps, worktree = diretório atual por padrão
scripts/mbp-run.sh --repo wa --dir <worktree> -- tests/test_x.py tests/test_y.py -q
# comando pesado (REA/APK): roda em ~/gt-remote/exec/<slot>, scratch apagado no fim
scripts/mbp-run.sh --exec --push /caminho/app.asar --pull out.json:/scratch/ -- \
  sh -c 'rea analyze-javascript-application in/app.asar --integrity-policy record-and-continue --json > out.json'
scripts/mbp-run.sh --check       # saúde do MBP
scripts/mbp-run.sh --seed wa|ps  # (re)semeia base + site-packages (com checagem de hash)
```
Quem chama trata rc 96..99 como "rode local", nunca como teste reprovado.

## Códigos de saída
0..95 = rc do pytest/comando remoto (propagado) · 99 offload desligado · 98 MBP indisponível ou sem saúde (ssh > 5 s, RAM livre < 3 GB, swap usado >= 5 GB, bateria <= 40% sem tomada, ou ssh caiu no meio) · 97 configuração (uso errado, base ausente → `--seed`) · 96 três slots ocupados.
Limiares ajustáveis por ambiente: `MBP_MIN_AVAIL_MB`, `MBP_MAX_SWAP_MB`, `MBP_MIN_BATT`, `MBP_MAX_SLOTS`, `MBP_RUN_TIMEOUT_S`.

## O que mora no MBP (`~/gt-remote`)
- `whatsapp_automation/`, `property_scrapers/`: árvores-base (sem .git, venv, shared/data, *.db, logs, .beads…).
- `mirror/<repo>-<slot>/`: um espelho por slot (clone APFS da base na 1ª vez, depois `rsync --delete` do worktree do chamador).
- `venv/` (WA, python3.14) e `venv-ps/` (PS, python3.11): site-packages copiados do mini (um `pip install` novo falha em `Levenshtein`); hash em `.sp-hash`.
- `slots/N`: trava por `mkdir`; dono = `host:pid:epoch`; dono morto ou idade > 4 h é liberado por quem chega.
- `exec/N`: scratch do modo `--exec`, apagado no fim (capturas de REA nunca ficam).
- `rea/`: REA 6.4.0 instalado com Node 22 (`brew install node@22 ghidra`, ghidra/openjdk@21/node@22 fixados com `brew pin`). O Node 25 do MBP não serve ao REA (exige 22.19+, 24.11+ ou 26+).
- Log das execuções: `$CITY/.gc/logs/mbp-run.jsonl` (ts, repo, modo, slot, rc, segundos).

## Manutenção
- Reseed noturno com hash (bead própria): `mbp-run.sh --seed wa; mbp-run.sh --seed ps`.
- `rea update` no MBP só por bead que revisa o changelog (REA roda com as permissões do usuário).
- Segredos: o MBP usa o mesmo acesso do mini (decisão do Athos, 11/10); o comando enviado nunca carrega segredo.

## Limites conhecidos
- **Swap do MBP:** o macOS não devolve o arquivo de swap depois de uma pressão; o MBP fica em 4,9-5,2 GB "usados" mesmo ocioso, então o limiar de 5 GB bloqueia o offload parte do tempo. Medido hoje: 5.248 MB recusou uma execução com 3,8 GB de RAM disponível. Decisão pendente: trocar o critério por RAM disponível + pressão de memória.
- Teste que lê `shared/data/*.db` falha no MBP (os bancos não são enviados): o runner imprime uma nota; rode esse teste local.
- Cada execução paga ~6 s de ssh/rsync; testes de menos de ~10 s não valem o offload.
