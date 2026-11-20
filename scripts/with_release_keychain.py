#!/usr/bin/env python3
"""Run one local packaging command with a disposable signing keychain."""

import base64
import os
from pathlib import Path
import secrets
import signal
import subprocess
import sys
import tempfile


def credentials(path):
    """Read literal dotenv values, including unquoted identity names with spaces."""
    values = {}
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        key, sep, value = line.partition('=')
        if not sep:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        values[key.removeprefix('export ').strip()] = value
    return values


def configure(title, *args):
    # Do not include argv in exceptions or logs. Some Apple tools take secrets as arguments.
    result = subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(f"{title} failed (exit {result.returncode})")


def package(source, command):
    cfg = credentials(source)
    env = os.environ.copy()
    env['TYPEFLUX_CODESIGN_IDENTITY'] = env.get('TYPEFLUX_CODESIGN_IDENTITY') or cfg['CODESIGN_IDENTITY']
    notarize = Path(command[0]).name == 'release_notarize.sh'
    with tempfile.TemporaryDirectory(prefix='typeflux-signing-') as directory:
        keychain = Path(directory) / 'release.keychain-db'
        p12 = Path(directory) / 'identity.p12'
        password = secrets.token_hex(32)
        try:
            configure('Create keychain', '/usr/bin/security', 'create-keychain', '-p', password, keychain)
            configure('Set keychain timeout', '/usr/bin/security', 'set-keychain-settings', '-lut', '21600', keychain)
            configure('Unlock keychain', '/usr/bin/security', 'unlock-keychain', '-p', password, keychain)
            p12.write_bytes(base64.b64decode(cfg['APPLE_CERTIFICATE_BASE64'], validate=True))
            configure('Import signing identity', '/usr/bin/security', 'import', p12, '-f', 'pkcs12',
                      '-k', keychain, '-P', cfg['APPLE_CERTIFICATE_PASSWORD'], '-T', '/usr/bin/codesign')
            p12.unlink()
            configure('Authorize codesign', '/usr/bin/security', 'set-key-partition-list',
                      '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', password, keychain)
            env['TYPEFLUX_CODESIGN_KEYCHAIN'] = str(keychain)
            if notarize and not env.get('TYPEFLUX_NOTARY_KEYCHAIN'):
                profile = env.get('TYPEFLUX_NOTARY_PROFILE') or 'typeflux-local'
                configure('Configure notarization', '/usr/bin/xcrun', 'notarytool', 'store-credentials',
                          profile, '--apple-id', cfg['NOTARYTOOL_APPLE_ID'], '--team-id', cfg['APPLE_TEAM_ID'],
                          '--password', cfg['NOTARYTOOL_PASSWORD'], '--keychain', keychain)
                env.update(TYPEFLUX_NOTARY_PROFILE=profile, TYPEFLUX_NOTARY_KEYCHAIN=str(keychain))
            return subprocess.run(command, env=env).returncode
        finally:
            if keychain.exists():
                configure('Delete temporary signing keychain', '/usr/bin/security', 'delete-keychain', keychain)


if __name__ == '__main__':
    def stop(signum, frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, stop)
    try:
        sys.exit(package(sys.argv[1], sys.argv[2:]))
    except (OSError, RuntimeError, ValueError, KeyError) as error:
        sys.exit(f"Local release signing: {error}")
