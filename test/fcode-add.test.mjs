// box/fcode-add.sh run for real: bash, git, python3, flock and ssh-keygen on a throwaway FCODE_SSH_DIR / FCODE_WORKSPACE / FCODE_CFG.
// GitHub is local: bare repos under <root>/gh, reached through git's url.<base>.insteadOf (GIT_CONFIG_COUNT env), and a fake `gh` first on PATH.
// Run on Linux (the box): `node --test test/fcode-add.test.mjs`. Skipped where those tools are missing (Windows).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import http from 'node:http';
import { createApp, adminRequest } from '../server.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const SCRIPT = path.join(here, '..', 'box', 'fcode-add.sh');
const have = process.platform !== 'win32'
  && spawnSync('bash', ['-c', 'for t in git python3 flock ssh-keygen timeout install cmp awk sed; do command -v $t >/dev/null || exit 1; done']).status === 0;
const skip = !have && 'needs Linux with bash, git, python3, flock, ssh-keygen';
const TOKEN = 'ghp_FAKETOKEN0123456789abcdefghijklmnop';
const ZERO = '0'.repeat(40);

const FAKE_GH = `#!/bin/bash
echo "$*" >>"$FAKE_GH_LOG"
case "$1 $2" in
  "api repos/"*)
    case "$FAKE_GH_PUSH" in
      true|false) echo "$FAKE_GH_PUSH"; exit 0;;
      *) echo "To get started with GitHub CLI, please run:  gh auth login" >&2; exit 4;;
    esac;;
  "pr list") exit 0;;
  "auth git-credential") [ "$3" = get ] && printf 'username=ghuser\npassword=%s\n' "\${GH_TOKEN:-none}"; exit 0;;
esac
exit 1
`;
const hook = (body) => `#!/bin/sh\nwhile read o n r; do\n${body}\ndone\nexit 0\n`;
const HOOKS = {
  ro: hook('  case "$r" in refs/heads/box/*) echo "remote: Permission to o/r.git denied to box." >&2; exit 1;; esac'),
  blocked: hook('  case "$r" in refs/heads/box/*) echo "remote: error: GH006: Protected branch update failed for $r." >&2; exit 1;; esac'),
  archived: hook('  echo "remote: This repository was archived so it is read-only." >&2; exit 1'),
  nodelete: hook(`  [ "$n" = ${ZERO} ] && { echo "remote: delete refused" >&2; exit 1; }`),
};

