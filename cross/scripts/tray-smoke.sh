#!/bin/sh
# Tray smoke test, run inside `dbus-run-session` (CI and containers):
#   dbus-run-session -- sh scripts/tray-smoke.sh target/debug
# Starts keepwatch-tray, checks it registers a StatusNotifierItem, clicks
# Keep awake > Until I turn it off through the dbusmenu interface, checks the
# CLI sees and stops that session, then sends SIGTERM and checks the
# inhibitor child is gone. Uses a stand-in systemd-inhibit (debug builds only).
set -eu
bin=${1:-target/debug}
work=$(mktemp -d)
chmod 700 "$work"
export XDG_RUNTIME_DIR="$work" XDG_CONFIG_HOME="$work/config" XDG_STATE_HOME="$work/state"
cat > "$work/systemd-inhibit" <<'SH'
#!/bin/sh
case "$1" in --list) exit 1;; esac
echo $$ >> "$XDG_RUNTIME_DIR/holders"
while [ $# -gt 0 ]; do case "$1" in --*) shift;; *) break;; esac; done
exec "$@"
SH
chmod 755 "$work/systemd-inhibit"
printf '#!/bin/sh\necho "$@" >> "$XDG_RUNTIME_DIR/systemctl-args"\n' > "$work/systemctl"
chmod 755 "$work/systemctl"
mkdir -p "$work/ps" "$work/thermal"
echo "state:      closed" > "$work/lid"
export KEEPWATCH_TEST_SYSTEMD_INHIBIT="$work/systemd-inhibit" KEEPWATCH_TEST_SYSTEMCTL="$work/systemctl" \
  KEEPWATCH_TEST_BUSCTL="$work/none" KEEPWATCH_TEST_LID_STATE="$work/lid" \
  KEEPWATCH_TEST_POWER_SUPPLY="$work/ps" KEEPWATCH_TEST_THERMAL="$work/thermal"
fail() { echo "FAIL: $*"; cat "$work/tray.err"; exit 1; }
alive() { [ -d "/proc/$1" ] && ! grep -q '^State:.*Z' "/proc/$1/status" 2>/dev/null; }

"$bin/keepwatch-tray" 2>"$work/tray.err" &
tray=$!
sleep 2
alive "$tray" || { cat "$work/tray.err"; fail "tray exited"; }
name=$(dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus \
  org.freedesktop.DBus.ListNames | grep -o "org.kde.StatusNotifierItem-$tray-[0-9]*" | head -1)
[ -n "$name" ] || fail "no org.kde.StatusNotifierItem-$tray-* on the bus"
echo "registered $name"

layout=$(dbus-send --session --print-reply --dest="$name" /MenuBar com.canonical.dbusmenu.GetLayout \
  int32:0 int32:-1 array:string:)
id=$(echo "$layout" | awk '/int32/ {id=$2} /"Until I turn it off"/ {print id; exit}')
[ -n "$id" ] || fail "no 'Until I turn it off' in the menu"
echo "clicking menu item $id"
dbus-send --session --type=method_call --print-reply=literal --dest="$name" /MenuBar com.canonical.dbusmenu.Event \
  int32:"$id" string:clicked variant:int32:0 uint32:0
sleep 3
[ -s "$work/holders" ] || fail "clicking didn't take an inhibitor"
holder=$(tail -1 "$work/holders")
alive "$holder" || fail "inhibitor not running"
[ -f "$work/keepwatch/awake.pid" ] || fail "no awake lock"
grep -q "^$tray " "$work/keepwatch/awake.pid" || fail "lock doesn't name the tray"
"$bin/keepwatch" status --json | grep -q '"keepwatchHolding": true' || fail "status doesn't see it"
echo "menu click holds awake (inhibitor pid $holder)"

"$bin/keepwatch" awake --off | grep -q "Stopped the tray's keep-awake" || fail "awake --off didn't stop it"
sleep 1
alive "$tray" || fail "awake --off killed the tray"
alive "$holder" && fail "inhibitor still held after awake --off"
[ -f "$work/keepwatch/awake.pid" ] && fail "lock left behind"
echo "keepwatch awake --off stopped the tray's session; tray still running"

lid_id=$(echo "$layout" | awk '/int32/ {id=$2} /"Start for 1 hour"/ {print id; exit}')
[ -n "$lid_id" ] || fail "no 'Start for 1 hour' in the menu"
dbus-send --session --type=method_call --print-reply=literal --dest="$name" /MenuBar com.canonical.dbusmenu.Event \
  int32:"$lid_id" string:clicked variant:int32:0 uint32:0
sleep 3
"$bin/keepwatch" lid status --json | grep -q '"owner": "tray"' || fail "lid status doesn't show the tray's session"
"$bin/keepwatch" lid end | grep -q "Ended the lid session" || fail "lid end didn't end it"
sleep 1
alive "$tray" || fail "lid end killed the tray"
grep -q suspend "$work/systemctl-args" || fail "lid closed at the end, but no suspend request"
grep -q " ended stop-requested: " "$work/state/keepwatch/lid.log" || fail "no log line"
echo "tray lid session: started from the menu, ended by 'keepwatch lid end', suspend requested"

dbus-send --session --type=method_call --print-reply=literal --dest="$name" /MenuBar com.canonical.dbusmenu.Event \
  int32:"$id" string:clicked variant:int32:0 uint32:0
sleep 3
holder=$(tail -1 "$work/holders")
alive "$holder" || fail "second click didn't hold"
kill -TERM "$tray"
for _ in 1 2 3 4 5 6 7 8 9 10; do alive "$tray" || break; sleep 0.5; done
alive "$tray" && fail "tray ignored SIGTERM"
sleep 1
alive "$holder" && fail "inhibitor survived SIGTERM"
echo "SIGTERM: tray exited and released the inhibitor"
rm -rf "$work"
echo "tray smoke test passed"
