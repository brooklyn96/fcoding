#!/bin/sh
# fcode-add (runs ON the coder box, installed as ~/.local/bin/fcode-add): runs the installed "add project" script under the server's own
# deadline, the same as the app's "Thêm dự án" does (server.mjs startAdd). It is the entry of the laptop's `fcode add` and the owner's manual one.
#   fcode-add <owner/repo> <name>
# The script is $FCODE_APP/fcode-add.sh (FCODE_APP defaults to /data/home/fcoding, the APP of install.sh; FCODE_ADD_SCRIPT overrides the script, for tests and the laptop).
# The deadline code is NOT a copy: it is ADD_WATCHDOG, read from the installed server.mjs, so the app and this CLI can never differ.
# `setsid` makes the watchdog the leader of its own process group, like the server's `detached: true`: its kill(0, ...) then reaches only the
# job's group, never the ssh session or the caller's shell. At the deadline (FCODE_ADD_TIMEOUT_S, default 600) the whole group gets TERM and,
# after FCODE_ADD_KILL_AFTER_S (default 30), KILL (uutils `timeout` KILLs its direct child only).
# Exit status: the job's own code when it ends on its own; 137 (the group KILL) when the deadline fired or a signal here ended it; 3 + "R NO_SCRIPT" on stdout when this box has
# no installed script or server (run `bash install.sh` from an up-to-date checkout). Never 124. Needs: node, setsid, bash. dash may print "Killed" on stderr after a group KILL; harmless.
app="${FCODE_APP:-/data/home/fcoding}"
s="${FCODE_ADD_SCRIPT:-$app/fcode-add.sh}"
[ -f "$s" ] && [ -f "$app/server.mjs" ] || { echo "R NO_SCRIPT"; exit 3; }
# a non-interactive ssh login PATH may lack node: append the server's tool dirs (server.mjs toolEnv: ~/.local/bin, ~/.bun/bin) and /usr/local/bin; nothing else is searched
PATH="$PATH:$HOME/.local/bin:$HOME/.bun/bin:/usr/local/bin"
# argv[1] is a placeholder: with -e, server.mjs's "run as main" check compares argv[1] with its own path, and must not match here
w=$(node --input-type=module -e 'const { pathToFileURL } = await import("node:url"); const { resolve } = await import("node:path");
const m = await import(pathToFileURL(resolve(process.argv[2])).href); process.stdout.write(m.ADD_WATCHDOG)' x "$app/server.mjs" 2>/dev/null)
[ -n "$w" ] || { echo "R NO_SCRIPT"; exit 3; }
t="${FCODE_ADD_TIMEOUT_S:-600}"
k="${FCODE_ADD_KILL_AFTER_S:-30}"
# same rule as the laptop's Get-FcodeAddLimitVars: 1 to 5 digits, no leading zero; anything else falls back to the default
case "$t" in [1-9] | [1-9][0-9] | [1-9][0-9][0-9] | [1-9][0-9][0-9][0-9] | [1-9][0-9][0-9][0-9][0-9]) ;; *) t=600 ;; esac
case "$k" in [1-9] | [1-9][0-9] | [1-9][0-9][0-9] | [1-9][0-9][0-9][0-9] | [1-9][0-9][0-9][0-9][0-9]) ;; *) k=30 ;; esac
# no `exec`: the caller (ssh's shell, or any group leader) is the leader of its group, and a setsid that is the leader forks and loses the code
# (the parent returns 0 at once; with -w a signal death comes back as 9). As a background child of this sh it is no leader, so it only calls
# setsid() and runs node in place; a KILLed watchdog is 137 here.
# INT / TERM / HUP (Ctrl-C, a hung-up terminal, a kill) go to the watchdog alone, like the server's TERM: it arms, TERMs the job's group and KILLs it at
# kill-after, so this CLI returns only after kill-after (up to 30 s) with 137. Without the trap the job would run on in its own session until the
# deadline. A dropped ssh without a tty sends no signal: the job then ends by itself or at the deadline, as before.
# The trap is set BEFORE the job starts: a signal in that window is recorded (sig=1) and forwarded right after `pid=$!`. The loop re-waits after a
# trapped signal (wait returns at once then) until the watchdog is really gone.
pid=; sig=
trap 'sig=1; [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null' INT TERM HUP
setsid node -e "$w" "${t}000" "${k}000" bash "$s" "$@" &
pid=$!
[ -z "$sig" ] || kill -TERM "$pid" 2>/dev/null
while :; do wait "$pid"; rc=$?; kill -0 "$pid" 2>/dev/null || break; done
exit "$rc"