function sh(cmd, args, env, cwd) {
  const r = spawnSync(cmd, args, { cwd, encoding: 'utf8', env: { PATH: process.env.PATH, HOME: env.home, GIT_CONFIG_NOSYSTEM: '1', ...env.extra } });
  assert.equal(r.status, 0, `${cmd} ${args.join(' ')}: ${r.stderr}`);
  return r.stdout.trim();
}
// one throwaway world per test
function world(push = 'true') {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'pc-fa-'));
  const e = { root, home: path.join(root, 'home'), bin: path.join(root, 'bin'), gh: path.join(root, 'gh'), ws: path.join(root, 'ws'), ssh: path.join(root, 'ssh'),
    cfgDir: path.join(root, 'cfg'), ghlog: path.join(root, 'gh.log'), push, rewrites: [] };
  e.tmp = path.join(root, 'tmp');
  for (const d of [e.home, e.bin, e.gh, e.ws, e.cfgDir, e.tmp]) fs.mkdirSync(d, { recursive: true });
  fs.chmodSync(e.cfgDir, 0o700);
  e.cfg = path.join(e.cfgDir, 'config.json');
  fs.writeFileSync(e.cfg, JSON.stringify({ cookieSecret: Buffer.alloc(32, 7).toString('base64'), projects: { other: '/data/workspace/other' }, port: 7681, keep: 1 }, null, 2) + '\n', { mode: 0o600 });
  fs.writeFileSync(path.join(e.bin, 'gh'), FAKE_GH, { mode: 0o755 });
  fs.writeFileSync(path.join(e.bin, 'journalctl'), '#!/bin/sh\nexit 0\n', { mode: 0o755 }); // the real one would read the box's journal
  fs.writeFileSync(path.join(e.bin, 'curl'), '#!/bin/sh\nexit 0\n', { mode: 0o755 }); // and this would call a server on port 7681
  // everything under https://github.com/ and git@github-<name>: is a local path, unless a test points it elsewhere
  e.rewrites.push(['https://github.com/', `${e.gh}/`]);
  e.map = (name) => e.rewrites.push([`git@github-${name}:`, `${e.gh}/`]);
  return e;
}
// a bare repo <root>/gh/<repo>.git with one commit on main (and a pre-receive hook when asked)
function bare(e, repo, hookName) {
  const dir = path.join(e.gh, `${repo}.git`);
  fs.mkdirSync(dir, { recursive: true });
  const w = fs.mkdtempSync(path.join(e.root, 'seed-'));
  sh('git', ['init', '-q', '--bare', '-b', 'main', dir], e);
  sh('git', ['init', '-q', '-b', 'main', w], e);
  fs.writeFileSync(path.join(w, 'README.md'), 'hello\n');
  sh('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', '-C', w, 'add', '.'], e);
  sh('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', '-C', w, 'commit', '-q', '-m', 'seed'], e);
  sh('git', ['-C', w, 'push', '-q', dir, 'main'], e);
  if (hookName) fs.writeFileSync(path.join(dir, 'hooks', 'pre-receive'), HOOKS[hookName], { mode: 0o755 });
  return dir;
}
function scriptEnv(e, extra = {}) {
  const env = { PATH: `${e.bin}:${process.env.PATH}`, HOME: e.home, TMPDIR: e.tmp, LANG: 'C.UTF-8', GIT_CONFIG_NOSYSTEM: '1', FCODE_SSH_DIR: e.ssh, FCODE_WORKSPACE: e.ws, FCODE_CFG: e.cfg,
    FAKE_GH_LOG: e.ghlog, FAKE_GH_PUSH: e.push, GH_TOKEN: TOKEN, GIT_CONFIG_COUNT: String(e.rewrites.length), ...extra };
  e.rewrites.forEach(([from, to], i) => { env[`GIT_CONFIG_KEY_${i}`] = `url.${to}.insteadOf`; env[`GIT_CONFIG_VALUE_${i}`] = from; });
  return env;
}
const shape = (code, stdout, stderr) => {
  const lines = stdout.split('\n').map((l) => /^R (\S+)(?: (.*))?$/.exec(l)).filter(Boolean).map((m) => [m[1], m[2] ?? '']);
  return { code, lines, codes: lines.map((l) => l[0]), detail: (c) => lines.find((l) => l[0] === c)?.[1], stdout, stderr };
};
function run(e, repo, name, extra = {}) {
  const env = scriptEnv(e, extra);
  const r = spawnSync('bash', [SCRIPT, ...(repo === undefined ? [] : [repo]), ...(name === undefined ? [] : [name])], { env, encoding: 'utf8', timeout: 120e3 });
  return shape(r.status, r.stdout, r.stderr);
}
const runAsync = (e, repo, name, extra = {}) => new Promise((resolve) => { // several at once
  const p = spawn('bash', [SCRIPT, repo, name], { env: scriptEnv(e, extra), stdio: ['ignore', 'pipe', 'pipe'] });
  let out = '', er = '';
  p.stdout.on('data', (d) => { out += d; }); p.stderr.on('data', (d) => { er += d; });
  p.on('close', (code) => resolve(shape(code, out, er)));
});
const projects = (e) => JSON.parse(fs.readFileSync(e.cfg, 'utf8')).projects;
const git = (e, dir, ...a) => sh('git', ['-C', dir, ...a], e);
const gitRaw = (e, dir, ...a) => spawnSync('git', ['-C', dir, ...a], { encoding: 'utf8', env: { PATH: process.env.PATH, HOME: e.home, GIT_CONFIG_NOSYSTEM: '1' } }).stdout;
const gitOr = (e, dir, ...a) => spawnSync('git', ['-C', dir, ...a], { encoding: 'utf8', env: { PATH: process.env.PATH, HOME: e.home, GIT_CONFIG_NOSYSTEM: '1' } }).stdout.trim();
const files = (d) => fs.readdirSync(d, { withFileTypes: true }).flatMap((x) => (x.isDirectory() ? (x.name === 'gh' ? [] : files(path.join(d, x.name))) : x.isFile() ? [path.join(d, x.name)] : []));
// nothing the world holds, and nothing the script printed, may contain the token (the bare repos under gh/ are the fake GitHub: not scanned)
const noToken = (e, r) => {
  assert.ok(!r.stdout.includes(TOKEN) && !r.stderr.includes(TOKEN), 'printed');
  for (const f of files(e.root)) assert.ok(!fs.readFileSync(f).includes(TOKEN), `written: ${f}`);
};
// every mktemp of the script (TMPDIR = e.tmp) is gone: also after a TOKEN_FALLBACK re-exec, which skips the EXIT trap
const tmpClean = (e) => assert.deepEqual(fs.readdirSync(e.tmp), [], 'temp files left behind');
const done = (e) => fs.rmSync(e.root, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
const TAIL = ['V_BRANCH_OK', 'V_PR_OK', 'V_HOOK_OK', 'V_SERVER_OK', 'RULES_NO'];

test('script: syntax is valid bash', { skip }, () => {
  const r = spawnSync('bash', ['-n', SCRIPT], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  assert.ok(!fs.readFileSync(SCRIPT, 'latin1').includes('\r'), 'LF only');
});

test('token path: gh can push -> https clone, repo-local gh credential helper, no key, no alias, hook, write check, config; the token is never written; rerun is safe', { skip }, () => {
  const e = world('true');
  try {
    const remote = bare(e, 'o/r');
    const r = run(e, 'o/r', 'r');
    assert.deepEqual([r.code, r.codes], [0, ['TOKEN_OK', 'READ_OK', 'CLONED', 'HOOK_OK', 'WRITE_OK', 'CFG_ADDED', ...TAIL]], r.stdout + r.stderr);
    const dir = path.join(e.ws, 'r');
    assert.equal(git(e, dir, 'config', '--get', 'remote.origin.url'), 'https://github.com/o/r.git'); // not the local path, no token in it
    // the repo's helper chain: an empty value first (it resets what system/global config bring), then gh; nothing global
    assert.equal(gitRaw(e, dir, 'config', '--local', '--get-all', 'credential.helper'), '\n!gh auth git-credential\n');
    assert.equal(gitOr(e, dir, 'config', '--global', '--get-all', 'credential.helper'), ''); // never global
    // no deploy key and no alias were made
    assert.deepEqual(fs.existsSync(e.ssh) ? fs.readdirSync(e.ssh).filter((f) => !f.startsWith('.fcode-add-')) : [], []);
    assert.equal(projects(e).r, dir);
    assert.equal(projects(e).other, '/data/workspace/other'); // the others stay
    assert.equal(JSON.parse(fs.readFileSync(e.cfg, 'utf8')).keep, 1);
    assert.equal(fs.statSync(e.cfg).mode & 0o777, 0o600);
    assert.ok(fs.readdirSync(e.cfgDir).some((f) => f.startsWith('config.json.bak-')));
    // the box hook is in and works; the write-check branch is gone from the remote
    const hookFile = path.join(dir, '.git', 'hooks', 'pre-push');
    assert.equal(spawnSync(hookFile, ['origin', 'x'], { input: 'refs/heads/x 0 refs/heads/main 0\n' }).status, 1);
    assert.equal(spawnSync(hookFile, ['origin', 'x'], { input: 'refs/heads/box/x 0 refs/heads/box/x 0\n' }).status, 0);
    assert.equal(git(e, remote, 'for-each-ref', 'refs/heads/box'), '');
    assert.equal(git(e, dir, 'config', '--local', '--get', 'core.hooksPath'), path.join(dir, '.git', 'hooks')); // git is pointed at the clone's own hooks
    tmpClean(e);
    // gh was asked only for the permission; its credential helper never ran (the clone is local here)
    const calls = fs.readFileSync(e.ghlog, 'utf8').trim().split('\n');
    assert.deepEqual(calls.filter((c) => c.startsWith('api')), ['api repos/o/r --jq .permissions.push']);
    assert.ok(!calls.some((c) => c.includes('git-credential')));
    noToken(e, r);
    // rerun of a project that is already registered with this origin: success, and NOTHING is touched (no gh call, no probe, no config change)
    const cfgBefore = fs.readFileSync(e.cfg, 'utf8'), confBefore = fs.readFileSync(path.join(dir, '.git', 'config'), 'utf8'), ghBefore = fs.readFileSync(e.ghlog, 'utf8');
    const again = run(e, 'o/r', 'r');
    assert.deepEqual([again.code, again.codes], [0, ['CFG_EXISTS']], again.stdout + again.stderr);
    assert.equal(fs.readFileSync(e.cfg, 'utf8'), cfgBefore);
    assert.equal(fs.readFileSync(path.join(dir, '.git', 'config'), 'utf8'), confBefore);
    assert.equal(fs.readFileSync(e.ghlog, 'utf8'), ghBefore);
    assert.deepEqual(boxRefs(e, remote), []);
    tmpClean(e);
    noToken(e, again);
  } finally { done(e); }
});

test('key path: gh cannot push (or is not logged in, or FCODE_NO_TOKEN) -> deploy key, alias, ssh clone as before; rerun is safe', { skip }, () => {
  for (const [push, extra] of [['false', {}], ['fail', {}], ['true', { FCODE_NO_TOKEN: '1' }]]) {
    const e = world(push);
    try {
      bare(e, 'o/r'); e.map('r');
      const r = run(e, 'o/r', 'r', extra);
      assert.deepEqual([r.code, r.codes], [0, ['KEY_NEW', 'ALIAS_ADDED', 'READ_OK', 'CLONED', 'HOOK_OK', 'WRITE_OK', 'CFG_ADDED', ...TAIL]], `${push} ${r.stdout}${r.stderr}`);
      const dir = path.join(e.ws, 'r');
      assert.equal(git(e, dir, 'config', '--get', 'remote.origin.url'), 'git@github-r:o/r.git');
      assert.equal(gitOr(e, dir, 'config', '--local', '--get-regexp', 'credential'), ''); // no helper on the key path
      assert.equal(fs.statSync(path.join(e.ssh, 'id_ed25519_r')).mode & 0o777, 0o600);
      assert.match(fs.readFileSync(path.join(e.ssh, 'config'), 'utf8'), /# fcode add: o\/r\nHost github-r\n {2}HostName github\.com\n/);
      assert.equal(projects(e).r, dir);
      noToken(e, r);
      const again = run(e, 'o/r', 'r', extra); // already registered with this origin: success, nothing touched
      assert.deepEqual([again.code, again.codes], [0, ['CFG_EXISTS']], again.stdout);
    } finally { done(e); }
  }
});

test('token path falls back to the deploy key when the clone is refused (token cannot read the repo)', { skip }, () => {
  const e = world('true');
  try {
    bare(e, 'o/r'); e.map('r');
    e.rewrites[0] = ['https://github.com/', `${e.gh}/nowhere/`]; // https clone: repository not found; the ssh alias works
    const r = run(e, 'o/r', 'r');
    assert.deepEqual([r.code, r.codes], [0, ['TOKEN_OK', 'READ_OK', 'TOKEN_FALLBACK', 'KEY_NEW', 'ALIAS_ADDED', 'READ_OK', 'CLONED', 'HOOK_OK', 'WRITE_OK', 'CFG_ADDED', ...TAIL]], r.stdout + r.stderr);
    assert.equal(git(e, path.join(e.ws, 'r'), 'config', '--get', 'remote.origin.url'), 'git@github-r:o/r.git');
    noToken(e, r);
  } finally { done(e); }
});

test('token path falls back when the write check is refused for permission (the token reads but cannot write): key path, NEED_WRITE with the public key, nothing added', { skip }, () => {
  const e = world('true');
  try {
    bare(e, 'o/r', 'ro'); e.map('r');
    const r = run(e, 'o/r', 'r'); // also proves the lock is not held by the first pass (no deadlock on the re-exec)
    assert.equal(r.code, 41, r.stdout + r.stderr);
    // the token run's clone is removed before the key run starts (that one clones again), and the key run's own clone goes when it fails; one SSH_DETAIL
    assert.deepEqual(r.codes, ['TOKEN_OK', 'READ_OK', 'CLONED', 'HOOK_OK', 'TOKEN_FALLBACK', 'KEY_NEW', 'ALIAS_ADDED', 'READ_OK', 'CLONED', 'HOOK_OK', 'SSH_DETAIL', 'PUBKEY', 'NEED_WRITE']);
    assert.match(r.detail('PUBKEY'), /^ssh-ed25519 [A-Za-z0-9+/]+ fcode-o\/r$/);
    assert.equal(fs.existsSync(path.join(e.ws, 'r')), false); // no orphan clone
    assert.equal(projects(e).r, undefined); // nothing added
    tmpClean(e);
    noToken(e, r);
    // the private key never reaches the output
    const priv = fs.readFileSync(path.join(e.ssh, 'id_ed25519_r'), 'utf8').split('\n').filter((l) => l && !l.startsWith('-----'));
    for (const l of priv) assert.ok(!r.stdout.includes(l) && !r.stderr.includes(l));
  } finally { done(e); }
});

test('permissions.push says true but the real write check is refused (any GitHub 403 wording): the key route decides, NEED_WRITE or NEED_KEY, nothing added', { skip }, () => {
  // the API reports the user's role, not the token's scope (seen on the box: push true, then HTTPS push 403 "Permission to ... denied")
  for (const [name, wording] of [['403 Permission', 'remote: Permission to o/r.git denied to box.'], ['403 Write access', 'remote: Write access to repository not granted.'],
    ['403 curl', "fatal: unable to access 'https://github.com/o/r.git/': The requested URL returned error: 403"], ['401', 'remote: Invalid username or password.\nfatal: Authentication failed for \'https://github.com/o/r.git/\''],
    ['no prompt', "fatal: could not read Username for 'https://github.com': terminal prompts disabled"]]) {
    for (const keyReadable of [true, false]) {
      const e = world('true');
      try {
        const dir = bare(e, 'o/r');
        fs.writeFileSync(path.join(dir, 'hooks', 'msg'), `${wording}\n`);
        fs.writeFileSync(path.join(dir, 'hooks', 'pre-receive'), hook('  case "$r" in refs/heads/box/*) cat "$(dirname "$0")/msg" >&2; exit 1;; esac'), { mode: 0o755 });
        if (keyReadable) e.map('r'); else e.rewrites.push(['git@github-r:', `${e.gh}/missing/`]);
        const r = run(e, 'o/r', 'r');
        const label = `${name} keyReadable=${keyReadable}: ${r.stdout}${r.stderr}`;
        assert.equal(r.code, keyReadable ? 41 : 40, label);
        assert.equal(r.codes.at(-1), keyReadable ? 'NEED_WRITE' : 'NEED_KEY', label);
        assert.ok(r.codes.includes('TOKEN_FALLBACK') && r.codes.includes('KEY_NEW'), label);
        assert.match(r.detail('PUBKEY'), /^ssh-ed25519 [A-Za-z0-9+/]+ fcode-o\/r$/);
        assert.equal(projects(e).r, undefined, label);
        assert.equal(gitOr(e, path.join(e.ws, 'r'), 'config', '--local', '--get-regexp', 'credential'), '', label);
        noToken(e, r);
      } finally { done(e); }
    }
  }
});

test('key path outcomes: NEED_KEY (public key printed), NEED_WRITE, WRITE_BLOCKED, REPO_ARCHIVED, NET_FAIL, CLEANUP_FAIL', { skip }, () => {
  // NEED_KEY: the repo cannot be read through the alias
  let e = world('false');
  try {
    e.rewrites.push(['git@github-r:', `${e.gh}/missing/`]);
    const r = run(e, 'o/r', 'r');
    assert.equal(r.code, 40);
    assert.deepEqual(r.codes, ['KEY_NEW', 'ALIAS_ADDED', 'SSH_DETAIL', 'PUBKEY', 'NEED_KEY']);
    assert.match(r.detail('PUBKEY'), /^ssh-ed25519 [A-Za-z0-9+/]+ fcode-o\/r$/);
    assert.equal(r.detail('PUBKEY'), fs.readFileSync(path.join(e.ssh, 'id_ed25519_r.pub'), 'utf8').trim());
    assert.ok(!fs.existsSync(path.join(e.ws, 'r')) && projects(e).r === undefined);
    const priv = fs.readFileSync(path.join(e.ssh, 'id_ed25519_r'), 'utf8').split('\n').filter((l) => l && !l.startsWith('-----'));
    for (const l of priv) assert.ok(!r.stdout.includes(l) && !r.stderr.includes(l));
    // after the user adds the key the same call goes on (here: the repo shows up)
    bare(e, 'o/r'); e.rewrites.pop(); e.map('r');
    const again = run(e, 'o/r', 'r');
    assert.deepEqual([again.code, again.codes.slice(0, 4)], [0, ['KEY_EXISTS', 'ALIAS_EXISTS', 'READ_OK', 'CLONED']], again.stdout);
  } finally { done(e); }
  for (const [hookName, token, code, last] of [['ro', false, 41, 'NEED_WRITE'], ['blocked', false, 42, 'WRITE_BLOCKED'], ['blocked', true, 42, 'WRITE_BLOCKED'],
    ['archived', false, 44, 'REPO_ARCHIVED'], ['archived', true, 44, 'REPO_ARCHIVED']]) {
    e = world(token ? 'true' : 'false');
    try {
      bare(e, 'o/r', hookName); e.map('r');
      const r = run(e, 'o/r', 'r');
      assert.equal(r.code, code, `${hookName} ${token} ${r.stdout}${r.stderr}`);
      assert.equal(r.codes.at(-1), last);
      assert.ok(!r.codes.includes('TOKEN_FALLBACK') || (hookName === 'ro' && token), 'only a permission refusal falls back');
      assert.equal(projects(e).r, undefined);
      assert.equal(fs.existsSync(path.join(e.ws, 'r')), false, 'the clone this run made is removed when the project is not added');
      tmpClean(e);
      noToken(e, r);
    } finally { done(e); }
  }
  // NET_FAIL on the key path (ls-remote) and on the token path (clone)
  for (const token of [false, true]) {
    e = world(token ? 'true' : 'false');
    try {
      e.rewrites[0] = ['https://github.com/', 'http://127.0.0.1:1/']; // curl: "Failed to connect ... Couldn't connect to server"
      e.rewrites.push(['git@github-r:', 'ssh://git@127.0.0.1:1/']); // ssh: "connect to host ... Connection refused"
      const r = run(e, 'o/r', 'r');
      assert.equal(r.code, 43, r.stdout + r.stderr);
      assert.equal(r.codes.at(-1), 'NET_FAIL');
      assert.ok(!r.codes.includes('NEED_KEY') && !r.codes.includes('TOKEN_FALLBACK'));
    } finally { done(e); }
  }
  // CLEANUP_FAIL: the check branch cannot be deleted: still added, exit 30, the branch name is reported
  for (const token of [false, true]) {
    e = world(token ? 'true' : 'false');
    try {
      const remote = bare(e, 'o/r', 'nodelete'); e.map('r');
      const r = run(e, 'o/r', 'r');
      assert.equal(r.code, 30, r.stdout + r.stderr);
      // the probe ref is unique per run: box/fcode-add-check-<name>-<epoch>-<pid>; that exact branch is named, and it is the one left on the remote
      const branch = r.detail('CLEANUP_FAIL');
      assert.match(branch, /^refs\/heads\/box\/fcode-add-check-r-\d+-\d+-\d+$/);
      assert.equal(git(e, remote, 'for-each-ref', '--format=%(refname)', 'refs/heads/box'), branch);
      assert.ok(r.codes.includes('CFG_ADDED') && r.codes.includes('WRITE_OK'));
      assert.equal(projects(e).r, path.join(e.ws, 'r'));
      tmpClean(e);
    } finally { done(e); }
  }
});

test('arguments, config and folder checks: exit codes and nothing created', { skip }, () => {
  let e = world('true');
  try {
    bare(e, 'o/r');
    assert.deepEqual([run(e).code, run(e).codes], [2, ['USAGE']]);
    assert.deepEqual([run(e, 'o/r').code, run(e, 'o/r').codes], [2, ['USAGE']]);
    for (const [repo, name] of [['o', 'r'], ['o/r', 'R'], ['o/r', 'home'], ['o/r', '-x'], ['o/r', 'a b'], ['../r', 'r'], ['o/..', 'r'], ['o/r/x', 'r'], ['o/r;ls', 'r'], ['o/r', 'x'.repeat(65)]]) {
      const r = run(e, repo, name);
      assert.deepEqual([r.code, r.codes], [2, ['BAD_ARGS']], `${repo} ${name}`);
    }
    assert.deepEqual(fs.readdirSync(e.ws), []);
    assert.equal(run(e, 'o/r.git', 'r').code, 0); // .git is stripped
    // a folder of that name is never adopted, whatever it is: a plain folder, a file, a clone of another repo, a clone of THIS repo that is not registered
    const taken = path.join(e.ws, 'taken');
    fs.mkdirSync(taken);
    let r = run(e, 'o/r', 'taken');
    assert.deepEqual([r.code, r.codes, r.detail('DIR_EXISTS')], [11, ['DIR_EXISTS'], 'exists']);
    fs.rmSync(taken, { recursive: true });
    fs.writeFileSync(taken, 'a file');
    r = run(e, 'o/r', 'taken');
    assert.deepEqual([r.code, r.codes, r.detail('DIR_EXISTS')], [11, ['DIR_EXISTS'], 'exists']);
    fs.rmSync(taken);
    bare(e, 'a/b');
    for (const origin of ['https://github.com/a/b.git', 'https://github.com/o/r.git']) {
      sh('git', ['clone', '-q', path.join(e.gh, 'a/b.git'), taken], e);
      sh('git', ['-C', taken, 'remote', 'set-url', 'origin', origin], e);
      const before = fs.readFileSync(path.join(taken, '.git', 'config'), 'utf8');
      r = run(e, 'o/r', 'taken');
      assert.deepEqual([r.code, r.codes, r.detail('DIR_EXISTS')], [11, ['DIR_EXISTS'], 'exists'], origin);
      assert.equal(fs.readFileSync(path.join(taken, '.git', 'config'), 'utf8'), before); // untouched
      assert.deepEqual(fs.readdirSync(path.join(taken, '.git', 'hooks')).filter((x) => x === 'pre-push'), []);
      fs.rmSync(taken, { recursive: true });
    }
    assert.equal(projects(e).taken, undefined);
  } finally { done(e); }
  // config: broken, or the name already points elsewhere
  e = world('true');
  try {
    bare(e, 'o/r');
    fs.writeFileSync(e.cfg, '{not json', { mode: 0o600 });
    let r = run(e, 'o/r', 'r');
    assert.deepEqual([r.code, r.codes], [22, ['CFG_BROKEN']]);
    fs.writeFileSync(e.cfg, '[]', { mode: 0o600 });
    assert.equal(run(e, 'o/r', 'r').code, 22);
    fs.writeFileSync(e.cfg, JSON.stringify({ projects: [] }), { mode: 0o600 });
    assert.equal(run(e, 'o/r', 'r').code, 22);
    fs.writeFileSync(e.cfg, JSON.stringify({ projects: { r: '/elsewhere' } }), { mode: 0o600 });
    r = run(e, 'o/r', 'r');
    assert.deepEqual([r.code, r.codes, r.detail('CFG_CONFLICT')], [21, ['CFG_CONFLICT'], '/elsewhere']);
    assert.deepEqual(fs.readdirSync(e.ws), []); // nothing cloned
  } finally { done(e); }
  // the name's key or alias belongs to another repo (key path)
  e = world('false');
  try {
    bare(e, 'o/r'); e.map('r');
    assert.equal(run(e, 'o/r', 'r').code, 0);
    const clash = run(e, 'someone/else', 'r'); // the folder is o/r's
    assert.deepEqual([clash.code, clash.codes, clash.detail('DIR_EXISTS')], [11, ['DIR_EXISTS'], 'exists']);
    fs.rmSync(path.join(e.ws, 'r'), { recursive: true }); // folder and config entry gone, key and alias stay
    fs.writeFileSync(e.cfg, JSON.stringify({ projects: {} }), { mode: 0o600 });
    const used = run(e, 'someone/else', 'r');
    assert.deepEqual([used.code, used.codes], [23, ['NAME_USED']]);
    assert.deepEqual(fs.readdirSync(e.ws), []);
  } finally { done(e); }
});

test('a project added by key is not touched by a rerun, even when gh could push now (idempotent: CFG_EXISTS only)', { skip }, () => {
  const e = world('true');
  try {
    bare(e, 'o/r'); e.map('r');
    assert.equal(run(e, 'o/r', 'r', { FCODE_NO_TOKEN: '1' }).code, 0); // added by key
    const r = run(e, 'o/r', 'r'); // gh would say push = true now
    assert.deepEqual([r.code, r.codes], [0, ['CFG_EXISTS']], r.stdout);
    assert.equal(git(e, path.join(e.ws, 'r'), 'config', '--get', 'remote.origin.url'), 'git@github-r:o/r.git');
  } finally { done(e); }
});

// ---------- the server running the real script ----------
function httpJson(port, method, p, { body, cookie } = {}) {
  return new Promise((resolve, reject) => {
    const payload = body === undefined ? undefined : JSON.stringify(body);
    const h = { 'X-PC': '1', ...(cookie && { Cookie: cookie }), ...(payload !== undefined && { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) }) };
    const r = http.request({ host: '127.0.0.1', port, method, path: p, headers: h }, (res) => {
      const chunks = []; res.on('data', (c) => chunks.push(c));
      res.on('end', () => { const text = Buffer.concat(chunks).toString('utf8'); resolve({ status: res.statusCode, headers: res.headers, text, json: JSON.parse(text || 'null') }); });
    });
    r.on('error', reject); r.end(payload);
  });
}
async function withServer(e, fn) {
  const never = [process.execPath, '-e', 'process.exit(1)'];
  const logs = [];
  const app = createApp({ configDir: e.cfgDir, tmux: never, gh: never, git: never, omp: never, spendRoots: {}, updatesFile: path.join(e.root, 'none.json'), gitSyncFile: path.join(e.root, 'none2.json'), gitSync: null,
    log: (l) => logs.push(l), addScript: ['env', ...Object.entries(scriptEnv(e)).map(([k, v]) => `${k}=${v}`), 'bash', SCRIPT] });
  const port = await app.listen(0, '127.0.0.1');
  try {
    const p = await adminRequest(e.cfgDir, { cmd: 'pair', name: 't' });
    const login = await httpJson(port, 'POST', '/api/pair', { body: { code: p.code } });
    const cookie = login.headers['set-cookie'][0].split(';')[0];
    const call = (m, u, body) => httpJson(port, m, u, { body, cookie });
    const add = async (body) => {
      const r = await call('POST', '/api/projects', body);
      assert.equal(r.status, 202, r.text);
      for (let i = 0; i < 600; i++) { const j = await call('GET', `/api/projects/jobs/${r.json.job}`); if (j.json.state !== 'running') return j; await new Promise((x) => setTimeout(x, 100)); }
      throw new Error('job did not end');
    };
    await fn({ call, add, logs, app });
  } finally { await app.close(); }
}

test('server + real script: a pasted link adds the project by token; it is in /api/meta and /api/home at once; the token is nowhere', { skip }, async () => {
  const e = world('true');
  try {
    bare(e, 'o/r');
    await withServer(e, async ({ call, add, logs }) => {
      const j = await add({ repo: 'https://www.github.com/o/r.git/tree/main?x=1#y' });
      assert.deepEqual(j.json, { state: 'done', code: 'ADDED', name: 'r', repo: 'o/r', via: 'token', detail: null }, j.text);
      assert.deepEqual((await call('GET', '/api/meta')).json.projects, ['other', 'r']);
      assert.deepEqual((await call('GET', '/api/home')).json.projects.map((p) => p.name), ['other', 'r']); // the server's own config file, rewritten by the script
      assert.equal(projects(e).r, path.join(e.ws, 'r'));
      const again = await add({ repo: 'o/r' }); // safe to run again: registered with this origin, so nothing is touched (no TOKEN_OK line: via null)
      assert.deepEqual([again.json.state, again.json.code, again.json.via, again.json.detail], ['done', 'ADDED', null, null]);
      noToken(e, { stdout: j.text + again.text + logs.join('\n'), stderr: '' });
      assert.deepEqual(logs.filter((l) => l.startsWith('add-project')), ['add-project r ADDED', 'add-project r ADDED']);
    });
  } finally { done(e); }
});

test('server + real script: the deploy key route answers NEED_KEY with the public key and the GitHub link', { skip }, async () => {
  const e = world('false');
  try {
    e.rewrites.push(['git@github-r:', `${e.gh}/missing/`]);
    await withServer(e, async ({ add }) => {
      const j = await add({ repo: 'o/r' });
      assert.equal(j.json.state, 'failed'); assert.equal(j.json.code, 'NEED_KEY'); assert.equal(j.json.via, 'key');
      assert.match(j.json.pubkey, /^ssh-ed25519 [A-Za-z0-9+/]+ fcode-o\/r$/);
      assert.equal(j.json.keyUrl, 'https://github.com/o/r/settings/keys/new');
      assert.ok(j.json.detail && j.json.detail.length <= 200);
      assert.equal(j.json.pubkey, fs.readFileSync(path.join(e.ssh, 'id_ed25519_r.pub'), 'utf8').trim());
      const priv = fs.readFileSync(path.join(e.ssh, 'id_ed25519_r'), 'utf8').split('\n').filter((l) => l && !l.startsWith('-----'));
      for (const l of priv) assert.ok(!j.text.includes(l));
    });
  } finally { done(e); }
});
// ======================= round 2: write proof, hook, paths, cleanup, durability =======================
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, ms = 30000) { const end = Date.now() + ms; for (;;) { if (fn()) return; if (Date.now() > end) throw new Error('until: timed out'); await sleep(50); } }
const boxRefs = (e, remote) => git(e, remote, 'for-each-ref', '--format=%(refname)', 'refs/heads/box').split('\n').filter(Boolean);

test('write proof: an old check branch is no proof; once the probe was created the write is proven, and ANY refused delete is only CLEANUP_FAIL (ADDED_WARN) naming the branch', { skip }, () => {
  const e = world('true');
  try {
    const remote = bare(e, 'o/r'); e.map('r');
    git(e, remote, 'update-ref', 'refs/heads/box/fcode-add-check', git(e, remote, 'rev-parse', 'main')); // what the old script left behind
    // a branch may be created, but its deletion is refused for permission
    fs.writeFileSync(path.join(remote, 'hooks', 'pre-receive'), hook(`  [ "$n" = ${ZERO} ] && { echo "remote: Permission to o/r.git denied to box." >&2; exit 1; }`), { mode: 0o755 });
    const r = run(e, 'o/r', 'r');
    assert.equal(r.code, 30, r.stdout + r.stderr); // the create worked: the token can write; the refused delete is a warning
    assert.deepEqual(r.codes.slice(0, 7), ['TOKEN_OK', 'READ_OK', 'CLONED', 'HOOK_OK', 'CLEANUP_FAIL', 'WRITE_OK', 'CFG_ADDED']);
    assert.ok(!r.codes.includes('TOKEN_FALLBACK'));
    assert.equal(projects(e).r, path.join(e.ws, 'r'));
    // the old branch was never touched; the one probe this run made is named, and is the only new branch on the remote
    const refs = boxRefs(e, remote);
    assert.ok(refs.includes('refs/heads/box/fcode-add-check'));
    const probes = refs.filter((x) => /^refs\/heads\/box\/fcode-add-check-r-\d+-\d+-\d+$/.test(x));
    assert.deepEqual(probes, [r.detail('CLEANUP_FAIL')]);
    tmpClean(e);
  } finally { done(e); }
  // a key that can only read: creating the probe is refused for permission, an old check branch changes nothing
  const e2 = world('false');
  try {
    const remote = bare(e2, 'o/r', 'ro'); e2.map('r');
    git(e2, remote, 'update-ref', 'refs/heads/box/fcode-add-check', git(e2, remote, 'rev-parse', 'main'));
    const r = run(e2, 'o/r', 'r');
    assert.deepEqual([r.code, r.codes.at(-1)], [41, 'NEED_WRITE'], r.stdout + r.stderr);
    assert.ok(!r.codes.includes('WRITE_OK') && projects(e2).r === undefined);
  } finally { done(e2); }
});

test('write proof: two adds of one repo under different names each create and delete only their own probe branch', { skip }, async () => {
  const e = world('true');
  try {
    const remote = bare(e, 'o/r');
    const log = path.join(e.root, 'refs.log');
    fs.writeFileSync(path.join(remote, 'hooks', 'pre-receive'), hook(`  echo "$o $n $r" >>${log}; sleep 1`), { mode: 0o755 }); // slow: the two runs overlap
    const [a, b] = await Promise.all([runAsync(e, 'o/r', 'ra'), runAsync(e, 'o/r', 'rb')]);
    for (const r of [a, b]) { assert.equal(r.code, 0, r.stdout + r.stderr); assert.ok(r.codes.includes('WRITE_OK') && !r.codes.includes('CLEANUP_FAIL')); }
    const rows = fs.readFileSync(log, 'utf8').trim().split('\n').map((l) => l.split(' '));
    assert.equal(rows.length, 4); // each run: one create, one delete
    for (const name of ['ra', 'rb']) {
      const mine = rows.filter((x) => x[2].startsWith(`refs/heads/box/fcode-add-check-${name}-`));
      assert.equal(mine.length, 2, name);
      assert.equal(mine[0][2], mine[1][2]); // the same probe: created, then deleted
      assert.ok(mine[0][0] === ZERO && mine[1][1] === ZERO && mine[1][0] === mine[0][1], 'created, then deleted with the commit it created');
    }
    assert.deepEqual(boxRefs(e, remote), []);
    assert.deepEqual(Object.keys(projects(e)).sort(), ['other', 'ra', 'rb']);
    tmpClean(e);
  } finally { done(e); }
});

test('hook: git uses the clone\'s own hooks even when a global core.hooksPath points elsewhere (checked by a real push, not by running the file)', { skip }, () => {
  const e = world('true');
  try {
    const empty = path.join(e.root, 'global-hooks'); fs.mkdirSync(empty);
    fs.writeFileSync(path.join(e.home, '.gitconfig'), `[core]\n\thooksPath = ${empty}\n`);
    bare(e, 'o/r'); const target = path.join(e.root, 'target.git'); sh('git', ['init', '-q', '--bare', target], e); // empty: every push has something to send, so the hook is asked
    const r = run(e, 'o/r', 'r');
    assert.deepEqual([r.code, r.codes], [0, ['TOKEN_OK', 'READ_OK', 'CLONED', 'HOOK_OK', 'WRITE_OK', 'CFG_ADDED', ...TAIL]], r.stdout + r.stderr);
    const dir = path.join(e.ws, 'r');
    assert.equal(git(e, dir, 'config', '--local', '--get', 'core.hooksPath'), path.join(dir, '.git', 'hooks'));
    const push = (ref) => spawnSync('git', ['-C', dir, 'push', '-q', target, `HEAD:${ref}`], { encoding: 'utf8', env: { PATH: process.env.PATH, HOME: e.home, GIT_CONFIG_NOSYSTEM: '1' } });
    const toMain = push('refs/heads/main');
    assert.notEqual(toMain.status, 0);
    assert.match(toMain.stderr, /blocked on this box/);
    assert.equal(push('refs/heads/box/z').status, 0);
  } finally { done(e); }
});

test('hook: an install failure fails the add before the project is registered, and the clone this run made is removed', { skip }, () => {
  const e = world('true');
  try {
    const remote = bare(e, 'o/r');
    const tpl = path.join(e.root, 'tpl'); fs.mkdirSync(tpl); fs.writeFileSync(path.join(tpl, 'hooks'), 'a file where the hooks folder should be');
    const extra = { GIT_TEMPLATE_DIR: tpl };
    let r = run(e, 'o/r', 'r', extra);
    assert.deepEqual([r.code, r.codes], [24, ['TOKEN_OK', 'READ_OK', 'CLONED', 'HOOK_FAIL']], r.stdout + r.stderr);
    assert.equal(r.detail('HOOK_FAIL'), 'install'); // the install error itself ends the run, not only the later verification
    assert.equal(fs.existsSync(path.join(e.ws, 'r')), false);
    assert.equal(projects(e).r, undefined);
    tmpClean(e);
  } finally { done(e); }
});

test('paths: a symlinked target, a .git that is a link, or a git dir outside the workspace is refused before any change; a symlinked workspace is fine', { skip }, () => {
  const e = world('true');
  try {
    bare(e, 'o/r');
    const out = path.join(e.root, 'outside'); fs.mkdirSync(out);
    const clone = path.join(out, 'clone');
    sh('git', ['clone', '-q', path.join(e.gh, 'o/r.git'), clone], e);
    sh('git', ['-C', clone, 'remote', 'set-url', 'origin', 'https://github.com/o/r.git'], e); // the origin matches, so only the path rules can refuse it
    const snap = () => JSON.stringify([fs.readFileSync(path.join(clone, '.git', 'config'), 'utf8'), fs.readdirSync(path.join(clone, '.git', 'hooks')).sort()]);
    const before = snap();
    const target = path.join(e.ws, 'r');
    // 1. the workspace entry is a link to the outside clone
    fs.symlinkSync(clone, target);
    let r = run(e, 'o/r', 'r');
    assert.deepEqual([r.code, r.codes, r.detail('DIR_UNSAFE')], [11, ['DIR_UNSAFE'], 'unsafe'], r.stdout + r.stderr);
    assert.equal(snap(), before);
    fs.unlinkSync(target);
    // 2. a real folder whose .git is a link to the outside git dir
    fs.mkdirSync(target); fs.symlinkSync(path.join(clone, '.git'), path.join(target, '.git'));
    r = run(e, 'o/r', 'r');
    assert.deepEqual([r.code, r.codes], [11, ['DIR_UNSAFE']]);
    assert.equal(snap(), before);
    fs.rmSync(target, { recursive: true });
    // 3. .git is a file that points at the outside git dir
    fs.mkdirSync(target); fs.writeFileSync(path.join(target, '.git'), `gitdir: ${path.join(clone, '.git')}\n`);
    r = run(e, 'o/r', 'r');
    assert.deepEqual([r.code, r.codes], [11, ['DIR_EXISTS']]);
    assert.equal(snap(), before);
    fs.rmSync(target, { recursive: true });
    assert.equal(projects(e).r, undefined);
    assert.deepEqual(fs.readdirSync(e.ws), []);
    tmpClean(e);
    // a workspace that is itself a link to a real folder is fine, and so is a rerun inside it
    const link = path.join(e.root, 'ws-link'); fs.symlinkSync(e.ws, link);
    r = run(e, 'o/r', 'r', { FCODE_WORKSPACE: link });
    assert.deepEqual([r.code, r.codes.slice(0, 3)], [0, ['TOKEN_OK', 'READ_OK', 'CLONED']], r.stdout + r.stderr);
    assert.equal(run(e, 'o/r', 'r', { FCODE_WORKSPACE: link }).code, 0);
  } finally { done(e); }
});

test('cleanup: a name whose key or alias belongs to another repo is NAME_USED before the token route clones anything', { skip }, () => {
  const e = world('true');
  try {
    bare(e, 'o/r');
    fs.mkdirSync(e.ssh, { recursive: true });
    fs.writeFileSync(path.join(e.ssh, 'config'), '\n# fcode add: someone/else\nHost github-r\n  HostName github.com\n');
    const r = run(e, 'o/r', 'r');
    assert.deepEqual([r.code, r.codes], [23, ['NAME_USED']], r.stdout + r.stderr);
    assert.deepEqual(fs.readdirSync(e.ws), []);
    assert.ok(!fs.existsSync(e.ghlog), 'gh was not even asked');
    tmpClean(e);
  } finally { done(e); }
});

test('cleanup: a failed add removes the clone this run made, never a folder that was already there (also across the token fallback)', { skip }, () => {
  // a folder that existed before is refused before anything happens: it stays exactly as it was, gh is not even asked
  const e = world('true');
  try {
    const remote = bare(e, 'o/r', 'ro'); e.map('r');
    const dir = path.join(e.ws, 'r');
    sh('git', ['clone', '-q', remote, dir], e);
    sh('git', ['-C', dir, 'remote', 'set-url', 'origin', 'https://github.com/o/r.git'], e);
    const before = fs.readFileSync(path.join(dir, '.git', 'config'), 'utf8');
    const r = run(e, 'o/r', 'r');
    assert.deepEqual([r.code, r.codes], [11, ['DIR_EXISTS']], r.stdout + r.stderr);
    assert.ok(fs.existsSync(path.join(dir, '.git')), 'the folder that was there stays');
    assert.equal(fs.readFileSync(path.join(dir, '.git', 'config'), 'utf8'), before);
    assert.ok(!fs.existsSync(e.ghlog));
    assert.equal(projects(e).r, undefined);
    tmpClean(e);
  } finally { done(e); }
  // the registration itself fails (config folder not writable): the new clone goes, nothing is registered
  if (process.getuid?.() !== 0) {
    const e2 = world('true');
    try {
      bare(e2, 'o/r');
      fs.chmodSync(e2.cfgDir, 0o500);
      const r = run(e2, 'o/r', 'r');
      assert.deepEqual([r.code, r.codes.at(-1)], [22, 'CFG_BROKEN'], r.stdout + r.stderr);
      assert.equal(fs.existsSync(path.join(e2.ws, 'r')), false);
      tmpClean(e2);
    } finally { fs.chmodSync(e2.cfgDir, 0o700); done(e2); }
  }
});

test('cleanup: a TERM (the server stopping, a timeout) while the write check runs removes the new clone and the temp files', { skip }, async () => {
  const e = world('true');
  try {
    const remote = bare(e, 'o/r');
    const marker = path.join(e.root, 'in-hook');
    fs.writeFileSync(path.join(remote, 'hooks', 'pre-receive'), hook(`  case "$r" in refs/heads/box/*) touch ${marker}; sleep 60;; esac`), { mode: 0o755 });
    const p = spawn('bash', [SCRIPT, 'o/r', 'r'], { env: scriptEnv(e), stdio: 'ignore', detached: true });
    const exited = new Promise((resolve) => p.on('close', (code, sig) => resolve([code, sig])));
    await until(() => fs.existsSync(marker));
    assert.ok(fs.existsSync(path.join(e.ws, 'r')));
    process.kill(-p.pid, 'SIGTERM'); // the whole group, as the server does
    const [code] = await exited;
    assert.equal(code, 143);
    assert.equal(fs.existsSync(path.join(e.ws, 'r')), false);
    assert.equal(projects(e).r, undefined);
    tmpClean(e);
  } finally { done(e); }
});

test('durability: config.json and its backup are fsynced before the rename, then the folder is', { skip }, () => {
  const e = world('true');
  try {
    bare(e, 'o/r');
    const py = path.join(e.root, 'py'); fs.mkdirSync(py);
    const log = path.join(e.root, 'fsync.log');
    fs.writeFileSync(path.join(py, 'sitecustomize.py'), `import os
_log = os.environ['FSYNC_LOG']; _fsync, _replace = os.fsync, os.replace
def _w(s):
    with open(_log, 'a') as f: f.write(s + '\\n')
def fsync(fd):
    try: p = os.readlink('/proc/self/fd/%d' % fd)
    except OSError: p = '?'
    _w('fsync ' + p); return _fsync(fd)
def replace(a, b, *x, **k):
    _w('replace %s %s' % (a, b)); return _replace(a, b, *x, **k)
os.fsync = fsync; os.replace = replace
`);
    const r = run(e, 'o/r', 'r', { PYTHONPATH: py, FSYNC_LOG: log });
    assert.equal(r.code, 0, r.stdout + r.stderr);
    const rows = fs.readFileSync(log, 'utf8').trim().split('\n');
    assert.equal(rows.length, 4, rows.join('\n'));
    assert.match(rows[0], new RegExp(`^fsync ${e.cfg.replace(/\./g, '\\.')}\\.bak-`)); // the backup, on disk first
    assert.match(rows[1], new RegExp(`^fsync ${e.cfgDir}/\\.config\\.json\\..*\\.tmp$`)); // the new file, before the rename
    assert.match(rows[2], new RegExp(`^replace ${e.cfgDir}/\\.config\\.json\\..*\\.tmp ${e.cfg.replace(/\./g, '\\.')}$`));
    assert.equal(rows[3], `fsync ${e.cfgDir}`); // then the folder
    assert.equal(projects(e).r, path.join(e.ws, 'r'));
  } finally { done(e); }
});
// ======================= round 3: no adoption of existing folders; credentials, push destination, hooks dir, registration vs cleanup =======================
const FAKE_GLOBAL_HELPER = '#!/bin/sh\necho "$1" >>"$GLOBAL_HELPER_LOG"\n[ "$1" = get ] && printf "username=glob\\npassword=FROM-GLOBAL\\n"\nexit 0\n';
const globalHelper = (e) => { // a helper in the GLOBAL git config that must never be asked, nor told about a credential
  const sh1 = path.join(e.root, 'global-helper.sh'); fs.writeFileSync(sh1, FAKE_GLOBAL_HELPER, { mode: 0o755 });
  e.helperLog = path.join(e.root, 'global-helper.log');
  fs.writeFileSync(path.join(e.home, '.gitconfig'), `[credential]\n\thelper = ${sh1}\n`);
  return { GLOBAL_HELPER_LOG: e.helperLog };
};
const helperCalls = (e) => (fs.existsSync(e.helperLog) ? fs.readFileSync(e.helperLog, 'utf8').trim().split('\n').filter(Boolean) : []);

test('credentials: the token route resets inherited helpers for the clone: a global helper is never asked, gh alone answers', { skip }, async () => {
  const e = world('true');
  const seen = [];
  const srv = http.createServer((req, res) => { seen.push(req.headers.authorization ?? ''); res.writeHead(401, { 'WWW-Authenticate': 'Basic realm="x"' }); res.end(); }); // always "log in first"
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));
  try {
    const extra = globalHelper(e);
    bare(e, 'o/r');
    e.rewrites[0] = ['https://github.com/', `http://127.0.0.1:${srv.address().port}/`];
    e.rewrites.push(['git@github-r:', `${e.gh}/missing/`]); // the fallback key route has nothing to read either (no network here)
    const r = await runAsync(e, 'o/r', 'r', extra); // the clone is refused (401) and the run falls back; only the credentials it used matter here
    assert.ok(r.codes.includes('TOKEN_OK'), r.stdout + r.stderr);
    const auths = seen.filter(Boolean).map((h) => Buffer.from(h.replace(/^Basic /, ''), 'base64').toString());
    assert.ok(auths.length >= 1, 'git asked for credentials');
    assert.ok(auths.every((a) => a === `ghuser:${TOKEN}`), 'only the gh helper gave a credential');
    assert.deepEqual(helperCalls(e), [], 'the global helper was never run (no get, no store, no erase)');
    noToken(e, r);
  } finally { srv.close(); done(e); }
});

