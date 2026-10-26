#!/usr/bin/env python3
# Gia lap `instabox` de thu fcode phien tren may: "box" la chinh may nay (chuong trinh python cua box chay cuc bo, HOME/cau hinh
# lay tu FCODE_PHIEN_BOXENV). Lenh: wake | ls --json | ssh <box> -- <lenh>. Trang thai box doc tu FAKE_BOX_STATE (mac dinh running).
# stdin/stdout cua ssh di thang vao chuong trinh (nhi phan), nhu instabox that.
import json, os, re, subprocess, sys

a = sys.argv[1:]
if a and a[0] == 'wake':
    print('coder: running')
    sys.exit(0)
if a and a[0] == 'ls':
    print(json.dumps([{'name': 'coder', 'state': os.environ.get('FAKE_BOX_STATE', 'running')}]))
    sys.exit(0)
if a and a[0] == 'ssh':
    if os.environ.get('FAKE_SSH_FAIL'):
        sys.stderr.write('fake-instabox: ssh failed\n')
        sys.exit(255)
    log = os.environ.get('FAKE_SSH_LOG')
    if log:
        with open(log, 'a') as f:
            f.write('ssh\n')
    m = re.match(r"^(?:env (.*?) )?python3 -c '(.*)' (\S+) (\w+)$", a[-1])
    if not m:
        sys.stderr.write('fake-instabox: lenh la\n')
        sys.exit(2)
    env = os.environ.copy()
    for kv in (m.group(1) or '').split():
        k, v = kv.split('=', 1)
        env[k] = v
    sys.exit(subprocess.run([sys.executable, '-c', m.group(2), m.group(3), m.group(4)], env=env).returncode)
sys.exit(2)

