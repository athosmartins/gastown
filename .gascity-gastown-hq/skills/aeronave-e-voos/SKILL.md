---
name: aeronave-e-voos
description: Use when asked to identify a Brazilian aircraft (by tail number / prefixo like PS-ATV, PR-XXX, PT-XXX), find its owner/operator, or pull its recent flight history ("de quem é esse avião", "últimas viagens do PS-XXX", "quem é o dono dessa aeronave", "esse jato é de quem", "para onde esse avião tem voado"). Covers the ANAC RAB open dataset (owner, operator, model, serial, liens) and the FlightAware embedded JSON (last ~14 days of flights) — including the traps that make the obvious approaches fail. Applies to ALL Gas City agents/crews.
---

# aeronave-e-voos — dono e histórico de voo de aeronave brasileira

Duas perguntas diferentes, duas fontes diferentes. Não misture:

| Pergunta | Fonte | Custo |
|---|---|---|
| **De quem é?** modelo, série, dono, operador, gravame | **RAB da ANAC** (dados abertos) | grátis |
| **Para onde voou?** últimos ~14 dias | **FlightAware** (JSON embutido na página) | grátis |

---

## 1. Dono / cadastro — RAB da ANAC

Baixe o dataset inteiro (~23 MB, atualizado diariamente) e filtre local. **Não**
tente a consulta web `cons_rab.asp`: é formulário com sessão, e o dataset resolve
tudo de uma vez.

```bash
curl -s -L -o rab.csv \
  "https://sistemas.anac.gov.br/dadosabertos/Aeronaves/RAB/dados_aeronaves.csv"
head -1 rab.csv   # 1ª linha é "Atualizado em: AAAA-MM-DD" — PULE ela antes do DictReader
```

```python
import csv, re
with open('rab.csv', encoding='latin-1') as f:   # latin-1, NÃO utf-8
    f.readline()                                  # descarta "Atualizado em:"
    rows = [r for r in csv.DictReader(f, delimiter=';')
            if r['MARCAS'].strip().upper() == 'PSATV']
```

**Armadilhas medidas:**

- **Encoding duplo.** O arquivo é `latin-1`, mas os campos `PROPRIETARIOS`/
  `OPERADORES` vêm com UTF-8 gravado dentro do latin-1 — "AÉREAS" aparece como
  `AÃREAS`. Conserte por campo: `s.encode('latin-1').decode('utf-8')`.
- **`MARCAS` vem SEM hífen** (`PSATV`, não `PS-ATV`). Normalize os dois lados.
- **`PROPRIETARIOS`/`OPERADORES` são JSON dentro de string**, com uma lista de
  dicts (`NOME`, `DOCUMENTO`, `PERCENTUAL`, `UF`). Vários donos = várias entradas.
- **CPF vem mascarado** (`046XXXXXX79`); CNPJ vem completo → joga direto no
  `real_estate.rfb.cnpj_consolidado` (ver CLAUDE.md do rig).
- **Dono ≠ quem usa.** Em leasing (`Santander Leasing`, `BV Leasing`) o
  proprietário é o banco; **quem opera é o `OPERADORES`**. Se alguém te falou um
  nome ligado ao avião, quase sempre é o OPERADOR.
- **`DS_GRAVAME`** conta a história: `ARRENDAMENTO MERCANTIL` (leasing),
  `ALIENAÇÃO FIDUCIÁRIA` (financiado), `RESERVADAS AS MARCAS` (prefixo alocado,
  aeronave ainda não operando — importação/revenda), `NENHUM GRAVAME` (quitado).
- **`DT_CANC` preenchido = matrícula CANCELADA.** Sempre reporte isso.

### Achar por modelo quando só se sabe parte do prefixo
Regex no `MARCAS` (`PS-?[A-Z]{2}V`) + filtro de modelo. **Cuidado com falso
positivo por substring**: procurar "200" em `DS_MODELO` pega `ERJ 170-200`. E
lembre que nem todo Beechcraft é King Air — **400/400A é Beechjet (jato)**, não
King Air. King Air real: `C90*`, `E90`, `F90`, `200`, `B200*`, `300`, `B300`,
`260`, `360`.

---

## 2. Histórico de voo — FlightAware

**O que NÃO funciona (todos medidos, não presuma):**

