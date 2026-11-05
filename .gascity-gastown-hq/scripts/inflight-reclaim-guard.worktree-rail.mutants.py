#!/usr/bin/env python3
"""inflight-reclaim-guard.worktree-rail.mutants.py — controle negativo dos checks WT-* do inflight-reclaim-guard (ga-s90p58a, o trilho de progresso do worktree).

Contents
  O que faz · Como roda · Saída

O QUE FAZ: cada mutante troca UM trecho do guard numa CÓPIA (o original nunca é tocado) e roda o `--selftest` do guard contra a cópia. Só conta como MORTO se os checks WT-* que prendem aquela guarda
  reprovarem (ou, no mutante que tira a rede de segurança "o trilho nunca levanta", se o selftest quebrar com Traceback). Reprovar por OUTRO motivo (cópia que nem abre, SyntaxError) NÃO mata. Antes dos
  mutantes roda um CONTROLE: a cópia sem mutação tem de passar, senão "todos mortos" seria o harness quebrado reprovando tudo. O trecho trocado tem de aparecer EXATAMENTE uma vez no guard (senão FATAL).
COMO RODA: python3 -I scripts/inflight-reclaim-guard.worktree-rail.mutants.py   (cada filho roda o --selftest inteiro, que monta repos de git de verdade: 3 cópias por vez, 512 MB por arquivo e 120 s)
  WT_RAIL_MUTANTS_GUARD=<arquivo>   aponta para outro guard (o selftest usa isto para provar o FATAL). Cada filho roda com GC_SELFTEST=1 e GC_LEDGER_DIR descartável.
SAÍDA: uma linha por mutante (morto / SOBREVIVEU) e `MUTANTES: <mortos>/<total> mortos`; exit 0 só com todos mortos; exit 2 (FATAL) para guard ausente, mutante velho ou controle vermelho.
"""
import concurrent.futures
import os
import resource
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GUARD = os.environ.get("WT_RAIL_MUTANTS_GUARD") or os.path.join(HERE, "inflight-reclaim-guard.py")
SIBLINGS = ("bead_state.py", "gc_ledger.py", "park_labels.py")   # o guard importa os dois primeiros no nível do módulo; o bead_state importa o park_labels
WORKERS, CHILD_TIMEOUT_SECS, CHILD_FSIZE_BYTES, MIN_WT_PASS = 3, 120, 512 * 1024 * 1024, 70   # MIN_WT_PASS: trilho que sumiu do selftest não vira "todos mortos"

_STATUS = '    for entry in _wt_git(wt_path, "status", "--porcelain=v1", "-z", "--no-renames", "--untracked-files=all")[1].split(b"\\0"):\n'
_MATCH = ('                if not (_branch_segment_matches_bead(os.path.basename(wt["path"]), bead_id)\n'
          '                        or _branch_segment_matches_bead(wt["branch"].rsplit("/", 1)[-1], bead_id)):\n')
_RECENT_IF = "                if newest is not None and now - newest < window:\n"
_LIST_ERR = '            except _WtUnreadable as exc:\n                why.append(str(exc))\n                continue\n            for wt in worktrees:\n'
_FUTURE = "    if any(t - now > WORKTREE_FUTURE_SKEW_SECS for t in stamps):\n"
_HEAD_RC = '        if _wt_git(wt_path, "rev-parse", "--verify", "-q", "HEAD", ok_rcs=(0, 1))[0] != 1:\n            raise\n'
_ALERT_IF = "        if now - since >= WORKTREE_DOUBT_ALERT_SECS and now - bead_state.get(\"wt_doubt_alerted_at\", 0) >= WORKTREE_DOUBT_ALERT_SECS:\n"
_RUN_CYCLE_CALL = "        has_recent_branch = has_recent_progress(bead_id, bead_state, now, consult_progress_rails)\n"
_WARN = '    print(f"[INFLIGHT-RECLAIM] worktree-rail: bead={bead_id} não consegui ler: {_WT_RAIL_WHY} — tratando como progresso-pode-existir (fail-safe: NÃO reclama)", flush=True)\n'

