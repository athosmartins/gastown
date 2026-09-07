#!/usr/bin/env python3
"""Testes de generate_park_labels.py (ga-r150x9, Phase 1).

Duas coisas precisam ser verdade pra este gerador ser seguro:

1. TRAVA DE SEGURANÇA (o requisito mais importante do bead): o conteúdo
   gerado a partir de park_labels.json tem que reproduzir BYTE A BYTE
   park_labels.py e park_labels.sh como estão commitados hoje. Se este teste
   falhar, o gerador mudou comportamento sem ninguém perceber -- exatamente a
   classe de bug silencioso que este bead existe pra matar.
2. CRITÉRIO FALSIFICÁVEL: adicionar um label novo à fonte (park_labels.json)
   e ver os fragmentos de TODOS os formatos (python, shell, json/jq) mudarem
   sozinhos, sem nenhuma edição manual em park_labels.py ou park_labels.sh.

    python3 -m pytest scripts/test_generate_park_labels.py -q
"""
import copy
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import generate_park_labels as gen  # noqa: E402


def test_check_mode_passes_against_committed_files():
    """The safety lock, automated: generate_park_labels.py --check must exit
    0 against the files as actually committed in this repo. This is the
    'diff-vazio' proof the bead's acceptance criteria requires, made
    re-runnable instead of a one-time manual check."""
    data = gen.load_source()
    py_out = gen.render_py(data)
    sh_out = gen.render_sh(data)

    with open(gen.PY_TARGET, "r", encoding="utf-8") as f:
        py_committed = f.read()
    with open(gen.SH_TARGET, "r", encoding="utf-8") as f:
        sh_committed = f.read()

    assert py_out == py_committed, (
        "generated park_labels.py differs from the committed file -- run "
        "`python3 scripts/generate_park_labels.py --write` and inspect the "
        "diff before committing; see " + repr(gen._diff("park_labels.py", py_committed, py_out))
    )
    assert sh_out == sh_committed, (
        "generated park_labels.sh differs from the committed file -- run "
        "`python3 scripts/generate_park_labels.py --write` and inspect the "
        "diff before committing; see " + repr(gen._diff("park_labels.sh", sh_committed, sh_out))
    )


def test_rendering_is_deterministic():
    """Same source, rendered twice, must produce identical bytes -- a
    generator whose output depends on dict/set iteration order would make
    the diff-empty check flaky."""
    data = gen.load_source()
    assert gen.render_py(data) == gen.render_py(data)
    assert gen.render_sh(data) == gen.render_sh(data)


def test_adding_a_label_propagates_to_python_and_shell_without_manual_edits():
    """THE falsifiable criterion from the bead's acceptance criteria: add one
    label to the source and see py + sh fragments change themselves."""
    data = copy.deepcopy(gen.load_source())
    new_label = "story:test-canary-ga-r150x9"

    for group in data["groups"]:
        if group["id"] == "not_ready":
            group["members"].append({"label": new_label})
            break
    else:
        raise AssertionError("fixture drift: 'not_ready' group not found in park_labels.json")

    py_out = gen.render_py(data)
    sh_out = gen.render_sh(data)

    assert f'"{new_label}"' in py_out, "new label did not reach the generated Python fragment"
    assert f'"{new_label}"' in sh_out, "new label did not reach the generated shell fragment"

    # Every OTHER label must still be present too -- this must be additive,
    # not a lossy re-render.
    baseline = gen.load_source()
    for group in baseline["groups"]:
        for member in group["members"]:
            quoted = json.dumps(member["label"])
            assert quoted in py_out, f"{member['label']} dropped from generated Python on unrelated add"
            assert quoted in sh_out, f"{member['label']} dropped from generated shell on unrelated add"


def test_json_source_is_the_jq_consumable_fragment():
    """park_labels.json doubles as the jq fragment (criterion 1's third
    format) -- any group's member labels must be reachable by a plain jq
    path, and in_park_labels must correctly partition PARK_LABELS'
    5-group union from the 2 excluded groups (gate_park, flowing_or_done)."""
    data = gen.load_source()
    all_labels = {m["label"] for g in data["groups"] for m in g["members"]}
    assert "gate:needs-human" in all_labels
    assert "pilot:no-auto-dispatch" in all_labels

    park_group_ids = {g["id"] for g in data["groups"] if g["in_park_labels"]}
    assert park_group_ids == {"needs_human", "manual_exec", "blocked_family", "not_ready", "pilot_held"}

    excluded_ids = {g["id"] for g in data["groups"] if not g["in_park_labels"]}
    assert excluded_ids == {"gate_park", "flowing_or_done"}


def test_generated_python_module_is_valid_and_behaves_correctly():
    """Belt-and-suspenders on top of the byte-identity check: load the
    freshly-generated Python text as a real module and exercise a couple of
    behaviors, so a future template edit that happens to stay byte-identical
    in some OTHER regard but breaks semantics (e.g. a typo'd operator) can't
    slip through unnoticed."""
    data = gen.load_source()
    py_out = gen.render_py(data)

    ns = {}
    exec(compile(py_out, "<generated park_labels.py>", "exec"), ns)  # noqa: S102

    assert ns["is_labeled"](["gate:needs-human:product"], ns["GATE_NEEDS_HUMAN_PREFIX"]) is True
    assert ns["is_labeled"](["pilot:held-until:1690000000"], ns["PILOT_HELD_LABEL"]) is True
    assert ns["is_labeled"](["totally-unrelated"], ns["PILOT_HELD_LABEL"]) is False
    assert "gate:needs-human" in ns["PARK_LABELS"]
    assert "gate:needs-fix" not in ns["PARK_LABELS"]  # GATE_PARK_LABELS excluded by design
    assert ns["is_reclaim_exhausted"](["pilot:reclaim-count:3"]) is True
    assert ns["is_reclaim_exhausted"](["pilot:reclaim-count:2"]) is False


if __name__ == "__main__":
    import pytest
    sys.exit(pytest.main([__file__, "-v"]))
