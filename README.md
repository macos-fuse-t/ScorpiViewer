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

In fullscreen, guest resolution changes stretch the display to the existing
window. Fullscreen transitions also preserve the window frame, and fullscreen
layout does not request a different guest resolution. Windowed mode continues
to size the window to the guest display. Check with `tests/run-fullscreen-test.sh`.

Choose **View → Lock Mouse to Window** in the menu bar, or Command + right-click
inside the guest display and check **Lock Mouse to Window** in its context menu.
Then click inside the guest display to capture the pointer. The capture
click is not sent to the guest. A brief hint shows **Control + Command + G** to
release the pointer. The option stays checked after release; click inside again
to recapture, or uncheck it in the context menu to restore ordinary input.
The setting is remembered across launches; each new Viewer still waits for a
click inside before capturing the pointer.

With mouse lock enabled, guest mouse and keyboard input is forwarded only while
captured and the Viewer is focused. Release, focus loss, menus, fullscreen
transitions, and display disconnects free the pointer and release held guest
buttons and keys. Window moves and resizes update the confinement boundary.
With a matching hypervisor, captured input uses relative mouse reports, allowing
continuous camera turns past every screen edge. The physical Mac pointer stays
hidden at the center; guest cursor shape, visibility and `move_cursor` position
updates control a separate host-rendered overlay. Until the guest supplies cursor
positions, visible cursor placement is estimated from movement. Ordinary
uncaptured input continues to use absolute tablet coordinates. Older hypervisors
retain the previous absolute confinement behavior.

Restart the VM after updating the hypervisor: the existing USB tablet now exposes
both absolute and relative HID mouse collections, with no VM configuration change
or custom guest driver required. Confinement and its hint live in
`MouseLockController`, and host cursor drawing lives in `GuestCursorOverlay`.
Check with `tests/run-mouse-lock-test.sh`.

View → Use Mac shortcuts is on by default and remembers your choice. It sends
Cmd+C/X/V/A/Z/F/W to the guest as Ctrl+C/X/V/A/Z/F/W. These shortcuts reach the
guest before macOS menus handle them, including Cmd+W for closing a guest tab or
document. With the option off, they use the Windows key instead. Other Command
combinations retain their existing behavior, and tapping Command opens the guest
Start menu. Cmd+Q, Cmd+Tab, and Ctrl+Cmd+F retain their macOS actions. Clipboard
sharing is controlled separately by Share Clipboard.
