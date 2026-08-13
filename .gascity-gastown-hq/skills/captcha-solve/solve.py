#!/usr/bin/env python3
"""Resolve captcha via anti-captcha OU 2captcha, escolhendo pelo TIPO.

Os dois serviços expõem a mesma API JSON (createTask/getTaskResult), então o
código é um só e muda apenas a base URL e a chave no Bitwarden.

MEDIDO em 13/08/2026 (não é opinião — foi o mesmo captcha nos dois serviços):
  hCaptcha (Receita Federal)  anti-captcha: ERROR_NO_SLOT_AVAILABLE | 2captcha: OK 86s US$0,0030
  imagem   (CNDT/TST)         anti-captcha: OK ~10s US$0,0006
  reCAPTCHA v3 ent. (PBH)     anti-captcha: OK ~25s

=> NÃO existe "o melhor serviço". Existe o serviço certo PARA AQUELE TIPO.
   Antes de declarar um site intransponível, TESTE OS DOIS (--duelo).

Uso:
  solve.py imagem   --file <arquivo-com-base64>
  solve.py hcaptcha --url <pageurl> --key <sitekey> [--service 2captcha]
  solve.py recaptcha-v3-enterprise --url <U> --key <K> --action <pageAction>
  solve.py hcaptcha --url <U> --key <K> --duelo      # roda nos 2 e compara
"""
import argparse
import re
import subprocess
import sys
import threading
import time

import requests

SERVICOS = {
    # nome            base url                       item no Bitwarden
    "anti-captcha": ("https://api.anti-captcha.com", "anti-captcha"),
    "2captcha":     ("https://api.2captcha.com",     "2captcha"),
}

# Qual serviço tentar PRIMEIRO para cada tipo, pela medição acima.
PADRAO_POR_TIPO = {
    "hcaptcha": "2captcha",
    "imagem": "anti-captcha",
    "recaptcha": "anti-captcha",
    "recaptcha-invisible": "anti-captcha",
    "recaptcha-v3": "anti-captcha",
    "recaptcha-v3-enterprise": "anti-captcha",
}


def chave(item, tentativas=4):
    """O `secret` (Bitwarden) falha de forma INTERMITENTE — trate como transitório.

    Três estados distintos: veio / não veio / o comando nem rodou. Nunca
    colapse "não consegui ler a chave" em "não tem chave".
    """
    ultimo = ""
    for i in range(tentativas):
        p = subprocess.run(["secret", item], capture_output=True, text=True)
        m = re.search(r"[0-9a-zA-Z]{32}", p.stdout or "")
        if m:
            return m.group(0)
        ultimo = (p.stderr or p.stdout or "").strip()[:120]
        time.sleep(2 * (i + 1))
    raise SystemExit(f"ERRO: chave `{item}` não veio em {tentativas} tentativas. "
                     f"Última saída do `secret`: {ultimo!r}")


def _montar_task(tipo, url, sitekey, action, b64):
    if tipo == "imagem":
        return {"type": "ImageToTextTask", "body": b64, "phrase": False,
                "case": False, "numeric": 0}
    if tipo.startswith("hcaptcha"):
        return {"type": "HCaptchaTaskProxyless", "websiteURL": url, "websiteKey": sitekey}
    if "v3" in tipo:
        t = {"type": "RecaptchaV3TaskProxyless", "websiteURL": url,
             "websiteKey": sitekey, "minScore": 0.7}
        if action:
            t["pageAction"] = action
        if "enterprise" in tipo:
            t["isEnterprise"] = True
        return t
    t = {"type": "RecaptchaV2TaskProxyless", "websiteURL": url, "websiteKey": sitekey}
    if "invisible" in tipo:
        t["isInvisible"] = True
    return t


def resolver(tipo, servico=None, url=None, sitekey=None, action=None,
             b64=None, timeout=200):
    servico = servico or PADRAO_POR_TIPO.get(tipo, "anti-captcha")
    api, item = SERVICOS[servico]
    k = chave(item)
    task = _montar_task(tipo, url, sitekey, action, b64)

    r = requests.post(f"{api}/createTask",
                      json={"clientKey": k, "task": task}, timeout=45).json()
    if r.get("errorId"):
        # Mensagem tipicamente util: "Passed sitekey is from another Recaptcha
        # type" = voce declarou o tipo errado. Descubra o tipo pelo que a PAGINA
        # faz (grecaptcha.enterprise.execute -> v3 enterprise; execute() sem
        # action -> v2 invisible; checkbox -> v2), nunca por chute.
        raise SystemExit(f"ERRO createTask [{servico}]: "
                         f"{r.get('errorCode')} {r.get('errorDescription')}")
    tid = r["taskId"]

    t0 = time.time()
    while time.time() - t0 < timeout:
        time.sleep(5)
        s = requests.post(f"{api}/getTaskResult",
                          json={"clientKey": k, "taskId": tid}, timeout=45).json()
        if s.get("errorId"):
            raise SystemExit(f"ERRO getTaskResult [{servico}]: "
                             f"{s.get('errorCode')} {s.get('errorDescription')}")
        if s.get("status") == "ready":
            sol = s["solution"]
            return (sol.get("gRecaptchaResponse") or sol.get("token")
                    or sol.get("text"))
    raise SystemExit(f"ERRO: timeout de {timeout}s esperando o {servico}")


def duelo(tipo, url, sitekey, action, b64):
    """Roda os DOIS serviços no mesmo captcha e imprime o comparativo."""
    out = {}

    def um(nome):
        t0 = time.time()
        try:
            tok = resolver(tipo, servico=nome, url=url, sitekey=sitekey,
                           action=action, b64=b64)
            out[nome] = {"ok": True, "seg": round(time.time() - t0), "len": len(tok or "")}
        except SystemExit as e:
            out[nome] = {"ok": False, "erro": str(e)[:160], "seg": round(time.time() - t0)}

    ths = [threading.Thread(target=um, args=(n,)) for n in SERVICOS]
    for t in ths:
        t.start()
    for t in ths:
        t.join()
    for n, v in out.items():
        print(f"{n}: {v}")
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tipo", choices=sorted(PADRAO_POR_TIPO))
    ap.add_argument("--service", choices=list(SERVICOS))
    ap.add_argument("--url")
    ap.add_argument("--key")
    ap.add_argument("--action")
    ap.add_argument("--file", help="arquivo com o base64 da imagem (tipo=imagem)")
    ap.add_argument("--duelo", action="store_true", help="testa os 2 serviços e compara")
    a = ap.parse_args()

    b64 = None
    if a.tipo == "imagem":
        if not a.file:
            ap.error("tipo=imagem exige --file")
        b64 = open(a.file).read().strip().strip('"')
        if "," in b64[:80]:
            b64 = b64.split(",", 1)[1]
    elif not (a.url and a.key):
        ap.error(f"tipo={a.tipo} exige --url e --key")

    if a.duelo:
        duelo(a.tipo, a.url, a.key, a.action, b64)
        return
    print(resolver(a.tipo, servico=a.service, url=a.url, sitekey=a.key,
                   action=a.action, b64=b64))


if __name__ == "__main__":
    sys.exit(main())
