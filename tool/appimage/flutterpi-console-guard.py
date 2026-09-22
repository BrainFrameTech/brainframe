#!/usr/bin/env python3
"""Keep keystrokes out of the console while flutter-pi runs.

flutter-pi reads the keyboard through libinput, straight from evdev, and
draws through DRM/KMS. It never tells the kernel's virtual terminal that it
has taken the keyboard over, so the VT keeps translating every key press and
queuing the characters on the console's tty in parallel. Nothing reads them
while the app runs; the moment it exits, the shell (or the login prompt) that
owns the console reads the lot — a username and password typed into a note
become a login on tty1 (flutter-pi issue #298). Ctrl+C typed into a text
field reaches the same tty and kills the app.

Every compositor that draws on KMS defends against this the same way: it puts
its controlling VT's keyboard into K_OFF (the KDSKBMODE ioctl), under which
the kernel discards key events before they become characters, and restores
the previous mode on exit. libinput is untouched — the app still sees every
key. This script does that around the command it is given, because flutter-pi
does not do it itself.

Usage: flutterpi-console-guard.py COMMAND [ARG...]

Exit status is the command's. The VT is found through the controlling
terminal (/dev/tty), so launching from a login on the console needs no
privileges; /dev/tty0 (the active console) is tried next, which needs
CAP_SYS_TTY_CONFIG. When neither works — launched over SSH, say — the command
still runs, after a warning that spells out the leak.

With K_OFF set, Ctrl+Alt+Fn cannot switch consoles until the app exits; that
is the kernel's behaviour, not a choice here. If this guard is killed outright
(SIGKILL, an OOM kill) the mode is not restored: from another machine,
`sudo kbd_mode -u -C /dev/tty1` brings the console back.
"""

import fcntl
import os
import signal
import struct
import subprocess
import sys

KDGKBMODE = 0x4B44  # <linux/kd.h>: read the keyboard mode into an int
KDSKBMODE = 0x4B45  # set the keyboard mode from an int argument
K_OFF = 0x04

WARNING = """\
brainframe: cannot turn the console keyboard off ({reason}).
  Keystrokes typed into the app will ALSO reach whatever owns the console —
  a shell, or the login prompt — and be acted on when the app exits. Launch
  from a login on the console itself, or give the process CAP_SYS_TTY_CONFIG
  (a systemd unit with TTYPath= does either). See docs/appimage.md."""


def open_console():
    """Return (path, fd, current mode) of a VT this process may configure."""
    reasons = []
    for path in ("/dev/tty", "/dev/tty0"):
        try:
            fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
        except OSError as e:
            reasons.append(f"{path}: {e.strerror}")
            continue
        mode = bytearray(4)
        try:
            fcntl.ioctl(fd, KDGKBMODE, mode)
        except OSError as e:
            # ENOTTY here means "not a virtual console" (a pty over SSH).
            reasons.append(f"{path}: {e.strerror}")
            os.close(fd)
            continue
        return path, fd, struct.unpack("i", mode)[0]
    return None, -1, "; ".join(reasons)


def main(argv):
    if not argv:
        print("usage: flutterpi-console-guard.py COMMAND [ARG...]", file=sys.stderr)
        return 2

    path, fd, previous = open_console()
    if path is None:
        print(WARNING.format(reason=previous), file=sys.stderr)
        os.execvp(argv[0], argv)

    try:
        fcntl.ioctl(fd, KDSKBMODE, K_OFF)
    except OSError as e:
        print(WARNING.format(reason=f"{path}: {e.strerror}"), file=sys.stderr)
        os.close(fd)
        os.execvp(argv[0], argv)

    child = subprocess.Popen(argv)

    # A signal to this guard is meant for the app: forward it and keep waiting,
    # so the mode is restored only once the app is actually gone.
    def forward(signum, _frame):
        child.send_signal(signum)

    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, forward)

    try:
        status = child.wait()
    finally:
        try:
            fcntl.ioctl(fd, KDSKBMODE, previous)
        finally:
            os.close(fd)

    # Popen reports death by signal as a negative number; mirror the shell.
    return status if status >= 0 else 128 - status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
