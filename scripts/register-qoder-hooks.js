'use strict';
// Merge sync-guard hook entries into the Qoder user settings.json "hooks"
// group (Claude-Code-shaped). Upsert only - never deletes user-added hooks.
// Backup first, verify after.
// usage: node register-qoder-hooks.js <settings.json> <spec.json>
// spec: { entries: [ { event, matcher, command, timeoutSec } ] }
const fs = require('fs');
const [file, specFile] = process.argv.slice(2);
if (!file || !specFile) {
  console.error('usage: node register-qoder-hooks.js <settings.json> <spec.json>');
  process.exit(1);
}
const spec = JSON.parse(fs.readFileSync(specFile, 'utf8'));
const entries = (spec.entries || []).filter(function (e) { return e && e.event && e.command; });
if (entries.length === 0) {
  console.error('spec has no entries');
  process.exit(1);
}
const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14);
fs.copyFileSync(file, file + '.bak-hooks-' + stamp);
const d = JSON.parse(fs.readFileSync(file, 'utf8'));
if (!d.hooks) d.hooks = {};
for (const e of entries) {
  if (!Array.isArray(d.hooks[e.event])) d.hooks[e.event] = [];
  const groups = d.hooks[e.event];
  let grp = groups.find(function (g) { return g && ((g.matcher || '') === (e.matcher || '')); });
  if (!grp) {
    grp = e.matcher ? { matcher: e.matcher, hooks: [] } : { hooks: [] };
    groups.push(grp);
  }
  if (!Array.isArray(grp.hooks)) grp.hooks = [];
  const hit = grp.hooks.find(function (h) { return h && h.type === 'command' && h.command === e.command; });
  if (hit) {
    if (e.timeoutSec != null) hit.timeout = e.timeoutSec;
  } else {
    const h = { type: 'command', command: e.command };
    if (e.timeoutSec != null) h.timeout = e.timeoutSec;
    grp.hooks.push(h);
  }
}
fs.writeFileSync(file, JSON.stringify(d, null, 2) + '\n', 'utf8');
// verify: every expected command must exist under its event (+matcher)
const check = JSON.parse(fs.readFileSync(file, 'utf8'));
let ok = true;
for (const e of entries) {
  const groups = (check.hooks && check.hooks[e.event]) || [];
  const found = groups.some(function (g) {
    if (((g.matcher || '') !== (e.matcher || ''))) return false;
    return (g.hooks || []).some(function (h) { return h && h.command === e.command; });
  });
  if (!found) { ok = false; console.error('verify failed: ' + e.event + ' ' + e.command); }
}
if (!ok) process.exit(1);
console.log('QODER_HOOKS_OK');
