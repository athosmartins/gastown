# REA: versão fixa, patch dos 300 s versionado e update só por bead

## Contents

• Resumo · Por que a versão é fixa · O patch (helper Swift, 60 s → 300 s)
• Comandos do dia a dia (`check` e `apply`) · Códigos de saída · O que fazer quando o `check` não dá 0
• Atualizar o REA (só por bead) · MBP · Issue upstream · Limites conhecidos e o que NÃO foi provado

## Resumo
- Versão fixada: **`rea-agents@6.4.0`** (arquivo `scripts/rea-patches/PIN`).
- O único desvio local do pacote é **uma linha** em `dist/process/DarwinProcessRunTokenReader.js:135`: `timeout: 60_000` → `timeout: 300_000`. Ela está em git como patch (`scripts/rea-patches/6.4.0/0001-swiftc-helper-timeout-300s.patch`), com os hashes esperados em `scripts/rea-patches/6.4.0/MANIFEST.tsv`.
- Reaplicar com **um comando**: `scripts/rea-patch.sh apply`. Conferir sem mexer em nada: `scripts/rea-patch.sh check`.
- **Nunca rode `rea update` nem `rea --update` à mão.** Mudar de versão é uma bead que revisa o changelog (seção "Atualizar o REA").

## Por que a versão é fixa
O REA roda com as permissões do usuário (lê processos, abre navegador, roda Ghidra/Java). `rea update` e `rea --update` executam `npm install --global rea-agents@<versão>`: trocam o pacote inteiro sem ninguém ler o changelog **e** apagam o patch local. A consequência prática é dupla: a versão anda sem revisão e, sob o load deste host, o helper Swift volta a estourar o prazo de 60 s.

## O patch (helper Swift, 60 s → 300 s)
- **O que é o prazo:** na primeira leitura de tokens de processo, o REA compila o helper (`bridge/process/ProcessRunTokenReader*.swift`) com `xcrun swiftc`, e `DarwinProcessRunTokenReader.js` mata a compilação se passar de 60 s. Não existe variável de ambiente nem opção do 6.4.0 para mudar esse prazo (o upstream `main` ainda usa 60 s por padrão; tem um `compileTimeoutMs` injetável, mas não exposto ao usuário).
- **Origem do patch:** feito à mão pelo Mayor em 11/10/2026 (os arquivos do pacote têm data de 11/10 13:36). O mesmo dia teve duas falhas de `analyze-javascript-application` (Bitwarden, asar de 50 MB) com load ~50: "timeout do helper Swift" e `provider_timeout` (registro em `mbp-offload.md`). O comentário na própria linha diz: `// local patch (Mayor 11/10): swiftc >60s sob load alto`.
- **Fidelidade:** o patch em git, aplicado ao arquivo pristine do 6.4.0 (sha256 `c71a355f…1b05`), produz byte a byte o arquivo instalado hoje (sha256 `67a40bb3…299d`). O pristine foi conferido contra o tarball do registro npm.
- **Por que `patch` e não `git apply`:** `/opt/homebrew` é um repositório git, e o `git apply` rodado dentro de um subdiretório de repositório PULA em silêncio os caminhos fora do prefixo e sai com 0. O script usa `patch -p1 -F0` (sem fuzz) numa cópia temporária, confere o sha256 do resultado contra o manifesto e só então troca o arquivo por rename. O estado de cada arquivo vem do hash (pristine / patched / outro), nunca de "o patch saiu com 0".

## Comandos do dia a dia (`check` e `apply`)
```bash
scripts/rea-patch.sh check     # só leitura (também: status, ou sem argumento)
scripts/rea-patch.sh apply     # idempotente: aplica o que falta, verifica por hash antes e depois
scripts/rea-patch.selftest.sh  # testes herméticos (pacote falso em mktemp; a instalação real só é lida)
```
O pacote vem do `rea` que está no PATH (`readlink -f`, dois diretórios acima de `scripts/rea.mjs`), não de um caminho escrito aqui. Para mirar outra instalação (por exemplo a do MBP): `REA_PKG_DIR=<dir do rea-agents> scripts/rea-patch.sh check`.

