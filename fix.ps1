<#
.SYNOPSIS
    SpotX + Spicetify Unified Compatibility Hotfix Script
    Supports Spotify 1.2.x (Webpack) and 1.3.x (Rspack, up to 1.3.4)
.DESCRIPTION
    Fixes critical compatibility issues between SpotX and Spicetify.
    Every patch below is probed against the actual bundle first; patches that
    are no longer needed (upstream fixed them) are reported as "not-needed"
    instead of being applied blindly.

    1. Snapshot filename casing: SpotX renames v8_context_snapshot*.bin to
       V8_context_snapshot*.bin; Spicetify's case-sensitive scanner then fails
       to extract the modules. This restores the lowercase name.
    2. Spotify 1.2.x Webpack: legacy Spicetify semver bug could inject a broken
       `Spicetify.Snackbar.enqueueImageSnackbar=` statement (black screen).
    3. Legacy 1.2.x/1.3.0 runtime guards (useNavigateStable / RegistryContext)
       that only exist on old bundles. Skipped when the bundle does not contain
       the anchor.
    4. Custom Apps chunk registration into the Rspack/Webpack .u map and CSS
       allowlist - only when Spicetify did not already register the app itself.
       Spicetify >= 2.45.1 registers custom apps natively on Rspack builds.
    5. helper/spicetifyWrapper.js: legacy rspackChunk / Spicetify.URI hacks are
       skipped when the wrapper already ships native support (Spicetify 2.45+).
    6. spicetify-routes-*.js push headers: only rewritten when the bundle does
       not already negotiate window.rspackChunk.

    A JSON report can be written with -ReportPath; it records every patch that
    was applied, skipped or not needed for the inspected client.
.LINK
    https://github.com/Maolaohei/spotx-spicetify-fusion
#>

