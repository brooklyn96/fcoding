import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import net from 'node:net';
import crypto from 'node:crypto';
import { createApp, hashPassword, writePrivate, trimScreen, KEYS } from '../server.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const FAKE = path.join(here, 'fake-tmux.mjs');
const SERVER = path.join(here, '..', 'server.mjs');
const PW = 'correct horse battery';
const VN = 'Xin chào, tiếng Việt có dấu: ắ ẫ ợ ữ';
const ABS = path.resolve(os.tmpdir());
const PW_HASH = hashPassword(PW); // N = 2^14, the smallest the server accepts
const HOME = os.homedir();
const LAUNCH = `env LANG=C.UTF-8 LC_ALL=C.UTF-8 'PATH=${HOME}/.local/bin:${HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin' `;
const MONTH = 30 * 24 * 3600 * 1000;

async function boot(opts = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'pc-test-'));
  const fakeDir = path.join(root, 'fake'); fs.mkdirSync(fakeDir);
  const configDir = path.join(root, 'cfg'); fs.mkdirSync(configDir);
  fs.writeFileSync(path.join(configDir, 'config.json'), JSON.stringify({
    passwordHash: PW_HASH, cookieSecret: Buffer.alloc(32, 7).toString('base64'),
    projects: { alpha: ABS, 'my.proj': ABS }, port: 7681,
  }));
  process.env.FAKE_TMUX_DIR = fakeDir;
  const logs = [];
  const app = createApp({ configDir, tmux: [process.execPath, FAKE], log: (l) => logs.push(l), pollMs: 40, pasteEnterDelayMs: 0, ...opts });
  const port = await app.listen(0, '127.0.0.1');
  const ctx = { app, port, logs, root, configDir };
  ctx.req = (method, p, o = {}) => request(port, method, p, o);
  ctx.login = async (headers = {}) => {
    const r = await ctx.req('POST', '/api/login', { body: { password: PW }, headers });
    assert.equal(r.status, 200);
    return { cookie: r.headers['set-cookie'][0].split(';')[0], json: r.json };
  };
  ctx.calls = () => {
    try { return fs.readFileSync(path.join(fakeDir, 'log.jsonl'), 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l)); } catch { return []; }
  };
  ctx.close = async () => {
    await app.close();
    for (let i = 0; i < 150 && app.stats().running + app.stats().waiting > 0; i++) await new Promise((r) => setTimeout(r, 20));
    await new Promise((r) => setTimeout(r, 100)); // let exiting fake-tmux children finish writing
    fs.rmSync(root, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
  };
  return ctx;
}

function request(port, method, p, { body, headers = {}, cookie, raw, pc = true } = {}) {
  return new Promise((resolve, reject) => {
    const h = pc ? { 'X-PC': '1', ...headers } : { ...headers };
    if (cookie) h.Cookie = cookie;
    let payload = raw;
    if (body !== undefined) { payload = JSON.stringify(body); h['Content-Type'] = 'application/json'; }
    if (payload !== undefined) h['Content-Length'] = Buffer.byteLength(payload);
    const r = http.request({ host: '127.0.0.1', port, method, path: p, headers: h }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        let json; try { json = JSON.parse(text); } catch {}
        resolve({ status: res.statusCode, headers: res.headers, text, json });
      });
    });
    r.on('error', reject);
    r.end(payload);
  });
}

async function withApp(fn, opts) {
  const c = await boot(opts);
  try { await fn(c); } finally { await c.close(); }
}
const mkSession = (c, cookie, name = 'work') =>
  c.req('POST', '/api/sessions', { cookie, body: { name, project: 'alpha', harness: 'shell' } });
const JSON_CT = { 'Content-Type': 'application/json' };

test('GET / is plain text without auth; no static files', () => withApp(async (c) => {
  const r = await c.req('GET', '/');
  assert.equal(r.status, 200);
  assert.match(r.headers['content-type'], /^text\/plain/);
  assert.equal(r.text, 'fcoding ok');
  for (const p of ['/index.html', '/manifest.webmanifest', '/icon.svg']) assert.equal((await c.req('GET', p)).status, 401);
}));

test('every protected route needs a session', () => withApp(async (c) => {
  const routes = [
    ['GET', '/api/me'], ['GET', '/api/meta'], ['GET', '/api/sessions'], ['GET', '/api/screen/work'], ['GET', '/api/stream/work'],
    ['POST', '/api/sessions'], ['POST', '/api/open'], ['POST', '/api/send/work'], ['POST', '/api/key/work'], ['POST', '/api/resize/work'],
    ['POST', '/api/logout'], ['DELETE', '/api/sessions/work'], ['GET', '/api/nothing'], ['GET', '/other'],
  ];
  for (const [m, p] of routes) {
    const r = await c.req(m, p, { body: m === 'POST' ? {} : undefined });
    assert.equal(r.status, 401, `${m} ${p}`);
  }
  assert.equal((await c.req('GET', '/api/me', { cookie: 'pc_sid=forged' })).status, 401);
  assert.equal((await c.req('GET', '/api/me', { headers: { Authorization: 'Bearer forged' } })).status, 401);
  assert.equal(c.calls().length, 0); // nothing reached tmux
}));

test('login: bad password, ok, cookie flags', () => withApp(async (c) => {
  const bad = await c.req('POST', '/api/login', { body: { password: 'nope' } });
  assert.equal(bad.status, 401);
  assert.deepEqual(bad.json, { error: 'bad_password' });
  assert.equal((await c.req('POST', '/api/login', { body: { password: 5 } })).status, 400);
  assert.equal((await c.req('POST', '/api/login', { body: {} })).status, 400);
  const ok = await c.req('POST', '/api/login', { body: { password: PW } });
  assert.equal(ok.status, 200);
  assert.deepEqual(ok.json, { ok: true }); // no token without X-PC-Client: ios
  const sc = ok.headers['set-cookie'][0];
  assert.match(sc, /^pc_sid=[A-Za-z0-9_-]{43}; /);
  for (const f of ['HttpOnly', 'Secure', 'SameSite=Strict', 'Path=/', 'Max-Age=2592000']) assert.ok(sc.includes(f), f);
  const cookie = sc.split(';')[0];
  assert.equal((await c.req('GET', '/api/me', { cookie })).status, 200);
  const meta = await c.req('GET', '/api/meta', { cookie });
  assert.deepEqual(meta.json.projects.sort(), ['alpha', 'my.proj']);
  assert.deepEqual(meta.json.keys, KEYS);
  assert.deepEqual(meta.json.harnesses, ['omp', 'claude', 'codex', 'shell']);
}));

test('ios client gets a Bearer token that works like the cookie', () => withApp(async (c) => {
  const { cookie, json } = await c.login({ 'X-PC-Client': 'ios' });
  assert.match(json.token, /^[A-Za-z0-9_-]{43}$/);
  assert.equal(cookie, `pc_sid=${json.token}`);
  const auth = { Authorization: `Bearer ${json.token}` };
  assert.equal((await c.req('GET', '/api/me', { headers: auth })).status, 200);
  const r = await c.req('POST', '/api/sessions', { headers: auth, body: { name: 'viabearer', project: 'alpha', harness: 'shell' } });
  assert.equal(r.status, 201);
  // revocation applies to both
  assert.equal((await c.req('POST', '/api/logout', { headers: auth })).status, 200);
  assert.equal((await c.req('GET', '/api/me', { headers: auth })).status, 401);
  assert.equal((await c.req('GET', '/api/me', { cookie })).status, 401);
  assert.ok(!c.logs.join('\n').includes(json.token));
}));

test('login rate limit per IP with Retry-After', () => withApp(async (c) => {
  const xf = { 'X-Forwarded-For': '9.9.9.9, 10.0.0.1' };
  for (let i = 0; i < 5; i++) assert.equal((await c.req('POST', '/api/login', { body: { password: 'x' + i }, headers: xf })).status, 401);
  const r = await c.req('POST', '/api/login', { body: { password: PW }, headers: xf }); // even the right password
  assert.equal(r.status, 429);
  assert.equal(r.json.error, 'rate_limited');
  assert.ok(r.json.retryAfter > 0 && r.json.retryAfter <= 900);
  assert.equal(r.headers['retry-after'], String(r.json.retryAfter));
  const other = await c.req('POST', '/api/login', { body: { password: PW }, headers: { 'X-Forwarded-For': '8.8.8.8' } });
  assert.equal(other.status, 200);
}));

test('successful logins are not counted against the limit', () => withApp(async (c) => {
  const xf = { 'X-Forwarded-For': '7.7.7.7' };
  for (let i = 0; i < 4; i++) await c.req('POST', '/api/login', { body: { password: 'x' }, headers: xf });
  for (let i = 0; i < 3; i++) assert.equal((await c.req('POST', '/api/login', { body: { password: PW }, headers: xf })).status, 200);
}));

