"""Finite trusted per-app source profiles. No profile is decoded from RPC/env.

Product composition must bind a reviewed LaunchSpec, observed code identity,
principal/epoch and selected native library through CaptureHostConfig. Shipping
profiles have neither a launch nor a grant, and inspect no installed process.
"""
from __future__ import annotations
from dataclasses import dataclass

from .contracts import Fault
from .tisra_capture_host import CaptureHostAttachment, CaptureHostConfig
from .tisra_capture_uploads import METHODS

APPS = frozenset({'tisra', 'mio', 'friday'})


@dataclass(frozen=True)
class CaptureSourceProfile:
    app: str
    config: CaptureHostConfig | None = None
    enabled: bool = False

    def validate(self):
        if self.app not in APPS or type(self.enabled) is not bool:
            raise Fault('capture_profile_unconfigured')
        if self.enabled:
            cfg = self.config
            if (type(cfg) is not CaptureHostConfig or cfg.source.app != self.app or
                    not cfg.library_granted or not cfg.methods or not cfg.methods <= METHODS):
                raise Fault('capture_profile_unconfigured')
        elif self.config is not None:
            raise Fault('capture_profile_unconfigured')


def production_profiles():
    return tuple(CaptureSourceProfile(app) for app in sorted(APPS))


def attachment_for_profiles(profiles=None):
    profiles = production_profiles() if profiles is None else tuple(profiles)
    if (any(type(p) is not CaptureSourceProfile for p in profiles) or
            {p.app for p in profiles} != APPS or len(profiles) != len(APPS)):
        raise Fault('capture_profile_unconfigured')
    for profile in profiles:
        profile.validate()
    active = [p for p in profiles if p.enabled]
    # This source slice admits exactly one explicit selected consumer/library.
    if len(active) > 1:
        raise Fault('capture_profile_unconfigured')
    return CaptureHostAttachment(active[0].config, enabled=True) if active else CaptureHostAttachment()