[CmdletBinding()]
param(
    [switch]$Quiet,
    [switch]$LaunchSpotify,
    [switch]$Force,
    [switch]$NoStop,
    [switch]$KeepEnglish,
    [string]$SpotifyDir,
    [string]$JsHelperDir,
    [string]$I18nDir,
    [string]$ReportPath
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# This fork is the project the scripts and the docs all point to.
$FusionRepoUrl = 'https://github.com/Maolaohei/spotx-spicetify-fusion'

$script:Results = New-Object System.Collections.Generic.List[object]

function Write-Log {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    if (-not $Quiet) {
        Write-Host $Message -ForegroundColor $Color
    }
}

function Add-Result {
    param(
        [string]$Patch,
        [ValidateSet('applied', 'not-needed', 'skipped', 'failed')]
        [string]$Status,
        [string]$Detail = ""
    )
    $script:Results.Add([PSCustomObject]@{
            Patch  = $Patch
            Status = $Status
            Detail = $Detail
        })
    switch ($Status) {
        'applied' { Write-Log "  [+] $Patch - $Detail" "Green" }
        'not-needed' { Write-Log "  [=] $Patch - not needed ($Detail)" "DarkGray" }
        'skipped' { Write-Log "  [~] $Patch - skipped ($Detail)" "Yellow" }
        'failed' { Write-Log "  [-] $Patch - FAILED ($Detail)" "Red" }
    }
}

# Replaces the first regular expression match with replacement text, once.
function Replace-FirstMatch {
    param(
        [string]$Content,
        [string]$Pattern,
        [string]$Replacement
    )
    $m = [regex]::Match($Content, $Pattern)
    if (-not $m.Success) { return $null }
    return $Content.Remove($m.Index, $m.Length).Insert($m.Index, $Replacement)
}

# Inserts text right after the first match of Pattern (e.g. into a chunk map).
function Insert-AfterFirstMatch {
    param(
        [string]$Content,
        [string]$Pattern,
        [string]$Insert
    )
    $m = [regex]::Match($Content, $Pattern)
    if (-not $m.Success) { return $null }
    $pos = $m.Index + $m.Length
    return $Content.Insert($pos, $Insert)
}

Write-Log " SpotX + Spicetify Unified Compatibility Hotfix (v2.2)" "Cyan"
Write-Log " Supports Spotify 1.2.x (Webpack) & 1.3.x+ (Rspack, tested 1.3.4)" "Cyan"
Write-Log " GitHub: $FusionRepoUrl" "Cyan"

# Locate Spotify & Spicetify directories
if ($SpotifyDir) {
    $SpotifyDirResolved = $SpotifyDir
}
else {
    $SpotifyDirResolved = Join-Path $env:APPDATA "Spotify"
    if (-not (Test-Path $SpotifyDirResolved)) {
        $SpotifyDirResolved = Join-Path $env:LOCALAPPDATA "Spotify"
    }
}
if (-not (Test-Path $SpotifyDirResolved)) {
    Write-Log "[-] Spotify installation directory not found!" "Red"
    Write-Log "    Install Spotify first (install.ps1), then re-run this hotfix." "Yellow"
    # No 'exit' here: fix.ps1 is documented as "iwr -useb ... | iex", and 'exit'
    # inside Invoke-Expression closes the caller's console window. SetShouldExit
    # reports the failure through -File exit codes instead.
    $host.SetShouldExit(1)
    return
}

$SpotifyExe = Join-Path $SpotifyDirResolved "Spotify.exe"
$SpotifyAppsDir = Join-Path $SpotifyDirResolved "Apps\xpui"

# Terminate running Spotify processes so the patched bundles are not locked.
# -NoStop is used by tooling that patches an offline copy; the check also keeps
# a machine without a client in that directory from killing unrelated processes.
if (-not $NoStop) {
    $spotifyProcs = Get-Process -Name "Spotify" -ErrorAction SilentlyContinue
    if ($spotifyProcs -and (Test-Path $SpotifyExe)) {
        Write-Log "[*] Closing running Spotify process..." "Yellow"
        $spotifyProcs | Stop-Process -Force
        Start-Sleep -Milliseconds 800
    }
}
$xpuiJs = Join-Path $SpotifyAppsDir "xpui.js"
$wrapperJs = Join-Path $SpotifyAppsDir "helper\spicetifyWrapper.js"
$indexHtml = Join-Path $SpotifyAppsDir "index.html"

if (-not (Test-Path $xpuiJs)) {
    Write-Log "[-] Spotify xpui.js not found at: $xpuiJs" "Red"
    Write-Log "    Please run 'spicetify apply' or 'spicetify backup apply' first." "Yellow"
    $host.SetShouldExit(1)
    return
}

# Detect Spotify version and architecture
$detectedVersion = "unknown"
if (Test-Path $SpotifyExe) {
    try {
        $detectedVersion = (Get-Item $SpotifyExe).VersionInfo.ProductVersion
        if (-not $detectedVersion) {
            $detectedVersion = (Get-Item $SpotifyExe).VersionInfo.FileVersion
        }
    }
    catch {}
}

$xpuiContent = [System.IO.File]::ReadAllText($xpuiJs, [System.Text.Encoding]::UTF8)

$is130OrAbove = $false
if ($detectedVersion -ne "unknown" -and $detectedVersion -match '^1\.([3-9]|\d{2,})\.') {
    $is130OrAbove = $true
}
elseif ($xpuiContent.Contains("rspackChunk") -or $xpuiContent.Contains("rspackChunkclient_web")) {
    $is130OrAbove = $true
}

Write-Log "[+] Spotify path: $SpotifyDirResolved" "Green"
if ($is130OrAbove) {
    Write-Log "[+] Detected Spotify Version: $detectedVersion (v1.3.x+ Rspack Architecture)" "Green"
}
else {
    Write-Log "[+] Detected Spotify Version: $detectedVersion (v1.2.x Webpack Architecture)" "Green"
}

# SECTION A: Normalize snapshot filenames (Fix for SpotX commit 9fa954a casing hack)
# Windows paths are case-insensitive, so Test-Path cannot tell V8_ from v8_:
# enumerate the directory and match the name case-sensitively instead.
Add-Type -Assembly 'System.IO.Compression.FileSystem' -ErrorAction SilentlyContinue
$snapshotDir = $SpotifyDirResolved
$snapshotFixed = 0
$snapshotFiles = @(Get-ChildItem -LiteralPath $snapshotDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -cmatch '^V8_context_snapshot.*\.bin$' })
foreach ($snapshotFile in $snapshotFiles) {
    $lowerName = "v" + $snapshotFile.Name.Substring(1)
    $tempName = "$lowerName.tmp"
    try {
        Rename-Item -LiteralPath $snapshotFile.FullName -NewName $tempName -Force -ErrorAction Stop
        Rename-Item -LiteralPath (Join-Path $snapshotDir $tempName) -NewName $lowerName -Force -ErrorAction Stop
        $snapshotFixed++
    }
    catch {}
}
if ($snapshotFixed -gt 0) {
    Add-Result -Patch "A: snapshot casing" -Status applied -Detail "normalized $snapshotFixed file(s) to v8_context_snapshot*.bin"
}
else {
    Add-Result -Patch "A: snapshot casing" -Status not-needed -Detail "no V8_context_snapshot*.bin present"
}

