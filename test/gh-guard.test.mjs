// box/gh-guard.sh (the box's ~/.local/bin/gh) run for real with bash, in front of a stub "real gh" (FCODE_GH_REAL) that logs its argv.
// Run on Linux (the box): `node --test test/gh-guard.test.mjs`. Skipped where bash or git is missing (Windows).
// Test groups 3a-3e are the matrix of /tmp/ai-work/fcoding/wf-guard/DECISION-r2.md, REWORK item 3.
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

// the stub: logs argv (one line per call). "pr view" prints STUB_PR (unset: "no such PR", exit 1); REST pulls/<n>/files prints STUB_FILES
// (STUB_FILES_FAIL: HTTP 502); "auth git-credential get" answers a credential; anything else prints out:/err: lines (and in:<its stdin> when
// STUB_CAT is set) and exits STUB_RC
const STUB = `#!/bin/bash
printf '%s\\n' "$*" >>"$STUB_LOG"
case "$*" in
  "pr view"*) [ -n "\${STUB_PR:-}" ] || { echo "no such PR" >&2; exit 1; }; printf '%s\\n' "$STUB_PR"; exit 0;;
  "api --paginate repos/"*/pulls/*/files" -q "*) [ -z "\${STUB_FILES_FAIL:-}" ] || { echo 'gh: Server Error (HTTP 502)' >&2; exit 1; }; printf '%s' "\${STUB_FILES:-}"; exit 0;;
  "auth git-credential get") cat >/dev/null; printf 'protocol=https\\nhost=github.com\\nusername=x-access-token\\npassword=TOKEN-FROM-GH\\n'; exit 0;;
esac
[ -z "\${STUB_CAT:-}" ] || { printf 'in:'; cat; }
echo "out:$*"; echo "err:$*" >&2; exit "\${STUB_RC:-0}"
`;
const H = 'a1'.repeat(20); // the PR head the guard inspects
const H2 = 'b2'.repeat(20);
const HINT = '(trợ giúp: gh help pr merge)';
const NO_SECRET_LINE = String.raw`no_secret() { nsf=$HOME/.config/fcode/no-secret-repos; [ -f "$nsf" ] && [ -r "$nsf" ] && [ "$(wc -c <"$nsf")" -eq "$(tr -d '\000' <"$nsf" | wc -c)" ] && sed 's/#.*//; s/[[:space:]]//g' "$nsf" | grep -qixF -- "$1"; }`;
const MSG = (n, url = `https://github.com/o/r/pull/${n}`, head = H) =>
  `gh-guard: PR #${n} sửa .github/ ở repo không có trong ~/.config/fcode/no-secret-repos (head ${head}); box không merge — gọi fcode-notify <dự án> merge-ready "<một dòng>" ${url}, chủ merge trên GitHub.\n`;
const API_MSG = (m, ep) => `gh-guard: gh api ${m} ${ep} bị chặn trên box (chỉ lệnh đọc GET đi qua); dùng lệnh gh tương ứng (gh pr / issue / release / workflow …) — báo fcoding nếu thật cần.\n`;
const CMD_MSG = (w) => `gh-guard: '${w}' không chạy được trên box (không phải tên lệnh gh đầy đủ; alias, extension và tên tắt đều bị chặn) — gõ lệnh gh đầy đủ.\n`;
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
  e.list = (text) => { const f = path.join(e.home, '.config', 'fcode', 'no-secret-repos'); fs.mkdirSync(path.dirname(f), { recursive: true }); if (text === undefined) fs.rmSync(f, { force: true }); else fs.writeFileSync(f, text); };
  return e;
}
const done = (e) => fs.rmSync(e.root, { recursive: true, force: true });
const noMerge = (e, what) => assert.ok(!e.calls().some((c) => c.startsWith('pr merge')), what);

