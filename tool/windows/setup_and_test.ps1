# OBD Doctor - Windows setup + test
# Installs what is missing (Git, Flutter SDK), prepares the project, runs analyze + tests,
# and writes everything to setup_log.txt in the project folder.
# Safe to run again: it skips steps that are already done.

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$log = Join-Path $root 'setup_log.txt'
# Flutter/Android tools break on paths with spaces (e.g. C:\Users\Magic Master Remap),
# so the SDK, pub cache and a working copy of the project live under C:\ instead.
$sdkDir = 'C:\flutter'
$pubCache = 'C:\pub-cache'
$workDir = 'C:\dev\obd_doctor'
Set-Content -Path $log -Value "OBD Doctor setup log - $(Get-Date -Format s)" -Encoding UTF8
$summary = [ordered]@{}

function Log([string]$msg) {
    Write-Host $msg -ForegroundColor Cyan
    Add-Content -Path $log -Value $msg -Encoding UTF8
}

function Refresh-Path {
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$m;$u"
}

function Run-Tool([string]$title, [string]$exe, [string[]]$a) {
    Log ""
    Log "=== $title"
    Log "> $exe $($a -join ' ')"
    $out = & $exe @a 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $out | Out-Host
    if ($out) { Add-Content -Path $log -Value $out -Encoding UTF8 }
    Log "(exit code $code)"
    return [pscustomobject]@{ Code = $code; Text = ($out -join "`n") }
}

Log "Project (downloaded): $root"
Log "Windows: $([Environment]::OSVersion.VersionString)"

# ---------- 1. Git ----------
Refresh-Path
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Log "Git not found - installing with winget..."
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements --silent 2>&1 |
            ForEach-Object { "$_" } | Tee-Object -Variable w | Out-Host
        Add-Content -Path $log -Value $w -Encoding UTF8
        Refresh-Path
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            $gitDefault = 'C:\Program Files\Git\cmd'
            if (Test-Path $gitDefault) { $env:Path = "$gitDefault;$env:Path" }
        }
    } else {
        Log "winget is not available. Install Git from https://git-scm.com/download/win then run this again."
    }
}
if (Get-Command git -ErrorAction SilentlyContinue) {
    Log "Git: $(git --version)"
    $summary['Git'] = 'OK'
} else {
    $summary['Git'] = 'MISSING'
    Log "STOP: Flutter needs Git."
}

# ---------- 2. Flutter SDK ----------
$oldHome = Join-Path $env:USERPROFILE 'flutter'
$flutter = $null
if (-not (Test-Path (Join-Path $sdkDir 'bin\flutter.bat')) -and (Test-Path (Join-Path $oldHome 'bin\flutter.bat'))) {
    Log "Moving Flutter from $oldHome to $sdkDir (no spaces in path)..."
    Move-Item $oldHome $sdkDir
}
# Flutter that the user downloaded and extracted by hand (e.g. in Downloads): move it to C:\flutter
if (-not (Test-Path (Join-Path $sdkDir 'bin\flutter.bat'))) {
    $dl = Join-Path $env:USERPROFILE 'Downloads'
    $manual = @(
        Get-ChildItem -Path $dl -Directory -Filter 'flutter*' -ErrorAction SilentlyContinue | ForEach-Object {
            if (Test-Path (Join-Path $_.FullName 'bin\flutter.bat')) { $_.FullName }
            elseif (Test-Path (Join-Path $_.FullName 'flutter\bin\flutter.bat')) { Join-Path $_.FullName 'flutter' }
        }
    ) | Select-Object -First 1
    if ($manual) {
        Log "Found extracted Flutter at $manual - moving it to $sdkDir ..."
        try {
            Move-Item -Path $manual -Destination $sdkDir -ErrorAction Stop
        } catch {
            Log "Move failed ($_) - copying instead (a few minutes)..."
            robocopy $manual $sdkDir /E /NFL /NDL /NJH /NJS /NP | Out-Null
        }
    }
}
$found = Get-Command flutter -ErrorAction SilentlyContinue
if (Test-Path (Join-Path $sdkDir 'bin\flutter.bat')) {
    $flutter = Join-Path $sdkDir 'bin\flutter.bat'
} elseif ($found -and ($found.Source -notmatch ' ')) {
    $flutter = $found.Source
} elseif ($summary['Git'] -eq 'OK') {
    Log "Flutter not found - downloading the current stable release to $sdkDir (about 1 GB, may take a while)..."
    try {
        $base = 'https://storage.googleapis.com/flutter_infra_release/releases'
        $rel = Invoke-RestMethod "$base/releases_windows.json"
        $hash = $rel.current_release.stable
        $item = $rel.releases | Where-Object { $_.hash -eq $hash } | Select-Object -First 1
        $zipName = Split-Path $item.archive -Leaf
        Log "Flutter $($item.version) - $zipName"

        # Files cannot be created directly in C:\ without admin rights, so use a folder.
        $dlDir = 'C:\flutter-download'
        New-Item -ItemType Directory -Force -Path $dlDir | Out-Null
        $zip = Join-Path $dlDir $zipName

        # Reuse a partial download from an earlier run, or a copy the user downloaded by browser.
        $candidates = @(
            (Join-Path $env:TEMP 'flutter_sdk.zip'),
            (Join-Path (Join-Path $env:USERPROFILE 'Downloads') $zipName)
        )
        foreach ($c in $candidates) {
            if (-not (Test-Path $zip) -and (Test-Path $c)) {
                Log "Reusing earlier download: $c"
                Move-Item $c $zip
            }
        }

        $ok = $false
        for ($try = 1; $try -le 20 -and -not $ok; $try++) {
            if ((Test-Path $zip) -and $item.sha256) {
                Log "Checking file integrity..."
                if ((Get-FileHash $zip -Algorithm SHA256).Hash -eq $item.sha256.ToUpper()) { $ok = $true; break }
            }
            Log "Download attempt $try (continues where it stopped)..."
            curl.exe -L --fail --retry 5 --retry-delay 5 --speed-limit 1000 --speed-time 60 -C - -o $zip "$base/$($item.archive)"
            $code = $LASTEXITCODE
            if ($code -eq 0 -and -not $item.sha256) { $ok = $true }
            if ($code -eq 33 -or $code -eq 22) {
                # server refused to resume or file is corrupt: start that file over
                Remove-Item $zip -ErrorAction SilentlyContinue
            }
            if (-not $ok -and $code -ne 0) { Log "curl stopped with code $code - retrying in 10 s"; Start-Sleep 10 }
        }
        if (-not $ok) { throw "download did not complete after 20 attempts (partial file kept at $zip, run again to continue)" }

        Log "Extracting to C:\flutter (5-10 minutes, the window may look idle)..."
        tar.exe -xf $zip -C 'C:\'
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $sdkDir 'bin\flutter.bat'))) {
            Log "tar failed (code $LASTEXITCODE), trying Expand-Archive..."
            Expand-Archive -Path $zip -DestinationPath 'C:\' -Force
        }
        if (Test-Path (Join-Path $sdkDir 'bin\flutter.bat')) {
            Remove-Item $dlDir -Recurse -Force -ErrorAction SilentlyContinue
            $flutter = Join-Path $sdkDir 'bin\flutter.bat'
        } else {
            throw "extraction did not produce $sdkDir\bin\flutter.bat"
        }
    } catch {
        Log "Flutter install failed: $_"
    }
}

