#!/usr/bin/env node
// fcoding server: Node 22, built-ins only. See CONTRACT.md (S1-S8, A1-A5).
import http from 'node:http';
import net from 'node:net';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFile, execFileSync, spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { performance } from 'node:perf_hooks';

export const HARNESSES = { omp: 'omp', claude: 'claude', codex: 'codex', shell: 'bash -l' };
export const KEYS = ['Enter', 'Escape', 'Tab', 'BTab', 'Up', 'Down', 'Left', 'Right', 'PageUp', 'PageDown',
  'Home', 'End', 'BSpace', 'C-c', 'C-d', 'C-l', 'C-o', 'C-r', 'C-u', 'C-z', 'M-a', 'y', 'n', 'Space'];
const NAME_RE = /^[a-z0-9][a-z0-9-]{0,31}$/;
const COOKIE = 'pc_sid';
const COOKIE_MAX_AGE = 30 * 24 * 3600;
const BODY_LIMIT = 64 * 1024;
const TEXT_LIMIT = 32 * 1024;
const LONG_TEXT = 500; // bytes; longer single lines are pasted, not typed
// v1.3.3 image upload (CONTRACT A12): POST /api/projects/<name>/upload. Content-Type -> file extension and the magic bytes the body must start with
const UPLOAD_LIMIT = 10 * 1024 * 1024;
const UPLOAD_KEEP_MS = 7 * 24 * 3600e3; // a file in .fcode/uploads older than this is deleted by the next upload
const UPLOAD_NAME_RE = /^\d{8}-\d{6}-[0-9a-f]{6}\.(?:jpg|png)$/;
const UPLOAD_ROUTE = /^\/api\/projects\/([^/]+)\/upload$/;
const UPLOAD_SLOTS = 2; // uploads in flight at once (counted before a body byte is read); one more is 429 busy
const UPLOAD_REQUEST_MS = 120e3; // an admitted upload's body window (and http requestTimeout): a 10 MiB photo on a weak link
const BODY_MS = 15e3; // every other request, and an upload before it is admitted, is cut when not complete after this
const NOFOLLOW = fs.constants.O_NOFOLLOW ?? 0; // not defined on Windows
const UPLOAD_TYPES = new Map([
  ['image/jpeg', { ext: 'jpg', magic: Buffer.from([0xff, 0xd8, 0xff]) }],
  ['image/png', { ext: 'png', magic: Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) }],
]);
const PAIR_TTL = 120 * 1000, PAIR_ATTEMPTS = 5, PAIR_PENDING = 3;
const PAIR_PER_MINUTE = 10, PAIR_MINUTE = 60 * 1000, PAIR_PER_HOUR = 30, PAIR_HOUR = 3600 * 1000;
const MAX_STREAMS = 50;
const MAX_WAITING = 20; // mutation jobs waiting behind the active one
const MAX_READS = 7; // 8 tmux children in all: one slot is reserved for the active mutation
const DRAIN_TIMEOUT = 30000;
const HARNESS_CHECK_MS = 400; // after create: is the harness still running?
const ADMIN_JOB_MS = 20000; // admin.sock: how long a request may take once it is read (fcode-new waits for a session to start)
const FCODE_NEW_HARNESSES = ['omp', 'claude', 'codex']; // what fcode-new offers (not the plain shell)
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

// ---------- project order + display names (GET / PUT /api/prefs, CONTRACT A13) ----------
const ALIAS_MAX = 30;
const ALIAS_RE = /^[\p{L}\p{M}\p{N} ._-]+$/u;
const PREFS_BAD = 'Dữ liệu sắp xếp không đúng dạng.';
// The body of a PUT or the stored file -> {order, aliases}: only known project names, unique order, NFC trimmed aliases; an alias equal to its
// own project name is dropped. Strict (PUT): a wrong shape or a refused alias throws HttpErr(400, <Vietnamese sentence>); the app mirrors these
// rules. Lenient (GET of the stored file): the same checks drop only the entry that no longer fits (the first alias in project order wins), keep the rest.
function normalizePrefs(v, names, lenient = false) {
  const bad = (msg) => { if (!lenient) throw new HttpErr(400, msg); };
  const root = v && typeof v === 'object' ? v : {};
  const orderIn = Array.isArray(root.order) ? root.order : [];
  const aliasesIn = root.aliases && typeof root.aliases === 'object' && !Array.isArray(root.aliases) ? root.aliases : {};
  if (orderIn !== root.order || aliasesIn !== root.aliases) bad(PREFS_BAD);
  const order = [];
  for (const n of orderIn) {
    if (typeof n !== 'string') { bad(PREFS_BAD); continue; }
    if (names.includes(n) && !order.includes(n)) order.push(n);
  }
  const aliases = {}; const used = new Map(); // lower-cased alias -> project
  for (const name of names) {
    const raw = Object.hasOwn(aliasesIn, name) ? aliasesIn[name] : undefined; // own keys only: a project called "constructor" has no alias
    if (raw === undefined || raw === null) continue;
    if (typeof raw !== 'string') { bad(PREFS_BAD); continue; }
    const a = raw.normalize('NFC').trim();
    if (!a || a === name) continue;
    if ([...a].length > ALIAS_MAX) { bad(`Tên “${[...a].slice(0, ALIAS_MAX).join('')}…” dài quá ${ALIAS_MAX} ký tự.`); continue; }
    if (!ALIAS_RE.test(a)) { bad(`Tên “${a}” chỉ được có chữ, số, dấu cách và - _ .`); continue; }
    const key = a.toLowerCase();
    const other = names.find((n) => n !== name && n.toLowerCase() === key);
    if (other) { bad(`Tên “${a}” trùng tên dự án ${other}.`); continue; }
    if (used.has(key)) { bad(`Tên “${a}” đã dùng cho ${used.get(key)}.`); continue; }
    used.set(key, name); aliases[name] = a;
  }
  return { order, aliases };
}

