"""The align+v pipeline with the three models in one process (loaded on first use, unloaded when idle).

MOSS-Transcribe-Diarize gives the lines (start, end, speaker) per window; Qwen3-ASR-1.7B transcribes the
same audio in <= 180 s chunks cut at MOSS pauses, with the request's context terms as hotwords;
Qwen3-ForcedAligner times each unit, which goes to the MOSS line that holds it. MOSS never gets a prompt
(in mlx-audio a prompt replaces its instruction and the timestamps are lost).
"""

from __future__ import annotations

import gc
import logging
import os
import threading
import time

import numpy as np

from . import plan
from .merge import assign, moss_lines, spans_for

log = logging.getLogger("omi_asr")

MOSS = os.environ.get("OMI_ASR_MOSS", "OpenMOSS-Team/MOSS-Transcribe-Diarize")
QWEN = os.environ.get("OMI_ASR_QWEN", "mlx-community/Qwen3-ASR-1.7B-bf16")
ALIGNER = os.environ.get("OMI_ASR_ALIGNER", "mlx-community/Qwen3-ForcedAligner-0.6B-bf16")
ALIGN_LANGUAGE = os.environ.get("OMI_ASR_ALIGN_LANGUAGE", "Chinese")  # the bench's setting for mixed zh/en
IDLE_UNLOAD_SECONDS = float(os.environ.get("OMI_ASR_IDLE_UNLOAD", "900"))
MAX_RESPLIT_DEPTH = 3


