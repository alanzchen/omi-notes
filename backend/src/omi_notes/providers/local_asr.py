"""The local ASR sidecar (`sidecar/asr`, MOSS-Transcribe-Diarize lines + Qwen3-ASR text) as Omi's STT.

It speaks the `openai_diarized` shape: segments with real start/end and `speaker_id`. Differences from a
generic OpenAI-compatible server, all deliberate (asr-bench-20261108):
- requests of up to 1200 s (one MOSS window: its context allows ~20 min) cut at pauses, each reaching 20 s
  into its neighbours so the same speech is heard twice (`anchors` ties the labels there); the sidecar
  re-splits a truncated window itself; never per-speaker 30 s windows;
- no `language` hint (mixed Mandarin/English) and no `prompt` (a MOSS prompt replaces its instruction);
  the keyterms go as `context`, which the sidecar gives Qwen as hotwords;
- its labels restart in every piece, and inside a piece in every window MOSS was re-split into (the
  answer's `windows`, label prefixes `W<k>.<n>-`): each such window becomes a piece of its own here, so
  the pipeline links them all with voiceprints (`pipeline.speaker_links`) and uses them as the
  provider's labels.
A 900 s piece takes about 80 s (RTF 0.09, plus ~10 s to load the models); the 20 min timeout leaves room
for MOSS re-splitting a truncated window without letting a hung sidecar hold the worker for an hour.
`healthy()` asks `/health` (cached 30 s; `refresh=True` asks again). The sidecar is the only engine:
while it is down, conversations wait for it (never another provider).
"""

from __future__ import annotations

import time

import httpx

from . import SttRequest
import io

import numpy as np
import soundfile as sf

from .openai_stt import SAMPLE_RATE, OpenAICompatStt, _flac, _TooLarge, normalize_response, pad_short, split_points


UNKNOWN = "UNKNOWN"  # the sidecar's label for words no MOSS line holds


def _normalized(data: dict) -> dict:
    """`normalize_response`, with the sidecar's UNKNOWN words marked `unattributed` (speaker None): kept and
    shown as an unknown speaker, never numbered, linked or used for a voiceprint."""
    segments = [dict(s, speaker_id=None) if s.get("speaker_id") == UNKNOWN else s for s in data.get("segments") or []]
    result = normalize_response(dict(data, segments=segments))
    for utterance in result["results"]["utterances"]:
        if utterance.get("speaker") is None:
            utterance["unattributed"] = True
    return result


OVERLAP_SECONDS = 20.0  # each request reaches this far into its neighbour (they share twice this)
ANCHOR_SECONDS = 2.0  # shared speech that ties two requests' labels
ANCHOR_SHARE = 0.5  # ... and at least this share of each label's speech in the shared stretch


def _sub_request(request: SttRequest, pcm: np.ndarray, a: float, b: float) -> SttRequest:
    """The samples [a, b) of a request, with its speech blocks clipped and shifted."""
    piece = pcm[round(a * SAMPLE_RATE) : round(b * SAMPLE_RATE)]
    blocks = [(max(x, a) - a, min(y, b) - a) for x, y in sorted(request.blocks) if y > a and x < b]
    return SttRequest(flac=_flac(piece), duration=len(piece) / SAMPLE_RATE, blocks=blocks,
                      language=request.language, keyterms=request.keyterms)  # fmt: skip


def _shared(xs: list[tuple[float, float]], ys: list[tuple[float, float]]) -> float:
    return sum(max(0.0, min(b, d) - max(a, c)) for a, b in xs for c, d in ys)


def anchors(left: list[dict], right: list[dict], lo: float, hi: float, least: float = ANCHOR_SECONDS) -> list[list[int]]:
    """Labels of two neighbouring requests that cover the same speech in their shared stretch [lo, hi]:
    each other's best partner, sharing at least ANCHOR_SECONDS and ANCHOR_SHARE of each one's speech there."""

    def spans(utts: list[dict]) -> dict[int, list[tuple[float, float]]]:
        out: dict[int, list[tuple[float, float]]] = {}
        for u in utts:
            a, b = max(float(u["start"]), lo), min(float(u["end"]), hi)
            if u.get("speaker") is not None and b > a:
                out.setdefault(u["speaker"], []).append((a, b))
        return out

    ls, rs = spans(left), spans(right)
    shared = {(x, y): _shared(ls[x], rs[y]) for x in ls for y in rs}
    out = []
    for (x, y), v in shared.items():
        if v < least or v < ANCHOR_SHARE * min(_shared(ls[x], ls[x]) or 1, _shared(rs[y], rs[y]) or 1):
            continue
        if max(shared[(x, k)] for k in rs) > v or max(shared[(k, y)] for k in ls) > v:
            continue
        out.append([x, y])
    return out


