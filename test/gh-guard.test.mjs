// box/gh-guard.sh (the box's ~/.local/bin/gh) run for real with bash, in front of a stub "real gh" (FCODE_GH_REAL) that logs its argv.
// Run on Linux (the box): `node --test test/gh-guard.test.mjs`. Skipped where bash or git is missing (Windows).
// Tests named [astra N] / [review X] prove the findings of /tmp/ai-work/fcoding/wf-guard/astra-r1.md and review-r1.md (round 3).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const GUARD = path.join(here, '..', 'box', 'gh-guard.sh');
const ADD = path.join(here, '..', 'box', 'fcode-add.sh');
const skip = (process.platform === 'win32' || spawnSync('bash', ['-c', 'command -v git >/dev/null']).status !== 0) && 'needs Linux with bash and git';

// the stub: logs argv (one line per call). "pr view" prints STUB_PR; REST pulls/<n>/files prints STUB_FILES (STUB_FILES_FAIL: HTTP 502);
// "api repos/<o>/<r> -q .default_branch" prints main (STUB_NOREPO: HTTP 404); the tree of main lists one .github blob when STUB_WF is set
// (STUB_TRUNC: truncated, STUB_WF_FAIL: HTTP 502); that blob prints STUB_WF; "repo view" prints STUB_REPO; "auth git-credential" answers a
// credential; "stdin cat" echoes its stdin; anything else prints out:/err: lines (and in:<its stdin> when STUB_CAT is set), exits STUB_RC
const STUB = `#!/bin/bash
printf '%s\\n' "$*" >>"$STUB_LOG"
case "$*" in
  "pr view"*) [ -n "\${STUB_PR:-}" ] || { echo "no such PR" >&2; exit 1; }; printf '%s\\n' "$STUB_PR"; exit 0;;
  "api --paginate repos/"*/pulls/*/files" -q "*) [ -z "\${STUB_FILES_FAIL:-}" ] || { echo 'gh: Server Error (HTTP 502)' >&2; exit 1; }; printf '%s' "\${STUB_FILES:-}"; exit 0;;
  "api repos/"*" -q .default_branch") [ -z "\${STUB_NOREPO:-}" ] || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }; echo main; exit 0;;
  "api repos/"*"/git/trees/main?recursive=1 -q "*)
    [ -z "\${STUB_WF_FAIL:-}" ] || { echo 'gh: Server Error (HTTP 502)' >&2; exit 1; }
    [ -n "\${STUB_TRUNC:-}" ] && echo true || echo false
    [ -z "\${STUB_WF+x}" ] || echo "blob 1111111111111111111111111111111111111111"; exit 0;;
  "api repos/"*"/git/blobs/1111111111111111111111111111111111111111 -H Accept: application/vnd.github.raw") printf '%s\\n' "$STUB_WF"; exit 0;;
  "repo view"*) [ -n "\${STUB_REPO:-}" ] && echo "$STUB_REPO"; [ -n "\${STUB_REPO:-}" ]; exit;;
  "auth git-credential get") cat >/dev/null; printf 'protocol=https\\nhost=github.com\\nusername=x-access-token\\npassword=TOKEN-FROM-GH\\n'; exit 0;;
  "stdin cat") cat; exit 0;;
esac
[ -z "\${STUB_CAT:-}" ] || { printf 'in:'; cat; }
echo "out:$*"; echo "err:$*" >&2; exit "\${STUB_RC:-0}"
`;
const H = 'a1'.repeat(20); // the PR head the guard inspects
const H2 = 'b2'.repeat(20);
const MSG = (n, url = `https://github.com/o/r/pull/${n}`, head = H) =>
  `gh-guard: PR #${n} sửa .github/ ở repo có secret (head ${head}); chỉ chủ được duyệt — gọi fcode-notify <dự án> merge-ready "<một dòng>" ${url}\n`;
const SECRET_WF = 'env:\n  K: ${{ secrets.DEPLOY_SSH_KEY }}\n';
const PR = (n, repo = 'o/r', count = 1, head = H) => [n, `https://github.com/${repo}/pull/${n}`, head, count].join('\n');
const FILES = (...rows) => rows.map((r) => (Array.isArray(r) ? r : [r, '']).join('\t')).join('\n') + '\n';
const GH_FILES = (n, repo = 'o/r') => `api --paginate repos/${repo}/pulls/${n}/files -q .[] | [.filename, (.previous_filename // "")] | @tsv`;

