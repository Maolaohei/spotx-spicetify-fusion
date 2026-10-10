#!/usr/bin/env bash
# SpotX + Spicetify All-in-One Automated Installer (Linux Edition)
# Supports Spotify 1.2.x & 1.3.x (Rspack, tested 1.3.4)
# GitHub: https://github.com/ZGQ-inc/spotx-spicetify-fusion
# Telegram: https://t.me/ZGQinc
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
echo -e "${CYAN} GitHub: https://github.com/ZGQ-inc/spotx-spicetify-fusion            ${NC}"

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
    echo -e "${YELLOW}    Re-run after the next release, or report it: https://github.com/ZGQ-inc/spotx-spicetify-fusion/issues${NC}" >&2
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

# 7. Apply Unified Compatibility Hotfix (Embedded)
#    Keep this in sync with fix.sh - it is the same patch pipeline, executed
#    inline so the one-liner installer stays self-contained.
echo -e "${YELLOW}[7/7] Applying SpotX + Spicetify compatibility hotfix...${NC}"

python3 - << 'EOF'
import os
import sys
import glob
import re
import json
import datetime

themed_dir = os.path.expanduser("~/.config/spicetify/Extracted/Themed/xpui")
raw_dir = os.path.expanduser("~/.config/spicetify/Extracted/Raw/xpui")

search_paths = ["/opt/spotify", "/usr/share/spotify", "/usr/lib/spotify", os.path.expanduser("~/.local/share/spotify")]
target_dirs = [d for d in [themed_dir, raw_dir] if os.path.isdir(d)]
for sp in search_paths:
    app_xpui = os.path.join(sp, "Apps", "xpui")
    if os.path.isdir(app_xpui):
        target_dirs.append(app_xpui)

results = []

def add_result(patch, status, detail=""):
    results.append({"patch": patch, "status": status, "detail": detail})

def insert_after_once(content, anchor, insert):
    m = re.search(anchor, content)
    if not m:
        return content, False
    return content[:m.end()] + insert + content[m.end():], True

