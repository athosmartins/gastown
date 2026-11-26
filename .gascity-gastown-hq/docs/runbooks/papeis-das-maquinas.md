# Papéis das máquinas (mini 64, mini 16, MBP, Hetzner, S3, MotherDuck) · runbook

## Contents

• Resumo · Mini 64 · Mini 16 · MBP · Hetzner · S3 e MotherDuck · O que muda no dia do corte · Regras que valem · Regras substituídas · Em aberto · Fases e beads · Quando revisar

Programa ga-6akvlv (revisão de arquitetura de 15/10, Athos: "você decide o papel de cada máquina") e, desde 25/11, o programa de troca ga-ke5w2ie (Athos: "extrair o máximo de valor de todas as máquinas"). Este doc diz o que roda onde e por quê; o como de cada peça está nos runbooks citados e, para a troca, em `docs/runbooks/mini64/`. **Leia assim:** "mini 16" é o mini de hoje (16 GB / 256 GB); "mini 64" é o M5 Pro (64 GB / 1 TB) que chega na semana de 30/11 (ga-ke5w2ie); até o corte o 16 faz o papel do 64. **[novo 25/11]** marca decisão do grill de 25/11 (ga-ke5w2ie); **[substituída 25/11]** marca regra antiga que essa decisão derrubou; o que não tem marca vale como estava, com a data da decisão original. Cada afirmação cita a bead (ou o runbook) de onde veio.

## Resumo

| Máquina | Hoje (até o corte) | Depois da troca | Fonte |
|---|---|---|---|
| Mini 64 (M5 Pro, 64 GB / 1 TB) | — (chega na semana de 30/11) | **[novo 25/11]** Frota inteira: 8 celulares por USB, Dolt, daemons do WhatsApp, painéis, motor (Pilot, gate, supervisor) e 6–8 workers de construção | ga-ke5w2ie |
| Mini 16 (16 GB / 256 GB) | Frota (celulares por USB, daemons do WhatsApp, painéis), Dolt, motor e crews; construtores só em teto local pequeno | **[novo 25/11]** Construção de código (2–3 vagas, pode ler dado) + reserva com restore semanal testado: restaura o backup toda semana e assume em ~30 min se o 64 tiver defeito | ga-ke5w2ie.8, ga-2hd02v.17 |
| MacBook Pro | Rajada só quando o Athos não usa: testes, Go, REA/APK; laboratório de restore | Sem mudança | ga-77c1qg, ga-ke5w2ie.8 |
| Hetzner cax41 (aarch64, 16 núcleos, 30 GB) | Construtores (dog-remote, wa-worker-remote), revisores do gate e testes; só código, nunca dado de lead | **[novo 25/11]** Segue por 2 semanas depois do corte, com a mesma regra de dado, e é cancelado se o ritmo segurar | ga-2hd02v.17, ga-qg1dw5z, ga-ke5w2ie.9 |
| S3 | Backups; parquets RFB lidos de lá | **[novo 25/11]** Única cópia fora de casa; sem egresso (os parquets RFB vão para o disco local) | ga-ke5w2ie, ga-ke5w2ie.10 |
| MotherDuck | Em uso (~1.200 arquivos `md:`) | **[novo 25/11]** Sai de vez, só depois da migração feita e testada | ga-ke5w2ie.13 |

## Mini 64

