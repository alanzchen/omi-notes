#!/usr/bin/env python3
"""Regenerate the simulated-device trace and the OmiKit test Opus packets.

Needs macOS `say` and ffmpeg with libopus. Encodes speech exactly like the CV1 firmware's mode
(Opus CELT-only "restricted lowdelay", 16 kHz mono, 20 ms frames, ~32 kbps VBR) and writes:

  OmiNotes/Resources/simulated_trace.omitrace
      "OMITRC01" + entries [t_offset_us u32 LE][len u16 LE][seq u16 LE][fragment_index u8][opus]
      (the simulated device rewrites seq at replay time)
  Packages/OmiKit/Tests/OmiCaptureTests/Resources/opus_packets.bin
      [len u16 LE][opus] x 64

Usage: cd ios && python3 Tools/make_sim_trace.py
"""
import os, struct, subprocess, tempfile

TEXT = ("Okay, so let's go over the plan for next week. The budget review is on Tuesday at ten, "
        "and Priya will send the draft numbers tomorrow. Remind me to book the conference room. "
        "Also, we still need to decide whether the launch moves to October.")

def ogg_packets(data):
    off, cur, out = 0, b"", []
    while off < len(data):
        assert data[off:off + 4] == b"OggS"
        nseg = data[off + 26]
        lacing = data[off + 27:off + 27 + nseg]
        body = off + 27 + nseg
        for l in lacing:
            cur += data[body:body + l]
            body += l
            if l < 255:
                out.append(cur)
                cur = b""
        off = body
    assert out[0].startswith(b"OpusHead") and out[1].startswith(b"OpusTags")
    return out[2:]

def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ios = os.path.dirname(here)
    with tempfile.TemporaryDirectory() as tmp:
        aiff, opus = os.path.join(tmp, "s.aiff"), os.path.join(tmp, "s.opus")
        subprocess.run(["say", "-v", "Samantha", "-o", aiff, TEXT], check=True)
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", aiff, "-ar", "16000", "-ac", "1",
                        "-c:a", "libopus", "-application", "lowdelay", "-b:a", "32k", "-vbr", "on",
                        "-frame_duration", "20", "-compression_level", "3", opus], check=True)
        packets = ogg_packets(open(opus, "rb").read())
    jitter = [0, 3000, 1000, 4000, 2000]
    trace = bytearray(b"OMITRC01")
    for i, p in enumerate(packets):
        note = struct.pack("<HB", i & 0xFFFF, 0) + p
        trace += struct.pack("<IH", i * 20000 + jitter[i % 5], len(note)) + note
    with open(os.path.join(ios, "OmiNotes/Resources/simulated_trace.omitrace"), "wb") as f:
        f.write(trace)
    with open(os.path.join(ios, "Packages/OmiKit/Tests/OmiCaptureTests/Resources/opus_packets.bin"), "wb") as f:
        for p in packets[100:164]:
            f.write(struct.pack("<H", len(p)) + p)
    print(f"{len(packets)} packets ({len(packets) * 0.02:.1f} s); trace {len(trace)} bytes")

if __name__ == "__main__":
    main()
