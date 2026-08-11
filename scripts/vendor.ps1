# Vendors third-party C dependencies into ./vendor
# Run from the repo root:  pwsh -File scripts/vendor.ps1
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$vendor = Join-Path $root "vendor"
New-Item -ItemType Directory -Force -Path $vendor | Out-Null

# --- CLAP headers (pure C ABI) ---
$clapDir = Join-Path $vendor "clap"
if (-not (Test-Path (Join-Path $clapDir "include\clap\clap.h"))) {
    Write-Host "Cloning CLAP headers..."
    $tmp = Join-Path $env:TEMP ("clap-" + [Guid]::NewGuid().ToString("N"))
    git clone --depth 1 --branch 1.2.6 https://github.com/free-audio/clap.git $tmp
    New-Item -ItemType Directory -Force -Path $clapDir | Out-Null
    Copy-Item -Recurse -Force (Join-Path $tmp "include") $clapDir
    Remove-Item -Recurse -Force $tmp
} else {
    Write-Host "CLAP headers already present."
}

# --- Clay single-header UI layout library (needed from Phase 4 onward) ---
$clayDir = Join-Path $vendor "clay"
New-Item -ItemType Directory -Force -Path $clayDir | Out-Null
$clayHeader = Join-Path $clayDir "clay.h"
if (-not (Test-Path $clayHeader)) {
    Write-Host "Downloading clay.h..."
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/nicbarker/clay/v0.14/clay.h" -OutFile $clayHeader
} else {
    Write-Host "clay.h already present."
}

# --- stb single-header image codecs ---
# stb_image decodes the baked GUI PNGs at plugin load; stb_image_write is used
# by tools/bake_assets to emit them. Both are public domain.
$stbDir = Join-Path $vendor "stb"
New-Item -ItemType Directory -Force -Path $stbDir | Out-Null
foreach ($h in @("stb_image.h", "stb_image_write.h")) {
    $dest = Join-Path $stbDir $h
    if (-not (Test-Path $dest)) {
        Write-Host "Downloading $h..."
        Invoke-WebRequest -Uri "https://raw.githubusercontent.com/nothings/stb/master/$h" -OutFile $dest
    } else {
        Write-Host "$h already present."
    }
}

# --- clap-wrapper (projects our CLAP into a VST3; needed for Phase 7) ---
# The CLAP + VST3 SDKs it depends on are fetched by clap-wrapper itself at
# CMake-configure time (CLAP_WRAPPER_DOWNLOAD_DEPENDENCIES), so only the wrapper
# sources are vendored here.
$wrapperDir = Join-Path $vendor "clap-wrapper"
if (-not (Test-Path (Join-Path $wrapperDir "CMakeLists.txt"))) {
    Write-Host "Cloning clap-wrapper..."
    git clone --depth 1 --branch v0.15.1 https://github.com/free-audio/clap-wrapper.git $wrapperDir
} else {
    Write-Host "clap-wrapper already present."
}

Write-Host "Vendoring complete." -ForegroundColor Green
