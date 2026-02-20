$ErrorActionPreference = "Stop"

$repoRoot = $PSScriptRoot
Push-Location $repoRoot
try {
	& odin build demo
	if ($LASTEXITCODE -ne 0) {
		throw "odin build demo failed."
	}

	$hadLayers = Test-Path Env:VK_INSTANCE_LAYERS
	$previousLayers = $env:VK_INSTANCE_LAYERS
	$env:VK_INSTANCE_LAYERS = "VK_LAYER_KHRONOS_validation"
	try {
		& ".\demo.exe"
	} finally {
		if ($hadLayers) {
			$env:VK_INSTANCE_LAYERS = $previousLayers
		} else {
			Remove-Item Env:VK_INSTANCE_LAYERS -ErrorAction SilentlyContinue
		}
	}
} finally {
	Pop-Location
}
