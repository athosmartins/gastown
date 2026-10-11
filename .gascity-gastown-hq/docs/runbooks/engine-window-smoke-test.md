# Smoke-test de janela de engine (`gc`) — todos os subcomandos

**Rode o Passo A ANTES de trocar o binário `gc` e o Passo B DEPOIS de cada swap.** A janela só
termina quando o Passo B fecha sem nenhum `FAIL` e sem `UNKNOWN` esquecido. Este checklist nasceu
do `ga-q119gk`: em 08/09 o smoke-test de uma janela cobriu `version` / `doctor` / `bd`, passou, e a
cidade ficou ~3 h sem o grupo `gc dolt` inteiro.

Referência desta versão: binário `gc-1.1.1-engwin0919` (`gc version` → `engwin-20260919`), medido
em 2026-10-11 com a máquina sob load ~55. O baseline de comandos
(`engine-window-smoke-test.baseline.txt`, 205 linhas = 55 comandos + 150 subcomandos) é desse binário.

---

## O que aconteceu em 08/09, e por que o smoke-test não pegou

- Janela do `ga-165vq` (12:25–15:26 locais): binário `gc-1.1.1-engwin0908-ga165vq`, buildado de
  `upstream/main` (`042e965f0`, gastownhall/gascity, 2026-09-08) e não do fork. Compilou limpo, os
  testes do patch passaram, o smoke-test ficou verde — e o grupo `gc dolt` (14 subcomandos) tinha
  sumido. Foi descoberto ~3 h depois, por acidente. Rollback: symlink de volta + kickstart do
  supervisor.
- **Por que passou:** o smoke-test cobria o que o PATCH tocava (e `version`/`doctor`/`bd`). O patch
  não tinha nada a ver com `dolt`, então o ponto cego era exatamente o que ninguém estava olhando.
  Uma lista fixa de "tudo que `gc --help` anuncia" não depende de lembrar o que o patch mexe.
- **Causa raiz — foi de propósito do upstream, não regressão.** Evidência lida no código do
  upstream em `042e965f0` (via GitHub; **não** reproduzida executando o build na cidade):
  `internal/bootstrap/packs/` contém só `core`; `BootstrapPacks` é declarada **vazia** com o
  comentário "cities rely on explicit pinned [imports], not user-global implicit imports"; e um
  pack `dolt` só existe como exemplo (`examples/bd/dolt`). Já o `gc dolt` desta cidade vem dos
  packs de sistema materializados pelo fork (`.gc/system/packs/dolt`, `~/.gc/system/packs/dolt`) —
  o `city.toml` só importa `gastown` e `town-deltas`, e `gc --help` rotula o grupo como
  "Commands from the dolt import". Medido hoje: com o binário vivo, `dolt` e `gastown` aparecem em
  `gc --help` mesmo fora do diretório da cidade, então o cwd NÃO é o discriminador.
  **Não verificado:** se declarar `[imports.dolt]` explícito no `city.toml` traria o grupo de volta
  no build upstream.
- **Consequência prática:** `upstream/main` não é base drop-in para esta cidade. Se o Passo A
  ficar vermelho em `dolt` (ou em qualquer outro grupo) com um candidato upstream, o problema é a
  **base**, não o patch — pare e decida a migração para imports explícitos antes de buildar de lá.

---

## Como ler o resultado — três estados, nunca dois

| estado | quando | o que fazer |
|---|---|---|
| `PASS` | rc=0 **e** a assinatura esperada apareceu | segue |
| `FAIL` | rc≠0 (e ≠124), ou a assinatura sumiu | **não aceite o swap**; rollback (abaixo) |
| `UNKNOWN` | `timeout` (rc=124) ou a sonda não pôde rodar | **não conta como PASS.** Rode de novo sozinha; se continuar `UNKNOWN`, alguém lê a saída antes de fechar a janela |

- **Timeout:** 120 s serve para quase tudo; use **300 s** em `status`, `doctor`, `gastown status`,
  `convoy list` e `mail count` (medido 11/10 com load 55–60: `gc version` 9 s, `gc bd list` 18 s,
  `mail count` 57 s, `convoy list` 104 s). **`status`, `doctor` e `gastown status` estouraram até os
  300 s no binário bom** — sob load alto eles dão `UNKNOWN` por natureza. Não pare no primeiro
  `UNKNOWN` de load — pare no segundo, e leia o `UNKNOWN` como "sem informação", nunca como `PASS`.
