#!/usr/bin/env bash
# SpotX + Spicetify Unified Compatibility Hotfix Script (Linux Edition)
# Supports Spotify 1.2.x (Webpack) & 1.3.x+ (Rspack, tested 1.3.4)
# GitHub: https://github.com/ZGQ-inc/spotx-spicetify-fusion
#
# Environment:
#   SPOTIFY_DIR=/path/to/spotify   override client autodetection (testing/portable)
#   SPICETIFY_CONFIG=/path        override spicetify config dir
#   REPORT_PATH=/path/report.json write a JSON patch report

set -e

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN} SpotX + Spicetify Unified Compatibility Hotfix (Linux v2.2)   ${NC}"
echo -e "${CYAN} Supports Spotify 1.2.x (Webpack) & 1.3.x+ (Rspack, tested 1.3.4) ${NC}"
echo -e "${CYAN} GitHub: https://github.com/ZGQ-inc/spotx-spicetify-fusion            ${NC}"

# Terminate running Spotify processes
if pgrep -x "spotify" > /dev/null; then
    echo -e "${YELLOW}[*] Closing running Spotify processes...${NC}"
    killall -9 spotify 2>/dev/null || true
    sleep 1
fi

# Locate Spotify and Spicetify directories on Linux
SPICETIFY_DIR="${SPICETIFY_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/spicetify}"
THEMED_XPUI_DIR="$SPICETIFY_DIR/Extracted/Themed/xpui"
RAW_XPUI_DIR="$SPICETIFY_DIR/Extracted/Raw/xpui"

# Find system Spotify install path
SEARCH_PATHS=("/opt/spotify" "/usr/share/spotify" "/usr/lib/spotify" "$HOME/.local/share/spotify" "/var/lib/flatpak/app/com.spotify.Client/current/active/files/extra/share/spotify")
SPOTIFY_DIR="${SPOTIFY_DIR:-}"
if [ -z "$SPOTIFY_DIR" ]; then
    for p in "${SEARCH_PATHS[@]}"; do
        if [ -f "$p/Apps/xpui.spa" ] || [ -f "$p/spotify" ]; then
            SPOTIFY_DIR="$p"
            break
        fi
    done
fi

echo -e "${GREEN}[+] Spicetify config path: $SPICETIFY_DIR${NC}"
if [ -n "$SPOTIFY_DIR" ]; then
    echo -e "${GREEN}[+] Detected Spotify installation path: $SPOTIFY_DIR${NC}"
fi

# Target directories where xpui.js could exist
TARGET_XPUI_DIRS=()
if [ -d "$THEMED_XPUI_DIR" ]; then
    TARGET_XPUI_DIRS+=("$THEMED_XPUI_DIR")
fi
if [ -d "$RAW_XPUI_DIR" ]; then
    TARGET_XPUI_DIRS+=("$RAW_XPUI_DIR")
fi
if [ -n "$SPOTIFY_DIR" ] && [ -d "$SPOTIFY_DIR/Apps/xpui" ]; then
    TARGET_XPUI_DIRS+=("$SPOTIFY_DIR/Apps/xpui")
fi

if [ ${#TARGET_XPUI_DIRS[@]} -eq 0 ]; then
    echo -e "${YELLOW}[*] Extracted xpui folder not found in cache. Running 'spicetify backup apply'...${NC}"
    if command -v spicetify >/dev/null 2>&1; then
        spicetify backup apply || true
        if [ -d "$THEMED_XPUI_DIR" ]; then
            TARGET_XPUI_DIRS+=("$THEMED_XPUI_DIR")
        fi
    fi
fi

if [ ${#TARGET_XPUI_DIRS[@]} -eq 0 ]; then
    echo -e "${RED}[-] Error: Could not locate xpui.js. Please run 'spicetify backup apply' first.${NC}"
    exit 1
fi

# Snapshot casing: SpotX renames v8_context_snapshot*.bin to V8_context_snapshot*.bin,
# which makes Spicetify's case-sensitive scanner skip the module extraction.
if [ -n "$SPOTIFY_DIR" ] && [ -d "$SPOTIFY_DIR" ]; then
    for f in "$SPOTIFY_DIR"/V8_context_snapshot*.bin; do
        [ -e "$f" ] || continue
        base=$(basename "$f")
        lower="v${base:1}"
        if [ ! -e "$SPOTIFY_DIR/$lower" ]; then
            mv "$f" "$SPOTIFY_DIR/$lower" && echo -e "${GREEN}  [+] Normalized snapshot casing: $lower${NC}"
        fi
    done
fi

# Python 3 helper to execute precise AST/string patching
apply_patch_python() {
    SPOTIFY_DIR="$SPOTIFY_DIR" REPORT_PATH="${REPORT_PATH:-}" python3 - << 'EOF'
import os
import sys
import glob
import json
import datetime
import re

themed_dir = os.path.expanduser("~/.config/spicetify/Extracted/Themed/xpui")
raw_dir = os.path.expanduser("~/.config/spicetify/Extracted/Raw/xpui")
spotify_dir = os.environ.get("SPOTIFY_DIR", "")

target_dirs = [d for d in [themed_dir, raw_dir] if os.path.isdir(d)]
if spotify_dir and os.path.isdir(os.path.join(spotify_dir, "Apps", "xpui")):
    target_dirs.append(os.path.join(spotify_dir, "Apps", "xpui"))

results = []

def add_result(patch, status, detail=""):
    results.append({"patch": patch, "status": status, "detail": detail})

def insert_after_once(content, anchor, insert):
    """Insert text right after the first regex match. Returns (content, True) or (content, False)."""
    import re
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
        import re
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

report_path = os.environ.get("REPORT_PATH", "")
if report_path:
    failed = [r for r in results if r["status"] == "failed"]
    report = {
        "tool": "fix.sh",
        "version": "2.2",
        "timestamp": datetime.datetime.now().isoformat(),
        "spotifyDir": spotify_dir,
        "failed": len(failed),
        "results": results,
    }
    try:
        with open(report_path, "w", encoding="utf-8") as f:
            json.dump(report, f, indent=2)
        print("  [+] Report written to %s" % report_path)
    except Exception as e:
        print("  [-] Could not write report: %s" % e)

failed = [r for r in results if r["status"] == "failed"]
if failed:
    print("  [!] %d patch(es) could not be verified - the Spotify bundle probably changed." % len(failed))
    print("      Re-run this script after the next SpotX/Spicetify release, or report it:")
    print("      https://github.com/ZGQ-inc/spotx-spicetify-fusion/issues")
EOF
}

echo -e "${CYAN}[*] Applying compatibility patches...${NC}"
if command -v python3 >/dev/null 2>&1; then
    apply_patch_python
else
    echo -e "${RED}[-] python3 is required to run the Linux hotfix script.${NC}"
    exit 1
fi

# Re-apply Spicetify to repack xpui.spa on Linux
if command -v spicetify >/dev/null 2>&1; then
    echo -e "${YELLOW}[*] Running 'spicetify apply' to re-bundle xpui.spa...${NC}"
    spicetify apply || true
fi

echo -e "${GREEN} [OK] All SpotX + Spicetify Linux compatibility patches processed!${NC}"
echo -e "${GREEN} Spotify 1.2.x & 1.3.x Rspack, Marketplace & extensions restored!${NC}"
