#!/usr/bin/env bash
# SpotX + Spicetify All-in-One Automated Installer (Linux Edition)
# Supports Spotify 1.2.x & 1.3.x (Rspack, tested 1.3.4)
# Project: https://github.com/Maolaohei/spotx-spicetify-fusion
# Upstream: https://github.com/ZGQ-inc/spotx-spicetify-fusion (MIT)
# Telegram (upstream community): https://t.me/ZGQinc
#
# Run `bash install.sh --verify-only` to check the upstream bypass rules against
# the current SpotX-Bash / Spicetify / Marketplace installers without touching
# the system.

set -e

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

VERIFY_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --verify-only) VERIFY_ONLY=1 ;;
        --help|-h)
            echo "Usage: install.sh [--verify-only]"
            exit 0
            ;;
    esac
done

# This fork is the project the installer, the hotfix and the docs all point to.
FUSION_REPO_URL="https://github.com/Maolaohei/spotx-spicetify-fusion"
FUSION_REPO_RAW="https://raw.githubusercontent.com/Maolaohei/spotx-spicetify-fusion/main"

# Spicetify refuses to run with root privileges (it can make Spotify show a
# black window). This script calls sudo where it needs system access, so it must
# be started as a normal user.
if [ "$(id -u)" -eq 0 ]; then
    echo -e "${RED}[X] Do not run this installer as root: Spicetify refuses to run with root privileges.${NC}" >&2
    echo -e "${YELLOW}    Re-run as your normal user (the script calls sudo where needed).${NC}" >&2
    exit 1
fi

CHECKS_PASSED=0
CHECKS_FAILED=0

check_ok() {
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
    [ "$VERIFY_ONLY" -eq 1 ] && echo -e "  ${GREEN}[ok]${NC}   $1"
    return 0
}

check_fail() {
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
    echo -e "  ${RED}[FAIL]${NC} $1" >&2
    return 0
}

check() {
    if [ "$1" -eq 0 ]; then check_ok "$2"; else check_fail "$2"; fi
}

echo -e "${CYAN} SpotX + Spicetify All-in-One Automated Installer (Linux)       ${NC}"
echo -e "${CYAN} Supports Spotify 1.2.x & 1.3.x (Rspack Architecture, tested 1.3.4) ${NC}"
echo -e "${CYAN} GitHub: ${FUSION_REPO_URL}            ${NC}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

fetch() {
    # fetch <url> <outfile>
    curl -fsSL --retry 3 --retry-delay 2 "$1" -o "$2"
}

# ---------------------------------------------------------------------------
# Dependency preflight: download the upstream installers and neutralise their
# interactive prompts. Every bypass is verified; drift fails loudly instead of
# hanging the unattended install.
# ---------------------------------------------------------------------------
echo -e "${YELLOW}[0/7] Verifying upstream dependency bypasses...${NC}"

SPOTX_SH="$WORKDIR/spotx.sh"
SPICETIFY_SH="$WORKDIR/spicetify-install.sh"
MARKETPLACE_SH="$WORKDIR/marketplace-install.sh"

if ! fetch "https://raw.githubusercontent.com/SpotX-Official/SpotX-Bash/main/spotx.sh" "$SPOTX_SH"; then
    check_fail "could not download SpotX-Bash"
fi
if ! fetch "https://raw.githubusercontent.com/spicetify/cli/main/install.sh" "$SPICETIFY_SH"; then
    check_fail "could not download the Spicetify CLI installer"
fi
if ! fetch "https://raw.githubusercontent.com/spicetify/marketplace/main/resources/install.sh" "$MARKETPLACE_SH"; then
    check_fail "could not download the Marketplace installer"
fi

# SpotX-Bash: make sure every flag used below still exists (its option list is
# printed from the script itself).
for flag in --noninteractive --devmode --force; do
    if grep -q -- "$flag" "$SPOTX_SH"; then
        check_ok "SpotX-Bash supports $flag"
    else
        check_fail "SpotX-Bash no longer documents $flag"
    fi
done

# Spicetify CLI installer: re-runs ask "Spicetify is already installed. Do you
# want to fix your installation? (Y/n)" and read from /dev/tty. Answer "n" so
# the latest build is always installed; /dev/tty reads must never survive.
if grep -q 'read -r choice < /dev/tty' "$SPICETIFY_SH"; then
    sed -i 's#read -r choice < /dev/tty#choice=n#' "$SPICETIFY_SH"
