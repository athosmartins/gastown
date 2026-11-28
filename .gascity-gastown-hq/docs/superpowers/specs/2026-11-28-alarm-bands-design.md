# Alarmes por faixa estatística — Design Spec (ga-4mzkfj9)

## Contents

• Intenção · Objetivos e não-objetivos · Restrições · Decisões minhas · Verificação · Fica para depois

> Status: **entregue ao gate junto com o código**; o texto da bead (Athos 28/11, `story:approved`) é a descrição aprovada, **as decisões abaixo são do construtor** (dog-remote), não do Athos. Operação: `docs/runbooks/alarm-bands.md`.

## Intenção
Os vigias usam limite fixo e **repetem por dias**: «gate abaixo de 8,0/h» a cada 6 h desde 26/11 com o gate estável em ~3/h; alerta de autoconserto de bead já segurada. O limite diz onde o produto QUER estar, não se algo MUDOU, e o ruído enche o inbox do Mayor e dos agentes até ninguém ler. A melhoria (playbook «The AI-Native SDLC», escolhida pelo Athos) é julgar cada métrica contra o comportamento recente dela mesma: 1σ só registra, 2σ acorda um agente que só lê para diagnosticar, 3σ propõe o conserto — e o mesmo quadro nunca avisa duas vezes.

## Objetivos e não-objetivos
**Objetivos.** Um `bands.yaml` versionado (por métrica: média móvel, σ, regras de Western Electric) lido por um script determinístico; ação por faixa; dispensa humana que ajusta a faixa; 22-07 h em silêncio; 2-3 vigias pilotos; contagem antes/depois de 7 dias.
**Não-objetivos.** Substituir os pisos de disco que **agem** (proteção, não ruído); rodar runbook pré-aprovado no 3σ (não existe nenhum com autorização citável, regra Nº 4); o piloto do `autoheal_escalation_watch.py` (mora no rig WA, este worktree não o alcança); previsão/modelo na detecção.
**Anti-objetivos** (falha mesmo que «funcione»): uma parada real do gate que a faixa cala; uma falha que a base aprende como normal; o agente de diagnóstico que age ou fala sob a identidade do vigia; o mesmo alarme voltando pela porta dos fundos (por exemplo, logo depois de uma dispensa).

## Restrições
Da bead: começar por 2-3 vigias; a meta do Athos (8/h) é referência de produto, não gatilho de repetição; respeitar o silêncio 22-07 h. Do ambiente: o job roda no `/usr/bin/python3` do mini (3.9, sem PyYAML, sem tomllib); o gate recusa leitura que falha e é tratada como vazio (E12/3º estado), então toda leitura nova diz o que faz em «vazio» e em «falhou»; `AGENTS.md` não cresce (docs em `docs/`).

