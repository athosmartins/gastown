#!/usr/bin/env python3
"""dolt-load-page — página estática de atribuição da carga do Dolt.

Lê o JSONL do dolt-load-attributor e gera HTML autocontido. NÃO consulta o Dolt:
um painel que consulta o banco pra mostrar carga do banco adiciona a carga que
está medindo — foi exatamente o que fez o painel.urblink se derrubar sozinho
(wa-mvnv2). Aqui a fonte é o arquivo que o coletor já escreveu.

Duas visões porque respondem perguntas diferentes:
  AGORA    barras horizontais do último ciclo — 'quem está comendo o Dolt neste
           momento', que é o que se olha durante um incidente.
  HISTÓRICO área empilhada por dono — 'quem MUDOU e desde quando', que é o que
           permite agir (um dono que dobra às 14h aponta pro que mudou às 14h).
"""
import json, os, sys, html
from collections import defaultdict, OrderedDict
from datetime import datetime

SRC = os.path.expanduser(os.environ.get("DOLT_ATTR_LOG",
      "~/gt/.gascity-gastown-hq/.gc/logs/dolt-load-attribution.jsonl"))
OUT = os.path.expanduser(os.environ.get("DOLT_PAGE_OUT",
      "~/gt/.gascity-gastown-hq/.gc/logs/dolt-load.html"))
TOP = 5  # 5 donos + "outros" = 6 slots; a paleta tem ordem fixa de 8, nunca ciclada

# Ordem categórica FIXA (dataviz reference palette, validada:
#   light  ALL CHECKS PASS  (WARN de contraste -> exige rótulo visível/tabela: temos os dois)
#   dark   ALL CHECKS PASS)
LIGHT = ["#2a78d6","#eb6834","#1baf7a","#eda100","#e87ba4","#008300"]
DARK  = ["#3987e5","#d95926","#199e70","#c98500","#d55181","#008300"]

def load():
    recs = []
    try:
        with open(SRC, encoding="utf-8") as f:
            for ln in f:
                ln = ln.strip()
                if not ln: continue
                try: recs.append(json.loads(ln))
                except json.JSONDecodeError: continue
    except FileNotFoundError:
        return []
    return recs

def pct(rec):
    tot = rec.get("samples") or sum((rec.get("by_owner") or {}).values()) or 1
    return {k: 100.0*v/tot for k, v in (rec.get("by_owner") or {}).items()}

def hhmm(ts):
    try: return datetime.fromisoformat(ts.replace("Z","+00:00")).astimezone().strftime("%H:%M")
    except Exception: return "?"

def build(recs):
    if not recs:
        return None
    last = recs[-1]
    cur = sorted(pct(last).items(), key=lambda kv: -kv[1])
    # donos rankeados pela MÉDIA na janela — cor segue a ENTIDADE, não o rank do
    # ciclo (um filtro que muda a contagem não pode repintar os sobreviventes)
    acc = defaultdict(float)
    for r in recs:
        for k, v in pct(r).items(): acc[k] += v
    ranked = [k for k, _ in sorted(acc.items(), key=lambda kv: -kv[1])]
    named = ranked[:TOP]
    slot = OrderedDict((n, i) for i, n in enumerate(named))
    series = named + (["outros"] if len(ranked) > TOP else [])
    rows = []
    for r in recs:
        p = pct(r)
        row = {"t": hhmm(r.get("ts","")), "cpu": r.get("dolt_cpu_end") or ""}
        vals = [round(p.get(n, 0.0), 1) for n in named]
        if len(ranked) > TOP:
            vals.append(round(sum(v for k, v in p.items() if k not in slot), 1))
        row["v"] = vals
        rows.append(row)
    return {"series": series, "rows": rows, "current": cur,
            "cpu": last.get("dolt_cpu_end") or "?", "n": len(recs),
            "samples": last.get("samples", 0), "when": hhmm(last.get("ts",""))}

