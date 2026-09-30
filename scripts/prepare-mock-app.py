"""Copy only a marked synthetic build into a fresh runner-owned namespace."""
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys
import uuid

with Path(__file__).with_name('mock-mail-scenarios.json').open('rb') as stream:
    scenarios = json.load(stream)
host, source, destination = sys.argv[1:4]
source, destination = Path(source).resolve(), Path(destination).resolve()
if host not in ('mobile', 'macos') or destination.exists():
    raise SystemExit('Invalid host or existing destination')
relative = Path('Info.plist') if host == 'mobile' else Path('Contents/Info.plist')
with (source / relative).open('rb') as stream:
    info = plistlib.load(stream)
if info.get('UnwiredMockScenario') not in scenarios['nativeJourney']:
    raise SystemExit('The native journey requires a supported test-only build')
identifier = 'dev.unwired.mock.' + uuid.uuid4().hex
signer = '-'
entitlements_path = None
profile = None
if host == 'macos':
    # Mac Data Protection Keychain requires a profile covering the disposable ID.
    profile_path = os.environ.get('UNWIRED_MOCK_PROFILE')
    signer = os.environ.get('UNWIRED_SIGNING_IDENTITY', '-')
    if not profile_path or signer == '-' or len(sys.argv) != 5:
        raise SystemExit('Mac sessions require UNWIRED_MOCK_PROFILE, UNWIRED_SIGNING_IDENTITY and a cleanup executable')
    profile = Path(profile_path).resolve()
    decoded = subprocess.run(['security', 'cms', '-D', '-i', str(profile)],
                             check=True, capture_output=True).stdout
    authorization = plistlib.loads(decoded)
    team = authorization['TeamIdentifier'][0]
    allowed = authorization['Entitlements'].get('com.apple.application-identifier')
    prefix = allowed.split('.', 1)[0] if isinstance(allowed, str) else ''
    if not prefix or allowed not in (prefix + '.dev.unwired.mock.*', prefix + '.*'):
        raise SystemExit('Mac profile must cover disposable dev.unwired.mock.* identities')
    entitlements_path = destination.parent / 'mock-entitlements.plist'
    with entitlements_path.open('wb') as stream:
        plistlib.dump({'com.apple.application-identifier': prefix + '.' + identifier,
                      'com.apple.developer.team-identifier': team,
                      'keychain-access-groups': [prefix + '.' + identifier]}, stream)
# Record ownership before mutation so preparation failures can be cleaned up.
record = {'version': 1, 'kind': 'mock-mail-session', 'scenario': info['UnwiredMockScenario'],
          'host': host, 'bundleIdentifier': identifier, 'app': str(destination)}
(destination.parent / 'ownership.json').write_text(json.dumps(record, indent=2) + '\n')
shutil.copytree(source, destination, symlinks=True)
info['CFBundleIdentifier'] = identifier
with (destination / relative).open('wb') as stream:
    plistlib.dump(info, stream)
sign_arguments = ['codesign', '--force', '--sign', signer]
if profile is not None:
    shutil.copyfile(profile, destination / 'Contents/embedded.provisionprofile')
    sign_arguments += ['--entitlements', str(entitlements_path)]
    cleanup_app = destination.parent / 'Cleanup.app'
    (cleanup_app / 'Contents/MacOS').mkdir(parents=True)
    shutil.copyfile(sys.argv[4], cleanup_app / 'Contents/MacOS/cleanup')
    (cleanup_app / 'Contents/MacOS/cleanup').chmod(0o755)
    shutil.copyfile(profile, cleanup_app / 'Contents/embedded.provisionprofile')
    with (cleanup_app / 'Contents/Info.plist').open('wb') as stream:
        plistlib.dump({'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'cleanup',
                      'CFBundlePackageType': 'APPL'}, stream)
    subprocess.run(sign_arguments + [str(cleanup_app)], check=True)
# Preserve nested framework signatures; replace only the application signature.
subprocess.run(sign_arguments + [str(destination)], check=True)
print(identifier)
