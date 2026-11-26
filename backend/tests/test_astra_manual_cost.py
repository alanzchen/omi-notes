"""Astra IT1 (2026-11-26) probe, ported: imports adapted to this package; outcome as the invariants require."""
from pathlib import Path
import pytest
from .test_speaker_policy import Env, AUTH

def test_put_settings_does_not_inventory_unrelated_sample_population(tmp_path,monkeypatch):
    e=Env(tmp_path)
    folder=e.store.person_dir(e.gigi)/"samples"
    orig=Path.glob;seen=[]
    def tracked(self,pattern,*a,**kw):
        for p in orig(self,pattern,*a,**kw):
            if self==e.store.vault.people and pattern=="*/samples/*.json":seen.append(p.name)
            yield p
    monkeypatch.setattr(Path,"glob",tracked)
    def seed(a,b):
        for i in range(a,b):(folder/f"unused-{i}.json").write_text("{}")
    def run():
        seen.clear();response=e.client.put("/v1/speakers/settings",json={"auto_assign":True},headers=AUTH)
        assert response.status_code==200
        return len(seen)
    seed(0,100);small=run()
    seed(100,1000);large=run()
    print("SETTINGS_SAMPLE_VISITS",small,large)
    assert large<=small*3,"a fixed settings request walks the total sample-file population"