test('global login limit 30/hour', () => withApp(async (c) => {
  for (let ip = 1; ip <= 6; ip++) {
    for (let i = 0; i < 5; i++) await c.req('POST', '/api/login', { body: { password: 'x' }, headers: { 'X-Forwarded-For': `1.1.1.${ip}` } });
  }
  const r = await c.req('POST', '/api/login', { body: { password: PW }, headers: { 'X-Forwarded-For': '2.2.2.2' } });
  assert.equal(r.status, 429);
  assert.ok(Number(r.headers['retry-after']) > 0 && Number(r.headers['retry-after']) <= 3600);
}));

test('logout and logout-all revoke', () => withApp(async (c) => {
  const a = await c.login(); const b = await c.login();
  const out = await c.req('POST', '/api/logout', { cookie: a.cookie });
  assert.equal(out.status, 200);
  assert.match(out.headers['set-cookie'][0], /Max-Age=0/);
  assert.equal((await c.req('GET', '/api/me', { cookie: a.cookie })).status, 401);
  assert.equal((await c.req('GET', '/api/me', { cookie: b.cookie })).status, 200);
  const d = await c.login();
  assert.equal((await c.req('POST', '/api/logout?all=1', { cookie: d.cookie })).status, 200);
  assert.equal((await c.req('GET', '/api/me', { cookie: b.cookie })).status, 401);
  assert.equal((await c.req('GET', '/api/me', { cookie: d.cookie })).status, 401);
}));

test('restart logs everyone out: sessions live in memory only, nothing is written', async () => {
  const c = await boot();
  const { cookie, json } = await c.login({ 'X-PC-Client': 'ios' });
  await c.app.close();
  assert.deepEqual(fs.readdirSync(c.configDir), ['config.json']); // no sessions.json
  const app2 = createApp({ configDir: c.configDir, tmux: [process.execPath, FAKE], log: () => {} });
  const port = await app2.listen(0, '127.0.0.1');
  assert.equal((await request(port, 'GET', '/api/me', { cookie })).status, 401);
  assert.equal((await request(port, 'GET', '/api/me', { headers: { Authorization: `Bearer ${json.token}` } })).status, 401);
  assert.equal((await request(port, 'POST', '/api/login', { body: { password: PW } })).status, 200);
  await app2.close();
  fs.rmSync(c.root, { recursive: true, force: true });
});

test('CSRF: X-PC header and Origin', () => withApp(async (c) => {
  const { cookie } = await c.login();
  const body = { name: 'csrf', project: 'alpha', harness: 'shell' };
  assert.equal((await c.req('POST', '/api/sessions', { cookie, body, pc: false })).status, 403);
  assert.equal((await c.req('POST', '/api/sessions', { cookie, body, headers: { 'X-PC': '0' } })).status, 403);
  assert.equal((await c.req('POST', '/api/login', { body: { password: PW }, pc: false })).status, 403);
  assert.equal((await c.req('DELETE', '/api/sessions/csrf', { cookie, pc: false })).status, 403);
  assert.equal((await c.req('POST', '/api/logout', { cookie, pc: false })).status, 403);
  const own = `https://127.0.0.1:${c.port}`;
  for (const origin of ['https://evil.example', `http://127.0.0.1:${c.port}`, 'null']) {
    assert.equal((await c.req('POST', '/api/sessions', { cookie, body, headers: { Origin: origin } })).status, 403, origin);
  }
  assert.equal((await c.req('POST', '/api/sessions', { cookie, body, headers: { Origin: own } })).status, 201);
  // behind the proxy the public name arrives in X-Forwarded-Host (A2)
  const fwd = { 'X-Forwarded-Host': 'box.example.com' };
  assert.equal((await c.req('POST', '/api/sessions', { cookie, body: { ...body, name: 'csrf2' }, headers: { ...fwd, Origin: 'https://box.example.com' } })).status, 201);
  assert.equal((await c.req('POST', '/api/sessions', { cookie, body: { ...body, name: 'csrf3' }, headers: { ...fwd, Origin: own } })).status, 403);
  assert.equal((await c.req('POST', '/api/login', { body: { password: PW }, headers: { Origin: 'https://evil.example' } })).status, 403);
  assert.equal((await c.req('GET', '/api/me', { cookie, pc: false })).status, 200); // GET needs no header
}));

test('validation of names, keys, projects, harnesses, ranges', () => withApp(async (c) => {
  const { cookie } = await c.login();
  const post = (p, body) => c.req('POST', p, { cookie, body });
  for (const name of ['Work', '-a', 'a b', 'a/b', '..', 'a'.repeat(33), '', 'a;ls', 'x\n']) {
    const r = await post('/api/sessions', { name, project: 'alpha', harness: 'shell' });
    assert.equal(r.status, 400, JSON.stringify(name));
  }
  assert.equal((await post('/api/sessions', { name: 'ok', project: '/etc', harness: 'shell' })).status, 400);
  assert.equal((await post('/api/sessions', { name: 'ok', project: '__proto__', harness: 'shell' })).status, 400);
  assert.equal((await post('/api/sessions', { name: 'ok', project: 'alpha', harness: 'rm -rf' })).status, 400);
  assert.equal((await post('/api/sessions', { name: 'ok', project: 'alpha', harness: 'constructor' })).status, 400);
  assert.equal((await post('/api/sessions', { name: 'ok', project: 'alpha' })).status, 400);
  assert.equal((await post('/api/open', { project: 'nope', harness: 'shell' })).status, 400);
  assert.equal((await post('/api/open', { project: 'alpha', harness: 'nope' })).status, 400);
  assert.equal(c.calls().length, 0);

  assert.equal((await mkSession(c, cookie, 'work')).status, 201);
  assert.equal((await mkSession(c, cookie, 'work')).status, 409);
  const created = c.calls().find((x) => x.argv[0] === 'new-session');
  assert.deepEqual(created.argv.slice(0, 5), ['new-session', '-d', '-s', 'work', '-c']);
  assert.equal(created.argv.at(-1), `${LAUNCH}bash -l`);

  assert.equal((await c.req('GET', '/api/screen/Bad_Name', { cookie })).status, 400);
  assert.equal((await c.req('GET', '/api/screen/ghost', { cookie })).status, 404);
  assert.equal((await c.req('DELETE', '/api/sessions/ghost', { cookie })).status, 404);
  for (const q of ['10', '5000', 'abc', '-1', '1e2', '']) assert.equal((await c.req('GET', `/api/screen/work?lines=${q}`, { cookie })).status, 400, q);

  const k = (b) => post('/api/key/work', b);
  assert.equal((await k({ key: 'rm' })).status, 400);
  assert.deepEqual((await k({ key: 'F13' })).json, { error: 'bad_key' });
  assert.equal((await k({ key: '; ls' })).status, 400);
  assert.equal((await k({})).status, 400);
  assert.equal((await k({ key: 'Enter', repeat: 0 })).status, 400);
  assert.equal((await k({ key: 'Enter', repeat: 21 })).status, 400);
  assert.equal((await k({ key: 'Enter', repeat: 1.5 })).status, 400);
  for (const key of KEYS) assert.equal((await k({ key })).status, 200, key);
  assert.equal((await k({ key: 'Down', repeat: 3 })).status, 200);
  assert.deepEqual(c.calls().filter((x) => x.argv[0] === 'send-keys').at(-1).argv, ['send-keys', '-t', '=work:', 'Down', 'Down', 'Down']);

  const rs = (b) => post('/api/resize/work', b);
  for (const b of [{ cols: 19, rows: 24 }, { cols: 301, rows: 24 }, { cols: 80, rows: 9 }, { cols: 80, rows: 201 }, { cols: '80', rows: 24 }, {}]) {
    assert.equal((await rs(b)).status, 400, JSON.stringify(b));
  }
  assert.equal((await rs({ cols: 20, rows: 10 })).status, 200);
  assert.equal((await rs({ cols: 300, rows: 200 })).status, 200);
  assert.deepEqual(c.calls().filter((x) => x.argv[0] === 'resize-window').at(-1).argv, ['resize-window', '-t', '=work:', '-x', '300', '-y', '200']);

  assert.equal((await post('/api/send/work', { text: 5 })).status, 400);
  assert.equal((await post('/api/send/work', { text: 'a\0b' })).status, 400);
  assert.equal((await post('/api/send/work', { text: '' })).status, 400);
  assert.equal((await c.req('GET', '/api/send/work', { cookie })).status, 405);
  assert.equal((await c.req('POST', '/api/send/work', { cookie, raw: '{}', headers: { 'Content-Type': 'text/plain' } })).status, 415);
  assert.equal((await c.req('POST', '/api/send/work', { cookie, raw: '{bad', headers: JSON_CT })).status, 400);
  assert.equal((await c.req('POST', '/api/send/work', { cookie, raw: '[]', headers: JSON_CT })).status, 400);
  assert.equal((await c.req('DELETE', '/api/sessions/work', { cookie })).status, 200);
  assert.deepEqual(c.calls().filter((x) => x.argv[0] === 'kill-session').at(-1).argv, ['kill-session', '-t', '=work']);
}));

