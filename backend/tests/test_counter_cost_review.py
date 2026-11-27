"""Astra IT5 probe (2026-11-24), adopted unchanged except imports/paths."""
from __future__ import annotations
import json, subprocess, threading, time, types
from pathlib import Path
import pytest
from omi_notes.db import Database, QUEUE
ROOT=Path(__file__).resolve().parents[2]  # this repository (Astra's pointed at her worktree)
def _in_git_work_tree(path) -> bool:
    return subprocess.run(["git", "rev-parse", "--is-inside-work-tree"], cwd=path, capture_output=True).returncode == 0


NO_GIT = "needs git history; covered by the in-repo run"  # the release tree (deploy/build-release.sh) has no .git


def old_database():
    if not _in_git_work_tree(ROOT):
        pytest.skip(NO_GIT)
    src=subprocess.check_output(['git','show','d861a4e:backend/src/omi_notes/db.py'],cwd=ROOT,text=True)
    mod=types.ModuleType('omi_notes.counter_review_old_db'); mod.__package__='omi_notes'
    exec(compile(src,'d861a4e-db.py','exec'),mod.__dict__)
    return mod.Database

def insert(db,seq,status='pending'):
    db.execute('INSERT INTO chunks(capture_id,chunk_sequence,device_id,source,sha256,size,path,received_at,start_epoch,end_epoch,start_offset_us,end_offset_us,status) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)',('capture',seq,'device','pendant_pcm',str(seq),1,'x',float(seq),float(seq),float(seq+1),0,1,status))

def assert_counts(db):
    truth={r['status']:r['n'] for r in db.query('SELECT status,COUNT(*) n FROM chunks GROUP BY status')}
    stored={r['status']:r['n'] for r in db.query('SELECT * FROM chunk_counts') if r['n']}
    assert stored==truth
    for key,predicate in QUEUE.items():
        assert db.queue_total(key)==db.one(f'SELECT COUNT(*) n FROM conversations WHERE {predicate}')['n']

def conv(db,key,status):
    db.execute('INSERT INTO conversations(id,device_id,start,end,status,created_at,updated_at) VALUES (?,?,?,?,?,?,?)',(key,'d',1.,2.,status,1.,1.))

def test_seed_serializes_writes_before_and_during_transaction(tmp_path,monkeypatch):
    path=tmp_path/'index.sqlite3'; Old=old_database(); old=Old(path)
    for i in range(10): insert(old,i)
    conv(old,'before','open'); old.close()
    created=threading.Event(); allow_seed=threading.Event(); in_seed=threading.Event(); finish_seed=threading.Event(); writer_done=threading.Event()
    errors=[]; results=[]; original=Database._counters
    def delayed_seed(self):
        created.set(); assert allow_seed.wait(5)
        def trace(sql):
            if sql=='DELETE FROM chunk_counts':
                in_seed.set(); assert finish_seed.wait(5)
        self.conn().set_trace_callback(trace)
        try: original(self)
        finally: self.conn().set_trace_callback(None)
    monkeypatch.setattr(Database,'_counters',delayed_seed)
    def opener():
        try: results.append(Database(path))
        except BaseException as exc: errors.append(exc)
    t=threading.Thread(target=opener);t.start();assert created.wait(5)
    # Real old release connection writes after new triggers exist but before seed begins.
    other=Old(path);insert(other,10);conv(other,'between','failed');other.close()
    allow_seed.set();assert in_seed.wait(5)
    def writer():
        try:
            other=Old(path);insert(other,11);conv(other,'during','closed');other.close()
        except BaseException as exc:errors.append(exc)
        finally:writer_done.set()
    u=threading.Thread(target=writer);u.start()
    assert not writer_done.wait(.05),'BEGIN IMMEDIATE must prevent the concurrent writer passing the seed'
    finish_seed.set();t.join(5);u.join(5)
    assert not t.is_alive() and not u.is_alive() and not errors
    db=Database(path);assert_counts(db);assert db.chunk_count('pending')==12
    assert db.queue_total('open')==db.queue_total('failed')==db.queue_total('pending')==1