- Linhas `warning:` / `WARN` no meio da saída (builtin pack divergente, `config show`,
  `native_store_unavailable`) são ruído de 11/10 e **não** mudam o estado; só rc e assinatura contam.
- Cada chamada `gc` leva 3–30 s com a máquina saturada. O B1 inteiro (56 chamadas) levou **334 s**
  medido em 11/10, e o Passo A (56 chamadas também) levou **434 s**: reserve ~8 min para o A, ~6 min
  para o B1 e até ~20 min para o B2 (as três sondas de 300 s podem estourar). Não rode sondas em
  paralelo (aumenta o load e produz `UNKNOWN` falso).

---

## Passo A — ANTES do swap: o candidato perdeu algum comando? (teria pego 08/09)

Compara a superfície de comandos do binário **candidato** (ainda NÃO linkado) com o baseline
versionado. Só leitura: roda `--help` de cada comando, não chama nada que mude estado.

```bash
cd "$GC_CITY_PATH"
BASE="$GC_CITY_PATH/docs/runbooks/engine-window-smoke-test.baseline.txt"
CAND=~/.local/libexec/gc-1.1.1-engwinYYYYMMDD     # o binário NOVO, ainda fora do symlink
OUT=$(mktemp -d)

surface() {  # $1 = binário gc; imprime "cmd" e "cmd sub", um por linha, ordenado
  b=$1
  sec='/^[A-Z][A-Za-z ]*:$/{f=($0=="Available Commands:");next} f&&NF{print $1}'
  "$b" --help 2>/dev/null | awk "$sec" | while read -r c; do
    echo "$c"
    "$b" "$c" --help 2>/dev/null | awk "$sec" | sed "s/^/$c /"
  done | LC_ALL=C sort
}

# vazio → UNKNOWN (o binário não rodou; nunca PASS); falhou/ilegível → também vira vazio → UNKNOWN
surface "$CAND" > "$OUT/cand.txt"
if [ ! -s "$BASE" ] || [ ! -s "$OUT/cand.txt" ]; then
  echo "UNKNOWN: baseline ou candidato vazio — o binário nem rodou? NÃO trate como PASS"
elif [ -n "$(comm -23 "$BASE" "$OUT/cand.txt")" ]; then
  echo "FAIL — o candidato PERDEU (existia no baseline):"; comm -23 "$BASE" "$OUT/cand.txt"
else
  echo "PASS"; echo "novos no candidato (informativo — atualize o baseline se for intencional):"
  comm -13 "$BASE" "$OUT/cand.txt"
fi
```

- Rodado literalmente contra o binário vivo em 11/10: `PASS`, nenhum "novo", 434 s.
- `FAIL` aqui **bloqueia o swap**. O 08/09 teria saído como `FAIL — o candidato PERDEU: dolt;
  dolt cleanup; … dolt sync` (15 linhas) com o binário ainda no disco e a cidade intocada.
