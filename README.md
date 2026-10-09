# ScorpiViewer reference project
This is a reference project for interacting with Scorpi frame buffer.  
The communication socket name is hardcoded as "/tmp/vm_sock" in ViewController.m

Trackpad scrolling preserves precise deltas and macOS momentum. Ordinary mouse
wheel events retain whole-detent scrolling. This requires a matching Scorpi
hypervisor with the `scroll_event` command and USB tablet Resolution Multiplier
support; no VM device configuration change is needed. Restart the VM after
updating the hypervisor so the guest reads the new HID descriptor. Guests that
do not enable high-resolution scrolling receive accumulated whole wheel steps.

Trackpad sensitivity is set by `TRACKPAD_POINTS_PER_DETENT` in `ViewController.m`
(40 points per wheel detent). Horizontal scrolling is not forwarded.
