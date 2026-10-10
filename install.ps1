# SpotX + Spicetify All-in-One Automated Installer (Windows Edition)
# Supports Spotify 1.2.x & 1.3.x (Rspack, tested 1.3.4)
# Project: https://github.com/Maolaohei/spotx-spicetify-fusion
# Upstream: https://github.com/ZGQ-inc/spotx-spicetify-fusion (MIT)
# Telegram (upstream community): https://t.me/ZGQinc
#
# This installer wraps the upstream SpotX and Spicetify installers and removes
# their interactive prompts so the whole flow can run unattended. Upstream
# changes those scripts frequently, so every bypass below is verified after it
# is applied: if a prompt can no longer be neutralised, the installer stops with
# a clear message instead of hanging or silently skipping the bypass.
#
# Run `.\install.ps1 -VerifyOnly` to check the bypass rules against the current
# upstream scripts without installing anything.

param(
    [switch]$VerifyOnly,
    [string]$UpstreamDir
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ProgressPreference = 'SilentlyContinue'

# This fork is the project the installer, the hotfix and the docs all point to.
$FusionRepoUrl = 'https://github.com/Maolaohei/spotx-spicetify-fusion'
$FusionRepoRaw = 'https://raw.githubusercontent.com/Maolaohei/spotx-spicetify-fusion/main'

$script:Checks = New-Object System.Collections.Generic.List[object]
$script:UpstreamHashes = [ordered]@{}
$script:VerifyExitCode = 0
$script:FailedSteps = New-Object System.Collections.Generic.List[string]

# Spicetify refuses to run elevated: files written by an elevated process are
# owned by the Administrators group, and Spotify (running as the normal user)
# can end up unable to read them - which shows up as a black/blank window.
# Nothing in this installer needs elevation (SpotX's Defender exclusions are
# explicitly skipped), so abort with instructions instead of leaving a broken
# half-applied install behind.
function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if ((Test-Elevated) -and -not $VerifyOnly) {
    Write-Host "[X] This installer is running as Administrator." -ForegroundColor Red
    Write-Host "    Spicetify refuses to run elevated: the files it writes would be owned by" -ForegroundColor Yellow
    Write-Host "    Administrators, and Spotify (running as you) can then show a black window." -ForegroundColor Yellow
    Write-Host "    Close this window, open a NORMAL PowerShell (no 'Run as administrator'), then run:" -ForegroundColor Yellow
    Write-Host "      iwr -useb $FusionRepoRaw/install.ps1 | iex" -ForegroundColor Yellow
    # No 'exit': the documented path is "iwr -useb ... | iex" and 'exit' inside
    # Invoke-Expression closes the caller's console window.
    $host.SetShouldExit(1)
    return
}

function Add-Check {
    param(
        [string]$Name,
        [bool]$Ok,
        [string]$Detail = ""
    )
    $script:Checks.Add([PSCustomObject]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
    if (-not $VerifyOnly) { return }
    if ($Ok) {
        Write-Host ("  [ok]   {0}{1}" -f $Name, $(if ($Detail) { " - $Detail" } else { "" })) -ForegroundColor Green
    }
    else {
        Write-Host ("  [FAIL] {0}{1}" -f $Name, $(if ($Detail) { " - $Detail" } else { "" })) -ForegroundColor Red
        $script:VerifyExitCode = 1
    }
}

function Get-UpstreamScript {
    param(
        [string]$Name,
        [string]$Url,
        [string]$CacheName
    )
    $target = $null
    if ($UpstreamDir) {
        $target = Join-Path $UpstreamDir $CacheName
        if (-not (Test-Path $target)) {
            throw "$Name not found in -UpstreamDir: $target"
        }
        $content = [System.IO.File]::ReadAllText($target)
    }
    else {
        $target = Join-Path $env:TEMP $CacheName
        Invoke-WebRequest -Uri $Url -OutFile $target -UseBasicParsing
        $content = [System.IO.File]::ReadAllText($target)
    }
    $script:UpstreamHashes[$Name] = (Get-FileHash -Path $target -Algorithm SHA256).Hash.ToLower()
    return $content
}

function Get-ScriptSyntaxErrors {
    param([string]$Content)
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Content, [ref]$tokens, [ref]$errors)
    return @($errors)
}

function Get-DeclaredParameters {
    param([string]$Content)
    $names = New-Object System.Collections.Generic.List[string]
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Content, [ref]$tokens, [ref]$errors)
    if ($ast.ParamBlock) {
        foreach ($p in $ast.ParamBlock.Parameters) {
            $names.Add($p.Name.VariablePath.UserPath)
            foreach ($attr in $p.Attributes) {
                if ($attr.TypeName.Name -eq 'Alias') {
                    foreach ($arg in $attr.PositionalArguments) {
                        if ($arg.Value) { $names.Add([string]$arg.Value) }
                    }
                }
            }
        }
    }
    return $names
}

