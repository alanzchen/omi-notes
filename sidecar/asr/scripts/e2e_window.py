"""Post one audio window to a running sidecar and compare with a reference align+v result.

    .venv/bin/python scripts/e2e_window.py URL WAV REFERENCE.json [OUT.json]

Reports lines, speakers, timing, the sidecar's own RTF/peak memory, and the normalized token edit
distance between the two texts (one CJK character or one Latin word per token, fillers and punctuation
dropped). Prints no transcript text.
"""

import json
import re
import sys
import time
from pathlib import Path

import httpx

VOCAB = "Overleaf, literature review, Grok, reactance, a priori, IS paper, Management Science"  # the bench's context
url, wav, ref_path = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
out = Path(sys.argv[4]) if len(sys.argv) > 4 else None


def tokens(text: str) -> list[str]:
    text = re.sub(r"[^\w\s]", " ", text.lower())
    out = []
    for word in text.split():
        for part in re.findall(r"[一-鿿]|[a-z0-9']+", word):
            if part not in {"嗯", "啊", "呃", "哦", "um", "uh"}:
                out.append(part)
    return out


def distance(a: list[str], b: list[str]) -> float:
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i] + [0] * len(b)
        for j, y in enumerate(b, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y))
        prev = cur
    return prev[-1] / max(1, len(a))


t = time.perf_counter()
r = httpx.post(f"{url}/v1/audio/transcriptions", files={"file": (wav.name, wav.read_bytes(), "audio/wav")},
               data={"model": "omi-asr", "response_format": "diarized_json", "context": VOCAB}, timeout=3600)
r.raise_for_status()
wall = time.perf_counter() - t
got = r.json()
ref = json.loads(ref_path.read_text())["segments"]
got_text = " ".join(s["text"] for s in got["segments"])
ref_text = " ".join(s["text"] for s in ref)
report = {
    "audio_seconds": got["duration"], "wall_seconds": round(wall, 1), "sidecar": got["omi_asr"],
    "lines": {"sidecar": len(got["segments"]), "reference": len(ref)},
    "speakers": {"sidecar": sorted({s["speaker_id"] for s in got["segments"]}), "reference": sorted({s["speaker"] for s in ref})},
    "tokens": {"sidecar": len(tokens(got_text)), "reference": len(tokens(ref_text))},
    "token_edit_distance_vs_reference": round(distance(tokens(ref_text), tokens(got_text)), 4),
    "vocab_terms_found": {v.strip(): got_text.lower().count(v.strip().lower()) for v in VOCAB.split(",")},
}
print(json.dumps(report, ensure_ascii=False, indent=1))
if out:
    out.write_text(json.dumps({"report": report, "response": got}, ensure_ascii=False, indent=1))
