# Artefatos do relatório E8 (ga-5c3msy)

Relatório: `../token-por-bead-e8.md`. Esta pasta guarda o que o gera e o publica. Nada aqui altera a cidade: tudo lê e escreve só nesta pasta ou no arquivo de saída que você der.

| arquivo | para quê |
|---|---|
| `e2-readout.py` / `e2-readout.out.txt` | seção 5 do relatório: mistura de effort e amostra de branches do E2. Lê o ledger e o log do gate (`GC_CITY_PATH` muda a cidade). A saída arquivada é a de 01/10 ~03h (anterior à contagem de vereditos sem `dry_run` e de linhas ilegíveis do ledger, que o script agora imprime; rode de novo para ver o número de hoje). |
| `estudo-tabelas.js` / `.css` | o comportamento de tabela que o Athos exige em toda tabela nova (wa-6qnv9): clique no nome da coluna ordena (número começa decrescente, texto crescente), botão direito ou segurar ~550 ms abre o filtro da coluna, cabeçalho travado ao rolar. |
| `estudo-tabelas.test.js` | testa o comportamento na página REAL (jsdom) e prova que o teste morde: roda contra 7 mutantes do script/CSS e exige que cada um reprove. Imprime `<N> ok, 0 failed`. |
| `build-estudo.sh` | `bash build-estudo.sh <saida.html>`: pandoc (gfm) → HTML único com o CSS e o script embutidos → roda o teste. Precisa de `pandoc`, `node` e do módulo `jsdom` (o rig WhatsApp traz um; `JSDOM_PATH` aponta outro). Não publica. |

## Publicar na aba 📚 Estudos

A aba lê `whatsapp_automation/shared/data/estudos/index.json` (fora do git: o diretório pode ter dado pessoal). Passos, na ordem:

1. `bash build-estudo.sh /caminho/tokens-por-bead-aprovada-ga-5c3msy.html`
2. Copie o HTML para `shared/data/estudos/` (nome do arquivo = `arquivo` da entrada). **Antes** da entrada: o dashboard ignora entrada sem arquivo.
3. Acrescente a entrada em `index.json`: `slug` (a-z, 0-9, hífen), `arquivo`, `titulo`, `descricao` (uma linha), `data` (ISO), `tags`. **Sem a chave `publico`**: só `publico: true` (booleano exato) serve o estudo no host sem login, e este relatório é interno. O arquivo é JSON com `indent=1`, `ensure_ascii=False`, sem newline final (round-trip exato em 01/10); troque o arquivo por rename atômico e guarde cópia antes.
4. Confira: `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8097/estudos/tokens-por-bead-aprovada-ga-5c3msy` → 200. O dashboard acrescenta o seu widget de busca no fim da página (≈ 35 KB); o teste passa nela também (`node estudo-tabelas.test.js <html baixado>`).

O prod test `packs/town-deltas/assets/prod-tests/gascity/story-ga-5c3msy.sh` confere o que for conferível disso depois do deploy (entrada única, sem `publico`, arquivo no lugar, daemon responde 200).
