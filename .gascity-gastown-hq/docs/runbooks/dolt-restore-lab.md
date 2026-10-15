# Laboratório de restore do Dolt (`dolt-restore-lab.sh`) · runbook

## Contents

• Estado em uma linha · O que é — e o que não é
• Como usar · Códigos de saída · O que o relatório tem
• Flatten · Medido, inferido, não testado · O que falta · Como desfazer

Bead ga-ap2dd6 (revisão de arquitetura de 15/10). **Esta entrega é a fatia de código; o bead NÃO está pronto** — ver "O que falta".

## Estado em uma linha

O script que faz o ensaio de restore existe e está testado só com banco de fixture. **Nenhum dado real foi restaurado, nenhuma credencial S3 foi criada e nada foi instalado no servidor Hetzner.** O bead original mandava restaurar hq + WA no servidor, o que conflitava com a regra do Athos de 13/10 ("nenhum dado de lead/cliente nem backup de beads sai do mini", descrição do ga-2hd02v). Decisão do Athos, relatada pelo Mayor no comentário de 15/10 18:42 do ga-ap2dd6 (AskUserQuestion do Mayor, 15/10 15:2x, "opção 2 de 3"): **o laboratório roda no MBP, a regra fica, nada do Dolt vai para o Hetzner** (Hetzner recebe só motor, workers e testes).

## O que é — e o que não é

É: `scripts/dolt-restore-lab.sh run …` pega UM backup do Dolt (pasta `file://` ou prefixo `s3://`), **restaura de verdade**, confere a contagem de linhas de cada tabela contra um manifest, cronometra busca/restore/contagem contra o RTO e, se pedido, mede o flatten + `dolt gc` na cópia. Roda em qualquer máquina com `dolt` e `python3`; não depende da cidade, do `bd` nem do `gc`.

Não é: a ligação com o MBP (`mbp-run.sh --exec`), a credencial S3 só-leitura, o agendamento, o alerta, nem o gerador do manifest. Nada disso está aqui (ver "O que falta"). O script não sabe em que máquina roda; no desenho aprovado ela é o MBP, que é do Athos.

Por que existe: o `dolt-restore-verify.sh` só consegue provar que o manifest do S3 fecha para o hq ("NAO e um restore", log de 11/10) porque um restore de verdade pede ~19 GB que o mini não tem.

## Como usar

```bash
bash scripts/dolt-restore-lab.sh run --db hq --source s3://urblink-dolt-backups/hq \
  --manifest /caminho/hq.manifest.json --workdir /var/lib/restore-lab \
  --report /var/lib/restore-lab/hq.report.json --rto-seconds 1800 --flatten
```

* `--source`: `file:///dir` (pasta de backup do Dolt, tem o arquivo `manifest`) ou `s3://bucket/prefixo` (buscado com `aws s3 sync` para dentro da pasta de trabalho).
* `--manifest`: `{"schema":1,"db":"hq","tables":{"issues":123,"comments":456}}` — contagens tiradas **do lado de origem** quando o backup foi feito. **Só números**: pode viajar para qualquer máquina. Restaurado ≥ esperado passa (linha criada entre a contagem e o snapshot só soma); menos que isso reprova. Liste só tabelas de contagem estável (as `dolt_ignore`, de alta rotatividade, ficam de fora).
* `--workdir`: caminho absoluto; o script cria `run-XXXXXX` lá dentro e **só apaga esse**. Recusa `/`, o `$HOME`, caminho relativo e qualquer pasta com `.dolt`/`.beads`. Uma trava (`.lab.lock`) impede duas rodadas na mesma pasta; trava de pid morto é recolhida.
* Termina apagando o restaurado (use `--keep` para inspecionar). A origem nunca é tocada; a cópia buscada do S3 é apagada logo depois do restore, para o `gc` ter espaço.
* Disco: exige 400% do tamanho do backup livre (`LAB_DISK_MARGIN_PCT`): cópia buscada + restaurado + folga do `dolt gc` (2–2,8× o banco). Ilegível = UNKNOWN, nunca "cabe".
* O dolt roda com `DOLT_ROOT_PATH` dentro da pasta de trabalho (o commit do flatten precisa de identidade, e assim o `~/.dolt` do usuário do host nunca é lido nem escrito).