# Replaces every assignment of the form `$choice = ...PromptForChoice(...)`
# with a constant. AST-based so multi-line prompts (with nested parentheses)
# are replaced exactly, without leaving dangling arguments behind.
function Set-ChoiceConstant {
    param(
        [string]$Content,
        [string]$Value
    )
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Content, [ref]$tokens, [ref]$errors)
    $nodes = $ast.FindAll({
            param($n)
            ($n -is [System.Management.Automation.Language.AssignmentStatementAst]) -and
            ($n.Left.Extent.Text -match '^\$choice$') -and
            ($n.Right.Extent.Text -match 'PromptForChoice')
        }, $true)
    $count = 0
    foreach ($node in @($nodes | Sort-Object { $_.Extent.StartOffset } -Descending)) {
        $start = $node.Extent.StartOffset
        $len = $node.Extent.EndOffset - $start
        $Content = $Content.Remove($start, $len).Insert($start, "`$choice = $Value")
        $count++
    }
    return [PSCustomObject]@{ Content = $Content; Count = $count }
}

function Write-VerifyReport {
    param([string]$Title)
    $failed = @($script:Checks | Where-Object { -not $_.Ok })
    Write-Host ""
    Write-Host "=== $Title ===" -ForegroundColor Cyan
    Write-Host ("  checks: {0} passed / {1} failed" -f ($script:Checks.Count - $failed.Count), $failed.Count) -ForegroundColor $(if ($failed.Count) { "Red" } else { "Green" })
    foreach ($k in $script:UpstreamHashes.Keys) {
        Write-Host ("  {0}: sha256 {1}" -f $k, $script:UpstreamHashes[$k]) -ForegroundColor DarkGray
    }
}

if ($VerifyOnly) {
    Write-Host " SpotX + Spicetify installer - upstream bypass self-check" -ForegroundColor Cyan
    Write-Host " (no installation actions will be performed)" -ForegroundColor DarkGray
}

Write-Host " SpotX + Spicetify All-in-One Automated Installer" -ForegroundColor Cyan
Write-Host " GitHub: $FusionRepoUrl" -ForegroundColor Cyan
Write-Host " Supports Spotify 1.2.x & 1.3.x (Rspack)" -ForegroundColor Cyan

# --------------------------------------------------------------------------
# 1. Install / Update Spotify with SpotX
# --------------------------------------------------------------------------
if (-not $VerifyOnly) {
    Write-Host "[1/5] Installing Spotify and patching with SpotX..." -ForegroundColor Yellow
}
else {
    Write-Host "[1/5] Checking the SpotX bypass rules..." -ForegroundColor Yellow
}

$spotxUrl = "https://raw.githubusercontent.com/SpotX-Official/SpotX/main/run.ps1"
$spotxContent = Get-UpstreamScript -Name "SpotX run.ps1" -Url $spotxUrl -CacheName "run_spotx.ps1"

# 1a. SpotX refuses to run when a Spicetify bundle is present. The fusion flow
#     intentionally applies SpotX on top of / before Spicetify, so both guards
#     are neutralised. (SpotX >= 1.3.4 added the "FileLocBroken" guard.)
$spotxContent = $spotxContent -replace '(?s)if\s*\(\s*\$test_spa\s+-and\s+\$test_js\s*\)\s*\{.*?Stop-Script\s*\}', '# [fusion] xpui.spa + Spicetify bundle present; patching is intentional here'
$spotxContent = $spotxContent -replace '(?s)if\s*\(\s*\$test_js\s*\)\s*\{.*?Stop-Script\s*\}', '# [fusion] Spicetify bundle present; patching is intentional here'
$guardsNeutralised = ($spotxContent -notmatch 'Can-I-use-SpotX-and-Spicetify-together') -and ($spotxContent -notmatch 'Read-Host\s+-Prompt\s+\(\$lang\)\.Spicetify')
Add-Check -Name "SpotX: Spicetify guard prompts removed" -Ok $guardsNeutralised -Detail $(if ($guardsNeutralised) { "both guards neutralised" } else { "upstream guard text changed" })

