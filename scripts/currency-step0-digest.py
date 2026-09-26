#!/usr/bin/env python3
"""Compare a reviewed payload and the legacy updater's installed payload."""
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
digest = hashlib.sha256()
for path in sorted(root.rglob('*')):
    if '__pycache__' in path.parts or path.suffix == '.pyc':
        continue
    if path.is_symlink():
        raise SystemExit('payload symlink refused: ' + str(path))
    if path.is_file():
        digest.update(str(path.relative_to(root)).encode() + b'\0')
        digest.update(hashlib.sha256(path.read_bytes()).digest())
print(digest.hexdigest())
