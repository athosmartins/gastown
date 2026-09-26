#!/usr/bin/env python3
"""overlay-root-leak-guard.py (ga-swnkfm)

POR QUE (incidente de 26/09): a ga-aijm2v.6 deu aos revisores o overlay `pool-reviewer`. Os revisores NAO tem
work_dir proprio: rodam na RAIZ da cidade. O engine faz JSON-merge do overlay_dir em <workdir>/.claude/settings.json,
entao o overlay do revisor virou o <cidade>/.claude/settings.json — e o engine deriva o <cidade>/.gc/settings.json
(o --settings de TODAS as sessoes) de "defaults embutidos + <cidade>/.claude/settings.json" (internal/hooks/hooks.go
installClaude/desiredClaudeSettings). Resultado medido: gate-done OFF (builder nao consegue submeter ao gate),
CLAUDE.md do Athos/gt fora do contexto, memoria off, deny de Agent/EnterWorktree — em TODAS as sessoes da cidade.

A sobra VOLTOU depois do revert (2a ocorrencia): o merge de overlay (internal/overlay/merge.go MergeSettingsJSON) SO
ADICIONA — chave de topo nao-hook: o overlay vence; hooks: uniao. Nunca remove. Reverter o overlay_dir NAO desfaz o
estrago, e um supervisor com config antiga em cache re-mescla o overlay velho. Por isso este guard olha o ARTEFATO
(os dois arquivos), nao so a config.

O QUE FAZ (detection-only — nunca escreve nada; limpar e decisao de quem tem o contexto):
  1. ARTEFATOS: le <cidade>/.claude/settings.json E <cidade>/.gc/settings.json e procura "folhas de papel" — folhas
     (caminho+valor) que existem em algum overlay por papel mas NAO no overlay base (`pool`). Achou = contaminado.
  2. TOPOLOGIA (a causa, antes de qualquer spawn): de `gc config show`, agente com overlay_dir cujo work_dir resolve
     pra RAIZ da cidade so pode usar overlay sem delta sobre o base; e dois agentes com overlays divergentes nao
     podem dividir o mesmo work_dir (o merge acumula, o ultimo nao apaga o anterior).

ERRO != VAZIO: arquivo ilegivel/JSON invalido, config que nao carrega, diretorio de overlays vazio => rc 2
(desconhecido), NUNCA rc 0. Sao TRES estados: limpo (0) / contaminado (1) / nao-consegui-saber (2).

Uso:  overlay-root-leak-guard.py [--json] [--no-alarm] [--order] [--city DIR] [--config-toml FILE] ...
      rc (CLI): 0 limpo | 1 vazamento | 2 nao consegui saber.  --order (o `gc order`): 0 se alarmou/deduplicou, 2 se a entrega do alarme falhou.
Env:  GC_CITY_PATH | GC_CITY (cidade), OVLG_STATE_DIR, OVLG_ROUTER, OVLG_ESCALATE_AFTER_S (default 14400 = 4h),
      OVLG_GC_TIMEOUT_S (default 120).
Import (selftest): importlib.util.spec_from_file_location — entry() so roda sob __main__.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import subprocess
import sys
import time
from pathlib import Path

try:
    import tomllib  # python >= 3.11
except ImportError:  # um traceback sairia rc 1 == 'vazamento': erro nao pode se passar por achado
    print("overlay-root-leak-guard: ERRO — python >= 3.11 (tomllib) necessario; achei " + sys.version.split()[0] + " (rc 2 = nao consegui verificar)", file=sys.stderr)
    sys.exit(2)

RC_OK, RC_LEAK, RC_UNKNOWN = 0, 1, 2

ARTIFACT_RELS = (".claude/settings.json", ".gc/settings.json")
DEFAULT_BASE_OVERLAY = "pool"
SAMPLE_LEAVES = 8


# ----------------------------------------------------------------------------- folhas (o vocabulario da comparacao)
def _canon(v) -> str:
    return json.dumps(v, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def leaves(doc, path: tuple = ()) -> set:
    """Conjunto de folhas (caminho, valor-canonico) de um JSON.

    dict -> recursa por chave; lista -> UMA folha por elemento sob o caminho + "[]" (deny/claudeMdExcludes/hooks: o
    que importa e QUAIS elementos estao la, nao a ordem); escalar -> folha. Vazio ({} ou []) conta como folha, senao
    "skillOverrides: {}" seria invisivel.
    """
    out: set = set()
    if isinstance(doc, dict):
        if not doc and path:
            out.add((path, "{}"))
        for k, v in doc.items():
            out |= leaves(v, path + (str(k),))
    elif isinstance(doc, list):
        if not doc and path:
            out.add((path, "[]"))
        for el in doc:
            out.add((path + ("[]",), _canon(el)))
    else:
        out.add((path, _canon(doc)))
    return out


def fmt_leaf(leaf) -> str:
    path, val = leaf
    return ".".join(path) + "=" + val


# ----------------------------------------------------------------------------- leitura (3 estados)
def read_json_object(path: Path):
    """-> (estado, obj, erro). estado: ok | absent | unreadable. Nunca colapsa erro em ausencia."""
    try:
        raw = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return "absent", None, None
    except OSError as e:
        return "unreadable", None, f"{path}: {e}"
    try:
        obj = json.loads(raw)
    except ValueError as e:
        return "unreadable", None, f"{path}: JSON invalido ({e})"
    if not isinstance(obj, dict):
        return "unreadable", None, f"{path}: JSON nao e um objeto de topo"
    return "ok", obj, None


def load_overlays(overlays_dir: Path):
    """-> ({nome: set(folhas)}, [erros]). Diretorio ausente/vazio e ERRO (nao da pra calcular delta)."""
    errs: list = []
    if not overlays_dir.is_dir():
        return {}, [f"diretorio de overlays nao existe: {overlays_dir}"]
    out: dict = {}
    for d in sorted(p for p in overlays_dir.iterdir() if p.is_dir()):
        f = d / ".claude" / "settings.json"
        state, obj, err = read_json_object(f)
        if state == "absent":
            continue
        if state == "unreadable":
            errs.append(f"overlay '{d.name}': {err}")
            continue
        out[d.name] = leaves(obj)
    if not out and not errs:
        errs.append(f"nenhum overlay (<nome>/.claude/settings.json) em {overlays_dir}")
    return out, errs


def base_overlay_name(overlays_dir: Path, override: str | None):
    """-> (nome, aviso|None). Manifesto AUSENTE = usa o default `pool` em silencio (cidade sem manifesto); manifesto
    ILEGIVEL = usa o default mas o aviso aparece (nao da pra saber qual era o base — nao finja que sabia)."""
    if override:
        return override, None
    state, man, err = read_json_object(overlays_dir / "pool-roles.json")
    if state == "ok" and isinstance(man.get("base_overlay"), str) and man["base_overlay"]:
        return man["base_overlay"], None
    if state == "unreadable":
        return DEFAULT_BASE_OVERLAY, f"manifesto ilegivel ({err}) — assumi o overlay base '{DEFAULT_BASE_OVERLAY}'"
    return DEFAULT_BASE_OVERLAY, None


def role_deltas(overlays: dict, base: str) -> dict:
    """{overlay: folhas que ele tem e o base NAO tem} — so os nao vazios. E o que 'altera' um arquivo compartilhado."""
    b = overlays[base]
    return {n: (lv - b) for n, lv in overlays.items() if n != base and (lv - b)}


# ----------------------------------------------------------------------------- 1. artefatos vivos
def check_artifacts(city: Path, deltas: dict):
    """Le OS DOIS arquivos. -> (findings, unknowns, states)."""
    findings, unknowns, states = [], [], {}
    for rel in ARTIFACT_RELS:
        state, obj, err = read_json_object(city / rel)
        states[rel] = state
        if state == "unreadable":
            unknowns.append({"kind": "artifact-unreadable", "file": rel, "detail": err})
            continue
        if state == "absent":
            continue
        lv = leaves(obj)
        hit_by = {name: (lv & dl) for name, dl in deltas.items() if lv & dl}
        if hit_by:
            # Os overlays por papel compartilham muitas folhas (mesmo claudeMdExcludes, mesma lista de skills off), entao
            # "quem tem alguma folha aqui" aponta todo mundo. A fonte provavel e o overlay cujo DELTA esta mais completo
            # no arquivo (cobertura); empate fica empatado (ex.: wa-worker e ps-worker herdam a mesma lista).
            cover = {n: len(h) / len(deltas[n]) for n, h in hit_by.items()}
            top = max(cover.values())
            union = set().union(*hit_by.values())
            findings.append({
                "kind": "artifact-contaminated",
                "file": rel,
                "sources": sorted(n for n, c in cover.items() if c == top),
                "coverage": {n: round(c, 2) for n, c in sorted(cover.items())},
                "n_leaves": len(union),
                "sample": [fmt_leaf(l) for l in sorted(union)[:SAMPLE_LEAVES]],
                "leaves": [fmt_leaf(l) for l in sorted(union)],
            })
    return findings, unknowns, states


# ----------------------------------------------------------------------------- 2. topologia (a causa)
def resolve_workdir(a: dict, city: Path):
    """Chave de identidade do work_dir efetivo de um agente. 'instance' = template com {{...}} (um dir por instancia)."""
    wd = (a.get("work_dir") or "").strip()
    qname = (a.get("dir") + "/" if a.get("dir") else "") + str(a.get("name"))
    if not wd:
        if a.get("dir"):
            return ("rig-root", a["dir"])
        return ("city-root",)
    if "{{" in wd:
        return ("instance", qname)
    p = Path(wd)
    p = p if p.is_absolute() else city / p
    try:
        rp = p.resolve()
    except OSError:
        rp = Path(os.path.normpath(p))
    try:
        if rp == city.resolve():
            return ("city-root",)
    except OSError:
        pass
    return ("path", str(rp))


def overlay_leaves_for(a: dict, city: Path, overlays: dict):
    """-> (folhas|None, aviso|None, erro|None). Sem overlay_dir: (None, None, None). Ausente no disco: aviso (no-op
    silencioso no engine, nao vaza). ILEGIVEL: erro — nao da pra saber o que esse agente grava."""
    od = (a.get("overlay_dir") or "").strip()
    if not od:
        return None, None, None
    name = Path(od).name
    if name in overlays:
        return overlays[name], None, None
    p = Path(od)
    p = p if p.is_absolute() else city / p
    state, obj, err = read_json_object(p / ".claude" / "settings.json")
    if state == "ok":
        return leaves(obj), None, None
    if state == "absent":
        return None, f"overlay_dir '{od}' nao existe em disco (no-op silencioso no engine: sessao sem overlay)", None
    return None, None, err


def check_topology(city: Path, config: dict, overlays: dict, base: str):
    """-> (findings, warnings, unknowns, root_resident). root_resident lista o que foi EXAMINADO na raiz: um 'limpo'
    que nao mostra o que olhou nao se distingue de um guard cego."""
    findings, warnings, unknowns = [], [], []
    base_lv = overlays[base]
    groups: dict = {}
    for a in config.get("agent", []) or []:
        lv, warn, err = overlay_leaves_for(a, city, overlays)
        qname = (a.get("dir") + "/" if a.get("dir") else "") + str(a.get("name"))
        if warn:
            warnings.append(f"{qname}: {warn}")
        if err:
            unknowns.append({"kind": "overlay-unreadable", "detail": f"{qname}: {err}"})
        if lv is None:
            continue
        key = resolve_workdir(a, city)
        groups.setdefault(key, []).append({
            "agent": qname, "overlay": Path(a["overlay_dir"]).name, "leaves": lv,
            "suspended": bool(a.get("suspended")), "delta": lv - base_lv,
        })
    root_resident = sorted(f'{m["agent"]}({m["overlay"]})' for m in groups.get(("city-root",), []))
    for key, members in sorted(groups.items(), key=lambda kv: str(kv[0])):
        if key == ("city-root",):
            for m in members:
                if m["delta"]:
                    findings.append({
                        "kind": "root-resident-role-overlay",
                        "agent": m["agent"], "overlay": m["overlay"], "suspended": m["suspended"],
                        "n_leaves": len(m["delta"]),
                        "sample": [fmt_leaf(l) for l in sorted(m["delta"])[:SAMPLE_LEAVES]],
                    })
        elif key[0] in ("path", "rig-root") and len(members) > 1:
            distinct = {frozenset(m["leaves"]) for m in members}
            if len(distinct) > 1:
                findings.append({
                    "kind": "shared-workdir-divergent-overlays",
                    "workdir": key[1],
                    "agents": [f'{m["agent"]}({m["overlay"]})' for m in members],
                })
    return findings, warnings, unknowns, root_resident


def load_config(city: Path, config_toml: str | None, timeout_s: float):
    """-> (config|None, erro|None). `gc config show` sai em TOML; falha/timeout/parse => erro (nunca 'sem agentes')."""
    if config_toml:
        src = f"--config-toml {config_toml}"
        try:
            text = Path(config_toml).read_text(encoding="utf-8")
        except OSError as e:
            return None, f"{src}: {e}"
    else:
        gc = os.environ.get("GC_BIN", "gc")
        src = f"`{gc} config show`"
        try:
            r = subprocess.run([gc, "--city", str(city), "config", "show"], capture_output=True, text=True, timeout=timeout_s)
        except (OSError, subprocess.TimeoutExpired) as e:
            return None, f"{src} nao rodou: {e}"
        if r.returncode != 0:
            return None, f"{src} rc={r.returncode}: {r.stderr.strip()[:300]}"
        text = r.stdout
    try:
        cfg = tomllib.loads(text)
    except tomllib.TOMLDecodeError as e:
        return None, f"saida de {src} nao e TOML valido: {e}"
    if not cfg.get("agent"):
        return None, f"{src} nao listou nenhum agente (config vazia != cidade sem overlays)"
    return cfg, None


# ----------------------------------------------------------------------------- orquestracao
def run_check(city: Path, overlays_dir: Path, base_override, config_toml, gc_timeout_s: float) -> dict:
    result = {"city": str(city), "findings": [], "unknowns": [], "warnings": [], "artifacts": {}, "base_overlay": None,
              "roles_with_delta": [], "root_resident": None}
    overlays, errs = load_overlays(overlays_dir)
    if errs:
        result["unknowns"] += [{"kind": "overlays-unreadable", "detail": e} for e in errs]
    base, base_warn = base_overlay_name(overlays_dir, base_override)
    if base_warn:
        result["warnings"].append(base_warn)
    result["base_overlay"] = base
    if base not in overlays:
        result["unknowns"].append({"kind": "base-overlay-missing", "detail": f"overlay base '{base}' nao encontrado em {overlays_dir} — sem base nao ha delta a procurar"})
        result["rc"] = RC_UNKNOWN
        return result
    deltas = role_deltas(overlays, base)
    result["roles_with_delta"] = sorted(deltas)
    if not deltas:
        result["unknowns"].append({"kind": "no-role-deltas", "detail": "nenhum overlay por papel difere do base — nada a procurar (suspeito: diretorio errado?)"})
    f, u, states = check_artifacts(city, deltas)
    result["findings"] += f
    result["unknowns"] += u
    result["artifacts"] = states
    if all(s == "absent" for s in states.values()):
        result["unknowns"].append({"kind": "artifacts-absent", "detail": f"nenhum dos dois arquivos existe em {city} — cidade errada?"})
    cfg, cerr = load_config(city, config_toml, gc_timeout_s)
    if cerr:
        result["unknowns"].append({"kind": "config-unavailable", "detail": cerr})
    else:
        tf, tw, tu, root_res = check_topology(city, cfg, overlays, base)
        result["findings"] += tf
        result["warnings"] += tw
        result["unknowns"] += tu
        result["root_resident"] = root_res
    result["rc"] = RC_LEAK if result["findings"] else (RC_UNKNOWN if result["unknowns"] else RC_OK)
    return result


REMEDIATION = (
    "COMO LIMPAR (a guarda NAO escreve nada): o merge de overlay so ADICIONA chave — reverter overlay_dir nao desfaz. "
    "1) remova as chaves listadas de <cidade>/.claude/settings.json (fonte do .gc/settings.json) e deixe a raiz == overlay "
    "`pool` base; 2) remova as mesmas chaves de <cidade>/.gc/settings.json; 3) confira com este guard (rc 0). Sessoes ja "
    "vivas subiram com a config vazada — reinicio gradual. Cause: agente com overlay de papel rodando na raiz "
    "(ver findings 'root-resident-role-overlay') — de a ele work_dir proprio antes de religar o overlay (ga-swnkfm)."
)


def render(res: dict) -> str:
    L = ["═══ overlay-root-leak-guard ═══", f"  cidade: {res['city']}   overlay base: {res['base_overlay']}",
         f"  overlays por papel com delta: {', '.join(res['roles_with_delta']) or '-'}",
         f"  artefatos lidos: " + ", ".join(f"{k}={v}" for k, v in res["artifacts"].items()),
         "  agentes na raiz com overlay (examinados): " + (", ".join(res["root_resident"]) if res["root_resident"] else ("nenhum" if res["root_resident"] == [] else "? (config indisponivel)"))]
    for f in res["findings"]:
        if f["kind"] == "artifact-contaminated":
            L.append(f"  ✗ CONTAMINADO {f['file']}: {f['n_leaves']} chave(s) de overlay de papel (fonte provavel: {', '.join(f['sources'])}) — ex.: " + "; ".join(f["sample"]))
        elif f["kind"] == "root-resident-role-overlay":
            L.append(f"  ✗ CAUSA {f['agent']} roda na RAIZ com overlay '{f['overlay']}' ({f['n_leaves']} chave(s) alem do base){' [suspenso]' if f['suspended'] else ''} — ex.: " + "; ".join(f["sample"]))
        elif f["kind"] == "shared-workdir-divergent-overlays":
            L.append(f"  ✗ CAUSA work_dir compartilhado {f['workdir']} com overlays divergentes: {', '.join(f['agents'])}")
    for u in res["unknowns"]:
        L.append(f"  ? NAO CONSEGUI SABER [{u['kind']}]: {u['detail']}")
    for w in res["warnings"]:
        L.append(f"  ~ aviso: {w}")
    L.append({RC_OK: "  ✓ limpo", RC_LEAK: "  ✗ VAZAMENTO", RC_UNKNOWN: "  ? DESCONHECIDO (nao e 'limpo')"}[res["rc"]])
    return "\n".join(L)


# ----------------------------------------------------------------------------- alarme (cooldown por fingerprint)
def fingerprints(res: dict) -> dict:
    """{chave-de-dedup: (assunto, corpo)}."""
    out: dict = {}
    for f in res["findings"]:
        if f["kind"] == "artifact-contaminated":
            k = f"artifact|{f['file']}|{','.join(f['sources'])}|{f['n_leaves']}"
            out[k] = (f"config:overlay-vazou -- {f['file']} da raiz contem chaves de overlay de papel ({', '.join(f['sources'])})",
                      f"{f['file']} tem {f['n_leaves']} chave(s) de overlay por papel (ex.: {'; '.join(f['sample'])}). "
                      f"Esse arquivo (ou o .gc/settings.json derivado dele) vale pra TODAS as sessoes da cidade. {REMEDIATION}")
        elif f["kind"] == "root-resident-role-overlay":
            k = f"cause|{f['agent']}|{f['overlay']}"
            out[k] = (f"config:overlay-na-raiz -- {f['agent']} roda na raiz com overlay '{f['overlay']}'",
                      f"{f['agent']} nao tem work_dir proprio (roda na raiz da cidade) e usa overlay_dir '{f['overlay']}', que traz "
                      f"{f['n_leaves']} chave(s) alem do base (ex.: {'; '.join(f['sample'])}). No primeiro spawn ele grava isso na raiz e no "
                      f".gc/settings.json de todas as sessoes. Volte pro overlay base ou de work_dir proprio ao agente (ga-swnkfm).")
        elif f["kind"] == "shared-workdir-divergent-overlays":
            k = f"shared|{f['workdir']}|{','.join(f['agents'])}"
            out[k] = (f"config:workdir-compartilhado -- overlays divergentes em {f['workdir']}",
                      f"Agentes {', '.join(f['agents'])} dividem o work_dir {f['workdir']} com overlays diferentes; o merge acumula e nunca remove (ga-swnkfm).")
    # dedup por KIND (um alarme por tipo de cegueira, sem tempestade), mas o corpo lista TODOS os detalhes do kind: antes so o ultimo aparecia e
    # dois arquivos/agentes ilegiveis do mesmo kind pareciam um so (gate ga-3d1wno r1).
    by_kind: dict = {}
    for u in res["unknowns"]:
        by_kind.setdefault(u["kind"], []).append(u["detail"])
    for kind, details in by_kind.items():
        k = f"unknown|{kind}"
        out[k] = (f"config:overlay-guard-cego -- nao consegui verificar ({kind})",
                  f"overlay-root-leak-guard nao conseguiu verificar se algum overlay por papel vazou pra raiz: {' | '.join(details)}. "
                  f"Isto e DESCONHECIDO, nao 'limpo' (ga-swnkfm).")
    return out


def alarm(res: dict, state_dir: Path, router: Path | None, escalate_after_s: int, city: Path) -> int:
    """Cooldown por fingerprint; entrega falha NAO grava (retry no proximo tick); chave que sumiu num tick COMPLETO (sem
    desconhecidos) e esquecida (recorrencia depois de limpo alarma na hora); num tick com desconhecido nada e esquecido.
    -> numero de entregas que falharam."""
    now = int(time.time())
    seen_file = state_dir / "overlay-root-leak-guard-seen.json"
    try:
        state_dir.mkdir(parents=True, exist_ok=True)
        seen = json.loads(seen_file.read_text()) if seen_file.exists() else {}
        if not isinstance(seen, dict):
            seen = {}
    except (OSError, ValueError):
        seen = {}
    fps = fingerprints(res)
    # Tick com DESCONHECIDO (ex.: `gc config show` falhou): o que nao apareceu nao esta "limpo", so nao foi visto. Esquecer aqui faria o achado de
    # topologia re-alarmar no tick seguinte sem respeitar o cooldown (config show intermitente; gate ga-3d1wno r1). So um tick sem desconhecido esquece.
    incomplete = bool(res["unknowns"])
    new_seen = {k: v for k, v in seen.items() if k in fps or incomplete}
    failed = 0
    for k, (subject, body) in fps.items():
        last = seen.get(k, 0)
        if isinstance(last, int) and last and now - last < escalate_after_s:
            continue
        if router and router.exists() and os.access(router, os.X_OK):
            cmd = [str(router), "-s", subject, "-m", body, "--topic", "infra"]
        else:
            cmd = [os.environ.get("GC_BIN", "gc"), "mail", "send", "mayor", "-s", subject, "-m", body]
        try:
            rc = subprocess.run(cmd, capture_output=True, timeout=120).returncode
        except (OSError, subprocess.TimeoutExpired):
            rc = 1
        if rc != 0:
            failed += 1
            print(f"overlay-root-leak-guard: ALARME NAO ENTREGUE (rc={rc}) key='{k}' — nao gravo como visto, tento no proximo tick", file=sys.stderr)
            continue
        new_seen[k] = now
    try:
        seen_file.write_text(json.dumps(new_seen))
    except OSError:
        pass
    return failed


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--city", default=os.environ.get("GC_CITY_PATH") or os.environ.get("GC_CITY"))
    ap.add_argument("--overlays-dir")
    ap.add_argument("--base-overlay")
    ap.add_argument("--config-toml", help="TOML do `gc config show` (teste); sem isto o guard roda `gc config show`")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--no-alarm", action="store_true")
    ap.add_argument("--no-lock", action="store_true", help="so selftest")
    ap.add_argument("--order", action="store_true",
                    help="modo `gc order`: o ALARME e o canal (como os outros guards) — sai 0 se o achado foi alarmado/deduplicado, "
                         "sai 2 so se a ENTREGA do alarme falhou (o order runner trata exit != 0 como run falho)")
    a = ap.parse_args(argv)
    if not a.city:
        # sem env (ex.: order sem GC_CITY_PATH): o script mora em <cidade>/packs/town-deltas/assets/scripts/
        guess = Path(__file__).resolve().parents[4]
        if (guess / "city.toml").is_file():
            a.city = str(guess)
    if not a.city or not Path(a.city).is_dir():
        print("ERRO: cidade nao encontrada — defina GC_CITY_PATH ou --city", file=sys.stderr)
        return RC_UNKNOWN
    city = Path(a.city).resolve()
    overlays_dir = Path(a.overlays_dir) if a.overlays_dir else city / "packs/town-deltas/assets/claude-overlays"

    lock_fh = None
    if not a.no_lock:
        lock_path = city / ".gc/runtime/overlay-root-leak-guard.lock"
        try:
            lock_path.parent.mkdir(parents=True, exist_ok=True)
            lock_fh = open(lock_path, "w")
            fcntl.flock(lock_fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            if a.order:
                # o order roda de 10 em 10 min: a instancia que segura o lock cobre esta rodada, sair 0 e certo.
                print(f"overlay-root-leak-guard: outra instancia ja rodando (lock {lock_path}) — saindo")
                return RC_OK
            # CLI manual (o runbook de docs/pool-preamble-per-role.md le `rc=$?` sozinho): 0 aqui seria "limpo" sem check nenhum rodado — o mesmo
            # erro-vira-vazio que este guard existe pra evitar (gate ga-3d1wno r1). rc 2 = nao rodei, repita.
            print(f"overlay-root-leak-guard: outra instancia ja rodando (lock {lock_path}) — NAO rodei (rc 2 = desconhecido, nao 'limpo'); repita", file=sys.stderr)
            return RC_UNKNOWN
        except OSError as e:
            # nao rodar sem garantia de instancia unica e correto (ga-y0g5x), mas sair 0 seria um guard CEGO que parece saudavel
            print(f"overlay-root-leak-guard: nao consegui abrir o lock ({e}) — NAO rodei (rc 2 = desconhecido, nao 'limpo')", file=sys.stderr)
            return RC_UNKNOWN

    res = run_check(city, overlays_dir, a.base_overlay, a.config_toml, float(os.environ.get("OVLG_GC_TIMEOUT_S", "120")))
    if a.json:
        print(json.dumps({k: v for k, v in res.items() if k != "findings"} | {"findings": [{k: v for k, v in f.items() if k != "leaves"} for f in res["findings"]]}, ensure_ascii=False))
    else:
        print(render(res))
    rc = res["rc"]
    failed = 0
    if not a.no_alarm and rc != RC_OK:
        state_dir = Path(os.environ.get("OVLG_STATE_DIR") or city / ".gc/runtime/packs/maintenance")
        router = Path(os.environ["OVLG_ROUTER"]) if os.environ.get("OVLG_ROUTER") else city / "packs/town-deltas/assets/escalation-router.sh"
        failed = alarm(res, state_dir, router, int(os.environ.get("OVLG_ESCALATE_AFTER_S", "14400")), city)
    elif not a.no_alarm and rc == RC_OK:
        # limpo: esquece tudo que estava visto, pra uma recorrencia alarmar na hora (nao esperar o cooldown).
        state_dir = Path(os.environ.get("OVLG_STATE_DIR") or city / ".gc/runtime/packs/maintenance")
        try:
            (state_dir / "overlay-root-leak-guard-seen.json").unlink(missing_ok=True)
        except OSError:
            pass
    if lock_fh:
        lock_fh.close()
    if a.order:
        return RC_UNKNOWN if failed else RC_OK
    return rc


def entry(argv=None) -> int:
    """main() com a rede de seguranca que importa: um crash do Python sai com rc 1 — o MESMO codigo de 'vazamento'.
    Erro nao pode se passar por achado (nem por limpo): qualquer excecao vira rc 2 (desconhecido) com o traceback."""
    try:
        return main(argv)
    except SystemExit:
        raise
    except BaseException:
        import traceback
        traceback.print_exc()
        print("overlay-root-leak-guard: ERRO INTERNO — nao consegui verificar (rc 2 = desconhecido, NAO e 'limpo' nem 'vazou')", file=sys.stderr)
        return RC_UNKNOWN


if __name__ == "__main__":
    sys.exit(entry())