class LocalAsrStt(OpenAICompatStt):
    name = "local-asr"
    links_speakers = True
    HEALTH_TTL = 30.0
    overlap_seconds = OVERLAP_SECONDS

    def __init__(self, base_url: str, model: str = "omi-asr", *, max_request_seconds: float = 1200.0,
                 transport: httpx.BaseTransport | None = None, timeout: float = 1200.0) -> None:  # fmt: skip
        super().__init__(base_url, "", model, style="openai_diarized", max_request_seconds=max_request_seconds,
                         timeout=timeout, transport=transport)  # fmt: skip
        self._health: tuple[float, bool] | None = None
        self._health_client = httpx.Client(timeout=httpx.Timeout(2.0, connect=1.0), transport=transport)

    @property
    def cache_tag(self) -> str:
        return f"local-asr-v2-{self.max_seconds:g}-o{self.overlap_seconds:g}"

    def fields(self, request: SttRequest) -> dict[str, str | list[str]]:
        fields: dict[str, str | list[str]] = {"model": self.model, "response_format": "diarized_json"}
        if request.keyterms:
            fields["context"] = ", ".join(request.keyterms)
        return fields

    def transcribe(self, request: SttRequest) -> dict:
        """Requests of at most `max_seconds`, cut at pauses, each reaching `overlap_seconds` into its
        neighbours. Every utterance is kept once (by the request owning its middle); labels restart per
        request (and per MOSS re-split window: each is a group), and labels covering the same speech in a
        shared stretch are anchors for the speaker clustering (`pipeline.speaker_links`)."""
        pcm, _ = sf.read(io.BytesIO(request.flac), dtype="int16")
        total = len(pcm) / SAMPLE_RATE
        over = min(self.overlap_seconds, self.max_seconds / 6) if self.max_seconds else 0.0  # a request stays within the limit
        cuts = [c for c, _ in split_points(request, self.max_seconds - 2 * over)] if self.max_seconds and total > self.max_seconds else []
        edges = [0.0, *cuts, total]
        utterances: list[dict] = []
        groups: list[list[int]] = []
        found: list[list[list[int]]] = []
        heard: list[list[dict]] = []  # every utterance of each request, in absolute time (for anchors)
        language, base, group = None, 0, 0
        for k in range(len(edges) - 1):
            own_a, own_b = edges[k], edges[k + 1]
            a, b = (max(0.0, own_a - over) if k else 0.0), (min(total, own_b + over) if k < len(edges) - 2 else total)
            part = request if (a, b) == (0.0, total) else _sub_request(request, pcm, a, b)
            mine: list[dict] = []
            for offset, result in self._transcribe_part(a, part):
                top = -1
                for u in result["results"]["utterances"]:
                    shifted = dict(u, start=float(u["start"]) + offset, end=float(u["end"]) + offset)
                    shifted.pop("words", None)
                    if u.get("speaker") is not None:
                        shifted["speaker"] = u["speaker"] + base
                        top = max(top, u["speaker"])
                        groups.append([shifted["speaker"], group])
                    mine.append(shifted)
                base += top + 1
                group += 1
                channel = (result["results"].get("channels") or [{}])[0]
                language = language or channel.get("detected_language")
            heard.append(mine)
            utterances += [u for u in mine if own_a <= (u["start"] + u["end"]) / 2 < own_b or (k == len(edges) - 2 and (u["start"] + u["end"]) / 2 >= own_b)]
            if k:
                found.append(anchors(heard[k - 1], mine, max(0.0, own_a - over), min(total, own_a + over), min(ANCHOR_SECONDS, over)))
        groups = [list(g) for g in {tuple(g) for g in groups}]
        response = {"results": {"channels": [{"detected_language": language} if language else {}], "utterances": utterances}}
        if group > 1:
            response["omi_notes"] = {"pieces": group, "offsets": [round(e, 3) for e in edges[:-1]], "groups": sorted(groups),
                                     "anchors": [pair for pairs in found for pair in pairs], "overlap_seconds": over}  # fmt: skip
        return response

    def _transcribe_part(self, offset: float, part: SttRequest) -> list[tuple[float, dict]]:
        try:
            data = self._post(pad_short(part))
        except _TooLarge:  # the generic path halves it
            return super()._transcribe_part(offset, part)
        windows = sorted(data.get("windows") or [], key=lambda w: float(w["start"]))
        if len(windows) < 2:
            return [(offset, _normalized(data))]
        # each segment belongs to the window whose label prefix it carries (the first window's is empty)
        groups: dict[int, list[dict]] = {}
        for seg in data.get("segments") or []:
            label = str(seg.get("speaker_id") or "")
            k = next((i for i, w in enumerate(windows) if w.get("label_prefix") and label.startswith(w["label_prefix"])), 0)
            groups.setdefault(k, []).append(seg)
        out = []
        for k, segments in sorted(groups.items()):
            start = float(windows[k]["start"])
            shifted = [dict(seg, start=float(seg["start"]) - start, end=float(seg["end"]) - start) for seg in segments]
            out.append((offset + start, _normalized(dict(data, segments=shifted))))
        return out

    def healthy(self, *, refresh: bool = False) -> bool:
        now = time.monotonic()
        if not refresh and self._health and now - self._health[0] < self.HEALTH_TTL:
            return self._health[1]
        root = self.base_url[: -len("/v1")] if self.base_url.endswith("/v1") else self.base_url
        try:
            ok = self._health_client.get(root + "/health").status_code == 200
        except httpx.HTTPError:
            ok = False
        self._health = (now, ok)
        return ok
