# Preâmbulo por tarefa (ga-aijm2v.7, etapa 2) — SOMBRA

**Estado:** a **sombra** está pronta no branch `feat/ga-aijm2v.7-preambulo-por-tarefa`; NADA está vivo até o gate mergear e a order `jev-preambulo` ser carregada.
Mesmo depois disso **nenhuma sessão perde uma linha de doutrina**: todo registro sai com `aplicado: false`. A sombra só grava o que o Jev *cortaria*,
para o Athos ver o tamanho do prêmio e o risco antes de qualquer corte real. **O A/B ao vivo (critérios de economia por sessão e de aprovação no gate por braço) NÃO está entregue** —
depende de uma entrada por sessão que o `gc prime` hoje não tem (seção "O que a sombra ainda não responde").

## O que faz

Para cada bead roteada a um pool (`gc.routed_to` = `gastown.dog` / `wa-worker` / `ps-worker`) que uma sessão pegou (atribuída, em andamento ou fechada), a order horária
`jev-preambulo` pergunta ao Jev **uma vez** (uma pergunta `noul` por seção elegível, até 13 por chamada) *"esta tarefa precisa das regras de <seção>?"* e grava em
`jev-experiment.jsonl` (`mode: "preambulo"`) quais seções ele dispensaria. O relatório diário das 21:07 ganhou o bloco "Preâmbulo" (`jev_preambulo_report.py`).

Onde está cada coisa:

| peça | arquivo |
|---|---|
| política (o que pode ser cortado, limiar, pisos, marcadores de injeção) | `packs/town-deltas/assets/claude-overlays/pool-roles.json` → `doctrine.per_task` |
| validação da política (`check`) e teto por papel (`per-task`) | `packs/town-deltas/assets/pool-preamble-build.py` |
| consumidor (Jev → decisão → log) | `scripts/jev_preambulo_experiment.py` (`run`, `explain`) |
| relatório (junta o log do gate na hora de ler) | `scripts/jev_preambulo_report.py` |
| order + wrapper (cooldown 1h, `timeout`, `nice`, flock) | `packs/town-deltas/orders/jev-preambulo.toml`, `assets/scripts/jev-preambulo.sh` |
| testes | `scripts/jev-preambulo.selftest.sh` (207 checagens), `assets/tests/jev-daily-report.test.sh` (bloco T11) |

## Regras de corte (todas declaradas no manifesto, todas provadas por `pool-preamble-build.py check`)

Uma seção só é **cortada** (na sombra: só registrada como cortável) quando **todas** valem:

1. está em `per_task.eligible` **e** é entregue àquele papel — o núcleo, `never_cut` e qualquer id fora do manifesto (inclusive um que o Jev invente) entram **sempre**;
2. o Jev respondeu **a pergunta daquela seção**, com resposta válida (`noul` em [0,1], finito);
3. P(precisa) **< limiar** (0,3 — inicial, ajustável pela medição). Exatamente 0,3 fica;
4. nenhum **piso estrutural** (`must_include`: `issue_type`, chave de metadata, label ou regex no texto) disparou — ex.: bead de molecule mantém `graph-v2-formulas`, texto que fala em "mockup/UI/HTML/tela" mantém `mockup-s3`, "engine rebuild/binary swap/engine window" mantém `engine-window-patch`;
5. o texto da tarefa não tem **marcador de injeção** (`per_task.injection_markers`) — com marcador, o Jev nem é chamado e tudo fica.

**Terceiro estado, sempre:** Jev fora, lento, sem credencial, resposta malformada ou parcial ⇒ aquela seção **fica** (`motivo: jev_indisponivel`), nunca é cortada.
Uma resposta ruim estraga só a *sua* seção. Três falhas seguidas do Jev param a passada (circuit breaker); uma bead que falha 3x fica com a decisão "tudo fica" e não é reperguntada.

Elegíveis hoje (`pool-preamble-build.py per-task`; tokens **estimados**, 2,2 chars/token):

| papel | elegíveis | teto (se dispensasse TODAS) | doutrina entregue |
|---|---|---|---|
| dog | `graph-v2-formulas`, `engine-window-patch`, `nudge-permission-dialog` | ≈ 4.235 tok (9.318 chars) | 52.234 chars |
| wa-worker / ps-worker | + `mockup-s3`, `assignee-when-building` (sem `nudge-permission-dialog`) | ≈ 5.913 tok (13.009 chars) | 54.359 chars |
| revisores | nenhuma | 0 | 31.634 chars |

**Nunca corta** (`never_cut`, cada uma com o motivo escrito no manifesto): `claudemd-carryover`, `dolt-cleanup-hazards`, `research-only-channels`, `next-action-mayor-waiting` —
regras cuja relevância não é função do texto da tarefa e cuja falha não desfaz.

Contexto do teto: é um **teto**, não uma previsão. Sobre o 1º turno de sonda depois da etapa 1 (dog 21.309, wa-worker 22.870, ps-worker 22.724 tokens; doc `pool-preamble-per-role.md`) ele
equivale a ≈ 20% (dog) e ≈ 26% (workers); o corte real será menor, porque os pisos estruturais e o limiar seguram seções. O número que decide é o da sombra.

## O texto da tarefa é conteúdo de fora