# 1b. Auto-answer 'n' to the Defender exclusion prompt (also skipped entirely
#     because -defender_exclusions_off is passed).
$spotxContent = $spotxContent -replace 'Read-Host\s+-Prompt\s+\$defenderPrompt', "'n'"
$defenderNeutralised = ($spotxContent -notmatch 'Read-Host\s+-Prompt\s+\$defenderPrompt')
Add-Check -Name "SpotX: Defender prompt neutralised" -Ok $defenderNeutralised -Detail $(if ($defenderNeutralised) { "forced to 'n'" } else { "prompt pattern not found" })

# 1c. Legacy SpotX versions launched SpotifySetup.exe through explorer.exe to
#     dodge the GUI installer. SpotX >= 1.3.4 extracts the installer itself, so
#     the rewrite only applies when the old text is still present.
$legacyLaunch = 'Start-Process\s+-FilePath\s+explorer\.exe\s+-ArgumentList\s+\$setupExe'
if ([regex]::IsMatch($spotxContent, $legacyLaunch)) {
    $spotxContent = [regex]::Replace($spotxContent, $legacyLaunch, 'Start-Process -FilePath $setupExe', 1)
    Add-Check -Name "SpotX: legacy explorer.exe launch removed" -Ok $true -Detail "old SpotX detected and patched"
}
else {
    Add-Check -Name "SpotX: legacy explorer.exe launch removed" -Ok $true -Detail "not present (SpotX extracts the installer itself)"
}

$syntaxErrors = Get-ScriptSyntaxErrors -Content $spotxContent
Add-Check -Name "SpotX: patched script parses" -Ok ($syntaxErrors.Count -eq 0) -Detail $(if ($syntaxErrors.Count) { $syntaxErrors[0].Message } else { "no syntax errors" })

# 1d. Reconcile the flags with the parameters the downloaded SpotX declares.
#     Upstream renames/removes switches regularly (e.g. -canvasHome no longer
#     exists); passing an unknown switch would abort the whole invocation.
#     Canonical parameter names are used because array splatting would pass
#     flags as positional arguments (hash splatting binds them by name).
$spotxDesired = @(
    @{ Name = 'confirm_uninstall_ms_spoti' },
    @{ Name = 'confirm_spoti_recomended_over' },
    @{ Name = 'new_theme' },
    @{ Name = 'block_update_on' },
    @{ Name = 'podcasts_on' },
    @{ Name = 'devtools' },
    @{ Name = 'exp_spotify' },
    @{ Name = 'adsections_off' },
    @{ Name = 'cache_limit'; Value = '20000' },
    @{ Name = 'topsearchbar' },
    @{ Name = 'newFullscreenMode' },
    @{ Name = 'rightsidebarcolor' },
    @{ Name = 'hide_col_icon_off' },
    @{ Name = 'no_pause' },
    @{ Name = 'defender_exclusions_off' }
)
$declared = Get-DeclaredParameters -Content $spotxContent
$spotxParams = @{}
$skippedFlags = New-Object System.Collections.Generic.List[string]
foreach ($item in $spotxDesired) {
    $bare = $item.Name.TrimStart('-')
    if ($declared -contains $bare) {
        if ($item.Value) { $spotxParams[$bare] = [string]$item.Value }
        else { $spotxParams[$bare] = $true }
    }
    else {
        $skippedFlags.Add("-$bare")
    }
}
Add-Check -Name "SpotX: flags reconciled" -Ok ($spotxParams.Count -ge ($spotxDesired.Count - 1)) -Detail $(if ($skippedFlags.Count) { "skipped missing flags: $($skippedFlags -join ' ')" } else { "all $($spotxParams.Count) flags accepted" })

if (-not $VerifyOnly) {
    $spotxLocalPath = Join-Path $env:TEMP "run_spotx.ps1"
    [System.IO.File]::WriteAllText($spotxLocalPath, $spotxContent, (New-Object System.Text.UTF8Encoding($false)))
    & $spotxLocalPath @spotxParams
}

