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
# Clean up the background probe + temp file on ANY exit (incl. an early `set -e`
# abort if the feeder fails), so we never leak a running probe or a tmp file.
trap 'kill "$PROBE" 2>/dev/null || true; rm -f "$OUT"' EXIT
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

# Resolve each pad's ACTUAL slot from its connect event. Two SIMULTANEOUSLY
# created pads race through udev enumeration, so Pad A is NOT guaranteed slot 0 —
# keying the state assertions to a hardcoded slot made this check flaky (it
# passed only when A happened to enumerate first). Pad A is replugged and
# densely reuses its freed slot, so its latest connect slot is the one live
# during the state phase; Pad B connects once.
guid_a1=$(grep "kind=connected" "$OUT" | grep "Virtual Pad A" | head -1 | sed 's/.*guid=\([0-9a-f]*\).*/\1/')
guid_a2=$(grep "kind=connected" "$OUT" | grep "Virtual Pad A" | tail -1 | sed 's/.*guid=\([0-9a-f]*\).*/\1/')
guid_b=$(grep "kind=connected" "$OUT" | grep "Virtual Pad B" | head -1 | sed 's/.*guid=\([0-9a-f]*\).*/\1/')
slot_a=$(grep "kind=connected" "$OUT" | grep "Virtual Pad A" | tail -1 | sed 's/.*slot=\([0-9]*\).*/\1/')
slot_b=$(grep "kind=connected" "$OUT" | grep "Virtual Pad B" | head -1 | sed 's/.*slot=\([0-9]*\).*/\1/')

# ── State phase (core#33: update/isButtonPressed/axisValue) ────────────
# Assertions keyed to each pad's resolved slot ($slot_a / $slot_b), not a
# hardcoded 0/1 — order-independent.
expect 1 "STATE slot=$slot_a btn=7 pressed"   # BTN_SOUTH on A -> right_face_down
expect 1 "STATE slot=$slot_b btn=6 pressed"   # BTN_EAST on B -> right_face_right
expect 1 "STATE slot=$slot_a btn=9 pressed"   # BTN_TL held on A (simultaneous phase)
expect 1 "STATE slot=$slot_b btn=15 pressed"  # BTN_START on B while A holds TL
expect 1 "STATE slot=$slot_a btn=2 pressed"   # hat right on A -> left_face_right
expect 1 "STATE slot=$slot_b btn=12 pressed"  # RZ past threshold -> synthesized right_trigger_2
expect 1 "STATE slot=$slot_a axis=0 val=1.00" # ABS_X max on A -> +1.0
expect 1 "STATE slot=$slot_b axis=5 val=1.00" # ABS_RZ max on B -> 1.0
# Cross-slot bleed must not happen: B's inputs never on A's slot and vice versa.
expect 0 "STATE slot=$slot_a btn=6 "
expect 0 "STATE slot=$slot_a btn=15 "
expect 0 "STATE slot=$slot_b btn=7 "
expect 0 "STATE slot=$slot_b btn=9 "
expect 0 "STATE slot=$slot_b btn=2 "

grep "^TIMING" "$OUT" || true

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