Saída esperada hoje:
```
rea-patch: applied   dist/process/DarwinProcessRunTokenReader.js
rea-patch: OK rea-agents 6.4.0 (pinned), 1/1 patched file(s) in place — /opt/homebrew/lib/node_modules/rea-agents
```

## Códigos de saída
Três estados, para "não deu para saber" nunca parecer "está tudo bem":

| rc | Significa | Exemplo |
|---|---|---|
| 0 | versão == pin e todo arquivo do manifesto está patched | `check` verde; `apply` sem nada a fazer ou feito |
| 1 | desvio: versão instalada diferente do pin, ou arquivo ainda pristine | alguém rodou `rea update`; `check` antes do `apply`. O `apply` recusa (rc 1) em versão diferente |
| 2 | desconhecido: pacote/manifesto ilegível ou malformado (inclui manifesto vazio ou só com comentários, sem a linha `# none`), ou arquivo que não é nem o pristine nem o patched. O `apply` não modifica nada nesses casos | alguém editou o arquivo de outro jeito; `rea` fora do PATH; `package.json` de outro pacote |

O `apply` classifica **todos** os arquivos antes de instalar qualquer um: se um estiver "estranho", nenhum é tocado. O que a classificação não vê é um patch que deixou de encaixar, ou uma escrita que falha, num arquivo *depois do primeiro*: isso sai como `PARTIAL: …` (rc 2) e o conjunto fica pela metade; rode `check` para ver o que falta. Hoje o manifesto tem uma linha só, então o caso não existe na prática.

## O que fazer quando o `check` não dá 0
- **rc 1, "not patched":** `scripts/rea-patch.sh apply`. É o caso de um `npm install`/`brew upgrade` que reinstalou o mesmo 6.4.0.
- **rc 1, "installed X but pinned 6.4.0":** a versão andou. Não "conserte" com `apply` (ele recusa de propósito). Descubra quem rodou o update, avise o Mayor, e decida na bead de atualização (seção abaixo) se volta a 6.4.0 (`npm install --global rea-agents@6.4.0` seguido de `apply`) ou se adota a nova versão pelo processo.
- **rc 2, "UNKNOWN … is modified":** o arquivo não é o pristine nem o nosso. Não force. Compare com `npm pack rea-agents@6.4.0` em diretório novo e abra bead.
- **rc 2, outros:** o texto diz o que faltou (PIN, manifesto, `package.json`, `rea` no PATH).

## Atualizar o REA (só por bead)
Regra: **versão nova só entra por uma bead dedicada** (rota `gastown.dog` ou crew), nunca por um worker no meio de outra tarefa. Roteiro:
1. **Ler o changelog** entre a versão fixada e a candidata (`https://github.com/morluto/rea/releases`) e anotar na bead: o que mudou nos comandos que usamos (web: `list-browser-targets`, `observe-web-session`, `inspect-web-page`, `analyze-web-bundle`, `export-web-scripts`), mudanças de permissão/rede/coleta, e se o prazo do helper Swift ficou configurável.
2. **Máquina:** a regra de REA pesado vale (10 GB livres, swap até 6 GB, nenhum outro `rea` ativo). Instalação pesada vai para o MBP se a chave estiver ligada.
3. **Instalar a versão exata** (nunca `latest`): `npm install --global rea-agents@X.Y.Z`.
4. **Patch:** pegue o arquivo pristine novo (`npm pack rea-agents@X.Y.Z` em diretório novo e vazio), veja se a linha do prazo mudou de lugar. Se o upstream já resolveu, **descarte o patch** (manifesto sem linhas só vale com uma linha `# none: <motivo>`; sem ela, vazio ou só comentário é rc 2, porque um arquivo truncado seria igual; resultado: `0/0`). Se não, gere o `.patch` novo com `diff -u` (cabeçalho `a/…` e `b/…`, sem timestamp), calcule os dois sha256 e escreva `scripts/rea-patches/X.Y.Z/{MANIFEST.tsv,*.patch}`.
5. **Trocar o pin:** editar `scripts/rea-patches/PIN`. Manter a pasta da versão antiga até a bead fechar (permite voltar).
6. **Provar:** `scripts/rea-patch.sh apply && scripts/rea-patch.sh check` (rc 0), `scripts/rea-patch.selftest.sh` (tudo PASS), e um comando web real do `rea` respondendo (`rea doctor`: só `node` e `host` precisam estar ok; `healthy: false` é esperado aqui, não rode `rea setup`).
7. **MBP:** repetir lá (seção abaixo) ou registrar na bead que ficou para depois.
8. Comentar na bead a linha `REA:` e o que foi conferido.