function world() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'pc-gg-'));
  const e = { root, home: path.join(root, 'home'), cwd: path.join(root, 'cwd'), stub: path.join(root, 'real-gh'), log: path.join(root, 'gh.log') };
  fs.mkdirSync(e.home); fs.mkdirSync(e.cwd);
  fs.writeFileSync(e.stub, STUB, { mode: 0o755 });
  fs.writeFileSync(e.log, '');
  e.env = (env = {}) => ({ PATH: process.env.PATH, HOME: e.home, GIT_CONFIG_NOSYSTEM: '1', FCODE_GH_REAL: e.stub, STUB_LOG: e.log, ...env });
  e.run = (args, env = {}, opt = {}) => {
    const r = spawnSync('bash', [GUARD, ...args], { cwd: opt.cwd ?? e.cwd, input: opt.input ?? '', encoding: 'utf8', timeout: 30e3, env: e.env(env) });
    return { code: r.status, stdout: r.stdout, stderr: r.stderr };
  };
  e.calls = () => fs.readFileSync(e.log, 'utf8').split('\n').filter(Boolean);
  e.reset = () => fs.writeFileSync(e.log, '');
  e.allow = (name, mode = 0o600) => { const d = path.join(e.home, '.config', 'fcode', 'guard-allow'); fs.mkdirSync(d, { recursive: true }); const f = path.join(d, name); fs.writeFileSync(f, 'owner said yes\n'); fs.chmodSync(f, mode); return f; };
  e.allowLog = () => { const f = path.join(e.home, '.local', 'state', 'fcode', 'guard-allow.log'); return fs.existsSync(f) ? fs.readFileSync(f, 'utf8') : ''; };
  return e;
}
const done = (e) => fs.rmSync(e.root, { recursive: true, force: true });
const git = (env, ...a) => assert.equal(spawnSync('git', a, { encoding: 'utf8', env }).status, 0, a.join(' '));
// <root>/o/r.git with .github/workflows/d.yml = wf on main, cloned to <root>/clone
function clone(e, wf) {
  const env = { PATH: process.env.PATH, HOME: e.home, GIT_CONFIG_NOSYSTEM: '1' };
  const bare = path.join(e.root, 'o', 'r.git'); const seed = path.join(e.root, 'seed'); const dir = path.join(e.root, 'clone');
  git(env, 'init', '-q', '--bare', '-b', 'main', bare); git(env, 'init', '-q', '-b', 'main', seed);
  fs.mkdirSync(path.join(seed, '.github', 'workflows'), { recursive: true });
  fs.writeFileSync(path.join(seed, '.github', 'workflows', 'd.yml'), wf);
  git(env, '-C', seed, 'add', '-A'); git(env, '-c', 'user.name=t', '-c', 'user.email=t@t', '-C', seed, 'commit', '-q', '-m', 's'); git(env, '-C', seed, 'push', '-q', bare, 'main');
  git(env, 'clone', '-q', bare, dir);
  return dir;
}