fi
if grep -q 'read -r choice < /dev/tty' "$SPICETIFY_SH"; then
    check_fail "Spicetify installer still reads from /dev/tty"
else
    check_ok "Spicetify installer runs without a tty prompt"
fi

# The Marketplace prompt is stripped; Marketplace is installed explicitly later.
if grep -q 'Do you want to install spicetify Marketplace' "$SPICETIFY_SH"; then
    check_ok "Spicetify Marketplace prompt located"
else
    check_fail "Spicetify Marketplace prompt marker changed"
fi
sed -i '/Do you want to install spicetify Marketplace/,$d' "$SPICETIFY_SH"
if grep -q 'Do you want to install spicetify Marketplace' "$SPICETIFY_SH"; then
    check_fail "Spicetify Marketplace prompt was not stripped"
else
    check_ok "Spicetify Marketplace prompt stripped"
fi

if sh -n "$SPICETIFY_SH" 2>/dev/null; then
    check_ok "patched Spicetify installer parses"
else
    check_fail "patched Spicetify installer has a shell syntax error"
fi
if sh -n "$MARKETPLACE_SH" 2>/dev/null; then
    check_ok "Marketplace installer parses"
else
    check_fail "Marketplace installer has a shell syntax error"
fi

if [ "$CHECKS_FAILED" -gt 0 ]; then
    echo -e "${RED}[-] Upstream bypass checks failed ($CHECKS_FAILED). The dependency scripts changed.${NC}" >&2
    echo -e "${YELLOW}    Re-run after the next release, or report it: ${FUSION_REPO_URL}/issues${NC}" >&2
    exit 1
fi

if [ "$VERIFY_ONLY" -eq 1 ]; then
    echo -e "${GREEN}[+] Upstream bypass self-check passed ($CHECKS_PASSED checks).${NC}"
    exit 0
fi

# 1. Install or update Spotify on Debian/Ubuntu derivatives if apt is available
if command -v apt-get >/dev/null 2>&1; then
    echo -e "${YELLOW}[1/7] Setting up official Spotify APT repository...${NC}"
    sudo mkdir -p /etc/apt/keyrings
    curl -sS https://download.spotify.com/debian/pubkey_C85668DF69375001.gpg | sudo gpg --dearmor --yes -o /etc/apt/keyrings/spotify.gpg 2>/dev/null || true
    echo "deb [signed-by=/etc/apt/keyrings/spotify.gpg] https://repository.spotify.com stable non-free" | sudo tee /etc/apt/sources.list.d/spotify.list > /dev/null

    echo -e "${YELLOW}[1/7] Installing / Updating spotify-client...${NC}"
    sudo apt-get update -qq || true
    sudo apt-get install -y spotify-client || true
fi

# 2. Adjust Spotify directory permissions for Spicetify
linux_search_path() {
    local paths=("/opt" "/usr/share" "/usr/lib" "/var/lib/flatpak" "$HOME/.local/share")
    for path in "${paths[@]}"; do
        installPath=$(find "${path}" -type f -path "*/spotify*Apps/*" -not -path "*snap*" -name "xpui.spa" -print -quit 2>/dev/null | rev | cut -d/ -f3- | rev || true)
        if [[ -n "${installPath}" ]]; then
            return 0
        fi
    done
    return 1
}

echo -e "${YELLOW}[2/7] Configuring Spotify directory permissions...${NC}"
if linux_search_path; then
    echo -e "${GREEN}[+] Found Spotify path at: ${installPath}${NC}"
    sudo chmod a+wr "${installPath}" || true
    sudo chmod a+wr "${installPath}/Apps" -R || true
else
    echo -e "${YELLOW}[!] Warning: Spotify directory not auto-detected. Proceeding with standard paths.${NC}"
fi

