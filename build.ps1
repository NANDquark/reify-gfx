Set-StrictMode -Version Latest
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
Push-Location $scriptDir

$osPlatform = [System.Runtime.InteropServices.OSPlatform]::Windows
$isWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform($osPlatform)
$vcpkgTriplet = if ($env:VCPKG_DEFAULT_TRIPLET) { $env:VCPKG_DEFAULT_TRIPLET } else { "x64-windows-static" }

function Resolve-VcpkgRoot {
    if ($env:VCPKG_ROOT -and (Test-Path (Join-Path $env:VCPKG_ROOT "vcpkg.exe"))) {
        return $env:VCPKG_ROOT
    }

    $vcpkgCmd = Get-Command vcpkg -ErrorAction SilentlyContinue
    if ($null -eq $vcpkgCmd) {
        return $null
    }

    $vcpkgExePath = $vcpkgCmd.Source
    if ([string]::IsNullOrWhiteSpace($vcpkgExePath)) {
        return $null
    }

    return Split-Path -Parent $vcpkgExePath
}

$cmakeArgs = @(
    "-S", "lib/msdfgen",
    "-B", "lib/msdfgen/build",
    "-DMSDFGEN_CORE_ONLY=OFF",
    "-DMSDFGEN_USE_VCPKG=ON",
    "-DMSDFGEN_DISABLE_SVG=ON",
    "-DMSDFGEN_USE_SKIA=OFF",
    "-DCMAKE_BUILD_TYPE=Release"
)

if ($env:VCPKG_ROOT) {
    $cmakeArgs += "-DCMAKE_TOOLCHAIN_FILE=$env:VCPKG_ROOT\scripts\buildsystems\vcpkg.cmake"
}

if (Test-Path "lib/msdfgen/build") {
    Remove-Item "lib/msdfgen/build" -Recurse -Force
}

if ($isWindows) {
    $vcpkgRoot = Resolve-VcpkgRoot
    if (-not $vcpkgRoot) {
        throw "vcpkg was not found. Install vcpkg and either set VCPKG_ROOT or add vcpkg.exe to PATH."
    }
    $vcpkgExe = Join-Path $vcpkgRoot "vcpkg.exe"
    $vcpkgToolchain = Join-Path $vcpkgRoot "scripts/buildsystems/vcpkg.cmake"
    if (-not (Test-Path $vcpkgExe)) {
        throw "vcpkg executable not found at '$vcpkgExe'"
    }
    if (-not (Test-Path $vcpkgToolchain)) {
        throw "vcpkg toolchain file not found at '$vcpkgToolchain'"
    }

    & $vcpkgExe install "--triplet=$vcpkgTriplet" freetype libpng zlib tinyxml2
    if ($LASTEXITCODE -ne 0) {
        throw "vcpkg install failed"
    }

    $env:VCPKG_ROOT = $vcpkgRoot

    $cmakeArgs += "-DCMAKE_TOOLCHAIN_FILE=$vcpkgToolchain"
    $cmakeArgs += "-DVCPKG_TARGET_TRIPLET=$vcpkgTriplet"
    $cmakeArgs += "-DVCPKG_MANIFEST_MODE=OFF"

    $cmakeArgs += "-G"
    $cmakeArgs += "Visual Studio 17 2022"
    $cmakeArgs += "-A"
    $cmakeArgs += "x64"
}

cmake @cmakeArgs
cmake --build lib/msdfgen/build --config Release

Push-Location "lib/vma"
if ($isWindows) {
    premake5 --vk-version=3 vs2022
    $solution = Join-Path "build" "make\windows\vma.sln"
    if (-not (Test-Path $solution)) {
        throw "Generated solution not found: $solution"
    }
    msbuild $solution /p:Configuration=Release
}
else {
    premake5 --vk-version=3 gmake
    Push-Location "build/make/linux"
    & make config=release_x86_64
    Pop-Location
}
Pop-Location

Pop-Location