# SECTION B: Patch xpui.js
Write-Log "[*] Inspecting and patching xpui.js..." "Cyan"
$xpuiPatched = $false

# B1: Remove corrupted legacy snackbar injection (Spicetify < 2.45 semver bug)
$badSnackbar = "Spicetify.Snackbar.enqueueImageSnackbar="
if ($xpuiContent.Contains($badSnackbar)) {
    $xpuiContent = $xpuiContent.Replace($badSnackbar, "")
    $xpuiPatched = $true
    Add-Result -Patch "B1: Snackbar SyntaxError" -Status applied -Detail "removed legacy enqueueImageSnackbar injection"
}
else {
    Add-Result -Patch "B1: Snackbar SyntaxError" -Status not-needed -Detail "not present (Spicetify >= 2.45 bundles are clean)"
}

# B2: Wrap useNavigateStable calls in a try/catch (legacy Marketplace white screen)
$navPattern = 'return\(0,([A-Za-z_$][\w$]*)\.useNavigateStable\)\(\)'
$navMatch = [regex]::Match($xpuiContent, $navPattern)
if ($navMatch.Success) {
    $navModule = $navMatch.Groups[1].Value
    $safeNav = 'return(()=>{try{return(0,' + $navModule + '.useNavigateStable)()}catch(err){return Spicetify?.Platform?.History?.push||Spicetify?.Platform?.History?.navigate||(()=>({}))}})()'
    $xpuiContent = $xpuiContent.Remove($navMatch.Index, $navMatch.Length).Insert($navMatch.Index, $safeNav)
    $xpuiPatched = $true
    Add-Result -Patch "B2: useNavigateStable fallback" -Status applied -Detail "wrapped (0,$navModule.useNavigateStable)()"
}
else {
    Add-Result -Patch "B2: useNavigateStable fallback" -Status not-needed -Detail "anchor absent (fixed on this build)"
}

# B3: RegistryContext safe guard (legacy Spotify 1.3.0 crash modal)
$oldRegistry = "(0,i.useContext)(e.yv)"
$safeRegistry = "((0,i.useContext)(e.yv)||Spicetify?.Platform?.Registry||{entries:new Map()})"
if ($xpuiContent.Contains($oldRegistry) -and -not $xpuiContent.Contains($safeRegistry)) {
    $xpuiContent = $xpuiContent.Replace($oldRegistry, $safeRegistry)
    $xpuiPatched = $true
    Add-Result -Patch "B3: RegistryContext guard" -Status applied -Detail "legacy 1.3.0 anchor found"
}
else {
    Add-Result -Patch "B3: RegistryContext guard" -Status not-needed -Detail "anchor absent (fixed on this build)"
}