# (nome, trecho antigo, trecho novo, checks WT-* que TÊM de reprovar | ["Traceback"] quando a rede de segurança tirada protege contra uma exceção)
MUTANTS = [
    # --- a janela e o veredito ---
    ("janela-inclusiva", _RECENT_IF, "                if newest is not None and now - newest <= window:\n", ["WT-2b ("]),
    ("janela-padrao-errada", "    window = RECLAIM_TTL if window_seconds is None else window_seconds\n    why = []\n", "    window = RECLAIM_TTL\n    why = []\n", ["WT-6b:"]),
    ("nunca-recent", _RECENT_IF, "                if False:\n", ["WT-1 (", "WT-4a:", "WT-E1 ("]),
    ("sem-sinal-vira-recent", _RECENT_IF, "                if newest is None or now - newest < window:\n", ["WT-9a:"]),
    ("min-em-vez-de-max", "    return max(stamps) if stamps else None\n", "    return min(stamps) if stamps else None\n", ["WT-4a:"]),
    # --- quais worktrees são da bead ---
    ("casa-por-prefixo-cru", _MATCH, _MATCH.replace('_branch_segment_matches_bead(os.path.basename(wt["path"]), bead_id)', 'os.path.basename(wt["path"]).startswith(bead_id)', 1), ["WT-5a:"]),
    ("casa-so-por-diretorio", _MATCH, _MATCH.replace('_branch_segment_matches_bead(wt["branch"].rsplit("/", 1)[-1], bead_id)', "False", 1), ["WT-5e:"]),
    ("casa-so-por-branch", _MATCH, _MATCH.replace('_branch_segment_matches_bead(os.path.basename(wt["path"]), bead_id)', "False", 1), ["WT-5b:", "WT-5c:", "WT-5d:"]),
    ("branch-nao-lido", '            found[-1]["branch"] = line[len("branch refs/heads/"):]\n', '            found[-1]["branch"] = ""\n', ["WT-5e:"]),
    # --- o que conta como alteração no working tree ---
    ("status-untracked-normal", _STATUS, _STATUS.replace("--untracked-files=all", "--untracked-files=normal"), ["WT-4f:"]),
    ("status-com-ignorados", _STATUS, _STATUS.replace('"--untracked-files=all"', '"--untracked-files=all", "--ignored"'), ["WT-9c:"]),
    ("status-com-renames", _STATUS, _STATUS.replace('"--no-renames", ', ""), ["WT-10b:"]),
    ("caminho-com-deslocamento-errado", "        probe = os.path.join(wt_path, os.fsdecode(entry[3:]))\n", "        probe = os.path.join(wt_path, os.fsdecode(entry[2:]))\n", ["WT-4d:"]),
    ("apagado-sem-rastro", "                probe = os.path.dirname(probe)\n", "                break\n", ["WT-4c:"]),
    # --- carimbo no futuro ---
    ("futuro-vale-como-recente", _FUTURE, "    if False:\n", ["WT-8h:", "WT-8i:"]),
    ("margem-de-relogio-zero", _FUTURE, "    if any(t - now > 0 for t in stamps):\n", ["WT-4i:"]),
    # --- não consegui ler: nunca vira quieto ---
    ("rc-do-git-ignorado", "    if r.returncode not in ok_rcs:\n", "    if False:\n", ["WT-8d:"]),
    ("timeout-vira-saida-vazia", '        raise _WtUnreadable(f"git {verb} estourou {WORKTREE_GIT_TIMEOUT}s em {path}")\n', '        return 0, b""\n', ["WT-8d2:"]),
    ("git-que-nao-roda-vira-saida-vazia", '        raise _WtUnreadable(f"git {verb} não rodou em {path}: {exc}")\n', '        return 0, b""\n', ["WT-8d3:"]),
    ("lixo-do-log-ignorado", '        except ValueError:\n            raise _WtUnreadable(f"git log devolveu {out[:40]!r} em {wt_path}, não uma data")\n', "        except ValueError:\n            pass\n", ["WT-8f:"]),
    ("head-com-erro-vira-sem-commit", _HEAD_RC, "        if False:\n            raise\n", ["WT-8e:", "WT-8f:"]),
    ("head-sem-commit-vira-erro", _HEAD_RC, "        raise\n", ["WT-9a:", "WT-9b:"]),
    ("worktree-sumido-vira-quieto", '    if not os.path.isdir(wt_path):\n        raise _WtUnreadable(', '    if False:\n        raise _WtUnreadable(', ["WT-8g:"]),
    ("lstat-negado-engolido", '            except OSError as exc:\n                raise _WtUnreadable(f"não li o mtime de {probe}: {exc}")\n', "            except OSError as exc:\n                break\n", ["WT-8j:"]),
    ("sumiu-no-meio-engolido", '                if probe == wt_path:\n                    raise _WtUnreadable(', "                if probe == wt_path:\n                    break\n                    raise _WtUnreadable(", ["WT-8j2:"]),
    ("repo-sumido-vira-quieto", '            if not os.path.isdir(repo):\n                why.append(f"o repo da rig {repo} não existe")\n                continue\n', "            if not os.path.isdir(repo):\n                continue\n", ["WT-8o:"]),
    ("rig-sem-git-vira-duvida", '            if not os.path.exists(os.path.join(repo, ".git")):\n                continue\n', "            if False:\n                continue\n", ["WT-7b:"]),
    ("listagem-vazia-aceita", '    if not found:\n        raise _WtUnreadable(', '    if False:\n        raise _WtUnreadable(', ["WT-8p:"]),
    ("erro-de-listagem-calado", _LIST_ERR, _LIST_ERR.replace("                why.append(str(exc))\n", ""), ["WT-8a:", "WT-8k:"]),
    ("erro-de-atividade-calado", "                except _WtUnreadable as exc:\n                    why.append(str(exc))\n                    continue\n                if newest",
     "                except _WtUnreadable as exc:\n                    continue\n                if newest", ["WT-8d:", "WT-8g:"]),
    ("duvida-vence-progresso", _LIST_ERR, _LIST_ERR.replace("                continue\n", "                return WT_UNREADABLE\n"), ["WT-8l:"]),
    ("excecao-inesperada-vaza", "    except Exception as exc:   # o trilho nunca levanta", "    except ZeroDivisionError as exc:   # o trilho nunca levanta", ["Traceback"]),
    ("unreadable-vira-quieto", "    return WT_UNREADABLE\n\n\ndef worktree_rail_holds", "    return WT_QUIET\n\n\ndef worktree_rail_holds", ["WT-8a:", "WT-8d:", "WT-E3:"]),
    ("aviso-mudo", _WARN, "    pass\n", ["WT-8a:"]),
    ("unreadable-nao-conta", '    WT_RAIL_COUNTS["unreadable"] += 1\n', "    pass\n", ["WT-8a:", "WT-E3:"]),
    ("recent-nao-conta", '                    WT_RAIL_COUNTS["recent"] += 1\n', "                    pass\n", ["WT-1 (", "WT-E1 ("]),
    # --- a lista de repos vem da config ---
    ("rigs-falhou-vira-quieto", "    if stores is None:\n        raise _WtUnreadable(", "    if stores is None:\n        return []\n        raise _WtUnreadable(", ["WT-12a:"]),
    ("repos-do-REPOS-fixo", "    stores = _list_rig_stores()\n    if stores is None:\n", "    stores = [(p, p) for p in REPOS]\n    if stores is None:\n", ["WT-12b:"]),
    # --- o trilho só lê ---
    ("sem-no-optional-locks", '"--no-optional-locks", ', "", ["WT-10:", "WT-10b:"]),
    ("fsmonitor-ligado", '"-c", "core.fsmonitor=false", ', "", ["WT-10b:"]),
    # --- o relógio de dúvida e o alerta ---
    ("duvida-nunca-zera", '    if verdict != WT_UNREADABLE:\n        bead_state.pop("wt_doubt_since", None)\n', "    if verdict != WT_UNREADABLE:\n        pass\n", ["WT-14i:"]),
    ("relogio-sempre-em-duvida", "    if verdict != WT_UNREADABLE:\n        bead_state.pop(", "    if False:\n        bead_state.pop(", ["WT-14d:"]),
    ("alerta-sem-horizonte", _ALERT_IF, _ALERT_IF.replace("now - since >= WORKTREE_DOUBT_ALERT_SECS and", "True and", 1), ["WT-14c:"]),
    ("alerta-na-borda-exclusiva", _ALERT_IF, _ALERT_IF.replace("now - since >=", "now - since >", 1), ["WT-14e:"]),
    ("alerta-a-cada-varredura", _ALERT_IF, _ALERT_IF.replace(" and now - bead_state.get(\"wt_doubt_alerted_at\", 0) >= WORKTREE_DOUBT_ALERT_SECS", "", 1), ["WT-14f:"]),
    ("alerta-nunca-repete", '            bead_state["wt_doubt_alerted_at"] = now\n', '            bead_state["wt_doubt_alerted_at"] = 10 ** 12\n', ["WT-14g:"]),
    ("quieto-segura", "    return verdict != WT_QUIET\n", "    return True\n", ["WT-14b:"]),
    ("duvida-nao-segura", "    return verdict != WT_QUIET\n", "    return verdict == WT_RECENT\n", ["WT-14c:"]),
    ("trilho-com-o-now-do-ciclo", "    verdict = get_worktree_progress(bead_id)\n", "    verdict = get_worktree_progress(bead_id, now=now)\n", ["WT-E7:"]),
    # --- a fiação (has_recent_progress, run_cycle, resumo do ciclo) ---
    ("consulta-sempre", "    if consult_rails and not get_branch_recent(bead_id):\n", "    if True and not get_branch_recent(bead_id):\n", ["WT-15a:"]),
    ("branch-nao-curto-circuita", "    if consult_rails and not get_branch_recent(bead_id):\n", "    if consult_rails and not (get_branch_recent(bead_id) and False):\n", ["WT-15b:"]),
    ("so-trilho-de-worktree", "    if consult_rails and not get_branch_recent(bead_id):\n", "    if consult_rails and not False:\n", ["WT-15b:"]),
    ("so-trilho-de-branch", "        return worktree_rail_holds(bead_id, bead_state, now)\n", "        return False\n", ["WT-15c:", "WT-15e:", "WT-E1 ("]),
    ("duvida-nao-zera-sem-consulta", '    bead_state.pop("wt_doubt_since", None)\n    return bool(consult_rails)\n', "    return bool(consult_rails)\n", ["WT-15f:"]),
    ("run-cycle-sem-trilho-do-worktree", _RUN_CYCLE_CALL, "        has_recent_branch = get_branch_recent(bead_id) if consult_progress_rails else False\n", ["WT-E1 (", "WT-16a ("]),
    ("run-cycle-consulta-sempre", _RUN_CYCLE_CALL, "        has_recent_branch = has_recent_progress(bead_id, bead_state, now, True)\n", ["WT-E6:"]),
    ("run-cycle-nao-zera-contagens", "    WT_RAIL_COUNTS.update(recent=0, unreadable=0)   # ga-s90p58a: as contagens", "    pass   # ga-s90p58a: as contagens", ["WT-E5:", "WT-16b ("]),
    ("main-sem-resumo-do-trilho", "            print(_cycle_summary(inflight_count, stranded_count), flush=True)\n",
     '            print(f"[INFLIGHT-RECLAIM] cycle: inflight={inflight_count} stranded={stranded_count}", flush=True)\n', ["WT-16c ("]),
    ("resumo-sem-contagem", "worktree_unreadable={WT_RAIL_COUNTS['unreadable']}", "worktree_unreadable=0", ["WT-17:"]),
]


