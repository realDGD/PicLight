# PicLight app icon

`PicLight.icon/` contains the reviewed Icon Composer source. Its compiled
`Assets.car` is cached in [Precompiled](../Precompiled/README.md) and copied during
CLT packaging for `CFBundleIconName=PicLight`. The system renders supported
light, dark, clear and tinted appearances from the catalog.

`PicLight.icns` is the reviewed classic fallback, copied as `CFBundleIconFile=PicLight`.
It contains all 10 sizes from 16 through 1024 pixels; actool's generated ICNS has
fewer sizes, so packaging deliberately uses this complete file.

When changing the icon, update the source document and repack the classic icon:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash Resources/AppIcon/build-icons.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 scripts/precompile-resources.py update
```

The first command requires Icon Composer / ictool from the installed Xcode;
the second refreshes changed cached resources with actool and Metal tools.
Daily app builds need only CLT and the matching cached files. No command changes
the global developer directory. See the [installation and build guide](../../docs/release/unsigned-installation.md).

Catalog structure checks and byte hashes do not prove live Dock / Finder icon
appearance on every macOS version; that needs the corresponding desktop.