## Decisões minhas
1. **Série em baldes fixos, não janela rolante.** O gate vira contagem por bloco de 3 h na grade 07-10-13-16-19-22 (5 blocos/dia ativos): pontos independentes (as regras de Western Electric supõem isso), sem o mergulho noturno natural na base, e a grade cabe exatamente na janela 22-07. Custo: a detecção atrasa até um bloco (~3 h), o mesmo da janela de 3 h antiga.
2. **Contagem em √(x+3/8).** Média de ~9 revisadas por bloco não tem limite inferior de 3σ em escala crua (daria negativo) e uma parada total nunca chegaria ao 3σ; em √ uma parada total fica a ~5σ. σ com piso de 0,5 (Poisson).
3. **A falha não vira o normal.** A base não inclui os 8 pontos em teste nem os de episódio aberto, e a janela fica congelada no começo do episódio (sem isso, um incidente de mais de 14 dias esvazia a base, o meter cai na regra fixa e o alarme repetido ressuscita).
4. **Aprendendo ≠ calado.** Base curta, série corrompida, estado ilegível, `bands.yaml` quebrado ou módulo que não carrega: o meter fica **na regra fixa de antes**, avisando. Já silêncio, rodada ocupada e «sem ponto novo» são decisões das faixas e não caem na regra antiga. Nenhum caminho termina em silêncio por falha de leitura.
5. **Uma entrega por faixa por episódio, carimbada só depois de entregue.** Mail que falha não é carimbado e repete na próxima rodada sem gastar o diagnóstico de novo; o mail nunca espera pelo diagnóstico nem pela bead. Estado que não grava = nenhuma ação (não saberia lembrar).
6. **O agente de 2σ só lê por construção**, no molde do `e9-plan.sh`: `claude -p --tools "Read,Grep,Glob"`, sem MCP, sem fontes de settings, `deny` em Bash/Edit/Write/rede e nas chaves da máquina, sem as variáveis de identidade (nenhum mail/nudge/comentário sob o nome do vigia), teto de US$ e de tempo, **gasto registrado antes de acontecer** (ledger que não grava = não gasta). Falha ou teto estourado: o mail sai sem diagnóstico, dizendo por quê.
7. **O 3σ propõe, não executa.** Bead `-t bug -p 1`, `exec:auto` + `story:approved` + rota `gastown.dog` (o gate revisa o que ela construir), texto do modelo fechado em `<conteudo_externo>` no mail e na bead (na bead, encurtado: quem a lê age), identidade da bead = rótulo do episódio (tentativa repetida **acha** a bead), tetos por dia. Prioridade 1 porque o 3σ é rara e é queda real; subir/descer é uma linha do `bands.yaml`. **Risco que é do Mayor**: a bead nasce `exec:auto` + `story:approved` (molde do `gate-refusal-checks.py`) com texto derivado de logs; a revisão de segurança automática apontou isso, a mitigação é o fence + teto + TRAVAS na bead e os rótulos serem a chave `bead.labels` (trocar a postura não exige código). Não escolhi um estado «pré-aprovação» no escuro: `story:needs-approval` cai na fila do Athos e `story:unrefined` entra no pipeline de refino.
8. **Dispensar = aceitar o que existe.** Só tirar o episódio não basta: o dado dispensado ainda é o mais novo e abriria outro episódio no run seguinte. Por isso a dispensa grava `accepted_until`, devolve os pontos à base e alarga σ (+25 % por dispensa em 30 dias, teto +100 %); só ponto **novo** é julgado.
9. **Leitor de YAML estrito de subconjunto**, não PyYAML (não existe no mini). Chave desconhecida, tipo errado, palavra que o YAML 1.1 lê como booleano, número ambíguo: erro com a linha. O `bands.yaml` tem de significar a mesma coisa para qualquer leitor YAML (o teste confere contra PyYAML quando existe).
10. **Disco só em sombra, e por variação, não por nível.** O nível do disco é um passeio com zeragens (limpezas), não uma variável em torno de uma média: as regras de Western Electric não se aplicam. A **queda por hora** é o sinal de «enchendo anormalmente rápido» (o incidente de 19/11 foi ~1 GB/h). Os pisos que agem ficam intocados; a sombra conta o que as faixas diriam. Hora sem leitura não gera ponto; **sem volume reserva** (no macOS `/` é o volume selado).
11. **A meta do Athos vira referência.** Consequência de produto, dita sem rodeio: um gate **estável abaixo de 8/h** deixa de interromper; aparece no relatório da manhã e no texto de todo aviso. É o que a bead pede; quem quiser o comportamento antigo tem `GTM_BANDS=0`.
12. **Interruptores em camadas** (`GTM_BANDS=0|shadow`, `mode: shadow` por métrica, `BANDS_DIAGNOSE=0`, `enabled: false`), porque o risco do recurso é calar um alarme de verdade: dá para voltar sem deploy.
13. **Contagem «antes»** lida do próprio log do vigia, com o número de linhas olhadas ao lado (um zero sem isso não prova nada); a do disco é parcial e diz.

## Verificação
- `bands.selftest.py` (config, estatística, máquina de estados, E/S de três estados, ações, adaptadores contra `claude`/`bd`/`gc` falsos que **gravam o que receberam**, dispensa, relatório, CLI, disco) e `gate-throughput-meter.selftest.sh` (16 casos antigos intactos + 12 de faixas, com log sintético de 15 dias); `gate-daily-report.selftest.sh` e `wait-for-dolt-plan.selftest.py` seguem verdes.
- **Mutantes**: 37 defeitos plausíveis injetados um a um (repetir entrega, base sem hold-out, sem congelar a janela, regra frouxa, mail falho carimbado, estado corrompido lido como ausente, agente com Bash, agente com identidade, ledger ilegível lido como zero, falha das faixas calando o alarme, leitura de disco que falha virando zero, volume reserva, diagnóstico solto no mail…); os 37 foram mortos.
- Lido a saída real de um episódio 3σ (mail, bead, evidência do agente, ledger) e corrigidos 3 defeitos de texto que o teste verde não pegava.
- **Não verificado**: nada rodou no mini (sem Dolt/`gc`/`bd`/`claude` reais neste nó); a sintaxe foi conferida para Python 3.9 por `ast.parse(feature_version=(3, 9))`, mas o código só **executou** em 3.12; os flags do `claude -p` espelham o `e9-plan.sh` que já roda lá, não foram exercitados contra o binário real.

## Fica para depois
- Piloto do `autoheal_escalation_watch.py` no rig WA (bead própria; o motor se chama por caminho).
- Ligar o disco ao vivo: decisão do Mayor depois dos 7 dias de sombra (`bands.py report`).
- Runbook pré-aprovado no 3σ, quando existir um com autorização citável.
- Outras métricas da bead (swap, captura): um bloco em `bands.yaml` + um coletor.