**[novo 25/11]** Fica com tudo que depende de hardware ou de dado vivo, e ainda com o motor e a construção (ga-ke5w2ie):
- **8 celulares por USB direto**, com bancos e serviços: central-sender, slot-scheduler, conversation-monitor e watchdogs (ga-ke5w2ie, ga-6akvlv). Celular, hub e placas mudam de máquina juntos, com o envio parado: um dono só por aparelho, e os celulares não se dividem entre as duas máquinas (crews, ga-ke5w2ie.12). A troca física dos cabos não é problema (Athos, ga-ke5w2ie.8).
- **Chrome CDP** em 127.0.0.1:9222 (iptu, pbh, pipedrive-ib), **Google Drive** montado (sync_sources, cpf-status, property_search), `secret` e `notify` locais, health.db e classifications.db (8+ escritores) ficam com a frota (ga-6akvlv, 15/10). O que não migra sozinho (permissões TCC/FDA, Command Line Tools, driver serial WCH.CN das placas, chaves ssh de host, chaves do Bitwarden e do Keychain) está no inventário da ga-ke5w2ie.1, não neste doc (ga-ke5w2ie, risco 3).
- **Dolt de beads** (`.beads/dolt/`) e **motor** (Pilot, gate, supervisor) ficam juntos e vão com o 64: a latência entre máquinas obriga Dolt e motor a ficarem juntos (ga-6akvlv; medido em 30/10, ga-puml3i).
- **map-viewer** fica com a frota: lê e escreve bancos vivos, chama :8095 e usa `secret` (ga-6akvlv, revisão adversarial de 15/10).
- **6–8 workers de construção** (ga-ke5w2ie). Por quê: medido no 16, ~8 h/dia de construção parada por piso de disco, ~18 reboots/quedas em 16 dias e ~55 beads aprovadas/dia; a estimativa para o 64 é 90–120/dia (estimativa, não medição) e o teto passa a ser o gate e as contas Claude (ga-ke5w2ie).
- **Limites:** os de hoje (piso de disco, guardas de RAM e de swap, teto do pool WA) foram calibrados para 16 GB / 256 GB; reajusta na D+1, não se copia cego (ga-ke5w2ie.7; risco 4 do épico; digo-wa em ga-ke5w2ie.12).

## Mini 16

**[novo 25/11]** Fica no setup: vendê-lo e deixá-lo parado como reserva foram descartados pelo Athos ("extrair o máximo de valor de todas as máquinas"; ga-ke5w2ie.8). Dois papéis e um limite:
- **Construção de código, 2–3 vagas, pode ler dado**, porque fica em casa (ga-ke5w2ie.8). As crews recomendaram que o 16 leia cópia e nunca o banco vivo, e que jobs pesados (estudos, renders, Hex/relatórios) rodem fora de hora; é orientação consolidada pelo Mayor em 25/11 18:09, não decisão do Athos (ga-ke5w2ie.12).
- **Reserva com restore semanal testado:** restaura o backup toda semana e assume em ~30 min se o 64 tiver defeito (ga-ke5w2ie.8). A ordem de grandeza bate com o RTO de 30 min que o laboratório de restore já cronometra (`dolt-restore-lab.md`, ga-ap2dd6). Nenhuma fatia do épico constrói o job semanal nem o passo de assumir: ver "Em aberto".
- **Limite, depois do corte:** não envia WhatsApp, não escreve no Dolt de produção e não faz backup S3, e não volta sozinho depois de um reboot: a ga-ke5w2ie.4 prevê aposentar o servidor antigo com um marcador que faz os scripts de backup recusarem rodar, e um `desfazer` que exige confirmação explícita. Os passos de assumir como reserva não estão escritos (ver "Em aberto"); o que já vale é o risco nº 1 do épico: dois servidores vivos = WhatsApp em dobro, Dolt divergente, backup S3 sobrescrito pela máquina errada (ga-ke5w2ie).

## MBP

Sem mudança de papel (ga-ke5w2ie.8):
- **Rajada só quando o Athos não usa** (regra ga-77c1qg, Athos 12/10): 100% da capacidade com ele fora, nunca pesar com ele usando. "Fora" = tela bloqueada ou 10 min sem teclado/mouse; leitura que falha vale "usando"; em uso, o teto cai para 1 execução em prioridade de fundo e só com o MBP saudável. Chave manual (liga/desliga/pausa) e status claro de uso (ga-77c1qg, ga-sokx7u, `mbp-offload.md`).
- **Go** (`go test`/`build`) roda lá, não no mini (ga-edkfip).
- **Laboratório de restore** do backup S3 (`dolt-restore-lab.md`, ga-3kmvyr); o restaurado é apagado ao fim (ga-ap2dd6, Athos 15/10).

## Hetzner