# 3. Install SpotX-Bash
#    -e is intentionally NOT passed: SpotX-Bash's -e/--noexp *excludes*
#    experimental features, while the Windows installer enables them.
echo -e "${YELLOW}[3/7] Installing SpotX-Bash...${NC}"
(curl -sSL https://raw.githubusercontent.com/SpotX-Official/SpotX-Bash/main/spotx.sh | bash -s -- --noninteractive -d -f) || true

# 4. Install Spicetify CLI (using the verified, prompt-free copy from step 0)
echo -e "${YELLOW}[4/7] Installing Spicetify CLI...${NC}"
sh "$SPICETIFY_SH" || true
export PATH="$HOME/.spicetify:$PATH"

# 5. Pre-launch Spotify, auto-grant local network permission, and install Marketplace
echo -e "${YELLOW}[5/7] Pre-launching Spotify, granting permissions, and installing Marketplace...${NC}"

grant_permissions() {
    python3 -c '
import json, os, glob
pref_patterns = [
    os.path.expanduser("~/.config/spotify/**/Preferences"),
    os.path.expanduser("~/.local/share/spotify/**/Preferences")
]
for pat in pref_patterns:
    for p in glob.glob(pat, recursive=True):
        try:
            with open(p, "r", encoding="utf-8") as f:
                data = json.load(f)
            prof = data.setdefault("profile", {})
            cs = prof.setdefault("content_settings", {})
            exc = cs.setdefault("exceptions", {})
            grant = {"https://login.app.spotify.com:443,*": {"setting": 1}}
            exc["local_network_access"] = grant
            exc["local_network"] = grant
            exc["loopback_network"] = grant
            d_vals = data.setdefault("default_content_setting_values", {})
            d_vals["local_network_access"] = 1
            d_vals["local_network"] = 1
            prof.setdefault("default_content_setting_values", {})["local_network_access"] = 1
            prof.setdefault("default_content_setting_values", {})["local_network"] = 1
            with open(p, "w", encoding="utf-8") as f:
                json.dump(data, f)
        except Exception:
            pass
' 2>/dev/null || true
}

# Pre-configure Chromium Preferences before starting
grant_permissions

# Launch Spotify in background to initialize browser cache and local database
echo -e "${CYAN}  -> Launching Spotify to initialize profile and runtime...${NC}"
spotify >/dev/null 2>&1 &
SP_PID=$!
sleep 3

# Grant permissions while running
grant_permissions

# Auto-allow / activate Allow button if xdotool is available
if command -v xdotool >/dev/null 2>&1; then
    xdotool search --name "Spotify" windowactivate key Return 2>/dev/null || true
fi

# Wait 5 seconds as requested
echo -e "${CYAN}  -> Waiting 5 seconds before applying Marketplace...${NC}"
sleep 5

# Terminate Spotify cleanly so Spicetify can patch files without locking conflicts
kill -9 "$SP_PID" 2>/dev/null || true
killall -9 spotify 2>/dev/null || true
sleep 2

# Grant permissions again after exit
grant_permissions

# Install Spicetify Marketplace. Current installers are prompt-free, but keep
# feeding "Y" so a re-introduced prompt cannot stall the unattended install.
echo -e "${CYAN}  -> Installing Spicetify Marketplace...${NC}"
(yes Y | sh "$MARKETPLACE_SH") || true

# 6. Configure Spicetify with Marketplace
echo -e "${YELLOW}[6/7] Configuring Spicetify with Marketplace...${NC}"
spicetify config custom_apps marketplace || true
spicetify apply || true

# 7. Apply the project's compatibility hotfix, fetched from this repository so
#    the installer and fix.sh can never drift apart
echo -e "${YELLOW}[7/7] Applying SpotX + Spicetify compatibility hotfix...${NC}"

FIX_SH="$WORKDIR/fix.sh"
if fetch "$FUSION_REPO_RAW/fix.sh" "$FIX_SH"; then
    bash "$FIX_SH" || true
else
    echo -e "${YELLOW}[!] Could not fetch the hotfix from ${FUSION_REPO_RAW}/fix.sh${NC}" >&2
    echo -e "${YELLOW}    Run it manually after the installation:${NC}" >&2
    echo -e "${YELLOW}    curl -fsSL ${FUSION_REPO_RAW}/fix.sh | bash${NC}" >&2
fi

# Launch Spotify on Linux if available
if command -v spotify >/dev/null 2>&1; then
    echo -e "${CYAN}  -> Launching patched Spotify...${NC}"
    spotify >/dev/null 2>&1 &
fi

echo -e "${GREEN} Linux installation and compatibility hotfix finished!         ${NC}"
echo -e "${GREEN} Enjoy Spotify with SpotX adblocking and Spicetify custom apps! ${NC}"