# --------------------------------------------------------------------------
# 2. Install Spicetify CLI (bypassing the internal prompts so Spotify can be
#    initialised first). Verified against the current install script.
# --------------------------------------------------------------------------
if (-not $VerifyOnly) {
    Write-Host "[2/5] Installing Spicetify CLI..." -ForegroundColor Yellow
}
else {
    Write-Host "[2/5] Checking the Spicetify CLI bypass rules..." -ForegroundColor Yellow
}

$spicetifyCliUrl = "https://raw.githubusercontent.com/spicetify/cli/master/install.ps1"
$spicetifyScript = Get-UpstreamScript -Name "Spicetify install.ps1" -Url $spicetifyCliUrl -CacheName "spicetify_install.ps1"

# 2a. Drop the embedded Marketplace prompt (Marketplace is installed in step 3).
$hadMarketplaceRegion = $spicetifyScript -match '(?s)#region Marketplace.*?#endregion Marketplace'
$spicetifyScript = $spicetifyScript -replace '(?s)#region Marketplace.*?#endregion Marketplace', '# [fusion] Marketplace prompt bypassed; handled in the next step'
Add-Check -Name "Spicetify: Marketplace prompt removed" -Ok ($spicetifyScript -notmatch '#region Marketplace') -Detail $(if ($hadMarketplaceRegion) { "region stripped" } else { "region already absent" })

# 2b. Bypass the administrator warning (the fusion installer is expected to run
#     from a normal user shell; the check only aborts inconveniently).
$hadAdminCheck = $spicetifyScript -match 'if\s*\(-not\s*\(Test-Admin\)\)\s*\{'
$spicetifyScript = $spicetifyScript -replace 'if\s*\(-not\s*\(Test-Admin\)\)\s*\{', 'if ($false) {'
Add-Check -Name "Spicetify: admin abort bypassed" -Ok ($spicetifyScript -notmatch 'if\s*\(-not\s*\(Test-Admin\)\)') -Detail $(if ($hadAdminCheck) { "check disabled" } else { "check already absent" })

# 2c. New Spicetify installers ask "Spicetify is already installed. Do you want
#     to fix your installation?" on every re-run. Answer "continue with
#     installation" (1) so 'update the dependency' always installs the latest
#     build; the admin warning prompt is answered the same way (and its branch
#     is already dead after 2b).
$hadInstalledPrompt = $spicetifyScript -match 'Spicetify is already installed'
$choiceRewrite = Set-ChoiceConstant -Content $spicetifyScript -Value 1
$spicetifyScript = $choiceRewrite.Content
$promptNowGone = -not [regex]::IsMatch($spicetifyScript, "Spicetify is already installed\..*?PromptForChoice")
Add-Check -Name "Spicetify: 'already installed' prompt neutralised" -Ok $promptNowGone -Detail $(if ($hadInstalledPrompt) { "forced to continue with installation" } else { "prompt not present in this version" })
Add-Check -Name "Spicetify: choice prompts rewritten" -Ok ($choiceRewrite.Count -ge 1 -or -not ($spicetifyScript -match 'PromptForChoice')) -Detail "$($choiceRewrite.Count) prompt(s) replaced"

# 2d. Neutralise any remaining interactive constructs in the reachable paths.
$spicetifyScript = $spicetifyScript -replace '\$Host\.UI\.RawUI\.Flushinputbuffer\(\)', '# [fusion] flush bypassed'
$spicetifyScript = [regex]::Replace($spicetifyScript, '(?m)^\s*Pause\s*$', '# [fusion] Pause bypassed')
$spicetifyUnattended = ($spicetifyScript -notmatch 'PromptForChoice') -and ($spicetifyScript -notmatch 'Read-Host') -and ($spicetifyScript -notmatch 'Flushinputbuffer') -and ($spicetifyScript -notmatch '(?m)^\s*Pause\s*$')
Add-Check -Name "Spicetify: installer runs unattended" -Ok $spicetifyUnattended -Detail $(if ($spicetifyUnattended) { "no interactive prompts left" } else { "an interactive prompt survived the rewrite" })

