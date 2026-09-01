'use strict';
// Rewrite mcpServers.ssh in the Claude global config to the launcher form:
// command=node, args=[launcher.js, --config=<toml>], env={} - no secrets kept
// in this file. A timestamped backup is written next to the config first.
const fs = require('fs');
const [file, launcherPath, cfgPath] = process.argv.slice(2);
if (!file || !launcherPath || !cfgPath) {
  console.error('usage: node ssh-claude-register.js <claude.json> <launcherPath> <configPath>');
  process.exit(1);
}
const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14);
fs.copyFileSync(file, file + '.bak-sshmcp-' + stamp);
const d = JSON.parse(fs.readFileSync(file, 'utf8'));
if (!d.mcpServers) {
  console.error('no mcpServers');
  process.exit(1);
}
d.mcpServers.ssh = { command: 'node', args: [launcherPath, '--config=' + cfgPath], env: {} };
fs.writeFileSync(file, JSON.stringify(d, null, 2), 'utf8');
const check = JSON.parse(fs.readFileSync(file, 'utf8'));
const s = check.mcpServers.ssh;
if (!s || s.command !== 'node' || s.args[0] !== launcherPath || s.args[1] !== '--config=' + cfgPath) {
  console.error('rewrite verification failed');
  process.exit(1);
}
console.log('CLAUDE_REGISTER_OK');