test('gh-guard: syntax is valid bash, LF only', { skip }, () => {
  const r = spawnSync('bash', ['-n', GUARD], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  assert.ok(!fs.readFileSync(GUARD, 'latin1').includes('\r'));
});

test('gh-guard: the shared sensitivity rule is the same text in the guard and in the pre-push hook', { skip }, () => {
  const block = (t) => { const a = t.split('\n'); const s = a.findIndex((l) => l.startsWith('# >>> shared rule')); const end = a.indexOf('# <<< shared rule'); assert.ok(s >= 0 && end > s); return a.slice(s + 1, end).join('\n'); };
  const hook = spawnSync('bash', [ADD, '--hook-text'], { encoding: 'utf8' }).stdout;
  assert.equal(block(fs.readFileSync(GUARD, 'utf8')), block(hook));
  assert.match(block(hook), /git grep -qiF secrets "\$sr_t" -- ':\(top\)\.github'/);
});

test('gh-guard: every other call is passed through unchanged (argv, stdin, stdout, stderr, exit code) with no lookup: reads, GET with a query, gh workflow run', { skip }, () => {
  const e = world();
  try {
    for (const [args, rc] of [[['repo', 'list', '--limit', '5'], 0], [['run', 'view', '42', '--log'], 3], [['workflow', 'run', 'deploy.yml', '--ref', 'box/x', '-f', 'action=deploy'], 0],
      [['pr', 'create', '--base', 'main', '--fill'], 1], [['pr', 'list', '--state', 'merged'], 0], [['api', 'repos/o/r/contents/.github/workflows/ci.yml'], 0],
      [['api', 'repos/o/r/git/refs/heads/main'], 0], [['api', 'repos/o/r/pulls/5/merge'], 1], [['api', 'repos/o/r/commits/abc/statuses?per_page=100', '--paginate'], 0],
      [['api', '/user/repos?affiliation=owner,collaborator&sort=updated&per_page=100&page=1', '--jq', '.[] | @json'], 0], [['api', '-X', 'get', 'search/issues', '-f', 'q=x'], 0],
      [['api', '%72epos/o/r/contents/x'], 0], [['release', 'upload', 'v1', 'a.ipa'], 0], [['--version'], 0]]) {
      e.reset();
      const r = e.run(args, { STUB_RC: String(rc), STUB_WF: SECRET_WF });
      const line = args.join(' ');
      assert.deepEqual([r.code, r.stdout, r.stderr], [rc, `out:${line}\n`, `err:${line}\n`], line);
      assert.deepEqual(e.calls(), [line], line); // one call, no lookup of its own
    }
    const r = e.run(['issue', 'create', '--body-file', '-'], { STUB_CAT: '1' }, { input: 'line 1\nline 2\n' });
    assert.deepEqual([r.code, r.stdout], [0, 'in:line 1\nline 2\nout:issue create --body-file -\n']);
  } finally { done(e); }
});

test('gh-guard: git push through `credential.helper=!gh auth git-credential` still gets the credential from the real gh', { skip }, () => {
  const e = world();
  try {
    const bin = path.join(e.root, 'bin'); fs.mkdirSync(bin); fs.symlinkSync(GUARD, path.join(bin, 'gh'));
    const r = spawnSync('git', ['-c', 'credential.helper=', '-c', 'credential.helper=!gh auth git-credential', 'credential', 'fill'],
      { input: 'protocol=https\nhost=github.com\n\n', encoding: 'utf8', env: e.env({ PATH: `${bin}:${process.env.PATH}`, GIT_TERMINAL_PROMPT: '0' }) });
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /^password=TOKEN-FROM-GH$/m);
    assert.deepEqual(e.calls(), ['auth git-credential get']);
  } finally { done(e); }
});

test('gh-guard [astra 9]: a first word that is not a built-in gh command (alias, extension) is refused, its arguments never reach gh', { skip }, () => {
  const e = world();
  try {
    for (const args of [['p', 'merge', '5', '--squash'], ['co', '5'], ['some-extension', 'merge'], ['-R', 'o/r', 'pm', '5']]) {
      e.reset();
      const r = e.run(args, { STUB_ALIAS: 'p: pr\nco: pr checkout\npm: pr merge\n' });
      const first = args[0] === '-R' ? 'pm' : args[0];
      assert.deepEqual([r.code, r.stdout, r.stderr], [65, '', `gh-guard: '${first}' không phải lệnh gh có sẵn (alias, extension) — box không chạy alias hay extension; gõ lệnh gh đầy đủ.\n`], args.join(' '));
      assert.deepEqual(e.calls(), [], args.join(' '));
    }
  } finally { done(e); }
});

