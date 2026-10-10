#!/usr/bin/env bash
# Synthetic verification for the shared Python patch pipeline used by fix.sh
# and install.sh. A real Linux Spotify client cannot be driven end-to-end from
# a Windows/CI checkout, so this test builds two minimal bundles that reproduce
# the shapes the pipeline must distinguish:
#
#   legacy : old Spicetify wrapper (rspackChunkclient_web only) + old route
#            header + no custom app registered -> patches must be applied
#   modern : Spicetify >= 2.45 native registration + rspackChunk route header
#            -> every patch must be reported as "not-needed" and files must
#            stay byte-identical
#
# Usage: bash tools/verify-shell-patches.sh
set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILED=0
assert() {
    # assert <ok:0|1> <name> [detail]
    if [ "$1" -eq 0 ]; then
        echo -e "  ${GREEN}[ok]${NC}   $2"
    else
        echo -e "  ${RED}[FAIL]${NC} $2${3:+ - $3}"
        FAILED=$((FAILED + 1))
    fi
}

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 not found; skipping shell patch pipeline verification"
    exit 0
fi

# On Windows, 'python3' can be the Microsoft Store stub; find a working
# interpreter and expose it to fix.sh (which calls python3 on Linux) via PATH.
PY=""
if python3 -c 'pass' >/dev/null 2>&1; then
    PY=python3
elif command -v python >/dev/null 2>&1 && python -c 'pass' >/dev/null 2>&1; then
    PY=python
else
    echo "no working python interpreter found; skipping shell patch pipeline verification"
    exit 0
fi
mkdir -p "$WORK/bin"
cat > "$WORK/bin/python3" << EOF
#!/usr/bin/env bash
exec "$(command -v "$PY")" "\$@"
EOF
chmod +x "$WORK/bin/python3"

# --- bundle shapes ---------------------------------------------------------
MODERN_WRAPPER='var x=window?.rspackChunk||window?.rspackChunkclient_web||window?.webpackChunkclient_web;Spicetify.URI.fromString??=f.find(m=>m?.NQG),Spicetify.React=f.find(m=>m?.useMemo),foo();'
LEGACY_WRAPPER='var x=window?.webpackChunkclient_web||window?.rspackChunkclient_web;Spicetify.React=f.find(m=>m?.useMemo),foo();'
MODERN_ROUTE='((e)=>{const t=e.rspackChunk||e.rspackChunkclient_web||e.webpackChunkclient_web||[];return t})("undefined"!=typeof self?self:globalThis).push([["spicetify-routes-demo"],{},e=>e]);'
LEGACY_ROUTE='(self.webpackChunkclient_web=self.webpackChunkclient_web||[]).push([["spicetify-routes-demo"],{},e=>e]);'

make_bundle() {
    # make_bundle <dir> <wrapper> <route> <chunkmap-entry?>
    local dir="$1" wrapper="$2" route="$3" registered="$4"
    mkdir -p "$dir/Apps/xpui/helper"
    local map='1328:"placeholder"'
    local allow='1328:1'
    if [ "$registered" = "yes" ]; then
        map='"spicetify-routes-demo":"spicetify-routes-demo",'"$map"
        allow='"spicetify-routes-demo":1,'"$allow"
    fi
    cat > "$dir/Apps/xpui/xpui.js" <<EOF
(function(){var c={7207:0};n.f.miniCss=function(e,t,o){if(c[e])t.push(c[e]);else 0!==c[e]&&({$allow})[e]&&t.push(c[e])};n.u=e=>""+(({$map})[e]||e)+".js";n.miniCssF=e=>""+(({$map})[e]||e)+".css";})();
EOF
    printf '%s' "$wrapper" > "$dir/Apps/xpui/helper/spicetifyWrapper.js"
    printf '%s' "$route" > "$dir/Apps/xpui/spicetify-routes-demo.js"
}

run_pipeline() {
    # run_pipeline <client-dir> <report>
    PATH="$WORK/bin:$PATH" SPOTIFY_DIR="$1" REPORT_PATH="$2" bash "$REPO_ROOT/fix.sh" > "$WORK/run.log" 2>&1
}

status_of() {
    "$PY" - "$1" "$2" << 'EOF'
import json, sys
report, patch = sys.argv[1], sys.argv[2]
data = json.load(open(report))
for r in data["results"]:
    if r["patch"].startswith(patch):
        print(r["status"])
        break
else:
    print("missing")
EOF
}