test('sessions list and screen', () => withApp(async (c) => {
  const { cookie } = await c.login();
  assert.deepEqual((await c.req('GET', '/api/sessions', { cookie })).json, { sessions: [] }); // tmux: no server running
  await mkSession(c, cookie, 'work');
  const ls = (await c.req('GET', '/api/sessions', { cookie })).json.sessions;
  assert.deepEqual(ls, [{ name: 'work', project: 'alpha', harness: 'shell', created: 1700000000, attached: false, activity: 1700000100 }]);
  const sc = (await c.req('GET', '/api/screen/work?lines=100', { cookie })).json;
  assert.equal(sc.text, 'hello world\nline 2'); // trailing blank lines trimmed
  assert.deepEqual([sc.cols, sc.rows, sc.cursor], [80, 24, { x: 3, y: 5 }]);
  assert.match(sc.hash, /^[0-9a-f]{16}$/);
  const cap = c.calls().find((x) => x.argv[0] === 'capture-pane');
  assert.deepEqual(cap.argv, ['capture-pane', '-p', '-J', '-t', '=work:', '-S', '-100']);
}));

test('POST /api/open creates once, then reuses', () => withApp(async (c) => {
  const { cookie } = await c.login();
  const o1 = await c.req('POST', '/api/open', { cookie, body: { project: 'my.proj', harness: 'claude' } });
  assert.equal(o1.status, 200);
  assert.deepEqual(o1.json, { name: 'my-proj-claude', created: true });
  const o2 = await c.req('POST', '/api/open', { cookie, body: { project: 'my.proj', harness: 'claude' } });
  assert.deepEqual(o2.json, { name: 'my-proj-claude', created: false });
  const ns = c.calls().filter((x) => x.argv[0] === 'new-session' && x.argv[3] === 'my-proj-claude');
  assert.equal(ns.length, 2); // second attempt hit "duplicate session"
  assert.equal(ns[0].argv.at(-1), `${LAUNCH}claude`);
  // same name but a different harness: not silently reused
  await mkSession(c, cookie, 'alpha-codex');
  const clash = await c.req('POST', '/api/open', { cookie, body: { project: 'alpha', harness: 'codex' } });
  assert.equal(clash.status, 409);
}));

test('send: one line uses send-keys -l; Vietnamese is byte-exact', () => withApp(async (c) => {
  const { cookie } = await c.login();
  await mkSession(c, cookie);
  const r = await c.req('POST', '/api/send/work', { cookie, body: { text: VN, enter: true } });
  assert.equal(r.status, 200);
  const calls = c.calls().filter((x) => x.argv[0] === 'send-keys');
  assert.deepEqual(calls[0].argv, ['send-keys', '-t', '=work:', '-l', '--', VN]);
  assert.ok(Buffer.from(calls[0].argv[5], 'utf8').equals(Buffer.from(VN, 'utf8')));
  assert.deepEqual(calls[1].argv, ['send-keys', '-t', '=work:', 'Enter']);
  assert.ok(!c.calls().some((x) => x.argv[0] === 'load-buffer'));
  await c.req('POST', '/api/send/work', { cookie, body: { text: '-rf', enter: false } }); // "--" protects option-like text
  assert.deepEqual(c.calls().at(-1).argv, ['send-keys', '-t', '=work:', '-l', '--', '-rf']);
  await c.req('POST', '/api/send/work', { cookie, body: { text: '', enter: true } });
  assert.deepEqual(c.calls().at(-1).argv, ['send-keys', '-t', '=work:', 'Enter']);
}));

test('send: multi-line and long text use load-buffer (stdin) + paste-buffer -p', () => withApp(async (c) => {
  const { cookie } = await c.login();
  await mkSession(c, cookie);
  const multi = `${VN}\nDòng hai: ắ ẫ ợ ữ 😀\r\n\ttab và "quote" 'x' $HOME \`id\`; rm -rf /`;
  const want = multi.replace(/\r\n/g, '\n');
  assert.equal((await c.req('POST', '/api/send/work', { cookie, body: { text: multi, enter: true } })).status, 200);
  const calls = c.calls();
  const i = calls.findIndex((x) => x.argv[0] === 'load-buffer');
  assert.deepEqual(calls[i].argv, ['load-buffer', '-b', 'pc', '-']);
  assert.ok(Buffer.from(calls[i].stdin, 'base64').equals(Buffer.from(want, 'utf8')));
  assert.deepEqual(calls[i + 1].argv, ['paste-buffer', '-p', '-d', '-b', 'pc', '-t', '=work:']);
  assert.deepEqual(calls[i + 2].argv, ['send-keys', '-t', '=work:', 'Enter']);
  assert.ok(!calls.some((x) => x.argv.some((a) => a.includes('Dòng hai')))); // text never in argv on this path
  // long single line is pasted too, no Enter
  const long = 'ắ'.repeat(400);
  await c.req('POST', '/api/send/work', { cookie, body: { text: long, enter: false } });
  const l = c.calls().filter((x) => x.argv[0] === 'load-buffer').at(-1);
  assert.equal(Buffer.from(l.stdin, 'base64').toString('utf8'), long);
  assert.equal(c.calls().at(-1).argv[0], 'paste-buffer');
  // concurrent sends do not interleave use of the shared buffer
  await Promise.all([1, 2, 3].map((n) => c.req('POST', '/api/send/work', { cookie, body: { text: `a${n}\nb${n}`, enter: false } })));
  assert.deepEqual(c.calls().slice(-6).map((x) => x.argv[0]), ['load-buffer', 'paste-buffer', 'load-buffer', 'paste-buffer', 'load-buffer', 'paste-buffer']);
}));

test('send to a missing session is 404 and the buffer is dropped', () => withApp(async (c) => {
  const { cookie } = await c.login();
  const r = await c.req('POST', '/api/send/ghost', { cookie, body: { text: 'a\nb' } });
  assert.equal(r.status, 404);
  assert.ok(c.calls().some((x) => x.argv[0] === 'delete-buffer'));
}));

test('size limits: body 64 KB, text 32 KB', () => withApp(async (c) => {
  const { cookie } = await c.login();
  await mkSession(c, cookie);
  const big = await c.req('POST', '/api/send/work', { cookie, raw: JSON.stringify({ text: 'x'.repeat(70 * 1024) }), headers: JSON_CT });
  assert.equal(big.status, 413);
  const huge = await c.req('POST', '/api/login', { raw: JSON.stringify({ password: 'x'.repeat(65 * 1024) }), headers: JSON_CT });
  assert.equal(huge.status, 413);
  assert.equal((await c.req('POST', '/api/send/work', { cookie, body: { text: 'a'.repeat(32 * 1024 + 1) } })).status, 413);
  assert.equal((await c.req('POST', '/api/send/work', { cookie, body: { text: 'ắ'.repeat(11000) } })).status, 413); // 33000 bytes
  assert.equal((await c.req('POST', '/api/send/work', { cookie, body: { text: 'a'.repeat(32 * 1024) } })).status, 200);
}));

test('security headers on every response', () => withApp(async (c) => {
  const { cookie } = await c.login();
  const csp = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'";
  const rs = [
    await c.req('GET', '/'), await c.req('GET', '/api/me'), await c.req('GET', '/api/me', { cookie }),
    await c.req('POST', '/api/login', { body: { password: 'x' } }), await c.req('GET', '/nope', { cookie }),
    await c.req('POST', '/api/sessions', { cookie, pc: false }),
  ];
  for (const r of rs) {
    assert.equal(r.headers['content-security-policy'], csp);
    assert.equal(r.headers['x-content-type-options'], 'nosniff');
    assert.equal(r.headers['referrer-policy'], 'no-referrer');
  }
  for (const r of rs.slice(1, 4)) assert.equal(r.headers['cache-control'], 'no-store');
}));

test('SSE: retry, screen event, gone on logout', () => withApp(async (c) => {
  const { cookie } = await c.login();
  await mkSession(c, cookie);
  const { res, req } = await new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port: c.port, path: '/api/stream/work', headers: { Cookie: cookie } }, (res) => resolve({ res, req }));
    req.on('error', reject); req.end();
  });
  assert.equal(res.statusCode, 200);
  assert.match(res.headers['content-type'], /^text\/event-stream/);
  assert.equal(res.headers['cache-control'], 'no-store');
  assert.equal(res.headers['content-encoding'], undefined);
  let buf = '';
  res.setEncoding('utf8');
  res.on('data', (d) => { buf += d; });
  const waitFor = async (s) => {
    for (let i = 0; i < 100 && !buf.includes(s); i++) await new Promise((r) => setTimeout(r, 40));
    assert.ok(buf.includes(s), `timeout waiting for ${s}; got ${buf}`);
  };
  await waitFor('event: screen');
  assert.ok(buf.startsWith('retry: 3000\n\n'));
  const data = JSON.parse(buf.split('event: screen\ndata: ')[1].split('\n')[0]);
  assert.equal(data.text, 'hello world\nline 2');
  await c.req('POST', '/api/logout', { cookie });
  await waitFor('event: gone\ndata: {"reason":"auth"}');
  req.destroy();
  const again = await c.login();
  assert.equal((await c.req('GET', '/api/stream/ghost', { cookie: again.cookie })).status, 404);
  // session deleted -> gone with reason "session"
  const s2 = await openStream(c.port, again.cookie);
  let b2 = ''; s2.res.setEncoding('utf8'); s2.res.on('data', (d) => { b2 += d; });
  assert.ok(await until(() => b2.includes('event: screen')));
  assert.equal((await c.req('DELETE', '/api/sessions/work', { cookie: again.cookie })).status, 200);
  assert.ok(await until(() => b2.includes('event: gone\ndata: {"reason":"session"}')), b2.slice(-200));
  s2.req.destroy();
}));

