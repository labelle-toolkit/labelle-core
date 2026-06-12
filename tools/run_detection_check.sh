#!/usr/bin/env bash
# core#33 harness — drives `evdev-probe` against `uinput_feeder.py` and
# asserts the detection acceptance subset that needs no physical hardware:
#
#   * two SIMULTANEOUS pads -> two connects with distinct slots + GUIDs
#   * destroying one pad    -> a disconnect, the other keeps running
#   * recreating it with identical ids -> connect with the SAME guid
#     (replug identity stability)
#   * after all pads are gone -> describe() is empty (slots freed)
#
# Run as root on Linux (incl. WSL2): tools/run_detection_check.sh
set -euo pipefail
cd "$(dirname "$0")/.."

modprobe uinput 2>/dev/null || true

zig build
OUT=$(mktemp)
./zig-out/bin/evdev-probe >"$OUT" 2>&1 &
PROBE=$!
sleep 1 # let the probe arm the udev monitor before the first hotplug
python3 tools/uinput_feeder.py
wait "$PROBE"

echo "--- probe output ---"
cat "$OUT"
echo "--------------------"

fail=0
expect() { # expect <count> <pattern>
  local n
  n=$(grep -c "$2" "$OUT" || true)
  if [ "$n" -ne "$1" ]; then
    echo "FAIL: expected $1 x '$2', got $n"
    fail=1
  else
    echo "OK: $1 x '$2'"
  fi
}

expect 2 "kind=connected .*name=Virtual Pad A"
expect 1 "kind=connected .*name=Virtual Pad B"
expect 3 "kind=disconnected"
expect 0 "^DESCRIBE"

guid_a1=$(grep "kind=connected" "$OUT" | grep "Virtual Pad A" | head -1 | sed 's/.*guid=\([0-9a-f]*\).*/\1/')
guid_a2=$(grep "kind=connected" "$OUT" | grep "Virtual Pad A" | tail -1 | sed 's/.*guid=\([0-9a-f]*\).*/\1/')
guid_b=$(grep "kind=connected" "$OUT" | grep "Virtual Pad B" | head -1 | sed 's/.*guid=\([0-9a-f]*\).*/\1/')
slot_a=$(grep "kind=connected" "$OUT" | grep "Virtual Pad A" | head -1 | sed 's/.*slot=\([0-9]*\).*/\1/')
slot_b=$(grep "kind=connected" "$OUT" | grep "Virtual Pad B" | head -1 | sed 's/.*slot=\([0-9]*\).*/\1/')

if [ "$guid_a1" = "$guid_a2" ]; then
  echo "OK: replug GUID stable ($guid_a1)"
else
  echo "FAIL: replug GUID changed ($guid_a1 -> $guid_a2)"
  fail=1
fi
if [ "$guid_a1" != "$guid_b" ]; then
  echo "OK: pads have distinct GUIDs"
else
  echo "FAIL: A and B share a GUID"
  fail=1
fi
if [ "$slot_a" != "$slot_b" ]; then
  echo "OK: pads occupy distinct slots ($slot_a vs $slot_b)"
else
  echo "FAIL: A and B share slot $slot_a"
  fail=1
fi

rm -f "$OUT"
if [ "$fail" -eq 0 ]; then
  echo "== detection check: ALL PASS =="
fi
exit $fail
