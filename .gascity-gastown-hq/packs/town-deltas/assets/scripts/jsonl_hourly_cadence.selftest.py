#!/usr/bin/env python3
"""jsonl_hourly_cadence.selftest.py (ga-c0939v.7) — testes do jsonl_hourly_cadence.py.

Contents
  Escopo · Como rodar · O que cada bloco prova

ESCOPO: hermético. Só tmpdir e subprocess do próprio script; sem rede, sem aws, sem o log real. As linhas das fixtures têm o FORMATO do log de produção
  (copiadas de .gc/logs/jsonl-hourly-offsite.log em 23/10): um regex que só casa com o que o teste inventou não prova nada.
COMO RODAR: python3 -I jsonl_hourly_cadence.selftest.py   (rc 0 = tudo passou; a última linha é `=== RESULT: PASS=n FAIL=n ===`)
O QUE PROVA:
  A. o que é publicação: `OK`, `ponto batido` e `FALHOU ... snapshot novo subiu` contam; `FALHOU` sem "subiu" e `UNKNOWN` não; OK + FALHOU da mesma chave é UMA;
  B. causa do gap: disco, fonte parada, run morto, falha do upload, sem veredito; várias no mesmo gap (a mais grave é a primária); nenhuma => "disparo atrasado";
  C. números: quantis do gap, fatia acima do limite e o atraso do dado até o S3 por snapshot novo (idade do HEAD + duração do run), valores conferidos à mão;
  D. a linha de comando: --since, --json, --list, e os códigos de saída (log ausente, menos de 2 publicações e uso errado não viram "tudo bem").
"""
import datetime
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "jsonl_hourly_cadence.py")
sys.path.insert(0, HERE)
import jsonl_hourly_cadence as jc  # noqa: E402

PASS = FAIL = 0


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print("  PASS: " + name)
    else:
        FAIL += 1
        print("  FAIL: " + name + (" -- " + str(detail) if detail else ""))


BASE = jc.ep("2026-10-20T00:00:00Z")
IGN = "(ignorados: bench_hq_copy,fixdepkeys_0d16f874c5d7)"


def L(t, msg):
    return "[%s] %s" % (jc.iso(BASE + t), msg)


def snap(t, stem, age):   # linha de início de run, formato do log real
    return L(t, "snapshot %s (HEAD %s, dado de há %ds)" % (stem, stem.split("-")[1], age))


def ok(t, stem):          # snapshot novo verificado
    return L(t, "OK %s: 174411070 bytes, 45106 issues em 9 bancos %s, régua: compared, 227s" % (stem, IGN))


def same(t):              # HEAD igual: ponto batido
    return L(t, "HEAD 3260b024dc48 já está no S3 (20261023T063525Z-3260b024dc48): ponto batido")


def stem(n):
    return "20261020T%06dZ-%012x" % (n, 0xabc000 + n)


def run_cli(lines, *args, raw=None):
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "x.log")
        if raw is None:
            open(p, "w", encoding="utf-8").write("\n".join(lines) + "\n")
        r = subprocess.run([sys.executable, "-I", TOOL, "--log", p] + list(args), capture_output=True, text=True)
        return r.returncode, r.stdout, r.stderr


def measure(lines, limit=3600):
    pubs, misses = jc.parse(lines)
    return pubs, misses, jc.analyse(pubs, misses, limit)


print("=== jsonl_hourly_cadence.selftest.py ===")

print("-- A. o que é publicação")
# A1: cadência regular de 70 min, 5 publicações com dado novo
lines = []
for i in range(5):
    t = i * 4200
    lines += [snap(t - 200, stem(i), 100), ok(t, stem(i)), L(t + 20, "retenção: 60 chaves, 2 apagadas")]
pubs, misses, res = measure(lines)
check("A1 cadência regular: 5 publicações, 4 gaps de 4200 s", len(pubs) == 5 and res["gaps"] == 4 and res["gap_s"]["p50"] == 4200, (len(pubs), res.get("gap_s")))
check("A1 todos os gaps passam de 1 h e a causa é 'disparo atrasado' (nenhum run falhou no meio)", res["gaps_over_limit"] == 4 and res["over_by_primary_cause"] == {"disparo atrasado": 4}, res["over_by_primary_cause"])

# A2: ponto batido conta como publicação (o latest.json foi reescrito), mas não traz dado novo
pubs, _, _ = measure([snap(-100, stem(0), 100), ok(0, stem(0)), same(3000)])
check("A2 'ponto batido' é publicação (kind=mesmo) e NÃO traz atraso de dado (não há dado novo)", [p["kind"] for p in pubs] == ["novo", "mesmo"] and pubs[1]["lag"] is None and pubs[0]["lag"] == 100 + 100, pubs)