test('gh-guard: merging a PR that changes .github/ in a repo with secrets is refused (65) in any flag order; the merge never runs', { skip }, () => {
  const e = world();
  try {
    const env = { STUB_PR: PR(5, 'o/r', 2), STUB_FILES: FILES('src/a.js', '.github/workflows/deploy.yml'), STUB_WF: SECRET_WF };
    for (const args of [['pr', 'merge', '5', '--squash', '-R', 'o/r'], ['-R', 'o/r', 'pr', 'merge', '5'], ['pr', 'merge', '--squash', '--subject', 'a b', '5', '--repo=o/r'],
      ['pr', 'merge', '-dR', 'o/r', '5'], ['pr', 'merge', '-Ro/r', '-s', '5'], ['pr', 'merge', 'https://github.com/o/r/pull/5', '--merge'], ['pr', 'merge', '--body', '--help', '5', '-R', 'o/r']]) {
      e.reset();
      const r = e.run(args, env);
      assert.deepEqual([r.code, r.stdout, r.stderr], [65, '', MSG(5)], args.join(' '));
      assert.ok(!e.calls().some((c) => c.startsWith('pr merge')), args.join(' '));
      assert.ok(e.calls().includes(GH_FILES(5)), args.join(' ')); // the REST file list
    }
    // the selector and -R reach gh pr view as given; the current branch's PR when there is no selector
    e.reset(); e.run(['pr', 'merge', '--squash', '5', '-R', 'o/r'], env);
    assert.match(e.calls()[0], /^pr view 5 -R o\/r --json number,url,headRefOid,changedFiles /);
    e.reset(); assert.equal(e.run(['pr', 'merge', '--squash'], env).code, 65);
    assert.match(e.calls()[0], /^pr view --json /);
    // a workflow that only names secrets.GITHUB_TOKEN counts as secrets too (the word anywhere)
    e.reset(); assert.equal(e.run(['pr', 'merge', '5', '-R', 'o/r'], { ...env, STUB_WF: 'T: ${{ secrets.GITHUB_TOKEN }}\n' }).code, 65);
  } finally { done(e); }
});

test('gh-guard [astra 5]: --help never skips the checks (--help --help=false, --help alone)', { skip }, () => {
  const e = world();
  try {
    const env = { STUB_PR: PR(5, 'o/r', 1), STUB_FILES: FILES('.github/workflows/deploy.yml'), STUB_WF: SECRET_WF };
    for (const args of [['pr', 'merge', '5', '--squash', '--help', '--help=false', '-R', 'o/r'], ['pr', 'merge', '5', '--help', '-R', 'o/r']]) {
      e.reset();
      const r = e.run(args, env);
      assert.deepEqual([r.code, r.stderr], [65, MSG(5)], args.join(' '));
      assert.ok(!e.calls().some((c) => c.startsWith('pr merge')));
    }
    e.reset();
    const r = e.run(['api', 'graphql', '--help', '-f', 'query=mutation { mergePullRequest(input: {}) { clientMutationId } }']);
    assert.equal(r.code, 65); assert.deepEqual(e.calls(), []);
  } finally { done(e); }
});

test('gh-guard [astra 6]: flags are read like gh (pflag): -R=o/r, --repo=o/r, -dR=o/r, -X=PUT, -F=…; an unknown flag, a missing value or an extra argument is refused', { skip }, () => {
  const e = world();
  try {
    const env = { STUB_PR: PR(5, 'o/r', 1), STUB_FILES: FILES('.github/workflows/d.yml'), STUB_WF: SECRET_WF };
    for (const args of [['pr', 'merge', '-R=o/r', '5'], ['pr', 'merge', '--repo=o/r', '5'], ['pr', 'merge', '-dR=o/r', '5'], ['pr', 'merge', '-d=true', '-R', 'o/r', '5']]) {
      e.reset();
      const r = e.run(args, env);
      assert.deepEqual([r.code, r.stderr], [65, MSG(5)], args.join(' '));
      assert.match(e.calls()[0], /^pr view 5 -R o\/r --json /, args.join(' '));
    }
    e.reset();
    let r = e.run(['api', '-X=PUT', 'repos/o/r/contents/.github/workflows/x.yml', '--input', 'b.json'], env);
    assert.deepEqual([r.code, r.stderr], [65, 'gh-guard: o/r dùng secret trong workflow; gh api PUT vào repo này bị chặn — báo fcoding, chủ làm.\n']);
    fs.writeFileSync(path.join(e.cwd, 'q.graphql'), 'mutation { mergePullRequest(input: {}) { clientMutationId } }');
    r = e.run(['api', 'graphql', '-F=query=@q.graphql']);
    assert.equal(r.code, 65);
    // what the guard cannot classify: refused before any call
    const PARSE = /^gh-guard: không đọc chắc lệnh gh (pr merge|api) này/;
    for (const args of [['pr', 'merge', '5', '--squash', '--foo'], ['pr', 'merge', '5', '-R'], ['pr', 'merge', '5', '6'], ['pr', 'merge', '5', '-x'], ['pr', 'merge', '5', '-H', 'x'],
      ['api', '-Z', 'user'], ['api', 'user', 'extra'], ['api', 'repos/o/r', '--method'], ['api', '-R', 'o/r', 'user']]) {
      e.reset();
      r = e.run(args, env);
      assert.equal(r.code, 65, args.join(' ')); assert.match(r.stderr, PARSE, args.join(' '));
      assert.deepEqual(e.calls(), [], args.join(' '));
    }
  } finally { done(e); }
});

