# Verification

- Two foreground layers only; no custom outer-glass SVG or bitmap backdrop.
- Light/dark root fill channels are neutral (R = G = B).
- Foreground extra specular, translucency and shadow disabled; no SVG blur.
- 12 Apple renders: 6 appearances x design generations 26 and 27, each 1024 x 1024.
- actool succeeds at minimum deployment target 14.0, zero warnings/errors.
- Assets.car includes Aqua, DarkAqua and Tintable icon stacks and a MultiSized Image.
- Native ICNS round-trip: all 10 expected entries, correct 16–1024 pixel dimensions.
- Prior reference ICNS copied byte-for-byte.
- All 100 v2 files retain their original SHA-256.
- No application integration performed.

Limitations: no separate macOS 14/15/26 installation test, no App Store validation, no live wallpaper-compositing test. Icon Composer does not support responding to the system transparency slider, so automatic one-step mapping is not implemented.