# A3: OK + FALHOU(snapshot novo subiu, MESMA chave) é UM run: sem isso há gap de 0 s (medido no log real: min 0h00m antes do conserto)
key = "jsonl-hourly/snap/%s.tar.gz" % stem(1)
fail_up = L(4205, "FALHOU: fonte parada: o exporter escreve mas não comita: a árvore do archive está adiante do HEAD, que tem 41496s (> 21600s) (snapshot novo subiu: key=%s)" % key)
pubs, _, res = measure([snap(3900, stem(1), 50), ok(4000, stem(1)), fail_up, snap(7800, stem(2), 50), ok(8000, stem(2))])
check("A3 OK e FALHOU('snapshot novo subiu') da mesma chave: 2 publicações, não 3", len(pubs) == 2, [p["kind"] for p in pubs])
check("A3 e nenhum gap de 0 s", res["gap_s"]["min"] > 1000, res["gap_s"])

# A4: FALHOU com 'snapshot novo subiu' mas SEM OK antes (chave nova) conta uma vez
pubs, _, _ = measure([snap(3900, stem(1), 50), fail_up, ok(9000, stem(2))])
check("A4 FALHOU('snapshot novo subiu') sem OK da mesma chave é uma publicação", [p["kind"] for p in pubs] == ["novo+falha", "novo"], [p["kind"] for p in pubs])

# A5: FALHOU sem 'subiu', FALHOU 'subiu mas latest.json NÃO andou' (formato antigo) e UNKNOWN não publicam
f_plain = L(500, "FALHOU: fonte parada: o exporter escreve mas não comita: a árvore do archive está adiante do HEAD, que tem 25419s (> 21600s)")
f_old = L(600, "FALHOU: snapshot 20261016T065733Z-73c4c2cf555f broken (bench_hq_copy/config.jsonl: não começa com {\"rows\":[ nem é {}); subiu mas latest.json NÃO andou")
unk = L(700, "UNKNOWN: pouco disco em /Users/athos/gt/.gascity-gastown-hq/.gc/runtime/packs/town-deltas (797 MB < 1024 MB)")
pubs, misses, _ = measure([ok(0, stem(0)), f_plain, f_old, unk, ok(9000, stem(1))])
check("A5 FALHOU sem 'snapshot novo subiu', o formato antigo 'subiu mas latest.json NÃO andou' e UNKNOWN NÃO são publicação", len(pubs) == 2 and len(misses) == 3, (len(pubs), misses))

print("-- B. causa do gap")
def causes_between(*mid):
    _, _, r = measure([ok(0, stem(0))] + list(mid) + [ok(9000, stem(1))])
    return r["over"][0]["causes"]
check("B1 UNKNOWN 'pouco disco' (formato antigo do log real) => disco", causes_between(unk) == ["disco"], causes_between(unk))
new_unk = L(700, "UNKNOWN: pouco disco em /x/town-deltas (600 MB livres < 656 MB: 2x o último pacote + 256 MB de folga, mínimo 512 MB)")
check("B2 UNKNOWN 'pouco disco' (formato novo, com o piso proporcional) => disco", causes_between(new_unk) == ["disco"], causes_between(new_unk))
check("B3 FALHOU 'fonte parada' => fonte parada", causes_between(f_plain) == ["fonte parada"], causes_between(f_plain))
check("B4 FALHOU de outro tipo => falha do upload", causes_between(f_old) == ["falha do upload"], causes_between(f_old))
check("B5 UNKNOWN de outro tipo => sem veredito", causes_between(L(700, "UNKNOWN: aws ausente (/opt/homebrew/bin/aws)")) == ["sem veredito"])
check("B6 'run anterior não terminou' => run morto", causes_between(L(700, "run anterior não terminou (timeout do order, kill ou reboot): conta como run sem snapshot")) == ["run morto"])
check("B7 várias causas no mesmo gap: todas, da mais grave para a menos (disco antes de fonte parada)", causes_between(f_plain, unk) == ["disco", "fonte parada"], causes_between(f_plain, unk))
_, _, r = measure([ok(0, stem(0)), f_plain, unk, ok(9000, stem(1)), ok(18000, stem(2))])
check("B8 a causa PRIMÁRIA de cada gap é a mais grave dele (o outro gap, sem rastro, é 'disparo atrasado')", r["over_by_primary_cause"] == {"disco": 1, "disparo atrasado": 1}, r["over_by_primary_cause"])
check("B9 gap dentro do limite não entra em 'over'", measure([ok(0, stem(0)), ok(3600, stem(1))])[2]["gaps_over_limit"] == 0)
check("B10 exatamente no limite (3600 s) não é acima; 3601 s é", measure([ok(0, stem(0)), ok(3600, stem(1))])[2]["gaps_over_limit"] == 0 and measure([ok(0, stem(0)), ok(3601, stem(1))])[2]["gaps_over_limit"] == 1)

