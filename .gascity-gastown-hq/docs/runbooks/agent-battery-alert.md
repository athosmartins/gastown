# Bateria de agentes — aviso de queda, merge causador e controle negativo (ga-hyp55ss.4, fatia 4)

## Contents

- O que faz
- Ligar
- A regra da queda
- O merge causador
- Controle negativo
- Onde grava
- Medido e NÃO verificado

## O que faz

Fatia 4 da bateria (ga-hyp55ss): a 3 mede toda noite e a cada mudança de configuração (`agent-battery-night.md`), **esta compara**. A ordem `hetzner-agent-battery-alert` (a cada 20 min) lê as linhas novas de
`$GC_CITY_PATH/.gc/logs/agent-battery.jsonl` e, para cada papel medido, compara a taxa com a mediana das últimas noites **do mesmo acervo** (o driver passou a gravar `papeis.<papel>.acervo`, o sha256 do acervo medido). Queda que a sorte
não explica = e-mail ao Mayor + rótulo `audit:bateria-queda` (e um comentário com os números) nas beads dos commits que mexeram na configuração do papel entre as duas medições. Só mede e avisa: não bloqueia merge.

## Ligar

1. As fatias 1-3 no ar (acervo, `ABN_TOKEN_CMD`, bandeira do nó: ver `agent-battery-night.md`) e **3 noites seguidas com relatório**: sem 3 noites do mesmo acervo não há base e nada é avisado.
2. `gc order show hetzner-agent-battery-alert`; a 1ª volta só grava a base (`.gc/agent-battery/alert-state.json`), então o histórico que já existe nunca vira uma enxurrada de avisos velhos.
3. Depois das 3 noites, rode o controle uma vez (abaixo). `python3 -I scripts/agent-battery-alert.py --help` lista as opções; cada uma vem também de `ABA_<NOME>`.

## A regra da queda

Para cada papel com `cat: ok` na linha nova: `mediana` = a das últimas `--janela` (5) **noites** do mesmo papel e do mesmo acervo (medida de merge não entra: é a de uma configuração que acabou de mudar); precisa de `--min-noites` (3).
- **Queda** = a taxa ficou ao menos `--limiar` (0,20 = 20 pontos) abaixo da mediana **e** a chance de ver tantos acertos se o papel ainda acertasse a mediana é no máximo `--alfa` (0,10; binomial, mediana presa a no máximo 95%: uma base de 100% não quer dizer p=1).
- **Ruído** = do tamanho do limiar mas cabendo na sorte: só vai ao log de decisões. Com 5 tarefas só um colapso aparece (de 80%, até 2 acertos de 5); com 20 já se vê 80% → 60%. A amostra pequena protege o Mayor de aviso falso.
- **Sem base / sem acervo** (menos de 3 noites do acervo de hoje; linha de formato antigo): não avisa. Linha cujo papel não foi medido (`falhou`, `inerte`, `pulado`) não é avaliada: nunca vira taxa 0.
- **Uma vez por queda**: a mesma configuração ainda baixa na noite seguinte é `persistente` e não repete o e-mail; volta a valer quando a taxa se recupera, ou quando a configuração muda e continua baixa.
- **Medida com o prompt trocado não é rodada**: o driver grava `role_prompt` na linha quando roda com `--role-prompt` (o controle, ou alguém testando à mão na cidade real); a varredura a ignora, não a usa como base e nunca marca bead por causa dela.

## O merge causador

Entre a medição anterior do papel (qualquer modo) e a atual, o `config_sha` mudou? Então `git log <ref anterior>..<ref atual> -- <caminhos>` no clone da cidade, com os caminhos que o executor usa para o `config_sha` (`.claude/`, `CLAUDE.md`,
`<cidade>/CLAUDE.md` e o prompt do papel: lidos de `agent-battery-run.py`, uma fonte só). A bead sai do assunto `tipo(<bead>): ...`; cada uma recebe `bd -C <cidade> label add <bead> audit:bateria-queda` e um comentário.
- Marca no máximo `--max-marcar` (5) beads; acima disso o e-mail lista tudo e **não marca ninguém** (um intervalo grande demais não aponta ninguém). Commit sem bead no assunto é listado, não marcado.
- **Sha igual** nas duas medições: não houve merge de configuração; o e-mail diz isso e nada é marcado (a causa é o modelo, o nó ou a sorte). **Git sem resposta** (o clone não tem o commit): o e-mail sai sem marca e diz «não consegui listar».
- É lista de **candidatos**, não prova de causa. Ver as marcadas: `bd list --label audit:bateria-queda --limit 0`. Tirar: `bd label remove <bead> audit:bateria-queda`. Nenhum script do repositório lê esse rótulo (grep em 28/11). O `bd create --parent` copia os rótulos do pai para a filha; o prefixo `audit:` é um dos que a política de herança (espelhada em `child-cycle-labels-sweep.py`) deixa de fora, mas o patch que a aplica no `bd` (ga-y5z6hzh) está em `docs/pending-engine-window` sem a marca APLICADO e o README dele mediu, em 31/10, que o `bd` vivo ainda não a tinha: um follow-up criado a partir de uma bead marcada pode herdar o rótulo.
- Ordem: e-mail primeiro, marcas depois. E-mail que falha = nada marcado e a linha fica para a próxima volta (exit 1); marca que falha = exit 1 com o motivo, e o e-mail já nomeou a bead.

