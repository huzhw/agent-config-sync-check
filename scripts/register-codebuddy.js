'use strict';
// Set mcpServers.<name> in the CodeBuddy mcp.json (JSON, Claude-Code-shaped)
// to the given command+args, touching nothing else. Backup first, verify after.
// usage: node register-codebuddy.js <mcp.json> <name> <command> [args...]
const fs = require('fs');
const [file, name, command, ...args] = process.argv.slice(2);
if (!file || !name || !command) {
  console.error('usage: node register-codebuddy.js <mcp.json> <name> <command> [args...]');
  process.exit(1);
}
const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14);
fs.copyFileSync(file, file + '.bak-mcp-' + stamp);
const d = JSON.parse(fs.readFileSync(file, 'utf8'));
if (!d.mcpServers) d.mcpServers = {};
d.mcpServers[name] = { type: 'stdio', command: command, args: args };
fs.writeFileSync(file, JSON.stringify(d, null, 2) + '\n', 'utf8');
const check = JSON.parse(fs.readFileSync(file, 'utf8'));
const s = check.mcpServers[name];
if (!s || s.command !== command || JSON.stringify(s.args) !== JSON.stringify(args)) {
  console.error('rewrite verification failed');
  process.exit(1);
}
console.log('CODEBUDDY_REGISTER_OK');