test('gh-guard [astra 7]: every gh api graphql call is refused, any spelling, any body (JSON-escaped included), no call made', { skip }, () => {
  const e = world();
  try {
    fs.writeFileSync(path.join(e.cwd, 'body.json'), '{"query":"mutation { \\u006dergePullRequest(input: {pullRequestId: \\"PR_x\\"}) { clientMutationId } }"}');
    for (const args of [['api', 'graphql', '--input', 'body.json'], ['api', 'graphql', '-f', 'query=query { viewer { login } }'], ['api', 'GraphQL', '-f', 'query=x'],
      ['api', '/graphql', '-f', 'query=x'], ['api', 'https://api.github.com/graphql', '-f', 'query=x'], ['api', '-X', 'GET', 'graphql', '-f', 'query=x'], ['api', 'graphql', '--paginate']]) {
      e.reset();
      const r = e.run(args, {}, { input: '' });
      assert.deepEqual([r.code, r.stdout], [65, ''], args.join(' '));
      assert.match(r.stderr, /^gh-guard: gh api graphql bị chặn trên box/, args.join(' '));
      assert.deepEqual(e.calls(), [], args.join(' '));
    }
  } finally { done(e); }
});

test('gh-guard [astra 8]: a non-GET gh api call whose target repo is not plainly repos/<o>/<r> is refused (encoded, traversal, other host, non-repo)', { skip }, () => {
  const e = world();
  try {
    const DOUBT = /^gh-guard: gh api .*: không xác định chắc repo đích; bị chặn/;
    for (const [args, env] of [[['api', '-X', 'PUT', '%72epos/o/r/contents/.github/workflows/x.yml', '--input', 'body.json'], {}], [['api', '%67raphql', '-f', 'query=x'], {}],
      [['api', '-X', 'PUT', 'repos/f/c/contents/%2e%2e/%2E%2E/o/r/contents/.github/x'], {}], [['api', '-X', 'PUT', 'repos/f/c/../../o/r/contents/.github/x'], {}],
      [['api', '-X', 'PUT', 'repos/f/c/./x'], {}], [['api', '-X', 'PUT', 'repos/o/r//contents/.github/x'], {}], [['api', '-X', 'PUT', 'repos\\o\\r\\contents'], {}],
      [['api', '-X', 'PUT', 'repos/f/c/contents/%252e%252e/x'], {}], [['api', '-X', 'PUT', 'https://api.github.com/repos/f/c/contents/x'], {}],
      [['api', '-X', 'PATCH', 'repos/f/c/issues/1', '--hostname', 'ghe.example'], {}], [['api', '-X', 'PATCH', 'repos/f/c/issues/1'], { GH_HOST: 'ghe.example' }],
      [['api', 'user/repos', '-f', 'name=x'], {}], [['api', '-X', 'PUT', 'repos/{owner}/{repo}/contents/x'], {}], [['api', '-X', '', 'graphq'], {}]]) {
      e.reset();
      const r = e.run(args, env);
      assert.equal(r.code, 65, args.join(' ')); assert.match(r.stderr, DOUBT, args.join(' '));
      assert.deepEqual(e.calls().filter((c) => !c.startsWith('repo view')), [], args.join(' '));
    }
  } finally { done(e); }
});

