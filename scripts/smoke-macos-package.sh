#!/bin/sh
set -eu

PACKAGE_DIR=${1:?Pass the unpacked portable package or .app directory}
case "$PACKAGE_DIR" in
  *.app)
    BIN="$PACKAGE_DIR/Contents/Resources/backend/bin/dj4ghub-macos"
    LIBUSB="$PACKAGE_DIR/Contents/Resources/backend/lib/libusb-1.0.0.dylib"
    ENTRY="$PACKAGE_DIR/Contents/MacOS/DJ4Hub"
    PORT=7578
    ;;
  *)
    BIN="$PACKAGE_DIR/bin/dj4ghub-macos"
    LIBUSB="$PACKAGE_DIR/lib/libusb-1.0.0.dylib"
    ENTRY="$PACKAGE_DIR/dj4ghub"
    PORT=7575
    ;;
esac

test -x "$BIN"
test -x "$ENTRY"
test -f "$LIBUSB"
if /usr/sbin/lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Smoke test requires unused port $PORT; no existing service was stopped." >&2
  exit 1
fi

python3 - "$BIN" "$LIBUSB" <<'PY'
import re
import subprocess
import sys

for path in sys.argv[1:]:
    architecture = subprocess.check_output(['lipo', '-archs', path], text=True).strip()
    expected = subprocess.check_output(['uname', '-m'], text=True).strip()
    if architecture != expected:
        raise SystemExit(f'{path}: expected {expected}, got {architecture}')
    commands = subprocess.check_output(['otool', '-l', path], text=True)
    minimums = re.findall(r'^\s+minos (\d+(?:\.\d+)*)', commands, re.M)
    if not minimums or any(tuple(map(int, value.split('.')[:2])) > (13, 0) for value in minimums):
        raise SystemExit(f'{path}: expected minimum macOS <= 13.0, got {minimums}')
    dependencies = subprocess.check_output(['otool', '-L', path], text=True)
    if re.search(r'/opt/homebrew|/usr/local|/Cellar/', '\n'.join(dependencies.splitlines()[1:])):
        raise SystemExit(f'{path}: contains a package-manager dependency')
    subprocess.run(['codesign', '--verify', '--strict', path], check=True)
PY

case "$PACKAGE_DIR" in
  *.app)
    python3 - "$ENTRY" "$PACKAGE_DIR/Contents/Info.plist" <<'PY'
import plistlib
import re
import subprocess
import sys

binary, plist = sys.argv[1:]
with open(plist, 'rb') as stream:
    info = plistlib.load(stream)
assert info['CFBundleExecutable'] == 'DJ4Hub'
assert info['LSMinimumSystemVersion'] == '13.0'
assert subprocess.check_output(['lipo', '-archs', binary], text=True).strip() == subprocess.check_output(['uname', '-m'], text=True).strip()
minimums = re.findall(r'^\s+minos (\d+(?:\.\d+)*)', subprocess.check_output(['otool', '-l', binary], text=True), re.M)
assert minimums and all(tuple(map(int, v.split('.')[:2])) <= (13, 0) for v in minimums), minimums
PY
    codesign --verify --deep --strict "$PACKAGE_DIR"
    ;;
esac

LOG=$(mktemp "${TMPDIR:-/tmp}/dj4hub-smoke.XXXXXX")
PID=
cleanup() {
  if [ -n "$PID" ]; then
    children=$(pgrep -P "$PID" || true)
    # Both entrypoints may own a backend child. Kill only this test's processes.
    for child in $children; do kill -TERM "$child" 2>/dev/null || true; done
    kill -TERM "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -f "$LOG"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
case "$PACKAGE_DIR" in
  *.app) "$ENTRY" --demo -backgroundAudio NO >"$LOG" 2>&1 & ;;
  *) DJ4GHUB_NO_OPEN=1 "$ENTRY" start --demo >"$LOG" 2>&1 & ;;
esac
PID=$!

attempt=0
while [ "$attempt" -lt 60 ]; do
  if ! kill -0 "$PID" 2>/dev/null; then break; fi
  if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/api/health" 2>/dev/null |
    python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(not (d.get("ok") is True and d.get("demo") is True))' 2>/dev/null; then
    echo "Smoke test passed: $ENTRY"
    exit 0
  fi
  attempt=$((attempt + 1))
  sleep 1
done
cat "$LOG" >&2
echo "Smoke test failed: $ENTRY did not serve a healthy demo backend." >&2
exit 1