## Códigos de saída

Três estados, não dois: "não consegui checar" não é "checado e bom".

| rc | nome | quando |
|---|---|---|
| 0 | OK | restaurou, toda tabela ≥ manifest, dentro do RTO |
| 1 | FAIL | checado e quebrado: backup sem `manifest` do dolt, restore falha, tabela ausente/ilegível ou abaixo do manifest |
| 2 | UNKNOWN | não deu para checar: manifest ausente/ilegível/vazio/de outro banco, dolt ou python3 ausente, busca no S3 falhou, disco curto, outra rodada em curso |
| 3 | SLOW | tudo passou, mas busca+restore+contagem passou do RTO |

Precedência quando vários acontecem: FAIL > UNKNOWN > SLOW > OK. **O rc é só o do restore.** O resultado do flatten vai no relatório e na linha `RESULT:` (`flatten=OK|FAIL|SKIPPED|UNKNOWN`): é pesquisa, não deve acordar ninguém como "backup quebrado". Manifest inutilizável ainda faz o restore e o cronometra (o tempo vale), mas o veredito é UNKNOWN.

## O que o relatório tem

JSON com `verdict`, `rc`, `reason`, `host`, `dolt_version`, `source_kind`, `source_kb`, `rto_seconds`, `fetch_s`/`restore_s`/`count_s`/`total_s` (null quando não medido), `restored_kb`, `tables.<t>.{expected,restored}` e `flatten.{result,why,commits_before,commits_after,kb_before,kb_after_gc,flatten_s,gc_s,gc_args}`. **Só contagens, tamanhos e tempos — nenhum valor de linha** (o teste procura valores de fixture no relatório e no log). A última linha do stdout é `RESULT: <veredito> db=… rc=… total_s=… flatten=… report=…`.

## Flatten

Mesma receita do `bd flatten` (Tim Sehn), com `dolt` puro na cópia: branch novo → `reset --soft` na raiz → um commit de snapshot → troca o branch ativo → `dolt gc` (`--gc-args` para mudar; o padrão é o do passo 6 do `bd flatten`). **Cada passo é conferido**: um protótipo meu com o `reset` falhando seguiu em frente e "achatou" nada, com cara de sucesso; o teste de hoje exige `FAIL` nesse caso. Depois confere que o histórico encolheu e que **a contagem de cada tabela é a mesma de antes**. Histórico de ≤2 commits = `SKIPPED` (nada a achatar); restore não verificado = `SKIPPED`; mais de uma raiz = `UNKNOWN`. A cópia restaurada não tem remotos, então a poda de refs remotas do `bd flatten` não se aplica.

## Medido, inferido, não testado

