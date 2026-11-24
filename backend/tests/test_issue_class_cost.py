"""Astra IT5 probe (2026-11-24), adopted unchanged except imports/paths."""
from pathlib import Path
import json
import pytest
from omi_notes import views
from omi_notes.pipeline import conversations as pipeline_module
from .test_read_cost_nov24 import endpoint, add_conversations

def test_class_problem_summary_does_not_parse_whole_bad_population(client,monkeypatch):
    pipeline=client.app.state.speakers.pipeline; db=client.app.state.db
    root=pipeline.vault.conversations
    paths=[]; oldglob=Path.glob
    def glob(self,pattern,*args,**kwargs):
        if self==root and pattern=='*/*/class.json': return iter(paths)
        return oldglob(self,pattern,*args,**kwargs)
    monkeypatch.setattr(Path,'glob',glob)
    def unreadable(*a,**kw): raise pipeline_module.rclass.UnreadableChoice('synthetic permission/read failure')
    monkeypatch.setattr(pipeline_module.rclass,'read',unreadable)
    monkeypatch.setattr(pipeline_module.log,'error',lambda *a,**kw:None)
    loads=json.loads; parsed=[]
    expected=[None]
    def observed(s,*a,**kw):
        if s==expected[0]: parsed.append(len(s))
        return loads(s,*a,**kw)
    monkeypatch.setattr(views.json,'loads',observed)
    def run(n):
        db.execute('DELETE FROM conversations'); add_conversations(db,0,n,'done')
        db.execute("UPDATE conversations SET note_path='n.md'")
        paths[:]=[root/'2026-11-24'/r['id']/'class.json' for r in db.query('SELECT id FROM conversations')]
        pipeline.reconcile_classes(1.0)
        expected[0]=db.meta('class_unreadable'); parsed.clear()
        answer=endpoint(client,'/v1/issues')(limit=20)
        issue=next(x for x in answer['issues'] if x['code']=='class_choice_unreadable')
        assert issue['count']==n
        assert issue['server_step'].count(', ')==4
        return sum(parsed),len(answer['issues'])
    a=run(100);b=run(10000)
    print('CLASS_ISSUES_JSON_PARSED',a,b)
    assert b[0]<=a[0]*3,'one fixed-count/5-example issue still parses all bad conversation IDs'
