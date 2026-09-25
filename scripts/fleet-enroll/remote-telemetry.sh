#!/usr/bin/env bash
# remote-telemetry.sh <host> <core_url> — runs ON the target as root, after the orchestrator
# has synced /root/code/chief/{hermes-node,chief-spec/sdk} and /opt/hermes-host-bootstrap-baseline.
# Installs the Chief node daemon in TELEMETRY-ONLY mode (heartbeat/state/provisioning).
# Convergence writers, reconcile and supervisor units are never installed or enabled here.
set -euo pipefail
host="$1"; core="$2"
node_dir=/root/code/chief/hermes-node
base=/opt/hermes-host-bootstrap-baseline
export PATH="/root/.local/bin:$PATH"

command -v uv >/dev/null || { echo "uv is not installed on this node; install it deliberately (bootstrap lib) before enrolling"; exit 1; }
cd "$node_dir"
[[ -x .venv/bin/python ]] || uv venv -q --python python3 .venv
uv pip install --python .venv/bin/python -q -e ../chief-spec/sdk/python -e .

install -d -m 0755 /etc/chief
umask 077
cat >/etc/chief/node.env.new <<ENV
CHIEF_NODE_ID=${host}
CHIEF_NODE_ROLE=server
CHIEF_CORE_URL=${core}
HERMES_BOOTSTRAP_DIR=${base}
HOME=/root
PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV
if ! cmp -s /etc/chief/node.env.new /etc/chief/node.env 2>/dev/null; then
  [[ -f /etc/chief/node.env ]] && cp -a /etc/chief/node.env "/etc/chief/node.env.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  mv /etc/chief/node.env.new /etc/chief/node.env
else
  rm -f /etc/chief/node.env.new
fi
umask 022
install -o root -g root -m 0644 "$base/systemd/telemetry-only/chief-node.service" /etc/systemd/system/chief-node.service
systemctl daemon-reload
systemctl enable chief-node.service
systemctl restart chief-node.service

for u in chief-node-reconcile.service chief-node-supervisor.service chief-node-supervisor.timer chief-node-converger.service; do
  if systemctl is-enabled "$u" >/dev/null 2>&1 || systemctl is-active "$u" >/dev/null 2>&1; then
    echo "WARNING: convergence unit $u is enabled/active on $host (enrollment does not arm convergence)"
  fi
done

.venv/bin/python -m hermes_node.daemon emit-provisioning --node-id "$host" --core "$core" >/dev/null
sleep 3
systemctl is-active chief-node.service
