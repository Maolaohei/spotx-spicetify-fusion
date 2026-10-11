#!/usr/bin/env bash
# SpotX + Spicetify Unified Compatibility Hotfix Script (Linux Edition)
# Supports Spotify 1.2.x (Webpack) & 1.3.x+ (Rspack, tested 1.3.4)
# Project: https://github.com/Maolaohei/spotx-spicetify-fusion
# Upstream: https://github.com/ZGQ-inc/spotx-spicetify-fusion (MIT)
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

# This fork is the project the scripts and the docs all point to.
FUSION_REPO_URL="https://github.com/Maolaohei/spotx-spicetify-fusion"
FUSION_REPO_RAW="https://raw.githubusercontent.com/Maolaohei/spotx-spicetify-fusion/main"

# Directory of this script, when it is run from a checkout (used to pick up the
# bundled i18n dictionary instead of downloading it).
FIX_SH_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    FIX_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

echo -e "${CYAN} SpotX + Spicetify Unified Compatibility Hotfix (Linux v2.2)   ${NC}"
echo -e "${CYAN} Supports Spotify 1.2.x (Webpack) & 1.3.x+ (Rspack, tested 1.3.4) ${NC}"
echo -e "${CYAN} GitHub: ${FUSION_REPO_URL}            ${NC}"

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
    FUSION_REPO_URL="$FUSION_REPO_URL" FUSION_REPO_RAW="$FUSION_REPO_RAW" FIX_SH_DIR="$FIX_SH_DIR" I18N_DIR="${I18N_DIR:-}" SPOTIFY_DIR="$SPOTIFY_DIR" REPORT_PATH="${REPORT_PATH:-}" python3 - << 'EOF'
import os
import sys
import glob
import json
import datetime
import io
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

# E: Chinese UI for Spicetify's helper panels ("Experimental features",
#    "Home config", "Sidebar config"). Spicetify ships them in English only, so
#    the visible labels are translated in both the CLI templates (so
#    `spicetify apply` redeploys the Chinese version) and the deployed copies.
#    Skip with KEEP_ENGLISH=1.
CHINESE_UI = [
    ("expFeatures.js", [
        ("\"Waiting for Spotify to finish loading...\"", "\"正在等待 Spotify 加载完成…\""),
        ("Using fallback mode. Some features may not work.", "正在使用兼容模式，部分功能可能不可用。"),
        ("placeholder=\"Search for a feature\"", "placeholder=\"搜索功能项\""),
        ("\"Experimental features\"", "\"实验性功能\""),
        (">Clear all cached features and preferences<", ">清空已缓存的功能与偏好设置<"),
        (">Reset</button>", ">重置</button>"),
    ]),
    ("homeConfig.js", [
        ("up.innerText = \"Up\";", "up.innerText = \"上移\";"),
        ("down.innerText = \"Down\";", "down.innerText = \"下移\";"),
        ("\"Unstick\" : \"Stick\"", "\"取消置顶\" : \"置顶\""),
        ("\"Unlower\" : \"Lower\"", "\"取消置底\" : \"置底\""),
        ("\"Home config\"", "\"首页排序\""),
    ]),
    ("sidebarConfig.js", [
        ("up.innerText = \"Up\";", "up.innerText = \"上移\";"),
        ("down.innerText = \"Down\";", "down.innerText = \"下移\";"),
        ("\"Unstick\" : \"Stick\"", "\"取消置顶\" : \"置顶\""),
        ("\"Unhide\" : \"Hide\"", "\"取消隐藏\" : \"隐藏\""),
        ("\"Sidebar config\"", "\"侧边栏配置\""),
    ]),
]
ui_state = {"applied": 0, "translated": 0, "files": 0, "drift": [], "feature_labels": 0}

# Inner feature labels: expFeatures.js lists Spotify's own flags with their
# English descriptions. The project ships a name -> Chinese dictionary that is
# injected as a lookup; flags we do not know yet keep their English text.
FEATURE_LABELS = {}

