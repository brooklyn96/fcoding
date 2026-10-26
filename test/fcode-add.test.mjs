// box/fcode-add.sh run for real: bash, git, python3, flock and ssh-keygen on a throwaway FCODE_SSH_DIR / FCODE_WORKSPACE / FCODE_CFG.
// GitHub is local: bare repos under <root>/gh, reached through git's url.<base>.insteadOf (GIT_CONFIG_COUNT env), and a fake `gh` first on PATH.
// Run on Linux (the box): `node --test test/fcode-add.test.mjs`. Skipped where those tools are missing (Windows).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
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
  for (const d of [e.home, e.bin, e.gh, e.ws, e.cfgDir]) fs.mkdirSync(d, { recursive: true });
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
  const env = { PATH: `${e.bin}:${process.env.PATH}`, HOME: e.home, LANG: 'C.UTF-8', GIT_CONFIG_NOSYSTEM: '1', FCODE_SSH_DIR: e.ssh, FCODE_WORKSPACE: e.ws, FCODE_CFG: e.cfg,
    FAKE_GH_LOG: e.ghlog, FAKE_GH_PUSH: e.push, GH_TOKEN: TOKEN, GIT_CONFIG_COUNT: String(e.rewrites.length), ...extra };
  e.rewrites.forEach(([from, to], i) => { env[`GIT_CONFIG_KEY_${i}`] = `url.${to}.insteadOf`; env[`GIT_CONFIG_VALUE_${i}`] = from; });
  return env;
}
function run(e, repo, name, extra = {}) {
  const env = scriptEnv(e, extra);
  const r = spawnSync('bash', [SCRIPT, ...(repo === undefined ? [] : [repo]), ...(name === undefined ? [] : [name])], { env, encoding: 'utf8', timeout: 120e3 });
  const lines = r.stdout.split('\n').map((l) => /^R (\S+)(?: (.*))?$/.exec(l)).filter(Boolean).map((m) => [m[1], m[2] ?? '']);
  return { code: r.status, lines, codes: lines.map((l) => l[0]), detail: (c) => lines.find((l) => l[0] === c)?.[1], stdout: r.stdout, stderr: r.stderr };
}
const projects = (e) => JSON.parse(fs.readFileSync(e.cfg, 'utf8')).projects;
const git = (e, dir, ...a) => sh('git', ['-C', dir, ...a], e);
const gitOr = (e, dir, ...a) => spawnSync('git', ['-C', dir, ...a], { encoding: 'utf8', env: { PATH: process.env.PATH, HOME: e.home, GIT_CONFIG_NOSYSTEM: '1' } }).stdout.trim();
const files = (d) => fs.readdirSync(d, { withFileTypes: true }).flatMap((x) => (x.isDirectory() ? (x.name === 'gh' ? [] : files(path.join(d, x.name))) : x.isFile() ? [path.join(d, x.name)] : []));
// nothing the world holds, and nothing the script printed, may contain the token (the bare repos under gh/ are the fake GitHub: not scanned)
const noToken = (e, r) => {
  assert.ok(!r.stdout.includes(TOKEN) && !r.stderr.includes(TOKEN), 'printed');
  for (const f of files(e.root)) assert.ok(!fs.readFileSync(f).includes(TOKEN), `written: ${f}`);
};
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
    assert.equal(git(e, dir, 'config', '--local', '--get', 'credential.https://github.com.helper'), '!gh auth git-credential');
    assert.equal(gitOr(e, dir, 'config', '--global', '--get-all', 'credential.helper'), ''); // never global
    assert.deepEqual(gitOr(e, dir, 'config', '--local', '--get-regexp', 'credential').split('\n'), ['credential.https://github.com.helper !gh auth git-credential']);
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
    // gh was asked only for the permission; its credential helper never ran (the clone is local here)
    const calls = fs.readFileSync(e.ghlog, 'utf8').trim().split('\n');
    assert.deepEqual(calls.filter((c) => c.startsWith('api')), ['api repos/o/r --jq .permissions.push']);
    assert.ok(!calls.some((c) => c.includes('git-credential')));
    noToken(e, r);
    // rerun: the same, nothing new
    const again = run(e, 'o/r', 'r');
    assert.deepEqual([again.code, again.codes], [0, ['TOKEN_OK', 'READ_OK', 'CLONE_EXISTS', 'HOOK_EXISTS', 'WRITE_OK', 'CFG_EXISTS', ...TAIL]], again.stdout);
    assert.equal(gitOr(e, dir, 'config', '--local', '--get-all', 'credential.https://github.com.helper'), '!gh auth git-credential');
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
      const again = run(e, 'o/r', 'r', extra);
      assert.deepEqual([again.code, again.codes], [0, ['KEY_EXISTS', 'ALIAS_EXISTS', 'READ_OK', 'CLONE_EXISTS', 'HOOK_EXISTS', 'WRITE_OK', 'CFG_EXISTS', ...TAIL]], again.stdout);
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
    assert.deepEqual(r.codes, ['TOKEN_OK', 'READ_OK', 'CLONED', 'HOOK_OK', 'TOKEN_FALLBACK', 'KEY_NEW', 'ALIAS_ADDED', 'READ_OK', 'CLONE_EXISTS', 'HOOK_EXISTS', 'SSH_DETAIL', 'PUBKEY', 'NEED_WRITE']); // one SSH_DETAIL: the refused token write prints none
    assert.match(r.detail('PUBKEY'), /^ssh-ed25519 [A-Za-z0-9+/]+ fcode-o\/r$/);
    const dir = path.join(e.ws, 'r');
    assert.equal(git(e, dir, 'config', '--get', 'remote.origin.url'), 'git@github-r:o/r.git');
    assert.equal(gitOr(e, dir, 'config', '--local', '--get-regexp', 'credential'), ''); // the helper was taken out again
    assert.equal(projects(e).r, undefined); // nothing added
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
      bare(e, 'o/r', 'nodelete'); e.map('r');
      const r = run(e, 'o/r', 'r');
      assert.equal(r.code, 30, r.stdout + r.stderr);
      assert.equal(r.detail('CLEANUP_FAIL'), 'refs/heads/box/fcode-add-check');
      assert.ok(r.codes.includes('CFG_ADDED') && r.codes.includes('WRITE_OK'));
      assert.equal(projects(e).r, path.join(e.ws, 'r'));
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
    // another project already has this folder name
    fs.mkdirSync(path.join(e.ws, 'taken'));
    let r = run(e, 'o/r', 'taken');
    assert.deepEqual([r.code, r.codes], [11, ['DIR_NOTGIT']]);
    fs.rmSync(path.join(e.ws, 'taken'), { recursive: true });
    bare(e, 'a/b');
    sh('git', ['clone', '-q', path.join(e.gh, 'a/b.git'), path.join(e.ws, 'taken')], e);
    sh('git', ['-C', path.join(e.ws, 'taken'), 'remote', 'set-url', 'origin', 'https://github.com/a/b.git'], e);
    r = run(e, 'o/r', 'taken');
    assert.deepEqual([r.code, r.codes, r.detail('DIR_OTHER')], [11, ['DIR_OTHER'], 'a/b']);
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
    assert.deepEqual([clash.code, clash.codes, clash.detail('DIR_OTHER')], [11, ['DIR_OTHER'], 'o/r']);
    fs.rmSync(path.join(e.ws, 'r'), { recursive: true }); // folder and config entry gone, key and alias stay
    fs.writeFileSync(e.cfg, JSON.stringify({ projects: {} }), { mode: 0o600 });
    const used = run(e, 'someone/else', 'r');
    assert.deepEqual([used.code, used.codes], [23, ['NAME_USED']]);
    assert.deepEqual(fs.readdirSync(e.ws), []);
  } finally { done(e); }
});

test('a project that already uses an ssh key keeps it, even when gh could push', { skip }, () => {
  const e = world('true');
  try {
    bare(e, 'o/r'); e.map('r');
    assert.equal(run(e, 'o/r', 'r', { FCODE_NO_TOKEN: '1' }).code, 0); // added by key
    const r = run(e, 'o/r', 'r'); // gh would say push = true now
    assert.deepEqual([r.code, r.codes.slice(0, 5)], [0, ['KEY_EXISTS', 'ALIAS_EXISTS', 'READ_OK', 'CLONE_EXISTS', 'HOOK_EXISTS']], r.stdout);
    assert.ok(!r.codes.includes('TOKEN_OK'));
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
      const again = await add({ repo: 'o/r' }); // safe to run again
      assert.deepEqual([again.json.state, again.json.code, again.json.via], ['done', 'ADDED', 'token']);
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