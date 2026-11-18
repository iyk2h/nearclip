"""Original quiet electronic bed; no external audio or samples."""
import math, struct, wave
from pathlib import Path
rate, duration = 48000, 40
out = Path(__file__).with_name('soundtrack.wav')
notes = (220.0, 329.6276, 440.0, 493.8833, 277.1826, 415.3047, 554.3653, 415.3047)
clicks = (5.0, 11.0, 14.8, 19.0, 22.0, 24.0, 28.0, 34.0)
peak = 0.0
with wave.open(str(out), 'wb') as wav:
    wav.setparams((2, 2, rate, 0, 'NONE', 'not compressed'))
    buf = bytearray()
    for i in range(rate * duration):
        t = i / rate
        fade = min(1, t / 2, (duration-t) / 2)
        root = 110.0 if int(t / 8) % 2 == 0 else 138.5913
        pad = 0.023 * math.sin(2*math.pi*root*t) + 0.013 * math.sin(2*math.pi*root*1.5*t)
        beat = t % 0.75
        note = notes[int(t/0.75) % len(notes)]
        arp = 0.017 * (1-math.exp(-beat*90)) * math.exp(-beat*6) * math.sin(2*math.pi*note*t)
        accent = 0.0
        for click in clicks:
            d=t-click
            if 0 <= d < 0.16:
                accent += 0.038 * math.exp(-d*36) * math.sin(2*math.pi*(800*d-850*d*d))
        val = fade*(pad+arp+accent)
        peak=max(peak,abs(val))
        sample=int(max(-1,min(1,val))*32767)
        buf.extend(struct.pack('<hh',sample,sample))
        if len(buf)>=192000: wav.writeframesraw(buf); buf.clear()
    wav.writeframesraw(buf)
assert peak < 0.2
with wave.open(str(out),'rb') as check:
    assert check.getnframes()==rate*duration and check.getnchannels()==2
print(f'PASS: original 40s stereo soundtrack, peak {20*math.log10(peak):.1f} dBFS')
