<#
.SYNOPSIS
    Offline end-to-end verification for the SpotX + Spicetify fusion patches.
.DESCRIPTION
    Rebuilds the whole fusion pipeline from shipped artifacts, without
    installing Spotify on the machine:

      1. download the pinned Spotify 1.3.4 installer and verify its SHA-256,
      2. run the real SpotX run.ps1 against an extracted client sandbox
         (-SpotifyPath, no install, no shortcut, no registry writes),
      3. install Spicetify 2.45.3 (portable, SPICETIFY_CONFIG points at a temp
         dir) and run `spicetify -n backup apply` with the Marketplace custom
         app (-n keeps the sandbox client from being launched),
      4. run fix.ps1 -SpotifyDir <sandbox> -ReportPath <artifact>,
      5. assert the expected state and write verify-out/offline-e2e.json.

    Required flags for SpotX run.ps1 are read from the downloaded script, so a
    renamed/removed switch fails the run instead of being silently skipped.

    Notes:
      - Nothing is installed: the client lives in a temp sandbox and only
        -SpotifyPath / SPICETIFY_CONFIG overrides are used.
      - fix.ps1 stops running Spotify processes, so close Spotify first.
      - Run install.ps1 -VerifyOnly / install.sh --verify-only for the
        installer-level bypass checks; this script focuses on the bundle patches.

.PARAMETER CacheDir
    Download cache (installer, spicetify release, marketplace release).
.PARAMETER OutDir
    Where the JSON artifact is written.
.PARAMETER SkipDownload
    Fail instead of downloading when the cache is incomplete.
.PARAMETER KeepWork
    Keep the extracted sandbox for manual inspection.
#>

[CmdletBinding()]
param(
    [string]$CacheDir,
    [string]$OutDir,
    [switch]$SkipDownload,
    [switch]$KeepWork
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $CacheDir) { $CacheDir = Join-Path $RepoRoot ".cache\verify-offline" }
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot "verify-out" }
New-Item -ItemType Directory -Force -Path $CacheDir, $OutDir | Out-Null

$SpotifySetupUrl = "https://loadspot.amd64fox1.workers.dev/download/spotify_installer-1.3.4.258.gc60b10b0946a-x64.exe"
$SpotifySetupSize = 156864632
$XpuiSpaSha256 = "19be39b9f8da51a5e766699bc0e7a8bf6dc6f09b1b733a2d8feb4cb2e1ce0608"
$SpicetifyZipUrl = "https://github.com/spicetify/cli/releases/download/v2.45.3/spicetify-2.45.3-windows-x64.zip"
$MarketplaceZipUrl = "https://github.com/spicetify/marketplace/releases/latest/download/marketplace.zip"

$Assertions = New-Object System.Collections.Generic.List[object]
$script:FailureCount = 0

function Write-Step {
    param([string]$Message, [string]$Color = "Cyan")
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor $Color
}

function Assert-That {
    param(
        [string]$Name,
        [bool]$Ok,
        [string]$Detail = ""
    )
    $Assertions.Add([PSCustomObject]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
    if ($Ok) {
        Write-Host ("  [ok]   {0}{1}" -f $Name, $(if ($Detail) { " - $Detail" } else { "" })) -ForegroundColor Green
    }
    else {
        Write-Host ("  [FAIL] {0}{1}" -f $Name, $(if ($Detail) { " - $Detail" } else { "" })) -ForegroundColor Red
        $script:FailureCount++
    }
}

function Get-DownloadedFile {
    param(
        [string]$Url,
        [string]$Path,
        [long]$ExpectedSize = 0,
        [string]$Name = ""
    )
    $complete = (Test-Path $Path)
    if ($complete -and $ExpectedSize -gt 0 -and (Get-Item $Path).Length -ne $ExpectedSize) { $complete = $false }
    if (-not $complete) {
        if ($SkipDownload) { throw "Missing cached artifact and -SkipDownload was set: $Path" }
        Write-Host "  [*] downloading $(if ($Name) { $Name } else { Split-Path -Leaf $Path })..." -ForegroundColor DarkGray
        $ok = $false
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            & curl.exe -sSL --ssl-no-revoke -o $Path $Url
            if ($LASTEXITCODE -eq 0) { $ok = $true }
            else {
                & curl.exe -sSL -o $Path $Url
                if ($LASTEXITCODE -eq 0) { $ok = $true }
            }
        }
        if (-not $ok) {
            Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing
        }
    }
    if ($ExpectedSize -gt 0) {
        $actual = (Get-Item $Path).Length
        if ($actual -ne $ExpectedSize) { throw "Unexpected size for $Path`: $actual bytes (expected $ExpectedSize)" }
    }
    return $Path
}

function Get-FileHash256 {
    param([string]$Path)
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
}

function Expand-Zip {
    param([string]$Zip, [string]$Destination)
    if (Test-Path $Destination) { Remove-Item $Destination -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Zip, $Destination)
}

function Get-InstallFingerprint {
    # Identity of the files the installer would overwrite in a real install.
    # A running Spotify does not rewrite these, so comparing before/after is
    # stable even when the client is up (unlike a recursive directory walk).
    $paths = @(
        (Join-Path $realAppSpotify "Spotify.exe"),
        (Join-Path $realAppSpotify "Apps\xpui.spa"),
        (Join-Path $realAppSpotify "Apps\xpui.bak"),
        (Join-Path $realAppSpotify "Apps\login.spa")
    )
    $items = foreach ($p in $paths) {
        if (Test-Path $p) {
            $f = Get-Item $p
            '{0}|{1}|{2}' -f $f.Name, $f.Length, $f.LastWriteTimeUtc.Ticks
        }
        else { '<absent>' }
    }
    return ($items -join ';')
}

# Reusable: PowerShell variables that are used but never assigned in the script.
# This is the bug class that broke install.ps1 ($SpotifyDir) and fix.ps1
# ($FusionRepoRaw): the parameter-binding error killed the run right after the
# hotfix, and the dictionary fetch silently used a relative URI.
function Get-UsedButUndefinedVariables {
    param([string]$Path)
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput([System.IO.File]::ReadAllText($Path), [ref]$tokens, [ref]$parseErrors)
    $assigned = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    # Script, function and scriptblock parameters all live in ParamBlockAst nodes.
    foreach ($block in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParamBlockAst] }, $true)) {
        foreach ($p in $block.Parameters) { [void]$assigned.Add($p.Name.VariablePath.UserPath) }
    }
    foreach ($node in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        if ($node.Left -is [System.Management.Automation.Language.VariableExpressionAst]) { [void]$assigned.Add($node.Left.VariablePath.UserPath) }
    }
    foreach ($node in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
        [void]$assigned.Add($node.Variable.VariablePath.UserPath)
    }
    foreach ($node in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        foreach ($p in $node.Parameters) { [void]$assigned.Add($p.Name.VariablePath.UserPath) }
    }
    $automatic = @('_', 'PSItem', 'this', 'args', 'null', 'true', 'false', 'error', 'PSScriptRoot', 'PSCommandPath',
        'MyInvocation', 'LASTEXITCODE', '?', '^', '$', 'Host', 'HOME', 'PWD', 'PID', 'OFS', 'Matches', 'input',
        'foreach', 'switch', 'StackTrace', 'PSVersionTable', 'IsWindows', 'IsLinux', 'IsMacOS', 'IsCoreCLR', 'PSHOME',
        'Profile', 'PSCulture', 'PSUICulture', 'PSEdition', 'PSBoundParameters', 'PSStyle', 'Console', 'ExecutionContext',
        'NestedPromptLevel', 'ShellId', 'ConfirmPreference', 'DebugPreference', 'ErrorActionPreference', 'ErrorView',
        'FormatEnumerationLimit', 'InformationPreference', 'MaximumHistoryCount', 'OutputEncoding', 'ProgressPreference',
        'PSDefaultParameterValues', 'PSModuleAutoLoadingPreference', 'VerbosePreference', 'WarningPreference',
        'WhatIfPreference', 'PSDebugPreference', 'PSDebugContext')
    $uses = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) |
        ForEach-Object { $_.VariablePath.UserPath } | Sort-Object -Unique
    return @($uses | Where-Object {
            $automatic -notcontains $_ -and
            -not $_.StartsWith('script:') -and -not $_.StartsWith('global:') -and
            -not $_.StartsWith('env:') -and -not $_.StartsWith('local:') -and -not $_.StartsWith('using:') -and
            -not $assigned.Contains($_)
        })
}

function Get-SnapshotState {
    # Windows paths are case-insensitive; compare exact names to know the casing.
    param([string]$Dir)
    $names = @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    return [PSCustomObject]@{
        Cased = $names -ccontains 'V8_context_snapshot.bin'
        Lower = $names -ccontains 'v8_context_snapshot.bin'
    }
}

