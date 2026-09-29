#!/usr/bin/env python3
"""Print the X11 screen size as "WIDTH HEIGHT" (pixels).

Used by the TypingMaster launcher to pick a Wine DPI. Talks to the X server
(or XWayland) through libX11 directly, so no extra tools are needed in the
sandbox. Exits non-zero if the display can't be opened.
"""
import ctypes
import sys


def main() -> int:
    try:
        x11 = ctypes.cdll.LoadLibrary("libX11.so.6")
    except OSError:
        return 1
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XDefaultScreen.argtypes = [ctypes.c_void_p]
    x11.XDisplayWidth.argtypes = [ctypes.c_void_p, ctypes.c_int]
    x11.XDisplayHeight.argtypes = [ctypes.c_void_p, ctypes.c_int]
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]

    display = x11.XOpenDisplay(None)
    if not display:
        return 1
    screen = x11.XDefaultScreen(display)
    print(x11.XDisplayWidth(display, screen), x11.XDisplayHeight(display, screen))
    x11.XCloseDisplay(display)
    return 0


if __name__ == "__main__":
    sys.exit(main())
