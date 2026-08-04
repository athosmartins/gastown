#!/usr/bin/env python3
"""Corrige o IMÓVEL (lote) ao qual um anúncio de BH está designado — de forma persistente.

Front-door: o daemon anuncios (127.0.0.1:8204), o MESMO endpoint que o cockpit humano usa.
NUNCA escreve direto no MotherDuck: o daemon é dono do write-ahead local e do flush, e escrever
por fora deixa os dois fora de sincronia (e o flush seguinte pode sobrescrever você).

Subcomandos:
    localizar <url|trecho>        acha o anúncio e o lote em que ele está HOJE
    lote <rua> [numero]           acha o índice cadastral do lote CERTO
    corrigir --de IC --para IC    grava a correção (persistente)
    verificar <IC>                confere local + MotherDuck
    desfazer <IC>                 remove a correção

Escopo: BH. Contagem tem cockpit irmão (/contagem/correct) com OUTRA identidade — ver SKILL.md.
"""
import argparse
import gzip
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

ANUNCIOS = os.environ.get('ANUNCIOS_DIR', '/Users/athos/gt/whatsapp_automation/daemons/anuncios')
ARTIFACT = os.path.join(ANUNCIOS, 'data', 'anuncios.json.gz')
LOTS_CACHE = os.path.join(ANUNCIOS, 'data', 'bh_lots_cache.duckdb')
DAEMON = os.environ.get('ANUNCIOS_URL', 'http://127.0.0.1:8204')


def _norm_ic(s):
    """IC sem espaços — o build chaveia as linhas assim (norm() do build_dataset)."""
    return re.sub(r'\s+', '', str(s or '')).strip().upper()


def _artifact():
    if not os.path.exists(ARTIFACT):
        sys.exit(f'ERRO: artefato não encontrado: {ARTIFACT}')
    with gzip.open(ARTIFACT) as f:
        return json.load(f)


def _lots_con():
    import duckdb
    if not os.path.exists(LOTS_CACHE):
        sys.exit(f'ERRO: cache de lotes ausente: {LOTS_CACHE}\n'
                 f'      materialize com: python3 {ANUNCIOS}/bh_lots_cache.py')
    return duckdb.connect(LOTS_CACHE, read_only=True)


def _post(path, payload):
    req = urllib.request.Request(DAEMON + path, method='POST',
                                 data=json.dumps(payload).encode(),
                                 headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read())
    except urllib.error.URLError as e:
        sys.exit(f'ERRO: daemon anuncios inacessível em {DAEMON} ({e}).\n'
                 f'      Confira: lsof -nP -iTCP:8204 -sTCP:LISTEN')


def cmd_localizar(args):
    needle = args.alvo.strip()
    rows = [r for r in _artifact() if needle in str(r.get('url') or '')]
    if not rows:
        print(f'Nenhum anúncio com "{needle}" na URL.')
        print('Dica: use um trecho estável da URL (ex.: o id numérico do anúncio).')
        return 1
    for r in rows:
        print('─' * 70)
        print(f"  anúncio ....... {r.get('sources')}  ({r.get('finalidade')}, R$ {r.get('preco')})")
        print(f"  url ........... {r.get('url')}")
        print()
        print(f"  DESIGNADO HOJE ao lote:")
        print(f"    índice cadastral (--de) ... {r.get('imovel_id')}")
        print(f"    endereço .................. {r.get('endereco')}")
        print(f"    bairro .................... {r.get('bairro')}")
        print(f"    área ...................... {r.get('area')} m2")
        print(f"    proprietário .............. {r.get('owners')}")
        print(f"    precisão do match ......... {r.get('prec')}  (loc_status={r.get('loc_status')})")
    print('─' * 70)
    return 0


def cmd_lote(args):
    con = _lots_con()
    rua = args.rua.strip().upper()
    if args.numero:
        sql = ("SELECT base, endereco, bairro, area, prop, n_ind FROM lots "
               "WHERE upper(endereco) LIKE ? AND TRY_CAST(REGEXP_EXTRACT(endereco, '(\\d+)') AS INT) = ? "
               "ORDER BY base")
        rows = con.execute(sql, [f'%{rua}%', int(args.numero)]).fetchall()
    else:
        rows = con.execute("SELECT base, endereco, bairro, area, prop, n_ind FROM lots "
                           "WHERE upper(endereco) LIKE ? ORDER BY endereco LIMIT 40",
                           [f'%{rua}%']).fetchall()
    if not rows:
        print(f'Nenhum lote para "{args.rua}"' + (f' nº {args.numero}' if args.numero else ''))
        return 1
    print(f'{"ÍNDICE CADASTRAL (--para)":26} | {"ENDEREÇO":26} | {"BAIRRO":14} | ÁREA | PROPRIETÁRIO')
    print('─' * 118)
    for base, end, bairro, area, prop, n_ind in rows:
        extra = f'  [lote com {n_ind} índices]' if (n_ind or 1) > 1 else ''
        print(f'{base:26} | {str(end):26} | {str(bairro):14} | {str(area):>5} | {str(prop)[:30]}{extra}')
    return 0