test('gh-guard [review P3 doubt]: in a repo without secrets, writes pass unchanged even with %20 or {owner}/{repo}/{branch}; in a repo with secrets every non-GET is refused', { skip }, () => {
  const e = world();
  try {
    const writes = [['api', '-X', 'PUT', 'repos/o/r/contents/docs/a%20b.md', '-f', 'content=eA=='], ['api', '-X', 'PATCH', 'repos/{owner}/{repo}/git/refs/heads/{branch}', '-F', 'force=true'],
      ['api', 'repos/o/r/issues/1/comments', '-f', 'body=100% done, see repos/o/r//contents/.github and mergePullRequest'], ['api', '-X', 'PUT', 'repos/o/r/pulls/5/merge'],
      ['api', '-X', 'PUT', 'repos/o/r/contents/.github/workflows/x.yml', '--input', '-'], ['api', '--method=DELETE', '/repos/o/r/actions/secrets/K'], ['api', 'repos/o/r/git/refs', '-f', 'ref=refs/heads/x']];
    for (const args of writes) { // no .github files on o/r: unchanged, stdin handed on
      e.reset();
      const r = e.run(args, { STUB_REPO: 'o/r', STUB_CAT: '1' }, { input: 'body' });
      assert.deepEqual([r.code, r.stdout, e.calls().at(-1)], [0, `in:bodyout:${args.join(' ')}\n`, args.join(' ')], args.join(' '));
    }
    for (const args of writes) {
      e.reset();
      const r = e.run(args, { STUB_REPO: 'o/r', STUB_WF: SECRET_WF });
      assert.equal(r.code, 65, args.join(' '));
      assert.match(r.stderr, /^gh-guard: o\/r dùng secret trong workflow; gh api (PUT|PATCH|POST|DELETE) vào repo này bị chặn/, args.join(' '));
      assert.ok(!e.calls().includes(args.join(' ')), args.join(' '));
    }
  } finally { done(e); }
});

test('gh-guard: the API rule fails closed: an unreadable repo, tree or truncated tree counts as secrets; a listed repo needs no API', { skip }, () => {
  const e = world();
  try {
    const env = { STUB_PR: PR(9, 'o/r', 1), STUB_FILES: FILES('.github/x') };
    for (const extra of [{ STUB_NOREPO: '1' }, { STUB_WF_FAIL: '1' }, { STUB_TRUNC: '1' }]) {
      const r = e.run(['pr', 'merge', '9', '-R', 'o/r'], { ...env, ...extra });
      assert.deepEqual([r.code, r.stderr], [65, MSG(9)], JSON.stringify(extra));
    }
    fs.mkdirSync(path.join(e.home, '.config', 'fcode'), { recursive: true });
    fs.writeFileSync(path.join(e.home, '.config', 'fcode', 'sensitive-repos'), '# owner\nO/R\n');
    e.reset();
    const r = e.run(['pr', 'merge', '9', '-R', 'o/r'], env); // no workflows at all, but listed
    assert.deepEqual([r.code, r.stderr], [65, MSG(9)]);
    assert.ok(!e.calls().some((c) => c.startsWith('api repos/o/r ') || c.includes('git/trees')), 'the list decides without the API');
  } finally { done(e); }
});

test('gh-guard [astra 10]: a rename out of .github/ is seen through previous_filename; an unreadable or short file list, or an unreadable PR, refuses', { skip }, () => {
  const e = world();
  try {
    let r = e.run(['pr', 'merge', '5', '-R', 'o/r'], { STUB_PR: PR(5, 'o/r', 1), STUB_FILES: FILES(['retired-deploy.yml', '.github/workflows/deploy.yml']), STUB_WF: SECRET_WF });
    assert.deepEqual([r.code, r.stderr], [65, MSG(5)]);
    r = e.run(['pr', 'merge', '5', '-R', 'o/r'], { STUB_PR: PR(5, 'o/r', 1), STUB_FILES: FILES(['.GitHub/x.yml', 'src/x.yml']), STUB_WF: SECRET_WF });
    assert.deepEqual([r.code, r.stderr], [65, MSG(5)]);
    r = e.run(['pr', 'merge', '5', '-R', 'o/r'], { STUB_PR: PR(5, 'o/r', 3), STUB_FILES: FILES('a.js', 'b.js'), STUB_WF: SECRET_WF }); // 2 of 3 listed
    assert.deepEqual([r.code, r.stderr], [65, MSG(5)]);
    r = e.run(['pr', 'merge', '5', '-R', 'o/r'], { STUB_PR: PR(5, 'o/r', 1), STUB_FILES_FAIL: '1', STUB_WF: SECRET_WF });
    assert.deepEqual([r.code, r.stderr], [65, MSG(5)]);
    r = e.run(['pr', 'merge', '9', '-R', 'o/r'], { STUB_WF: SECRET_WF });
    assert.equal(r.code, 65); assert.match(r.stderr, /^gh-guard: không đọc được PR 9;/);
    for (const pr of [['5', 'https://github.com/o/r/pull/5', 'abc', '1'].join('\n'), ['5', 'https://github.com/o/r/pull/6', H, '1'].join('\n'), ['5', 'https://github.com/o/r?x/pull/5', H, '1'].join('\n')]) {
      r = e.run(['pr', 'merge', '5', '-R', 'o/r'], { STUB_PR: pr, STUB_FILES: FILES('a.js'), STUB_WF: SECRET_WF });
      assert.equal(r.code, 65, pr); assert.match(r.stderr, /^gh-guard: không đọc rõ PR 5/, pr);
    }
  } finally { done(e); }
});