## Controle negativo

`python3 -I scripts/agent-battery-alert.py control [--role dog]` prova que a bateria **enxerga** uma regressão. Roda o driver da noite uma vez numa cidade descartável (o jsonl, os relatórios e o estado reais não são tocados), com
`--role-prompt <papel>=scripts/agent-battery-control-prompt.md`: o executor lê esse arquivo (uma instrução inútil, «não leia nem edite nada, responda feito») **no lugar do prompt do papel**, no nó, e nenhum commit é feito: a main não muda e o
arquivo não é prompt de nenhum papel nem caminho de configuração (o gatilho de merge não o vê). Julga pela mesma regra da queda e manda o resultado ao Mayor, com `CONTROLE: <x>` na última linha:
- **PASSOU** (exit 0): a taxa caiu e o aviso teria disparado. É o «pronto quando» da ga-hyp55ss junto com as 3 noites.
- **FALHOU** (exit 1): a taxa **não** caiu o bastante (a bateria não enxerga regressão: acervo fácil demais, ou o agente ignora o prompt anexado) ou o driver não mediu (o e-mail diz qual).
- **INERTE** (exit 0): sem base de 3 noites no acervo de hoje (checado **antes** de gastar), sem acervo, sem credencial, nó desligado ou outra rodada em andamento.

Custo: **gasta tokens de verdade**. O teto é o `--night-cap` do papel (1,2 M por dia UTC, somado entre rodadas do mesmo estado); o gasto real de um controle com o prompt ruim não foi medido. Estado do nó em `<node-state>-control`, separado da noite. O arquivo do prompt precisa estar na `origin/main` do espelho do nó (≤ 5 min depois do merge).

## Onde grava

- `$GC_CITY_PATH/.gc/agent-battery/alert-state.json`: quantas linhas do jsonl já foram vistas e, por papel, se está em queda e com qual `config_sha`. Ilegível = exit 1 sem avaliar nada; apague-o para regravar a base.
- `$GC_CITY_PATH/.gc/logs/agent-battery-alert.jsonl`: uma linha por papel avaliado (`kind`: `sem_acervo`, `sem_base`, `ok`, `ruido`, `queda`, `persistente`; `taxa`, `base`, `noites`, `queda`, `p`, `marcadas`). Responde «por que não avisou?».
- E-mail ao Mayor por `gc --city <cidade> mail send mayor`; rótulo e comentário por `bd -C <cidade>`.

## Medido e NÃO verificado

**Medido (28/11, neste nó):** `bash scripts/agent-battery-alert.selftest.sh` (133 verificações, ≈ 20 s; varredura sobre jsonl e um repositório git sintético, controle contra o driver REAL com ssh e executor de mentira) e o selftest do driver (110, as 5 novas: `acervo` e `role_prompt` no jsonl,
`acervo` torto vira `null`, papel que falhou traz a chave `acervo`, repasse de `--role-prompt`). Campanha de mutantes de um defeito por vez, com o original passando antes pelo mesmo caminho: 95 de 95 mortos no `agent-battery-alert.py` e 9 de 9 nas linhas que mudei no driver. O executor REAL
(`--dry-run` contra o espelho do nó) aceita `--role-prompt` e troca o `config_sha` do papel no mesmo commit, com o `origin/main` do espelho idêntico antes e depois. O lint do work-order fica em 37 achados antes e depois (o `--limit` do driver, da fatia 3, só mudou da linha 108 para a 109).

**NÃO verificado:**
- Nenhuma chamada real a `bd label add`/`bd comment` e a `gc mail send` (o atalho do nó não as passa): a sintaxe é a de scripts em produção (`athos-acao-guard.py`, `child-cycle-labels-sweep.py`, `hetzner-occupancy-watch.py`). O driver da noite chama `gc mail send mayor` **sem** `--city`; esta ordem usa `--city`.
- A ordem nunca foi carregada por um `gc order` vivo; o git do clone do nó é parcial, então o histórico real só foi exercitado num repositório sintético.
- O controle nunca rodou de verdade (sem chave nesta sessão): se um prompt anexado derruba mesmo a taxa do `claude` é o que ele mede. Os limiares (20 pp, 0,10, janela 5, mínimo 3 noites) são palpite até haver noites reais.

**Limites que ficam:**
- A base anda: depois de ~3 noites baixas a mediana as acompanha e a queda deixa de ser vista; o aviso é um só por regressão e o relatório da noite segue mostrando a taxa.
- Troca de acervo (o acervo da fatia 1 refeito) zera a base: 3 noites sem aviso. O `config_sha` não enxerga os `global_fragments` do `city.toml` (limite da fatia 2): merge só neles não dispara medida nem aviso.
- `ok` é «o selftest da bead passa», não «a mudança é boa».