def _load_feature_labels():
    global FEATURE_LABELS
    candidates = []
    i18n_dir = os.environ.get("I18N_DIR", "")
    if i18n_dir:
        candidates.append(os.path.join(i18n_dir, "exp-features.zh.json"))
    script_dir = os.environ.get("FIX_SH_DIR", "")
    if script_dir:
        candidates.append(os.path.join(script_dir, "i18n", "exp-features.zh.json"))
    for path in candidates:
        if os.path.isfile(path):
            with io.open(path, encoding="utf-8") as f:
                FEATURE_LABELS = json.load(f).get("labels", {})
            print("  [+] feature labels: %d entries loaded from %s" % (len(FEATURE_LABELS), path))
            return
    url = os.environ.get("FUSION_REPO_RAW", "") + "/i18n/exp-features.zh.json"
    try:
        import urllib.request
        with urllib.request.urlopen(url, timeout=30) as resp:
            FEATURE_LABELS = json.loads(resp.read().decode("utf-8")).get("labels", {})
        print("  [+] feature labels: %d entries loaded from the project dictionary" % len(FEATURE_LABELS))
    except Exception as exc:
        print("  [~] feature labels: could not load the dictionary (%s)" % exc)

def _js_escape(value):
    out = []
    for ch in value:
        code = ord(ch)
        if ch == '"':
            out.append(chr(92) + '"')
        elif code == 92:
            out.append(chr(92) * 2)
        elif code > 127:
            out.append(chr(92) + "u%04x" % code)
        else:
            out.append(ch)
    return "".join(out)

def _apply_feature_labels(path):
    with io.open(path, encoding="utf-8") as f:
        text = f.read()
    if "zhLabel(" in text:
        ui_state["translated"] += 1
        return
    anchor = "let isFallback = false;"
    row_label = '<label class="col description">${desc}</label>'
    if anchor not in text or row_label not in text:
        ui_state["drift"].append("feature labels in expFeatures.js")
        return
    pairs = ",".join('"%s":"%s"' % (name, _js_escape(FEATURE_LABELS[name])) for name in sorted(FEATURE_LABELS))
    injection = 'const zhLabels={%s};const zhLabel=(name,desc)=>zhLabels[name]||desc;' % pairs
    text = text.replace(anchor, anchor + injection, 1)
    text = text.replace(row_label, '<label class="col description">${zhLabel(name, desc)}</label>')
    with io.open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    ui_state["applied"] += len(FEATURE_LABELS)
    ui_state["feature_labels"] = len(FEATURE_LABELS)