Cax41 (aarch64, 16 núcleos, 30 GB). **[novo 25/11]** Fica por 2 semanas depois do corte, enquanto o setup novo se prova (os jobs migram para o 64 e o 16 e medimos); se o ritmo segurar, é cancelado (Athos, ga-ke5w2ie.9). Até lá:
- **Construtores e revisores remotos** (ga-2hd02v): dog-remote, wa-worker-remote, gate-reviewer-remote; ps-worker remoto em `hetzner-ps-node.md`. Desde 19/11, «construtores todos no Hetzner»: dogs e construtores do WA rodam só lá; no mini ficam crews, painéis e banco, e a bead que precisa de algo só do mini espera vaga num teto local pequeno (Athos, ga-2hd02v.17). A bead só vai ao nó com `node:ok` (só código e teste). Tetos e degraus: `hetzner-capacity.md`.
- **Dado:** nunca conversa de WhatsApp nem contato de lead, nunca backup de beads (Athos 13/10, ga-2hd02v; 11/11, ga-qg1dw5z). Cadastro de lote + proprietário só pelo usuário `dados`, enquanto o build roda e sem rede (trava 1, `hetzner-dados.md`, ga-qg1dw5z.1). O nó lê o Dolt do mini por atalho ssh; nada de beads, lead ou credencial fica gravado lá.
- **Trabalho pesado sob demanda:** GC `--full` do Dolt (runbook da ga-2895yv.1.1.2), testes noturnos (`hetzner-nightly-tests.md`).
- **Casa nova antes do cancelamento:** testes noturnos, mutação, espelho git, passo espacial SPE e `gc --full` ganham lugar no 64 ou no 16 pela ga-ke5w2ie.9, que também remove o túnel -R 2293, o hetzner-fw-ip-watch e os vigias do nó. Qual job vai para qual máquina ainda não está decidido: ver "Em aberto".
- **Servidor pago trabalha sempre** (Athos 14/10): vaga ociosa com fila apta ao nó é bug (ex.: ga-2hd02v.3.12). Vale como estava até a ga-ke5w2ie.9 (aberta) dizer o que o nó ainda leva nas 2 semanas depois do corte.

## S3 e MotherDuck

- **S3:** **[novo 25/11]** fica como a única cópia fora de casa (DR) e sem egresso (decisão do Mayor no grill, ga-ke5w2ie). O egresso chegou a US$ 200/mês e estoura o teto de R$ 1.000: os parquets RFB passam para o disco local do 64 e o histórico Claude vai para Glacier IR (ga-ke5w2ie.10: urgente pelo custo, independe do dia D, mas precisa do disco de 1 TB). O restic da config do mini vai para o Google Drive do Athos, não para o S3 (`mini-restic-backup-restore.md`, ga-qu9us).
- **MotherDuck:** **[novo 25/11]** sai de vez, mas só depois de a migração para o 64 estar feita e testada (Athos, ga-ke5w2ie.13, que depende do corte). Escopo: ~1.200 arquivos `md:`, fila de escritores (DuckDB tem 1), caminho do Hex, backup local→S3, corte em camadas. Ganhos esperados: velocidade (17 GB em RAM), nenhuma falha de sessão da nuvem e ~R$ 200/mês a menos (ga-ke5w2ie.13).

## O que muda no dia do corte

Passo a passo, scripts e testes: `docs/runbooks/mini64/` (um arquivo `NN-nome.md` por fatia; o índice é o `README.md`, da ga-ke5w2ie.1; scripts em `scripts/mini64/`). As fatias ainda estão entrando no main: até uma entrar, o texto dela é a descrição da bead. Aqui, só o que troca de papel (ga-ke5w2ie):