test('credentials: the clone\'s own helper chain is "empty, then gh": git asks gh alone, and a credential is stored nowhere else', { skip }, () => {
  const e = world('true');
  try {
    const extra = globalHelper(e);
    bare(e, 'o/r');
    assert.equal(run(e, 'o/r', 'r', extra).code, 0);
    const dir = path.join(e.ws, 'r');
    const env = { PATH: `${e.bin}:${process.env.PATH}`, HOME: e.home, GIT_CONFIG_NOSYSTEM: '1', GH_TOKEN: TOKEN, FAKE_GH_LOG: e.ghlog, GIT_TERMINAL_PROMPT: '0', ...extra };
    const fill = spawnSync('git', ['-C', dir, 'credential', 'fill'], { input: 'protocol=https\nhost=github.com\n\n', encoding: 'utf8', env });
    assert.match(fill.stdout, /username=ghuser/);
    assert.ok(!fill.stdout.includes('FROM-GLOBAL'));
    spawnSync('git', ['-C', dir, 'credential', 'approve'], { input: 'protocol=https\nhost=github.com\nusername=ghuser\npassword=x\n\n', encoding: 'utf8', env });
    spawnSync('git', ['-C', dir, 'credential', 'reject'], { input: 'protocol=https\nhost=github.com\nusername=ghuser\npassword=x\n\n', encoding: 'utf8', env });
    assert.deepEqual(helperCalls(e), [], 'the global helper heard nothing');
    assert.ok(fs.readFileSync(e.ghlog, 'utf8').includes('auth git-credential get'));
  } finally { done(e); }
});

