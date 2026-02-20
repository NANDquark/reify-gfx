$ErrorActionPreference = "Stop"

function Resolve-Slangc {
	$fromPath = Get-Command slangc -ErrorAction SilentlyContinue
	if ($fromPath) {
		return $fromPath.Source
	}
	if ($env:SLANGC -and (Test-Path $env:SLANGC)) {
		return $env:SLANGC
	}
	if ($env:VULKAN_SDK) {
		$fromSdk = Join-Path $env:VULKAN_SDK "Bin\slangc.exe"
		if (Test-Path $fromSdk) {
			return $fromSdk
		}
	}
	$defaultSdkRoot = "C:\VulkanSDK"
	if (Test-Path $defaultSdkRoot) {
		$candidate = Get-ChildItem -Path $defaultSdkRoot -Directory |
			Sort-Object Name -Descending |
			ForEach-Object { Join-Path $_.FullName "Bin\slangc.exe" } |
			Where-Object { Test-Path $_ } |
			Select-Object -First 1
		if ($candidate) {
			return $candidate
		}
	}
	return ""
}

$slangcExe = Resolve-Slangc
if ([string]::IsNullOrWhiteSpace($slangcExe)) {
	throw "slangc not found. Add slangc to PATH, set SLANGC, or install Vulkan SDK with slangc."
}

Push-Location $PSScriptRoot
try {
	& $slangcExe "quad.slang" `
		-target "spirv" `
		-entry "vertMain" `
		-stage "vertex" `
		-entry "fragMain" `
		-stage "fragment" `
		-reflection-json "quad_shader_types.json" `
		-o "quad.spv"
	if ($LASTEXITCODE -ne 0) {
		throw "slangc shader compilation failed."
	}

	& odin run "..\tools\shader_types_gen"
	if ($LASTEXITCODE -ne 0) {
		throw "odin run ..\\tools\\shader_types_gen failed."
	}
} finally {
	Pop-Location
}
