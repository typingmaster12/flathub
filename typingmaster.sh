#!/bin/sh
# TypingMaster launcher inside the Flatpak sandbox.
#
# - Keeps a private Wine prefix in ~/.var/app/com.typingmaster.TypingMaster/data/wine
# - Copies the packaged program files into the prefix (the app expects a
#   writable program folder, /app is read-only) whenever the package version
#   changes. Files a previous package shipped but this one doesn't are
#   deleted; files the app created there itself are left alone.
# - Sets Wine's DPI from the screen size (TypingMaster is DPI-unaware and
#   would be tiny on large screens; Wine scales it up when DPI > 96).
# - Starts TypingMaster.exe.
#
# User settings: ~/.var/app/com.typingmaster.TypingMaster/config/typingmaster.conf
#   DPI=auto | 96 | 120 | 144 | 192 | ...
#
# Environment overrides (for troubleshooting):
#   TYPINGMASTER_DPI=...          overrides DPI from typingmaster.conf
#   WINEDEBUG=...                 Wine debug channels (default: all off)
#   TYPINGMASTER_RESET_PREFIX=1   delete the Wine prefix before starting
#                                 (user data in the prefix is lost!)

set -eu

# Program files: in the package itself (download bundle), or unpacked at
# install time from the extra-data zip (Flathub, see apply_extra.py).
if [ -d /app/extra/typingmaster ]; then
    PACKAGED_DIR=/app/extra/typingmaster
else
    PACKAGED_DIR=/app/typingmaster
fi
SHARE_DIR=/app/share/typingmaster
APP_EXE=TypingMaster.exe

export WINEPREFIX="${XDG_DATA_HOME:-$HOME/.local/share}/wine"
export WINEDEBUG="${WINEDEBUG:--all}"

INSTALL_DIR="$WINEPREFIX/drive_c/Program Files (x86)/TypingMaster"
PACKAGE_STAMP="$(cat "$PACKAGED_DIR/.package-build-id")"
STAMP_FILE="$WINEPREFIX/.typingmaster-build-id"
FILES_LIST="$WINEPREFIX/.typingmaster-files"
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/typingmaster.conf"
USER_REG="$WINEPREFIX/user.reg"

log() { echo "typingmaster: $*" >&2; }

# Registry state is checked in user.reg itself, not in separate stamp files:
# if Wine is killed before it saves the registry, a stamp would claim the
# settings were applied although they were lost.
# Note: while Wine is running, its changes may not be on disk yet; the
# settings are then simply applied again, which is harmless.

# Print the value of "name" in [key] of user.reg (key as written in the file,
# e.g. 'Control Panel\\Desktop').
user_reg_value() {
    # Passed via the environment: awk -v would turn \\ into \.
    REG_KEY="[$1]" REG_NAME="\"$2\"=" awk '
        BEGIN { key = ENVIRON["REG_KEY"]; name = ENVIRON["REG_NAME"] }
        index($0, "[") == 1 { in_key = (index($0, key) == 1) }
        in_key && index($0, name) == 1 { print substr($0, length(name) + 1); exit }
    ' "$USER_REG" 2>/dev/null
    unset REG_KEY REG_NAME
}

# DPI for a screen height in pixels. TypingMaster's window is ~800x600, so it
# is scaled from 1050 px screen height upwards.
dpi_for_height() {
    if   [ "$1" -ge 2000 ]; then echo 192   # 4K and up: 200 %
    elif [ "$1" -ge 1400 ]; then echo 144   # 1440p/1600p: 150 %
    elif [ "$1" -ge 1050 ]; then echo 120   # 1080p/1200p: 125 %
    else                         echo 96    # 100 %
    fi
}

# Requested DPI: TYPINGMASTER_DPI, else DPI= from the config file, else auto.
wanted_dpi() {
    setting="${TYPINGMASTER_DPI:-}"
    if [ -z "$setting" ] && [ -f "$CONFIG_FILE" ]; then
        setting="$(sed -n 's/^[[:space:]]*DPI[[:space:]]*=[[:space:]]*\([A-Za-z0-9]*\).*/\1/p' "$CONFIG_FILE" | tail -1)"
    fi
    case "$setting" in
        ''|auto|AUTO|Auto)
            size="$(python3 "$SHARE_DIR/screen-size.py" 2>/dev/null)" || size=""
            if [ -n "$size" ]; then
                dpi_for_height "${size#* }"
            else
                echo 96
            fi ;;
        *[!0-9]*) log "ignoring invalid DPI setting '$setting'"; echo 96 ;;
        *)
            if [ "$setting" -lt 96 ] || [ "$setting" -gt 480 ]; then
                log "ignoring out-of-range DPI $setting (96-480)"; echo 96
            else
                echo "$setting"
            fi ;;
    esac
}

# Create the user config on first start, so users can find and change it.
if [ ! -f "$CONFIG_FILE" ]; then
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" <<'EOF'
# TypingMaster (Flatpak) settings. Changes apply at the next start.
#
# Size of the TypingMaster window and text:
#   DPI=auto   pick from the screen size (default)
#   DPI=96     100 %  (smallest)
#   DPI=120    125 %
#   DPI=144    150 %
#   DPI=192    200 %
DPI=auto
EOF
fi