test('push destination: a global url.*.pushInsteadOf that would send the probe elsewhere is refused before anything is cloned', { skip }, () => {
  const e = world('true');
  try {
    bare(e, 'o/r', 'ro'); e.map('r'); // "GitHub" refuses every box/* push; the key alias is a local fixture too (never real GitHub SSH)
    const writable = path.join(e.root, 'wr'); bare({ ...e, gh: writable }, 'o/r'); // ...but this one takes them
    fs.writeFileSync(path.join(e.home, '.gitconfig'), `[url "${writable}/"]\n\tpushInsteadOf = https://github.com/\n`);
    const r = run(e, 'o/r', 'r');
    // the https URL is rewritten: the run is a deploy-key run from the start (no TOKEN_OK, no TOKEN_FALLBACK, no re-exec, no URL_REWRITE);
    // what happens then is the key route's own: this remote refuses the probe push, the writable repo is never reached
    assert.deepEqual([r.code, r.codes], [41, ['KEY_NEW', 'ALIAS_ADDED', 'READ_OK', 'CLONED', 'HOOK_OK', 'SSH_DETAIL', 'PUBKEY', 'NEED_WRITE']], r.stdout + r.stderr);
    assert.ok(!r.codes.some((c) => ['TOKEN_OK', 'TOKEN_FALLBACK', 'URL_REWRITE', 'WRITE_OK', 'CFG_ADDED'].includes(c)));
    assert.deepEqual(fs.readdirSync(e.ws), []);
    assert.deepEqual(git(e, path.join(writable, 'o/r.git'), 'for-each-ref', 'refs/heads/box'), '');
    assert.equal(projects(e).r, undefined);
    // the same for the key route, and for a plain insteadOf that moves the fetch
    fs.writeFileSync(path.join(e.home, '.gitconfig'), `[url "${writable}/"]\n\tinsteadOf = git@github-r:\n`);
    const k = run(e, 'o/r', 'r', { FCODE_NO_TOKEN: '1' });
    assert.deepEqual([k.code, k.codes], [26, ['URL_REWRITE']], k.stdout + k.stderr);
    assert.deepEqual(fs.readdirSync(e.ws), []);
  } finally { done(e); }
  // an unrelated rewrite is fine
  const e2 = world('true');
  try {
    bare(e2, 'o/r');
    fs.writeFileSync(path.join(e2.home, '.gitconfig'), `[url "${path.join(e2.root, 'elsewhere')}/"]\n\tinsteadOf = https://gitlab.com/\n\tpushInsteadOf = git@gitlab.com:\n`);
    assert.equal(run(e2, 'o/r', 'r').code, 0);
  } finally { done(e2); }
});

