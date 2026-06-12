#!/usr/bin/env python3
"""core#33 harness -- uinput virtual-gamepad feeder (detection phase).

Creates TWO virtual gamepads (real kernel input devices, via /dev/uinput)
with distinct identities, then exercises the hotplug lifecycle the
detection source must track:

  t=0   create pad A (045e:028e) and pad B (054c:09cc)
  t=3   destroy pad A                      -> disconnect for A's slot
  t=5   recreate pad A with the SAME ids   -> connect with the SAME guid
  t=8   exit (destroys both)               -> disconnect for both

Two simultaneous pads are deliberate: multi-gamepad handling (distinct
slots, distinct GUIDs, independent lifecycles) is part of the acceptance
surface, not an afterthought.

Requires /dev/uinput access (root, or a uinput udev rule) and
python3-evdev. The pads carry BTN_GAMEPAD-class keys plus ABS axes so
udev's input_id builtin tags them ID_INPUT_JOYSTICK=1 -- the filter
gamepad_source/linux.zig applies.
"""
import time

from evdev import AbsInfo, UInput, ecodes as e

STICK = AbsInfo(value=0, min=-32768, max=32767, fuzz=16, flat=128, resolution=0)
TRIGGER = AbsInfo(value=0, min=0, max=255, fuzz=0, flat=0, resolution=0)

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
    ],
}


def make(name, vendor, product):
    ui = UInput(CAPS, name=name, vendor=vendor, product=product,
                version=0x0110, bustype=e.BUS_USB)
    print(f"feeder: created {name} ({vendor:04x}:{product:04x}) at {ui.device.path}",
          flush=True)
    return ui


def main():
    pad_a = make("Virtual Pad A", 0x045E, 0x028E)
    pad_b = make("Virtual Pad B", 0x054C, 0x09CC)
    time.sleep(3)

    pad_a.close()
    print("feeder: destroyed Virtual Pad A", flush=True)
    time.sleep(2)

    # Same identity -> the source must derive the same GUID (replug key).
    pad_a = make("Virtual Pad A", 0x045E, 0x028E)
    time.sleep(3)

    pad_a.close()
    pad_b.close()
    print("feeder: destroyed both pads", flush=True)


if __name__ == "__main__":
    main()