def cmd_corrigir(args):
    de = _norm_ic(args.de)
    para = [_norm_ic(x) for x in args.para.split(',') if x.strip()]
    if not de or not para:
        sys.exit('ERRO: --de e --para são obrigatórios')

    # Guarda: o lote de destino precisa existir no cache. Sem isto, um IC digitado errado
    # entra no override e o build NÃO casa linha nenhuma — a correção some em silêncio,
    # que é exatamente o bug wa-kt5i1 do lado de Contagem.
    con = _lots_con()
    ph = ','.join(['?'] * len(para))
    achados = {r[0]: r for r in con.execute(
        f'SELECT base, endereco, bairro, area, prop FROM lots WHERE base IN ({ph})', para).fetchall()}
    faltando = [p for p in para if p not in achados]
    if faltando:
        sys.exit(f'ERRO: índice(s) cadastral(is) não encontrado(s) no cadastro de BH: {faltando}\n'
                 f'      A correção NÃO foi gravada (um IC inexistente seria ignorado pelo build).\n'
                 f'      Use `lote <rua> <numero>` para achar o índice correto.')

    print('Vai gravar:')
    for p in para:
        b, end, bairro, area, prop = achados[p]
        print(f'   {de}  ->  {b}   ({end}, {bairro}, {area} m2, {prop})')
    if not args.sim:
        resp = input('Confirma? [s/N] ').strip().lower()
        if resp not in ('s', 'sim', 'y', 'yes'):
            print('abortado.')
            return 1

    out = _post('/bh/correct', {'imovel_id': de, 'fonte': 'bh', 'indices': para})
    if out.get('error'):
        sys.exit(f"ERRO do daemon: {out['error']}")
    print('OK:', json.dumps(out.get('match', {}), ensure_ascii=False))
    print()
    print('Gravado. Confira com:  corrigir_anuncio.py verificar', de)
    return 0


def _md_con():
    import duckdb
    tok = os.environ.get('MOTHERDUCK_TOKEN') or subprocess.check_output(
        [os.path.expanduser('~/.local/bin/secret'), 'motherduck-token'], text=True, timeout=20).strip()
    return duckdb.connect('md:real_estate?motherduck_token=' + tok)


def cmd_verificar(args):
    import duckdb
    ic = _norm_ic(args.ic)
    store = os.path.join(ANUNCIOS, 'data', 'bh_verdicts_local.duckdb')
    print('1) write-ahead LOCAL (instantâneo):')
    try:
        c = duckdb.connect(store, read_only=True)
        o = c.execute('SELECT corrected_ic, corrected_logradouro, corrected_bairro, '
                      'assemblage_area_m2, synced FROM overrides WHERE imovel_id=?', [ic]).fetchall()
        v = c.execute('SELECT status, indices, synced FROM verdicts WHERE imovel_id=?', [ic]).fetchall()
        print('   override:', o or '(nenhum)')
        print('   veredito:', v or '(nenhum)')
        if o and not o[0][-1]:
            print('   ⚠️ synced=False — ainda não foi pro MotherDuck (o refresh.py flusha antes do build)')
    except Exception as e:
        print('   (não consegui ler o store local:', e, ')')

    print('2) MotherDuck (o que o build noturno lê):')
    try:
        con = _md_con()
        r = con.execute('SELECT corrected_ic, corrected_logradouro, corrected_bairro, '
                        'assemblage_area_m2, corrected_lat, corrected_lon, corrected_at '
                        "FROM pesquisa_mercado.bh_match_overrides WHERE imovel_id=? AND fonte='bh'",
                        [ic]).fetchall()
        print('   ', r or '(nenhum) — a correção NÃO vai sobreviver ao rebuild')
    except Exception as e:
        print('   (MotherDuck indisponível:', e, ')')

    print('3) artefato servido AGORA (só muda depois do próximo build, 01:30):')
    rows = [r for r in _artifact() if r.get('imovel_id') == ic]
    for r in rows:
        print(f"    endereco={r.get('endereco')} | bairro={r.get('bairro')} | "
              f"area={r.get('area')} | loc_status={r.get('loc_status')}")
    if not rows:
        print('    (linha não está no artefato atual)')
    return 0


def cmd_desfazer(args):
    ic = _norm_ic(args.ic)
    out = _post('/bh/verdict', {'imovel_id': ic, 'fonte': 'bh', 'status': 'pendente'})
    if out.get('error'):
        sys.exit(f"ERRO do daemon: {out['error']}")
    print('OK — veredito "pendente" gravado; o flush apaga o override no MotherDuck.')
    print('Confira com: corrigir_anuncio.py verificar', ic)
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)

    a = sub.add_parser('localizar', help='acha o anúncio pela URL e mostra o lote atual')
    a.add_argument('alvo', help='URL do anúncio ou trecho dela (ex.: o id)')
    a.set_defaults(func=cmd_localizar)

    b = sub.add_parser('lote', help='acha o índice cadastral do lote certo')
    b.add_argument('rua')
    b.add_argument('numero', nargs='?')
    b.set_defaults(func=cmd_lote)

    c = sub.add_parser('corrigir', help='grava a correção (persistente)')
    c.add_argument('--de', required=True, help='IC do lote ERRADO (= imovel_id da linha do anúncio)')
    c.add_argument('--para', required=True, help='IC do lote CERTO (vírgula p/ vários)')
    c.add_argument('--sim', action='store_true', help='não pergunta confirmação')
    c.set_defaults(func=cmd_corrigir)

    d = sub.add_parser('verificar', help='confere local + MotherDuck + artefato')
    d.add_argument('ic')
    d.set_defaults(func=cmd_verificar)

    e = sub.add_parser('desfazer', help='remove a correção')
    e.add_argument('ic')
    e.set_defaults(func=cmd_desfazer)

    args = p.parse_args()
    sys.exit(args.func(args) or 0)


if __name__ == '__main__':
    main()
