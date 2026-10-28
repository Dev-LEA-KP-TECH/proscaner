# OBD Doctor - Android setup + APK build (Windows)
# Installs Java 21 + Android SDK (command-line, no Android Studio needed), accepts licenses,
# builds the APK, and installs it on a phone if one is connected by USB.
# Log: android_log.txt in the project folder. Safe to run again.

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$log = Join-Path $root 'android_log.txt'
Set-Content -Path $log -Value "OBD Doctor Android log - $(Get-Date -Format s)" -Encoding UTF8
$summary = [ordered]@{}

$sdk = 'C:\Android\sdk'
$gradleHome = 'C:\gradle'
$flutter = 'C:\flutter\bin\flutter.bat'

function Log([string]$msg) {
    Write-Host $msg -ForegroundColor Cyan
    Add-Content -Path $log -Value $msg -Encoding UTF8
}

function Refresh-Path {
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$m;$u"
}

function Run-Tool([string]$title, [string]$exe, [string[]]$a, $stdin = $null) {
    Log ""
    Log "=== $title"
    Log "> $exe $($a -join ' ')"
    if ($null -ne $stdin) {
        $out = $stdin | & $exe @a 2>&1 | ForEach-Object { "$_" }
    } else {
        $out = & $exe @a 2>&1 | ForEach-Object { "$_" }
    }
    $code = $LASTEXITCODE
    $out | Out-Host
    if ($out) { Add-Content -Path $log -Value $out -Encoding UTF8 }
    Log "(exit code $code)"
    return [pscustomobject]@{ Code = $code; Text = ($out -join "`n") }
}

function Set-UserEnv([string]$name, [string]$value) {
    [Environment]::SetEnvironmentVariable($name, $value, 'User')
    Set-Item -Path "Env:$name" -Value $value
}

Log "Project: $root"
if (-not (Test-Path $flutter)) {
    Log "STOP: C:\flutter not found. Run SETUP_WINDOWS.bat first."
    exit 1
}

# ---------- 0. Tidy: a duplicate project folder got copied inside the project ----------
$nested = Join-Path $root 'obd_doctor'
if (Test-Path (Join-Path $nested 'pubspec.yaml')) {
    $dest = Join-Path (Split-Path $root) '_obd_doctor_duplicate'
    Log "Moving duplicate folder $nested to $dest (not deleted - remove it yourself if you like)"
    Move-Item $nested $dest -Force
}

# ---------- 1. Java (JDK 21) ----------
function Find-Jdk {
    foreach ($d in @('C:\Program Files\Microsoft', 'C:\Program Files\Eclipse Adoptium', 'C:\Program Files\Java')) {
        if (Test-Path $d) {
            $j = Get-ChildItem $d -Directory -Filter 'jdk-21*' -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | Select-Object -First 1
            if ($j -and (Test-Path (Join-Path $j.FullName 'bin\java.exe'))) { return $j.FullName }
        }
    }
    return $null
}
$jdk = Find-Jdk
if (-not $jdk) {
    Log "Installing Microsoft OpenJDK 21 with winget..."
    winget install --id Microsoft.OpenJDK.21 -e --source winget --accept-package-agreements --accept-source-agreements --silent 2>&1 |
        ForEach-Object { "$_" } | Tee-Object -Variable w | Out-Host
    Add-Content -Path $log -Value $w -Encoding UTF8
    $jdk = Find-Jdk
}
if ($jdk) {
    Set-UserEnv 'JAVA_HOME' $jdk
    $env:Path = "$jdk\bin;$env:Path"
    Log "Java: $jdk"
    $summary['Java 21'] = 'OK'
} else {
    $summary['Java 21'] = 'MISSING'
}

# ---------- 2. Android SDK command-line tools ----------
# Since late 2026 the "latest" command-line tools are a wrapper around the new Android CLI,
# which cannot install NDK/platform packages by their usual names. Flutter's Gradle build
# also calls cmdline-tools\latest\sdkmanager to fetch the NDK, so pin the classic tools (19.0).
$toolsUrl = 'https://dl.google.com/android/repository/commandlinetools-win-13114758_latest.zip'
$toolsVersion = '19.0'
$latest = Join-Path $sdk 'cmdline-tools\latest'
$sdkmanager = Join-Path $latest 'bin\sdkmanager.bat'

function Get-ToolsVersion {
    $sp = Join-Path $latest 'source.properties'
    if (-not (Test-Path $sp)) { return $null }
    $line = Get-Content $sp | Where-Object { $_ -match '^Pkg.Revision=' } | Select-Object -First 1
    if ($line) { return ($line -split '=')[1].Trim() }
    return $null
}

if ($jdk -and ((Get-ToolsVersion) -ne $toolsVersion)) {
    Log "Installing classic Android command-line tools $toolsVersion (found: $(Get-ToolsVersion))..."
    try {
        New-Item -ItemType Directory -Force -Path $sdk | Out-Null
        $zip = Join-Path $sdk 'cmdline-tools-19.zip'
        curl.exe -L --fail --retry 5 -C - -o $zip $toolsUrl
        if ($LASTEXITCODE -ne 0) { throw "download failed (curl exit $LASTEXITCODE)" }
        $tmp = Join-Path $sdk 'cmdline-extract'
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        tar.exe -xf $zip -C $tmp
        if ($LASTEXITCODE -ne 0) { throw "extract failed (tar exit $LASTEXITCODE)" }
        if (Test-Path $latest) {
            $old = Join-Path $sdk 'cmdline-tools\android-cli-wrapper'
            Remove-Item $old -Recurse -Force -ErrorAction SilentlyContinue
            Move-Item $latest $old
        }
        New-Item -ItemType Directory -Force -Path (Join-Path $sdk 'cmdline-tools') | Out-Null
        Move-Item (Join-Path $tmp 'cmdline-tools') $latest
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $zip -ErrorAction SilentlyContinue
        Log "Command-line tools now: $(Get-ToolsVersion)"
    } catch {
        Log "Android command-line tools install failed: $_"
    }
}