# B4: Custom Apps chunk registration (.u map, miniCssF map, CSS allowlist)
$customAppBundles = @()
$routeFiles = @(Get-ChildItem -Path $SpotifyAppsDir -Filter "spicetify-routes-*.js" -ErrorAction SilentlyContinue)
foreach ($rf in $routeFiles) {
    if ($rf.Name -match "^spicetify-routes-(.+)\.js$") {
        $customAppBundles += $Matches[1]
    }
}

if ($customAppBundles.Count -eq 0) {
    Add-Result -Patch "B4: Custom Apps chunk map" -Status skipped -Detail "no spicetify-routes-*.js bundles found"
}
else {
    $uAnchor = '\.u=\w+=>""\+\(\(\{'
    $cssAnchor = '\.miniCssF=\w+=>""\+\(\(\{'
    $allowAnchor = '0!==\w+\[e\]&&\(\{'
    $appId = 1001
    $mappedBySpicetify = 0
    $injected = 0

    foreach ($app in $customAppBundles) {
        $bundleName = "spicetify-routes-$app"
        $nameKey = '"' + $bundleName + '"'
        $alreadyMapped = $xpuiContent.Contains(":" + $nameKey)

        if (-not $alreadyMapped) {
            $entry = "$appId`:$nameKey,"
            $newContent = Insert-AfterFirstMatch -Content $xpuiContent -Pattern $uAnchor -Insert $entry
            if ($null -ne $newContent) {
                $xpuiContent = $newContent
                $xpuiPatched = $true
                $injected++
            }
            if ([regex]::IsMatch($xpuiContent, $cssAnchor)) {
                $newContent = Insert-AfterFirstMatch -Content $xpuiContent -Pattern $cssAnchor -Insert $entry
                if ($null -ne $newContent) { $xpuiContent = $newContent }
            }
        }
        else {
            $mappedBySpicetify++
        }

        $cssAllowed = $xpuiContent.Contains($nameKey + ":1") -or $xpuiContent.Contains("$appId`:1")
        if (-not $cssAllowed) {
            $newContent = Insert-AfterFirstMatch -Content $xpuiContent -Pattern $allowAnchor -Insert "$appId`:1,"
            if ($null -ne $newContent) {
                $xpuiContent = $newContent
                $xpuiPatched = $true
                $injected++
            }
        }
        $appId++
    }

    if ($injected -gt 0) {
        Add-Result -Patch "B4: Custom Apps chunk map" -Status applied -Detail "injected $injected map entry/entries for $($customAppBundles.Count) app(s)"
    }
    elseif ($mappedBySpicetify -eq $customAppBundles.Count) {
        Add-Result -Patch "B4: Custom Apps chunk map" -Status not-needed -Detail "Spicetify registered all $($customAppBundles.Count) app(s) natively"
    }
    elseif (-not [regex]::IsMatch($xpuiContent, $uAnchor)) {
        Add-Result -Patch "B4: Custom Apps chunk map" -Status failed -Detail "no Rspack .u loader found; Spotify bundle shape changed"
    }
    else {
        Add-Result -Patch "B4: Custom Apps chunk map" -Status applied -Detail "chunk map already present"
    }
}

if ($xpuiPatched) {
    [System.IO.File]::WriteAllText($xpuiJs, $xpuiContent, (New-Object System.Text.UTF8Encoding($false)))
    Write-Log "[SUCCESS] xpui.js successfully patched!" "Green"
}
else {
    Write-Log "[INFO] xpui.js needs no patches on this build." "Cyan"
}

