#!/usr/bin/env bash
# Run the fleet-trace-retention tests with the Hermes interpreter (needs hermes_state + PyYAML).
# HERMES_DISABLE_LAZY_INSTALLS=1: importing Hermes must never start a dependency sync or relaunch into another
# interpreter (Hermes's venv_sync.prepare_launch does that on self-updating installs).
cd "$(dirname "$0")/.." || exit 2
PY="${FTR_PYTHON:-/usr/local/lib/hermes-agent/venv/bin/python}"
exec env -u PYTHONPATH -u PYTHONHOME HERMES_DISABLE_LAZY_INSTALLS=1 "$PY" -m unittest discover -s tests \
  -p 'test_fleet_trace_retention.py' "$@"
