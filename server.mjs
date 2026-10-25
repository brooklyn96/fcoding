#!/usr/bin/env node
// fcoding server: Node 22, built-ins only. See CONTRACT.md (S1-S8, A1-A5).
import http from 'node:http';
import net from 'node:net';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFile, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const HARNESSES = { omp: 'omp', claude: 'claude', codex: 'codex', shell: 'bash -l' };
export const KEYS = ['Enter', 'Escape', 'Tab', 'BTab', 'Up', 'Down', 'Left', 'Right', 'PageUp', 'PageDown',
  'Home', 'End', 'BSpace', 'C-c', 'C-d', 'C-l', 'C-o', 'C-r', 'C-u', 'C-z', 'M-a', 'y', 'n', 'Space'];
const NAME_RE = /^[a-z0-9][a-z0-9-]{0,31}$/;
const COOKIE = 'pc_sid';
const COOKIE_MAX_AGE = 30 * 24 * 3600;
const BODY_LIMIT = 64 * 1024;
const TEXT_LIMIT = 32 * 1024;
const LONG_TEXT = 500; // bytes; longer single lines are pasted, not typed
const PAIR_TTL = 120 * 1000, PAIR_ATTEMPTS = 5, PAIR_PENDING = 3;
const PAIR_PER_MINUTE = 10, PAIR_MINUTE = 60 * 1000, PAIR_PER_HOUR = 30, PAIR_HOUR = 3600 * 1000;
const MAX_STREAMS = 50;
const MAX_WAITING = 20; // mutation jobs waiting behind the active one
const MAX_READS = 7; // 8 tmux children in all: one slot is reserved for the active mutation
const DRAIN_TIMEOUT = 30000;
const HARNESS_CHECK_MS = 400; // after create: is the harness still running?
const RUNNING_MS = 8000; // overview: activity this recent = running
const GIT_CACHE_MS = 10000; // overview: git results per project
const NOT_FOUND_RE = /can't find|no such session|no server running|no sessions|error connecting to|no current/i;
// JSON for an SSE data line: U+2028, U+2029 and U+0085 escaped (line breaks to some line readers; still valid JSON)
const SSE_BREAKS = new RegExp(`[${String.fromCharCode(0x2028, 0x2029, 0x85)}]`, 'g');
const sseJson = (v) => JSON.stringify(v).replace(SSE_BREAKS, (ch) => `\\u${ch.charCodeAt(0).toString(16).padStart(4, '0')}`);
const shq = (s) => `'${s.replace(/'/g, "'\\''")}'`;
// harness PATH is explicit: neither the tmux server's nor the unit's PATH is relied on (A3)
const home = os.homedir();
const HARNESS_ENV = `env LANG=C.UTF-8 LC_ALL=C.UTF-8 ${shq(`PATH=${home}/.local/bin:${home}/.bun/bin:/usr/local/bin:/usr/bin:/bin`)} `;

const SEC_HEADERS = {
  'Content-Security-Policy': "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'",
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
};

class HttpErr extends Error {
  constructor(status, code, extra = {}) { super(code); this.status = status; this.code = code; Object.assign(this, extra); }
}

