#!/usr/bin/env python3
"""Differential check against Swanium (the reference implementation).

Runs a ROM for N frames on Gooswan (tools/sst run) and on swanium-core
(tools/swprobe, built against a sibling Swanium checkout) with the same
key script, then reports the first frame whose framebuffer differs, how
many final pixels / WRAM bytes differ, and the audio RMS difference.

usage: diff_swanium.py <rom> [frames=600] [keys=-] [model]
       diff_swanium.py --list <file-with-rom-paths> [frames]
"""
import os, subprocess, sys, tempfile, math, struct

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SST = os.environ.get("SST", os.path.join(ROOT, "tools", "sst"))
PROBE = os.environ.get("SWPROBE", os.path.join(ROOT, "tools", "swprobe", "target", "release", "swprobe"))


def run(rom, frames, keys, model, tmp):
    g, s = os.path.join(tmp, "g"), os.path.join(tmp, "s")
    margs = [model] if model else []
    subprocess.run([SST, "run", rom, str(frames), g, keys] + margs, capture_output=True, check=False)
    subprocess.run([PROBE, rom, str(frames), s, keys] + margs, capture_output=True, check=False)
    return g, s


def read(p, mode="rb"):
    try:
        with open(p, mode) as f:
            return f.read()
    except OSError:
        return None


def compare(rom, frames=600, keys="-", model=""):
    with tempfile.TemporaryDirectory() as tmp:
        g, s = run(rom, frames, keys, model, tmp)
        gh, sh = read(g + ".hashes", "r"), read(s + ".hashes", "r")
        if gh is None or sh is None:
            return {"rom": rom, "error": "missing output"}
        gh, sh = gh.split(), sh.split()
        first = next((i for i, (a, b) in enumerate(zip(gh, sh)) if a != b), None)
        if first is None and len(gh) != len(sh):
            first = min(len(gh), len(sh))
        same = sum(1 for a, b in zip(gh, sh) if a == b)
        gp, sp = read(g + ".ppm"), read(s + ".ppm")
        px = sum(1 for i in range(15, len(gp), 3) if gp[i:i + 3] != sp[i:i + 3]) if gp and sp else -1
        gr, sr = read(g + ".ram"), read(s + ".ram")
        ram = sum(1 for a, b in zip(gr, sr) if a != b) if gr and sr else -1
        ga, sa = read(g + ".pcm") or b"", read(s + ".pcm") or b""
        n = min(len(ga), len(sa)) // 2
        rms = 0.0
        if n:
            a = struct.unpack("<%dh" % n, ga[:n * 2]); b = struct.unpack("<%dh" % n, sa[:n * 2])
            rms = math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b)) / n)
        return {"rom": rom, "frames": len(gh), "first_diff": first, "same_frames": same,
                "final_px_diff": px, "ram_diff": ram, "audio_rms_diff": round(rms, 1),
                "audio_len": (len(ga) // 4, len(sa) // 4)}


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--list":
        frames = int(sys.argv[3]) if len(sys.argv) > 3 else 600
        for line in open(sys.argv[2]):
            rom = line.strip()
            if rom:
                r = compare(rom, frames)
                print(f"{r.get('first_diff')!s:>6} {r.get('final_px_diff')!s:>6} {r.get('ram_diff')!s:>6} {r.get('audio_rms_diff')!s:>8}  {os.path.basename(rom)}", flush=True)
    else:
        a = sys.argv[1:]
        print(compare(a[0], int(a[1]) if len(a) > 1 else 600, a[2] if len(a) > 2 else "-", a[3] if len(a) > 3 else ""))