# SECTION C: Patch helper/spicetifyWrapper.js
if (Test-Path $wrapperJs) {
    Write-Log "[*] Inspecting helper\spicetifyWrapper.js..." "Cyan"
    $wrapContent = [System.IO.File]::ReadAllText($wrapperJs, [System.Text.Encoding]::UTF8)
    $wrapPatched = $false

    # C1: window.rspackChunk hook - only for wrappers that do not ship it yet.
    # Note: 'rspackChunkclient_web' also contains 'rspackChunk', so the check
    # must exclude the legacy alias explicitly.
    if ($wrapContent -match 'rspackChunk(?!client_web)') {
        Add-Result -Patch "C1: rspackChunk hook" -Status not-needed -Detail "wrapper already negotiates window.rspackChunk"
    }
    else {
        $chunkTarget = 'window?.webpackChunkclient_web||window?.rspackChunkclient_web'
        $chunkFixed = 'window?.webpackChunkclient_web||window?.rspackChunkclient_web||window?.rspackChunk'
        if ($wrapContent.Contains($chunkTarget)) {
            $wrapContent = $wrapContent.Replace($chunkTarget, $chunkFixed)
            $wrapPatched = $true
            Add-Result -Patch "C1: rspackChunk hook" -Status applied -Detail "legacy wrapper patched"
        }
        else {
            Add-Result -Patch "C1: rspackChunk hook" -Status failed -Detail "wrapper shape unknown; neither native nor legacy anchor found"
        }
    }

    # C2: legacy Spicetify.URI export - the modern wrapper resolves URI itself
    $hasModernUri = $wrapContent -match 'URI\.fromString' -or $wrapContent -match 'waitForURI'
    $legacyUriInjection = '(()=>{let u=f.find(m=>m?.NQG?.PLAYLIST_V2);if(u){let s=u.o_h("spotify:track:4uLU6hMCjMI75M1A2tKUQC")?.constructor;if(s){s.Type=u.NQG,s.from=u.o_h,s.fromString=u.Lce,s.idToHex=u.DY5,s.hexToId=u.dx2,Spicetify.URI=s}}})(),'
    $legacyUriPattern = '\(\(\)=>\{let u=f\.find\(m=>m\?\.NQG\?\.PLAYLIST_V2\);.*?Spicetify\.URI=s\}\}\)\(\)\,?'

    if ($hasModernUri) {
        if ($wrapContent.Contains('Spicetify.URI=s')) {
            $cleaned = [regex]::Replace($wrapContent, $legacyUriPattern, '')
            if ($cleaned -ne $wrapContent) {
                $wrapContent = $cleaned
                $wrapPatched = $true
                Add-Result -Patch "C2: Spicetify.URI export" -Status applied -Detail "removed obsolete legacy URI injection left by older fix.ps1 runs"
            }
            else {
                Add-Result -Patch "C2: Spicetify.URI export" -Status skipped -Detail "legacy marker present but could not be removed cleanly"
            }
        }
        else {
            Add-Result -Patch "C2: Spicetify.URI export" -Status not-needed -Detail "wrapper resolves URI natively"
        }
    }
    else {
        $uriTarget = 'Spicetify.React=f.find(m=>m?.useMemo),'
        if ($wrapContent.Contains($uriTarget) -and -not $wrapContent.Contains('Spicetify.URI=s')) {
            $wrapContent = $wrapContent.Replace($uriTarget, $uriTarget + $legacyUriInjection)
            $wrapPatched = $true
            Add-Result -Patch "C2: Spicetify.URI export" -Status applied -Detail "legacy wrapper patched"
        }
        else {
            Add-Result -Patch "C2: Spicetify.URI export" -Status failed -Detail "wrapper shape unknown; legacy anchor not found"
        }
    }

    if ($wrapPatched) {
        [System.IO.File]::WriteAllText($wrapperJs, $wrapContent, (New-Object System.Text.UTF8Encoding($false)))
        Write-Log "[SUCCESS] spicetifyWrapper.js successfully patched!" "Green"
    }
    else {
        Write-Log "[INFO] spicetifyWrapper.js needs no patches on this build." "Cyan"
    }
}
else {
    Add-Result -Patch "C1/C2: spicetifyWrapper.js" -Status skipped -Detail "helper\spicetifyWrapper.js not found (set expose_apis=1 and run 'spicetify apply')"
}