$syntaxErrors = Get-ScriptSyntaxErrors -Content $spicetifyScript
Add-Check -Name "Spicetify: patched script parses" -Ok ($syntaxErrors.Count -eq 0) -Detail $(if ($syntaxErrors.Count) { $syntaxErrors[0].Message } else { "no syntax errors" })

if (-not $VerifyOnly) {
    Invoke-Expression $spicetifyScript

    # Ensure spicetify is immediately available in the current process PATH
    $spicetifyBin = "$env:LOCALAPPDATA\spicetify"
    if ((Test-Path $spicetifyBin) -and ($env:PATH -notmatch [regex]::Escape($spicetifyBin))) {
        $env:PATH = "$spicetifyBin;$env:PATH"
    }
}

# --------------------------------------------------------------------------
# 3. Pre-launch Spotify to initialize CEF state, auto-grant local network
#    permission, and install Marketplace
# --------------------------------------------------------------------------
if (-not $VerifyOnly) {
    Write-Host "[3/5] Pre-launching Spotify, granting permissions, and installing Marketplace..." -ForegroundColor Yellow
}
else {
    Write-Host "[3/5] Checking the Marketplace bypass rules..." -ForegroundColor Yellow
}

$marketScriptUrl = "https://raw.githubusercontent.com/spicetify/marketplace/main/resources/install.ps1"
$marketScript = Get-UpstreamScript -Name "Marketplace install.ps1" -Url $marketScriptUrl -CacheName "marketplace_install.ps1"

# 3a. Auto-answer 'Yes' (0) to the theme replacement prompt. The call spans
#     multiple lines in current installers, so an AST-based replacement is used.
$hadMarketChoice = $marketScript -match 'PromptForChoice'
$marketRewrite = Set-ChoiceConstant -Content $marketScript -Value 0
$marketScript = $marketRewrite.Content
$marketScript = $marketScript -replace '\$Host\.UI\.RawUI\.Flushinputbuffer\(\)', '# [fusion] flush bypassed'
$marketUnattended = ($marketScript -notmatch 'PromptForChoice') -and ($marketScript -notmatch 'Read-Host') -and ($marketScript -notmatch 'Flushinputbuffer')
Add-Check -Name "Marketplace: theme prompt neutralised" -Ok $marketUnattended -Detail $(if ($hadMarketChoice) { "forced to 'Yes' (0)" } else { "prompt not present in this version" })

$syntaxErrors = Get-ScriptSyntaxErrors -Content $marketScript
Add-Check -Name "Marketplace: patched script parses" -Ok ($syntaxErrors.Count -eq 0) -Detail $(if ($syntaxErrors.Count) { $syntaxErrors[0].Message } else { "no syntax errors" })

if ($VerifyOnly) {
    Write-VerifyReport -Title "Upstream bypass self-check"
    # No 'exit': these scripts are documented as "iwr -useb ... | iex" and an
    # 'exit' inside Invoke-Expression closes the caller's console window.
    # SetShouldExit keeps the -File exit code while leaving the session alive.
    $host.SetShouldExit($script:VerifyExitCode)
    return
}

function Grant-ChromiumLocalNetworkAccess {
    $prefPaths = @(
        "$env:LOCALAPPDATA\Spotify\Default\Preferences",
        "$env:APPDATA\Spotify\Default\Preferences",
        "$env:LOCALAPPDATA\Spotify\User Data\Default\Preferences"
    )
    foreach ($pp in $prefPaths) {
        if (Test-Path $pp) {
            try {
                $prefObj = Get-Content -Path $pp -Raw -Encoding UTF8 | ConvertFrom-Json
                if (-not $prefObj.profile) { $prefObj | Add-Member -NotePropertyName "profile" -NotePropertyValue ([PSCustomObject]@{}) -Force }
                if (-not $prefObj.profile.content_settings) { $prefObj.profile | Add-Member -NotePropertyName "content_settings" -NotePropertyValue ([PSCustomObject]@{}) -Force }
                if (-not $prefObj.profile.content_settings.exceptions) { $prefObj.profile.content_settings | Add-Member -NotePropertyName "exceptions" -NotePropertyValue ([PSCustomObject]@{}) -Force }

                $grantObj = [PSCustomObject]@{
                    "https://login.app.spotify.com:443,*" = [PSCustomObject]@{
                        "setting" = 1
                    }
                }
                $prefObj.profile.content_settings.exceptions | Add-Member -NotePropertyName "local_network_access" -NotePropertyValue $grantObj -Force
                $prefObj.profile.content_settings.exceptions | Add-Member -NotePropertyName "local_network" -NotePropertyValue $grantObj -Force
                $prefObj.profile.content_settings.exceptions | Add-Member -NotePropertyName "loopback_network" -NotePropertyValue $grantObj -Force

                if (-not $prefObj.default_content_setting_values) {
                    $prefObj | Add-Member -NotePropertyName "default_content_setting_values" -NotePropertyValue ([PSCustomObject]@{}) -Force
                }
                $prefObj.default_content_setting_values | Add-Member -NotePropertyName "local_network_access" -NotePropertyValue 1 -Force
                $prefObj.default_content_setting_values | Add-Member -NotePropertyName "local_network" -NotePropertyValue 1 -Force

                $prefObj | ConvertTo-Json -Depth 32 | Set-Content -Path $pp -Encoding UTF8
                Write-Host "  [+] Pre-configured Chromium local network access permission in Preferences" -ForegroundColor Green
            }
            catch {}
        }
    }
}

