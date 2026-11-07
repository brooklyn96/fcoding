// box/fcode-hooks.sh run for real (bash, git, python3) on throwaway projects listed in a throwaway FCode config (FCODE_CFG);
// the hook text comes from box/fcode-add.sh --hook-text (FCODE_ADD_SCRIPT). Run on Linux (the box): `node --test test/fcode-hooks.test.mjs`.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const SCRIPT = path.join(here, '..', 'box', 'fcode-hooks.sh');
const ADD = path.join(here, '..', 'box', 'fcode-add.sh');
const skip = (process.platform === 'win32' || spawnSync('bash', ['-c', 'for t in git python3 install cmp; do command -v $t >/dev/null || exit 1; done']).status !== 0)
  && 'needs Linux with bash, git, python3';
// the 8-line hook every project got before this change
const OLD_HOOK = `#!/bin/sh
# Box guard: never push directly to main/master. Work on box/<topic>, then merge through a PR.
while read local_ref local_sha remote_ref remote_sha; do
  case "$remote_ref" in
    refs/heads/main|refs/heads/master) echo "pre-push: pushing to \${remote_ref#refs/heads/} is blocked on this box; push a box/<topic> branch and merge via PR" >&2; exit 1;;
  esac
done
exit 0
`;
const HOOK = spawnSync('bash', [ADD, '--hook-text'], { encoding: 'utf8' }).stdout;

function world() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'pc-fh-'));
  const e = { root, home: path.join(root, 'home'), ws: path.join(root, 'ws'), cfg: path.join(root, 'config.json') };
  fs.mkdirSync(e.home); fs.mkdirSync(e.ws);
  e.env = { PATH: process.env.PATH, HOME: e.home, GIT_CONFIG_NOSYSTEM: '1', FCODE_CFG: e.cfg, FCODE_ADD_SCRIPT: ADD };
  e.git = (...a) => spawnSync('git', a, { encoding: 'utf8', env: e.env });
  e.repo = (name) => { const d = path.join(e.ws, name); assert.equal(e.git('init', '-q', '-b', 'main', d).status, 0); fs.mkdirSync(path.join(d, '.git', 'hooks'), { recursive: true }); return d; };
  e.run = (extra = {}) => { const r = spawnSync('bash', [SCRIPT], { encoding: 'utf8', env: { ...e.env, ...extra } }); return { code: r.status, lines: r.stdout.trim().split('\n'), stdout: r.stdout, stderr: r.stderr }; };
  e.hooksPath = (d) => e.git('-C', d, 'config', '--local', '--get', 'core.hooksPath').stdout.trim();
  return e;
}
const done = (e) => fs.rmSync(e.root, { recursive: true, force: true });
// every file under d (path -> content), to prove nothing else was written
const snap = (d) => Object.fromEntries(fs.readdirSync(d, { recursive: true, withFileTypes: true }).filter((x) => x.isFile())
  .map((x) => { const p = path.join(x.parentPath ?? x.path, x.name); return [path.relative(d, p), fs.readFileSync(p, 'latin1')]; }));

