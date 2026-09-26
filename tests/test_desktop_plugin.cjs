// Deterministic SDK/timer fixtures. No Electron, network, or external packages.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const rows = Array.from({length: 7}, (_, i) => ({
  label: `host-${i}`, endpoint: `https://host-${i}.test`, admission: 'admitted'
}));
const source = fs.readFileSync(path.join(__dirname, '../desktop-plugins/fleet-gateways/plugin.js'), 'utf8')
  .replace("import { host } from '@hermes/plugin-sdk';", '')
  .replace(/\/\* FLEET_MANIFEST \*\/ .*?;/, '/* FLEET_MANIFEST */ ' + JSON.stringify({schema_version: 1, complete: true, rows}) + ';')
  .replace('export default', 'globalThis.plugin =');

function fixture() {
  let now = 0;
  let disposed = false;
  let dispose;
  let sequence = 0;
  const tasks = new Map();
  const events = new Map();
  const warmed = [];
  function timer(fn, delay, interval = false) {
    const id = sequence++;
    tasks.set(id, {fn, due: now + delay, interval: interval ? delay : 0});
    return () => tasks.delete(id);
  }
  const ctx = {
    setTimeout: (fn, delay) => timer(fn, delay),
    setInterval: (fn, delay) => timer(fn, delay, true),
    onDispose: fn => { dispose = fn; },
    addEventListener: (_, name, fn) => events.set(name, fn)
  };
  const host = {
    connections: async () => rows.map((row, i) => ({id: `id-${i}`, label: row.label, url: row.endpoint, kind: 'remote'})),
    warmAgent: (id, profile) => { assert.equal(profile, 'default'); warmed.push({id, now}); }
  };
  const sandbox = {ctx, host, URL, window: {}, Date: {now: () => now}};
  vm.runInNewContext(source, sandbox);
  sandbox.plugin.register(ctx);
  async function fireDue() {
    while (true) {
      const next = [...tasks].filter(([, t]) => t.due <= now).sort((a, b) => a[1].due - b[1].due || a[0] - b[0])[0];
      if (!next) break;
      const [id, task] = next;
      tasks.delete(id);
      if (task.interval) tasks.set(id, {...task, due: now + task.interval});
      await task.fn();
      await Promise.resolve();
    }
  }
  return {
    warmed,
    async advance(target) {
      while ([...tasks.values()].some(t => t.due <= target)) {
        now = Math.min(...[...tasks.values()].map(t => t.due));
        await fireDue();
      }
      now = target;
    },
    async jump(target) { now = target; await fireDue(); },
    event(name) { if (!disposed) events.get(name)(); },
    dispose() { disposed = true; dispose(); tasks.clear(); events.clear(); }
  };
}

(async () => {
  let f = fixture();
  await f.advance(420000);
  assert.deepEqual(f.warmed.map(x => x.now), [0,30000,60000,90000,120000,150000,180000,240000,270000,300000,330000,360000,390000,420000]);

  f = fixture();
  await f.advance(0);
  await f.jump(75000); // first pending row is 45 seconds late
  await f.advance(180000);
  assert.equal(new Set(f.warmed.map(x => x.id)).size, 7);
  assert.equal(f.warmed.find(x => x.id === 'id-1').now, 75000);

  f = fixture();
  await f.advance(0);
  await f.jump(180000); // suspension during an unfinished stagger
  assert.equal(f.warmed.filter(x => x.now === 180000).length, 1);
  await f.advance(360000);
  assert.equal(new Set(f.warmed.map(x => x.id)).size, 7);

  f = fixture();
  await f.advance(30000);
  await f.jump(900000); // suspension, not hidden-window alignment
  const resumed = f.warmed.filter(x => x.now >= 900000);
  assert.equal(resumed.length, 1, 'resume must not burst');
  assert.equal(resumed[0].id, 'id-2', 'resume continues from the first missed row');
  await f.advance(1080000);
  assert.equal(new Set(f.warmed.filter(x => x.now >= 900000).map(x => x.id)).size, 7);

  f = fixture();
  await f.advance(0);
  f.event('online'); f.event('focus');
  await f.advance(60000);
  f.event('online'); f.event('focus'); // leave the pending stagger intact
  await f.advance(180000);
  assert.equal(f.warmed.length, 7);
  f.event('focus'); f.event('online');
  await f.advance(360000);
  const previous = new Map();
  for (const item of f.warmed) {
    assert.ok(item.now - (previous.get(item.id) ?? -Infinity) >= 60000);
    previous.set(item.id, item.now);
  }
  const before = f.warmed.length;
  f.dispose();
  f.event('focus');
  await f.advance(2000000);
  assert.equal(f.warmed.length, before);
  console.log('PASS: on-time, 45s late, sleep/resume, online/focus, spacing and dispose');
})().catch(error => { console.error(error); process.exitCode = 1; });
