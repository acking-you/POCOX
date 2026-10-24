"""Close an owned launcher's console and verify the release GUI survives."""

import ctypes
from ctypes import wintypes
from pathlib import Path
import subprocess
import sys
import tempfile
import time

kernel = ctypes.WinDLL("kernel32", use_last_error=True)
user = ctypes.WinDLL("user32", use_last_error=True)
kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel.OpenProcess.restype = wintypes.HANDLE
kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
kernel.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
kernel.CloseHandle.argtypes = [wintypes.HANDLE]
user.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]


def read_report(path):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if path.exists():
            values = path.read_text().split()
            if len(values) == 3:
                return [int(value) for value in values]
        time.sleep(0.02)
    raise AssertionError(f"Fixture did not write {path}")


with tempfile.TemporaryDirectory(prefix="pocox-console-") as directory:
    report = Path(directory) / "parent.txt"
    startup = subprocess.STARTUPINFO()
    startup.dwFlags = subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = subprocess.SW_HIDE
    parent = subprocess.Popen([sys.argv[1], "parent", str(report)], startupinfo=startup)
    child = None
    try:
        window, pid, visible = read_report(report)
        assert window and not visible, "The test must own a hidden parent console"
        child = kernel.OpenProcess(0x00100000 | 0x0001, False, pid)  # synchronize, terminate
        assert child, "Hold the exact child process for checks and cleanup"
        child_window, _, _ = read_report(Path(str(report) + ".child"))
        assert not child_window, "The release GUI attached to its launcher's console"
        assert user.PostMessageW(window, 0x0010, 0, 0), "Close only the fixture's console"
        parent.wait(timeout=5)
        assert kernel.WaitForSingleObject(child, 500) == 0x102, "Closing the console killed the GUI"
        print("Release GUI stayed independent and survived closing its launcher's console.")
    finally:
        if child:
            kernel.TerminateProcess(child, 0)
            kernel.WaitForSingleObject(child, 5000)
            kernel.CloseHandle(child)
        if parent.poll() is None:
            parent.kill()
        parent.wait(timeout=5)
