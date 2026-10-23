# Papéis das máquinas (mini, Hetzner, MBP) · runbook

## Contents

• Resumo · Mini · Hetzner · MBP · Regras que não mudam · Fases e beads · Quando revisar

Programa ga-6akvlv (revisão de arquitetura de 15/10, Athos: "você decide o papel de cada máquina"). Este doc diz o que roda onde e por quê; o como de cada peça está nos runbooks citados.

## Resumo

| Máquina | Papel | Não faz |
|---|---|---|
| Mac mini | Frota do WhatsApp + Dolt (todos os bancos de beads) + dados vivos | Build Go frio, repack, restore de verificação (estouram disco/swap) |
| Hetzner cax41 (aarch64, 16 núcleos, 30 GB) | Workers, revisores do gate e testes, só código; GC pesado do Dolt sob demanda | Guardar dado de beads ou de lead (regra de 13/10) |
| MacBook Pro | Rajada quando ocioso: testes, Go, REA/APK; laboratório de restore | Qualquer carga com o Athos usando a máquina |

## Mini

Fica com tudo que depende de hardware ou de dado vivo, e não sai dele:
- 5 celulares por USB/adb (central-sender, slot-scheduler, conversation-monitor, watchdogs).
- Chrome CDP em 127.0.0.1:9222 (iptu, pbh, pipedrive-ib).
- Google Drive montado (sync_sources, cpf-status, property_search).
- `secret` e `notify` locais; health.db e classifications.db, com 8+ escritores.
- O Dolt de beads (`.beads/dolt/`) e o motor (Pilot, gate, supervisor), que lê o Dolt a cada varredura.
- map-viewer fica no mini: lê e escreve bancos vivos da frota, chama :8095 e usa `secret`.

O gargalo do mini é disco e swap, não CPU. A limpeza do hq (15 → 5,5 GB, 21/10) foi feita no Hetzner e trocada de volta; o flatten foi descartado (ga-2895yv).

## Hetzner

- **Workers e revisores remotos** (ga-2hd02v): dog-remote, wa-worker-remote (3 vagas, `PILOT_WA_NODE_SLOTS`), gate-reviewer-remote; ps-worker remoto em modo sombra (`hetzner-ps-node.md`). A bead só vai ao nó com `node:ok` (só código e teste). Capacidade: `hetzner-capacity.md`.
- **Sem dado de beads:** o nó lê o Dolt do mini por atalho ssh; nada de beads, lead ou credencial fica gravado lá.
- **Trabalho pesado sob demanda:** GC `--full` do Dolt (runbook da ga-2895yv.1.1.2), testes noturnos (`hetzner-nightly-tests.md`).
- **Servidor pago trabalha sempre** (Athos 14/10): vaga ociosa com fila apta ao nó é bug (ex.: ga-2hd02v.3.12).

## MBP

- Rajada só com o Athos fora (tela bloqueada ou ocioso), com chave liga/desliga (ga-sokx7u, `mbp-offload.md`).
- Go (`go test`/`build`) roda lá, não no mini (ga-edkfip).
- Laboratório de restore do backup S3 (`dolt-restore-lab.md`, ga-3kmvyr).

## Regras que não mudam

1. Dado de beads não sai do mini (Athos, 13/10, reafirmada em 15/10 em ga-ap2dd6).
2. Não comprar 2º Mac mini. Provedor fica no Hetzner; se faltar RAM, cpx51 (~€60) ou AX42 (~€68-97), sempre abaixo do teto de R$ 1.000/mês.
3. ARM não é bloqueio (wheels aarch64 ok, Dockerfile multi-arch).

## Fases e beads

| Fase | O quê | Bead | Estado (23/10) |
|---|---|---|---|
| 1 | Laboratório de restore | ga-ap2dd6, ga-3kmvyr | 1ª fatia fechada; restore real do hq com hold até 24/10 |
| 2 | Workers, revisores e testes no nó | ga-2hd02v (filhas .3 WA, .4 PS) | WA no nó com 3 vagas; PS em sombra |
| 2b | MBP como nó de capacidade | ga-sokx7u | aberta |
| 3 | Motor (Pilot/gate) no nó, Dolt fica no mini | ga-puml3i | medir latência mini↔nó primeiro; se não couber, o motor fica no mini |

## Quando revisar

- Disco do mini abaixo do piso de forma recorrente com o hq acima de ~10 GB: reabrir o GC no nó, não o flatten.
- ga-puml3i aprovar a latência: abrir as fatias de migração do motor e atualizar a tabela acima.
- Nó travar por RAM: subir de plano (regra 2).
