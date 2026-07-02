# /status — Tabela de problemas e status da sessão

Use este comando para exibir e manter a tabela de problemas reportados pelo overseer.

## Regras obrigatórias

1. **Exiba a tabela no início de CADA resposta ao overseer** — sem exceção.
2. **Adicione imediatamente** qualquer problema novo que o overseer mencionar.
3. **Atualize o status** sempre que um bead mudar de estado.
4. **Remova itens** apenas quando o overseer confirmar que está ok.

## Como invocar

```
/status
```

Ao invocar, execute:
```bash
bd show <bead-ids> 2>&1 | grep -E "CLOSED|IN_PROGRESS|HOOKED|OPEN"
gt polecat list --all 2>&1
```

E monte a tabela com base nos resultados reais dos beads.

## Formato da tabela

| # | Problema | Bead | Status |
|---|----------|------|--------|
| N | Descrição curta | `hq-xxxxx` | 🔄 / ✅ / ⚠️ / 🧪 |

## Status

| Ícone | Significado |
|-------|-------------|
| 🔄 | Em andamento — polecat working |
| ✅ | Mergeado e confirmado pelo overseer |
| 🧪 | Mergeado — aguardando teste do overseer |
| ⚠️ | Bloqueado / aguardando input |
| ❌ | Falhou — precisa re-dispatch |

## Para crew members

Qualquer agente pode usar `/status` para ver o estado atual dos problemas da sessão.
Para adicionar um problema: crie o bead com `bd create`, sling para o polecat adequado, e adicione à tabela.
