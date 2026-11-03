#!/usr/bin/env python3
# Gia lap `ssh` de thu fcode phien tren may: "box" la chinh may nay (chuong trinh python cua box chay cuc bo, HOME/cau hinh
# lay tu FCODE_PHIEN_BOXENV). Dang goi: ssh [tuy chon] <host> <lenh>. stdin/stdout di qua day toi chuong trinh (nhi phan), nhu ssh that.
# Lenh `true` = kiem tra vao duoc box (fcode: `ssh -o BatchMode=yes -o ConnectTimeout=8 <host> true`): thoat 0, khong ghi nhat ky.
# Che do thu (env):
#   FAKE_DOWN=1                       box khong vao duoc: moi lenh thoat 255 ngay (nhu mang dut / box tat)
#   FAKE_SSH_FAIL=1                   moi ssh (tru kiem tra `true`) loi ngay
#   FAKE_SSH_FAIL_AFTER=<n>           ssh loi tu lan thu n+1
#   FAKE_SSH_CUT=<lenh>:<lan>:<byte>:<kieu>   lan goi thu <lan> (hoac * = moi lan) cua <lenh> (put|get|scan|hash|projects): sau <byte> byte (put: stdin, cac lenh khac: stdout)
#   ssh voi script base64 (Invoke-BoxScript: fcode add / pair): chay script bang bash cua Git for Windows
#                                     kieu cut = cat ngang va loi; stall = dung han (khong doc / khong gui nua, cho toi 60 s);
#                                     fail = khong chay chuong trinh, thoat 1 (loi o box, khong phai mat ket noi)
#                                     noack = (put) cho chay het roi nuot cau tra loi va bao loi (mat xac nhan)
#   FAKE_SSH_LOG=<file>               moi lan ssh mot dong "ssh <lenh>"; <file>.bytes: "<lenh> <byte vao> <byte ra>"
#   FAKE_ARGV_LOG=<file>              moi lan goi mot dong "<tuy chon> <host> <true|CMD>" (de thu cach fcode goi ssh)
import base64, json, os, re, subprocess, sys, tempfile, threading, time

# <tuy chon> <host> <lenh>: `-o X` co gia tri, cac tuy chon khac (-q -tt ...) khong
argv = sys.argv[1:]
opts, i = [], 0
while i < len(argv) and argv[i].startswith('-') and argv[i] != '--':
    if argv[i] == '-o' and i + 1 < len(argv):
        opts += argv[i:i + 2]
        i += 2
    else:
        opts.append(argv[i])
        i += 1
if i < len(argv) and argv[i] == '--':
    i += 1
host = argv[i] if i < len(argv) else ''
remote = ' '.join(argv[i + 1:])
if os.environ.get('FAKE_ARGV_LOG'):
    with open(os.environ['FAKE_ARGV_LOG'], 'a') as f:
        f.write(' '.join(opts + [host, 'true' if remote == 'true' else 'CMD']) + '\n')
if os.environ.get('FAKE_DOWN'):
    sys.stderr.write('ssh: connect to host ' + host + ' port 22: Connection timed out\n')
    sys.exit(255)
if remote == 'true':
    sys.exit(0)
if os.environ.get('FAKE_SSH_FAIL'):
    sys.stderr.write('fake-ssh: ssh failed\n')
    sys.exit(255)
if 'base64 -di' in remote:
    # Invoke-BoxScript (fcode add / pair): script base64 qua stdin; chay bang bash cua Git for Windows (khong phai bash cua WSL)
    log = os.environ.get('FAKE_SSH_LOG')
    if log:
        with open(log, 'a') as f:
            f.write('ssh script\n')
    data = base64.b64decode(sys.stdin.buffer.read())
    gx = subprocess.run(['git', '--exec-path'], stdout=subprocess.PIPE).stdout.decode().strip()
    bash = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(gx))), 'bin', 'bash.exe')
    fd, sp = tempfile.mkstemp(suffix='.sh')
    with os.fdopen(fd, 'wb') as f:
        f.write(data)
    try:
        # like the real remote command (bash -l $f; rc=$?): an outer bash turns a death by signal into 128+n (e.g. 137)
        rc = subprocess.call([bash, '-c', 'bash "$1"; exit $?', 'x', sp], stdin=subprocess.DEVNULL)
    finally:
        os.unlink(sp)
    sys.exit(rc)
m = re.match(r"^(?:env (.*?) )?python3 -c '(.*)' (\w+)$", remote)
if not m:
    sys.stderr.write('fake-ssh: lenh la\n')
    sys.exit(2)
cmd = m.group(3)
log = os.environ.get('FAKE_SSH_LOG')
prev = open(log).read().splitlines() if log and os.path.exists(log) else []
after = os.environ.get('FAKE_SSH_FAIL_AFTER')
if after and len(prev) >= int(after):
    sys.stderr.write('fake-ssh: ssh failed (after n calls)\n')
    sys.exit(255)
if log:
    with open(log, 'a') as f:
        f.write('ssh ' + cmd + '\n')
nth = sum(1 for x in prev if x == 'ssh ' + cmd) + 1
mode, limit = '', -1
cut = os.environ.get('FAKE_SSH_CUT', '').split(':')
if len(cut) == 4 and cut[0] == cmd and (cut[1] == '*' or int(cut[1]) == nth):
    limit, mode = int(cut[2]), cut[3]
if mode == 'fail':
    sys.stdin.buffer.read()
    sys.stderr.write('fake-ssh: box program failed\n')
    sys.exit(1)
env = os.environ.copy()
for kv in (m.group(1) or '').split():
    k, v = kv.split('=', 1)
    env[k] = v
p = subprocess.Popen([sys.executable, '-c', m.group(2), cmd], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
sin, sout = sys.stdin.buffer, sys.stdout.buffer
n = [0, 0]
hit = [False]

def pump_in():
    try:
        while True:
            want = 1 << 16
            if cmd == 'put' and mode in ('cut', 'stall'):
                want = min(want, limit - n[0])
                if want <= 0:
                    hit[0] = True
                    if mode == 'stall':
                        time.sleep(60)
                    break
            b = sin.read1(want) if hasattr(sin, 'read1') else sin.read(want)
            if not b:
                break
            n[0] += len(b)
            p.stdin.write(b)
    except OSError:
        pass
    try:
        p.stdin.close()
    except OSError:
        pass
t = threading.Thread(target=pump_in, daemon=True)
t.start()
rc = None
try:
    while True:
        want = 1 << 16
        if cmd != 'put' and mode in ('cut', 'stall'):   # get, scan, hash, projects: cut the answer
            want = min(want, limit - n[1])
            if want <= 0:
                if mode == 'stall':
                    time.sleep(60)
                p.kill()
                rc = 255
                break
        b = p.stdout.read1(want)
        if not b:
            break
        n[1] += len(b)
        if mode != 'noack':
            sout.write(b)
            sout.flush()
except OSError:
    rc = 255
if cmd == 'put' and mode in ('cut', 'stall'):
    t.join()
    if hit[0]:
        rc = 255
code = p.wait()
if log:
    with open(log + '.bytes', 'a') as f:
        f.write('%s %d %d\n' % (cmd, n[0], n[1]))
sys.exit(255 if mode == 'noack' else (rc if rc is not None else code))