| Quando | O que muda | Fatia |
|---|---|---|
| ~3 dias antes (D-3), de dia | Cópia grande com o Assistente de Migração, rede isolada e a chave de espera ligada; a noite de corte vira só delta (Dolt ~10 GB, `.gc`, `shared/data`, repos) | ga-ke5w2ie.5, ga-ke5w2ie.2 |
| 1º login do 64 | Nada da cidade carrega sozinho: os ~539 plists copiados ficam na espera e voltam por camadas, nesta ordem: 0 Dolt · 1 bd e motor (gc, supervisor, pilot) · 2 backups (só depois do servidor antigo aposentado) · 3 painéis · 4 cloudflared (1 conector só) · 5 envios WhatsApp e ligações, por último | ga-ke5w2ie.2 |
| Noite de sábado→domingo (D0) | O mini 16 deixa de enviar, de escrever no Dolt de produção e de fazer backup, e não volta sozinho; celulares e hub passam para o 64; WhatsApp fora de 00h a no máximo 07h (no ar às 07:00); nenhum número novo de ligação liga no D0 e o A03 segue desligado até o Athos religar | ga-ke5w2ie.4, ga-ke5w2ie.6, ga-ke5w2ie.15 |
| D0, até 04:30 | Go/no-go: um comando diz GO, NO-GO ou INCERTO. O rollback real só existe até o 1º envio ou escrita no 64 | ga-ke5w2ie.3 |
| D+1 | Limites reajustados para 64 GB / 1 TB (piso de disco, exportador jsonl, guardas de swap do reboot noturno, teto do pool WA, `gc --full` do hq local); o flatten do hq vai para esta data | ga-ke5w2ie.7, ga-wnwdsmg |
| Quando o disco de 1 TB existir | Parquets RFB do S3 para o disco local e histórico Claude para Glacier IR; independe do dia D | ga-ke5w2ie.10 |
| Depois do corte | Restore de prova do backup S3 no 64; saída do MotherDuck; mídias das conversas baixadas e transcritas automaticamente (transcrição local); pontes de ligação por celular, em degraus (canário de 1 número, depois 3, teto de 6 dos 8 celulares; decisão do peter, delegada pelo Athos) | ga-ke5w2ie.11, ga-ke5w2ie.13, ga-ke5w2ie.14, ga-ke5w2ie.15 |
| Corte + 2 semanas | Hetzner cancelado, se o ritmo segurar | ga-ke5w2ie.9 |

A execução real é na noite D0, pelo Mayor; nada disso roda contra a produção no mini 16 além de leitura (ga-ke5w2ie).

## Regras que valem

1. **Dado:** conversa de WhatsApp, contato de lead e backup de beads ficam em máquina do Athos e nunca vão para o Hetzner (Athos 13/10, ga-2hd02v; reafirmada em 15/10, ga-ap2dd6, e em 11/11, ga-qg1dw5z). Exceção estreita de 11/11: cadastro de lote + proprietário, só pelo usuário `dados` (seção Hetzner). **[novo 25/11]** "Máquina do Athos" passa a incluir o mini 16, que pode ler dado porque fica em casa (ga-ke5w2ie.8). O laboratório de restore roda no MBP, que é do Athos, e apaga o restaurado ao fim (ga-ap2dd6, Athos 15/10).
2. Teto de R$ 1.000/mês de gasto de nuvem (ga-6akvlv, 15/10; o egresso do S3 será cortado por estourá-lo, ga-ke5w2ie.10).
3. ARM não é bloqueio no nó: wheels aarch64 ok, Dockerfile multi-arch (ga-6akvlv, 15/10). Vale enquanto o nó existir.
4. **[novo 25/11]** Um dono só por daemon, por aparelho e por escrita: dois servidores vivos ao mesmo tempo = WhatsApp em dobro, Dolt divergente, backup S3 sobrescrito pela máquina errada (risco nº 1, ga-ke5w2ie). Depois do corte o 16 não envia, não escreve no Dolt de produção e não faz backup (ga-ke5w2ie.4); no 64, o envio WhatsApp é a última camada a carregar (ga-ke5w2ie.2).

## Regras substituídas

- "Não comprar 2º Mac mini" (15/10, ga-6akvlv). **[substituída 25/11]** O M5 Pro 64 GB / 1 TB chega na semana de 30/11 e o 16 foi mantido (ga-ke5w2ie).
- "Provedor fica no Hetzner; se faltar RAM, cpx51 ou AX42" (15/10, ga-6akvlv). **[substituída 25/11]** O Hetzner é cancelado 2 semanas depois do corte, se o ritmo segurar (ga-ke5w2ie.9).
- "Construtores todos no Hetzner" (19/11, ga-2hd02v.17). **[substituída 25/11, a partir do corte]** Os construtores vão para o 64 (6–8) e para o 16 (2–3 vagas) (ga-ke5w2ie).
- Fase 3, motor no nó (30/10, ga-puml3i). **[sem objeto desde 25/11]** O motor vai com o 64 (ga-ke5w2ie).
- "Reabrir o GC no nó, não o flatten" e "o flatten foi descartado" (30/10, ga-2895yv). Já estava velha: o flatten voltou em 11/11 (hq de 11,5 para 1,0 GB) e o próximo vai para a D+1 no 64, com 1 TB e sem piso de disco (ga-wnwdsmg, Mayor 25/11).