Write-Host " SpotX + Spicetify offline end-to-end verification" -ForegroundColor Cyan
Write-Host " cache: $CacheDir" -ForegroundColor DarkGray
Write-Host " out:   $OutDir" -ForegroundColor DarkGray

# The sandbox must not touch a real Spotify install or create one. Record the
# pre-state and clean up anything this verification creates.
$realAppSpotify = Join-Path $env:APPDATA "Spotify"
$realLocalSpotify = Join-Path $env:LOCALAPPDATA "Spotify"
$realAppExisted = Test-Path $realAppSpotify
$realLocalExisted = Test-Path $realLocalSpotify
if ($realAppExisted -or $realLocalExisted) {
    Write-Warning "A real Spotify directory exists; the sandbox run will leave it untouched."
}

# ---------------------------------------------------------------------------
# 1. Artifacts
# ---------------------------------------------------------------------------
Write-Step "Fetching pinned artifacts"
$installer = Get-DownloadedFile -Url $SpotifySetupUrl -Path (Join-Path $CacheDir "SpotifySetup-1.3.4.exe") -ExpectedSize $SpotifySetupSize -Name "Spotify 1.3.4 installer"
$spicetifyZip = Get-DownloadedFile -Url $SpicetifyZipUrl -Path (Join-Path $CacheDir "spicetify-2.45.3-windows-x64.zip") -Name "Spicetify 2.45.3"
$marketplaceZip = Get-DownloadedFile -Url $MarketplaceZipUrl -Path (Join-Path $CacheDir "marketplace.zip") -Name "Marketplace release"
$installerSha = Get-FileHash256 $installer
Assert-That "Spotify installer size/hash pinned" ((Get-Item $installer).Length -eq $SpotifySetupSize) -Detail "sha256 $installerSha"

$work = Join-Path $CacheDir "work"
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Force -Path $work | Out-Null