def translate_helpers(helper_dir):
    if not os.path.isdir(helper_dir):
        return
    for fname, edits in CHINESE_UI:
        path = os.path.join(helper_dir, fname)
        if not os.path.isfile(path):
            continue
        ui_state["files"] += 1
        with io.open(path, encoding="utf-8") as f:
            text = f.read()
        pending = [(o, n) for o, n in edits if o in text]
        already = [n for o, n in edits if n in text]
        if not pending:
            if already:
                ui_state["translated"] += 1
            else:
                ui_state["drift"].append(fname)
            continue
        for old, new in pending:
            text = text.replace(old, new)
        with io.open(path, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        ui_state["applied"] += len(pending)
    if FEATURE_LABELS:
        feature_path = os.path.join(helper_dir, "expFeatures.js")
        if os.path.isfile(feature_path):
            _apply_feature_labels(feature_path)

if not os.environ.get("KEEP_ENGLISH"):
    _load_feature_labels()
    template_dir = os.environ.get("JS_HELPER_DIR", "")
    if not template_dir:
        candidate = os.path.expanduser("~/.spicetify/jsHelper")
        if os.path.isdir(candidate):
            template_dir = candidate
    if template_dir:
        translate_helpers(template_dir)

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

        # B2: Spicetify renders its custom-app navigation rows outside Spotify's
        # React providers; two hooks on those rows then throw and take the whole
        # UI down with Spotify's fatal "Something went wrong / Reload page"
        # dialog when switching between the extra apps in the left sidebar:
        #   1. useNavigateStable() -> "must be used within a StableUseNavigateProvider"
        #   2. the RemoteConfig context's default delegate -> "Please wrap your
        #      component in RemoteConfig Provider"
        # Both get provider-independent fallbacks; pages rendered inside the
        # providers behave exactly as before. Replacement is done through
        # functions so no backreference escaping is involved.
        def _nav_fallback(match):
            return ('if(!e)return(...p)=>{try{const h=globalThis.Spicetify?.Platform?.History;'
                    'if(typeof p[0]==="number"){h?.go?.(p[0]);return}'
                    'const f=h?.push??h?.replace;if(typeof f==="function")f(p[0])}catch(_){}};/*fusion:nav*/')

        def _nav_legacy(match):
            return ('return(()=>{try{return(0,' + match.group(1) + '.useNavigateStable)()}catch(err){'
                    'return Spicetify?.Platform?.History?.push||Spicetify?.Platform?.History?.navigate||(()=>({}))}})()')

        def _remote_config(match):
            return ('(0,' + match.group(1) + '.createContext)(new ' + match.group(2) + '.Delegate(()=>({'
                    'getValue:e=>e&&typeof e==="object"&&"default"in e?e.default:void 0,'
                    'toJSON:()=>({}),toBuilder:()=>null})))/*fusion:remoteconfig*/')

        nav_throw = 'if(!e)throw Error("useNavigateStable must be used within a StableUseNavigateProvider");'
        nav_legacy_pattern = r'return\(0,([A-Za-z_$][\w$]*)\.useNavigateStable\)\(\)'
        rc_throw = (r'\(0,(\w+)\.createContext\)\(new ([\w.]+)\.Delegate\('
                    r'\(\)=>\{throw Error\("Please wrap your component in RemoteConfig Provider"\)\}\)\)')

        if '/*fusion:nav*/' in content:
            add_result("B2: useNavigateStable fallback", "not-needed", "fallback already installed")
        elif nav_throw in content:
            content = content.replace(nav_throw, _nav_fallback(None))
            patched = True
            add_result("B2: useNavigateStable fallback", "applied",
                       "hook falls back to Platform.History instead of throwing")
        elif re.search(nav_legacy_pattern, content):
            content = re.sub(nav_legacy_pattern, _nav_legacy, content, count=1)
            patched = True
            add_result("B2: useNavigateStable fallback", "applied", "legacy call site wrapped")
        else:
            add_result("B2: useNavigateStable fallback", "failed", "anchor not found on this build")

        if '/*fusion:remoteconfig*/' in content:
            add_result("B2: RemoteConfig fallback", "not-needed", "fallback already installed")
        elif re.search(rc_throw, content):
            content = re.sub(rc_throw, _remote_config, content, count=1)
            patched = True
            add_result("B2: RemoteConfig fallback", "applied",
                       "missing RemoteConfig provider returns definition defaults instead of throwing")
        else:
            add_result("B2: RemoteConfig fallback", "failed", "anchor not found on this build")

        # B3: the RegistryContext accessor throws when the provider is missing
        # (same nav-row chain as above). Resolve to a no-op store instead.
        reg_throw = ("if(null===e)throw Error(\"Trying to use 'RegistryContext' "
                     "without 'RegistryProvider'!\");")
        reg_replacement = ("if(null===e)e={resolve:()=>({getItem:()=>null,setItem:()=>{},"
                           "getEvents:()=>({addListener(){},removeListener(){}})})};/*fusion:registry*/")
        if '/*fusion:registry*/' in content:
            add_result("B3: RegistryProvider fallback", "not-needed", "fallback already installed")
        elif reg_throw in content:
            content = content.replace(reg_throw, reg_replacement)
            patched = True
            add_result("B3: RegistryProvider fallback", "applied",
                       "missing RegistryProvider resolves to a no-op store instead of throwing")
        else:
            add_result("B3: RegistryProvider fallback", "failed", "anchor not found on this build")

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

        # C2: make the wrapper's URI resolver self-starting (same as fix.ps1).
        # waitForURI() only waits for Spicetify.URI and never creates it, so on
        # builds where nothing else creates it (observed on Spotify 1.3.4) it
        # stays undefined and every extension that touches it throws at load.
        legacy_pattern = r'\(\(\)=>\{let u=f\.find\(m=>m\?\.NQG\?\.PLAYLIST_V2\);.*?Spicetify\.URI=s\}\}\)\(\)\,?'
        if "Spicetify.URI=s" in wcontent:
            cleaned = re.sub(legacy_pattern, "", wcontent)
            if cleaned != wcontent:
                wcontent = cleaned
                wpatched = True
                add_result("C2: legacy URI injection", "applied",
                           "removed the old name-based injection (it skipped Spicetify's isXxx helpers)")
        uri_wait = re.compile(r'if\(!Spicetify\.URI\)\{setTimeout\(\(\)=>[\w$]+\([\w$]+\+1\),Math\.min\(10\*2\*\*Math\.min\([\w$]+,6\),500\)\);return\}')
        if uri_wait.search(wcontent):
            wcontent = uri_wait.sub('if(!Spicetify.URI)Spicetify.URI={};', wcontent, count=1)
            wpatched = True
            add_result("C2: URI self-start", "applied",
                       "resolver creates the placeholder instead of waiting forever")
        elif 'if(!Spicetify.URI)Spicetify.URI={};' in wcontent:
            add_result("C2: URI self-start", "not-needed", "already patched")
        else:
            add_result("C2: URI self-start", "failed",
                       "wrapper anchor not found; URI may stay undefined for extensions")

        nav_anchor = "Spicetify._renderNavLinks=(e,t)=>{"
        if "/*fusion:navlinks*/" in wcontent:
            add_result("C3: nav render guard", "not-needed", "already guarded")
        elif nav_anchor in wcontent and "Spicetify.React.useReducer" in wcontent:
            wcontent = wcontent.replace(nav_anchor, nav_anchor + "if(!Spicetify.React||!Spicetify.React.useReducer)return null;/*fusion:navlinks*/", 1)
            wpatched = True
            add_result("C3: nav render guard", "applied", "no crash before Spicetify.React is bound")
        else:
            add_result("C3: nav render guard", "failed", "_renderNavLinks anchor not found")

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

    # E: Chinese UI in the deployed helper scripts
    if not os.environ.get("KEEP_ENGLISH"):
        translate_helpers(os.path.join(xpui_dir, "helper"))

if os.environ.get("KEEP_ENGLISH"):
    add_result("E: Chinese UI", "skipped", "disabled with KEEP_ENGLISH=1")
elif ui_state["applied"]:
    detail = "%d label(s) translated (templates + deployed)" % ui_state["applied"]
    if ui_state["feature_labels"]:
        detail += ", %d feature labels injected" % ui_state["feature_labels"]
    add_result("E: Chinese UI", "applied", detail)
elif ui_state["translated"]:
    add_result("E: Chinese UI", "not-needed", "helpers are already translated")
elif ui_state["files"] == 0:
    add_result("E: Chinese UI", "skipped", "Spicetify helper scripts not found (features disabled?)")
else:
    add_result("E: Chinese UI", "failed", "helper shape changed: %s" % ", ".join(ui_state["drift"]))

# D2: custom-app compatibility with Spotify 1.3.x. Spicetify's own apps and the
# curated ones were written against 1.2.x DOM ids; on 1.3.x those selectors are
# null, the app throws while rendering, and React replaces the whole UI with
# Spotify's fatal "Something went wrong / Reload page" dialog - reproducible by
# switching between the extra apps in the left sidebar. Legacy selector stays
# first (1.2.x behaviour untouched), the 1.3.x fallback / null guard is appended.
if os.environ.get("SKIP_APP_PATCHES"):
    add_result("D2: custom-app patches", "skipped", "disabled with SKIP_APP_PATCHES=1")
else:
    d2_patches = {
        "topbar": {
            "name": "D2: app top-bar container",
            "marker": "/*fusion:topbar*/",
            "old": 'document.querySelector(".main-topBar-topbarContentWrapper")',
            "old2": ('(document.querySelector(".main-topBar-topbarContentWrapper")'
                     ' || document.querySelector("#global-nav-bar .custom-navlinks-scrollable_container")'
                     ' || document.querySelector("#global-nav-bar") || document.body)/*fusion:topbar*/'),
            "new": ('(document.querySelector(".main-topBar-topbarContentWrapper")'
                    ' || document.querySelector(".main-view-container__scroll-node")'
                    ' || document.querySelector(".main-view-container")'
                    ' || document.querySelector("#main") || document.body)/*fusion:topbar*/'),
        },
        "viewportChain": {
            "name": "D2: lyrics-plus main-view selectors",
            "marker": "/*fusion:vp*/",
            "old": ('document.querySelector(".Root__main-view .os-viewport") ?? '
                    'document.querySelector(".Root__main-view .main-view-container__scroll-node")'),
            "new": ('document.querySelector(".main-view-container__scroll-node") ?? '
                    'document.querySelector(".main-view-container") ?? document.body/*fusion:vp*/'),
        },
        "viewportField": {
            "name": "D2: lyrics-plus viewport field",
            "marker": ('(document.querySelector(".main-view-container .os-viewport") ?? '
                       'document.querySelector(".main-view-container__scroll-node") ?? document.body)'),
            "old": 'document.querySelector(".main-view-container .os-viewport")',
            "new": ('(document.querySelector(".main-view-container .os-viewport") ?? '
                    'document.querySelector(".main-view-container__scroll-node") ?? document.body)'),
        },
        "offsetTop": {
            "name": "D2: lyrics-plus main-view offset",
            "marker": '?? document.querySelector(".main-view-container") ?? document.body).offsetTop',
            "old": 'document.querySelector(".Root__main-view").offsetTop',
            "new": ('((document.querySelector(".Root__main-view") ?? '
                    'document.querySelector(".main-view-container") ?? document.body).offsetTop)'),
        },
        "resizeSel": {
            "name": "D2: app resize-host selector",
            "marker": '.main-view-container__scroll-node, .main-view-container"',
            "old": ('".Root__main-view .os-resize-observer-host, .Root__main-view .os-size-observer, '
                    '.Root__main-view .main-view-container__scroll-node"'),
            "new": ('".Root__main-view .os-resize-observer-host, .Root__main-view .os-size-observer, '
                    '.Root__main-view .main-view-container__scroll-node, .main-view-container__scroll-node, '
                    '.main-view-container"'),
        },
        "resizeInit": {
            "name": "D2: app resize-host null guard",
            "marker": "useState(resizeHost?.clientWidth ?? 0)",
            "old": "useState(resizeHost.clientWidth)",
            "new": "useState(resizeHost?.clientWidth ?? 0)",
        },
        "resizeHandler": {
            "name": "D2: app resize-handler null guard",
            "marker": "setWindowSize(resizeHost?.clientWidth ?? 0)",
            "old": "setWindowSize(resizeHost.clientWidth)",
            "new": "setWindowSize(resizeHost?.clientWidth ?? 0)",
        },
        "observe": {
            "name": "D2: app ResizeObserver guard",
            "marker": "if (resizeHost) observer.observe(resizeHost);",
            "old": "observer.observe(resizeHost);",
            "new": "if (resizeHost) observer.observe(resizeHost);",
        },
    }
    xdg = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    user_apps = os.environ.get("SPICETIFY_APPS_DIR") or os.path.join(xdg, "spicetify", "CustomApps")
    cli_apps = os.environ.get("SPICETIFY_CLI_APPS_DIR") or os.path.expanduser("~/.spicetify/CustomApps")

    d2_targets = [
        (os.path.join(user_apps, "stats", "index.js"), ["topbar"]),
        (os.path.join(user_apps, "marketplace", "index.js"), ["topbar"]),
        (os.path.join(cli_apps, "lyrics-plus", "index.js"),
         ["topbar", "viewportChain", "viewportField", "offsetTop"]),
        (os.path.join(cli_apps, "lyrics-plus", "TabBar.js"),
         ["resizeSel", "resizeInit", "resizeHandler", "observe"]),
        (os.path.join(cli_apps, "reddit", "TabBar.js"),
         ["resizeSel", "resizeInit", "resizeHandler", "observe"]),
    ]
    for xpui_dir in target_dirs:
        d2_targets.append((os.path.join(xpui_dir, "spicetify-routes-stats.js"), ["topbar"]))
        d2_targets.append((os.path.join(xpui_dir, "spicetify-routes-marketplace.js"), ["topbar"]))
        d2_targets.append((os.path.join(xpui_dir, "spicetify-routes-lyrics-plus.js"),
                           ["topbar", "viewportChain", "viewportField", "offsetTop",
                            "resizeSel", "resizeInit", "resizeHandler", "observe"]))

    d2_counts = {key: 0 for key in d2_patches}
    d2_touched = 0
    for d2_path, keys in d2_targets:
        if not os.path.isfile(d2_path):
            continue
        with io.open(d2_path, encoding="utf-8") as f:
            d2_text = f.read()
        d2_changed = False
        for key in keys:
            patch = d2_patches[key]
            if patch["marker"] in d2_text:
                continue
            old_text = patch["old"] if patch["old"] in d2_text else patch.get("old2")
            if not old_text or old_text not in d2_text:
                continue
            d2_text = d2_text.replace(old_text, patch["new"])
            d2_counts[key] += 1
            d2_changed = True
        if d2_changed:
            with io.open(d2_path, "w", encoding="utf-8", newline="") as f:
                f.write(d2_text)
            d2_touched += 1

    for key, patch in d2_patches.items():
        if d2_counts[key]:
            add_result(patch["name"], "applied", "%d file(s) patched for Spotify 1.3.x" % d2_counts[key])
        elif d2_touched or os.path.isdir(user_apps) or os.path.isdir(cli_apps):
            add_result(patch["name"], "not-needed", "no unpatched occurrence found")
        else:
            add_result(patch["name"], "skipped", "no Spicetify CustomApps directory found")


# H: styling for the extra-app entries + unified Spotify-style icons. Written to
# the active theme's user.css (survives `spicetify apply`) and the deployed
# user.css; the managed block owns the tail of those files.
if os.environ.get("SKIP_NAV_STYLE"):
    add_result("H: nav styling", "skipped", "disabled with SKIP_NAV_STYLE=1")
else:
    NAV_CSS = """/* fusion:navstyle */
/* Unify the extra-app entries Spicetify adds to the global nav bar so they read
   as one set with Spotify's own icons (48x48, border-radius 9999px, 24px glyph,
   #b3b3b3, hover/press #242424/#000000, 8px rhythm). Managed block. */
#global-nav-bar .custom-navlinks-scrollable_container { display: flex; align-items: center; align-self: center; min-width: 0; }
#global-nav-bar .custom-navlinks-scrollable_container > .spicetify-sc-contentArea { display: flex; align-items: center; min-width: 0; }
#global-nav-bar .custom-navlink {
  --encore-icon-width: 24px; --encore-icon-height: 24px; --encore-graphic-size-decorative-base: 24px;
  display: inline-flex !important; align-items: center !important; justify-content: center !important;
  width: 48px !important; height: 48px !important; min-width: 48px !important; padding: 0 !important;
  margin: 0 4px !important; border: 0 !important; border-radius: 9999px !important;
  background-color: transparent; color: var(--text-subdued, #b3b3b3); flex: 0 0 auto; overflow: hidden;
  transition: color .15s ease, background-color .15s ease;
}
#global-nav-bar .custom-navlink:hover { color: var(--text-base, #ffffff); background-color: var(--background-highlight, #242424); }
#global-nav-bar .custom-navlink:active { background-color: var(--background-press, #000000); }
#global-nav-bar .custom-navlink:focus-visible { outline: 2px solid var(--text-base, #ffffff); outline-offset: 2px; }
#global-nav-bar .custom-navlink[aria-current="page"], #global-nav-bar .custom-navlink.link-subtle.active { color: var(--text-base, #ffffff); background-color: var(--background-highlight, #242424); }
#global-nav-bar .custom-navlink .e-10860-button__icon-wrapper { display: inline-flex; align-items: center; justify-content: center; width: 24px; height: 24px; }
#global-nav-bar .custom-navlink .e-10860-button__icon-wrapper > svg { display: block; width: 24px; height: 24px; max-width: 100%; max-height: 100%; }
#global-nav-bar .custom-navlink .e-10860-button__icon-wrapper > svg > svg { display: block; width: 100%; height: 100%; padding: 2px; box-sizing: border-box; }
#global-nav-bar .custom-navlink svg, #global-nav-bar .custom-navlink svg * { fill: currentColor; stroke: none; }
@media (max-width: 1100px) {
  #global-nav-bar .custom-navlink { --encore-icon-width: 20px; --encore-icon-height: 20px; --encore-graphic-size-decorative-base: 20px; width: 40px !important; height: 40px !important; min-width: 40px !important; }
  #global-nav-bar .custom-navlink .e-10860-button__icon-wrapper, #global-nav-bar .custom-navlink .e-10860-button__icon-wrapper > svg { width: 20px; height: 20px; }
}
"""
    if not os.environ.get("SHOW_ALL_APPS"):
        NAV_CSS += """/* fusion:navhide */
/* Curated nav visibility: Enhancify / Statistics are hidden by request. Set
   SHOW_ALL_APPS=1 to keep every custom-app entry visible. */
#global-nav-bar .custom-navlink[aria-label="Enhancify"],
#global-nav-bar .custom-navlink[aria-label="Statistics"],
.main-yourLibraryX-navItem:has(.main-yourLibraryX-navLink[aria-label="Enhancify"]),
.main-yourLibraryX-navItem:has(.main-yourLibraryX-navLink[aria-label="Statistics"]) {
  display: none !important;
}
"""
    NAV_ICON_ATTR = 'viewBox="0 0 16 16" width="24" height="24" fill="currentColor" data-fusion-navicon="1"'
    NAV_ICONS = {
        "marketplace": '<svg role="img" aria-hidden="true" ' + NAV_ICON_ATTR + '><path d="M9 1v6h6V1H9zm5 5h-4V2h4v4zM.999 7h6V1h-6v6zM2 2h4v4H2V2zm7 13h6V9H9v6zm1-5h4v4h-4v-4zM.999 15h6V9h-6v6zM2 10h4v4H2v-4z"/></svg>',
        "stats": '<svg role="img" aria-hidden="true" ' + NAV_ICON_ATTR + '><path d="M.999 15h2V5h-2v10zm4 0h2V1h-2v14zM9 15h2v-4H9v4zm4-7v7h2V8h-2z"/></svg>',
        "lyrics-plus": '<svg role="img" aria-hidden="true" ' + NAV_ICON_ATTR + '><path d="M8.5 1A4.505 4.505 0 004 5.5c0 .731.191 1.411.502 2.022L1.99 13.163a1.307 1.307 0 00.541 1.666l.605.349a1.307 1.307 0 001.649-.283L9.009 9.95C11.248 9.692 13 7.807 13 5.5 13 3.019 10.981 1 8.5 1zM4.023 14.245a.307.307 0 01-.388.066l-.605-.349a.309.309 0 01-.128-.393l2.26-5.078A4.476 4.476 0 007.715 9.92l-3.692 4.325zM8.5 9C6.57 9 5 7.43 5 5.5S6.57 2 8.5 2 12 3.57 12 5.5 10.429 9 8.5 9z"/></svg>',
        "Enhancify": '<svg role="img" aria-hidden="true" ' + NAV_ICON_ATTR + '><path d="M11.777.972c-.364 1.054-1.195 2.322-2.798 2.83-.115.036-.115.36 0 .396 1.603.508 2.434 1.775 2.798 2.83.04.114.406.114.446 0 .364-1.055 1.195-2.322 2.798-2.83.115-.036.115-.36 0-.396-1.603-.508-2.434-1.776-2.798-2.83-.04-.114-.406-.114-.446 0zM5.295 4.5a.75.75 0 01.747.682c.06.65.334 1.68.954 2.572.606.87 1.527 1.596 2.927 1.75a.75.75 0 010 1.491c-1.4.154-2.321.88-2.927 1.751a5.683 5.683 0 00-.954 2.572.75.75 0 01-1.493 0 5.683 5.683 0 00-.954-2.572c-.606-.87-1.527-1.597-2.927-1.75a.75.75 0 010-1.492c1.4-.154 2.321-.88 2.927-1.75.62-.892.894-1.922.954-2.572a.75.75 0 01.746-.682z"/></svg>',
    }
    css_targets = []
    theme_dir = os.environ.get("SPICETIFY_THEME_DIR", "")
    if not theme_dir:
        cfg = os.path.join(os.path.expanduser("~/.config"), "spicetify", "config-xpui.ini")
        theme = "marketplace"
        if os.path.isfile(cfg):
            m = re.search(r"(?m)^current_theme\\s*=\\s*(\\S+)", io.open(cfg, encoding="utf-8-sig").read())
            if m:
                theme = m.group(1)
        theme_dir = os.path.join(os.path.expanduser("~/.config"), "spicetify", "Themes", theme)
    css_targets.append(os.path.join(theme_dir, "user.css"))
    for d in target_dirs:
        css_targets.append(os.path.join(d, "user.css"))
    style_done = 0
    for css_path in css_targets:
        try:
            os.makedirs(os.path.dirname(css_path), exist_ok=True)
        except OSError:
            continue
        text = io.open(css_path, encoding="utf-8").read() if os.path.isfile(css_path) else ""
        head = text.split("/* fusion:navstyle */")[0].rstrip("\\n")
        new_css = (head + "\\n" if head else "") + NAV_CSS
        if new_css != text:
            io.open(css_path, "w", encoding="utf-8", newline="").write(new_css)
            style_done += 1
    if style_done:
        add_result("H: nav styling", "applied", "%d user.css file(s) written" % style_done)
    else:
        add_result("H: nav styling", "not-needed", "managed block already current")

    if os.environ.get("SHOW_ALL_APPS"):
        add_result("H: nav visibility", "skipped", "disabled with SHOW_ALL_APPS=1 - every custom-app entry stays visible")
    elif style_done:
        add_result("H: nav visibility", "applied", "curated set: Enhancify / Statistics entries hidden")
    else:
        add_result("H: nav visibility", "not-needed", "curated set already in effect")

    icon_done = 0
    for app, icon in NAV_ICONS.items():
        for json_path in (
            os.path.join(user_apps, app, "manifest.json"),
            os.path.join(cli_apps, app, "manifest.json"),
        ) + tuple(os.path.join(d, "spicetify-routes-%s.json" % app) for d in target_dirs):
            if not os.path.isfile(json_path):
                continue
            try:
                data = json.loads(io.open(json_path, encoding="utf-8-sig").read())
            except Exception:
                continue
            if data.get("icon") == icon and data.get("active-icon") == icon:
                continue
            data["icon"] = icon
            if "active-icon" in data:
                data["active-icon"] = icon
            io.open(json_path, "w", encoding="utf-8", newline="").write(json.dumps(data, ensure_ascii=False, indent=1))
            icon_done += 1
    if icon_done:
        add_result("H: nav icons", "applied", "%d manifest/route file(s) switched to Spotify-style glyphs" % icon_done)
    else:
        add_result("H: nav icons", "not-needed", "all app icons already unified")


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
    print("      %s/issues" % os.environ.get("FUSION_REPO_URL", "https://github.com/Maolaohei/spotx-spicetify-fusion"))
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