**Medido (15/10, no mini, dolt 2.3.1, fixture de 2 tabelas):** `scripts/dolt-restore-lab.selftest.sh` — 59 casos, 0 falhas, dolt de verdade, `aws` falso, ~2 min com o mini a load 66 (os mesmos 59 passam em bash 3.2, o do macOS, e em bash 5.3). **Os testes mordem:** rodei a suíte contra 12 cópias do script com um defeito cada (comparação invertida, checagem de disco que concatena valores, manifest vazio aceito, manifest de outro banco aceito, falha do `aws` tratada como backup quebrado, limpeza que apaga a origem, SLOW ignorado, tabela ausente aceita, trava de outra rodada ignorada, tamanho do S3 ilegível virando 0, flatten sem conferir contagem, `reset` sem checar). 10 foram pegas de primeira; **a de "flatten sem conferir contagem" passou batida** — nenhum teste perdia linha no flatten — e por isso há agora um teste com um `dolt` que apaga uma linha entre o `reset` e o commit (a cópia defeituosa reprova 2 casos; a correta passa). A do `reset` sem checar é equivalente: com o `reset` falho não sobra o que commitar e a checagem "o histórico encolheu" reprova do mesmo jeito. Protótipo do flatten: 7 → 2 commits, contagem igual, 48 → 40 KB (fixture, sem valor para o hq).
**Inferido:** o tempo e a memória do restore e do flatten no hq (12,9 GB) — nenhum número aqui vale para ele; é para isso que o laboratório existe. O custo de tráfego do S3 para fora da AWS (~US$0,09/GB, preço de lista que não conferi) pode ser relevante com restore todo dia: ~10-13 GB/noite só do hq (tamanho do S3 não medido; o vivo tem 12,9 GB) seriam ~US$20-35 por mês, fora o WA. **O bead dizia "custo: nenhum novo" e isso só valia para o servidor.**
**Não testado:** `aws` de verdade (formato de `s3 ls --summarize` assumido pela documentação do CLI), backup real do hq/WA, manifest real, o MBP (disco livre e `dolt` instalado lá não foram medidos), e a política de presença do Athos (ga-77c1qg) com este script.

## O que falta

1. **Credencial S3 só-leitura para o MBP.** Hoje não existe: o mini usa a credencial padrão do `aws` (não vi perfil nem item no cofre). Criar usuário/papel de IAM é ação na conta AWS, fora do que uma sessão de pool deve improvisar. Opções técnicas, para o Mayor escolher: credencial temporária e restrita (`aws sts get-federation-token` com política só de `s3:GetObject`/`ListBucket` no bucket, validade de horas, gerada no mini; depende de o usuário do mini ter `sts:GetFederationToken`), ou usuário de IAM só-leitura criado por quem tem acesso de administrador. Em ambos o valor passa pelo `secret`/ambiente e nunca vai a arquivo; atenção: `mbp-run.sh --exec --env K=V` põe o valor no argv do mini, então a entrega precisa de desenho próprio.
2. **Ligação com o MBP** por `mbp-run.sh --exec --push … --pull …` (já existe: scratch por slot, apagado no fim; só com o MBP livre, política ga-77c1qg; `taskpolicy -b` se ele voltar). Antes: medir disco livre no MBP (o restore do hq pede ~19 GB; com `LAB_DISK_MARGIN_PCT=400` o script recusa se faltar, sempre como UNKNOWN) e instalar `dolt` na mesma versão do mini.
3. **Manifest.** Proposta, a validar: em vez de contar o banco vivo "agora" (que cresceu depois do backup), perguntar ao mini a contagem **no mesmo commit** que o restaurado tem (`SELECT COUNT(*) FROM <tabela> AS OF '<hash do HEAD restaurado>'`); dá número exato do snapshot, sem a aproximação por `created_at` do `dolt-restore-verify.sh`. Falha se o commit já não existe no vivo (depois de um flatten) = UNKNOWN. Custo dessa consulta no hq vivo não medido.
4. **Cadência e custo.** Provar o restore não exige ser toda noite; semanal já responde "o hq restaura e em quanto tempo" por 1/7 do tráfego. Decisão de custo/produto para o Mayor/Athos.
5. Agendamento depois do upload e da prova do S3, alerta por `notify` só em rc 1/2/3, série de `report.json`. Só então o resultado do flatten no hq alimenta o ga-2895yv, e o restore por `bd import` do ga-c0939v usa o mesmo laboratório. **O ga-ap2dd6 não deve fechar antes do primeiro restore real medido.**

## Como desfazer

Apague `scripts/dolt-restore-lab.sh`, `scripts/dolt-restore-lab.selftest.sh` e este arquivo. O script não instala nada, não agenda nada e só escreve dentro de `--workdir/run-*` e no `--report`.
