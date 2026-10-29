#!/usr/bin/env python3
"""Linha de base de uso real do MCP playwright-cdp nos transcritos (ga-g7zyxc3, item 2 do par. 9 do relatorio).

SO AGREGADOS: contagem de chamadas por ferramenta e por dia, e bytes de resultado. Nenhum conteudo de transcrito e impresso.
Leitura: so arquivos *.jsonl modificados nos ultimos N dias dentro de ~/.claude/projects (raiz fixa, sem varrer o HOME).
vazio -> contagem 0 e diz "0 chamadas"; arquivo ilegivel/linha invalida -> conta em `skipped`, nunca vira 0 chamadas em silencio.
"""
import collections, json, os, re, sys, time

DAYS = int(sys.argv[1]) if len(sys.argv) > 1 else 9
ROOT = os.path.expanduser('~/.claude/projects')
cut = time.time() - DAYS * 86400
USE = re.compile(r'"name":"(mcp__playwright-cdp__[A-Za-z_]+)"')
TID = re.compile(r'"id":"(toolu_[A-Za-z0-9]+)"')
RID = re.compile(r'"tool_use_id":"(toolu_[A-Za-z0-9]+)"')

calls = collections.Counter()            # (dia, ferramenta) -> n
res_bytes = collections.defaultdict(int)  # ferramenta -> bytes de resultado
res_n = collections.Counter()
sessions = set()
files = skipped = bad_lines = 0

def result_len(content):
    if isinstance(content, str):
        return len(content.encode('utf-8', 'ignore'))
    n = 0
    for c in content or []:
        if isinstance(c, dict):
            if c.get('type') == 'text':
                n += len(c.get('text', '').encode('utf-8', 'ignore'))
            elif c.get('type') == 'image':
                n += 0  # imagem nao e texto; contada a parte se precisar
    return n

for dirpath, _dirs, names in os.walk(ROOT):
    for nm in names:
        if not nm.endswith('.jsonl'):
            continue
        p = os.path.join(dirpath, nm)
        try:
            if os.stat(p).st_mtime < cut:
                continue
            files += 1
            ids = {}
            f1 = open(p, 'r', encoding='utf-8', errors='ignore')
        except OSError:
            skipped += 1
            continue
        for ln in f1:
            if 'mcp__playwright-cdp__' not in ln or '"tool_use"' not in ln:
                continue
            try:
                o = json.loads(ln)
            except ValueError:
                bad_lines += 1
                continue
            day = (o.get('timestamp') or '')[:10] or '?'
            msg = o.get('message') or {}
            for c in (msg.get('content') or []) if isinstance(msg.get('content'), list) else []:
                if isinstance(c, dict) and c.get('type') == 'tool_use' and str(c.get('name', '')).startswith('mcp__playwright-cdp__'):
                    ids[c['id']] = c['name']
                    calls[(day, c['name'])] += 1
                    sessions.add(nm)
        f1.close()
        if not ids:
            continue
        try:
            f2 = open(p, 'r', encoding='utf-8', errors='ignore')
        except OSError:
            skipped += 1
            continue
        for ln in f2:
            if '"tool_result"' not in ln:
                continue
            m = RID.search(ln)
            if not m or m.group(1) not in ids:
                continue
            try:
                o = json.loads(ln)
            except ValueError:
                bad_lines += 1
                continue
            for c in (o.get('message') or {}).get('content') or []:
                if isinstance(c, dict) and c.get('type') == 'tool_result' and c.get('tool_use_id') in ids:
                    t = ids[c['tool_use_id']]
                    res_bytes[t] += result_len(c.get('content'))
                    res_n[t] += 1
        f2.close()

per_day = collections.Counter()
per_tool = collections.Counter()
for (d, t), n in calls.items():
    per_day[d] += n
    per_tool[t] += n
total = sum(per_day.values())
print(f'janela: {DAYS} dias | arquivos lidos: {files} | ilegiveis: {skipped} | linhas invalidas: {bad_lines} | sessoes com playwright-cdp: {len(sessions)}')
print(f'chamadas mcp__playwright-cdp__*: {total}')
print('por dia:', ', '.join(f'{d}={n}' for d, n in sorted(per_day.items())) or '(nenhuma)')
print('por ferramenta (chamadas | resultados lidos | KB de texto de resultado | KB medio):')
for t, n in per_tool.most_common():
    rn, rb = res_n[t], res_bytes[t]
    print(f'  {t.replace("mcp__playwright-cdp__", ""):28s} {n:5d} | {rn:5d} | {rb/1024:9.1f} | {(rb/1024/rn) if rn else 0:7.2f}')
print(f'KB de resultado no total: {sum(res_bytes.values())/1024:.1f}')
