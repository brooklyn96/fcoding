import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync, execFile, spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import net from 'node:net';
import crypto from 'node:crypto';
import { createApp, parseConfig, writePrivate, trimScreen, sgrOnly, trimAnsiScreen, adminRequest, adminPath, KEYS, stateOf, previewOf, summarize, menuOf, WAIT_PATTERNS, parseShortstat, acquireInstanceLock } from '../server.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const FAKE = path.join(here, 'fake-tmux.mjs');
const SERVER = path.join(here, '..', 'server.mjs');
const VN = 'Xin chào, tiếng Việt có dấu: ắ ẫ ợ ữ';
const ABS = path.resolve(os.tmpdir());
const HOME = os.homedir();
const LAUNCH = `env LANG=C.UTF-8 LC_ALL=C.UTF-8 'PATH=${HOME}/.local/bin:${HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin' `;

async function boot(opts = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'pc-test-'));
  const fakeDir = path.join(root, 'fake'); fs.mkdirSync(fakeDir);
  const configDir = path.join(root, 'cfg'); fs.mkdirSync(configDir);
  fs.writeFileSync(path.join(configDir, 'config.json'), JSON.stringify({
    cookieSecret: Buffer.alloc(32, 7).toString('base64'),
    projects: { alpha: ABS, 'my.proj': ABS }, port: 7681,
  }));
  process.env.FAKE_TMUX_DIR = fakeDir;
  const logs = [];
  const app = createApp({ configDir, tmux: [process.execPath, FAKE], log: (l) => logs.push(l), pollMs: 40, pasteEnterDelayMs: 0, ...opts });
  const port = await app.listen(0, '127.0.0.1');
  const ctx = { app, port, logs, root, configDir };
  ctx.req = (method, p, o = {}) => request(port, method, p, o);
  // pair a device the way the app does: --pair over admin.sock, then POST /api/pair
  ctx.login = async (headers = {}, name = 'test') => {
    const p = await adminRequest(configDir, { cmd: 'pair', name });
    const r = await ctx.req('POST', '/api/pair', { body: { code: p.code }, headers });
    assert.equal(r.status, 200, JSON.stringify(r.json));
    return { cookie: r.headers['set-cookie'][0].split(';')[0], json: r.json, token: r.json.token };
  };
  ctx.deviceId = async (name) => (await adminRequest(configDir, { cmd: 'devices' })).devices.find((d) => d.name === name).id;
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
    ['POST', '/api/logout'], ['DELETE', '/api/sessions/work'], ['GET', '/api/nothing'], ['GET', '/other'], ['POST', '/api/login'],
  ];
  for (const [m, p] of routes) {
    const r = await c.req(m, p, { body: m === 'POST' ? {} : undefined });
    assert.equal(r.status, 401, `${m} ${p}`);
  }
  assert.equal((await c.req('GET', '/api/me', { cookie: 'pc_sid=forged' })).status, 401);
  assert.equal((await c.req('GET', '/api/me', { headers: { Authorization: 'Bearer forged' } })).status, 401);
  assert.equal(c.calls().length, 0); // nothing reached tmux
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

test('paired devices survive a restart; only a keyed hash is stored', async () => {
  const c = await boot();
  const { cookie, token } = await c.login({}, 'my phone');
  await c.app.close();
  const stored = fs.readFileSync(path.join(c.configDir, 'devices.json'), 'utf8');
  assert.ok(!stored.includes(token));
  const app2 = createApp({ configDir: c.configDir, tmux: [process.execPath, FAKE], log: () => {} });
  const port = await app2.listen(0, '127.0.0.1');
  assert.equal((await request(port, 'GET', '/api/me', { cookie })).status, 200);
  assert.equal((await request(port, 'GET', '/api/me', { headers: { Authorization: `Bearer ${token}` } })).status, 200);
  await app2.close();
  fs.rmSync(c.root, { recursive: true, force: true });
});

test('CSRF: X-PC header and Origin', () => withApp(async (c) => {
  const { cookie } = await c.login();
  const body = { name: 'csrf', project: 'alpha', harness: 'shell' };
  assert.equal((await c.req('POST', '/api/sessions', { cookie, body, pc: false })).status, 403);
  assert.equal((await c.req('POST', '/api/sessions', { cookie, body, headers: { 'X-PC': '0' } })).status, 403);
  assert.equal((await c.req('POST', '/api/pair', { body: { code: '123456' }, pc: false })).status, 403);
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
  assert.equal((await c.req('POST', '/api/pair', { body: { code: '123456' }, headers: { Origin: 'https://evil.example' } })).status, 403);
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
  // omp agent hub: Alt+A opens it, Ctrl+O expands an entry; other Alt/Ctrl combinations stay refused
  assert.ok(KEYS.includes('M-a') && KEYS.includes('C-o'));
  for (const key of ['M-a', 'C-o']) {
    await k({ key }); // status 200 is covered by the KEYS loop above
    assert.deepEqual(c.calls().filter((x) => x.argv[0] === 'send-keys').at(-1).argv, ['send-keys', '-t', '=work:', key]);
  }
  for (const key of ['M-x', 'M-A', 'C-x', 'M-a M-a']) assert.deepEqual((await k({ key })).json, { error: 'bad_key' }, key);
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
  const huge = await c.req('POST', '/api/pair', { raw: JSON.stringify({ code: 'x'.repeat(65 * 1024) }), headers: JSON_CT });
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
    await c.req('POST', '/api/pair', { body: { code: 'x' } }), await c.req('GET', '/nope', { cookie }),
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
  const secret = '987654';
  await c.req('POST', '/api/pair', { body: { code: secret } });
  const p = await adminRequest(c.configDir, { cmd: 'pair', name: 'logtest' });
  const r = await c.req('POST', '/api/pair', { body: { code: p.code } });
  const json = r.json; const cookie = r.headers['set-cookie'][0].split(';')[0];
  await mkSession(c, cookie);
  await c.req('POST', '/api/send/work', { cookie, body: { text: 'SENT-TEXT-xyz ' + VN, enter: true } });
  await c.req('POST', '/api/send/work', { cookie, body: { text: 'MULTI-xyz\nline', enter: false } });
  const all = c.logs.join('\n');
  for (const s of [secret, p.code, 'SENT-TEXT', 'MULTI-xyz', VN, cookie.slice(7), json.token, 'pc_sid']) assert.ok(!all.includes(s), s);
  assert.ok(c.logs.length >= 5);
  for (const l of c.logs) assert.match(l, /^(GET|POST|DELETE) \/\S* \d{3} \d+ms$/);
}));

// every config.json that must be refused at startup and ignored at reload (A3 + round 4 item 1)
const badConfigs = (good) => {
  const b = (n) => crypto.randomBytes(n).toString('base64');
  const variants = [
    { cookieSecret: undefined }, { cookieSecret: 5 }, { cookieSecret: b(16) }, { cookieSecret: b(32).replace(/=+$/, '') }, { cookieSecret: `${b(32)} ` },
    { projects: [] }, { projects: 'x' }, { port: 'x' }, { port: 70000 },
  ];
  return ['{"cookieSecret": "SEKRET-abc', '[]', 'null', ...variants.map((v) => JSON.stringify({ ...good, ...v }))];
};