test('hooks dir: a clone whose hooks folder is a link (or leads outside the clone) is refused before anything is written there', { skip }, () => {
  const e = world('true');
  try {
    bare(e, 'o/r');
    const out = path.join(e.root, 'outside-hooks'); fs.mkdirSync(out);
    const tpl = path.join(e.root, 'tpl'); fs.mkdirSync(tpl); fs.symlinkSync(out, path.join(tpl, 'hooks'));
    const r = run(e, 'o/r', 'r', { GIT_TEMPLATE_DIR: tpl });
    assert.deepEqual([r.code, r.codes, r.detail('HOOK_FAIL')], [24, ['TOKEN_OK', 'READ_OK', 'CLONED', 'HOOK_FAIL'], 'install'], r.stdout + r.stderr);
    assert.deepEqual(fs.readdirSync(out), [], 'nothing was written through the link');
    assert.equal(fs.existsSync(path.join(e.ws, 'r')), false);
    assert.equal(projects(e).r, undefined);
    // a link at pre-push itself
    const tpl2 = path.join(e.root, 'tpl2'); fs.mkdirSync(path.join(tpl2, 'hooks'), { recursive: true }); fs.symlinkSync(path.join(out, 'pre-push'), path.join(tpl2, 'hooks', 'pre-push'));
    const r2 = run(e, 'o/r', 'r', { GIT_TEMPLATE_DIR: tpl2 });
    assert.deepEqual([r2.code, r2.detail('HOOK_FAIL')], [24, 'install'], r2.stdout + r2.stderr);
    assert.deepEqual(fs.readdirSync(out), []);
    tmpClean(e);
  } finally { done(e); }
});

