# Installing PicViewMac without a Developer ID

PicViewMac v0.1 is distributed as an independent `.app` / `.dmg`. It is **not**
notarized, because v0.1 deliberately does not require a paid Apple Developer
Program membership. The bundle is ad-hoc signed (`codesign --sign -`) so its
structure is intact, but Gatekeeper will still ask for confirmation on first
launch. That is expected.

## Install

1. Open `PicViewMac-0.1.0.dmg`.
2. Drag **PicViewMac** onto the **Applications** shortcut.
3. Open **Applications** → **PicViewMac**.

## If macOS blocks the first launch

macOS shows *“PicViewMac” cannot be opened because the developer cannot be
verified* (or *…is damaged and can’t be opened*, which in this case means the
same thing: no notarization ticket).

Do this:

1. Attempt to open the app once so macOS records the block.
2. Open **System Settings → Privacy & Security**.
3. Scroll to **Security**. A line about **PicViewMac** appears with an
   **Open Anyway** button.
4. Click **Open Anyway**, authenticate, and confirm **Open** in the dialog.

You only do this once per installed copy.

## What you should *not* do

Please do not work around this by weakening your system:

- do **not** run `spctl --master-disable`;
- do **not** disable System Integrity Protection (SIP);
- do **not** turn Gatekeeper off globally;
- do **not** `xattr -dr com.apple.quarantine` files from untrusted sources.

The per-app **Open Anyway** path exists exactly for independently distributed
software like this, and it keeps the rest of your Mac protected.

## Build it yourself instead

If you would rather not trust a prebuilt bundle, build from source:

```bash
git clone <this repository>
cd PicLight
./scripts/build-release.sh     # produces dist/PicViewMac.app, ad-hoc signed
./scripts/make-dmg.sh          # produces dist/PicViewMac-0.1.0.dmg
```

`build-release.sh` runs `codesign --verify --deep --strict` on the result and
fails if the signature is not structurally valid.

## Uninstall

Delete `PicViewMac.app` from Applications. Settings live in
`~/Library/Preferences/com.example.picviewmac.plist`; delete it if you want a
clean slate.
