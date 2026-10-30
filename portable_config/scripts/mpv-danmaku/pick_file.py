#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MPV External Danmaku / Subtitle Picker
Opens a native Windows OpenFileDialog centered on top of MPV with guaranteed topmost z-order.
"""
import sys
import os
import argparse
import subprocess

def pick_tkinter(title, init_dir):
    try:
        import tkinter as tk
        from tkinter import filedialog

        root = tk.Tk()
        # Invisible 0x0 window with topmost attribute ensures the child dialog stays on top of MPV fullscreen
        root.attributes('-alpha', 0.0)
        root.attributes('-topmost', True)
        root.geometry('0x0+0+0')
        root.lift()
        root.focus_force()
        root.update()

        file_path = filedialog.askopenfilename(
            parent=root,
            title=title,
            initialdir=init_dir,
            filetypes=[
                ('所有彈幕與字幕 (*.xml;*.ass;*.json;*.srt;*.vtt)', ('*.xml', '*.ass', '*.json', '*.srt', '*.vtt')),
                ('Bilibili XML 彈幕 (*.xml)', '*.xml'),
                ('ASS 彈幕與字幕 (*.ass)', '*.ass'),
                ('JSON 彈幕檔案 (*.json)', '*.json'),
                ('SRT/VTT 字幕 (*.srt;*.vtt)', ('*.srt', '*.vtt')),
                ('所有檔案 (*.*)', '*.*')
            ]
        )
        root.destroy()
        return file_path
    except Exception as e:
        return None

def pick_powershell(title, init_dir):
    try:
        init_ps = f'$f.InitialDirectory = "{init_dir}"' if init_dir else ''
        ps_code = f'''
        Add-Type -AssemblyName System.Windows.Forms
        $f = New-Object System.Windows.Forms.OpenFileDialog
        $f.Title = "{title}"
        $f.Filter = "所有彈幕與字幕 (*.xml;*.ass;*.json;*.srt;*.vtt)|*.xml;*.ass;*.json;*.srt;*.vtt|Bilibili XML 彈幕 (*.xml)|*.xml|ASS 彈幕與字幕 (*.ass)|*.ass|所有檔案 (*.*)|*.*"
        {init_ps}
        $top = New-Object System.Windows.Forms.Form
        $top.TopMost = $true
        if ($f.ShowDialog($top) -eq [System.Windows.Forms.DialogResult]::OK) {{
            [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
            Write-Output $f.FileName
        }}
        '''
        res = subprocess.run(['powershell', '-NoProfile', '-Command', ps_code], capture_output=True, text=True, encoding='utf-8')
        return res.stdout.strip()
    except Exception:
        return None

def main():
    parser = argparse.ArgumentParser(description="MPV Danmaku / Subtitle File Picker")
    parser.add_argument("candidate", nargs="?", default="")
    parser.add_argument("--dir", default="")
    parser.add_argument("--out", default="")
    args = parser.parse_args()

    init_dir = None
    target_cand = args.dir or args.candidate or ""
    if target_cand:
        cand = target_cand.strip('"\'').rstrip('\\/')
        if os.path.isfile(cand):
            init_dir = os.path.dirname(cand)
        elif os.path.isdir(cand):
            init_dir = cand

    title = '請選擇外部彈幕或字幕檔案 (支援任意不同檔名與路徑)'
    file_path = pick_tkinter(title, init_dir)
    if file_path is None:
        file_path = pick_powershell(title, init_dir)

    if file_path:
        norm = os.path.normpath(file_path.strip('"\' \t\r\n'))
        if args.out:
            try:
                with open(args.out, "w", encoding="utf-8") as f:
                    f.write(norm)
            except Exception:
                pass
        try:
            sys.stdout.write(norm)
            sys.stdout.flush()
        except Exception:
            pass

if __name__ == '__main__':
    main()
