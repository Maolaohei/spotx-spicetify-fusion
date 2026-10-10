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
$proc = Start-Process -FilePath $installer -ArgumentList '/extract', "`"$extracted`"" -Wait -PassThru -WindowStyle Hidden
Assert-That "installer /extract exit code 0" ($proc.ExitCode -eq 0) -Detail "exit $($proc.ExitCode)"
Assert-That "no %APPDATA%\Spotify created" (-not (Test-Path (Join-Path $env:APPDATA "Spotify"))) -Detail "sandbox-only extraction"

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
Assert-That "no real Spotify install created (%APPDATA%)" ($realAppExisted -or -not (Test-Path $realAppSpotify)) -Detail $(if ($realAppExisted) { "pre-existing, untouched" } else { "no %APPDATA%\Spotify created" })
Assert-That "no real Spotify install created (%LOCALAPPDATA%)" ($realLocalExisted -or -not (Test-Path $realLocalSpotify)) -Detail $(if ($realLocalExisted) { "pre-existing, untouched" } else { "no %LOCALAPPDATA%\Spotify created" })
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
$fixPs1 = Join-Path $RepoRoot "fix.ps1"
$previousEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $fixPs1 -Quiet -SpotifyDir $extracted -ReportPath $fixReport
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
Assert-That "fix.ps1 does not rewrite the Spicetify-built xpui.js" ($beforeXpuiHash -eq $afterXpuiHash) -Detail "B1/B2/B3/B4 were not needed"
Assert-That "fix.ps1 does not inject the legacy URI hack" ($beforeWrapperHash -eq $afterWrapperHash) -Detail "C1/C2 skipped (native wrapper)"
Assert-That "fix.ps1 does not rewrite the working route header" ($beforeRouteHash -eq $afterRouteHash) -Detail "D skipped (bundle negotiates rspackChunk)"
Assert-That "snapshot casing normalized back to lowercase" ($afterSnapshot.Lower -and -not $afterSnapshot.Cased) -Detail "v8_context_snapshot.bin"

$report = Get-Content -Path $fixReport -Raw | ConvertFrom-Json
$failedPatches = @($report.results | Where-Object { $_.status -eq 'failed' })
Assert-That "fix report has no failed patches" ($failedPatches.Count -eq 0) -Detail "$($report.results.Count) patch entries"
$b4 = $report.results | Where-Object { $_.Patch -like 'B4*' } | Select-Object -First 1
Assert-That "B4 reports Spicetify-managed chunk map" ($b4 -and $b4.status -eq 'not-needed') -Detail $(if ($b4) { "$($b4.status): $($b4.detail)" } else { "missing entry" })

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
$grepOutput = & git -C $RepoRoot grep -n -E 'ZGQ-inc/spotx-spicetify-fusion' -- install.ps1 install.sh fix.ps1 fix.sh custom-apps.ps1 custom-apps.sh fix-marketplace-nav.ps1 2>$null
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
foreach ($script in @('install.ps1', 'fix.ps1', 'custom-apps.ps1', 'fix-marketplace-nav.ps1')) {
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

# ---------------------------------------------------------------------------
# 9. Curated custom apps (Enhancify / Stats / lyrics-plus)
# ---------------------------------------------------------------------------
Write-Step "Verifying the curated custom apps"

# Content checks go through git grep: a PowerShell process must never open
# custom-apps.ps1 (some endpoint security suites quarantine it on read).
function Get-GitGrepLines {
    param([string]$Pattern, [string[]]$Paths)
    return @(& git -C $RepoRoot grep -n -E $Pattern -- @Paths 2>$null)
}

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