print("-- C. números (conferidos à mão)")
# dois snapshots novos: o 1º começou em 700 com HEAD de 100 s e publicou em 1000 (atraso 100 + 300 = 400 s); o 2º começou em 4900, HEAD de 100 s, publicou em 5000 (100 + 100 = 200 s)
pubs, _, res = measure([snap(700, stem(0), 100), ok(1000, stem(0)), snap(4900, stem(1), 100), ok(5000, stem(1)), same(6000)])
check("C1 atraso do dado = idade do HEAD ao começar o run + duração do run; 'ponto batido' fica de fora", [p["lag"] for p in pubs] == [400, 200, None], [p["lag"] for p in pubs])
d = res["pickup_lag_s"]
check("C2 quantis do atraso sobre os 2 snapshots novos: min 200 s, max 400 s", d["min"] == 200 and d["max"] == 400, d)
check("C3 contagem por tipo: 2 snapshots novos e 1 ponto batido", res["kinds"] == {"novo": 2, "novo+falha": 0, "mesmo": 1}, res["kinds"])
_, _, res = measure([ok(0, stem(0)), ok(3000, stem(1))])
check("C4 sem a linha 'dado de há' o atraso não é medido (e não vira 0): campo ausente", "pickup_lag_s" not in res, res.keys())
_, _, res = measure([snap(0, stem(0), 100), ok(60, stem(0)), same(200), ok(3100, stem(1))])   # o 2º OK não tem a linha `snapshot` do mesmo stem
check("C4b só um dos snapshots tem a linha: o atraso usa o que existe, não inventa o outro", res["pickup_lag_s"]["min"] == res["pickup_lag_s"]["max"] == 160, res["pickup_lag_s"])
vals = [60, 3600, 3660, 7200, 18000, 3700, 3500, 3900, 4000, 3600]
q = jc.quantiles(vals)
check("C5 quantis (posto mais próximo, para cima: índice int(p*n)): com 10 valores o p50 é o 6º e o p90 é o maior", (q["min"], q["max"], q["p50"], q["p90"]) == (60, 18000, 3700, 18000), q)

print("-- D. linha de comando")
many = []
for i in range(6):
    t = i * 4200
    many += [snap(t - 200, stem(i), 100), ok(t, stem(i))]
many.insert(3, "isto não é uma linha de log")
many.insert(5, "[2026-13-99T99:99:99Z] data impossível")
rc, so, se = run_cli(many)
check("D1 rc 0, texto com o resumo, o limite e o atraso do dado; linhas fora do formato (inclusive mês 13) são ignoradas", rc == 0 and "publicações do latest.json: 6" in so and "gaps > 1h00m: 5 de 5 (100%)" in so and "atraso do dado até o S3" in so, (rc, so, se))
rc, so, _ = run_cli(many, "--json")
j = json.loads(so)
check("D2 --json é JSON com gap_s, over, pickup_lag_s e kinds", rc == 0 and j["gaps"] == 5 and "p50" in j["gap_s"] and "pickup_lag_s" in j and j["kinds"]["novo"] == 6, so[:200])
rc, so, _ = run_cli(many, "--list")
check("D3 --list nomeia cada gap acima do limite com a causa", rc == 0 and so.count("disparo atrasado") >= 5 and "1h10m" in so, so)
since_day = jc.iso(BASE + 3 * 4200)
rc, so, _ = run_cli(many, "--json", "--since", since_day)
check("D4 --since recorta a janela (publicações a partir de t=12600: 3)", rc == 0 and json.loads(so)["publications"] == 3, so[:120])
rc, so, _ = run_cli(many, "--json", "--since", "2026-10-20")
check("D5 --since só com a data (AAAA-MM-DD) vale", rc == 0 and json.loads(so)["publications"] == 6, so[:120])
rc, so, se = run_cli(many, "--limit-s", "5000")
check("D6 --limit-s 5000: nenhum gap de 4200 s passa do limite", rc == 0 and "gaps > 1h23m: 0 de 5" in so, so)
rc, so, se = run_cli(many, "--since", "ontem")
check("D7 --since ilegível => rc 3", rc == 3, (rc, se))
rc, so, se = run_cli(many, "--limit-s", "0")
check("D8 --limit-s 0 => rc 3", rc == 3, (rc, se))
rc, so, se = run_cli(many, "--nao-existe")
check("D9 opção desconhecida => rc 3", rc == 3, rc)
rc, so, se = run_cli([ok(0, stem(0))])
check("D10 uma publicação só => rc 2 (sem gap para medir não é 'tudo bem')", rc == 2 and "menos de 2" in se and not so.strip(), (rc, so, se))
rc, so, se = run_cli([])
check("D11 log vazio => rc 2", rc == 2, (rc, so, se))
r = subprocess.run([sys.executable, "-I", TOOL, "--log", "/nao/existe/x.log"], capture_output=True, text=True)
check("D12 log inexistente => rc 2 com o motivo, e nada em stdout", r.returncode == 2 and "não li o log" in r.stderr and not r.stdout.strip(), (r.returncode, r.stderr, r.stdout))
rc, so, se = run_cli(many, "--since", "2099-01-01")
check("D13 janela sem publicações => rc 2", rc == 2, (rc, so, se))

print("=== RESULT: PASS=%d FAIL=%d ===" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
