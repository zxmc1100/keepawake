#!/bin/zsh
# Runs the real guard script under launchd as a user agent, with pmset swapped for a recorder, to
# prove sleep is restored on close and on SIGKILL. Needs no root and touches no real power setting.
# Usage: test_guard.sh path/to/KeepAwake
set -u
BIN=${1:?path to KeepAwake binary}
WORK=$(mktemp -d)
LABEL=com.zxmc.keepawake.guardtest
PLIST=$WORK/$LABEL.plist
SOCK=$WORK/s
STATE=$WORK/state

cleanup() { launchctl bootout gui/$UID/$LABEL 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

cat > "$WORK/pmset" <<EOF
#!/bin/sh
[ "\$1" = "-a" ] && echo "\$3" > "$STATE"
EOF
chmod +x "$WORK/pmset"

# The real plist from the app, with only the label, socket path and pmset swapped.
launchctl bootout gui/$UID/$LABEL 2>/dev/null
"$BIN" --guard-plist | python3 -I -c '
import plistlib, sys
plist, label, pmset, sock = sys.argv[1:]
job = plistlib.loads(sys.stdin.buffer.read())
job["Label"] = label
job["ProgramArguments"][-1] = job["ProgramArguments"][-1].replace("/usr/bin/pmset", pmset)
job["Sockets"]["Listener"]["SockPathName"] = sock
plistlib.dump(job, open(plist, "wb"))
' "$PLIST" "$LABEL" "$WORK/pmset" "$SOCK"
launchctl bootstrap gui/$UID "$PLIST" || { echo "FAIL: launchd rejected plist"; exit 1; }

# Client: wait for the guard's ack, then hold the socket open until killed or told to exit.
CLIENT="
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
s.settimeout(10); assert s.recv(8) == b'ok\n'
print('ack', flush=True)
time.sleep(float(sys.argv[2]))
"
fail() { echo "FAIL: $1"; exit 1; }
state_is() { for _ in {1..50}; do [[ "$(cat "$STATE" 2>/dev/null)" == "$1" ]] && return 0; /bin/sleep 0.1; done; return 1; }

# Client exits normally: sleep disabled while held, restored on close.
python3 -I -c "$CLIENT" "$SOCK" 1 > /dev/null || fail "no ack"
state_is 0 || fail "sleep not restored after clean close"
echo "ok: restored on clean close"

# Client is SIGKILLed: the kernel closes the socket, guard must still restore.
FIFO=$WORK/ack; mkfifo "$FIFO"
python3 -I -c "$CLIENT" "$SOCK" 60 > "$FIFO" &
CLIENT_PID=$!
read -r _ < "$FIFO"
state_is 1 || fail "sleep not disabled while held"
GUARD_CPU=$(ps -axo pcpu,command | awk -v l="$WORK/pmset" 'index($0, l) && !/awk/ {s+=$1} END {print s+0}')
kill -9 $CLIENT_PID; wait $CLIENT_PID 2>/dev/null
state_is 0 || fail "sleep not restored after SIGKILL"
echo "ok: restored after SIGKILL (guard cpu while armed: ${GUARD_CPU}%)"

# Client gone before the ack is written: a dead peer must not kill the guard before it restores.
python3 -I -c "
import socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.close()
" "$SOCK"
state_is 0 || fail "sleep not restored when the client left before the ack"
/bin/sleep 0.5
state_is 0 || fail "sleep left disabled after an early disconnect"
echo "ok: restored when the client left before the ack"

# Guard gets SIGTERM while armed (launchctl bootout, shutdown): must restore, not die holding it.
FIFO2=$WORK/ack2; mkfifo "$FIFO2"
python3 -I -c "$CLIENT" "$SOCK" 60 > "$FIFO2" &
CLIENT_PID=$!
read -r _ < "$FIFO2"
state_is 1 || fail "sleep not disabled while held (SIGTERM case)"
pkill -TERM -f "^/bin/sh -c trap .*$WORK/pmset" || fail "guard process not found"
state_is 0 || fail "sleep not restored after SIGTERM"
kill -9 $CLIENT_PID 2>/dev/null; wait $CLIENT_PID 2>/dev/null
echo "ok: restored after SIGTERM"

# The socket must be private to this user.
[[ "$(stat -f %Lp "$SOCK")" == 600 ]] || fail "socket mode $(stat -f %Lp "$SOCK"), expected 600"
echo "ok: socket mode 600"
echo "guard test ok"
