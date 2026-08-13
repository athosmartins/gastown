---
name: cnd-municipal-pbh
description: Use when you need a municipal tax clearance certificate from Belo Horizonte — "CND municipal", "certidão de quitação plena", "certidão negativa da PBH", "IPTU/ISS/ITBI em dia" — for a CNPJ or CPF, typically for a property purchase or contract signing. Emitted free at cnd.pbh.gov.br/CNDOnline, gated by an invisible reCAPTCHA Enterprise v3. Gives the exact flow, the token injection the page expects, and the 30-day validity trap. Applies to ALL Gas City agents/crews.
---

# cnd-municipal-pbh — Certidão Negativa de Débito da Prefeitura de BH

**Grátis**, sai na hora. Vale só para imóveis/contribuintes de **Belo Horizonte**
(sede/imóvel em outra cidade = outro órgão).
Fonte: `https://cnd.pbh.gov.br/CNDOnline/`.

⚠️ **A validade é de 30 DIAS** — muito mais curta que as outras (CNDT tem 180).
Se a assinatura do contrato escorregar um mês, esta precisa ser refeita.
**Tire esta por último**, quando a data de assinatura já estiver de pé.

⚠️ O que sai é o **"documento auxiliar"** — a representação gráfica. Formalmente
a certidão se obtém autenticando o **Código de Controle** no portal da PBH
(Decreto 15.927/2015). Na prática o documento auxiliar + código é o que circula;
guarde o código junto do arquivo.

## Modalidades (são radios diferentes — escolha a certa)

| Radio | Modalidade | Quando |
|---|---|---|
| `meuForm:customRadio:0` | **Quitação Plena Pessoa Jurídica** | empresa (o caso comum) |
| `meuForm:customRadio:1` | Quitação Plena Pessoa Física | pessoa |
| `meuForm:customRadio:2` | ISS | só serviço |
| `meuForm:customRadio:3` | IPTU e Taxas | só o imóvel |
| `meuForm:customRadio:4` | ITBI | transmissão |

## Receita (medida ponta a ponta em 13/08/2026)

**1. Escolha a modalidade — o campo do documento só aparece depois**

```js
document.getElementById('meuForm:customRadio:0').click();   // Quitação Plena PJ
// aguarde ~3s: o AJAX cria o campo do CNPJ
document.getElementById('meuForm:j_idt111');                // <- campo CNPJ (mascarado)
```
⚠️ O id do campo (`j_idt111`) é **gerado pelo JSF e pode mudar** quando a PBH
mexer na página. Se não existir, localize pela máscara `__.___.___/____-__` em
vez de confiar no id.

**2. Preencha o documento COM máscara**

```js
const c = document.getElementById('meuForm:j_idt111');
c.value = '18.908.990/0001-26';                 // com pontuação
c.dispatchEvent(new Event('input',  {bubbles:true}));
c.dispatchEvent(new Event('change', {bubbles:true}));
```

**3. Resolva o captcha — é reCAPTCHA Enterprise v3, COM action**

A página faz exatamente isto (confira no `<script>` dela):

```js
grecaptcha.enterprise.execute(publicKey, {action: 'cndonline_certidao_negativa_debitos'})
  .then(token => { document.getElementById('meuForm:token').value = token;
                   document.getElementById('meuForm:pesquisa').click(); });
```

Logo o tipo é `recaptcha-v3-enterprise` e o `action` é obrigatório. A sitekey
está no hidden `meuForm:publicKey` (em 13/08 era
`6LdBvoonAAAAAG2RduAxWppMsMH2xp4FLowz6x2t` — **leia do campo, não copie daqui**):

```bash
python3 ~/gt/.gascity-gastown-hq/skills/captcha-solve/solve.py \
  recaptcha-v3-enterprise --url "https://cnd.pbh.gov.br/CNDOnline/" \
  --key "<meuForm:publicKey>" --action "cndonline_certidao_negativa_debitos"
```
Declarar `recaptcha-invisible` aqui devolve
`ERROR_INVALID_KEY_TYPE: Passed sitekey is from another Recaptcha type`.

**4. Injete e envie — reproduzindo a função da página, não inventando**

```js
document.getElementById('meuForm:token').value = TOKEN;
document.getElementById('meuForm:pesquisa').click();
```
O resultado abre em **outra aba**: `.../CNDOnline/guiaCND.xhtml`.

**5. Leia e guarde**

A aba de resultado traz Nome, CNPJ, **Documento/Certidão nº**, **Código de
Controle**, emissão e validade. A frase boa é
**"encontra-se regular com a Fazenda Publica Municipal"**.

Não há PDF pra baixar — capture a página inteira e converta:
```python
from PIL import Image
Image.open('pbh.png').convert('RGB').save('PBH.pdf', 'PDF', resolution=150.0)
```

## Armadilha: "Captcha inválido" com token bom

Se você já enviou uma vez nessa aba, o **ViewState do JSF está velho** e a PBH
recusa mesmo um token fresco. **Recarregue `CNDOnline/` do zero** antes do
próximo documento — não reutilize a página pós-envio. Foi assim que a 2ª empresa
falhou na primeira tentativa em 13/08 e passou depois do reload.

## Exemplos reais (13/08/2026, ambos regulares)

| Empresa | CNPJ | Certidão | Controle | Validade |
|---|---|---|---|---|
| BTR Engenharia | 18.908.990/0001-26 | 38.622.950 | ABGFMMJPLK | 12/09/2026 |
| BBM Construções | 20.701.463/0001-98 | 38.623.116 | AHHFEJMNPJ | 12/09/2026 |

Relacionado: **`captcha-solve`** (motor e regras de injeção),
**`cnd-trabalhista-cndt`** (a trabalhista, captcha de imagem).
