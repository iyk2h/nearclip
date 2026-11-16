#!/usr/bin/env python3
"""Build a signed appcast for an already packaged NearClip release."""
import argparse
import base64
import datetime
import hashlib
import tempfile
import pathlib
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE)
p = argparse.ArgumentParser()
p.add_argument('app', type=pathlib.Path)
p.add_argument('archive', type=pathlib.Path)
p.add_argument('output', type=pathlib.Path)
p.add_argument('--download-url')
p.add_argument('--test-local', action='store_true', help='Allow a loopback-only URL for an isolated update test')
a = p.parse_args()
with (a.app / 'Contents/Info.plist').open('rb') as f:
    info = plistlib.load(f)
version, build = info['CFBundleShortVersionString'], str(info['CFBundleVersion'])
if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not re.fullmatch(r'\d+', build):
    raise SystemExit('Invalid release version/build')
if info['CFBundleIdentifier'] != 'dev.nearclip.mac':
    raise SystemExit('Unexpected app identifier')
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(a.app)], check=True)
# Do not sign metadata for one app while uploading a different archive.
def bundle_digest(path):
    digest = hashlib.sha256()
    for entry in sorted(path.rglob('*')):
        digest.update(str(entry.relative_to(path)).encode())
        if entry.is_symlink():
            digest.update(b'link:' + str(entry.readlink()).encode())
        elif entry.is_file():
            digest.update(b'file:' + hashlib.sha256(entry.read_bytes()).digest())
    return digest.digest()
with tempfile.TemporaryDirectory(prefix='nearclip-release-verify-') as temporary:
    subprocess.run(['ditto', '-x', '-k', str(a.archive), temporary], check=True)
    extracted = pathlib.Path(temporary) / 'NearClip.app'
    if not extracted.is_dir() or bundle_digest(extracted) != bundle_digest(a.app):
        raise SystemExit('Archive contents do not match the validated app bundle')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(extracted)], check=True)

vendor = ROOT / 'build/vendor/sparkle-2.10.1/bin'
public = subprocess.check_output([str(vendor / 'generate_keys'), '--account', 'dev.nearclip.updates', '-p'], text=True).strip()
if public != info['SUPublicEDKey']:
    raise SystemExit('Signing key does not match the public key in the app')
url = a.download_url or f'https://github.com/iyk2h/nearclip/releases/download/v{version}-build{build}/{a.archive.name}'
from urllib.parse import urlsplit
parsed = urlsplit(url)
valid = parsed.scheme == 'https' and parsed.netloc == 'github.com' and parsed.path.startswith('/iyk2h/nearclip/releases/download/') and not parsed.query and not parsed.fragment
if a.test_local:
    valid = valid or (parsed.scheme == 'http' and parsed.hostname == '127.0.0.1')
if not valid:
    raise SystemExit('Unexpected download URL')
sign = [str(vendor / 'sign_update'), '--account', 'dev.nearclip.updates']
signature = subprocess.check_output(sign + ['-p', str(a.archive)], text=True).strip()
if len(base64.b64decode(signature, validate=True)) != 64:
    raise SystemExit('Invalid archive signature')
root = ET.Element('rss', {'version': '2.0'})
channel = ET.SubElement(root, 'channel')
ET.SubElement(channel, 'title').text = 'NearClip updates'
ET.SubElement(channel, 'link').text = 'https://github.com/iyk2h/nearclip/releases'
ET.SubElement(channel, 'description').text = 'Signed NearClip beta updates for macOS.'
ET.SubElement(channel, f'{{{SPARKLE}}}bundleIdentifier').text = 'dev.nearclip.mac'
item = ET.SubElement(channel, 'item')
ET.SubElement(item, 'title').text = f'NearClip {version} · build {build} beta'
ET.SubElement(item, 'pubDate').text = datetime.datetime.now(datetime.timezone.utc).strftime('%a, %d %b %Y %H:%M:%S +0000')
ET.SubElement(item, f'{{{SPARKLE}}}version').text = build
ET.SubElement(item, f'{{{SPARKLE}}}shortVersionString').text = f'{version} (build {build})'
ET.SubElement(item, f'{{{SPARKLE}}}minimumSystemVersion').text = info['LSMinimumSystemVersion']
ET.SubElement(item, 'description').text = 'Update within NearClip, then restart. Pairing and settings are kept. Input sharing remains experimental.'
ET.SubElement(item, 'enclosure', {'url': url, f'{{{SPARKLE}}}edSignature': signature, 'length': str(a.archive.stat().st_size), 'type': 'application/octet-stream'})
a.output.parent.mkdir(parents=True, exist_ok=True)
ET.indent(root)
ET.ElementTree(root).write(a.output, encoding='utf-8', xml_declaration=True)
subprocess.run(sign + [str(a.output)], check=True)
subprocess.run(sign + ['--verify', str(a.output)], check=True)
subprocess.run(sign + ['--verify', str(a.archive), signature], check=True)
print(f'Prepared signed feed for {version} build {build}: {a.output}')
