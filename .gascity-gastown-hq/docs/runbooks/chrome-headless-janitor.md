# Faxineiro do Chrome headless (chrome-headless-janitor) · runbook

## Contents

• O que é · Causa · O que apaga e o que nunca apaga · Correção na origem (WA) · Instalar (Mayor, depois do merge) · Provar · Medido, lido no código, não testado

Bead ga-xjv29mb (achado do Mayor, 19/11). **Mergeado ≠ vivo: nada aqui está instalado** — o `.plist` só passa a valer depois do `launchctl bootstrap` abaixo. **A causa fica no rig WA e ainda não foi corrigida**: o janitor é só a rede de segurança (seção "Correção na origem").

## O que é
`scripts/chrome-headless-janitor.py`, a cada ~1 h pelo launchd do mini (`com.gascity.chrome-headless-janitor.plist`, `StartInterval` 3607). Apaga as pastas `scoped_dir*` que um Chrome headless deixa para trás. Pega também um chamador que ninguém achou ainda.

## Causa
- Desde o commit `d36b68b00` do Chromium (11/06/2026, bug 522307607, `chrome/browser/headless/headless_mode_init.cc`), um `chrome --headless` iniciado **sem** `--user-data-dir` faz para si um perfil descartável: uma `base::ScopedTempDir` chamada `scoped_dirXXXXXX` dentro de `<dir de dados padrão>-headless`. No mini: `~/Library/Application Support/Google/Chrome-headless/scoped_dirXXXXXX`. Antes do commit a pasta ia para o `$TMPDIR`, que o macOS limpa com o tempo (não verificado aqui); em Application Support ninguém limpa.
- O Chrome só a apaga em saída **ordenada** (o destrutor da `ScopedTempDir`). SIGTERM, SIGKILL e crash deixam a pasta para sempre (um shutdown que trava até o watchdog do próprio Chrome matar é o mesmo caso, por inferência). Relato com reprex no macOS para os sinais: rstudio/chromote#239; o crash foi visto no nó (abaixo). O issue 361615573 do Chromium está fechado como Won't Fix e a saída oficial é "o chamador passa o próprio `--user-data-dir`".
- **O chamador achado** (rig WA, não este): `tests/_chrome_dump_dom.py::dump_dom` (wa-d1wbl) monta `chrome --headless=new --disable-gpu --no-sandbox … --dump-dom <url>` sem `--user-data-dir` e dá `proc.kill()` (SIGKILL) assim que lê `</html>`, de propósito (evita ~15 s de shutdown do Chrome). 14 arquivos de teste, 16 pontos de chamada com Chrome real (mais 1 teste vivo do próprio helper), cada um deixando uma pasta por execução; a "leva" de 19:21–19:22 de 19/11 é uma rodada da suíte. Os outros lançadores do WA e do PS (Playwright, Puppeteer, `lib/contagem_ribi.py`) passam o próprio perfil e não vazam.
- Linha do tempo: 8.223 pastas / 22 GB em 19/11, a mais antiga de **11/08 (agosto)**, o que é compatível com o Chrome estável que traz o commit chegando ao mini. **Conferir no mini** (abaixo).

