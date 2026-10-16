# Re-medição do zap_vivareal e do wimoveis no nó Hetzner (ga-gxlhhm)

## Contents

• Veredito · Probe por família de IP (curl) · Mesmo cliente dos raspadores (requests) · Rodada real pequena · O que corrigir no runbook de 16/10 (ga-mqs133) · Como repetir · Limites da medição

## Veredito
**`zap_vivareal` e `wimoveis` continuam bloqueados no nó, por IPv4 e por IPv6.** Medido em 16/10/2026, 14:55–15:09 UTC (11:55–12:09 em BH), pelo menos 4 h depois da 1ª medição do ga-mqs133 (o comentário que a relata é das 10:53 UTC). Nada foi liberado: a lista de elegíveis do ga-mqs133 (`scripts/hetzner-scrape-eligible.txt`) não muda, as linhas `!zap_vivareal` e `!wimoveis` ficam. Nó: `hetzner-teste`, IPv4 `2.31.41.222`, IPv6 `2a01:4f8:c012:fa40::1`.

Por que a pergunta "IPv6 ou IPv4?" valia a medição: o nó **sai por IPv6 por padrão** para todo site que tem registro AAAA (`curl https://www.cloudflare.com/cdn-cgi/trace` devolve `ip=2a01:4f8:c012:fa40::1`; `zapimoveis`, `glue-api.zapimoveis` e `wimoveis` têm AAAA). O `probe` e o `run` do `hetzner-scrape-round.sh` não escolhem família, então as medições de 16/10 de manhã eram, na prática, medições de IPv6. Agora há `-4` e `-6` explícitos.

## Probe por família de IP (curl)
A glue-api da ZAP e as páginas do wimoveis levam os headers e parâmetros do raspador; as demais linhas (home da ZAP, VivaReal e controles) levam só o UA de navegador do `probe`. 3 tentativas por célula; as 3 deram o mesmo status e a mesma marca de bloqueio em todas. "Desafio" = 403 com `cf-mitigated: challenge` e página "Just a moment"; "AR" = 403 com a página "Attention Required" do Cloudflare.

| Endereço | nó `-4` | nó `-6` | nó padrão | mini padrão |
|---|---|---|---|---|
| `glue-api.zapimoveis.com.br/v2/listings` | 403 AR | 403 AR | 403 AR (IPv6) | 403 AR |
| `www.zapimoveis.com.br/` | 403 AR | 403 AR | 403 AR | 403 AR |
| `www.vivareal.com.br/` | 403 AR | sem conexão (sem AAAA) | 403 AR (IPv4) | 403 AR |
| `www.wimoveis.com.br/` | 403 desafio | 403 desafio | 403 desafio | 403 desafio |
| `www.wimoveis.com.br/venda/casas/mg/belo-horizonte/savassi/` | 403 desafio | 403 desafio | 403 desafio | 403 desafio |
| controle `chavesnamao` (BH, venda) | 403 desafio | 403 desafio | 403 desafio | 200 |
| controle `netimoveis.com/pesquisa` | 403 desafio | 403 desafio | 403 desafio | 404 |
| controle `cloudflare.com/cdn-cgi/trace` | 200 | 200 | 200 | 200 |

O curl **não separa** nó de mini para ZAP e wimoveis (o mini também leva 403): é por isso que o runbook de 16/10 deixou o wimoveis como "inconclusivo". A tabela seguinte resolve isso.

## Mesmo cliente dos raspadores (requests)
`requests.Session()` com os `HEADERS` e os parâmetros de cada raspador, só GET de leitura (nada gravado: sem seen, sem dado, sem cookie). A família é forçada trocando `urllib3.util.connection.allowed_gai_family`. 3 tentativas por célula; "passa" = HTTP 200 com corpo de verdade (JSON da API; HTML de 410 KB a 1,1 MB).

| Alvo | mini (IPv4) | nó padrão (IPv6) | nó IPv4 | nó IPv6 |
|---|---|---|---|---|
| glue-api da ZAP | 3/3 passam | 0/3 (403 AR) | 0/3 (403 AR) | 0/3 (403 AR) |
| wimoveis, lista de BH | 2/3 passam (1 desafio) | 0/3 (desafio) | 0/3 (desafio) | 0/3 (desafio) |
| wimoveis, home | 2/3 passam (1 desafio) | 0/3 (desafio) | 0/3 (desafio) | 0/3 (desafio) |