test('startup refuses a missing or malformed config (createApp throws, the process exits 1)', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pc-nopw-'));
  try {
    assert.throws(() => createApp({ configDir: dir, log: () => {} }), /config\.json missing/);
    const good = { cookieSecret: Buffer.alloc(32, 1).toString('base64'), projects: {} };
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
    const pr = await adminRequest(c.configDir, { cmd: 'pair' });
    assert.equal((await request(port, 'POST', '/api/pair', { body: { code: pr.code } })).status, 200);
    assert.equal(fs.statSync(path.join(c.configDir, 'devices.json')).mode & 0o777, 0o600);
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
  for (const action of ['logout', 'admin-revoke', 'rotate', 'disconnect']) {
    test(`gate: ${action} while a job waits${fill ? ' and all 8 children are busy' : ''} -> no later child spawns`, async () => {
      await withApp(async (c) => {
        const victim = await c.login({}, 'victim');
        const owner = await c.login({}, 'owner');
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
          if (action === 'logout') assert.equal((await c.req('POST', '/api/logout', { cookie: victim.cookie })).status, 200);
          if (action === 'admin-revoke') assert.deepEqual(await adminRequest(c.configDir, { cmd: 'revoke', id: await c.deviceId('victim') }), { ok: true, revoked: 1 });
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
        assert.ok(!victimRan(c), 'a child was spawned for the revoked/rotated/disconnected job');
      });
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

test('empty projects: meta, overview and the + flow work with no projects; a fresh install seeds none', () => withApp(async (c) => {
  setProjects(c, {}); // what a fresh install has
  const { cookie } = await c.login();
  assert.deepEqual((await c.req('GET', '/api/meta', { cookie })).json.projects, []);
  const ov = await c.req('GET', '/api/overview', { cookie });
  assert.equal(ov.status, 200);
  assert.deepEqual(ov.json.projects, []);
  assert.deepEqual(ov.json.sessions, []);
  for (const project of ['home', 'alpha']) { // nothing to open
    const o = await c.req('POST', '/api/open', { cookie, body: { project, harness: 'shell' } });
    assert.deepEqual([o.status, o.json], [400, { error: 'invalid' }], project);
    const s = await c.req('POST', '/api/sessions', { cookie, body: { name: 'x', project, harness: 'shell' } });
    assert.deepEqual([s.status, s.json], [400, { error: 'invalid' }], project);
  }
  assert.ok(!c.calls().some((x) => x.argv[0] === 'new-session'));
  setProjects(c, { beta: ABS }); // adding one by editing config.json: picked up without a restart
  assert.deepEqual((await c.req('GET', '/api/meta', { cookie })).json.projects, ['beta']);
}));

test('install.sh first-install seed: the config it writes parses and has no projects', () => {
  // run the real `node -e '...'` snippet from install.sh into a temp file (no bash needed)
  const install = fs.readFileSync(path.join(here, '..', 'install.sh'), 'utf8');
  const m = /\(umask 077; node -e '([^']+)' "\$CFG\/config\.json"\)/.exec(install);
  assert.ok(m, 'seed snippet not found in install.sh');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pc-seed-'));
  try {
    const file = path.join(dir, 'config.json');
    const r = spawnSync(process.execPath, ['-e', m[1], file], { encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    const cfg = parseConfig(fs.readFileSync(file, 'utf8'));
    assert.deepEqual(cfg.projectNames, []);
    assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf8')).projects, {});
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('malformed config at reload: the previous one stays; a repaired one is picked up', () => withApp(async (c) => {
  const { cookie } = await c.login();
  const f = path.join(c.configDir, 'config.json');
  const good = fs.readFileSync(f, 'utf8');
  const cfg = JSON.parse(good);
  for (const text of badConfigs(cfg)) {
    fs.writeFileSync(f, text);
    assert.equal((await c.req('GET', '/api/me', { cookie })).status, 200, text); // the previous config still rules
  }
  assert.ok(c.logs.some((l) => l.startsWith('config reload failed')));
  assert.ok(!c.logs.join('\n').includes('SEKRET'));
  // a projects-only edit keeps the logins
  fs.writeFileSync(f, JSON.stringify({ ...cfg, projects: { beta: ABS } }));
  assert.equal((await c.req('GET', '/api/me', { cookie })).status, 200);
  assert.deepEqual((await c.req('GET', '/api/meta', { cookie })).json.projects, ['beta']);
  // a repaired file with a new secret drops every session
  fs.writeFileSync(f, JSON.stringify({ ...cfg, cookieSecret: crypto.randomBytes(32).toString('base64') }));
  assert.equal((await c.req('GET', '/api/me', { cookie })).status, 401);
  await c.login(); // pairing still works with the new secret
}));

// ======================= round 4 =======================
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

// ======================= A4: device pairing =======================
// the admin CLI as a real child process (async: the server under test lives in this process)
const cli = (configDir, args) => new Promise((resolve) => {
  execFile(process.execPath, [SERVER, ...args], { env: { ...process.env, PC_CONFIG_DIR: configDir }, encoding: 'utf8', timeout: 15000, windowsHide: true },
    (err, stdout, stderr) => resolve({ status: err ? (typeof err.code === 'number' ? err.code : 1) : 0, stdout, stderr }));
});
const TAG = crypto.createHmac('sha256', Buffer.alloc(32, 7)).update('fcoding-devices').digest('hex'); // boot()'s secret
const devicesFile = (c) => JSON.parse(fs.readFileSync(path.join(c.configDir, 'devices.json'), 'utf8')).devices;
const pairReq = (c, code, extra = {}) => c.req('POST', '/api/pair', { body: { code, ...extra } });
const otherCode = (code) => String((Number(code) + 1) % 1e6).padStart(6, '0');

test('pairing: code from --pair, token once, cookie set, device persisted (keyed hash only) and survives a restart', async () => {
  const c = await boot();
  try {
    const out = await cli(c.configDir, ['--pair', 'iPhone X']);
    assert.equal(out.status, 0, out.stderr);
    const code = /Mã ghép: (\d{6}) /.exec(out.stdout)?.[1];
    assert.ok(code, out.stdout);
    assert.match(out.stdout, /hết hạn sau 120 giây/);
    assert.equal(c.logs.length, 0); // the code is never logged
    const r = await pairReq(c, code, { name: 'ignored: the CLI name wins' });
    assert.equal(r.status, 200);
    assert.equal(r.json.ok, true);
    assert.match(r.json.token, /^[A-Za-z0-9_-]{43}$/);
    const sc = r.headers['set-cookie'][0];
    assert.equal(sc.split(';')[0], `pc_sid=${r.json.token}`);
    for (const f of ['HttpOnly', 'Secure', 'SameSite=Strict', 'Path=/', 'Max-Age=2592000']) assert.ok(sc.includes(f), f);
    assert.equal((await c.req('GET', '/api/me', { headers: { Authorization: `Bearer ${r.json.token}` } })).status, 200);
    assert.equal((await pairReq(c, code)).status, 401); // single use
    const [d] = devicesFile(c);
    assert.equal(devicesFile(c).length, 1);
    assert.deepEqual(Object.keys(d).sort(), ['createdAt', 'id', 'keyHash', 'name']);
    assert.equal(d.name, 'iPhone X');
    assert.equal(d.keyHash, crypto.createHmac('sha256', Buffer.alloc(32, 7)).update(r.json.token).digest('hex'));
    assert.ok(!fs.readFileSync(path.join(c.configDir, 'devices.json'), 'utf8').includes(r.json.token));
    if (process.platform !== 'win32') assert.equal(fs.statSync(path.join(c.configDir, 'devices.json')).mode & 0o777, 0o600);
    assert.ok(!c.logs.join('\n').includes(r.json.token) && !c.logs.join('\n').includes(code));
    // name from the app when the CLI gave none
    const p2 = await adminRequest(c.configDir, { cmd: 'pair' });
    assert.equal((await pairReq(c, p2.code, { name: 'Máy của An' })).status, 200);
    assert.deepEqual(devicesFile(c).map((x) => x.name), ['iPhone X', 'Máy của An']);
    await c.app.close();
    const app2 = createApp({ configDir: c.configDir, tmux: [process.execPath, FAKE], log: () => {} });
    const port = await app2.listen(0, '127.0.0.1');
    assert.equal((await request(port, 'GET', '/api/me', { headers: { Authorization: `Bearer ${r.json.token}` } })).status, 200);
    await app2.close();
  } finally { await c.app.close().catch(() => {}); fs.rmSync(c.root, { recursive: true, force: true }); }
});

test('pairing: five wrong codes invalidate the pending code (four do not)', async () => {
  let t = 1_700_000_000_000;
  await withApp(async (c) => {
  let p = await adminRequest(c.configDir, { cmd: 'pair' });
  for (let i = 0; i < 4; i++) assert.deepEqual((await pairReq(c, otherCode(p.code))).json, { error: 'bad_code' });
  assert.equal((await pairReq(c, p.code)).status, 200); // 4 wrong, then right: ok
  t += 61000; // stay under 10/minute
  p = await adminRequest(c.configDir, { cmd: 'pair' });
  for (const bad of [otherCode(p.code), '12345', 'abcdef', 123456, '']) assert.equal((await pairReq(c, bad)).status, 401, String(bad));
  assert.deepEqual((await pairReq(c, p.code)).json, { error: 'bad_code' }); // gone after 5 wrong ones
  }, { now: () => t });
});

test('pairing: an expired code is rejected (120 s)', async () => {
  let t = 1_700_000_000_000;
  await withApp(async (c) => {
    let p = await adminRequest(c.configDir, { cmd: 'pair' });
    assert.equal(p.expiresAt, t + 120000);
    t += 119999;
    assert.equal((await pairReq(c, p.code)).status, 200);
    p = await adminRequest(c.configDir, { cmd: 'pair' });
    t += 120000;
    assert.deepEqual([(await pairReq(c, p.code)).status, devicesFile(c).length], [401, 1]);
  }, { now: () => t });
});

test('pairing: one pending code per issuer, 3 in all; a device never pushes the shell code out; each code is single use', async () => {
  let t = 1_700_000_000_000;
  await withApp(async (c) => {
    setPublicUrl(c, PUB);
    const d1 = await c.login({}, 'one'), d2 = await c.login({}, 'two'), d3 = await c.login({}, 'three');
    const S = await adminRequest(c.configDir, { cmd: 'pair', name: 'S' });
    const A = (await mintCode(c, d1.cookie, { name: 'A' })).json;
    let A2 = (await mintCode(c, d1.cookie, { name: 'A2' })).json; // device one's new code replaces its own
    while (A2.code === A.code) A2 = (await mintCode(c, d1.cookie, { name: 'A2' })).json;
    const B = (await mintCode(c, d2.cookie, { name: 'B' })).json;
    const C = (await mintCode(c, d3.cookie, { name: 'C' })).json; // the 4th: the oldest DEVICE code (A2) goes, the shell code stays
    t += 61000; // stay under 10 per minute
    for (const dead of [A, A2]) assert.equal((await pairReq(c, dead.code)).status, 401, dead.code);
    for (const live of [S, B, C]) assert.equal((await pairReq(c, live.code)).status, 200, live.code);
    t += 61000;
    for (const used of [S, B, C]) assert.equal((await pairReq(c, used.code)).status, 401); // single use
    assert.deepEqual(devicesFile(c).map((x) => x.name), ['one', 'two', 'three', 'S', 'B', 'C']);
  }, { now: () => t });
});

test('pairing: a new shell code replaces the shell\'s own code; with three device codes it drops the oldest device code', async () => {
  let t = 1_700_000_000_000;
  await withApp(async (c) => {
    setPublicUrl(c, PUB);
    const d = [await c.login({}, 'one'), await c.login({}, 'two'), await c.login({}, 'three')];
    const codes = [];
    for (const [i, x] of d.entries()) codes.push((await mintCode(c, x.cookie, { name: 'ABC'[i] })).json);
    const [A, B, C] = codes;
    const S = await adminRequest(c.configDir, { cmd: 'pair', name: 'S' }); // the 4th code: A (the oldest) goes
    const S2 = await adminRequest(c.configDir, { cmd: 'pair', name: 'S2' }); // replaces S, drops nobody
    t += 61000;
    for (const dead of [A, S]) if (dead.code !== S2.code) assert.equal((await pairReq(c, dead.code)).status, 401, dead.code);
    for (const live of [B, C, S2]) assert.equal((await pairReq(c, live.code)).status, 200, live.code);
  }, { now: () => t });
});

test('pairing: each pending code has its own expiry', async () => {
  let t = 1_700_000_000_000;
  await withApp(async (c) => {
    setPublicUrl(c, PUB);
    const { cookie } = await c.login();
    const a = await adminRequest(c.configDir, { cmd: 'pair' });
    t += 60000;
    const b = (await mintCode(c, cookie)).json;
    assert.equal(a.expiresAt, 1_700_000_000_000 + 120000);
    assert.equal(b.expiresAt, new Date(1_700_000_060_000 + 120000).toISOString());
    t += 70000; // A is 130 s old, B 70 s
    assert.equal((await pairReq(c, a.code)).status, 401);
    assert.equal((await pairReq(c, b.code)).status, 200);
  }, { now: () => t });
});

test('pairing: a wrong guess is one attempt against every live code; five kill a code, a newer one has fewer', async () => {
  await withApp(async (c) => {
    setPublicUrl(c, PUB);
    const { cookie } = await c.login();
    const a = await adminRequest(c.configDir, { cmd: 'pair' });
    const wrong = otherCode(a.code);
    for (let i = 0; i < 3; i++) assert.equal((await pairReq(c, wrong)).status, 401); // A: 3 attempts
    let b = (await mintCode(c, cookie)).json;
    while (b.code === wrong) b = (await mintCode(c, cookie)).json;
    for (let i = 0; i < 2; i++) assert.equal((await pairReq(c, wrong)).status, 401); // A: 5 attempts, B: 2
    assert.equal((await pairReq(c, a.code)).status, 401); // A is gone
    assert.equal((await pairReq(c, b.code)).status, 200); // B survived
  });
});

// ======================= QR pairing: POST /api/pair-code, GET /pair, fcode-pair --qr =======================
const PUB = 'https://box.example.com';
const setPublicUrl = (c, publicUrl) => { // what the owner does by editing config.json; picked up without a restart
  const f = path.join(c.configDir, 'config.json');
  writePrivate(f, JSON.stringify({ ...JSON.parse(fs.readFileSync(f, 'utf8')), publicUrl }));
};
const mintCode = (c, cookie, body = {}, headers = {}) => c.req('POST', '/api/pair-code', { cookie, body, headers });

test('POST /api/pair-code: needs a paired device and X-PC; answers the code, an ISO expiry and server-only links', async () => {
  const t = 1_700_000_000_000;
  await withApp(async (c) => {
    setPublicUrl(c, `${PUB}/`); // a trailing slash is normalised away
    assert.equal((await c.req('POST', '/api/pair-code', { body: {} })).status, 401); // no device
    assert.equal((await c.req('POST', '/api/pair-code', { body: {}, headers: { Authorization: 'Bearer forged' } })).status, 401);
    assert.equal((await c.req('POST', '/api/pair-code', { body: {}, cookie: 'pc_sid=forged' })).status, 401);
    const { cookie } = await c.login();
    assert.equal((await c.req('POST', '/api/pair-code', { cookie, body: {}, pc: false })).status, 403); // X-PC
    assert.equal((await c.req('GET', '/api/pair-code', { cookie })).status, 405);
    assert.equal((await mintCode(c, cookie, { name: 5 })).status, 400);
    const r = await mintCode(c, cookie, { name: 'Máy của An & Bình' });
    assert.equal(r.status, 200);
    assert.equal(r.headers['cache-control'], 'no-store');
    assert.deepEqual(Object.keys(r.json).sort(), ['appLink', 'code', 'expiresAt', 'shareLink']);
    assert.match(r.json.code, /^\d{6}$/);
    assert.equal(r.json.expiresAt, new Date(t + 120000).toISOString());
    // the links hold the server origin and nothing else: no code, no name
    assert.equal(r.json.appLink, `fcode://pair?server=${encodeURIComponent(PUB)}`);
    assert.equal(r.json.shareLink, `${PUB}/pair`);
    assert.ok(!r.json.appLink.includes(r.json.code) && !r.json.shareLink.includes(r.json.code));
    // no body at all is fine too (the app sends {})
    const bare = await c.req('POST', '/api/pair-code', { cookie, raw: '' });
    assert.equal(bare.status, 200);
    assert.deepEqual([bare.json.appLink, bare.json.shareLink], [r.json.appLink, r.json.shareLink]);
    // nothing permanent in the answer: no token, no secret
    const text = JSON.stringify([r.json, bare.json]);
    assert.ok(!text.includes(cookie.split('=')[1]) && !text.includes(Buffer.alloc(32, 7).toString('base64')));
    assert.equal(c.logs.filter((l) => l.includes(r.json.code) || l.includes(bare.json.code)).length, 0); // never logged
    // without publicUrl no link can be built: 409 and no code is made
    setPublicUrl(c, undefined);
    assert.deepEqual((await mintCode(c, cookie)).json, { error: 'no_public_url' });
  }, { now: () => t });
});

test('pair-code: the code works exactly once and makes a device named as suggested; a wrong guess is a normal bad_code', () => withApp(async (c) => {
  setPublicUrl(c, PUB);
  const { cookie } = await c.login();
  const { json } = await mintCode(c, cookie, { name: 'iPhone mới' });
  const r = await pairReq(c, json.code);
  assert.equal(r.status, 200);
  assert.equal((await c.req('GET', '/api/me', { headers: { Authorization: `Bearer ${r.json.token}` } })).status, 200);
  assert.deepEqual((await pairReq(c, json.code)).json, { error: 'bad_code' }); // single use
  assert.deepEqual(devicesFile(c).map((d) => d.name), ['test', 'iPhone mới']);
}));

test('pair-code: expires after 120 s, and five wrong guesses kill it (same store and lockout as --pair)', async () => {
  let t = 1_700_000_000_000;
  await withApp(async (c) => {
    setPublicUrl(c, PUB);
    const { cookie } = await c.login();
    let { json } = await mintCode(c, cookie);
    t += 120000;
    assert.deepEqual((await pairReq(c, json.code)).json, { error: 'bad_code' });
    t += 61000; // under the 10 per minute limit again
    ({ json } = await mintCode(c, cookie));
    for (let i = 0; i < 5; i++) assert.equal((await pairReq(c, otherCode(json.code))).status, 401);
    assert.deepEqual((await pairReq(c, json.code)).json, { error: 'bad_code' });
    assert.equal(devicesFile(c).length, 1); // only the first device
    // a code from a device and one from the shell are pending together: neither cancels the other
    t += 61000;
    const a = (await mintCode(c, cookie)).json;
    const b = await adminRequest(c.configDir, { cmd: 'pair' });
    assert.notEqual(a.code, b.code);
    assert.equal((await pairReq(c, a.code)).status, 200);
    assert.equal((await pairReq(c, b.code)).status, 200);
  }, { now: () => t });
});

test('GET /pair: no auth, one button with the server-only app link, no code anywhere, changes no pairing state', () => withApp(async (c) => {
  setPublicUrl(c, PUB);
  const { cookie } = await c.login();
  const { json } = await mintCode(c, cookie);
  const page = (q = '', opts) => c.req('GET', `/pair${q}`, opts);
  const r = await page();
  assert.equal(r.status, 200);
  assert.match(r.headers['content-type'], /^text\/html; charset=utf-8/);
  assert.equal(r.headers['cache-control'], 'no-store');
  assert.equal(r.headers['referrer-policy'], 'no-referrer');
  assert.match(r.headers['content-security-policy'], /default-src 'self'/);
  assert.ok(r.text.includes(`href="fcode://pair?server=${encodeURIComponent(PUB)}"`), r.text);
  assert.ok(r.text.includes('Mở FCode') && r.text.includes('Chưa cài FCode? Cài file fcode.ipa trước.'));
  assert.ok(!r.text.includes(json.code)); // no code in the page
  assert.ok(!/<script|src=|https?:\/\/(?!box\.example\.com)/.test(r.text)); // no scripts, no external assets
  // the query is ignored and never echoed: the same page whatever it says
  for (const q of [`?code=${json.code}`, '?code=000000', '?code=%3Cscript%3E', '?x=%22%3E%3Cscript%3Ealert(1)%3C/script%3E', '?code=abcdef', '?code=']) {
    assert.equal((await page(q)).text, r.text, q);
  }
  // it reads and changes no pairing state: many visits later the code still works, once
  for (let i = 0; i < 15; i++) { await page(); await page(`?code=${json.code}`, { cookie }); }
  assert.equal((await c.req('HEAD', '/pair')).status, 200);
  assert.equal((await pairReq(c, json.code)).status, 200);
  assert.deepEqual((await pairReq(c, json.code)).json, { error: 'bad_code' });
  assert.equal((await page()).text, r.text); // nothing about the spent code
  assert.equal((await c.req('POST', '/pair', { body: {} })).status, 401); // only GET/HEAD are the share page
  assert.ok(!c.logs.join('\n').includes(json.code)); // the query string is not logged
  setPublicUrl(c, undefined);
  const none = await page();
  assert.equal(none.status, 503);
  assert.ok(!none.text.includes('fcode://'));
}));

test('links come only from publicUrl: a spoofed Host, X-Forwarded-Host or Origin never reaches a link or the page', () => withApp(async (c) => {
  setPublicUrl(c, PUB);
  const { cookie } = await c.login();
  const evil = { Host: 'evil.example', 'X-Forwarded-Host': 'evil.example', 'X-Forwarded-Proto': 'http', Forwarded: 'host=evil.example;proto=http' };
  const r = await mintCode(c, cookie, { name: '"><script>alert(1)</script>&server=https://evil.example' }, evil);
  assert.equal(r.status, 200);
  assert.ok(!JSON.stringify(r.json).includes('evil'));
  assert.equal(r.json.appLink, `fcode://pair?server=${encodeURIComponent(PUB)}`); // exactly this, whatever the name says
  assert.equal(r.json.shareLink, `${PUB}/pair`);
  const page = await c.req('GET', '/pair', { headers: evil });
  assert.equal(page.status, 200);
  assert.ok(!page.text.includes('evil') && page.text.includes(encodeURIComponent(PUB)));
  // not configured: refused, whatever Host says
  setPublicUrl(c, undefined);
  const none = await mintCode(c, cookie, {}, evil);
  assert.deepEqual([none.status, none.json], [409, { error: 'no_public_url' }]);
  assert.equal((await c.req('GET', '/pair', { headers: evil })).status, 503);
}));

test('config publicUrl: only a bare https origin is accepted (normalised); anything else refuses to load', () => {
  const secret = Buffer.alloc(32, 1).toString('base64');
  const parse = (publicUrl) => parseConfig(JSON.stringify({ cookieSecret: secret, publicUrl })).publicUrl;
  assert.equal(parseConfig(JSON.stringify({ cookieSecret: secret })).publicUrl, undefined);
  assert.equal(parse('https://box.example.com'), 'https://box.example.com');
  assert.equal(parse('https://Box.Example.com/'), 'https://box.example.com');
  assert.equal(parse('https://box.example.com:8443'), 'https://box.example.com:8443');
  for (const bad of ['http://box.example.com', 'https://box.example.com/app', 'https://box.example.com/?a=1', 'https://box.example.com/#x', 'https://u:p@box.example.com', 'box.example.com', '', 'fcode://pair', 42, null, ['https://a.b'], {}]) {
    assert.throws(() => parse(bad), /publicUrl/, JSON.stringify(bad));
  }
});

// the fcode-pair command: server.mjs --pair [name] --qr (install.sh's wrapper turns "fcode-pair name --qr" into this)
const envWith = (vars) => { // process.env without any case variant of the keys in vars (Windows has "Path"), then vars
  const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !Object.keys(vars).some((v) => v.toLowerCase() === k.toLowerCase())));
  return { ...env, ...vars };
};
const cliEnv = (c, extra = {}) => new Promise((resolve) => {
  execFile(process.execPath, [SERVER, ...extra.args], { env: envWith({ PC_CONFIG_DIR: c.configDir, ...extra.env }), encoding: 'utf8', timeout: 15000, windowsHide: true },
    (err, stdout, stderr) => resolve({ status: err ? (typeof err.code === 'number' ? err.code : 1) : 0, stdout, stderr }));
});

const codeOfBox = (out) => /MÃ GHÉP:\s+(\d(?:\s+\d){5})/.exec(out)?.[1].replace(/\s/g, ''); // the code in big digits
test('fcode-pair --qr: server-only links, the code in big digits, ONE expiry line; plain --pair is unchanged', () => withApp(async (c) => {
  const noQr = { PATH: path.join(c.root, 'empty') }; // a PATH without qrencode (node is started by its full path)
  const plain = await cliEnv(c, { args: ['--pair', 'iPhone X'], env: noQr });
  assert.equal(plain.status, 0, plain.stderr);
  assert.match(plain.stdout, /^Mã ghép: \d{6} \(hết hạn sau 120 giây\)/);
  assert.ok(!/Link|qrencode|fcode:\/\/|MÃ GHÉP/.test(plain.stdout), plain.stdout); // exactly the old shape
  const count = (out) => (out.match(/hết hạn sau/g) || []).length;
  // --qr without publicUrl: a hint, then the code and the expiry; the code works
  let r = await cliEnv(c, { args: ['--pair', 'iPhone X', '--qr'], env: noQr });
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /publicUrl/);
  assert.equal(count(r.stdout), 1, r.stdout);
  assert.equal((await pairReq(c, codeOfBox(r.stdout))).status, 200);
  // with publicUrl and no qrencode: the links (no code in them), the one line, the code, one expiry line last
  setPublicUrl(c, PUB);
  r = await cliEnv(c, { args: ['--pair', 'Máy A', '--qr'], env: noQr });
  assert.equal(r.status, 0, r.stderr);
  const code = codeOfBox(r.stdout);
  assert.match(code, /^\d{6}$/, r.stdout);
  assert.ok(r.stdout.includes(`Link chia sẻ: ${PUB}/pair\n`), r.stdout);
  assert.ok(r.stdout.includes(`Link mở app: fcode://pair?server=${encodeURIComponent(PUB)}\n`), r.stdout);
  assert.ok(!/code=|name=/.test(r.stdout.replace(/MÃ GHÉP[^\n]*/, '')), r.stdout); // no code or name in any link
  assert.match(r.stdout, /cài qrencode để hiện mã QR\n/);
  assert.equal(count(r.stdout), 1, r.stdout);
  assert.ok(r.stdout.endsWith('Mã hết hạn sau 2 phút.\n'), r.stdout);
  assert.ok(r.stdout.indexOf('Link chia sẻ') < r.stdout.indexOf('MÃ GHÉP'));
  assert.equal((await pairReq(c, code)).status, 200);
  assert.ok(devicesFile(c).some((d) => d.name === 'Máy A'));
  // no name: "--pair --qr" means no name (it is not named "--qr")
  r = await cliEnv(c, { args: ['--pair', '--qr'], env: noQr });
  assert.equal((await pairReq(c, codeOfBox(r.stdout))).status, 200);
  assert.ok(!devicesFile(c).some((d) => d.name.includes('--qr')) && devicesFile(c).at(-1).name === 'device');
  r = await cliEnv(c, { args: ['--pair', '', '--qr'], env: noQr });
  assert.equal((await pairReq(c, codeOfBox(r.stdout))).status, 200);
  if (process.platform !== 'win32') { // a stand-in qrencode: it gets "-t ANSIUTF8 <app link>" and its output is printed first
    const bin = path.join(c.root, 'bin'); fs.mkdirSync(bin);
    fs.writeFileSync(path.join(bin, 'qrencode'), '#!/bin/sh\necho "QR[$1 $2] $3"\n', { mode: 0o755 });
    r = await cliEnv(c, { args: ['--pair', 'Máy B', '--qr'], env: { PATH: `${bin}:${noQr.PATH}` } });
    assert.ok(r.stdout.startsWith(`QR[-t ANSIUTF8] fcode://pair?server=${encodeURIComponent(PUB)}\n`), r.stdout);
    assert.ok(!r.stdout.includes('cài qrencode') && count(r.stdout) === 1 && r.stdout.indexOf('QR[') < r.stdout.indexOf('MÃ GHÉP'), r.stdout);
  }
}));

// A code dies with the device that made it (a stolen device must not re-pair itself after a revoke), and with a secret rotation.
const threeCodes = async (c) => { // two devices mint a code each, the shell makes one
  setPublicUrl(c, PUB);
  const d1 = await c.login({}, 'one'), d2 = await c.login({}, 'two');
  const a = (await mintCode(c, d1.cookie)).json, b = (await mintCode(c, d2.cookie)).json;
  const s = await adminRequest(c.configDir, { cmd: 'pair', name: 'shell' });
  return { d1, d2, a, b, s, redeem: async (x) => (await pairReq(c, x.code)).status };
};

test('pending codes: --revoke <id> kills that device\'s codes only (the probe: A mints, A is revoked, the code fails)', () => withApp(async (c) => {
  const { d1, a, b, s, redeem } = await threeCodes(c);
  assert.equal((await adminRequest(c.configDir, { cmd: 'revoke', id: await c.deviceId('one') })).ok, true);
  assert.equal((await c.req('GET', '/api/me', { cookie: d1.cookie })).status, 401);
  assert.equal(await redeem(a), 401);
  assert.equal(await redeem(s), 200); // the shell's and the other device's codes live on
  assert.equal(await redeem(b), 200);
}));

test('pending codes: --revoke all clears every pending code', () => withApp(async (c) => {
  const { a, b, s, redeem } = await threeCodes(c);
  assert.equal((await adminRequest(c.configDir, { cmd: 'revoke', id: 'all' })).ok, true);
  for (const x of [a, b, s]) assert.equal(await redeem(x), 401);
  assert.equal(devicesFile(c).length, 0);
  await c.login(); // a new code still works afterwards
}));

test('pending codes: logout kills that device\'s codes; logout?all=1 clears every pending code', () => withApp(async (c) => {
  let { d1, a, b, s, redeem } = await threeCodes(c);
  assert.equal((await c.req('POST', '/api/logout', { cookie: d1.cookie })).status, 200);
  assert.equal(await redeem(a), 401);
  assert.equal(await redeem(s), 200);
  const { cookie } = await c.login({}, 'three'); // d2 and the new device are still paired
  const x = (await mintCode(c, cookie)).json, y = await adminRequest(c.configDir, { cmd: 'pair' });
  assert.equal((await c.req('POST', '/api/logout?all=1', { cookie })).status, 200);
  for (const z of [b, x, y]) assert.equal(await redeem(z), 401);
}));

test('pending codes: a cookieSecret rotation clears every pending code', () => withApp(async (c) => {
  const { a, b, s, redeem } = await threeCodes(c);
  const f = path.join(c.configDir, 'config.json');
  writePrivate(f, JSON.stringify({ ...JSON.parse(fs.readFileSync(f, 'utf8')), cookieSecret: Buffer.alloc(32, 9).toString('base64') }));
  // NO request in between: POST /api/pair is the first thing that sees the new secret (the config is reloaded lazily)
  for (const x of [a, b, s]) assert.equal(await redeem(x), 401, x.code); // a device code and the shell code alike
  assert.deepEqual(devicesFile(c), []); // nothing was committed
  const p = await adminRequest(c.configDir, { cmd: 'pair' }); // and pairing works under the new secret
  assert.equal(await redeem(p), 200);
  assert.equal(devicesFile(c).length, 1);
}));

test('names: cut on a code point and well-formed (63 characters + an emoji, lone surrogates, many emoji); the server survives', () => withApp(async (c) => {
  setPublicUrl(c, PUB);
  const { cookie } = await c.login();
  const names = () => devicesFile(c).map((d) => d.name);
  const via = async (name) => { const r = await mintCode(c, cookie, { name }); assert.equal(r.status, 200, JSON.stringify(name)); assert.equal((await pairReq(c, r.json.code)).status, 200); return names().at(-1); };
  assert.equal(await via(`${'a'.repeat(63)}😀`), 'a'.repeat(63)); // the emoji would be cut in half: it is left out whole
  assert.equal(await via('ab\ud800cd'), 'abcd'); // a lone high surrogate
  assert.equal(await via('ab\udc00cd'), 'abcd'); // a lone low surrogate
  assert.equal(await via('😀'.repeat(40)), '😀'.repeat(32)); // exactly 64 UTF-16 units
  assert.ok(names().every((n) => n.length <= 64 && n === n.toWellFormed()));
  // the shell path too: it used to throw out of the admin socket callback
  const r = await adminRequest(c.configDir, { cmd: 'pair', name: `${'a'.repeat(63)}😀`, links: true });
  assert.equal(r.ok, true);
  assert.equal((await c.req('GET', '/')).status, 200);
  // devices.json stays valid: a restart accepts it
  await c.app.close();
  const app2 = createApp({ configDir: c.configDir, tmux: [process.execPath, FAKE], log: () => {} });
  await app2.listen(0, '127.0.0.1');
  assert.equal(app2.devices.size, 5);
  await app2.close();
}));

test('admin: an exception inside a request is an {ok:false} answer, never a crash', async () => {
  let boom = false;
  await withApp(async (c) => {
    boom = true;
    const bad = await adminRequest(c.configDir, { cmd: 'pair' });
    boom = false;
    assert.deepEqual(bad, { ok: false, error: 'internal' });
    assert.equal((await c.req('GET', '/')).status, 200);
    assert.equal((await adminRequest(c.configDir, { cmd: 'pair' })).ok, true);
  }, { now: () => { if (boom) throw new Error('boom'); return Date.now(); } });
});

test('pairing: global /api/pair limits 10/minute and 30/hour -> 429 with Retry-After', async () => {
  let t = 1_700_000_000_000;
  await withApp(async (c) => {
    for (let i = 0; i < 10; i++) assert.equal((await pairReq(c, '000000')).status, 401);
    let r = await pairReq(c, '000000');
    assert.equal(r.status, 429);
    assert.equal(r.json.error, 'rate_limited');
    assert.ok(Number(r.headers['retry-after']) > 0 && Number(r.headers['retry-after']) <= 60);
    // even the right code is refused while limited
    const p = await adminRequest(c.configDir, { cmd: 'pair' });
    assert.equal((await pairReq(c, p.code)).status, 429);
    t += 61000;
    assert.equal((await pairReq(c, p.code)).status, 200);
    for (let k = 0; k < 2; k++) { for (let i = 0; i < 9; i++) await pairReq(c, '000000'); t += 61000; } // 10 + 1 + 18 = 29 counted this hour
    assert.equal((await pairReq(c, '000000')).status, 401); // 30th
    r = await pairReq(c, '000000');
    assert.equal(r.status, 429);
    assert.ok(Number(r.headers['retry-after']) > 60 && Number(r.headers['retry-after']) <= 3600, r.headers['retry-after']);
  }, { now: () => t });
});

test('pairing: the code is compared with crypto.timingSafeEqual', () => withApp(async (c) => {
  const orig = crypto.timingSafeEqual;
  const seen = [];
  crypto.timingSafeEqual = (a, b) => { seen.push([a.length, b.length]); return orig(a, b); };
  try {
    const p = await adminRequest(c.configDir, { cmd: 'pair' });
    assert.equal((await pairReq(c, otherCode(p.code))).status, 401);
    assert.equal((await pairReq(c, p.code)).status, 200);
  } finally { crypto.timingSafeEqual = orig; }
  assert.deepEqual(seen, [[6, 6], [6, 6]]);
}));

test('admin.sock: mode 600, a stale socket is replaced, a non-socket is refused', async (t) => {
  if (process.platform === 'win32') return t.skip('unix sockets');
  const c = await boot();
  try {
    const sock = adminPath(c.configDir);
    const st = fs.statSync(sock);
    assert.ok(st.isSocket());
    assert.equal(st.mode & 0o777, 0o600);
    await c.app.close();
    assert.ok(!fs.existsSync(sock));
    // a server that died hard leaves its socket behind
    const k = spawnSync(process.execPath, ['-e', `require('net').createServer().listen(${JSON.stringify(sock)}, () => process.kill(process.pid, 'SIGKILL'))`]);
    assert.equal(k.signal, 'SIGKILL');
    assert.ok(fs.lstatSync(sock).isSocket());
    const app2 = createApp({ configDir: c.configDir, tmux: [process.execPath, FAKE], log: () => {} });
    await app2.listen(0, '127.0.0.1');
    assert.equal(fs.statSync(sock).mode & 0o777, 0o600);
    assert.equal((await adminRequest(c.configDir, { cmd: 'pair' })).ok, true);
    await app2.close();
    fs.writeFileSync(sock, 'not a socket');
    const app3 = createApp({ configDir: c.configDir, tmux: [process.execPath, FAKE], log: () => {} });
    await assert.rejects(app3.listen(0, '127.0.0.1'), /not a socket/);
  } finally { await c.app.close().catch(() => {}); fs.rmSync(c.root, { recursive: true, force: true }); }
});

test('CLI: --pair, --devices and --revoke exit 1 when the server is not running', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pc-cli-'));
  try {
    for (const args of [['--pair'], ['--devices'], ['--revoke', 'all']]) {
      const r = await cli(dir, args);
      assert.equal(r.status, 1, args.join(' '));
      assert.match(r.stderr, /not running/);
    }
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('CLI: --devices lists, --revoke <id> and --revoke all revoke through admin.sock', () => withApp(async (c) => {
  const a = await c.login({}, 'phone A'); const b = await c.login({}, 'phone B');
  const ls = await cli(c.configDir, ['--devices']);
  assert.equal(ls.status, 0, ls.stderr);
  const idA = await c.deviceId('phone A');
  assert.match(ls.stdout, new RegExp(`^${idA}  \\d{4}-\\d\\d-\\d\\dT[^ ]+  phone A$`, 'm'));
  assert.match(ls.stdout, /  phone B$/m);
  assert.ok(!ls.stdout.includes(a.token) && !ls.stdout.includes('keyHash') && !ls.stdout.includes(devicesFile(c)[0].keyHash));
  const r1 = await cli(c.configDir, ['--revoke', idA]);
  assert.deepEqual([r1.status, r1.stdout.trim()], [0, 'revoked: 1']);
  assert.equal((await c.req('GET', '/api/me', { cookie: a.cookie })).status, 401);
  assert.equal((await c.req('GET', '/api/me', { cookie: b.cookie })).status, 200);
  assert.deepEqual(devicesFile(c).map((d) => d.name), ['phone B']);
  const bad = await cli(c.configDir, ['--revoke', 'ffffffffffffffff']);
  assert.equal(bad.status, 1);
  assert.match(bad.stderr, /no such device/);
  const all = await cli(c.configDir, ['--revoke', 'all']);
  assert.deepEqual([all.status, all.stdout.trim()], [0, 'revoked: 1']);
  assert.equal((await c.req('GET', '/api/me', { cookie: b.cookie })).status, 401);
  assert.deepEqual(devicesFile(c), []);
  assert.match((await cli(c.configDir, ['--devices'])).stdout, /no paired devices/);
}));

// a server whose devices.json writes can be made to fail
const failingWrites = () => {
  const w = { failing: false, attempts: 0 };
  w.fn = (f, d) => {
    if (f.endsWith('devices.json')) w.attempts++;
    if (w.failing && f.endsWith('devices.json')) throw Object.assign(new Error('ENOSPC'), { code: 'ENOSPC' });
    writePrivate(f, d);
    if (w.afterRename && f.endsWith('devices.json')) throw Object.assign(new Error('EIO'), { code: 'EIO', committed: true }); // dir fsync failed
  };
  return w;
};

test('revoke: a failed devices.json write -> CLI exit 1, nothing changes', async () => {
  const w = failingWrites();
  await withApp(async (c) => {
    const a = await c.login({}, 'keep');
    const before = fs.readFileSync(path.join(c.configDir, 'devices.json'));
    w.failing = true;
    for (const id of [await c.deviceId('keep'), 'all']) {
      const r = await cli(c.configDir, ['--revoke', id]);
      assert.equal(r.status, 1);
      assert.match(r.stderr, /storage: ENOSPC/);
    }
    assert.equal((await c.req('GET', '/api/me', { cookie: a.cookie })).status, 200);
    assert.ok(fs.readFileSync(path.join(c.configDir, 'devices.json')).equals(before));
    // logout with a failed write: 500 storage, the device stays
    assert.deepEqual((await c.req('POST', '/api/logout', { cookie: a.cookie })).json, { error: 'storage' });
    assert.equal((await c.req('POST', '/api/logout?all=1', { cookie: a.cookie })).status, 500);
    assert.equal((await c.req('GET', '/api/me', { cookie: a.cookie })).status, 200);
    w.failing = false;
    assert.equal((await cli(c.configDir, ['--revoke', 'all'])).status, 0);
    assert.equal((await c.req('GET', '/api/me', { cookie: a.cookie })).status, 401);
  }, { writePrivate: w.fn });
});

test('pairing: a failed devices.json write -> 500 storage, no token, no cookie, no device', async () => {
  const w = failingWrites();
  await withApp(async (c) => {
    w.failing = true;
    const p = await adminRequest(c.configDir, { cmd: 'pair' });
    const r = await pairReq(c, p.code);
    assert.deepEqual([r.status, r.json], [500, { error: 'storage' }]);
    assert.equal(r.headers['set-cookie'], undefined);
    assert.ok(!r.text.includes('token'));
    assert.ok(!fs.existsSync(path.join(c.configDir, 'devices.json')));
    assert.deepEqual((await adminRequest(c.configDir, { cmd: 'devices' })).devices, []);
    w.failing = false;
    await c.login(); // a new --pair works
  }, { writePrivate: w.fn });
});

test('logout removes only the calling device; logout?all removes every device (memory and devices.json)', () => withApp(async (c) => {
  const a = await c.login({}, 'a'); const b = await c.login({}, 'b'); const d = await c.login({}, 'd');
  assert.equal((await c.req('POST', '/api/logout', { headers: { Authorization: `Bearer ${a.token}` } })).status, 200);
  assert.equal((await c.req('GET', '/api/me', { cookie: a.cookie })).status, 401);
  assert.deepEqual(devicesFile(c).map((x) => x.name), ['b', 'd']);
  assert.equal((await c.req('POST', '/api/logout?all=1', { cookie: b.cookie })).status, 200);
  for (const x of [b, d]) assert.equal((await c.req('GET', '/api/me', { cookie: x.cookie })).status, 401);
  assert.deepEqual(devicesFile(c), []);
}));

test('startup refuses an invalid devices.json (exit 1, nothing of the file printed); a missing one is empty', async () => {
  const c = await boot();
  await c.app.close();
  try {
    const f = path.join(c.configDir, 'devices.json');
    const ok = { id: '0123456789abcdef', name: 'x', keyHash: 'a'.repeat(64), createdAt: 1 };
    const bad = ['{"devices": [SEKRET', '[]', '{}', '{"devices": {}}', ...[
      { ...ok, id: 'xyz' }, { ...ok, id: 5 }, { ...ok, id: 1234567890123456 }, { ...ok, keyHash: 'SEKRET' }, { ...ok, keyHash: 1e63 }, { ...ok, createdAt: [1] }, { ...ok, name: 'n'.repeat(65) }, { ...ok, name: 7 }, { ...ok, createdAt: 'x' },
    ].map((d) => JSON.stringify({ devices: [d] })), JSON.stringify({ devices: [ok, ok] }), JSON.stringify({ secretTag: 5, devices: [] }), JSON.stringify({ secretTag: 'SEKRET', devices: [] })];
    for (const text of bad) {
      fs.writeFileSync(f, text);
      assert.throws(() => createApp({ configDir: c.configDir, log: () => {} }), /devices\.json/, text);
    }
    fs.writeFileSync(f, bad[0]);
    const r = spawnSync(process.execPath, [SERVER], { env: { ...process.env, PC_CONFIG_DIR: c.configDir, PC_PORT: '0' }, encoding: 'utf8', timeout: 10000 });
    assert.equal(r.status, 1);
    assert.match(r.stderr, /devices\.json is not valid JSON/);
    assert.ok(!r.stderr.includes('SEKRET'));
    for (const keyHash of [1234567890123456, 1e63]) { // numeric fields: the real server exits 1 too
      fs.writeFileSync(f, JSON.stringify({ devices: [{ ...ok, keyHash, id: 1234567890123456 }] }));
      assert.equal(spawnSync(process.execPath, [SERVER], { env: { ...process.env, PC_CONFIG_DIR: c.configDir, PC_PORT: '0' }, timeout: 10000 }).status, 1);
    }
    fs.writeFileSync(f, JSON.stringify({ secretTag: TAG, devices: [ok] }));
    assert.equal(createApp({ configDir: c.configDir, log: () => {} }).devices.size, 1);
    fs.writeFileSync(f, JSON.stringify({ devices: [] })); // first-run file without a tag: valid
    assert.equal(createApp({ configDir: c.configDir, log: () => {} }).devices.size, 0);
    fs.rmSync(f);
    assert.equal(createApp({ configDir: c.configDir, log: () => {} }).devices.size, 0);
  } finally { fs.rmSync(c.root, { recursive: true, force: true }); }
});

test('rotating cookieSecret invalidates every device and rewrites devices.json empty', async () => {
  const c = await boot();
  try {
    const a = await c.login({}, 'a'); const b = await c.login({}, 'b');
    rotate(c);
    for (const x of [a, b]) assert.equal((await c.req('GET', '/api/me', { cookie: x.cookie })).status, 401);
    assert.deepEqual(devicesFile(c), []);
    const n = await c.login({}, 'new');
    assert.equal((await c.req('GET', '/api/me', { cookie: n.cookie })).status, 200);
    await c.app.close();
    const app2 = createApp({ configDir: c.configDir, tmux: [process.execPath, FAKE], log: () => {} });
    const port = await app2.listen(0, '127.0.0.1');
    assert.equal((await request(port, 'GET', '/api/me', { cookie: a.cookie })).status, 401);
    assert.equal((await request(port, 'GET', '/api/me', { cookie: n.cookie })).status, 200);
    await app2.close();
  } finally { await c.app.close().catch(() => {}); fs.rmSync(c.root, { recursive: true, force: true }); }
});

// ======================= A4 update r1 =======================
test('writePrivate: a failed directory fsync after the rename carries committed: true', (t) => {
  if (process.platform === 'win32') return t.skip('no directory fsync on Windows');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pc-wp-'));
  const fsync = fs.fsyncSync;
  let n = 0;
  try {
    fs.fsyncSync = (fd) => { if (++n === 2) throw Object.assign(new Error('EIO'), { code: 'EIO' }); return fsync(fd); }; // 1 = file, 2 = dir
    let err; try { writePrivate(path.join(dir, 'devices.json'), 'newer'); } catch (x) { err = x; }
    fs.fsyncSync = fsync;
    assert.equal(err?.committed, true);
    assert.equal(fs.readFileSync(path.join(dir, 'devices.json'), 'utf8'), 'newer');
  } finally { fs.fsyncSync = fsync; fs.rmSync(dir, { recursive: true, force: true }); }
});

test('commit point is the rename: pair, revoke and logout succeed when only the dir fsync fails', async () => {
  const w = failingWrites();
  await withApp(async (c) => {
    w.afterRename = true;
    const a = await c.login({}, 'a'); // 200 + token although the write threw after the rename
    assert.equal((await c.req('GET', '/api/me', { cookie: a.cookie })).status, 200);
    const b = await c.login({}, 'b');
    const d = await c.login({}, 'd');
    assert.deepEqual(await adminRequest(c.configDir, { cmd: 'revoke', id: await c.deviceId('a') }), { ok: true, revoked: 1 });
    assert.equal((await c.req('GET', '/api/me', { cookie: a.cookie })).status, 401);
    assert.equal((await c.req('POST', '/api/logout', { cookie: b.cookie })).status, 200);
    assert.equal((await c.req('GET', '/api/me', { cookie: b.cookie })).status, 401);
    assert.deepEqual(devicesFile(c).map((x) => x.name), ['d']); // memory and file agree
    assert.equal((await c.req('POST', '/api/logout?all=1', { cookie: d.cookie })).status, 200);
    assert.deepEqual(devicesFile(c), []);
    assert.ok(c.logs.some((l) => l.startsWith('devices.json directory fsync failed: EIO')));
  }, { writePrivate: w.fn });
});

test('secretTag: a cookieSecret rotated while the server was stopped purges every device at startup', async () => {
  const c = await boot();
  try {
    const a = await c.login({}, 'a');
    assert.equal(JSON.parse(fs.readFileSync(path.join(c.configDir, 'devices.json'), 'utf8')).secretTag, TAG);
    await c.app.close();
    rotate(c);
    const newTag = crypto.createHmac('sha256', Buffer.from(JSON.parse(fs.readFileSync(path.join(c.configDir, 'config.json'), 'utf8')).cookieSecret, 'base64')).update('fcoding-devices').digest('hex');
    const app2 = createApp({ configDir: c.configDir, tmux: [process.execPath, FAKE], log: () => {} });
    assert.equal(app2.devices.size, 0);
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(c.configDir, 'devices.json'), 'utf8')), { secretTag: newTag, devices: [] });
    const port = await app2.listen(0, '127.0.0.1');
    assert.equal((await request(port, 'GET', '/api/me', { cookie: a.cookie })).status, 401);
    await app2.close();
    // an old file without a tag but with devices counts as a mismatch
    fs.writeFileSync(path.join(c.configDir, 'devices.json'), JSON.stringify({ devices: devicesFile(c).concat([{ id: '0123456789abcdef', name: 'x', keyHash: 'a'.repeat(64), createdAt: 1 }]) }));
    assert.equal(createApp({ configDir: c.configDir, log: () => {} }).devices.size, 0);
    assert.deepEqual(devicesFile(c), []);
  } finally { await c.app.close().catch(() => {}); fs.rmSync(c.root, { recursive: true, force: true }); }
});

test('secretTag: a failed purge after a rotation blocks auth and pairing, and is retried without another config edit', async () => {
  const w = failingWrites();
  await withApp(async (c) => {
    const a = await c.login({}, 'a');
    const before = fs.readFileSync(path.join(c.configDir, 'devices.json'), 'utf8');
    w.failing = true;
    rotate(c);
    assert.equal((await c.req('GET', '/api/me', { cookie: a.cookie })).status, 401);
    assert.equal(fs.readFileSync(path.join(c.configDir, 'devices.json'), 'utf8'), before); // still the old file
    assert.ok(c.logs.some((l) => l.startsWith('devices.json purge failed')));
    const p = await adminRequest(c.configDir, { cmd: 'pair' });
    const r = await c.req('POST', '/api/pair', { body: { code: p.code } });
    assert.deepEqual([r.status, r.json, r.headers['set-cookie']], [500, { error: 'storage' }, undefined]);
    w.failing = false; // storage is back: the next admin request purges
    assert.deepEqual((await adminRequest(c.configDir, { cmd: 'devices' })).devices, []);
    const f = JSON.parse(fs.readFileSync(path.join(c.configDir, 'devices.json'), 'utf8'));
    assert.deepEqual(f.devices, []);
    assert.notEqual(f.secretTag, TAG);
    // the 500 above did not use the code up: it still works once storage is back (it fails if pair() consumes before the purge guard)
    assert.equal((await c.req('POST', '/api/pair', { body: { code: p.code } })).status, 200);
    assert.deepEqual((await c.req('POST', '/api/pair', { body: { code: p.code } })).json, { error: 'bad_code' });
    const n = await c.login({}, 'new');
    assert.equal((await c.req('GET', '/api/me', { cookie: n.cookie })).status, 200);
    assert.equal((await c.req('GET', '/api/me', { cookie: a.cookie })).status, 401);
  }, { writePrivate: w.fn });
});

test('/api/pair is counted before the body: 10 oversized bodies use up the minute', async () => {
  let t = 1_700_000_000_000;
  await withApp(async (c) => {
    const big = JSON.stringify({ code: 'x'.repeat(65 * 1024) });
    for (let i = 0; i < 10; i++) assert.equal((await c.req('POST', '/api/pair', { raw: big, headers: JSON_CT })).status, 413);
    assert.equal((await c.req('POST', '/api/pair', { raw: big, headers: JSON_CT })).status, 429);
    const p = await adminRequest(c.configDir, { cmd: 'pair' });
    assert.equal((await pairReq(c, p.code)).status, 429);
    assert.equal((await c.req('POST', '/api/pair', { raw: '{bad json', headers: JSON_CT })).status, 429);
  }, { now: () => t });
});

test('/api/pair: concurrent requests never exceed the quota', async () => {
  let t = 1_700_000_000_000;
  await withApp(async (c) => {
    const rs = await Promise.all(Array.from({ length: 25 }, () => pairReq(c, '000000')));
    assert.equal(rs.filter((r) => r.status !== 429).length, 10);
    t += 61000;
    const rs2 = await Promise.all(Array.from({ length: 30 }, () => pairReq(c, '000000')));
    assert.equal(rs2.filter((r) => r.status !== 429).length, 10);
    t += 61000;
    const rs3 = await Promise.all(Array.from({ length: 30 }, () => pairReq(c, '000000')));
    assert.equal(rs3.filter((r) => r.status !== 429).length, 10); // 30 in the hour
    t += 61000;
    assert.equal((await pairReq(c, '000000')).status, 429);
  }, { now: () => t });
});

test('admin.sock handles only the first line of a connection', { skip: process.platform === 'win32' && 'unix sockets' }, () => withApp(async (c) => {
  const orig = crypto.randomInt;
  let calls = 0;
  crypto.randomInt = (...a) => { calls++; return orig(...a); };
  try {
    const reply = await new Promise((resolve, reject) => {
      const s = net.connect({ path: adminPath(c.configDir), allowHalfOpen: true }); // keeps writing after the server's reply
      let buf = '';
      s.on('data', (d) => { buf += d; });
      s.on('end', () => { s.end('{"cmd":"pair","name":"two"}\n'); setTimeout(() => resolve(buf), 100); }); // a second chunk on the same connection
      s.on('error', reject); // Windows pipes cannot half-close (EPIPE): POSIX only
      s.on('connect', () => s.write('{"cmd":"pair","name":"one"}\n'));
    });
    await sleep(100);
    assert.equal(reply.trim().split('\n').length, 1);
    assert.equal(calls, 1);
    assert.equal((await pairReq(c, JSON.parse(reply).code)).status, 200); // the first code is still the pending one
    assert.deepEqual(devicesFile(c).map((d) => d.name), ['one']);
  } finally { crypto.randomInt = orig; }
}));

test('pairing: the code comes from crypto.randomInt(0, 1000000), zero-padded', () => withApp(async (c) => {
  const orig = crypto.randomInt;
  const seen = [];
  crypto.randomInt = (...a) => { seen.push(a); return 42; };
  let p;
  try { p = await adminRequest(c.configDir, { cmd: 'pair' }); } finally { crypto.randomInt = orig; }
  assert.deepEqual(seen, [[0, 1e6]]);
  assert.equal(p.code, '000042');
  assert.equal(p.expiresIn, 120);
  assert.equal((await pairReq(c, '000042')).status, 200);
}));

test('device names lose C0, C1 and bidi control characters', () => withApp(async (c) => {
  const ch = (...cps) => String.fromCharCode(...cps);
  const raw = `a${ch(0x85)}b${ch(0x202e)}c${ch(0x2066)}d${ch(0x200f)}e${ch(0x1, 0x7f, 0x9f, 0x200e, 0x202a, 0x2069)}f`;
  await c.login({}, raw);
  assert.deepEqual(devicesFile(c).map((d) => d.name), ['abcdef']);
  const p = await adminRequest(c.configDir, { cmd: 'pair' }); // the app-sent name too
  assert.equal((await pairReq(c, p.code, { name: `x${ch(0x202d)}y` })).status, 200);
  assert.deepEqual(devicesFile(c).map((d) => d.name), ['abcdef', 'xy']);
}));

// ======================= A4 update r2 =======================
test('purge retry is throttled: at most one write per second from requests; admin requests and config changes always retry', async () => {
  let t = 1_700_000_000_000;
  const w = failingWrites();
  await withApp(async (c) => {
    const a = await c.login({}, 'a');
    w.failing = true;
    rotate(c);
    w.attempts = 0;
    for (let i = 0; i < 20; i++) assert.equal((await c.req('GET', '/api/me', { cookie: a.cookie })).status, 401);
    assert.equal(w.attempts, 1); // the purge that the rotation started; no retry within the same second
    const failLogs = () => c.logs.filter((l) => l.startsWith('devices.json purge failed')).length;
    assert.equal(failLogs(), 1);
    t += 999;
    await c.req('GET', '/api/me', { cookie: a.cookie });
    assert.equal(w.attempts, 1);
    t += 1;
    for (let i = 0; i < 5; i++) await c.req('GET', '/api/me', { cookie: a.cookie });
    assert.equal(w.attempts, 2); // one retry after 1 s
    await adminRequest(c.configDir, { cmd: 'devices' });
    await adminRequest(c.configDir, { cmd: 'devices' });
    assert.equal(w.attempts, 4); // every admin request retries
    const f = path.join(c.configDir, 'config.json');
    writePrivate(f, JSON.stringify({ ...JSON.parse(fs.readFileSync(f, 'utf8')), projects: { beta: ABS } })); // same secret, new stamp
    await c.req('GET', '/api/me', { cookie: a.cookie });
    assert.equal(w.attempts, 5); // a config change retries
    assert.equal(failLogs(), 5); // one log line per attempt
    w.failing = false;
    t += 1000;
    await c.req('GET', '/api/me', { cookie: a.cookie });
    assert.equal(w.attempts, 6);
    assert.deepEqual(devicesFile(c), []);
    for (let i = 0; i < 5; i++) await c.req('GET', '/api/me', { cookie: a.cookie });
    assert.equal(w.attempts, 6); // nothing pending: no more writes
    await c.login({}, 'new');
  }, { now: () => t, writePrivate: w.fn });
});

// ======================= A5: GET /api/overview, POST /api/open fresh =======================
const ESC = String.fromCharCode(27);
const NO_GIT = [process.execPath, '-e', 'process.exit(128)']; // every git call fails: projects get nulls
const fakeState = (c) => path.join(c.root, 'fake', 'state.json');
const setSession = (c, name, fields) => { // edit the fake tmux session table directly
  const st = JSON.parse(fs.readFileSync(fakeState(c), 'utf8'));
  st.sessions[name] = { created: 1700000000, dir: ABS, cmd: 'x', opts: { '@pc_project': 'alpha', '@pc_harness': 'shell' }, ...st.sessions[name], ...fields };
  fs.writeFileSync(fakeState(c), JSON.stringify(st));
};
const setProjects = (c, projects) => {
  const f = path.join(c.configDir, 'config.json');
  writePrivate(f, JSON.stringify({ ...JSON.parse(fs.readFileSync(f, 'utf8')), projects }));
};

test('overview state: running within 8 s of activity, then waiting for each prompt pattern, else idle', () => {
  const act = 1_700_000_000;
  assert.equal(stateOf('Proceed? (y/n)', act, act * 1000 + 8000), 'running'); // the 8 s boundary is still running
  assert.equal(stateOf('plain output', act, act * 1000 + 8001), 'idle');
  const samples = ['Overwrite? (y/n)', 'Apply [y/n]', 'Install [Y/n]', 'Delete [y/N]', 'Answer yes/no', 'Do you want to make this edit?',
    'Allow this command?', 'Approve the plan', 'Proceed?', 'Continue? ', 'Press Enter to continue', '❯ 1. Yes', '> 1. Yes, allow once'];
  assert.equal(samples.length, WAIT_PATTERNS.length + 1); // one per pattern, plus the "> 1." form
  WAIT_PATTERNS.forEach((re, i) => assert.ok(re.test(samples[i]), String(re)));
  assert.ok(WAIT_PATTERNS.at(-1).test(samples.at(-1)));
  for (const line of samples) {
    assert.equal(stateOf(`some output\n${line}\n\n`, act, act * 1000 + 9000), 'waiting', line);
    assert.equal(stateOf(`${line.toUpperCase()}`, act, act * 1000 + 9000), 'waiting', line.toUpperCase());
  }
  // only the last 6 non-empty lines count
  assert.equal(stateOf(['Proceed? (y/n)', '1', '2', '3', '4', '5', '6', ''].join('\n'), act, act * 1000 + 9000), 'idle');
  assert.equal(stateOf(['Proceed? (y/n)', '1', '', '2', '3', '4', '5', '', ''].join('\n'), act, act * 1000 + 9000), 'waiting');
  for (const plain of ['compiling src/main.rs', 'all tests passed', 'allowed = 3', 'continue', '$ ']) assert.equal(stateOf(plain, act, act * 1000 + 9000), 'idle', plain);
});

test('overview preview: ANSI, controls, box drawing, prompt chrome, long lines, code-point boundary', () => {
  const ch = (...cps) => String.fromCodePoint(...cps);
  assert.equal(previewOf(`${ESC}[1;31mError:${ESC}[0m build failed\n\n`), 'Error: build failed');
  assert.equal(previewOf(`${ESC}]0;title${String.fromCharCode(7)}done`), 'done');
  assert.equal(previewOf('Writing tests\n╭──────────╮\n│ >        │\n╰──────────╯\n  ❯ \n$\n'), 'Writing tests');
  assert.equal(previewOf('│ Edited 3 files │'), 'Edited 3 files');
  assert.equal(previewOf(`a${ch(0x85)}b${ch(0x202e)}c${ch(0x1)}d\tz`), 'abcd z');
  assert.equal(previewOf(''), null);
  assert.equal(previewOf('───\n>\n'), null);
  const long = 'x'.repeat(500);
  assert.equal(previewOf(long), 'x'.repeat(160));
  const emoji = ch(0x1f600);
  const p = previewOf('a'.repeat(159) + emoji + emoji);
  assert.equal(Array.from(p).length, 160);
  assert.ok(p.endsWith(emoji)); // never half a surrogate pair
  // waiting: the preview is the last matched prompt line, cleaned; otherwise the last real line
  const act = 1_700_000_000;
  assert.deepEqual(summarize(`│ Do you want to proceed? │\n${ESC}[1m  Overwrite foo? (y/n)${ESC}[0m\n  some hint\n╰───╯\n`, act, act * 1000 + 9000), { state: 'waiting', preview: 'Overwrite foo? (y/n)', menu: false });
  assert.deepEqual(summarize('│ Do you want to proceed? │\nchoose below\n', act, act * 1000 + 9000), { state: 'waiting', preview: 'Do you want to proceed?', menu: false });
  assert.deepEqual(summarize('Proceed? (y/n)\n', act, act * 1000 + 1000), { state: 'running', preview: 'Proceed? (y/n)', menu: false });
  assert.equal(summarize(`${'y'.repeat(170)} (y/n)`, act, act * 1000 + 9000).preview, 'y'.repeat(160));
  assert.deepEqual(summarize('built ok\n$ \n', act, act * 1000 + 9000), { state: 'idle', preview: 'built ok', menu: false });
  assert.deepEqual(parseShortstat(' 2 files changed, 3 insertions(+), 1 deletion(-)'), { files: 2, add: 3, del: 1 });
  assert.deepEqual(parseShortstat(' 1 file changed, 1 deletion(-)'), { files: 1, add: 0, del: 1 });
  assert.deepEqual(parseShortstat(' 1 file changed, 1 insertion(+)'), { files: 1, add: 1, del: 0 });
  assert.deepEqual(parseShortstat(' 1 file changed, 1 insertion(+), 1 deletion(-)'), { files: 1, add: 1, del: 1 });
  assert.deepEqual(parseShortstat(''), { files: 0, add: 0, del: 0 });
});

test('GET /api/overview: sessions with state and preview, one bad item gives nulls, response 200', async () => {
  let t = 1_700_000_200_000;
  await withApp(async (c) => {
    const { cookie } = await c.login();
    assert.equal((await c.req('GET', '/api/overview')).status, 401);
    let r = await c.req('GET', '/api/overview', { cookie });
    assert.equal(r.status, 200);
    assert.deepEqual(r.json.sessions, []);
    assert.equal(r.json.now, 1_700_000_200);
    assert.deepEqual(r.json.projects.map((x) => [x.name, x.branch, x.ahead, x.diff]), [['alpha', null, null, null], ['my.proj', null, null, null]]);
    for (const n of ['busy', 'ask', 'rest', 'gone']) assert.equal((await mkSession(c, cookie, n)).status, 201);
    setSession(c, 'busy', { activity: 1_700_000_195, screen: 'cargo build\n   Compiling foo\n' });
    setSession(c, 'ask', { activity: 1_700_000_100, screen: `Edit file?\n${ESC}[7m❯ 1. Yes${ESC}[0m\n  2. No\n╰────╯\n` });
    setSession(c, 'rest', { activity: 1_700_000_100, screen: 'done.\n$ \n', secret: 'never' });
    setSession(c, 'gone', { activity: 1_700_000_100, windowActivity: 1_700_000_197 }); // pane output 3 s ago: running
    r = await c.req('GET', '/api/overview', { cookie });
    assert.equal(r.status, 200);
    const by = Object.fromEntries(r.json.sessions.map((x) => [x.name, x]));
    assert.deepEqual(Object.keys(by.busy).sort(), ['activity', 'attached', 'created', 'harness', 'menu', 'name', 'preview', 'project', 'state']);
    assert.deepEqual([by.busy.state, by.busy.preview, by.busy.project, by.busy.harness], ['running', 'Compiling foo', 'alpha', 'shell']);
    assert.deepEqual([by.ask.state, by.ask.preview, by.ask.menu], ['waiting', '❯ 1. Yes', true]); // waiting: the matched prompt line
    assert.deepEqual([by.rest.state, by.rest.preview, by.rest.menu], ['idle', 'done.', false]);
    assert.deepEqual([by.gone.state, by.gone.activity], ['running', 1_700_000_197]); // window_activity counts
    // capture of the visible pane only: no -S history, no -e escapes
    const caps = c.calls().filter((x) => x.argv[0] === 'capture-pane' && x.argv.includes('=ask:'));
    assert.deepEqual(caps.at(-1).argv, ['capture-pane', '-p', '-J', '-t', '=ask:']);
    // a session that vanishes between list and capture: nulls for it, 200 for the rest
    const st = JSON.parse(fs.readFileSync(fakeState(c), 'utf8'));
    st.sessions.gone.screen = undefined;
    fs.writeFileSync(fakeState(c), JSON.stringify(st));
    await withEnv({ FAKE_TMUX_SCREEN_FILE: path.join(c.root, 'missing-file') }, async () => { // capture-pane fails for "gone" only
      r = await c.req('GET', '/api/overview', { cookie });
    });
    assert.equal(r.status, 200);
    const g = r.json.sessions.find((x) => x.name === 'gone');
    assert.deepEqual([g.state, g.preview, g.menu], [null, null, null]);
    assert.equal(r.json.sessions.find((x) => x.name === 'ask').state, 'waiting');
    assert.ok(!r.text.includes('never'));
  }, { now: () => t, git: NO_GIT });
});

const git = (dir, ...args) => {
  const r = spawnSync('git', ['-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@t', '-c', 'commit.gpgsign=false', ...args], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  return r.stdout;
};
test('overview git: branch, diff and ahead parsed; a non-repo gives nulls; cached for 10 s per project', async () => {
  let t = 1_700_000_200_000;
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pc-git-'));
  try {
    const repo = path.join(tmp, 'repo'); const plain = path.join(tmp, 'plain');
    fs.mkdirSync(repo); fs.mkdirSync(plain);
    git(repo, 'init', '-q', '-b', 'main');
    fs.writeFileSync(path.join(repo, 'a.txt'), 'one\ntwo\n');
    git(repo, 'add', '.'); git(repo, 'commit', '-q', '-m', 'one');
    git(repo, 'branch', 'base'); git(repo, 'branch', '--set-upstream-to=base');
    fs.writeFileSync(path.join(repo, 'b.txt'), 'b\n');
    git(repo, 'add', '.'); git(repo, 'commit', '-q', '-m', 'two');
    fs.writeFileSync(path.join(repo, 'a.txt'), 'one\nTWO\nthree\n'); // 2 insertions, 1 deletion
    // a ceiling stops git from finding a repo above the plain dir
    await withEnv({ GIT_CEILING_DIRECTORIES: tmp }, () => withApp(async (c) => {
      const { cookie } = await c.login();
      setProjects(c, { repo, plain });
      const pr = async () => Object.fromEntries((await c.req('GET', '/api/overview', { cookie })).json.projects.map((x) => [x.name, x]));
      let p = await pr();
      assert.deepEqual(p.repo, { name: 'repo', branch: 'main', ahead: 1, diff: { files: 1, add: 2, del: 1 } });
      assert.deepEqual(p.plain, { name: 'plain', branch: null, ahead: null, diff: null });
      fs.writeFileSync(path.join(repo, 'b.txt'), 'b\nc\n');
      t += 9999;
      assert.deepEqual((await pr()).repo.diff, { files: 1, add: 2, del: 1 }); // cache hit
      t += 1;
      assert.deepEqual((await pr()).repo.diff, { files: 2, add: 3, del: 1 }); // refreshed after 10 s
      git(repo, 'checkout', '-q', '-b', 'feature');
      t += 10000;
      p = await pr();
      assert.equal(p.repo.branch, 'feature');
      assert.equal(p.repo.ahead, null); // no upstream
      assert.ok(!fs.existsSync(path.join(repo, '.git', 'index.lock')));
    }, { now: () => t }));
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
});

test('overview gate: one read slot for the whole job, 503 when the read slots are full', () => withApp(async (c) => {
  const { cookie } = await c.login();
  for (const n of ['s1', 's2', 's3']) await mkSession(c, cookie, n);
  // screens hold their 2 slots for 3 s; each overview capture takes 250 ms
  await withEnv({ FAKE_TMUX_DELAYS: JSON.stringify({ 'display-message': 3000, 'capture-pane -S': 3000, 'capture-pane': 250 }) }, async () => {
    const screens = Array.from({ length: 3 }, () => c.req('GET', '/api/screen/s1', { cookie }));
    assert.ok(await until(() => c.app.stats().reads === 6, 3000));
    const before = c.calls().length;
    const ov = c.req('GET', '/api/overview', { cookie });
    assert.ok(await until(() => c.app.stats().reads === 7, 1000), `reads=${c.app.stats().reads}`); // 6 screens + the overview
    const samples = [];
    const iv = setInterval(() => samples.push(c.app.stats().reads), 2);
    const second = await c.req('GET', '/api/overview', { cookie }); // while the first one runs
    assert.deepEqual([second.status, second.json], [503, { error: 'busy' }]);
    const r = await ov;
    clearInterval(iv);
    assert.equal(r.status, 200);
    assert.equal(r.json.sessions.length, 3);
    // 7 for the whole job (one held slot, never per child), then 6 once it has released it
    const six = samples.indexOf(6) < 0 ? samples.length : samples.indexOf(6);
    assert.ok(six > 10 && samples.slice(0, six).every((x) => x === 7) && samples.slice(six).every((x) => x === 6), `reads during the overview: ${samples.join(',')}`);
    assert.equal(c.app.stats().reads, 6); // the screens still hold theirs
    assert.ok(maxOverlap(c.calls().slice(before).filter((x) => x.argv[0] === 'list-sessions' || (x.argv[0] === 'capture-pane' && !x.argv.includes('-S')))) <= 1);
    await Promise.all(screens);
  });
  assert.ok(await until(() => c.app.stats().reads === 0 && c.app.stats().running === 0));
}, { git: NO_GIT }));

test('overview gate: a revoke during the job stops it at the gate (401, no further child)', () => withApp(async (c) => {
  const a = await c.login({}, 'victim');
  for (const n of ['s1', 's2', 's3', 's4']) await mkSession(c, a.cookie, n);
  await withEnv({ FAKE_TMUX_DELAY_MS: '250' }, async () => {
    const before = c.calls().length;
    const ov = c.req('GET', '/api/overview', { cookie: a.cookie });
    assert.ok(await until(() => c.app.stats().running === 1, 3000));
    assert.deepEqual(await adminRequest(c.configDir, { cmd: 'revoke', id: await c.deviceId('victim') }), { ok: true, revoked: 1 });
    assert.equal((await ov).status, 401);
    await sleep(400);
    const caps = c.calls().slice(before).filter((x) => x.argv[0] === 'capture-pane');
    assert.ok(caps.length <= 1, `captures after revoke: ${caps.length}`);
  });
  assert.ok(await until(() => c.app.stats().reads === 0 && c.app.stats().running === 0));
}, { git: NO_GIT }));

// ---- POST /api/open fresh:true (A5 update 4) ----
const openReq = (c, cookie, body) => c.req('POST', '/api/open', { cookie, body: { project: 'alpha', harness: 'shell', ...body } });
test('open fresh: base, then base-2, base-3; never reuses; without fresh the old reuse stays', () => withApp(async (c) => {
  const { cookie } = await c.login();
  const names = [];
  for (let i = 0; i < 3; i++) {
    const r = await openReq(c, cookie, { fresh: true });
    assert.equal(r.status, 200, JSON.stringify(r.json));
    assert.equal(r.json.created, true);
    names.push(r.json.name);
  }
  assert.deepEqual(names, ['alpha-shell', 'alpha-shell-2', 'alpha-shell-3']);
  const old = await openReq(c, cookie, {});
  assert.deepEqual(old.json, { name: 'alpha-shell', created: false }); // reuse, as before
  assert.equal((await c.req('DELETE', '/api/sessions/alpha-shell-2', { cookie })).status, 200);
  assert.equal((await openReq(c, cookie, { fresh: true })).json.name, 'alpha-shell-2'); // the first free name
  assert.equal((await openReq(c, cookie, { fresh: 'yes' })).status, 400);
  const st = JSON.parse(fs.readFileSync(fakeState(c), 'utf8'));
  assert.deepEqual(Object.keys(st.sessions).sort(), ['alpha-shell', 'alpha-shell-2', 'alpha-shell-3']);
  assert.equal(st.sessions['alpha-shell-3'].opts['@pc_project'], 'alpha');
}));

test('open fresh: long project names keep the suffix within 32 chars; concurrent fresh opens get different names', () => withApp(async (c) => {
  const { cookie } = await c.login();
  const long = 'a-very-long-project-name-for-tests-x';
  setProjects(c, { [long]: ABS });
  const o = (body) => c.req('POST', '/api/open', { cookie, body: { project: long, harness: 'claude', fresh: true, ...body } });
  const r1 = await o(); const r2 = await o();
  assert.equal(r1.json.name, 'a-very-long-project-name-for-tes');
  assert.equal(r2.json.name, 'a-very-long-project-name-for-t-2');
  for (let i = 3; i <= 10; i++) assert.equal((await o()).json.name, i < 10 ? `a-very-long-project-name-for-t-${i}` : 'a-very-long-project-name-for-10'); // a trailing "-" of the cut base is dropped
  for (const n of [r1.json.name, r2.json.name]) assert.ok(n.length <= 32);
  setProjects(c, { alpha: ABS });
  const par = await Promise.all(Array.from({ length: 5 }, () => openReq(c, cookie, { fresh: true })));
  assert.ok(par.every((r) => r.status === 200 && r.json.created === true));
  assert.equal(new Set(par.map((r) => r.json.name)).size, 5);
}));

test('overview git: every call is execFile git -C <dir> with GIT_OPTIONAL_LOCKS=0, one round per project per 10 s', async () => {
  let t = 1_700_000_200_000;
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pc-fgit-'));
  const logFile = path.join(tmp, 'git.jsonl');
  const fakeGit = path.join(tmp, 'git.cjs'); // logs argv + env, then fails like "not a git repository"
  fs.writeFileSync(fakeGit, `require('fs').appendFileSync(${JSON.stringify(logFile)}, JSON.stringify({ argv: process.argv.slice(2), lock: process.env.GIT_OPTIONAL_LOCKS }) + String.fromCharCode(10)); process.exit(128);`);
  const calls = () => { try { return fs.readFileSync(logFile, 'utf8').trim().split('\n').map((l) => JSON.parse(l)); } catch { return []; } };
  try {
    await withApp(async (c) => {
      const { cookie } = await c.login();
      assert.equal((await c.req('GET', '/api/overview', { cookie })).status, 200);
      // alpha and my.proj share one dir: the cache is per dir, so one call; a failed rev-parse stops that project's round
      assert.deepEqual(calls(), [{ argv: ['-C', ABS, '-c', 'core.fsmonitor=false', 'rev-parse', '--abbrev-ref', 'HEAD'], lock: '0' }]);
      t += 9999;
      await c.req('GET', '/api/overview', { cookie });
      assert.equal(calls().length, 1); // cache hit
      t += 1;
      await c.req('GET', '/api/overview', { cookie });
      assert.equal(calls().length, 2); // refreshed after 10 s
    }, { now: () => t, git: [process.execPath, fakeGit] });
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
});

// ======================= A4 update r3: single instance =======================
const LOCK_MSG = /Một máy chủ FCode khác đang dùng thư mục cấu hình này/;
const freePort = () => new Promise((resolve) => { const s = net.createServer().listen(0, '127.0.0.1', () => { const { port } = s.address(); s.close(() => resolve(port)); }); });
// the real server as a child: resolves {listening, child} once it serves, or {code, err} when it exits first
async function startServer(configDir) {
  const port = await freePort();
  const child = spawn(process.execPath, [SERVER], { env: { ...process.env, PC_CONFIG_DIR: configDir, PC_PORT: String(port) }, stdio: ['ignore', 'pipe', 'pipe'] });
  let out = '', err = '';
  return new Promise((resolve) => {
    child.stdout.on('data', (d) => { out += d; if (out.includes('fcoding listening')) resolve({ listening: true, child, port }); });
    child.stderr.on('data', (d) => { err += d; });
    child.on('exit', (code, signal) => resolve({ listening: false, code, signal, err, child }));
  });
}
const stop = (r) => new Promise((resolve) => { if (r.child.exitCode !== null || r.child.signalCode) return resolve(); r.child.once('exit', () => resolve()); r.child.kill('SIGTERM'); });
const fileId = (f) => { const st = fs.lstatSync(f); return `${st.ino}:${st.mtimeMs}`; };
const freshDir = async () => { const c = await boot(); await c.login({}, 'phone'); await c.app.close(); return c; }; // config + devices.json, no server

test('instance lock: in-process, a second lock on the same config dir is refused; another dir is fine; free after close', async () => {
  const a = fs.mkdtempSync(path.join(os.tmpdir(), 'pc-lock-')); const b = fs.mkdtempSync(path.join(os.tmpdir(), 'pc-lock-'));
  try {
    const l1 = await acquireInstanceLock(a);
    await assert.rejects(acquireInstanceLock(a), LOCK_MSG);
    await assert.rejects(acquireInstanceLock(path.join(a, '.', '')), LOCK_MSG); // same real path
    const l2 = await acquireInstanceLock(b);
    await new Promise((r) => l1.close(r));
    const l3 = await acquireInstanceLock(a);
    await Promise.all([l2, l3].map((l) => new Promise((r) => l.close(r))));
  } finally { for (const d of [a, b]) fs.rmSync(d, { recursive: true, force: true }); }
});

test('instance lock: a second server on the same config dir (sequential and concurrent) exits 1 and touches nothing', async (t) => {
  if (process.platform === 'win32') return t.skip('spawns listening servers: box only');
  const c = await freshDir();
  const sock = adminPath(c.configDir); const dev = path.join(c.configDir, 'devices.json');
  const running = [];
  try {
    const a = await startServer(c.configDir); running.push(a);
    assert.ok(a.listening, a.err);
    const before = [fileId(sock), fileId(dev)];
    const b = await startServer(c.configDir); running.push(b);
    assert.deepEqual([b.listening, b.code], [false, 1]);
    assert.match(b.err, LOCK_MSG);
    assert.deepEqual([fileId(sock), fileId(dev)], before);
    assert.equal((await adminRequest(c.configDir, { cmd: 'devices' })).devices.length, 1); // the first one still answers
    await stop(a);
    const pair = await Promise.all([startServer(c.configDir), startServer(c.configDir)]); running.push(...pair);
    const ok = pair.filter((r) => r.listening); const refused = pair.filter((r) => !r.listening);
    assert.equal(ok.length, 1, pair.map((r) => r.err).join(' | '));
    assert.deepEqual([refused[0].code, LOCK_MSG.test(refused[0].err)], [1, true]);
    const id = fileId(sock);
    await sleep(200);
    assert.equal(fileId(sock), id); // the loser never unlinked the winner's socket
    assert.equal((await adminRequest(c.configDir, { cmd: 'devices' })).devices.length, 1);
  } finally { await Promise.all(running.map(stop)); fs.rmSync(c.root, { recursive: true, force: true }); }
});

test('instance lock: after SIGKILL a new start succeeds at once and replaces the stale admin.sock', async (t) => {
  if (process.platform === 'win32') return t.skip('spawns listening servers: box only');
  const c = await freshDir();
  const sock = adminPath(c.configDir);
  const running = [];
  try {
    const a = await startServer(c.configDir); running.push(a);
    assert.ok(a.listening, a.err);
    const ino = fs.lstatSync(sock).ino;
    await new Promise((r) => { a.child.once('exit', r); a.child.kill('SIGKILL'); });
    assert.ok(fs.lstatSync(sock).isSocket()); // left behind by the crash
    const b = await startServer(c.configDir); running.push(b);
    assert.ok(b.listening, b.err);
    assert.notEqual(fs.lstatSync(sock).ino, ino);
    assert.equal(fs.statSync(sock).mode & 0o777, 0o600);
    assert.equal((await adminRequest(c.configDir, { cmd: 'pair' })).ok, true);
  } finally { await Promise.all(running.map(stop)); fs.rmSync(c.root, { recursive: true, force: true }); }
});

test('instance lock: different config dirs run side by side', async (t) => {
  if (process.platform === 'win32') return t.skip('spawns listening servers: box only');
  const c1 = await freshDir(); const c2 = await freshDir();
  const running = [];
  try {
    const rs = await Promise.all([startServer(c1.configDir), startServer(c2.configDir)]); running.push(...rs);
    assert.ok(rs.every((r) => r.listening), rs.map((r) => r.err).join(' | '));
    for (const c of [c1, c2]) assert.equal((await adminRequest(c.configDir, { cmd: 'devices' })).ok, true);
  } finally { await Promise.all(running.map(stop)); for (const c of [c1, c2]) fs.rmSync(c.root, { recursive: true, force: true }); }
});

// ======================= A5 rework r1 =======================
// a fake git: logs argv; rev-parse prints `branch` (or fails like a non-repo), diff prints nothing, rev-list fails
const fakeGitIn = (tmp, { branch = null, sleepMs = 0 } = {}) => {
  const logFile = path.join(tmp, 'git.jsonl'); const file = path.join(tmp, 'git.cjs');
  fs.writeFileSync(file, `const fs = require('fs'), a = process.argv.slice(2);
fs.appendFileSync(${JSON.stringify(logFile)}, JSON.stringify(a) + String.fromCharCode(10));
if (${sleepMs}) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ${sleepMs});
const sub = a[4];
if (sub === 'rev-parse') { if (${JSON.stringify(branch)} === null) process.exit(128); process.stdout.write(${JSON.stringify(branch)} + String.fromCharCode(10)); }
else if (sub === 'rev-list') process.exit(128);`);
  return { spec: [process.execPath, file], calls: () => { try { return fs.readFileSync(logFile, 'utf8').trim().split('\n').map((l) => JSON.parse(l)); } catch { return []; } } };
};

test('overview git: a revoke during a slow git call caches nothing; the next overview runs git again', async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pc-fgit-'));
  const g = fakeGitIn(tmp, { sleepMs: 400 });
  try {
    await withApp(async (c) => {
      const a = await c.login({}, 'victim');
      const ov = c.req('GET', '/api/overview', { cookie: a.cookie });
      assert.ok(await until(() => g.calls().length === 1 && c.app.stats().running === 1, 3000));
      assert.deepEqual(await adminRequest(c.configDir, { cmd: 'revoke', id: await c.deviceId('victim') }), { ok: true, revoked: 1 });
      assert.equal((await ov).status, 401);
      const b = await c.login({}, 'next');
      assert.equal((await c.req('GET', '/api/overview', { cookie: b.cookie })).status, 200);
      assert.equal(g.calls().length, 2); // git ran again: the stopped round was not cached
      assert.equal((await c.req('GET', '/api/overview', { cookie: b.cookie })).status, 200);
      assert.equal(g.calls().length, 2); // the completed round is
    }, { git: g.spec });
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
});

test('overview git: concurrent cold overviews share one git run per dir; a stopped owner hands over', async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pc-fgit-'));
  const g = fakeGitIn(tmp, { branch: 'main', sleepMs: 300 });
  try {
    await withApp(async (c) => {
      const { cookie } = await c.login({}, 'one');
      const rs = await Promise.all(Array.from({ length: 4 }, () => c.req('GET', '/api/overview', { cookie })));
      assert.ok(rs.every((r) => r.status === 200 && r.json.projects[0].branch === 'main'));
      assert.equal(g.calls().filter((x) => x[4] === 'rev-parse').length, 1); // one round for ABS, shared
      // the owner of a cold round is revoked mid-way: a waiting overview runs its own round
      fs.rmSync(path.join(tmp, 'git.jsonl'));
      const f = path.join(c.configDir, 'config.json');
      writePrivate(f, JSON.stringify({ ...JSON.parse(fs.readFileSync(f, 'utf8')), projects: { fresh: tmp } })); // a cold dir
      const victim = await c.login({}, 'victim');
      const first = c.req('GET', '/api/overview', { cookie: victim.cookie });
      assert.ok(await until(() => g.calls().length === 1, 3000));
      const second = c.req('GET', '/api/overview', { cookie });
      await sleep(50);
      await adminRequest(c.configDir, { cmd: 'revoke', id: await c.deviceId('victim') });
      assert.equal((await first).status, 401);
      const s2 = await second;
      assert.equal(s2.status, 200);
      assert.equal(s2.json.projects[0].branch, 'main');
    }, { git: g.spec });
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
});

test('overview git: the branch name is cleaned like a preview (bidi, zero-width, 160 code points)', async () => {
  const ch = (...cps) => String.fromCodePoint(...cps);
  for (const [raw, want] of [[`main${ch(0x202e)}evil`, 'mainevil'], [`fe${ch(0x200b, 0xfeff)}at`, 'feat'], ['b'.repeat(300), 'b'.repeat(160)], [ch(0x202e), null]]) {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pc-fgit-'));
    const g = fakeGitIn(tmp, { branch: raw });
    try {
      await withApp(async (c) => {
        const { cookie } = await c.login();
        const p = (await c.req('GET', '/api/overview', { cookie })).json.projects[0];
        assert.equal(p.branch, want);
        if (want) assert.deepEqual(p.diff, { files: 0, add: 0, del: 0 });
      }, { git: g.spec });
    } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
  }
});

test('names and previews lose U+061C, U+200B-U+200D, U+2060 and U+FEFF', () => withApp(async (c) => {
  const ch = (...cps) => String.fromCharCode(...cps);
  const raw = `a${ch(0x61c)}b${ch(0x200b)}c${ch(0x200c)}d${ch(0x200d)}e${ch(0x2060)}f${ch(0xfeff)}g`;
  assert.equal(previewOf(raw), 'abcdefg');
  await c.login({}, raw);
  assert.deepEqual(devicesFile(c).map((d) => d.name), ['abcdefg']);
}));

test('a numbered choice inside box drawing is waiting; the preview is the inner line', () => {
  const act = 1_700_000_000, t = act * 1000 + 9000;
  assert.deepEqual(summarize('╭──────────╮\n│ Edit file? │\n│ ❯ 1. Yes   │\n│   2. No    │\n╰──────────╯\n', act, t), { state: 'waiting', preview: '❯ 1. Yes', menu: true });
  assert.deepEqual(summarize('┃ > 2. Always allow ┃', act, t), { state: 'waiting', preview: '> 2. Always allow', menu: true });
  assert.equal(stateOf('│ step 1. done │', act, t), 'idle');
});

test('waiting preview: the question line, not a numbered option (plain and boxed)', () => {
  const act = 1_700_000_000, t = act * 1000 + 9000;
  const want = { state: 'waiting', preview: 'Do you want to proceed?', menu: true };
  assert.deepEqual(summarize('Do you want to proceed?\n❯ 1. Yes\n2. No\n', act, t), want);
  assert.deepEqual(summarize('╭───────────────────────────╮\n│ Do you want to proceed?   │\n│ ❯ 1. Yes                  │\n│   2. No                   │\n╰───────────────────────────╯\n', act, t), want);
  assert.deepEqual(summarize('Allow this command?\n› 1. Yes\n> 2. Yes, and always allow\n', act, t), { state: 'waiting', preview: 'Allow this command?', menu: true });
  // only options match: the last of them
  assert.deepEqual(summarize('Pick one\n❯ 1. Yes\n> 2. Always allow\n', act, t), { state: 'waiting', preview: '> 2. Always allow', menu: true });
});

test('open fresh: a name created outside the server meanwhile moves on to base-2', () => withApp(async (c) => {
  const { cookie } = await c.login();
  await withEnv({ FAKE_TMUX_DUP_ONCE: 'alpha-shell' }, async () => {
    const r = await openReq(c, cookie, { fresh: true });
    assert.deepEqual([r.status, r.json], [200, { name: 'alpha-shell-2', created: true }]);
  });
  const st = JSON.parse(fs.readFileSync(fakeState(c), 'utf8'));
  assert.deepEqual(Object.keys(st.sessions), ['alpha-shell-2']);
  assert.ok(c.calls().some((x) => x.argv[0] === 'new-session' && x.argv.includes('alpha-shell')));
}));

test('overview: a client disconnect mid-job frees the read slot and starts no later capture', () => withApp(async (c) => {
  const { cookie } = await c.login();
  for (const n of ['s1', 's2', 's3', 's4']) await mkSession(c, cookie, n);
  await withEnv({ FAKE_TMUX_DELAYS: JSON.stringify({ 'capture-pane': 400 }) }, async () => {
    const req = http.get({ host: '127.0.0.1', port: c.port, path: '/api/overview', headers: { 'X-PC': '1', Cookie: cookie } });
    req.on('error', () => {});
    assert.ok(await until(() => c.calls().length >= 0 && c.app.stats().running === 1 && c.app.stats().reads === 1, 3000));
    await sleep(150); // inside list-sessions or the first, delayed capture
    req.destroy();
    assert.ok(await until(() => c.app.stats().reads === 0 && c.app.stats().running === 0, 3000), JSON.stringify(c.app.stats()));
    await sleep(900);
    const caps = c.calls().filter((x) => x.argv[0] === 'capture-pane');
    assert.ok(caps.length <= 1, `captures: ${caps.length} (at most the one in flight; 4 without the gate)`);
    assert.equal(c.app.stats().reads, 0);
  });
}, { git: NO_GIT }));

// ======================= A5 update 6: menu flag =======================
test('menu flag: a numbered menu on screen is menu:true even when a y/n line is the preview; line prompts are menu:false', () => {
  const act = 1_700_000_000, t = act * 1000 + 9000;
  // the two screens from the final r3 review: no y/n buttons may be offered on them
  assert.deepEqual(summarize('Overwrite config? (y/n)\n❯ 1. Yes\n2. No\n', act, t), { state: 'waiting', preview: 'Overwrite config? (y/n)', menu: true });
  assert.equal(summarize('Continue? [y/N] y\nPick a model\n❯ 1. Sonnet\n2. Opus\n', act, t).menu, true);
  // real y/n line prompts keep menu:false
  for (const [screen, preview] of [
    ['Proceed? (y/n)', 'Proceed? (y/n)'],
    ['After this operation, 12 MB will be used.\nDo you want to continue? [Y/n] ', 'Do you want to continue? [Y/n]'],
    ["The authenticity of host 'box (1.2.3.4)' can't be established.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? ", 'Are you sure you want to continue connecting (yes/no/[fingerprint])?'],
  ]) assert.deepEqual(summarize(screen, act, t), { state: 'waiting', preview, menu: false }, screen);
  // a boxed Claude Code permission menu
  const boxed = '╭──────────────────────────────────────╮\n│ Bash command                         │\n│   rm -rf build                       │\n│ Do you want to proceed?              │\n│ ❯ 1. Yes                             │\n│   2. No, and tell Claude what to do  │\n╰──────────────────────────────────────╯\n';
  assert.deepEqual(summarize(boxed, act, t), { state: 'waiting', preview: 'Do you want to proceed?', menu: true });
  // the flag does not depend on the state; a numbered line older than the last 6 lines does not count
  assert.equal(summarize('❯ 1. Yes', act, act * 1000).menu, true);
  assert.equal(summarize(['❯ 1. Yes', 'a', 'b', 'c', 'd', 'e', 'Proceed? (y/n)'].join('\n'), act, t).menu, false);
  assert.equal(menuOf('step 1.done\n12.items'), false); // needs "N. " with a space
});

// ======================= v1.1: ansi=1 (SGR colours), tmux pane targets =======================
// SGR in, SGR out: sequences that are not SGR are dropped; odd SGR forms are rewritten so a simple client parses them
test('sgrOnly: keeps SGR only, drops every other escape sequence', () => {
  const E = ESC;
  const same = [`${E}[1;31mred${E}[0m`, `${E}[38;5;208mx${E}[39m`, `${E}[48;2;1;2;3;1mx`, `${E}[90;107mx`, 'plain text, no escapes ắ ẫ', `a${E}[31m\nb`];
  for (const s of same) assert.equal(sgrOnly(s), s);
  const cases = [
    [`${E}[m`, `${E}[0m`], // empty = reset, written out
    [`${E}[?25lx${E}[2Jy${E}[1;1Hz${E}[K`, 'xyz'], // private mode, erase, cursor move, erase-line
    [`${E}]8;;http://example.com${E}\\link${E}]8;;${E}\\`, 'link'], // OSC 8 hyperlink with ST
    [`${E}]0;title\x07after`, 'after'], // OSC with BEL
    [`${E}]0;no end${E}[31mred`, `${E}[31mred`], // an unterminated OSC stops at the next ESC
    [`${E}Pq data${E}\\x${E}_apc\x07y${E}^pm${E}\\z`, 'xyz'], // DCS, APC, PM
    [`${E}(Ba${E}7b${E}8c${E}=d${E}>e`, 'abcde'], // two- and three-byte ESC sequences
    [`tail${E}`, 'tail'], // a lone ESC
    [`${E}[1;3`, ''], // a cut-off CSI
    [`${E}[31 mx${E}[1$mx`, 'xx'], // an intermediate byte: not SGR
    [`${E}[38:2::1:2:3mx${E}[38:2:4:5:6mx${E}[48:5:9mx`, `${E}[38;2;1;2;3mx${E}[38;2;4;5;6mx${E}[48;5;9mx`], // colon forms
    [`${E}[4:3mx${E}[4:0mx${E}[1;4:2mx`, `${E}[4mx${E}[24mx${E}[1;4mx`], // underline styles
    [`${E}[58;2;1;2;3mx${E}[1;58;5;9;3mx${E}[59mx`, `x${E}[1;3mxx`], // underline colour is dropped with its arguments
    [`${E}[38;5mx${E}[38;5;999mx${E}[38;2;1;2mx${E}[1;38;9;1mx`, `xxx${E}[1mx`], // bad or cut-off colours; an unknown mode drops what follows it
    [`${E}[200mx${E}[1;108;3mx`, `x${E}[1;3mx`], // codes above 107
    [`${E}[5:3mx${E}[1;5:3;4mx`, `${E}[53mx${E}[1;53;4mx`], // overline 5:3 is 53, never blink 5
    [`${E}[3:1mx${E}[1:2mx${E}[31:7mx`, 'xxx'], // other colon groups are dropped, never collapsed to their head
    [`${E}[38:2:1:2mx${E}[48:2:1:2mx${E}[38:2::1:2mx${E}[38:5mx${E}[38:5:7:8mx`, `xxxx${E}[38;5;7mx`], // cut-off colon colours are dropped (also with an empty colourspace slot); the next params stay
    [`${E}[1;38:2:1:2;4mx`, `${E}[1;4mx`], // a dropped colon colour does not eat its neighbours
    [`a\x0elqqk\x0fb${E}(0lqk${E}(Bc`, 'alqqkblqkc'], // ACS: SO/SI and charset designation are dropped
  ];
  for (const [from, to] of cases) assert.equal(sgrOnly(from), to, JSON.stringify(from));
  // whatever is left is SGR and nothing else
  assert.ok(!/\x1b(?!\[[0-9;]*m)/.test(sgrOnly(cases.map((x) => x[0]).join('\n'))));
});

test('trimAnsiScreen: lines with only SGR and blanks at the end are blank; spaces on the last real line stay', () => {
  const E = ESC;
  assert.equal(trimAnsiScreen(`a${E}[0m  \n${E}[39m${E}[49m\n   \n${E}[0m\n`), `a${E}[0m  `);
  assert.equal(trimAnsiScreen(`${E}[31mred${E}[0m\n\n${E}[0m\nb${E}[0m`), `${E}[31mred${E}[0m\n\n${E}[0m\nb${E}[0m`);
  assert.equal(trimAnsiScreen(`\n${E}[0m  \n`), '');
  assert.equal(trimAnsiScreen(''), '');
});

test('ansi=1: screen keeps SGR; default is unchanged (no -e); a colour-only change moves the hash', () => withApp(async (c) => {
  const { cookie } = await c.login();
  await mkSession(c, cookie);
  const E = ESC;
  const raw = `${E}[1;31mError${E}[0m: bad\n${E}]8;;http://x${E}\\link${E}]8;;${E}\\\n${E}[?25l${E}[2Jplain${E}[39m${E}[49m\n${E}[0m\n\n`;
  setSession(c, 'work', { screen: raw });
  const caps = () => c.calls().filter((x) => x.argv[0] === 'capture-pane').map((x) => x.argv);
  // default: byte-identical to before: same argv, text exactly what tmux printed (trimmed), nothing added
  const plain = (await c.req('GET', '/api/screen/work', { cookie })).json;
  assert.deepEqual(caps().at(-1), ['capture-pane', '-p', '-J', '-t', '=work:', '-S', '-300']);
  assert.equal(plain.text, trimScreen(raw));
  // ansi=1: -e, and only SGR in the text
  const a = (await c.req('GET', '/api/screen/work?ansi=1&lines=100', { cookie }));
  assert.equal(a.status, 200);
  assert.deepEqual(caps().at(-1), ['capture-pane', '-p', '-e', '-J', '-t', '=work:', '-S', '-100']);
  assert.equal(a.json.text, `${E}[1;31mError${E}[0m: bad\nlink\nplain${E}[39m${E}[49m`);
  assert.deepEqual([a.json.cols, a.json.rows, a.json.cursor], [80, 24, { x: 3, y: 5 }]);
  // any other value of ansi is the plain request
  for (const v of ['0', 'true', '2', '']) {
    await c.req('GET', `/api/screen/work?ansi=${v}`, { cookie });
    assert.ok(!caps().at(-1).includes('-e'), `ansi=${v}`);
  }
  // the hash covers the text as sent: same words, other colour = other hash; the same screen = the same hash
  setSession(c, 'work', { screen: raw.replace('[1;31m', '[1;32m') });
  const b = (await c.req('GET', '/api/screen/work?ansi=1&lines=100', { cookie })).json;
  assert.notEqual(b.hash, a.json.hash);
  assert.equal(b.text, a.json.text.replace('[1;31m', '[1;32m'));
  assert.equal((await c.req('GET', '/api/screen/work?ansi=1&lines=100', { cookie })).json.hash, b.hash);
  // a plain screen is the same either way
  setSession(c, 'work', { screen: 'hello\nworld\n\n' });
  assert.equal((await c.req('GET', '/api/screen/work?ansi=1', { cookie })).json.text, 'hello\nworld');
  assert.equal((await c.req('GET', '/api/screen/work?ansi=1', { cookie })).json.hash, (await c.req('GET', '/api/screen/work', { cookie })).json.hash);
}));

test('ansi=1: SSE stream sends SGR text and a colour-only change is a new event', () => withApp(async (c) => {
  const { cookie } = await c.login();
  await mkSession(c, cookie);
  const E = ESC;
  setSession(c, 'work', { screen: `${E}[31mred${E}[0m ${E}]0;t\x07ok\n` });
  const open = (query) => new Promise((resolve, reject) => {
    let buf = '';
    const req = http.request({ host: '127.0.0.1', port: c.port, path: `/api/stream/work${query}`, headers: { Cookie: cookie } }, (res) => {
      res.setEncoding('utf8');
      res.on('data', (d) => { buf += d; });
      resolve({ req, texts: () => [...buf.matchAll(/event: screen\ndata: (.*)\n/g)].map((m) => JSON.parse(m[1]).text) });
    });
    req.on('error', reject); req.end();
  });
  const s = await open('?ansi=1');
  const p = await open('');
  assert.ok(await until(() => s.texts().length === 1 && p.texts().length === 1));
  assert.deepEqual(s.texts(), [`${E}[31mred${E}[0m ok`]);
  assert.ok(c.calls().some((x) => x.argv[0] === 'capture-pane' && x.argv.includes('-e')));
  setSession(c, 'work', { screen: `${E}[32mred${E}[0m ${E}]0;t\x07ok\n` });
  assert.ok(await until(() => s.texts().length === 2), 'a colour-only change did not reach the ansi stream');
  assert.deepEqual(s.texts()[1], `${E}[32mred${E}[0m ok`);
  s.req.destroy(); p.req.destroy();
  assert.ok(await until(() => c.app.stats().streams === 0));
}));

test('prompt detection works on coloured text (SGR stripped before matching)', () => withApp(async (c) => {
  const E = ESC, act = 1_700_000_000, t = act * 1000 + 9000;
  const coloured = `${E}[1mDo you${E}[0m ${E}[33mwant${E}[0m to ${E}[4mproceed${E}[24m?\n${E}[7m❯ 1. Yes${E}[0m\n  ${E}[2m2. No${E}[0m\n`;
  const want = { state: 'waiting', preview: 'Do you want to proceed?', menu: true };
  assert.deepEqual(summarize(coloured, act, t), want);
  assert.deepEqual(summarize('Do you want to proceed?\n❯ 1. Yes\n  2. No\n', act, t), want); // the same words without colour
  assert.deepEqual(summarize(`${E}[32mProceed? ${E}[0m${E}[1m(y/n)${E}[0m`, act, t), { state: 'waiting', preview: 'Proceed? (y/n)', menu: false });
  assert.equal(previewOf(`${E}[31mfailed${E}[0m\n${E}[2m$ ${E}[0m`), 'failed');
  assert.equal(menuOf(`${E}[36m❯${E}[0m 1. A\n`), true);
  // end to end: the ansi screen the server sends, fed to the same matcher, gives the same answer
  const { cookie } = await c.login();
  await mkSession(c, cookie);
  setSession(c, 'work', { activity: 1_700_000_100, screen: `${coloured}${E}]8;;http://x${E}\\${E}\\\n` });
  const sc = (await c.req('GET', '/api/screen/work?ansi=1', { cookie })).json;
  assert.ok(!/\x1b(?!\[[0-9;]*m)/.test(sc.text));
  assert.deepEqual(summarize(sc.text, act, t), want);
  // overview: the pane is read without -e, and a coloured prompt is still "waiting"
  const ov = (await c.req('GET', '/api/overview', { cookie })).json.sessions.find((x) => x.name === 'work');
  assert.deepEqual([ov.state, ov.preview, ov.menu], ['waiting', 'Do you want to proceed?', true]);
  assert.ok(!c.calls().filter((x) => x.argv[0] === 'capture-pane' && !x.argv.includes('-S')).some((x) => x.argv.includes('-e')));
}));

test('tmux targets: panes are =name:, session-only commands are =name; a bare =name is refused by the fake like real tmux', () => withApp(async (c) => {
  const { cookie } = await c.login();
  await mkSession(c, cookie); // new-session, set-option x2, has-session
  const ok = async (p, body) => assert.equal((await c.req('POST', p, { cookie, body })).status, 200, p);
  await ok('/api/send/work', { text: 'one line', enter: true });
  await ok('/api/send/work', { text: 'two\nlines', enter: true }); // load-buffer + paste-buffer
  await ok('/api/key/work', { key: 'Up' });
  await ok('/api/resize/work', { cols: 80, rows: 24 });
  for (const q of ['', '?ansi=1']) assert.equal((await c.req('GET', `/api/screen/work${q}`, { cookie })).status, 200);
  assert.equal((await c.req('GET', '/api/overview', { cookie })).status, 200);
  assert.equal((await c.req('DELETE', '/api/sessions/work', { cookie })).status, 200);
  const seen = new Set();
  for (const { argv } of c.calls()) {
    const i = argv.indexOf('-t');
    if (i < 0) continue;
    seen.add(argv[0]);
    assert.match(argv[i + 1], ['kill-session', 'has-session'].includes(argv[0]) ? /^=work$/ : /^=work:$/, argv.join(' '));
  }
  for (const cmd of ['set-option', 'has-session', 'capture-pane', 'display-message', 'send-keys', 'paste-buffer', 'resize-window', 'kill-session']) assert.ok(seen.has(cmd), `${cmd} was not exercised`);
  // the fake follows real tmux: a bare session target does not resolve a pane
  const fake = (...args) => spawnSync(process.execPath, [FAKE, ...args], { env: { ...process.env, FAKE_TMUX_DIR: path.join(c.root, 'fake') }, encoding: 'utf8' });
  await mkSession(c, cookie);
  for (const cmd of [['capture-pane', '-p'], ['send-keys'], ['resize-window', '-x', '80'], ['display-message', '-p'], ['paste-buffer'], ['set-option', '@x', '1']]) {
    const bare = fake(cmd[0], '-t', '=work', ...cmd.slice(1)), colon = fake(cmd[0], '-t', '=work:', ...cmd.slice(1));
    assert.equal(bare.status, 1, `${cmd[0]} =work`);
    assert.match(bare.stderr, /can't find pane/);
    assert.equal(colon.status, 0, `${cmd[0]} =work:`);
  }
  assert.equal(fake('has-session', '-t', '=work').status, 0);
}));
