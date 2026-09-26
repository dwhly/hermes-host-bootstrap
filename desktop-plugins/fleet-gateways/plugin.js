// SDK contract pinned in compatibility.json at 61c06ca3ceb9fc775f79377402ea56107c127d5b.
// This source reference is NOT a qualified app artifact. Fleet-marshal supplies the
// h-mini2 app/rollback pin after canary checks; verify.sh checks it post-build.
// Install: $HERMES_HOME/desktop-plugins/fleet-gateways/plugin.js. Confirm enabled
// in Capabilities → Plugins. No native connection writes or internal bridges.
// Warming is fire-and-forget: qualify wake-to-sections time and guard skips under
// measured local secondary use. Qualify a 3-minute interval before raising caps.
import { host } from '@hermes/plugin-sdk';

const FLEET = /* FLEET_MANIFEST */ {schema_version: 1, complete: false, rows: []};
const INTERVAL = 4 * 60 * 1000;
const STAGGER = 30 * 1000;
const MIN_SPACING = 60 * 1000;

function normalizedURL(value) {
  try {
    const url = new URL(value);
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash) return null;
    return url.href.replace(/\/$/, '');
  } catch { return null; }
}

export default {
  id: 'fleet-gateways',
  name: 'Fleet gateways (warm only)',
  defaultEnabled: true,
  register(ctx) {
    if (FLEET.schema_version !== 1 || FLEET.complete !== true) return;
    const allowlist = FLEET.rows.filter(row => row.admission === 'admitted' && row.endpoint);
    if (allowlist.length > 7) return;
    let disposed = false;
    let generation = 0;
    let pending = [];
    let lastPass = -Infinity;
    let passEnds = -Infinity;
    const attempts = new Map();

    function pass(recover = false) {
      const now = Date.now();
      if (disposed || now - lastPass < MIN_SPACING || (!recover && now < passEnds)) return;
      lastPass = now;
      passEnds = now + allowlist.length * STAGGER;
      generation += 1;
      const current = generation;
      pending.forEach(cancel => cancel());
      pending = [];
      allowlist.forEach((desired, index) => {
        const due = now + index * STAGGER;
        pending.push(ctx.setTimeout(async () => {
          if (disposed || current !== generation) return;
          // A suspended renderer must discard missed ticks, then restart the stagger.
          if (Date.now() - due > 10000) { pass(true); return; }
          try {
            const rows = await host.connections();
            if (disposed || current !== generation) return;
            if (Date.now() - due > 10000) { pass(true); return; }
            const url = normalizedURL(desired.endpoint);
            const label = desired.label.trim().toLowerCase();
            const matches = rows.filter(row => row.label.trim().toLowerCase() === label || normalizedURL(row.url) === url);
            if (!url || matches.length !== 1) return;
            const row = matches[0];
            if (row.kind !== 'remote' || row.label.trim().toLowerCase() !== label || normalizedURL(row.url) !== url) return;
            const now = Date.now();
            if (now - (attempts.get(row.id) ?? -Infinity) < MIN_SPACING) return;
            attempts.set(row.id, now);
            host.warmAgent(row.id, 'default');
          } catch { /* Offline/older sources retry next pass; no activation or turn. */ }
        }, index * STAGGER));
      });
    }
    ctx.onDispose(() => { disposed = true; generation += 1; pending.forEach(cancel => cancel()); });
    ctx.setInterval(pass, INTERVAL);
    ctx.addEventListener(window, 'online', () => pass());
    ctx.addEventListener(window, 'focus', () => pass());
    pass();
  },
};
