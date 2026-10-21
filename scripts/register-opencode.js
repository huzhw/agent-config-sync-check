'use strict';
// Register one MCP server into an opencode config as a *local* server:
//   mcp.servers.<name> = { "type": "local", "command": [cmd, ...args] }
// opencode declares a local server's executable and its args in ONE array, so
// <command> becomes element 0 and the remaining argv becomes the tail.
//
// Backup first, verify after (same contract as register-zcode.js / register-qoder.js).
// Refuses to rewrite a JSONC file that still carries // or /* */ comments: a JSON
// rewrite would silently drop them, and opencode configs are hand-edited often
// enough that losing a comment is worse than a failed sync. Strip them by hand,
// then re-run.
//
// usage: node register-opencode.js <opencode.json[c]> <name> <command> [args...]
const fs = require('fs');

function scanJsonc(text) {
  let out = '';
  let comments = 0;
  let inStr = false;
  let i = 0;
  while (i < text.length) {
    const ch = text[i];
    const next = text[i + 1];
    if (inStr) {
      out += ch;
      if (ch === '\\') { out += next || ''; i += 2; continue; }
      if (ch === '"') { inStr = false; }
      i++;
      continue;
    }
    if (ch === '"') { inStr = true; out += ch; i++; continue; }
    if (ch === '/' && next === '/') { comments++; while (i < text.length && text[i] !== '\n') { i++; } continue; }
    if (ch === '/' && next === '*') { comments++; i += 2; while (i < text.length && !(text[i] === '*' && text[i + 1] === '/')) { i++; } i += 2; continue; }
    out += ch;
    i++;
  }
  return { text: out.replace(/,\s*([}\]])/g, '$1'), comments: comments };
}

const [file, name, command, ...args] = process.argv.slice(2);
if (!file || !name || !command) {
  console.error('usage: node register-opencode.js <opencode.json[c]> <name> <command> [args...]');
  process.exit(1);
}

const raw = fs.readFileSync(file, 'utf8');
const scan = scanJsonc(raw);
if (scan.comments > 0) {
  console.error('refusing to rewrite ' + file + ': it still has ' + scan.comments + ' JSONC comment(s) that a JSON rewrite would drop');
  process.exit(2);
}

const d = JSON.parse(scan.text);
if (!d.mcp || typeof d.mcp !== 'object' || Array.isArray(d.mcp)) { d.mcp = {}; }
if (!d.mcp.servers || typeof d.mcp.servers !== 'object' || Array.isArray(d.mcp.servers)) {
  // migrate the legacy keyed form (mcp.<name>) into the current mcp.servers map
  const legacy = {};
  for (const k of Object.keys(d.mcp)) {
    if (k === 'servers' || k === 'timeout') { continue; }
    legacy[k] = d.mcp[k];
  }
  d.mcp = { servers: legacy };
}
d.mcp.servers[name] = { type: 'local', command: [command, ...args] };

const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14);
fs.copyFileSync(file, file + '.bak-mcp-' + stamp);
fs.writeFileSync(file, JSON.stringify(d, null, 2) + '\n', 'utf8');

const check = JSON.parse(fs.readFileSync(file, 'utf8'));
const s = check.mcp && check.mcp.servers && check.mcp.servers[name];
if (!s || s.type !== 'local' || JSON.stringify(s.command) !== JSON.stringify([command, ...args])) {
  console.error('rewrite verification failed');
  process.exit(1);
}
console.log('OPENCODE_REGISTER_OK');