// ---------- config / devices / admin socket ----------
export function defaultConfigDir() {
  if (process.env.PC_CONFIG_DIR) return process.env.PC_CONFIG_DIR;
  return fs.existsSync('/data/home') ? '/data/home/.fcoding' : path.join(os.homedir(), '.fcoding');
}
// tmp file, fsync, rename, directory fsync. The rename is the commit point: an error after it carries committed: true.
export function writePrivate(file, data) {
  const dir = path.dirname(file);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const tmp = `${file}.${process.pid}.tmp`;
  try {
    const fd = fs.openSync(tmp, 'w', 0o600);
    try { fs.writeFileSync(fd, data); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
    fs.renameSync(tmp, file);
  } catch (e) { try { fs.unlinkSync(tmp); } catch {} throw e; }
  if (process.platform === 'win32') return;
  try { const d = fs.openSync(dir, 'r'); try { fs.fsyncSync(d); } finally { fs.closeSync(d); } } catch (e) { e.committed = true; throw e; }
}
// Config dir must be a real directory owned by us (0700); config.json and devices.json real, ours, 0600. Throws otherwise.
export function secureConfigDir(dir) {
  const uid = process.getuid?.();
  const check = (p, wantDir) => {
    let st;
    try { st = fs.lstatSync(p); } catch (e) { if (e.code === 'ENOENT') return false; throw e; }
    if (st.isSymbolicLink() || (wantDir ? !st.isDirectory() : !st.isFile())) throw new Error(`unsafe config path (symlink or wrong type): ${p}`);
    if (uid !== undefined && st.uid !== uid) throw new Error(`config path not owned by the current user: ${p}`);
    if (process.platform !== 'win32') fs.chmodSync(p, wantDir ? 0o700 : 0o600);
    return true;
  };
  if (check(dir, true)) for (const f of ['config.json', 'devices.json']) check(path.join(dir, f), false);
}
// Parse + validate a complete candidate. Error messages never quote the file (it holds the secret).
export function parseConfig(text) {
  let c;
  try { c = JSON.parse(text); } catch { throw new Error('config.json is not valid JSON'); }
  if (!c || typeof c !== 'object' || Array.isArray(c)) throw new Error('config.json is not an object');
  const s = c.cookieSecret; // canonical base64 (re-encoding gives the same text) of at least 32 bytes
  if (typeof s !== 'string' || Buffer.from(s, 'base64').length < 32 || Buffer.from(s, 'base64').toString('base64') !== s) throw new Error('config.json: cookieSecret missing or invalid');
  const projects = c.projects ?? {};
  if (typeof projects !== 'object' || projects === null || Array.isArray(projects)) throw new Error('config.json: projects must be an object');
  if (c.port !== undefined && !(Number.isInteger(c.port) && c.port > 0 && c.port < 65536)) throw new Error('config.json: port invalid');
  // publicUrl: the https origin of the published port; the pairing links are built from it and from nothing in a request
  let publicUrl;
  if (c.publicUrl !== undefined) {
    try {
      const u = new URL(c.publicUrl);
      if (typeof c.publicUrl !== 'string' || u.protocol !== 'https:' || u.username || u.password || u.pathname !== '/' || u.search || u.hash) throw new Error('bad');
      publicUrl = u.origin;
    } catch { throw new Error('config.json: publicUrl invalid (want an https origin such as https://box.example.com)'); }
  }
  return {
    secret: Buffer.from(s, 'base64'), port: c.port, projects, publicUrl,
    projectNames: Object.keys(projects).filter((k) => typeof projects[k] === 'string' && path.isAbsolute(projects[k])),
  };
}
// devices.json: {secretTag, devices:[{id, name, keyHash, createdAt}]}; invalid -> throw (no content in the message)
export function parseDevices(text) {
  let d;
  try { d = JSON.parse(text); } catch { throw new Error('devices.json is not valid JSON'); }
  const str = (v, re) => typeof v === 'string' && re.test(v);
  const ok = (x) => x && typeof x === 'object' && str(x.id, /^[0-9a-f]{16}$/) && typeof x.name === 'string' && x.name.length <= 64
    && str(x.keyHash, /^[0-9a-f]{64}$/) && typeof x.createdAt === 'number' && Number.isFinite(x.createdAt);
  if (!d || typeof d !== 'object' || !Array.isArray(d.devices) || !d.devices.every(ok) || new Set(d.devices.map((x) => x.id)).size !== d.devices.length
    || (d.secretTag !== undefined && !str(d.secretTag, /^[0-9a-f]{64}$/))) throw new Error('devices.json is invalid');
  return { secretTag: d.secretTag, devices: d.devices.map(({ id, name, keyHash, createdAt }) => ({ id, name, keyHash, createdAt })) };
}
const NAME_CTRL = /[\x00-\x1f\x7f-\x9f\u061c\u200b-\u200f\u202a-\u202e\u2060\u2066-\u2069\ufeff]/g; // C0, DEL, C1, bidi, zero-width, BOM
const cleanName = (n) => (typeof n === 'string' ? n.replace(NAME_CTRL, '').trim().slice(0, 64) : '');

// --- overview (A5): session state and a one-line preview from the visible pane ---
// approval / question prompts, matched case-insensitively against the last 6 non-empty lines
export const WAIT_PATTERNS = [
  /\(y\/n\)/i, /\[y\/n\]/i, /\[Y\/n\]/i, /\[y\/N\]/i, /\byes\/no\b/i, /\bdo you want\b/i, /\ballow\b/i, /\bapprove\b/i,
  /\bproceed\?/i, /\bcontinue\?/i, /\bpress enter\b/i, /^\s*[❯>]\s*\d+\./,
];
const ANSI_RE = /\x1b\[[0-?]*[ -\/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?|\x1b[@-_]/g;
const BOX_EDGE = /^[\s\u2500-\u259f|]+|[\s\u2500-\u259f|]+$/g; // box drawing + block elements at both ends
const PROMPT_ONLY = /^[>❯›$#%»:]*$/; // a bare prompt symbol is chrome
const cleanLine = (l) => l.replace(ANSI_RE, '').replace(/\t/g, ' ').replace(NAME_CTRL, '').replace(BOX_EDGE, '').trim();
const paneLines = (text) => text.split('\n').map(cleanLine).filter((l) => l && !PROMPT_ONLY.test(l));
// the last non-empty, non-chrome line, at most 160 code points; null when there is none
const clip = (l) => Array.from(l).slice(0, 160).join('');
export function previewOf(text) {
  const lines = paneLines(text);
  return lines.length ? clip(lines.at(-1)) : null;
}
// the last 6 non-empty lines of the pane, cleaned like a preview (so "│ ❯ 1. Yes │" is "❯ 1. Yes")
const tailLines = (text) => text.split('\n').map((l) => l.replace(ANSI_RE, '').replace(NAME_CTRL, '')).filter((l) => l.trim()).slice(-6).map(cleanLine);
// of those, the ones that match a prompt pattern
const promptLines = (text) => tailLines(text).filter((l) => l && WAIT_PATTERNS.some((re) => re.test(l)));
const CHOICE_RE = /^[❯>›]?\s*\d+\.\s/; // a numbered option such as "❯ 1. Yes"
// A5 update 6: a numbered menu is on screen (any of the last 6 lines, matched or not). The app then offers no y/n buttons,
// because the letter + Enter would confirm the highlighted option.
export const menuOf = (text) => tailLines(text).some((l) => CHOICE_RE.test(l));
// the question for the preview: the last matching line that is not a numbered option; else the last option; null when none matches
function promptLine(text) {
  const m = promptLines(text);
  return m.findLast((l) => !CHOICE_RE.test(l)) ?? m.at(-1) ?? null;
}
export function stateOf(text, activity, nowMs) {
  if (nowMs - activity * 1000 <= RUNNING_MS) return 'running';
  return promptLine(text) === null ? 'idle' : 'waiting';
}
// {state, preview, menu}: when waiting, the preview is the question line (cleaned like any preview), so the app sees the y/n question
export function summarize(text, activity, nowMs) {
  const state = stateOf(text, activity, nowMs);
  return { state, preview: state === 'waiting' ? clip(cleanLine(promptLine(text))) || previewOf(text) : previewOf(text), menu: menuOf(text) };
}
// " 2 files changed, 3 insertions(+), 1 deletion(-)" -> {files, add, del}; empty output = clean tree
export function parseShortstat(out) {
  const n = (re) => Number(re.exec(out)?.[1] ?? 0);
  return { files: n(/(\d+) files? changed/), add: n(/(\d+) insertions?\(\+\)/), del: n(/(\d+) deletions?\(-\)/) };
}
// admin.sock (unix socket, 600, in the 700 config dir); a named pipe on Windows (tests only)
export const adminPath = (configDir) => (process.platform === 'win32'
  ? `\\\\.\\pipe\\fcoding-${crypto.createHash('sha256').update(path.resolve(configDir)).digest('hex').slice(0, 16)}`
  : path.join(configDir, 'admin.sock'));
// --- single instance (A4 update r3): a lock held for the life of the process, taken before anything else ---
// Linux: an abstract unix socket (no file; the kernel frees the name when the process dies). Windows (tests): a named pipe.
export function lockName(configDir) {
  let real;
  try { real = fs.realpathSync(configDir); } catch { real = path.resolve(configDir); }
  const h = crypto.createHash('sha256').update(real).digest('hex').slice(0, 32);
  return process.platform === 'win32' ? `\\\\.\\pipe\\fcoding-lock-${h}` : `${String.fromCharCode(0)}fcoding-lock-${h}`;
}
export function acquireInstanceLock(configDir) {
  return new Promise((resolve, reject) => {
    const lock = net.createServer((s) => s.destroy()); // only holds the name; nobody needs to connect
    lock.once('error', (e) => reject(e.code === 'EADDRINUSE' ? new Error('Một máy chủ FCode khác đang dùng thư mục cấu hình này') : e));
    lock.listen(lockName(configDir), () => resolve(lock));
  });
}
// one JSON request line -> one JSON response line. Rejects with code ENOSERVER when no server listens.
export function adminRequest(configDir, req, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const s = net.connect(adminPath(configDir));
    let buf = '';
    const t = setTimeout(() => { s.destroy(); reject(new Error('admin socket timeout')); }, timeoutMs);
    s.on('connect', () => s.end(`${JSON.stringify(req)}\n`));
    s.on('data', (d) => { buf += d; });
    s.on('end', () => { clearTimeout(t); try { resolve(JSON.parse(buf)); } catch { reject(new Error('bad admin reply')); } });
    s.on('error', (e) => {
      clearTimeout(t);
      reject(['ENOENT', 'ECONNREFUSED'].includes(e.code) ? Object.assign(new Error('the fcoding server is not running'), { code: 'ENOSERVER' }) : e);
    });
  });
}
// trailing blank lines only, linear: spaces on the last real line stay
export function trimScreen(s) {
  let j = s.length - 1;
  while (j >= 0 && (s[j] === ' ' || s[j] === '\t' || s[j] === '\n')) j--;
  if (j < 0) return '';
  const nl = s.indexOf('\n', j);
  return nl < 0 ? s : s.slice(0, nl);
}

// --- ansi=1: the screen keeps SGR colours (ESC [ ... m) and nothing else ---
// Every other escape sequence (other CSI, OSC such as hyperlinks, DCS/APC/PM/SOS, two-byte ESC, a lone ESC) is dropped,
// and so are SO/SI (0x0E/0x0F, charset shifts), so the text equals what a plain capture-pane prints.
const ESC_RE = /[\x0e\x0f]|\x1b(?:\[([0-?]*)([ -\/]*)([@-~])?|[\]PX^_][^\x07\x1b\n]*(?:\x07|\x1b\\)?|[ -\/]*[0-~]?)/g;
const SGR_RE = /\x1b\[[0-9;]*m/g;
// A clean SGR: ";"-separated integers only. Colon forms become semicolon forms (38:2::r:g:b -> 38;2;r;g;b, 4:3 -> 4, 4:0 -> 24),
// the underline colour (58) is dropped, a bad or cut-off colour is dropped, and no code above 107 is passed. Nothing left = no sequence.
function cleanSgr(params) {
  if (!/^[0-9;:]*$/.test(params)) return '';
  const t = [];
  for (const g of params.split(';')) {
    const [h, ...sub] = g.split(':').map((x) => (x === '' ? 0 : Number(x))); // an empty parameter is 0
    if (!sub.length) t.push(h);
    else if (h === 38 || h === 48 || h === 58) { // colon colour: whole, or dropped (a cut-off one is never rewritten)
      if (sub[0] === 5 && sub.length >= 2) t.push(h, 5, sub[1]);
      else if (sub[0] === 2 && sub.length >= (g.split(':')[2] === '' ? 5 : 4)) t.push(h, 2, ...sub.slice(-3)); // 2:[colourspace:]r:g:b; an empty colourspace slot is there, so r:g:b must follow it
    } else if (h === 4) t.push(sub[0] === 0 ? 24 : 4); // underline styles
    else if (h === 5 && sub[0] === 3) t.push(53); // overline written as 5:3; it must not become blink (5)
    // any other colon group is dropped
  }
  const out = [];
  for (let i = 0; i < t.length; i++) {
    if (t[i] === 38 || t[i] === 48 || t[i] === 58) {
      const end = i + (t[i + 1] === 5 ? 2 : t[i + 1] === 2 ? 4 : t.length); // last index of "38;5;n" / "38;2;r;g;b"
      if (end >= t.length) break; // cut off or an unknown mode: nothing after it can be trusted
      if (t[i] !== 58 && t.slice(i + 2, end + 1).every((v) => v <= 255)) out.push(...t.slice(i, end + 1));
      i = end;
    } else if (t[i] <= 107 && t[i] !== 59) out.push(t[i]);
  }
  return out.length ? `\x1b[${out.join(';')}m` : '';
}
export const sgrOnly = (s) => (/[\x0e\x0f\x1b]/.test(s) ? s.replace(ESC_RE, (_m, params, inter, fin) => (fin === 'm' && !inter ? cleanSgr(params) : '')) : s);
// like trimScreen, but a trailing line that holds only SGR and blanks counts as blank
export function trimAnsiScreen(s) {
  const lines = s.split('\n');
  while (lines.length && /^[ \t]*$/.test(lines.at(-1).replace(SGR_RE, ''))) lines.pop();
  return lines.join('\n');
}

// GET /pair: a tiny page with one button that opens the app link. Only 6 digits and the configured origin reach it.
const escHtml = (t) => t.replace(/[&<>"']/g, (ch) => `&#${ch.charCodeAt(0)};`);
export function pairPage(appLink, status = 200) {
  const note = status === 503 ? 'Máy chủ chưa đặt địa chỉ công khai, nên chưa tạo được link ghép.'
    : status === 400 ? 'Link ghép không hợp lệ. Hãy tạo mã mới trong app FCode.' : null;
  const body = note ? `<p>${note}</p>`
    : `<a class="btn" href="${escHtml(appLink)}">Mở FCode</a><p>Mã dùng 1 lần, hết hạn sau ${PAIR_TTL / 60000} phút.</p><p class="s">Chưa cài FCode? Cài file fcode.ipa trước.</p>`;
  return `<!doctype html><html lang="vi"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>Ghép FCode</title><style>body{margin:0;font:17px/1.5 -apple-system,system-ui,sans-serif;background:#111;color:#eee;text-align:center}main{padding:48px 24px}.btn{display:block;max-width:320px;margin:24px auto;padding:16px;border-radius:14px;background:#0a84ff;color:#fff;font-size:20px;font-weight:600;text-decoration:none}.s{color:#999;font-size:15px}</style></head><body><main><h1>Ghép iPhone với FCode</h1>${body}</main></body></html>`;
}

// ---------- app ----------
export function createApp(opts = {}) {
  const configDir = opts.configDir || defaultConfigDir();
  let tmuxSpec = opts.tmux ?? process.env.PC_TMUX ?? 'tmux';
  if (typeof tmuxSpec === 'string') tmuxSpec = tmuxSpec.startsWith('[') ? JSON.parse(tmuxSpec) : [tmuxSpec];
  const log = opts.log || ((s) => console.log(s));
  const pollMs = opts.pollMs ?? 700;
  const pingMs = opts.pingMs ?? 15000;
  const drainTimeout = opts.drainTimeoutMs ?? DRAIN_TIMEOUT;
  const pasteEnterDelay = opts.pasteEnterDelayMs ?? 120;
  const now = opts.now || Date.now;
  const writeFile = opts.writePrivate || writePrivate;
  let gitSpec = opts.git ?? process.env.PC_GIT ?? 'git';
  if (typeof gitSpec === 'string') gitSpec = gitSpec.startsWith('[') ? JSON.parse(gitSpec) : [gitSpec];

  secureConfigDir(configDir);

  // --- config: invalid at startup -> throw (exit 1); invalid on reload -> keep the previous one ---
  const cfgFile = path.join(configDir, 'config.json');
  const stampOf = () => { try { const s = fs.statSync(cfgFile); return `${s.mtimeMs}:${s.size}:${s.ino}`; } catch { return ''; } };
  let cfgStamp = stampOf();
  let text;
  try { text = fs.readFileSync(cfgFile, 'utf8'); } catch { throw new Error(`config.json missing or unreadable in ${configDir} (run install.sh)`); }
  let cfg = parseConfig(text);
  let gen = 0; // bumped whenever the cookie secret changes

  // --- devices: persisted in devices.json, keyed by HMAC-SHA256(secret, token); the token itself is never stored ---
  const devFile = path.join(configDir, 'devices.json');
  let devText = null;
  try { devText = fs.readFileSync(devFile, 'utf8'); } catch (e) { if (e.code !== 'ENOENT') throw new Error('devices.json unreadable'); }
  const devices = new Map(); // id -> device; removing an id is that device's generation bump (ids are random, never reused)
  const byKey = new Map(); // keyHash -> id
  const load = (list) => { devices.clear(); byKey.clear(); for (const d of list) { devices.set(d.id, d); byKey.set(d.keyHash, d.id); } };
  const tagOf = (secret) => crypto.createHmac('sha256', secret).update('fcoding-devices').digest('hex');
  // write the list; the rename is the commit point (a later dir-fsync error is only logged). Throws when nothing changed.
  function writeDevices(list) {
    try { writeFile(devFile, JSON.stringify({ secretTag: tagOf(cfg.secret), devices: list }, null, 2)); } catch (e) {
      if (!e.committed) throw e;
      log(`devices.json directory fsync failed: ${e.code || 'error'}`);
    }
  }
  // devices.json written for another cookieSecret: devices are dropped from memory first, then the file is rewritten empty
  let purgePending = false, purgeAt = -Infinity;
  function purge() {
    purgeAt = now();
    try { writeDevices([]); purgePending = false; } catch (e) { purgePending = true; log(`devices.json purge failed: ${e.code || 'error'}`); }
    return !purgePending;
  }
  const stored = devText === null ? { devices: [] } : parseDevices(devText);
  if (stored.secretTag === undefined ? stored.devices.length > 0 : stored.secretTag !== tagOf(cfg.secret)) purge();
  else load(stored.devices);
  // durable first, memory second: when the write fails before the rename nothing changes (the caller answers 500 / exit 1)
  function commitDevices(list) {
    if (purgePending && !purge()) throw new Error('purge pending');
    writeDevices(list);
    load(list);
  }
  // force: an admin request. A pending purge is retried on force, on a config change, else at most once per second.
  function refreshConfig(force = false) {
    const st = stampOf();
    const changed = st !== cfgStamp;
    if (changed) {
      cfgStamp = st; // a bad file is retried on its next change
      let next = null;
      try { next = parseConfig(fs.readFileSync(cfgFile, 'utf8')); } catch (e) { log(`config reload failed, keeping the previous one: ${e.code || e.message}`); }
      if (next) {
        const rotated = !next.secret.equals(cfg.secret);
        cfg = next;
        if (rotated) { gen++; load([]); purge(); return; } // no old keyHash may match any more
      }
    }
    if (purgePending && (force || changed || now() - purgeAt >= 1000)) purge();
  }
  const keyOf = (token) => crypto.createHmac('sha256', cfg.secret).update(token).digest('hex');
  // ctx = {cancelled, device, gen}: the request is alive, its device still paired, the config generation unchanged
  function valid(ctx) {
    refreshConfig();
    return !ctx.cancelled && ctx.gen === gen && !purgePending && !!ctx.device && devices.has(ctx.device);
  }
  const gateErr = (ctx) => (ctx.cancelled ? new HttpErr(499, 'cancelled') : new HttpErr(401, 'unauthorized'));

  // --- pairing: up to 3 pending 6-digit codes (a shell code and QR codes do not cancel each other), each 120 s and single use,
  // 5 wrong attempts while it is live; /api/pair limited to 10/min and 30/h ---
  let pendings = []; // oldest first: {code, name, expiresAt, attempts}
  const pairHits = [];
  function pairLimited(t) {
    while (pairHits.length && pairHits[0] <= t - PAIR_HOUR) pairHits.shift();
    const minute = pairHits.filter((x) => x > t - PAIR_MINUTE);
    if (minute.length >= PAIR_PER_MINUTE) return Math.max(1, Math.ceil((minute[0] + PAIR_MINUTE - t) / 1000));
    if (pairHits.length >= PAIR_PER_HOUR) return Math.max(1, Math.ceil((pairHits[0] + PAIR_HOUR - t) / 1000));
    pairHits.push(t);
    return 0;
  }
  // constant-time: the comparison never depends on where the digits differ
  const codeMatches = (code, p) => typeof code === 'string' && /^\d{6}$/.test(code) && crypto.timingSafeEqual(Buffer.from(code), Buffer.from(p.code));
  function pair(code, name) {
    const t = now();
    pendings = pendings.filter((p) => t < p.expiresAt);
    const hits = pendings.map((p) => codeMatches(code, p)); // every live code is compared, none is skipped
    const i = hits.indexOf(true);
    if (i < 0) { // a wrong guess is one attempt against every live code; a code with 5 is gone
      pendings = pendings.filter((p) => ++p.attempts < PAIR_ATTEMPTS);
      throw new HttpErr(401, 'bad_code');
    }
    const [used] = pendings.splice(i, 1); // single use, even if the write below fails
    const devName = used.name || cleanName(name) || 'device';
    refreshConfig();
    if (purgePending) throw new HttpErr(500, 'storage');
    const token = crypto.randomBytes(32).toString('base64url');
    const dev = { id: crypto.randomBytes(8).toString('hex'), name: devName, keyHash: keyOf(token), createdAt: t };
    try { commitDevices([...devices.values(), dev]); } catch { throw new HttpErr(500, 'storage'); }
    return token;
  }
  function revoke(ids) { // throws on a failed write; nothing changes then
    commitDevices([...devices.values()].filter((d) => !ids.includes(d.id)));
  }
  // a new pending code (3 at most: the oldest goes when a 4th is made); used by the shell command and by POST /api/pair-code
  function newPairing(name) {
    const t = now();
    pendings = pendings.filter((p) => t < p.expiresAt);
    let code;
    do code = String(crypto.randomInt(0, 1e6)).padStart(6, '0'); while (pendings.some((p) => p.code === code)); // codes of live pairings differ
    const p = { code, name: cleanName(name), expiresAt: t + PAIR_TTL, attempts: 0 };
    pendings.push(p);
    while (pendings.length > PAIR_PENDING) pendings.shift();
    return p;
  }
  // {appLink, shareLink} from cfg.publicUrl only; null when it is not configured. The code is 6 digits, the name is encoded.
  function pairLinks(code, name) {
    const o = cfg.publicUrl;
    if (!o) return null;
    return {
      appLink: `fcode://pair?server=${encodeURIComponent(o)}&code=${code}${name ? `&name=${encodeURIComponent(name)}` : ''}`,
      shareLink: `${o}/pair?code=${code}`,
    };
  }
  function admin(req) {
    refreshConfig(true); // a rotation or a pending purge is handled before any answer
    if (req?.cmd === 'pair') {
      const p = newPairing(req.name);
      return { ok: true, code: p.code, expiresAt: p.expiresAt, expiresIn: PAIR_TTL / 1000, ...(req.links && { links: pairLinks(p.code, p.name) }) };
    }
    if (req?.cmd === 'devices') return { ok: true, devices: [...devices.values()].map(({ id, name, createdAt }) => ({ id, name, createdAt })) };
    if (req?.cmd === 'revoke') {
      const ids = req.id === 'all' ? [...devices.keys()] : [req.id];
      if (req.id !== 'all' && !devices.has(req.id)) return { ok: false, error: 'no such device' };
      try { revoke(ids); } catch (e) { return { ok: false, error: `storage: ${e.code || 'write failed'}` }; }
      return { ok: true, revoked: ids.length };
    }
    return { ok: false, error: 'unknown command' };
  }
  const adminServer = net.createServer((sock) => {
    let buf = '', done = false; // only the first line of a connection is handled
    sock.setTimeout(5000, () => sock.destroy());
    sock.on('error', () => {});
    sock.on('data', (d) => {
      if (done) return;
      buf += d;
      if (buf.length > 4096) return sock.destroy();
      const i = buf.indexOf('\n');
      if (i < 0) return;
      done = true;
      let req; try { req = JSON.parse(buf.slice(0, i)); } catch { req = null; }
      sock.end(`${JSON.stringify(admin(req))}\n`);
    });
  });
  const adminFile = adminPath(configDir);
  async function listenAdmin() {
    if (process.platform !== 'win32') {
      let st = null;
      try { st = fs.lstatSync(adminFile); } catch {}
      if (st) { // only the instance-lock holder gets here (main): an old socket is always ours to replace
        if (!st.isSocket()) throw new Error(`unsafe admin socket path (not a socket): ${adminFile}`);
        fs.unlinkSync(adminFile);
      }
    }
    await new Promise((resolve, reject) => {
      adminServer.once('error', reject);
      const old = process.umask(0o177); // the socket is born 600
      try { adminServer.listen(adminFile, resolve); } finally { process.umask(old); }
    });
    if (process.platform !== 'win32') fs.chmodSync(adminFile, 0o600);
  }

  // --- the one execution gate: every tmux child goes through run(ctx); execFile only, never a shell ---
  let running = 0, reads = 0;
  // spec: the binary (tmux by default; git for the overview). ctx.held: the job already holds one read slot.
  function run(ctx, args, input, spec = tmuxSpec) {
    if (!ctx) throw new Error('run() without ctx');
    const read = !ctx.mutation && !ctx.held;
    if (read && reads >= MAX_READS) return Promise.reject(new HttpErr(503, 'busy')); // reads never queue
    if (!valid(ctx)) return Promise.reject(gateErr(ctx)); // checked after capacity, nothing awaited before execFile
    running++; if (read) reads++;
    let freed = false;
    const free = () => { if (!freed) { freed = true; running--; if (read) reads--; } };
    return new Promise((resolve, reject) => {
      const [cmd, ...pre] = spec;
      try {
        const child = execFile(cmd, [...pre, ...args], {
          encoding: 'utf8', timeout: 5000, maxBuffer: 16 << 20, windowsHide: true,
          env: { ...process.env, LANG: 'C.UTF-8', LC_ALL: 'C.UTF-8', ...(spec === gitSpec && { GIT_OPTIONAL_LOCKS: '0' }) },
        }, (err, stdout, stderr) => {
          free();
          if (!err) return resolve(stdout);
          if (err.code === 'ENOENT') return reject(new HttpErr(500, 'tmux_missing'));
          const notFound = NOT_FOUND_RE.test(stderr || '');
          reject(new HttpErr(notFound ? 404 : 500, notFound ? 'not_found' : 'tmux', { stderr: stderr || '' }));
        });
        child.stdin.on('error', () => {});
        child.stdin.end(input === undefined ? undefined : Buffer.from(input, 'utf8'));
      } catch (e) { free(); reject(e); }
    });
  }

  // --- mutations: whole jobs in one FIFO, one active, at most MAX_WAITING waiting ---
  const queue = [];
  let active = null;
  function mutate(ctx, fn) {
    if (queue.length >= MAX_WAITING) throw new HttpErr(503, 'busy');
    return new Promise((resolve, reject) => {
      const job = { ctx, fn, resolve, reject };
      queue.push(job);
      ctx.onCancel = () => { const i = queue.indexOf(job); if (i >= 0) { queue.splice(i, 1); reject(gateErr(ctx)); } };
      pump();
    });
  }
  function pump() {
    while (!active && queue.length) {
      const job = queue.shift();
      if (!valid(job.ctx)) { job.reject(gateErr(job.ctx)); continue; }
      active = job;
      job.ctx.mutation = true; // its children use the reserved slot
      Promise.resolve().then(job.fn).then(job.resolve, job.reject).finally(() => { active = null; pump(); });
    }
  }

  // exact-match targets (a bare name would prefix-match another session)
  const pane = (name) => `=${name}:`;
  const sess = (name) => `=${name}`;
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  async function listSessions(ctx) {
    let out;
    try {
      // activity = the later of session_activity (client input) and window_activity (pane output; tmux does not move session_activity on output)
      out = await run(ctx, ['list-sessions', '-F', '#{session_name}|#{session_created}|#{session_attached}|#{session_activity}|#{window_activity}|#{@pc_harness}|#{@pc_project}']);
    } catch (e) {
      if (e.status === 404) return [];
      throw e;
    }
    const rows = [];
    for (const line of out.split('\n')) {
      const [name, created, attached, sActivity, wActivity, harness, ...rest] = line.split('|');
      if (!NAME_RE.test(name || '')) continue;
      rows.push({
        name, project: rest.join('|') || null, harness: harness || null,
        created: Number(created) || 0, attached: Number(attached) > 0, activity: Math.max(Number(sActivity) || 0, Number(wActivity) || 0),
      });
    }
    return rows;
  }

  const validProject = (p) => typeof p === 'string' && cfg.projectNames.includes(p);
  const validHarness = (h) => typeof h === 'string' && Object.hasOwn(HARNESSES, h);
  // runs inside a mutation job
  async function createSession(name, project, harness, ctx) {
    try {
      await run(ctx, ['new-session', '-d', '-s', name, '-c', cfg.projects[project], HARNESS_ENV + HARNESSES[harness]]);
    } catch (e) {
      if (/duplicate session/i.test(e.stderr || '')) throw new HttpErr(409, 'exists');
      throw e;
    }
    try {
      await run(ctx, ['set-option', '-t', pane(name), '@pc_project', project]);
      await run(ctx, ['set-option', '-t', pane(name), '@pc_harness', harness]);
    } catch (e) {
      if (e.status === 404) throw new HttpErr(500, 'harness_exited'); // the session died right after new-session
      await run(ctx, ['kill-session', '-t', sess(name)]).catch(() => {}); // only the session this job created
      throw e;
    }
    await sleep(HARNESS_CHECK_MS); // a harness that cannot start (missing tool, bad env) exits within this
    try { await run(ctx, ['has-session', '-t', sess(name)]); } catch (e) {
      if (e.status === 404) throw new HttpErr(500, 'harness_exited');
      throw e;
    }
  }

  // cursor is relative to the visible pane; rows = visible height; text may include history above it
  // ansi: keep the SGR colours (capture-pane -e, then only SGR survives); hash and change detection cover the text as sent
  async function getScreen(name, lines, ctx, ansi = false) {
    if (!ctx.mutation && reads + 2 > MAX_READS) throw new HttpErr(503, 'busy'); // both slots or neither
    const [cap, info] = await Promise.all([
      run(ctx, ['capture-pane', '-p', ...(ansi ? ['-e'] : []), '-J', '-t', pane(name), '-S', `-${lines}`]),
      run(ctx, ['display-message', '-p', '-t', pane(name), '#{pane_width} #{pane_height} #{cursor_x} #{cursor_y}']),
    ]);
    const [cols, rows, x, y] = info.trim().split(' ').map(Number);
    const text = ansi ? trimAnsiScreen(sgrOnly(cap)) : trimScreen(cap);
    const hash = crypto.createHash('sha1').update(`${cols}x${rows}@${x},${y}\n${text}`).digest('hex').slice(0, 16);
    return { text, rows, cols, cursor: { x, y }, hash };
  }

  // --- GET /api/overview: ONE read job holding one read slot; its tmux/git calls run one after another ---
  const gitCache = new Map(); // dir -> {at, value} once done, {pending} while one overview runs git for it
  const gateStop = (e) => e instanceof HttpErr && (e.status === 401 || e.status === 499);
  async function gitRound(dir, ctx) {
    const git = async (...args) => { // repo-local config cannot start an fsmonitor; no optional locks (env)
      try { return (await run(ctx, ['-C', dir, '-c', 'core.fsmonitor=false', ...args], undefined, gitSpec)).trim(); } catch (e) { if (gateStop(e)) throw e; return null; }
    };
    const raw = await git('rev-parse', '--abbrev-ref', 'HEAD');
    const branch = raw === null ? null : clip(cleanLine(raw)) || null;
    let value = { branch: null, ahead: null, diff: null };
    if (branch !== null) {
      const diff = await git('diff', '--shortstat', 'HEAD');
      const ahead = await git('rev-list', '--count', '@{upstream}..HEAD');
      value = { branch, ahead: ahead !== null && /^\d+$/.test(ahead) ? Number(ahead) : null, diff: diff === null ? null : parseShortstat(diff) };
    }
    if (!valid(ctx)) throw gateErr(ctx); // stopped while a git child ran: nothing of this round is cached
    return value;
  }
  async function gitInfo(dir, ctx) {
    for (;;) {
      const hit = gitCache.get(dir);
      if (hit?.value && now() - hit.at < GIT_CACHE_MS) return hit.value;
      if (hit?.pending) { // a concurrent cold overview already runs git here: share its result
        try { return await hit.pending; } catch (e) { if (!gateStop(e)) throw e; continue; } // its owner was stopped: try again
      }
      const pending = gitRound(dir, ctx);
      gitCache.set(dir, { pending });
      try {
        const value = await pending;
        gitCache.set(dir, { at: now(), value });
        return value;
      } catch (e) {
        if (gitCache.get(dir)?.pending === pending) gitCache.delete(dir);
        throw e;
      }
    }
  }
  async function overview(ctx) {
    if (reads >= MAX_READS) throw new HttpErr(503, 'busy'); // reads never queue
    if (!valid(ctx)) throw gateErr(ctx);
    reads++; ctx.held = true;
    try {
      const projects = [];
      for (const name of cfg.projectNames) projects.push({ name, ...(await gitInfo(cfg.projects[name], ctx)) });
      const sessions = [];
      for (const x of await listSessions(ctx)) {
        let state = null, preview = null, menu = null; // nulls when this item fails
        try {
          const text = await run(ctx, ['capture-pane', '-p', '-J', '-t', pane(x.name)]); // the visible pane, no escapes
          ({ state, preview, menu } = summarize(text, x.activity, now()));
        } catch (e) { if (gateStop(e)) throw e; }
        sessions.push({ ...x, state, preview, menu });
      }
      return { now: Math.floor(now() / 1000), projects, sessions };
    } finally { reads--; ctx.held = false; }
  }
  // <base>, <base>-2, <base>-3, ...: always within the 32-char name limit (base is shortened, the suffix kept)
  const freshName = (base, n) => {
    if (n === 1) return base;
    const suffix = `-${n}`;
    return base.slice(0, 32 - suffix.length).replace(/-+$/, '') + suffix;
  };

  // runs inside a mutation job; every step re-checks through run(ctx)
  async function sendText(name, text, enter, ctx) {
    text = text.replace(/\r\n?/g, '\n');
    if (text && (text.includes('\n') || Buffer.byteLength(text) > LONG_TEXT)) {
      await run(ctx, ['load-buffer', '-b', 'pc', '-'], text);
      try { await run(ctx, ['paste-buffer', '-p', '-d', '-b', 'pc', '-t', pane(name)]); }
      catch (e) { await run(ctx, ['delete-buffer', '-b', 'pc']).catch(() => {}); throw e; }
      if (enter && pasteEnterDelay) await sleep(pasteEnterDelay);
    } else if (text) {
      // tmux's argv parser treats a trailing ";" as a command separator and "\;" as a literal ";":
      // "a;" -> "a\;" (arrives as "a;"), "a\;" -> "a\\;" (arrives as "a\;"). Nothing else in argv is interpreted.
      const arg = text.endsWith(';') ? `${text.slice(0, -1)}\\;` : text;
      await run(ctx, ['send-keys', '-t', pane(name), '-l', '--', arg]);
    }
    if (enter) await run(ctx, ['send-keys', '-t', pane(name), 'Enter']);
  }

  // --- http helpers ---
  function json(res, status, obj, headers) {
    const body = JSON.stringify(obj);
    res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(body), ...headers });
    res.end(body);
  }
  function readBody(req) {
    return new Promise((resolve, reject) => {
      const chunks = []; let size = 0; let over = false;
      req.on('data', (c) => {
        size += c.length;
        if (size > BODY_LIMIT) { over = true; chunks.length = 0; if (size > 16 * BODY_LIMIT) req.destroy(); return; }
        if (!over) chunks.push(c);
      });
      req.on('end', () => (over ? reject(new HttpErr(413, 'too_large')) : resolve(Buffer.concat(chunks))));
      req.on('error', () => reject(new HttpErr(400, 'invalid')));
      req.on('close', () => reject(new HttpErr(499, 'cancelled'))); // no-op once settled
    });
  }
  function parseJson(req, buf) {
    const ct = (req.headers['content-type'] || '').split(';')[0].trim().toLowerCase();
    if (ct !== 'application/json') throw new HttpErr(415, 'unsupported');
    let v;
    try { v = JSON.parse(buf.toString('utf8')); } catch { throw new HttpErr(400, 'invalid'); }
    if (!v || typeof v !== 'object' || Array.isArray(v)) throw new HttpErr(400, 'invalid');
    return v;
  }
  function requestSid(req) {
    const m = /^Bearer ([A-Za-z0-9_-]{1,128})$/.exec(req.headers.authorization || '');
    if (m) return m[1];
    for (const part of (req.headers.cookie || '').split(';')) {
      const i = part.indexOf('=');
      if (i > 0 && part.slice(0, i).trim() === COOKIE) return part.slice(i + 1).trim();
    }
    return null;
  }
  const setCookie = (sid, maxAge) => `${COOKIE}=${sid}; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=${maxAge}`;
  function csrfOk(req) {
    if (req.headers['x-pc'] !== '1') return false;
    const o = req.headers.origin;
    if (o === undefined) return true; // native client sends none
    const host = req.headers['x-forwarded-host'] || req.headers.host;
    return typeof host === 'string' && !!host && o.toLowerCase() === `https://${host.toLowerCase()}`;
  }
  const validName = (n) => typeof n === 'string' && NAME_RE.test(n);

  // --- SSE ---
  let streams = 0;
  async function stream(req, res, name, lines, ctx, ansi) {
    if (streams >= MAX_STREAMS) throw new HttpErr(503, 'busy');
    streams++; // reserved before any await
    let closed = false; let paused = false; let inflight = false;
    let timer = null; let pingTimer = null; let drainTimer = null; let last = null;
    const cleanup = () => { // exactly once on every path
      if (closed) return;
      closed = true; streams--;
      clearTimeout(timer); clearInterval(pingTimer); clearTimeout(drainTimer);
    };
    res.on('close', cleanup); // registered before the first await
    try {
      let snap = await getScreen(name, lines, ctx, ansi);
      if (closed || res.destroyed) return cleanup();
      res.writeHead(200, { 'Content-Type': 'text/event-stream; charset=utf-8', 'Cache-Control': 'no-store', 'X-Accel-Buffering': 'no' });
      res.socket?.setNoDelay(true);
      res.flushHeaders();
      // true = handed to write() (a false return of write still means accepted: pause until 'drain', or give up after 30 s)
      const send = (chunk) => {
        if (closed || paused) return false;
        if (!res.write(chunk)) {
          paused = true;
          drainTimer = setTimeout(() => res.destroy(), drainTimeout);
          res.once('drain', () => { paused = false; clearTimeout(drainTimer); schedule(); });
        }
        return true;
      };
      const end = (reason) => {
        if (closed) return;
        res.end(`event: gone\ndata: ${JSON.stringify({ reason })}\n\n`);
        cleanup();
      };
      const schedule = () => { if (!closed && !paused && !timer && !inflight) timer = setTimeout(tick, pollMs); };
      const tick = async () => {
        timer = null;
        if (closed || paused) return; // no polling while paused; 'drain' reschedules
        inflight = true;
        try {
          if (!valid(ctx)) return end('auth');
          if (!snap) snap = await getScreen(name, lines, ctx, ansi);
          if (closed) return;
          if (!valid(ctx)) return end('auth');
          if (snap.hash !== last && send(`event: screen\ndata: ${sseJson(snap)}\n\n`)) last = snap.hash;
        } catch (e) {
          if (e.status === 404) return end('session');
          if (e.status === 401) return end('auth');
          // 503 busy (no free read slot) or a tmux hiccup: try again on the next tick
        } finally { inflight = false; snap = null; }
        schedule();
      };
      pingTimer = setInterval(() => send(': ping\n\n'), pingMs);
      send('retry: 3000\n\n');
      tick();
    } catch (e) {
      cleanup();
      throw e;
    }
  }

  async function route(req, res, url, ctx) {
    const { pathname } = url;
    const method = req.method;
    if (pathname === '/' && (method === 'GET' || method === 'HEAD')) {
      res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8', 'Content-Length': 10 });
      return res.end(method === 'HEAD' ? undefined : 'fcoding ok');
    }

    if (pathname === '/pair' && (method === 'GET' || method === 'HEAD')) { // share link: never reads or consumes the pending code
      refreshConfig(); // a config edit (publicUrl) is picked up here too
      const code = url.searchParams.get('code');
      const o = cfg.publicUrl;
      const ok = typeof code === 'string' && /^\d{6}$/.test(code) && !!o;
      const status = !o ? 503 : ok ? 200 : 400;
      const body = pairPage(ok ? pairLinks(code).appLink : null, status);
      res.writeHead(status, { 'Content-Type': 'text/html; charset=utf-8', 'Content-Length': Buffer.byteLength(body), 'Cache-Control': 'no-store' });
      return res.end(method === 'HEAD' ? undefined : body);
    }

    const isApi = pathname.startsWith('/api/');
    if (method !== 'GET' && method !== 'HEAD' && !csrfOk(req)) throw new HttpErr(403, 'forbidden');

    const seg = pathname.split('/');
    const isPair = pathname === '/api/pair';
    if (!isPair) {
      refreshConfig(); // before deriving the key
      const tok = requestSid(req);
      ctx.device = tok && tok.length < 128 ? byKey.get(keyOf(tok)) ?? null : null;
      ctx.gen = gen;
      if (!valid(ctx)) throw new HttpErr(401, 'unauthorized');
    }
    if (!isApi) throw new HttpErr(404, 'not_found');
    if (isPair) { // counted before the body: oversized, slow and invalid bodies use up the quota too
      if (method !== 'POST') throw new HttpErr(405, 'method');
      const wait = pairLimited(now());
      if (wait) return json(res, 429, { error: 'rate_limited', retryAfter: wait }, { 'Retry-After': String(wait) });
    }

    const body = method === 'GET' ? null : await readBody(req);
    if (!isPair && !valid(ctx)) throw gateErr(ctx); // re-checked once the body is in
    const want = (m) => { if (method !== m) throw new HttpErr(405, 'method'); };

    if (isPair) {
      const { code, name } = parseJson(req, body);
      const token = pair(code, name);
      return json(res, 200, { ok: true, token }, { 'Set-Cookie': setCookie(token, COOKIE_MAX_AGE) });
    }
    if (pathname === '/api/logout') {
      want('POST');
      try { revoke(url.searchParams.get('all') === '1' ? [...devices.keys()] : [ctx.device]); } catch { throw new HttpErr(500, 'storage'); }
      return json(res, 200, { ok: true }, { 'Set-Cookie': setCookie('', 0) });
    }
    if (pathname === '/api/me') { want('GET'); return json(res, 200, { ok: true }); }
    if (pathname === '/api/pair-code') { // a paired device mints a code for its next device (same store, TTL, single use and limits as --pair)
      want('POST');
      const b = body.length ? parseJson(req, body) : {};
      if (b.name !== undefined && typeof b.name !== 'string') throw new HttpErr(400, 'invalid');
      if (!cfg.publicUrl) throw new HttpErr(409, 'no_public_url'); // no code is made when no link can be built
      const p = newPairing(b.name);
      return json(res, 200, { code: p.code, expiresAt: new Date(p.expiresAt).toISOString(), ...pairLinks(p.code, p.name) });
    }
    if (pathname === '/api/overview') { want('GET'); return json(res, 200, await overview(ctx)); }
    if (pathname === '/api/meta') {
      want('GET');
      return json(res, 200, { projects: cfg.projectNames, harnesses: Object.keys(HARNESSES), keys: KEYS });
    }
    if (pathname === '/api/sessions') {
      if (method === 'GET') return json(res, 200, { sessions: await listSessions(ctx) });
      want('POST');
      const { name, project, harness } = parseJson(req, body);
      if (!validName(name) || !validProject(project) || !validHarness(harness)) throw new HttpErr(400, 'invalid');
      await mutate(ctx, () => createSession(name, project, harness, ctx));
      return json(res, 201, { name });
    }
    if (pathname === '/api/open') {
      want('POST');
      const { project, harness, fresh } = parseJson(req, body);
      if (!validProject(project) || !validHarness(harness) || (fresh !== undefined && typeof fresh !== 'boolean')) throw new HttpErr(400, 'invalid');
      const name = `${project}-${harness}`.toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-+/, '').slice(0, 32);
      if (!NAME_RE.test(name)) throw new HttpErr(400, 'invalid');
      if (fresh) { // A5 update 4: always a new session; the name is picked and created in the same job
        const picked = await mutate(ctx, async () => {
          const taken = new Set((await listSessions(ctx)).map((x) => x.name));
          for (let n = 1; n <= 1000; n++) {
            const cand = freshName(name, n);
            if (taken.has(cand)) continue;
            try { await createSession(cand, project, harness, ctx); return cand; } catch (e) { if (e.code !== 'exists') throw e; } // created outside us meanwhile
          }
          throw new HttpErr(409, 'exists');
        });
        return json(res, 200, { name: picked, created: true });
      }
      const created = await mutate(ctx, async () => { // check-then-create in one job
        try { await createSession(name, project, harness, ctx); return true; } catch (e) {
          if (e.code !== 'exists') throw e;
          const same = (await listSessions(ctx)).some((x) => x.name === name && x.project === project && x.harness === harness);
          if (!same) throw e; // name taken by another project/harness (truncation collision)
          return false;
        }
      });
      return json(res, 200, { name, created });
    }

    // /api/<verb>/<name>
    if (seg.length === 4 && seg[1] === 'api' && seg[0] === '' && ['sessions', 'screen', 'stream', 'send', 'key', 'resize'].includes(seg[2])) {
      const verb = seg[2]; const name = seg[3];
      if (!validName(name)) throw new HttpErr(400, 'invalid');
      if (verb === 'sessions') {
        want('DELETE');
        await mutate(ctx, () => run(ctx, ['kill-session', '-t', sess(name)]));
        return json(res, 200, { ok: true });
      }
      if (verb === 'screen' || verb === 'stream') {
        want('GET');
        const q = url.searchParams.get('lines');
        let lines = 300;
        if (q !== null) {
          lines = Number(q);
          if (!/^\d+$/.test(q) || lines < 50 || lines > 2000) throw new HttpErr(400, 'invalid');
        }
        const ansi = url.searchParams.get('ansi') === '1'; // anything else = plain text, as before
        if (verb === 'screen') return json(res, 200, await getScreen(name, lines, ctx, ansi));
        return stream(req, res, name, lines, ctx, ansi);
      }
      want('POST');
      const b = parseJson(req, body);
      if (verb === 'send') {
        const { text, enter } = b;
        if (typeof text !== 'string' || (enter !== undefined && typeof enter !== 'boolean')) throw new HttpErr(400, 'invalid');
        if (Buffer.byteLength(text) > TEXT_LIMIT) throw new HttpErr(413, 'too_large');
        if (text.includes('\0') || (!text && !enter)) throw new HttpErr(400, 'invalid');
        await mutate(ctx, () => sendText(name, text, enter === true, ctx));
        return json(res, 200, { ok: true });
      }
      if (verb === 'key') {
        const { key: k, repeat = 1 } = b;
        if (typeof k !== 'string' || !KEYS.includes(k)) throw new HttpErr(400, 'bad_key');
        if (!Number.isInteger(repeat) || repeat < 1 || repeat > 20) throw new HttpErr(400, 'invalid');
        await mutate(ctx, () => run(ctx, ['send-keys', '-t', pane(name), ...Array(repeat).fill(k)]));
        return json(res, 200, { ok: true });
      }
      const { cols, rows } = b; // resize
      if (!Number.isInteger(cols) || !Number.isInteger(rows) || cols < 20 || cols > 300 || rows < 10 || rows > 200) throw new HttpErr(400, 'invalid');
      await mutate(ctx, () => run(ctx, ['resize-window', '-t', pane(name), '-x', String(cols), '-y', String(rows)]));
      return json(res, 200, { ok: true });
    }
    throw new HttpErr(404, 'not_found');
  }

  // The handler never rejects: every failure path ends in a response (or a closed socket).
  const server = http.createServer(async (req, res) => {
    const t0 = Date.now();
    const ctx = { cancelled: false, device: null, gen: -1 };
    res.on('close', () => { if (!res.writableFinished) { ctx.cancelled = true; ctx.onCancel?.(); } });
    let target = '(bad-target)';
    try {
      for (const [k, v] of Object.entries(SEC_HEADERS)) res.setHeader(k, v);
      res.on('finish', () => log(`${req.method} ${target} ${res.statusCode} ${Date.now() - t0}ms`));
      let url;
      try { url = new URL(req.url, 'http://x'); } catch { throw new HttpErr(400, 'invalid'); }
      target = url.pathname;
      if (target.startsWith('/api/')) res.setHeader('Cache-Control', 'no-store');
      await route(req, res, url, ctx);
    } catch (e) {
      try {
        if (res.headersSent || res.destroyed) return res.end();
        const err = e instanceof HttpErr ? e : new HttpErr(500, 'internal');
        json(res, err.status, { error: err.code });
      } catch {}
    }
  });
  server.on('clientError', (err, socket) => {
    log('clientError');
    if (socket.writable && !socket.destroyed) socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
    else socket.destroy();
  });
  server.requestTimeout = 15000;
  server.headersTimeout = 10000;
  const listen = async (port = Number(process.env.PC_PORT) || cfg.port || 7681, host = '0.0.0.0') => {
    await listenAdmin();
    try {
      return await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, host, () => resolve(server.address().port)); });
    } catch (e) { adminServer.close(); throw e; }
  };
  const close = () => Promise.all([
    new Promise((resolve) => { server.close(() => resolve()); server.closeAllConnections(); }),
    new Promise((resolve) => (adminServer.listening ? adminServer.close(() => resolve()) : resolve())),
  ]);
  return { server, listen, close, devices, stats: () => ({ streams, running, reads, waiting: queue.length, active: !!active }) };
}