// the registration step under fault injection: Python's os.fsync / os.replace are wrapped through sitecustomize (PYTHONPATH)
function faulty(e, mode) {
  const py = path.join(e.root, `py-${mode}`); fs.mkdirSync(py, { recursive: true });
  fs.writeFileSync(path.join(py, 'sitecustomize.py'), `import os, time
mode = os.environ['SC_MODE']; cfgdir = os.environ['SC_CFGDIR']; mark = os.environ['SC_MARK']
_fsync, _replace = os.fsync, os.replace
def fsync(fd):
    try: p = os.readlink('/proc/self/fd/%d' % fd)
    except OSError: p = '?'
    if p == cfgdir and mode == 'fsyncfail': raise OSError(5, 'injected EIO')
    if p == cfgdir and mode == 'exit77': os._exit(77)
    return _fsync(fd)
def replace(a, b, *x, **k):
    r = _replace(a, b, *x, **k)
    if mode == 'hang':
        open(mark, 'w').write(str(os.getpid())); time.sleep(float(os.environ.get('SC_HANG', '5')))
    return r
os.fsync = fsync; os.replace = replace
`);
  return { PYTHONPATH: py, SC_MODE: mode, SC_CFGDIR: e.cfgDir, SC_MARK: path.join(e.root, `mark-${mode}`) };
}