Leitura: do **mini** o Cloudflare deixa passar (o wimoveis oscila, 4 de 6; a ZAP passou 3 de 3, e a resposta é JSON válido — vem com 0 anúncios porque o probe pede o bairro como `savassi`, o raspador pede "Savassi" com nome completo; para esta comparação só importa passar do Cloudflare); do **nó**, 0 de 27 chamadas (9 da ZAP, 18 do wimoveis), nas duas famílias e no padrão. Isso tira o wimoveis de "inconclusivo": é bloqueado.

## Rodada real pequena
Código implantado (`~/.property-scrapers/runtime/main`), pelo próprio `hetzner-scrape-round.sh run`, família padrão do nó (= IPv6), `--limit 3 --timeout 240`, staging fora da produção, lista de elegíveis temporária só para esta medição (a commitada não foi alterada).

| Raspador | Duração | Arquivos | O que o log do raspador mostra |
|---|---|---|---|
| `zap_vivareal` | 264 s (estourou os 240 s; rc cru 124 → 95) | 0 | 36 × `GAVE UP … 403 Client Error: Forbidden` em `glue-api.zapimoveis.com.br`, nenhum erro de outro tipo |
| `wimoveis` | 261 s (estourou os 240 s; rc cru 124 → 95) | 0 | 15 × `BLOCKED … HTTP 403 (gave up after retries)` já na página 1, nenhum erro de outro tipo |

A rodada com IPv4 forçado não foi feita com o raspador inteiro: o que decide o resultado é a 1ª chamada dele, que usa o mesmo cliente, os mesmos headers e o mesmo endereço da tabela acima (muda só o bairro) e deu 0/3 em IPv4. A pasta da rodada no nó foi apagada pelo script; não ficou processo.

## O que corrigir no runbook de 16/10 (ga-mqs133)
`docs/runbooks/hetzner-scrape-round.md` e `scripts/hetzner-scrape-eligible.txt` estão na branch `feat/ga-mqs133`, em gate (tentativa 1/3 reprovada), e não em `main`: ainda não dá para editar lá sem colidir com o conserto. Quando entrarem:
1. `wimoveis`: trocar "inconclusivo; fica local" por "bloqueado, medido com `requests` (0 de 18 do nó contra 4 de 6 do mini) e em rodada real". O `!wimoveis` continua.
2. "O IPv6 do nó e o IPv4 foram barrados nos mesmos sites" passa a estar medido (`-4` e `-6` explícitos, 4 sites do Cloudflare); até aqui `probe` e `run` não escolhiam família e o padrão do nó é IPv6.
3. Dizer que curl não decide ZAP nem wimoveis (o mini também leva 403): quem decide é a rodada real ou o `requests` com os headers do raspador.
4. Lacuna do `probe`: a tabela não registra a família usada. Um `--family 4|6` (curl `-4`/`-6`) faria a medição de IPv4 sair de graça na próxima vez.

## Como repetir
```bash
# probe por família (no nó): troque -4 por -6 ou tire a flag para o padrão
ssh hetzner-teste 'curl -4 -s -L -m 25 -D - -o /dev/null -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36" https://www.wimoveis.com.br/venda/casas/mg/belo-horizonte/savassi/'
# rodada real sem tocar na lista commitada (o script vem do ga-mqs133; só existe em main depois que ele entrar)
printf 'zap_vivareal\nwimoveis\n' > "$TMPDIR/elegiveis-temp.txt"
HETZNER_SCRAPE_ELIGIBLE="$TMPDIR/elegiveis-temp.txt" scripts/hetzner-scrape-round.sh run zap_vivareal --limit 3 --timeout 240 --stage "$TMPDIR/stage"
```
Para forçar a família num `requests`: `import socket, urllib3.util.connection as c; c.allowed_gai_family = lambda: socket.AF_INET` (ou `AF_INET6`) antes do 1º GET. Evite `--timeout` com zero à esquerda (`08`, `0600`): o `$(( ))` do script lê como octal (achado do revisor do gate no ga-mqs133; não reproduzido aqui).

## Limites da medição
- **Mesmo dia**, pelo menos 4 h depois da 1ª medição (manhã de BH → meio-dia de BH). Não há amostra de **outro dia**: é a única parte do pedido que ficou de fora.
- 3 tentativas por célula, uma janela de ~14 minutos no total. Reputação de IP de datacenter no Cloudflare pode mudar sem aviso.
- Só IP do próprio nó (um IPv4 e um /64 de IPv6) e só cliente HTTP simples. Não foi testado navegador real nem outro IP/ASN; "trocar de família" não resolve, mas o que resolveria (outro IP, outro método) não foi medido.
- O 403 vem do Cloudflare, não do site: a regra pode ser por ASN do datacenter, e então nenhum IP do mesmo provedor passaria.