# ---------------------------------------------------------------------------
# 2. Extract the real client and run the real SpotX against it
# ---------------------------------------------------------------------------
Write-Step "Extracting Spotify 1.3.4 (no install)"
$extracted = Join-Path $work "client"
New-Item -ItemType Directory -Force -Path $extracted | Out-Null
$appInstallBefore = Get-InstallFingerprint
$proc = Start-Process -FilePath $installer -ArgumentList '/extract', "`"$extracted`"" -Wait -PassThru -WindowStyle Hidden
Assert-That "installer /extract exit code 0" ($proc.ExitCode -eq 0) -Detail "exit $($proc.ExitCode)"
Assert-That "extraction leaves a real Spotify install untouched" ((Get-InstallFingerprint) -eq $appInstallBefore) -Detail $(if ($realAppExisted) { '%APPDATA%\Spotify files unchanged' } else { 'still absent (%APPDATA%)' })

$xpuiSpa = Join-Path $extracted "Apps\xpui.spa"
$spaSha = Get-FileHash256 $xpuiSpa
Assert-That "xpui.spa matches the pinned 1.3.4 hash" ($spaSha -eq $XpuiSpaSha256) -Detail "sha256 $spaSha"

Write-Step "Running the current SpotX against the sandbox (-SpotifyPath)"
$spotxScript = Get-DownloadedFile -Url "https://raw.githubusercontent.com/SpotX-Official/SpotX/main/run.ps1" -Path (Join-Path $CacheDir "run_spotx.ps1") -Name "SpotX run.ps1"
# Hash splatting: array splatting would pass the switches as positional values.
$spotxParams = @{
    SpotifyPath                = $extracted
    confirm_uninstall_ms_spoti = $true
    confirm_spoti_recomended_over = $true
    new_theme                  = $true
    block_update_on            = $true
    podcasts_on                = $true
    devtools                   = $true
    exp_spotify                = $true
    adsections_off             = $true
    cache_limit                = '20000'
    topsearchbar               = $true
    newFullscreenMode          = $true
    rightsidebarcolor          = $true
    hide_col_icon_off          = $true
    no_pause                   = $true
    defender_exclusions_off    = $true
    no_shortcut                = $true
}
$previousEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & $spotxScript @spotxParams *> (Join-Path $work "spotx.log")
}
finally {
    $ErrorActionPreference = $previousEap
}
$spotxState = Get-SnapshotState -Dir $extracted
Assert-That "SpotX patched the sandbox" (Test-Path (Join-Path $extracted "Apps\xpui.spa")) -Detail "xpui.spa present"
Assert-That "SpotX snapshot casing hack reproduced" ($spotxState.Cased -and -not $spotxState.Lower) -Detail "V8_context_snapshot.bin"

# SpotX converts the V8 snapshot into Apps/xpui/xpui.js inside the spa.
$spaEntries = & {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Join-Path $extracted "Apps\xpui.spa"))
    try { $zip.Entries | ForEach-Object { $_.FullName } } finally { $zip.Dispose() }
}
Assert-That "SpotX rebuilt xpui.js inside xpui.spa" ($spaEntries -contains "xpui.js") -Detail "rspack bundle present"

# ---------------------------------------------------------------------------
# 3. Spicetify 2.45.3 + Marketplace, fully portable
# ---------------------------------------------------------------------------
Write-Step "Applying Spicetify 2.45.3 + Marketplace in the sandbox"
$spicetifyDir = Join-Path $work "spicetify"
Expand-Zip -Zip $spicetifyZip -Destination $spicetifyDir
$spicetifyExe = Join-Path $spicetifyDir "spicetify.exe"
Assert-That "spicetify.exe extracted" (Test-Path $spicetifyExe) -Detail "v2.45.3 windows-x64"

$spConfig = Join-Path $work "sp-config"
New-Item -ItemType Directory -Force -Path (Join-Path $spConfig "CustomApps") | Out-Null
$marketApp = Join-Path $spConfig "CustomApps\marketplace"
$marketTmp = Join-Path $work "marketplace-tmp"
Expand-Zip -Zip $marketplaceZip -Destination $marketTmp
New-Item -ItemType Directory -Force -Path $marketApp | Out-Null
Get-ChildItem -Path (Join-Path $marketTmp "marketplace-dist") -Force | ForEach-Object {
    Move-Item $_.FullName -Destination $marketApp -Force
}

# Spicetify reads the Spotify version from the client's prefs file.
Set-Content -Path (Join-Path $extracted "prefs") -Value 'app.last-launched-version="1.3.4.258.gc60b10b0946a"' -Encoding ASCII

$previousConfig = $env:SPICETIFY_CONFIG
$previousEap = $ErrorActionPreference
$env:SPICETIFY_CONFIG = $spConfig
# Native stderr must not become a terminating error under $ErrorActionPreference='Stop'.
$ErrorActionPreference = 'Continue'
try {
    & $spicetifyExe config spotify_path $extracted *> (Join-Path $work "spicetify-config.log")
    & $spicetifyExe config prefs_path (Join-Path $extracted "prefs") *>> (Join-Path $work "spicetify-config.log")
    & $spicetifyExe config custom_apps marketplace *>> (Join-Path $work "spicetify-config.log")
    # -n/--no-restart: never launch the sandbox client (verification is headless).
    & $spicetifyExe -n backup apply *> (Join-Path $work "spicetify-apply.log")
    $applyExit = $LASTEXITCODE
}
finally {
    $env:SPICETIFY_CONFIG = $previousConfig
    $ErrorActionPreference = $previousEap
}
Assert-That "spicetify backup apply exit code 0" ($applyExit -eq 0) -Detail "Spicetify 2.45.3 on Spotify 1.3.4"
Assert-That "real install untouched by the whole run (%APPDATA%)" ((Get-InstallFingerprint) -eq $appInstallBefore) -Detail $(if ($realAppExisted) { '%APPDATA%\Spotify files unchanged' } else { 'no %APPDATA%\Spotify created' })
Assert-That "no real Spotify runtime dir created (%LOCALAPPDATA%)" ($realLocalExisted -or -not (Test-Path $realLocalSpotify)) -Detail $(if ($realLocalExisted) { 'pre-existing, untouched' } else { 'no %LOCALAPPDATA%\Spotify created' })
if (-not $realAppExisted -and (Test-Path $realAppSpotify)) { Remove-Item $realAppSpotify -Recurse -Force -ErrorAction SilentlyContinue }
if (-not $realLocalExisted -and (Test-Path $realLocalSpotify)) { Remove-Item $realLocalSpotify -Recurse -Force -ErrorAction SilentlyContinue }

$appsDir = Join-Path $extracted "Apps\xpui"
$xpuiJs = Join-Path $appsDir "xpui.js"
$wrapperJs = Join-Path $appsDir "helper\spicetifyWrapper.js"
$routeJs = Join-Path $appsDir "spicetify-routes-marketplace.js"

# ---------------------------------------------------------------------------
# 4. Pre-fix state: Spicetify must register custom apps natively
# ---------------------------------------------------------------------------
Write-Step "Asserting Spicetify's native custom-app registration"
$beforeXpui = [System.IO.File]::ReadAllText($xpuiJs, [System.Text.Encoding]::UTF8)
$beforeWrapperHash = Get-FileHash256 $wrapperJs
$beforeRouteHash = Get-FileHash256 $routeJs
$beforeXpuiHash = Get-FileHash256 $xpuiJs

Assert-That "route bundle generated" (Test-Path $routeJs) -Detail "spicetify-routes-marketplace.js"
Assert-That "chunk map has the app" ($beforeXpui.Contains('"spicetify-routes-marketplace":"spicetify-routes-marketplace"')) -Detail ".u / miniCssF maps"
Assert-That "CSS allowlist has the app" ($beforeXpui.Contains('"spicetify-routes-marketplace":1')) -Detail "n.f.miniCss allowlist"
Assert-That "wrapper ships native rspack support" ($beforeXpui.Contains('rspackChunk')) -Detail "rspackChunk consumed by the bundle"

# ---------------------------------------------------------------------------
# 5. Run the updated fix.ps1 against the sandbox
# ---------------------------------------------------------------------------
Write-Step "Running fix.ps1 -SpotifyDir <sandbox>"
$fixReport = Join-Path $OutDir "fix-report.json"
# Custom-app compatibility fixtures (D2): the real apps live in the user's
# Spicetify folders, so the E2E points fix.ps1 at fixtures that carry the exact
# anchor strings instead of touching the machine's installed apps.
$d2Root = Join-Path $work "d2-apps"
$d2User = Join-Path $d2Root "user"
$d2Cli = Join-Path $d2Root "cli"
New-Item -ItemType Directory -Force -Path (Join-Path $d2User "stats"), (Join-Path $d2User "marketplace"), (Join-Path $d2Cli "lyrics-plus"), (Join-Path $d2Cli "reddit") | Out-Null
$d2ThemeDir = Join-Path $d2Root "theme"
New-Item -ItemType Directory -Force -Path $d2ThemeDir | Out-Null
foreach ($fixtureApp in @("stats", "marketplace", "lyrics-plus", "Enhancify")) {
    $manifestDir = if ($fixtureApp -eq "stats" -or $fixtureApp -eq "marketplace") { Join-Path $d2User $fixtureApp } else { Join-Path $d2Cli $fixtureApp }
    New-Item -ItemType Directory -Force -Path $manifestDir | Out-Null
    '{ "name": "' + $fixtureApp + '", "icon": "<svg viewBox=\"0 0 99 99\"><path d=\"M0 0h1v1H0z\"/></svg>" }' | Set-Content -Path (Join-Path $manifestDir "manifest.json") -Encoding ascii
}
$d2Topbar = 'const nav = document.querySelector(".main-topBar-topbarContentWrapper");'
Set-Content -Path (Join-Path $d2User "stats\index.js") -Value $d2Topbar -Encoding ascii
Set-Content -Path (Join-Path $d2User "marketplace\index.js") -Value $d2Topbar -Encoding ascii
$d2Lyrics = @'
const vpChain = document.querySelector(".Root__main-view .os-viewport") ?? document.querySelector(".Root__main-view .main-view-container__scroll-node");
this.viewPort = document.querySelector(".main-view-container .os-viewport");
this.mainViewOffsetTop = document.querySelector(".Root__main-view").offsetTop;
const topBar = document.querySelector(".main-topBar-topbarContentWrapper");
'@
Set-Content -Path (Join-Path $d2Cli "lyrics-plus\index.js") -Value $d2Lyrics -Encoding ascii
$d2TabBar = @'
const resizeHost = document.querySelector(".Root__main-view .os-resize-observer-host, .Root__main-view .os-size-observer, .Root__main-view .main-view-container__scroll-node");
const [windowSize, setWindowSize] = useState(resizeHost.clientWidth);
const resizeHandler = () => setWindowSize(resizeHost.clientWidth);
observer.observe(resizeHost);
'@
# The real tab bar portals into the 1.2.x top-bar container; reproduce that
# exactly (tabs included) so the tabPortal patch has something to match.
$d2Tab = [char]9
$d2TabBar += (@(
        'const TabBarContext = ({ children }) => {'
        ($d2Tab + 'return Spicetify.ReactDOM.createPortal(')
        ($d2Tab + $d2Tab + 'react.createElement(')
        ($d2Tab + $d2Tab + $d2Tab + '"div",')
        ($d2Tab + $d2Tab + $d2Tab + '{')
        ($d2Tab + $d2Tab + $d2Tab + $d2Tab + 'className: "main-topBar-topbarContent",')
        ($d2Tab + $d2Tab + $d2Tab + '},')
        ($d2Tab + $d2Tab + $d2Tab + 'children')
        ($d2Tab + $d2Tab + '),')
        ($d2Tab + $d2Tab + 'document.querySelector(".main-topBar-topbarContentWrapper")')
        ($d2Tab + ');')
        '};'
    ) -join "`n") + "`n"
Set-Content -Path (Join-Path $d2Cli "lyrics-plus\TabBar.js") -Value $d2TabBar -Encoding ascii
Set-Content -Path (Join-Path $d2Cli "reddit\TabBar.js") -Value $d2TabBar -Encoding ascii

$fixPs1 = Join-Path $RepoRoot "fix.ps1"
$previousEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    # -JsHelperDir points at the sandbox copy of the CLI so the template
    # translation is verified without touching the machine's real Spicetify.
    & powershell -NoProfile -ExecutionPolicy Bypass -File $fixPs1 -Quiet -NoStop -JsHelperDir (Join-Path $spicetifyDir "jsHelper") -I18nDir (Join-Path $RepoRoot "i18n") -SpotifyDir $extracted -SpicetifyUserAppsDir $d2User -SpicetifyCliAppsDir $d2Cli -ThemeDir $d2ThemeDir -ReportPath $fixReport
    $fixExit = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previousEap
}
Assert-That "fix.ps1 exit code 0" ($fixExit -eq 0) -Detail "report: $fixReport"

$afterXpui = [System.IO.File]::ReadAllText($xpuiJs, [System.Text.Encoding]::UTF8)
$afterWrapperHash = Get-FileHash256 $wrapperJs
$afterRouteHash = Get-FileHash256 $routeJs
$afterXpuiHash = Get-FileHash256 $xpuiJs

$afterSnapshot = Get-SnapshotState -Dir $extracted
# The provider fallbacks must land in the client bundle (they are the reason
# switching between the extra apps in the left sidebar used to crash).
Assert-That "xpui.js got the useNavigateStable fallback" ($afterXpui.Contains('/*fusion:nav*/')) -Detail "hook no longer throws without the provider"
Assert-That "xpui.js got the RemoteConfig fallback" ($afterXpui.Contains('/*fusion:remoteconfig*/')) -Detail "context default returns definition defaults"
Assert-That "xpui.js got the Registry fallback" ($afterXpui.Contains('/*fusion:registry*/')) -Detail "registry resolves to a no-op store"
# The wrapper must be self-starting but must NOT carry the obsolete name-based
# URI injection (that one would skip Spicetify's isXxx helpers).
$afterWrapper = [System.IO.File]::ReadAllText($wrapperJs, [System.Text.Encoding]::UTF8)
Assert-That "wrapper URI resolver self-starting" ($afterWrapper.Contains('if(!Spicetify.URI)Spicetify.URI={};')) -Detail "placeholder created instead of waiting forever"
Assert-That "no legacy name-based URI injection" (-not $afterWrapper.Contains('Spicetify.URI=s')) -Detail "Spicetify's own finders stay in charge"
# The route bundle may legitimately change (D2 custom-app patches), but its
# Rspack push header must stay intact.
$beforeRouteText = [System.IO.File]::ReadAllText($routeJs, [System.Text.Encoding]::UTF8)
Assert-That "route bundle push header intact" ($beforeRouteText.Substring(0, [Math]::Min(200, $beforeRouteText.Length)).Contains('rspackChunk')) -Detail "header still negotiates rspackChunk"
Assert-That "snapshot casing normalized back to lowercase" ($afterSnapshot.Lower -and -not $afterSnapshot.Cased) -Detail "v8_context_snapshot.bin"

$report = Get-Content -Path $fixReport -Raw | ConvertFrom-Json
$failedPatches = @($report.results | Where-Object { $_.status -eq 'failed' })
Assert-That "fix report has no failed patches" ($failedPatches.Count -eq 0) -Detail "$($report.results.Count) patch entries"
# C: the wrapper's URI resolver must be made self-starting, otherwise
# Spicetify.URI stays undefined and every extension using it throws at load.
$deployedWrapper = [System.IO.File]::ReadAllText((Join-Path $appsDir "helper\spicetifyWrapper.js"), [System.Text.Encoding]::UTF8)
$templateWrapper = [System.IO.File]::ReadAllText((Join-Path $spicetifyDir "jsHelper\spicetifyWrapper.js"), [System.Text.Encoding]::UTF8)
Assert-That "wrapper URI resolver made self-starting (deployed)" ($deployedWrapper.Contains('if(!Spicetify.URI)Spicetify.URI={};')) -Detail "placeholder created instead of waiting forever"
Assert-That "wrapper URI resolver made self-starting (template)" ($templateWrapper.Contains('if(!Spicetify.URI)Spicetify.URI={};')) -Detail "survives spicetify apply"
$uriPatch = $report.results | Where-Object { $_.Patch -like 'C2: URI self-start*' } | Select-Object -First 1
Assert-That "C2 reported as applied" ($uriPatch -and $uriPatch.status -eq 'applied') -Detail $(if ($uriPatch) { $uriPatch.detail } else { 'missing entry' })

# D2: the custom-app patches must land in the fixtures (all three apps) and the
# result must still be valid JavaScript.
$d2Expected = @(
    'D2: app top-bar container',
    'D2: lyrics-plus main-view selectors',
    'D2: lyrics-plus viewport field',
    'D2: lyrics-plus main-view offset',
    'D2: app resize-host selector',
    'D2: app resize-host null guard',
    'D2: app resize-handler null guard',
    'D2: app ResizeObserver guard',
    'D2: tab-bar portal host'
)
foreach ($name in $d2Expected) {
    $entry = $report.results | Where-Object { $_.Patch -eq $name } | Select-Object -First 1
    Assert-That "$name applied to fixtures" ($entry -and $entry.status -eq 'applied') -Detail $(if ($entry) { "$($entry.status): $($entry.detail)" } else { 'missing entry' })
}
$d2Files = @(
    (Join-Path $d2User "stats\index.js"),
    (Join-Path $d2Cli "lyrics-plus\index.js"),
    (Join-Path $d2Cli "lyrics-plus\TabBar.js"),
    (Join-Path $d2Cli "reddit\TabBar.js")
)
foreach ($file in $d2Files) {
    $text = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
    Assert-That "fixture patched: $(Split-Path $file -Leaf) in $(Split-Path (Split-Path $file -Parent) -Leaf)" ($text.Contains('.main-view-container') -or $text.Contains('global-nav-bar')) -Detail "1.3.x fallback present"
}
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
if ($nodeCmd) {
    foreach ($file in $d2Files) {
        $tmpJs = Join-Path $work ("d2check-" + (Split-Path $file -Leaf) + ".mjs")
        Copy-Item $file $tmpJs -Force
        & $nodeCmd.Source --check $tmpJs 2>$null
        Assert-That "fixture parses: $(Split-Path $file -Leaf)" ($LASTEXITCODE -eq 0) -Detail "node --check"
    }
}
else {
    Assert-That "fixture parse check" $true -Detail "skipped (node not installed)"
}

$d2FixturesApplied = $true
# H: the managed styling block must land in the theme and the deployed user.css
# with the Spotify-native values, and must not leave the old rule behind.
$themeCss = Join-Path $d2ThemeDir "user.css"
$clientCss = Join-Path $appsDir "user.css"
Assert-That "theme user.css carries the managed block" ((Get-Content -Path $themeCss -Raw -Encoding UTF8).Contains('/* fusion:navstyle */')) -Detail "theme + deployed"
$styleText = Get-Content -Path $themeCss -Raw -Encoding UTF8
Assert-That "nav entries use Spotify's circular button shape" ($styleText.Contains('border-radius: 9999px')) -Detail "matches Spotify's own 48x48 pills"
Assert-That "nav entries align with the native row" ($styleText.Contains('align-self: center') -and $styleText.Contains('margin: 0 4px')) -Detail "8px rhythm, vertically centred"
Assert-That "no stale 8px rule left in the block" (-not $styleText.Contains('border-radius: 8px')) -Detail "single managed block"
Assert-That "deployed user.css got the block too" ((Get-Content -Path $clientCss -Raw -Encoding UTF8).Contains('/* fusion:navstyle */')) -Detail "applies without a rebuild"

# H: every fixture manifest switched to the Spotify-style glyph
foreach ($fixtureApp in @("stats", "marketplace", "lyrics-plus", "Enhancify")) {
    $manifestDir = if ($fixtureApp -eq "stats" -or $fixtureApp -eq "marketplace") { Join-Path $d2User $fixtureApp } else { Join-Path $d2Cli $fixtureApp }
    $iconText = Get-Content -Path (Join-Path $manifestDir "manifest.json") -Raw -Encoding UTF8
    Assert-That "icon unified: $fixtureApp" ($iconText.Contains('data-fusion-navicon') -and $iconText.Contains('viewBox=\"0 0 16 16\"')) -Detail "single 16x16 currentColor glyph"
}
$routeIcon = Get-Content -Path (Join-Path $appsDir "spicetify-routes-marketplace.json") -Raw -Encoding UTF8
Assert-That "deployed route manifest icon unified" ($routeIcon.Contains('data-fusion-navicon')) -Detail "nav renders the unified glyph"

# C3: the nav renderer must not throw before Spicetify.React is bound
$wrapperDeployed = [System.IO.File]::ReadAllText((Join-Path $appsDir "helper\spicetifyWrapper.js"), [System.Text.Encoding]::UTF8)
$wrapperTemplate = [System.IO.File]::ReadAllText((Join-Path $spicetifyDir "jsHelper\spicetifyWrapper.js"), [System.Text.Encoding]::UTF8)
Assert-That "deployed wrapper guards _renderNavLinks" ($wrapperDeployed.Contains('/*fusion:navlinks*/')) -Detail "returns early until React is bound"
Assert-That "CLI template guards _renderNavLinks" ($wrapperTemplate.Contains('/*fusion:navlinks*/')) -Detail "survives spicetify apply"
# C3 race fix: bind React on demand, keep the hook unconditional, survive an
# init that never sees the chunk callback and a not-yet-installed module.
Assert-That "deployed wrapper binds Spicetify.React on demand" ($wrapperDeployed.Contains('/*fusion:reactbind*/') -and $wrapperDeployed.Contains('if(!Spicetify._fusionBindReact())return null;')) -Detail "first render can call the hook"
Assert-That "CLI template binds Spicetify.React on demand" ($wrapperTemplate.Contains('/*fusion:reactbind*/')) -Detail "survives spicetify apply"
Assert-That "wrapper arms the bounded nav retry" ($wrapperDeployed.Contains('/*fusion:navretry*/') -and $wrapperTemplate.Contains('/*fusion:navretry*/')) -Detail "re-renders once ReactComponent is ready"
Assert-That "exposure scan tolerates a missing module" ($wrapperDeployed.Contains('/*fusion:scan*/') -and $wrapperTemplate.Contains('/*fusion:scan*/')) -Detail "one bad module cannot abort the exposure"
Assert-That "init wait is bounded" ($wrapperDeployed.Contains('/*fusion:noblock*/') -and $wrapperTemplate.Contains('/*fusion:noblock*/')) -Detail "a stuck chunk callback cannot hang the init"
foreach ($c3Name in @('C3: nav render guard', 'C3b: exposure scan guard', 'C3c: bounded init wait')) {
    $c3Entry = $report.results | Where-Object { $_.Patch -eq $c3Name } | Select-Object -First 1
    Assert-That "$c3Name applied in the sandbox" ($c3Entry -and $c3Entry.status -eq 'applied') -Detail $(if ($c3Entry) { $c3Entry.status } else { 'missing entry' })
}

# D2 tabPortal: the lyrics-plus tab bar must never portal into a null host
# (React error #200 replaced the whole view with the fatal dialog).
$tabBarFixture = [System.IO.File]::ReadAllText((Join-Path $d2Cli "lyrics-plus\TabBar.js"), [System.Text.Encoding]::UTF8)
Assert-That "tab bar portal host is patched" ($tabBarFixture.Contains('/*fusion:tabportal*/') -and $tabBarFixture.Contains('fusionTabHost ? Spicetify.ReactDOM.createPortal(fusionTabContent, fusionTabHost)')) -Detail "never portals into null"
Assert-That "tab bar keeps the legacy top-bar lookup first" ($tabBarFixture.Contains('const fusionTabHost =') -and $tabBarFixture.Contains('document.querySelector(".main-topBar-topbarContentWrapper") ||')) -Detail "1.2.x behaviour preserved"

# C4: Spicetify.showNotification must exist and never throw. The upstream compat
# loop only waits for Snackbar.enqueueSnackbar (absent on 1.3.4), so the wrapper
# installs a defensive shim that bridges to Snackbar.enqueueCustomSnackbar.
$notifySnippets = @(
    '/*fusion:notify*/',
    'Object.defineProperty(Spicetify,"showNotification"',
    'enqueueCustomSnackbar',
    'keyPrefix:"fusion-notify"',
    'if(message===null||message===undefined)return void 0;'
)
foreach ($snippet in $notifySnippets) {
    Assert-That "notify shim carries $snippet" ($wrapperDeployed.Contains($snippet) -and $wrapperTemplate.Contains($snippet)) -Detail "deployed + CLI template"
}
Assert-That "upstream enqueueSnackbar branch is untouched" ($wrapperDeployed.Contains('Spicetify.Snackbar.enqueueSnackbar=(l,{variant:h="default",autoHideDuration:y}={})')) -Detail "existing compat branch preserved"
$c4Entry = $report.results | Where-Object { $_.Patch -eq 'C4: showNotification shim' } | Select-Object -First 1
Assert-That "C4: showNotification shim applied in the sandbox" ($c4Entry -and $c4Entry.status -eq 'applied') -Detail $(if ($c4Entry) { $c4Entry.status } else { 'missing entry' })

$shimMatch = [regex]::Match($wrapperDeployed, '\(function\(\)\{/\*fusion:notify\*/[\s\S]*?\}\)\(\)')
Assert-That "notify shim is extractable" $shimMatch.Success -Detail "$($shimMatch.Length) byte(s)"
if ($shimMatch.Success -and $nodeCmd) {
    $shimJs = Join-Path $work "notify-shim.mjs"
    $harness = Join-Path $work "notify-shim-test.mjs"
    Set-Content -Path $shimJs -Value $shimMatch.Value -Encoding ascii
    $testSource = @'
import fs from "node:fs";
const src = fs.readFileSync(process.argv[2], "utf8");
globalThis.Spicetify = { Snackbar: {} };
let calls = [];
globalThis.Spicetify.Snackbar.enqueueCustomSnackbar = (message, opts) => { calls.push({ message, opts }); return "key-1"; };
eval(src);
const S = globalThis.Spicetify;
const fail = (m) => { console.error(m); process.exit(1); };
if (typeof S.showNotification !== "function") fail("showNotification missing");
const ret = S.showNotification("hello", false, 3000);
if (ret !== "key-1") fail("return value not preserved: " + ret);
if (calls.length !== 1 || calls[0].message !== "hello" || calls[0].opts.keyPrefix !== "fusion-notify" || calls[0].opts.autoHideDuration !== 3000) fail("bridge payload wrong: " + JSON.stringify(calls));
calls = [];
S.showNotification();
if (calls.length !== 0) fail("empty message must not bridge");
S.Snackbar.enqueueCustomSnackbar = () => { throw new Error("boom"); };
S.showNotification("throwing");
delete S.Snackbar.enqueueCustomSnackbar;
S.showNotification("missing");
S.Snackbar = undefined;
S.showNotification("nosnack");
if (typeof S.showNotification !== "function") fail("showNotification lost after failures");
S.Snackbar = { enqueueCustomSnackbar: () => "custom" };
let realCalled = false;
S.showNotification = (m) => { realCalled = true; return "real"; };
if (S.showNotification("m") !== "real" || !realCalled) fail("upstream implementation must win");
console.log("notify shim behaviour OK");
'@
    Set-Content -Path $harness -Value $testSource -Encoding ascii
    & $nodeCmd.Source $harness $shimJs *> $null
    Assert-That "notify shim behaves defensively (node)" ($LASTEXITCODE -eq 0) -Detail "bridge / no-op / never throws / upstream wins"
}

# D2 overlap regression guard: app tab bars must never be portaled into the nav
# container (that made the container taller and pushed the icons off the row).
$topbarChain = 'document.querySelector(".main-view-container__scroll-node")'
Assert-That "app top-bar fallback targets the page content" ($d2FixturesApplied -and (Get-Content -Path (Join-Path $d2User "stats\index.js") -Raw -Encoding UTF8).Contains($topbarChain)) -Detail "no nav-container portal"
Assert-That "nav container no longer a portal target" (-not ((Get-Content -Path (Join-Path $d2User "stats\index.js") -Raw -Encoding UTF8).Contains('custom-navlinks-scrollable_container'))) -Detail "prevents the overlap with the extra-app row"

# H: curated nav visibility - Enhancify / Statistics are hidden by default (in
# both nav variants), and -ShowAllApps must be able to bring them back.
Assert-That "curated hide rules landed in both nav variants" ($styleText.Contains('fusion:navhide') -and $styleText.Contains('aria-label="Enhancify"') -and $styleText.Contains('aria-label="Statistics"') -and $styleText.Contains('.main-yourLibraryX-navItem:has(')) -Detail "top bar + expanded library"
$navVis = $report.results | Where-Object { $_.Patch -eq 'H: nav visibility' } | Select-Object -First 1
Assert-That "H: nav visibility reported" ($navVis -and $navVis.status -eq 'applied') -Detail $(if ($navVis) { "$($navVis.status): $($navVis.detail)" } else { 'missing entry' })

$showAllDir = Join-Path $d2Root "theme-showall"
New-Item -ItemType Directory -Force -Path $showAllDir | Out-Null
$showAllReport = Join-Path $OutDir "fix-report-showall.json"
$ErrorActionPreference = 'Continue'
try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $fixPs1 -Quiet -NoStop -ShowAllApps -JsHelperDir (Join-Path $spicetifyDir "jsHelper") -I18nDir (Join-Path $RepoRoot "i18n") -SpotifyDir $extracted -SpicetifyUserAppsDir $d2User -SpicetifyCliAppsDir $d2Cli -ThemeDir $showAllDir -ReportPath $showAllReport
}
finally {
    $ErrorActionPreference = $previousEap
}
$showAllCss = Get-Content -Path (Join-Path $showAllDir "user.css") -Raw -Encoding UTF8
Assert-That "-ShowAllApps regenerates the block without curated hides" ((-not $showAllCss.Contains('fusion:navhide')) -and $showAllCss.Contains('/* fusion:navstyle */')) -Detail "opt-out works"
$showAllVis = (Get-Content -Path $showAllReport -Raw | ConvertFrom-Json).results | Where-Object { $_.Patch -eq 'H: nav visibility' } | Select-Object -First 1
Assert-That "H: nav visibility reports the opt-out" ($showAllVis -and $showAllVis.status -eq 'skipped') -Detail $(if ($showAllVis) { $showAllVis.status } else { 'missing entry' })

$b4 = $report.results | Where-Object { $_.Patch -like 'B4*' } | Select-Object -First 1
Assert-That "B4 reports Spicetify-managed chunk map" ($b4 -and $b4.status -eq 'not-needed') -Detail $(if ($b4) { "$($b4.status): $($b4.detail)" } else { "missing entry" })

# E: Chinese UI for Spicetify's English-only helper panels. The replacement text
# is written as JS unicode escapes so the scripts stay pure ASCII; assert the
# deployed copies and the CLI template were both translated.
$deployedExp = [System.IO.File]::ReadAllText((Join-Path $appsDir "helper\expFeatures.js"), [System.Text.Encoding]::UTF8)
$deployedHome = [System.IO.File]::ReadAllText((Join-Path $appsDir "helper\homeConfig.js"), [System.Text.Encoding]::UTF8)
$templateSidebar = [System.IO.File]::ReadAllText((Join-Path $spicetifyDir "jsHelper\sidebarConfig.js"), [System.Text.Encoding]::UTF8)
Assert-That "deployed expFeatures.js shows Chinese" ($deployedExp.Contains('\u5b9e\u9a8c\u6027\u529f\u80fd')) -Detail "Experimental features -> \u5b9e\u9a8c\u6027\u529f\u80fd"
Assert-That "fallback notice translated (emoji anchor avoided)" ($deployedExp.Contains('\u6b63\u5728\u4f7f\u7528\u517c\u5bb9\u6a21\u5f0f') -and -not $deployedExp.Contains('Using fallback mode')) -Detail "notice text replaced"

# E2: the rows inside the panel list Spotify's own feature flags with English
# descriptions. The project dictionary (keyed by feature name) is injected as a
# lookup so rows render Chinese; flags we do not know yet keep their English
# text, which is why the anchor and the row-label replacement matter.
$featureDictionary = Join-Path $RepoRoot "i18n\exp-features.zh.json"
Assert-That "feature dictionary shipped" (Test-Path $featureDictionary) -Detail $(if (Test-Path $featureDictionary) { "$((Get-Content -Path $featureDictionary -Raw -Encoding UTF8 | ConvertFrom-Json).labels.PSObject.Properties.Count) entries" } else { 'missing' })
Assert-That "feature labels injected into the deployed helper" ($deployedExp.Contains('zhLabel(') -and $deployedExp.Contains('${zhLabel(name, desc)}')) -Detail "lookup + row label"
$mapStart = $deployedExp.IndexOf('zhLabels={')
$mapEnd = $deployedExp.IndexOf('};const zhLabel')
$mapText = if ($mapStart -ge 0 -and $mapEnd -gt $mapStart) { $deployedExp.Substring($mapStart, $mapEnd - $mapStart) } else { '' }
$mapCount = ([regex]::Matches($mapText, '":"')).Count
Assert-That "injected dictionary carries the full label set" ($mapCount -ge 360) -Detail "$mapCount entries"
Assert-That "known flag renders Chinese" ($mapText.Contains('"enableSuperConnect":"\u542f\u7528\u8d85\u7ea7\u8fde\u63a5')) -Detail "enableSuperConnect -> \u542f\u7528\u8d85\u7ea7\u8fde\u63a5"
$templateExp = [System.IO.File]::ReadAllText((Join-Path $spicetifyDir "jsHelper\expFeatures.js"), [System.Text.Encoding]::UTF8)
Assert-That "CLI template got the feature labels too" ($templateExp.Contains('zhLabel(')) -Detail "template patched"
Assert-That "deployed homeConfig.js shows Chinese" ($deployedHome.Contains('\u9996\u9875\u6392\u5e8f')) -Detail "Home config -> \u9996\u9875\u6392\u5e8f"
Assert-That "CLI template sidebarConfig.js translated too" ($templateSidebar.Contains('\u4fa7\u8fb9\u680f\u914d\u7f6e')) -Detail "Sidebar config -> \u4fa7\u8fb9\u680f\u914d\u7f6e"
$uiPatch = $report.results | Where-Object { $_.Patch -like 'E: Chinese UI*' } | Select-Object -First 1
Assert-That "E reported as applied" ($uiPatch -and $uiPatch.status -eq 'applied') -Detail $(if ($uiPatch) { $uiPatch.detail } else { 'missing entry' })

# Idempotency: a second run must not rewrite the translated files.
$deployedExpHash = Get-FileHash256 (Join-Path $appsDir "helper\expFeatures.js")
$deployedHomeHash = Get-FileHash256 (Join-Path $appsDir "helper\homeConfig.js")
$secondReport = Join-Path $OutDir "fix-report-second.json"
$ErrorActionPreference = 'Continue'
try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $fixPs1 -Quiet -NoStop -JsHelperDir (Join-Path $spicetifyDir "jsHelper") -I18nDir (Join-Path $RepoRoot "i18n") -SpotifyDir $extracted -SpicetifyUserAppsDir $d2User -SpicetifyCliAppsDir $d2Cli -ThemeDir $d2ThemeDir -ReportPath $secondReport
}
finally {
    $ErrorActionPreference = $previousEap
}
$secondRun = Get-Content -Path $secondReport -Raw | ConvertFrom-Json
$secondUi = $secondRun.results | Where-Object { $_.Patch -like 'E: Chinese UI*' } | Select-Object -First 1
Assert-That "second run leaves the translations alone" ((Get-FileHash256 (Join-Path $appsDir "helper\expFeatures.js")) -eq $deployedExpHash) -Detail "expFeatures.js unchanged"
Assert-That "second run reports E as not-needed" ($secondUi -and $secondUi.status -eq 'not-needed') -Detail $(if ($secondUi) { $secondUi.status } else { 'missing entry' })
Assert-That "no failed patches after the second run" (@($secondRun.results | Where-Object { $_.status -eq 'failed' }).Count -eq 0) -Detail "$($secondRun.results.Count) entries"
# Regression guard for the Windows PowerShell 5.1 '(' + if-expression trap: when
# the managed block already exists, a parse error used to leave $newCss null and
# WriteAllText truncated user.css to 0 bytes.
$themeCssSecond = Get-Content -Path $themeCss -Raw -Encoding UTF8
Assert-That "second run keeps user.css intact (no truncation)" ($themeCssSecond.Length -gt 100 -and $themeCssSecond.Contains('/* fusion:navstyle */') -and $themeCssSecond.Contains('fusion:navhide')) -Detail "$($themeCssSecond.Length) byte(s) after the second run"
# The legacy URI injection must be absent even if an older fix.ps1 had run.
Assert-That "no legacy 'Spicetify.URI=s' injection left" (-not ([System.IO.File]::ReadAllText($wrapperJs, [System.Text.Encoding]::UTF8)).Contains('Spicetify.URI=s')) -Detail "wrapper clean"

# ---------------------------------------------------------------------------
# 6. Installer bypass self-check (install.ps1 -VerifyOnly)
# ---------------------------------------------------------------------------
Write-Step "Running install.ps1 -VerifyOnly (upstream bypass rules)"
$previousEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "install.ps1") -VerifyOnly *> (Join-Path $work "install-verify.log")
    $verifyExit = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previousEap
}
Assert-That "install.ps1 -VerifyOnly exit code 0" ($verifyExit -eq 0) -Detail "log: $work\install-verify.log"

# ---------------------------------------------------------------------------
# 7. Project links: every script and doc must point at this fork
# ---------------------------------------------------------------------------
Write-Step "Verifying project links"
$expectedRepo = 'https://github.com/Maolaohei/spotx-spicetify-fusion'
$expectedRaw = 'https://raw.githubusercontent.com/Maolaohei/spotx-spicetify-fusion/main'

$linkChecks = @(
    @{ File = 'install.ps1'; Name = 'FusionRepoUrl'; Pattern = '\$FusionRepoUrl\s*=\s*''([^'']+)'''; Expect = $expectedRepo },
    @{ File = 'install.ps1'; Name = 'FusionRepoRaw'; Pattern = '\$FusionRepoRaw\s*=\s*''([^'']+)'''; Expect = $expectedRaw },
    @{ File = 'install.sh'; Name = 'FUSION_REPO_URL'; Pattern = 'FUSION_REPO_URL="([^"]+)"'; Expect = $expectedRepo },
    @{ File = 'install.sh'; Name = 'FUSION_REPO_RAW'; Pattern = 'FUSION_REPO_RAW="([^"]+)"'; Expect = $expectedRaw },
    @{ File = 'fix.ps1'; Name = 'FusionRepoUrl'; Pattern = '\$FusionRepoUrl\s*=\s*''([^'']+)'''; Expect = $expectedRepo },
    @{ File = 'fix.ps1'; Name = 'FusionRepoRaw'; Pattern = '\$FusionRepoRaw\s*=\s*''([^'']+)'''; Expect = $expectedRaw },
    @{ File = 'fix.sh'; Name = 'FUSION_REPO_URL'; Pattern = 'FUSION_REPO_URL="([^"]+)"'; Expect = $expectedRepo },
    @{ File = 'custom-apps.ps1'; Name = 'FusionRepoRaw'; Pattern = '\$FusionRepoRaw\s*=\s*''([^'']+)'''; Expect = $expectedRaw },
    @{ File = 'custom-apps.sh'; Name = 'FUSION_REPO_RAW'; Pattern = 'FUSION_REPO_RAW="([^"]+)"'; Expect = $expectedRaw }
)
foreach ($check in $linkChecks) {
    $content = [System.IO.File]::ReadAllText((Join-Path $RepoRoot $check.File))
    $m = [regex]::Match($content, $check.Pattern)
    $value = if ($m.Success) { $m.Groups[1].Value } else { '<missing>' }
    Assert-That "$($check.File): $($check.Name) = fork URL" ($value -eq $check.Expect) -Detail $value
}

# Scripts may only mention the upstream repo in an attribution comment. This runs
# through git grep on purpose: some endpoint security products quarantine
# custom-apps.ps1 as soon as a PowerShell process opens it.
function Get-GitGrepLines {
    param([string]$Pattern, [string[]]$Paths)
    return @(& git -C $RepoRoot grep -n -E $Pattern -- @Paths 2>$null)
}

$grepOutput = Get-GitGrepLines -Pattern 'ZGQ-inc/spotx-spicetify-fusion' -Paths @('install.ps1', 'install.sh', 'fix.ps1', 'fix.sh', 'custom-apps.ps1', 'custom-apps.sh', 'fix-marketplace-nav.ps1')
$stale = @()
foreach ($line in @($grepOutput)) {
    if ($line -match 'Upstream|MIT') { continue }
    $stale += $line
}
Assert-That "scripts only cite upstream as attribution" ($stale.Count -eq 0) -Detail $(if ($stale.Count) { $stale -join '; ' } else { 'no stale upstream links' })

# Docs: the one-liners must use this fork and no longer the upstream proxy domain.
foreach ($doc in @('README.md', 'README_ZH.md')) {
    $d = [System.IO.File]::ReadAllText((Join-Path $RepoRoot $doc))
    $cmdCount = ([regex]::Matches($d, [regex]::Escape("$expectedRaw/"))).Count
    Assert-That "$doc uses the fork raw URLs" ($cmdCount -ge 6 -and -not $d.Contains('spicetify.zgqinc.gq')) -Detail "$cmdCount command link(s), no proxy domain"
}

# Published URLs must resolve (the raw branch is the one users install from).
foreach ($published in @('fix.ps1', 'fix.sh', 'install.ps1', 'install.sh', 'custom-apps.ps1', 'custom-apps.sh', 'Marketplace-backup.json')) {
    $url = "$expectedRaw/$published"
    $status = 0
    try {
        $resp = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 30
        $status = [int]$resp.StatusCode
    }
    catch {
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
    }
    Assert-That "published: $published" ($status -eq 200) -Detail "HTTP $status"
}

# ---------------------------------------------------------------------------
# 8. The documented one-liner path: iwr -useb <url> | iex
# ---------------------------------------------------------------------------
Write-Step "Verifying the one-liner install path (iwr | iex)"

# PowerShell 7 does not honour the response charset here, so a UTF-8 BOM is
# decoded as '???'. At the start of a .ps1 that turns the header comment into a
# command, and any '&' inside it becomes the background operator (observed: a
# stray background job plus "The term 'Extensions' is not recognized"). Keep
# every published script pure ASCII so no charset can break it.
# PowerShell 5.1 reads a BOM-less .ps1 with the ANSI code page, so non-ASCII in
# any of these files can silently break string literals (a GBK-trailing byte even
# eats the closing quote). Keep every script we run pure ASCII.
foreach ($script in @('install.ps1', 'fix.ps1', 'custom-apps.ps1', 'fix-marketplace-nav.ps1', 'tools/verify-offline.ps1')) {
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $RepoRoot $script))
    $nonAscii = @($bytes | Where-Object { $_ -gt 127 })
    Assert-That "$script is pure ASCII (iex-safe)" ($nonAscii.Count -eq 0) -Detail $(if ($nonAscii.Count) { "$($nonAscii.Count) non-ASCII byte(s), first at offset $([array]::IndexOf($bytes, $nonAscii[0]))" } else { 'no BOM, no non-ASCII' })
}

# 'exit' inside Invoke-Expression closes the caller's console; the scripts must
# use $host.SetShouldExit(n) + return instead.
$exitStatements = @(& git -C $RepoRoot grep -n -E '^\s*exit\b' -- install.ps1 fix.ps1 custom-apps.ps1 fix-marketplace-nav.ps1 2>$null)
Assert-That "no top-level 'exit' in iex-able scripts" ($exitStatements.Count -eq 0) -Detail $(if ($exitStatements.Count) { $exitStatements -join '; ' } else { 'SetShouldExit only' })

$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1
$pythonCmd = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $pythonCmd) { $pythonCmd = Get-Command python3 -ErrorAction SilentlyContinue | Select-Object -First 1 }

if ($pwshCmd -and $pythonCmd) {
    $probe = Join-Path $work "iwr-path-probe.ps1"
    @'
param([string]$Url)
$text = (Invoke-WebRequest -Uri $Url -UseBasicParsing).ToString()
$tok = $null
$err = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tok, [ref]$err)
$first = if ($text.Length -gt 0) { [string]$text[0] } else { '' }
$kind = if ($tok.Count -gt 0) { $tok[0].Kind.ToString() } else { '' }
$line = if ($tok.Count -gt 0) { $tok[0].Extent.StartLineNumber } else { 0 }
[PSCustomObject]@{ First = $first; Errors = $err.Count; FirstToken = $kind; FirstTokenLine = $line } | ConvertTo-Json -Compress
'@ | Set-Content -Path $probe -Encoding ascii

    # Serve the working tree locally and fetch it with PowerShell 7 exactly like
    # the documented one-liner does. A mangled first byte turns the header
    # comment into code (or the '&' into the background operator), which shows
    # up as a non-comment first token.
    $port = 8791
    $server = $null
    try {
        $server = Start-Process -FilePath $pythonCmd.Source -ArgumentList '-m', 'http.server', "$port", '--bind', '127.0.0.1', '--directory', $RepoRoot -PassThru -WindowStyle Hidden
        Start-Sleep -Seconds 2
        foreach ($script in @('install.ps1', 'fix.ps1', 'custom-apps.ps1')) {
            $raw = & $pwshCmd.Source -NoProfile -ExecutionPolicy Bypass -File $probe -Url "http://127.0.0.1:$port/$script" 2>$null | Select-Object -Last 1
            $result = $raw | ConvertFrom-Json
            $ok = ($result.FirstToken -eq 'Comment') -and ($result.FirstTokenLine -eq 1) -and ($result.Errors -eq 0) -and ($result.First -ne '?')
            Assert-That "$script survives PowerShell 7 iwr|iex" $ok -Detail "first='$($result.First)' parseErrors=$($result.Errors) firstToken=$($result.FirstToken)@L$($result.FirstTokenLine)"
        }
    }
    finally {
        if ($server) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
    }
}
else {
    Assert-That "PowerShell 7 iwr|iex path" $true -Detail "skipped (pwsh or python not installed)"
}

# Behavioural guard for the failure paths: running the script through iex must
# not terminate the session (a stray 'exit' used to close the console).
if ($pwshCmd) {
    $iexProbe = Join-Path $work "iex-safety-probe.ps1"
    $sandboxApp = Join-Path $work "iex-appdata"
    $sandboxLocal = Join-Path $work "iex-localappdata"
    New-Item -ItemType Directory -Force -Path $sandboxApp, $sandboxLocal | Out-Null
    foreach ($case in @(
            @{ Script = 'custom-apps.ps1'; Expect = 'spicetify CLI not found' },
            @{ Script = 'fix.ps1'; Expect = 'Spotify installation directory not found' }
        )) {
        $target = (Join-Path $RepoRoot $case.Script).Replace("'", "''")
        @"
`$env:APPDATA = '$sandboxApp'
`$env:LOCALAPPDATA = '$sandboxLocal'
`$env:PATH = "`$env:SystemRoot\System32"   # keep spicetify out of reach
`$code = [System.IO.File]::ReadAllText('$target')
iex `$code
Write-Host 'IEX-SENTINEL-ALIVE'
"@ | Set-Content -Path $iexProbe -Encoding ascii

        $previousEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = & $pwshCmd.Source -NoProfile -ExecutionPolicy Bypass -File $iexProbe 2>&1 | Out-String
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousEap
        }
        $survived = $output.Contains('IEX-SENTINEL-ALIVE')
        $reported = $output.Contains($case.Expect)
        Assert-That "$($case.Script) iex failure path keeps the session alive" ($survived -and $reported -and $exitCode -eq 1) -Detail "sentinel=$survived reported=$reported exit=$exitCode"
    }
}
else {
    Assert-That "iex failure-path safety" $true -Detail "skipped (pwsh not installed)"
}

