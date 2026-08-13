---
name: cnd-trabalhista-cndt
description: Use when you need the CNDT — Certidão Negativa de Débitos Trabalhistas — for a CNPJ or CPF ("tira a CNDT", "certidão trabalhista da empresa X", "preciso da negativa do TST", "documentos para assinatura do contrato"). Emitted free by the TST at cndt-certidao.tst.jus.br, gated by an image captcha. Gives the exact selectors, the captcha call, and why the first attempt usually fails. Applies to ALL Gas City agents/crews.
---

# cnd-trabalhista-cndt — Certidão Negativa de Débitos Trabalhistas (TST)

**Grátis**, sai na hora em PDF, vale **180 dias** e cobre **matriz e filiais**
num documento só. Aceita CNPJ **ou** CPF. Fonte: `https://cndt-certidao.tst.jus.br/`.

⚠️ A certidão pode voltar **positiva**. "Emitida com sucesso" ≠ "negativa" —
sempre leia o corpo do PDF: o texto bom é **"NÃO CONSTA como inadimplente no
Banco Nacional de Devedores Trabalhistas"**.

## Receita (medida ponta a ponta em 13/08/2026)

**1. Abra a página e o formulário**

```
https://cndt-certidao.tst.jus.br/inicio.faces
```
Clique no botão **"Emitir Certidão"** (`<button>`, não é link). O formulário só
existe depois desse clique. Se `gerarCertidaoForm:cpfCnpj` não existir ainda,
espere e clique de novo — a página é JSF e repinta.

**2. Preencha o documento e capture a imagem do captcha**

| Elemento | id |
|---|---|
| campo CPF/CNPJ | `gerarCertidaoForm:cpfCnpj` |
| imagem do captcha | `idImgBase64` (data URI, 300×90) |
| campo da resposta | `idCampoResposta` (name `resposta`) |
| token do desafio | `tokenDesafio` (hidden — **não mexa**) |
| botão emitir | `gerarCertidaoForm:btnEmitirCertidao` |

```js
const cnpj = document.getElementById('gerarCertidaoForm:cpfCnpj');
cnpj.value = '18908990000126';                 // só dígitos, sem máscara
cnpj.dispatchEvent(new Event('input',  {bubbles:true}));
cnpj.dispatchEvent(new Event('change', {bubbles:true}));
return document.getElementById('idImgBase64').src
         .replace(/^data:image\/[a-z]+;base64,\s*/i, '');   // salve num arquivo
```
Aqui `value=` + eventos **basta** (é JSF, não Angular).

**3. Resolva o captcha** — é de **imagem**, e quem resolve é o **anti-captcha**
(~10s, US$ 0,0006):

```bash
python3 ~/gt/.gascity-gastown-hq/skills/captcha-solve/solve.py imagem \
  --file /tmp/captcha_b64.txt
```

**4. Responda e emita** — imediatamente, sem escalas:

```js
const r = document.getElementById('idCampoResposta');
r.value = 'RESPOSTA';
r.dispatchEvent(new Event('input',  {bubbles:true}));
r.dispatchEvent(new Event('change', {bubbles:true}));
document.getElementById('gerarCertidaoForm:btnEmitirCertidao').click();
```

Sucesso → a página escreve **"Certidão EMITIDA com sucesso."** e o browser baixa
`certidao_<documento>.pdf`.

## A armadilha nº 1: "Código de validação inválido"

Acontece bastante na **primeira** tentativa. Duas causas, e a saída é a mesma:

- a leitura do captcha veio errada (captcha de imagem erra mesmo), ou
- o `tokenDesafio` rotacionou enquanto a resposta viajava até você.

**Conserto:** recarregue `inicio.faces` do zero, refaça o passo 1–4 com imagem
**nova**. Não reenvie a mesma resposta, e não reaproveite a imagem antiga —
custa US$ 0,0006 tentar de novo. Foi exatamente isso em 13/08: 1ª tentativa
recusada, 2ª emitiu.

## Conferir o que saiu (nunca pule)

```python
from pypdf import PdfReader
t = PdfReader('certidao_18908990000126.pdf').pages[0].extract_text()
assert 'NÃO CONSTA' in t          # se falhar, a certidão é POSITIVA
```
O PDF traz: Nome, CNPJ, número da certidão, expedição, **validade (180 dias)** e
a frase de negativa. Registre o número e a validade junto do arquivo — é o que
a outra ponta confere.

## Exemplo real

`BTR ENGENHARIA E PARTICIPAÇÕES LTDA` / 18.908.990/0001-26 → certidão
69351133/2026, expedida 13/08/2026, válida até 09/02/2027, **negativa**.

Relacionado: **`captcha-solve`** (motor e regras de injeção),
**`cnd-municipal-pbh`** (a municipal de BH, que usa outro tipo de captcha).