class Engine:
    def __init__(self) -> None:
        self.lock = threading.Lock()  # one request at a time: the models share one GPU
        self.models: tuple | None = None
        self.last_used = 0.0
        self.load_seconds: float | None = None

    # -- models ----------------------------------------------------------------------------------

    def _load(self) -> tuple:
        if self.models is None:
            os.environ.setdefault("HF_HUB_OFFLINE", "1")  # the models are already in the HF cache: never download
            import mlx.core as mx
            from mlx_audio.stt.utils import load_model

            t = time.perf_counter()
            models = tuple(load_model(repo) for repo in (MOSS, QWEN, ALIGNER))
            for m in models:
                mx.eval(m.parameters())
            self.models = models
            self.load_seconds = round(time.perf_counter() - t, 2)
            log.info("models loaded in %.1f s", self.load_seconds)
        return self.models

    def unload_if_idle(self) -> bool:
        with self.lock:
            if self.models is None or time.monotonic() - self.last_used < IDLE_UNLOAD_SECONDS:
                return False
            import mlx.core as mx

            self.models = None
            gc.collect()
            mx.clear_cache()
            log.info("models unloaded after %.0f s idle", IDLE_UNLOAD_SECONDS)
            return True

    @property
    def loaded(self) -> bool:
        return self.models is not None

    # -- pipeline --------------------------------------------------------------------------------

    def transcribe(self, pcm: np.ndarray, context: list[str]) -> dict:
        """16 kHz float32 mono → {text, language, duration, segments[{start, end, speaker_id, text}], omi_asr}."""
        with self.lock:
            import mlx.core as mx

            moss, qwen, aligner = self._load()
            mx.reset_peak_memory()
            t0 = time.perf_counter()
            duration = len(pcm) / plan.SR
            stats = {"windows": 0, "resplits": 0, "truncated_unresolved": 0, "unlabeled_windows": 0, "qwen_chunks": 0,
                     "qwen_capped": 0, "units": 0, "units_outside_lines": 0, "lines_with_moss_text": 0}  # fmt: skip
            lines: list[dict] = []
            languages: list[str] = []
            for k, (a, b) in enumerate(plan.plan_windows(pcm)):
                for sub, (lines_w, start, stop) in enumerate(self._moss(moss, pcm, a, b, 0, stats)):
                    prefix = "" if (k, sub) == (0, 0) else f"W{k + 1}.{sub + 1}-"
                    for line in lines_w:
                        line["speaker"] = prefix + line["speaker"]
                    lines.extend(self._text(qwen, aligner, pcm, start, stop, lines_w, context, stats, languages, prefix))
            t_total = time.perf_counter() - t0
            self.last_used = time.monotonic()
            lines.sort(key=lambda s: (s["start"], s["end"]))
            segments = [{"start": round(s["start"], 3), "end": round(s["end"], 3), "speaker_id": s["speaker"], "text": s["text"]}
                        for s in lines if s["text"]]  # fmt: skip
            return {
                "text": " ".join(s["text"] for s in segments),
                "language": max(set(languages), key=languages.count) if languages else None,
                "duration": round(duration, 3),
                "segments": segments,
                "omi_asr": dict(stats, seconds=round(t_total, 2), rtf=round(t_total / max(duration, 1e-6), 4),
                                peak_mlx_gb=round(mx.get_peak_memory() / 1e9, 2), load_seconds=self.load_seconds),  # fmt: skip
            }

    def _moss(self, moss, pcm: np.ndarray, a: float, b: float, depth: int, stats: dict) -> list[tuple[list[dict], float, float]]:
        """MOSS on [a, b] (absolute s): [(lines, window start, window end)], cut again at the middle pause
        while truncated."""
        import mlx.core as mx

        window = pcm[round(a * plan.SR) : round(b * plan.SR)]
        seconds = len(window) / plan.SR
        cap = plan.moss_max_tokens(seconds)
        r = moss.generate(mx.array(window), max_tokens=cap)
        stats["windows"] += 1
        relative = moss_lines(r.segments)
        if plan.is_truncated(relative, int(r.generation_tokens), cap, plan.speech_end(window)):
            if depth < MAX_RESPLIT_DEPTH and seconds > 120:
                cut = a + plan.middle_cut(window, 0.0, seconds)
                stats["resplits"] += 1
                log.warning("MOSS truncated on %.0f s (tokens %d/%d): cutting at %.1f s", seconds, r.generation_tokens, cap, cut)
                return self._moss(moss, pcm, a, cut, depth + 1, stats) + self._moss(moss, pcm, cut, b, depth + 1, stats)
            # Qwen still hears the whole window; its words past MOSS's last line go to the nearest line
            stats["truncated_unresolved"] += 1
            log.warning("MOSS still truncated on %.0f s at %.0f s (tokens %d/%d)", seconds, a, r.generation_tokens, cap)
        return [(moss_lines(r.segments, offset=a), a, b)]

    def _text(self, qwen, aligner, pcm: np.ndarray, start: float, stop: float, lines: list[dict], context: list[str],
              stats: dict, languages: list[str], prefix: str = "") -> list[dict]:  # fmt: skip
        """Qwen text on <= 180 s chunks of the whole window [start, stop] (speech MOSS left out included),
        aligned onto its MOSS lines."""
        import mlx.core as mx

        relative = [dict(s, start=s["start"] - start, end=s["end"] - start) for s in lines]
        units = []
        cuts = plan.chunk_cuts(relative, stop - start)
        for a, b in zip(cuts, cuts[1:], strict=False):
            chunk = pcm[round((start + a) * plan.SR) : round((start + b) * plan.SR)]
            if len(chunk) < plan.SR // 10:
                continue
            padded = np.pad(chunk, (0, plan.SR - len(chunk))) if len(chunk) < plan.SR else chunk
            cap = plan.qwen_max_tokens(len(chunk) / plan.SR)
            r = qwen.generate(mx.array(padded), hotwords=context or None, max_tokens=cap)
            stats["qwen_chunks"] += 1
            if int(getattr(r, "generation_tokens", 0) or 0) >= cap:  # a repetition loop: keep MOSS's text here
                stats["qwen_capped"] += 1
                log.warning("Qwen hit its cap on a %.0f s chunk: keeping MOSS text there", len(chunk) / plan.SR)
                continue
            text = (r.text or "").strip()
            reported = getattr(r, "language", None)  # mlx-audio 0.6.3 gives a list of names, e.g. ["English"]
            for name in reported if isinstance(reported, (list, tuple)) else [reported]:
                if isinstance(name, str) and name.strip() and name.strip().lower() != "none":
                    languages.append(name.strip())
            if not text:
                continue
            res = aligner.generate(chunk, text=text, language=ALIGN_LANGUAGE)
            units.extend(spans_for(text, [(it.text, float(it.start_time), float(it.end_time)) for it in res.items], start + a))
        if not lines:
            if not units:
                return []
            # MOSS found no speaker here but Qwen heard words: keep them under one label rather than drop them
            stats["unlabeled_windows"] += 1
            log.warning("MOSS found no lines in %.0f-%.0f s: %d words kept under one label", start, stop, len(units))
            lines = [{"start": units[0].start, "end": units[-1].end, "speaker": prefix + "S00", "moss_text": ""}]
        merged, s = assign(lines, units)
        for key in ("units", "units_outside_lines", "lines_with_moss_text"):
            stats[key] += s[key]
        return merged