# Elevation guards: Spicetify refuses to run elevated/root (files written by an
# elevated process can make Spotify show a black window), so the installers must
# detect it and stop with instructions.
foreach ($check in @(
        @{ File = 'install.ps1'; Pattern = 'WindowsBuiltInRole\]::Administrator' },
        @{ File = 'custom-apps.ps1'; Pattern = 'WindowsBuiltInRole\]::Administrator' },
        @{ File = 'install.sh'; Pattern = 'id -u' },
        @{ File = 'custom-apps.sh'; Pattern = 'id -u' },
        @{ File = 'fix.ps1'; Pattern = 'KeepEnglish' },
        @{ File = 'fix.sh'; Pattern = 'KEEP_ENGLISH' }
    )) {
    $lines = Get-GitGrepLines -Pattern $check.Pattern -Paths @($check.File)
    Assert-That "$($check.File) handles $($check.Pattern)" ($lines.Count -ge 1) -Detail "$($lines.Count) reference(s)"
}

# No script may read a variable it never assigns: an undefined variable used to
# abort install.ps1 right after the hotfix paragraph.
foreach ($script in @('install.ps1', 'fix.ps1', 'custom-apps.ps1', 'fix-marketplace-nav.ps1', 'tools/verify-offline.ps1')) {
    $undefined = Get-UsedButUndefinedVariables -Path (Join-Path $RepoRoot $script)
    Assert-That "$script has no undefined variables" ($undefined.Count -eq 0) -Detail $(if ($undefined.Count) { $undefined -join ', ' } else { 'all reads assigned' })
}