test('fcode-hooks: syntax is valid bash, LF only; the hook text is there', { skip }, () => {
  const r = spawnSync('bash', ['-n', SCRIPT], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  assert.ok(!fs.readFileSync(SCRIPT, 'latin1').includes('\r'));
  assert.match(HOOK, /^#!\/bin\/sh\n# Box guard:/);
});

test('fcode-hooks: puts the current hook into every project (old box hook replaced, missing one added), one line each, idempotent; unsafe or foreign ones fail untouched', { skip }, () => {
  const e = world();
  try {
    // a global core.hooksPath elsewhere must not win over what fcode-hooks sets
    const globalHooks = path.join(e.root, 'global-hooks'); fs.mkdirSync(globalHooks);
    fs.writeFileSync(path.join(e.home, '.gitconfig'), `[core]\n\thooksPath = ${globalHooks}\n`);
    const old = e.repo('old'); fs.writeFileSync(path.join(old, '.git', 'hooks', 'pre-push'), OLD_HOOK, { mode: 0o755 });
    const none = e.repo('none'); e.git('-C', none, 'config', '--local', 'core.hooksPath', path.join(none, '.git', 'hooks'));
    const cur = e.repo('cur'); fs.writeFileSync(path.join(cur, '.git', 'hooks', 'pre-push'), HOOK, { mode: 0o755 }); e.git('-C', cur, 'config', '--local', 'core.hooksPath', path.join(cur, '.git', 'hooks'));
    const foreign = e.repo('foreign'); fs.writeFileSync(path.join(foreign, '.git', 'hooks', 'pre-push'), '#!/bin/sh\nexec husky\n', { mode: 0o755 });
    const elsewhere = e.repo('elsewhere'); e.git('-C', elsewhere, 'config', '--local', 'core.hooksPath', path.join(e.root, 'other-hooks'));
    const linked = path.join(e.ws, 'linked'); fs.symlinkSync(old, linked);
    const gitlink = path.join(e.ws, 'gitlink'); fs.mkdirSync(gitlink); fs.symlinkSync(path.join(old, '.git'), path.join(gitlink, '.git'));
    fs.writeFileSync(e.cfg, JSON.stringify({ cookieSecret: 'x', projects: { old, none, cur, foreign, elsewhere, linked, gitlink, missing: path.join(e.ws, 'missing'), num: 5 } }));
    const before = { foreign: snap(foreign), elsewhere: snap(elsewhere), cur: snap(cur) };
    const r = e.run();
    assert.equal(r.code, 1, r.stdout + r.stderr);
    assert.deepEqual(r.lines, ['HOOK_OK old HEAD_FAIL', 'HOOK_OK none HEAD_FAIL', 'HOOK_EXISTS cur HEAD_FAIL', 'HOOK_FAIL foreign foreign', 'HOOK_FAIL elsewhere hookspath', 'HOOK_FAIL linked dir',
      'HOOK_FAIL gitlink unsafe', 'HOOK_FAIL missing dir', 'HOOK_FAIL num dir']); // no origin remote: set-head fails, the project does not
    for (const d of [old, none, cur]) {
      const f = path.join(d, '.git', 'hooks', 'pre-push');
      assert.equal(fs.readFileSync(f, 'utf8'), HOOK, d);
      assert.equal(fs.statSync(f).mode & 0o777, 0o755, d);
      assert.equal(e.hooksPath(d), path.join(d, '.git', 'hooks'), d);
    }
    assert.deepEqual({ foreign: snap(foreign), elsewhere: snap(elsewhere), cur: snap(cur) }, before); // nothing touched, cur included
    assert.deepEqual(fs.readdirSync(globalHooks), []);
    // git really runs it: a push to main is refused by the new hook
    const target = path.join(e.root, 't.git'); e.git('init', '-q', '--bare', target);
    e.git('-C', old, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '--allow-empty', '-m', 'x');
    const p = e.git('-C', old, 'push', target, 'HEAD:refs/heads/main');
    assert.notEqual(p.status, 0); assert.match(p.stderr, /blocked on this box/);
    // a second run: every installed project is HOOK_EXISTS and no file changes
    const after = { old: snap(old), none: snap(none), cur: snap(cur) };
    const again = e.run();
    assert.deepEqual(again.lines.slice(0, 3), ['HOOK_EXISTS old HEAD_FAIL', 'HOOK_EXISTS none HEAD_FAIL', 'HOOK_EXISTS cur HEAD_FAIL']);
    assert.deepEqual({ old: snap(old), none: snap(none), cur: snap(cur) }, after);
    // all fine -> exit 0
    fs.writeFileSync(e.cfg, JSON.stringify({ projects: { old, none, cur } }));
    assert.deepEqual([e.run().code], [0]);
  } finally { done(e); }
});

test('fcode-hooks: no hook text or an unreadable config ends with exit 2 and changes nothing', { skip }, () => {
  const e = world();
  try {
    const old = e.repo('old'); fs.writeFileSync(path.join(old, '.git', 'hooks', 'pre-push'), OLD_HOOK, { mode: 0o755 });
    fs.writeFileSync(e.cfg, JSON.stringify({ projects: { old } }));
    const before = snap(old);
    let r = e.run({ FCODE_ADD_SCRIPT: path.join(e.root, 'nope.sh') });
    assert.equal(r.code, 2); assert.match(r.stdout, /^HOOK_FAIL - no hook text/);
    fs.writeFileSync(e.cfg, '{broken');
    r = e.run();
    assert.equal(r.code, 2); assert.match(r.stdout, /^HOOK_FAIL - config/);
    assert.deepEqual(snap(old), before);
  } finally { done(e); }
});

test('fcode-hooks [astra P2]: a relative core.hooksPath (.git/hooks) is read from the project, not from where fcode-hooks runs', { skip }, () => {
  const e = world();
  try {
    const rel = e.repo('rel'); fs.writeFileSync(path.join(rel, '.git', 'hooks', 'pre-push'), OLD_HOOK, { mode: 0o755 });
    e.git('-C', rel, 'config', '--local', 'core.hooksPath', '.git/hooks');
    const away = e.repo('away'); e.git('-C', away, 'config', '--local', 'core.hooksPath', '../other-hooks'); // relative, but outside the clone's hooks
    fs.writeFileSync(e.cfg, JSON.stringify({ projects: { rel, away } }));
    const r = spawnSync('bash', [SCRIPT], { cwd: e.root, encoding: 'utf8', env: e.env }); // the cwd has no .git/hooks of its own
    assert.deepEqual([r.status, r.stdout], [1, 'HOOK_OK rel HEAD_FAIL\nHOOK_FAIL away hookspath\n'], r.stderr);
    assert.equal(fs.readFileSync(path.join(rel, '.git', 'hooks', 'pre-push'), 'utf8'), HOOK);
    assert.equal(e.hooksPath(rel), '.git/hooks', 'left as the project had it');
  } finally { done(e); }
});

test('fcode-hooks [review-r6]: a repo whose default branch is trunk and that has no origin/HEAD (git fetch never makes it): the hook refuses a new branch naming set-head; fcode-hooks runs it (HEAD_OK) and the push goes', { skip }, () => {
  const e = world();
  try {
    const remote = path.join(e.root, 'o', 't.git'); const seed = path.join(e.root, 'seed');
    const g = (...a) => { const r = e.git('-c', 'user.name=t', '-c', 'user.email=t@t', ...a); assert.equal(r.status, 0, r.stderr); return r.stdout.trim(); };
    g('init', '-q', '--bare', '-b', 'trunk', remote); g('init', '-q', '-b', 'trunk', seed);
    fs.mkdirSync(path.join(seed, '.github', 'workflows'), { recursive: true });
    fs.writeFileSync(path.join(seed, '.github', 'workflows', 'ci.yml'), 'jobs:\n  d:\n    env:\n      K: ${{ secrets.DEPLOY_SSH_KEY }}\n');
    g('-C', seed, 'add', '-A'); g('-C', seed, 'commit', '-q', '-m', 'seed'); g('-C', seed, 'push', '-q', remote, 'trunk');
    const d = path.join(e.ws, 'trunk'); g('clone', '-q', remote, d);
    g('-C', d, 'remote', 'set-head', 'origin', '-d'); // as after a clone of the empty repo and a later fetch
    fs.writeFileSync(path.join(d, '.git', 'hooks', 'pre-push'), HOOK, { mode: 0o755 });
    g('-C', d, 'switch', '-q', '-c', 'box/x');
    fs.writeFileSync(path.join(d, 'src.txt'), 'x\n'); g('-C', d, 'add', '-A'); g('-C', d, 'commit', '-q', '-m', 'src');
    const sha = g('-C', d, 'rev-parse', 'HEAD');
    let p = e.git('-C', d, 'push', '-q', 'origin', 'box/x');
    assert.notEqual(p.status, 0);
    assert.ok(p.stderr.includes(`pre-push: o/t: không có nhánh nào để so .github/ của commit ${sha} (nhánh này chưa có trên remote, box chưa biết nhánh chính origin/HEAD). Chạy: git remote set-head origin --auto rồi đẩy lại;`), p.stderr);
    fs.writeFileSync(e.cfg, JSON.stringify({ projects: { trunk: d } }));
    const r = e.run();
    assert.deepEqual([r.code, r.lines], [0, ['HOOK_EXISTS trunk HEAD_OK']], r.stderr);
    assert.equal(g('-C', d, 'symbolic-ref', 'refs/remotes/origin/HEAD'), 'refs/remotes/origin/trunk');
    p = e.git('-C', d, 'push', '-q', 'origin', 'box/x');
    assert.equal(p.status, 0, p.stderr);
    // a .github/ change is still refused, now against trunk
    fs.writeFileSync(path.join(d, '.github', 'workflows', 'ci.yml'), 'on: push\n'); g('-C', d, 'commit', '-q', '-am', 'wf');
    p = e.git('-C', d, 'push', '-q', 'origin', 'HEAD:refs/heads/box/y');
    assert.notEqual(p.status, 0); assert.match(p.stderr, /khác với nhánh trên remote và với nhánh chính/);
  } finally { done(e); }
});

test('install.sh installs fcode-hooks and the gh guard, runs fcode-hooks once the config exists, and a failing run never aborts the install', { skip }, () => {
  const install = fs.readFileSync(path.join(here, '..', 'install.sh'), 'utf8');
  assert.match(install, /\n\[ ! -f "\$SRC\/box\/fcode-hooks\.sh" \] \|\| install -D -m 755 "\$SRC\/box\/fcode-hooks\.sh" "\$HOME\/\.local\/bin\/fcode-hooks"\n/);
  assert.match(install, /\n\[ ! -f "\$SRC\/box\/gh-guard\.sh" \] \|\| install -D -m 755 "\$SRC\/box\/gh-guard\.sh" "\$HOME\/\.local\/bin\/gh"\n/);
  const block = /\nif \[ -x "\$HOME\/\.local\/bin\/fcode-hooks" \]; then\n[^\n]*\nfi\n/.exec(install)?.[0];
  assert.ok(block, 'the fcode-hooks run is in install.sh');
  const at = install.indexOf(block);
  assert.ok(install.indexOf('install -m 755 "$SRC/box/fcode-add.sh" "$APP/fcode-add.sh"') < at, 'after fcode-add.sh (the hook text) is installed');
  assert.ok(install.indexOf('strip_password_hash "$CFG/config.json"\n') < at, 'after the config exists');
  // the block itself under install.sh's own shell options: a failing fcode-hooks warns and the install goes on, with APP and the config passed
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'pc-fhi-'));
  try {
    fs.mkdirSync(path.join(root, '.local', 'bin'), { recursive: true });
    fs.writeFileSync(path.join(root, '.local', 'bin', 'fcode-hooks'), '#!/bin/sh\necho "HOOK_FAIL x dir $FCODE_APP $FCODE_CFG"\nexit 1\n', { mode: 0o755 });
    const r = spawnSync('bash', ['-c', `set -euo pipefail\nAPP=/a\nCFG=/c\n${block}\necho went-on`], { encoding: 'utf8', env: { PATH: process.env.PATH, HOME: root } });
    assert.deepEqual([r.status, r.stdout], [0, 'HOOK_FAIL x dir /a /c/config.json\nwent-on\n']);
    assert.match(r.stderr, /^warning: fcode-hooks did not update every project's pre-push hook/);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