if ($flutter -and (Test-Path $flutter)) {
    $bin = Split-Path $flutter
    $env:Path = "$bin;$env:Path"
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($null -eq $userPath) { $userPath = '' }
    $oldBin = Join-Path $oldHome 'bin'
    $parts = @($userPath -split ';' | Where-Object { $_ -and $_ -ne $oldBin })
    if (-not ($parts | Where-Object { $_ -eq $bin })) {
        $parts += $bin
        Log "Added $bin to your user PATH (open a new terminal to use 'flutter')."
    }
    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
    # pub cache outside the user profile (its path has spaces)
    New-Item -ItemType Directory -Force -Path $pubCache | Out-Null
    $env:PUB_CACHE = $pubCache
    [Environment]::SetEnvironmentVariable('PUB_CACHE', $pubCache, 'User')
    $summary['Flutter SDK'] = 'OK'
} else {
    $summary['Flutter SDK'] = 'MISSING'
}

# ---------- 3. Project ----------
if ($summary['Flutter SDK'] -eq 'OK') {
    if ($root -match ' ') {
        Log ""
        Log "Project path has spaces - copying the project to $workDir and working there."
        New-Item -ItemType Directory -Force -Path $workDir | Out-Null
        robocopy $root $workDir /E /XD build .dart_tool (Join-Path $root 'obd_doctor') /XF setup_log.txt /NFL /NDL /NJH /NJS /NP | Out-Null
        $root = $workDir
        Log "Project folder to use from now on: $root"
    }
    Push-Location $root
    $null = Run-Tool 'Disable analytics' $flutter @('--disable-analytics')
    $null = Run-Tool 'Flutter version' $flutter @('--version')

    if (-not (Test-Path (Join-Path $root 'android'))) {
        $r = Run-Tool 'Create Android/iOS platform folders' $flutter @('create', '--platforms=android,ios', '--org', 'com.obddoctor', '--project-name', 'obd_doctor', '.')
        # flutter create adds a counter-app test that does not match this app
        Remove-Item (Join-Path $root 'test\widget_test.dart') -ErrorAction SilentlyContinue
        $summary['flutter create'] = $(if ($r.Code -eq 0) { 'OK' } else { 'FAIL' })
    }

    $r = Run-Tool 'Dependencies' $flutter @('pub', 'get')
    if ($r.Text -match 'symlink support') {
        Log "Windows needs Developer Mode for Flutter plugins. Opening the setting - turn it ON, then run this again."
        Start-Process 'ms-settings:developers'
    }
    $summary['pub get'] = $(if ($r.Code -eq 0) { 'OK' } else { 'FAIL' })

    $dart = Join-Path (Split-Path $flutter) 'dart.bat'
    $r = Run-Tool 'Android/iOS permissions' $dart @('run', 'tool/setup_platforms.dart')
    $summary['permissions'] = $(if ($r.Code -eq 0) { 'OK' } else { 'FAIL' })

    $r = Run-Tool 'Analyze' $flutter @('analyze', '--no-fatal-infos')
    $summary['analyze'] = $(if ($r.Code -eq 0) { 'OK' } else { 'FAIL' })

    $r = Run-Tool 'Tests' $flutter @('test', '--reporter', 'expanded')
    $summary['tests'] = $(if ($r.Code -eq 0) { 'OK' } else { 'FAIL' })

    $null = Run-Tool 'Doctor (what is still needed to run on a phone)' $flutter @('doctor', '-v')
    Pop-Location
}

Log ""
Log "================ SUMMARY ================"
foreach ($k in $summary.Keys) { Log ("{0,-16} {1}" -f $k, $summary[$k]) }
Log "Log file: $log"
Log "Send setup_log.txt back to Claude if anything says FAIL or MISSING."
