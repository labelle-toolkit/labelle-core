#!/usr/bin/env python3
"""core#33 harness -- uinput virtual-gamepad feeder (detection + state).

Creates TWO virtual gamepads (real kernel input devices, via /dev/uinput)
with distinct identities, exercises the hotplug lifecycle, then drives
button/axis STATE on both pads:

  t=0   create pad A (045e:028e) and pad B (054c:09cc)
  t=3   destroy pad A                      -> disconnect for A's slot
  t=5   recreate pad A with the SAME ids   -> connect, SAME guid (slot 0 reused)
  t=7   STATE phase:
          - press/release BTN_SOUTH on A          (slot 0, canonical 7)
          - sweep ABS_X to max and back on A      (slot 0, axis 0 -> +1.0)
          - press/release BTN_EAST on B           (slot 1, canonical 6)
          - SIMULTANEOUS: hold BTN_TL on A (9) while pressing BTN_START
            on B (15) -- multi-pad state independence
          - hat d-pad right on A                  (slot 0, canonical 2)
          - ABS_RZ (right trigger) to max on B    (slot 1, axis 5 -> 1.0,
            plus synthesized canonical button 12)
  t~13  exit (destroys both)               -> disconnect for both

Multi-pad coverage is deliberate: distinct slots, distinct GUIDs, and
state that never bleeds across slots are asserted, not assumed.

Requires /dev/uinput access (root, or a uinput udev rule) and
python3-evdev. The pads carry BTN_GAMEPAD-class keys plus ABS axes so
udev's input_id builtin tags them ID_INPUT_JOYSTICK=1 -- the filter
gamepad_source/linux.zig applies.
"""
import time

from evdev import AbsInfo, UInput, ecodes as e

STICK = AbsInfo(value=0, min=-32768, max=32767, fuzz=16, flat=128, resolution=0)
TRIGGER = AbsInfo(value=0, min=0, max=255, fuzz=0, flat=0, resolution=0)
HAT = AbsInfo(value=0, min=-1, max=1, fuzz=0, flat=0, resolution=0)

CAPS = {
    e.EV_KEY: [
        e.BTN_SOUTH, e.BTN_EAST, e.BTN_NORTH, e.BTN_WEST,
        e.BTN_TL, e.BTN_TR, e.BTN_SELECT, e.BTN_START,
        e.BTN_MODE, e.BTN_THUMBL, e.BTN_THUMBR,
        e.BTN_DPAD_UP, e.BTN_DPAD_DOWN, e.BTN_DPAD_LEFT, e.BTN_DPAD_RIGHT,
    ],
    e.EV_ABS: [
        (e.ABS_X, STICK), (e.ABS_Y, STICK),
        (e.ABS_RX, STICK), (e.ABS_RY, STICK),
        (e.ABS_Z, TRIGGER), (e.ABS_RZ, TRIGGER),
        (e.ABS_HAT0X, HAT), (e.ABS_HAT0Y, HAT),
    ],
}

PAUSE = 0.4  # > 2 probe poll ticks, so every edge lands in a distinct frame


def make(name, vendor, product):
    ui = UInput(CAPS, name=name, vendor=vendor, product=product,
                version=0x0110, bustype=e.BUS_USB)
    print(f"feeder: created {name} ({vendor:04x}:{product:04x}) at {ui.device.path}",
          flush=True)
    return ui


def key(ui, code, value):
    ui.write(e.EV_KEY, code, value)
    ui.syn()


def abs_(ui, code, value):
    ui.write(e.EV_ABS, code, value)
    ui.syn()


def main():
    pad_a = make("Virtual Pad A", 0x045E, 0x028E)
    pad_b = make("Virtual Pad B", 0x054C, 0x09CC)
    time.sleep(3)

    pad_a.close()
    print("feeder: destroyed Virtual Pad A", flush=True)
    time.sleep(2)

    # Same identity -> the source must derive the same GUID (replug key),
    # and the freed slot 0 must be reused (dense lowest-free-slot policy).
    pad_a = make("Virtual Pad A", 0x045E, 0x028E)
    time.sleep(2)

    print("feeder: state phase", flush=True)
    # Button press/release edges on each pad.
    key(pad_a, e.BTN_SOUTH, 1); time.sleep(PAUSE)
    key(pad_a, e.BTN_SOUTH, 0); time.sleep(PAUSE)
    abs_(pad_a, e.ABS_X, 32767); time.sleep(PAUSE)
    abs_(pad_a, e.ABS_X, 0); time.sleep(PAUSE)
    key(pad_b, e.BTN_EAST, 1); time.sleep(PAUSE)
    key(pad_b, e.BTN_EAST, 0); time.sleep(PAUSE)

    # Simultaneous input on both pads: must land in their own slots only.
    key(pad_a, e.BTN_TL, 1); time.sleep(PAUSE)
    key(pad_b, e.BTN_START, 1); time.sleep(PAUSE)
    key(pad_a, e.BTN_TL, 0)
    key(pad_b, e.BTN_START, 0); time.sleep(PAUSE)

    # Hat-style d-pad (the form real pads use) and an analog trigger pull
    # past the synthesis threshold.
    abs_(pad_a, e.ABS_HAT0X, 1); time.sleep(PAUSE)
    abs_(pad_a, e.ABS_HAT0X, 0); time.sleep(PAUSE)
    abs_(pad_b, e.ABS_RZ, 255); time.sleep(PAUSE)
    abs_(pad_b, e.ABS_RZ, 0); time.sleep(PAUSE)

    pad_a.close()
    pad_b.close()
    print("feeder: destroyed both pads", flush=True)


if __name__ == "__main__":
    main()
