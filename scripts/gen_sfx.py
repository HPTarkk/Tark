#!/usr/bin/env python3
"""Synthesizes the app's UI sound-effect set into assets/sfx/*.wav.

Pure stdlib (wave/struct/math/random) — no numpy/ffmpeg dependency, so this
can be re-run anywhere to tweak a tone and regenerate the asset. Sounds are
short, layered sine tones with linear attack/release envelopes, meant to be
told apart by ear alone (motorcycle-in-pocket use case) rather than to be
subtle "modern app" chimes.
"""
import math
import os
import random
import struct
import wave

SR = 22050


def env_linear(n, attack, release, sr, sustain=1.0):
    a = max(1, min(int(attack * sr), n // 2 or 1))
    r = max(1, min(int(release * sr), n // 2 or 1))
    out = []
    for i in range(n):
        if i < a:
            out.append(sustain * i / a)
        elif i >= n - r:
            out.append(sustain * max(0.0, (n - i) / r))
        else:
            out.append(sustain)
    return out


def tone(freq, dur, sr=SR, attack=0.01, release=0.03, amp=0.8, harmonics=None):
    n = int(dur * sr)
    env = env_linear(n, attack, release, sr, amp)
    hsum = sum(h[1] for h in harmonics) if harmonics else 0.0
    out = []
    for i in range(n):
        t = i / sr
        s = math.sin(2 * math.pi * freq * t)
        if harmonics:
            for mult, hamp in harmonics:
                s += hamp * math.sin(2 * math.pi * freq * mult * t)
            s /= (1 + hsum)
        out.append(s * env[i])
    return out


def chirp(f0, f1, dur, sr=SR, attack=0.01, release=0.05, amp=0.8):
    n = int(dur * sr)
    env = env_linear(n, attack, release, sr, amp)
    out = []
    phase = 0.0
    for i in range(n):
        frac = i / n
        freq = f0 + (f1 - f0) * frac
        phase += 2 * math.pi * freq / sr
        out.append(math.sin(phase) * env[i])
    return out


def noise(dur, sr=SR, attack=0.005, release=0.05, amp=0.5, seed=1):
    rnd = random.Random(seed)
    n = int(dur * sr)
    env = env_linear(n, attack, release, sr, amp)
    return [rnd.uniform(-1, 1) * env[i] for i in range(n)]


def lowpass(samples, alpha):
    out = []
    prev = 0.0
    for s in samples:
        prev = prev + alpha * (s - prev)
        out.append(prev)
    return out


def silence(dur, sr=SR):
    return [0.0] * int(dur * sr)


def concat(*parts):
    out = []
    for p in parts:
        out.extend(p)
    return out


def mix(*parts):
    n = max(len(p) for p in parts)
    out = [0.0] * n
    for p in parts:
        for i, s in enumerate(p):
            out[i] += s
    peak = max((abs(x) for x in out), default=1.0) or 1.0
    if peak > 1.0:
        out = [x / peak for x in out]
    return out


def write_wav(path, samples, sr=SR):
    clamped = [max(-1.0, min(1.0, s)) for s in samples]
    ints = [int(s * 32767) for s in clamped]
    with wave.open(path, 'w') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(struct.pack('<%dh' % len(ints), *ints))


def build():
    sounds = {}

    # Rising 2-tone blip — VOX gate opens (I start transmitting).
    sounds['ptt_open'] = lowpass(concat(
        tone(700, 0.045, attack=0.004, release=0.012, amp=0.75),
        silence(0.005),
        tone(1050, 0.055, attack=0.004, release=0.018, amp=0.75),
    ), 0.55)

    # Descending 2-tone blip — VOX gate closes.
    sounds['ptt_close'] = lowpass(concat(
        tone(1050, 0.045, attack=0.004, release=0.012, amp=0.7),
        silence(0.005),
        tone(650, 0.06, attack=0.004, release=0.02, amp=0.7),
    ), 0.55)

    # Soft single tick — someone else starts talking (RX).
    sounds['rx_start'] = lowpass(
        tone(900, 0.09, attack=0.015, release=0.045, amp=0.45), 0.45)

    # Ascending 3-note chime — peer/BT/guest/hotspot connects.
    sounds['peer_join'] = concat(
        tone(523.25, 0.07, attack=0.006, release=0.03, amp=0.7),
        silence(0.008),
        tone(659.25, 0.07, attack=0.006, release=0.03, amp=0.7),
        silence(0.008),
        tone(784.0, 0.13, attack=0.006, release=0.06, amp=0.75),
    )

    # Descending 2-note chime — peer goes stale/leaves.
    sounds['peer_leave'] = concat(
        tone(659.25, 0.09, attack=0.006, release=0.035, amp=0.6),
        silence(0.01),
        tone(493.88, 0.15, attack=0.006, release=0.08, amp=0.6),
    )

    # Soft double-beep alert — link drops, auto-retry begins.
    sounds['link_lost'] = concat(
        tone(480, 0.09, attack=0.006, release=0.02, amp=0.7,
             harmonics=[(3, 0.25)]),
        silence(0.06),
        tone(480, 0.09, attack=0.006, release=0.03, amp=0.7,
             harmonics=[(3, 0.25)]),
    )

    # Bright ascending ping — link recovers.
    sounds['link_restored'] = mix(
        chirp(600, 1200, 0.2, attack=0.008, release=0.12, amp=0.7),
        concat(silence(0.02), tone(1800, 0.12, attack=0.01, release=0.09, amp=0.15)),
    )

    # Low triple-blip buzz — permission denied / capture stalled / BT failure.
    def error_blip():
        return tone(220, 0.05, attack=0.004, release=0.015, amp=0.7,
                    harmonics=[(3, 0.35), (5, 0.2)])
    sounds['error'] = concat(
        error_blip(), silence(0.04),
        error_blip(), silence(0.04),
        error_blip(),
    )

    # Short soft click — mute / music-cast toggle / SFX toggle itself.
    sounds['toggle'] = mix(
        lowpass(noise(0.012, attack=0.001, release=0.01, amp=0.5, seed=7), 0.35),
        tone(1200, 0.02, attack=0.001, release=0.015, amp=0.35),
    )

    # Rising "power-on" swell — entering a channel/session.
    sounds['channel_join'] = mix(
        lowpass(noise(0.42, attack=0.05, release=0.3, amp=0.3, seed=3), 0.12),
        chirp(300, 900, 0.35, attack=0.08, release=0.2, amp=0.55),
    )

    # Falling "power-down" swell — leaving a channel (confirmed).
    sounds['channel_leave'] = mix(
        lowpass(noise(0.36, attack=0.02, release=0.3, amp=0.25, seed=5), 0.12),
        chirp(900, 280, 0.3, attack=0.01, release=0.22, amp=0.55),
    )

    return sounds


def main():
    out_dir = os.path.join(os.path.dirname(__file__), '..', 'assets', 'sfx')
    out_dir = os.path.abspath(out_dir)
    os.makedirs(out_dir, exist_ok=True)
    for name, samples in build().items():
        path = os.path.join(out_dir, f'{name}.wav')
        write_wav(path, samples)
        print(f'wrote {path} ({len(samples) / SR * 1000:.0f} ms)')


if __name__ == '__main__':
    main()