# Versions this Flutter release needs (read from the Flutter SDK, with safe fallbacks)
$ndkVersion = '28.2.13676358'
$compileSdk = '36'
$fe = Get-ChildItem 'C:\flutter\packages\flutter_tools\gradle' -Recurse -Include 'FlutterExtension.kt', 'flutter.groovy' -ErrorAction SilentlyContinue
foreach ($f in $fe) {
    $txt = Get-Content $f.FullName -Raw
    if ($txt -match 'ndkVersion[^"\n]*"([0-9.]+)"') { $ndkVersion = $Matches[1] }
    if ($txt -match 'compileSdkVersion[^=\n]*=\s*(\d+)') { $compileSdk = $Matches[1] }
}
Log "Flutter needs NDK $ndkVersion, compileSdk $compileSdk"

if (Test-Path $sdkmanager) {
    Set-UserEnv 'ANDROID_HOME' $sdk
    Set-UserEnv 'ANDROID_SDK_ROOT' $sdk
    Set-UserEnv 'GRADLE_USER_HOME' $gradleHome
    New-Item -ItemType Directory -Force -Path $gradleHome | Out-Null
    $pt = Join-Path $sdk 'platform-tools'
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not ($userPath -split ';' | Where-Object { $_ -eq $pt })) {
        [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ";$pt"), 'User')
    }
    $env:Path = "$pt;$env:Path"

    $yes = @('y') * 40
    $null = Run-Tool 'Accept Android licenses' $sdkmanager @("--sdk_root=$sdk", '--licenses') $yes
    $pkgs = @('platform-tools', "platforms;android-$compileSdk", 'build-tools;36.0.0', "ndk;$ndkVersion")
    Log "Installing $($pkgs -join ', ') - the NDK is about 1 GB, the window may look idle."
    $null = Run-Tool 'Install SDK packages' $sdkmanager (@("--sdk_root=$sdk") + $pkgs) $yes

    $okPlat = Test-Path (Join-Path $sdk "platforms\android-$compileSdk")
    $okNdk = Test-Path (Join-Path $sdk "ndk\$ndkVersion")
    $okBt = Test-Path (Join-Path $sdk 'build-tools\36.0.0')
    Log "platforms;android-$compileSdk : $okPlat   ndk;$ndkVersion : $okNdk   build-tools;36.0.0 : $okBt"
    $summary['Android SDK'] = $(if ($okPlat -and $okNdk -and $okBt) { 'OK' } else { 'FAIL' })

    $null = Run-Tool 'Point Flutter at the SDK' $flutter @('config', '--android-sdk', $sdk)
    $null = Run-Tool 'Point Flutter at Java' $flutter @('config', '--jdk-dir', $jdk)
    $null = Run-Tool 'Flutter license check' $flutter @('doctor', '--android-licenses') $yes
} else {
    $summary['Android SDK'] = 'MISSING'
}

# ---------- 3. Build APK ----------
$apkOut = $null
if ($summary['Android SDK'] -eq 'OK') {
    Push-Location $root
    $null = Run-Tool 'Dependencies' $flutter @('pub', 'get')
    Log "First Android build downloads Gradle and the NDK - 10-30 minutes, the window may look idle."
    $r = Run-Tool 'Build APK' $flutter @('build', 'apk', '--release')
    $apk = Join-Path $root 'build\app\outputs\flutter-apk\app-release.apk'
    if ($r.Code -eq 0 -and (Test-Path $apk)) {
        $apkOut = Join-Path $root 'OBD_Doctor.apk'
        Copy-Item $apk $apkOut -Force
        $summary['APK'] = "OK ($apkOut)"
    } else {
        $summary['APK'] = 'FAIL'
    }

    # ---------- 4. Install on a phone if one is plugged in ----------
    if ($apkOut) {
        $adb = Join-Path $sdk 'platform-tools\adb.exe'
        $devs = & $adb devices 2>$null | Select-String -Pattern "\tdevice$"
        if ($devs) {
            $r = Run-Tool 'Install on phone' $adb @('install', '-r', $apkOut)
            $summary['Phone install'] = $(if ($r.Code -eq 0) { 'OK' } else { 'FAIL' })
        } else {
            $summary['Phone install'] = 'no phone connected (copy OBD_Doctor.apk to the phone instead)'
        }
    }
    $null = Run-Tool 'Doctor' $flutter @('doctor')
    Pop-Location
}

Log ""
Log "================ SUMMARY ================"
foreach ($k in $summary.Keys) { Log ("{0,-14} {1}" -f $k, $summary[$k]) }
Log "Log file: $log"
if ($apkOut) { Start-Process explorer.exe "/select,`"$apkOut`"" }