test('registration vs cleanup: once config.json was replaced the folder stays whatever happens next (late fsync error, exit, closed output, TERM)', { skip }, async () => {
  // the directory fsync fails after the commit: registered, a warning (exit 30), folder kept
  let e = world('true');
  try {
    bare(e, 'o/r');
    const r = run(e, 'o/r', 'r', faulty(e, 'fsyncfail'));
    assert.equal(r.code, 30, r.stdout + r.stderr);
    assert.ok(r.codes.includes('CFG_ADDED') && r.codes.includes('CFG_WARN'));
    assert.equal(projects(e).r, path.join(e.ws, 'r'));
    assert.ok(fs.existsSync(path.join(e.ws, 'r', '.git')));
  } finally { done(e); }
  // the writer dies after the commit (any non-zero exit): the cleanup sees the config maps the name to this folder and does not remove it
  e = world('true');
  try {
    bare(e, 'o/r');
    const r = run(e, 'o/r', 'r', faulty(e, 'exit77'));
    assert.equal(r.code, 77, r.stdout + r.stderr);
    assert.equal(projects(e).r, path.join(e.ws, 'r'));
    assert.ok(fs.existsSync(path.join(e.ws, 'r', '.git')), 'a registered folder is never removed');
  } finally { done(e); }
  // the reader of the output is gone (closed pipe) before the commit: nothing fails because of it
  e = world('true');
  try {
    bare(e, 'o/r');
    const p = spawn('bash', [SCRIPT, 'o/r', 'r'], { env: scriptEnv(e), stdio: ['ignore', 'pipe', 'pipe'] });
    p.stdout.destroy();
    const code = await new Promise((resolve) => p.on('close', resolve));
    assert.equal(code, 0);
    assert.equal(projects(e).r, path.join(e.ws, 'r'));
    assert.ok(fs.existsSync(path.join(e.ws, 'r', '.git')));
  } finally { done(e); }
  // TERM right after the commit: ignored during the registration step, the run goes on to the end; the folder stays
  e = world('true');
  try {
    bare(e, 'o/r');
    const env = { ...scriptEnv(e), ...faulty(e, 'hang') };
    const p = spawn('bash', [SCRIPT, 'o/r', 'r'], { env, stdio: 'ignore', detached: true });
    const exited = new Promise((resolve) => p.on('close', (code, sig) => resolve([code, sig])));
    await until(() => fs.existsSync(env.SC_MARK));
    process.kill(-p.pid, 'SIGTERM');
    const [code] = await exited;
    assert.ok(code === 0 || code === 30, `the run was not cut short (exit ${code})`);
    assert.equal(projects(e).r, path.join(e.ws, 'r'));
    assert.ok(fs.existsSync(path.join(e.ws, 'r', '.git')));
    tmpClean(e);
  } finally { done(e); }
});