# SECTION D: Fix custom apps push headers in spicetify-routes-*.js
if ($routeFiles.Count -gt 0) {
    Write-Log "[*] Inspecting custom app route bundles..." "Cyan"
    $headerFixed = 0
    $headerNative = 0
    foreach ($rf in $routeFiles) {
        $rc = [System.IO.File]::ReadAllText($rf.FullName, [System.Text.Encoding]::UTF8)
        $pushIdx = $rc.IndexOf(').push([[')
        if ($pushIdx -le 0 -or $pushIdx -ge 300) { continue }
        $head = $rc.Substring(0, $pushIdx)
        if ($head -match 'rspackChunk(?!client_web)') {
            $headerNative++
            continue
        }
        if ($head -match 'webpackChunkclient_web') {
            $fixedHead = '(("u">typeof self?self:global).rspackChunk||=[]' + $rc.Substring($pushIdx)
            [System.IO.File]::WriteAllText($rf.FullName, $fixedHead, (New-Object System.Text.UTF8Encoding($false)))
            $headerFixed++
        }
    }
    if ($headerFixed -gt 0) {
        Add-Result -Patch "D: route push headers" -Status applied -Detail "fixed $headerFixed bundle(s)"
    }
    elseif ($headerNative -gt 0) {
        Add-Result -Patch "D: route push headers" -Status not-needed -Detail "$headerNative bundle(s) already negotiate rspackChunk"
    }
    else {
        Add-Result -Patch "D: route push headers" -Status skipped -Detail "no route bundle matched the push header shape"
    }
}
else {
    Add-Result -Patch "D: route push headers" -Status skipped -Detail "no spicetify-routes-*.js bundles found"
}