Uma bead pode carregar texto escrito por qualquer um (página raspada, mensagem de lead colada na descrição). Ele chega a **um único lugar**: o campo `state` da chamada ao Jev
(só título, tipo, descrição e critérios — nunca notas/comentários/labels, onde o desfecho se acumula), dentro de `<conteudo_externo>…</conteudo_externo>` com a própria tag neutralizada por dentro.
O Jev devolve **números**; nada do texto é executado, interpolado num prompt de agente ou usado para nomear seção (respostas para ids que não perguntamos são ignoradas).
Marcador de injeção ⇒ nenhuma pergunta e nenhuma seção cortada. Falso positivo custa um preâmbulo cheio, nunca uma regra faltando.

## Medição (o que o bloco "Preâmbulo" do relatório diz, e o que não diz)

- **MEDIDO:** respostas do Jev; veredito do gate da 1ª revisão de cada bead (recalculado do `quality-gate.jsonl` na hora de ler — bead julgada depois do registro ainda conta).
- **ESTIMADO:** todo número de token (chars cortados ÷ chars por token). O teto vem impresso ao lado de qualquer média.
- **NÃO medido:** tokens por sessão por braço — exige sessões que recebam o corte de verdade; a sombra não tem nenhuma.
- **A/A:** o `arm` (50/50 determinístico por bead, `jev_experiment.assign_arm`) já é gravado. Enquanto todas as sessões recebem tudo, os dois braços **têm de parecer iguais no gate**; intervalos de Wilson por braço e de Newcombe para a diferença. Se não parecerem, a divisão está confundida e o A/B não vale.
- **Risco:** reprovação de 1ª tentativa cujo texto cita um termo da seção que o Jev cortaria (`cite_terms`). É **heurística e só pode errar para menos** — 0 é "sem evidência de dano", não "prova de que não há".
- Estados de terceira via aparecem à parte e nomeados (Jev falhou/parcial, bead que o gate nunca viu, motivo de reprovação ilegível, sem log do gate = "indisponível", nunca 0%).

## O que a sombra ainda não responde

1. **Aplicar de verdade.** A doutrina é filtrada por `TD_ROLE`, que é **env estático do agente** (`city.toml`/`agent.toml`); o `gc prime` renderiza no início da sessão. Uma sessão de pool
   **pega a bead depois do prime** (Step 1c do próprio prompt: probe → `--claim`). Logo, cortar por tarefa ao vivo pede uma **entrada por sessão no engine** (ex.: o prime saber a bead
   já atribuída, ou carregar as seções opcionais sob demanda depois do claim) — decisão de desenho do Mayor + patch em `docs/pending-engine-window/` (build+swap é janela do Mayor).
   *Não confirmado contra um engine atual:* a única árvore do engine que consultei (`~/gt/.local-patches/_src-hookfix`, de 17/08, scratch defasado) mostra o `gc prime` lendo só a identidade da sessão
   (`GC_SESSION_NAME/ID`, `GC_TEMPLATE`, `GC_ALIAS`) e nenhuma entrada de bead — reconfirmar contra `origin/main` do engine antes de desenhar o patch.
2. **Economia por sessão e aprovação no gate por braço** (critérios 5 e 6 da bead): só existem depois de (1). O limiar 0,3 e a lista `eligible` são ajustáveis pela sombra; seção cuja reprovação citada
   aparecer no A/B vira núcleo (mover de `eligible` para `never_cut` no manifesto).
3. **Amostra.** Medido em 26/09 com o próprio `discover` (só `bd list`, 6 stores lidos): 84 tarefas de pool no último dia (dog 68, wa-worker 16) e 328 em 4 dias (dog 141, wa-worker 187) ≈ 82/dia,
   ou seja ≈ 160 registros na sombra de 48h, divididos por papel, seção e braço. **ps-worker teve 0 tarefas na janela** (mesma lacuna da etapa 1): ele fica SEM DADO, não "sem cortes" — herdar a conclusão do wa-worker é decisão à parte.
   O relatório marca amostra pequena (< 10) e vão de tempo curto (< 48h) como preliminar. A 1ª passada engole a janela de 4 dias em ~6 rodadas (`--limit 60`).

## Operação

```bash
python3 packs/town-deltas/assets/pool-preamble-build.py check     # política coerente? (a order recusa rodar se não)
python3 packs/town-deltas/assets/pool-preamble-build.py per-task  # o que cada papel pode dispensar + teto
python3 scripts/jev_preambulo_experiment.py explain --store <rig> --bead <id>   # papel, elegíveis, pisos, injeção — sem Jev, sem escrita
python3 scripts/jev_preambulo_experiment.py run --dry-run --limit 5              # pergunta ao Jev de verdade, não grava
python3 scripts/jev_preambulo_report.py --resumo-pt                              # o bloco do relatório diário
bash scripts/jev-preambulo.selftest.sh                                           # 207 checagens, sem rede
```

- **Desligar:** `JEV_PREAMBULO_ENABLED=0` ou criar `.gc/logs/jev-preambulo.disabled` (uma cópia da regra, dentro do script). A order deixa de gravar; nada mais muda, porque nada aplica.
- **Política inválida:** o script sai 2 com o motivo e **não** roda (nem pergunta, nem grava) — o motivo cai no `.gc/logs/jev-preambulo.log`.
- **Custo:** ~4 s por tarefa nova (uma chamada por tarefa), limite `--limit` 60 por passada, `timeout` 900 s, `nice 10`, lock de instância única.
- **Reverter:** remover `orders/jev-preambulo.toml` (ou manter o `.disabled`). Não há efeito em sessão a desfazer; os registros já gravados ficam no `jev-experiment.jsonl`, inertes (`aplicado: false`), e o relatório genérico os ignora (`mode: "preambulo"`).