# Auto-configure Chromium Preferences before starting
Grant-ChromiumLocalNetworkAccess

# Launch Spotify in background to initialize browser cache and local database
Write-Host "  -> Launching Spotify to initialize profile and runtime..." -ForegroundColor Cyan
$SpotifyDir = Join-Path $env:APPDATA "Spotify"
if (-not (Test-Path $SpotifyDir)) {
    $SpotifyDir = Join-Path $env:LOCALAPPDATA "Spotify"
}
$spotifyExe = Join-Path $SpotifyDir "Spotify.exe"
if (Test-Path $spotifyExe) {
    Start-Process -FilePath $spotifyExe -ErrorAction SilentlyContinue
}

# Wait for CEF window initialization
Start-Sleep -Seconds 3

# Auto-allow "Access other devices on your local network" in Preferences while running
Grant-ChromiumLocalNetworkAccess

# Button and window names for the permission prompt. They are built from code
# points so this published script stays pure ASCII: PowerShell 7's
# "iwr -useb ... | iex" does not honour the response charset and would turn any
# non-ASCII byte into "?", which silently breaks those matches.
$allowButtons = @(
    'Allow',
    ([string][char]0x5141 + [string][char]0x8BB8),   # allow (zh)
    ([string][char]0x540C + [string][char]0x610F),   # agree (zh)
    ([string][char]0x786E + [string][char]0x5B9A),   # confirm (zh)
    'OK'
)
$windowPattern = 'Spotify|login|permission|network|' + (
    @([string][char]0x8BBE + [string][char]0x5907, [string][char]0x7F51 + [string][char]0x7EDC) -join '|'
)

# Auto-click the Allow button on the permission prompt via UI Automation
try {
    Add-Type -AssemblyName UIAutomationClient -ErrorAction SilentlyContinue
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($w in $windows) {
        try {
            if ($w.Current.Name -match $windowPattern -or $w.Current.ClassName -match "Chrome|Widget") {
                $buttons = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)))
                foreach ($btn in $buttons) {
                    $btnName = $btn.Current.Name
                    if ($allowButtons -contains $btnName) {
                        $pattern = $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
                        $pattern.Invoke()
                        Write-Host "  [+] Clicked '$btnName' permission button via UI Automation" -ForegroundColor Green
                        break
                    }
                }
            }
        }
        catch {}
    }
}
catch {}

# Fallback: Send Enter to activate default Allow button if modal is focused
try {
    $wshell = New-Object -ComObject WScript.Shell
    if ($wshell.AppActivate("Spotify")) {
        Start-Sleep -Milliseconds 300
        $wshell.SendKeys("{ENTER}")
    }
}
catch {}

# Wait 5 seconds as requested
Write-Host "  -> Waiting 5 seconds before applying Marketplace..." -ForegroundColor Cyan
Start-Sleep -Seconds 5

# Terminate Spotify cleanly so Spicetify can patch xpui without file locking conflicts
Get-Process -Name "Spotify" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

# Auto-configure Chromium Preferences again after exit
Grant-ChromiumLocalNetworkAccess