test('gh-guard: syntax is valid bash, LF only', { skip }, () => {
  const r = spawnSync('bash', ['-n', GUARD], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  assert.ok(!fs.readFileSync(GUARD, 'latin1').includes('\r'));
});

test('gh-guard 3e: the no_secret() line is the same text in the guard and in the pre-push hook', { skip }, () => {
  const line = (t) => { const l = t.split('\n').filter((x) => x.startsWith('no_secret() ')); assert.equal(l.length, 1); return l[0]; };
  const hook = spawnSync('bash', [ADD, '--hook-text'], { encoding: 'utf8' }).stdout;
  assert.equal(line(fs.readFileSync(GUARD, 'utf8')), NO_SECRET_LINE);
  assert.equal(line(hook), NO_SECRET_LINE);
});

test('gh-guard 3a: every other call is passed through unchanged (argv, stdin, stdout, stderr, exit code) with no lookup, listed or not', { skip }, () => {
  const e = world();
  try {
    for (const list of [undefined, 'o/r\n']) {
      e.list(list);
      for (const [args, rc] of [[['repo', 'list', '--limit', '5'], 0], [['run', 'view', '42', '--log'], 3], [['workflow', 'run', 'deploy.yml', '--ref', 'box/x', '-f', 'action=deploy'], 0],
        [['pr', 'create', '--base', 'main', '--fill'], 1], [['pr', 'list', '--state', 'merged'], 0], [['--', 'pr', 'list'], 0], [['release', 'create', 'v1', '--notes', 'x'], 0],
        [['release', 'upload', 'v1', 'a.ipa'], 0], [['--version'], 0], [['api', 'repos/o/r/contents/.github/workflows/ci.yml'], 0], [['api', 'repos/o/r/git/refs/heads/main'], 0],
        [['api', 'repos/o/r/pulls/5/merge'], 1], [['api', 'repos/o/r/commits/HEAD', '--jq', '.sha'], 0], [['api', 'repos/o/r/contents/.fcode/deploy.json?ref=abc', '--silent'], 0],
        [['api', 'repos/o/r/commits/abc/statuses?per_page=100', '--paginate', '--jq', '.[] | [.context, .description, .created_at, .target_url] | @json'], 0],
        [['api', '/user/repos?affiliation=owner,collaborator&sort=updated&per_page=100&page=1', '--jq', '.[] | @json'], 0], [['api', '-X', 'GET', 'search/issues', '-f', 'q=x'], 0],
        [['api', '-X', 'get', 'search/issues', '-f', 'q=x'], 0], [['api', 'repos/o/r/contents/docs/a%20b.md'], 0], [['api', 'repos/{owner}/{repo}/pulls', '--paginate', '--silent'], 0],
        [['api', '%72epos/o/r/contents/x'], 0]]) {
        e.reset();
        const r = e.run(args, { STUB_RC: String(rc) });
        const line = args.join(' ');
        assert.deepEqual([r.code, r.stdout, r.stderr], [rc, `out:${line}\n`, `err:${line}\n`], line);
        assert.deepEqual(e.calls(), [line], line); // one call, no lookup of its own
      }
    }
    const r = e.run(['issue', 'create', '--body-file', '-'], { STUB_CAT: '1' }, { input: 'line 1\nline 2\n' });
    assert.deepEqual([r.code, r.stdout], [0, 'in:line 1\nline 2\nout:issue create --body-file -\n']);
  } finally { done(e); }
});

test('gh-guard 3a: git push through `credential.helper=!gh auth git-credential` still gets the credential from the real gh', { skip }, () => {
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

test('gh-guard 3b: gh extension, gh alias, gh\'s short names and any alias or extension name are refused; gh is never called', { skip }, () => {
  const e = world();
  try {
    e.list('o/r\n');
    for (const args of [['extension', 'exec', 'x'], ['extension', 'list'], ['extension', 'install', 'owner/gh-x'], ['ext'], ['alias', 'set', 'p', 'pr'], ['p', 'merge', '5'],
      ['co', '5'], ['some-extension', 'merge'], ['-R', 'o/r', 'pm', '5']]) {
      e.reset();
      const r = e.run(args);
      const first = args[0] === '-R' ? 'pm' : args[0];
      assert.deepEqual([r.code, r.stdout, r.stderr], [65, '', CMD_MSG(first)], args.join(' '));
      assert.deepEqual(e.calls(), [], args.join(' '));
    }
  } finally { done(e); }
});

test('gh-guard 3c: pr merge in a listed repo (any case, # comments) runs exactly as given after one lookup: no file list, no pin, --auto and .github included', { skip }, () => {
  const e = world();
  try {
    e.list('# repos whose Actions secrets page the owner saw empty\nother/x\n  O/R  # this one\n');
    for (const args of [['pr', 'merge', '5', '-R', 'o/r', '--auto', '--squash'], ['pr', 'merge', '5', '-R', 'o/r'], ['pr', 'merge', '5', '-R', 'o/r', '--match-head-commit', H2]]) {
      e.reset();
      const r = e.run(args, { STUB_PR: PR(5, 'o/r', 1), STUB_FILES: FILES('.github/workflows/ci.yml') });
      assert.deepEqual([r.code, r.stdout], [0, `out:${args.join(' ')}\n`], args.join(' '));
      assert.equal(e.calls().length, 2, args.join(' '));
      assert.match(e.calls()[0], /^pr view 5 -R o\/r --json number,url,headRefOid,changedFiles /);
      assert.equal(e.calls()[1], args.join(' '));
    }
    // listed under another slug: o/r is judged as unlisted
    e.list('o/r2\nx/o/r\n');
    const r = e.run(['pr', 'merge', '5', '-R', 'o/r'], { STUB_PR: PR(5, 'o/r', 1), STUB_FILES: FILES('.github/workflows/ci.yml') });
    assert.deepEqual([r.code, r.stderr], [65, MSG(5)]);
    // astra r4: a malformed list allows nothing (grep would split lines at a NUL); a list that is not a readable regular file neither
    const listFile = path.join(e.home, '.config', 'fcode', 'no-secret-repos');
    const bad = [['NUL', () => e.list('other/repo\0o/r\n')], ['NUL beside a valid line', () => e.list('other/repo\0\nO/R\n')],
      ['directory', () => { e.list(undefined); fs.mkdirSync(listFile); }]];
    if (process.getuid?.() !== 0) bad.push(['unreadable', () => { fs.rmSync(listFile, { recursive: true, force: true }); e.list('o/r\n'); fs.chmodSync(listFile, 0); }]);
    for (const [what, make] of bad) {
      make();
      e.reset();
      const m = e.run(['pr', 'merge', '5', '-R', 'o/r'], { STUB_PR: PR(5, 'o/r', 1), STUB_FILES: FILES('.github/workflows/ci.yml') });
      assert.deepEqual([m.code, m.stderr], [65, MSG(5)], what);
      noMerge(e, what);
    }
    fs.rmSync(listFile, { recursive: true, force: true });
    e.list('other/repo\no/r\n'); // the same bytes without the NUL: listed
    e.reset();
    const ok = e.run(['pr', 'merge', '5', '-R', 'o/r'], { STUB_PR: PR(5, 'o/r', 1), STUB_FILES: FILES('.github/workflows/ci.yml') });
    assert.deepEqual([ok.code, e.calls().at(-1)], [0, 'pr merge 5 -R o/r']);
  } finally { done(e); }
});

// the 7 flag orders (the URL selector among them) and the -- forms; what the guard forwards when the PR touches no .github/
const ORDERS = [[['pr', 'merge', '5', '--squash', '-R', 'o/r']], [['-R', 'o/r', 'pr', 'merge', '5']], [['pr', 'merge', '--squash', '--subject', 'a b', '5', '--repo=o/r']],
  [['pr', 'merge', '-dR', 'o/r', '5']], [['pr', 'merge', '-Ro/r', '-s', '5']], [['pr', 'merge', 'https://github.com/o/r/pull/5', '--merge']],
  [['pr', 'merge', '--body', '--help', '5', '-R', 'o/r']],
  [['pr', 'merge', '--squash', '-R', 'o/r', '--', '5'], `pr merge --squash -R o/r --match-head-commit ${H} -- 5`],
  [['pr', 'merge', '5', '-R', 'o/r', '--body', '--', '-s'], `pr merge 5 -R o/r --body -- -s --match-head-commit ${H}`],
  [['pr', 'merge', '5', '-R', 'o/r', `--match-head-commit=${H}`], `pr merge 5 -R o/r --match-head-commit=${H}`]];

test('gh-guard 3c: pr merge in an unlisted repo (or with no list file) without .github/ runs pinned to the inspected head, in every flag order', { skip }, () => {
  const e = world();
  try {
    for (const list of [undefined, 'other/x\n']) {
      e.list(list);
      for (const [args, fwd = `${args.join(' ')} --match-head-commit ${H}`] of ORDERS) {
        e.reset();
        const r = e.run(args, { STUB_PR: PR(5, 'o/r', 2), STUB_FILES: FILES('src/a.js', 'docs/.github-notes.md'), STUB_CAT: '1' }, { input: 'stdin body' });
        assert.deepEqual([r.code, r.stdout, e.calls().at(-1)], [0, `in:stdin bodyout:${fwd}\n`, fwd], args.join(' '));
        assert.ok(e.calls().includes(GH_FILES(5)), args.join(' ')); // the REST file list
      }
    }
    // the selector and -R reach gh pr view as given; the current branch's PR when there is no selector
    e.reset(); e.run(['pr', 'merge', '--squash', '5', '-R', 'o/r'], { STUB_PR: PR(5), STUB_FILES: FILES('a.js') });
    assert.match(e.calls()[0], /^pr view 5 -R o\/r --json number,url,headRefOid,changedFiles /);
    e.reset(); e.run(['pr', 'merge', '--squash'], { STUB_PR: PR(5), STUB_FILES: FILES('a.js') });
    assert.match(e.calls()[0], /^pr view --json /);
  } finally { done(e); }
});

test('gh-guard 3c: pr merge in an unlisted repo of a PR touching .github/ (renames, any case, short or unreadable list) is refused (65), even with an approval file; the merge never runs', { skip }, () => {
  const e = world();
  try {
    const dir = path.join(e.home, '.config', 'fcode', 'guard-allow'); fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, `o__r__${H}`), 'owner said yes\n', { mode: 0o600 }); // no approval on the merge side
    for (const [args] of ORDERS) {
      e.reset();
      const r = e.run(args, { STUB_PR: PR(5, 'o/r', 2), STUB_FILES: FILES('src/a.js', '.github/workflows/deploy.yml') });
      assert.deepEqual([r.code, r.stdout, r.stderr], [65, '', MSG(5)], args.join(' '));
      noMerge(e, args.join(' '));
    }
    for (const [what, env] of [['previous_filename', { STUB_PR: PR(5, 'o/r', 1), STUB_FILES: FILES(['retired-deploy.yml', '.github/workflows/deploy.yml']) }],
      ['case', { STUB_PR: PR(5, 'o/r', 1), STUB_FILES: FILES(['.GitHub/x.yml', 'src/x.yml']) }], ['the folder itself', { STUB_PR: PR(5, 'o/r', 1), STUB_FILES: FILES('.github') }],
      ['short list', { STUB_PR: PR(5, 'o/r', 3), STUB_FILES: FILES('a.js', 'b.js') }], ['files API failure', { STUB_PR: PR(5, 'o/r', 1), STUB_FILES_FAIL: '1' }],
      ['files API failure, changedFiles 0', { STUB_PR: PR(5, 'o/r', 0), STUB_FILES_FAIL: '1' }]]) {
      e.reset();
      const r = e.run(['pr', 'merge', '5', '-R', 'o/r'], env);
      assert.deepEqual([r.code, r.stderr], [65, MSG(5)], what);
      noMerge(e, what);
    }
    assert.ok(fs.existsSync(path.join(dir, `o__r__${H}`)), 'the guard never touches the file');
  } finally { done(e); }
});

test('gh-guard 3c: in an unlisted repo --auto / --disable-auto and another --match-head-commit are refused; every pr-merge refusal but the .github one names gh help pr merge', { skip }, () => {
  const e = world();
  try {
    const env = { STUB_PR: PR(5, 'o/r', 1), STUB_FILES: FILES('src/a.js') };
    for (const a of ['--auto', '--auto=false', '--disable-auto']) {
      e.reset();
      const r = e.run(['pr', 'merge', '5', '-R', 'o/r', a], env);
      assert.deepEqual([r.code, r.stderr], [65, `gh-guard: PR #5: auto-merge ở repo không có trong ~/.config/fcode/no-secret-repos bị chặn (box chỉ kiểm tra được lần merge chạy ngay); merge không --auto. ${HINT}\n`], a);
      noMerge(e, a);
    }
    e.reset();
    let r = e.run(['pr', 'merge', '5', '-R', 'o/r', '--match-head-commit', H2], env);
    assert.deepEqual([r.code, r.stderr], [65, `gh-guard: PR #5: --match-head-commit ${H2} khác head đã kiểm tra ${H}; bị chặn. ${HINT}\n`]);
    noMerge(e, 'other head');
    // pr view fails (no PR for this branch): --help is judged as a run, and the message says how to read the help
    for (const args of [['pr', 'merge', '--help'], ['pr', 'merge', '9', '-R', 'o/r']]) {
      e.reset();
      r = e.run(args);
      assert.equal(r.code, 65, args.join(' '));
      assert.match(r.stderr, /^gh-guard: không đọc được PR (9|của nhánh này); không merge/, args.join(' '));
      assert.ok(r.stderr.endsWith(`${HINT}\n`), args.join(' '));
      noMerge(e, args.join(' '));
    }
    // --help on a .github PR: judged as a run
    for (const args of [['pr', 'merge', '5', '--squash', '--help', '--help=false', '-R', 'o/r'], ['pr', 'merge', '5', '--help', '-R', 'o/r']]) {
      e.reset();
      r = e.run(args, { STUB_PR: PR(5, 'o/r', 1), STUB_FILES: FILES('.github/workflows/deploy.yml') });
      assert.deepEqual([r.code, r.stderr], [65, MSG(5)], args.join(' '));
      noMerge(e, args.join(' '));
    }
    // an unreadable PR answer
    for (const pr of [['5', 'https://github.com/o/r/pull/5', 'abc', '1'].join('\n'), ['5', 'https://github.com/o/r/pull/6', H, '1'].join('\n'), ['5', 'https://github.com/o/r?x/pull/5', H, '1'].join('\n')]) {
      r = e.run(['pr', 'merge', '5', '-R', 'o/r'], { STUB_PR: pr, STUB_FILES: FILES('a.js') });
      assert.equal(r.code, 65, pr); assert.match(r.stderr, /^gh-guard: không đọc rõ PR 5/, pr);
      assert.ok(r.stderr.endsWith(`${HINT}\n`), pr);
    }
  } finally { done(e); }
});

test('gh-guard 3c: flags are read like gh (pflag): -R=o/r, --repo=o/r, -dR=o/r, -d=true; an unknown flag, a missing value or an extra argument is refused before any call', { skip }, () => {
  const e = world();
  try {
    const env = { STUB_PR: PR(5, 'o/r', 1), STUB_FILES: FILES('.github/workflows/d.yml') };
    for (const args of [['pr', 'merge', '-R=o/r', '5'], ['pr', 'merge', '--repo=o/r', '5'], ['pr', 'merge', '-dR=o/r', '5'], ['pr', 'merge', '-d=true', '-R', 'o/r', '5']]) {
      e.reset();
      const r = e.run(args, env);
      assert.deepEqual([r.code, r.stderr], [65, MSG(5)], args.join(' '));
      assert.match(e.calls()[0], /^pr view 5 -R o\/r --json /, args.join(' '));
    }
    for (const args of [['pr', 'merge', '5', '--squash', '--foo'], ['pr', 'merge', '5', '-R'], ['pr', 'merge', '5', '6'], ['pr', 'merge', '5', '-x'], ['pr', 'merge', '5', '-H', 'x']]) {
      e.reset();
      const r = e.run(args, env);
      assert.deepEqual([r.code, r.stderr], [65, `gh-guard: không đọc chắc lệnh gh pr merge này (cờ lạ, thiếu giá trị hay thừa đối số); bị chặn — gõ lại đúng cú pháp gh. ${HINT}\n`], args.join(' '));
      assert.deepEqual(e.calls(), [], args.join(' '));
    }
  } finally { done(e); }
});

test('gh-guard 3d: every gh api call that is not GET is refused in every repo, listed or not, before any call', { skip }, () => {
  const e = world();
  try {
    fs.writeFileSync(path.join(e.cwd, 'f'), '{}');
    for (const list of [undefined, 'o/r\n']) {
      e.list(list);
      for (const [args, m, ep] of [[['api', '-X', 'POST', 'repos/o/r/issues'], 'POST', 'repos/o/r/issues'], [['api', '-X', 'PUT', 'repos/o/r/pulls/5/merge'], 'PUT', 'repos/o/r/pulls/5/merge'],
        [['api', '-X', 'PATCH', 'repos/o/r/git/refs/heads/x', '-F', 'force=true'], 'PATCH', 'repos/o/r/git/refs/heads/x'], [['api', '-X', 'DELETE', 'repos/o/r/git/refs/heads/x'], 'DELETE', 'repos/o/r/git/refs/heads/x'],
        [['api', '-X=put', 'repos/o/r/contents/.github/workflows/x.yml', '--input', 'f'], 'PUT', 'repos/o/r/contents/.github/workflows/x.yml'], [['api', '-XPOST', 'repos/o/r/issues'], 'POST', 'repos/o/r/issues'],
        [['api', '--method=Delete', '/repos/o/r/actions/secrets/K'], 'DELETE', '/repos/o/r/actions/secrets/K'], [['api', 'repos/o/r/issues', '-f', 'k=v'], 'POST', 'repos/o/r/issues'],
        [['api', 'repos/o/r/issues', '-F', 'k=@f'], 'POST', 'repos/o/r/issues'], [['api', 'repos/o/r/contents/x', '--input', 'f'], 'POST', 'repos/o/r/contents/x'],
        [['api', '%72epos/o/r/contents/x', '-X', 'PUT'], 'PUT', '%72epos/o/r/contents/x'], [['api', '-X', '', 'user'], '', 'user']]) {
        e.reset();
        const r = e.run(args, { STUB_CAT: '1' }, { input: 'body' });
        assert.deepEqual([r.code, r.stdout, r.stderr], [65, '', API_MSG(m, ep)], `${list} ${args.join(' ')}`);
        assert.deepEqual(e.calls(), [], args.join(' '));
      }
    }
    // --method get is a read: forwarded unchanged
    e.reset();
    const r = e.run(['api', '--method', 'get', 'repos/o/r/contents/x']);
    assert.deepEqual([r.code, e.calls()], [0, ['api --method get repos/o/r/contents/x']]);
  } finally { done(e); }
});

test('gh-guard 3d: every gh api graphql call is refused (any spelling, with or without -X GET); unknown flags, missing values and extra arguments are refused; no call made', { skip }, () => {
  const e = world();
  try {
    e.list('o/r\n');
    fs.writeFileSync(path.join(e.cwd, 'body.json'), '{"query":"mutation { \\u006dergePullRequest(input: {pullRequestId: \\"PR_x\\"}) { clientMutationId } }"}');
    for (const args of [['api', 'graphql', '--input', 'body.json'], ['api', 'graphql', '-f', 'query=query { viewer { login } }'], ['api', 'GraphQL', '-f', 'query=x'],
      ['api', '/graphql', '-f', 'query=x'], ['api', 'https://api.github.com/graphql', '-f', 'query=x'], ['api', '-X', 'GET', 'graphql', '-f', 'query=x'],
      ['api', '-X', 'GET', 'https://api.github.com/graphql'], ['api', 'graphql', '--paginate'], ['api', 'graphql', '--help', '-f', 'query=mutation { x }']]) {
      e.reset();
      const r = e.run(args);
      assert.deepEqual([r.code, r.stdout], [65, ''], args.join(' '));
      assert.match(r.stderr, /^gh-guard: gh api graphql bị chặn trên box/, args.join(' '));
      assert.deepEqual(e.calls(), [], args.join(' '));
    }
    for (const args of [['api', '-Z', 'user'], ['api', 'user', 'extra'], ['api', 'repos/o/r', '--method'], ['api', '-R', 'o/r', 'user'], ['api']]) {
      e.reset();
      const r = e.run(args);
      assert.equal(r.code, 65, args.join(' ')); assert.match(r.stderr, /^gh-guard: không đọc chắc lệnh gh api này/, args.join(' '));
      assert.deepEqual(e.calls(), [], args.join(' '));
    }
  } finally { done(e); }
});

test('gh-guard 3e: never calls itself: a real gh that is this script (or a link to it) or missing ends at once with 127', { skip }, () => {
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