test('registration: a name already registered for this folder but whose folder is gone is cloned again; a failure then removes that clone', { skip }, () => {
  const e = world('false');
  try {
    bare(e, 'o/r', 'ro'); e.map('r');
    fs.writeFileSync(e.cfg, JSON.stringify({ cookieSecret: Buffer.alloc(32, 7).toString('base64'), projects: { r: path.join(e.ws, 'r') } }), { mode: 0o600 });
    const r = run(e, 'o/r', 'r');
    assert.equal(r.code, 41, r.stdout + r.stderr);
    assert.ok(r.codes.includes('CLONED'));
    assert.equal(fs.existsSync(path.join(e.ws, 'r')), false); // the stale entry is not a reason to keep a clone that failed its checks
  } finally { done(e); }
  // a registered folder with ANOTHER origin is not "already added": it is refused
  const e2 = world('true');
  try {
    bare(e2, 'a/b');
    const dir = path.join(e2.ws, 'r');
    sh('git', ['clone', '-q', path.join(e2.gh, 'a/b.git'), dir], e2);
    sh('git', ['-C', dir, 'remote', 'set-url', 'origin', 'https://github.com/a/b.git'], e2);
    fs.writeFileSync(e2.cfg, JSON.stringify({ cookieSecret: Buffer.alloc(32, 7).toString('base64'), projects: { r: dir } }), { mode: 0o600 });
    const r = run(e2, 'o/r', 'r');
    assert.deepEqual([r.code, r.codes], [11, ['DIR_EXISTS']], r.stdout + r.stderr);
  } finally { done(e2); }
});
test('credentials: a failed write of the repo\'s helper chain fails the add and removes the clone', { skip }, () => {
  const e = world('true');
  try {
    bare(e, 'o/r');
    const real = spawnSync('bash', ['-c', 'command -v git'], { encoding: 'utf8' }).stdout.trim();
    fs.writeFileSync(path.join(e.bin, 'git'), `#!/bin/bash\ncase "$*" in *"config --local --add credential.helper"*) exit 1;; esac\nexec ${real} "$@"\n`, { mode: 0o755 });
    const r = run(e, 'o/r', 'r');
    assert.deepEqual([r.code, r.codes, r.detail('CRED_FAIL')], [25, ['TOKEN_OK', 'READ_OK', 'CLONED', 'CRED_FAIL'], 'config'], r.stdout + r.stderr);
    assert.equal(fs.existsSync(path.join(e.ws, 'r')), false);
    assert.equal(projects(e).r, undefined);
    tmpClean(e);
  } finally { done(e); }
});

// ======================= round 4: atomic reservation of the target, escalation to KILL =======================
const realTool = (cmd) => spawnSync('bash', ['-c', `command -v ${cmd}`], { encoding: 'utf8' }).stdout.trim();
const wrapper = (e, cmd, body) => fs.writeFileSync(path.join(e.bin, cmd), `#!/bin/bash\n${body}\nexec ${realTool(cmd)} "$@"\n`, { mode: 0o755 });
// the wrapper acts only when the LAST argument is the target folder (<FCODE_WORKSPACE>/<name>); every other mkdir (ws, sshdir, hooks) is untouched
const onTarget = (e, name, body) => wrapper(e, 'mkdir', `if [ "\${@: -1}" = "\${FCODE_WORKSPACE}/${name}" ]; then\n${body}\nfi`);
// terminated = gone, or a zombie (state Z in /proc/<pid>/stat): a killed process whose parent is gone may stay a zombie when the box has no reaping init
const terminated = (pid) => {
  try {
    const st = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
    return st.slice(st.lastIndexOf(')') + 2, st.lastIndexOf(')') + 3) === 'Z';
  } catch { return true; }
};

test('reservation: a failed clone leaves nothing (key route, and token route after its fallback)', { skip }, () => {
  for (const push of ['false', 'true']) {
    const e = world(push);
    try {
      bare(e, 'o/r'); e.map('r');
      // a clone that dies half way: it leaves a .git and a file in the target, exit 128
      wrapper(e, 'git', 'for a in "$@"; do if [ "$a" = clone ]; then t="${@: -1}"; mkdir -p "$t/.git"; echo x > "$t/file"; echo "fatal: injected clone failure" >&2; exit 128; fi; done');
      const r = run(e, 'o/r', 'r');
      const want = push === 'false' ? ['KEY_NEW', 'ALIAS_ADDED', 'READ_OK', 'CLONE_FAIL'] : ['TOKEN_OK', 'READ_OK', 'TOKEN_FALLBACK', 'KEY_NEW', 'ALIAS_ADDED', 'READ_OK', 'CLONE_FAIL'];
      assert.deepEqual([r.code, r.codes], [12, want], r.stdout + r.stderr);
      assert.match(r.detail('CLONE_FAIL'), /injected clone failure/);
      assert.deepEqual(fs.readdirSync(e.ws), [], 'the half clone is gone');
      assert.equal(projects(e).r, undefined);
      tmpClean(e);
    } finally { done(e); }
  }
});

test('reservation: a TERM during the clone removes the folder (exit 143)', { skip }, async () => {
  const e = world('false');
  try {
    bare(e, 'o/r'); e.map('r');
    const marker = path.join(e.root, 'in-clone');
    wrapper(e, 'git', `for a in "$@"; do if [ "$a" = clone ]; then mkdir -p "\${@: -1}/.git"; touch ${marker}; exec sleep 60; fi; done`);
    const p = spawn('bash', [SCRIPT, 'o/r', 'r'], { env: scriptEnv(e), stdio: 'ignore', detached: true });
    const exited = new Promise((resolve) => p.on('close', (code, sig) => resolve([code, sig])));
    await until(() => fs.existsSync(marker));
    assert.ok(fs.existsSync(path.join(e.ws, 'r')));
    process.kill(-p.pid, 'SIGTERM');
    const [code] = await exited;
    assert.equal(code, 143);
    assert.deepEqual(fs.readdirSync(e.ws), []);
    assert.equal(projects(e).r, undefined);
    tmpClean(e);
  } finally { done(e); }
});

test('reservation: a workspace that cannot be written is CLONE_FAIL with the mkdir error, nothing left', { skip: skip || process.getuid?.() === 0 }, () => {
  const e = world('false');
  try {
    bare(e, 'o/r'); e.map('r');
    fs.chmodSync(e.ws, 0o500);
    const r = run(e, 'o/r', 'r');
    assert.deepEqual([r.code, r.codes], [12, ['CLONE_FAIL']], r.stdout + r.stderr);
    assert.match(r.detail('CLONE_FAIL'), /Permission denied/);
    fs.chmodSync(e.ws, 0o700);
    assert.deepEqual(fs.readdirSync(e.ws), []);
    assert.equal(projects(e).r, undefined);
    tmpClean(e);
  } finally { try { fs.chmodSync(e.ws, 0o700); } catch {} done(e); }
});

test('reservation: someone else creating the target in the same instant is DIR_EXISTS, and their files are never touched', { skip }, () => {
  const e = world('true');
  try {
    bare(e, 'o/r');
    // the other one wins the race between the existence check and our mkdir
    onTarget(e, 'r', `/bin/mkdir -p "\${@: -1}"; echo keep > "\${@: -1}/other"`);
    const r = run(e, 'o/r', 'r');
    assert.deepEqual([r.code, r.codes], [11, ['DIR_EXISTS']], r.stdout + r.stderr);
    assert.equal(fs.readFileSync(path.join(e.ws, 'r', 'other'), 'utf8'), 'keep\n');
    assert.equal(projects(e).r, undefined);
    tmpClean(e);
  } finally { done(e); }
});

test('reservation: a TERM that lands between mkdir and "owned" is held, then honoured: folder removed, exit 143', { skip }, () => {
  const e = world('true');
  try {
    bare(e, 'o/r');
    // mkdir succeeds, the TERM hits the script before mkdir returns to it
    onTarget(e, 'r', `/bin/mkdir "\${@: -1}"; st=$?; kill -TERM $PPID; exit $st`);
    const r = run(e, 'o/r', 'r');
    assert.equal(r.code, 143, r.stdout + r.stderr);
    assert.deepEqual(fs.readdirSync(e.ws), [], 'the reserved folder is not left behind');
    assert.equal(projects(e).r, undefined);
    tmpClean(e);
  } finally { done(e); }
});

test('escalation (script): under timeout --kill-after a TERM ignored during the registration step ends in KILL for the whole group; the project stays registered', { skip }, async () => {
  const e = world('true');
  try {
    bare(e, 'o/r');
    const env = { ...scriptEnv(e), ...faulty(e, 'hang'), SC_HANG: '10' };
    const p = spawn('timeout', ['--kill-after=2', '60', 'bash', SCRIPT, 'o/r', 'r'], { env, stdio: 'ignore', detached: true });
    const exited = new Promise((resolve) => p.on('close', (code, sig) => resolve([code, sig])));
    await until(() => fs.existsSync(env.SC_MARK) && fs.readFileSync(env.SC_MARK, 'utf8').length > 0);
    const pyPid = Number(fs.readFileSync(env.SC_MARK, 'utf8'));
    const t0 = Date.now();
    process.kill(-p.pid, 'SIGTERM'); // bash and python both ignore it (registration step); timeout arms its KILL
    const [code, sig] = await exited;
    const took = Date.now() - t0;
    assert.ok(code === 137 || sig === 'SIGKILL', `ended by KILL (code ${code}, signal ${sig})`);
    assert.ok(took < 4500, `within kill-after + slack (${took} ms)`);
    await until(() => terminated(pyPid), 3000);
    assert.equal(projects(e).r, path.join(e.ws, 'r'));
    assert.ok(fs.existsSync(path.join(e.ws, 'r', '.git')));
  } finally { done(e); }
});
