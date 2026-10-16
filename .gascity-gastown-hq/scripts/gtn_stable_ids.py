"""gtn_stable_ids — plugin do pytest da bateria noturna do nó Linux (ga-9p6pte). Carregado com `-p gtn_stable_ids` (PYTHONPATH=~/gt-remote/bin).

## Contents
  Por quê · O que muda

POR QUÊ: a suíte inteira sob xdist abortava com "Different tests were collected between gw0 and gw1". Medido no nó (16/10, 4 coletas de 68.479 testes em cópias separadas):
  duas coletas com a MESMA semente de hash (PYTHONHASHSEED=0) diferem em 2 ids, e com sementes aleatórias em 3. A semente cobre a ORDEM de parametrização por set; o que sobra
  são ids com RELÓGIO dentro: `[2026-10-14T18:32:55-velha]` (test_pipedrive_nucleos_sync_wa_xlhdoi) e `voicebot-1792135915-1792135915.33803` (test_voicebot_pull_recordings_script_wa_zm78r).
  Cada worker coleta num segundo e o xdist compara os ids dos workers. Estes ids também mudariam a cada noite, e toda falha deles apareceria como "nova" no relatório.
O QUE MUDA: SÓ o node id (texto) de quem tem timestamp ISO ou epoch de 10 dígitos: vira `<TS>` / `<EPOCH>`. O teste, os parâmetros e o que ele executa não mudam; o xdist agenda por índice.
"""
import re

import pytest

_TS = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}")
_EPOCH = re.compile(r"(?<![\d.])1[5-9]\d{8}(?!\d)")


@pytest.hookimpl(trylast=True)
def pytest_collection_modifyitems(session, config, items):
    for item in items:
        stable = _EPOCH.sub("<EPOCH>", _TS.sub("<TS>", item._nodeid))
        if stable != item._nodeid:
            item._nodeid = stable
