# PicLight — app icon (shipped)

The icon `PicLight.app` carries. Two files, two code paths, both shipped:

| File | Path into the bundle | Who reads it |
| --- | --- | --- |
| `PicLight.icon/` | compiled by `actool` → `Contents/Resources/Assets.car` | macOS 26 / 27 (`CFBundleIconName`) — the icon stack, so the system renders the light, dark, clear and tinted appearances itself |
| `PicLight.icns` | `Contents/Resources/PicLight.icns` | macOS 14 / 15 (`CFBundleIconFile`) — flat renditions on the classic grid |

`scripts/build-release.sh` does that compilation and writes both Info.plist keys;
`scripts/verify-release.sh` checks the result (33 checks, 9 of them icon checks).
Nothing loads an icon at runtime: macOS reads app icons out of the bundle, which is
why the icon exists only in `dist/PicLight.app` and not in a bare `swift build`
executable.

**Currently shipped: v4 "native"** — a gloved hand holding a flashlight with a
warm beam; no tile art, no glass layer, no shadow of its own. The document is
`PicLight.icon/icon.json`; the review package with Apple renders at every
appearance is `design/AppIcon-native-v4/`.

## Switching between the reviewed versions

```bash
cp -R design/AppIcon-native-v4/PicLight.icon Resources/AppIcon/PicLight.icon      # v4 (current)
# cp -R design/AppIcon-transparency-v3/build/middle.icon Resources/AppIcon/PicLight.icon   # v3
Resources/AppIcon/build-icons.sh                                                  # repack the loose .icns
./scripts/build-release.sh && ./scripts/make-dmg.sh
./scripts/verify-release.sh
```

`build-icons.sh` reproduces a reviewed `.icns` byte-for-byte: run on the v4
document it packs the identical file the v4 package shipped
(`890acf31…`, checked with `cmp`).

| Version | Where | What differs |
| --- | --- | --- |
| **v4 native** (shipped) | `design/AppIcon-native-v4/` | flat solid fill (`0.985` / dark `0.065`), `specular` off, `shadow` 0, no glass layer, no `features` |
| v3 transparency | `design/AppIcon-transparency-v3/build/{clear,middle,tinted}.icon` | light fill alpha 0.05 / 0.18 / 0.45, foreground `specular` + shadow 0.12, plus a self-drawn glass layer (`Assets/glass.svg`, `glass: true`, translucency 0.8) and `features: ["refractivity","specular-location"]` |
| v2 reference-style | `design/AppIcon-staged-v2/` | gradient blue plate, different artwork language |

`dist/icon-review/` held ad-hoc copies that differed only in their icon
(`PicLight v4`, `PicLight v4 Min26`, `PicLight v3 Clear/Middle/Tinted`), built so
the live rendering could be compared side by side while the version was being
decided. **v4 is the final choice; that set has been removed** and `dist/` holds
only `PicLight.app` and `PicLight-0.1.0.dmg`. To rebuild such a copy:
`cp -R dist/PicLight.app /tmp/x.app`, swap in an `Assets.car` and `.icns` compiled
from another document, set a distinct `CFBundleIdentifier` with `PlistBuddy`, then
`codesign --force --deep --sign - /tmp/x.app` (throwaway ids only — never ship one).

### What a static export cannot show — read this before judging an icon

`ictool --export-image` flattens the document, and flattening drops exactly the
things that make the new icon look like the new icon. Measured on this project:

- the three v3 documents render **byte-identically** (same SHA-256 at every
  appearance and design generation; the tile stays 61.2% alpha-covered in all
  three) — the fill alpha does not survive the export;
- `specular`, `shadow`, `translucency`, `refractivity` and the `glass` material are
  applied by the system when it composites the icon stack, so they are absent from
  every PNG in the design packages;
- consequently v3 and v4 differ in the PNGs by a faint blue inset panel and almost
  nothing else, while in the Dock they differ by the whole material.

So this icon can only be judged on a desktop, and only with
**System Settings → Appearance → "Icon & widget style"** left at **Default**:
that setting decides whether app icons follow light/dark at all (Clear and Tinted
replace the artwork with the system's monochrome/clear rendering).

## Files and hashes (v4, as shipped)

```
890acf31e6760313b818dbf5afb7e871f80b9fbf9ec24bc9bd30a7b657537cb9  PicLight.icns
51bb38714520d66e9c62c8ba001d89763d4fd91822b5d6b628b23c26cd6ed4b0  PicLight.icon/icon.json
ee0c262277941f3924539806c70980f8f614c3de6d4419c87f1d9a8feff857b6  PicLight.icon/Assets/foreground.png
7cb1981029fc2be88605d90edd65546a2692bc40be4471dc75ee98c987b7ce45  PicLight.icon/Assets/beam.svg
```

`Assets.car` is not committed: it is compiled at release time from the document
next to it by `scripts/build-release.sh`.

### Why the `.icns` is packed by hand

`actool` also emits a `PicLight.icns` next to `Assets.car`, but it only carries
16–256 px (measured: 4 entries) — the document is full-bleed artwork and there is
no 512/1024 flat source for `actool` to flatten, so Finder on macOS 14/15 would
draw it upscaled. `build-icons.sh` packs the loose `.icns` on the classic
824/1024 grid instead — `alpha bbox side/canvas 0.8477` at 1024, against 0.8516
measured on Apple's own system icons.

## Cost and what is not verified

- `actool` is required for the macOS 26/27 icon. `PICLIGHT_ALLOW_LOOSE_ICON=1`
  builds without it and ships only the `.icns`, which macOS 26/27 wraps in its own
  generic material; `verify-release.sh` then reports the icon stack as SKIPPED
  rather than passing it.
- Finder and the Dock cache icons per path. A bundle rebuilt at a path the icon
  cache has already seen — including one it saw before the icon existed — can keep
  showing the old or generic icon, so the verification probes a fresh copy.
  `lsregister -f <app>` refreshes LaunchServices; the IconServices cache is only
  reliably cleared by logging out or restarting.
- No separate macOS 14/15/26 installation was tested, and no live wallpaper
  compositing was measured from this repository — that needs eyes on a desktop.
