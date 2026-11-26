"""Read-only Astra IT2b review probes; the assertions state requested cost invariants."""
from dataclasses import replace
from pathlib import Path
import time
import uuid
import pytest
from .conftest import AUTH
from .test_carbon_it1_20261126 import _setup_person, AUTH as IT1_AUTH

class CountedPeople(list):
    def __init__(self, n):
        super().__init__({'id':str(i), 'name':str(i), 'me':False} for i in range(n))
        self.visits=0
    def __iter__(self):
        for p in super().__iter__():
            self.visits+=1
            yield p

def test_suggestions_limit_one_has_bounded_population_work(client):
    svc=client.app.state.speakers
    counts=[]
    for n in (100,1000):
        people=CountedPeople(n)
        svc._people=replace(svc._people, people=people, suggestions=[], ready=True)
        response=client.get('/v1/speakers/suggestions?limit=1',headers=AUTH)
        assert response.status_code==200
        counts.append(people.visits)
    print('SUGGESTIONS_PEOPLE_VISITS',counts)
    assert counts[1] <= 20, 'limit=1 scans every cached person before slicing suggestions'

def test_put_settings_does_not_touch_population(client,monkeypatch):
    svc=client.app.state.speakers
    def forbidden(*args,**kw):raise AssertionError('settings request touched global population')
    for name in ('scan_people','sync_samples','evidence_key','reconcile_vectors'):
        monkeypatch.setattr(svc.store,name,forbidden)
    monkeypatch.setattr(svc,'refresh_people',forbidden)
    for body in ({'auto_assign':False},{'unknown_voices_enabled':True},{'acknowledged_at':None}):
        response=client.put('/v1/speakers/settings',json=body,headers=AUTH)
        assert response.status_code==200
    print('PUT_SETTINGS_NO_POPULATION_WORK',True)




# Expected-truth versions of Astra 08's two measurements (her probes measured the growth).
@pytest.mark.parametrize('population', ['people', 'samples'])
def test_put_person_same_name_does_no_population_work(client, monkeypatch, population):
    svc = client.app.state.speakers
    store = svc.store
    pid = str(uuid.uuid4())
    assert client.put('/v1/people/' + pid, json={'name': 'Target'}, headers=AUTH).status_code == 201
    notes = store.vault.root / 'People'
    folder = store.person_dir(pid) / 'samples'
    folder.mkdir(parents=True, exist_ok=True)
    reads, globs = [], []
    realopen, realglob = Path.open, Path.glob

    def opened(path, *args, **kw):
        mode = args[0] if args else kw.get('mode', 'r')
        if 'r' in mode and path.is_relative_to(store.vault.root) and path.suffix == '.md':
            reads.append(path.name)
        return realopen(path, *args, **kw)

    def globbed(path, pattern, *args, **kw):
        for found in realglob(path, pattern, *args, **kw):
            if pattern == '*/samples/*.json':
                globs.append(found.name)
            yield found

    monkeypatch.setattr(Path, 'open', opened)
    monkeypatch.setattr(Path, 'glob', globbed)
    counts = []
    for start, n in ((0, 100), (100, 1000)):
        for i in range(start, n):
            if population == 'people':
                (notes / f'Person {i:04}.md').write_text('---\nomi_person_id: ' + str(uuid.UUID(int=i + 1)) + '\n---\n')
            else:
                (folder / f'unindexed-{i}.json').write_text('{}')
        reads.clear(); globs.clear()
        assert client.put('/v1/people/' + pid, json={'name': 'Target'}, headers=AUTH).status_code == 200
        counts.append(len(reads) if population == 'people' else len(globs))
    print('PUT_PERSON_POPULATION_WORK', population, counts)
    assert counts[1] <= counts[0] + 5, 'a same-name PUT walks the whole population'


def test_unknown_voice_clustering_has_a_real_input_bound(monkeypatch):
    import numpy as np
    from omi_notes.speakers import suggest
    seen = []
    real = suggest.cluster
    monkeypatch.setattr(suggest, 'cluster', lambda vectors, *a, **k: seen.append(len(vectors)) or real(vectors, *a, **k))
    for n in (25, 1000):
        seen.clear()
        candidates = [suggest.Candidate(f'c{i}', 'S1', np.ones(8, dtype=np.float32), 6.0, '2026-11-26', -20.0) for i in range(n)]
        suggest.suggestions(candidates, {}, me_exists=True, dismissed={}, now=0.0, limit=20)
        assert max(seen or [0]) <= suggest.MAX_CLUSTER_INPUT, (n, seen)
