"""Astra IT1 (2026-11-26) probe, ported: imports adapted to this package; outcome as the invariants require."""
from __future__ import annotations
import ast, subprocess
from pathlib import Path
import pytest
from omi_notes.pipeline import conversations
from . import test_speaker_policy as owner

@pytest.mark.parametrize("damage", [None, "sample"])
def test_base_unfiltered_hint_method_cannot_name_an_opted_out_person(tmp_path,monkeypatch,damage):
    root=Path(__file__).resolve().parents[2]  # this repository
    src=subprocess.check_output(["git","show","f066723:backend/src/omi_notes/pipeline/conversations.py"],cwd=root,text=True,timeout=10)
    tree=ast.parse(src)
    cls=next(n for n in tree.body if isinstance(n,ast.ClassDef) and n.name=="ConversationPipeline")
    method=next(n for n in cls.body if isinstance(n,ast.FunctionDef) and n.name=="possible_voice_names")
    scope=dict(conversations.__dict__)
    exec(compile(ast.Module(body=[method],type_ignores=[]),"f066723-possible_voice_names","exec"),scope)
    monkeypatch.setattr(conversations.ConversationPipeline,"possible_voice_names",scope["possible_voice_names"])
    # IT1-05 fixed differently than this probe first assumed: the owner's test 8 now asserts a real "Gigi" hint before
    # the opt-out (non-vacuous), and it still passes with the old method, which has no filter of its own, because
    # the opt-out is enforced at the source every hint shares: the voice space's centroids (I1, `naming_samples`)
    owner.test_8_a_readable_consent_without_attestation_opts_out_names_vectors_and_hints(tmp_path,damage)