def fatal(msg):
    print("FATAL: " + msg)
    sys.exit(2)


def run_selftest(guard_text, label):
    """Roda o --selftest de uma cópia com `guard_text`; devolve (rc, saída). Falhou em rodar/estourou prazo → (None, motivo): nunca vira 'passou'."""
    tmp = tempfile.mkdtemp(prefix="irg-wtrail-mut-")
    try:
        with open(os.path.join(tmp, "inflight-reclaim-guard.py"), "w", encoding="utf-8") as f:
            f.write(guard_text)
        for sib in SIBLINGS:
            src = os.path.join(os.path.dirname(os.path.abspath(GUARD)), sib)
            if not os.path.isfile(src):
                return None, "irmão ausente ao lado do guard: " + sib
            shutil.copy(src, os.path.join(tmp, sib))
        env = dict(os.environ, GC_SELFTEST="1", GC_LEDGER_DIR=os.path.join(tmp, "ledger"))
        os.makedirs(env["GC_LEDGER_DIR"], exist_ok=True)
        try:
            r = subprocess.run([sys.executable, os.path.join(tmp, "inflight-reclaim-guard.py"), "--selftest"], cwd=tmp, env=env, capture_output=True, text=True, timeout=CHILD_TIMEOUT_SECS,
                               preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_FSIZE, (CHILD_FSIZE_BYTES, CHILD_FSIZE_BYTES)))
        except subprocess.TimeoutExpired:
            return None, "estourou %ds (%s)" % (CHILD_TIMEOUT_SECS, label)
        except Exception as e:   # noqa: BLE001 — não conseguir rodar não é "mutante morto"
            return None, "não rodou (%s): %r" % (label, e)
        return r.returncode, r.stdout + r.stderr
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def judge(rc, out, expect):
    """True sse o mutante morreu PELO MOTIVO esperado."""
    if rc is None or rc == 0:
        return False
    return "Traceback" in out if expect == ["Traceback"] else all(("FAIL: " + check_id) in out for check_id in expect)


