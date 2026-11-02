import sys
import os
import time
import subprocess
import ctypes
from ctypes import wintypes

user32 = ctypes.windll.user32

PROJECT_ROOT = r"D:\Media tool\mpv-x86_64-v3-20260610-git-304426c"
MPV_COM = os.path.join(PROJECT_ROOT, "mpv.com")
SCREENSHOT_PATH = os.path.join(PROJECT_ROOT, "prove-it", "screenshots", "real_mouse_hover_test.png")

# Find window callback
mpv_hwnds = []

def enum_windows_callback(hwnd, extra):
    if user32.IsWindowVisible(hwnd):
        length = user32.GetWindowTextLengthW(hwnd)
        if length > 0:
            buff = ctypes.create_unicode_buffer(length + 1)
            user32.GetWindowTextW(hwnd, buff, length + 1)
            title = buff.value
            if "mpv" in title.lower() or "zoo" in title.lower() or "bilibili" in title.lower():
                mpv_hwnds.append((hwnd, title))
    return True

WNDENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

def find_mpv_window():
    mpv_hwnds.clear()
    user32.EnumWindows(WNDENUMPROC(enum_windows_callback), 0)
    if mpv_hwnds:
        return mpv_hwnds[0][0]
    return None

def main():
    yt_url = "https://www.youtube.com/watch?v=jNQXAC9IVRw"
    
    # Launch mpv with GUI
    cmd = [
        MPV_COM,
        f"--screenshot-directory={os.path.join(PROJECT_ROOT, 'prove-it', 'screenshots')}",
        "--keep-open=yes",
        "--force-window=yes",
        "--ontop=yes",
        yt_url
    ]
    
    print("[1] Launching MPV with YouTube...")
    proc = subprocess.Popen(cmd, cwd=PROJECT_ROOT)
    
    # Wait for window to appear
    hwnd = None
    for _ in range(20):
        time.sleep(0.5)
        hwnd = find_mpv_window()
        if hwnd:
            break
            
    if not hwnd:
        print("[FAIL] MPV window not found!")
        proc.terminate()
        return 1
        
    print(f"[2] Found MPV window handle: {hwnd}")
    
    # Wait for playback to begin
    time.sleep(4.0)
    
    # Get window rect
    rect = wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    w = rect.right - rect.left
    h = rect.bottom - rect.top
    print(f"[3] Window rect: ({rect.left}, {rect.top}) - ({rect.right}, {rect.bottom}), size {w}x{h}")
    
    # Seekbar target: center horizontally, ~35px from bottom
    target_x = rect.left + w // 2
    target_y = rect.bottom - 45
    
    print(f"[4] Moving mouse cursor to seekbar position: ({target_x}, {target_y})...")
    user32.SetCursorPos(target_x, target_y)
    
    # Also send a small wiggle so Windows sends WM_MOUSEMOVE
    time.sleep(0.1)
    user32.SetCursorPos(target_x + 2, target_y)
    time.sleep(0.1)
    user32.SetCursorPos(target_x, target_y)
    
    # Wait for hover thumbnail to render
    print("[5] Hovering for 4.5 seconds for thumbfast to decode...")
    time.sleep(4.5)
    
    # Take screenshot via mpv IPC or user32 window capture or script
    # We can write an IPC command or send key 's' for screenshot
    # 's' in mpv by default takes screenshot of window or video
    # In portable_config/input.conf, what does 's' do?
    print("[6] Sending 's' key to mpv window for screenshot...")
    WM_KEYDOWN = 0x0100
    WM_KEYUP = 0x0101
    VK_S = 0x53
    user32.PostMessageW(hwnd, WM_KEYDOWN, VK_S, 0)
    time.sleep(0.1)
    user32.PostMessageW(hwnd, WM_KEYUP, VK_S, 0)
    
    time.sleep(2.0)
    
    # Terminate mpv
    proc.terminate()
    print("[7] MPV closed. Check screenshot directory.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