## MBP
- Instalação separada, em `~/gt-remote/rea` (Node 22; ver `mbp-offload.md`). Caminho do pacote: `~/gt-remote/rea/lib/node_modules/rea-agents`.
- **Situação conferida em 12/10/2026 (só leitura, por ssh):** versão **6.4.0**, mas o arquivo está **pristine** (sha256 `c71a355f…1b05`, `timeout: 60_000` na linha 135): o patch **não** foi aplicado lá. Não foi alterado nesta bead: o MBP é o nó ocioso e a execução de 11/10 deu rc 0 em 75 s sem o patch. Se o MBP passar a rodar compilação do helper sob load, o `rea-patch.sh` precisa rodar **lá** (ele lê arquivos locais): copie `scripts/rea-patch.sh` e `scripts/rea-patches/` para o MBP e rode `REA_PKG_DIR=$HOME/gt-remote/rea/lib/node_modules/rea-agents ./rea-patch.sh apply`.
- `rea update` no MBP segue a mesma regra: só por bead.

## Issue upstream
A ideia é pedir ao projeto (`morluto/rea`) que o prazo de compilação do helper Swift seja configurável (variável de ambiente ou opção, como já existe `REA_GHIDRA_STARTUP_TIMEOUT_MS`), para eliminar o patch local. O texto não deve conter dado interno: sem nomes de host, caminhos do usuário, alvos analisados nem beads. A issue foi aberta em 12/10/2026 com autorização do Athos (comentário do Mayor na bead `ga-pfc2ww`): <https://github.com/morluto/rea/issues/2184> (o rascunho está no comentário do dog na mesma bead). Se ela for atendida, a bead de atualização do roteiro acima troca o patch pela variável de ambiente.

## Limites conhecidos e o que NÃO foi provado
- **O estouro de 60 s não foi reproduzido nesta bead.** Uma compilação do helper medida a quente (`xcrun swiftc` dos `.swift` do 6.4.0, load ~64 neste host) levou **15,3 s**. As falhas de 11/10 (load ~50) estão registradas só em `mbp-offload.md`; o patch é uma folga contra o pior caso observado, não um conserto com causa comprovada. A compilação fria, com cache vazio, não foi medida.
- O patch só cobre o **prazo da compilação** do helper; o `provider_timeout` da outra falha de 11/10 é outro prazo e não é afetado.
- Existe um arquivo solto `…/DarwinProcessRunTokenReader.js.orig-60s` (backup deixado na hora do patch à mão): não é usado por nada e o script o ignora. Pode ser apagado com `safe-clean` quando alguém passar por lá.
- O script não impede que alguém rode `rea update`; ele só **detecta** o resultado (`check` rc 1) e **recusa** consertar versão não revisada. Quem quiser a trava na origem pode chamar `rea-patch.sh check` antes de um comando REA pesado (não existe wrapper `rea-run` hoje; a skill `rea-scraper-first` é o ponto de entrada dos workers) e tratar rc ≠ 0 como "pare e avise".
