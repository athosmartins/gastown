"""gtn_stable_ids — plugin do pytest da bateria noturna do nó Linux (ga-9p6pte). Carregado com `-p gtn_stable_ids` (PYTHONPATH=~/gt-remote/bin).

## Contents
  Por quê · O que muda · Ids reprovados · Escudo do relatório

POR QUÊ: a suíte inteira sob xdist abortava com "Different tests were collected between gw0 and gw1". Medido no nó (16/10, 4 coletas de 68.479 testes em cópias separadas):
  duas coletas com a MESMA semente de hash (PYTHONHASHSEED=0) diferem em 2 ids, e com sementes aleatórias em 3. A semente cobre a ORDEM de parametrização por set; o que sobra
  são ids com RELÓGIO dentro: `[2026-10-14T18:32:55-velha]` (test_pipedrive_nucleos_sync_wa_xlhdoi) e `voicebot-1792135915-1792135915.33803` (test_voicebot_pull_recordings_script_wa_zm78r).
  Cada worker coleta num segundo e o xdist compara os ids dos workers. Estes ids também mudariam a cada noite, e toda falha deles apareceria como "nova" no relatório.
  2ª ocorrência (ga-2hd02v.5.7, medido no nó em 03/11): o `wa-suite` do lastro fez 27 rodadas SEGUIDAS rc 3 `total-implausivel` (de 02/11 04:35Z a 03/11 03:43Z; ~63 erros, 0 testes
  rodados, 5 núcleos parados) e nenhuma `completo` desde 29/10 15:42Z. O pytest abortou com "Different tests were collected between gw2 and gw4" e o ÚNICO id que diferia, nas 2 rodadas
  que ainda tinham log no nó, era `test_selo_com_carimbo_ilegivel_ou_no_futuro_nao_usa[2026-12-03 03:39:23]` vs `...:24` (test_lot_complementos_assado_unico_wa_9rdam3_1, a1a04dabc,
  01/11): o relógio com ESPAÇO no lugar do `T`. O padrão antigo só conhecia o `T`, então o id passava sem troca e cada worker coletava o seu segundo.
  NÃO explicado por isto: 7 rodadas rc 3 esporádicas de 27/10 a 29/10 (a mesma ponta passou na rodada seguinte; os logs já foram podados), de outra fonte de instabilidade que não se mediu.
O QUE MUDA: SÓ o node id (texto) de quem tem timestamp `AAAA-MM-DD` + `T` ou espaço + `HH:MM:SS`, com ou sem fração (`.123456` de `str(datetime.now())`, `,123` do logging), ou epoch de
  10 dígitos: vira `<TS>` / `<EPOCH>`. O teste, os parâmetros e o que ele executa não mudam; o xdist agenda por índice.
  NÃO coberto: data sem hora (`2026-12-03`: estável durante a coleta, muda à meia-noite), fuso depois dos segundos (o texto do fuso é igual em todos os workers) e epoch com fração
  (`1792135915.33803` vira `<EPOCH>.33803`; a fração não foi medida como instável).
IDS REPROVADOS: o relatório da noite compara os ids que falharam com os da noite anterior. Cortar a linha `FAILED <id> - <mensagem>` no primeiro " - " perde id de parametrize que tem " - "
  dentro (`[ADE V - Setor 4]` e `[ADE V - Setor 5]` viravam UMA linha). Por isso o id sai daqui, de quem o tem inteiro, no fim da sessão, SÓ no controlador (o worker do xdist não imprime):
    GTN-FAIL: <id em JSON>                  uma linha por id distinto de teste reprovado (falha OU erro); JSON ASCII, então não tem quebra de linha nem " - " ambíguo
    GTN-FAILED: n=<ids distintos> reports=<falhas + erros que o pytest contou>
  `reports` é o número que o resumo do pytest também mostra (failed + error); o script confere os dois e a quantidade de linhas GTN-FAIL contra `n`. Sem zero por engano:
    vazio (nenhuma falha) → emite `n=0 reports=0`;  falhou/ilegível (qualquer exceção ao montar a lista) → NÃO emite nada, e o script lê "sem lista" como comparação indisponível.
ESCUDO DO RELATÓRIO (ga-84gkpab): no trial de 15/11 o lote 1 da noite em lotes MORREU com rc=3 (INTERNALERROR do xdist) aos ~14% e perdeu 7.997 testes por causa de UM. Causa: o conftest.py raiz do WA
  (`_filtrado_pelo_espelho`, wa-fsatxi) roda `git ls-files` dentro de `pytest_runtest_makereport` quando um teste reprova com FileNotFoundError; o teste
  `test_alimentador_lista_ok_false_alarme_wa_79apps.py::test_aviso_liga_strict_exit_e_o_timeout_cobre_o_autodispatch` troca `subprocess.run` por um falso (`stdout=None`) E lê `scripts/notify`, que o nó
  não recebe: o `r.stdout.split(NUL)` do conftest levanta AttributeError, o worker sai e o controlador aborta a sessão. No mini o arquivo existe, o hook nem corre e ninguém vê. Reproduz em 30 s com o
  arquivo sozinho (`-n 0`, rc=3). A correção de fato é de uma linha no conftest do WA (tratar `stdout` que não é texto como «não sei»); até lá, e para qualquer outro hook da suíte que quebre
  do mesmo jeito, este plugin envolve a montagem do relatório por FORA: se um hook levanta exceção, o relatório é refeito do jeito padrão do pytest (`TestReport.from_item_and_call`), SEM o hook que
  quebrou. O teste continua reprovando (o FileNotFoundError é de verdade: o nó não tem o arquivo), nada vira verde; só deixa de derrubar o lote. O relatório refeito leva a seção `GTN-ESCUDO` e o controlador
  imprime `GTN-ESCUDO: n=<quantos>` (só quando n > 0). Se nem o relatório padrão sai, a exceção original segue adiante (o lote aborta e fica «não rodou», como antes).
"""
import json
import re
import sys