# ---------------------------------------------------------------------------
# 9. Curated custom apps (Enhancify / Stats / lyrics-plus)
# ---------------------------------------------------------------------------
Write-Step "Verifying the curated custom apps"

# Content checks go through git grep: a PowerShell process must never open
# custom-apps.ps1 (some endpoint security suites quarantine it on read).
$psDelegates = Get-GitGrepLines -Pattern 'FusionRepoRaw/fix\.ps1' -Paths @('custom-apps.ps1')
$shDelegates = Get-GitGrepLines -Pattern 'FUSION_REPO_RAW/fix\.sh' -Paths @('custom-apps.sh')
Assert-That "custom-apps.ps1 delegates to fix.ps1" ($psDelegates.Count -ge 1) -Detail "$($psDelegates.Count) reference(s)"
Assert-That "custom-apps.sh delegates to fix.sh" ($shDelegates.Count -ge 1) -Detail "$($shDelegates.Count) reference(s)"

$duplicated = Get-GitGrepLines -Pattern '0!==d\[e\]&&\(\{|rspackChunk\|\|=\[\]' -Paths @('custom-apps.ps1', 'custom-apps.sh')
Assert-That "no duplicated Rspack pipeline in custom-apps.*" ($duplicated.Count -eq 0) -Detail $(if ($duplicated.Count) { $duplicated -join '; ' } else { 'single patch pipeline' })

