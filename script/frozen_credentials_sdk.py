"""Read-only verifier for the exact retained fc08 SDK; never build or repair it."""
import hashlib
import json
import stat
from pathlib import Path

MANIFEST_SHA256 = '25cb022f2bb5a9b094844a580404236bcdb5d5264afe5928293373271dc540b2'
MODULE_MAP_SHA256 = '43278aa62fe2dd4d44e6c7435b7998bf21f32d9d9549d24915e8c9083c42e4c7'
ARTIFACTS = {
    'FlyAICompression.o', 'ARLCredentialOnboarding.o',
    'ARLCredentialHostCore.swiftmodule', 'libARLCredentialHostCore.a',
    'ARLCredentialHostCore.o', 'ARLCredentialOnboarding.swiftmodule',
    'ARLCredentialHostCore.swiftdoc', 'ARLCredentialOnboarding.swiftdoc',
}


def file_hash(path):
    path = Path(path)
    if not path.is_absolute() or path.resolve(strict=True) != path:
        raise ValueError(f'Noncanonical or symlink SDK input: {path}')
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > 16 * 1024 * 1024:
        raise ValueError(f'Not a bounded regular SDK input: {path}')
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_frozen_sdk(root, sdk):
    raise ValueError('Retired fc08 SDK verifier; current build.sh compiles the canonical SDK. No external input was read.')
