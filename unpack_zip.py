#!/usr/bin/env python3
"""Unpack a TypingMaster program zip made on Windows.

Used by scripts/prepare-input.sh (download bundle) and by apply_extra (Flathub
install). Differences from `unzip`:

- File names without the zip UTF-8 flag are Windows "ANSI" names (e.g.
  "lessons/Città.vcb.it" in Windows-1252). They are decoded as UTF-8 if valid,
  otherwise as Windows-1252, instead of being guessed from the locale.
- Backslashes become "/", and entries that would land outside the target
  folder (absolute paths, "..") are refused.

Usage: unpack_zip.py <program.zip> <target-folder>
"""
import os
import posixpath
import shutil
import sys
import zipfile

UTF8_FLAG = 0x800


def entry_name(info: zipfile.ZipInfo) -> str:
    if info.flag_bits & UTF8_FLAG:
        name = info.filename
    else:
        # zipfile decoded the raw bytes as cp437; get the bytes back.
        raw = info.filename.encode("cp437")
        try:
            name = raw.decode("utf-8")
        except UnicodeDecodeError:
            name = raw.decode("cp1252", errors="replace")
    return name.replace("\\", "/")


def safe_path(target: str, name: str) -> str:
    norm = posixpath.normpath(name)
    if norm.startswith("/") or norm == ".." or norm.startswith("../"):
        raise ValueError(f"unsafe path in zip: {name!r}")
    return os.path.join(target, *norm.split("/"))


def unpack(zip_path: str, target: str) -> int:
    count = 0
    with zipfile.ZipFile(zip_path) as zf:
        for info in zf.infolist():
            name = entry_name(info)
            dest = safe_path(target, name)
            if name.endswith("/"):
                os.makedirs(dest, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with zf.open(info) as src, open(dest, "wb") as out:
                shutil.copyfileobj(src, out)
            os.chmod(dest, 0o644)
            count += 1
    return count


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: unpack_zip.py <program.zip> <target-folder>")
    try:
        n = unpack(sys.argv[1], sys.argv[2])
    except (OSError, ValueError, zipfile.BadZipFile) as e:
        sys.exit(f"error: {e}")
    print(f"unpacked {n} files")
