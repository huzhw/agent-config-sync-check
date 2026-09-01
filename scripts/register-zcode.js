'use strict';
// Set mcp.servers.<name> in the ZCode CLI config (JSON) to the given
// command+args, touching nothing else. Backup first, verify after.
// usage: node register-zcode.js <config.json> <name> <command> [args...]
const fs = require('fs');
const [file, name, command, ...args] = process.argv.slice(2);
if (!file || !name || !command) {
  console.error('usage: node register-zcode.js <config.json> <name> <command> [args...]');
  process.exit(1);
}
const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14);
fs.copyFileSync(file, file + '.bak-sshmcp-' + stamp);
const d = JSON.parse(fs.readFileSync(file, 'utf8'));
if (!d.mcp) d.mcp = {};
if (!d.mcp.servers) d.mcp.servers = {};
d.mcp.servers[name] = { command: command, args: args };
fs.writeFileSync(file, JSON.stringify(d, null, 2) + '\n', 'utf8');
const check = JSON.parse(fs.readFileSync(file, 'utf8'));
const s = check.mcp.servers[name];
if (!s || s.command !== command || JSON.stringify(s.args) !== JSON.stringify(args)) {
  console.error('rewrite verification failed');
  process.exit(1);
}
console.log('ZCODE_REGISTER_OK');
