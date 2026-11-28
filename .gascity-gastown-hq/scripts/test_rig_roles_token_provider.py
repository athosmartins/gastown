#!/usr/bin/env python3
"""ga-af1ta5l — polecat/refinery/witness of every rig run on the 1-year token (provider claude-headless).

Athos 28/11 (ga-xy0916u.1): only the Mayor and the Remote Control crews keep the full login. A rig role with no
`provider` runs on the workspace default `claude` = the Mayor's own login, so each rig in city.toml must patch
its three roles to `claude-headless` (claude-lowprio.sh then points the session at the pool's token item).

Reads city.toml as written (the [[rigs.patches]] of each [[rigs]]), not the resolved config: the resolved
view needs the live city (.gc, packs), which a test run does not have.
"""
import os
import tomllib

CITY = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "city.toml"))
ROLES = ("polecat", "refinery", "witness")
PROVIDER = "claude-headless"


def _rigs():
    with open(CITY, "rb") as fh:
        return tomllib.load(fh)["rigs"]


def test_there_are_rigs_to_check():
    # A city.toml that lost its rigs would make every loop below pass on nothing.
    assert len(_rigs()) >= 5


def test_every_rig_pins_its_three_roles_to_the_token_provider():
    missing = []
    for rig in _rigs():
        pinned = {p["agent"]: p.get("provider") for p in rig.get("patches") or []}
        for role in ROLES:
            if pinned.get(role) != PROVIDER:
                missing.append(f'{rig["name"]}/{role}: provider={pinned.get(role)!r}')
    assert not missing, "rig roles still on the default login (the Mayor's): " + "; ".join(missing)


def test_wa_refinery_keeps_its_test_command_env():
    # The provider line was added to the existing ga-skuoh patch: it must not have dropped the env.
    wa = next(r for r in _rigs() if r["name"] == "whatsapp_automation")
    ref = next(p for p in wa["patches"] if p["agent"] == "refinery")
    assert ref["env"]["test_command"].endswith("-m pytest tests/ -q")
