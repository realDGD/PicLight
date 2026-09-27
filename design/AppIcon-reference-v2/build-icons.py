#!/usr/bin/env python3
"""Re-export only this review directory. Does not modify or build PicLight.app."""
import json
import pathlib
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent
DEVELOPER = pathlib.Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
ICT = DEVELOPER.parent / 'Applications/Icon Composer.app/Contents/Executables/ictool'
if not ICT.is_file():
    raise SystemExit('Icon Composer from Xcode 27 is required for this document.')

def run(*args):
    return subprocess.run([str(a) for a in args], check=True, capture_output=True, text=True)

def render(doc, destination, appearance='Default', generation=27):
    args = [ICT, doc, '--export-image', '--output-file', destination,
            '--platform', 'macOS', '--rendition', appearance,
            '--width', '1024', '--height', '1024', '--scale', '1',
            '--design-generation', str(generation)]
    if appearance.startswith('Tinted'):
        args += ['--tint-color', '0.14', '--tint-strength', '0.8']
    run(*args)

for directory in ['build', 'preview/native', 'reference', 'legacy', 'verification/compiled']:
    (ROOT / directory).mkdir(parents=True, exist_ok=True)
for name in ['export-grid', 'preview']:
    run('swiftc', '-O', ROOT / f'tools/{name}.swift', '-o', ROOT / f'build/{name}')

for generation in [26, 27]:
    for mode in ['Default', 'Dark', 'ClearLight', 'ClearDark', 'TintedLight', 'TintedDark']:
        render(ROOT / 'PicLight.icon', ROOT / f'preview/native/{mode}-{generation}.png', mode, generation)
for mode, name in [('Default', 'light'), ('Dark', 'dark')]:
    render(ROOT / 'source/ReferenceExport.icon', ROOT / f'reference/PicLight-{name}.png', mode)

SIZES = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
         (256, 1), (256, 2), (512, 1), (512, 2)]

def pack(master, folder, basename, catalog=False):
    iconset = folder / f'{basename}.iconset'
    iconset.mkdir(exist_ok=True)
    images = []
    for points, scale in SIZES:
        name = f'icon_{points}x{points}' + ('@2x' if scale == 2 else '') + '.png'
        run(ROOT / 'build/export-grid', master, iconset / name, points * scale, '0.8046875', '0.25')
        images.append(dict(filename=name, idiom='mac', size=f'{points}x{points}', scale=f'{scale}x'))
    run('iconutil', '-c', 'icns', iconset, '-o', folder / f'{basename}.icns')
    if catalog:
        target = folder / f'{basename}.appiconset'
        target.mkdir(exist_ok=True)
        for item in images:
            shutil.copyfile(iconset / item['filename'], target / item['filename'])
        (target / 'Contents.json').write_text(json.dumps(dict(images=images,
            info=dict(author='xcode', version=1)), indent=2) + '\n')

pack(ROOT / 'preview/native/Default-26.png', ROOT / 'legacy', 'PicLight', True)
pack(ROOT / 'reference/PicLight-light.png', ROOT / 'reference', 'PicLight-reference', True)
pack(ROOT / 'reference/PicLight-dark.png', ROOT / 'reference', 'PicLight-reference-dark')

compiled = ROOT / 'verification/compiled'
result = run('xcrun', 'actool', '--output-format', 'human-readable-text', '--notices', '--warnings',
    '--errors', '--platform', 'macosx', '--target-device', 'mac', '--minimum-deployment-target', '14.0',
    '--app-icon', 'PicLight', '--output-partial-info-plist', compiled / 'partial.plist',
    '--compile', compiled, ROOT / 'PicLight.icon')
(compiled / 'actool.log').write_text(result.stdout + result.stderr)
(compiled / 'asset-info.json').write_text(run('xcrun', 'assetutil', '--info', compiled / 'Assets.car').stdout)
run(ROOT / 'build/preview', ROOT)
print('Exported reference PNGs; 12 native renders; 3 complete ICNS files; 4 review sheets; compiled Assets.car.')
