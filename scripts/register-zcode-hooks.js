'use strict';
// Merge hook entries into the ZCode CLI config hooks section (idempotent).
// usage: node register-zcode-hooks.js <config.json> <spec.json>
// spec: { entries: [ {event, matcher, type, command, args, timeoutMs, key} ] }
// - forces hooks.enabled = true (config-file hooks are off by default)
// - same event + same matcher group: an entry whose args contain key is
//   replaced in place, otherwise the entry is appended
// - backs up first, re-parses and verifies after, exits 1 on any failure
const fs = require('fs');
const [file, specFile] = process.argv.slice(2);
if (!file || !specFile) {
  console.error('usage: node register-zcode-hooks.js <config.json> <spec.json>');
  process.exit(1);
}
const spec = JSON.parse(fs.readFileSync(specFile, 'utf8'));
// PS 5.1 ConvertTo-Json unfolds single-element arrays into bare objects
if (!Array.isArray(spec.entries)) spec.entries = spec.entries ? [spec.entries] : [];
spec.entries = spec.entries.filter(function (e) { return e && e.event && e.command; });
const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14);
fs.copyFileSync(file, file + '.bak-hooks-' + stamp);
let d;
try {
  d = JSON.parse(fs.readFileSync(file, 'utf8'));
} catch (e) {
  console.error('config parse failed: ' + e.message);
  process.exit(1);
}
if (!d.hooks || typeof d.hooks !== 'object') d.hooks = {};
d.hooks.enabled = true;
if (!d.hooks.events || typeof d.hooks.events !== 'object') d.hooks.events = {};
const ev = d.hooks.events;
for (const ent of spec.entries || []) {
  if (!Array.isArray(ev[ent.event])) ev[ent.event] = [];
  const groups = ev[ent.event];
  let group = groups.find(function (g) { return (g.matcher || null) === (ent.matcher || null); });
  if (!group) {
    group = ent.matcher ? { matcher: ent.matcher, hooks: [] } : { hooks: [] };
    groups.push(group);
  }
  if (!Array.isArray(group.hooks)) group.hooks = [];
  const form = { type: ent.type, command: ent.command };
  if (ent.type === 'process') form.args = ent.args || [];
  if (ent.timeoutMs != null) form.timeoutMs = ent.timeoutMs;
  const idx = group.hooks.findIndex(function (h) {
    return Array.isArray(h.args) && ent.key && h.args.indexOf(ent.key) >= 0;
  });
  if (idx >= 0) group.hooks[idx] = form;
  else group.hooks.push(form);
}
fs.writeFileSync(file, JSON.stringify(d, null, 2) + '\n', 'utf8');
// verify: re-parse and confirm every entry landed
const v = JSON.parse(fs.readFileSync(file, 'utf8'));
let ok = !!(v.hooks && v.hooks.enabled === true);
for (const ent of spec.entries || []) {
  if (!ok) break;
  const groups = (v.hooks.events[ent.event] || []);
  const g = groups.find(function (x) { return (x.matcher || null) === (ent.matcher || null); });
  const hit = g && g.hooks.find(function (h) {
    return Array.isArray(h.args) && ent.key && h.args.indexOf(ent.key) >= 0;
  });
  if (!hit) ok = false;
}
if (!ok) {
  console.error('post-write verification failed');
  process.exit(1);
}
console.log('ZCODE_HOOKS_OK');
