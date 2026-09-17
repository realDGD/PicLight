# Animation energy A/B (same session, 2026-09-18)

Question: is the animated path's per-drawn-frame energy above the recorded baseline because of a
real regression, or because an archived number was being compared against a fresh one?

Method: `sample-animation.sh` builds one instrumented app per arm and runs the same 20 s animated
fixture (`anim-1000.gif`, 1 MPixel, 30 frames, 40 ms) N times through the production path. The
baseline arm is revision 123d943, instrumented with the whole-file overlay of its era (the
anchored instrumentation cannot instrument it; the energy counter and the draw/ping counters are
byte-identical between the two forms, checked with `git show`).

| arm | samples | draws | energy | per drawn frame | ping p95 | ping max |
| --- | --- | --- | --- | --- | --- | --- |
| baseline 123d943 (Quartz) | 8 | 319.9 (316–329) | 102.6 J (99.0–109.8) | 320.8 mJ (304–338) | 82 ms | 111 ms |
| HEAD, Metal on | 5 | 319.8 (313–325) | 88.5 J (85.8–90.2) | 276.9 mJ (264–287) | 86 ms | 193 ms |
| HEAD, Metal off (`PICLIGHT_DISABLE_METAL=1`) | 5 | 297.0 (290–302) | 84.3 J (82.8–85.9) | 283.9 mJ (276–292) | 87 ms | 126 ms |

## Finding: the residual was a cross-session artefact, not a regression

The archived baseline (`results/gates-E5-animation.txt`) reads 78.1 J and 249 mJ per drawn frame.
That number **does not reproduce**: the same baseline code, measured today, gives 99.0–109.8 J and
304–338 mJ per drawn frame (two rounds of samples, 8 runs). Energy on this machine is
session-sensitive — swap is 3.7 GiB used with ~1.4 GiB free and load average ~2.4 — so an absolute
energy figure from one session cannot be compared with a figure from another.

Within one session the ordering is the opposite of a regression:

- per drawn frame: HEAD 277–284 mJ against the baseline's 313–321 mJ, i.e. **11–14 % lower**;
- open energy for the same 20 s of playback: HEAD 84.3–88.5 J against 99.4–104.5 J, **15–19 % lower**;
- cadence is unchanged (319.8 vs 319.9 draws per 20 s).

Metal on versus off inside HEAD is within noise per frame (276.9 vs 283.9 mJ, spreads 8.2 % and
5.7 %), but Metal delivers more frames in the same window (319.8 vs 297.0 draws, 346 vs 325 frames
applied) for ~5 % more energy: on this content the renderer buys cadence rather than saving power.
One Metal-on sample shows a single 193 ms ping spike (p95 stays 86 ms in every run, and the
criterion is p95).

## Consequence for the spec

§16's animation criterion is restated as a same-session A/B with the baseline arm measured in the
same sitting, because that is the only comparison this measurement supports. The absolute
"249 mJ per drawn frame" figure is recorded as non-reproducible rather than as a target.
