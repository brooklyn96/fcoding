// box/gh-guard.sh (the box's ~/.local/bin/gh) run for real with bash, in front of a stub "real gh" (FCODE_GH_REAL) that logs its argv.
// Run on Linux (the box): `node --test test/gh-guard.test.mjs`. Skipped where bash or git is missing (Windows).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const GUARD = path.join(here, '..', 'box', 'gh-guard.sh');
const skip = (process.platform === 'win32' || spawnSync('bash', ['-c', 'command -v git >/dev/null']).status !== 0) && 'needs Linux with bash and git';

// the stub: logs argv (one line per call); "pr view" prints STUB_PR, the workflow listing of a repo prints one file url (or 404 when STUB_WF is
// unset), that url prints STUB_WF, "repo view" prints STUB_REPO, "alias list" prints STUB_ALIAS, "stdin cat" echoes its stdin; anything else
// prints out:/err: lines (and in:<its stdin> when STUB_CAT is set) and exits STUB_RC
const STUB = `#!/bin/bash
printf '%s\\n' "$*" >>"$STUB_LOG"
case "$1 $2" in
  "pr view") [ -n "\${STUB_PR:-}" ] || { echo "no such PR" >&2; exit 1; }; printf '%s\\n' "$STUB_PR"; exit 0;;
  "api repos/"*/contents/.github/workflows)
    [ -n "\${STUB_WF+x}" ] || { echo '{"message":"Not Found"}'; echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
    [ -z "\${STUB_WF_FAIL:-}" ] || { echo 'gh: Server Error (HTTP 502)' >&2; exit 1; }
    echo "https://api.github.com/repos/$(echo "$2" | cut -d/ -f2-3)/contents/.github/workflows/ci.yml?ref=main"; exit 0;;
  "api https://api.github.com/"*) printf '%s\\n' "$STUB_WF"; exit 0;;
  "repo view") [ -n "\${STUB_REPO:-}" ] && echo "$STUB_REPO"; [ -n "\${STUB_REPO:-}" ]; exit;;
  "alias list") printf '%s' "\${STUB_ALIAS:-}"; exit 0;;
  "stdin cat") cat; exit 0;;
esac
[ -z "\${STUB_CAT:-}" ] || { printf 'in:'; cat; }
echo "out:$*"; echo "err:$*" >&2; exit "\${STUB_RC:-0}"
`;
const MSG = (n) => `gh-guard: PR #${n} sửa .github/ ở repo có secret; chỉ chủ được merge — gọi fcode-notify merge-ready.\n`;
const SECRET_WF = 'env:\n  K: ${{ secrets.DEPLOY_SSH_KEY }}\n';
const PR = (n, repo, files, count = files.length) => [n, `https://github.com/${repo}/pull/${n}`, count, ...files].join('\n');

function world() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'pc-gg-'));
  const e = { root, home: path.join(root, 'home'), cwd: path.join(root, 'cwd'), stub: path.join(root, 'real-gh'), log: path.join(root, 'gh.log') };
  fs.mkdirSync(e.home); fs.mkdirSync(e.cwd);
  fs.writeFileSync(e.stub, STUB, { mode: 0o755 });
  fs.writeFileSync(e.log, '');
  e.run = (args, env = {}, opt = {}) => {
    const r = spawnSync('bash', [GUARD, ...args], { cwd: opt.cwd ?? e.cwd, input: opt.input ?? '', encoding: 'utf8', timeout: 30e3,
      env: { PATH: process.env.PATH, HOME: e.home, GIT_CONFIG_NOSYSTEM: '1', FCODE_GH_REAL: e.stub, STUB_LOG: e.log, ...env } });
    return { code: r.status, stdout: r.stdout, stderr: r.stderr };
  };
  e.calls = () => fs.readFileSync(e.log, 'utf8').split('\n').filter(Boolean);
  e.reset = () => fs.writeFileSync(e.log, '');
  return e;
}
const done = (e) => fs.rmSync(e.root, { recursive: true, force: true });

