# Install PicLight without a Developer ID

PicLight can be compiled locally with Command Line Tools and ad-hoc signed
(`codesign --sign -`). This requires no Apple account, Developer ID certificate
or paid Apple Developer Program membership. The signature checks the bundle's
integrity; it does not provide an Apple-verified publisher identity or notarization.

## Homebrew: compile on your Mac

Requirements: Homebrew, Swift 6+ and a macOS 26+ SDK supplied by Command Line
Tools. The app runs on macOS 14+, while installing a recent CLT package may
require a newer build host. The formula checks the actual CLT SDK before building.

The repository itself supplies the [Formula](../../Formula/piclight.rb), so it
uses a custom tap URL. These commands require a published `main` revision
containing the Formula and `Resources/Precompiled/`; old revisions lack them.
The formula follows `main` (`HEAD`), rather than an older release archive.

```bash
brew tap --custom-remote realdgd/piclight https://github.com/realDGD/PicLight.git
brew install --HEAD --build-from-source realdgd/piclight/piclight
```

If Homebrew asks you to trust this third-party formula, review its source and
approve only that formula. On Homebrew versions providing the trust command:

```bash
brew trust --formula realdgd/piclight/piclight
brew install --HEAD --build-from-source realdgd/piclight/piclight
```

The Formula compiles Swift / C on your Mac, copies validated precompiled icon
and Metal resources, ad-hoc signs the app and installs it under Homebrew's
Cellar. It neither downloads a prebuilt PicLight app nor needs a signing
certificate. It does not install Xcode, switch `xcode-select`, or update resource
caches. An unavailable or outdated CLT must be installed or updated separately.
See [Homebrew's tap guide](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)
for the tap and trust model.

Run the installed app:

```bash
open "$(brew --prefix)/opt/piclight/PicLight.app"
```

Optional Finder / Launchpad link, without overwriting an existing app:

```bash
mkdir -p "$HOME/Applications"
ln -s "$(brew --prefix)/opt/piclight/PicLight.app" "$HOME/Applications/PicLight.app"
```

This link follows the current Homebrew version after upgrades. If the destination
already exists, `ln` stops; keep or remove the old installation deliberately.
Quit PicLight before upgrading:

```bash
brew update
brew upgrade --fetch-HEAD --build-from-source realdgd/piclight/piclight
brew test realdgd/piclight/piclight
```

The formula test checks resources, signature and a headless Metal probe; it does
not open a viewer window. Uninstall with `brew uninstall realdgd/piclight/piclight`
and remove the optional Applications symlink if you created it. Preferences remain
at `~/Library/Preferences/com.example.picviewmac.plist`.

## Build directly from a checkout

Use a checkout containing the cached resources:

```bash
git clone https://github.com/realDGD/PicLight.git
cd PicLight
bash scripts/build-release.sh
bash scripts/make-dmg.sh
```

The build script defaults to CLT within its own process, validates resource input
hashes and targets, compiles the main executable, and signs `dist/PicLight.app`.
It preserves the previous app if building, assembly or signing fails. It does not
change the global developer directory. An explicit `DEVELOPER_DIR` is respected.

Only when the icon, shader, deployment target or resource recipe changes, refresh
the cached resources on a machine with the installed resource compiler toolchain:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 scripts/precompile-resources.py update
python3 scripts/precompile-resources.py check
```

Unchanged resources do not invoke compilers. `--force` refreshes both resources.
`--minimum-system-version` defaults to `14.0` and must match the app builder's
`MINIMUM_SYSTEM_VERSION`. Store the artifacts and manifest together. Updating
resources does not install tools or switch `xcode-select`. Classic icon updates
are described in [AppIcon](../../Resources/AppIcon/README.md).

Targeted script checks do not open windows or run the Swift suite:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -p 'test_precompiled_resources.py' -v
```

Homebrew sets `PICLIGHT_SWIFTPM_DISABLE_SANDBOX=1` for the two SwiftPM build calls,
because its outer sandbox cannot contain a second SwiftPM sandbox. Ordinary app
builds keep SwiftPM's default sandbox. Installed app checks can be run with
`brew test realdgd/piclight/piclight`; actual GUI use is separate.

## Downloaded app / DMG

Open `PicLight-0.1.0.dmg`, drag **PicLight** onto **Applications**, then open it.
This independently distributed bundle has no Apple notarization ticket. If macOS
blocks an app you trust, attempt to open it, then use **System Settings → Privacy
& Security → Open Anyway** for that app. Follow
[Apple's instructions](https://support.apple.com/en-us/102445).

Local compilation avoids depending on the distributor's Developer ID certificate;
it does not guarantee approval under every Gatekeeper or managed-device policy.
No installation command here disables Gatekeeper, removes quarantine attributes,
or changes system security settings. A damaged-app warning can also indicate
corruption or an invalid signature: verify the bundle and its source before
approving it, rather than assuming the warning only means missing notarization.
