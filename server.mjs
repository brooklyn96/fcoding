#!/usr/bin/env node
// fcoding server: Node 22, built-ins only. See CONTRACT.md (S1-S8, A1, A2, A3).
import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const HARNESSES = { omp: 'omp', claude: 'claude', codex: 'codex', shell: 'bash -l' };
export const KEYS = ['Enter', 'Escape', 'Tab', 'BTab', 'Up', 'Down', 'Left', 'Right', 'PageUp', 'PageDown',
  'Home', 'End', 'BSpace', 'C-c', 'C-d', 'C-l', 'C-r', 'C-u', 'C-z', 'y', 'n', 'Space'];
const NAME_RE = /^[a-z0-9][a-z0-9-]{0,31}$/;
const COOKIE = 'pc_sid';
const COOKIE_MAX_AGE = 30 * 24 * 3600;
const BODY_LIMIT = 64 * 1024;
const TEXT_LIMIT = 32 * 1024;
const LONG_TEXT = 500; // bytes; longer single lines are pasted, not typed
const IP_FAILS = 5, IP_WINDOW = 15 * 60 * 1000;
const GLOBAL_FAILS = 30, GLOBAL_WINDOW = 3600 * 1000;
const MAX_STREAMS = 50;
const MAX_WAITING = 20; // mutation jobs waiting behind the active one
const MAX_READS = 7; // 8 tmux children in all: one slot is reserved for the active mutation
const DRAIN_TIMEOUT = 30000;
const HARNESS_CHECK_MS = 400; // after create: is the harness still running?
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

