'use strict';
// Convert Claude settings.json hook entries into target-end form.
// usage: node hooks-convert.js <input.json>   (result JSON goes to stdout)
// input: {
//   entries: [ { event, matcher, type, command, timeout, timeoutMs } ],
//   supportedEvents: [..],        // events the target end can run
//   dropEvents: [..],             // events never to sync to this end
//   dropToolsInMatcher: [..],     // tool names removed from matcher alternations
//   rewrites: [ {match, replace} ], // literal string rewrites applied to command
//   excludeCommandPatterns: [..], // wildcard (* ?) patterns, matching = skip
//   preferredType: "process"|"command"  // process = split shell strings
// }
// output: { entries: [ {event, matcher, type, command, args, timeoutMs, key} ],
//           skipped: [ {event, command, reason} ] }
// key = the identity token (script path); the writer uses it to match old entries.
const fs = require('fs');
const HOME = (process.env.HOME || process.env.USERPROFILE || '').replace(/\\/g, '/');
const input = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const out = { entries: [], skipped: [] };

// PS 5.1 ConvertTo-Json unfolds single-element arrays into bare objects and
// turns empty ones into null; normalize every list field to a clean array.
function asArr(v) {
  if (v == null) return [];
  const a = Array.isArray(v) ? v : [v];
  return a.filter(function (x) { return x != null; });
}
input.entries = asArr(input.entries);
input.supportedEvents = asArr(input.supportedEvents);
input.dropEvents = asArr(input.dropEvents);
input.dropToolsInMatcher = asArr(input.dropToolsInMatcher);
input.rewrites = asArr(input.rewrites);
input.excludePatterns = asArr(input.excludePatterns);

// wildcard (* ?) SUBSTRING match: the pattern must appear anywhere in the
// command string (patterns are typically script file names, commands are
// full paths with quotes and arguments)
function wcMatch(s, pat) {
  const rx = new RegExp(pat.replace(/[.+^${}()|[\]\\]/g, '\\$&')
    .replace(/\*/g, '.*').replace(/\?/g, '.'), 'i');
  return rx.test(s);
}

for (const e of input.entries) {
  // PS 5.1 ConvertTo-Json over-escapes backslashes (\\ becomes \\\\ in the
  // JSON text, i.e. a literal double backslash after parsing); collapse them
  // so Windows paths survive (UNC \\\\server degrades to \\\\server, still valid)
  const cmd = String(e.command || '').replace(/\\\\/g, '\\');
  if ((input.dropEvents || []).indexOf(e.event) >= 0) {
    out.skipped.push({ event: e.event, command: cmd, reason: 'event dropped: ' + e.event });
    continue;
  }
  if ((input.supportedEvents || []).indexOf(e.event) < 0) {
    out.skipped.push({ event: e.event, command: cmd, reason: 'event not supported' });
    continue;
  }
  if (input.excludePatterns.some(function (p) { return wcMatch(cmd, p); })) {
    out.skipped.push({ event: e.event, command: cmd, reason: 'excluded by pattern' });
    continue;
  }

  let c = cmd;
  for (const rw of input.rewrites || []) c = c.split(rw.match).join(rw.replace);

  let matcher = e.matcher || '';
  for (const t of input.dropToolsInMatcher || []) {
    matcher = matcher.split('|').map(function (s) { return s.trim(); })
      .filter(function (s) { return s && s !== t; }).join('|');
  }

  const timeoutMs = e.timeoutMs != null ? Math.round(e.timeoutMs)
    : (e.timeout != null ? Math.round(e.timeout * 1000) : null);

  if (String(input.preferredType) !== 'process') {
    out.entries.push({ event: e.event, matcher: matcher, type: 'command', command: c, args: [], timeoutMs: timeoutMs, key: c });
    continue;
  }

  // strip quotes and expand $HOME so paths become plain tokens
  const flat = c.replace(/"\$HOME"\/?/g, HOME + '/').replace(/"/g, '');

  // form 1: [env] node <path>.cjs|.js [rest...]
  let m = flat.match(/(?:^|\s)node\s+([^\s]+\.(?:cjs|js))\s*(.*)$/i);
  if (m) {
    const args = [m[1]];
    m[2].split(/\s+/).forEach(function (t) { if (t) args.push(t); });
    out.entries.push({ event: e.event, matcher: matcher, type: 'process', command: 'node', args: args, timeoutMs: timeoutMs, key: m[1] });
    continue;
  }
  // form 2: <path>.sh (bash script, $HOME expanded above)
  m = flat.match(/([^\s]+\.sh)\s*$/);
  if (m) {
    out.entries.push({ event: e.event, matcher: matcher, type: 'process', command: 'bash', args: [m[1]], timeoutMs: timeoutMs, key: m[1] });
    continue;
  }
  // fallback: keep as a command-type entry, verbatim
  out.entries.push({ event: e.event, matcher: matcher, type: 'command', command: flat, args: [], timeoutMs: timeoutMs, key: flat });
}

console.log(JSON.stringify(out));