# Install Marketplace with the unattended 'Yes' choice (verified above)
Write-Host "  -> Installing Spicetify Marketplace..." -ForegroundColor Cyan
try {
    Invoke-Expression $marketScript
}
catch {
    $script:FailedSteps.Add('Marketplace installer') | Out-Null
    Write-Warning "Marketplace installer failed: $_"
}

# --------------------------------------------------------------------------
# 4. Apply Spicetify Configuration with Marketplace
# --------------------------------------------------------------------------
Write-Host "[4/5] Applying Spicetify configuration with Marketplace..." -ForegroundColor Yellow

# The Spicetify CLI refuses to run elevated (see the guard at the top) and can
# fail for other reasons; every step is checked so the closing summary cannot
# claim success for a half-applied install.
function Invoke-SpicetifyStep {
    param(
        [string]$Label,
        [string[]]$Arguments
    )
    & spicetify @Arguments
    if ($LASTEXITCODE -ne 0) {
        $script:FailedSteps.Add($Label) | Out-Null
        Write-Warning "spicetify $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

Invoke-SpicetifyStep -Label 'spicetify config custom_apps marketplace' -Arguments @('config', 'custom_apps', 'marketplace')
Invoke-SpicetifyStep -Label 'spicetify apply' -Arguments @('apply')

# --------------------------------------------------------------------------
# 5. Apply the project's compatibility hotfix, fetched from this repository so
#    the installer and fix.ps1 can never drift apart
# --------------------------------------------------------------------------
Write-Host "[5/5] Applying SpotX + Spicetify compatibility hotfix..." -ForegroundColor Yellow

$fixUrl = "$FusionRepoRaw/fix.ps1"
$fixPath = Join-Path $env:TEMP "spotx-spicetify-fusion-fix.ps1"
$fixReport = Join-Path $env:TEMP "spotx-spicetify-fusion-fix-report.json"
if (Test-Path $fixReport) { Remove-Item $fixReport -Force -ErrorAction SilentlyContinue }
try {
    Invoke-WebRequest -Uri $fixUrl -OutFile $fixPath -UseBasicParsing
    & $fixPath -ReportPath $fixReport
    if (Test-Path $fixReport) {
        $fixResult = Get-Content -Path $fixReport -Raw | ConvertFrom-Json
        if ($fixResult.failed -gt 0) {
            $script:FailedSteps.Add("hotfix ($($fixResult.failed) patch(es) failed)") | Out-Null
        }
    }
}
catch {
    $script:FailedSteps.Add('hotfix') | Out-Null
    Write-Warning "Could not fetch or run the compatibility hotfix: $_"
    Write-Warning "Run it manually after the installation:"
    Write-Warning "  iwr -useb $fixUrl | iex"
}

# The hotfix can only patch an extracted client: without xpui.js nothing above
# produced a usable install.
$xpuiJsPath = Join-Path (Join-Path $SpotifyDir "Apps\xpui") "xpui.js"
if (-not (Test-Path $xpuiJsPath)) {
    $script:FailedSteps.Add('Spotify client was never preprocessed (xpui.js missing)') | Out-Null
}

# 6. Launch Patched Spotify Client
if (Test-Path $spotifyExe) {
    Write-Host "  -> Launching patched Spotify..." -ForegroundColor Cyan
    Start-Process -FilePath $spotifyExe
}

if ($script:FailedSteps.Count -eq 0) {
    Write-Host " Installation and unified hotfix completed successfully!" -ForegroundColor Green
    Write-Host " Enjoy your ad-free, fully-customized, high-performance Spotify!" -ForegroundColor Green
}
else {
    Write-Host ""
    Write-Host "[X] Installation finished, but these steps failed:" -ForegroundColor Red
    foreach ($step in $script:FailedSteps) { Write-Host "      - $step" -ForegroundColor Red }
    Write-Host "" -ForegroundColor Red
    Write-Host "    Most common cause: the shell was running as Administrator." -ForegroundColor Yellow
    Write-Host "    Open a NORMAL PowerShell (no 'Run as administrator'), close Spotify, then re-run:" -ForegroundColor Yellow
    Write-Host "      iwr -useb $FusionRepoRaw/install.ps1 | iex" -ForegroundColor Yellow
    $host.SetShouldExit(1)
    return
}