import pytest

_TS = re.compile(r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?")
_EPOCH = re.compile(r"(?<![\d.])1[5-9]\d{8}(?!\d)")


@pytest.hookimpl(trylast=True)
def pytest_collection_modifyitems(session, config, items):
    for item in items:
        stable = _EPOCH.sub("<EPOCH>", _TS.sub("<TS>", item._nodeid))
        if stable != item._nodeid:
            item._nodeid = stable


def _relatorio_sem_o_hook(item, call, exc):
    """O relatório padrão do pytest para (item, call), marcado com a seção GTN-ESCUDO; None se nem ele sai."""
    try:
        rep = pytest.TestReport.from_item_and_call(item, call)
        aviso = "GTN-ESCUDO: um hook da suíte quebrou ao montar o relatório (%s: %s) em %s [%s]; relatório refeito sem ele" % (
            type(exc).__name__, exc, item.nodeid, call.when)
        rep.sections.append(("GTN-ESCUDO", aviso))
        sys.stderr.write(aviso + "\n")
        return rep
    except Exception:
        return None


@pytest.hookimpl(wrapper=True, tryfirst=True)
def pytest_runtest_makereport(item, call):
    try:
        return (yield)
    except Exception as exc:
        rep = _relatorio_sem_o_hook(item, call, exc)
        if rep is None:
            raise
        return rep


def pytest_terminal_summary(terminalreporter, exitstatus, config):
    if hasattr(config, "workerinput"):  # worker do xdist: quem tem todos os relatórios é o controlador
        return
    try:
        escudos = sum(1 for lst in terminalreporter.stats.values() for r in lst
                      if any(nome == "GTN-ESCUDO" for nome, _ in (getattr(r, "sections", None) or ())))
        if escudos:
            terminalreporter.write_line("GTN-ESCUDO: n=%d" % escudos)
    except Exception:
        pass  # contar o escudo é enfeite: nunca atrapalha a lista de ids abaixo
    try:
        reports = [r for key in ("failed", "error") for r in terminalreporter.stats.get(key, []) if getattr(r, "count_towards_summary", True)]
        ids = sorted({r.nodeid for r in reports})
        lines = ["GTN-FAIL: " + json.dumps(i, ensure_ascii=True) for i in ids]
        lines.append("GTN-FAILED: n=%d reports=%d" % (len(ids), len(reports)))
    except Exception:  # não monta a lista inteira → não emite NADA (lista parcial é pior que nenhuma)
        return
    for line in lines:
        terminalreporter.write_line(line)
