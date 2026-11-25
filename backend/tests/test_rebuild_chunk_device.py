"""The audio branch of a FULL rebuild compares a chunk's header device with its folder the way the vault names folders
(`safe_component`, as 4514256 did for tombstones): an id the API accepts with punctuation still rebuilds, and an
acknowledged chunk whose header names another device than its folder is refused, not indexed under the wrong one."""

import shutil
import uuid

import pytest

from omi_notes.envelope import build_envelope, parse_envelope
from omi_notes.spool import safe_component
from omi_notes.vault import index_dir

from .conftest import put_chunk
from .test_disk_full import GiB, _envs, _free
from .test_publication_matrix import fresh


def _stored(settings, monkeypatch, device: str):
    _free(monkeypatch, 50 * GiB)
    c = fresh(settings)
    cap = str(uuid.uuid4())
    env = parse_envelope(_envs(cap)[0])
    h = env.header.model_dump(mode="json")
    h["device_id"] = device
    raw = build_envelope(h, env.payload)
    assert put_chunk(c, cap, 0, raw).status_code == 201
    return c, cap, raw


@pytest.mark.parametrize("device", ["11111111-2222-4333-8444-555555555555", "Watch:example"])
def test_a_chunk_in_its_own_device_folder_rebuilds(settings, monkeypatch, device):
    c, cap, raw = _stored(settings, monkeypatch, device)
    c.app.state.db.set_meta("schema_version", "11")
    c.app.state.db.close()
    again = fresh(settings)
    assert again.get("/healthz").status_code == 200
    assert again.app.state.db.one("SELECT device_id FROM chunks WHERE capture_id=?", (cap,))["device_id"] == device


def test_an_acknowledged_chunk_in_another_device_folder_is_refused(settings, monkeypatch):
    device = "11111111-2222-4333-8444-555555555555"
    c, cap, raw = _stored(settings, monkeypatch, device)
    v = c.app.state.vault
    c.app.state.db.set_meta("schema_version", "11")
    c.app.state.db.close()
    index = index_dir(settings, v) / "index.sqlite3"
    other = v.raw / safe_component("22222222-2222-4333-8444-555555555555")
    other.mkdir(parents=True)
    shutil.move(str(v.capture_dir(device, cap)), str(other / cap))  # misplaced: the header still names `device`
    before = index.read_bytes()
    result = fresh(settings).get("/healthz")
    assert result.status_code == 503, result.text
    assert index.read_bytes() == before
    assert (other / cap / "0.omnc").read_bytes() == raw, "the audio is kept where it is"