$statsProbe = Get-GitGrepLines -Pattern 'os-resize-observer-host' -Paths @('custom-apps.ps1', 'custom-apps.sh')
Assert-That "Stats layout patch is probe-based" ($statsProbe.Count -ge 2) -Detail "$($statsProbe.Count) anchor reference(s)"

$enhZipFilter = @((Get-GitGrepLines -Pattern '\.zip' -Paths @('custom-apps.ps1', 'custom-apps.sh')).Count)
Assert-That "Enhancify asset selection filters .zip" ($enhZipFilter[0] -ge 2) -Detail "$($enhZipFilter[0]) zip reference(s)"

# Spicetify >= 2.45 appends ONE value per call for list keys (custom_apps,
# extensions). The pre-2.45 multi-value call is not just ignored: the extra
# arguments are read as config field names, so only the first value lands.
# The scripts must use the per-item form; verify it against the real CLI.
$oldStyleListCalls = Get-GitGrepLines -Pattern "'custom_apps', 'Enhancify'|'extensions', 'bookmark\.js'|config custom_apps Enhancify|config extensions bookmark" -Paths @('custom-apps.ps1', 'custom-apps.sh')
Assert-That "custom-apps.* avoid the pre-2.45 multi-value config call" ($oldStyleListCalls.Count -eq 0) -Detail $(if ($oldStyleListCalls.Count) { $oldStyleListCalls -join '; ' } else { 'per-item calls only' })