- Candidato que nem executa dá `surface` vazio → `UNKNOWN`, nunca `PASS` (erro ≠ "nada a reportar").
- `gc bd` é só repasse para o binário `bd` (usa outros cabeçalhos de ajuda, não "Available
  Commands:"), então os subcomandos dele **não** entram no baseline; o `bd` é coberto no Passo B.
- **Atualizar o baseline:** só quando a mudança de comando for INTENCIONAL (upstream renomeou,
  patch adicionou), no mesmo commit da janela. **Nunca gere o baseline a partir do candidato para
  deixar o Passo A verde** — isso apaga o detector. Para regenerar do binário vivo depois de uma
  janela aceita: `surface "$(readlink -f "$(command -v gc)")" > "$BASE"`.

---

## Passo B — DEPOIS do swap: cada comando responde?

### B1 — todo comando de `gc --help` responde `--help` (rc=0)

```bash
cd "$GC_CITY_PATH"
gc version        # tem de imprimir o tag do candidato (ex.: engwin-20260919); outro valor = swap não pegou
# vazio (sem lista) → o contador final sai 0 ≠ 55 = falha, não "tudo certo"; falhou → rc≠0 vira FAIL, rc=124 vira UNKNOWN
for c in $(gc --help 2>/dev/null | awk '/^[A-Z][A-Za-z ]*:$/{f=($0=="Available Commands:");next} f&&NF{print $1}'); do
  timeout 120 gc "$c" --help >/dev/null 2>&1; rc=$?
  case $rc in 0) r=PASS ;; 124) r=UNKNOWN ;; *) r=FAIL ;; esac
  echo "$r $c (rc=$rc)"
done | sort | tee "${OUT:-/tmp}/help.txt" | grep -v '^PASS' ; grep -c '^PASS' "${OUT:-/tmp}/help.txt"
```

Saída esperada: nenhuma linha `FAIL`/`UNKNOWN` e o **contador final = 55** (nº de comandos do
baseline). Lista vazia ou contador menor não é "tudo certo" — é `gc --help` que falhou.
(Rodado literalmente em 11/10 no `engwin0919`: `engwin-20260919`, nenhum `FAIL`/`UNKNOWN`, contador 55, 334 s.)

### B2 — sondas funcionais (só leitura) e o que cada comando significa

Rode de dentro da cidade (`cd "$GC_CITY_PATH"`), **uma sonda por vez**, na ordem da tabela. Cada
linha diz o que tem de aparecer para ser `PASS`; sem a assinatura é `FAIL` mesmo com rc=0 (vazio ≠
sucesso), e `timeout` é `UNKNOWN`. `timeout 120` é o padrão; as linhas marcadas **300 s** usam
`timeout 300`. Todas são só leitura. Assinaturas medidas em 11/10 com `engwin0919` (menos as três
linhas que dizem "não medida"); os valores que mudam com o estado da cidade (contagens, PIDs,
nomes) estão entre `<>`.

#### Grupo A — 33 comandos com sonda funcional

| comando | sonda | `PASS` = rc e assinatura | notas / como falha |
|---|---|---|---|
| `version` | `gc version` | rc=0 e imprime o tag do candidato (`engwin-20260919`) | tag diferente = o symlink não pegou |
| `status` | **300 s** `gc status` | rc=0 e saída não vazia. **Assinatura completa não medida**: em 11/10 (load ~60) estourou 120 s e depois 300 s no binário bom, imprimindo só `gc status: loading session snapshot timed out after 3s; continuing with runtime-only status` | `UNKNOWN` sob load alto, mesmo no binário bom — não é sinal do candidato. Repita com a máquina calma e **grave aqui** a assinatura que aparecer. Enquanto isso a existência vem do B1 |
| `doctor` | **300 s** `gc doctor` | o rc de baseline **não foi medido**: nunca terminou em 300 s (load ~60). Imprimiu, na ordem, `✓ city-structure — city.toml present`, `✓ city-config — city.toml loaded (0 agents, 5 rigs)…` e os `✓ v2-*` | há pelo menos um check com `hint:` (contrato legado `graph.v2`) no binário bom, então rc≠0 pode ser o normal. Rode o mesmo comando no binário **anterior** com a mesma carga e compare a lista de checks `✓` em vez de esperar um rc fixo. `UNKNOWN` sob load não é falha |
| `bd` | `gc bd list --limit 1` | rc=0, uma linha de bead e `Showing 1 issues…` | repasse ao binário `bd`; falha aqui pode ser o Dolt, não o `gc` — confira com `gc dolt status` |
| `beads` | `gc beads health` | rc=0 e `Beads provider: healthy` | |
| `agent` | `gc agent list` | rc=0 e cabeçalho `Agents in <cidade>:` | |
| `cities` | `gc cities list` | rc=0, cabeçalho `NAME  PATH` e a linha da cidade (`gascity  <GC_CITY_PATH>`) | |
| `config` | `gc config show --validate` | rc=0 | despeja muitos `warning:` — ruído; só o rc conta |
| `converge` | `gc converge list` | rc=0 e `No convergence loops found.` (ou uma tabela) | |
| `convoy` | **300 s** `gc convoy list` | rc=0 e tabela `ID  TITLE  PROGRESS` | 104 s medido com load 55; `WARN native_store_unavailable` para rigs sem `bd` é ruído |
| `dolt` | `gc dolt status` e `gc dolt list` | rc=0; `status` → `running`; `list` → uma linha por DB, incluindo `hq` | **o grupo que sumiu em 08/09.** `gc: unknown command "dolt"` = `FAIL` e rollback |
| `dolt-cleanup` | `gc dolt-cleanup` (**nunca** `--force`) | rc=0, `DROPPED-DATABASE DIRECTORIES (<n>)` e `ORPHAN dolt sql-server PROCESSES (<n>)` | sem `--force` só relata, não apaga; as contagens `<n>` variam, os dois cabeçalhos não |
| `formula` | `gc formula list` | rc=0 e nomes `mol-*` | lista vazia = `FAIL` (vazio ≠ sucesso) |
| `gastown` | **300 s** `gc gastown status` | rc=0 e a saída começa com `Gastown status for <cidade>` e `City: <caminho>`. O resto **não foi medido**: estourou 120 s e 300 s no binário bom depois de imprimir só essas duas linhas | mesmo caso do `status`: `UNKNOWN` sob load alto; repita com a máquina calma e grave a assinatura completa |
| `import` | `gc import check` | rc=0 e `Import state OK: <n> remote import(s) checked` | **não use `import list`**: hoje é vazio com rc=0 (os dois imports são caminho local), então não prova nada |
| `mail` | **300 s** `gc mail count` | rc=0 e `<n> total, <n> unread for <agente>` | 57 s medido com load 55; dentro de uma sessão o `<agente>` é o da sessão, fora dela é `human` |
| `maintenance` | `gc maintenance status` | **não tem `PASS` funcional** — hoje dá rc=2 e `supervisor not running (controller-down)` mesmo com o supervisor de pé | quirk de baseline, reproduzido no binário bom: rc=2 com essa mensagem é o esperado; `gc: unknown command`, panic ou outro rc = `FAIL`. A prova de existência é o B1 (`--help`). Se um binário futuro corrigir o quirk (rc=0 com status real), atualize esta linha |
| `mcp` | `gc mcp list --agent <template>` (ex.: `gastown.dog`) | rc=0 e `Provider:` … `No projected MCP servers.` (ou a lista) | sem `--agent`/`--session` dá rc=1 pedindo o alvo — isso não é falha do binário |
| `nudge` | `gc nudge status` | rc=0 e cabeçalho `AGENT  PENDING  IN_FLIGHT  DEAD  SESSION` | |
| `order` | `gc order list` | rc=0 e cabeçalho `NAME  TYPE  TRIGGER  INTERVAL/SCHED  RIG  TARGET` | |
| `pack` | `gc pack list` | rc=0 e `No remote packs configured.` (ou a lista) | |
| `rig` | `gc rig list` | rc=0, `Rigs in <cidade>:` e a linha `gascity (HQ)` | |
| `runtime` | `gc runtime drain-check` | **rc=1 e saída vazia** (a sessão não está drenando) | igual dentro e fora de uma sessão de agente (medido); rc=0 significa "esta sessão está drenando"; `gc: unknown command` = `FAIL` |
| `service` | `gc service list` | rc=0 e `No services configured.` (ou a lista) | |
| `session` | `gc session list` | rc=0 e cabeçalho `ID  TEMPLATE  STATE …` | |
| `shell` | `gc shell status` | rc=0 e `Shell integration is not installed.` (ou instalado) | |
| `skill` | `gc skill list` | rc=0 e cabeçalho `NAME  FROM  PATH` | |
| `supervisor` | `gc supervisor status` | rc=0 e `Supervisor is running (PID <n>)` | o `<n>` tem de ser o PID do `launchctl print gui/$(id -u)/com.gascity.supervisor` |
| `trace` | `gc trace status` | rc=0, `Controller running: true` e `Controller PID: <n>` | |
| `wait` | `gc wait list` | rc=0 e cabeçalho `WAIT  SESSION  STATE  KIND  NOTE` | |
| `help` | `gc help` | rc=0 e a 1ª linha `Gas City CLI — orchestration-builder for multi-agent workflows` | |
| `completion` | `gc completion zsh` | rc=0 e a 1ª linha `#compdef gc` | |
| `prime` | `gc prime` | rc=0 e a 1ª linha é um cabeçalho `# …` (`# Dog Context` dentro de uma sessão de dog; `# Gas City Agent` fora de sessão) | |

#### Grupo B — 22 comandos só com `--help` (**nunca execute**)

Estes mudam estado, derrubam ou sobem a cidade, ou exigem um alvo/argumento que um smoke-test
genérico não tem. A classificação vem do texto do `--help` de cada um; **nenhum foi executado**. Para
eles o B1 (`gc <cmd> --help` com rc=0) **é** o teste — e o Passo A já pega o desaparecimento.

| comando | por que só `--help` |
|---|---|
| `agent-script` | roda um script YAML de demo |
| `analyze` | relatórios sobre o log de eventos; exige entradas |
| `build-image` | monta um contexto Docker (escreve em disco) |
| `dashboard` | abre o dashboard (servidor/navegador) |
| `event` | só tem `emit`, que escreve no log de eventos da cidade |
| `events` | lista eventos da API; não sondado (filtros/stream) |
| `github` | monitor de PRs via API externa do GitHub |
| `graph` | exige beads ou um convoy como argumento |
| `handoff` | dispara o handoff de contexto — reinicia a sessão de quem chama |
| `hook` | busca trabalho roteado pela `work_query` do agente; sem sessão de agente não há alvo |
| `init` | cria um workspace |
| `lint` | valida um pack; exige o caminho |
| `prompt` | autoria de templates de prompt |
| `register` | registra a cidade no supervisor |
| `reload` | força o controller a reler a config |
| `restart` | para e sobe a cidade inteira |
| `resume` | tira a cidade de `suspended` (edita o `city.toml`) |
| `sling` | roteia um bead para um agente (cria trabalho) |
| `start` | sobe a cidade sob o supervisor |
| `stop` | derruba todas as sessões da cidade |
| `suspend` | suspende a cidade (edita o `city.toml`) |
| `unregister` | remove a cidade do registro do supervisor |

**Conferência de cobertura:** 33 + 22 = 55 = os comandos do baseline. Para provar que a tabela não
deixou nenhum de fora depois de uma janela que adicione comandos, rode:

```bash
R="$GC_CITY_PATH/docs/runbooks"
[ -s "$R/engine-window-smoke-test.baseline.txt" ] || echo "UNKNOWN: baseline vazio/ilegível — a conferência não rodou"
grep -v ' ' "$R/engine-window-smoke-test.baseline.txt" | while read -r c; do
  grep -q "^| \`$c\` |" "$R/engine-window-smoke-test.md" || echo "SEM LINHA NA TABELA: $c"
done
```

Qualquer `SEM LINHA NA TABELA` = comando novo sem sonda: classifique-o no Grupo A ou B no mesmo
commit que atualiza o baseline.

---

## Rollback (qualquer `FAIL` no Passo B, ou `UNKNOWN` que não limpa)

Mesmo caminho do deploy (doc `ga-ftmci-dolt-cpu-engine-window.md`): o symlink é trocado de volta e
**só o supervisor** é reiniciado — Mayor e runtimes vivos seguem de pé, e só os spawns novos pegam
o binário. Não reinicie a cidade inteira para forçar.

```bash
ln -sf <binário anterior> /opt/homebrew/bin/gc      # ex.: ~/.local/libexec/gc-1.1.1-engwin0919
launchctl kickstart -k gui/$(id -u)/com.gascity.supervisor

# prove pelo PROCESSO, não pelo symlink (verificado 11/10: supervisor pid 800 → engwin0919):
PID=$(launchctl print gui/$(id -u)/com.gascity.supervisor | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\)$/\1/p' | head -1)
lsof -p "$PID" -a -d txt -Fn | grep '/gc-'          # tem de mostrar o binário ANTERIOR
```

Depois do rollback, rode o **B1** de novo — o binário antigo tem de voltar a `PASS` em tudo.
Se o B1 do binário antigo também falhar, o problema é o ambiente (load, Dolt), não a troca.

---

## Limites conhecidos (o que este checklist NÃO prova)

- **`status`, `doctor` e `gastown status` não têm assinatura completa medida:** os três não
  terminaram em 300 s com o binário bom (load ~60). Hoje eles só provam existência (B1) e, quando
  terminam, rc/saída precisam ser comparados com o binário anterior. Medir isso com a máquina calma
  e gravar a assinatura na tabela é pendência desta doc.
- Prova **presença, exit code e assinatura**, não comportamento. Um comando que existe e responde
  `--help` pode estar quebrado ao executar; o B2 cobre a leitura básica dos que têm forma segura.
- Comandos que mudam estado ou sobem/derrubam processos só têm o `--help` testado (tabela B2).
  Rodar `gc stop`, `restart`, `handoff` etc. "para testar" numa cidade viva derruba as sessões.
- O Passo A mede a superfície **declarada**. Um comando que aparece em `--help` mas falha só ao
  executar passa o A e é pego (se tiver sonda) no B2.
- O build de `upstream/main` de 08/09 **não** foi re-executado para esta doc: rodá-lo na cidade de
  produção seria repetir o incidente. A prova do detector foi (a) o baseline contra o binário vivo
  (sem diferenças) e (b) um candidato simulado sem `dolt` (as 15 linhas acusadas).

## Relacionados

- `ga-q119gk` — o incidente e este checklist · `ga-165vq` — o patch da janela de 08/09
- `janela-manutencao-bd-e-engine.md` — a janela em si (Passo 3 tem as verificações de cidade:
  `gc dolt health`, `pool-probe.selftest.sh --live`); este doc cobre os **comandos** do `gc`
- `ga-ftmci-dolt-cpu-engine-window.md` — mecânica de deploy/rollback (symlink + kickstart)
