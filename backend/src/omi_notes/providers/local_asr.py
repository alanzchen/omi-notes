"""The local ASR sidecar (`sidecar/asr`, MOSS-Transcribe-Diarize lines + Qwen3-ASR text) as Omi's STT.

It speaks the `openai_diarized` shape: segments with real start/end and `speaker_id`. Differences from a
generic OpenAI-compatible server, all deliberate (asr-bench-20261108):
- requests of up to 900 s (one MOSS window: it stops itself after ~16.4k output tokens, which dense speech
  reaches near 20 min) cut at pauses, each reaching 20 s
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
import re

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


def _union(spans: list[tuple[float, float]]) -> list[tuple[float, float]]:
    out: list[list[float]] = []
    for a, b in sorted(spans):
        if out and a <= out[-1][1]:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return [(a, b) for a, b in out]


def _minus(spans: list[tuple[float, float]], cut: list[tuple[float, float]]) -> list[tuple[float, float]]:
    out = []
    for a, b in spans:
        pieces = [(a, b)]
        for c, d in cut:
            pieces = [p for x, y in pieces for p in ((x, min(y, c)), (max(x, d), y)) if p[1] > p[0]]
        out += pieces
    return out


def _shared(xs: list[tuple[float, float]], ys: list[tuple[float, float]]) -> float:
    return sum(max(0.0, min(b, d) - max(a, c)) for a, b in xs for c, d in ys)


def _length(spans: list[tuple[float, float]]) -> float:
    return sum(b - a for a, b in spans)


def seam(left: list[dict], right: list[dict], lo: float, hi: float, step: float = 0.1) -> float:
    """Where two neighbouring requests' answers are joined inside their shared stretch [lo, hi]: the moment
    farthest from any utterance of either (a pause both heard), the middle on a tie. Cutting there, the same
    speech lies wholly on one side in both answers even when they time it a little differently."""
    spans = [(float(u["start"]), float(u["end"])) for u in left + right]
    mid = (lo + hi) / 2

    def clearance(t: float) -> float:
        return min((0.0 if a <= t <= b else min(abs(t - a), abs(t - b)) for a, b in spans), default=hi - lo)

    points = [lo + k * step for k in range(int((hi - lo) / step) + 1)] or [mid]
    return max(points, key=lambda t: (round(clearance(t), 3), -abs(t - mid)))


def _tokens(text: str) -> list[str]:
    """Words for comparison: lower case, punctuation dropped; CJK characters one by one."""
    out: list[str] = []
    for word in re.findall(r"[\w']+", text.lower()):
        out += list(word) if any("\u3000" <= ch <= "\u9fff" or "\uac00" <= ch <= "\ud7af" for ch in word) else [word]
    return out


def _contains(whole: list[str], part: list[str]) -> bool:
    n = len(part)
    return n == 0 or any(whole[i : i + n] == part for i in range(len(whole) - n + 1))


def _covered(u: dict, others: list[dict]) -> bool:
    """Whether `u` is already there: another utterance overlapping half of it in time holds all of its words
    in order ("open the door" is in "do not open the door", not the other way round). Anything else is kept:
    a duplicate beats a loss."""
    a, b = float(u["start"]), float(u["end"])
    words = _tokens(str(u.get("transcript", "")))
    return any(_shared([(a, b)], [(float(o["start"]), float(o["end"]))]) >= 0.5 * max(b - a, 1e-6)
               and _contains(_tokens(str(o.get("transcript", ""))), words) for o in others)  # fmt: skip


def anchors(left: list[dict], right: list[dict], lo: float, hi: float, least: float = ANCHOR_SECONDS) -> list[list[int]]:
    """Labels of two neighbouring requests that cover the same speech in their shared stretch [lo, hi]:
    each other's best partner, sharing at least ANCHOR_SECONDS and ANCHOR_SHARE of each one's speech there."""

    def spans(utts: list[dict]) -> dict[int, list[tuple[float, float]]]:
        raw: dict[int, list[tuple[float, float]]] = {}
        for u in utts:
            a, b = max(float(u["start"]), lo), min(float(u["end"]), hi)
            if u.get("speaker") is not None and b > a:
                raw.setdefault(u["speaker"], []).append((a, b))
        merged = {k: _union(v) for k, v in raw.items()}
        # two people at once: that speech can't say which label is which
        both = _union([(max(a, c), min(b, d)) for x in merged for y in merged if x < y
                       for a, b in merged[x] for c, d in merged[y] if min(b, d) > max(a, c)])  # fmt: skip
        return {k: _minus(v, both) for k, v in merged.items()}

    ls, rs = spans(left), spans(right)
    shared = {(x, y): _shared(ls[x], rs[y]) for x in ls for y in rs}
    out = []
    for (x, y), v in shared.items():
        # most of BOTH labels' own speech there is this same speech
        if v < least or v < ANCHOR_SHARE * _length(ls[x]) or v < ANCHOR_SHARE * _length(rs[y]):
            continue
        rivals = [shared[(x, k)] for k in rs if k != y] + [shared[(k, y)] for k in ls if k != x]
        if any(r >= v for r in rivals):  # not each other's clear best: ambiguous, no anchor
            continue
        out.append([x, y])
    return out


class LocalAsrStt(OpenAICompatStt):
    name = "local-asr"
    links_speakers = True
    HEALTH_TTL = 30.0
    overlap_seconds = OVERLAP_SECONDS

    def __init__(self, base_url: str, model: str = "omi-asr", *, max_request_seconds: float = 900.0,
                 transport: httpx.BaseTransport | None = None, timeout: float = 1200.0) -> None:  # fmt: skip
        super().__init__(base_url, "", model, style="openai_diarized", max_request_seconds=max_request_seconds,
                         timeout=timeout, transport=transport)  # fmt: skip
        self._health: tuple[float, bool] | None = None
        self.health_info: dict = {}  # the last /health answer (models, self-test), for /v1/status
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
        stretches: list[tuple[float, float]] = []
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
            if k:
                lo, hi = max(0.0, own_a - over), min(total, own_a + over)
                found.append(anchors(heard[k - 1], mine, lo, hi, min(ANCHOR_SECONDS, over)))
                stretches.append((lo, hi))
        # join neighbours at a pause both heard; then rescue anything one side would drop that the other lacks
        seams = [seam([u for u in heard[k] if u["end"] > lo], [u for u in heard[k + 1] if u["start"] < hi], lo, hi)
                 for k, (lo, hi) in enumerate(stretches)]  # fmt: skip
        bounds = [float("-inf"), *seams, float("inf")]
        kept = [[u for u in mine if bounds[k] <= (u["start"] + u["end"]) / 2 < bounds[k + 1]] for k, mine in enumerate(heard)]
        for k, (lo, hi) in enumerate(stretches):
            def here(u: dict) -> bool:  # only what lies in this shared stretch (the other side of a request has its own)
                return u["end"] > lo and u["start"] < hi

            kept[k] += [u for u in heard[k] if u not in kept[k] and here(u) and not _covered(u, kept[k + 1])]
            # after the left side's rescues are in: never both copies of one phrase
            kept[k + 1] += [u for u in heard[k + 1] if u not in kept[k + 1] and here(u) and not _covered(u, kept[k])]
        utterances = sorted((u for mine in kept for u in mine), key=lambda u: (u["start"], u["end"]))
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
            answer = self._health_client.get(root + "/health")
            ok = answer.status_code == 200
            try:
                self.health_info = answer.json() if isinstance(answer.json(), dict) else {}
            except ValueError:
                self.health_info = {}
        except httpx.HTTPError:
            ok = False
        self._health = (now, ok)
        return ok