# Curated nav set: Enhancify and Statistics are still fetched by custom-apps.*
# (so their files/patches stay available) but must NOT be enabled - only
# lyrics-plus + Marketplace land in custom_apps.
$customPs1Text = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'custom-apps.ps1'), [System.Text.Encoding]::UTF8)
$customShText = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'custom-apps.sh'), [System.Text.Encoding]::UTF8)
Assert-That "curated enable set is lyrics-plus + marketplace" ($customPs1Text.Contains("@('lyrics-plus', 'marketplace')") -and -not $customPs1Text.Contains("@('Enhancify', 'stats', 'lyrics-plus')")) -Detail "Enhancify / Stats stay disabled"
Assert-That "curated shell enable set matches" ($customShText.Contains('for app in lyrics-plus marketplace; do') -and -not $customShText.Contains('for app in Enhancify stats lyrics-plus; do')) -Detail "same set on Linux"

# Windows PowerShell 5.1 cannot parse `(if (..) {..} else {..})` as an
# expression; the published scripts must stay runnable from `iwr | iex` on 5.1.
$ps7OnlyExpr = Get-GitGrepLines -Pattern '= \(if \(' -Paths @('fix.ps1', 'install.ps1', 'custom-apps.ps1', 'fix-marketplace-nav.ps1')
Assert-That "published .ps1 stay PowerShell 5.1 compatible" ($ps7OnlyExpr.Count -eq 0) -Detail $(if ($ps7OnlyExpr.Count) { $ps7OnlyExpr -join '; ' } else { 'no PS7-only (if ...) expression' })

