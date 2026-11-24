"""Astra's 2026-11-24 IT1 burst-path cost repros (copied unchanged from her review, except the IT1-01 xfail)."""
from __future__ import annotations
import json, time, uuid
import pytest
from pathlib import Path
from omi_notes import views
from omi_notes.pipeline.conversations import queue_counts

def measure(db, fn):
    steps=0
    def tick():
        nonlocal steps
        steps+=1
        return 0
    db.conn().set_progress_handler(tick,1)
    try:
        t=time.perf_counter(); result=fn(); elapsed=time.perf_counter()-t
    finally: db.conn().set_progress_handler(None,0)
    return steps, elapsed, result

def add_chunks(db,a,b,status):
    with db.tx() as c:
        c.executemany("INSERT INTO chunks(capture_id,chunk_sequence,device_id,source,sha256,size,path,received_at,start_epoch,end_epoch,start_offset_us,end_offset_us,status) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
        [("capture",i,"device","pendant_pcm",str(i),1,"x",float(i),float(i),float(i+1),0,1,status) for i in range(a,b)])

def add_conversations(db,a,b,status='done'):
    with db.tx() as c:
        c.executemany('INSERT INTO conversations(id,device_id,start,end,status,created_at,updated_at) VALUES (?,?,?,?,?,?,?)',[(str(uuid.UUID(int=i+1)),"device",float(i),float(i+1),status,0.0,0.0) for i in range(a,b)])

def endpoint(client,path): return next(r.endpoint for r in client.app.routes if getattr(r,'path',None)==path)

def test_status_work_does_not_scale_with_pending_backlog(client,settings):
    db=client.app.state.db
    add_chunks(db,0,100,'pending')
    f=endpoint(client,'/v1/status')
    a=measure(db,f)
    add_chunks(db,100,10000,'pending')
    b=measure(db,f)
    print('STATUS_PENDING',{'100':a[:2],'10000':b[:2],'count':b[2]['queue']['chunks_pending']})
    q="SELECT MIN(received_at) AS t FROM chunks WHERE status='pending'"
    print('STATUS_MIN_PLAN',[dict(r) for r in db.query('EXPLAIN QUERY PLAN '+q)])
    assert b[2]['queue']['chunks_pending']==10000
    assert b[0]<=a[0]*3, 'one status request walks pending population instead of a maintained counter/minimum'

def test_recent_issues_historical_cost_controls(client):
    db=client.app.state.db
    recent=endpoint(client,'/v1/conversations/recent'); issues=endpoint(client,'/v1/issues'); status=endpoint(client,'/v1/status')
    add_conversations(db,0,100)
    functions={'recent':lambda:recent(limit=20,before=None,recording_class=None,day=None,short=None),'issues':lambda:issues(limit=20),'status':status}
    a={k:measure(db,f) for k,f in functions.items()}
    add_conversations(db,100,10000)
    b={k:measure(db,f) for k,f in functions.items()}
    print('READS_DONE_HISTORY',{k:{'100':a[k][:2],'10000':b[k][:2]} for k in functions})
    for k in functions: assert b[k][0]<=a[k][0]*3,(k,a[k][:2],b[k][:2])

@pytest.mark.xfail(strict=True, reason='ASTRA-20261124-IT1-01 open: GET /v1/people still reconciles every sample file '
                   '(design: build/deployment/nightly/2026-11-24/r2/IT1-01-DESIGN.md)')
def test_people_request_does_not_enumerate_all_sample_files(client,monkeypatch):
    db=client.app.state.db; vault=client.app.state.vault
    pid=str(uuid.uuid4()); notes=vault.root/'People'; notes.mkdir(exist_ok=True)
    (notes/'Tester.md').write_text('---\nomi_person_id: '+pid+'\n---\n')
    folder=vault.people/pid/'samples'; folder.mkdir(parents=True,exist_ok=True)
    def seed(a,b):
        rows=[]
        for i in range(a,b):
            sid=str(uuid.UUID(int=i+1)); (folder/(sid+'.json')).write_text('{}')
            rows.append((sid,pid,'fake','fake',b'0000','enrollment',float(i)))
        with db.tx() as c: c.executemany('INSERT INTO samples(id,person_id,model,model_sha,vector,source,created_at) VALUES (?,?,?,?,?,?,?)',rows)
    real=Path.glob; visited=[]
    def tracked(self,pattern,**kwargs):
        for p in real(self,pattern,**kwargs):
            if self==vault.people and str(pattern)=='*/samples/*.json': visited.append(p.name)
            yield p
    monkeypatch.setattr(Path,'glob',tracked)
    f=endpoint(client,'/v1/people')
    # endpoint's request argument only supplies app.state, no network.
    from types import SimpleNamespace
    req=SimpleNamespace(app=client.app)
    seed(0,100); result=f(req); a=len(visited); visited.clear()
    seed(100,1000); result=f(req); b=len(visited)
    print('PEOPLE_SAMPLE_ENUMERATION',{'100_samples':a,'1000_samples':b,'people_returned':len(result['people'])})
    assert len(result['people'])==1
    assert b<=a+5,'Home appearance enumerates all samples despite returning the same one-person response'


def test_watch_performance_ignores_unrelated_old_event_population(client):
    db=client.app.state.db; f=endpoint(client,'/v1/watch/performance')
    def seed(a,b):
        with db.tx() as c: c.executemany('INSERT INTO events(event_id,device_id,type,at,body_json,received_at) VALUES (?,?,?,?,?,?)',[(str(uuid.UUID(int=i+1)),'device','button',float(i),'{}',float(i)) for i in range(a,b)])
    seed(0,100);a=measure(db,lambda:f(days=14))
    seed(100,10000);b=measure(db,lambda:f(days=14))
    print('WATCH_OLD_EVENT_COST',{'100':a[:2],'10000':b[:2],'same_answer':a[2]==b[2]})
    print('WATCH_PLAN',[dict(r) for r in db.query("EXPLAIN QUERY PLAN SELECT device_id,body_json FROM events WHERE type='watch_perf' AND at>=? ORDER BY at",(time.time()-14*86400,))])
    assert a[2]==b[2]
    assert b[0]<=a[0]*3,'Watch page request scans unrelated historical events despite a bounded14-day request'


def test_stats_ignores_old_named_speaker_population(client):
    from datetime import timezone
    db=client.app.state.db
    now=time.time()
    def seed(a,b):
        add_conversations(db,a,b)
        with db.tx() as c:
            c.executemany('INSERT INTO speaker_labels(conversation_id,label,person_id) VALUES (?,?,?)',[(str(uuid.UUID(int=i+1)),'SPEAKER_00','person') for i in range(a,b)])
    seed(0,100)
    a=measure(db,lambda:views.stats(db,timezone.utc,7,now))
    seed(100,10000)
    b=measure(db,lambda:views.stats(db,timezone.utc,7,now))
    query="SELECT c.start,l.person_id FROM speaker_labels l JOIN conversations c ON c.id=l.conversation_id WHERE l.person_id IS NOT NULL AND c.start>=? AND c.note_path IS NOT NULL AND json_extract(c.index_json, '$.kind') IN ('completed','transcript_only') AND c.enrollment_id IS NULL"
    print('STATS_OLD_SPEAKERS',{'100':a[:2],'10000':b[:2],'same_answer':a[2]==b[2]})
    print('STATS_PEOPLE_PLAN',[dict(r) for r in db.query('EXPLAIN QUERY PLAN '+query,(now-7*86400,))])
    assert a[2]==b[2]
    assert b[0]<=a[0]*3, 'Server seven-day stats scans unrelated historical named speakers'
