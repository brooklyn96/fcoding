// Fake tmux for tests: records argv + stdin (JSONL) and keeps a tiny session table.
// Env: FAKE_TMUX_DIR (state.json, log.jsonl), FAKE_TMUX_DELAY_MS, FAKE_TMUX_SCREEN (JSON string) or FAKE_TMUX_SCREEN_FILE,
// FAKE_TMUX_BIG, FAKE_TMUX_EXIT (new-session succeeds but the harness exits at once, like tmux 3.5a),
// FAKE_TMUX_EXIT_AFTER_MS (the harness exits that many ms after new-session; seen by has-session only),
// FAKE_TMUX_EXIT_AT_OPTION (the harness exits while that option is being set: set-option -> "no such session").
// Per session in state.json (tests may edit it): activity (session_activity, unix s, default 1700000100),
// windowActivity (window_activity, default 0), screen (capture-pane text).
// FAKE_TMUX_DELAYS: JSON {command: ms}, overrides FAKE_TMUX_DELAY_MS per command ("capture-pane -S": only captures with history).
// FAKE_TMUX_DUP_ONCE: new-session for that name answers "duplicate session" once, as if created outside the server.
import fs from 'node:fs';
import path from 'node:path';

const dir = process.env.FAKE_TMUX_DIR;
const argv = process.argv.slice(2);
const [cmd] = argv;
const arg = (flag) => { const i = argv.indexOf(flag); return i >= 0 ? argv[i + 1] : undefined; };
const target = () => (arg('-t') || '').replace(/^=/, '').replace(/:$/, '');
const stateFile = path.join(dir, 'state.json');
const load = () => { try { return JSON.parse(fs.readFileSync(stateFile, 'utf8')); } catch { return { sessions: {} }; } };
const save = (s) => fs.writeFileSync(stateFile, JSON.stringify(s));
const fail = (msg) => { process.stderr.write(msg + '\n'); process.exit(1); };

const t0 = Date.now();
let stdin = null;
if (cmd === 'load-buffer') stdin = fs.readFileSync(0).toString('base64');
// logged on exit (success or failure) with start/end times so tests can measure overlap and ordering
process.on('exit', () => fs.appendFileSync(path.join(dir, 'log.jsonl'), JSON.stringify({ argv, stdin, t0, t1: Date.now() }) + '\n'));
const delays = JSON.parse(process.env.FAKE_TMUX_DELAYS || '{}'); // per command, e.g. {"capture-pane": 300}
const delay = Number((argv.includes('-S') ? delays[`${cmd} -S`] : undefined) ?? delays[cmd] ?? process.env.FAKE_TMUX_DELAY_MS ?? 0);
if (delay) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, delay);

// like real tmux 3.x: these commands take a target-pane, and a bare "=name" does not resolve one ("can't find pane"); "=name:" does
if (['capture-pane', 'display-message', 'send-keys', 'paste-buffer', 'resize-window', 'set-option'].includes(cmd) && /^=[^:]*$/.test(arg('-t') || '')) fail(`can't find pane: ${arg('-t').slice(1)}`);

const st = load();
const needSession = () => { if (!st.sessions[target()]) fail(`can't find session: ${target()}`); };

switch (cmd) {
  case 'new-session': {
    const name = arg('-s');
    if (st.sessions[name]) fail(`duplicate session: ${name}`);
    if (process.env.FAKE_TMUX_DUP_ONCE === name && !fs.existsSync(path.join(dir, 'dup-once'))) { // created by someone else meanwhile
      fs.writeFileSync(path.join(dir, 'dup-once'), name);
      fail(`duplicate session: ${name}`);
    }
    if (process.env.FAKE_TMUX_EXIT) break; // the pane's command died: the session is already gone
    const after = Number(process.env.FAKE_TMUX_EXIT_AFTER_MS || 0); // the harness exits this long after start
    st.sessions[name] = { created: 1700000000, dir: arg('-c'), cmd: argv[argv.length - 1], opts: {}, ...(after && { diesAt: Date.now() + after }) };
    save(st);
    break;
  }
  case 'has-session': { // only has-session sees a delayed death (deterministic: set-option never does)
    const s = st.sessions[target()];
    if (s?.diesAt && s.diesAt <= Date.now()) { delete st.sessions[target()]; save(st); }
    needSession();
    break;
  }
  case 'set-option': {
    const opt = argv[argv.length - 2];
    if (st.sessions[target()] && process.env.FAKE_TMUX_EXIT_AT_OPTION === opt) { delete st.sessions[target()]; save(st); }
    if (!st.sessions[target()]) fail(`no such session: ${target()}`);
    st.sessions[target()].opts[opt] = argv[argv.length - 1]; save(st);
    break;
  }
  case 'kill-session': needSession(); delete st.sessions[target()]; save(st); break;
  case 'list-sessions': {
    const names = Object.keys(st.sessions);
    if (!names.length) fail('no server running on /tmp/tmux-1000/default');
    for (const n of names) {
      const s = st.sessions[n];
      console.log(`${n}|${s.created}|0|${s.activity ?? 1700000100}|${s.windowActivity ?? 0}|${s.opts['@pc_harness'] || ''}|${s.opts['@pc_project'] || ''}`);
    }
    break;
  }
  case 'capture-pane': {
    needSession();
    if (process.env.FAKE_TMUX_BIG) { // ~300 KB that differs on every call: drives SSE backpressure
      let out = '';
      for (let i = 0; i < 4000; i++) out += `line ${i} ${Date.now()}-${process.pid} ${'x'.repeat(60)}\n`;
      process.stdout.write(out);
    } else {
      const f = process.env.FAKE_TMUX_SCREEN_FILE;
      if (st.sessions[target()].screen !== undefined) { process.stdout.write(st.sessions[target()].screen); break; }
      process.stdout.write(f ? fs.readFileSync(f, 'utf8') : process.env.FAKE_TMUX_SCREEN ? JSON.parse(process.env.FAKE_TMUX_SCREEN) : 'hello world\nline 2\n\n\n');
    }
    break;
  }
  case 'display-message': needSession(); console.log('80 24 3 5'); break;
  case 'send-keys': case 'paste-buffer': case 'resize-window': needSession(); break;
  default: break; // load-buffer, delete-buffer: ok
}
