---
name: captcha-solve
description: Use when a site blocks automation with a captcha (hCaptcha, reCAPTCHA v2/v3/Enterprise, or an image captcha) and you need to get past it programmatically — typically government portals (Receita Federal, TST/CNDT, prefeituras, juntas comerciais, cartórios). Covers WHICH paid service solves WHICH captcha type (they are not interchangeable — measured), how to inject the token so the page accepts it, and the traps that silently waste rounds. Do NOT declare a site unreachable before running the two-service duel. Applies to ALL Gas City agents/crews.
---

# captcha-solve — passar por captcha em portal público

Temos **duas** contas pagas: `anti-captcha` e `2captcha` (chaves no Bitwarden,
`secret anti-captcha` / `secret 2captcha`). Elas **não são intercambiáveis**.

## Regra nº 1 — o vencedor é POR TIPO, não absoluto

Medido em 13/08/2026, mesmo captcha, os dois serviços em paralelo:

| Tipo | anti-captcha | 2captcha |
|---|---|---|
| **hCaptcha** (Receita Federal) | ❌ `ERROR_NO_SLOT_AVAILABLE` | ✅ 86s · US$ 0,0030 |
| **imagem** (CNDT/TST) | ✅ ~10s · US$ 0,0006 | não testado |
| **reCAPTCHA v3 Enterprise** (PBH) | ✅ ~25s | não testado |

⚠️ Uma nota antiga dizia "anti-captcha venceu, 2captcha falhou (UNSOLVABLE)".
Aquilo era sobre **reCAPTCHA v2** e continua valendo pra v2 — mas generalizar
aquilo pro hCaptcha te faz concluir que o site é intransponível quando não é.
**Na dúvida, rode o duelo:**

```bash
python3 ~/gt/.gascity-gastown-hq/skills/captcha-solve/solve.py hcaptcha \
  --url "https://site/pagina" --key "<sitekey>" --duelo
```

## Regra nº 2 — descubra o TIPO pelo que a PÁGINA faz, nunca por chute

O serviço **recusa a sitekey** se o tipo declarado não bater
(`Passed sitekey is from another Recaptcha type`). Leia o JS da página:

| O que a página chama | Tipo a declarar |
|---|---|
| `grecaptcha.enterprise.execute(key, {action: '...'})` | `recaptcha-v3-enterprise` (+ `--action`) |
| `grecaptcha.execute()` sem action | `recaptcha-invisible` |
| widget com checkbox | `recaptcha` |
| `hcaptcha.execute()` | `hcaptcha` |
| `<img>` com desenho + campo de texto | `imagem` |

## Uso

```bash
S=~/gt/.gascity-gastown-hq/skills/captcha-solve/solve.py
python3 $S imagem --file /tmp/captcha_b64.txt
python3 $S hcaptcha --url "https://…" --key "<sitekey>"
python3 $S recaptcha-v3-enterprise --url "https://…" --key "<k>" --action "<pageAction>"
```

## Como INJETAR o token (a metade que faz falhar em silêncio)

O token não basta existir — a página precisa consumi-lo do jeito dela:

- **Campo escondido nomeado** (padrão JSF/PBH): a página tem uma função que
  grava o token num input e clica no botão. **Reproduza essa função**, não
  invente: `document.getElementById('meuForm:token').value = TOKEN;` seguido de
  `document.getElementById('meuForm:pesquisa').click();`
- **`hcaptcha.execute()` invisível** (padrão Angular/Receita): substitua o
  método pra devolver o token já resolvido, antes de clicar em enviar:
  ```js
  window.hcaptcha.execute    = () => Promise.resolve({response: T, key: T});
  window.hcaptcha.getResponse = () => T;
  ```
- **`textarea[name=g-recaptcha-response]`**: preencha o valor E chame **só** o
  `.callback` do widget — nunca o `expired-callback`.

## Armadilhas medidas (cada uma custou pelo menos uma rodada)

1. **O token expira em ~120s.** Resolva por ÚLTIMO: prepare a página inteira,
   e só então peça o token, injete e envie. Token que viaja por 2 minutos chega morto.
2. **Página com estado pós-envio recusa token bom.** Depois de um envio falho o
   ViewState (JSF) fica velho e devolve "Captcha inválido" mesmo com token
   fresco. **Recarregue a página** antes de tentar de novo.
3. **NÃO sirva o token de um `http://127.0.0.1` local pra economizar contexto.**
   A CSP desses portais bloqueia `connect-src` e o `fetch` da página fica
   **PENDURADO** — não falha rápido, pendura. Testado: até `/ping` trivial
   passou de 120s. Passe o token direto no `evaluate`.
4. **Erro genérico muda de código quando você passa.** Na Receita, captcha
   recusado = "erro 023"; com token válido virou "erro 106". Se o código mudou,
   **você passou do captcha** — o problema agora é outro. Não fique atacando o
   captcha.
5. **`fill()` não satisfaz Angular.** Campo preenchido por `value=` ou `fill()`
   dá "CNPJ inválido" porque o ControlValueAccessor não viu evento de tecla. Use
   digitação real (`pressSequentially` / `browser_type` com `slowly`).
6. **`secret` falha de forma intermitente.** Trate como transitório e repita —
   `solve.py` já faz 4 tentativas. Nunca leia "não consegui a chave" como "não
   tem chave".

## Saldo

`secret anti-captcha` / `secret 2captcha` → as duas contas são pré-pagas. Para
recarregar o anti-captcha existe a skill **`anti-captcha-topup`** (fluxo de
pagamento no browser autenticado). Custo típico por captcha: US$ 0,0006 a 0,003.

## Quem usa isto

Skills **`cnd-trabalhista-cndt`** e **`cnd-municipal-pbh`** dependem deste
motor. Se você adicionar outra certidão, reuse `solve.py` em vez de reescrever.