def render(d):
    if d is None:
        return "<p>Sem dados ainda — o coletor grava a cada 10min.</p>"
    ser = d["series"]; rows = d["rows"]
    lg = ",".join(LIGHT[:len(ser)]); dk = ",".join(DARK[:len(ser)])
    # ---- barras do AGORA (rótulo direto em cada barra: exigência do WARN) ----
    top = d["current"][:8]
    mx = max([v for _, v in top] or [1])
    bars = []
    for i, (k, v) in enumerate(top):
        w = max(1.0, 100.0*v/mx)
        c = f"var(--s{slot_of(k, ser)})" if slot_of(k, ser) is not None else "var(--muted-mark)"
        bars.append(
            f'<div class="brow"><div class="bname" title="{html.escape(k)}">{html.escape(k)}</div>'
            f'<div class="btrack"><div class="bfill" style="width:{w:.1f}%;background:{c}"></div></div>'
            f'<div class="bval">{v:.1f}%</div></div>')
    # ---- área empilhada do HISTÓRICO ----
    W, H, PL, PB, PT = 720, 210, 44, 26, 12
    n = len(rows)
    area = ""
    if n >= 2:
        stepx = (W-PL-8)/(n-1)
        cum = [0.0]*n
        polys = []
        for si in range(len(ser)):
            top_pts, bot_pts = [], []
            for xi, r in enumerate(rows):
                x = PL + xi*stepx
                y0 = H-PB - (cum[xi]/100.0)*(H-PB-PT)
                cum[xi] += r["v"][si] if si < len(r["v"]) else 0
                y1 = H-PB - (cum[xi]/100.0)*(H-PB-PT)
                top_pts.append(f"{x:.1f},{y1:.1f}"); bot_pts.append(f"{x:.1f},{y0:.1f}")
            polys.append(f'<polygon class="ar" points="{" ".join(top_pts+bot_pts[::-1])}" '
                         f'fill="var(--s{si})"/>')
        gy = "".join(f'<line class="gl" x1="{PL}" y1="{H-PB-(p/100)*(H-PB-PT):.1f}" '
                     f'x2="{W-8}" y2="{H-PB-(p/100)*(H-PB-PT):.1f}"/>'
                     f'<text class="ax" x="{PL-7}" y="{H-PB-(p/100)*(H-PB-PT)+3:.1f}" '
                     f'text-anchor="end">{p}%</text>' for p in (0,50,100))
        xl = "".join(f'<text class="ax" x="{PL+xi*stepx:.1f}" y="{H-PB+15}" '
                     f'text-anchor="middle">{html.escape(rows[xi]["t"])}</text>'
                     for xi in range(0, n, max(1, n//6)))
        area = (f'<svg viewBox="0 0 {W} {H}" role="img" '
                f'aria-label="Composição da carga do Dolt por dono ao longo do tempo">'
                f'{gy}{"".join(polys)}{xl}</svg>')
    else:
        area = ('<p class="thin">A série temporal precisa de pelo menos 2 ciclos. '
                f'Há {n} até agora — o coletor grava a cada 10 minutos.</p>')
    leg = "".join(f'<span class="lg"><i style="background:var(--s{i})"></i>{html.escape(s)}</span>'
                  for i, s in enumerate(ser))
    trows = "".join(
        f'<tr><td>{html.escape(k)}</td><td class="num">{v:.1f}%</td></tr>'
        for k, v in d["current"])
    return f"""<div class="viz-root" data-palette-light="{lg}" data-palette-dark="{dk}">
<header><h1>Carga do Dolt · por dono</h1>
<p class="sub">Última leitura {html.escape(d["when"])} · {d["samples"]} amostras ·
CPU do Dolt ao fim do ciclo <strong>{html.escape(str(d["cpu"]))}%</strong> ·
{d["n"]} ciclo(s) no histórico</p></header>

<section><h2>Agora</h2>
<div class="bars">{"".join(bars)}</div></section>

<section><h2>Histórico — composição por dono</h2>
<div class="legend">{leg}</div>
<div class="chart">{area}</div></section>

<section><h2>Tabela do ciclo atual</h2>
<table><thead><tr><th>Dono</th><th class="num">Share</th></tr></thead>
<tbody>{trows}</tbody></table></section>

<footer><p class="thin">Mede <strong>connection-samples</strong>, não CPU por processo:
o macOS não atribui ao cliente o CPU que o servidor gastou por causa dele. É proxy de
carga, não medida direta. A página é estática e <strong>não consulta o Dolt</strong> —
lê o JSONL que o coletor grava.</p></footer></div>"""

def slot_of(name, ser):
    return ser.index(name) if name in ser else (len(ser)-1 if "outros" in ser else None)

CSS = """<style>
.viz-root{--surface-1:#fcfcfb;--text-primary:#1a1a19;--text-secondary:#5a5a55;
--grid:#e6e5df;--muted-mark:#c3c2b7;
--s0:#2a78d6;--s1:#eb6834;--s2:#1baf7a;--s3:#eda100;--s4:#e87ba4;--s5:#008300;
color-scheme:light;background:var(--surface-1);color:var(--text-primary);
font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
padding:20px;max-width:820px;margin:0 auto}
@media (prefers-color-scheme:dark){:root:where(:not([data-theme="light"])) .viz-root{
color-scheme:dark;--surface-1:#1a1a19;--text-primary:#fff;--text-secondary:#c3c2b7;
--grid:#33322e;--muted-mark:#5a5a55;
--s0:#3987e5;--s1:#d95926;--s2:#199e70;--s3:#c98500;--s4:#d55181;--s5:#008300}}
:root[data-theme="dark"] .viz-root{color-scheme:dark;--surface-1:#1a1a19;
--text-primary:#fff;--text-secondary:#c3c2b7;--grid:#33322e;--muted-mark:#5a5a55;
--s0:#3987e5;--s1:#d95926;--s2:#199e70;--s3:#c98500;--s4:#d55181;--s5:#008300}
h1{font-size:19px;margin:0 0 2px}h2{font-size:13px;text-transform:uppercase;
letter-spacing:.06em;color:var(--text-secondary);margin:26px 0 10px;font-weight:600}
.sub,.thin{color:var(--text-secondary);font-size:13px;margin:0}
.brow{display:flex;align-items:center;gap:10px;margin:5px 0}
.bname{flex:0 0 176px;font-size:13px;overflow:hidden;text-overflow:ellipsis;
white-space:nowrap;color:var(--text-primary)}
.btrack{flex:1;background:var(--grid);border-radius:4px;height:15px;overflow:hidden}
.bfill{height:100%;border-radius:0 4px 4px 0}
.bval{flex:0 0 52px;text-align:right;font-variant-numeric:tabular-nums;
font-size:13px;color:var(--text-primary)}
.chart{overflow-x:auto}svg{width:100%;height:auto;display:block}
.ar{stroke:var(--surface-1);stroke-width:2}
.gl{stroke:var(--grid);stroke-width:1}
.ax{fill:var(--text-secondary);font-size:10px}
.legend{display:flex;flex-wrap:wrap;gap:12px;margin-bottom:8px}
.lg{display:inline-flex;align-items:center;gap:5px;font-size:12px;
color:var(--text-secondary)}
.lg i{width:11px;height:11px;border-radius:3px;display:inline-block}
table{border-collapse:collapse;width:100%;font-size:13px}
th,td{text-align:left;padding:5px 8px;border-bottom:1px solid var(--grid)}
th{color:var(--text-secondary);font-weight:600;font-size:11px;text-transform:uppercase}
.num{text-align:right;font-variant-numeric:tabular-nums}
footer{margin-top:26px;padding-top:12px;border-top:1px solid var(--grid)}
</style>"""

def main():
    d = build(load())
    doc = ("<!doctype html><html lang=\"pt-BR\"><head><meta charset=\"utf-8\">"
           "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
           "<title>Carga do Dolt por dono</title>" + CSS + "</head><body>"
           + render(d) + "</body></html>")
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f: f.write(doc)
    print(f"gerado: {OUT} ({len(doc)} bytes, {0 if d is None else d['n']} ciclo(s))")

    # Publicação S3 (opcional, ligada por DOLT_PAGE_S3). Chave FIXA: o Athos
    # guarda o link uma vez e ele continua valendo — presign expira em 7 dias e
    # viraria manutenção recorrente. NÃO usa o prefixo mockups/: ele tem Deny
    # anônimo desde 2026-07-30 (ga-3qq0y) e a página ficaria 403.
    dest = os.environ.get("DOLT_PAGE_S3", "")
    if dest:
        import subprocess
        try:
            r = subprocess.run(["aws","s3","cp",OUT,dest,
                                "--content-type","text/html; charset=utf-8",
                                "--cache-control","max-age=60"],
                               capture_output=True, text=True, timeout=120)
            print("publicado" if r.returncode == 0
                  else f"(aviso: upload falhou rc={r.returncode}: {r.stderr.strip()[:120]})")
        except Exception as e:
            print(f"(aviso: upload falhou: {e})")
    return 0

if __name__ == "__main__":
    sys.exit(main())
