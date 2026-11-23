#!/usr/bin/env python3
"""Compatibility shim: `import dwd` (AmForge's h-af tools) -> the shared fleet module, configured for amforge.

When AmForge adopts the shared module, /root/.hermes/google-workspace/dwd.py becomes a symlink to this file
(/usr/local/lib/fleet-google-dwd/current/dwd.py). Callers keep `sys.path.insert(0, "/root/.hermes/google-workspace");
import dwd` unchanged: this file replaces itself in sys.modules with the configured shared module, so
`dwd.get`, `dwd.SCOPES_READ`, `dwd.ALLOWED_SUBJECTS`, `dwd._audit`, ... are the shared module's own objects.
"""
import os
import sys

_HERE = os.path.dirname(os.path.realpath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import fleet_google_dwd as _m  # noqa: E402

_m.configure("amforge")

if __name__ == "__main__":
    _m.main()
else:
    sys.modules[__name__] = _m