// ---------- add a project (POST /api/projects, CONTRACT A11) ----------
const CTRL_RE = /[\x00-\x1f\x7f]/;
const REPO_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const PROJECT_NAME_RE = /^[a-z0-9][a-z0-9._-]{0,63}$/;
// A pasted GitHub link -> owner/repo: https://[www.]github.com/o/r, github.com/o/r or git@github.com:o/r, then any of /, .git, ?query, #fragment and
// extra path (/tree/main). Any other text is returned as it is (plain owner/repo, or something the repo rule then refuses: another host has a ":" or "@").
const GITHUB_LINK_RE = /^(?:https:\/\/(?:www\.)?github\.com\/|(?:www\.)?github\.com\/|git@github\.com:)([^?#]*)/i;
export function repoOfLink(s) {
  const m = GITHUB_LINK_RE.exec(s);
  if (!m) return s;
  const [owner, repo = ''] = m[1].split('/');
  return `${owner}/${repo}`;
}
// Same rules as `fcode add` (laptop/fcode.ps1 Invoke-Add), after repoOfLink: -> {repo, name} or a 400 bad_repo / bad_name. A null or empty name means "the repo part".
export function parseAddRequest(b) {
  const bad = (code) => new HttpErr(400, code);
  if (typeof b.repo !== 'string' || CTRL_RE.test(b.repo)) throw bad('bad_repo');
  const repo = repoOfLink(b.repo).replace(/\.git$/i, '');
  if (!REPO_RE.test(repo) || /^\.+\//.test(repo) || /\/\.+$/.test(repo)) throw bad('bad_repo');
  const given = b.name !== undefined && b.name !== null && b.name !== '';
  if (given && (typeof b.name !== 'string' || CTRL_RE.test(b.name))) throw bad('bad_name');
  const name = given ? b.name.toLowerCase().replace(/\.git$/, '') : repo.split('/')[1].toLowerCase();
  if (!PROJECT_NAME_RE.test(name) || name === 'home') throw bad('bad_name');
  return { repo, name };
}
// script exit code -> job code; anything else (or a signal) is FAILED. The script's "R <CODE> [detail]" lines add the public key and the detail.
const ADD_CODES = { 0: 'ADDED', 30: 'ADDED_WARN', 40: 'NEED_KEY', 41: 'NEED_WRITE', 42: 'WRITE_BLOCKED', 43: 'NET_FAIL', 44: 'REPO_ARCHIVED',
  11: 'DIR_CONFLICT', 21: 'CFG_CONFLICT', 22: 'CFG_BROKEN', 23: 'NAME_USED', 2: 'BAD_ARGS', 12: 'CLONE_FAIL',
  124: 'TIMEOUT' }; // timeout(1): 124 = the deadline (its --kill-after kill ends it as a signal, not a code; the job's own deadline, kept when the server is gone)
// the detail words the app matches: DIR_EXISTS 'exists', DIR_UNSAFE 'unsafe', HOOK_FAIL 'install' | 'verify'; also URL_REWRITE 'rewrite' (26) and CRED_FAIL 'config' (25); first line with text wins
const ADD_DETAIL = ['SSH_DETAIL', 'CLONE_FAIL', 'DIR_EXISTS', 'DIR_UNSAFE', 'HOOK_FAIL', 'URL_REWRITE', 'CRED_FAIL', 'CFG_CONFLICT', 'CFG_BROKEN', 'CLEANUP_FAIL'];
const SERVER_DIR = path.dirname(fileURLToPath(import.meta.url));
const ADD_SCRIPT = path.join(SERVER_DIR, 'fcode-add.sh'), ADD_SCRIPT_DEV = path.join(SERVER_DIR, 'box', 'fcode-add.sh'); // installed next to server.mjs, or in a checkout
const GH_LIST_MS = 60e3, GH_PAGES = 3, GH_PAGE_SIZE = 100, GH_LIST_MAX = GH_PAGES * GH_PAGE_SIZE; // GET /api/github/repos: cache time, pages read, most repos listed
// pages 1..3 of the newest-updated repos, one JSON object per line ("@json"); no --paginate (an account with thousands of repos would run out of time)
const ghReposArgs = (page) => ['api', `/user/repos?affiliation=owner,collaborator,organization_member&sort=updated&per_page=${GH_PAGE_SIZE}&page=${page}`, '--jq',
  '.[] | {repo: .full_name, private: .private, archived: .archived, canPush: (.permissions.push // false), updatedAt: .updated_at} | @json'];
const ADD_TIMEOUT_MS = 10 * 60e3, ADD_KEEP_MS = 30 * 60e3, ADD_MAX_JOBS = 50, ADD_KILL_AFTER_S = 30, ADD_KILL_GRACE_MS = 45000, ADD_OUT_MAX = 256 * 1024;
// a detail is one clean line of at most 200 characters; tokens and URL credentials never pass
const jobText = (s) => Array.from(cleanLine(s).replace(/(gh[a-z]_|github_pat_)[A-Za-z0-9_]+/gi, '<token>').replace(/\/\/[^/\s@]*@/g, '//<cred>@')).slice(0, 200).join('');
export function addOutcome(code, stdout) {
  const lines = new Map();
  for (const l of stdout.split('\n')) { const m = /^R (\S+)(?: (.*))?$/.exec(l.replace(/\r$/, '')); if (m) lines.set(m[1], m[2] ?? ''); }
  const result = code === 21 && lines.has('ALIAS_FAIL') ? 'FAILED' : ADD_CODES[code] ?? 'FAILED'; // 21 is also "cannot write the ssh config"
  // via: the way in that ended the run. A token run that fell back to a deploy key printed TOKEN_FALLBACK, then the key lines: key wins.
  const via = lines.has('KEY_NEW') || lines.has('KEY_EXISTS') ? 'key' : lines.has('TOKEN_OK') ? 'token' : null;
  const out = { state: code === 0 || code === 30 ? 'done' : 'failed', code: result, detail: null, via };
  const found = code === 0 ? null : ADD_DETAIL.find((k) => lines.get(k));
  if (found) out.detail = jobText(lines.get(found)) || null;
  const pub = lines.get('PUBKEY'); // public key only: anything that is not one line "ssh-ed25519 <base64> [comment]" is dropped
  if ((result === 'NEED_KEY' || result === 'NEED_WRITE') && /^ssh-ed25519 [A-Za-z0-9+/]+={0,2}( \S{1,200})?$/.test(pub ?? '')) out.pubkey = pub;
  return out;
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
// The server origin the app accepts in a pairing link. ONE rule shared with the iOS PairLink parser: the "rule" field and the vectors in
// test/origin-vectors.json (the same file is in the iOS tree). Raw input printable ASCII only, then lower-cased as a whole; "https://" + host
// [+ ":" port, 1-65535 without a leading zero] [+ "/"], nothing else; host = LDH name with a dot (no "xn--" label, last label not a number) OR dotted IPv4
// without leading zeros and without a trailing dot OR a bracketed IPv6 address. Returns the canonical origin (443 left out) or null.
// A host written another way (IDN, "localhost", "192.168.001.010", "1.2.3.0x4") gives a QR no phone can use.
export function strictOrigin(raw) {
  if (typeof raw !== 'string' || /[^\x21-\x7e]/.test(raw)) return null; // printable ASCII only (checked before lowercasing: KELVIN SIGN must not become "k")
  const m = /^https:\/\/(\[[0-9a-f:.]+\]|[^:/[\]]+)(?::([1-9]\d{0,4}))?\/?$/.exec(raw.toLowerCase()); // the whole string is lower-cased, scheme included
  if (!m) return null;
  let host = m[1];
  const port = m[2] === undefined ? null : Number(m[2]);
  if (port !== null && !(port >= 1 && port <= 65535)) return null;
  const origin = `https://${host}${port === null || port === 443 ? '' : `:${port}`}`;
  if (host.startsWith('[')) return net.isIPv6(host.slice(1, -1)) ? origin : null;
  if (/^(0|[1-9]\d{0,2})(\.(0|[1-9]\d{0,2})){3}$/.test(host)) return host.split('.').every((o) => Number(o) <= 255) ? origin : null;
  if (host.endsWith('.')) host = host.slice(0, -1);
  const labels = host.split('.');
  if (host.length > 253 || labels.length < 2 || !labels.every((l) => /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/.test(l) && !l.startsWith('xn--'))) return null;
  if (/^(0x[0-9a-f]*|[0-9]+)$/.test(labels.at(-1))) return null; // read as a number by the system resolver
  return `https://${host}${port === null || port === 443 ? '' : `:${port}`}`;
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
  // publicOrigin: publicUrl in the exact form the app accepts, or null (then no pairing link is made; see strictOrigin)
  const publicOrigin = publicUrl === undefined ? null : strictOrigin(c.publicUrl);
  // timeZone: the IANA zone of the home screen's days (today, yesterday, 30 days); never the process TZ
  const timeZone = c.timeZone ?? DEFAULT_TZ;
  try { if (typeof timeZone !== 'string') throw new Error('bad'); new Intl.DateTimeFormat('en-CA', { timeZone }); } catch { throw new Error('config.json: timeZone invalid (want an IANA zone such as "Asia/Ho_Chi_Minh")'); }
  return {
    secret: Buffer.from(s, 'base64'), port: c.port, projects, publicUrl, publicOrigin, timeZone,
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
    // no half-close after the request (a named pipe on Windows would drop the reply of a slow command): the reply is one line
    const done = () => { clearTimeout(t); s.destroy(); try { resolve(JSON.parse(buf)); } catch { reject(new Error('bad admin reply')); } };
    s.on('connect', () => s.write(`${JSON.stringify(req)}\n`));
    s.on('data', (d) => { buf += d; if (buf.includes('\n')) done(); });
    s.on('end', done);
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
  const body = !appLink ? '<p>Máy chủ chưa đặt địa chỉ công khai hợp lệ, nên chưa mở được app từ link này.</p>'
    : `<a class="btn" href="${escHtml(appLink)}">Mở FCode</a><p>Sau khi app mở, gõ mã 6 số đang hiện trên iPhone cũ hoặc trên máy tính.</p><p class="s">Chưa cài FCode? Cài file fcode.ipa trước.</p>`;
  return `<!doctype html><html lang="vi"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>Ghép FCode</title><style>body{margin:0;font:17px/1.5 -apple-system,system-ui,sans-serif;background:#111;color:#eee;text-align:center}main{padding:48px 24px}.btn{display:block;max-width:320px;margin:24px auto;padding:16px;border-radius:14px;background:#0a84ff;color:#fff;font-size:20px;font-weight:600;text-decoration:none}.s{color:#999;font-size:15px}</style></head><body><main><h1>Ghép iPhone với FCode</h1>${body}</main></body></html>`;
}

// ---------- home screen v2 (CONTRACT.md A8): quota, spend, box timer, projects, updates, Codex reset ----------
const QUOTA_TTL = 60e3, LISTING_TTL = 300e3, SPEND_TTL = 300e3, PROJECTS_TTL = 120e3, GATE_CONFIG_TTL = 600e3, RUN_WINDOW = 100; // RUN_WINDOW: Actions runs read per project (deploy line and PR checks)
const HOME_WAIT_MS = 8000; // a part with no value yet is waited for this long at most, then it is empty and fills in the background
const FRESH_MIN_MS = 10e3, HOME_FRESH_WAIT_MS = 25e3; // GET /api/home?fresh=1: a part older than 10 s is read again and waited for, 25 s at most
const WARM_TICK_MS = 5e3; // from boot every home part is checked this often and refreshed once it is past its own TTL (never more than one refresh at a time)
const OVERVIEW_PAR = 3, OVERVIEW_KEEP = 4; // GET /api/overview: its git and tmux reads run at most this many at a time, each inside one of the MAX_READS slots; it leaves OVERVIEW_KEEP slots free (two screen reads)
const QUOTA_STALE_MS = 10 * 60e3; // a report omp fetched longer ago than this is stale
const DEFAULT_TZ = 'Asia/Ho_Chi_Minh';
export const BOX = { maxRunMinutes: 480, idlePauseMinutes: 30, cooldownMinutes: 10 };
const BOX_REC_MS = 10 * 60e3; // the box's own instabox record is used while it was read less than this ago (staging refreshes it every 30 s)
const BOX_TICK_MS = 30e3, BOX_GAP_MS = 90e3; // a tick that comes more than 90 s late = the box was asleep and resumed
const SPEND_DAYS = 30, SCAN_DAYS = 31, SCAN_CHUNK = 8 << 20, MAX_LINE = 4 << 20;
const RESET_TIMEOUT = 45e3, RESET_KEEP_MS = 15 * 60e3, RESET_REPLY_MS = 15e3; // a reset still running after 15 s is answered 202 pending
const RESET_FINAL = ['reset', 'already', 'nothing_to_reset', 'no_credit']; // the only answers kept for a retry with the same requestId
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
  'gpt-5.6-cyber': [12.5, 75, 1.25, 15.625], 'gpt-5.5': [5, 30, 0.5], 'gpt-5.5-pro': [30, 180], 'gpt-5.5-cyber': [12.5, 75, 1.25],
  'gpt-5.4': [2.5, 15, 0.25], 'gpt-5.4-pro': [30, 180], 'gpt-5.4-mini': [0.75, 4.5, 0.075], 'gpt-5.4-nano': [0.2, 1.25, 0.02],
  'gpt-5.3-codex': [1.75, 14, 0.175], 'gpt-5.2': [1.75, 14, 0.175], 'gpt-5.2-pro': [21, 168], 'gpt-5.1': [1.25, 10, 0.125],
  'gpt-5.1-codex-mini': [0.25, 2, 0.025], 'gpt-5': [1.25, 10, 0.125], 'gpt-5-pro': [15, 120], 'gpt-5-codex': [1.25, 10, 0.125],
  'gpt-5-mini': [0.25, 2, 0.025], 'gpt-5-nano': [0.05, 0.4, 0.005],
};
// LiteLLM bills these suffixes at the base model's rate (gpt-5.1-codex-max = gpt-5.1, gpt-5.2-chat-latest = gpt-5.2)
const SAME_PRICE_SUFFIX = /-(?:codex-max|codex|chat-latest|chat|search-api)$/;
// exact name (date suffix dropped), then the base of a same-price variant; any other variant is unpriced
export function priceOf(model) {
  if (typeof model !== 'string') return null;
  const m = model.toLowerCase().replace(/^.*\//, '').replace(/-\d{8}$|-\d{4}-\d{2}-\d{2}$/, '');
  if (Object.hasOwn(PRICES, m)) return PRICES[m];
  const base = m.replace(SAME_PRICE_SUFFIX, '');
  return base !== m && Object.hasOwn(PRICES, base) ? PRICES[base] : null;
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
// A child session (fork or subagent spawn) whose leading token_count lines replay the parent's history (Pane codex_child_meta):
// JSON null and blank strings count as absent, so a root session with `forked_from_id: null` is not a child.
export function codexChildMeta(p) {
  const set = (k) => p?.[k] !== undefined && p[k] !== null && (typeof p[k] !== 'string' || p[k].trim() !== '');
  return set('forked_from_id') || set('parent_thread_id') || p?.thread_source === 'subagent'
    || (p?.source !== null && typeof p?.source === 'object' && p.source.subagent !== undefined && p.source.subagent !== null);
}
const epochSec = (t) => { const ms = Date.parse(t); return Number.isFinite(ms) ? Math.floor(ms / 1000) : null; };
// Codex (~/.codex/sessions, archived_sessions): token_count events; st carries the session, account and model of the file.
// Replay gate (Pane CodexReplayGate): a child file replays its parent's history, task_started lines included (with the parent's
// older started_at), before its own first live turn. The gate opens at the first task_started whose started_at is at or after
// the child's session_meta timestamp (seconds); with no such timestamp, at or after that task_started line's own second.
export function codexLine(v, st) {
  const p = v?.payload;
  if (!p || typeof p !== 'object') return null;
  if (v.type === 'session_meta') { // only the file's own (first) one counts: a child file repeats its parent's right after
    if (st.sawMeta) return null;
    st.sawMeta = true;
    st.session = str(p.id);
    st.account = str(p.creator_account_id) ?? str(p.account_id);
    st.model = str(p.model) ?? st.model;
    if (codexChildMeta(p)) st.gate = { until: epochSec(v.timestamp) }; // until null: self-timed
    return null;
  }
  if (v.type === 'turn_context') { st.model = str(p.model) ?? st.model; return null; }
  if (p.type === 'task_started') {
    const started = p.started_at;
    if (st.gate && typeof started === 'number' && Number.isFinite(started)) {
      const t = st.gate.until ?? epochSec(v.timestamp);
      if (t !== null && started >= t) st.gate = null;
    }
    return null;
  }
  if (p.type !== 'token_count' || !p.info || typeof p.info !== 'object') return null;
  const tot = p.info.total_token_usage, last = p.info.last_token_usage;
  const totKey = tot ? JSON.stringify(tot) : null;
  if (totKey && totKey === st.prev) return null; // the same cumulative totals again: a re-emitted snapshot, not new usage
  const prevTot = st.prevTot;
  st.prev = totKey; st.prevTot = tot;
  if (st.gate) return null; // replayed parent history: seeds the delta baseline, never counted (the parent's file counts it)
  const u = last ?? (tot && Object.fromEntries(Object.keys(tot).map((k) => [k, Math.max(0, num(tot[k]) - num(prevTot?.[k]))])));
  const ts = Date.parse(v.timestamp);
  if (!u || !Number.isFinite(ts)) return null;
  const input = num(u.input_tokens), cached = Math.min(input, num(u.cached_input_tokens)), output = num(u.output_tokens);
  const pr = priceOf(str(p.info.model) ?? st.model);
  return { ts, harness: 'codex', who: st.account ? `codex:${st.account}` : null, usd: pr ? costOf(pr, { input: input - cached, output, cacheRead: cached }) : null,
    tokens: num(u.total_tokens) || input + output, key: `x:${st.session ?? st.file}:${totKey ?? ts}` };
}
const PREFILTER = { omp: (l) => l.includes('"usage"'), claude: (l) => l.includes('"assistant"'), codex: (l) => /token_count|turn_context|session_meta|task_started/.test(l) };
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
const dayFmt = new Map();
// "YYYY-MM-DD" of an instant in an IANA zone
const dayKey = (ms, timeZone) => {
  let f = dayFmt.get(timeZone);
  if (!f) dayFmt.set(timeZone, f = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }));
  return f.format(ms);
};
const r4 = (x) => Math.round(x * 1e4) / 1e4;
const money = ({ usd, tokens }) => ({ usd: r4(usd), tokens: Math.round(tokens) });
// {today, yesterday, last30, weeklyEstimate, daily30}: calendar days in timeZone (config.json, never the process TZ), the last 30
// ending today, oldest first. weeklyEstimate (Pane): spend inside the account's "7d" window / (usedPercent / 100), from 5 % used;
// at >= 100 % the spend itself. Only the account's own (attributed) events count: unattributed usage of the same quota is left out.
export function spendOf(events, nowMs, weekly = null, timeZone = DEFAULT_TZ) {
  const days = [];
  const today = Date.parse(`${dayKey(nowMs, timeZone)}T12:00:00Z`); // the date only; day arithmetic in UTC has no DST
  for (let i = SPEND_DAYS - 1; i >= 0; i--) days.push(new Date(today - i * 86400e3).toISOString().slice(0, 10));
  const idx = new Map(days.map((k, i) => [k, i]));
  const daily = days.map((date) => ({ date, usd: 0, tokens: 0 }));
  for (const e of events) {
    const i = idx.get(dayKey(e.ts, timeZone));
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
// An account without an omp credential id (a "~hash" id: no reset listing matched it) has spend null: unknown, not $0.
export function spendView(events, accounts, byAccountId, nowMs, timeZone = DEFAULT_TZ) {
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
  const perAccount = new Map(accounts.map((a) => [a.id, a.resets.target ? spendOf(byId.get(a.id), nowMs, a.windows.find((w) => w.key === '7d'), timeZone) : null]));
  const harnesses = [...new Set(uniq.map((e) => e.harness))];
  const byHarness = harnesses.map((h) => ({ harness: h, usd: spendOf(uniq.filter((e) => e.harness === h), nowMs, null, timeZone).last30.usd })).sort((a, b) => b.usd - a.usd);
  return { perAccount, totals: { spend: spendOf(uniq, nowMs, null, timeZone), byHarness } };
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
// a workflow is told apart by its id (a run's workflowDatabaseId, a workflow list's id): two files can share a name; without an id, by name
const wfKey = (r) => String(r?.workflowDatabaseId ?? r?.id ?? str(r?.workflowName) ?? str(r?.name) ?? '');
// checks of one PR head from Actions runs (gh run list --json workflowDatabaseId,workflowName,name,status,conclusion,headSha, newest first):
// the latest run per workflow through the same pass/fail/pending rules as the rollup; null when the runs could not be read
export function checksOfRuns(runs, sha) {
  if (!Array.isArray(runs)) return null;
  const latest = new Map();
  for (const r of runs) {
    const wf = wfKey(r);
    if (sha && r?.headSha === sha && !latest.has(wf)) latest.set(wf, { status: String(r.status ?? '').toUpperCase(), conclusion: String(r.conclusion ?? '').toUpperCase() });
  }
  return checksOf([...latest.values()]);
}
// runs: Actions runs, the checks of a PR whose statusCheckRollup is unreadable (a token without Checks access)
export const prsOf = (list, runs = null) => list.map((p) => ({ number: p.number, title: clip(cleanLine(String(p.title ?? ''))), checks: checksOf(p.statusCheckRollup) ?? checksOfRuns(runs, p.headRefOid),
  mergeable: p.mergeable === 'MERGEABLE' ? true : p.mergeable === 'CONFLICTING' ? false : null }));
export function runOf(list) {
  const r = Array.isArray(list) ? list[0] : null;
  if (!r || typeof r !== 'object') return null;
  const status = r.status !== 'completed' ? 'in_progress' : ['success', 'neutral', 'skipped'].includes(r.conclusion) ? 'success' : 'failure';
  return { workflow: str(r.workflowName) ?? str(r.name), status, at: str(r.createdAt), url: str(r.url) };
}
// the workflows whose name or file path contains "deploy" (gh workflow list --all --json id,name,path)
export const deployWorkflows = (workflows) => (Array.isArray(workflows) ? workflows : []).filter((w) => /deploy/i.test(`${w?.name} ${w?.path}`));
// the newest run of a deploy workflow (the same, by id); PR gates and CI are never it
export function deployRunOf(runs, workflows) {
  if (!Array.isArray(runs)) return null;
  const ids = new Set(deployWorkflows(workflows).map(wfKey));
  return runOf(runs.filter((r) => { const n = str(r?.workflowName) ?? str(r?.name); return n && (/deploy/i.test(n) || ids.has(wfKey(r))); }));
}
// Generic deploy gate (decision-r4 §4.4): the deploy line of a gate project is the commit status `fcode/deploy` of the head. The
// status text is untrusted: only its first word is read and mapped to a fixed (status, kind); the text itself is never shown or logged.
// status uses the lastRun values the app already knows (done -> success, failed -> failure); `kind` is the finer state (absent on an Actions line).
export const GATE_CONTEXT = 'fcode/deploy';
const GATE_KEYWORDS = new Map([['deployed', ['success', 'deployed']], ['skipped', ['success', 'skipped']], ['superseded', ['success', 'superseded']],
  ...['queued', 'waiting', 'building', 'activating', 'deferred', 'paused'].map((k) => [k, ['in_progress', 'waiting']]),
  ...['refused', 'rolled', 'config'].map((k) => [k, ['failure', 'failed']]), ['needs', ['failure', 'needs_human']]]);
// the statuses list (one JSON array per line: [context, description, created_at, target_url], newest first) -> the first fcode/deploy entry or null
export function gateStatusOf(text) {
  for (const l of String(text).split('\n')) {
    if (!l.trim()) continue;
    const e = JSON.parse(l);
    if (Array.isArray(e) && typeof e[0] === 'string' && e[0].toLowerCase() === GATE_CONTEXT) return e;
  }
  return null;
}
// a status entry (null: the head has none yet) -> lastRun
export function gateRunOf(e) {
  const [status, kind] = (e && GATE_KEYWORDS.get(String(e[1] ?? '').split(/[\s:;]+/)[0].toLowerCase())) || ['in_progress', 'waiting'];
  return { workflow: GATE_CONTEXT, status, kind, at: isoOf(e?.[2]), url: githubUrl(e?.[3]) };
}
const githubUrl = (u) => (typeof u === 'string' && /^https:\/\/github\.com\/\S{1,300}$/.test(u) ? u : null);
// A project with no deploy line shows its newest published release (gh release list --json tagName,publishedAt,isLatest; drafts and
// prereleases are excluded by flags) as kind "released"; no usable release -> null. The tag is untrusted text.
export function releaseRunOf(list, repo) {
  const r = (Array.isArray(list) ? list : []).filter((x) => typeof x?.tagName === 'string' && Date.parse(x.publishedAt) > 0)
    .sort((a, b) => Date.parse(b.publishedAt) - Date.parse(a.publishedAt))[0];
  const tag = r && clip(cleanLine(r.tagName));
  if (!tag) return null;
  return { workflow: tag, status: 'success', kind: 'released', at: isoOf(r.publishedAt), url: githubUrl(`https://github.com/${repo}/releases/tag/${r.tagName.split('/').map(encodeURIComponent).join('/')}`) };
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
  pending: 'Reset vẫn đang chạy trên box. Xem lại Hạn mức sau ít phút.',
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
// the environment of the tools the server runs (omp, gh, git, fcode-git-sync): ~/.local/bin and ~/.bun/bin first on PATH
const toolEnv = () => ({ ...process.env, LANG: 'C.UTF-8', LC_ALL: 'C.UTF-8', NO_COLOR: '1', GH_PROMPT_DISABLED: '1', GIT_OPTIONAL_LOCKS: '0',
  PATH: `${home}/.local/bin:${home}/.bun/bin:${process.env.PATH ?? '/usr/local/bin:/usr/bin:/bin'}` });
// a child with a timeout, never a shell; rejects with stdout/stderr attached
function execTool(spec, args, timeout, env = toolEnv()) {
  return new Promise((resolve, reject) => {
    const [cmd, ...pre] = spec;
    execFile(cmd, [...pre, ...args], { encoding: 'utf8', timeout, maxBuffer: 32 << 20, windowsHide: true, env },
      (err, stdout, stderr) => (err ? reject(Object.assign(err, { stdout, stderr })) : resolve(stdout)));
  });
}
// git-sync.json of the box timer (fcode-git-sync) -> Map project name -> the `git` object of GET /api/home. A missing, unreadable or
// broken file, or a project it does not list, is NO_GIT (every field null; autoUpdated false); a field of the wrong type is null on its own.
// autoUpdated / autoSkip: what the timer's fast-forward did (an entry of an older script has neither: false / null).
const AUTO_SKIPS = ['in_progress', 'on_branch', 'dirty', 'ahead', 'filters', 'busy', 'late', 'ff_failed'];
const NO_GIT = Object.freeze({ behind: null, ahead: null, dirty: null, branch: null, syncedAt: null, error: null, autoUpdated: false, autoSkip: null });
const textOf = (v) => { const t = str(v); return t ? clip(cleanLine(t)) || null : null; };
const count = (v) => (Number.isInteger(v) && v >= 0 ? v : null);
const isoOf = (v) => (typeof v === 'string' ? iso(Date.parse(v)) : null);
export function parseGitSync(text) {
  const out = new Map();
  let projects;
  try { projects = JSON.parse(text)?.projects; } catch { return out; }
  if (!projects || typeof projects !== 'object' || Array.isArray(projects)) return out;
  for (const [name, v] of Object.entries(projects)) {
    if (!v || typeof v !== 'object') continue;
    out.set(name, {
      behind: count(v.behindDefault), ahead: count(v.aheadOfOrigin),
      dirty: typeof v.dirty === 'boolean' ? v.dirty : null,
      branch: textOf(v.branch), syncedAt: isoOf(v.lastFetchAt), error: textOf(v.error),
      autoUpdated: v.autoUpdated === true, autoSkip: AUTO_SKIPS.includes(v.autoSkip) ? v.autoSkip : null,
    });
  }
  return out;
}
// --- v1.3.2: omp sessions of a project, instabox staging box ---
// omp keeps a project's sessions in <agent dir>/sessions/<encoded cwd> (omp's own rule: under tmpdir "-tmp-<rel>", under home "-<rel>" ("-" for
// home itself), else "--<abs path>--"; "/", "\" and ":" become "-", nothing else changes). homeDir / tmpDir are parameters for tests.
export function ompDirName(cwd, homeDir = home, tmpDir = os.tmpdir()) {
  const abs = path.resolve(cwd);
  const within = (base) => { const r = path.relative(path.resolve(base), abs); return r === '' || (!r.startsWith('..') && !path.isAbsolute(r)) ? r : null; };
  const dash = (s) => s.replace(/[/\\:]/g, '-');
  const t = within(tmpDir), h = within(homeDir);
  if (t !== null) return t ? `-tmp-${dash(t)}` : '-tmp';
  if (h !== null) return `-${dash(h)}`;
  return `--${dash(abs.replace(/^[/\\]/, ''))}--`;
}
const OMP_ID_RE = /^[0-9a-f-]{8,64}$/;
const OMP_LIST_MAX = 10, OMP_HEAD_BYTES = 64 * 1024, OMP_TITLE_CHARS = 60;
// session files are <timestamp>_<id>.jsonl: the id is what follows the last "_"
const ompIdOf = (file) => { const m = /_([^_/\\]+)\.jsonl$/.exec(file); return m && OMP_ID_RE.test(m[1]) ? m[1] : null; };
// omp session format guard: the header (`type:"session"`) versions this server understands. The laptop sync (laptop/fcode.ps1) keeps the same list.
export const KNOWN_VERSIONS = [3];
// What the first two lines of a session file say, from its first bytes only (message bodies are never read):
// {title, version, cwd, empty}. version / cwd come from the header (null when there is none or it does not parse: unknown format);
// empty = nothing after the title and header lines. buf = the file's first bytes, size = the whole file.
export function ompHead(buf, size) {
  const rec = (a, b) => { try { const v = JSON.parse(buf.toString('utf8', a, b)); return v && typeof v === 'object' ? v : null; } catch { return null; } };
  const out = (header, title, end) => ({
    title: title ? Array.from(cleanLine(title)).slice(0, OMP_TITLE_CHARS).join('').trim() : '',
    version: header?.type === 'session' && Number.isInteger(header.version) ? header.version : null,
    cwd: header?.type === 'session' ? str(header.cwd) : null,
    empty: !(size > end + 1),
  });
  const i1 = buf.indexOf(10);
  if (i1 < 0) return { title: '', version: null, cwd: null, empty: true }; // not even one whole line yet
  const first = rec(0, i1);
  if (first?.type === 'session') return out(first, str(first.title), i1);
  if (first?.type !== 'title') return { title: '', version: null, cwd: null, empty: false };
  let i2 = buf.indexOf(10, i1 + 1);
  if (i2 < 0 && size <= buf.length) i2 = buf.length; // a header with no newline after it: the file ends there
  if (i2 < 0) return { title: '', version: null, cwd: null, empty: false }; // the header line is longer than what was read
  const header = rec(i1 + 1, i2);
  return out(header, str(first.title) ?? (header?.type === 'session' ? str(header.title) : null), i2);
}
async function readStart(file, n) {
  let fh;
  try {
    fh = await fs.promises.open(file, 'r');
    const buf = Buffer.alloc(n);
    const { bytesRead } = await fh.read(buf, 0, n, 0);
    return buf.subarray(0, bytesRead);
  } catch { return null; } finally { await fh?.close().catch(() => {}); }
}
// instabox ls --json -> Map box name -> {state, updatedAt}; state running|suspended|stopped|starting, anything else "unknown".
// A box asked to run that is not running yet counts as starting.
const STAGING_STATES = ['running', 'suspended', 'stopped', 'starting'];
export function parseStaging(list) {
  const out = new Map();
  for (const b of Array.isArray(list) ? list : []) {
    if (typeof b?.name !== 'string') continue;
    const s = typeof b.state === 'string' ? b.state : '';
    out.set(b.name, { state: b.desiredState === 'running' && s !== 'running' ? 'starting' : STAGING_STATES.includes(s) ? s : 'unknown', updatedAt: isoOf(b.updatedAt) });
  }
  return out;
}
// the box's own record in `instabox ls --json` (by name or id) -> the numbers the ring needs, or null: no such box, no run, or no max run (-1 unlimited)
export function boxOf(list, names) {
  const r = (Array.isArray(list) ? list : []).find((b) => b && typeof b === 'object' && (names.includes(b.name) || names.includes(b.id)));
  const run = Date.parse(r?.runStartedAt), cool = Date.parse(r?.cooldownUntil);
  const pos = (v) => typeof v === 'number' && v > 0;
  if (!(run > 0) || !pos(r.maxRunMinutes)) return null;
  return { state: r.state, runStartedAt: run, maxRunMinutes: r.maxRunMinutes, cooldownUntil: cool > 0 ? cool : null, cooldownMinutes: pos(r.cooldownMinutes) ? r.cooldownMinutes : BOX.cooldownMinutes,
    idlePauseMinutes: pos(r.autoSuspendAfterSeconds) ? r.autoSuspendAfterSeconds / 60 : BOX.idlePauseMinutes };
}
// the instabox key reaches the service through start.sh; the server keeps it in memory and takes it out of its own environment, so the
// tmux server and every harness session it starts never inherit it
function takeInstaboxKey() {
  const k = process.env.INSTABOX_API_KEY;
  delete process.env.INSTABOX_API_KEY;
  return typeof k === 'string' && k.trim() ? k.trim() : null;
}
const STAGING_TTL = 30e3, STAGING_START_MS = 60e3, GUARD_TTL = 10 * 60e3, GUARD_SCAN = 20, GUARD_YOUNG_MS = 30e3;
const GIT_SYNC_MS = 8e3; // openFresh: how long fcode-git-sync may take before the new session is made anyway (fcode-new and the app wait 20 s in all)
// Stale-while-revalidate, one refresh at a time. get(wait): a value younger than ttl as is; an older one at once while a refresh
// runs in the background. With no value yet, or after clear(), the refresh is waited for at most `wait` ms; then the old value
// (fresh: false) or, with none, a throw, and the refresh carries on. fresh is false while the last refresh failed. A failed
// refresh is retried only `retry` ms later, not on every poll. clear() also drops a refresh started before it (its result is old).
// Every answer carries `at`, when the refresh behind the value started; fresh is never true for a refresh that clear() dropped.
export function memo(ttl, fn, now, retry = ttl, ttlOf = () => undefined) {
  let value, vttl = ttl, at = -Infinity, failedAt = -Infinity, ok = true, cleared = false, pending = null, gen = 0;
  const refresh = () => {
    if (pending) return pending;
    const g = gen, started = now(); // the value is as old as the moment its refresh started
    const p = Promise.resolve().then(fn).then((v) => {
      const kept = g === gen;
      if (kept) { value = v; vttl = ttlOf(v) ?? ttl; at = started; ok = true; cleared = false; }
      return { v, kept, started };
    },
      (e) => { if (g === gen) { failedAt = now(); ok = false; } throw e; });
    pending = p;
    p.catch(() => {}).finally(() => { if (pending === p) pending = null; });
    return p;
  };
  const old = (e) => { if (value === undefined) throw e; return { value, fresh: false, at }; };
  const settle = async (wait) => { // join the one refresh (start it when none runs) and wait for it at most `wait` ms
    const p = refresh();
    let timer;
    try {
      const r = await (Number.isFinite(wait) ? Promise.race([p, new Promise((_, rej) => { timer = setTimeout(rej, wait, new Error('timeout')); })]) : p);
      return r.kept ? { value: r.v, fresh: true, at: r.started } : { value: r.v, fresh: false, at: -Infinity }; // dropped: of no age
    } catch (e) { return old(e); } finally { clearTimeout(timer); }
  };
  return {
    async get(wait = Infinity) {
      const t = now();
      if (value !== undefined && t - at < vttl) return { value, fresh: ok, at };
      const backoff = t - failedAt < retry;
      if (value !== undefined && !cleared) { if (!backoff) refresh(); return { value, fresh: ok && !backoff, at }; }
      if (backoff) return old(new Error('failed recently'));
      return settle(wait);
    },
    // fresh(wait, minAge): like get, but a value older than minAge ms is refreshed now and waited for (at most `wait` ms) instead of served
    // stale; a refresh that fails or runs past `wait` gives the old value with fresh: false. A value younger than minAge is not redone,
    // nor is a refresh that failed less than minAge ago: a burst of calls does not hammer the source.
    async fresh(wait, minAge) {
      const t = now();
      if (value !== undefined && ok && t - at < minAge) return { value, fresh: true, at };
      if (!ok && t - failedAt < minAge) return old(new Error('failed recently'));
      return settle(wait);
    },
    clear() { at = -Infinity; failedAt = -Infinity; cleared = true; gen++; pending = null; },
    settled: () => Promise.resolve(pending).catch(() => {}), // the refresh running now, if any, has ended
    at: () => at, // when the stored value's refresh started (-Infinity: none)
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
  const bodyMs = opts.bodyMs ?? BODY_MS, uploadRequestMs = opts.uploadRequestMs ?? UPLOAD_REQUEST_MS; // tests only: shorter bounds
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
  const gitSyncFile = opts.gitSyncFile ?? path.join(home, '.local', 'state', 'fcode', 'git-sync.json');
  const gitSyncMs = opts.gitSyncMs ?? GIT_SYNC_MS;
  const ompRoot = opts.ompSessionsRoot ?? path.join(process.env.PI_CODING_AGENT_DIR || path.join(home, '.omp', 'agent'), 'sessions');
  const instaboxSpec = specOf(opts.instabox ?? process.env.PC_INSTABOX ?? 'instabox');
  const instaboxKey = opts.instaboxKey !== undefined ? opts.instaboxKey : takeInstaboxKey(); // null: no key, staging is off

  secureConfigDir(configDir);

  // --- config: invalid at startup -> throw (exit 1); invalid on reload -> keep the previous one ---
  const cfgFile = path.join(configDir, 'config.json');
  const stampOf = () => { try { const s = fs.statSync(cfgFile); return `${s.mtimeMs}:${s.size}:${s.ino}`; } catch { return ''; } };
  let cfgStamp = stampOf();
  let projectsDirty = false; // the project list changed: the next /api/home answers at once from the cache and refreshes in the background
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
        if (JSON.stringify(next.projects) !== JSON.stringify(cfg.projects)) { projects.clear(); projectsDirty = true; } // a project added or removed: the home list is read again
        cfg = next;
        if (rotated) { gen++; pendings = []; load([]); purge(); return; } // no old keyHash may match any more
      }
    }
    if (purgePending && (force || changed || now() - purgeAt >= 1000)) purge();
  }
  const keyOf = (token) => crypto.createHmac('sha256', cfg.secret).update(token).digest('hex');
  // ctx = {cancelled, device, gen}: the request is alive, its device still paired, the config generation unchanged
  // ctx.admin (the local admin socket, no device): the same checks without the device
  function valid(ctx) {
    refreshConfig();
    return !ctx.cancelled && ctx.gen === gen && !purgePending && (ctx.admin || (!!ctx.device && devices.has(ctx.device)));
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
  // {appLink, shareLink} from cfg.publicOrigin (publicUrl as the app accepts it) only; null when it is not configured or not usable. Never a code, a name or anything from a request:
  // a link can be intercepted (the fcode scheme is not exclusive), so the user types the code.
  function pairLinks() {
    const o = cfg.publicOrigin;
    return o ? { appLink: `fcode://pair?server=${encodeURIComponent(o)}`, shareLink: `${o}/pair` } : null;
  }
  async function admin(req, ctx) { // an exception must never leave the socket callback: it would take the server down
    try { return await adminCmd(req, ctx); } catch (e) { log(`admin request failed: ${e.code || e.name}`); return { ok: false, error: 'internal' }; }
  }
  async function adminCmd(req, ctx) {
    refreshConfig(true); // a rotation or a pending purge is handled before any answer
    if (req?.cmd === 'pair') {
      if (req.links && cfg.publicUrl && !cfg.publicOrigin) return { ok: false, error: 'public_url_invalid' }; // no code is made for a QR that cannot work
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
    if (req?.cmd === 'meta') return { ok: true, projects: cfg.projectNames, harnesses: FCODE_NEW_HARNESSES };
    if (req?.cmd === 'new') { // fcode-new: the same new session as the app's "+" (openFresh), without a paired device
      if (!validProject(req.project)) return { ok: false, error: 'unknown_project' };
      if (!FCODE_NEW_HARNESSES.includes(req.harness)) return { ok: false, error: 'unknown_harness' };
      ctx.gen = gen; // after refreshConfig above: a rotation just handled is not a stale generation
      try { return { ok: true, name: await openFresh(req.project, req.harness, ctx) }; }
      catch (e) { return { ok: false, error: e instanceof HttpErr ? e.code : 'internal' }; }
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
      sock.setTimeout(ADMIN_JOB_MS); // a new session waits for the mutation queue and the harness check
      let req; try { req = JSON.parse(buf.slice(0, i)); } catch { req = null; }
      // the client gone (timeout, Ctrl+C) before the reply: a queued new session is dropped, as for an HTTP request that closes
      const ctx = { cancelled: false, device: null, gen: -1, admin: true };
      let replied = false; // not sock.writableFinished: a peer that left has already ended our side too
      sock.on('close', () => { if (!replied) { ctx.cancelled = true; ctx.onCancel?.(); } });
      admin(req, ctx).then((r) => { replied = true; sock.end(`${JSON.stringify(r)}\n`); });
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
  async function createSession(name, project, harness, ctx, command = HARNESSES[harness]) {
    try {
      await run(ctx, ['new-session', '-d', '-s', name, '-c', cfg.projects[project], HARNESS_ENV + command]);
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

  // --- GET /api/overview: ONE read job; its tmux/git calls run up to OVERVIEW_PAR at a time, each child inside a read slot the job holds ---
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
    // the job holds its own read slot all along. fn over items, results in item order, min(OVERVIEW_PAR, items) at a time: for the length of
    // one phase it takes the extra slots that are free, never the last OVERVIEW_KEEP (two screen reads), and gives them back at the end of
    // the phase (listSessions runs on the own slot alone). Every child runs inside a slot, so MAX_READS still bounds the children in all,
    // and a busy server runs the job one child at a time as before. After an error no new item starts, the running ones end, then it is thrown.
    reads++; ctx.held = true;
    const each = async (items, fn) => {
      const out = new Array(items.length), want = Math.min(OVERVIEW_PAR, items.length);
      let got = 0, next = 0, err;
      while (1 + got < want && reads < MAX_READS - OVERVIEW_KEEP) { reads++; got++; }
      try {
        await Promise.all(Array.from({ length: Math.min(1 + got, items.length) }, async () => {
          while (!err && next < items.length) {
            const i = next++;
            try { out[i] = await fn(items[i]); } catch (e) { err ??= { e }; }
          }
        }));
      } finally { reads -= got; }
      if (err) throw err.e;
      return out;
    };
    try {
      const projects = await each(cfg.projectNames, async (name) => ({ name, ...(await gitInfo(cfg.projects[name], ctx)) }));
      const sessions = await each(await listSessions(ctx), async (x) => {
        let state = null, preview = null, menu = null; // nulls when this item fails
        try {
          const text = await run(ctx, ['capture-pane', '-p', '-J', '-t', pane(x.name)]); // the visible pane, no escapes
          ({ state, preview, menu } = summarize(text, x.activity, now()));
        } catch (e) { if (gateStop(e)) throw e; }
        return { ...x, state, preview, menu };
      });
      return { now: Math.floor(now() / 1000), projects, sessions };
    } finally { reads--; ctx.held = false; }
  }
  // the session name /api/open reuses for a project and harness
  const openName = (project, harness) => `${project}-${harness}`.toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-+/, '').slice(0, 32);
  // <base>, <base>-2, <base>-3, ...: always within the 32-char name limit (base is shortened, the suffix kept)
  const freshName = (base, n) => {
    if (n === 1) return base;
    const suffix = `-${n}`;
    return base.slice(0, 32 - suffix.length).replace(/-+$/, '') + suffix;
  };

  // `fcode-git-sync <project>` before a new session: it only fetches and refreshes the behind / ahead / dirty counts of the card (a single-project run never
  // fast-forwards; only the box's 5-minute timer may). This server never changes a checkout. Never blocks the open and is never killed: an open waits for it at most gitSyncMs, or
  // until the open is cancelled, then goes on; the child keeps running, detached and unref'd with its output ignored, and ends by its
  // own limits. One sync per project at a time: an open that arrives meanwhile joins it instead of starting another. A missing
  // command or a failure only log one line. ctx.onCancel is free until mutate takes it.
  const syncs = new Map(); // project -> {done, warned} while its fcode-git-sync runs
  function startSync(project, spec) {
    let over = false, finish;
    const s = { warned: false, done: new Promise((r) => { finish = r; }) };
    const end = (why) => {
      if (over) return;
      over = true;
      if (syncs.get(project) === s) syncs.delete(project);
      if (why) log(`git-sync ${project}: ${why}`);
      finish();
    };
    try {
      const [cmd, ...pre] = spec;
      const child = spawn(cmd, [...pre, project], { stdio: 'ignore', detached: true, windowsHide: true, env: toolEnv() });
      child.on('error', (e) => end(e.code === 'ENOENT' ? 'command not found' : 'cannot start'));
      child.on('exit', (code, sig) => end(code === 0 ? '' : `exit ${code ?? sig}`));
      child.unref();
    } catch { end('cannot start'); }
    return s;
  }
  function gitSync(project, ctx) {
    const spec = opts.gitSync === undefined ? ['fcode-git-sync'] : opts.gitSync; // null: none; else resolved on toolEnv()'s PATH (~/.local/bin first)
    if (!spec) return Promise.resolve();
    let s = syncs.get(project);
    if (!s) syncs.set(project, s = startSync(project, spec));
    return new Promise((resolve) => {
      let left = false, timer;
      const leave = (why) => {
        if (left) return;
        left = true; clearTimeout(timer);
        if (ctx.onCancel === cancel) ctx.onCancel = undefined;
        if (why && !s.warned) { s.warned = true; log(`git-sync ${project}: ${why}`); } // once per sync, not per waiting open
        resolve();
      };
      const cancel = () => leave();
      ctx.onCancel = cancel;
      timer = setTimeout(leave, gitSyncMs, `not finished after ${gitSyncMs / 1000} s, opening anyway`);
      s.done.then(() => leave());
    });
  }
  // always a new session (the app's "+", fcode-new): the name is picked and created in the same mutation job
  async function openFresh(project, harness, ctx) {
    const name = openName(project, harness);
    if (!NAME_RE.test(name)) throw new HttpErr(400, 'invalid');
    if (!valid(ctx)) throw gateErr(ctx);
    await gitSync(project, ctx); // outside the mutation job: it does not hold up other creates
    return mutate(ctx, async () => {
      const taken = new Set((await listSessions(ctx)).map((x) => x.name));
      for (let n = 1; n <= 1000; n++) {
        const cand = freshName(name, n);
        if (taken.has(cand)) continue;
        try { await createSession(cand, project, harness, ctx); return cand; } catch (e) { if (e.code !== 'exists') throw e; } // created outside us meanwhile
      }
      throw new HttpErr(409, 'exists');
    });
  }

  // --- omp sessions of a project (GET /api/projects/<name>/omp-sessions, POST .../<id>/resume) ---
  // the top-level session files (never the nested ones) of the project's encoded dir: [{name, id}]; none when the dir is missing
  async function ompFiles(dir) {
    let ents;
    try { ents = await fs.promises.readdir(dir, { withFileTypes: true }); } catch { return []; }
    return ents.flatMap((e) => { const id = e.isFile() ? ompIdOf(e.name) : null; return id ? [{ name: e.name, id }] : []; });
  }
  // newest 10 non-empty sessions: {id, title, updatedAt, origin}. Only the first bytes of a file and its .fcode-origin sidecar are read.
  async function ompSessions(project) {
    const dir = path.join(ompRoot, ompDirName(cfg.projects[project]));
    const files = [];
    for (const f of await ompFiles(dir)) {
      try { const st = await fs.promises.stat(path.join(dir, f.name)); files.push({ ...f, mtime: st.mtimeMs, size: st.size }); } catch {}
    }
    files.sort((a, b) => b.mtime - a.mtime || (a.name < b.name ? 1 : -1));
    const out = [];
    for (const f of files) {
      if (out.length >= OMP_LIST_MAX) break;
      const buf = await readStart(path.join(dir, f.name), Math.min(f.size, OMP_HEAD_BYTES));
      const head = buf && ompHead(buf, f.size);
      if (!head || head.empty || !KNOWN_VERSIONS.includes(head.version)) continue; // empty, or a format this server does not know: not offered
      const mark = await readStart(path.join(dir, `${f.name.slice(0, -6)}.fcode-origin`), 16); // laptop's sync marks what it copied here
      out.push({ id: f.id, title: head.title, updatedAt: iso(f.mtime), origin: mark?.toString('utf8').trim() === 'laptop' ? 'laptop' : 'box' });
    }
    return out;
  }
  // omp format guard: `omp --version` and the headers of the newest GUARD_SCAN sessions of every project dir under the sessions root.
  // formatOk = false when a header has a version outside KNOWN_VERSIONS (reason "unknown_version:<v>"), or is missing / unreadable in a
  // complete file (not empty, not modified in the last 30 s: reason "no_header"), or when a session whose header cwd is a configured project sits outside the project's encoded dir
  // (reason "dir_rule": omp changed how it names the dir). Checked at most every 10 min (the first one at start); a failed scan is
  // not an alarm (formatOk stays true, reason null).
  async function ompGuardScan() {
    const version = await execTool(ompSpec, ['--version'], 10e3).then((s) => /\d+(?:\.\d+)+\S*/.exec(s)?.[0] ?? (str(s)?.slice(0, 40) ?? null), () => null);
    const files = [];
    try {
      for (const d of await fs.promises.readdir(ompRoot, { withFileTypes: true })) {
        if (!d.isDirectory()) continue;
        const dir = path.join(ompRoot, d.name);
        for (const f of await ompFiles(dir)) {
          try { const st = await fs.promises.stat(path.join(dir, f.name)); files.push({ dir: d.name, file: path.join(dir, f.name), mtime: st.mtimeMs, size: st.size }); } catch {}
        }
      }
    } catch { return { version, formatOk: true, reason: null }; }
    files.sort((a, b) => b.mtime - a.mtime);
    const wanted = new Map(cfg.projectNames.map((p) => [path.resolve(cfg.projects[p]), p]));
    let reason = null;
    for (const f of files.slice(0, GUARD_SCAN)) {
      const buf = await readStart(f.file, Math.min(f.size, OMP_HEAD_BYTES));
      const head = buf && ompHead(buf, f.size);
      if (!head) continue;
      // no usable header in a file that is empty or younger than 30 s is one being created (or a crash leftover): not an alarm
      if (head.version === null && (head.empty || now() - f.mtime < GUARD_YOUNG_MS)) continue;
      if (head.version === null) reason ??= 'no_header';
      else if (!KNOWN_VERSIONS.includes(head.version)) reason ??= `unknown_version:${head.version}`;
      else if (head.cwd && wanted.has(path.resolve(head.cwd)) && ompDirName(head.cwd) !== f.dir) reason ??= 'dir_rule';
    }
    return { version, formatOk: reason === null, reason };
  }
  const ompGuard = memo(GUARD_TTL, ompGuardScan, now);
  ompGuard.get().catch(() => {}); // at start, in the background
  // "<project>-omp-r-<last 8 of the id>": omp ids are UUIDv7, whose first 8 digits are a timestamp (65 s steps), the last 8 are random.
  // The project part is shortened, never the id part, so the name stays within 32 characters
  const resumeName = (project, id) => {
    const tail = `omp-r-${id.slice(-8)}`.replace(/[^a-z0-9-]+/g, '-');
    const base = project.toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-+/, '').slice(0, 32 - tail.length - 1).replace(/-+$/, '');
    return base ? `${base}-${tail}` : tail;
  };
  // runs inside a mutation job: `omp -r <id>` launched like the omp harness; a session of that name from an earlier resume is reused
  async function resumeOmp(project, id, ctx) {
    const name = resumeName(project, id);
    if (!NAME_RE.test(name)) throw new HttpErr(400, 'invalid');
    const old = (await listSessions(ctx)).find((x) => x.name === name);
    if (old) {
      if (old.project !== project || old.harness !== 'omp') throw new HttpErr(409, 'exists');
      return name;
    }
    await createSession(name, project, 'omp', ctx, `${HARNESSES.omp} -r ${shq(id)}`);
    return name;
  }

  // --- staging box: `instabox ls --json` (30 s) and `instabox start <box> --no-wait`, box name = project name ---
  // The same listing also holds this box's own record (.box: the real run start and max run for the home ring, see boxInfo). The box is
  // told by its hostname "instabox-<name>" (or the plain name), PC_BOX_NAME / opts.boxName overriding it; not listed: .box is null.
  const hostName = String(opts.boxName ?? process.env.PC_BOX_NAME ?? os.hostname());
  const boxNames = [hostName, hostName.replace(/^instabox-/, '')];
  const lsBoxes = async () => {
    const list = JSON.parse(await execTool(instaboxSpec, ['ls', '--json'], 15e3, { ...toolEnv(), INSTABOX_API_KEY: instaboxKey }));
    return Object.assign(parseStaging(list), { box: boxOf(list, boxNames) });
  };
  const staging = memo(STAGING_TTL, lsBoxes, now);
  const startingBoxes = new Set(); // projects whose `instabox start` runs now
  // detached and unref'd with its output ignored; a failure only logs one line (never the key)
  function startBox(project) {
    startingBoxes.add(project);
    let over = false;
    const end = (why) => { if (over) return; over = true; startingBoxes.delete(project); staging.clear(); if (why) log(`staging-start ${project}: ${why}`); };
    try {
      const [cmd, ...pre] = instaboxSpec;
      const child = spawn(cmd, [...pre, 'start', project, '--no-wait'], { stdio: 'ignore', detached: true, windowsHide: true, timeout: STAGING_START_MS,
        env: { ...toolEnv(), INSTABOX_API_KEY: instaboxKey } });
      child.on('error', (e) => end(e.code === 'ENOENT' ? 'command not found' : 'cannot start'));
      child.on('exit', (code, sig) => end(code === 0 ? '' : `exit ${code ?? sig}`));
      child.unref();
    } catch { end('cannot start'); }
  }

  // bracketed paste into the session's input (tmux buffer "pc"); runs inside a mutation job
  async function pasteText(name, text, ctx) {
    await run(ctx, ['load-buffer', '-b', 'pc', '-'], text);
    try { await run(ctx, ['paste-buffer', '-p', '-d', '-b', 'pc', '-t', pane(name)]); }
    catch (e) { await run(ctx, ['delete-buffer', '-b', 'pc']).catch(() => {}); throw e; }
  }
  // runs inside a mutation job; every step re-checks through run(ctx)
  async function sendText(name, text, enter, ctx) {
    text = text.replace(/\r\n?/g, '\n');
    if (text && (text.includes('\n') || Buffer.byteLength(text) > LONG_TEXT)) {
      await pasteText(name, text, ctx);
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
  const freshMin = opts.freshMinMs ?? FRESH_MIN_MS, freshWait = opts.homeFreshWaitMs ?? HOME_FRESH_WAIT_MS; // tests only: shorter bounds
  const homeWait = opts.homeWaitMs ?? HOME_WAIT_MS, resetReplyMs = opts.resetReplyMs ?? RESET_REPLY_MS, resetTimeout = opts.resetTimeoutMs ?? RESET_TIMEOUT;
  // Two parts, each its own memo: the quota (`omp usage --json`, 60 s) and the reset listing (`omp usage reset --json`: credential ids, reset
  // counts and targets, 5 min, the last good listing is kept on a failure). The accounts of a reply are built from both when the reply is made
  // (accountsOf), so a slow or failing listing never holds back or ages the usage numbers, and a listing that lands shows at the next reply.
  const listing = memo(LISTING_TTL, async () => JSON.parse(await execTool(ompSpec, ['usage', 'reset', '--json'], 30e3)), now, QUOTA_TTL);
  const quota = memo(QUOTA_TTL, async () => {
    const usage = JSON.parse(await execTool(ompSpec, ['usage', '--json'], 30e3));
    return { usage, at: now() }; // the raw report and when it was read (its accounts are stale by that clock)
  }, now, QUOTA_TTL);
  // After a reset the reset counts must come from a listing fetched after it: a kept listing whose refresh started at or after lastResetAt.
  // While the stored listing is older (slow, failed, or a refresh dropped by a later reset) the accounts are marked stale: true. A stored
  // listing started at or after lastResetAt stays trusted even when a later listing refresh fails (as when no reset ever happened).
  // No listing at all (slow or failed first listing): `~` ids and no reset target.
  let lastResetAt = -Infinity;
  // qv, lv: the answers of quota.get / listing.get (lv null: no listing yet) -> {accounts, byAccountId}
  function accountsOf(qv, lv) {
    const { accounts, byAccountId } = parseQuota(qv.value.usage, lv?.value ?? null, qv.value.at);
    const afterReset = lastResetAt > -Infinity && !(lv && lv.at >= lastResetAt);
    return { accounts: accounts.map((a) => ({ ...a, stale: a.stale || afterReset || !qv.fresh })), byAccountId };
  }
  const scan = spendScanner(spendRoots, now);
  const spend = memo(SPEND_TTL, scan, now);
  // Generic deploy gate (decision-r4 §4.4). A gate project = its repo is in gate-repos.json (a JSON array of "owner/repo", added the first
  // time the context is seen on any sha, never removed), else .fcode/deploy.json exists on the head (answer kept 10 min). The default
  // branch head is resolved once per refresh and used for both reads. undefined: not a gate project (the Actions rule); null: a gate
  // project whose status could not be read; else the lastRun.
  const gateFile = path.join(configDir, 'gate-repos.json');
  const gateRepos = new Set();
  try { for (const r of JSON.parse(fs.readFileSync(gateFile, 'utf8'))) if (typeof r === 'string') gateRepos.add(r.toLowerCase()); } catch {}
  const gateConfig = new Map(); // repo -> {at, has}
  const ghApi = (...a) => execTool(ghSpec, ['api', ...a], 20e3);
  async function gateLastRun(repo) {
    const key = repo.toLowerCase();
    const c = gateConfig.get(key);
    const seen = c && now() - c.at < GATE_CONFIG_TTL ? c : null;
    if (!gateRepos.has(key) && seen && !seen.has) return undefined; // no config on the head a moment ago
    let gate = gateRepos.has(key) || !!seen?.has;
    try {
      const sha = (await ghApi(`repos/${repo}/commits/HEAD`, '--jq', '.sha')).trim();
      if (!/^[0-9a-f]{40}$/.test(sha)) throw new Error('no head');
      if (!gate) {
        let has = true;
        await ghApi(`repos/${repo}/contents/.fcode/deploy.json?ref=${sha}`, '--silent').catch((e) => { if (e.killed || !/HTTP 404/.test(e.stderr ?? '')) throw e; has = false; });
        gateConfig.set(key, { at: now(), has });
        if (!has) return undefined;
        gate = true;
      }
      const e = gateStatusOf(await ghApi(`repos/${repo}/commits/${sha}/statuses?per_page=100`, '--paginate', '--jq', '.[] | [.context, .description, .created_at, .target_url] | @json'));
      if (e && !gateRepos.has(key)) { // stays a gate project from now on, whatever happens to its config; a failed write is retried at the next refresh
        try { writeFile(gateFile, JSON.stringify([...gateRepos, key].sort())); gateRepos.add(key); } catch (er) { if (er.committed) gateRepos.add(key); }
      }
      return gateRunOf(e);
    } catch { return gate ? null : undefined; }
  }
  async function projectInfo(name) {
    const dir = cfg.projects[name];
    const out = { name, repo: null, branch: null, prs: null, lastRun: null };
    const git = (...a) => execTool(gitSpec, ['-C', dir, '-c', 'core.fsmonitor=false', ...a], 5000).then((s) => s.trim(), () => null);
    const ghRaw = (...a) => execTool(ghSpec, ['-R', out.repo, ...a], 20e3).then(JSON.parse);
    const gh = (...a) => ghRaw(...a).catch(() => null); // failed or not JSON: null
    const [url, br] = await Promise.all([git('remote', 'get-url', 'origin'), git('rev-parse', '--abbrev-ref', 'HEAD')]);
    out.branch = br ? clip(cleanLine(br)) || null : null;
    out.repo = repoOf(url); // the remote URL itself (it may hold credentials) never leaves this function
    if (!out.repo) return out;
    const runList = (limit, ...a) => gh('run', 'list', '--limit', String(limit), '--json', 'workflowDatabaseId,workflowName,name,status,conclusion,createdAt,url,headSha', ...a);
    const prList = (fields) => gh('pr', 'list', '--state', 'open', '--limit', '20', '--json', fields);
    const [prs, runs, workflows, gate] = await Promise.all([
      // a token without checks access fails the whole query with statusCheckRollup (a GraphQL "not accessible" error or an HTTP 403):
      // then the list without it, and the checks come from the Actions runs of each head SHA; a timeout or any other failure is not retried
      ghRaw('pr', 'list', '--state', 'open', '--limit', '20', '--json', 'number,title,mergeable,headRefOid,statusCheckRollup')
        .catch((e) => (!e.killed && !/rate limit/i.test(e.stderr ?? '') && /not accessible|permission|scope|403|forbidden/i.test(e.stderr ?? '') ? prList('number,title,mergeable,headRefOid') : null)),
      runList(RUN_WINDOW), // one list: the deploy line and the PR checks
      gh('workflow', 'list', '--all', '--json', 'id,name,path'), // a deploy workflow is also known by its file path (--all: a disabled one too)
      gateLastRun(out.repo), // never rejects
    ]);
    out.prs = Array.isArray(prs) ? prsOf(prs, runs) : null;
    if (gate !== undefined) { out.lastRun = gate; return out; } // a gate project: the commit status, not the Actions runs
    out.lastRun = deployRunOf(runs, workflows);
    if (!out.lastRun && Array.isArray(runs) && runs.length >= RUN_WINDOW) { // window full: a deploy run may be older than all of it
      const old = await Promise.all(deployWorkflows(workflows).filter((w) => w.id != null).map((w) => runList(1, '--workflow', String(w.id))));
      out.lastRun = runOf(old.flat().filter(Boolean).sort((a, b) => (a.createdAt < b.createdAt) - (a.createdAt > b.createdAt)));
    }
    // no deploy line and the Actions reads worked and the repo has no deploy workflow: its latest release (a failed read is "unknown", never a release)
    if (!out.lastRun && Array.isArray(runs) && Array.isArray(workflows) && !deployWorkflows(workflows).length) out.lastRun = releaseRunOf(await gh('release', 'list', '--limit', '10', '--exclude-drafts', '--exclude-pre-releases', '--json', 'tagName,publishedAt,isLatest'), out.repo);
    return out;
  }
  const projects = memo(PROJECTS_TTL, () => Promise.all(cfg.projectNames.map(projectInfo)), now);
  // box timer (estimate, no API key): the last resume = a 30 s tick that came more than 90 s late, or the start of a box run.
  // {resume, tick, boot} is kept in box-timer.json on every 30 s tick, so a server restart (reinstall, crash, systemctl restart)
  // within 90 s of the last tick, on the same boot, keeps the run's resume. An older or missing file means the box was asleep or
  // stopped; another boot (Linux boot_id; null where there is none) is a reboot: both are a new run (resume = now).
  // An instabox pause keeps the boot_id, so the 90 s tick gap is what catches it.
  const boxFile = path.join(configDir, 'box-timer.json');
  let boot = null;
  try { boot = fs.readFileSync(opts.bootIdFile ?? '/proc/sys/kernel/random/boot_id', 'utf8').trim() || null; } catch {}
  let boxResume = now(), boxTick = now();
  try {
    const b = JSON.parse(fs.readFileSync(boxFile, 'utf8'));
    const age = boxTick - b?.tick;
    if (Number.isFinite(b?.resume) && Number.isFinite(b?.tick) && b.resume <= b.tick && age >= 0 && age < BOX_GAP_MS
      && (b.boot ?? null) === boot) boxResume = b.resume;
  } catch {} // no file or a bad one: a new run
  const tick = () => { const t = now(); if (t - boxTick > BOX_GAP_MS) boxResume = t; boxTick = t; };
  const tickBox = () => { // the 30 s tick: also stored (a failed write only loses the restart memory)
    tick();
    try { writeFile(boxFile, JSON.stringify({ resume: boxResume, tick: boxTick, boot })); } catch {}
  };
  tickBox();
  const boxTimer = setInterval(tickBox, BOX_TICK_MS);
  boxTimer.unref();
  // from boot every part is kept warm: one check per tick, and get(0) starts a refresh only for a part past its own TTL (and not in its
  // retry wait), through the memo, so a part is never refreshed twice at once; /api/home then answers from memory
  const warmTick = opts.warmTickMs ?? WARM_TICK_MS;
  let warmTimer = null;
  const warmUp = () => {
    for (const m of [quota, listing, spend, projects, ...(instaboxKey ? [staging] : [])]) m.get(0).catch(() => {});
  };
  function startWarm() {
    if (warmTimer || !(warmTick > 0)) return;
    warmUp();
    warmTimer = setInterval(warmUp, warmTick);
    warmTimer.unref();
  }
  // rec: this box's record from the cached `instabox ls` (staging part: stale-while-revalidate, never waited for here) with the time it was read.
  // instabox's own numbers win: sleeps at runStartedAt + maxRunMinutes (a paused box: its cooldownUntil is the wake, which the app reads as
  // sleepsAt + cooldown). A record read before the last resume (a tick gap) or older than BOX_REC_MS is not used: the estimate answers until a new one lands.
  let boxNums = BOX; // maxRun / idle pause / cooldown of the estimate: the last record's, so a lapsed record does not change them
  function boxInfo(rec) {
    tick();
    const t = now();
    const ib = rec?.box && rec.at >= boxResume && t - rec.at < BOX_REC_MS ? rec.box : null;
    if (ib) {
      const cool = ib.cooldownMinutes * 60e3;
      const paused = ib.state !== 'running' && ib.cooldownUntil > t;
      // the estimate follows the known run start (tickBox stores it too): it stays right when the record lapses and never restarts against a live run
      if (!paused && ib.runStartedAt <= t) boxResume = ib.runStartedAt;
      boxNums = { maxRunMinutes: ib.maxRunMinutes, idlePauseMinutes: ib.idlePauseMinutes, cooldownMinutes: ib.cooldownMinutes };
      const at = paused ? ib.cooldownUntil - cool : ib.runStartedAt + ib.maxRunMinutes * 60e3;
      return { state: 'running', sleepsAt: paused || at > t ? iso(at) : null, ...boxNums, source: 'instabox' };
    }
    const maxMs = boxNums.maxRunMinutes * 60e3;
    let at = boxResume + maxMs;
    // We are answering this request, so the box runs. An estimate already past its sleep time plus a whole cooldown is wrong (a pause the
    // tick gap did not catch): the run starts again now, or the ring stays at "--:--" for good.
    if (t > at + boxNums.cooldownMinutes * 60e3) { boxResume = t; at = t + maxMs; }
    return { state: 'running', sleepsAt: at > t ? iso(at) : null, ...boxNums, source: 'estimate' };
  }
  // fresh (?fresh=1): each part older than freshMin is read again now and waited for, freshWait at most; else as the cache holds it
  async function homeView(fresh = false) {
    // each part answers at once from its cache, or within homeWait the first time; a part not ready is empty and fills later
    // right after a project was added or removed the cached list is not waited for (wait 0: the reply is at once, the refresh runs on)
    const projWait = projectsDirty ? 0 : homeWait; projectsDirty = false;
    const part = (m, wait) => (fresh ? m.fresh(freshWait, freshMin) : m.get(wait));
    // the listing is waited for half as long as the quota when it has no value yet (a slow first listing: `~` ids, filled in at a later reply)
    const [q, l, s, p, b, g] = await Promise.allSettled([part(quota, homeWait), part(listing, homeWait / 2), part(spend, homeWait), part(projects, projWait),
      instaboxKey ? part(staging, homeWait) : Promise.reject(new Error('no instabox key')), part(ompGuard, homeWait)]);
    const boxes = b.status === 'fulfilled' ? b.value.value : null; // no key, or instabox failed with nothing cached: every staging is null
    const t = now();
    const qv = q.status === 'fulfilled' ? q.value : null;
    const { accounts, byAccountId } = qv ? accountsOf(qv, l.status === 'fulfilled' ? l.value : null) : { accounts: [], byAccountId: new Map() };
    const view = s.status === 'fulfilled' ? spendView(s.value.value, accounts, byAccountId, t, cfg.timeZone) : null;
    let updates = {};
    try { updates = parseUpdates(fs.readFileSync(updatesFile, 'utf8')); } catch {}
    let gits = new Map(); // read once per home reply; the projects part is cached, this is not
    try { gits = parseGitSync(fs.readFileSync(gitSyncFile, 'utf8')); } catch {}
    const withGit = (list) => list.map((x) => ({ ...x, git: gits.get(x.name) ?? NO_GIT, staging: boxes?.get(x.name) ?? null }));
    const cachedProjects = new Map((p.status === 'fulfilled' ? p.value.value : []).map((x) => [x.name, x]));
    return {
      generatedAt: iso(t), box: boxInfo(b.status === 'fulfilled' ? { box: b.value.value.box, at: b.value.at } : null),
      accounts: accounts.map((a) => ({ ...a, spend: view?.perAccount.get(a.id) ?? null })),
      totals: view?.totals ?? { spend: null, byHarness: [] },
      // not read yet (first request, slow gh): each project with nothing known and loading: true (a gh failure has no loading)
      // in config order, each project from the cache by name (a stale list still serves the ones it knows), a new one as a loading placeholder
      projects: withGit(cfg.projectNames.map((name) => cachedProjects.get(name) ?? { name, repo: null, branch: null, prs: null, lastRun: null, loading: true })),
      updates,
      omp: g.status === 'fulfilled' ? g.value.value : { version: null, formatOk: true, reason: null }, // not scanned yet: no alarm
    };
  }
  // POST /api/codex-reset: one reset per account at a time; the same requestId joins a running reset, and a final answer
  // (RESET_FINAL) is kept 15 min for a retry with that id. An error is not kept: a retry runs omp again (omp fences its own spend).
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
      try {
        const [qv, lv] = await Promise.all([quota.get(homeWait), listing.get(homeWait / 2).catch(() => null)]);
        acct = accountsOf(qv, lv).accounts.find((a) => a.id === accountId);
      } catch { throw new HttpErr(503, 'unavailable'); }
      if (!acct) throw new HttpErr(404, 'unknown_account'); // not 'not_found', which an older server gives for the unknown route
      if (acct.harness !== 'codex') throw new HttpErr(400, 'not_allowed');
      if (!acct.resets.target) throw new HttpErr(409, 'no_target');
      let reply;
      try { reply = resetReply(await execTool(ompSpec, ['usage', 'reset', acct.resets.target], resetTimeout)); } catch (e) {
        // killed at the timeout: the redeem may have gone out, so "not confirmed", never "omp did not run"
        reply = e.killed ? { result: 'error', message: RESET_MSG.error } : e.code === 'ENOENT' ? { result: 'error', message: RESET_MSG.tool }
          : resetReply(`${e.stdout ?? ''}\n${e.stderr ?? ''}`);
      }
      log(`codex-reset ${accountId} ${reply.result}`); // the account id and the result only
      if (RESET_FINAL.includes(reply.result)) resetDone.set(doneKey, { at: now(), reply });
      lastResetAt = now(); listing.clear(); quota.clear(); // whatever omp answered, the next GET /api/home reads the counts again
      return reply;
    })();
    resetJobs.set(accountId, { requestId, promise: job });
    job.then(() => resetJobs.delete(accountId), () => resetJobs.delete(accountId));
    return job;
  }

  // --- POST /api/projects: the box script as a job (CONTRACT A11). argv only, never a shell; one running job per name; 10 min, then the
  // whole process group is killed; ended jobs are kept 30 min. Only the script's "R <CODE> [detail]" lines are read: its stderr is dropped,
  // and nothing but the name and the code is logged. FCODE_CFG points the script at THIS server's config.json. ---
  const addSpec = specOf(opts.addScript ?? process.env.PC_ADD_SCRIPT ?? ['bash', [ADD_SCRIPT, ADD_SCRIPT_DEV].find((f) => fs.existsSync(f)) ?? ADD_SCRIPT]);
  const addTimeout = opts.addTimeoutMs ?? (Number(process.env.PC_ADD_TIMEOUT_MS) || ADD_TIMEOUT_MS);
  // on Linux the script runs under timeout(1): the deadline then holds on its own even when this server is gone (a crash, or a restart that
  // leaves the job alone: install.sh uses KillMode=process); a graceful stop ends the jobs through close(). 124 maps to TIMEOUT; a kill-after kill ends as a signal.
  const addKillAfter = Number(process.env.PC_ADD_KILL_AFTER_S) || ADD_KILL_AFTER_S; // test-only override, like PC_ADD_TIMEOUT_MS
  const addWrap = process.platform === 'win32' ? [] : ['timeout', `--kill-after=${addKillAfter}`, String(addTimeout / 1000)];
  const addJobs = new Map(); // id -> job
  const addRunning = new Map(); // name -> its running job
  const addStops = new Set(); // one per running child: ends it when the app closes
  // ended jobs go after 30 min (checked on every submit and every poll); at most 50 are kept, the oldest finished first (a running one never)
  function pruneAdd() {
    for (const [k, j] of addJobs) if (j.state !== 'running' && now() - j.endedAt > ADD_KEEP_MS) addJobs.delete(k);
    const ended = [...addJobs.values()].filter((j) => j.state !== 'running').sort((a, b) => a.endedAt - b.endedAt);
    for (let over = addJobs.size - ADD_MAX_JOBS; over > 0 && ended.length; over--) addJobs.delete(ended.shift().id);
  }
  function startAdd(repo, name) {
    pruneAdd();
    const busy = addRunning.get(name);
    if (busy) return busy;
    const job = { id: crypto.randomBytes(16).toString('hex'), name, repo, state: 'running', code: null, detail: null, endedAt: 0 };
    addJobs.set(job.id, job); addRunning.set(name, job);
    pruneAdd();
    let out = '', child, timer, grace;
    const end = () => { clearTimeout(timer); addStops.delete(abort); };
    const abort = () => { end(); killGroup('SIGTERM'); clearTimeout(grace); }; // the app closes
    const finish = (res) => {
      if (job.state !== 'running') return;
      end();
      Object.assign(job, res, { endedAt: now() });
      if (res.pubkey) job.keyUrl = `https://github.com/${repo}/settings/keys/new`;
      addRunning.delete(name);
      log(`add-project ${name} ${job.code}`);
    };
    const killGroup = (sig) => { try { process.kill(process.platform === 'win32' ? child.pid : -child.pid, sig); } catch {} }; // -pid: the group
    try {
      const [cmd, ...pre] = [...addWrap, ...addSpec];
      child = spawn(cmd, [...pre, repo, name], { stdio: ['ignore', 'pipe', 'ignore'], detached: true, windowsHide: true, env: { ...toolEnv(), FCODE_CFG: cfgFile } });
    } catch { finish({ state: 'failed', code: 'FAILED' }); return job; }
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (c) => { if (out.length < ADD_OUT_MAX) out += c; });
    child.on('error', () => finish({ state: 'failed', code: 'FAILED' }));
    child.on('close', (code) => { clearTimeout(grace); finish(addOutcome(code, out)); }); // the job is gone: no late SIGKILL to a group id that may be reused
    timer = setTimeout(() => {
      finish({ state: 'failed', code: 'TIMEOUT' });
      killGroup('SIGTERM'); // the script cleans up its clone on TERM; on Linux timeout(1) kills what is left at +30 s, this backstop only at +45 s
      grace = setTimeout(() => killGroup('SIGKILL'), opts.addKillGraceMs ?? ADD_KILL_GRACE_MS); // opts.addKillGraceMs: tests
      grace.unref();
    }, addTimeout);
    addStops.add(abort);
    return job;
  }
  // GET /api/github/repos: what the box's gh login can see (the list is cached 60 s, one gh run at a time), with the project each repo is
  // already on the box as (onBox: read from each project's origin on every request, so a project just added shows at once)
  let ghList = null, ghPending = null; // {at, rows}
  const githubRepos = () => {
    if (ghList && now() - ghList.at < GH_LIST_MS) return Promise.resolve(ghList.rows);
    if (!ghPending) {
      const at = now();
      ghPending = (async () => {
        const rows = [];
        for (let page = 1; page <= GH_PAGES; page++) { // pages 1..3, stopping at a short page
          let n = 0;
          for (const l of (await execTool(ghSpec, ghReposArgs(page), 30e3)).split('\n')) {
            if (!l.trim()) continue;
            n++;
            let v; try { v = JSON.parse(l); } catch { continue; }
            if (v && typeof v.repo === 'string' && /^[\w.-]+\/[\w.-]+$/.test(v.repo)) {
              rows.push({ repo: v.repo, private: v.private === true, archived: v.archived === true, canPush: v.canPush === true, updatedAt: typeof v.updatedAt === 'string' ? iso(Date.parse(v.updatedAt)) : null });
            }
          }
          if (n < GH_PAGE_SIZE) break;
        }
        rows.sort((a, b) => (b.updatedAt ?? '').localeCompare(a.updatedAt ?? ''));
        ghList = { at, rows: rows.slice(0, GH_LIST_MAX) };
        return ghList.rows;
      })().finally(() => { ghPending = null; });
    }
    return ghPending;
  };
  async function boxRepos() { // lower-cased owner/name -> project name (the first project in config order)
    const urls = await Promise.all(cfg.projectNames.map((name) => execTool(gitSpec, ['-C', cfg.projects[name], 'remote', 'get-url', 'origin'], 5000).then((s) => s.trim(), () => null)));
    const m = new Map();
    cfg.projectNames.forEach((name, i) => { const r = repoOf(urls[i])?.toLowerCase(); if (r && !m.has(r)) m.set(r, name); });
    return m;
  }
  const addJob = (id) => { pruneAdd(); return addJobs.get(id); };

  // --- http helpers ---
  function json(res, status, obj, headers) {
    const body = JSON.stringify(obj);
    res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(body), ...headers });
    res.end(body);
  }
  function readBody(req) {
    return new Promise((resolve, reject) => {
      const chunks = []; let size = 0; let over = false; // the time bound is the per-request timer of the handler (ctx.cut)
      req.on('data', (c) => {
        size += c.length;
        if (size > BODY_LIMIT) { over = true; chunks.length = 0; if (size > 16 * BODY_LIMIT) req.destroy(); return; }
        if (!over) chunks.push(c);
      });
      req.on('end', () => { over ? reject(new HttpErr(413, 'too_large')) : resolve(Buffer.concat(chunks)); });
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

  // --- POST /api/projects/<name>/upload?session=<name> (CONTRACT A12) ---
  // the raw body, at most UPLOAD_LIMIT bytes: past it the 413 is answered at once, the bytes so far are dropped, and the
  // connection is closed after the answer (the rest of the body is never read, see the handler)
  function readUpload(req) {
    return new Promise((resolve, reject) => {
      const declared = req.headers['content-length'];
      if (declared !== undefined && Number(declared) > UPLOAD_LIMIT) return reject(new HttpErr(413, 'too_big'));
      const chunks = []; let size = 0;
      req.on('data', (c) => {
        size += c.length;
        if (size > UPLOAD_LIMIT) { chunks.length = 0; reject(new HttpErr(413, 'too_big')); return; }
        chunks.push(c);
      });
      req.on('end', () => resolve(Buffer.concat(chunks)));
      req.on('error', () => reject(new HttpErr(400, 'invalid')));
      req.on('close', () => reject(new HttpErr(499, 'cancelled'))); // no-op once settled
    });
  }
  // hides the upload folder from git without touching any file git or the laptop sync share: `.fcode/.gitignore` holds the single line `*`, which
  // ignores everything in the folder, the .gitignore itself included, in any repo above it. Written atomically (a part file in the same folder, then
  // rename, which replaces a link instead of following it); `fc` is `<project>/.fcode`, already checked to be a real folder. A link or a non-file
  // at `.gitignore` throws: the upload is refused (500 storage) like any other unsafe path.
  async function hideFromGitOnce(fc) {
    const file = path.join(fc, '.gitignore'), want = '*\n';
    let st = null;
    try { st = await fs.promises.lstat(file); } catch (e) { if (e.code !== 'ENOENT') throw e; }
    if (st) {
      if (!st.isFile()) throw new Error('not a file');
      if (st.size === want.length && await fs.promises.readFile(file, { encoding: 'utf8', flag: fs.constants.O_RDONLY | NOFOLLOW }) === want) return; // size first: a big file is never read
    }
    // a part file a crash left (exactly our name, a regular file, over 1 h old; a link is never followed or removed) goes first
    try {
      for (const n of await fs.promises.readdir(fc)) {
        if (!/^\.gitignore\.fcode-part-\d+-[0-9a-f]{6}$/.test(n)) continue;
        try { const f = path.join(fc, n), s = await fs.promises.lstat(f); if (s.isFile() && now() - s.mtimeMs > 3600e3) await fs.promises.unlink(f); } catch {}
      }
    } catch {}
    const part = `${file}.fcode-part-${process.pid}-${crypto.randomBytes(3).toString('hex')}`;
    let owned = false; // only a part file this call created is ever unlinked: an O_EXCL failure (EEXIST) leaves the other file alone
    try {
      const fh = await fs.promises.open(part, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | NOFOLLOW, 0o600);
      owned = true;
      try { await fh.writeFile(want); } finally { await fh.close(); }
      await fs.promises.rename(part, file);
    } catch (e) { if (owned) await fs.promises.unlink(part).catch(() => {}); throw e; }
  }
  // one at a time: two first uploads of a project must not both rename a part file over `.gitignore` (atomic on Linux; EPERM for the loser on
  // Windows). A failed run never poisons the chain; the caller gets this run's own result
  let hideChain = Promise.resolve();
  function hideFromGit(fc) { const p = hideChain.then(() => hideFromGitOnce(fc)); hideChain = p.catch(() => {}); return p; }
  // regular files named like our uploads and older than UPLOAD_KEEP_MS; anything else in the folder is left alone, a link is never followed.
  // Runs on upload only; one file failing never stops the rest.
  async function sweepUploads(up) {
    let names;
    try { names = await fs.promises.readdir(up); } catch { return; }
    for (const n of names) {
      if (!UPLOAD_NAME_RE.test(n)) continue;
      try {
        const f = path.join(up, n), st = await fs.promises.lstat(f);
        if (st.isFile() && now() - st.mtimeMs > UPLOAD_KEEP_MS) await fs.promises.unlink(f);
      } catch {}
    }
  }
  // the absolute path ALONE into the session's input, never Enter. claude, omp and unknown: bracketed paste; codex: one send-keys -l (a paste stays text there).
  // A path with whitespace or a quote is not attached. true only after tmux answered 0.
  // s = the session as it was when the upload was accepted. The body took time: inside the job, right before tmux, it must still be the same session
  // (same name, project, agent kind and creation time), else nothing is sent (the name may now belong to another project's session).
  async function attachPath(s, file, ctx) {
    if (/[\s'"]/.test(file)) return false;
    try {
      return await mutate(ctx, async () => {
        const cur = (await listSessions(ctx)).find((x) => x.name === s.name);
        if (!cur || cur.project !== s.project || cur.harness !== s.harness || cur.created !== s.created) return false;
        await (s.harness === 'codex' ? run(ctx, ['send-keys', '-t', pane(s.name), '-l', '--', file]) : pasteText(s.name, file, ctx));
        return true;
      });
    } catch (e) {
      if (gateStop(e)) throw e;
      return false;
    }
  }
  // admission first: at most UPLOAD_SLOTS in flight, counted before any body byte is read (the 429 reads nothing; the handler closes the connection
  // after every refused upload, so the unread body is never drained); the slot is freed in this one finally, on every way out
  let uploads = 0;
  async function upload(req, res, url, ctx, rawName) {
    if (req.method !== 'POST') throw new HttpErr(405, 'method');
    if (uploads >= UPLOAD_SLOTS) throw new HttpErr(429, 'busy');
    uploads++;
    try { return await storeUpload(req, res, url, ctx, rawName); } finally { uploads--; }
  }
  async function storeUpload(req, res, url, ctx, rawName) {
    // The client may be gone at any await below (ctx.cancelled is set by the response 'close' the handler registered before the first await; a
    // request destroyed by the timer is req.destroyed). Nothing would ever settle readUpload once the request has closed, so stop here instead.
    const alive = () => { if (ctx.cancelled || req.destroyed) throw new HttpErr(499, 'cancelled'); };
    let project = '';
    try { project = decodeURIComponent(rawName); } catch {}
    const dir = validProject(project) ? cfg.projects[project] : null;
    if (!dir || !(await fs.promises.stat(dir).then((s) => s.isDirectory(), () => false))) throw new HttpErr(404, 'no_project');
    alive();
    const type = UPLOAD_TYPES.get((req.headers['content-type'] || '').split(';')[0].trim().toLowerCase());
    if (!type) throw new HttpErr(415, 'bad_type');
    const session = url.searchParams.get('session'); // checked before anything is written
    let found = null;
    if (session !== null) {
      found = (await listSessions(ctx)).find((x) => x.name === session && x.project === project);
      alive();
      if (!found) throw new HttpErr(404, 'no_session');
    }
    ctx.cut(uploadRequestMs); // auth, CSRF, project, type, session and the slot are all in: only now the body gets the long window (else the short one of the handler)
    const buf = await readUpload(req);
    if (!valid(ctx)) throw gateErr(ctx); // the device may have been revoked while the body came in
    if (!buf.length) throw new HttpErr(400, 'empty');
    if (!buf.subarray(0, type.magic.length).equals(type.magic)) throw new HttpErr(415, 'bad_type');
    const up = path.join(dir, '.fcode', 'uploads');
    const stamp = new Date(now()).toISOString().replace(/[-:]/g, '').slice(0, 15).replace('T', '-'); // UTC: YYYYMMDD-HHMMSS
    let file;
    try {
      for (const d of [path.dirname(up), up]) { // one level at a time: a symlink in place of either is refused before anything is made through it
        await fs.promises.mkdir(d, { recursive: true, mode: 0o700 });
        if (!(await fs.promises.lstat(d)).isDirectory()) throw new Error('not a directory');
      }
      await hideFromGit(path.dirname(up));
      let fh;
      for (let i = 0; !fh; i++) {
        file = path.join(up, `${stamp}-${crypto.randomBytes(3).toString('hex')}.${type.ext}`);
        try { fh = await fs.promises.open(file, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | NOFOLLOW, 0o600); } catch (e) { if (e.code !== 'EEXIST' || i >= 4) throw e; }
      }
      try { await fh.writeFile(buf); } catch (e) { await fh.close(); await fs.promises.unlink(file).catch(() => {}); throw e; }
      await fh.close();
    } catch { throw new HttpErr(500, 'storage'); }
    await sweepUploads(up);
    return json(res, 200, { path: file, attached: found ? await attachPath(found, file, ctx) : false });
  }

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
    const um = UPLOAD_ROUTE.exec(pathname); // v1.3.3: reads its own raw body, so it must come before the 64 KB JSON readBody below
    if (um) return upload(req, res, url, ctx, um[1]);
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
      if (!cfg.publicOrigin) { log('pair-code refused: publicUrl is not a server address the app accepts'); throw new HttpErr(500, 'public_url_invalid'); }
      const p = newPairing(b.name, ctx.device);
      return json(res, 200, { code: p.code, expiresAt: new Date(p.expiresAt).toISOString(), ...pairLinks() });
    }
    if (pathname === '/api/overview') { want('GET'); return json(res, 200, await overview(ctx)); }
    if (pathname === '/api/home') { want('GET'); return json(res, 200, await homeView(url.searchParams.get('fresh') === '1')); }
    if (pathname === '/api/projects') {
      want('POST');
      const { repo, name } = parseAddRequest(parseJson(req, body));
      return json(res, 202, { job: startAdd(repo, name).id });
    }
    if (seg.length === 5 && seg[0] === '' && seg[1] === 'api' && seg[2] === 'projects' && seg[3] === 'jobs' && seg[4] !== 'omp-sessions') { // a project named "jobs" keeps its omp-sessions list (CONTRACT A9); a job id is hex, never that word
      want('GET');
      const j = addJob(seg[4]);
      if (!j) throw new HttpErr(404, 'no_job');
      return json(res, 200, { state: j.state, code: j.code, name: j.name, repo: j.repo, via: j.via ?? null, pubkey: j.pubkey, keyUrl: j.keyUrl, detail: j.detail });
    }
    if (pathname === '/api/github/repos') {
      want('GET');
      let rows;
      try { rows = await githubRepos(); } catch (e) {
        if (e.code === 'ENOENT' || e.code === 4 || /gh auth login|GH_TOKEN|not logged in|authentication required|HTTP 401|Bad credentials/i.test(e.stderr ?? '')) {
          log('github repos: no token'); return json(res, 200, { repos: [], reason: 'no_github_token' });
        }
        log('github repos: unavailable'); throw new HttpErr(502, 'github_unavailable');
      }
      const onBox = await boxRepos();
      return json(res, 200, { repos: rows.map((r) => ({ ...r, onBox: onBox.get(r.repo.toLowerCase()) ?? null })) });
    }
    if (pathname === '/api/codex-reset') {
      want('POST');
      const { accountId, requestId } = parseJson(req, body);
      if (typeof accountId !== 'string' || accountId.length > 128 || typeof requestId !== 'string' || !/^[A-Za-z0-9-]{8,64}$/.test(requestId)) throw new HttpErr(400, 'invalid');
      // omp may take up to 45 s (its own 10 s list + 15 s redeem, then our kill); the app gives up at 20 s, so a reset still
      // running after resetReplyMs is answered 202 pending and finishes in the background (it clears the quota cache when done)
      const job = codexReset(accountId, requestId);
      let timer;
      const reply = await Promise.race([job, new Promise((r) => { timer = setTimeout(r, resetReplyMs, null); })]).finally(() => clearTimeout(timer));
      return reply ? json(res, 200, reply) : json(res, 202, { result: 'pending', message: RESET_MSG.pending });
    }
    if (pathname === '/api/meta') {
      want('GET');
      return json(res, 200, { projects: cfg.projectNames, harnesses: Object.keys(HARNESSES), keys: KEYS });
    }
    if (pathname === '/api/prefs') { // CONTRACT A13: <configDir>/prefs.json, written whole and atomically; the code below is synchronous, so two PUTs never interleave and the last wins
      const file = path.join(configDir, 'prefs.json');
      if (method === 'GET') {
        let prefs = { order: [], aliases: {} };
        try { prefs = normalizePrefs(JSON.parse(fs.readFileSync(file, 'utf8')), cfg.projectNames, true); } catch {} // no file or not JSON: empty; an entry the project list outgrew is dropped alone
        return json(res, 200, prefs);
      }
      want('PUT');
      const prefs = normalizePrefs(parseJson(req, body), cfg.projectNames);
      try { writeFile(file, JSON.stringify(prefs)); } catch (e) { if (!e.committed) throw new HttpErr(500, 'storage'); } // renamed, only the directory fsync failed: saved
      return json(res, 200, prefs);
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
      const name = openName(project, harness);
      if (!NAME_RE.test(name)) throw new HttpErr(400, 'invalid');
      if (fresh) return json(res, 200, { name: await openFresh(project, harness, ctx), created: true }); // A5 update 4: always a new session
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

    // v1.3.2: /api/projects/<name>/omp-sessions, /api/projects/<name>/omp-sessions/<id>/resume, /api/projects/<name>/staging/start
    const pm = /^\/api\/projects\/([^/]+)\/(?:(omp-sessions)|omp-sessions\/([^/]+)\/(resume)|(staging)\/start)$/.exec(pathname);
    if (pm) {
      want(pm[2] ? 'GET' : 'POST');
      const unescape = (s) => { try { return decodeURIComponent(s); } catch { return ''; } };
      const project = unescape(pm[1]);
      const refuse = (status, error) => json(res, status, { ok: false, error });
      if (!validProject(project)) return refuse(404, 'unknown_project');
      if (pm[2]) return json(res, 200, { ok: true, sessions: await ompSessions(project) });
      if (pm[4]) { // resume
        const id = unescape(pm[3]);
        const dir = path.join(ompRoot, ompDirName(cfg.projects[project]));
        const file = OMP_ID_RE.test(id) ? (await ompFiles(dir)).find((f) => f.id === id) : null;
        const st = file && await fs.promises.stat(path.join(dir, file.name)).catch(() => null);
        if (!st) return refuse(404, 'unknown_session');
        const buf = await readStart(path.join(dir, file.name), Math.min(st.size, OMP_HEAD_BYTES));
        if (!buf || !KNOWN_VERSIONS.includes(ompHead(buf, st.size).version)) return refuse(409, 'unknown_format'); // the list never offers it either
        return json(res, 200, { ok: true, session: await mutate(ctx, () => resumeOmp(project, id, ctx)) });
      }
      // staging/start: only a box that `instabox ls` lists under the project's name; a running or starting one is left alone
      if (!instaboxKey) return refuse(409, 'no_instabox_key');
      let box;
      try { box = (await lsBoxes()).get(project); } catch { return refuse(503, 'staging_unavailable'); } // the state now (a fresh ls), never a cached one
      if (!box) return refuse(404, 'no_staging_box');
      if (box.state === 'running' || box.state === 'starting' || startingBoxes.has(project)) return json(res, 200, { ok: true, state: box.state === 'running' ? 'running' : 'starting' });
      startBox(project);
      return json(res, 200, { ok: true, state: 'starting' });
    }

    // /api/<verb>/<name>
    if (seg.length === 4 && seg[1] === 'api' && seg[0] === '' && ['sessions', 'screen', 'stream', 'send', 'key', 'resize'].includes(seg[2])) {
      const verb = seg[2]; const name = seg[3];
      if (!validName(name)) throw new HttpErr(400, 'invalid');
      if (verb === 'sessions' && method === 'PATCH') { // A8 rename: a mutation job, so it is ordered against every create of the server
        const { name: to } = parseJson(req, body);
        if (!validName(to)) throw new HttpErr(400, 'bad_name');
        await mutate(ctx, async () => { // the server keeps no per-session state by name; the tmux options move with the session
          // "<project>-<harness>" is the name /api/open reuses: only a session of that project and harness may take it
          const reserved = cfg.projectNames.flatMap((p) => Object.keys(HARNESSES).map((h) => [p, h])).find(([p, h]) => openName(p, h) === to);
          if (reserved && to !== name) {
            const me = (await listSessions(ctx)).find((x) => x.name === name);
            if (!me) throw new HttpErr(404, 'not_found');
            if (me.project !== reserved[0] || me.harness !== reserved[1]) throw new HttpErr(409, 'reserved_name');
          }
          try { await run(ctx, ['rename-session', '-t', sess(name), to]); } catch (e) {
            if (/duplicate session/i.test(e.stderr || '')) throw new HttpErr(409, 'name_taken'); // also one made outside the server meanwhile
            throw e; // a missing old name: 404 not_found
          }
        });
        return json(res, 200, { name: to });
      }
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
  const server = http.createServer({ connectionsCheckingInterval: Math.min(30000, uploadRequestMs / 4) }, async (req, res) => {
    const t0 = Date.now();
    const ctx = { cancelled: false, device: null, gen: -1 };
    res.on('close', () => { if (!res.writableFinished) { ctx.cancelled = true; ctx.onCancel?.(); } });
    // ONE timer per request, set before anything else (also for requests that are refused before their body is read, which Node would drain
    // until requestTimeout): a request that is not complete after `ms` is destroyed. Short (bodyMs) by default; only the upload route, once
    // everything that can refuse it has passed, swaps it for the long one. A complete request is never touched (SSE, a response still being built).
    ctx.cut = (ms) => { clearTimeout(ctx.cutTimer); ctx.cutTimer = setTimeout(() => { if (!req.complete) req.destroy(); }, ms).unref(); };
    ctx.cut(bodyMs);
    req.on('close', () => clearTimeout(ctx.cutTimer));
    let target = '(bad-target)';
    try {
      for (const [k, v] of Object.entries(SEC_HEADERS)) res.setHeader(k, v);
      // numbers only: at = arrival (UTC), sock = connection id # request number on it (#1 = new socket), conn = socket age at arrival, lag = arrival
      // minus the phone's X-PC-Sent (only a plain integer within a day is believed; the header text is never logged).
      const c = conns.get(req.socket) || { id: 0, at: t0, n: 0 };
      const sent = /^\d{10,16}$/.test(req.headers['x-pc-sent'] || '') ? t0 - Number(req.headers['x-pc-sent']) : NaN;
      const tail = ` at=${new Date(t0).toISOString().slice(11, 23)} sock=${c.id}#${++c.n} conn=${t0 - c.at}ms${Math.abs(sent) < 86400000 ? ` lag=${sent}ms` : ''}`;
      res.on('finish', () => log(`${req.method} ${target} ${res.statusCode} ${Date.now() - t0}ms${tail}`));
      let url;
      try { url = new URL(req.url, 'http://x'); } catch { throw new HttpErr(400, 'invalid'); }
      target = url.pathname;
      if (target.startsWith('/api/')) res.setHeader('Cache-Control', 'no-store');
      await route(req, res, url, ctx);
    } catch (e) {
      try {
        if (res.headersSent || res.destroyed) return res.end();
        const err = e instanceof HttpErr ? e : new HttpErr(500, 'internal');
        // a refused upload (401/403/404/405/413/415/429/400...) did not consume its body: answer with Connection: close and cut the request once
        // the answer is flushed; nothing is drained, so a client cannot keep the socket busy by sending the body anyway. Known cost: a client whose
        // body is still in flight when the socket closes gets a reset, and the reset can overtake the answer (the app then shows its network message).
        if (UPLOAD_ROUTE.test(target)) { res.setHeader('Connection', 'close'); res.once('finish', () => req.destroy()); }
        json(res, err.status, { error: err.code });
      } catch {}
    }
  });
  const conns = new WeakMap(); let connSeq = 0;
  server.on('connection', (sock) => conns.set(sock, { id: ++connSeq, at: Date.now(), n: 0 }));
  // permanent: a blocked event loop shows up in the journal (a request line only counts from the moment the handler runs).
  let stallAt = performance.now();
  const stallTimer = setInterval(() => {
    const now = performance.now(); const drift = now - stallAt - 250; stallAt = now;
    if (drift > 200) log(`event loop blocked ${Math.round(drift)}ms until=${new Date().toISOString().slice(11, 23)}`);
  }, 250);
  stallTimer.unref();
  server.on('clientError', (err, socket) => {
    log('clientError');
    if (socket.writable && !socket.destroyed) socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
    else socket.destroy();
  });
  server.requestTimeout = uploadRequestMs; // the outer bound (120 s); every request is cut at bodyMs by ctx.cut unless the upload route has been admitted
  server.headersTimeout = Math.min(10000, uploadRequestMs);
  const listen = async (port = Number(process.env.PC_PORT) || cfg.port || 7681, host = '0.0.0.0') => {
    await listenAdmin();
    try {
      const bound = await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, host, () => resolve(server.address().port)); });
      startWarm();
      return bound;
    } catch (e) { adminServer.close(); throw e; }
  };
  const close = () => {
    clearInterval(boxTimer);
    clearInterval(stallTimer);
    clearInterval(warmTimer); warmTimer = null;
    for (const abort of [...addStops]) abort();
    return Promise.all([
      new Promise((resolve) => { server.close(() => resolve()); server.closeAllConnections(); }),
      new Promise((resolve) => (adminServer.listening ? adminServer.close(() => resolve()) : resolve())),
    ]);
  };
  const homeIdle = () => Promise.all([quota, listing, spend, projects, staging, ompGuard].map((m) => m.settled())); // tests: no refresh still running
  return { server, listen, close, devices, tickBox, homeIdle, stats: () => ({ streams, running, reads, waiting: queue.length, active: !!active, addJobs: addJobs.size }) };
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
// fcode-new (--new <args>): --projects | --harnesses | <project> <harness>. Over admin.sock, so the session is made by the running server
// exactly as the app's "+" makes it. stdout: the list or the new session name only; any error: Vietnamese on stderr, nothing on stdout, exit 1.
const NEW_ERRORS = {
  unknown_project: 'Không có dự án này. Xem danh sách: fcode-new --projects',
  unknown_harness: 'Không có harness này. Xem danh sách: fcode-new --harnesses',
  harness_exited: 'Harness thoát ngay sau khi khởi động, chưa có phiên nào.',
  busy: 'Server đang bận, thử lại sau ít giây.',
  cancelled: 'Lệnh đã bị huỷ, chưa có phiên nào.',
  'unknown command': 'Server FCode trên box là bản cũ: chạy lại bash install.sh.',
};
async function newCli(dir, args) {
  const fail = (msg) => { console.error(msg); process.exit(1); };
  const meta = args.length === 1 && ['--projects', '--harnesses'].includes(args[0]);
  if (!meta && args.length !== 2) fail('Cách dùng: fcode-new --projects | fcode-new --harnesses | fcode-new <dự án> <harness>');
  let r;
  try { r = await adminRequest(dir, meta ? { cmd: 'meta' } : { cmd: 'new', project: args[0], harness: args[1] }, 20000); }
  catch (e) {
    fail(e.code === 'ENOSERVER' ? 'Server FCode chưa chạy trên box.'
      : e.message === 'admin socket timeout' ? 'Server FCode không trả lời kịp. Thử lại sau ít giây; nếu vẫn vậy, chạy lại bash install.sh trên box.'
        : 'Không nói chuyện được với server FCode. Thử lại; nếu vẫn lỗi, chạy lại bash install.sh trên box.');
  }
  if (!r.ok) fail(NEW_ERRORS[r.error] ?? 'Không tạo được phiên. Thử lại sau ít giây.');
  for (const line of meta ? (args[0] === '--projects' ? r.projects : r.harnesses) : [r.name]) console.log(line);
}
async function main() {
  const dir = defaultConfigDir();
  if (process.argv[2] === '--new') return newCli(dir, process.argv.slice(3)); // the wrapper puts it first; "fcode-pair --new" is a pairing name
  const arg = (f) => { const i = process.argv.indexOf(f); return i < 0 ? undefined : process.argv[i + 1] ?? ''; };
  const qr = process.argv.includes('--qr');
  const req = process.argv.includes('--pair') ? { cmd: 'pair', name: arg('--pair') === '--qr' ? '' : arg('--pair'), ...(qr && { links: true }) }
    : process.argv.includes('--devices') ? { cmd: 'devices' }
      : process.argv.includes('--revoke') ? { cmd: 'revoke', id: arg('--revoke') } : null;
  if (req) { // admin CLI: talks to the RUNNING server over admin.sock
    let r;
    try { r = await adminRequest(dir, req); } catch (e) { console.error(e.code === 'ENOSERVER' ? `${e.message} (no ${adminPath(dir)})` : `admin socket: ${e.message}`); process.exit(1); }
    if (!r.ok) {
      console.error(r.error === 'public_url_invalid' ? 'publicUrl trong config.json không hợp lệ cho app (cần https://tên-miền-ASCII)' : `error: ${r.error}`);
      process.exit(1);
    }
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
  // a stop or restart of the service (SIGTERM) ends the running add jobs cleanly (their clones are removed) before the process goes
  for (const sig of ['SIGTERM', 'SIGINT']) process.once(sig, () => { setTimeout(() => process.exit(0), 5000).unref(); app.close().catch(() => {}).finally(() => process.exit(0)); });
  const port = await app.listen();
  void lock; // held until the process exits
  console.log(`fcoding listening on 0.0.0.0:${port}`);
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((e) => { console.error(e.message); process.exit(1); });
}