// ---------- password / config ----------
export function hashPassword(pw, { N = 16384, r = 8, p = 1 } = {}) {
  const salt = crypto.randomBytes(16);
  const hash = crypto.scryptSync(pw, salt, 64, { N, r, p, maxmem: 256 * N * r });
  return { algo: 'scrypt', salt: salt.toString('base64'), hash: hash.toString('base64'), N, r, p };
}
const scryptAsync = (pw, salt, len, o) => new Promise((res, rej) => crypto.scrypt(pw, salt, len, o, (e, k) => (e ? rej(e) : res(k))));
async function verifyPassword(pw, ph) {
  const want = Buffer.from(ph.hash, 'base64');
  const got = await scryptAsync(pw, Buffer.from(ph.salt, 'base64'), want.length, { N: ph.N, r: ph.r, p: ph.p, maxmem: 256 * ph.N * ph.r });
  return got.length === want.length && crypto.timingSafeEqual(got, want);
}
export function defaultConfigDir() {
  if (process.env.PC_CONFIG_DIR) return process.env.PC_CONFIG_DIR;
  return fs.existsSync('/data/home') ? '/data/home/.fcoding' : path.join(os.homedir(), '.fcoding');
}
// tmp file, fsync, rename, directory fsync
export function writePrivate(file, data) {
  const dir = path.dirname(file);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const tmp = `${file}.${process.pid}.tmp`;
  try {
    const fd = fs.openSync(tmp, 'w', 0o600);
    try { fs.writeFileSync(fd, data); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
    fs.renameSync(tmp, file);
  } catch (e) { try { fs.unlinkSync(tmp); } catch {} throw e; }
  if (process.platform !== 'win32') { const d = fs.openSync(dir, 'r'); try { fs.fsyncSync(d); } finally { fs.closeSync(d); } }
}
// Config dir must be a real directory owned by us (0700); config.json real, ours, 0600. Throws otherwise.
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
  if (check(dir, true)) check(path.join(dir, 'config.json'), false);
}
// Parse + validate a complete candidate. Error messages never quote the file (it holds the secret).
export function parseConfig(text) {
  let c;
  try { c = JSON.parse(text); } catch { throw new Error('config.json is not valid JSON'); }
  if (!c || typeof c !== 'object' || Array.isArray(c)) throw new Error('config.json is not an object');
  const ph = c.passwordHash;
  // canonical base64 (re-encoding gives the same text) of at least min bytes
  const b64 = (s, min) => typeof s === 'string' && Buffer.from(s, 'base64').length >= min && Buffer.from(s, 'base64').toString('base64') === s;
  const int = (n, lo, hi) => Number.isInteger(n) && n >= lo && n <= hi;
  if (!ph || typeof ph !== 'object' || ph.algo !== 'scrypt' || !b64(ph.salt, 16) || !b64(ph.hash, 32)
    || !int(ph.N, 2 ** 14, 2 ** 20) || (ph.N & (ph.N - 1)) || !int(ph.r, 1, 32) || !int(ph.p, 1, 16)
    || ph.N >= 2 ** (16 * ph.r) || 128 * ph.N * ph.r > 256 * 2 ** 20) { // RFC 7914 N < 2^(16r); memory 128*N*r <= 256 MiB
    throw new Error('config.json: passwordHash missing or invalid (run --set-password)');
  }
  if (!b64(c.cookieSecret, 32)) throw new Error('config.json: cookieSecret missing or invalid');
  const projects = c.projects ?? {};
  if (typeof projects !== 'object' || projects === null || Array.isArray(projects)) throw new Error('config.json: projects must be an object');
  if (c.port !== undefined && !(Number.isInteger(c.port) && c.port > 0 && c.port < 65536)) throw new Error('config.json: port invalid');
  return {
    passwordHash: ph, hashText: JSON.stringify(ph), secret: Buffer.from(c.cookieSecret, 'base64'), port: c.port, projects,
    projectNames: Object.keys(projects).filter((k) => typeof projects[k] === 'string' && path.isAbsolute(projects[k])),
  };
}
function randomPassword(n = 24) {
  const abc = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
  let s = '';
  for (let i = 0; i < n; i++) s += abc[crypto.randomInt(abc.length)];
  return s;
}
export function setPassword(configDir, pw) {
  secureConfigDir(configDir);
  const file = path.join(configDir, 'config.json');
  let cfg = {};
  if (fs.existsSync(file)) {
    try { cfg = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { cfg = null; }
    if (!cfg || typeof cfg !== 'object' || Array.isArray(cfg)) throw new Error('config.json is not valid JSON; fix or remove it first');
  }
  cfg.passwordHash = hashPassword(pw);
  cfg.cookieSecret = crypto.randomBytes(32).toString('base64'); // rotate: every old session key becomes unverifiable
  cfg.projects ||= { home: process.env.HOME || os.homedir() };
  cfg.port ||= 7681;
  const text = JSON.stringify(cfg, null, 2);
  parseConfig(text); // the whole new config must be valid, or nothing is written
  writePrivate(file, text);
  secureConfigDir(configDir);
}
// trailing blank lines only, linear: spaces on the last real line stay
export function trimScreen(s) {
  let j = s.length - 1;
  while (j >= 0 && (s[j] === ' ' || s[j] === '\t' || s[j] === '\n')) j--;
  if (j < 0) return '';
  const nl = s.indexOf('\n', j);
  return nl < 0 ? s : s.slice(0, nl);
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

  secureConfigDir(configDir);

  // --- config: invalid at startup -> throw (exit 1); invalid on reload -> keep the previous one ---
  const cfgFile = path.join(configDir, 'config.json');
  const stampOf = () => { try { const s = fs.statSync(cfgFile); return `${s.mtimeMs}:${s.size}:${s.ino}`; } catch { return ''; } };
  let cfgStamp = stampOf();
  let text;
  try { text = fs.readFileSync(cfgFile, 'utf8'); } catch { throw new Error(`config.json missing or unreadable in ${configDir} (run --set-password)`); }
  let cfg = parseConfig(text);
  let gen = 0; // bumped whenever the password hash or the cookie secret changes

  // --- sessions: memory only, keyed by HMAC-SHA256(secret, sid); a restart logs everyone out ---
  const sessions = new Map();
  function refreshConfig() {
    const st = stampOf();
    if (st === cfgStamp) return;
    cfgStamp = st; // a bad file is retried on its next change
    let next;
    try { next = parseConfig(fs.readFileSync(cfgFile, 'utf8')); } catch (e) { log(`config reload failed, keeping the previous one: ${e.code || e.message}`); return; }
    if (next.hashText !== cfg.hashText || !next.secret.equals(cfg.secret)) { sessions.clear(); gen++; }
    cfg = next;
  }
  const sidKey = (sid) => crypto.createHmac('sha256', cfg.secret).update(sid).digest('hex');
  // ctx = {cancelled, key, gen}: the request is alive, its session valid and unexpired, the config generation unchanged
  function valid(ctx) {
    refreshConfig();
    const exp = ctx.key ? sessions.get(ctx.key) : undefined;
    return !ctx.cancelled && ctx.gen === gen && exp > now();
  }
  const gateErr = (ctx) => (ctx.cancelled ? new HttpErr(499, 'cancelled') : new HttpErr(401, 'unauthorized'));

  // --- login rate limits ---
  const ipFails = new Map();
  let globalFails = [];
  const prune = (a, win, t) => { while (a.length && a[0] <= t - win) a.shift(); return a; };
  function rateLimited(ip, t) {
    if (ipFails.size > 5000) for (const [k, a] of ipFails) if (!prune(a, IP_WINDOW, t).length) ipFails.delete(k);
    const a = prune(ipFails.get(ip) || [], IP_WINDOW, t);
    if (a.length >= IP_FAILS) return Math.max(1, Math.ceil((a[0] + IP_WINDOW - t) / 1000));
    prune(globalFails, GLOBAL_WINDOW, t);
    if (globalFails.length >= GLOBAL_FAILS) return Math.max(1, Math.ceil((globalFails[0] + GLOBAL_WINDOW - t) / 1000));
    return 0;
  }
  // an attempt is counted up front (so parallel guesses cannot dodge the limit) and refunded on success
  const reserve = (ip, t) => { if (!ipFails.has(ip)) ipFails.set(ip, []); ipFails.get(ip).push(t); globalFails.push(t); };
  const refund = (ip, t) => {
    const a = ipFails.get(ip); const i = a ? a.indexOf(t) : -1; if (i >= 0) a.splice(i, 1);
    const j = globalFails.indexOf(t); if (j >= 0) globalFails.splice(j, 1);
  };

  // --- the one execution gate: every tmux child goes through run(ctx); execFile only, never a shell ---
  let running = 0, reads = 0;
  function run(ctx, args, input) {
    if (!ctx) throw new Error('run() without ctx');
    const read = !ctx.mutation;
    if (read && reads >= MAX_READS) return Promise.reject(new HttpErr(503, 'busy')); // reads never queue
    if (!valid(ctx)) return Promise.reject(gateErr(ctx)); // checked after capacity, nothing awaited before execFile
    running++; if (read) reads++;
    let freed = false;
    const free = () => { if (!freed) { freed = true; running--; if (read) reads--; } };
    return new Promise((resolve, reject) => {
      const [cmd, ...pre] = tmuxSpec;
      try {
        const child = execFile(cmd, [...pre, ...args], {
          encoding: 'utf8', timeout: 5000, maxBuffer: 16 << 20, windowsHide: true,
          env: { ...process.env, LANG: 'C.UTF-8', LC_ALL: 'C.UTF-8' },
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
      out = await run(ctx, ['list-sessions', '-F', '#{session_name}|#{session_created}|#{session_attached}|#{session_activity}|#{@pc_harness}|#{@pc_project}']);
    } catch (e) {
      if (e.status === 404) return [];
      throw e;
    }
    const rows = [];
    for (const line of out.split('\n')) {
      const [name, created, attached, activity, harness, ...rest] = line.split('|');
      if (!NAME_RE.test(name || '')) continue;
      rows.push({
        name, project: rest.join('|') || null, harness: harness || null,
        created: Number(created) || 0, attached: Number(attached) > 0, activity: Number(activity) || 0,
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
  async function getScreen(name, lines, ctx) {
    if (!ctx.mutation && reads + 2 > MAX_READS) throw new HttpErr(503, 'busy'); // both slots or neither
    const [cap, info] = await Promise.all([
      run(ctx, ['capture-pane', '-p', '-J', '-t', pane(name), '-S', `-${lines}`]),
      run(ctx, ['display-message', '-p', '-t', pane(name), '#{pane_width} #{pane_height} #{cursor_x} #{cursor_y}']),
    ]);
    const [cols, rows, x, y] = info.trim().split(' ').map(Number);
    const text = trimScreen(cap);
    const hash = crypto.createHash('sha1').update(`${cols}x${rows}@${x},${y}\n${text}`).digest('hex').slice(0, 16);
    return { text, rows, cols, cursor: { x, y }, hash };
  }

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
  function clientIp(req) {
    const xf = req.headers['x-forwarded-for']; // the instabox proxy overwrites this with the real client IP
    const first = typeof xf === 'string' ? xf.split(',')[0].trim() : '';
    return (first || req.socket.remoteAddress || 'unknown').slice(0, 64);
  }
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
  async function stream(req, res, name, lines, ctx) {
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
      let snap = await getScreen(name, lines, ctx);
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
          if (!snap) snap = await getScreen(name, lines, ctx);
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

    const isApi = pathname.startsWith('/api/');
    if (method !== 'GET' && method !== 'HEAD' && !csrfOk(req)) throw new HttpErr(403, 'forbidden');

    const seg = pathname.split('/');
    const isLogin = pathname === '/api/login';
    if (!isLogin) {
      refreshConfig(); // before deriving the key
      const sid = requestSid(req);
      ctx.key = sid && sid.length < 128 ? sidKey(sid) : null;
      ctx.gen = gen;
      if (!valid(ctx)) throw new HttpErr(401, 'unauthorized');
    }
    if (!isApi) throw new HttpErr(404, 'not_found');

    const body = method === 'GET' ? null : await readBody(req);
    if (!isLogin && !valid(ctx)) throw gateErr(ctx); // re-checked once the body is in
    const want = (m) => { if (method !== m) throw new HttpErr(405, 'method'); };

    if (isLogin) {
      want('POST');
      const { password } = parseJson(req, body);
      if (typeof password !== 'string' || !password || password.length > 256) throw new HttpErr(400, 'invalid');
      refreshConfig();
      const t = now(); const ip = clientIp(req);
      const wait = rateLimited(ip, t);
      if (wait) return json(res, 429, { error: 'rate_limited', retryAfter: wait }, { 'Retry-After': String(wait) });
      reserve(ip, t);
      const g0 = gen;
      if (!(await verifyPassword(password, cfg.passwordHash))) throw new HttpErr(401, 'bad_password');
      refund(ip, t);
      refreshConfig();
      if (gen !== g0) throw new HttpErr(401, 'bad_password'); // password changed while we were hashing
      for (const [k, exp] of sessions) if (exp <= t) sessions.delete(k);
      while (sessions.size >= 200) sessions.delete(sessions.keys().next().value);
      const sid = crypto.randomBytes(32).toString('base64url');
      sessions.set(sidKey(sid), t + COOKIE_MAX_AGE * 1000);
      const out = req.headers['x-pc-client'] === 'ios' ? { ok: true, token: sid } : { ok: true };
      return json(res, 200, out, { 'Set-Cookie': setCookie(sid, COOKIE_MAX_AGE) });
    }
    if (pathname === '/api/logout') {
      want('POST');
      if (url.searchParams.get('all') === '1') sessions.clear(); else sessions.delete(ctx.key);
      return json(res, 200, { ok: true }, { 'Set-Cookie': setCookie('', 0) });
    }
    if (pathname === '/api/me') { want('GET'); return json(res, 200, { ok: true }); }
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
      const { project, harness } = parseJson(req, body);
      if (!validProject(project) || !validHarness(harness)) throw new HttpErr(400, 'invalid');
      const name = `${project}-${harness}`.toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-+/, '').slice(0, 32);
      if (!NAME_RE.test(name)) throw new HttpErr(400, 'invalid');
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
        if (verb === 'screen') return json(res, 200, await getScreen(name, lines, ctx));
        return stream(req, res, name, lines, ctx);
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
    const ctx = { cancelled: false, key: null, gen: -1 };
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
  const listen = (port = Number(process.env.PC_PORT) || cfg.port || 7681, host = '0.0.0.0') =>
    new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, host, () => resolve(server.address().port)); });
  const close = () => new Promise((resolve) => { server.close(() => resolve()); server.closeAllConnections(); });
  return { server, listen, close, sessions, stats: () => ({ streams, running, reads, waiting: queue.length, active: !!active }) };
}

// ---------- CLI ----------
async function main() {
  const dir = defaultConfigDir();
  if (process.argv.includes('--set-password')) {
    let pw = '';
    if (!process.stdin.isTTY) {
      const chunks = [];
      for await (const c of process.stdin) chunks.push(c);
      pw = Buffer.concat(chunks).toString('utf8').replace(/\r?\n$/, ''); // only the line ending; spaces are part of it
    }
    const generated = !pw;
    if (generated) pw = randomPassword();
    else if (pw.length < 8 || pw.length > 256) { console.error('password must be 8-256 characters'); process.exit(1); }
    setPassword(dir, pw);
    console.log(generated ? `Password set. Generated password (shown once): ${pw}` : 'Password set.');
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
  const app = createApp({ configDir: dir });
  const port = await app.listen();
  console.log(`fcoding listening on 0.0.0.0:${port}`);
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((e) => { console.error(e.message); process.exit(1); });
}