def test_real_old_release_writes_keep_new_counters_after_rollback_forward(tmp_path):
    path=tmp_path/'index.sqlite3'; new=Database(path)
    for i in range(20):insert(new,i)
    conv(new,'one','open');conv(new,'two','closed');new.close()
    old=old_database()(path)
    with old.tx() as conn:
        conn.execute("UPDATE chunks SET status='processed' WHERE chunk_sequence<10")
        conn.execute("UPDATE chunks SET status='failed' WHERE chunk_sequence=19")
        conn.execute('DELETE FROM chunks WHERE chunk_sequence=0')
        conn.execute("UPDATE conversations SET status='failed' WHERE id='one'")
        conn.execute("DELETE FROM conversations WHERE id='two'")
    insert(old,20);conv(old,'three','transcribing');old.close()
    again=Database(path);assert_counts(again)
    assert again.meta('counters')=='2'
    assert again.chunk_count('pending')==10 and again.chunk_count('processed')==9 and again.chunk_count('failed')==1

def test_per_insert_counter_cost_is_population_independent(tmp_path):
    db=Database(tmp_path/'index.sqlite3')
    def steps(fn):
        n=0
        def progress():
            nonlocal n;n+=1;return 0
        db.conn().set_progress_handler(progress,1)
        try:fn()
        finally:db.conn().set_progress_handler(None,0)
        return n
    for i in range(100):insert(db,i)
    a=steps(lambda:insert(db,100))
    with db.tx():
        for i in range(101,6300):insert(db,i)
    b=steps(lambda:insert(db,6300))
    print('CHUNK_INSERT_VM',a,b)
    assert b<=a*2
    assert_counts(db)

def test_oldest_pending_seek_and_counter_query_plans(tmp_path):
    db=Database(tmp_path/'index.sqlite3')
    plans={
      'oldest':[tuple(r) for r in db.query("EXPLAIN QUERY PLAN SELECT MIN(received_at) FROM chunks WHERE status='pending'")],
      'counter':[tuple(r) for r in db.query("EXPLAIN QUERY PLAN SELECT n FROM chunk_counts WHERE status='pending'")],
      'events':[tuple(r) for r in db.query("EXPLAIN QUERY PLAN SELECT body_json FROM events WHERE type='watch_performance' AND at>=? ORDER BY at",(1.,))]
    }
    print(json.dumps(plans))
    assert 'chunks_status_received' in str(plans['oldest'])
    assert 'sqlite_autoindex_chunk_counts' in str(plans['counter'])
    assert 'events_type_at' in str(plans['events'])


def test_live_size_legacy_migration_is_one_time(tmp_path):
    path=tmp_path/'index.sqlite3'; old=old_database()(path)
    with old.tx():
        for i in range(32000): insert(old,i)
        for i in range(1500): conv(old,f'c{i}', ['open','closed','failed','done'][i%4])
    old.close()
    t=time.perf_counter(); new=Database(path); elapsed=time.perf_counter()-t
    assert_counts(new)
    indexes={r['name'] for r in new.query("SELECT name FROM sqlite_master WHERE type='index'")}
    assert {'conversations_claimed','conversations_active_retry_at','conversations_active_end','conversations_issue_failed','conversations_issue_conflict','conversations_issue_retrying'} <= indexes
    new.close(); t=time.perf_counter(); Database(path).close(); reopened=time.perf_counter()-t
    print('LEGACY_MIGRATION_32000_CHUNKS_1500_CONVERSATIONS',elapsed,'REOPEN',reopened)

def test_negative_waiting_is_possible_across_writer_interleave(tmp_path,monkeypatch):
    from omi_notes import views
    from omi_notes.settings import Settings
    db=Database(tmp_path/'index.sqlite3')
    conv(db,'working','summarizing')
    db.execute("UPDATE conversations SET claim_token='worker', claim_expires=200")
    writer=Database(tmp_path/'index.sqlite3')
    original=db.queue_total
    def interleave(name):
        if name=='active_listed': writer.execute("UPDATE conversations SET status='done',claim_token=NULL,claim_expires=NULL")
        return original(name)
    monkeypatch.setattr(db,'queue_total',interleave)
    a=views.activity(db,Settings(),100.)
    print('ACTIVITY_INTERLEAVE',a['waiting'],a['backing_off'])
    assert a['waiting'] >= 0
