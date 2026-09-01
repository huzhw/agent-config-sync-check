'use strict';
// ssh-mcp launcher - the single password injection point for all agent ends.
// Reads ssh-passwords.env (same directory, KEY=VALUE lines, never in git),
// injects the pairs into this process env (existing real env vars win), then
// spawns ssh-mcp with stdio passthrough. MCP registrations stay password-free:
// they only reference this launcher + the TOML, both via the per-end junction.
//
// Usage: node launcher.js [--config=<path to ssh-mcp-config.toml>]
// (any extra args are forwarded to ssh-mcp verbatim)
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

const here = __dirname;
const args = process.argv.slice(2);

// 1. inject passwords (file wins nothing: real env vars keep priority)
const pwFile = path.join(here, 'ssh-passwords.env');
let injected = 0;
if (fs.existsSync(pwFile)) {
  for (const line of fs.readFileSync(pwFile, 'utf8').split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/);
    if (m && !(m[1] in process.env)) {
      process.env[m[1]] = m[2];
      injected++;
    }
  }
} else {
  process.stderr.write('[ssh-mcp-launcher] warning: passwords file not found: ' + pwFile + '\n');
}

// 2. spawn ssh-mcp via shell (the npm .cmd shim cannot be spawned directly on
//    Windows without a shell); args are --key=value forms without spaces.
function quote(a) {
  return /[^\w@%+=:,./\\-]/.test(a) ? '"' + a.replace(/"/g, '\\"') + '"' : a;
}
const child = spawn('ssh-mcp ' + args.map(quote).join(' '), {
  shell: true,
  stdio: 'inherit',
});
child.on('error', (err) => {
  process.stderr.write('[ssh-mcp-launcher] spawn failed: ' + err.message + '\n');
  process.exit(1);
});
child.on('exit', (code, signal) => {
  process.exit(signal ? 1 : (code || 0));
});