test('gh-guard: syntax is valid bash, LF only', { skip }, () => {
  const r = spawnSync('bash', ['-n', GUARD], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  assert.ok(!fs.readFileSync(GUARD, 'latin1').includes('\r'));
});

test('gh-guard: every other call is passed through unchanged (argv, stdin, stdout, stderr, exit code), gh workflow run included', { skip }, () => {
  const e = world();
  try {
    for (const [args, rc] of [[['repo', 'list', '--limit', '5'], 0], [['run', 'view', '42', '--log'], 3], [['workflow', 'run', 'deploy.yml', '--ref', 'box/x', '-f', 'action=deploy'], 0],
      [['pr', 'create', '--base', 'main', '--fill'], 1], [['pr', 'list', '--state', 'merged'], 0], [['api', 'repos/o/r/contents/.github/workflows/ci.yml'], 0], [['api', '-X', 'PUT', 'repos/o/r/contents/README.md', '-f', 'content=eA=='], 0],
      [['api', 'graphql', '-f', 'query=query { viewer { login } }'], 0], [['api', 'repos/o/r/git/refs/heads/main'], 0], [['api', 'repos/o/r/pulls/5/merge'], 1],
      [['api', 'repos/o/r/issues/1/comments', '-f', 'body=100% done, see repos/o/r//contents/.github and mergePullRequest'], 0], [['api', '-X', 'POST', 'repos/o/r/git/blobs', '-f', 'content=x'], 0]]) {
      e.reset();
      const r = e.run(args, { STUB_RC: String(rc), STUB_WF: SECRET_WF });
      const line = args.join(' ');
      assert.deepEqual([r.code, r.stdout, r.stderr], [rc, `out:${line}\n`, `err:${line}\n`], line);
      assert.deepEqual(e.calls(), [line], line); // one call, no lookup of its own
    }
    const r = e.run(['stdin', 'cat'], {}, { input: 'line 1\nline 2\n' });
    assert.deepEqual([r.code, r.stdout], [0, 'line 1\nline 2\n']);
  } finally { done(e); }
});

test('gh-guard: merging a PR that changes .github/ in a repo whose workflow reads a secret is refused (65), in any flag order; the merge never runs', { skip }, () => {
  const e = world();
  try {
    const env = { STUB_PR: PR(5, 'o/r', ['src/a.js', '.github/workflows/deploy.yml']), STUB_WF: SECRET_WF };
    for (const args of [['pr', 'merge', '5', '--squash', '-R', 'o/r'], ['-R', 'o/r', 'pr', 'merge', '5'], ['pr', 'merge', '--squash', '--subject', 'a b', '5', '--repo=o/r'],
      ['pr', 'merge', '-dR', 'o/r', '5', '--auto'], ['pr', 'merge', '-Ro/r', '-s', '5'], ['pr', 'merge', 'https://github.com/o/r/pull/5', '--merge'], ['pr', 'merge', '--body', '-h', '5', '-R', 'o/r']]) {
      e.reset();
      const r = e.run(args, env);
      assert.deepEqual([r.code, r.stdout, r.stderr], [65, '', MSG(5)], args.join(' '));
      assert.ok(!e.calls().some((c) => c.startsWith('pr merge')), args.join(' '));
      assert.ok(e.calls().some((c) => c.startsWith('api repos/o/r/contents/.github/workflows')), args.join(' ')); // not a clone here: read through the API
    }
    // the selector and -R reach gh pr view as given
    e.reset(); e.run(['pr', 'merge', '--squash', '5', '-R', 'o/r'], env);
    assert.match(e.calls()[0], /^pr view 5 -R o\/r --json number,url,changedFiles,files /);
    // the current branch's PR (no selector)
    e.reset(); assert.equal(e.run(['pr', 'merge', '--squash'], env).code, 65);
    assert.match(e.calls()[0], /^pr view --json /);
  } finally { done(e); }
});

test('gh-guard: allowed merges pass through unchanged: no .github change, GITHUB_TOKEN-only or no workflows, help', { skip }, () => {
  const e = world();
  try {
    const cases = [
      { STUB_PR: PR(6, 'o/r', ['src/a.js', 'docs/.github-notes.md']), STUB_WF: SECRET_WF },
      { STUB_PR: PR(7, 'o/r', ['.github/workflows/ci.yml']), STUB_WF: '# no secrets here\nT: ${{ secrets.GITHUB_TOKEN }}\n' },
      { STUB_PR: PR(8, 'o/r', ['.github/workflows/ci.yml']) }, // no .github/workflows on the default branch (404)
    ];
    for (const env of cases) {
      e.reset();
      const r = e.run(['pr', 'merge', '--squash', '-R', 'o/r'], { ...env, STUB_RC: '0' });
      assert.deepEqual([r.code, r.stdout, r.stderr], [0, 'out:pr merge --squash -R o/r\n', 'err:pr merge --squash -R o/r\n'], env.STUB_PR);
      assert.equal(e.calls().at(-1), 'pr merge --squash -R o/r');
    }
    e.reset();
    const h = e.run(['pr', 'merge', '--help']);
    assert.equal(h.code, 0);
    assert.deepEqual(e.calls(), ['pr merge --help']);
  } finally { done(e); }
});

test('gh-guard: fail closed: an unreadable PR, a file list shorter than changedFiles (gh stops at 100), an unreadable workflow listing, or a listed repo refuse the merge', { skip }, () => {
  const e = world();
  try {
    let r = e.run(['pr', 'merge', '9', '-R', 'o/r'], { STUB_WF: SECRET_WF }); // pr view fails
    assert.equal(r.code, 65); assert.match(r.stderr, /^gh-guard: không đọc được PR 9;/);
    r = e.run(['pr', 'merge', '9', '-R', 'o/r'], { STUB_PR: PR(9, 'o/r', ['a.js'], 100), STUB_WF: SECRET_WF });
    assert.deepEqual([r.code, r.stderr], [65, MSG(9)]);
    r = e.run(['pr', 'merge', '9', '-R', 'o/r'], { STUB_PR: PR(9, 'o/r', ['.github/x']), STUB_WF: '', STUB_WF_FAIL: '1' }); // HTTP 502 on the listing
    assert.deepEqual([r.code, r.stderr], [65, MSG(9)]);
    fs.mkdirSync(path.join(e.home, '.config', 'fcode'), { recursive: true });
    fs.writeFileSync(path.join(e.home, '.config', 'fcode', 'sensitive-repos'), '# owner\nO/R\n');
    e.reset();
    r = e.run(['pr', 'merge', '9', '-R', 'o/r'], { STUB_PR: PR(9, 'o/r', ['.github/x']) }); // no workflows at all, but listed
    assert.deepEqual([r.code, r.stderr], [65, MSG(9)]);
    assert.ok(!e.calls().some((c) => c.startsWith('api')), 'the list decides without the API');
  } finally { done(e); }
});

test('gh-guard: in a clone of the PR\'s base repo the rule is read from origin\'s default branch (like the hook), not the API', { skip }, () => {
  const e = world();
  try {
    const g = (...a) => assert.equal(spawnSync('git', a, { encoding: 'utf8', env: { PATH: process.env.PATH, HOME: e.home, GIT_CONFIG_NOSYSTEM: '1' } }).status, 0, a.join(' '));
    const bare = path.join(e.root, 'o', 'r.git'); const seed = path.join(e.root, 'seed'); const clone = path.join(e.root, 'clone');
    g('init', '-q', '--bare', '-b', 'main', bare); g('init', '-q', '-b', 'main', seed);
    fs.mkdirSync(path.join(seed, '.github', 'workflows'), { recursive: true });
    fs.writeFileSync(path.join(seed, '.github', 'workflows', 'd.yml'), SECRET_WF);
    g('-C', seed, 'add', '-A'); g('-c', 'user.name=t', '-c', 'user.email=t@t', '-C', seed, 'commit', '-q', '-m', 's'); g('-C', seed, 'push', '-q', bare, 'main');
    g('clone', '-q', bare, clone);
    const env = { STUB_PR: PR(3, 'o/r', ['.github/workflows/d.yml']) }; // the API would say "no workflows" (STUB_WF unset)
    let r = e.run(['pr', 'merge', '3'], env, { cwd: clone });
    assert.deepEqual([r.code, r.stderr], [65, MSG(3)]);
    assert.ok(!e.calls().some((c) => c.startsWith('api')));
    // a PR of another repo from this clone goes to the API
    e.reset();
    r = e.run(['pr', 'merge', '3', '-R', 'x/y'], { STUB_PR: PR(3, 'x/y', ['.github/workflows/d.yml']) }, { cwd: clone });
    assert.equal(r.code, 0, r.stderr);
    assert.ok(e.calls().some((c) => c.startsWith('api repos/x/y/contents/.github/workflows')));
  } finally { done(e); }
});

test('gh-guard: gh api PUT/PATCH/DELETE on contents/.github, actions/secrets or environments of a repo with secrets is refused; doubtful paths too', { skip }, () => {
  const e = world();
  try {
    const env = { STUB_WF: SECRET_WF, STUB_REPO: 'o/r' };
    for (const args of [['api', '-X', 'PUT', 'repos/o/r/contents/.github/workflows/x.yml', '-f', 'content=eA=='], ['api', '--method=DELETE', '/repos/o/r/actions/secrets/K'],
      ['api', '-XPATCH', 'https://api.github.com/repos/o/r/environments/prod'], ['api', 'repos/O/R/environments/prod/secrets/K', '--method', 'put'],
      ['api', '-X', 'PUT', 'repos/{owner}/{repo}/actions/secrets/K'], ['api', '-X', 'DELETE', 'repos/o/r/contents/.github?ref=box/x']]) {
      e.reset();
      const r = e.run(args, env);
      assert.equal(r.code, 65, args.join(' '));
      assert.match(r.stderr, /^gh-guard: o\/r dùng secret trong workflow; gh api (PUT|PATCH|DELETE) vào \.github\/, secrets, environments, git refs\/trees\/commits hay merges bị chặn/i, args.join(' '));
      assert.ok(!e.calls().some((c) => c.startsWith(args.slice(0, 2).join(' '))), args.join(' '));
    }
    for (const args of [['api', '-X', 'PUT', 'repos/o/r/contents/%2Egithub/x'], ['api', '-X', 'PUT', 'repos/o/r/contents/./.github/x'], ['api', '-X', 'PUT', 'repos/o/r//contents/.github/x'],
      ['api', '-X', 'PUT', 'repos/{owner}/r/contents/.github/x']]) {
      const r = e.run(args, env);
      assert.equal(r.code, 65, args.join(' '));
      assert.match(r.stderr, /^gh-guard: không đọc rõ đường dẫn của gh api PUT/, args.join(' '));
    }
    // same calls on a repo without secrets, reads, POST, and other paths pass
    for (const [args, en] of [[['api', '-X', 'PUT', 'repos/o/r/contents/.github/workflows/x.yml'], {}], [['api', 'repos/o/r/actions/secrets'], env],
      [['api', '-X', 'POST', 'repos/o/r/actions/workflows/d.yml/dispatches'], env], [['api', '-X', 'PUT', 'repos/o/r/contents/src/a.js'], env]]) {
      e.reset();
      const r = e.run(args, en);
      assert.deepEqual([r.code, r.stdout], [0, `out:${args.join(' ')}\n`], args.join(' '));
    }
    // {owner}/{repo} that gh cannot resolve: refused
    const r = e.run(['api', '-X', 'PUT', 'repos/{owner}/{repo}/environments/x'], { STUB_WF: SECRET_WF });
    assert.equal(r.code, 65);
  } finally { done(e); }
});

test('gh-guard: gh api PUT repos/<o>/<r>/pulls/<n>/merge is checked like gh pr merge; --auto merges too', { skip }, () => {
  const e = world();
  try {
    const env = { STUB_PR: PR(5, 'o/r', ['src/a.js', '.github/workflows/deploy.yml']), STUB_WF: SECRET_WF, STUB_REPO: 'o/r' };
    for (const args of [['api', '-X', 'PUT', 'repos/o/r/pulls/5/merge'], ['api', '--method=put', '/repos/o/r/pulls/5/merge', '-f', 'merge_method=squash'],
      ['api', '-XPUT', 'https://api.github.com/repos/o/r/pulls/5/merge'], ['api', '-X', 'PUT', 'repos/{owner}/{repo}/pulls/5/merge'], ['api', 'repos/o/r/pulls/5/merge', '-X', 'PUT', '--input', '-'],
      ['pr', 'merge', '--auto', '--squash', '5', '-R', 'o/r']]) {
      e.reset();
      const r = e.run(args, env, { input: '{"merge_method":"merge"}' });
      assert.deepEqual([r.code, r.stdout, r.stderr], [65, '', MSG(5)], args.join(' '));
      assert.ok(e.calls().some((c) => c.startsWith('pr view 5 -R o/r --json ')), args.join(' '));
      assert.ok(!e.calls().some((c) => c.includes('pulls/5/merge') || c.startsWith('pr merge')), args.join(' '));
    }
    // a PR without .github, or a repo without secrets: the call runs unchanged (stdin included)
    for (const en of [{ ...env, STUB_PR: PR(5, 'o/r', ['src/a.js']) }, { STUB_PR: env.STUB_PR }]) {
      e.reset();
      const r = e.run(['api', '-X', 'PUT', 'repos/o/r/pulls/5/merge', '--input', '-'], { ...en, STUB_CAT: '1' }, { input: '{"merge_method":"squash"}' });
      assert.deepEqual([r.code, r.stdout], [0, 'in:{"merge_method":"squash"}out:api -X PUT repos/o/r/pulls/5/merge --input -\n']);
      assert.equal(e.calls().at(-1), 'api -X PUT repos/o/r/pulls/5/merge --input -');
    }
    e.reset();
    const r = e.run(['api', '-X', 'PUT', 'repos/o/r/pulls/5/merge'], { STUB_WF: SECRET_WF }); // pr view fails
    assert.equal(r.code, 65); assert.match(r.stderr, /^gh-guard: không đọc được PR 5;/);
    assert.ok(!e.calls().some((c) => c.includes('pulls/5/merge')));
  } finally { done(e); }
});

test('gh-guard: gh api graphql naming a merge or branch-write mutation is refused in every repo (query in -f, -F @file, --input file or stdin, URL endpoint); other graphql passes', { skip }, () => {
  const e = world();
  try {
    const file = path.join(e.root, 'q.graphql');
    const mut = (m) => `mutation { ${m}(input: {pullRequestId: "PR_kwDO"}) { clientMutationId } }`;
    const MSGQ = (m) => `gh-guard: gh api graphql có ${m} (merge hoặc ghi nhánh) bị chặn: box không biết repo đích; dùng gh pr merge hoặc git push để box kiểm tra — repo có secret thì gọi fcode-notify merge-ready.\n`;
    for (const m of ['mergePullRequest', 'enablePullRequestAutoMerge', 'enqueuePullRequest', 'createCommitOnBranch', 'updateRef', 'updateRefs', 'createRef', 'mergeBranch']) {
      e.reset();
      const r = e.run(['api', 'graphql', '-f', `query=${mut(m)}`]); // no secrets anywhere (STUB_WF unset): still refused
      assert.deepEqual([r.code, r.stdout, r.stderr], [65, '', MSGQ(m)], m);
      assert.deepEqual(e.calls(), [], m);
    }
    fs.writeFileSync(file, mut('mergePullRequest'));
    const body = JSON.stringify({ query: 'mutation($id: ID!) { mergePullRequest(input: {pullRequestId: $id}) { clientMutationId } }', variables: { id: 'PR_kwDO' } });
    for (const [args, input] of [[['api', 'graphql', '-F', `query=@${file}`], ''], [['api', 'graphql', '--input', file], ''], [['api', 'graphql', '--input', '-'], body],
      [['api', 'graphql', '-F', 'query=@-', '-f', 'id=PR_kwDO'], mut('mergePullRequest')], [['api', '--raw-field=query=' + mut('mergePullRequest'), 'https://api.github.com/graphql'], ''],
      [['api', 'GraphQL', '--field', `query=@${file}`], ''], [['api', '-X', 'POST', 'graphql', '-fquery=' + mut('mergepullrequest')], '']]) {
      e.reset();
      const r = e.run(args, {}, { input });
      assert.equal(r.code, 65, args.join(' ')); assert.match(r.stderr, /^gh-guard: gh api graphql có mergePullRequest \(merge/i, args.join(' '));
      assert.deepEqual(e.calls(), [], args.join(' '));
    }
    // a file the guard cannot read: refused (fail closed)
    let r = e.run(['api', 'graphql', '--input', path.join(e.root, 'missing.json')]);
    assert.equal(r.code, 65); assert.match(r.stderr, /^gh-guard: không đọc được .*missing\.json cho gh api graphql/);
    // other graphql passes unchanged, its stdin handed on to the real gh
    e.reset();
    const q = JSON.stringify({ query: 'query { repository(owner: "o", name: "r") { pullRequests(first: 1) { nodes { number } } } }' });
    r = e.run(['api', 'graphql', '--input', '-'], { STUB_CAT: '1', STUB_WF: SECRET_WF }, { input: q });
    assert.deepEqual([r.code, r.stdout, r.stderr], [0, `in:${q}out:api graphql --input -\n`, 'err:api graphql --input -\n']);
    assert.deepEqual(e.calls(), ['api graphql --input -']);
    fs.writeFileSync(file, 'query { viewer { login } }');
    e.reset();
    r = e.run(['api', 'graphql', '-F', `query=@${file}`], { STUB_WF: SECRET_WF });
    assert.deepEqual([r.code, e.calls()], [0, [`api graphql -F query=@${file}`]]);
  } finally { done(e); }
});

test('gh-guard: gh api writes to git/refs, git/trees, git/commits or merges of a repo with secrets are refused (fields without -X mean POST); other repos pass', { skip }, () => {
  const e = world();
  try {
    const calls = [['api', 'repos/o/r/git/refs', '-f', 'ref=refs/heads/x', '-f', 'sha=abc'], ['api', '-X', 'PATCH', 'repos/o/r/git/refs/heads/box/x', '-F', 'force=true'],
      ['api', '-X', 'POST', 'repos/o/r/git/trees', '--input', '-'], ['api', 'repos/o/r/git/commits', '-f', 'message=m', '-f', 'tree=t'],
      ['api', '-X', 'POST', 'repos/o/r/merges', '-f', 'base=main', '-f', 'head=box/x'], ['api', '-X', 'DELETE', 'repos/o/r/git/refs/heads/main']];
    for (const args of calls) {
      e.reset();
      const r = e.run(args, { STUB_WF: SECRET_WF });
      assert.equal(r.code, 65, args.join(' '));
      assert.match(r.stderr, /^gh-guard: o\/r dùng secret trong workflow; gh api (POST|PATCH|DELETE) vào .*git refs\/trees\/commits hay merges bị chặn/, args.join(' '));
      assert.ok(!e.calls().some((c) => c.startsWith(args.slice(0, 2).join(' '))), args.join(' '));
    }
    for (const args of calls) { // no workflows on o/r (404): unchanged
      e.reset();
      const r = e.run(args);
      assert.deepEqual([r.code, r.stdout, e.calls().at(-1)], [0, `out:${args.join(' ')}\n`, args.join(' ')], args.join(' '));
    }
  } finally { done(e); }
});

test('gh-guard: an alias whose expansion runs merge or api is refused; other aliases and extensions pass unchanged', { skip }, () => {
  const e = world();
  try {
    const env = { STUB_ALIAS: 'co: pr checkout\npm: pr merge --squash\nq: !gh api graphql -f query="$1"\nmine: pr list --author @me\n' };
    for (const [args, exp] of [[['pm', '5'], 'pr merge --squash'], [['q', 'x'], '!gh api graphql -f query="$1"']]) {
      e.reset();
      const r = e.run(args, env);
      assert.deepEqual([r.code, r.stderr], [65, `gh-guard: alias ${args[0]} chạy '${exp}'; box không kiểm tra alias — gõ lệnh gh đầy đủ.\n`]);
      assert.deepEqual(e.calls(), ['alias list']);
    }
    for (const args of [['co', '5'], ['mine'], ['some-extension', 'merge']]) {
      e.reset();
      const r = e.run(args, env);
      assert.deepEqual([r.code, r.stdout, e.calls()], [0, `out:${args.join(' ')}\n`, ['alias list', args.join(' ')]], args.join(' '));
    }
  } finally { done(e); }
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
