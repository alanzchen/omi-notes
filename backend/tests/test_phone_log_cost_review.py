from pathlib import Path
import uuid
from omi_notes import phone_log

def test_phone_log_batch_does_not_inventory_unrelated_phones(tmp_path, monkeypatch):
    folder=tmp_path/'phone';folder.mkdir()
    own='phone-'+str(uuid.uuid4())
    real=Path.stat; seen=[]
    def stat(self,*args,**kwargs):
        if self.parent==folder: seen.append(self.name)
        return real(self,*args,**kwargs)
    monkeypatch.setattr(Path,'stat',stat)
    body={'device_id':own,'lines':[{'level':'info','at':'2026-11-24T00:00:00Z','category':'review','message':'fixture'}]}
    def seed(a,b):
        for i in range(a,b): (folder/('phone-'+str(uuid.UUID(int=i+1))+'.log')).write_text('x')
    seed(0,100);assert phone_log.append(tmp_path,body)==1;a=len(seen);seen.clear()
    seed(100,1000);assert phone_log.append(tmp_path,body)==1;b=len(seen)
    print('PHONE_LOG_STAT_CALLS',a,b)
    assert b<=a+10, 'one fixed diagnostic batch inventories unrelated retained phone logs'