if [ "${TYPINGMASTER_RESET_PREFIX:-0}" = 1 ] && [ -d "$WINEPREFIX" ]; then
    log "resetting Wine prefix $WINEPREFIX"
    wineserver -k 2>/dev/null || true
    rm -rf "$WINEPREFIX"
fi

# First start: create the prefix.
if [ ! -f "$WINEPREFIX/system.reg" ]; then
    log "creating Wine prefix (first start, this takes a moment)"
    mkdir -p "$WINEPREFIX"
    wineboot --init
    # Let Wine write the new registry to disk (computer_name reads it). Safe
    # to wait here: with a brand-new prefix no TypingMaster can be running.
    wineserver -w
fi

# NOTE: don't use "wineserver -w" below this point. If TypingMaster is
# already running, it waits until the user closes it, so a second start from
# the menu would hang. Registry changes reach the running Wine directly.

# Apply our Wine defaults on first start and whenever the package's
# wine-settings.reg changed (e.g. a new font mapping in an update).
# The import also stores the file's checksum as a marker value in the registry.
settings_sum="$(sha256sum "$SHARE_DIR/wine-settings.reg" | cut -d' ' -f1 | cut -c1-16)"
if [ "$(user_reg_value 'Software\\TypingMaster-Flatpak' SettingsVersion)" != "\"$settings_sum\"" ]; then
    log "applying Wine settings"
    reg_tmp="$(mktemp)"
    cat "$SHARE_DIR/wine-settings.reg" > "$reg_tmp"
    printf '\n[HKEY_CURRENT_USER\\Software\\TypingMaster-Flatpak]\n"SettingsVersion"="%s"\n' \
        "$settings_sum" >> "$reg_tmp"
    wine regedit /S "$reg_tmp"
    rm -f "$reg_tmp"
fi

# Install or update the program files in the prefix.
if [ ! -f "$STAMP_FILE" ] || [ "$(cat "$STAMP_FILE")" != "$PACKAGE_STAMP" ]; then
    log "installing program files ($PACKAGE_STAMP)"
    mkdir -p "$INSTALL_DIR"
    # Remove files an earlier package shipped but this one doesn't.
    # Files the app created itself were never in the list and are kept.
    if [ -f "$FILES_LIST" ]; then
        LC_ALL=C comm -23 "$FILES_LIST" "$PACKAGED_DIR/.package-files" |
        while IFS= read -r f; do
            rm -f -- "$INSTALL_DIR/$f"
        done
    fi
    # Overwrite packaged files, keep anything else the app wrote there.
    cp -R "$PACKAGED_DIR/." "$INSTALL_DIR/"
    chmod -R u+w "$INSTALL_DIR"
    rm -f "$INSTALL_DIR/.package-build-id" "$INSTALL_DIR/.package-files"
    cp "$PACKAGED_DIR/.package-files" "$FILES_LIST"
    printf '%s\n' "$PACKAGE_STAMP" > "$STAMP_FILE"
fi

# Default workstation settings for Linux, in
#   %APPDATA%\TypingMaster11\<COMPUTERNAME>.wk10
# Keys are only added when missing, so the user's own later choices stay.
#   DpiAlertIsShown=1  don't show the Windows display-scaling hint
#   FullScreen=0       start windowed
WK10_DIR_NAME=TypingMaster11
WK10_DEFAULTS="DpiAlertIsShown=1 FullScreen=0"

# Wine's computer name (= GetComputerName in the app), read from the registry
# so no extra Wine start is needed.
computer_name() {
    sed -n '/^\[System\\\\ControlSet001\\\\Control\\\\ComputerName\\\\ComputerName\]/,/^\[/ s/^"ComputerName"="\([^"]*\)".*/\1/p' \
        "$WINEPREFIX/system.reg" | head -1
}

apply_wk10_defaults() {
    name="$(computer_name)"
    [ -n "$name" ] || { log "computer name not found, skipping .wk10 defaults"; return 0; }
    dir="$WINEPREFIX/drive_c/users/${USER:-$(id -un)}/AppData/Roaming/$WK10_DIR_NAME"
    file="$dir/$name.wk10"
    mkdir -p "$dir"
    # The app writes CRLF lines; make sure an existing file ends with one.
    if [ -s "$file" ] && [ "$(tail -c 1 "$file" | od -An -c | tr -d ' ')" != '\n' ]; then
        printf '\r\n' >> "$file"
    fi
    for kv in $WK10_DEFAULTS; do
        if ! grep -qi "^${kv%%=*}=" "$file" 2>/dev/null; then
            printf '%s\r\n' "$kv" >> "$file"
        fi
    done
}
apply_wk10_defaults

# Apply the DPI (only when it changed: writing the registry costs a second).
dpi="$(wanted_dpi)"
if [ "$(user_reg_value 'Control Panel\\Desktop' LogPixels)" != "$(printf 'dword:%08x' "$dpi")" ]; then
    log "setting display scale to $dpi DPI ($((dpi * 100 / 96)) %)"
    wine reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d "$dpi" /f >/dev/null
fi

cd "$INSTALL_DIR"
exec wine "$APP_EXE" "$@"