| Caminho | Resultado |
|---|---|
| `WebFetch` no FlightAware | **403** — use `curl` com User-Agent de browser |
| FlightRadar24 / RadarBox | **403** ao curl |
| `adsb.lol`, `airplanes.live`, `adsb.fi` | só **posição AO VIVO**, zero histórico |
| `opensky-network.org/api/metadata/aircraft/...` | **410 Gone** (desativado) |
| `hexdb.io` reg→hex | `n/a` para prefixo brasileiro |

**🚨 O hex ICAO24 brasileiro NÃO é derivável da matrícula.** Não perca tempo:
testei a fórmula `base + prefixo*17576 + índice_das_letras` contra 2.995 registros
brasileiros limpos (hex na faixa E40000–E7FFFF) — **acerta 0,2%**. Não é linear
nem monotônico; é atribuído por ordem de registro. E o `aircraftDatabase.csv` da
OpenSky (94 MB) **não cobre prefixos `PS-` recentes** e ainda contém lixo
(registro brasileiro com hex de faixa americana `A*`). Sem o hex não há
`/flights/aircraft` da OpenSky — por isso o caminho é a FlightAware.

**O que funciona:**

```bash
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/122.0 Safari/537.36"
curl -s --max-time 30 -A "$UA" -L \
  "https://flightaware.com/live/flight/PSATV" -o fa.html   # matrícula SEM hífen
```

O histórico está num JSON embutido, não no HTML renderizado:

```python
import re, json, datetime, pathlib
h = pathlib.Path('fa.html').read_text(errors='ignore')
d = json.loads(re.search(r'var trackpollBootstrap = (\{.*?\});', h, re.S).group(1))
voos = list(d['flights'].values())[0]['activityLog']['flights']
for f in voos:
    dep = f.get('takeoffTimes', {}).get('actual') or f.get('gateDepartureTimes', {}).get('actual')
    arr = f.get('landingTimes', {}).get('actual') or f.get('gateArrivalTimes', {}).get('actual')
    print(datetime.datetime.fromtimestamp(int(dep)).strftime('%d/%m %H:%M'),
          f['origin'].get('friendlyLocation'), '->', f['destination'].get('friendlyLocation'),
          f.get('flightStatus'))
```

**Armadilhas medidas:**

- **`grep` no HTML mente.** A string `"No flights in the last 14 days"` aparece
  no HTML como **template Handlebars** mesmo quando HÁ voos. Nunca conclua "sem
  voos" por grep — só o `activityLog.flights` do JSON decide.
- **Janela ~14 dias.** Buraco no meio costuma ser **falta de cobertura ADS-B no
  interior**, não avião parado. Diga isso ao reportar; não afirme "ficou parado".
- **Registro incompleto**: decolagem e pouso no mesmo minuto = trecho parcial,
  não voo instantâneo. Reporte como incompleto.
- **`flightStatus: "airborne"`** = está no ar AGORA (sem horário de pouso).
- Aeroportos pequenos vêm como código ICAO (`SNKP`, `SDGF`) ou até
  `lat/lon` (`18.65S/52.94W`) quando não há aeródromo cadastrado.

---

## 3. Como reportar (o que dá valor)

O **padrão de rota** costuma valer mais que a lista de voos. Cruze os destinos
com a atividade do dono: base fixa + destinos repetidos = avião operacional
(rodar unidade/fazenda/obra), não lazer. Foi assim que o PS-ATV se explicou —
base Jundiaí (SP), destinos no mapa canavieiro da dona (Presidente Prudente,
Mirante do Paranapanema, Nova Alvorada do Sul, Camapuã, Chapadão do Céu,
Mineiros).

Depois de resolver o CNPJ do dono, o enriquecimento nacional acende de graça:
`real_estate.rfb.cnpj_consolidado` (sócios, capital, situação) e
`real_estate.pf.cpf_consolidado` — ver CLAUDE.md do rig `whatsapp_automation`.

⚠️ **LGPD / bucket público.** Movimento de aeronave e dono PF são dados que
identificam pessoa. **Não** suba isso em
`s3://whatsapp-viewer-549710416969/mockups/` — o link é público e permanente.
Dossiê vai em `shared/data/estudos/` atrás do Cloudflare Access.