## Em aberto

Pontos que as beads não fecham, para o Mayor abrir ou responder (este doc não os inventa):
1. **Restore semanal e assunção do 16 em ~30 min** (decisão de 25/11, ga-ke5w2ie.8): nenhuma fatia do épico constrói o job semanal, define onde a cópia fica nem escreve os passos de assumir. A ga-ke5w2ie.11 só prova o restore no 64.
2. **Como as 2–3 vagas do 16 leem dado e falam com o Dolt do 64:** cópia restaurada ou o Dolt do 64 pela rede? Nenhuma bead do épico diz.
3. **Casa nova de cada job do Hetzner** (testes noturnos, mutação, espelho git, passo espacial SPE, `gc --full`): ga-ke5w2ie.9, ainda aberta.
4. **Quantos celulares:** 8 (Athos, 25/11, ga-ke5w2ie) contra 5 na versão de 15/10 deste doc (ga-6akvlv); a conferência do dia é o `adb devices` do go/no-go (ga-ke5w2ie.3).

## Fases e beads

Estado como estava em 30/10, com as marcas de 19/11 e 25/11 por cima; não reconferido em 26/11 (o estado vivo está em `bd show <bead>`):

| Fase | O quê | Bead | Estado |
|---|---|---|---|
| 1 | Laboratório de restore | ga-ap2dd6, ga-3kmvyr | 1ª fatia fechada; primeiro restore real do hq no MBP medido em 19/10, veredito OK (`dolt-restore-lab.md`) |
| 2 | Workers, revisores e testes no nó | ga-2hd02v (filhas .3 WA, .4 PS) | ga-2hd02v.1.6 fechada 30/10 (dog, revisor e wa-worker remotos provados com bead real); rota WA ao nó em `auto` desde 30/10 (33bc8fb4f); cessão por prioridade que corta o WA antes do nó = ga-2hd02v.3.16; PS em sombra. **19/11:** construtores todos no nó (ga-2hd02v.17). **[novo 25/11]** o nó sai 2 semanas depois do corte (ga-ke5w2ie.9) |
| 2b | MBP como nó de capacidade | ga-sokx7u, ga-w7qwl1.2 | prova ao vivo com sessão de teste (ga-w7qwl1.2.4); guarda só dentro da sessão remota, `~/.claude` do Athos intocado (ga-w7qwl1.2.7); canário (ga-w7qwl1.2.5) espera as duas |
| 3 | Motor (Pilot/gate) no nó, Dolt fica no mini | ga-puml3i | **medido 30/10: o motor FICA no mini.** O atalho ssh recusa por desenho as leituras do Pilot (`--limit 0`, flags de exclusão, ready/query, escritas); overhead do atalho +0,61 s/chamada p50 (RTT 236 ms); varredura do mini já tem p50 6,2 min e o gargalo é a saturação do mini, não a distância. Números na ga-puml3i. **[novo 25/11]** sem objeto: o motor vai com o 64 (ga-ke5w2ie) |
| 4 | Troca para o mini 64; o 16 vira construção e reserva; Hetzner cancelado 2 semanas depois do corte | ga-ke5w2ie (fatias .1 a .15) | **[novo 25/11]** decidida em 25/11; o mini chega na semana de 30/11; fatias e estado em `bd show ga-ke5w2ie` |

## Quando revisar

- No corte (ga-ke5w2ie.6): trocar a coluna "Hoje" do resumo pela "Depois", passar o mini 16 de "hoje" para construção e reserva e tirar o aviso de que as fatias ainda estão entrando no main.
- Na D+1 (ga-ke5w2ie.7): se os limites do 64 mudarem a regra do Go no MBP ou o teto de vagas do 16, atualizar as seções MBP e Mini 16.
- No cancelamento do Hetzner (ga-ke5w2ie.9): apagar a seção Hetzner, a regra 3 e as linhas do nó nas fases.
- Quando o MotherDuck sair (ga-ke5w2ie.13): trocar o MotherDuck do resumo por "saiu em <data>".
- Quando existir o restore semanal e o passo de assumir do 16: tirar o item 1 de "Em aberto" e apontar para o runbook.
