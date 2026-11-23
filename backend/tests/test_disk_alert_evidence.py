"""(2026-11-22: translated to the revision protocol, ASTRA-20261122-IT1 DESIGN-06/07: the witness's "index write at t"
became "a publication begun at revision r"; every final assertion is unchanged.)
Astra's IT3 alert-evidence repros (omi-notes-reviews/nightly-2026-11-21-it3/python/test_round3_checks.py), adopted unchanged
(ASTRA-20261121-IT3-02; one bad-alert check adapted, see there): recovery needs a successful index write after the latest write failure, and a successful
measurement of every watched volume."""
from __future__ import annotations
import errno
import json
import pytest
from omi_notes import disk_alert, ingest
from .conftest import AUTH
from .test_disk_full import _free, GiB, Usage


def test_write_evidence_must_follow_the_latest_write_failure(client, settings, monkeypatch):
    _free(monkeypatch,50*GiB)
    disk_alert.note_down(settings.logs_dir,free_bytes=GiB,floor_bytes=ingest.MIN_FREE_BYTES,reason='space',now=100,kind='space')
    began = disk_alert.revision(settings.logs_dir)  # a publication begins (the old "write at 110")
    disk_alert.note_down(settings.logs_dir,free_bytes=None,floor_bytes=ingest.MIN_FREE_BYTES,reason='new write failure',now=120,kind='write')
    disk_alert.witness(settings.logs_dir,[settings.vault_dir,settings.db_path.parent],floor_bytes=ingest.MIN_FREE_BYTES,now=121,since_revision=began)
    state=disk_alert.read(settings.logs_dir)
    print('OLD_WRITE_EVIDENCE',state)
    assert state['state']=='down', 'a write at110 cannot prove recovery from the failure at120'


def test_unmeasurable_index_volume_is_not_proof_of_recovery(client, settings, monkeypatch):
    disk_alert.note_down(settings.logs_dir,free_bytes=GiB,floor_bytes=ingest.MIN_FREE_BYTES,reason='index space',now=100,kind='space')
    def free(path):
        if path == settings.db_path.parent: raise OSError(errno.EACCES,'synthetic cannot stat index volume')
        return Usage(100*GiB,50*GiB,50*GiB)
    monkeypatch.setattr(disk_alert.shutil,'disk_usage',free)
    disk_alert.witness(settings.logs_dir,[settings.vault_dir,settings.db_path.parent],floor_bytes=ingest.MIN_FREE_BYTES,now=121,since_revision=disk_alert.revision(settings.logs_dir))
    state=disk_alert.read(settings.logs_dir)
    print('UNKNOWN_INDEX_VOLUME',state)
    assert state['state']=='down'


def test_corrupt_alert_fields_are_unknown_not_bad_wire_types(client, settings):
    path=settings.logs_dir/'alerts'/'disk.json';path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps({'state':'down','down_since':{'bad':'type'}}))
    response=client.get('/v1/status',headers=AUTH)
    print('BAD_ALERT_STATUS',response.status_code,response.json().get('disk'))
    assert response.status_code==200
    # (adapted: d4357e7 sends since:null for a bad down_since, which the coordinator allowed; the wire type is never wrong)
    disk = response.json().get('disk')
    assert disk is None or (disk.get('since') is None and isinstance(disk.get('full'), bool)), disk


@pytest.mark.parametrize('code',[errno.EACCES,errno.EROFS,errno.EIO])
def test_other_io_failures_are_not_disk_full(code):
    assert not ingest._disk_full_error(OSError(code,'synthetic failure'))


def test_hysteresis_and_fresh_evidence_clear_control(client, settings,monkeypatch):
    _free(monkeypatch,ingest.MIN_FREE_BYTES+disk_alert.HYSTERESIS)
    disk_alert.note_down(settings.logs_dir,free_bytes=None,floor_bytes=ingest.MIN_FREE_BYTES,reason='write',now=100)
    disk_alert.witness(settings.logs_dir,[settings.vault_dir,settings.db_path.parent],floor_bytes=ingest.MIN_FREE_BYTES,now=102,since_revision=disk_alert.revision(settings.logs_dir))
    assert disk_alert.read(settings.logs_dir)['state']=='recovered'
