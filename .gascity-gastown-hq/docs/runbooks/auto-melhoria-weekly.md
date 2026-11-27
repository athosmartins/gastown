# Resumo semanal da auto-melhoria (auto-melhoria-weekly) · runbook

## Contents

• O que manda · Como rodar · Quando diz NÃO MEDIDO · Limites

Fatia 4 de 4 do piloto «Recusas → checagens» (épico ga-mw5gdyu, Athos 26/11). Toda segunda 08:00 (hora local) o Athos recebe por `notify`, e o Mayor por mail, **3 a 5 linhas em português, sem pergunta**. Só lê (medidor da .1, registro e beads da .2, confs da .3); não escreve nada deles. Uma decisão de produto que apareça vai por bead com `athos.acao` e `aguarda:athos`, nunca por este texto.

## O que manda
1. `1ª tentativa: 62% (31/50) vs 58% (29/50) na semana anterior (+4 pts, dentro do ruído)`: o `first_attempt` do medidor, esta semana × a anterior (as duas pelo `measure()` do próprio medidor; um veredito na fronteira cai numa semana só). «Dentro do ruído» = a diferença cabe no acaso (intervalo de 95% da diferença de duas proporções; duas semanas de ~50 beads diferem até uns 19 pontos só por acaso). Com menos de 5 beads numa das semanas não há variação, só os números.
2. `Recusas do portão: N (X com classe-raiz, Y sem leitura) · classe n, …`: recusas de revisor da semana e as 3 classes que mais recusaram.
3. `Checagens: pedidas · entraram em teste · promovidas · desligadas`: pedidas = beads do ciclo da .2 criadas na semana; as outras três vêm do registro `# ratchet` da conf de cada checagem (a catraca da .3), pelo horário gravado nela.
4. `⚠ quality-gate.jsonl: …`, só quando uma linha rasgada pode esconder veredito da semana.

## Como rodar
`python3 -I scripts/auto-melhoria-weekly.py [--apply] [--json] [--now AAAA-MM-DDTHH:MM:SSZ] [--city DIR]`. Sem `--apply` só imprime o texto e diz o que faria. A order `packs/town-deltas/orders/auto-melhoria-weekly.toml` roda com `--apply` às 11:00 UTC de segunda (cron é UTC: = 08:00 em -03). **Nada é enviado entre 00h e 08h locais** (a conta de calendário do `quiet_hours.py`; o arquivo de nível ao vivo não é consultado, ele ainda diria QUIET por minutos depois das 08h); janela ilegível também segura. Rodada adiada não se repete: rode à mão depois das 08h. O mail sai sem `--notify` (não acorda o Mayor: é leitura de rotina). Rodar `--apply` duas vezes manda duas vezes. Saída: 0 · 1 um canal falhou (o outro foi tentado) · 2 algo NÃO MEDIDO ou janela ilegível · 64 uso · 70 bug. Testes: `python3 -I scripts/test_auto_melhoria_weekly.py`. Depois do reload: `gc order show auto-melhoria-weekly` e um dry-run à mão.

## Quando diz NÃO MEDIDO
Cada peça falha sozinha e o relatório sai mesmo assim (semana cega não é semana quieta): log do gate ausente/vazio/ilegível (sem 1ª tentativa nem classes), medidor que não carrega ou levanta, registro de classes ausente/ilegível/sem cabeçalho, `bd list` do ciclo que falha. `N sem leitura` = conf que não é do ciclo ou ilegível, linha do registro estragada, decisão sem hora, bead sem data. O motivo vem entre parênteses; `--json` traz o detalhe.

## Limites
- Nada rodou ao vivo (o nó não tem Dolt nem `gc`): o 1º envio real é o teste de campo. Duas rodadas do medidor (semana e anterior) levam minutos sob carga (a order dá 1800 s); se o `bd`/Dolt estiver pendurado e estourar isso, nada sai e a order aparece como falha (não como semana quieta).
- Duas linhas do registro que nomeiem a mesma checagem contam as duas (a catraca já as marca `fora-do-contrato`).
- «Dentro do ruído» é um sinal, não prova: 95% por semana, sem correção para muitas semanas. O limiar (`Z`) é decisão minha; o Mayor pode trocar.
