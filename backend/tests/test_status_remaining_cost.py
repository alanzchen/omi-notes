"""Astra's IT3-01 whole-endpoint cost probes (2026-11-24), copied unchanged except the import header."""
import pytest
from .test_read_cost_nov24 import add_conversations, endpoint, measure

@pytest.mark.parametrize('kind',['queued','conflicted'])
def test_entire_status_does_not_scan_remaining_population(client,kind):
    db=client.app.state.db; f=endpoint(client,'/v1/status')
    def seed(a,b):
        add_conversations(db,a,b,'closed' if kind=='queued' else 'done')
        if kind=='conflicted': db.execute("UPDATE conversations SET edited=1,note_path='note.md' WHERE start>=?",(float(a),))
    seed(0,100);a=measure(db,f)
    seed(100,10000);b=measure(db,f)
    print('STATUS_REMAINING',kind,{'100':a[:2],'10000':b[:2],'activity':b[2]['activity'],'queue':b[2]['queue']})
    assert b[0]<=a[0]*3, 'the full status endpoint still scans conversation population'


def test_issues_page_does_not_scan_failure_population(client):
    db=client.app.state.db; f=endpoint(client,'/v1/issues')
    add_conversations(db,0,100,'failed');a=measure(db,lambda:f(limit=20))
    add_conversations(db,100,10000,'failed');b=measure(db,lambda:f(limit=20))
    print('ISSUES_FAILURE_POPULATION',{'100':a[:2],'10000':b[:2],'returned':len(b[2]['issues'])})
    from omi_notes.views import LISTED, NOT_DISMISSED
    print('ISSUES_PLAN',[tuple(r) for r in db.query(f"EXPLAIN QUERY PLAN SELECT * FROM conversations WHERE status='failed' AND {LISTED} AND {NOT_DISMISSED} ORDER BY start DESC LIMIT ?",(20,))])
    assert b[0]<=a[0]*3, 'the issues page still scans its whole matching population'
