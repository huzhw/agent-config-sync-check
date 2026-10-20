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
// Script identity = the quoted script path at the end of the command line
// (e.g. bash "C:/.../guard-memory-write.sh"). Matching by script path lets the
// upsert REPLACE a stale interpreter (bare bash -> pinned Git Bash) in place
// instead of appending a duplicate entry (2026-10-20 Git install move incident).
function scriptKey(cmd) {
  const m = /["']([^"']+\.(?:sh|cjs|js))["']\s*$/.exec(String(cmd || ''));
  return m ? m[1] : String(cmd || '');
}
// Dedupe only the guard scripts; user-added hooks are never removed.
function isGuardScript(key) {
  return key.indexOf('/.claude/hooks/') >= 0 || key.indexOf('/.codex/hooks/') >= 0;
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
  const key = scriptKey(e.command);
  const hit = grp.hooks.find(function (h) { return h && h.type === 'command' && scriptKey(h.command) === key; });
  if (hit) {
    hit.command = e.command;
    if (e.timeoutSec != null) hit.timeout = e.timeoutSec;
  } else {
    const h = { type: 'command', command: e.command };
    if (e.timeoutSec != null) h.timeout = e.timeoutSec;
    grp.hooks.push(h);
  }
}
// One entry per guard script: drop historical duplicates left by earlier
// appends (bare bash + pinned absolute path), keep the first.
for (const ev of Object.keys(d.hooks)) {
  if (!Array.isArray(d.hooks[ev])) continue;
  for (const grp of d.hooks[ev]) {
    if (!grp || !Array.isArray(grp.hooks)) continue;
    const seen = {};
    grp.hooks = grp.hooks.filter(function (h) {
      if (!h || h.type !== 'command') return true;
      const k = scriptKey(h.command);
      if (!isGuardScript(k)) return true;
      if (seen[k]) return false;
      seen[k] = true;
      return true;
    });
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