def main():
    if not os.path.isfile(GUARD):
        fatal("guard ausente: %s" % GUARD)
    with open(GUARD, encoding="utf-8") as f:
        text = f.read()
    for name, old, new, _expect in MUTANTS:
        if text.count(old) != 1:
            fatal("mutante '%s' velho: o trecho aparece %d vez(es) no guard, tem de ser exatamente 1" % (name, text.count(old)))
        if old == new:
            fatal("mutante '%s' não muda nada" % name)
    rc0, out0 = run_selftest(text, "controle")
    wt_pass = sum(1 for line in (out0 or "").splitlines() if line.startswith("PASS: WT-"))
    if rc0 != 0 or wt_pass < MIN_WT_PASS or "FAIL:" in (out0 or ""):
        fatal("controle vermelho (cópia SEM mutação: rc=%r, checks WT passando=%d, mínimo %d): %s" % (rc0, wt_pass, MIN_WT_PASS, (out0 or "")[-300:].replace("\n", " | ")))
    print("controle: a cópia sem mutação passa (%d checks WT-*)" % wt_pass)

    def one(m):
        name, old, new, expect = m
        rc, out = run_selftest(text.replace(old, new, 1), name)
        return name, expect, judge(rc, out, expect), rc, out

    killed = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as pool:
        for name, expect, dead, rc, out in pool.map(one, MUTANTS):
            killed += dead
            fails = [l[6:36] for l in (out or "").splitlines() if l.startswith("FAIL: ")]
            print("  morto      %s  (reprovou: %s)" % (name, ", ".join(expect)) if dead else
                  "  SOBREVIVEU %s  (esperava reprovar %s; rc=%r; reprovou: %s)" % (name, expect, rc, fails or (out or "")[-160:].replace("\n", " | ")))
    print("MUTANTES: %d/%d mortos" % (killed, len(MUTANTS)))
    sys.exit(0 if killed == len(MUTANTS) else 1)


if __name__ == "__main__":
    main()