echo "SpotX + Spicetify shell patch pipeline verification"

# --- legacy bundle: patches must fire ------------------------------------
LEGACY_DIR="$WORK/legacy"
make_bundle "$LEGACY_DIR" "$LEGACY_WRAPPER" "$LEGACY_ROUTE" "no"
run_pipeline "$LEGACY_DIR" "$WORK/legacy-report.json"

[ "$(status_of "$WORK/legacy-report.json" 'C1:')" = "applied" ] && assert 0 "legacy: rspackChunk hook applied" || assert 1 "legacy: rspackChunk hook applied" "$(status_of "$WORK/legacy-report.json" 'C1:')"
[ "$(status_of "$WORK/legacy-report.json" 'B4:')" = "applied" ] && assert 0 "legacy: custom app chunk map injected" || assert 1 "legacy: custom app chunk map injected" "$(status_of "$WORK/legacy-report.json" 'B4:')"
[ "$(status_of "$WORK/legacy-report.json" 'D:')" = "applied" ] && assert 0 "legacy: route push header fixed" || assert 1 "legacy: route push header fixed" "$(status_of "$WORK/legacy-report.json" 'D:')"

grep -q 'rspackChunk||=' "$LEGACY_DIR/Apps/xpui/spicetify-routes-demo.js" && assert 0 "legacy: header rewritten to rspackChunk" || assert 1 "legacy: header rewritten to rspackChunk"
grep -q '1001:"spicetify-routes-demo"' "$LEGACY_DIR/Apps/xpui/xpui.js" && assert 0 "legacy: numeric chunk entry injected" || assert 1 "legacy: numeric chunk entry injected"
grep -qF 'rspackChunkclient_web||window?.rspackChunk' "$LEGACY_DIR/Apps/xpui/helper/spicetifyWrapper.js" && assert 0 "legacy: wrapper hooked" || assert 1 "legacy: wrapper hooked"

# --- modern bundle: files must not change --------------------------------
MODERN_DIR="$WORK/modern"
make_bundle "$MODERN_DIR" "$MODERN_WRAPPER" "$MODERN_ROUTE" "yes"
before_xpui=$(sha256sum "$MODERN_DIR/Apps/xpui/xpui.js" | cut -d' ' -f1)
before_wrapper=$(sha256sum "$MODERN_DIR/Apps/xpui/helper/spicetifyWrapper.js" | cut -d' ' -f1)
before_route=$(sha256sum "$MODERN_DIR/Apps/xpui/spicetify-routes-demo.js" | cut -d' ' -f1)
run_pipeline "$MODERN_DIR" "$WORK/modern-report.json"

[ "$(status_of "$WORK/modern-report.json" 'C1:')" = "not-needed" ] && assert 0 "modern: rspackChunk hook not needed" || assert 1 "modern: rspackChunk hook not needed" "$(status_of "$WORK/modern-report.json" 'C1:')"
[ "$(status_of "$WORK/modern-report.json" 'B4:')" = "not-needed" ] && assert 0 "modern: custom app already registered" || assert 1 "modern: custom app already registered" "$(status_of "$WORK/modern-report.json" 'B4:')"
[ "$(status_of "$WORK/modern-report.json" 'D:')" = "not-needed" ] && assert 0 "modern: route header already correct" || assert 1 "modern: route header already correct" "$(status_of "$WORK/modern-report.json" 'D:')"

[ "$before_xpui" = "$(sha256sum "$MODERN_DIR/Apps/xpui/xpui.js" | cut -d' ' -f1)" ] && assert 0 "modern: xpui.js untouched" || assert 1 "modern: xpui.js untouched"
[ "$before_wrapper" = "$(sha256sum "$MODERN_DIR/Apps/xpui/helper/spicetifyWrapper.js" | cut -d' ' -f1)" ] && assert 0 "modern: wrapper untouched" || assert 1 "modern: wrapper untouched"
[ "$before_route" = "$(sha256sum "$MODERN_DIR/Apps/xpui/spicetify-routes-demo.js" | cut -d' ' -f1)" ] && assert 0 "modern: route bundle untouched" || assert 1 "modern: route bundle untouched"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo -e "${GREEN}Shell patch pipeline verification PASSED.${NC}"
else
    echo -e "${RED}Shell patch pipeline verification FAILED ($FAILED).${NC}"
    sed -n '1,80p' "$WORK/run.log" 2>/dev/null || true
fi
exit "$FAILED"