# SECTION E: Chinese UI for Spicetify's helper panels
#   "Experimental features", "Home config" and "Sidebar config" are Spicetify's
#   own English-only helper scripts. Their visible labels are replaced with JS
#   unicode escapes (kept ASCII here so the iwr|iex path stays safe). Both the
#   CLI templates (so `spicetify apply` redeploys the Chinese version) and the
#   copies deployed in the client are patched. Skip with -KeepEnglish.
if ($KeepEnglish) {
    Add-Result -Patch "E: Chinese UI" -Status skipped -Detail "disabled with -KeepEnglish"
}
else {
    $chineseUi = @(
        @{ File = 'expFeatures.js'; Edits = @(
                @{ Old = '"Waiting for Spotify to finish loading..."'; New = '"\u6b63\u5728\u7b49\u5f85 Spotify \u52a0\u8f7d\u5b8c\u6210\u2026"' },
                @{ Old = 'Using fallback mode. Some features may not work.'; New = '\u6b63\u5728\u4f7f\u7528\u517c\u5bb9\u6a21\u5f0f\uff0c\u90e8\u5206\u529f\u80fd\u53ef\u80fd\u4e0d\u53ef\u7528\u3002' },
                @{ Old = 'placeholder="Search for a feature"'; New = 'placeholder="\u641c\u7d22\u529f\u80fd\u9879"' },
                @{ Old = '"Experimental features"'; New = '"\u5b9e\u9a8c\u6027\u529f\u80fd"' },
                @{ Old = '>Clear all cached features and preferences<'; New = '>\u6e05\u7a7a\u5df2\u7f13\u5b58\u7684\u529f\u80fd\u4e0e\u504f\u597d\u8bbe\u7f6e<' },
                @{ Old = '>Reset</button>'; New = '>\u91cd\u7f6e</button>' }
            ) },
        @{ File = 'homeConfig.js'; Edits = @(
                @{ Old = 'up.innerText = "Up";'; New = 'up.innerText = "\u4e0a\u79fb";' },
                @{ Old = 'down.innerText = "Down";'; New = 'down.innerText = "\u4e0b\u79fb";' },
                @{ Old = '"Unstick" : "Stick"'; New = '"\u53d6\u6d88\u7f6e\u9876" : "\u7f6e\u9876"' },
                @{ Old = '"Unlower" : "Lower"'; New = '"\u53d6\u6d88\u7f6e\u5e95" : "\u7f6e\u5e95"' },
                @{ Old = '"Home config"'; New = '"\u9996\u9875\u6392\u5e8f"' }
            ) },
        @{ File = 'sidebarConfig.js'; Edits = @(
                @{ Old = 'up.innerText = "Up";'; New = 'up.innerText = "\u4e0a\u79fb";' },
                @{ Old = 'down.innerText = "Down";'; New = 'down.innerText = "\u4e0b\u79fb";' },
                @{ Old = '"Unstick" : "Stick"'; New = '"\u53d6\u6d88\u7f6e\u9876" : "\u7f6e\u9876"' },
                @{ Old = '"Unhide" : "Hide"'; New = '"\u53d6\u6d88\u9690\u85cf" : "\u9690\u85cf"' },
                @{ Old = '"Sidebar config"'; New = '"\u4fa7\u8fb9\u680f\u914d\u7f6e"' }
            ) }
    )

    $helperDirs = New-Object System.Collections.Generic.List[string]
    if ($JsHelperDir) {
        if (Test-Path $JsHelperDir) { $helperDirs.Add((Resolve-Path $JsHelperDir).Path) }
    }
    else {
        $templateDir = Join-Path $env:LOCALAPPDATA "spicetify\jsHelper"
        if (-not (Test-Path $templateDir)) {
            $spicetifyCmd = Get-Command spicetify -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($spicetifyCmd) { $templateDir = Join-Path (Split-Path $spicetifyCmd.Source) "jsHelper" }
        }
        if (Test-Path $templateDir) { $helperDirs.Add($templateDir) }
    }
    $deployedHelperDir = Join-Path $SpotifyAppsDir "helper"
    if (Test-Path $deployedHelperDir) { $helperDirs.Add($deployedHelperDir) }

    $uiApplied = 0
    $uiTranslated = 0
    $uiFiles = 0
    $uiDrift = New-Object System.Collections.Generic.List[string]
    foreach ($dir in ($helperDirs | Select-Object -Unique)) {
        foreach ($entry in $chineseUi) {
            $path = Join-Path $dir $entry.File
            if (-not (Test-Path $path)) { continue }
            $uiFiles++
            $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
            $pending = @($entry.Edits | Where-Object { $text.Contains($_.Old) })
            $done = @($entry.Edits | Where-Object { $text.Contains($_.New) })
            if ($pending.Count -eq 0) {
                if ($done.Count -gt 0) { $uiTranslated++ }
                else { $uiDrift.Add("$([System.IO.Path]::GetFileName($path)) in $(Split-Path $dir -Leaf)") }
                continue
            }
            foreach ($edit in $pending) { $text = $text.Replace($edit.Old, $edit.New) }
            [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
            $uiApplied += $pending.Count
        }
    }

    # Inner feature labels: the panel lists Spotify's own feature flags with
    # their English descriptions ("Enable the Super Connect feature"). The
    # project ships a name -> Chinese dictionary; inject a lookup into
    # expFeatures.js so the rows render Chinese and any flag we do not know yet
    # keeps its English text.
    $featureLabels = $null
    $labelSource = ''
    if ($I18nDir) {
        $candidate = Join-Path $I18nDir 'exp-features.zh.json'
        if (Test-Path $candidate) { $featureLabels = $candidate; $labelSource = 'local' }
    }
    if (-not $featureLabels -and $PSScriptRoot) {
        $candidate = Join-Path (Join-Path $PSScriptRoot 'i18n') 'exp-features.zh.json'
        if (Test-Path $candidate) { $featureLabels = $candidate; $labelSource = 'repo' }
    }
    if (-not $featureLabels) {
        $candidate = Join-Path $env:TEMP 'spotx-spicetify-fusion-exp-features.zh.json'
        try {
            Invoke-WebRequest -Uri "$FusionRepoRaw/i18n/exp-features.zh.json" -OutFile $candidate -UseBasicParsing
            $featureLabels = $candidate
            $labelSource = 'project'
        }
        catch {
            Write-Log "  [~] feature labels: could not fetch the dictionary ($($_.Exception.Message))" "Yellow"
        }
    }

    if ($featureLabels) {
        $json = Get-Content -Path $featureLabels -Raw -Encoding UTF8 | ConvertFrom-Json
        $map = @{}
        foreach ($prop in $json.labels.PSObject.Properties) {
            $value = $prop.Value.ToString()
            $escaped = New-Object System.Text.StringBuilder
            foreach ($ch in $value.ToCharArray()) {
                $code = [int]$ch
                if ($code -eq 34) { [void]$escaped.Append('\"') }
                elseif ($code -eq 92) { [void]$escaped.Append('\\') }
                elseif ($code -gt 127) { [void]$escaped.AppendFormat('\u{0:x4}', $code) }
                else { [void]$escaped.Append($ch) }
            }
            $map[$prop.Name] = $escaped.ToString()
        }
        $pairs = @()
        foreach ($name in ($map.Keys | Sort-Object)) { $pairs += '"' + $name + '":"' + $map[$name] + '"' }
        $injection = "const zhLabels={" + ($pairs -join ',') + "};const zhLabel=(name,desc)=>zhLabels[name]||desc;"

        foreach ($dir in ($helperDirs | Select-Object -Unique)) {
            $path = Join-Path $dir 'expFeatures.js'
            if (-not (Test-Path $path)) { continue }
            $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
            if ($text.Contains('zhLabel(')) { $uiTranslated++; continue }
            $anchor = 'let isFallback = false;'
            $rowLabel = '<label class="col description">${desc}</label>'
            if (-not $text.Contains($anchor) -or -not $text.Contains($rowLabel)) { $uiDrift.Add('feature labels in expFeatures.js'); continue }
            $text = $text.Replace($anchor, $anchor + $injection)
            $text = $text.Replace($rowLabel, '<label class="col description">${zhLabel(name, desc)}</label>')
            [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
            $uiApplied += $map.Count
        }
        Write-Log "  [+] feature labels: $($map.Count) entries applied from the $labelSource dictionary" "Green"
    }

    if ($uiApplied -gt 0) {
        Add-Result -Patch "E: Chinese UI" -Status applied -Detail "$uiApplied label(s) translated (templates + deployed)"
    }
    elseif ($uiTranslated -gt 0) {
        Add-Result -Patch "E: Chinese UI" -Status not-needed -Detail "helpers are already translated"
    }
    elseif ($uiFiles -eq 0) {
        Add-Result -Patch "E: Chinese UI" -Status skipped -Detail "Spicetify helper scripts not found (features disabled?)"
    }
    else {
        Add-Result -Patch "E: Chinese UI" -Status failed -Detail "helper shape changed: $($uiDrift -join ', ')"
    }
}

# SECTION F: Verification & Launch
$failed = @($script:Results | Where-Object { $_.Status -eq 'failed' })
Write-Log " [OK] All SpotX + Spicetify compatibility patches processed!" "Green"
if ($failed.Count -gt 0) {
    Write-Log " [!] $($failed.Count) patch(es) could not be verified - the Spotify bundle probably changed." "Yellow"
    Write-Log "     Re-run this script after the next SpotX/Spicetify release, or report it:" "Yellow"
    Write-Log "     $FusionRepoUrl/issues" "Yellow"
}

if ($ReportPath) {
    try {
        $report = [PSCustomObject]@{
            tool           = "fix.ps1"
            version        = "2.2"
            timestamp      = (Get-Date).ToString("o")
            spotifyDir     = $SpotifyDirResolved
            spotifyVersion = $detectedVersion
            architecture   = if ($is130OrAbove) { "rspack" } else { "webpack" }
            failed         = $failed.Count
            results        = $script:Results
        }
        $report | ConvertTo-Json -Depth 5 | Set-Content -Path $ReportPath -Encoding UTF8
        Write-Log "[+] Report written to $ReportPath" "Green"
    }
    catch {
        Write-Log "[-] Could not write report: $_" "Red"
    }
}

if ($LaunchSpotify) {
    if (Test-Path $SpotifyExe) {
        Write-Log "[*] Launching Spotify..." "Cyan"
        Start-Process -FilePath $SpotifyExe
    }
}
