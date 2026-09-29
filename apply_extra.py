#!/usr/bin/python3
"""Flathub install step (flatpak "apply_extra").

Flatpak downloads the TypingMaster program zip (extra-data) from
typingmaster.com at install time into /app/extra and runs this script there.
It prepares /app/extra/typingmaster exactly like scripts/prepare-input.sh
does for the download bundle:

- unpack with correct Windows file names (unpack_zip.py),
- drop the files listed in exclude-files.txt,
- write .package-build-id and .package-files for the launcher,
- delete the zip.
"""
import fnmatch
import glob
import os
import shutil
import sys

SHARE = "/app/share/typingmaster"
APP_EXE = "TypingMaster.exe"
TARGET = "typingmaster"

sys.path.insert(0, SHARE)
from unpack_zip import unpack  # noqa: E402


def main() -> int:
    zips = glob.glob("*.zip")
    if len(zips) != 1:
        print(f"apply_extra: expected one zip in {os.getcwd()}, found {zips}", file=sys.stderr)
        return 1

    shutil.rmtree("unpack", ignore_errors=True)
    shutil.rmtree(TARGET, ignore_errors=True)
    unpack(zips[0], "unpack")

    # Files at the top level, or inside one wrapping folder.
    src = "unpack"
    if not os.path.isfile(os.path.join(src, APP_EXE)):
        found = [d for d in glob.glob(os.path.join(src, "*", APP_EXE))]
        if len(found) != 1:
            print(f"apply_extra: {APP_EXE} not found in the zip", file=sys.stderr)
            return 1
        src = os.path.dirname(found[0])
    shutil.move(src, TARGET)
    shutil.rmtree("unpack", ignore_errors=True)

    # Excluded files (same patterns as config.sh EXCLUDE_FILES).
    with open(os.path.join(SHARE, "exclude-files.txt"), encoding="utf-8") as f:
        patterns = [p.strip() for p in f if p.strip() and not p.startswith("#")]
    files = []
    for root, _dirs, names in os.walk(TARGET):
        for name in names:
            rel = os.path.relpath(os.path.join(root, name), TARGET).replace(os.sep, "/")
            if any(fnmatch.fnmatchcase(rel, p) for p in patterns):
                os.remove(os.path.join(TARGET, rel))
                print(f"apply_extra: excluded {rel}")
            else:
                files.append(rel)

    shutil.copyfile(os.path.join(SHARE, "package-build-id"), os.path.join(TARGET, ".package-build-id"))
    # Sorted like `LC_ALL=C sort` (UTF-8 byte order = code point order).
    with open(os.path.join(TARGET, ".package-files"), "w", encoding="utf-8") as f:
        f.writelines(rel + "\n" for rel in sorted(files))

    os.remove(zips[0])
    print(f"apply_extra: installed {len(files)} program files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