test('logs hold method, path, status, ms only', () => withApp(async (c) => {
  const secret = 'Mật khẩu bí mật 12345 ắ';
  await c.req('POST', '/api/login', { body: { password: secret } });
  const { cookie, json } = await c.login({ 'X-PC-Client': 'ios' });
  await mkSession(c, cookie);
  await c.req('POST', '/api/send/work', { cookie, body: { text: 'SENT-TEXT-xyz ' + VN, enter: true } });
  await c.req('POST', '/api/send/work', { cookie, body: { text: 'MULTI-xyz\nline', enter: false } });
  const all = c.logs.join('\n');
  for (const s of [secret, PW, 'SENT-TEXT', 'MULTI-xyz', VN, cookie.slice(7), json.token, 'pc_sid']) assert.ok(!all.includes(s), s);
  assert.ok(c.logs.length >= 5);
  for (const l of c.logs) assert.match(l, /^(GET|POST|DELETE) \/\S* \d{3} \d+ms$/);
}));

test('--set-password: reads stdin, writes scrypt hash, generate mode', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pc-pw-'));
  try {
    const cfgDir = path.join(dir, 'cfg');
    const env = { ...process.env, PC_CONFIG_DIR: cfgDir };
    const run = (input) => spawnSync(process.execPath, [SERVER, '--set-password'], { input, env, encoding: 'utf8' });
    const r = run(`${PW}\n`);
    assert.equal(r.status, 0, r.stderr);
    assert.ok(!r.stdout.includes(PW));
    const file = path.join(cfgDir, 'config.json');
    const cfg = JSON.parse(fs.readFileSync(file, 'utf8'));
    assert.equal(cfg.passwordHash.algo, 'scrypt');
    for (const f of ['salt', 'hash', 'N', 'r', 'p']) assert.ok(cfg.passwordHash[f], f);
    assert.ok(cfg.cookieSecret && cfg.projects && cfg.port === 7681);
    if (process.platform !== 'win32') assert.equal(fs.statSync(file).mode & 0o777, 0o600);
    assert.notEqual(run('abc\n').status, 0); // too short
    assert.equal(run('  spaced pass  \r\n').status, 0); // only the line ending is stripped
    {
      const a = createApp({ configDir: cfgDir, log: () => {} });
      const p = await a.listen(0, '127.0.0.1');
      try {
        assert.equal((await request(p, 'POST', '/api/login', { body: { password: '  spaced pass  ' } })).status, 200);
        assert.equal((await request(p, 'POST', '/api/login', { body: { password: 'spaced pass' } })).status, 401);
      } finally { await a.close(); }
    }
    const gen = run('');
    assert.equal(gen.status, 0);
    const pw = /: (\S{24})\s*$/.exec(gen.stdout)?.[1];
    assert.ok(pw, gen.stdout);
    const app = createApp({ configDir: cfgDir, log: () => {} });
    const port = await app.listen(0, '127.0.0.1');
    try {
      assert.equal((await request(port, 'POST', '/api/login', { body: { password: PW } })).status, 401); // replaced
      assert.equal((await request(port, 'POST', '/api/login', { body: { password: pw } })).status, 200);
    } finally { await app.close(); }
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

// every config.json that must be refused at startup and ignored at reload (A3 + round 4 item 1)
const badConfigs = (good) => {
  const ph = good.passwordHash;
  const b = (n) => crypto.randomBytes(n).toString('base64');
  const variants = [
    { passwordHash: undefined }, { passwordHash: null }, { passwordHash: 'x' },
    { passwordHash: { ...ph, algo: 'bcrypt' } }, { passwordHash: { ...ph, algo: undefined } },
    { passwordHash: { ...ph, hash: '' } }, { passwordHash: { ...ph, hash: 'AA==' } }, { passwordHash: { ...ph, hash: b(16) } },
    { passwordHash: { ...ph, hash: ph.hash.replace(/=+$/, '') } }, // non-canonical: padding dropped
    { passwordHash: { ...ph, hash: `${ph.hash.slice(0, 40)}\n${ph.hash.slice(40)}` } }, // non-canonical: newline inside
    { passwordHash: { ...ph, salt: b(8) } }, { passwordHash: { ...ph, salt: ph.salt.replace(/=+$/, '') } },
    { passwordHash: { ...ph, N: 2 ** 30 } }, { passwordHash: { ...ph, N: 2 ** 13 } }, { passwordHash: { ...ph, N: 20000 } }, { passwordHash: { ...ph, N: '16384' } },
    { passwordHash: { ...ph, N: 65536, r: 1, p: 1 } }, // RFC 7914: N must be < 2^(16r)
    { passwordHash: { ...ph, N: 2 ** 20, r: 32 } }, // 128*N*r = 4 GiB > 256 MiB
    { passwordHash: { ...ph, r: 0 } }, { passwordHash: { ...ph, r: 33 } }, { passwordHash: { ...ph, p: 0 } }, { passwordHash: { ...ph, p: 17 } },
    { cookieSecret: 5 }, { cookieSecret: b(16) }, { cookieSecret: b(32).replace(/=+$/, '') }, { cookieSecret: `${b(32)} ` },
    { projects: [] }, { projects: 'x' }, { port: 'x' }, { port: 70000 },
  ];
  return ['{"passwordHash": {"salt": "SEKRET-abc"', '[]', 'null', ...variants.map((v) => JSON.stringify({ ...good, ...v }))];
};

test('startup refuses a missing or malformed config (createApp throws, the process exits 1)', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pc-nopw-'));
  try {
    assert.throws(() => createApp({ configDir: dir, log: () => {} }), /config\.json missing/);
    const good = { passwordHash: PW_HASH, cookieSecret: Buffer.alloc(32, 1).toString('base64'), projects: {} };
    fs.writeFileSync(path.join(dir, 'config.json'), JSON.stringify(good));
    createApp({ configDir: dir, log: () => {} }); // the good one is accepted
    const bad = badConfigs(good);
    for (const text of bad) {
      fs.writeFileSync(path.join(dir, 'config.json'), text);
      assert.throws(() => createApp({ configDir: dir, log: () => {} }), /config\.json/, text);
    }
    fs.writeFileSync(path.join(dir, 'config.json'), bad[0]);
    const r = spawnSync(process.execPath, [SERVER], { env: { ...process.env, PC_CONFIG_DIR: dir, PC_PORT: '0' }, encoding: 'utf8', timeout: 10000 });
    assert.equal(r.status, 1);
    assert.match(r.stderr, /config\.json is not valid JSON/);
    assert.ok(!r.stderr.includes('SEKRET'));
    // scrypt parameters Node would reject or that need too much memory: the process exits 1
    for (const p of [{ N: 65536, r: 1, p: 1 }, { N: 2 ** 20, r: 32 }]) {
      fs.writeFileSync(path.join(dir, 'config.json'), JSON.stringify({ ...good, passwordHash: { ...good.passwordHash, ...p } }));
      const x = spawnSync(process.execPath, [SERVER], { env: { ...process.env, PC_CONFIG_DIR: dir, PC_PORT: '0' }, encoding: 'utf8', timeout: 10000 });
      assert.equal(x.status, 1, JSON.stringify(p));
      assert.match(x.stderr, /passwordHash missing or invalid/);
    }
    // what setPassword writes (hashPassword defaults: N 2^14, r 8, p 1) is accepted
    const d = hashPassword('default params ok');
    assert.deepEqual([d.N, d.r, d.p], [2 ** 14, 8, 1]);
    fs.writeFileSync(path.join(dir, 'config.json'), JSON.stringify({ ...good, passwordHash: d }));
    createApp({ configDir: dir, log: () => {} });
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

// ======================= rework round 1 =======================
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const until = async (fn, ms = 5000) => { const t = Date.now(); while (Date.now() - t < ms) { if (await fn()) return true; await sleep(20); } return false; };
const withEnv = async (env, fn) => {
  const old = {};
  for (const k of Object.keys(env)) { old[k] = process.env[k]; if (env[k] === undefined) delete process.env[k]; else process.env[k] = env[k]; }
  try { return await fn(); } finally { for (const k of Object.keys(old)) { if (old[k] === undefined) delete process.env[k]; else process.env[k] = old[k]; } }
};
const rawHttp = (port, data) => new Promise((resolve) => {
  const s = net.connect(port, '127.0.0.1', () => s.write(data));
  let out = '';
  s.on('data', (d) => { out += d; });
  s.on('close', () => resolve(out));
  s.on('error', () => resolve(out));
  setTimeout(() => s.destroy(), 2000);
});
// open an SSE stream; resolves on the response head (status) with the live req/res
const openStream = (port, cookie, name = 'work') => new Promise((resolve, reject) => {
  const req = http.request({ host: '127.0.0.1', port, path: `/api/stream/${name}`, headers: { Cookie: cookie } }, (res) => resolve({ status: res.statusCode, req, res }));
  req.on('error', (e) => resolve({ status: 0, req, error: e }));
  req.end();
});
const maxOverlap = (calls) => {
  const ev = calls.flatMap((x) => [[x.t0, 1], [x.t1, -1]]).sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  let cur = 0, max = 0;
  for (const [, d] of ev) { cur += d; max = Math.max(max, cur); }
  return max;
};

test('malformed request targets get 400 and the process survives', () => withApp(async (c) => {
  for (const target of ['//', '//%', '//x:bad/', '//[']) {
    const out = await rawHttp(c.port, `GET ${target} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n`);
    assert.match(out, /^HTTP\/1\.1 400 /, target);
  }
  const garbage = await rawHttp(c.port, 'GET\r\n\r\n');
  assert.match(garbage, /^HTTP\/1\.1 400 /);
  const ok = await c.req('GET', '/');
  assert.equal(ok.status, 200);
  assert.equal(ok.text, 'fcoding ok');
}));

test('expiry boundary for cookie and Bearer (opts.now)', async () => {
  let t = 1_700_000_000_000;
  await withApp(async (c) => {
    const { cookie, json } = await c.login({ 'X-PC-Client': 'ios' });
    const auth = { Authorization: `Bearer ${json.token}` };
    const month = 30 * 24 * 3600 * 1000;
    t += month - 1;
    assert.equal((await c.req('GET', '/api/me', { cookie })).status, 200);
    assert.equal((await c.req('GET', '/api/me', { headers: auth })).status, 200);
    t += 1; // exactly at expiry
    assert.equal((await c.req('GET', '/api/me', { cookie })).status, 401);
    assert.equal((await c.req('GET', '/api/me', { headers: auth })).status, 401);
  }, { now: () => t });
});

test('10 parallel bad logins from one IP: exactly 5 x 401, 5 x 429', () => withApp(async (c) => {
  const xf = { 'X-Forwarded-For': '5.5.5.5' };
  const rs = await Promise.all(Array.from({ length: 10 }, (_, i) => c.req('POST', '/api/login', { body: { password: `bad-${i}` }, headers: xf })));
  const n = (s) => rs.filter((r) => r.status === s).length;
  assert.equal(n(401), 5);
  assert.equal(n(429), 5);
  // the guesses were never verified past the limit, and a good password is blocked too
  assert.equal((await c.req('POST', '/api/login', { body: { password: PW }, headers: xf })).status, 429);
}));

test('password change drops every session without a restart, and after one', async () => {
  const c = await boot();
  try {
    const old = await c.login({ 'X-PC-Client': 'ios' });
    const before = JSON.parse(fs.readFileSync(path.join(c.configDir, 'config.json'), 'utf8')).cookieSecret;
    const env = { ...process.env, PC_CONFIG_DIR: c.configDir };
    const NEW = 'brand new password 42';
    const r = spawnSync(process.execPath, [SERVER, '--set-password'], { input: `${NEW}\n`, env, encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    const after = JSON.parse(fs.readFileSync(path.join(c.configDir, 'config.json'), 'utf8'));
    assert.notEqual(after.cookieSecret, before); // rotated
    assert.deepEqual(after.projects, { alpha: ABS, 'my.proj': ABS }); // other settings kept
    // running server: no restart
    assert.equal((await c.req('GET', '/api/me', { cookie: old.cookie })).status, 401);
    assert.equal((await c.req('GET', '/api/me', { headers: { Authorization: `Bearer ${old.json.token}` } })).status, 401);
    assert.equal((await c.req('POST', '/api/login', { body: { password: PW } })).status, 401);
    const fresh = await c.req('POST', '/api/login', { body: { password: NEW } });
    assert.equal(fresh.status, 200);
    const freshCookie = fresh.headers['set-cookie'][0].split(';')[0];
    assert.equal((await c.req('GET', '/api/me', { cookie: freshCookie })).status, 200);
    // the old token must not come back when the server restarts
    await c.app.close();
    const app2 = createApp({ configDir: c.configDir, tmux: [process.execPath, FAKE], log: () => {} });
    const port = await app2.listen(0, '127.0.0.1');
    assert.equal((await request(port, 'GET', '/api/me', { cookie: old.cookie })).status, 401);
    assert.equal((await request(port, 'GET', '/api/me', { cookie: freshCookie })).status, 401); // memory only
    await app2.close();
  } finally { fs.rmSync(c.root, { recursive: true, force: true }); await c.app.close().catch(() => {}); }
});

test('config dir hygiene: modes repaired, symlinks refused', async (t) => {
  if (process.platform === 'win32') return t.skip('POSIX modes');
  const c = await boot();
  try {
    await c.app.close();
    fs.chmodSync(c.configDir, 0o777); fs.chmodSync(path.join(c.configDir, 'config.json'), 0o666);
    const app2 = createApp({ configDir: c.configDir, log: () => {} });
    assert.equal(fs.statSync(c.configDir).mode & 0o777, 0o700);
    assert.equal(fs.statSync(path.join(c.configDir, 'config.json')).mode & 0o777, 0o600);
    const port = await app2.listen(0, '127.0.0.1');
    const r = await request(port, 'POST', '/api/login', { body: { password: PW } });
    assert.equal(r.status, 200);
    await app2.close();
    const link = path.join(c.root, 'link');
    fs.symlinkSync(c.configDir, link);
    assert.throws(() => createApp({ configDir: link, log: () => {} }), /unsafe config path/);
    fs.rmSync(link);
    fs.renameSync(path.join(c.configDir, 'config.json'), path.join(c.root, 'real.json'));
    fs.symlinkSync(path.join(c.root, 'real.json'), path.join(c.configDir, 'config.json'));
    assert.throws(() => createApp({ configDir: c.configDir, log: () => {} }), /unsafe config path/);
  } finally { fs.rmSync(c.root, { recursive: true, force: true }); }
});

test('screen trim removes trailing blank lines only', () => withApp(async (c) => {
  const { cookie } = await c.login();
  await mkSession(c, cookie);
  const get = async (screen) => withEnv({ FAKE_TMUX_SCREEN: JSON.stringify(screen) }, async () => (await c.req('GET', '/api/screen/work', { cookie })).json.text);
  assert.equal(await get('foo   \n   \n\t\n\n'), 'foo   '); // spaces on the last real line stay
  assert.equal(await get('  indented\nx  \n\n'), '  indented\nx  ');
  assert.equal(await get('   \n\n'), '');
}));

test('send-keys path: trailing ";" is escaped for tmux, nothing else is touched', () => withApp(async (c) => {
  const { cookie } = await c.login();
  await mkSession(c, cookie);
  const cases = [
    ['let x = 1;', 'let x = 1\\;'], ['a;', 'a\\;'], ['a\\;', 'a\\\\;'], [';', '\\;'], [';;', ';\\;'],
    ['x ; kill-server', 'x ; kill-server'], ['x \\; y', 'x \\; y'], ['$(id) `id` ~ #{pane_id}', '$(id) `id` ~ #{pane_id}'],
    ['-l', '-l'], ['Ắ;', 'Ắ\\;'],
  ];
  for (const [text, arg] of cases) {
    assert.equal((await c.req('POST', '/api/send/work', { cookie, body: { text, enter: false } })).status, 200);
    assert.deepEqual(c.calls().at(-1).argv, ['send-keys', '-t', '=work:', '-l', '--', arg], JSON.stringify(text));
  }
  // multi-line text ending in ";" goes through the buffer untouched
  await c.req('POST', '/api/send/work', { cookie, body: { text: 'a\nb;', enter: false } });
  const lb = c.calls().filter((x) => x.argv[0] === 'load-buffer').at(-1);
  assert.equal(Buffer.from(lb.stdin, 'base64').toString('utf8'), 'a\nb;');
}));

test('SSE admission: at most 50 streams, reserved before any await, all capacity released', () => withApp(async (c) => {
  const { cookie } = await c.login();
  await mkSession(c, cookie);
  // one at a time: the first 50 are admitted, the rest are 503 busy (stream limit)
  const rs = [];
  for (let i = 0; i < 55; i++) rs.push(await openStream(c.port, cookie));
  assert.deepEqual(rs.map((r) => r.status), [...Array(50).fill(200), ...Array(5).fill(503)]);
  assert.equal(c.app.stats().streams, 50);
  for (const r of rs) { r.res?.resume(); r.req.destroy(); }
  assert.ok(await until(() => c.app.stats().streams === 0), 'streams not released');
  // a burst never holds more than 50 (a stream whose first capture finds no free read slot is 503), all released
  let peak = 0; const iv = setInterval(() => { peak = Math.max(peak, c.app.stats().streams); }, 2);
  const burst = await Promise.all(Array.from({ length: 80 }, () => openStream(c.port, cookie)));
  clearInterval(iv);
  assert.ok(peak <= 50, `peak=${peak}`);
  assert.ok(burst.every((r) => r.status === 200 || r.status === 503));
  for (const r of burst) { r.res?.resume(); r.req.destroy(); }
  assert.ok(await until(() => c.app.stats().streams === 0 && c.app.stats().running === 0));
}, { pollMs: 60000 }));

test('SSE: early-aborted opens release their slot (60 aborts, then 50 fresh streams fit)', () => withApp(async (c) => {
  const { cookie } = await c.login();
  await mkSession(c, cookie);
  await withEnv({ FAKE_TMUX_DELAY_MS: '150' }, async () => {
    const reqs = Array.from({ length: 60 }, () => {
      const req = http.request({ host: '127.0.0.1', port: c.port, path: '/api/stream/work', headers: { Cookie: cookie } });
      req.on('error', () => {}); req.end();
      return req;
    });
    assert.ok(await until(() => c.app.stats().streams > 0, 3000), 'streams were never reserved');
    for (const r of reqs) r.destroy(); // abort while the first capture is still in flight
    assert.ok(await until(() => c.app.stats().streams === 0), `leaked: ${JSON.stringify(c.app.stats())}`);
  });
  assert.ok(await until(() => c.app.stats().running === 0));
  const rs = [];
  for (let i = 0; i < 50; i++) rs.push(await openStream(c.port, cookie));
  assert.equal(rs.filter((r) => r.status === 200).length, 50);
  for (const r of rs) { r.res?.resume(); r.req.destroy(); }
  assert.ok(await until(() => c.app.stats().streams === 0 && c.app.stats().running === 0));
}, { pollMs: 60000 }));

test('SSE backpressure: polling pauses while the client does not read, resumes on drain', () => withApp(async (c) => {
  const { cookie } = await c.login();
  await mkSession(c, cookie);
  await withEnv({ FAKE_TMUX_BIG: '1' }, async () => {
    const s = await openStream(c.port, cookie);
    assert.equal(s.status, 200);
    s.res.pause(); // a stalled phone
    const captures = () => c.calls().filter((x) => x.argv[0] === 'capture-pane').length;
    let prev = -1;
    assert.ok(await until(async () => { const n = captures(); const same = n === prev; prev = n; await sleep(400); return same && n > 2; }, 15000), 'polling never paused');
    const frozen = captures();
    await sleep(600);
    assert.equal(captures(), frozen); // no polling while the socket is full
    assert.equal(c.app.stats().streams, 1);
    s.res.resume(); // phone reads again
    assert.ok(await until(() => captures() > frozen, 5000), 'polling did not resume');
    s.req.destroy();
    assert.ok(await until(() => c.app.stats().streams === 0));
  });
}, { pollMs: 20 }));

test('SSE backpressure: a consumer that stays stuck is dropped after the drain timeout', () => withApp(async (c) => {
  const { cookie } = await c.login();
  await mkSession(c, cookie);
  await withEnv({ FAKE_TMUX_BIG: '1' }, async () => {
    const s = await openStream(c.port, cookie);
    assert.equal(s.status, 200);
    s.res.pause();
    assert.ok(await until(() => c.app.stats().streams === 0, 20000), 'stuck stream was not destroyed');
    s.req.destroy();
  });
}, { pollMs: 20, drainTimeoutMs: 400 }));

test('mutation queue: at most 20 waiting (503 busy); reads capped at 7 children and never queued', () => withApp(async (c) => {
  const { cookie } = await c.login();
  await mkSession(c, cookie);
  await withEnv({ FAKE_TMUX_DELAY_MS: '100' }, async () => {
    const before = c.calls().length;
    const rs = await Promise.all(Array.from({ length: 30 }, (_, i) => c.req('POST', '/api/send/work', { cookie, body: { text: `m${i}`, enter: false } })));
    const ok = rs.filter((r) => r.status === 200).length; const busy = rs.filter((r) => r.status === 503);
    assert.equal(ok + busy.length, 30);
    assert.ok(busy.length >= 8 && ok >= 15, `ok=${ok} busy=${busy.length}`);
    assert.deepEqual(busy[0].json, { error: 'busy' });
    assert.equal(c.app.stats().waiting, 0);
    assert.equal(c.calls().length - before, ok); // only admitted sends reached tmux
  });
  // concurrent tmux children never exceed 8
  await withEnv({ FAKE_TMUX_DELAY_MS: '120' }, async () => {
    const before = c.calls().length;
    let peak = 0; const iv = setInterval(() => { peak = Math.max(peak, c.app.stats().running); }, 3);
    const rs = await Promise.all(Array.from({ length: 30 }, () => c.req('GET', '/api/screen/work', { cookie })));
    clearInterval(iv);
    assert.ok(peak >= 2 && peak <= 7, `peak=${peak}`);
    assert.ok(maxOverlap(c.calls().slice(before)) <= 7);
    assert.ok(rs.some((r) => r.status === 503) && rs.some((r) => r.status === 200));
    assert.ok(rs.every((r) => r.status === 200 || (r.status === 503 && r.json.error === 'busy')));
  });
}));

test('queued sends of a closed request are cancelled; keys keep order behind text', () => withApp(async (c) => {
  const { cookie } = await c.login();
  await mkSession(c, cookie);
  await withEnv({ FAKE_TMUX_DELAY_MS: '250' }, async () => {
    const post = (text) => {
      const body = JSON.stringify({ text, enter: false });
      const req = http.request({ host: '127.0.0.1', port: c.port, method: 'POST', path: '/api/send/work', headers: { ...JSON_CT, 'X-PC': '1', Cookie: cookie, 'Content-Length': Buffer.byteLength(body) } });
      req.on('error', () => {}); req.end(body);
      return req;
    };
    const a = post('AAA');
    await sleep(60);
    const b = post('BBB'); // queued behind A
    await sleep(60);
    b.destroy(); // the phone gave up
    const keyRes = c.req('POST', '/api/key/work', { cookie, body: { key: 'Enter' } }); // queued behind A (and the dead B)
    await keyRes;
    a.destroy();
  });
  await sleep(300);
  const sends = c.calls().filter((x) => x.argv[0] === 'send-keys');
  assert.ok(sends.some((x) => x.argv.includes('AAA')));
  assert.ok(!sends.some((x) => x.argv.includes('BBB')), 'cancelled send still ran');
  const iA = sends.findIndex((x) => x.argv.includes('AAA'));
  const iK = sends.findIndex((x) => x.argv.length === 4 && x.argv[3] === 'Enter');
  assert.ok(iA >= 0 && iK > iA, 'key ran before the text it was queued behind');
  assert.ok(sends[iA].t1 <= sends[iK].t0 + 5, 'text and key overlapped');
  assert.equal(c.app.stats().waiting, 0);
}));

// ======================= A3 (round 3) =======================
// a POST whose request object stays in hand (to disconnect it); done resolves {status, json} or {status: 0}
const rawPost = (port, p, body, cookie) => {
  const data = JSON.stringify(body);
  const req = http.request({ host: '127.0.0.1', port, method: 'POST', path: p, headers: { ...JSON_CT, 'X-PC': '1', Cookie: cookie, 'Content-Length': Buffer.byteLength(data) } });
  const done = new Promise((resolve) => {
    req.on('response', (res) => { let t = ''; res.on('data', (d) => { t += d; }); res.on('end', () => { let j; try { j = JSON.parse(t); } catch {} resolve({ status: res.statusCode, json: j }); }); });
    req.on('error', () => resolve({ status: 0 }));
  });
  return { req, done, data };
};
const victimRan = (c) => c.calls().some((x) => x.argv.some((a) => String(a).includes('VICTIM')) || (x.argv[0] === 'send-keys' && x.argv.at(-1) === 'Enter'));
const rotate = (c) => {
  const f = path.join(c.configDir, 'config.json');
  const cfg = JSON.parse(fs.readFileSync(f, 'utf8'));
  cfg.cookieSecret = crypto.randomBytes(32).toString('base64');
  writePrivate(f, JSON.stringify(cfg));
};

for (const fill of [false, true]) {
  for (const action of ['revoke', 'expire', 'rotate', 'disconnect']) {
    test(`gate: ${action} while a job waits${fill ? ' and all 8 children are busy' : ''} -> no later child spawns`, async () => {
      let t = 1_700_000_000_000;
      await withApp(async (c) => {
        const victim = await c.login(); // logged in first: expires first
        t += MONTH - 2000;
        const owner = await c.login();
        await mkSession(c, owner.cookie);
        await withEnv({ FAKE_TMUX_DELAY_MS: '500' }, async () => {
          const blocker = c.req('POST', '/api/send/work', { cookie: owner.cookie, body: { text: 'BLOCKER', enter: false } });
          assert.ok(await until(() => c.app.stats().running === 1 && c.app.stats().active, 3000));
          let reads = [];
          if (fill) {
            reads = [...Array.from({ length: 3 }, () => c.req('GET', '/api/screen/work', { cookie: owner.cookie })), c.req('GET', '/api/sessions', { cookie: owner.cookie })];
            assert.ok(await until(() => c.app.stats().running === 8, 3000), JSON.stringify(c.app.stats()));
            const extra = await c.req('GET', '/api/screen/work', { cookie: owner.cookie });
            assert.equal(extra.status, 503); // reads never queue
            assert.deepEqual(extra.json, { error: 'busy' });
          }
          const v = rawPost(c.port, '/api/send/work', { text: 'VICTIM', enter: true }, victim.cookie);
          v.req.end(v.data);
          assert.ok(await until(() => c.app.stats().waiting === 1, 3000), 'victim job never queued');
          if (action === 'revoke') assert.equal((await c.req('POST', '/api/logout', { cookie: victim.cookie })).status, 200);
          if (action === 'expire') t += 3000;
          if (action === 'rotate') rotate(c);
          if (action === 'disconnect') {
            v.req.destroy();
            assert.ok(await until(() => c.app.stats().waiting === 0, 300), 'disconnected job not removed promptly');
            assert.equal(c.app.stats().active, true); // removed while the blocker still runs
          }
          assert.equal((await blocker).status, 200);
          await Promise.all(reads);
          const r = await v.done;
          if (action !== 'disconnect') assert.equal(r.status, 401);
          assert.ok(await until(() => !c.app.stats().active && c.app.stats().waiting === 0 && c.app.stats().running === 0));
        });
        await sleep(150);
        assert.ok(!victimRan(c), 'a child was spawned for the revoked/expired/rotated/disconnected job');
      }, { now: () => t });
    });
  }
}

test('partial body, then logout -> 401 and no session is created', () => withApp(async (c) => {
  const { cookie } = await c.login();
  const v = rawPost(c.port, '/api/sessions', { name: 'late', project: 'alpha', harness: 'shell' }, cookie);
  v.req.write(v.data.slice(0, 10));
  await sleep(100);
  assert.equal((await c.req('POST', '/api/logout', { cookie })).status, 200);
  v.req.end(v.data.slice(10));
  assert.equal((await v.done).status, 401);
  assert.equal(c.calls().length, 0);
}));

test('two simultaneous /api/open for one project: both 200, same name, created once', () => withApp(async (c) => {
  const { cookie } = await c.login();
  await withEnv({ FAKE_TMUX_DELAY_MS: '100' }, async () => {
    const rs = await Promise.all([1, 2].map(() => c.req('POST', '/api/open', { cookie, body: { project: 'alpha', harness: 'omp' } })));
    assert.deepEqual(rs.map((r) => r.status), [200, 200]);
    assert.deepEqual(rs.map((r) => r.json.name), ['alpha-omp', 'alpha-omp']);
    assert.deepEqual(rs.map((r) => r.json.created).sort(), [false, true]);
  });
}));

test('harness that exits at once: 500 harness_exited for /api/open and POST /api/sessions', () => withApp(async (c) => {
  const { cookie } = await c.login();
  await withEnv({ FAKE_TMUX_EXIT: '1' }, async () => {
    const o = await c.req('POST', '/api/open', { cookie, body: { project: 'alpha', harness: 'omp' } });
    assert.equal(o.status, 500);
    assert.deepEqual(o.json, { error: 'harness_exited' });
    const s = await mkSession(c, cookie, 'dies');
    assert.equal(s.status, 500);
    assert.deepEqual(s.json, { error: 'harness_exited' });
  });
}));

test('text + Enter job cancelled between stages: no Enter is sent', () => withApp(async (c) => {
  const { cookie } = await c.login();
  await mkSession(c, cookie);
  // pasted text: cancelled during the paste -> Enter delay
  const a = rawPost(c.port, '/api/send/work', { text: 'VICTIM line 1\nline 2', enter: true }, cookie);
  a.req.end(a.data);
  assert.ok(await until(() => c.calls().some((x) => x.argv[0] === 'paste-buffer')));
  a.req.destroy();
  await sleep(700);
  // typed text: cancelled while send-keys -l runs
  await withEnv({ FAKE_TMUX_DELAY_MS: '300' }, async () => {
    const b = rawPost(c.port, '/api/send/work', { text: 'VICTIM2', enter: true }, cookie);
    b.req.end(b.data);
    assert.ok(await until(() => c.app.stats().running === 1 && c.app.stats().active, 3000));
    b.req.destroy();
    assert.ok(await until(() => !c.app.stats().active && c.app.stats().running === 0));
  });
  await sleep(150);
  assert.ok(c.calls().some((x) => x.argv.includes('VICTIM2'))); // the first stage was already dispatched
  assert.ok(!c.calls().some((x) => x.argv[0] === 'send-keys' && x.argv.at(-1) === 'Enter'), 'Enter sent after cancel');
}, { pasteEnterDelayMs: 500 }));

test('mixed traffic: mutations run in FIFO order, <= 20 wait, <= 8 children, reads 503 when full', () => withApp(async (c) => {
  const { cookie } = await c.login();
  await mkSession(c, cookie);
  const before = c.calls().length;
  await withEnv({ FAKE_TMUX_DELAY_MS: '150' }, async () => {
    let peakWait = 0, peakRun = 0;
    const iv = setInterval(() => { const s = c.app.stats(); peakWait = Math.max(peakWait, s.waiting); peakRun = Math.max(peakRun, s.running); }, 2);
    const muts = []; const reads = [];
    for (let i = 0; i < 30; i++) {
      muts.push(c.req('POST', '/api/send/work', { cookie, body: { text: `q${i}`, enter: false } }));
      reads.push(c.req('GET', i % 3 ? '/api/screen/work' : '/api/sessions', { cookie }));
      await sleep(8);
    }
    const mr = await Promise.all(muts); const rr = await Promise.all(reads);
    clearInterval(iv);
    assert.ok(peakWait <= 20, `peakWait=${peakWait}`);
    assert.ok(peakRun <= 8, `peakRun=${peakRun}`);
    assert.ok(mr.some((r) => r.status === 503), 'queue never overflowed');
    assert.ok(mr.every((r) => r.status === 200 || (r.status === 503 && r.json.error === 'busy')));
    assert.ok(rr.some((r) => r.status === 503), 'reads never hit the cap');
    assert.ok(rr.every((r) => r.status === 200 || (r.status === 503 && r.json.error === 'busy')));
    const calls = c.calls().slice(before);
    assert.ok(maxOverlap(calls) <= 8, `overlap=${maxOverlap(calls)}`);
    const ran = calls.filter((x) => x.argv[0] === 'send-keys').sort((x, y) => x.t0 - y.t0).map((x) => Number(x.argv.at(-1).slice(1)));
    const ok = mr.map((r, i) => (r.status === 200 ? i : -1)).filter((i) => i >= 0);
    assert.deepEqual(ran, ok); // exactly the admitted ones, in arrival order
  });
}));

test('SSE: a ping that hits backpressure during a capture, then drain -> the latest screen still arrives', () => withApp(async (c) => {
  const { cookie } = await c.login();
  await mkSession(c, cookie);
  const file = path.join(c.root, 'screen.txt');
  fs.writeFileSync(file, 'SCREEN-AAA\n');
  let sres = null;
  c.app.server.on('request', (req, res) => { if (req.url.startsWith('/api/stream/')) sres = res; });
  await withEnv({ FAKE_TMUX_SCREEN_FILE: file }, async () => {
    const s = await openStream(c.port, cookie);
    let buf = ''; s.res.setEncoding('utf8'); s.res.on('data', (d) => { buf += d; });
    assert.ok(await until(() => buf.includes('SCREEN-AAA')), `status=${s.status} buf=${buf.slice(0, 300)}`);
    const orig = sres.write.bind(sres);
    let armed = false, hit = false;
    sres.write = (chunk, ...rest) => {
      const r = orig(chunk, ...rest);
      if (armed && String(chunk).startsWith(': ping')) { armed = false; hit = true; return false; } // socket "full"
      return r;
    };
    fs.writeFileSync(file, 'SCREEN-BBB\n');
    await withEnv({ FAKE_TMUX_DELAY_MS: '200' }, async () => {
      armed = true;
      assert.ok(await until(() => hit, 3000), 'no ping');
      await sleep(600); // a capture of BBB finished while paused and was not handed to write()
    });
    assert.ok(!buf.includes('SCREEN-BBB'), 'event written while paused');
    sres.emit('drain'); // the phone reads again; the screen does not change any more
    assert.ok(await until(() => buf.includes('SCREEN-BBB'), 3000), 'latest screen lost after drain');
    s.req.destroy();
    assert.ok(await until(() => c.app.stats().streams === 0));
  });
}, { pollMs: 30, pingMs: 60 }));

test('screen trim is linear: 2000 lines x 300 spaces < 50 ms and correct', () => {
  const blank = `${' '.repeat(300)}\n`.repeat(2000);
  const t0 = performance.now();
  const out = trimScreen(`top  \n${blank}`);
  const dt = performance.now() - t0;
  assert.equal(out, 'top  ');
  assert.ok(dt < 50, `${dt} ms`);
  assert.equal(trimScreen(blank), '');
  assert.equal(trimScreen(`a\n${blank}b`), `a\n${blank}b`);
  assert.equal(trimScreen('x\t \n \t\n'), 'x\t ');
  assert.equal(trimScreen(''), '');
});

let t = 1_700_000_000_000;
test('malformed config at reload: the previous one stays; a repaired one is picked up', () => withApp(async (c) => {
  const { cookie } = await c.login();
  const f = path.join(c.configDir, 'config.json');
  const good = fs.readFileSync(f, 'utf8');
  const cfg = JSON.parse(good);
  for (const text of badConfigs(cfg)) {
    fs.writeFileSync(f, text);
    t += 3600 * 1000; // stay under the 30/hour global login limit
    assert.equal((await c.req('GET', '/api/me', { cookie })).status, 200, text);
    assert.equal((await c.req('POST', '/api/login', { body: { password: 'wrong password' } })).status, 401, text); // e.g. hash "" must not match everything
    assert.equal((await c.req('POST', '/api/login', { body: { password: PW } })).status, 200, text); // old config, never a crash
  }
  assert.equal((await c.req('POST', '/api/login', { body: { password: PW } })).status, 200); // the previous config still rules
  assert.ok(c.logs.some((l) => l.startsWith('config reload failed')));
  assert.ok(!c.logs.join('\n').includes('SEKRET'));
  // a projects-only edit keeps the logins
  fs.writeFileSync(f, JSON.stringify({ ...cfg, projects: { beta: ABS } }));
  assert.equal((await c.req('GET', '/api/me', { cookie })).status, 200);
  assert.deepEqual((await c.req('GET', '/api/meta', { cookie })).json.projects, ['beta']);
  // a repaired file with a new secret drops every session
  fs.writeFileSync(f, JSON.stringify({ ...cfg, cookieSecret: crypto.randomBytes(32).toString('base64') }));
  assert.equal((await c.req('GET', '/api/me', { cookie })).status, 401);
  assert.equal((await c.req('POST', '/api/login', { body: { password: PW } })).status, 200);
}, { now: () => t }));

// ======================= round 4 =======================
test('--set-password validates the whole new config: invalid port -> exit 1, nothing written, running server unchanged', () => withApp(async (c) => {
  const { cookie } = await c.login();
  const f = path.join(c.configDir, 'config.json');
  const cfg = JSON.parse(fs.readFileSync(f, 'utf8'));
  fs.writeFileSync(f, JSON.stringify({ ...cfg, port: 'x' })); // a bad edit the running server ignores
  assert.equal((await c.req('GET', '/api/me', { cookie })).status, 200);
  const before = fs.readFileSync(f);
  const r = spawnSync(process.execPath, [SERVER, '--set-password'], { input: 'another password 1\n', env: { ...process.env, PC_CONFIG_DIR: c.configDir }, encoding: 'utf8' });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /port invalid/);
  assert.ok(!r.stderr.includes(cfg.cookieSecret) && !r.stdout.includes('another password'));
  assert.ok(fs.readFileSync(f).equals(before), 'config.json changed');
  assert.deepEqual(fs.readdirSync(c.configDir), ['config.json']); // no tmp file left
  assert.equal((await c.req('GET', '/api/me', { cookie })).status, 200);
  assert.equal((await c.req('POST', '/api/login', { body: { password: PW } })).status, 200);
  assert.equal((await c.req('POST', '/api/login', { body: { password: 'another password 1' } })).status, 401);
}));

test('writePrivate removes its tmp file when the rename fails', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pc-wp-'));
  const rename = fs.renameSync;
  try {
    fs.writeFileSync(path.join(dir, 'config.json'), 'old');
    fs.renameSync = () => { throw Object.assign(new Error('EIO'), { code: 'EIO' }); };
    assert.throws(() => writePrivate(path.join(dir, 'config.json'), 'new'), /EIO/);
    fs.renameSync = rename;
    assert.deepEqual(fs.readdirSync(dir), ['config.json']);
    assert.equal(fs.readFileSync(path.join(dir, 'config.json'), 'utf8'), 'old');
  } finally { fs.renameSync = rename; fs.rmSync(dir, { recursive: true, force: true }); }
});

test('rotation while scrypt runs: that login is 401 without Set-Cookie, the next one is 200', () => withApp(async (c) => {
  const f = path.join(c.configDir, 'config.json');
  const cfg = JSON.parse(fs.readFileSync(f, 'utf8'));
  writePrivate(f, JSON.stringify({ ...cfg, passwordHash: hashPassword(PW, { N: 2 ** 17 }) })); // slow hash: a wide window
  assert.equal((await c.req('GET', '/api/me')).status, 401); // picks the new hash up
  const t0 = Date.now();
  const pending = c.req('POST', '/api/login', { body: { password: PW } });
  await sleep(60);
  rotate(c); // new cookie secret while the password is being hashed
  const r = await pending;
  assert.ok(Date.now() - t0 > 60);
  assert.equal(r.status, 401);
  assert.equal(r.headers['set-cookie'], undefined);
  const ok = await c.req('POST', '/api/login', { body: { password: PW } });
  assert.equal(ok.status, 200);
  assert.ok(ok.headers['set-cookie']);
}));

test('harness that exits 0.2 s after start: 500 harness_exited (has-session after 400 ms)', () => withApp(async (c) => {
  const { cookie } = await c.login();
  await withEnv({ FAKE_TMUX_EXIT_AFTER_MS: '200' }, async () => {
    const o = await c.req('POST', '/api/open', { cookie, body: { project: 'alpha', harness: 'omp' } });
    assert.equal(o.status, 500);
    assert.deepEqual(o.json, { error: 'harness_exited' });
    const s = await mkSession(c, cookie, 'late');
    assert.deepEqual([s.status, s.json], [500, { error: 'harness_exited' }]);
  });
  const hs = c.calls().filter((x) => x.argv[0] === 'has-session');
  assert.deepEqual(hs.at(-1).argv, ['has-session', '-t', '=late']);
  const ns = c.calls().find((x) => x.argv[0] === 'new-session' && x.argv[3] === 'late');
  assert.ok(hs.at(-1).t0 - ns.t1 >= 350, 'has-session ran before the 400 ms wait');
  assert.equal((await mkSession(c, cookie, 'stays')).status, 201); // a harness that keeps running is fine
}));

test('harness that dies during metadata: set-option 404 -> 500 harness_exited, no has-session', () => withApp(async (c) => {
  const { cookie } = await c.login();
  await withEnv({ FAKE_TMUX_EXIT_AT_OPTION: '@pc_harness' }, async () => {
    const o = await c.req('POST', '/api/open', { cookie, body: { project: 'alpha', harness: 'omp' } });
    assert.deepEqual([o.status, o.json], [500, { error: 'harness_exited' }]);
    const s = await mkSession(c, cookie, 'meta');
    assert.deepEqual([s.status, s.json], [500, { error: 'harness_exited' }]);
  });
  const calls = c.calls();
  assert.deepEqual(calls.filter((x) => x.argv[0] === 'set-option').map((x) => x.argv.at(-2)), ['@pc_project', '@pc_harness', '@pc_project', '@pc_harness']);
  assert.ok(!calls.some((x) => x.argv[0] === 'has-session' || x.argv[0] === 'kill-session'));
}));

test('screen reads take both read slots or none (no half-spawned capture)', () => withApp(async (c) => {
  const { cookie } = await c.login();
  await mkSession(c, cookie);
  const before = c.calls().length;
  await withEnv({ FAKE_TMUX_DELAY_MS: '500' }, async () => {
    const three = Array.from({ length: 3 }, () => c.req('GET', '/api/screen/work', { cookie }));
    assert.ok(await until(() => c.app.stats().reads === 6, 3000));
    const r = await c.req('GET', '/api/screen/work', { cookie }); // only 1 slot left
    assert.deepEqual([r.status, r.json], [503, { error: 'busy' }]);
    assert.equal(c.app.stats().reads, 6);
    const ls = c.req('GET', '/api/sessions', { cookie }); // a one-slot read still fits
    assert.equal((await ls).status, 200);
    assert.deepEqual((await Promise.all(three)).map((x) => x.status), [200, 200, 200]);
  });
  await sleep(100);
  const calls = c.calls().slice(before);
  assert.equal(calls.filter((x) => x.argv[0] === 'capture-pane').length, 3);
  assert.equal(calls.filter((x) => x.argv[0] === 'display-message').length, 3);
}));

test('SSE data lines escape U+2028, U+2029 and U+0085 and still parse to the same text', () => withApp(async (c) => {
  const { cookie } = await c.login();
  await mkSession(c, cookie);
  const file = path.join(c.root, 'screen.txt');
  const text = 'a\u2028b\u2029c\u0085d ắ';
  fs.writeFileSync(file, `${text}\n`);
  let buf = '';
  await withEnv({ FAKE_TMUX_SCREEN_FILE: file }, async () => {
    const s = await openStream(c.port, cookie);
    s.res.setEncoding('utf8'); s.res.on('data', (d) => { buf += d; });
    assert.ok(await until(() => buf.includes('event: screen')));
    s.req.destroy();
  });
  const line = buf.split('\n').find((l) => l.startsWith('data: {'));
  for (const ch of ['\u2028', '\u2029', '\u0085']) assert.ok(!buf.includes(ch), `raw U+${ch.charCodeAt(0).toString(16)}`);
  assert.ok(line.includes('\\u2028') && line.includes('\\u2029') && line.includes('\\u0085'));
  assert.equal(JSON.parse(line.slice(6)).text, text);
}));
