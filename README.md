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

Viewer accepts the HV socket as its first positional argument. For text clipboard
sharing with Windows, launch it with `--daemon-socket <scorpid socket> --vm-id <VM ID>`
(or set `SCORPI_DAEMON_SOCKET` and `SCORPI_VM_ID`). `scorpi view` and
`scorpi start --view` pass those arguments automatically. View → Share Clipboard is
on by default and synchronizes while this Viewer is focused, including its menus.
Focus loss attempts a final Windows-to-Mac copy before pausing. Closing the window
or disabling sharing stops immediately. Clipboard contents stay in scorpid and
the guest agent; Viewer sends only state over `scorpi.viewer.v1` on the daemon's
Unix socket. Daemon disconnects do not interrupt the HV display/input connection;
Viewer reconnects and sends a fresh state snapshot.

The native daemon-session client has a standalone protocol check:
`python3 tests/viewer_session_protocol_test.py`.

Viewer redraws completed IOSurface frames and notification-driven scanouts on
demand. Pending updates coalesce into the next AppKit redraw; idle frames do not
submit GPU work. Resize/exposure still redraw the current image, and legacy
`redrawOnTimer` scanouts retain the 60 Hz fallback. Surface IDs identify storage,
not frame contents: repeated IDs still invalidate the view. The native rendering
check is `tests/run-renderer-test.sh`.

View → Use Mac shortcuts is on by default and remembers your choice. It sends
Cmd+C/X/V/A/Z/F/W to the guest as Ctrl+C/X/V/A/Z/F/W. These shortcuts reach the
guest before macOS menus handle them, including Cmd+W for closing a guest tab or
document. With the option off, they use the Windows key instead. Other Command
combinations retain their existing behavior, and tapping Command opens the guest
Start menu. Cmd+Q, Cmd+Tab, and Ctrl+Cmd+F retain their macOS actions. Clipboard
sharing is controlled separately by Share Clipboard.
