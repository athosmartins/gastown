---
name: corrigir-imovel-do-anuncio
description: Use when Athos (or anyone) says an anúncio/listing is attached to the wrong imóvel, lote, endereço or índice cadastral — "esse anúncio está no imóvel errado", "conserta o imóvel desse anúncio", "esse anúncio não é nesse endereço", "o anúncio X é na rua Y nº Z, não no que está aí". Covers anúncios de Belo Horizonte no dashboard anuncios.urblink.com.br e no mapa. Applies to ALL Gas City agents.
---

# corrigir-imovel-do-anuncio — mover um anúncio para o lote certo, de forma persistente

O match anúncio→lote é automático e erra: muito anúncio não traz número na rua
(`endereco = "Rua Outono"`), então cai por geocodificação (`MATCH QUALITY = GEO`) e para no
lote vizinho. Corrigir **não** é editar o dado da fonte — é gravar um **override** que o
build noturno reaplica por cima do match automático. É isso que faz a correção sobreviver.

Não invente tabela nova nem escreva direto no MotherDuck: o mecanismo já existe e tem
front-door. Escrever por fora dessincroniza o write-ahead local do daemon e o flush seguinte
pode sobrescrever você.

## A armadilha nº 1 — o que é `--de`

A linha do anúncio é **chaveada pelo índice cadastral do lote em que ele está hoje** (o
ERRADO). Então:

| | |
|---|---|
| `--de` | IC do lote **errado** — é o `imovel_id` da linha do anúncio |
| `--para` | IC do lote **certo** |

Quem inverte isso grava um override que não casa com linha nenhuma e a correção some **sem
erro**. O `localizar` já imprime o `--de` pronto — use ele, não deduza.

## Procedimento

```bash
S=~/.claude/skills/corrigir-imovel-do-anuncio/corrigir_anuncio.py   # ou .gascity-gastown-hq/skills/...

python3 $S localizar 1151704          # trecho da URL (o id serve) -> mostra o lote atual + o --de
python3 $S lote Outono 324            # rua + número -> mostra o IC do lote certo (--para)
python3 $S corrigir --de 101011A0130016 --para 102009035B0015
python3 $S verificar 101011A0130016   # local + MotherDuck + artefato
```

`corrigir` pede confirmação (`--sim` pula), e **recusa** um IC que não existe no cadastro de
BH — é a diferença entre uma correção gravada e uma correção descartada em silêncio.
Vários lotes: `--para IC1,IC2` (assemblage).

Desfazer: `python3 $S desfazer 101011A0130016`.

## O que muda, e quando

O build de **01:30** (launchd `com.whatsapp.anuncios-refresh`) reaplica o override e reescreve
`endereço, bairro, área, proprietário, polígono` e marca `loc_status = corrigido_humano`. Até
lá o dashboard segue mostrando o valor antigo — isso é esperado, **não** é a correção ter
falhado. O `verificar` mostra as três camadas separadas justamente pra você não confundir
"ainda não rebuildou" com "não gravou".

⚠️ **`lat`/`lon` e o link do Maps** (medido em 2026-08-04): o overlay de BH não os movia — o
pino do botão "🧭 Street View + AR" e o link do Google Maps continuavam no lote ERRADO
enquanto o resto da ficha já mostrava o certo. Uma correção que parece ter dado certo e manda
o humano pra casa errada da rua. Fix em `whatsapp_automation`, branch
`fix/anuncio-override-latlon`. Confira se já entrou antes de confiar na coordenada:
`git -C ~/gt/whatsapp_automation log --oneline -S corrected_lat -- daemons/anuncios/build_dataset.py`

O `imovel_id` da linha continua sendo o IC antigo (é a chave da linha). Tudo que é exibido
passa a ser do lote certo. Isso é do desenho do cockpit, não um resto de bug.

## Erros comuns

| Sintoma | Causa |
|---|---|
| "Gravei e o dashboard não mudou" | Normal antes do build das 01:30. Confira com `verificar`. |
| Correção some sem erro | `--de`/`--para` invertidos, ou IC inexistente. |
| `daemon inacessível` | O daemon anuncios (:8204) precisa estar de pé — ele é o front-door. |
| `cache de lotes ausente` | `python3 <anuncios>/bh_lots_cache.py` pra materializar. |

## Fora de escopo

**Contagem** tem cockpit irmão (`/contagem/correct`) com **outra identidade**: lá o
`imovel_id` é o id do ANÚNCIO e `fonte` é o portal, e a correção é por link do Google Maps ou
por clique em lotes. Não aponte este script pra Contagem.

**O mapa** (mapa.urblink) monta a camada de lotes por outro caminho
(`scripts/map_viewer/rebuild_lotes_layer.py`), que **não** lê a tabela de override. Uma
correção feita aqui aparece no dashboard de anúncios; a ficha do lote no mapa pode seguir
mostrando o vínculo antigo. Se isso importar no caso, diga explicitamente em vez de assumir
que os dois estão alinhados.
