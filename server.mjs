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
const LONE_SURROGATE = /[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/g;
function cleanName(n) {
  if (typeof n !== 'string') return '';
  let out = '', len = 0;
  for (const ch of n.replace(LONE_SURROGATE, '').replace(NAME_CTRL, '').trim()) { // never half of a surrogate pair
    if (len + ch.length > 64) break;
    out += ch; len += ch.length;
  }
  return out.trim();
}

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

// GET /pair: a tiny page with one button that opens the app link. Nothing from the request reaches it (no code, no query).
const escHtml = (t) => t.replace(/[&<>"']/g, (ch) => `&#${ch.charCodeAt(0)};`);
export function pairPage(appLink) {
  const body = !appLink ? '<p>Máy chủ chưa đặt địa chỉ công khai, nên chưa mở được app từ link này.</p>'
    : `<a class="btn" href="${escHtml(appLink)}">Mở FCode</a><p>Sau khi app mở, gõ mã 6 số đang hiện trên iPhone cũ hoặc trên máy tính.</p><p class="s">Chưa cài FCode? Cài file fcode.ipa trước.</p>`;
  return `<!doctype html><html lang="vi"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>Ghép FCode</title><style>body{margin:0;font:17px/1.5 -apple-system,system-ui,sans-serif;background:#111;color:#eee;text-align:center}main{padding:48px 24px}.btn{display:block;max-width:320px;margin:24px auto;padding:16px;border-radius:14px;background:#0a84ff;color:#fff;font-size:20px;font-weight:600;text-decoration:none}.s{color:#999;font-size:15px}</style></head><body><main><h1>Ghép iPhone với FCode</h1>${body}</main></body></html>`;
}

// ---------- home screen v2 (CONTRACT.md A8): quota, spend, box timer, projects, updates, Codex reset ----------
const QUOTA_TTL = 60e3, SPEND_TTL = 300e3, PROJECTS_TTL = 120e3;
const QUOTA_STALE_MS = 10 * 60e3; // a report omp fetched longer ago than this is stale
export const BOX = { maxRunMinutes: 480, idlePauseMinutes: 30, cooldownMinutes: 10 };
const BOX_TICK_MS = 30e3, BOX_GAP_MS = 90e3; // a tick that comes more than 90 s late = the box was asleep and resumed
const SPEND_DAYS = 30, SCAN_DAYS = 31, SCAN_CHUNK = 8 << 20, MAX_LINE = 4 << 20;
const RESET_TIMEOUT = 45e3, RESET_KEEP_MS = 15 * 60e3;
const HARNESS_OF = { anthropic: 'claude', 'openai-codex': 'codex' };
const OMP_HARNESS = { anthropic: 'claude', 'claude-agent-sdk': 'claude', 'openai-codex': 'codex' };
const PLAN_LABELS = { free: 'Free', plus: 'Plus', pro: 'Pro', max: 'Max', team: 'Team', business: 'Business', enterprise: 'Enterprise', edu: 'Edu' };
// USD per million tokens: [input, output, cache read, cache write 5 min, cache write 1 h] (absent = input rate; 1 h absent = 2 x input).
// Source: LiteLLM model_prices_and_context_window.json (github.com/BerriAI/litellm, main), read 2026-10-26. Used only for logs
// that carry no cost of their own (Claude Code, Codex); omp logs carry their own cost. An unknown model counts tokens, never dollars.
export const PRICES = {
  'claude-opus-5-5': [4, 20, 0.2, 5, 8], 'claude-opus-5': [5, 25, 0.5, 6.25, 10], 'claude-opus-4-8': [5, 25, 0.5, 6.25, 10],
  'claude-opus-4-7': [5, 25, 0.5, 6.25, 10], 'claude-opus-4-6': [5, 25, 0.5, 6.25, 10], 'claude-opus-4-5': [5, 25, 0.5, 6.25, 10],
  'claude-sonnet-5-5': [2, 10, 0.1, 2.5, 4], 'claude-sonnet-5': [2, 10, 0.2, 2.5, 4], 'claude-sonnet-4-6': [3, 15, 0.3, 3.75, 6],
  'claude-sonnet-4-5': [3, 15, 0.3, 3.75, 6], 'claude-haiku-5-5': [0.1, 0.5, 0.01, 0.125, 0.2], 'claude-haiku-4-5': [1, 5, 0.1, 1.25, 2],
  'gpt-5.6': [4, 20, 0.4, 5], 'gpt-5.6-sol': [4, 20, 0.4, 5], 'gpt-5.6-terra': [2, 12, 0.2, 2.5], 'gpt-5.6-luna': [0.2, 1.2, 0.02, 0.25],
  'gpt-5.5': [5, 30, 0.5], 'gpt-5.4': [2.5, 15, 0.25], 'gpt-5.4-mini': [0.75, 4.5, 0.075], 'gpt-5.3-codex': [1.75, 14, 0.175],
  'gpt-5.2': [1.75, 14, 0.175], 'gpt-5.1': [1.25, 10, 0.125], 'gpt-5.1-codex-mini': [0.25, 2, 0.025], 'gpt-5': [1.25, 10, 0.125],
  'gpt-5-codex': [1.25, 10, 0.125], 'gpt-5-mini': [0.25, 2, 0.025], 'gpt-5-nano': [0.05, 0.4, 0.005],
};
// exact name, then without a date suffix, then the longest known "<name>-" prefix ("gpt-5.1-codex-max" -> gpt-5.1)
export function priceOf(model) {
  if (typeof model !== 'string') return null;
  const m = model.toLowerCase().replace(/^.*\//, '').replace(/-\d{8}$|-\d{4}-\d{2}-\d{2}$/, '');
  if (Object.hasOwn(PRICES, m)) return PRICES[m];
  const k = Object.keys(PRICES).filter((x) => m.startsWith(`${x}-`)).sort((a, b) => b.length - a.length)[0];
  return k ? PRICES[k] : null;
}
const costOf = (p, { input = 0, output = 0, cacheRead = 0, w5m = 0, w1h = 0 }) =>
  (input * p[0] + output * p[1] + cacheRead * (p[2] ?? p[0]) + w5m * (p[3] ?? p[0]) + w1h * (p[4] ?? p[0] * 2)) / 1e6;
const num = (x) => (Number.isFinite(x) && x > 0 ? x : 0);
const str = (v) => (typeof v === 'string' && v.trim() ? v.trim() : null);
const iso = (ms) => (Number.isFinite(ms) ? new Date(ms).toISOString() : null);
const planLabel = (raw) => { const r = str(raw); return r ? PLAN_LABELS[r.toLowerCase()] ?? r[0].toUpperCase() + r.slice(1) : null; };

// --- quota: `omp usage --json` reports + the `omp usage reset --json` listing (credential ids) -> accounts ---
const windowLabel = (id, tier) => {
  const m = /^(\d+)([hd])$/.exec(id);
  const base = m ? `${m[1]} ${m[2] === 'h' ? 'giờ' : 'ngày'}` : id;
  return tier ? `${base} ${tier[0].toUpperCase()}${tier.slice(1)}` : base;
};
function usedPercentOf(a) {
  if (!a || typeof a !== 'object') return null;
  let v = null;
  if (Number.isFinite(a.usedFraction)) v = a.usedFraction * 100;
  else if (Number.isFinite(a.used) && a.unit === 'percent') v = a.used;
  else if (Number.isFinite(a.used) && Number.isFinite(a.limit) && a.limit > 0) v = (a.used / a.limit) * 100;
  return v === null ? null : Math.round(v * 10) / 10;
}
// a window omp does not report (no limit entry, or no number) is not shown
export function windowsOf(limits) {
  const out = [];
  for (const l of Array.isArray(limits) ? limits : []) {
    const usedPercent = usedPercentOf(l?.amount);
    const id = str(l?.scope?.windowId) ?? str(l?.window?.id);
    if (usedPercent === null || !id) continue;
    const tier = str(l.scope?.tier)?.toLowerCase() ?? null;
    const dur = l.window?.durationMs;
    out.push({ key: tier ? `${id}_${tier}` : id, label: windowLabel(id, tier), usedPercent, resetsAt: iso(l.window?.resetsAt),
      periodSeconds: Number.isFinite(dur) ? Math.round(dur / 1000) : null });
  }
  return out;
}
// -> {accounts, byAccountId: Map("<harness>:<vendor account id>" -> account id)}. The account id is the omp reset target
// "<provider>/<credential id>" (also the key of omp's per-message credentialId); unmatched accounts get a hash id and no target.
export function parseQuota(usage, resetList, nowMs) {
  const listed = (Array.isArray(resetList?.accounts) ? resetList.accounts : []).filter((r) => r && Number.isInteger(r.credentialId));
  const taken = new Set();
  const accounts = [], byAccountId = new Map();
  const add = (provider, m, report) => {
    const harness = HARNESS_OF[provider];
    if (!harness || !m || typeof m !== 'object') return;
    const same = (r) => r.provider === provider && (r.accountId ?? null) === (m.accountId ?? null) && (r.orgId ?? null) === (m.orgId ?? null)
      && (!r.email || !m.email || r.email === m.email);
    const r = listed.find((x) => !taken.has(x) && same(x));
    if (r) taken.add(r);
    const target = r ? `${provider}/${r.credentialId}` : null;
    const id = target ?? `${provider}/~${crypto.createHash('sha256').update(`${m.accountId}|${m.orgId}|${m.email}`).digest('hex').slice(0, 8)}`;
    const fetched = Number.isFinite(report?.fetchedAt) ? report.fetchedAt : null;
    const credits = r ?? report?.resetCredits ?? {};
    const err = [report?.error, m.error, m.reason, m.status].filter((x) => typeof x === 'string' || typeof x === 'number').join(' ');
    accounts.push({
      id, harness, email: str(m.email), org: str(m.orgName), plan: planLabel(m.planType ?? m.subscriptionType ?? m.plan),
      fetchedAt: iso(fetched), stale: fetched === null || nowMs - fetched > QUOTA_STALE_MS, rateLimited: /rate.?limit|\b429\b/i.test(err),
      windows: windowsOf(report?.limits),
      resets: { available: Math.max(0, Math.trunc(num(credits.redeemableCount ?? credits.availableCount))), target },
    });
    if (str(m.accountId)) byAccountId.set(`${harness}:${m.accountId}`, id);
  };
  for (const rep of Array.isArray(usage?.reports) ? usage.reports : []) add(rep?.provider, rep?.metadata, rep);
  for (const a of Array.isArray(usage?.accountsWithoutUsage) ? usage.accountsWithoutUsage : []) add(a?.provider, a, null);
  return { accounts, byAccountId };
}

// --- spend: local logs. One event per billed request: {ts, harness, who, usd|null, tokens, key}; key dedupes across files ---
// omp / pi session files (~/.omp/agent/sessions): assistant messages carry provider, credentialId, usage and usage.cost.total
export function ompLine(v, fileKey) {
  let m, who = null, key;
  if (v?.type === 'message' && v.message?.role === 'assistant') {
    m = v.message;
    key = str(m.responseId) ? `o:${m.responseId}` : `o:${fileKey}:${v.id}`;
    if (Number.isInteger(m.credentialId) && str(m.provider)) who = `${m.provider}/${m.credentialId}`;
  } else if (v?.type === 'model_usage') { m = v; key = `o:${fileKey}:${v.id}`; } // titles, compaction: no credential id
  else return null;
  const harness = OMP_HARNESS[m.provider], u = m.usage;
  const ts = Number.isFinite(m.timestamp) ? m.timestamp : Date.parse(v.timestamp);
  if (!harness || !u || typeof u !== 'object' || !Number.isFinite(ts)) return null;
  const w1h = num(u.cttl?.ephemeral1h), parts = { input: num(u.input), output: num(u.output), cacheRead: num(u.cacheRead), w5m: Math.max(0, num(u.cacheWrite) - w1h), w1h };
  const p = priceOf(m.model);
  const usd = Number.isFinite(u.cost?.total) ? u.cost.total : p ? costOf(p, parts) : null;
  return { ts, harness, who, usd, tokens: num(u.totalTokens) || parts.input + parts.output + parts.cacheRead + num(u.cacheWrite), key };
}
// Claude Code (~/.claude/projects): one message can span several lines (and sidechains replay it) with the same message.id: count it once
export function claudeLine(v) {
  const m = v?.type === 'assistant' ? v.message : null, u = m?.usage;
  const ts = Date.parse(v?.timestamp);
  if (!u || typeof u !== 'object' || m.model === '<synthetic>' || !Number.isFinite(ts)) return null;
  const w = num(u.cache_creation_input_tokens), w1h = Math.min(w, num(u.cache_creation?.ephemeral_1h_input_tokens));
  const parts = { input: num(u.input_tokens), output: num(u.output_tokens), cacheRead: num(u.cache_read_input_tokens), w5m: w - w1h, w1h };
  const p = priceOf(m.model);
  const usd = Number.isFinite(v.costUSD) ? v.costUSD : p ? costOf(p, parts) : null;
  return { ts, harness: 'claude', who: null, usd, tokens: parts.input + parts.output + parts.cacheRead + w, key: str(m.id) ? `c:${m.id}` : null };
}
// Codex (~/.codex/sessions, archived_sessions): token_count events; st carries the session, account and model of the file
export function codexLine(v, st) {
  const p = v?.payload;
  if (!p || typeof p !== 'object') return null;
  if (v.type === 'session_meta') {
    st.session = str(p.id) ?? st.session;
    st.account = str(p.creator_account_id) ?? str(p.account_id) ?? st.account;
    st.model = str(p.model) ?? st.model;
    return null;
  }
  if (v.type === 'turn_context') { st.model = str(p.model) ?? st.model; return null; }
  if (p.type !== 'token_count' || !p.info || typeof p.info !== 'object') return null;
  const tot = p.info.total_token_usage, last = p.info.last_token_usage;
  const totKey = tot ? JSON.stringify(tot) : null;
  if (totKey && totKey === st.prev) return null; // the same cumulative totals again: a re-emitted snapshot, not new usage
  const prevTot = st.prevTot;
  st.prev = totKey; st.prevTot = tot;
  const u = last ?? (tot && Object.fromEntries(Object.keys(tot).map((k) => [k, Math.max(0, num(tot[k]) - num(prevTot?.[k]))])));
  const ts = Date.parse(v.timestamp);
  if (!u || !Number.isFinite(ts)) return null;
  const input = num(u.input_tokens), cached = Math.min(input, num(u.cached_input_tokens)), output = num(u.output_tokens);
  const pr = priceOf(str(p.info.model) ?? st.model);
  return { ts, harness: 'codex', who: st.account ? `codex:${st.account}` : null, usd: pr ? costOf(pr, { input: input - cached, output, cacheRead: cached }) : null,
    tokens: num(u.total_tokens) || input + output, key: `x:${st.session ?? st.file}:${totKey ?? ts}` };
}
const PREFILTER = { omp: (l) => l.includes('"usage"'), claude: (l) => l.includes('"assistant"'), codex: (l) => /token_count|turn_context|session_meta/.test(l) };
// Incremental: each file is read from where the last scan stopped (whole lines only); a file that shrank or was replaced is re-read.
// Files not modified in the last 31 days are skipped; a file that disappears is dropped. Events stay per file, deduped when summed.
export function spendScanner(roots, nowFn = Date.now) {
  const files = new Map(); // path -> {ino, offset, events, st, skip}
  async function listFiles(dir, out, depth = 0) {
    if (depth > 16) return;
    let ents;
    try { ents = await fs.promises.readdir(dir, { withFileTypes: true }); } catch { return; }
    for (const e of ents) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) await listFiles(p, out, depth + 1);
      else if (e.isFile() && e.name.endsWith('.jsonl')) out.push(p);
    }
  }
  function parse(kind, f, line) {
    if (!line || line.length > MAX_LINE || !PREFILTER[kind](line)) return;
    let v;
    try { v = JSON.parse(line); } catch { return; }
    const e = kind === 'omp' ? ompLine(v, f.st.file) : kind === 'claude' ? claudeLine(v) : codexLine(v, f.st);
    if (e) f.events.push(e);
  }
  async function readNew(file, kind, f, size) {
    const fh = await fs.promises.open(file, 'r');
    try {
      while (f.offset < size) {
        const buf = Buffer.alloc(Math.min(size - f.offset, SCAN_CHUNK));
        const { bytesRead } = await fh.read(buf, 0, buf.length, f.offset);
        if (!bytesRead) break;
        const nl = buf.lastIndexOf(10, bytesRead - 1);
        if (nl < 0) { // no line end in a full chunk: an over-long line, skipped up to its end; else an unfinished last line waits
          if (bytesRead < SCAN_CHUNK) break;
          f.offset += bytesRead; f.skip = true; continue;
        }
        const lines = buf.toString('utf8', 0, nl).split('\n');
        if (f.skip) { lines.shift(); f.skip = false; }
        for (const line of lines) parse(kind, f, line);
        f.offset += nl + 1;
      }
    } finally { await fh.close(); }
  }
  return async function scan() {
    const cutoff = nowFn() - SCAN_DAYS * 86400e3;
    const seen = new Set();
    for (const kind of ['omp', 'claude', 'codex']) {
      for (const dir of roots[kind] ?? []) {
        const list = [];
        await listFiles(dir, list);
        for (const file of list) {
          let s;
          try { s = await fs.promises.stat(file); } catch { continue; }
          if (s.mtimeMs < cutoff || seen.has(file)) continue;
          seen.add(file);
          let f = files.get(file);
          if (!f || f.ino !== s.ino || s.size < f.offset) files.set(file, f = { ino: s.ino, offset: 0, events: [], st: { file: path.basename(file) }, skip: false });
          if (s.size > f.offset) { try { await readNew(file, kind, f, s.size); } catch {} } // unreadable now: what was read stays
        }
      }
    }
    for (const k of files.keys()) if (!seen.has(k)) files.delete(k);
    return [...files.values()].flatMap((f) => f.events);
  };
}
const dayKey = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const r4 = (x) => Math.round(x * 1e4) / 1e4;
const money = ({ usd, tokens }) => ({ usd: r4(usd), tokens: Math.round(tokens) });
// {today, yesterday, last30, weeklyEstimate, daily30}: local calendar days (the server's TZ), the last 30 ending today, oldest first.
// weeklyEstimate (Pane): spend inside the account's "7d" window / (usedPercent / 100), from 5 % used; at >= 100 % the spend itself.
export function spendOf(events, nowMs, weekly = null) {
  const days = [];
  const base = new Date(nowMs);
  for (let i = SPEND_DAYS - 1; i >= 0; i--) days.push(dayKey(new Date(base.getFullYear(), base.getMonth(), base.getDate() - i, 12)));
  const idx = new Map(days.map((k, i) => [k, i]));
  const daily = days.map((date) => ({ date, usd: 0, tokens: 0 }));
  for (const e of events) {
    const i = idx.get(dayKey(new Date(e.ts)));
    if (i !== undefined && e.ts <= nowMs) { daily[i].usd += e.usd ?? 0; daily[i].tokens += e.tokens; }
  }
  const sum = daily.reduce((a, d) => ({ usd: a.usd + d.usd, tokens: a.tokens + d.tokens }), { usd: 0, tokens: 0 });
  let weeklyEstimate = null;
  const end = Date.parse(weekly?.resetsAt);
  if (weekly && Number.isFinite(end) && weekly.periodSeconds > 0 && weekly.usedPercent >= 5) {
    const start = end - weekly.periodSeconds * 1000, w = { usd: 0, tokens: 0 };
    for (const e of events) if (e.ts >= start && e.ts <= nowMs) { w.usd += e.usd ?? 0; w.tokens += e.tokens; }
    const frac = Math.min(1, weekly.usedPercent / 100);
    if (w.tokens > 0) weeklyEstimate = money({ usd: w.usd / frac, tokens: w.tokens / frac }); // nothing logged in the window: no estimate
  }
  return { today: money(daily[SPEND_DAYS - 1]), yesterday: money(daily[SPEND_DAYS - 2]), last30: money(sum), weeklyEstimate, daily30: daily.map((d) => ({ date: d.date, ...money(d) })) };
}
// events -> per-account spend (Map id -> spend) and totals. An event whose account is not known counts in its harness total only.
export function spendView(events, accounts, byAccountId, nowMs) {
  const keys = new Set(), uniq = [];
  for (const e of events) {
    if (e.key) { if (keys.has(e.key)) continue; keys.add(e.key); }
    uniq.push(e);
  }
  const byId = new Map(accounts.map((a) => [a.id, []]));
  for (const e of uniq) {
    const id = e.who && (byId.has(e.who) ? e.who : byAccountId.get(e.who));
    if (id) byId.get(id).push(e);
  }
  const perAccount = new Map(accounts.map((a) => [a.id, spendOf(byId.get(a.id), nowMs, a.windows.find((w) => w.key === '7d'))]));
  const harnesses = [...new Set(uniq.map((e) => e.harness))];
  const byHarness = harnesses.map((h) => ({ harness: h, usd: spendOf(uniq.filter((e) => e.harness === h), nowMs).last30.usd })).sort((a, b) => b.usd - a.usd);
  return { perAccount, totals: { spend: spendOf(uniq, nowMs), byHarness } };
}

// --- projects (gh), updates (status.json), Codex reset (omp) ---
// owner/repo of a GitHub remote: https, ssh:// or scp-like, also through an ssh host alias (git@github-work:owner/repo.git)
export function repoOf(url) {
  const m = /^(?:[a-z+]+:\/\/)?(?:[^@/\s]+@)?([^:/\s]+)[:/]+(?:\d+\/)?([\w.-]+)\/([\w.-]+?)(?:\.git)?\/?$/i.exec(String(url ?? '').trim());
  return m && /github/i.test(m[1]) ? `${m[2]}/${m[3]}` : null;
}
const CHECK_FAIL = ['FAILURE', 'ERROR', 'TIMED_OUT', 'CANCELLED', 'ACTION_REQUIRED', 'STARTUP_FAILURE'];
// gh statusCheckRollup: CheckRun {status, conclusion} or StatusContext {state}; null when gh could not read checks
export function checksOf(rollup) {
  if (!Array.isArray(rollup)) return null;
  if (!rollup.length) return 'none';
  let pending = false;
  for (const c of rollup) {
    const res = String(c?.conclusion || c?.state || '').toUpperCase();
    if (CHECK_FAIL.includes(res)) return 'failure';
    if (c?.status !== undefined ? String(c.status).toUpperCase() !== 'COMPLETED' : ['PENDING', 'EXPECTED', ''].includes(res)) pending = true;
  }
  return pending ? 'pending' : 'success';
}
export const prsOf = (list) => list.map((p) => ({ number: p.number, title: clip(cleanLine(String(p.title ?? ''))), checks: checksOf(p.statusCheckRollup),
  mergeable: p.mergeable === 'MERGEABLE' ? true : p.mergeable === 'CONFLICTING' ? false : null }));
export function runOf(list) {
  const r = Array.isArray(list) ? list[0] : null;
  if (!r || typeof r !== 'object') return null;
  const status = r.status !== 'completed' ? 'in_progress' : ['success', 'neutral', 'skipped'].includes(r.conclusion) ? 'success' : 'failure';
  return { workflow: str(r.workflowName) ?? str(r.name), status, at: str(r.createdAt), url: str(r.url) };
}
// status.json of the box updater: the harness tools only (omp, claude, codex); a result outside updated|current|failed is null
const UPDATE_RESULTS = ['updated', 'current', 'failed'];
export function parseUpdates(text) {
  let j;
  try { j = JSON.parse(text); } catch { return {}; }
  const out = {};
  if (!j || typeof j !== 'object' || Array.isArray(j)) return out;
  for (const tool of ['omp', 'claude', 'codex']) {
    const v = j[tool];
    if (v && typeof v === 'object') out[tool] = { from: str(v.from) ?? '', to: str(v.to) ?? '', at: str(v.at), result: UPDATE_RESULTS.includes(v.result) ? v.result : null };
  }
  return out;
}
// `omp usage reset <target>` prints one line (stdout on success, stderr otherwise); first matching rule wins
export const RESET_MSG = {
  reset: 'Đã reset hạn mức Codex.',
  already: 'Lượt reset này đã được dùng rồi, không trừ thêm lượt nào.',
  nothing_to_reset: 'Chưa cần reset: hạn mức chưa bị chặn nên không mất lượt nào.',
  no_credit: 'Không còn lượt reset nào cho tài khoản này.',
  login: 'Đăng nhập tài khoản này đã hết hạn. Mở omp trên box và /login lại.',
  busy: 'Đang có một lần reset khác cho tài khoản này. Đợi một chút rồi xem lại Hạn mức.',
  list: 'Không tải được lượt reset (mạng hoặc đăng nhập). Chưa mất lượt nào, thử lại sau.',
  changed: 'Lượt reset vừa thay đổi, chưa mất lượt nào. Mở lại Hạn mức rồi thử lại.',
  tool: 'Không chạy được omp trên box. Thử lại sau.',
  error: 'Không xác nhận được reset. Xem lại Hạn mức trước khi thử lại.',
};
const RESET_RULES = [
  [/reset applied for/i, 'reset', 'reset'],
  [/already redeemed|another omp process spent a saved reset/i, 'already', 'already'],
  [/nothing to reset right now/i, 'nothing_to_reset', 'nothing_to_reset'],
  [/no saved resets available/i, 'no_credit', 'no_credit'],
  [/could not authenticate|try \/login|sign in to it again/i, 'error', 'login'],
  [/already in progress|started spending/i, 'error', 'busy'],
  [/couldn.t load this account.s saved resets/i, 'error', 'list'],
  [/reset offer changed/i, 'error', 'changed'],
];
export function resetReply(text) {
  const t = String(text ?? '').replace(ANSI_RE, '');
  const [, result, msg] = RESET_RULES.find(([re]) => re.test(t)) ?? [null, 'error', 'error'];
  return { result, message: RESET_MSG[msg] };
}
// a child with a timeout, never a shell; rejects with stdout/stderr attached
function execTool(spec, args, timeout) {
  return new Promise((resolve, reject) => {
    const [cmd, ...pre] = spec;
    execFile(cmd, [...pre, ...args], {
      encoding: 'utf8', timeout, maxBuffer: 32 << 20, windowsHide: true,
      env: { ...process.env, LANG: 'C.UTF-8', LC_ALL: 'C.UTF-8', NO_COLOR: '1', GH_PROMPT_DISABLED: '1', GIT_OPTIONAL_LOCKS: '0',
        PATH: `${home}/.local/bin:${home}/.bun/bin:${process.env.PATH ?? '/usr/local/bin:/usr/bin:/bin'}` },
    }, (err, stdout, stderr) => (err ? reject(Object.assign(err, { stdout, stderr })) : resolve(stdout)));
  });
}
// one refresh at a time; within ttl the cached value; a failed refresh hands back the previous value with fresh: false
function memo(ttl, fn, now) {
  let value, at = -Infinity, pending = null;
  return {
    async get() {
      if (value !== undefined && now() - at < ttl) return { value, fresh: true };
      pending ??= Promise.resolve().then(fn).then((v) => { value = v; at = now(); return v; }).finally(() => { pending = null; });
      try { return { value: await pending, fresh: true }; } catch (e) { if (value === undefined) throw e; return { value, fresh: false }; }
    },
    clear() { at = -Infinity; },
  };
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
  const specOf = (v) => (typeof v === 'string' ? (v.startsWith('[') ? JSON.parse(v) : [v]) : v);
  const ompSpec = specOf(opts.omp ?? process.env.PC_OMP ?? 'omp');
  const ghSpec = specOf(opts.gh ?? process.env.PC_GH ?? 'gh');
  const spendRoots = opts.spendRoots ?? {
    omp: [path.join(home, '.omp', 'agent', 'sessions')],
    claude: [path.join(process.env.CLAUDE_CONFIG_DIR || path.join(home, '.claude'), 'projects')],
    codex: ['sessions', 'archived_sessions'].map((d) => path.join(process.env.CODEX_HOME || path.join(home, '.codex'), d)),
  };
  const updatesFile = opts.updatesFile ?? path.join(home, '.local', 'state', 'fcode-update', 'status.json');

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
        if (rotated) { gen++; pendings = []; load([]); purge(); return; } // no old keyHash may match any more
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
  let pendings = []; // oldest first: {code, name, expiresAt, attempts, issuer}; issuer = a device id or 'shell'
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
    refreshConfig(); // a config edit is seen BEFORE any code is looked up or consumed: a rotation has then already cleared every pending code
    if (purgePending) throw new HttpErr(500, 'storage');
    const t = now();
    pendings = pendings.filter((p) => t < p.expiresAt && (p.issuer === 'shell' || devices.has(p.issuer))); // a revoked issuer's codes are dead
    const hits = pendings.map((p) => codeMatches(code, p)); // every live code is compared, none is skipped
    const i = hits.indexOf(true);
    if (i < 0) { // a wrong guess is one attempt against every live code; a code with 5 is gone
      pendings = pendings.filter((p) => ++p.attempts < PAIR_ATTEMPTS);
      throw new HttpErr(401, 'bad_code');
    }
    const [used] = pendings.splice(i, 1); // single use, even if the write below fails
    const devName = used.name || cleanName(name) || 'device';
    const token = crypto.randomBytes(32).toString('base64url');
    const dev = { id: crypto.randomBytes(8).toString('hex'), name: devName, keyHash: keyOf(token), createdAt: t };
    try { commitDevices([...devices.values(), dev]); } catch { throw new HttpErr(500, 'storage'); }
    return token;
  }
  // throws on a failed write; nothing changes then. Pending codes made by a removed device go with it; all: every pending code goes.
  function revoke(ids, all = false) {
    commitDevices([...devices.values()].filter((d) => !ids.includes(d.id)));
    pendings = all ? [] : pendings.filter((p) => !ids.includes(p.issuer));
  }
  // a new pending code for an issuer ('shell' or a device id): it replaces that issuer's own code; 3 at most, and when a 4th is made
  // the oldest DEVICE code goes (the shell code is never pushed out by a device). Used by the shell command and by POST /api/pair-code.
  function newPairing(name, issuer) {
    const t = now();
    pendings = pendings.filter((p) => t < p.expiresAt && p.issuer !== issuer);
    let code;
    do code = String(crypto.randomInt(0, 1e6)).padStart(6, '0'); while (pendings.some((p) => p.code === code)); // codes of live pairings differ
    const p = { code, name: cleanName(name), expiresAt: t + PAIR_TTL, attempts: 0, issuer };
    pendings.push(p);
    while (pendings.length > PAIR_PENDING) pendings.splice(pendings.findIndex((x) => x.issuer !== 'shell'), 1);
    return p;
  }
  // {appLink, shareLink} from cfg.publicUrl only; null when it is not configured. Never a code, a name or anything from a request:
  // a link can be intercepted (the fcode scheme is not exclusive), so the user types the code.
  function pairLinks() {
    const o = cfg.publicUrl;
    return o ? { appLink: `fcode://pair?server=${encodeURIComponent(o)}`, shareLink: `${o}/pair` } : null;
  }
  function admin(req) { // an exception must never leave the socket callback: it would take the server down
    try { return adminCmd(req); } catch (e) { log(`admin request failed: ${e.code || e.name}`); return { ok: false, error: 'internal' }; }
  }
  function adminCmd(req) {
    refreshConfig(true); // a rotation or a pending purge is handled before any answer
    if (req?.cmd === 'pair') {
      const p = newPairing(req.name, 'shell');
      return { ok: true, code: p.code, expiresAt: p.expiresAt, expiresIn: PAIR_TTL / 1000, ...(req.links && { links: pairLinks() }) };
    }
    if (req?.cmd === 'devices') return { ok: true, devices: [...devices.values()].map(({ id, name, createdAt }) => ({ id, name, createdAt })) };
    if (req?.cmd === 'revoke') {
      const ids = req.id === 'all' ? [...devices.keys()] : [req.id];
      if (req.id !== 'all' && !devices.has(req.id)) return { ok: false, error: 'no such device' };
      try { revoke(ids, req.id === 'all'); } catch (e) { return { ok: false, error: `storage: ${e.code || 'write failed'}` }; }
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

  // --- GET /api/home (A8): each part cached on its own; a failing part is empty or stale, never a 500 ---
  let lastResetList = null; // the last good `omp usage reset --json`: credential ids survive one failed listing
  const quota = memo(QUOTA_TTL, async () => {
    const [u, r] = await Promise.allSettled([execTool(ompSpec, ['usage', '--json'], 30e3), execTool(ompSpec, ['usage', 'reset', '--json'], 30e3)]);
    if (u.status === 'rejected') throw u.reason;
    try { if (r.status === 'fulfilled') lastResetList = JSON.parse(r.value); } catch {}
    return parseQuota(JSON.parse(u.value), lastResetList, now());
  }, now);
  const scan = spendScanner(spendRoots, now);
  const spend = memo(SPEND_TTL, scan, now);
  async function projectInfo(name) {
    const dir = cfg.projects[name];
    const out = { name, repo: null, branch: null, prs: null, lastRun: null };
    const git = (...a) => execTool(gitSpec, ['-C', dir, '-c', 'core.fsmonitor=false', ...a], 5000).then((s) => s.trim(), () => null);
    const gh = (...a) => execTool(ghSpec, ['-R', out.repo, ...a], 20e3).then(JSON.parse).catch(() => null); // failed or not JSON: null
    const [url, br] = await Promise.all([git('remote', 'get-url', 'origin'), git('rev-parse', '--abbrev-ref', 'HEAD')]);
    out.branch = br ? clip(cleanLine(br)) || null : null;
    out.repo = repoOf(url); // the remote URL itself (it may hold credentials) never leaves this function
    if (!out.repo) return out;
    const prList = (fields) => gh('pr', 'list', '--state', 'open', '--limit', '20', '--json', fields);
    const [prs, runs] = await Promise.all([
      // a token without checks access fails the whole query with statusCheckRollup: then the list without checks (checks null)
      prList('number,title,mergeable,statusCheckRollup').then((x) => x ?? prList('number,title,mergeable')),
      gh('run', 'list', '--limit', '1', '--json', 'workflowName,name,status,conclusion,createdAt,url'),
    ]);
    out.prs = Array.isArray(prs) ? prsOf(prs) : null;
    out.lastRun = runOf(runs);
    return out;
  }
  const projects = memo(PROJECTS_TTL, () => Promise.all(cfg.projectNames.map(projectInfo)), now);
  // box timer (estimate, no API key): the last resume = process start or a 30 s tick that came more than 90 s late
  let boxResume = now(), boxTick = now();
  const tickBox = () => { const t = now(); if (t - boxTick > BOX_GAP_MS) boxResume = t; boxTick = t; };
  const boxTimer = setInterval(tickBox, BOX_TICK_MS);
  boxTimer.unref();
  function boxInfo() {
    tickBox();
    const at = boxResume + BOX.maxRunMinutes * 60e3;
    return { state: 'running', sleepsAt: at > now() ? iso(at) : null, ...BOX, source: 'estimate' };
  }
  async function homeView() {
    const [q, s, p] = await Promise.allSettled([quota.get(), spend.get(), projects.get()]);
    const t = now();
    const qv = q.status === 'fulfilled' ? q.value : null;
    const accounts = qv ? qv.value.accounts.map((a) => ({ ...a, stale: a.stale || !qv.fresh })) : [];
    const view = s.status === 'fulfilled' ? spendView(s.value.value, accounts, qv?.value.byAccountId ?? new Map(), t) : null;
    let updates = {};
    try { updates = parseUpdates(fs.readFileSync(updatesFile, 'utf8')); } catch {}
    return {
      generatedAt: iso(t), box: boxInfo(),
      accounts: accounts.map((a) => ({ ...a, spend: view?.perAccount.get(a.id) ?? null })),
      totals: view?.totals ?? { spend: null, byHarness: [] },
      projects: p.status === 'fulfilled' ? p.value.value : [],
      updates,
    };
  }
  // POST /api/codex-reset: one reset per account at a time; a retry with the same requestId gets the same answer, nothing runs twice
  const resetJobs = new Map(); // accountId -> {requestId, promise}
  const resetDone = new Map(); // "accountId|requestId" -> {at, reply}
  function codexReset(accountId, requestId) {
    for (const [k, d] of resetDone) if (now() - d.at > RESET_KEEP_MS) resetDone.delete(k);
    const doneKey = `${accountId}|${requestId}`;
    if (resetDone.has(doneKey)) return Promise.resolve(resetDone.get(doneKey).reply);
    const busy = resetJobs.get(accountId);
    if (busy) return busy.requestId === requestId ? busy.promise : Promise.reject(new HttpErr(409, 'in_progress'));
    const job = (async () => { // the lock is taken before the first await
      let acct;
      try { acct = (await quota.get()).value.accounts.find((a) => a.id === accountId); } catch { throw new HttpErr(503, 'unavailable'); }
      if (!acct) throw new HttpErr(404, 'not_found');
      if (acct.harness !== 'codex') throw new HttpErr(400, 'not_allowed');
      if (!acct.resets.target) throw new HttpErr(409, 'no_target');
      let reply;
      try { reply = resetReply(await execTool(ompSpec, ['usage', 'reset', acct.resets.target], RESET_TIMEOUT)); } catch (e) {
        reply = e.code === 'ENOENT' || e.killed ? { result: 'error', message: RESET_MSG.tool } : resetReply(`${e.stdout ?? ''}\n${e.stderr ?? ''}`);
      }
      log(`codex-reset ${accountId} ${reply.result}`); // the account id and the result only
      resetDone.set(doneKey, { at: now(), reply });
      if (reply.result === 'reset' || reply.result === 'already') quota.clear();
      return reply;
    })();
    resetJobs.set(accountId, { requestId, promise: job });
    job.then(() => resetJobs.delete(accountId), () => resetJobs.delete(accountId));
    return job;
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

    refreshConfig(); // first thing for every route: no route may see a stale secret, device list or pending code
    if (pathname === '/pair' && (method === 'GET' || method === 'HEAD')) { // share link: no code in it; never reads or changes a pending code
      const links = pairLinks(); // the query string is never read
      const status = links ? 200 : 503;
      const body = pairPage(links?.appLink);
      res.writeHead(status, { 'Content-Type': 'text/html; charset=utf-8', 'Content-Length': Buffer.byteLength(body), 'Cache-Control': 'no-store' });
      return res.end(method === 'HEAD' ? undefined : body);
    }

    const isApi = pathname.startsWith('/api/');
    if (method !== 'GET' && method !== 'HEAD' && !csrfOk(req)) throw new HttpErr(403, 'forbidden');

    const seg = pathname.split('/');
    const isPair = pathname === '/api/pair';
    if (!isPair) {
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
      const all = url.searchParams.get('all') === '1';
      try { revoke(all ? [...devices.keys()] : [ctx.device], all); } catch { throw new HttpErr(500, 'storage'); }
      return json(res, 200, { ok: true }, { 'Set-Cookie': setCookie('', 0) });
    }
    if (pathname === '/api/me') { want('GET'); return json(res, 200, { ok: true }); }
    if (pathname === '/api/pair-code') { // a paired device mints a code for its next device (same store, TTL, single use and limits as --pair)
      want('POST');
      const b = body.length ? parseJson(req, body) : {};
      if (b.name !== undefined && typeof b.name !== 'string') throw new HttpErr(400, 'invalid');
      if (!cfg.publicUrl) throw new HttpErr(409, 'no_public_url'); // no code is made when no link can be built
      const p = newPairing(b.name, ctx.device);
      return json(res, 200, { code: p.code, expiresAt: new Date(p.expiresAt).toISOString(), ...pairLinks() });
    }
    if (pathname === '/api/overview') { want('GET'); return json(res, 200, await overview(ctx)); }
    if (pathname === '/api/home') { want('GET'); return json(res, 200, await homeView()); }
    if (pathname === '/api/codex-reset') {
      want('POST');
      const { accountId, requestId } = parseJson(req, body);
      if (typeof accountId !== 'string' || accountId.length > 128 || typeof requestId !== 'string' || !/^[A-Za-z0-9-]{8,64}$/.test(requestId)) throw new HttpErr(400, 'invalid');
      return json(res, 200, await codexReset(accountId, requestId));
    }
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
  const close = () => {
    clearInterval(boxTimer);
    return Promise.all([
      new Promise((resolve) => { server.close(() => resolve()); server.closeAllConnections(); }),
      new Promise((resolve) => (adminServer.listening ? adminServer.close(() => resolve()) : resolve())),
    ]);
  };
  return { server, listen, close, devices, tickBox, stats: () => ({ streams, running, reads, waiting: queue.length, active: !!active }) };
}

// ---------- CLI ----------
// fcode-pair --qr: the QR of the server-only app link (qrencode, when installed), the share link, then the code in big digits and
// ONE expiry line. The QR holds no code: the user types it.
function printQr(r) {
  const { links } = r;
  if (!links) console.log('Chưa đặt "publicUrl" trong config.json nên chưa tạo được link/mã QR. Ví dụ: "publicUrl": "https://<địa-chỉ-công-khai>"');
  else {
    let shown = false;
    try { process.stdout.write(execFileSync('qrencode', ['-t', 'ANSIUTF8', links.appLink], { encoding: 'utf8', timeout: 5000, windowsHide: true })); shown = true; } catch {}
    console.log(`Link chia sẻ: ${links.shareLink}`);
    if (!shown) console.log(`Link mở app: ${links.appLink}\ncài qrencode để hiện mã QR`);
  }
  const bar = '='.repeat(32);
  console.log(`\n${bar}\n  MÃ GHÉP:   ${[...r.code].join('   ')}\n${bar}\nMã hết hạn sau ${Math.round(r.expiresIn / 60)} phút.`);
}
async function main() {
  const dir = defaultConfigDir();
  const arg = (f) => { const i = process.argv.indexOf(f); return i < 0 ? undefined : process.argv[i + 1] ?? ''; };
  const qr = process.argv.includes('--qr');
  const req = process.argv.includes('--pair') ? { cmd: 'pair', name: arg('--pair') === '--qr' ? '' : arg('--pair'), ...(qr && { links: true }) }
    : process.argv.includes('--devices') ? { cmd: 'devices' }
      : process.argv.includes('--revoke') ? { cmd: 'revoke', id: arg('--revoke') } : null;
  if (req) { // admin CLI: talks to the RUNNING server over admin.sock
    let r;
    try { r = await adminRequest(dir, req); } catch (e) { console.error(e.code === 'ENOSERVER' ? `${e.message} (no ${adminPath(dir)})` : `admin socket: ${e.message}`); process.exit(1); }
    if (!r.ok) { console.error(`error: ${r.error}`); process.exit(1); }
    if (req.cmd === 'pair') {
      if (qr) printQr(r);
      else console.log(`Mã ghép: ${r.code} (hết hạn sau ${r.expiresIn} giây)\nNhập mã này vào app. Chạy lại lệnh sẽ thay mã cũ của lệnh này.`);
    } else if (req.cmd === 'devices') {
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