$uiConfig = Join-Path $work "ui-config"
New-Item -ItemType Directory -Force -Path $uiConfig | Out-Null
$previousConfig = $env:SPICETIFY_CONFIG
$previousEap = $ErrorActionPreference
$env:SPICETIFY_CONFIG = $uiConfig
$ErrorActionPreference = 'Continue'
try {
    foreach ($app in @('Enhancify', 'stats', 'lyrics-plus')) {
        & $spicetifyExe config custom_apps $app | Out-Null
    }
    $listed = (& $spicetifyExe config custom_apps 2>&1 |
            ForEach-Object { ($_ -replace "\x1b\[[0-9;]*m", '').Trim() } |
            Where-Object { $_ }) -join '|'
}
finally {
    $env:SPICETIFY_CONFIG = $previousConfig
    $ErrorActionPreference = $previousEap
}
$listed = $listed.Trim()
$missing = @('Enhancify', 'stats', 'lyrics-plus') | Where-Object { $listed -notmatch [regex]::Escape($_) }
Assert-That "per-item config calls append every value (real CLI)" ($missing.Count -eq 0) -Detail "custom_apps = $listed"

# Real upstream artifacts: the pinned releases the scripts resolve.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$statsZip = Get-DownloadedFile -Url "https://github.com/harbassan/spicetify-apps/releases/download/stats-v1.1.3/spicetify-stats.release.zip" -Path (Join-Path $CacheDir "stats-v1.1.3.zip") -Name "Stats v1.1.3"
$enhancifyZip = Get-DownloadedFile -Url "https://github.com/ECE49595-Team-6/EnhancifyInstall/releases/download/1.0.0/EnhancifyInstall-1.0.0.zip" -Path (Join-Path $CacheDir "EnhancifyInstall-1.0.0.zip") -Name "Enhancify 1.0.0"

$statsZipHandle = [System.IO.Compression.ZipFile]::OpenRead($statsZip)
try {
    $statsEntry = $statsZipHandle.GetEntry('stats/index.js')
    $reader = New-Object System.IO.StreamReader($statsEntry.Open())
    try { $statsJs = $reader.ReadToEnd() } finally { $reader.Dispose() }
}
finally { $statsZipHandle.Dispose() }
Assert-That "Stats v1.1.3 no longer needs the layout patch" (-not $statsJs.Contains('.Root__main-view .os-resize-observer-host')) -Detail "$([math]::Round($statsJs.Length / 1024)) KB bundle, anchor absent"

$enhZipHandle = [System.IO.Compression.ZipFile]::OpenRead($enhancifyZip)
try {
    $enhNames = @($enhZipHandle.Entries | ForEach-Object { $_.FullName })
}
finally { $enhZipHandle.Dispose() }
Assert-That "Enhancify 1.0.0 is a flat app bundle" (($enhNames -contains 'manifest.json') -and ($enhNames -contains 'index.js')) -Detail "$($enhNames.Count) entries, manifest + index at root"

# ---------------------------------------------------------------------------
# 10. Artifact
# ---------------------------------------------------------------------------
Write-Step "Writing artifact"
$artifact = [PSCustomObject]@{
    tool            = "tools/verify-offline.ps1"
    timestamp       = (Get-Date).ToString("o")
    spotify         = "1.3.4.258.gc60b10b0946a"
    spicetify       = "2.45.3"
    installerSha256 = $installerSha
    xpuiSpaSha256   = $spaSha
    before          = [PSCustomObject]@{ xpui = $beforeXpuiHash; wrapper = $beforeWrapperHash; route = $beforeRouteHash }
    after           = [PSCustomObject]@{ xpui = $afterXpuiHash; wrapper = $afterWrapperHash; route = $afterRouteHash }
    fixReport       = $report
    assertions      = $Assertions
    failed          = $script:FailureCount
}
$artifactPath = Join-Path $OutDir "offline-e2e.json"
$artifact | ConvertTo-Json -Depth 8 | Set-Content -Path $artifactPath -Encoding UTF8

Write-Host ""
if ($script:FailureCount -eq 0) {
    Write-Host "Offline E2E verification PASSED ($($Assertions.Count) assertions)." -ForegroundColor Green
    Write-Host "Artifact: $artifactPath" -ForegroundColor Green
}
else {
    Write-Host "Offline E2E verification FAILED ($script:FailureCount of $($Assertions.Count) assertions)." -ForegroundColor Red
    Write-Host "Artifact: $artifactPath" -ForegroundColor Red
}

if (-not $KeepWork) {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
else {
    Write-Host "Work dir kept: $work" -ForegroundColor DarkGray
}

exit $(if ($script:FailureCount -eq 0) { 0 } else { 1 })
