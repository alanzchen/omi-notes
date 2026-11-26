"""Astra IT1 (2026-11-26) probe, ported: imports adapted to this package; outcome as the invariants require."""
import uuid
import pytest
from .test_speaker_policy import Env, AUTH
from omi_notes.speakers import journal
from omi_notes.speakers.imports import Importer

def test_manual_assignment_does_not_create_sample_after_readable_optout(tmp_path):
    e=Env(tmp_path)
    conv,_=e.conversation(named=False,sha="e")
    assert e.store.attested(e.gigi)
    e.tear_consent("{}")
    before=e.store.db.one("SELECT COUNT(*) n FROM samples WHERE person_id=?",(e.gigi,))["n"]
    revision=e.store.db.one("SELECT speakers_revision FROM conversations WHERE id=?",(conv,))[0]
    response=e.client.put(f"/v1/conversations/{conv}/speakers/S1",json={"person_id":e.gigi,"expected_revision":revision,"request_id":str(uuid.uuid4())},headers=AUTH)
    after=e.store.db.one("SELECT COUNT(*) n FROM samples WHERE person_id=?",(e.gigi,))["n"]
    print("MANUAL_AFTER_OPTOUT",response.status_code,response.json(),"sample_count",before,after,"current_policy",e.store.person_policy(e.gigi,e.store.settings()))
    assert after==before, "a cached attestation must not authorize new voice data after readable optout"

def test_journal_gate_observes_readable_optout(tmp_path):
    e=Env(tmp_path)
    e.tear_consent("{}")
    why=journal._invalid(e.store,{"kind":"merge","person":e.gigi,"generations":{e.gigi:e.store.forget_count(e.gigi)}})
    print("JOURNAL_OPTOUT_GATE",repr(why),e.store.person_policy(e.gigi,e.store.settings()))
    assert why, "replay must not gain voice data for person with readable optout"

def test_import_gate_checks_readable_optout(tmp_path):
    e=Env(tmp_path)
    e.tear_consent("{}")
    current=Importer(e.svc)._consent(e.gigi)
    print("IMPORT_OPTOUT_GATE",current)
    assert current[1] is None
