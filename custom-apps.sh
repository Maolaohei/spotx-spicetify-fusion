#!/usr/bin/env bash
# SpotX + Spicetify Fusion - Curated Custom Apps & Extensions Installer (Linux Edition)
# Project: https://github.com/Maolaohei/spotx-spicetify-fusion
# Upstream: https://github.com/ZGQ-inc/spotx-spicetify-fusion (MIT)
#
# Notes on the curated set:
#   - Enhancify  : latest upstream release (flat zip -> CustomApps/Enhancify)
#   - Stats      : latest upstream release; the legacy resize-observer patch is
#                  applied only when the bundle still contains the old anchor
#   - lyrics-plus: ships inside the Spicetify CLI, so it updates with the CLI
# The Rspack compatibility patching is delegated to the project's fix.sh
# instead of being duplicated here (fix.sh probes each patch and reports).

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

FUSION_REPO_URL="https://github.com/Maolaohei/spotx-spicetify-fusion"
FUSION_REPO_RAW="https://raw.githubusercontent.com/Maolaohei/spotx-spicetify-fusion/main"

# Spicetify refuses to run with root privileges (it can make Spotify show a
# black window), so fail with instructions here.
if [ "$(id -u)" -eq 0 ]; then
    echo -e "${RED}[X] Running as root - Spicetify refuses to run with root privileges.${NC}" >&2
    echo -e "${YELLOW}    Re-run this script as your normal user (no sudo).${NC}" >&2
    exit 1
fi

echo -e "${CYAN} SpotX + Spicetify Fusion - Custom Apps & Extensions Installer${NC}"
echo -e "${CYAN} Curated: Enhancify, Stats (on-demand patch), lyrics-plus & Extensions${NC}"
echo -e "${CYAN} Project: ${FUSION_REPO_URL}${NC}"

export PATH="$HOME/.spicetify:$PATH"

if ! command -v spicetify >/dev/null 2>&1; then
    echo -e "${RED}[X] spicetify CLI not found! Please run install.sh first.${NC}"
    exit 1
fi

APP_PATH="${XDG_CONFIG_HOME:-$HOME/.config}/spicetify/CustomApps"
EXT_PATH="${XDG_CONFIG_HOME:-$HOME/.config}/spicetify/Extensions"
mkdir -p "$APP_PATH" "$EXT_PATH"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

latest_tag() {
    curl -s "$1" | grep -o '"tag_name": *"[^"]*"' | head -n1 | cut -d '"' -f 4 || true
}

echo -e "${YELLOW}Installing Enhancify...${NC}"
enhancify_url=$(curl -s https://api.github.com/repos/ECE49595-Team-6/EnhancifyInstall/releases/latest \
    | grep -o 'https://[^"]*\.zip' | head -n1 || true)
if [[ -n "$enhancify_url" ]]; then
    mkdir -p "$APP_PATH/Enhancify"
    curl -fsSL "$enhancify_url" -o "$TMP_DIR/enhancify.zip"
    unzip -qo "$TMP_DIR/enhancify.zip" -d "$APP_PATH/Enhancify"
    echo -e "${GREEN}  [+] Enhancify $(latest_tag https://api.github.com/repos/ECE49595-Team-6/EnhancifyInstall/releases/latest) installed successfully.${NC}"
else
    echo -e "${YELLOW}  [!] Enhancify: could not resolve a .zip release asset (GitHub API rate limit?).${NC}"
fi

echo -e "${YELLOW}Installing Stats...${NC}"
stats_url=$(curl -s https://api.github.com/repos/harbassan/spicetify-apps/releases \
    | grep -o 'https://[^"]*stats[^"]*\.zip' | head -n1 || true)
if [[ -n "$stats_url" ]]; then
    curl -fsSL "$stats_url" -o "$TMP_DIR/stats.zip"
    unzip -qo "$TMP_DIR/stats.zip" -d "$APP_PATH"
    echo -e "${GREEN}  [+] Stats $(latest_tag https://api.github.com/repos/harbassan/spicetify-apps/releases) installed successfully.${NC}"

    # Legacy layout patch: newer Stats resolves its own resize host, so this is
    # only applied while the old anchor is still present in the bundle.
    stats_index="$APP_PATH/stats/index.js"
    if [[ -f "$stats_index" ]]; then
        if ! grep -qF '.Root__main-view .os-resize-observer-host' "$stats_index"; then
            echo -e "${GREEN}  [=] Stats layout patch not needed (this build uses a different resize strategy).${NC}"
        elif ! command -v python3 >/dev/null 2>&1; then
            echo -e "${YELLOW}  [!] Stats layout anchor present but python3 is missing - patch skipped.${NC}"
        else
            python3 - "$stats_index" <<'PY'
import io
import sys

path = sys.argv[1]
original = ('document.querySelector(".Root__main-view .os-resize-observer-host") '
            '?? document.querySelector(".Root__main-view .os-size-observer")')
replacement = original + ' ?? document.querySelector(".Root__main-view")'

content = io.open(path, encoding="utf-8").read()
if replacement in content:
    print("  [=] Stats layout patch already applied.")
elif original in content:
    io.open(path, "w", encoding="utf-8").write(content.replace(original, replacement, 1))
    print("  [+] Stats resize observer patched for the modern Spotify UI.")
else:
    print("  [!] Stats layout anchor found but its shape changed - patch skipped (nothing written).")
PY
        fi
    fi
else
    echo -e "${YELLOW}  [!] Stats: could not resolve a stats*.zip release asset (GitHub API rate limit?).${NC}"
fi

echo -e "${YELLOW}Configuring Spicetify custom apps and extensions...${NC}"
CONFIG_OK=1
run_spicetify() {
    if ! spicetify "$@"; then
        CONFIG_OK=0
        echo -e "${YELLOW}  [!] spicetify $* failed${NC}" >&2
    fi
}
run_spicetify config custom_apps Enhancify stats lyrics-plus
run_spicetify config extensions bookmark.js fullAppDisplay.js keyboardShortcut.js loopyLoop.js popupLyrics.js shuffle+.js trashbin.js webnowplaying.js
run_spicetify config sidebar_config 0
run_spicetify apply

echo -e "${YELLOW}Applying the project's compatibility hotfix...${NC}"
FIX_SH="$TMP_DIR/fix.sh"
HOTFIX_OK=1
if curl -fsSL "$FUSION_REPO_RAW/fix.sh" -o "$FIX_SH"; then
    if ! bash "$FIX_SH"; then
        HOTFIX_OK=0
        echo -e "${YELLOW}  [!] The hotfix reported an error (is Spotify installed? run install.sh first).${NC}" >&2
    fi
else
    HOTFIX_OK=0
    echo -e "${YELLOW}  [!] Could not fetch the hotfix from ${FUSION_REPO_RAW}/fix.sh${NC}" >&2
    echo -e "${YELLOW}      Run it manually: curl -fsSL ${FUSION_REPO_RAW}/fix.sh | bash${NC}" >&2
fi

if command -v spotify >/dev/null 2>&1; then
    killall -9 spotify 2>/dev/null || true
    spotify >/dev/null 2>&1 &
fi

if [[ "$CONFIG_OK" -eq 1 && "$HOTFIX_OK" -eq 1 ]]; then
    echo -e "${GREEN} Custom apps and extensions installed and patched successfully!${NC}"
else
    echo -e "${YELLOW} Finished with errors - run install.sh first if Spotify/Spicetify are missing, then re-run this script.${NC}"
    exit 1
fi