## O que apaga e o que nunca apaga
Para cada raiz — `Application Support/Google/Chrome-headless`, `Caches/Google/Chrome-headless` (o gêmeo de cache, pela regra de `GetUserCacheDirectory`; inferido, não medido) e as duas `Chrome for Testing-headless` — lista só os filhos diretos `scoped_dir[A-Za-z0-9_]+` e apaga o que for **diretório de verdade, velho e sem dono**:
- **Velho:** nada dentro, em nenhuma profundidade, foi escrito nas últimas 24 h (a caminhada para no primeiro arquivo recente; mtime no futuro conta como recente).
- **Sem dono:** nenhum processo cita o nome. Todo filho de um Chrome headless vivo leva `--user-data-dir=<a pasta>` (o navegador copia esse switch para todos: `chrome_content_browser_client.cc`, `kCommonSwitchNames`), então `ps -A -w -w -o command=` o acha. **Dois `-w`:** o `ps` BSD corta a linha em 80 colunas sem eles e esconderia o switch.
- Toda leitura tem três saídas e "não consegui saber" cai no estado inerte. `ps` que falha ou volta vazio = não sei se há Chrome vivo = **nada apagado**, INCOMPLETA (saída 1); o `ps` só é perguntado quando algo está velho. Raiz que não lista = `unreadable`; raiz que é symlink = `not-a-dir`, nunca seguida; perfil cuja subárvore não lê inteira, ou com mais de 100 mil entradas = `unjudged`, mantido. Um Chrome vivo mantém SUA pasta e **não** é erro.
- **Nunca toca:** o perfil normal (`Google/Chrome`), `~/.chrome-cdp`, symlink, arquivo, nomes parecidos (`scoped_dir`, `scoped_dirXYZ.bak`, `xscoped_dir…`) e nada fora das raízes.
- Olha a pasta de novo antes do `rmtree` (inode e mtime como estavam) e depois dele: sumiu = apagado; ainda lá = PARCIAL; outro erro = NÃO VERIFICADO (os dois últimos fecham a raiz INCOMPLETA).
- Sentinela de produção (`CHROME_HEADLESS_JANITOR_PROD=1` no plist; sem ele as raízes reais são só dry-run), kill-switch (`CHROME_HEADLESS_JANITOR_ENABLED=0`), `--dry-run` e uma instância por vez (`flock`): como no `claude-security-janitor`.
- Limite que não é inteiro positivo (`…_MAX_AGE_SECS`, `…_ENTRY_CAP`): a rodada para com saída 1 e nada apagado; um limite adivinhado poderia apagar mais do que se quis.

## Correção na origem (WA) — falta fazer
O janitor deixa até ~1 dia de pastas no disco (média medida: 8.223 em ~100 dias, ≈ 82 por dia, ~2,7 MB cada, em picos de até 16 por rodada da suíte). A causa é o chamador, e o conserto é do rig WA (daqui não se cria bead no WA):
- **Patch pronto e testado:** `docs/pending-wa-patches/ga-xjv29mb-dump-dom-own-profile.patch`. Na raiz de um worktree do WA: `git apply <o patch>`. Altera `tests/_chrome_dump_dom.py` e cria `tests/_fake_profile_chrome.py` e `tests/test_chrome_dump_dom_own_profile_ga_xjv29mb.py`.
- O que faz: cada chamada de `dump_dom` recebe `--user-data-dir=<pasta temporária nova>` e `--incognito` (o que o Chrome já aplica sozinho quando faz o próprio perfil), a não ser que o chamador passe o seu; mata o **grupo** de processos do Chrome (não só o principal) e apaga o perfil no `finally`, inclusive em timeout e quando o Chrome nem sobe. A assinatura de `dump_dom` não muda: nenhum dos 21 pontos de chamada precisa mexer.
- Testes: um Chrome falso com as mesmas regras de perfil do real (cria `scoped_dir…` sem `--user-data-dir`, só limpa em saída ordenada) prova que 3 chamadas não deixam nada, que o controle (chamada antiga + SIGKILL) vaza, e cobre timeout, Chrome que não sobe, perfil do chamador, `--incognito` e auxiliar que continua escrevendo; mais um teste **vivo** que repete o critério da bead no Chrome real, com `HOME` isolado (pula sem Chrome, e pula se o controle não vazar nada).
- Provado no nó Linux: 14 verdes e 2 vivos pulados; 7 mutantes do helper mortos, cada um pelo teste que o nomeia; aplicado em cópia pristina com `patch -p1` e rodado de novo. O teste vivo **não** rodou em lugar nenhum (o nó não tem Chrome do macOS): é a primeira coisa que o gate do WA no mini vai exercitar.
- **Aceite no mini, depois do merge no WA:** `ls ~/Library/Application\ Support/Google/Chrome-headless | grep -c scoped_dir` antes e depois de rodar a suíte do WA: o número não cresce.

