"""Fixed formal Tisra peer pin for an explicitly packaged ARL host.

This is a read-only identity boundary. It does not select a model, grant a
research method, start an app, or enroll an RPC caller.
"""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import stat
import subprocess

from .supervisor import SignedPeerVerifier

TISRA_APP = Path('/Applications/Tisra.app')
TISRA_EXECUTABLE = TISRA_APP / 'Contents/MacOS/Tisra'
TISRA_EXECUTABLE_SHA256 = 'a50cb1c02e7d2eac8a3be7ed4c75d3231e50ece0042e2db0c9b3cf13ad22fb4e'
TISRA_REQUIREMENT = 'cdhash H"3be74e1372d40b213ce4233632cd19ec09e9d21e"'
HELPER_SHA256 = 'f76ac5dcd2cd3378364774a2d3885ed53ced3badc6b8c67629c88247d21c5a76'
ENV = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LANG': 'C', 'LC_ALL': 'C', 'TMPDIR': '/tmp'}


def exact_file(path: Path, expected: str) -> bool:
    try:
        info = path.lstat()
        return (stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and
                not info.st_mode & 0o022 and hashlib.sha256(path.read_bytes()).hexdigest() == expected)
    except (OSError, ValueError):
        return False


class FormalTisraPeer:
    def __init__(self, helper: Path):
        self.helper = helper
        self.signed = SignedPeerVerifier(helper, {'tisra': TISRA_REQUIREMENT})

    def __call__(self, connection, claimed_app):
        if (claimed_app != 'tisra' or
                not exact_file(self.helper, HELPER_SHA256) or
                not exact_file(TISRA_EXECUTABLE, TISRA_EXECUTABLE_SHA256)):
            return None
        return self.signed(connection, claimed_app)

    def session_binding(self, connection, app):
        from .contracts import Fault
        if self(connection, app) != app:raise Fault('app_identity_unverified')
        key, current = self.signed.session_binding(connection, app)
        return key, lambda: (exact_file(self.helper, HELPER_SHA256) and
                            exact_file(TISRA_EXECUTABLE, TISRA_EXECUTABLE_SHA256) and current())


def available_formal_tisra_peer(package_root: Path | None = None):
    """Return a pinned verifier only for the exact reviewed installed artifacts.

    Mismatch leaves the peer unavailable while the metadata host remains live.
    Product packaging must place the reviewed helper under build/.
    """
    root = Path(package_root) if package_root is not None else Path(__file__).resolve().parents[1]
    helper = root / 'build/PeerSignatureHelper'
    if not exact_file(helper, HELPER_SHA256) or not exact_file(TISRA_EXECUTABLE, TISRA_EXECUTABLE_SHA256):
        return None
    try:
        result = subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '--deep', str(TISRA_APP)],
                                env=ENV, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        if result.returncode != 0:
            return None
        result = subprocess.run(['/usr/bin/codesign', '-d', '-r-', str(TISRA_APP)],
                                env=ENV, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=5)
        if result.returncode != 0 or ('# designated => ' + TISRA_REQUIREMENT).encode() not in result.stdout:
            return None
        return FormalTisraPeer(helper)
    except (OSError, subprocess.TimeoutExpired):
        return None