for xpui_dir in target_dirs:
    xpui_js = os.path.join(xpui_dir, "xpui.js")
    wrapper_js = os.path.join(xpui_dir, "helper", "spicetifyWrapper.js")
    route_files = []
    custom_apps = []

    if os.path.exists(xpui_js):
        with open(xpui_js, "r", encoding="utf-8") as f:
            content = f.read()

        patched = False

        # B1: legacy Spicetify semver bug injecting broken snackbar statement
        bad_snackbar = "Spicetify.Snackbar.enqueueImageSnackbar="
        if bad_snackbar in content:
            content = content.replace(bad_snackbar, "")
            patched = True
            add_result("B1: Snackbar SyntaxError", "applied", "removed legacy enqueueImageSnackbar injection")
        else:
            add_result("B1: Snackbar SyntaxError", "not-needed", "not present (Spicetify >= 2.45 bundles are clean)")

        # B2: legacy useNavigateStable safe fallback
        nav = re.search(r"return\(0,([A-Za-z_$][\w$]*)\.useNavigateStable\)\(\)", content)
        if nav:
            module = nav.group(1)
            safe_nav = ("return(()=>{try{return(0," + module + ".useNavigateStable)()}catch(err){"
                        "return Spicetify?.Platform?.History?.push||Spicetify?.Platform?.History?.navigate||(()=>({}))}})()")
            content = content[:nav.start()] + safe_nav + content[nav.end():]
            patched = True
            add_result("B2: useNavigateStable fallback", "applied", "wrapped (0,%s.useNavigateStable)()" % module)
        else:
            add_result("B2: useNavigateStable fallback", "not-needed", "anchor absent (fixed on this build)")

        # B3: legacy RegistryContext safe guard (Spotify 1.3.0 only)
        old_reg = "(0,i.useContext)(e.yv)"
        safe_reg = "((0,i.useContext)(e.yv)||Spicetify?.Platform?.Registry||{entries:new Map()})"
        if old_reg in content and safe_reg not in content:
            content = content.replace(old_reg, safe_reg)
            patched = True
            add_result("B3: RegistryContext guard", "applied", "legacy 1.3.0 anchor found")
        else:
            add_result("B3: RegistryContext guard", "not-needed", "anchor absent (fixed on this build)")

        # B4: Custom Apps chunk registration (.u map, miniCssF map, CSS allowlist)
        route_files = sorted(glob.glob(os.path.join(xpui_dir, "spicetify-routes-*.js")))
        custom_apps = []
        for rf in route_files:
            bname = os.path.basename(rf)
            if bname.startswith("spicetify-routes-") and bname.endswith(".js"):
                custom_apps.append(bname[len("spicetify-routes-"):-3])

        if not custom_apps:
            add_result("B4: Custom Apps chunk map", "skipped", "no spicetify-routes-*.js bundles found")
        else:
            u_anchor = r'\.u=\w+=>""\+\(\(\{'
            css_anchor = r'\.miniCssF=\w+=>""\+\(\(\{'
            allow_anchor = r'0!==\w+\[e\]&&\(\{'
            app_id = 1001
            mapped_by_spicetify = 0
            injected = 0

            for app in custom_apps:
                bundle = "spicetify-routes-" + app
                name_key = '"%s"' % bundle
                already_mapped = (":" + name_key) in content
                if not already_mapped:
                    entry = '%d:%s,' % (app_id, name_key)
                    content, ok = insert_after_once(content, u_anchor, entry)
                    if ok:
                        patched = True
                        injected += 1
                    if re.search(css_anchor, content):
                        content, _ = insert_after_once(content, css_anchor, entry)
                else:
                    mapped_by_spicetify += 1

                css_allowed = (name_key + ":1") in content or ("%d:1" % app_id) in content
                if not css_allowed:
                    content, ok = insert_after_once(content, allow_anchor, "%d:1," % app_id)
                    if ok:
                        patched = True
                        injected += 1
                app_id += 1

            if injected:
                add_result("B4: Custom Apps chunk map", "applied",
                           "injected %d map entry/entries for %d app(s)" % (injected, len(custom_apps)))
            elif mapped_by_spicetify == len(custom_apps):
                add_result("B4: Custom Apps chunk map", "not-needed",
                           "Spicetify registered all %d app(s) natively" % len(custom_apps))
            elif not re.search(u_anchor, content):
                add_result("B4: Custom Apps chunk map", "failed",
                           "no Rspack .u loader found; Spotify bundle shape changed")
            else:
                add_result("B4: Custom Apps chunk map", "applied", "chunk map already present")

        if patched:
            with open(xpui_js, "w", encoding="utf-8") as f:
                f.write(content)
            print("  [SUCCESS] Patched %s" % xpui_js)
        else:
            print("  [INFO] %s needs no patches on this build." % xpui_js)

    # C: helper/spicetifyWrapper.js
    if os.path.exists(wrapper_js):
        with open(wrapper_js, "r", encoding="utf-8") as f:
            wcontent = f.read()
        wpatched = False

        if re.search(r"rspackChunk(?!client_web)", wcontent):
            add_result("C1: rspackChunk hook", "not-needed", "wrapper already negotiates window.rspackChunk")
        else:
            target_chunk = "window?.webpackChunkclient_web||window?.rspackChunkclient_web"
            fixed_chunk = target_chunk + "||window?.rspackChunk"
            if target_chunk in wcontent:
                wcontent = wcontent.replace(target_chunk, fixed_chunk)
                wpatched = True
                add_result("C1: rspackChunk hook", "applied", "legacy wrapper patched")
            else:
                add_result("C1: rspackChunk hook", "failed", "wrapper shape unknown; neither native nor legacy anchor found")

        legacy_pattern = r'\(\(\)=>\{let u=f\.find\(m=>m\?\.NQG\?\.PLAYLIST_V2\);.*?Spicetify\.URI=s\}\}\)\(\)\,?'
        has_modern_uri = "URI.fromString" in wcontent or "waitForURI" in wcontent
        if has_modern_uri:
            if "Spicetify.URI=s" in wcontent:
                cleaned = re.sub(legacy_pattern, "", wcontent)
                if cleaned != wcontent:
                    wcontent = cleaned
                    wpatched = True
                    add_result("C2: Spicetify.URI export", "applied",
                               "removed obsolete legacy URI injection left by older fix.sh runs")
                else:
                    add_result("C2: Spicetify.URI export", "skipped", "legacy marker present but could not be removed cleanly")
            else:
                add_result("C2: Spicetify.URI export", "not-needed", "wrapper resolves URI natively")
        else:
            uri_target = "Spicetify.React=f.find(m=>m?.useMemo),"
            uri_inject = ('(()=>{let u=f.find(m=>m?.NQG?.PLAYLIST_V2);if(u){let s=u.o_h("spotify:track:4uLU6hMCjMI75M1A2tKUQC")?.constructor;'
                          'if(s){s.Type=u.NQG,s.from=u.o_h,s.fromString=u.Lce,s.idToHex=u.DY5,s.hexToId=u.dx2,Spicetify.URI=s}}})(),')
            if uri_target in wcontent and "Spicetify.URI=s" not in wcontent:
                wcontent = wcontent.replace(uri_target, uri_target + uri_inject)
                wpatched = True
                add_result("C2: Spicetify.URI export", "applied", "legacy wrapper patched")
            else:
                add_result("C2: Spicetify.URI export", "failed", "wrapper shape unknown; legacy anchor not found")

        if wpatched:
            with open(wrapper_js, "w", encoding="utf-8") as f:
                f.write(wcontent)
            print("  [SUCCESS] Patched %s" % wrapper_js)
        else:
            print("  [INFO] %s needs no patches on this build." % wrapper_js)
    else:
        add_result("C1/C2: spicetifyWrapper.js", "skipped",
                   "helper/spicetifyWrapper.js not found (set expose_apis=1 and run 'spicetify apply')")

    # D: push headers in spicetify-routes-*.js
    if custom_apps:
        header_fixed = 0
        header_native = 0
        for rf in route_files:
            with open(rf, "r", encoding="utf-8") as f:
                rc = f.read()
            push_idx = rc.find(").push([[")
            if not (0 < push_idx < 300):
                continue
            head = rc[:push_idx]
            if re.search(r"rspackChunk(?!client_web)", head):
                header_native += 1
                continue
            if "webpackChunkclient_web" in head:
                fixed_head = '(("u">typeof self?self:global).rspackChunk||=[]' + rc[push_idx:]
                with open(rf, "w", encoding="utf-8") as f:
                    f.write(fixed_head)
                header_fixed += 1
        if header_fixed:
            add_result("D: route push headers", "applied", "fixed %d bundle(s)" % header_fixed)
        elif header_native:
            add_result("D: route push headers", "not-needed", "%d bundle(s) already negotiate rspackChunk" % header_native)
        else:
            add_result("D: route push headers", "skipped", "no route bundle matched the push header shape")
    else:
        add_result("D: route push headers", "skipped", "no spicetify-routes-*.js bundles found")

failed = [r for r in results if r["status"] == "failed"]
if failed:
    print("  [!] %d patch(es) could not be verified - the Spotify bundle probably changed." % len(failed))
    print("      Re-run this script after the next SpotX/Spicetify release, or report it:")
    print("      https://github.com/ZGQ-inc/spotx-spicetify-fusion/issues")
EOF

# Launch Spotify on Linux if available
if command -v spotify >/dev/null 2>&1; then
    echo -e "${CYAN}  -> Launching patched Spotify...${NC}"
    spotify >/dev/null 2>&1 &
fi

echo -e "${GREEN} Linux installation and compatibility hotfix finished!         ${NC}"
echo -e "${GREEN} Enjoy Spotify with SpotX adblocking and Spicetify custom apps! ${NC}"