## Instalar (Mayor, depois do merge)
```bash
cd /Users/athos/gt/.gascity-gastown-hq
ls ~/Library/Application\ Support/Google/Chrome-headless | grep -c scoped_dir     # quantas há agora
python3 scripts/chrome-headless-janitor.py --dry-run                              # 1 rodada de verdade; nada apagado
launchctl bootout gui/$(id -u)/com.gascity.chrome-headless-janitor 2>/dev/null
cp scripts/com.gascity.chrome-headless-janitor.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gascity.chrome-headless-janitor.plist
launchctl kickstart gui/$(id -u)/com.gascity.chrome-headless-janitor              # 1ª rodada real agora
tail -6 .gc/logs/chrome-headless-janitor.out
launchctl print gui/$(id -u)/com.gascity.chrome-headless-janitor | grep -E 'state|runs|last exit'
```
Conferir a hipótese da linha do tempo (não dá para medir do nó): `defaults read "/Applications/Google Chrome.app/Contents/Info" CFBundleShortVersionString` e `ls -ltr ~/Library/Application\ Support/Google/Chrome-headless | head -3` (antes da primeira rodada real, ou na linha `kept_fresh`/`deleted` do log).
Desligar: `CHROME_HEADLESS_JANITOR_ENABLED=0` no plist (ou `launchctl bootout`). O `--dry-run` à mão é sempre seguro. Saída da rodada ≠ 0 enquanto algo estiver INCOMPLETO: `launchctl print … | grep 'last exit'` mostra sem abrir o log.

## Provar
```bash
bash scripts/chrome-headless-janitor.selftest.sh                 # 143 checagens, ~4 s
CHJ_MUTANTS=1 bash scripts/chrome-headless-janitor.selftest.sh   # + 25 mutantes; todos têm de FALHAR a bateria
```
Fixture inteira em diretório descartável (HOME falso com as raízes de `Library/…`; o `ps` é um stub que imita o corte em 80 colunas do `ps` BSD sem dois `-w`, e que pode falhar, voltar vazio ou sumir). O bloco em Python injeta o que um subprocesso não alcança: pasta reescrita entre julgar e apagar, `rmtree` que deixa a pasta, olhada pós-delete que falha, subárvore ilegível, relógio adiantado.

## Medido, lido no código, não testado
- **Medido (nó Linux, 24/11):** a rodada sobre 2.000 perfis / 120 mil arquivos leva 1,0 s só caminhando (`--dry-run`) e 6,8 s apagando. No mini (APFS, load 40–60, `nice`) espera-se de 10 a 50 vezes isso, ainda longe de 1 h; **não medido no mini**.
- **Observado em Chrome real (Chromium 148, anterior ao commit, no nó):** o temporário se chama `org.chromium.Chromium.scoped_dir.XXXXXX` no `$TMPDIR` e **sobrou** depois da morte anormal do navegador (o binário abortou na partida por um limite desta VM; não é uma morte por SIGKILL provocada). O Chromium completo não roda neste nó, então a árvore de processos viva não pôde ser observada.
- **Lido no código-fonte do Chromium (HEAD, 24/11), não observado ao vivo no macOS:** onde o diretório nasce e quem o possui (`headless_mode_init.cc`, linhas 62–94 e 163), que só o destrutor o apaga (`base/files/scoped_temp_dir.cc`) e que todo filho herda `--user-data-dir` (`chrome_content_browser_client.cc:3165`). É daí que vem a premissa de segurança do "sem dono".
- **Inferido:** o gêmeo em `Caches/Google/Chrome-headless` (regra de `GetUserCacheDirectory`); que o Chrome estável da linha do tempo é o que traz o commit de 11/06.
- **Não testado:** rodada real pelo launchd no mini; `ps -A -w -w` no macOS de verdade (o stub imita o comportamento documentado do BSD); o teste vivo do WA no Chrome real; as raízes de `Chrome for Testing-headless` (mesmo código, nomes pela regra do código-fonte).
