# Chief Plan Key Provisioning

`lib/94-chief-fleet-convergence.sh` creates `/etc/chief/node-plan.key` when it is absent. The file is
owned `root:chief` and mode `0640`; `hermes-converger` accepts only `key_id=node:<node_id>:plan-v1`.

Core must have the same byte string to sign node-facing plans. For h-do1, mount or inject the value
into the chief-stack container as a secret and expose its path with:

```text
CHIEF_NODE_PLAN_KEY_PATH=/run/secrets/chief_node_plan_key_h-do1
```

The bootstrap module also writes `/etc/chief/node.env` with `CHIEF_NODE_ID` and `CHIEF_CORE_URL`.
If the chief-stack compose project is present at `/root/code/chief/chief-stack/compose.yaml`, add a
secret named `chief_node_plan_key_<node_id>` from `/etc/chief/node-plan.key` and mount it read-only
into the core service before enabling plan signing.