// ---------- CLI ----------
// fcode-pair --qr: the QR of the app link (qrencode, when installed) and the links; the code line is printed before this
function printQr(links, expiresIn) {
  if (!links) return console.log('Chưa đặt "publicUrl" trong config.json nên chưa tạo được link/mã QR. Ví dụ: "publicUrl": "https://<địa-chỉ-công-khai>"');
  let shown = false;
  try { process.stdout.write(execFileSync('qrencode', ['-t', 'ANSIUTF8', links.appLink], { encoding: 'utf8', timeout: 5000, windowsHide: true })); shown = true; } catch {}
  console.log(`Link chia sẻ: ${links.shareLink}\nMã hết hạn sau ${Math.round(expiresIn / 60)} phút.`);
  if (!shown) console.log(`Link mở app: ${links.appLink}\ncài qrencode để hiện mã QR`);
}
async function main() {
  const dir = defaultConfigDir();
  const arg = (f) => { const i = process.argv.indexOf(f); return i < 0 ? undefined : process.argv[i + 1] ?? ''; };
  const qr = process.argv.includes('--qr');
  const req = process.argv.includes('--pair') ? { cmd: 'pair', name: arg('--pair'), ...(qr && { links: true }) }
    : process.argv.includes('--devices') ? { cmd: 'devices' }
      : process.argv.includes('--revoke') ? { cmd: 'revoke', id: arg('--revoke') } : null;
  if (req) { // admin CLI: talks to the RUNNING server over admin.sock
    let r;
    try { r = await adminRequest(dir, req); } catch (e) { console.error(e.code === 'ENOSERVER' ? `${e.message} (no ${adminPath(dir)})` : `admin socket: ${e.message}`); process.exit(1); }
    if (!r.ok) { console.error(`error: ${r.error}`); process.exit(1); }
    if (req.cmd === 'pair') {
      console.log(`Mã ghép: ${r.code} (hết hạn sau ${r.expiresIn} giây)\nNhập mã này vào app. Có thể có tối đa 3 mã cùng lúc; mã thứ 4 thay mã cũ nhất.`);
      if (qr) printQr(r.links, r.expiresIn);
    }
    else if (req.cmd === 'devices') {
      if (!r.devices.length) console.log('(no paired devices)');
      for (const d of r.devices) console.log(`${d.id}  ${new Date(d.createdAt).toISOString()}  ${d.name}`);
    } else console.log(`revoked: ${r.revoked}`);
    return;
  }
  // a bug must not leave the process half-alive: log the type only (never data) and let systemd restart us
  const fatal = (kind) => (e) => {
    const frame = String(e?.stack || '').split('\n').find((l) => l.trim().startsWith('at '))?.trim() || '';
    console.error(`${kind}: ${e?.name || typeof e} ${e?.code || ''} ${frame}`);
    process.exit(1);
  };
  process.on('unhandledRejection', fatal('unhandledRejection'));
  process.on('uncaughtException', fatal('uncaughtException'));
  const lock = await acquireInstanceLock(dir); // before config, devices or admin.sock are touched
  const app = createApp({ configDir: dir });
  const port = await app.listen();
  void lock; // held until the process exits
  console.log(`fcoding listening on 0.0.0.0:${port}`);
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((e) => { console.error(e.message); process.exit(1); });
}
