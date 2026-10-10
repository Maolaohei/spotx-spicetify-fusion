# SpotX + Spicetify Fusion - Curated Custom Apps & Extensions Installer
# Project: https://github.com/Maolaohei/spotx-spicetify-fusion
# Upstream: https://github.com/ZGQ-inc/spotx-spicetify-fusion (MIT)
#
# Notes on the curated set:
#   - Enhancify  : latest upstream release (flat zip -> CustomApps\Enhancify)
#   - Stats      : latest upstream release; the legacy resize-observer patch is
#                  applied only when the bundle still contains the old anchor
#   - lyrics-plus: ships inside the Spicetify CLI, so it updates with the CLI
# The Rspack compatibility patching is delegated to the project's fix.ps1
# instead of being duplicated here (fix.ps1 probes each patch and reports).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ProgressPreference = 'SilentlyContinue'

$FusionRepoUrl = 'https://github.com/Maolaohei/spotx-spicetify-fusion'
$FusionRepoRaw = 'https://raw.githubusercontent.com/Maolaohei/spotx-spicetify-fusion/main'

Write-Host " SpotX + Spicetify Fusion - Custom Apps & Extensions Installer" -ForegroundColor Cyan
Write-Host " Curated: Enhancify, Stats (on-demand patch), lyrics-plus & Popular Extensions" -ForegroundColor Cyan
Write-Host " Project: $FusionRepoUrl" -ForegroundColor Cyan

$spicetifyBin = "$env:LOCALAPPDATA\spicetify"
if ((Test-Path $spicetifyBin) -and ($env:PATH -notmatch [regex]::Escape($spicetifyBin))) {
    $env:PATH = "$spicetifyBin;$env:PATH"
}
$SpotifyDir = Join-Path $env:APPDATA "Spotify"
if (-not (Test-Path $SpotifyDir)) {
    $SpotifyDir = Join-Path $env:LOCALAPPDATA "Spotify"
}
$SpotifyExe = Join-Path $SpotifyDir "Spotify.exe"
$customAppsDir = "$env:APPDATA\spicetify\CustomApps"
if (-not (Test-Path $customAppsDir)) {
    New-Item -ItemType Directory -Path $customAppsDir -Force | Out-Null
}

function Install-Enhancify {
    Write-Host "Installing Enhancify..." -ForegroundColor Yellow
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/ECE49595-Team-6/EnhancifyInstall/releases/latest"
        # Pick the .zip asset explicitly; the release also ships install.ps1.
        $asset = $release.assets | Where-Object { $_.browser_download_url -match '\.zip$' } | Select-Object -First 1
        if (-not $asset) {
            Write-Warning "Enhancify: no .zip asset in release $($release.tag_name)"
            return
        }
        $tempZipPath = "$env:TEMP\Enhancify.zip"
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tempZipPath -UseBasicParsing
        New-Item -ItemType Directory -Path "$customAppsDir\Enhancify" -Force | Out-Null
        Expand-Archive -Path $tempZipPath -DestinationPath "$customAppsDir\Enhancify" -Force
        Remove-Item -Path $tempZipPath -Force -ErrorAction SilentlyContinue
        Write-Host "  [+] Enhancify $($release.tag_name) installed successfully." -ForegroundColor Green
    }
    catch {
        Write-Warning "Enhancify download failed: $_"
    }
}

function Install-Stats {
    Write-Host "Installing Stats..." -ForegroundColor Yellow
    try {
        $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/harbassan/spicetify-apps/releases" -UseBasicParsing
        $match = $null
        foreach ($release in @($releases)) {
            $asset = $release.assets | Where-Object { $_.browser_download_url -match 'stats.*\.zip$' } | Select-Object -First 1
            if ($asset) {
                $match = [PSCustomObject]@{ Release = $release; Asset = $asset }
                break
            }
        }
        if (-not $match) {
            Write-Warning "Stats: no stats*.zip asset found in the recent releases"
            return
        }
        $tempZipPath = "$env:TEMP\spicetify-stats.zip"
        Invoke-WebRequest -Uri $match.Asset.browser_download_url -OutFile $tempZipPath -UseBasicParsing
        Expand-Archive -Path $tempZipPath -DestinationPath $customAppsDir -Force
        Remove-Item -Path $tempZipPath -Force -ErrorAction SilentlyContinue
        Write-Host "  [+] Stats $($match.Release.tag_name) installed successfully." -ForegroundColor Green

        # Legacy layout patch: newer Stats resolves its own resize host, so this
        # is only applied while the old anchor is still present in the bundle.
        $statsIndex = Join-Path $customAppsDir "stats\index.js"
        if (Test-Path $statsIndex) {
            $anchor = '.Root__main-view .os-resize-observer-host'
            $original = 'document.querySelector(".Root__main-view .os-resize-observer-host") ?? document.querySelector(".Root__main-view .os-size-observer")'
            $replacement = $original + ' ?? document.querySelector(".Root__main-view")'
            $content = [System.IO.File]::ReadAllText($statsIndex, [System.Text.Encoding]::UTF8)
            if (-not $content.Contains($anchor)) {
                Write-Host "  [=] Stats layout patch not needed (this build uses a different resize strategy)." -ForegroundColor DarkGray
            }
            elseif ($content.Contains($replacement)) {
                Write-Host "  [=] Stats layout patch already applied." -ForegroundColor DarkGray
            }
            elseif ($content.Contains($original)) {
                [System.IO.File]::WriteAllText($statsIndex, $content.Replace($original, $replacement), (New-Object System.Text.UTF8Encoding($false)))
                Write-Host "  [+] Stats resize observer patched for the modern Spotify UI." -ForegroundColor Green
            }
            else {
                Write-Warning "Stats layout anchor found but its shape changed - patch skipped (nothing written)."
            }
        }
    }
    catch {
        Write-Warning "Stats download failed: $_"
    }
}

function Invoke-FusionHotfix {
    Write-Host "Applying the project's compatibility hotfix..." -ForegroundColor Yellow
    $fixUrl = "$FusionRepoRaw/fix.ps1"
    $fixPath = Join-Path $env:TEMP "spotx-spicetify-fusion-fix.ps1"
    $reportPath = Join-Path $env:TEMP "spotx-spicetify-fusion-fix-report.json"
    try {
        Invoke-WebRequest -Uri $fixUrl -OutFile $fixPath -UseBasicParsing
        & $fixPath -SpotifyDir $SpotifyDir -ReportPath $reportPath
    }
    catch {
        Write-Warning "Could not fetch or run the compatibility hotfix: $_"
        Write-Warning "Run it manually: iwr -useb $fixUrl | iex"
    }
}

Install-Enhancify
Install-Stats

Write-Host "Configuring Spicetify custom apps and extensions..." -ForegroundColor Yellow
spicetify config custom_apps Enhancify stats lyrics-plus
spicetify config extensions bookmark.js fullAppDisplay.js keyboardShortcut.js loopyLoop.js popupLyrics.js shuffle+.js trashbin.js webnowplaying.js
spicetify config sidebar_config 0
spicetify apply

Invoke-FusionHotfix

Get-Process -Name "Spotify" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
if (Test-Path $SpotifyExe) {
    Start-Process -FilePath $SpotifyExe
}

Write-Host " Custom apps and extensions installed and patched successfully!" -ForegroundColor Green