test('gh-guard [astra 11]: an allowed merge in a repo with secrets runs pinned to the inspected head (--match-head-commit), another head given is refused, auto-merge is refused', { skip }, () => {
  const e = world();
  try {
    const env = { STUB_PR: PR(5, 'o/r', 2), STUB_FILES: FILES('src/a.js', 'docs/.github-notes.md'), STUB_WF: SECRET_WF, STUB_CAT: '1' };
    for (const [args, fwd] of [[['pr', 'merge', '5', '--squash', '-R', 'o/r'], `pr merge 5 --squash -R o/r --match-head-commit ${H}`],
      [['pr', 'merge', '--squash', '-R', 'o/r', '--', '5'], `pr merge --squash -R o/r --match-head-commit ${H} -- 5`],
      [['pr', 'merge', '5', '-R', 'o/r', '--body', '--', '-s'], `pr merge 5 -R o/r --body -- -s --match-head-commit ${H}`],
      [['pr', 'merge', '5', '-R', 'o/r', `--match-head-commit=${H}`], `pr merge 5 -R o/r --match-head-commit=${H}`]]) {
      e.reset();
      const r = e.run(args, env, { input: 'stdin body' });
      assert.deepEqual([r.code, r.stdout, e.calls().at(-1)], [0, `in:stdin bodyout:${fwd}\n`, fwd], args.join(' '));
    }
    e.reset();
    let r = e.run(['pr', 'merge', '5', '-R', 'o/r', '--match-head-commit', H2], env);
    assert.deepEqual([r.code, r.stderr], [65, `gh-guard: PR #5: --match-head-commit ${H2} khác head đã kiểm tra ${H}; bị chặn.\n`]);
    for (const a of ['--auto', '--auto=false', '--disable-auto']) {
      e.reset();
      r = e.run(['pr', 'merge', '5', '-R', 'o/r', a], env);
      assert.equal(r.code, 65, a); assert.match(r.stderr, /^gh-guard: PR #5: auto-merge ở repo có secret bị chặn/, a);
      assert.ok(!e.calls().some((c) => c.startsWith('pr merge')), a);
    }
    // a repo without secrets: the call runs exactly as given (no pin), .github and --auto included
    for (const args of [['pr', 'merge', '5', '-R', 'o/r', '--auto'], ['pr', 'merge', '5', '-R', 'o/r']]) {
      e.reset();
      r = e.run(args, { STUB_PR: PR(5, 'o/r', 1), STUB_FILES: FILES('.github/workflows/ci.yml') });
      assert.deepEqual([r.code, e.calls().at(-1)], [0, args.join(' ')], args.join(' '));
      assert.ok(!e.calls().includes(GH_FILES(5)), 'no file list needed');
    }
  } finally { done(e); }
});

test('gh-guard [review P2 allow]: a .github PR in a repo with secrets merges only with the owner\'s allow file for that exact head; the use is logged and the file removed after success', { skip }, () => {
  const e = world();
  try {
    const env = { STUB_PR: PR(5, 'O/R', 1), STUB_FILES: FILES('.github/workflows/deploy.yml'), STUB_WF: SECRET_WF };
    const url = 'https://github.com/O/R/pull/5';
    // wrong sha, wrong mode, a link: refused, nothing logged
    const wrong = e.allow(`o__r__${H2}`);
    let r = e.run(['pr', 'merge', '5', '-R', 'O/R'], env);
    assert.deepEqual([r.code, r.stderr], [65, MSG(5, url)]);
    fs.rmSync(wrong);
    const f = e.allow(`o__r__${H}`, 0o644);
    r = e.run(['pr', 'merge', '5', '-R', 'O/R'], env);
    assert.equal(r.code, 65);
    fs.rmSync(f); const target = path.join(e.root, 'target'); fs.writeFileSync(target, 'x', { mode: 0o600 }); fs.chmodSync(target, 0o600); fs.symlinkSync(target, f);
    r = e.run(['pr', 'merge', '5', '-R', 'O/R'], env);
    assert.equal(r.code, 65);
    fs.rmSync(f);
    assert.equal(e.allowLog(), '');
    // the right file: a failed merge keeps it, a merge that worked removes it; every use is one log line
    e.allow(`o__r__${H}`);
    e.reset();
    r = e.run(['pr', 'merge', '5', '-R', 'O/R', '--squash'], { ...env, STUB_RC: '1' });
    assert.deepEqual([r.code, e.calls().at(-1)], [1, `pr merge 5 -R O/R --squash --match-head-commit ${H}`]);
    assert.ok(fs.existsSync(f));
    r = e.run(['pr', 'merge', '5', '-R', 'O/R', '--squash'], env);
    assert.deepEqual([r.code, r.stdout], [0, `out:pr merge 5 -R O/R --squash --match-head-commit ${H}\n`]);
    assert.ok(!fs.existsSync(f), 'used once');
    const lines = e.allowLog().trim().split('\n');
    assert.equal(lines.length, 2);
    for (const l of lines) assert.match(l, new RegExp(`^\\d{4}-\\d\\d-\\d\\dT\\d\\d:\\d\\d:\\d\\dZ O/R ${H} merge$`));
    // gone now: refused again
    assert.equal(e.run(['pr', 'merge', '5', '-R', 'O/R'], env).code, 65);
    // auto-merge stays refused even with the file
    e.allow(`o__r__${H}`);
    assert.equal(e.run(['pr', 'merge', '5', '-R', 'O/R', '--auto'], env).code, 65);
  } finally { done(e); }
});

test('gh-guard [astra 1, review P3 b]: in a clone of the PR\'s base repo the rule is read from origin (not the API), from any folder, .github/ included', { skip }, () => {
  const e = world();
  try {
    const dir = clone(e, SECRET_WF);
    const env = { STUB_PR: PR(3, 'o/r', 1), STUB_FILES: FILES('.github/workflows/d.yml') }; // the API would say "no workflows" (STUB_WF unset)
    for (const cwd of [dir, path.join(dir, '.github'), path.join(dir, '.github', 'workflows')]) {
      e.reset();
      const r = e.run(['pr', 'merge', '3'], env, { cwd });
      assert.deepEqual([r.code, r.stderr], [65, MSG(3)], cwd);
      assert.ok(!e.calls().some((c) => c.includes('default_branch') || c.includes('git/trees')), cwd);
    }
    // a PR of another repo from this clone goes to the API (no .github files there: passes unchanged)
    e.reset();
    let r = e.run(['pr', 'merge', '3', '-R', 'x/y'], { STUB_PR: PR(3, 'x/y', 1), STUB_FILES: FILES('.github/workflows/d.yml') }, { cwd: dir });
    assert.equal(r.code, 0, r.stderr);
    assert.ok(e.calls().includes('api repos/x/y -q .default_branch'));
    // a clone whose workflows never say "secrets": the merge runs unchanged, no API (the review's missing allow case)
    done(e);
    const e2 = world();
    try {
      const d2 = clone(e2, 'on: push\njobs: {}\n');
      r = e2.run(['pr', 'merge', '3', '--squash'], env, { cwd: path.join(d2, '.github') });
      assert.deepEqual([r.code, e2.calls().at(-1)], [0, 'pr merge 3 --squash']);
      assert.ok(!e2.calls().some((c) => c.startsWith('api')));
    } finally { done(e2); }
    const e3 = world();
    try {
      const d3 = clone(e3, 'T: ${{ secrets.GITHUB_TOKEN }}\n'); // the word alone counts
      r = e3.run(['pr', 'merge', '3'], env, { cwd: d3 });
      assert.equal(r.code, 65);
    } finally { done(e3); }
  } finally { if (fs.existsSync(e.root)) done(e); }
});

test('gh-guard: never calls itself: a real gh that is this script (or a link to it) or missing ends at once with 127', { skip }, () => {
  const e = world();
  try {
    const link = path.join(e.root, 'gh-link'); fs.symlinkSync(GUARD, link);
    for (const real of [GUARD, link, path.join(e.root, 'missing'), e.root]) {
      const r = e.run(['pr', 'list'], { FCODE_GH_REAL: real });
      assert.deepEqual([r.code, r.stdout], [127, ''], real);
      assert.match(r.stderr, /^gh-guard: real gh not found/);
    }
    assert.deepEqual(e.calls(), []);
  } finally { done(e); }
});
