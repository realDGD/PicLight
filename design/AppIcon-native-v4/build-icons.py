#!/usr/bin/env python3
"""Export this standalone icon review package; never modifies the application."""
import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent
DEVELOPER = pathlib.Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
ICT = DEVELOPER.parent / 'Applications/Icon Composer.app/Contents/Executables/ictool'

def run(*args):
    return subprocess.run([str(a) for a in args], check=True, capture_output=True, text=True)

def render(destination, mode, generation=27, size=1024):
    args = [ICT, ROOT / 'PicLight.icon', '--export-image', '--output-file', destination,
        '--platform', 'macOS', '--rendition', mode, '--width', size, '--height', size,
        '--scale', 1, '--design-generation', generation]
    if mode.startswith('Tinted'):
        args += ['--tint-color', '0.14', '--tint-strength', '0.8']
    run(*args)

for folder in ['build', 'preview/native', 'preview/sizes', 'exports/PicLight.iconset', 'verification/compiled']:
    (ROOT / folder).mkdir(parents=True, exist_ok=True)
for name in ['export-grid', 'preview']:
    run('swiftc', '-O', ROOT / f'tools/{name}.swift', '-o', ROOT / f'build/{name}')
for generation in [26,27]:
    for mode in ['Default','Dark','ClearLight','ClearDark','TintedLight','TintedDark']:
        render(ROOT / f'preview/native/{mode}-{generation}.png', mode, generation)
for mode in ['Default','Dark']:
    for size in [256,128,64,32,16]:
        render(ROOT / f'preview/sizes/{mode}-{size}.png', mode, 27, size)
for points,scale in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]:
    name=f'icon_{points}x{points}'+('@2x' if scale==2 else '')+'.png'
    run(ROOT / 'build/export-grid', ROOT / 'preview/native/Default-26.png',
        ROOT / 'exports/PicLight.iconset' / name, points*scale, '0.8046875', '0.25')
run('iconutil','-c','icns',ROOT / 'exports/PicLight.iconset','-o',ROOT / 'exports/PicLight-native.icns')
compiled = ROOT / 'verification/compiled'
result=run('xcrun','actool','--output-format','human-readable-text','--notices','--warnings','--errors',
    '--platform','macosx','--target-device','mac','--minimum-deployment-target','14.0',
    '--app-icon','PicLight','--output-partial-info-plist',compiled / 'partial.plist',
    '--compile',compiled,ROOT / 'PicLight.icon')
(compiled / 'actool.log').write_text(result.stdout+result.stderr)
(compiled / 'asset-info.json').write_text(run('xcrun','assetutil','--info',compiled / 'Assets.car').stdout)
run(ROOT / 'build/preview',ROOT)
print('Exported 12 native appearance masters, 10 size previews, complete ICNS, 3 review sheets, and compiled Assets.car.')
